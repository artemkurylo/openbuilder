# Runbook

Day-2 operations, organised by symptom. Every entry gives the exact command.

Two conventions throughout:

- `you/your-repo` is the target repo, `<slug>` the story-set slug, `<pr>` the PR number.
- `<key>` is the state key `ob_slug_key` derives: `<owner>__<repo>__<slug>`, e.g.
  `you__your-repo__healthz-endpoint`.

## 0. The first three commands, always

```sh
openbuilder status you/your-repo     # slugs, branches, PRs, labels, last action
openbuilder logs                     # tail /opt/openbuilder/log/openbuilder.log over SSM
openbuilder doctor                   # ob-doctor PASS/FAIL table on the instance
```

If `status` shows nothing and `logs` returns nothing, the instance is probably stopped — which is its
normal resting state, not an incident. The question is then whether anything tried to wake it, and that
half of the loop runs in AWS rather than on the instance:

```sh
aws logs tail /aws/lambda/openbuilder-waker --region eu-central-1 --profile openbuilder-deploy --since 1h
```

Expect one tick every `waker_interval_minutes` (default 5), each ending in a JSON line whose `outcome`
field says what it decided. No ticks at all, or an `outcome` you did not expect, means the loop is stalled
on power-on — jump to [§5](#5-instance-is-stopped-and-not-picking-up-work).

To get a shell for anything below:

```sh
openbuilder shell                    # aws ssm start-session onto the instance
```

Everything on the instance runs as the `openbuilder` user. Always prefix with `sudo -u openbuilder`, or you
will create root-owned files in `/opt/openbuilder` and break the next poll pass.

## 1. Agent produced nothing / no commits

`ob-implement` and `ob-respond` both **require at least one new commit**. If the model finished without
committing, the job fails loudly: `openbuilder:blocked` goes on, a comment with the log tail goes on the
PR, and the attempts counter has already been incremented. If the failure happened *before* any PR
existed, there is no PR to comment on, so `ob-implement` opens a tracking issue titled
`openbuilder blocked: <slug>` instead — look for that:

```sh
gh issue list --repo you/your-repo --search 'openbuilder blocked in:title'
```

Diagnose in this order.

**a. Read what the agent said.** Each round leaves its own forensics directory,
`/opt/openbuilder/state/<key>/rounds/<NNN>/`, holding `prompt.md` (exactly what the model was given),
`run.ndjson` (the full NDJSON), `final.md` (the agent's own report), `feedback.md` (respond rounds only)
and `pr-body.md`. Start with `final.md` of the newest round — it is the agent explaining itself, already
extracted:

```sh
openbuilder shell
cd "$(sudo -u openbuilder bash -lc 'ls -d /opt/openbuilder/state/<key>/rounds/*/ | tail -1')"
sudo -u openbuilder cat final.md
sudo -u openbuilder cat prompt.md      # what it was actually asked, after substitution
```

If `final.md` is missing — the run died before it could be written — extract the text from the NDJSON:

```sh
sudo -u openbuilder jq -rs 'map(select(.type=="agent_end"))|last|.messages|map(select(.role=="assistant"))|last
        |.content|map(select(.type=="text"))|map(.text)|join("\n")' run.ndjson
```

**b. Read the worklog** on the work branch — this is where the agent records dead ends across rounds:

```sh
gh api repos/you/your-repo/contents/.openbuilder/backlog/<slug>/worklog.md \
  --ref openbuilder/work/<slug> --jq .content | base64 -d
```

**c. Interpret.** The implementer prompt tells it to **stop and explain instead of guessing at missing
requirements**, so "no commits plus a paragraph of questions" is the system working as designed, not a
crash. The fix is upstream: the story card was ambiguous. Tighten it and re-dispatch:

```sh
# edit .openbuilder/backlog/<slug>/story-NN-*.md in your local clone, then
# commit the change — editing a card voids its approval, and dispatch refuses a
# voided approval — then re-record it from inside the clone:
cd <clone>
# <control-repo> is the absolute path to your control-repo clone — ob-gate
# lives in the control repo's local/bin, not in the target clone.
<control-repo>/local/bin/ob-gate record <epic> backlog <slug>
openbuilder dispatch you/your-repo <slug>
```

Then force a clean re-implement per [§13](#13-force-a-re-implement-from-scratch).

**d. If instead it ran out of time** — the log line will say the omp run hit `OPENBUILDER_MAX_RUNTIME` —
either split the story (the correct answer; see `backlog/SCHEMA.md` on sizing) or raise the ceiling:

```sh
openbuilder shell
sudo sed -i 's/^OPENBUILDER_MAX_RUNTIME=.*/OPENBUILDER_MAX_RUNTIME=90m/' /opt/openbuilder/etc/openbuilder.env
```

That edit is local to the instance and will be reverted the next time cloud-init renders the file. For a
durable change, set `max_runtime` in `infra/terraform.tfvars` and `make apply`.

## 2. PR stuck in `openbuilder:in-progress`

`openbuilder:in-progress` is only ever set at job start and removed at job end, success or failure. If it
persists for longer than `OPENBUILDER_MAX_RUNTIME`, the process died without running its cleanup — OOM,
an instance stop mid-run, or a `SIGKILL`.

Check whether anything is actually running:

```sh
openbuilder shell
ls -l /opt/openbuilder/run/                                   # lockfiles
pgrep -a -u openbuilder omp                                   # is an omp child alive?
systemctl status openbuilder-poll.service --no-pager
sudo journalctl -u openbuilder-poll.service -n 200 --no-pager
```

`ob_lock` uses `flock`, so a stale lockfile is not itself a problem — the lock dies with the process that
held it, and rule 1 stops matching. If `pgrep` is empty and the lockfile is old, the lock is not held.

Clear the state by hand and let the next poll pass re-decide:

```sh
gh pr edit <pr> --repo you/your-repo --remove-label openbuilder:in-progress \
                                     --add-label openbuilder:changes-requested
```

Adding `changes-requested` makes rule 6 fire, so the instance runs `ob-respond` and continues the round it
lost. If it lost the *initial* implement and never pushed a work branch, there is no PR — see
[§13](#13-force-a-re-implement-from-scratch).

If it was killed by memory pressure:

```sh
openbuilder shell
sudo dmesg -T | grep -i -E 'oom|killed process'
free -m
```

A `t4g.medium` is 4 GB. A big `npm install` plus a test run plus omp can exhaust it. Raise
`instance_type` in `infra/terraform.tfvars` (`t4g.large`) and `make apply`.

## 3. `openbuilder:blocked` appeared

`blocked` is terminal from the instance's point of view: rule 3 skips the slug **forever**. It is always
accompanied by an explanation — a PR comment, or a `openbuilder blocked: <slug>` tracking issue if the
failure predates the PR.

```sh
gh pr view <pr> --repo you/your-repo --comments
openbuilder logs
```

Two distinct causes, distinguishable from the comment text:

- **Rule 4** — the attempts counter reached `OPENBUILDER_MAX_ATTEMPTS`; see
  [§4](#4-attempts-hit-openbuilder_max_attempts).
- **Any failure path** — a push rejected, `gh` 401, omp non-zero exit, no new commit. Fix the underlying
  cause, then resume.

To resume after fixing the cause, remove the label and give the instance something to match:

```sh
gh pr edit <pr> --repo you/your-repo --remove-label openbuilder:blocked \
                                     --add-label openbuilder:changes-requested
```

Rule 3 stops matching, rule 6 matches, `ob-respond` runs on the next pass. **Reset the attempts counter
too**, or rule 4 will immediately re-block it — and clear the `blocked-reported` marker, or rule 4's
report will not fire again the next time the cap is genuinely hit:

```sh
openbuilder shell
printf '0\n' | sudo -u openbuilder tee /opt/openbuilder/state/<key>/attempts >/dev/null
sudo -u openbuilder rm -f /opt/openbuilder/state/<key>/blocked-reported
```

Write `0` rather than deleting the file, and write it as the `openbuilder` user: a re-created root-owned
`attempts` is exactly the kind of thing that breaks the next poll pass. If the slug never got a PR, close
the `openbuilder blocked: <slug>` tracking issue instead of editing PR labels:

```sh
gh issue list --repo you/your-repo --search 'openbuilder blocked in:title' --json number,title
gh issue close <n> --repo you/your-repo
```

## 4. Attempts hit `OPENBUILDER_MAX_ATTEMPTS`

Rule 4: `attempts >= OPENBUILDER_MAX_ATTEMPTS` (default 6) → label `openbuilder:blocked`, comment, skip.
Every `ob-implement` and every `ob-respond` costs one attempt, so six is roughly "one implement plus five
review rounds".

Read the counter:

```sh
openbuilder shell
cat /opt/openbuilder/state/<key>/attempts          # a plain integer
ls /opt/openbuilder/state/<key>/blocked-reported   # exists once the cap has been reported
ls -d /opt/openbuilder/state/<key>/rounds/*/       # one directory per round actually run
```

**Think before you reset.** Six failed rounds on one story almost always means the story card is wrong,
not that the model needs a seventh try — the weak model is not going to find the answer on attempt seven
if it has not by attempt six. The right move is usually to close the PR, split the story, and re-plan.

If you do want more rounds:

```sh
openbuilder shell
printf '0\n' | sudo -u openbuilder tee /opt/openbuilder/state/<key>/attempts >/dev/null
sudo -u openbuilder rm -f /opt/openbuilder/state/<key>/blocked-reported
gh pr edit <pr> --repo you/your-repo --remove-label openbuilder:blocked \
                                     --add-label openbuilder:changes-requested
```

To raise the ceiling durably, set `max_attempts` in `infra/terraform.tfvars` and `make apply`.

## 5. Instance is stopped and not picking up work

Expected: `ob-idle-stop` stops the instance after `OPENBUILDER_IDLE_STOP_MINUTES` (default 30) of no lock
held, no actionable work from `ob-poll --dry-run`, and no mtime change under `state/` or the log.
Immediately before the stop it records that verdict at `/openbuilder/state/last_stop` in Parameter Store,
which is the half of the waker's flap guard that distinguishes a self-stop from a hand-run one (**e**).

Two things power it back on. The laptop CLI starts it for any interactive command — `openbuilder dispatch`
and `openbuilder review` both call `aws ec2 start-instances` and wait. The waker starts it when nobody is
at a laptop: an EventBridge rule invokes the `openbuilder-waker` Lambda every `waker_interval_minutes`
(default 5), it evaluates the same rule table as `ob-poll` against GitHub, and calls `ec2:StartInstances`
only when a slug is actionable **and** the instance state is exactly `stopped`. It never stops the
instance — that stays with `ob-idle-stop`, the only party that knows whether a job is mid-flight. So a
label added from the GitHub web UI boots the instance on its own, within `waker_interval_minutes`.

**a. Get it running now.**

```sh
openbuilder start                    # ec2 start-instances + wait
openbuilder status you/your-repo
```

If `start` returns but the instance never picks up work, the timers did not come back — see
[§9](#9-poll-timer-not-firing).

If the instance will not start at all, look at the API's reason:

```sh
aws ec2 describe-instances --instance-ids "$OPENBUILDER_INSTANCE_ID" \
  --region "$OPENBUILDER_REGION" \
  --query 'Reservations[].Instances[].{State:State.Name,Reason:StateTransitionReason}'
```

`InsufficientInstanceCapacity` for `t4g.medium` in your AZ is transient — retry, or change
`subnet_cidr`/AZ in Terraform.

To stop it deliberately:

```sh
openbuilder stop
```

A hand-run stop does **not** keep the box off. Nothing writes a self-stop record for it, so the waker starts
it again within `waker_interval_minutes` if GitHub has actionable work — that is deliberate, and the flap
guard no longer masks it for twenty minutes. To keep the instance off regardless, set `waker_enabled = false`
(**d**).

**b. Ask the waker what it sees.** This is the same code path the schedule runs, side effect included: if
the answer is yes and the instance is stopped, this call starts it.

```sh
aws lambda invoke --region eu-central-1 --profile openbuilder-deploy \
  --function-name openbuilder-waker --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout
```

The function's verdict lands on stdout first, then the CLI's own `{"StatusCode": 200, ...}`. An idle,
healthy loop answers `{"actionable": 0, "slugs": [], "started": false, "outcome": "nothing-to-do"}`. Read
`outcome` first:

| `outcome` | What it means | What to do |
|---|---|---|
| `nothing-to-do` | no plan branch is actionable — every slug matched rule 2, 3, 4 or 7 | nothing. Read the `DECISION` lines (**c**) to confirm which rule, then [§9](#9-poll-timer-not-firing) if you disagree |
| `instance-running` / `instance-pending` | work is waiting, but the instance is already on and its own poll timer owns it | nothing. If it stays that way for more than a minute or two, [§9](#9-poll-timer-not-firing) |
| `instance-stopping` | it caught `ob-idle-stop` mid-shutdown; starting now would race the stop | nothing. The next tick starts it |
| `flap-guard` | it refused to start: `ob-idle-stop` recorded that it stopped itself for having no work only minutes into this uptime, yet the waker sees work — a genuine disagreement | **e** below. Do not start it in a loop |
| `start-refused` | EC2 refused the start with a transient error (`error` names the code) | nothing. The work stays queued and the next tick retries; **f** below |
| `started` | `ec2:StartInstances` was called; `slugs` names what triggered it | expect `openbuilder status` to show movement within a minute or two |

Any other `outcome`, or a reply carrying `"FunctionError": "Unhandled"` instead of an `outcome`, is a bug or
a broken credential — the function deliberately raises on everything it cannot classify, so its error metric
stays meaningful. Read the traceback in the log (**c**) and treat it as
[§6](#6-app-token-expired-or-401) until proven otherwise.

**c. Read the scheduled ticks.** Every invocation, scheduled or manual, logs to
`/aws/lambda/openbuilder-waker` (retention `waker_log_retention_days`, default 14):

```sh
aws logs tail /aws/lambda/openbuilder-waker --region eu-central-1 --profile openbuilder-deploy --since 1h
aws logs tail /aws/lambda/openbuilder-waker --region eu-central-1 --profile openbuilder-deploy --follow
aws logs tail /aws/lambda/openbuilder-waker --region eu-central-1 --profile openbuilder-deploy \
  --since 6h --filter-pattern DECISION
```

Its per-slug lines have the same shape as `ob-poll`'s on purpose, so the two logs read alike:

```
DECISION repo=you/your-repo slug=healthz-endpoint rule=5 actionable=True reason=no-pr
```

That `rule=` number maps onto the same state-machine table in
[architecture.md](architecture.md#2-the-state-machine) as the instance's own decisions, so a waker line and
an `ob-poll --dry-run` line about the same slug are directly comparable.

Two rules never appear here, because they are instance-local state the Lambda cannot see: rule 1 (a lock is
held, so the instance is already busy) and rule 4 (the attempt budget). Rule 4 needs no separate coverage —
a slug that exhausts its budget gets `openbuilder:blocked` on the PR, or on a `openbuilder blocked: <slug>`
tracking issue when there is no PR, and the waker refuses on both (rule 3 and rule 4's no-PR form).

**d. Turn it off, or change its cadence.** In `infra/terraform.tfvars`:

```hcl
waker_enabled            = false   # stop the schedule; the Lambda stays deployed
waker_interval_minutes   = 5       # worst-case delay between labelling a PR and the instance booting
waker_flap_guard_minutes = 20      # keep below idle_stop_minutes; one of the guard's two conditions
```

Then `make apply`. `waker_enabled = false` sets the EventBridge rule to `DISABLED` and changes nothing
else: the Lambda, its role and its log group stay, and the manual invoke in **b** keeps working — so you
can still ask "is there work?" without a schedule. Power-on falls back to the laptop CLI.
`waker_interval_minutes` is the whole latency budget of the loop's power-on half; 1 to 60 minutes is
accepted, and a 5-minute cadence is ~8.6k invocations a month, well inside the perpetual Lambda free tier.

Confirm what is actually deployed:

```sh
terraform -chdir=infra output waker
```

That prints the live `function_name`, `schedule` (`rate(5 minutes)`), `enabled`, and the two commands above
with your own region and profile already filled in.

**e. `outcome: flap-guard`.** The waker refuses to start the instance only when **both** halves of the
guard hold: `LaunchTime` younger than `waker_flap_guard_minutes` (default 20) **and** an `ob-idle-stop`
record saying it stopped itself for having no work during that same uptime. The reasoning is in
[architecture.md](architecture.md#the-flap-guard--second-line-of-defence); what matters here is that a
refusal is evidence of a real disagreement between the two evaluations, not an artefact of somebody stopping
the box by hand. It says so in the log:

```
REFUSING to start i-0123456789abcdef0: ob-idle-stop stopped it at 2026-08-09T11:05:03+00:00 for having no
work, only 3.4 min after it launched, yet ['you/your-repo#healthz-endpoint'] looks actionable from here. The
instance and the waker disagree — run `ob-poll --dry-run` on the instance and compare its DECISION lines
with the ones above, rather than starting it in a loop.
```

The JSON result carries both halves — `minutes_since_launch`, and `self_stopped_at` taken from the record —
so you can tell which uptime it is talking about without parsing the prose.

Read the record itself:

```sh
aws ssm get-parameter --name /openbuilder/state/last_stop --region eu-central-1 \
  --profile openbuilder-deploy --query 'Parameter.Value' --output text
```

```
{"instance":"i-0123456789abcdef0","at":"2026-08-09T11:05:03Z","actionable":0,"quiet_minutes":30,"by":"ob-idle-stop"}
```

`ParameterNotFound` means nothing has ever self-stopped under this prefix, so the guard cannot fire at all. A
record whose `at` predates the current `LaunchTime` belongs to an earlier uptime and does not fire it either.
Every unreadable, malformed or unexpected record is treated the same way — as "we do not know" — and the
waker starts the instance, because a needless start costs cents while a stranded backlog costs the loop.

A refusal therefore says the instance found no work minutes before the waker found some. That disagreement
is the bug; starting the instance every five minutes only bills it. So do **not** loop `openbuilder start`.
Start it once, and put the two verdicts side by side:

```sh
openbuilder start
openbuilder shell
sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run
```

Compare per slug. Both sides print `DECISION ... rule=<n>`, so line them up:

- **Both sides call the same slug actionable** — then condition 2 (`ob-poll --dry-run` reporting
  `ACTIONABLE=0`) cannot have held when it stopped, even though the record says it did. Either the work
  appeared *after* the stop, which is legitimate and the next tick handles, or the two sides read GitHub
  differently: a stale token on the instance, or a repo in `var.repos` but not in `OPENBUILDER_REPOS`. Read
  what it actually printed: `sudo journalctl -u openbuilder-idle.service --since '1 hour ago' --no-pager`.
- **Instance says `rule=1`** — a lock is held during the dry run you just made. The waker cannot see locks,
  so the asymmetry is expected and harmless, but it cannot explain the refusal either: a held lock fails
  `ob-idle-stop`'s condition 1, so no record would have been written. Re-run the dry run once it clears.
- **Instance says `rule=4`, waker says `rule=5` or `6`** — the attempt budget is exhausted but the
  `openbuilder:blocked` label never reached GitHub, so the waker keeps thinking there is work. Apply the
  label by hand and fix the reporting path per [§4](#4-attempts-hit-openbuilder_max_attempts).
- **Different rules on the same slug for no other reason** — the two read GitHub seconds apart and a label
  or PR changed in between. It resolves itself on the next tick.

**f. `outcome: start-refused`.** EC2 declined the start with `InsufficientInstanceCapacity`,
`Unsupported` or `RequestLimitExceeded`. The waker treats all three as transient, does not raise, and says
so in plain language:

```
could not start i-0123456789abcdef0: InsufficientInstanceCapacity. ['you/your-repo#healthz-endpoint'] stays queued; retrying on the next tick. Capacity in the instance's availability zone is the usual cause and it clears on its own.
```

There is nothing to do and nothing to reset: the work lives in GitHub, not in the waker, so every tick
re-derives it and tries again. `waker_interval_minutes` is therefore also the retry interval, and retrying
is the whole strategy — the instance is pinned to one subnet because its EBS root volume is AZ-bound, so a
capacity refusal in that AZ can only be waited out. Confirm the reason from the EC2 side with the
`describe-instances` call in **a**; `openbuilder start` will fail the same way while capacity is short.

## 6. App token expired or 401

The installation token lives one hour. `ob-token` caches it at `/opt/openbuilder/cache/gh-token.json` and
mints a fresh one when it is within five minutes of `expires_at`, so an expiry should be invisible. A
persistent 401 means the *credential inputs* are wrong, not that the token aged out.

```sh
openbuilder doctor
```

Then, on the instance:

```sh
openbuilder shell
sudo -u openbuilder rm -f /opt/openbuilder/cache/gh-token.json      # force a fresh mint
sudo -u openbuilder bash -lc 'GH_TOKEN=$(/opt/openbuilder/bin/ob-token) gh api user --jq .login'
# expect: openbuilder-bot[bot]
```

If that fails, the cause is one of:

| Error | Cause | Fix |
|---|---|---|
| `A JWT could not be decoded` | PEM in SSM is mangled or the App ID is wrong | re-put both, see [github-app-setup.md](github-app-setup.md#6-put-the-values-into-ssm) |
| 404 on `/app/installations/<id>/access_tokens` | installation ID is wrong | re-read it from the `settings/installations/<id>` URL |
| Token mints, `gh` 403 on push | repo not in the App installation, or Workflows permission missing | **Install App** → Configure |
| `ParameterNotFound` in the log | wrong `OPENBUILDER_SSM_PREFIX`, or `make secrets` was never run | `aws ssm get-parameters-by-path --path /openbuilder --recursive --query 'Parameters[].Name' --output table` |

Check the clock too — JWT signing uses `iat = now-60`, `exp = now+540`, and a badly skewed clock produces
exactly the "could not be decoded" error:

```sh
openbuilder shell
timedatectl status
```

## 7. OpenRouter 429 or insufficient credit

Symptom: omp exits fast, `run.ndjson` is tiny, cost is zero, and the log shows an HTTP error from the
provider.

```sh
openbuilder shell
cd "$(sudo -u openbuilder bash -lc 'ls -d /opt/openbuilder/state/<key>/rounds/*/ | tail -1')"
sudo -u openbuilder tail -c 4000 run.ndjson
sudo -u openbuilder grep -c . run.ndjson     # a handful of lines = failed before doing any work
```

Check the key end-to-end without printing it:

```sh
openbuilder shell
sudo -u openbuilder bash -lc '
  OPENROUTER_API_KEY=$(aws ssm get-parameter --with-decryption \
    --name /openbuilder/openrouter_api_key --query Parameter.Value --output text)
  export OPENROUTER_API_KEY
  curl -s -o /dev/null -w "%{http_code}\n" https://openrouter.ai/api/v1/credits \
    -H "Authorization: Bearer $OPENROUTER_API_KEY"'
```

- `200` — the key is valid; a `429` during a run was rate limiting. The next poll pass retries in 60
  seconds; that is the whole remediation. Repeated 429s mean too many slugs in flight — queue fewer.
- `401` — bad key. Re-put it and delete nothing else:

  ```sh
  aws ssm put-parameter --overwrite --name /openbuilder/openrouter_api_key \
    --type SecureString --value 'sk-or-v1-REPLACE_ME' --region eu-central-1
  ```

- `402` / a zero balance — top up at <https://openrouter.ai/credits>.

`ob-doctor` covers this with a one-token omp call, which is the cheapest possible end-to-end check:

```sh
openbuilder doctor
```

## 8. Model produced a broken build

The agent is instructed to run the repo's own test and lint commands, but a weak model can convince
itself a failure is unrelated. That is what the review gate is for.

```sh
gh pr checks <pr> --repo you/your-repo
gh pr diff <pr> --repo you/your-repo
openbuilder review you/your-repo <pr>
openbuilder review --watch you/your-repo <pr>   # unattended: reviews each new
                                                # head sha once, applies its own
                                                # verdict, stops after
                                                # OPENBUILDER_MAX_ATTEMPTS (6)
                                                # rounds; exit 4 = blocked,
                                                # exit 5 = rounds exhausted
```

Then hand it back with the failure quoted in a comment, which is what `ob-respond` will read:

~~~sh
gh pr comment <pr> --repo you/your-repo --body-file - <<'EOF'
CI is failing. `npm test` output:

```
FAIL test/health.test.js
  expected 200, got 404
```

Fix the route registration, then re-run the tests locally before pushing.
EOF
openbuilder request-changes you/your-repo <pr>
~~~

`ob-respond` pulls the PR body, **all** review comments and **all** review threads with
`gh api --paginate`, so a specific, quoted failure is the highest-signal thing you can give it. Vague
comments produce vague rounds.

If it is unsalvageable, stop spending attempts on it. Do **not** reach for `openbuilder approve` — that
label means "a human may merge this", and using it as a mute button leaves a lie in the PR timeline.

Close it outright instead, then re-plan with better story cards:

```sh
gh pr close <pr> --repo you/your-repo
gh pr edit <pr> --repo you/your-repo --add-label openbuilder:blocked
```

`blocked` is the honest label: rule 3 makes the instance skip the slug forever without pretending the work was
accepted.

## 9. Poll timer not firing

```sh
openbuilder shell
systemctl list-timers 'openbuilder-*' --all --no-pager
systemctl status openbuilder-poll.timer  --no-pager
systemctl status openbuilder-poll.service --no-pager
sudo journalctl -u openbuilder-poll.service -n 200 --no-pager
sudo journalctl -u openbuilder-idle.service -n 100 --no-pager
```

Expected: `openbuilder-poll.timer` with `OnBootSec=60s`, `OnUnitInactiveSec=60s`, `AccuracySec=5s`,
`Persistent=false`; `openbuilder-idle.timer` with `OnBootSec=10min`, `OnUnitInactiveSec=5min`. Both
`active (waiting)`.

Restart them:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now openbuilder-poll.timer openbuilder-idle.timer
```

If the units are missing entirely, cloud-init or `bootstrap.sh` did not finish. Check, then re-run
bootstrap — it is idempotent:

```sh
sudo cloud-init status --long
sudo tail -100 /var/log/cloud-init-output.log
sudo /opt/openbuilder/repo/runner/bootstrap.sh
```

If the service fails immediately with a status about the environment file, the env file is missing or
malformed (`EnvironmentFile=/opt/openbuilder/etc/openbuilder.env`):

```sh
sudo cat /opt/openbuilder/etc/openbuilder.env
```

Every line must be `KEY=value`, no `export`, no stray quotes. If it is wrong, fix
`infra/terraform.tfvars` and `make apply` — the file is rendered by cloud-init from Terraform vars.

Run one pass in the foreground to see what it decides. `--dry-run` prints one
`DECISION repo=... slug=... rule=<n> action=... reason=...` line per slug and a final `ACTIONABLE=<n>`,
and takes no action:

```sh
sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run
```

`ACTIONABLE=0` with a plan branch you expected to be picked up means a refusal rule matched — read the
`rule=` number against the table in [architecture.md](architecture.md#2-the-state-machine). The common
answers are rule 2/3 (an `approved` or `blocked` label you forgot about) and rule 4 (attempts capped).

## 10. Disk full

Symptom: git operations fail, `run.ndjson` truncates, everything blocks.

```sh
openbuilder shell
df -h /opt/openbuilder
sudo du -sh /opt/openbuilder/* | sort -h
sudo du -sh /opt/openbuilder/state/* | sort -h
```

The usual suspects, in order: `work/` worktrees, `src/` clones with big histories and `node_modules`,
`state/<key>/rounds/<NNN>/run.ndjson` transcripts, and the apt/npm caches.
`/opt/openbuilder/log/openbuilder.log` is almost never the problem — only real work writes to it, so it
grows on the order of kilobytes per day.

Reclaim, safest first:

```sh
# 1. old round transcripts for slugs that are done (approved/merged).
#    Each rounds/<NNN>/ also holds prompt.md, final.md, feedback.md and pr-body.md — those are small,
#    and they are the forensics you want to keep, so delete the NDJSON only.
sudo -u openbuilder find /opt/openbuilder/state -name 'run.ndjson' -mtime +14 -delete

# 2. worktrees for finished slugs — remove through git so the clone's metadata stays consistent
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo \
  worktree remove --force /opt/openbuilder/work/you__your-repo__<slug>
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo worktree prune

# 3. git object churn
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo gc --prune=now

# 4. package manager caches
sudo apt-get clean
sudo -u openbuilder npm cache clean --force

# 5. journal
sudo journalctl --vacuum-time=7d
```

If you ever do need to trim the log, **rotate and recreate — never truncate in place.**
`openbuilder logs -f` follows that exact path by byte offset: it copes with a fresh, smaller file, but an
in-place truncation leaves it reading past the end.

```sh
openbuilder shell
sudo -u openbuilder bash -c 'cd /opt/openbuilder/log &&
  mv openbuilder.log "openbuilder.log.$(date -u +%Y%m%dT%H%M%SZ)" && : > openbuilder.log'
```

No logrotate config is installed, by design — see [§11](#11-reading-the-logs).

Never `rm -rf` a `work/` directory without `git worktree remove`/`prune` — the clone in `src/` keeps
metadata pointing at it and the next `ob-implement` for that slug will fail confusingly.

For headroom, raise `root_volume_gb` in `infra/terraform.tfvars`, `make apply`, then grow the filesystem:

```sh
openbuilder shell
lsblk
sudo growpart /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1
```

## 11. Reading the logs

**Operational log** — `/opt/openbuilder/log/openbuilder.log`. One strictly append-only file (every writer
uses `>>`), ISO-8601 UTC timestamps, and everything passes through the redactor (`sk-or-`, `ghs_`,
`github_pat_`, PEM bodies) — so it is safe to paste into a ticket as-is. Nothing rotates or recreates it;
no logrotate config is installed.

**An idle instance writes nothing to it, and that is healthy.** Uneventful poll passes and routine "not idle
yet" checks go to the journal only. This is deliberate, not an oversight: `ob-idle-stop`'s third idle
condition measures this file's mtime, so a chatty logger would keep the instance awake forever and defeat
auto-stop. Silence here means no work happened — use `journalctl` for the noisy view. Do not "fix" it by
adding heartbeat logging, and if you ever trim it, rotate rather than truncate in place
([§10](#10-disk-full)).

```sh
openbuilder logs                 # tail it over SSM
openbuilder logs -f              # follow
```

On the instance directly:

```sh
openbuilder shell
tail -n 200 /opt/openbuilder/log/openbuilder.log
tail -f    /opt/openbuilder/log/openbuilder.log
grep -F '<slug>' /opt/openbuilder/log/openbuilder.log
grep -E 'ERROR|WARN'  /opt/openbuilder/log/openbuilder.log | tail -50
```

**Per-round forensics** — `/opt/openbuilder/state/<key>/rounds/<NNN>/`, one directory per round actually
run, each holding:

| File | Contents |
|---|---|
| `prompt.md` | exactly what the model was given, after `{{PLACEHOLDER}}` substitution |
| `run.ndjson` | the full NDJSON, one JSON object per line, `.type` in `session\|agent_start\|turn_start\|message_start\|message_update\|message_end\|turn_end\|agent_end` |
| `final.md` | the agent's own report — the extracted final assistant text |
| `feedback.md` | the review comments and threads fed in (respond rounds only) |
| `pr-body.md` | the PR body as posted |

`prompt.md` next to `final.md` is the highest-signal pair in the whole system: it is exactly what you
asked for and exactly what you got. Read those before touching the NDJSON.

```sh
openbuilder shell
cd "$(sudo -u openbuilder bash -lc 'ls -d /opt/openbuilder/state/<key>/rounds/*/ | tail -1')"
cat final.md
cat prompt.md

# the same text, straight from the NDJSON — use this if final.md is missing
jq -rs 'map(select(.type=="agent_end"))|last|.messages|map(select(.role=="assistant"))|last
        |.content|map(select(.type=="text"))|map(.text)|join("\n")' run.ndjson

# what this run cost, in USD
jq -s 'map(select(.type=="message_end")|.message.usage.cost.total//0)|add//0' run.ndjson

# the shape of the run: how many of each event
jq -r .type run.ndjson | sort | uniq -c

# every tool call it made, in order
jq -rc 'select(.type=="message_end")|.message.content[]?|select(.type=="tool_use")|[.name,(.input|tostring)[0:160]]|@tsv' run.ndjson
```

Cost across every job on the instance:

```sh
openbuilder cost
```

**systemd journal** — the per-decision view, and the only place uneventful passes appear. `ob-poll` prints
one line per slug plus a total:

```sh
sudo journalctl -u openbuilder-poll.service  --since '2 hours ago' --no-pager
sudo journalctl -u openbuilder-idle.service  --since '1 day ago'   --no-pager

# just the decisions
sudo journalctl -u openbuilder-poll.service --since today --no-pager | grep -E 'DECISION|ACTIONABLE'
```

A decision line looks like
`DECISION repo=you/your-repo slug=healthz-endpoint rule=7 action=skip reason=<...>`, and each pass ends
with `ACTIONABLE=<n>`. That `rule=` number maps straight onto the state-machine table in
[architecture.md](architecture.md#2-the-state-machine), so it tells you exactly why the instance did or did not
act — which is usually the answer to "why is nothing happening".

## 12. Re-run a single job by hand

Useful when you want to watch a run live instead of waiting 60 seconds and reading a transcript. Take the
slug lock the same way the poller does by simply not running two at once — stop the timer first.

```sh
openbuilder shell
sudo systemctl stop openbuilder-poll.timer          # don't race the poller

# a full implement pass
sudo -u openbuilder /opt/openbuilder/bin/ob-implement you/your-repo <slug>

# or one review round against an existing PR
sudo -u openbuilder /opt/openbuilder/bin/ob-respond you/your-repo <slug> <pr>

# what the poller *would* do, no side effects
sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run

# a real single pass
sudo -u openbuilder /opt/openbuilder/bin/ob-poll

sudo systemctl start openbuilder-poll.timer         # ALWAYS put it back
```

These are the same entry points the timer uses and they update labels, attempts and the worklog exactly
the same way — a manual run is not a dry run.

## 13. Force a re-implement from scratch

Rule 5 only fires when **no PR with head `openbuilder/work/<slug>` exists**. So to make the instance start the
story over, remove the PR and the branch:

```sh
gh pr close <pr> --repo you/your-repo --delete-branch
```

If the branch survives (or there was never a PR):

```sh
git push origin --delete openbuilder/work/<slug>
```

Then clear the instance's local state for that slug so it starts from a clean worktree, and reset attempts:

```sh
openbuilder shell
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo \
  worktree remove --force /opt/openbuilder/work/you__your-repo__<slug> || true
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo worktree prune
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo branch -D openbuilder/work/<slug> || true
sudo -u openbuilder rm -rf /opt/openbuilder/state/you__your-repo__<slug>
```

Push updated story cards if you changed them — but editing a card voids its approval (the recorded
bytes no longer match, and `openbuilder dispatch` refuses a voided approval). Commit the change and
re-record it from inside the clone before dispatching:

```sh
git -C <clone> commit -am 'story: tighten acceptance criteria'
(cd <clone> && <control-repo>/local/bin/ob-gate record <epic> backlog <slug>)
openbuilder dispatch you/your-repo <slug>
```

The next poll pass matches rule 5 and runs `ob-implement` fresh. Note that the worklog is gone with the
branch — that is the point of a clean restart.

To retire a slug permanently instead, delete the plan branch; `ob-poll` iterates over
`openbuilder/plan/*`, so no branch means no work:

```sh
git push origin --delete openbuilder/plan/<slug>
```

## 14. Roll back merged work

Nothing the instance does is irreversible, because it never merges. Once *you* have merged, revert like any
other change:

```sh
git fetch origin
git checkout main && git pull --ff-only

# a squash-merged PR is one commit
git revert --no-edit <merge-or-squash-sha>

# a true merge commit
git revert --no-edit -m 1 <merge-sha>

git push origin main
```

Find the SHA:

```sh
gh pr view <pr> --repo you/your-repo --json mergeCommit,mergedAt,title
```

Prefer `git revert` over a force-push: the agent's guardrails hook blocks force-pushes, and history that
the instance may still have cloned in `src/` should not be rewritten under it. If you do rewrite anyway, reset
the instance's clone:

```sh
openbuilder shell
sudo -u openbuilder git -C /opt/openbuilder/src/you__your-repo fetch --all --prune
```

## 15. Update the instance

The instance runs whatever is in `/opt/openbuilder/repo`, a checkout of this control repo. After you push a
change to `runner/`, `agent/remote/` or the prompts:

```sh
openbuilder shell
sudo -u openbuilder /opt/openbuilder/bin/ob-selfupdate
```

That does `git -C /opt/openbuilder/repo pull --ff-only` and then re-runs `bootstrap.sh`, which is
idempotent: it re-copies `runner/bin`, `runner/prompts` and `agent/remote` into `/opt/openbuilder/`,
reinstalls the systemd units, and `daemon-reload`s. Verify:

```sh
openbuilder doctor
```

If the pull fails because the working tree diverged (you hand-edited a script on the instance):

```sh
openbuilder shell
sudo -u openbuilder git -C /opt/openbuilder/repo status --short
sudo -u openbuilder git -C /opt/openbuilder/repo checkout -- .
sudo -u openbuilder /opt/openbuilder/bin/ob-selfupdate
```

`--ff-only` is deliberate: the instance never merges, not even its own control repo.

Changes to `/opt/openbuilder/etc/openbuilder.env` are **not** covered by `ob-selfupdate` — that file is
rendered by cloud-init from Terraform variables. To change it properly, edit `infra/terraform.tfvars`,
`make apply`, and recreate the instance (or hand-edit the file on the instance for a temporary override and
accept that it is not durable).

To pick up a new omp release, bump `omp_version` in `infra/terraform.tfvars` and `make apply`, or just
re-run bootstrap — it downloads `omp-linux-arm64` plus `SHA256SUMS.txt`, verifies the checksum, and skips
the install if the version already matches:

```sh
openbuilder shell
sudo /opt/openbuilder/repo/runner/bootstrap.sh
omp --version
```

`LEARNINGS.md` is deliberately outside all of this. A round re-reads it from the control repo's *remote*
every time it runs, so publishing an entry is a push and nothing else — no `ob-selfupdate`, no restart. See
[§17](#17-publish-a-learning).

## 16. Instance never powers off

Symptom: the instance stays `running` for hours, nothing new appears in
`/opt/openbuilder/log/openbuilder.log`, and the idle service repeats one line every five minutes:

```
2026-08-09T11:05:03Z INFO  ob-idle-stop: staying up: condition 1 failed — locks held: selfupdate
```

```sh
openbuilder shell
sudo journalctl -u openbuilder-idle.service -n 100 --no-pager | grep 'staying up'
pgrep -a -u openbuilder omp                # empty: nothing is actually running
ls -l /opt/openbuilder/run/
```

Condition 1 is "no lock is held". `pgrep` empty while condition 1 keeps failing is **not** a stale
lockfile — `ob_lock` uses `flock`, so a lock dies with the process that held it
([§2](#2-pr-stuck-in-openbuilderin-progress)). It means the probe cannot open the lockfile at all, which is
a permissions bug, and the most expensive one found so far: a root-owned
`/opt/openbuilder/run/selfupdate.lock`, left behind by an `ob-selfupdate` run as root, kept an instance
awake for seven hours instead of thirty minutes.

Check ownership. Every lock must read `openbuilder openbuilder 664`:

```sh
openbuilder shell
stat -c "%U %G %a %n" /opt/openbuilder/run/*.lock
# expect: openbuilder openbuilder 664 /opt/openbuilder/run/selfupdate.lock
```

The fix is a self-update **as root** — the repair is a `chown`, so it needs to be:

```sh
sudo /opt/openbuilder/bin/ob-selfupdate
```

`bootstrap.sh` re-creates `run/` as `2775` — setgid and group-writable, so a lockfile created by root stays
usable by the service user — then chowns and chmods every existing `*.lock` and logs
`normalised ownership of /opt/openbuilder/run/*.lock`. Re-run the `stat` above, then watch it actually go
down:

```sh
sudo journalctl -u openbuilder-idle.service -f
# expect, within OPENBUILDER_IDLE_STOP_MINUTES:
# ob-idle-stop: recorded the stop verdict at /openbuilder/state/last_stop
# ob-idle-stop: idle for more than 30m with no locks and no actionable work; stopping i-0123456789abcdef0
# ob-idle-stop: stop requested for i-0123456789abcdef0
```

The verdict comes first because the record has to exist before the stop for the waker's flap guard
([§5](#5-instance-is-stopped-and-not-picking-up-work), **e**) to mean anything. Publishing it is best effort:
a failure is a WARN and the instance stops anyway, because nothing justifies keeping a paid instance running.

```
2026-08-09T11:05:03Z WARN  ob-idle-stop: could not write /openbuilder/state/last_stop; the flap guard has nothing to fire on, so the waker may start this instance again as soon as work appears
```

That is the safe direction, and the message says so: with no record the guard's second condition can never
hold, so the waker does not hold the instance back at all — it starts it on the next tick if GitHub has
work.

A fresh occurrence of this class of bug is loud rather than silent. `ob_lock_held` opens the lockfile
read-only and takes a *shared* lock — an exclusive holder still makes `flock -ns` fail, so detection is
unchanged — and a file it cannot open at all is a distinct error, treated as NOT held:

```
2026-08-09T11:05:03Z ERROR ob-idle-stop: cannot open lockfile /opt/openbuilder/run/selfupdate.lock as openbuilder; treating it as NOT held — fix its ownership (expected openbuilder:openbuilder, mode 0664)
```

That line goes to both the journal and the operational log, so it is findable after the fact:

```sh
grep -F 'cannot open lockfile' /opt/openbuilder/log/openbuilder.log
```

An ownership mistake is a configuration bug to fix, never a reason to keep the instance running — and
billing — forever. Prevention is the rule from the top of this file: everything on the instance runs as
`openbuilder`, so use `sudo -u openbuilder` for the routine self-update in
[§15](#15-update-the-instance) and keep the root form for this repair. Running it as root is safe now:
`ob_lock` creates every lockfile `0664` and chowns it to `openbuilder` whenever root is the one creating it.

## 17. Publish a learning

`LEARNINGS.md` at the root of this control repo is the durable store of operational knowledge, and
`ob-implement` and `ob-respond` inject it verbatim into every round as the prompt's `{{LEARNINGS}}` block.
It is read from the **remote**, not from the instance's checkout, which is what makes publishing cheap: one
file edit and a push apply on the very next round, with no code deploy and no restart. It is also why the
store lives in the repo rather than on the instance — an EBS root volume cannot follow its instance to
another availability zone, so a rebuild destroys the disk and everything on it. The mechanism is described
in [architecture.md](architecture.md#3-the-learnings-store); what follows is the operator's half.

**a. Publish one.** In your clone of the control repo:

```sh
# edit LEARNINGS.md — see its own "Rules for editing this file"; entry shape is
#   ### N. Imperative rule, in one line  /  Symptom / Cause / Rule / Proven
make scrub                                   # §18 — never publish an identifier by accident
git add LEARNINGS.md
git commit -m 'learnings: <the rule, in one line>'
git push origin main
```

That is the whole deployment. `ob_learnings` runs `git fetch origin HEAD` in `/opt/openbuilder/repo` and
reads `FETCH_HEAD:LEARNINGS.md`, so the next round has the new entry without `ob-selfupdate`
([§15](#15-update-the-instance)) and without touching a service. `fetch origin HEAD` writes `FETCH_HEAD`
without moving any branch and without making the clone shallow — a shallow clone would break
`ob-selfupdate`'s `merge --ff-only` — and it cannot race a self-update either, because `ob-selfupdate`
skips entirely while any job lock is held.

Confirm it from the instance instead of trusting the push. Call the library function exactly as a round
does:

```sh
openbuilder shell
sudo -u openbuilder bash -c 'source /opt/openbuilder/bin/ob-common.sh; ob_load_env; out=$(mktemp); ob_learnings "$out"; wc -l <"$out"'
```

`ob_learnings` logs which source it used, then the `wc -l` prints the line count it produced:

```
2026-08-09T11:05:03Z INFO  bash: learnings: 138 lines from artemkurylo/openbuilder (remote)
138
```

`(remote)` is the assertion you came for — anything else means the chain degraded (**c**), and the entry
you just pushed is probably not in the round. The `bash:` prefix is only `OB_PROG` falling back to `$0`
because you sourced the library by hand; a real round logs `ob-implement:` or `ob-respond:`. The line also
lands in the operational log, so it is findable per round after the fact:

```sh
grep -F 'learnings:' /opt/openbuilder/log/openbuilder.log | tail -5
wc -l /opt/openbuilder/state/<key>/rounds/*/learnings.md   # what each round was actually given
```

**b. Accept a learning a round proposed.** A round never edits `LEARNINGS.md`. It may append a candidate
to the file named by `{{LEARNINGS_OUT}}` — `/opt/openbuilder/state/<key>/rounds/<NNN>/learnings-proposed.md`,
the single path outside its worktree the agent is allowed to write. That file starts empty, so any
non-blank line counts as a proposal; when there is one, the round appends a
`### Learnings proposed this round` section to the slug's `worklog.md` and commits it to the work branch,
which puts it on the pull request. Read it there:

```sh
gh api repos/you/your-repo/contents/.openbuilder/backlog/<slug>/worklog.md \
  --ref openbuilder/work/<slug> --jq .content | base64 -d | sed -n '/Learnings proposed/,$p'
```

To accept it: in the control repo, put the entry under the heading it belongs to — "Rules the implementer
must follow" or "Environment truths" — give it the next number, and publish it with **a**. Check it against
that file's own editing rules first: it must have been *observed*, stated as an imperative, and be
repo-agnostic (knowledge about one target repo belongs in that repo's `worklog.md`).

**Nothing the round wrote takes effect on its own.** The proposal exists only as text on a PR; the store is
`LEARNINGS.md` and only a human — or the reviewer acting for one — commits there. Rejecting a proposal is
doing nothing at all. Conversely, merging the PR does not publish anything: the worklog lands in the
*target* repo, not here.

**c. Diagnose the fallback chain.** `ob_learnings` tries four sources in order and says which one it used.
Only the first is healthy; the other three are `WARN` and each has a distinct cause:

| Log line | What it means |
|---|---|
| `INFO  learnings: <N> lines from <control repo> (remote)` | healthy. `<N>` lines came from `FETCH_HEAD:LEARNINGS.md`, i.e. whatever is pushed right now |
| `WARN  learnings: remote unreachable; using the local clone at <sha>` | the fetch (or the `show FETCH_HEAD:`) failed. The round ran on the clone's committed copy, so **everything pushed since `<sha>` is missing** |
| `WARN  learnings: using the installed copy at /opt/openbuilder/LEARNINGS.md` | there is no usable clone at all. The round ran on the snapshot `bootstrap.sh` copied in, frozen at whenever bootstrap last ran |
| `WARN  learnings: none found; this round runs without them` | no clone and no installed copy. The `{{LEARNINGS}}` block was empty and the round proceeded anyway |

One check per line, in the same order:

```sh
openbuilder shell

# "remote unreachable" — egress, then auth. cloud-init clones the control repo over
# anonymous HTTPS, so DNS/NAT/security-group first; a private control repo needs the
# App token's git credential helper instead (§6).
sudo -u openbuilder git -C /opt/openbuilder/repo fetch origin HEAD && echo FETCH_OK
sudo -u openbuilder git -C /opt/openbuilder/repo log --oneline -1 FETCH_HEAD

# "using the installed copy" — is /opt/openbuilder/repo a clone at all?
ls -d /opt/openbuilder/repo/.git || sudo -u openbuilder \
  git clone https://github.com/artemkurylo/openbuilder.git /opt/openbuilder/repo

# "none found" — bootstrap never ran, or ran before LEARNINGS.md existed. It installs
# the fallback copy; running it also fixes the clone above.
sudo /opt/openbuilder/repo/runner/bootstrap.sh
ls -l /opt/openbuilder/LEARNINGS.md
```

A missing clone is the serious one: `ob-selfupdate` needs it too, so that instance is not receiving code
changes either ([§15](#15-update-the-instance)). None of the three fails the round on purpose — a missing
learnings file degrades a round, it never fails one — so nothing else in the log will point at this. The
`learnings:` line is the only evidence, which is why it is worth grepping before you conclude the model
ignored an entry: it may never have been given it.

## 18. `make scrub` before you publish

Everything in this repo is public and every prompt it produces is processed by a third-party model, so
employer and client names, internal hostnames, cloud account numbers, work email domains and the local
directory layout of your checkout must never be committed. `local/bin/ob-scrub-check` is the gate.

The deny list is **not** in the repo, because the patterns are themselves the sensitive part. The tool reads
`$OPENBUILDER_SCRUB_DENY`, or `.scrub-deny` at the repo root, which is gitignored: one extended regex per
line, blank lines and `#` comments ignored. Point `$OPENBUILDER_SCRUB_DENY` at a list kept outside any
checkout and every repo you own is checked against the same patterns.

```sh
make scrub                            # the worktree, then all history — what CI-of-one looks like
local/bin/ob-scrub-check              # tracked files in the working tree
local/bin/ob-scrub-check --staged     # exactly what you are about to commit
local/bin/ob-scrub-check --history    # every commit, via `git rev-list --all` (slow, thorough)
```

Clean is two lines, exit 0:

```
ob-scrub-check: clean (worktree).
ob-scrub-check: clean (history).
```

A hit names the path and a count, exits 1, and never prints what matched:

```
ob-scrub-check: worktree: docs/runbook.md — 2 match(es)

ob-scrub-check: 1 location(s) matched the deny list. Nothing was printed from
ob-scrub-check: those files on purpose — open them yourself. A match already in
ob-scrub-check: published history needs history rewritten, not just a new commit.
```

The silence is the design: a check that echoes the string it is protecting has leaked it into your
terminal, your scrollback and eventually some log. Open the named file and search it against your own deny
list. In `--history` mode the first field is the short commit instead of `worktree`, so a hit tells you
where in history to look:

```
ob-scrub-check: 5582097a: docs/runbook.md — 2 match(es)
```

And that is the case with real consequences. A match in a commit you have already pushed cannot be fixed by
a follow-up commit — the string is in the published object, and removing it means **rewriting history** and
force-pushing, which breaks the instance's clone of the control repo (`LEARNINGS.md` entry 11) and needs the
re-clone in **§17c**. Which is the argument for running `--staged` before every commit and `make scrub`
before every push, rather than discovering it later.

With no deny list at all the tool exits **0** and tells you what to put in one — a checkout with no patterns
has nothing to check, so it is not an error:

```
ob-scrub-check: no deny list at /path/to/openbuilder/.scrub-deny; nothing to check.
ob-scrub-check: create it (it is gitignored) with one extended regex per line —
ob-scrub-check: employer and client names, internal hostnames, account ids, work
ob-scrub-check: email domains, and the parent directories of your checkout.
```

`make lint` also shellchecks `local/bin/*`, so the check itself is linted like the runner scripts.

## 19. Quick reference

| Want | Command |
|---|---|
| See everything at a glance | `openbuilder status you/your-repo` |
| Tail the instance log | `openbuilder logs -f` |
| Full preflight | `openbuilder doctor` |
| Shell on the instance | `openbuilder shell` |
| Power | `openbuilder start` / `openbuilder stop` |
| Spend so far | `openbuilder cost` |
| What would the poller do? | `sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run` |
| Run one implement now | `sudo -u openbuilder /opt/openbuilder/bin/ob-implement you/your-repo <slug>` |
| Run one review round now | `sudo -u openbuilder /opt/openbuilder/bin/ob-respond you/your-repo <slug> <pr>` |
| Fresh App token identity | `sudo -u openbuilder bash -lc 'GH_TOKEN=$(/opt/openbuilder/bin/ob-token) gh api user --jq .login'` |
| Update the instance | `sudo -u openbuilder /opt/openbuilder/bin/ob-selfupdate` |
| Hand the PR back to the instance | `openbuilder request-changes you/your-repo <pr>` |
| Tell the instance to stop touching a PR | `openbuilder approve you/your-repo <pr>` |
| Drive a PR to a verdict unattended | `openbuilder review --watch you/your-repo <pr>` |
| Merge and clean up | `openbuilder land you/your-repo <pr>` |
| Why is my plan branch doing nothing? | `openbuilder status you/your-repo` (read the `UNAPPR` column) |
| Reset attempts | `printf '0\n' \| sudo -u openbuilder tee /opt/openbuilder/state/<key>/attempts` then `rm -f .../blocked-reported` |
| Read the newest round's report | `cat /opt/openbuilder/state/<key>/rounds/*/final.md \| tail -40` |
| Why did the poller skip my slug? | `sudo journalctl -u openbuilder-poll.service --since today \| grep DECISION` |
| Did the waker see work? | `aws lambda invoke --region eu-central-1 --profile openbuilder-deploy --function-name openbuilder-waker --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout` |
| What the waker decided | `aws logs tail /aws/lambda/openbuilder-waker --region eu-central-1 --profile openbuilder-deploy --since 1h` |
| Is the waker scheduled at all? | `terraform -chdir=infra output waker` |
| Lock ownership (must be `openbuilder openbuilder 664`) | `stat -c "%U %G %a %n" /opt/openbuilder/run/*.lock` |
| Confirm the instance sees a published learning | `sudo -u openbuilder bash -c 'source /opt/openbuilder/bin/ob-common.sh; ob_load_env; out=$(mktemp); ob_learnings "$out"; wc -l <"$out"'` |
| Which source the learnings came from | `grep -F 'learnings:' /opt/openbuilder/log/openbuilder.log \| tail -5` |
| Refuse to publish a private identifier | `make scrub` (or `local/bin/ob-scrub-check --staged` before a commit) |

## 20. Refusals from the laptop CLI

A refusal is a message on stderr (and always exits non-zero). Every refusal this slug added, quoted
verbatim from `local/bin/openbuilder`, with the cause and the fix. Appended as §20 rather than
renumbering: the section numbers are things other documents point at.

| Refusal (grep this) | Cause | Fix |
|---|---|---|
| `local/bin/ob-gate is missing or not executable at $OB_BIN_DIR/ob-gate — the epic gate cannot run without it` | `plan-workflow-01-gate` has not merged, or the script was removed | merge the gate slug; reinstall `local/bin/ob-gate` |
| `plan <owner/repo> <epic>` (usage line) | `openbuilder plan` needs exactly an owner/repo and an epic | `openbuilder plan you/your-repo <epic>` |
| `invalid slug '$1' (must match` | the epic (or slug) is not `^[a-z0-9][a-z0-9-]{1,48}$` | rename it; a backticked value copied from a PRD header fails here on purpose |
| `$dir has uncommitted changes on branch $current; commit or stash them before switching to $branch` | resuming would reset the design branch to origin's tip and discard uncommitted work | commit or stash in the clone, then re-run `openbuilder plan` |
| `an approval for epic $epic is void: an approved artifact changed after it was approved.` | a PRD/RFC/backlog approved in an earlier session changed on disk | re-approve the artifact — see "Un-voiding an approval" below |
| `ob-gate rejected 'verify $epic --all'` | the CLI and `ob-gate` disagree about the command surface | fix the versions of the two scripts together |
| `no local clone at $dir — run '$OB_PROG plan $repo <epic>' first` | dispatch needs the design-branch clone that `plan` creates | `openbuilder plan you/your-repo <epic>` |
| `$backlog/plan.md has no '- epic:' line; dispatch cannot tell which epic gates this slug.` | the card set carries no `- epic: <epic>` bullet (RFC §2) | add the line under the first `# ` heading (backlog/SCHEMA.md) |
| `$dir is on branch $current, not the design branch $design for epic $epic.` | the clone is on the wrong branch — an approval is read from the design branch | `openbuilder plan you/your-repo <epic>` |
| `$backlog has uncommitted or untracked changes in $dir:` | an approval covers committed bytes only, and ob-gate verify cannot see uncommitted files | commit the changes, then re-approve |
| `the recorded backlog approval for $slug no longer matches the files on $design — an artifact changed after it was approved.` | a card was edited after `ob-gate record` (exit 3 from verify) | commit the edit, re-record, dispatch again — see "Un-voiding an approval" |
| `no backlog approval is recorded for $slug in .openbuilder/epics/$epic/state.json.` | this slug was never approved (exit 4) — an approval for another slug does not satisfy it | `(cd <clone> && <control-repo>/local/bin/ob-gate record <epic> backlog <slug>)`, then dispatch again |
| `no backlog approval is recorded` (status `UNAPPR` = `yes`) | rule 4b would decline this plan branch on every poll pass, silently | approve the backlog, or delete the branch |
| `'ob-gate stage $epic dispatched' failed; no plan branch was created` | the stage pointer did not move | investigate `ob-gate` and re-dispatch |
| `refusing to cut` | `state.json` on the design branch still says `stage: backlog` after the stage call — cutting now would carry `stage: backlog`, which rule 4b declines forever | fix the stage ordering bug; the assertion exists to catch it |
| `$design differs from origin/$design after 'ob-gate stage $epic dispatched'; push it before dispatching:` | the local design tip is not on origin, so the audit trail would not survive | `git -C <clone> push origin <design>` |
| `origin/$branch already exists and is not an ancestor of $design; pushing it would rewrite history, which openbuilder never does.` | a leftover plan branch is not an ancestor of the design tip | delete it first: `gh api -X DELETE repos/<repo>/git/refs/heads/<branch>` |
| `usage: $OB_PROG review [--watch] <owner/repo> <pr>` | `review` wants one optional `--watch` and exactly two positionals | `openbuilder review [--watch] you/your-repo <pr>` |
| `$repo#$pr is blocked; a human is required` (exit 4) | the PR carries `openbuilder:blocked` — the agent gave up | read the last comment, fix the blocker, re-request changes |
| `review rounds for $repo#$pr reached $rounds_max (OPENBUILDER_MAX_ATTEMPTS) without a verdict; a human is required` (exit 5) | the watch loop spent its whole round budget with no verdict | intervene by hand; raise `OPENBUILDER_MAX_ATTEMPTS` only after thinking about the cost |
| `usage: $OB_PROG land <owner/repo> <pr>` | `land` wants exactly an owner/repo and a PR number | `openbuilder land you/your-repo <pr>` |
| `$repo#$pr is not labelled $OB_LABEL_PREFIX:approved; land never merges an unapproved pull request.` | `land` refuses to guess | `openbuilder review --watch you/your-repo <pr>`, then `openbuilder approve` |
| `$repo#$pr is $state, not OPEN; there is nothing to land` | the PR is merged/closed already | nothing to do |
| `the head branch of $repo#$pr is '$head', not under $OB_BRANCH_PREFIX/work/; land only handles openbuilder pull requests` | the PR is not one of ours | merge it by hand, if at all |
| `cannot read .openbuilder/backlog/$slug/plan.md on $plan_branch; land cannot tell which epic to clean up` | the plan branch is gone or the backlog is missing | restore the branch before landing |
| `.openbuilder/backlog/$slug/plan.md on $plan_branch has no '- epic:' line; land cannot tell which epic to clean up` | the plan branch lacks the RFC §2 bullet | add `- epic: <epic>` before landing |
| `cannot read .openbuilder/epics/$epic/state.json on $design_branch; land will not delete branches it cannot account for` | missing or malformed epic state; deleting branches on a guess is the one thing land never does | restore `state.json`, or clean up by hand |
| `confirmation did not match \"land $slug\"; nothing was merged and nothing was deleted` | the typed answer was not exactly `land <slug>` | type the exact slug — it is what makes the wrong PR unconfirmable by muscle memory |
| `gh pr merge $pr failed; nothing was deleted` | the merge refused or raced | retry; nothing was touched |
| `instance cleanup failed (exit $rc); prune it by hand:` | the SSM teardown did not finish — the merge and branch deletions already happened | run the two `sudo` commands the warning prints |

### Un-voiding an approval

An approval is void because the **bytes changed** — `ob-gate` records git blob shas and re-checks them,
so there is no flag that suppresses the check and there should not be one. The fix is always to commit
the artifact as it now is and re-record the approval from inside the clone:

```sh
git -C <clone> add <artifact> && git -C <clone> commit -m 'fix: ...'
(cd <clone> && <control-repo>/local/bin/ob-gate record <epic> prd|rfc|backlog <slug>)
```

Then re-run the command that refused. For a backlog slug the re-record also re-commits and re-pushes
`state.json` on the design branch, so a dispatch right after it sees intact bytes.

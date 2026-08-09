# Learnings

Durable, hard-won operational knowledge for everything that runs in openbuilder: the implementer on
the instance, the planner and reviewer on the laptop, and whoever operates the infrastructure.

**Why this file exists.** Every entry below cost real time or real money to discover, and none of them
were catchable by reading code. Instances get rebuilt (a root volume cannot follow its instance to
another availability zone, so a rebuild destroys the disk), models get swapped, laptops change. This
file lives in the control repository precisely so none of that erases what was learned.

**How it reaches the implementer.** `ob-implement` and `ob-respond` inject this file verbatim into
every round's prompt, refreshed from the control repository's remote at the start of the round. So
publishing a new entry here takes effect on the very next round — no code deploy, no `ob-selfupdate`,
no instance restart.

## Rules for editing this file

1. **An entry earns its place by having been observed.** Symptom, cause, rule, and how it was proven.
   No speculation, no "best practices", nothing a linter or a type checker would have caught.
2. **State the rule as an imperative**, so it can be followed without re-deriving the story.
3. **Keep it repo-agnostic.** Knowledge about one target repository belongs in that repository, or in
   the slug's `worklog.md` — not here.
4. **Never delete an entry because it looks obvious.** It looks obvious because it is written down.
   Delete only when it has become false, and say so in the commit message.
5. **The implementer proposes, the reviewer commits.** An implementation round may append a candidate
   entry to the per-round proposal file its prompt names, and it arrives on the pull request for review.
   Only a human, or the reviewer acting for one, edits this file. (This file is injected into that
   prompt verbatim, so it deliberately contains no template placeholders of its own — they would reach
   the model unexpanded.)

Entry shape:

```
### N. Imperative rule, in one line
**Symptom** what you actually see, verbatim where possible.
**Cause** the mechanism, not the guess.
**Rule** what to do instead, every time.
**Proven** how it was demonstrated, and when.
```

---

## Rules the implementer must follow

### 1. Never conflate "I cannot access it" with "it is busy"
**Symptom** `ob-idle-stop: staying up: condition 1 failed — locks held: selfupdate`, forever, on an
instance where nothing was running. It billed seven hours instead of thirty minutes.
**Cause** `ob_lock_held` probed a lockfile by opening it for append inside a subshell. A permission
error made the subshell exit non-zero, which the caller read as "another process holds this lock", so
one root-owned lockfile was indistinguishable from a live job.
**Rule** A probe must fail for exactly one reason. When a check can fail because the resource is busy
*or* because the check itself is broken, separate the two: report the broken-check case loudly and
distinctly, and never let it silently choose the more expensive branch. Ask for the least authority
that still answers the question — a shared, read-only lock still detects an exclusive holder.
**Proven** 2026-08-09 on the instance: free lock, live exclusive holder, released lock, and an
unreadable root-owned lock each produce the correct verdict, the last one with a loud ERROR line.

### 2. Never run `git` as root against a repository owned by someone else
**Symptom** every later `git` command by the service user dies with `Permission denied` on
`.git/FETCH_HEAD` or `.git/index.lock`.
**Cause** `ob-selfupdate` ran as root and fetched into an `openbuilder`-owned clone, leaving
root-owned objects behind.
**Rule** Run `git` as the owning user (`runuser -u <owner> -- env HOME=<home> git …`). Reserve root
for what genuinely needs it, and hand back ownership of anything root creates in a shared directory.
**Proven** 2026-08-09, first real deployment; the same class of bug produced learning 1.

### 3. Exit code 0 is not proof that the work happened
**Symptom** `ob-doctor` blamed "bad key, model id or egress" when the real answer was an empty account
balance.
**Cause** `omp` exits 0 with an empty assistant message when the provider returns a hard HTTP 402.
**Rule** Verify the artefact, not the exit status: assert that the output exists and has the expected
shape, and when a subprocess fails, ask the upstream service for its own error text instead of
guessing. A diagnostic that guesses is worse than one that admits it does not know.
**Proven** 2026-08-09; `ob-doctor` now prints the provider's `.error.message` verbatim.

### 4. Never weaken a check to make it pass
**Rule** No skipped spec, no deleted assertion, no silenced linter, no widened type, no special-cased
input. Fix the cause, or stop and report the blocker precisely. A precise blocker is a good outcome; a
plausible guess is not.
**Why it is here** This is the rule whose violation is cheapest in the moment and most expensive
afterwards, so it is written down rather than assumed.

### 5. Read the permission you actually need, not the one with a familiar name
**Symptom** `ob-doctor` reported every repository unwritable on a healthy installation.
**Cause** it read `.permissions.push` from `GET /repos/{owner}/{repo}`, which describes a **user's**
role. A GitHub App installation token has no user, so that field is always `false`.
**Rule** When an API answers "no", check that the field you read describes the identity you are
actually using. For an App token the authority is the installation's permission set
(`contents=write`), not the repository's user-facing permission block.
**Proven** 2026-08-09; the check now uses repository reachability plus the installation's permissions.

### 16. A guard that infers a fault from elapsed time will accuse the operator
**Symptom** a genuinely queued story sat unstarted for twenty minutes while the waker logged
`REFUSING to start ...: it was launched 6.5 min ago and is already stopped again` every five minutes.
Nothing was wrong: an operator had started the box by hand for an unrelated test and stopped it two
minutes later.
**Cause** the flap guard tried to detect "the instance and the waker disagree" from one observable —
a young `LaunchTime` on a stopped instance. A self-stop after finding no work and a human stop are
indistinguishable by that measure, so the guard blamed a fault that had not happened and blocked real
work for its whole window.
**Rule** Do not infer intent from a clock. Have the party that made the decision record it, and gate on
that record: `ob-idle-stop` now writes `state/last_stop` before stopping, and the guard fires only when
that record is newer than the launch. When the evidence is missing, choose the direction that keeps work
moving — a needless start costs cents, a stranded backlog costs the whole point of the system.
**Proven** 2026-08-09: two consecutive ticks refused a real story with `minutes_since_launch` 6.5 and
11.5; the same situation after the change starts the instance, because no self-stop was recorded.

## Environment truths

### 6. SSM `AWS-RunShellScript` runs `/bin/sh` (dash) on Ubuntu, not bash
**Symptom** `Bad substitution` from a script that runs perfectly in an interactive shell.
**Rule** Do not send bash syntax through SSM directly. Base64-wrap the script and pipe it to `bash` —
`local/bin/obrun` does exactly that, and reads `.openbuilder.local` for the target instance.
**Proven** repeatedly on 2026-08-08 and 2026-08-09, on `${VAR:0:3}` and on `[[ … ]]`.

### 7. cloud-init `runcmd` has no `HOME`
**Symptom** `fatal: $HOME not set` from `git config --global`, and because of `set -e`, a bootstrap
that looked 95% complete while having installed zero systemd units.
**Rule** Never assume an environment variable exists in a non-login, non-interactive context. Resolve
it explicitly (`getent passwd root`) and pass it.
**Proven** 2026-08-08, first boot.

### 8. Canonical's Ubuntu AMIs do not ship the AWS CLI
**Symptom** every `aws ssm get-parameter` fails, so no secret is readable, on an instance whose IAM
role is perfectly correct.
**Rule** Install it in bootstrap, derive the architecture, keep the install idempotent. Do not carry
over assumptions from Amazon Linux, which does ship it.
**Proven** 2026-08-08.

### 9. `terraform output -raw` can print a warning on stdout and still exit 0
**Symptom** the string `Warning: No outputs found` was cached as an AWS region.
**Rule** Validate the *shape* of any value captured from a subprocess before storing or reusing it.
Exit status alone does not tell you that a value is a value.
**Proven** 2026-08-08.

### 10. Starting a stopped EC2 instance can be refused, and its volume cannot move
**Symptom** `InsufficientInstanceCapacity` from `ec2:StartInstances`, repeatedly, for over half an
hour.
**Cause** stopping releases the host slot; starting asks for a new one in the *same* availability
zone, because an EBS volume is AZ-bound. It is not a quota — that is `InstanceLimitExceeded` — and no
other instance is holding anything that could be released.
**Rule** Treat a capacity refusal as expected and transient: log it plainly, leave the work queued,
retry on the next tick, and never let it become an unhandled exception on a schedule. When it
persists, move availability zone (`var.availability_zone`), which replaces the subnet and the
instance — cheap while the disk holds only caches, so move early. Capacity Reservations bill 24/7 and
would defeat stopping when idle.
**Proven** 2026-08-09: `eu-central-1a` refused every start while throwaway probes in `1b` and `1c`
were accepted immediately; the instance was moved to `1b`.

### 11. Force-pushing the control repository breaks the instance's clone
**Symptom** `ob-selfupdate` refuses with "fast-forward failed; history diverged".
**Cause** the clone is advanced with `merge --ff-only`, deliberately, so a rewritten history cannot be
swallowed silently.
**Rule** Do not rewrite published history on the control repository. If you must, reset the instance's
clone by hand afterwards. The refusal is the feature.
**Proven** 2026-08-08, after removing an author line from the public history.

### 12. Review as a human, not as the bot
**Symptom** `ob-respond: no actionable reviewer feedback found on <repo>#<pr>` on a pull request that
visibly carries a review comment and the `openbuilder:changes-requested` label. The round fails, the
attempt counter advances and the slug is labelled `openbuilder:blocked`.
**Cause** `gather_feedback` drops every conversation comment whose author login starts with
`openbuilder`, so the App cannot feed its own words back to itself. A review posted with the App's
installation token is authored by `openbuilder-bot[bot]` and is therefore invisible by design.
**Rule** Post review comments as the human account (`gh`, or the web UI). Reserve the installation
token for what the instance itself does. When a tool ignores input by design, make it say so in the
failure message rather than reporting an empty result.
**Proven** 2026-08-09: the first review round on artemkurylo/openbuilder#1 failed exactly this way; the
same review posted as the human account was collected on the next pass.

### 13. A timer that measures from completion drifts, so no clock second is safe
**Symptom** two consecutive hand-run `ob-idle-stop` invocations, deliberately scheduled 25 and 28
seconds past the minute to dodge the poll pass, both hit `condition 1 failed — locks held: poll`.
**Cause** `openbuilder-poll.timer` uses `OnUnitInactiveSec=60s`, which counts from when the previous
run *finished*, not when it started. A pass that takes ~7 s therefore gives a ~67 s period, and its
start walks forward roughly 7 s every cycle. Aligning to a fixed second aligns to a moving target.
**Rule** Never assume a periodic job starts at a fixed offset. Either read the next start
(`systemctl list-timers`), or retry until the lock is free instead of trying to predict the window.
**Proven** 2026-08-09: poll starts observed at :56, :07, :18, :28 — 11 s of drift per cycle for a
60 s interval and a ~7 s run.

### 14. A file injected verbatim must contain no template syntax
**Symptom** the rendered prompt of the first real round carried a literal `{{LEARNINGS_OUT}}` at line
326, where the surrounding text had every other placeholder substituted.
**Cause** the prompt renderer substitutes scalars but inserts block files **verbatim**, deliberately —
model- and human-authored text must never be interpreted. `LEARNINGS.md` is a block, and its own
editing rules quoted the placeholder by name, so the placeholder survived into the model's context.
**Rule** When a document is included verbatim into a template, it may describe a placeholder but must
never spell one. Grep the rendered artefact for unsubstituted syntax; the count should be zero.
**Proven** 2026-08-09: `grep -c "{{[A-Z_]*}}"` on the round-001 prompt returned 1, and named the line.

### 15. A GitHub App installation token lasts an hour; bind it per operation
**Symptom** a long session started returning HTTP 401 on calls that had worked for an hour, while a
freshly minted token in the same process worked immediately.
**Cause** installation tokens expire after one hour. Worse, the helper captured the token in a
default argument, which most languages evaluate once at definition time, so every later call kept
using the first token no matter how many times it was re-minted.
**Rule** Treat a short-lived credential as per-operation state, never as a default or a cached
module-level constant. `ob-token` already re-mints and caches with an expiry — go through it rather
than holding a token yourself.
**Proven** 2026-08-09: label calls returned 401 mid-session and succeeded on the next line after
re-minting.

### 17. A hook installed in one repository must be a no-op, not a wall, in every other

**Symptom** `/tmp/shared-hooks/pre-commit: line 4: /tmp/other-repo/local/bin/ob-scrub-check: No such file or directory` (exit 127) — a hook installed in one repository dying in every other repository that shares the same `core.hooksPath`.
**Cause** `git rev-parse --git-path hooks` honours `core.hooksPath`. When that setting points at a shared directory (a global `~/.githooks` is the common setup), one hook file runs in every repository, and a hook body that references `local/bin/...` relative to the working tree resolves it against whichever repository happens to be committing.
**Rule** Treat the resolved hooks directory like any shared location: before writing to it, verify it lies inside the repository's own git directory (`git rev-parse --git-common-dir`) and refuse otherwise, naming `--force` for the deliberate case; and write the hook so it resolves its own repository (`git rev-parse --show-toplevel`) and exits 0 quietly when the command it would run is not present there.
**Proven** 2026-08-09 on the instance while addressing the review of `ob-install-hooks` (artemkurylo/openbuilder#2): a hook body of `exec local/bin/ob-scrub-check --staged` installed under `core.hooksPath=/tmp/shared-hooks` died in an unrelated repository with exactly the quoted error; after the fix, the same hook exits 0 in a repository without the tool and still refuses a staged deny-list match in its own repository.

### 18. A deploy that is allowed to decline must be verified, not assumed
**Symptom** a change was committed, pushed and "deployed", yet the behaviour it added never happened.
The deploy had logged `ob-selfupdate: jobs are running (poll); skipping self-update for now` — one line,
exit 0, easy to read as success.
**Cause** `ob-selfupdate` deliberately declines while any job lock is held, because swapping scripts
under a running round would be worse. The poll timer takes that lock every 60 seconds, so a single
attempt on a busy instance is a coin flip. Half of a two-part change was live — the Lambda that read a
record — while the half that wrote it was not.
**Rule** After deploying, assert the effect, not the exit status: grep the installed file for the new
symbol, or exercise the behaviour. Retry a decline in a loop until it reports `self-update complete`.
Treat "skipped" as a failure to deploy, because that is what it is.
**Proven** 2026-08-09: `/openbuilder/state/last_stop` was still `ParameterNotFound` after a stop that
should have written it; the installed `ob-idle-stop` had none of the new code until selfupdate was
retried, after which the record appeared.

### 19. A linter that is absent is not "lint passed"
**Symptom** `command -v shellcheck` printed nothing on a fresh build box, and `make lint` answered `shellcheck not installed — skipping lint.` and exited **0** — so a story whose acceptance names a shellcheck run could not execute it, and the graceful skip read exactly like a pass.
**Cause** the target degrades deliberately when the tool is missing, and `apt-get install` needs root a build box may not grant, so the missing tool is not one command away.
**Rule** When acceptance names a linter, fetch it yourself — static release binaries run from `~/.local/bin` without root — and run the acceptance command verbatim. Never let a graceful-skip branch stand for the check, and never report a skip as a pass.
**Proven** 2026-08-09, round 001 of `plan-workflow-00-host`: shellcheck 0.10.0 static aarch64 extracted into `~/.local/bin` and ran `shellcheck -x -S warning` on both edited scripts. Proposed by the round that earned it.

### 20. `obrun` reads its script from stdin; pass it as an argument and SSM cheerfully runs nothing
**Symptom** `obrun sed -i ... ; grep ...` returned `Success` with an empty stdout and an empty stderr, and the file it was supposed to edit was untouched. Re-running "to be sure" produced the same confident `Success`.
**Cause** `local/bin/obrun` builds its payload with `payload="$(base64 | tr -d \n)"` — from **stdin**, not from `$1`. An argument is ignored, `base64` reads EOF, and SSM faithfully executes an empty script, which succeeds. The wrapper then prints `[Status,StandardOutputContent,StandardErrorContent]`, i.e. `Success` and two empty fields.
**Rule** Pipe the script in: `printf %s\n cmd | obrun`, or use `obrun -f file`. And when a remote command reports success, assert the **effect** — grep the file, re-read the value — never the status. A tool that cannot fail is a tool that is not running.
**Proven** 2026-08-09, trimming `OPENBUILDER_REPOS` in `/opt/openbuilder/etc/openbuilder.env`: two argument-style invocations reported `Success` and changed nothing; the stdin form printed the real BEFORE/AFTER and the poller then listed one repo instead of three.

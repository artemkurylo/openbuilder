# openbuilder

A control plane for autonomous coding that splits the job across two machines and uses GitHub as the
message bus. Your laptop runs a strong, expensive model (Claude Opus 5 via `omp`) to do the two things
humans are bad at delegating — deciding *what* to build and judging whether the result is acceptable.
A small arm64 EC2 instance — off by default — runs a cheap, fast model (DeepSeek V4 Flash via OpenRouter)
to do the typing: it picks up plan branches, implements the stories, opens a pull request, and answers
review rounds until the reviewer approves. There is no webhook, no queue, no inbound port and no SSH —
the instance polls GitHub every 60 seconds and stops itself when there is nothing to do, and a scheduled
Lambda (the waker) starts it again when GitHub grows work. The backlog is the trigger: nothing has to be
running, and nobody has to open a terminal, for the loop to advance. Every artifact of every step is a
branch, a commit, a PR comment or a label, so the whole system is auditable with `git log` and `gh`.

## How it flows

```mermaid
flowchart TD
    A["Laptop: openbuilder plan<br/>Opus 5 writes story cards"] --> B["Laptop: openbuilder dispatch<br/>starts instance, pushes openbuilder/plan/slug"]
    B --> C["GitHub: plan branch + label openbuilder:queued"]
    C --> D["Instance: ob-poll every 60s<br/>rule 5 matches"]
    D --> E["Instance: ob-implement<br/>DeepSeek V4 Flash writes code"]
    E --> F["GitHub: PR from openbuilder/work/slug<br/>label openbuilder:awaiting-review"]
    F --> G["Laptop: openbuilder review<br/>Opus 5 reads the diff"]
    G -->|changes needed| H["Laptop: openbuilder request-changes<br/>label openbuilder:changes-requested"]
    H --> I["Instance: ob-poll rule 6<br/>ob-respond, fresh session + worklog"]
    I --> F
    G -->|looks good| J["Laptop: openbuilder approve<br/>label openbuilder:approved"]
    J --> K["Human: gh pr merge --squash"]
    F -.->|nothing to do for 30 min| L["Instance: ob-idle-stop<br/>instance stops itself"]
    L -.-> M["Waker Lambda: every 5 min<br/>ob-poll's rule table, evaluated from outside"]
    M -.->|actionable and stopped| N["ec2:StartInstances<br/>~30-45 s to a live poll timer"]
    N -.-> D
```

Three roles, three different cost profiles:

| Role | Where | Model | Job |
|---|---|---|---|
| planner | laptop | `amazon-bedrock/us.anthropic.claude-opus-5` | turn an idea into backlog story cards, push a plan branch |
| implementer | EC2 `t4g.medium` | `openrouter/deepseek/deepseek-v4-flash-0731` | implement stories, open a PR, answer review rounds |
| reviewer | laptop | `amazon-bedrock/us.anthropic.claude-opus-5` | review the PR, post comments, gate the merge |

### Power: who turns it on, who turns it off

The instance is **off by default**, and neither half of the power decision needs a human in it:

| Direction | Who decides | Condition |
|---|---|---|
| off | `ob-idle-stop`, on the instance, every 5 min | no lock held, `ob-poll --dry-run` finds nothing actionable, and nothing written under `log/` or `state/` for `OPENBUILDER_IDLE_STOP_MINUTES` (default 30) |
| on | `openbuilder-waker`, a Lambda invoked by EventBridge every `waker_interval_minutes` (default 5) | GitHub has actionable work **and** the instance state is exactly `stopped` |

Only the instance may power off, because it is the only party that knows whether a job is mid-flight.
Only the waker can power on, because a stopped instance cannot poll. The waker never stops anything.

**Actionable** is the same rule table `ob-poll` evaluates on the instance, read from outside with the
GitHub App token: a `openbuilder/plan/<slug>` branch with no PR whose head is `openbuilder/work/<slug>`
(rule 5), or such a PR labelled `openbuilder:changes-requested` (rule 6). Not actionable:
`openbuilder:approved` (rule 2, and it wins over `changes-requested`), `openbuilder:blocked` (rule 3),
no relevant label at all (rule 7 — the ball is with the reviewer), and, when there is no PR yet, an open
issue titled `openbuilder blocked: <slug>` carrying `openbuilder:blocked` (rule 4's no-PR form). Rules 1
(a lock is held) and 4 (the attempt budget) are instance-local state the Lambda cannot see; rule 4 is
covered anyway, because exhausting the budget is precisely what makes the instance apply
`openbuilder:blocked`. Without that check one permanently failing slug would wake the instance every
five minutes forever.

A **flap guard** stops the waker fighting the instance: it refuses to start an instance whose
`LaunchTime` is younger than `waker_flap_guard_minutes` (default 20) when that instance is already
`stopped` again. `ob-idle-stop` needs 30 minutes of quiet before it stops, so a legitimate cycle can
never be that short — a shorter one means the instance and the waker disagree about whether there is
work, which is a bug to investigate, not a reason to pay for a start every five minutes. The refusal is
logged in full.

Every pass ends in exactly one `outcome`, which is the whole of the waker's observable behaviour:

| `outcome` | Meaning |
|---|---|
| `nothing-to-do` | no plan branch in any repo is actionable |
| `instance-running`, `instance-pending`, `instance-stopping` | work exists, but the instance is not `stopped`: it already owns the work, or it is mid-shutdown and the next tick will pick it up |
| `flap-guard` | work exists and the instance is stopped, but it stopped again too soon after launching — see above |
| `started` | `ec2:StartInstances` accepted; the poll timer is live in ~30-45 s |
| `start-refused` | EC2 declined transiently (`InsufficientInstanceCapacity`, `Unsupported`, `RequestLimitExceeded`) — the work stays queued in GitHub and the next tick retries, so this is logged plainly rather than raised. Any other error still raises, which keeps the function's error metric meaningful |

The laptop CLI is unchanged: `dispatch`, `review`, `request-changes`, `shell`, `doctor` and `cost` still
call `aws ec2 start-instances` and wait, so an interactive command never talks to a stopped instance. It
is simply no longer *required*. Label a PR `openbuilder:changes-requested` from the GitHub web UI on a
phone and the instance is up within `waker_interval_minutes` and has pushed its answer before you are
back at a keyboard.

## Quickstart: zero to first merged PR

Everything below is copy-pasteable. Replace `you/your-repo` with the repo you want the agent to work in.

### 0. Prerequisites

| Tool | Minimum | Check |
|---|---|---|
| Terraform | `>= 1.6.0` | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| GitHub CLI | any recent | `gh auth status` |
| omp | `17.2.11` | `omp --version` |
| `jq` | 1.6+ | `jq --version` |
| `git` | any recent | `git --version` |
| Session Manager plugin | any | `session-manager-plugin --version` |
| An AWS account | — | see below |
| An OpenRouter API key | — | https://openrouter.ai/keys |

The Session Manager plugin is what makes `openbuilder shell` work; without it every other subcommand
still functions, because they use `ssm send-command` rather than an interactive session.

```sh
brew install --cask session-manager-plugin        # macOS
```

#### AWS credentials for the deploy

Use a **dedicated profile** for this project. Do not rely on whatever `AWS_PROFILE` your shell happens
to export — that is frequently a work SSO profile for an unrelated account, and Terraform obeys it.

`aws configure sso` is **not** the command you want: that is for IAM Identity Center, which most
personal accounts do not have. If the only SSO start URL on your machine belongs to an employer, it
points at exactly the account this must not deploy into.

##### Recommended: `aws login`, no stored secret

AWS CLI 2.32.0+ can mint temporary credentials from a browser sign-in and refresh them automatically,
so no long-lived access key ever lands on disk. This module requires `hashicorp/aws` **>= 6.23.0** for
it, which is what `versions.tf` pins — support was added in that release.

1. Console → **IAM → Users → Create user**, `openbuilder-deploy`, **with** console access (you sign in
   as this user in the browser).
2. **Attach policies directly:** `AdministratorAccess` **and** `SignInLocalDevelopmentAccess`.
   The second is what permits `aws login` itself; the first is because this module creates a VPC, an
   EC2 instance, an IAM role and instance profile, four SSM parameters and a budget.
   `PowerUserAccess` is *not* enough — it cannot create the instance role.
3. Declare the profile in `~/.aws/config`. **Substitute your real 12-digit account id** — it is in the
   console's top-right account menu. The literal `ACCOUNT_ID` below will not work:

```ini
[profile openbuilder-deploy]
login_session = arn:aws:iam::ACCOUNT_ID:user/openbuilder-deploy
region        = eu-central-1
```

4. In the browser, sign in **as `openbuilder-deploy`**, not as the account root. Then:

```sh
aws login --profile openbuilder-deploy
aws sts get-caller-identity --profile openbuilder-deploy   # must be YOUR account id
```

`aws login` derives the session from whoever is signed into the browser. If you are signed in as root
it will offer to rewrite the profile to `arn:aws:iam::<id>:root` — answer **n**, switch the browser to
the IAM user, and rerun. Root works, but it cannot be scoped or revoked granularly.

The session lasts up to 12 hours; re-run `aws login` when it lapses, and `aws logout --profile
openbuilder-deploy` to end it early. Tokens are cached in `~/.aws/login/cache/`, never in
`~/.aws/credentials`. A `terraform apply` running longer than the session will fail on expiry — not a
concern here, since this module applies in a couple of minutes.

##### Fallback: static access key

If you would rather not use `aws login`, create the same user without console access, skip
`SignInLocalDevelopmentAccess`, then **Security credentials → Create access key → CLI** and run
`aws configure --profile openbuilder-deploy`, answering with the key, the secret, `eu-central-1` and
`json`. This works with any provider version. The tradeoff is a long-lived secret sitting in
`~/.aws/credentials`, which is precisely what the console warns you about.

##### Either way

Put the profile name in **two** places, so neither Terraform nor the CLI can wander into another
account: `aws_profile` in `infra/terraform.tfvars`, and `OPENBUILDER_AWS_PROFILE` in
`.openbuilder.local`.

Your laptop separately needs Amazon Bedrock access to `us.anthropic.claude-opus-5`, because the planner
and reviewer run locally against that model. That is a different account and region from the instance,
and it keeps using your normal `AWS_PROFILE`/`AWS_REGION` — the CLI never touches those.

### 1. Get this repo onto GitHub

Cloud-init clones the control repo onto the instance over plain HTTPS, so the simplest setup is a public
control repo.

```sh
git clone https://github.com/artemkurylo/openbuilder.git
cd openbuilder
```

Building it from scratch instead? From the repo root:

```sh
make repo-create
```

> If you make the control repo private, add it to the GitHub App installation in step 2 as well —
> the first cloud-init clone will fail (logged, not fatal) and `ob-selfupdate` will pick it up later
> with an App token.

### 2. Create the GitHub App

Follow **[docs/github-app-setup.md](docs/github-app-setup.md)**. It walks the exact click-path and ends
with three values you will need in step 5:

- the numeric **App ID**
- the numeric **installation ID**
- the downloaded **private key PEM**

Permissions are Contents RW, Pull requests RW, Issues RW, Metadata RO, Workflows RW. No webhook.

### 3. Initialise Terraform

```sh
make init
```

This runs `terraform init` in `infra/` and creates `infra/terraform.tfvars` from
`infra/terraform.tfvars.example` if it does not exist yet.

### 4. Fill in `infra/terraform.tfvars`

Open `infra/terraform.tfvars` and set at minimum:

```hcl
region             = "eu-central-1"
repos              = ["you/your-repo"]
control_repo       = "artemkurylo/openbuilder"
budget_alert_email = "you@example.com"
```

`repos` is the allowlist. The instance will only ever look at plan branches in these repositories, and the
App installation token is scoped to them. Everything else has a sane default (`t4g.medium`, 40 GiB gp3,
`/openbuilder` SSM prefix, 45m max runtime, 6 max attempts, 30 min idle stop, `monthly_budget_usd = 20`).

The waker's four knobs are defaulted too, and documented in `infra/variables.tf`. Override them in
`terraform.tfvars` only when the defaults do not fit:

```hcl
# waker_enabled            = true   # false disables the schedule and hands power-on back to the laptop
#                                   # CLI; the Lambda stays deployed and manually invokable
# waker_interval_minutes   = 5      # 1-60; the worst-case delay between a label landing on GitHub and
#                                   # the instance booting
# waker_flap_guard_minutes = 20     # refuse to start an instance that stopped again this recently; must
#                                   # stay below idle_stop_minutes or it would block legitimate wakes
# waker_log_retention_days = 14     # it logs a few lines every interval, forever
```

The budget that `budget_alert_email` arms covers **AWS spend only** — OpenRouter bills the model
separately and the AWS budget can never see it. Set a hard spend limit on the OpenRouter key too.

### 5. Create the infrastructure

```sh
make plan-tf     # read the plan; expect a VPC, one public subnet, an IGW, an SG with zero ingress,
                 # an IAM role, four SSM parameters, one EC2 instance, and the waker's seven resources:
                 # the Lambda, its role and inline policy, its log group, the EventBridge rule, that
                 # rule's target, and the invoke permission
make apply
```

Terraform creates the four SSM parameters with the placeholder value `REPLACE_ME` and then
**never touches their contents again** (`lifecycle { ignore_changes = [value] }`).

### 6. Put the three secrets into SSM

```sh
make secrets
```

That prints the exact commands with placeholders. Run them with your real values:

```sh
aws ssm put-parameter --overwrite --name /openbuilder/openrouter_api_key \
  --type SecureString --value 'sk-or-v1-REPLACE_ME' --region eu-central-1

aws ssm put-parameter --overwrite --name /openbuilder/github_app_id \
  --type String --value 'REPLACE_ME' --region eu-central-1

aws ssm put-parameter --overwrite --name /openbuilder/github_app_installation_id \
  --type String --value 'REPLACE_ME' --region eu-central-1

aws ssm put-parameter --overwrite --name /openbuilder/github_app_private_key \
  --type SecureString --value "$(cat ~/Downloads/openbuilder-bot.private-key.pem)" --region eu-central-1
```

Nothing secret is ever written to `/opt/openbuilder/etc/openbuilder.env`. The runner fetches these with
`aws ssm get-parameter --with-decryption` at job start and exports them into the `omp` child process only.

### 7. Point the laptop CLI at the instance

```sh
cat > .openbuilder.local <<'EOF'
OPENBUILDER_INSTANCE_ID=i-REPLACE_ME
OPENBUILDER_REGION=eu-central-1
OPENBUILDER_TARGET_REPO=you/your-repo
# Only needed when your shell's AWS_PROFILE points somewhere else — e.g. at an
# account that just serves the local planner/reviewer model. EC2/SSM calls for
# the instance use this profile; the local `omp` session is left completely alone.
OPENBUILDER_AWS_PROFILE=your-personal-profile
EOF
```

The CLI deliberately ignores `AWS_REGION` and `AWS_DEFAULT_REGION` when deciding where the instance lives:
those belong to your local model provider and are frequently a different region entirely. Only
`OPENBUILDER_REGION`, the cached value, or the `region` Terraform output can set it.

`terraform output instance_id` (or the tail of `make apply`) gives you the instance id. Then put the CLI
on your `PATH`:

```sh
export PATH="$PWD/local/bin:$PATH"
```

### 8. Verify the instance, then the waker

```sh
make doctor
```

`ob-doctor` runs on the instance over SSM and prints a PASS/FAIL table: binaries and versions, env file
parsed, every SSM parameter readable, App token mints and `gh api user` works, every repo in
`OPENBUILDER_REPOS` reachable and writable, `OPENROUTER_API_KEY` valid via a one-token `omp` call, both
systemd timers active, disk free. **Do not continue until every row is PASS.**

`ob-doctor` runs on the instance, so it cannot see the waker. Check that one by hand, once:

```sh
eval "$(cd infra && terraform output -json waker | jq -r .invoke)"
```

At this point the backlog is empty, so it prints
`{"actionable": 0, "slugs": [], "started": false, "outcome": "nothing-to-do"}` and starts nothing. This
is not a dry run — invoked later, with a plan branch waiting and the instance stopped, it will do its job
and start the instance. The same Terraform output carries the matching `aws logs tail` command under
`.logs`; every pass prints one `DECISION` line per plan branch, in the shape `ob-poll` logs its own.

### 9. Plan a change

```sh
openbuilder plan you/your-repo healthz-endpoint
```

Opus 5 runs locally with the planner agent and scaffolds
`.openbuilder/backlog/healthz-endpoint/` — a `plan.md` plus one `story-NN-*.md` per slice. Read them.
Edit them. This is the highest-leverage five minutes in the whole loop; the remote agent will do exactly
what these cards say and nothing more. The contract is [backlog/SCHEMA.md](backlog/SCHEMA.md), and
[backlog/example/plan.md](backlog/example/plan.md) plus its story card is a filled-in pair to compare
against.

### 10. Dispatch

```sh
openbuilder dispatch you/your-repo healthz-endpoint
```

This starts the instance and waits for it, commits the backlog directory, pushes
`openbuilder/plan/healthz-endpoint`, and makes sure the six `openbuilder:*` labels exist in the repo.

### 11. Wait for the PR

```sh
openbuilder status you/your-repo
```

Within ~60 seconds `ob-poll` matches rule 5 (no PR with head `openbuilder/work/healthz-endpoint`) and
runs `ob-implement`. The label goes `openbuilder:queued` → `openbuilder:in-progress` →
`openbuilder:awaiting-review`, and a PR appears whose title is the first `# ` heading of `plan.md`.
Watch it happen with:

```sh
openbuilder logs -f
```

### 12. Review

```sh
openbuilder review you/your-repo 42
```

Opus 5 reads the diff, the plan, the worklog and the repo, then posts line-anchored comments and a
verdict. Act on the verdict:

```sh
openbuilder request-changes you/your-repo 42   # -> instance runs ob-respond on the next poll
```

Each `request-changes` costs one attempt. After `OPENBUILDER_MAX_ATTEMPTS` (6) the instance labels the PR
`openbuilder:blocked` and stops touching it.

### 13. Approve and merge

```sh
openbuilder approve you/your-repo 42
gh pr merge 42 --repo you/your-repo --squash --delete-branch
```

`openbuilder:approved` is the instance's stop sign: rule 2 in the state machine skips that slug forever.
**Only a human merges.** The remote agent is blocked from merging, force-pushing and pushing to a
default branch by the guardrails hook, and never has a reason to try.

Thirty minutes later `ob-idle-stop` powers the instance down and your spend drops to the EBS volume. It
comes back up on its own the next time GitHub has work for it.

## The daily loop

Once the setup above is done, a normal day is four commands:

```sh
openbuilder plan     you/your-repo add-rate-limit   # think, then edit the story cards
openbuilder dispatch you/your-repo add-rate-limit   # starts the instance, pushes the plan branch
openbuilder review   you/your-repo 43               # Opus 5 reviews; you read its verdict
openbuilder approve  you/your-repo 43               # then gh pr merge
```

`plan` and `review` are the two that genuinely need your laptop — that is where Opus 5 runs. `dispatch`
pushes a branch and `approve` moves a label, and doing either from the GitHub web UI works identically,
because the waker watches the same branches and labels the CLI would have touched.

Everything else is observation:

| Command | What it does |
|---|---|
| `openbuilder status [owner/repo]` | table of slugs, branches, PRs, labels, last action |
| `openbuilder logs [-f]` | tail `/opt/openbuilder/log/openbuilder.log` over SSM |
| `openbuilder cost` | sum `.message.usage.cost.total` across the instance's `run.ndjson` files |
| `openbuilder doctor` | run `ob-doctor` on the instance |
| `openbuilder shell` | `aws ssm start-session` onto the instance |
| `openbuilder start` / `openbuilder stop` | instance power, by hand |

You can queue several slugs at once. `ob-poll` takes **one action per slug per pass** and holds a
per-slug lock, so parallel plan branches make progress round-robin instead of stampeding.

## Learnings

`LEARNINGS.md` at the root of this repository is the durable store of operational knowledge — the things
that cost real time or real money to discover and that no linter would have caught. Every entry is
**Symptom / Cause / Rule / Proven**, and `ob-implement` and `ob-respond` inject the whole file into every
round's prompt as hard rules the implementer must follow.

**Publishing one is a push.** The file is read from this repository's *remote* at the start of every round, so:

```sh
$EDITOR LEARNINGS.md      # add an entry, following the rules at the top of the file
git commit -am 'learnings: never conflate "cannot access it" with "it is busy"'
git push
```

The next round has it — for every slug in every repo in `repos` at once, with no `ob-selfupdate`, no restart
and no `terraform apply`. If the remote is unreachable the round falls back to the instance's own clone,
then to the copy `bootstrap.sh` installed; with none of those it runs without learnings and logs that it
did. A missing learnings file degrades a round, it never fails one.

**Proposing one is the agent's job; committing it is yours.** A round that observed something durable
appends a candidate to a per-round file — the only path outside its worktree it is allowed to write — and
the wrapper copies it into `.openbuilder/backlog/<slug>/worklog.md` under **Learnings proposed this round**,
committed on the work branch, so it lands in the pull request you are already reviewing. Nothing the agent
writes reaches `LEARNINGS.md` by itself: only a human, or the reviewer acting for one, edits that file. Most
rounds propose nothing, which is the expected outcome, not a failure.

Repo-specific knowledge does not go there — that belongs in the slug's `worklog.md`. The reasoning behind
the remote-first read, the fallback chain and the propose/accept split is in
[docs/architecture.md](docs/architecture.md#3-the-learnings-store).

## What it costs

Approximate `eu-central-1` on-demand pricing, 730 hours/month. The `t4g.medium` hourly rate is verified
against AWS's published EU (Frankfurt) pricing; the gp3 rate is **approximate and unverified**. See
[docs/cost.md](docs/cost.md) for the full arithmetic.

| Item | Assumption | Monthly (approx.) |
|---|---|---|
| EC2 `t4g.medium`, always on | 730 h @ $0.0384/h (verified) | ~$28.03 |
| EC2 `t4g.medium`, idle auto-stop | 240 h @ $0.0384/h (verified) | ~$9.22 |
| Public IPv4 address | ~$0.005/h while running, 240 h | ~$1.20 |
| EBS 40 GiB gp3 | ~$0.095/GB-month (approximate), billed 24/7 while stopped | ~$3.80 |
| DeepSeek V4 Flash tokens | 20 stories @ 350k in / 45k out | ~$0.79 |
| EventBridge `rate(5 minutes)` + `openbuilder-waker` Lambda + its log group | free tier | ~$0.00 |
| SSM Session Manager, Parameter Store (standard), KMS, Budgets, CloudWatch metrics | — | ~$0.00 |
| **Total with idle auto-stop** (8 h/day awake, assumed) | 240 h | **~$15.01/mo** |
| **Total always-on** (730 h) | 730 h | **~$36.27/mo** |

The model is not the expensive part. The instance is — which is why `ob-idle-stop` exists on one side and
the waker on the other, and why there is no NAT gateway (~$32/mo) or interface endpoint pair (~$22/mo) in
the design. Auto-stop does not reduce what the waker costs, and does not need to: it runs while the box
is stopped, which is the point, and a scheduled EventBridge rule plus ~8.6k invocations a month at 256 MB
sits far inside the perpetual free tier either way. The 240 h row is 8 h/day × 30 days, an
assumption rather than a measurement — awake hours track the backlog, not your working day.

The gp3 volume is the one line auto-stop cannot touch: $3.80/month whether the instance runs or not, which
is the floor for a month with no work in it. Getting to $0 would mean terminating the instance rather than
stopping it, and that throws away the warm clones and `node_modules` that make a wake 30-45 seconds
instead of a 2-4 minute cold build. Not worth $3.80.

The default `monthly_budget_usd = 20` is enough for an auto-stopping instance (~$14.22 of AWS spend, 71% of
budget, so the 80% alert at $16 never fires) and **not** enough always-on (~$35.48 of AWS spend). Either
way the budget covers **AWS spend only** — the DeepSeek tokens are billed by OpenRouter and are invisible
to it.

## Repo layout

```
openbuilder/
├── README.md                 this file: what it is, quickstart, daily loop
├── LEARNINGS.md              durable operational knowledge, injected into every round's prompt
├── Makefile                  targets: help init plan-tf apply destroy secrets doctor shell logs status fmt lint scrub repo-create
├── docs/                     architecture, day-2 runbook, GitHub App setup, cost math
├── infra/                    Terraform: VPC, public subnet, IAM, SSM params, instance, budget
├── infra/templates/          cloud-init template that renders openbuilder.env and calls bootstrap.sh
├── infra/waker.tf            the power-on half: EventBridge rule, Lambda, its IAM role and log group
├── runner/                   everything that runs ON the instance
├── runner/bin/               ob-common.sh, ob-token, ob-poll, ob-implement, ob-respond, ob-idle-stop, ob-doctor, ob-selfupdate
├── runner/systemd/           the poll timer (60s) and the idle timer (5m) and their oneshot services
├── runner/prompts/           implement.md / respond.md templates fed to omp with {{PLACEHOLDER}} markers
├── waker/                    the waker Lambda, stdlib only: rs256.py (RSA-SHA256 signing), github.py (the actionable predicate), handler.py
├── agent/remote/             omp config + implementer agent installed to /opt/openbuilder/.omp
├── agent/local/              omp planner + reviewer agents and their skills, for your laptop
├── agent/hooks/              pre-tool-call guardrails hook: no merge, no force-push, no push to main
├── backlog/                  SCHEMA.md — the story-card contract — plus a filled-in example
├── local/bin/                the `openbuilder` laptop CLI
└── local/bin/ob-scrub-check  pre-publish check: no private identifiers in the tree, the index or history
```

## Before you push: `make scrub`

Everything in this repository is public, and the plan text and review comments that flow through it are
processed by a third-party model. Two targets keep that honest:

| Target | What it does |
|---|---|
| `make scrub` | `local/bin/ob-scrub-check` over the tracked working tree, then over every commit (`--history`, which walks `git rev-list --all` — slow and thorough). Exits non-zero on any match |
| `make lint` | `shellcheck -x -S warning` over `runner/bootstrap.sh`, `runner/bin/*` and `local/bin/*`; skipped with a note when shellcheck is not installed |

`ob-scrub-check` matches an extended-regex deny list, case-insensitively — employer and client names,
internal hostnames, cloud account ids, work email domains, the parent directories of your checkout —
against the working tree, the index (`--staged`) or all of history (`--history`). It reports a path and a
match count and **never the matching text**, because a check that echoes the string it protects has just
leaked it into your terminal and your scrollback.

**The deny list is not in this repo**, because the patterns are themselves the sensitive part. Create it
once — `.scrub-deny` is gitignored:

```sh
cat > .scrub-deny <<'EOF'
# one extended regex per line; blank lines and # comments are ignored.
# Substitute the real strings — placeholders match nothing.
<employer-or-client-name>
internal\.<their-domain>\.(net|com)
@<their-domain>\.(com|net)
<your-12-digit-aws-account-id>
/Users/[a-z]+/Development/<their-name>
EOF

make scrub
```

Set `OPENBUILDER_SCRUB_DENY=/path/to/list` to share one list across several repositories. With no list at
all the check prints how to create one and exits 0, so a fresh clone is never blocked by it. A match that is
already in published history needs the history rewritten, not just another commit — which is the argument
for running `make scrub` before the first push, not after.

Write the literal strings you are hiding, not generic shapes: a bare `[0-9]{12}` for "an account id" matches
the checksums in `infra/.terraform.lock.hcl` and the `DigestInfo` constant in `waker/rs256.py`, and a check
that cries wolf gets skipped.

## Troubleshooting

Full playbook in [docs/runbook.md](docs/runbook.md). The fast table:

| Symptom | Likely cause | Command to run |
|---|---|---|
| `openbuilder dispatch` pushed but no PR after 5 min | instance stopped, or poll timer not firing | `openbuilder status` then `openbuilder start`, then `openbuilder shell` and `systemctl list-timers 'openbuilder-*'` |
| A label applied in the GitHub web UI never woke the instance | waker disabled (`waker_enabled = false`), its schedule, SSM access or App credentials broken, or EC2 short of capacity in the subnet's AZ (`outcome: start-refused`, retried every tick) | `eval "$(cd infra && terraform output -json waker \| jq -r .invoke)"`, then the `.logs` command from the same output |
| Waker logs `REFUSING to start` | flap guard: the instance was `stopped` again within `waker_flap_guard_minutes` of launching, so it and the waker disagree about whether there is work | `openbuilder start`, then `openbuilder shell` and `sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run` |
| PR stuck on `openbuilder:in-progress` | job died mid-run, stale lock, or `OPENBUILDER_MAX_RUNTIME` hit | `openbuilder logs` then `openbuilder shell` and `ls -l /opt/openbuilder/run/` |
| `openbuilder:blocked` appeared | max attempts reached, or a hard failure — the reason is in a PR comment, or in a `openbuilder blocked: <slug>` issue if it failed before the PR existed | `gh pr view <pr> --repo you/your-repo --comments` |
| No commits, agent "explained" instead | story card was ambiguous; the agent is told to stop rather than guess | read `.openbuilder/backlog/<slug>/worklog.md` on the work branch, tighten the card, re-dispatch |
| `gh` calls fail with 401 | App token expired or the App is not installed on that repo | `openbuilder shell` then `sudo -u openbuilder /opt/openbuilder/bin/ob-doctor` |
| omp exits instantly, no tokens spent | bad or out-of-credit `OPENROUTER_API_KEY` (429 / 402) | `openbuilder doctor`, then re-put `/openbuilder/openrouter_api_key` |
| Instance never stops, bill keeps growing | idle timer not firing, work is genuinely queued, or a lockfile in `run/` the service user cannot open — logged as `cannot open lockfile ... treating it as NOT held`, and repaired by `ob-selfupdate` | `openbuilder shell` then `sudo -u openbuilder /opt/openbuilder/bin/ob-poll --dry-run` and `ls -l /opt/openbuilder/run/` |
| Disk full, git operations fail | accumulated worktrees, caches and `run.ndjson` files | `openbuilder shell` then `df -h /opt/openbuilder` |
| Instance running old scripts after a control-repo push | instance has not self-updated | `openbuilder shell` then `sudo -u openbuilder /opt/openbuilder/bin/ob-selfupdate` |

One thing that looks like a fault and is not: **`openbuilder logs` is empty on an idle instance.** Only real
work writes to `/opt/openbuilder/log/openbuilder.log`; uneventful poll passes go to the journal only, on
purpose, because idle auto-stop watches that file's mtime. For the noisy per-decision view use
`openbuilder shell` and
`sudo journalctl -u openbuilder-poll.service --since today | grep DECISION`.

## Where to read next

- [docs/architecture.md](docs/architecture.md) — components, the full state machine, the learnings store,
  the sequence diagram, the design decisions and their tradeoffs, and the security model.
- [docs/github-app-setup.md](docs/github-app-setup.md) — one-time identity setup.
- [docs/runbook.md](docs/runbook.md) — symptom-driven day-2 operations.
- [docs/cost.md](docs/cost.md) — the money, itemised.
- [LEARNINGS.md](LEARNINGS.md) — the operational knowledge every round is handed, and the rules for adding
  to it.
- [backlog/SCHEMA.md](backlog/SCHEMA.md) — how to write a story card the remote agent can actually execute.

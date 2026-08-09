# Cost

**Every AWS price in this document is either verified against the AWS pricing feed or marked
approximate.** They are `eu-central-1` on-demand prices and they drift; check
<https://aws.amazon.com/ec2/pricing/on-demand/> and
<https://aws.amazon.com/ebs/pricing/> for the authoritative numbers in your region. It matters which is
which:

- the `t4g.medium` on-demand rate of **$0.0384/hour is verified** — read from AWS's own pricing feed for
  EU (Frankfurt), not off a marketing page;
- the gp3 rate of **~$0.095/GB-month is a list price, approximate** — it could not be read from the feed.
  AWS documents $0.08/GB-month for `us-east-1` and Frankfurt runs roughly 19% higher, so treat $0.095 as
  an estimate and re-check it before you rely on the last dollar;
- the public IPv4 rate of **~$0.005/hour is the published list price**, uniform across regions at the
  time of writing but unverified against the feed.

Composed from those three, a month of running the instance 24/7 is **~$35.48** of AWS spend
(`$28.03` compute + `$3.80` EBS + `$3.65` IPv4): one verified rate plus two list prices, so the total
inherits their uncertainty. Everything else AWS charges for here rounds to zero, including the waker.

The OpenRouter token prices are the ones the model card quotes for
`openrouter/deepseek/deepseek-v4-flash-0731` and are exact at the time of writing.

**The AWS budget does not see model spend.** `aws_budgets_budget` covers AWS charges only; OpenRouter
bills you separately and that spend is completely invisible to the AWS budget. See §5.

All monthly figures use **730 hours** as one month.

## 1. Unit prices used

| Line item | Unit price | Notes |
|---|---|---|
| EC2 `t4g.medium` on-demand | **$0.0384 / hour** (verified) | 2 vCPU Graviton2, 4 GiB. Read from the AWS pricing feed for EU (Frankfurt). |
| EBS gp3 storage | **~$0.095 / GB-month** (list price, approximate) | Baseline 3,000 IOPS and 125 MB/s are included; we provision no extra. `us-east-1` is documented at $0.08; Frankfurt is ~19% higher. |
| Public IPv4 address | **~$0.005 / hour** (list price, approximate) | Charged per in-use address, only while the instance is running. |
| DeepSeek V4 Flash input | **$0.09 / Mtok** | Exact. Billed by OpenRouter, not AWS. |
| DeepSeek V4 Flash output | **$0.18 / Mtok** | Exact. Billed by OpenRouter, not AWS. |
| SSM Session Manager | **$0.00** | No charge for the service. |
| SSM Parameter Store, standard tier | **$0.00** | The four `/openbuilder/*` parameters are standard, not advanced. |
| KMS `alias/aws/ssm` decrypt | **$0.00** | AWS-managed key; no key charge. Request volume here is a rounding error. |
| CloudWatch custom metrics, `OpenBuilder` namespace | **~$0.30 / metric-month** (approximate) | Free-tier covers a handful; treat as ~$0 at this volume. |
| AWS Budgets | **$0.00** for the first two budgets (approximate) | We create at most one. |
| Data transfer out | **~$0.09 / GB** (approximate) after the 100 GB/month free allowance | `git push` and API traffic; well under a GB. |
| EventBridge scheduled rule, `rate(5 minutes)` | **$0.00** | Scheduled rules are not billed for invocations. |
| Lambda `openbuilder-waker`, 256 MB, arm64 | **$0.00** | ~8,600 invocations/month of a couple of seconds — inside the perpetual free tier. See §3. |
| CloudWatch Logs, `/aws/lambda/openbuilder-waker` | **~$0.00** | 14-day retention (`waker_log_retention_days`), so a function that logs every five minutes forever cannot accumulate storage. |

Three facts that dominate everything below:

1. **EBS is billed 24/7 on the provisioned size, whether the instance runs or not.** Stopping the
   instance removes the compute charge and the public IPv4 charge; the 40 GiB gp3 volume keeps costing
   ~$3.80/month regardless. Idle auto-stop does not reduce it by one cent — see §3.
2. **The model is not the expensive part.** At $0.09/Mtok input, a month of real work costs less than a
   single day of the instance. Optimise the instance, not the prompts.
3. **Nobody decides the duty cycle by hand.** `ob-idle-stop` powers the instance off after 30 minutes of
   quiet and the waker powers it back on within `waker_interval_minutes` of work appearing, so your bill
   is set by how much work you dispatch, not by whether you remembered to stop the box.

## 2. Worked example

### Assumptions — state them, then do the arithmetic

| Assumption | Value |
|---|---|
| Instance | one `t4g.medium`, `eu-central-1` |
| Root volume | 40 GiB gp3, encrypted (the `root_volume_gb` default) |
| Awake hours per day | **8** (assumption; `ob-idle-stop` at `OPENBUILDER_IDLE_STOP_MINUTES=30`, waker on at `waker_interval_minutes=5`) |
| Awake hours per month | 8 × 30 = **240 h** (assumption) |
| Stories implemented per month | **20** (assumption) |
| Rounds per story | 1 `ob-implement` + 2 `ob-respond` = **3 omp runs** |
| Input tokens per story, all rounds | **350,000** (assumption) |
| Output tokens per story, all rounds | **45,000** (assumption) |

The token numbers deserve a word, because they are the ones people get wrong. Each round is a **fresh
omp session** (`--no-session`), so it re-reads the story cards, the worklog, the relevant source files and
the review comments from scratch. Roughly 100k–150k input tokens per round on a small-to-medium repo is
normal; 350k across three rounds is a realistic middle. Output is small because the agent writes diffs
and commit messages, not essays — 15k output tokens per round is generous.

### EC2 compute

```
240 h  ×  $0.0384/h  =  $9.216        →  ~$9.22 / month
```

### Public IPv4 address (only while running)

```
240 h  ×  $0.005/h   =  $1.20         →  ~$1.20 / month
```

### EBS root volume (billed whether running or stopped)

```
40 GiB  ×  $0.095/GB-month  =  $3.80  →  ~$3.80 / month   (gp3 rate approximate)
```

### Model tokens

Twenty stories a month, 350,000 input and 45,000 output tokens each, as assumed above.

Input:

```
20 stories  ×  350,000 tok  =  7,000,000 tok  =  7.0 Mtok
7.0 Mtok  ×  $0.09/Mtok     =  $0.63
```

Output:

```
20 stories  ×  45,000 tok   =    900,000 tok  =  0.9 Mtok
0.9 Mtok  ×  $0.18/Mtok     =  $0.162
```

Model total:

```
$0.63  +  $0.162  =  $0.792            →  ~$0.79 / month
```

This $0.79 is billed by **OpenRouter**, not AWS. The AWS budget in §5 cannot see it and will never alert
on it.

### Total

Idle auto-stop only reduces the line items that stop when the instance stops:

| Item | Monthly (approx.) | Reduced by idle auto-stop? |
|---|---|---|
| EC2 `t4g.medium`, 240 h | $9.22 | **Yes** — billed per running hour |
| Public IPv4, 240 h | $1.20 | **Yes** — charged only while in use |
| EBS 40 GiB gp3 | $3.80 | **No** — billed 24/7 on provisioned size |
| DeepSeek V4 Flash, 20 stories | $0.79 | Indirectly — fewer rounds, fewer tokens (OpenRouter, not AWS) |
| EventBridge `rate(5 minutes)` + `openbuilder-waker` Lambda + its log group | ~$0.00 | **No** — runs while the box is stopped, which is the point; free tier either way |
| SSM, Parameter Store, KMS, Budgets, CloudWatch metrics | ~$0.00 | n/a |
| **Total** | **~$15.01 / month** | of which **$3.80 is unavoidable** |

Arithmetic: `$9.216 + $1.20 + $3.80 + $0.792 = $15.008`.

That is **~$0.75 per merged story** ($15.008 ÷ 20), of which four cents is the model ($0.792 ÷ 20 =
$0.0396).

The laptop side — Opus 5 planning and reviewing through Bedrock — is billed separately by your Bedrock
account and is not counted here. It is typically the largest number in the whole system, which is exactly
why only two steps out of the loop use it.

## 3. The closed loop: where in the band you land

The instance is **stopped by default**. `ob-idle-stop` powers it off after 30 minutes of quiet; the waker
Lambda evaluates GitHub every `waker_interval_minutes` (default 5) and calls `ec2:StartInstances` when a
plan branch or a `openbuilder:changes-requested` PR is waiting. Neither end of that loop needs a human, so
your awake hours are a function of how much work you dispatch — not of whether you remembered to stop the
box.

That puts the AWS bill in a band. The bottom is the 40 GiB gp3 volume, which bills whatever you do — the
subsection below. The top is 730 awake hours at **~$35.48/month of AWS spend**, the ceiling, and you reach
it only if the instance never goes quiet for 30 consecutive minutes.

Same 20 stories, same volume, only the instance hours change. The 240 h/month row is 8 h/day × 30 days —
an assumption, not a measurement.

| Scenario | Instance hours | Compute | IPv4 | EBS | Model | **Total** |
|---|---|---|---|---|---|---|
| **Always-on** — never quiet for 30 min | 730 | $28.03 | $3.65 | $3.80 | $0.79 | **~$36.27** |
| **Idle auto-stop** — 8 h/day awake (assumed) | 240 | $9.22 | $1.20 | $3.80 | $0.79 | **~$15.01** |
| 3 h/day awake | 90 | $3.46 | $0.45 | $3.80 | $0.79 | **~$8.50** |
| No actionable work all month | 0 | $0.00 | $0.00 | $3.80 | $0.00 | **~$3.80** |

Substitute your own hours — compute and IPv4 are the only terms that move, and they move together at
`$0.0384 + $0.005 = $0.0434` per awake hour:

```
awake_h  ×  $0.0434/h  +  $3.80  =  AWS spend / month
```

The two ends and the middle, spelled out.

Never quiet, 730 h:

```
730 h  ×  $0.0384/h  =  $28.032       →  ~$28.03   compute
730 h  ×  $0.005/h   =  $3.65                      IPv4 (list price)
40 GiB ×  $0.095/GB  =  $3.80                      gp3 (list price)
                     =  $35.482      →  ~$35.48 / month of AWS spend
                        $0.792                     model, via OpenRouter
                     =  $36.274      →  ~$36.27 / month all-in
```

An intermediate duty cycle, the assumed 240 h:

```
240 h  ×  $0.0384/h  =  $9.216        →  ~$9.22    compute
240 h  ×  $0.005/h   =  $1.20                      IPv4 (list price)
40 GiB ×  $0.095/GB  =  $3.80                      gp3 (list price), unchanged
                        $0.792                     model, via OpenRouter
                     =  $15.008      →  ~$15.01 / month all-in
```

So 8 awake hours a day instead of 24 saves **$21.27/month (~59%)** (`$36.274 − $15.008 = $21.266`).

### The waker costs nothing

**Treat the waker as $0.** An EventBridge scheduled rule is not billed for its invocations, and
`rate(5 minutes)` is ~8,600 invocations a month:

```
730 h ÷ (5 min / 60)  =  8,760 invocations / month  (call it ~8.6k)
8,760  ×  ~2 s  ×  256 MB  ≈  4,500 GB-s / month
```

The perpetual Lambda free tier is 1M requests and 400,000 GB-s a month, so both dimensions are an order of
magnitude inside it, and there is no layer, no container image and no NAT hop to pay for either. The one
cost that would have crept is logs: a function that writes a decision line every five minutes forever
accumulates. `/aws/lambda/openbuilder-waker` is created with 14-day retention
(`waker_log_retention_days`) precisely so that it cannot.

### Start/stop latency is the price of the band

Stopping and starting a `t4g.medium` takes **~30–45 seconds** end to end, which is what makes an
aggressive `idle_stop_minutes` cheap in wall-clock terms: the waker pays it once per burst of work, and
the laptop CLI pays it for interactive commands (`openbuilder dispatch` and `openbuilder review` still
start the instance themselves and wait). Lowering `idle_stop_minutes` below 30 buys very little — a plan
branch pushed five minutes after the last one would pay the start-up again — and 30 minutes is a
reasonable compromise between paying for idle and thrashing. It is also the number the waker's flap guard
is calibrated against: if an instance is `stopped` again within `waker_flap_guard_minutes` (20) of
launching, the waker refuses to restart it, because a cycle that short means something is wrong rather
than that there is work to do.

### The floor: gp3 is the one cost auto-stop cannot touch

gp3 is billed **24/7 on the provisioned size**, not on usage and not on instance state, so
**~$3.80/month is the hard floor** of a stopped instance. It is the dominant *fixed* cost: 100% of the
stopped-month bill ($3.80 of $3.80), and still ~25% of the
240 h bill ($3.80 of $15.008). Every other AWS line item on this page goes to zero when the instance stops;
this one does not. Once the loop is auto-stopping aggressively, **shrinking the volume is the only lever
left on the floor** — halving it halves the bill of a mostly-idle month:

```
20 GiB  ×  $0.095/GB-month  =  $1.90     (saves $1.90/month — half the floor)
```

The exact line to change, in `infra/terraform.tfvars`:

```hcl
root_volume_gb = 20
```

Then `make apply`. **EBS volumes can only be grown, never shrunk**, so this is a decision to make
*before* the first `apply`; afterwards it means recreating the instance. 40 GiB is the default because it
holds one or two target repos with clones, worktrees and `node_modules`; go below ~20 GiB and you are
fighting the OS image plus the toolchain caches. Pair a smaller volume with the disk-hygiene commands in
[runbook.md §10](runbook.md#10-disk-full).

Going *below* that number means terminating the instance rather than stopping it, and that is a bad trade.
A stopped instance keeps its root volume, so the git clones, the worktrees and the `node_modules` trees
are still warm and start/stop costs ~30–45 seconds. Terminating throws all of it away for a 2–4 minute
cold start that re-clones and re-installs before any work happens — and the waker fires whenever a plan
branch appears, so you would pay that cold start several times a week to save $3.80 a month.

For comparison, the two "more private" network designs this system deliberately does not use. Both
figures are **approximate and unverified for Frankfurt** — treat them as a lower bound, since eu-central-1
list prices run above `us-east-1`:

| Alternative | Added monthly cost (approx., unverified) |
|---|---|
| NAT gateway (so the instance can sit in a private subnet) | ~$32.40 + data processing |
| Interface VPC endpoints for `ssm`, `ssmmessages`, `ec2messages` | ~$21.60 |
| Both | **~$54/month** |

That is roughly three and a half times the entire running cost of the system at the assumed duty cycle
($54 ÷ $15.008 ≈ 3.6), to hide a host with zero ingress rules. See
[architecture.md](architecture.md#public-subnet-instead-of-a-nat-gateway-or-interface-endpoints).

## 4. Three levers to cut cost further

### Lever 1 — shrink the EBS volume (the only lever on the floor)

At the assumed 8 h/day duty cycle the 40 GiB volume is **~25% of the bill** ($3.80 of $15.008), and it is
the only line item you pay while the instance is off — see [the floor](#the-floor-gp3-is-the-one-cost-auto-stop-cannot-touch)
above for the `root_volume_gb = 20` change and the grow-only caveat. In absolute terms instance hours are
now the bigger number; in *unavoidable* terms this is the whole floor.

### Lever 2 — drop to `t4g.small`, or go Graviton spot

`t4g.small` (2 vCPU, 2 GiB) is ~$0.0192/hour — exactly half of `t4g.medium`, since the `t4g` family
prices scale linearly by size (derived from the verified medium rate, so approximate):

```
240 h  ×  $0.0192/h  =  $4.608          (saves ~$4.61/month)
```

The tradeoff is real: 2 GiB is tight for a Node toolchain plus a test run plus omp, and an OOM kill
during a run costs you an attempt and leaves a PR on `openbuilder:in-progress`
([runbook.md §2](runbook.md#2-pr-stuck-in-openbuilderin-progress)). Only worth it for small repos with
light test suites. Set `instance_type = "t4g.small"` and `make apply`.

A Compute Savings Plan or a 1-year Reserved Instance cuts the compute line ~30–40% if you decide to run
always-on anyway. Spot is cheaper still but the wrong shape for this design — an interruption mid-run
loses the round and the instance would come back without your warm caches.

### Lever 3 — spend fewer rounds per story

Rounds are the multiplier on everything: instance hours *and* tokens. Three rounds per story instead of
five is a 40% cut on the model line and, more importantly, on awake time. The levers that actually move
this are all on the planning side:

- **Write mechanically checkable acceptance criteria.** "Returns 200 with `{"status":"ok"}`" ends a round;
  "works correctly" causes one. See [../backlog/SCHEMA.md](../backlog/SCHEMA.md).
- **Size stories S or M, never L.** An L story is the single most reliable way to burn all six attempts.
- **Quote exact failures in review comments.** `ob-respond` reads every review comment via
  `gh api --paginate`; a pasted stack trace converges in one round where "the tests fail" does not.

There is also a cap, not a lever: `OPENBUILDER_MAX_ATTEMPTS` (default 6) bounds the worst case per story,
and `OPENBUILDER_MAX_RUNTIME` (default `45m`) bounds a single run. Both exist so a pathological story
cannot quietly spend a month's budget.

## 5. Watching actual spend

Model spend, summed from `.message.usage.cost.total` across every round's `run.ndjson` on the instance:

```sh
openbuilder cost
```

For one job, across all of its rounds:

```sh
openbuilder shell
sudo -u openbuilder jq -s 'map(select(.type=="message_end")|.message.usage.cost.total//0)|add//0' \
  /opt/openbuilder/state/<owner>__<repo>__<slug>/rounds/*/run.ndjson
```

AWS spend — Terraform creates a monthly cost budget when `enable_budget = true` and
`budget_alert_email` is set:

```hcl
monthly_budget_usd = 20
budget_alert_email = "you@example.com"
enable_budget      = true
```

**The budget covers AWS spend only.** OpenRouter bills the model separately, so the ~$0.79/month of
DeepSeek tokens above — and any runaway multiple of it — is completely invisible to
`aws_budgets_budget`. An AWS budget alert will never tell you the model is burning money.

### Is $20 enough?

The alert threshold is 80% of the budget, so it fires at **$16 of AWS spend**. AWS-only totals (model
excluded, because the budget excludes it):

| Scenario | AWS spend/month | Against a $20 budget |
|---|---|---|
| Never quiet for 30 min, 730 h | $28.032 + $3.65 + $3.80 = **~$35.48** | **Not sufficient.** 177% of budget. The $16 alert fires around day 14 and the budget is blown around day 17. |
| 240 awake h (assumed) | $9.216 + $1.20 + $3.80 = **~$14.22** | **Sufficient.** 71% of budget, $5.78 of headroom; the $16 alert never fires. |
| 90 awake h | $3.456 + $0.45 + $3.80 = **~$7.71** | Sufficient, comfortably — 39% of budget. |
| Stopped all month | **$3.80** | Sufficient — 19% of budget. |

Where the thresholds actually sit, with a 40 GiB volume ($3.80 fixed) and $0.0434 per awake hour
(compute + IPv4):

```
($16.00 − $3.80) ÷ $0.0434/h  =  ~281 awake h/month  (~9.4 h/day)  →  80% alert fires above this
($20.00 − $3.80) ÷ $0.0434/h  =  ~373 awake h/month  (~12.4 h/day) →  budget exceeded above this
```

So: $20 is the right budget for an instance whose loop actually closes and the wrong budget for one that
never goes quiet. If you run always-on deliberately, raise `monthly_budget_usd` to at least 45 or the alert
becomes noise you learn to ignore.

Also set a hard spend limit on the OpenRouter key itself at <https://openrouter.ai/keys>. That is the
only control that bounds model spend at all — the AWS budget does not. A budget alert is an email; a key
limit is a wall, and a wall is what you want protecting a model with shell access.

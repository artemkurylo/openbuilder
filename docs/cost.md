# Cost

**Every AWS price in this document is approximate and region-dependent.** They are `us-east-1`
on-demand list prices as a reasonable working estimate; check
<https://aws.amazon.com/ec2/pricing/on-demand/> and
<https://aws.amazon.com/ebs/pricing/> for the authoritative numbers in your region, and expect them to
drift. The OpenRouter token prices are the ones the model card quotes for
`openrouter/deepseek/deepseek-v4-flash-0731` and are exact at the time of writing.

All monthly figures use **730 hours** as one month.

## 1. Unit prices used

| Line item | Unit price | Notes |
|---|---|---|
| EC2 `t4g.medium` on-demand | **~$0.0336 / hour** (approximate) | 2 vCPU Graviton2, 4 GiB. Approximate, region-dependent. |
| EBS gp3 storage | **~$0.08 / GB-month** (approximate) | Baseline 3,000 IOPS and 125 MB/s are included; we provision no extra. |
| Public IPv4 address | **~$0.005 / hour** (approximate) | Charged per in-use address. |
| DeepSeek V4 Flash input | **$0.09 / Mtok** | Exact. |
| DeepSeek V4 Flash output | **$0.18 / Mtok** | Exact. |
| SSM Session Manager | **$0.00** | No charge for the service. |
| SSM Parameter Store, standard tier | **$0.00** | The four `/openbuilder/*` parameters are standard, not advanced. |
| KMS `alias/aws/ssm` decrypt | **$0.00** | AWS-managed key; no key charge. Request volume here is a rounding error. |
| CloudWatch custom metrics, `OpenBuilder` namespace | **~$0.30 / metric-month** (approximate) | Free-tier covers a handful; treat as ~$0 at this volume. |
| AWS Budgets | **$0.00** for the first two budgets (approximate) | We create at most one. |
| Data transfer out | **~$0.09 / GB** after 100 GB free (approximate) | `git push` and API traffic; well under a GB. |

Two facts that dominate everything below:

1. **EBS is billed while the instance is stopped.** Stopping the box removes the compute charge and the
   public IPv4 charge; the 100 GB gp3 volume keeps costing ~$8.00/month regardless. That is the floor.
2. **The model is not the expensive part.** At $0.09/Mtok input, a month of real work costs less than a
   single day of the instance. Optimise the instance, not the prompts.

## 2. Worked example

### Assumptions — state them, then do the arithmetic

| Assumption | Value |
|---|---|
| Instance | one `t4g.medium`, `us-east-1` |
| Root volume | 100 GB gp3, encrypted |
| Awake hours per day | **8** (idle auto-stop at `OPENBUILDER_IDLE_STOP_MINUTES=30`) |
| Awake hours per month | 8 × 30 = **240 h** |
| Stories implemented per month | **20** |
| Rounds per story | 1 `ob-implement` + 2 `ob-respond` = **3 omp runs** |
| Input tokens per story, all rounds | **350,000** |
| Output tokens per story, all rounds | **45,000** |

The token numbers deserve a word, because they are the ones people get wrong. Each round is a **fresh
omp session** (`--no-session`), so it re-reads the story cards, the worklog, the relevant source files and
the review comments from scratch. Roughly 100k–150k input tokens per round on a small-to-medium repo is
normal; 350k across three rounds is a realistic middle. Output is small because the agent writes diffs
and commit messages, not essays — 15k output tokens per round is generous.

### EC2 compute

```
240 h  ×  $0.0336/h  =  $8.064        →  ~$8.06 / month
```

### Public IPv4 address (only while running)

```
240 h  ×  $0.005/h   =  $1.20         →  ~$1.20 / month
```

### EBS root volume (billed whether running or stopped)

```
100 GB  ×  $0.08/GB-month  =  $8.00   →  ~$8.00 / month
```

### Model tokens

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

### Total

| Item | Monthly (approx.) |
|---|---|
| EC2 `t4g.medium`, 240 h | $8.06 |
| Public IPv4, 240 h | $1.20 |
| EBS 100 GB gp3 | $8.00 |
| DeepSeek V4 Flash, 20 stories | $0.79 |
| SSM, Parameter Store, KMS, Budgets, CloudWatch | ~$0.00 |
| **Total** | **~$18.05 / month** |

That is **~$0.90 per merged story**, of which four cents is the model.

The laptop side — Opus 5 planning and reviewing through Bedrock — is billed separately by your Bedrock
account and is not counted here. It is typically the largest number in the whole system, which is exactly
why only two steps out of the loop use it.

## 3. Idle auto-stop: what it saves

Same 20 stories, same volume, only the instance hours change.

| Scenario | Instance hours | Compute | IPv4 | EBS | Model | **Total** |
|---|---|---|---|---|---|---|
| Always on | 730 | $24.53 | $3.65 | $8.00 | $0.79 | **~$36.97** |
| Idle auto-stop, 8 h/day awake | 240 | $8.06 | $1.20 | $8.00 | $0.79 | **~$18.05** |
| Idle auto-stop, 3 h/day awake | 90 | $3.02 | $0.45 | $8.00 | $0.79 | **~$12.26** |
| Stopped all month | 0 | $0.00 | $0.00 | $8.00 | $0.00 | **~$8.00** |

The arithmetic for the always-on row:

```
730 h  ×  $0.0336/h  =  $24.528       →  ~$24.53
730 h  ×  $0.005/h   =  $3.65
```

So idle auto-stop saves roughly **$18.92/month (~51%)** at 8 awake hours a day, and the floor is the
$8.00 EBS volume you pay whatever happens.

This is why the laptop CLI starts the instance itself: `openbuilder dispatch` and `openbuilder review`
both run `aws ec2 start-instances` and wait, so aggressive auto-stop costs you a ~30 second start-up
instead of a missed trigger. Lowering `idle_stop_minutes` below 30 buys very little — a plan branch you
push five minutes after the last one would pay the start-up again — and 30 minutes is a reasonable
compromise between paying for idle and thrashing.

For comparison, the two "more private" network designs this system deliberately does not use:

| Alternative | Added monthly cost (approx.) |
|---|---|
| NAT gateway (so the box can sit in a private subnet) | ~$32.40 + data processing |
| Interface VPC endpoints for `ssm`, `ssmmessages`, `ec2messages` | ~$21.60 |
| Both | **~$54/month** |

That is roughly three times the entire running cost of the system, to hide a host with zero ingress
rules. See [architecture.md](architecture.md#public-subnet-instead-of-a-nat-gateway-or-interface-endpoints).

## 4. Three levers to cut cost further

### Lever 1 — shrink the EBS volume (biggest single win)

At an 8 h/day duty cycle the 100 GB volume is **44% of the bill**, and it is the only line item you pay
while the box is off. 100 GB is generous headroom for clones, worktrees and `node_modules`; 40 GB is
usually plenty for one or two target repos.

```
 40 GB  ×  $0.08/GB-month  =  $3.20     (saves $4.80/month)
```

Set `root_volume_gb = 40` in `infra/terraform.tfvars` and `make apply`. Note that EBS volumes can only be
grown, never shrunk, so this is a decision to make **before** the first `apply` — afterwards it means
recreating the instance. Pair a smaller volume with the disk-hygiene commands in
[runbook.md §10](runbook.md#10-disk-full).

### Lever 2 — drop to `t4g.small`, or go Graviton spot

`t4g.small` (2 vCPU, 2 GiB) is ~$0.0168/hour — exactly half of `t4g.medium`:

```
240 h  ×  $0.0168/h  =  $4.032          (saves ~$4.03/month)
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

Model spend, summed from `.message.usage.cost.total` across every `run.ndjson` on the box:

```sh
openbuilder cost
```

For one job:

```sh
openbuilder shell
sudo -u openbuilder jq -s 'map(select(.type=="message_end")|.message.usage.cost.total//0)|add//0' \
  /opt/openbuilder/state/<owner>__<repo>__<slug>/run.ndjson
```

AWS spend — Terraform creates a monthly cost budget when `enable_budget = true` and
`budget_alert_email` is set:

```hcl
monthly_budget_usd = 100
budget_alert_email = "you@example.com"
enable_budget      = true
```

Also set a hard spend limit on the OpenRouter key itself at <https://openrouter.ai/keys>. A budget alert
is an email; a key limit is a wall, and a wall is what you want protecting a model with shell access.

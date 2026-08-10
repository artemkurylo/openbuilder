# Working in openbuilder

Read this before changing anything here. `LEARNINGS.md` is the other required read: it is loaded into
every remote round automatically, and its entries are rules, not suggestions.

openbuilder is a control plane for unattended agentic coding. A laptop plans and reviews with a strong
model; an EC2 instance implements with a cheap one and opens pull requests; GitHub is the only message
bus. The instance is **off by default** — `ob-idle-stop` powers it down, the `openbuilder-waker` Lambda
powers it up when GitHub has work. `docs/architecture.md` is the design authority, `docs/runbook.md` the
operational one.

## Three standing obligations

Everything in this repository is operated unattended, at 3am, by something that cannot ask a question.
That makes three habits load-bearing rather than polite.

### 1. Extract the lesson, every time

When you learn something that cost you real time or real money to discover — a symptom that lied, a
mechanism you had to reverse-engineer, a default that was not what it looked like — **write it into
`LEARNINGS.md` before you move on**. Use `local/bin/ob-learn`, which numbers and places the entry for you:

```sh
printf '%s\n' '### Imperative rule, in one line' \
  '**Symptom** what you actually saw, quoted.' \
  '**Cause** the mechanism, not the guess.' \
  '**Rule** what to do instead, every time.' \
  '**Proven** how it was demonstrated, and when.' \
  | local/bin/ob-learn --section environment
```

The bar is the four tests in the file itself: it would have changed how you worked, it is true beyond
this repository, you observed it, and it is not already there. Nothing a linter or a type checker would
have caught. Nothing speculative. A remote round proposes candidates and a human accepts them; when you
are the human, accept them by committing.

An unwritten lesson is a lesson someone pays for twice — and the machine that learned it does not
survive: an EBS volume cannot follow its instance across availability zones, so a rebuild takes the disk
with it. The control repository is the only memory that persists.

### 2. Leave the docs true

A stale doc is worse than a missing one, because it is trusted. In the same change that alters behaviour,
update whichever of these it just made wrong:

| File | Owns |
|---|---|
| `README.md` | what it is, how to run it, the repo layout |
| `docs/architecture.md` | design and the reasoning behind each decision |
| `docs/runbook.md` | operator procedures, symptoms, and exact commands |
| `docs/cost.md` | every price and the arithmetic behind it |
| `LEARNINGS.md` | rules learned the hard way, injected into every round |
| `backlog/SCHEMA.md` | the story-card contract |

Quote log lines verbatim from the source rather than paraphrasing them — an operator greps for the string
they actually saw. Mark anything you did not observe yourself as unverified, and say what would verify it.

### 3. Delegate the review; never review in the session that wrote the code

A pull request is reviewed by a **fresh subagent** with no memory of writing it — `openbuilder review`,
or a `reviewer` agent dispatched for that pull request alone. The session that planned the cards or wrote
the diff MUST NOT also produce the verdict, even when it is a different model and even when it would be
faster.

The reason is not process hygiene, it is measurement error. A session that has already convinced itself a
design is correct re-reads its own reasoning in the diff and calls that agreement. It also knows which
acceptance items it checked by hand ten minutes ago and quietly trusts them, which is exactly how a
reported pass becomes an unverified one. A reviewer that starts from the cards, the PRD, the RFC and the
diff has to earn every conclusion.

So: dispatch the review, let it post its own verdict and label, and read the result as evidence rather
than as a formality. When it disagrees with the session that wrote the code, that disagreement is the
most valuable output the system produces — do not overrule it silently.

**Proven the day the rule was written.** The session that had planned the epic read `plan-workflow-05-cli`
inline and was heading toward approval: it had checked the dispatch gate, the land refusals and the watch
loop, and found them sound. A fresh reviewer dispatched for that pull request alone found two blocking
defects in the same diff. `review --watch` died on its first line under `set -u` — the laptop CLI had
copied `ob-poll`'s two sanitising lines without `ob-poll`'s default, so the entire unattended-review
requirement was unreachable as shipped. And `cmd_land` treated "no plan ref exists" as "that slug landed",
which is equally true of a slug never dispatched — so the first `land` of a multi-slug epic would delete
the design branch, at that moment the only copy of the epic's intake, PRD, RFC and all forty-four cards,
including those of a slug not yet built. Both were reproduced, not argued.

The first defect was in code the planning session had read twice. That is the measurement error, exactly:
it knew what the line was *for*, so it read the intent instead of the line.

## House rules

- **Verify by running it, not by reading it.** Every claim in these docs was demonstrated. Three of the
  four defects in the first reviewed pull request were found by re-running its acceptance criteria rather
  than trusting the report that said they passed.
- **`make lint` and `make scrub` before you push.** `lint` is `shellcheck -x -S warning` over every
  script; `scrub` refuses to publish employer, client, hostname or account identifiers, in the working
  tree and in the whole history. This repository is public and its contents are processed by a
  third-party model.
- **Fix the cause.** No skipped spec, no deleted assertion, no silenced linter, no special-cased input.
  A precise blocker is a good outcome; a plausible guess is not.
- **Never force-push.** `ob-selfupdate` advances the instance's clone with `merge --ff-only` and will
  correctly refuse a rewritten history, leaving the instance stuck until someone resets it by hand.
- **Review as a human, not as the bot.** `ob-respond` ignores conversation comments authored by
  `openbuilder*` so the App cannot review itself; a review posted with the App token is invisible to it.
- **Shell style:** `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, a header comment that
  explains *why* the file exists, two-space indent, `local` for every function variable, and one clear
  function over a clever one-liner. `runner/bin/ob-common.sh` is sourced-only and is the single home for
  logging, redaction, locking, secrets, GitHub access and prompt rendering — put shared behaviour there
  rather than reimplementing it.

# PRD — a gated, resumable workflow from problem statement to merged pull request

- epic: `plan-workflow`
- repo: `artemkurylo/openbuilder`
- stage: `prd` — awaiting approval
- inputs: `.openbuilder/epics/plan-workflow/intake.md` (eight questions, all answered)

## 1. Summary

One entry point — `/openbuilder-plan <epic>` — carries a piece of work from a sentence to a merged
pull request through seven stages and four human gates. Each stage has exactly one actor, one
model, and one artifact. Each gate is a human decision recorded on a branch, not in a
conversation, so the workflow survives a closed session, a rebooted laptop, and a week of
interruption.

This document says what the workflow must do and why. How it does it is the RFC.

## 2. Problem

The loop from a story card to a merged pull request is built and has run twice end to end,
unattended. Everything before the card is not built: it lives in one Opus 5 session, and it is
lost when that session ends. Three concrete consequences, all observed:

- **The reasoning is not durable.** Why an approach was chosen exists only as chat history. A
  review three days later, or a second slug on the same epic, starts from nothing.
- **There is no gate before spend.** `openbuilder dispatch` pushes a plan branch, and the poller's
  trigger is that branch existing. The decision to spend money and instance time is a side effect
  of a file being written, with no recorded human yes in between.
- **The loop does not close.** Nothing tears down: two finished, merged slugs still have their
  plan branches on `origin`, evaluated by the poller and the waker on every pass, with a worktree
  and a state directory each on the instance. And each review round has to be hand-cranked with
  three commands, so "the agents talk until they agree" is currently "I drive both of them".

## 3. Actors

| Actor | Runs | Model | Sees |
|---|---|---|---|
| you | laptop, interactively | — | everything |
| the planner side | laptop, interactively | Opus 5 | the repo, you, the epic artifacts |
| the worker | EC2, unattended | DeepSeek V4 Flash | the cards, the epic docs, `LEARNINGS.md` |
| the reviewer | laptop, unattended | Opus 5 | the diff, the cards, the worklog, the RFC |

The division is fixed and is the point of the system: strong model where judgement is needed and a
human is present, cheap model where the contract is already written down.

## 4. Goals

- Turn a one-sentence problem statement into a merged pull request with no step that exists only
  in someone's memory.
- Make each human decision cheap to give and impossible to lose.
- Spend no money on an unapproved plan.
- Leave the repository, after landing, with the reasoning and without the scaffolding.

## 5. Non-goals

- Not a project tracker. No estimates, no velocity, no status dashboard, no cross-epic
  dependencies.
- Not a second review gate. The reviewer already exists; this epic automates its cadence, not its
  rubric.
- Not multi-user. One human drives; concurrent operators are out of scope, and so is any
  permission model beyond what GitHub already enforces.
- Not a change to the card contract. `backlog/SCHEMA.md` stands as written.
- Not a change to how the worker implements or how the instance powers itself.

## 6. Requirements

Numbered so the RFC and the cards can cite them.

### R1 — One entry point, resumable from any stage

`/openbuilder-plan <epic>` is the only thing to remember. Invoked on a new epic it starts intake;
invoked on an existing one it reads the recorded stage and resumes there. Resuming after a lost
session must not re-ask an answered question, re-derive an approved artifact, or lose an approval.

### R2 — The interrogation is an artifact, not a conversation

Every question and its answer is written down as it is resolved, together with why it was worth
asking and what it changed. The grill has a stated stopping rule: ask only while an answer would
change a requirement, a design decision, or an acceptance criterion; answer from the repository
whatever the repository can answer. On "enough", every still-open question becomes a stated
assumption in the PRD — never a silent guess.

### R3 — Four gates, and an approval that cannot be forged or drift

The gates are PRD, RFC, backlog, and merge. At each one:

- the workflow presents the artifact and stops;
- nothing downstream may begin until a human approves;
- the approval is recorded durably on the branch, identifying the exact artifact content approved;
- if that artifact is modified afterwards, the approval is void and the workflow refuses to
  advance until it is re-approved.

An approval that survives an edit to the thing it approved is a ceremony. This requirement is what
makes it a gate.

### R4 — No spend before the backlog gate, enforced by the system

The worker must not start on an unapproved backlog even when the workflow's own tooling is
bypassed — a branch pushed by hand, a script, a mistake. The poller and the waker must both decline
to act on a plan branch whose backlog is not approved, and must decline **quietly**: no attempt
consumed, no `blocked` label, no wake-up. Declining loudly would turn a human mistake into a
terminal state that needs a second human to clear.

### R5 — The worker inherits the reasoning, subordinate to the contract

Every implementation and every response round has the PRD and the RFC available alongside the
cards. They exist so the worker can resolve a judgement call the way the design intended. They are
explicitly **not** a source of scope: work implied by the PRD that no card asks for is out of
scope, and a conflict between the RFC and a card is a blocker to report, not a choice to make.

### R6 — The design record lands with the code

After the pull request merges and every branch is deleted, the PRD and the RFC are present on the
default branch. Six months later the reasoning is readable from `main` alone, with no branch, no
tag, and no session to recover.

### R7 — Review converges without being driven

Once a pull request is open, one command carries it to a verdict: the reviewer reviews, the worker
responds, the reviewer re-reviews, until it approves or the existing attempt budget is exhausted.
The reviewer's findings must be visible to the worker (a review the worker cannot see is a stalled
loop, not a review) and no round may be reviewed twice. Exhaustion, disagreement, and a blocked
worker are all reported to a human with the reason; none of them loops forever.

### R8 — Merging is one human action that leaves nothing behind

A single command merges an approved pull request and returns the world to its pre-epic state:
every branch the epic created is gone from `origin`, and the instance keeps no worktree and no
per-slug state for it. The command refuses to merge anything not approved, and refuses to guess
which pull request is meant. Nothing else in the system may merge, ever.

### R9 — Every refusal names the reason and the fix

The workflow refuses in normal operation: an unapproved artifact, an approval voided by an edit, a
backlog with no cards, a stale design branch, a dirty tree. Each refusal states what is wrong and
the exact next command. A refusal a human has to debug is worse than the mistake it caught.

### R10 — Multiple pull requests when the work wants them

An epic may produce several pull requests. The unit is the slug: the backlog stage decides how many
slugs an epic has, each with a handful of cards, and they are dispatched one at a time. One epic,
one PRD, one RFC, one or more slugs, one pull request each.

## 7. Success criteria

Measured on this epic itself, which goes through the workflow it defines:

1. A closed and reopened session resumes at the recorded stage with no repeated question and no
   lost approval.
2. A plan branch pushed by hand with an unapproved backlog produces no round, no attempt, no
   label, and no instance wake-up — demonstrated against live GitHub, not argued.
3. An artifact edited after approval blocks the next stage until re-approved.
4. A pull request goes from open to `openbuilder:approved` with exactly one human command and at
   least one round of reviewer/worker disagreement in between.
5. After landing, `main` contains the PRD and the RFC, `origin` has none of the epic's branches,
   and the instance has no state directory for the slug.
6. The four documented commands are the only ones needed from problem statement to merge.

## 8. Constraints and assumptions

- GitHub is the only message bus between laptop and instance. No webhook, no inbound port, no
  shared filesystem. Unchanged.
- The instance is off by default and woken by the waker; anything the workflow expects the
  instance to notice must be visible in the rule table the waker also evaluates.
- The worker is a weak model and cannot ask a question. Every artifact it reads must be
  self-contained.
- The reviewer must post as a human: the worker ignores comments authored by the bot, so a review
  posted with the App token is invisible to it (learning 12).
- This repository is public and its contents are processed by a third-party model. No employer,
  client, hostname, account or work-email identifier may appear in any artifact.
- The bot never merges and never force-pushes. Both remain true after this epic.

## 9. Out of scope for this epic

- Any change to `backlog/SCHEMA.md`, to how cards are sized, or to the `write-backlog` skill's
  slicing rules.
- Any change to the reviewer's rubric, the guardrails hook, the security model, or the cost model.
- Any change to instance provisioning, the waker's power-on policy, or the flap guard, beyond the
  one rule-table precondition R4 requires.
- Cross-epic or cross-slug automatic dependency resolution. A human dispatches the next slug.
- Migrating the two existing slugs (`learn-command`, `scrub-hook`) into the new layout. Their
  branches are cleaned up by hand once `land` exists.
- **The quick-fix path.** A one-line fix must not need four gates, and the intended answer is a
  GitHub issue as the entry point: filed from a phone, or filed by the local agent once it has
  diagnosed something and stated the fix. Deliberately deferred until this workflow exists, because
  it is a second trigger, not a shortcut through this one — see §10.

## 10. Risks

- **The rule-table gate lands twice.** R4 must hold in both `ob-poll` and the waker, which
  implement the same table by contract. A one-sided change is a silent divergence: the waker wakes
  the instance for work the poller then declines, and the instance bills until it idles out. The
  design must make the two provably agree, not merely both edited.
- **The tool builds the tool.** The worker implements this epic, including the file that dispatches
  it. Mitigated by slicing — the dispatcher changes late and alone — and by the fact that nothing
  merges without review.
- **The design record in the diff.** R6 puts the PRD and the RFC into the pull request. If the copy
  is not idempotent, the second slug of an epic produces an empty commit and fails the round's
  "at least one commit" check for a reason that has nothing to do with the code.
- **Gate fatigue.** Four gates on a small change is friction, and friction is what makes people
  bypass a workflow. The answer is a documented fast path, and its shape is already decided: a
  labelled GitHub issue becomes the unit of work for a fix small enough that the PRD, the RFC and
  the slice are the same sentence. That is its own epic, for a structural reason — the poller's
  only trigger today is `refs/heads/openbuilder/plan/*`, so an issue-driven path is a new rule in
  the rule table, which by the parity contract means a new rule in the waker too, plus a decision
  about who authors the single card and where the gate sits when the human is on a phone. Building
  it before the gated path exists would mean designing the exception before the rule. Until then
  the honest fast path is a one-card epic, and the failure mode to watch for is not friction but a
  gate quietly skipped.

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

### R8 — Merging is one authorized action that leaves nothing behind

A single command merges an approved pull request and returns the world to its pre-epic state:
every branch the epic created is gone from `origin`, and the instance keeps no worktree and no
per-slug state for it. The command refuses to merge anything not approved, and refuses to guess
which pull request is meant.

Nothing merges without a **recorded human authorization**. That authorization takes one of exactly
two forms: a human running the land command, or an auto-merge the human enabled for that epic under
R12. The remote implementer never merges under any circumstances — that rule is unchanged and
absolute.

### R9 — Every refusal names the reason and the fix

The workflow refuses in normal operation: an unapproved artifact, an approval voided by an edit, a
backlog with no cards, a stale design branch, a dirty tree. Each refusal states what is wrong and
the exact next command. A refusal a human has to debug is worse than the mistake it caught.

### R10 — Multiple pull requests when the work wants them

An epic may produce several pull requests. The unit is the slug: the backlog stage decides how many
slugs an epic has, each with a handful of cards, and they are dispatched one at a time. One epic,
one PRD, one RFC, one or more slugs, one pull request each.

### R11 — openbuilder operates on personal repositories only, and enforces it

openbuilder must never act on a repository hosted anywhere but `github.com`, and never on a
repository outside the personal account. This is not a configuration default; it is a boundary the
code refuses to cross:

- every entry point rejects a non-personal owner **before** any network call, naming the owner it
  refused;
- every GitHub call pins the host explicitly rather than inheriting whatever the environment
  offers;
- a host other than `github.com` anywhere in the configuration is a fatal startup error, not a
  knob;
- the refusal is loud, since a silent fallback to the wrong host is the failure this exists to
  prevent.

The boundary is currently held by luck, not by code: `gh` on the laptop is authenticated to an
enterprise host as well as to `github.com`, `local/bin/openbuilder` makes twenty-three `gh` calls
without pinning a host, and repository validation checks only that an argument looks like
`owner/repo`. It has worked so far because the commands happen to run inside a `github.com` clone.
That is a coincidence, and this requirement removes the dependence on it.

This is the same failure class the project has already paid for twice — `ob_region()` deliberately
ignoring an ambient `AWS_REGION`, and the AWS provider needing an explicit profile because the
ambient one was a work account. Credential and host separation is a standing property of this
system, not a feature of this epic; R11 finishes the job for GitHub.

### R12 — Auto-merge is opt-in, conditional, and self-halting

Waiting for a human at every merge is the loop's real bottleneck: an epic of six slugs stalls six
times, each time for as long as it takes someone to look. So the reviewer may merge what it
approved — but only under every one of these conditions, all of which must hold simultaneously:

1. **Enabled explicitly, per epic, and recorded like any other approval.** Enabling auto-merge is
   itself a gate: a human authorizes it once, the authorization is recorded durably, and it names
   the epic it applies to. It is never a default and never global.
2. **A clean verdict.** The reviewer's verdict is approve with **zero** blocking and **zero**
   important findings. Nit-only is acceptable. A verdict that needed a judgement call is a verdict a
   human should see.
3. **The repository's own checks pass on the merge result, not on the branch.** This repository has
   no CI, so the reviewer is otherwise the only gate — and the branch that gets merged is the branch
   `ob-selfupdate` deploys to the instance. Before merging, the merge must be performed locally
   against the current default branch and the repository's own lint and secret-scrub targets run on
   that result. A pull request that is correct alone and breaks the default branch together is the
   failure this condition exists to catch, and it is the one no reviewer reliably sees.
4. **The diff touches nothing that can disarm the system.** Infrastructure, the waker, the
   guardrails hook, CI configuration, the learnings store, the story-card contract, and the CLI that
   drives the whole workflow are excluded by path. A change to the machinery that enforces the rules
   is exactly the change a human must read.
5. **Truthful attribution.** The merge is recorded by GitHub as performed by the bot, not by a human
   who was not there. An audit trail that credits a person for a machine's decision is worse than
   no audit trail.
6. **Self-halting.** The first refusal, failed check, or unexpected state stops the whole loop and
   reports. Auto-merge never retries, never escalates, and never proceeds to the next slug after a
   failure.
7. **Legible afterwards.** Every auto-merge leaves a comment enumerating each condition and the
   observed result, so the decision can be audited without re-deriving it.

A consequence worth stating plainly: condition 4 means the slug that rewrites the workflow CLI can
never auto-merge. That is correct, not a limitation.

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
7. With an enterprise host authenticated in `gh` and exported in the environment, every openbuilder
   command that takes a repository refuses a non-personal owner before making a network call, and
   every command that does make one reaches `github.com` — demonstrated on this laptop, where both
   hosts are in fact authenticated.
8. Each of R12's seven conditions, violated one at a time, produces a refusal that names the
   condition it failed and merges nothing — including the case that matters most: a pull request the
   reviewer approves whose merge into the default branch fails the repository's own lint or scrub.

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
- **Personal use only.** `github.com`, personal account, and no path by which a work or enterprise
  host can be reached — see R11. A repository on an enterprise host is not a supported
  configuration to be handled carefully; it is a state the code refuses to enter.

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

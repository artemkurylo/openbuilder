# Intake — `plan-workflow`

The grill, question by question. Written **during** the interrogation, one block per question, not
summarised afterwards: an omp session is not durable, this branch is. Re-running
`/openbuilder-plan plan-workflow` reads `state.json`, sees `stage: intake`, and resumes at the
first unanswered question instead of re-interrogating.

- epic: `plan-workflow`
- repo: `artemkurylo/openbuilder`
- opened: 2026-08-09
- stage: `prd` (intake closed 2026-08-09, all eight questions answered)

## Problem statement (as given, 2026-08-09)

> I want a persistent, harness-driven workflow. When I plan to work on something I want a
> pre-defined path: slash command `openbuilder-plan`. I describe the problem, Opus 5 grills me,
> and once the plan is agreed and every question is exercised we branch. Then a PRD, which I
> approve. Then a technical approach — an RFC — which I approve. Then a backlog of stories. Then
> the openbuilder worker takes them one by one with access to the PRD, the RFC and the cards, and
> opens a PR (or several, if that makes sense). Then I kick off a review agent on my laptop; the
> two of you talk through GitHub comments until it approves. Then I review, I merge, the branch is
> deleted.

Four human gates: PRD, RFC, backlog, merge. Between any two gates there is exactly one actor with
one model. Nothing crosses a gate without a durable record that a human said yes.

This epic is itself the first thing to go through the workflow it defines, which is why this file
exists on a branch before the tooling does.

## What the repository already does (verified against `main` @ `e0d231b`)

Read before asking anything, because most of the workflow is already built and the questions
below are only about the parts that are not.

| Already there | Where | Fits the new flow? |
|---|---|---|
| `openbuilder plan <repo> <slug>` scaffolds `plan.md` and launches an Opus 5 session in a managed clone | `local/bin/openbuilder:564` | becomes the workflow launcher; the scaffold is replaced by stages |
| `planner` agent writes cards from a conversation | `agent/local/agents/planner.md` | must read `prd.md`/`rfc.md` instead of interviewing |
| card contract | `backlog/SCHEMA.md`, `write-backlog` skill | unchanged |
| `dispatch` commits and pushes `openbuilder/plan/<slug>` | `local/bin/openbuilder:666` | becomes the dispatch gate |
| the poller's trigger is the ref `refs/heads/openbuilder/plan/*` | `runner/bin/ob-poll:49,132` | **this is the spend switch** — see Q4 |
| one work branch and one PR per slug, all cards in one omp run | `runner/bin/ob-implement:113-146,266` | see Q1 |
| work branch cut from `merge-base(plan, default)`; PR base is the default branch | `runner/bin/ob-implement:83,271` | why the backlog stays out of the review diff — keep |
| implementer reads only `plan.md` + `story-*.md` off the plan branch | `runner/bin/ob-implement:113-146` | needs two more blocks: PRD, RFC |
| six `openbuilder:*` labels; `ob-respond` re-labels `awaiting-review` after each round | `ob-common.sh:278`, `ob-respond:344` | the review loop's trigger already exists |
| `reviewer` agent posts one verdict and one label | `agent/local/agents/reviewer.md` | gains the RFC as a contract to check against |
| attempt budget of 6, then `blocked` and terminal | `ob-poll:124`, `ob-common.sh:426` | bounds the review loop for free |
| slash commands load from `<cwd>/.omp/commands/*.md` | omp `slash-command-internals.md` §2 | `ob_install_local_assets` mirrors `agent/local/agents` into the clone but **not** commands — one-line gap |
| headless omp, proven | `ob-common.sh:682` | the review loop can run unattended on the laptop |

Two gaps that are not questions, just missing work:

- **Nothing tears down.** `origin` still carries `openbuilder/plan/learn-command` and
  `openbuilder/plan/scrub-hook` for two finished, merged slugs. Their PRs are approved so rule 2
  skips them forever, but the poller and the waker evaluate them on every pass, and the instance
  keeps a worktree and a state directory per slug. `land` has to exist.
- **The review loop is hand-cranked.** Each round needs `openbuilder review`, then
  `openbuilder request-changes`, then `openbuilder review` again. "You talk through GitHub
  comments until it approves" is a `--watch` flag over labels that already change correctly.

## Open questions

### Q1 — One pull request per slug, or one per story?

**Asked because** `ob-implement` hands every card in a slug to a single omp run on a single work
branch and opens one PR (`ob-implement:113-146,266`). Your "or multiple PRs, if it makes sense"
has two readings and they cost very differently.

- **A. PR = slug (recommended).** The backlog stage decides how many PRs by emitting several
  slugs — `plan-workflow-01`, `-02` — each with 1–3 cards. Zero changes to the state machine, the
  label protocol, the waker parity contract or the attempt budget. You dispatch them one at a
  time.
- **B. PR = story.** Per-story work branches, per-story attempt counters, a gate that holds story
  02 until 01 merges, and either stacked branches (which collide with "the bot never force-pushes")
  or serialisation on your merge latency. A new state machine, not an increment — and it buys
  smaller diffs, which A already buys.

**Answered** A — PR = slug. The planner emits several slugs when an epic wants several pull
requests; each carries 1–3 cards.
**Consequence** the state machine, the label protocol, the waker parity contract and the attempt
budget are all unchanged. `depends_on` stays intra-slug; cross-slug order is a human dispatching
the next slug after the previous one merges.

### Q2 — Where do the PRD and the RFC live after the branches are deleted?

**Asked because** the epic docs only exist on `openbuilder/design/*` and `openbuilder/plan/*`,
and the work branch is deliberately cut from the merge-base so they never enter the PR diff
(`ob-implement:83`). Step "the branch is deleted" therefore destroys the reasoning.

- **A. They ride the work branch into `main` (recommended).** `ob-implement` copies
  `.openbuilder/epics/<epic>/` onto the work branch as its first commit, idempotently. Cost: two
  documents in the review diff that the reviewer wants to read anyway. Benefit: merged `main` is
  self-documenting and survives every branch deletion.
- **B. Archive as a tag** — `git tag openbuilder/epic/<epic>` before deleting. Permanent, out of
  the way, and unreadable as documentation.
- **C. Let them die.** The PR body already embeds the plan.

**Answered** A — the epic docs ride the work branch into `main`.
**Consequence** `ob-implement` copies `.openbuilder/epics/<epic>/` onto the work branch, so the
PRD and the RFC appear in the review diff and survive every branch deletion. The copy must be
idempotent, or the second slug of an epic produces an empty commit and the round fails its
"at least one commit" check for the wrong reason.

### Q3 — How do you approve a PRD or an RFC?

**Asked because** the approval has to be durable and tamper-evident, otherwise "approved PRD"
becomes a ceremony an eager agent can edit out from under you. My mechanism either way: record
the artifact's git blob sha in `state.json`, so if the file changes the approval is void and the
workflow refuses to advance. The question is only the surface.

- **A. In the session (recommended for speed).** You say approve; I commit `state.json` with an
  `Approves-prd: <blob>` trailer. Zero friction, no round trip.
- **B. A pull request from the design branch.** You get inline comments, review-from-phone, and a
  GitHub-native audit trail; the cost is an extra PR per epic that is never merged (or is merged
  into `main` — which incidentally answers Q2 as well).

**Answered** A — approval happens in the session.
**Consequence** no design-phase pull request. The approval is still tamper-evident: the artifact's
blob sha is recorded when you approve, and an artifact edited afterwards voids its own approval.

### Q4 — Should the dispatch gate be enforced by the state machine, or by convention?

**Asked because** the trigger is a ref name: `ob-poll` matches `refs/heads/openbuilder/plan/*`
and rule 5 fires as soon as such a branch exists with no PR (`ob-poll:49,132`). A design branch
named `openbuilder/design/<epic>` is invisible to it, so simply not creating the plan branch until
you approve the backlog is a complete gate — enforced by the CLI, i.e. by convention.

- **A. Convention (recommended).** No runner change at all. The one hole is a human pushing
  `openbuilder/plan/*` by hand with an unapproved or empty backlog; today that fails loudly and
  terminally (`read_backlog` dies, slug gets `blocked`), not dangerously.
- **B. Invariant.** Rule 5 additionally requires `state.json` on the plan branch to carry an
  `approvals.backlog` blob matching the committed cards. Because `ob-poll` and `waker/github.py`
  implement the same table by contract (architecture §2 parity), this is the same change in bash
  and Python plus its parity test, and one extra API call per rule-5 candidate.

**Answered** B — enforced by the state machine, overriding my recommendation.
**Consequence** the largest piece of work in this epic. Rule 5 gains a precondition that the plan
branch's `state.json` carries a backlog approval matching the committed cards, and because
`ob-poll` and `waker/github.py` implement the same table by contract (architecture §2, parity),
the rule lands twice — bash and Python — with a test that proves the two agree. In exchange the
gate holds even when the CLI is bypassed, and a plan branch pushed by hand with an unapproved
backlog is skipped rather than burning an attempt into `blocked`.

### Q5 — Is "backlog written" a gate, or does the worker start immediately?

**Asked because** you named approvals for the PRD and the RFC but described the worker starting
once the backlog exists. Dispatch is the first moment money is spent and the last free moment to
veto a bad slice — and the planner is already instructed to surface the decisions it made on the
implementer's behalf "so the human can veto them now rather than at review time"
(`planner.md:139-144`). I want one keystroke there. Say so if you'd rather it were automatic.

**Answered** yes, a gate.
**Consequence** dispatch never happens as a side effect of the backlog being written. Combined
with Q4, the approval is both a keystroke and a fact on the branch.

### Q6 — Which clone does the workflow run in?

**Asked because** `openbuilder plan` clones the target into a CLI-managed workspace and mirrors
the agents into `<clone>/.omp/agents` with `/.omp/` added to the clone's local excludes
(`local/bin/openbuilder:503`). That is not the checkout you are sitting in right now.

- **A. The managed clone (recommended).** The CLI owns branch discipline and asset installation;
  your own working tree is never touched.
- **B. Your current checkout, whatever it is.** Convenient, but the workflow then has to cope with
  your uncommitted work, your branch, and installing `.omp/` assets into a tree you also use.

**Answered** A — the CLI-managed clone.
**Consequence** your own checkouts are never touched, and the workflow may assume a clean tree on
a branch it created.

### Q7 — When does the grill stop?

**Asked because** an interrogation with no stopping rule is a way to never reach a PRD. My
proposed rule: I keep asking only while an unanswered question would change an artifact — a PRD
requirement, an RFC decision, or a story card's acceptance list. Anything the repository can
answer, I answer myself instead of asking. You can say "enough" at any point and I record every
still-open question as a stated assumption in the PRD rather than silently guessing.

**Answered** agreed as proposed.
**Consequence** the stopping rule is written into the workflow skill, not left to judgement: ask
only while an answer would change a PRD requirement, an RFC decision, or an acceptance list;
answer from the repository whatever the repository can answer; on "enough", every still-open
question becomes a stated assumption in the PRD rather than a silent guess.

### Q8 — Bootstrap: who builds this workflow?

**Asked because** the workflow's own tooling lives in the file that dispatches the workflow —
`local/bin/openbuilder`, 1189 lines — and handing that to DeepSeek V4 Flash is a chicken-and-egg
risk: a broken `dispatch` cannot be fixed by dispatching.

- **A. Split (recommended).** I build the stage machinery locally (the command, the skill, the
  `architect` agent, the prompt and agent changes). The remote implementer builds the two
  self-contained additions — `openbuilder land` and `openbuilder review --watch` — through the
  normal loop, which also proves the new flow end to end on real work.
- **B. All remote.** Maximum dogfooding, and the failure mode is that the tool breaks the tool.
- **C. All local.** Safest and least interesting; the remote instance sits idle.

**Answered** B, effectively — the local side does intake, PRD, RFC and the backlog split; the
worker implements the backlog; the local reviewer reviews; you merge.
**Consequence** the chicken-and-egg risk is accepted, and it is smaller than it looked: a broken
`local/bin/openbuilder` on an unmerged work branch cannot break anything, because the instance
runs its own clone of `main` and nothing merges without review. The mitigation is slicing —
`local/bin/openbuilder` changes late and in its own slug, so a bad round there cannot block the
rest of the epic. After any slug touching `runner/` merges, the instance needs `ob-selfupdate`
before the new code runs, and `ob-selfupdate` is allowed to decline while a lock is held
(learning 18), so the acceptance for those slugs must assert the effect, not the exit code.

### Q9 — What is the fast path for a change too small to deserve four gates?

**Asked because** you raised it against the gate-fatigue risk in the PRD, unprompted, which makes
it an intake answer rather than a review comment.

**Answered** a GitHub issue is the entry point for quick fixes — filed from a phone, or filed by the
local agent once it has diagnosed something and stated the fix — and it comes **after** this
workflow exists.
**Consequence** deferred, and correctly so: it is a second trigger, not a shortcut through this
one. The poller's only trigger is `refs/heads/openbuilder/plan/*` (`ob-poll:49`), so an
issue-driven path is a new rule in the rule table, and by the parity contract a new rule in
`waker/github.py` as well, plus a decision about who authors the single card and where the gate
sits when the human has only a phone. Designing it now would mean designing the exception before
the rule exists. Until then the fast path is a one-card epic.

### Q10 — May openbuilder ever touch a repository on an enterprise host?

**Asked because** you stated it as a boundary, and checking it turned up a live hole rather than a
hypothetical one.

**Answered** no. Personal use only: `github.com`, personal account, and no reachable path to a work
or enterprise host.
**Consequence** PRD gains **R11** and a constraint, so the PRD approval recorded at `d5f5736` is
void by its own mechanism — `prd.md`'s blob no longer matches `approvals.prd.blob`, which is exactly
the behaviour R3 demands. RFC gains §4b and a sixth slug, `plan-workflow-00-host`, ordered first.
The hole was: `gh` on this laptop is authenticated to an enterprise host *and* to `github.com`,
`local/bin/openbuilder` makes 23 `gh` calls without pinning `GH_HOST`, and `ob_validate_repo`
checks only that an argument is shaped like `owner/repo` — so `openbuilder plan <work-org>/<repo> x`
passes validation, and the host it resolves to is whatever the environment offers. Nothing has gone
wrong only because the commands have run inside a `github.com` clone. The instance and the waker
were already pinned (`cloud-init.yaml.tftpl:50`, `waker/github.py:27`).

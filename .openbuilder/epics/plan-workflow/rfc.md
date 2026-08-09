# RFC — how `/openbuilder-plan` works

- epic: `plan-workflow`
- repo: `artemkurylo/openbuilder`
- stage: `rfc` — awaiting approval
- implements: `prd.md` (approved 2026-08-09, blob `92074e0`) — requirements cited as **R1**…**R10**
- read with: `docs/architecture.md` §2 (the state machine and the parity contract), `backlog/SCHEMA.md`

Everything asserted about current behaviour was read out of `main` @ `e0d231b`, with file and line
cited. Anything I could not verify is marked `[UNVERIFIED]` and says what would verify it.

---

## 1. Shape of the change

Three ideas carry the whole design.

1. **The epic directory is the durable state.** Stages, approvals and reasoning live in files on a
   branch, not in a session. Every actor — you, the planner, the worker, the reviewer, the poller,
   the waker — reads the same files. (R1, R2, R3)
2. **A branch namespace is the spend switch.** `openbuilder/design/*` is invisible to the poller;
   `openbuilder/plan/*` is the trigger. The design phase therefore cannot start a round by
   accident, and the rule table additionally refuses to act on a plan branch whose backlog is not
   approved. (R4)
3. **Deterministic code records approvals; the model only triggers it.** A new
   `local/bin/ob-gate` computes blob shas, writes `state.json` and commits the trailer. No approval
   record is ever authored by a model, because the whole value of the record is that it is
   mechanical. (R3)

## 2. Artifact layout

Ratifies the provisional layout this epic has been using since intake.

```
.openbuilder/epics/<epic>/intake.md    the grill: one block per resolved question
.openbuilder/epics/<epic>/prd.md       what and why. no implementation.
.openbuilder/epics/<epic>/rfc.md       how. the technical approach.
.openbuilder/epics/<epic>/state.json   stage pointer + approvals. ephemeral coordination.
.openbuilder/backlog/<slug>/plan.md    unchanged (backlog/SCHEMA.md), plus one new line
.openbuilder/backlog/<slug>/story-NN-<name>.md   unchanged
.openbuilder/backlog/<slug>/worklog.md unchanged; written by the instance on the work branch
```

`<epic>` uses the existing slug regex `^[a-z0-9][a-z0-9-]{1,48}$` (`ob-common.sh:140`,
`local/bin/openbuilder` `ob_validate_slug`). One epic, one PRD, one RFC, one or more slugs, one
pull request per slug (R10).

`plan.md` gains exactly one line, in the metadata block under the `# ` heading:

```
- epic: plan-workflow
```

That line is how the runner finds the design docs from a story card. It is a plain bullet, not
frontmatter, because `plan.md` has no frontmatter today (`ob-implement:236` takes the PR title from
the first `# ` heading) and adding a YAML parser to bash for one field would be a second
convention. Extraction is `awk '/^- epic:/ {print $3; exit}'`.

When an epic has one slug, the slug **is** the epic name. With several, they are `<epic>-NN-<name>`
and each `plan.md` carries the same `- epic:` line.

### `state.json`

```json
{
  "epic": "plan-workflow",
  "repo": "artemkurylo/openbuilder",
  "stage": "rfc",
  "opened": "2026-08-09",
  "slugs": ["plan-workflow-01-gate"],
  "approvals": {
    "prd": { "at": "2026-08-09T08:50:27Z", "blob": "92074e0…" },
    "rfc": { "at": "…", "blob": "…" },
    "backlog": {
      "at": "…",
      "slug": "plan-workflow-01-gate",
      "files": { "plan.md": "<blob>", "story-01-…md": "<blob>" }
    }
  }
}
```

`stage` ∈ `intake | prd | rfc | backlog | dispatched | landed`. It names the stage **in progress**,
so `stage: rfc` means the RFC is being written or is awaiting approval, and the PRD approval is
already recorded.

**Why blob shas and not a timestamp or a signature.** A blob sha is what git already computes for
the exact bytes of a file; `git rev-parse <ref>:<path>` yields it locally and the GitHub contents
API returns it as the `sha` field for a file or a directory entry. So the same approval record is
verifiable from the laptop, from the instance, and from the waker with no shared secret, no clock
and no new dependency. Edit the artifact and the sha changes: the approval is void by construction
rather than by policy (R3).

**Why `approvals.backlog` is a file map rather than one digest.** The backlog is many files, and
the gate must catch a card edited after approval. A directory listing from the contents API returns
one blob sha per entry, so an exact set-and-sha comparison is two lines of `jq` and two lines of
stdlib Python. Deriving a git tree sha instead would mean reimplementing tree serialisation in both
languages to save one field. The map also gives a precise refusal: `story-02-…md changed since
approval`, not "the backlog changed".

`state.json` is deliberately **not** part of the record that lands on `main` — see §7.

## 3. Stage machine on the laptop

### 3.1 Entry point

Two ways in, one procedure:

- `openbuilder plan <owner/repo> <epic>` — prepares the clone and launches the Opus 5 session
  (this is today's `cmd_plan`, rewritten).
- `/openbuilder-plan <epic>` — inside an already-running session in that clone.

The slash command is a file at `agent/local/commands/openbuilder-plan.md`, mirrored into
`<clone>/.omp/commands/` by `ob_install_local_assets`. omp discovers project commands at
`<cwd>/.omp/commands/*.md` (omp `slash-command-internals.md` §2), and `.omp/` is already added to
the clone's local git excludes (`local/bin/openbuilder:519`), so nothing leaks into a commit.

`cmd_plan` seeds the session with **prose**, not with `/openbuilder-plan`. Whether omp expands a
slash command supplied as the initial positional prompt is `[UNVERIFIED]`; it would be verified by
running `omp "/openbuilder-plan x"` and observing the expansion. The design does not depend on it:
both entry points say the same thing — load the `openbuilder-workflow` skill and resume epic
`<epic>` — so the answer only affects which of the two is one keystroke shorter.

### 3.2 Resumption (R1)

On entry, in this order:

1. `git rev-parse --verify openbuilder/design/<epic>` — checkout if present, else create it from
   `origin/<default>` and push it. Pushing immediately is free: `ob-poll:49` and
   `waker/github.py:87` both match `refs/heads/openbuilder/plan/` only, so nothing polls
   `design/*`.
2. No epic directory → `stage: intake`, write `state.json`, begin the grill.
3. Epic directory present → read `state.json`, then `ob-gate verify <epic> --all`, which re-checks
   every recorded approval against the current blobs. A void approval stops the session with the
   exact re-approval command (R9). A valid one resumes at `stage`.
4. `stage: intake` → read `intake.md` first and continue at the first block whose **Answered** line
   is still `_pending_`. Never re-ask an answered question.

### 3.3 Stage contracts

| Stage | Actor | Reads | Writes | Advanced by |
|---|---|---|---|---|
| intake | main session, Opus 5 | repo, you | `intake.md` | grill exhausted → writes `prd.md` |
| prd | main session, Opus 5 | `intake.md`, repo | `prd.md` | `ob-gate record <epic> prd` |
| rfc | `architect` subagent | `prd.md`, repo | `rfc.md` | `ob-gate record <epic> rfc` |
| backlog | `planner` subagent | `prd.md`, `rfc.md`, repo | `plan.md` + cards | `ob-gate record <epic> backlog <slug>` |
| dispatched | `openbuilder dispatch` | `state.json` | plan branch on `origin` | the instance |

Intake and the PRD run in the **main** session because they are the only stages that talk to a
human. The RFC and the backlog run in subagents that start blank, which is not a limitation but the
test: if the RFC can only be written from `prd.md` plus the repository, then `prd.md` is provably
sufficient for every downstream reader — including a weak model at 3am with no conversation to
consult.

The grill's stopping rule is written into the skill, not left to taste: ask only while an answer
would change a PRD requirement, an RFC decision, or an acceptance criterion; answer from the
repository anything the repository can answer; on "enough", every still-open question becomes a
stated assumption in `prd.md` rather than a silent guess (R2).

### 3.4 `local/bin/ob-gate` — the only writer of `state.json`

```
ob-gate init    <epic> --repo <owner/repo>     create state.json at stage intake
ob-gate stage   <epic> <stage>                 advance the stage pointer (no approval)
ob-gate record  <epic> prd|rfc                 record approval of that stage's artifact
ob-gate record  <epic> backlog <slug>          record approval of a backlog directory
ob-gate verify  <epic> [prd|rfc|backlog|--all] exit 0 if intact, 3 if void, 4 if absent
ob-gate show    <epic>                         the state, human-readable
```

`record` computes `git rev-parse HEAD:<path>` for the artifact (or every file in the backlog
directory), writes `state.json`, advances `stage` to the next one, commits with a
`Approves-<stage>: <sha>` trailer, and pushes. One command per gate, so an approval is a single
deterministic event that is visible in `git log` without a JSON parser.

Distinct exit codes because callers branch on them: `dispatch` refuses on 3 and 4 with different
messages, and the session's resumption check reports them differently (R9).

Style follows the repo: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, `local` in every
function, and `shellcheck -x -S warning` clean under `make lint` (`AGENTS.md`, house rules).

### 3.5 Dispatch

`cmd_dispatch <owner/repo> <slug>` gains a precondition and loses its scaffold assumptions:

1. resolve `<epic>` from `.openbuilder/backlog/<slug>/plan.md`;
2. `ob-gate verify <epic> backlog` — refuse on anything but 0;
3. `ob-gate stage <epic> dispatched`, committed on the design branch;
4. create `openbuilder/plan/<slug>` **from the design branch tip**, push it;
5. `ob_ensure_labels`, then print what happens next, as today.

Step 4 is what puts the epic documents on the plan branch: the plan branch descends from the design
branch, so `intake.md`, `prd.md`, `rfc.md` and `state.json` are present on it for the runner to
read. The work branch is still cut from `merge-base(plan, default)` (`ob-implement:83`), so none of
this enters the pull-request diff by default.

Order matters: `stage: dispatched` must be committed **before** the plan branch is cut, or the plan
branch carries `stage: backlog` and rule 4b (§4) declines forever.

### 3.6 Review, unattended (R7)

`openbuilder review --watch <owner/repo> <pr>` — poll the PR's labels every
`OPENBUILDER_POLL_INTERVAL`-equivalent (60 s), and act on the first match:

| Label | Action |
|---|---|
| `blocked` | print the blocking comment, exit 4 — a human is required |
| `approved` | print `openbuilder land <repo> <pr>`, exit 0 |
| `changes-requested`, `in-progress` | wait: the instance owns the PR right now |
| `awaiting-review`, head sha unchanged since the last review | wait: this round was already reviewed |
| `awaiting-review`, new head sha | review it |

"Review it" is the existing reviewer agent run headlessly with the verified invocation from
`ob_run_omp` (`ob-common.sh:706`): `omp -p --no-pty --mode json --no-session --max-time … --model
$OB_OPUS_MODEL`, in the clone, with the laptop's own `gh` credentials — which is not an
optimisation but a requirement: `ob-respond` drops conversation comments authored by
`openbuilder*`, so a review posted with the App token is invisible to the worker (learning 12).

The head sha of the last reviewed round is remembered in
`$OPENBUILDER_WORKSPACE/state/<repo>__<pr>/reviewed-head`, which is what makes "no round is
reviewed twice" mechanical rather than hopeful. Round count is capped at
`OPENBUILDER_MAX_ATTEMPTS` (6, `ob-poll:23`) so laptop and instance exhaust together instead of one
outliving the other.

`--watch` is a flag on the existing command rather than a new one: the interactive path stays
exactly as it is for the times you want to read the diff yourself.

### 3.7 Landing (R8)

`openbuilder land <owner/repo> <pr>`:

1. refuse unless the PR carries `openbuilder:approved`;
2. resolve `<slug>` from the PR head branch, `<epic>` from `plan.md`, and show what will be merged
   and what will be deleted; require an explicit typed confirmation;
3. `gh pr merge <pr> --squash --delete-branch`;
4. delete `openbuilder/plan/<slug>` on `origin`; delete `openbuilder/design/<epic>` **only when no
   other slug of the epic is unlanded**, read from `state.json.slugs`;
5. over SSM (`local/bin/obrun`, because SSM runs dash — `docs/runbook.md`): remove the instance's
   worktree for the slug and `state/<repo>__<slug>/`;
6. print the remaining slugs of the epic, if any, with the dispatch command for the next one.

The bot never merges; `land` is human-invoked and refuses to guess a pull request. That property is
unchanged and is checked by the reviewer's frozen-names rubric (`reviewer.md:102`).

## 4. Rule 4b — the spend gate in the state machine (R4)

The load-bearing change, and the only one that lands twice.

### 4.1 Placement

Today's table (`docs/architecture.md` §2, `ob-poll:93-150`) is seven rules, first match wins, at
most one action per slug per pass. The new precondition must sit after the attempt-budget check and
before implement. It is inserted as **rule 4b**, not as a new rule 5 with everything renumbered.

Rationale: the numbers appear in `ob-poll`, in `waker/handler.py`, in the architecture doc, in
`DECISION` log lines an operator greps, and in the reviewer's frozen-names list. Renumbering four
of them to gain a tidy sequence trades a real risk of silent divergence for cosmetics. `4b` sorts
where it belongs and reads unambiguously in a log line:

```
DECISION repo=owner/x slug=y rule=4b action=skip reason=backlog-unapproved
```

### 4.2 The check

For a slug whose plan branch exists and which has no pull request yet:

1. read `.openbuilder/backlog/<slug>/plan.md` on the plan branch; extract `- epic:`. Absent →
   decline;
2. read `.openbuilder/epics/<epic>/state.json` on the plan branch. Absent, unparseable, or
   `stage != "dispatched"` → decline;
3. require `approvals.backlog.slug == <slug>`, and every entry of `approvals.backlog.files` to
   match the blob sha of that file in the plan branch's `.openbuilder/backlog/<slug>/` listing,
   with no extra and no missing `story-*.md`. Mismatch → decline.

Pass → rule 5 proceeds exactly as today. Three GitHub API calls in the rule-5 candidate path only —
contents of `plan.md`, contents of `state.json`, listing of the backlog directory. A slug that
already has a pull request never reaches this check, so the steady-state cost is zero.

### 4.3 Declining quietly

A decline is `action=skip`, and nothing else: no attempt consumed, no label written, no comment, no
`ACTIONABLE` increment, and therefore no wake-up from the waker. The PRD is explicit about this
(R4) and the reason is operational: a loud refusal would label the slug `openbuilder:blocked`,
which `ob-poll:119` treats as terminal, so one human mistake would need a second human to clear.
Today an unapproved plan branch fails inside `read_backlog` (`ob-implement:144`) and does exactly
that.

The one thing a decline must not be is invisible. `ob-poll` writes decisions to stdout — the
journal — and deliberately writes nothing to the operational log on an uneventful pass, because
`ob-idle-stop` reads that log's mtime as "when work last happened" (`ob-poll:6-9`). So rule 4b logs
to stdout only, like every other skip. The visible surface for a human is
`openbuilder status <repo>`, which gains an `unapproved` column.

### 4.4 Parity

`ob-poll` (bash) and `waker/github.py` (zero-dependency Python) implement the same table by
contract, because the waker must decide whether powering the instance on is worth $0.0384/h without
running the instance's code (architecture §2, parity contract). Rule 4b therefore lands in both, and
a one-sided change is the worst failure mode available here: the waker wakes the instance for work
the poller then declines, and the box bills until `ob-idle-stop` notices, every waker tick.

Verification follows the bar already set for the waker: exercise every case against **live GitHub**
in a sandbox repository the instance does not poll, one case per outcome, then clean up — the same
method that proved the waker's five outcomes and the lock probe's four cases. Both implementations
run against the same fixture branches and must produce the same decision. Asserting parity by
reading the two files side by side is not acceptable for this rule.

## 5. The worker's inheritance (R5)

`ob-implement` and `ob-respond` render their prompts through `ob_render_prompt` with a scalar map
and a block map (`ob-common.sh:627`). Two new blocks, `PRD` and `RFC`, populated in `read_backlog`:

```
git -C "$SRC_DIR" show "origin/<plan>:.openbuilder/epics/<epic>/prd.md" > "$ROUND_DIR/prd.md"
```

A missing file is not fatal — it renders as `_(no PRD for this slug)_`. Slugs planned before this
epic have no epic directory and must keep working; making the design docs mandatory would break
`learn-command` and `scrub-hook` and every hand-written backlog.

The prompt sections (`runner/prompts/implement.md`, `respond.md`) state the subordination
explicitly, because a weak model handed a PRD will otherwise implement the PRD:

> The PRD and the RFC are context for judgement, never a source of work. The story cards are the
> only contract. Work implied by the PRD that no card asks for is **out of scope**. If a card and
> the RFC genuinely conflict, stop and report the conflict — do not choose.

That wording matches hard rule 5 already in the prompt ("never invent a missing requirement",
`implement.md:32`), so it reinforces an existing rule rather than adding a competing one.

## 6. Reviewer changes

`reviewer.md` gains the RFC as a checked contract, in the rubric's §2 (contract conformance,
blocking), phrased narrowly on purpose:

> A diff that satisfies every acceptance criterion but solves the problem a different way than the
> approved RFC is a finding, not a preference. Name the RFC decision it departs from. If the
> departure is better, say so and request the RFC be amended — do not approve a design change that
> nobody approved.

Reading order gains `prd.md` and `rfc.md` before the cards. The rubric itself, the severities and
the verdict schema are untouched: the PRD puts them out of scope.

## 7. What lands on `main` (R6)

`ob-implement` copies the epic directory onto the work branch as the round's first commit:

```
docs(epic): PRD and RFC for <epic>
```

Copied: `intake.md`, `prd.md`, `rfc.md`. **Not copied: `state.json`** — it is coordination state,
its stage pointer is stale the moment the branch is deleted, and a stale file on `main` is worse
than a missing one because it is trusted (`AGENTS.md`, "leave the docs true"). The reasoning lands;
the scaffolding dies with the branches.

The copy is idempotent: if the files already match the work branch's content, no commit is made.
This matters mechanically, not just aesthetically — `ob-implement:196` hard-fails a round that
produces no commits, and the second slug of an epic would otherwise attempt an empty commit and
fail for a reason unrelated to the code (PRD §10).

## 8. New and changed files

### New

| Path | What |
|---|---|
| `local/bin/ob-gate` | the only writer of `state.json`; record / verify / stage / show |
| `agent/local/commands/openbuilder-plan.md` | slash command: resolve the epic, load the skill, resume |
| `agent/local/agents/skills/openbuilder-workflow/SKILL.md` | the procedure: stage contracts, grill rules, gate protocol, artifact templates, refusal wording |
| `agent/local/agents/architect.md` | Opus 5 RFC author from PRD + repo |
| `docs/workflow.md` | the workflow as documentation authority |

### Changed

| Path | Change |
|---|---|
| `local/bin/openbuilder` | `cmd_plan` → stage-aware launcher on the design branch; `cmd_dispatch` gains the gate check and cuts the plan branch from the design branch; `cmd_review --watch`; new `cmd_land`; `ob_install_local_assets` also mirrors `agent/local/commands/` into `<clone>/.omp/commands/`; `cmd_status` gains an `unapproved` column |
| `runner/bin/ob-poll` | rule 4b |
| `waker/github.py`, `waker/handler.py` | rule 4b, same semantics |
| `runner/bin/ob-implement` | resolve `- epic:`; read PRD and RFC off the plan branch; two new blocks; copy the epic docs onto the work branch idempotently |
| `runner/bin/ob-respond` | the same two blocks |
| `runner/prompts/implement.md`, `runner/prompts/respond.md` | `## PRD` / `## RFC` sections with the subordination rule |
| `agent/local/agents/planner.md` | read `prd.md` and `rfc.md` instead of interviewing; may emit several slugs; write the `- epic:` line |
| `agent/local/agents/reviewer.md` | the RFC as a checked contract |
| `docs/architecture.md` | rule 4b in §2 and in the parity contract; a §on the workflow; a design-decision entry for "blob shas as approvals" |
| `docs/runbook.md` | the four commands; the refusal table; how to un-void an approval |
| `README.md`, `AGENTS.md` | the workflow is the documented entry point |
| `backlog/SCHEMA.md` | the one new `- epic:` line in `plan.md`. Nothing else. |

## 9. Proposed slicing

Five slugs, five pull requests, dispatched one at a time (R10). Sized against
`backlog/SCHEMA.md`. The planner stage produces the cards; this is the shape I intend and the
reason for the order.

| # | slug | size | depends on | why it is its own PR |
|---|---|---|---|---|
| 1 | `plan-workflow-01-gate` | M | — | `ob-gate` plus the layout. Self-contained, verifiable by running it, and every later slug needs it |
| 2 | `plan-workflow-02-rule` | M | 01 | rule 4b in bash and Python plus the live parity exercise. One reviewer concern, twice |
| 3 | `plan-workflow-03-context` | M | 01 | PRD/RFC into both prompts and the epic-docs copy. Touches `runner/` and the prompts only |
| 4 | `plan-workflow-04-agents` | M | 01 | the command, the skill, the `architect` agent, the planner and reviewer edits, `docs/workflow.md`. No shell |
| 5 | `plan-workflow-05-cli` | L | 01, 02 | `local/bin/openbuilder`: launcher, dispatch gate, `--watch`, `land`. The riskiest file, alone, last |

Merge order is 1 before 2, because rule 4b starts requiring a `state.json` that only `ob-gate`
writes. After any slug touching `runner/` merges, the instance needs `ob-selfupdate` before the new
code runs, and `ob-selfupdate` is allowed to decline while a lock is held and still exit 0
(learning 18) — so those cards must assert the deployed effect, not the exit code.

Slug 5 is sized `L`, which `backlog/SCHEMA.md:102` calls a smell. It is honest here rather than
mislabelled: four commands in one 1189-line file, each meaningless without the others, and
splitting them would produce a `dispatch` that gates against a `state.json` no command can write.
If it fails a round, it fails alone and nothing upstream is blocked.

## 10. Alternatives rejected

- **PR per story.** Per-story branches, per-story attempt counters, a gate holding story 02 until
  01 merges, and either stacked branches — which collide with "the bot never force-pushes" — or
  serialisation on human merge latency. A new state machine for smaller diffs that slug-level
  slicing already gives (intake Q1).
- **The gate by convention only.** Cheaper by two implementations and a live parity exercise, but it
  makes the CLI the enforcement, so any bypass — a hand-pushed branch, a script, a second person —
  reaches the worker. Rejected by intake Q4.
- **Design-phase pull request instead of in-session approval.** Inline comments and phone review,
  at the cost of a PR per epic that is never merged. Rejected by intake Q3; the blob-sha record
  gives the audit trail without it.
- **Renumbering the rule table.** Tidier than `4b`, and it silently changes four documents, two
  implementations and every operator's grep. Not worth it.
- **A YAML frontmatter block in `plan.md`** for the epic reference. Needs a YAML parser in bash for
  one field, beside a file format that deliberately has none.
- **Archiving the epic docs as a tag.** Permanent and out of the way, and unreadable as
  documentation. Rejected by intake Q2.

## 11. Risks and what would catch each

| Risk | Catch |
|---|---|
| rule 4b diverges between poller and waker | both run against the same live fixture branches, one case per outcome, decisions compared — not a side-by-side read |
| the epic-docs copy is not idempotent | a card asserting a second round on the same epic produces no `docs(epic)` commit and the round still succeeds |
| `--watch` reviews the same round twice, or loops | `reviewed-head` marker, and the 6-round cap; a card must exercise both |
| a plan branch cut before `stage: dispatched` is committed | ordering is explicit in §3.5, and the failure is visible as `rule=4b reason=backlog-unapproved` on every pass |
| `state.json` reaches `main` and rots | it is excluded from the copy by name, with a test that the `docs(epic)` commit contains exactly three files |
| the worker breaks the dispatcher it is dispatched by | slug 5 is last and alone; nothing merges without review; the instance runs its own clone of `main` |
| `[UNVERIFIED]` slash expansion of a seeded prompt | irrelevant by construction — both entry points carry the same prose instruction (§3.1) |

## 12. Open assumptions

- `OPENBUILDER_WORKSPACE` is writable on the laptop for the `--watch` marker. Read from
  `.openbuilder.local` today; assumed, not verified in a fresh checkout.
- **Verified, not assumed:** the GitHub contents API returns the git blob sha as `sha` for
  directory entries, so rule 4b's comparison needs one listing call and no content download.
  Proven 2026-08-09 on this very branch: `gh api
  'repos/artemkurylo/openbuilder/contents/.openbuilder/epics/plan-workflow?ref=openbuilder/design/plan-workflow'`
  returned `prd.md 92074e0fa12b82b3b8a5be8880aa843d5bf814bf`, byte-identical to
  `git rev-parse HEAD:.openbuilder/epics/plan-workflow/prd.md`. Slug 2 must still confirm it for a
  repository on the enterprise host if one is ever added to `OPENBUILDER_REPOS`.
- Nothing in this epic changes cost. Rule 4b adds three API calls per unapproved slug per minute
  and no instance time; a declined slug does not wake the box, which if anything lowers spend.

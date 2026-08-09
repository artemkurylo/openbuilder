---
name: openbuilder-workflow
description: The openbuilder design workflow - seven stages from problem statement to merged pull request, four human gates, the intake block format, the grill's stopping rule, the gate protocol, the refusal table and the PRD and RFC templates. Use when running /openbuilder-plan or writing anything under .openbuilder/epics/<epic>/.
globs: .openbuilder/epics/**/*.md
---

# The openbuilder design workflow

One entry point — `/openbuilder-plan <epic>` — carries a piece of work from a
problem statement to a merged pull request through seven stages and four human
gates. Everything that matters lives in files on a branch, not in this session, so
a closed session, a rebooted laptop and a week of interruption cost nothing.

## Artifact layout

```
.openbuilder/epics/<epic>/intake.md    the grill: one block per resolved question
.openbuilder/epics/<epic>/prd.md       what and why. no implementation.
.openbuilder/epics/<epic>/rfc.md       how. the approved technical approach.
.openbuilder/epics/<epic>/state.json   stage pointer + approvals. ephemeral coordination.
.openbuilder/backlog/<slug>/           plan.md, story-*.md cards, worklog.md
```

`<epic>` matches `^[a-z0-9][a-z0-9-]{1,48}$`. One epic, one PRD, one RFC, one or
more slugs, one pull request per slug.

`state.json` holds exactly the fields `epic`, `repo`, `stage`, `opened`, `slugs`
and `approvals`. `stage` is the six-value enum `intake | prd | rfc | backlog |
dispatched | landed`. `approvals.prd` and `approvals.rfc` are `{at, blob}`;
`approvals.backlog` is a map keyed by slug, each entry `{at, files}` with one
blob per file. A blob value is a git blob sha — `git rev-parse <ref>:<path>` —
and `local/bin/ob-gate` is the only writer of `state.json`, by design: the whole
value of an approval record is that it is mechanical.

`plan.md` gains exactly one line from this workflow, as a plain bullet immediately
under its `# ` heading (it has no frontmatter):

```
- epic: <epic>
```

The runner extracts it with `awk '/^- epic:/ {print $3; exit}'` to find the design
docs from a story card.

## Resumption

On entry, in this order:

1. Check out `openbuilder/design/<epic>`, or create it from `origin/<default>` and
   push it immediately — nothing polls `design/*`, so pushing is free.
2. No epic directory → run `ob-gate init <epic> --repo <owner/repo>` (creates
   `state.json` at `stage: intake`) and begin the grill.
3. Epic directory present → read `state.json`, then run `ob-gate verify <epic>
   --all` and branch on its exit code: `0` resumes at `stage`, `3` refuses as
   void, `4` refuses as absent.
4. `stage: intake` → read `intake.md` first and continue at the first block whose
   `**Answered**` line is still `_pending_`.

Never re-ask an answered question.

## The seven stages

The workflow has seven stages, but `state.json.stage` has six values
(`intake | prd | rfc | backlog | dispatched | landed`), because `review` runs
while the pointer still reads `dispatched`. Do not "fix" one of the two numbers.

> Stages 5 to 7 are driven by `openbuilder dispatch`, `openbuilder review --watch`
> and `openbuilder land`. The backlog gate inside `dispatch`, the `--watch` flag and
> the `land` command arrive with the `plan-workflow-05-cli` slug.

### Stage 1 — intake

- **Actor** main session, Opus 5.
- **Reads** the repository, the human.
- **Writes** `intake.md`.
- **Exit** the stopping rule is reached and no block's `**Answered**` line is
  `_pending_`; then `ob-gate stage <epic> prd`.

### Stage 2 — prd

- **Actor** main session, Opus 5.
- **Reads** `intake.md`, the repository.
- **Writes** `prd.md`.
- **Exit** the human approves in the session; then `ob-gate record <epic> prd`.

### Stage 3 — rfc

- **Actor** `architect` subagent.
- **Reads** `prd.md`, the repository.
- **Writes** `rfc.md`.
- **Exit** the human approves in the session; then `ob-gate record <epic> rfc`.

### Stage 4 — backlog

- **Actor** `planner` subagent, one run per slug.
- **Reads** `prd.md`, `rfc.md`, the repository.
- **Writes** `.openbuilder/backlog/<slug>/plan.md` and its `story-NN-<name>.md`
  cards.
- **Exit** the human approves that slug; then `ob-gate record <epic> backlog
  <slug>`.

### Stage 5 — dispatch

- **Actor** `openbuilder dispatch <owner/repo> <slug>`, human-invoked.
- **Reads** `state.json`.
- **Writes** `openbuilder/plan/<slug>` on `origin`.
- **Exit** the plan branch exists on `origin`, cut from the design branch tip
  **after** `stage: dispatched` was committed.

Ordering warning: `stage: dispatched` must be committed on the design branch
before the plan branch is cut, or the plan branch carries `stage: backlog` and
rule 4b declines forever with `reason=backlog-unapproved`.

### Stage 6 — review

- **Actor** `openbuilder review --watch <owner/repo> <pr>` on the laptop.
- **Reads** the PR's labels, diff, cards and worklog.
- **Writes** a PR review and exactly one `openbuilder:*` label per round.
- **Exit** `openbuilder:approved` (exit 0), `openbuilder:blocked` (exit 4), or
  `OPENBUILDER_MAX_ATTEMPTS` (6) rounds spent.

### Stage 7 — land

- **Actor** `openbuilder land <owner/repo> <pr>`, human-invoked.
- **Reads** the PR, `plan.md`, `state.json`.
- **Writes** the squash merge and the branch deletions.
- **Exit** the PR is merged, the epic's branches are gone from `origin`, and
  `stage: landed`.

## The grill

Intake is an interrogation, and its stopping rule is fixed:

> Ask a question only while its answer would change a PRD requirement, an RFC
> decision, or an acceptance criterion. Answer from the repository anything the
> repository can answer. When the human says enough, every still-open question
> becomes a stated assumption in prd.md, never a silent guess.

Every question is one block in `intake.md`:

```
### Qn — <the question, as a question>

**Asked because** <the requirement, design decision or acceptance criterion the
answer would change>

- **A. <option>** <what it costs and what it buys>
- **B. <option>** <what it costs and what it buys>

**Answered** <the chosen option and the human's decision, or _pending_>
**Consequence** <what the answer changed>
```

Three rules make the format work:

- The block is written **when the question is asked**, with `**Answered**
  _pending_` and no `**Consequence**` line.
- `_pending_` is the exact resumption marker read by `## Resumption` step 4.
- The block is updated in place when the answer arrives — never appended as a
  second block, never summarised afterwards.

## The gate protocol

The four gates are PRD, RFC, backlog (once per slug) and merge. At each gate, in
this order:

1. Present the whole artifact in the session and stop.
2. Take no further action that advances a stage.
3. Wait for the human to approve in their own words in this session.
4. Then run the one `ob-gate record` command for that gate.

> Never run ob-gate record on your own initiative. Record an approval only after the
> human has stated it in this session, in their own words. An agent that records its
> own approval has deleted the only gate in the system.

The merge gate is not an `ob-gate record` — it is `openbuilder land`,
human-invoked, which refuses any PR without the `openbuilder:approved` label.
`ob-gate record` also advances `stage`, so it is never paired with a manual
`ob-gate stage`.

## Refusals

The wording below is fixed and reproduced in `docs/workflow.md`: PRD **R9**
requires every refusal to name the reason and the exact next command, and a
reworded string would make the two files disagree.

| Situation | What to say |
|---|---|
| the stage's artifact is not approved in this session | `REFUSED: <stage> is not approved in this session. Next: read the artifact above and say approve.` |
| `ob-gate verify <epic> --all` exits 3 — the recorded blob no longer matches the file on this branch | `REFUSED: approval for <stage> is void - the recorded blob no longer matches the file on this branch. Next: ob-gate record <epic> <stage>` |
| `ob-gate verify <epic> --all` exits 4 — no approval recorded | `REFUSED: no approval recorded for <stage>. Next: ob-gate record <epic> <stage>` |
| `backlog <slug>` contains no story card | `REFUSED: backlog <slug> contains no story-*.md card. Next: write at least one card, then ob-gate record <epic> backlog <slug>` |
| `openbuilder/design/<epic>` is behind `origin` | `REFUSED: openbuilder/design/<epic> is behind origin. Next: git pull --ff-only origin openbuilder/design/<epic>` |
| the working tree is dirty | `REFUSED: the working tree is dirty. Next: git status --short, then commit or stash before advancing a stage` |

## The prd.md template

```
# PRD — <one line>

- epic: <epic>
- repo: <owner/repo>
- stage: <current stage>
- inputs: <intake.md>

## 1. Summary
## 2. Problem
## 3. Actors
## 4. Goals
## 5. Non-goals
## 6. Requirements
## 7. Success criteria
## 8. Constraints and assumptions
## 9. Out of scope
## 10. Risks
```

Requirements in section 6 are numbered `R1`, `R2`, … each with a `### Rn —
<title>` heading, because the RFC and the cards cite those ids. The PRD says what
and why; it contains no implementation.

## The rfc.md template

```
# RFC — <one line>

- epic: <epic>
- repo: <owner/repo>
- stage: <current stage>
- implements: <prd.md blob sha>
- read with: <the docs and schemas the RFC was read against>

## 1. Shape of the change
## 2. Design
## 3. New and changed files
## 4. Proposed slicing
## 5. Alternatives rejected
## 6. Risks and what would catch each
## 7. Open assumptions
```

Three rules:

- `## 2. Design` may be split into as many numbered sections as the design needs,
  and a section added after review is **appended** with a suffixed number (`4b`)
  rather than renumbered, because section numbers appear in cross-references.
- Every claim about current behaviour cites a file and a line.
- Anything not verified is marked `[UNVERIFIED]` and says what would verify it.
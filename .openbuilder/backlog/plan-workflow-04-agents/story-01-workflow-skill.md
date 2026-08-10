---
id: story-01-workflow-skill
title: Add the openbuilder-workflow skill and /openbuilder-plan command
size: M
depends_on: []
files:
  - agent/local/agents/skills/openbuilder-workflow/SKILL.md
  - agent/local/commands/openbuilder-plan.md
acceptance:
  - "agent/local/agents/skills/openbuilder-workflow/SKILL.md exists and its YAML frontmatter parses with exactly the keys name, description, globs"
  - "grep -c '^## [A-Z]' on SKILL.md prints 8, and grep -c '^### Stage [1-7] — ' prints 7"
  - "grep -c '^- \\*\\*Exit\\*\\*' on SKILL.md prints 7"
  - "grep -c 'REFUSED: ' on SKILL.md prints 6, and on agent/local/commands/openbuilder-plan.md prints 2"
  - "grep -c '^## [0-9]' on SKILL.md prints 17 (10 PRD template sections plus 7 RFC template sections)"
  - "the python3 check in ## Acceptance prints OK OK and exits 0, confirming the stopping rule and the never-self-approve rule are present verbatim after whitespace normalisation"
---

## Context

`/openbuilder-plan <epic>` is the workflow's only entry point (PRD **R1**). Today
nothing behind it exists: there is no `agent/local/commands/` directory in this repo,
and the procedure lives in one Opus 5 session.

Two files, two different formats.

**The skill.** `agent/local/agents/skills/write-backlog/SKILL.md` is the bar. Read it
whole (260 lines). Its frontmatter is exactly `name`, `description`, `globs`
(lines 1-5). Its body is a `# ` title, then `##` sections that state a rule and then
justify it with the concrete failure it prevents — see lines 9-16 ("the failure mode
you are designing against"), 100-110 (write for a literal reader), 112-131 (sizing,
with the weak-model cost spelled out) and 133-143 (acceptance items, as a
✗/✓ table). Match that density. A skill that lists rules
without naming the failure each one prevents is not written to this bar.

**The command.** omp discovers project slash commands at `<cwd>/.omp/commands/*.md`,
non-recursive, with `description` taken from frontmatter when present, and expands
`$1` positionally at prompt time. So the file is `agent/local/commands/openbuilder-plan.md`
and it reads the epic name from `$1`.

The command file is **not reachable yet**, and that is expected. This repo has no
`.omp/` directory, and `ob_install_local_assets` (`local/bin/openbuilder:503`) mirrors
only `agent/local/agents/.` into `<clone>/.omp/agents/` (line 509) plus the guardrail
hook (line 514). `plan-workflow-05-cli` adds the `agent/local/commands/` mirror. Do
not add it here.

Everything the skill asserts is fixed by the approved design in
`.openbuilder/epics/plan-workflow/rfc.md` — the layout in §2, resumption in §3.2, the
stage table in §3.3, `ob-gate`'s surface and exit codes in §3.4, dispatch ordering in
§3.5, `--watch` in §3.6 and landing in §3.7. Read those sections. Do not redesign
them; the RFC is approved.

Trap: the workflow has **seven** stages but `state.json.stage` is a **six**-value
enum (`intake | prd | rfc | backlog | dispatched | landed`, RFC §2). `review` runs
while the pointer still reads `dispatched`. The skill must say this explicitly, or a
later reader will "fix" one of the two numbers.

Trap: AGENTS.md's second standing obligation is to leave the docs true. Stages 5 to 7
are driven by commands that do not exist until `plan-workflow-05-cli` lands, so the
skill carries one sentence saying so.

## Change

### 1. `agent/local/agents/skills/openbuilder-workflow/SKILL.md`

Frontmatter, exactly these three keys, in this order, matching `write-backlog`'s
shape:

```yaml
---
name: openbuilder-workflow
description: The openbuilder design workflow - seven stages from problem statement to merged pull request, four human gates, the intake block format, the grill's stopping rule, the gate protocol, the refusal table and the PRD and RFC templates. Use when running /openbuilder-plan or writing anything under .openbuilder/epics/<epic>/.
globs: .openbuilder/epics/**/*.md
---
```

Body: one `# ` title, then exactly these eight `##` sections, in this order, and no
others:

1. `## Artifact layout`
2. `## Resumption`
3. `## The seven stages`
4. `## The grill`
5. `## The gate protocol`
6. `## Refusals`
7. `## The prd.md template`
8. `## The rfc.md template`

`## Artifact layout` — the five paths from RFC §2 in a fenced block
(`intake.md`, `prd.md`, `rfc.md`, `state.json` under
`.openbuilder/epics/<epic>/`, and `.openbuilder/backlog/<slug>/`), the `<epic>` slug
regex `^[a-z0-9][a-z0-9-]{1,48}$`, the `state.json` field list (`epic`, `repo`,
`stage`, `opened`, `slugs`, `approvals`), the six-value `stage` enum, and the fact
that `approvals.prd` and `approvals.rfc` are `{at, blob}` while `approvals.backlog`
is a map keyed by slug holding `{at, files}`. State that a blob value is a git blob
sha — `git rev-parse <ref>:<path>` — and that `local/bin/ob-gate` is the only writer
of `state.json`.

Also state the one `plan.md` line the workflow adds, as a plain bullet immediately
under the `# ` heading, extracted by `awk '/^- epic:/ {print $3; exit}'`:

```
- epic: <epic>
```

`## Resumption` — the four numbered steps of RFC §3.2, in order: (1) checkout
`openbuilder/design/<epic>` or create it from `origin/<default>` and push it;
(2) no epic directory → `ob-gate init <epic> --repo <owner/repo>`, `stage: intake`,
begin the grill; (3) epic directory present → read `state.json`, then run
`ob-gate verify <epic> --all` and branch on its exit code — 0 resume at `stage`,
3 refuse as void, 4 refuse as absent; (4) `stage: intake` → read `intake.md` first
and continue at the first block whose `**Answered**` line is still `_pending_`. Add
the sentence: never re-ask an answered question.

`## The seven stages` — one paragraph stating that there are seven stages but
`state.json.stage` has six values, because `review` runs while the pointer reads
`dispatched`; then this sentence, which keeps the file honest:

> Stages 5 to 7 are driven by `openbuilder dispatch`, `openbuilder review --watch`
> and `openbuilder land`. The backlog gate inside `dispatch`, the `--watch` flag and
> the `land` command arrive with the `plan-workflow-05-cli` slug.

Then exactly seven `###` subsections, with these exact heading lines:

```
### Stage 1 — intake
### Stage 2 — prd
### Stage 3 — rfc
### Stage 4 — backlog
### Stage 5 — dispatch
### Stage 6 — review
### Stage 7 — land
```

Each subsection is four bullets, in this order and with these exact bold labels:
`- **Actor**`, `- **Reads**`, `- **Writes**`, `- **Exit**`. Fill them from RFC §3.3,
§3.5, §3.6 and §3.7:

| Stage | Actor | Reads | Writes | Exit |
|---|---|---|---|---|
| intake | main session, Opus 5 | the repository, the human | `intake.md` | the stopping rule is reached and no block's `**Answered**` line is `_pending_`; then `ob-gate stage <epic> prd` |
| prd | main session, Opus 5 | `intake.md`, the repository | `prd.md` | the human approves in the session; then `ob-gate record <epic> prd` |
| rfc | `architect` subagent | `prd.md`, the repository | `rfc.md` | the human approves in the session; then `ob-gate record <epic> rfc` |
| backlog | `planner` subagent, one run per slug | `prd.md`, `rfc.md`, the repository | `.openbuilder/backlog/<slug>/plan.md` and its `story-NN-<name>.md` cards | the human approves that slug; then `ob-gate record <epic> backlog <slug>` |
| dispatch | `openbuilder dispatch <owner/repo> <slug>`, human-invoked | `state.json` | `openbuilder/plan/<slug>` on `origin` | the plan branch exists on `origin`, cut from the design branch tip **after** `stage: dispatched` was committed |
| review | `openbuilder review --watch <owner/repo> <pr>` on the laptop | the PR's labels, diff, cards and worklog | a PR review and exactly one `openbuilder:*` label per round | `openbuilder:approved` (exit 0), `openbuilder:blocked` (exit 4), or `OPENBUILDER_MAX_ATTEMPTS` (6) rounds spent |
| land | `openbuilder land <owner/repo> <pr>`, human-invoked | the PR, `plan.md`, `state.json` | the squash merge and the branch deletions | the PR is merged, the epic's branches are gone from `origin`, and `stage: landed` |

In the dispatch subsection add the ordering warning from RFC §3.5: `stage: dispatched`
must be committed on the design branch before the plan branch is cut, or the plan
branch carries `stage: backlog` and rule 4b declines forever with
`reason=backlog-unapproved`.

`## The grill` — the stopping rule and the intake block format.

The stopping rule is fixed text. Write it as a blockquote, with no backticks, no bold
and no rewording:

> Ask a question only while its answer would change a PRD requirement, an RFC
> decision, or an acceptance criterion. Answer from the repository anything the
> repository can answer. When the human says enough, every still-open question
> becomes a stated assumption in prd.md, never a silent guess.

Then the intake block format, in a fenced block, exactly this shape — it is the shape
`.openbuilder/epics/plan-workflow/intake.md:63-82` already uses:

```
### Qn — <the question, as a question>

**Asked because** <the requirement, design decision or acceptance criterion the
answer would change>

- **A. <option>** <what it costs and what it buys>
- **B. <option>** <what it costs and what it buys>

**Answered** <the chosen option and the human's decision, or _pending_>
**Consequence** <what the answer changed>
```

State the three rules that make the format work: the block is written **when the
question is asked**, with `**Answered** _pending_` and no `**Consequence**` line;
`_pending_` is the exact resumption marker read by `## Resumption` step 4; and the
block is updated in place when the answer arrives — never appended to as a second
block, never summarised afterwards.

`## The gate protocol` — the four gates are PRD, RFC, backlog (once per slug) and
merge. State the sequence as four numbered steps: present the whole artifact in the
session and stop; take no further action that advances a stage; wait for the human to
approve in their own words in this session; then run the one `ob-gate record` command
for that gate. Then this fixed text as a blockquote, no rewording:

> Never run ob-gate record on your own initiative. Record an approval only after the
> human has stated it in this session, in their own words. An agent that records its
> own approval has deleted the only gate in the system.

Add: the merge gate is not an `ob-gate record` — it is `openbuilder land`,
human-invoked, which refuses any PR without the `openbuilder:approved` label. And:
`ob-gate record` also advances `stage`, so it is never paired with a manual
`ob-gate stage`.

`## Refusals` — a two-column table, `| Situation | What to say |`, with exactly these
six rows. The `What to say` cell is the exact string, and each begins `REFUSED: `:

```
REFUSED: <stage> is not approved in this session. Next: read the artifact above and say approve.
REFUSED: approval for <stage> is void - the recorded blob no longer matches the file on this branch. Next: ob-gate record <epic> <stage>
REFUSED: no approval recorded for <stage>. Next: ob-gate record <epic> <stage>
REFUSED: backlog <slug> contains no story-*.md card. Next: write at least one card, then ob-gate record <epic> backlog <slug>
REFUSED: openbuilder/design/<epic> is behind origin. Next: git pull --ff-only origin openbuilder/design/<epic>
REFUSED: the working tree is dirty. Next: git status --short, then commit or stash before advancing a stage
```

Map rows two and three to `ob-gate verify` exit codes 3 and 4 respectively, in the
`Situation` column. State once, above the table, why the wording is fixed: PRD **R9**
requires every refusal to name the reason and the exact next command, and
`docs/workflow.md` reproduces this table, so a reworded string makes the two files
disagree.

`## The prd.md template` — one fenced block. A `# PRD — <one line>` heading, then the
metadata bullets `- epic:`, `- repo:`, `- stage:`, `- inputs:`, then exactly these ten
numbered sections, each at the start of a line:

- `## 1. Summary`
- `## 2. Problem`
- `## 3. Actors`
- `## 4. Goals`
- `## 5. Non-goals`
- `## 6. Requirements`
- `## 7. Success criteria`
- `## 8. Constraints and assumptions`
- `## 9. Out of scope`
- `## 10. Risks`

State that §6's requirements are numbered `R1`, `R2`, … with a `### Rn — <title>`
heading each, because the RFC and the cards cite those ids, and that the PRD says
what and why and contains no implementation.

`## The rfc.md template` — one fenced block. A `# RFC — <one line>` heading, then the
metadata bullets `- epic:`, `- repo:`, `- stage:`, `- implements:` (naming the PRD's
approved blob), `- read with:`, then exactly these seven numbered sections:

- `## 1. Shape of the change`
- `## 2. Design`
- `## 3. New and changed files`
- `## 4. Proposed slicing`
- `## 5. Alternatives rejected`
- `## 6. Risks and what would catch each`
- `## 7. Open assumptions`

Below the fenced template, state three rules: §2 may be split into as many numbered sections as
the design needs, and a section added after review is **appended** with a suffixed
number (`4b`) rather than renumbered, because section numbers appear in
cross-references; every claim about current behaviour cites a file and a line;
anything not verified is marked `[UNVERIFIED]` and says what would verify it.

### 2. `agent/local/commands/openbuilder-plan.md`

Create the directory `agent/local/commands/`. One file, thin — under 40 lines. It
resolves the epic, loads the skill, and hands over. It must not restate the stage
procedure; that is the skill's job and a second copy will drift.

Frontmatter, one key:

```yaml
---
description: Start or resume the openbuilder design workflow for an epic.
---
```

Body, an ordered instruction list:

1. If `$1` is empty, stop and print exactly:
   `REFUSED: no epic named. Next: /openbuilder-plan <epic>`
2. If `$1` does not match `^[a-z0-9][a-z0-9-]{1,48}$`, stop and print exactly:
   `REFUSED: epic name $1 is not a valid slug. Next: /openbuilder-plan <lower-case-kebab-name>`
3. Read `openbuilder-workflow`'s `SKILL.md` in full before any other tool call.
4. Follow its `## Resumption` section for epic `$1`, then continue at the stage that
   section resolves.
5. Every refusal comes from the skill's `## Refusals` table, verbatim.
6. One line pointing at the gate protocol: approvals are recorded only after the
   human states one, and this command never records an approval.

## Acceptance

Run from the repository root.

- Both files exist:
  `test -f agent/local/agents/skills/openbuilder-workflow/SKILL.md && test -f agent/local/commands/openbuilder-plan.md` exits 0.

- Frontmatter parses as YAML with exactly the three named keys:

  ```bash
  python3 -c '
  import sys
  p = "agent/local/agents/skills/openbuilder-workflow/SKILL.md"
  t = open(p, encoding="utf-8").read().split("---")
  keys = [l.split(":")[0] for l in t[1].strip().splitlines() if l and not l.startswith(" ")]
  assert keys == ["name", "description", "globs"], keys
  print("OK", keys)
  '
  ```

  prints `OK ['name', 'description', 'globs']` and exits 0.

- Structure counts, each printing the stated number:

  ```bash
  S=agent/local/agents/skills/openbuilder-workflow/SKILL.md
  grep -c '^## [A-Z]' "$S"            # 8   (the eight body sections)
  grep -c '^### Stage [1-7] — ' "$S"  # 7
  grep -c '^- \*\*Exit\*\*' "$S"      # 7
  grep -c 'REFUSED: ' "$S"            # 6
  grep -c '^## [0-9]' "$S"            # 17
  grep -c 'REFUSED: ' agent/local/commands/openbuilder-plan.md   # 2
  ```

- The two fixed strings are present verbatim, insensitive to line wrapping:

  ```bash
  python3 - <<'PY'
  import re, sys
  want = [
    "Ask a question only while its answer would change a PRD requirement, an RFC decision, or an acceptance criterion. Answer from the repository anything the repository can answer. When the human says enough, every still-open question becomes a stated assumption in prd.md, never a silent guess.",
    "Never run ob-gate record on your own initiative. Record an approval only after the human has stated it in this session, in their own words. An agent that records its own approval has deleted the only gate in the system.",
  ]
  text = open("agent/local/agents/skills/openbuilder-workflow/SKILL.md", encoding="utf-8").read()
  flat = re.sub(r"[>\s]+", " ", text)
  bad = [w for w in want if w not in flat]
  print(" ".join("OK" for _ in want) if not bad else "MISSING: " + bad[0][:60])
  sys.exit(1 if bad else 0)
  PY
  ```

  prints `OK OK` and exits 0.

- The command file is thin: `wc -l < agent/local/commands/openbuilder-plan.md` prints
  a number below 40.

- The seven stage names appear in order:
  `grep -o 'Stage [1-7] — [a-z]*' agent/local/agents/skills/openbuilder-workflow/SKILL.md`
  prints, in this order, `Stage 1 — intake`, `Stage 2 — prd`, `Stage 3 — rfc`,
  `Stage 4 — backlog`, `Stage 5 — dispatch`, `Stage 6 — review`, `Stage 7 — land`.

## Out of scope

- **No shell.** Do not touch `local/bin/openbuilder`, and specifically do not extend
  `ob_install_local_assets` (`local/bin/openbuilder:503`) to mirror
  `agent/local/commands/`. `plan-workflow-05-cli` does that. Do not create a `.omp/`
  directory in this repo.
- Do not write `local/bin/ob-gate`, and do not run it. It arrives with
  `plan-workflow-01-gate`. The skill quotes its surface and its exit codes; that is
  all.
- No second skill, no second command file, no `agent/local/commands/README.md`.
- Do not edit `agent/local/agents/planner.md`, `reviewer.md`, or anything under
  `agent/local/agents/skills/write-backlog/` — story 02 owns the agent files and the
  `write-backlog` skill is frozen by PRD §9.
- Do not create `docs/workflow.md`. Story 03 owns it.
- Do not add a `model`, `tools`, `thinking`, `allowed-tools` or `argument-hint` key to
  either file's frontmatter. The skill takes `name`, `description`, `globs`; the
  command takes `description`.
- Do not invent extra stages, extra `state.json` fields, an extra `stage` enum value,
  or a fifth gate. Do not renumber the RFC template's sections.
- No worked example, no sample epic, no `intake.md` fixture committed anywhere.
- Do not write `.openbuilder/epics/` content of any kind; this slug ships prompt files
  only.

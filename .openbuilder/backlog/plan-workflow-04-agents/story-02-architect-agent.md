---
id: story-02-architect-agent
title: Add the architect agent; point planner and reviewer at the epic docs
size: M
depends_on:
  - story-01-workflow-skill
files:
  - agent/local/agents/architect.md
  - agent/local/agents/planner.md
  - agent/local/agents/reviewer.md
acceptance:
  - "agent/local/agents/architect.md exists and the python3 frontmatter check prints OK followed by the seven top-level keys name, description, model, thinking, tools, autoloadSkills, output"
  - "architect.md declares output.additionalProperties false and output.required exactly [epic, path, requirements_covered, decisions, unverified, open_assumptions, ready_for_gate], and grep -c '^## ' prints 5"
  - "grep -c 'openbuilder/plan/<slug>' on planner.md prints 0, grep -c '^- epic: ' prints 1, grep -q 'openbuilder-workflow' exits 0, and grep -c '^## ' prints 7"
  - "the python3 reading-order check on reviewer.md prints OK 6, with prd.md as item 1 and rfc.md as item 2"
  - "the python3 verbatim check prints OK, confirming the RFC-departure wording of RFC §6 is present in reviewer.md"
  - "grep -c 'enum: \\[approve, changes-requested\\]' on reviewer.md prints 1, proving the verdict schema is unchanged"
---

## Context

Story 01's skill names `architect` as the actor for stage 3 and `planner` as the actor
for stage 4. This story makes both true, and gives the reviewer the RFC as a contract.

**`architect.md` does not exist.** Model its frontmatter on
`agent/local/agents/reviewer.md:1-42`, which is the only agent in this repo with a
structured `output` schema: keys in the order `name`, `description`, `model`,
`thinking`, `tools`, `autoloadSkills`, `output`; the schema uses
`additionalProperties: false` (line 11), a one-line flow sequence for `required`
(line 12), and a `description` on every property. Copy that shape exactly — a second
convention for agent output schemas is a maintainability finding, and the reviewer's
own rubric flags it (`reviewer.md:112-113`).

**`planner.md` is briefed by a conversation today.** Line 3's description says it
"Turns an idea into a value-sliced backlog"; nothing in the 144-line file mentions
`prd.md` or `rfc.md` (`grep -c 'prd.md\|rfc.md'` prints 0). Line 19 tells it to write
on `openbuilder/plan/<slug>`, which is wrong under the approved design: the backlog is
written on `openbuilder/design/<epic>`, and `openbuilder dispatch` cuts the plan branch
from that branch's tip *after* the backlog gate (RFC §3.5, step 4). Line 7 autoloads
only `write-backlog`. Lines 34-47 specify `plan.md`'s sections and do not mention the
new `- epic:` bullet (RFC §2). Lines 88-89 assume one slug per run. Lines 130-137 are
the boundaries. Lines 139-144 are the closing report.

**`reviewer.md`'s reading order starts at the cards.** Lines 54-63 are four numbered
items: `plan.md`, `story-*.md`, `worklog.md`, the diff. RFC §6 requires `prd.md` and
`rfc.md` ahead of the cards, and adds one bullet to the rubric's section 2 (contract
and acceptance conformance, blocking, lines 88-108). Nothing else in the reviewer
changes: the rubric's three sections, the severities (`blocking`/`important`/`nit`) and
the verdict enum on line 16 are put out of scope by PRD §9 and RFC §6.

Trap: pre-epic backlogs have no `.openbuilder/epics/` directory at all — `learn-command`
and `scrub-hook` are already merged without one, and RFC §5 makes a missing PRD render
as `_(no PRD for this slug)_` rather than fail. A reviewer that treats an absent PRD as a finding
would block every hand-written backlog. It is an observation for the `summary`, never a
comment and never a blocking finding.

Trap: `python3` here has no PyYAML (`import yaml` raises `ModuleNotFoundError`). The
acceptance checks below are stdlib-only by construction; do not add a dependency to
satisfy them.

## Change

### 1. Create `agent/local/agents/architect.md`

Frontmatter, exactly these seven top-level keys in this order. The `description` must
contain no `:` character, because the acceptance check parses keys by line prefix.

```yaml
---
name: architect
description: <one paragraph - Opus 5 architect for openbuilder, writes .openbuilder/epics/<epic>/rfc.md from the approved prd.md plus the repository, and returns a structured result the human gate can check mechanically>
model: amazon-bedrock/us.anthropic.claude-opus-5
thinking: high
tools: read,grep,glob,write,edit,bash,lsp,todo,web_search,yield
autoloadSkills:
  - openbuilder-workflow
output:
  type: object
  additionalProperties: false
  required: [epic, path, requirements_covered, decisions, unverified, open_assumptions, ready_for_gate]
  properties:
    ...
---
```

`tools` is that exact comma-separated string, in that exact order. No `github` and no
`task`: the architect posts nothing and dispatches nothing.

`output.properties` — exactly these seven, each with a `type` and a `description`:

| Property | Type | Description states |
|---|---|---|
| `epic` | string | the epic slug the RFC was written for |
| `path` | string | the repo-relative path written, always `.openbuilder/epics/<epic>/rfc.md` |
| `requirements_covered` | array of string | every PRD requirement id the RFC addresses, as written in the PRD (`R1`, `R2`, …), so the human can diff this list against the PRD's own section 6 |
| `decisions` | array of object | one entry per load-bearing decision; `additionalProperties: false`, `required: [id, decision, rationale, requirements]` — `id` is the RFC section number the decision is recorded in, `decision` is one sentence, `rationale` is why, `requirements` is the list of PRD requirement ids it serves |
| `unverified` | array of object | one entry per claim marked `[UNVERIFIED]` in the RFC; `additionalProperties: false`, `required: [claim, verified_by]` — `verified_by` is the exact command or observation that would settle it |
| `open_assumptions` | array of string | anything the repository could not answer and the RFC assumed; empty when there are none |
| `ready_for_gate` | boolean | true only when no decision in the RFC is left open; false names the unresolved decision in `open_assumptions` |

Body: exactly five `##` sections, in this order, and no others:

1. `## Deliverable`
2. `## What to read, in this order`
3. `## How to decide`
4. `## Boundaries`
5. `## Finish`

`## Deliverable` — one file, `.openbuilder/epics/<epic>/rfc.md`, on the design branch
`openbuilder/design/<epic>`, following the `openbuilder-workflow` skill's
`## The rfc.md template` section by section. Nothing else is written.

`## What to read, in this order` — four numbered items:

1. `.openbuilder/epics/<epic>/prd.md` — the contract. Every requirement id in its
   section 6 is either addressed by the RFC or declared out of scope naming the PRD
   section that puts it there.
2. `.openbuilder/epics/<epic>/intake.md` — context only. It records options already
   rejected and why. Never re-open a question whose `**Answered**` line is filled in.
3. `docs/architecture.md` — the state machine and the parity contract, plus
   `backlog/SCHEMA.md` for what the backlog stage will have to produce.
4. The actual files the change touches. Read them; cite them by path and line.

`## How to decide` — six rules:

- Every claim about current behaviour cites a file and a line, read from the repo, and
  names the ref it was read at.
- Anything not verified is marked `[UNVERIFIED]` in the RFC and appears in
  `unverified` with the command that would verify it. An unmarked guess is a defect.
- Every decision is a decision. If a sentence would contain "decide whether to", stop
  and decide, then record the alternative in `## 5. Alternatives rejected` with its
  cost.
- A section added after review is appended with a suffixed number (`4b`), never a
  renumbering, because section numbers appear in cross-references.
- `## 4. Proposed slicing` is a table of slugs with size, dependencies and one reason
  each for being its own pull request. Sizes follow `backlog/SCHEMA.md`; `L` is
  declared as a smell, not hidden as `M`.
- You start blank on purpose. If the RFC cannot be written from `prd.md` plus the
  repository, the PRD is insufficient — say which requirement is under-specified in
  `open_assumptions` and set `ready_for_gate` to false rather than inventing the
  missing intent.

`## Boundaries` — six prohibitions:

- The only file you write is `.openbuilder/epics/<epic>/rfc.md`. No product code, no
  `local/bin/*`, no `runner/*`, no card.
- You never write `state.json`. `local/bin/ob-gate` is its only writer.
- You never run `ob-gate` in any form, and never commit, push, create a branch, or
  open a pull request.
- Quote the skill's never-self-approve rule and obey it: an approval is recorded only
  after the human states one, and never by you.
- No secrets, tokens, credentials, hostnames, employer or account identifiers in the
  RFC — this repository is public and its contents are processed by a third-party
  model.
- You do not write the backlog. The `planner` does, from your RFC.

`## Finish` — return the structured result matching this agent's `output` schema, and
in the session print the RFC's path, the `requirements_covered` list beside the PRD's
own requirement ids, and every entry of `unverified` and `open_assumptions`, so the
human has what the gate needs in one place.

### 2. Edit `agent/local/agents/planner.md`

Seven edits. Do not restructure the rest of the file.

1. **Line 3, `description`** — replace "Turns an idea into a value-sliced backlog"
   with wording that says it reads the approved `prd.md` and `rfc.md` of an epic and
   emits one or more slugs. The string `Turns an idea into` must not survive.
2. **Line 7-8, `autoloadSkills`** — add `openbuilder-workflow` as a second entry
   under the existing `write-backlog`, keeping `write-backlog` first.
3. **Lines 11-15, the intro** — add one sentence: the brief is
   `.openbuilder/epics/<epic>/prd.md` and `.openbuilder/epics/<epic>/rfc.md`, both
   approved and recorded, not a conversation; there is no interview to conduct and no
   one to ask.
4. **Line 19** — change the branch from `openbuilder/plan/<slug>` to
   `openbuilder/design/<epic>`, and add that `openbuilder dispatch` cuts
   `openbuilder/plan/<slug>` from the design branch tip after the backlog gate
   (RFC §3.5). The literal string `openbuilder/plan/<slug>` must not appear anywhere
   in the file afterwards.
5. **Lines 34-47, the `### plan.md` section** — require the epic bullet immediately
   under the `# ` heading, as a fenced block containing exactly this line at column
   zero, and state that the runner extracts it with `awk '/^- epic:/ {print $3; exit}'`
   and that it is a plain bullet because `plan.md` has no frontmatter:

   ```
   - epic: <epic>
   ```

6. **A new `## What you are given` section immediately before line 91's
   `## Research before you write`** — read `prd.md` first, then `rfc.md`, then the
   repository. State three rules: the RFC's `## 4. Proposed slicing` table is the
   intended shape, and a card set that departs from it must say so in `plan.md`'s
   `## Approach` rather than departing silently; work implied by the PRD that the RFC
   does not design is out of scope; a contradiction between the PRD and the RFC stops
   the stage and is reported to the human, not resolved.
7. **Lines 88-89 and 139-144** — one planner run may emit several slugs for one epic
   (PRD **R10**). Name them `<epic>-NN-<name>`, or use the epic name itself when there
   is only one. Each slug's `plan.md` carries the same `- epic:` line. `depends_on`
   stays inside one slug; cross-slug order is a human dispatching the next slug. The
   `## Finish` report is per slug. Also extend `## Boundaries` (lines 130-137) with:
   never run `ob-gate`, never record an approval, never commit, push or create a
   branch.

After the edits `grep -c '^## '` on the file prints 7.

### 3. Edit `agent/local/agents/reviewer.md`

Three edits, and nothing else.

1. **Line 3, `description`** — add the RFC to the list of what it reads.
2. **Lines 54-63, `## What to read, in this order`** — six numbered items at column
   zero, in this order:
   1. `.openbuilder/epics/<epic>/prd.md`
   2. `.openbuilder/epics/<epic>/rfc.md`
   3. `.openbuilder/backlog/<slug>/plan.md`
   4. every `.openbuilder/backlog/<slug>/story-*.md`
   5. `.openbuilder/backlog/<slug>/worklog.md`
   6. the full diff (`gh pr diff`), then the surrounding code

   Keep the existing explanatory clause on each of the four items that already exist.
   On items 1 and 2 add: a slug planned before the epic layout existed has no epic
   directory; an absent `prd.md` or `rfc.md` is one observation in the `summary`, never
   a line comment and never blocking.
3. **Inside the rubric's section 2, after the `## Out of scope` bullet at lines
   100-101** — one new bullet, whose text is exactly this, wrapping allowed at the
   file's existing width:

   > A diff that satisfies every acceptance criterion but solves the problem a
   > different way than the approved RFC is a finding, not a preference. Name the RFC
   > decision it departs from. If the departure is better, say so and request the RFC
   > be amended — do not approve a design change that nobody approved.

## Acceptance

Run from the repository root.

- `test -f agent/local/agents/architect.md` exits 0.

- The architect's frontmatter, checked with stdlib Python only:

  ```bash
  python3 - <<'PY'
  import re, sys
  t = open("agent/local/agents/architect.md", encoding="utf-8").read()
  assert t.startswith("---\n"), "no frontmatter fence"
  fm = t.split("\n---\n", 1)[0][4:]
  top = re.findall(r"^([A-Za-z_]+):", fm, re.M)
  assert top == ["name","description","model","thinking","tools","autoloadSkills","output"], top
  assert re.search(r"^model: amazon-bedrock/us\.anthropic\.claude-opus-5$", fm, re.M), "model"
  assert re.search(r"^tools: read,grep,glob,write,edit,bash,lsp,todo,web_search,yield$", fm, re.M), "tools"
  assert re.search(r"^  additionalProperties: false$", fm, re.M), "additionalProperties"
  req = re.search(r"^  required: \[(.+)\]$", fm, re.M).group(1).split(", ")
  assert req == ["epic","path","requirements_covered","decisions","unverified","open_assumptions","ready_for_gate"], req
  print("OK", top)
  PY
  ```

  prints `OK ['name', 'description', 'model', 'thinking', 'tools', 'autoloadSkills', 'output']`
  and exits 0.

- `grep -c '^## ' agent/local/agents/architect.md` prints `5`.

- The planner's edits. `grep -c` exits 1 when the count is 0; a printed `0` is the
  expected result for the first line:

  ```bash
  P=agent/local/agents/planner.md
  grep -c 'openbuilder/plan/<slug>' "$P"   # 0
  grep -q 'openbuilder/design/<epic>' "$P"; echo $?   # 0
  grep -c '^- epic: ' "$P"                 # 1
  grep -q 'openbuilder-workflow' "$P"; echo $?        # 0
  grep -Fc 'Turns an idea into' "$P"       # 0
  grep -c '^## ' "$P"                      # 7
  grep -c '^## What you are given' "$P"    # 1
  ```

- The reviewer's reading order, six items, in order:

  ```bash
  python3 - <<'PY'
  import re, sys
  lines = [l for l in open("agent/local/agents/reviewer.md", encoding="utf-8")
           if re.match(r"^[0-9]\. ", l)]
  want = ["prd.md", "rfc.md", "plan.md", "story-", "worklog.md", "gh pr diff"]
  assert len(lines) == 6, len(lines)
  for w, l in zip(want, lines):
      assert w in l, (w, l.strip())
  print("OK", len(lines))
  PY
  ```

  prints `OK 6` and exits 0.

- The RFC-departure wording, verbatim after whitespace normalisation:

  ```bash
  python3 - <<'PY'
  import re, sys
  want = "A diff that satisfies every acceptance criterion but solves the problem a different way than the approved RFC is a finding, not a preference. Name the RFC decision it departs from. If the departure is better, say so and request the RFC be amended — do not approve a design change that nobody approved."
  flat = re.sub(r"[>\s]+", " ", open("agent/local/agents/reviewer.md", encoding="utf-8").read())
  print("OK" if want in flat else "MISSING")
  sys.exit(0 if want in flat else 1)
  PY
  ```

  prints `OK` and exits 0.

- The reviewer's schema is untouched:
  `grep -c 'enum: \[approve, changes-requested\]' agent/local/agents/reviewer.md`
  prints `1`, and
  `grep -c 'enum: \[blocking, important, nit\]' agent/local/agents/reviewer.md`
  prints `1`.

- `grep -c '^### [123]\. ' agent/local/agents/reviewer.md` prints `3` — the rubric
  still has exactly three numbered sections.

## Out of scope

- **No shell.** No change to `local/bin/*`, `runner/*` or `waker/*`. Do not write
  `local/bin/ob-gate` and do not run it.
- No change to the reviewer's rubric structure, its three severities, its verdict
  enum, its `output` schema, its `## Rules for every comment you write` section, its
  `## Verdict` section, or its `## Posting the review` section. RFC §6 restricts the
  change to the reading order and one bullet in rubric section 2.
- No change to `agent/local/agents/skills/review-openbuilder-pr/`, and do not add
  `openbuilder-workflow` to the reviewer's `autoloadSkills` — the reviewer does not
  drive stages.
- No change to `agent/local/agents/skills/write-backlog/` or to `backlog/SCHEMA.md`.
  PRD §9 freezes the card contract and the slicing rules; the planner's `## How to
  slice` section (lines 73-89) keeps its rules, gaining only the multi-slug sentence.
- Do not create `agent/local/commands/openbuilder-plan.md` or the
  `openbuilder-workflow` skill — story 01 owns both.
- Do not create `docs/workflow.md`. Story 03 owns it.
- No new agent beyond `architect`. No `security` agent, no `intake` agent, no `gate`
  agent. Intake and the PRD run in the main session by design (RFC §3.3).
- Do not add `tools`, `model` or `thinking` keys to any skill file, and do not change
  the planner's or reviewer's `model`, `thinking` or `tools` lines.
- No dependency install. `import yaml` fails here; the checks above are stdlib-only
  and must stay that way.
- Do not run `make lint`, `make fmt`, `make scrub`, or a formatter over these files.

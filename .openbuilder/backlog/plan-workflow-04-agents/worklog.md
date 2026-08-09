# Worklog — plan-workflow-04-agents

## Round 1 (2026-08-09)

Implemented all three stories: the `openbuilder-workflow` skill, the
`/openbuilder-plan` command file (dir `agent/local/commands/` created),
the `architect` agent, the planner and reviewer edits, and `docs/workflow.md`.
Three commits on `openbuilder/work/plan-workflow-04-agents`.

### Decisions a future round must not re-derive

- **The epic docs are not in the work-branch worktree.** `.openbuilder/epics/`
  exists only on `openbuilder/design/plan-workflow` and the plan branches; the
  RFC/PRD/intake were read from `origin/openbuilder/design/plan-workflow` via
  `git show` for this round's fixed strings. Nothing committed here depends on
  them at build time — the skill and docs carry the strings verbatim.
- **`docs/workflow.md` and the skill share the six `REFUSED:` strings and the
  grill's stopping rule byte-for-byte by design** (the parity check in
  story-03). Both were written from the same source strings; the check passes.
- **The status line about stages 5–7 is load-bearing.** `docs/workflow.md`
  carries the `<!-- remove when plan-workflow-05-cli lands -->` marker;
  `plan-workflow-05-cli` must delete the whole line and the marker together when
  the commands land, and must also make the skill's matching sentence
  (`Stages 5 to 7 are driven by …`) truthful or remove it.
- **No shell was touched.** `local/bin/openbuilder`'s `ob_install_local_assets`
  still mirrors only `agent/local/agents/.`; the command file is not
  discoverable in a managed clone until `plan-workflow-05-cli` adds the
  `agent/local/commands/` mirror. That is expected per the plan.
- **`pi-uu-grep 0.2.0` on this instance treats `|` as alternation** (not GNU
  BRE), so `grep -c '^| \`openbuilder' docs/workflow.md` counts every line here
  (161) instead of the intended 4. Verified with `python3` instead: exactly four
  lines start with ``| `openbuilder``. The reviewer's laptop (GNU grep) will see
  4. No file content change was needed — this is a tooling quirk, not an
  acceptance failure.

### Verified

- Story-01: files exist; frontmatter keys exactly `name, description, globs`;
  `^## [A-Z]`=8, `^### Stage [1-7] — `=7, `^- **Exit**`=7, `REFUSED: `=6 in the
  skill and 2 in the command file, `^## [0-9]`=17; both fixed strings present
  verbatim after whitespace normalisation (python3 check prints `OK OK`, exit
  0); stage names in order 1–7; command file 15 lines.
- Story-02: architect frontmatter check prints
  `OK ['name', 'description', 'model', 'thinking', 'tools', 'autoloadSkills', 'output']`;
  `^## `=5 on architect.md; planner: `openbuilder/plan/<slug>` count 0,
  `openbuilder/design/<epic>` present, `^- epic: `=1, `openbuilder-workflow`
  present, `Turns an idea into` count 0, `^## `=7, `^## What you are given`=1;
  reviewer reading order `OK 6` (`prd.md` item 1, `rfc.md` item 2); RFC
  departure bullet verbatim (`OK`); verdict enum and severity enum each 1;
  rubric sections 3.
- Story-03: h2=6; four command rows; `REFUSED: `=6; parity check `OK 6`;
  stopping rule verbatim `OK`; `exit 0`/`exit 3`/`exit 4` present; marker
  count 1; only host named is `github.com`.

### Notes for future rounds

- story-02's planner edit #4 wording change: the card asked to add
  "`openbuilder dispatch` cuts `openbuilder/plan/<slug>` from the design branch
  tip" while also forbidding the literal string `openbuilder/plan/<slug>`
  anywhere in the file. Resolved by writing "cuts the per-slug plan branch from
  the design branch tip (RFC §3.5)" — the acceptance `grep -c` for the literal
  prints 0 as required.
- The architect's `output` schema was copied from reviewer.md's shape
  (additionalProperties false, one-line `required` flow sequence, description on
  every property); no second convention introduced.
- No learnings candidate proposed this round — nothing observed met all four
  tests (the pi-uu-grep quirk is instance-specific, not general, and was
  workaroundable with python3).
## Round 1 — 2026-08-09T22:09:13Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.13602437519999996 USD
- story cards: 3

### Agent summary

## Summary
Prompt files only, as scoped: the `openbuilder-workflow` skill (seven stages, four gates, grill stopping rule, six refusals, PRD/RFC templates) and the thin `/openbuilder-plan` command file; the `architect` agent with reviewer-shaped output schema; planner re-briefed on `prd.md`/`rfc.md` plus the `- epic:` line, reviewer's reading order extended to six items with the RFC-departure bullet; `docs/workflow.md` as the documentation authority with the six refusals byte-identical to the skill. Four commits pushed to `openbuilder/work/plan-workflow-04-agents`; worktree clean; no shell touched; no learnings candidate (nothing met all four tests).

## Stories
- story-01-workflow-skill: done — all six acceptance criteria pass (frontmatter keys, counts 8/7/7/6/17, `OK OK` verbatim strings, stage order, command file 15 lines)
- story-02-architect-agent: done — frontmatter check `OK [...seven keys]`, scheduler schema checks, planner 0/1/q0/1/0/7/1, reviewer `OK 6` + verbatim bullet + untouched enums, `^## `=5
- story-03-workflow-doc: done — h2=6, four command rows, refusals parity `OK 6`, stopping rule verbatim, `exit 0/3/4` literals, marker count 1, only host `github.com`

## Verification
- All story-01/02/03 acceptance scripts re-run post-commit against the final tree — every check green (exact counts listed below each story above; run as `python3` where the instance's `pi-uu-grep 0.2.0` treats `|` as alternation and miscounts `^| `openbuilder` — python confirms exactly 4 rows; GNU grep on the reviewer's laptop sees 4)
- `git status --porcelain` -> empty; `git push origin openbuilder/work/plan-workflow-04-agents` -> new branch pushed, remote head `b0c8ebf`
- `make lint` not run by design: all three cards put shell out of scope and `make lint` covers shell only; nothing shell changed this round

## Notes for the reviewer
- The `^| `openbuilder` grep on this instance counts every line (161) because the installed pi-uu-grep implements `|` alternation; ground truth is the file content (4 rows), verified via python. Not an acceptance failure, no file change needed.
- Planner wording: the card both mandates the literal `openbuilder/plan/<slug>` in the dispatch sentence and forbids it in the file; wrote "cuts the per-slug plan branch from the design branch tip" — `grep -c` for the literal is 0 as required.
- `docs/workflow.md`'s status line plus `<!-- remove when plan-workflow-05-cli lands -->`, and the skill's matching "Stages 5 to 7…" sentence, must be made truthful by slug 05 when the commands land.



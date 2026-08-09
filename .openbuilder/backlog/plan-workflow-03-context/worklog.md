# Worklog — plan-workflow-03-context

## Round 001 (story-01..03)

What a future round would otherwise have to rediscover:

- `ob_epic_name`, `ob_epic_doc` and `ob_epic_docs_commit` live in
  `runner/bin/ob-common.sh` under a new `Epic documents` section between
  `ob_render_prompt` and the `omp` divider. The `- epic:` extraction
  (`awk '/^- epic:/ {print $3; exit}'`) is frozen by RFC §2; the value must match
  `^[a-z0-9][a-z0-9-]{1,48}$` or it is treated exactly like an absent line. The
  two fallback strings (`_(no PRD for this slug)_` / `_(no RFC for this slug)_`)
  are written by `ob_epic_doc` only, so they appear nowhere else in the tree.
- Both `ob-implement` and `ob-respond` resolve the epic in `read_backlog` right
  after fetching `plan.md`, log `epic=<name|none>`, and add `PRD`/`RFC` block-map
  rows directly after `STORIES` in `render()`. `ob-respond` additionally
  initialises both block files to the fallback BEFORE the plan-branch
  existence check (lines 174-175 in this tree), because that check can return
  early and an unset block path renders as `_(nothing recorded)_`.
- `copy_epic_docs()` in `ob-implement` sits between `read_backlog` and `render`
  in `main()`. It re-reads `BASE_SHA` unconditionally afterwards — that is the
  ONLY other `BASE_SHA` assignment besides `prepare_repo`, and it is what keeps
  `assert_progress` counting the agent's commits, not the docs commit.
- `ob_epic_docs_commit` copies exactly `intake.md prd.md rfc.md` (never the
  directory, never `state.json`), commits only on content difference, and never
  uses `--allow-empty`. The second slug of an epic is the normal idempotent case:
  it logs `already current; no commit`.
- Docs truth: `docs/architecture.md` ob-implement row now names the epic-docs
  copy. Nothing else referenced the prompt block set.
- Harness quirk (this environment): the interactive shell shadows `grep` with a
  restricted builtin that does not match `^{{PRD}}$`-style patterns; acceptance
  commands must run under a fresh bash (`env -i ... bash --noprofile --norc`) or
  call `/usr/bin/grep` explicitly. GNU grep 3.11.
- `shellcheck 0.10.0` is at `~/.local/bin/shellcheck` (not on PATH); export
  `PATH="$HOME/.local/bin:$PATH"` before `make lint` so it does not take the
  graceful-skip branch.
## Round 1 — 2026-08-09T21:51:47Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.09727076352 USD
- story cards: 3

### Agent summary

## Summary
Implemented R5/R6 of the `plan-workflow` epic: added `ob_epic_name`, `ob_epic_doc` and `ob_epic_docs_commit` to `runner/bin/ob-common.sh` (new `Epic documents` section after `ob_render_prompt`), wired the epic's PRD/RFC into both `ob-implement` and `ob-respond` (`read_backlog` + `PRD`/`RFC` block rows in `render`), appended byte-identical `## PRD`/`## RFC` sections to both prompt templates between `{{STORIES}}` and the worklog, and made `ob-implement` commit `intake.md`/`prd.md`/`rfc.md` onto the work branch as `docs(epic): PRD and RFC for <epic>` before the agent runs, re-baselining `BASE_SHA` so `assert_progress` counts only agent commits. `state.json` is never copied (literal three-name list). Four commits, clean tree.

## Stories
- story-01-epic-doc-blocks: done — helpers + implement wiring; `ob_epic_name` never returns non-zero (returns 0 on unreadable/absent/malformed/backticked `- epic:` values), and both fallback strings (`_(no PRD for this slug)_` / `_(no RFC for this slug)_`) are written into the block file by `ob_epic_doc`, never left empty (an empty block would render `_(nothing recorded)_`).
- story-02-respond-epic-blocks: done — four `ob_epic_doc` calls in `ob-respond` at lines 174, 175 (fallback init, before the plan-branch-gone early return at line 178) and 186, 187 (re-populate after the `plan.md` fetch); prompt regions byte-identical to `implement.md` (parity `diff` prints nothing).
- story-03-epic-docs-commit: done — second `ob_epic_docs_commit` call logged `epic docs for demo-epic already current; no commit`; `BASE_SHA` is re-read in `copy_epic_docs` only (assignments: globals init, `prepare_repo:95`, `copy_epic_docs:161`).

## Verification
- `shellcheck -x -S warning runner/bin/ob-common.sh runner/bin/ob-implement runner/bin/ob-respond` -> rc=0 (shellcheck 0.10.0 from `~/.local/bin`, not the absent-on-PATH skip branch)
- `make lint` -> rc=0 over all runner/local scripts
- story-01 acceptance harness -> PASS (all echoes match: `[demo-epic]`, `[]`, `[]`, `[# PRD body]`, `[_(no PRD for this slug)_]` x2, renders 1/1/4)
- story-02 acceptance harness -> PASS (template counts 1/1/1, parity diff empty, renders 1+1, plan-branch-gone path 1+1)
- story-03 acceptance harness -> PASS (subject `docs(epic): PRD and RFC for demo-epic`, names-only list of the three paths, `state\.json` count 0, idempotent second call adds 0 commits, empty epic rc=0, amended `rfc.md` commits `rfc.md` only)
- `grep -c 'allow-empty' runner/bin/ob-common.sh` -> 0; `grep -c 'docs(epic): PRD and RFC for' docs/architecture.md` -> 1; `make scrub` -> rc=0 (no `.scrub-deny` list present in this worktree, so it was a no-op)
- `git status --porcelain` -> empty

## Notes for the reviewer
- This harness's interactive shell shadows `grep` with a restricted builtin that fails on `^{{PRD}}$`-style patterns; acceptance commands were run under a fresh bash (`env -i ... bash --noprofile --norc`) resolving `/usr/bin/grep` 3.11. Noted in the round worklog for the next round.
- An empty epic document on the plan branch (zero bytes) is treated as absent and falls back — per the card's "non-empty" wording, not a deviation.
- `ob_epic_docs_commit`'s `git commit` failure correctly propagates to fail the round (RFC §7); `ob_epic_name`/`ob_epic_doc` degrade instead.
- No learnings proposed (`learnings-proposed.md` left empty).



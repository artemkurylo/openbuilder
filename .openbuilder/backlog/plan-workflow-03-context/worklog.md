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
---
id: story-03-epic-docs-commit
title: Commit the epic's intake, PRD and RFC onto the work branch, once
size: M
depends_on: [story-01-epic-doc-blocks]
files:
  - runner/bin/ob-common.sh
  - runner/bin/ob-implement
  - docs/architecture.md
acceptance:
  - "`shellcheck -x -S warning runner/bin/ob-common.sh runner/bin/ob-implement` exits 0"
  - "in the harness below, the first `ob_epic_docs_commit` call creates one commit whose subject is exactly `docs(epic): PRD and RFC for demo-epic`"
  - "`git -C $wt show --stat --name-only --pretty=format: HEAD` lists exactly the three paths `.openbuilder/epics/demo-epic/intake.md`, `.openbuilder/epics/demo-epic/prd.md`, `.openbuilder/epics/demo-epic/rfc.md`, and `grep -c 'state\\.json'` over that output prints 0"
  - "a second call with unchanged content adds no commit: `git -C $wt log --oneline --grep='^docs(epic)' | wc -l` prints 1, and `git -C $wt rev-list --count <post-copy-sha>..HEAD` prints 0; a call with an empty epic returns 0 and adds no commit"
  - "`sed -n '/^  prepare_repo$/,/^  run_agent$/p' runner/bin/ob-implement` prints exactly the five lines `prepare_repo`, `read_backlog`, `copy_epic_docs`, `render`, `run_agent` in that order, and `grep -c 'docs(epic): PRD and RFC for' docs/architecture.md` prints 1"
---

## Context

R6 of the PRD: after the pull request merges and every branch is deleted, the PRD and the RFC must be
readable from the default branch alone. RFC §7 says how: `ob-implement` copies the epic directory onto
the work branch as the round's first commit, with the message `docs(epic): PRD and RFC for <epic>`.

`story-01` added `ob_epic_name` and `ob_epic_doc` to `runner/bin/ob-common.sh` and set the global
`EPIC` in `ob-implement`'s `read_backlog()`. This story adds the copy. Read
`story-01-epic-doc-blocks.md` for those contracts.

Four facts that decide the design.

1. **The work branch does not have the documents.** It is cut from
   `merge-base(origin/<plan>, origin/<default>)` (`ob-implement:83-84,92`), and the epic directory
   lives on the plan branch (RFC §3.5). So the copy source is
   `origin/<plan-branch>:.openbuilder/epics/<epic>/<file>`, exactly as `read_backlog` reads the cards
   (`ob-implement:115,118`).
2. **An empty commit fails the round for the wrong reason.** `git commit` refuses a no-op, and
   `ob-implement`'s `on_exit` (`ob-implement:50-69`) turns any non-zero exit into a blocked report on
   the pull request. The second slug of an epic branches from a merge-base that already contains the
   documents — that is the normal case, not the exception — so the copy must compare content and
   commit only on a difference (RFC §7, PRD §10 risk 3).
3. **`assert_progress` counts commits from `BASE_SHA`.** `BASE_SHA` is captured in `prepare_repo`
   (`ob-implement:94`) and `assert_progress` requires `rev-list --count "${BASE_SHA}..HEAD"` ≥ 1
   (`ob-implement:196-200`). If the docs commit lands after that snapshot and `BASE_SHA` is left
   alone, a round in which the agent committed nothing would still pass the check. The re-baseline in
   step 2 below is what keeps that check about the agent.
4. **`state.json` must not land.** It is coordination state; its `stage` pointer is stale the moment
   the branch is deleted, and `AGENTS.md` is explicit that a stale doc is worse than a missing one
   because it is trusted. It is excluded **by name**: the copy iterates a literal three-item list and
   never enumerates the directory, so a file added to the epic directory later cannot leak onto the
   default branch by accident.

`ob_worklog_append` (`ob-common.sh:505`) is the precedent for a library function that writes into the
worktree; it is also why this one belongs in the library rather than inline in `ob-implement` — a
sourced function is exercisable from a worktree with plain `git`, which is what makes the acceptance
block below runnable without an instance.

## Change

### 1. `runner/bin/ob-common.sh` — `ob_epic_docs_commit`

Append one function to the `Epic documents` section `story-01` created, after `ob_epic_doc`, with a
header comment stating why `state.json` is excluded and why the comparison exists.

`ob_epic_docs_commit <src-dir> <plan-ref> <epic> <worktree>`

- `<epic>` empty → return 0 immediately. No log line, no commit: a backlog with no `- epic:` line is
  normal, not noteworthy.
- Destination is `<worktree>/.openbuilder/epics/<epic>`.
- Iterate exactly the literal list `intake.md prd.md rfc.md`, in that order. Do not list the
  directory, do not glob, do not copy `state.json` or any other name.
- For each: `git -C <src-dir> show "<plan-ref>:.openbuilder/epics/<epic>/<name>"` into a single
  reused temporary file created with `mktemp`, discarding stderr and tolerating a non-zero exit. An
  empty result means the file is absent on the plan branch — skip it silently, do not fail.
- Copy only when it differs: when the destination file does not exist, or when `cmp -s` reports a
  difference, `mkdir -p` the destination directory, copy the temporary file over it, and record that
  something changed.
- Remove the temporary file before returning, on every path.
- Nothing changed → `ob_log INFO "epic docs for <epic> already current; no commit"` and return 0. No
  `git add`, no `git commit`, no `--allow-empty` anywhere.
- Something changed → `git -C <worktree> add -- ".openbuilder/epics/<epic>"`, then
  `git -C <worktree> commit --quiet -m "docs(epic): PRD and RFC for <epic>"`, then
  `ob_log INFO "committed epic docs for <epic> (intake.md, prd.md, rfc.md)"`.
- A failing `git commit` propagates and fails the round. That is correct — do not swallow it.

### 2. `runner/bin/ob-implement` — call it before the agent runs

1. Add a new function `copy_epic_docs()` between the end of `read_backlog()` (`ob-implement:146`) and
   the start of `render()` (`ob-implement:148`). It does exactly two things, in this order:
   - `ob_epic_docs_commit "$SRC_DIR" "origin/${PLAN_BRANCH}" "$EPIC" "$WT_DIR"`
   - `BASE_SHA="$(git -C "$WT_DIR" rev-parse HEAD)"` — unconditionally, whether or not a commit
     happened.

   Give it a header comment saying why the re-baseline exists: `assert_progress` must count the
   agent's commits, not this one.
2. In `main()`, call `copy_epic_docs` on its own line between `read_backlog` (`ob-implement:331`) and
   `render` (`ob-implement:332`). It runs before `render` and therefore before `run_agent`, so the
   documents are in the worktree the agent works in and not only in its prompt.
3. Change nothing else in `main()`: the label transitions, the lock, the attempt counter and the
   push/PR sequence stay as they are.

### 3. `docs/architecture.md` — keep the round description true

In the `ob-implement` row of the component table (`docs/architecture.md:38`), insert the clause

```
copy the epic's `intake.md`, `prd.md` and `rfc.md` onto the work branch as `docs(epic): PRD and RFC for <epic>` when their content differs,
```

immediately after the words `in slug order,` and before the words `render` and
`prompts/implement.md` in the same row. The row stays one line. Change nothing else in that file — no
new section, no rule-table edit, no `docs/workflow.md`.

## Acceptance

- `shellcheck -x -S warning runner/bin/ob-common.sh runner/bin/ob-implement` exits 0.
- Ordering and doc-truth, each printing what is shown:

  ```sh
  sed -n '/^  prepare_repo$/,/^  run_agent$/p' runner/bin/ob-implement
  #   prepare_repo
  #   read_backlog
  #   copy_epic_docs
  #   render
  #   run_agent
  grep -c 'docs(epic): PRD and RFC for' docs/architecture.md    # 1
  grep -c 'allow-empty' runner/bin/ob-common.sh                 # 0
  ```

- Run this from the repository root of the worktree. Every printed value must match the comment.

  ```sh
  tmp="$(mktemp -d)"; fix="$tmp/fix"; wt="$tmp/wt"
  git init -q "$fix"
  git -C "$fix" config user.name t
  git -C "$fix" config user.email t@example.com
  printf 'seed\n' >"$fix/README.md"
  git -C "$fix" add -A && git -C "$fix" commit -qm seed
  def="$(git -C "$fix" rev-parse --abbrev-ref HEAD)"
  git -C "$fix" checkout -q -b plan
  mkdir -p "$fix/.openbuilder/epics/demo-epic"
  printf '# intake body\n' >"$fix/.openbuilder/epics/demo-epic/intake.md"
  printf '# PRD body\n'    >"$fix/.openbuilder/epics/demo-epic/prd.md"
  printf '# RFC body\n'    >"$fix/.openbuilder/epics/demo-epic/rfc.md"
  printf '{"stage":"dispatched"}\n' >"$fix/.openbuilder/epics/demo-epic/state.json"
  git -C "$fix" add -A && git -C "$fix" commit -qm plan
  git -C "$fix" checkout -q "$def"
  git -C "$fix" worktree add -q -b work "$wt" "$(git -C "$fix" merge-base plan HEAD)"
  git -C "$wt" config user.name t
  git -C "$wt" config user.email t@example.com

  # shellcheck source=/dev/null
  source runner/bin/ob-common.sh

  ob_epic_docs_commit "$fix" plan demo-epic "$wt" 2>/dev/null
  git -C "$wt" log -1 --pretty=%s            # docs(epic): PRD and RFC for demo-epic
  git -C "$wt" show --stat --name-only --pretty=format: HEAD | sed '/^$/d'
  #   .openbuilder/epics/demo-epic/intake.md
  #   .openbuilder/epics/demo-epic/prd.md
  #   .openbuilder/epics/demo-epic/rfc.md
  git -C "$wt" show --name-only --pretty=format: HEAD | grep -c 'state\.json' || true   # 0

  # the re-baseline copy_epic_docs performs, and idempotence
  base2="$(git -C "$wt" rev-parse HEAD)"
  ob_epic_docs_commit "$fix" plan demo-epic "$wt" 2>/dev/null
  git -C "$wt" log --oneline --grep='^docs(epic)' | wc -l | tr -d ' '   # 1
  git -C "$wt" rev-list --count "${base2}..HEAD"                        # 0
  ob_epic_docs_commit "$fix" plan "" "$wt" 2>/dev/null; echo "rc=$?"    # rc=0
  git -C "$wt" rev-list --count "${base2}..HEAD"                        # 0

  # an amended document on the plan branch does commit again
  git -C "$fix" checkout -q plan
  printf '# RFC body v2\n' >"$fix/.openbuilder/epics/demo-epic/rfc.md"
  git -C "$fix" commit -qam amend
  git -C "$fix" checkout -q "$def"
  ob_epic_docs_commit "$fix" plan demo-epic "$wt" 2>/dev/null
  git -C "$wt" show --name-only --pretty=format: HEAD | sed '/^$/d'     # rfc.md only
  git -C "$fix" worktree remove --force "$wt"
  rm -rf -- "$tmp"
  ```

- State in the final message that the second `ob_epic_docs_commit` call logged
  `epic docs for demo-epic already current; no commit`, and that `BASE_SHA` is re-read in
  `copy_epic_docs` and nowhere else.

## Out of scope

- `state.json`: not copied, not parsed, not read. No `jq`, no stage check, no approval check — slug
  `plan-workflow-02-rule` owns rule 4b and slug `plan-workflow-01-gate` owns `state.json`.
- No change to `runner/bin/ob-respond` or `runner/prompts/respond.md` (`story-02`), and no change to
  the two prompt templates at all in this story.
- No change to `ob_epic_name` or `ob_epic_doc` (`story-01`). If one is wrong, report a blocker.
- No `git rm` of anything on the work branch, no cleanup of an epic directory that a previous round
  left, no `--allow-empty`, no `--amend`, no force-push.
- The copy does not touch `worklog.md`, does not reorder `record_worklog`, and does not change
  `assert_progress`'s threshold or message.
- No new configuration variable to enable or disable the copy, and no `--no-epic-docs` flag.
- `docs/architecture.md`: one clause in one table row only. No rule-table edit, no new section, no
  `docs/workflow.md`, no `README.md`, no `docs/runbook.md`.
- No test directory, no harness script committed to the repository, no writes under
  `/opt/openbuilder`, no `ob-selfupdate`.

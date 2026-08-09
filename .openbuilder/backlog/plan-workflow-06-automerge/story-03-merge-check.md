---
id: story-03-merge-check
title: Add `openbuilder merge-check` for lint and scrub on the merge result
size: M
depends_on: []
files:
  - local/bin/openbuilder
  - docs/runbook.md
acceptance:
  - "`openbuilder merge-check <repo> <pr>` on a mergeable, clean pull request prints `cond=4 result=pass`, `cond=5 result=pass`, `cond=6 result=pass` and exits 0"
  - "with `shellcheck` absent from PATH it prints `lint tool unavailable; refusing to treat a skipped check as a pass` and exits 1, having created no worktree"
  - "with `OPENBUILDER_SCRUB_DENY` pointing at a nonexistent file it prints `scrub deny list unreadable at <path>; refusing to treat a skipped check as a pass` and exits 1"
  - "on a pull request that conflicts with the default branch it prints `trial merge conflicts with <branch>; rebase or merge by hand` and exits 1"
  - "after every run, success or failure or Ctrl-C, `$OB_CACHE_DIR/automerge/<pr>` does not exist and `git worktree list` in the clone shows only the clone itself"
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
---

## Context

This repository has no `.github/workflows` — verified — so nothing runs on a pull request, the
reviewer is the only gate, and `main` is what `ob-selfupdate` deploys onto the instance. A bad merge
does not just ship a bug: it can break the machine that would otherwise fix it (RFC §3.8.3). Two pull
requests that each pass alone and fail together are the class this catches, and checking the branch
instead of the merge result would miss all of it.

This story implements RFC §3.8.2 conditions **4, 5 and 6** and nothing else, as a standalone
subcommand a human can run: `openbuilder merge-check <owner/repo> <pr>`. `story-04` consumes it for
`--auto-merge`. It makes **no** GitHub mutation, needs **no** token, and merges nothing, ever.

### Both checks pass vacuously by default. This is the whole difficulty of the story.

Measured in a real scratch worktree of this repository, 2026-08-09 (RFC §3.8.3.1):

| run | exit | output |
|---|---|---|
| `make scrub` in a scratch worktree | `0` | `ob-scrub-check: no deny list at <wt>/.scrub-deny; nothing to check.` |
| same, with `OPENBUILDER_SCRUB_DENY` at the operator's list | `0` | `ob-scrub-check: clean (worktree).` and `ob-scrub-check: clean (history).` |
| `make lint` with `shellcheck` absent | `0` | `shellcheck not installed — skipping lint.` |
| `make lint` with `shellcheck` present | `0` | `shellcheck -x -S warning runner/bootstrap.sh local/bin/… runner/bin/…` |

The deny list is **gitignored on purpose** (`local/bin/ob-scrub-check:26` reads
`${OPENBUILDER_SCRUB_DENY:-$REPO_ROOT/.scrub-deny}`, and `:43` exits 0 when it is unreadable), so it is
absent from every scratch worktree, on every machine, always. `make lint` skips and exits 0 when the
linter is missing (`Makefile:80-84`, LEARNINGS 19). A check that reads either exit code as success is
a rubber stamp, and this command exists to be the substitute for CI.

So: **require the tooling to be present before accepting a result, and assert the output, never the
exit status** (LEARNINGS 18 and 19).

### Assert with `grep -F`, always

`ob-scrub-check` prints `ob-scrub-check: clean (worktree).`. Measured on this laptop:
`grep -c 'clean (worktree)'` prints `0` and `grep -cF 'clean (worktree)'` prints `1` — the parentheses
are metacharacters under an extended-regex grep and the bare pattern silently fails. Every assertion
you write against `make`, `gh` or `git` output in this story uses `grep -F` (or `grep -qF`). A
detector that fails to match refuses a good merge while looking like the gate working, which is worse
than no detector.

### What to copy

- `ob_ensure_clone <repo>` (`openbuilder:527-541`) prints the clone directory and fetches; it also
  asserts the origin host. `ob_default_branch <repo>` (`503-505`). `ob_gh` (`453-455`) is the pinned
  `gh`; every `gh` call goes through it.
- `OB_CACHE_DIR` is `${XDG_CACHE_HOME:-$HOME/.cache}/openbuilder` (`openbuilder:51`), already used for
  the region and instance-id scraps after an unconditional `mkdir -p` (`176-191`, `221-237`).
- `OB_ROOT` (`openbuilder:49`) is this repository's root — where the operator's `.scrub-deny` lives
  when `OPENBUILDER_SCRUB_DENY` is unset.
- `cmd_cost` (`openbuilder:1101-1122`) for the shape of a small command with one report.
- `ob_command_table` (`576-…`) and the `case` in `main` for registration.

### Traps

- `ob-scrub-check` resolves its deny list from `git rev-parse --show-toplevel` of the **current
  directory**, so the path must be absolute and outside the worktree, and the checks must run with the
  worktree as cwd. Use a subshell: `(cd "$wt" && …)`.
- `git worktree remove --force` removes a worktree with the uncommitted trial merge in it — verified;
  one `--force` is enough. It still fails if the directory was deleted underneath it, so keep the
  `rm -rf` fallback and the `worktree prune`.
- The script has `set -euo pipefail` (`openbuilder:38`) and **no** existing `trap`. Yours is the first;
  do not remove it and do not add a second.
- A `make` invocation must never abort the script through `set -e`: capture with
  `out=$( … 2>&1 ) || rc=$?` and inspect `rc` and `out` yourself.

## Change

All in `local/bin/openbuilder`.

### 1. State for the cleanup

Beside `OB_LOG_CHUNK_BYTES` (line 77), two globals with a comment saying they exist so the worktree is
removed on every exit path:

```
OB_MERGE_CHECK_WT=''
OB_MERGE_CHECK_DIR=''
```

### 2. `ob_merge_check_cleanup`

Add above `ob_merge_check`. Takes no arguments. When `$OB_MERGE_CHECK_WT` is empty it returns 0
immediately. Otherwise, in order, ignoring every failure:

1. `git -C "$OB_MERGE_CHECK_DIR" worktree remove --force "$OB_MERGE_CHECK_WT" 2>/dev/null || rm -rf "$OB_MERGE_CHECK_WT"`
2. `git -C "$OB_MERGE_CHECK_DIR" worktree prune 2>/dev/null || true`
3. `OB_MERGE_CHECK_WT=''`

It must be safe to call twice.

### 3. `ob_merge_check <owner/repo> <pr>`

The contract, which `story-04` depends on and which must not drift:

- **stdout**: one line per condition, in order, exactly
  `cond=<4|5|6> result=<pass|fail> detail=<text>`. On a failure the `detail` is the RFC §3.8.2
  refusal string **verbatim**, and no further `cond=` line is printed.
- **return**: `0` when 4, 5 and 6 all pass; `1` at the first failure.
- **effect**: the scratch worktree is gone before every `return`, and on `INT`/`TERM`.

Body, in this order — the two tooling checks come first because they are the cheapest and because a
missing tool must never reach a worktree:

1. `local repo=$1 pr=$2`; `ob_need git gh make`.
2. **Lint tooling.** `command -v shellcheck >/dev/null 2>&1` — if not:
   ```
   printf 'cond=5 result=fail detail=lint tool unavailable; refusing to treat a skipped check as a pass\n'
   return 1
   ```
3. **Scrub deny list.** `deny=${OPENBUILDER_SCRUB_DENY:-$OB_ROOT/.scrub-deny}`; when `$deny` does not
   start with `/`, make it absolute against `$PWD`. Then:
   - not readable →
     `printf 'cond=6 result=fail detail=scrub deny list unreadable at %s; refusing to treat a skipped check as a pass\n' "$deny"`, return 1.
   - readable but with no usable pattern — `grep -cvE '^[[:space:]]*(#|$)' -- "$deny"` prints `0` →
     `printf 'cond=6 result=fail detail=scrub deny list %s has no usable patterns; refusing to treat a skipped check as a pass\n' "$deny"`, return 1.
     `ob-scrub-check:56-59` exits 0 in exactly that case, which is the same vacuous pass wearing a
     different hat.
4. `dir=$(ob_ensure_clone "$repo")`; `base=$(ob_default_branch "$repo")`;
   `head=$(ob_gh pr view "$pr" --repo "$repo" --json headRefName --jq '.headRefName')`. An empty
   `head` → `ob_die "cannot read pull request #$pr in $repo"` (the wording `cmd_review` already uses).
   Then `git -C "$dir" fetch --prune --quiet origin`.
5. Create the worktree:
   ```
   wt="$OB_CACHE_DIR/automerge/$pr"
   mkdir -p "$(dirname "$wt")"
   rm -rf "$wt"
   git -C "$dir" worktree prune
   OB_MERGE_CHECK_DIR="$dir"
   trap 'ob_merge_check_cleanup' EXIT INT TERM
   git -C "$dir" worktree add --detach --quiet "$wt" "origin/$base" || ob_die "cannot create the merge-check worktree at $wt"
   OB_MERGE_CHECK_WT="$wt"
   ```
   Set `OB_MERGE_CHECK_WT` **after** the worktree exists, so a failed `add` does not make cleanup
   delete a directory it did not create.
6. **Condition 4.** `git -C "$wt" merge --no-ff --no-commit --quiet "origin/$head"`; non-zero →
   ```
   printf 'cond=4 result=fail detail=trial merge conflicts with %s; rebase or merge by hand\n' "$base"
   ob_merge_check_cleanup
   return 1
   ```
   Success → `printf 'cond=4 result=pass detail=merged into %s without conflict\n' "$base"`.
7. **Condition 5.** `out=$( (cd "$wt" && make lint) 2>&1 ) || rc=$?` with `rc=0` initialised first.
   Then, in this order:
   - `printf '%s\n' "$out" | grep -qF 'skipping lint'` **or** `grep -qF 'nothing to lint'` → fail with
     `lint tool unavailable; refusing to treat a skipped check as a pass`.
   - `rc != 0` → fail with `lint failed on the merge result, not on the branch`.
   - `printf '%s\n' "$out" | grep -qF 'shellcheck -x -S warning'` must succeed; if it does not, fail
     with `lint failed on the merge result, not on the branch` — the linter did not run, and a check
     that did not run is not a pass.
   - otherwise `printf 'cond=5 result=pass detail=shellcheck -x -S warning ran on the merge result\n'`.

   Every failure prints its `cond=5 result=fail detail=<string>` line, calls
   `ob_merge_check_cleanup`, and returns 1.
8. **Condition 6.** `out=$( (cd "$wt" && OPENBUILDER_SCRUB_DENY="$deny" make scrub) 2>&1 ) || rc=$?`.
   Then:
   - `grep -qF 'nothing to check'` or `grep -qF 'no usable patterns'` → fail with
     `scrub deny list unreadable at <deny>; refusing to treat a skipped check as a pass`.
   - `rc != 0` → fail with `scrub failed on the merge result`.
   - both of `printf '%s\n' "$out" | grep -cF 'clean (worktree).'` and `grep -cF 'clean (history).'`
     must print `1`; anything else → fail with `scrub failed on the merge result`. `make scrub` runs
     `ob-scrub-check` twice (`Makefile:97-99`), so exactly these two lines are the proof that both
     passes happened.
   - otherwise `printf 'cond=6 result=pass detail=clean (worktree) and clean (history)\n'`.
9. `ob_merge_check_cleanup`; `return 0`.

Nothing in this function may `git push`, `gh pr merge`, `git commit`, or write anywhere except the
worktree it created and removes.

### 4. `cmd_merge_check <owner/repo> <pr>`

```
local usage="usage: $OB_PROG merge-check <owner/repo> <pr>"
[[ $# -eq 2 ]] || ob_die "$usage"
```
then `ob_validate_repo`, `ob_validate_pr`, `ob_need git gh make jq`, then
`ob_info "checking the merge of #$pr into the default branch of $repo"`, then `ob_merge_check` with
its output passed straight through, then print `merge-check: PASS` and return 0, or
`merge-check: FAIL` on stderr and return 1.

### 5. Registration

- `main`'s `case`: `merge-check) cmd_merge_check "$@" ;;` immediately after the `review)` line.
- `ob_command_table`: after the `review` line,
  ```
    merge-check <owner/repo> <pr>      run the repo's own lint and scrub on the PR merged into main
  ```
  Keep the existing two-space indent and description column; do not reflow the rest of the heredoc.

### 6. `docs/runbook.md`

- §19 quick reference: one row, `Will this PR break main?` →
  `openbuilder merge-check you/your-repo <pr>`.
- §20 (`## 20. Refusals from the laptop CLI`, added by `plan-workflow-05-cli` story-04): one row per
  refusal string this story adds, quoted verbatim from the source — the two tooling refusals, the
  no-usable-patterns one, `trial merge conflicts with`, `lint failed on the merge result, not on the
  branch`, and `scrub failed on the merge result` — each with its cause and its fix (install
  shellcheck; create or point `OPENBUILDER_SCRUB_DENY` at the deny list; rebase; fix the code).

## Acceptance

`shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.
`local/bin/openbuilder help | grep -cF 'merge-check <owner/repo> <pr>'` prints `1`.
`local/bin/openbuilder merge-check a/b; echo $?` prints
`openbuilder: usage: openbuilder merge-check <owner/repo> <pr>` and `1`.

**Sandbox, required, because conditions 4-6 need a repository with this repository's `Makefile`.**
Build it from the clone you already have:

```sh
gh repo create <you>/ob-mc-sandbox --private
git clone <this-repo-path> /tmp/ob-mc && cd /tmp/ob-mc
git remote set-url origin "https://github.com/<you>/ob-mc-sandbox.git"
git push -q -u origin HEAD:main
```

Then, one pull request per case (open each with `gh pr create --repo <you>/ob-mc-sandbox --base main
--head <branch> --title t --body b`, and use `M=local/bin/openbuilder` from this repository):

1. **All three pass.** Branch `mc-clean` adding one comment line to `README.md`.
   `"$M" merge-check <you>/ob-mc-sandbox <pr> >/tmp/mc.out; echo "rc=$?"` — `rc=0`, and
   `grep -cF 'cond=4 result=pass' /tmp/mc.out`, `grep -cF 'cond=5 result=pass' /tmp/mc.out`,
   `grep -cF 'cond=6 result=pass' /tmp/mc.out` each print `1`.
   This item requires `shellcheck` on `PATH` and a readable deny list; if either is missing the
   command must refuse, which is items 2 and 3, not a failure of this one.
2. **Vacuous lint pass, refused.** Build a PATH without the linter and prove it is absent first:
   ```sh
   mkdir -p /tmp/ob-nolint
   for t in git gh make jq awk sed; do ln -sf "$(command -v "$t")" /tmp/ob-nolint/"$t"; done
   PATH=/tmp/ob-nolint:/bin:/usr/bin command -v shellcheck; echo "absent=$?"      # absent=1
   PATH=/tmp/ob-nolint:/bin:/usr/bin "$M" merge-check <you>/ob-mc-sandbox <pr> >/tmp/mc2.out 2>&1
   echo "rc=$?"                                                                  # rc=1
   grep -cF 'lint tool unavailable; refusing to treat a skipped check as a pass' /tmp/mc2.out   # 1
   ls -d "${XDG_CACHE_HOME:-$HOME/.cache}"/openbuilder/automerge/<pr> 2>&1 | grep -cF 'No such'  # 1
   ```
   The last line is the point of the ordering: no worktree may be created when the tooling is missing.
3. **Vacuous scrub pass, refused.**
   ```sh
   OPENBUILDER_SCRUB_DENY=/tmp/definitely-not-here "$M" merge-check <you>/ob-mc-sandbox <pr> >/tmp/mc3.out 2>&1
   grep -cF 'scrub deny list unreadable at /tmp/definitely-not-here; refusing to treat a skipped check as a pass' /tmp/mc3.out   # 1
   ```
   and with an empty deny list, `: >/tmp/empty-deny`, the message is
   `scrub deny list /tmp/empty-deny has no usable patterns; refusing to treat a skipped check as a pass`.
   Both exit 1.
4. **Conflict.** Commit a change to the first line of `README.md` on `main`, then open a pull request
   from a branch that changes the same line differently. `"$M" merge-check <you>/ob-mc-sandbox <pr>`
   prints `cond=4 result=fail detail=trial merge conflicts with main; rebase or merge by hand`,
   prints no `cond=5` or `cond=6` line, and exits 1.
5. **Lint fails on the merge result.** Branch adding `local/bin/ob-probe` containing
   `#!/usr/bin/env bash` and `x=$1; echo $x` (unquoted, SC2086, a warning). `merge-check` prints
   `cond=4 result=pass`, then `cond=5 result=fail detail=lint failed on the merge result, not on the
   branch`, and exits 1.
6. **Teardown, every path.** After each of items 1-5:
   ```sh
   ls -d "${XDG_CACHE_HOME:-$HOME/.cache}"/openbuilder/automerge/<pr> 2>&1 | grep -cF 'No such'  # 1
   git -C "$HOME/.openbuilder/repos/<you>__ob-mc-sandbox" worktree list | wc -l                   # 1
   ```
   And once under interruption: start the command, `Ctrl-C` (or `kill -INT` its pid) while the scrub's
   `--history` pass is running, then re-run both assertions — both must still hold.

Clean up: `gh repo delete <you>/ob-mc-sandbox --yes`, `rm -rf /tmp/ob-mc /tmp/ob-nolint`.

## Out of scope

- **Do not merge, push, comment, label or edit anything on GitHub.** This command is read-only against
  the remote. No `gh pr merge`, no `gh api -X`, no `git push`, not even a `--dry-run` variant of one.
- **Do not add the R12 conditions 1, 2, 3 or 7.** No `state.json` read, no protected-path list, no
  verdict parsing, no head-sha comparison, no App token, no teardown of branches. `story-04` owns all
  of it.
- Do not touch `cmd_review`, `ob_review_watch`, `cmd_land`, `cmd_approve` or `cmd_request_changes`.
- Do not add a flag: no `--keep-worktree`, `--no-lint`, `--no-scrub`, `--base`, `--verbose` or
  `--json`. Two positional arguments, nothing else.
- Do not change `Makefile`, `local/bin/ob-scrub-check` or `.gitignore`. In particular, do **not**
  commit a `.scrub-deny`, do not make it tracked, and do not copy it into the worktree — export
  `OPENBUILDER_SCRUB_DENY` and leave the file where the operator keeps it.
- Do not assert any `make` result by exit status alone, and do not write a bare-pattern `grep` against
  `make` output. `grep -F` or `grep -qF` everywhere.
- Do not cache, memoise or reuse a worktree between runs, and do not keep one on failure "for
  debugging".
- No new dependency, no new `OPENBUILDER_*` variable (`OPENBUILDER_SCRUB_DENY` already exists, owned by
  `ob-scrub-check`), and no reformatting of `local/bin/openbuilder`.
- No `README.md` change in this story — `story-04` owns the README.

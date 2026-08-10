---
id: story-02-gate-record-verify
title: Record and verify approvals by blob sha, with exit codes 0/3/4
size: M
depends_on:
  - story-01-gate-state-file
files:
  - local/bin/ob-gate
acceptance:
  - "shellcheck -x -S warning local/bin/ob-gate exits 0"
  - "in the scratch repo of ## Acceptance: ob-gate record gate-smoke prd exits 0, jq -r '.approvals.prd.blob' equals git rev-parse HEAD:.openbuilder/epics/gate-smoke/prd.md, jq -r '.stage' prints rfc, and git log -1 --format=%B | grep -c '^Approves-prd: ' prints 1"
  - "ob-gate record gate-smoke backlog gate-smoke exits 0, jq -r '.approvals.backlog[\"gate-smoke\"].files | keys | join(\",\")' prints exactly plan.md,story-01-x.md with no worklog.md entry, jq -r '.stage' still prints backlog, and jq -r '.slugs | index(\"gate-smoke\") != null' prints true"
  - "ob-gate verify gate-smoke --all exits 0; after one byte is appended to .openbuilder/epics/gate-smoke/prd.md it exits 3 and stdout contains 'prd VOID'; after git checkout -- of that file it exits 0 again"
  - "after jq 'del(.approvals.prd)' is written back, ob-gate verify gate-smoke prd exits 4 and stdout contains 'prd ABSENT'; ob-gate verify gate-smoke backlog no-such-slug exits 4"
  - "with an uncommitted story-02-y.md in .openbuilder/backlog/gate-smoke/, ob-gate record gate-smoke backlog gate-smoke exits 1 with stderr containing 'is not committed at HEAD' and git diff --quiet HEAD -- .openbuilder/epics/gate-smoke/state.json exits 0"
---

## Context

`story-01-gate-state-file` created `local/bin/ob-gate` with `init`, `stage` and `show`, plus the
shared machinery this story consumes: `die()` (message + optional exit code), `usage()`,
`read_state`, `write_state` (atomic `mktemp` + `mv` inside the epic directory), and
`commit_state <epic> <subject> [trailer]` (skips when the bytes did not change, commits exactly
`state.json` by pathspec, pushes `HEAD:refs/heads/<branch>`, and dies with exit 1 naming the local
commit if the push fails). Reuse all of them; do not add a second write path, a second commit path,
or a second temp-file scheme.

This story adds the two subcommands that make the record a gate (PRD **R3**, RFC **§3.4**).

**Why a blob sha.** `git rev-parse <ref>:<path>` and `git hash-object -- <path>` both produce the sha
git already computes for the exact bytes of a file, and the GitHub contents API returns the identical
value as the `sha` field of a file or directory entry. So the same record is checkable from the
laptop, from the instance, and from the waker with no shared secret and no clock. Verified on this
branch: `git rev-parse HEAD:.openbuilder/epics/plan-workflow/prd.md`,
`git hash-object -- .openbuilder/epics/plan-workflow/prd.md`, and
`jq -r '.approvals.prd.blob' .openbuilder/epics/plan-workflow/state.json` all print
`ba6725f35e7d275b41752e51c137207373aca71f`.

**Why `approvals.backlog` is a map keyed by slug, whose value holds a `files` map.** An epic has one
PRD and one RFC but several backlogs (PRD R10), each approved at a different moment, and the gate
must catch a single card edited after approval. RFC §2 fixes the shape; rule 4b
(`plan-workflow-02-rule`) compares that map against the plan branch's directory listing and requires
an exact set-and-sha match, with no extra and no missing `story-*.md`. Write exactly this shape:

```json
"backlog": {
  "plan-workflow-01-gate": {
    "at": "2026-08-09T19:02:11Z",
    "files": { "plan.md": "<blob>", "story-01-gate-state-file.md": "<blob>" }
  }
}
```

`worklog.md` is never a key. `backlog/SCHEMA.md:22-23` puts it on the work branch, written by the
instance; on a design branch it does not exist, and if a stray one does it must not enter the map or
block the approval.

Traps:

- `git rev-parse HEAD:<path>` prints its own argument on stdout and exits 128 when the path is not in
  `HEAD`. Use `git rev-parse --verify --quiet "HEAD:<path>"`, which exits 1 with empty output.
  (Verified.)
- `jq`'s `keys` sorts; `keys_unsorted` does not. `git ls-tree --name-only` already emits names in
  sorted order, which puts `plan.md` before every `story-*.md`, so build the map in listing order and
  the file reads naturally either way.
- `verify` must hash the **working tree**, not `HEAD`: an approved artifact edited but not committed
  is exactly the drift R3 exists to catch, and its `HEAD` blob would still match.
- `record` must refuse when the working tree and `HEAD` disagree, so a recorded sha never describes
  bytes the human did not read.
- Do not use `jq -n` here. Every write is an assignment onto the document returned by `read_state`,
  so the live file's undocumented `notes` key and its key order survive.

## Change

Edit `local/bin/ob-gate` only.

1. **`artifact_rel <epic> <prd|rfc>`** → `.openbuilder/epics/<epic>/prd.md` or `…/rfc.md`.
   **`backlog_rel <slug>`** → `.openbuilder/backlog/<slug>`.

2. **`require_committed <rel> <fix-command>`** — the shared precondition, used for a single file and
   for a directory. In this order:
   1. `git -C "$REPO_ROOT" diff --quiet HEAD -- "<rel>"`; non-zero →
      `die "<rel> has uncommitted changes; commit them first, then re-run: <fix-command>" 1`.
   2. `git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "<rel>"`; for the first entry whose
      basename is `plan.md` or matches `story-*.md` →
      `die "<that path> is not committed at HEAD; commit it first, then re-run: <fix-command>" 1`.
      An untracked `worklog.md` or any other name is ignored.

3. **`cmd_record <epic> prd|rfc`.**
   1. `read_state` (exit 1 when there is no state file).
   2. `rel="$(artifact_rel …)"`. The file not existing on disk →
      `die "no such artifact: <rel>" 1`.
   3. `blob="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "HEAD:<rel>")"`; empty →
      `die "<rel> is not committed at HEAD; commit it first, then re-run: ob-gate record <epic> <stage>" 1`.
   4. `require_committed "<rel>" "ob-gate record <epic> <stage>"`.
   5. `at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`.
   6. New document:
      `jq --arg at "$at" --arg blob "$blob" --arg next "<next-stage>" '.approvals.<stage> = {at: $at, blob: $blob} | .stage = $next'`,
      piped to `write_state`. The stage table is exactly: `prd` → `rfc`, `rfc` → `backlog`.
   7. Print `recorded <stage> approval for <epic>: <blob>` and `<epic> stage -> <next-stage>`.
   8. `commit_state <epic> "openbuilder(gate): approve <stage> for <epic>" "Approves-<stage>: <blob>"`.

4. **`cmd_record <epic> backlog <slug>`.** A missing slug →
   `die "missing <slug> for 'record backlog'" 2`. Validate the slug with the same
   `require_epic`-style regex `^[a-z0-9][a-z0-9-]{1,48}$`; on failure
   `die "invalid slug '<slug>' (expected ^[a-z0-9][a-z0-9-]{1,48}$)" 2`. Then:
   1. `read_state`.
   2. `dir="$(backlog_rel "$slug")"`. `require_committed "<dir>" "ob-gate record <epic> backlog <slug>"`.
   3. Enumerate `git -C "$REPO_ROOT" ls-tree --name-only HEAD -- "<dir>/"`, take the basename of each
      line, and keep exactly `plan.md` and every name matching `story-*.md`. Every other name —
      `worklog.md` included — is skipped without comment.
   4. No `plan.md` → `die "<dir>/plan.md is not committed at HEAD" 1`. Zero `story-*.md` →
      `die "<dir>/ has no story-*.md; a backlog with no cards cannot be approved" 1`.
   5. For each kept name in listing order, `git rev-parse --verify --quiet "HEAD:<dir>/<name>"`, and
      accumulate lines of `<name><TAB><blob>` into an array.
   6. Build the files object with one `jq` call over those lines on stdin:
      `jq -R -s 'split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): .[1]}) | add'`.
   7. New document, one `jq` call over `read_state`:
      `jq --arg slug "$slug" --arg at "$at" --argjson files "$files" '.approvals.backlog[$slug] = {at: $at, files: $files} | (if (.slugs | index($slug)) then . else .slugs += [$slug] end)'`,
      piped to `write_state`. **`stage` is not touched**: several slugs of one epic are approved
      before any is dispatched, and `openbuilder dispatch` owns the move to `dispatched`
      (RFC §3.5 step 3).
   8. `tree="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "HEAD:<dir>")"` — the git tree sha of
      the slug directory. Print `recorded backlog approval for <epic>/<slug>: <n> file(s)` and
      `commit_state <epic> "openbuilder(gate): approve backlog <slug> for <epic>" "Approves-backlog: <tree>"`.
      The tree sha is in the trailer only so the trailer keeps the documented
      `Approves-<stage>: <sha>` shape and a human reading `git log` has one resolvable object. It is
      **not** the record and nothing verifies against it — the record is the `files` map, for the
      reason RFC §2 gives.

5. **`cmd_verify <epic> [prd|rfc|backlog [<slug>]|--all]`.** Writes nothing, commits nothing, and
   prints every line to **stdout**. An omitted target means `--all`. An unknown target →
   `die "unknown verify target: '<arg>' (accepted: prd, rfc, backlog, --all)" 2`.
   A state file that is not readable → print
   `no approval recorded for <epic>: <state_rel> does not exist` and exit **4** — verify reports
   absence as 4, so it must not use `read_state`, which exits 1.

   Two flags, `void_seen` and `absent_seen`, are set as findings are printed. Every finding is
   printed, not just the first. Exit code at the end: `3` if `void_seen`, else `4` if `absent_seen`,
   else `0`. Void outranks absent because a voided approval is the condition R9 wants a human to see
   first.

   **`verify_artifact <epic> <prd|rfc>`:** recorded is `.approvals.<t>.blob`; null or empty →
   absent. Otherwise the artifact missing on disk → void, reason `missing since approval`;
   `git hash-object -- "<abs path>"` differing from the record → void, reason
   `changed since approval`; equal → intact.

   **`verify_backlog <epic> [<slug>]`:** with a slug, check that one; without, check every key of
   `approvals.backlog` in `keys_unsorted` order, and when the object is empty print
   `backlog ABSENT — no approval recorded` and set `absent_seen`. For one slug: no
   `approvals.backlog[<slug>]` key, or its `files` object empty → absent. Otherwise compare the map
   against the working-tree set (`plan.md` if it exists, plus every `story-*.md` in the directory):
   a mapped name absent on disk → void, reason `missing since approval`; a mapped name whose
   `git hash-object` differs → void, reason `changed since approval`; a name on disk that is not in
   the map → void, reason `is not covered by the approval`. All three are the conditions rule 4b
   enforces on the plan branch.

   Exact output lines (`die`-style `ob-gate: ` prefix on all of them, as `printf '%s: %s\n'
   "$OB_PROG" …`):

   ```
   ob-gate: prd intact ba6725f35e7d275b41752e51c137207373aca71f
   ob-gate: backlog/plan-workflow-01-gate intact 4 file(s)
   ob-gate: prd VOID — prd.md changed since approval
   ob-gate: backlog/plan-workflow-01-gate VOID — story-02-x.md missing since approval
   ob-gate: backlog/plan-workflow-01-gate VOID — story-03-y.md is not covered by the approval
   ob-gate: prd ABSENT — no approval recorded
   ob-gate: fix: ob-gate record plan-workflow prd
   ob-gate: fix: ob-gate record plan-workflow backlog plan-workflow-01-gate
   ```

   The `fix:` line is printed once per non-intact target, immediately after that target's findings,
   and never for an intact one. The target label is `prd`, `rfc`, or `backlog/<slug>`; the name in a
   finding is the basename, not the path.

6. **`main`.** Replace the `subcommand not implemented yet` refusal from
   `story-01-gate-state-file` with dispatch to `cmd_record` and `cmd_verify`. A `record` target that
   is none of `prd`, `rfc`, `backlog` →
   `die "unknown record target: '<arg>' (accepted: prd, rfc, backlog)" 2`. `usage()` already lists
   both subcommands and both exit codes; change nothing in it.

## Acceptance

Run in a throwaway repository with a local bare `origin`, as in `story-01-gate-state-file`, so `push`
is exercised offline and nothing lands in this repo's history.

```sh
shellcheck -x -S warning local/bin/ob-gate   # must exit 0
OB=$PWD/local/bin/ob-gate
T=$(mktemp -d)
git init -q -b main --bare "$T/origin.git"
git init -q -b main "$T/work" && cd "$T/work"
git remote add origin "$T/origin.git"
mkdir -p .openbuilder/epics/gate-smoke .openbuilder/backlog/gate-smoke
printf 'prd body\n'  > .openbuilder/epics/gate-smoke/prd.md
printf 'rfc body\n'  > .openbuilder/epics/gate-smoke/rfc.md
printf '# t\n\n- epic: gate-smoke\n' > .openbuilder/backlog/gate-smoke/plan.md
printf 'card\n'      > .openbuilder/backlog/gate-smoke/story-01-x.md
printf 'round 1\n'   > .openbuilder/backlog/gate-smoke/worklog.md
git add -A && git commit -q -m artifacts
git push -q origin HEAD:refs/heads/main
"$OB" init gate-smoke --repo artemkurylo/openbuilder
S=.openbuilder/epics/gate-smoke/state.json
```

Then, in `$T/work`:

- `"$OB" record gate-smoke prd` exits 0; `jq -r '.approvals.prd.blob' "$S"` equals
  `git rev-parse HEAD:.openbuilder/epics/gate-smoke/prd.md`; `jq -r '.stage' "$S"` prints `rfc`;
  `git log -1 --format=%B | grep -c '^Approves-prd: '` prints `1`; `git log -1 --format=%s` prints
  `openbuilder(gate): approve prd for gate-smoke`.
- `"$OB" record gate-smoke rfc` exits 0 and `jq -r '.stage' "$S"` prints `backlog`.
- `"$OB" record gate-smoke backlog gate-smoke` exits 0;
  `jq -r '.approvals.backlog["gate-smoke"].files | keys | join(",")' "$S"` prints exactly
  `plan.md,story-01-x.md`; `jq -r '.approvals.backlog["gate-smoke"].files | has("worklog.md")' "$S"`
  prints `false`; `jq -r '.stage' "$S"` still prints `backlog`;
  `jq -r '.slugs | index("gate-smoke") != null' "$S"` prints `true`;
  `git log -1 --format=%B | grep -c '^Approves-backlog: '` prints `1`.
- `"$OB" verify gate-smoke --all` exits 0 and prints three `intact` lines and no `fix:` line;
  `"$OB" verify gate-smoke` (no target) also exits 0.
- Void, uncommitted edit: `printf 'x' >> .openbuilder/epics/gate-smoke/prd.md`, then
  `"$OB" verify gate-smoke prd` exits **3** and stdout contains `prd VOID` and
  `fix: ob-gate record gate-smoke prd`. `git checkout -- .openbuilder/epics/gate-smoke/prd.md`, then
  the same command exits 0.
- Void, edited card: `printf 'x' >> .openbuilder/backlog/gate-smoke/story-01-x.md`, then
  `"$OB" verify gate-smoke backlog gate-smoke` exits 3 and stdout contains
  `story-01-x.md changed since approval`. Restore with `git checkout --`.
- Void, extra card: `printf 'new\n' > .openbuilder/backlog/gate-smoke/story-02-y.md`, then
  `"$OB" verify gate-smoke backlog gate-smoke` exits 3 and stdout contains
  `story-02-y.md is not covered by the approval`.
- Refusal, uncommitted card (same file still present): `"$OB" record gate-smoke backlog gate-smoke`
  exits **1**, stderr contains `story-02-y.md is not committed at HEAD`, and
  `git diff --quiet HEAD -- "$S"` exits 0 — no state was written. Then
  `rm .openbuilder/backlog/gate-smoke/story-02-y.md`.
- Refusal, modified artifact: `printf 'x' >> .openbuilder/epics/gate-smoke/rfc.md`, then
  `"$OB" record gate-smoke rfc` exits 1 and stderr contains `has uncommitted changes`. Restore with
  `git checkout --`.
- Refusal, no cards: `mkdir -p .openbuilder/backlog/empty-slug && printf '# t\n' >
  .openbuilder/backlog/empty-slug/plan.md && git add -A && git commit -q -m empty`, then
  `"$OB" record gate-smoke backlog empty-slug` exits 1 and stderr contains
  `has no story-*.md; a backlog with no cards cannot be approved`.
- Absent: `jq 'del(.approvals.prd)' "$S" > /tmp/s && mv /tmp/s "$S"`, then
  `"$OB" verify gate-smoke prd` exits **4** and stdout contains `prd ABSENT`.
  `"$OB" verify gate-smoke backlog no-such-slug` exits 4.
  `"$OB" verify no-such-epic --all` exits 4 and stdout contains `does not exist`.
- `"$OB" verify gate-smoke bogus` exits 2.
- Usage: `"$OB" record gate-smoke backlog` exits 2; `"$OB" record gate-smoke plan` exits 2.
- No temp file survives any of the above:
  `find .openbuilder/epics/gate-smoke -name '.ob-gate.tmp.*'` prints nothing.
- Against the live epic in the work tree, read-only: `local/bin/ob-gate verify plan-workflow --all`
  exits **4** (the PRD and the RFC are intact, `approvals.backlog` is empty) and its stdout contains
  `prd intact ba6725f35e7d275b41752e51c137207373aca71f`,
  `rfc intact f6af7260918e938ede38864cdd28a4679709fb9d` and `backlog ABSENT`; afterwards
  `git status --porcelain .openbuilder/epics/plan-workflow` prints nothing.
- Remove the scratch tree: `rm -rf "$T"`.

## Out of scope

- Do **not** run `ob-gate record` against the live `plan-workflow` epic. The only live-epic command
  in this story is `verify`, which writes nothing. Recording the real approval is the human's action
  on the design branch, not the implementer's.
- No changes to `.openbuilder/epics/plan-workflow/state.json`, `prd.md`, `rfc.md` or `intake.md`.
- No rule 4b, no `runner/bin/ob-poll`, no `waker/**`. The plan-branch side of this comparison is
  `plan-workflow-02-rule`.
- No changes to `local/bin/openbuilder`: nothing calls `ob-gate` yet, and wiring `cmd_dispatch` to it
  is `plan-workflow-05-cli`.
- No GitHub API call and no `gh`. `verify` is local-only; blob shas from the contents API are rule
  4b's problem.
- No new state fields. `epic`, `repo`, `stage`, `opened`, `slugs`, `approvals` is the documented set,
  plus whatever unknown keys the file already carries — preserve them, do not add to them, do not
  remove them.
- No `--force`, no `--re-approve`, no `--json`, no interactive confirmation prompt. Re-approving is
  running `record` again.
- No tree-sha comparison in `verify`, no digest of the files map, no signature, no timestamp
  comparison. The `files` map of blob shas is the record.
- No refactor of `init`, `stage`, `show`, `usage()` or the `commit_state`/`write_state` helpers from
  `story-01-gate-state-file` beyond replacing the `not implemented yet` dispatch arm.
- Do not commit any `gate-smoke`, `empty-slug` or `no-such-epic` directory to this repo: the exercise
  runs in `$(mktemp -d)` and is deleted. `git status --porcelain` at the end shows only
  `local/bin/ob-gate`.

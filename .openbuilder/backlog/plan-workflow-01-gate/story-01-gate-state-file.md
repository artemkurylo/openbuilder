---
id: story-01-gate-state-file
title: Create ob-gate with init, stage and show over an atomic state.json
size: M
depends_on: []
files:
  - local/bin/ob-gate
acceptance:
  - "shellcheck -x -S warning local/bin/ob-gate exits 0 and test -x local/bin/ob-gate exits 0"
  - "local/bin/ob-gate --help exits 0 and prints a first line starting 'usage: ob-gate init'; bare local/bin/ob-gate exits 2; local/bin/ob-gate bogus e exits 2"
  - "ob-gate init gate-smoke --repo artemkurylo/openbuilder creates .openbuilder/epics/gate-smoke/state.json where jq -r '.epic,.repo,.stage,(.slugs|length)' prints gate-smoke, artemkurylo/openbuilder, intake, 0; a second init exits 2"
  - "after a hand-added .notes key, ob-gate stage gate-smoke rfc leaves jq -r '.notes' printing 'keep me' and jq -r '.stage' printing rfc; ob-gate stage gate-smoke nope exits 2"
  - "git log -1 --format=%s prints 'openbuilder(gate): stage gate-smoke -> rfc', git log -1 --format=%B | grep -c '^Approves-' prints 0, and re-running the same stage command exits 0 while git rev-list --count HEAD is unchanged"
  - "find .openbuilder/epics/gate-smoke -name '.ob-gate.tmp.*' prints nothing, and local/bin/ob-gate show plan-workflow exits 0 with output matching ^stage  *backlog$"
---

## Context

There is no laptop-side owner of `.openbuilder/epics/<epic>/state.json` today. The live file at
`.openbuilder/epics/plan-workflow/state.json` was written by hand, and this story creates the script
that owns it from now on (RFC §3.4).

Read that live file first — it is the shape you must be able to rewrite without disturbing:

```json
{
  "epic": "plan-workflow",
  "repo": "artemkurylo/openbuilder",
  "stage": "backlog",
  "opened": "2026-08-09",
  "slugs": ["plan-workflow-00-host", "..."],
  "approvals": { "prd": { "at": "...", "blob": "..." }, "rfc": { ... }, "backlog": {} },
  "notes": "Recorded by hand: ..."
}
```

`notes` is **not** in the documented field set and must survive every rewrite. That is the reason
every write in this script is a `jq` assignment onto the parsed document rather than a fresh object
built from a template. Verified on this repo with jq 1.7.1:
`jq . .openbuilder/epics/plan-workflow/state.json | cmp - .openbuilder/epics/plan-workflow/state.json`
is byte-identical, so `jq`'s default two-space output already matches the file on disk.

The pattern to copy is the two existing single-purpose laptop scripts. Read both before writing:

- `local/bin/ob-learn:30-46` — `set -euo pipefail`, `IFS=$'\n\t'`, then `OB_PROG` and
  `REPO_ROOT="$(git rev-parse --show-toplevel)"` as plain constants.
- `local/bin/ob-learn:47-62` — `usage()` as a `cat <<EOF` heredoc, listing every option.
- `local/bin/ob-learn:64-73` — `cleanup()` plus `trap cleanup EXIT`, removing a temp path only when
  the variable holding it is non-empty.
- `local/bin/ob-learn:75-79` — `die() { local msg="$1" code="${2:-1}"; ... exit "$code"; }`, printing
  `"$OB_PROG: $msg"` to stderr. Every refusal in this story goes through it.
- `local/bin/ob-learn:81-114` — argument parsing that exits **2** for a usage error (missing value,
  unknown argument, unknown enum value) and names the accepted values in the message.
- `local/bin/ob-learn:274-279` — the atomic write: `mktemp` a sibling of the target file, write it,
  `mv` it into place.
- `local/bin/ob-learn:290-311` — a `main()` that calls the steps in order, then `main "$@"` as the
  last line of the file.
- `local/bin/ob-scrub-check:29-41` — a positional-argument `case` that exits 2 on an unknown
  argument, and `-h | --help` exiting 0.
- `local/bin/ob-learn:306-307` — success messages go to **stdout**; refusals go to stderr via
  `die`.

The slug/epic name regex is frozen: `^[a-z0-9][a-z0-9-]{1,48}$` — see `local/bin/openbuilder:249-252`
(`ob_validate_slug`) and `runner/bin/ob-common.sh:140-144` (`ob_require_slug`). The repo argument
regex is `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` — `local/bin/openbuilder:244-247`. Copy both regexes
verbatim; do not invent a third.

The UTC timestamp format is `date -u +%Y-%m-%dT%H:%M:%SZ`, the same call `ob_log` makes at
`runner/bin/ob-common.sh:46`, and the same format already in the live `state.json` (`"at":
"2026-08-09T18:11:22Z"`).

Traps:

- **Do not source `runner/bin/ob-common.sh`.** It is instance-side and sourced-only; neither
  `ob-learn` nor `ob-scrub-check` sources it. `ob-gate` defines its own `die()` and `OB_PROG`.
- **`jq` is not `jaq`.** An interactive shell on this laptop may resolve `jq` to `jaq`. The script
  calls `jq` by name and is run non-interactively, where `jq` is real jq (1.7.1 here). Do not add an
  alias, a `jaq` fallback, or an explicit `--indent` flag — the default two-space output is what
  keeps `state.json` byte-stable.
- `mktemp` must create the temp file **inside the epic directory**, not in `/tmp`: across
  filesystems `mv` degrades to copy-then-unlink and stops being atomic.
- `git rev-parse HEAD:<path>` prints its argument on stdout when it fails. Always use
  `git rev-parse --verify --quiet "HEAD:<path>"`, which exits 1 with empty output instead.
  (Verified: exit 1, empty stdout, on a path that exists on disk but not in `HEAD`.)
- `make lint` globs `local/bin/*`, so the new file is linted automatically. Do not edit the
  `Makefile`.

## Change

Create `local/bin/ob-gate`, mode `0755`, and nothing else.

1. **Header.** `#!/usr/bin/env bash`, then a comment block saying why the file exists: `state.json`
   records which artifact content a human approved, an approval authored by a model is worthless
   because the whole value of the record is that it is mechanical, so exactly one deterministic
   script computes the blob shas and writes the file. Then `set -euo pipefail` and `IFS=$'\n\t'`.

2. **Constants.** `OB_PROG="ob-gate"`, `REPO_ROOT="$(git rev-parse --show-toplevel)"`, and
   `TMP_STATE=""`. Declare an array of the six valid stages in order:
   `intake prd rfc backlog dispatched landed`.

3. **`usage()`** — a `cat <<EOF` heredoc printing exactly this text:

```
usage: ob-gate init   <epic> --repo <owner/repo>
       ob-gate stage  <epic> <stage>
       ob-gate record <epic> prd|rfc
       ob-gate record <epic> backlog <slug>
       ob-gate verify <epic> [prd|rfc|backlog [<slug>]|--all]
       ob-gate show   <epic>
       ob-gate --help

subcommands:
  init    write .openbuilder/epics/<epic>/state.json at stage intake
  stage   move the stage pointer; <stage> is one of
          intake, prd, rfc, backlog, dispatched, landed
  record  record human approval of an artifact: compute its git blob sha,
          write state.json, advance the stage, commit with an
          Approves-<stage>: <sha> trailer, and push
  verify  re-check recorded approvals against the bytes on disk;
          the default target is --all
  show    print the recorded state, human-readable

exit codes:
  0  success; for verify, every checked approval is intact
  1  operational refusal (artifact not committed, push failed, no state file)
  2  usage error (unknown subcommand, bad argument, missing value)
  3  verify: an approval is void — the artifact changed since it was recorded
  4  verify: an approval is absent — nothing was recorded for that target
EOF
```

4. **`cleanup()` + `trap cleanup EXIT`** — `rm -f "$TMP_STATE"` when `TMP_STATE` is non-empty,
   `return 0` at the end, exactly as `ob-learn:64-73`.

5. **`die() { local msg="$1" code="${2:-1}"; ... }`** — `printf '%s: %s\n' "$OB_PROG" "$msg" >&2`,
   then `exit "$code"`. Every message quoted in this card is the `<msg>` argument; `die` adds the
   `ob-gate: ` prefix.

6. **`need_jq()`** — `command -v jq >/dev/null 2>&1 ||
   die "jq is required and was not found on PATH" 1`. Called once from `main`.

7. **Validators.** `require_epic <name>` applies `^[a-z0-9][a-z0-9-]{1,48}$` and on failure dies with
   `invalid epic name '<name>' (expected ^[a-z0-9][a-z0-9-]{1,48}$)` and code 2. `require_repo_arg
   <owner/repo>` applies `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` and dies with
   `not a valid <owner>/<repo>: <arg>` and code 2.

8. **Path helpers**, each one line, `local`, `printf` with no trailing newline where composed:
   `epic_rel <epic>` → `.openbuilder/epics/<epic>`; `state_rel <epic>` → `<epic_rel>/state.json`;
   `state_path <epic>` → `${REPO_ROOT}/<state_rel>`. Repo-relative strings are what `git` commands
   take; absolute paths are what `jq` and `mktemp` take. Every git invocation in this script uses
   `git -C "$REPO_ROOT" …`.

9. **`read_state <epic>`** — die with
   `no epic state at <state_rel>; run: ob-gate init <epic> --repo <owner/repo>` and code 1 when the
   file is not readable; otherwise print the file to stdout.

10. **`write_state <epic>`** — reads the new JSON document from **stdin**. `TMP_STATE="$(mktemp
    "$(dirname "$(state_path "$epic")")/.ob-gate.tmp.XXXXXX")"`, write stdin into it, `mv` it over
    `state.json`, then set `TMP_STATE=""`. `jq` already emits a trailing newline; do not add a
    second one and do not `chmod` the result.

11. **`commit_state <epic> <subject> [trailer]`** — the single commit/push path, in this order:
    1. `git -C "$REPO_ROOT" diff --quiet HEAD -- "$(state_rel "$epic")"` **and** the file being
       already tracked → nothing changed: print
       `state.json already up to date; nothing committed` to stdout and return 0. Do not commit, do
       not push. (An untracked `state.json`, i.e. the `init` case, always commits.)
    2. Commit exactly that one path, leaving any other staged or unstaged change in the tree
       untouched: `git -C "$REPO_ROOT" commit --quiet -m "<subject>" -- "<state_rel>"`, adding a
       second `-m "<trailer>"` before the pathspec when a trailer was given, so the trailer is its
       own paragraph and `git interpret-trailers --parse` finds it. (Verified: a pathspec commit
       leaves an unrelated dirty file dirty, and `git log -1 --format=%B` contains the trailer on
       its own line.)
    3. Resolve the branch once: `branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"`, then
       `git -C "$REPO_ROOT" push --quiet origin "HEAD:refs/heads/${branch}"` — an explicit refspec
       so the push never depends on `push.default` or on an upstream being configured. On success
       print `pushed <branch> to origin`.
    4. On push failure: print, do not roll back, and exit non-zero —
       `die "push to origin failed; state.json is committed locally as <short-sha> — re-run: git push origin HEAD:refs/heads/<branch>" 1`,
       where `<short-sha>` is `git -C "$REPO_ROOT" rev-parse --short HEAD`.

12. **`cmd_init <epic> --repo <owner/repo>`.** Accept the flag in either order after the epic name;
    a missing `--repo` value dies with `missing value for --repo` code 2; a missing `--repo`
    altogether dies with `missing required --repo <owner/repo>` code 2; any other argument dies with
    `unknown argument: '<arg>' (accepted: --repo)` code 2. An existing `state.json` dies with
    `state.json already exists at <state_rel>; use 'ob-gate stage' or 'ob-gate record'` code 2.
    Otherwise `mkdir -p` the epic directory and write this document, in this key order, via
    `jq -n` (the only `jq -n` in the script) and `write_state`:

    ```json
    {
      "epic": "<epic>",
      "repo": "<owner/repo>",
      "stage": "intake",
      "opened": "<date -u +%Y-%m-%d>",
      "slugs": [],
      "approvals": { "prd": {}, "rfc": {}, "backlog": {} }
    }
    ```

    Then print `opened epic <epic> at stage intake (<state_rel>)` and
    `commit_state <epic> "openbuilder(gate): open epic <epic>"`.

13. **`cmd_stage <epic> <stage>`.** A stage not in the six dies with
    `unknown stage: '<stage>' (accepted: intake, prd, rfc, backlog, dispatched, landed)` code 2.
    Otherwise `read_state | jq --arg s "<stage>" '.stage = $s' | write_state`, print
    `<epic> stage -> <stage>`, and `commit_state <epic> "openbuilder(gate): stage <epic> -> <stage>"`
    with **no** trailer. `stage` never touches `approvals`.

14. **`cmd_show <epic>`.** Print to stdout, one field per line, with `printf '%-8s %s\n' <label>
    <value>` — the label padded to 8 columns, then one space, then the value:

    ```
    epic     plan-workflow
    repo     artemkurylo/openbuilder
    stage    backlog
    opened   2026-08-09
    slugs    plan-workflow-00-host, plan-workflow-01-gate
    prd      approved 2026-08-09T18:11:22Z ba6725f35e7d275b41752e51c137207373aca71f
    rfc      approved 2026-08-09T18:11:22Z f6af7260918e938ede38864cdd28a4679709fb9d
    backlog  none recorded
    ```

    `slugs` with an empty list prints `none`. A `prd` or `rfc` whose `.blob` is null or empty prints
    `not approved`. `backlog` prints one line per recorded slug, `backlog  <slug> approved <at> <n>
    file(s)`, and the literal `none recorded` when `approvals.backlog` is empty. `show` reads only —
    it never writes, commits, verifies or exits non-zero except through `read_state`.

15. **`main "$@"`.** No arguments → `usage` to stderr, exit 2. `-h` or `--help` as the first
    argument → `usage` to stdout, exit 0. Otherwise shift the subcommand and dispatch to
    `cmd_init`, `cmd_stage`, `cmd_show`; anything else dies with
    `unknown subcommand: '<arg>' (accepted: init, stage, record, verify, show)` code 2. `record` and
    `verify` are added by `story-02-gate-record-verify` — until then they must still be listed in
    `usage()` and in that message, and reaching them dies with
    `subcommand not implemented yet: <arg>` code 2. Every subcommand takes `<epic>` as its first
    positional argument; a missing one dies with `missing <epic>` code 2. `main` calls `need_jq`
    before dispatching.

## Acceptance

Run the exercise in a throwaway git repository with a local bare `origin`, so `push` is exercised
for real, offline, and nothing lands in this repo's history. `OB=$PWD/local/bin/ob-gate` from the
work tree, then:

```sh
chmod 755 local/bin/ob-gate
shellcheck -x -S warning local/bin/ob-gate   # must exit 0
test -x local/bin/ob-gate                    # must exit 0
OB=$PWD/local/bin/ob-gate
T=$(mktemp -d)
git init -q -b main --bare "$T/origin.git"
git init -q -b main "$T/work" && cd "$T/work"
git remote add origin "$T/origin.git"
git commit -q --allow-empty -m base
git push -q origin HEAD:refs/heads/main
```

Then, in `$T/work`:

- `"$OB" --help` exits 0 and its first line is `usage: ob-gate init   <epic> --repo <owner/repo>`.
  `"$OB"` with no arguments exits 2. `"$OB" bogus gate-smoke` exits 2 and stderr contains
  `unknown subcommand: 'bogus'`.
- `"$OB" init gate-smoke --repo artemkurylo/openbuilder` exits 0 and creates
  `.openbuilder/epics/gate-smoke/state.json`;
  `jq -r '.epic, .repo, .stage, (.slugs | length)' .openbuilder/epics/gate-smoke/state.json` prints
  `gate-smoke`, `artemkurylo/openbuilder`, `intake`, `0` on four lines. Running the same command
  again exits 2 and stderr contains `already exists`.
- `"$OB" init bad_epic --repo artemkurylo/openbuilder` exits 2; `"$OB" init ok-epic --repo notarepo`
  exits 2; `"$OB" init ok-epic` exits 2.
- Unknown-key survival: `jq '.notes = "keep me"' .openbuilder/epics/gate-smoke/state.json > /tmp/s
  && mv /tmp/s .openbuilder/epics/gate-smoke/state.json`, then `"$OB" stage gate-smoke rfc` exits 0
  and `jq -r '.notes, .stage' .openbuilder/epics/gate-smoke/state.json` prints `keep me` then `rfc`.
- `"$OB" stage gate-smoke nope` exits 2 and stderr contains `unknown stage: 'nope'`.
- `git log -1 --format=%s` prints `openbuilder(gate): stage gate-smoke -> rfc`, and
  `git log -1 --format=%B | grep -c '^Approves-'` prints `0`.
- Idempotence: `n=$(git rev-list --count HEAD)`; `"$OB" stage gate-smoke rfc` exits 0, prints
  `ob-gate: state.json already up to date; nothing committed`, and `git rev-list --count HEAD` still
  prints `$n`.
- Push reached `origin`: `git -C "$T/origin.git" log -1 --format=%s main` prints
  `openbuilder(gate): stage gate-smoke -> rfc`.
- `find .openbuilder/epics/gate-smoke -name '.ob-gate.tmp.*'` prints nothing.
- Back in the work tree (not `$T/work`), against the live epic:
  `local/bin/ob-gate show plan-workflow` exits 0, its output matches `grep -qE '^stage  *backlog$'`
  and `grep -qE '^prd  *approved 2026-08-09T18:11:22Z ba6725f35e7d275b41752e51c137207373aca71f$'`,
  and `git status --porcelain .openbuilder/epics/plan-workflow` prints nothing — `show` wrote
  nothing.
- Remove the scratch tree: `rm -rf "$T"`.

## Out of scope

- No `record` and no `verify` — those are `story-02-gate-record-verify`. Leave them listed in
  `usage()` and refused with exit 2.
- No `Makefile`, `README.md`, `docs/architecture.md`, `docs/runbook.md` or `docs/workflow.md` edits.
- No changes to `local/bin/openbuilder`, `local/bin/ob-learn`, `local/bin/ob-scrub-check` or
  `runner/bin/ob-common.sh`. Do not move any of `ob-gate`'s helpers into `ob-common.sh`: that file is
  instance-side and sourced-only.
- No `.gitignore` entry for the temp file: the `EXIT` trap removes it, and a name that needs
  ignoring is a bug.
- No branch-name enforcement. `ob-gate` must work from any branch and any clone; it does not check
  for `openbuilder/design/<epic>`.
- No owner allowlist, no `GH_HOST`, no `gh` call. `git push` is the only network operation.
- No file locking, no `flock`, no concurrency handling: one human runs this one command at a time.
- No `--dry-run`, no `--json` output, no colour, no shell completion.
- Do not commit a `.openbuilder/epics/gate-smoke/` directory to this repo. The exercise happens in
  `$(mktemp -d)` and is deleted; `git status --porcelain` at the end of the story shows only
  `local/bin/ob-gate`.

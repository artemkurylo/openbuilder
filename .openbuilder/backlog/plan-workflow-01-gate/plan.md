# feat(gate): record and verify epic approvals with local/bin/ob-gate

- epic: plan-workflow

## Goal

A human approval of a PRD, an RFC or a backlog becomes a mechanical, verifiable record on the
design branch. One new laptop script, `local/bin/ob-gate`, is the only writer of
`.openbuilder/epics/<epic>/state.json`. It computes git blob shas, rewrites the state atomically,
advances the stage pointer, commits with an `Approves-<stage>: <sha>` trailer and pushes. `verify`
re-checks a recorded approval against the bytes on disk and exits `0` intact, `3` void, `4` absent,
so every later caller — the session's resumption check, `openbuilder dispatch`, the poller's rule
4b — branches on a number instead of a judgement.

Implements PRD **R1** (resumable from a recorded stage) and **R3** (an approval that cannot be
forged and cannot survive an edit to the thing it approved), per RFC **§2** (artifact layout and
`state.json`) and **§3.4** (`ob-gate`, the only writer).

## Why now

Every other slug in this epic reads what this one writes. Rule 4b (`plan-workflow-02-rule`) starts
declining any plan branch whose `state.json` does not carry a matching `approvals.backlog[<slug>]`
entry, and nothing can write that entry today: the live
`.openbuilder/epics/plan-workflow/state.json` was recorded **by hand**, which is exactly the thing
RFC §1 says an approval must never be. RFC §9 therefore orders 01 before 02.

## Approach

`ob-gate` is a sibling of the two existing laptop-side single-purpose scripts, `local/bin/ob-learn`
and `local/bin/ob-scrub-check`: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, an
`OB_PROG` constant, `REPO_ROOT` from `git rev-parse --show-toplevel`, a local `die()` that takes an
optional exit code, a `usage()` heredoc, one clear function per job, `local` on every variable, two-
space indent. It does **not** source `runner/bin/ob-common.sh`: that file is instance-side and
sourced-only, and neither existing laptop script sources it.

Decisions made here so the implementer has nothing left to choose:

- **`jq` does the JSON, and every write is an assignment onto the parsed document** — never a
  rebuild from a template. The live `state.json` carries a `notes` key that is not in the documented
  field set, and `jq`'s object assignment preserves both unknown keys and key order. Verified:
  `jq . .openbuilder/epics/plan-workflow/state.json | cmp - .openbuilder/epics/plan-workflow/state.json`
  is byte-identical with jq 1.7.1, so a no-op rewrite produces a no-op diff.
- **Atomic write**: `mktemp` inside the epic directory, then `mv` over `state.json`, with an `EXIT`
  trap removing the temp file — the shape `ob-learn:274-279` already uses for `LEARNINGS.md`. An
  interrupted run can never leave a truncated state file.
- **Stage advance table**: `record prd` → `stage: rfc`; `record rfc` → `stage: backlog`;
  `record backlog <slug>` leaves `stage` untouched, because several slugs of one epic are approved
  before any of them is dispatched (R10) and `openbuilder dispatch` is what sets `dispatched`
  (RFC §3.5 step 3).
- **Comparison direction**: `record` reads the committed blob (`git rev-parse --verify --quiet
  HEAD:<path>`) and refuses when the artifact is uncommitted or modified, so the recorded sha always
  describes the bytes the human just read. `verify` hashes the **working tree**
  (`git hash-object -- <path>`), which catches an edit that was never committed. Both produce the
  same 40-hex sha for the same bytes, so the two views agree whenever the working tree matches
  `HEAD`, and they agree with the plan-branch listing rule 4b compares against (RFC §12: the
  contents API returns the identical value as `sha`).
- **Every state-mutating subcommand commits and pushes.** Only `record` adds the trailer. Nothing
  is committed when the bytes did not change, so re-running a subcommand is idempotent rather than
  a stream of empty-diff commits.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-gate-state-file | Create ob-gate with init, stage and show over an atomic state.json | M | [] |
| story-02-gate-record-verify | Record and verify approvals by blob sha, with exit codes 0/3/4 | M | [story-01-gate-state-file] |
| story-03-schema-epic-line | Document the `- epic:` line in backlog/SCHEMA.md | S | [] |

## Out of scope

- **No changes to `local/bin/openbuilder`.** `cmd_plan`, `cmd_dispatch`, `cmd_review` and `cmd_land`
  belong to `plan-workflow-05-cli`; the `ob_gh()` host wrapper and the owner allowlist belong to
  `plan-workflow-00-host`. `ob-gate` is invoked as a standalone script, and no command is wired to
  call it in this slug.
- **No rule-table work.** Rule 4b in `runner/bin/ob-poll` and `waker/github.py` is
  `plan-workflow-02-rule`.
- **No prompt or runner changes.** `runner/prompts/*`, `runner/bin/ob-implement` and
  `runner/bin/ob-respond` are `plan-workflow-03-context`.
- **No agents, skills or slash commands.** `agent/local/**` and `docs/workflow.md` are
  `plan-workflow-04-agents`.
- **No epic-directory content is authored by this slug.** `ob-gate` never writes `intake.md`,
  `prd.md` or `rfc.md`, and never edits the live `.openbuilder/epics/plan-workflow/` files.
- No `Makefile` change: `make lint` already globs `local/bin/*`, so `ob-gate` is linted the moment
  it exists.
- No owner allowlist, host pinning, or `GH_HOST` handling inside `ob-gate`: it makes no network call
  except `git push`.
- No new dependency. `jq` and `git` only — no Python, no YAML parser, no `gh`.

## Risks

- **`jq` is not `jaq`.** An interactive shell on this laptop may resolve `jq` to `jaq`, whose output
  formatting and flag set differ. The script must call `jq` by name and is always run
  non-interactively, where `jq` resolves to real jq (1.7.1 on this laptop). Reviewer should check
  that no alias, `command -v jaq` fallback or `--indent` flag was added: the default two-space
  output is what keeps the file byte-stable.
- **A rebuilt `state.json` silently drops a key.** The live file has a `notes` key outside the
  documented set. Reviewer should check every write is `jq '<assignment>' state.json`, never
  `jq -n '{...}'` outside `init`, and that story-01's `notes`-survival criterion was actually run.
- **A partial write.** Reviewer should check the temp file is created by `mktemp` in the epic
  directory (not `/tmp`, which may be a different filesystem, making `mv` a copy) and that the
  `EXIT` trap removes it.
- **An approval recorded for bytes nobody read.** Reviewer should check `record` refuses on an
  uncommitted or modified artifact, exit 1, rather than recording the HEAD blob of a file whose
  working-tree copy differs.

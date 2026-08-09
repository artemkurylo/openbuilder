---
id: story-01-plan-launcher
title: Turn `openbuilder plan` into a stage-aware design-branch launcher
size: M
depends_on: []
files:
  - local/bin/openbuilder
  - README.md
acceptance:
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
  - "`openbuilder plan` with 0, 1 or 3 arguments exits 1 and prints exactly `openbuilder: usage: openbuilder plan <owner/repo> <epic>`"
  - "`openbuilder plan artemkurylo/openbuilder Not_An_Epic` exits 1 and its stderr contains `invalid slug 'Not_An_Epic'`"
  - "`grep -c ob_write_plan_scaffold local/bin/openbuilder` prints 0"
  - "in a sandbox repo with no `openbuilder/design/<epic>` ref, `OB_FAKE_OMP` on PATH: the command creates the branch, pushes it, creates `<clone>/.omp/commands/`, and the recorded omp argv contains `--model amazon-bedrock/us.anthropic.claude-opus-5`"
---

## Context

`cmd_plan` (`local/bin/openbuilder:564-631`) is slug-shaped. It cuts `openbuilder/plan/<slug>`
directly (lines 577-583), writes a backlog scaffold with `ob_write_plan_scaffold`
(lines 587-592, function at 633-660), and seeds an Opus 5 session whose whole job is writing story
cards. That is the hole PRD §2 names: the design phase starts on the branch the poller triggers on,
so the spend switch is thrown before anything is approved.

RFC §3.1 and §3.2 replace it. `openbuilder plan <owner/repo> <epic>` prepares the clone, holds
`openbuilder/design/<epic>`, verifies every approval already recorded for the epic, and launches one
session seeded with prose. `openbuilder/design/*` is invisible to the poller — `ob-poll:49` and
`waker/github.py:87` both match `refs/heads/openbuilder/plan/` only — so pushing the design branch
immediately is free.

What you are copying:

- `ob_plan_branch` and `ob_work_branch` (`openbuilder:524-525`) are one-line `printf` helpers. The new
  `ob_design_branch` is the third of the set and goes beside them.
- `ob_install_local_assets` (`openbuilder:503-522`) already mirrors `agent/local/agents` into
  `<clone>/.omp/agents/` (lines 508-512) with a `[[ -d … ]]` guard and an `ob_warn` on the else
  branch, and copies the guardrails hook under a `[[ -f … ]]` guard (513-515). The commands mirror is
  the same shape a third time.
- `ob_ensure_clone` (`openbuilder:483-496`) fetches or clones and prints the directory. It is also
  where `plan-workflow-00-host` puts the `origin`-must-be-github.com assertion, so `cmd_plan` inherits
  that by calling it. Do not add a host check of your own.
- The launch is `GH_REPO="$repo" exec omp --cwd "$dir" --model "$OB_OPUS_MODEL" --append-system-prompt
  … "$seed"` (lines 626-630). Keep that shape, including the `exec`.
- `OB_BIN_DIR` is `<root>/local/bin` and `OB_ROOT` is the control-repo root (`openbuilder:43-44`).

Traps:

- `git checkout -B "$branch" --track "origin/$branch"` **resets the branch to origin's tip**. Running
  it while already on the design branch would discard local commits and the session's uncommitted
  work. The resumption path must not do that.
- `<epic>` is validated with the existing `ob_validate_slug` (`openbuilder:249-252`), not a new
  function: RFC §2 says an epic name is a slug under the same regex.
- `agent/local/commands/` does not exist in this repo yet — `plan-workflow-04-agents` creates it. A
  missing directory is a warning, never fatal.
- `local/bin/ob-gate` does not exist yet either; `plan-workflow-01-gate` creates it. Its absence is a
  refusal with the exact message below, not a silent skip.

## Change

All edits are in `local/bin/openbuilder` unless a heading says otherwise.

### 1. `ob_design_branch`

Add immediately after `ob_work_branch` (line 525), same one-line `printf` shape:
`ob_design_branch <epic>` prints `<OB_BRANCH_PREFIX>/design/<epic>`.

### 2. `ob_gate`

Add directly below `ob_design_branch`. `ob_gate <clone-dir> <args...>` shifts the first argument off
and runs `"$OB_BIN_DIR/ob-gate"` with the rest inside a subshell whose working directory is
`<clone-dir>`, so `ob-gate`'s own `git rev-parse --show-toplevel` resolves to the clone. It returns
`ob-gate`'s exit status unchanged and does no logging.

Add a second one-line helper `ob_need_gate` that dies when `$OB_BIN_DIR/ob-gate` is not executable,
with exactly:

```
ob_die "local/bin/ob-gate is missing or not executable at $OB_BIN_DIR/ob-gate — the epic gate cannot run without it"
```

### 3. `ob_install_local_assets` — mirror the commands directory

Add `"$dir/.omp/commands"` to the existing `mkdir -p` at line 507. Then, after the guardrails-hook
block (line 515), add a third block in the same shape as lines 508-512: when
`$OB_ROOT/agent/local/commands` is a directory, `cp -R "$OB_ROOT/agent/local/commands/." "$dir/.omp/commands/"`;
otherwise

```
ob_warn "missing $OB_ROOT/agent/local/commands — /openbuilder-plan will not be available in the session"
```

Change nothing else in the function; the `/.omp/` git-exclude at lines 519-521 already covers the new
directory.

### 4. `cmd_plan` — rewrite the body

Keep the function name and its position in the file. New body, in this order:

1. `local usage="usage: $OB_PROG plan <owner/repo> <epic>"`; `[[ $# -eq 2 ]] || ob_die "$usage"`.
2. `local repo=$1 epic=$2`; `ob_validate_repo "$repo"`; `ob_validate_slug "$epic"`;
   `ob_need git gh omp`; `ob_need_gate`.
3. `dir=$(ob_ensure_clone "$repo")`; `branch=$(ob_design_branch "$epic")`;
   `base=$(ob_default_branch "$repo")`; `current=$(git -C "$dir" rev-parse --abbrev-ref HEAD)`.
4. Branch resolution — exactly three cases, in this order:
   - `current == $branch` → no git command at all. Log
     `ob_info "already on design branch $branch"`. This is what makes resumption non-destructive.
   - the tree has staged or unstaged changes to tracked files
     (`! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet`) → refuse:
     ```
     ob_die "$dir has uncommitted changes on branch $current; commit or stash them before switching to $branch
  git -C $dir status --short"
     ```
   - `refs/remotes/origin/$branch` exists (`git -C "$dir" show-ref --verify --quiet`) → log
     `ob_info "checking out existing design branch $branch"` then
     `git -C "$dir" checkout -B "$branch" --track "origin/$branch" --quiet`.
   - otherwise → log `ob_info "creating design branch $branch from origin/$base"`, then
     `git -C "$dir" checkout -B "$branch" "origin/$base" --quiet`, then
     `git -C "$dir" push --quiet --set-upstream origin "$branch"`, then
     `ob_info "pushed $branch to origin"`. Push only on creation, never on checkout.
5. `ob_install_local_assets "$dir"`.
6. Approval check. Skip it entirely when `$dir/.openbuilder/epics/$epic/state.json` does not exist:
   log `ob_info "no epic directory for $epic yet — the session will start intake"`. Otherwise capture
   the exit code (`local rc=0; ob_gate "$dir" verify "$epic" --all || rc=$?`) and branch with a
   `case` on `$rc`:
   - `0` → `ob_info "approvals for epic $epic verified"`
   - `3` → refuse with exactly:
     ```
     ob_die "an approval for epic $epic is void: an approved artifact changed after it was approved.
  Inspect it:   (cd $dir && $OB_BIN_DIR/ob-gate show $epic)
  Re-approve:   (cd $dir && $OB_BIN_DIR/ob-gate record $epic <stage>)"
     ```
   - `4` → `ob_info "no approvals recorded for epic $epic yet"` and continue. Absent is normal before
     the first gate; only void is fatal.
   - `2` → `ob_die "ob-gate rejected 'verify $epic --all' as a usage error (exit 2); the CLI and ob-gate disagree about the command surface"`
   - anything else → `ob_die "ob-gate verify $epic --all failed with exit $rc"`
7. Build the seed with a `cat <<EOF` heredoc, as today. The text is exactly this, with `$repo`,
   `$epic`, `$branch` and `$OB_BIN_DIR` interpolated:

   ```
   You are running as the openbuilder workflow session for <repo>, epic `<epic>`.

   Load the `openbuilder-workflow` skill and resume epic `<epic>`. Do not ask me what
   to do first — the skill and the recorded stage decide that.

   The epic's durable state is `.openbuilder/epics/<epic>/` on the current branch
   (`<branch>`): intake.md, prd.md, rfc.md, state.json. Read state.json first and
   continue at the stage it names. If that directory does not exist this is a new
   epic: run `<OB_BIN_DIR>/ob-gate init <epic> --repo <repo>` and start intake.

   `<OB_BIN_DIR>/ob-gate` is the only thing that may write state.json or record an
   approval. Never edit state.json by hand, and never record an approval I did not
   give in this session.

   Never create or push a branch under `openbuilder/plan/` — `openbuilder dispatch`
   does that, and it is the gate that spends money.
   ```

8. Launch: `ob_info "launching omp workflow session ($OB_OPUS_MODEL) in $dir"` then the same
   `GH_REPO="$repo" exec omp --cwd "$dir" --model "$OB_OPUS_MODEL" --append-system-prompt … "$seed"`
   call as lines 626-630, with the system prompt exactly:

   ```
   openbuilder workflow session for <repo> epic <epic> on branch <branch>. Artifacts live in .openbuilder/epics/<epic>/. Only local/bin/ob-gate writes state.json. Never push a branch under openbuilder/plan/, never merge.
   ```

### 5. Delete `ob_write_plan_scaffold`

Remove lines 633-660 in full. `cmd_plan` was its only caller, and the planner subagent now writes
`plan.md` from the RFC. Leave no wrapper and no comment where it was.

### 6. `ob_command_table`

Replace the `plan` line (line 535) with, keeping the existing two-space indent and column alignment:

```
  plan <owner/repo> <epic>          design branch + Opus 5 workflow session for an epic
```

### 7. `README.md`

Rewrite the `### 9. Plan a change` section (README.md:342-353) so it is true: the command takes an
epic, not a slug; it works on `openbuilder/design/<epic>`; the session runs intake → PRD → RFC →
backlog with a human gate at each of the last three; the cards land under
`.openbuilder/backlog/<slug>/` and the contract is still `backlog/SCHEMA.md`. Use
`openbuilder plan you/your-repo healthz-endpoint` as the example command so the following sections
still read as one story. Change nothing else in `README.md`.

## Acceptance

- `shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing. It exits 0 today; it
  must still exit 0 and print nothing after this story.
- Argument handling, no network needed:
  - `local/bin/openbuilder plan; echo $?` prints
    `openbuilder: usage: openbuilder plan <owner/repo> <epic>` on stderr and `1`.
  - `local/bin/openbuilder plan a/b c d; echo $?` prints the same and `1`.
  - `local/bin/openbuilder plan artemkurylo/openbuilder Not_An_Epic 2>&1 | grep -c "invalid slug 'Not_An_Epic'"`
    prints `1`.
- `grep -c ob_write_plan_scaffold local/bin/openbuilder` prints `0`.
- `grep -c '^  plan <owner/repo> <epic>' local/bin/openbuilder` prints `1`, and
  `local/bin/openbuilder help | grep -c 'plan <owner/repo> <slug>'` prints `0`.
- **Sandbox required.** Create a throwaway repo you own (`gh repo create <you>/ob-sandbox --private`)
  with one commit on its default branch, and export `OPENBUILDER_WORKSPACE=$(mktemp -d)`. Put a fake
  `omp` first on `PATH` that appends `"$@"` to `$OB_FAKE_OMP` and exits 0, so no model is billed.
  Then `local/bin/openbuilder plan <you>/ob-sandbox demo-epic` and assert all five:
  1. `gh api repos/<you>/ob-sandbox/git/ref/heads/openbuilder/design/demo-epic --jq .ref` prints
     `refs/heads/openbuilder/design/demo-epic`.
  2. `git -C "$OPENBUILDER_WORKSPACE/<you>__ob-sandbox" rev-parse --abbrev-ref HEAD` prints
     `openbuilder/design/demo-epic`.
  3. `test -d "$OPENBUILDER_WORKSPACE/<you>__ob-sandbox/.omp/commands"` exits 0.
  4. `grep -c -- '--model amazon-bedrock/us.anthropic.claude-opus-5' "$OB_FAKE_OMP"` prints `1`.
  5. Running the same command a second time prints `already on design branch openbuilder/design/demo-epic`
     and leaves `git -C … status --porcelain` output unchanged.
  Clean up: `gh repo delete <you>/ob-sandbox --yes` and `rm -rf "$OPENBUILDER_WORKSPACE"`.
- **Sandbox required.** With `ob-gate` absent (it is, until `plan-workflow-01-gate` merges),
  `local/bin/openbuilder plan <you>/ob-sandbox demo-epic` exits 1 with
  `local/bin/ob-gate is missing or not executable` on stderr.

## Out of scope

- **No drive-by refactor of `local/bin/openbuilder`.** It is 1189 lines. Touch only
  `ob_install_local_assets`, `cmd_plan`, `ob_command_table`'s `plan` line, and the two new one-line
  helpers, and delete `ob_write_plan_scaffold`. No reordering, no renaming, no re-indentation, no
  extraction of a "shared" branch-resolution helper, no change to any other `cmd_*` function.
- No `cmd_dispatch`, `cmd_review`, `cmd_status` or `cmd_land` change — the other three stories in this
  slug own those.
- Do not create `local/bin/ob-gate`, do not write `state.json`, do not run `ob-gate init`. The session
  runs `init`; `plan-workflow-01-gate` writes the script.
- Do not create `agent/local/commands/openbuilder-plan.md` or the `openbuilder-workflow` skill.
  `plan-workflow-04-agents` owns them; the mirror must tolerate their absence.
- Do not add an `origin`-host check, a `GH_HOST` pin or an owner allowlist. `plan-workflow-00-host`
  owns those and puts the `origin` assertion inside `ob_ensure_clone`.
- Do not edit `README.md`'s mermaid diagram (lines 14-33) or `## The daily loop` (lines 409-417).
  `story-04-land-teardown` owns both. Do not edit `docs/runbook.md` at all in this story — it never
  mentions `openbuilder plan`.
- No `--dry-run`, `--force`, `--epic` or `--branch` flag on `plan`. Two positional arguments, nothing
  else.
- No new dependency, no new environment variable, no change to `.openbuilder.local` handling.

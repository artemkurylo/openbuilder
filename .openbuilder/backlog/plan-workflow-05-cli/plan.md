# feat(cli): stage-aware plan, a gated dispatch, unattended review and land

- epic: plan-workflow

## Goal

`local/bin/openbuilder` becomes the laptop half of the gated workflow. Four commands change or
appear, and after this slug the four documented commands in PRD §7.6 are the only ones needed from a
problem statement to a merged pull request:

1. `openbuilder plan <owner/repo> <epic>` — prepares the clone, creates or checks out
   `openbuilder/design/<epic>`, verifies every recorded approval, and launches one Opus 5 session
   seeded with prose that resumes the epic at its recorded stage.
2. `openbuilder dispatch <owner/repo> <slug>` — refuses to cut a plan branch until
   `ob-gate verify <epic> backlog` says the backlog approval is intact and covers this slug, records
   `stage: dispatched` **before** the plan branch exists, then cuts `openbuilder/plan/<slug>` from
   the design-branch tip.
3. `openbuilder review --watch <owner/repo> <pr>` — carries a pull request to a verdict without a
   human driving each round, reviewing each new head sha exactly once, capped at
   `OPENBUILDER_MAX_ATTEMPTS`.
4. `openbuilder land <owner/repo> <pr>` — merges an approved pull request and returns the world to
   its pre-epic state: three branches gone from `origin`, no worktree and no per-slug state left on
   the instance.

Plus one read-only surface: `openbuilder status` gains an `UNAPPR` column, because a rule-4b decline
is deliberately silent (RFC §4.3) and silence needs exactly one place a human can look.

Implements PRD **R1** (resumable entry point), **R7** (review converges without being driven) and
**R8** (merging is one human action that leaves nothing behind), per RFC **§3.1**, **§3.2**, **§3.5**,
**§3.6** and **§3.7**.

## Why now

`cmd_plan` today (`openbuilder:564-631`) is slug-shaped, not epic-shaped: it cuts
`openbuilder/plan/<slug>` on the spot, scaffolds a `plan.md` with `ob_write_plan_scaffold`
(`openbuilder:633-660`), and seeds a session whose only job is writing cards. That means the design
phase starts on the branch the poller triggers on — the spend switch is thrown before anything is
approved, which is precisely the hole PRD §2 and R4 exist to close.

`cmd_dispatch` (`openbuilder:666-731`) has no gate at all. Its five preconditions are a clone, a
backlog directory, a `plan.md`, at least one `story-*.md`, and nothing else; it then commits the
backlog itself (`openbuilder:699-707`) and pushes. So the recorded human yes never enters the
picture, and dispatch is the only actor that can set `stage: dispatched` (RFC §3.5 step 3, and
`plan-workflow-01-gate` deliberately leaves `record backlog` from touching `stage`).

Review is hand-cranked in three commands per round, and nothing tears down: two finished slugs still
have their plan branches on `origin` and a worktree plus a state directory each on the instance
(PRD §2, third bullet).

## Approach

Four stories, one per command, because each has its own verification command and its own failure
mode. All four edit the same file, so the ordering rule is: `story-01` introduces
`ob_design_branch` and the gate-invocation helper, `story-02` introduces `ob_epic_of_plan` and the
`UNAPPR` column, `story-04` consumes both. `story-03` shares no new symbol with the others and
carries `depends_on: []`.

Decisions made here so no card leaves one open:

- **`ob-gate` is invoked as a sibling script inside the clone.** `plan-workflow-01-gate` gives it
  `REPO_ROOT` from `git rev-parse --show-toplevel`, so it operates on whatever repository contains
  the working directory. The CLI therefore calls it through one helper,
  `ob_gate <clone-dir> <args...>`, which runs `( cd "<clone-dir>" && "$OB_BIN_DIR/ob-gate" "$@" )`.
  One choke point, one place the exit code is read, and no `PATH` dependency.
- **Exit codes are branched on, never collapsed.** `ob-gate verify` returns 0 intact, 3 void, 4
  absent, 2 usage, 1 operational refusal (RFC §3.4, and `plan-workflow-01-gate`'s surface). Every call
  site captures the code with `rc=0; ob_gate … || rc=$?` and uses a `case` with a distinct message per
  code and a catch-all for anything else. `set -e` would otherwise abort before the message is
  printed.
- **`dispatch` verifies one slug, not the epic.** `ob-gate verify <epic> backlog` takes an optional
  slug, and without it an epic with *some* recorded backlog approval exits 0 even when the slug being
  dispatched was never approved. So `cmd_dispatch` always calls
  `ob-gate verify <epic> backlog <slug>`, and exit 4 therefore means "not recorded for this slug". The
  CLI never parses `state.json` to decide whether an approval exists — it reads an exit code.
- **`<epic>` is validated with the existing `ob_validate_slug`** (`openbuilder:249-252`), not a new
  `ob_validate_epic`. RFC §2 says an epic name *is* a slug under the same regex; a second function
  would be a second convention for one rule. This also guards the extraction: `plan.md`'s
  `- epic:` line is a plain bullet with no backticks (RFC §2), so a value like `` `plan-workflow` ``
  copied from a PRD header fails loudly at validation instead of producing a path that does not
  exist.
- **`cmd_plan` never runs `ob-gate init`.** The session does, on the `stage: intake` branch of its
  own procedure (`plan-workflow-04-agents`, `SKILL.md` step 2), because `/openbuilder-plan` is an
  equal entry point (RFC §3.1) and must not depend on having been launched by the CLI. `cmd_plan`
  prepares the clone, holds the design branch, fails fast on a void approval, and launches.
- **The seed is prose.** Whether omp expands a slash command supplied as the initial positional
  prompt is `[UNVERIFIED]` (RFC §3.1) and the design does not depend on it, so the seed says "load
  the `openbuilder-workflow` skill and resume epic `<epic>`" in words. It also carries the absolute
  path of `ob-gate`, because the session's cwd is the target clone, not this control repo.
- **`--watch` copies the verified headless invocation in full**, including
  `--approval-mode yolo --auto-approve` from `ob-common.sh:706`. RFC §3.6 elides those two flags in
  prose while citing that line as the verified invocation; without them a headless run that must
  label and comment stalls on an approval prompt.
- **In `--watch` the reviewer applies its own verdict** by running
  `"$OB_BIN_DIR/openbuilder" approve|request-changes <repo> <pr>` itself. R7 says one command carries
  the pull request to a verdict; a headless reviewer that ends by *telling a human* to run `approve`
  is the loop it was supposed to close. Both subcommands already exist and already do the labelling,
  the comment and the instance wake-up.
- **The marker is written only after a reviewer run exits 0.** A failed run must be retried, not
  remembered as reviewed. The round counter still increments, so a repeatedly failing run is bounded
  by the same cap instead of looping.
- **`land` needs no clone.** It reads `plan.md` and `state.json` over the contents API with
  `-H 'Accept: application/vnd.github.raw'` and deletes refs with `gh api -X DELETE`. Verified on
  this laptop, 2026-08-09: that header returns the file body verbatim, and a directory listing
  returns one `sha` per entry.
- **Instance teardown goes through `ob_ssm_exec`, not `local/bin/obrun`.** `ob_ssm_exec`
  (`openbuilder:276-338`) is already the CLI's SSM path, already polls to a terminal state and
  already returns the remote exit code. `obrun` exists for ad-hoc bash payloads and resolves its own
  profile. Both run under `/bin/sh` (dash) via AWS-RunShellScript, so the payload is strictly POSIX
  — no `[[`, no arrays, no `${var//x/y}` — and the `git` parts run `sudo -u openbuilder` so root
  never touches a repository owned by the service user.
- **Doc ownership is split by section, not shared.** Each story updates the `ob_command_table` line
  it changes and the runbook/README section that describes its own command. `story-04` owns the
  three whole-flow surfaces — README's mermaid diagram, README's `## The daily loop`, and the
  runbook's `## 0.` and `## 19.` — plus a new runbook `## 20. Refusals from the laptop CLI`.
  Appended as §20 rather than inserted as a new §19, for the reason RFC §4.1 gives about renumbering
  a thing other documents point at.

### Why the slug is sized `L` and not a mislabelled `M`

`backlog/SCHEMA.md:102-108` calls `L` a smell and says the failure mode is concrete: a large story
burns `OPENBUILDER_MAX_ATTEMPTS` on rounds that each re-litigate a different third of the diff. That
warning is about a **story**, and no story here is `L` — all four are `M`, each with one command, one
verification path and two to three files. The slug is `L` because it is four `M` stories in one
1189-line file (RFC §9).

Splitting the slug is worse than sizing it honestly, for one mechanical reason: `dispatch` gates
against a `state.json` field that only `dispatch` itself sets. Ship the gate without the
`ob-gate stage <epic> dispatched` call and every plan branch it cuts carries `stage: backlog`, so
rule 4b declines it on every poll pass forever (RFC §3.5, last paragraph) — a slug that can never run
and never reports why. Ship `land` without the gate and `land` has no `stage`/`slugs` contract to
read. The four commands are meaningless without each other because they are one state machine seen
from four angles.

The cost of getting it wrong is bounded in a way the SCHEMA warning is not: this slug is last, nothing
depends on it, and if a round fails nothing upstream is blocked (RFC §9, closing paragraph).

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-plan-launcher | Turn `openbuilder plan` into a stage-aware design-branch launcher | M | [] |
| story-02-dispatch-gate | Gate dispatch on a recorded backlog approval and flag it in status | M | [story-01-plan-launcher] |
| story-03-review-watch | Add `openbuilder review --watch` with a reviewed-head marker and cap | M | [] |
| story-04-land-teardown | Add `openbuilder land` to merge an approved PR and delete its branches | M | [story-02-dispatch-gate] |

## Out of scope

- **No `runner/**` and no `waker/**`.** Rule 4b is `plan-workflow-02-rule`; the PRD/RFC prompt blocks
  and the epic-docs copy are `plan-workflow-03-context`; `ob_load_env`'s `OPENBUILDER_GH_HOST`
  assertion is `plan-workflow-00-host`.
- **No `local/bin/ob-gate`.** `plan-workflow-01-gate` builds it. This slug only calls it and reads
  its exit codes. If it is absent, the new call sites refuse with the exact message each card names —
  they do not reimplement any part of it, and nothing in this slug ever writes `state.json`.
- **No `ob_gh` wrapper, no owner allowlist, no `origin`-host assertion.**
  `plan-workflow-00-host` owns all three, and its story-01 puts the `origin` assertion inside
  `ob_ensure_clone`, which every command here already calls. New `gh` call sites *use* `ob_gh`; they
  do not define or move it.
- **No agents, skills, slash-command files or `docs/workflow.md`.** `plan-workflow-04-agents`.
- **No `backlog/SCHEMA.md` change.** `plan-workflow-01-gate` story-03 documents the `- epic:` line.
- **No drive-by refactor of `local/bin/openbuilder`.** It is 1189 lines and every story here touches
  a named function inside it. No reordering of functions, no renaming of an existing function or
  variable, no re-indentation, no extraction of a "common" helper that no card asks for, no
  conversion of an existing `gh`/`aws` call site, and no change to `cmd_logs`, `cmd_shell`,
  `cmd_doctor`, `cmd_start`, `cmd_stop`, `cmd_cost`, `ob_ssm_exec`, `ob_aws`, `ob_region` or
  `ob_instance_id`.
- **No new dependency and no new configuration file format.** `git`, `gh`, `jq`, `aws` and `omp`
  only, exactly as today.
- **No `Makefile`, CI or Terraform change.** `make lint` already globs `local/bin/*`.

## Risks

- **This slug edits the file that dispatches the epic, so it lands last and alone.** RFC §9 and PRD
  §10 ("the tool builds the tool"): the worker implements the dispatcher it was dispatched by. The
  mitigations are structural, not hopeful — the instance runs its own clone of `main`
  (`/opt/openbuilder/repo`) and only advances it via `ob-selfupdate`, so a broken working copy of
  `local/bin/openbuilder` on a work branch cannot affect the round producing it, and nothing merges
  without review. A reviewer should read the four command functions separately rather than as one
  change.
- **`plan-workflow-00-host` must merge first.** It adds `ob_gh()` and moves twelve existing `gh` call
  sites onto it. This slug adds new `gh` call sites in `cmd_status`, `cmd_review` and `cmd_land`; if
  it lands first, those are four more unpinned sites that inherit the ambient `GH_HOST` and someone
  has to audit them for a property they should have inherited (RFC §4b.3, last paragraph). Every card
  here therefore instructs: call `gh` only through `ob_gh`, and if `ob_gh` is not defined in
  `local/bin/openbuilder`, stop and report the missing prerequisite instead of calling `gh` directly.
- **A broken `dispatch` cannot be fixed by dispatching.** `dispatch` is the only way to put a plan
  branch on `origin`, and a plan branch is the poller's only trigger (`ob-poll:49`,
  `waker/github.py:87` match `refs/heads/openbuilder/plan/` only). If this slug's `cmd_dispatch`
  merges broken, the recovery is manual — cut and push the plan branch by hand, or fix the CLI by
  hand on the laptop — and no amount of re-planning helps, because re-planning ends in a `dispatch`
  that does not work. This is why story-02's acceptance exercises every refusal path by exit code and
  message before the happy path, and why its ordering guard is an assertion in the code rather than a
  comment.
- **The ordering constraint in story-02 is invisible in a diff read top to bottom.** `ob-gate stage
  <epic> dispatched` must be committed on the design branch *before* `openbuilder/plan/<slug>` is
  cut. Reversed, the plan branch carries `stage: backlog`, rule 4b declines quietly on every pass,
  and the operator sees a plan branch that produces nothing and logs nothing to the operational log.
  Reviewer should check that the code asserts `stage == dispatched` on the design-branch tip and
  refuses to cut the plan branch otherwise, rather than merely calling the two things in the right
  order.
- **`--watch` runs an unattended Opus 5 loop that can label and comment.** It is capped at
  `OPENBUILDER_MAX_ATTEMPTS` rounds and it writes the reviewed head sha to a marker, but the two
  guards protect different failures: the cap bounds spend, the marker prevents re-reviewing a round.
  Reviewer should check the marker is written only after a run exits 0 (a failed run must be retried,
  not remembered) and that the round counter increments even when the run fails (or a failing run
  loops forever inside the cap).
- **`land` is destructive and irreversible past step 3.** Once `gh pr merge` succeeds, the branch
  deletions cannot be undone by re-running the command, because the second run refuses on the
  `openbuilder:approved`/`OPEN` precondition. Reviewer should check the typed confirmation is
  required *before* the merge, that the confirmation compares against the exact string `land <slug>`,
  and that the design branch is deleted only when no other slug in `state.json.slugs` still has a
  plan branch on `origin`.

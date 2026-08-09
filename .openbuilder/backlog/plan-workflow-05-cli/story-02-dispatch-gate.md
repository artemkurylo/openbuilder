---
id: story-02-dispatch-gate
title: Gate dispatch on a recorded backlog approval and flag it in status
size: M
depends_on:
  - story-01-plan-launcher
files:
  - local/bin/openbuilder
  - docs/runbook.md
  - README.md
acceptance:
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
  - "a dispatch of a slug with no `approvals.backlog[<slug>]` entry exits 1 and prints `no backlog approval is recorded for <slug>`"
  - "a dispatch of a slug whose card was edited after approval exits 1 and prints `no longer matches`, and `gh api repos/<repo>/git/matching-refs/heads/openbuilder/plan/<slug>` returns an empty array afterwards"
  - "a dispatch whose `state.json` on the design branch does not say `stage: dispatched` exits 1, prints `refusing to cut`, and creates no plan branch"
  - "`grep -c 'openbuilder: backlog for' local/bin/openbuilder` prints 0"
  - "`openbuilder status <repo>` prints a header containing `UNAPPR` and prints `yes` in that column for a hand-pushed plan branch with no approval"
---

## Context

`cmd_dispatch` (`local/bin/openbuilder:666-731`) has no gate. It checks a clone exists (680-681), a
backlog directory exists (685-686), a `plan.md` exists (687-688) and at least one `story-*.md` exists
(690-692); then it checks out the plan branch (694-697), commits the backlog itself (699-707) and
pushes (709-710). No recorded human approval enters the picture, which is the hole PRD §2 and R4
close.

RFC §3.5 gives dispatch five steps: resolve `<epic>` from `plan.md`; `ob-gate verify <epic> backlog
<slug>` and refuse on anything but 0; `ob-gate stage <epic> dispatched` committed on the design
branch; cut
`openbuilder/plan/<slug>` **from the design-branch tip** and push it; `ob_ensure_labels` and the
"what happens next" report as today.

Two facts that shape the code:

- **The backlog now lives on the design branch.** The planner writes the cards there and
  `ob-gate record <epic> backlog <slug>` commits and pushes them (`plan-workflow-01-gate`: "every
  state-mutating subcommand commits and pushes"). Dispatch therefore authors no commit to the backlog
  at all — the `git add`/`git commit` block at lines 699-707 has to go, or dispatch would create a
  commit whose bytes no approval covers.
- **The ordering is load-bearing.** `ob-gate record backlog` deliberately leaves `stage` untouched,
  so `dispatch` is the only thing that sets `dispatched`. Cut the plan branch first and it carries
  `stage: backlog`; rule 4b then declines it on every poll pass forever, logging only to stdout and
  writing nothing to the operational log (RFC §3.5 last paragraph, §4.3). The slug produces nothing
  and explains nothing. So the code must *assert* `stage == dispatched` on the design-branch tip
  before it creates the plan branch, not merely call the two things in order.

`cmd_status` (`openbuilder:839-898`) is the one visible surface for that quiet decline (RFC §4.3). It
lists every `openbuilder/plan/*` ref from three `gh api`/`gh pr list` calls (847-850), folds them
with one `jq` program (852-878), prints a fixed-width header (886-891) and a `while IFS=$'\t' read`
loop (892-897).

Verified on this laptop, 2026-08-09, against `artemkurylo/openbuilder`:

- `gh api "repos/<repo>/contents/<path>?ref=<branch>" -H 'Accept: application/vnd.github.raw'` prints
  the file body verbatim.
- `gh api "repos/<repo>/contents/<dir>?ref=<branch>"` returns one entry per file with `name`, `type`
  and `sha`, where `sha` is the git blob sha (RFC §12).

Traps:

- `plan.md`'s epic line is a plain bullet, `- epic: plan-workflow`, with **no backticks** (RFC §2).
  The extracted value must be validated so a backticked value copied from a PRD header fails loudly.
- `set -e` aborts on a non-zero `ob_gate` call before you can read the code. Capture it with
  `local rc=0; ob_gate … || rc=$?`.
- `git push --force` is forbidden repo-wide (`AGENTS.md`, "Never force-push"). A re-dispatch onto a
  diverged `origin/openbuilder/plan/<slug>` must refuse, not force.
- `plan-workflow-00-host` adds the `ob_gh` wrapper. Every new `gh` call in this story goes through it.

## Change

### 1. `ob_epic_of_plan`

Add below `ob_gate` (added by `story-01-plan-launcher`). `ob_epic_of_plan` takes **no arguments** and
reads `plan.md` on **stdin**, printing the epic name with `awk '/^- epic:/ {print $3; exit}'` — the
exact extraction RFC §2 specifies. Reading stdin rather than a path is what lets `cmd_dispatch` feed
it a file and `cmd_status` feed it an API response. It prints nothing when the line is absent.

### 2. `cmd_dispatch` — rewrite the body

Keep the function name and position. New body, in exactly this order:

1. Usage and validation as today (lines 667-672), unchanged, including `ob_need git gh aws jq`.
2. Delete the `ob_ensure_running` call at line 676 **from here** and re-add it at step 9 below. Keep
   the comment at 674-675 with the call. Refusing a dispatch must cost no EC2 time, and the comment
   stays true because the instance is up before the plan branch exists.
3. `dir=$(ob_clone_dir "$repo")`; `backlog=.openbuilder/backlog/$slug`. Replace the message at line
   681 with, exactly:
   ```
   ob_die "no local clone at $dir — run '$OB_PROG plan $repo <epic>' first"
   ```
   Keep the checks at 685-692 and their messages verbatim, replacing `'$OB_PROG plan $repo $slug'`
   with `'$OB_PROG plan $repo <epic>'` in the message at line 686.
4. Resolve the epic:
   ```
   epic=$(ob_epic_of_plan <"$dir/$backlog/plan.md")
   ```
   Empty → refuse:
   ```
   ob_die "$backlog/plan.md has no '- epic:' line; dispatch cannot tell which epic gates this slug.
  Add a line reading exactly '- epic: <epic>' under its first heading (backlog/SCHEMA.md)."
   ```
   Then `ob_validate_slug "$epic"` — a backticked or quoted value fails here.
5. `design=$(ob_design_branch "$epic")`. Assert the clone is on it:
   ```
   current=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
   [[ $current == "$design" ]] || ob_die "$dir is on branch $current, not the design branch $design for epic $epic.
  Run: $OB_PROG plan $repo $epic"
   ```
6. Assert the backlog directory has no uncommitted and no untracked changes, because an approval covers
   committed bytes only and `ob-gate verify` has nothing to say about a file it never recorded:
   ```
   if [[ -n $(git -C "$dir" status --porcelain -- "$backlog") ]]; then
     ob_die "$backlog has uncommitted or untracked changes in $dir:
   $(git -C "$dir" status --porcelain -- "$backlog")
   An approval covers committed bytes only. Commit these, then re-approve:
     (cd $dir && $OB_BIN_DIR/ob-gate record $epic backlog $slug)"
   fi
   ```
   Using `status --porcelain` rather than `diff` on purpose: it catches an untracked new story card,
   which is exactly the "no extra `story-*.md`" case rule 4b checks on the plan branch.
7. `ob_need_gate`, then the gate. `ob-gate verify` takes an optional slug —
   `ob-gate verify <epic> backlog [<slug>]` — and with the slug given it answers about that slug
   alone, which is the only question dispatch is asking. Without it, an epic that has *some* recorded
   backlog approval exits 0 even when this slug was never approved. So always pass the slug.

   `local rc=0; ob_gate "$dir" verify "$epic" backlog "$slug" || rc=$?` and a `case` on `$rc`:
   - `0` → `ob_info "backlog approval for $slug on epic $epic verified"`
   - `3` → refuse:
     ```
     ob_die "the recorded backlog approval for $slug no longer matches the files on $design — an artifact changed after it was approved.
  Re-approve this slug, then dispatch again:
    (cd $dir && $OB_BIN_DIR/ob-gate record $epic backlog $slug)"
     ```
   - `4` → refuse:
     ```
     ob_die "no backlog approval is recorded for $slug in .openbuilder/epics/$epic/state.json.
  Approve this slug, then dispatch again:
    (cd $dir && $OB_BIN_DIR/ob-gate record $epic backlog $slug)"
     ```
   - `2` → `ob_die "ob-gate rejected 'verify $epic backlog $slug' as a usage error (exit 2); the CLI and ob-gate disagree about the command surface"`
   - anything else → `ob_die "ob-gate verify $epic backlog $slug failed with exit $rc"`

   That is the whole gate. Do not add a second `jq` read of `state.json` to check for the slug — exit
   4 already means "not recorded for this slug", and the CLI never parses `state.json` for an approval
   decision.
8. Advance the stage, then prove it:
   ```
   ob_info "recording stage=dispatched for epic $epic on $design"
   ob_gate "$dir" stage "$epic" dispatched ||
     ob_die "'ob-gate stage $epic dispatched' failed; no plan branch was created"
   ```
   `ob-gate stage` commits `state.json` by pathspec and pushes `HEAD:refs/heads/<branch>` itself, so
   dispatch authors no commit and runs no push of its own here. It only verifies, with two assertions,
   both before any plan-branch work:
   - the design-branch tip carries it:
     ```
     stage_now=$(git -C "$dir" show "$design:.openbuilder/epics/$epic/state.json" | jq -r '.stage')
     [[ $stage_now == dispatched ]] || ob_die "state.json on $design still says stage='$stage_now' after 'ob-gate stage $epic dispatched'; refusing to cut $(ob_plan_branch "$slug"), because rule 4b would decline it on every poll pass forever"
     ```
   - `origin` has it, since the plan branch is cut from the local design tip and the design branch is
     the audit trail:
     ```
     git -C "$dir" fetch --quiet origin
     [[ $(git -C "$dir" rev-parse "$design") == $(git -C "$dir" rev-parse "origin/$design") ]] ||
       ob_die "$design differs from origin/$design after 'ob-gate stage $epic dispatched'; push it before dispatching:
    git -C $dir push origin $design"
     ```
9. `ob_ensure_running` — here, with the comment from lines 674-675 moved with it.
10. Cut the plan branch from the design tip **without checking it out**, so the clone stays on the
    design branch for the next slug:
    ```
    branch=$(ob_plan_branch "$slug")
    ```
    If `refs/remotes/origin/$branch` exists and
    `git -C "$dir" merge-base --is-ancestor "origin/$branch" "$design"` fails, refuse:
    ```
    ob_die "origin/$branch already exists and is not an ancestor of $design; pushing it would rewrite history, which openbuilder never does.
  Delete it first if this dispatch is intentional:
    gh api -X DELETE repos/$repo/git/refs/heads/$branch"
    ```
    Otherwise `git -C "$dir" branch -f "$branch" "$design"`, log
    `ob_info "created plan branch $branch from $design"`, then
    `git -C "$dir" push --quiet --set-upstream origin "$branch"` and
    `ob_info "pushed $branch to origin"`.
11. `ob_ensure_labels "$repo"` as today (line 712).
12. Keep the closing `cat <<EOF` report (714-730) with three edits: add a
    `design branch : $design` line above `plan branch`; insert a new numbered step between today's 1
    and 2 reading
    `2. Rule 4b re-checks the recorded backlog approval against the plan branch. A mismatch is a silent skip — 'openbuilder status $repo' is where it shows up.`
    and renumber the two steps after it; change the final `Then:` line to
    `$OB_PROG review --watch $repo <pr>`.

### 3. `cmd_status` — the `UNAPPR` column

Add a function `ob_status_unapproved <repo> <slug>` directly above `cmd_status`. It prints exactly one
of three tokens on stdout and never exits non-zero:

- `-` — rule 4b would let this plan branch through;
- `yes` — rule 4b would decline it;
- `?` — an API call failed or a response did not parse, so the answer is unknown.

It mirrors RFC §4.2 against `refs/heads/<plan-branch>`, using `ob_gh` for all three calls:

1. `plan.md` body via `gh api "repos/$repo/contents/.openbuilder/backlog/$slug/plan.md?ref=$plan_branch" -H 'Accept: application/vnd.github.raw'`.
   Call failure → `?`. Empty body, or no epic from `ob_epic_of_plan`, or an epic that fails the slug
   regex → `yes`.
2. `state.json` body from `.openbuilder/epics/<epic>/state.json` on the same ref, same header. Call
   failure → `?`. Unparseable JSON → `yes`.
3. The directory listing `gh api "repos/$repo/contents/.openbuilder/backlog/$slug?ref=$plan_branch"`.
   Call failure → `?`.

Then one `jq -e -n` expression taking the listing and `state.json` as `--argjson` and the slug as
`--arg`, which is true only when all three hold:

- `.stage == "dispatched"`;
- `.approvals.backlog[<slug>].files` exists;
- that `files` map is **exactly equal** to the map built from the listing — key `name`, value `sha` —
  restricted to entries whose `type` is `"file"` and whose `name` is `plan.md` or matches
  `story-*.md`. Equality both ways: no extra card, no missing card, no changed sha.

True → print `-`. False → print `yes`. A `jq` invocation that itself fails → print `?`.

In `cmd_status`, call it from the existing `while IFS=$'\t' read` loop (892-897) only when the row's
`pr` field is `-`; when the slug already has a pull request print `-` without any call, because rule
4b never reaches a slug that has one (RFC §4.2). Add the column between `PR` and `LABELS` in all three
`printf` format strings (886-891 and 895-896) as `%-7s`, header `UNAPPR`, separator row `-------`.
Leave the `jq` program at 852-878 untouched.

### 4. `ob_command_table`

Replace the `dispatch` line (line 536) with:

```
  dispatch <owner/repo> <slug>      gate the backlog, cut and push the plan branch
```

### 5. Docs

- `docs/runbook.md:83-88` (§1c): the re-dispatch snippet must say that editing a card voids the
  approval, so the sequence is edit, commit, `ob-gate record <epic> backlog <slug>`, then
  `openbuilder dispatch`. Keep the `[§13]` cross-reference on the line after.
- `docs/runbook.md:790-795` (§13): same correction — `openbuilder dispatch` alone no longer suffices
  after editing cards.
- `README.md:355-362` (`### 10. Dispatch`): replace "commits the backlog directory, pushes …" with
  what it does now — verifies the recorded backlog approval, records `stage: dispatched` on the design
  branch, cuts `openbuilder/plan/<slug>` from the design-branch tip and pushes it, and ensures the six
  labels. Say that it refuses when the approval is absent or void.

## Acceptance

- `shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.
- `grep -c 'openbuilder: backlog for' local/bin/openbuilder` prints `0` — dispatch no longer authors
  a backlog commit.
- `local/bin/openbuilder status artemkurylo/openbuilder | head -2` prints a header row containing
  `UNAPPR`, and every data row has six columns before `LAST ACTIVITY`.
- **Sandbox required** for the four live paths below. Create `gh repo create <you>/ob-sandbox --private`
  with one commit, `export OPENBUILDER_WORKSPACE=$(mktemp -d)`, and prepare it with
  `local/bin/openbuilder plan <you>/ob-sandbox demo-epic` (fake `omp` on `PATH`, as in
  `story-01-plan-launcher`). Commit an epic directory and a one-card backlog under
  `.openbuilder/backlog/demo-slug/` whose `plan.md` carries `- epic: demo-epic`, and push the design
  branch. Then:
  1. **No approval.** With `state.json` at `stage: backlog` and no `approvals.backlog` key,
     `local/bin/openbuilder dispatch <you>/ob-sandbox demo-slug; echo $?` prints
     `no backlog approval is recorded for demo-slug` and `1`, and
     `gh api repos/<you>/ob-sandbox/git/matching-refs/heads/openbuilder/plan/demo-slug --jq length`
     prints `0`.
  2. **Approval recorded for another slug only.** Add `approvals.backlog.other-slug` and re-run:
     stderr contains `no backlog approval is recorded for demo-slug` again — `verify` is asked about
     `demo-slug` alone, so another slug's record does not satisfy it — exit `1`, still no plan branch.
  3. **Mutated card.** Record an approval for `demo-slug` with `ob-gate`, then append a line to
     `story-01-*.md` and commit it. Re-run: stderr contains `no longer matches`, exit `1`, still no
     plan branch.
  4. **Ordering guard.** Record a valid approval, then make `ob-gate` unable to advance the stage
     (put a `stage` subcommand stub earlier on `PATH`, or revert `state.json` to `stage: backlog`
     and re-commit after the `ob-gate stage` call would have run). Re-run: stderr contains
     `refusing to cut`, exit `1`, and still no plan branch.
  5. **Happy path.** Restore a valid approval and run for real: exit `0`,
     `gh api repos/<you>/ob-sandbox/contents/.openbuilder/epics/demo-epic/state.json?ref=openbuilder/plan/demo-slug -H 'Accept: application/vnd.github.raw' | jq -r .stage`
     prints `dispatched`, and
     `git -C "$OPENBUILDER_WORKSPACE/<you>__ob-sandbox" rev-parse --abbrev-ref HEAD` still prints
     `openbuilder/design/demo-epic`.
  6. **The column.** `local/bin/openbuilder status <you>/ob-sandbox` prints `-` in `UNAPPR` for
     `demo-slug`. Then push a second plan branch by hand with no approval
     (`git push origin openbuilder/design/demo-epic:refs/heads/openbuilder/plan/hand-pushed` after
     committing a `hand-pushed` backlog whose `plan.md` names `demo-epic`) and assert the same command
     prints `yes` for it.
  Clean up: `gh repo delete <you>/ob-sandbox --yes`, `rm -rf "$OPENBUILDER_WORKSPACE"`, and remove any
  `PATH` stub you added.

## Out of scope

- **No drive-by refactor of `local/bin/openbuilder`.** It is 1189 lines. Touch only `cmd_dispatch`,
  `cmd_status`'s `printf`s and read loop, the `dispatch` line of `ob_command_table`, and the two new
  functions. No reordering, no renaming, no re-indentation, no rewrite of the `jq` program at 852-878,
  no conversion of an existing `gh` call site to `ob_gh` (`plan-workflow-00-host` owns those), and no
  change to `cmd_plan`, `cmd_review`, `cmd_approve`, `cmd_request_changes` or any `cmd_*` below
  `cmd_status`.
- Do not create or modify `local/bin/ob-gate`, and never write `state.json` from the CLI. `ob-gate` is
  its only writer (RFC §3.4). The CLI never parses `state.json` to decide whether an approval exists;
  it reads `ob-gate verify`'s exit code. The only `jq` reads of `state.json` are the `stage` assertion
  in step 8 and `ob_status_unapproved`, neither of which is an approval decision for dispatch.
- No rule-4b implementation in `runner/bin/ob-poll` or `waker/github.py`. `plan-workflow-02-rule` owns
  the rule; `ob_status_unapproved` only *reports* the same predicate from the laptop and shares no code
  with them.
- No caching, no rate-limit handling and no parallelism in `ob_status_unapproved`. Three API calls per
  plan branch that has no pull request, serial, and `?` on any failure.
- No `--force`, `--no-gate`, `--skip-verify` or `--yes` flag on `dispatch`. There is no bypass; a
  bypass is the thing R4 exists to prevent.
- No `git push --force`, no `--force-with-lease`, no branch deletion from `dispatch`.
- Do not edit `README.md`'s mermaid diagram (14-33) or `## The daily loop` (409-417), or
  `docs/runbook.md` §0 (11-38) or §19 (1144-1170) — `story-04-land-teardown` owns those four.
- No `backlog/SCHEMA.md` change: `plan-workflow-01-gate` story-03 documents the `- epic:` line.
- No new dependency and no new environment variable.

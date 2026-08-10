---
id: story-04-land-teardown
title: Add `openbuilder land` to merge an approved PR and delete its branches
size: M
depends_on:
  - story-02-dispatch-gate
files:
  - local/bin/openbuilder
  - docs/runbook.md
  - README.md
acceptance:
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
  - "`land` on a pull request without `openbuilder:approved` exits 1, prints `is not labelled openbuilder:approved`, and makes no merge call"
  - "typing anything other than `land <slug>` at the confirmation exits 1 with `confirmation did not match` and nothing is merged"
  - "after a successful land in a sandbox, `openbuilder/work/<slug>` and `openbuilder/plan/<slug>` are absent from `gh api repos/<repo>/git/matching-refs/heads/openbuilder/`"
  - "when `state.json.slugs` still lists a slug with no merged `openbuilder/work/<that-slug>` pull request — dispatched-but-unlanded or never dispatched — the design branch survives and stdout contains `openbuilder dispatch <repo> <that-slug>`"
  - "when every other slug in `state.json.slugs` has a merged work-branch PR, the design branch is deleted"
---

## Context

Nothing in the system tears down. Two finished, merged slugs still have their plan branches on
`origin`, evaluated by the poller and the waker on every pass, with a worktree and a state directory
each on the instance (PRD §2, third bullet). `cmd_approve` currently ends by printing
`gh pr merge <pr> --repo <repo> --squash` (`local/bin/openbuilder:812`), and that is the whole of the
merge story.

RFC §3.7 gives `openbuilder land <owner/repo> <pr>` seven steps: refuse an unapproved pull request;
resolve the slug and the epic and require a typed confirmation; `gh pr merge --squash
--delete-branch`; delete the plan branch, and the design branch only when no other slug of the epic
is unlanded; over SSM remove the instance's worktree and `state/<key>/`; print the remaining slugs
with the dispatch command for the next one. The bot never merges — `land` is human-invoked and refuses
to guess a pull request, a property the reviewer's frozen-names rubric checks
(`agent/local/agents/reviewer.md:102`).

Facts you need, all read out of the tree:

- On-disk keys on the instance: `ob_src_dir` is `/opt/openbuilder/src/<owner>__<repo>`
  (`runner/bin/ob-common.sh:415-417`), `ob_worktree_dir` is
  `/opt/openbuilder/work/<owner>__<repo>__<slug>` (`ob-common.sh:420-423`) and `ob_state_dir` is
  `/opt/openbuilder/state/<owner>__<repo>__<slug>` (`ob-common.sh:407-413`). `OB_REMOTE_HOME` in the
  CLI is already `/opt/openbuilder` (`openbuilder:54`) and `OB_REMOTE_USER` is `openbuilder`
  (`openbuilder:56`).
- `ob_ssm_exec <script> [timeout]` (`openbuilder:276-338`) is the CLI's SSM path: it hands the script
  to AWS-RunShellScript, polls to a terminal state, splits stdout and stderr and returns the remote
  exit code. `cmd_cost` (`openbuilder:1101-1122`) and `cmd_logs` show the established style — build
  the script in a `ob_*_script()` function with a heredoc and escape every `$` that must survive to
  the remote shell.
- AWS-RunShellScript runs `/bin/sh`, which is **dash** on Ubuntu, so bashisms fail with
  `Bad substitution` (`local/bin/obrun:4-6`). The payload must be strictly POSIX: no `[[`, no arrays,
  no `${var//x/y}`, no `local`.
- Verified on this laptop, 2026-08-09, against `artemkurylo/openbuilder`:
  `gh api "repos/<repo>/contents/<path>?ref=<branch>" -H 'Accept: application/vnd.github.raw'` prints
  the file body verbatim. `land` therefore needs no clone and makes no local `git` call.
- `ob_epic_of_plan` (added by `story-02-dispatch-gate`) reads `plan.md` on stdin and prints the epic.
  `ob_design_branch` and `ob_plan_branch` are one-line helpers (`openbuilder:524-525` plus
  `story-01-plan-launcher`).

Traps:

- Running `git` as root inside `/opt/openbuilder/src/...`, which the `openbuilder` user owns, trips
  git's `dubious ownership` refusal. The SSM script must run every `git` through
  `sudo -u openbuilder`. `rm -rf` of the state directory as root is fine.
- `ob_remote_as_user` (`openbuilder:341-344`) `exec`s a single binary path. It cannot run a
  multi-line script body, so do not try to wrap the teardown in it.
- Past the merge, `land` is not re-runnable: a second invocation refuses on the `OPEN` precondition.
  Everything that can refuse must refuse **before** step 3.
- **The design branch is the only copy of an epic's approved artifacts.** The planner writes the
  cards, `plan.md`, PRD and RFC onto `openbuilder/design/<epic>`, and RFC §10 dispatches slugs one at
  a time, so most listed slugs have no plan branch yet. "No plan ref" therefore says nothing about
  whether a slug landed — it is equally true of a never-dispatched slug. `land` must never use ref
  absence as the landed signal; it must find positive evidence of landing (a merged work-branch PR)
  and keep the design branch for every slug that lacks it.
- `plan-workflow-00-host` adds the `ob_gh` wrapper. Every `gh` call in this story goes through it.

## Change

### 1. `cmd_land <owner/repo> <pr>`

Add a new section comment and the function between `cmd_request_changes` (ends line 833) and the
`status` section comment at line 835-837.

1. `local usage="usage: $OB_PROG land <owner/repo> <pr>"`; `[[ $# -eq 2 ]] || ob_die "$usage"`;
   `ob_validate_repo "$repo"`; `ob_validate_pr "$pr"`; `ob_need gh aws jq`.
2. One `gh pr view` for `headRefName,labels,state,title`. A failed call →
   `ob_die "cannot read pull request #$pr in $repo"` (the same wording as line 751). Then two
   refusals, in this order:
   - not labelled `$OB_LABEL_PREFIX:approved`:
     ```
     ob_die "$repo#$pr is not labelled $OB_LABEL_PREFIX:approved; land never merges an unapproved pull request.
  Review it first:  $OB_PROG review --watch $repo $pr"
     ```
   - `state` is not `OPEN`:
     ```
     ob_die "$repo#$pr is $state, not OPEN; there is nothing to land"
     ```
3. Resolve the slug from the head branch. It must start with `$OB_BRANCH_PREFIX/work/`; otherwise
   ```
   ob_die "the head branch of $repo#$pr is '$head', not under $OB_BRANCH_PREFIX/work/; land only handles openbuilder pull requests"
   ```
   Strip the prefix, then `ob_validate_slug "$slug"`.
   `plan_branch=$(ob_plan_branch "$slug")`.
4. Resolve the epic from `plan.md` on the plan branch, read with the raw-content header. A failed call:
   ```
   ob_die "cannot read .openbuilder/backlog/$slug/plan.md on $plan_branch; land cannot tell which epic to clean up"
   ```
   Pipe the body through `ob_epic_of_plan`. Empty →
   ```
   ob_die ".openbuilder/backlog/$slug/plan.md on $plan_branch has no '- epic:' line; land cannot tell which epic to clean up"
   ```
   Then `ob_validate_slug "$epic"` and `design_branch=$(ob_design_branch "$epic")`.
5. Read `state.json` from `.openbuilder/epics/$epic/state.json` on `$design_branch`, same header. A
   failed call or unparseable JSON:
   ```
   ob_die "cannot read .openbuilder/epics/$epic/state.json on $design_branch; land will not delete branches it cannot account for"
   ```
   Extract `.slugs[]` into an array.
6. Show the plan and require a typed confirmation, **before any destructive call**. Print to stdout:
   the repo, `#<pr>` and its title, the head branch and the base branch, then a `will delete:` block
   listing `$head` (by `--delete-branch`), `$plan_branch`, and either `$design_branch` or
   `$design_branch (kept — epic <epic> has other unlanded slugs)`; then the two instance paths that
   will be removed. Then:
   ```
   printf 'type "land %s" to proceed: ' "$slug"
   read -r answer
   [[ $answer == "land $slug" ]] ||
     ob_die "confirmation did not match \"land $slug\"; nothing was merged and nothing was deleted"
   ```
   The confirmation string is `land <slug>` exactly — the slug is what makes it impossible to confirm
   the wrong pull request by muscle memory.
7. Merge: `ob_gh pr merge "$pr" --repo "$repo" --squash --delete-branch` or
   ```
   ob_die "gh pr merge $pr failed; nothing was deleted"
   ```
   Then `ob_info "merged $repo#$pr and deleted $head"`.
8. Delete the plan branch: `ob_gh api -X DELETE "repos/$repo/git/refs/heads/$plan_branch"`. On failure
   `ob_warn "could not delete $plan_branch (already gone?)"` and continue — the ref being absent is the
   desired end state either way.
9. Decide the design branch. A slug from `state.json.slugs` is *unlanded* until there is **positive
   evidence it landed**: a merged pull request whose head branch is exactly
   `openbuilder/work/<that-slug>`. Absence of a plan ref is NOT evidence — a slug that was never
   dispatched has no plan ref either, and its cards, `plan.md`, PRD and RFC live only on the design
   branch. So for every slug in `.slugs` other than the one being merged right now, check
   `ob_gh pr list --repo <repo> --head openbuilder/work/<slug> --state merged`, exact-match the head
   branch with `jq`, and treat the slug as unlanded when no merged PR matches. Compute the
   keep/delete decision once, before the merge, because nothing it reads changes during the command.
   - Any unlanded slug → keep the design branch and log
     `ob_info "keeping $design_branch — epic $epic has unlanded slugs"`.
   - None → `ob_gh api -X DELETE "repos/$repo/git/refs/heads/$design_branch"`, then
     `ob_info "deleted $design_branch — epic $epic has no unlanded slugs"`. On failure
     `ob_warn "could not delete $design_branch (already gone?)"`.
10. Prune the instance. `ob_ensure_running` first, then a new `ob_land_prune_script <repo> <slug>`
    beside `ob_cost_script` (line 1101) building a strictly POSIX script that sets
    `key=<owner>__<repo>__<slug>`, `src=$OB_REMOTE_HOME/src/<owner>__<repo>`,
    `wt=$OB_REMOTE_HOME/work/$key`, `st=$OB_REMOTE_HOME/state/$key`, then:
    - `sudo -u openbuilder git -C "$src" worktree remove --force "$wt"`, falling back to
      `rm -rf "$wt"` when that fails;
    - `sudo -u openbuilder git -C "$src" worktree prune`, failure ignored;
    - `sudo -u openbuilder git -C "$src" branch -D <work-branch>`, failure ignored — the remote branch
      is gone and the local one is dead weight;
    - `rm -rf "$st"`;
    - a final `printf 'pruned %s and %s\n' "$wt" "$st"`.
    Run it with `ob_ssm_exec "$(ob_land_prune_script …)"`, capture the code, print the output. On a
    non-zero code:
    ```
    ob_warn "instance cleanup failed (exit $rc); prune it by hand:
  $OB_PROG shell
  sudo -u $OB_REMOTE_USER git -C $OB_REMOTE_HOME/src/<owner>__<repo> worktree remove --force $OB_REMOTE_HOME/work/<key>
  sudo rm -rf $OB_REMOTE_HOME/state/<key>"
    ```
    and make `cmd_land` return **6**. The merge and the branch deletions already happened; exit 0 would
    claim a teardown that did not finish, and R8 requires the instance to keep nothing. Do not stop the
    instance — `ob-idle-stop` owns that.
11. Final report on stdout: `landed <repo>#<pr> :: <slug>` with one line per deleted branch. When step
    9 kept the design branch, print the unlanded slugs in `state.json.slugs` order, one dispatch
    command per line, with the slug substituted:
    ```
    epic <epic> still has unlanded slugs. Dispatch the next one:
      openbuilder dispatch <repo> <slug>
    ```

### 2. `main` and `ob_command_table`

Add `land) cmd_land "$@" ;;` to the `case` in `main`, immediately after the
`request-changes` line (line 1172). In `ob_command_table`, add after the `request-changes` line
(line 539):

```
  land <owner/repo> <pr>            merge an approved pull request and delete every branch it used
```

### 3. `docs/runbook.md`

- §19 quick reference (1144-1170): change the `Tell the instance to stop touching a PR` row's command
  to keep `openbuilder approve you/your-repo <pr>`, and add three rows —
  `Drive a PR to a verdict unattended` → `openbuilder review --watch you/your-repo <pr>`;
  `Merge and clean up` → `openbuilder land you/your-repo <pr>`;
  `Why is my plan branch doing nothing?` → `openbuilder status you/your-repo` (read the `UNAPPR`
  column).
- §0 (11-38) needs no change: its three commands are still correct. Do not touch it.
- Append a new section `## 20. Refusals from the laptop CLI`, after §19, as the last section of the
  file. Appended rather than inserted as a new §19 for the reason RFC §4.1 gives about renumbering a
  thing other documents point at. It is a table with columns `Refusal (grep this) | Cause | Fix`, one
  row per refusal this slug adds — every message named in `story-01-plan-launcher`,
  `story-02-dispatch-gate`, `story-03-review-watch` and this card — quoted verbatim from the source,
  not paraphrased. Follow it with a short `### Un-voiding an approval` subsection: an approval is void
  because the bytes changed, so the fix is always to commit the artifact and re-run
  `ob-gate record <epic> prd|rfc|backlog <slug>` from inside the clone; there is no flag that
  suppresses the check.

### 4. `README.md`

- The mermaid block (16-33): change node `A` to name `openbuilder plan` as the epic workflow session
  (intake → PRD → RFC → backlog, gated), node `G` to `openbuilder review --watch`, and node `K` from
  `Human: gh pr merge --squash` to
  `Human: openbuilder land<br/>merge, delete all three branches, prune the instance`. Leave nodes
  `B`-`F` and `H`-`N` alone.
- `### 13. Approve and merge` (395-407): retitle it `### 13. Approve and land`, replace the
  `gh pr merge` line with `openbuilder land you/your-repo 42`, and document the typed confirmation, the
  three branches it deletes and the instance prune. Keep the `**Only a human merges.**` paragraph.
- `## The daily loop` (409-417): four commands, updated — `plan <repo> <epic>`,
  `dispatch <repo> <slug>`, `review --watch <repo> <pr>`, `land <repo> <pr>` — with the comment on the
  `dispatch` line saying it refuses without a recorded backlog approval.

## Acceptance

- `shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.
- `local/bin/openbuilder help | grep -c 'land <owner/repo> <pr>'` prints `1`, and
  `local/bin/openbuilder land; echo $?` prints
  `openbuilder: usage: openbuilder land <owner/repo> <pr>` and `1`.
- `local/bin/openbuilder help | grep -c 'gh pr merge'` prints `0`.
- **Sandbox required** for everything below. Set up: `gh repo create <you>/ob-sandbox --private` with
  one commit; push `openbuilder/design/land-epic` carrying
  `.openbuilder/epics/land-epic/state.json` with `stage: dispatched` and
  `slugs: ["land-slug","other-slug"]`; push `openbuilder/plan/land-slug` from it with a
  `.openbuilder/backlog/land-slug/plan.md` whose second line is `- epic: land-epic`; push
  `openbuilder/work/land-slug` with one extra commit and open a pull request from it.
  1. **Unapproved refusal.** With no `openbuilder:approved` label,
     `local/bin/openbuilder land <you>/ob-sandbox <pr>; echo $?` prints
     `is not labelled openbuilder:approved` and `1`;
     `gh pr view <pr> --repo <you>/ob-sandbox --json state --jq .state` still prints `OPEN`.
  2. **Confirmation refusal.** `local/bin/openbuilder approve <you>/ob-sandbox <pr>`, then
     `printf 'yes\n' | local/bin/openbuilder land <you>/ob-sandbox <pr>; echo $?` prints
     `confirmation did not match "land land-slug"` and `1`; the pull request is still `OPEN`.
  3. **Epic with a slug left.** Push `openbuilder/plan/other-slug` from the design branch (no PR).
     Then `printf 'land land-slug\n' | local/bin/openbuilder land <you>/ob-sandbox <pr>` exits `0` or
     `6` (`6` when no instance is reachable, which is expected in a sandbox — assert the warning text
     names the two manual `sudo` commands), and afterwards:
     - `gh api repos/<you>/ob-sandbox/git/matching-refs/heads/openbuilder/ --jq '.[].ref'` contains
       `refs/heads/openbuilder/design/land-epic` and does not contain `openbuilder/plan/land-slug` or
       `openbuilder/work/land-slug`;
     - stdout contains `openbuilder dispatch <you>/ob-sandbox other-slug`.
  4. **Never-dispatched slug keeps the design branch.** Reuse the setup with
     `slugs: ["land-slug","only-slug"]`, but do NOT push `openbuilder/plan/only-slug` and do not open
     a PR for it. After a confirmed land of `land-slug`,
     `gh api repos/<you>/ob-sandbox/git/matching-refs/heads/openbuilder/ --jq '.[].ref'` still
     contains `refs/heads/openbuilder/design/land-epic`, and stdout contains
     `openbuilder dispatch <you>/ob-sandbox only-slug`.
  5. **Last slug of the epic.** Repeat the setup with `slugs: ["only-slug"]` and one pull request.
     After a confirmed land,
     `gh api repos/<you>/ob-sandbox/git/matching-refs/heads/openbuilder/ --jq length` prints `0` — all
     three branches gone.
  6. **Instance prune, once, against the real instance.** With
     `/opt/openbuilder/state/<you>__ob-sandbox__only-slug` created by hand
     (`openbuilder shell`, then `sudo -u openbuilder mkdir -p …`), a confirmed land exits `0` and
     `openbuilder shell` then `ls /opt/openbuilder/state | grep -c ob-sandbox` prints `0`.
  Clean up: `gh repo delete <you>/ob-sandbox --yes`, and on the instance
  `sudo rm -rf /opt/openbuilder/{work,state,src}/*ob-sandbox*` for anything the prune left behind.
- `docs/runbook.md` ends with `## 20. Refusals from the laptop CLI`, and every `Refusal (grep this)`
  cell in its table is found verbatim by
  `grep -F "<cell>" local/bin/openbuilder` — run this for every row; each must print at least one line.

## Out of scope

- **No drive-by refactor of `local/bin/openbuilder`.** It is 1189 lines. Add `cmd_land` and
  `ob_land_prune_script`, add two lines to `main` and `ob_command_table`, and touch nothing else in the
  file. No reordering, no renaming, no re-indentation, no extraction of a shared "resolve slug and
  epic" helper beyond calling `ob_epic_of_plan`, no conversion of an existing `gh` call site to
  `ob_gh`, and no change to `cmd_approve` — including the `gh pr merge` hint it prints at line 812,
  which `story-04` does **not** own.
- Do not use `local/bin/obrun`, do not modify it, and do not add a second SSM mechanism.
  `ob_ssm_exec` is the CLI's path.
- Do not stop the instance, change `ob-idle-stop`, or add an idle-timeout override. `land` leaves the
  instance running.
- No `--force`, `--yes`, `--no-confirm` or `--dry-run` flag on `land`. The typed confirmation is the
  whole safety mechanism; a flag that skips it defeats R8.
- No merge strategy other than `--squash --delete-branch`. No rebase, no merge commit, no auto-merge,
  no `--admin`.
- No branch protection, no release tagging, no changelog generation, no issue closing, no PR-body
  editing, no `git revert` path. Rolling back a merge is `docs/runbook.md` §14 and stays a human's job.
- No cleanup of the operator's local clone under `OPENBUILDER_WORKSPACE`. `land` makes no local `git`
  call at all.
- No change to `runner/bin/ob-common.sh`, `runner/bin/ob-poll`, `waker/**`, `agent/**` or
  `infra/**`. The instance-side path constants are read from those files, not edited.
- No new dependency and no new environment variable.
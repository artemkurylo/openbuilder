# Worklog — plan-workflow-01-gate

## Round 1 (2026-08-09)

Implemented all three stories; `local/bin/ob-gate` (mode 0755) is complete with
`init`, `stage`, `record`, `verify`, `show`; `backlog/SCHEMA.md` documents the
`- epic:` line. Three commits, all pushed to `openbuilder/work/plan-workflow-01-gate`.

### Decisions a future round must not re-derive

- **Live `state.json` has moved past the story cards.** The cards quote stage
  `backlog`, rfc blob `f6af7260918e938ede38864cdd28a4679709fb9d`, and an empty
  `approvals.backlog`. The live file on `openbuilder/plan/plan-workflow-01-gate`
  (and `openbuilder/design/plan-workflow`) now has `stage: dispatched`, rfc
  re-recorded as `e69f7c143dbf95dad51731228b69f0c0d98d2567` at
  `2026-08-09T18:40:31Z`, and a fully populated `approvals.backlog` for all six
  slugs. Consequences: story-01's live grep `^stage  *backlog$` and story-02's
  live expectation `verify plan-workflow --all` → exit 4 with `backlog ABSENT`
  can no longer hold. The script was exercised against the actual current live
  state instead: `show` prints `stage dispatched` plus all six backlog rows;
  `verify --all` exits 0 with all 8 targets intact (`prd intact ba6725f3…`,
  `rfc intact e69f7c14…`), writing nothing. PRD blob/date still match the cards.
- **The live epic is not in the work-branch worktree.** `.openbuilder/epics/`
  only exists on the plan/design branches. To run the read-only live-epic
  checks I materialized `epics/plan-workflow` + the six slug dirs from the plan
  branch via `git archive … | tar -x` and removed them afterwards; the tree is
  clean. `show`/`verify` wrote nothing (state.json hash unchanged before/after).
- **Deviation from the card's `commit_state`:** a pure pathspec commit
  (`git commit -- <path>`) cannot commit a brand-new file; `ob-gate init` failed
  with `error: pathspec … did not match any file(s) known to git` until
  `commit_state` staged the one path first (`git ls-files --error-unmatch -- <rel> ||
  git add -- <rel>`). All other acceptances then passed unchanged.
- **`jq` here is a shell builtin reporting `jaq 2.3.0`**, exactly the risk the
  card flagged (real jq 1.7 also exists at `/usr/bin/jq`; the builtin shadows
  it). Verified byte-identical pretty round-trip of the live `state.json` and
  identical assignment output, so the file stays byte-stable. No alias/fallback
  added, per the card.
- **shellcheck was absent** on this instance; downloaded v0.10.0 (arm64) to
  `/tmp/shellcheck-bin` and ran `make lint` with it on PATH. Repo lint passes.
  The repo has no test suite — verification is the acceptance exercises below.

### Verified

- Story-01 acceptance in a scratch repo with a local bare `origin` (push
  exercised for real): shellcheck 0, init/stage/show behavior, unknown-key
  survival (`notes`), idempotent stage (no empty-diff commit), no temp files.
- Story-02 acceptance in a scratch repo: prd/rfc/backlog record with correct
  blob + `Approves-<stage>: <sha>` trailers, verify 0/3/4 exit codes, refusals
  (uncommitted card, modified artifact, no cards), absent cases, usage errors.
- Story-03 greps: Three/Two counts, bullet order, awk literal, exactly one
  replaced line, 11 long lines unchanged, round-trip awk on plan.md prints
  `plan-workflow`.
## Round 1 — 2026-08-09T19:10:18Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.10781912064 USD
- story cards: 3

### Agent summary

## Summary
Implemented all three stories: `local/bin/ob-gate` (0755, shellcheck-clean) owns `.openbuilder/epics/<epic>/state.json` with `init`/`stage`/`show`/`record`/`verify` — every write a `jq` assignment preserving unknown keys, atomic `mktemp`+`mv` in the epic dir, one commit/push path with `Approves-<stage>: <sha>` trailers — and `backlog/SCHEMA.md` documents the `- epic:` line. Full acceptance exercises ran in throwaway repos with real local bare `origin`s (push exercised, nothing landed in this repo's history); live-epic `show`/`verify` were run read-only against the current plan-branch state (zero writes). The two live-epic acceptance greps reference a state snapshot that has since advanced — the live file is now `stage: dispatched` with a fully populated `approvals.backlog` (cards assumed `backlog`/empty), so story-01's `^stage  *backlog$` grep and story-02's expected `verify --all` → exit 4 cannot hold against reality; the script was verified against the actual current state instead (see worklog for the exact blobs).

## Stories
- story-01-gate-state-file: done — init/stage/show over atomic state.json; scratch acceptance fully green; live `show plan-workflow` correct against current state, writes nothing
- story-02-gate-record-verify: done — record/verify by blob sha with exit codes 0/3/4; scratch acceptance fully green; live `verify plan-workflow --all` → 0 with all 8 targets intact (card's expected 4/`backlog ABSENT` is stale)
- story-03-schema-epic-line: done — all six acceptance greps pass (Three/Two counts, bullet order, awk literal, exactly one replaced line, 11 long lines unchanged, round-trip awk prints `plan-workflow`)

## Verification
- `shellcheck -x -S warning local/bin/ob-gate` -> exit 0 (shellcheck 0.10.0 installed to /tmp/shellcheck-bin; the repo's `make lint` skips when absent, so acceptance required it)
- `make lint` -> exit 0, all 15 shell scripts including ob-gate
- story-01 scratch runner -> "ALL STORY-01 SCRATCH CHECKS PASSED" (help line, exit-2 paths, init fields, notes survival, stage commit subject, idempotence with no empty-diff commit, push reached origin, no temp files)
- story-02 scratch runner -> "ALL STORY-02 SCRATCH CHECKS PASSED" (blob equality, trailers `Approves-prd:`/`Approves-backlog:`, stage advance, files map excludes worklog.md, void/absent/refusal/usage paths, exit codes 0/1/3/4, no temp files)
- story-03 greps -> all six criteria as above; `git status --porcelain` -> empty (tree clean); repo has no test suite — verification is the exercised commands above
- 4 commits pushed to `openbuilder/work/plan-workflow-01-gate`

## Notes for the reviewer
- Acceptance drift (not a script bug): the live `state.json` on the plan/design branches advanced after card authoring — `stage: dispatched`, rfc re-recorded `e69f7c143d…` at 18:40:31Z, `approvals.backlog` populated for all six slugs. Story-01's `show` grep `^stage  *backlog$` and story-02's live `verify --all` → exit 4 + `backlog ABSENT` can no longer pass; verified against actual state instead. Full details in worklog.md.
- Deliberate deviation: `commit_state` stages the untracked `state.json` before the pathspec commit (a bare `git commit -- <path>` cannot commit a new file — observed failure quoted in worklog and in the learnings proposal).
- `jq` on this instance resolves to a shell builtin reporting `jaq 2.3.0`; verified byte-identical round-trip of the live pretty file and identical assignment output, so byte-stability holds. No alias/fallback added, per card.
- Worklog committed per round instructions; one learnings candidate appended to `learnings-proposed.md` (pathspec-commit trap).

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there, and nowhere else.

### N. Stage an untracked file before a pathspec commit
**Symptom** `error: pathspec '.openbuilder/epics/gate-smoke/state.json' did not match any file(s) known to git` — `git commit -- <path>` refuses to commit a brand-new file.
**Cause** `git commit -- <pathspec>` commits the working-tree content of paths git already knows; a file that was never added to the index is invisible to it, and the error says nothing about staging.
**Rule** When a helper or script commits exactly one path, stage that path first (`git ls-files --error-unmatch -- <path> || git add -- <path>`) before the pathspec commit, so the first commit of a new file behaves the same as every re-commit.
**Proven** 2026-08-09 in the ob-gate scratch-repo exercise: `ob-gate init` failed with exactly the quoted error on a fresh `state.json`, and passed unchanged once the one-path stage was added to the shared commit helper.


## Round 2 (2026-08-09) — review of PR #4

Addressed the CHANGES_REQUESTED review by @artemkurylo. Three commits, one per
feedback item.

### Decisions a future round must not re-derive

- **`write_state` refuses a failed pipeline instead of mv-ing garbage.** The
  reviewer reproduced `ob-gate stage demo rfc` zeroing a committed
  `state.json` when the middle `jq` stage failed: `pipefail` reports the
  failure only after the last pipeline element has run. Fix: before the `mv`,
  the staged temp file must be non-empty and parse as an object carrying
  `epic`, `stage`, `approvals`
  (`jq -e 'type == "object" and has("epic") and has("stage") and has("approvals")'`);
  on refusal `die 1` naming the temp path, stating `state.json` was left
  untouched, and removing the temp file **in `write_state` itself** — as a
  pipeline element it runs in a subshell, its `TMP_STATE` never reaches the
  parent, and the parent's `EXIT` trap cannot clean up. This also restores the
  documented exit-code contract: the reproduced jq parse-error run exited 5
  (jq's status via `pipefail`); refused writes now exit 1.
- **New acceptance criterion (round 2), requested by the reviewer:** with a
  stub `jq` on PATH that exits 1, `ob-gate stage <epic> rfc` must exit
  non-zero and `state.json` must be byte-identical to before — assert with
  `git diff --quiet HEAD -- <state path>`. The story cards live only on
  `openbuilder/plan/plan-workflow-01-gate`, which this round must not push to,
  so the criterion is recorded here; the next plan-branch edit should fold it
  into `story-01-gate-state-file.md`. Verified in the scratch repo exactly as
  stated: stub jq → exit 1, byte-identical state, no temp file left.
- **`commit_state` refuses a detached HEAD.** On a detached HEAD
  `rev-parse --abbrev-ref HEAD` prints the literal `HEAD`, so the push refspec
  would create `refs/heads/HEAD` on the remote. The check runs before staging
  or committing: `die "not on a branch; ob-gate must run on the epic's design
  branch" 1` — nothing committed, nothing pushed.
- **Empty-array expansions now match house style**
  `"${arr[@]+"${arr[@]}"}"` (`ob-implement:127`): the two
  `for k in "${kept[@]}"` loops in `record_backlog` and the
  `printf '%s\n' "${mapped[@]}"` coverage check in `verify_backlog_slug`.
- **The reviewer's "not a finding" stands:** `record backlog` leaving `stage`
  untouched and appending to `slugs[]` is correct and load-bearing; untouched.

### Verified

- Round-2 scratch runner, 39 checks, all PASS against the final tree: story-01
  core (help line, exit-2 paths, init fields, notes survival, idempotent
  stage), story-02 core (prd/rfc/backlog record blobs + trailers, files map
  without worklog.md, stage untouched by backlog, verify 0/3/4, refusals 1/2)
  and the new criteria: stub `jq` → exit 1 + byte-identical state +
  `git diff --quiet HEAD --` + no temp file; detached HEAD → exit 1 + refusal
  message + no `refs/heads/HEAD` on origin + no local commit.
- `shellcheck -x -S warning local/bin/ob-gate` → 0; `make lint` → 0.
- Live epic, read-only: `ob-gate verify plan-workflow --all` exits 3 on the
  work branch — `prd intact ba6725f3…`, `rfc intact e69f7c14…`, all six
  backlog slugs VOID ("missing since approval") because the plan cards do not
  exist in the work-branch working tree; `ob-gate show plan-workflow` prints
  the live state. state.json blob identical before/after (`15886a02e…`);
  nothing written. The epics were materialized from the plan branch
  (`git archive`) and removed afterwards; tree clean.

## Round 2 — 2026-08-09T20:02:55Z

Review-response round by `ob-respond` (attempt 2 of 6).

- action: respond to review
- pull request: #4
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.07369578496000001 USD

### Agent summary

All round-2 work complete and pushed. Final state: 4 commits on the work branch, tree clean.

## Summary
Addressed all four review items on PR #4: `write_state` now validates the staged document (non-empty, JSON object carrying `epic`/`stage`/`approvals`) before the `mv` and refuses with exit 1, removing its temp file itself since pipeline subshells never reach the parent's EXIT trap; `commit_state` refuses on a detached HEAD before staging anything; the two empty-array expansions now use the house idiom; the requested acceptance criterion is recorded in the worklog because the story cards live only on the plan branch, which this round must not push to. One focused commit per item, all pushed.

## Feedback
- `local/bin/ob-gate` (`write_state`): fixed — staged temp is checked for non-empty + parseable object with the maintained keys before `mv`; refusal `die 1` names the temp path and states `state.json` was left untouched; temp removed inside `write_state` (subshell, parent trap cannot fire). Exit-code contract restored: refused writes exit the documented 1, not jq's propagated status (was 5).
- `local/bin/ob-gate` (`commit_state`): fixed — `rev-parse --abbrev-ref HEAD` == `HEAD` → `die "not on a branch; ob-gate must run on the epic's design branch" 1`, before staging/committing, so no local commit and no `refs/heads/HEAD` on the remote.
- `local/bin/ob-gate` nits: fixed — `for k in "${kept[@]+"${kept[@]}"}"` (both loops) and `printf '%s\n' "${mapped[@]+"${mapped[@]}"}"`, matching `ob-implement:127`.
- Acceptance line: recorded verbatim in the round-2 worklog section (`git diff --quiet HEAD -- <state path>` after a stub-jq run) — the story cards exist only on `openbuilder/plan/plan-workflow-01-gate`, which hard rule 2 forbids pushing to; it should be folded into `story-01-gate-state-file.md` on the next plan-branch edit.
- "Not a finding" (backlog record leaves `stage` untouched, appends `slugs[]`): kept, untouched.

## Verification
- `/tmp/r2-runner.sh` (39 checks, scratch repo + local bare origin) -> `FAILURES=0`: story-01/story-02 core all pass; stub `jq` (exit 1) on `ob-gate stage gate-smoke rfc` -> exit 1 (not 5), stderr contains `state.json was left untouched`, `git diff --quiet HEAD -- state.json` and byte-compare both clean, no temp file; detached HEAD -> exit 1, refusal message, no `refs/heads/HEAD` on origin, no local commit.
- `shellcheck -x -S warning local/bin/ob-gate` -> exit 0; `make lint` -> exit 0.
- Live epic read-only (materialized from plan branch, removed after): `verify plan-workflow --all` -> exit 3 on this work branch — `prd intact ba6725f3…`, `rfc intact e69f7c14…`, six backlog slugs VOID "missing since approval" (plan cards absent from the work-branch tree — correct); state.json blob identical before/after (`15886a02e…`), nothing written.

## Still open
- none. (The acceptance-line location is the only judgment call: worklog instead of the plan-branch story card, per the no-push-to-plan-branch rule.)

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there, and nowhere else.

### N. The last element of a pipeline must validate and clean up for itself
**Symptom** `ob-gate stage demo rfc` zeroed a committed `state.json` when the middle `jq` stage failed: `pipefail` reported the failure only after the final element had already `mv`ed an empty temp file over the record.
**Cause** every pipeline element runs in a subshell, so a function at the end of a pipeline cannot share variables with the parent (its `TMP_STATE=` assignment never reaches the parent's `trap cleanup EXIT`) and the unconditional `cat | mv` it performs does not know the upstream stage failed.
**Rule** When a function can be the last element of a pipeline, treat its stdin as untrusted: validate the staged payload (non-empty, expected shape) before the atomic replace, refuse with the caller's own exit code, and remove its own temp file on the refusal path — the parent's trap will not run for it.
**Proven** 2026-08-09, review round 2 of the ob-gate PR: with a stub `jq` on PATH exiting 1, `ob-gate stage` exited `1` and `state.json` stayed byte-identical (`git diff --quiet HEAD --` green), where before the same failure truncated the file to 0 bytes; and `TMP_STATE=parent; echo x | bash -c 'TMP_STATE='; echo "$TMP_STATE"` prints `parent`, demonstrating the subshell isolation.


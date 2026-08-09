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
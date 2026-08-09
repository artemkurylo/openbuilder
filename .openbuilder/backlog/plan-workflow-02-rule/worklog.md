# Worklog — plan-workflow-02-rule

## Round 1 (2026-08-09)

Implemented all three stories: rule 4b in `runner/bin/ob-poll` (story-01) and
`waker/github.py:decide` (story-02), proven against the same seven live fixture
branches on `artemkurylo/openbuilder-fixture` with `diff` empty on the extracted
`slug reason` pairs; `docs/architecture.md` documents the rule (story-03). Three
commits, all on `openbuilder/work/plan-workflow-02-rule`: `20ef0c2` (poll),
`a4c1463` (waker), `debdeee` (docs).

### Decisions a future round must not re-derive

- **`gh api` prints a non-2xx response body to stdout and fails non-zero.**
  The card specified `gh_contents_raw` as `ob_gh api … 2>/dev/null` with "empty
  output means unreadable". Empirically, a 404 prints the JSON error document to
  **stdout** (`{"message":"Not Found",…}`), so "empty output" never happens for
  a missing file. Both poll helpers therefore capture stdout and the exit status
  and return empty output (rc 0) on any non-zero `gh` exit; callers still treat
  empty output as unreadable, which keeps the five reason strings byte-identical
  with the waker's `GitHubError → None`. Verified 2026-08-09: with the exit-status
  guard, `fx-no-state` declines `backlog-unapproved:no-state`; without it, the
  404 document parsed as a valid empty-state JSON and produced `stage=-`.
  This is the mechanism behind the proposed learnings entry.
- **The system `jq` is `jaq 2.3.0`**, which is jq-compatible for everything
  rule 4b uses (`-e`, `-r`, `.stage // empty`, `--arg`, `to_entries`), with one
  difference: iterating an empty object (`to_entries[]` over `{}`) errors with
  rc 5 instead of printing nothing. The `|| true` capture path makes both
  outcomes an empty `recorded_entries`, so `no-approval` is still correct. Do
  not "fix" this by removing `|| true`.
- **Known parity nuance, both sides correct per their cards.** A `state.json`
  that is valid JSON but not an object (e.g. an array) yields `stage=-` from
  `ob-poll` (`jq -e .` accepts any valid JSON) but `no-state` from the waker
  (`json.loads` result is not a dict). Both decline; only the reason string
  differs, and `ob-gate` (slug 01) can never write such a file. Left as is;
  tightening parity here was out of scope and the fixture does not exercise it.
- **Fixture bookkeeping.** The seed script `/tmp/ob4b/seed.sh` and the sandbox
  env file lived under `/tmp` and are deleted (story-02 Step 5); the PEM was
  written under `umask 077` to `/tmp/ob4b/app.pem`, never appeared in a command
  argument, and was removed. All seven fixture branches are deleted;
  `matching-refs …/openbuilder/plan/` returns length 0; the sandbox repository
  `artemkurylo/openbuilder-fixture` itself is left in place for the next slug.
- **Harness quirk, session-local:** this agent shell's `grep` is the pi-uu-grep
  builtin (Rust regex), where `^| 4b |` matches every line (alternation/anchors
  differ from GNU BRE). The acceptance greps were re-run against `/usr/bin/grep`
  (GNU 3.11), which is what the instance has; results are identical under the
  intended GNU semantics. No repo change needed.

### Deliberate deviations from the cards

- `gh_contents_raw` / `backlog_listing` check the `gh` exit status and return
  empty output on failure (see first bullet above) instead of relying on gh
  printing nothing to stdout. Contract unchanged: callers treat empty output as
  unreadable, read failures are not distinguished from absent files.
- Story-02's `waker/github.py` verification initially failed on all approved
  branches (`fx-approved` → `no-approval`) because the approvals lookup used
  `approvals[slug]` instead of `approvals["backlog"][slug]`. Caught by the live
  parity diff, fixed, re-run. The parity diff is the point of the slug; it works.

### Left undone

- Nothing. Definition of done met: three commits pushed-shaped (not pushed yet —
  wrapper pushes), worktree clean, fixture repo has zero labels/issues/PRs/refs.
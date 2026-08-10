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
## Round 1 — 2026-08-09T21:42:53Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.1289235584 USD
- story cards: 3

### Agent summary

## Summary
Implemented rule 4b (the backlog approval gate) in both halves of the rule table: `runner/bin/ob-poll` now declines an unapproved plan branch with `action=skip` (no attempt, label, comment, or log line) between rules 4 and 5, and `waker/github.py:decide` returns the identical verdict (`rule=4b`, not actionable), proven by running both implementations against the same seven live fixture branches and diffing the extracted `slug reason` pairs to empty. `docs/architecture.md` documents the rule in the rule table, the parity table, and a new subsection. No side effects from any pass: zero labels/issues/PRs on the fixture repo, nothing written to the operational log, fixtures torn down afterwards.

## Stories
- story-01-ob-poll-rule-4b: done — `shellcheck` clean; six fixture slugs declined with the exact six reason strings, `fx-approved` reaches rule 5, `ACTIONABLE=1`; zero labels/issues/PRs, empty state dirs, log mtime unchanged.
- story-02-waker-rule-4b: done — `py_compile` clean; `decide` returns `rule=4b actionable=False` for the six unapproved slugs and `rule=5 actionable=True` for `fx-approved` only; `diff poll.fields waker.fields` empty; fixture branches deleted (`length` → 0).
- story-03-architecture-rule-4b: done — two `| 4b |` rows, headings in order, sentence updated, all five reason tokens in all three files, numstat deleted-line count = 1.

## Verification
- `shellcheck -x -S warning runner/bin/ob-poll` -> exit 0, no output
- `python3 -m py_compile waker/github.py waker/handler.py` -> exit 0, `__pycache__` removed
- worktree `ob-poll --dry-run` vs `waker decide` on 7 fixture branches -> 6 identical `slug reason` pairs, `diff` exit 0, `ACTIONABLE=1` poll / 1 `actionable=True` waker
- story-03 checks: `grep -c '^| 4b |'` -> 2; numstat `cut -f2` -> 1; diff shows only the rewritten line-151 sentence
- `git status --porcelain` -> clean; 4 commits pushed to `openbuilder/work/plan-workflow-02-rule`

## Notes for the reviewer
- **One implementation deviation from the cards, mechanism not contract:** `gh api` prints non-2xx response bodies to stdout (observed: a 404 printed `{"message":"Not Found",...}` to stdout, exit non-zero), so the poll's `gh_contents_raw`/`backlog_listing` key off the `gh` exit status and return empty output on failure, instead of relying on empty stdout. The five reason strings are unaffected and byte-identical to the waker's. Documented in `worklog.md`; also proposed as a `LEARNINGS.md` candidate in `learnings-proposed.md`.
- Known parity nuance (both sides per-card, not exercised by fixtures): a `state.json` that is valid JSON but not an object yields `stage=-` from the poll and `no-state` from the waker. `ob-gate` cannot produce such a file; left as-is.
- The waker's initial run was caught by the parity diff (`approvals[slug]` instead of `approvals["backlog"][slug]`); fixed and re-verified.
- Fixture PEM was written to `/tmp/ob4b/app.pem` under `umask 077` and removed; never appeared in a command argument. Sandbox repo `artemkurylo/openbuilder-fixture` left in place for the next slug.

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there, and nowhere else.

### When a command tool reports failure, read the exit status, not the stdout
**Symptom** `gh api -H "Accept: application/vnd.github.raw" "repos/…/contents/…?ref=…"` on a missing file printed `{"message":"Not Found","documentation_url":"…","status":"404"}` to **stdout** (a second copy went to stderr as `gh: Not Found (HTTP 404)`), and its `2>/dev/null` wrapper therefore captured a non-empty "body" for a file that does not exist — a rule-4b poll pass then reported `reason=backlog-unapproved:stage=-` instead of `:no-state` for the no-state fixture branch.
**Cause** `gh api` (CLI v2) writes the response body of a non-2xx to stdout regardless of status, so "empty output" never happens for a 404; only the non-zero exit status distinguishes a missing file from a real body.
**Rule** When a helper's contract is "empty output means unreadable", implement it by capturing stdout together with the exit code and returning empty on any non-zero exit — never by discarding stderr and hoping the tool prints nothing to stdout. Same for any CLI whose error document could come back on stdout.
**Proven** 2026-08-09, rule-4b round: fixture branch `fx-no-state` (no `state.json` committed) declined `no-state` only after the `ob_gh` exit status was checked; before the fix the 404 JSON parsed as an empty-state document. The waker half (`waker/github.py`) gets the same outcome from `GitHubError`, so poll and waker agree.


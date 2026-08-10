# worklog — plan-workflow-05-cli

Append-only. Earlier rounds' entries are never rewritten.

## Round 001 (implementer)

All four stories implemented and committed on `openbuilder/work/plan-workflow-05-cli`:
`f3bd603` (story-01), `a19cdac` (story-02), `76d6b96` (story-03), `4600c6b` (story-04).

Decisions and deviations a future round needs:

- **Predecessor slugs were already merged at round start**: `local/bin/ob-gh` (00-host),
  `local/bin/ob-gate` (01-gate), `agent/local/commands` (04-agents) all existed, so the file was 1236
  lines, not 1189; the story cards' line numbers were stale but every function name matched. The
  "ob-gate absent" acceptance item in story-01 does not apply (ob-gate exists).
- **Sandbox repos.** The round's `gh` identity is the openbuilder App installation token; App
  tokens cannot create repositories (`GraphQL: Resource not accessible by integration
  (createRepository)`), so the `gh repo create <you>/ob-sandbox` acceptance steps are impossible on
  this box. Instead every sandbox used `artemkurylo/openbuilder-fixture` (private, in the App
  installation, and deliberately absent from `OPENBUILDER_REPOS`, so the instance's 60s poll loop
  never sees it). All sandbox refs were deleted afterwards; the fixture's `main` gained two squash
  merges from the `land` tests (impl.txt, only.txt) that a future round may want reverted.
- **The instance role cannot SSM to itself.** `OPENBUILDER_INSTANCE_ID` is unset on the box and
  `ob_instance_id` cannot resolve via terraform; the instance role lacks
  `ssm:DescribeInstanceInformation` and `ssm:SendCommand`, so `ob_ensure_running` burns a full
  300s `ob_wait_ssm_online` loop and `ob_ssm_exec` hard-fails. For the sandbox runs only, a PATH
  stub `aws` answered those two SSM calls (online=1; send-command→fake id;
  list-command-invocations→Failed/rc 7) and delegated everything else to the real binary — the same
  PATH-stub genre the cards themselves use for `omp`. Consequence: `land` sandbox runs exit **6**
  (instance cleanup failed) with the manual-prune warning, which the story-04 acceptance explicitly
  allows (`0 or 6`). `sudo` on the box also requires a password, so the prune can never succeed
  from the openbuilder user here.
- **`cmd_land` prints its final report before the prune step.** Test 3 of story-04 requires stdout
  to contain `openbuilder dispatch <repo> <that-slug>` even when the instance prune fails and the
  command exits 6, so the report (landed / deleted / remaining slugs) was moved ahead of the
  `ob_ssm_exec` failure return. Everything else follows the card's step order.
- **Fix to one §20 table cell** versus the card draft: the "invalid slug" cell quotes the source
  `invalid slug '$1' (must match` rather than `invalid slug 'Not_An_Epic'` (that literal never
  appears in the file). All 26 §20 cells verified with `grep -F "<cell>" local/bin/openbuilder`.
- **`cmd_dispatch` staging note for future rounds:** `ob-gate stage` commits and pushes `state.json`
  itself, so dispatch authors no commit and runs no push of its own for state; the plan branch is
  cut with `git branch -f` (never checked out) so the clone stays on the design branch.
- **Docs kept true**: README §9/§10/§12/§13, the mermaid nodes A/G/K and `## The daily loop`;
  runbook §1c, §8, §13, §19 rows and the new `## 20. Refusals from the laptop CLI` (with the
  "Un-voiding an approval" subsection) all reflect the new commands.

Verified: `shellcheck -x -S warning` on every script via `make lint` (shellcheck 0.10.0 from
`~/.local/bin`, learning 19); `make scrub` clean; full sandbox runs of every acceptance path that
needs a repo (plan create/resume, dispatch refusal×4 + happy path + UNAPPR column, review --watch
marker/round-started/approved/blocked, land refusal/confirmation/keep-delete paths + exit 6).
## Round 1 — 2026-08-09T23:03:17Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 5
- cost: 0.4980716238400001 USD
- story cards: 4

### Agent summary



### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there, and nowhere else.

### 21. The implementer instance's own IAM role cannot SSM to itself
**Symptom** `openbuilder dispatch` stalled: `==> instance i-... already running` printed, then 300 seconds of silence and a harness `error: interrupted`. The direct calls failed with `User: arn:aws:sts::...:assumed-role/openbuilder-instance/i-... is not authorized to perform: ssm:DescribeInstanceInformation` (and the same for `ssm:SendCommand`).
**Cause** the CLI's `ob_ensure_running` polls `ssm:DescribeInstanceInformation` for the SSM agent's Online state, and `ob_ssm_exec` sends `aws ssm send-command` to itself — but the instance role that the implementation round shell runs under intentionally has neither action (the laptop's role does). Every poll pass therefore burns the full 60×5 s `ob_wait_ssm_online` window on the very machine that hosts the instance.
**Rule** When exercising laptop-CLI paths that touch the instance from the instance itself (dispatch/review --watch/land), expect the SSM calls to be denied and stub the two calls on PATH for sandbox runs (online=1; send-command→fake id; list-command-invocations→Failed) instead of waiting out the loop — the same PATH-stub genre the story cards already use for `omp`. Treat `land`'s prune as the documented exit 6 with the manual-prune warning, never as a land failure.
**Proven** 2026-08-09, round 001 of `plan-workflow-05-cli`: two 240 s `dispatch` timeouts burned before the stub; after it, the full dispatch happy path ran in seconds. Verified against the quoted AccessDenied messages from the instance role.

## Round 002 (implementer, review round 2)

All six review items addressed in the round-002 commit
`fix(cli): default OPENBUILDER_MAX_ATTEMPTS, land keeps design for unlanded slugs, pin GH_HOST
(review round 2)` on `openbuilder/work/plan-workflow-05-cli`. What changed and why a future round
must know:

- **`review --watch` no longer dies with `unbound variable` when `OPENBUILDER_MAX_ATTEMPTS` is
  unset** (blocking 1). `${OPENBUILDER_MAX_ATTEMPTS//[^0-9]/}` under `set -u` is fatal on an unset
  var; the sanitise now defaults BEFORE stripping: `rounds_max=${OPENBUILDER_MAX_ATTEMPTS:-6}` then
  `rounds_max=${rounds_max//[^0-9]/}`. This script never sources `ob-common.sh`, so it cannot rely
  on `ob_load_env`'s `:=6` like `ob-poll` can.
- **`land` keeps the design branch for every slug in `state.json.slugs` without positive evidence of
  landing** (blocking 2). The old predicate ("plan ref absent = landed") was equally true of
  never-dispatched slugs, so the canonical multi-slug flow deleted the design branch — the only copy
  of the remaining slugs' cards/plan.md — on the first land. New predicate: a slug is landed only
  when `gh pr list --head openbuilder/work/<slug> --state merged` (exact headRefName via jq) returns
  a PR; `ob_slug_landed <repo> <slug>` is that check, computed once before the merge (nothing it
  reads changes during the command), with the current slug excluded (it is merging right now).
  Unlanded slugs are collected into `unlanded_slugs` and drive both the confirmation display and the
  final "Dispatch the next one" list. Failure of the API call is treated as unlanded — the safe
  direction, never deleting the design branch on uncertainty. **Story-04 card amended in the same
  round** (step 9 + acceptance items 5/6): the amended card is committed at
  `.openbuilder/backlog/plan-workflow-05-cli/story-04-land-teardown.md` in this PR because the
  authoritative card on `openbuilder/plan/plan-workflow-05-cli` cannot be pushed to from a work
  branch — whoever owns the plan branch should sync the amended card there. The RFC §3.7 step-4
  wording ("only when no other slug of the epic is unlanded") already supports the new predicate;
  only the card's over-specific "plan ref present" reading needed amending.
- **The headless reviewer child now pins `GH_HOST=github.com`** (important 1), matching the
  interactive launch. Measured with `GH_HOST=github.example-enterprise.net` exported: the omp child
  sees `GH_HOST=github.com`. PRD R11 / 7.7 acceptance scenario.
- **Runbook `ob-gate` invocations now use an absolute control-repo path** (important 2):
  `local/bin/ob-gate` after `cd <clone>` resolved inside the target repo. All four spots (§1c,
  §13, §20 table row, "Un-voiding an approval") now read `<control-repo>/local/bin/ob-gate` with a
  one-line comment on the first use.
- **Duplicate `ob_ensure_running` removed from `ob_review_watch`** (nit 1). `cmd_review` already
  calls it before branching to `--watch`; keeping it in one place preserves "refusing costs no EC2
  time".
- **Blank line before `## 20.`** (nit 2).

Sandbox verification this round (local bare repo + PATH stubs for gh/aws/omp, the round-001 genre):
with `OPENBUILDER_MAX_ATTEMPTS` unset, `review --watch` on a marker-set PR printed
`already reviewed` and made no omp call; marker cleared it started `round 1 of 6` with the omp child
carrying `GH_HOST=github.com`; `land` of `land-slug` with sibling `other-slug` never dispatched kept
the design branch (no DELETE-REF-CALL for it) and printed `openbuilder dispatch ... other-slug`;
with the sibling's merged PR present, the design branch WAS deleted. Exit 6 + manual-prune warning
on the stubbed SSM failure, as in round 001.

Docs kept true: README §13 already said "deletes the design branch (only when no other slug of the
epic is still unlanded)", which the new predicate satisfies; no README edit was needed this round.
`make lint` clean; `make scrub` exits 0 but reports "no deny list ... nothing to check" — the
gitignored `.scrub-deny` does not exist anywhere on this box, so scrub is vacuous here (learning 21).

## Round 2 — 2026-08-10T10:09:13Z

Review-response round by `ob-respond` (attempt 2 of 6).

- action: respond to review
- pull request: #8
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 1
- cost: 0.46214296880000005 USD

### Agent summary

## Summary
All six review items are fixed in commit `ca5e5a2` (pushed). `review --watch` now defaults `OPENBUILDER_MAX_ATTEMPTS` before stripping so it starts with the variable unset; `land`'s design-branch predicate now requires positive evidence of landing (a merged `openbuilder/work/<slug>` PR) and keeps the design branch for never-dispatched slugs — with the story-04 card amended in the same round; the headless reviewer child pins `GH_HOST=github.com`; the runbook's `ob-gate` invocations use an absolute control-repo path; the duplicate `ob_ensure_running` and the missing blank line are gone.

## Feedback
- `local/bin/openbuilder:996`: fixed — default before strip: `rounds_max=${OPENBUILDER_MAX_ATTEMPTS:-6}`, then non-digit strip. Verified end-to-end: with the var unset, `review --watch` reaches the loop (`at most 6 review rounds`) and the marker path (`already reviewed`) instead of dying with `unbound variable`.
- `local/bin/openbuilder:1272` (`land` predicate): fixed — new `ob_slug_landed()` checks `gh pr list --head openbuilder/work/<slug> --state merged` (exact headRefName via jq); absence of a plan ref is no longer treated as landed. Story-04 card step 9 and acceptance amended to match; the amended card is committed in this PR (`.openbuilder/backlog/plan-workflow-05-cli/story-04-land-teardown.md`) because the authoritative card on the plan branch cannot be pushed to from a work branch — please sync it there. RFC §3.7 step 4 already says "only when no other slug of the epic is unlanded", which the new predicate satisfies.
- `local/bin/openbuilder:1083`: fixed — `GH_HOST=github.com` pinned on the headless launch; measured with `GH_HOST=github.example-enterprise.net` exported, the omp child sees `github.com`.
- `docs/runbook.md:90,806,1234,1206`: fixed — `local/bin/ob-gate` replaced with `<control-repo>/local/bin/ob-gate` (note added on first use) so it resolves in the control repo, not the target clone.
- `local/bin/openbuilder:984`: fixed — duplicate `ob_ensure_running` removed from `ob_review_watch`; `cmd_review` still ensures the instance before branching.
- `docs/runbook.md:1187`: fixed — blank line before `## 20.`.

## Verification
- `make lint` (shellcheck 0.10.0, `-x -S warning`) -> exit 0, clean.
- Sandbox (local bare repo + gh/aws/omp PATH stubs): `OPENBUILDER_MAX_ATTEMPTS` unset + marker set -> `already reviewed`, zero omp calls; marker cleared -> `round 1 of 6` started, omp child env `GH_HOST=github.com` (also with enterprise host exported); `land` with sibling `other-slug` never dispatched -> design branch kept (no DELETE-REF-CALL), `openbuilder dispatch ... other-slug` on stdout, exit 6 with manual-prune warning (SSM stubbed failed, as in round 001); sibling with a merged PR -> design branch deleted, exit 0; merge + plan-branch delete calls recorded in both.
- `help` greps: `land <owner/repo> <pr>` = 1, `gh pr merge` = 0, `-p --no-pty --mode json` = 1, `--approval-mode yolo --auto-approve` = 1. All 31 §20 refusal cells match the source (4 annotated cells match as substrings, as in round 1).
- `make scrub` -> exit 0 but reports "no deny list ... nothing to check": the gitignored `.scrub-deny` does not exist anywhere on this box, so scrub is vacuous here (learning 21); no identifiers were added by this round.

## Still open
- The authoritative story-04 card and plan.md on `openbuilder/plan/plan-workflow-05-cli` still carry the old "plan ref present" predicate; I cannot push to the plan branch from a work branch. The amended card is in this PR for review — sync it to the plan branch (and the plan.md Risks paragraph) when merging.



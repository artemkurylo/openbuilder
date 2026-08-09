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


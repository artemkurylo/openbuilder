# feat(cli): auto-merge an approved pull request under seven checked conditions

- epic: plan-workflow

## Goal

`openbuilder review --watch --auto-merge` merges a pull request the reviewer approved, and only
when all seven of R12's conditions hold — checked cheapest-first, each refusal naming its condition
and merging nothing. The merge is recorded by GitHub as `openbuilder-bot`, the repository's own lint
and scrub run on the **merge result** in a scratch worktree that is always removed, the §3.7 teardown
runs afterwards, and the command then stops instead of chaining to the next slug. Enabling it is
itself a gate: `ob-gate record <epic> automerge`. Implements **R8**'s second authorization form and
**R12** of `.openbuilder/epics/plan-workflow/prd.md`, per §3.8 (`3.8.1`–`3.8.4`, including
`3.8.3.1`) of `.openbuilder/epics/plan-workflow/rfc.md`.

## Why now

Waiting for a human at every merge is the loop's real bottleneck: an epic of six slugs stalls six
times, each time for as long as it takes someone to look (PRD R12). Everything the merge decision
needs already exists after slug 05 — the verdict, the label, the approval record, the teardown — and
none of it is joined up.

The slug also carries a defect found while writing it, on 2026-08-09, in code slug 01 already
shipped. `ob-gate record <epic> prd` and `record <epic> rfc` set `.stage` **unconditionally**
(`local/bin/ob-gate:242-248`), so re-approving an artifact after dispatch rewinds the pointer
`dispatched -> rfc` or `-> backlog`. Plan branches already pushed carry their own snapshot of
`state.json` and are unaffected, but a plan branch cut while the pointer is rewound carries
`stage=backlog`, and rule 4b (RFC §4.2 step 2) then declines that slug **forever** with
`reason=backlog-unapproved` — silently, because a decline is `action=skip` with no label and no
comment (RFC §4.3). One re-approval, one slug that never runs and never says why. It is fixed here
because this is the slug that adds the fourth `record` target and therefore already owns
`record`'s stage handling.

## Approach

Five stories: two small ones in `local/bin/ob-gate` that make the authorization recordable and stop
the pointer rewinding, two in `local/bin/openbuilder` split on the line between *checking* and
*merging*, and one that repairs every document R12 makes false — the reviewer rubric, the review
skill, the workflow skill's Stage 7 and `docs/workflow.md`. That last story grew from S to M when
`plan-workflow-04-agents` landed two more files claiming `land` is the only way anything merges.

**Why the merge-result check is its own story and its own subcommand.** RFC §3.8.2 conditions 4, 5
and 6 need a scratch worktree, a trial merge, two `make` targets and an unconditional teardown; they
make no GitHub mutation, need no token, and answer a question a human asks independently — "will
this pull request break `main`?". Conditions 1, 2, 3 and 7 are four cheap reads plus the merge, the
App token, the teardown and the audit comment. Cutting between them gives two independently
verifiable stories with no stub in either: `story-03` ships `openbuilder merge-check <repo> <pr>`,
which is complete and useful on its own and is exactly how PRD success criterion 8's hardest case is
reproduced by hand; `story-04` consumes it. Cutting the other way — "the read-only conditions" then
"the merge" — would make `story-03` a command that decides to merge and then does not, which is a
placeholder, not a story.

The contract between them, fixed here so neither story has to guess:

```
ob_merge_check <owner/repo> <pr>
  stdout: one line per condition, in order, exactly
            cond=<4|5|6> result=<pass|fail> detail=<text>
          where detail on a failure is the RFC §3.8.2 refusal string verbatim
  return: 0 when 4, 5 and 6 all pass; 1 at the first failure (no further lines)
  effect: the scratch worktree is removed before every return, and on INT/TERM
```

`story-04` captures those lines, folds them into the audit comment, and turns a non-zero return into
`auto-merge refused (condition <n>): <detail>` and exit 7.

**Both merge-result checks pass vacuously by default, and the story says so three times.** RFC
§3.8.3.1 is the measured version: in a scratch worktree `make scrub` exits **0** printing
`ob-scrub-check: no deny list at <wt>/.scrub-deny; nothing to check.`, because the deny list is
gitignored on purpose and therefore absent from every worktree on every machine, always; and
`make lint` exits **0** printing `shellcheck not installed — skipping lint.` when the linter is
absent (`Makefile:80-84`, LEARNINGS 19). Reproduced independently while writing this backlog, in a
worktree of this repo. So `story-03` requires the tooling to be **present** before it will accept a
result, exports `OPENBUILDER_SCRUB_DENY` at an absolute path outside the worktree, and asserts the
**output** of each check rather than its exit status (LEARNINGS 18 and 19 arriving together).

**Every output assertion uses `grep -F`.** `ob-scrub-check` prints `ob-scrub-check: clean
(worktree).`; `grep -q 'clean (worktree)'` matches under a basic-regex grep and **silently fails**
under an extended-regex one — measured both ways on this laptop, `grep -c` printing `0` for the bare
pattern and `1` for `-F`. A vacuous-pass detector that itself fails to match is worse than no
detector: it refuses a good merge while looking like the gate working.

**The stage fix is advance-only, and `ob-gate stage` keeps its freedom.** `STAGES` is already an
ordered array (`ob-gate:17`). `record` moves the pointer to the stage that follows the artifact it
recorded **only when that stage is later than the current one**, and otherwise leaves it untouched
and says so on stderr. `ob-gate stage <epic> <stage>` is the manual override and is unchanged — a
human who wants to go backwards has one obvious way to do it.

**`record automerge` records no blob sha.** Every other `record` target hashes bytes a human read;
this one authorizes a *policy*, and there is nothing to hash. That is also why `verify` must not
grow an `automerge` case: there is no artifact to compare it against, so it can never be voided, and
`verify --all` must keep ignoring it. The authorization is already present, written by hand in this
session, in `.openbuilder/epics/plan-workflow/state.json` under `approvals.automerge` with `at`, `by`
and a `note`; the new code reads that shape unchanged and preserves unknown keys instead of
migrating it.

**Decisions made on the implementer's behalf** — each is a coin flip the RFC does not settle, and
each is a place a human should say no now rather than at review time:

1. **`openbuilder merge-check` is a new public subcommand** the RFC does not name. It is what makes
   `story-03` a story rather than a stub, and what makes conditions 4–6 reproducible by hand.
2. **Condition 2's counts come from the reviewer's own NDJSON transcript**, the round file
   `--watch` already writes at `$OB_CACHE_DIR/review/<owner>__<repo>__<pr>.round-NN.ndjson`
   (`plan-workflow-05-cli` story-03). It is the only artifact that carries `severity` mechanically:
   the `reviewer` agent's structured output has it (`agent/local/agents/reviewer.md:35-38`) and the
   posted pull-request comments do not. The extraction is shape-agnostic and was run against two
   plausible envelopes while writing this backlog. No transcript, or no verdict object in it, is a
   **refusal**, never a pass.
3. **`state.json` is read from the design branch**, not the plan branch, for condition 1. The plan
   branch's copy is the dispatch-time snapshot and cannot carry an authorization recorded after
   dispatch. This matches `cmd_land` (RFC §3.7 step 4).
4. **The audit comment is posted with the App token**, the same actor as the merge, so the audit
   trail has one author. A refusal posts **no** comment — it prints to stderr and exits 7.
5. **`ob-gate` sources `by` from the GitHub login** (`gh api user --jq .login`), falling back to
   `git config --get user.name`. The hand-written record says `artemkurylo`, which is the login and
   not this laptop's `user.name`.
6. **The §3.7 teardown is extracted, not copied.** `story-04` moves steps 8–11 of `cmd_land` into
   `ob_land_teardown` and has both callers use it, rather than leaving two copies to diverge.

**Measured while landing the first auto-merge by hand, 2026-08-09.** `gh pr view --json mergedBy --jq
.mergedBy.login` prints `app/openbuilder-bot`, not `openbuilder-bot`: the `app/` prefix is part of the
login for a GitHub App actor. `story-04` asserts the prefixed form. This is exactly the class of detail
a weak model gets wrong once and then reports as working, so it is stated twice — in the card's
acceptance item and in its step 7.

**Cross-slug prerequisites.** `plan-workflow-01-gate` must have merged (`local/bin/ob-gate` exists)
and `plan-workflow-05-cli` must have merged (`ob_review_watch`, `cmd_land`, `ob_epic_of_plan`,
`ob_design_branch`, `ob_gate`, `ob_land_prune_script`, `docs/runbook.md` §20). Both are epic-level
ordering, per RFC §9, and neither belongs in a card's `depends_on`, which names stories in this slug
only.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-gate-stage-advance-only | Make `ob-gate record` advance the stage pointer, never rewind it | S | [] |
| story-02-gate-record-automerge | Add `ob-gate record <epic> automerge` and show it in `ob-gate show` | S | [] |
| story-03-merge-check | Add `openbuilder merge-check` for lint and scrub on the merge result | M | [] |
| story-04-review-auto-merge | Add `review --watch --auto-merge` with R12's seven conditions | M | [story-02-gate-record-automerge, story-03-merge-check] |
| story-05-reviewer-rubric-r12 | Teach the reviewer rubric which merges R12 permits, and which stay blocking | M | [] |

`story-04` genuinely needs both parents: it calls `ob_merge_check` for conditions 4–6, and its
condition-1 refusal names `ob-gate record <epic> automerge`, which must exist for the refusal to be
actionable. `story-01` and `story-02` are independent of each other and of everything else — one
edits `record_artifact`, the other adds a sibling function beside it. `story-05` is independent too:
it edits only prose a strong model reads, in two files no other story touches.

## Out of scope

- **Rule 4b, `ob-poll`, `waker/**`.** The stage-rewind defect is fixed at the writer
  (`local/bin/ob-gate`); rule 4b's reader is correct as specified and is not touched. Slug
  `plan-workflow-02-rule` owns it.
- **`runner/**` entirely.** No `ob-common.sh`, no `ob-implement`, no `ob-respond`, no prompt
  template. The instance never merges and gains nothing here.
- **`agent/**` beyond the two files `story-05` names.** No new agent, no `docs/workflow.md`, and no
  change to `agent/remote/**`. In particular the reviewer is **not** taught to emit a findings
  summary — condition 2 reads the transcript it already produces.
- **`backlog/SCHEMA.md`, `LEARNINGS.md`, `infra/**`, `.github/**`, `agent/hooks/**`.** Every one of
  them is on this slug's own protected-path list; a diff that edited them could never auto-merge.
- **No second authorization form.** `land` (human, typed confirmation) and `--auto-merge` (recorded
  per-epic authorization) are the only two, and R8 freezes that.
- **No allowlist, sandbox or diff-content policy beyond the seven-entry denylist.** RFC §3.8.2 is
  explicit that the list is defence in depth, not a sandbox, and that conditions 2, 5 and 6 stand
  behind it.
- **No chaining.** After one merge the command stops and prints the next dispatch command. No
  `--all`, no queue, no second pull request in one invocation.
- **No retry of anything.** Not the merge, not the checks, not the token mint. First failure stops
  the loop (R12 condition 6).
- **No new dependency**, no new `OPENBUILDER_*` variable, and no change to the six
  `openbuilder:*` labels or to any branch name.

## Risks

- **The rubric that judges this slug is the one it fixes, and the fix does not apply to itself.**
  `agent/local/agents/reviewer.md:85` treats any `merge` in a diff as automatically blocking, and this
  slug adds exactly such a merge. `story-05` repairs that rule at the source — drawing the line by
  execution context rather than by keyword — but the reviewer reads its rubric from
  `$OB_ROOT/agent/local/agents` on the **laptop's checkout** (`ob_install_local_assets`, verified
  2026-08-09), not from the branch under review. So `story-05` governs every later review and **not**
  this slug's own pull request, which is why `story-04` still requires the worklog to cite PRD R12,
  RFC §3.8.4 and the recorded authorization in one paragraph. A reviewer should satisfy itself
  independently that the remote implementer's merge prohibitions are untouched — `story-05` lists
  those three files as out of scope precisely so that check stays cheap.
- **A vacuous pass is the failure mode this slug exists to prevent, and its detector can fail
  vacuously too.** Two independent hazards: the tool being absent (handled by presence checks) and
  the assertion not matching (handled by `grep -F`, standardised in both cards). A reviewer should
  grep the diff for any `grep -q '` on `make` output and treat a bare pattern as a finding.
- **The App token is a credential in a shell variable.** It must never be logged, never be passed
  to `ob_gh` (whose other call sites would then inherit it), and never be written to disk. `story-04`
  confines it to two commands in one function. A reviewer should check that no `ob_info`, `ob_warn`
  or `printf` can reach it.
- **Condition 2's transcript shape is inferred, not proven against omp.** The extraction was
  verified against two synthetic envelopes, not against a live run. If it matches nothing, the
  command **refuses** — the failure mode is a dead feature, never a wrong merge. First live
  `--auto-merge` run should be read for the condition-2 line of the audit comment before it is
  trusted.
- **`local/bin/openbuilder` is edited by two stories here and by four in slug 05.** Both stories in
  this slug append new functions and touch a handful of named lines; whichever lands second rebases.
  This slug's own pull request touches `local/bin/openbuilder` and therefore can never auto-merge
  itself, which PRD R12 states as correct rather than a limitation.
- **The teardown extraction moves working code.** `ob_land_teardown` is the only refactor in the
  slug. `story-04` requires `cmd_land`'s existing acceptance strings to survive verbatim so the
  move is checkable by `grep -F` rather than by reading.

---
id: story-04-review-auto-merge
title: Add `review --watch --auto-merge` with R12's seven conditions
size: M
depends_on:
  - story-02-gate-record-automerge
  - story-03-merge-check
files:
  - local/bin/openbuilder
  - docs/runbook.md
  - README.md
acceptance:
  - "`openbuilder review --auto-merge <repo> <pr>` without `--watch` exits 1 with `--auto-merge requires --watch`, and makes no network call"
  - "each of the seven conditions, violated one at a time in a sandbox, prints `auto-merge refused (condition <n>): <the RFC refusal string>`, exits 7, and leaves the pull request OPEN"
  - "on a passing run the pull request is merged and `gh pr view <pr> --json mergedBy --jq .mergedBy.login` prints `app/openbuilder-bot` — measured live 2026-08-09, the App prefix is part of the login and an equality test against `openbuilder-bot` fails"
  - "the audit comment posted after a merge contains one `condition <n>:` line for each of the seven conditions with its observed result"
  - "`openbuilder land` keeps its own behaviour: `grep -cF 'confirmation did not match' local/bin/openbuilder` prints 1 and a land in the sandbox still deletes all three branches"
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
---

## Context

`openbuilder review --watch` (added by `plan-workflow-05-cli` story-03) drives a pull request to a
verdict and, on `openbuilder:approved`, prints `land it with: openbuilder land <repo> <pr>` and exits
0. R12 lets the reviewer merge what it approved instead — but only under seven conditions that must
all hold, and only when a human has authorized auto-merge for that epic.

RFC §3.8.2, verbatim and in the order they are cheapest to check:

| # | Condition | Refusal |
|---|---|---|
| 1 | `approvals.automerge` recorded for this epic | `automerge not authorised for <epic>; run: ob-gate record <epic> automerge` |
| 2 | verdict `approve`, `blocking` and `important` both zero | `verdict carries <n> blocking / <n> important findings; a human should read this` |
| 3 | no changed path matches the protected list | `diff touches <path>, which is protected; a human must read this` |
| 4 | trial merge into the default branch succeeds textually | `trial merge conflicts with <branch>; rebase or merge by hand` |
| 5 | `make lint` on the merge result | `lint failed on the merge result, not on the branch` |
| 6 | `make scrub` on the merge result | `scrub failed on the merge result` |
| 7 | the PR is still `OPEN`, still `openbuilder:approved`, and its head sha is the one reviewed | `pull request moved since review (head <a> -> <b>); re-review` |

Conditions 4, 5 and 6 are already implemented: `story-03` gives you

```
ob_merge_check <owner/repo> <pr>
  stdout: cond=<4|5|6> result=<pass|fail> detail=<text>   (detail on failure = the refusal string)
  return: 0 when all three pass, 1 at the first failure
```

Call it. Do not re-implement the worktree, the trial merge, the tooling-presence refusals or the
teardown of the worktree.

### Where each input comes from

- **The epic.** The head branch is `openbuilder/work/<slug>`; strip `$OB_BRANCH_PREFIX/work/`, then read
  `.openbuilder/backlog/<slug>/plan.md` from `openbuilder/plan/<slug>` with
  `ob_gh api "repos/$repo/contents/<path>?ref=<branch>" -H 'Accept: application/vnd.github.raw'`
  (verified 2026-08-09 against this repository) and pipe it through `ob_epic_of_plan` (added by
  `plan-workflow-05-cli` story-02, reads stdin, prints the epic).
- **`state.json`.** From the **design** branch, `ob_design_branch "$epic"`, same raw-content call. Not
  from the plan branch: that copy is the dispatch-time snapshot and cannot carry an authorization
  recorded after dispatch. This matches `cmd_land` (RFC §3.7 step 4).
- **The reviewed head sha.** `$OB_CACHE_DIR/review/$(ob_repo_key "$repo")__$pr`, the one-line marker
  `ob_review_watch` writes after a successful round.
- **The verdict counts.** The reviewer's own transcript, `$OB_CACHE_DIR/review/<key>__<pr>.round-NN.ndjson`,
  also written by `ob_review_watch`. It is the only artifact carrying `severity` mechanically: the
  `reviewer` agent's structured output has `comments[].severity` in `blocking|important|nit`
  (`agent/local/agents/reviewer.md:35-38`) and the posted pull-request comments do not.
- **The App token.** `waker/github.py` mints one from the App PEM with `installation_token(app_id,
  installation_id, pem)`, and `waker/rs256.py` signs the JWT with no third-party dependency. Verified
  2026-08-09 on this laptop: `PYTHONPATH=<repo>/waker python3 -c 'from github import
  installation_token'` imports cleanly — `waker/` has no `__init__.py` and `github.py` does
  `from rs256 import b64u, sign`, so the import is flat and the directory goes on `PYTHONPATH`. The
  three inputs are SSM parameters `<prefix>/github_app_id`,
  `<prefix>/github_app_installation_id` and `<prefix>/github_app_private_key` (SecureString), where
  the prefix defaults to `/openbuilder` (`runner/bin/ob-common.sh:88`).

### Traps

- **The token is a credential in a shell variable.** It must never reach `ob_info`, `ob_warn`,
  `printf`, a file, or `ob_gh` — whose other call sites would inherit it from the environment. Confine
  it to the two commands that need it.
- **The reviewer must keep posting as the operator, never as the App** (learning 12: `ob-respond`
  drops comments authored by `openbuilder*`, so a review posted as the bot is invisible to the worker).
  Only the merge and the post-merge audit comment use the App token.
- **The reviewer's rubric treats a `merge` in a diff as automatically blocking**
  (`agent/local/agents/reviewer.md:85`) and checks that "the bot never merges" still holds (`:102`).
  Your worklog entry must name PRD R12, RFC §3.8.4 and the recorded `approvals.automerge`
  authorization in one paragraph, so the reviewer reads the citation instead of filing a violation.
- **`cmd_land` steps 8-11 are the teardown you need.** Extract them; do not copy them.
- Every assertion against `make`, `gh` or `git` output uses `grep -F` / `grep -qF`. A bare pattern
  silently fails on text containing regex metacharacters — measured.
- `plan-workflow-00-host` added `ob_gh`. Every `gh` call here goes through it, except the single merge
  and the single audit comment, which need the App token in their environment.

## Change

All in `local/bin/openbuilder` unless stated.

### 1. `OB_PROTECTED_PATHS`

Immediately after the `OB_LABELS` array (line 71), one array and one comment naming RFC §3.8.2 and
saying that each entry is machinery a human must read: infrastructure and the waker spend money and
can strand the box, `agent/hooks/` is the guardrail denylist, `.github/` is CI (whose absence is why
conditions 5 and 6 exist), `LEARNINGS.md` is injected into every round, `SCHEMA.md` is the card
contract, and `local/bin/openbuilder` is the CLI performing the merge.

```
OB_PROTECTED_PATHS=(
    infra/
    waker/
    agent/hooks/
    .github/
    LEARNINGS.md
    backlog/SCHEMA.md
    local/bin/openbuilder
)
```

This is the **only** copy of the list. Nothing else in the repository may hold a second one.

### 2. `cmd_review` argument parsing

- `usage` becomes `usage: $OB_PROG review [--watch [--auto-merge]] <owner/repo> <pr>`.
- `--auto-merge` sets `automerge=1`.
- After the loop, `(( automerge == 1 )) && (( watch == 0 ))` →
  `ob_die "--auto-merge requires --watch: $usage"`. This check happens before `ob_validate_repo` and
  before any `ob_need`, so it costs no network call.
- Pass it through: `ob_review_watch "$repo" "$pr" "$automerge"`.

### 3. `ob_review_watch` — third parameter

`local repo=$1 pr=$2 automerge=${3:-0}`. Change exactly one branch, the `approved` one:

```
if (( automerge == 1 )); then
    ob_auto_merge "$repo" "$pr"
    return $?
fi
```
above the existing `approved. land it with: …` printf, which stays for `automerge == 0`. Add
`--auto-merge` to the `ob_info` banner line so the operator sees which mode is running. Change nothing
else in the function.

### 4. `ob_app_token`

Add beside `ob_gh` (line 455). Prints an installation token on stdout and nothing else, ever.

1. `ob_need aws python3`.
2. `prefix=${OPENBUILDER_SSM_PREFIX:-/openbuilder}` — a local default with a comment citing
   `runner/bin/ob-common.sh:88`; the laptop CLI does not source the instance-side library.
3. Three reads through `ob_aws`:
   `ob_aws ssm get-parameter --name "$prefix/github_app_id" --query 'Parameter.Value' --output text`,
   the same for `github_app_installation_id`, and for `github_app_private_key` with
   `--with-decryption`. Any empty result, `None`, or `REPLACE_ME` →
   `ob_die "cannot read <name> from SSM; the App credentials are not set up"` naming the parameter but
   never its value.
4. Mint, passing all three through the environment so none of them appears in `ps` output or in an
   argument list:
   ```
   OB_APP_ID="$app_id" OB_APP_INSTALL="$install_id" OB_APP_PEM="$pem" \
   PYTHONPATH="$OB_ROOT/waker" python3 -c 'import os,sys
   from github import installation_token
   sys.stdout.write(installation_token(os.environ["OB_APP_ID"], os.environ["OB_APP_INSTALL"], os.environ["OB_APP_PEM"]))' ||
     ob_die "could not mint a GitHub App installation token"
   ```
5. No `ob_info`, no `ob_warn`, no debug print anywhere in this function.

### 5. `ob_verdict_counts <ndjson-file>`

Prints one tab-separated line — `verdict<TAB>blocking<TAB>important<TAB>nit` — for the last verdict
object in the transcript, or nothing at all. Exactly this filter, which finds the object wherever omp
nests it and also handles a result carried as a JSON string (both shapes exercised while this card was
written):

```
jq -Rr '
  fromjson? // empty
  | [ .. | (objects, (strings | (fromjson? // empty))) ]
  | .[]
  | select(type == "object" and has("verdict") and has("comments"))
  | [ .verdict,
      ([ .comments[]? | select(.severity == "blocking") ] | length),
      ([ .comments[]? | select(.severity == "important") ] | length),
      ([ .comments[]? | select(.severity == "nit") ] | length) ]
  | @tsv
' "$1" | tail -1
```

Empty output means "no verdict found", which the caller treats as a refusal, never as a pass.

### 6. `ob_land_teardown <owner/repo> <slug> <epic>`

Extract steps 8-11 of `cmd_land` — plan-branch deletion, the design-branch decision, the SSM prune via
`ob_land_prune_script`, and the final report with the next dispatch command — into this function,
**moving** the code rather than rewriting it. `cmd_land` then calls
`ob_land_teardown "$repo" "$slug" "$epic"` and returns its status, keeping steps 1-7 (the refusals, the
typed confirmation, the merge) exactly as they are. The function returns `6` when the instance prune
fails, as `cmd_land` does today, and `0` otherwise. Every message it prints keeps its current wording,
because `docs/runbook.md` §20 and `cmd_land`'s own acceptance items grep for them.

### 7. `ob_auto_merge <owner/repo> <pr>`

Add below `ob_review_watch`. `ob_need git gh aws jq make python3`.

A local helper for refusals, used by every condition:

```
refuse() {   # refuse <n> <string>
    printf '%s: auto-merge refused (condition %s): %s\n' "$OB_PROG" "$1" "$2" >&2
    return 7
}
```

A refusal posts **no** comment on the pull request: it prints to stderr and returns 7. Only a merge is
commented on (R12 condition 7 is about auditing merges).

Collect the observed result of each condition into an array as you go — `results+=("condition 1: pass
— authorised <at> by <by>")` and so on — because the audit comment must enumerate all seven.

Order, exactly:

0. **Read the pull request once.**
   `ob_gh pr view "$pr" --repo "$repo" --json headRefName,headRefOid,state,labels,files,title` into a
   JSON blob. Failure → `ob_die "cannot read pull request #$pr in $repo"`.
   Resolve `head`, `head_sha`, `state`, and the slug (head must start with `$OB_BRANCH_PREFIX/work/`,
   otherwise `ob_die "the head branch of $repo#$pr is '$head', not under $OB_BRANCH_PREFIX/work/; --auto-merge only handles openbuilder pull requests"`), then `ob_validate_slug "$slug"`.
   Read the reviewed sha from the marker; absent or empty →
   `refuse 7 "no reviewed head recorded for $repo#$pr; --auto-merge merges only a round it reviewed"`.
1. **Condition 1 — authorisation.** Resolve the epic from `plan.md` on `$(ob_plan_branch "$slug")`;
   unreadable or no `- epic:` line → `refuse 1 "cannot resolve the epic of $repo#$pr from .openbuilder/backlog/$slug/plan.md; --auto-merge cannot check its authorisation"`.
   Read `state.json` from `$(ob_design_branch "$epic")` and test
   `jq -e '.approvals.automerge.at // empty'`. Unreadable, unparseable, or absent →
   `refuse 1 "automerge not authorised for $epic; run: ob-gate record $epic automerge"`.
2. **Condition 2 — a clean verdict.** Pick the highest-numbered
   `$OB_CACHE_DIR/review/<key>__<pr>.round-*.ndjson`; none → `refuse 2 "no reviewer verdict for $repo#$pr under $OB_CACHE_DIR/review; --auto-merge merges only a verdict it can read"`.
   Run `ob_verdict_counts` on it; empty output → the same refusal wording. Then, when the verdict is
   not `approve` or `blocking + important > 0` →
   `refuse 2 "verdict carries $blocking blocking / $important important findings; a human should read this"`.
   Nits do not refuse; record the count in the results line.
3. **Condition 3 — protected paths.** For each `.files[].path` of the pull request, against each entry
   of `OB_PROTECTED_PATHS`: an entry ending in `/` matches when the path starts with it; an entry
   without a trailing `/` matches only an exactly equal path. First match →
   `refuse 3 "diff touches $path, which is protected; a human must read this"`. Note in a comment that
   this slug's own pull request touches `local/bin/openbuilder` and therefore can never auto-merge
   itself, which PRD R12 states as correct rather than a limitation.
4. **Conditions 4, 5, 6 — the merge result.** `mc_out=$(ob_merge_check "$repo" "$pr")` with the return
   captured. Append every `cond=…` line to the results. Non-zero → take the failing line, parse its
   `cond=<n>` and everything after `detail=`, and `refuse "$n" "$detail"`.
5. **Condition 7 — nothing moved.** Re-read `state`, `labels` and `headRefOid` with a fresh
   `ob_gh pr view`. When `state != OPEN`, the `$OB_LABEL_PREFIX:approved` label is absent, or the oid
   differs from the reviewed sha →
   `refuse 7 "pull request moved since review (head $reviewed -> $now); re-review"`. Use the reviewed
   sha and the fresh oid in that order.
6. **Merge, as the bot.**
   ```
   token=$(ob_app_token) || return 1
   GH_HOST=github.com GH_TOKEN="$token" gh pr merge "$pr" --repo "$repo" --squash --delete-branch ||
       ob_die "auto-merge: gh pr merge #$pr failed; nothing was deleted"
   ```
   Not through `ob_gh`: the token must not enter an environment any other `gh` call inherits. Repeat
   `GH_HOST=github.com` inline and say why in a comment.
7. **Assert the effect, not the exit code.** `actor=$(ob_gh pr view "$pr" --repo "$repo" --json mergedBy --jq '.mergedBy.login')`.
   The value is `app/openbuilder-bot`, **not** `openbuilder-bot` — measured live on 2026-08-09 when
   this merge path was first exercised by hand. Compare with `[[ $actor == app/openbuilder-bot ]]`,
   never with the bare login, and do not strip the prefix. When it does not match,
   `ob_warn "merge actor is '$actor', not app/openbuilder-bot; the audit trail is wrong"` and remember
   to return `6` at the end. Also assert the merge itself:
   `ob_gh pr view "$pr" --repo "$repo" --json state --jq '.state'` must print `MERGED`; anything else
   → `ob_die "auto-merge: #$pr is <state> after the merge call; refusing to tear down"`. `gh` can
   succeed while merging nothing (LEARNINGS 18/19); the state is the proof.
8. **The audit comment**, posted with the App token so its author matches the merger:
   ```
   GH_HOST=github.com GH_TOKEN="$token" gh pr comment "$pr" --repo "$repo" --body "$body"
   ```
   `body` is, exactly:
   ```
   **openbuilder: auto-merged.** Authorised for epic `<epic>` by `<by>` at `<at>` (approvals.automerge).

   condition 1: pass — <detail>
   condition 2: pass — <detail>
   condition 3: pass — <detail>
   condition 4: pass — <detail>
   condition 5: pass — <detail>
   condition 6: pass — <detail>
   condition 7: pass — <detail>

   Merged with the GitHub App installation token, squash, head branch deleted.
   ```
   One line per condition, all seven, in order, each with the observed result — a run that merged has
   seven `pass` lines and a `detail` that says what was observed, not what was expected. A failure to
   post is `ob_warn "could not post the auto-merge audit comment"` and a return of `6`; the merge
   already happened and claiming a complete audit would be a lie.
9. **Teardown and stop.** `ob_land_teardown "$repo" "$slug" "$epic"`, keeping its return code: `6`
   survives. Then
   ```
   printf 'auto-merge stopped after one merge; --auto-merge never chains to the next slug\n'
   ```
   The next dispatch command is already printed by `ob_land_teardown` when the epic has unlanded slugs.
   Return `0`, or `6` when step 7, 8 or 9 asked for it.

Exit codes for `review`, all six, documented in a comment above `ob_auto_merge`: `0` merged (or
approved, without `--auto-merge`), `1` any `ob_die`, `4` blocked, `5` rounds exhausted, `6` merged but
the audit or teardown did not finish, `7` auto-merge refused by a condition.

### 8. `ob_command_table`

Replace the `review` line with:

```
  review [--watch [--auto-merge]] <owner/repo> <pr>  review a PR with Opus 5; --auto-merge merges a clean approval
```

Keep the two-space indent; do not reflow the rest of the heredoc.

### 9. `docs/runbook.md`

- §19 quick reference: one row, `Drive a PR to a verdict and merge it` →
  `openbuilder review --watch --auto-merge you/your-repo <pr>`, with the note that it refuses unless
  `ob-gate record <epic> automerge` was run.
- §20 (`## 20. Refusals from the laptop CLI`): one row per refusal string this story adds — all seven
  condition strings plus the three `--auto-merge`-specific ones (`--auto-merge requires --watch`, the
  missing marker, the missing verdict) — quoted verbatim from the source, with cause and fix. Add a
  short `### Enabling auto-merge` subsection: it is one command, `ob-gate record <epic> automerge`, run
  from the clone on the epic's design branch; it is per epic, never global, never a default; and the
  slug that rewrites `local/bin/openbuilder` can never auto-merge because that path is on the
  protected list.

### 10. `README.md`

In `### 12. Review`, document `--auto-merge` as the unattended-merge form: it requires `--watch`, it
requires the recorded per-epic authorization, it checks seven conditions cheapest-first and names the
one it refuses on, it runs the repository's own lint and scrub on the merge result rather than on the
branch, GitHub records `openbuilder-bot` as the merger, and it stops after one merge. Keep the attended
form and the `**Only a human merges.**` paragraph in `### 13` intact — a recorded authorization *is* a
human decision, and say so in one sentence rather than deleting the paragraph.

## Acceptance

`shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.

No-network argument handling:

```sh
local/bin/openbuilder review --auto-merge a/b 1; echo $?
# openbuilder: --auto-merge requires --watch: usage: openbuilder review [--watch [--auto-merge]] <owner/repo> <pr>
# 1
local/bin/openbuilder help | grep -cF '--watch [--auto-merge]'    # prints 1
grep -cF 'infra/' local/bin/openbuilder                            # at least 1, in OB_PROTECTED_PATHS
```

The list lives in one place: `grep -cF 'backlog/SCHEMA.md' local/bin/openbuilder` prints `1`.

**Sandbox, required.** Reuse the `story-03` sandbox recipe (a private repo pushed from a clone of this
one, so it has the `Makefile`), and additionally push the branch layout `--auto-merge` reads:
`openbuilder/design/am-epic` carrying `.openbuilder/epics/am-epic/state.json` with
`stage: dispatched`, `slugs: ["am-slug"]` and **no** `approvals.automerge`;
`openbuilder/plan/am-slug` carrying `.openbuilder/backlog/am-slug/plan.md` whose second line is
`- epic: am-epic`; `openbuilder/work/am-slug` with one commit; a pull request from it labelled
`openbuilder:approved` (run `local/bin/openbuilder approve <you>/ob-am-sandbox <pr>` once to create the
labels). Write the marker and a transcript by hand, since no reviewer ran:

```sh
K=<you>__ob-am-sandbox
D="${XDG_CACHE_HOME:-$HOME/.cache}/openbuilder/review"
mkdir -p "$D"
gh pr view <pr> --repo <you>/ob-am-sandbox --json headRefOid --jq .headRefOid >"$D/${K}__<pr>"
printf '%s\n' '{"result":{"data":{"verdict":"approve","summary":"s","comments":[]}}}' \
  >"$D/${K}__<pr>.round-01.ndjson"
```

Then, one case per condition. In every refusal case assert all three of: the message, the exit code
`7`, and that `gh pr view <pr> --repo <you>/ob-am-sandbox --json state --jq .state` still prints
`OPEN`.

1. **Condition 1.** With no `approvals.automerge` on the design branch, run
   `local/bin/openbuilder review --watch --auto-merge <you>/ob-am-sandbox <pr>`: stderr contains
   `auto-merge refused (condition 1): automerge not authorised for am-epic; run: ob-gate record am-epic automerge`.
2. **Condition 2.** Add the authorization to the design branch's `state.json` (by hand, or with
   `ob-gate record am-epic automerge` from a clone on that branch), then rewrite the transcript with
   two blocking findings:
   `'{"result":{"data":{"verdict":"approve","summary":"s","comments":[{"severity":"blocking"},{"severity":"important"}]}}}'`.
   The refusal is `verdict carries 1 blocking / 1 important findings; a human should read this`.
   Then delete the transcript entirely: the refusal becomes
   `no reviewer verdict for <you>/ob-am-sandbox#<pr> under <dir>; --auto-merge merges only a verdict it can read`.
   Restore the clean transcript afterwards.
3. **Condition 3.** Add a commit to `openbuilder/work/am-slug` touching `LEARNINGS.md`, refresh the
   marker to the new head sha, and re-run: the refusal is
   `diff touches LEARNINGS.md, which is protected; a human must read this`. Then repeat with a commit
   touching `infra/variables.tf` (prefix match) and confirm the refusal names that path. Reset the
   branch afterwards.
4. **Conditions 4, 5, 6.** Reuse the three `story-03` cases — the conflicting branch, the SC2086
   script, and `OPENBUILDER_SCRUB_DENY=/tmp/definitely-not-here` — on the auto-merge path. Each prints
   `auto-merge refused (condition 4|5|6): <the same string story-03 printed>` and exits 7. The scrub
   case must show the vacuous-pass refusal, not a pass:
   `grep -cF 'refusing to treat a skipped check as a pass'` prints `1`. Also run one case with
   `shellcheck` hidden (the `PATH=/tmp/ob-nolint:/bin:/usr/bin` recipe from `story-03`) and assert the
   refusal and that the pull request is still `OPEN` — a machine without the linter must never merge.
5. **Condition 7.** With everything else passing, push one more commit to the work branch **without**
   refreshing the marker, then run: the refusal is
   `pull request moved since review (head <old> -> <new>); re-review`. Then set the marker back, remove
   the `openbuilder:approved` label, and re-run: the same condition-7 refusal.
6. **The happy path.** Everything restored and consistent — authorization recorded, clean transcript,
   marker equal to the head sha, `openbuilder:approved`, no protected path, no conflict, `shellcheck`
   on `PATH`, a real deny list. Run it, and assert:
   ```sh
   gh pr view <pr> --repo <you>/ob-am-sandbox --json state --jq .state            # MERGED
   gh pr view <pr> --repo <you>/ob-am-sandbox --json mergedBy --jq .mergedBy.login # openbuilder-bot
   gh api repos/<you>/ob-am-sandbox/git/matching-refs/heads/openbuilder/ --jq length  # 0
   gh pr view <pr> --repo <you>/ob-am-sandbox --json comments --jq '.comments[-1].body' >/tmp/am.md
   for n in 1 2 3 4 5 6 7; do grep -cF "condition $n: pass" /tmp/am.md; done        # seven 1s
   ls -d "${XDG_CACHE_HOME:-$HOME/.cache}"/openbuilder/automerge/<pr> 2>&1 | grep -cF 'No such'  # 1
   ```
   and that stdout contains `auto-merge stopped after one merge`. An exit code of `6` is acceptable
   here **only** when the SSM prune failed because no instance is reachable, and then the warning must
   name the two manual `sudo` commands, exactly as `cmd_land` does.
7. **`land` still works after the extraction.** `grep -cF 'confirmation did not match' local/bin/openbuilder`
   prints `1`; and on a second sandbox pull request,
   `printf 'land am-slug2\n' | local/bin/openbuilder land <you>/ob-am-sandbox <pr2>` merges it and
   leaves `gh api repos/<you>/ob-am-sandbox/git/matching-refs/heads/openbuilder/ --jq length` printing
   `0`.

Clean up: `gh repo delete <you>/ob-am-sandbox --yes`, `rm -f "$D/${K}__"*`, `rm -rf /tmp/ob-nolint`.

## Out of scope

- **Do not re-implement conditions 4, 5 or 6.** Call `ob_merge_check`. No second worktree, no second
  trial merge, no second tooling-presence check, no second copy of the refusal strings.
- **Do not add a second protected-path list**, do not make it configurable, do not read it from a file,
  and do not turn it into an allowlist. One array in `local/bin/openbuilder`.
- **Do not touch `cmd_approve`, `cmd_request_changes`, the reviewer seed, or anything under
  `agent/**`.** The reviewer keeps posting with the operator's credentials and keeps its current
  rubric; condition 2 reads the transcript it already writes.
- Do not change `ob_gh`, and do not set `GH_TOKEN` or `GITHUB_TOKEN` anywhere except the two commands
  that perform the merge and the audit comment.
- Do not log, print, echo, `set -x`, or write the App token, the PEM, or any SSM value. Not even
  truncated, not even at debug level.
- Do not add a flag beyond `--auto-merge`: no `--force`, `--yes`, `--dry-run`, `--no-checks`,
  `--allow-protected`, `--interval` or `--rounds`.
- Do not chain to another pull request or another slug, do not loop after a merge, and do not dispatch
  anything. Print the next command and stop.
- Do not retry the merge, the checks, or the token mint, and do not treat a refusal as retryable.
- Do not post a comment, review or label on any refusal path, and do not change the six
  `openbuilder:*` labels or add a new one.
- Do not change `runner/**`, `waker/**`, `infra/**`, `Makefile`, `backlog/SCHEMA.md` or `LEARNINGS.md`.
  `waker/github.py` is **imported**, not edited.
- No new dependency and no new `OPENBUILDER_*` variable.

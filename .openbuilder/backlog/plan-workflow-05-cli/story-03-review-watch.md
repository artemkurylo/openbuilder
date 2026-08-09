---
id: story-03-review-watch
title: Add `openbuilder review --watch` with a reviewed-head marker and cap
size: M
depends_on: []
files:
  - local/bin/openbuilder
  - docs/runbook.md
  - README.md
acceptance:
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
  - "`openbuilder review --watch a/b` exits 1 with `usage: openbuilder review [--watch] <owner/repo> <pr>`; `openbuilder review a/b 1 2` exits 1 with the same line"
  - "with the marker pre-set to the PR's head sha and the label `openbuilder:awaiting-review`, `--watch` prints `already reviewed` and starts no omp process"
  - "with the marker removed, the same invocation prints `reviewing #<pr> at <sha> headlessly (round 1 of 6)` and execs omp with `-p --no-pty --mode json --no-session`"
  - "on `openbuilder:approved` it prints `land it with: openbuilder land <repo> <pr>` and exits 0; on `openbuilder:blocked` it exits 4"
---

## Context

`cmd_review` (`local/bin/openbuilder:737-794`) is interactive only: it ensures the instance is
running, checks out the PR head, installs the local omp assets and `exec`s an attended Opus 5 session
whose seed ends by telling *you* to run `openbuilder approve` or `openbuilder request-changes`
(779-782). So each round needs a human at the keyboard, which is the third consequence PRD §2 lists.

RFC §3.6 adds `--watch`: poll the pull request's labels every 60 s and act on the first match.

| Label | Action |
|---|---|
| `openbuilder:blocked` | print the last comment, exit 4 — a human is required |
| `openbuilder:approved` | print the `land` command, exit 0 |
| `openbuilder:changes-requested`, `openbuilder:in-progress` | wait: the instance owns the PR right now |
| `openbuilder:awaiting-review`, head sha unchanged since the last review | wait: this round was already reviewed |
| `openbuilder:awaiting-review`, new head sha | review it |

The last reviewed head sha lives in `$OB_CACHE_DIR/review/<owner>__<repo>__<pr>`, one line.
`OB_CACHE_DIR` is `${XDG_CACHE_HOME:-$HOME/.cache}/openbuilder` (`openbuilder:46`) and the file is
created after `mkdir -p`, the pattern the region and instance-id caches already use
(`openbuilder:176-178`, `openbuilder:221-224`). Losing the marker costs one redundant review, which is
idempotent; it can never cause a round to be skipped, which is the failure that would matter
(RFC §3.6).

What you are copying:

- The headless omp invocation is verified and lives at `runner/bin/ob-common.sh:706-707`:
  `omp -p --no-pty --mode json --approval-mode yolo --auto-approve --no-session --max-time <t> --model <m>`.
  Copy it in full. RFC §3.6 elides the two approval flags in prose while citing that line as *the*
  verified invocation; without them a headless run that must label and comment stalls on an approval
  prompt.
- `ob_pr_labels <repo> <pr>` (`openbuilder:441-443`) prints one label name per line and never fails.
  Match with `grep -qxF`.
- `ob_repo_key <owner/repo>` (`openbuilder:259`) prints `owner__repo`.
- `OB_LOG_FOLLOW_INTERVAL` and `OB_LOG_CHUNK_BYTES` (`openbuilder:71-72`) show where a poll-loop
  constant belongs.
- `cmd_logs` (`openbuilder:953-1000`) is the existing bounded-polling-loop shape: a `while :;` with
  `sleep` at the top of each pass and `ob_info` before entering it.

Why the reviewer applies its own verdict in `--watch`: R7 says one command carries the pull request to
a verdict. A headless reviewer that ends by telling an absent human to run `approve` is the loop it was
supposed to close. `cmd_approve` (796-813) and `cmd_request_changes` (815-833) already do the
labelling, the comment and the instance wake-up, so the seed instructs the reviewer to run one of them
and nothing else.

Traps:

- The reviewer must post with **the laptop's own `gh` credentials**, never the App token: `ob-respond`
  drops conversation comments authored by `openbuilder*`, so a review posted as the bot is invisible to
  the worker (`AGENTS.md`, learning 12). Do not set `GH_TOKEN` or `GITHUB_TOKEN` for the omp child.
- The interactive path must keep its `exec`. The watch path must not `exec` anything — it has a loop to
  return to.
- `OPENBUILDER_MAX_ATTEMPTS` is an instance-side variable and is normally unset on the laptop. Sanitise
  it the way `ob-poll:192-193` does: strip non-digits, then default to `6`.
- `plan-workflow-00-host` adds the `ob_gh` wrapper. Every new `gh` call in this story goes through it.

## Change

### 1. Constants

Add beside `OB_LOG_CHUNK_BYTES` (line 72), with a comment saying why each exists:

- `OB_WATCH_INTERVAL=60` — label poll interval in seconds, matching the instance's poll timer so the
  two sides observe the same cadence. Not configurable.
- `OB_WATCH_MAX_TIME=45m` — `--max-time` for one headless reviewer run, matching the
  `OPENBUILDER_MAX_RUNTIME` default at `runner/bin/ob-common.sh:94`.

### 2. `cmd_review` — argument parsing

Replace the fixed `[[ $# -eq 2 ]]` check (738-739) with:

```
local usage="usage: $OB_PROG review [--watch] <owner/repo> <pr>"
```

and a `while [[ $# -gt 0 ]]` loop in the shape of `cmd_logs` (956-976): `--watch` sets `watch=1` and
shifts; `-h|--help` prints `$usage` and returns 0; anything starting with `-` is
`ob_die "$usage"`; anything else is collected positionally. After the loop, exactly two positionals or
`ob_die "$usage"`.

Then validate as today, and when `watch=1` call `ob_review_watch "$repo" "$pr"` and `return` its exit
status. Otherwise run the existing interactive body (743-793) unchanged, `exec` included.

### 3. `ob_review_watch <repo> <pr>`

Add directly below `cmd_review`.

Setup, once:

- `ob_need git gh omp aws jq`; `ob_ensure_running`.
- `dir=$(ob_ensure_clone "$repo")`; `ob_install_local_assets "$dir"`.
- `marker_dir="$OB_CACHE_DIR/review"`; `mkdir -p "$marker_dir"`;
  `marker="$marker_dir/$(ob_repo_key "$repo")__$pr"`. The `mkdir -p` runs unconditionally on every
  invocation — it is what makes a cleared cache or a fresh laptop a no-op rather than a failure.
- `rounds_max=${OPENBUILDER_MAX_ATTEMPTS//[^0-9]/}`; `rounds_max=${rounds_max:-6}`; `rounds=0`.
- `ob_info "watching $repo#$pr every ${OB_WATCH_INTERVAL}s, at most $rounds_max review rounds (Ctrl-C to stop)"`.

Then `while :;` and, in this order — **first match wins**, so `blocked` beats `approved`:

1. `labels=$(ob_pr_labels "$repo" "$pr")`.
2. `blocked` → print the last comment on the pull request
   (`ob_gh pr view "$pr" --repo "$repo" --json comments --jq '.comments | last | .body'`) to stdout,
   preceded on stderr by
   `ob_warn "#$pr is labelled $OB_LABEL_PREFIX:blocked; last comment follows"`, then
   `printf '%s\n' "$OB_PROG: $repo#$pr is blocked; a human is required" >&2` and `exit 4`.
3. `approved` → `printf 'approved. land it with: %s land %s %s\n' "$OB_PROG" "$repo" "$pr"` and
   `exit 0`.
4. `changes-requested` or `in-progress` → `ob_info "#$pr is $OB_LABEL_PREFIX:<label>; the instance owns it — waiting ${OB_WATCH_INTERVAL}s"`,
   `sleep "$OB_WATCH_INTERVAL"`, `continue`.
5. `awaiting-review`:
   - `head_sha=$(ob_gh pr view "$pr" --repo "$repo" --json headRefOid --jq '.headRefOid')`. An empty
     result → `ob_warn "could not read the head sha of #$pr; retrying in ${OB_WATCH_INTERVAL}s"`,
     sleep, continue.
   - marker exists and its contents equal `$head_sha` →
     `ob_info "#$pr head $head_sha already reviewed — waiting ${OB_WATCH_INTERVAL}s"`, sleep,
     continue.
   - otherwise review this round — step 7.
6. No `$OB_LABEL_PREFIX:` label at all →
   `ob_info "#$pr has no $OB_LABEL_PREFIX label yet — waiting ${OB_WATCH_INTERVAL}s"`, sleep,
   continue.
7. Reviewing a round:
   - `rounds=$((rounds + 1))`. **Check the cap before spending anything:** when
     `rounds > rounds_max`, `printf '%s\n' "$OB_PROG: review rounds for $repo#$pr reached $rounds_max (OPENBUILDER_MAX_ATTEMPTS) without a verdict; a human is required" >&2` and `exit 5`.
   - `git -C "$dir" fetch --prune --quiet origin`, then check out the head branch with the same three
     lines as the interactive path (753-756), keeping the `ob_warn` else branch (758).
   - `ob_info "reviewing #$pr at $head_sha headlessly (round $rounds of $rounds_max)"`.
   - Build the seed. It is the interactive seed (765-785) with the verdict block replaced by:

     ```
     Finish by running exactly one of these two commands yourself, and nothing else:
       <OB_BIN_DIR>/openbuilder approve <repo> <pr>
       <OB_BIN_DIR>/openbuilder request-changes <repo> <pr>

     Before request-changes, post line-anchored review comments a small model can act
     on without guessing. You are running unattended: there is no human to hand the
     verdict to, and leaving the pull request unlabelled stalls the loop.

     Never merge, never push to <head>, never push to a default branch.
     ```
   - Run omp, capturing NDJSON, **not** with `exec`:
     ```
     ndjson="$marker_dir/$(ob_repo_key "$repo")__$pr.round-$(printf '%02d' "$rounds").ndjson"
     rc=0
     GH_REPO="$repo" omp --cwd "$dir" -p --no-pty --mode json --approval-mode yolo \
       --auto-approve --no-session --max-time "$OB_WATCH_MAX_TIME" --model "$OB_OPUS_MODEL" \
       --append-system-prompt "<same string as line 792>" "$seed" >"$ndjson" 2>&1 || rc=$?
     ob_info "reviewer transcript: $ndjson"
     ```
   - `rc == 0` → `printf '%s\n' "$head_sha" >"$marker"` and
     `ob_info "recorded reviewed head $head_sha for #$pr"`. Then sleep and continue: the next pass sees
     the label the reviewer just set.
   - `rc != 0` → `ob_warn "reviewer run for #$pr exited $rc; marker not written, retrying next pass"`,
     sleep, continue. The round counter has already been incremented, so a repeatedly failing run is
     bounded by the cap instead of looping forever.

Exit codes, all four: `0` approved, `1` any refusal from `ob_die`, `4` blocked, `5` rounds exhausted.

### 4. `ob_command_table`

Replace the `review` line (line 537) with:

```
  review [--watch] <owner/repo> <pr>  review a pull request with Opus 5; --watch runs every round
```

Keep the two-space indent. Realign the description column of the surrounding lines only if this line is
longer than the current column start; do not reflow the rest of the heredoc.

### 5. Docs

- `docs/runbook.md:494-499` (§8): add `openbuilder review --watch you/your-repo <pr>` to the snippet
  with one line saying it drives every round to a verdict and stops at 6 rounds, and name the exit
  codes 4 (blocked) and 5 (exhausted).
- `README.md:379-393` (`### 12. Review`): document `--watch` as the unattended form — that it reviews
  each new head sha exactly once using the marker under `~/.cache/openbuilder/review/`, applies its own
  verdict, and exits 0 on approval with the `openbuilder land` command to run next. Keep the attended
  form documented; it is still the path for reading a diff yourself.

## Acceptance

- `shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.
- Argument handling, no network:
  - `local/bin/openbuilder review --watch a/b; echo $?` prints
    `openbuilder: usage: openbuilder review [--watch] <owner/repo> <pr>` and `1`.
  - `local/bin/openbuilder review a/b 1 2; echo $?` prints the same and `1`.
  - `local/bin/openbuilder review --nope a/b 1; echo $?` prints the same and `1`.
  - `local/bin/openbuilder review --help` prints the usage line and exits 0.
- `grep -c -- '-p --no-pty --mode json' local/bin/openbuilder` prints `1`, and
  `grep -c -- '--approval-mode yolo --auto-approve' local/bin/openbuilder` prints `1`.
- **Sandbox required, real pull request.** In a throwaway repo you own, open a pull request from any
  branch, run `local/bin/openbuilder approve <you>/ob-sandbox <pr>` once to create the six labels, then
  relabel it to exactly `openbuilder:awaiting-review` with
  `gh pr edit <pr> --repo <you>/ob-sandbox --add-label openbuilder:awaiting-review --remove-label openbuilder:approved`.
  1. **Marker set → no review.**
     ```sh
     mkdir -p ~/.cache/openbuilder/review
     gh pr view <pr> --repo <you>/ob-sandbox --json headRefOid --jq .headRefOid \
       > ~/.cache/openbuilder/review/<you>__ob-sandbox__<pr>
     timeout 20 local/bin/openbuilder review --watch <you>/ob-sandbox <pr> 2>&1 | tee /tmp/w1.log
     ```
     Assert `grep -c 'already reviewed' /tmp/w1.log` prints at least `1` and
     `grep -c 'reviewing #' /tmp/w1.log` prints `0`. While it runs, `pgrep -f 'omp .*--no-pty'` finds
     nothing.
  2. **Marker cleared → it reviews.** `rm ~/.cache/openbuilder/review/<you>__ob-sandbox__<pr>`, run the
     same `timeout 20` command, and assert the output contains
     `reviewing #<pr> at <sha> headlessly (round 1 of 6)`. Ending the run with `timeout` is expected;
     the assertion is that the round started.
  3. **Approved.** `gh pr edit <pr> --repo <you>/ob-sandbox --add-label openbuilder:approved --remove-label openbuilder:awaiting-review`,
     then `local/bin/openbuilder review --watch <you>/ob-sandbox <pr>; echo $?` prints
     `approved. land it with: openbuilder land <you>/ob-sandbox <pr>` and `0`.
  4. **Blocked.** Swap the label for `openbuilder:blocked` and re-run: exit code is `4` and stderr
     contains `is blocked; a human is required`.
  Clean up: `rm -f ~/.cache/openbuilder/review/<you>__ob-sandbox__<pr>*`, close the pull request, and
  `gh repo delete <you>/ob-sandbox --yes`.

## Out of scope

- **No drive-by refactor of `local/bin/openbuilder`.** It is 1189 lines. Touch only `cmd_review`, the
  new `ob_review_watch`, the two new constants and the `review` line of `ob_command_table`. Do not
  refactor the interactive seed at 765-785 beyond reusing its text, do not touch `cmd_approve`,
  `cmd_request_changes`, `ob_pr_relabel`, `ob_pr_labels`, `cmd_logs` or `cmd_status`, and do not
  reorder or re-indent anything.
- Do not change `cmd_approve` or `cmd_request_changes` in any way. `--watch` calls them as they are;
  that is the whole reason it can apply a verdict without new labelling code.
- No NDJSON parsing, no cost extraction, no verdict summarising in the CLI. Write the transcript to the
  round file, log its path, and let GitHub carry the verdict. Do not copy `ob_omp_final_text` or
  `ob_omp_cost` out of `runner/bin/ob-common.sh`; that file is sourced-only and instance-side, and this
  script does not source it.
- No `GH_TOKEN`/`GITHUB_TOKEN` in the omp child environment. The review must be authored by you, not by
  the App (learning 12).
- No new reviewer rubric, agent or skill. `agent/local/agents/reviewer.md` is
  `plan-workflow-04-agents`; `review-openbuilder-pr` stays as it is.
- No pull-request state handling beyond the six `openbuilder:*` labels — no `merged`, `closed` or
  `draft` branch, no CI-status gate, no mergeability check.
- No configurable poll interval, no `--interval`, `--rounds`, `--once` or `--dry-run` flag. One flag,
  `--watch`.
- No backgrounding, no `nohup`, no `systemd`/`launchd` unit, no PID file, no lock. `--watch` runs in the
  foreground of the terminal that started it.
- Do not edit `README.md`'s mermaid diagram (14-33) or `## The daily loop` (409-417), or
  `docs/runbook.md` §0 (11-38) or §19 (1144-1170) — `story-04-land-teardown` owns those four.
- No new dependency.

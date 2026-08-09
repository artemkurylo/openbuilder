---
id: story-01-ob-poll-rule-4b
title: Add rule 4b to ob-poll so an unapproved backlog is skipped silently
size: M
depends_on: []
files:
  - runner/bin/ob-poll
acceptance:
  - "shellcheck -x -S warning runner/bin/ob-poll exits 0 and prints no output"
  - "against the seven fixture branches, ob-poll --dry-run prints rule=4b action=skip for the six unapproved slugs with reasons backlog-unapproved:no-epic-line, :no-state, :stage=backlog, :no-approval, :files-differ(plan.md), :files-differ(story-02-extra.md)"
  - "the same pass prints slug=fx-approved rule=5 action=implement and a final ACTIONABLE=1"
  - "after that pass the fixture repo has zero labels, zero issues and zero pull requests"
  - "after that pass each of the seven state directories under /opt/openbuilder/state contains no attempts file and no blocked-reported file"
  - "no line is appended to /opt/openbuilder/log/openbuilder.log by the pass (its mtime is unchanged)"
---

## Context

`runner/bin/ob-poll` evaluates the §6 rule table in `evaluate()` (line 93): seven rules, in order,
first match wins, at most one action per slug per pass. Each rule ends in a `decision` call
(line 40) that prints one `DECISION repo=… slug=… rule=… action=… reason=…` line to **stdout**, and
rules 5 and 6 additionally increment `ACTIONABLE` (lines 135, 143) — the counter `ob-idle-stop`
parses from the trailing `ACTIONABLE=<n>` line.

Three properties of this file are load-bearing and must survive your change:

- **Nothing may be written to the operational log on an uneventful pass.** The header comment at
  lines 6-9 says why: `ob-idle-stop` reads `$OPENBUILDER_HOME/log/openbuilder.log`'s mtime as "when
  work last happened", so a chatty pass keeps the instance awake and billing. Rule 4b therefore
  calls **no** `ob_log`, ever — not at INFO, not at WARN, not on an API failure.
- **A dry run takes no lock** (lines 196-198) and skips `ob_ensure_labels` (lines 220-222), so
  `--dry-run` neither blocks the live pass nor creates anything.
- **`set -euo pipefail` and `IFS=$'\n\t'` are in force** (lines 10-11). A helper that returns
  non-zero inside a command substitution aborts the whole pass.

`ob_gh` (`runner/bin/ob-common.sh:261-270`) is the only way this repo calls `gh`: it mints a fresh
installation token into the child environment and pins `GH_HOST`. `jq` is installed on the instance
and is already used by `ob-token`. Bash is 5.x, so `local -A` associative arrays are available.

Rule 4b is poller-only logic with exactly one caller, so it stays in `ob-poll`; do not move any of it
into `ob-common.sh`.

The `state.json` shape rule 4b reads is fixed by the approved RFC (`.openbuilder/epics/plan-workflow/rfc.md`
§2), and `plan.md` carries the epic as a plain bullet extracted with `awk '/^- epic:/ {print $3; exit}'`:

```json
{ "stage": "dispatched",
  "approvals": { "backlog": { "<slug>": { "at": "…",
      "files": { "plan.md": "<blob sha>", "story-01-x.md": "<blob sha>" } } } } }
```

A GitHub contents *directory* listing returns one entry per file with `sha` equal to the git blob sha
— the same value `git rev-parse <ref>:<path>` prints. That is why no card content is downloaded.

## Change

In `runner/bin/ob-poll` only.

1. **Header comment.** Add one sentence to the block comment at lines 2-9 stating that rule 4b reads
   the plan branch's backlog approval and declines with `action=skip` and no side effect, so a decline
   costs no attempt, no label and no log line.

2. **`safe_field <value> <max-len>`** — new function, printed values come from branch content.
   Removes every character outside `[A-Za-z0-9._-]` (pure bash pattern substitution, no subshell),
   truncates to `<max-len>`, and prints `-` when the result is empty. Always returns 0.

3. **`gh_contents_raw <owner/repo> <ref> <path>`** — new function. Prints the file body on stdout:

   ```sh
   ob_gh api -H "Accept: application/vnd.github.raw" \
     "repos/${repo}/contents/${path}?ref=${ref}" 2>/dev/null
   ```

   stderr is discarded and the caller treats empty output as unreadable. Do not add a base64 path:
   the `raw` Accept header returns the bytes directly (verified against
   `repos/artemkurylo/openbuilder/contents/Makefile?ref=main`).

4. **`backlog_listing <owner/repo> <ref> <dir>`** — new function. Prints one `name<TAB>sha` line per
   listing entry whose `type` is `file`:

   ```sh
   ob_gh api "repos/${repo}/contents/${dir}?ref=${ref}" \
     --jq '.[] | select(.type == "file") | "\(.name)\t\(.sha)"' 2>/dev/null
   ```

5. **`backlog_decline_reason <owner/repo> <slug>`** — new function, the rule itself. It prints the
   reason string with no trailing newline and prints **nothing** when the backlog is approved. It
   **always returns 0** — a non-zero return would abort the pass under `set -e`. Every value it
   captures is assigned with `|| true` so a failed `ob_gh` cannot propagate. In order:

   1. `ref="${OPENBUILDER_BRANCH_PREFIX}/plan/${slug}"`, `dir=".openbuilder/backlog/${slug}"`.
   2. Read `${dir}/plan.md` with `gh_contents_raw`. Extract the epic with
      `awk '/^- epic:/ {print $3; exit}'`. If the body is empty, the epic is empty, or the epic does
      not match `^[a-z0-9][a-z0-9-]{1,48}$`, print `backlog-unapproved:no-epic-line` and return. The
      regex check is not cosmetic: the value is interpolated into an API path and comes from a file
      on a branch.
   3. Read `.openbuilder/epics/${epic}/state.json` with `gh_contents_raw`. If the body is empty or
      `jq -e . >/dev/null 2>&1` fails on it, print `backlog-unapproved:no-state` and return.
   4. `stage="$(… | jq -r '.stage // empty')"`. If it is not exactly `dispatched`, print
      `backlog-unapproved:stage=` followed by `safe_field "$stage" 32` and return.
   5. Recorded map:
      `jq -r --arg s "$slug" '.approvals.backlog[$s].files // {} | to_entries[] | "\(.key)\t\(.value)"'`.
      If that produces no non-empty line, print `backlog-unapproved:no-approval` and return.
   6. Call `backlog_listing`. Load both sides into `local -A recorded=() listed=()` with
      `while IFS=$'\t' read -r name sha` over a `< <(printf '%s\n' …)` process substitution, skipping
      empty names.
   7. Build the compared name set: every key of `recorded`, plus every key of `listed` that is
      `plan.md` or matches `story-*.md`. Sort it with `LC_ALL=C sort -u` through
      `mapfile -t names < <(…)` so a name containing a space cannot split. Any other listed file —
      `worklog.md`, for instance — is ignored.
   8. Walk `names` in that sorted order and stop at the **first** name whose recorded sha is empty,
      whose listed sha is empty, or whose two shas differ: print `backlog-unapproved:files-differ(`
      then `safe_field "$name" 48` then `)`, and return. Look the listed sha up in `listed`, which
      holds every file in the directory, not only the filtered names.
   9. Print nothing and return 0.

6. **Wire it into `evaluate()`**, as a new block between the rule-4 block (which ends at line 130)
   and the rule-5 comment at line 132, and add `reason` to the function's `local` declaration on
   line 95:

   ```sh
   # --- Rule 4b: plan branch present, no PR, backlog not approved -> skip quietly.
   if [[ -z "$pr" ]]; then
     reason="$(backlog_decline_reason "$repo" "$slug")"
     if [[ -n "$reason" ]]; then
       decision "$repo" "$slug" 4b skip "$reason"
       return 0
     fi
   fi
   ```

   No `ACTIONABLE` increment, no `run_action`, no `mark_blocked`, no `ob_label_add`, no
   `ob_report_blocked`, no state file. The rule number passed to `decision` is the literal `4b`.
   Rules 5, 6 and 7 keep their numbers and their bodies unchanged.

7. Write each of the five reason strings as **one literal** in the source (`printf
   'backlog-unapproved:no-state'`, `printf 'backlog-unapproved:stage=%s' …`), never assembled from a
   prefix variable, so `grep backlog-unapproved runner/bin/ob-poll` finds all of them.

Add no `DRY_RUN` branch: rule 4b performs read-only API calls, and a dry run must reach the identical
decision.

## Acceptance

**Step 0 — preconditions.** The sandbox repository `artemkurylo/openbuilder-fixture` exists and the
openbuilder App installation includes it (see `plan.md`, "Operator prerequisite"). Confirm:

```sh
source /opt/openbuilder/bin/ob-common.sh; ob_load_env
ob_gh api repos/artemkurylo/openbuilder-fixture --jq .full_name   # prints the full name
grep -c openbuilder-fixture /opt/openbuilder/etc/openbuilder.env  # prints 0
```

If the first command does not print `artemkurylo/openbuilder-fixture`, stop and report that the
sandbox repository is not reachable — do not create it and do not substitute another repository.
Throughout this section, `grep -c` printing `0` also exits 1: the printed count is the assertion, not
the exit status.

**Step 1 — lint.** `shellcheck -x -S warning runner/bin/ob-poll` exits 0 and prints nothing. Do not
run `make lint`, `make scrub` or any other project-wide target.

**Step 2 — seed the seven fixture branches.** Write this to `/tmp/ob4b/seed.sh` and run
`bash /tmp/ob4b/seed.sh`. It is scaffolding: it lives in `/tmp` and is never committed to any
repository. The plain `https://github.com/…` clone and push need no token argument: the instance's
global git credential helper shells out to `ob-token` (`runner/bootstrap.sh:294-301`).

```sh
#!/usr/bin/env bash
# /tmp/ob4b/seed.sh — rule-4b fixture branches. Never committed.
set -euo pipefail
IFS=$'\n\t'
FIX=artemkurylo/openbuilder-fixture
SLUGS=(fx-no-epic fx-no-state fx-bad-stage fx-no-approval fx-file-edited fx-extra-story fx-approved)

rm -rf /tmp/ob4b/repo
mkdir -p /tmp/ob4b
git clone --quiet "https://github.com/${FIX}.git" /tmp/ob4b/repo
cd /tmp/ob4b/repo
git config user.name openbuilder-bot
git config user.email openbuilder-bot@users.noreply.github.com

# Delete first, then create: force-pushing is blocked by the guardrail hook.
for s in "${SLUGS[@]}"; do
  git push --quiet origin --delete "openbuilder/plan/${s}" 2>/dev/null || true
done

card() { # card <path>
  printf '%s\n' '---' 'id: story-01-fixture' 'title: fixture card' 'size: S' \
    'depends_on: []' 'files: []' 'acceptance: []' '---' '' '## Context' 'fixture' '' \
    '## Change' 'nothing' '' '## Acceptance' 'nothing' '' '## Out of scope' 'everything' >"$1"
}

seed() { # seed <slug> <epic-line:0|1>
  local slug="$1" epic="$2" dir=".openbuilder/backlog/$1"
  git checkout --quiet -B "openbuilder/plan/${slug}" main
  rm -rf .openbuilder
  mkdir -p "$dir" .openbuilder/epics/fx-epic
  if [[ "$epic" == 1 ]]; then
    printf '%s\n' "# fixture ${slug}" '' '- epic: fx-epic' '' '## Goal' 'fixture' >"$dir/plan.md"
  else
    printf '%s\n' "# fixture ${slug}" '' '## Goal' 'fixture' >"$dir/plan.md"
  fi
  card "$dir/story-01-fixture.md"
  git add -A
  git commit --quiet -m "fixture ${slug}: backlog"
}

sha() { git rev-parse "HEAD:.openbuilder/backlog/$1/$2"; }

state() { # state <slug> <stage> <approved:0|1>
  local slug="$1" stage="$2" approved="$3" backlog='{}'
  if [[ "$approved" == 1 ]]; then
    backlog="$(printf '{"%s":{"at":"2026-08-09T00:00:00Z","files":{"plan.md":"%s","story-01-fixture.md":"%s"}}}' \
      "$slug" "$(sha "$slug" plan.md)" "$(sha "$slug" story-01-fixture.md)")"
  fi
  printf '{"epic":"fx-epic","repo":"%s","stage":"%s","opened":"2026-08-09","slugs":["%s"],"approvals":{"backlog":%s}}\n' \
    "$FIX" "$stage" "$slug" "$backlog" | jq . >.openbuilder/epics/fx-epic/state.json
  git add -A
  git commit --quiet -m "fixture ${slug}: state ${stage}"
}

push() { git push --quiet origin "openbuilder/plan/$1"; }

seed fx-no-epic 0;                                            push fx-no-epic
seed fx-no-state 1;                                           push fx-no-state
seed fx-bad-stage 1;     state fx-bad-stage backlog 1;        push fx-bad-stage
seed fx-no-approval 1;   state fx-no-approval dispatched 0;   push fx-no-approval
seed fx-file-edited 1;   state fx-file-edited dispatched 1
printf 'edited after approval\n' >>.openbuilder/backlog/fx-file-edited/plan.md
git commit --quiet -am 'fixture fx-file-edited: edit plan.md after approval'
push fx-file-edited
seed fx-extra-story 1;   state fx-extra-story dispatched 1
card .openbuilder/backlog/fx-extra-story/story-02-extra.md
git add -A && git commit --quiet -m 'fixture fx-extra-story: unapproved extra card'
push fx-extra-story
seed fx-approved 1
printf '# worklog\n' >.openbuilder/backlog/fx-approved/worklog.md
git add -A && git commit --quiet -m 'fixture fx-approved: stray worklog'
state fx-approved dispatched 1
push fx-approved
printf 'seeded %s branches\n' "${#SLUGS[@]}"
```

It must end with `seeded 7 branches`, and
`ob_gh api 'repos/artemkurylo/openbuilder-fixture/git/matching-refs/heads/openbuilder/plan/' --jq 'length'`
must print `7`.

**Step 3 — one dry-run pass over the fixture repo, using your worktree copy.** Run these from the
root of your worktree, so `$PWD/runner/bin/ob-poll` is the file you just changed; the installed
`/opt/openbuilder/bin/ob-poll` is the *previous* deploy and does not have rule 4b. The script sources
`ob-common.sh` from its own directory (`runner/bin/ob-poll:15-17`), so the worktree copy is
self-consistent. `/opt/openbuilder/etc/` is guarded by the pre-tool hook, so the sandbox env file
goes in `/tmp`:

```sh
mkdir -p /tmp/ob4b
sed 's#^OPENBUILDER_REPOS=.*#OPENBUILDER_REPOS=artemkurylo/openbuilder-fixture#' \
  /opt/openbuilder/etc/openbuilder.env >/tmp/ob4b/openbuilder.env
stat -c %Y /opt/openbuilder/log/openbuilder.log >/tmp/ob4b/log-mtime-before
OPENBUILDER_ENV_FILE=/tmp/ob4b/openbuilder.env \
  bash "$PWD/runner/bin/ob-poll" --dry-run 2>/tmp/ob4b/poll.err | tee /tmp/ob4b/poll.out
```

`/tmp/ob4b/poll.out` must contain exactly these seven `DECISION` lines, in any order, plus
`ACTIONABLE=1` as its last line:

| slug | expected fields |
|---|---|
| fx-no-epic | `rule=4b action=skip reason=backlog-unapproved:no-epic-line` |
| fx-no-state | `rule=4b action=skip reason=backlog-unapproved:no-state` |
| fx-bad-stage | `rule=4b action=skip reason=backlog-unapproved:stage=backlog` |
| fx-no-approval | `rule=4b action=skip reason=backlog-unapproved:no-approval` |
| fx-file-edited | `rule=4b action=skip reason=backlog-unapproved:files-differ(plan.md)` |
| fx-extra-story | `rule=4b action=skip reason=backlog-unapproved:files-differ(story-02-extra.md)` |
| fx-approved | `rule=5 action=implement reason=no-pr attempts=0` |

Check it mechanically — every command's expected output is given:

```sh
grep -c 'rule=4b action=skip' /tmp/ob4b/poll.out                        # 6
grep -cF 'slug=fx-approved rule=5 action=implement' /tmp/ob4b/poll.out  # 1
tail -1 /tmp/ob4b/poll.out                                              # ACTIONABLE=1
for r in no-epic-line no-state 'stage=backlog' no-approval \
         'files-differ(plan.md)' 'files-differ(story-02-extra.md)'; do
  grep -cF "reason=backlog-unapproved:${r}" /tmp/ob4b/poll.out          # 1 each
done
```

`fx-approved` reaching rule 5 is the happy-path check: the gate must not break it. It starts no
round, because `run_action` returns immediately under `--dry-run` (`runner/bin/ob-poll:58-60`).

**Step 4 — a decline leaves nothing behind.**

```sh
ob_gh label list --repo artemkurylo/openbuilder-fixture 2>&1 | grep -c openbuilder   # 0
ob_gh issue list --repo artemkurylo/openbuilder-fixture --state all | wc -l          # 0
ob_gh pr list --repo artemkurylo/openbuilder-fixture --state all | wc -l             # 0
for s in fx-no-epic fx-no-state fx-bad-stage fx-no-approval fx-file-edited \
         fx-extra-story fx-approved; do
  ls -A "/opt/openbuilder/state/artemkurylo__openbuilder-fixture__${s}" 2>/dev/null | wc -l  # 0
done
stat -c %Y /opt/openbuilder/log/openbuilder.log   # equals /tmp/ob4b/log-mtime-before
                                                  # (if the log file does not exist on this instance,
                                                  #  both stat calls fail and the assertion is that
                                                  #  the pass did not create it)
```

The seven state *directories* are expected to exist and to be empty: `ob_attempts_get` creates the
directory for every slug on every pass through rule 4 (`runner/bin/ob-common.sh:408-435`), which is
pre-existing behaviour. What must not exist is an `attempts` or `blocked-reported` file inside them.

**Step 5 — leave the fixture branches in place.** `story-02-waker-rule-4b` runs the other
implementation against these same seven branches and owns the cleanup. Do not delete them here.

## Out of scope

- `waker/`, `docs/`, `local/bin/`, `runner/prompts/`, `runner/bin/ob-common.sh`,
  `runner/bin/ob-implement`, `runner/bin/ob-respond`. This story touches one file.
- No new files, anywhere in the repository. The seed script belongs in `/tmp`.
- No caching of the three API calls, no retry loop, no timeout flag, no parallelism.
- No new reason strings, no renaming of the five, and no extra fields on the `DECISION` line.
- No renumbering of rules 5, 6 or 7, and no change to their bodies, to `mark_blocked`, to
  `run_action`, to `poll_repo` or to `main`.
- No `ob_log` call anywhere in the new code, and no new `ob-poll` flag or environment variable.
- No verification of `approvals.prd` or `approvals.rfc`, and no check that `prd.md` or `rfc.md`
  exist. `ob-gate verify` owns those.
- Do not reformat, re-order or re-comment the parts of `ob-poll` you did not change.
- Do not run `make lint`, `make scrub`, `terraform` or any project-wide suite.
- Do not commit anything to `artemkurylo/openbuilder-fixture` other than the seven fixture branches,
  and never push to its `main`.

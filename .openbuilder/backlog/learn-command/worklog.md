# Worklog — learn-command

## Round 001 (story-01-ob-learn)

- Added `local/bin/ob-learn` (executable): reads a candidate learning from `-f FILE` or
  stdin, validates the `### N.` heading + `**Symptom**`/`**Cause**`/`**Rule**`/`**Proven**`
  shape (in order), checks the scrub deny list, numbers the entry `highest ### N. + 1`, and
  inserts it as the last entry of the requested section. `--dry-run` prints without touching
  LEARNINGS.md. Verified against every acceptance line; `shellcheck -x -S warning` clean
  (whole `local/bin/*` passes, matching `make lint`).
- LEARNINGS.md currently has 11 numbered entries (max 11, next is 12). The `### N.` template
  line inside the "Entry shape" code block is skipped by numbering (not digits). LEARNINGS.md
  ends in a single newline; `ob-learn` normalizes to that after a real insertion.
- Notes for future rounds touching shell here:
  - An EXIT trap's last command determines the script's exit status in bash — a trap that
    ends on a failed `[[ ]]` silently converts `exit 0` into exit 1. End cleanup traps with
    a guaranteed-success command. Discovered while verifying `--help` (expected 0, got 1).
  - `ob-learn` refuses candidates matching the deny list with a line count only, never the
    matching text, mirroring `ob-scrub-check`; denial happens before any write.
## Round 1 — 2026-08-09T06:32:25Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 2
- cost: 0.06634018048 USD
- story cards: 1

### Agent summary

## Summary
Added `local/bin/ob-learn` (story-01): a leaf command that turns an accepted candidate learning into a correctly numbered, correctly placed entry in `LEARNINGS.md`. It validates the `### N.` heading and the four label lines in order, refuses candidates matching the scrub deny list (count only, never the text, like `ob-scrub-check`), numbers the entry one above the current max (`### 12.`), inserts it as the last entry of the requested section with one blank-line separators and a single trailing newline, writes atomically via a same-filesystem temp file + `mv`, and supports `--dry-run`. Commits: `64b7e99` (script), `6477bb9` (worklog). `LEARNINGS.md` is unmodified.

## Stories
- story-01-ob-learn: done

## Verification
- `shellcheck -x -S warning local/bin/ob-learn` -> exit 0; full `shellcheck -x -S warning local/bin/*` (the `make lint` command; shellcheck 0.10.0 fetched to /tmp, none installed system-wide) -> exit 0
- `ob-learn --help` (stdin = `tail -f /dev/null`, blocking) -> usage on stdout, exit 0, no stdin read
- no `--section` / bad `--section bogus` / unknown arg -> exit 2, message names `implementer`, `environment` (stderr only; stdout empty)
- candidates missing `**Proven**` / `**Cause**` (out of order) / only a heading / empty / first line `## not a level three heading` / mid-line label -> exit 1, message names exactly the missing line or the heading problem, stderr only
- `--dry-run` with valid candidates (template `### N.` heading and `### 99.` heading) -> prints `### 12.` + `section: implementer|environment`, exit 0, `cmp` confirms LEARNINGS.md byte-identical
- real `--section implementer` insert -> `### 12.` lands as last entry, immediately before `## Environment truths`, diff = exactly the 6 entry lines, file ends in single newline; restored with `git checkout`
- real `--section environment` insert -> `### 12.` at end of file, single trailing newline, blank-line separator; restored
- deny list via `OPENBUILDER_SCRUB_DENY` (comments/blanks ignored, case-insensitive, 1 matching line) -> exit 1, stdout 0 bytes, LEARNINGS.md byte-identical; non-matching deny list proceeds normally
- `-f` missing file -> exit 2 with message; `git status` -> working tree clean, LEARNINGS.md unmodified

## Notes for the reviewer
- Shellcheck is not installed on this instance and there is no passwordless sudo; the static 0.10.0 arm64 binary was downloaded to `/tmp` solely for verification, nothing installed.
- `ob-learn` normalizes the file to end in a single newline after a real insertion (per spec) and strips leading/trailing blank lines from the candidate; both verified end-to-end.
- One candidate learning appended to `learnings-proposed.md` (bash EXIT-trap exit-status gotcha, observed while fixing `--help`).

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there.

### N. A bash EXIT-trap's last command sets the script's exit status
**Symptom** `ob-learn --help` printed usage correctly but exited 1; `bash -x` showed `+ exit 0` run, then the EXIT trap's `[[ -n '' ]]` as the final executed command.
**Cause** when a trap runs before the shell exits, the exit status of the trap's last command overrides the status passed to `exit` (unless the trap calls `exit` itself).
**Rule** End every EXIT trap on a command guaranteed to succeed (`return 0` in the trap function, or `|| true`), and verify a script's exit status, not just its output, after any refactor around traps.
**Proven** 2026-08-09, story-01 of the learn-command round: changing the cleanup trap's final `[[ ]] && rm` guard to `return 0` fixed `--help`'s exit code from 1 to 0.


## Round 003 (review round 3)

- Addressed the three review items on PR #1, one commit each:
  - `while IFS= read -r line || [[ -n "$line" ]]` in `read_candidate` (both file and stdin
    paths), `next_number` and `write_learnings`, so a candidate whose last line lacks a
    trailing newline is not silently dropped. `printf '### r\n...\n**Proven** d'` (no final
    `\n`) now validates and dry-runs cleanly instead of reporting "missing the **Proven**
    line". The guard is latent in the two LEARNINGS.md readers (file ends in newline).
  - `.ob-learn.tmp.*` added to `.gitignore` under "Operator-local config", so an interrupted
    run's leftover temp file is never `git add -A`-ed into the public repo.
  - `main` now declares `local line`; `--dry-run` prints the section via
    `section_display_name` (`Rules the implementer must follow` / `Environment truths`),
    matching the write path.
- Also took the reviewer's optional item: duplicate label lines are now rejected
  ("candidate repeats the **...** label") instead of silently skipped.
- `LEARNINGS.md` unmodified in the final commit; restored via `git checkout` after each real
  insertion test.

## Round 3 — 2026-08-09T06:51:26Z

Review-response round by `ob-respond` (attempt 3 of 6).

- action: respond to review
- pull request: #1
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 5
- cost: 0.03352753152 USD

### Agent summary

The LEARNINGS.md diff vs main is **pre-existing drift**, not mine: `git log origin/main..HEAD -- LEARNINGS.md` is empty — no commit on this branch touched it, and the worktree is clean. Main gained a 12th entry and rewrote rules-item 5 after this branch diverged; ob-learn numbers dynamically (`highest + 1`), so nothing to change, and the review explicitly forbids touching LEARNINGS.md. Noting it for the reviewer.

All work complete and pushed (`240cf87..aa55f01`).

## Summary
Fixed all three review items on `local/bin/ob-learn`, one commit each: guarded every `while IFS= read -r` loop with `|| [[ -n "$line" ]]` so a candidate whose last line lacks a trailing newline is no longer silently dropped (the exact `printf` repro now validates cleanly); added `.ob-learn.tmp.*` to `.gitignore` next to the operator-local entries; and declared `local line` in `main` while making `--dry-run` print the section via `section_display_name`, matching the write path. Also took the reviewer's optional item — repeated label lines are now rejected instead of silently accepted. `LEARNINGS.md` is unmodified in the final commit.

## Feedback
- `local/bin/ob-learn` `read_candidate`/`next_number`/`write_learnings`: fixed — all four read loops guard the final unterminated line; repro `printf '### r\n**Symptom** a\n**Cause** b\n**Rule** c\n**Proven** d' | ob-learn --section implementer --dry-run` now prints the entry and exits 0.
- `.gitignore`: fixed — `.ob-learn.tmp.*` added with a comment; `git check-ignore .ob-learn.tmp.ABC123` now confirms ignored.
- `main` `line` global: fixed — `local line` declared; `--dry-run` prints `section: Rules the implementer must follow` / `section: Environment truths`, consistent with the insert path.
- Duplicate labels (optional item): fixed — `**Symptom**` twice is now rejected with `candidate repeats the **Symptom** label`; it was ~5 lines, so I took it.

## Verification
- `make lint` (with shellcheck 0.10.0 on PATH; repo command skips when absent) -> exit 0, all 4 shell scripts-paths clean; `shellcheck -x -S warning local/bin/ob-learn` -> exit 0
- reviewer's no-newline repro -> entry accepted, exit 0; `--dry-run` both sections -> LEARNINGS.md byte-identical; missing `**Proven**`, bad heading, out-of-order labels -> exit 1 with the naming message; duplicate `**Symptom**` -> exit 1 naming the label
- real `--section implementer` insert -> `### 12.` as last entry before `## Environment truths`; `--section environment` -> `### 12.` at file end, single trailing newline; both restored with `git checkout`
- deny list (via `OPENBUILDER_SCRUB_DENY`) -> exit 1, stdout 0 bytes, count-only stderr, LEARNINGS.md byte-identical; non-matching list proceeds
- `--help` with blocking stdin -> usage on stdout, exit 0; `-f` file without trailing newline and candidate with trailing blanks -> handled; `git status` clean, `LEARNINGS.md` unmodified vs branch tip

## Still open
- none from the review. (Note: the branch's `LEARNINGS.md` predates two newer commits on `main` — the 12th learning and a rewrite of editing-rule 5; `ob-learn` numbers dynamically so this needs no change here, but expect a merge-time file resolution. One candidate learning appended to `learnings-proposed.md`.)

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there.

### N. `while IFS= read -r` silently drops a final line without a trailing newline
**Symptom** `ob-learn` rejected a perfectly valid candidate with `candidate is missing the **Proven** line` although the `**Proven** d` line was right there — the input had been produced by `printf` without a final `\n`.
**Cause** `while IFS= read -r line` runs its body only while `read` returns success, and `read` returns failure on end-of-input, discarding a final unterminated line instead of yielding it and failing after.
**Rule** When the input's final newline is not guaranteed, guard the loop with `|| [[ -n "$line" ]]` so an unterminated last line is still processed. A diagnostic that blames the data for the reader's own handling is worse than one that says it does not know.
**Proven** 2026-08-09, review round 3 of the learn-command story: the guard was added to all three `read` loops in `local/bin/ob-learn` and the exact repro (`printf '### r\n…\n**Proven** d'` without `\n`) then validated and dry-ran cleanly.


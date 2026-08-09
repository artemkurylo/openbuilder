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
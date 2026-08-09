---
id: story-01-ob-learn
title: Add local/bin/ob-learn to append a validated entry to LEARNINGS.md
size: S
depends_on: []
files:
  - local/bin/ob-learn
acceptance:
  - "local/bin/ob-learn exists, is executable, and starts with the shebang #!/usr/bin/env bash"
  - "shellcheck -x -S warning local/bin/ob-learn exits 0"
  - "ob-learn --help prints usage and exits 0 without reading stdin"
  - "with no --section argument the command exits non-zero and its message names the two accepted values"
  - "a candidate missing any one of the four **Symptom** / **Cause** / **Rule** / **Proven** lines is rejected with exit 1 and a message naming exactly which line is missing"
  - "a candidate whose first non-blank line is not a level-3 markdown heading is rejected with exit 1"
  - "a valid candidate is inserted with the number one higher than the highest existing ### N. in LEARNINGS.md"
  - "a candidate inserted with --section implementer lands as the last entry of the 'Rules the implementer must follow' section, before the '## Environment truths' heading"
  - "a candidate inserted with --section environment lands as the last entry of the file"
  - "--dry-run prints the numbered entry and the target section to stdout and leaves LEARNINGS.md byte-identical"
  - "when a deny list is present and the candidate matches it, the command exits 1, prints no line of the candidate, and does not modify LEARNINGS.md"
  - "every failure exits non-zero and writes its message to stderr, never to stdout"
---

## Context

You are working in the openbuilder control repository itself. Read `LEARNINGS.md` at the repo root before
you write anything: it is both the data this command edits and the specification of the entry shape.

What you need to know:

- `LEARNINGS.md` has exactly two entry sections, in this order: `## Rules the implementer must follow`
  and `## Environment truths`. Entries are level-3 markdown headings numbered across the whole file, not
  per section: `### 1.` … `### 5.` are under the first heading, `### 6.` … `### 11.` under the second.
- An entry is a `### N. <imperative rule>` heading followed by four bold-labelled lines in this order:
  `**Symptom**`, `**Cause**`, `**Rule**`, `**Proven**`. One entry — learning 4 — deliberately has
  `**Why it is here**` instead of `**Symptom**` and `**Proven**`; that is an existing exception and you
  must not "fix" it, but you also do not need to accept that shape as input.
- The deny list mechanism already exists in `local/bin/ob-scrub-check`. Read it. It resolves
  `$OPENBUILDER_SCRUB_DENY`, else `.scrub-deny` at the repo root, one extended regex per line, ignoring
  blank lines and lines starting with `#`. It is gitignored and is usually absent on a fresh clone.
- `ob-scrub-check` never prints matching text, on purpose: a check that echoes the string it protects has
  leaked it. `ob-learn` must hold the same line.
- Existing shell style in this repo, which you must follow: `#!/usr/bin/env bash`, then
  `set -euo pipefail`, then `IFS=$'\n\t'`, a header comment block that explains *why* the script exists,
  two-space indentation, `local` for every function variable, and long single-purpose functions over
  clever one-liners. `local/bin/ob-scrub-check` is the closest model — copy its shape.
- There is no test framework in this repository. Verification is `shellcheck` plus running the command,
  which is what the acceptance list is written against.

## Change

1. Create `local/bin/ob-learn`, executable, following the style notes above. Its header comment must say
   what it is for: turning an accepted candidate learning into a correctly numbered, correctly placed
   entry, without hand-editing.

2. Interface:

   ```
   ob-learn --section implementer|environment [-f FILE] [--dry-run]
   ob-learn --help
   ```

   The candidate is read from `FILE` when `-f` is given, otherwise from stdin. `--section` is required;
   with it missing or holding any other value, fail with a message naming both accepted values.
   `--help` prints the usage and exits 0 and must not block on stdin.

3. Validate the candidate before touching anything, and report the first problem you find:
   - the first non-blank line must match `^### ` (a level-3 heading);
   - the four labels `**Symptom**`, `**Cause**`, `**Rule**` and `**Proven**` must each appear at the
     start of a line, in that order;
   - a missing label is an error whose message names that label.

   Reject with exit 1 and put the message on stderr.

4. If a deny list resolves (same resolution order as `ob-scrub-check`), match the candidate against it
   case-insensitively. On a match: exit 1, say how many lines matched and that nothing was printed on
   purpose, print none of the candidate, and leave `LEARNINGS.md` untouched. Absence of a deny list is
   not an error.

5. Numbering: find the highest `### N.` anywhere in `LEARNINGS.md` and use `N + 1`. Rewrite the
   candidate's heading with that number, preserving the rest of the heading text verbatim. Do not
   renumber existing entries.

6. Placement:
   - `--section implementer` inserts the entry so it becomes the last entry under
     `## Rules the implementer must follow`, immediately before the `## Environment truths` heading;
   - `--section environment` appends the entry at the end of the file.
   In both cases keep exactly one blank line between the previous entry and the new heading, and leave
   the file ending in a single newline.

7. `--dry-run` prints the fully numbered entry and the section it would land in, to stdout, and makes no
   change to `LEARNINGS.md`.

8. Write `LEARNINGS.md` atomically: build the new content in a temporary file and move it into place, so
   an interrupted run cannot leave the store truncated. Clean the temporary file up on exit.

## Verification

There is no test runner here, so verify by running the thing, and state each result in your final
message:

1. `shellcheck -x -S warning local/bin/ob-learn` exits 0.
2. `local/bin/ob-learn --help` prints usage, exits 0.
3. A candidate missing `**Proven**` is rejected and the message names `**Proven**`.
4. A candidate whose first line is `## not a level three heading` is rejected.
5. `--dry-run` with a valid candidate prints `### 12.` (the current highest is 11) and
   `git diff --stat -- LEARNINGS.md` reports no change afterwards.
6. A real insertion with `--section implementer` puts `### 12.` immediately before
   `## Environment truths`; then `git checkout -- LEARNINGS.md` to restore the file.
7. A real insertion with `--section environment` puts `### 12.` at the end of the file; restore again.
8. With a temporary deny list containing a pattern the candidate matches (point
   `OPENBUILDER_SCRUB_DENY` at it), the command exits 1 and `LEARNINGS.md` is unchanged.

**Leave `LEARNINGS.md` unmodified in your final commit.** It is the store, not a fixture: the only file
this story adds is `local/bin/ob-learn`. If `git status` shows `LEARNINGS.md` as modified when you are
done, restore it.

#!/usr/bin/env bash
# assert-style.sh — a regression guard for LEARNINGS 22.
#
# LEARNINGS 22: `grep -c "^{{PRD}}$" runner/prompts/implement.md` printed 0 for a
# file containing exactly that line, and `grep -c "docs(epic): PRD and RFC for"`
# printed 0 for a file containing exactly that text. Under an extended-regex grep
# `{ } ( )` are metacharacters, so a pattern copied out of expected output stops
# being a literal — and nothing in the result distinguishes "did not match" from
# "text is absent". A detector that cannot match reports a clean pass or refuses
# correct work, and both look like the check working.
#
# So this case scans the repository's own shell scripts for that shape and fails
# on each occurrence, naming file and line.
#
# THE DETECTION IS A HEURISTIC. It reads one line at a time and cannot know what
# a shell expansion will hold, so it is deliberately biased towards silence:
#
#   flagged   a grep call whose first pattern argument is a literal (quoted or
#             bare) that contains `(`, `)`, or a brace that cannot be an interval
#             expression (`{{`, `{PRD}` — as opposed to `{1,3}`), and whose option
#             cluster carries no `-F`/`--fixed-strings`.
#   not flagged
#             `-F` anywhere in a short-option cluster, or `--fixed-strings`;
#             a pattern taken from a file (`-f FILE`);
#             a pattern that also uses `^ $ | [ + *` or a backslash escape, which
#             marks deliberate regex intent — note this makes any pattern that is
#             a variable expansion ("$needle") invisible to the guard, because its
#             content is unknown at scan time;
#             any line carrying the marker comment `# grep-regex-ok`;
#             any whole-line shell comment, which is prose or dead code and can
#             never be a call site (this file's own header being the example).
#
# Consequences of the bias: a literal `(` inside a genuine regex that also uses
# `|` is not flagged, and a bad pattern hidden in a variable is not flagged. It
# catches the family that actually bit this repository twice in one day; it is not
# a proof.
#
# The guard is asserted against a fixture with known-bad and known-good lines
# before it is pointed at the repository, so a guard that has silently stopped
# detecting anything fails here rather than reporting the repo clean.
#
# Hermetic: python3 stdlib over files already on disk. No network.

# shellcheck source=tests/lib.sh
source "$TESTS_LIB"

work="$(tmpdir)"
detector="${work}/assert_style.py"

cat >"$detector" <<'PY'
"""Report shell lines that hand a literal-looking pattern to grep without -F."""
import re
import sys

TOKEN = re.compile(
    '"(?:\\\\.|[^"\\\\])*"'
    "|\\$?'(?:\\\\.|[^'\\\\])*'"
    '|[^\\s;|&<>()`]+'
)
GREP = re.compile('(?:^|[\\s;|&(`$])(?:git[ \\t]+)?grep\\b')
INTERVAL = re.compile('\\{[0-9]+(,[0-9]*)?\\}')
REGEX_INTENT = ('^', '$', '|', '[', '+', '*', '\\')
OPTS_TAKING_NON_PATTERN = ('-f', '-m', '--file', '--max-count')
OPTS_TAKING_PATTERN = ('-e', '--regexp')
MARKER = '# grep-regex-ok'


def unquote(t):
    if len(t) >= 2 and t[0] == t[-1] and t[0] in '"\'':
        return t[1:-1]
    if t.startswith("$'") and t.endswith("'"):
        return t[2:-1]
    return t


def pattern_of(seg):
    """(has_F, first pattern argument) for one grep call's argument text."""
    toks = [m.group(0) for m in TOKEN.finditer(seg)]
    fixed = False
    pattern = None
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == '--':
            if i + 1 < len(toks):
                pattern = toks[i + 1]
            break
        if t.startswith('-') and len(t) > 1:
            if t in OPTS_TAKING_NON_PATTERN:
                i += 2
                continue
            if t in OPTS_TAKING_PATTERN:
                if i + 1 < len(toks):
                    pattern = toks[i + 1]
                break
            if t == '--fixed-strings' or (not t.startswith('--') and 'F' in t):
                fixed = True
            i += 1
            continue
        pattern = t
        break
    return fixed, pattern


def literal_braces(p):
    """A brace that cannot be part of an interval expression is meant literally."""
    stripped = INTERVAL.sub('', p)
    return '{' in stripped or '}' in stripped


def suspicious(p):
    if literal_braces(p):
        return True
    if any(r in p for r in REGEX_INTENT):
        return False
    return '(' in p or ')' in p


def offenders(path, text):
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        if MARKER in raw:
            continue
        line = raw.strip()
        if line.startswith('#'):
            continue
        for m in GREP.finditer(line):
            fixed, pattern = pattern_of(line[m.end():])
            if fixed or pattern is None:
                continue
            if not suspicious(unquote(pattern)):
                continue
            out.append('%s:%d: %s' % (path, n, line))
            break
    return out


def main(argv):
    for path in argv:
        try:
            fh = open(path, 'r')
        except IOError:
            continue
        try:
            text = fh.read()
        except (IOError, ValueError):
            continue
        finally:
            fh.close()
        for line in offenders(path, text):
            sys.stdout.write(line + '\n')
    return 0


sys.exit(main(sys.argv[1:]))
PY

# --- the guard is asserted against a fixture first ---------------------------
# Every payload below is single-quoted with `grep` as its first word, so in THIS
# file the word is preceded by a quote and is not a call site the guard can see —
# that is why the commented payload puts its `#` in printf's format string rather
# than in the payload. The repository scan further down proves the property holds,
# since the scanned set includes this file.

fixture="${work}/fixture.sh"
{
  printf '%s\n' 'grep -q "docs(epic): PRD and RFC for" f.md'
  printf '%s\n' 'grep -qF "docs(epic): PRD and RFC for" f.md'
  printf '%s\n' 'grep -c "^{{PRD}}$" f.md'
  printf '%s\n' 'grep -qE "^(prd|rfc)$" f.md'
  printf '%s\n' 'grep -q "retry{1,3}" f.md'
  printf '%s\n' 'grep -q "epic(name)" f.md # grep-regex-ok'
  printf '%s\n' 'git grep -I -i -E -c -f "$PATTERNS" --'
  printf '%s\n' 'grep -q "a plain literal" f.md'
  printf '# %s\n' 'grep -q "docs(epic): commented out" f.md'
} >"$fixture"

flagged="$(python3 "$detector" "$fixture")"

count_lines() {
  local n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
  done <<EOF
${1-}
EOF
  printf '%s\n' "$n"
}

assert_contains 'fixture.sh:1:' "$flagged" \
  'the guard flags a parenthesised literal handed to grep without -F'
assert_contains 'fixture.sh:3:' "$flagged" \
  'the guard flags literal braces even when the pattern is anchored'
assert_not_contains 'fixture.sh:2:' "$flagged" \
  'the guard accepts the same pattern once -F is present'
assert_not_contains 'fixture.sh:4:' "$flagged" \
  'the guard accepts a genuine regex using alternation'
assert_not_contains 'fixture.sh:5:' "$flagged" \
  'the guard accepts a real interval expression'
assert_not_contains 'fixture.sh:6:' "$flagged" \
  'the guard honours the # grep-regex-ok marker'
assert_not_contains 'fixture.sh:7:' "$flagged" \
  'the guard ignores a pattern read from a file with -f'
assert_not_contains 'fixture.sh:8:' "$flagged" \
  'the guard ignores a literal with no metacharacters'
assert_not_contains 'fixture.sh:9:' "$flagged" \
  'the guard ignores a whole-line comment that quotes a bad call'
assert_eq '2' "$(count_lines "$flagged")" \
  'the guard flags exactly the two bad fixture lines and nothing else'

# --- and then at the repository ----------------------------------------------
# cwd is the repo root (tests/run guarantees it), so the reported paths are
# relative and the labels below name a real file and line.

scanned=()
for f in local/bin/* runner/bin/* tests/run tests/*.sh tests/cases/*.sh; do
  [ -f "$f" ] || continue
  scanned+=("$f")
done

offenders="$(python3 "$detector" "${scanned[@]}")"

assert_eq '' "$offenders" \
  'no shell script in local/bin, runner/bin or tests hands a literal pattern to grep without -F'

while IFS= read -r offender; do
  [ -n "$offender" ] || continue
  where="${offender%%: *}"
  assert_eq '' "$offender" \
    "${where} hands a literal pattern to grep without -F"
done <<EOF
${offenders}
EOF

exit 0

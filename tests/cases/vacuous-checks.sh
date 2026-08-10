#!/usr/bin/env bash
# vacuous-checks.sh — the two checks this repository runs on itself that report
# success while checking nothing.
#
# Measured 2026-08-09 and pinned here:
#
#   make scrub  in any fresh worktree exits 0 and prints "nothing to check."
#               because the deny list is gitignored on purpose and is therefore
#               absent from every worktree, on every machine, always.
#   make lint   with shellcheck off PATH exits 0 and prints "skipping lint."
#
# Both are deliberate designs, and both mean a green run is not evidence. That
# matters because auto-merge treats these as its substitute for CI. So what is
# asserted here is not "the check passes" — it is that the two outcomes are
# distinguishable by their output and NOT by their exit status, and that the
# fixed strings the rest of the repo greps for actually discriminate.
#
# Hermetic: one detached worktree of this repository plus temp files. No network.
# The worktree is created after nothing else can fail and removed before any
# assertion runs, so no exit path can leave one behind.

# shellcheck source=tests/lib.sh
source "$TESTS_LIB"

# A deny-list pattern that cannot match anything in this repository, built at
# runtime so the literal never appears in this file — which is itself one of the
# tracked files `make scrub` scans.
nomatch="$(printf 'z%.0s' {1..40})"

# PATH with every directory that holds a shellcheck removed, so `make lint` takes
# its skip branch. PATH itself is never modified: this value is passed to the one
# command that needs it.
path_without_shellcheck() {
  local out='' p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -x "${p}/shellcheck" ]; then
      continue
    fi
    if [ -z "$out" ]; then
      out="$p"
    else
      out="${out}:${p}"
    fi
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  printf '%s\n' "$out"
}

deny="$(tmpdir)/deny.txt"
{
  printf '# fixture deny list — comments and blanks are ignored\n'
  printf '\n'
  printf '%s\n' "$nomatch"
} >"$deny"

# A shellcheck that does nothing: `make lint`'s run branch is what is under test,
# not shellcheck's verdict on this repository. A stub keeps the assertion about
# the Makefile and keeps the run deterministic and fast.
stub_bin="$(tmpdir)"
printf '#!/bin/sh\nexit 0\n' >"${stub_bin}/shellcheck"
chmod 0755 "${stub_bin}/shellcheck"

# --- capture every measurement, then tear the worktree down ------------------

worktree="$(tmpdir)/wt"
git -C "$TESTS_ROOT" worktree prune >&2
git -C "$TESTS_ROOT" worktree add --detach -q "$worktree" HEAD >&2

scrub_bare_out="$(make -C "$worktree" scrub 2>&1)"
scrub_bare_rc=$?

scrub_deny_out="$(OPENBUILDER_SCRUB_DENY="$deny" make -C "$worktree" scrub 2>&1)"
scrub_deny_rc=$?

lint_present_out="$(PATH="${stub_bin}:${PATH}" make -C "$worktree" lint 2>&1)"
lint_present_rc=$?

lint_absent_out="$(PATH="$(path_without_shellcheck)" make -C "$worktree" lint 2>&1)"
lint_absent_rc=$?

git -C "$TESTS_ROOT" worktree remove --force "$worktree" >&2
git -C "$TESTS_ROOT" worktree prune >&2
worktree_list="$(git -C "$TESTS_ROOT" worktree list 2>&1)"

# --- make scrub: the vacuous run and the real one ----------------------------

assert_eq '0' "$scrub_bare_rc" \
  'make scrub in a fresh worktree exits 0 with no deny list present'
assert_contains 'nothing to check.' "$scrub_bare_out" \
  'the vacuous scrub says so in its output: nothing to check'
assert_not_contains 'clean (worktree).' "$scrub_bare_out" \
  'the vacuous scrub never claims the worktree is clean'

assert_eq '0' "$scrub_deny_rc" \
  'make scrub with a deny list on a clean tree also exits 0'
assert_contains 'clean (worktree).' "$scrub_deny_out" \
  'the real scrub reports a clean worktree'
assert_contains 'clean (history).' "$scrub_deny_out" \
  'the real scrub reports clean history — make scrub runs both modes'
assert_not_contains 'nothing to check.' "$scrub_deny_out" \
  'the real scrub never claims there was nothing to check'

# The punchline: the exit status is identical, so only the output distinguishes
# "checked everything, found nothing" from "checked nothing".
assert_eq "$scrub_bare_rc" "$scrub_deny_rc" \
  'checking nothing and checking everything exit with the same status'

# --- make lint: skipped and not skipped --------------------------------------

assert_eq '0' "$lint_absent_rc" \
  'make lint exits 0 with shellcheck absent from PATH'
assert_contains 'skipping lint.' "$lint_absent_out" \
  'the skipped lint says so in its output: skipping lint'
assert_not_contains 'shellcheck -x -S warning' "$lint_absent_out" \
  'the skipped lint never prints a shellcheck invocation'

assert_eq '0' "$lint_present_rc" \
  'make lint exits 0 with a shellcheck on PATH'
assert_contains 'shellcheck -x -S warning' "$lint_present_out" \
  'the real lint prints the shellcheck invocation it runs'
assert_contains 'local/bin/ob-gate' "$lint_present_out" \
  'the real lint enumerates the scripts, so the file list is not empty'
assert_not_contains 'skipping lint.' "$lint_present_out" \
  'the real lint never claims it was skipped'
assert_not_contains 'nothing to lint.' "$lint_present_out" \
  'the real lint never claims there were no scripts to lint'

# --- the test leaves no worktree behind --------------------------------------

assert_not_contains "$worktree" "$worktree_list" \
  'the worktree this case created is gone from git worktree list'

exit 0

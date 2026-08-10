#!/usr/bin/env bash
# tests/lib.sh — SOURCED-ONLY assertion and fixture library for the openbuilder
# test suite. Single responsibility: give a case file the whole vocabulary it is
# allowed to use, so no case file ever prints a result line or cleans up a temp
# directory by hand.
#
# Usage (from a case file):  source "$TESTS_LIB"
#
# Case files must not install their own EXIT trap: this library owns it and uses
# it to remove every temp path it handed out, on every exit path.
#
# A case file is normally also sourcing the library under test, and those
# libraries turn on `set -euo pipefail` and `IFS=$'\n\t'`. Everything here is
# written to survive that: no bare `cmd; rc=$?`, no unquoted expansion, no
# `[[ ... ]] && ...` statement whose false branch would trip errexit.

# Result lines are emitted WITHOUT a number ("ok - <label>"); tests/run
# renumbers them so numbering is global across case files. Any other line a case
# file prints on stdout is passed through by the runner as a `#` diagnostic.

# Reason string set by `todo`; while non-empty, a failing assertion is expected
# and a passing one is a failure.
_OB_T_TODO=''

# Every temp path handed out lives under this root, so cleanup is one rm -rf
# and `tmpdir` stays safe to call from inside a command substitution (where an
# array or variable update in the subshell would have been lost).
_OB_T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/obtest.XXXXXX")"

# Case file name, used to label a SKIP. BASH_SOURCE[1] is the file sourcing us.
_OB_T_CASE="$(basename -- "${BASH_SOURCE[1]:-$0}")"

_ob_t_cleanup() {
  if [ -n "${_OB_T_ROOT:-}" ] && [ -d "$_OB_T_ROOT" ]; then
    chmod -R u+rwX "$_OB_T_ROOT" 2>/dev/null || true
    rm -rf -- "$_OB_T_ROOT" || true
  fi
}
trap _ob_t_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# _ob_t_show <value> — render a value as one quoted line, so a diagnostic can
# never be mistaken for a result line.
_ob_t_show() {
  local v="${1-}"
  v="${v//$'\n'/\\n}"
  v="${v//$'\t'/\\t}"
  printf "'%s'" "$v"
}

_ob_t_pass() {
  local label="${1-}"
  if [ -n "$_OB_T_TODO" ]; then
    printf 'not ok - %s # TODO PASSED UNEXPECTEDLY (%s)\n' "$label" "$_OB_T_TODO"
  else
    printf 'ok - %s\n' "$label"
  fi
}

# _ob_t_fail <label> [diagnostic...] — diagnostics are printed only for a real
# failure; under `todo` the failure is the expected outcome and stays quiet.
_ob_t_fail() {
  local label="${1-}"
  shift || true
  if [ -n "$_OB_T_TODO" ]; then
    printf 'ok - %s # TODO %s\n' "$label" "$_OB_T_TODO"
    return 0
  fi
  printf 'not ok - %s\n' "$label"
  local d
  for d in "$@"; do
    printf '  %s\n' "$d"
  done
}

# assert_eq <expected> <actual> <label>
assert_eq() {
  local expected="${1-}" actual="${2-}" label="${3-}"
  if [ "$expected" = "$actual" ]; then
    _ob_t_pass "$label"
  else
    _ob_t_fail "$label" \
      "expected: $(_ob_t_show "$expected")" \
      "actual:   $(_ob_t_show "$actual")"
  fi
}

# assert_contains <needle> <haystack> <label> — fixed string, never a regex:
# the needle is quoted inside the case pattern, so (){}[]* are literal.
assert_contains() {
  local needle="${1-}" haystack="${2-}" label="${3-}"
  case "$haystack" in
  *"$needle"*) _ob_t_pass "$label" ;;
  *) _ob_t_fail "$label" \
    "missing: $(_ob_t_show "$needle")" \
    "in:      $(_ob_t_show "$haystack")" ;;
  esac
}

# assert_not_contains <needle> <haystack> <label> — fixed string.
assert_not_contains() {
  local needle="${1-}" haystack="${2-}" label="${3-}"
  case "$haystack" in
  *"$needle"*) _ob_t_fail "$label" \
    "unexpected: $(_ob_t_show "$needle")" \
    "in:         $(_ob_t_show "$haystack")" ;;
  *) _ob_t_pass "$label" ;;
  esac
}

# assert_status <expected-code> <label> -- <cmd> [args...] — run the command
# with its output captured (so it cannot pollute the result stream) and compare
# the exit status. The command runs in a subshell, so a helper that calls `exit`
# is testable here.
assert_status() {
  local expected="${1-}" label="${2-}" sep="${3-}"
  if [ "$sep" != '--' ]; then
    _ob_t_fail "$label" "assert_status: expected '--' before the command, got $(_ob_t_show "$sep")"
    return 0
  fi
  shift 3
  local out='' rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = "$expected" ]; then
    _ob_t_pass "$label"
  else
    _ob_t_fail "$label" \
      "expected status: $(_ob_t_show "$expected")" \
      "actual status:   $(_ob_t_show "$rc")" \
      "output:          $(_ob_t_show "$out")"
  fi
}

# todo <reason> — every assertion after this call is expected to fail. One that
# passes is reported as a failure, which is how a TODO flips when the fix lands.
todo() {
  _OB_T_TODO="${1:-no reason given}"
}

# skip <reason> — end the case file now, reporting one SKIP result with this
# reason. Use it when the contract under test is genuinely not present on this
# branch: a SKIP with the real reason is honest, a green assertion is not.
skip() {
  local reason="${1:-no reason given}"
  printf 'ok - %s: %s # SKIP %s\n' "$_OB_T_CASE" "$reason" "$reason"
  exit 0
}

# skip_unless_live <reason> — the network/AWS/GitHub gate. Emits one SKIP result
# and ends the case file unless OB_TEST_LIVE=1, so live-only checks belong in
# their own file.
skip_unless_live() {
  local reason="${1:-needs network}"
  if [ "${OB_TEST_LIVE:-}" = '1' ]; then
    return 0
  fi
  skip "${reason} - not live (set OB_TEST_LIVE=1)"
}

# tmpdir — print the path of a fresh temp dir, removed when the case file exits.
tmpdir() {
  mktemp -d "${_OB_T_ROOT}/t.XXXXXX"
}

# new_repo — print the path of a fresh temp git repo on branch main with one
# commit, a fixed identity, no signing and no inherited hooks.
new_repo() {
  local d
  d="$(tmpdir)"
  {
    git -C "$d" init -q -b main
    git -C "$d" config core.hooksPath "${d}/.git/hooks-disabled"
    git -C "$d" config commit.gpgsign false
    git -C "$d" config user.email 'tests@openbuilder.invalid'
    git -C "$d" config user.name 'openbuilder tests'
    printf 'seed\n' >"${d}/README.md"
    git -C "$d" add -- README.md
    git -C "$d" commit -q -m 'seed'
  } >&2
  printf '%s\n' "$d"
}

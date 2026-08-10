#!/usr/bin/env bash
# rule 4b parity, the one input the two halves are KNOWN to disagree on: an
# epic state.json that is valid JSON but not an object, e.g. `["dispatched"]`.
#
#   bash   ob-poll gates on `jq -e .`, which a non-empty array satisfies, so it
#          walks on and asks jq for `.stage`. Indexing an array with a string is
#          a jq error, the command substitution yields nothing, and the pass
#          declines with `backlog-unapproved:stage=-`.
#   python waker/github.py gates on `isinstance(state, dict)`, so it declines
#          with `backlog-unapproved:no-state`.
# BOTH halves decline, so the instance stays asleep and no money is spent either
# way; the behaviour is right on both sides and only the reason string differs.
# A future round must unify the WORDING, not change which side declines. Marked
# TODO rather than papered over: when the two strings match this case flips to
# `not ok ... # TODO PASSED UNEXPECTEDLY` and whoever lands the fix sees it.
#
# shellcheck source=tests/lib.sh
source "$TESTS_LIB"
# shellcheck source=tests/rule4b-parity-lib.sh
source "${TESTS_ROOT}/tests/rule4b-parity-lib.sh"

rule4b_skip_unless_present

# rule4b_setup emits the extraction assertions, which are expected to PASS, so it
# has to run before todo takes effect. The parity assertion below is then the only
# assertion this file emits, because under todo a passing assertion is a failure.
rule4b_setup

from_bash="$(rule4b_bash_reason 14-state-json-valid-json-not-an-object)"
from_python="$(rule4b_py_reason 14-state-json-valid-json-not-an-object)"

todo 'both halves correctly decline, only the reason string differs: ob-poll accepts a non-object state.json past jq -e . and reports stage=-, waker/github.py rejects it on isinstance and reports no-state. Unify the wording, do not change which side declines'
assert_eq "$from_bash" "$from_python" \
  'a state.json that is valid JSON but not an object: the two halves agree byte for byte'

#!/usr/bin/env bash
# rule 4b parity — `backlog_decline_reason` is implemented twice, once in bash
# (runner/bin/ob-poll, on the instance) and once in python (waker/github.py, in
# a Lambda that ticks every five minutes). Rule 4b is the gate that decides
# whether the instance powers on and starts spending money, so a one-sided
# change either bills the owner on every tick or never wakes the box at all.
# Every case below asserts the two halves return the SAME string AND that the
# string is the expected one, so a change of wording is caught as well as a
# change of behaviour.
#
# Hermetic: no network, no gh, no token. tests/rule4b-parity-lib.sh explains the
# two injected I/O boundaries and the fixture layout.
#
# shellcheck source=tests/lib.sh
source "$TESTS_LIB"
# shellcheck source=tests/rule4b-parity-lib.sh
source "${TESTS_ROOT}/tests/rule4b-parity-lib.sh"

rule4b_skip_unless_present
rule4b_setup

# --- 1. no epic line on the plan branch's plan.md --------------------------
# Without a well-formed `- epic: <slug>` line there is no epic state to read, so
# there is nothing that could have approved this backlog.
rule4b_parity 01-plan-md-absent 'backlog-unapproved:no-epic-line' \
  'plan.md absent on the plan branch'
rule4b_parity 02-plan-md-without-epic-line 'backlog-unapproved:no-epic-line' \
  'plan.md present but carries no `- epic:` line'
rule4b_parity 03-plan-md-epic-value-backticked 'backlog-unapproved:no-epic-line' \
  'plan.md epic value is backticked, so it is not a slug'

# --- 2. the epic's state.json is unreadable --------------------------------
rule4b_parity 04-state-json-absent 'backlog-unapproved:no-state' \
  "the epic's state.json is absent"
rule4b_parity 05-state-json-unparseable 'backlog-unapproved:no-state' \
  "the epic's state.json is present but unparseable"

# --- 3. the epic is not dispatched -----------------------------------------
# Both halves must render a missing stage key the same way, hence the second
# case: bash gets an empty string out of jq, python gets None, and both have to
# come out as `-`.
rule4b_parity 06-stage-is-backlog 'backlog-unapproved:stage=backlog' \
  'the epic is still at stage backlog'
rule4b_parity 07-stage-key-missing 'backlog-unapproved:stage=-' \
  'the epic state has no stage key at all'

# --- 4. no approval recorded for this slug ---------------------------------
rule4b_parity 08-approval-absent-for-slug 'backlog-unapproved:no-approval' \
  'approvals.backlog has no entry for the slug'
rule4b_parity 09-approval-files-map-empty 'backlog-unapproved:no-approval' \
  "the slug's approval records an empty files map"

# --- 5 and 6. the approved file set no longer matches the branch -----------
# This is the case the gate exists for: a story card edited after the reviewer
# approved the backlog must not be built.
rule4b_parity 10-story-card-edited-after-approval \
  'backlog-unapproved:files-differ(story-01-x.md)' \
  'a story card was edited after approval, so its blob sha moved'
rule4b_parity 11-story-card-added-after-approval \
  'backlog-unapproved:files-differ(story-02-y.md)' \
  'a story card was added after approval, so it is in the listing but not the approval'

# --- 7 and 8. approved: no decline -----------------------------------------
rule4b_parity 12-approved-and-matching '' \
  'fully approved and every card still matches: no decline'
# The trap: ob-implement writes worklog.md into the backlog directory, so every
# slug that has ever been worked on has a file in the listing that no approval
# will ever mention. If either half counted it, every merged slug would fail its
# own gate and the instance would stop waking.
rule4b_parity 13-approved-with-worklog-md '' \
  'approved slug whose listing also carries worklog.md and a subdirectory: still no decline'

# --- no fixture may sit there uncovered ------------------------------------
# The one fixture not asserted on above is the known bash/python divergence,
# which needs a file of its own because it is marked TODO. If that file were
# deleted, its fixture would go unexercised, so this pins the hand-off too.
rule4b_assert_every_fixture_exercised 14-state-json-valid-json-not-an-object
assert_contains '14-state-json-valid-json-not-an-object' \
  "$(cat "${TESTS_ROOT}/tests/cases/rule4b-parity-nonobject-state.sh")" \
  'the one fixture excluded above is still claimed by the sibling TODO case file'

# --- the scrubbing helper both halves use for a reason field ---------------
# safe_field / _safe_field keep only [A-Za-z0-9._-], truncate to the limit, and
# render empty as `-`. It runs on branch content, so it is what stops a hostile
# slug or card name from breaking the `key=value` shape of a DECISION line.
rule4b_safe_field_parity \
  'plan story one.md' 48 'planstoryone.md' \
  'scrub: spaces are dropped' \
  'story-"01".md' 48 'story-01.md' \
  'scrub: quotes are dropped' \
  'evil) reason=owned' 48 'evilreasonowned' \
  'scrub: a value cannot close a files-differ( or inject a key=value pair' \
  $'first line\nsecond' 48 'firstlinesecond' \
  'scrub: a newline cannot split a DECISION line in two' \
  '../../etc/passwd' 32 '....etcpasswd' \
  'scrub: path separators are dropped' \
  '' 32 '-' \
  'scrub: an empty value renders as -' \
  'abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij' 32 \
  'abcdefghijabcdefghijabcdefghijab' \
  'scrub: 60 characters truncate to the 32 limit' \
  'story-07-refactor-the-poll-loop-and-rename-things-again-1.md' 48 \
  'story-07-refactor-the-poll-loop-and-rename-thing' \
  'scrub: a 60-character card name truncates to the 48 limit' \
  'x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x' 32 \
  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
  'scrub: both halves scrub before they truncate, not after'

#!/usr/bin/env bash
# obgate.sh — local/bin/ob-gate, the epic approval gate.
#
# ob-gate is the only thing standing between an edited artifact and a dispatched
# slug: it records the git blob sha of what a human approved and later re-checks
# the bytes on disk against that record. Every assertion below defends one of
# those two halves — that the recorded value is the right value, and that a
# change to the approved bytes is reported as VOID with the command that fixes
# it. A gate that records the wrong bytes, or that reports intact after an edit,
# is worse than no gate at all.
#
# Hermetic: a scratch repo from new_repo plus a bare `origin` in a temp dir, so
# ob-gate's commit-and-push path runs for real with no network.

# shellcheck source=tests/lib.sh
source "$TESTS_LIB"

GATE="${TESTS_ROOT}/local/bin/ob-gate"

repo="$(new_repo)"
origin="$(tmpdir)/origin.git"
git init -q --bare -- "$origin" >&2
git -C "$repo" remote add origin "$origin"

epic='demo-epic'
slug='demo-slug'
epic_dir="${repo}/.openbuilder/epics/${epic}"
slug_dir="${repo}/.openbuilder/backlog/${slug}"
state="${epic_dir}/state.json"
prd_rel=".openbuilder/epics/${epic}/prd.md"

# ob-gate resolves the repository from the working directory, so every call runs
# in a subshell that has cd'd into the scratch repo.
gate() {
  (cd "$repo" && "$GATE" "$@")
}

field() {
  jq -r --arg k "$1" '.[$k] // ""' "$state"
}

show_field() {
  printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2 }'
}

mkdir -p -- "$epic_dir" "$slug_dir"

# --- init and show -----------------------------------------------------------

out="$(gate init "$epic" --repo o/r 2>&1)"
assert_contains "opened epic ${epic} at stage intake" "$out" \
  'init reports the epic it opened and the stage it opened it at'
assert_eq 'intake' "$(field stage)" \
  'init writes state.json at stage intake'
assert_eq "$epic" "$(field epic)" \
  'init records the epic name in state.json'

shown="$(gate show "$epic" 2>&1)"
assert_eq "$epic" "$(show_field "$shown" epic)" 'show prints the epic'
assert_eq 'o/r' "$(show_field "$shown" repo)" 'show prints the repo'
assert_eq 'intake' "$(show_field "$shown" stage)" 'show prints the stage'

# --- record prd --------------------------------------------------------------

printf 'the product requirements\n' >"${epic_dir}/prd.md"

# An approval whose sha describes bytes that are not in a commit describes bytes
# nobody can retrieve. Recording must refuse rather than record that.
assert_status 1 'record refuses a prd.md that is not committed at HEAD' \
  -- gate record "$epic" prd

git -C "$repo" add -A >&2
git -C "$repo" commit -q -m 'prd' >&2

out="$(gate record "$epic" prd 2>&1)"
assert_contains "recorded prd approval for ${epic}" "$out" \
  'record reports the approval it recorded'

# The whole value of the record is that it is the git blob sha of the approved
# file. Anything else silently approves different bytes than the human read.
assert_eq "$(git -C "$repo" rev-parse "HEAD:${prd_rel}")" \
  "$(jq -r '.approvals.prd.blob' "$state")" \
  'the recorded prd sha is the git blob sha of the approved file'

assert_status 0 'verify prd exits 0 while the approved bytes are intact' \
  -- gate verify "$epic" prd
out="$(gate verify "$epic" prd 2>&1)"
assert_contains 'prd intact' "$out" 'verify reports prd intact'

# --all with rfc and backlog still unrecorded is ABSENT (4), not intact and not
# void: "nothing was ever approved" must not read the same as "approved and
# unchanged".
assert_status 4 'verify --all exits 4 while rfc and backlog are unrecorded' \
  -- gate verify "$epic" --all
out="$(gate verify "$epic" --all 2>&1)"
assert_contains 'rfc ABSENT' "$out" 'verify --all names the unrecorded target'

# --- an edited prd.md voids the approval -------------------------------------
# This is the contract the whole workflow rests on.

printf 'and one sentence a model slipped in\n' >>"${epic_dir}/prd.md"

assert_status 3 'verify exits 3 once prd.md changed since approval' \
  -- gate verify "$epic" prd
out="$(gate verify "$epic" prd 2>&1)"
assert_contains 'prd VOID' "$out" 'verify reports prd VOID after an edit'
assert_not_contains 'prd intact' "$out" \
  'verify never reports intact for changed bytes'
assert_contains "fix: ob-gate record ${epic} prd" "$out" \
  'the VOID message names the exact command that re-approves'

git -C "$repo" checkout -- "$prd_rel" >&2
assert_status 0 'verify is clean again once prd.md is restored' \
  -- gate verify "$epic" prd

# --- record rfc and backlog --------------------------------------------------

printf 'the design\n' >"${epic_dir}/rfc.md"
printf 'the plan\n' >"${slug_dir}/plan.md"
printf 'first card\n' >"${slug_dir}/story-01-first.md"
printf 'second card\n' >"${slug_dir}/story-02-second.md"
git -C "$repo" add -A >&2
git -C "$repo" commit -q -m 'rfc and backlog' >&2

out="$(gate record "$epic" rfc 2>&1)"
assert_contains "recorded rfc approval for ${epic}" "$out" \
  'record reports the rfc approval'

out="$(gate record "$epic" backlog "$slug" 2>&1)"
assert_contains '3 file(s)' "$out" \
  'record backlog counts plan.md and both story cards'

assert_status 0 'verify --all exits 0 with prd, rfc and backlog all intact' \
  -- gate verify "$epic" --all
out="$(gate verify "$epic" --all 2>&1)"
assert_contains 'prd intact' "$out" 'verify --all reports prd intact'
assert_contains "backlog/${slug} intact 3 file(s)" "$out" \
  'verify --all reports the approved file count for the slug'

# --- worklog.md must not void an intact approval -----------------------------
# The implementer writes it during the round; no human approved it, so it is not
# part of what was approved and must not void what was.

printf 'round 1: started\n' >"${slug_dir}/worklog.md"
assert_status 0 'a worklog.md in the backlog directory does not void the approval' \
  -- gate verify "$epic" --all
out="$(gate verify "$epic" --all 2>&1)"
assert_not_contains 'VOID' "$out" 'worklog.md is never reported as a change'
assert_contains "backlog/${slug} intact" "$out" \
  'the slug is still intact with a worklog.md present'

# --- an edited card voids the slug -------------------------------------------

printf 'a requirement nobody approved\n' >>"${slug_dir}/story-02-second.md"
assert_status 3 'verify exits 3 once a story card changed' \
  -- gate verify "$epic" backlog
out="$(gate verify "$epic" backlog 2>&1)"
assert_contains "backlog/${slug} VOID" "$out" 'the VOID names the slug'
assert_contains 'story-02-second.md changed since approval' "$out" \
  'the VOID names the card that changed'
assert_contains "fix: ob-gate record ${epic} backlog ${slug}" "$out" \
  'the slug VOID message names the exact command that re-approves'
git -C "$repo" checkout -- ".openbuilder/backlog/${slug}/story-02-second.md" >&2

# --- an added card voids the slug too ----------------------------------------
# A new card is as much a change to the approved set as an edited one.

printf 'a card that appeared after approval\n' >"${slug_dir}/story-03-third.md"
assert_status 3 'verify exits 3 once an unapproved story card appears' \
  -- gate verify "$epic" backlog
out="$(gate verify "$epic" backlog 2>&1)"
assert_contains 'story-03-third.md is not covered by the approval' "$out" \
  'the VOID names the card that is not covered by the approval'
rm -f -- "${slug_dir}/story-03-third.md"
assert_status 0 'verify is clean again once the extra card is gone' \
  -- gate verify "$epic" --all

# --- stage pointer: advance-only ---------------------------------------------
# REAL DEFECT on this branch. record_artifact computes the next stage from the
# artifact it recorded and writes it unconditionally, so re-approving prd.md on
# an epic that already reached `dispatched` rewinds the pointer to `rfc`. Rule 4b
# then declines every slug cut from that plan branch, as action=skip: no attempt,
# no label, no comment. Carded as plan-workflow-06-automerge story-01, not yet
# fixed, so the expectation below is registered as a TODO — it is red on purpose
# and flips to a visible failure ("TODO PASSED UNEXPECTEDLY") the moment the fix
# lands.
#
# Stage and timestamp are asserted as one value on purpose: a "fix" that refuses
# the whole re-record would leave the stage at `dispatched` while recording
# nothing, and must not pass this test by accident.

gate stage "$epic" dispatched >/dev/null 2>&1
at_before="$(jq -r '.approvals.prd.at' "$state")"
# approvals.prd.at has one-second resolution; sleep so a fresh record is visible.
sleep 1
gate record "$epic" prd >/dev/null 2>&1
at_after="$(jq -r '.approvals.prd.at' "$state")"
if [ "$at_after" != "$at_before" ]; then
  recorded='fresh-timestamp'
else
  recorded='stale-timestamp'
fi

todo 'fails until plan-workflow-06-automerge story-01 lands'
assert_eq 'dispatched fresh-timestamp' "$(field stage) ${recorded}" \
  're-recording prd on a dispatched epic keeps the stage and records a fresh approval'

exit 0

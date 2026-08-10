#!/usr/bin/env bash
# runner-epic-docs.sh — the epic-document helpers in runner/bin/ob-common.sh:
# ob_epic_name, ob_epic_doc and ob_epic_docs_commit.
#
# These three decide what reasoning survives a merged PR and a deleted branch,
# and every one of them is on the "degrade, never fail the round" side of the
# contract. Until now they were only ever checked by hand.
#
# Hermetic: git against local temp repos only, no network, no AWS, no gh.

# shellcheck source=tests/lib.sh
source "$TESTS_LIB"

# The library under test is sourced-only and expects an operating environment.
# /dev/null as the env file keeps the frozen defaults and reads nothing from the
# host; OPENBUILDER_HOME in a temp dir keeps its mkdir/chmod off the real tree.
OB_PROG='runner-epic-docs.test'
OPENBUILDER_ENV_FILE='/dev/null'
OPENBUILDER_HOME="$(tmpdir)"
export OB_PROG OPENBUILDER_ENV_FILE OPENBUILDER_HOME

# shellcheck source=runner/bin/ob-common.sh
source "$TESTS_ROOT/runner/bin/ob-common.sh"
ob_load_env

# ---------------------------------------------------------------------------
# ob_epic_name — the `- epic:` line of a plan.md, or nothing at all
# ---------------------------------------------------------------------------
# A backlog that predates the epic layout, or one whose line is malformed, is
# normal input: the helper must print nothing and still return 0, because a
# non-zero here would fail an otherwise healthy round. The slug pattern is also
# the guard that stops the value being interpolated into a git path.

plans="$(tmpdir)"

printf -- '- slug: demo-01\n- epic: demo-epic\n- title: whatever\n' >"${plans}/good.md"
assert_eq 'demo-epic' "$(ob_epic_name "${plans}/good.md")" \
  'ob_epic_name reads the epic from a well-formed plan.md'

printf -- '- slug: demo-01\n- title: a backlog older than epics\n' >"${plans}/none.md"
assert_eq '' "$(ob_epic_name "${plans}/none.md")" \
  'ob_epic_name is empty for a plan.md with no epic line'

printf -- '- epic: `demo`\n' >"${plans}/backticked.md"
assert_eq '' "$(ob_epic_name "${plans}/backticked.md")" \
  'ob_epic_name rejects a backticked epic value'

printf -- '- epic: Bad_Name!\n' >"${plans}/malformed.md"
assert_eq '' "$(ob_epic_name "${plans}/malformed.md")" \
  'ob_epic_name rejects a value that fails the slug contract'

assert_eq '' "$(ob_epic_name "${plans}/does-not-exist.md")" \
  'ob_epic_name is empty for an unreadable plan.md'

assert_status 0 'ob_epic_name returns 0 for an unreadable plan.md' \
  -- ob_epic_name "${plans}/does-not-exist.md"

# ---------------------------------------------------------------------------
# fixture: a repo whose plan branch carries one epic, and whose work branch
# (main) does not
# ---------------------------------------------------------------------------

repo="$(new_repo)"
epic_dir="${repo}/.openbuilder/epics/demo-epic"
prd_body='# PRD demo-epic
The product requirement that must survive the branch deletion.'
rfc_body='# RFC demo-epic
The design that must survive the branch deletion.'
intake_body='# Intake demo-epic
The request as it arrived.'

git -C "$repo" checkout -q -b plan
mkdir -p "$epic_dir"
printf '%s\n' "$intake_body" >"${epic_dir}/intake.md"
printf '%s\n' "$prd_body" >"${epic_dir}/prd.md"
printf '%s\n' "$rfc_body" >"${epic_dir}/rfc.md"
printf '%s\n' '# State demo-epic' >"${epic_dir}/state.md"
printf '%s\n' '{"stage":"build","slug":"demo-01"}' >"${epic_dir}/state.json"
git -C "$repo" add -- .openbuilder
git -C "$repo" commit -q -m 'epic: demo-epic documents'
git -C "$repo" checkout -q main

# ---------------------------------------------------------------------------
# ob_epic_doc — the document body, or the fallback sentence that names the reason
# ---------------------------------------------------------------------------
# The fallback string is the whole point of the helper: an empty file renders as
# "_(nothing recorded)_", which is a different claim and hides why the section is
# empty. Assert the exact sentence, not merely that something was written.

out="$(tmpdir)/doc.md"

ob_epic_doc "$repo" plan demo-epic PRD "$out"
assert_eq "$prd_body" "$(cat "$out")" \
  'ob_epic_doc writes the PRD body from the plan ref'

ob_epic_doc "$repo" plan demo-epic RFC "$out"
assert_eq "$rfc_body" "$(cat "$out")" \
  'ob_epic_doc writes the RFC body from the plan ref'

ob_epic_doc "$repo" plan '' PRD "$out"
assert_eq '_(no PRD for this slug)_' "$(cat "$out")" \
  'ob_epic_doc falls back to the no-PRD sentence for an empty epic name'
assert_eq '1' "$(wc -l <"$out" | tr -d ' ')" \
  'ob_epic_doc PRD fallback is exactly one line'
assert_not_contains '_(nothing recorded)_' "$(cat "$out")" \
  'ob_epic_doc PRD fallback is not the empty-block sentence'

ob_epic_doc "$repo" plan ghost-epic PRD "$out"
assert_eq '_(no PRD for this slug)_' "$(cat "$out")" \
  'ob_epic_doc falls back to the no-PRD sentence for an epic that does not exist'

ob_epic_doc "$repo" plan '' RFC "$out"
assert_eq '_(no RFC for this slug)_' "$(cat "$out")" \
  'ob_epic_doc falls back to the no-RFC sentence for an empty epic name'

ob_epic_doc "$repo" plan ghost-epic RFC "$out"
assert_eq '_(no RFC for this slug)_' "$(cat "$out")" \
  'ob_epic_doc falls back to the no-RFC sentence for an epic that does not exist'

assert_status 0 'ob_epic_doc returns 0 when the document is missing' \
  -- ob_epic_doc "$repo" plan ghost-epic RFC "$out"

# ---------------------------------------------------------------------------
# ob_epic_docs_commit — land intake/prd/rfc on the work branch, once, and never
# state.json
# ---------------------------------------------------------------------------

before="$(git -C "$repo" rev-list --count HEAD)"
ob_epic_docs_commit "$repo" plan demo-epic "$repo"
after="$(git -C "$repo" rev-list --count HEAD)"

assert_eq "$((before + 1))" "$after" \
  'ob_epic_docs_commit creates exactly one commit'

assert_eq 'main' "$(git -C "$repo" symbolic-ref --short HEAD)" \
  'ob_epic_docs_commit commits on the work branch, not the plan branch'

assert_eq 'docs(epic): PRD and RFC for demo-epic' \
  "$(git -C "$repo" log -1 --format=%s)" \
  'ob_epic_docs_commit subject is exactly the frozen docs(epic) line'

landed="$(git -C "$repo" show --name-only --pretty=format: HEAD | sed '/^$/d' | LC_ALL=C sort)"
expected_landed='.openbuilder/epics/demo-epic/intake.md
.openbuilder/epics/demo-epic/prd.md
.openbuilder/epics/demo-epic/rfc.md'
assert_eq "$expected_landed" "$landed" \
  'ob_epic_docs_commit lands exactly intake.md, prd.md and rfc.md'

# state.json's stage pointer is stale the moment the branch is deleted, so it
# landing on the default branch would be a bug, not a nicety.
assert_not_contains 'state.json' "$landed" \
  'ob_epic_docs_commit never lands state.json'
assert_not_contains 'state.md' "$landed" \
  'ob_epic_docs_commit never lands state.md'

assert_eq "$prd_body" "$(git -C "$repo" show 'HEAD:.openbuilder/epics/demo-epic/prd.md')" \
  'the landed prd.md carries the plan branch body verbatim'

# Second slug of the same epic: the merge-base already carries the documents, so
# a second call must not hit git commit's refusal of a no-op.
ob_epic_docs_commit "$repo" plan demo-epic "$repo"
assert_eq "$after" "$(git -C "$repo" rev-list --count HEAD)" \
  'ob_epic_docs_commit adds no commit when the content is unchanged'

assert_status 0 'ob_epic_docs_commit returns 0 for an empty epic name' \
  -- ob_epic_docs_commit "$repo" plan '' "$repo"
assert_eq "$after" "$(git -C "$repo" rev-list --count HEAD)" \
  'ob_epic_docs_commit adds no commit for an empty epic name'

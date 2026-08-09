---
id: story-02-respond-epic-blocks
title: Render the same PRD and RFC blocks into the respond prompt
size: S
depends_on: [story-01-epic-doc-blocks]
files:
  - runner/bin/ob-respond
  - runner/prompts/respond.md
acceptance:
  - "`shellcheck -x -S warning runner/bin/ob-respond` exits 0"
  - "`grep -c '^{{PRD}}$' runner/prompts/respond.md` and `grep -c '^{{RFC}}$' runner/prompts/respond.md` each print 1, both between `{{STORIES}}` and `## Worklog from previous rounds`"
  - "`diff <(sed -n '/^## PRD$/,/^{{RFC}}$/p' runner/prompts/implement.md) <(sed -n '/^## PRD$/,/^{{RFC}}$/p' runner/prompts/respond.md)` prints nothing and exits 0"
  - "a prompt rendered from `runner/prompts/respond.md` with the harness block map contains the PRD body once and `_(no RFC for this slug)_` once"
  - "with the plan branch absent, both block files still exist and contain the fallback lines: the harness's second render prints `_(no PRD for this slug)_` and `_(no RFC for this slug)_` once each"
---

## Context

`story-01` added `ob_epic_name` and `ob_epic_doc` to `runner/bin/ob-common.sh` and wired them into
`ob-implement`. This story does the same for the review-response round. Read
`story-01-epic-doc-blocks.md` for the two helpers' contracts; do not re-implement them, do not change
them, and do not copy their logic into `ob-respond`.

`ob-respond`'s `read_backlog()` (`ob-respond:163-192`) differs from `ob-implement`'s in one way that
matters here: it is **best effort**. Reviewer feedback is the round's primary input, so when the plan
branch is gone it logs a warning and returns early at `ob-respond:170-173` with `plan.md` and
`stories.md` truncated to empty. That early return is why the two block files must be initialised
before it: a block path that does not exist renders as `_(nothing recorded)_`
(`ob-common.sh:657-666`), which is the wrong sentence for "this slug has no PRD".

`ob_epic_doc` with an empty `<epic>` writes the fallback and never touches git, so initialising is
one call per document with `""` in the epic position — the same function, no second code path.

`render()` (`ob-respond:194-233`) builds the block map at `ob-respond:223-228`. The prompt template
is `runner/prompts/respond.md`, whose story-cards heading is
`## Story cards (the acceptance criteria this PR is held against)`.

## Change

### 1. `runner/bin/ob-respond`

1. Add a global `EPIC=""` immediately after `FILTER_OK=0` (`ob-respond:35`).
2. In `read_backlog()`, immediately after the two truncations `: >"${ROUND_DIR}/plan.md"` and
   `: >"${ROUND_DIR}/stories.md"` (`ob-respond:167-168`) and **before** the plan-branch existence
   check (`ob-respond:170`), initialise both documents to the fallback:
   - `ob_epic_doc "$SRC_DIR" "$ref" "" PRD "${ROUND_DIR}/prd.md"`
   - `ob_epic_doc "$SRC_DIR" "$ref" "" RFC "${ROUND_DIR}/rfc.md"`
3. After the `plan.md` fetch (`ob-respond:174-175`) and before `local -a paths=()`
   (`ob-respond:177`), resolve the epic and re-populate:
   - `EPIC="$(ob_epic_name "${ROUND_DIR}/plan.md")"`
   - `ob_log INFO "epic=${EPIC:-none}"`
   - `ob_epic_doc "$SRC_DIR" "$ref" "$EPIC" PRD "${ROUND_DIR}/prd.md"`
   - `ob_epic_doc "$SRC_DIR" "$ref" "$EPIC" RFC "${ROUND_DIR}/rfc.md"`

   `ref` is already `origin/${PLAN_BRANCH}` (`ob-respond:165`). `EPIC` is a script global; do not add
   it to the `local` list at `ob-respond:164`.
4. In `render()`, add two block-map rows directly after the `STORIES` row (`ob-respond:224`), in this
   order and in the same `printf 'NAME\t%s\n'` shape: `PRD` → `${ROUND_DIR}/prd.md`, `RFC` →
   `${ROUND_DIR}/rfc.md`. Add nothing to the scalar map.

### 2. `runner/prompts/respond.md`

Insert the same block `story-01` inserted into `runner/prompts/implement.md`, byte for byte,
immediately after the line that is exactly `{{STORIES}}` — which in this file follows
`## Story cards (the acceptance criteria this PR is held against)`, so the sections land between the
cards and `## Worklog from previous rounds`. Everything inside the fence is literal content of the
prompt template — the two `##` lines are headings of `respond.md`, not sections of this card, which
has exactly four: Context, Change, Acceptance, Out of scope.

```markdown

---

## PRD

The PRD and the RFC are context for judgement, never a source of work. The story
cards are the only contract. Work implied by the PRD that no card asks for is
**out of scope**. If a card and the RFC genuinely conflict, stop and report the
conflict — do not choose.

{{PRD}}

---

## RFC

The same rule as above: context for judgement, never a source of work.

{{RFC}}
```

Do not reword it for the review context, do not add a sentence about the reviewer, and do not
renumber or edit the existing hard rules or "What to do" items. The parity `diff` in `## Acceptance`
must print nothing.

## Acceptance

- `shellcheck -x -S warning runner/bin/ob-respond` exits 0.
- Template checks, each printing `1`:

  ```sh
  grep -c '^{{PRD}}$' runner/prompts/respond.md
  grep -c '^{{RFC}}$' runner/prompts/respond.md
  sed -n '/^{{STORIES}}$/,/^## Worklog from previous rounds$/p' runner/prompts/respond.md \
    | grep -c '^{{RFC}}$'
  ```

- Parity with the implement prompt — prints nothing, exits 0:

  ```sh
  diff <(sed -n '/^## PRD$/,/^{{RFC}}$/p' runner/prompts/implement.md) \
       <(sed -n '/^## PRD$/,/^{{RFC}}$/p' runner/prompts/respond.md)
  ```

- Rendering, from the repository root of the worktree. Each `grep -c` must print the value shown:

  ```sh
  tmp="$(mktemp -d)"; fix="$tmp/fix"
  git init -q "$fix"
  git -C "$fix" config user.name t
  git -C "$fix" config user.email t@example.com
  printf 'seed\n' >"$fix/README.md"
  git -C "$fix" add -A && git -C "$fix" commit -qm seed
  def="$(git -C "$fix" rev-parse --abbrev-ref HEAD)"
  git -C "$fix" checkout -q -b plan
  mkdir -p "$fix/.openbuilder/epics/demo-epic"
  printf '# PRD body\n' >"$fix/.openbuilder/epics/demo-epic/prd.md"
  git -C "$fix" add -A && git -C "$fix" commit -qm plan
  git -C "$fix" checkout -q "$def"

  # shellcheck source=/dev/null
  source runner/bin/ob-common.sh

  ob_epic_doc "$fix" plan demo-epic PRD "$tmp/prd.md" 2>/dev/null
  ob_epic_doc "$fix" plan demo-epic RFC "$tmp/rfc.md" 2>/dev/null   # absent on the fixture
  : >"$tmp/empty.md"
  {
    printf 'PLAN\t%s\n'      "$tmp/empty.md"
    printf 'STORIES\t%s\n'   "$tmp/empty.md"
    printf 'PR_BODY\t%s\n'   "$tmp/empty.md"
    printf 'FEEDBACK\t%s\n'  "$tmp/empty.md"
    printf 'WORKLOG\t%s\n'   "$tmp/empty.md"
    printf 'LEARNINGS\t%s\n' "$tmp/empty.md"
    printf 'PRD\t%s\n'       "$tmp/prd.md"
    printf 'RFC\t%s\n'       "$tmp/rfc.md"
  } >"$tmp/blocks.tsv"
  printf 'SLUG\tdemo-slug\n' >"$tmp/scalars.tsv"
  ob_render_prompt runner/prompts/respond.md "$tmp/out.md" "$tmp/scalars.tsv" "$tmp/blocks.tsv"
  grep -c '^# PRD body$' "$tmp/out.md"                        # 1
  grep -c '^_(no RFC for this slug)_$' "$tmp/out.md"          # 1

  # the plan-branch-is-gone path: both documents fall back, nothing fails
  ob_epic_doc "$fix" origin/nope "" PRD "$tmp/prd.md" 2>/dev/null
  ob_epic_doc "$fix" origin/nope "" RFC "$tmp/rfc.md" 2>/dev/null
  ob_render_prompt runner/prompts/respond.md "$tmp/out2.md" "$tmp/scalars.tsv" "$tmp/blocks.tsv"
  grep -c '^_(no PRD for this slug)_$' "$tmp/out2.md"         # 1
  grep -c '^_(no RFC for this slug)_$' "$tmp/out2.md"         # 1
  rm -rf -- "$tmp"
  ```

- State in the final message which line numbers the four `ob_epic_doc` calls landed on, and that the
  two initialising calls precede the early return at `ob-respond:170`.

## Out of scope

- No change to `runner/bin/ob-common.sh`. `story-01` owns the two helpers; if one of them is wrong,
  report it as a blocker rather than editing it here.
- No change to `runner/bin/ob-implement`, `runner/prompts/implement.md`, or `main()` in either script.
- No epic-docs commit and no `copy_epic_docs` — `story-03` owns that.
- No change to `gather_feedback()`, `unresolved_ids()`, the `openbuilder*` author filter, or the
  `ob_die` message at `ob-respond:156`.
- No change to the existing hard rules, "What to do" items, "Definition of done" or "Final message"
  sections of `runner/prompts/respond.md`.
- No `state.json`, no `jq`, no approval check.
- No test directory, no harness script committed to the repository, no writes under
  `/opt/openbuilder`, no `ob-selfupdate`.

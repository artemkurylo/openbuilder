---
id: story-01-epic-doc-blocks
title: Render the epic's PRD and RFC into the implement prompt
size: M
depends_on: []
files:
  - runner/bin/ob-common.sh
  - runner/bin/ob-implement
  - runner/prompts/implement.md
acceptance:
  - "`shellcheck -x -S warning runner/bin/ob-common.sh runner/bin/ob-implement` exits 0"
  - "`ob_epic_name` prints `demo-epic` for a plan.md carrying `- epic: demo-epic`, and prints nothing and returns 0 for a plan.md with no such line and for one carrying a backticked value"
  - "`ob_epic_doc <fix> plan demo-epic PRD <out>` writes the fixture's PRD body to <out>; `ob_epic_doc <fix> plan \"\" PRD <out>` and `ob_epic_doc <fix> plan ghost-epic PRD <out>` each write exactly the one line `_(no PRD for this slug)_` and return 0"
  - "a prompt rendered from `runner/prompts/implement.md` with the harness block map contains the PRD body once under a `## PRD` heading and the line `_(no RFC for this slug)_` once under a `## RFC` heading"
  - "`grep -c '^{{PRD}}$' runner/prompts/implement.md` and `grep -c '^{{RFC}}$' runner/prompts/implement.md` each print 1, and both lines sit between `{{STORIES}}` and `## Worklog from previous rounds`"
---

## Context

`ob-implement` renders `runner/prompts/implement.md` through `ob_render_prompt` (`ob-common.sh:627`)
with a scalar map and a block map, built in `render()` (`ob-implement:148-185`). A block-map row is
`NAME<TAB>path`, and a template line that is **exactly** `{{NAME}}` after trimming is replaced by
that file verbatim (`ob-common.sh:655-666`). Scalars are substituted inside a line; blocks are not.
Model- and human-authored text only ever arrives through the block map, which is why it must stay
that way here: an RFC full of backticks, `&` and `$(...)` must survive verbatim.

The story cards and `plan.md` are read off the **plan** branch in `read_backlog()`
(`ob-implement:113-146`), because the work branch is cut from `merge-base(plan, default)`
(`ob-implement:83-84`) and does not contain the backlog. `.openbuilder/epics/<epic>/` is on the plan
branch too — RFC §3.5 cuts the plan branch from the design branch — so the same `git show
origin/<plan-branch>:<path>` shape reaches the epic documents.

Two traps.

1. **An empty block file renders as `_(nothing recorded)_`** (`ob-common.sh:664`). The
   "no PRD" fallback must therefore be written *into* the file; leaving the file empty produces the
   wrong sentence.
2. **A backlog written before this epic has no epic directory at all.** `learn-command`, `scrub-hook`
   and every hand-written backlog have no `- epic:` line. A missing epic must degrade to the fallback
   and never fail a round.

`ob_learnings` (`ob-common.sh:542-567`) is the existing example of injecting an external document
into a round: it resolves a document, always leaves a file behind, logs which source it used, and
degrades instead of failing. Follow that shape. Shell style per `AGENTS.md`: two-space indent,
`local` for every function variable, one clear function.

## Change

### 1. `runner/bin/ob-common.sh` — a new `Epic documents` section

Insert one new section, framed by the same `# ---` divider comment style as its neighbours,
**between** the end of `ob_render_prompt` (`ob-common.sh:672`) and the `# omp` divider
(`ob-common.sh:674`). Each function gets a header comment saying why it exists.

`ob_epic_name <plan-file>` — prints the epic name on stdout, or nothing.

- Unreadable file: print nothing, return 0.
- Extract with exactly `awk '/^- epic:/ {print $3; exit}'`. That extraction is frozen by RFC §2 and
  is also what `ob-poll` rule 4b uses; do not invent a second parser and do not add a YAML parser.
- Require the extracted value to match `^[a-z0-9][a-z0-9-]{1,48}$` (the frozen slug regex, as in
  `ob_require_slug`, `ob-common.sh:140-144`). On no match print nothing and return 0 — a backticked
  or malformed value is treated exactly like an absent line, because the value is interpolated into a
  git path.
- Never call `ob_die`. This function always returns 0.

`ob_epic_doc <src-dir> <plan-ref> <epic> <PRD|RFC> <out-file>` — leaves the document, or the
fallback, in `<out-file>`. Always returns 0.

- Map the label to a file name: `PRD` → `prd.md`, `RFC` → `rfc.md`. Any other label is a programmer
  error: `ob_die "ob_epic_doc: unknown label '<label>' (expected PRD or RFC)"`.
- When `<epic>` is non-empty, run
  `git -C <src-dir> show "<plan-ref>:.openbuilder/epics/<epic>/<name>"` redirected to `<out-file>`,
  discarding its stderr and tolerating a non-zero exit.
- If `<out-file>` is then non-empty, log
  `ob_log INFO "epic doc <label>: <n> lines from <plan-ref>"` where `<n>` is
  `wc -l` of the file with surrounding spaces stripped (the shape used at `ob-common.sh:552`), and
  return.
- Otherwise log
  `ob_log WARN "epic doc <label>: not found at <plan-ref>:.openbuilder/epics/<epic>/<name>; using the fallback"`
  and fall through. Skip this warning when `<epic>` is empty — the caller already logged that.
- Fallback: write exactly one line, `_(no PRD for this slug)_` or `_(no RFC for this slug)_`, formed
  from the label, with a trailing newline. This string appears in the codebase only here.

### 2. `runner/bin/ob-implement` — resolve the epic and add the two blocks

1. Add a global `EPIC=""` immediately after `LEARNINGS_OUT=""` (`ob-implement:35`).
2. In `read_backlog()`, immediately after the `plan.md` fetch and its `ob_die`
   (`ob-implement:118-119`) and before `local -a paths=()` (`ob-implement:121`), add four lines:
   - `EPIC="$(ob_epic_name "${ROUND_DIR}/plan.md")"`
   - `ob_log INFO "epic=${EPIC:-none}"`
   - `ob_epic_doc "$SRC_DIR" "$ref" "$EPIC" PRD "${ROUND_DIR}/prd.md"`
   - `ob_epic_doc "$SRC_DIR" "$ref" "$EPIC" RFC "${ROUND_DIR}/rfc.md"`

   `ref` is already `origin/${PLAN_BRANCH}` (`ob-implement:115`). Do not add `EPIC` to the `local`
   list at `ob-implement:114`; it is a script global.
3. In `render()`, add two block-map rows directly after the `STORIES` row (`ob-implement:178`), in
   this order, using the same `printf 'NAME\t%s\n'` shape:
   `PRD` → `${ROUND_DIR}/prd.md`, `RFC` → `${ROUND_DIR}/rfc.md`.
   Add nothing to the scalar map.

### 3. `runner/prompts/implement.md` — the two sections

Insert this block immediately after the line that is exactly `{{STORIES}}`, so the sections land
between the story cards and `## Worklog from previous rounds`. The contract is read first, the
reasoning second, and `## Learnings` stays last. Copy it exactly, including the blank first line;
`story-02` asserts byte parity with `respond.md`. Everything inside the fence is literal content of
the prompt template — the two `##` lines are headings of `implement.md`, not sections of this card,
which has exactly four: Context, Change, Acceptance, Out of scope.

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

`{{PRD}}` and `{{RFC}}` must each be alone on their line, unindented — an indented or inline
placeholder is not a block substitution.

## Acceptance

- `shellcheck -x -S warning runner/bin/ob-common.sh runner/bin/ob-implement` exits 0.
- `grep -c '^{{PRD}}$' runner/prompts/implement.md` prints `1`; same for `^{{RFC}}$`. And
  `sed -n '/^{{STORIES}}$/,/^## Worklog from previous rounds$/p' runner/prompts/implement.md`
  contains both lines.
- Run this from the repository root of the worktree. Every `echo` line below must print the value
  shown after it.

  ```sh
  tmp="$(mktemp -d)"; fix="$tmp/fix"
  git init -q "$fix"
  git -C "$fix" config user.name t
  git -C "$fix" config user.email t@example.com
  printf 'seed\n' >"$fix/README.md"
  git -C "$fix" add -A && git -C "$fix" commit -qm seed
  def="$(git -C "$fix" rev-parse --abbrev-ref HEAD)"
  git -C "$fix" checkout -q -b plan
  mkdir -p "$fix/.openbuilder/epics/demo-epic" "$fix/.openbuilder/backlog/demo-slug"
  printf '# feat: demo\n\n- epic: demo-epic\n' >"$fix/.openbuilder/backlog/demo-slug/plan.md"
  printf '# PRD body\n' >"$fix/.openbuilder/epics/demo-epic/prd.md"
  printf '# RFC body\n' >"$fix/.openbuilder/epics/demo-epic/rfc.md"
  printf '# intake body\n' >"$fix/.openbuilder/epics/demo-epic/intake.md"
  printf '{"stage":"dispatched"}\n' >"$fix/.openbuilder/epics/demo-epic/state.json"
  git -C "$fix" add -A && git -C "$fix" commit -qm plan
  git -C "$fix" checkout -q "$def"

  # shellcheck source=/dev/null
  source runner/bin/ob-common.sh

  git -C "$fix" show plan:.openbuilder/backlog/demo-slug/plan.md >"$tmp/plan.md"
  echo "[$(ob_epic_name "$tmp/plan.md")]"                       # [demo-epic]
  printf '# feat: old\n' >"$tmp/old.md"
  echo "[$(ob_epic_name "$tmp/old.md")]"                        # []
  printf '# feat: q\n\n- epic: `demo-epic`\n' >"$tmp/bt.md"
  echo "[$(ob_epic_name "$tmp/bt.md")]"                         # []

  ob_epic_doc "$fix" plan demo-epic PRD "$tmp/prd.md" 2>/dev/null
  echo "[$(cat "$tmp/prd.md")]"                                 # [# PRD body]
  ob_epic_doc "$fix" plan "" PRD "$tmp/no-prd.md" 2>/dev/null
  echo "[$(cat "$tmp/no-prd.md")]"                              # [_(no PRD for this slug)_]
  ob_epic_doc "$fix" plan ghost-epic PRD "$tmp/ghost.md" 2>/dev/null
  echo "[$(cat "$tmp/ghost.md")]"                               # [_(no PRD for this slug)_]
  ob_epic_doc "$fix" plan "" RFC "$tmp/no-rfc.md" 2>/dev/null

  : >"$tmp/empty.md"
  {
    printf 'PLAN\t%s\n'      "$tmp/empty.md"
    printf 'STORIES\t%s\n'   "$tmp/empty.md"
    printf 'WORKLOG\t%s\n'   "$tmp/empty.md"
    printf 'LEARNINGS\t%s\n' "$tmp/empty.md"
    printf 'PRD\t%s\n'       "$tmp/prd.md"
    printf 'RFC\t%s\n'       "$tmp/no-rfc.md"
  } >"$tmp/blocks.tsv"
  printf 'SLUG\tdemo-slug\n' >"$tmp/scalars.tsv"
  ob_render_prompt runner/prompts/implement.md "$tmp/out.md" "$tmp/scalars.tsv" "$tmp/blocks.tsv"
  grep -c '^# PRD body$' "$tmp/out.md"                          # 1
  grep -c '^_(no RFC for this slug)_$' "$tmp/out.md"            # 1
  grep -c '_(nothing recorded)_' "$tmp/out.md"                  # 4  (the four empty blocks)
  rm -rf -- "$tmp"
  ```

- State in the final message that `ob_epic_name` never returns non-zero and that both fallback
  strings are written into the block file rather than left empty.

## Out of scope

- `runner/bin/ob-respond` and `runner/prompts/respond.md` — `story-02` owns them. Do not edit either
  file in this story.
- The epic-docs commit on the work branch — `story-03` owns it. This story adds no commit, no
  `copy_epic_docs`, and does not touch `main()`.
- No change to `ob_render_prompt`, to the scalar map, or to the `PLAN`, `STORIES`, `WORKLOG` and
  `LEARNINGS` blocks.
- No `state.json` read, no `jq`, no approval check, no `ob-poll` or `waker/` edit.
- No caching of the fetched documents between rounds, no truncation or summarisation of the PRD or
  the RFC, and no new configuration variable to switch this off.
- No test directory and no harness script committed to the repository. The acceptance block above is
  the verification; anything left in `runner/bin/` is linted by `make lint` and deployed to the
  instance.
- No writes under `/opt/openbuilder` and no `ob-selfupdate`.
- Do not reformat, reorder or rename anything else in `ob-common.sh` or `ob-implement`.

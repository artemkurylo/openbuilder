# feat(runner): give every round the PRD and the RFC, and land them on main

- epic: plan-workflow

## Goal

Every implementation and every review-response round renders the epic's `prd.md` and `rfc.md` into
its prompt, subordinate to the story cards; and the epic's `intake.md`, `prd.md` and `rfc.md` reach
the default branch with the code, as the round's first commit on the work branch. Implements
**R5** and **R6** of `.openbuilder/epics/plan-workflow/prd.md`, per §5 and §7 of
`.openbuilder/epics/plan-workflow/rfc.md`.

## Why now

The worker is a weak model that cannot ask a question, and today it sees only the cards. A judgement
call inside a card — which of two shapes, which failure mode — is decided by coin flip because the
reasoning that would settle it lives on a branch the round never reads. And after the pull request
merges and every branch is deleted, that reasoning is gone entirely: `main` keeps the code and loses
the why.

Both halves are cheap: the plan branch already carries `.openbuilder/epics/<epic>/` (RFC §3.5 cuts
it from the design branch), and `ob_render_prompt` already includes files verbatim through a block
map. What is missing is the wiring, the fallback for backlogs that predate the epic layout, and the
one commit that carries the documents onto the work branch.

## Approach

Three primitives in `runner/bin/ob-common.sh`, four call sites, two prompt sections, one commit.

**Why the library and not the two scripts.** `ob-implement` and `ob-respond` need byte-identical
behaviour here — the same fallback string, the same resolution rule — and `AGENTS.md` makes
`ob-common.sh` the single home for shared behaviour and for prompt rendering. It is also what makes
this slug verifiable without an instance: a sourced function can be exercised from a worktree with
plain `git` and `bash`, and every acceptance item below is a command the reviewer re-runs. RFC §8
already lists `ob-common.sh` among the epic's changed files; §5's mechanism (block map,
`git show origin/<plan>:…`, the literal fallback) is preserved exactly.

The three functions, appended as one new `Epic documents` section between `ob_render_prompt` (ends
`ob-common.sh:672`) and the `omp` divider (`ob-common.sh:674`):

```
ob_epic_name       <plan-file>                              -> epic on stdout, or nothing
ob_epic_doc        <src-dir> <plan-ref> <epic> <PRD|RFC> <out-file>
ob_epic_docs_commit <src-dir> <plan-ref> <epic> <worktree>
```

**No `- epic:` line means fallback, never failure.** `ob_epic_name` extracts with
`awk '/^- epic:/ {print $3; exit}'` (the extraction frozen by RFC §2), then requires the value to
match `^[a-z0-9][a-z0-9-]{1,48}$`; anything else — a missing line, a backticked value, a stray word —
prints nothing and exits 0. Both blocks then render `_(no PRD for this slug)_` /
`_(no RFC for this slug)_` and the epic-docs commit is skipped. `learn-command`, `scrub-hook` and
every hand-written backlog have no epic directory, and a round that refuses to run without one would
break them for a documentation feature.

**The fallback is written into the file, not left empty.** `ob_render_prompt` renders an empty block
file as `_(nothing recorded)_` (`ob-common.sh:664`), which is the wrong sentence and hides the
reason. `ob_epic_doc` therefore always leaves a non-empty file behind.

**Exactly three files are copied, and `state.json` is excluded by name.** The copy loops over the
literal list `intake.md prd.md rfc.md`; it never copies the directory. `state.json` is coordination
state whose `stage` pointer is stale the moment the branch is deleted, and `AGENTS.md` is explicit
that a stale doc is worse than a missing one because it is trusted. The reasoning lands; the
scaffolding dies with the branches.

**Idempotence is a content comparison, and an empty commit is a real failure.** `ob_epic_docs_commit`
compares each file with `cmp -s` against the worktree and commits only when something differs. The
second slug of an epic branches from a merge-base that already contains the documents, so without
the comparison it would attempt an empty commit; `git commit` refuses that, the round dies, and
`ob-implement`'s `on_exit` labels the pull request `openbuilder:blocked` for a reason that has
nothing to do with the code (RFC §7, PRD §10).

**The copy runs before the agent.** In `ob-implement`'s `main`, `copy_epic_docs` sits between
`read_backlog` (which resolves the epic) and `render`, so the documents are in the worktree the agent
works in, not only in its prompt. `copy_epic_docs` re-reads `BASE_SHA` afterwards, because
`prepare_repo` captures it at `ob-implement:94` and `assert_progress` counts
`rev-list BASE_SHA..HEAD` at `ob-implement:197`: without the re-baseline the docs commit would
satisfy the "at least one commit" check on behalf of an agent that produced nothing.

**The prompt sections say the cards win.** Both templates gain the same two sections — a `PRD` one
carrying the subordination paragraph and the `{{PRD}}` block, and an `RFC` one carrying a one-line
pointer back to it and the `{{RFC}}` block — inserted immediately after the line that is exactly
`{{STORIES}}`. That places them between the story cards and the worklog: the contract is read first,
the reasoning second, and `## Learnings` stays last. The exact wording is quoted verbatim in
`story-01-epic-doc-blocks.md`, and `story-02` asserts byte parity between the two templates with
`diff` over a `sed` extraction rather than trusting a careful second edit. Its substance: the PRD and
the RFC are context for judgement and never a source of work; the cards are the only contract; work
implied by the PRD that no card asks for is out of scope; a genuine card/RFC conflict is stopped and
reported, not decided.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-epic-doc-blocks | Render the epic's PRD and RFC into the implement prompt | M | [] |
| story-02-respond-epic-blocks | Render the same two blocks into the respond prompt | S | [story-01-epic-doc-blocks] |
| story-03-epic-docs-commit | Commit intake, PRD and RFC onto the work branch, once per epic | M | [story-01-epic-doc-blocks] |

## Out of scope

- Rule 4b, `ob-poll`, `waker/` and anything that reads `state.json`. Slug `plan-workflow-02-rule`
  owns the rule table; this slug never parses `state.json` and never copies it.
- `local/bin/ob-gate` and `state.json` authorship. Slug `plan-workflow-01-gate`.
- `local/bin/openbuilder` — no launcher, no dispatch gate, no `--watch`, no `land`. Slug
  `plan-workflow-05-cli`.
- `agent/local/**` — no `architect`, no skill, no `planner.md` or `reviewer.md` edit, no
  `docs/workflow.md`. Slug `plan-workflow-04-agents`.
- `backlog/SCHEMA.md`. The `- epic:` line is documented by slug `plan-workflow-04-agents`; this slug
  only consumes it.
- No new test directory, no test harness committed to the repo. The acceptance commands are the
  verification; `make lint` shellchecks everything in `runner/bin/`, so a script left there would be
  deployed to the instance.
- No `ob-selfupdate`, no writes under `/opt/openbuilder`. The round runs in a worktree.
- No change to `ob_render_prompt`, to the scalar map, or to the existing `PLAN`, `STORIES`,
  `WORKLOG` and `LEARNINGS` blocks.

## Risks

- **The two prompt templates drift.** Two copies of the subordination wording is one copy too many
  for a weak reader to be given inconsistently. `story-02` asserts byte parity of the region with
  `diff` on a `sed` extraction rather than trusting a careful edit.
- **The docs commit masks a no-op agent round.** Mitigated by the `BASE_SHA` re-baseline in
  `copy_epic_docs`, and by `story-03`'s ordering assertion on `main`. A reviewer should check that
  `BASE_SHA` is re-read after the copy and nowhere else.
- **`ob-common.sh` is touched by two slugs.** `plan-workflow-00-host` edits `ob_load_env` near
  `ob-common.sh:78`; this slug appends a new section near `ob-common.sh:673`. Different regions, but
  whichever lands second rebases.
- **A blob-identical file with different meaning.** The copy trusts the plan branch over the
  worktree: when both differ, the plan branch wins and the difference is committed. That is deliberate
  — the plan branch is the dispatch-time snapshot — and it means an epic document amended between two
  slugs lands twice, as two commits with the same subject on two branches.

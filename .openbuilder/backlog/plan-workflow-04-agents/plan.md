# feat(agent): /openbuilder-plan command, workflow skill and architect agent

- epic: plan-workflow

## Goal

The design half of the workflow becomes a set of prompt files that survive a closed
session. After this slug: `/openbuilder-plan <epic>` exists as a command file, the
seven-stage procedure and the four gates exist as a durable skill, an `architect`
agent writes `rfc.md` from `prd.md` plus the repository with a structured output the
gate can read mechanically, the `planner` reads `prd.md` and `rfc.md` instead of
interviewing a human, the `reviewer` checks the RFC as a contract, and
`docs/workflow.md` is the documentation authority for the four commands and every
refusal.

Implements PRD **R1** (one resumable entry point), **R2** (the interrogation is an
artifact with a stated stopping rule), **R7** on the reviewer side (the RFC as a
checked contract), and RFC §3.1, §3.2, §3.3 and §6.

## Why now

Everything before a story card lives in one Opus 5 session today
(`.openbuilder/epics/plan-workflow/prd.md` §2). `agent/local/agents/planner.md:19`
tells the planner to write on `openbuilder/plan/<slug>`, which is the branch the
dispatch gate is supposed to cut *after* approval, and nothing in that file mentions
a PRD or an RFC — so the backlog stage has no durable input. There is no `architect`
agent, no `agent/local/commands/` directory at all, and `docs/` has
`architecture.md`, `cost.md`, `github-app-setup.md` and `runbook.md` but no
workflow document. The stage machine cannot be resumed because it is not written
down anywhere a new session can read.

## Approach

Prompt files only. No shell in this slug: `local/bin/ob-gate` is
`plan-workflow-01-gate`, the four commands are `plan-workflow-05-cli`, and this slug
must not touch `local/bin/openbuilder` even though slug 05 will extend
`ob_install_local_assets` (`local/bin/openbuilder:503`) to mirror
`agent/local/commands/` the way it already mirrors `agent/local/agents` at line 509.

Two decisions made on the implementer's behalf, both to keep acceptance mechanical
rather than a matter of taste:

1. **Every load-bearing sentence is fixed text, quoted verbatim in the cards.** The
   grill's stopping rule, the never-self-approve rule, the six `REFUSED:` strings and
   the reviewer's RFC-departure wording are given as exact strings. They are checked
   with `python3` after whitespace normalisation, so line wrapping at the repo's ~80
   columns cannot break a check. Paraphrase is a defect, not a style choice.
2. **Seven stage sections, six `state.json` values.** The workflow has seven stages
   (intake, prd, rfc, backlog, dispatch, review, land) but `state.json.stage` is the
   six-value enum the RFC fixes in §2 — `review` runs while the pointer still reads
   `dispatched`. The skill says this out loud so nobody "fixes" the enum.

A third decision, forced by AGENTS.md ("leave the docs true"): stages 5 to 7 are
driven by commands that do not exist until `plan-workflow-05-cli` lands. Both the
skill and `docs/workflow.md` carry one explicit status line saying so, and
`docs/workflow.md` marks it with an HTML comment so slug 05 can find and delete it.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| `story-01-workflow-skill` | Add the openbuilder-workflow skill and /openbuilder-plan command | M | — |
| `story-02-architect-agent` | Add the architect agent; point planner and reviewer at the epic docs | M | `story-01-workflow-skill` |
| `story-03-workflow-doc` | Document the workflow, its commands and refusals in docs/workflow.md | S | `story-01-workflow-skill` |

## Out of scope

- **No shell.** No change to `local/bin/*`, `runner/*` or `waker/*`. In particular
  `ob_install_local_assets` (`local/bin/openbuilder:503`) is not extended here —
  `plan-workflow-05-cli` mirrors `agent/local/commands/` into
  `<clone>/.omp/commands/`. Until it does, the new command file is not discoverable
  in a managed clone, and that is expected.
- No `local/bin/ob-gate`. The skill and the cards *invoke* it and quote its exit
  codes; `plan-workflow-01-gate` writes it.
- No change to `backlog/SCHEMA.md`, to `agent/local/agents/skills/write-backlog/`,
  or to the sizing and slicing rules. PRD §9 puts them out of scope.
- No change to the reviewer's rubric severities, its verdict enum, or its `output`
  schema. RFC §6 says the rubric, the severities and the verdict schema are
  untouched.
- No change to `agent/hooks/pre/guardrails.ts`. Its eleven rules — nine bash, one
  path, one structured tool argument — already cover merge, force-push (including the
  `github` tool spelling), default-branch push, `--hard` reset outside a worktree,
  root deletion, instance termination and every route into `/opt/openbuilder/etc`.
- No change to `README.md`, `AGENTS.md`, `docs/runbook.md` or `docs/architecture.md`.
  They document commands that do not exist until `plan-workflow-05-cli` lands.
- No new skill beyond `openbuilder-workflow`, and no second command file.
- No tests directory, no linter config, no CI change. `make lint` covers shell only.

## Risks

- **Paraphrase.** The four verbatim strings are the whole point of the gate and the
  grill; a reworded stopping rule is unenforceable and a reworded `REFUSED:` line
  breaks `docs/workflow.md`'s table. The reviewer should run each `python3` check in
  the cards rather than read the sentences and agree with them.
- **A doc that lies.** `docs/workflow.md` describes `openbuilder review --watch` and
  `openbuilder land` before they exist. The status line and its
  `<!-- remove when plan-workflow-05-cli lands -->` marker are what keep the file
  honest; if either is missing this slug has broken AGENTS.md's standing obligation.
- **Scope creep into shell.** The temptation is to add the one-line mirror to
  `ob_install_local_assets` "while we are here". Slug 05 rewrites four commands in
  that 1189-line file; two slugs editing it concurrently is the collision the slicing
  exists to avoid.
- **The architect's schema drifting from the reviewer's.** `architect.md` copies the
  frontmatter shape of `reviewer.md:16-45`, including `additionalProperties: false`.
  A second convention for agent output schemas is a maintainability finding.

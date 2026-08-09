---
id: story-03-schema-epic-line
title: Document the `- epic:` line in backlog/SCHEMA.md
size: S
depends_on: []
files:
  - backlog/SCHEMA.md
acceptance:
  - "grep -c 'Three hard requirements outside the frontmatter:' backlog/SCHEMA.md prints 1 and grep -c 'Two hard requirements' backlog/SCHEMA.md prints 0"
  - "grep -n 'must start with a\\|must carry an\\|not yours to write' backlog/SCHEMA.md prints exactly 3 lines, in that order, with increasing line numbers"
  - "grep -cF \"awk '/^- epic:/ {print \\$3; exit}'\" backlog/SCHEMA.md prints 1"
  - "git diff -- backlog/SCHEMA.md | grep -c '^-[^-]' prints 1 — exactly one existing line was replaced"
  - "awk 'length > 110 {c++} END {print c+0}' backlog/SCHEMA.md prints 11, unchanged from before the edit"
  - "git diff --name-only | grep -v '^local/bin/ob-gate$' prints exactly backlog/SCHEMA.md"
---

## Context

`backlog/SCHEMA.md` is the authoritative story-card contract, and PRD §5 and §9 put it out of scope
for this epic **except** for one line: `plan.md` gains an `- epic:` bullet so a card set can name the
epic directory holding its PRD and RFC (RFC §2, and the "Changed" table in RFC §8: "the one new
`- epic:` line in `plan.md`. Nothing else.").

The relevant part of the file today is lines 18-23:

```
Two hard requirements outside the frontmatter:

- **`plan.md` must start with a `# ` heading.** `ob-implement` derives the pull request title from it. No
  heading, no usable PR title.
- **`worklog.md` is not yours to write.** The instance creates and appends to it on the work branch, one entry
  per round. Do not commit one on the plan branch.
```

Two bullets, no blank line between them, prose wrapped at at most 110 columns (line 22 is exactly
110). The `# ` heading claim is true: `pr_title()` at `runner/bin/ob-implement:234-236` takes the
title with `awk '/^# /{sub(/^# +/, ""); print; exit}'`.

The extraction for the new line is `awk '/^- epic:/ {print $3; exit}'` — verified: given
`- epic: plan-workflow` it prints `plan-workflow`. That is why the field is a plain bullet and not
YAML frontmatter: `plan.md` has no frontmatter at all, and adding a YAML parser to bash for one
field would be a second convention (RFC §2, and RFC §10 rejects the frontmatter alternative
explicitly).

This slug's own `plan.md` already carries the line, so the file being documented and the example are
consistent.

## Change

Edit `backlog/SCHEMA.md` and nothing else. Exactly two edits, both inside lines 18-23.

1. Replace `Two hard requirements outside the frontmatter:` with
   `Three hard requirements outside the frontmatter:`. This is the only existing line the story
   removes.

2. Insert one new bullet **between** the `# ` heading bullet and the `worklog.md` bullet — that is,
   after the line `  heading, no usable PR title.` and before the line beginning
   `- **`worklog.md` is not yours to write.**` — with no blank line before or after it, matching the
   existing bullet spacing. Its content, in this order and this wording:

   - the bold lead `**`plan.md` must carry an `- epic:` line.**;
   - where it goes: directly under the `# ` heading, as a plain bullet, written `- epic: <epic>`;
   - what it names: the directory `.openbuilder/epics/<epic>/` that holds the PRD and the RFC this
     backlog implements;
   - why it is a plain bullet and not frontmatter: `plan.md` has no frontmatter, and the value is read
     with `awk '/^- epic:/ {print $3; exit}'`;
   - the consequence of omitting it: nothing can find the design documents or the recorded approval
     for this slug from the card alone.

   Wrap the bullet's lines at no more than 110 characters, continuation lines indented two spaces,
   like the two bullets around it. Do not reflow, re-wrap or re-punctuate any existing line.

Nothing else in `backlog/SCHEMA.md` changes: not the layout block at lines 8-13, not the frontmatter
key table, not the body-section descriptions, not the sizing table, not the `depends_on` section, not
the acceptance-criteria rules, not the template, and not the bad/good example. The template at lines
157-211 keeps its current content; it is a **card** template and the `- epic:` line belongs to
`plan.md`, which the template does not show.

## Acceptance

From the repository root:

- `grep -c 'Three hard requirements outside the frontmatter:' backlog/SCHEMA.md` prints `1`, and
  `grep -c 'Two hard requirements' backlog/SCHEMA.md` prints `0`.
- `grep -n 'must start with a\|must carry an\|not yours to write' backlog/SCHEMA.md` prints exactly
  three lines, in that order, with strictly increasing line numbers — the new bullet sits between the
  other two.
- `grep -cF "awk '/^- epic:/ {print \$3; exit}'" backlog/SCHEMA.md` prints `1`.
- `git diff -- backlog/SCHEMA.md | grep -c '^-[^-]'` prints `1`: exactly one existing line
  (`Two hard requirements…`) was replaced, and no other line was touched.
- `awk 'length > 110 {c++} END {print c+0}' backlog/SCHEMA.md` prints `11`, the same count as before
  the edit — the eleven long lines are table rows, so the new prose stayed within the file's wrap
  width.
- `git diff --name-only | grep -v '^local/bin/ob-gate$'` prints exactly `backlog/SCHEMA.md`.
- Round-trip check on this slug's own plan: `awk '/^- epic:/ {print $3; exit}'
  .openbuilder/backlog/plan-workflow-01-gate/plan.md` prints `plan-workflow`, matching the form the
  new bullet documents.

## Out of scope

- No other change to `backlog/SCHEMA.md`. Not the layout block, not the key table, not the sizing
  table, not the template, not the bad/good example, not a new section, not a typo fix, not a
  reflow.
- No changes to `agent/local/agents/skills/write-backlog/SKILL.md`. It documents the same schema and
  is `plan-workflow-04-agents`' concern, not this story's.
- No changes to `runner/bin/ob-implement`, `runner/bin/ob-poll`, `waker/**` or any prompt: this story
  documents the line, it does not read it. Extraction lands in `plan-workflow-03-context`, and the
  gate that requires it in `plan-workflow-02-rule`.
- No changes to `README.md`, `AGENTS.md`, `docs/architecture.md`, `docs/runbook.md` or
  `docs/workflow.md`.
- No `- epic:` line added to `.openbuilder/backlog/learn-command/` or
  `.openbuilder/backlog/scrub-hook/`. PRD §9 puts migrating the two pre-existing slugs out of scope.
- No edit to any file under `.openbuilder/backlog/plan-workflow-01-gate/` — the cards you are reading
  are the input to this round, not part of its diff.

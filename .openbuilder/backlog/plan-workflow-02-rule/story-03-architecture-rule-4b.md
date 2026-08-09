---
id: story-03-architecture-rule-4b
title: Document rule 4b in the architecture rule table and parity contract
size: S
depends_on:
  - story-02-waker-rule-4b
files:
  - docs/architecture.md
acceptance:
  - "grep -c '^| 4b |' docs/architecture.md prints 2"
  - "docs/architecture.md contains the heading ### Rule 4b — the backlog approval gate, positioned after ### Parity contract and before ### The flap guard"
  - "the sentence at docs/architecture.md:151 reads Rules 1-4b are refusals and they come first"
  - "each of the five reason tokens backlog-unapproved:no-epic-line, :no-state, :stage=, :no-approval, :files-differ appears in runner/bin/ob-poll, waker/github.py and docs/architecture.md"
  - "git diff --numstat docs/architecture.md reports exactly 1 deleted line, proving both table-row additions are pure insertions and only the line-151 sentence was rewritten"
---

## Context

`docs/architecture.md` is the design authority (`AGENTS.md`, "Leave the docs true"), and §2 "The
state machine" is where the rule table lives. Two tables need the new row:

- the rule table itself, `docs/architecture.md:141-149` — seven rows, `| # | Condition | Action |`;
- the parity table under `### Parity contract — ob-poll and waker/github.py` at line 155,
  `docs/architecture.md:161-169` — `| # | ob-poll, on the instance | waker/github.py, in Lambda |`.

The prose immediately after the rule table (line 151) says *"Rules 1–4 are refusals and they come
first"*, which stops being true once rule 4b exists. The paragraph at lines 184-189 ("**Changing the
rules obliges two edits.**") already states the parity obligation and needs no change.

`AGENTS.md` also requires log lines to be quoted verbatim from the source rather than paraphrased,
because an operator greps for the string they actually saw. That is why this story documents the five
`reason=` strings literally instead of describing them.

`story-01-ob-poll-rule-4b` and `story-02-waker-rule-4b` are finished before this one: read the five
reason strings out of `runner/bin/ob-poll` and `waker/github.py` and copy them, rather than retyping
them from this card.

The em dash and en dash in this file's headings and ranges are deliberate; match the surrounding
style.

## Change

In `docs/architecture.md` only.

1. **Rule table.** Insert this row, verbatim, between the rule-4 row (line 146) and the rule-5 row
   (line 147):

   ```
   | 4b | no PR yet, and the plan branch's backlog is not approved in `state.json` | skip quietly: no attempt, no label, no comment |
   ```

   Leave rows 1–4 and 5–7 exactly as they are. Do not renumber anything.

2. **The sentence at line 151.** Change `Rules 1–4 are refusals and they come first` to
   `Rules 1–4b are refusals and they come first`. Change nothing else in that paragraph.

3. **Parity table.** Insert this row, verbatim, between the rule-4 row (line 166) and the rule-5 row
   (line 167):

   ```
   | 4b | backlog not approved on the plan branch → skip | same verdict: not actionable |
   ```

4. **New subsection**, placed after the "Changing the rules obliges two edits" paragraph (which ends
   at line 189) and before `### The flap guard — second line of defence` (line 191). Heading text
   exactly:

   `### Rule 4b — the backlog approval gate`

   Its body, in this order and no longer than about 25 lines:

   - **What it reads**, as a three-row list naming both endpoints once: the contents of a file at a
     ref (`GET repos/<repo>/contents/<path>?ref=<ref>`) for
     `.openbuilder/backlog/<slug>/plan.md` and for `.openbuilder/epics/<epic>/state.json`, and the
     contents of a directory at a ref for `.openbuilder/backlog/<slug>/`. State that a listing
     entry's `sha` **is** the git blob sha — the value `git rev-parse <ref>:<path>` prints — so the
     file-set check downloads no card content, and that the three calls happen only for a slug that
     has no pull request.
   - **What it requires to pass**: `stage: dispatched` in `state.json`, and an
     `approvals.backlog[<slug>].files` map whose entries match the committed blob shas exactly, with
     no missing and no extra `story-*.md`.
   - **The five reason strings, as a two-column table** — cause and the verbatim `reason=` value:
     `backlog-unapproved:no-epic-line`, `backlog-unapproved:no-state`,
     `backlog-unapproved:stage=<stage>`, `backlog-unapproved:no-approval`,
     `backlog-unapproved:files-differ(<name>)`. Say that both implementations emit byte-identical
     strings, and that a read failure of any kind is reported as the same reason as an absent file
     because a decline has no side effect and the next pass is 60 seconds later.
   - **Why the decline is quiet**: `action=skip` and nothing else — no attempt consumed, no label, no
     comment, no `ACTIONABLE` increment, so no wake-up. A loud refusal would label the slug
     `openbuilder:blocked`, which rule 3 treats as terminal, so one human mistake would need a second
     human to clear it. Note that the decision goes to stdout only, because an uneventful pass must
     not touch `log/openbuilder.log`, whose mtime `ob-idle-stop` reads as "when work last happened".
   - **One example line, verbatim**:

     `DECISION repo=owner/x slug=y rule=4b action=skip reason=backlog-unapproved:no-approval`

   - **How the two implementations were proven to agree**: seven live fixture branches in a sandbox
     repository the instance does not poll, one per cause plus the pass case, `ob-poll --dry-run` and
     `waker/github.py:decide` run against the same branches, and the extracted `slug`/`reason` pairs
     diffed. Add that a side-by-side read of the two files is not accepted as evidence for this rule.

Write no `[UNVERIFIED]` marker: everything above was demonstrated by stories 01 and 02. If any claim
here was not demonstrated, report it rather than documenting it.

## Acceptance

```sh
grep -c '^| 4b |' docs/architecture.md                                    # 2
grep -n '^### Parity contract\|^### Rule 4b — the backlog approval gate\|^### The flap guard' \
  docs/architecture.md            # three lines, in exactly that order, ascending line numbers
grep -cF 'Rules 1–4b are refusals and they come first' docs/architecture.md   # 1
grep -cF 'DECISION repo=owner/x slug=y rule=4b action=skip reason=backlog-unapproved:no-approval' \
  docs/architecture.md                                                    # 1
```

Doc-truth cross-check — every documented reason string must exist in both implementations, and every
implemented one must be documented:

```sh
for f in runner/bin/ob-poll waker/github.py docs/architecture.md; do
  grep -ohE 'backlog-unapproved:(no-epic-line|no-state|no-approval|stage=|files-differ)' "$f" |
    sort -u
done | sort | uniq -c
```

Five lines, each with a count of `3`. Any count below 3 is a stale doc or a missing string.

Nothing else in the file may move. Both table rows are pure insertions and the only rewritten line is
the sentence at line 151, so the diff must delete exactly one line:

```sh
git diff --numstat docs/architecture.md | cut -f2   # 1
git diff --numstat docs/architecture.md | cut -f3   # docs/architecture.md, and nothing else
git diff docs/architecture.md | grep '^-[^-]'       # exactly one line, the old 'Rules 1–4' sentence
```

If `cut -f2` prints anything but `1`, a line was rewritten that should not have been: read the diff
and restore it.

Do not run `make lint`, `make scrub`, `terraform fmt` or any project-wide target; this story changes
one Markdown file.

## Out of scope

- `docs/runbook.md` — the operator surface for this workflow (the four commands, the refusal table,
  un-voiding an approval) belongs to `plan-workflow-01-gate` and `plan-workflow-05-cli` per RFC §8.
- `docs/cost.md`. Rule 4b adds three API calls per unapproved slug per pass and no instance time
  (RFC §12); there is no price to change.
- `README.md`, `AGENTS.md`, `LEARNINGS.md`, `backlog/SCHEMA.md`, `docs/workflow.md`.
- The `§ on the workflow` and the "blob shas as approvals" design-decision entry that RFC §8 also
  assigns to `docs/architecture.md`: those belong to slugs 01 and 04, not here.
- §1's component inventory, the environment contract in §2's preamble, the flap-guard subsection, and
  every design-decision section further down the file.
- No renumbering of rules 5, 6 or 7 in any table, list or sentence in the repository.
- No new diagram, no table of contents entry, no reflow or re-wrap of paragraphs you did not change,
  and no change to the file's dash or heading conventions.
- No code change in `runner/` or `waker/`. If a reason string in the code differs from what this card
  says, the code is authoritative — document the code and report the discrepancy.

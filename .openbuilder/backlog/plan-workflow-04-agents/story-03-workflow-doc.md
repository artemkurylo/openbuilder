---
id: story-03-workflow-doc
title: Document the workflow, its commands and refusals in docs/workflow.md
size: S
depends_on:
  - story-01-workflow-skill
files:
  - docs/workflow.md
acceptance:
  - "docs/workflow.md exists and grep -c '^## ' prints 6"
  - "grep -c '^| `openbuilder' docs/workflow.md prints 4 — one row per documented command"
  - "grep -c 'REFUSED: ' docs/workflow.md prints 6"
  - "the python3 parity check prints OK 6, confirming the six REFUSED strings in docs/workflow.md are byte-identical to the six in the openbuilder-workflow skill"
  - "the python3 verbatim check prints OK, confirming the grill's stopping rule appears in docs/workflow.md exactly as in the skill"
  - "grep -Fc '<!-- remove when plan-workflow-05-cli lands -->' docs/workflow.md prints 1"
---

## Context

`docs/` holds `architecture.md`, `cost.md`, `github-app-setup.md` and `runbook.md`.
There is no workflow document, and RFC §8 makes `docs/workflow.md` the documentation
authority for the workflow. PRD success criterion 6 is that four documented commands
are the only ones needed from problem statement to merge, so this file has to name
exactly four and no more.

Voice: `docs/runbook.md` (1170 lines) and `README.md` (610 lines) are the models. The
runbook opens with `# Runbook` then `## 0. The first three commands, always`, uses
`##` sections and fenced `bash` blocks whose expected output is a `# expect:` comment
inside the block. The README uses prose plus tables and explains *why* a mechanism has
the shape it has. Follow both: tables for the contracts, fenced blocks with
`# expect:` for anything a human would type.

This file duplicates two pieces of fixed text from
`agent/local/agents/skills/openbuilder-workflow/SKILL.md`: the grill's stopping rule
and the six `REFUSED:` strings. That duplication is deliberate — the skill is what the
agent obeys, this file is what the human reads — and it is checked, so the two cannot
drift. Copy the strings; do not re-word them.

AGENTS.md's second standing obligation is to leave the docs true, and this is the
awkward case: `openbuilder dispatch` exists today but has no backlog gate,
`openbuilder review` exists but has no `--watch`, and `openbuilder land` does not
exist at all. All three arrive with the `plan-workflow-05-cli` slug. The file therefore
opens with one status line, marked with an HTML comment so slug 05 can find and delete
it. Writing the file without that line would put an untrue document on `main`.

`local/bin/ob-gate` and its exit codes (0 intact, 3 void, 4 absent) arrive with
`plan-workflow-01-gate`, which merges before this slug, so `ob-gate` may be documented
as live.

## Change

Create `docs/workflow.md`. No frontmatter — no file under `docs/` has any.

Line 1 is `# The openbuilder workflow`. Then a one-paragraph opening: one entry point,
seven stages, four human gates, each gate a decision recorded on a branch rather than
in a session, so the workflow survives a closed session and a week of interruption.

Immediately after it, the status line, exactly one blockquote line followed by the
marker on the same line:

```
> Status — the design stages run today. The backlog gate inside `openbuilder dispatch`, the `--watch` flag on `openbuilder review` and the `openbuilder land` command arrive with the `plan-workflow-05-cli` slug; until it lands, dispatch does not check the backlog gate and merging is manual. <!-- remove when plan-workflow-05-cli lands -->
```

Then exactly these six `##` sections, in this order, and no others:

1. `## The four commands`
2. `## The seven stages`
3. `## The four gates`
4. `## Refusals`
5. `## Resuming after a lost session`
6. `## Where the artifacts live`

### `## The four commands`

A four-row table, `| Command | What it does | Ends when |`, whose data rows each begin
`| \`openbuilder` — no fifth row:

| Command | Covers |
|---|---|
| `openbuilder plan <owner/repo> <epic>` | prepares the clone, checks out or creates `openbuilder/design/<epic>`, launches the Opus 5 session, and resumes at the recorded stage. State in the cell that `/openbuilder-plan <epic>` is the same thing from inside an already-running session in that clone |
| `openbuilder dispatch <owner/repo> <slug>` | verifies the backlog gate, commits `stage: dispatched`, and cuts `openbuilder/plan/<slug>` from the design branch tip — in that order |
| `openbuilder review --watch <owner/repo> <pr>` | polls the pull request's labels every 60 s and drives reviewer/worker rounds to a verdict, capped at `OPENBUILDER_MAX_ATTEMPTS` (6) |
| `openbuilder land <owner/repo> <pr>` | refuses without `openbuilder:approved`, then squash-merges, deletes the epic's branches on `origin`, and removes the instance's worktree and per-slug state |

Below the table, one fenced `bash` block showing the four in sequence for one epic,
with a `# expect:` comment on the observable result of each — the design branch
created, the plan branch pushed, the `openbuilder:approved` label, the merge.

Then two sentences on the boundary: nothing but `openbuilder land` merges, ever, and
it is human-invoked and refuses to guess a pull request.

### `## The seven stages`

One table, `| # | Stage | Actor | Model | Artifact | Gate |`, seven rows: intake, prd,
rfc, backlog, dispatch, review, land — the same actors and artifacts as the skill's
`## The seven stages` section. Under it, one sentence stating that `state.json.stage`
has six values (`intake | prd | rfc | backlog | dispatched | landed`) because `review`
runs while the pointer still reads `dispatched`.

### `## The four gates`

The gates are PRD, RFC, backlog (once per slug) and merge. State the mechanism in
prose: a human approves in the session, and `local/bin/ob-gate` — never a model —
computes the artifact's git blob sha, writes it into `state.json`, advances `stage`,
and commits with an `Approves-<stage>: <sha>` trailer. Then say why a blob sha: it is
what git already computes for the exact bytes, `git rev-parse <ref>:<path>` yields it
locally and the GitHub contents API returns the identical value as the `sha` field of
a directory entry, so the same record is verifiable from the laptop, from the instance
and from the waker with no shared secret and no clock. Edit the artifact and the
approval is void by construction rather than by policy.

Then a table of `ob-gate`'s surface — the six invocations
(`init`, `stage`, `record <epic> prd|rfc`, `record <epic> backlog <slug>`,
`verify <epic> [prd|rfc|backlog|--all]`, `show`) — and a second, three-row table of
`verify`'s exit codes. Write the codes in that table as the literal strings `exit 0`
(intact), `exit 3` (void — the recorded blob no longer matches) and `exit 4` (absent —
no record), because the acceptance check greps for exactly those three strings.

Close with the merge gate: it is not an `ob-gate record`; it is `openbuilder land`
refusing anything without `openbuilder:approved`.

State once that the poller and the waker enforce the backlog gate independently as
rule 4b, so a plan branch pushed by hand with an unapproved backlog produces no round,
no attempt, no label and no wake-up — the decline is `action=skip` and nothing else.

### `## Refusals`

A three-column table, `| Situation | Message | Fix |`, with exactly six rows. The
`Message` cell holds the string copied byte-for-byte from the skill's `## Refusals`
table; the `Fix` cell is the human action. All six are:

```
REFUSED: <stage> is not approved in this session. Next: read the artifact above and say approve.
REFUSED: approval for <stage> is void - the recorded blob no longer matches the file on this branch. Next: ob-gate record <epic> <stage>
REFUSED: no approval recorded for <stage>. Next: ob-gate record <epic> <stage>
REFUSED: backlog <slug> contains no story-*.md card. Next: write at least one card, then ob-gate record <epic> backlog <slug>
REFUSED: openbuilder/design/<epic> is behind origin. Next: git pull --ff-only origin openbuilder/design/<epic>
REFUSED: the working tree is dirty. Next: git status --short, then commit or stash before advancing a stage
```

Above the table, one sentence: every refusal names the reason and the exact next
command, because a refusal a human has to debug is worse than the mistake it caught.

Below the table, a short "un-voiding an approval" fenced block: the artifact changed
after approval, so `ob-gate verify <epic> --all` exits 3; read the diff, decide, and
re-approve with `ob-gate record <epic> <stage>`, with `# expect:` on the exit code
before and after.

### `## Resuming after a lost session`

The four resumption steps of RFC §3.2 as a numbered list, then the grill's stopping
rule as a blockquote, copied from the skill with no backticks, no bold and no
rewording:

> Ask a question only while its answer would change a PRD requirement, an RFC
> decision, or an acceptance criterion. Answer from the repository anything the
> repository can answer. When the human says enough, every still-open question
> becomes a stated assumption in prd.md, never a silent guess.

Then one paragraph on the intake block: `### Qn — question`, `**Asked because**`,
`**Answered**`, `**Consequence**`, and that `**Answered** _pending_` is the exact
marker resumption looks for, so an answered question is never re-asked.

### `## Where the artifacts live`

A table of the five paths — `intake.md`, `prd.md`, `rfc.md`, `state.json` under
`.openbuilder/epics/<epic>/`, and `.openbuilder/backlog/<slug>/` — with, for each,
which branch carries it and whether it reaches `main`. State that `intake.md`,
`prd.md` and `rfc.md` are copied onto the work branch by `ob-implement` as the round's
first commit, `docs(epic): PRD and RFC for <epic>`, and that `state.json` is
deliberately excluded because it is coordination state whose stage pointer is stale
the moment the branch is deleted, and a stale file on `main` is worse than a missing
one.

Close with the two branch namespaces: `openbuilder/design/<epic>` is invisible to the
poller and the waker, which match `refs/heads/openbuilder/plan/` only, so the design
phase cannot start a round by accident; `openbuilder/plan/<slug>` is the trigger.

End with one sentence stating that GitHub is the only message bus between laptop and
instance, and that openbuilder operates on `github.com` and on no other host. Write
`github.com` literally — the acceptance check greps for it, and it must be the only
host name in the file.

## Acceptance

Run from the repository root.

- `test -f docs/workflow.md` exits 0.

- Structure and command count:

  ```bash
  grep -c '^## ' docs/workflow.md            # 6
  grep -c '^| `openbuilder' docs/workflow.md # 4
  grep -c 'REFUSED: ' docs/workflow.md       # 6
  grep -Fc '<!-- remove when plan-workflow-05-cli lands -->' docs/workflow.md  # 1
  ```

- Each of the four commands is named:

  ```bash
  for c in "openbuilder plan" "openbuilder dispatch" "openbuilder review --watch" "openbuilder land"; do
    grep -qF "$c" docs/workflow.md || { echo "MISSING $c"; exit 1; }
  done; echo OK
  ```

  prints `OK` and exits 0.

- The six refusal strings are byte-identical to the skill's:

  ```bash
  python3 - <<'PY'
  import re, sys
  def refusals(p):
      return sorted({m.rstrip() for m in re.findall(r"REFUSED: [^|\n]+", open(p, encoding="utf-8").read())})
  a = refusals("agent/local/agents/skills/openbuilder-workflow/SKILL.md")
  b = refusals("docs/workflow.md")
  assert len(a) == 6, ("skill", len(a), a)
  assert a == b, ("mismatch", [x for x in a if x not in b], [x for x in b if x not in a])
  print("OK", len(a))
  PY
  ```

  prints `OK 6` and exits 0.

- The stopping rule is present verbatim, insensitive to line wrapping:

  ```bash
  python3 - <<'PY'
  import re, sys
  want = "Ask a question only while its answer would change a PRD requirement, an RFC decision, or an acceptance criterion. Answer from the repository anything the repository can answer. When the human says enough, every still-open question becomes a stated assumption in prd.md, never a silent guess."
  flat = re.sub(r"[>\s]+", " ", open("docs/workflow.md", encoding="utf-8").read())
  print("OK" if want in flat else "MISSING")
  sys.exit(0 if want in flat else 1)
  PY
  ```

  prints `OK` and exits 0.

- `ob-gate verify`'s three exit codes are documented as literal strings:

  ```bash
  grep -qF 'exit 0' docs/workflow.md \
    && grep -qF 'exit 3' docs/workflow.md \
    && grep -qF 'exit 4' docs/workflow.md; echo $?   # 0
  ```

- The only GitHub host named anywhere in the file is `github.com`:
  `grep -Eo '[A-Za-z0-9.-]+\.(com|net|io|org)' docs/workflow.md | sort -u` prints
  `github.com` and nothing else.

## Out of scope

- **No shell.** No change to `local/bin/*`, `runner/*` or `waker/*`.
- No token, key, credential or account identifier of any kind, not even as an example
  value. This repository is public and its contents are processed by a third-party
  model; the only host it may name is `github.com`.
- No change to `README.md`, `AGENTS.md`, `docs/runbook.md`, `docs/architecture.md` or
  `docs/cost.md`, and no link added to any of them. They describe commands that do not
  exist until `plan-workflow-05-cli` lands; linking a document that promises `land`
  from the README would make the README untrue.
- Do not create or edit the `openbuilder-workflow` skill, the command file, or any
  agent file — stories 01 and 02 own those. Copy the two fixed texts out of the skill;
  do not edit the skill to match this file.
- No fifth command, no `ob-selfupdate`, `obrun`, `openbuilder status`,
  `openbuilder logs` or troubleshooting content. Troubleshooting is `docs/runbook.md`'s
  job and this file must not become a second runbook.
- No rule-table documentation beyond the one sentence about rule 4b declining quietly.
  `docs/architecture.md` §2 is the rule table's home and is not touched here.
- No diagrams, no mermaid, no ASCII flowchart, no screenshots.
- No cost figures. `docs/cost.md` owns those and nothing in this epic changes cost.
- Do not remove the status line or its HTML comment marker. Slug 05 removes both when
  the commands become real.
- Do not run `make lint`, `make fmt` or `make scrub`.

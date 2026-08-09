---
id: story-05-reviewer-rubric-r12
title: Teach the reviewer rubric which merges R12 permits, and which stay blocking
size: M
depends_on: []
files:
  - agent/local/agents/reviewer.md
  - agent/local/agents/skills/review-openbuilder-pr/SKILL.md
  - agent/local/agents/skills/openbuilder-workflow/SKILL.md
  - docs/workflow.md
acceptance:
  - "`grep -cF 'automatically blocking' agent/local/agents/reviewer.md` prints 1, and the surrounding bullet names both the permitted reviewer path and the still-forbidden implementer path"
  - "`grep -cF 'A human merges' agent/local/agents/skills/review-openbuilder-pr/SKILL.md` prints 0 — every such claim is replaced by wording that survives R12"
  - "`grep -nF 'gh pr merge' agent/local/agents/skills/review-openbuilder-pr/SKILL.md` still reports the line under the remote agent's prohibitions, and that line still forbids it"
  - "both files name PRD R12 and RFC §3.8 at least once: `grep -cF 'R12' agent/local/agents/reviewer.md` and the same for the skill each print 1 or more"
  - "the `openbuilder:approved` label description in the skill's table and in its `gh label create` call say the same thing as `local/bin/openbuilder`'s `OB_LABELS` entry — compare the three strings and they agree word for word"
  - "`grep -cF 'human-invoked' agent/local/agents/skills/openbuilder-workflow/SKILL.md` still finds Stage 7's merge sentence, and that sentence now names both authorised forms — `openbuilder land` and an authorised `--auto-merge`"
  - "`docs/workflow.md`'s `land` row names both forms too, and `grep -cF 'the only' docs/workflow.md` does not appear in any sentence about merging"
  - "no file outside the four listed above is modified: `git diff --name-only` prints exactly those four paths"
---

## Context

The reviewer rubric currently encodes an invariant that R12 makes false. `agent/local/agents/reviewer.md:85-86`
says any `merge` introduced by a diff is **automatically blocking**, and the skill states flatly that
`A human merges` (`SKILL.md:15`, `:339`) and that `openbuilder:approved` means `human may merge`
(`:290`, `:328`).

After R12 that is wrong in one direction and still right in the other, and the difference is the whole
safety argument:

- The **remote implementer** never merges. Unchanged, absolute, and a merge introduced anywhere it
  executes — `runner/`, `agent/remote/`, anything installed under `/opt/openbuilder` — stays
  automatically blocking.
- The **local reviewer** may merge what it approved, under `--auto-merge`, guarded by all seven
  conditions of RFC §3.8.2, on a per-epic authorisation recorded in `approvals.automerge`.

Leaving the rubric as it is has a concrete cost, not a cosmetic one: it makes the reviewer file a
blocking finding against `story-04`'s own diff, and against every later change to the auto-merge path.
`story-04` works around that by asking the implementer to argue past the rule in its worklog. That is
backwards — a rule that must be argued past on every correct diff is a broken rule. Fix it here, and
`story-04` keeps its worklog citation as an explanation rather than as a defence.

You are editing the rubric a strong model reads before judging a pull request. Precision matters more
than brevity: an over-broad permission here silently disarms the gate that R12's conditions exist to
be.

## Change

### 1. `agent/local/agents/reviewer.md`, the git-boundaries bullet

**Find it by content, never by line number.** `grep -n 'automatically blocking' agent/local/agents/reviewer.md`
locates it. Every line number in this card would be wrong: `plan-workflow-04-agents` inserted six lines
above this bullet after the card was written, and `plan-workflow-05-cli` may shift it again.

Replace the single bullet with one that draws the line by execution context, keeping the phrase
`automatically blocking` (other acceptance items and the skill grep for it):

- Any `merge`, force-push, default-branch push, or write to `/opt/openbuilder/etc` introduced into code
  the **instance** executes — `runner/`, `agent/remote/`, `waker/`, anything installed under
  `/opt/openbuilder` — is **automatically blocking**. The remote implementer never merges; PRD R12 did
  not change that and nothing may.
- A `gh pr merge` in the **laptop** reviewer path (`local/bin/openbuilder`) is permitted by PRD R12 and
  RFC §3.8, and is blocking unless **all** of these hold in the diff you are reading: it is reachable
  only through `--auto-merge`; every one of the seven conditions of RFC §3.8.2 is checked before it,
  with the RFC's refusal string; it uses a GitHub App installation token rather than the operator's
  credentials; and a refusal returns without merging. State which of those you verified.

Keep the bullet's position and the section it lives in. Do not touch any other rubric item.

### 2. The same file, wherever it claims nothing merges without a human

Search for `Nothing merges without you` (it is in the agent's opening paragraph). Replace the absolute
with the true statement: nothing merges without either a human, or an auto-merge a human authorised for
that epic under R12 — and the reviewer's verdict is still the only thing that makes either possible.
Do not soften the sentence into a hedge; it should read as a stronger claim about the reviewer's
position, because it is one.

### 3. `agent/local/agents/skills/review-openbuilder-pr/SKILL.md`

Four edits, no more:

Locate each by content — `grep -nF` on the quoted phrase — not by the line numbers below, which are
from before slug 04 landed and are already stale:

- `A human merges` (was `:15`) — `openbuilder:approved` no longer means "A human merges". It means the instance stops touching
  the pull request forever, and the merge is then either a human's `openbuilder land` or an authorised
  `--auto-merge`. Say that.
- the `gh label create` description and the label table row (were `:290`, `:328`). Both must match `OB_LABELS` in
  `local/bin/openbuilder` word for word, because `story-04` changes that string and the rubric's own
  "frozen names hold" rule (`reviewer.md:100-104`) greps for agreement between them. Read the array
  first and copy from it; do not invent wording and do not edit `local/bin/openbuilder` from this card.
- the **remote agent's** prohibition, the bullet containing `no merge queue` (was `:339`). It stays a prohibition. Add only the clause that makes
  it survive R12: no merge, no `--auto`, no merge queue **from the instance**, and the existence of
  `--auto-merge` on the laptop is not a licence for the remote agent to merge anything, ever.

### 4. `openbuilder-workflow/SKILL.md` and `docs/workflow.md`

Both describe the merge gate as though `land` were the only way code reaches the default branch. Stage 7
of the skill says the merge gate "is `openbuilder land`, human-invoked"; `docs/workflow.md` carries the
same claim in its command table. After R12 there are **two** authorised forms and exactly two:

- `openbuilder land` — a human, with the typed confirmation;
- `openbuilder review --watch --auto-merge` — the reviewer, under all seven conditions, on a per-epic
  `approvals.automerge` a human recorded.

Say that in both files, in one sentence each, and keep the surrounding prose. Do not restate the seven
conditions in either file — they live in the PRD and the RFC, and a third copy would drift. Do not add a
new stage: auto-merge is Stage 7 performed by the reviewer, not a Stage 8.

### 5. Nothing else

You are not implementing auto-merge in this card, not editing `local/bin/openbuilder`, and not touching
`runner/prompts/implement.md` or `agent/remote/agents/implementer.md` — those forbid the implementer from
merging, which is still true and must stay verbatim.

## Acceptance

Beyond the frontmatter items, read your own diff once and answer in the worklog: after your edit, would
a reviewer applying this rubric to `story-04`'s diff reach a blocking finding? Quote the bullet that
decides it. If the answer is yes, the edit is wrong and you must fix it before opening the pull request.

## Out of scope

- Implementing `--auto-merge`, `ob_app_token`, or any condition — `story-04` owns all of it.
- Editing `local/bin/openbuilder`, including its `OB_LABELS` array. Copy from it, never into it.
- Relaxing anything the remote implementer is forbidden to do: `runner/prompts/implement.md:26`,
  `runner/prompts/respond.md:25` and `agent/remote/agents/implementer.md:145` stay exactly as they are.
- Rewriting, reordering, or "tidying" any other rubric item. An unrequested rubric edit is an
  unreviewed change to the thing that reviews changes.
- Adding a second copy of the protected-path list, the conditions table, or the label descriptions.

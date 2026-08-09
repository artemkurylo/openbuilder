---
description: Start or resume the openbuilder design workflow for an epic.
---

# /openbuilder-plan <epic>

1. If `$1` is empty, stop and print exactly:
   `REFUSED: no epic named. Next: /openbuilder-plan <epic>`
2. If `$1` does not match `^[a-z0-9][a-z0-9-]{1,48}$`, stop and print exactly:
   `REFUSED: epic name $1 is not a valid slug. Next: /openbuilder-plan <lower-case-kebab-name>`
3. Read `openbuilder-workflow`'s `SKILL.md` in full before any other tool call.
4. Follow its `## Resumption` section for epic `$1`, then continue at the stage
   that section resolves.
5. Every refusal comes from the skill's `## Refusals` table, verbatim.
6. Approvals are recorded only after the human states one, in their own words —
   this command never records an approval.
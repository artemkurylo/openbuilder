# Close the learnings loop with a `ob-learn` command

`LEARNINGS.md` is the durable store of operational knowledge, and both round scripts already inject it
into every prompt. The write side is still manual: a reviewer who accepts a candidate has to open the
file, find the highest `### N.`, pick the right section, keep the four-line entry shape, remember that
the deny list exists, and get all of it right by hand. Every one of those steps is a chance to publish a
malformed entry — or an employer identifier — into a public repository.

This slice adds one small command, `local/bin/ob-learn`, that does the mechanical part: validate the
entry shape, assign the next number, insert it into the requested section, and refuse outright when the
candidate matches the local deny list. It changes no existing behaviour and adds no dependency.

Scope is deliberately one story. `ob-learn` is a leaf: nothing else in the repo calls it, so it can be
verified in isolation with `shellcheck` and a handful of invocations against a temporary file.

## Stories

1. `story-01-ob-learn` — the command itself, with validation, numbering, section placement, deny-list
   refusal and `--dry-run`.

## Out of scope

- Committing or pushing. `ob-learn` edits the working tree and stops; the reviewer commits, exactly as
  they do today. A command that commits on your behalf is a command that pushes a bad entry on your
  behalf.
- Editing `LEARNINGS.md`'s existing eleven entries, its prose, or its editing rules.
- Any change to `ob-implement`, `ob-respond`, `ob-common.sh`, the prompts, or `infra/`.
- Renumbering or reordering existing entries.

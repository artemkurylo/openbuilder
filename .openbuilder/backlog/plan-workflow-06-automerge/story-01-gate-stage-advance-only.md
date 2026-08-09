---
id: story-01-gate-stage-advance-only
title: Make `ob-gate record` advance the stage pointer, never rewind it
size: S
depends_on: []
files:
  - local/bin/ob-gate
acceptance:
  - "re-running `ob-gate record <epic> prd` on an epic at stage `dispatched` leaves `.stage` equal to `dispatched` in state.json"
  - "that run prints `leaving the stage pointer untouched` on stderr and still records a fresh `approvals.prd.at`"
  - "`ob-gate record <epic> prd` on an epic at stage `intake` still sets `.stage` to `rfc`, and `record <epic> rfc` at `rfc` still sets it to `backlog`"
  - "`ob-gate stage <epic> prd` on an epic at `dispatched` still sets `.stage` to `prd` — the manual override is unchanged"
  - "`shellcheck -x -S warning local/bin/ob-gate` exits 0 with no output"
---

## Context

`record_artifact` (`local/bin/ob-gate:232-252`) computes the next stage from the artifact it recorded
and then writes it unconditionally:

```
  if [[ "$stage" == "prd" ]]; then next="rfc"; else next="backlog"; fi
  ... jq '.approvals[$stage] = {at: $at, blob: $blob} | .stage = $next' ...
```

So re-approving `prd.md` on an epic that has already reached `dispatched` rewinds `.stage` to `rfc`,
and re-approving `rfc.md` rewinds it to `backlog`. Found 2026-08-09 on this epic.

Why that is not cosmetic: rule 4b (`.openbuilder/epics/plan-workflow/rfc.md` §4.2, step 2) declines
any slug whose plan branch carries a `state.json` with `stage != "dispatched"`, and a decline is
`action=skip` — no attempt, no label, no comment, no wake-up (§4.3). A plan branch cut while the
pointer is rewound therefore never runs and never says why. Branches already pushed carry their own
snapshot and are unaffected, so the damage is bounded to slugs dispatched after the rewind — which is
exactly the case a human cannot see.

What you must not change:

- `STAGES=(intake prd rfc backlog dispatched landed)` (`ob-gate:17`) is already the ordering. Use it;
  do not introduce a second list, a map, or numeric constants.
- `cmd_stage` (`ob-gate:218-230`) is the **manual override** and keeps its current freedom to move the
  pointer anywhere in `STAGES`, backwards included. Do not add a monotonicity check there.
- `record_backlog` (`ob-gate:254-295`) does not touch `.stage` today. Leave it that way.
- Every write still goes through `write_state` and every mutation is still committed and pushed by
  `commit_state`. `commit_state` already no-ops when nothing changed (`ob-gate:159-162`).

## Change

In `local/bin/ob-gate`:

1. Add a helper directly above `record_artifact` (i.e. after `cmd_stage` ends at line 230):

   ```
   # stage_index <stage> — 0-based position in STAGES, or -1 for an unknown stage.
   stage_index() { ... }
   ```

   It loops over `"${STAGES[@]}"` with a counter and prints the index of the first exact match, or
   `-1` when there is no match. It never dies.

2. In `record_artifact`, after `next` is computed and before the `jq` pipeline, resolve both
   positions and decide once:

   ```
   cur="$(printf '%s' "$doc" | jq -r '.stage')"
   cur_i="$(stage_index "$cur")"
   next_i="$(stage_index "$next")"
   ```

   - `next_i > cur_i` → `advance=true`.
   - otherwise → `advance=false`.
   - `cur_i` is `-1` (the file carries a stage this script does not know) → `advance=false`, and
     additionally print on stderr:
     `ob-gate: stage '<cur>' is not one of intake, prd, rfc, backlog, dispatched, landed; leaving the stage pointer untouched`

3. Make the assignment conditional. Keep the single `jq` invocation and the existing argument style;
   pass the decision as JSON:

   ```
   printf '%s' "$doc" | jq --arg at "$at" --arg blob "$blob" --arg stage "$stage" \
     --arg next "$next" --argjson advance "$advance" \
     '.approvals[$stage] = {at: $at, blob: $blob} | (if $advance then .stage = $next else . end)' |
     write_state "$epic"
   ```

4. Replace the unconditional `printf '%s stage -> %s\n' "$epic" "$next"` (line 250) with the two
   cases. The approval line at 249 is unchanged.

   - advanced: `printf '%s stage -> %s\n' "$epic" "$next"` — the wording other cards and docs already
     grep for.
   - not advanced: on stdout `printf '%s stage unchanged (%s)\n' "$epic" "$cur"`, and on stderr

     ```
     ob-gate: stage is already <cur>, which is at or past <next>; leaving the stage pointer untouched
     ob-gate: move it deliberately with: ob-gate stage <epic> <stage>
     ```

     Both stderr lines use the `%s: ` prefix style the rest of the script uses (`printf '%s: ...\n'
     "$OB_PROG" ...`), not the `die` helper — this is not a refusal. The approval is still recorded,
     still committed and still pushed.

5. Update the `record` description in `usage()` (`ob-gate:33-35`) so the second line reads
   `write state.json, advance the stage when the recorded artifact's next stage is later than the
   current one, commit with an` — keep the rest of the sentence and the `Approves-<stage>: <sha>`
   trailer text as they are.

Add nothing else. No new subcommand, no new flag, no change to exit codes.

## Acceptance

Every command below runs in a throwaway repository with a real `origin`, because `commit_state`
pushes. Set it up exactly once:

```sh
set -e
tmp=$(mktemp -d)
git init --bare -q "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/wc"
cd "$tmp/wc"
git checkout -qb openbuilder/design/e1
mkdir -p .openbuilder/epics/e1
printf 'prd\n' >.openbuilder/epics/e1/prd.md
printf 'rfc\n' >.openbuilder/epics/e1/rfc.md
git add -A && git commit -qm init && git push -q -u origin HEAD
G=<abs-path-to-this-repo>/local/bin/ob-gate
```

1. **Forward path unchanged.**

   ```sh
   "$G" init e1 --repo you/e1
   "$G" record e1 prd  && jq -r .stage .openbuilder/epics/e1/state.json   # prints rfc
   "$G" record e1 rfc  && jq -r .stage .openbuilder/epics/e1/state.json   # prints backlog
   ```

2. **The regression.** Move to `dispatched`, then re-record `prd`:

   ```sh
   "$G" stage e1 dispatched
   before=$(jq -r '.approvals.prd.at' .openbuilder/epics/e1/state.json)
   sleep 1   # `at` has one-second resolution; without this the two stamps can be equal
   "$G" record e1 prd >/tmp/g.out 2>/tmp/g.err
   jq -r .stage .openbuilder/epics/e1/state.json      # MUST print dispatched
   grep -cF 'leaving the stage pointer untouched' /tmp/g.err   # prints 1
   grep -cF 'e1 stage unchanged (dispatched)' /tmp/g.out       # prints 1
   after=$(jq -r '.approvals.prd.at' .openbuilder/epics/e1/state.json)
   test "$before" != "$after" && echo "approval re-recorded"   # prints the message
   ```

   The `at` comparison is the point: the approval must still be recorded and pushed. A fix that
   refuses the whole `record` instead of skipping the pointer move fails this item.

3. **Same for `rfc`.** `"$G" record e1 rfc` at `dispatched` also leaves `.stage` as `dispatched`.

4. **Equal is not later.** `"$G" stage e1 rfc`, then `"$G" record e1 prd` (whose next stage *is*
   `rfc`): `jq -r .stage` still prints `rfc` and stderr carries
   `stage is already rfc, which is at or past rfc`.

5. **Manual override intact.** `"$G" stage e1 prd` then `jq -r .stage` prints `prd`; `"$G" stage e1
   dispatched` then `jq -r .stage` prints `dispatched`.

6. **Unknown stage.** `jq '.stage = "weird"' state.json` written back in place (via a temp file), then
   `"$G" record e1 prd`: `jq -r .stage` prints `weird`, and stderr contains
   `is not one of intake, prd, rfc, backlog, dispatched, landed`.

7. `shellcheck -x -S warning local/bin/ob-gate` exits 0 and prints nothing.

Clean up with `rm -rf "$tmp"`. Do not run any of this against
`.openbuilder/epics/plan-workflow/state.json`.

## Out of scope

- **Do not add a monotonicity check to `cmd_stage`.** It is the manual override; making it refuse a
  backwards move would leave no way to correct a pointer at all.
- Do not make `record_backlog` write `.stage`. It does not today, and rule 4b requires `dispatched`
  to be set by `openbuilder dispatch`, not by an approval.
- Do not change the `Approves-prd:` / `Approves-rfc:` trailers, the commit subjects, the exit codes,
  or any wording other than the three lines named above.
- Do not touch `verify`, `show`, `init`, `write_state`, `commit_state`, `require_committed` or
  `read_state`.
- Do not add a `--force`, `--no-advance` or `--stage` flag to `record`.
- No new file, no new dependency (`jq` and `git` only, as today), no reformatting of the script and
  no re-ordering of its functions.
- Do not edit `.openbuilder/epics/**`, `runner/**`, `waker/**` or `docs/**` in this story.

---
id: story-02-gate-record-automerge
title: Add `ob-gate record <epic> automerge` and show it in `ob-gate show`
size: S
depends_on: []
files:
  - local/bin/ob-gate
acceptance:
  - "`ob-gate record <epic> automerge` writes `approvals.automerge.at` matching `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$` and a non-empty `approvals.automerge.by`"
  - "the run leaves `.stage` byte-identical and preserves any pre-existing key under `approvals.automerge`, such as `note`"
  - "the HEAD commit message contains the trailer `Approves-automerge: <epic>`"
  - "`ob-gate show <epic>` prints a line containing `automerge authorised`, and `ob-gate verify <epic> --all` prints no line containing `automerge` and exits 0"
  - "`local/bin/ob-gate show plan-workflow` prints `automerge authorised 2026-08-09T21:35:21Z by artemkurylo` from the existing hand-written record"
  - "`shellcheck -x -S warning local/bin/ob-gate` exits 0 with no output"
---

## Context

RFC §3.8.1 makes enabling auto-merge a gate of its own: `ob-gate record <epic> automerge` writes
`approvals.automerge = {at, by}` and commits with an `Approves-automerge:` trailer, and
`openbuilder review --watch --auto-merge` refuses unless that record exists for the epic the pull
request belongs to. So the blast radius of a mistyped flag is one refusal, not a merge.

This record is different from every other one in exactly one way, and the difference must survive
review: **it stores no blob sha**, because it authorizes a *policy* rather than a set of bytes. There
is nothing to hash and nothing it could later be compared against. That is also why `verify` must not
grow an `automerge` case — an approval that cannot be voided has no verification to do — and why
`verify --all` must keep ignoring it.

The authorization already exists in this repository, written by hand in the session that produced
this backlog:

```json
"automerge": {
  "at": "2026-08-09T21:35:21Z",
  "by": "artemkurylo",
  "note": "Authorised in session 2026-08-09. Recorded by hand: ob-gate record <epic> automerge is what plan-workflow-06-automerge builds."
}
```

Your code must **read that shape unchanged** and must not migrate, normalise or rewrite it. In
particular the `note` key must survive a re-record, which is why the assignment below merges instead of
replacing — `.approvals.automerge = {…}` would silently drop it. The script's header comment already
states that unknown keys such as `notes` survive because every write is a `jq` assignment onto the
parsed document (`ob-gate:8-10`); keep that promise.

What to copy:

- `record_artifact` (`ob-gate:232-252`) for the shape of a record function: read the doc, compute
  `at` with `date -u +%Y-%m-%dT%H:%M:%SZ`, pipe through one `jq`, `write_state`, print what happened,
  `commit_state` with a subject and a trailer.
- `cmd_record` (`ob-gate:297-312`) for dispatch, and its `die` message for the unknown-target case.
- `cmd_show` (`ob-gate:314-337`) for the display format.

Traps:

- There is no existing `by` field anywhere in the script; you are adding the first one. The recorded
  value is a GitHub login (`artemkurylo`), which is **not** this laptop's `git config user.name`
  (`Artem Kurylo`). Source it as specified below and do not invent a third source.
- `ob-gate` today needs only `jq` and `git` (`need_jq`, `ob-gate:63-66`). `gh` becomes an *optional*
  input here: when it is missing or fails, fall back, never die on its absence alone.
- `record automerge` must not move `.stage`. It is not an artifact in the `intake -> landed`
  progression.

## Change

In `local/bin/ob-gate`:

### 1. `record_automerge <epic>`

Add directly after `record_backlog` ends (line 295) and before `cmd_record`.

1. `doc="$(read_state "$epic")"`.
2. `at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` — the same format string as `record_artifact:241`.
3. Resolve `by`, in this order, first non-empty wins:
   - `GH_HOST=github.com gh api user --jq .login 2>/dev/null` when `gh` is on `PATH`;
   - `git -C "$REPO_ROOT" config --get user.name`;
   - still empty → `die "cannot determine who is authorising automerge; set one of them, then re-run: gh auth login   |   git config user.name \"<you>\"" 1`.

   `GH_HOST=github.com` is not optional: this laptop's `gh` is authenticated to more than one host and
   the login must come from `github.com` (PRD R11).
4. Merge, do not replace, and do not touch `.stage`:

   ```
   printf '%s' "$doc" | jq --arg at "$at" --arg by "$by" \
     '.approvals.automerge = ((.approvals.automerge // {}) + {at: $at, by: $by})' |
     write_state "$epic"
   ```
5. `printf 'recorded automerge authorisation for %s: by %s at %s\n' "$epic" "$by" "$at"`.
6. `commit_state "$epic" "openbuilder(gate): authorise automerge for $epic" "Approves-automerge: $epic"`.
   The trailer value is the **epic name**, not a sha — there is no artifact. Add a one-line comment
   above the `commit_state` call saying exactly that, so the next reader does not "fix" it.

### 2. `cmd_record`

Add an `automerge)` arm calling `record_automerge "$epic"`, after the `backlog)` arm. Change the
unknown-target message to `(accepted: prd, rfc, backlog, automerge)`.

### 3. `usage()`

Add, immediately after the `record <epic> backlog <slug>` line (`ob-gate:24`):

```
       ob-gate record <epic> automerge
```

and extend the `record` description block (lines 33-35) with one sentence:
`automerge records no blob sha — it authorises a policy, not an artifact, so there is nothing to
compare it against later.`

### 4. `cmd_show`

1. The longest label becomes `automerge`, nine characters. Replace **every** occurrence of `%-8s`
   inside `cmd_show` (lines 314-337) with `%-9s` — `sed -n '314,337p' local/bin/ob-gate | grep -cF
   '%-8s'` prints `9` today and must print `0` afterwards. Change nothing else about those lines.
2. Add one final block after the backlog `if/else` ends (line 336):

   ```
   printf '%-9s %s\n' "automerge" "$(printf '%s' "$doc" | jq -r 'if (.approvals.automerge.at // "") == "" then "not authorised" else "authorised " + .approvals.automerge.at + " by " + (.approvals.automerge.by // "unknown") end')"
   ```

   So a recorded authorization prints `automerge authorised 2026-08-09T21:35:21Z by artemkurylo` and an
   absent one prints `automerge not authorised`.

### 5. `cmd_verify`

No behavioural change. Add a comment immediately above the `case "$target" in` at line 443:

```
  # automerge is deliberately not a verify target: it records an authorisation,
  # not bytes, so there is nothing to re-hash and nothing that can be voided.
  # `verify --all` therefore never reports on it, and `verify <epic> automerge`
  # stays a usage error.
```

`ob-gate verify <epic> automerge` keeps exiting 2 with the existing unknown-target message. Do not add
`automerge` to that accepted list.

## Acceptance

Use the same throwaway repository harness as `story-01` (bare `origin`, a clone on
`openbuilder/design/e1`, `prd.md` and `rfc.md` committed, `G` pointing at this repo's
`local/bin/ob-gate`), then:

1. **The record.**

   ```sh
   "$G" init e1 --repo you/e1
   "$G" record e1 automerge
   jq -r '.approvals.automerge.at' .openbuilder/epics/e1/state.json |
     grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'   # prints 1
   jq -r '.approvals.automerge.by' .openbuilder/epics/e1/state.json        # prints a non-empty login
   jq -r '.approvals.automerge | has("blob")' .openbuilder/epics/e1/state.json   # prints false
   ```

2. **The stage is untouched.**

   ```sh
   before=$(jq -r .stage .openbuilder/epics/e1/state.json)
   "$G" record e1 automerge
   test "$before" = "$(jq -r .stage .openbuilder/epics/e1/state.json)" && echo same   # prints same
   ```

3. **Unknown keys survive.** Seed a `note`, re-record, and assert it is still there:

   ```sh
   jq '.approvals.automerge.note = "keep me"' .openbuilder/epics/e1/state.json >/tmp/s.json
   mv /tmp/s.json .openbuilder/epics/e1/state.json
   git add -A && git commit -qm seed && git push -q origin HEAD
   "$G" record e1 automerge
   jq -r '.approvals.automerge.note' .openbuilder/epics/e1/state.json   # prints keep me
   ```

4. **The trailer.** `git log -1 --format=%B | grep -cF 'Approves-automerge: e1'` prints `1`.

5. **`show`.** `"$G" show e1 | grep -cF 'automerge authorised'` prints `1`. On a fresh epic with no
   record, the same command with `grep -cF 'automerge not authorised'` prints `1`.

6. **`verify` ignores it.** `"$G" verify e1 --all; echo "rc=$?"` — the exit code is whatever the prd,
   rfc and backlog targets produce for that epic (`4` on the harness above, which has no artifact
   approvals), and `"$G" verify e1 --all 2>&1 | grep -cF automerge || true` prints `0`.
   `"$G" verify e1 automerge; echo $?` prints the unknown-verify-target message and `2`.

7. **The existing record, read unchanged.** From this repository's root, read-only, no writes:

   ```sh
   local/bin/ob-gate show plan-workflow |
     grep -cF 'automerge authorised 2026-08-09T21:35:21Z by artemkurylo'   # prints 1
   ```

   This is the item that proves the new code consumes the hand-written shape rather than a shape of
   its own. Do **not** run `record`, `stage` or `init` against `plan-workflow`.

8. `shellcheck -x -S warning local/bin/ob-gate` exits 0 and prints nothing.

Clean up the harness with `rm -rf "$tmp"`.

## Out of scope

- **Do not add a blob sha, a file list, a tree sha or any content hash to the automerge record.** It
  authorizes a policy; there is nothing to hash. A reviewer will read an added sha as a
  misunderstanding of the whole record.
- Do not add an `automerge` case to `verify`, to `verify --all`'s report, or to the accepted verify
  targets, and do not add a void/absent exit path for it.
- Do not add a revoke, unrecord, `--remove` or expiry path. Removing an authorization is editing
  `state.json` by hand, and that is deliberate.
- Do not make automerge per-slug. RFC §3.8.1 scopes it to the epic; a per-slug map is a different
  design and would need a different PRD.
- Do not change `record_artifact`, `record_backlog`, `cmd_stage`, `cmd_init`, `write_state`,
  `commit_state` or any exit code. `story-01` owns `record_artifact` in this same slug — leave it
  alone here.
- Do not add `gh` to `need_jq` or to a new hard requirement check. It is an optional identity source.
- Do not print, log or store an email address anywhere. `by` is a login or a name, and nothing else.
- No new file, no new dependency, no reformatting of the script, no re-ordering of its functions.
- Do not touch `local/bin/openbuilder` in this story — `story-03` and `story-04` own it.

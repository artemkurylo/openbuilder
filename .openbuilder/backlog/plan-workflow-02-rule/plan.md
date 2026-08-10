# feat(poll,waker): rule 4b — decline a plan branch whose backlog is unapproved

- epic: plan-workflow
- implements: PRD **R4**; RFC **§4** (§4.1 placement, §4.2 the check, §4.3 declining quietly, §4.4 parity)
- prerequisite slug: `plan-workflow-01-gate` — rule 4b reads the `state.json` that only `ob-gate` writes

## Goal

A plan branch whose backlog is not approved must not start a round, and must not wake the instance.
`runner/bin/ob-poll` and `waker/github.py` both gain **rule 4b**, sitting between rule 4 and rule 5:
for a slug with a plan branch and no pull request, read the plan branch's `plan.md`, its epic's
`state.json`, and the backlog directory listing; unless `state.json` says `stage: dispatched` and
carries a blob-sha-exact `approvals.backlog[<slug>]` for the committed cards, decline.

A decline is `action=skip` and nothing else: no attempt consumed, no label, no comment, no
`ACTIONABLE` increment, no wake-up (RFC §4.3, PRD R4). The only trace is one `DECISION` line on
stdout carrying a reason string the operator can grep.

## Why now

`ob-poll` today acts on any `openbuilder/plan/<slug>` branch that exists. The whole design-stage
gate (`ob-gate`, slug 01) is therefore enforcement by convention: a branch pushed by hand, by a
script, or by a mistake reaches `ob-implement`, which fails inside `read_backlog`
(`runner/bin/ob-implement:144`) and — via rule 4's budget path — ends as `openbuilder:blocked`,
a state `ob-poll:119` treats as terminal. One human mistake then needs a second human to clear.

Rule 4b turns the gate into a property of the system rather than of the tooling, and RFC §9 makes it a
dependency of `plan-workflow-05-cli`, the slug that teaches `dispatch` to push plan branches.

## Approach

Same table, twice, by contract (`docs/architecture.md:155-189`, "Parity contract"). Every decision
below is fixed here so the two implementations cannot drift on anything but syntax.

**Placement.** Rule `4b`, not a renumbered 5/6/7 (RFC §4.1). In `ob-poll` it goes between the rule-4
block (`runner/bin/ob-poll:124-130`) and the rule-5 block (`runner/bin/ob-poll:132-137`), guarded by
`[[ -z "$pr" ]]`. In `waker/github.py` it goes inside `if found is None:` (`waker/github.py:155-160`),
after the rule-4 `blocked-issue` verdict and before the rule-5 `no-pr` verdict. The verdict's `rule`
value is the **string** `4b`, so both logs read `rule=4b`.

**Three reads, in this order, on the plan branch `openbuilder/plan/<slug>`.**

| # | What | Endpoint |
|---|---|---|
| 1 | `.openbuilder/backlog/<slug>/plan.md`, for the `- epic:` line | contents of a file at a ref: `GET repos/<repo>/contents/<path>?ref=<ref>` |
| 2 | `.openbuilder/epics/<epic>/state.json` | the same contents endpoint |
| 3 | the backlog directory listing, for one blob sha per file | contents of a directory at a ref: `GET repos/<repo>/contents/.openbuilder/backlog/<slug>?ref=<ref>` |

A directory listing entry's `sha` **is** the git blob sha — the same value `git rev-parse <ref>:<path>`
prints. Verified 2026-08-09 (RFC §12): the listing of
`.openbuilder/backlog/scrub-hook?ref=main` returned `worklog.md
05d82535db081b5e86d8833eb2f92f86936213ff`, byte-identical to
`git rev-parse origin/main:.openbuilder/backlog/scrub-hook/worklog.md`. So the file-set comparison
needs one listing call and downloads no card content.

**Five reason strings, byte-identical in both implementations**, all prefixed `backlog-unapproved`
so that one grep finds every decline while each cause stays distinguishable:

| Cause | `reason=` |
|---|---|
| `plan.md` unreadable, or no `- epic:` line, or the epic name fails the slug regex | `backlog-unapproved:no-epic-line` |
| `state.json` unreadable or not parseable JSON | `backlog-unapproved:no-state` |
| parsed, but `stage` is not `dispatched` | `backlog-unapproved:stage=<stage>` |
| no `approvals.backlog[<slug>]`, or its `files` map is absent or empty | `backlog-unapproved:no-approval` |
| the recorded `files` map and the listing disagree | `backlog-unapproved:files-differ(<name>)` |

**Decisions made here so no card leaves one open:**

- **A read failure of any kind is not distinguished from an absent file.** 404, 502, a rate limit and
  a network error all produce the reason above for that read. Justification: a decline has no side
  effect and the next pass is 60 seconds later, so distinguishing them buys nothing and would put a
  second error taxonomy under the parity contract.
- **The compared name set** is the union of the recorded `files` keys and the listing entries with
  `type == "file"` whose name is `plan.md` or matches `story-*.md`. Names are compared in byte order
  (`LC_ALL=C sort` / Python `sorted`), and the **first** name that is missing, extra, or
  sha-different is the one named in `files-differ(<name>)`. A listing file that is neither `plan.md`
  nor `story-*.md` and is not in the recorded map is ignored — `worklog.md` on a plan branch is not a
  decline.
- **Untrusted values are scrubbed before they reach a `DECISION` field**: `<stage>` and `<name>` have
  every character outside `[A-Za-z0-9._-]` removed and are truncated (32 and 48), and an empty result
  renders `-`. `plan.md` and `state.json` are branch content, so a space in a value must not be able
  to break the `key=value` shape of the line.
- **The epic name is validated against `^[a-z0-9][a-z0-9-]{1,48}$` before it is interpolated into an
  API path.** It comes from a file on a branch.
- **Rule 4b calls no logger.** `ob-poll` writes nothing to `$OPENBUILDER_HOME/log/openbuilder.log`
  on an uneventful pass, because `ob-idle-stop` reads that log's mtime as "when work last happened"
  (`runner/bin/ob-poll:6-9`). The whole decline is one `decision` line on stdout.
- **`--dry-run` reaches the identical decision.** Rule 4b is three read-only API calls, so it needs
  no `DRY_RUN` branch; and a dry run takes no lock (`runner/bin/ob-poll:196-198`) and skips
  `ob_ensure_labels` (`runner/bin/ob-poll:220-222`), so exercising it creates nothing.
- **Rule 4b verifies the backlog approval only.** It does not check `approvals.prd`, `approvals.rfc`,
  or that `prd.md`/`rfc.md` exist. Those are `ob-gate verify`'s job in slug 01.

**Verification.** The RFC forbids proving parity by reading the two files side by side (§4.4). Both
implementations are run against the **same seven live fixture branches** in a sandbox repository the
instance does not poll, one branch per decline cause plus the pass case, and their `rule=`/`reason=`
fields are diffed.

**Operator prerequisite, once, before this slug is dispatched.** An installation token cannot create
a user repository, so the human creates the sandbox first and adds it to the openbuilder App
installation:

```sh
GH_HOST=github.com gh repo create artemkurylo/openbuilder-fixture --private --add-readme
# then add openbuilder-fixture to the App installation at
# https://github.com/settings/installations, and confirm the instance can see it:
local/bin/obrun <<'EOF'
source /opt/openbuilder/bin/ob-common.sh; ob_load_env
ob_gh api repos/artemkurylo/openbuilder-fixture --jq .full_name
EOF
```

It must print `artemkurylo/openbuilder-fixture`, and `openbuilder-fixture` must **not** appear in
`OPENBUILDER_REPOS` on the instance or in the waker's Lambda environment.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-ob-poll-rule-4b | Add rule 4b to ob-poll and prove it against live fixture branches | M | [] |
| story-02-waker-rule-4b | Add rule 4b to the waker and diff its decisions against ob-poll | M | [story-01-ob-poll-rule-4b] |
| story-03-architecture-rule-4b | Document rule 4b in the architecture rule and parity tables | S | [story-02-waker-rule-4b] |

## Out of scope

- `local/bin/ob-gate` and anything that **writes** `state.json` — slug `plan-workflow-01-gate`.
- `local/bin/openbuilder`: no `cmd_dispatch` gate check, and no `unapproved` column in
  `cmd_status` — slug `plan-workflow-05-cli` (RFC §8).
- `runner/bin/ob-implement`, `runner/bin/ob-respond`, `runner/prompts/*` — slug
  `plan-workflow-03-context`.
- `runner/bin/ob-common.sh`. Rule 4b is poller-only logic and has exactly one caller; it does not
  belong in the shared library, and the personal-host `ob_load_env` change is slug 00's.
- `docs/runbook.md`, `docs/cost.md`, `README.md`, `LEARNINGS.md`, `backlog/SCHEMA.md`.
- Renumbering rules 5, 6 or 7 anywhere (RFC §4.1, §10).
- Caching, retrying or batching the three API calls. Rule 4b runs only for a slug with no pull
  request, so the steady-state cost is zero (RFC §4.2).
- New files of any kind. RFC §8 assigns this slug exactly four changed files —
  `runner/bin/ob-poll`, `waker/github.py`, `waker/handler.py`, `docs/architecture.md` — and no new
  ones; the fixture script lives in `/tmp` and is never committed.
- Any change to the waker's flap guard, `start_instances` path, `_config`, or `_last_stop_verdict`.

## Risks

- **A one-sided landing is the worst failure available here.** If the waker gains rule 4b and the
  poller does not, unapproved backlogs get implemented anyway; if the poller gains it and the waker
  does not, the waker starts the instance for work the poller then declines and the box bills at
  $0.0384/h until `ob-idle-stop` notices — **every tick**, because the plan branch never goes away
  (RFC §4.4, `docs/architecture.md:184-189`). The catch is story-02's acceptance: both
  implementations run against the same seven fixture branches and the extracted `slug`/`reason`
  fields must `diff` empty, plus `ACTIONABLE=1` on one side and exactly one actionable verdict on
  the other. A reviewer who accepts a side-by-side read of the two files instead has accepted
  nothing.
- **After merge the instance needs `ob-selfupdate` before rule 4b runs, and `ob-selfupdate` is
  allowed to decline while any job lock is held and still exit 0** (`LEARNINGS.md` entry 18;
  `runner/bin/ob-selfupdate:18-29`). The poll timer takes a lock every 60 seconds, so one attempt on
  a busy instance is a coin flip. Assert the deployed effect, not the exit code — after merging,
  repeat until the `tail -3` block contains `self-update complete` and the final line printed is
  `rule-4b-deployed`:

  ```sh
  local/bin/obrun <<'EOF'
  sudo /opt/openbuilder/bin/ob-selfupdate 2>&1 | tail -3
  grep -q backlog-unapproved /opt/openbuilder/bin/ob-poll &&
    echo rule-4b-deployed || echo rule-4b-MISSING
  EOF
  ```

  Treat `skipping self-update for now` as a failure to deploy, because that is what it is.
- **A plan branch cut before `stage: dispatched` is committed declines forever** (RFC §3.5). That is
  the intended behaviour and it is visible as `rule=4b reason=backlog-unapproved:stage=backlog` on
  every pass; the fix is slug 05's dispatch ordering, not a looser gate here.
- **The fixture exercise must run the modified script, not the deployed one.** The installed
  `/opt/openbuilder/bin/ob-poll` is the previous deploy; run the copy in the worktree by absolute
  path. If the wrong copy is exercised, no `rule=4b` line appears and the acceptance fails loudly
  rather than passing quietly.
- **Writing the sandbox env file into `/opt/openbuilder/etc/` is blocked** by the pre-tool guardrail
  (`agent/hooks/pre/guardrails.ts:30`, prohibition 7), and `git push --force` is blocked by
  prohibition 2. The fixture recipe therefore keeps its env file in `/tmp` and deletes remote
  branches before re-creating them instead of force-pushing.

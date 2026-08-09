# The openbuilder workflow

One entry point, seven stages, four human gates. Each gate is a decision recorded
on a branch rather than in a session, so the workflow survives a closed session
and a week of interruption.

> Status — the design stages run today. The backlog gate inside `openbuilder dispatch`, the `--watch` flag on `openbuilder review` and the `openbuilder land` command arrive with the `plan-workflow-05-cli` slug; until it lands, dispatch does not check the backlog gate and merging is manual. <!-- remove when plan-workflow-05-cli lands -->

## The four commands

| Command | What it does | Ends when |
|---|---|---|
| `openbuilder plan <owner/repo> <epic>` | prepares the clone, checks out or creates `openbuilder/design/<epic>`, launches the Opus 5 session, and resumes at the recorded stage. `/openbuilder-plan <epic>` is the same thing from inside an already-running session in that clone | the session is ready at the recorded stage |
| `openbuilder dispatch <owner/repo> <slug>` | verifies the backlog gate, commits `stage: dispatched`, and cuts `openbuilder/plan/<slug>` from the design branch tip — in that order | the plan branch exists on `origin` |
| `openbuilder review --watch <owner/repo> <pr>` | polls the pull request's labels every 60 s and drives reviewer/worker rounds to a verdict, capped at `OPENBUILDER_MAX_ATTEMPTS` (6) | `openbuilder:approved` (exit 0), `openbuilder:blocked` (exit 4), or the cap |
| `openbuilder land <owner/repo> <pr>` | refuses without `openbuilder:approved`, then squash-merges, deletes the epic's branches on `origin`, and removes the instance's worktree and per-slug state | the PR is merged; nothing of the epic remains on `origin` or the instance |

The four in sequence, for one epic:

```sh
openbuilder plan <owner/repo> <epic>
# expect: openbuilder/design/<epic> checked out or created; the session resumes at the recorded stage

openbuilder dispatch <owner/repo> <slug>
# expect: openbuilder/plan/<slug> pushed to origin

openbuilder review --watch <owner/repo> <pr>
# expect: openbuilder:approved label set; exit 0

openbuilder land <owner/repo> <pr>
# expect: pull request merged; branches deleted from origin
```

The boundary is absolute: nothing but `openbuilder land` merges, ever, and it is
human-invoked and refuses to guess a pull request.

## The seven stages

| # | Stage | Actor | Model | Artifact | Gate |
|---|---|---|---|---|---|
| 1 | intake | main session | Opus 5 | `intake.md` | the grill's stopping rule reached |
| 2 | prd | main session | Opus 5 | `prd.md` | human approves in the session |
| 3 | rfc | `architect` subagent | Opus 5 | `rfc.md` | human approves in the session |
| 4 | backlog | `planner` subagent | Opus 5 | `.openbuilder/backlog/<slug>/` | human approves that slug |
| 5 | dispatch | `openbuilder dispatch` | — | `openbuilder/plan/<slug>` on `origin` | the backlog gate |
| 6 | review | `openbuilder review --watch` | Opus 5 | a PR review and one `openbuilder:*` label | the `openbuilder:approved` verdict |
| 7 | land | `openbuilder land` | — | the squash merge and the branch deletions | the `openbuilder:approved` label |

`state.json.stage` has six values (`intake | prd | rfc | backlog | dispatched |
landed`) because `review` runs while the pointer still reads `dispatched`.

## The four gates

The gates are PRD, RFC, backlog (once per slug) and merge. At each design gate the
mechanism is the same: a human approves in the session, and `local/bin/ob-gate` —
never a model — computes the artifact's git blob sha, writes it into `state.json`,
advances `stage`, and commits with an `Approves-<stage>: <sha>` trailer.

Why a blob sha: it is what git already computes for the exact bytes,
`git rev-parse <ref>:<path>` yields it locally and the GitHub contents API returns
the identical value as the `sha` field of a directory entry, so the same record is
verifiable from the laptop, from the instance and from the waker with no shared
secret and no clock. Edit the artifact and the approval is void by construction
rather than by policy.

`ob-gate`'s surface:

| Invocation | What it does |
|---|---|
| `ob-gate init <epic> --repo <owner/repo>` | creates `state.json` at `stage: intake` |
| `ob-gate stage <epic> <stage>` | advances the stage pointer, no approval |
| `ob-gate record <epic> prd\|rfc` | records approval of that stage's artifact |
| `ob-gate record <epic> backlog <slug>` | records approval of a backlog directory |
| `ob-gate verify <epic> [prd\|rfc\|backlog [<slug>]\|--all]` | re-checks every recorded approval |
| `ob-gate show <epic>` | prints the state, human-readable |

`ob-gate verify`'s exit codes:

| Exit code | Meaning |
|---|---|
| `exit 0` | intact — every recorded approval still matches the current blobs |
| `exit 3` | void — the recorded blob no longer matches the file on this branch |
| `exit 4` | absent — no approval recorded |

The merge gate is not an `ob-gate record`; it is `openbuilder land` refusing
anything without `openbuilder:approved`.

The poller and the waker enforce the backlog gate independently as rule 4b, so a
plan branch pushed by hand with an unapproved backlog produces no round, no
attempt, no label and no wake-up — the decline is `action=skip` and nothing else.

## Refusals

Every refusal names the reason and the exact next command, because a refusal a
human has to debug is worse than the mistake it caught.

| Situation | Message | Fix |
|---|---|---|
| `<stage>` not approved in this session | `REFUSED: <stage> is not approved in this session. Next: read the artifact above and say approve.` | read the artifact above and say `approve` in this session |
| `ob-gate verify <epic> --all` exits 3 — the recorded blob no longer matches | `REFUSED: approval for <stage> is void - the recorded blob no longer matches the file on this branch. Next: ob-gate record <epic> <stage>` | read the diff, decide, and re-approve |
| `ob-gate verify <epic> --all` exits 4 — no approval recorded | `REFUSED: no approval recorded for <stage>. Next: ob-gate record <epic> <stage>` | run `ob-gate record <epic> <stage>` |
| `backlog <slug>` contains no story card | `REFUSED: backlog <slug> contains no story-*.md card. Next: write at least one card, then ob-gate record <epic> backlog <slug>` | write at least one `story-*.md` card, then record |
| the design branch `openbuilder/design/<epic>` is behind `origin` | `REFUSED: openbuilder/design/<epic> is behind origin. Next: git pull --ff-only origin openbuilder/design/<epic>` | pull the design branch with `--ff-only` |
| the working tree is dirty | `REFUSED: the working tree is dirty. Next: git status --short, then commit or stash before advancing a stage` | commit or stash, then advance |

Un-voiding an approval:

```sh
ob-gate verify <epic> --all
# expect: exit 3 - the artifact changed after approval, so the approval is void

# read the diff and decide; if you still approve:
ob-gate record <epic> <stage>
# expect: exit 0 - approval re-recorded, stage advanced
```

## Resuming after a lost session

1. Check out `openbuilder/design/<epic>`, or create it from `origin/<default>` and
   push it.
2. No epic directory → `ob-gate init <epic> --repo <owner/repo>` at
   `stage: intake`, and begin the grill.
3. Epic directory present → read `state.json`, then `ob-gate verify <epic> --all`:
   exit 0 resumes at `stage`, exit 3 refuses as void, exit 4 refuses as absent.
4. `stage: intake` → read `intake.md` first and continue at the first block whose
   `**Answered**` line is still `_pending_`.

Never re-ask an answered question. The grill's stopping rule:

> Ask a question only while its answer would change a PRD requirement, an RFC
> decision, or an acceptance criterion. Answer from the repository anything the
> repository can answer. When the human says enough, every still-open question
> becomes a stated assumption in prd.md, never a silent guess.

Each question is one block in `intake.md` — `### Qn — question`, `**Asked
because**`, `**Answered**`, `**Consequence**` — and `**Answered** _pending_` is
the exact marker resumption looks for, so an answered question is never re-asked.

## Where the artifacts live

| Path | Carried by | Reaches `main`? |
|---|---|---|
| `.openbuilder/epics/<epic>/intake.md` | `openbuilder/design/<epic>`, copied onto the work branch | yes |
| `.openbuilder/epics/<epic>/prd.md` | `openbuilder/design/<epic>`, copied onto the work branch | yes |
| `.openbuilder/epics/<epic>/rfc.md` | `openbuilder/design/<epic>`, copied onto the work branch | yes |
| `.openbuilder/epics/<epic>/state.json` | `openbuilder/design/<epic>` only | no |
| `.openbuilder/backlog/<slug>/` | `openbuilder/design/<epic>`, snapshotted onto `openbuilder/plan/<slug>` | the cards land with the pull request |

`intake.md`, `prd.md` and `rfc.md` are copied onto the work branch by `ob-implement`
as the round's first commit, `docs(epic): PRD and RFC for <epic>`. `state.json` is
deliberately excluded: it is coordination state whose stage pointer is stale the
moment the branch is deleted, and a stale file on `main` is worse than a missing
one.

Two branch namespaces close the loop: `openbuilder/design/<epic>` is invisible to
the poller and the waker, which match `refs/heads/openbuilder/plan/` only, so the
design phase cannot start a round by accident; `openbuilder/plan/<slug>` is the
trigger.

GitHub is the only message bus between laptop and instance, and openbuilder
operates on `github.com` and on no other host.
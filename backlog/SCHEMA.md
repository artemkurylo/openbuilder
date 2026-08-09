# Story card contract

This file is authoritative. A story card that does not conform is a bug — the remote agent reads these
files literally and does exactly what they say, nothing more and nothing less.

Cards live in the **target** repo, committed on the plan branch `openbuilder/plan/<slug>`:

```
.openbuilder/backlog/<slug>/plan.md                 # the epic: why, and the ordered story list
.openbuilder/backlog/<slug>/story-01-<name>.md      # one card per slice; NN is 01, 02, 03 in order
.openbuilder/backlog/<slug>/story-02-<name>.md
.openbuilder/backlog/<slug>/worklog.md              # written by the instance on the work branch
```

`<slug>` matches `^[a-z0-9][a-z0-9-]{1,48}$`. `ob-implement` reads **every** `story-*.md` in the directory
in filename order and hands them all to one omp run, so `NN` is what controls the sequence on disk.

Three hard requirements outside the frontmatter:

- **`plan.md` must start with a `# ` heading.** `ob-implement` derives the pull request title from it. No
  heading, no usable PR title.
- **`plan.md` must carry an `- epic:` line.** Directly under the `# ` heading, as a plain bullet, written
  `- epic: <epic>`, it names the directory `.openbuilder/epics/<epic>/` that holds the PRD and the RFC
  this backlog implements. It is a plain bullet and not frontmatter because `plan.md` has no frontmatter
  and the value is read with `awk '/^- epic:/ {print $3; exit}'`. Omit it and nothing can find the design
  documents or the recorded approval for this slug from the card alone.
- **`worklog.md` is not yours to write.** The instance creates and appends to it on the work branch, one entry
  per round. Do not commit one on the plan branch.

## Frontmatter

YAML, fenced by `---` at the very top of the file. All six keys are required; `depends_on` may be empty.

```yaml
---
id: story-01-healthz-route
title: Add a /healthz endpoint returning service status
size: S
depends_on: []
files:
  - src/routes/health.js
  - src/app.js
acceptance:
  - "GET /healthz returns HTTP 200"
  - "the response body is {\"status\":\"ok\",\"uptime\":<number>}"
  - "npm test passes, including a new test in test/health.test.js"
---
```

| Key | Type | Rules |
|---|---|---|
| `id` | string | Must equal the filename without `.md`. This is what the agent and the worklog cite, so it must be stable and unique within the slug. |
| `title` | string | One imperative line, under ~80 chars. Ends up in the commit message and the PR checklist. Say what changes, not what you hope for. |
| `size` | `S` \| `M` \| `L` | Exactly one of these three letters. See [Sizing](#sizing). |
| `depends_on` | list of `id` | Story ids in this same slug that must be complete first. `[]` if none. See [Ordering](#ordering-and-depends_on). |
| `files` | list of paths | Repo-relative paths the story is expected to touch. Not a hard boundary — a scope declaration. |
| `acceptance` | list of strings | Mechanically checkable conditions. See [Acceptance criteria](#acceptance-criteria-must-be-mechanically-checkable). |

`files` earns its place by being the fastest thing in the card to review. If the agent's diff touches
files you did not list, that is a signal — usually that the story was under-specified, occasionally that
the agent wandered. It also tells the agent where to start reading instead of grepping the whole repo.
List the files you expect to change, including new ones and the test file. Do not list every file it might
need to *read*.

## Body sections

Exactly these four `##` headings, in this order, all present:

### `## Context`

Why this story exists and what the agent needs to know that is not obvious from the code. Point at the
existing patterns it should copy — "follow the shape of `src/routes/version.js`" saves a review round.
Name constraints: framework version, an existing convention, a thing that must not change.

Do not restate the change here. Do not write history the agent cannot act on.

### `## Change`

The instruction. Imperative, step by step, specific enough that two different engineers would produce the
same diff. Name the functions, the routes, the field names, the file paths. If a decision matters, make it
here — the agent is told to **stop and explain rather than guess at missing requirements**, so an
unanswered question costs you a full round and an attempt.

### `## Acceptance`

Prose expansion of the `acceptance` frontmatter list: exact commands to run and exact expected output.
The frontmatter list is the checklist; this section is how to verify each item. Include the repo's own
test and lint commands, because the agent is instructed to run them if they exist.

### `## Out of scope`

The most under-used section in the file, and the one that saves the most money. Weak models generalise:
ask for one endpoint and you may get authentication middleware, a rate limiter and a refactor of the
router. Every "no" here is a diff you do not have to review.

Name the adjacent work explicitly. "No auth on this route", "do not touch `src/db.js`", "no new
dependencies", "no changes to the CI workflow".

## Sizing

`size` is an honest estimate of the diff, not of the difficulty.

| Size | Means | Typical shape |
|---|---|---|
| **S** | One file, maybe a test alongside it. Under an hour for a competent human. | Add a route. Add a validation check. Fix an off-by-one with a regression test. |
| **M** | A few files that have to change together. | A new module plus its wiring plus its tests. A schema field threaded through two layers. |
| **L** | **Should probably be split.** | Anything you cannot describe in `## Change` without writing "and then". |

`L` is a smell, not a size. It exists so the planner can be honest instead of mislabelling a large story
as `M`, and it is a prompt to go back and cut. The failure mode is concrete: a large story burns
`OPENBUILDER_MAX_ATTEMPTS` (default 6) on review rounds that each re-litigate a different third of the
diff, then lands `openbuilder:blocked` with nothing merged. Two `S` stories that each merge beat one `L`
that never does.

Rule of thumb: if `files` has more than about five entries, or `acceptance` has more than about five
items, split it.

## Ordering and `depends_on`

`ob-implement` gives the agent every story in the slug at once, in filename order, in a single run.
`depends_on` is what tells the agent that order is **required** rather than incidental — that story 02
must not be started until 01's interface exists, because it consumes it.

Consequences worth understanding:

- Use `depends_on` to encode real data or interface dependencies. "Story 02 imports the `health()` helper
  story 01 adds" is a dependency. "Story 02 is in the same file" is not.
- Keep the dependency graph shallow. A chain of five dependent stories is one `L` story wearing a hat, and
  it will fail the same way: if 01 goes wrong, everything downstream is wrong, and a single review round
  cannot fix it.
- Independent stories (`depends_on: []`) are what you want. They can be reviewed, and if necessary
  re-driven, in isolation.
- `depends_on` references the `id`, not the filename or the number: `depends_on: [story-01-healthz-route]`.

If two stories genuinely cannot be separated, they are one story. Merge them and size it `M`.

## Acceptance criteria must be mechanically checkable

This is the single rule that decides whether the loop converges.

Every entry in `acceptance` must be something a machine, or a reviewer running one command, can declare
true or false without judgement. The reason is structural: the remote agent uses these criteria to decide
it is finished, and the reviewer uses them to decide whether to approve. If the criterion needs an opinion,
both ends of the loop are guessing, and guessing costs an attempt.

Concretely, an acceptance criterion should name a command and its expected result, an observable HTTP
response, an exact string in an output, or a test that must pass. It should never contain "correctly",
"properly", "gracefully", "reasonable", "clean", "as appropriate", or "if needed".

| Not checkable | Checkable |
|---|---|
| Error handling works properly | `GET /healthz` with the database stopped returns 503 and `{"status":"degraded"}` |
| The code is clean and idiomatic | `npm run lint` exits 0 with no new warnings |
| Performance is acceptable | `/healthz` responds in under 50 ms locally, measured with `curl -w '%{time_total}'` |
| Tests are added | `test/health.test.js` exists and `npm test` passes, including a case for the 503 path |
| The endpoint is documented | `README.md` contains a `## Health check` section documenting the route and both status codes |

## Template

Copy this and fill it in. This is a complete, valid card.

```markdown
---
id: story-02-healthz-db-check
title: Report degraded status from /healthz when the database is unreachable
size: S
depends_on:
  - story-01-healthz-route
files:
  - src/routes/health.js
  - test/health.test.js
acceptance:
  - "GET /healthz returns 200 and {\"status\":\"ok\"} when the database responds"
  - "GET /healthz returns 503 and {\"status\":\"degraded\"} when the database throws"
  - "test/health.test.js covers both paths and npm test passes"
  - "npm run lint exits 0"
---

## Context

Story 01 added `src/routes/health.js` with a static `{"status":"ok"}` response. The load balancer uses
this route for target health, so it must go unhealthy when the service cannot serve real traffic.

The database handle is exported as `db` from `src/db.js` and exposes `db.ping()`, which resolves on
success and rejects on failure. `src/routes/version.js` shows the established pattern for a route that
awaits something and branches on the result. The project uses `node:test` with `node --test`, wired to
`npm test`.

## Change

1. In `src/routes/health.js`, import `db` from `../db.js`.
2. Make the handler `async`. Wrap `await db.ping()` in `try`/`catch`.
3. On success, respond `200` with `{ status: "ok", uptime: process.uptime() }` as today.
4. On a rejection, respond `503` with `{ status: "degraded", uptime: process.uptime() }`. Do not include
   the error message or stack in the response body.
5. Log the caught error once via the existing `log.warn` from `src/log.js`. Do not add a logging library.
6. In `test/health.test.js`, add two cases using the existing `withStubbedDb` helper: one where `ping`
   resolves and one where it rejects. Assert both the status code and the parsed body.

## Acceptance

- `npm test` passes; `test/health.test.js` contains a passing case for each of the two paths.
- Manual check, service running with the database up:
  `curl -s -o /dev/null -w '%{http_code}' localhost:3000/healthz` prints `200`.
- Manual check with the database stopped: the same command prints `503`, and
  `curl -s localhost:3000/healthz` prints `{"status":"degraded","uptime":<number>}`.
- `npm run lint` exits 0.

## Out of scope

- No caching or debouncing of the ping result.
- No new dependencies.
- No changes to `src/db.js`, the connection settings, or retry behaviour.
- No changes to `.github/workflows/`.
- No readiness/liveness split — one route only.
```

## Bad vs good

The same story, written two ways. The first one costs you six attempts and a `openbuilder:blocked` label.

### Bad

```markdown
---
id: story-01
title: Health check
size: M
depends_on: []
files: []
acceptance:
  - "it works"
---

## Context

We need health checks.

## Change

Add a health endpoint and make sure errors are handled properly. Add tests.

## Acceptance

The endpoint works correctly and the tests pass.

## Out of scope

Nothing.
```

What goes wrong, specifically:

- `id: story-01` does not match the filename, so the worklog and PR checklist cannot cite it unambiguously.
- `files: []` gives the agent no starting point; it will grep the repo and guess at conventions.
- "handled properly" is the exact phrasing the agent is instructed to stop and ask about — or, worse, to
  invent an answer for. Either way you lose a round.
- "it works" is not a criterion. Neither the agent nor the reviewer can evaluate it, so the review round
  becomes a design conversation held through PR comments at one round per 60-second poll.
- `## Out of scope: Nothing` is an invitation. Expect middleware you did not ask for.
- `size: M` with one route in it means the planner was not paying attention, and sizing stops being a
  signal.

### Good

```markdown
---
id: story-01-healthz-route
title: Add a GET /healthz endpoint returning status and uptime
size: S
depends_on: []
files:
  - src/routes/health.js
  - src/app.js
  - test/health.test.js
acceptance:
  - "GET /healthz returns HTTP 200 with content-type application/json"
  - "the body is {\"status\":\"ok\",\"uptime\":<number of seconds>}"
  - "test/health.test.js asserts the status code and the body shape, and npm test passes"
  - "npm run lint exits 0"
---

## Context

The load balancer needs an unauthenticated route it can poll. `src/routes/version.js` is the closest
existing example: a small module exporting a handler, registered in `src/app.js` alongside the other
routes. Express 4, `node:test` via `npm test`, ESLint via `npm run lint`.

## Change

1. Create `src/routes/health.js` exporting a single handler, following the shape of
   `src/routes/version.js`.
2. Respond `200` with JSON `{ status: "ok", uptime: process.uptime() }`.
3. Register it in `src/app.js` as `GET /healthz`, above the auth middleware so it stays unauthenticated.
4. Create `test/health.test.js` with one case asserting status `200` and both body fields.

## Acceptance

- `npm test` passes and includes the new test file.
- With the service running, `curl -s localhost:3000/healthz` prints
  `{"status":"ok","uptime":<number>}` and `curl -s -o /dev/null -w '%{http_code}'` on the same URL
  prints `200`.
- `npm run lint` exits 0.

## Out of scope

- No authentication on this route — it must stay reachable without a token.
- No database or dependency checks; status is static in this story.
- No new dependencies.
- No changes to `.github/workflows/` or the Dockerfile.
```

The difference is not length. It is that every line of the good card is either a fact the agent needs or a
condition someone can check.

## See also

- [`example/plan.md`](example/plan.md) and [`example/story-01-example.md`](example/story-01-example.md) —
  a real filled-in pair.
- [`../docs/cost.md`](../docs/cost.md) — why rounds per story is the cost lever that matters, and why
  card quality is therefore a budget decision.

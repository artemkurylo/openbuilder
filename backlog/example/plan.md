# Add a /healthz endpoint to the widget-api service

> Example plan. This is what `openbuilder plan you/widget-api healthz-endpoint` produces and what you
> commit to `openbuilder/plan/healthz-endpoint` as
> `.openbuilder/backlog/healthz-endpoint/plan.md`. The first `# ` heading above becomes the pull request
> title, so it reads as a change, not as a topic.

**Slug:** `healthz-endpoint`
**Target repo:** `you/widget-api`
**Work branch:** `openbuilder/work/healthz-endpoint`

## Why

`widget-api` sits behind an ALB target group that currently health-checks `GET /` — the same route that
renders the index page. That route stays up as long as the Node process is alive, so a container with a
dead database connection keeps receiving traffic and returning 500s to real users. We have been paged for
this twice.

We need a dedicated, unauthenticated, cheap route whose status code reflects whether the service can
actually serve requests, so the ALB can pull a bad task out of rotation on its own.

## Scope

One route, `GET /healthz`, returning `200` with a small JSON body when the service is healthy. Static for
now: it reports liveness and uptime, not dependency health. Wiring the database ping into it is deliberate
follow-up work, not part of this slug — see [Out of scope](#out-of-scope).

The ALB target group change itself is a Terraform change in a different repository and is not part of this
slug either.

## Stories

- [ ] `story-01-example` — Add a `GET /healthz` route returning status and uptime, with a test (**S**, no dependencies)

One story, one PR. That is a perfectly good plan: the change is a single file plus its registration plus a
test, and splitting it further would create dependent stories with nothing to gain. See
[../SCHEMA.md](../SCHEMA.md#sizing).

## Context the agent needs

- Express 4. The app is assembled in `src/app.js`, which registers routes and then applies
  `requireToken` from `src/auth.js` as middleware.
- `src/routes/version.js` is the closest existing route: a small module exporting one handler, registered
  in `src/app.js`. Copy its shape.
- Tests are `node:test`, run with `node --test test/`, wired to `npm test`. `test/version.test.js` is the
  pattern to follow, including how it boots the app with `createApp()` from `src/app.js`.
- Lint is ESLint via `npm run lint`. It runs in CI and must stay clean.

## Verification for the whole slug

```sh
npm ci
npm test
npm run lint
node src/index.js &
curl -s localhost:3000/healthz
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/healthz
```

Expected: `npm test` and `npm run lint` both exit 0; the first `curl` prints
`{"status":"ok","uptime":<number>}`; the second prints `200`.

## Out of scope

- No database, cache or downstream dependency checks in this slug. A follow-up story adds `db.ping()` and
  a `503` degraded path; keeping it separate means this PR can merge today and the ALB can be pointed at
  the new route immediately.
- No `/readyz` or liveness/readiness split.
- No metrics, tracing or new dependencies.
- No changes to `src/auth.js`, `src/db.js`, the Dockerfile, or `.github/workflows/`.
- No change to the ALB target group — that lives in the `you/infra` repo.

## Notes for the reviewer

The one thing worth checking carefully is **route registration order** in `src/app.js`. `/healthz` must be
registered *above* the `requireToken` middleware, or the ALB will get `401` and mark every task unhealthy.
That is the failure this plan is most likely to produce, so it is the first thing to look at in the diff.

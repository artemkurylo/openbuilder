---
id: story-01-example
title: Add a GET /healthz endpoint returning status and uptime
size: S
depends_on: []
files:
  - src/routes/health.js
  - src/app.js
  - test/health.test.js
acceptance:
  - "GET /healthz returns HTTP 200 with content-type application/json"
  - "the response body is {\"status\":\"ok\",\"uptime\":<seconds as a number>}"
  - "GET /healthz succeeds without an Authorization header"
  - "test/health.test.js asserts the status code, the content type and both body fields, and npm test passes"
  - "npm run lint exits 0"
---

## Context

`widget-api` is behind an ALB target group that health-checks `GET /`, which stays up as long as the Node
process is alive. We need a dedicated route the load balancer can poll, and it must be reachable without a
token or the ALB will see `401` and mark every task unhealthy.

What you need to know about this repo:

- Express 4. The app is assembled by `createApp()` in `src/app.js`, which registers routes and then applies
  `requireToken` from `src/auth.js` as middleware for everything below it.
- `src/routes/version.js` is the closest existing route — a module exporting one handler, registered in
  `src/app.js`. Copy its shape exactly; do not introduce a router factory or a new directory convention.
- `test/version.test.js` is the test pattern, including how it boots the app with `createApp()` and how it
  issues requests. Tests are `node:test`, run with `node --test test/` via `npm test`.
- Lint is ESLint via `npm run lint`; it runs in CI and must stay clean.
- `process.uptime()` returns seconds as a float. That is the value to report; do not round it or convert it.

## Change

1. Create `src/routes/health.js`. Export a single handler named `health`, following the export style of
   `src/routes/version.js`.
2. The handler responds `200` with JSON `{ status: "ok", uptime: process.uptime() }`. Use the same
   `res.json(...)` call style as `version.js` so the content type is set by Express.
3. In `src/app.js`, import the handler and register it as `app.get("/healthz", health)`. Register it
   **above** the `app.use(requireToken)` line, so the route is not authenticated. Put it next to the
   existing `/version` registration.
4. Create `test/health.test.js` with one test case:
   - build the app with `createApp()` the way `test/version.test.js` does;
   - issue `GET /healthz` with no `Authorization` header;
   - assert the status is `200`;
   - assert the `content-type` header starts with `application/json`;
   - assert the parsed body has `status === "ok"` and `typeof body.uptime === "number"`.
5. Do not assert an exact `uptime` value — it changes on every run. Assert the type only.

## Acceptance

- `npm test` exits 0 and the run includes `test/health.test.js` with a passing case.
- `npm run lint` exits 0 with no new warnings.
- With the service running (`node src/index.js`):

  ```sh
  curl -s localhost:3000/healthz
  # {"status":"ok","uptime":12.345}

  curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/healthz
  # 200

  curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization:' localhost:3000/healthz
  # 200   <- still 200: the route is not behind requireToken
  ```

- `git diff --stat` touches only `src/routes/health.js`, `src/app.js` and `test/health.test.js`.

## Out of scope

- No database, cache or downstream dependency checks. This route is static in this story; the `db.ping()`
  degraded path is a separate follow-up story.
- No `503` path, no `/readyz`, no liveness/readiness split.
- No metrics, tracing, logging middleware or new dependencies — `package.json` must not change.
- No changes to `src/auth.js`, `src/db.js`, the Dockerfile, or `.github/workflows/`.
- No refactor of `src/app.js` beyond the two lines this story adds.
- No change to the ALB target group; that lives in the `you/infra` repo.

---
name: write-backlog
description: How to slice a feature into openbuilder story cards - sizing heuristics, the slicing rules, the exact frontmatter and body schema, and a full worked example. Use when writing or reviewing anything under .openbuilder/backlog/<slug>/.
globs: .openbuilder/backlog/**/*.md
---

# Writing an openbuilder backlog

A backlog is a contract between a strong planner (Opus 5, on a laptop, with you in
the loop) and a weak implementer (DeepSeek V4 Flash, on a headless instance, alone, at
3am, with no way to ask a question). The story card is the entire interface.

The failure mode you are designing against is not "the implementer cannot code". It
is "the implementer had to choose, chose plausibly, and chose wrong" — producing a
diff that looks fine and is not. Every ambiguity you leave is a coin flip you are
delegating.

## Layout

```
.openbuilder/backlog/<slug>/
├── plan.md                    # intent, approach, story table, risks
├── story-01-<name>.md
├── story-02-<name>.md
└── worklog.md                 # NOT yours - the implementer creates this
```

`<slug>` matches `^[a-z0-9][a-z0-9-]{1,48}$`. Numbers are zero-padded, dense, and
ordered by dependency: `01`, `02`, `03`. `<name>` is a short kebab-case handle.

The first `# ` heading of `plan.md` becomes the pull request title. Write that line
as a PR title.

## The card schema

Frontmatter keys — exactly these, no others:

| Key | Type | Meaning |
|---|---|---|
| `id` | string | `story-<NN>-<name>`, matching the filename stem |
| `title` | string | One imperative line, ≤ 72 chars |
| `size` | `S` \| `M` \| `L` | See the sizing table |
| `depends_on` | list of story ids | Same slug only; `[]` when independent |
| `files` | list of paths | Where the change is expected to land |
| `acceptance` | list of strings | Mechanically checkable, one per line |

Body sections, in this order, with these exact headings:

- `## Context` — what exists today, the pattern to follow, the file it lives in, and
  the traps. This is where your research goes.
- `## Change` — precisely what to do: files, symbols, signatures, error behaviour.
- `## Acceptance` — the prose version of the frontmatter list, with the exact
  commands to run.
- `## Out of scope` — the improvements the implementer must *not* make.

## Slicing rules

### 1. Slice on value, then on repo boundary

Every story must deliver something a human would call done. "Add the types" is not
done. "`ob-token` mints a token and prints it" is done.

The seductive wrong answer is slicing by layer:

> ✗ story-01: add the type definitions
> ✗ story-02: add the parsing logic
> ✗ story-03: wire it into the CLI

None of those is independently verifiable, none is independently reviewable, and the
PR only makes sense read end to end — which is exactly the review you cannot afford
from a cheap model. Slice by capability instead:

> ✓ story-01: `ob-token` mints an installation token from the App private key
> ✓ story-02: `ob-token` caches the token on disk and reuses it while valid
> ✓ story-03: `ob-doctor` reports token mint health in its PASS/FAIL table

Secondary axis: the repo boundary. A story that touches `infra/` and `runner/` and
`docs/` is usually three stories, because each has a different verification command
and a different reviewer concern.

### 2. Each story is independently verifiable

Before you write the card, name the command. `bash runner/bin/ob-token | wc -c`,
`terraform validate`, `npm test -- src/token.test.ts`, `shellcheck -x runner/bin/*`.
If you cannot name a command, test, or concrete observation that demonstrates *this
story* landed, it is not a story. Merge it into its neighbour, or re-cut the slice.

### 3. Keep the dependency graph shallow

`depends_on` is a chain or a fan-out, not a lattice. If `story-05` depends on both
`02` and `04`, ask whether `02` and `04` were ever really separate. Deep graphs mean
the implementer cannot make progress after the first blocked story.

### 4. 3–7 stories

One story is legitimate for genuine one-PR work — do not pad. Two to three is the
common case. More than about eight means the slug is two slugs; split it, and say so
in `plan.md`.

### 5. Write for a literal reader

- Exact file paths. Exact symbol names. Exact env var names. Exact commands.
- No open decisions. If you write "decide whether to…", you have not finished
  planning. Pick the format, the signature, the error behaviour, the name.
- Describe the shape of the code, not its characters. Give the signature and the
  failure mode; do not paste an implementation, or you have written the code and
  skipped the tests.
- `## Out of scope` is load-bearing. It is where you pre-empt the "helpful" extras:
  no retry wrapper, no metrics, no rename of the surrounding module, no new
  dependency, no reformat of the file.

## Sizing

Size is about *risk and blast radius*, not keystrokes.

| Size | Shape | Files | Verification | Example |
|---|---|---|---|---|
| **S** | One clear change in an existing pattern; no new interface | 1–2 | One command | Add a cached-token branch to an existing function |
| **M** | New function or file inside an established pattern; one interface others consume | 2–4 | A test file plus a lint pass | New `ob-idle-stop` script with an IMDSv2 self-id lookup |
| **L** | New subsystem, or a change with cross-cutting consequences | 5+ | Multiple suites, plus a manual smoke check | The whole poll-loop state machine |

Rules of thumb:

- Anything you would size **XL** is not a story. Split it.
- If a story's `files` list has more than about six entries, it is an L that wants to
  be two Ms.
- An L is acceptable when the thing genuinely is one atomic capability (a state
  machine cannot be half-implemented). It is not acceptable as a place to put
  everything you did not want to slice.
- Prefer S and M. A weak model's success rate falls off a cliff with story size, and
  a failed L costs a full round; a failed S costs a comment.

## Acceptance items

Each item must be checkable by running something or reading something specific.

| ✗ Unverifiable | ✓ Verifiable |
|---|---|
| handles errors gracefully | on HTTP 401 it exits 1 and logs `token mint failed` to stderr |
| is well tested | `npm test -- src/token.test.ts` passes with ≥ 3 cases including expiry |
| performant | a cache hit makes zero HTTP requests (assert with a stubbed `curl`) |
| follows repo conventions | `shellcheck -x -S warning runner/bin/ob-token` is clean |
| secure | the cache file is created with mode `0600`; `stat -c %a` prints `600` |

## Worked example

Slug: `token-cache`. Two stories.

### `plan.md`

```markdown
# feat(runner): mint and cache GitHub App installation tokens

## Goal
Every `gh` call from the instance authenticates with a short-lived GitHub App
installation token. Minting happens at most once per validity window instead of
once per invocation, so a 60-second poll loop does not make 1440 token calls a day.

## Why now
`ob-poll` runs every 60s and each pass shells out to `gh` several times. Without a
cache we mint a token per call, which is slow, rate-limited, and noisy in the App's
audit log.

## Approach
`ob-token` is the single source of a token. It builds an RS256 JWT with `openssl`,
exchanges it for an installation token, and writes the raw GitHub response JSON to
`$OPENBUILDER_HOME/cache/gh-token.json` at mode 0600. Callers never parse the
response themselves; they call `ob-token` and read stdout.

Decision made on the implementer's behalf: the cache stores GitHub's response
verbatim (including `expires_at`) rather than a derived struct, so freshness logic
has exactly one input and no clock arithmetic is duplicated. Freshness threshold is
5 minutes, hardcoded — not configurable, because a wrong value here fails silently.

## Stories
| id | title | size | depends_on |
|---|---|---|---|
| story-01-token-mint | Mint an installation token from the App private key | M | [] |
| story-02-token-cache | Cache the token on disk and reuse it while valid | S | [story-01-token-mint] |

## Out of scope
- Token revocation.
- Any credential source other than the GitHub App (no PATs, no OAuth).
- Multi-installation support: exactly one installation id, from SSM.

## Risks
- The PEM contains newlines; naive shell handling will corrupt it. Reviewer should
  check the private key is fed to `openssl` via a file or process substitution and
  never through an interpolated string.
- A token in a log line is a credential leak. Reviewer should grep the diff for any
  path where `$token` reaches `ob_log`.
```

### `story-02-token-cache.md`

```markdown
---
id: story-02-token-cache
title: Cache the installation token on disk and reuse it while valid
size: S
depends_on: [story-01-token-mint]
files:
  - runner/bin/ob-token
acceptance:
  - "a fresh cache file causes zero calls to api.github.com"
  - "a cache file whose expires_at is under 5 minutes away triggers a re-mint"
  - "the cache file is created with mode 0600"
  - "`shellcheck -x -S warning runner/bin/ob-token` is clean"
---

## Context
`story-01-token-mint` left `ob-token` minting a token on every invocation. The mint
path is the function `ob_token_mint` in `runner/bin/ob-token`, which echoes the raw
JSON response from `POST /app/installations/<id>/access_tokens` to stdout.

`$OPENBUILDER_HOME` is `/opt/openbuilder` and `cache/` already exists (created by
cloud-init, owned by the `openbuilder` user). `jq` is installed. `ob-common.sh`
provides `ob_log` and `ob_die`.

Trap: GitHub returns `expires_at` as an ISO-8601 UTC string like
`2026-08-08T19:44:12Z`. GNU `date -d` parses it; BSD `date` does not. The instance is
Ubuntu 24.04, so GNU `date` is correct here — but do not reach for `date -j`.

Trap: the token must never be logged. `ob_log` output goes to a file that a human
tails.

## Change
In `runner/bin/ob-token`:

1. Add `ob_token_cache_path` echoing `"$OPENBUILDER_HOME/cache/gh-token.json"`.
2. Add `ob_token_cache_valid`: returns 0 when the cache file exists, parses as JSON,
   has a non-empty `.token`, and `.expires_at` is more than 300 seconds in the
   future; returns 1 otherwise. Compute with
   `$(date -u -d "$expires_at" +%s)` minus `$(date -u +%s)`. Any parse failure
   returns 1 — never propagate a malformed cache.
3. In `main`: if `ob_token_cache_valid`, print `.token` from the cache and exit 0.
   Otherwise mint, write the response with `umask 077` before the redirect so the
   file is 0600 at creation (do not create-then-chmod), then print `.token`.
4. Log cache hits and misses at debug level with the word `cache` and the remaining
   validity in seconds. Never log the token or any part of it.

## Acceptance
- `ob-token >/dev/null && ob-token >/dev/null` mints once; verify by asserting the
  cache file's mtime is unchanged by the second call.
- `jq '.expires_at = "1970-01-01T00:00:00Z"' cache/gh-token.json` written back in
  place causes the next call to re-mint.
- `stat -c %a "$OPENBUILDER_HOME/cache/gh-token.json"` prints `600`.
- `shellcheck -x -S warning runner/bin/ob-token` exits 0.

## Out of scope
- Locking around concurrent `ob-token` invocations. The poll loop already holds a
  global lock; do not add flock here.
- Caching anything other than the installation token.
- Making the 300-second threshold configurable.
- Reformatting or restructuring the rest of `ob-token`.
```

Note what the example does: it names the function to add, the exact `date`
invocation, the `umask` ordering, the log wording, and four things not to do. There
is nothing left for the implementer to decide — only work to do and tests to run.

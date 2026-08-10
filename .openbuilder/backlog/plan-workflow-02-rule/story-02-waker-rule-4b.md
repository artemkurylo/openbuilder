---
id: story-02-waker-rule-4b
title: Add rule 4b to the waker and diff its decisions against ob-poll
size: M
depends_on:
  - story-01-ob-poll-rule-4b
files:
  - waker/github.py
  - waker/handler.py
acceptance:
  - "python3 -m py_compile waker/github.py waker/handler.py exits 0, and waker/__pycache__ is deleted afterwards"
  - "github.decide against the seven fixture branches returns rule 4b and actionable False for the six unapproved slugs and rule 5 actionable True for fx-approved only"
  - "the six slug-and-reason pairs extracted from the waker output and from ob-poll --dry-run diff empty"
  - "the verification imports waker/github.py only, never waker/handler.py and never lambda_handler, so no instance can be started"
  - "after the run the fixture repo still has zero labels, zero issues and zero pull requests"
  - "the seven fixture branches are deleted and gh api repos/artemkurylo/openbuilder-fixture/git/matching-refs/heads/openbuilder/plan/ returns length 0"
---

## Context

`waker/github.py` is the waker's half of the rule table and the reason the parity contract exists:
the instance is off most of the time, so something outside it must decide whether powering it on is
worth $0.0384/h (`docs/architecture.md:155-189`). The contract is explicit — *"Add, reorder or retire
a rule in `ob-poll` and you must make the matching change in `waker/github.py:decide` in the same
commit. Forgetting produces no error"* (`docs/architecture.md:184-186`). `story-01-ob-poll-rule-4b`
just added rule 4b to `ob-poll`; this story is the other half, and the two must be provably in
agreement rather than merely both edited.

What the file already gives you:

- `_request(path, token=…, jwt=…, method=…)` at line 36 — builds the URL against `API`
  (`https://api.github.com`, hard-pinned at line 27), sets the three headers, and either returns
  parsed JSON or raises `GitHubError` (line 32) on any HTTP or URL error.
- `plan_slugs` (85), `work_pr` (101), `blocked_slugs` (119), and `decide` (134) — which builds one
  verdict dict per plan branch via the inner `verdict(slug, actionable, rule, reason)` helper (142)
  and returns them in GitHub's ref order.
- The rule-5 candidate path is `if found is None:` at line 155: rule 4 (`blocked-issue`, line 157)
  then rule 5 (`no-pr`, line 159).

`waker/handler.py` prints each verdict as
`DECISION repo={repo} slug={slug} rule={rule} actionable={actionable} reason={reason}` (lines
110-114) — deliberately the same shape as `ob-poll`'s lines, so the two logs read alike. It is also
the only module allowed to import boto3: `github.py` imports no AWS SDK precisely so the whole
decision path runs on a laptop or on the instance against live GitHub with a local PEM
(`docs/architecture.md:542-547`). Keep that split intact — the verification below depends on it.

The Lambda runtime is python3.13 with boto3 and nothing else, so `github.py` may import from the
standard library only.

The semantics, the five reason strings, the read order, the name-set union rule, the byte-order
tie-break and the scrubbing rule are fixed in `plan.md` under "Approach" and are already implemented
in `runner/bin/ob-poll` by story 01. Read that implementation before you write this one: every reason
string here must be byte-identical to the one `ob-poll` prints for the same fixture branch.

## Change

### `waker/github.py`

1. Add `import base64` and `import re` to the stdlib import block at lines 19-23, in alphabetical
   order. Add no third-party import and no `boto3`.

2. Add a module-level constant `_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,48}$")` next to `_UA`,
   and `_STORY_RE = re.compile(r"^story-.*\.md$")`. The epic name read out of `plan.md` is
   interpolated into an API path, so it is validated before use.

3. Add `_safe_field(value: str, limit: int) -> str` — deletes every character outside
   `[A-Za-z0-9._-]`, truncates to `limit`, and returns `-` when the result is empty. This is the
   Python twin of `ob-poll`'s `safe_field`; the limits are 32 for a stage and 48 for a file name.

4. Add `_contents(token, repo, ref, path) -> str | None` — `GET
   repos/{repo}/contents/{path}?ref={quote(ref, safe="/")}`, then `base64.b64decode` of the
   response's `content` field decoded as UTF-8 with `errors="replace"`. Returns `None` when the
   request raises `GitHubError`, when the body is not a dict, or when `content` is missing or empty.
   Use `urllib.parse.quote` as `work_pr` already does at line 110.

5. Add `_backlog_files(token, repo, ref, path) -> dict[str, str] | None` — the directory listing:
   `GET repos/{repo}/contents/{path}?ref=…`, returning `{entry["name"]: entry["sha"]}` for entries
   whose `type` is `"file"`. Returns `None` on `GitHubError` or when the body is not a list. The
   `sha` of a listing entry is the git blob sha, so nothing else needs downloading.

6. Add `backlog_decline_reason(token, repo, branch_prefix, slug) -> str | None` — public, because the
   verification below calls it directly. Returns `None` when the backlog is approved, otherwise the
   reason string. `ref = f"{branch_prefix}/plan/{slug}"`,
   `backlog = f".openbuilder/backlog/{slug}"`. In order:

   1. `_contents` of `{backlog}/plan.md`. Take the first line that `startswith("- epic:")`, split it
      on whitespace and take field index 2. If the body is `None`, no such line exists, the line has
      fewer than three fields, or `_SLUG_RE.fullmatch` fails on the value → return
      `"backlog-unapproved:no-epic-line"`.
   2. `_contents` of `.openbuilder/epics/{epic}/state.json`, then `json.loads`. If the body is
      `None`, `json.loads` raises `ValueError`, or the result is not a dict → return
      `"backlog-unapproved:no-state"`.
   3. `state.get("stage")`. If it is not exactly the string `"dispatched"` → return
      `f"backlog-unapproved:stage={_safe_field(str(stage or ''), 32)}"`.
   4. `recorded = state["approvals"]["backlog"][slug]["files"]`, defensively via `.get` chains so a
      missing key or a non-dict at any level is not an exception. If it is missing, not a dict, or
      empty → return `"backlog-unapproved:no-approval"`.
   5. `listed = _backlog_files(token, repo, ref, backlog) or {}` — a `None` listing becomes an empty
      dict and falls through to step 6, which then reports the first recorded name. That matches
      `ob-poll`, where a failed listing leaves every recorded name unmatched. Do not return
      `no-approval` here: the approval record exists, the files could not be confirmed.
   6. `names = sorted(set(recorded) | {n for n in listed if n == "plan.md" or _STORY_RE.match(n)})`.
      `sorted` is byte order, matching `LC_ALL=C sort`. Walk `names` in order and return
      `f"backlog-unapproved:files-differ({_safe_field(name, 48)})"` for the **first** name whose
      `recorded.get(name)` is falsy, whose `listed.get(name)` is falsy, or where the two differ. Look
      names up in the full `listed` dict, not in the filtered set.
   7. Return `None`.

7. In `decide`, inside `if found is None:` (line 155), keep rule 4 first and insert rule 4b between
   it and rule 5:

   - `slug in blocked` → `verdict(slug, False, 4, "blocked-issue")`, unchanged;
   - otherwise call `backlog_decline_reason`; a truthy reason →
     `verdict(slug, False, "4b", reason)`;
   - otherwise → `verdict(slug, True, 5, "no-pr")`, unchanged.

   The `rule` value is the **string** `"4b"`, so `handler.py`'s format string prints `rule=4b`.
   `decide`'s signature, its return type, and rules 2, 3, 6 and 7 are unchanged.

### `waker/handler.py`

8. One sentence added to the module docstring (lines 1-18), and no code change at all: state that the
   rule table now includes rule 4b, that it is fully visible from GitHub — unlike rules 1 and 4,
   which the docstring already explains are instance-local — and that it costs three extra contents
   reads per plan branch that has no pull request. `lambda_handler`, `_config`, `_repos`,
   `_instance`, `_last_stop_verdict`, the flap guard and the `start_instances` path stay byte-for-byte
   as they are.

## Acceptance

**Step 0.** The seven fixture branches from `story-01-ob-poll-rule-4b` Step 2 are still on
`artemkurylo/openbuilder-fixture`. Confirm, and re-run `/tmp/ob4b/seed.sh` if not:

```sh
source /opt/openbuilder/bin/ob-common.sh; ob_load_env
ob_gh api 'repos/artemkurylo/openbuilder-fixture/git/matching-refs/heads/openbuilder/plan/' \
  --jq 'length'    # prints 7
```

**Step 1.** `python3 -m py_compile waker/github.py waker/handler.py` exits 0 and prints nothing, then
`rm -rf waker/__pycache__`. `__pycache__` is not in `.gitignore`, so a stray `.pyc` would land in the
diff; `git status --porcelain waker` must list exactly the two modified `.py` files and nothing
untracked. There is no Python lint target in this repository; do not add one and do not run
`make lint`.

**Step 2 — run the waker's predicate directly against the same fixture branches.** `github.py`
imports no AWS SDK, which is what makes this possible; `handler.py` is never imported and
`lambda_handler` is never called, so nothing can start an instance. The App credentials come from
SSM, the same three parameters `ob-token` reads (`runner/bin/ob-token:95-102`):

```sh
umask 077
mkdir -p /tmp/ob4b
source /opt/openbuilder/bin/ob-common.sh; ob_load_env
ob_ssm github_app_private_key >/tmp/ob4b/app.pem
APP_ID="$(ob_ssm github_app_id)"
INST_ID="$(ob_ssm github_app_installation_id)"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=waker python3 - "$APP_ID" "$INST_ID" <<'PY' | tee /tmp/ob4b/waker.out
import sys
import github

pem = open("/tmp/ob4b/app.pem").read()
token = github.installation_token(sys.argv[1], sys.argv[2], pem)
for v in github.decide(token, "artemkurylo/openbuilder-fixture", "openbuilder", "openbuilder"):
    print(
        "DECISION repo={repo} slug={slug} rule={rule} actionable={actionable} "
        "reason={reason}".format(**v)
    )
PY
```

The `print` format string is copied verbatim from `waker/handler.py:112-113`, so this prints exactly
what the Lambda would log. Expected, one line per branch:

| slug | expected fields |
|---|---|
| fx-no-epic | `rule=4b actionable=False reason=backlog-unapproved:no-epic-line` |
| fx-no-state | `rule=4b actionable=False reason=backlog-unapproved:no-state` |
| fx-bad-stage | `rule=4b actionable=False reason=backlog-unapproved:stage=backlog` |
| fx-no-approval | `rule=4b actionable=False reason=backlog-unapproved:no-approval` |
| fx-file-edited | `rule=4b actionable=False reason=backlog-unapproved:files-differ(plan.md)` |
| fx-extra-story | `rule=4b actionable=False reason=backlog-unapproved:files-differ(story-02-extra.md)` |
| fx-approved | `rule=5 actionable=True reason=no-pr` |

```sh
grep -c 'rule=4b actionable=False' /tmp/ob4b/waker.out            # 6
grep -cF 'slug=fx-approved rule=5 actionable=True' /tmp/ob4b/waker.out  # 1
grep -c 'actionable=True' /tmp/ob4b/waker.out                     # 1
```

**Step 3 — the parity diff. This is the point of the slug.** Re-run the poller side from Step 3 of
`story-01-ob-poll-rule-4b` against the same branches, then compare the two outputs field by field. A
side-by-side read of the two source files does **not** satisfy this (RFC §4.4):

```sh
OPENBUILDER_ENV_FILE=/tmp/ob4b/openbuilder.env \
  bash "$PWD/runner/bin/ob-poll" --dry-run >/tmp/ob4b/poll.out

grep -oE 'slug=[^ ]+ rule=4b action=skip reason=[^ ]+' /tmp/ob4b/poll.out |
  sed -E 's/ rule=4b action=skip reason=/ /' | LC_ALL=C sort >/tmp/ob4b/poll.fields
grep -oE 'slug=[^ ]+ rule=4b actionable=False reason=[^ ]+' /tmp/ob4b/waker.out |
  sed -E 's/ rule=4b actionable=False reason=/ /' | LC_ALL=C sort >/tmp/ob4b/waker.fields

wc -l </tmp/ob4b/poll.fields            # 6
wc -l </tmp/ob4b/waker.fields           # 6
diff /tmp/ob4b/poll.fields /tmp/ob4b/waker.fields   # prints nothing, exits 0
tail -1 /tmp/ob4b/poll.out              # ACTIONABLE=1
```

`diff` printing nothing is the parity evidence: the same seven live branches, six identical
`slug reason` pairs, and one actionable slug on each side. `ACTIONABLE=1` beside
`grep -c 'actionable=True' … # 1` is what rules out the billing failure named in `plan.md` — the
waker waking the box for work the poller declines.

**Step 4 — still no side effects, from either side.**

```sh
ob_gh label list --repo artemkurylo/openbuilder-fixture 2>&1 | grep -c openbuilder  # 0
ob_gh issue list --repo artemkurylo/openbuilder-fixture --state all | wc -l         # 0
ob_gh pr list --repo artemkurylo/openbuilder-fixture --state all | wc -l            # 0
```

**Step 5 — tear the fixture down.** Delete the fixture branches and the scratch directory, including
the PEM:

```sh
cd /tmp/ob4b/repo
for s in fx-no-epic fx-no-state fx-bad-stage fx-no-approval fx-file-edited \
         fx-extra-story fx-approved; do
  git push --quiet origin --delete "openbuilder/plan/${s}"
done
cd /
rm -f /tmp/ob4b/app.pem
rm -rf /tmp/ob4b
source /opt/openbuilder/bin/ob-common.sh; ob_load_env
ob_gh api 'repos/artemkurylo/openbuilder-fixture/git/matching-refs/heads/openbuilder/plan/' \
  --jq 'length'    # prints 0
rmdir /opt/openbuilder/state/artemkurylo__openbuilder-fixture__fx-* 2>/dev/null || true
```

The sandbox repository itself is left in place for the next slug; the human deletes it when the epic
lands. Record in `worklog.md` that the PEM was written under `umask 077` to `/tmp/ob4b/app.pem` and
removed, and never appeared in any command argument.

## Out of scope

- `runner/`, `docs/`, `local/bin/`, `infra/`. This story touches two files under `waker/`.
- No new dependency and no import outside the standard library. `base64` and `re` are the only two
  imports added.
- No `boto3` or AWS call in `github.py`, and no code change in `handler.py` — its edit is one
  docstring sentence.
- No change to the flap guard, `_last_stop_verdict`, `_TRANSIENT_START_ERRORS`, the
  `start_instances` path, or any Lambda environment variable.
- No change to `infra/waker.tf`, the EventBridge schedule, the IAM policy, or the log retention.
- No `aws lambda invoke`, and never call `lambda_handler` in the verification: it would start the
  instance.
- No unit-test file, no `tests/` directory, no test framework. The repository has none and the
  verification here is a live exercise against GitHub.
- No caching of the contents reads, no retry loop, no `_TIMEOUT` change, and no pagination handling
  for the backlog listing.
- No new reason strings and no reason string that differs by a single byte from `ob-poll`'s.
- No renaming of `decide`, `plan_slugs`, `work_pr` or `blocked_slugs`, and no change to their
  signatures.
- Do not run `make lint`, `make scrub`, `terraform` or any project-wide suite.

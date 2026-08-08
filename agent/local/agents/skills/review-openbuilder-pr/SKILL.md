---
name: review-openbuilder-pr
description: Review rubric and the exact gh commands for openbuilder pull requests - fetch the diff and review threads, post line comments, post the summary review, and set the openbuilder:approved / openbuilder:changes-requested label that drives the poll loop. Use when reviewing a PR on an openbuilder/work/<slug> branch.
---

# Reviewing an openbuilder PR

The PR was written by a cheap model with no supervision. You are the gate. Your
review is also the *only* instruction the next round receives — the remote agent
reads exactly your line comments and your review body, and nothing else. Vagueness
here costs a whole round.

Two outcomes only:

- `openbuilder:approved` → the box stops touching the PR forever. A human merges.
- `openbuilder:changes-requested` → the next poll pass runs `ob-respond` and the
  agent does another round.

Setting neither leaves the PR parked on `openbuilder:awaiting-review` and the loop
stalls silently. Always set exactly one.

---

## 0. Set up the shell variables

Everything below uses these. Set them once.

```sh
REPO=owner/repo        # e.g. artemkurylo/some-project
PR=123                 # the pull request number
```

---

## 1. Gather the material

Metadata, labels, branch, and the head commit SHA (needed to anchor line comments):

```sh
gh pr view "$PR" --repo "$REPO" \
  --json number,title,state,headRefName,headRefOid,baseRefName,labels,body,files,url
```

```sh
HEAD_SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
HEAD_REF=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
```

The full diff:

```sh
gh pr diff "$PR" --repo "$REPO"
```

Just the touched paths, to orient yourself before reading:

```sh
gh pr diff "$PR" --repo "$REPO" --name-only
```

The backlog and the worklog, read from the PR's head branch (do not trust a local
checkout to be current):

```sh
SLUG=${HEAD_REF#openbuilder/work/}   # HEAD_REF was captured in the block above

gh api --paginate \
  "repos/$REPO/contents/.openbuilder/backlog/$SLUG?ref=$HEAD_SHA" \
  --jq '.[].name'

gh api "repos/$REPO/contents/.openbuilder/backlog/$SLUG/worklog.md?ref=$HEAD_SHA" \
  --jq '.content' | base64 -d
```

Prior review rounds — existing review comments and their resolution state. Always
`--paginate`; a PR on its fourth round easily exceeds one page:

```sh
# inline review comments (flat)
gh api --paginate "repos/$REPO/pulls/$PR/comments" \
  --jq '.[] | {id, path, line, user: .user.login, body}'

# submitted reviews (verdicts + bodies)
gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq '.[] | {id, state, user: .user.login, body}'

# issue-level comments (ob-implement / ob-respond post their round summaries here)
gh api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq '.[] | {user: .user.login, body}'

# review threads with resolution state (GraphQL; REST does not expose isResolved)
gh api graphql -f query='
  query($owner:String!, $name:String!, $pr:Int!) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes {
            isResolved
            isOutdated
            path
            line
            comments(first:20) { nodes { author { login } body } }
          }
        }
      }
    }
  }' -f owner="${REPO%/*}" -f name="${REPO#*/}" -F pr="$PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | {isResolved, isOutdated, path, line}'
```

Do not repeat a finding that is already an unresolved thread. Do check whether a
previously-raised finding was actually fixed or merely marked resolved.

---

## 2. The rubric

Apply in this order. Order matters: an incorrect change that conforms beautifully to
the story is still a reject.

### Correctness — blocking

- Does the code do what the story says? Read the surrounding function, not just the
  hunk.
- Inverted conditions, off-by-one, wrong default, wrong operator.
- Error paths: swallowed exceptions, ignored non-zero exit, `|| true` hiding a real
  failure, a lock not released on the failure branch.
- Boundaries: empty collection, single element, missing key, zero, negative,
  expired, absent file.
- Bash specifics — most of this repo is bash:
  - unquoted `$var` where a path or user input can contain whitespace;
  - missing `set -euo pipefail` / `IFS=$'\n\t'`;
  - `eval` on any interpolated value (never acceptable);
  - a failing command inside a pipeline whose status is masked;
  - `$(...)` inside a string where the exit status is dropped.
- Secrets: any path by which `sk-or-*`, `ghs_*`, `github_pat_*`, or a PEM body can
  reach a log, a commit, a PR comment, or process arguments. A token in `ps` output
  is a leak.
- File modes on anything holding a credential (`0600`), and created *with* that mode
  rather than chmod'd afterwards.
- Concurrency: the flock, the poll pass overlapping a running job, read-modify-write
  on `state/`.
- **Automatic blocking findings**, no discussion:
  - a `git merge`, `gh pr merge`, or merge-queue call;
  - a force-push in any spelling (`--force`, `-f`, `--force-with-lease`);
  - a push to `main`/`master`/any default branch;
  - a write to `/opt/openbuilder/etc`;
  - an `aws ec2 terminate-instances`;
  - a widened IAM statement or GitHub App permission.

### Contract and acceptance conformance — blocking

Enumerate. For **every** story card, for **every** item in its `acceptance` list,
write down the hunk that satisfies it — or that nothing does.

- Every story in `plan.md` is implemented, or explicitly listed as blocked in the
  worklog's open questions.
- Nothing from any `## Out of scope` section was implemented anyway. Unrequested
  scope is a finding: it is unreviewed code riding along with reviewed code.
- Frozen names are exact — branches `openbuilder/plan|work/<slug>`, the six
  `openbuilder:*` labels, `OPENBUILDER_*` env vars, the four SSM parameter names,
  the model selector `openrouter/deepseek/deepseek-v4-flash-0731`. A near-miss
  rename breaks the loop with no error message.
- The worklog's **Verified** section contains real commands with real output. An
  empty or hand-waving Verified section on a behaviour change is changes-requested
  on its own.

### Maintainability — usually `important` or `nit`

- A second convention beside an existing one → `important`.
- Dead code, unreachable branch, leftover debug output, commented-out block.
- A name or comment that contradicts the code.
- Duplication that will drift.
- A newly introduced observable contract with no test.

### What NOT to comment on

Never spend a review round on something the repo's own tooling handles: formatting,
indentation, quote style, import order, line length, trailing commas, anything
`terraform fmt` or `shellcheck -S warning` or the project formatter would fix for
free. If a needed tool is missing from the repo, say it once in the review body and
move on.

Also never comment on a line the PR did not touch. If untouched code worries you,
put it in the review body as an observation.

---

## 3. Post a single line comment

Anchor to `path` + `line` in the post-change file, with `side=RIGHT`. The line must
appear in the diff.

```sh
gh api --method POST "repos/$REPO/pulls/$PR/comments" \
  -f commit_id="$HEAD_SHA" \
  -f path="runner/bin/ob-token" \
  -F line=42 \
  -f side="RIGHT" \
  -f body='`$slug` is unquoted here, so a slug containing whitespace expands to two
arguments and `flock` takes the wrong path. Quote it: `ob_lock "$slug"`.'
```

Multi-line range (comment spans lines 40–42):

```sh
gh api --method POST "repos/$REPO/pulls/$PR/comments" \
  -f commit_id="$HEAD_SHA" \
  -f path="runner/bin/ob-token" \
  -F start_line=40 -f start_side="RIGHT" \
  -F line=42 -f side="RIGHT" \
  -f body='This whole block re-mints on every call; see the caching story acceptance.'
```

Reply inside an existing thread (use the comment id from step 1):

```sh
gh api --method POST "repos/$REPO/pulls/$PR/comments/<comment_id>/replies" \
  -f body='Still unquoted after round 3 — see the original comment.'
```

---

## 4. Post the summary review

**Preferred: one review carrying the body and every line comment atomically.** This
posts as a single review event instead of N notifications, and the remote agent sees
one coherent instruction set. Build the payload as JSON and pipe it in.

`event` is `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`.

```sh
cat >/tmp/ob-review.json <<'JSON'
{
  "commit_id": "HEAD_SHA_PLACEHOLDER",
  "event": "REQUEST_CHANGES",
  "body": "## openbuilder review — round 2\n\n**Verdict: changes-requested**\n\nAcceptance checked story by story:\n- story-01 (3/3) satisfied — `shellcheck` clean, mode 0600 verified in worklog.\n- story-02 (2/4) — items 3 and 4 are not implemented; see line comments.\n\nBlocking: the cache file is created then chmod'd, leaving a window at 0644.\n",
  "comments": [
    {
      "path": "runner/bin/ob-token",
      "line": 42,
      "side": "RIGHT",
      "body": "Created at the default umask then chmod'd — a reader can open it in the window between. Set `umask 077` before the redirect instead."
    },
    {
      "path": "runner/bin/ob-token",
      "line": 58,
      "side": "RIGHT",
      "body": "`ob_log` receives the raw token here. Log the remaining validity in seconds, never the token."
    }
  ]
}
JSON

sed -i.bak "s/HEAD_SHA_PLACEHOLDER/$HEAD_SHA/" /tmp/ob-review.json

gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input /tmp/ob-review.json
```

**Simpler alternative** when you have no line comments (or already posted them
individually):

```sh
# request changes
gh pr review "$PR" --repo "$REPO" --request-changes --body-file /tmp/ob-review-body.md

# approve
gh pr review "$PR" --repo "$REPO" --approve --body-file /tmp/ob-review-body.md

# comment only (use this if `gh` refuses the above because you authored the PR)
gh pr review "$PR" --repo "$REPO" --comment --body-file /tmp/ob-review-body.md
```

GitHub rejects `--approve` and `--request-changes` on a PR you authored yourself. The
openbuilder PR is authored by `openbuilder-bot`, and you review as your own account,
so this normally works — but if it 422s, fall back to `--comment`. **The label, not
the review event, is what drives the loop**, so a `COMMENT` review plus the right
label is fully functional.

---

## 5. Set the label — this is the actual message bus

Make sure both terminal labels exist (idempotent; the `|| true` swallows the
"already exists" error):

```sh
gh label create "openbuilder:approved" --repo "$REPO" \
  --color 0E8A16 --description "openbuilder: human may merge; the box stops here" || true

gh label create "openbuilder:changes-requested" --repo "$REPO" \
  --color D93F0B --description "openbuilder: reviewer wants another round" || true
```

### Approve

```sh
gh pr edit "$PR" --repo "$REPO" \
  --add-label "openbuilder:approved" \
  --remove-label "openbuilder:awaiting-review" \
  --remove-label "openbuilder:changes-requested" \
  --remove-label "openbuilder:in-progress"
```

### Request changes

```sh
gh pr edit "$PR" --repo "$REPO" \
  --add-label "openbuilder:changes-requested" \
  --remove-label "openbuilder:awaiting-review"
```

Confirm it took — a silently-missing label is the most common way this loop stalls:

```sh
gh pr view "$PR" --repo "$REPO" --json labels --jq '.labels[].name'
```

### The full label set, and who owns each

| Label | Meaning | Set by |
|---|---|---|
| `openbuilder:queued` | plan pushed, not yet picked up | laptop |
| `openbuilder:in-progress` | remote agent working | box |
| `openbuilder:awaiting-review` | PR ready for Opus 5 | box |
| `openbuilder:changes-requested` | reviewer wants another round | laptop |
| `openbuilder:approved` | human may merge; box stops touching it | laptop |
| `openbuilder:blocked` | agent gave up, needs a human | box |

Never set `openbuilder:in-progress`, `openbuilder:awaiting-review`, or
`openbuilder:blocked` from a review — those belong to the box, and writing them from
the laptop confuses the state machine.

---

## 6. What you must never do

- **Never merge.** No `gh pr merge`, no `--auto`, no merge queue. A human merges,
  after `openbuilder:approved`.
- Never push, commit, force-push, or edit files on the work branch. You are
  read-only on code; you describe, the implementer fixes.
- Never approve to be agreeable, and never request changes to look thorough.
- Never close the PR. If the work is unsalvageable, request changes with a precise
  explanation and let the human decide.

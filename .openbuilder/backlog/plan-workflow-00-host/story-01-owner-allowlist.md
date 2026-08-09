---
id: story-01-owner-allowlist
title: Refuse non-personal owners and non-github.com clone origins
size: S
depends_on: []
files:
  - local/bin/openbuilder
acceptance:
  - "`openbuilder status someorg/somerepo` exits 1, prints exactly `openbuilder: refusing someorg/somerepo: owner 'someorg' is not in OPENBUILDER_OWNER (artemkurylo)` to stderr, and invokes no `gh` subprocess at all (proven with a stub `gh` on PATH that logs every invocation: the log stays empty)"
  - "`OPENBUILDER_OWNER=someorg openbuilder status someorg/somerepo` exits 0 and the same stub `gh` is invoked 3 times"
  - "`OPENBUILDER_OWNER= openbuilder status someorg/somerepo` exits 1 with the allowlist shown as `(artemkurylo)` — an empty value falls back to the default and never allows everything"
  - "`openbuilder plan artemkurylo/fake probe-slug` against a workspace clone whose `origin` is `git@ghe.example.com:artemkurylo/fake.git` exits 1, prints `refusing clone <dir>: origin is git@ghe.example.com:artemkurylo/fake.git, which is not on github.com`, and never prints `fetching artemkurylo/fake`"
  - "the same command with `origin` set to `https://github.com/artemkurylo/ob-probe-nonexistent.git`, and again with `git@github.com:artemkurylo/ob-probe-nonexistent.git`, prints `fetching artemkurylo/fake` and never prints `refusing clone`"
  - "`shellcheck -x -S warning local/bin/openbuilder` exits 0 with no output"
---

## Context

`local/bin/openbuilder` is the operator CLI. It runs on a laptop whose `gh` is authenticated to two
hosts, and it takes an `<owner>/<repo>` argument on six commands. Today `ob_validate_repo`
(`openbuilder:244-247`) validates only the *shape* of that argument:

```
[[ $1 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || ob_die "not a valid <owner>/<repo>: $1"
```

so `openbuilder status someorg/somerepo` makes three live API calls against a repository that has
nothing to do with this system. PRD R11 requires the owner to be refused *before* any network call,
naming the owner refused.

The second hole is the managed clone. `ob_clone_dir` (`openbuilder:479-481`) maps `owner/repo` to
`$OPENBUILDER_WORKSPACE/owner__repo`; `ob_ensure_clone` (`openbuilder:483-496`) runs
`git -C "$dir" fetch --prune --quiet origin` at line 489 when that directory already has a `.git`,
without ever checking where `origin` points. A workspace directory reused from another host therefore
sends a fetch to that host. `cmd_dispatch` has the same exposure through the
`git -C "$dir" push --quiet --set-upstream origin "$branch"` at `openbuilder:710`.

What to copy:

- `ob_die` (`openbuilder:80-83`) prints `"$OB_PROG: $*"` to stderr and exits 1. Message text below is
  the argument to `ob_die`; the `openbuilder: ` prefix comes for free.
- `ob_load_local_config` (`openbuilder:97-127`) is the one place defaults are set. It saves the five
  real environment variables into `local saved_*` at lines 98-102, sources `.openbuilder.local`,
  restores the saved values at lines 115-119 so a real environment variable outranks the file, then
  applies `${VAR:-default}` at lines 121-125. A sixth variable follows that exact three-step shape.
- `ob_pr_relabel` (`openbuilder:456`) is the file's existing pattern for splitting a comma-separated
  string under `IFS=$'\n\t'`: `IFS=',' read -r -a to_remove <<<"$remove_csv"`, then
  `[[ -n $label ]] || continue` inside the loop.

Traps:

- The file uses **four-space** indentation, unlike `runner/bin/ob-common.sh`. Match the file.
- `set -euo pipefail` is on. The restore lines at 115-119 are bare `[[ ... ]] && VAR=...`, which is
  only safe because the function ends with `return 0` at line 126. A new restore line must go *among*
  those lines, never after line 125.
- `ob_validate_repo` is reached from `ob_repo_arg` (`openbuilder:240`) and directly from
  `cmd_plan:568`, `cmd_dispatch:670`, `cmd_review:741`, `cmd_approve:800` and
  `cmd_request_changes:819`. All six inherit the allowlist with no call-site change.
- In `cmd_dispatch`, `ob_ensure_running` (line 675) deliberately runs before the local checks — its
  comment at lines 673-674 explains why. Do not reorder it. `ob_ensure_running` talks to AWS, not to
  a git remote, so the origin assertion belongs after the existing clone check at lines 679-681.

## Change

In `local/bin/openbuilder` only.

1. Add `OPENBUILDER_OWNER` to `ob_load_local_config` following the three-step shape above:
   `local saved_owner=${OPENBUILDER_OWNER:-}` beside the other `saved_*` declarations;
   `[[ -n $saved_owner ]] && OPENBUILDER_OWNER=$saved_owner` among the restore lines at 115-119;
   `OPENBUILDER_OWNER=${OPENBUILDER_OWNER:-artemkurylo}` among the defaults at 121-125.

2. Rewrite `ob_validate_repo` to keep the existing shape check and then check the owner. Signature is
   unchanged: one positional argument, no output on success, `ob_die` on failure. Order matters — the
   shape check stays first, so a malformed argument still reports the shape error.
   - Take the owner as everything before the first `/`.
   - Split `$OPENBUILDER_OWNER` on commas, skipping empty entries, and compare each entry to the
     owner with `==` inside `[[ ]]`. Exact, case-sensitive.
   - On no match, `ob_die` with exactly:
     `refusing $repo: owner '$owner' is not in OPENBUILDER_OWNER ($OPENBUILDER_OWNER)`
   - Declare every variable `local`.

3. Add a helper `ob_assert_origin_host <dir>` in the "Local clone / omp asset helpers" section
   (banner at `openbuilder:475-477`), above `ob_clone_dir`, with a header comment saying why it
   exists — a workspace directory reused from another host would otherwise receive a fetch or a push.
   - Read the URL with `git -C "$dir" remote get-url origin 2>/dev/null`. A non-zero exit is
     `ob_die "clone at $dir has no 'origin' remote"`.
   - Accept the URL only when it matches the bash regex
     `^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)`. All three forms are accepted;
     nothing else is.
   - Otherwise `ob_die` with exactly:
     `refusing clone $dir: origin is $url, which is not on github.com`
   - Declare every variable `local`.

4. Call `ob_assert_origin_host "$dir"` in exactly two places:
   - In `ob_ensure_clone`, as the **first** statement inside the `if [[ -d $dir/.git ]]` branch —
     before the `ob_info "fetching …"` line and before the `git fetch` at line 489. The `else`
     branch, which clones fresh through `gh`, gets no call: there is no `origin` yet.
   - In `cmd_dispatch`, immediately after the `ob_die "no local clone at $dir …"` check at
     lines 679-681.

5. Add one entry for `OPENBUILDER_OWNER` to the header comment's configuration list
   (`openbuilder:9-26`), in the same two-column shape as the entries already there, stating that it
   is comma-separated, defaults to `artemkurylo`, and that a non-matching owner is refused before any
   network call.

## Acceptance

Run from the repository root. Build the stub `gh` once — it records the invocation and returns a
valid empty JSON array so `jq` downstream is unaffected:

```
tmp=$(mktemp -d)
cat >"$tmp/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${GH_HOST:-unset}" >>"$OB_PROBE_LOG"
printf '[]\n'
exit 0
STUB
chmod +x "$tmp/gh"
export OB_PROBE_LOG=$tmp/seen
```

1. Refusal, and no subprocess:
   `: >"$OB_PROBE_LOG"; PATH="$tmp:$PATH" local/bin/openbuilder status someorg/somerepo` exits 1,
   stderr is exactly
   `openbuilder: refusing someorg/somerepo: owner 'someorg' is not in OPENBUILDER_OWNER (artemkurylo)`,
   and `wc -l <"$OB_PROBE_LOG"` prints `0`.
2. The allowlist is honoured, not hardcoded:
   `: >"$OB_PROBE_LOG"; OPENBUILDER_OWNER=someorg PATH="$tmp:$PATH" local/bin/openbuilder status someorg/somerepo`
   exits 0 and `wc -l <"$OB_PROBE_LOG"` prints `3`.
3. Empty means default, not "anything":
   `OPENBUILDER_OWNER= PATH="$tmp:$PATH" local/bin/openbuilder status someorg/somerepo` exits 1 and
   its message ends `(artemkurylo)`.
4. Wrong-host origin refused before the fetch:
   ```
   ws=$(mktemp -d); git init -q "$ws/artemkurylo__fake"
   git -C "$ws/artemkurylo__fake" remote add origin git@ghe.example.com:artemkurylo/fake.git
   out=$(GIT_TERMINAL_PROMPT=0 OPENBUILDER_WORKSPACE=$ws local/bin/openbuilder plan artemkurylo/fake probe-slug 2>&1); echo $?
   ```
   prints `1`; `$out` contains
   `refusing clone $ws/artemkurylo__fake: origin is git@ghe.example.com:artemkurylo/fake.git, which is not on github.com`
   and does **not** contain `fetching artemkurylo/fake`. Before this change the same command prints
   `fetching artemkurylo/fake` and then `ssh: Could not resolve hostname ghe.example.com`.
5. Both accepted URL forms pass through: repeat step 4 with `origin` set to
   `https://github.com/artemkurylo/ob-probe-nonexistent.git`, then to
   `git@github.com:artemkurylo/ob-probe-nonexistent.git`. Each run must print
   `fetching artemkurylo/fake` and must not contain `refusing clone`. Both then fail with GitHub's own
   `Repository not found`, which is expected and is not part of this assertion.
6. `shellcheck -x -S warning local/bin/openbuilder` exits 0 and prints nothing.

Remove the probe directories afterwards: `rm -rf "$tmp" "$ws"`.

## Out of scope

- No `ob_gh` wrapper and no `GH_HOST` anywhere in this story. That is `story-02-pin-gh-host`; do not
  start it here and do not touch any line that invokes `gh`.
- Do not touch `runner/bin/ob-common.sh`, `waker/`, `infra/`, `docs/` or `README.md`.
- Do not reorder `cmd_dispatch`: `ob_ensure_running` stays at line 675, ahead of the local checks.
- No `git` wrapper function, no change to `ob_clone_dir`, and no change to how `ob_ensure_clone`
  clones a fresh repository.
- No case-insensitive matching, no glob or regex entries in `OPENBUILDER_OWNER`, no wildcard, and no
  "allow any owner" escape hatch. Exact, comma-separated strings only.
- No new validator for `OPENBUILDER_WORKSPACE`, no `mkdir`, no permission check.
- Do not touch `ob_validate_slug` (`openbuilder:249-252`) or `ob_validate_pr`
  (`openbuilder:254-256`).
- No new dependency, no reformatting of the file, no rename of any existing function, and no
  reindentation.

---
id: story-02-pin-gh-host
title: Route every gh call through ob_gh and make OPENBUILDER_GH_HOST an assertion
size: S
depends_on: []
files:
  - local/bin/openbuilder
  - runner/bin/ob-common.sh
acceptance:
  - "with a stub `gh` on PATH, `GH_HOST=example.com openbuilder status artemkurylo/openbuilder` invokes the stub 3 times and the stub sees `GH_HOST=github.com` on all 3; with `GH_HOST` unset it also sees `github.com` on all 3, never `unset`"
  - "`grep -cE '^[[:space:]]*gh ' local/bin/openbuilder` prints 0 (was 7), `grep -cE '\\$\\(gh ' local/bin/openbuilder` prints 0 (was 4), `grep -cE '^[[:space:]]*if gh ' local/bin/openbuilder` prints 0 (was 1)"
  - "`grep -n '\\bgh\\b' local/bin/openbuilder` shows a `gh` token only on the 8 `ob_need` lines, the comment above `ob_pr_relabel`, the `merge it with: gh pr merge` printf, and the single `gh \"$@\"` inside `ob_gh`"
  - "`OPENBUILDER_ENV_FILE=/dev/null OPENBUILDER_HOME=$(mktemp -d) OPENBUILDER_GH_HOST=ghe.example.com bash -c 'source runner/bin/ob-common.sh; ob_load_env'` exits 1 and prints `OPENBUILDER_GH_HOST is 'ghe.example.com'; openbuilder supports github.com only`; the same command with `OPENBUILDER_GH_HOST=github.com` exits 0"
  - "`OPENBUILDER_GH_HOST=ghe.example.com openbuilder help` and `... openbuilder status artemkurylo/openbuilder` both exit 1 with the same message; `OPENBUILDER_GH_HOST=github.com openbuilder help` exits 0"
  - "`shellcheck -x -S warning local/bin/openbuilder runner/bin/ob-common.sh` exits 0 with no output"
---

## Context

Every `gh` invocation in `local/bin/openbuilder` inherits its host from the ambient `GH_HOST` or from
the current directory's git remote. This laptop's `gh` is authenticated to two hosts, so the CLI
reaching `github.com` today is a property of where it happens to be run. PRD R11 requires the host to
be pinned at the call, and RFC §4b.2 layer 2 specifies a single wrapper rather than N edits, "because
the property must hold for the *next* call site too".

The instance already does this. `ob_gh` at `runner/bin/ob-common.sh:261-270` mints an installation
token, sets `GH_TOKEN`/`GITHUB_TOKEN`/`GH_HOST` in the child environment only, and returns `gh`'s
status through a local `rc`. The laptop wrapper must **not** copy the token half: the operator's own
`gh` credentials are the right ones there, and the token dance exists only because the instance has
no interactive auth. What carries over is the name — one concept, one name on both sides.

Layer 3 is `runner/bin/ob-common.sh:91`:

```
: "${OPENBUILDER_GH_HOST:=github.com}"
```

This is a default, so `/opt/openbuilder/etc/openbuilder.env` can set any host and `ob_load_env` will
accept it and export it into `ob_gh`. Demonstrable today:

```
$ OPENBUILDER_ENV_FILE=/dev/null OPENBUILDER_HOME=$(mktemp -d) OPENBUILDER_GH_HOST=ghe.example.com \
    bash -c 'source runner/bin/ob-common.sh; ob_load_env; echo $OPENBUILDER_GH_HOST'
ghe.example.com          # exit 0
```

The variable keeps its name — `infra/templates/cloud-init.yaml.tftpl:50` renders
`OPENBUILDER_GH_HOST=github.com` and `docs/architecture.md:115-121` calls the name frozen — it just
stops being a setting.

The twelve call sites, as the file stands at the start of this round:

| line | call |
|---|---|
| 430 | `if gh label create …` in `ob_ensure_labels` |
| 435 | `gh label edit …` in `ob_ensure_labels` |
| 442 | `gh pr view …` in `ob_pr_labels` |
| 468 | `gh pr edit …` in `ob_pr_relabel` |
| 472 | `gh repo view …` in `ob_default_branch` |
| 493 | `gh repo clone …` in `ob_ensure_clone` |
| 750 | `head=$(gh pr view …)` in `cmd_review` |
| 808 | `gh pr comment …` in `cmd_approve` |
| 827 | `gh pr comment …` in `cmd_request_changes` |
| 847 | `plan_refs=$(gh api …)` in `cmd_status` |
| 848 | `work_refs=$(gh api …)` in `cmd_status` |
| 849 | `prs=$(gh pr list …)` in `cmd_status` |

Traps:

- **`story-01-owner-allowlist` inserts lines above some of these**, so the numbers above are an
  inventory, not addresses. Locate each site by its command text.
- `GH_HOST` and `OPENBUILDER_GH_HOST` are two different variables. `GH_HOST` is `gh`'s own and is what
  the wrapper sets. `OPENBUILDER_GH_HOST` is openbuilder's and is what the assertion refuses. Neither
  one is read where the other is written.
- Eight lines mention `gh` as an argument to `ob_need` (`openbuilder:427,486,570,672,743,802,821,844`).
  `ob_need` checks for the binary on `PATH`; those must keep the literal `gh`.
- `local/bin/openbuilder` uses four-space indentation; `runner/bin/ob-common.sh` uses two. Match each
  file.
- `ob_die` in `ob-common.sh:66-69` logs at ERROR through `ob_log`, which appends to
  `$OPENBUILDER_HOME/log/openbuilder.log` only when that directory exists. At line 91 the directory
  loop at lines 112-115 has not run yet, so a refusal reaches stderr and not the log file. That is
  fine; do not move the directory loop to "fix" it.
- `ob-common.sh` is sourced-only (`ob-common.sh:2-7`) and has a double-source guard at lines 12-15.
  Add nothing that executes at source time.

## Change

### `local/bin/openbuilder`

1. Add `ob_gh` at the top of the "GitHub helpers" section, immediately after the banner comment
   (`openbuilder:421-423`) and before `ob_ensure_labels`. It takes the `gh` argument list, runs `gh`
   with `GH_HOST=github.com` set in the child environment only, and returns `gh`'s exit status by
   being the function's last command. No `local`, no token handling, no `rc` variable, no logging, no
   retry — one command.
   Above it, a header comment saying why it exists: this laptop's `gh` is authenticated to more than
   one host, openbuilder is a personal-account tool, and the host must not come from the environment
   or the cwd (R11).

2. Replace `gh` with `ob_gh` at all twelve call sites listed in `## Context`. Nothing else on those
   lines changes: keep every argument, every `--flag`, every redirection, every `2>/dev/null`, every
   `|| true` and every `|| ob_die …` exactly as it is, and keep the `$( )` and `if` shapes.

3. Leave the literal `gh` in place on all eight `ob_need` lines, in the comment above `ob_pr_relabel`
   that mentions "a gh error", and in the `printf 'merge it with: gh pr merge %s --repo %s --squash\n'`
   in `cmd_approve`. That printf is advice for a human to type; `ob_gh` is not on their `PATH`.

4. In `ob_load_local_config`, after the defaults block (`openbuilder:121-125`) and before the
   `return 0`, refuse a non-`github.com` value of `OPENBUILDER_GH_HOST`. Treat unset as `github.com`
   so the common case is silent. `ob_die` with exactly:
   `OPENBUILDER_GH_HOST is '<value>'; openbuilder supports github.com only`
   `ob_load_local_config` is called first in `main` (`openbuilder:1162`), so this refuses every
   subcommand, `help` included. That is intended: R11 makes a wrong host a startup error.
   Add a header-comment entry for `OPENBUILDER_GH_HOST` to the configuration list at
   `openbuilder:9-26`, in the same two-column shape as the entries already there, stating it is
   asserted rather than configurable.

### `runner/bin/ob-common.sh`

5. In `ob_load_env`, immediately after `: "${OPENBUILDER_GH_HOST:=github.com}"` (line 91), refuse any
   other value with `ob_die` and the same message string as step 4, character for character — one
   string, two places. Above it, a two-line comment: this is not a setting; any other value is a
   misconfigured instance, not a supported deployment (R11).
   The variable stays in the `export` list at lines 104-109. Do not remove it and do not remove the
   default.

## Acceptance

Run from the repository root.

1. Host pinning, observed at the boundary. The stub records the `GH_HOST` its own process inherited
   and returns valid empty JSON so `jq` downstream is unaffected:
   ```
   tmp=$(mktemp -d)
   cat >"$tmp/gh" <<'STUB'
   #!/usr/bin/env bash
   printf '%s\n' "${GH_HOST:-unset}" >>"$OB_PROBE_LOG"
   printf '[]\n'
   exit 0
   STUB
   chmod +x "$tmp/gh"; export OB_PROBE_LOG=$tmp/seen
   : >"$OB_PROBE_LOG"
   GH_HOST=example.com PATH="$tmp:$PATH" local/bin/openbuilder status artemkurylo/openbuilder
   sort -u "$OB_PROBE_LOG"; wc -l <"$OB_PROBE_LOG"
   ```
   `sort -u` must print exactly one line, `github.com`, and `wc -l` must print `3`. Repeat with
   `GH_HOST` unset (`env -u GH_HOST PATH="$tmp:$PATH" local/bin/openbuilder status artemkurylo/openbuilder`):
   same result, and never `unset`. Before this change the first run records `example.com` three times.
2. No unwrapped call site survives. All three of these print `0`:
   ```
   grep -cE '^[[:space:]]*gh ' local/bin/openbuilder
   grep -cE '\$\(gh ' local/bin/openbuilder
   grep -cE '^[[:space:]]*if gh ' local/bin/openbuilder
   ```
   Before this change they print `7`, `4` and `1` — twelve sites in three syntactic shapes.
3. Inventory. `grep -n '\bgh\b' local/bin/openbuilder` lists a `gh` token only on: the eight
   `ob_need` lines, the `a gh error` comment above `ob_pr_relabel`, the `merge it with: gh pr merge`
   printf, and one executing `gh "$@"` inside `ob_gh`. Any other line is a missed call site.
   (`\bgh\b` does not match inside `ob_gh`, because `_` is a word character.)
4. The instance-side assertion:
   ```
   OPENBUILDER_ENV_FILE=/dev/null OPENBUILDER_HOME=$(mktemp -d) OPENBUILDER_GH_HOST=ghe.example.com \
     bash -c 'source runner/bin/ob-common.sh; ob_load_env'; echo $?
   ```
   prints `1` and a stderr line containing
   `OPENBUILDER_GH_HOST is 'ghe.example.com'; openbuilder supports github.com only`. The same command
   with `OPENBUILDER_GH_HOST=github.com` prints `0`. Before this change the first form prints `0`.
5. The laptop-side assertion: `OPENBUILDER_GH_HOST=ghe.example.com local/bin/openbuilder help` exits
   1 with that same message, `OPENBUILDER_GH_HOST=ghe.example.com local/bin/openbuilder status artemkurylo/openbuilder`
   exits 1 with it too, and `OPENBUILDER_GH_HOST=github.com local/bin/openbuilder help` exits 0 and
   prints the usage table.
6. `shellcheck -x -S warning local/bin/openbuilder runner/bin/ob-common.sh` exits 0 and prints
   nothing. It exits 0 before this change too, so a new warning is a regression, not a pre-existing
   one.

Remove the probe directory afterwards: `rm -rf "$tmp"`.

## Out of scope

- No owner allowlist, no `OPENBUILDER_OWNER`, no `origin` assertion. That is
  `story-01-owner-allowlist`; do not touch `ob_validate_repo` or `ob_ensure_clone`'s fetch branch.
- No `ob_git` wrapper and no change to any `git -C "$dir" …` invocation. `gh repo clone` derives its
  URL from the pinned host, and the managed clone's `origin` is story-01's problem.
- Do not port the token handling from `ob-common.sh:261-270` into the laptop wrapper. No `GH_TOKEN`,
  no `GITHUB_TOKEN`, no `ob_gh_token`, no `rc` variable, no `ob_log`/`ob_info` call inside `ob_gh`.
- No retry, no timeout, no rate-limit handling, no `--jq` normalisation, and no caching in `ob_gh`.
- Do not change the `printf 'merge it with: gh pr merge …'` line in `cmd_approve`.
- Do not remove `OPENBUILDER_GH_HOST`, its default at `ob-common.sh:91`, or its entry in the export
  list at `ob-common.sh:104-109`.
- Do not touch `infra/templates/cloud-init.yaml.tftpl`, `waker/`, `docs/`, `README.md`, `Makefile`, or
  any other file under `runner/bin/`.
- No new dependency, no reformatting of either file, no rename of any existing function, and no
  reindentation.

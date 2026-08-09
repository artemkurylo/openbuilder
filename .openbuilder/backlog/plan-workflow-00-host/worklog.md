# Worklog — plan-workflow-00-host

## Round 001 — story-01-owner-allowlist + story-02-pin-gh-host (implemented)

Both cards implemented and verified; neither blocks the other.

- `ob_validate_repo` now refuses owners not in `OPENBUILDER_OWNER` (comma-separated,
  exact case-sensitive match, default `artemkurylo`, empty value falls back to the
  default) before any `gh`/`git`/`aws` call. `ob_assert_origin_host` refuses a managed
  clone whose `origin` is not `https://github.com/`, `git@github.com:` or
  `ssh://git@github.com/`; it runs inside `ob_ensure_clone`'s existing-clone branch
  (before the fetch) and in `cmd_dispatch` after the clone-existence check.
- Every `gh` invocation in `local/bin/openbuilder` now goes through `ob_gh`, which
  pins `GH_HOST=github.com` in the child environment only. The literal `gh` remains on
  the eight `ob_need` lines, the `a gh error` comment, and the `merge it with:` printf.
- `OPENBUILDER_GH_HOST` is now an assertion in both `ob_load_local_config` (laptop) and
  `ob_load_env` (instance, `runner/bin/ob-common.sh`), with the same message string in
  both places. Unset defaults to `github.com`; any other value refuses startup.
- **Deliberate deviation:** the `ob_gh` header comment was reworded to avoid the bare
  word `gh` so the story-02 acceptance grep (`grep -n '\bgh\b'`) lists exactly the
  ob_need/comment/printf/`gh "$@"` lines. The card prescribed the comment's *content*
  (this laptop's gh is authenticated to more than one host; personal-account tool;
  host must not come from env/cwd) — all of it is preserved.
- `OPENBUILDER_OWNER` follows the same saved/restore/default three-step shape as the
  other five `OPENBUILDER_*` variables in `ob_load_local_config`, so a real environment
  variable outranks `.openbuilder.local`.
- The build box had no `shellcheck`; it was installed as a static binary to
  `~/.local/bin` (v0.10.0) purely to run the acceptance lint. Not a repo change.
- Deliberately untouched per Out of scope: `ob_validate_slug`, `ob_validate_pr`,
  `ob_clone_dir`, `ob_ensure_running` ordering in `cmd_dispatch`, `infra/`, `waker/`,
  `docs/`, `README.md`.

Verification: every acceptance command of both cards run and passed (see the round
summary the wrapper appends); `make lint` and `make scrub` exit 0.
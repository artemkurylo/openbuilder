# Worklog — scrub-hook

## Round 001 (story-01-ob-install-hooks)

- Added `local/bin/ob-install-hooks` (executable): installs a per-clone `pre-commit` hook that runs
  `ob-scrub-check --staged` via `exec`, so its exit status propagates and a deny-list match refuses
  the commit. Hooks dir resolved only with `git rev-parse --git-path hooks` (returns a possibly
  relative path — anchored to absolute; `core.hooksPath` is never read nor modified). Ownership is
  marked by the line `Installed by ob-install-hooks` in the hook body. `--force` preserves a foreign
  hook as `<hook>.bak`; `--uninstall` removes only a marked hook, refuses a foreign one; unknown
  argument exits 2; running outside a git tree exits 1.
- `Makefile`: new `hooks` target added to `.PHONY` with a `##` help comment,
  `@local/bin/ob-install-hooks`. `README.md`: `make hooks` added to the "Before you push" table and
  to the repo-layout tree; hook documented as per-clone, opt-in, removed with `--uninstall`, and
  bypassable with `git commit --no-verify`.
- Verified end to end in a scratch clone under /tmp: plain install + absolute-path print, second run
  reports "already installed" with the file byte-identical, `git commit` refused on a deny-list
  match while a clean commit passes, foreign-hook refusal names `--force`, `--force` leaves `.bak`,
  `--uninstall` ours-only, absent/uninstalled/unknown-arg/outside-repo paths. This worktree's real
  hooks dir is shared with the main checkout (`git rev-parse --git-path hooks` →
  `/opt/openbuilder/src/artemkurylo__openbuilder/.git/hooks`, samples only beforehand), so the
  worktree `make hooks` run was uninstalled immediately; the clone was handed back hookless.
- Notes for future rounds:
  - shellcheck is NOT installed on the instance, so `make lint` normally skips. Downloaded the
    static v0.11.0 linux-aarch64 binary to /tmp for verification; a future round needing `make lint`
    must do the same or install as root.
  - The persistent shell session retains exported env vars across bash calls: a
    `OPENBUILDER_SCRUB_DENY` export from a sandbox test leaked into a later `make scrub`, which then
    reported "clean" against the throwaway list. Unset it (or remember it) before judging scrub
    output.
## Round 1 — 2026-08-09T07:39:46Z

Implementation round by `ob-implement` (attempt 1 of 6).

- action: implement
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 2
- cost: 0.045049087999999994 USD
- story cards: 1

### Agent summary

Done. Final state verified: two commits, clean tree, hooks dir restored, sandbox removed.

## Summary
Added `local/bin/ob-install-hooks` (story-01): an executable installer that resolves the hooks directory via `git rev-parse --git-path hooks` (never constructs or reconfigures it), writes a short `pre-commit` hook that `exec`s `ob-scrub-check --staged`, marks it with a stable ownership line, and supports `--force` (foreign hook kept as `.bak`) and `--uninstall` (ours only, non-zero on foreign). Wired `make hooks` into the Makefile (`.PHONY` + `##` help comment) and documented it in README's "Before you push" section and repo-layout tree, stating plainly that the hook is per-clone, opt-in, and bypassable with `--no-verify`.

## Stories
- story-01-ob-install-hooks: done — all 11 acceptance lines verified by running the script in a scratch clone and in this worktree.

## Verification
- `shellcheck -x -S warning local/bin/ob-install-hooks` (v0.11.0, static linux-aarch64 binary — shellcheck is not installed on this instance, so `make lint` would otherwise skip) -> exit 0; `make lint` (same binary on PATH) -> exit 0 over all 15 scripts
- `local/bin/ob-install-hooks --help` -> usage, exit 0
- Scratch-clone runs: plain install -> hook executable at `$(git rev-parse --git-path hooks)/pre-commit`, absolute path printed; second run -> "already installed", exit 0, byte-identical (`md5sum`); staged file matching a temp deny list -> `git commit` exit 1, no commit created, while a clean commit passed; foreign one-line hook -> exit 1 naming `--force`, file untouched; `--force` -> exit 0, `.bak` preserved with old content, new hook installed; `--uninstall` -> removed ours (exit 0), refused foreign (exit 1, file preserved); absent hook / unknown arg (exit 2) / outside git tree (exit 1) paths all correct; all failure messages on stderr
- `make hooks` in this worktree -> install, exit 0; re-run -> "already installed", exit 0; then `--uninstall`; `make help` lists `hooks` between `fmt` and `init`
- `make scrub` -> exit 0 (this clone has no `.scrub-deny`; runs print the instructive create-it message; an earlier run against a throwaway deny list left over in the shell env also reported clean)
- Commits: `1804b40` (feature: script + Makefile + README), `62c331f` (worklog); working tree clean

## Notes for the reviewer
- This worktree is a linked worktree: `git rev-parse --git-path hooks` resolves to the main checkout's shared `.git/hooks` (samples only before and after). The `make hooks` verification installed there and was uninstalled immediately; the clone is hookless as found.
- The commit-refusal scenario was exercised in a throwaway `/tmp` clone (with `ob-scrub-check` copied in), not in this worktree, to avoid staging real content against a temp deny list here.
- No learnings proposed; the two environment quirks discovered (missing shellcheck; a test-exported `OPENBUILDER_SCRUB_DENY` leaking into a later `make scrub` in the persistent shell) are recorded in the round-001 worklog instead.



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
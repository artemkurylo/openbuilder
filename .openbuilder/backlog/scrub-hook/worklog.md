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


## Round 002 (review round 2)

- Review defects fixed in `local/bin/ob-install-hooks` (three focused commits):
  - Argument parsing now loops over `"$@"` (ob-learn style) instead of reading only
    `$1`, so `--force --bogus` exits 2 naming the unknown argument; `--force` with
    `--uninstall` is rejected as a contradiction (exit 2, stderr).
  - Shared `core.hooksPath` refusal: when `git rev-parse --git-path hooks` resolves
    outside the repository's own git directory, a plain install exits 1, names
    `core.hooksPath`, offers `--force`, and writes nothing. The comparison uses
    `git rev-parse --git-common-dir` (not `--absolute-git-dir`), so a linked
    worktree — whose hooks dir is the common git dir of the same repository — is
    still allowed, as is uninstall from a forced shared install. The setting is
    never read or modified.
  - Hook body now resolves its own repository (`git rev-parse --show-toplevel`)
    and exits 0 quietly when that repository has no executable
    `local/bin/ob-scrub-check`, instead of dying with "No such file or directory"
    in a repo it was never installed for (the reviewer's repro: a hook forced into
    a shared dir fires in every repo; it must be a no-op, not a wall). Still
    `exec`s the check when present, so exit status propagates.
  - `--force` now says when it replaces an existing `.bak` (reviewer's optional
    item, cheap so done).
- Round-1 behaviors re-verified in a scratch clone of the worktree: --help exit 0;
  plain install prints the absolute path; second run "already installed" with the
  file byte-identical; staged deny-list match refuses the commit while a clean
  commit passes; foreign-hook refusal names --force and leaves the file intact;
  --force keeps the foreign hook as `.bak`; --uninstall removes only ours;
  outside-repo exit 1; unknown argument exit 2; make hooks + make help (listed).
- Shared-hooksPath scenarios exercised with `GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp/shared-hooks`: plain
  run refuses (exit 1, nothing created); `--force` installs there; the hook then
  fires in an unrelated repo and exits 0 quietly, and in its own repo runs
  ob-scrub-check (exit 1 on a staged match). Linked-worktree install of the same
  clone is allowed and the hook fires from the worktree root. Clone handed back
  hookless; scratch dirs removed.
- `make lint` (shellcheck v0.11.0 static binary on PATH, same as round 1) exit 0
  over all 15 scripts including the new hook-body check on an installed copy;
  `make scrub` exit 0. Working tree clean.
- Learning proposed this round: shared `core.hooksPath` — a hooks dir outside the
  repository's own git dir is run by every repo, so refuse the install and make
  the hook a no-op where the tool it invokes is absent. Candidate appended to the
  round-002 proposal file for the reviewer.

## Round 2 — 2026-08-09T07:51:28Z

Review-response round by `ob-respond` (attempt 2 of 6).

- action: respond to review
- pull request: #2
- model: `openrouter/deepseek/deepseek-v4-flash-0731`
- new commits: 4
- cost: 0.06718643456 USD

### Agent summary

## Summary
Addressed both defects plus the optional item: argument parsing now loops over `"$@"` and rejects `--force --uninstall` as a contradiction; a plain install refuses a hooks directory outside the repository's own git dir (naming `core.hooksPath` and `--force`, writing nothing); and the hook body now resolves its own repository and exits 0 quietly where `ob-scrub-check` is absent, so a forced install into a shared dir is a no-op elsewhere, not a wall. Proposed the `core.hooksPath` learning to the reviewer. Four commits, tree clean.

## Feedback
- `local/bin/ob-install-hooks` arg parsing: fixed — loops over `"$@"`; `--force --bogus` exits 2 naming the argument; `--force --uninstall` exits 2 as a contradiction.
- `local/bin/ob-install-hooks` shared `core.hooksPath`: fixed — resolved hooks dir compared against the repository's own git dir via `git rev-parse --git-common-dir`; outside it, install exits 1 (stderr, names `core.hooksPath` and `--force`), nothing created, setting untouched. Deliberate deviation: `--git-common-dir` rather than the suggested `--absolute-git-dir`, because that flag resolves to the per-worktree dir and would falsely refuse legitimate installs from linked worktrees of the same repository (this worktree included), while the common dir is the true owner of the hooks directory. Uninstall from a forced shared install still works.
- Hook body: fixed — `git rev-parse --show-toplevel`, exit 0 quietly when `$REPO_ROOT/local/bin/ob-scrub-check` is not executable, else `exec` it (exit status still propagates).
- `--force` overwriting an existing `.bak`: fixed — prints "replacing the previous ... .bak" first (your optional item).
- Learning: proposed — one candidate written to `rounds/002/learnings-proposed.md`; it passed all four tests and is not in `LEARNINGS.md`.

## Verification
- `shellcheck -x -S warning local/bin/ob-install-hooks` (v0.11.0 static, as round 1) -> exit 0; same on an installed hook copy -> exit 0; `make lint` (binary on PATH) -> exit 0 over all 15 scripts; `make scrub` -> exit 0
- Scratch-clone runs (state: branch HEAD `19fce02`): `--help` exit 0; plain install -> absolute path printed, `-x` hook; second run -> "already installed", exit 0, byte-identical (`md5sum`); staged deny match -> `git commit` exit 1, no commit; clean commit passes; foreign hook -> exit 1 naming `--force`, file intact; `--force` -> preserved as `.bak` (and says when replacing an existing `.bak`); `--uninstall` removes ours, refuses foreign (exit 1); absent/outside-repo/unknown-arg paths exit 0/1/2 as before
- Shared-hooks repro (`GIT_CONFIG_KEY_0=core.hooksPath …`): plain run -> exit 1, message names `core.hooksPath` and `--force`, `/tmp/shared-hooks` never created; `--force` -> installs there; that hook fired in an unrelated repo -> exit 0, no output; fired in its own repo -> refuses a staged match (exit 1); old pre-fix body reproduced verbatim failing `No such file or directory` (exit 127) to confirm the mechanism
- Linked worktree of the clone: install allowed into the common git dir, hook fires from the worktree root, uninstall works
- `make hooks` -> install, re-run -> "already installed", `make help` lists `hooks`; clone left hookless, scratch dirs removed
- Commits: `f8ede33` (args), `71e6c3b` (shared-dir + hook no-op), `19fce02` (.bak), `b4dc610` (worklog); working tree clean

## Still open
- none

### Learnings proposed this round

Candidates only. They reach `LEARNINGS.md` in the control repo when the reviewer commits them there, and nowhere else.

### N. A hook installed in one repository must be a no-op, not a wall, in every other

**Symptom** `/tmp/shared-hooks/pre-commit: line 4: /tmp/other-repo/local/bin/ob-scrub-check: No such file or directory` (exit 127) — a hook installed in one repository dying in every other repository that shares the same `core.hooksPath`.
**Cause** `git rev-parse --git-path hooks` honours `core.hooksPath`. When that setting points at a shared directory (a global `~/.githooks` is the common setup), one hook file runs in every repository, and a hook body that references `local/bin/...` relative to the working tree resolves it against whichever repository happens to be committing.
**Rule** Treat the resolved hooks directory like any shared location: before writing to it, verify it lies inside the repository's own git directory (`git rev-parse --git-common-dir`) and refuse otherwise, naming `--force` for the deliberate case; and write the hook so it resolves its own repository (`git rev-parse --show-toplevel`) and exits 0 quietly when the command it would run is not present there.
**Proven** 2026-08-09 on the instance while addressing the review of `ob-install-hooks` (artemkurylo/openbuilder#2): a hook body of `exec local/bin/ob-scrub-check --staged` installed under `core.hooksPath=/tmp/shared-hooks` died in an unrelated repository with exactly the quoted error; after the fix, the same hook exits 0 in a repository without the tool and still refuses a staged deny-list match in its own repository.


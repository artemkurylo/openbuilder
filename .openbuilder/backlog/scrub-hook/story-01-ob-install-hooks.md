---
id: story-01-ob-install-hooks
title: Add local/bin/ob-install-hooks to install a pre-commit scrub hook
size: S
depends_on: []
files:
  - local/bin/ob-install-hooks
  - Makefile
  - README.md
acceptance:
  - "local/bin/ob-install-hooks exists, is executable, starts with #!/usr/bin/env bash, and shellcheck -x -S warning exits 0 on it"
  - "ob-install-hooks --help prints usage and exits 0"
  - "a plain run installs an executable pre-commit hook into the clone's real hooks directory, resolved via `git rev-parse --git-path hooks`, and prints the path it wrote"
  - "the installed hook runs ob-scrub-check --staged and exits non-zero when it does, so the commit is refused"
  - "running it twice in a row succeeds both times and reports the second as already installed, with no duplicated content"
  - "when a pre-commit hook already exists that this tool did not write, it exits non-zero, does not overwrite, and its message names --force"
  - "--force replaces such a hook, and preserves the previous file next to it with a .bak suffix"
  - "--uninstall removes a hook this tool wrote, and refuses with a non-zero exit to remove one it did not"
  - "core.hooksPath is never read for writing decisions nor modified: the script only ever writes inside the directory git itself reports"
  - "make hooks runs the installer, and make help lists it"
  - "every failure writes its message to stderr and exits non-zero"
---

## Context

You are working in the openbuilder control repository. Read `AGENTS.md` first — it is the house style and
it names the two standing obligations. Read `local/bin/ob-scrub-check` before writing anything: it is both
the tool the hook invokes and the closest model for the style of the script you are adding.

What you need to know about this repo:

- Shell style, non-negotiable and visible in every script under `runner/bin/` and `local/bin/`:
  `#!/usr/bin/env bash`, then `set -euo pipefail`, then `IFS=$'\n\t'`, a header comment block that
  explains **why** the file exists, two-space indentation, `local` for every function variable, and long
  clear functions over clever one-liners.
- `ob-scrub-check --staged` checks the git index against a deny list and exits 1 on a match. It prints
  paths and match counts and never the matching text, on purpose. With no deny list present it prints
  instructions and exits 0, so the hook is harmless on a fresh clone.
- The hooks directory is **not** always `.git/hooks`: a worktree, a submodule or a `core.hooksPath`
  setting moves it. `git rev-parse --git-path hooks` is the only correct way to ask, and it may return a
  relative path. Do not construct the path yourself, and do not change `core.hooksPath`.
- The `Makefile` has a `.PHONY` line listing every target and a `## comment` convention that the `help`
  target parses. Follow both; a target missing from `.PHONY` is a latent bug.
- There is no test framework in this repository. Verification is `shellcheck` plus running the command,
  which is what the acceptance list is written against.

## Change

1. Create `local/bin/ob-install-hooks`, executable. Interface:

   ```
   ob-install-hooks [--force] [--uninstall] [--help]
   ```

2. Resolve the hooks directory with `git rev-parse --git-path hooks`, create it if absent, and write
   `pre-commit` there. Print the absolute path you wrote.

3. The hook body must invoke `ob-scrub-check --staged` from the repository it is installed in and
   propagate its exit status, so a match refuses the commit. Keep the hook short and make it explain
   itself in one comment line, including the fact that `--no-verify` bypasses it.

4. Mark the hook as yours with a stable marker line in its body, and use that marker for every ownership
   decision:
   - already installed and marked as yours -> report it and exit 0 without rewriting;
   - present but not marked as yours -> exit non-zero, change nothing, and name `--force` in the message;
   - `--force` -> move the existing file aside with a `.bak` suffix, then install;
   - `--uninstall` -> remove it when marked as yours, otherwise refuse non-zero.

5. Add a `hooks` target to the `Makefile` that runs the installer, with a `##` help comment, and add it
   to `.PHONY`.

6. Update `README.md` where it documents make targets, so `make hooks` is listed alongside `make lint`
   and `make scrub`. Say plainly that the hook is per-clone and opt-in, and that `--no-verify` bypasses
   it — a guarantee it cannot make must not be implied.

## Verification

No test runner here, so verify by running it and state each result in your final message:

1. `shellcheck -x -S warning local/bin/ob-install-hooks` exits 0.
2. `local/bin/ob-install-hooks --help` prints usage, exits 0.
3. A plain run installs the hook; `test -x "$(git rev-parse --git-path hooks)/pre-commit"` succeeds.
4. A second run reports it as already installed and exits 0, and the hook file is byte-identical.
5. Stage a file containing a string your temporary deny list matches, point `OPENBUILDER_SCRUB_DENY` at
   that list, and confirm `git commit` is refused. Then unstage and remove it.
6. Replace the hook with an unrelated one-line script and confirm a plain run refuses and names
   `--force`; then confirm `--force` installs and leaves a `.bak`.
7. `--uninstall` removes yours, and refuses on a foreign hook.
8. `make hooks` works and `make help` lists it.

Leave the clone without an installed hook when you are done — uninstall it as your last verification
step, so the repository you hand back is in the state you found it.

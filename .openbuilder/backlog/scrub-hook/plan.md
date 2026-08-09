# Refuse the leak at commit time, not at review time

`ob-scrub-check` already refuses to publish employer, client, hostname and account identifiers, and
`make scrub` runs it over the working tree and the whole history. Both are opt-in: they only help if
someone remembers to run them. The one moment where remembering matters is the moment a string enters
history, because a match already pushed needs history rewritten rather than a follow-up commit.

This slice adds `local/bin/ob-install-hooks`, which installs a `pre-commit` hook that runs
`ob-scrub-check --staged`. One small command, opt-in per clone, uninstallable, and honest about the fact
that a hook is a convenience rather than a guarantee — `--no-verify` exists and CI is a separate concern.

Scope is one story. The script is a leaf: nothing else calls it, so it is verifiable in isolation.

## Stories

1. `story-01-ob-install-hooks` — the installer, with `--uninstall`, `--force`, idempotency, and refusal
   to clobber a hook it did not write.

## Out of scope

- Any change to `ob-scrub-check` itself, to the deny list, or to `LEARNINGS.md`.
- Installing the hook automatically. A hook that appears without being asked for is a hook that gets
  deleted in anger.
- CI enforcement, `pre-push`, `commit-msg`, or any second hook.
- `core.hooksPath` reconfiguration: respect whatever the clone already uses, never change it.

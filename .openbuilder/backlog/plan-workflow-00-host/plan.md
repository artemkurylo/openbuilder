# fix(cli): pin every gh call to github.com and refuse non-personal owners

- epic: plan-workflow

## Goal

`local/bin/openbuilder` must be incapable of touching a repository that is not on `github.com` and
not owned by the personal account. Two properties, both held by code rather than by habit:

1. a non-personal owner is refused at argument-parsing time, before any `gh`, `git` or `aws` call,
   naming both the owner it refused and the allowlist it checked against;
2. every `gh` invocation the CLI makes resolves `github.com`, whatever `GH_HOST` the ambient
   environment or the current directory's remote suggests.

## Why now

PRD R11 and RFC §4b. The boundary is currently held by coincidence: this laptop's `gh` is
authenticated to two hosts, both active for their host, and the CLI's twelve `gh` invocations
(`openbuilder:430,435,442,468,472,493,750,808,827,847,848,849`) pin nothing, so the host comes from
the ambient environment or the cwd's remote. `ob_validate_repo` (`openbuilder:244-247`) checks only
the shape `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, so every owner passes. Both holes are demonstrable
today, not hypothetical:

```
$ GH_HOST=example.com <stub gh on PATH> openbuilder status artemkurylo/openbuilder
   -> the stub is invoked 3 times and sees GH_HOST=example.com every time
$ openbuilder status someorg/somerepo
   -> exit 0, three live calls made against someorg/somerepo
```

RFC §4b.3 puts this slug first because `plan-workflow-05-cli` rewrites four commands in this same
file; landing the boundary afterwards would mean auditing four brand-new call sites for a property
they should have inherited.

## Approach

Three layers from RFC §4b.2, split across two stories by *when the refusal happens* rather than by
file, so each story has its own verification command and neither depends on the other:

- **story-01** — refusals that happen from the arguments alone, with no network: the
  `OPENBUILDER_OWNER` allowlist in `ob_validate_repo`, and an `origin`-host assertion on the managed
  clone.
- **story-02** — the host pin: an `ob_gh()` wrapper, all twelve call sites moved onto it, and
  `OPENBUILDER_GH_HOST` turned from a setting into an assertion in both `ob_load_env` and
  `ob_load_local_config`.

They are not merged into one story because they fail differently and are proven differently:
story-01 is proven by a command that makes *zero* subprocess calls, story-02 by a command that makes
three and inspects the environment each one inherited. Neither needs the other's code to be verified,
so both carry `depends_on: []` even though they edit the same file.

Decisions made here so neither card leaves one open:

- The wrapper is named `ob_gh`, matching the instance-side wrapper at `ob-common.sh:261` so the two
  sides of the system use one name for one concept.
- The wrapper covers `gh` only, **not** `git`. `gh repo clone` derives its URL from the pinned host,
  and every other remote-touching `git` call runs inside the managed clone, whose `origin` story-01
  asserts. There is no third mechanism.
- The allowlist variable is `OPENBUILDER_OWNER`, comma-separated, default `artemkurylo`, defaulted
  alongside the other `OPENBUILDER_*` defaults in `ob_load_local_config` (`openbuilder:121-125`) so
  a real environment variable outranks `.openbuilder.local` exactly as the existing five do.
- Owner comparison is exact and case-sensitive. GitHub owners are case-insensitive, but the
  allowlist is operator-written and its default is a literal account name, so a case variant is a
  typo worth refusing rather than a spelling to accept. This also avoids `${var,,}`, which needs
  bash 4.
- The `origin` assertion lives in a helper called from `ob_ensure_clone` and `cmd_dispatch`, not
  inline in `cmd_plan`. `cmd_plan` obtains its clone through `ob_ensure_clone`, and the `git fetch`
  at `openbuilder:489` is itself the network call the assertion has to precede, so inside
  `ob_ensure_clone` is the only placement where R11's "before any network call" actually holds.
  `cmd_dispatch` gets the same helper because its `git push` at `openbuilder:710` is the other way a
  reused workspace directory reaches a remote.

## Stories

| id | title | size | depends_on |
|---|---|---|---|
| story-01-owner-allowlist | Refuse non-personal owners and non-github.com clone origins | S | [] |
| story-02-pin-gh-host | Route every gh call through ob_gh and make OPENBUILDER_GH_HOST an assertion | S | [] |

## Out of scope

- Anything about epics, `state.json`, `ob-gate`, rule 4b, the PRD/RFC prompt blocks, `cmd_land` or
  `cmd_review --watch`. Those are slugs 01 through 05 of the same epic.
- `waker/github.py`. `API = "https://api.github.com"` at `waker/github.py:27` is already hard-pinned;
  there is nothing to change.
- `infra/templates/cloud-init.yaml.tftpl`. `OPENBUILDER_GH_HOST=github.com` at line 50 is already
  the required value and the variable keeps its name, so no Terraform change and no re-apply.
- `docs/architecture.md`. Its environment contract (lines 115-121) lists variable *names* and calls
  them frozen; both statements stay true, so there is no doc to correct.
- Any new dependency, any AWS/SSM change, any reformatting of either file, and any rename of an
  existing function.

## Risks

- **Merge order.** This slug must merge before `plan-workflow-05-cli`, which rewrites four commands
  in `local/bin/openbuilder` (RFC §9). Landing them the other way round means slug 05's new commands
  are written against a file without `ob_gh()` and reintroduce unpinned call sites.
- **The two stories share one file.** Both edit `local/bin/openbuilder`, and both add one line to its
  header comment block. They touch disjoint functions, and each card names the function it edits, but
  a reviewer should read the diff of `ob_validate_repo`, `ob_ensure_clone`, `ob_gh` and
  `ob_load_local_config` separately rather than as one change.
- **`GH_HOST` and `OPENBUILDER_GH_HOST` are different variables.** `GH_HOST` is `gh`'s own; the
  wrapper sets it. `OPENBUILDER_GH_HOST` is openbuilder's; the assertion refuses it. Conflating them
  would make the story-02 probe assert against the variable it just set. Reviewer should check the
  assertion reads `OPENBUILDER_GH_HOST` and the wrapper writes `GH_HOST`.
- **A missed call site is invisible at review time.** Twelve substitutions in a 1189-line file; a
  reviewer reading the diff cannot see a site that was not in it. The three zero-count greps in
  story-02's acceptance are what catches this, so they must actually be run, not reasoned about.
- **RFC §4b.1 says 23 call sites; the file has 12.** The number in the RFC is stale relative to
  `local/bin/openbuilder` as it stands at 1189 lines. The design is unchanged — a wrapper, every call
  site moved to it — and story-02 lists the twelve lines explicitly. Do not go hunting for eleven
  more.

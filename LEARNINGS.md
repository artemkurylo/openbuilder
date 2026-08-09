# Learnings

Durable, hard-won operational knowledge for everything that runs in openbuilder: the implementer on
the instance, the planner and reviewer on the laptop, and whoever operates the infrastructure.

**Why this file exists.** Every entry below cost real time or real money to discover, and none of them
were catchable by reading code. Instances get rebuilt (a root volume cannot follow its instance to
another availability zone, so a rebuild destroys the disk), models get swapped, laptops change. This
file lives in the control repository precisely so none of that erases what was learned.

**How it reaches the implementer.** `ob-implement` and `ob-respond` inject this file verbatim into
every round's prompt, refreshed from the control repository's remote at the start of the round. So
publishing a new entry here takes effect on the very next round — no code deploy, no `ob-selfupdate`,
no instance restart.

## Rules for editing this file

1. **An entry earns its place by having been observed.** Symptom, cause, rule, and how it was proven.
   No speculation, no "best practices", nothing a linter or a type checker would have caught.
2. **State the rule as an imperative**, so it can be followed without re-deriving the story.
3. **Keep it repo-agnostic.** Knowledge about one target repository belongs in that repository, or in
   the slug's `worklog.md` — not here.
4. **Never delete an entry because it looks obvious.** It looks obvious because it is written down.
   Delete only when it has become false, and say so in the commit message.
5. **The implementer proposes, the reviewer commits.** An implementation round may append a candidate
   entry to the per-round proposal file its prompt names, and it arrives on the pull request for review.
   Only a human, or the reviewer acting for one, edits this file. (This file is injected into that
   prompt verbatim, so it deliberately contains no template placeholders of its own — they would reach
   the model unexpanded.)

Entry shape:

```
### N. Imperative rule, in one line
**Symptom** what you actually see, verbatim where possible.
**Cause** the mechanism, not the guess.
**Rule** what to do instead, every time.
**Proven** how it was demonstrated, and when.
```

---

## Rules the implementer must follow

### 1. Never conflate "I cannot access it" with "it is busy"
**Symptom** `ob-idle-stop: staying up: condition 1 failed — locks held: selfupdate`, forever, on an
instance where nothing was running. It billed seven hours instead of thirty minutes.
**Cause** `ob_lock_held` probed a lockfile by opening it for append inside a subshell. A permission
error made the subshell exit non-zero, which the caller read as "another process holds this lock", so
one root-owned lockfile was indistinguishable from a live job.
**Rule** A probe must fail for exactly one reason. When a check can fail because the resource is busy
*or* because the check itself is broken, separate the two: report the broken-check case loudly and
distinctly, and never let it silently choose the more expensive branch. Ask for the least authority
that still answers the question — a shared, read-only lock still detects an exclusive holder.
**Proven** 2026-08-09 on the instance: free lock, live exclusive holder, released lock, and an
unreadable root-owned lock each produce the correct verdict, the last one with a loud ERROR line.

### 2. Never run `git` as root against a repository owned by someone else
**Symptom** every later `git` command by the service user dies with `Permission denied` on
`.git/FETCH_HEAD` or `.git/index.lock`.
**Cause** `ob-selfupdate` ran as root and fetched into an `openbuilder`-owned clone, leaving
root-owned objects behind.
**Rule** Run `git` as the owning user (`runuser -u <owner> -- env HOME=<home> git …`). Reserve root
for what genuinely needs it, and hand back ownership of anything root creates in a shared directory.
**Proven** 2026-08-09, first real deployment; the same class of bug produced learning 1.

### 3. Exit code 0 is not proof that the work happened
**Symptom** `ob-doctor` blamed "bad key, model id or egress" when the real answer was an empty account
balance.
**Cause** `omp` exits 0 with an empty assistant message when the provider returns a hard HTTP 402.
**Rule** Verify the artefact, not the exit status: assert that the output exists and has the expected
shape, and when a subprocess fails, ask the upstream service for its own error text instead of
guessing. A diagnostic that guesses is worse than one that admits it does not know.
**Proven** 2026-08-09; `ob-doctor` now prints the provider's `.error.message` verbatim.

### 4. Never weaken a check to make it pass
**Rule** No skipped spec, no deleted assertion, no silenced linter, no widened type, no special-cased
input. Fix the cause, or stop and report the blocker precisely. A precise blocker is a good outcome; a
plausible guess is not.
**Why it is here** This is the rule whose violation is cheapest in the moment and most expensive
afterwards, so it is written down rather than assumed.

### 5. Read the permission you actually need, not the one with a familiar name
**Symptom** `ob-doctor` reported every repository unwritable on a healthy installation.
**Cause** it read `.permissions.push` from `GET /repos/{owner}/{repo}`, which describes a **user's**
role. A GitHub App installation token has no user, so that field is always `false`.
**Rule** When an API answers "no", check that the field you read describes the identity you are
actually using. For an App token the authority is the installation's permission set
(`contents=write`), not the repository's user-facing permission block.
**Proven** 2026-08-09; the check now uses repository reachability plus the installation's permissions.

## Environment truths

### 6. SSM `AWS-RunShellScript` runs `/bin/sh` (dash) on Ubuntu, not bash
**Symptom** `Bad substitution` from a script that runs perfectly in an interactive shell.
**Rule** Do not send bash syntax through SSM directly. Base64-wrap the script and pipe it to `bash` —
`local/bin/obrun` does exactly that, and reads `.openbuilder.local` for the target instance.
**Proven** repeatedly on 2026-08-08 and 2026-08-09, on `${VAR:0:3}` and on `[[ … ]]`.

### 7. cloud-init `runcmd` has no `HOME`
**Symptom** `fatal: $HOME not set` from `git config --global`, and because of `set -e`, a bootstrap
that looked 95% complete while having installed zero systemd units.
**Rule** Never assume an environment variable exists in a non-login, non-interactive context. Resolve
it explicitly (`getent passwd root`) and pass it.
**Proven** 2026-08-08, first boot.

### 8. Canonical's Ubuntu AMIs do not ship the AWS CLI
**Symptom** every `aws ssm get-parameter` fails, so no secret is readable, on an instance whose IAM
role is perfectly correct.
**Rule** Install it in bootstrap, derive the architecture, keep the install idempotent. Do not carry
over assumptions from Amazon Linux, which does ship it.
**Proven** 2026-08-08.

### 9. `terraform output -raw` can print a warning on stdout and still exit 0
**Symptom** the string `Warning: No outputs found` was cached as an AWS region.
**Rule** Validate the *shape* of any value captured from a subprocess before storing or reusing it.
Exit status alone does not tell you that a value is a value.
**Proven** 2026-08-08.

### 10. Starting a stopped EC2 instance can be refused, and its volume cannot move
**Symptom** `InsufficientInstanceCapacity` from `ec2:StartInstances`, repeatedly, for over half an
hour.
**Cause** stopping releases the host slot; starting asks for a new one in the *same* availability
zone, because an EBS volume is AZ-bound. It is not a quota — that is `InstanceLimitExceeded` — and no
other instance is holding anything that could be released.
**Rule** Treat a capacity refusal as expected and transient: log it plainly, leave the work queued,
retry on the next tick, and never let it become an unhandled exception on a schedule. When it
persists, move availability zone (`var.availability_zone`), which replaces the subnet and the
instance — cheap while the disk holds only caches, so move early. Capacity Reservations bill 24/7 and
would defeat stopping when idle.
**Proven** 2026-08-09: `eu-central-1a` refused every start while throwaway probes in `1b` and `1c`
were accepted immediately; the instance was moved to `1b`.

### 11. Force-pushing the control repository breaks the instance's clone
**Symptom** `ob-selfupdate` refuses with "fast-forward failed; history diverged".
**Cause** the clone is advanced with `merge --ff-only`, deliberately, so a rewritten history cannot be
swallowed silently.
**Rule** Do not rewrite published history on the control repository. If you must, reset the instance's
clone by hand afterwards. The refusal is the feature.
**Proven** 2026-08-08, after removing an author line from the public history.

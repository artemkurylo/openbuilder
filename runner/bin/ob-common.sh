#!/usr/bin/env bash
# ob-common.sh — SOURCED-ONLY shared library for the OpenBuilder runner.
# Single responsibility: one implementation of logging, secret redaction, locking,
# SSM secret access, GitHub CLI auth, per-job state and the verified omp invocation,
# so no other runner script ever reimplements them.
#
# Usage:  source "$(dirname "$0")/ob-common.sh"   (never execute this file)
set -euo pipefail
IFS=$'\n\t'

# Double-source guard: sourcing twice must be a no-op.
if [[ -n "${OB_COMMON_SH_SOURCED:-}" ]]; then
  return 0
fi
OB_COMMON_SH_SOURCED=1

# Directory this library lives in; also where the sibling `ob-token` lives.
OB_BIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Name used as the log prefix. Callers may override before sourcing.
OB_PROG="${OB_PROG:-$(basename -- "${0}")}"
# Never let git or gh block on an interactive credential prompt.
export GIT_TERMINAL_PROMPT=0

# ---------------------------------------------------------------------------
# Redaction and logging
# ---------------------------------------------------------------------------

# ob_redact — stdin/stdout filter that removes every credential shape this
# system can produce. Everything captured from a subprocess MUST pass through
# this before it is logged, commented on a PR, or written to disk.
ob_redact() {
  sed -E \
    -e 's/sk-or-[A-Za-z0-9_-]+/sk-or-REDACTED/g' \
    -e 's/ghs_[A-Za-z0-9]+/ghs_REDACTED/g' \
    -e 's/github_pat_[A-Za-z0-9_]+/github_pat_REDACTED/g' \
    -e 's/gh[pou]_[A-Za-z0-9]+/gh_REDACTED/g' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/ s|^[^-].*$|[PEM BODY REDACTED]|' \
    -e 's/-----BEGIN ([A-Z ]*)PRIVATE KEY-----/-----BEGIN \1PRIVATE KEY----- [BODY REDACTED]/'
}

# ob_log <level> <msg...> — ISO-8601 UTC line to stderr AND the operational log.
ob_log() {
  local level="$1"
  shift
  local ts line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '%s %-5s %s: %s' "$ts" "$level" "$OB_PROG" "$*" | ob_redact)"
  printf '%s\n' "$line" >&2
  if [[ -n "${OPENBUILDER_HOME:-}" && -d "${OPENBUILDER_HOME}/log" ]]; then
    printf '%s\n' "$line" >>"${OPENBUILDER_HOME}/log/openbuilder.log" 2>/dev/null || true
  fi
}

# ob_log_file <level> <file> — append captured subprocess output to the log,
# redacted line by line.
ob_log_file() {
  local level="$1" file="$2"
  [[ -s "$file" ]] || return 0
  local line
  while IFS= read -r line; do
    ob_log "$level" "| ${line}"
  done < <(ob_redact <"$file")
}

# ob_die <msg...> — log at ERROR and exit non-zero. Fail loud, never silent.
ob_die() {
  ob_log ERROR "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

# ob_load_env — load /opt/openbuilder/etc/openbuilder.env when readable, apply
# the frozen §5 defaults for anything missing, and make sure the directory tree
# exists. Idempotent. That file never contains secrets.
ob_load_env() {
  local envfile="${OPENBUILDER_ENV_FILE:-/opt/openbuilder/etc/openbuilder.env}"
  if [[ -r "$envfile" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$envfile"
    set +a
  fi

  : "${OPENBUILDER_HOME:=/opt/openbuilder}"
  : "${OPENBUILDER_SSM_PREFIX:=/openbuilder}"
  : "${OPENBUILDER_REPOS:=}"
  : "${OPENBUILDER_CONTROL_REPO:=artemkurylo/openbuilder}"
  : "${OPENBUILDER_GH_HOST:=github.com}"
  : "${OPENBUILDER_MODEL:=openrouter/deepseek/deepseek-v4-flash-0731}"
  : "${OPENBUILDER_SMOL_MODEL:=openrouter/deepseek/deepseek-v4-flash-0731}"
  : "${OPENBUILDER_MAX_RUNTIME:=45m}"
  : "${OPENBUILDER_MAX_ATTEMPTS:=6}"
  : "${OPENBUILDER_IDLE_STOP_MINUTES:=30}"
  : "${OPENBUILDER_BRANCH_PREFIX:=openbuilder}"
  : "${OPENBUILDER_LABEL_PREFIX:=openbuilder}"
  : "${OPENBUILDER_GIT_USER_NAME:=openbuilder-bot}"
  : "${OPENBUILDER_GIT_USER_EMAIL:=openbuilder-bot@users.noreply.github.com}"
  : "${AWS_REGION:=eu-central-1}"
  : "${PI_CODING_AGENT_DIR:=${OPENBUILDER_HOME}/.omp}"

  export OPENBUILDER_HOME OPENBUILDER_SSM_PREFIX OPENBUILDER_REPOS \
    OPENBUILDER_CONTROL_REPO OPENBUILDER_GH_HOST OPENBUILDER_MODEL \
    OPENBUILDER_SMOL_MODEL OPENBUILDER_MAX_RUNTIME OPENBUILDER_MAX_ATTEMPTS \
    OPENBUILDER_IDLE_STOP_MINUTES OPENBUILDER_BRANCH_PREFIX \
    OPENBUILDER_LABEL_PREFIX OPENBUILDER_GIT_USER_NAME \
    OPENBUILDER_GIT_USER_EMAIL AWS_REGION PI_CODING_AGENT_DIR
  export AWS_DEFAULT_REGION="$AWS_REGION"

  local dir
  for dir in log run state src work cache prompts; do
    mkdir -p "${OPENBUILDER_HOME}/${dir}"
  done
  chmod 0700 "${OPENBUILDER_HOME}/cache"
}

# ob_repos — one `owner/repo` per line, from the comma-separated env var.
ob_repos() {
  local item
  local -a items=()
  IFS=',' read -r -a items <<<"${OPENBUILDER_REPOS:-}"
  for item in "${items[@]+"${items[@]}"}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item"
  done
}

# ob_require_repo <owner/repo> — validate the shape of a repo argument.
ob_require_repo() {
  local repo="$1"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    ob_die "invalid repo '${repo}' (expected owner/name)"
}

# ob_require_slug <slug> — enforce the frozen slug contract from §4.
ob_require_slug() {
  local slug="$1"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,48}$ ]] ||
    ob_die "invalid slug '${slug}' (expected ^[a-z0-9][a-z0-9-]{1,48}\$)"
}

# ---------------------------------------------------------------------------
# Locking
#
# Dedicated file-descriptor map — do NOT reuse these fds anywhere else:
#   fd 9 — the lock this process HOLDS for the rest of its lifetime (ob_lock).
#          A process takes at most one such lock; the kernel releases it on exit.
#   fd 8 — transient probe, opened and closed inside a subshell by ob_lock_held.
#
# run/ is shared by two identities: the timers run as $OB_SERVICE_USER, while
# ob-selfupdate is legitimately run as root. Every lockfile therefore has to be
# openable by both, and a lockfile that is NOT openable must never be mistaken
# for a held one — that mistake kept the instance awake (and billing) for seven
# hours on the first real deployment.
# ---------------------------------------------------------------------------

# The unprivileged identity that owns $OPENBUILDER_HOME and runs the timers.
OB_SERVICE_USER="${OB_SERVICE_USER:-openbuilder}"

ob_lock_path() {
  printf '%s/run/%s.lock' "${OPENBUILDER_HOME}" "$1"
}

# ob_lock <name> — non-blocking flock on fd 9. Returns 0 when the lock is ours,
# non-zero WITHOUT exiting when another process holds it, so the caller decides
# whether that means "skip quietly" or something louder.
ob_lock() {
  local name="$1" lockfile
  lockfile="$(ob_lock_path "$name")"
  exec 9>>"$lockfile"
  # Group-writable, and owned by the service user whenever root created it, so
  # the other identity can still take this lock afterwards. Both calls are
  # no-ops for a file we do not own, hence the guards.
  chmod 0664 "$lockfile" 2>/dev/null || true
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${OB_SERVICE_USER}:${OB_SERVICE_USER}" "$lockfile" 2>/dev/null || true
  fi
  if ! flock -n 9; then
    exec 9>&-
    return 1
  fi
  return 0
}

# ob_lock_held <name> — 0 when some OTHER process currently holds that lock.
#
# The probe opens the lockfile READ-ONLY and asks for a SHARED lock: an
# exclusive holder still makes `flock -ns` fail, so detection is unchanged,
# but it no longer needs write permission. Failing to open the file at all is
# reported as a distinct, loud error and treated as NOT held: an ownership
# mistake is a configuration bug to fix, never a reason to keep the instance
# running forever.
ob_lock_held() {
  local name="$1" lockfile rc=0
  lockfile="$(ob_lock_path "$name")"
  [[ -e "$lockfile" ]] || return 1
  (
    exec 8<"$lockfile" || exit 3
    flock -ns 8 || exit 1
    exit 0
  ) || rc=$?
  case "$rc" in
  0) return 1 ;;
  1) return 0 ;;
  *)
    ob_log ERROR "cannot open lockfile ${lockfile} as $(id -un); treating it as NOT held — fix its ownership (expected ${OB_SERVICE_USER}:${OB_SERVICE_USER}, mode 0664)"
    return 1
    ;;
  esac
}

# ob_locks_held — names of every currently held lock, one per line.
ob_locks_held() {
  local path name
  shopt -s nullglob
  for path in "${OPENBUILDER_HOME}/run/"*.lock; do
    name="$(basename -- "$path" .lock)"
    if ob_lock_held "$name"; then
      printf '%s\n' "$name"
    fi
  done
  shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

# ob_ssm <param-name> — decrypted SSM Parameter Store value on stdout.
# The value is NEVER logged and never written to a file by this function.
ob_ssm() {
  local param="$1" name value
  name="${OPENBUILDER_SSM_PREFIX%/}/${param}"
  if ! value="$(aws ssm get-parameter --name "$name" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null)"; then
    ob_log ERROR "cannot read SSM parameter ${name}"
    return 1
  fi
  if [[ -z "$value" || "$value" == "None" || "$value" == "REPLACE_ME" ]]; then
    ob_log ERROR "SSM parameter ${name} is unset or still REPLACE_ME"
    return 1
  fi
  printf '%s' "$value"
}

# ob_gh_token — a GitHub App installation token (minted and cached by ob-token).
ob_gh_token() {
  "${OB_BIN_DIR}/ob-token"
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

# ob_gh <args...> — run `gh` with a fresh installation token in the CHILD
# environment only; the token is never exported into this shell.
ob_gh() {
  local token rc=0
  if ! token="$(ob_gh_token)"; then
    ob_log ERROR "could not mint a GitHub App token"
    return 1
  fi
  GH_TOKEN="$token" GITHUB_TOKEN="$token" GH_HOST="${OPENBUILDER_GH_HOST}" \
    gh "$@" || rc=$?
  return "$rc"
}

# ob_label <short> — the fully qualified label name, e.g. openbuilder:queued.
ob_label() {
  printf '%s:%s' "${OPENBUILDER_LABEL_PREFIX}" "$1"
}

# ob_ensure_labels <owner/repo> — create the six §4 labels if absent.
ob_ensure_labels() {
  local repo="$1" spec short color desc
  for spec in \
    'queued|fbca04|Plan branch pushed, waiting for the instance to pick it up' \
    'in-progress|1d76db|The remote agent is working on this right now' \
    'awaiting-review|0e8a16|PR is ready for the reviewer' \
    'changes-requested|d93f0b|The reviewer wants another implementation round' \
    'approved|5319e7|Approved; a human may merge and the instance stops touching it' \
    'blocked|b60205|The agent gave up; a human needs to look at this'; do
    IFS='|' read -r short color desc <<<"$spec"
    # `gh label create` errors when the label already exists; that is expected.
    ob_gh label create "$(ob_label "$short")" --repo "$repo" \
      --color "$color" --description "$desc" >/dev/null 2>&1 || true
  done
}

# ob_label_add <owner/repo> <issue-or-pr-number> <short-label>
# Uses the issues REST endpoint, which addresses issues and pull requests alike.
ob_label_add() {
  local repo="$1" number="$2" short="$3"
  ob_gh api -X POST "repos/${repo}/issues/${number}/labels" \
    -f "labels[]=$(ob_label "$short")" >/dev/null 2>&1 ||
    ob_log WARN "could not add label $(ob_label "$short") to ${repo}#${number}"
}

# ob_label_remove <owner/repo> <issue-or-pr-number> <short-label>
ob_label_remove() {
  local repo="$1" number="$2" short="$3"
  ob_gh api -X DELETE "repos/${repo}/issues/${number}/labels/$(ob_label "$short")" \
    >/dev/null 2>&1 || true
}

# ob_pr_labels <owner/repo> <number> — space-padded label list for matching.
ob_pr_labels() {
  local repo="$1" number="$2" names
  names="$(ob_gh api "repos/${repo}/issues/${number}" \
    --jq '[.labels[].name] | join(" ")' 2>/dev/null || printf '')"
  printf ' %s ' "$names"
}

# ob_has_label <space-padded-label-list> <short-label>
ob_has_label() {
  local haystack="$1" short="$2"
  [[ "$haystack" == *" $(ob_label "$short") "* ]]
}

# ob_pr_comment <owner/repo> <pr> <body-file>
ob_pr_comment() {
  local repo="$1" pr="$2" file="$3"
  ob_gh pr comment "$pr" --repo "$repo" --body-file "$file" >/dev/null ||
    ob_log WARN "could not comment on ${repo}#${pr}"
}

# ob_default_branch <owner/repo>
ob_default_branch() {
  local repo="$1" branch
  branch="$(ob_gh repo view "$repo" --json defaultBranchRef \
    --jq '.defaultBranchRef.name' 2>/dev/null || printf '')"
  [[ -n "$branch" ]] || return 1
  printf '%s' "$branch"
}

# ob_pr_number <owner/repo> <head-branch> [state] — empty when there is none.
ob_pr_number() {
  local repo="$1" head="$2" state="${3:-all}"
  ob_gh pr list --repo "$repo" --head "$head" --state "$state" \
    --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null || printf ''
}

# ob_report_blocked <owner/repo> <slug> <pr-or-empty> <message>
# Fail loud (hard rule 5): drop in-progress, add blocked, and leave a comment
# carrying a redacted log tail — on the PR, or on a dedicated tracking issue
# when no PR exists yet.
ob_report_blocked() {
  local repo="$1" slug="$2" pr="$3" message="$4"
  local body tail_file number title
  body="$(mktemp)"
  tail_file="$(mktemp)"
  tail -n 80 "${OPENBUILDER_HOME}/log/openbuilder.log" 2>/dev/null |
    ob_redact >"$tail_file" || true
  {
    printf '## openbuilder: blocked\n\n'
    printf '%s\n\n' "$message"
    printf -- '- slug: `%s`\n' "$slug"
    printf -- '- attempts: %s / %s\n' \
      "$(ob_attempts_get "$repo" "$slug")" "${OPENBUILDER_MAX_ATTEMPTS}"
    printf -- '- instance time: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Operational log tail (redacted):\n\n```\n'
    cat "$tail_file"
    printf '```\n'
  } >"$body"

  number="$pr"
  if [[ -z "$number" ]]; then
    title="openbuilder blocked: ${slug}"
    number="$(ob_gh issue list --repo "$repo" --state open --limit 1 \
      --search "in:title ${title}" --json number --jq '.[0].number // empty' \
      2>/dev/null || printf '')"
    if [[ -z "$number" ]]; then
      number="$(ob_gh issue create --repo "$repo" --title "$title" \
        --body-file "$body" 2>/dev/null |
        sed -n 's#.*/\([0-9][0-9]*\)$#\1#p' | tail -n 1 || printf '')"
    else
      ob_gh issue comment "$number" --repo "$repo" --body-file "$body" \
        >/dev/null 2>&1 || true
    fi
  else
    ob_pr_comment "$repo" "$number" "$body"
  fi

  if [[ -n "$number" ]]; then
    ob_label_remove "$repo" "$number" in-progress
    ob_label_add "$repo" "$number" blocked
  else
    ob_log ERROR "no PR or issue available to mark blocked for ${repo} ${slug}"
  fi
  rm -f "$body" "$tail_file"
}

# ---------------------------------------------------------------------------
# Per-job state
# ---------------------------------------------------------------------------

# ob_slug_key <owner/repo> <slug> → owner__repo__slug
ob_slug_key() {
  local repo="$1" slug="$2"
  printf '%s__%s' "${repo//\//__}" "$slug"
}

# ob_state_dir <owner/repo> <slug>
ob_state_dir() {
  local dir
  dir="${OPENBUILDER_HOME}/state/$(ob_slug_key "$1" "$2")"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# ob_src_dir <owner/repo> — clone location of a target repo.
ob_src_dir() {
  printf '%s/src/%s' "${OPENBUILDER_HOME}" "${1//\//__}"
}

# ob_worktree_dir <owner/repo> <slug>
ob_worktree_dir() {
  printf '%s/work/%s' "${OPENBUILDER_HOME}" "$(ob_slug_key "$1" "$2")"
}

# ob_attempts_get <owner/repo> <slug>
ob_attempts_get() {
  local file value
  file="$(ob_state_dir "$1" "$2")/attempts"
  if [[ -s "$file" ]]; then
    value="$(tr -dc '0-9' <"$file")"
    printf '%s' "${value:-0}"
  else
    printf '0'
  fi
}

# ob_attempts_incr <owner/repo> <slug> — prints the new value.
ob_attempts_incr() {
  local repo="$1" slug="$2" file next
  file="$(ob_state_dir "$repo" "$slug")/attempts"
  next=$(($(ob_attempts_get "$repo" "$slug") + 1))
  printf '%s\n' "$next" >"$file"
  printf '%s' "$next"
}

# ob_attempts_reset <owner/repo> <slug> — used by an operator to un-block a slug.
ob_attempts_reset() {
  local file
  file="$(ob_state_dir "$1" "$2")/attempts"
  printf '0\n' >"$file"
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

ob_clone_url() {
  printf 'https://%s/%s.git' "${OPENBUILDER_GH_HOST}" "$1"
}

# ob_sync_src <owner/repo> — clone or fetch the target repo into src/ and echo
# the path. Authentication comes from the git credential helper installed by
# bootstrap.sh, so no token ever lands in a URL or in argv.
ob_sync_src() {
  local repo="$1" dir url
  dir="$(ob_src_dir "$repo")"
  url="$(ob_clone_url "$repo")"
  if [[ -d "${dir}/.git" ]]; then
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch --prune --quiet origin
  else
    mkdir -p "$(dirname -- "$dir")"
    git clone --quiet "$url" "$dir"
  fi
  git -C "$dir" config user.name "${OPENBUILDER_GIT_USER_NAME}"
  git -C "$dir" config user.email "${OPENBUILDER_GIT_USER_EMAIL}"
  git -C "$dir" worktree prune
  printf '%s' "$dir"
}

# ob_remote_branch_exists <src-dir> <branch>
ob_remote_branch_exists() {
  local dir="$1" branch="$2"
  [[ -n "$(git -C "$dir" ls-remote --heads origin "$branch" 2>/dev/null)" ]]
}

# ob_add_worktree <src-dir> <worktree-dir> <branch> <start-point>
# Idempotent: reuses an existing worktree, otherwise points the branch at the
# start point and checks it out into its own worktree.
ob_add_worktree() {
  local src="$1" wt="$2" branch="$3" start="$4"
  if [[ -e "${wt}/.git" ]]; then
    git -C "$wt" checkout --quiet "$branch"
  else
    mkdir -p "$(dirname -- "$wt")"
    git -C "$src" worktree add --quiet -B "$branch" "$wt" "$start"
  fi
  git -C "$wt" config user.name "${OPENBUILDER_GIT_USER_NAME}"
  git -C "$wt" config user.email "${OPENBUILDER_GIT_USER_EMAIL}"
}

# ob_worklog_append <worktree> <slug> <round> <heading> <detail-file>
# Appends one timestamped round to the worklog that lives on the work branch,
# and prints the worklog path.
ob_worklog_append() {
  local wt="$1" slug="$2" round="$3" heading="$4" detail="$5"
  local dir file
  dir="${wt}/.openbuilder/backlog/${slug}"
  file="${dir}/worklog.md"
  mkdir -p "$dir"
  if [[ ! -s "$file" ]]; then
    printf '# Worklog — %s\n\nAppend-only. One section per agent round.\n' \
      "$slug" >"$file"
  fi
  {
    printf '\n## Round %s — %s\n\n' "$round" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n\n' "$heading"
    ob_redact <"$detail"
    printf '\n'
  } >>"$file"
  printf '%s' "$file"
}

# ---------------------------------------------------------------------------
# Learnings
# ---------------------------------------------------------------------------

# ob_learnings <out-file> — the curated LEARNINGS.md from the control repo.
#
# Read from the REMOTE first. Learnings are published by editing one file and
# pushing it, and that must take effect on the very next round: routing them
# through `ob-selfupdate` would tie a documentation change to a code deploy, and
# an instance that is rebuilt (an EBS volume cannot follow its instance across
# availability zones) must not lose them either. The local clone is the fallback,
# then the copy bootstrap installed, then nothing — a missing learnings file
# degrades a round, it never fails one.
#
# `fetch origin HEAD` deliberately writes FETCH_HEAD without moving any branch
# and without making the clone shallow, which would break ob-selfupdate's
# `merge --ff-only`. It cannot race that merge either: ob-selfupdate skips
# entirely while any job lock is held.
ob_learnings() {
  local out="$1" repo_dir="${OPENBUILDER_HOME}/repo"
  local installed="${OPENBUILDER_HOME}/LEARNINGS.md"
  local -a git_ro=(git -C "$repo_dir" -c safe.directory='*')

  : >"$out"
  if [[ -d "${repo_dir}/.git" ]]; then
    if "${git_ro[@]}" fetch --quiet origin HEAD 2>/dev/null &&
      "${git_ro[@]}" show FETCH_HEAD:LEARNINGS.md >"$out" 2>/dev/null &&
      [[ -s "$out" ]]; then
      ob_log INFO "learnings: $(wc -l <"$out" | tr -d ' ') lines from ${OPENBUILDER_CONTROL_REPO} (remote)"
      return 0
    fi
    if "${git_ro[@]}" show HEAD:LEARNINGS.md >"$out" 2>/dev/null && [[ -s "$out" ]]; then
      ob_log WARN "learnings: remote unreachable; using the local clone at $("${git_ro[@]}" rev-parse --short HEAD)"
      return 0
    fi
  fi
  if [[ -s "$installed" ]]; then
    cp -- "$installed" "$out"
    ob_log WARN "learnings: using the installed copy at ${installed}"
    return 0
  fi
  : >"$out"
  ob_log WARN "learnings: none found; this round runs without them"
}

# ob_learnings_proposed <file> — 0 when the round left a candidate entry behind.
#
# The file starts empty, so any non-blank line is a proposal. Deliberately NOT
# treating a leading `#` as a comment: the entry shape the prompt asks for is a
# markdown heading (`### N. rule`), and an earlier version of this check silently
# swallowed every real proposal for exactly that reason.
ob_learnings_proposed() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  grep -qE '[^[:space:]]' -- "$file"
}

# ob_learnings_section <proposal-file> — the markdown block that carries a
# round's proposed learnings, on stdout, or nothing at all when there is no
# proposal.
#
# One implementation on purpose. A proposal is written into the round directory,
# which lives on the instance's root volume — the least durable thing in the
# system: it is destroyed by a rebuild, and an EBS volume cannot follow its
# instance across availability zones (it happened on 2026-08-09). GitHub is the
# only durable store here, so every exit path that talks to GitHub has to be able
# to carry the proposal, and none of them may format it differently:
#
#   * a successful round appends this to the slug's worklog.md, which is
#     committed to the work branch and therefore reviewable in the PR diff;
#   * a FAILED round appends it to the blocked report, which comments on the PR
#     or opens a tracking issue.
#
# Without the second path a round that proposed a learning and then died — a
# failed push, a rejected test, an exhausted attempt budget — would lose it with
# the disk, silently, which is the one outcome this whole mechanism exists to
# prevent.
ob_learnings_section() {
  local file="$1"
  ob_learnings_proposed "$file" || return 0
  printf '### Learnings proposed this round\n\n'
  printf 'Candidates only. They reach `LEARNINGS.md` in the control repo when the '
  printf 'reviewer commits them there, and nowhere else.\n\n'
  ob_redact <"$file"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Prompt rendering
# ---------------------------------------------------------------------------

# ob_render_prompt <template> <out> <scalar-map> <block-map>
#
# scalar-map lines: NAME<TAB>value  — every literal {{NAME}} becomes value.
# block-map lines:  NAME<TAB>path   — a line that is exactly {{NAME}} is
#                                     replaced by the contents of path.
#
# Substitution is done by awk with literal index()/substr() replacement, never
# by `eval`, `envsubst` or sed. That matters because story cards, plan text and
# review comments are model- and human-authored: they routinely contain `&`,
# backslashes, backticks and `$(...)`, all of which must survive verbatim and
# none of which may ever be interpreted. Model-authored text only ever arrives
# through the block map, i.e. through file inclusion with no substitution at all.
ob_render_prompt() {
  local template="$1" out="$2" scalars="$3" blocks="$4"
  [[ -r "$template" ]] || ob_die "prompt template not readable: ${template}"
  awk -v scalarmap="$scalars" -v blockmap="$blocks" '
    function lrepl(s, pat, val,   i, acc) {
      acc = ""
      while ((i = index(s, pat)) > 0) {
        acc = acc substr(s, 1, i - 1) val
        s = substr(s, i + length(pat))
      }
      return acc s
    }
    BEGIN {
      while ((getline maprow < scalarmap) > 0) {
        cut = index(maprow, "\t")
        if (cut > 0) sval[substr(maprow, 1, cut - 1)] = substr(maprow, cut + 1)
      }
      close(scalarmap)
      while ((getline maprow < blockmap) > 0) {
        cut = index(maprow, "\t")
        if (cut > 0) bpath[substr(maprow, 1, cut - 1)] = substr(maprow, cut + 1)
      }
      close(blockmap)
    }
    {
      line = $0
      probe = line
      gsub(/^[ \t]+|[ \t]+$/, "", probe)
      if (probe ~ /^\{\{[A-Z0-9_]+\}\}$/) {
        key = substr(probe, 3, length(probe) - 4)
        if (key in bpath) {
          emitted = 0
          while ((getline blockline < bpath[key]) > 0) {
            print blockline
            emitted = 1
          }
          close(bpath[key])
          if (!emitted) print "_(nothing recorded)_"
          next
        }
      }
      for (key in sval) line = lrepl(line, "{{" key "}}", sval[key])
      print line
    }
  ' "$template" >"$out"
}

# ---------------------------------------------------------------------------
# omp
# ---------------------------------------------------------------------------

# ob_run_omp <workdir> <prompt-file> <ndjson-out> [model] [max-time]
# The VERIFIED headless invocation from §1. The OpenRouter key and the GitHub
# token are injected into the omp CHILD environment only — never exported into
# this shell, never written to a file. Returns omp's own exit code.
ob_run_omp() {
  local workdir="$1" prompt="$2" out="$3"
  local model="${4:-${OPENBUILDER_MODEL}}"
  local maxtime="${5:-${OPENBUILDER_MAX_RUNTIME}}"
  local key token errfile rc=0

  [[ -d "$workdir" ]] || ob_die "ob_run_omp: no such workdir: ${workdir}"
  [[ -r "$prompt" ]] || ob_die "ob_run_omp: unreadable prompt: ${prompt}"
  key="$(ob_ssm openrouter_api_key)" || return 1
  token="$(ob_gh_token)" || return 1

  mkdir -p "$(dirname -- "$out")"
  : >"$out"
  errfile="$(mktemp)"
  ob_log INFO "omp start model=${model} max-time=${maxtime} cwd=${workdir} prompt=${prompt}"
  (
    cd "$workdir" || exit 127
    exec env \
      OPENROUTER_API_KEY="$key" \
      GH_TOKEN="$token" \
      GITHUB_TOKEN="$token" \
      GH_HOST="${OPENBUILDER_GH_HOST}" \
      HOME="${OPENBUILDER_HOME}" \
      PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR}" \
      omp -p --no-pty --mode json --approval-mode yolo --auto-approve \
      --no-session --max-time "$maxtime" --model "$model" "@${prompt}"
  ) >"$out" 2>"$errfile" || rc=$?
  ob_log_file WARN "$errfile"
  rm -f "$errfile"
  ob_log INFO "omp exit=${rc} ndjson_lines=$(wc -l <"$out" | tr -d ' ')"
  return "$rc"
}

# ob_omp_final_text <ndjson> — final assistant text (extraction from §1).
ob_omp_final_text() {
  jq -rs 'map(select(.type=="agent_end"))|last|.messages|map(select(.role=="assistant"))|last
          |.content|map(select(.type=="text"))|map(.text)|join("\n")' "$1" \
    2>/dev/null || printf ''
}

# ob_omp_cost <ndjson> — total USD cost of a run (extraction from §1).
ob_omp_cost() {
  jq -s 'map(select(.type=="message_end")|.message.usage.cost.total//0)|add//0' "$1" \
    2>/dev/null || printf '0'
}

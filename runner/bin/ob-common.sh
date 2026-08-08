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
# ---------------------------------------------------------------------------

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
  if ! flock -n 9; then
    exec 9>&-
    return 1
  fi
  return 0
}

# ob_lock_held <name> — 0 when some OTHER process currently holds that lock.
ob_lock_held() {
  local name="$1" lockfile
  lockfile="$(ob_lock_path "$name")"
  [[ -e "$lockfile" ]] || return 1
  if (
    exec 8>>"$lockfile"
    flock -n 8
  ); then
    return 1
  fi
  return 0
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
    'queued|fbca04|Plan branch pushed, waiting for the box to pick it up' \
    'in-progress|1d76db|The remote agent is working on this right now' \
    'awaiting-review|0e8a16|PR is ready for the reviewer' \
    'changes-requested|d93f0b|The reviewer wants another implementation round' \
    'approved|5319e7|Approved; a human may merge and the box stops touching it' \
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
    printf -- '- box time: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

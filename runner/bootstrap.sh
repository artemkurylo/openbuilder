#!/usr/bin/env bash
# bootstrap.sh — provision (or re-provision) the openbuilder instance. IDEMPOTENT:
# re-running it on a healthy instance changes nothing.
# Single responsibility: everything that must be true on the instance before
# ob-poll can do useful work — packages, gh, Node, omp, the /opt/openbuilder
# tree, git identity and credentials, and the four systemd units.
#
# Must run as root. Called by cloud-init on first boot and by ob-selfupdate
# afterwards. Never prints a secret.
set -euo pipefail
IFS=$'\n\t'

OB_USER="openbuilder"
OB_HOME="/opt/openbuilder"
# Cloud-init owns this file; the override exists so the functions below can be
# exercised against a sandbox env file.
OB_ENV_FILE="${OPENBUILDER_ENV_FILE:-${OB_HOME}/etc/openbuilder.env}"
# Pick the omp release asset for the machine we actually booted on. The default
# instance_type is Graviton, but it is a Terraform variable — hardcoding arm64
# would silently install an unrunnable binary on an x86 instance type.
case "$(uname -m)" in
  aarch64 | arm64) OMP_ASSET="omp-linux-arm64" ;;
  x86_64 | amd64) OMP_ASSET="omp-linux-x64" ;;
  *) printf 'bootstrap: unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
OMP_REPO="can1357/oh-my-pi"
# runner/bootstrap.sh -> the control repo checkout root.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

export DEBIAN_FRONTEND=noninteractive

log() {
  local line
  line="$(printf '%s bootstrap: %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*")"
  printf '%s\n' "$line"
  if [[ -d "${OB_HOME}/log" ]]; then
    printf '%s\n' "$line" >>"${OB_HOME}/log/openbuilder.log" 2>/dev/null || true
  fi
}

die() {
  log "FATAL $*"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "must run as root"
}

# load_env — cloud-init exports these on first boot; on the ob-selfupdate path
# they only exist in the env file, so read it here too. Both extra variables are
# optional.
load_env() {
  if [[ -r "$OB_ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$OB_ENV_FILE"
    set +a
    log "loaded ${OB_ENV_FILE}"
  else
    log "WARN ${OB_ENV_FILE} is missing (cloud-init owns that file); continuing with defaults"
  fi
  OB_HOME="${OPENBUILDER_HOME:-$OB_HOME}"
}

ensure_user_and_tree() {
  if ! getent group "$OB_USER" >/dev/null; then
    groupadd --system "$OB_USER"
    log "created group ${OB_USER}"
  fi
  if ! id -u "$OB_USER" >/dev/null 2>&1; then
    useradd --system --gid "$OB_USER" --home-dir "$OB_HOME" --create-home \
      --shell /bin/bash "$OB_USER"
    log "created user ${OB_USER}"
  fi

  local dir
  for dir in bin prompts agent etc repo src work state log run cache .omp .omp/agent; do
    install -d -o "$OB_USER" -g "$OB_USER" -m 0755 "${OB_HOME}/${dir}"
  done
  install -d -o "$OB_USER" -g "$OB_USER" -m 0700 "${OB_HOME}/cache"
  # run/ holds the flock files and is written by BOTH identities: the timers run
  # as $OB_USER, ob-selfupdate is run as root. setgid + group-write means a lock
  # created by root stays usable by the service user. Existing files are
  # repaired here too — this function runs on every self-update, and a single
  # root-owned lockfile is enough to defeat the idle-stop check.
  install -d -o "$OB_USER" -g "$OB_USER" -m 2775 "${OB_HOME}/run"
  if compgen -G "${OB_HOME}/run/*.lock" >/dev/null; then
    chown "${OB_USER}:${OB_USER}" "${OB_HOME}"/run/*.lock
    chmod 0664 "${OB_HOME}"/run/*.lock
    log "normalised ownership of ${OB_HOME}/run/*.lock"
  fi
  touch "${OB_HOME}/log/openbuilder.log"
  chown "${OB_USER}:${OB_USER}" "${OB_HOME}/log/openbuilder.log"
  chmod 0644 "${OB_HOME}/log/openbuilder.log"
  chown "${OB_USER}:${OB_USER}" "$OB_HOME"
}

apt_missing() {
  local pkg
  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
      grep -q 'install ok installed'; then
      printf '%s\n' "$pkg"
    fi
  done
}

install_packages() {
  local -a base=(
    git curl jq unzip build-essential ca-certificates gnupg ripgrep fd-find
    python3 python3-venv python3-pip
  )
  local -a extra=()
  # Space- or comma-separated list from var.extra_apt_packages. Splitting via a
  # local IFS keeps it explicit instead of relying on unquoted expansion.
  if [[ -n "${OPENBUILDER_EXTRA_APT_PACKAGES:-}" ]]; then
    IFS=$' ,\t\n' read -r -a extra <<<"${OPENBUILDER_EXTRA_APT_PACKAGES}"
  fi

  local -a want=("${base[@]}" "${extra[@]+"${extra[@]}"}")
  local -a missing=()
  mapfile -t missing < <(apt_missing "${want[@]}")
  if ((${#missing[@]} == 0)); then
    log "all apt packages already installed"
  else
    log "installing apt packages: ${missing[*]}"
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi

  # omp's file tooling looks for `fd`; Debian ships the binary as `fdfind`.
  if [[ -x /usr/bin/fdfind && ! -e /usr/local/bin/fd ]]; then
    ln -s /usr/bin/fdfind /usr/local/bin/fd
    log "linked /usr/local/bin/fd -> /usr/bin/fdfind"
  fi
}

install_gh() {
  local keyring="/usr/share/keyrings/githubcli-archive-keyring.gpg"
  local list="/etc/apt/sources.list.d/github-cli.list"
  if command -v gh >/dev/null 2>&1 && [[ -f "$keyring" && -f "$list" ]]; then
    log "gh already installed: $(gh --version | awk 'NR == 1')"
    return 0
  fi
  if [[ ! -f "$keyring" ]]; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o "$keyring" || die "cannot download the gh keyring"
    chmod 0644 "$keyring"
  fi
  printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" "$keyring" >"$list"
  apt-get update -qq
  apt-get install -y --no-install-recommends gh || die "cannot install gh"
  log "installed gh: $(gh --version | awk 'NR == 1')"
}

install_node() {
  local keyring="/usr/share/keyrings/nodesource.gpg"
  local list="/etc/apt/sources.list.d/nodesource.list"
  if command -v node >/dev/null 2>&1 && [[ "$(node -v)" == v22.* ]]; then
    log "Node already installed: $(node -v)"
    return 0
  fi
  if [[ ! -f "$keyring" ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
      gpg --dearmor -o "$keyring" || die "cannot import the NodeSource key"
    chmod 0644 "$keyring"
  fi
  printf 'deb [signed-by=%s] https://deb.nodesource.com/node_22.x nodistro main\n' \
    "$keyring" >"$list"
  apt-get update -qq
  apt-get install -y --no-install-recommends nodejs || die "cannot install nodejs"
  log "installed Node: $(node -v)"
}

install_omp() {
  local version base tmp expected actual
  version="${OPENBUILDER_OMP_VERSION:-latest}"
  if [[ -z "$version" || "$version" == "latest" ]]; then
    base="https://github.com/${OMP_REPO}/releases/latest/download"
  else
    base="https://github.com/${OMP_REPO}/releases/download/${version}"
  fi

  tmp="$(mktemp -d)"
  if ! curl -fsSL "${base}/SHA256SUMS.txt" -o "${tmp}/SHA256SUMS.txt"; then
    rm -rf "$tmp"
    if [[ -x /usr/local/bin/omp ]]; then
      log "WARN cannot fetch SHA256SUMS.txt from ${base}; keeping the installed omp"
      return 0
    fi
    die "cannot fetch ${base}/SHA256SUMS.txt and no omp is installed"
  fi

  expected="$(awk -v asset="$OMP_ASSET" \
    '{ name = $2; sub(/^\*/, "", name); if (name == asset) { print $1; exit } }' \
    "${tmp}/SHA256SUMS.txt")"
  if [[ -z "$expected" ]]; then
    rm -rf "$tmp"
    die "SHA256SUMS.txt has no entry for ${OMP_ASSET}"
  fi

  if [[ -x /usr/local/bin/omp ]]; then
    actual="$(sha256sum /usr/local/bin/omp | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      log "omp already matches the target build ($(omp --version 2>/dev/null | awk 'NR == 1'))"
      rm -rf "$tmp"
      return 0
    fi
  fi

  log "downloading ${base}/${OMP_ASSET}"
  curl -fsSL "${base}/${OMP_ASSET}" -o "${tmp}/${OMP_ASSET}" || {
    rm -rf "$tmp"
    die "cannot download ${OMP_ASSET}"
  }
  actual="$(sha256sum "${tmp}/${OMP_ASSET}" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp"
    die "checksum mismatch for ${OMP_ASSET} (expected ${expected}, got ${actual})"
  fi
  install -m 0755 "${tmp}/${OMP_ASSET}" /usr/local/bin/omp
  rm -rf "$tmp"
  log "installed omp: $(/usr/local/bin/omp --version 2>/dev/null | awk 'NR == 1')"
}

# Canonical's Ubuntu images do NOT ship the AWS CLI (Amazon Linux does). Without
# it every `aws ssm get-parameter` fails, so the runner cannot read a single
# secret and ob-idle-stop cannot stop the instance — the whole system is inert.
# Installed from the official bundle because Ubuntu's `awscli` package lags and
# has historically shipped v1.
install_awscli() {
  local arch url tmp
  if command -v aws >/dev/null 2>&1; then
    log "aws already installed: $(aws --version 2>&1 | head -1)"
    return 0
  fi
  case "$(uname -m)" in
    aarch64 | arm64) arch="aarch64" ;;
    x86_64 | amd64) arch="x86_64" ;;
    *) die "unsupported architecture for the AWS CLI: $(uname -m)" ;;
  esac
  url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now, not at trap time
  trap "rm -rf '${tmp}'" RETURN
  log "downloading ${url}"
  curl -fsSL "$url" -o "${tmp}/awscliv2.zip" || die "cannot download the AWS CLI"
  unzip -q "${tmp}/awscliv2.zip" -d "$tmp" || die "cannot unpack the AWS CLI"
  "${tmp}/aws/install" --update >/dev/null || die "aws/install failed"
  command -v aws >/dev/null 2>&1 || die "aws still not on PATH after install"
  log "installed aws: $(aws --version 2>&1 | head -1)"
}

install_runner() {
  install -o "$OB_USER" -g "$OB_USER" -m 0755 \
    "${REPO_ROOT}/runner/bin/"* "${OB_HOME}/bin/"
  install -o "$OB_USER" -g "$OB_USER" -m 0644 \
    "${REPO_ROOT}/runner/prompts/"*.md "${OB_HOME}/prompts/"
  log "installed runner scripts and prompts"

  # Fallback copy only. A round reads LEARNINGS.md from the control repo's remote
  # so that publishing one takes effect immediately; this copy is what it falls
  # back to when the network or the clone is unavailable.
  if [[ -f "${REPO_ROOT}/LEARNINGS.md" ]]; then
    install -o "$OB_USER" -g "$OB_USER" -m 0644 \
      "${REPO_ROOT}/LEARNINGS.md" "${OB_HOME}/LEARNINGS.md"
    log "installed the learnings fallback copy"
  fi

  if [[ -d "${REPO_ROOT}/agent/remote" ]]; then
    cp -a "${REPO_ROOT}/agent/remote/." "${OB_HOME}/agent/"
    chown -R "${OB_USER}:${OB_USER}" "${OB_HOME}/agent"
    # omp reads its global config from $PI_CODING_AGENT_DIR/agent; symlinks keep
    # one copy of the truth in ${OB_HOME}/agent.
    if [[ -f "${OB_HOME}/agent/config.yml" ]]; then
      ln -sfn "${OB_HOME}/agent/config.yml" "${OB_HOME}/.omp/agent/config.yml"
    fi
    if [[ -d "${OB_HOME}/agent/agents" ]]; then
      ln -sfn "${OB_HOME}/agent/agents" "${OB_HOME}/.omp/agent/agents"
    fi
    chown -R "${OB_USER}:${OB_USER}" "${OB_HOME}/.omp"
    log "installed the remote omp config into ${OB_HOME}/.omp/agent"
  else
    log "WARN ${REPO_ROOT}/agent/remote is missing; omp will use its defaults"
  fi
}

configure_git() {
  local helper name email
  name="${OPENBUILDER_GIT_USER_NAME:-openbuilder-bot}"
  email="${OPENBUILDER_GIT_USER_EMAIL:-openbuilder-bot@users.noreply.github.com}"
  # A credential helper that shells out to ob-token: no token is ever stored on
  # disk or embedded in a remote URL. Single-quoted so $1 and $( ) reach git, not
  # this shell.
  helper='!f() { if test "$1" = get; then printf "username=x-access-token\npassword=%s\n" "$('"${OB_HOME}"'/bin/ob-token)"; fi; }; f'

  runuser -u "$OB_USER" -- env HOME="$OB_HOME" git config --global user.name "$name"
  runuser -u "$OB_USER" -- env HOME="$OB_HOME" git config --global user.email "$email"
  runuser -u "$OB_USER" -- env HOME="$OB_HOME" git config --global credential.helper "$helper"
  runuser -u "$OB_USER" -- env HOME="$OB_HOME" git config --global safe.directory '*'
  runuser -u "$OB_USER" -- env HOME="$OB_HOME" git config --global advice.detachedHead false

  # root needs the same identity for the ob-selfupdate path. HOME must be given
  # explicitly: cloud-init's runcmd executes with no HOME at all, and
  # `git config --global` then dies with "fatal: $HOME not set", which under
  # `set -e` aborted this script before the systemd units were installed.
  local root_home
  root_home="$(getent passwd root | cut -d: -f6)"
  [[ -n "$root_home" ]] || root_home=/root
  env HOME="$root_home" git config --global user.name "$name"
  env HOME="$root_home" git config --global user.email "$email"
  env HOME="$root_home" git config --global credential.helper "$helper"
  env HOME="$root_home" git config --global safe.directory '*'
  log "configured git identity and the ob-token credential helper"
}

install_units() {
  local unit src dst changed=0
  for unit in openbuilder-poll.service openbuilder-poll.timer \
    openbuilder-idle.service openbuilder-idle.timer; do
    src="${REPO_ROOT}/runner/systemd/${unit}"
    dst="/etc/systemd/system/${unit}"
    [[ -f "$src" ]] || die "missing systemd unit ${src}"
    if ! cmp -s "$src" "$dst"; then
      install -m 0644 "$src" "$dst"
      changed=1
      log "installed ${dst}"
    fi
  done
  if ((changed)); then
    systemctl daemon-reload
  fi
  systemctl enable --now openbuilder-poll.timer openbuilder-idle.timer
  log "timers: $(systemctl is-active openbuilder-poll.timer) / $(systemctl is-active openbuilder-idle.timer)"
}

main() {
  require_root
  load_env
  log "bootstrapping from ${REPO_ROOT}"
  ensure_user_and_tree
  install_packages
  install_gh
  install_node
  install_omp
  install_awscli
  install_runner
  configure_git
  install_units
  log "bootstrap complete"
}

# Executed normally; sourcing the file instead exposes the functions above
# without provisioning anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

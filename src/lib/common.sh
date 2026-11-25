# shellcheck shell=bash
# ============================================================================
# sdm-proxy-cluster-kit :: src/lib/common.sh
# Shared contract for every mode. Modes MUST use these helpers rather than
# re-implementing them. Bash 4.2+ (RHEL 7 / Amazon Linux 2) - no namerefs,
# no ${var@Q}, no `wait -n`. No TAB characters anywhere (paste safety).
#
# ============================================================================

set +x
export -n SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY DELINEA_USERNAME DELINEA_PASSWORD \
  KIT_DELINEA_SVC_USERNAME KIT_DELINEA_SVC_PASSWORD KIT_DELINEA_USERNAME_PATH KIT_DELINEA_PASSWORD_PATH 2>/dev/null || true

# ---------------------------------------------------------------- constants
KIT_NAME="sdm-proxy-cluster-kit"
KIT_VERSION="${KIT_VERSION:-0.1.2}"
SDM_USER="sdm"
SDM_USER_HOME="/home/sdm"
SDM_HOME_DIR="/home/sdm/.sdm"
SDM_PREFIX="/opt/strongdm"
SDM_BIN="/opt/strongdm/bin/sdm"
SDM_UNIT="sdm-worker"
SDM_SYSCONFIG="/etc/sysconfig/sdm-worker"
SDM_SIDECAR="/home/sdm/.sdm/secretenv.enc"
SDM_DEFAULT_BIND=":8443"
KIT_DIR="/opt/sdm-proxy-cluster-kit"
KIT_LOG_DIR="/var/log/sdm-proxy-cluster-kit"
KIT_BACKUP_DIR="/var/backups/sdm-proxy-cluster-kit"
KIT_APP_DOMAINS=("app.strongdm.com" "app.eu.strongdm.com" "app.uk.strongdm.com")
KIT_FOREIGN_UNITS=("sdm-worker" "sdm-relay" "sdm-gateway" "sdm-proxy")

# Exit codes (documented in README; modes must use these).
KIT_EXIT_OK=0
KIT_EXIT_FAIL=1        # a check failed / operation failed
KIT_EXIT_USAGE=2       # bad input, missing env var in non-interactive mode
KIT_EXIT_PRECOND=3     # not root, no systemd, unsupported OS, container
KIT_EXIT_ABORTED=4     # operator declined a confirmation

# ---------------------------------------------------------------- colors
# Muted "Slate Dark" accents, low glare for screen shares. Truecolor when the
# terminal says so, basic ANSI otherwise, none when NO_COLOR or not a TTY.
kit_init_colors() {
  C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_HEAD=""; C_ACC=""; C_RST=""
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then return 0; fi
  if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
    C_OK=$'\e[38;2;124;201;142m'; C_WARN=$'\e[38;2;229;145;118m'; C_FAIL=$'\e[38;2;224;128;143m'
    C_INFO=$'\e[38;2;124;172;239m'; C_DIM=$'\e[38;2;167;176;188m'; C_HEAD=$'\e[38;2;227;231;236m\e[1m'
    C_ACC=$'\e[38;2;91;200;180m'
  else
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_INFO=$'\e[36m'; C_DIM=$'\e[2m'; C_HEAD=$'\e[1m'; C_ACC=$'\e[36m'
  fi
  C_RST=$'\e[0m'
}
kit_init_colors

# ---------------------------------------------------------------- output
KIT_PASS=0; KIT_WARN=0; KIT_FAIL=0
ok()   { KIT_PASS=$((KIT_PASS+1)); printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { KIT_WARN=$((KIT_WARN+1)); printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail() { KIT_FAIL=$((KIT_FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_RST" "$*"; }
info() { printf '  %s[INFO]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }   # indented detail under the line above
kit_have() { command -v "$1" >/dev/null 2>&1; }

kit_banner() { # kit_banner "Mode title"
  printf '\n%s+----------------------------------------------------------------------+%s\n' "$C_ACC" "$C_RST"
  printf '%s|%s %s%-68s%s %s|%s\n' "$C_ACC" "$C_RST" "$C_HEAD" "StrongDM Proxy Cluster Kit v$KIT_VERSION" "$C_RST" "$C_ACC" "$C_RST"
  printf '%s|%s %-68s %s|%s\n' "$C_ACC" "$C_RST" "${1:-}" "$C_ACC" "$C_RST"
  printf '%s|%s %-68s %s|%s\n' "$C_ACC" "$C_RST" "host $(kit_hostname)  $(date '+%F %T %Z')" "$C_ACC" "$C_RST"
  printf '%s+----------------------------------------------------------------------+%s\n' "$C_ACC" "$C_RST"
}
kit_step() { # kit_step N TOTAL "title"   -> big, numbered, easy to follow on a screen share
  printf '\n%s== STEP %s/%s  %s%s\n' "$C_HEAD" "$1" "$2" "$3" "$C_RST"
}
kit_section() { printf '\n%s== %s%s\n' "$C_HEAD" "$*" "$C_RST"; }

# kit_die CODE "WHAT failed" "WHY it matters / what we saw" "FIX: exact command(s), one per line"
# Prints a boxed, screen-share-readable error and exits. Never put secrets in it.
kit_die() {
  local code=$1 what=$2 why=${3:-} fix=${4:-}
  printf '\n%s+---- ERROR -----------------------------------------------------------+%s\n' "$C_FAIL" "$C_RST"
  printf '%s|%s WHAT: %s\n' "$C_FAIL" "$C_RST" "$what"
  if [ -n "$why" ]; then while IFS= read -r l; do printf '%s|%s WHY:  %s\n' "$C_FAIL" "$C_RST" "$l"; done <<<"$why"; fi
  if [ -n "$fix" ]; then while IFS= read -r l; do printf '%s|%s FIX:  %s\n' "$C_FAIL" "$C_RST" "$l"; done <<<"$fix"; fi
  printf '%s|%s LOG:  %s\n' "$C_FAIL" "$C_RST" "${KIT_LOG_FILE:-(not logging)}"
  printf '%s+----------------------------------------------------------------------+%s\n' "$C_FAIL" "$C_RST"
  exit "$code"
}

kit_summary() { # prints PASS/WARN/FAIL totals; returns 1 when any FAIL
  printf '\n%s== Summary%s\n  %s%d ok%s   %s%d warning(s)%s   %s%d failure(s)%s\n' \
    "$C_HEAD" "$C_RST" "$C_OK" "$KIT_PASS" "$C_RST" "$C_WARN" "$KIT_WARN" "$C_RST" "$C_FAIL" "$KIT_FAIL" "$C_RST"
  [ -n "${KIT_LOG_FILE:-}" ] && printf '  full transcript: %s\n' "$KIT_LOG_FILE"
  [ "$KIT_FAIL" -eq 0 ]
}

# ---------------------------------------------------------------- logging
# kit_log_init MODE : tee everything to $KIT_LOG_DIR/<mode>-<ts>.log (0600).
# Review operational transcripts locally before sharing.
kit_log_init() {
  [ "$(id -u)" = 0 ] || return 0
  if ! kit_private_dir "$KIT_LOG_DIR"; then
    kit_private_dir "$KIT_DIR" || kit_die 3 "Unsafe administrative directory." "" "Review $KIT_DIR."
    KIT_LOG_DIR="$KIT_DIR/logs"
    kit_private_dir "$KIT_LOG_DIR" || kit_die 3 "Unsafe transcript directory." "" "Review $KIT_LOG_DIR."
  fi
  KIT_LOG_FILE=$(mktemp "$KIT_LOG_DIR/$1-$(date +%Y%m%d-%H%M%S).XXXXXX.log") ||
    kit_die 3 "Cannot open a private transcript." "" "Check permissions and free space in $KIT_LOG_DIR."
  # tee -i + ignored INT: Ctrl-C must not kill the logger, or the next write
  # SIGPIPEs the script before its EXIT handlers (reverts, scrub) can run.
  exec > >(trap '' INT HUP; exec tee -i -a "$KIT_LOG_FILE") 2>&1
}

# ---------------------------------------------------------------- exit traps
# Stack of cleanup commands run on EXIT (LIFO). Secrets are always scrubbed.
KIT_ON_EXIT=()
kit_on_exit() { KIT_ON_EXIT+=("$1"); }
KIT_SECRET_VARS=()
kit_secret_register() { KIT_SECRET_VARS+=("$@"); }      # names of vars holding secrets
kit_scrub() {
  local v
  for v in "${KIT_SECRET_VARS[@]:-}"; do
    [ -n "$v" ] || continue
    printf -v "$v" '%s' ''; unset "$v"
  done
  return 0
}
kit_run_exit_handlers() {
  local rc=$? i
  for ((i=${#KIT_ON_EXIT[@]}-1; i>=0; i--)); do eval "${KIT_ON_EXIT[i]}" || true; done
  kit_scrub
  return $rc
}
trap kit_run_exit_handlers EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP   # SSH / SSM disconnect: still run the EXIT handlers

# ---------------------------------------------------------------- prompts
# Interactive = a usable /dev/tty. Every prompt reads from /dev/tty so the
# script works when its own source arrived on stdin (curl | bash, bash -s).
kit_tty_ok() { { : </dev/tty; } 2>/dev/null; }
kit_noninteractive() { ! kit_tty_ok || [ "${KIT_NONINTERACTIVE:-}" = 1 ]; }

# kit_ask VAR "Prompt" [default]  - visible input. If $VAR already set (env), uses it.
kit_ask() {
  local __v=$1 __p=$2 __d=${3:-} __in
  if [ -n "${!__v:-}" ]; then info "$__p: using \$$__v from the environment"; return 0; fi
  if kit_noninteractive; then
    [ -n "$__d" ] && { printf -v "$__v" '%s' "$__d"; return 0; }
    kit_die $KIT_EXIT_USAGE "Missing required value: $__v" "Running non-interactively, so nothing can be prompted for." "export $__v='...' and re-run"
  fi
  printf '  %s?%s %s%s: ' "$C_ACC" "$C_RST" "$__p" "${__d:+ [$__d]}" >/dev/tty
  IFS= read -r __in </dev/tty || __in=""
  [ -z "$__in" ] && __in=$__d
  printf -v "$__v" '%s' "$__in"
}

# kit_ask_secret VAR "Prompt"  - hidden, entered twice, never echoed, registered for scrub.
kit_ask_secret() {
  local __v=$1 __p=$2 __a __b __try
  kit_secret_register "$__v"
  if [ -n "${!__v:-}" ]; then info "$__p: using \$$__v from the environment (value not shown)"; return 0; fi
  kit_noninteractive && kit_die $KIT_EXIT_USAGE "Missing required secret: $__v" "Running non-interactively, so nothing can be prompted for." "export $__v='...' (e.g. from your secrets manager) and re-run"
  for __try in 1 2 3; do
    printf '  %s?%s %s (hidden): ' "$C_ACC" "$C_RST" "$__p" >/dev/tty; IFS= read -rs __a </dev/tty; printf '\n' >/dev/tty
    printf '  %s?%s confirm %s: ' "$C_ACC" "$C_RST" "$__p" >/dev/tty;      IFS= read -rs __b </dev/tty; printf '\n' >/dev/tty
    if [ -z "$__a" ]; then warn "empty value, try again"; continue; fi
    if [ "$__a" != "$__b" ]; then warn "the two entries did not match, try again"; continue; fi
    printf -v "$__v" '%s' "$__a"; __a=""; __b=""; return 0
  done
  __a=""; __b=""
  kit_die $KIT_EXIT_USAGE "Could not read $__v" "Three attempts were empty or did not match." "Re-run the kit and type the value carefully (paste works)."
}

# kit_confirm "Question" [default y|n] -> 0 yes / 1 no. Non-interactive: honours KIT_ASSUME_YES=1.
kit_confirm() {
  local q=$1 d=${2:-n} a
  if kit_noninteractive; then [ "${KIT_ASSUME_YES:-}" = 1 ]; return; fi
  printf '  %s?%s %s %s: ' "$C_ACC" "$C_RST" "$q" "$([ "$d" = y ] && echo '[Y/n]' || echo '[y/N]')" >/dev/tty
  IFS= read -r a </dev/tty || a=""; a=${a:-$d}
  case $a in y|Y|yes|YES|Yes) return 0;; *) return 1;; esac
}

# kit_confirm_typed WORD "Explanation"  -> operator must type WORD exactly. Non-interactive: KIT_REPLACE=yes.
kit_confirm_typed() {
  local w=$1 msg=$2 a
  if kit_noninteractive; then [ "${KIT_REPLACE:-}" = yes ]; return; fi
  printf '  %s?%s %s\n    Type %s%s%s to continue, anything else aborts: ' "$C_ACC" "$C_RST" "$msg" "$C_HEAD" "$w" "$C_RST" >/dev/tty
  IFS= read -r a </dev/tty || a=""
  [ "$a" = "$w" ]
}

# kit_pick VAR "Title" "opt1" "opt2" ... -> VAR = chosen option text (1-based numbered menu).
kit_pick() {
  local __v=$1 __t=$2; shift 2
  local __i __a
  if [ -n "${!__v:-}" ]; then return 0; fi
  kit_noninteractive && kit_die $KIT_EXIT_USAGE "Missing choice: $__v" "Non-interactive run." "export $__v=<one of: $*>"
  while :; do
    printf '\n  %s%s%s\n' "$C_HEAD" "$__t" "$C_RST" >/dev/tty
    __i=1; for __a in "$@"; do printf '    %s%d)%s %s\n' "$C_ACC" "$__i" "$C_RST" "$__a" >/dev/tty; __i=$((__i+1)); done
    printf '  %s?%s choose 1-%d: ' "$C_ACC" "$C_RST" "$#" >/dev/tty; IFS= read -r __a </dev/tty || __a=""
    if [[ $__a =~ ^[0-9]+$ ]] && [ "$__a" -ge 1 ] && [ "$__a" -le $# ]; then printf -v "$__v" '%s' "${!__a}"; return 0; fi
    warn "'$__a' is not a choice"
  done
}

# ---------------------------------------------------------------- platform
kit_hostname() { hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown; }
kit_is_root() { [ "$(id -u)" = 0 ]; }
kit_require_root() {
  kit_is_root || kit_die $KIT_EXIT_PRECOND "This needs root." "It manages users, services and /etc/sysconfig." \
    "sudo -i            # become root, then re-run
bash $KIT_DIR/$KIT_NAME.sh"
}
kit_in_container() {
  [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qaE '(docker|kubepods|containerd|libpod)' /proc/1/cgroup 2>/dev/null \
    || [ "${container:-}" != "" ] || { kit_have systemd-detect-virt && systemd-detect-virt --container >/dev/null 2>&1; }
}
kit_has_systemd() { [ -d /run/systemd/system ] && kit_have systemctl; }
# Sets OS_ID OS_VERSION_ID OS_PRETTY OS_FAMILY(rhel|debian|unknown) PKG_MGR(dnf|yum|apt|"")
kit_detect_os() {
  OS_ID=unknown; OS_VERSION_ID=""; OS_PRETTY="unknown"; OS_FAMILY=unknown; PKG_MGR=""
  if [ -r /etc/os-release ]; then
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_VERSION_ID=$(. /etc/os-release; echo "${VERSION_ID:-}")
    OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")
    case " $(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}") " in
      *" rhel "*|*" fedora "*|*" centos "*|*" amzn "*) OS_FAMILY=rhel;;
      *" debian "*|*" ubuntu "*) OS_FAMILY=debian;;
    esac
  fi
  if kit_have dnf; then PKG_MGR=dnf; elif kit_have yum; then PKG_MGR=yum; elif kit_have apt-get; then PKG_MGR=apt; fi
}
# kit_arch -> amd64 | arm64 (exits on anything else)
kit_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;;
    *) kit_die $KIT_EXIT_PRECOND "Unsupported CPU architecture: $(uname -m)" "StrongDM publishes Linux builds for amd64 and arm64 only." "";;
  esac
}
kit_selinux_mode() { if kit_have getenforce; then getenforce 2>/dev/null; else echo Disabled; fi; }

# kit_ensure_cmds cmd... : installs missing tools via the package manager (says what and why).
kit_ensure_cmds() {
  local missing=() c pkgs=()
  for c in "$@"; do kit_have "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  for c in "${missing[@]}"; do
    case $c in sha256sum|base64|stat|timeout) pkgs+=(coreutils);; getent) pkgs+=(glibc-common);; ss) pkgs+=(iproute2);; *) pkgs+=("$c");; esac
  done
  [ -n "${PKG_MGR:-}" ] || kit_detect_os
  info "installing missing tool(s): ${missing[*]} (package: ${pkgs[*]})"
  case $PKG_MGR in
    dnf) dnf install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
    yum) yum install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
    apt) { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"; } >/dev/null 2>&1 ;;
    *) false ;;
  esac || true
  for c in "${missing[@]}"; do
    kit_have "$c" || kit_die $KIT_EXIT_PRECOND "Required tool '$c' is missing and could not be installed." \
      "Package manager: ${PKG_MGR:-none found}. The host may have no repo access." \
      "Install it yourself, then re-run:
dnf install -y ${pkgs[*]}      # RHEL / Rocky / Alma / Amazon Linux
apt-get install -y ${pkgs[*]}  # Ubuntu / Debian"
  done
  ok "installed: ${missing[*]}"
}

# ---------------------------------------------------------------- node inspection
# kit_find_node_procs -> lines "pid|user|role|exe|cwd|start_epoch" for running sdm worker/relay/gateway/proxy.
kit_find_node_procs() {
  local d exe cwd cmd role pid uid user clk now upt st
  clk=$(getconf CLK_TCK 2>/dev/null || echo 100); now=$(date +%s); upt=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
  for d in /proc/[0-9]*; do
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    # /proc/PID/exe is unreadable for other users' processes in containers without
    # CAP_SYS_PTRACE; fall back to argv[0] so the worker is still found.
    exe=$(readlink "$d/exe" 2>/dev/null) || exe=${cmd%% *}
    case ${exe##*/} in sdm*) ;; *) continue;; esac
    role=$(printf '%s' "$cmd" | grep -oE ' (worker|relay|gateway|proxy)( |$)' | head -1 | tr -d ' ')
    [ -n "$role" ] || continue
    pid=${d#/proc/}
    uid=$(awk '/^Uid:/{print $2}' "$d/status" 2>/dev/null)
    user=$(awk -F: -v u="$uid" '$3==u{print $1; exit}' /etc/passwd); user=${user:-$uid}
    st=$(awk -v clk="$clk" -v up="$upt" -v now="$now" '{sub(/.*\) /,""); print int(now-up+$20/clk)}' "$d/stat" 2>/dev/null)
    cwd=$(readlink "$d/cwd" 2>/dev/null)
    [[ $exe$cwd != *'|'* && $exe$cwd != *[[:cntrl:]]* ]] || continue
    printf '%s|%s|%s|%s|%s|%s\n' "$pid" "$user" "$role" "$exe" "$cwd" "$st"
  done
}
# kit_proc_env PID KEY -> prints value, returns 1 if unset/unreadable. Never echo secret keys' values to the screen.
kit_proc_env() {
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | awk -v k="$2" 'index($0,k"=")==1{print substr($0,length(k)+2); f=1; exit} END{exit !f}'
}
# Detach worker programs from the operator's controlling terminal. Keep the
# wrapper waiting even with older setsid versions that lack --wait.
kit_run_unprivileged() (
  local user=$1 uid
  shift
  uid=$(id -u "$user") && [ "$uid" -gt 0 ] || exit 1
  local switch=()
  if kit_is_root; then switch=(runuser -u "$user" --)
  elif [ "$(id -u)" != "$uid" ]; then exit 1; fi
  set +m
  cd / || exit 1
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid ${switch[@]+"${switch[@]}"} "$@" 9>&-
  exit "$?"
)
kit_as_worker() {
  local d=$1
  shift
  kit_run_unprivileged "$SDM_USER" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$SDM_USER_HOME" SDM_HOME="$d" SDM_LOG_OUTPUT=stderr "$@"
}

kit_trusted_dir() {
  local d=$1 mode
  [[ $d == /* ]] || return 1
  while :; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -c %u "$d")" = 0 ] || return 1
    mode=$(stat -c %a "$d") || return 1
    (( (8#$mode & 022) == 0 )) || return 1
    [ "$d" = / ] && return 0
    d=$(dirname -- "$d") || return 1
  done
}
kit_private_dir() {
  local dir=$1
  kit_trusted_dir "$(dirname -- "$dir")" && [ ! -L "$dir" ] || return 1
  if [ ! -d "$dir" ]; then (umask 077; mkdir "$dir") || return 1; fi
  [ "$(stat -c '%u:%a' "$dir")" = 0:700 ]
}

kit_trusted_file() {
  local f=$1 mode
  [ ! -L "$f" ] && [ -f "$f" ] && kit_trusted_dir "$(dirname -- "$f")" && [ "$(stat -c %u -- "$f")" = 0 ] || return 1
  mode=$(stat -c %a -- "$f") && (( (8#$mode & 022) == 0 ))
}

kit_lock_changes() {
  kit_have flock || kit_die 3 "Install and debug require flock." "" "Install util-linux."
  kit_private_dir "$KIT_DIR" || kit_die 3 "Unsafe administrative directory." "" "Review $KIT_DIR."
  exec 9>"$KIT_DIR/install.lock" && flock -n 9 || kit_die 1 "Another install or debug session holds the kit lock." "" "Retry after that session finishes."
}

kit_https_url() {
  local pattern='^https://[a-zA-Z0-9.-]+(:[0-9]+)?(/[a-zA-Z0-9._~/%+=-]*)?$'
  [[ $1 =~ $pattern ]]
}

kit_unit_exists() { kit_has_systemd && systemctl cat "$1" >/dev/null 2>&1 </dev/null; }
# systemd 219 (RHEL 7 / Amazon Linux 2) has no `systemctl show --value`; strip "Name=" ourselves.
kit_unit_prop() { systemctl show -p "$2" "$1" 2>/dev/null </dev/null | sed 's/^[^=]*=//'; }   # kit_unit_prop UNIT User|MainPID|ActiveState|WorkingDirectory|ExecStart|EnvironmentFiles
kit_unit_main_pid() { local p; p=$(kit_unit_prop "$1" MainPID); [ -n "$p" ] && [ "$p" != 0 ] && echo "$p"; }

# Read and edit whole systemd EnvironmentFile assignments. A quoted or
# backslash-continued value can contain physical lines that look like new keys.
kit_envfile_records() { # get|has|omit|names, optional space-separated keys; reads stdin
  local op=$1 keys=" ${2:-} " line key record rest state slashes last=""
  local assignment='^[[:blank:]]*(export[[:blank:]]+)?([a-zA-Z_][a-zA-Z0-9_]*)[[:blank:]]*=(.*)$'
  while IFS= read -r line || [ -n "$line" ]; do
    record=$line; key=""
    if [[ $line =~ $assignment ]]; then
      key=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}; state=start
    elif [[ $line =~ ^[[:blank:]]*[\#\;] ]]; then
      rest=$line; state=bare
    else
      rest=""; state=bare
    fi
    while :; do
      case $state in
        start)
          rest=${rest#"${rest%%[!$' \t\r']*}"}
          case $rest in
            \'*) state=single; rest=${rest:1}; continue;;
            \"*) state=double; rest=${rest:1}; continue;;
            *) state=bare; continue;;
          esac;;
        single)
          if [[ $rest == *\'* ]]; then rest=${rest#*\'}; state=start; continue; fi;;
        double)
          rest=${rest#"${rest%%[\\\"]*}"}
          case $rest in
            \"*) rest=${rest:1}; state=start; continue;;
            \\?*) rest=${rest:2}; continue;;
          esac;;
        bare)
          slashes=${rest##*[!\\]}
          (( ${#slashes} % 2 )) || break;;
      esac
      # Fail safely on an unfinished record rather than append settings to it.
      rest=""; IFS= read -r rest || [ -n "$rest" ] || return 2
      record+=$'\n'"$rest"
    done
    if [ "$op" = names ]; then
      [ -z "$key" ] || printf '%s ' "$key"
    elif [ -n "$key" ] && [[ $keys == *" $key "* ]]; then
      case $op in has) return 0;; get) last=${record#*=};; esac
    elif [ "$op" = omit ]; then printf '%s\n' "$record" || return 2; fi
  done
  case $op in get) [ -n "$last" ] && printf '%s\n' "$last";; has) return 1;; omit|names) return 0;; esac
}
kit_envfile_get() { [ -r "$1" ] && kit_envfile_records get "$2" < "$1"; }
kit_envfile_has() { [ -r "$1" ] && kit_envfile_records has "$2" < "$1"; }

# Replace a set of keys as one root-private file. New assignment lines arrive
# on stdin, so values never become external command arguments.
kit_envfile_update() { # FILE "keys to remove" < replacement lines
  local f=$1 keys=$2 tmp
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  if { [ ! -e "$f" ] || kit_envfile_records omit "$keys" < "$f"; } > "$tmp" &&
     cat >> "$tmp" && chmod 0600 "$tmp" && mv -fT "$tmp" "$f"; then return 0; fi
  rm -f -- "$tmp"; return 1
}
kit_envfile_set() {
  [[ $3 != *$'\n'* && $3 != *$'\r'* ]] || return 1
  kit_envfile_update "$1" "$2" <<<"$2=$3"
}
kit_envfile_unset() {
  local rc=0
  kit_envfile_has "$1" "$2" || rc=$?
  [ "$rc" = 1 ] && return 0
  [ "$rc" = 0 ] || return "$rc"
  kit_envfile_update "$1" "$2" </dev/null
}

# ---------------------------------------------------------------- network
kit_tcp_ok() { # host port
  if kit_have timeout; then timeout 6 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null
  else (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; fi
}
# kit_http METHOD URL [form-body] [bearer] -> sets HB (body) HC (http code) HE (curl exit).
# Sensitive bodies and headers use stdin. Never follow redirects with credentials.
kit_http() {
  local method=$1 url=$2 body=${3:-} token=${4:-} cfg="" out
  local args=(-q --silent --show-error --globoff --max-time 60 --proto '=https' --request "$method" --write-out $'\n__HTTP__%{http_code}')
  HB=""; HC=000; HE=1
  [[ $url == https://* && $url != *[[:cntrl:]]* ]] || return 0
  if [ -n "$body" ]; then
    local form_pattern='^[a-zA-Z0-9%_=&.+~-]+$'
    [[ $body =~ $form_pattern ]] || return 0
    cfg+="data = \"$body\""$'\n'
  fi
  if [ -n "$token" ]; then
    [[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || return 0
    cfg+="header = \"Authorization: Bearer $token\""$'\n'
  fi
  out=$(printf '%s' "$cfg" | curl "${args[@]}" -K - --url "$url" 2>/dev/null); HE=$?
  HC=${out##*__HTTP__}; HB=${out%$'\n'__HTTP__*}; [[ $HC =~ ^[0-9]{3}$ ]] || HC=000
  return 0
}

# ---------------------------------------------------------------- JSON (no jq)
# json_flat < json  -> "path<TAB>type<TAB>escaped-value" (type s|l). Decode a value with printf '%b'.
json_flat() { LC_ALL=C awk '
function ws(){ while (i<=n && index(" \t\r\n", substr(s,i,1))) i++ }
function hex(h,  k,v){ v=0; h=tolower(h); for(k=1;k<=4;k++) v=v*16+index("0123456789abcdef",substr(h,k,1))-1; return v }
function utf8(c){ if(c<128) return sprintf("%c",c)
  if(c<2048) return sprintf("%c%c",192+int(c/64),128+c%64)
  if(c<65536) return sprintf("%c%c%c",224+int(c/4096),128+int(c/64)%64,128+c%64)
  return sprintf("%c%c%c%c",240+int(c/262144),128+int(c/4096)%64,128+int(c/64)%64,128+c%64) }
function str(  o,c,e,u,u2){ o=""; i++
  while(i<=n){ c=substr(s,i,1)
    if(c=="\"") { i++; return o }
    if(c=="\\"){ e=substr(s,i+1,1); i+=2
      if(e=="n") o=o "\n"; else if(e=="t") o=o "\t"; else if(e=="r") o=o "\r"
      else if(e=="b") o=o "\b"; else if(e=="f") o=o "\f"
      else if(e=="u"){ u=hex(substr(s,i,4)); i+=4
        if(u>=55296 && u<56320 && substr(s,i,2)=="\\u"){ u2=hex(substr(s,i+2,4)); i+=6; u=65536+(u-55296)*1024+(u2-56320) }
        o=o utf8(u) }
      else o=o e
      continue }
    o=o c; i++ }
  return o }
function esc(v,  o,k,c){ o=""; for(k=1;k<=length(v);k++){ c=substr(v,k,1)
    if(c=="\\") o=o "\\\\"; else if(c=="\t") o=o "\\t"; else if(c=="\n") o=o "\\n"; else if(c=="\r") o=o "\\r"
    else if(c<" ") o=o sprintf("\\x%02x", index(ctl,c)); else o=o c }
  return o }
function val(p,  k,c,lit){ ws(); c=substr(s,i,1)
  if(c=="{"){ i++; ws(); if(substr(s,i,1)=="}"){i++;return}
    while(1){ ws(); k=str(); ws(); i++; val(p (p==""?"":".") k); ws(); c=substr(s,i,1); i++; if(c!=",") return } }
  if(c=="["){ i++; ws(); if(substr(s,i,1)=="]"){i++;return}; k=0
    while(1){ val(p "." k); k++; ws(); c=substr(s,i,1); i++; if(c!=",") return } }
  if(c=="\""){ print p "\ts\t" esc(str()); return }
  lit=""; while(i<=n && !index(",]} \t\r\n", substr(s,i,1))){ lit=lit substr(s,i,1); i++ }
  print p "\tl\t" lit }
BEGIN{ for(k=1;k<32;k++) ctl=ctl sprintf("%c",k) }
{ s=s $0 "\n" }
END{ n=length(s); i=1; val("") }'; }
# jget "<flat>" path -> decoded value (path match is case-insensitive, like Go's encoding/json).
jget() { local line; line=$(printf '%s\n' "$1" | awk -F'\t' -v p="$2" 'tolower($1)==tolower(p){print $3; exit}'); printf '%b' "$line"; }

# ---------------------------------------------------------------- value helpers (never reveal secrets)
kit_shape() { local v=$1 c=""
  [[ $v == *[a-z]* ]] && c+="lower+"; [[ $v == *[A-Z]* ]] && c+="upper+"
  [[ $v == *[0-9]* ]] && c+="digit+"; [[ $v == *[^A-Za-z0-9]* ]] && c+="symbol+"
  printf 'len=%d bytes, classes=%s' "${#v}" "${c%+}"; }
kit_anomalies() { local v=$1 out=() t LC_ALL=C
  [[ $v =~ ^[[:space:]] || $v =~ [[:space:]]$ ]] && out+=("leading/trailing whitespace")
  [[ $v == *$'\r'* || $v == *$'\n'* ]] && out+=("contains CR/LF")
  [[ $v == *$'\t'* ]] && out+=("contains TAB")
  [[ $v =~ \&(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+)\; ]] && out+=("contains an HTML entity such as &amp;")
  [[ $v =~ %[0-9A-Fa-f]{2} ]] && out+=("contains %XX (maybe URL-encoded)")
  [[ $v =~ [$'\x80'-$'\xff'] ]] && out+=("contains non-ASCII bytes (accents, NBSP, zero-width, smart quotes)")
  t=${v//[$'\r\n\t']/}; [[ $t =~ [[:cntrl:]] ]] && out+=("contains control characters")
  local IFS=';'; printf '%s' "${out[*]:-}"; }
kit_trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
kit_html_unescape() { local v=$1; v=${v//&lt;/<}; v=${v//&gt;/>}; v=${v//&quot;/\"}; v=${v//&#39;/\'}; v=${v//&apos;/\'}; v=${v//&amp;/&}; printf '%s' "$v"; }
kit_urlencode() { local LC_ALL=C s=$1 i c o=""; for ((i=0;i<${#s};i++)); do c=${s:i:1}
  case $c in [a-zA-Z0-9.~_-]) o+=$c;; *) printf -v c '%%%02X' "'$c"; o+=$c;; esac; done; printf '%s' "$o"; }

# patsub_replacement (bash 5.2) would turn '&' in ${v//x/&} into the match. Off.
shopt -u patsub_replacement 2>/dev/null || true

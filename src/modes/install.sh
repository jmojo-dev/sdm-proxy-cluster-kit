# shellcheck shell=bash
# ============================================================================
# sdm-proxy-cluster-kit :: src/modes/install.sh   (defines mode_install)
#
# Installs or repairs a StrongDM proxy cluster worker running as user `sdm`
# with SDM_HOME=/home/sdm/.sdm. Every input (including secrets) is collected
# before anything on the host changes. Private helpers are prefixed inst_.
#
# Environment variables read by this mode:
# @env SDM_APP_DOMAIN  Control plane region: app.strongdm.com, app.eu.strongdm.com or app.uk.strongdm.com (skips the region menu)
# @env SDM_PROXY_CLUSTER_ACCESS_KEY  Proxy cluster access key (skips the prompt)
# @env SDM_PROXY_CLUSTER_SECRET_KEY  Proxy cluster secret key (skips the hidden prompt; never printed)
# @env KIT_DELINEA  yes|no - will this cluster use Delinea Secret Server (default when unset and non-interactive: yes if DELINEA_USERNAME is set)
# @env KIT_ROTATE_DELINEA  yes = replace an existing sealed Delinea username and password. Ordinary repairs keep the existing pair.
# @env DELINEA_USERNAME  Delinea Secret Server username, sealed into the node secret store
# @env DELINEA_PASSWORD  Delinea Secret Server password, sealed into the node secret store (never printed)
# @env DELINEA_SERVER_URL  Optional Delinea server URL written to /etc/sysconfig/sdm-worker (blank = configured on the secret store in the Admin UI)
# @env SDM_BIND_ADDRESS  Worker listen address (default :8443; never prompted)
# @env KIT_ASSUME_YES  1 = accept the install summary and other yes/no confirmations when non-interactive
# @env KIT_BACKUP_CERT  Path to a root-protected PEM encryption certificate for foreign-install backups; keep the private key offline
# @env KIT_REPLACE  yes = allow replacing a foreign StrongDM install when non-interactive (instead of typing REPLACE)
# @env KIT_FORCE_REINSTALL  yes = reprovision the CLI, sealed keys and unit on an existing worker
# @env KIT_START_TIMEOUT  Seconds to wait for the worker to come up (default 90)
# ============================================================================

INST_TOTAL=13
INST_STATE_FILE="$KIT_DIR/install.state"       # root 0600: key fingerprint, domain, bind
INST_PENDING_FILE="$KIT_DIR/activation.pending" # root 0600: interrupted provisioning or activation
INST_REPLACED_LIST="$KIT_DIR/replaced.list"    # foreign items already backed up + stopped

# ---------------------------------------------------------------- small helpers
inst_abort() { printf '\n'; info "Aborted by the operator. Nothing further was changed."; exit "$KIT_EXIT_ABORTED"; }


inst_nologin() { local p; for p in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin; do [ -x "$p" ] && { echo "$p"; return; }; done; echo /bin/false; }

inst_user_home() { getent passwd "$1" 2>/dev/null | awk -F: '{print $6; exit}'; }

inst_strip_quotes() { local v=$1; v=${v#[\"\']}; v=${v%[\"\']}; printf '%s' "$v"; }

inst_bind_port() { local b=${1:-$SDM_DEFAULT_BIND}; printf '%s' "${b##*:}"; }

# Fingerprint of the key pair (salted sha256), so a re-run can tell whether the
# keys changed without storing them. printf is a builtin: nothing on argv.
inst_key_fp() { printf 'sdm-proxy-cluster-kit:v1\n%s\n%s' "$SDM_PROXY_CLUSTER_ACCESS_KEY" "$SDM_PROXY_CLUSTER_SECRET_KEY" | sha256sum | awk '{print $1}'; }

inst_state_get() { kit_envfile_get "$INST_STATE_FILE" "$1" 2>/dev/null; }
inst_state_set() {
  kit_private_dir "$KIT_DIR" || return 1
  kit_envfile_set "$INST_STATE_FILE" "$1" "$2"
}

inst_read_pending() {
  INST_PENDING=""
  [ -e "$INST_PENDING_FILE" ] || [ -L "$INST_PENDING_FILE" ] || return 0
  kit_trusted_file "$INST_PENDING_FILE" && [ "$(stat -c %a "$INST_PENDING_FILE")" = 600 ] ||
    inst_failed "Unsafe pending worker activation record."
  INST_PENDING=$(kit_envfile_get "$INST_PENDING_FILE" PHASE)
  case "$INST_PENDING" in
    provision|activate) return 0;;
    *) inst_failed "Invalid pending worker activation record.";;
  esac
}

# Call before changing any settings or files that the worker loads at startup.
inst_mark_pending() {
  local phase
  kit_private_dir "$KIT_DIR" || inst_failed "Unsafe administrative directory for pending worker activation."
  inst_read_pending
  phase=${1:-${INST_PENDING:-activate}}
  if [ "$INST_PENDING" != "$phase" ]; then
    # Unit, state and environment files can live on different filesystems.
    if [ "$INST_PENDING" = provision ]; then sync || inst_failed "Cannot flush provisioned worker files."; fi
    kit_envfile_set "$INST_PENDING_FILE" PHASE "$phase" && sync || inst_failed "Cannot record pending worker activation."
    INST_PENDING=$phase
  fi
  INST_NEED_RESTART=1
}

inst_was_replaced() { [ -r "$INST_REPLACED_LIST" ] && grep -qxF -- "$1" "$INST_REPLACED_LIST"; }

# Which systemd service a PID belongs to (from its cgroup), or empty.
inst_pid_unit() { sed -n 's#.*/\([^/]*\)\.service.*#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -1; }
inst_pid_start() { awk '{sub(/.*\) /,""); if ($1 !~ /^[XZ]$/ && $20 ~ /^[0-9]+$/) print $20}' "/proc/$1/stat" 2>/dev/null; }

# Names (never values) of KEY=VALUE lines in an env file.
inst_env_keys() { [ -r "$1" ] && kit_envfile_records names < "$1"; }

# Names in the sealed sidecar (as the worker, via the installed binary). Sets
# INST_SEALED_KEYS; returns 1 when the sidecar exists but cannot be read.
inst_sealed_keys() {
  local out rc
  INST_SEALED_KEYS=""
  [ -f "$SDM_SIDECAR" ] || return 0
  [ -x "$SDM_BIN" ] || return 0
  out=$(kit_as_worker "$SDM_HOME_DIR" "$SDM_BIN" nodesecrets list 2>/dev/null </dev/null); rc=$?
  if [ $rc -ne 0 ]; then INST_SEALED_ERR="service user could not read sealed keys"; return 1; fi
  INST_SEALED_KEYS=" $(printf '%s\n' "$out" | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | tr '\n' ' ')"
  return 0
}
inst_sealed_has() { [[ ${INST_SEALED_KEYS:-} == *" $1 "* ]]; }
inst_delinea_sealed() { inst_sealed_keys && inst_sealed_has DELINEA_USERNAME && inst_sealed_has DELINEA_PASSWORD; }

# Does a file contain a secret value? Pure bash: the value never hits argv.
inst_file_contains() { local f=$1 v=$2 c; [ -n "$v" ] && [ -r "$f" ] || return 1; c=$(cat "$f" 2>/dev/null); [[ $c == *"$v"* ]]; }

# ============================================================================
# STEP 1: preflight
# ============================================================================
inst_preflight() {
  kit_step 1 $INST_TOTAL "Preflight checks"
  kit_require_root; ok "running as root"
  if kit_in_container; then
    kit_die $KIT_EXIT_PRECOND "This looks like a container; the kit does not install workers inside containers." \
"sdm seals the proxy cluster keys to the host's machine-id and refuses to do that in a container
on this platform. Use host-based sealing on a full virtual machine or physical host." \
"Run the worker with the official image and pass secrets via the orchestrator instead:
  mount a secrets file and set SDM_SECRETS_FILE=/path/to/file in the container
  (plus SDM_PROXY_CLUSTER_ACCESS_KEY / SDM_PROXY_CLUSTER_SECRET_KEY or the same keys in that file)
Or run this kit on the VM / host itself."
  fi
  ok "not a container"
  kit_has_systemd || kit_die $KIT_EXIT_PRECOND "systemd is not running on this host." \
    "The worker is installed as the systemd unit $SDM_UNIT." \
    "Use a systemd-based distribution (RHEL/Rocky/Alma 7-9, Amazon Linux 2/2023, Ubuntu, Debian)."
  ok "systemd is running"
  kit_detect_os
  case "$OS_ID" in
    rhel|rocky|almalinux|centos|ol|amzn|ubuntu|debian) ok "OS: $OS_PRETTY";;
    *) warn "OS '$OS_PRETTY' is not one the kit is tested on; continuing";
       note "tested: RHEL/Rocky/Alma 7-9, Amazon Linux 2/2023, Ubuntu, Debian";;
  esac
  INST_ARCH=$(kit_arch) || exit $KIT_EXIT_PRECOND
  ok "architecture: $INST_ARCH"
  INST_SELINUX=$(kit_selinux_mode)
  info "SELinux: ${INST_SELINUX:-Disabled}"
}

# ============================================================================
# STEP 2: collect every input before changing anything
# ============================================================================
inst_collect() {
  kit_step 2 $INST_TOTAL "Collect settings and secrets (nothing has been changed yet)"
  local d okd=0 a

  # Region.
  kit_pick SDM_APP_DOMAIN "Which StrongDM region is your organization in?" "${KIT_APP_DOMAINS[@]}"
  SDM_APP_DOMAIN=$(kit_trim "$SDM_APP_DOMAIN"); SDM_APP_DOMAIN=${SDM_APP_DOMAIN#https://}; SDM_APP_DOMAIN=${SDM_APP_DOMAIN%/}
  for d in "${KIT_APP_DOMAINS[@]}"; do [ "$d" = "$SDM_APP_DOMAIN" ] && okd=1; done
  [ $okd = 1 ] || kit_die $KIT_EXIT_USAGE "Unknown region '$SDM_APP_DOMAIN'." \
    "Proxy cluster workers connect to one of: ${KIT_APP_DOMAINS[*]}" \
    "export SDM_APP_DOMAIN=app.strongdm.com   # or app.eu.strongdm.com / app.uk.strongdm.com"
  ok "region: $SDM_APP_DOMAIN"

  # Proxy cluster keys. Never exported to every child: only the install subshell gets them.
  note "Admin UI > Networking > Proxy Clusters > (your cluster) > add key gives you an access key + secret key."
  kit_ask_secret SDM_PROXY_CLUSTER_ACCESS_KEY "Proxy cluster access key"
  kit_ask_secret SDM_PROXY_CLUSTER_SECRET_KEY "Proxy cluster secret key"
  export -n SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY 2>/dev/null || true
  inst_clean_secret SDM_PROXY_CLUSTER_ACCESS_KEY "access key" trim
  inst_clean_secret SDM_PROXY_CLUSTER_SECRET_KEY "secret key" trim
  [ -n "$SDM_PROXY_CLUSTER_ACCESS_KEY" ] || kit_die $KIT_EXIT_USAGE "The access key is empty." "" "export SDM_PROXY_CLUSTER_ACCESS_KEY='...' and re-run"
  [ -n "$SDM_PROXY_CLUSTER_SECRET_KEY" ] || kit_die $KIT_EXIT_USAGE "The secret key is empty." "" "export SDM_PROXY_CLUSTER_SECRET_KEY='...' and re-run"
  [[ $SDM_PROXY_CLUSTER_ACCESS_KEY =~ [[:space:]] ]] && kit_die $KIT_EXIT_USAGE "The access key contains whitespace." \
    "Keys are a single token; a space usually means two values were pasted together." "Copy the access key again from the Admin UI and re-run."
  [[ $SDM_PROXY_CLUSTER_SECRET_KEY =~ [[:space:]] ]] && kit_die $KIT_EXIT_USAGE "The secret key contains whitespace." \
    "Keys are a single token; a space usually means two values were pasted together." "Copy the secret key again from the Admin UI and re-run."
  if [[ $SDM_PROXY_CLUSTER_ACCESS_KEY != pk-* ]]; then
    if [[ $SDM_PROXY_CLUSTER_SECRET_KEY == pk-* ]]; then
      kit_die $KIT_EXIT_USAGE "The access key and secret key look swapped." "The access key is the one that starts with 'pk-'." "Re-run and enter the pk-... value as the access key."
    fi
    kit_die $KIT_EXIT_USAGE "The access key does not start with 'pk-'." \
      "Proxy cluster access keys look like pk-XXXX ($(kit_shape "$SDM_PROXY_CLUSTER_ACCESS_KEY") was entered); sdm refuses anything else." \
      "Admin UI > Networking > Proxy Clusters > your cluster > add key, then re-run with that access key."
  fi
  [ "$SDM_PROXY_CLUSTER_ACCESS_KEY" = "$SDM_PROXY_CLUSTER_SECRET_KEY" ] && kit_die $KIT_EXIT_USAGE \
    "The access key and the secret key are identical." "The same value was probably pasted twice." "Re-run and paste the access key, then the secret key."

  # Delinea Secret Server.
  export -n DELINEA_USERNAME DELINEA_PASSWORD 2>/dev/null || true
  INST_DELINEA=no; INST_ROTATE_DELINEA=no; INST_KEEP_DELINEA=0
  case ${KIT_ROTATE_DELINEA:-no} in
    yes) INST_ROTATE_DELINEA=yes;;
    no) ;;
    *) kit_die $KIT_EXIT_USAGE "KIT_ROTATE_DELINEA must be yes or no." "" "Use yes to replace the sealed Delinea pair.";;
  esac
  a=$(printf '%s' "${KIT_DELINEA:-}" | tr '[:upper:]' '[:lower:]')
  case "$a" in
    yes|y|true|1) INST_DELINEA=yes;;
    no|n|false|0) INST_DELINEA=no;;
    "") if [ "$INST_ROTATE_DELINEA" = yes ]; then INST_DELINEA=yes
        elif kit_noninteractive; then [ -n "${DELINEA_USERNAME:-}" ] && INST_DELINEA=yes
        elif kit_confirm "Will this cluster use Delinea Secret Server as a secret store?" n; then INST_DELINEA=yes; fi;;
    *) kit_die $KIT_EXIT_USAGE "KIT_DELINEA must be yes or no (got '$KIT_DELINEA')." "" "export KIT_DELINEA=yes   # or no";;
  esac
  if [ "$INST_ROTATE_DELINEA" = yes ] && [ "$INST_DELINEA" != yes ]; then
    kit_die $KIT_EXIT_USAGE "Delinea rotation requires Delinea provisioning." "" "Set KIT_DELINEA=yes or unset KIT_ROTATE_DELINEA."
  fi
  if [ "$INST_DELINEA" = yes ]; then
    if [ "$INST_ROTATE_DELINEA" = no ] && inst_delinea_sealed; then
      if ! kit_noninteractive && [ -z "${KIT_ROTATE_DELINEA:-}" ] && kit_confirm "Rotate the existing sealed Delinea credentials?" n; then INST_ROTATE_DELINEA=yes
      else INST_KEEP_DELINEA=1; fi
    fi
    if [ "$INST_KEEP_DELINEA" = 0 ]; then
      kit_ask DELINEA_USERNAME "Delinea Secret Server username"
      kit_secret_register DELINEA_USERNAME
      kit_ask_secret DELINEA_PASSWORD "Delinea Secret Server password"
      export -n DELINEA_USERNAME DELINEA_PASSWORD 2>/dev/null || true
      inst_clean_secret DELINEA_USERNAME "Delinea username" trim
      inst_clean_secret DELINEA_PASSWORD "Delinea password" keep
      [ -n "$DELINEA_USERNAME" ] && [ -n "$DELINEA_PASSWORD" ] ||
        kit_die $KIT_EXIT_USAGE "Delinea provisioning requires both a username and a password." "" "Supply both values and re-run install."
    else
      unset DELINEA_USERNAME DELINEA_PASSWORD
    fi
    if [ -z "${DELINEA_SERVER_URL:-}" ] && ! kit_noninteractive; then
      kit_ask DELINEA_SERVER_URL "Delinea server URL (leave blank if it is set on the secret store in the Admin UI)" ""
    fi
    DELINEA_SERVER_URL=$(kit_trim "${DELINEA_SERVER_URL:-}")
  else
    unset DELINEA_USERNAME DELINEA_PASSWORD
  fi
  if [ -n "${DELINEA_SERVER_URL:-}" ] && ! kit_https_url "$DELINEA_SERVER_URL"; then
      kit_die $KIT_EXIT_USAGE "DELINEA_SERVER_URL must be an https:// URL." "" "export DELINEA_SERVER_URL=https://yourtenant.secretservercloud.com   # or leave it unset"
  fi

  # Bind address (env only).
  INST_BIND=$(kit_trim "${SDM_BIND_ADDRESS:-$SDM_DEFAULT_BIND}")
  [[ $INST_BIND =~ ^[^[:space:]]*:[0-9]+$ ]] || kit_die $KIT_EXIT_USAGE "SDM_BIND_ADDRESS '$INST_BIND' is not host:port or :port." "" "export SDM_BIND_ADDRESS=:8443"
  local port; port=$(inst_bind_port "$INST_BIND")
  { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } 2>/dev/null || kit_die $KIT_EXIT_USAGE "Port $port is out of range." "" "export SDM_BIND_ADDRESS=:8443"

  # Summary (shapes only, never values).
  kit_section "Please confirm"
  printf '    %-26s %s\n' "service user" "$SDM_USER  (home $SDM_USER_HOME, SDM_HOME $SDM_HOME_DIR)"
  printf '    %-26s %s\n' "region" "$SDM_APP_DOMAIN"
  printf '    %-26s %s\n' "access key" "hidden  ($(kit_shape "$SDM_PROXY_CLUSTER_ACCESS_KEY"))"
  printf '    %-26s %s\n' "secret key" "hidden  ($(kit_shape "$SDM_PROXY_CLUSTER_SECRET_KEY"))"
  printf '    %-26s %s\n' "bind address" "$INST_BIND"
  if [ "$INST_DELINEA" = yes ]; then
    if [ "$INST_KEEP_DELINEA" = 1 ]; then
      info "Keeping existing sealed Delinea credentials. Use KIT_ROTATE_DELINEA=yes to apply new values."
    else
      printf '    %-26s %s\n' "Delinea username" "hidden  ($(kit_shape "$DELINEA_USERNAME"))"
      printf '    %-26s %s\n' "Delinea password" "hidden  ($(kit_shape "$DELINEA_PASSWORD"))"
    fi
    printf '    %-26s %s\n' "Delinea server URL" "${DELINEA_SERVER_URL:-(from the secret store in the Admin UI)}"
  else
    printf '    %-26s %s\n' "Delinea Secret Server" "not used"
  fi
  if kit_noninteractive && [ "${KIT_ASSUME_YES:-}" != 1 ]; then
    kit_die $KIT_EXIT_USAGE "Non-interactive install needs explicit consent." "There is no terminal to confirm the summary above on." "export KIT_ASSUME_YES=1 and re-run"
  fi
  kit_confirm "Proceed with these settings?" y || inst_abort
}

# inst_clean_secret VAR label trim|keep : reject CR/LF, optionally trim, warn on oddities (no values shown).
inst_clean_secret() {
  local __v=$1 label=$2 mode=$3 val an t
  val=${!__v:-}
  if [[ $val == *$'\r'* || $val == *$'\n'* ]]; then
    kit_die $KIT_EXIT_USAGE "The $label contains a line break." "Values must be a single line (they are sealed one line per key)." "Re-run and paste the value again without the trailing newline."
  fi
  if [ "$mode" = trim ]; then
    t=$(kit_trim "$val")
    if [ "$t" != "$val" ]; then warn "removed leading/trailing whitespace from the $label"; printf -v "$__v" '%s' "$t"; val=$t; fi
  fi
  an=$(kit_anomalies "$val")
  [ -n "$an" ] && { warn "the $label looks unusual: $an"; note "($(kit_shape "$val")) - check it if authentication fails later"; }
  t=""; val=""
  return 0
}

# ============================================================================
# STEP 3 / 4: dependencies and reachability
# ============================================================================
inst_deps() {
  kit_step 3 $INST_TOTAL "Required tools"
  kit_have runuser && kit_have setsid && kit_have flock || kit_die 3 "Required util-linux tools are missing." "" "Install util-linux."
  kit_ensure_cmds curl unzip sha256sum
  ok "curl, unzip and sha256sum are available"
}

inst_reach() {
  kit_step 4 $INST_TOTAL "Can this host reach $SDM_APP_DOMAIN:443?"
  if kit_tcp_ok "$SDM_APP_DOMAIN" 443; then ok "TCP 443 to $SDM_APP_DOMAIN is open"; return 0; fi
  if [ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]; then
    kit_http GET "https://$SDM_APP_DOMAIN/"
    if [ "$HE" = 0 ] && [ "$HC" != 000 ]; then
      warn "direct TCP 443 is blocked, but $SDM_APP_DOMAIN answers through the HTTPS proxy (HTTP $HC)"
      note "the worker also needs the proxy: add HTTPS_PROXY=... to $SDM_SYSCONFIG after the install"
      return 0
    fi
  fi
  kit_die $KIT_EXIT_PRECOND "Cannot open TCP 443 to $SDM_APP_DOMAIN." \
"The worker must reach the StrongDM control plane outbound on 443. Usual causes:
an egress security group / NACL / firewall rule, a corporate proxy that is not configured,
or DNS that does not resolve $SDM_APP_DOMAIN." \
"getent hosts $SDM_APP_DOMAIN                       # does DNS resolve?
curl -sv https://$SDM_APP_DOMAIN/ -o /dev/null     # what blocks it?
allow outbound TCP 443 to $SDM_APP_DOMAIN in your security group / firewall, or
export HTTPS_PROXY=http://proxy:port and re-run"
}

# ============================================================================
# STEP 5: existing-install analysis
#   INST_CLASS = NONE | OURS-HEALTHY | OURS-NEEDS-REPAIR | FOREIGN
# ============================================================================
inst_analyze() {
  INST_FINDINGS=(); INST_REPAIRS=(); INST_REINSTALL=(); INST_FOREIGN_UNITS=(); INST_FOREIGN_DIRS=()
  INST_FOREIGN_ENVS=(); INST_FOREIGN_PIDS=(); INST_PID_START=(); INST_INFO=()
  INST_OURS=0; INST_NEED_BINARY=0; INST_KEYS_UNKNOWN=0; INST_SIDECAR_BAD=0
  INST_PLAINTEXT_KEYS=0; INST_PREV_ENV=()
  local u user envf exec wd envs f d line pid puser role exe h sdmhome n

  # User `sdm` must have home /home/sdm (hard rule; checked before any change).
 
  if getent passwd "$SDM_USER" >/dev/null 2>&1; then

    h=$(inst_user_home "$SDM_USER")
    if [ "$h" != "$SDM_USER_HOME" ]; then
      kit_die $KIT_EXIT_PRECOND "User '$SDM_USER' exists but its home is '$h', not $SDM_USER_HOME." \
"The kit always runs the worker as $SDM_USER with SDM_HOME=$SDM_HOME_DIR and will not change that." \
"usermod -m -d $SDM_USER_HOME $SDM_USER     # moves the home directory (stop anything running as $SDM_USER first)
then re-run this kit"
    fi
  fi

  # systemd units.
  for u in "${KIT_FOREIGN_UNITS[@]}"; do
    kit_unit_exists "$u" || continue
    user=$(kit_unit_prop "$u" User); exec=$(kit_unit_prop "$u" ExecStart); wd=$(kit_unit_prop "$u" WorkingDirectory)
    envf=$(kit_unit_prop "$u" EnvironmentFiles); envs=$(printf '%s\n' "$envf" | grep -oE '/[^ ]+' | tr '\n' ' ')
    local act en; act=$(kit_unit_prop "$u" ActiveState); en=$(systemctl is-enabled "$u" 2>/dev/null </dev/null)
    if [ "$u" = "$SDM_UNIT" ] && [ "$user" = "$SDM_USER" ] && [[ $exec == *"argv[]=$SDM_BIN worker"* ]]; then
      sdmhome=$(inst_strip_quotes "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_HOME)")
      if [ "$sdmhome" = "$SDM_HOME_DIR" ] || { [ -z "$sdmhome" ] && [ "$wd" = "$SDM_HOME_DIR" ]; }; then
        INST_OURS=1; INST_OURS_ACTIVE=$act; INST_OURS_ENABLED=$en
        INST_INFO+=("unit $u: ours (User=$SDM_USER, SDM_HOME=$SDM_HOME_DIR), $act, ${en:-unknown}")
        continue
      fi
    fi
    if inst_was_replaced "unit:$u" && [ "$act" = inactive ] && [[ $en != enabled* ]]; then
      INST_INFO+=("unit $u: replaced by an earlier run (stopped, disabled; backup in $KIT_BACKUP_DIR)")
      continue
    fi
    INST_FOREIGN_UNITS+=("$u")
    INST_FINDINGS+=("unit $u: User=${user:-root}, $act/${en:-unknown}")
    INST_FINDINGS+=("    WorkingDirectory=${wd:-none}  EnvironmentFile=${envs:-none}")
    [ -n "$wd" ] && [ -d "$wd" ] && INST_FOREIGN_DIRS+=("$wd")
    for f in $envs; do
      [ -f "$f" ] || continue
      INST_FOREIGN_ENVS+=("$f")
      sdmhome=$(inst_strip_quotes "$(kit_envfile_get "$f" SDM_HOME)")
      [ -n "$sdmhome" ] && [ -d "$sdmhome" ] && INST_FOREIGN_DIRS+=("$sdmhome")
    done
  done

  # Running sdm worker/relay/gateway/proxy processes.
  while IFS='|' read -r pid puser role exe _ _; do
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
    u=$(inst_pid_unit "$pid")
    if [ "$INST_OURS" = 1 ] && [ "$u" = "$SDM_UNIT" ] && [ "$puser" = "$SDM_USER" ]; then continue; fi
    if [ -n "$u" ] && [[ " ${INST_FOREIGN_UNITS[*]} " == *" $u "* ]]; then
      INST_FINDINGS+=("process $pid: sdm $role as $puser (unit $u, stopped with it)"); continue
    fi
    INST_PID_START[pid]=$(inst_pid_start "$pid")
    [ -n "${INST_PID_START[pid]}" ] || continue
    INST_FOREIGN_PIDS+=("$pid")
    INST_FINDINGS+=("process $pid: sdm $role as $puser, exe $exe, ${u:+unit $u}${u:-not managed by a known unit}")
  done < <(kit_find_node_procs)

  # /etc/sysconfig/sdm* env files.
  for f in /etc/sysconfig/sdm*; do
    [ -f "$f" ] || continue
    case "$f" in "$SDM_SYSCONFIG".*) continue;; esac       # kit/sdm temp files
    [[ " ${INST_FOREIGN_ENVS[*]} " == *" $f "* ]] && continue
    if [ "$f" = "$SDM_SYSCONFIG" ]; then
      sdmhome=$(inst_strip_quotes "$(kit_envfile_get "$f" SDM_HOME)")
      if [ "$INST_OURS" = 1 ] || [ "$sdmhome" = "$SDM_HOME_DIR" ]; then
        [ "$INST_OURS" = 1 ] || INST_INFO+=("$f: left over from an earlier install of ours (sdm install rewrites it)")
        continue
      fi
    fi
    if inst_was_replaced "env:$f"; then INST_INFO+=("$f: replaced by an earlier run (backup in $KIT_BACKUP_DIR)"); continue; fi
    INST_FOREIGN_ENVS+=("$f")
    INST_FINDINGS+=("env file $f: keys $(inst_env_keys "$f")(values not shown)")
    sdmhome=$(inst_strip_quotes "$(kit_envfile_get "$f" SDM_HOME)")
    [ -n "$sdmhome" ] && [ -d "$sdmhome" ] && [ "$sdmhome" != "$SDM_HOME_DIR" ] && INST_FOREIGN_DIRS+=("$sdmhome")
  done

  # Sealed sidecars in /root and /home/*.
  for d in /root/.sdm /home/*/.sdm; do
    [ -f "$d/secretenv.enc" ] || continue
    [ "$d" = "$SDM_HOME_DIR" ] && continue
    [[ " ${INST_FOREIGN_DIRS[*]} " == *" $d "* ]] && continue
    if inst_was_replaced "dir:$d"; then INST_INFO+=("$d: replaced by an earlier run (left in place, backup in $KIT_BACKUP_DIR)"); continue; fi
    INST_FOREIGN_DIRS+=("$d")
    INST_FINDINGS+=("sealed secrets $d/secretenv.enc (owner $(stat -c %U "$d/secretenv.enc" 2>/dev/null))")
  done
  # Unit discovery and the sysconfig scan can both select the same file.
  if [ ${#INST_FOREIGN_ENVS[@]} -gt 0 ]; then mapfile -t INST_FOREIGN_ENVS < <(printf '%s\n' "${INST_FOREIGN_ENVS[@]}" | awk '!s[$0]++'); fi
  if [ ${#INST_FOREIGN_DIRS[@]} -gt 0 ]; then mapfile -t INST_FOREIGN_DIRS < <(printf '%s\n' "${INST_FOREIGN_DIRS[@]}" | awk '!s[$0]++'); fi
  for d in "${INST_FOREIGN_DIRS[@]}"; do
    [[ " ${INST_FINDINGS[*]} " == *"$d/secretenv.enc"* ]] || INST_FINDINGS+=("config dir $d (will be backed up, not deleted)")
  done

  # Only these settings migrate between different installations. Existing kit
  # workers keep their complete environment when the kit updates its own keys.
  for n in DELINEA_SERVER_URL DELINEA_API_TENANT HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
    line=$(kit_envfile_get "$SDM_SYSCONFIG" "$n") && INST_PREV_ENV+=("$n=$line")
  done

  [ "$INST_OURS" = 1 ] && inst_health
  if [ ${#INST_FOREIGN_UNITS[@]} -gt 0 ] || [ ${#INST_FOREIGN_DIRS[@]} -gt 0 ] || [ ${#INST_FOREIGN_ENVS[@]} -gt 0 ] || [ ${#INST_FOREIGN_PIDS[@]} -gt 0 ]; then
    INST_CLASS=FOREIGN
  elif [ "$INST_OURS" = 1 ]; then
    if [ ${#INST_REPAIRS[@]} -eq 0 ] && [ ${#INST_REINSTALL[@]} -eq 0 ]; then INST_CLASS=OURS-HEALTHY; else INST_CLASS=OURS-NEEDS-REPAIR; fi
  else
    INST_CLASS=NONE
  fi
}

# Health of an install that is ours. Fills INST_REPAIRS (fixable in place) and
# INST_REINSTALL (reprovision the CLI, sealed credentials and service unit).
inst_health() {
  local v fp ad ab own
  [ -x "$SDM_BIN" ] || { INST_REPAIRS+=("binary $SDM_BIN is missing"); INST_NEED_BINARY=1; }

  ad=$(inst_strip_quotes "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_APP_DOMAIN)"); ad=${ad:-app.strongdm.com}
  [ "$ad" = "$SDM_APP_DOMAIN" ] || INST_REINSTALL+=("region changes from $ad to $SDM_APP_DOMAIN")
  ab=$(inst_strip_quotes "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_BIND_ADDRESS)"); ab=${ab:-$SDM_DEFAULT_BIND}
  [ "$ab" = "$INST_BIND" ] || INST_REINSTALL+=("bind address changes from $ab to $INST_BIND")
  [ "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_LOG_OUTPUT)" = stdout ] || INST_REPAIRS+=("SDM_LOG_OUTPUT=stdout missing from $SDM_SYSCONFIG")

  # Keys: sealed (names only) or plaintext fallback.
  if [ -x "$SDM_BIN" ] && ! inst_sealed_keys; then
    INST_SIDECAR_BAD=1
    INST_REINSTALL+=("sealed secrets file cannot be read (host cloned or machine-id changed?) - it will be set aside, not deleted")
  fi
  local sealed=0 plain=0
  inst_sealed_has SDM_PROXY_CLUSTER_ACCESS_KEY && inst_sealed_has SDM_PROXY_CLUSTER_SECRET_KEY && sealed=1
  kit_envfile_has "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_ACCESS_KEY && kit_envfile_has "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_SECRET_KEY && plain=1
  if [ $sealed = 0 ] && [ $plain = 0 ] && [ "$INST_SIDECAR_BAD" = 0 ]; then
    if [ -x "$SDM_BIN" ] || [ ! -f "$SDM_SIDECAR" ]; then INST_REINSTALL+=("no proxy cluster keys found (sealed or in $SDM_SYSCONFIG)"); fi
  fi
  if kit_envfile_has "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_ACCESS_KEY || kit_envfile_has "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_SECRET_KEY; then
    INST_PLAINTEXT_KEYS=1
    if [ $sealed = 1 ]; then INST_REPAIRS+=("plaintext keys left in $SDM_SYSCONFIG although they are sealed (will be removed)")
    else
      v=$(kit_envfile_get "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_ACCESS_KEY); fp=$(kit_envfile_get "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_SECRET_KEY)
      if [ "$v" != "$SDM_PROXY_CLUSTER_ACCESS_KEY" ] || [ "$fp" != "$SDM_PROXY_CLUSTER_SECRET_KEY" ]; then INST_REINSTALL+=("the keys you entered differ from the installed ones"); fi
      v=""; fp=""
    fi
  fi
  if [ $sealed = 1 ]; then
    fp=$(inst_state_get KEY_FP)
    if [ -z "$fp" ]; then INST_KEYS_UNKNOWN=1
    elif [ "$fp" != "$(inst_key_fp)" ]; then INST_REINSTALL+=("the keys you entered differ from the installed ones")
    fi
  fi

  # Ownership / permissions.
  for v in "$SDM_HOME_DIR" "$SDM_HOME_DIR/state.kv" "$SDM_SIDECAR"; do
    [ -e "$v" ] || continue
    own=$(stat -c %U "$v" 2>/dev/null)
    [ "$own" = "$SDM_USER" ] || INST_REPAIRS+=("$v is owned by $own, not $SDM_USER")
  done
  [ -d "$SDM_HOME_DIR" ] || INST_REPAIRS+=("$SDM_HOME_DIR is missing")
  [ -f "$SDM_HOME_DIR/state.kv" ] || [ ${#INST_REINSTALL[@]} -gt 0 ] || INST_REINSTALL+=("$SDM_HOME_DIR/state.kv is missing")

  [ "${INST_OURS_ENABLED:-}" = enabled ] || INST_REPAIRS+=("unit $SDM_UNIT is not enabled at boot")
  [ "${INST_OURS_ACTIVE:-}" = active ] || INST_REPAIRS+=("unit $SDM_UNIT is not running (${INST_OURS_ACTIVE:-unknown})")
  case "${INST_PENDING:-}" in
    provision) INST_REINSTALL+=("an earlier provisioning attempt was interrupted");;
    activate) INST_REPAIRS+=("worker settings from an earlier attempt still need activation");;
  esac
  # Port in use by something else is diagnosed at start (step 11).
  return 0
}

inst_report_and_decide() {
  kit_step 5 $INST_TOTAL "Look for existing StrongDM installs"
  inst_analyze
  local i
  for i in "${INST_INFO[@]}"; do info "$i"; done
  case "$INST_CLASS" in
    NONE) ok "no existing StrongDM worker, relay or gateway found: fresh install";;
    OURS-HEALTHY) ok "existing install is ours and healthy";;
    OURS-NEEDS-REPAIR) warn "existing install is ours but needs attention:"
      for i in "${INST_REPAIRS[@]}"; do note "repair: $i"; done
      for i in "${INST_REINSTALL[@]}"; do note "re-install: $i"; done;;
    FOREIGN) warn "found a StrongDM install that this kit did not create:"
      for i in "${INST_FINDINGS[@]}"; do note "$i"; done
      if [ "$INST_OURS" = 1 ]; then
        for i in "${INST_REPAIRS[@]}"; do note "repair (ours): $i"; done
        for i in "${INST_REINSTALL[@]}"; do note "re-install (ours): $i"; done
      fi;;
  esac

  # Port check (before changing anything) when nothing sdm-like will free it.
  local port; port=$(inst_bind_port "$INST_BIND")
  if kit_have ss && [ -n "$(ss -ltnH "sport = :$port" 2>/dev/null)" ] && [ -z "$(kit_find_node_procs)" ]; then
    kit_die $KIT_EXIT_PRECOND "Port $port is already in use by another program." \
      "The worker listens on $INST_BIND and would fail to start." \
"ss -ltnp 'sport = :$port'          # see who owns it
stop that program, or choose another port: export SDM_BIND_ADDRESS=:8444"
  fi

  # Decide what to do.
  INST_DO_INSTALL=0
  if [ "$INST_CLASS" = FOREIGN ]; then
    printf '\n'
    if [ "${#INST_FOREIGN_PIDS[@]}" -gt 0 ]; then
      kit_die "$KIT_EXIT_PRECOND" "A StrongDM process has no known restartable unit." \
        "The kit cannot restore processes ${INST_FOREIGN_PIDS[*]} after an unsuccessful replacement." \
        "Use the original service manager or launch mechanism to stop those processes, then re-run."
    fi
    note "REPLACE will back up the listed files with encryption and stop ${INST_FOREIGN_UNITS[*]:-no units}."
    note "The kit restores previously running units if the replacement fails."
    if kit_noninteractive && [ "${KIT_REPLACE:-}" != yes ]; then
      kit_die $KIT_EXIT_USAGE "A foreign StrongDM install is present." "Non-interactive runs only replace it when told to." "export KIT_REPLACE=yes and re-run (review the findings above first)"
    fi
    kit_confirm_typed REPLACE "Replace the install(s) listed above?" || inst_abort
    ok "operator confirmed REPLACE"
  fi
  if [ "$INST_OURS" != 1 ]; then INST_DO_INSTALL=1; return 0; fi

  if [ ${#INST_REINSTALL[@]} -gt 0 ]; then
    warn "a re-install is needed. The worker will restart and active sessions will drop."
    kit_confirm "Re-install the worker now?" y || inst_abort
    INST_DO_INSTALL=1; return 0
  fi
  if [ "$INST_KEYS_UNKNOWN" = 1 ]; then
    warn "the installed keys are sealed and cannot be read back, so the kit cannot tell whether you entered the same keys."
    note "If you rotated the keys, choose re-install (or KIT_FORCE_REINSTALL=yes). Otherwise the install is kept as is."
  fi
  if [ "${KIT_FORCE_REINSTALL:-}" = yes ]; then
    warn "KIT_FORCE_REINSTALL=yes: re-installing. This restarts the worker and drops active sessions."
    INST_DO_INSTALL=1; return 0
  fi
  if ! kit_noninteractive; then
    note "Re-installing is never needed for repairs; it restarts the worker and drops active sessions."
    if kit_confirm "Re-install anyway?" n; then INST_DO_INSTALL=1; warn "re-install chosen by the operator"; return 0; fi
  fi
  info "keeping the existing install; only repairs will be made"
}

# Back up the selected configuration before changing any services.
inst_backup_certificate() {
  kit_ask KIT_BACKUP_CERT "Path to the backup recipient PEM certificate"
  kit_trusted_file "$KIT_BACKUP_CERT" || inst_failed "Use a root-protected backup certificate."
  kit_ensure_cmds openssl
}
inst_encrypt_backup() {
  local out=$1
  [ ! -e "$out" ] && openssl cms -encrypt -binary -aes256 -stream -outform DER -in "$stage/plain" -out "$out" "$KIT_BACKUP_CERT" &&
    openssl cms -cmsout -inform DER -in "$out" -out /dev/null &&
    (cd "$dest" && sha256sum "${out#"$dest"/}" >> SHA256SUMS) && rm -f "$stage/plain"
}
inst_backup_foreign() {
  local dest u f d safe stage source_hash copy_hash
  local envfiles=("${INST_FOREIGN_ENVS[@]}")
  if [ "$INST_OURS" != 1 ] && [ -f "$SDM_SYSCONFIG" ] &&
      [[ " ${envfiles[*]} " != *" $SDM_SYSCONFIG "* ]]; then envfiles+=("$SDM_SYSCONFIG"); fi
  if (( ${#INST_FOREIGN_DIRS[@]} + ${#INST_FOREIGN_UNITS[@]} + ${#INST_FOREIGN_ENVS[@]} > 0 )); then inst_backup_certificate; fi
  if [ "${#INST_FOREIGN_DIRS[@]}" -gt 0 ] || [ -d "$SDM_HOME_DIR" ]; then kit_ensure_cmds tar; fi
  mkdir -p /var/backups && kit_private_dir "$KIT_BACKUP_DIR" && kit_private_dir "$KIT_DIR" || inst_failed "Unsafe backup or administrative directory."
  dest=$(mktemp -d "$KIT_BACKUP_DIR/$(date +%Y%m%d-%H%M%S).XXXXXX") || inst_failed "Cannot create backup."
  (umask 077; mkdir "$dest/units" "$dest/env" "$dest/dirs") || inst_failed "Cannot create backup directories."
  inst_backup_failed() { [ -z "${stage:-}" ] || rm -rf -- "$stage"; inst_failed "Backup incomplete in $dest. No replacement has started."; }
  [ "$(stat -f -c %T /dev/shm)" = tmpfs ] || inst_failed "Encrypted backups require tmpfs scratch space in /dev/shm."
  stage=$(mktemp -d /dev/shm/sdm-backup.XXXXXX) || inst_backup_failed
  local cleanup; printf -v cleanup 'rm -rf -- %q' "$stage"; kit_on_exit "$cleanup"
  for u in "${INST_FOREIGN_UNITS[@]}"; do
    systemctl cat "$u" </dev/null > "$stage/plain" && [ -s "$stage/plain" ] && inst_encrypt_backup "$dest/units/$u.service.cms" || inst_backup_failed
  done
  for f in "${envfiles[@]}"; do
    safe=${f#/}; safe=${safe//\//_}
    [ -f "$f" ] && [ ! -L "$f" ] && cp -- "$f" "$stage/plain" &&
      source_hash=$(sha256sum < "$f") && copy_hash=$(sha256sum < "$stage/plain") && [ "$source_hash" = "$copy_hash" ] &&
      inst_encrypt_backup "$dest/env/$safe.cms" || inst_backup_failed
  done
  for d in "${INST_FOREIGN_DIRS[@]}"; do
    case "$d" in /root/.sdm|/home/*/.sdm|/sdm|/var/lib/strongdm|/opt/strongdm/*) ;; *) inst_backup_failed;; esac
    [ "$(readlink -f -- "$d")" = "$d" ] && [ -d "$d" ] || inst_backup_failed
    safe=${d#/}; safe=${safe//\//_}
    (cd -P -- "$d" && [ "$PWD" = "$d" ] && tar -cf "$stage/plain" . && tar -df "$stage/plain") &&
      inst_encrypt_backup "$dest/dirs/$safe.tar.cms" || inst_backup_failed
  done
  if [ "$INST_OURS" != 1 ] && [ -d "$SDM_HOME_DIR" ] &&
      [[ " ${INST_FOREIGN_DIRS[*]} " != *" $SDM_HOME_DIR "* ]]; then
    safe=${SDM_HOME_DIR#/}; safe=${safe//\//_}
    (cd -P -- "$SDM_HOME_DIR" && [ "$PWD" = "$SDM_HOME_DIR" ] && tar -cf "$stage/plain" . && tar -df "$stage/plain") &&
      inst_encrypt_backup "$dest/dirs/$safe.tar.cms" || inst_backup_failed
  fi
  if [ "$INST_OURS" != 1 ] && [ -f "$SDM_BIN" ] && [ ! -L "$SDM_BIN" ]; then
    (cd -P -- "$(dirname -- "$SDM_BIN")" && [ "$PWD" = "$(dirname -- "$SDM_BIN")" ] &&
      [ ! -L "${SDM_BIN##*/}" ] && cp -P -- "${SDM_BIN##*/}" "$stage/plain" && [ ! -L "$stage/plain" ]) &&
      inst_encrypt_backup "$dest/worker-binary.cms" || inst_backup_failed
  fi
  printf '%s\n' 'Sensitive worker backup. Restrict access to the backup administrator.' > "$dest/README.txt" || inst_backup_failed
  if [ -e "$dest/SHA256SUMS" ]; then (cd "$dest" && sha256sum -c SHA256SUMS >/dev/null) || inst_backup_failed; fi
  : > "$dest/COMPLETE" || inst_backup_failed
  rm -rf -- "$stage"
  INST_BACKUP_PATH=$dest
  ok "encrypted backup verified in $dest"
}

# Paths on which provisioning can overwrite a foreign service's installation.
# Move the originals into root-only directories on their own filesystems.
# The journal uses no secret values and can be replayed after an interrupted run.
inst_replacement_paths() {
  printf '%s|%s\n' "$SDM_PREFIX" /opt "$SDM_HOME_DIR" /home \
    "$SDM_SYSCONFIG" /etc/sysconfig "$INST_STATE_FILE" "$KIT_DIR" \
    "${INST_PENDING_FILE:-$KIT_DIR/activation.pending}" "$KIT_DIR" "$INST_REPLACED_LIST" "$KIT_DIR"
  if kit_has_systemd; then
    printf '%s|%s\n' "/etc/systemd/system/$SDM_UNIT.service" /etc/systemd/system \
      "/etc/systemd/system/$SDM_UNIT.service.d" /etc/systemd/system
  fi
}

inst_replacement_move() (
  local path=$1 vault=$2 operation=$3 parent leaf
  parent=${path%/*}; leaf=${path##*/}
  cd -P -- "$parent" && [ "$PWD" = "$parent" ] || return 1
  case "$operation" in
    save)
      [ "$(stat -c %d .)" = "$(stat -c %d "$vault")" ] && mv -T -- "$leaf" "$vault/original"
      ;;
    copy)
      cp -aT -- "$vault/original" "$vault/working" && mv -fT -- "$vault/working" "$leaf"
      ;;
    restore)
      rm -rf -- "$leaf" && mv -T -- "$vault/original" "$leaf"
      ;;
    remove)
      rm -rf -- "$leaf"
      ;;
  esac
)

# Record the actual enablement links, including custom and runtime links,
# so rollback does not need to infer them from a unit's [Install] section.
inst_replacement_links() {
  local journal=$1 link target unit _state dir
  local names=() dirs=()
  while IFS='|' read -r unit _state; do names+=("$unit.service"); done < "$journal/units"
  for dir in /etc/systemd/system /run/systemd/system; do [ ! -d "$dir" ] || dirs+=("$dir"); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  find "${dirs[@]}" -type l -printf '%p\0%l\0' > "$journal/linkscan" || return 1
  while IFS= read -rd '' link && IFS= read -rd '' target; do
    # The worker fragment itself is saved with the other overwritten paths.
    [ "$link" != "/etc/systemd/system/$SDM_UNIT.service" ] || continue
    case "${link%/*}" in
      /etc/systemd/system|/run/systemd/system)
        if [[ " ${names[*]} " == *" ${link##*/} "* ]]; then
          printf '%s\0%s\0' "$link" "$target"
          continue
        fi
        ;;
    esac
    if [[ " ${names[*]} " == *" ${target##*/} "* ]]; then
      printf '%s\0%s\0' "$link" "$target"
    fi
  done < "$journal/linkscan"
}

inst_replacement_cleanup() {
  local journal=$1 _path vault _present
  if [ -f "$journal/paths" ]; then
    while IFS='|' read -r _path vault _present; do
      if [ -e "$vault" ] || [ -L "$vault" ]; then
        kit_private_dir "$vault" && rm -rf -- "$vault" || return 1
      fi
    done < "$journal/paths"
  fi
  rm -rf -- "$journal"
}

inst_replacement_recover() {
  local journal="$KIT_DIR/replacement" path vault present u state link target failed=0
  [ -e "$journal" ] || return 0
  kit_private_dir "$journal" || return 1
  if [ ! -f "$journal/pending" ] || [ -f "$journal/committed" ] || [ -f "$journal/restored" ]; then
    inst_replacement_cleanup "$journal" || return 1
    return 0
  fi
  warn "Restoring the previous StrongDM installation after an unsuccessful replacement."
  if [ -f "$journal/switched" ]; then
    if kit_unit_exists "$SDM_UNIT"; then systemctl stop "$SDM_UNIT" </dev/null >/dev/null 2>&1 || return 1; fi
    while IFS='|' read -r path vault present; do
      kit_private_dir "$vault" || { failed=1; continue; }
      if [ -e "$vault/original" ] || [ -L "$vault/original" ]; then
        inst_replacement_move "$path" "$vault" restore || failed=1
      elif [ "$present" = no ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
        inst_replacement_move "$path" "$vault" remove || failed=1
      fi
    done < "$journal/paths"
    [ "$failed" = 0 ] || return 1
    inst_replacement_links "$journal" > "$journal/current-links" || return 1
    while IFS= read -rd '' link && IFS= read -rd '' target; do
      kit_trusted_dir "${link%/*}" && rm -f -- "$link" || failed=1
    done < "$journal/current-links"
    while IFS= read -rd '' link && IFS= read -rd '' target; do
      mkdir -p -- "${link%/*}" && kit_trusted_dir "${link%/*}" && ln -s -- "$target" "$link" || failed=1
    done < "$journal/links"
    [ "$failed" = 0 ] || return 1
    if kit_has_systemd; then systemctl daemon-reload </dev/null || return 1; fi
  fi
  while IFS='|' read -r u state; do
    if [ "$state" = active ]; then
      systemctl reset-failed "$u" </dev/null >/dev/null 2>&1 || true
      systemctl start "$u" </dev/null >/dev/null 2>&1 && systemctl is-active --quiet "$u" </dev/null || failed=1
    elif [ "$(kit_unit_prop "$u" ActiveState)" != inactive ]; then
      systemctl stop "$u" </dev/null >/dev/null 2>&1 || failed=1
    fi
  done < "$journal/units"
  [ "$failed" = 0 ] || return 1
  sync && : > "$journal/restored" && sync || return 1
  inst_replacement_cleanup "$journal" || return 1
  ok "Previous StrongDM installation restored."
}

inst_replacement_exit() {
  inst_replacement_recover || fail "Replacement recovery is incomplete. The rollback journal remains in $KIT_DIR/replacement. Re-run the installer to retry recovery."
}

inst_replacement_worker_processes() {
  local uid status field real effective saved filesystem
  uid=$(id -u "$SDM_USER" 2>/dev/null) || return 1
  [ -r /proc/1/status ] || return 0
  for status in /proc/[0-9]*/status; do
    while read -r field real effective saved filesystem; do
      [ "$field" = Uid: ] || continue
      if [[ $uid = "$real" || $uid = "$effective" || $uid = "$saved" || $uid = "$filesystem" ]]; then
        return 0
      fi
      break
    done 2>/dev/null < "$status" || { [ ! -e "$status" ] || return 0; }
  done
  return 1
}

inst_replacement_probe_sealing() {
  [ "${INST_DO_INSTALL:-0}" = 1 ] && [ "$INST_OURS" != 1 ] && [ -n "${INST_NEW_BIN:-}" ] || return 0
  if inst_replacement_worker_processes; then
    info "Credential sealing will be checked after the original service account stops."
    return 0
  fi
  local scratch cleanup
  scratch=$(mktemp -d /dev/shm/sdm-sealing.XXXXXX) || inst_failed "Cannot stage a credential sealing check."
  printf -v cleanup 'rm -rf -- %q' "$scratch"; kit_on_exit "$cleanup"
  local SDM_BIN=/proc/self/fd/8 SDM_USER_HOME="$scratch/home" SDM_HOME_DIR="$scratch/home" SDM_SIDECAR="$scratch/home/secretenv.enc"
  local INST_SEALED_KEYS INST_SEALED_ERR
  chmod 0711 "$scratch" && install -d -m 0700 -o "$SDM_USER" "$SDM_HOME_DIR" ||
    inst_failed "Cannot prepare the isolated sealing check."
  inst_seal_pair 8<"$INST_NEW_BIN"
  if [ "${INST_DELINEA:-no}" = yes ] && [ -n "${DELINEA_USERNAME:-}" ] && [ -n "${DELINEA_PASSWORD:-}" ]; then
    printf '%s\n%s\n' "$DELINEA_USERNAME" "$DELINEA_PASSWORD" |
      kit_as_worker "$SDM_HOME_DIR" "$SDM_BIN" nodesecrets set DELINEA_USERNAME DELINEA_PASSWORD 8<"$INST_NEW_BIN" >/dev/null 2>&1 &&
      inst_sealed_keys 8<"$INST_NEW_BIN" && inst_sealed_has DELINEA_USERNAME && inst_sealed_has DELINEA_PASSWORD ||
      inst_failed "The replacement CLI could not seal and verify the Delinea credentials."
  fi
  rm -rf -- "$scratch"
  ok "verified that the replacement CLI can seal credentials before stopping services"
}

inst_replace_foreign() {
  [ "$INST_CLASS" = FOREIGN ] || return 0
  [ "${#INST_FOREIGN_PIDS[@]}" = 0 ] || inst_failed "Stop the unmanaged StrongDM processes using their original launch mechanism."
  if [ "$INST_OURS" != 1 ] && [ "${INST_KEEP_DELINEA:-0}" = 1 ]; then
    inst_failed "Supply the Delinea credentials with KIT_ROTATE_DELINEA=yes to seal them for the replacement worker."
  fi
  local journal="$KIT_DIR/replacement" u state path anchor vault present p link target
  [ ! -L "$SDM_PREFIX" ] && [ ! -L "$SDM_PREFIX/bin" ] ||
    inst_failed "The worker prefix and binary directory must be physical paths for safe replacement."
  kit_section "Backing up the foreign installation"
  inst_backup_foreign
  inst_replacement_probe_sealing
  kit_private_dir "$journal" || inst_failed "Cannot create the replacement journal."
  kit_on_exit inst_replacement_exit
  (umask 077; : > "$journal/units"; : > "$journal/paths") || inst_failed "Cannot initialize the replacement journal."
  local units=("${INST_FOREIGN_UNITS[@]}")
  if [ "$INST_OURS" = 1 ]; then units+=("$SDM_UNIT"); fi
  for u in "${units[@]}"; do
    state=$(kit_unit_prop "$u" ActiveState)
    case "$state" in active|inactive) ;; *) inst_failed "Wait for $u to settle before replacing it (state: ${state:-unknown}).";; esac
    [ "$(kit_unit_prop "$u" Id)" = "$u.service" ] || inst_failed "Resolve the systemd unit alias $u before replacement."
    if [ "$state" = active ]; then
      case "$(kit_unit_prop "$u" KillMode)" in control-group|mixed) ;; *) inst_failed "Cannot safely stop all processes in $u."; esac
    fi
    printf '%s|%s\n' "$u" "$state" >> "$journal/units" || inst_failed "Cannot record the state of $u."
  done
  if [ "$INST_OURS" != 1 ]; then
    for p in $(kit_unit_prop "$SDM_UNIT" DropInPaths); do
      case "$p" in
        "/etc/systemd/system/$SDM_UNIT.service.d/"*|*/systemd/system/service.d/*) ;;
        *) inst_failed "Review the inherited worker unit override at $p before replacement.";;
      esac
    done
    [ ! -e "/run/systemd/system/$SDM_UNIT.service" ] && [ ! -L "/run/systemd/system/$SDM_UNIT.service" ] ||
      inst_failed "Remove the runtime worker unit override before replacement."
  fi
  inst_replacement_links "$journal" > "$journal/links" || inst_failed "Cannot record unit enablement."
  while IFS='|' read -r path anchor; do
    kit_trusted_dir "$anchor" || inst_failed "Unsafe parent for replacement path $path."
    vault=$(mktemp -d "$anchor/.sdm-kit-replacement.XXXXXX") || inst_failed "Cannot protect the original at $path."
    present=no
    if [ -e "$path" ] || [ -L "$path" ]; then present=yes; fi
    printf '%s|%s|%s\n' "$path" "$vault" "$present" >> "$journal/paths" || inst_failed "Cannot record the original at $path."
    if [ "$present" = yes ]; then
      [ "$(stat -c %d -- "${path%/*}")" = "$(stat -c %d -- "$vault")" ] ||
        inst_failed "The replacement path $path must be on its parent's filesystem."
      if kit_have mountpoint && mountpoint -q -- "$path"; then inst_failed "Cannot preserve the mount point $path during replacement."; fi
    fi
  done < <(inst_replacement_paths)
  : > "$journal/pending" && sync || inst_failed "Cannot prepare rollback."
  for u in "${units[@]}"; do
    systemctl stop "$u" </dev/null >/dev/null 2>&1 || inst_failed "Cannot stop $u."
    [ "$(kit_unit_prop "$u" ActiveState)" = inactive ] || inst_failed "$u remained active after stopping it."
  done
  if [ -n "$(kit_find_node_procs)" ]; then
    inst_failed "A StrongDM process is still running. Use its original launch mechanism to stop it."
  fi
  if [ "$INST_OURS" != 1 ] && inst_replacement_worker_processes; then
    inst_failed "Other processes still run as $SDM_USER. Stop them with their original launch mechanism before sealing credentials."
  fi
  : > "$journal/switched" && sync || inst_failed "Cannot record the replacement switch."
  if [ "$INST_OURS" != 1 ]; then
    while IFS= read -rd '' link && IFS= read -rd '' target; do
      [ "${target##*/}" = "$SDM_UNIT.service" ] || continue
      kit_trusted_dir "${link%/*}" && rm -f -- "$link" || inst_failed "Cannot remove previous worker enablement."
    done < "$journal/links"
  fi
  while IFS='|' read -r path vault present; do
    [ "$present" = yes ] || continue
    inst_replacement_move "$path" "$vault" save || inst_failed "Cannot preserve the original at $path."
    if [ "$INST_OURS" = 1 ] || [ "$path" = "$SDM_PREFIX" ] || [ "$path" = "$INST_REPLACED_LIST" ]; then
      inst_replacement_move "$path" "$vault" copy || inst_failed "Cannot stage the existing files at $path."
    fi
  done < "$journal/paths"
}

inst_replacement_validate_worker() {
  [ -f "$KIT_DIR/replacement/pending" ] && [ "$INST_OURS" != 1 ] || return 0
  local command extended
  systemctl daemon-reload </dev/null || inst_failed "Cannot load the replacement worker definition."
  command=$(kit_unit_prop "$SDM_UNIT" ExecStart)
  extended=$(kit_unit_prop "$SDM_UNIT" ExecStartEx)
  [ "$(kit_unit_prop "$SDM_UNIT" User)" = "$SDM_USER" ] &&
    [[ $command == "{ path=$SDM_BIN ; argv[]=$SDM_BIN worker ; "* && $command != *"} {"* ]] &&
    [[ -z $extended || $extended == *"flags= ;"* ]] ||
    inst_failed "The effective worker definition does not run the verified binary as $SDM_USER."
}

inst_replacement_commit() {
  local journal="$KIT_DIR/replacement" u f d list
  [ -f "$journal/pending" ] || return 0
  list="$journal/new-replaced.list"
  (umask 077; : > "$list") || inst_failed "Cannot stage replacement history."
  if [ -f "$INST_REPLACED_LIST" ]; then cat "$INST_REPLACED_LIST" > "$list" || inst_failed "Cannot copy replacement history."; fi
  for u in "${INST_FOREIGN_UNITS[@]}"; do
    [ "$u" = "$SDM_UNIT" ] && continue
    [ "$(kit_unit_prop "$u" ActiveState)" = inactive ] || inst_failed "$u returned to service during replacement."
    systemctl disable "$u" </dev/null >/dev/null 2>&1 || inst_failed "Cannot disable $u."
    if [ "$(systemctl is-enabled "$u" 2>/dev/null </dev/null)" = enabled-runtime ]; then
      systemctl disable --runtime "$u" </dev/null >/dev/null 2>&1 || inst_failed "Cannot disable runtime enablement for $u."
    fi
    printf 'unit:%s\n' "$u" >> "$list" || inst_failed "Cannot record replacement of $u."
  done
  for f in "${INST_FOREIGN_ENVS[@]}"; do
    [ "$f" = "$SDM_SYSCONFIG" ] || printf 'env:%s\n' "$f" >> "$list" || inst_failed "Cannot record the replacement."
  done
  for d in "${INST_FOREIGN_DIRS[@]}"; do printf 'dir:%s\n' "$d" >> "$list" || inst_failed "Cannot record the replacement."; done
  mv -fT -- "$list" "$INST_REPLACED_LIST" && sync && : > "$journal/committed" && sync ||
    inst_failed "Cannot finalize the replacement."
  inst_replacement_cleanup "$journal" || warn "Committed replacement. Cleanup will retry on the next install."
}

# ============================================================================
# STEP 6: service user + SDM_HOME
# ============================================================================
inst_ensure_user() {
  local nl h grp=()
  if getent passwd "$SDM_USER" >/dev/null 2>&1; then
    h=$(inst_user_home "$SDM_USER")
    [ "$h" = "$SDM_USER_HOME" ] || kit_die $KIT_EXIT_PRECOND "User '$SDM_USER' exists but its home is '$h', not $SDM_USER_HOME." \
      "The kit always runs the worker as $SDM_USER with SDM_HOME=$SDM_HOME_DIR." "usermod -m -d $SDM_USER_HOME $SDM_USER
then re-run this kit"
    ok "user $SDM_USER exists (home $SDM_USER_HOME)"
  else
    [ ! -e "$SDM_USER_HOME" ] && [ ! -L "$SDM_USER_HOME" ] || inst_failed "Review the existing service home before creating the account."
    nl=$(inst_nologin)
    getent group "$SDM_USER" >/dev/null 2>&1 && grp=(-g "$SDM_USER")
    useradd -m -d "$SDM_USER_HOME" -s "$nl" -c "StrongDM proxy cluster worker" "${grp[@]}" "$SDM_USER" </dev/null \
      || kit_die $KIT_EXIT_FAIL "Could not create user $SDM_USER." "useradd failed (see above)." \
           "useradd -m -d $SDM_USER_HOME -s $nl -c 'StrongDM proxy cluster worker' $SDM_USER"
    if kit_have passwd; then passwd -l "$SDM_USER" >/dev/null 2>&1; else usermod -L "$SDM_USER" >/dev/null 2>&1; fi
    ok "created user $SDM_USER (home $SDM_USER_HOME, shell $nl, password locked)"
  fi
  [ ! -L "$SDM_USER_HOME" ] && [ -d "$SDM_USER_HOME" ] && [ "$(id -u "$SDM_USER")" != 0 ] || kit_die 3 "Unsafe service account or home directory." "" "Review $SDM_USER_HOME and the sdm account."
  [ "${1:-}" = account-only ] || inst_prepare_worker_home
}

inst_prepare_worker_home() {
  kit_as_worker "$SDM_HOME_DIR" mkdir -p -m 0700 "$SDM_HOME_DIR" && kit_as_worker "$SDM_HOME_DIR" chmod 0700 "$SDM_HOME_DIR" ||
    kit_die 3 "Worker cannot manage its state directory." "" "Inspect $SDM_HOME_DIR and its ownership offline."
  ok "$SDM_HOME_DIR is 0700 $SDM_USER:$(id -gn "$SDM_USER" 2>/dev/null)"
}

# ============================================================================
# STEP 7: binary (release JSON -> zip -> sha256 -> unzip -> --version)
# ============================================================================
# inst_fetch_release DOMAIN -> sets INST_REL_URL INST_REL_VERSION INST_REL_SHA; returns 1 on failure (INST_REL_ERR).
inst_fetch_release() {
  local jurl=$1 flat
  INST_REL_URL=""; INST_REL_VERSION=""; INST_REL_SHA=""; INST_REL_ERR=""
  [[ $jurl == https://* ]] || { INST_REL_ERR="release metadata requires HTTPS"; return 1; }
  kit_http GET "$jurl"
  if [ "$HE" != 0 ]; then INST_REL_ERR="curl exit $HE: $(printf '%s' "$HB" | head -1)"; return 1; fi
  [ "$HC" = 200 ] || { INST_REL_ERR="HTTP $HC"; return 1; }
  flat=$(printf '%s' "$HB" | json_flat)
  INST_REL_URL=$(jget "$flat" url); INST_REL_VERSION=$(jget "$flat" version); INST_REL_SHA=$(jget "$flat" sha256)
  INST_REL_SHA=$(printf '%s' "$INST_REL_SHA" | tr '[:upper:]' '[:lower:]')
  [ -n "$INST_REL_URL" ] || { INST_REL_ERR="no url in the release JSON"; return 1; }
  [[ $INST_REL_SHA =~ ^[0-9a-f]{64}$ ]] || { INST_REL_ERR="no valid sha256 in the release JSON"; return 1; }
  if [[ $INST_REL_URL != https://* || $INST_REL_URL == *[[:cntrl:]]* ]]; then INST_REL_ERR="release URL is not https"; return 1; fi
  return 0
}

inst_installed_version() { [ -x "$SDM_BIN" ] && kit_as_worker "$SDM_HOME_DIR" "$SDM_BIN" --version 2>/dev/null </dev/null | awk '$1=="sdm" && $2=="version" && $3~/^[0-9][0-9A-Za-z._+-]*$/{print $3; exit}'; }

# inst_download_verify -> sets INST_NEW_BIN (unzipped sdm in a root-only temp dir).
inst_download_verify() {
  local zip got out rc
  kit_private_dir "$KIT_DIR" && kit_private_dir "$KIT_DIR/tmp" \
    || kit_die $KIT_EXIT_FAIL "Cannot create $KIT_DIR/tmp." "" "mkdir -p $KIT_DIR/tmp; df -h $SDM_PREFIX"
  if [ -z "${INST_TMP:-}" ]; then
    INST_TMP=$(mktemp -d "$KIT_DIR/tmp/install.XXXXXX") || kit_die $KIT_EXIT_FAIL "mktemp failed in $KIT_DIR/tmp." "" "df -h $SDM_PREFIX"
    local q; printf -v q 'rm -rf -- %q' "$INST_TMP"; kit_on_exit "$q"
  fi
  zip="$INST_TMP/sdm.zip"
  info "downloading sdm $INST_REL_VERSION"
  curl -q -fsSL --proto "=https" --proto-redir "=https" --globoff --max-time 900 -o "$zip" --url "$INST_REL_URL" </dev/null 2>"$INST_TMP/curl.err"; rc=$?
  if [ $rc -ne 0 ]; then INST_DL_ERR="curl exit $rc: $(head -1 "$INST_TMP/curl.err")"; return 1; fi
  got=$(sha256sum "$zip" | awk '{print $1}')
  if [ "$got" != "$INST_REL_SHA" ]; then
    kit_die $KIT_EXIT_FAIL "Checksum mismatch for the downloaded sdm zip." \
"expected sha256 $INST_REL_SHA
got      sha256 $got
The download was corrupted or altered in transit (often a TLS-inspecting proxy serving an error page)." \
"curl -sI '$INST_REL_URL'          # check what is being served
re-run the kit; if it repeats, allow downloads.strongdm.com through your proxy without rewriting"
  fi
  ok "sha256 verified ($got)"
  [ "$(unzip -Z1 "$zip" | grep -cx sdm)" = 1 ] || inst_failed "The verified archive must contain one sdm executable."
  rm -rf "$INST_TMP/x"; mkdir -p "$INST_TMP/x"
  unzip -p "$zip" sdm > "$INST_TMP/x/sdm" </dev/null || kit_die $KIT_EXIT_FAIL "Could not unzip the sdm binary." "The zip passed its checksum but has no 'sdm' entry." "unzip -l $zip"
  rm -f "$zip"
  chmod 0755 "$INST_TMP/x/sdm"
  # Pass only a read-only descriptor into private staging to the unprivileged version probe.
  out=$(kit_run_unprivileged nobody env -i PATH=/usr/bin:/bin HOME=/nonexistent SDM_LOG_OUTPUT=stderr \
    timeout 20 /proc/self/fd/8 --version 8<"$INST_TMP/x/sdm" </dev/null 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    kit_die $KIT_EXIT_FAIL "The downloaded sdm binary will not run (exit $rc)." \
"$(printf '%s' "$out" | head -3)
Exit 126 usually means $SDM_PREFIX is on a noexec mount; 'Exec format error' means the wrong architecture." \
"findmnt -T $KIT_DIR/tmp -o TARGET,OPTIONS     # look for noexec
uname -m                                      # expect x86_64 or aarch64"
  fi
  [[ $out == *"$INST_REL_VERSION"* ]] || warn "binary reports '$out', expected version $INST_REL_VERSION"
  ok "binary runs: $out"
  INST_NEW_BIN="$INST_TMP/x/sdm"
}

inst_binary() {
  kit_step 6 $INST_TOTAL "StrongDM binary"
  local cur cands=() j fetched=0
  if [ "$INST_OURS" = 1 ]; then cur=$(inst_installed_version); fi
  [ -n "$cur" ] && info "installed: $SDM_BIN version $cur"
  cands=("https://$SDM_APP_DOMAIN/releases/upgrade?software=sdm-cli&os=linux&arch=$INST_ARCH")
  [ "$SDM_APP_DOMAIN" != app.strongdm.com ] && cands+=("https://app.strongdm.com/releases/upgrade?software=sdm-cli&os=linux&arch=$INST_ARCH")

  if [ "$INST_DO_INSTALL" = 0 ] && [ "$INST_NEED_BINARY" = 0 ]; then
    if inst_fetch_release "${cands[0]}" && [ -n "$INST_REL_VERSION" ]; then
      if [ "$INST_REL_VERSION" = "$cur" ]; then ok "installed version $cur is the latest; no download needed"
      else info "latest is $INST_REL_VERSION; keeping $cur (the kit does not swap the binary under a healthy worker)"; fi
    else
      info "could not look up the latest version (${INST_REL_ERR:-unknown}); keeping $cur"
    fi
    return 0
  fi

  for j in "${cands[@]}"; do
    if ! inst_fetch_release "$j"; then warn "release lookup failed at ${j%%\?*}: $INST_REL_ERR"; continue; fi
    fetched=1
    ok "latest sdm-cli for linux/$INST_ARCH: $INST_REL_VERSION"
    inst_download_verify && return 0
    warn "download failed: $INST_DL_ERR"
  done
  if [ $fetched = 0 ]; then
    kit_die $KIT_EXIT_FAIL "Could not look up the latest sdm release." "Last error: ${INST_REL_ERR:-unknown}" \
"curl -s '${cands[0]}'
check outbound HTTPS to $SDM_APP_DOMAIN (and any proxy settings), then re-run"
  fi
  kit_die $KIT_EXIT_FAIL "Could not download the sdm binary." "Last error: ${INST_DL_ERR:-unknown}" \
"curl -sSI '$INST_REL_URL'
allow outbound HTTPS to downloads.strongdm.com (or the regional downloads host), then re-run"
}

# ============================================================================
# STEP 8: sdm install (or in-place repair)
# ============================================================================
inst_failed() { kit_die $KIT_EXIT_FAIL "$1" "" "Correct the reported problem and re-run the kit."; }

# The service owns its self-updating CLI. Root never follows a path inside that tree.
inst_place_binary() {
  kit_trusted_dir /opt || inst_failed "Unsafe /opt directory."
  if [ ! -e "$SDM_PREFIX" ] && [ ! -L "$SDM_PREFIX" ]; then
    install -d -m 0755 -o "$SDM_USER" "$SDM_PREFIX" || inst_failed "Cannot create worker prefix."
  fi
  if kit_trusted_dir "$SDM_PREFIX" && { [ ! -e "$SDM_PREFIX/bin" ] || kit_trusted_dir "$SDM_PREFIX/bin"; }; then
    local tmp
    mkdir -p "$SDM_PREFIX/bin" || inst_failed "Cannot create binary directory."
    chmod 0755 "$SDM_PREFIX/bin" || inst_failed "Cannot set permissions on protected binary directory."
    tmp=$(mktemp "$SDM_PREFIX/bin/.sdm.XXXXXX") && install -m 0755 "$INST_NEW_BIN" "$tmp" &&
      mv -fT "$tmp" "$SDM_BIN" || inst_failed "Cannot install the verified binary."
  else
    kit_as_worker "$SDM_HOME_DIR" bash -c '
      set -eu
      mkdir -p -m 0755 "$1/bin"
      t=$(mktemp "$1/bin/.sdm.XXXXXX")
      trap '\''rm -f "$t"'\'' EXIT
      cat > "$t"; chmod 0755 "$t"; mv -fT "$t" "$1/bin/sdm"
    ' bash "$SDM_PREFIX" < "$INST_NEW_BIN" || inst_failed "Worker cannot update its binary."
  fi
}

inst_write_unit() {
  local unitdir=/etc/systemd/system tmp
  kit_trusted_dir "$unitdir" || inst_failed "Unsafe systemd unit directory."
  tmp=$(mktemp "$unitdir/.sdm-worker.XXXXXX") || inst_failed "Cannot stage unit."
  {
    printf '%s\n' '[Unit]' 'Description=StrongDM worker' 'After=network-online.target' 'Wants=network-online.target' '[Service]' \
      "User=$SDM_USER" "WorkingDirectory=$SDM_HOME_DIR" "ExecStart=$SDM_BIN worker" "EnvironmentFile=$SDM_SYSCONFIG" 'Restart=always' 'RestartSec=3'
    if [ "$(inst_bind_port "$INST_BIND")" -lt 1024 ]; then echo 'AmbientCapabilities=CAP_NET_BIND_SERVICE'; fi
    printf '%s\n' '[Install]' 'WantedBy=multi-user.target'
  } > "$tmp" && chmod 0644 "$tmp" && mv -fT "$tmp" "$unitdir/$SDM_UNIT.service" || inst_failed "Cannot install worker unit."
}

inst_seal_pair() {
  printf '%s\n%s\n' "$SDM_PROXY_CLUSTER_ACCESS_KEY" "$SDM_PROXY_CLUSTER_SECRET_KEY" |
    kit_as_worker "$SDM_HOME_DIR" "$SDM_BIN" nodesecrets set SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY >/dev/null 2>&1 ||
    inst_failed "Could not seal cluster credentials as the worker. Check machine identity and state-directory permissions."
  inst_sealed_keys && inst_sealed_has SDM_PROXY_CLUSTER_ACCESS_KEY && inst_sealed_has SDM_PROXY_CLUSTER_SECRET_KEY || inst_failed "Sealed cluster credentials could not be verified."
}

inst_write_environment() {
  local core managed tmp
  core=$(printf '%s\n' "SDM_HOME=$SDM_HOME_DIR" "SDM_APP_DOMAIN=$SDM_APP_DOMAIN" "SDM_BIND_ADDRESS=$INST_BIND" 'SDM_LOG_OUTPUT=stdout')
  managed='SDM_HOME SDM_APP_DOMAIN SDM_BIND_ADDRESS SDM_LOG_OUTPUT SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY'
  if [ "${INST_OURS:-0}" = 1 ] || [ "${INST_CLASS:-}" = NONE ]; then
    kit_envfile_update "$SDM_SYSCONFIG" "$managed" <<<"$core" || inst_failed "Cannot update worker environment."
  else
    tmp=$(mktemp "$SDM_SYSCONFIG.XXXXXX") || inst_failed "Cannot stage worker environment."
    if ! {
      printf '%s\n' "$core" &&
      { [ ${#INST_PREV_ENV[@]} -eq 0 ] || printf '%s\n' "${INST_PREV_ENV[@]}"; }
    } > "$tmp" || ! mv -fT "$tmp" "$SDM_SYSCONFIG"; then
      rm -f -- "$tmp"; inst_failed "Cannot install worker environment."
    fi
  fi
}

inst_run_install() {
  inst_place_binary
  if [ "${INST_SIDECAR_BAD:-0}" = 1 ]; then
    kit_as_worker "$SDM_HOME_DIR" mv -T "$SDM_SIDECAR" "$SDM_SIDECAR.unreadable-$(date +%s)" || inst_failed "Cannot preserve unreadable sidecar."
  fi
  inst_seal_pair
  kit_as_worker "$SDM_HOME_DIR" bash -c 'umask 077; touch "$1/state.kv" "$1/sdm.log"' bash "$SDM_HOME_DIR" || inst_failed "Worker state is inaccessible."
  inst_write_environment
  inst_write_unit
  inst_state_set KEY_FP "$(inst_key_fp)" || inst_failed "Cannot save installation state."
  inst_state_set APP_DOMAIN "$SDM_APP_DOMAIN" && inst_state_set BIND "$INST_BIND" || inst_failed "Cannot save worker settings."
  INST_NEED_RESTART=1
}

inst_repair() {
  local f
  if [ "$INST_NEED_BINARY" = 1 ]; then inst_mark_pending; inst_place_binary; fi
  for f in "$SDM_HOME_DIR" "$SDM_HOME_DIR/state.kv" "$SDM_SIDECAR"; do
    [ -e "$f" ] || continue
    [ "$(stat -c %U "$f")" = "$SDM_USER" ] || inst_failed "Unexpected ownership of $f. Review the file offline before repairing its ownership."
  done
  if [ "${INST_PLAINTEXT_KEYS:-0}" = 1 ] && ! { inst_sealed_has SDM_PROXY_CLUSTER_ACCESS_KEY && inst_sealed_has SDM_PROXY_CLUSTER_SECRET_KEY; }; then
    inst_mark_pending
    inst_seal_pair
  fi
  if [ "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_LOG_OUTPUT)" != stdout ]; then
    inst_mark_pending
    kit_envfile_set "$SDM_SYSCONFIG" SDM_LOG_OUTPUT stdout || inst_failed "Cannot set SDM_LOG_OUTPUT."
    ok "set SDM_LOG_OUTPUT=stdout"
  fi
  if [ -z "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_HOME)" ]; then
    inst_mark_pending
    kit_envfile_set "$SDM_SYSCONFIG" SDM_HOME "$SDM_HOME_DIR" || inst_failed "Cannot set SDM_HOME."
    ok "set SDM_HOME=$SDM_HOME_DIR"
  fi
  if [ "${INST_PLAINTEXT_KEYS:-0}" = 1 ] && inst_sealed_has SDM_PROXY_CLUSTER_ACCESS_KEY && inst_sealed_has SDM_PROXY_CLUSTER_SECRET_KEY; then
    inst_mark_pending
    kit_envfile_unset "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_ACCESS_KEY && kit_envfile_unset "$SDM_SYSCONFIG" SDM_PROXY_CLUSTER_SECRET_KEY || inst_failed "Cannot remove plaintext cluster keys."
    ok "removed plaintext proxy cluster keys from $SDM_SYSCONFIG (the sealed copies are used)"
  fi
  [ ${#INST_REPAIRS[@]} -eq 0 ] && ok "nothing to repair"
  [ -z "$(inst_state_get KEY_FP)" ] && [ "$INST_KEYS_UNKNOWN" = 0 ] && [ "${INST_PLAINTEXT_KEYS:-0}" = 1 ] && inst_state_set KEY_FP "$(inst_key_fp)"
  return 0
}

# ============================================================================
# STEP 9: env file
# ============================================================================
inst_envfile() {
  kit_step 9 $INST_TOTAL "Worker environment file $SDM_SYSCONFIG"
  local cur
  [ -f "$SDM_SYSCONFIG" ] || kit_die $KIT_EXIT_FAIL "$SDM_SYSCONFIG is missing after install." "" "re-run this kit"
  if [ -n "${DELINEA_SERVER_URL:-}" ]; then
    cur=$(kit_envfile_get "$SDM_SYSCONFIG" DELINEA_SERVER_URL)
    if [ "$cur" != "$DELINEA_SERVER_URL" ]; then
      inst_mark_pending
      kit_envfile_set "$SDM_SYSCONFIG" DELINEA_SERVER_URL "$DELINEA_SERVER_URL" || inst_failed "Cannot write Delinea URL."
    fi
    ok "DELINEA_SERVER_URL=$DELINEA_SERVER_URL"
  fi
  if [ "$(stat -c %u:%a "$SDM_SYSCONFIG")" != 0:600 ]; then
    kit_envfile_set "$SDM_SYSCONFIG" SDM_LOG_OUTPUT stdout || inst_failed "Cannot secure the worker environment."
  fi
  ok "env file keys: $(inst_env_keys "$SDM_SYSCONFIG")(values not shown)"
}

# ============================================================================
# STEP 10: seal Delinea credentials
# ============================================================================
inst_seal() {
  kit_step 10 $INST_TOTAL "Seal Delinea Secret Server credentials"
  if [ "$INST_DELINEA" != yes ]; then
    if kit_envfile_has "$SDM_SYSCONFIG" DELINEA_PASSWORD; then inst_failed "Plaintext Delinea credentials remain. Enable Delinea provisioning to seal them."; fi
    info "Delinea Secret Server not used; skipped"; return 0
  fi
  if [ "${INST_ROTATE_DELINEA:-no}" = no ] && inst_delinea_sealed; then
    ok "existing sealed Delinea credentials retained"
  else
    [ "${INST_KEEP_DELINEA:-0}" = 0 ] || inst_failed "The previously sealed Delinea pair is unavailable. Re-run with credentials to provision it."
    inst_mark_pending
    if ! printf '%s\n%s\n' "$DELINEA_USERNAME" "$DELINEA_PASSWORD" |
      kit_as_worker "$SDM_HOME_DIR" "$SDM_BIN" nodesecrets set DELINEA_USERNAME DELINEA_PASSWORD >/dev/null 2>&1; then
      inst_failed "Could not seal the supplied Delinea credentials as the service user."
    fi
    inst_delinea_sealed || inst_failed "The new Delinea pair could not be verified in sealed storage."
    ok "sealed: DELINEA_USERNAME, DELINEA_PASSWORD"
  fi
  [ "$(stat -c %U "$SDM_SIDECAR")" = "$SDM_USER" ] || inst_failed "Unexpected sealed file owner."
  if kit_envfile_has "$SDM_SYSCONFIG" DELINEA_USERNAME || kit_envfile_has "$SDM_SYSCONFIG" DELINEA_PASSWORD; then
    inst_mark_pending
    kit_envfile_update "$SDM_SYSCONFIG" "DELINEA_USERNAME DELINEA_PASSWORD" </dev/null || inst_failed "Cannot remove plaintext Delinea credentials."
    ok "removed plaintext DELINEA_USERNAME/DELINEA_PASSWORD from $SDM_SYSCONFIG"
  fi
}

# ============================================================================
# STEP 11: start and wait for the worker
# ============================================================================
inst_live_invocation() {
  local props key value state substate pid started invocation ticks
  local fields=(-p ActiveState -p SubState -p MainPID -p ExecMainStartTimestampMonotonic)
  # systemd 219 returns an error when any requested property is unknown.
  props=$(systemctl show "$SDM_UNIT" "${fields[@]}" -p InvocationID 2>/dev/null </dev/null) ||
    props=$(systemctl show "$SDM_UNIT" "${fields[@]}" 2>/dev/null </dev/null) || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      ActiveState) state=$value;;
      SubState) substate=$value;;
      MainPID) pid=$value;;
      InvocationID) invocation=$value;;
      ExecMainStartTimestampMonotonic) started=$value;;
    esac
  done <<<"$props"
  [ "${state:-}" = active ] && [ "${substate:-}" = running ] && [[ ${pid:-} =~ ^[1-9][0-9]*$ ]] || return 1
  ticks=$(inst_pid_start "$pid"); [ -n "$ticks" ] || return 1
  if ! [[ ${invocation:-} =~ ^[0-9a-f]{32}$ && $invocation != 00000000000000000000000000000000 ]]; then
    invocation=""
    [[ ${started:-} =~ ^[1-9][0-9]*$ ]] || return 1
  fi
  printf '%s|%s|%s|%s\n' "$pid" "$ticks" "${started:-}" "$invocation"
}

inst_invocation_messages() {
  local pid _ started invocation
  IFS='|' read -r pid _ started invocation <<<"$1"
  local args=(-b --no-pager "_SYSTEMD_UNIT=$SDM_UNIT.service")
  if [ -n "$invocation" ]; then
    journalctl "${args[@]}" -o cat "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null </dev/null
  else
    # systemd 219 lacks invocation IDs. The current boot, main PID and
    # microsecond start boundary keep entries from earlier uses of the PID out.
    LC_ALL=C journalctl "${args[@]}" -o short-monotonic "_PID=$pid" 2>/dev/null </dev/null |
      LC_ALL=C awk -v started="$started" 'match($0, /^\[[[:space:]]*[0-9]+\.[0-9]+\]/) {
        stamp = substr($0, 2, RLENGTH - 2)
        sub(/^[[:space:]]+/, "", stamp)
        sub(/\./, "", stamp)
        if (stamp + 0 >= started) print
      }'
  fi
}

inst_start() {
  kit_step 11 $INST_TOTAL "Start $SDM_UNIT and wait for it to connect"
  local since="" timeout=${KIT_START_TIMEOUT:-90} t=0 st invocation ready nres nres0
  [ "$timeout" -ge 0 ] 2>/dev/null || inst_failed "KIT_START_TIMEOUT must be a nonnegative number of seconds."
  inst_read_pending
  [ "$INST_PENDING" != provision ] || inst_failed "Worker provisioning is incomplete."
  systemctl daemon-reload </dev/null || inst_failed "Cannot reload systemd worker configuration."
  systemctl enable "$SDM_UNIT" </dev/null >/dev/null 2>&1 || kit_die $KIT_EXIT_FAIL "systemctl enable $SDM_UNIT failed." "" "systemctl enable $SDM_UNIT; systemctl status $SDM_UNIT"
  ok "$SDM_UNIT enabled at boot"
  st=$(kit_unit_prop "$SDM_UNIT" ActiveState)
  if [[ $st != active && $st != activating && $st != reloading ]] || [ -n "$INST_PENDING" ] || [ "${INST_NEED_RESTART:-0}" = 1 ]; then
    since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl reset-failed "$SDM_UNIT" </dev/null >/dev/null 2>&1 || true
    if [ "$st" = active ]; then
      warn "restarting $SDM_UNIT to apply changes (this worker's active sessions drop; clients reconnect via other workers)"
    fi
    systemctl restart "$SDM_UNIT" </dev/null || inst_start_failed "$since" ""
  else
    info "checking readiness of the active $SDM_UNIT without restarting it"
  fi
  nres0=$(kit_unit_prop "$SDM_UNIT" NRestarts)
  info "waiting up to ${timeout}s for 'running proxy worker' and 'initial authsync complete' in the current invocation"
  while :; do
    if invocation=$(inst_live_invocation); then
      ready=$(inst_invocation_messages "$invocation" | awk '
        /running proxy worker/ { running = 1 }
        /initial authsync complete/ { auth = 1 }
        running && auth { print "ready"; exit }
      ') || true
      # Recheck after reading the journal in case systemd replaced the worker.
      if [ "$ready" = ready ] && [ "$(inst_live_invocation)" = "$invocation" ]; then
        if [ -n "$INST_PENDING" ]; then
          sync && rm -f -- "$INST_PENDING_FILE" || inst_failed "Cannot clear pending worker activation."
          INST_PENDING=""
        fi
        INST_NEED_RESTART=0
        ok "$SDM_UNIT is active: running proxy worker, initial authsync complete (${t}s)"
        [ -n "$since" ] || ok "$SDM_UNIT kept running"
        return 0
      fi
    fi
    [ "$t" -lt "$timeout" ] || break
    if [ -n "$since" ] && [ "$(kit_unit_prop "$SDM_UNIT" ExecMainStatus)" = 203 ]; then break; fi
    nres=$(kit_unit_prop "$SDM_UNIT" NRestarts)
    if [[ $nres =~ ^[0-9]+$ && $nres0 =~ ^[0-9]+$ ]] && [ $((nres - nres0)) -ge 3 ]; then break; fi
    sleep 1; t=$((t+1))
  done
  inst_start_failed "$since" "$invocation"
}

inst_start_failed() {
  local since=$1 invocation=${2:-} j port why fix what="$SDM_UNIT did not come up."
  port=$(inst_bind_port "$INST_BIND")
  info "Use journalctl locally to inspect detailed worker errors."
  if [ -n "$since" ]; then
    j=$(journalctl -b -u "$SDM_UNIT" --since "$since" --no-pager -o cat 2>/dev/null </dev/null; systemctl status "$SDM_UNIT" --no-pager 2>/dev/null </dev/null)
  else
    what="Readiness of $SDM_UNIT could not be verified."
    j=""
    if [ -n "$invocation" ]; then j=$(inst_invocation_messages "$invocation"); fi
  fi
  j=$(printf '%s' "$j" | tr '[:upper:]' '[:lower:]')
  if [[ $j == *"203/exec"* ]]; then
    why="systemd could not execute $SDM_BIN (203/EXEC): SELinux label or a noexec mount."
    fix="ls -Z $SDM_BIN; inspect the host SELinux policy and mount options
findmnt -T $SDM_BIN -o TARGET,OPTIONS     # must not be noexec"
  elif [[ $j == *"address already in use"* || $j == *"cannot bind"* ]]; then
    why="Port $port is already in use, so the worker cannot listen on $INST_BIND."
    fix="ss -ltnp 'sport = :$port'      # find the other program
stop it, or re-run with export SDM_BIND_ADDRESS=:8444"
  elif [[ $j == *"invalid proxy cluster key"* || $j == *"proxy cluster key authentication"* ||
          $j == *"proxyclusterkey"* || $j == *"unauthenticated"* || $j == *"unauthorized"* ||
          $j == *"invalid credentials"* || $j == *"invalid access key"* || $j == *"authentication failed"* ]]; then
    why="The control plane rejected the proxy cluster keys (wrong key, deleted key, or another region)."
    fix="Admin UI > Networking > Proxy Clusters > your cluster: create a new key pair
re-run this kit with the new keys (it re-installs when the keys change)"
  elif [[ $j == *"no such host"* || $j == *"i/o timeout"* || $j == *"connection refused"* || $j == *"dial tcp"* || $j == *"x509"* || $j == *"tls:"* || $j == *"deadline exceeded"* ]]; then
    why="The worker cannot reach the control plane at $SDM_APP_DOMAIN (DNS, firewall, proxy or TLS inspection)."
    fix="curl -sv https://$SDM_APP_DOMAIN/ -o /dev/null
allow outbound 443 to $SDM_APP_DOMAIN; for a proxy add HTTPS_PROXY=... to $SDM_SYSCONFIG and systemctl restart $SDM_UNIT"
  elif [[ $j == *"secretenv: read source"* || $j == *"secretenv: decrypt"* || $j == *"secretenv: parse"* ]]; then
    why="The worker could not read its sealed secrets file."
    fix="runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets list
ls -l $SDM_SIDECAR      # must be owned by $SDM_USER"
  else
    why="The current worker invocation did not provide both startup messages within ${KIT_START_TIMEOUT:-90}s. Inspect the local journal."
    fix="journalctl -u $SDM_UNIT -f
run this kit again and choose 2 (debug) for verbose logs"
  fi
  kit_die $KIT_EXIT_FAIL "$what" "$why" "$fix"
}

# ============================================================================
# STEP 12: no secret left behind
# ============================================================================
inst_verify_scrub() {
  kit_step 12 $INST_TOTAL "Check that no secret was left in plaintext"
  local v leaked=0
  for v in SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY DELINEA_PASSWORD; do
    [ -n "${!v:-}" ] || continue
    if inst_file_contains "$SDM_SYSCONFIG" "${!v}"; then
      fail "$v is present in plaintext in the worker environment file"; leaked=1
    fi
    if [ -n "${KIT_LOG_FILE:-}" ] && inst_file_contains "$KIT_LOG_FILE" "${!v}"; then fail "$v value found in the transcript $KIT_LOG_FILE"; leaked=1; fi
  done
  [ $leaked = 0 ] && ok "no secret values in $SDM_SYSCONFIG${KIT_LOG_FILE:+ or the transcript}"
  info "secret variables are wiped from this shell when the kit exits"
  [ "$leaked" = 0 ]
}

# ============================================================================
# STEP 13: summary
# ============================================================================
inst_final() {
  kit_step 13 $INST_TOTAL "Summary"
  local port ver st en sealed fw=""
  port=$(inst_bind_port "$INST_BIND")
  ver=$(inst_installed_version); st=$(kit_unit_prop "$SDM_UNIT" ActiveState); en=$(systemctl is-enabled "$SDM_UNIT" 2>/dev/null </dev/null)
  inst_sealed_keys >/dev/null 2>&1; sealed=$(kit_trim "${INST_SEALED_KEYS:-}")
  if kit_have firewall-cmd && [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then
    firewall-cmd --query-port="$port/tcp" >/dev/null 2>&1 || fw="firewall-cmd --permanent --add-port=$port/tcp && firewall-cmd --reload"
  elif kit_have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw status 2>/dev/null | grep -qE "^$port(/tcp)?[[:space:]]" || fw="ufw allow $port/tcp"
  fi
  printf '\n%s+----------------------------------------------------------------------+%s\n' "$C_ACC" "$C_RST"
  printf '%s|%s %s%-68s%s\n' "$C_ACC" "$C_RST" "$C_HEAD" "Proxy cluster worker installed" "$C_RST"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "result" "$INST_CLASS -> $([ "$INST_DO_INSTALL" = 1 ] && echo installed || echo kept/repaired)"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "user" "$SDM_USER (home $SDM_USER_HOME)"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "SDM_HOME" "$SDM_HOME_DIR"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "binary" "$SDM_BIN ${ver:-?}"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "unit" "$SDM_UNIT: $st, ${en:-?}"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "region / bind" "$SDM_APP_DOMAIN / $INST_BIND"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "sealed keys" "${sealed:-none}"
  [ -n "${INST_BACKUP_PATH:-}" ] && printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "backup" "$INST_BACKUP_PATH"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "logs" "journalctl -u $SDM_UNIT -f"
  printf '%s|%s %-20s %s\n' "$C_ACC" "$C_RST" "verify" "run this kit again and choose 3 to verify"
  printf '%s+----------------------------------------------------------------------+%s\n' "$C_ACC" "$C_RST"
  if [ -n "$fw" ]; then
    warn "the host firewall is active and port $port/tcp is not open; clients cannot reach this worker"
    note "$fw"
  fi
  kit_summary
}

# ============================================================================
# mode_install
# ============================================================================
mode_install() {
  INST_DO_INSTALL=0; INST_NEED_RESTART=0; INST_TMP=""; INST_NEW_BIN=""; INST_BACKUP_PATH=""
  kit_log_init install
  kit_banner "New install - install or repair a proxy cluster worker"
  inst_preflight
  kit_lock_changes
  # A killed debug shell releases the kit lock while its expiry timer stays armed.
  if declare -F dbg_recover_sessions >/dev/null; then
    dbg_recover_sessions || inst_failed "Cannot finish the interrupted debug session before changing the worker."
  fi
  inst_replacement_recover || inst_failed "The previous replacement could not be restored. Inspect the rollback journal in $KIT_DIR/replacement before retrying."
  inst_read_pending
  if [ -e "$SDM_SYSCONFIG" ] || [ -L "$SDM_SYSCONFIG" ]; then
    kit_trusted_file "$SDM_SYSCONFIG" || inst_failed "Review ownership and permissions on the existing worker environment before installation."
  fi
  inst_collect
  inst_deps
  inst_reach
  inst_report_and_decide
  if { [ "${INST_OURS:-0}" = 1 ] || [ "$INST_CLASS" = NONE ]; } &&
     { [ "$INST_DO_INSTALL" = 1 ] || [ "${INST_ROTATE_DELINEA:-no}" = yes ] || { [ "$INST_DELINEA" = yes ] && [ "$INST_KEEP_DELINEA" = 0 ]; }; } &&
     [ -n "$(inst_strip_quotes "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_SECRETS_FILE)")" ]; then
    inst_failed "SDM_SECRETS_FILE selects an external credential source. Update credentials there, or remove the setting to provision sealed credentials with the kit."
  fi
  inst_binary
  kit_step 7 $INST_TOTAL "Prepare account and replace approved foreign installs"
  mkdir -p /etc/sysconfig && kit_trusted_dir /etc/sysconfig || inst_failed "Unsafe worker environment directory."
  [ ! -L "$SDM_SYSCONFIG" ] || inst_failed "Worker environment file is a symbolic link."
  if [ "$INST_DELINEA" != yes ] && kit_envfile_has "$SDM_SYSCONFIG" DELINEA_PASSWORD; then inst_failed "Enable Delinea provisioning to migrate existing plaintext credentials."; fi
  inst_ensure_user account-only
  inst_replace_foreign
  inst_prepare_worker_home
  if [ "$INST_DO_INSTALL" = 1 ]; then
    kit_step 8 $INST_TOTAL "Provision the worker and seal cluster credentials"
    inst_mark_pending provision
    inst_run_install
    inst_mark_pending activate
  else
    kit_step 8 $INST_TOTAL "Repair the existing worker in place"
    inst_repair
  fi
  inst_envfile
  inst_seal
  local k
  for k in SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY DELINEA_PASSWORD; do
    kit_envfile_has "$SDM_SYSCONFIG" "$k" && inst_failed "Plaintext $k remains in the worker environment file."
  done
  inst_replacement_validate_worker
  inst_start
  inst_verify_scrub || inst_failed "A plaintext credential remains after installation."
  inst_replacement_commit
  inst_final
}

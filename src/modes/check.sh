# shellcheck shell=bash
# ============================================================================
# sdm-proxy-cluster-kit :: src/modes/check.sh   (mode_check - READ-ONLY)
#
# Never changes the system: no writes outside the kit's own transcript, no
# service restarts, no package installs. Every fix is printed, not applied.
#
# Sections:
#   1 Host and runtime      2 Install layout       3 Connectivity
#   4 Recent logs           5 Delinea secret store  6 Summary + likely problems
#
# ============================================================================
# @env KIT_CHECK_DELINEA  yes|no - run or skip the Delinea section without asking (default: run when any DELINEA_* setting is found)
# @env KIT_DELINEA_SERVER_URL  Trusted HTTPS server URL supplied by the operator for live checks
# @env KIT_DELINEA_USERNAME_PATH  the resource's username secret path, e.g. 1234?key=Username (empty = skip)
# @env KIT_DELINEA_PASSWORD_PATH  the resource's password secret path, e.g. 1234?key=Password (empty = skip)
# @env KIT_RDP_HOST  RDP target host[:port] to test TCP reachability from this worker (empty = skip)
# @env KIT_DELINEA_SVC_USERNAME  service-account username, used only when DELINEA_USERNAME is sealed (unreadable by design)
# @env KIT_DELINEA_SVC_PASSWORD  service-account password, used only when DELINEA_PASSWORD is sealed; never printed
# @env KIT_DELINEA_CA_FILE  Optional operator-approved CA bundle for live authentication
# @env KIT_DELINEA_LIVE  yes = enable live authentication to the explicitly supplied HTTPS server; default no
# @env KIT_DELINEA_VAULT_URL  Trusted HTTPS vault URL from the Admin UI for Platform checks
# @env HTTPS_PROXY  the operator shell's proxy (also https_proxy/HTTP_PROXY/http_proxy/NO_PROXY/no_proxy); replaced by the worker's own proxy settings so the checks see what the worker sees

# ---------------------------------------------------------------- state
chk_reset() {
  CHK_PID=""; CHK_PUSER=""; CHK_PEXE=""; CHK_PCWD=""; CHK_PSTART=""; CHK_PROCS=""
  CHK_ENVFILE=$SDM_SYSCONFIG; CHK_HOME=""; CHK_HOME_SRC=""
  CHK_SYSTEMD=0; CHK_CONTAINER=0; CHK_ROOT=0; CHK_UNIT=0; CHK_ENVREAD=0
  CHK_SECRETS_FILE=""; CHK_MOUNT_KEYS=""; CHK_MOUNT_FLAT=""; CHK_SEALED_KEYS=""; CHK_SEALED_OK=0
  CHK_STRAY_KEYS=""; CHK_APP_DOMAIN=""; CHK_APP_SRC=""; CHK_WPROXY=""; CHK_SHELL_PROXY=""
  CHK_VERSION=""
  CHK_PSEV=(); CHK_PROBS=(); CHK_FIXES=()
}

# chk_fail/chk_warn "message" "fix command(s), one per line" -> also recorded for the
# "most likely problems" list at the end.
chk_fail() { fail "$1"; CHK_PSEV+=(FAIL); CHK_PROBS+=("$1"); CHK_FIXES+=("${2:-}"); }
chk_warn() { warn "$1"; CHK_PSEV+=(WARN); CHK_PROBS+=("$1"); CHK_FIXES+=("${2:-}"); }

chk_penv() { [ -n "$CHK_PID" ] && kit_proc_env "$CHK_PID" "$1"; }
chk_unquote() { local v=$1
  if [[ $v == \'*\' && ${#v} -ge 2 ]]; then v=${v:1:${#v}-2}; elif [[ $v == \"*\" && ${#v} -ge 2 ]]; then v=${v:1:${#v}-2}; fi
  printf '%s' "$v"; }
# chk_cfg KEY -> the value the running worker sees (its environ when readable, else the env file).
chk_cfg() { local v
  if [ "$CHK_ENVREAD" = 1 ]; then kit_proc_env "$CHK_PID" "$1"; return; fi
  v=$(kit_envfile_get "$CHK_ENVFILE" "$1") || return 1
  chk_unquote "$v"; }
chk_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
chk_ts() { date -d "@$1" '+%F %T' 2>/dev/null || echo "$1"; }
chk_changed_after_start() { [ -n "$CHK_PSTART" ] && [ "$(chk_mtime "$1")" -gt $((CHK_PSTART + 2)) ]; }
chk_is_secret_key() {
  case $1 in *SECRET*|*PASSWORD*|*PASSWD*|*TOKEN*|*ACCESS_KEY*|*PRIVATE*|*CREDENTIAL*|*_KEY) return 0;; esac
  return 1; }
chk_realpath() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
chk_in_list() { [[ " $2 " == *" $1 "* ]]; }   # chk_in_list WORD "space separated list"

# ---------------------------------------------------------------- discovery (silent)
chk_discover() {
  local pid user role exe cwd st mp="" ef v
  kit_is_root && CHK_ROOT=1
  kit_in_container && CHK_CONTAINER=1
  kit_has_systemd && CHK_SYSTEMD=1
  if [ "$CHK_SYSTEMD" = 1 ] && kit_unit_exists "$SDM_UNIT"; then
    CHK_UNIT=1
    mp=$(kit_unit_main_pid "$SDM_UNIT")
    ef=$(kit_unit_prop "$SDM_UNIT" EnvironmentFiles); ef=${ef%% *}; ef=${ef#-}
    [ -n "$ef" ] && CHK_ENVFILE=$ef
  fi
  CHK_PROCS=$(kit_find_node_procs)
  while IFS='|' read -r pid user role exe cwd st; do
    [ "$role" = worker ] && [[ $pid =~ ^[0-9]+$ && $st =~ ^[0-9]{1,12}$ ]] || continue
    if [ -z "$CHK_PID" ] || [ "$pid" = "$mp" ]; then
      CHK_PID=$pid; CHK_PUSER=$user; CHK_PEXE=$exe; CHK_PCWD=$cwd; CHK_PSTART=$st
    fi
  done <<<"$CHK_PROCS"
  [ -n "$CHK_PID" ] && [ -r "/proc/$CHK_PID/environ" ] && CHK_ENVREAD=1
  # SDM_HOME as the worker resolves it: env, else its cwd (service).
  if v=$(chk_penv SDM_HOME) && [ -n "$v" ]; then CHK_HOME=$v; CHK_HOME_SRC="worker environment SDM_HOME"
  elif [ "$CHK_ENVREAD" = 1 ] && [ -n "$CHK_PCWD" ]; then CHK_HOME=$CHK_PCWD; CHK_HOME_SRC="worker working directory (SDM_HOME unset)"
  elif v=$(kit_envfile_get "$CHK_ENVFILE" SDM_HOME); then CHK_HOME=$(chk_unquote "$v"); CHK_HOME_SRC="$CHK_ENVFILE"
  elif [ -n "$CHK_PCWD" ]; then CHK_HOME=$CHK_PCWD; CHK_HOME_SRC="worker working directory"
  else CHK_HOME=$SDM_HOME_DIR; CHK_HOME_SRC="kit standard (no worker found)"; fi
  if v=$(chk_cfg SDM_APP_DOMAIN) && [ -n "$v" ]; then CHK_APP_DOMAIN=$v; CHK_APP_SRC="SDM_APP_DOMAIN"
  else CHK_APP_DOMAIN=${KIT_APP_DOMAINS[0]}; CHK_APP_SRC="default (SDM_APP_DOMAIN unset)"; fi
  # Make every network check below use the worker's proxy settings, not the operator's.
  CHK_SHELL_PROXY=${HTTPS_PROXY:-${https_proxy:-}}
  unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do
    ef=$(chk_cfg "$v") && [ -n "$ef" ] && export "$v=$ef"
  done
  CHK_WPROXY=${HTTPS_PROXY:-${https_proxy:-}}
}

# ---------------------------------------------------------------- 1 host
chk_host() {
  local m n out
  kit_section "1. Host and runtime"
  kit_detect_os
  info "OS $OS_PRETTY (family $OS_FAMILY), arch $(uname -m), kernel $(uname -r), bash $BASH_VERSION"
  [ "$OS_FAMILY" = unknown ] && chk_warn "OS family not recognised; the kit targets RHEL/Rocky/Alma 7-9, Amazon Linux 2/2023, Ubuntu/Debian" ""
  if [ "$CHK_ROOT" = 1 ]; then ok "running as root"
  else chk_warn "not running as root: the worker's environment, sealed secrets and journal may be unreadable, so some checks are incomplete" "sudo -i      # then re-run the kit and choose Check"; fi
  if [ "$CHK_CONTAINER" = 1 ]; then
    info "inside a container: settings are read from the worker's process environment and SDM_SECRETS_FILE"
  fi
  if [ "$CHK_SYSTEMD" = 1 ]; then ok "systemd present ($(systemctl --version 2>/dev/null </dev/null | head -1))"
  elif [ "$CHK_CONTAINER" = 1 ]; then info "no systemd (normal in a container); unit and journal checks are skipped"
  else chk_fail "systemd is not running; the worker is installed as a systemd unit" "use a systemd host (RHEL/Rocky/Alma 7-9, Amazon Linux 2/2023, Ubuntu/Debian)"; fi
  m=$(kit_selinux_mode)
  case $m in
    Enforcing) info "SELinux: Enforcing";;
    Permissive) info "SELinux: Permissive (denials are logged, not enforced)";;
    *) info "SELinux: ${m:-not installed}";;
  esac
  if [ "$m" != Disabled ] && [ -n "$m" ] && kit_have ausearch && [ "$CHK_ROOT" = 1 ]; then
    out=$(ausearch -m avc,user_avc -ts today -i 2>/dev/null </dev/null | grep -iE 'sdm|strongdm' | grep -i 'avc')
    n=$(printf '%s' "$out" | grep -c . )
    if [ "${n:-0}" -gt 0 ]; then
      chk_warn "$n SELinux AVC denial(s) today mention sdm/strongdm" "ausearch -m avc -ts today -i | grep -i sdm      # read them
Review the path labels and local policy with the host administrator."
    else ok "no SELinux AVC denials mentioning sdm today"; fi
  fi
  chk_clock
}

chk_clock() {
  local hdr e now d
  if ! kit_have curl; then info "curl is not installed: clock skew not checked"; return; fi
  hdr=$(curl -q --globoff --proto "=https" -sSI -m 15 "https://$CHK_APP_DOMAIN/" 2>/dev/null </dev/null | tr -d '\r' | awk 'tolower($1)=="date:"{sub(/^[^:]*:[ ]*/,""); print; exit}')
  if [ -z "$hdr" ]; then info "could not read the time from https://$CHK_APP_DOMAIN (see section 3); clock skew not checked"; return; fi
  e=$(date -d "$hdr" +%s 2>/dev/null) || { info "unparseable Date header '$hdr'"; return; }
  now=$(date +%s); d=$((now - e)); [ $d -lt 0 ] && d=$((-d))
  if [ $d -le 30 ]; then ok "clock is within ${d}s of $CHK_APP_DOMAIN"
  else
    local fixc="timedatectl set-ntp true          # systemd hosts
chronyc makestep                    # step the clock now (chrony)"
    if [ $d -le 120 ]; then chk_warn "clock is ${d}s off from $CHK_APP_DOMAIN" "$fixc"
    else chk_fail "clock is ${d}s off from $CHK_APP_DOMAIN; TLS and token validation can fail" "$fixc"; fi
  fi
}

# ---------------------------------------------------------------- 2 layout
chk_layout() {
  kit_section "2. Install layout (kit standard: unit $SDM_UNIT, user $SDM_USER, SDM_HOME=$SDM_HOME_DIR)"
  chk_user
  chk_unit
  chk_binary
  chk_procs
  chk_envfile
  chk_homes
  chk_secretsrc
  chk_stray
  chk_other_units
}

chk_user() {
  local pw home
  pw=$(getent passwd "$SDM_USER" 2>/dev/null || awk -F: -v u="$SDM_USER" '$1==u' /etc/passwd)
  if [ -z "$pw" ]; then
    if [ "$CHK_CONTAINER" = 1 ]; then info "no '$SDM_USER' user (normal in a container image)"
    else chk_fail "user '$SDM_USER' does not exist" "bash $KIT_DIR/$KIT_NAME.sh install      # creates it and installs the worker"; fi
    return
  fi
  home=$(printf '%s' "$pw" | cut -d: -f6)
  if [ "$home" = "$SDM_USER_HOME" ]; then ok "user '$SDM_USER' exists, home $home"
  else chk_fail "user '$SDM_USER' has home '$home', the kit standard is $SDM_USER_HOME" "usermod -d $SDM_USER_HOME -m $SDM_USER      # after stopping the worker: systemctl stop $SDM_UNIT"; fi
}

chk_unit() {
  local en act sub nr u wd es p since
  if [ "$CHK_SYSTEMD" = 0 ]; then info "no systemd: unit checks skipped"; return; fi
  if [ "$CHK_UNIT" = 0 ]; then
    chk_fail "systemd unit $SDM_UNIT is not installed" "bash $KIT_DIR/$KIT_NAME.sh install      # or choose 'New install' in the menu"; return; fi
  ok "unit $SDM_UNIT installed ($(kit_unit_prop "$SDM_UNIT" FragmentPath))"
  en=$(systemctl is-enabled "$SDM_UNIT" 2>/dev/null </dev/null)
  if [ "$en" = enabled ]; then ok "enabled (starts at boot)"
  else chk_fail "$SDM_UNIT is not enabled (state: ${en:-unknown}), so it will not start at boot" "systemctl enable $SDM_UNIT"; fi
  act=$(kit_unit_prop "$SDM_UNIT" ActiveState); sub=$(kit_unit_prop "$SDM_UNIT" SubState)
  since=$(kit_unit_prop "$SDM_UNIT" ActiveEnterTimestamp)
  if [ "$act" = active ]; then ok "active ($sub) since ${since:-?}"
  else chk_fail "$SDM_UNIT is $act ($sub)" "systemctl start $SDM_UNIT
journalctl -u $SDM_UNIT -n 50 --no-pager      # why it stopped"; fi
  nr=$(kit_unit_prop "$SDM_UNIT" NRestarts)
  if [[ $nr =~ ^[0-9]+$ ]] && [ "$nr" -gt 0 ]; then
    chk_warn "systemd has restarted $SDM_UNIT $nr time(s) since it was loaded (crash loop?)" "journalctl -u $SDM_UNIT -n 100 --no-pager"; fi
  u=$(kit_unit_prop "$SDM_UNIT" User)
  if [ "$u" = "$SDM_USER" ]; then ok "runs as User=$u"
  else chk_fail "unit runs as '${u:-root}', the kit standard is '$SDM_USER'" "bash $KIT_DIR/$KIT_NAME.sh install      # repairs the unit (asks before replacing)"; fi
  wd=$(kit_unit_prop "$SDM_UNIT" WorkingDirectory)
  if [ "$wd" = "$SDM_HOME_DIR" ]; then ok "WorkingDirectory=$wd"
  else chk_warn "WorkingDirectory is '${wd:-unset}', expected $SDM_HOME_DIR" "bash $KIT_DIR/$KIT_NAME.sh install      # repairs the unit"; fi
  es=$(kit_unit_prop "$SDM_UNIT" ExecStart); p=$(printf '%s' "$es" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
  if [ "$p" = "$SDM_BIN" ]; then ok "ExecStart uses $SDM_BIN"
  else chk_warn "ExecStart binary is '${p:-unknown}', expected $SDM_BIN" "bash $KIT_DIR/$KIT_NAME.sh install"; fi
  [ "$CHK_ENVFILE" = "$SDM_SYSCONFIG" ] || chk_warn "unit loads env file '$CHK_ENVFILE', expected $SDM_SYSCONFIG" ""
}

chk_binary() {
  if [ -x "$SDM_BIN" ]; then
    if CHK_VERSION=$(kit_as_worker "$SDM_HOME_DIR" timeout 15 "$SDM_BIN" --version </dev/null 2>/dev/null); then
      CHK_VERSION=$(printf '%s\n' "$CHK_VERSION" | awk '$1=="sdm" && $2=="version" && $3~/^[0-9][0-9A-Za-z._+-]*$/{print $3; exit}')
      ok "binary $SDM_BIN: ${CHK_VERSION:-version unknown}"
    else chk_warn "could not inspect the installed CLI with reduced privileges" "check the service account and CLI permissions"; fi
  elif [ -n "$CHK_PEXE" ]; then info "no $SDM_BIN; the running worker uses ${CHK_PEXE% (deleted)}"
  else chk_fail "binary $SDM_BIN not found" "bash $KIT_DIR/$KIT_NAME.sh install"; fi
  if [[ $CHK_PEXE == *" (deleted)" ]]; then
    chk_warn "the running worker's binary was replaced after it started (upgrade pending)" "systemctl restart $SDM_UNIT"
  elif [ -n "$CHK_PEXE" ] && [ "$CHK_PEXE" != "$SDM_BIN" ]; then info "running worker binary: $CHK_PEXE"; fi
}

chk_procs() {
  local pid user role exe cwd st nw=0 strays="" others=""
  if [ -z "$CHK_PROCS" ]; then
    if [ "$CHK_CONTAINER" = 1 ] && [ "$CHK_SYSTEMD" = 0 ]; then
      chk_fail "no sdm worker process is running in this container" "docker logs --tail 50 <container>      # why it exited (run this on the docker host)"
    else chk_fail "no sdm worker process is running" "systemctl start $SDM_UNIT
journalctl -u $SDM_UNIT -n 50 --no-pager"; fi
    return
  fi
  while IFS='|' read -r pid user role exe cwd st; do
    [ -n "$pid" ] || continue
    info "pid $pid: sdm $role, user $user, started $(chk_ts "$st"), cwd ${cwd:-?}"
    if [ "$role" = worker ]; then nw=$((nw+1)); [ "$pid" != "$CHK_PID" ] && strays+=" $pid"
    else others+=" $role(pid $pid)"; fi
  done <<<"$CHK_PROCS"
  [ -n "$CHK_PID" ] && ok "worker process pid $CHK_PID (user $CHK_PUSER)"
  if [ $nw -gt 1 ]; then
    chk_fail "$nw sdm worker processes are running; one per host is expected (they compete for the bind port and sealed secrets)" "systemctl show -p MainPID $SDM_UNIT      # the one to keep
kill$strays      # the stray one(s), after checking how they were started"
  fi
  [ -n "$others" ] && chk_warn "other StrongDM node processes on this host:$others" "only if this host should be a worker only: systemctl disable --now <their unit>"
  if [ -n "$CHK_PUSER" ] && [ "$CHK_PUSER" != "$SDM_USER" ] && [ "$CHK_CONTAINER" = 0 ]; then
    chk_warn "the worker runs as '$CHK_PUSER', the kit standard is '$SDM_USER'" "bash $KIT_DIR/$KIT_NAME.sh install      # repairs the unit"; fi
  if [ -n "$CHK_PID" ] && [ "$CHK_ENVREAD" = 0 ]; then
    if [ "$CHK_ROOT" = 1 ]; then
      chk_warn "cannot read the worker's /proc/$CHK_PID/environ even as root (container without CAP_SYS_PTRACE?); using $CHK_ENVFILE instead" \
          "docker exec -u $CHK_PUSER -it <container> bash      # run the check as the worker's user"
    else chk_warn "cannot read /proc/$CHK_PID/environ; using $CHK_ENVFILE instead" "sudo -i      # then re-run the check"; fi
  fi
}

chk_print_redacted() {
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|[[:space:]]*'#'*|'#'*) continue;; esac
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k=${BASH_REMATCH[2]}; v=${BASH_REMATCH[3]}
      if chk_is_secret_key "$k"; then note "$k=<redacted, ${#v} bytes>"
      else note "$k=<set>"; fi
    else note "<line not in KEY=VALUE form, ${#line} bytes, not shown>"; fi
  done < "$1"
}

chk_envfile() {
  local f=$CHK_ENVFILE v lo plain="" k mode
  if [ ! -e "$f" ]; then
    if [ "$CHK_CONTAINER" = 1 ] && [ "$CHK_SYSTEMD" = 0 ]; then info "no $f (normal in a container: configuration comes from the process environment)"
    else chk_fail "env file $f is missing" "bash $KIT_DIR/$KIT_NAME.sh install      # rewrites it"; fi
  elif [ ! -r "$f" ]; then chk_warn "cannot read $f (need root)" "sudo -i      # then re-run the check"
  else
    mode=$(stat -c '%a' "$f" 2>/dev/null)
    info "$f (owner $(stat -c '%U:%G' "$f" 2>/dev/null), mode $mode, modified $(chk_ts "$(chk_mtime "$f")"); secret values redacted):"
    chk_print_redacted "$f"
    for k in SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY SDM_RELAY_TOKEN SDM_ADMIN_TOKEN DELINEA_PASSWORD; do
      kit_envfile_has "$f" "$k" && plain+=" $k"
    done
    if [ -n "$plain" ]; then
      chk_warn "plaintext credential(s) in $f:$plain" "runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set$plain      # seal them (hidden prompt)
sed -i -E '/^(export )?($(printf '%s' "${plain# }" | tr ' ' '|'))=/d' $f
systemctl restart $SDM_UNIT
# or: bash $KIT_DIR/$KIT_NAME.sh install   (seals and removes them)"
      note "sdm install writes the keys in plaintext only when the host cannot seal."
      [ "${mode: -2}" != 00 ] && \
        chk_warn "$f holds credentials and is readable by group/other (mode $mode)" "chmod 600 $f"
    fi
    if chk_changed_after_start "$f"; then
      chk_fail "$f was modified ($(chk_ts "$(chk_mtime "$f")")) AFTER the worker started ($(chk_ts "$CHK_PSTART")); the worker still runs with the old values" "systemctl restart $SDM_UNIT"
    fi
  fi
  lo=$(chk_cfg SDM_LOG_OUTPUT)
  case $lo in
    stdout|stderr) ok "SDM_LOG_OUTPUT=$lo: logs go to journald (journalctl -u $SDM_UNIT), not to a file under SDM_HOME";;
    *) if [ "$CHK_CONTAINER" = 1 ] && [ "$CHK_SYSTEMD" = 0 ]; then info "SDM_LOG_OUTPUT=${lo:-unset} (containers default to stdout when SDM_DOCKERIZED=true)"
       else chk_warn "SDM_LOG_OUTPUT is '${lo:-unset}': the worker writes a rotating log FILE under its SDM_HOME, so journalctl shows almost nothing" "echo 'SDM_LOG_OUTPUT=stdout' >> $f
systemctl restart $SDM_UNIT"; fi;;
  esac
  v=$(chk_cfg SDM_VERBOSE)
  if [ "$v" = true ]; then
    if kit_envfile_has "$f" SDM_VERBOSE; then
      chk_warn "SDM_VERBOSE=true is still on: debug-level logging is noisy and was meant to be temporary" "sed -i '/^SDM_VERBOSE=/d' $f
systemctl restart $SDM_UNIT      # drops this worker's active sessions"
    else
      chk_warn "SDM_VERBOSE=true is still on (set in the worker's environment, not in $f): debug-level logging is noisy" \
          "remove SDM_VERBOSE from the unit's Environment= lines or the container's env, then restart the worker"
    fi
  else ok "SDM_VERBOSE is ${v:-unset} (normal info-level logging)"; fi
}

chk_homes() {
  local ef wd pe
  ef=$(kit_envfile_get "$CHK_ENVFILE" SDM_HOME 2>/dev/null) && ef=$(chk_unquote "$ef")
  wd=""; [ "$CHK_UNIT" = 1 ] && wd=$(kit_unit_prop "$SDM_UNIT" WorkingDirectory)
  pe=$(chk_penv SDM_HOME)
  info "worker SDM_HOME: $CHK_HOME (from $CHK_HOME_SRC)"
  note "env file: ${ef:-unset}   unit WorkingDirectory: ${wd:-n/a}   process env: ${pe:-unset/unreadable}   process cwd: ${CHK_PCWD:-n/a}"
  if [ "$CHK_CONTAINER" = 1 ] && [ "$CHK_SYSTEMD" = 0 ]; then return; fi
  if [ "$CHK_HOME" = "$SDM_HOME_DIR" ] && { [ -z "$ef" ] || [ "$ef" = "$SDM_HOME_DIR" ]; } && { [ -z "$pe" ] || [ "$pe" = "$SDM_HOME_DIR" ]; }; then
    ok "SDM_HOME is consistently $SDM_HOME_DIR"
  else chk_warn "SDM_HOME is not consistently $SDM_HOME_DIR (the worker uses $CHK_HOME)" "bash $KIT_DIR/$KIT_NAME.sh install      # repairs the env file and unit"; fi
  if [ -d "$CHK_HOME" ]; then
    local o; o=$(stat -c %U "$CHK_HOME" 2>/dev/null)
    if [ -n "$CHK_PUSER" ] && [ "$CHK_PUSER" != root ] && [ "$o" != "$CHK_PUSER" ]; then
      chk_warn "$CHK_HOME is owned by '$o' but the worker runs as '$CHK_PUSER'" "inspect the directory ownership offline"; fi
  else chk_fail "SDM_HOME $CHK_HOME does not exist" "bash $KIT_DIR/$KIT_NAME.sh install"; fi
}

# chk_nodesecrets_list DIR -> sets CHK_NS_KEYS (space separated), CHK_NS_MSG; returns 0 listed, 1 no file, 2 error.
chk_nodesecrets_list() {
  local d=$1 bin=$SDM_BIN out
  CHK_NS_KEYS=""; CHK_NS_MSG=""
  [ -f "$d/secretenv.enc" ] || { CHK_NS_MSG="no sidecar"; return 1; }
  [ -x "$bin" ] || { CHK_NS_MSG="installed CLI unavailable"; return 2; }
  kit_as_worker "$d" test -r "$d/secretenv.enc" || { CHK_NS_MSG="unreadable as service user"; return 2; }
  out=$(kit_as_worker "$d" timeout 20 "$bin" nodesecrets list </dev/null 2>/dev/null) || { CHK_NS_MSG="unreadable as service user"; return 2; }
  CHK_NS_KEYS=$(printf '%s\n' "$out" | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | tr '\n' ' ')
  CHK_NS_KEYS=${CHK_NS_KEYS% }
  if [ -z "$CHK_NS_KEYS" ]; then
    if [[ $out == *"no sealed secrets file present"* ]]; then CHK_NS_MSG="no sealed secrets file present"; return 1; fi
    if [ -n "$out" ]; then CHK_NS_MSG="unrecognized CLI response"; return 2; fi
  fi
  return 0
}

chk_secretsrc() {
  local f k where sc o
  CHK_SECRETS_FILE=$(chk_cfg SDM_SECRETS_FILE)
  if [ -n "$CHK_SECRETS_FILE" ]; then
    f=$CHK_SECRETS_FILE
    info "SDM_SECRETS_FILE=$f: the worker reads secrets from this plaintext JSON file INSTEAD of the sealed sidecar"
    if [[ $f != /* ]]; then chk_fail "SDM_SECRETS_FILE must be an absolute path; the worker refuses to start" "use an absolute path, e.g. /run/secrets/sdm.json"
    elif [ ! -e "$f" ]; then chk_fail "$f does not exist; the worker fails closed at startup" "mount the secret file at $f (or unset SDM_SECRETS_FILE)"
    elif [ ! -f "$f" ]; then chk_fail "$f is not a regular file; the worker fails closed at startup" "mount a regular file at $f"
    elif [ ! -r "$f" ]; then chk_warn "cannot read $f (need root)" "sudo -i"
    else
      if kit_is_root && { [ -z "$CHK_PID" ] || [ "$(awk '/^Uid:/{print $2}' "/proc/$CHK_PID/status" 2>/dev/null)" != 0 ]; }; then
        CHK_MOUNT_FLAT=$(kit_as_worker "$CHK_HOME" cat -- "$f" 2>/dev/null | json_flat)
      else CHK_MOUNT_FLAT=$(json_flat < "$f"); fi
      CHK_MOUNT_KEYS=$(printf '%s\n' "$CHK_MOUNT_FLAT" | cut -f1 | grep -v '\.' | tr '\n' ' '); CHK_MOUNT_KEYS=${CHK_MOUNT_KEYS% }
      if [ -n "$CHK_MOUNT_KEYS" ]; then ok "$f keys: $CHK_MOUNT_KEYS"
      else chk_fail "$f has no top-level JSON keys (not a JSON object?)" "the file must be a JSON object: {\"DELINEA_USERNAME\":\"...\",\"DELINEA_PASSWORD\":\"...\"}"; fi
      chk_changed_after_start "$f" && chk_fail "$f changed AFTER the worker started; secrets are loaded once at startup" "systemctl restart $SDM_UNIT      # container: restart the container"
    fi
  else
    sc=$CHK_HOME/secretenv.enc
    if [ -f "$sc" ]; then
      o=$(stat -c %U "$sc" 2>/dev/null)
      ok "sealed sidecar $sc (owner $o, mode $(stat -c %a "$sc" 2>/dev/null), modified $(chk_ts "$(chk_mtime "$sc")"))"
      if [ -n "$CHK_PUSER" ] && [ "$CHK_PUSER" != root ] && [ "$o" != "$CHK_PUSER" ]; then
        chk_fail "$sc is owned by '$o' but the worker runs as '$CHK_PUSER', so it cannot read it" "Inspect the sidecar and its ownership offline before repairing the worker."; fi
      chk_changed_after_start "$sc" && chk_fail "sealed sidecar changed AFTER the worker started; it is loaded once at startup, so the worker still uses the old values" "systemctl restart $SDM_UNIT"
      chk_nodesecrets_list "$CHK_HOME"
      case $? in
        0) CHK_SEALED_OK=1; CHK_SEALED_KEYS=$CHK_NS_KEYS; info "sealed key names: ${CHK_SEALED_KEYS:-none}";;
        1) CHK_SEALED_OK=1; info "sealed key names: none";;
        *) chk_warn "could not list the sealed keys: $CHK_NS_MSG" "runuser -u sdm -- env SDM_HOME=$CHK_HOME SDM_LOG_OUTPUT=stderr $SDM_BIN nodesecrets list";;
      esac
    else
      CHK_SEALED_OK=1
      info "no sealed sidecar at $sc (then every credential must come from the environment)"
    fi
  fi
  for k in DELINEA_SERVER_URL DELINEA_API_TENANT; do
    if chk_in_list "$k" "$CHK_SEALED_KEYS $CHK_MOUNT_KEYS"; then
      chk_fail "$k is in the secret store, but the worker reads it ONLY from its environment, so that value is ignored" "runuser -u sdm -- env SDM_HOME=$CHK_HOME $SDM_BIN nodesecrets unset $k
echo '$k=<value>' >> $CHK_ENVFILE
systemctl restart $SDM_UNIT"; fi
  done
  for k in SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY; do
    where=""
    chk_in_list "$k" "$CHK_SEALED_KEYS" && where="sealed sidecar"
    chk_in_list "$k" "$CHK_MOUNT_KEYS" && where="SDM_SECRETS_FILE"
    [ -z "$where" ] && chk_penv "$k" >/dev/null && where="process environment"
    [ -z "$where" ] && kit_envfile_has "$CHK_ENVFILE" "$k" && where="$CHK_ENVFILE"
    if [ -n "$where" ]; then ok "$k provided by the $where"
    elif [ "$CHK_SEALED_OK" = 1 ] && [ "$CHK_ROOT" = 1 ]; then
      chk_fail "$k is not provided anywhere the worker reads it" "bash $KIT_DIR/$KIT_NAME.sh install      # asks for the keys and seals them"
    else info "$k: could not verify (sealed keys not listable or not root)"; fi
  done
}

chk_stray() {
  local d hp missing k any=0 msg fixc
  hp=$(chk_realpath "$CHK_HOME")
  for d in /root/.sdm /home/*/.sdm /sdm; do
    [ -d "$d" ] || continue
    [ "$(chk_realpath "$d")" = "$hp" ] && continue
    any=1
    if [ -f "$d/secretenv.enc" ]; then
      chk_nodesecrets_list "$d"
      missing=""
      for k in $CHK_NS_KEYS; do chk_in_list "$k" "$CHK_SEALED_KEYS $CHK_MOUNT_KEYS" || missing+=" $k"; done
      CHK_STRAY_KEYS+=" $CHK_NS_KEYS"
      msg="sealed secrets in $d/secretenv.enc (keys: ${CHK_NS_KEYS:-${CHK_NS_MSG:-unknown}}) are NOT read by the worker, which reads $CHK_HOME"
      fixc="runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set ${missing# }      # re-enter the values into the worker's sidecar
systemctl restart $SDM_UNIT
mv $d $d.unused-$(date +%Y%m%d)      # after the worker works"
      [ -n "$missing" ] || fixc="mv $d $d.unused-$(date +%Y%m%d)      # leftover; the worker already has these keys"
      if [ -n "$missing" ]; then chk_fail "$msg; missing from the worker:$missing" "$fixc"
      else chk_warn "$msg" "$fixc"; fi
      note "Cause: after 'sudo su -' (or sudo -i) USER is root, and an interactive 'sdm nodesecrets set'"
      note "without SDM_HOME writes ~root/.sdm. Always pass SDM_HOME=$SDM_HOME_DIR."
    else
      info "leftover directory $d (no sealed secrets; contents: $(ls -A "$d" 2>/dev/null | head -8 | tr '\n' ' ')) - not used by the worker"
    fi
  done
  [ $any = 0 ] && ok "no stray .sdm directories in /root or /home/*"
}

chk_other_units() {
  local u st
  [ "$CHK_SYSTEMD" = 1 ] || return 0
  for u in sdm "${KIT_FOREIGN_UNITS[@]}"; do
    [ "$u" = "$SDM_UNIT" ] && continue
    kit_unit_exists "$u" || continue
    st=$(kit_unit_prop "$u" ActiveState)
    chk_warn "another StrongDM unit '$u' is installed ($st)" "systemctl disable --now $u      # only if this host should be a worker only"
  done
}

# ---------------------------------------------------------------- 3 connectivity
chk_connect() {
  local d=$CHK_APP_DOMAIN ips a lv b port
  kit_section "3. Connectivity"
  info "control plane: $d (from $CHK_APP_SRC)"
  chk_in_list "$d" "${KIT_APP_DOMAINS[*]}" || info "not one of the standard regions (${KIT_APP_DOMAINS[*]}); fine for a private/vanity domain"
  if [ -n "$CHK_WPROXY" ]; then info "the worker uses an HTTPS proxy for its connectivity checks"
  elif [ -n "$CHK_SHELL_PROXY" ]; then
    info "your shell has a proxy set but the worker does not; the checks below go direct, as the worker does"
  fi
  if kit_have getent; then
    ips=$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -n "$ips" ]; then ok "DNS $d -> $ips"
    elif [ -n "$CHK_WPROXY" ]; then info "DNS for $d fails locally (fine when the proxy resolves it)"
    else chk_fail "DNS lookup for $d failed" "getent hosts $d; cat /etc/resolv.conf      # fix the resolver or egress DNS"; fi
  fi
  if [ -z "$CHK_WPROXY" ]; then
    if kit_tcp_ok "$d" 443; then ok "TCP $d:443 reachable"
    else chk_fail "TCP $d:443 is not reachable from this host" "allow outbound tcp/443 to $d (security group / firewall / proxy)"; fi
  fi
  if kit_have curl; then
    case $(uname -m) in aarch64|arm64) a=arm64;; *) a=amd64;; esac
    kit_http GET "https://$d/releases/upgrade?software=sdm-cli&os=linux&arch=$a"
    case $HE in
      0) if [ "${HC:0:1}" = 2 ]; then
           lv=$(jget "$(printf '%s' "$HB" | json_flat)" version)
           ok "HTTPS to $d works (HTTP $HC)"
           [ -n "$lv" ] && info "latest sdm for linux/$a: $lv; installed: ${CHK_VERSION:-unknown}"
         else chk_warn "HTTPS to $d answered HTTP $HC" "curl -sv https://$d/ -o /dev/null      # look for a proxy or captive portal"; fi;;
      77) chk_fail "curl cannot load the system CA bundle (curl exit 77)" "dnf install -y ca-certificates      # or: apt-get install -y ca-certificates";;
      35|51|53|58|60|83|90|91)
         chk_fail "TLS to $d failed (curl exit $HE): " "a TLS-inspecting proxy needs its CA in the system trust store:
cp proxy-ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust      # RHEL family
cp proxy-ca.crt /usr/local/share/ca-certificates/ && update-ca-certificates      # Debian family";;
      5|6|7|28|56|97) chk_fail "HTTPS to $d failed (curl exit $HE): " "curl -sv https://$d/ -o /dev/null      # see where it stops";;
      *) chk_warn "HTTPS to $d: curl exit $HE: " "curl -sv https://$d/ -o /dev/null";;
    esac
  else info "curl is not installed: HTTPS check skipped (dnf/apt-get install -y curl)"; fi
  b=$(chk_cfg SDM_BIND_ADDRESS); [ -n "$b" ] || b=$SDM_DEFAULT_BIND
  port=${b##*:}
  if [[ ! $port =~ ^[0-9]+$ ]]; then chk_warn "cannot parse SDM_BIND_ADDRESS '$b'" ""; return; fi
  if [ -z "$CHK_PID" ]; then info "worker not running: bind port $port not checked"
  elif chk_listening "$port"; then ok "something listens on tcp/$port (worker bind address $b)"
  else chk_fail "nothing listens on tcp/$port although the worker is running (bind address $b)" "journalctl -u $SDM_UNIT -n 100 --no-pager | grep -iE 'bind|listen|address'"; fi
  chk_firewall "$port"
}

chk_listening() { local p=$1 hx
  if kit_have ss; then ss -ltn 2>/dev/null | awk -v p=":$p" 'NR>1 && substr($4, length($4)-length(p)+1)==p {f=1} END{exit !f}'; return; fi
  printf -v hx '%04X' "$p"
  cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$hx" '$4=="0A" { split($2,a,":"); if (a[2]==p) f=1 } END{exit !f}'
}

chk_firewall() { local p=$1 lst
  if kit_have firewall-cmd && [ "$(firewall-cmd --state 2>/dev/null </dev/null)" = running ]; then
    lst=" $(firewall-cmd --list-ports 2>/dev/null </dev/null) "
    if [[ $lst == *" $p/tcp "* ]]; then ok "firewalld allows $p/tcp"
    else chk_warn "firewalld is running and does not list $p/tcp (fine if a zone/service rule covers it)" "firewall-cmd --permanent --add-port=$p/tcp && firewall-cmd --reload"; fi
  elif kit_have ufw && ufw status 2>/dev/null </dev/null | grep -q 'Status: active'; then
    if ufw status 2>/dev/null </dev/null | grep -qE "^$p(/tcp)?[[:space:]].*ALLOW"; then ok "ufw allows $p"
    else chk_warn "ufw is active and has no ALLOW rule for $p" "ufw allow $p/tcp"; fi
  else info "no active firewalld/ufw on this host (cloud security groups still apply: allow inbound tcp/$p from the load balancer/gateways)"; fi
}

# ---------------------------------------------------------------- 4 logs
chk_logs() {
  local s all lh errs wrns nerr nwrn nstart started_ago
  kit_section "4. Recent logs"
  if [ "$CHK_SYSTEMD" = 0 ] || ! kit_have journalctl; then
    info "no journald here. In a container the worker logs to stdout; on the docker host run:"
    note "docker logs --since 1h <container> 2>&1 | grep -E 'running proxy worker|initial authsync complete|level=error'"
    return
  fi
  [ "$CHK_UNIT" = 1 ] || { info "unit $SDM_UNIT not installed: no logs to read"; return; }
  [ "$CHK_ROOT" = 1 ] || info "not root: the journal may hide the worker's lines"
  if [ -n "$CHK_PSTART" ]; then
    s=$(chk_ts "$CHK_PSTART"); started_ago=$(( $(date +%s) - CHK_PSTART ))
    info "worker started $s ($((started_ago/60)) min ago)"
    all=$(journalctl -u "$SDM_UNIT" --since "$s" --no-pager -o cat 2>/dev/null </dev/null | head -20000)
    if printf '%s\n' "$all" | grep -q 'running proxy worker'; then ok "'running proxy worker' logged since the last start"
    elif [ $started_ago -gt 120 ]; then chk_fail "no 'running proxy worker' line since the last start: the worker did not get past startup" "journalctl -u $SDM_UNIT --since '$s' --no-pager | head -60"
    else info "'running proxy worker' not logged yet (started under 2 min ago)"; fi
    if printf '%s\n' "$all" | grep -q 'initial authsync complete'; then ok "'initial authsync complete' logged (talking to the control plane)"
    elif [ $started_ago -gt 120 ]; then chk_warn "no 'initial authsync complete' since the last start: it has not synced with the control plane" \
        "journalctl -u $SDM_UNIT --since '$s' --no-pager | grep -iE 'error|auth|token|connect' | tail -20"
    else info "'initial authsync complete' not logged yet"; fi
  else info "worker not running: startup lines not checked"; fi
  lh=$(journalctl -u "$SDM_UNIT" --since "-1h" --no-pager -o short-iso 2>/dev/null </dev/null | tail -20000)
  errs=$(printf '%s\n' "$lh" | grep -iE 'level=(error|fatal|panic|dpanic)|"level":"(error|fatal|panic|dpanic)"|Main process exited|Failed with result')
  wrns=$(printf '%s\n' "$lh" | grep -iE 'level=warn|"level":"warn')
  nerr=$(printf '%s' "$errs" | grep -c .); nwrn=$(printf '%s' "$wrns" | grep -c .)
  nstart=$(printf '%s\n' "$lh" | grep -cE 'Started StrongDM worker|Started sdm-worker')
  info "last hour: $(printf '%s' "$lh" | grep -c .) line(s), $nerr error(s), $nwrn warning(s), $nstart start(s)"
  [ "$nstart" -gt 2 ] && chk_warn "$SDM_UNIT started $nstart times in the last hour (restart loop)" "journalctl -u $SDM_UNIT --since -1h --no-pager | grep -iE 'error|exited' | tail -20"
  if [ "$nerr" -gt 0 ]; then
    chk_warn "$nerr error line(s) in the last hour" "journalctl -u $SDM_UNIT --since -1h --no-pager | grep -iE 'level=error|\"level\":\"error\"'"
  fi
}

# ---------------------------------------------------------------- 5 delinea
chk_delinea_wanted() {
  local found=""
  case ${KIT_CHECK_DELINEA:-} in
    yes|y|1|true) info "KIT_CHECK_DELINEA=yes"; return 0;;
    no|n|0|false) info "skipped (KIT_CHECK_DELINEA=no)"; return 1;;
  esac
  [ "$CHK_ENVREAD" = 1 ] && tr '\0' '\n' < "/proc/$CHK_PID/environ" 2>/dev/null | grep -q '^DELINEA_' && found+=" worker-env"
  [ -r "$CHK_ENVFILE" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?DELINEA_' "$CHK_ENVFILE" && found+=" env-file"
  [[ " $CHK_SEALED_KEYS $CHK_MOUNT_KEYS " == *" DELINEA_"* ]] && found+=" secret-store"
  [[ " $CHK_STRAY_KEYS " == *" DELINEA_"* ]] && found+=" stray-sidecar"
  if [ -n "$found" ]; then info "DELINEA_* settings found in:$found"; return 0; fi
  if kit_noninteractive; then info "no DELINEA_* settings found; skipped (export KIT_CHECK_DELINEA=yes to force)"; return 1; fi
  kit_confirm "No DELINEA_* settings found. Test a Delinea secret store anyway?" n || { info "skipped"; return 1; }
}

# chk_ask VAR "prompt": env value, else (interactive) a visible prompt where Enter = empty.
chk_ask() {
  if [ -n "${!1:-}" ]; then info "$2: using \$$1 from the environment"; return 0; fi
  kit_noninteractive && { printf -v "$1" '%s' ""; return 0; }
  kit_ask "$1" "$2 (Enter to skip)" ""
}

# secretkit.ParsePath + delinea.parsePath -> CHK_PK CHK_PR CHK_PID_ CHK_PENC CHK_PSTATIC, or return 1 with CHK_PERR
chk_parse_path() {
  local raw=$1 q path kv parts=() norm dg
  CHK_PK=""; CHK_PENC=""; CHK_PSTATIC=""; CHK_SID=""; CHK_PERR=""; CHK_PR=""
  path=${raw%%\?*}; if [ "$path" = "$raw" ]; then q=""; else q=${raw#*\?}; fi
  [ -n "$q" ] && IFS='&' read -ra parts <<<"$q"
  for kv in ${parts[@]+"${parts[@]}"}; do
    case $kv in key=*) [ -z "$CHK_PK" ] && CHK_PK=${kv#key=};; encoding=*) [ -z "$CHK_PENC" ] && CHK_PENC=${kv#encoding=};; static=*) [ -z "$CHK_PSTATIC" ] && CHK_PSTATIC=${kv#static=};; esac
  done
  CHK_PK=${CHK_PK//+/ }; printf -v CHK_PK '%b' "${CHK_PK//%/\\x}"; printf -v path '%b' "${path//%/\\x}"
  CHK_PR=$path
  case $CHK_PENC in ''|base64) ;; *) CHK_PERR="invalid secret encoding '$CHK_PENC' (only base64 or none)"; return 1;; esac
  [ "$CHK_PSTATIC" = true ] && return 0
  [ -n "$CHK_PK" ] || { CHK_PERR="delinea secrets require a key to query (add ?key=<FieldName>)"; return 1; }
  norm=${path#"${path%%[!/]*}"}
  [ -n "$norm" ] || { CHK_PERR="path must be a secret ID or a folder path like /Folder/Secret"; return 1; }
  if [[ $norm =~ ^[+-]?[0-9]+$ ]]; then dg=${norm#[+-]}; CHK_SID=$((10#$dg)); [[ $norm == -* ]] && CHK_SID=-$CHK_SID; return 0; fi
  [[ $path == */* ]] || { CHK_PERR="path must be a secret ID or a folder path like /Folder/Secret"; return 1; }
  return 0
}

chk_delinea() {
  kit_section "5. Delinea secret store"
  chk_delinea_wanted || return 0
  kit_secret_register CHK_SPW CHK_TOKEN CHK_VAL_PASS CHK_WANT KIT_DELINEA_SVC_PASSWORD
  CHK_SU=""; CHK_SPW=""; CHK_TOKEN=""; CHK_VAL_PASS=""; CHK_WANT=""; CHK_API=""; CHK_URL=""
  chk_dl_creds
  chk_dl_url
  chk_dl_paths
  if [ "${KIT_DELINEA_LIVE:-no}" = yes ] && [ -n "$CHK_URL" ]; then
    unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
    if [ -n "${KIT_DELINEA_CA_FILE:-}" ]; then
      local ca=$KIT_DELINEA_CA_FILE
      if ! kit_trusted_file "$ca"; then
        chk_fail "Untrusted Delinea CA bundle" "use a root-owned regular file under a protected directory"; return
      fi
      export CURL_CA_BUNDLE=$ca
    fi
    CHK_WPROXY=""; chk_dl_live
  else info "live authentication skipped; set KIT_DELINEA_LIVE=yes and a trusted KIT_DELINEA_SERVER_URL to enable"; fi
  if [ -n "${KIT_RDP_HOST:-}" ]; then
    local rh rp
    rh=${KIT_RDP_HOST%%:*}; rp=${KIT_RDP_HOST##*:}; [ "$rp" = "$KIT_RDP_HOST" ] && rp=3389
    if kit_tcp_ok "$rh" "$rp"; then ok "RDP target $rh:$rp is reachable (TCP) from this worker"
    else chk_fail "RDP target $rh:$rp is NOT reachable (TCP) from this worker" "allow tcp/$rp from this worker to $rh (Windows firewall / security group)"; fi
  fi
  info "the worker caches fetched credentials for up to 12h per user login; saving the resource, or sdm logout + sdm login, clears it"
  CHK_SPW=""; CHK_TOKEN=""; CHK_VAL_PASS=""; CHK_WANT=""
}

# Effective DELINEA_USERNAME / DELINEA_PASSWORD and where they come from.
chk_dl_creds() {
  local k v src envv envhas a
  for k in DELINEA_USERNAME DELINEA_PASSWORD; do
    v=""; src=""; envhas=0
    envv=$(chk_penv "$k") && envhas=1
    if chk_in_list "$k" "$CHK_MOUNT_KEYS"; then v=$(jget "$CHK_MOUNT_FLAT" "$k"); src="SDM_SECRETS_FILE"
    elif chk_in_list "$k" "$CHK_SEALED_KEYS"; then src="sealed sidecar"
    elif [ $envhas = 1 ] && [ -n "$envv" ]; then v=$envv; src="worker environment"
    elif [ "$CHK_ENVREAD" = 0 ] && v=$(kit_envfile_get "$CHK_ENVFILE" "$k"); then v=$(chk_unquote "$v"); src="$CHK_ENVFILE (worker env unreadable)"; fi
    if [ -z "$src" ]; then
      if chk_in_list "$k" "$CHK_STRAY_KEYS"; then chk_fail "$k is only in a stray sidecar the worker does not read (see section 2)" "runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set $k
systemctl restart $SDM_UNIT"
      elif kit_envfile_has "$CHK_ENVFILE" "$k"; then chk_fail "$k is in $CHK_ENVFILE but NOT in the running worker" "systemctl restart $SDM_UNIT"
      else chk_fail "$k is not set anywhere the worker reads it" "runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set $k      # hidden prompt
systemctl restart $SDM_UNIT"; fi
      continue
    fi
    if [ "$src" = "sealed sidecar" ]; then ok "$k comes from the sealed sidecar (value unreadable by design)"
    elif [ $k = DELINEA_USERNAME ]; then ok "$k comes from the $src (value hidden)"
    else ok "$k comes from the $src: $(kit_shape "$v")"; fi
    if [ -n "$v" ]; then a=$(kit_anomalies "$v"); [ -n "$a" ] && chk_warn "$k value anomalies: $a" "re-enter it: runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set $k"; fi
    [ "$src" != "worker environment" ] && [ $envhas = 1 ] && [ -n "$envv" ] && chk_warn "$k is ALSO in the worker's environment, but the $src value wins; editing the environment value does nothing" \
        "sed -i '/^$k=/d' $CHK_ENVFILE      # remove the dead copy"
    if [ $k = DELINEA_USERNAME ]; then CHK_SU=$v; else CHK_SPW=$v; fi
  done
  envv=""
}

chk_dl_url() {
  local eurl eten
  eurl=$(chk_penv DELINEA_SERVER_URL || { [ "$CHK_ENVREAD" = 0 ] && kit_envfile_get "$CHK_ENVFILE" DELINEA_SERVER_URL; })
  eten=$(chk_penv DELINEA_API_TENANT || { [ "$CHK_ENVREAD" = 0 ] && kit_envfile_get "$CHK_ENVFILE" DELINEA_API_TENANT; })
  eurl=$(chk_unquote "$eurl"); eten=$(chk_unquote "$eten")
  CHK_URL=""
  if [ -n "$eurl" ] && ! kit_https_url "$eurl"; then chk_warn "worker Secret Server URL requires a valid HTTPS address" "check the URL in the Admin UI"; fi
  if [ -n "$eten" ] && [ -n "${KIT_DELINEA_SERVER_URL:-$eurl}" ]; then
    chk_fail "only one of serverURL and tenant may be set" "correct the worker configuration before testing"; return
  fi
  [ "${KIT_DELINEA_LIVE:-no}" = yes ] || return 0
  chk_ask KIT_DELINEA_SERVER_URL "Trusted HTTPS Server URL set on the secret store in the Admin UI"
  if ! kit_https_url "${KIT_DELINEA_SERVER_URL:-}"; then
    chk_fail "live authentication requires a trusted HTTPS Secret Server URL" "supply KIT_DELINEA_SERVER_URL from your Admin UI"; return
  fi
  CHK_URL=${KIT_DELINEA_SERVER_URL%/}
}

chk_dl_paths() {
  local label raw var
  CHK_L_LABEL=(); CHK_L_KEY=(); CHK_L_PATH=(); CHK_L_ID=(); CHK_L_ENC=(); CHK_L_STATIC=()
  chk_ask KIT_DELINEA_USERNAME_PATH "Username secret path exactly as on the resource (e.g. 1234?key=Username)"
  if [ -z "${KIT_DELINEA_PASSWORD_PATH:-}" ] && ! kit_noninteractive; then
    printf '  Password secret path (hidden, Enter to skip): ' >/dev/tty
    IFS= read -rs KIT_DELINEA_PASSWORD_PATH </dev/tty || KIT_DELINEA_PASSWORD_PATH=""; printf '\n' >/dev/tty
  fi
  chk_ask KIT_RDP_HOST "RDP target host[:port] to test from this worker"
  for label in username password; do
    var=KIT_DELINEA_USERNAME_PATH; [ $label = password ] && var=KIT_DELINEA_PASSWORD_PATH
    raw=${!var:-}
    [ -n "$raw" ] || { info "$label path not given; skipped"; continue; }
    if chk_parse_path "$raw"; then
      CHK_L_LABEL+=("$label"); CHK_L_KEY+=("$CHK_PK"); CHK_L_PATH+=("$CHK_PR"); CHK_L_ID+=("$CHK_SID"); CHK_L_ENC+=("$CHK_PENC"); CHK_L_STATIC+=("$CHK_PSTATIC")
      if [ "$CHK_PSTATIC" = true ]; then ok "$label is static (value hidden)"
      elif [ -n "$CHK_SID" ]; then ok "$label: secret ID $CHK_SID, key '$CHK_PK', encoding ${CHK_PENC:-plaintext}"
      else ok "$label: folder path '$CHK_PR', key '$CHK_PK'"
        chk_warn "$label uses a folder path; it resolves to whichever secret DELINEA_USERNAME sees there" "use the numeric secret ID on the resource, e.g. 1234?key=$CHK_PK"; fi
      [ "$CHK_PK" != "$(kit_trim "$CHK_PK")" ] && chk_fail "$label key '$CHK_PK' has leading/trailing spaces, so it never matches a field" "remove the spaces from the key on the resource"
    else chk_fail "$label path is invalid: $CHK_PERR" "fix the secret path on the resource: <ID or /Folder/Secret>?key=<FieldName>"; fi
  done
  if [ ${#CHK_L_LABEL[@]} = 2 ] && [ -z "${CHK_L_STATIC[0]}" ] && [ -z "${CHK_L_STATIC[1]}" ] && [ "${CHK_L_KEY[0]}" = "${CHK_L_KEY[1]}" ]; then
    chk_fail "the username and password paths use the SAME key '${CHK_L_KEY[0]}'" "set the username path to ?key=Username and the password path to ?key=Password (the fields' display names)"; fi
}

chk_dl_get_creds() {
  if [ -n "$CHK_SU" ] && [ -n "$CHK_SPW" ]; then return 0; fi
  if kit_noninteractive && { { [ -z "$CHK_SU" ] && [ -z "${KIT_DELINEA_SVC_USERNAME:-}" ]; } || { [ -z "$CHK_SPW" ] && [ -z "${KIT_DELINEA_SVC_PASSWORD:-}" ]; }; }; then
    chk_warn "the service-account credentials are sealed and no terminal is available to type them; live Secret Server checks skipped" \
        "export KIT_DELINEA_SVC_USERNAME=... KIT_DELINEA_SVC_PASSWORD=...   # then re-run (or run interactively)"
    return 1
  fi
  if [ -z "$CHK_SU" ]; then
    kit_noninteractive || note "DELINEA_USERNAME is sealed: type the SAME service-account username you sealed."
    kit_ask KIT_DELINEA_SVC_USERNAME "DELINEA_USERNAME (service account)"
    CHK_SU=$KIT_DELINEA_SVC_USERNAME
  fi
  if [ -z "$CHK_SPW" ]; then
    kit_noninteractive || note "DELINEA_PASSWORD is sealed: type the SAME password you sealed (hidden, nothing is logged)."
    kit_ask_secret KIT_DELINEA_SVC_PASSWORD "DELINEA_PASSWORD (service account)"
    CHK_SPW=$KIT_DELINEA_SVC_PASSWORD
  fi
  info "using typed/env service-account credentials; the kit cannot prove they equal the sealed ones"
}

chk_dl_live() {
  local host port ips healthy_re='"[Hh]ealthy"[[:space:]]*:[[:space:]]*true' t vf
  host=${CHK_URL#*://}; host=${host%%/*}; port=${host##*:}; [ "$port" = "$host" ] && { port=443; [[ $CHK_URL == http://* ]] && port=80; }; host=${host%:*}
  if kit_have getent; then
    ips=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -n "$ips" ]; then ok "DNS $host -> $ips"
    elif [ -z "$CHK_WPROXY" ]; then chk_fail "DNS lookup for $host failed" "getent hosts $host; cat /etc/resolv.conf"; fi
  fi
  if [ -z "$CHK_WPROXY" ]; then
    if kit_tcp_ok "$host" "$port"; then ok "TCP $host:$port reachable"
    else chk_fail "TCP $host:$port is not reachable from this worker" "allow outbound tcp/$port from this worker to $host"; return; fi
  fi
  if ! kit_have curl; then chk_warn "curl is not installed, so the live Secret Server checks are skipped" "dnf install -y curl      # or: apt-get install -y curl"; return; fi
  chk_dl_get_creds || return
  CHK_API=$CHK_URL
  kit_http GET "$CHK_URL/api/v1/healthcheck"
  case $HE in 35|51|53|58|60|77|83|90|91)
    chk_fail "TLS to $CHK_URL failed (curl exit $HE): " "configure the approved CA in the host system trust store"
    return;; esac
  if [[ $HE = 0 && $HC = 200 ]] && [[ $HB =~ $healthy_re || ( $HB != *'{'* && $HB == *Healthy* ) ]]; then
    ok "Secret Server healthcheck $CHK_URL/api/v1/healthcheck: healthy"
    kit_http POST "$CHK_URL/oauth2/token" "username=$(kit_urlencode "$CHK_SU")&password=$(kit_urlencode "$CHK_SPW")&grant_type=password"
    if [ "$HE" = 0 ] && [ "${HC:0:1}" = 2 ] && CHK_TOKEN=$(jget "$(printf '%s' "$HB" | json_flat)" access_token) && [ -n "$CHK_TOKEN" ]; then ok "OAuth2 password grant succeeded"
    else chk_fail "POST /oauth2/token: HTTP $HC " "check the service account in Secret Server (locked? expired? wrong password?), then re-seal:
runuser -u sdm -- env SDM_HOME=$SDM_HOME_DIR $SDM_BIN nodesecrets set DELINEA_USERNAME DELINEA_PASSWORD && systemctl restart $SDM_UNIT"
      note "StrongDM never sends the token 'domain' parameter, so an AD account must be able to log in without it (local account, or AD user with domain login not required)"; fi
  else
    info "/api/v1/healthcheck not healthy (HTTP $HC); trying Delinea Platform /health"
    kit_http GET "$CHK_URL/health"
    if [[ $HE = 0 && $HC = 200 ]] && [[ $HB =~ $healthy_re || ( $HB != *'{'* && $HB == *Healthy* ) ]]; then
      ok "Delinea Platform /health: healthy"
      kit_http POST "$CHK_URL/identity/api/oauth2/token/xpmplatform" "grant_type=client_credentials&client_id=$(kit_urlencode "$CHK_SU")&client_secret=$(kit_urlencode "$CHK_SPW")&scope=xpmheadless"
      if [ "$HE" = 0 ] && [ "${HC:0:1}" = 2 ] && t=$(jget "$(printf '%s' "$HB" | json_flat)" access_token) && [ -n "$t" ]; then
        ok "Platform service-account token obtained"
        kit_http GET "$CHK_URL/vaultbroker/api/vaults" "" "$t"
        if [ "$HE" != 0 ] || [ "$HC" != 200 ]; then chk_fail "Platform vault lookup failed (HTTP $HC)" "check the Platform service account permissions"; return; fi
        vf=$(printf '%s' "$HB" | json_flat)
        CHK_API=$(printf '%s\n' "$vf" | awk -F'\t' '{p=$1; sub(/\.[^.]*(\.url)?$/,"",p)}
          tolower($1)~/\.isdefault$/{d[p]=$3} tolower($1)~/\.isactive$/{a[p]=$3}
          tolower($1)~/\.connection\.url$/{u[p]=$3}
          END{for(p in u) if(d[p]=="true"&&a[p]=="true"){print u[p]; exit}}')
        if kit_https_url "${KIT_DELINEA_VAULT_URL:-}" && [ "${CHK_API%/}" = "${KIT_DELINEA_VAULT_URL%/}" ]; then
          CHK_API=${KIT_DELINEA_VAULT_URL%/}; CHK_TOKEN=$t; ok "verified default vault"
        else chk_fail "default vault did not match KIT_DELINEA_VAULT_URL" "verify the default vault in Delinea and supply its HTTPS URL"; fi
        t=""
      else chk_fail "Platform token: HTTP $HC " "check the Platform service account (client id/secret) and re-seal DELINEA_USERNAME/DELINEA_PASSWORD"; fi
    else chk_fail "neither /api/v1/healthcheck nor /health is healthy at $CHK_URL (the worker reports tss-sdk 'invalid URL')" "check the URL includes the application path, e.g. https://<host>/SecretServer"; fi
  fi
  CHK_SPW=""; KIT_DELINEA_SVC_PASSWORD=""
  if [ -n "$CHK_TOKEN" ]; then chk_dl_fetch; fi
  CHK_TOKEN=""; HB=""
  chk_dl_compare
}

chk_dl_table() {
  local idx fn ip
  note "field names and password flags"
  printf '%s\n' "$CHK_SF" | awk -F'\t' 'tolower($1)~/^items\.[0-9]+\./{split($1,a,"."); print a[2]}' | sort -un | while read -r idx; do
    fn=$(jget "$CHK_SF" "items.$idx.fieldName"); ip=$(jget "$CHK_SF" "items.$idx.isPassword")
    note "field: $fn (isPassword=$ip)"
  done
}

chk_dl_fetch() {
  local j n label key ref lastref="" idxs idx v a near fl
  n=${#CHK_L_LABEL[@]}; CHK_SF=""
  [ "$n" -gt 0 ] || { info "no resource secret paths given: secret fetch skipped"; return; }
  for ((j=0; j<n; j++)); do
    label=${CHK_L_LABEL[j]}; key=${CHK_L_KEY[j]}
    if [ "${CHK_L_STATIC[j]}" = true ]; then continue; fi
    if [ -n "${CHK_L_ID[j]}" ]; then ref="secrets/${CHK_L_ID[j]}"; else ref="secrets/0?secretPath=$(kit_urlencode "${CHK_L_PATH[j]}")"; fi
    if [ "$ref" != "$lastref" ]; then
      lastref=$ref; CHK_SF=""
      kit_http GET "$CHK_API/api/v1/$ref" "" "$CHK_TOKEN"
      if [ "$HE" != 0 ] || [ "${HC:0:1}" != 2 ]; then
        chk_fail "GET /api/v1/${ref%%\?*} ($label): HTTP $HC " "in Secret Server give the service account View on the secret; turn off checkout/require-comment/approval for it (the API cannot satisfy them)"
        [[ $HB == *API_AccessDenied* || $HC = 403 ]] && note "the service account lacks View on this secret, or the secret requires checkout, a comment, or approval"
        continue
      fi
      CHK_SF=$(printf '%s' "$HB" | json_flat); HB=""
      ok "GET /api/v1/${ref%%\?*}: 200, secret id $(jget "$CHK_SF" id), name '$(jget "$CHK_SF" name)', template $(jget "$CHK_SF" secretTemplateId)"
      for fl in checkOutEnabled checkedOut requiresComment autoChangeEnabled checkOutChangePasswordEnabled; do
        if [ "$(jget "$CHK_SF" "$fl")" = true ]; then
          if [[ $fl == *Change* ]]; then chk_warn "secret has $fl=true: the password can rotate while the worker serves a cached copy for up to 12h" \
              "after a rotation: save the resource in the Admin UI (clears the cache)"
          else chk_warn "secret has $fl=true" "turn it off for secrets StrongDM reads"; fi
        fi
      done
      [ "$(jget "$CHK_SF" active)" = false ] && chk_fail "the secret is inactive (deleted)" "restore it, or point the resource at an active secret"
      chk_dl_table
    fi
    [ -n "$CHK_SF" ] || continue
    idxs=$(printf '%s\n' "$CHK_SF" | awk -F'\t' 'tolower($1)~/^items\.[0-9]+\.fieldname$/ {split($1,a,"."); print a[2] "\t" $3}' |
      while IFS=$'\t' read -r idx v; do v=$(printf '%b' "$v"); [ "$v" = "$key" ] && echo "$idx"; done)
    if [ -z "$idxs" ]; then
      near=$(printf '%s\n' "$CHK_SF" | awk -F'\t' -v k="$key" '(tolower($1)~/\.fieldname$/ && tolower($3)==tolower(k)) || (tolower($1)~/\.slug$/ && $3==k) {print $1 "=" $3; exit}')
      if [[ $near == *.slug=* ]]; then near=$(jget "$CHK_SF" "${near%%.slug=*}.fieldName"); else near=${near#*=}; fi
      chk_fail "$label key '$key' matches no field name (the worker reports 'failed to find field $key')" \
          "${near:+set the key to '$near' - }keys must equal the field's DISPLAY NAME exactly (case-sensitive), not its slug"
      continue
    fi
    [ "$(printf '%s\n' "$idxs" | wc -l)" -gt 1 ] && chk_warn "several fields are named '$key'; the worker uses the LAST one" "rename the duplicate field in the secret template"
    idx=$(printf '%s\n' "$idxs" | tail -1)
    v=$(jget "$CHK_SF" "items.$idx.itemValue")
    if [ -z "$v" ]; then chk_fail "$label field '$key' is empty (the worker reports 'failed to find field')" "fill in the '$key' field on the secret"; continue; fi
    [ "$label" = password ] && [ "$(jget "$CHK_SF" "items.$idx.isPassword")" != true ] && chk_warn "the password key '$key' is NOT the template's password field" \
        "point the password path at the template's password field (usually ?key=Password)"
    if [ "${CHK_L_ENC[j]}" = base64 ]; then
      v=$(printf '%s' "$v" | base64 -d 2>/dev/null) || { chk_fail "$label: encoding=base64 but the value does not decode" "remove &encoding=base64 from the path"; continue; }
    fi
    a=$(kit_anomalies "$v")
    if [ "$label" = username ]; then
      if [ "$(jget "$CHK_SF" "items.$idx.isPassword")" = true ]; then chk_fail "username path selects a password field" "correct the field mapping"
      else ok "username field is populated (value hidden)"; fi
    else
      CHK_VAL_PASS=$v
      if [ -n "$a" ]; then chk_warn "password $(kit_shape "$v"); anomalies: $a" "clean up the password in Secret Server (or compare below)"; else ok "password value: $(kit_shape "$v")"; fi
    fi
  done
  CHK_SF=""; v=""
}

chk_dl_compare() {
  local why="" ud k
  [ -n "$CHK_VAL_PASS" ] || return 0
  kit_noninteractive && { CHK_VAL_PASS=""; return 0; }
  printf '  %s?%s Paste the password that WORKS when typed manually (hidden; Enter alone skips): ' "$C_ACC" "$C_RST" >/dev/tty
  IFS= read -rs CHK_WANT </dev/tty || CHK_WANT=""; printf '\n' >/dev/tty
  if [ -z "$CHK_WANT" ]; then info "comparison skipped"
  elif [ "$CHK_VAL_PASS" = "$CHK_WANT" ]; then
    ok "the Secret Server value is byte-identical to the working password"
    note "so the worker gets the right password. Remaining suspects: the 12h credential cache (save the resource),"
    note "another worker serving the connection, or the username/domain shown above."
  else
    [ -z "$why" ] && [ "$(kit_trim "$CHK_VAL_PASS")" = "$CHK_WANT" ] && why="trimming whitespace"
    [ -z "$why" ] && [ "$(kit_html_unescape "$CHK_VAL_PASS")" = "$CHK_WANT" ] && why="HTML-unescaping (&amp; -> &)"
    [ -z "$why" ] && [ "$(kit_html_unescape "$(kit_trim "$CHK_VAL_PASS")")" = "$CHK_WANT" ] && why="trimming + HTML-unescaping"
    [ -z "$why" ] && [ "${CHK_VAL_PASS//[$'\r\n']/}" = "$CHK_WANT" ] && why="removing CR/LF"
    if [ -z "$why" ]; then printf -v ud '%b' "${CHK_VAL_PASS//%/\\x}"; [ "$ud" = "$CHK_WANT" ] && why="URL-decoding"; ud=""; fi
    if [ -n "$why" ]; then
      chk_fail "the Secret Server value DIFFERS from the working password; they match after $why" \
          "edit the password in Secret Server so it is stored exactly as typed, then save the resource in the Admin UI (clears the 12h cache)"
    else
      k=0; while [ $k -lt ${#CHK_VAL_PASS} ] && [ $k -lt ${#CHK_WANT} ] && [ "${CHK_VAL_PASS:k:1}" = "${CHK_WANT:k:1}" ]; do k=$((k+1)); done
      chk_fail "the Secret Server value DIFFERS from the working password (first difference at byte $k; ${#CHK_VAL_PASS} vs ${#CHK_WANT} bytes)" \
          "it is a genuinely different password: update the secret in Secret Server, then save the resource in the Admin UI"
    fi
  fi
  CHK_WANT=""; CHK_VAL_PASS=""
}

# ---------------------------------------------------------------- 6 report
chk_report() {
  local i n=0 sev shown=0 max=10 line
  [ ${#CHK_PROBS[@]} -gt 0 ] || { printf '\n'; ok "no problems found"; return 0; }
  kit_section "Most likely problems (failures first) and how to fix them"
  for sev in FAIL WARN; do
    for ((i=0; i<${#CHK_PROBS[@]}; i++)); do
      [ "${CHK_PSEV[i]}" = "$sev" ] || continue
      n=$((n+1))
      [ $shown -ge $max ] && continue
      shown=$((shown+1))
      if [ "$sev" = FAIL ]; then printf '  %s%d. [FAIL]%s %s\n' "$C_FAIL" "$shown" "$C_RST" "${CHK_PROBS[i]}"
      else printf '  %s%d. [WARN]%s %s\n' "$C_WARN" "$shown" "$C_RST" "${CHK_PROBS[i]}"; fi
      if [ -n "${CHK_FIXES[i]}" ]; then
        while IFS= read -r line; do note "fix: $line"; done <<<"${CHK_FIXES[i]}"
      fi
    done
  done
  [ $n -gt $max ] && note "... and $((n - max)) more above."
  return 0
}

# ---------------------------------------------------------------- entry
mode_check() {
  local rc=0
  kit_log_init check
  kit_banner "Check install - read-only health check (changes nothing)"
  chk_reset
  chk_discover
  chk_host
  chk_layout
  chk_connect
  chk_logs
  chk_delinea
  kit_summary || rc=$KIT_EXIT_FAIL
  chk_report
  return $rc
}

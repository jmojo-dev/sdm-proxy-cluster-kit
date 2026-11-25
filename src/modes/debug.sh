# shellcheck shell=bash
# ============================================================================
# sdm-proxy-cluster-kit :: src/modes/debug.sh  -> mode_debug
# Turn on verbose logging for one worker, follow its journal, and switch it
# off on exit or through an independent systemd timer.
#
# @env KIT_DEBUG_UNIT  unit to debug when several sdm units exist (e.g. sdm-worker)
# @env KIT_DEBUG_FILTER  log filter: all | secrets | rdp | errors (non-interactive default: all)
# @env KIT_DEBUG_MINUTES  minutes to follow the journal before reverting (default 30, max 1440)
# @env KIT_DEBUG_KEEP  1 = leave SDM_VERBOSE=true in place when done (no revert)
# @env KIT_ASSUME_YES  1 = answer yes to the confirmations when non-interactive
# ============================================================================

# Mode state (globals so the EXIT handler can see them).
DBG_UNIT=""; DBG_ENVFILE=""; DBG_PRIOR_STATE=""; DBG_PRIOR_VALUE=""
DBG_CHANGED=0; DBG_FINISHED=0; DBG_ARMED=0; DBG_START=""; DBG_END=""; DBG_INTERRUPTED=0; DBG_FILTER=""
DBG_RUNTIME=/run/sdm-proxy-cluster-kit-debug
DBG_SESSION=""; DBG_PRIOR_PROCESS=""

# dbg_prop UNIT PROP -> value. Works on systemd 219 (RHEL 7 / Amazon Linux 2),
# which has no `systemctl show --value` (added in systemd 230).
dbg_prop() { local l; l=$(systemctl show -p "$2" -- "$1" 2>/dev/null </dev/null | head -1); printf '%s' "${l#*=}"; }
dbg_main_pid() { local p; p=$(dbg_prop "$1" MainPID); [ -n "$p" ] && [ "$p" != 0 ] && echo "$p"; }

# dbg_envfiles UNIT -> one path per line. systemd 219 prints EnvironmentFile=
# for each entry, while newer versions print EnvironmentFiles=.
dbg_envfiles() {
  systemctl show -p EnvironmentFiles -- "$1" 2>/dev/null </dev/null \
    | sed -e 's/^EnvironmentFiles=//' -e 's/^EnvironmentFile=//' \
    | tr ' ' '\n' | grep -E '^-?/' | sed -e 's/^-//'
}

# dbg_pick_envfile UNIT -> path of the env file this unit loads, or nothing.
# Prefers /etc/sysconfig/<unit> (what `sdm install` writes); otherwise the last
# listed file, because later EnvironmentFile= entries override earlier ones.
dbg_pick_envfile() {
  local u=$1 files fb="/etc/sysconfig/${1%.service}"
  files=$(dbg_envfiles "$u")
  if [ -n "$files" ]; then
    if printf '%s\n' "$files" | grep -qxF "$fb"; then echo "$fb"; else printf '%s\n' "$files" | tail -1; fi
    return 0
  fi
  # Older systemctl may not list it; accept the fallback only if the unit text references it.
  if systemctl cat -- "$u" 2>/dev/null </dev/null | grep -qE "^[[:space:]]*EnvironmentFile=-?${fb}[[:space:]]*$"; then echo "$fb"; fi
}

# dbg_unquote VALUE -> VALUE without one pair of surrounding quotes (systemd strips them).
dbg_unquote() { local v=$1; case $v in \"*\"|\'*\') v=${v:1:${#v}-2};; esac; printf '%s' "$v"; }

# dbg_save_prior FILE -> sets DBG_PRIOR_STATE (absent|present) and DBG_PRIOR_VALUE.
dbg_save_prior() {
  DBG_PRIOR_VALUE=""
  if kit_envfile_has "$1" SDM_VERBOSE; then
    DBG_PRIOR_STATE=present
    DBG_PRIOR_VALUE=$(kit_envfile_get "$1" SDM_VERBOSE) || DBG_PRIOR_VALUE=""
  else
    DBG_PRIOR_STATE=absent
  fi
}

# dbg_pid_verbose PID -> SDM_VERBOSE as the process sees it, or "<unset>".
dbg_pid_verbose() { local v; if v=$(kit_proc_env "$1" SDM_VERBOSE); then printf '%s' "$v"; else printf '<unset>'; fi; }

# dbg_wait_active UNIT SECONDS -> 0 once active (and still active 2s later), 1 otherwise.
dbg_wait_active() {
  local u=$1 n=$2 i st
  for ((i=0; i<n; i++)); do
    st=$(systemctl is-active -- "$u" 2>/dev/null </dev/null)
    if [ "$st" = active ]; then
      sleep 2
      [ "$(systemctl is-active -- "$u" 2>/dev/null </dev/null)" = active ] && return 0
    elif [ "$st" = failed ]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

# The timer runs this same function in a separate systemd service. The lock on
# the private session directory serializes publication and both cleanup paths.
dbg_revert() (
  local session=$1 unit dropin expiry
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  [ -d "$session" ] || exit 0
  { exec 8<"$session"; } 2>/dev/null || { [ ! -d "$session" ]; exit; }
  flock -x 8 || exit 1
  [ -d "$session" ] || exit 0
  if [ -f "$session/state" ]; then
    { IFS= read -r unit && IFS= read -r dropin; } < "$session/state" || exit 1
    expiry="sdmkit-debug-${session##*.}"
    # Remove the optional env file first. Even a worker restart while systemd
    # still has the drop-in cached then reads only the original configuration.
    rm -f -- "$session/verbose" "$dropin" || exit 1
    rmdir -- "${dropin%/*}" 2>/dev/null || true
    timeout 15s systemctl daemon-reload </dev/null || exit 1
    if [ -f "$session/restart" ]; then
      timeout 70s systemctl restart -- "$unit" </dev/null || exit 1
      rm -f -- "$session/restart" || exit 1
    fi
    timeout 15s systemctl stop "$expiry.timer" >/dev/null 2>&1 || true
    rm -f -- "/run/systemd/system/$expiry.timer" "/run/systemd/system/$expiry.service" || exit 1
  fi
  rm -rf -- "$session" || exit 1
)

dbg_recover_sessions() {
  local session
  [ -e "$DBG_RUNTIME" ] || [ -L "$DBG_RUNTIME" ] || return 0
  kit_private_dir "$DBG_RUNTIME" || return 1
  for session in "$DBG_RUNTIME"/session.*; do
    [ -d "$session" ] || continue
    info "Cleaning up an interrupted debug session"
    dbg_revert "$session" || return 1
  done
}

# Load an optional environment file after the worker's existing files.
# Environment= would lose to any EnvironmentFile= already setting SDM_VERBOSE.
dbg_start_runtime() (
  local mins=$1 session=$DBG_SESSION dropdir dropin path name last='' expiry LC_ALL=C
  exec 8<"$session" && flock -x 8 || exit 1
  kit_trusted_dir /run/systemd/system || exit 1
  dropdir="/run/systemd/system/$DBG_UNIT.d"
  if [ ! -e "$dropdir" ]; then mkdir -m 0755 -- "$dropdir" || exit 1; fi
  kit_trusted_dir "$dropdir" || exit 1
  # systemd reads drop-ins in filename order across its search paths.
  while IFS= read -r path; do
    name=${path##*/}
    [[ $name > $last ]] && last=$name
  done < <(printf '%s\n' "$(dbg_prop "$DBG_UNIT" DropInPaths)" | sed 's| /|\n/|g')
  dropin="$dropdir/${last:+$last.}zz-sdmkit-${session##*.}.conf"
  expiry="/run/systemd/system/sdmkit-debug-${session##*.}"
  for path in "$dropin" "$expiry.timer" "$expiry.service"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || exit 1
  done
  printf '%s\n%s\n' "$DBG_UNIT" "$dropin" > "$session/state.tmp" &&
    mv -T -- "$session/state.tmp" "$session/state" || exit 1
  printf '[Service]\nEnvironmentFile=-%s/verbose\n' "$session" > "$session/worker.conf" || exit 1
  printf 'SDM_VERBOSE=true\n' > "$session/verbose.tmp" || exit 1

  # Use regular runtime units so Restart= works on systemd 219 as well.
  { declare -f dbg_revert && printf '\ndbg_revert "$1"\n'; } > "$session/revert" || exit 1
  cat > "$session/expiry.service" <<EOF || exit 1
[Unit]
Description=Expire temporary StrongDM debug logging
ConditionPathExists=$session/revert
[Service]
ExecStart=/bin/bash $session/revert $session
Restart=on-failure
RestartSec=5s
EOF
  cat > "$session/expiry.timer" <<EOF || exit 1
[Unit]
Description=StrongDM debug expiry timer
[Timer]
OnActiveSec=$((mins * 60 + 5))s
AccuracySec=1s
EOF
  # Create the unit files in their final directories for the local file labels.
  cp -T -- "$session/expiry.service" "$expiry.service" &&
    cp -T -- "$session/expiry.timer" "$expiry.timer" &&
    cp -T -- "$session/worker.conf" "$dropin" && timeout 15s systemctl daemon-reload </dev/null || exit 1
  [ "$(dbg_prop "${expiry##*/}.service" FragmentPath)" = "$expiry.service" ] &&
    [ "$(dbg_prop "${expiry##*/}.timer" FragmentPath)" = "$expiry.timer" ] || exit 1
  [ "$(dbg_envfiles "$DBG_UNIT" | tail -1)" = "$session/verbose" ] || exit 1
  timeout 15s systemctl start "${expiry##*/}.timer" </dev/null || exit 1
  [ "$(dbg_prop "${expiry##*/}.timer" SubState)" = waiting ] || exit 1
  : > "$session/restart" && mv -T -- "$session/verbose.tmp" "$session/verbose"
)

# dbg_filter_regex NAME -> extended regex for grep -Ei ("" = no filter). Returns 1 on an unknown name.
dbg_filter_regex() {
  case $1 in
    all) printf '';;
    secrets) printf '%s' 'credential field|FetchCredentials|tss-sdk-go|secretstore|secret store|delinea';;
    rdp) printf '%s' 'rdp|(^|[^a-z])nla([^a-z]|$)|credssp|kerberos|krb5|ntlm|spnego|tpkt|rdpdr|drdynvc|ephemeral user';;
    errors) printf '%s' 'level"?[=:] *"?(warn|warning|error|dpanic|panic|fatal)|panic:|goroutine [0-9]+ \[';;
    *) return 1;;
  esac
}

# dbg_harden_log: Ctrl-C reaches every process in the foreground group, including
# the `tee` that kit_log_init starts, and a dead tee would kill (SIGPIPE) the
# revert before it prints anything. Re-plumb the transcript through `tee -i`,
# writing to the original stdout saved in fd 7 by mode_debug.
# Safe to drop once kit_log_init itself uses `tee -i`.
dbg_harden_log() {
  [ -n "${KIT_LOG_FILE:-}" ] || return 0
  exec > >(exec tee -i -a "$KIT_LOG_FILE" >&7 2>&7) 2>&1
}

# dbg_capture_hint -> how to pull the captured window out of the journal later.
dbg_capture_hint() {
  local end=${DBG_END:-$(date '+%Y-%m-%d %H:%M:%S')}
  [ -n "$DBG_START" ] || return 0
  info "the verbose window is kept in the journal; to save it to a file later:"
  note "journalctl -u $DBG_UNIT --since '$DBG_START' --until '$end' --no-pager"
}

# dbg_finish: EXIT handler and normal end. Removes the runtime override and
# reports the restarted worker's effective environment.
# Runs once. Never exits (that would skip the remaining EXIT handlers).
dbg_finish() {
  local pid got
  [ "$DBG_FINISHED" = 1 ] && return 0
  DBG_FINISHED=1
  trap '' INT TERM HUP PIPE        # a second Ctrl-C or a hang-up must not cut the revert short
  [ "$DBG_ARMED" = 1 ] || return 0
  DBG_END=$(date '+%Y-%m-%d %H:%M:%S')
  kit_section "Switching verbose logging off"
  if [ -n "$DBG_SESSION" ]; then
    if dbg_revert "$DBG_SESSION"; then
      ok "removed the temporary SDM_VERBOSE override"
      if [ "$DBG_CHANGED" = 1 ]; then
        if dbg_wait_active "$DBG_UNIT" 60 && pid=$(dbg_main_pid "$DBG_UNIT"); then
          got=$(dbg_pid_verbose "$pid")
          ok "$DBG_UNIT MainPID $pid sees SDM_VERBOSE=$got after removing the override"
          if [ "$DBG_PRIOR_PROCESS" != '(no running process)' ] && [ "$got" != "$DBG_PRIOR_PROCESS" ]; then
            warn "the worker previously saw SDM_VERBOSE=$DBG_PRIOR_PROCESS; review its systemd environment"
          fi
        else
          fail "$DBG_UNIT has no stable MainPID after removing the override"
        fi
      fi
    else
      fail "could not complete cleanup for $DBG_UNIT"
      note "check: journalctl -u sdmkit-debug-${DBG_SESSION##*.}.service --no-pager"
    fi
  elif [ "$DBG_CHANGED" = 1 ]; then
    warn "KIT_DEBUG_KEEP=1: SDM_VERBOSE=true is LEFT ON in $DBG_ENVFILE"
    note "verbose logs are large and may contain request details; switch it off when done:"
    if [ "$DBG_PRIOR_STATE" = present ]; then
      note "sed -i 's/^SDM_VERBOSE=.*/SDM_VERBOSE=$DBG_PRIOR_VALUE/' $DBG_ENVFILE && systemctl restart $DBG_UNIT"
    else
      note "sed -i '/^SDM_VERBOSE=/d' $DBG_ENVFILE && systemctl restart $DBG_UNIT"
    fi
  else
    info "the kit did not change verbose logging for $DBG_UNIT"
  fi
  dbg_capture_hint
  [ -n "${KIT_LOG_FILE:-}" ] && info "kit transcript: $KIT_LOG_FILE"
  return 0
}

# dbg_find_unit -> sets DBG_UNIT, or exits.
dbg_find_unit() {
  local u found=()
  if [ -n "${KIT_DEBUG_UNIT:-}" ]; then
    systemctl cat -- "$KIT_DEBUG_UNIT" >/dev/null 2>&1 </dev/null || kit_die $KIT_EXIT_USAGE "KIT_DEBUG_UNIT=$KIT_DEBUG_UNIT is not a systemd unit on this host." \
      "systemctl cat $KIT_DEBUG_UNIT found nothing." \
      "systemctl list-units --all 'sdm*'     # see what exists
unset KIT_DEBUG_UNIT                   # or let the kit find it"
    DBG_UNIT=$KIT_DEBUG_UNIT; return 0
  fi
  if kit_unit_exists "$SDM_UNIT"; then DBG_UNIT=$SDM_UNIT; return 0; fi
  for u in "${KIT_FOREIGN_UNITS[@]}"; do kit_unit_exists "$u" && found+=("$u"); done
  case ${#found[@]} in
    0) kit_die $KIT_EXIT_PRECOND "No StrongDM worker service found on this host." \
         "Looked for systemd units: ${KIT_FOREIGN_UNITS[*]}. Debug mode works on an installed service." \
         "Run the kit again and choose 1 (New install), then come back to Debug.";;
    1) DBG_UNIT=${found[0]};;
    *) kit_pick KIT_DEBUG_UNIT "Several StrongDM services exist. Which one do you want to debug?" "${found[@]}"
       DBG_UNIT=$KIT_DEBUG_UNIT;;
  esac
  [ "$DBG_UNIT" = "$SDM_UNIT" ] || warn "$DBG_UNIT was not installed by this kit (it uses '$SDM_UNIT'); debugging it anyway"
}

# dbg_pick_filter -> sets DBG_FILTER (all|secrets|rdp|errors), or exits.
dbg_pick_filter() {
  local c=""
  if [ -n "${KIT_DEBUG_FILTER:-}" ]; then
    dbg_filter_regex "$KIT_DEBUG_FILTER" >/dev/null || kit_die $KIT_EXIT_USAGE "KIT_DEBUG_FILTER='$KIT_DEBUG_FILTER' is not a filter." \
      "Valid filters: all, secrets, rdp, errors." "export KIT_DEBUG_FILTER=all"
    DBG_FILTER=$KIT_DEBUG_FILTER; return 0
  fi
  if kit_noninteractive; then DBG_FILTER=all; return 0; fi
  kit_pick c "Which log lines do you want to see?" \
    "all       - every line from the worker" \
    "secrets   - secret store / Delinea credential lookups" \
    "rdp       - RDP, NLA, CredSSP, Kerberos and NTLM" \
    "errors    - warnings and errors only"
  DBG_FILTER=${c%% *}
}

mode_debug() {
  local total=6 pid act sub since user pverb fverb filt re mins rc follow_pid signal=0

  exec 7>&1                      # original stdout, for dbg_harden_log
  kit_log_init debug
  dbg_harden_log
  exec 7>&-
  trap 'exit 129' HUP            # ssh drop: still run the EXIT handlers (revert)
  kit_banner "Debug install - verbose logs, auto-revert when done"

  # ---- 1. preconditions
  kit_step 1 $total "Checking this host"
  if ! kit_has_systemd; then
    if kit_in_container; then
      kit_die $KIT_EXIT_PRECOND "This is a container without systemd, so there is no service to restart." \
        "SDM_VERBOSE is read once when the sdm process starts. In a container it comes from the container environment." \
        "Docker:      add  -e SDM_VERBOSE=true  (or SDM_VERBOSE: \"true\" under environment: in compose), recreate the container,
             then  docker logs -f <container>
Kubernetes:  kubectl set env deployment/<name> SDM_VERBOSE=true   # rolls the pods
             kubectl logs -f deployment/<name>
When done:   remove SDM_VERBOSE (kubectl set env deployment/<name> SDM_VERBOSE-) and recreate again."
    fi
    kit_die $KIT_EXIT_PRECOND "systemd is not running on this host." \
      "Debug mode restarts the worker through systemd and reads its journal." \
      "Run the kit on a systemd host (RHEL/Rocky/Alma 7-9, Amazon Linux, Ubuntu/Debian)."
  fi
  kit_require_root
  kit_lock_changes
  dbg_recover_sessions || kit_die $KIT_EXIT_PRECOND "Could not prepare the debug runtime directory or finish an interrupted debug session." \
    "Runtime state: $DBG_RUNTIME" "Check its ownership and the debug cleanup journal."
  kit_have journalctl || kit_die $KIT_EXIT_PRECOND "journalctl is not installed." \
    "Workers log to journald (SDM_LOG_OUTPUT=stdout); the kit follows them with journalctl." \
    "dnf install -y systemd      # RHEL family
apt-get install -y systemd  # Ubuntu / Debian"
  kit_have timeout || kit_ensure_cmds timeout
  mins=${KIT_DEBUG_MINUTES:-30}
  if ! [[ $mins =~ ^0*([1-9][0-9]{0,3})$ ]] || [ "${BASH_REMATCH[1]}" -gt 1440 ]; then
    kit_die $KIT_EXIT_USAGE "KIT_DEBUG_MINUTES='$mins' is not a number of minutes." "Use a whole number from 1 to 1440." "export KIT_DEBUG_MINUTES=30"
  fi
  mins=${BASH_REMATCH[1]}
  ok "systemd, journalctl and root are available"

  # ---- 2. which service
  kit_step 2 $total "Finding the worker service"
  dbg_find_unit
  DBG_UNIT=$(dbg_prop "$DBG_UNIT" Id)
  if ! [[ $DBG_UNIT =~ ^([a-zA-Z0-9_.:@-]|\\x[[:xdigit:]]{2})+\.service$ ]]; then
    kit_die $KIT_EXIT_PRECOND "The selected unit is not an installed systemd service." "" "Select a worker service with KIT_DEBUG_UNIT."
  fi
  DBG_ENVFILE=$(dbg_pick_envfile "$DBG_UNIT")
  if [ -z "$DBG_ENVFILE" ]; then
    kit_die $KIT_EXIT_PRECOND "$DBG_UNIT does not load an environment file, so SDM_VERBOSE cannot be set safely." \
      "'sdm install' creates the unit with EnvironmentFile=-/etc/sysconfig/${DBG_UNIT%.service}. This unit was set up some other way." \
      "Re-run the kit and choose 1 (New install) to install the service the supported way, or set it by hand:
systemctl edit $DBG_UNIT     # add:  [Service]  Environment=SDM_VERBOSE=true
systemctl restart $DBG_UNIT  # and remove the drop-in again when done"
  fi
  if [ -L "$DBG_ENVFILE" ] || ! kit_trusted_dir "$(dirname -- "$DBG_ENVFILE")"; then kit_die 3 "Unsafe environment file location." "" "Review the systemd unit configuration."; fi
  if [ ! -f "$DBG_ENVFILE" ]; then
    kit_die $KIT_EXIT_PRECOND "The env file $DBG_ENVFILE that $DBG_UNIT loads does not exist." \
      "'sdm install' always writes it (SDM_HOME, SDM_LOG_OUTPUT=stdout); without it this unit was not installed by 'sdm install', and creating one by guesswork could change how it runs." \
      "Re-run the kit and choose 1 (New install) - it repairs the env file without re-registering a healthy worker."
  fi
  kit_trusted_file "$DBG_ENVFILE" || kit_die 3 "Untrusted worker environment file." "" "Review ownership and write permissions before enabling debug."
  act=$(systemctl is-active -- "$DBG_UNIT" 2>/dev/null </dev/null); sub=$(dbg_prop "$DBG_UNIT" SubState)
  user=$(dbg_prop "$DBG_UNIT" User); pid=$(dbg_main_pid "$DBG_UNIT")
  since=$(dbg_prop "$DBG_UNIT" ActiveEnterTimestamp)
  if [ -n "$pid" ]; then pverb=$(dbg_pid_verbose "$pid"); else pverb="(no running process)"; fi
  DBG_PRIOR_PROCESS=$pverb
  if kit_envfile_has "$DBG_ENVFILE" SDM_VERBOSE; then fverb=$(kit_envfile_get "$DBG_ENVFILE" SDM_VERBOSE) || fverb='""'; else fverb="<not set>"; fi
  info "unit:         $DBG_UNIT  (${act:-unknown}/${sub:-?})"
  info "runs as:      ${user:-root}"
  info "MainPID:      ${pid:-none}   started: ${since:-n/a}"
  info "env file:     $DBG_ENVFILE"
  info "SDM_VERBOSE:  running process = $pverb   env file = $fverb"

  # ---- 3. confirm
  kit_step 3 $total "Confirm the restart"
  if [ "$act" != active ]; then
    warn "$DBG_UNIT is not running (state: ${act:-unknown}). That may be exactly what you are debugging."
    kit_confirm "Start it with verbose logging anyway?" y || kit_die $KIT_EXIT_ABORTED "Stopped at your request." "Nothing was changed." ""
  fi
  DBG_ARMED=1                    # from here on, the EXIT handler reports and reverts
  kit_on_exit dbg_finish
  if [ "$pverb" = true ] && [ "$(dbg_unquote "$fverb")" = true ]; then
    ok "verbose logging is already on for this process; no restart needed, nothing will be changed"
    DBG_START=$(date '+%Y-%m-%d %H:%M:%S')
  else
    warn "Restarting $DBG_UNIT DROPS every active session going through THIS worker"
    note "(other workers in the proxy cluster keep serving; users reconnect through them or this one)"
    if [ "${KIT_DEBUG_KEEP:-}" != 1 ]; then note "It is restarted again at the end to switch verbose logging off."; fi
    kit_confirm "Restart $DBG_UNIT with SDM_VERBOSE=true now?" n || kit_die $KIT_EXIT_ABORTED "Stopped at your request." "Nothing was changed." ""

    # ---- 4. set
    kit_step 4 $total "Turning on verbose logging"
    if [ "${KIT_DEBUG_KEEP:-}" != 1 ]; then
      kit_private_dir "$DBG_RUNTIME" && DBG_SESSION=$(mktemp -d "$DBG_RUNTIME/session.XXXXXXXX") &&
        dbg_start_runtime "$mins" ||
        kit_die $KIT_EXIT_FAIL "Could not enable the temporary debug override for $DBG_UNIT." \
          "Debug requires a systemd expiry timer and an environment file that loads last." "systemctl cat $DBG_UNIT"
      DBG_CHANGED=1
      ok "temporary SDM_VERBOSE=true override enabled with a systemd expiry timer"
    elif [ "$(dbg_unquote "$fverb")" = true ]; then
      info "$DBG_ENVFILE already has SDM_VERBOSE=true (the process just has not been restarted since); leaving the file alone"
    else
      dbg_save_prior "$DBG_ENVFILE"
      kit_envfile_set "$DBG_ENVFILE" SDM_VERBOSE true || kit_die $KIT_EXIT_FAIL "Could not write $DBG_ENVFILE." \
        "The file may be read-only or the disk full." "ls -l $DBG_ENVFILE; df -h /etc"
      DBG_CHANGED=1
      ok "SDM_VERBOSE=true written to $DBG_ENVFILE (previously: $([ "$DBG_PRIOR_STATE" = present ] && printf '%s' "$DBG_PRIOR_VALUE" || printf 'not set'))"
    fi

    # ---- 5. restart
    kit_step 5 $total "Restarting $DBG_UNIT"
    DBG_START=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl restart -- "$DBG_UNIT" </dev/null && dbg_wait_active "$DBG_UNIT" 60 || kit_die $KIT_EXIT_FAIL "$DBG_UNIT did not become active within 60 seconds." \
      "Last journal lines:
$(journalctl -u "$DBG_UNIT" -n 20 --no-pager -o short-iso 2>&1)" \
      "systemctl status $DBG_UNIT
journalctl -u $DBG_UNIT --since '$DBG_START' --no-pager"
    pid=$(dbg_main_pid "$DBG_UNIT")
    pverb=$(dbg_pid_verbose "${pid:-0}")
    [ -n "$pid" ] && [ "$pverb" = true ] || kit_die $KIT_EXIT_FAIL "The restarted process (MainPID ${pid:-none}) does not see SDM_VERBOSE=true (it sees $pverb)." \
      "Something later in the unit overrides it (another EnvironmentFile=, or a wrapper script)." \
      "systemctl cat $DBG_UNIT
systemctl show -p EnvironmentFiles -p Environment $DBG_UNIT"
    ok "$DBG_UNIT is active, MainPID $pid has SDM_VERBOSE=true"
  fi

  # ---- 6. follow
  kit_step 6 $total "Following the logs"
  dbg_pick_filter
  filt=$DBG_FILTER
  re=$(dbg_filter_regex "$filt")
  info "filter: $filt   time limit: $mins minute(s)"
  warn "verbose logs can contain sensitive request details"
  printf '\n%s+----------------------------------------------------------------------+%s\n' "$C_ACC" "$C_RST"
  printf '%s|%s %s%-68s%s %s|%s\n' "$C_ACC" "$C_RST" "$C_HEAD" "Reproduce the problem now." "$C_RST" "$C_ACC" "$C_RST"
  printf '%s|%s %-68s %s|%s\n' "$C_ACC" "$C_RST" "Press Ctrl-C when done." "$C_ACC" "$C_RST"
  printf '%s+----------------------------------------------------------------------+%s\n\n' "$C_ACC" "$C_RST"
  # Waiting for a background job lets Bash handle disconnects immediately.
  trap 'signal=130' INT
  trap 'signal=143' TERM
  trap 'signal=129' HUP
  local journal_args=(journalctl -u "$DBG_UNIT" -f -o short-iso --no-pager --since "$DBG_START")
  # An orphaned journal reader must not keep the kit's changes lock alive.
  if [ -z "$re" ]; then
    timeout "${mins}m" "${journal_args[@]}" 9>&- </dev/null &
  else
    timeout "${mins}m" "${journal_args[@]}" 9>&- </dev/null > >(grep -E -i --line-buffered -e "$re" 9>&-) &
  fi
  follow_pid=$!
  if [ "$signal" = 0 ]; then wait "$follow_pid"; rc=$?; else rc=$signal; fi
  if [ "$signal" != 0 ]; then
    trap '' INT TERM HUP
    kill -TERM "$follow_pid" 2>/dev/null || true
    wait "$follow_pid" 2>/dev/null || true
    [ "$signal" = 130 ] || exit "$signal"
    DBG_INTERRUPTED=1
  fi
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  echo
  if [ "$DBG_INTERRUPTED" = 1 ]; then info "stopped with Ctrl-C"
  elif [ "$rc" = 124 ]; then info "time limit of $mins minute(s) reached"
  else warn "journalctl stopped unexpectedly (exit $rc)"; fi

  dbg_finish
  kit_summary
}

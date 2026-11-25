#!/usr/bin/env bash
# Run in a fresh systemd test container; this provisions the kit's real unit.
KIT_ROOT=${KIT_ROOT:-/kit}
# shellcheck disable=SC1090,SC1091
. "$KIT_ROOT/src/lib/common.sh"
# shellcheck disable=SC1090,SC1091
. "$KIT_ROOT/src/modes/install.sh"
# shellcheck disable=SC1090,SC1091
. "$KIT_ROOT/tests/lib/testlib.sh"
kit_has_systemd || t_skip "requires an isolated systemd boot"

fixture=$T_WORK/sdm
cat > "$fixture" <<'FIXTURE'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'sdm version 1.2.3 (fixture)';;
  nodesecrets)
    file=$SDM_HOME/secretenv.enc
    case "$2" in
      list) sort -u "$file";;
      set)
        shift 2
        for key; do
          IFS= read -r value && [ -n "$value" ] || exit 1
          printf '%s\n' "$key"
        done > "$file"
        chmod 0600 "$file";;
    esac;;
  worker)
    mode=$SDM_HOME/recovery-test-mode
    case $(cat "$mode" 2>/dev/null) in
      crash)
        printf 'waiting\n' > "$mode"
        printf '%s\n' 'running proxy worker' 'initial authsync complete'
        exit 1;;
      waiting) echo 'worker is waiting for authentication';;
      *) printf '%s\n' 'running proxy worker' 'initial authsync complete';;
    esac
    exec sleep infinity;;
esac
FIXTURE
chmod 0755 "$fixture"

run_install() (
  kit_in_container() { return 1; }
  kit_log_init() { :; }
  inst_reach() { :; }
  inst_binary() { INST_NEW_BIN=$fixture; }
  case "${2:-}" in
    before_unit) inst_write_unit() { kill -KILL "$BASHPID"; };;
    before_activation) inst_start() { kill -KILL "$BASHPID"; };;
  esac
  KIT_NONINTERACTIVE=1; KIT_ASSUME_YES=1; KIT_DELINEA=no; KIT_START_TIMEOUT=6
  SDM_APP_DOMAIN=app.strongdm.com; SDM_PROXY_CLUSTER_ACCESS_KEY=pk-fixture; SDM_PROXY_CLUSTER_SECRET_KEY='fixture-secret'
  SDM_BIND_ADDRESS=$1
  mode_install
)

live_bind() {
  local pid
  pid=$(kit_unit_main_pid "$SDM_UNIT") || return 1
  tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^SDM_BIND_ADDRESS=//p'
}

result=$T_WORK/install.log
run_install :8443 > "$result" 2>&1
t_eq "fresh worker verified" "$?" 0
[ "$T_FAILS" -eq 0 ] || { t_tail "$result"; t_done; }
old_pid=$(kit_unit_main_pid "$SDM_UNIT")
t_eq "first worker loaded the requested bind" "$(live_bind)" :8443

run_install :443 before_unit > "$result" 2>&1
t_eq "test interrupted before publishing the unit" "$?" 137
t_eq "incomplete provisioning is recorded privately" "$(t_mode "$INST_PENDING_FILE")" '600 root:root'
t_eq "provisioning record survives the interruption" "$(kit_envfile_get "$INST_PENDING_FILE" PHASE)" provision
t_eq "environment already contains the changed bind" "$(kit_envfile_get "$SDM_SYSCONFIG" SDM_BIND_ADDRESS)" :443
t_eq "old worker still uses its original bind" "$(live_bind)" :8443

run_install :443 before_activation > "$result" 2>&1
t_eq "test interrupted after publishing configuration" "$?" 137
t_has "retry completed the unit updates for the new bind" "/etc/systemd/system/$SDM_UNIT.service" 'AmbientCapabilities=CAP_NET_BIND_SERVICE'
t_eq "completed provisioning is marked for activation" "$(kit_envfile_get "$INST_PENDING_FILE" PHASE)" activate
t_eq "old worker was kept running during provisioning" "$(kit_unit_main_pid "$SDM_UNIT")" "$old_pid"

run_install :443 > "$result" 2>&1
t_eq "retry activated the pending configuration" "$?" 0
t_eq "live worker loaded the new bind" "$(live_bind)" :443
t_eq "verified activation clears the pending record" "$(t_mode "$INST_PENDING_FILE")" missing
active_pid=$(kit_unit_main_pid "$SDM_UNIT")
run_install :443 > "$result" 2>&1
t_eq "healthy retry verifies the current invocation" "$?" 0
t_eq "healthy retry keeps the same PID" "$(kit_unit_main_pid "$SDM_UNIT")" "$active_pid"

# Force the legacy identity branch while still querying the real unit and journal.
(
  systemctl() {
    if [[ $* == *' -p InvocationID' ]]; then
      command systemctl "$@" | sed '/^InvocationID=/d'
      return 1
    fi
    command systemctl "$@"
  }
  KIT_START_TIMEOUT=0 INST_BIND=:443 inst_start
) > "$result" 2>&1
t_eq "legacy PID and start boundary verify a live worker" "$?" 0
t_eq "legacy verification keeps the same PID" "$(kit_unit_main_pid "$SDM_UNIT")" "$active_pid"

(
  journalctl() {
    printf '%s\n' '[    9.900000] host sdm[123]: running proxy worker' \
      '[   10.100000] host sdm[123]: initial authsync complete'
  }
  inst_invocation_messages '123|1000|10000000|'
) > "$result"
t_hasnt "legacy boundary rejects earlier entries with the same PID" "$result" 'running proxy worker'
t_has "legacy boundary preserves messages from the current worker" "$result" 'initial authsync complete'

kit_as_worker "$SDM_HOME_DIR" bash -c 'printf "crash\n" > "$SDM_HOME/recovery-test-mode"'
(
  inst_mark_pending
  KIT_START_TIMEOUT=6 INST_BIND=:443 inst_start
) > "$result" 2>&1
t_eq "startup rejects success markers from the crashed worker" "$?" 1
t_eq "replacement is active during the failed readiness check" "$(kit_unit_prop "$SDM_UNIT" ActiveState)" active
t_eq "failed readiness retains pending activation" "$(kit_envfile_get "$INST_PENDING_FILE" PHASE)" activate
replacement_pid=$(kit_unit_main_pid "$SDM_UNIT")
(
  INST_PENDING_FILE=$T_WORK/no-pending-record
  KIT_START_TIMEOUT=0 INST_BIND=:443 inst_start
) > "$result" 2>&1
t_eq "already active worker requires evidence from its own invocation" "$?" 1
t_eq "verification of an active worker leaves its PID alone" "$(kit_unit_main_pid "$SDM_UNIT")" "$replacement_pid"

kit_as_worker "$SDM_HOME_DIR" rm "$SDM_HOME_DIR/recovery-test-mode"
run_install :443 > "$result" 2>&1
t_eq "pending activation can recover after startup failure" "$?" 0
t_eq "subsequent readiness clears the activation record" "$(t_mode "$INST_PENDING_FILE")" missing

active_pid=$(kit_unit_main_pid "$SDM_UNIT")
kit_as_worker "$SDM_HOME_DIR" bash -c 'printf "waiting\n" > "$SDM_HOME/recovery-test-mode"'
(
  journalctl() {
    local messages
    messages=$(command journalctl "$@") || return 1
    if [ ! -e "$T_WORK/restarted-during-journal-read" ]; then
      touch "$T_WORK/restarted-during-journal-read"
      systemctl restart "$SDM_UNIT" || return 1
    fi
    printf '%s\n' "$messages"
  }
  KIT_START_TIMEOUT=0 INST_BIND=:443 inst_start
) > "$result" 2>&1
t_eq "readiness rejects a worker replaced during journal verification" "$?" 1
t_eq "test replaced the worker during verification" "$([ "$(kit_unit_main_pid "$SDM_UNIT")" != "$active_pid" ] && echo yes)" yes
t_done

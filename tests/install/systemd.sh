#!/usr/bin/env bash
# install.sh helpers against real systemd with a FAKE /opt/strongdm/bin/sdm.
# Needs a container booted with systemd and the repo at /kit. Exit 0 = pass.
#   docker run -d --name kit-sd --privileged --cgroupns=host \
#     -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
#     -v "$PWD":/kit:ro <ubuntu:22.04 + systemd image> /sbin/init
#   docker exec kit-sd bash /kit/tests/install/systemd.sh
# Covers: ours-healthy / key change / not running, foreign replacement and
# unmanaged-process refusal, Delinea sealing + plaintext removal, start wait success,
# failure classification (bad keys, port in use, 203/EXEC).
KIT=${KIT:-/kit}
# shellcheck disable=SC1090,SC1091
. "$KIT/src/lib/common.sh"; . "$KIT/src/modes/install.sh"
trap - EXIT
n=0; bad=0
t() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; bad=$((bad+1)); fi; }
has() { n=$((n+1)); if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok   $1"; else echo "FAIL $1: missing [$3]"; printf '%s\n' "$2" | tail -15; bad=$((bad+1)); fi; }
hasnt() { n=$((n+1)); if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL $1: unexpected [$3]"; bad=$((bad+1)); else echo "ok   $1"; fi; }
kit_has_systemd || { echo "SKIP: systemd not running (needs a systemd-booted container, see tests/run-systemd.sh)"; exit 77; }

mkdir -p /opt/strongdm/bin /etc/sysconfig /opt/fake
cat > /opt/strongdm/bin/sdm <<'F'
#!/bin/bash
case "$1" in
  --version) echo "sdm version 1.2.3 (fake) (crypto)";;
  nodesecrets)
    [ "$(id -u)" != 0 ] || exit 3
    [ "$2" != set ] || [ ! -e "$SDM_HOME/deny-seal" ] || exit 1
    f="$SDM_HOME/secretenv.enc"
    case "$2" in
      list) [ -f "$f" ] && sort -u "$f" || echo "no sealed secrets file present" >&2;;
      set) shift 2; for k; do IFS= read -r v || { echo "cannot read value for $k" >&2; exit 1; }; [ -n "$v" ] || exit 1; echo "$k" >> "$f"; done
           chown "$(stat -c %u:%g "$SDM_HOME")" "$f"; chmod 0600 "$f"; echo "sealed $* into $f";;
    esac;;
  worker)
    case "${FAKE_MODE:-ok}" in
      ok) echo 'level=info msg="Starting strongDM worker"'; sleep 2
          echo 'level=info msg="[cli.Worker] running proxy worker" workerID=w-1'; sleep 1
          echo 'level=info msg="initial authsync complete"'; exec sleep 100000;;
      auth) echo 'level=info msg="secretenv: using sealed sidecar secret source (default)"'
            echo 'level=error msg="[cli.Error]" error="failed to initialize proxy cluster key authentication: invalid operation: invalid proxy cluster key"'; exit 2;;
      port) echo 'level=error msg="cannot bind TCP address: listen tcp4 :8443: bind: address already in use"'; exit 1;;
    esac;;
esac
F
chmod 0755 /opt/strongdm/bin/sdm
# Drive the real install entry with an offline CLI fixture; systemd and file permissions are real.
fixture=$(mktemp /root/kit-fixture.XXXXXX)
mv /opt/strongdm/bin/sdm "$fixture"; rmdir /opt/strongdm/bin /opt/strongdm
fresh_install() (
  kit_in_container() { return 1; }
  kit_selinux_mode() { echo Enforcing; }
  setenforce() { touch /run/kit-test-setenforce; return 1; }
  inst_reach() { :; }
  inst_binary() { INST_NEW_BIN=$fixture; }
  KIT_NONINTERACTIVE=1; KIT_ASSUME_YES=1; KIT_DELINEA=${KIT_DELINEA:-no}
  SDM_APP_DOMAIN=app.strongdm.com; SDM_PROXY_CLUSTER_ACCESS_KEY=pk-fixture; SDM_PROXY_CLUSTER_SECRET_KEY=${SDM_PROXY_CLUSTER_SECRET_KEY:-example-cluster-value}
  mode_install
)
inst_ensure_user >/dev/null || exit 1
kit_as_worker "$SDM_HOME_DIR" touch "$SDM_HOME_DIR/deny-seal"
out=$(fresh_install 2>&1); t "sealing failure stops provisioning" "$?" 1
t "no plaintext fallback written" "$([ ! -e "$SDM_SYSCONFIG" ] && echo y)" y
kit_as_worker "$SDM_HOME_DIR" rm "$SDM_HOME_DIR/deny-seal"
out=$(fresh_install 2>&1); rc=$?; t "fresh provisioning completes" "$rc" 0
if [ "$rc" != 0 ]; then printf '%s\n' "$out" | tail -20; exit 1; fi
t "SELinux enforcement was never changed" "$([ ! -e /run/kit-test-setenforce ] && echo y)" y
t "fresh unit is active" "$(systemctl is-active "$SDM_UNIT")" active
t "fresh service runs as worker" "$(kit_unit_prop "$SDM_UNIT" User)" sdm
t "fresh config private to root" "$(stat -c '%u:%a' "$SDM_SYSCONFIG")" 0:600
t "worker cannot write administrative directory" "$(kit_as_worker "$SDM_HOME_DIR" test -w "$KIT_DIR"; echo $?)" 1
hasnt "cluster credential hidden" "$out" example-cluster-value
out=$(KIT_DELINEA=yes DELINEA_USERNAME=fixture-user DELINEA_PASSWORD=fixture-pass fresh_install 2>&1)
t "initial Delinea provisioning" "$?" 0
pid=$(kit_unit_main_pid "$SDM_UNIT")
sealed=$(sha256sum "$SDM_SIDECAR")
for which in same changed absent; do
  case $which in
    same) out=$(KIT_DELINEA=yes DELINEA_USERNAME=fixture-user DELINEA_PASSWORD=fixture-pass fresh_install 2>&1);;
    changed) out=$(KIT_DELINEA=yes DELINEA_USERNAME=other-user DELINEA_PASSWORD=sdm-worker fresh_install 2>&1);;
    absent) out=$(KIT_DELINEA=yes fresh_install 2>&1);;
  esac
  t "retaining Delinea pair ($which inputs) succeeds" "$?" 0
  t "retaining Delinea pair ($which inputs) leaves service running" "$(kit_unit_main_pid "$SDM_UNIT")" "$pid"
  t "retaining Delinea pair ($which inputs) skips sealing" "$(sha256sum "$SDM_SIDECAR")" "$sealed"
done
out=$(KIT_DELINEA=yes KIT_ROTATE_DELINEA=yes DELINEA_USERNAME=other-user DELINEA_PASSWORD=other-pass fresh_install 2>&1)
t "explicit Delinea rotation succeeds" "$?" 0
t "explicit rotation writes the pair" "$([ "$(sha256sum "$SDM_SIDECAR")" != "$sealed" ] && echo y)" y
t "explicit rotation activates new credentials" "$([ "$(kit_unit_main_pid "$SDM_UNIT")" != "$pid" ] && echo y)" y
hasnt "rotation hides new password" "$out" other-pass
cat >> "$SDM_SYSCONFIG" <<'CUSTOM'
# Local worker configuration
SSL_CERT_FILE="/etc/site certs.pem"
GOMEMLIMIT=240MiB
CUSTOM_VALUE="first line
SDM_HOME=inside a quoted value
last line"
CUSTOM_CONTINUED=join\
SDM_BIND_ADDRESS=literal
SDM_LOG_OUTPUT=stdout
CUSTOM
out=$(SDM_PROXY_CLUSTER_SECRET_KEY=rotated-fixture fresh_install 2>&1)
t "cluster key rotation succeeds with custom environment" "$?" 0
pid=$(kit_unit_main_pid "$SDM_UNIT")
setting() {
  local entry
  while IFS= read -r -d '' entry; do
    [[ $entry == "$1="* ]] && { printf '%s' "${entry#*=}"; return; }
  done < "/proc/$pid/environ"
}
t "worker retains custom CA path" "$(setting SSL_CERT_FILE)" "/etc/site certs.pem"
t "worker retains memory limit" "$(setting GOMEMLIMIT)" 240MiB
t "worker retains multiline quoted value" "$(setting CUSTOM_VALUE)" $'first line\nSDM_HOME=inside a quoted value\nlast line'
t "worker retains continuation" "$(setting CUSTOM_CONTINUED)" 'joinSDM_BIND_ADDRESS=literal'
t "worker receives expected core settings" "$(setting SDM_HOME) / $(setting SDM_BIND_ADDRESS)" "$SDM_HOME_DIR / :8443"
t "duplicate managed key is removed" "$(grep -c '^SDM_LOG_OUTPUT=' "$SDM_SYSCONFIG")" 1
t "rotated environment remains protected" "$(stat -c '%u:%a' "$SDM_SYSCONFIG")" 0:600
t "rotated cluster key absent from environment" "$(setting SDM_PROXY_CLUSTER_SECRET_KEY)" ""
kit_envfile_set "$SDM_SYSCONFIG" SDM_SECRETS_FILE /run/secrets/worker
sealed=$(sha256sum "$SDM_SIDECAR")
out=$(SDM_PROXY_CLUSTER_SECRET_KEY=another-rotation fresh_install 2>&1)
t "external credential source stops sidecar rotation" "$?" 1
has "external source remediation" "$out" SDM_SECRETS_FILE
t "external credential source leaves sidecar untouched" "$(sha256sum "$SDM_SIDECAR")" "$sealed"
t "external credential source leaves worker running" "$(kit_unit_main_pid "$SDM_UNIT")" "$pid"
kit_envfile_unset "$SDM_SYSCONFIG" SDM_SECRETS_FILE
systemctl stop "$SDM_UNIT"; rm -f "$fixture"
cat > /etc/systemd/system/sdm-worker.service <<'U'
[Unit]
Description=StrongDM worker service.
ConditionFileIsExecutable=/opt/strongdm/bin/sdm
[Service]
ExecStart=/opt/strongdm/bin/sdm worker
WorkingDirectory=/home/sdm/.sdm
User=sdm
Restart=always
RestartSec=3
EnvironmentFile=-/etc/sysconfig/sdm-worker
[Install]
WantedBy=multi-user.target
U
SDM_APP_DOMAIN=app.strongdm.com; INST_BIND=:8443; INST_SELINUX=Disabled
SDM_PROXY_CLUSTER_ACCESS_KEY=pk-AAAA1111; SDM_PROXY_CLUSTER_SECRET_KEY='sec-ZZZ/999+='
inst_ensure_user >/dev/null
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\nSDM_APP_DOMAIN=app.strongdm.com\nDELINEA_USERNAME=old-user\nDELINEA_PASSWORD=old-pass\n' > /etc/sysconfig/sdm-worker
chown sdm: /etc/sysconfig/sdm-worker; chmod 0700 /etc/sysconfig/sdm-worker
printf 'SDM_PROXY_CLUSTER_ACCESS_KEY\nSDM_PROXY_CLUSTER_SECRET_KEY\n' > /home/sdm/.sdm/secretenv.enc
: > /home/sdm/.sdm/state.kv; chown sdm: /home/sdm/.sdm/*
inst_state_set KEY_FP "$(inst_key_fp)"
systemctl daemon-reload; systemctl enable --now sdm-worker >/dev/null 2>&1; sleep 4

# ---- ours
inst_analyze
t "ours healthy" "$INST_CLASS" OURS-HEALTHY
SDM_PROXY_CLUSTER_SECRET_KEY='rotated'; inst_analyze
t "key change -> repair class" "$INST_CLASS" OURS-NEEDS-REPAIR
has "key change -> reinstall" "${INST_REINSTALL[*]}" "differ from the installed"
SDM_PROXY_CLUSTER_SECRET_KEY='sec-ZZZ/999+='
SDM_APP_DOMAIN=app.eu.strongdm.com; inst_analyze; has "region change -> reinstall" "${INST_REINSTALL[*]}" "region changes"
SDM_APP_DOMAIN=app.strongdm.com
mv "$INST_STATE_FILE" /tmp/state.bak; inst_analyze; t "no fp -> keys unknown" "$INST_KEYS_UNKNOWN/$INST_CLASS" "1/OURS-HEALTHY"; mv /tmp/state.bak "$INST_STATE_FILE"
systemctl stop sdm-worker; inst_analyze
t "stopped -> repair" "$INST_CLASS" OURS-NEEDS-REPAIR; has "not running" "${INST_REPAIRS[*]}" "is not running"
chown root /home/sdm/.sdm/state.kv; inst_analyze; has "ownership finding" "${INST_REPAIRS[*]}" "state.kv is owned by root"
INST_DO_INSTALL=0; out=$(inst_repair 2>&1); t "unsafe ownership rejected" "$?" 1
chown sdm: /home/sdm/.sdm/state.kv

# ---- Delinea sealing (fake nodesecrets) + plaintext removal
INST_DELINEA=yes; DELINEA_USERNAME='svc-del'; DELINEA_PASSWORD='p@ss word"1'; INST_PLAINTEXT=""
out=$(inst_seal 2>&1); t "seal rc" "$?" 0
has "sealed both" "$out" "sealed: DELINEA_USERNAME, DELINEA_PASSWORD"
hasnt "pw not printed" "$out" "$DELINEA_PASSWORD"
t "plaintext removed" "$(grep -c '^DELINEA_' /etc/sysconfig/sdm-worker)" 0
t "sidecar owner" "$(stat -c %U /home/sdm/.sdm/secretenv.enc)" sdm
t "env file mode kept" "$(stat -c '%a %U' /etc/sysconfig/sdm-worker)" "600 root"
DELINEA_SERVER_URL=https://t.secretservercloud.com; INST_DO_INSTALL=0
out=$(inst_envfile 2>&1); t "url written" "$(kit_envfile_get /etc/sysconfig/sdm-worker DELINEA_SERVER_URL)" "$DELINEA_SERVER_URL"

# ---- start / wait
INST_NEED_RESTART=1; out=$(KIT_START_TIMEOUT=40 inst_start 2>&1); t "start rc" "$?" 0
has "start ok" "$out" "running proxy worker, initial authsync complete"
INST_NEED_RESTART=0; out=$(inst_start 2>&1); has "no needless restart" "$out" "kept running"
inst_analyze; t "healthy after start" "$INST_CLASS" OURS-HEALTHY
out=$(inst_verify_scrub 2>&1); has "scrub ok" "$out" "no secret values"
out=$(INST_DO_INSTALL=0 inst_final 2>&1); has "final verify hint" "$out" "choose 3 to verify"; has "final sealed names" "$out" "DELINEA_PASSWORD"

# ---- failure classification
kit_envfile_set /etc/sysconfig/sdm-worker FAKE_MODE auth; INST_NEED_RESTART=1
out=$( (KIT_START_TIMEOUT=40 inst_start) 2>&1); t "auth fail rc" "$?" 1; has "auth classified" "$out" "rejected the proxy cluster keys"
kit_envfile_set /etc/sysconfig/sdm-worker FAKE_MODE port
out=$( (KIT_START_TIMEOUT=40 inst_start) 2>&1); t "port fail rc" "$?" 1; has "port classified" "$out" "already in use"
kit_envfile_unset /etc/sysconfig/sdm-worker FAKE_MODE
chmod 0644 /opt/strongdm/bin/sdm; sed -i '/^ConditionFileIsExecutable/d' /etc/systemd/system/sdm-worker.service
out=$( (KIT_START_TIMEOUT=20 inst_start) 2>&1); t "203 rc" "$?" 1; has "203 classified" "$out" "203/EXEC"
chmod 0755 /opt/strongdm/bin/sdm; systemctl daemon-reload
out=$(KIT_START_TIMEOUT=40 inst_start 2>&1); t "recovered" "$?" 0

# ---- foreign unit + stray process, REPLACE, re-run
cp /bin/bash /opt/fake/sdm
cat > /etc/systemd/system/sdm-relay.service <<'U'
[Service]
ExecStart=/opt/fake/sdm -c "sleep 100000; :" relay
WorkingDirectory=/root/.sdm
EnvironmentFile=-/etc/sysconfig/sdm-proxy
[Install]
WantedBy=multi-user.target
U
mkdir -p /root/.sdm; : > /root/.sdm/secretenv.enc
printf 'SDM_RELAY_TOKEN=dummy\nSDM_HOME=/root/.sdm\n' > /etc/sysconfig/sdm-proxy
systemctl daemon-reload; systemctl enable --now sdm-relay >/dev/null 2>&1
setsid /opt/fake/sdm -c 'sleep 100000; :' gateway </dev/null >/dev/null 2>&1 & stray=$!
sleep 2
inst_analyze
t "foreign class" "$INST_CLASS" FOREIGN
t "foreign unit" "${INST_FOREIGN_UNITS[*]}" sdm-relay
t "stray pid" "${INST_FOREIGN_PIDS[*]}" "$stray"
has "relay proc attributed" "${INST_FINDINGS[*]}" "unit sdm-relay, stopped with it"
t "ours still seen" "$INST_OURS" 1
out=$( (KIT_NONINTERACTIVE=1 inst_report_and_decide) 2>&1 </dev/null); t "unmanaged process -> 3" "$?" 3
kill "$stray"; wait "$stray" 2>/dev/null
inst_analyze
out=$( (KIT_NONINTERACTIVE=1 inst_report_and_decide) 2>&1 </dev/null); t "no KIT_REPLACE -> 2" "$?" 2
KIT_BACKUP_CERT=/root/kit-test-backup.pem
openssl req -x509 -nodes -newkey rsa:2048 -subj /CN=fixture -days 1 -keyout /root/kit-test-backup.key -out "$KIT_BACKUP_CERT" >/dev/null 2>&1 || exit 1
out=$(KIT_BACKUP_CERT=/etc/hosts inst_replace_foreign 2>&1); t "invalid backup certificate aborts replacement" "$?" 1
t "backup failure leaves foreign unit active" "$(systemctl is-active sdm-relay)" active
out=$( (trap kit_run_exit_handlers EXIT; inst_replace_foreign; systemctl start sdm-worker; inst_replacement_commit) 2>&1); t "replace rc" "$?" 0
t "relay stopped" "$(systemctl is-active sdm-relay)" inactive
t "relay disabled" "$(systemctl is-enabled sdm-relay)" disabled
t "relay unit kept" "$([ -f /etc/systemd/system/sdm-relay.service ] && echo y)" y
t "ours untouched" "$(systemctl is-active sdm-worker)" active
b=$(dirname "$(find /var/backups/sdm-proxy-cluster-kit -name COMPLETE -type f -print -quit)")
t "one completed backup" "$(find /var/backups/sdm-proxy-cluster-kit -name COMPLETE -type f | wc -l)" 1
t "backup protected" "$(stat -c %a "$b")" 700
inst_analyze
t "rerun not foreign" "$INST_CLASS" OURS-HEALTHY
has "rerun info" "${INST_INFO[*]}" "unit sdm-relay: replaced by an earlier run"
systemctl enable sdm-relay >/dev/null 2>&1; inst_analyze; t "re-enabled -> foreign again" "$INST_CLASS" FOREIGN

echo "== $((n-bad))/$n passed"
[ $bad = 0 ]

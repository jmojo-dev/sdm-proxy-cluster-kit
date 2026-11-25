#!/usr/bin/env bash
# Run on a disposable systemd host. Tests the real replacement lifecycle with an offline CLI.
KIT=${KIT:-/kit}
# shellcheck disable=SC1090,SC1091
. "$KIT/src/lib/common.sh"; . "$KIT/src/modes/install.sh"
trap - EXIT
kit_has_systemd || { echo "SKIP: systemd is not running"; exit 77; }

set -e
check() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL %s (got %s, wanted %s)\n' "$1" "$2" "$3"
    tail -40 "$output"
    exit 1
  fi
  printf 'ok   %s\n' "$1"
}
unit_state() {
  local active enabled
  active=$(systemctl is-active "$1") || true
  enabled=$(systemctl is-enabled "$1" 2>/dev/null) || true
  printf '%s/%s\n' "$active" "$enabled"
}

work=$(mktemp -d /root/sdm-replacement-test.XXXXXX)
output="$work/out"
cert="$work/cert.pem"
openssl req -x509 -nodes -newkey rsa:2048 -subj /CN=fixture -days 1 -keyout "$work/key" -out "$cert" 2>/dev/null
kit_trusted_file "$cert"
mkdir -p /etc/sysconfig

install_fixture() {
  local scenario=$1 replace=${2:-yes} rc=0
  KIT="$KIT" KIT_BACKUP_CERT="$cert" KIT_REPLACE="$replace" FIXTURE="$work/$scenario" SCENARIO="$scenario" \
    bash -c '
      . "$KIT/src/lib/common.sh"
      . "$KIT/src/modes/install.sh"
      kit_in_container() { return 1; }
      inst_reach() { :; }
      inst_binary() { INST_NEW_BIN=$FIXTURE; }
      if [ "$SCENARIO" = interrupted ]; then
        inst_start() {
          printf "%s\n" "test interruption marker" > "${INST_PENDING_FILE:-$KIT_DIR/activation.pending}"
          systemctl start sdm-gateway || exit 1
          kill -KILL "$BASHPID"
        }
      fi
      KIT_NONINTERACTIVE=1; KIT_ASSUME_YES=1; KIT_DELINEA=no; KIT_START_TIMEOUT=8
      if [ "$SCENARIO" = delinea-failure ]; then
        KIT_DELINEA=yes
        DELINEA_USERNAME=fixture-delinea-user
        DELINEA_PASSWORD=fixture-delinea-secret
      fi
      SDM_APP_DOMAIN=app.strongdm.com
      SDM_PROXY_CLUSTER_ACCESS_KEY=pk-fixture
      SDM_PROXY_CLUSTER_SECRET_KEY=fixture-cluster-secret
      mode_install
    ' > "$output" 2>&1 || rc=$?
  printf '%s' "$rc"
}

cat > "$work/success" <<'CLI'
#!/bin/bash
[ "$(id -u)" -ne 0 ] || exit 100
case "$1:$2" in
  --version:) echo "sdm version 1.2.3";;
  nodesecrets:set)
    shift 2
    umask 077
    for key; do
      IFS= read -r value && [ -n "$value" ] || exit 2
      printf '%s\n' "$key" >> "$SDM_HOME/secretenv.enc"
    done
    ;;
  nodesecrets:list) cat "$SDM_HOME/secretenv.enc";;
  worker:)
    printf '%s\n' 'running proxy worker' 'initial authsync complete'
    exec sleep infinity
    ;;
esac
CLI
sed '/nodesecrets:set)/a\    exit 23' "$work/success" > "$work/seal-failure"
sed '/    shift 2/a\    [ "$1" != DELINEA_USERNAME ] || exit 23' "$work/success" > "$work/delinea-failure"
sed '/  worker:)/a\    touch "$HOME/candidate-start-attempt"\n    exit 24' "$work/success" > "$work/start-failure"
cp "$work/success" "$work/interrupted"
chmod 0755 "$work/success" "$work/seal-failure" "$work/delinea-failure" "$work/start-failure" "$work/interrupted"

cat > /etc/systemd/system/sdm-relay.service <<'UNIT'
[Service]
ExecStart=/bin/sleep infinity
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now sdm-relay
relay_pid=$(kit_unit_prop sdm-relay MainPID)
check "replacement sealing fails" "$(install_fixture seal-failure)" 1
check "candidate reached sealing" "$(grep -Fq 'Could not seal cluster credentials' "$output" && echo yes)" yes
check "active enabled relay undisturbed" "$(unit_state sdm-relay)" active/enabled
check "sealing failure detected before stopping relay" "$(kit_unit_prop sdm-relay MainPID)" "$relay_pid"
check "no replacement boot link" "$(test -L /etc/systemd/system/multi-user.target.wants/sdm-worker.service && echo yes)" ""
check "recovery journal cleaned" "$(test -d "$KIT_DIR/replacement" && echo yes)" ""
check "Delinea sealing fails" "$(install_fixture delinea-failure)" 1
check "candidate reached Delinea sealing" "$(grep -Fq 'could not seal and verify the Delinea credentials' "$output" && echo yes)" yes
check "Delinea sealing failure detected before stopping relay" "$(kit_unit_prop sdm-relay MainPID)" "$relay_pid"
check "Delinea credentials absent from output" "$(grep -aEq 'fixture-delinea-(user|secret)' "$output" && echo yes)" ""

inst_ensure_user
mkdir -p "$SDM_PREFIX/bin" /etc/systemd/system/sdm-worker.service.d
cat > "$SDM_BIN" <<'CLI'
#!/bin/bash
[ "$1" = relay ] && [ "$LEGACY_TOKEN" = fixture-legacy-token ] &&
  [ "$LEGACY_OVERRIDE" = fixture-override ] && [ "$(cat state.kv)" = "legacy state" ] || exit 99
exec sleep infinity
CLI
chmod 0755 "$SDM_BIN"
printf '%s\n' 'legacy state' > "$SDM_HOME_DIR/state.kv"
printf '%s\n' 'legacy sidecar' > "$SDM_SIDECAR"
chown "$SDM_USER:" "$SDM_HOME_DIR/state.kv" "$SDM_SIDECAR"
printf '%s\n' "SDM_HOME=$SDM_HOME_DIR" 'LEGACY_TOKEN=fixture-legacy-token' > "$SDM_SYSCONFIG"
chmod 0600 "$SDM_SYSCONFIG"
cat > /etc/systemd/system/sdm-worker.service <<'UNIT'
[Service]
User=sdm
ExecStart=/opt/strongdm/bin/sdm relay
WorkingDirectory=/home/sdm/.sdm
EnvironmentFile=/etc/sysconfig/sdm-worker
[Install]
WantedBy=graphical.target
UNIT
printf '[Service]\nEnvironment=LEGACY_OVERRIDE=fixture-override\n' > /etc/systemd/system/sdm-worker.service.d/legacy.conf
cp /etc/systemd/system/sdm-relay.service /etc/systemd/system/sdm-gateway.service
systemctl daemon-reload
systemctl disable sdm-relay
systemctl enable sdm-gateway
systemctl enable --now sdm-worker
check "original same-name service starts" "$(unit_state sdm-worker)" active/enabled
sha256sum "$SDM_BIN" "$SDM_SYSCONFIG" "$SDM_HOME_DIR/state.kv" "$SDM_SIDECAR" \
  /etc/systemd/system/sdm-worker.service /etc/systemd/system/sdm-worker.service.d/legacy.conf > "$work/originals"

check "replacement startup fails" "$(install_fixture start-failure)" 1
check "replacement startup was attempted" "$(test -e "$SDM_USER_HOME/candidate-start-attempt" && echo yes)" yes
check "prior same-name worker restored" "$(unit_state sdm-worker)" active/enabled
check "prior disabled active relay restored" "$(unit_state sdm-relay)" active/disabled
check "prior enabled inactive gateway restored" "$(unit_state sdm-gateway)" inactive/enabled
check "original paths and contents restored" "$(sha256sum -c "$work/originals" >/dev/null && echo yes)" yes
check "original custom boot link restored" "$(test -L /etc/systemd/system/graphical.target.wants/sdm-worker.service && echo yes)" yes
check "replacement boot link removed" "$(test -L /etc/systemd/system/multi-user.target.wants/sdm-worker.service && echo yes)" ""
check "credentials absent from failure output" "$(grep -aEq 'fixture-(cluster-secret|legacy-token)' "$output" && echo yes)" ""
check "credentials absent from permanent backups" "$(grep -arq 'fixture-legacy-token' "$KIT_BACKUP_DIR" && echo yes)" ""
check "failed replacement does not set history" "$(test -e "$INST_REPLACED_LIST" && echo yes)" ""

check "interruption leaves rollback journal" "$(install_fixture interrupted)" 137
check "rollback is pending" "$(test -f "$KIT_DIR/replacement/pending" && echo yes)" yes
check "previously inactive gateway started during interruption" "$(unit_state sdm-gateway)" active/enabled
check "retry recovers before honoring replacement approval" "$(install_fixture success no)" 2
check "same-name service restored on retry" "$(unit_state sdm-worker)" active/enabled
check "gateway returned to prior inactive state" "$(unit_state sdm-gateway)" inactive/enabled
check "original paths restored on retry" "$(sha256sum -c "$work/originals" >/dev/null && echo yes)" yes
check "candidate activation marker cleared on retry" "$(test -e "$KIT_DIR/activation.pending" && echo yes)" ""

check "replacement succeeds" "$(install_fixture success)" 0
check "replacement worker active and enabled" "$(unit_state sdm-worker)" active/enabled
check "foreign relay inactive and disabled" "$(unit_state sdm-relay)" inactive/disabled
check "foreign gateway inactive and disabled" "$(unit_state sdm-gateway)" inactive/disabled
check "old same-name overrides removed" "$(test -e /etc/systemd/system/sdm-worker.service.d && echo yes)" ""
check "old worker boot link removed" "$(test -e /etc/systemd/system/graphical.target.wants/sdm-worker.service && echo yes)" ""
check "replacement history committed" "$(grep -qxF 'unit:sdm-relay' "$INST_REPLACED_LIST" && echo yes)" yes
check "successful replacement journal cleaned" "$(test -e "$KIT_DIR/replacement" && echo yes)" ""

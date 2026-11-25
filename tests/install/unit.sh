#!/usr/bin/env bash
# Unit tests for src/modes/install.sh helpers. Run as root in a plain container
# (no systemd needed) with the repo at /kit. Needs: useradd, curl, unzip, zip,
# sha256sum (installed below if missing). Exit 0 = pass.
#   docker run --rm -v "$PWD":/kit:ro ubuntu:22.04 bash /kit/tests/install/unit.sh
KIT=${KIT:-/kit}
# shellcheck disable=SC1090,SC1091
. "$KIT/src/lib/common.sh"; . "$KIT/src/modes/install.sh"
trap - EXIT
n=0; bad=0
t() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; bad=$((bad+1)); fi; }
has() { n=$((n+1)); if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok   $1"; else echo "FAIL $1: missing [$3]"; bad=$((bad+1)); fi; }
hasnt() { n=$((n+1)); if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL $1: unexpected [$3]"; bad=$((bad+1)); else echo "ok   $1"; fi; }

for c in curl unzip zip sha256sum useradd openssl; do kit_have "$c" || need=1; done
if [ -n "${need:-}" ]; then
  if kit_have apt-get; then apt-get -qq update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -qq install -y curl unzip zip passwd openssl >/dev/null 2>&1
  elif kit_have dnf; then dnf -q install -y --allowerasing curl unzip zip shadow-utils openssl >/dev/null 2>&1
  elif kit_have yum; then yum -q install -y curl unzip zip shadow-utils openssl >/dev/null 2>&1
  elif kit_have apk; then apk add -q curl unzip zip shadow coreutils >/dev/null 2>&1; fi
fi
SEC='S3cr3t-VALUE-xyz/+='; ACC='pk-ACCESSKEY12345'; DPW='d3l!nea pass"word'; DUS='svc-delinea'

# ---- 1. collect: non-interactive missing input -> exit 2, secrets never printed
run_collect() { ( exec 2>&1; KIT_NONINTERACTIVE=1; inst_collect ) </dev/null; }
out=$(env -u SDM_APP_DOMAIN bash -c '. /kit/src/lib/common.sh; . /kit/src/modes/install.sh; trap - EXIT; KIT_NONINTERACTIVE=1 inst_collect' 2>&1 </dev/null); rc=$?
t "no region -> 2" "$rc" 2; has "no region msg" "$out" "SDM_APP_DOMAIN"
out=$(SDM_APP_DOMAIN=app.example.com run_collect); t "bad region -> 2" "$?" 2
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com run_collect); t "no access key -> 2" "$?" 2; has "access key hint" "$out" "SDM_PROXY_CLUSTER_ACCESS_KEY"
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC run_collect); t "no secret -> 2" "$?" 2; has "secret hint" "$out" "SDM_PROXY_CLUSTER_SECRET_KEY"
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC SDM_PROXY_CLUSTER_SECRET_KEY=$SEC run_collect); t "no assume-yes -> 2" "$?" 2; has "assume-yes hint" "$out" "KIT_ASSUME_YES=1"
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC SDM_PROXY_CLUSTER_SECRET_KEY=$SEC KIT_DELINEA=yes KIT_ASSUME_YES=1 run_collect); t "delinea w/o user -> 2" "$?" 2
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC SDM_PROXY_CLUSTER_SECRET_KEY=$ACC KIT_ASSUME_YES=1 run_collect); t "same keys -> 2" "$?" 2
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=auth-x1 SDM_PROXY_CLUSTER_SECRET_KEY=$SEC KIT_ASSUME_YES=1 run_collect); t "no pk- prefix -> 2" "$?" 2; has "prefix msg" "$out" "pk-"
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$SEC SDM_PROXY_CLUSTER_SECRET_KEY=$ACC KIT_ASSUME_YES=1 run_collect); t "swapped -> 2" "$?" 2; has "swapped msg" "$out" "swapped"
out=$(SDM_APP_DOMAIN=app.eu.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC SDM_PROXY_CLUSTER_SECRET_KEY=$SEC SDM_BIND_ADDRESS=8443 KIT_ASSUME_YES=1 run_collect); t "bad bind -> 2" "$?" 2
out=$(SDM_APP_DOMAIN=app.uk.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=" $ACC " SDM_PROXY_CLUSTER_SECRET_KEY=$SEC \
      DELINEA_USERNAME=$DUS DELINEA_PASSWORD=$DPW DELINEA_SERVER_URL=https://x.secretservercloud.com KIT_ASSUME_YES=1 run_collect); rc=$?
t "full env -> 0" "$rc" 0
has "delinea inferred" "$out" "Delinea server URL"
has "trim warned" "$out" "removed leading/trailing whitespace"
hasnt "secret key not printed" "$out" "$SEC"
hasnt "delinea pw not printed" "$out" "$DPW"
hasnt "delinea user not printed" "$out" "$DUS"
hasnt "access key hidden" "$out" "$ACC"
hasnt "access key prefix hidden" "$out" "pk-ACC"
out=$(SDM_APP_DOMAIN=app.strongdm.com SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC SDM_PROXY_CLUSTER_SECRET_KEY=$SEC DELINEA_SERVER_URL=http://x KIT_DELINEA=yes \
      DELINEA_USERNAME=$DUS DELINEA_PASSWORD=$DPW KIT_ASSUME_YES=1 run_collect); t "http delinea url -> 2" "$?" 2

# ---- 2. user creation + idempotency
userdel -r sdm >/dev/null 2>&1
out=$(inst_ensure_user 2>&1); t "create user rc" "$?" 0
outer_session=$(awk '{print $6}' /proc/self/stat)
worker_session=$(kit_as_worker "$SDM_HOME_DIR" awk '{print $6}' /proc/self/stat)
t "worker runs outside operator terminal session" "$([ -n "$worker_session" ] && [ "$outer_session" != "$worker_session" ] && echo y)" y
runuser -u nobody -- bash -c '. /kit/src/lib/common.sh; kit_as_worker "$SDM_HOME_DIR" id -u' >/dev/null
t "unrelated non-root account cannot execute the worker CLI" "$?" 1
t "home" "$(getent passwd sdm | cut -d: -f6)" /home/sdm
t "shell nologin/false" "$(getent passwd sdm | cut -d: -f7 | grep -cE "nologin|/bin/false")" 1
t "SDM_HOME mode" "$(stat -c '%a %U' /home/sdm/.sdm)" "700 sdm"
t "password locked" "$(getent shadow sdm | cut -d: -f2 | cut -c1)" "!"
touch /home/sdm/.sdm/state.kv; chown sdm: /home/sdm/.sdm/state.kv
out=$(inst_ensure_user 2>&1); t "second run rc" "$?" 0; has "second run says exists" "$out" "user sdm exists"
t "state.kv untouched" "$(stat -c %U /home/sdm/.sdm/state.kv)" sdm
usermod -d /srv/sdm sdm
out=$( (inst_ensure_user) 2>&1); t "wrong home -> 3" "$?" 3; has "fix cmd" "$out" "usermod -m -d /home/sdm sdm"
SDM_APP_DOMAIN=app.strongdm.com; INST_BIND=:8443
out=$( (inst_analyze) 2>&1); t "analyze wrong home -> 3" "$?" 3
usermod -d /home/sdm sdm

# ---- 3. foreign install detection + backup with redaction
rm -rf /var/backups/sdm-proxy-cluster-kit /opt/sdm-proxy-cluster-kit; mkdir -p /root/.sdm /etc/sysconfig
printf 'sealed-bytes' > /root/.sdm/secretenv.enc; printf 'id' > /root/.sdm/state.kv
cat > /etc/sysconfig/sdm-worker <<ENV
SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC
SDM_PROXY_CLUSTER_SECRET_KEY=$SEC
SDM_HOME=/root/.sdm
SDM_LOG_OUTPUT=stdout
DELINEA_PASSWORD=$DPW
DELINEA_SERVER_URL=https://keep.example.com
HTTPS_PROXY=http://proxy:3128
ENV
cat > /etc/sysconfig/sdm-proxy <<ENV
SDM_RELAY_TOKEN=tok-$SEC
SDM_HOME=/root/.sdm
ENV
inst_analyze
t "class FOREIGN" "$INST_CLASS" FOREIGN
t "foreign dirs" "${INST_FOREIGN_DIRS[*]}" "/root/.sdm"
t "foreign envs" "${INST_FOREIGN_ENVS[*]}" "/etc/sysconfig/sdm-proxy /etc/sysconfig/sdm-worker"
has "findings name keys" "${INST_FINDINGS[*]}" "SDM_RELAY_TOKEN"
hasnt "findings hide values" "${INST_FINDINGS[*]}" "$SEC"
has "prev env kept url" "${INST_PREV_ENV[*]}" "DELINEA_SERVER_URL=https://keep.example.com"
has "prev env kept proxy" "${INST_PREV_ENV[*]}" "HTTPS_PROXY=http://proxy:3128"
KIT_BACKUP_CERT=/root/kit-test-backup.pem
openssl req -x509 -nodes -newkey rsa:2048 -subj /CN=fixture -days 1 -keyout /root/kit-test-backup.key -out "$KIT_BACKUP_CERT" >/dev/null 2>&1 || exit 1
original_env_hash=$(sha256sum </etc/sysconfig/sdm-worker)
out=$( (trap kit_run_exit_handlers EXIT; inst_replace_foreign; inst_replacement_commit) 2>&1); t "replace rc" "$?" 0
b=$(ls -d /var/backups/sdm-proxy-cluster-kit/*/ | head -1)
t "backup perms" "$(stat -c %a /var/backups/sdm-proxy-cluster-kit)" 700
t "backup dir copied" "$(openssl cms -decrypt -binary -inform DER -in "$b/dirs/root_.sdm.tar.cms" -inkey /root/kit-test-backup.key | tar -xO ./secretenv.enc)" "sealed-bytes"

t "backup env verified" "$(openssl cms -decrypt -binary -inform DER -in "$b/env/etc_sysconfig_sdm-worker.cms" -inkey /root/kit-test-backup.key | sha256sum)" "$original_env_hash"
t "no plaintext in persistent backups" "$(grep -aFrq -- "$SEC" "$b" || echo y)" y
t "overlapping environment is retired" "$([ ! -e /etc/sysconfig/sdm-worker ] && echo y)" y
t "original dir untouched" "$(cat /root/.sdm/secretenv.enc)" "sealed-bytes"
# Re-run: sdm install would have rewritten sdm-worker as ours; previously replaced items are not FOREIGN again.
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > /etc/sysconfig/sdm-worker
inst_analyze
t "rerun class" "$INST_CLASS" NONE
has "rerun info" "${INST_INFO[*]}" "replaced by an earlier run"
# A new foreign sidecar elsewhere is still detected.
mkdir -p /home/alice/.sdm; : > /home/alice/.sdm/secretenv.enc
inst_analyze; t "new sidecar FOREIGN" "$INST_CLASS" FOREIGN; t "new sidecar dir" "${INST_FOREIGN_DIRS[*]}" /home/alice/.sdm
rm -rf /home/alice /root/.sdm /etc/sysconfig/sdm-proxy /etc/sysconfig/sdm-worker

# ---- 5. Simulate the vendor network response in this test process only.
m=$(mktemp -d); mkdir "$m/z"
printf '#!/bin/bash\n[ "$EUID" != 0 ] || exit 1\necho "sdm version 9.9.9 (fixture)"\n' > "$m/z/sdm"; chmod 0755 "$m/z/sdm"
(cd "$m/z" && zip -q ../sdm.zip sdm) || exit 1
SHA=$(sha256sum "$m/sdm.zip" | cut -d' ' -f1)
kit_http() { HE=0; HC=200; HB=$(printf '{"url":"%s","version":"9.9.9","sha256":"%s"}' "$mock_url" "$SHA"); }
curl() { local out; while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then out=$2; shift; fi; shift; done; cp "$m/sdm.zip" "$out"; }
mock_url=https://downloads.example/sdm.zip
inst_fetch_release "file://$m/release"; t "local metadata refused" "$?" 1
mock_url=http://downloads.example/sdm.zip
inst_fetch_release https://app.strongdm.com/fixture; t "cleartext archive refused" "$?" 1
mock_url=https://downloads.example/sdm.zip
inst_fetch_release https://app.strongdm.com/fixture; t "vendor metadata" "$?" 0
INST_TMP=""; out=$( (inst_download_verify) 2>&1); t "download ok rc" "$?" 0; has "runs" "$out" "sdm version 9.9.9"
INST_REL_SHA=$(printf '%064d' 0)
out=$( (inst_download_verify) 2>&1); t "sha mismatch -> 1" "$?" 1; has "mismatch msg" "$out" "Checksum mismatch"
unset -f curl kit_http

# ---- 6. misc
bash -ec '. /kit/src/lib/common.sh; :'
t "empty cleanup preserves success with errexit" "$?" 0
SDM_PROXY_CLUSTER_ACCESS_KEY=$ACC; SDM_PROXY_CLUSTER_SECRET_KEY=$SEC
a=$(inst_key_fp); t "fp stable" "$(inst_key_fp)" "$a"; t "fp len" "${#a}" 64
SDM_PROXY_CLUSTER_SECRET_KEY=other; t "fp changes" "$([ "$(inst_key_fp)" != "$a" ] && echo y)" y
f=$(mktemp); printf 'A=1\nB=%s\n' "$SEC" > "$f"
inst_file_contains "$f" "$SEC"; t "contains" "$?" 0; inst_file_contains "$f" "nope"; t "not contains" "$?" 1
t "env keys" "$(inst_env_keys "$f")" "A B "
printf 'CUSTOM="first\nembedded_identifier=part of the value"\nNEXT=two\n' > "$f"
t "reported names exclude text inside a multiline value" "$(inst_env_keys "$f")" "CUSTOM NEXT "
printf 'UNRELATED="unfinished\nSDM_HOME=inside\n' > "$f"
before=$(sha256sum "$f")
kit_envfile_set "$f" SDM_HOME /wanted; t "incomplete record fails update" "$?" 1
t "failed update preserves original" "$(sha256sum "$f")" "$before"
kit_envfile_unset "$f" SDM_HOME; t "incomplete record fails removal" "$?" 2
t "bind port" "$(inst_bind_port 0.0.0.0:9443)" 9443
t "no tabs in source" "$(grep -c "$(printf '\t')" "$KIT/src/modes/install.sh")" 0

echo "== $((n-bad))/$n passed"
[ $bad = 0 ]

#!/usr/bin/env bash
# mode_check, Delinea section, against the mock Secret Server (no systemd).
# Scenarios: env-delivered creds + ID paths; folder path + wrong-case key;
# shared key + no URL; sealed creds via KIT_DELINEA_SVC_*; sealed creds and no
# way to type them. Exit 0 = pass, 77 = skip.
# shellcheck disable=SC1091
. /kit/tests/check/lib/fixtures.bash
ck_setup
O=$T_WORK/out
URL=https://127.0.0.1:9443/SecretServer
export KIT_DELINEA_LIVE=yes KIT_DELINEA_CA_FILE=/etc/ck-test-ca.pem

# ---- 1: env-delivered creds, numeric ID paths
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\nDELINEA_USERNAME=svc_sdm\n' > /etc/sysconfig/sdm-worker
chmod 600 /etc/sysconfig/sdm-worker
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout DELINEA_USERNAME=svc_sdm 'DELINEA_PASSWORD=S3cr&t +%x' SDM_VERBOSE=true
rc=$(ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' 'KIT_DELINEA_PASSWORD_PATH=1234?key=Password' KIT_RDP_HOST=127.0.0.1:3389)
t_eq "1: exit 1 (RDP unreachable is a FAIL)" "$rc" 1
t_has "1: section 5 ran" "$O" "== 5. Delinea secret store"
t_has "1: user from env" "$O" "DELINEA_USERNAME comes from the worker environment (value hidden)"
t_has "1: password shape only" "$O" "DELINEA_PASSWORD comes from the worker environment: len=10 bytes"
t_has "1: healthcheck" "$O" "healthcheck $URL/api/v1/healthcheck: healthy"
t_has "1: token" "$O" "OAuth2 password grant succeeded"
t_has "1: fetch" "$O" "GET /api/v1/secrets/1234: 200, secret id 1234, name 'svc-rdp-test'"
t_has "1: username presence" "$O" "username field is populated (value hidden)"
t_has "1: password anomalies" "$O" "contains an HTML entity such as &amp;"
t_has "1: autochange warn" "$O" "autoChangeEnabled=true"
t_hasnt "1: fetched identity hidden" "$O" "CORP\\svc-rdp-test"
t_has "1: RDP fail" "$O" "RDP target 127.0.0.1:3389 is NOT reachable"
t_has "1: verbose warn" "$O" "SDM_VERBOSE=true is still on"
t_hasnt "1: a username alone is not a plaintext secret" "$O" "plaintext credential(s)"
t_has "1: api token field described" "$O" "API Token"
t_has "1: likely problems list" "$O" "Most likely problems"
t_has "1: bind port found" "$O" "something listens on tcp/8443"
ck_no_secrets "1" "$O"

# ---- 2: folder path + wrong-case key
rc=$(ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' 'KIT_DELINEA_PASSWORD_PATH=/POC/svc-rdp-test?key=password')
t_has "2: folder path parsed" "$O" "password: folder path '/POC/svc-rdp-test', key 'password'"
t_has "2: folder path warn" "$O" "uses a folder path"
t_has "2: by-path fetch" "$O" "GET /api/v1/secrets/0: 200"
t_has "2: key miss" "$O" "password key 'password' matches no field name"
t_has "2: near-miss hint" "$O" "set the key to 'Password'"
ck_no_secrets "2" "$O"

# ---- 3: shared key, no URL anywhere, bad path
rc=$(ck_run "$O" 'KIT_DELINEA_USERNAME_PATH=1234?key=Password' 'KIT_DELINEA_PASSWORD_PATH=1234?key=Password')
t_has "3: same key" "$O" "use the SAME key 'Password'"
t_has "3: no URL" "$O" "requires a trusted HTTPS Secret Server URL"
t_hasnt "3: no live calls" "$O" "OAuth2 password grant"
rc=$(ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_USERNAME_PATH=Secret?key=Username' 'KIT_DELINEA_PASSWORD_PATH=1234')
t_has "3: bad path" "$O" "path must be a secret ID or a folder path"
t_has "3: key required" "$O" "require a key to query"

# ---- 4: sealed creds supplied via KIT_DELINEA_SVC_*; URL + tenant conflict
printf 'SDM_PROXY_CLUSTER_ACCESS_KEY\nSDM_PROXY_CLUSTER_SECRET_KEY\nDELINEA_USERNAME\nDELINEA_PASSWORD\n' > /home/sdm/.sdm/secretenv.enc
chown sdm: /home/sdm/.sdm/secretenv.enc; chmod 600 /home/sdm/.sdm/secretenv.enc
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\nDELINEA_API_TENANT=acme\n' > /etc/sysconfig/sdm-worker
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout DELINEA_API_TENANT=acme
rc=$(ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' 'KIT_DELINEA_PASSWORD_PATH=1234?key=Password' KIT_DELINEA_SVC_USERNAME=svc_sdm 'KIT_DELINEA_SVC_PASSWORD=S3cr&t +%x')
t_has "4: sealed keys listed" "$O" "sealed key names: SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY DELINEA_USERNAME DELINEA_PASSWORD"
t_has "4: user sealed" "$O" "DELINEA_USERNAME comes from the sealed sidecar"
t_has "4: proxy keys sealed" "$O" "SDM_PROXY_CLUSTER_SECRET_KEY provided by the sealed sidecar"
t_has "4: url+tenant conflict" "$O" "only one of serverURL and tenant may be set"
t_hasnt "4: conflicting settings prevent authentication" "$O" "OAuth2 password grant"
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout
t_hasnt "4: no CLI log file created in SDM_HOME" "$O" "sdm.log.created-by-fake"
[ -e /home/sdm/.sdm/sdm.log.created-by-fake ] && t_bad "4: nodesecrets ran without SDM_LOG_OUTPUT=stderr" || t_ok "4: nodesecrets ran with SDM_LOG_OUTPUT=stderr"
ck_no_secrets "4" "$O"

# ---- 5: sealed creds, non-interactive, nothing to type them with
rc=$(ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_PASSWORD_PATH=1234?key=Password')
t_has "5: live part skipped with a warning" "$O" "no terminal is available to type them"

# ---- 6: KIT_CHECK_DELINEA=no skips; nothing DELINEA_* anywhere -> auto skip
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no)
t_has "6: explicit skip" "$O" "skipped (KIT_CHECK_DELINEA=no)"
printf 'SDM_PROXY_CLUSTER_ACCESS_KEY\nSDM_PROXY_CLUSTER_SECRET_KEY\n' > /home/sdm/.sdm/secretenv.enc
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > /etc/sysconfig/sdm-worker
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout
rc=$(ck_run "$O")
t_has "6: auto skip" "$O" "no DELINEA_* settings found; skipped"

# ---- 7: interactive compare via a pty (needs `script`)
ck_script_ok() { # util-linux < 2.25 script(1) hands the pty EOF when its stdin is a pipe
  local v; v=$(script --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [ -n "$v" ] && [ "${v%%.*}" -ge 2 ] && { [ "${v%%.*}" -gt 2 ] || [ "${v#*.}" -ge 25 ]; }; }
if prep_need script >/dev/null 2>&1 && ! ck_script_ok; then
  t_note "7: skipped (util-linux script $(script --version 2>/dev/null | grep -oE '[0-9.]+' | head -1) cannot drive a pty from a pipe; a real terminal is unaffected)"
elif prep_need script >/dev/null 2>&1; then
  printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > /etc/sysconfig/sdm-worker
  ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout DELINEA_USERNAME=svc_sdm 'DELINEA_PASSWORD=S3cr&t +%x'
  # Inputs in prompt order: URL, user path, password path, RDP host, working password.
  # Wait for each prompt to appear before answering (fixed sleeps were flaky on
  # slow images: centos:7's script(1) dropped input sent before the prompt).
  : > "$O"
  ck_wait() { local i; for i in $(seq 1 300); do grep -qF -- "$1" "$O" 2>/dev/null && { sleep 0.3; return 0; }; sleep 0.2; done; return 0; }
  { ck_wait 'Server URL set on the secret store';   printf '%s\n' "$URL"
    ck_wait 'Username secret path';                 printf '%s\n' '1234?key=Username'
    ck_wait 'Password secret path';                 printf '%s\n' '1234?key=Password'
    ck_wait 'RDP target host';                      printf '\n'
    ck_wait 'WORKS when typed';                      printf '%s\n' 'Tröp&Pa&ss'
    sleep 3; } | \
    env KIT_MODE=check NO_COLOR=1 script -qfec "bash $CK_KIT" /dev/null > "$O" 2>&1
  t_has "7: compare explains the difference" "$O" "they match after trimming + HTML-unescaping"
  sed -i 's/Tröp&Pa&ss//' "$O"   # the pty echoes nothing for hidden input, but be safe
  ck_no_secrets "7" "$O"
else t_note "7: skipped (no script command)"; fi

ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout DELINEA_USERNAME=svc_sdm 'DELINEA_PASSWORD=S3cr&t +%x'
ck_run "$O" KIT_DELINEA_SERVER_URL=$URL 'KIT_DELINEA_USERNAME_PATH=1234?key=Password' 'KIT_DELINEA_PASSWORD_PATH=fixture-static-value?static=true' >/dev/null
t_has "wrong mapping detected" "$O" "username path selects a password field"
t_hasnt "static path hidden" "$O" "fixture-static-value"
ck_no_secrets "misconfigured fields" "$O"
ck_run "$O" KIT_DELINEA_SERVER_URL=http://127.0.0.1:8080/SecretServer >/dev/null
t_has "cleartext refused" "$O" "requires a trusted HTTPS Secret Server URL"
t_hasnt "no cleartext grant" "$O" "OAuth2 password grant"
ck_run "$O" KIT_DELINEA_SERVER_URL=https://127.0.0.1:9443/redirect-test >/dev/null
t_has "token redirect reported" "$O" "HTTP 307"
t_hasnt "redirect did not replay grant" "$O" "OAuth2 password grant"
PLATFORM=https://127.0.0.1:9443/platform
ck_run "$O" KIT_DELINEA_SERVER_URL=$PLATFORM KIT_DELINEA_VAULT_URL=$URL 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' >/dev/null
t_has "approved Platform vault" "$O" "verified default vault"
t_has "Platform bearer accepted by vault" "$O" "username field is populated (value hidden)"
ck_run "$O" KIT_DELINEA_SERVER_URL=$PLATFORM KIT_DELINEA_VAULT_URL=$PLATFORM 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' >/dev/null
t_has "mismatched Platform vault refused" "$O" "default vault did not match"
t_hasnt "no fetch for mismatched vault" "$O" "GET /api/v1/secrets/"
ck_run "$O" KIT_DELINEA_LIVE=no KIT_DELINEA_SERVER_URL=$URL >/dev/null
t_has "live checks opt in" "$O" "live authentication skipped"
t_hasnt "no default grant" "$O" "OAuth2 password grant"
ck_kill_worker
t_done

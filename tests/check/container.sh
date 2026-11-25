#!/usr/bin/env bash
# mode_check in container mode: no systemd, no env file, worker configured only
# through its process environment, secrets from SDM_SECRETS_FILE (plaintext JSON).
# Exit 0 = pass, 77 = skip.
# shellcheck disable=SC1091
. /kit/tests/check/lib/fixtures.bash
ck_setup
O=$T_WORK/out
rm -f /etc/sysconfig/sdm-worker /home/sdm/.sdm/secretenv.enc
mkdir -p /sdm /run/secrets
printf '{"SDM_PROXY_CLUSTER_ACCESS_KEY":"auth-abc","SDM_PROXY_CLUSTER_SECRET_KEY":"SECRETKEYVALUE","DELINEA_USERNAME":"svc_sdm","DELINEA_PASSWORD":"S3cr&t +%%x","DELINEA_SERVER_URL":"http://ignored"}\n' > /run/secrets/sdm.json
chmod 644 /run/secrets/sdm.json
ck_worker SDM_HOME=/sdm SDM_LOG_OUTPUT=stdout SDM_SECRETS_FILE=/run/secrets/sdm.json DELINEA_SERVER_URL=http://127.0.0.1:8080/SecretServer
rc=$(ck_run "$O" 'KIT_DELINEA_USERNAME_PATH=1234?key=Username' 'KIT_DELINEA_PASSWORD_PATH=1234?key=Password')
t_has "no env file is fine in a container" "$O" "normal in a container: configuration comes from the process environment"
t_has "secrets file used" "$O" "SDM_SECRETS_FILE=/run/secrets/sdm.json: the worker reads secrets from this plaintext JSON file"
t_has "secrets file keys" "$O" "keys: SDM_PROXY_CLUSTER_ACCESS_KEY SDM_PROXY_CLUSTER_SECRET_KEY DELINEA_USERNAME DELINEA_PASSWORD DELINEA_SERVER_URL"
t_has "server URL in secret store is ignored" "$O" "DELINEA_SERVER_URL is in the secret store, but the worker reads it ONLY from its environment"
t_has "user from secrets file" "$O" "DELINEA_USERNAME comes from the SDM_SECRETS_FILE (value hidden)"
t_has "live check requires opt in" "$O" "live authentication skipped"
t_hasnt "no credentials sent" "$O" "OAuth2 password grant"
t_has "keys provided" "$O" "SDM_PROXY_CLUSTER_SECRET_KEY provided by the SDM_SECRETS_FILE"
t_has "docker logs hint" "$O" "docker logs --since 1h"
t_hasnt "no systemd failure in a container" "$O" "systemd is not running"
ck_no_secrets "container" "$O"

# missing secrets file -> fail closed
ck_worker SDM_HOME=/sdm SDM_LOG_OUTPUT=stdout SDM_SECRETS_FILE=/run/secrets/missing.json
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no)
t_eq "missing secrets file exits 1" "$rc" 1
t_has "missing secrets file" "$O" "/run/secrets/missing.json does not exist; the worker fails closed at startup"

ck_kill_worker
t_done

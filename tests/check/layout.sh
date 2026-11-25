#!/usr/bin/env bash
# mode_check, install layout: stray /root/.sdm sidecar, env file newer than the
# process, SDM_VERBOSE left on, plaintext secret in the env file, then a
# "host" run with fake systemctl/journalctl (unit checks + log summary).
# Exit 0 = pass, 77 = skip.
# shellcheck disable=SC1091
. /kit/tests/check/lib/fixtures.bash
ck_setup
O=$T_WORK/out

# ---- 1: stray /root/.sdm sidecar holding the Delinea creds; worker sidecar has only the keys
printf 'SDM_PROXY_CLUSTER_ACCESS_KEY\nSDM_PROXY_CLUSTER_SECRET_KEY\n' > /home/sdm/.sdm/secretenv.enc
chown sdm: /home/sdm/.sdm/secretenv.enc; chmod 600 /home/sdm/.sdm/secretenv.enc
mkdir -p /root/.sdm; printf 'DELINEA_USERNAME\nDELINEA_PASSWORD\n' > /root/.sdm/secretenv.enc
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > /etc/sysconfig/sdm-worker; chmod 600 /etc/sysconfig/sdm-worker
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout
rc=$(ck_run "$O" KIT_CHECK_DELINEA=yes)
t_eq "1: exit 1" "$rc" 1
t_has "1: stray sidecar found without reading as root" "$O" "sealed secrets in /root/.sdm/secretenv.enc"
t_has "1: cause explained" "$O" "after 'sudo su -' (or sudo -i) USER is root"
t_has "1: root-owned sidecar left private" "$O" "unreadable as service user"
t_has "1: worker keys ok" "$O" "SDM_PROXY_CLUSTER_SECRET_KEY provided by the sealed sidecar"
rm -rf /root/.sdm

# ---- 2: env file modified after start, SDM_VERBOSE in it, plaintext secret in it
sleep 3
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\nSDM_VERBOSE=true\nSDM_PROXY_CLUSTER_SECRET_KEY=SECRETKEYVALUE\n' > /etc/sysconfig/sdm-worker
chmod 644 /etc/sysconfig/sdm-worker
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no)
t_has "2: env file newer than process" "$O" "AFTER the worker started"
t_has "2: plaintext secret" "$O" "plaintext credential(s) in /etc/sysconfig/sdm-worker: SDM_PROXY_CLUSTER_SECRET_KEY"
t_has "2: redacted" "$O" "SDM_PROXY_CLUSTER_SECRET_KEY=<redacted, 14 bytes>"
t_has "2: world-readable" "$O" "readable by group/other (mode 644)"
t_has "2: restart fix listed" "$O" "fix: systemctl restart sdm-worker"
ck_no_secrets "2" "$O"
# the worker itself has no SDM_VERBOSE: the env-file line alone is not "on" (process env wins)
t_hasnt "2: verbose judged from the process env" "$O" "SDM_VERBOSE=true is still on"
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout SDM_VERBOSE=true SDM_PROXY_CLUSTER_SECRET_KEY=SECRETKEYVALUE
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no)
t_has "2: verbose warn" "$O" "SDM_VERBOSE=true is still on"
t_hasnt "2: restarted worker is current" "$O" "AFTER the worker started"
t_has "2: sealed value preferred over env" "$O" "SDM_PROXY_CLUSTER_SECRET_KEY provided by the sealed sidecar"
ck_no_secrets "2b" "$O"

# ---- 3: duplicate worker processes
CK_FAKE2=/opt/strongdm/test/sdm2; cp /bin/bash $CK_FAKE2
( cd / && exec $CK_FAKE2 -c 'sleep 900; :' worker ) >/dev/null 2>&1 &
sleep 1
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no)
t_has "3: duplicate workers" "$O" "2 sdm worker processes are running"
for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" = "$CK_FAKE2" ] && kill "${d#/proc/}"; done

# ---- 4: host mode with fake systemd + journald
mkdir -p /run/systemd/system /tmp/ckbin
WPID=""; for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" = "$CK_FAKE" ] && WPID=${d#/proc/}; done
echo "$WPID" > /tmp/ck-mainpid
cat > /tmp/ckbin/systemctl <<'EOF'
#!/bin/bash
# fake systemctl: sdm-worker installed + sdm-proxy (relay) leftover. systemd 219 style show (no --value).
case "$1" in
  --version) echo "systemd 219 (fake)";;
  cat) case "$2" in sdm-worker|sdm-proxy) echo "[Service]";; *) exit 1;; esac;;
  is-enabled) echo enabled;;
  show)
    [ "$2" = -p ] || exit 1; p=$3; u=$4
    case "$u:$p" in
      sdm-worker:MainPID) echo "MainPID=$(cat /tmp/ck-mainpid)";;
      *:ActiveState) [ "$u" = sdm-proxy ] && echo "ActiveState=inactive" || echo "ActiveState=active";;
      *:SubState) echo "SubState=running";;
      *:User) echo "User=sdm";;
      *:WorkingDirectory) echo "WorkingDirectory=/home/sdm/.sdm";;
      *:EnvironmentFiles) echo "EnvironmentFiles=/etc/sysconfig/sdm-worker (ignore_errors=no)";;
      *:ExecStart) echo "ExecStart={ path=/opt/strongdm/bin/sdm ; argv[]=/opt/strongdm/bin/sdm worker ; ignore_errors=no }";;
      *:FragmentPath) echo "FragmentPath=/etc/systemd/system/$u.service";;
      *:NRestarts) echo "NRestarts=3";;
      *:ActiveEnterTimestamp) echo "ActiveEnterTimestamp=Thu 2026-11-19 10:00:00 UTC";;
      *) echo "$p=";;
    esac;;
  *) exit 1;;
esac
EOF
cat > /tmp/ckbin/journalctl <<'EOF'
#!/bin/bash
echo 'time=2026-11-19T10:00:01Z level=info msg="[cli.Worker] running proxy worker"'
echo 'time=2026-11-19T10:00:03Z level=info msg="initial authsync complete"'
echo 'time=2026-11-19T10:05:00Z level=error msg="failed to dial upstream"'
echo 'time=2026-11-19T10:06:00Z level=warn msg="slow authsync"'
EOF
chmod 755 /tmp/ckbin/*
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > /etc/sysconfig/sdm-worker; chmod 600 /etc/sysconfig/sdm-worker
ck_worker SDM_HOME=/home/sdm/.sdm SDM_LOG_OUTPUT=stdout
for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" = "$CK_FAKE" ] && echo "${d#/proc/}" > /tmp/ck-mainpid; done
rc=$(ck_run "$O" KIT_CHECK_DELINEA=no PATH=/tmp/ckbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
t_has "4: unit found" "$O" "unit sdm-worker installed (/etc/systemd/system/sdm-worker.service)"
t_has "4: enabled" "$O" "enabled (starts at boot)"
t_has "4: active" "$O" "active (running) since Thu 2026-11-19 10:00:00 UTC"
t_has "4: user" "$O" "runs as User=sdm"
t_has "4: workdir" "$O" "WorkingDirectory=/home/sdm/.sdm"
t_has "4: execstart" "$O" "ExecStart uses /opt/strongdm/bin/sdm"
t_has "4: restarts warn" "$O" "has restarted sdm-worker 3 time(s)"
t_has "4: relay unit warn" "$O" "another StrongDM unit 'sdm-proxy' is installed (inactive)"
t_has "4: startup line" "$O" "'running proxy worker' logged since the last start"
t_has "4: authsync line" "$O" "'initial authsync complete' logged"
t_has "4: error count" "$O" "1 error(s), 1 warning(s)"
t_hasnt "4: raw error omitted" "$O" "failed to dial upstream"
t_has "4: consistent home" "$O" "SDM_HOME is consistently /home/sdm/.sdm"

ck_kill_worker
t_done

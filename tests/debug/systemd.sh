#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars are read inside eval'd checks
# Full debug loop against a dummy sdm-worker unit. Needs a container booted
# with systemd (e.g. as below) and
# the repo at /kit. Exit 0 = pass.
#   docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
#     --tmpfs /run --tmpfs /run/lock -v "$PWD":/kit:ro <ubuntu+systemd image> /sbin/init
# Covers timeout, Ctrl-C, TERM, HUP, SIGKILL, foreign unit precedence and KEEP.
KIT=${KIT:-/kit}
[ -d /run/systemd/system ] || { echo "SKIP: systemd not running (needs a systemd-booted container, see tests/run-systemd.sh)"; exit 77; }
S=/tmp/kit-dbg.sh; cat "$KIT/src/lib/common.sh" "$KIT"/src/modes/*.sh "$KIT/src/main.sh" > "$S"
E=/etc/sysconfig/sdm-worker
bad=0; chk() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; bad=$((bad+1)); fi; }
mainpid_env() { tr '\0' '\n' < "/proc/$(systemctl show -p MainPID "${1:-sdm-worker}" | cut -d= -f2)/environ" | grep '^SDM_VERBOSE=' || echo unset; }
wait_follow() {
  local log=$1 i
  for ((i=0; i<60; i++)); do
    grep -q 'Reproduce the problem' "$log" && return 0
    sleep 1
  done
  return 1
}

mkdir -p /etc/sysconfig /opt/strongdm/bin
cat > /opt/strongdm/bin/fake-worker <<'W'
#!/bin/bash
while :; do echo "level=info msg=\"tick\" verbose=${SDM_VERBOSE:-unset}"
  [ "${SDM_VERBOSE:-}" = true ] && echo 'level=debug msg="credential field" key=password path=x'
  sleep 1; done
W
chmod +x /opt/strongdm/bin/fake-worker
cat > /etc/systemd/system/sdm-worker.service <<'U'
[Unit]
Description=fake sdm worker
[Service]
EnvironmentFile=-/etc/sysconfig/sdm-worker
ExecStart=/opt/strongdm/bin/fake-worker
Restart=always
[Install]
WantedBy=multi-user.target
U
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > $E; chmod 0700 $E
systemctl daemon-reload; systemctl restart sdm-worker; sleep 1
before=$(cat $E)

install -d -m 0700 /opt/sdm-proxy-cluster-kit
(
  exec 9>/opt/sdm-proxy-cluster-kit/install.lock; flock -n 9 || exit 1
  KIT_MODE=debug KIT_NONINTERACTIVE=1 bash "$S" 9>&- </dev/null >/tmp/kit-lock-check 2>&1
  [ "$?" = 1 ] && grep -q 'holds the kit lock' /tmp/kit-lock-check
)
rc=$?; chk "active installer excludes debug changes" '[ $rc = 0 ] && [ "$(cat $E)" = "$before" ]'
chmod 0666 "$E"
KIT_MODE=debug KIT_NONINTERACTIVE=1 bash "$S" </dev/null >/tmp/kit-permission-check 2>&1; rc=$?
chk "writable env file refused" '[ $rc = 3 ] && grep -q "Untrusted worker environment file" /tmp/kit-permission-check'
chmod 0600 "$E"
mkdir -m 0777 /run/sdm-proxy-cluster-kit-debug
KIT_MODE=debug KIT_NONINTERACTIVE=1 bash "$S" </dev/null >/tmp/kit-runtime-permission 2>&1; rc=$?
chk "writable runtime directory refused" '[ $rc = 3 ] && grep -q "Could not prepare the debug runtime directory" /tmp/kit-runtime-permission'
rmdir /run/sdm-proxy-cluster-kit-debug

echo "== 1: decline (non-interactive, no KIT_ASSUME_YES) -> exit 4, nothing changed"
KIT_MODE=debug KIT_NONINTERACTIVE=1 bash $S </dev/null >/tmp/o1 2>&1; rc=$?
chk "exit 4" '[ $rc = 4 ]'; chk "file untouched" '[ "$(cat $E)" = "$before" ]'

echo "== 2: timeout path, prior absent, filter secrets"
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=1 KIT_DEBUG_FILTER=secrets bash $S </dev/null >/tmp/o2 2>&1; rc=$?
chk "exit 0" '[ $rc = 0 ]'
chk "followed filtered lines" 'grep -q "credential field" /tmp/o2 && ! grep -q "msg=\"tick\"" /tmp/o2'
chk "time limit msg" 'grep -q "time limit of 1 minute" /tmp/o2'
chk "file restored" '[ "$(cat $E)" = "$before" ]'
chk "process unset" '[ "$(mainpid_env)" = unset ]'
chk "capture hint" 'grep -q "journalctl -u sdm-worker.service --since" /tmp/o2'
tail -12 /tmp/o2

echo "== 3: Ctrl-C on a pty, prior SDM_VERBOSE=false"
printf 'SDM_VERBOSE=false\n' >> $E; systemctl restart sdm-worker; sleep 1; before=$(cat $E)
python3 - "$S" <<'P' >/tmp/o3 2>&1
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(KIT_MODE="debug", TERM="dumb")
    os.execvp("bash", ["bash", sys.argv[1]])
buf = b""
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: d = os.read(fd, 4096)
            except OSError: return False
            if not d: return False
            buf += d; sys.stdout.write(d.decode(errors="replace")); sys.stdout.flush()
    return True
def wait_for(s, t=90):
    end = time.time() + t
    while s.encode() not in buf and time.time() < end:
        if not pump(0.5): break
    return s.encode() in buf
assert wait_for("now? [y/N]"), "no confirm prompt"
os.write(fd, b"y\n")
assert wait_for("choose 1-4"), "no filter menu"
os.write(fd, b"1\n")
assert wait_for("verbose=true"), "no verbose lines"
time.sleep(2)
os.write(fd, b"\x03")            # Ctrl-C through the tty line discipline
pump(1); os.write(fd, b"\x03")   # impatient second Ctrl-C during the revert
while pump(1): pass
_, st = os.waitpid(pid, 0)
print("\nEXIT", os.waitstatus_to_exitcode(st))
P
chk "pty driver ok" 'grep -q "^EXIT 0" /tmp/o3'
chk "stopped with ctrl-c msg" 'grep -q "stopped with Ctrl-C" /tmp/o3'
chk "revert visible on screen" 'grep -q "sees SDM_VERBOSE=false after removing the override" /tmp/o3'
chk "file restored exactly" '[ "$(cat $E)" = "$before" ]'
chk "process false" '[ "$(mainpid_env)" = SDM_VERBOSE=false ]'
transcript=$(sed -n 's/^  full transcript: //p' /tmp/o3 | tr -d '\r' | tail -1)
chk "transcript has revert" '[ -f "$transcript" ] && grep -qF "sees SDM_VERBOSE=false after removing the override" "$transcript"'
tail -14 /tmp/o3

echo "== 4: KIT_DEBUG_KEEP=1 leaves it on"
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=1 KIT_DEBUG_FILTER=errors KIT_DEBUG_KEEP=1 bash $S </dev/null >/tmp/o4 2>&1; rc=$?
chk "exit 0" '[ $rc = 0 ]'; chk "left on" '[ "$(mainpid_env)" = SDM_VERBOSE=true ] && grep -q "LEFT ON" /tmp/o4 && grep -qx "SDM_VERBOSE=true" "$E"'
chk "KEEP started no runtime expiry timer" '! grep -q "with a systemd expiry timer" /tmp/o4'

echo "== 5: already verbose -> no restart, nothing changed"
p0=$(systemctl show -p MainPID sdm-worker | cut -d= -f2); before=$(cat $E)
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_DEBUG_MINUTES=1 KIT_DEBUG_FILTER=errors bash $S </dev/null >/tmp/o5 2>&1; rc=$?
chk "exit 0" '[ $rc = 0 ]'; chk "same pid" '[ "$(systemctl show -p MainPID sdm-worker | cut -d= -f2)" = "$p0" ]'
chk "file same" '[ "$(cat $E)" = "$before" ]'

echo "== 6: SIGTERM mid-follow still reverts"
sed -i '/^SDM_VERBOSE=/d' $E; systemctl restart sdm-worker; sleep 1; before=$(cat $E)
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=5 bash $S </dev/null >/tmp/o6 2>&1 &
k=$!; chk "debug ready" 'wait_follow /tmp/o6'
started=$SECONDS; kill -TERM $k; wait $k; rc=$?
chk "reverted promptly after TERM" '[ $((SECONDS-started)) -lt 30 ]'
chk "exit 143" '[ $rc = 143 ]'; chk "file restored" '[ "$(cat $E)" = "$before" ]'; chk "process unset" '[ "$(mainpid_env)" = unset ]'

echo "== 7: env file missing -> exit 3, explained"
mv $E $E.bak; KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 bash $S </dev/null >/tmp/o7 2>&1; rc=$?; mv $E.bak $E
chk "exit 3" '[ $rc = 3 ] && grep -q "does not exist" /tmp/o7'

echo "== 8: alias with a later EnvironmentFile and a hard-killed operator shell"
F=sdm-debug-foreign.service
mkdir -p "/etc/systemd/system/$F.d"
cat > "/etc/systemd/system/$F" <<'U'
[Service]
Environment=SDM_VERBOSE=direct
EnvironmentFile=/etc/sysconfig/sdm-debug-foreign
ExecStart=/opt/strongdm/bin/fake-worker
Restart=always
U
printf 'SDM_VERBOSE=first\n' > /etc/sysconfig/sdm-debug-foreign
printf 'SDM_VERBOSE=false\n\n' > /etc/sysconfig/sdm-debug-foreign-last
cp /etc/sysconfig/sdm-debug-foreign-last /tmp/foreign-before
printf '[Service]\nEnvironmentFile=/etc/sysconfig/sdm-debug-foreign-last\n' > "/etc/systemd/system/$F.d/zzzz-late.conf"
ln -s "$F" /etc/systemd/system/sdm-debug-alias.service
systemctl daemon-reload && systemctl start "$F"
KIT_MODE=debug KIT_DEBUG_UNIT=sdm-debug-alias KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=1 \
  KIT_DEBUG_FILTER=secrets bash "$S" </dev/null >/tmp/o8 2>&1 &
k=$!; chk "debug ready through the alias" 'wait_follow /tmp/o8'
chk "runtime file overrides every existing assignment" '[ "$(mainpid_env "$F")" = SDM_VERBOSE=true ]'
chk "base files unchanged during debug" 'grep -qx "SDM_VERBOSE=first" /etc/sysconfig/sdm-debug-foreign && cmp -s /tmp/foreign-before /etc/sysconfig/sdm-debug-foreign-last'
systemctl restart "$F"
chk "the override survives a worker restart within the window" '[ "$(mainpid_env "$F")" = SDM_VERBOSE=true ]'
kill -KILL "$k"; wait "$k"; rc=$?
chk "operator shell was hard-killed" '[ "$rc" = 137 ]'
chk "orphaned filtered journal released the kit lock" 'flock -n /opt/sdm-proxy-cluster-kit/install.lock true'
started=$SECONDS
while [ $((SECONDS-started)) -lt 75 ]; do
  if [ "$(mainpid_env "$F")" = SDM_VERBOSE=false ] && ! compgen -G '/run/sdm-proxy-cluster-kit-debug/session.*' >/dev/null; then break; fi
  sleep 1
done
chk "systemd restored prior worker environment after SIGKILL" '[ $((SECONDS-started)) -lt 75 ] && [ "$(mainpid_env "$F")" = SDM_VERBOSE=false ]'
chk "runtime override and session state removed" '[ ! -d "/run/systemd/system/$F.d" ] && ! compgen -G "/run/sdm-proxy-cluster-kit-debug/session.*" >/dev/null'
chk "base environment never rewritten" 'cmp -s /tmp/foreign-before /etc/sysconfig/sdm-debug-foreign-last'
cat >> "/etc/systemd/system/$F.d/zzzz-late.conf" <<'U'
Restart=no
ExecStartPre=/bin/bash -c 'test "$$SDM_VERBOSE" != true'
U
systemctl daemon-reload
KIT_MODE=debug KIT_DEBUG_UNIT="$F" KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 bash "$S" </dev/null >/tmp/o8-failed-start 2>&1; rc=$?
chk "failed verbose startup restored the original worker" '[ "$rc" = 1 ] && [ "$(mainpid_env "$F")" = SDM_VERBOSE=false ]'

echo "== 9: a new debug session recovers an orphan, then exits on HUP"
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=5 bash "$S" </dev/null >/tmp/o9-orphan 2>&1 &
k=$!; chk "first session ready" 'wait_follow /tmp/o9-orphan'
kill -KILL "$k"; wait "$k"
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=5 bash "$S" </dev/null >/tmp/o9 2>&1 &
k=$!; chk "next session recovered the orphan" 'wait_follow /tmp/o9 && grep -q "Cleaning up an interrupted debug session" /tmp/o9'
kill -HUP "$k"; wait "$k"; rc=$?
chk "HUP exits 129 and reverts promptly" '[ "$rc" = 129 ] && [ "$(mainpid_env)" = unset ] && ! compgen -G "/run/sdm-proxy-cluster-kit-debug/session.*" >/dev/null'

echo "== 10: no unit -> exit 3 with New install hint"
KIT_MODE=debug KIT_NONINTERACTIVE=1 KIT_ASSUME_YES=1 KIT_DEBUG_MINUTES=5 bash "$S" </dev/null >/tmp/pre-install-debug 2>&1 &
k=$!; chk "debug session ready before install" 'wait_follow /tmp/pre-install-debug'
kill -KILL "$k"; wait "$k"
(
  . "$KIT/src/lib/common.sh"; . "$KIT/src/modes/debug.sh"; . "$KIT/src/modes/install.sh"
  kit_in_container() { return 1; }
  inst_collect() { exit 42; }
  mode_install
) >/tmp/recover-before-install 2>&1; rc=$?
chk "install reverts debug before collecting inputs" '[ "$rc" = 42 ] && [ "$(mainpid_env)" = unset ] && ! compgen -G "/run/sdm-proxy-cluster-kit-debug/session.*" >/dev/null'
systemctl stop sdm-worker; mv /etc/systemd/system/sdm-worker.service /tmp/; systemctl daemon-reload
for i in $(seq 30); do systemctl cat sdm-worker >/dev/null 2>&1 || break; sleep 0.5; done   # wait for the reload to land
KIT_MODE=debug KIT_NONINTERACTIVE=1 bash $S </dev/null >/tmp/o10 2>&1; rc=$?
mv /tmp/sdm-worker.service /etc/systemd/system/; systemctl daemon-reload
chk "exit 3" '[ $rc = 3 ] && grep -q "choose 1 (New install)" /tmp/o10'

[ $bad = 0 ] && echo "ALL PASS" || echo "$bad FAILED"; [ $bad = 0 ]

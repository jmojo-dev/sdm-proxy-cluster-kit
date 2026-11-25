# shellcheck shell=bash
# ============================================================================
# tests/check/lib/fixtures.bash - fixtures for the mode_check tests.
# Sourced by tests/check/*.sh inside a container with the repo at /kit.
#   ck_setup            deps, user sdm, fake /opt/strongdm/bin/sdm, mock server, kit build
#   ck_worker K=V ...   (re)start a fake "sdm worker" process as user sdm with that env
#   ck_run OUT [K=V...] run `KIT_MODE=check` non-interactively, output to OUT, prints rc
# The fake worker is a copy of bash named "sdm", so kit_find_node_procs sees it.
# The fake CLI answers `--version` and `nodesecrets list` (sidecar = plain key list).
# ============================================================================
# shellcheck disable=SC1091
. /kit/tests/lib/testlib.sh
# shellcheck disable=SC1091
. /kit/tests/lib/container-prep.sh

CK_LIB=/kit/tests/check/lib
CK_KIT=/tmp/ck-kit.sh
CK_FAKE=/opt/strongdm/test/sdm

ck_setup() {
  prep_detect
  prep_need curl useradd getent || t_skip "could not install curl/useradd"
  [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/pki/tls/certs/ca-bundle.crt ] || case $PREP_PKG in
    apt) { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates; } >/dev/null 2>&1;;
    dnf|yum) $PREP_PKG install -y -q ca-certificates >/dev/null 2>&1;;
  esac
  CK_PY=$(command -v python3 || command -v python || command -v python2)
  if [ -z "$CK_PY" ]; then prep_need python3 >/dev/null 2>&1; CK_PY=$(command -v python3); fi
  [ -n "$CK_PY" ] || t_skip "no python for the mock Secret Server"
  getent passwd sdm >/dev/null || useradd -m -d /home/sdm -s /sbin/nologin sdm || t_skip "useradd failed"
  mkdir -p /home/sdm/.sdm /opt/strongdm/bin /opt/strongdm/test /etc/sysconfig
  chown sdm: /home/sdm/.sdm; chmod 700 /home/sdm/.sdm
  cp /bin/bash "$CK_FAKE"
  cat > /opt/strongdm/bin/sdm <<'EOF'
#!/bin/bash
# fake sdm CLI for tests/check
[ "${SDM_LOG_OUTPUT:-}" = stderr ] || { [ -n "${SDM_HOME:-}" ] && : > "$SDM_HOME/sdm.log.created-by-fake"; }
case "$1" in
  --version) [ "$(id -u)" != 0 ] || exit 3; echo "sdm version 99.0.0-test";;
  nodesecrets)
    [ "$(id -u)" != 0 ] || exit 3
    [ "$2" = list ] || exit 2
    f="${SDM_HOME:-.}/secretenv.enc"
    [ -f "$f" ] || { echo "no sealed secrets file present" >&2; exit 0; }
    [ -r "$f" ] || { echo "secretenv: read sidecar: permission denied" >&2; exit 1; }
    grep -v '^#' "$f";;
  *) exit 2;;
esac
EOF
  chmod 755 /opt/strongdm/bin/sdm
  ( cd / && nohup "$CK_PY" "$CK_LIB/mock.py" >/tmp/ck-mock.log 2>&1 & )
  local _; for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:8080/SecretServer/api/v1/healthcheck && break; sleep 0.5; done
  local arch=amd64
  case $(uname -m) in aarch64|arm64) arch=arm64;; esac
  /kit/tests/.work/bin/tlsproxy-"$arch" > /tmp/ck-tls.log 2>&1 &
  for _ in $(seq 40); do [ -s /etc/ck-test-ca.pem ] && break; sleep 0.1; done
  [ -s /etc/ck-test-ca.pem ] || { echo "TLS fixture missing; build with tests/run.sh" >&2; exit 1; }
  cat /kit/src/lib/common.sh /kit/src/modes/*.sh /kit/src/main.sh > "$CK_KIT"
  bash -n "$CK_KIT" || t_skip "kit does not parse (another mode file mid-edit?)"
}

# Root reads another user's /proc/PID/environ only with CAP_SYS_PTRACE (docker drops it).
# Without it the fake worker runs as root so its environment stays readable.
ck_have_ptrace() { local c; c=$(awk '/^CapEff:/{print $2}' /proc/self/status); [ $(( (16#$c >> 19) & 1 )) = 1 ]; }

ck_kill_worker() {
  local d
  for d in /proc/[0-9]*; do [ "$(readlink "$d/exe" 2>/dev/null)" = "$CK_FAKE" ] && kill "${d#/proc/}" 2>/dev/null; done
  sleep 0.3
}

# ck_worker [K=V ...] : fresh worker as user sdm, cwd /home/sdm/.sdm, env exactly as given.
ck_worker() {
  local s=/tmp/ck-worker-start.sh a
  ck_kill_worker
  { printf 'cd /home/sdm/.sdm || exit 1\nexec env -i PATH=/usr/bin:/bin'
    for a in "$@"; do printf ' %q' "$a"; done
    printf ' %q -c %q worker\n' "$CK_FAKE" 'sleep 900; :'
  } > "$s"
  chmod 755 "$s"
  if ck_have_ptrace; then su -s /bin/bash sdm -c "bash $s" >/dev/null 2>&1 &
  else bash "$s" >/dev/null 2>&1 & fi
  sleep 1.2
}

ck_run() { # OUT [K=V ...]
  local out=$1; shift
  env KIT_MODE=check KIT_NONINTERACTIVE=1 NO_COLOR=1 "$@" bash "$CK_KIT" > "$out" 2>&1 </dev/null
  echo $?
}

# Fail if any of the known secret values shows up anywhere in OUT.
ck_no_secrets() { # DESC OUT
  local s
  for s in 'S3cr&t +%x' 'S3cr&t' 'Tröp' 'Pa&ss' 'tokVALUEdonotprint' 'tok123' 'SECRETKEYVALUE'; do
    t_hasnt "$1: no secret value '$s' printed" "$2" "$s"
  done
}

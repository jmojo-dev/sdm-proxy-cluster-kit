#!/usr/bin/env bash
# Runs the tests that need real systemd (tests/*/systemd.sh) inside a privileged,
# systemd-booted Ubuntu 22.04 container. tests/run.sh skips them (exit 77).
#   tests/run-systemd.sh            build image, run install + debug systemd tests
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
IMG=sdmkit-systemd:22.04
NAME=sdmkit-systemd-$$
docker build -q -t "$IMG" "$REPO/tests/systemd" >/dev/null || { echo "image build failed"; exit 1; }
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
rc=0
mkdir -p "$REPO/tests/.work/logs/systemd"
for t in install/systemd install/recovery-systemd install/rollback-systemd debug/systemd; do
  docker run -d --name "$NAME" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v "$REPO":/kit:ro "$IMG" >/dev/null || exit 1
  for i in $(seq 1 30); do docker exec "$NAME" test -d /run/systemd/system && break; sleep 1; done
  log="$REPO/tests/.work/logs/systemd/${t/\//-}.log"
  if docker exec "$NAME" bash "/kit/tests/$t.sh" > "$log" 2>&1; then echo "PASS  $t"; else echo "FAIL  $t  ($log)"; rc=1; fi
  docker rm -f "$NAME" >/dev/null || exit 1
done
exit $rc

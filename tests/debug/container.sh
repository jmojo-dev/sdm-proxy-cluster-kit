#!/usr/bin/env bash
# Debug mode inside a plain container (no systemd): must explain how to enable
# SDM_VERBOSE there and exit 3. Repo at /kit. Exit 0 = pass.
KIT=${KIT:-/kit}
s=$(mktemp); cat "$KIT/src/lib/common.sh" "$KIT"/src/modes/*.sh "$KIT/src/main.sh" > "$s"
out=$(KIT_MODE=debug KIT_NONINTERACTIVE=1 bash "$s" </dev/null 2>&1); rc=$?
echo "$out"
[ "$rc" = 3 ] || { echo "FAIL: exit $rc, want 3"; exit 1; }
for w in 'SDM_VERBOSE=true' 'docker logs -f' 'kubectl logs -f'; do
  printf '%s' "$out" | grep -qF -- "$w" || { echo "FAIL: missing '$w'"; exit 1; }
done
echo "PASS container explanation"

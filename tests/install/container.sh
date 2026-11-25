#!/usr/bin/env bash
# Install mode inside a plain container: must refuse with exit 3 and point at
# SDM_SECRETS_FILE. Repo at /kit, run as root. Exit 0 = pass.
KIT=${KIT:-/kit}
s=$(mktemp); cat "$KIT/src/lib/common.sh" "$KIT"/src/modes/*.sh "$KIT/src/main.sh" > "$s"
out=$(KIT_MODE=install KIT_NONINTERACTIVE=1 bash "$s" </dev/null 2>&1); rc=$?
echo "$out"
[ "$rc" = 3 ] || { echo "FAIL: exit $rc, want 3"; exit 1; }
printf '%s' "$out" | grep -qF 'SDM_SECRETS_FILE' || { echo "FAIL: no SDM_SECRETS_FILE hint"; exit 1; }
printf '%s' "$out" | grep -qF 'STEP 2/' && { echo "FAIL: went past preflight"; exit 1; }
echo "PASS container refusal"

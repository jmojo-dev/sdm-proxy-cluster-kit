#!/usr/bin/env bash
# shellcheck disable=SC2034  # vars are read inside eval'd checks
# Unit tests for src/modes/debug.sh helpers. Runs in any container with the
# repo at /kit (no systemd needed). Exit 0 = pass.
KIT=${KIT:-/kit}
# shellcheck disable=SC1090,SC1091
. "$KIT/src/lib/common.sh"; . "$KIT/src/modes/debug.sh"
trap - EXIT
n=0; bad=0
t() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; bad=$((bad+1)); fi; }
d=$(mktemp -d); f=$d/sdm-worker

# Prior env-file values are recorded for the persistent KEEP path.
printf 'SDM_HOME=/home/sdm/.sdm\nSDM_LOG_OUTPUT=stdout\n' > "$f"; chmod 0700 "$f"
dbg_save_prior "$f"; t "absent detected" "$DBG_PRIOR_STATE" absent
kit_envfile_set "$f" SDM_VERBOSE true; t "set" "$(kit_envfile_get "$f" SDM_VERBOSE)" true
t "env file private" "$(stat -c %a "$f")" 600
printf 'SDM_VERBOSE=false\nSDM_HOME=/x\n' > "$f"
dbg_save_prior "$f"; t "present detected" "$DBG_PRIOR_STATE/$DBG_PRIOR_VALUE" present/false
printf 'SDM_VERBOSE=\n' > "$f"; dbg_save_prior "$f"
t "empty present" "$DBG_PRIOR_STATE/[$DBG_PRIOR_VALUE]" "present/[]"
printf 'SDM_VERBOSE="true"\n' > "$f"; dbg_save_prior "$f"
t "unquote" "$(dbg_unquote "$DBG_PRIOR_VALUE")" true

# Legacy systemctl asks for EnvironmentFiles but prints the singular prefix.
legacy_files=$(
  systemctl() {
    printf '%s\n' 'EnvironmentFile=/etc/sysconfig/sdm-worker (ignore_errors=no)' \
      'EnvironmentFile=/run/debug/verbose (ignore_errors=yes)'
  }
  dbg_envfiles sdm-worker
)
t "systemd 219 environment file ordering" "$legacy_files" $'/etc/sysconfig/sdm-worker\n/run/debug/verbose'

# filters
t "filter all empty" "$(dbg_filter_regex all)" ""
dbg_filter_regex bogus >/dev/null; t "filter bogus rc" $? 1
m() { printf '%s\n' "$2" | grep -Eiqe "$(dbg_filter_regex "$1")" && echo y || echo n; }
t "secrets cred field" "$(m secrets 'level=debug msg="credential field" key=password path=a/b')" y
t "secrets tss" "$(m secrets 'msg="tss-sdk-go: GET /api/v1/secrets/12"')" y
t "secrets fetch" "$(m secrets 'msg="[secretstores.FetchCredentials] trying to load"')" y
t "secrets miss" "$(m secrets 'msg="initial authsync complete"')" n
t "rdp prefix" "$(m rdp 'msg="[rdp.preamble] completed protocol negotiation"')" y
t "rdp nla" "$(m rdp 'msg="NLA failed"')" y
t "rdp miss" "$(m rdp 'msg="unlabeled thing"')" n
t "errors logfmt" "$(m errors 'time=2026 level=error msg="x"')" y
t "errors json" "$(m errors '{"level":"warn","msg":"x"}')" y
t "errors miss" "$(m errors 'level=info msg="error in name only"')" n
t "errors panic" "$(m errors 'panic: runtime error')" y

# proc env
SDM_VERBOSE=true sleep 5 & p=$!; sleep 0.2
t "pid verbose" "$(dbg_pid_verbose $p)" true; kill $p
env -u SDM_VERBOSE sleep 5 & p=$!; sleep 0.2
t "pid unset" "$(dbg_pid_verbose $p)" "<unset>"; kill $p

# filter env handling (non-interactive)
KIT_NONINTERACTIVE=1; DBG_FILTER=""; unset KIT_DEBUG_FILTER; dbg_pick_filter; t "filter default" "$DBG_FILTER" all
KIT_DEBUG_FILTER=rdp dbg_pick_filter; t "filter env" "$DBG_FILTER" rdp
out=$( (KIT_DEBUG_FILTER=nope dbg_pick_filter) 2>&1 ); t "filter bad rc" $? 2

rm -rf "$d"
echo "$((n-bad))/$n passed"; [ "$bad" = 0 ]

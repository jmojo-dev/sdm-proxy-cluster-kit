# shellcheck shell=bash
# ============================================================================
# tests/lib/testlib.sh - tiny assertion helpers for tests run inside containers.
# A test exits 0 = PASS, 77 = SKIP, anything else = FAIL (see tests/run.sh).
#   . /kit/tests/lib/testlib.sh
# ============================================================================
# shellcheck disable=SC2034  # variables below are used by the tests that source this
T_FAILS=0
KIT_ROOT=${KIT_ROOT:-/kit}
KIT_DIST=$KIT_ROOT/dist
KIT_VERSION=$(tr -d ' \r\n' < "$KIT_ROOT/VERSION")
KIT_TARGET=/opt/sdm-proxy-cluster-kit/sdm-proxy-cluster-kit.sh
T_WORK=$(mktemp -d /tmp/kittest.XXXXXX)
chmod 0755 "$T_WORK"

t_sha() { local o; o=$(sha256sum "$1" 2>/dev/null) || { echo none; return; }; echo "${o%% *}"; }
WANT_SHA=$(t_sha "$KIT_DIST/sdm-proxy-cluster-kit.sh")

t_ok()   { printf 'ok   - %s\n' "$*"; }
t_bad()  { printf 'FAIL - %s\n' "$*"; T_FAILS=$((T_FAILS + 1)); }
t_skip() { printf 'SKIP - %s\n' "$*"; exit 77; }
t_note() { printf '#      %s\n' "$*"; }

t_eq() { # DESC GOT WANT
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1 (got '$2', want '$3')"; fi
}
t_has() { # DESC FILE NEEDLE  (fixed string)
  if grep -qF -- "$3" "$2"; then t_ok "$1"; else t_bad "$1 (missing '$3')"; t_tail "$2"; fi
}
t_hasnt() { # DESC FILE NEEDLE
  if grep -qF -- "$3" "$2"; then t_bad "$1 (found '$3')"; t_tail "$2"; else t_ok "$1"; fi
}
t_tail() { sed 's/^/#      | /' "$1" | tail -25; }
t_mode() { stat -c '%a %U:%G' "$1" 2>/dev/null || echo missing; }

t_reset() { rm -rf /opt/sdm-proxy-cluster-kit; }

# t_kit_installed DESC : the kit landed byte-identical, root-only.
t_kit_installed() {
  t_eq "$1: kit is byte-identical to dist" "$(t_sha "$KIT_TARGET")" "$WANT_SHA"
  t_eq "$1: kit file is 0700 root" "$(t_mode "$KIT_TARGET")" "700 root:root"
  t_eq "$1: kit dir is 0700 root" "$(t_mode /opt/sdm-proxy-cluster-kit)" "700 root:root"
}

t_done() {
  rm -rf "$T_WORK"
  if [ "$T_FAILS" -eq 0 ]; then echo "PASS"; exit 0; fi
  echo "$T_FAILS assertion(s) failed"; exit 1
}

# shellcheck shell=bash
# ============================================================================
# tests/lib/container-prep.sh - package installs that work on every test image
# (ubuntu, debian, rockylinux, amazonlinux, centos:7 with its EOL repos).
#
# Source it inside a test container:
#   . /kit/tests/lib/container-prep.sh
#   prep_need curl script || t_skip "no curl/script on this image"
#
# Or run it directly to pre-install everything the tests use (tests/run.sh does
# this once per image and caches the result with `docker commit`):
#   bash /kit/tests/lib/container-prep.sh --warm
# ============================================================================

# Commands the tests may ask for. --warm installs all of them.
PREP_WARM_CMDS="curl script zsh sudo gzip sha256sum base64 timeout useradd"
PREP_UPDATED=""

prep_detect() { # sets PREP_ID PREP_VER PREP_PKG (apt|dnf|yum)
  PREP_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")
  PREP_VER=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
  if command -v apt-get >/dev/null 2>&1; then PREP_PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PREP_PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PREP_PKG=yum
  else PREP_PKG=""; fi
}

# CentOS 7 is EOL: mirrorlist.centos.org is gone. Point yum at vault.centos.org
# (aarch64 builds live under /altarch). Idempotent.
prep_fix_centos7() {
  [ "$PREP_ID" = centos ] && [ "${PREP_VER%%.*}" = 7 ] || return 0
  [ -f /etc/yum.repos.d/kit-vault.repo ] && return 0
  local base=http://vault.centos.org/7.9.2009 keys="" k r
  [ "$(uname -m)" = aarch64 ] && base=http://vault.centos.org/altarch/7.9.2009
  for k in /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7*; do [ -f "$k" ] && keys="$keys file://$k"; done
  mkdir -p /etc/yum.repos.d/disabled
  mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/disabled/ 2>/dev/null || true
  for r in os updates extras; do
    printf '[vault-%s]\nname=CentOS 7 vault %s\nbaseurl=%s/%s/$basearch/\ngpgcheck=1\ngpgkey=%s\nenabled=1\n\n' \
      "$r" "$r" "$base" "$r" "${keys# }"
  done > /etc/yum.repos.d/kit-vault.repo
}

prep_pkg_for() { # CMD -> package name for this distro
  case "$1:$PREP_PKG" in
    script:apt) echo bsdutils;;
    script:*) echo util-linux;;
    useradd:apt) echo passwd;;
    useradd:*) echo shadow-utils;;
    sha256sum:*|base64:*|timeout:*) echo coreutils;;
    *) echo "$1";;
  esac
}

# prep_need CMD... : make sure each command exists, installing packages if needed.
# Returns 1 (does not exit) when something could not be installed.
# shellcheck disable=SC2086  # $pkgs is a word list on purpose
prep_need() {
  local c pkgs="" missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [ -z "$missing" ] && return 0
  [ -n "${PREP_PKG+x}" ] || prep_detect
  prep_fix_centos7
  for c in $missing; do pkgs="$pkgs $(prep_pkg_for "$c")"; done
  echo "prep: installing$pkgs (for$missing) via ${PREP_PKG:-nothing}" >&2
  case $PREP_PKG in
    apt)
      if [ -z "$PREP_UPDATED" ]; then apt-get update -qq >/dev/null 2>&1; PREP_UPDATED=1; fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs >/dev/null 2>&1;;
    dnf) dnf install -y -q --allowerasing $pkgs >/dev/null 2>&1;;
    yum) yum install -y -q $pkgs >/dev/null 2>&1;;
  esac
  local rc=0
  for c in $missing; do
    command -v "$c" >/dev/null 2>&1 || { echo "prep: could not install $c" >&2; rc=1; }
  done
  return $rc
}

if [ "${1:-}" = --warm ]; then
  prep_detect
  # shellcheck disable=SC2086
  prep_need $PREP_WARM_CMDS || true   # partial is fine: tests skip what is missing
  case $PREP_PKG in apt) apt-get clean;; dnf|yum) $PREP_PKG clean all -q >/dev/null 2>&1;; esac
  exit 0
fi

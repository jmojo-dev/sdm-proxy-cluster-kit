#!/usr/bin/env bash
# (a) dist/paste-me.txt, fed to bash / sh / zsh on stdin, reproduces the kit
#     byte-for-byte, installs it 0700 root, and runs it.
. /kit/tests/lib/testlib.sh
. /kit/tests/lib/container-prep.sh

PASTE=$T_WORK/paste-me.txt
cp "$KIT_DIST/paste-me.txt" "$PASTE"

run_with() { # LABEL SHELL... : feed the paste block on stdin
  local label=$1 out=$T_WORK/out.txt rc; shift
  t_reset
  "$@" < "$PASTE" > "$out" 2>&1; rc=$?
  # No TTY and no KIT_MODE: the kit itself stops with exit 2. That proves it ran.
  t_eq "$label: exit code is the kit's (2 = no mode, no tty)" "$rc" 2
  t_has "$label: reports unpacked OK" "$out" "unpacked OK: $KIT_TARGET"
  t_has "$label: kit ran (asks for KIT_MODE)" "$out" "No mode selected"
  t_hasnt "$label: no mangled warning" "$out" "TRUNCATED OR MANGLED"
  t_kit_installed "$label"
  t_eq "$label: payload temp file removed" "$(ls /opt/sdm-proxy-cluster-kit)" "sdm-proxy-cluster-kit.sh"
}

run_with "bash" bash
t_note "/bin/sh is $(readlink -f /bin/sh)"
run_with "sh ($(basename "$(readlink -f /bin/sh)"))" sh
if [ -x /bin/dash ]; then run_with "dash" dash; fi
if prep_need zsh; then run_with "zsh" zsh -f; else t_note "zsh not installable here - skipped"; fi

# Paste a second time over an existing install: must replace cleanly.
run_with "bash re-paste" bash

# Hardened hosts run root with umask 077: /opt/strongdm must still end up 0755.
t_reset
(umask 077; sh < "$PASTE" > "$T_WORK/out.txt" 2>&1)
t_kit_installed "umask 077"

# The saved copy runs on its own.
t_eq "--version from the saved copy" "$(bash "$KIT_TARGET" --version 2>&1)" "sdm-proxy-cluster-kit $KIT_VERSION"
bash "$KIT_TARGET" --help > "$T_WORK/help.txt" 2>&1
t_has "--help prints usage" "$T_WORK/help.txt" "usage: bash sdm-proxy-cluster-kit.sh"

t_done

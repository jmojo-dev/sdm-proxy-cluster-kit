#!/usr/bin/env bash
# (c) dist/install.sh as `curl | bash`: installs the kit 0700 root, hands args and
#     env through, fails clean without a mode, runs nothing when cut short, and
#     handles the not-root cases (no sudo / no tty / sudo with a tty).
# shellcheck disable=SC2024  # redirects after sudo are meant to stay ours
. /kit/tests/lib/testlib.sh
. /kit/tests/lib/container-prep.sh

INST=$T_WORK/install.sh
cp "$KIT_DIST/install.sh" "$INST"
chmod 0644 "$INST"
OUT=$T_WORK/out.txt

# Root, no TTY, KIT_MODE unset -> kit installed, then a clean exit 2.
t_reset
cat "$INST" | bash > "$OUT" 2>&1; rc=$?
t_eq "root pipe, no KIT_MODE: exit 2" "$rc" 2
t_has "root pipe, no KIT_MODE: explains" "$OUT" "No mode selected."
t_has "root pipe: says where it saved the kit" "$OUT" "saved $KIT_TARGET"
t_kit_installed "root pipe"

# Arguments reach the kit.
t_reset
got=$(cat "$INST" | bash -s -- --version 2>/dev/null); rc=$?
t_eq "bash -s -- --version: output" "$got" "sdm-proxy-cluster-kit $KIT_VERSION"
t_eq "bash -s -- --version: exit 0" "$rc" 0
t_kit_installed "bash -s"

# The environment reaches the kit (KIT_MODE is validated by the kit, not the bootstrap).
t_reset
cat "$INST" | KIT_MODE=bogus bash > "$OUT" 2>&1; rc=$?
t_eq "KIT_MODE passes through: exit 2" "$rc" 2
t_has "KIT_MODE passes through: kit saw it" "$OUT" "Unknown KIT_MODE 'bogus'"

# Partial downloads run nothing.
SIZE=$(wc -c < "$INST")
t_reset
head -c $((SIZE / 2)) "$INST" | bash > "$OUT" 2>&1; rc=$?
t_eq "half a download: nothing installed" "$(t_mode /opt/sdm-proxy-cluster-kit)" "missing"
t_hasnt "half a download: kit did not run" "$OUT" "No mode selected"
if [ "$rc" -ne 0 ]; then t_ok "half a download: non-zero exit ($rc)"; else t_bad "half a download exited 0"; fi
t_reset
sed '$d' "$INST" | bash > "$OUT" 2>&1
t_eq "missing last line: nothing installed" "$(t_mode /opt/sdm-proxy-cluster-kit)" "missing"

# Not root, no sudo or no TTY -> exit 3 with a fix, nothing written.
if id nobody >/dev/null 2>&1; then
  t_reset
  su -s /bin/bash nobody -c "cat $INST | bash" > "$OUT" 2>&1; rc=$?
  t_eq "not root, no tty: exit 3" "$rc" 3
  t_has "not root, no tty: suggests verified file" "$OUT" "sudo bash ./install.sh"
  t_eq "not root, no tty: nothing installed" "$(t_mode /opt/sdm-proxy-cluster-kit)" "missing"
fi

if prep_need sudo; then
  # Plain sudo resets the environment; -E and `env` keep it (README documents this).
  t_reset
  export KIT_MODE=bogus
  cat "$INST" | sudo bash > "$OUT" 2>&1
  t_has "sudo (no -E) drops KIT_MODE" "$OUT" "No mode selected."
  cat "$INST" | sudo -E bash > "$OUT" 2>&1
  t_has "sudo -E keeps KIT_MODE" "$OUT" "Unknown KIT_MODE 'bogus'"
  unset KIT_MODE
  cat "$INST" | sudo env KIT_MODE=bogus bash > "$OUT" 2>&1
  t_has "sudo env KIT_MODE=... works" "$OUT" "Unknown KIT_MODE 'bogus'"

  # Not root WITH a terminal: install.sh writes a temp file and re-runs through sudo.
  if prep_need script useradd; then
    id kittest >/dev/null 2>&1 || useradd -m kittest
    mkdir -p /etc/sudoers.d
    echo 'kittest ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kittest; chmod 0440 /etc/sudoers.d/kittest
    t_reset
    # stdin stays open until the session ends: old script(1) (centos 7) quits at stdin EOF.
    done_f=/tmp/kittest-done.$$; rm -f "$done_f"
    { for _ in $(seq 60); do [ -e "$done_f" ] && break; sleep 1; done; } |
      su kittest -c "script -qc 'cat $INST | bash -s -- --version; touch $done_f' /dev/null" > "$OUT" 2>&1
    rm -f "$done_f"
    t_has "not root + tty: re-ran via sudo" "$OUT" "re-running the install step with sudo"
    t_has "not root + tty: kit ran with args" "$OUT" "sdm-proxy-cluster-kit $KIT_VERSION"
    t_kit_installed "not root + tty via sudo"
    t_eq "not root + tty: temp file cleaned up" \
      "$(find /tmp -maxdepth 1 -name 'sdm-proxy-cluster-kit.*' | wc -l)" 0
  else
    t_note "script/useradd unavailable - sudo+tty case skipped"
  fi
else
  t_note "sudo not installable here - sudo cases skipped"
fi

t_done

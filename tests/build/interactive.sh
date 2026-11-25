#!/usr/bin/env bash
# (a, interactive) Simulate a human pasting dist/paste-me.txt into an interactive
# shell on a real pseudo-terminal (script(1)): readline/zle line editing, history
# expansion, TAB completion and, where supported, bracketed paste. Then leave
# the kit's menu with Ctrl-C and exit the shell.
. /kit/tests/lib/testlib.sh
. /kit/tests/lib/container-prep.sh
prep_need script timeout || t_skip "script(1)/timeout not available on this image"

PASTE=$KIT_DIST/paste-me.txt
printf 'set enable-bracketed-paste on\n' > "$T_WORK/inputrc"

# Write like a terminal does: in small bursts. Dumping everything at once makes
# script(1) deadlock (pty input full while the echo it has not read piles up).
feed() { # BRACKETED(0|1) TRANSCRIPT
  local n=0 line
  [ "$1" = 1 ] && printf '\033[200~'
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    n=$((n + 1)); [ $((n % 8)) = 0 ] && sleep 0.05
  done < "$PASTE"
  [ "$1" = 1 ] && printf '\033[201~\r'    # end of paste, then the operator presses Enter
  # Leave the menu with Ctrl-C (SIGINT via the tty), so the test never depends on
  # what a mode asks next. The kit traps INT and exits 130.
  for _ in $(seq 120); do grep -q 'choose 1-' "$2" 2>/dev/null && break; sleep 0.5; done
  sleep 1; printf '\003'
  sleep 2; printf 'exit\n'
}

run_tty() { # LABEL BRACKETED(0|1) SHELL-COMMAND
  local label=$1 br=$2 cmd=$3 out=$T_WORK/tty.txt done=$T_WORK/done
  t_reset; rm -f "$done" "$out"
  # Keep stdin open until the shell exits: old script(1) quits at stdin EOF.
  { feed "$br" "$out"; for _ in $(seq 120); do [ -e "$done" ] && break; sleep 1; done; } |
    TERM=xterm INPUTRC=$T_WORK/inputrc timeout -k 10 150 script -qc "$cmd; touch $done" /dev/null > "$out" 2>&1
  touch "$done"
  tr -d '\r' < "$out" > "$out.clean"
  t_has "$label: unpacked" "$out.clean" "unpacked OK: /opt"
  t_has "$label: menu shown" "$out.clean" "What do you want to do"
  t_hasnt "$label: no history expansion error" "$out.clean" "event not found"
  t_hasnt "$label: no zsh history error" "$out.clean" "no such event"
  t_hasnt "$label: no completion listing" "$out.clean" "Display all"
  t_kit_installed "$label"
}

run_tty "bash -i (typed)" 0 "bash --norc --noprofile -i"
case ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]} in
  4[0-3]) t_note "bash $BASH_VERSION has no bracketed paste - bracketed case skipped";;
  *) run_tty "bash -i (bracketed paste)" 1 "bash --norc --noprofile -i";;
esac
if prep_need zsh; then
  run_tty "zsh -i (typed)" 0 "zsh -f -i"
  # Terminals only send paste brackets to apps that ask for them; zsh asks since 5.1.
  case $(zsh -fc 'echo $ZSH_VERSION') in
    [0-4].*|5.0*) t_note "zsh $(zsh -fc 'echo $ZSH_VERSION') has no bracketed paste - bracketed case skipped";;
    *) run_tty "zsh -i (bracketed paste)" 1 "zsh -f -i";;
  esac
else
  t_note "zsh not installable here - skipped"
fi

t_done

#!/usr/bin/env bash
# (d) Lint with THIS image's shells: no TABs/CRs, bash -n under the image's bash
#     (4.2 on centos:7), POSIX/zsh parse of the paste block, shellcheck if present.
. /kit/tests/lib/testlib.sh
. /kit/tests/lib/container-prep.sh

t_note "bash $BASH_VERSION"
TAB=$(printf '\t'); CR=$(printf '\r')
for f in $(find /kit/src -type f -name '*.sh') "$KIT_DIST"/sdm-proxy-cluster-kit.sh "$KIT_DIST"/install.sh "$KIT_DIST"/paste-me.txt; do
  n=${f#/kit/}
  if grep -q "$TAB" "$f"; then t_bad "$n: contains TAB"; else t_ok "$n: no TAB"; fi
  if grep -q "$CR" "$f"; then t_bad "$n: contains CR"; else t_ok "$n: no CR"; fi
done

for f in "$KIT_DIST/sdm-proxy-cluster-kit.sh" "$KIT_DIST/install.sh"; do
  if err=$(bash -n "$f" 2>&1); then t_ok "bash -n ${f#/kit/}"; else t_bad "bash -n ${f#/kit/}: $err"; fi
done
# The kit must load under this bash (catches bash-5-only syntax at source time on 4.2).
t_eq "kit --version under bash $BASH_VERSION" "$(bash "$KIT_DIST/sdm-proxy-cluster-kit.sh" --version 2>&1)" \
  "sdm-proxy-cluster-kit $KIT_VERSION"

if err=$(sh -n "$KIT_DIST/paste-me.txt" 2>&1); then t_ok "sh -n paste-me.txt ($(readlink -f /bin/sh))"
else t_bad "sh -n paste-me.txt: $err"; fi
if [ -x /bin/dash ]; then
  if err=$(dash -n "$KIT_DIST/paste-me.txt" 2>&1); then t_ok "dash -n paste-me.txt"; else t_bad "dash -n paste-me.txt: $err"; fi
fi
if prep_need zsh; then
  if err=$(zsh -n "$KIT_DIST/paste-me.txt" 2>&1); then t_ok "zsh -n paste-me.txt"; else t_bad "zsh -n paste-me.txt: $err"; fi
fi
# Characters that interactive shells treat specially must not appear in the paste block.
if grep -q '!' "$KIT_DIST/paste-me.txt"; then t_bad "paste-me.txt contains '!' (history expansion)"
else t_ok "paste-me.txt has no '!'"; fi
if LC_ALL=C grep -q '[^ -~]' "$KIT_DIST/paste-me.txt"; then t_bad "paste-me.txt has non-ASCII bytes"
else t_ok "paste-me.txt is plain ASCII"; fi
t_eq "paste-me.txt: longest line <= 100" "$(awk 'length > m { m = length } END { print (m <= 100) }' "$KIT_DIST/paste-me.txt")" 1

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -S warning -e SC2034 "$KIT_DIST/sdm-proxy-cluster-kit.sh" > "$T_WORK/sc.txt" 2>&1; then
    t_ok "shellcheck (warning+)"
  else
    t_note "shellcheck findings (not fatal):"; t_tail "$T_WORK/sc.txt"
  fi
else
  t_note "shellcheck not installed in this image - skipped"
fi

t_done

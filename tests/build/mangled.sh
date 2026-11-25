#!/usr/bin/env bash
# (b) A damaged paste never runs anything and says so clearly; a good install
#     already on disk survives a bad paste; harmless whitespace is tolerated.
. /kit/tests/lib/testlib.sh

GOOD=$T_WORK/good.txt
cp "$KIT_DIST/paste-me.txt" "$GOOD"
# Line numbers of the base64 payload (between the heredoc line and its delimiter).
FIRST=$(awk '/<<.SDMKIT_PAYLOAD_END_/ { print NR + 1; exit }' "$GOOD")
LAST=$(awk '/^SDMKIT_PAYLOAD_END_/ { print NR - 1; exit }' "$GOOD")
MID=$(( (FIRST + LAST) / 2 ))
t_note "payload is lines $FIRST-$LAST; damaging around line $MID"

expect_refused() { # LABEL FILE
  local out=$T_WORK/out.txt
  sh < "$2" > "$out" 2>&1
  t_has "$1: says the paste was mangled" "$out" "PASTE WAS TRUNCATED OR MANGLED - nothing was run."
  t_hasnt "$1: kit did not run" "$out" "No mode selected"
  t_hasnt "$1: no unpacked OK" "$out" "unpacked OK"
}

# One character changed in one base64 line.
awk -v n="$MID" 'NR == n { c = substr($0, 10, 1); $0 = substr($0, 1, 9) (c == "A" ? "B" : "A") substr($0, 11) } 1' \
  "$GOOD" > "$T_WORK/flip.txt"
t_reset; expect_refused "one char flipped" "$T_WORK/flip.txt"
t_eq "one char flipped: no kit written" "$(t_mode "$KIT_TARGET")" "missing"

# A run of lines lost in the middle (what a choking console does).
awk -v a="$MID" 'NR < a || NR >= a + 12' "$GOOD" > "$T_WORK/gap.txt"
t_reset; expect_refused "12 lines dropped" "$T_WORK/gap.txt"

# One line cut short (terminal line-length limits).
awk -v n="$MID" 'NR == n { $0 = substr($0, 1, 40) } 1' "$GOOD" > "$T_WORK/short.txt"
t_reset; expect_refused "line cut short" "$T_WORK/short.txt"

# A bad paste must not replace a good kit already installed.
t_reset; sh < "$GOOD" > /dev/null 2>&1
expect_refused "bad paste over good install" "$T_WORK/flip.txt"
t_kit_installed "bad paste over good install: previous kit intact"

# Whitespace some consoles add (indent, trailing spaces, CR) inside the payload is ignored.
awk -v a="$FIRST" -v b="$LAST" 'NR >= a && NR <= b { $0 = "  " $0 "  \r" } 1' "$GOOD" > "$T_WORK/ws.txt"
t_reset; sh < "$T_WORK/ws.txt" > "$T_WORK/out.txt" 2>&1
t_has "indent/trailing space/CR in payload: still unpacks" "$T_WORK/out.txt" "unpacked OK: $KIT_TARGET"
t_kit_installed "whitespace-tolerant"

# Not root: refuses with a clear message, nothing runs.
if id nobody >/dev/null 2>&1; then
  t_reset
  su -s /bin/sh nobody -c "cd /tmp && sh $GOOD" > "$T_WORK/out.txt" 2>&1
  t_has "not root: says so" "$T_WORK/out.txt" "NOT ROOT - nothing was run."
  t_hasnt "not root: kit did not run" "$T_WORK/out.txt" "No mode selected"
else
  t_note "no 'nobody' user - not-root case skipped"
fi

t_done

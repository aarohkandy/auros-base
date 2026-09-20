#!/usr/bin/env bash
# Shell idioms that are wrong in a way that only shows up on the HEALTHY path.
#
# 1. `grep -c PATTERN || echo 0`
#    grep -c ALWAYS prints a count — including 0 — and exits 1 when that count is 0. So on the zero
#    case this prints TWO zeros, "0\n0", and every integer test that consumes it errors out.
#
#    That mattered more than it sounds, because of WHICH checks used it. The matrix agent counted
#    SELinux denials (B11), kernel oopses (B11) and compositor crashes (B8) this way. A clean image
#    has ZERO of each. So those checks would have FAILED ON EVERY PERFECT IMAGE — the bug fires on
#    exactly the outcome we are hoping for, and Gate 1 would have stayed red on a correct build while
#    somebody debugged a graphics crash that never happened.
#
# 2. `find` over a list of directories where any may be absent, inside `$( )`, under `set -e` and
#    `pipefail`. find exits 1 on a missing directory, pipefail propagates it, and `set -e` kills the
#    script with NO MESSAGE. It cost a base build that stopped mid-step with nothing in the log.
#
# How this file itself is written matters: the first attempt to FIX (1) used a regex that stopped at
# `|`, which skipped every grep whose pattern contained an alternation — and the check afterwards used
# the same regex and reported "none left" while three remained. So the scan below is a plain substring
# test. A check that shares the bug it is looking for cannot find it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok () { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no () { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "grep -c double-zero:"
# Plain substring, deliberately. See the note above.
# This file is excluded from its own scan: it has to CONTAIN the wrong idiom, both to describe it and
# to prove below that it really misbehaves. Same reason tools/honesty-gate.mjs skips its rules file.
hits=$(cd "$HERE" && grep -rn '|| echo 0' --include='*.sh' . 2>/dev/null | grep -v node_modules \
       | grep -v '^\./tests/shell-idioms\.test\.sh:' | grep 'grep -' || true)
if [ -z "$hits" ]; then ok "no 'grep -c ... || echo 0' anywhere in auros-base"
else no "found the double-zero idiom:"; printf '%s\n' "$hits" | sed 's/^/          /'; fi

# Prove the idiom is actually wrong, so this test is defending a real bug and not a preference.
bad=$(printf 'fine\n' | grep -c nope || echo 0)
[ "$bad" = "$(printf '0\n0')" ] && ok "the wrong idiom really does emit two zeros (so the scan above matters)" \
                                 || no "the wrong idiom did not reproduce — this test may be obsolete"
good=$(printf 'fine\n' | grep -c nope || true)
[ "$good" = "0" ] && ok "the right idiom emits exactly one 0 on the zero case" || no "right idiom gave [$good]"
[ "$good" -eq 0 ] 2>/dev/null && ok "and that value survives an integer test" || no "integer test failed on [$good]"
good2=$(printf 'a\nb\n' | grep -c . || true)
[ "$good2" = "2" ] && ok "the right idiom still counts correctly when there ARE matches" || no "got [$good2]"

echo
echo "find over possibly-absent directories under set -e:"
out=$(bash -c 'set -euo pipefail
  x="$(find /definitely-absent-auros /tmp -maxdepth 0 2>/dev/null | wc -l)"; echo reached' 2>&1 || true)
[ -z "$out" ] && ok "confirmed: an absent directory kills an unguarded find silently (the bug is real)" \
              || no "expected silent death, got [$out] — re-check whether this hazard still applies"
out=$(bash -c 'set -euo pipefail
  e=""; for d in /definitely-absent-auros /tmp; do [ -d "$d" ] && e="$e $d"; done
  x="$(find $e -maxdepth 0 | wc -l)"; echo reached' 2>&1 || true)
[ "$out" = "reached" ] && ok "filtering to existing directories first survives" || no "guarded find died: [$out]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

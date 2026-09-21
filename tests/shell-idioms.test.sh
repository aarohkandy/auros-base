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


echo
echo "local self-reference (bash expands a whole 'local' line before assigning any of it):"
out=$(bash -c 'set -u; f(){ local t="$1" d="x/${t}"; echo "$d"; }; f hi' 2>&1 || true)
case "$out" in
  *"unbound variable"*) ok "confirmed: a local reading its own sibling dies under set -u (the bug is real)" ;;
  *) no "expected an unbound-variable death, got [$out] — re-check this hazard" ;;
esac
hits=$(python3 "$HERE/tests/lib/local_selfref.py" "$HERE")
if [ -z "$hits" ]; then ok "no local line reads a name it assigns in the same statement"
else no "a local line reads a name it assigns in the same statement:"; printf '%s\n' "$hits" | sed 's/^/          /'; fi

echo
echo "producer | grep -q under pipefail (grep -q exits on the match, the producer dies of SIGPIPE, pipefail reports a MISS):"
# Polarity decides the damage. `if ! x | grep -q GOOD; then fail` goes falsely RED. `if x | grep -q BAD;
# then fail` goes falsely GREEN — a check that can never fail. prove-red.sh hit this 88/3000 on Linux.
# D19 says every script sets pipefail, and libraries inherit it from whoever sources them, so every shell
# file is scanned, not just the ones that spell out `pipefail`. Comment lines are skipped (they name the
# idiom to warn against it). Plain substrings again: find "| grep -", then read the flag word after it
# with shell string operations. No regex, for the reason at the top of this file.
# ponytail: only the first flag word after grep is read, so `| grep -E -q` slips through; none exist today.
sigpipe_scan() { # <dir> — prints file:line for every pipe into an early-exiting grep
  local f line n pre rest flags
  while IFS= read -r f; do
    case "$f" in
      *.sh) ;;
      *) IFS= read -r line < "$f" || true
         case "$line" in '#!'*sh*) ;; *) continue ;; esac ;;
    esac
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n+1))
      case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
      rest="$line"
      while [ "${rest#*| grep -}" != "$rest" ]; do
        pre="${rest%%"| grep -"*}"; rest="${rest#*| grep -}"; flags="${rest%% *}"
        case "$pre" in *'|') continue ;; esac   # `a || grep -q` is an or-list, not a pipe
        case "$flags" in
          -quiet*|-silent*) ;;   # --quiet / --silent
          -*) continue ;;        # any other long option
          *q*) ;;                # -q, -qE, -Eq, -qxF ...
          *) continue ;;
        esac
        printf '%s:%s: %s\n' "${f#"$1"/}" "$n" "$line"; break
      done
    done < "$f"
  done < <(grep -rlIF -e '| grep -' "$1" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.github 2>/dev/null \
           | grep -v '/tests/shell-idioms\.test\.sh$' || true)
}

# Prove the race is real, deterministically: the producer writes far more than a pipe holds, so after
# grep -q has matched line 1 and gone, the producer's next write MUST hit SIGPIPE.
# The exit code is the producer's, and producers differ: one killed by SIGPIPE gives 141 (macOS
# seq), one that catches EPIPE and reports it gives 1 (GNU seq on the runner: "write error: Broken
# pipe"). Either way the MATCH is lost, and that — not a specific number — is the hazard.
rc=$(bash -c 'set -o pipefail; { echo BAD; seq 1 200000; } | grep -q BAD; echo $?' 2>/dev/null)
[ "$rc" != 0 ] && ok "confirmed: a MATCHING producer | grep -q returns non-zero [$rc] under pipefail (the bug is real)" \
               || no "a matching pipe returned 0 — the hazard did not reproduce; re-check this test"
v=$(bash -c 'set -o pipefail; if { echo BAD; seq 1 200000; } | grep -q BAD; then echo RED; else echo GREEN; fi' 2>/dev/null)
[ "$v" = GREEN ] && ok "  ...so 'if x | grep -q BAD; then fail' reads GREEN with BAD in the output (the false pass)" \
                 || no "  ...expected the false GREEN, got [$v]"
rc=$(bash -c 'set -o pipefail; grep -q BAD <<<"$({ echo BAD; seq 1 200000; })"; echo $?')
[ "$rc" = 0 ] && ok "the here-string form matches reliably" || no "here-string form gave [$rc]"

# Prove the scan fires on planted examples, and stays quiet on the safe forms.
PLANT="$(mktemp -d)"; trap 'rm -rf "$PLANT"' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'if journalctl -k | grep -qE "oops"; then echo bad; fi' > "$PLANT/planted"
printf '%s\n' 'x() { kcmshell6 --list | grep -Eq "$1"; }' 'y() { dnf --help | grep --quiet flag; }' > "$PLANT/lib.sh"
printf '%s\n' 'set -uo pipefail' 'grep -q oops <<<"$(journalctl -k)"' '  # never x | grep -q y' \
              'n=$(x | grep -c y || true)' 'x | grep -v y | sort' 'a || grep -q b f' > "$PLANT/fine.sh"
got=$(sigpipe_scan "$PLANT")
case "$got" in *"planted:3:"*) ok "the scan catches a planted 'journalctl | grep -qE' in an extensionless script" ;;
  *) no "the scan MISSED the planted example: [$got]" ;; esac
case "$got" in *"lib.sh:1:"*) ok "  ...and 'grep -Eq' (q not first) in a sourced library" ;; *) no "  ...missed grep -Eq: [$got]" ;; esac
case "$got" in *"lib.sh:2:"*) ok "  ...and 'grep --quiet'" ;; *) no "  ...missed grep --quiet: [$got]" ;; esac
case "$got" in *"fine.sh"*) no "the scan flagged a safe form: [$got]" ;; *) ok "  ...and leaves here-strings, comments, grep -c and grep -v alone" ;; esac

hits=$(sigpipe_scan "$HERE")
if [ -z "$hits" ]; then ok "no pipe into grep -q anywhere in auros-base's shell"
else no "pipe into grep -q (use: grep -q PATTERN <<<\"\$(producer)\", or capture first):"; printf '%s\n' "$hits" | sed 's/^/          /'; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# tools/make-enrolment.sh — a school's first passwords: shown once on a terminal, only hashes on disk.
#
# The REAL script runs under `script` (it refuses a stdout that is not a terminal). openssl is wrapped
# by a shim that logs its argv — a password must never appear there — and then runs the real openssl
# when it can make SHA-512 crypt hashes (Linux), or a stand-in that fakes one (macOS's LibreSSL
# cannot). With the real one, every printed password is checked against its hash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

SCRIPT="$REPO/tools/make-enrolment.sh"
printf 'make-enrolment.sh — first passwords for the handover sheet, hashes for the install media\n'

REAL=0; case "$(printf x | openssl passwd -6 -stdin 2>/dev/null)" in '$6$'*) REAL=1 ;; esac
[ "$REAL" = 1 ] || note "this openssl cannot make \$6\$ hashes; a stand-in is used and the password-vs-hash check is skipped"
REAL_OPENSSL="$(command -v openssl)"
STUBS="$(stubdir)"
stub "$STUBS" openssl <<EOF
#!/usr/bin/env bash
echo "\$*" >> "\$SHIM_LOG"
[ "\${OPENSSL_BROKEN:-0}" = 1 ] && { echo "unknown option '-6'" >&2; exit 1; }
[ "$REAL" = 1 ] && exec "$REAL_OPENSSL" "\$@"
printf '\$6\$stubsalt\$%s\n' "\$(shasum -a 256 | cut -c1-40)"
EOF

W="$(newroot)"
# tty_run <cmd...> — under a pseudo-terminal: util-linux script on Linux, BSD script on macOS.
tty_run() {
  if script --version >/dev/null 2>&1; then script -qec "$(printf '%q ' "$@")" /dev/null
  else script -q /dev/null "$@"; fi
}
mk() { SHIM_LOG="$W/argv" PATH="$STUBS:$PATH" tty_run bash "$SCRIPT" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }

group "the happy path"
run_check mkenrol green "two accounts → a 0600 hash file, passwords on the terminal" -- mk --out "$W/school.enrol" school-it pupil
OUT="$T_LAST_OUT"
F="$(cat "$W/school.enrol" 2>/dev/null)"
assert_has "the file is 0600" "-rw-------" "$(ls -l "$W/school.enrol")"
assert_eq  "one hash line per account, SHA-512 crypt" "2" "$(grep -cE '^(school-it|pupil):\$6\$[^:]+$' <<<"$F")"
pw="$(sed -nE 's/^  (school-it|pupil) +([a-z2-9]{5}(-[a-z2-9]{5}){3})$/\1 \2/p' <<<"$OUT")"
assert_eq  "both passwords printed, 4 groups of 5 from the no-look-alike alphabet" "2" "$(grep -c . <<<"$pw")"
p1="$(sed -n 1p <<<"$pw" | cut -d' ' -f2)"; p2="$(sed -n 2p <<<"$pw" | cut -d' ' -f2)"
[ "$p1" != "$p2" ] && ok "each account gets its own password" || bad "the two accounts share a password"
assert_not "no password is in the file" "$p1" "$F"
assert_not "…either of them" "$p2" "$F"
assert_not "no password was ever an openssl argument" "$p1" "$(cat "$W/argv")"
assert_has "openssl was fed on stdin" "passwd -6 -stdin" "$(cat "$W/argv")"
if [ "$REAL" = 1 ]; then
  while read -r n p; do
    h="$(sed -n "s/^$n://p" <<<"$F")"; salt="$(cut -d'$' -f3 <<<"$h")"
    assert_eq "$n's printed password verifies against its hash" "$h" "$(printf '%s' "$p" | openssl passwd -6 -salt "$salt" -stdin)"
  done <<<"$pw"
fi

group "refusals"
run_check mkenrol red "stdout is a file, not a terminal" -- env SHIM_LOG="$W/argv" PATH="$STUBS:$PATH" bash "$SCRIPT" --out "$W/b.enrol" school-it
assert_has "…says why" "not a terminal" "$T_LAST_OUT"
assert_nofile "…and makes nothing" "$W/b.enrol"
before="$(cat "$W/school.enrol")"
run_check mkenrol red "the output file exists" -- mk --out "$W/school.enrol" school-it
assert_eq "…and it is untouched" "$before" "$(cat "$W/school.enrol")"
run_check mkenrol red "a name no recipe can declare" -- mk --out "$W/c.enrol" 'School_IT'
run_check mkenrol red "an account named twice" -- mk --out "$W/d.enrol" pupil pupil
run_check mkenrol red "no account named" -- mk --out "$W/e.enrol"
export OPENSSL_BROKEN=1
run_check mkenrol red "an openssl that cannot make SHA-512 crypt (LibreSSL)" -- mk --out "$W/f.enrol" school-it
unset OPENSSL_BROKEN
assert_has "…says where to run it" "Linux build machine" "$T_LAST_OUT"
for f in c d e f; do assert_nofile "no file left by refusal $f" "$W/$f.enrol"; done

t_finish make-enrolment.test.sh

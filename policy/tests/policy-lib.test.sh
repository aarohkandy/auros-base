#!/usr/bin/env bash
# ==================================================================================================
# policy-lib.test.sh — prove auros_disable_weak_deps puts install_weak_deps in the [main] SECTION.
#
# The bug this exists to keep fixed: the function used to `cat >>` its block onto the END of
# /etc/dnf/dnf.conf. dnf.conf is an INI file, and a key belongs to whatever section header precedes
# it. If any section follows [main] — a repo section, a hardening-layer drop-in, a future Fedora
# default — then install_weak_deps=False lands in THAT section and dnf ignores it, without a word.
# A later `dnf install` in the customer recipe's own layer then pulls Recommends back in and
# reinstates the desktop kiosk mode just deleted.
#
# That is the silent no-op this file's own header calls out as mechanism 2 ("they all fail QUIETLY,
# which is the part that matters"), committed by the handler for it. This test drives the real
# function against fixtures and asserts the key's SECTION, not its presence.
# ==================================================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/policy-lib.sh"
[ -r "$LIB" ] || { echo "cannot find lib/policy-lib.sh"; exit 2; }

PASS=0; FAILED=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED+1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC1090
. "$LIB"
# There is no dnf on the host; auros_verify_weak_deps then warns "NOT VERIFIED", which is the
# correct honest behaviour and is asserted below.

# Which INI section does <key> end up in? This is the whole point of the test, so it is computed
# from the file rather than grepped for.
section_of() {   # section_of <file> <key>
    awk -v key="$2" '
        /^[[:space:]]*\[.*\][[:space:]]*$/ { sec = $0; gsub(/[][[:space:]]/, "", sec); next }
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print (sec == "" ? "<no section>" : sec); found=1; exit }
        END { if (!found) print "<absent>" }
    ' "$1"
}

echo "── [main] is NOT the last section: the appending version put the key in the wrong one ──────"
cat > "$WORK/a.conf" <<'EOF'
[main]
gpgcheck=1
installonly_limit=3

[updates-testing]
enabled=0
EOF
AUROS_DNF_CONF="$WORK/a.conf" auros_disable_weak_deps >"$WORK/log" 2>&1
got=$(section_of "$WORK/a.conf" install_weak_deps)
[ "$got" = main ] && ok "key lands in [main] (was: [updates-testing])" || no "key lands in [main]" "got [$got]"
[ "$(grep -c '^install_weak_deps' "$WORK/a.conf")" = 1 ] && ok "exactly one occurrence" || no "exactly one occurrence"
grep -q '^\[updates-testing\]' "$WORK/a.conf" && ok "the other section is untouched (shared file)" || no "the other section is untouched"
grep -q 'enabled=0' "$WORK/a.conf" && ok "its contents are untouched" || no "its contents are untouched"

echo "── [main] IS the last section: still correct, and still only once ──────────────────────────"
cat > "$WORK/b.conf" <<'EOF'
[fedora]
enabled=1

[main]
gpgcheck=1
EOF
AUROS_DNF_CONF="$WORK/b.conf" auros_disable_weak_deps >>"$WORK/log" 2>&1
got=$(section_of "$WORK/b.conf" install_weak_deps)
[ "$got" = main ] && ok "key lands in [main]" || no "key lands in [main]" "got [$got]"

echo "── idempotent: a second call changes nothing ───────────────────────────────────────────────"
before="$(cat "$WORK/a.conf")"
AUROS_DNF_CONF="$WORK/a.conf" auros_disable_weak_deps >>"$WORK/log" 2>&1
[ "$before" = "$(cat "$WORK/a.conf")" ] && ok "byte-identical after a second call (S7 builds twice)" || no "byte-identical after a second call"

echo "── no [main] at all: one is created rather than writing a key into nothing ─────────────────"
cat > "$WORK/c.conf" <<'EOF'
[somerepo]
enabled=1
EOF
AUROS_DNF_CONF="$WORK/c.conf" auros_disable_weak_deps >>"$WORK/log" 2>&1
got=$(section_of "$WORK/c.conf" install_weak_deps)
[ "$got" = main ] && ok "a [main] section is created and the key goes in it" || no "a [main] section is created" "got [$got]"
grep -q 'no \[main\] section' "$WORK/log" && ok "and it says so out loud in the build log" || no "and it says so out loud"

echo "── verification is attempted, and an unverifiable result is stated rather than assumed ─────"
grep -q 'NOT VERIFIED' "$WORK/log" \
  && ok "no dnf on this host => 'NOT VERIFIED' in the log, not a silent success" \
  || no "no dnf on this host => 'NOT VERIFIED' in the log" "$(cat "$WORK/log")"

echo "── the regression itself: assert the OLD behaviour would have failed this test ─────────────"
# Reproduce what `cat >>` used to do, and show section_of catches it. Without this line the test
# above could be passing for the wrong reason.
cat > "$WORK/d.conf" <<'EOF'
[main]
gpgcheck=1

[updates-testing]
enabled=0
EOF
printf 'install_weak_deps=False\n' >> "$WORK/d.conf"
got=$(section_of "$WORK/d.conf" install_weak_deps)
[ "$got" = "updates-testing" ] \
  && ok "appending to the end of the file puts the key in [updates-testing] — the bug, reproduced" \
  || no "appending puts the key in the wrong section" "got [$got]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]

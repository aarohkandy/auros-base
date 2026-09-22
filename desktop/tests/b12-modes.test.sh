#!/usr/bin/env bash
# ==================================================================================================
# b12-modes.test.sh — prove that check B12 can go RED, per mode, for the right reason.
#
# D19: "a step that cannot fail is not a check. When adding any gate, the first question is 'what
# would make this go red?', and if there is no answer, the gate is decoration."
#
# assert-zero-terminal.sh now evaluates B12's four tasks against what the recipe's policy mode
# CLAIMS, rather than against `open`'s list. That change is only worth anything if the new
# criteria can fail, so this file drives the real script against stubbed system commands and
# asserts, for each mode, both the green case and a specific red one:
#
#   locked  green: the network and language pages refuse to open and polkit refuses outright
#           red:   the network page OPENS        -> the KDE Control Module Restriction is not in
#                                                   force. This is the exact regression
#                                                   build/40-windows-feel.sh causes by rewriting
#                                                   /etc/xdg/kdeglobals after apply-policy, which
#                                                   nothing at run time used to notice.
#           red:   polkit answers 3 instead of 1 -> that is `managed` behaviour, not `locked`
#   open    green: the four pages open
#           red:   the network page is missing
#   kiosk   green: the application runs and no desktop binary survived
#           red:   konsole survived the removal pass
#   any     exit 2 when the claims file is missing — never a silent fall-back to `open`
#
# Runs anywhere bash runs; it stubs systemctl/kcmshell6/pkcheck/flatpak and never touches the host.
# ==================================================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../assert-zero-terminal.sh"
[ -r "$SUT" ] || { echo "cannot find assert-zero-terminal.sh next to this test"; exit 2; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
no()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the stub world ────────────────────────────────────────────────────────────────────────────────
# Every stub reads its answer out of $WORK/facts, so a scenario is a handful of lines of data and
# not a handful of copies of a fake binary.
mkstubs() {
    local bin="$WORK/bin"; rm -rf "$bin"; mkdir -p "$bin"

    cat > "$bin/systemctl" <<'EOS'
#!/usr/bin/env bash
unit=""
for a in "$@"; do case "$a" in -*) ;; is-active|is-enabled|list-units) ;; *) unit="$a" ;; esac; done
grep -qx "active:$unit" "$FACTS" && exit 0
exit 3
EOS

    cat > "$bin/kcmshell6" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "--list" ]; then grep '^kcm:' "$FACTS" | sed 's/^kcm://'; exit 0; fi
# Opening a module: it stays up only if the module is both listed AND authorised.
grep -qx "kcm:$1" "$FACTS" || { echo "no such module" >&2; exit 1; }
grep -qx "kcm-denied:$1" "$FACTS" && { echo "KAuthorized: refused" >&2; exit 1; }
sleep 30
EOS

    cat > "$bin/pkcheck" <<'EOS'
#!/usr/bin/env bash
action=""
while [ $# -gt 0 ]; do case "$1" in --action-id) action="$2"; shift 2 ;; *) shift ;; esac; done
rc="$(grep "^pk:$action=" "$FACTS" | head -1 | cut -d= -f2)"
exit "${rc:-1}"
EOS

    cat > "$bin/plasma-discover" <<'EOS'
#!/usr/bin/env bash
grep -qx "app:plasma-discover" "$FACTS" || exit 1
sleep 30
EOS

    cat > "$bin/flatpak" <<'EOS'
#!/usr/bin/env bash
echo flathub
EOS
    cat > "$bin/kreadconfig6" <<'EOS'
#!/usr/bin/env bash
echo false
EOS
    # `id -nG` answers from a groups: fact, so a scenario picks pupil or aurosadmin member.
    cat > "$bin/id" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = -nG ]; then g="$(grep '^groups:' "$FACTS" | cut -d: -f2)"; echo "${g:-pupil}"; exit 0; fi
exec /usr/bin/id "$@"
EOS
    for extra in konsole gnome-terminal xterm dolphin plasmashell gnome-shell sddm gdm; do
        cat > "$bin/$extra" <<EOS
#!/usr/bin/env bash
exit 0
EOS
    done
    chmod 0755 "$bin"/*
    printf '%s' "$bin"
}

# remove the stubs for binaries a scenario says are NOT on the image
unstub() { local b; for b in "$@"; do rm -f "$WORK/bin/$b"; done; }

run_sut() {   # run_sut <mode-env-body>  -> stdout+stderr in $OUT, exit code in $RC
    local claims="$WORK/claims.env"
    printf '%s\n' "$1" > "$claims"
    set +e
    OUT="$( AUROS_CLAIMS_FILE="$claims" \
            AUROS_LAUNCH_SETTLE=1 \
            FACTS="$WORK/facts" \
            PATH="$WORK/bin:/usr/bin:/bin" \
            WAYLAND_DISPLAY=wayland-0 \
            bash "$SUT" 2>&1 )"
    RC=$?
    set -e
}

expect_line() { # expect_line <PASS|FAIL> <substring> <description>
    if grep -q "^$1 .*$2" <<<"$OUT"; then ok "$3"; else
        no "$3"
        printf '%s\n' "$OUT" | sed -n '/install-app\|wifi\|language\|printer\|kiosk/p' | sed 's/^/        /'
    fi
}
expect_rc() { if [ "$RC" = "$1" ]; then ok "$2"; else no "$2 (exit $RC, wanted $1)"; fi; }

LOCKED='AUROS_MODE=locked
AUROS_MODE_B1=login-prompt
AUROS_MODE_B12_INSTALL_APP=none
AUROS_MODE_B12_WIFI=none
AUROS_MODE_B12_PRINTER=seat
AUROS_MODE_B12_LANGUAGE=none
AUROS_MODE_B12_USERS=own-password
AUROS_MODE_B12_DESKTOP=yes'

MANAGED_USERS='AUROS_MODE=managed
AUROS_MODE_B1=login-prompt
AUROS_MODE_B12_INSTALL_APP=admin
AUROS_MODE_B12_WIFI=admin
AUROS_MODE_B12_PRINTER=seat
AUROS_MODE_B12_LANGUAGE=admin
AUROS_MODE_B12_USERS=aurosadmin
AUROS_MODE_B12_DESKTOP=yes'

OPEN='AUROS_MODE=open
AUROS_MODE_B1=login-prompt
AUROS_MODE_B12_INSTALL_APP=seat
AUROS_MODE_B12_WIFI=seat
AUROS_MODE_B12_PRINTER=seat
AUROS_MODE_B12_LANGUAGE=seat
AUROS_MODE_B12_USERS=seat
AUROS_MODE_B12_DESKTOP=yes'

KIOSK='AUROS_MODE=kiosk
AUROS_MODE_B1=kiosk-session
AUROS_MODE_B12_INSTALL_APP=n/a
AUROS_MODE_B12_WIFI=n/a
AUROS_MODE_B12_PRINTER=n/a
AUROS_MODE_B12_LANGUAGE=n/a
AUROS_MODE_B12_USERS=n/a
AUROS_MODE_B12_DESKTOP=no'

echo "── locked: the green case ──────────────────────────────────────────────────────────────────"
mkstubs >/dev/null
cat > "$WORK/facts" <<'EOF'
active:NetworkManager
active:cups.socket
kcm:kcm_networkmanagement
kcm:kcm_regionandlang
kcm:kcm_printer_manager
kcm-denied:kcm_networkmanagement
kcm-denied:kcm_regionandlang
pk:org.freedesktop.Flatpak.app-install=1
pk:org.freedesktop.packagekit.package-install=1
pk:org.freedesktop.NetworkManager.settings.modify.system=1
pk:org.freedesktop.locale1.set-locale=1
kcm:kcm_users
pk:org.freedesktop.accounts.user-administration=1
pk:org.freedesktop.accounts.change-own-password=0
EOF
run_sut "$LOCKED"
expect_line PASS 'install-app/polkit-flatpak'  "locked: installing software is refused outright"
expect_line PASS 'wifi/polkit'                 "locked: changing the network is refused outright"
expect_line PASS 'wifi/settings-page'          "locked: the network settings page refuses to open"
expect_line PASS 'language/settings-page'      "locked: the language settings page refuses to open"
expect_line PASS 'wifi/daemon'                 "locked: NetworkManager is still running (the floor)"
expect_line PASS 'users/settings-page'         "locked, a pupil: the Users page opens (to choose their own password)"
expect_line PASS 'users/own-password'          "locked, a pupil: polkit lets them choose their own password"
expect_line PASS 'users/polkit'                "locked, a pupil: managing accounts is refused outright"

echo "── locked, owner decision: a pupil changes their own password and NOTHING else ────────────"
cp "$WORK/facts" "$WORK/facts.pupil"
sed -i.bak 's|change-own-password=0|change-own-password=2|' "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'users/own-password.*cannot choose' "a pupil who needs IT to choose their own password => RED"
cp "$WORK/facts.pupil" "$WORK/facts"
sed -i.bak 's|user-administration=1|user-administration=2|' "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'users/polkit.*administrator password' "a pupil offered account management behind a password => RED (that is managed)"
cp "$WORK/facts.pupil" "$WORK/facts"
sed -i.bak 's|user-administration=1|user-administration=0|' "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'users/polkit.*AUTHORISED' "a pupil polkit lets manage accounts => RED"
cp "$WORK/facts.pupil" "$WORK/facts"
echo 'kcm-denied:kcm_users' >> "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'users/settings-page' "the Users page still hidden from the pupil => RED (no GUI to choose a password)"
# the aurosadmin member on locked: the page opens and polkit asks for their password
cp "$WORK/facts.pupil" "$WORK/facts"
sed -i.bak 's|user-administration=1|user-administration=2|' "$WORK/facts"
echo 'groups:school-it aurosadmin' >> "$WORK/facts"
run_sut "$LOCKED"
expect_line PASS 'users/polkit'                "locked, an aurosadmin member: managing accounts asks for the admin password"
expect_line PASS 'users/own-password'          "locked, an aurosadmin member: chooses their own password too"
cp "$WORK/facts.pupil" "$WORK/facts"

echo "── managed, A4: the Users page is the IT account's, and only the IT account's ───────────────"
echo 'kcm-denied:kcm_users' >> "$WORK/facts"
cp "$WORK/facts" "$WORK/facts.mpupil"
run_sut "$MANAGED_USERS"
expect_line PASS 'users/settings-page'         "managed, a pupil: the Users page refuses to open (A4)"
expect_line PASS 'users/polkit'                "managed, a pupil: managing accounts is not granted"
sed -i.bak '/kcm-denied:kcm_users/d' "$WORK/facts"
run_sut "$MANAGED_USERS"
expect_line FAIL 'users/settings-page.*OPENED AND STAYED UP' "a pupil for whom the Users page opens => RED"
cp "$WORK/facts.mpupil" "$WORK/facts"
sed -i.bak 's|pk:org.freedesktop.accounts.user-administration=1|pk:org.freedesktop.accounts.user-administration=0|' "$WORK/facts"
run_sut "$MANAGED_USERS"
expect_line FAIL 'users/polkit.*AUTHORISED' "a pupil polkit lets manage accounts => RED"
cp "$WORK/facts.mpupil" "$WORK/facts"
sed -i.bak -e '/kcm-denied:kcm_users/d' -e 's|user-administration=1|user-administration=3|' "$WORK/facts"
echo 'groups:school-it aurosadmin' >> "$WORK/facts"
run_sut "$MANAGED_USERS"
expect_line PASS 'users/settings-page'         "an aurosadmin member: the Users page opens"
expect_line PASS 'users/polkit'                "an aurosadmin member: polkit asks for the admin password"
echo 'kcm-denied:kcm_users' >> "$WORK/facts"
run_sut "$MANAGED_USERS"
expect_line FAIL 'users/settings-page'         "an aurosadmin member with the page still hidden => RED"
cp "$WORK/facts.pupil" "$WORK/facts"

echo "── locked: RED when the KDE restriction is not in force ────────────────────────────────────"
# This is build/40-windows-feel.sh rewriting /etc/xdg/kdeglobals after apply-policy merged the
# [KDE Control Module Restrictions] group into it. Nothing at run time used to notice.
sed -i.bak '/kcm-denied:kcm_networkmanagement/d' "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'wifi/settings-page.*OPENED AND STAYED UP' "locked goes RED when the network page opens anyway"
if grep -q '40-windows-feel' <<<"$OUT"; then ok "the failure message names the cause"; else no "the failure message names the cause"; fi

echo "── locked: RED when polkit answers 'managed' instead of 'locked' ───────────────────────────"
sed -i.bak 's|pk:org.freedesktop.NetworkManager.settings.modify.system=1|pk:org.freedesktop.NetworkManager.settings.modify.system=3|' "$WORK/facts"
run_sut "$LOCKED"
expect_line FAIL 'wifi/polkit.*administrator password' "locked goes RED when the answer is 3, not 1"

echo "── open: the green case, and RED when a page is missing ────────────────────────────────────"
mkstubs >/dev/null
cat > "$WORK/facts" <<'EOF'
active:NetworkManager
active:cups.socket
kcm:kcm_networkmanagement
kcm:kcm_regionandlang
kcm:kcm_printer_manager
app:plasma-discover
pk:org.freedesktop.Flatpak.app-install=0
pk:org.freedesktop.NetworkManager.settings.modify.system=0
pk:org.freedesktop.locale1.set-locale=0
kcm:kcm_users
pk:org.freedesktop.accounts.user-administration=3
EOF
run_sut "$OPEN"
expect_line PASS 'wifi/launch'       "open: the network page opens"
expect_line PASS 'language/launch'   "open: the language page opens"
expect_line PASS 'install-app/launch' "open: the software shop opens"
expect_line PASS 'users/settings-page' "open: the Users page opens"

sed -i.bak '/kcm:kcm_networkmanagement/d' "$WORK/facts"
run_sut "$OPEN"
expect_line FAIL 'wifi/settings-page' "open goes RED when there is no network page"

echo "── kiosk: the green case, and RED when a terminal survived ─────────────────────────────────"
mkstubs >/dev/null
unstub konsole gnome-terminal xterm dolphin plasmashell gnome-shell sddm gdm plasma-discover
cat > "$WORK/facts" <<'EOF'
active:auros-kiosk.service
EOF
mkdir -p "$WORK/etc/auros"
run_sut "$KIOSK"
expect_line PASS 'kiosk/service'   "kiosk: the application service is running"
expect_line FAIL 'kiosk/configured' "kiosk goes RED with no /etc/auros/kiosk.conf on this host (expected off-image)"
if grep -q 'kiosk/no-desktop.*konsole is absent' <<<"$OUT"; then ok "kiosk: konsole absent is a pass"; else no "kiosk: konsole absent is a pass"; fi

mkstubs >/dev/null
unstub gnome-terminal xterm dolphin plasmashell gnome-shell sddm gdm plasma-discover
run_sut "$KIOSK"
expect_line FAIL 'kiosk/no-desktop.*konsole is still on this image' "kiosk goes RED when konsole survived"

echo "── a missing claims file is exit 2, never a silent fall-back to open ───────────────────────"
set +e
OUT="$( AUROS_CLAIMS_FILE="$WORK/does-not-exist" PATH="$WORK/bin:/usr/bin:/bin" \
        WAYLAND_DISPLAY=wayland-0 bash "$SUT" 2>&1 )"
RC=$?
set -e
expect_rc 2 "no claims file => INCONCLUSIVE (exit 2)"
if grep -q "defaulting to" <<<"$OUT"; then ok "and it says why defaulting would be wrong"; else no "and it says why defaulting would be wrong"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

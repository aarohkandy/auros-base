#!/usr/bin/env bash
# ==================================================================================================
# assert-zero-terminal.sh — the implementation of check B12
#
# checks.yaml, B12, verbatim:
#   "from a fresh user session, installing an application, connecting to Wi-Fi, adding a printer and
#    changing the language are each reachable through the GUI, verified by asserting the responsible
#    .desktop entries and GUI components exist and launch"
#
# Installed into the image as /usr/libexec/auros/assert-zero-terminal and run by the VM check harness
# INSIDE the booted machine, as an ordinary unprivileged user, inside their graphical session.
#
# CONTRACT
#   exit 0  every assertion passed                    → B12 pass
#   exit 1  at least one assertion failed             → B12 fail
#   exit 2  could not be evaluated (no session, etc.) → B12 is NOT pass. checks.yaml is explicit that a
#           check that cannot be evaluated mechanically is not a check, and results.schema.json is
#           explicit that skip is not a pass. Never record exit 2 as anything but a failure to test.
#   --json FILE   additionally writes the results.schema.json check object for B12
#   --no-launch   static assertions only; always exits 2 at best, because "exists" is not "launches"
#
# WHY "EXISTS AND LAUNCHES" AND NOT JUST "EXISTS": a .desktop file whose Exec points at a binary that
# a prune step removed still exists. It is a menu entry that does nothing, which to our user is
# indistinguishable from a broken computer, and it is exactly the kind of thing a nightly rebuild
# against a moving upstream produces. So every GUI path here is started and has to survive.
# ==================================================================================================
set -uo pipefail          # NOT -e: a failing assertion must be recorded, not abort the run

LAUNCH=true
JSON_OUT=
while (($#)); do
    case $1 in
        --json) JSON_OUT=${2:?--json needs a path}; shift 2 ;;
        --no-launch) LAUNCH=false; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASSES=0; FAILS=0; NOTES=()
pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; PASSES=$((PASSES+1)); }
fail() { printf 'FAIL  %-26s %s\n' "$1" "$2"; FAILS=$((FAILS+1)); NOTES+=("$1: $2"); }
info() { printf '      %-26s %s\n' "$1" "$2"; }

echo "=== B12 zero-terminal audit — $(date -Is) — user $(id -un) ==="

# ── is this actually a session? ───────────────────────────────────────────────────────────────────
HAVE_SESSION=false
if [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; then HAVE_SESSION=true; fi
if [[ $LAUNCH == true && $HAVE_SESSION == false ]]; then
    echo
    echo "INCONCLUSIVE: no WAYLAND_DISPLAY and no DISPLAY."
    echo "B12 says 'from a fresh user session'. Run this inside the logged-in user's session"
    echo "(the harness can reach it with: systemd-run --user --pipe ... or via the greeter's session)."
    echo "Refusing to report a pass from outside a session."
    exit 2
fi

# ── helpers ───────────────────────────────────────────────────────────────────────────────────────
# A GUI component "launches" if it is still alive after a few seconds. A missing KCM, a missing
# binary, or a plugin that fails to load all make these exit immediately.
LAUNCH_SETTLE=6
launches() { # launches <label> <cmd...>
    local label=$1; shift
    if [[ $LAUNCH != true ]]; then info "$label" "launch not attempted (--no-launch)"; return 0; fi
    # Distinguish "not installed" from "started and died" for whoever reads this at 2am.
    command -v "$1" >/dev/null 2>&1 || { info "$label" "$1 is not installed at all"; return 1; }
    "$@" >/dev/null 2>&1 &
    local pid=$!
    sleep "$LAUNCH_SETTLE"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        return 0
    fi
    wait "$pid" 2>/dev/null
    return 1
}
desktop_entry() { # first readable path for a desktop file id, across XDG_DATA_DIRS + flatpak exports
    local id=$1 d
    for d in ${XDG_DATA_HOME:-$HOME/.local/share} \
             $(printf '%s' "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" | tr ':' ' ') \
             /var/lib/flatpak/exports/share; do
        [[ -r "$d/applications/$id" ]] && { printf '%s' "$d/applications/$id"; return 0; }
    done
    return 1
}
kcm_exists() { kcmshell6 --list 2>/dev/null | grep -qw -- "$1"; }
first_kcm() { local c; for c in "$@"; do kcm_exists "$c" && { printf '%s' "$c"; return 0; }; done; return 1; }
backends() { find /usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover \
                  /usr/lib64/qt5/plugins/discover /usr/lib/qt5/plugins/discover \
                  -name '*-backend.so' 2>/dev/null | xargs -r -n1 basename | sed 's/-backend\.so//' | sort -u; }

# ── 0. the layer is present at all ────────────────────────────────────────────────────────────────
if [[ -r /usr/share/auros/desktop-facts.env ]]; then
    # shellcheck disable=SC1091
    . /usr/share/auros/desktop-facts.env
    pass "layer-present" "desktop layer v${AUROS_DESKTOP_LAYER_VERSION:-?}, welcome=${AUROS_WELCOME_IMPL:-?}"
else
    fail "layer-present" "/usr/share/auros/desktop-facts.env missing — 40-windows-feel.sh did not run"
fi

# ── 1. INSTALL AN APPLICATION ─────────────────────────────────────────────────────────────────────
if e=$(desktop_entry org.kde.discover.desktop); then pass "install-app/entry" "$e"
else fail "install-app/entry" "org.kde.discover.desktop not found in any XDG data dir"; fi

b=$(backends)
if [[ -z $b ]]; then
    fail "install-app/backend" "no Discover backend plugins on disk — the app store cannot install anything"
elif grep -qx 'flatpak' <<<"$b"; then
    stray=$(grep -Ev '^(flatpak|fwupd)$' <<<"$b" || true)
    if [[ -n $stray ]]; then
        fail "install-app/flatpak-only" "backends present that cannot work on an image-based OS: $(tr '\n' ' ' <<<"$stray")"
    else
        pass "install-app/flatpak-only" "backends: $(tr '\n' ' ' <<<"$b")"
    fi
else
    fail "install-app/backend" "flatpak backend absent (found: $(tr '\n' ' ' <<<"$b"))"
fi

if [[ -r /etc/flatpak/remotes.d/flathub.flatpakrepo ]] || \
   flatpak remotes --system 2>/dev/null | grep -q '^flathub'; then
    pass "install-app/flathub" "Flathub configured system-wide"
else
    fail "install-app/flathub" "no Flathub remote — Discover would open on an empty shop"
fi

if launches "install-app/launch" plasma-discover; then pass "install-app/launch" "plasma-discover stayed up ${LAUNCH_SETTLE}s"
else fail "install-app/launch" "plasma-discover exited immediately"; fi

# ── 2. CONNECT TO WI-FI ───────────────────────────────────────────────────────────────────────────
if systemctl is-active --quiet NetworkManager; then pass "wifi/daemon" "NetworkManager active"
else fail "wifi/daemon" "NetworkManager not active — the GUI would have nothing to drive"; fi

applet=$(find /usr/share/plasma/plasmoids -maxdepth 1 -name 'org.kde.plasma.networkmanagement' 2>/dev/null | head -1)
if [[ -n $applet ]]; then
    pass "wifi/applet" "$applet"
else
    fail "wifi/applet" "org.kde.plasma.networkmanagement plasmoid missing — no network icon in the system tray"
fi

if k=$(first_kcm kcm_networkmanagement kcm_networkmanager networkmanagement); then
    pass "wifi/settings-page" "$k"
    if launches "wifi/launch" kcmshell6 "$k"; then pass "wifi/launch" "$k stayed up ${LAUNCH_SETTLE}s"
    else fail "wifi/launch" "$k exited immediately"; fi
else
    fail "wifi/settings-page" "no network KCM in kcmshell6 --list"
fi

# ── 3. ADD A PRINTER ──────────────────────────────────────────────────────────────────────────────
if systemctl is-enabled --quiet cups.socket 2>/dev/null || systemctl is-active --quiet cups 2>/dev/null; then
    pass "printer/daemon" "cups reachable (socket enabled or service active)"
else
    fail "printer/daemon" "cups neither socket-enabled nor running — adding a printer cannot succeed"
fi

PRINTER_OK=false
if k=$(first_kcm kcm_printer_manager printmanager kcm_printmanager); then
    pass "printer/settings-page" "$k"
    if launches "printer/launch" kcmshell6 "$k"; then PRINTER_OK=true; pass "printer/launch" "$k stayed up ${LAUNCH_SETTLE}s"
    else fail "printer/launch" "$k exited immediately"; fi
elif e=$(desktop_entry system-config-printer.desktop); then
    pass "printer/settings-page" "fallback: $e"
    if launches "printer/launch" system-config-printer; then PRINTER_OK=true; pass "printer/launch" "system-config-printer stayed up"
    else fail "printer/launch" "system-config-printer exited immediately"; fi
else
    fail "printer/settings-page" "no printer GUI at all — neither a print KCM nor system-config-printer"
fi
[[ $PRINTER_OK == true ]] || info "printer" "network discovery additionally needs avahi-daemon; see 40-windows-feel.sh §1"

# ── 4. CHANGE THE LANGUAGE ────────────────────────────────────────────────────────────────────────
if k=$(first_kcm kcm_regionandlang kcm_translations kcm_formats regionandlang); then
    pass "language/settings-page" "$k"
    if launches "language/launch" kcmshell6 "$k"; then pass "language/launch" "$k stayed up ${LAUNCH_SETTLE}s"
    else fail "language/launch" "$k exited immediately"; fi
else
    fail "language/settings-page" "no region/language KCM in kcmshell6 --list"
fi

# ── 5. THE WINDOWS SHAPE — not in B12's four tasks, but it is what D4 asked for, and a taskbar that
#       did not materialise is the loudest possible failure of this layer. ─────────────────────────
sc=$(kreadconfig6 --file kdeglobals --group KDE --key SingleClick 2>/dev/null)
if [[ $sc == false ]]; then pass "windows-shape/double-click" "SingleClick=false, as this user reads it"
else fail "windows-shape/double-click" "SingleClick resolves to '${sc:-<unset>}' for this user — single click opens files"; fi

APPLETS="${XDG_DATA_HOME:-$HOME/.local/share}/plasma-org.kde.plasma.desktop-appletsrc"
[[ -r $APPLETS ]] || APPLETS="${XDG_CONFIG_HOME:-$HOME/.config}/plasma-org.kde.plasma.desktop-appletsrc"
if [[ -r $APPLETS ]]; then
    if grep -q 'org.kde.plasma.kickoff' "$APPLETS" && grep -q 'org.kde.plasma.icontasks' "$APPLETS"; then
        pass "windows-shape/taskbar" "start menu and task buttons present in the user's panel"
    else
        fail "windows-shape/taskbar" "panel config exists but has no kickoff/icontasks — the layout script did not apply"
    fi
else
    fail "windows-shape/taskbar" "no panel config for this user — first-run has not completed a graphical login"
fi

for d in Desktop Documents Downloads Pictures; do
    [[ -d "$HOME/$d" ]] && pass "windows-shape/folder" "~/$d" || fail "windows-shape/folder" "~/$d missing"
done
for d in Templates Public; do
    [[ -d "$HOME/$d" ]] && fail "windows-shape/folder" "~/$d exists — not a Windows folder, and nobody asked for it" \
                        || pass "windows-shape/folder" "~/$d correctly absent"
done

# ── 6. THE GUIDED FIRST RUN ───────────────────────────────────────────────────────────────────────
[[ -x /usr/libexec/auros/auros-first-run ]] \
    && pass "first-run/script" "/usr/libexec/auros/auros-first-run" \
    || fail "first-run/script" "missing or not executable"
[[ -L /usr/lib/systemd/user/graphical-session.target.wants/auros-first-run.service ]] \
    && pass "first-run/enabled" "enabled for every user in /usr/lib/systemd/user" \
    || fail "first-run/enabled" "not enabled — a new user gets a bare desktop"
if command -v plasma-welcome >/dev/null 2>&1; then
    [[ -r /usr/share/plasma/plasma-welcome/intro-customization.desktop ]] \
        && pass "first-run/wizard" "plasma-welcome, with the Auros intro page" \
        || fail "first-run/wizard" "plasma-welcome present but our intro customisation is missing"
    n=$(ls /usr/share/plasma/plasma-welcome/extra-pages/*.qml 2>/dev/null | wc -l | tr -d ' ')
    [[ $n -ge 2 ]] && pass "first-run/pages" "$n Auros pages installed" \
                   || fail "first-run/pages" "expected 2 extra pages, found $n"
elif [[ -r /usr/share/auros/orientation.html ]]; then
    pass "first-run/wizard" "fallback orientation page (plasma-welcome absent — degraded, not broken)"
else
    fail "first-run/wizard" "no welcome wizard and no fallback page"
fi
[[ -x /usr/bin/auros-welcome ]] && pass "first-run/reopenable" "Start menu → Help and Getting Started" \
                                || fail "first-run/reopenable" "/usr/bin/auros-welcome missing"

# ── 7. NOTHING WE SHIP OPENS A TERMINAL ───────────────────────────────────────────────────────────
# A GUI entry with Terminal=true drops the user at a console, which is the thing D4 forbids.
t=$(grep -l '^Terminal=true' /usr/share/applications/org.auros.*.desktop 2>/dev/null || true)
[[ -z $t ]] && pass "no-terminal/our-entries" "no Auros .desktop entry opens a terminal" \
            || fail "no-terminal/our-entries" "$t"

# ── verdict ───────────────────────────────────────────────────────────────────────────────────────
echo
echo "=== $PASSES passed, $FAILS failed ==="
STATUS=pass; RC=0
if (( FAILS > 0 )); then STATUS=fail; RC=1; fi
if [[ $LAUNCH != true ]]; then
    echo "NOTE: --no-launch was used. B12 requires that the GUI paths LAUNCH, so this run cannot"
    echo "      establish a pass however many static assertions it satisfied."
    STATUS=fail; RC=2
fi

if [[ -n $JSON_OUT ]]; then
    # Cap the detail: it lands in a ledger a human reads, and twenty failures in one string is not
    # more informative than five plus a count. The full list is on stdout, in the CI run.
    detail="$PASSES passed, $FAILS failed"
    if (( FAILS > 0 )); then
        detail="$detail — $(printf '%s; ' "${NOTES[@]:0:5}")"
        (( FAILS > 5 )) && detail="$detail and $((FAILS - 5)) more (full list in the run log)"
    fi
    printf '{"id":"B12","status":"%s","detail":%s}\n' \
        "$STATUS" "$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" > "$JSON_OUT"
    echo "wrote $JSON_OUT"
fi
exit $RC

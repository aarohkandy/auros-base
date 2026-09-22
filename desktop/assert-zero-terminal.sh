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
#   --mode M      evaluate against policy mode M instead of the one the image is stamped with.
#                 For testing this script, and for asserting that an image is NOT some other mode.
#
# WHY "EXISTS AND LAUNCHES" AND NOT JUST "EXISTS": a .desktop file whose Exec points at a binary that
# a prune step removed still exists. It is a menu entry that does nothing, which to our user is
# indistinguishable from a broken computer, and it is exactly the kind of thing a nightly rebuild
# against a moving upstream produces. So every GUI path here is started and has to survive.
#
# ── B12 IS EVALUATED AGAINST THE MODE'S OWN CLAIMS, NOT AGAINST `open`'s ──────────────────────────
#
# B12's four tasks are written in checks.yaml against what an `open` image does, because the base is
# an open image. Three of the four policy modes deliberately do something else:
#
#   locked  00-auros-locked.rules denies the whole org.freedesktop.NetworkManager.,
#           org.freedesktop.Flatpak., org.freedesktop.packagekit. and org.freedesktop.locale1.
#           prefixes, and 20-control-module-restrictions.ini sets kcm_networkmanagement=false and
#           kcm_regionandlang=false. Three of B12's four tasks are unreachable BY CONSTRUCTION, and
#           locked/description.md tells the customer so.
#   kiosk   there is no desktop and no session at all.
#   managed everything is reachable, but the machine asks for the IT password first. A password is
#           not a terminal, so managed passes on all four.
#
# Evaluated against `open`'s list, a locked image fails B12 for doing exactly what was ordered and a
# kiosk image fails it twice over — which means the publish gate silently makes `open` the only
# shippable mode, and the subtraction product has no path to a customer. A recipe that cannot be
# published is worse than one that fails.
#
# So each mode declares its criteria in policy/<mode>/mode.env, apply-policy writes the active
# mode's declaration to /usr/lib/auros/policy/claims.env, and this script reads that file. The
# vocabulary is:
#
#   seat   the GUI offers it and any user at the machine can complete it. Asserted as today:
#          the entry/KCM exists AND launches.
#   admin  the GUI offers it and asks for the administrator password. Asserted identically — D4
#          forbids needing a command line, not needing a credential.
#   none   the mode deliberately removes it from the seat. Asserted as the OPPOSITE: the GUI must
#          NOT offer it. This is a check that can genuinely go red, in both directions — it fails if
#          the restriction leaks and the machine offers a door it will then slam, and it fails if
#          the restriction quietly stops being applied. It is also the only runtime check that would
#          notice build/40-windows-feel.sh overwriting /etc/xdg/kdeglobals after apply-policy merged
#          the KDE Control Module Restrictions into it, which is an ordering hazard 20-policy.sh
#          warns about at build time and nothing else observes at run time.
#   n/a    there is no desktop session on this machine (kiosk). The four tasks are not claimed; the
#          kiosk criterion is asserted instead.
#
# A mode whose claims file is missing or unreadable is NOT silently treated as `open`. It exits 2.
# ==================================================================================================
set -uo pipefail          # NOT -e: a failing assertion must be recorded, not abort the run

LAUNCH=true
JSON_OUT=
MODE_OVERRIDE=
CLAIMS_FILE=${AUROS_CLAIMS_FILE:-/usr/lib/auros/policy/claims.env}
while (($#)); do
    case $1 in
        --json) JSON_OUT=${2:?--json needs a path}; shift 2 ;;
        --no-launch) LAUNCH=false; shift ;;
        --mode) MODE_OVERRIDE=${2:?--mode needs a mode name}; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PASSES=0; FAILS=0; NOTES=()
pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; PASSES=$((PASSES+1)); }
fail() { printf 'FAIL  %-26s %s\n' "$1" "$2"; FAILS=$((FAILS+1)); NOTES+=("$1: $2"); }
info() { printf '      %-26s %s\n' "$1" "$2"; }

echo "=== B12 zero-terminal audit — $(date -Is) — user $(id -un) ==="

# ── which mode's promises are we auditing? ────────────────────────────────────────────────────────
# Loaded FIRST, because it decides what every assertion below means. An unreadable claims file is an
# exit 2 and never a fall-back to `open`: silently auditing a locked image against open's list is
# how three modes ended up unpublishable, and silently auditing an open image against locked's list
# would be worse — it would report a pass for a machine that offers none of what we sold.
AUROS_MODE=
AUROS_MODE_B1=
AUROS_MODE_B12_INSTALL_APP=
AUROS_MODE_B12_WIFI=
AUROS_MODE_B12_PRINTER=
AUROS_MODE_B12_LANGUAGE=
AUROS_MODE_B12_DESKTOP=
AUROS_MODE_B12_USERS=
if [[ -r $CLAIMS_FILE ]]; then
    # shellcheck disable=SC1090
    . "$CLAIMS_FILE"
elif [[ -n $MODE_OVERRIDE ]]; then
    : # --mode supplies everything below
else
    echo
    echo "INCONCLUSIVE: $CLAIMS_FILE is missing or unreadable."
    echo "apply-policy writes it from policy/<mode>/mode.env at image build time. Without it there is"
    echo "no way to know which mode's promises B12 is supposed to be auditing, and defaulting to"
    echo "'open' would silently fail every locked and kiosk image for doing what was ordered."
    exit 2
fi

if [[ -n $MODE_OVERRIDE ]]; then
    ov=/usr/share/auros/policy/$MODE_OVERRIDE/mode.env
    [[ -r ${AUROS_MODE_ENV_DIR:-}/$MODE_OVERRIDE/mode.env ]] && ov=${AUROS_MODE_ENV_DIR}/$MODE_OVERRIDE/mode.env
    if [[ -r $ov ]]; then
        # shellcheck disable=SC1090
        . "$ov"
        AUROS_MODE=$MODE_OVERRIDE
    else
        echo "--mode $MODE_OVERRIDE: no mode.env at $ov" >&2; exit 2
    fi
fi

: "${AUROS_MODE:=open}"
: "${AUROS_MODE_B1:=login-prompt}"
: "${AUROS_MODE_B12_DESKTOP:=yes}"
for v in AUROS_MODE_B12_INSTALL_APP AUROS_MODE_B12_WIFI AUROS_MODE_B12_PRINTER AUROS_MODE_B12_LANGUAGE; do
    if [[ -z ${!v} ]]; then
        echo "INCONCLUSIVE: $v is not declared for mode '$AUROS_MODE'." >&2
        echo "Every mode must say what it claims for each of B12's four tasks. An undeclared task is" >&2
        echo "a task nobody decided about, and guessing would be how a promise gets made by accident." >&2
        exit 2
    fi
    case ${!v} in
        seat|admin|none|n/a) ;;
        *) echo "INCONCLUSIVE: $v='${!v}' is not one of seat|admin|none|n/a" >&2; exit 2 ;;
    esac
done
case $AUROS_MODE_B12_USERS in
    seat|aurosadmin|own-password|n/a) ;;
    *) echo "INCONCLUSIVE: AUROS_MODE_B12_USERS='$AUROS_MODE_B12_USERS' is not one of seat|aurosadmin|own-password|n/a (who may open the Users page)" >&2; exit 2 ;;
esac

echo "mode: $AUROS_MODE   B1=$AUROS_MODE_B1   desktop=$AUROS_MODE_B12_DESKTOP"
echo "B12 claims: install-app=$AUROS_MODE_B12_INSTALL_APP wifi=$AUROS_MODE_B12_WIFI printer=$AUROS_MODE_B12_PRINTER language=$AUROS_MODE_B12_LANGUAGE users=$AUROS_MODE_B12_USERS"
echo

# ── is this actually a session? ───────────────────────────────────────────────────────────────────
# A mode that declares it has no desktop is exempt, and only that mode: everything else still has to
# be audited from inside a real user session or it is not audited at all.
HAVE_SESSION=false
if [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; then HAVE_SESSION=true; fi
if [[ $AUROS_MODE_B12_DESKTOP == yes && $LAUNCH == true && $HAVE_SESSION == false ]]; then
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
# Overridable only so that desktop/tests/b12-modes.test.sh can drive this script against stubs
# without waiting six seconds per GUI component. Nothing in the image sets it.
LAUNCH_SETTLE=${AUROS_LAUNCH_SETTLE:-6}
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
# Here-string, not `kcmshell6 --list | grep -q`: under pipefail grep -q's early exit SIGPIPEs the
# (long) listing and a present KCM reads as absent — in a `none` mode that is a false PASS.
kcm_exists() { grep -qw -- "$1" <<<"$(kcmshell6 --list 2>/dev/null)"; }
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

# ── how a task is judged against what the mode claims ─────────────────────────────────────────────
#
# One helper, used by all four tasks, so that `seat`, `admin` and `none` are three answers from the
# SAME attempt rather than three code paths that drift. `none` is not "skip"; it is the opposite
# assertion, and it is what lets a locked image record a real B12 pass instead of being unpublishable.
#
# For `none` the criterion is deliberately the mechanism the mode actually uses, because that is the
# thing that can regress:
#   * the KDE Control Module must refuse to open  (KDE Kiosk, the fragile half — build/40-windows-
#     feel.sh rewrites /etc/xdg/kdeglobals after apply-policy merged the restrictions into it, and
#     nothing else at run time would notice)
#   * pkcheck must answer 1, refused outright     (polkit, the durable half)
# Either one coming back permissive is a red, and the message says which.
#
# pkcheck here is a stronger subject than the one B5 uses: assert-zero-terminal runs as a real seat
# user inside a real graphical session, so an answer of 1 cannot be "the probe had no session".

pk() { pkcheck --action-id "$1" --process "$$" >/dev/null 2>&1; echo $?; }

pk_refused() {  # pk_refused <label> <action> — for `none`: 1 and only 1
    local label=$1 action=$2 rc; rc=$(pk "$action")
    case $rc in
        1) pass "$label" "$action — refused outright (pkcheck 1) for this seat user in an active session" ;;
        0) fail "$label" "$action — AUTHORISED (pkcheck 0) for an ordinary seat user. Mode '$AUROS_MODE' tells the customer this cannot be done at the machine." ;;
        2|3) fail "$label" "$action — answerable with an administrator password (pkcheck $rc). That is 'managed' behaviour; mode '$AUROS_MODE' promises a refusal that no password changes." ;;
        *) fail "$label" "$action — pkcheck returned $rc (error). An error is not a refusal." ;;
    esac
}

pk_answerable() {  # pk_answerable <label> <action> — for `seat`/`admin`: anything but a hard refusal
    local label=$1 action=$2 rc; rc=$(pk "$action")
    case $rc in
        0) pass "$label" "$action — permitted for this seat user (pkcheck 0)" ;;
        2|3) pass "$label" "$action — offered, and asks for the administrator password (pkcheck $rc). A password is not a terminal." ;;
        1) fail "$label" "$action — refused outright (pkcheck 1), but mode '$AUROS_MODE' claims this task is reachable. The GUI would offer a door it then slams." ;;
        *) fail "$label" "$action — pkcheck returned $rc (error)." ;;
    esac
}

pk_not_granted() {  # pk_not_granted <label> <action> — a pupil: refused, or only with an administrator's password
    local label=$1 action=$2 rc; rc=$(pk "$action")
    case $rc in
        1|2|3) pass "$label" "$action — not granted to this user (pkcheck $rc)" ;;
        0) fail "$label" "$action — AUTHORISED (pkcheck 0) for a user outside aurosadmin. Mode '$AUROS_MODE' promises only the IT account manages accounts." ;;
        *) fail "$label" "$action — pkcheck returned $rc (error). An error is not a refusal." ;;
    esac
}

reach() {  # reach <claim> <label> <what> -- <launch cmd...>
    local claim=$1 label=$2 what=$3; shift 3; [[ ${1:-} == -- ]] && shift
    if [[ $claim == n/a ]]; then info "$label" "not claimed by mode '$AUROS_MODE'"; return; fi
    if [[ $LAUNCH != true ]]; then info "$label" "launch not attempted (--no-launch); this run cannot establish B12 either way"; return; fi
    local up=false
    launches "$label" "$@" && up=true
    case $claim in
        seat|admin)
            if $up; then pass "$label" "$what stayed up ${LAUNCH_SETTLE}s — reachable from the GUI, no terminal"
            else fail "$label" "$what did not stay up, but mode '$AUROS_MODE' claims this task is reachable from the GUI"; fi ;;
        none)
            if $up; then fail "$label" "$what OPENED AND STAYED UP. Mode '$AUROS_MODE' tells the customer this is switched off at the seat, so the restriction is not in force. The usual cause is /etc/xdg/kdeglobals having been replaced as a whole file after apply-policy merged [KDE Control Module Restrictions] into it — build/40-windows-feel.sh runs after build/20-policy.sh."
            else pass "$label" "$what refused to open, as mode '$AUROS_MODE' promises"; fi ;;
    esac
}

# ── 1. INSTALL AN APPLICATION ─────────────────────────────────────────────────────────────────────
C=$AUROS_MODE_B12_INSTALL_APP
if [[ $C == none ]]; then
    # locked: Discover may still be on the image; what must be true is that a student at the seat
    # cannot complete an install, and cannot be pushed toward a terminal to do it either.
    pk_refused "install-app/polkit-flatpak"    org.freedesktop.Flatpak.app-install
    pk_refused "install-app/polkit-packagekit" org.freedesktop.packagekit.package-install
    info "install-app/claim" "mode '$AUROS_MODE' does not offer installing software at the seat (locked/description.md says so in the same words)"
elif [[ $C == n/a ]]; then
    info "install-app" "no desktop on this machine (mode $AUROS_MODE)"
else
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
       grep -q '^flathub' <<<"$(flatpak remotes --system 2>/dev/null)"; then
        pass "install-app/flathub" "Flathub configured system-wide"
    else
        fail "install-app/flathub" "no Flathub remote — Discover would open on an empty shop"
    fi

    reach "$C" "install-app/launch" "plasma-discover" -- plasma-discover
    [[ $C == admin ]] && pk_answerable "install-app/polkit" org.freedesktop.Flatpak.app-install
fi

# ── 2. CONNECT TO WI-FI ───────────────────────────────────────────────────────────────────────────
# The DAEMON floor is asserted in every mode including `none`. A locked machine that cannot join a
# new network must still be ON the network it was given, or it stops updating and we have sold a
# school the abandoned laptop we sell against.
if systemctl is-active --quiet NetworkManager; then pass "wifi/daemon" "NetworkManager active"
else fail "wifi/daemon" "NetworkManager not active — the machine has no network at all"; fi

C=$AUROS_MODE_B12_WIFI
if [[ $C == none ]]; then
    pk_refused "wifi/polkit" org.freedesktop.NetworkManager.settings.modify.system
    if k=$(first_kcm kcm_networkmanagement kcm_networkmanager networkmanagement); then
        # The module is still listed. That is not automatically wrong — kcmshell6's listing is not
        # the enforcement — so we attempt to OPEN it, which is.
        reach "$C" "wifi/settings-page" "$k" -- kcmshell6 "$k"
    else
        pass "wifi/settings-page" "no network KCM is offered to this user, as mode '$AUROS_MODE' promises"
    fi
elif [[ $C == n/a ]]; then
    info "wifi" "no desktop on this machine (mode $AUROS_MODE)"
else
    applet=$(find /usr/share/plasma/plasmoids -maxdepth 1 -name 'org.kde.plasma.networkmanagement' 2>/dev/null | head -1)
    if [[ -n $applet ]]; then
        pass "wifi/applet" "$applet"
    else
        fail "wifi/applet" "org.kde.plasma.networkmanagement plasmoid missing — no network icon in the system tray"
    fi

    if k=$(first_kcm kcm_networkmanagement kcm_networkmanager networkmanagement); then
        pass "wifi/settings-page" "$k"
        reach "$C" "wifi/launch" "$k" -- kcmshell6 "$k"
    else
        fail "wifi/settings-page" "no network KCM in kcmshell6 --list"
    fi
    [[ $C == admin ]] && pk_answerable "wifi/polkit" org.freedesktop.NetworkManager.settings.modify.system
fi

# ── 3. ADD A PRINTER ──────────────────────────────────────────────────────────────────────────────
C=$AUROS_MODE_B12_PRINTER
if [[ $C == n/a ]]; then
    info "printer" "no desktop on this machine (mode $AUROS_MODE)"
else
    if systemctl is-enabled --quiet cups.socket 2>/dev/null || systemctl is-active --quiet cups 2>/dev/null; then
        pass "printer/daemon" "cups reachable (socket enabled or service active)"
    else
        fail "printer/daemon" "cups neither socket-enabled nor running — adding a printer cannot succeed"
    fi

    if [[ $C == none ]]; then
        info "printer/claim" "mode '$AUROS_MODE' does not offer adding a printer at the seat"
        if k=$(first_kcm kcm_printer_manager printmanager kcm_printmanager); then
            reach "$C" "printer/settings-page" "$k" -- kcmshell6 "$k"
        else
            pass "printer/settings-page" "no printer KCM is offered to this user, as mode '$AUROS_MODE' promises"
        fi
    else
        if k=$(first_kcm kcm_printer_manager printmanager kcm_printmanager); then
            pass "printer/settings-page" "$k"
            reach "$C" "printer/launch" "$k" -- kcmshell6 "$k"
        elif e=$(desktop_entry system-config-printer.desktop); then
            pass "printer/settings-page" "fallback: $e"
            reach "$C" "printer/launch" "system-config-printer" -- system-config-printer
        else
            fail "printer/settings-page" "no printer GUI at all — neither a print KCM nor system-config-printer"
        fi
    fi
    # Reported every run, pass or fail. B12 asks whether adding a printer is reachable from the GUI, and it
    # is without mDNS (USB, and printer-by-IP-address) — so this is an observation, not an assertion. It is
    # printed because 10-hardening.sh opened the mdns firewall port for exactly this and nothing listens on
    # it. desktop/README.md GAP-3.
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        info "printer/discovery" "avahi-daemon running — network printers are discovered automatically"
    else
        info "printer/discovery" "avahi-daemon NOT running: USB and printer-by-IP work, mDNS auto-discovery does not (README GAP-3, owner: hardening layer)"
    fi
fi

# ── 4. CHANGE THE LANGUAGE ────────────────────────────────────────────────────────────────────────
C=$AUROS_MODE_B12_LANGUAGE
if [[ $C == none ]]; then
    pk_refused "language/polkit" org.freedesktop.locale1.set-locale
    if k=$(first_kcm kcm_regionandlang kcm_translations kcm_formats regionandlang); then
        reach "$C" "language/settings-page" "$k" -- kcmshell6 "$k"
    else
        pass "language/settings-page" "no region/language KCM is offered to this user, as mode '$AUROS_MODE' promises"
    fi
    # B4 still asserts that the machine BOOTS in the recipe's declared language. `none` means the
    # student cannot change it, not that the school did not get the language they ordered.
    info "language/claim" "mode '$AUROS_MODE' fixes the language in the recipe; check B4 asserts the machine boots in it"
elif [[ $C == n/a ]]; then
    info "language" "no desktop on this machine (mode $AUROS_MODE)"
else
    if k=$(first_kcm kcm_regionandlang kcm_translations kcm_formats regionandlang); then
        pass "language/settings-page" "$k"
        reach "$C" "language/launch" "$k" -- kcmshell6 "$k"
    else
        fail "language/settings-page" "no region/language KCM in kcmshell6 --list"
    fi
    [[ $C == admin ]] && pk_answerable "language/polkit" org.freedesktop.locale1.set-locale
fi

# ── 4b. MANAGE USER ACCOUNTS (owner decision A4, control repo docs/ACCOUNTS.md §3) ────────────────
# Not one of checks.yaml's four tasks. `aurosadmin` means: the Users page opens for an aurosadmin
# member and for nobody else, and polkit refuses everyone else. The matrix session's user is one or the
# other, so one run proves one half; desktop/tests/b12-modes.test.sh drives both.
# `own-password` (locked, owner decision in ACCOUNTS.md §5): the Users page opens for EVERYONE, so a
# pupil can choose their own password there; polkit grants a pupil exactly that (pkcheck 0 for
# change-own-password in this real session) and refuses managing accounts outright (1). The IT account
# still manages accounts, with its password.
C=$AUROS_MODE_B12_USERS
UA=org.freedesktop.accounts.user-administration
OWNPW=org.freedesktop.accounts.change-own-password
own_password_granted() {
    local rc; rc=$(pk "$OWNPW")
    if [[ $rc == 0 ]]; then pass "users/own-password" "$OWNPW — granted to $(id -un) in this session (pkcheck 0): they can choose their own password"
    else fail "users/own-password" "$OWNPW — pkcheck $rc for $(id -un) in this session: they cannot choose their own password without IT (policy/common 10-auros-own-password.rules not in force)"; fi
}
if [[ $C == own-password ]]; then
    if kcm_exists kcm_users; then reach seat "users/settings-page" kcm_users -- kcmshell6 kcm_users
    else fail "users/settings-page" "no kcm_users in kcmshell6 --list: nobody here can choose their own password in the GUI"; fi
    own_password_granted
    if [[ " $(id -nG 2>/dev/null) " == *" aurosadmin "* ]]; then pk_answerable "users/polkit" "$UA"
    else pk_refused "users/polkit" "$UA"; fi
elif [[ $C == aurosadmin ]] && [[ " $(id -nG 2>/dev/null) " != *" aurosadmin "* ]]; then
    if kcm_exists kcm_users; then reach none "users/settings-page" kcm_users -- kcmshell6 kcm_users
    else pass "users/settings-page" "no Users page is offered to $(id -un), who is not in aurosadmin"; fi
    pk_not_granted "users/polkit" "$UA"
elif [[ $C == seat || $C == aurosadmin ]]; then
    if kcm_exists kcm_users; then reach admin "users/settings-page" kcm_users -- kcmshell6 kcm_users
    else fail "users/settings-page" "no kcm_users in kcmshell6 --list: the account that should manage passwords has no page to do it"; fi
    pk_answerable "users/polkit" "$UA"
else
    info "users" "no desktop on this machine (mode $AUROS_MODE)"
fi

# ── THE KIOSK CRITERION — what B12 means on a machine with no desktop ─────────────────────────────
#
# Everything from here down assumes there is a desktop to audit. Kiosk has none, by design, and
# checks.yaml's B12 is unsatisfiable on it as written. The equivalent property — the one that
# actually delivers D4's "never requires a terminal" on an appliance — is that the application the
# machine exists to run is up, and that there is no GUI path to anything else because none exists.
#
# This branch can go red: it fails if the kiosk service is not running, if no application is
# configured, or if a desktop shell, a display manager or a terminal emulator survived the removal
# pass. It is not a skip.
if [[ $AUROS_MODE_B12_DESKTOP != yes ]]; then
    if systemctl is-active --quiet auros-kiosk.service; then
        pass "kiosk/service" "auros-kiosk.service is active"
    else
        fail "kiosk/service" "auros-kiosk.service is $(systemctl is-active auros-kiosk.service 2>&1 || true) — the machine has no desktop AND no application"
    fi
    if [[ -r /etc/auros/kiosk.conf ]] && grep -q '^KIOSK_EXEC=".\+"' /etc/auros/kiosk.conf; then
        pass "kiosk/configured" "an application is configured in /etc/auros/kiosk.conf"
    else
        fail "kiosk/configured" "/etc/auros/kiosk.conf names no application — a kiosk with no application is a brick that passes every check which only looks at what was deleted"
    fi
    for bin in plasmashell gnome-shell sddm gdm konsole gnome-terminal xterm dolphin plasma-discover; do
        if command -v "$bin" >/dev/null 2>&1; then
            fail "kiosk/no-desktop" "$bin is still on this image — there is a GUI path off the application"
        else
            pass "kiosk/no-desktop" "$bin is absent"
        fi
    done
    info "kiosk/scope" "B12's four tasks are not claimed on this mode (policy/kiosk/mode.env declares them n/a). policy/kiosk/assert.sh is the mode's own proof; this is B12's half of it."
    echo
    echo "=== $PASSES passed, $FAILS failed ==="
    STATUS=pass; RC=0
    (( FAILS > 0 )) && { STATUS=fail; RC=1; }
    if [[ -n $JSON_OUT ]]; then
        detail="$PASSES passed, $FAILS failed (mode=$AUROS_MODE, kiosk criterion)"
        (( FAILS > 0 )) && detail="$detail — $(printf '%s; ' "${NOTES[@]:0:5}")"
        printf '{"id":"B12","status":"%s","detail":%s}\n' \
            "$STATUS" "$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" > "$JSON_OUT"
        echo "wrote $JSON_OUT"
    fi
    exit $RC
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
echo "=== $PASSES passed, $FAILS failed  (mode=$AUROS_MODE) ==="
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
    detail="$PASSES passed, $FAILS failed (mode=$AUROS_MODE)"
    if (( FAILS > 0 )); then
        detail="$detail — $(printf '%s; ' "${NOTES[@]:0:5}")"
        (( FAILS > 5 )) && detail="$detail and $((FAILS - 5)) more (full list in the run log)"
    fi
    printf '{"id":"B12","status":"%s","detail":%s}\n' \
        "$STATUS" "$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" > "$JSON_OUT"
    echo "wrote $JSON_OUT"
fi
exit $RC

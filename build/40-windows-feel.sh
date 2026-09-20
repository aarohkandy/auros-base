#!/usr/bin/env bash
# ==================================================================================================
# 40-windows-feel.sh — the Windows-familiarity layer  (TASKS.md A10, DECISIONS.md D4)
#
# D4 is a binding human directive, quoted in full in DECISIONS.md.  Its short form: "make it feel like
# personalized windows rather than linux rn which needs you to memorize books of commands".
#
# The user this layer is for is a 62-year-old school administrator or a 9-year-old, on a 2013 laptop,
# who has never seen Linux and is not going to learn.  Every decision below is made for them, and the
# reasoning is written down next to it rather than in a commit message nobody will find.
#
# THE ORGANISING RULE: a setting a user has to find is a setting that is not set.  Everything here is
# applied system-wide, in the image, before the machine is ever switched on.
#
# Run by auros-base/Containerfile, in numeric order, inside the image build.  Its inputs live in
# auros-base/desktop/ and are COPYed to /tmp/auros-build/desktop/ before the scripts run.
# Idempotent: safe to run twice, and safe to run against an image where a previous version ran.
# ==================================================================================================
set -euo pipefail

SRC=/tmp/auros-build/desktop
FACTS=/usr/share/auros/desktop-facts.env
DOCDIR=/usr/share/doc/auros
# Pinned in desktop/flatpak/PROVENANCE.md.  If the committed file is edited, this build fails.
FLATHUB_SHA256=3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a

say() { printf '  %s\n' "$*"; }
step() { printf '\n[40-windows-feel] %s\n' "$*"; }

step "starting"
if [[ ! -d $SRC ]]; then
    echo "FATAL: $SRC does not exist." >&2
    echo "  The convention is that auros-base/desktop/ is COPYed to /tmp/auros-build/desktop/ before" >&2
    echo "  build/*.sh run.  Either the Containerfile's COPY is missing or it lands somewhere else." >&2
    exit 1
fi

# ── package manager ───────────────────────────────────────────────────────────────────────────────
if command -v dnf5 >/dev/null 2>&1; then PKG=dnf5
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
else echo "FATAL: neither dnf5 nor dnf is available in this image." >&2; exit 1; fi
say "package manager: $PKG"

# install_weak_deps=False everywhere.  Weak dependencies are how PackageKit and friends come back in
# through the side door two steps after we have deleted them; check S3 would catch it on the next
# nightly, but catching it here is cheaper than a red matrix at 3am.
pkg_install() {
    local want=() p
    for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || want+=("$p"); done
    if ((${#want[@]})); then
        say "installing: ${want[*]}"
        $PKG install -y --setopt=install_weak_deps=False "${want[@]}"
    else
        say "already present: $*"
    fi
}
# dnf4 spells it --noautoremove and dnf5 spells it --no-autoremove. Probe once rather than guess:
# guessing wrong makes the removal step fail the whole base build on an option name.
RMFLAGS=()
if $PKG remove --help 2>&1 | grep -q -- '--no-autoremove'; then RMFLAGS=(--no-autoremove)
elif $PKG remove --help 2>&1 | grep -q -- '--noautoremove'; then RMFLAGS=(--noautoremove)
else say "note: $PKG has neither --noautoremove nor --no-autoremove; removing without it"; fi

pkg_remove_if_present() {
    local have=() p
    for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 && have+=("$p"); done
    if ((${#have[@]})); then
        say "removing: ${have[*]}"
        $PKG remove -y "${RMFLAGS[@]}" "${have[@]}"
    else
        say "not installed, nothing to remove: $*"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 1. THE PIECES A ZERO-TERMINAL DESKTOP NEEDS
#
# Check B12 audits four tasks: install an application, connect to Wi-Fi, add a printer, change the
# language — each reachable through the GUI.  Those four are not abstractions; each is one package
# being present.  We install them explicitly rather than trusting the base to keep carrying them,
# because the base is rebuilt nightly by people who owe us nothing (D9 is the precedent: greenboot was
# assumed present and was not).
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "1. installing the GUI paths B12 audits"
pkg_install \
    plasma-discover \
    plasma-discover-flatpak \
    plasma-nm \
    plasma-print-manager \
    cups \
    xdg-user-dirs \
    xdg-user-dirs-gtk \
    flatpak \
    libnotify

# plasma-welcome is the first-run wizard (section 5).  Installed separately because, unlike the four
# above, the product still works without it — so an upstream that stops carrying it should degrade the
# welcome experience, not fail the whole base build.
WELCOME_IMPL=fallback-html
if rpm -q plasma-welcome >/dev/null 2>&1 || \
   $PKG install -y --setopt=install_weak_deps=False plasma-welcome; then
    WELCOME_IMPL=plasma-welcome
    say "welcome wizard: plasma-welcome"
else
    say "welcome wizard: plasma-welcome UNAVAILABLE — falling back to the static orientation page"
fi

# Printing: socket-activated, so the daemon is not running on a machine that never prints.
systemctl enable cups.socket >/dev/null 2>&1 && say "enabled cups.socket" || say "could not enable cups.socket"
# NOTE FOR THE POLICY/HARDENING LAYER, not decided here: discovering a network printer over mDNS needs
# avahi-daemon.  That is a network-facing daemon on every machine in a school, so whether it is enabled
# is a hardening decision and not this layer's to make.  Without it, USB and IPP-by-address printers
# work from the GUI and network auto-discovery does not.

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 2. DISCOVER: FLATPAK BACKEND ONLY
#
# On an image-based OS, "install this rpm" is a path that cannot work.  Leaving the PackageKit or
# rpm-ostree backend in Discover means a user is OFFERED that path, follows it, and either fails or
# succeeds — and succeeding is worse, because a machine with layered packages has quietly stopped being
# the image we test, sign and rebuild every night (spec §3).
#
# The fwupd backend stays.  Firmware updates are not packages, they work fine on an image-based system,
# and on 2012-2018 hardware they are occasionally the difference between a working trackpad and a
# support call.
#
# What this costs, stated plainly: Discover no longer has a "check for system updates" button.  OS
# updates on Auros are automatic and unattended (the update agent, A4), so there is nothing for a user
# to press — but "is my computer up to date?" is a real question and the orientation page answers it.
# If A4 ships a GUI status entry, the welcome page should link it.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "2. making Discover Flatpak-only"
pkg_remove_if_present \
    plasma-discover-packagekit \
    plasma-discover-rpm-ostree \
    plasma-discover-snap \
    PackageKit \
    PackageKit-command-not-found \
    gnome-software

# The removals above must not have taken Discover with them.  A base with no app store is a base that
# fails B12 and D4 at once, and it would otherwise be discovered by a customer rather than by us.
rpm -q plasma-discover >/dev/null 2>&1 || {
    echo "FATAL: removing the non-Flatpak backends also removed plasma-discover." >&2
    echo "  Discover is the only GUI path to installing an application (check B12)." >&2
    exit 1
}
rpm -q plasma-discover-flatpak >/dev/null 2>&1 || {
    echo "FATAL: plasma-discover-flatpak is not installed. Discover would have no usable backend." >&2
    exit 1
}

# Filesystem-level assertion, in the spirit of check S9: the question is not what the package database
# believes, it is which plugins exist on disk.  A backend .so that survives here would be loaded.
stray=$(find /usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover \
             /usr/lib64/qt5/plugins/discover /usr/lib/qt5/plugins/discover \
             -name '*-backend.so' 2>/dev/null \
        | grep -Ev '/(flatpak|fwupd)-backend\.so$' || true)
if [[ -n $stray ]]; then
    echo "FATAL: non-Flatpak Discover backends still on disk:" >&2
    printf '  %s\n' $stray >&2
    exit 1
fi
say "discover backends on disk: $(find /usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover -name '*-backend.so' 2>/dev/null | xargs -r -n1 basename | sort | tr '\n' ' ')"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 3. FLATHUB, CONFIGURED IN THE IMAGE
#
# `flatpak remote-add` at build time would write to /var/lib/flatpak, and /var is machine-local state
# that an OCI image does not carry — the remote would simply not exist on the installed machine.  The
# mechanism that does work is flatpak-remote(5)'s static preconfiguration directory.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "3. configuring Flathub system-wide"
actual=$(sha256sum "$SRC/flatpak/flathub.flatpakrepo" | awk '{print $1}')
if [[ $actual != "$FLATHUB_SHA256" ]]; then
    echo "FATAL: desktop/flatpak/flathub.flatpakrepo does not match its pinned hash." >&2
    echo "  expected $FLATHUB_SHA256" >&2
    echo "  actual   $actual" >&2
    echo "  This file carries the GPG key that verifies every application a customer ever installs." >&2
    echo "  If Flathub rotated its key, update the file AND both hashes in a reviewed commit." >&2
    exit 1
fi
install -D -m 0644 "$SRC/flatpak/flathub.flatpakrepo" /etc/flatpak/remotes.d/flathub.flatpakrepo
say "installed /etc/flatpak/remotes.d/flathub.flatpakrepo (sha256 verified)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 4. WINDOWS-SHAPED BY DEFAULT
#
# KConfig cascades from $XDG_CONFIG_DIRS (/etc/xdg) into every user's session, including users that
# already exist, and keeps tracking the image as the image is rebuilt.  /etc/skel does not: it is a
# snapshot taken when the account was created.  So /etc/xdg is the mechanism and /etc/skel is the
# exception, used only where cascading is unreliable.  Each file says which it is and why.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "4. installing Windows-shaped defaults"
for f in kdeglobals kwinrc kcminputrc plasmarc dolphinrc ksmserverrc kglobalshortcutsrc; do
    install -D -m 0644 "$SRC/xdg/$f" "/etc/xdg/$f"
    say "/etc/xdg/$f"
done
install -D -m 0644 "$SRC/xdg/user-dirs.defaults" /etc/xdg/user-dirs.defaults
install -D -m 0644 "$SRC/xdg/user-dirs.conf"     /etc/xdg/user-dirs.conf
say "/etc/xdg/user-dirs.defaults  (Desktop, Documents, Downloads, Music, Pictures, Videos — and no Templates or Public)"
install -D -m 0755 "$SRC/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh" \
    /etc/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh
say "/etc/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh"

# Double-click is the single most-felt setting in this file, so it gets its own assertion rather than
# being trusted to a loop that copied seven files.
grep -qx 'SingleClick=false' /etc/xdg/kdeglobals || {
    echo "FATAL: SingleClick=false is not in /etc/xdg/kdeglobals." >&2
    echo "  KDE opens files on a single click; every person coming off Windows double-clicks." >&2
    exit 1
}
say "double-click to open: set (kdeglobals [KDE] SingleClick=false)"

# The look-and-feel package: appearance defaults plus the layout script that builds the taskbar.
find "$SRC/lookandfeel" -type f | while read -r f; do
    install -D -m 0644 "$f" "/usr/share/plasma/look-and-feel/${f#"$SRC/lookandfeel/"}"
done
say "/usr/share/plasma/look-and-feel/org.auros.windows.desktop/ (layout + defaults)"

# /etc/skel — only the two things that genuinely belong there.
install -D -m 0644 "$SRC/xdg/kglobalshortcutsrc" /etc/skel/.config/kglobalshortcutsrc
install -D -m 0755 "$SRC/welcome/org.auros.Welcome.desktop" /etc/skel/Desktop/org.auros.Welcome.desktop
say "/etc/skel/.config/kglobalshortcutsrc  (kglobalaccel does not reliably read cascaded defaults)"
say "/etc/skel/Desktop/org.auros.Welcome.desktop  (executable, so Plasma opens it without a trust prompt)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 5. FIRST BOOT IS A GUIDED SETUP
#
# We use KDE's own plasma-welcome rather than writing a wizard.  It already covers language, network and
# finding applications, it is translated far beyond anything we could manage, and it is maintained by
# the people who maintain the desktop it introduces.  Its README documents exactly two extension points
# and we use both: intro-customization.desktop for the first screen's text, and numbered QML files in
# extra-pages/ for our own pages.  Ours are the orientation and the honest page about Windows programs.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "5. installing the first-run flow"
install -D -m 0644 "$SRC/welcome/intro-customization.desktop" \
    /usr/share/plasma/plasma-welcome/intro-customization.desktop
for q in "$SRC"/welcome/extra-pages/*.qml; do
    install -D -m 0644 "$q" "/usr/share/plasma/plasma-welcome/extra-pages/$(basename "$q")"
    say "extra page: $(basename "$q")"
done
install -D -m 0644 "$SRC/welcome/orientation.html"           /usr/share/auros/orientation.html
install -D -m 0755 "$SRC/welcome/auros-welcome"              /usr/bin/auros-welcome
install -D -m 0755 "$SRC/welcome/auros-first-run"            /usr/libexec/auros/auros-first-run
install -D -m 0644 "$SRC/welcome/auros-first-run.service"    /usr/lib/systemd/user/auros-first-run.service
install -D -m 0644 "$SRC/welcome/org.auros.Welcome.desktop"  /usr/share/applications/org.auros.Welcome.desktop

# Enabled by a symlink in /usr/lib rather than by `systemctl --user enable`, because the users of these
# machines do not exist yet when the image is built.
install -d /usr/lib/systemd/user/graphical-session.target.wants
ln -sf ../auros-first-run.service \
    /usr/lib/systemd/user/graphical-session.target.wants/auros-first-run.service
say "auros-first-run.service enabled for every user (graphical-session.target.wants)"

# The stamp version in the unit's ConditionPathExists and the one in the script must agree, or the unit
# stops short-circuiting and the welcome wizard reopens on every single login.  Cheap to check, and the
# failure is invisible until a customer is annoyed by it every morning.
u=$(grep -o 'first-run\.v[0-9]*\.stamp' /usr/lib/systemd/user/auros-first-run.service | head -1)
s=$(grep -o 'STAMP_VERSION=v[0-9]*' /usr/libexec/auros/auros-first-run | head -1 | cut -d= -f2)
[[ $u == "first-run.${s}.stamp" ]] || {
    echo "FATAL: first-run stamp version mismatch: unit says '$u', script says '$s'." >&2; exit 1; }
say "first-run stamp version: $s (unit and script agree)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 6. THE .EXE CAPABILITY (DECISIONS.md D16)
#
# D16: a Bottles prefix CANNOT be pre-configured inside the OCI image, because prefixes live in $HOME
# and no bootc image controls $HOME.  So the image ships the template and the per-user oneshot; the
# Flatpak itself is turned on by the RECIPE.
#
# ASSUMED INTERFACE, not written by this layer (file ownership): the recipe's `compat_layer: true` is
# expected to emit a flatpak preinstall drop-in, i.e.
#     /etc/flatpak/preinstall.d/<name>.preinstall  containing  [Flatpak Preinstall com.usebottles.bottles]
# per flatpak-preinstall(1).  Nothing here depends on that file existing: auros-bottles-setup checks for
# the app at run time and exits quietly when it is absent, so the capability can be switched on in a
# later recipe build with no change to this layer.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "6. installing the .exe capability machinery (inert unless a recipe installs Bottles)"
install -D -m 0644 "$SRC/compat/windows-apps.conf" /usr/share/auros/windows-apps/windows-apps.conf
install -D -m 0644 "$SRC/compat/README.txt"        /usr/share/auros/windows-apps/README.txt
install -D -m 0755 "$SRC/compat/auros-bottles-setup" /usr/libexec/auros/auros-bottles-setup
install -D -m 0644 "$SRC/compat/auros-bottles-setup.service" \
    /usr/lib/systemd/user/auros-bottles-setup.service
ln -sf ../auros-bottles-setup.service \
    /usr/lib/systemd/user/graphical-session.target.wants/auros-bottles-setup.service
bu=$(grep -o 'windows-apps\.v[0-9]*\.stamp' /usr/lib/systemd/user/auros-bottles-setup.service | head -1)
bs=$(grep -o 'STAMP_VERSION=v[0-9]*' /usr/libexec/auros/auros-bottles-setup | head -1 | cut -d= -f2)
[[ $bu == "windows-apps.${bs}.stamp" ]] || {
    echo "FATAL: bottles stamp version mismatch: unit says '$bu', script says '$bs'." >&2; exit 1; }
say "template at /usr/share/auros/windows-apps/ ; materialiser runs per user only when Bottles exists"
say "bottles stamp version: $bs (unit and script agree)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# 7. THE AUDIT AND THE DOCUMENTS
# ══════════════════════════════════════════════════════════════════════════════════════════════════
step "7. installing the B12 audit and the customer-facing documents"
install -D -m 0755 "$SRC/assert-zero-terminal.sh" /usr/libexec/auros/assert-zero-terminal
install -D -m 0644 "$SRC/EXE-COMPATIBILITY.md"    "$DOCDIR/EXE-COMPATIBILITY.md"
install -D -m 0644 "$SRC/README.md"               "$DOCDIR/desktop-README.md"
say "/usr/libexec/auros/assert-zero-terminal  (check B12 runs this inside the booted VM)"

# Build-time facts, so the audit and any human can tell what was actually built rather than what was
# intended.  D19's lesson in file form: a claim that cannot be contradicted is not evidence.
install -d /usr/share/auros
{
    echo "# Written by build/40-windows-feel.sh. Measured at build time, not declared."
    echo "AUROS_DESKTOP_LAYER_VERSION=1"
    echo "AUROS_WELCOME_IMPL=$WELCOME_IMPL"
    echo "AUROS_DISCOVER_BACKENDS=$(find /usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover \
        -name '*-backend.so' 2>/dev/null | xargs -r -n1 basename | sed 's/-backend\.so//' | sort | paste -sd, -)"
    echo "AUROS_LOOKANDFEEL=org.auros.windows.desktop"
    echo "AUROS_FIRST_RUN_STAMP=first-run.${s}.stamp"
    echo "AUROS_BUILT_AT=$(date -Is)"
} > "$FACTS"
chmod 0644 "$FACTS"
say "facts recorded in $FACTS:"
sed 's/^/    /' "$FACTS"

step "done — Windows-familiarity layer installed"

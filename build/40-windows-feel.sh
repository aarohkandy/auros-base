#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/40-windows-feel.sh
#
# The Windows-familiarity layer. TASKS.md A10, DECISIONS.md D4, and the implementation side of check
# B12. Design notes and the verification table are in desktop/README.md.
#
# D4 is a binding human directive, not a preference:
#   "make sure people can still use it, if it can run exe and feel like windows that'd be amazing but
#    not completely required, make it clean end to end, make it feel like personalized windows rather
#    than linux rn which needs you to memorize books of commands and stuff"
#
# The user is a 62-year-old school administrator or a 9-year-old, on a 2013 laptop, who has never seen
# Linux and is not going to learn. The organising rule for everything below: A SETTING A USER HAS TO
# FIND IS A SETTING THAT IS NOT SET. Nothing here is left to the user, the installer or a first-boot
# prompt — it is in the image before the machine is switched on.
#
# Idempotent, per 00-common.sh's contract: running the whole build twice over the same filesystem must
# produce the same filesystem, because check S7 builds twice and compares content digests. That is why
# every file goes through install_file/install_text (SOURCE_DATE_EPOCH stamping) and why nothing this
# script writes contains a timestamp.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

. "${AUROS_BUILD_DIR:-/tmp/auros-build}/build/00-common.sh"
AUROS_STEP="40-windows-feel"

SRC="${AUROS_BUILD_DIR}/desktop"
[ -d "$SRC" ] || die "the build context has no desktop/ — the Containerfile did not COPY auros-base/desktop to ${AUROS_BUILD_DIR}/desktop"

# Pinned in desktop/flatpak/PROVENANCE.md. See section 3 for why this is a hash and not a download.
FLATHUB_SHA256=3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "the GUI paths check B12 audits"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# B12 audits four tasks: install an application, connect to Wi-Fi, add a printer, change the language,
# each reachable through the GUI. Those four are not abstractions — each is one package being present.
# We install them explicitly rather than trusting the base to keep carrying them. D9 is the precedent:
# greenboot was assumed present on Aurora and was not.
pkg_ensure \
  plasma-discover \
  plasma-discover-flatpak \
  plasma-nm \
  plasma-print-manager \
  cups \
  xdg-user-dirs \
  xdg-user-dirs-gtk \
  flatpak \
  libnotify

# Socket-activated, so the print daemon is not running on a machine that never prints.
if have_unit cups.socket; then
  enable_unit cups.socket
else
  warn "cups.socket does not exist in this image — adding a printer would fail check B12"
fi

# NOT THIS STEP'S DECISION, recorded here because it is load-bearing for B12 and nobody currently owns
# it: driverless printer discovery is mDNS, and mDNS needs avahi-daemon running. build/10-hardening.sh
# already opens mdns in the default firewall zone and says in its own log that it does so "because
# check B12 requires that adding a printer works without a terminal" — but no step in this build
# ENABLES avahi-daemon. Opening the port and not running the daemon gets us neither the discovery nor
# the smaller attack surface. Enabling a network-facing daemon on every machine in a school is a
# hardening decision, so this step does not make it; it makes it visible instead.
if have_unit avahi-daemon.service || have_unit avahi-daemon.socket; then
  if [ -e /usr/lib/systemd/system/multi-user.target.wants/avahi-daemon.service ] \
  || [ -e /etc/systemd/system/multi-user.target.wants/avahi-daemon.service ] \
  || [ -e /usr/lib/systemd/system/sockets.target.wants/avahi-daemon.socket ]; then
    found "avahi-daemon is enabled — network printers will be discovered automatically"
  else
    warn "avahi-daemon is present but NOT enabled: USB and printer-by-IP work from the GUI, mDNS auto-discovery does not. 10-hardening.sh opened the mdns port for B12. Owner: the hardening layer. See desktop/README.md GAP-3."
  fi
else
  warn "avahi-daemon is not installed: printer auto-discovery is unavailable. See desktop/README.md GAP-3."
fi

# plasma-welcome is the first-run wizard (section 5). Installed on its own rather than in the list
# above because, unlike those four, the product still works without it — an upstream that stops
# carrying it should degrade the welcome experience, not fail the entire base build.
WELCOME_IMPL=fallback-html
if have_pkg plasma-welcome; then
  WELCOME_IMPL=plasma-welcome
  found "plasma-welcome already present"
elif "$(auros_pkg_mgr)" install -y --setopt=install_weak_deps=False plasma-welcome >/dev/null 2>&1 \
     && have_pkg plasma-welcome; then
  WELCOME_IMPL=plasma-welcome
  did "installed plasma-welcome"
  record installed-package plasma-welcome
else
  warn "plasma-welcome is unavailable on this base — first run falls back to the static orientation page (degraded, not broken)"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "Discover: Flatpak backend only"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# On an image-based OS "install this rpm" is a path that cannot work. Leaving the PackageKit or
# rpm-ostree backend in Discover means a user is OFFERED that path — and succeeding is worse than
# failing, because a machine with layered packages has quietly stopped being the image we test, sign
# and rebuild every night (spec §3).
#
# The fwupd backend stays. Firmware updates are not packages, they work on an image-based system, and
# on 2012-2018 hardware they are occasionally the difference between a working trackpad and a call.
#
# THE COST, stated plainly: Discover no longer has a "check for system updates" button. Updates here
# are automatic and unattended (A4), so there is nothing for a user to press — but "is my computer up
# to date?" is a real question and right now only the orientation page answers it. desktop/README.md
# GAP-4.
PKG_MGR="$(auros_pkg_mgr)"
RMFLAGS=()
case "$PKG_MGR" in
  dnf5|dnf)
    # dnf4 spells it --noautoremove, dnf5 --no-autoremove. Probing beats guessing: guessing wrong
    # fails the whole base build on an option name.
    # Captured, not `--help | grep -q`: under pipefail grep's early exit SIGPIPEs the help text and a
    # supported flag reads as unsupported.
    rmhelp="$("$PKG_MGR" remove --help 2>&1 || true)"
    if   grep -q -- '--no-autoremove' <<<"$rmhelp"; then RMFLAGS=(--no-autoremove)
    elif grep -q -- '--noautoremove' <<<"$rmhelp";  then RMFLAGS=(--noautoremove)
    else found "$PKG_MGR accepts neither --noautoremove nor --no-autoremove; removing without it"
    fi ;;
esac

removed=0
for p in plasma-discover-packagekit plasma-discover-rpm-ostree plasma-discover-snap \
         PackageKit PackageKit-command-not-found gnome-software; do
  if have_pkg "$p"; then
    case "$PKG_MGR" in
      dnf5|dnf)   "$PKG_MGR" remove -y "${RMFLAGS[@]}" "$p" >/dev/null 2>&1 || warn "$PKG_MGR could not remove $p" ;;
      rpm-ostree) rpm-ostree override remove "$p" >/dev/null 2>&1 || warn "rpm-ostree could not remove $p" ;;
    esac
    if have_pkg "$p"; then
      warn "$p is still installed after an attempted removal"
    else
      did "removed $p"
      record removed-package "$p"
      removed=$((removed + 1))
    fi
  else
    found "$p not installed"
  fi
done
found "removed $removed package(s) that would have offered an install path an image-based OS cannot honour"

# The removals must not have taken Discover with them. A base with no app store fails B12 and D4 at
# once, and it would be found by a customer rather than by us.
have_pkg plasma-discover      || die "removing the non-Flatpak backends also removed plasma-discover, which is the only GUI path to installing an application (check B12)"
have_pkg plasma-discover-flatpak || die "plasma-discover-flatpak is not installed — Discover would have no usable backend"

# Filesystem-level assertion, in the spirit of check S9: the question is not what the package database
# believes, it is which plugins exist on disk, because a backend .so that survives here gets loaded.
backend_dirs="/usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover /usr/lib64/qt5/plugins/discover /usr/lib/qt5/plugins/discover"
# Search ONLY the directories that exist.
#
# This line used to pass all four to `find`. Three do not exist on Fedora 44 x86_64, and `find` exits 1
# on a missing directory. Under `set -euo pipefail` that exit code propagates through the pipeline, and
# inside `$( )` assigned to a variable, `set -e` then KILLS THE SCRIPT WITH NO MESSAGE. `2>/dev/null`
# hides find's error text but not its exit status.
#
# It is the dual of D19. pipefail exists so failures are loud; here an EXPECTED absence — an optional
# directory not being there — killed the build and suppressed the reason, which is the worst of both.
# The diagnostic added below it never printed, because execution never reached it; the only clue was
# that the log stopped mid-step with nothing at all.
existing_dirs=""
for _d in $backend_dirs; do [ -d "$_d" ] && existing_dirs="$existing_dirs $_d"; done
if [ -n "$existing_dirs" ]; then
  # shellcheck disable=SC2086
  present="$(find $existing_dirs -name '*-backend.so' | xargs -r -n1 basename | sed 's/-backend\.so//' | sort -u | paste -sd, -)"
  # shellcheck disable=SC2086
  stray="$(find $existing_dirs -name '*-backend.so' | { grep -Ev '/(flatpak|fwupd)-backend\.so$' || true; })"
else
  present=""; stray=""
fi
[ -z "$stray" ] || die "non-Flatpak Discover backends are still on disk: $(printf '%s ' $stray)— they would be loaded and offered to a user"
if [ -z "$present" ]; then
  # Print the ground truth WITH the failure rather than making the next build fetch it. Three
  # failures today were a remembered path or name; each cost a twelve-minute image build to learn
  # one fact. An assertion that says only "not found" makes that cost mandatory.
  printf 'auros[40-windows-feel]   searched for Discover backends in:\n' >&2
  # shellcheck disable=SC2086
  for d in $backend_dirs; do printf 'auros[40-windows-feel]     %s %s\n' "$d" "$([ -d "$d" ] && echo '(exists)' || echo '(absent)')" >&2; done
  printf 'auros[40-windows-feel]   every *.so shipped by plasma-discover:\n' >&2
  rpm -ql plasma-discover 2>/dev/null | grep '\.so$' | sed 's|^|auros[40-windows-feel]     |' >&2 || true
  printf 'auros[40-windows-feel]   every path containing "discover" under /usr/lib*/qt*/plugins:\n' >&2
  find /usr/lib64/qt6/plugins /usr/lib/qt6/plugins /usr/lib64/qt5/plugins /usr/lib/qt5/plugins \
       -ipath '*discover*' 2>/dev/null | head -40 | sed 's|^|auros[40-windows-feel]     |' >&2 || true
  die "no Discover backend plugins found at the paths above — the app store could not install anything (check B12). The listing above is ground truth: correct backend_dirs from it rather than guessing another path."
fi
did "Discover backends on disk: ${present}"
record discover-backends "$present"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "Flathub, configured in the image"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# `flatpak remote-add` at build time would write to /var/lib/flatpak, and /var is machine-local state
# that an OCI image does not carry — the remote would simply not exist on the installed machine. The
# mechanism that does work is flatpak-remote(5)'s static preconfiguration directory.
#
# The hash check is not ceremony. The GPGKey line in that file is the key Flatpak will use to verify
# every application a customer ever installs. Pinning it makes a key rotation a visible pull request
# instead of something the network decides during a nightly build.
actual="$(sha256sum "$SRC/flatpak/flathub.flatpakrepo" | awk '{print $1}')"
[ "$actual" = "$FLATHUB_SHA256" ] \
  || die "desktop/flatpak/flathub.flatpakrepo does not match its pinned hash (expected $FLATHUB_SHA256, got $actual) — this file carries the key that verifies every application a customer installs; if Flathub rotated it, update the file and both hashes in a reviewed commit"
install_file "$SRC/flatpak/flathub.flatpakrepo" /etc/flatpak/remotes.d/flathub.flatpakrepo 0644
found "sha256 verified against desktop/flatpak/PROVENANCE.md"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "Windows-shaped by default"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# KConfig cascades from $XDG_CONFIG_DIRS (/etc/xdg) into every user's session and the user's own file
# is layered on top. A value in /etc/xdg therefore reaches every user — INCLUDING accounts that
# already exist — and keeps tracking the image as the image is rebuilt nightly. A copy in /etc/skel
# is a snapshot frozen at account-creation time that never updates again. So /etc/xdg is the
# mechanism; /etc/skel is used for exactly two things and each says why.
for f in kdeglobals kwinrc kcminputrc plasmarc dolphinrc ksmserverrc kglobalshortcutsrc; do
  install_file "$SRC/xdg/$f" "/etc/xdg/$f" 0644
done
install_file "$SRC/xdg/user-dirs.defaults" /etc/xdg/user-dirs.defaults 0644
install_file "$SRC/xdg/user-dirs.conf"     /etc/xdg/user-dirs.conf     0644
found "user folders: Desktop, Documents, Downloads, Music, Pictures, Videos — and no Templates or Public, because a Windows machine has neither and a folder nobody asked for is a folder we should not create"
install_file "$SRC/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh" \
             /etc/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh 0755
found "session adds the flatpak exports to XDG_DATA_DIRS, so an app installed in Discover appears in the start menu without a re-login"

# Double-click is the single most-felt setting in this layer, so it is asserted rather than trusted to
# a loop that copied seven files.
#
# THE ASSERTION IS GROUP-AWARE, and it has to be. kdeglobals is an INI file and KConfig reads
# SingleClick out of [KDE] and nowhere else. `grep -qx 'SingleClick=false'` matched the line wherever
# it appeared — so a file with the key under [General], which KConfig ignores entirely, passed this
# check while the machine still opened files on one click. A check that accepts a configuration the
# software does not read is the "configured but not effective" failure B5 is named after, in the one
# setting D4 makes the product.
_auros_ini_value() { # <file> <group> <key> -- the LAST value KConfig would see for that key
  awk -v want="[$2]" -v key="$3" '
    /^[[:space:]]*\[/ { ing = ($0 ~ "^[[:space:]]*\\" want "[[:space:]]*$"); next }
    ing && index($0, key "=") == 1 { sub(/^[^=]*=/, "", $0); v = $0 }
    END { if (v != "") print v }
  ' "$1"
}
_auros_singleclick="$(_auros_ini_value /etc/xdg/kdeglobals KDE SingleClick)"
[ "$_auros_singleclick" = "false" ] \
  || die "[KDE] SingleClick=false is not in force in /etc/xdg/kdeglobals (found '${_auros_singleclick:-nothing}') — KDE would open files on a single click, and every person coming off Windows double-clicks. The key is only read from the [KDE] group; a copy under any other group does nothing."
did "double-click to open is set system-wide (kdeglobals [KDE] SingleClick=false)"
record windows-default "double-click"

# The look-and-feel package: appearance defaults, plus the layout script that IS the taskbar.
while IFS= read -r f; do
  install_file "$f" "/usr/share/plasma/look-and-feel/${f#"$SRC/lookandfeel/"}" 0644
done < <(find "$SRC/lookandfeel" -type f | sort)
LAYOUT=/usr/share/plasma/look-and-feel/org.auros.windows.desktop/contents/layouts/org.kde.plasma.desktop-layout.js
[ -f "$LAYOUT" ] || die "the layout script did not install — without it there is no taskbar"
for w in kickoff icontasks systemtray digitalclock showdesktop; do
  grep -q "org.kde.plasma.$w" "$LAYOUT" || die "the layout script does not add org.kde.plasma.$w"
done
did "taskbar layout installed: start menu, task buttons, system tray, clock, show desktop"

# /etc/skel — only the two things that genuinely belong there.
install_file "$SRC/xdg/kglobalshortcutsrc" /etc/skel/.config/kglobalshortcutsrc 0644
found "the skel copy of kglobalshortcutsrc is the exception to the /etc/xdg rule: kglobalaccel does not reliably merge cascaded defaults"
install_file "$SRC/welcome/org.auros.Welcome.desktop" /etc/skel/Desktop/org.auros.Welcome.desktop 0755
found "executable, so Plasma opens the desktop icon without an untrusted-file prompt"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "first boot is a guided setup"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# We use KDE's own plasma-welcome rather than writing a wizard. It already covers language, network
# and finding applications, it is translated far beyond anything we could manage, and it is maintained
# by the people who maintain the desktop it introduces. Its README documents exactly two extension
# points and we use both: intro-customization.desktop for the first screen, and numbered QML files in
# extra-pages/ for our own pages — the orientation, and the honest page about Windows programs.
install_file "$SRC/welcome/intro-customization.desktop" \
             /usr/share/plasma/plasma-welcome/intro-customization.desktop 0644
pages=0
for q in "$SRC"/welcome/extra-pages/*.qml; do
  install_file "$q" "/usr/share/plasma/plasma-welcome/extra-pages/$(basename "$q")" 0644
  pages=$((pages + 1))
done
[ "$pages" -ge 2 ] || die "expected the orientation page and the Windows-programs page, installed $pages"

install_file "$SRC/welcome/orientation.html"          /usr/share/auros/orientation.html          0644
install_file "$SRC/welcome/auros-welcome"             /usr/bin/auros-welcome                     0755
install_file "$SRC/welcome/auros-first-run"           "${AUROS_LIBEXEC}/auros-first-run"         0755
install_file "$SRC/welcome/auros-first-run.service"   /usr/lib/systemd/user/auros-first-run.service 0644
install_file "$SRC/welcome/org.auros.Welcome.desktop" /usr/share/applications/org.auros.Welcome.desktop 0644
enable_user_unit auros-first-run.service graphical-session.target

# The stamp version in the unit's ConditionPathExists and the one in the script must agree, or the
# unit stops short-circuiting and the welcome wizard reopens on every single login. Cheap to check,
# and the failure is invisible to us and infuriating to a customer every morning.
u="$(grep -o 'first-run\.v[0-9]*\.stamp' /usr/lib/systemd/user/auros-first-run.service | head -1)"
s="$(grep -o 'STAMP_VERSION=v[0-9]*' "${AUROS_LIBEXEC}/auros-first-run" | head -1 | cut -d= -f2)"
[ "$u" = "first-run.${s}.stamp" ] || die "first-run stamp version mismatch: the unit says '$u', the script says '$s' — the wizard would reopen at every login"
did "first run: ${WELCOME_IMPL}, ${pages} Auros pages, stamp ${u}, reopenable from Start → Help and Getting Started"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "the .exe capability (DECISIONS.md D16)"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# D16: a Bottles prefix CANNOT be pre-configured inside the OCI image, because prefixes live in $HOME
# and no bootc image controls $HOME. So the image ships a TEMPLATE under /usr and a `systemd --user`
# oneshot with a stamp file that materialises it per user at first run. The Flatpak itself is turned
# on by the RECIPE, not here.
#
# ASSUMED INTERFACE, not written by this step (file ownership): a recipe with `compat_layer: true` is
# expected to emit /etc/flatpak/preinstall.d/<name>.preinstall containing
# `[Flatpak Preinstall com.usebottles.bottles]`, per flatpak-preinstall(1). Nothing here depends on
# that file existing — auros-bottles-setup checks for the app at run time and exits quietly when it is
# absent, so the capability can be switched on in a later recipe build with no change to this layer.
install_file "$SRC/compat/windows-apps.conf" /usr/share/auros/windows-apps/windows-apps.conf 0644
install_file "$SRC/compat/README.txt"        /usr/share/auros/windows-apps/README.txt        0644
install_file "$SRC/compat/auros-bottles-setup" "${AUROS_LIBEXEC}/auros-bottles-setup"         0755
install_file "$SRC/compat/auros-bottles-setup.service" \
             /usr/lib/systemd/user/auros-bottles-setup.service 0644
enable_user_unit auros-bottles-setup.service graphical-session.target

bu="$(grep -o 'windows-apps\.v[0-9]*\.stamp' /usr/lib/systemd/user/auros-bottles-setup.service | head -1)"
bs="$(grep -o 'STAMP_VERSION=v[0-9]*' "${AUROS_LIBEXEC}/auros-bottles-setup" | head -1 | cut -d= -f2)"
[ "$bu" = "windows-apps.${bs}.stamp" ] || die "bottles stamp version mismatch: the unit says '$bu', the script says '$bs'"
did "template at /usr/share/auros/windows-apps/; the per-user materialiser is inert unless a recipe installs Bottles"
found "Office and Adobe are on the does-not-come-across list, not in a footnote — see /usr/share/doc/auros/EXE-COMPATIBILITY.md"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "the B12 audit and the documents"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
install_file "$SRC/assert-zero-terminal.sh" "${AUROS_LIBEXEC}/assert-zero-terminal" 0755
install_file "$SRC/EXE-COMPATIBILITY.md"    /usr/share/doc/auros/EXE-COMPATIBILITY.md 0644
install_file "$SRC/README.md"               /usr/share/doc/auros/desktop-README.md    0644
found "check B12 runs ${AUROS_LIBEXEC}/assert-zero-terminal inside the booted VM, in a real user session"

# What was actually built, as opposed to what was intended. Deliberately carries NO timestamp: this
# file ships in the image, and a timestamp would make it the one file that differs between the two
# builds check S7 compares.
install_text "${AUROS_PREFIX}/desktop-facts.env" 0644 <<FACTS
# Written by build/40-windows-feel.sh. Measured at build time, not declared.
# No timestamp on purpose — see check S7.
AUROS_DESKTOP_LAYER_VERSION=1
AUROS_WELCOME_IMPL=${WELCOME_IMPL}
AUROS_DISCOVER_BACKENDS=${present}
AUROS_LOOKANDFEEL=org.auros.windows.desktop
AUROS_FIRST_RUN_STAMP=${u}
AUROS_WINDOWS_APPS_STAMP=${bu}
FACTS
# The audit reads this path. Kept as a symlink under /usr/share/auros so the fact file lives with the
# rest of the image's self-knowledge in ${AUROS_PREFIX} (00-common.sh's rule) while the documented
# path stays stable.
mkdir -p /usr/share/auros
ln -sfn "${AUROS_PREFIX}/desktop-facts.env" /usr/share/auros/desktop-facts.env
auros_stamp /usr/share/auros/desktop-facts.env
printf '%s\n' /usr/share/auros/desktop-facts.env >> "$AUROS_WRITTEN_LIST"
did "recorded what was built in ${AUROS_PREFIX}/desktop-facts.env"
sed 's/^/auros[40-windows-feel]      /' "${AUROS_PREFIX}/desktop-facts.env"

step "Windows-familiarity layer installed"

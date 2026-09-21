#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/40-windows-feel.test.sh — the Windows-familiarity layer's build-time assertions.
#
# D4 is a binding human directive, not a preference: "make it feel like personalized windows rather
# than linux". The user is a 62-year-old school administrator or a nine-year-old on a 2013 laptop.
# The organising rule of the layer is "a setting a user has to find is a setting that is not set", so
# every one of these is in the image before the machine is switched on — which means every one of
# them is a thing a build can get silently wrong and nobody notices until a customer does.
#
# WHAT THIS FILE OWNS AND WHAT IT DOES NOT:
#   here                        the BUILD-TIME assertions in build/40-windows-feel.sh
#   desktop/tests/b12-modes.test.sh   check B12 per policy mode, against the real
#                               assert-zero-terminal.sh. That file already drives every mode into
#                               green and red; repeating it here would be a second copy that drifts.
#
# A BUG THIS FILE FOUND:
#   the double-click assertion was `grep -qx 'SingleClick=false' /etc/xdg/kdeglobals`. kdeglobals is
#   an INI file and KConfig reads SingleClick out of [KDE] and nowhere else — so a file with the key
#   under [General] passed the check while the machine still opened files on one click. Configured,
#   not effective, in the single setting D4 makes the product. The wrong-group case below is that
#   regression, and it was watched going green against the old implementation.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

W="$REPO/build/40-windows-feel.sh"
D="$REPO/desktop"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
export PATH="$STUBS:$PATH"

printf '40-windows-feel.sh — the Windows-familiarity layer  (%s)\n' "$T_SED_MODE"

PRE='set -uo pipefail
step() { :; }
did()  { echo "DID $*"; }
found(){ echo "FOUND $*"; }
warn() { echo "WARN $*"; }
die()  { echo "DIE $*" >&2; exit 1; }
record(){ :; }
'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "double-click — the single most-felt setting in the layer"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The range is the WHOLE double-click section, from its comment to its record line, not just the
# helper function. Anchoring on the helper's name would make the test abort — rather than go red —
# the moment somebody replaced the implementation with a group-blind grep again, and an abort is a
# weaker signal than "the wrong-group case now passes".
CLICK_BLOCK="$(extract_between "$W" '^# Double-click is the single most-felt' '^record windows-default' | rootify /etc/xdg/kdeglobals)"

click_case() { # <kdeglobals body>
  local root; root="$(newroot)"; mkdir -p "$root/etc/xdg"
  printf '%s\n' "$1" > "$root/etc/xdg/kdeglobals"
  ROOT="$root" bash -c "$PRE
$CLICK_BLOCK"
}

run_check click.double green "the kdeglobals we actually ship" -- click_case "$(cat "$D/xdg/kdeglobals")"
run_check click.double green "the minimum that works: [KDE] then the key" -- click_case '[KDE]
SingleClick=false'
run_check click.double red   "SingleClick=true"        -- click_case '[KDE]
SingleClick=true'
run_check click.double red   "the key is absent"       -- click_case '[KDE]
widgetStyle=Breeze'
run_check click.double red   "the file is empty"       -- click_case ''

# THE REGRESSION. KConfig reads this key from [KDE] only. The old grep matched it anywhere.
run_check click.double red "SingleClick=false under [General] — a group KConfig does not read it from" \
  -- click_case '[General]
SingleClick=false'
assert_has "says the key is only read from [KDE]" "only read from the [KDE] group" "$T_LAST_OUT"
run_check click.double red "SingleClick=false under [KFileDialog Settings]" -- click_case '[KFileDialog Settings]
SingleClick=false'
run_check click.double red "the key appears before any group header at all" -- click_case 'SingleClick=false
[KDE]
widgetStyle=Breeze'

# A later duplicate in the same group wins, which is what KConfig does. Both directions, because a
# reader that took the FIRST value would report a machine as double-click when it is not.
run_check click.double red   "[KDE] sets it false and then true again" -- click_case '[KDE]
SingleClick=false
SingleClick=true'
run_check click.double green "[KDE] sets it true and then false again" -- click_case '[KDE]
SingleClick=true
SingleClick=false'
# And a [KDE] section that is reopened later in the file is still [KDE].
run_check click.double green "a second [KDE] section carries the value" -- click_case '[KDE]
widgetStyle=Breeze

[General]
ColorScheme=BreezeLight

[KDE]
SingleClick=false'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "Discover — the rpm/PackageKit backends are gone FROM DISK, not just from the rpm database"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# On an image-based OS "install this rpm" is a path that cannot work, and SUCCEEDING is worse than
# failing: a machine with layered packages has quietly stopped being the image we test, sign and
# rebuild every night. The assertion is on the filesystem rather than on `rpm -q`, because a backend
# .so that survives a removal still gets loaded and still gets offered to a user.
BACKEND_BLOCK="$(extract_between "$W" '^backend_dirs=' '^record discover-backends' \
  | rootify /usr/lib64/qt6/plugins/discover /usr/lib/qt6/plugins/discover /usr/lib64/qt5/plugins/discover /usr/lib/qt5/plugins/discover)"

backend_case() { # <backend names...>
  local root b; root="$(newroot)"
  mkdir -p "$root/usr/lib64/qt6/plugins/discover"
  for b in "$@"; do : > "$root/usr/lib64/qt6/plugins/discover/${b}-backend.so"; done
  ROOT="$root" bash -c "$PRE
$BACKEND_BLOCK"
}

run_check discover.backends green "flatpak and fwupd only"     -- backend_case flatpak fwupd
run_check discover.backends green "flatpak alone"              -- backend_case flatpak
run_check discover.backends red   "no backends on disk at all" -- backend_case
assert_has "says the app store could not install anything" "could not install anything" "$T_LAST_OUT"
for stray in packagekit rpm-ostree snap dummy steamos; do
  run_check discover.backends red "a '$stray' backend survived on disk" -- backend_case flatpak fwupd "$stray"
  assert_has "names the stray plugin"   "$stray-backend.so" "$T_LAST_OUT"
  assert_has "says it would be offered" "offered to a user"  "$T_LAST_OUT"
done

# The removal list in the script and the stray pattern in the assertion have to agree, or a package
# we remove is not one we then refuse to ship. Read both out of the file rather than restated.
REMOVE_LIST="$(extract_raw "$W" '^for p in plasma-discover-packagekit' '^         PackageKit' | tr ' ' '\n' | grep -E 'discover-|PackageKit|gnome-software' || true)"
assert_has "the removal list still names the PackageKit backend"  "plasma-discover-packagekit"  "$REMOVE_LIST"
assert_has "the removal list still names the rpm-ostree backend"  "plasma-discover-rpm-ostree"  "$REMOVE_LIST"
assert_has "the assertion's allowlist is flatpak and fwupd only"  "(flatpak|fwupd)-backend" \
  "$(extract_lines "$W" 'stray=')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "Flathub — the key that verifies every application a customer ever installs"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The GPGKey line in flathub.flatpakrepo is what Flatpak uses to verify every app a customer
# installs. Pinning its hash makes a key rotation a visible pull request instead of something the
# network decides during a nightly build.
HASH_BLOCK="$(extract_between "$W" '^actual="$(sha256sum' '^install_file "$SRC/flatpak/flathub.flatpakrepo"')"

hash_case() { # <source file to use as the repo file> <expected sha>
  # The FILE is copied rather than its text round-tripped through a variable: $(cat f) drops the
  # trailing newline, which changes the hash — so a test written that way reports a mismatch on the
  # very file that matches, and the natural next move is to "fix" the pin.
  local root; root="$(newroot)"; mkdir -p "$root/flatpak"
  cp "$1" "$root/flatpak/flathub.flatpakrepo"
  SRC="$root" FLATHUB_SHA256="$2" bash -c "$PRE
install_file() { :; }
$(printf '%s\n' "$HASH_BLOCK" | grep -v '^install_file ')"
}

REAL_REPO="$D/flatpak/flathub.flatpakrepo"
REAL_SHA="$(shasum -a 256 "$REAL_REPO" 2>/dev/null | awk '{print $1}')"
[ -n "$REAL_SHA" ] || REAL_SHA="$(sha256sum "$REAL_REPO" | awk '{print $1}')"
PINNED="$(grep -E '^FLATHUB_SHA256=' "$W" | head -1 | cut -d= -f2-)"
[ -n "$PINNED" ] || t_abort "40-windows-feel.sh has no FLATHUB_SHA256 pin — this test would be vacuous"

assert_eq "the shipped flathub.flatpakrepo matches its pinned hash" "$PINNED" "$REAL_SHA"
assert_has "and the file really does carry a GPG key" "GPGKey=" "$(cat "$REAL_REPO")"

# sha256sum is GNU-only; the build runs in the image where it exists. On a BSD host, stand in for it.
command -v sha256sum >/dev/null 2>&1 || stub "$STUBS" sha256sum <<'SH'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
SH
run_check flathub.pin green "the file matches the pin" -- hash_case "$REAL_REPO" "$REAL_SHA"
MUT="$(newroot)/rotated.flatpakrepo"; { cat "$REAL_REPO"; printf 'x\n'; } > "$MUT"
run_check flathub.pin red   "one byte of the file changed — a rotated key would look like this" \
  -- hash_case "$MUT" "$REAL_SHA"
assert_has "explains what the file is for" "verifies every application a customer installs" "$T_LAST_OUT"
run_check flathub.pin red "the pin was updated but the file was not" \
  -- hash_case "$REAL_REPO" "0000000000000000000000000000000000000000000000000000000000000000"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the taskbar — the layout script IS the Windows shape"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Without the layout script there is no taskbar, which is most of what "feels like Windows" means.
# The five widgets are asserted by name because a layout that installed and contained none of them
# would still be a file on disk, and the build would still say it installed one.
LAYOUT="$D/lookandfeel/org.auros.windows.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
assert_file "the layout script is in the payload at all" "$LAYOUT"
WIDGETS="$(extract_lines "$W" '^for w in ' | sed -E 's/^for w in //; s/; do$//')"
[ -n "$WIDGETS" ] || t_abort "could not read the widget list out of 40-windows-feel.sh"
for w in $WIDGETS; do
  if grep -q "org.kde.plasma.$w" "$LAYOUT"; then
    ok "the shipped layout adds org.kde.plasma.$w"
  else
    bad "the shipped layout does NOT add org.kde.plasma.$w, which the build asserts it does"
  fi
done

LAYOUT_BLOCK="$(extract_between "$W" '^LAYOUT=/usr/share/plasma/look-and-feel' '^did "taskbar layout installed' \
  | rootify /usr/share/plasma/look-and-feel)"
layout_case() { # <body or 'absent'>
  local root; root="$(newroot)"
  mkdir -p "$root/usr/share/plasma/look-and-feel/org.auros.windows.desktop/contents/layouts"
  [ "$1" = absent ] || printf '%s\n' "$1" > "$root/usr/share/plasma/look-and-feel/org.auros.windows.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
  ROOT="$root" bash -c "$PRE
$LAYOUT_BLOCK"
}
run_check layout.taskbar green "the real layout script" -- layout_case "$(cat "$LAYOUT")"
run_check layout.taskbar red   "the layout script did not install" -- layout_case absent
assert_has "says there would be no taskbar" "no taskbar" "$T_LAST_OUT"
run_check layout.taskbar red "a layout script with no start menu in it" \
  -- layout_case 'var panel = new Panel; panel.addWidget("org.kde.plasma.icontasks");'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the other layouts — every look-and-feel package ships well-formed, not only the default"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The Windows layout is the default (D4). The shelf (browser-first) and simple (three big buttons)
# layouts are alternatives; the reasons and the evidence are in the control repo's
# docs/DESKTOP-LAYOUTS.md. A layout a school picks and that then produces no panel is the same
# failure as the taskbar missing, so each package gets the same scrutiny as the default one.
LNF_IDS="$(extract_lines "$W" '^LNF_IDS=' | cut -d= -f2- | tr -d '"')"
[ -n "$LNF_IDS" ] || t_abort "could not read LNF_IDS out of 40-windows-feel.sh"
assert_has "the build still validates the default Windows package" "org.auros.windows.desktop" "$LNF_IDS"

# The payload and the build's list must agree both ways: a package in the repo the build does not
# check ships unvalidated, and a package the build lists but the repo lacks fails every build.
SHIPPED="$(find "$D/lookandfeel" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' ')"
assert_eq "the packages in desktop/lookandfeel are exactly the ones the build validates" \
  "$(printf '%s\n' $LNF_IDS | sort | tr '\n' ' ')" "$SHIPPED"

# Well-formed, statically: valid JSON with the right id and the proprietary licence (D30), and a
# layout script that at least parses as JavaScript. Parsing is not running: nothing on this machine
# is a plasmashell, so whether Plasma accepts every call is a VM question (desktop/README.md VERIFY-3).
for id in $LNF_IDS; do
  P="$D/lookandfeel/$id"
  got="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); k=m["KPlugin"]; print(k["Id"], k["License"], m["KPackageStructure"])' "$P/metadata.json" 2>&1)"
  assert_eq "$id: metadata.json parses, with its own id, the proprietary licence and the LookAndFeel structure" \
    "$id LicenseRef-Proprietary Plasma/LookAndFeel" "$got"
  if command -v node >/dev/null 2>&1; then
    if node --check "$P/contents/layouts/org.kde.plasma.desktop-layout.js" 2>/dev/null; then
      ok "$id: the layout script parses as JavaScript"
    else
      bad "$id: the layout script is not valid JavaScript — plasmashell would reject it and the user would get no panel"
    fi
  else
    note "node is not installed here; $id's layout script was not syntax-checked"
  fi
done

LNF_BLOCK="$(extract_between "$W" '^LNF_IDS=' '^did "look-and-feel packages' | rootify /usr/share/plasma/look-and-feel)"
# lnf_case <mutation> — installs the real payload into a fake root, applies one mutation (shell, with
# $L pointing at the installed tree), then runs the build's own block against it.
lnf_case() {
  local root; root="$(newroot)"
  mkdir -p "$root/usr/share/plasma/look-and-feel"
  cp -R "$D/lookandfeel/." "$root/usr/share/plasma/look-and-feel/"
  # A mutation that fails to apply returns GREEN, so a red case whose bug never went in reports as a
  # failure of this test instead of passing on a machine that was never broken.
  ( L="$root/usr/share/plasma/look-and-feel"; eval "$1" ) || { echo "the mutation itself failed: $1"; return 0; }
  ROOT="$root" bash -c "$PRE
$LNF_BLOCK"
}
S=org.auros.shelf.desktop; M=org.auros.simple.desktop
run_check layout.packages green "the real payload, all three packages" -- lnf_case ':'
run_check layout.packages red   "the simple package did not install" -- lnf_case "rm -rf \"\$L/$M\""
assert_has "names the package" "$M" "$T_LAST_OUT"
run_check layout.packages red   "the shelf package did not install" -- lnf_case "rm -rf \"\$L/$S\""
run_check layout.packages red   "metadata.json carries another package's id (a copy that was never edited)" \
  -- lnf_case "sed -i 's/\"Id\": \"$S\"/\"Id\": \"org.auros.windows.desktop\"/' \"\$L/$S/metadata.json\""
assert_has "says Plasma would not list it" "would not list it" "$T_LAST_OUT"
run_check layout.packages red   "metadata.json lost its KPackageStructure" \
  -- lnf_case "sed -i '/KPackageStructure/d' \"\$L/$M/metadata.json\""
run_check layout.packages red   "defaults names the Windows package" \
  -- lnf_case "sed -i 's/^LookAndFeelPackage=.*/LookAndFeelPackage=org.auros.windows.desktop/' \"\$L/$M/contents/defaults\""
run_check layout.packages red   "the layout script is missing" \
  -- lnf_case "rm \"\$L/$S/contents/layouts/org.kde.plasma.desktop-layout.js\""
assert_has "says the user would have no panel" "no panel" "$T_LAST_OUT"
run_check layout.packages red   "the layout drops the system tray (no Wi-Fi from the GUI, B12)" \
  -- lnf_case "sed -i '/addWidget(\"org.kde.plasma.systemtray\")/d' \"\$L/$M/contents/layouts/org.kde.plasma.desktop-layout.js\""
assert_has "names the missing widget" "org.kde.plasma.systemtray" "$T_LAST_OUT"
# THE FALSE GREEN this check is shaped against: the widget is gone but a comment still names it.
run_check layout.packages red   "the task buttons are gone and only a comment still mentions org.kde.plasma.icontasks" \
  -- lnf_case "sed -i 's/.*addWidget(\"org.kde.plasma.icontasks\").*/\\/\\/ org.kde.plasma.icontasks used to be here/' \"\$L/$S/contents/layouts/org.kde.plasma.desktop-layout.js\""

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the first-run stamp — the check that stops the wizard reopening every morning"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# If the unit's ConditionPathExists and the script's STAMP_VERSION disagree, the unit stops
# short-circuiting and the welcome wizard reopens at every single login. Invisible to us, infuriating
# to a customer daily — which is the kind of defect that never gets reported, it just gets the
# machines stopped being used.
for pair in "welcome/auros-first-run.service:welcome/auros-first-run:first-run" \
            "compat/auros-bottles-setup.service:compat/auros-bottles-setup:windows-apps"; do
  unit="${pair%%:*}"; rest="${pair#*:}"; script="${rest%%:*}"; prefix="${rest##*:}"
  u="$(grep -o "${prefix}\.v[0-9]*\.stamp" "$D/$unit" | head -1)"
  s="$(grep -o 'STAMP_VERSION=v[0-9]*' "$D/$script" | head -1 | cut -d= -f2)"
  if [ -n "$u" ] && [ -n "$s" ] && [ "$u" = "${prefix}.${s}.stamp" ]; then
    ok "$prefix stamp versions agree between the unit and the script ($u)"
  else
    bad "$prefix stamp mismatch: unit says '${u:-nothing}', script says '${s:-nothing}' — the wizard would reopen at every login"
  fi
done

STAMP_BLOCK="$(extract_between "$W" '^u="$(grep -o' '^did "first run:' \
  | rootify /usr/lib/systemd/user)"
stamp_case() { # <unit stamp> <script stamp>
  local root; root="$(newroot)"
  mkdir -p "$root/usr/lib/systemd/user" "$root/libexec"
  printf 'ConditionPathExists=!%%h/.local/state/auros/first-run.%s.stamp\n' "$1" \
    > "$root/usr/lib/systemd/user/auros-first-run.service"
  printf 'STAMP_VERSION=%s\n' "$2" > "$root/libexec/auros-first-run"
  ROOT="$root" AUROS_LIBEXEC="$root/libexec" WELCOME_IMPL=plasma-welcome pages=2 bash -c "$PRE
$STAMP_BLOCK"
}
run_check stamp.first-run green "the unit and the script agree"   -- stamp_case v1 v1
run_check stamp.first-run red   "the unit says v1, the script v2" -- stamp_case v1 v2
assert_has "says the wizard would reopen at every login" "reopen at every login" "$T_LAST_OUT"
run_check stamp.first-run red   "the unit names no stamp at all"  -- stamp_case '' v1

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "B12's four GUI paths — the packages that ARE the four tasks"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# B12 audits four tasks. Each one is not an abstraction: it is one package being present. They are
# installed explicitly rather than inherited from the base, because D9 is the precedent — greenboot
# was assumed present on Aurora and was not.
PKGS="$(extract_raw "$W" '^pkg_ensure ' '^  libnotify$' | grep -E '^  [a-z]' | tr -d ' \\\\')"
[ -n "$PKGS" ] || t_abort "could not read the pkg_ensure list out of 40-windows-feel.sh"
for want in plasma-discover plasma-discover-flatpak plasma-nm plasma-print-manager cups; do
  case " $(printf '%s' "$PKGS" | tr '\n' ' ') " in
    *" $want "*) ok "B12 still installs $want explicitly" ;;
    *) bad "B12's package list no longer installs $want — one of the four tasks would depend on the base still carrying it (D9)" ;;
  esac
done

# The removal pass must not be allowed to take Discover with it. A base with no app store fails B12
# and D4 at once, and it would be found by a customer rather than by us.
SURVIVE="$(extract_lines "$W" 'have_pkg plasma-discover')"
assert_has "the build refuses if plasma-discover was removed"         "die" "$SURVIVE"
assert_has "and if the flatpak backend was removed with it"           "plasma-discover-flatpak" "$SURVIVE"

# The one honest gap in this layer, asserted so it cannot be quietly closed by accident or quietly
# forgotten: 10-hardening.sh opens the mdns port for printer discovery and nothing enables
# avahi-daemon. The script says so at build time rather than pretending. If somebody enables it, this
# goes red and the gap note has to be removed in the same change.
assert_has "the avahi gap is still declared rather than papered over" "GAP-3" "$(cat "$W")"
t_exempt b12.packages \
  "assertions about the CONTENT of the shipping script — which packages it installs, which removals
       it refuses to survive — rather than about a runtime decision. B12 itself is driven into green
       and red per policy mode by desktop/tests/b12-modes.test.sh, which owns that coverage."


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the welcome pages — the honest one is not optional"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Two pages ship: the orientation, and the page that says plainly which Windows programs do not come
# across. The second one is the one a customer would rather not read and the one we are least likely
# to notice going missing, because everything else still works. `-ge 2` is what makes it mandatory,
# and `-ge 1` would let the honest page disappear with the build still green.
PAGES_BLOCK="$(extract_between "$W" '^pages=0$' 'the Windows-programs page, installed')"

pages_run() { # <root> <n pages>
  local root="$1" n="$2" i
  mkdir -p "$root/src/welcome/extra-pages"
  i=1; while [ "$i" -le "$n" ]; do printf 'import QtQuick\n' > "$root/src/welcome/extra-pages/${i}0-page.qml"; i=$((i+1)); done
  ROOT="$root" SRC="$root/src" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$ROOT\$2\")\"; install -m \"\${3:-0644}\" \"\$1\" \"\$ROOT\$2\"; }
$PAGES_BLOCK"
}

R="$(newroot)"; run_check welcome.pages green "both pages are installed" -- pages_run "$R" 2
assert_file "the first page landed" "$R/usr/share/plasma/plasma-welcome/extra-pages/10-page.qml"
assert_file "so did the second"     "$R/usr/share/plasma/plasma-welcome/extra-pages/20-page.qml"
R="$(newroot)"; run_check welcome.pages green "a third page was added" -- pages_run "$R" 3

# THE ONE THAT MATTERS. One page is the orientation with the Windows-programs page missing.
R="$(newroot)"; run_check welcome.pages red "only ONE page — the honest page went missing" -- pages_run "$R" 1
assert_has "names both pages it expected" "the orientation page and the Windows-programs page" "$T_LAST_OUT"
assert_has "and says how many it found"   "installed 1"                                        "$T_LAST_OUT"
R="$(newroot)"; run_check welcome.pages red "extra-pages/ is empty" -- pages_run "$R" 0

# And the repository must ship at least the two the build insists on, or the check and the payload
# disagree and one of them is wrong.
NPAGES="$(find "$D/welcome/extra-pages" -name '*.qml' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NPAGES" -ge 2 ]; then ok "the repo ships $NPAGES welcome pages, which is what the build demands"
else bad "the repo ships $NPAGES welcome page(s); build/40-windows-feel.sh demands at least 2"; fi
assert_has "and one of them is the Windows-programs page" "windows" \
  "$(find "$D/welcome/extra-pages" -name '*.qml' -exec basename {} \; | tr 'A-Z' 'a-z' | tr '\n' ' ')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "enable_user_unit — 'enabled for every future user' is a symlink, not a log line"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# These are `systemd --user` units, and every user of these machines is created long after the image
# was built — so the symlink has to be IN THE IMAGE. If it is not, the first-run wizard and the
# Bottles materialiser simply never run, for anybody, ever, and the build log says "enabled".
#
# Two deletions are each invisible without this: the `[ -e "$dir/$u" ] || die` after the ln, and the
# `[ -f /usr/lib/systemd/user/$u ] || die` before it.
EUU_FN="$(extract_fn "$W" enable_user_unit | rootify /usr/lib/systemd/user)"

euu_run() { # <root> <unit> <create-unit: yes|no> [noln]
  local root="$1" path="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" sdir
  mkdir -p "$root/usr/lib/systemd/user"
  [ "$3" = yes ] && printf '[Unit]\nDescription=%s\n[Install]\nWantedBy=graphical-session.target\n' "$2" \
    > "$root/usr/lib/systemd/user/$2"
  if [ "${4:-}" = noln ]; then
    sdir="$root/lnbin"; mkdir -p "$sdir"
    # An `ln` that exits 0 and creates nothing. The build would report "enabled user unit" and the
    # wizard would never run on any machine.
    stub "$sdir" ln <<'SH'
#!/usr/bin/env bash
exit 0
SH
    path="$sdir:$path"
  fi
  ROOT="$root" PATH="$path" AUROS_WRITTEN_LIST="$root/written" bash -c "$PRE
auros_stamp(){ :; }
$EUU_FN
enable_user_unit '$2' graphical-session.target"
}

R="$(newroot)"
run_check welcome.user-unit green "the unit exists and is enabled for graphical-session.target" \
  -- euu_run "$R" auros-first-run.service yes
assert_symlink_to "the .wants link is relative, pointing at the unit beside it" \
  "$R/usr/lib/systemd/user/graphical-session.target.wants/auros-first-run.service" "../auros-first-run.service"
assert_has "and reading through it reaches the real unit" "Description=auros-first-run.service" \
  "$(cat "$R/usr/lib/systemd/user/graphical-session.target.wants/auros-first-run.service" 2>/dev/null || echo '<dangling>')"
assert_has "the path is recorded for the mtime re-stamp" "graphical-session.target.wants" "$(cat "$R/written" 2>/dev/null || true)"

# Idempotent: the build must be runnable twice over one filesystem (check S7).
run_check welcome.user-unit green "running it a second time" -- euu_run "$R" auros-first-run.service yes

R="$(newroot)"
run_check welcome.user-unit red "the user unit was never installed" -- euu_run "$R" auros-bottles-setup.service no
assert_has "names the file it could not find" "does not exist" "$T_LAST_OUT"

# THE REFUSAL THAT HAD NO TEST: ln exits 0 and creates nothing.
R="$(newroot)"
run_check welcome.user-unit red "ln exits 0 and creates no link" -- euu_run "$R" auros-first-run.service yes noln
assert_has "says it could not enable it" "could not enable" "$T_LAST_OUT"

# And the two user units the layer actually ships must be the ones that pass.
for uu in welcome/auros-first-run.service compat/auros-bottles-setup.service; do
  assert_file "the repo ships $uu" "$D/$uu"
done

t_finish "40-windows-feel.sh"

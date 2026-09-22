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
# DESKTOP-LAYOUTS.md §2.1: the script never set floating, and a scripted panel floats by default.
run_check layout.taskbar red "the real layout with its panel.floating = false line removed (the taskbar floats)" \
  -- layout_case "$(grep -vx 'panel.floating = false;' "$LAYOUT")"
assert_has "says the taskbar would float" "would float" "$T_LAST_OUT"

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
S=org.auros.shelf.desktop; M=org.auros.simple.desktop; A=org.auros.mac.desktop
run_check layout.packages green "the real payload, all four packages" -- lnf_case ':'
run_check layout.packages red   "the mac package did not install" -- lnf_case "rm -rf \"\$L/$A\""
assert_has "names the mac package" "$A" "$T_LAST_OUT"
run_check layout.packages red   "the mac layout drops the input-method indicator (Marathi users cannot see how they are typing)" \
  -- lnf_case "sed -i '/addWidget(\"org.kde.plasma.kimpanel\")/d' \"\$L/$A/contents/layouts/org.kde.plasma.desktop-layout.js\""
assert_has "names kimpanel" "org.kde.plasma.kimpanel" "$T_LAST_OUT"
run_check layout.packages red   "the Windows layout drops the input-method indicator" \
  -- lnf_case "sed -i '/addWidget(\"org.kde.plasma.kimpanel\")/d' \"\$L/org.auros.windows.desktop/contents/layouts/org.kde.plasma.desktop-layout.js\""
run_check layout.packages red   "the mac layout has no task buttons in its dock" \
  -- lnf_case "sed -i '/addWidget(\"org.kde.plasma.icontasks\")/d' \"\$L/$A/contents/layouts/org.kde.plasma.desktop-layout.js\""
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
group "choosing the layout — one setting, Windows unless a recipe says otherwise, nothing unknown"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# One mechanism: a recipe's derived layer runs `set-desktop-layout <name>`, which writes the package id
# to /etc/auros/desktop-layout and into [KDE] LookAndFeelPackage of /etc/xdg/kdeglobals; auros-first-run
# reads the file. These run the REAL helper against a fake root holding the real payload.
HELPER="$D/set-desktop-layout"
assert_file "the helper is in the payload" "$HELPER"

# fresh_root — a new fake root holding the real payload, in $CHOSEN_ROOT. Made in THIS shell, not in
# choose_case, because run_check runs its command in a subshell and a root made there is invisible here.
fresh_root() {
  CHOSEN_ROOT="$(newroot)"; T_TMPDIRS+=("$CHOSEN_ROOT")
  mkdir -p "$CHOSEN_ROOT/etc/xdg" "$CHOSEN_ROOT/usr/share/plasma/look-and-feel"
  cp -R "$D/lookandfeel/." "$CHOSEN_ROOT/usr/share/plasma/look-and-feel/"
  cp "$D/xdg/kdeglobals" "$CHOSEN_ROOT/etc/xdg/kdeglobals"
}
# choose_case <mutation> <args...> — the mutation is shell run with $R as the root, before the helper.
choose_case() {
  ( R="$CHOSEN_ROOT"; eval "$1" ) || { echo "the mutation itself failed: $1"; return 0; }
  shift
  AUROS_LAYOUT_ROOT="$CHOSEN_ROOT" bash "$HELPER" "$@"
}
kde_lnf() { awk '/^[[:space:]]*\[/ { k = ($0 == "[KDE]"); next } k && index($0, "LookAndFeelPackage=") == 1 { sub(/^[^=]*=/, ""); print }' "$1"; }

for pair in windows:org.auros.windows.desktop browser-first:org.auros.shelf.desktop \
            simple:org.auros.simple.desktop mac:org.auros.mac.desktop; do
  name="${pair%%:*}"; id="${pair#*:}"
  fresh_root; CHOSEN_ROOT_SAVED="$CHOSEN_ROOT"
  run_check layout.choose green "set-desktop-layout $name" -- choose_case ':' "$name"
  assert_eq "$name: /etc/auros/desktop-layout names $id" "$id" "$(cat "$CHOSEN_ROOT_SAVED/etc/auros/desktop-layout" 2>&1)"
  assert_eq "$name: kdeglobals [KDE] LookAndFeelPackage is $id, once" "$id" "$(kde_lnf "$CHOSEN_ROOT_SAVED/etc/xdg/kdeglobals")"
  assert_eq "$name: every other line of the shared kdeglobals is untouched" \
    "$(grep -v '^LookAndFeelPackage=' "$D/xdg/kdeglobals")" "$(grep -v '^LookAndFeelPackage=' "$CHOSEN_ROOT_SAVED/etc/xdg/kdeglobals")"
done
# Every name the helper knows is a package the build ships, and every shipped package has a name.
NAMES_IDS="$(sed -nE 's/^ +[a-z-]+\) +ID=(org\.auros\.[a-z]+\.desktop) ;;$/\1/p' "$HELPER" | sort | tr '\n' ' ')"
assert_eq "the helper's names map onto exactly the packages the build validates" \
  "$(printf '%s\n' $LNF_IDS | sort | tr '\n' ' ')" "$NAMES_IDS"

fresh_root; run_check layout.choose red "an unknown name (macos)" -- choose_case ':' macos
assert_has "says which names exist" "windows|browser-first|simple|mac" "$T_LAST_OUT"
assert_nofile "and records nothing" "$CHOSEN_ROOT/etc/auros/desktop-layout"
assert_eq "and leaves kdeglobals alone" "$(cat "$D/xdg/kdeglobals")" "$(cat "$CHOSEN_ROOT/etc/xdg/kdeglobals")"
fresh_root; run_check layout.choose red "no name at all" -- choose_case ':'
fresh_root; run_check layout.choose red "a raw package id instead of a name" -- choose_case ':' org.auros.mac.desktop
fresh_root; run_check layout.choose red "a path instead of a name" -- choose_case ':' ../../../tmp/evil
fresh_root; run_check layout.choose red "the named package is not in this image" \
  -- choose_case 'rm -rf "$R/usr/share/plasma/look-and-feel/org.auros.mac.desktop"' mac
assert_has "says users would get no panel" "no panel" "$T_LAST_OUT"
fresh_root; run_check layout.choose red "this image has no /etc/xdg/kdeglobals (not an Auros base)" \
  -- choose_case 'rm "$R/etc/xdg/kdeglobals"' simple
fresh_root; run_check layout.choose green "[KDE] exists without the key: it is added under [KDE]" \
  -- choose_case 'printf "[General]\nLookAndFeelPackage=wrong\n[KDE]\nSingleClick=false\n" > "$R/etc/xdg/kdeglobals"' simple
assert_eq "…into [KDE], not the [General] copy KConfig never reads for it" "org.auros.simple.desktop" "$(kde_lnf "$CHOSEN_ROOT/etc/xdg/kdeglobals")"
assert_has "…and the [General] line is left as it was" "LookAndFeelPackage=wrong" "$(cat "$CHOSEN_ROOT/etc/xdg/kdeglobals")"
fresh_root; choose_case ':' simple >/dev/null
run_check layout.choose green "run again on the same image, simple then mac" -- choose_case ':' mac
assert_eq "…the second wins, with exactly one LookAndFeelPackage line in the file" \
  "1 org.auros.mac.desktop" "$(grep -c '^LookAndFeelPackage=' "$CHOSEN_ROOT/etc/xdg/kdeglobals") $(cat "$CHOSEN_ROOT/etc/auros/desktop-layout")"

# The build refuses a package that has no name in the helper — else no recipe could choose it.
NAME_BLOCK="$(extract_between "$W" '^install_file "\$SRC/set-desktop-layout"' '^did "recipes choose the layout')"
name_case() { # <sed program applied to a copy of the helper>
  local root; root="$(newroot)"; mkdir -p "$root/src"
  sed "$1" "$HELPER" > "$root/src/set-desktop-layout"
  SRC="$root/src" AUROS_LIBEXEC="$root/usr/libexec/auros" LNF_IDS="$LNF_IDS" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$2\")\"; cp \"\$1\" \"\$2\"; }
$NAME_BLOCK"
}
run_check layout.choose green "the build's name check, on the real helper" -- name_case ''
run_check layout.choose red   "the build's name check, on a helper that lost its mac line" -- name_case '/ID=org.auros.mac.desktop ;;/d'
assert_has "says no recipe could choose it" "no recipe could choose it" "$T_LAST_OUT"

# auros-first-run: the file decides; no file, or anything not shipped, means Windows.
FR_BLOCK="$(extract_between "$D/welcome/auros-first-run" '^# Which layout\. A recipe' '^echo "desktop-layout: \$LNF"' \
  | rootify /etc/auros/desktop-layout /usr/share/plasma/look-and-feel)"
firstrun_case() { # <content of /etc/auros/desktop-layout, or 'absent'>
  local root; root="$(newroot)"; mkdir -p "$root/etc/auros" "$root/usr/share/plasma/look-and-feel"
  cp -R "$D/lookandfeel/." "$root/usr/share/plasma/look-and-feel/"
  [ "$1" = absent ] || printf '%s\n' "$1" > "$root/etc/auros/desktop-layout"
  ROOT="$root" bash -c "$FR_BLOCK" | tail -1
}
assert_eq "first-run: no setting → the Windows layout" "desktop-layout: org.auros.windows.desktop" "$(firstrun_case absent)"
assert_eq "first-run: the mac setting → the mac layout" "desktop-layout: org.auros.mac.desktop" "$(firstrun_case org.auros.mac.desktop)"
assert_eq "first-run: the simple setting → the simple layout" "desktop-layout: org.auros.simple.desktop" "$(firstrun_case org.auros.simple.desktop)"
assert_eq "first-run: a well-formed id this image does not ship → Windows" "desktop-layout: org.auros.windows.desktop" "$(firstrun_case org.auros.nope.desktop)"
assert_eq "first-run: a path in the file → Windows" "desktop-layout: org.auros.windows.desktop" "$(firstrun_case ../../etc/passwd)"
assert_eq "first-run: an empty file → Windows" "desktop-layout: org.auros.windows.desktop" "$(firstrun_case '')"

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
EUU_FN="$(extract_fn "$REPO/build/00-common.sh" enable_user_unit | rootify /usr/lib/systemd/user)"

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
for uu in welcome/auros-first-run.service welcome/auros-choose-password.service compat/auros-bottles-setup.service; do
  assert_file "the repo ships $uu" "$D/$uu"
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "KDE plasma-setup is suppressed — first boot is ours alone (owner decision 2026-09-21)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# plasma-setup 6.7.5's unit runs before the display manager unless /etc/plasma-setup-done exists
# (files/plasma-setup.service.in). The build writes the marker and asserts the unit still keys on it.
PS_BLOCK="$(extract_between "$W" '^PS_DONE=/etc/plasma-setup-done' '^fi$' \
  | rootify /usr/lib/systemd/system/plasma-setup.service)"
# The two lines of the real 6.7.5 unit that decide whether it runs.
PS_REAL='ConditionPathExists=!/etc/plasma-setup-done
ConditionKernelCommandLine=!rd.live.image'

ps_case() { # <unit body or 'absent'> -> exit 0 iff the build accepted it; the marker must be written
  local root; root="$(newroot)"; mkdir -p "$root/usr/lib/systemd/system"
  [ "$1" = absent ] || printf '[Unit]\n%s\n' "$1" > "$root/usr/lib/systemd/system/plasma-setup.service"
  ROOT="$root" bash -c "$PRE
install_text() { mkdir -p \"\$ROOT\$(dirname \"\$1\")\"; cat > \"\$ROOT\$1\"; }
$PS_BLOCK" || return 1
  [ -s "$root/etc/plasma-setup-done" ] || { echo "no /etc/plasma-setup-done written"; return 1; }
}

run_check plasma-setup green "plasma-setup 6.7.5's own conditions" -- ps_case "$PS_REAL"
run_check plasma-setup green "plasma-setup not installed at all" -- ps_case absent
run_check plasma-setup red "KDE renamed the flag — our marker would suppress nothing" \
  -- ps_case 'ConditionPathExists=!/var/lib/plasma-setup/done'
assert_has "says the wizard would take seat0" "would take seat0" "$T_LAST_OUT"
run_check plasma-setup red "the unit has no done-flag condition — it runs every boot" \
  -- ps_case 'ConditionKernelCommandLine=!rd.live.image'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "with no wizard, who is at seat0 on first boot — the account gap detector"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Nothing creates an account today (no recipe field, no provisioning step). The detector must say
# NONE for that image — it is the shipping state — and must see the paths that would close the gap.
ACCT_BLOCK="$(extract_between "$W" '^FIRST_BOOT_ACCOUNT=none' '^fi$' \
  | rootify /etc/systemd/system/display-manager.service /etc/passwd /usr/lib/passwd \
            /etc/systemd/system/multi-user.target.wants /usr/lib/systemd/system/multi-user.target.wants)"

acct_case() { # <passwd lines> [kiosk] -> exit 0 iff some account path was found
  local root; root="$(newroot)"; mkdir -p "$root/etc/systemd/system"
  printf '%s\n' "$1" > "$root/etc/passwd"
  printf 'root:x:0:0:root:/root:/bin/bash\n' > "$root/usr/lib/passwd"
  if [ "${2:-}" = recipe ]; then mkdir -p "$root/usr/lib/systemd/system/multi-user.target.wants"
    ln -s ../auros-accounts.service "$root/usr/lib/systemd/system/multi-user.target.wants/auros-accounts.service"
    : > "$root/usr/lib/systemd/system/auros-accounts.service"; fi
  if [ "${2:-}" = kiosk ]; then ln -s /dev/null "$root/etc/systemd/system/display-manager.service"
  else ln -s /usr/lib/systemd/system/plasmalogin.service "$root/etc/systemd/system/display-manager.service"; fi
  ROOT="$root" bash -c "$PRE
$ACCT_BLOCK
echo \"seat0=\$FIRST_BOOT_ACCOUNT\"; [ \"\$FIRST_BOOT_ACCOUNT\" != none ]"
}
SYSTEM_ONLY='aurosprobe:x:980:980:Auros policy assertion probe:/var/lib/aurosprobe:/usr/bin/bash
auroskiosk:x:979:979::/var/lib/auroskiosk:/usr/sbin/nologin
nobody:x:65534:65534::/:/usr/sbin/nologin'
run_check first-boot.account red "today's image: system accounts only, a display manager — nobody to log in" \
  -- acct_case "$SYSTEM_ONLY"
assert_has "names the gap" "FIRST-BOOT ACCOUNT GAP" "$T_LAST_OUT"
run_check first-boot.account green "kiosk: the display manager is masked, auroskiosk has the seat" \
  -- acct_case "$SYSTEM_ONLY" kiosk
assert_has "and says so" "seat0=kiosk" "$T_LAST_OUT"
run_check first-boot.account green "a provisioned human account" -- acct_case "$SYSTEM_ONLY
teacher:x:1000:1000:Teacher:/var/home/teacher:/bin/bash"
assert_has "and names it" "seat0=users:teacher" "$T_LAST_OUT"
run_check first-boot.account green "the recipe path: auros-accounts is enabled and creates the accounts at first boot" \
  -- acct_case "$SYSTEM_ONLY" recipe
assert_has "and says so" "seat0=recipe" "$T_LAST_OUT"
run_check first-boot.account red "a uid-1000 account with no shell is not a person" -- acct_case "$SYSTEM_ONLY
svc:x:1001:1001::/:/sbin/nologin"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the accounts unit — installed with its ordering, and never with a secret"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ACC_BUILD="$(extract_between "$W" '^ENROL_DIR=/etc/auros/enrolment' '^enable_unit auros-accounts.service$' \
  | rootify /etc/auros/enrolment /usr/lib/systemd/system)"
# <mode>: ok | secret-in-image | no-chpasswd | unit-after-login
accb_case() {
  local root tools; root="$(newroot)"; tools="$(stubdir)"
  local t; for t in python3 getent useradd usermod chpasswd chage stat sha256sum grep mkdir cp dirname; do
    [ "$1" = no-chpasswd ] && [ "$t" = chpasswd ] && continue
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$t" 2>/dev/null || echo true)" | stub "$tools" "$t"
  done
  [ "$1" = secret-in-image ] && mkdir -p "$root/etc/auros/enrolment"
  mkdir -p "$root/usr/lib/systemd/system" "$root/usr/libexec/auros"
  ROOT="$root" AUROS_LIBEXEC="$root/usr/libexec/auros" SRC="$D" bash -c "$PRE
PATH='$tools'
install_file() { mkdir -p \"\$(dirname \"\$2\")\"; cp \"\$1\" \"\$2\"; }
enable_unit() { :; }
$( [ "$1" = unit-after-login ] && echo 'install_file() { mkdir -p "$(dirname "$2")"; grep -v "^Before=" "$1" > "$2"; }' )
$ACC_BUILD"
}
run_check accounts.build green "the shipped script, unit and drop-in" -- accb_case ok
run_check accounts.build red "an enrolment directory baked into the image" -- accb_case secret-in-image
assert_has "says a secret would be published" "published with it" "$T_LAST_OUT"
run_check accounts.build red "an image with no chpasswd" -- accb_case no-chpasswd
assert_has "names the missing tool" "needs chpasswd" "$T_LAST_OUT"
run_check accounts.build red "a unit that no longer runs before sign-in opens" -- accb_case unit-after-login
assert_has "names the lost ordering" "lost 'Before=display-manager.service" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "choose your own password — the session step ships only with the GUI it needs"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
CP_BUILD="$(extract_between "$W" '^# Choose your own password, once per account' '^enable_user_unit auros-choose-password.service')"
# <tools present, space-separated> <package manager installs kdialog: yes|no>
cp_case() {
  local tools t; tools="$(stubdir)"
  for t in $1; do printf '#!/bin/sh\nexit 0\n' | stub "$tools" "$t"; done
  printf '#!/bin/sh\n[ "%s" = yes ] && printf "#!/bin/sh\\n" > "%s/kdialog" && chmod +x "%s/kdialog"\n' "$2" "$tools" "$tools" | stub "$tools" pkgmgr
  bash -c "$PRE
PATH='$tools:/usr/bin:/bin'
SRC=/src AUROS_LIBEXEC=/libexec
auros_pkg_mgr() { echo pkgmgr; }
install_file() { :; }
enable_user_unit() { echo \"ENABLED \$1\"; }
$CP_BUILD"
}
run_check welcome.choose-password green "kdialog and kcmshell6 on the base"                -- cp_case "kdialog kcmshell6" no
run_check welcome.choose-password green "kdialog missing, installed from the repositories" -- cp_case "kcmshell6" yes
run_check welcome.choose-password red   "kdialog missing and not installable"              -- cp_case "kcmshell6" no
assert_has "names it" "needs kdialog" "$T_LAST_OUT"
run_check welcome.choose-password red   "no kcmshell6, so no Users page to choose it on"   -- cp_case "kdialog" no
assert_has "names it" "needs kcmshell6" "$T_LAST_OUT"

t_finish "40-windows-feel.sh"

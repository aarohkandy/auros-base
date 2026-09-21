#!/usr/bin/env bash
# Layout screenshots in the boot matrix — evidence, never a verdict. Every block under test is
# extracted from the shipping file.
#
#   gate      only the one screenshot profile asks for them; only the last full boot takes them
#   guest     layout_screens: for each layout, plasma-apply-lookandfeel -a <id> then evaluateScript,
#             then #AUROS-SCREEN# <nn>-<word>; a layout that cannot be put up is a SKIP line with a why
#   watcher   run-boot.sh's screen_watcher: one QMP screendump per head per announced layout, file
#             names <profile>-<nn>-<word>-<head>.png, every failure written to screenshots.tsv
#   summary   the one non-gating run-summary line
#   inert     none of it can emit a check record, and it runs after B11
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
AGENT_SH="$REPO/matrix/run/guest/auros-matrix-agent.sh"
RUN_BOOT="$REPO/matrix/run/run-boot.sh"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "gate: one profile, last full boot"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
PG="$(extract_between "$RUN_BOOT" '^SCREENSHOTS=0$' 'AUROS_SCREENSHOT_PROFILE:-uefi-modern')"
pg_case() { PROFILE="$1" bash -c "$PG"'
[ "$SCREENSHOTS" = 1 ]'; }
run_check gate green "uefi-modern takes screenshots" -- pg_case uefi-modern
run_check gate red "bios-legacy does not" -- pg_case bios-legacy
GG="$(extract_lines "$AGENT_SH" '^\[ "\$SCREENSHOTS" = 1 \] && ')"
gg_case() { grep -q shot <<<"$(SCREENSHOTS=$1 N=$2 FULL_BOOTS=2 bash -c 'layout_screens() { echo shot; }
'"$GG")"; }
run_check gate green "boot 2 of 2, asked: shoots" -- gg_case 1 2
run_check gate red "boot 1 of 2: does not (boot 2 must start in the default layout)" -- gg_case 1 1
run_check gate red "not asked: does not" -- gg_case 0 2

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "guest: each layout is applied the way auros-first-run applies it, then announced"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
GUEST="$(extract_lines "$AGENT_SH" '^SHOT_LAYOUTS=')
$(extract_fn "$AGENT_SH" apply_layout | rootify /usr/share/plasma)
$(extract_fn "$AGENT_SH" layout_screens)"
S="$(stubdir)"
for c in plasma-apply-lookandfeel gdbus kscreen-doctor loginctl pkill; do
  printf '#!/bin/sh\necho "%s $1 $2" >> "$CALLS"\n[ "%s" = "$FAIL" ] && exit 1\nexit 0\n' "$c" "$c" | stub "$S" "$c"
done
R="$(newroot)"
for id in windows shelf simple mac; do
  mkdir -p "$R/usr/share/plasma/look-and-feel/org.auros.$id.desktop/contents/layouts"
  echo "// $id" > "$R/usr/share/plasma/look-and-feel/org.auros.$id.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"
done
# guest_case <FAIL-stub> <WL> -> prints the announcements; exit 0 iff all four were announced, in order.
guest_case() {
  local calls; calls="$(newroot)/calls"
  PATH="$S:$PATH" ROOT="$R" CALLS="$calls" FAIL="$1" WL="$2" SESS=c2 TEST_USER=auros \
    SCREEN_SETTLE=0 SCREEN_HOLD=0 bash -c 'say() { printf "%s\n" "$*"; }; asuser() { "$@"; }
'"$GUEST"'
layout_screens || { echo "layout_screens returned non-zero"; exit 3; }' > "$calls.out"
  cat "$calls.out"; echo "--- calls"; cat "$calls" 2>/dev/null
  [ "$(grep -c '^#AUROS-SCREEN# ' "$calls.out")" = 4 ] || return 1
  [ "$(grep '^#AUROS-SCREEN# ' "$calls.out" | cut -d' ' -f2 | tr '\n' ' ')" = "01-windows 02-browser-first 03-simple 04-mac " ]
}
run_check guest green "four layouts, announced 01-windows .. 04-mac" -- guest_case none /run/user/1000/wayland-0
OUT="$T_LAST_OUT"
assert_has "browser-first is org.auros.shelf.desktop" "plasma-apply-lookandfeel -a org.auros.shelf.desktop" "$OUT"
assert_has "the layout script goes to plasmashell" "gdbus call --session" "$OUT"
assert_eq "apply then script, per layout, then windows re-applied last (10 calls)" 10 \
  "$(printf '%s\n' "$OUT" | sed -n '/^--- calls/,$p' | grep -cE '^(plasma-apply-lookandfeel|gdbus) ')"
assert_eq "…and the last one leaves Windows" "plasma-apply-lookandfeel -a org.auros.windows.desktop" \
  "$(printf '%s\n' "$OUT" | grep '^plasma-apply-lookandfeel' | tail -1)"
run_check guest red "plasmashell refuses the script: no layout is announced" -- guest_case gdbus /run/user/1000/wayland-0
assert_has "…each is a SKIP that says why" "#AUROS-SCREEN-SKIP# 04-mac plasmashell refused evaluateScript" "$T_LAST_OUT"
assert_not "…and the phase itself never fails" "returned non-zero" "$T_LAST_OUT"
run_check guest red "no graphical session: nothing is attempted" -- guest_case none ''
assert_has "…and it says so" "#AUROS-SCREEN-SKIP# 01-windows no graphical session" "$T_LAST_OUT"
assert_not "…without touching plasma" "plasma-apply-lookandfeel -a" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "watcher: a screendump per head per announced layout; failures recorded, never raised"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
HOST="$(extract_fn "$RUN_BOOT" shoot_one)
$(extract_fn "$RUN_BOOT" screen_watcher)
$(extract_fn "$RUN_BOOT" screen_summary)"
N="$(stubdir)"
# qmp.mjs's argv: <sock> screendump <timeout> <file> [device]. QMPFAIL=device|all makes QEMU refuse.
stub "$N" node <<'SH'
#!/usr/bin/env bash
shift; sock=$1 cmd=$2 file=$4 dev=${5:-}
echo "$cmd sock=$sock dev=${dev:-<console0>} $file" >> "$CALLS"
case "${QMPFAIL:-}" in
  all) echo "qmp: timed out after 10s waiting for screendump" >&2; exit 1;;
  device) [ -n "$dev" ] && { echo "qmp: screendump: GenericError: Device 'auros-gpu' not found" >&2; exit 1; };;
esac
printf 'PNG' > "$file"
SH
# watch_case <QMPFAIL> -> exit 0 iff all four PNGs exist and every row is ok
watch_case() {
  local d log; d="$(newroot)"; log="$d/agent.log"
  printf '%s\n' '#AUROS-BOOT# 2' '#AUROS-SCREEN# 01-windows locked=no' '#AUROS-SCREEN-SKIP# 02-browser-first plasma-apply-lookandfeel -a org.auros.shelf.desktop failed' \
    '#AUROS-SCREEN# 01-windows locked=no' '#AUROS-SCREEN# ../../etc/passwd' '#AUROS-SCREEN# 03-simple locked=yes' '#AUROS-DONE# full' > "$log"
  PATH="$N:$PATH" CALLS="$d/calls" SHOT_DIR="$d/shots" PROFILE=uefi-modern HARNESS_DIR=/h AUROS_POLL_INTERVAL=0 bash -c '
grep_file() { [ -f "$1" ] && grep -qaE "$2" "$1"; }
'"$HOST"'
mkdir -p "$SHOT_DIR"
screen_watcher "$1" /w/qmp 999999 || { echo "watcher returned non-zero"; exit 3; }
echo "--- tsv"; cat "$SHOT_DIR/screenshots.tsv"; echo "--- calls"; cat "$CALLS"; echo "--- files"; ls "$SHOT_DIR"
echo "--- summary"; screen_summary "$SHOT_DIR/screenshots.tsv"
for f in 01-windows-con0 01-windows-virtio-gpu 03-simple-con0 03-simple-virtio-gpu; do [ -s "$SHOT_DIR/uefi-modern-$f.png" ] || exit 1; done
! grep -qv -e ok -e skipped <<<"$(cut -f3 "$SHOT_DIR/screenshots.tsv")"' _ "$log"
}
QMPFAIL='' run_check watcher green "two layouts announced: four PNGs, both heads" -- watch_case
OUT="$T_LAST_OUT"
assert_has "files are <profile>-<nn>-<word>-<head>.png" "uefi-modern-03-simple-virtio-gpu.png" "$OUT"
assert_has "console 0 is dumped with no device" "screendump sock=/w/qmp dev=<console0>" "$OUT"
assert_has "the virtio head by its QOM id" "dev=auros-gpu" "$OUT"
assert_eq "a repeated announcement is shot once (4 dumps)" 4 "$(printf '%s\n' "$OUT" | grep -c '^screendump ')"
assert_not "a name that is a path is never a file name" "passwd" "$OUT"
assert_has "a guest SKIP is carried into the tsv" "02-browser-first	-	skipped	plasma-apply-lookandfeel" "$OUT"
assert_has "summary counts PNGs and says it gates nothing" "Layout screenshots (evidence only, gates nothing): 4 PNG(s) captured (2 while logind said the session was LOCKED" "$OUT"
QMPFAIL=device run_check watcher red "QEMU refuses the virtio head: those PNGs are missing" -- watch_case
assert_has "…the tsv says why" "virtio-gpu	fail	qmp: screendump: GenericError: Device 'auros-gpu' not found" "$T_LAST_OUT"
assert_not "…and the watcher did not fail" "watcher returned non-zero" "$T_LAST_OUT"
QMPFAIL=all run_check watcher red "QMP unreachable: no PNGs" -- watch_case
assert_has "…the summary line names the failure" "0 PNG(s) captured, 5 not:" "$T_LAST_OUT"

SM="$(extract_fn "$RUN_BOOT" screen_summary)"
run_check summary green "a tsv with a row: a count" -- bash -c "$SM"'
f=$(mktemp); printf "01-windows\tcon0\tok\tx.png\n" > "$f"; grep -q "1 PNG(s) captured" <<<"$(screen_summary "$f")"'
run_check summary red "no tsv at all: says NONE, not zero-and-fine" -- bash -c "$SM"'
s=$(screen_summary /nonexistent); echo "$s"; grep -q "PNG(s) captured" <<<"$s"'
assert_has "…and why" "NONE — the agent never reached the screenshot phase" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "inert: the screenshot code cannot record a check, and runs after B11"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
inert_case() { ! grep -qE '(^|[^_a-z])(emit|record) |#AUROS#' <<<"$1"; }
run_check inert green "guest and host screenshot code emit no #AUROS# record" -- inert_case "$GUEST
$HOST"
run_check inert red "(mutation) an emit inside it would be caught" -- inert_case "$GUEST
  emit B13 pass shot"
after_b11() { # exit 0 iff the layout_screens call comes after the last B11 emit
  local call b11
  call=$(grep -n '&& layout_screens$' "$1" | tail -1 | cut -d: -f1)
  b11=$(grep -n 'emit B11 ' "$1" | tail -1 | cut -d: -f1)
  [ -n "$call" ] && [ -n "$b11" ] && [ "$call" -gt "$b11" ]
}
run_check inert green "the shipping agent shoots after B11 is emitted" -- after_b11 "$AGENT_SH"
MOVED="$(newroot)/agent.sh"
awk '/&& layout_screens$/{next} /^# ── B11/{print "[ \"$SCREENSHOTS\" = 1 ] && [ \"$N\" -eq \"$FULL_BOOTS\" ] && layout_screens"} {print}' "$AGENT_SH" > "$MOVED"
run_check inert red "(mutation) shooting before B11 is caught" -- after_b11 "$MOVED"

t_finish "layout-screens"

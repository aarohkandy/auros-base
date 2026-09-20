#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/30-update-agent.test.sh — the safety-critical layer, against a synthetic fake root.
#
# THE PROPERTY THIS LAYER EXISTS FOR, and the one thing that can silently take it away:
#
#   greenboot declares a boot GREEN when every script in /etc/greenboot/check/required.d exits 0. So
#   A REQUIRED HEALTH CHECK THAT CANNOT FAIL DOES NOT MERELY PROVE NOTHING — IT DISABLES ROLLBACK
#   WHILE LOOKING INSTALLED. Every file is present, `greenboot-healthcheck.service` runs, the journal
#   says the boot was good, and a machine that boots to a black screen keeps the image that broke it.
#   In a school, with no terminal and no out-of-band console, that is a technician per laptop.
#
# So the core of this file is: run each required check against a BROKEN system and require it to say
# so. Four checks, each one driven into every failure branch it has. If any of them could not be made
# to fail, that is the finding, not a missing test.
#
# WHAT THIS FILE COULD NOT TEST AND WHY, stated rather than implied: nothing here proves that a real
# machine rolls back. That is check U3, in a VM, and it is the only thing that can prove it. What this
# proves is the layer beneath — that the mechanism which DECIDES to roll back is capable of deciding
# "no".
#
# THE SECOND THEME is layout versus capability. This build failed on
# `/usr/libexec/greenboot/greenboot-grub2-set-counter` because greenboot 0.16.4 reorganised and that
# path no longer exists. The response was NOT to write down the new path — the next release moves it
# again — but to assert the capability and print `rpm -ql greenboot` on failure so the real layout is
# learned from the package. The tests below pin that behaviour: a capability map that goes red must
# print the package's actual file list, or the next person guesses too.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

U="$REPO/build/30-update-agent.sh"
CHK="$REPO/update-agent/greenboot/check/required.d"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
# The shim (and any other stub) must be ahead of the real tools for every block this file runs.
# Without this the build scripts' GNU `sed -i` silently became a BSD `sed -i <suffix>` and corrupted
# the file it was meant to edit, while still exiting 0.
export PATH="$STUBS:$PATH"

printf '30-update-agent.sh — the safety-critical layer  (%s)\n' "$T_SED_MODE"

PRE='set -uo pipefail
step() { :; }
did()  { echo "DID $*"; }
found(){ echo "FOUND $*"; }
warn() { echo "WARN $*"; }
die()  { echo "DIE $*" >&2; exit 1; }
record(){ :; }
'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "greenboot — the capability map, not a remembered file list"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Each capability is satisfied by ANY of several paths, because greenboot has already moved them once
# and will again. What must never happen is the build passing with the rollback trigger absent: every
# other part of greenboot still looks correctly installed in that state, and check U3 becomes a story
# we tell rather than a thing that happens.
GB_BLOCK="$(extract_between "$U" '^_gb_missing=\(\)' '^did "greenboot capabilities verified' \
  | rootify /usr/libexec/greenboot /usr/lib/systemd/system /usr/lib/bootupd)"

# Which capabilities exist and which paths satisfy each, read OUT OF THE SHIPPING SCRIPT rather than
# restated here — so a capability added to 30-update-agent.sh is covered by the loop below on the
# same commit, with no second list to forget.
GB_MAP="$(awk '/^_gb_need /{ line=$0; while (line ~ /\\$/) { sub(/\\$/,"",line); getline nxt; line = line nxt } print line }' "$U")"
[ -n "$GB_MAP" ] || t_abort "30-update-agent.sh declares no _gb_need capabilities — this test would be vacuous"

gb_cap_of()   { printf '%s' "$1" | sed -E 's/^_gb_need +"([^"]*)".*/\1/'; }
gb_paths_of() { printf '%s' "$1" | tr ' ' '\n' | grep '^/' || true; }
ALL_GB_PATHS="$(printf '%s\n' "$GB_MAP" | while IFS= read -r l; do gb_paths_of "$l"; done | sort -u)"
[ -n "$ALL_GB_PATHS" ] || t_abort "could not read any candidate paths out of the _gb_need lines"

gb_root() { # <space-separated paths to OMIT> -> a fake image root with an rpm stub
  local omit=" $1 " root p
  root="$(newroot)"; mkdir -p "$root/bin"
  # The rpm stub's file list is deliberately NOT the layout the script expects. That is the whole
  # point of printing it: when the capability map goes red, the output has to show what the package
  # really ships so the next person reads it instead of guessing a second path.
  stub "$root/bin" rpm <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-ql" ] && { printf '%s\n' /usr/bin/greenboot-the-new-name /usr/lib/systemd/system/greenboot-v2.service; exit 0; }
exit 0
SH
  for p in $ALL_GB_PATHS; do
    case "$omit" in *" $p "*) continue ;; esac
    mkdir -p "$root$(dirname "$p")"
    [ -e "$root$p" ] || : > "$root$p"
  done
  printf '%s' "$root"
}
gb_run() { local root="$1"; PATH="$root/bin:$PATH" ROOT="$root" bash -c "$PRE
$GB_BLOCK"; }

run_check greenboot.capabilities green "every capability satisfied by the paths the script accepts" \
  -- gb_run "$(gb_root '')"

# One capability at a time: remove EVERY path that would satisfy it, leave the rest, and the build
# must refuse. Removing only one of several alternatives would prove nothing, because the map is
# explicitly a list of alternatives.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  cap="$(gb_cap_of "$line")"
  paths="$(gb_paths_of "$line" | tr '\n' ' ')"
  [ -n "$paths" ] || continue
  run_check greenboot.capabilities red "nothing provides: $cap" -- gb_run "$(gb_root "$paths")"
  assert_has "names the missing capability"      "$cap" "$T_LAST_OUT"
  assert_has "lists the paths it looked for"     "looked for" "$T_LAST_OUT"
  # THE PART THAT STOPS THE NEXT GUESS. The build failed once on a path greenboot had moved; the fix
  # was not a new path but printing the package's real file list, so the layout is learned once.
  assert_has "prints what the package ACTUALLY ships" "greenboot-the-new-name" "$T_LAST_OUT"
  assert_has "and refuses rather than continuing" "does not provide what auto-rollback needs" "$T_LAST_OUT"
done <<EOF
$GB_MAP
EOF

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the GRUB boot counter — the fragment that makes rollback a thing GRUB does"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Without boot_counter logic in GRUB's config there is no rollback, and EVERY OTHER PART of greenboot
# still looks correctly installed. So the check is on the CONTENT of the fragment, not its existence:
# a fragment that is present and says nothing about the counter is exactly the silent gap U3 exists
# to catch.
FRAG_BLOCK="$(extract_between "$U" '^GB_FRAGMENT=' '^did "GRUB boot-counter fragment present"' \
  | rootify /usr/lib/bootupd)"

frag_case() { # <'absent'|content>
  local root; root="$(newroot)"
  mkdir -p "$root/usr/lib/bootupd/grub2-static/configs.d"
  [ "$1" = absent ] || printf '%s\n' "$1" > "$root/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg"
  ROOT="$root" bash -c "$PRE
$FRAG_BLOCK"
}

run_check greenboot.grub-fragment green "a fragment containing boot_counter logic" \
  -- frag_case 'if [ -n "${boot_counter}" ]; then
  if [ "${boot_counter}" = "0" -o "${boot_counter}" = "-1" ]; then set default=1; fi
fi'
run_check greenboot.grub-fragment red "the fragment is absent entirely" -- frag_case absent
assert_has "explains that everything else still looks installed" "still looks correctly installed" "$T_LAST_OUT"
run_check greenboot.grub-fragment red "the fragment EXISTS but has no boot_counter logic in it" \
  -- frag_case '# greenboot
set timeout=5'
assert_has "says the fragment is present but empty of counter logic" "no boot_counter logic" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "GREENBOOT_MAX_BOOT_ATTEMPTS — 'fails twice ⇒ rollback' is literally 2"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Spec §6A sells "rolls back automatically if the new image fails to reach a login prompt twice".
# Upstream's default is 3. The difference between what we sell and what the machine does is this one
# edit, and the edit has to be idempotent because the whole build runs twice under check S7.
CONF_BLOCK="$(extract_between "$U" '^CONF=/etc/greenboot/greenboot.conf' '^record greenboot-max-boot-attempts' \
  | rootify /etc/greenboot)"

conf_case() { # <starting greenboot.conf body, or 'absent'> [repeat]
  local root; root="$(newroot)"; mkdir -p "$root/etc/greenboot"
  [ "$1" = absent ] || printf '%s\n' "$1" > "$root/etc/greenboot/greenboot.conf"
  ROOT="$root" AUROS_WRITTEN_LIST=/dev/null bash -c "$PRE
auros_stamp() { :; }
$CONF_BLOCK
${2:-}" && { printf '%s' "$root" > "$root/.ok"; cat "$root/etc/greenboot/greenboot.conf"; }
}

STOCK='GREENBOOT_MAX_BOOT_ATTEMPTS=3
DISABLED_HEALTHCHECKS=()'
run_check greenboot.max-attempts green "stock config with the upstream default of 3" -- conf_case "$STOCK"
assert_has "ends up at 2"                 "GREENBOOT_MAX_BOOT_ATTEMPTS=2" "$T_LAST_OUT"
assert_not "and 3 is gone, not shadowed"  "GREENBOOT_MAX_BOOT_ATTEMPTS=3" "$T_LAST_OUT"

run_check greenboot.max-attempts red "greenboot.conf does not exist" -- conf_case absent
run_check greenboot.max-attempts red "the config no longer defines DISABLED_HEALTHCHECKS" \
  -- conf_case 'GREENBOOT_MAX_BOOT_ATTEMPTS=3'
assert_has "says why that would break every boot" "no longer defines DISABLED_HEALTHCHECKS" "$T_LAST_OUT"

# Idempotence, because check S7 builds the image twice from the same input and compares digests. A
# second run that appended a second GREENBOOT_MAX_BOOT_ATTEMPTS=2 would leave the file with two of
# them — and the assertion inside the block is what catches that, so running the block twice must
# still be green and must still yield exactly one.
run_check greenboot.max-attempts green "running the whole block twice is idempotent" \
  -- conf_case "$STOCK" "$CONF_BLOCK"
assert_eq "exactly one MAX_BOOT_ATTEMPTS line after two runs" "1" \
  "$(printf '%s\n' "$T_LAST_OUT" | grep -c '^GREENBOOT_MAX_BOOT_ATTEMPTS=2$' | tr -d ' ')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "required.d — EVERY rollback trigger must be able to fire"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# This is the centre of the file. Each check is run against a healthy synthetic machine (must exit 0)
# and then against each specific breakage it claims to detect (must exit non-zero).
#
# The stub `sleep` is a no-op so that 20-graphical-target.sh's 120-second deadline costs nothing.
# Without it the failing case would take two minutes and somebody would delete it.
REQUIRED="$(ls "$CHK"/*.sh)"
assert_eq "required.d still has exactly 4 rollback triggers" "4" "$(printf '%s\n' $REQUIRED | grep -c . | tr -d ' ')"
for f in $REQUIRED; do
  grep -q 'AUROS_TEST_ROOT' "$f" || grep -qE 'nmcli|NetworkManager' "$f" \
    || bad "$(basename "$f") has neither a test seam nor a stubbable interface — it cannot be driven into failure, which means nothing proves it can fire"
done

mk_machine() { # -> a root with a bin/ of stubs; caller overwrites the ones it cares about
  local root; root="$(newroot)"; mkdir -p "$root/bin" "$root/usr/libexec/auros" "$root/usr/lib/systemd/system"
  stub "$root/bin" sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
  stub "$root/bin" bootc <<'SH'
#!/usr/bin/env bash
echo "bootc 1.16.10"
SH
  printf '#!/bin/sh\nexit 0\n' > "$root/usr/libexec/auros/auros-update"; chmod 0755 "$root/usr/libexec/auros/auros-update"
  printf '%s' "$root"
}
run_chk() { # <root> <script>
  env -i PATH="$1/bin:/usr/bin:/bin:/usr/sbin:/sbin" AUROS_TEST_ROOT="$1" HOME="$1" bash "$2"
}

# ── 10-network-stack.sh ──────────────────────────────────────────────────────────────────────────
# It deliberately proves the local network STACK and never connectivity: a required check that needed
# the internet would roll a whole school back over a broadband outage, and then roll back again from
# there, which is the fallback boot and needs a technician per machine (U5).
net_machine() { # <NM active?> <nmcli present?> <nmcli answers?>
  local root; root="$(mk_machine)"
  stub "$root/bin" systemctl <<SH
#!/usr/bin/env bash
case "\$*" in *NetworkManager*) [ "$1" = yes ] && exit 0 || { echo inactive; exit 3; } ;; esac
exit 0
SH
  if [ "$2" = yes ]; then
    stub "$root/bin" nmcli <<SH
#!/usr/bin/env bash
[ "$3" = yes ] || exit 1
case "\$*" in *RUNNING*) echo running ;; *STATE*) echo connected ;; *) echo "" ;; esac
SH
  fi
  printf '%s' "$root"
}
run_check gb.10-network green "NetworkManager active and answering"         -- run_chk "$(net_machine yes yes yes)" "$CHK/10-network-stack.sh"
run_check gb.10-network red   "NetworkManager is not active"                -- run_chk "$(net_machine no  yes yes)" "$CHK/10-network-stack.sh"
run_check gb.10-network red   "nmcli is missing, so the stack cannot be inspected" -- run_chk "$(net_machine yes no yes)" "$CHK/10-network-stack.sh"
run_check gb.10-network red   "NetworkManager is active but not answering nmcli"   -- run_chk "$(net_machine yes yes no)" "$CHK/10-network-stack.sh"

# And the property that must NOT make it fail: an offline machine. This is the whole reason the check
# is written the way it is, so it is asserted rather than assumed.
R="$(net_machine yes yes yes)"
stub "$R/bin" nmcli <<'SH'
#!/usr/bin/env bash
case "$*" in *RUNNING*) echo running ;; *STATE*) echo disconnected ;; *) echo "" ;; esac
SH
run_check gb.10-network green "the machine is OFFLINE — must still be a pass (U5)" -- run_chk "$R" "$CHK/10-network-stack.sh"
assert_has "and says connectivity is not asserted" "intentionally NOT asserted" "$T_LAST_OUT"

# ── 20-graphical-target.sh ───────────────────────────────────────────────────────────────────────
# The runtime half of B1. Without it a machine that boots to a black screen is, as far as greenboot
# is concerned, perfectly healthy — and it would keep the image that broke it.
dm_machine() { # <image has a display manager?> <dm state> <graphical.target state>
  local root; root="$(mk_machine)"
  [ "$1" = yes ] && : > "$root/usr/lib/systemd/system/display-manager.service"
  stub "$root/bin" systemctl <<SH
#!/usr/bin/env bash
case "\$*" in
  *display-manager.service*) echo "$2" ;;
  *graphical.target*)        echo "$3" ;;
  *) echo unknown ;;
esac
exit 0
SH
  printf '%s' "$root"
}
run_check gb.20-graphical green "a display manager is present and reaches active" -- run_chk "$(dm_machine yes active inactive)" "$CHK/20-graphical-target.sh"
run_check gb.20-graphical red   "a display manager is present and FAILED"          -- run_chk "$(dm_machine yes failed  active)"   "$CHK/20-graphical-target.sh"
assert_has "says there is no login prompt" "there is no login prompt" "$T_LAST_OUT"
run_check gb.20-graphical red   "a display manager is present and never becomes active" -- run_chk "$(dm_machine yes activating inactive)" "$CHK/20-graphical-target.sh"
# A kiosk image has no display manager by design (D12). It must not pass unconditionally — the
# graphical stack still has to come up or the kiosk session has nothing to draw on.
run_check gb.20-graphical green "no display manager (kiosk), and graphical.target is active" -- run_chk "$(dm_machine no inactive active)" "$CHK/20-graphical-target.sh"
run_check gb.20-graphical red   "no display manager AND graphical.target never comes up"      -- run_chk "$(dm_machine no inactive inactive)" "$CHK/20-graphical-target.sh"
assert_has "says the machine has no usable screen" "no usable screen" "$T_LAST_OUT"

# ── 30-update-timer-enabled.sh ───────────────────────────────────────────────────────────────────
# "A machine that can't update is a machine we abandoned." Required, not wanted, for that reason.
tmr_machine() { # <is-enabled> <is-active> <wrapper: present|missing> <bootc: present|missing>
  local root; root="$(mk_machine)"
  stub "$root/bin" systemctl <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  is-enabled) echo "$1"; [ "$1" = enabled ] || [ "$1" = enabled-runtime ] || exit 1 ;;
  is-active)  echo "$2"; [ "$2" = active ] || exit 3 ;;
  show)       echo "Mon 2026-09-21 04:00:00 UTC" ;;
esac
exit 0
SH
  cat > "$root/bin/systemctl" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  is-enabled) echo "$1"; [ "$1" = enabled ] || [ "$1" = enabled-runtime ] || exit 1 ;;
  is-active)  echo "$2"; [ "$2" = active ] || exit 3 ;;
  show)       echo "Mon 2026-09-21 04:00:00 UTC" ;;
  *) exit 0 ;;
esac
SH
  chmod 0755 "$root/bin/systemctl"
  [ "$3" = missing ] && rm -f "$root/usr/libexec/auros/auros-update"
  [ "$4" = missing ] && rm -f "$root/bin/bootc"
  printf '%s' "$root"
}
run_check gb.30-timer green "the timer is enabled and active, the wrapper is there"  -- run_chk "$(tmr_machine enabled active present present)" "$CHK/30-update-timer-enabled.sh"
run_check gb.30-timer red   "the timer is DISABLED — this machine would never update" -- run_chk "$(tmr_machine disabled active present present)" "$CHK/30-update-timer-enabled.sh"
assert_has "says it would never fetch another update" "never fetch another update" "$T_LAST_OUT"
run_check gb.30-timer red   "the timer is masked"                                     -- run_chk "$(tmr_machine masked inactive present present)" "$CHK/30-update-timer-enabled.sh"
run_check gb.30-timer red   "enabled but not scheduled — the silent half"             -- run_chk "$(tmr_machine enabled inactive present present)" "$CHK/30-update-timer-enabled.sh"
assert_has "says it is not scheduled to run" "not scheduled to run" "$T_LAST_OUT"
run_check gb.30-timer red   "the ExecStart wrapper is gone"                           -- run_chk "$(tmr_machine enabled active missing present)" "$CHK/30-update-timer-enabled.sh"
assert_has "says the update run would fail every time" "fail every time" "$T_LAST_OUT"
run_check gb.30-timer red   "bootc itself is not installed"                           -- run_chk "$(tmr_machine enabled active present missing)" "$CHK/30-update-timer-enabled.sh"

# ── 40-no-new-failed-units.sh ────────────────────────────────────────────────────────────────────
# Fully covered, in both directions, by update-agent/tests/run-tests.sh section D — which owns the
# green.d/red.d interaction this check depends on. Repeating it here would be a second copy that
# drifts. The one thing asserted here is that the file still carries the seam that makes those tests
# possible, because losing it would make them silently test the laptop instead of the image.
grep -q 'AUROS_TEST_ROOT' "$CHK/40-no-new-failed-units.sh" \
  && ok "40-no-new-failed-units.sh keeps its test seam (covered by update-agent/tests/run-tests.sh D1-D7)" \
  || bad "40-no-new-failed-units.sh lost its AUROS_TEST_ROOT seam — update-agent/tests would silently start testing the host"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the update timer is protected from pruning, and named identically everywhere"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# 30-update-agent.sh's own die message says it out loud: if the unit is ever renamed, "change this
# script AND the greenboot check 30-update-timer-enabled.sh together". Nothing enforced that. Two
# files naming two different units would leave a machine whose build enables one timer and whose
# health check demands another — which fails every boot, forever, and rolls every machine back.
BUILD_TIMER="$(grep -E '^TIMER_UNIT=' "$U" | head -1 | sed 's#.*/##')"
CHECK_TIMER="$(grep -E '^TIMER=' "$CHK/30-update-timer-enabled.sh" | head -1 | cut -d= -f2-)"
[ -n "$BUILD_TIMER" ] || t_abort "could not read TIMER_UNIT out of 30-update-agent.sh"
[ -n "$CHECK_TIMER" ] || t_abort "could not read TIMER out of 30-update-timer-enabled.sh"
assert_eq "the build and the health check name the same timer" "$BUILD_TIMER" "$CHECK_TIMER"

# And the protected set must name it too, or a recipe could prune the update path and check S10 would
# have nothing to catch it with.
PLIST="$REPO/hardening/protected.list"
assert_has "protected.list protects the update timer" "$BUILD_TIMER" "$(cat "$PLIST")"
assert_has "protected.list protects bootc itself"     "	cmd	bootc" "$(cat "$PLIST")"
assert_has "protected.list protects greenboot"        "	pkg	greenboot" "$(cat "$PLIST")"

# The timer is also in the runtime assertion's candidate list, which is the one place D22's finding
# lives: uupd.timer, not bootc's timer, is what Aurora preset-enables. A list missing one of them
# would report a perfectly-patched machine as un-patched, or the reverse.
ALIB="$REPO/policy/lib/assert-lib.sh"
if [ -f "$ALIB" ]; then
  TIMERS="$(grep -E '^A_UPDATE_TIMERS=' "$ALIB" | head -1)"
  assert_has "the policy layer's timer list includes bootc's timer" "$BUILD_TIMER" "$TIMERS"
  assert_has "and uupd.timer, which D22 identifies as the real driver on this base" "uupd.timer" "$TIMERS"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "every shipped health check parses, and greenboot will actually run it"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# greenboot globs '*.sh' and sorts by name. A check whose filename does not end in .sh is a check
# that never runs, and a check that does not parse fails on every boot of every machine — which in
# required.d means rolling back every image forever.
for d in check/required.d check/wanted.d green.d red.d; do
  n=0
  for f in "$REPO/update-agent/greenboot/$d"/*; do
    [ -e "$f" ] || continue
    n=$((n+1))
    case "$f" in *.sh) ;; *) bad "$d/$(basename "$f") does not end in .sh — greenboot would never run it"; continue ;; esac
    bash -n "$f" 2>/dev/null || { bad "$d/$(basename "$f") does not parse — it would fail on every boot"; continue; }
  done
  [ "$n" -gt 0 ] && ok "$d: $n script(s), all named *.sh and all parse" \
                 || bad "$d is empty — the build asserts it is not"
done

t_finish "30-update-agent.sh"

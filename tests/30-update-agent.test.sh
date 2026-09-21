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


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "required.d — the COUNT, because every required check is a rollback trigger"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The file says it in capitals: EVERY REQUIRED CHECK IS A ROLLBACK TRIGGER. A fifth one added
# quietly gives a school a fifth way to have every laptop roll back overnight, and the build's own
# assertion is `[ "$req" = "4" ]`. Relaxed to `-ge 4` that assertion can only notice deletions.
#
# The suite already counts the scripts in the REPO. This counts what the BUILD would accept, which
# is a different question and the one the assertion is actually making.
REQ_BLOCK="$(extract_between "$U" '^req="' '^did "4 required checks' \
  | rootify /usr/lib/greenboot/check/required.d)"

req_run() { # <root> <n scripts>
  local root="$1" n="$2" i
  mkdir -p "$root/usr/lib/greenboot/check/required.d"
  i=1; while [ "$i" -le "$n" ]; do printf '#!/usr/bin/bash\nexit 0\n' > "$root/usr/lib/greenboot/check/required.d/${i}0-x.sh"; i=$((i+1)); done
  ROOT="$root" bash -c "$PRE
$REQ_BLOCK"
}

R="$(newroot)"; run_check gb.required-count green "exactly 4 required checks" -- req_run "$R" 4
assert_has "says how many rollback triggers there are" "4 required checks (rollback triggers)" "$T_LAST_OUT"
R="$(newroot)"; run_check gb.required-count red "a FIFTH rollback trigger was added quietly" -- req_run "$R" 5
assert_has "names the count it found"      "found 5"            "$T_LAST_OUT"
assert_has "and says where the decision belongs" "DECISIONS.md"  "$T_LAST_OUT"
R="$(newroot)"; run_check gb.required-count red "one required check was deleted" -- req_run "$R" 3
R="$(newroot)"; run_check gb.required-count red "none of them installed" -- req_run "$R" 0

# And the repository and the build must agree about the number, or one of them is wrong.
assert_eq "the repo ships exactly the 4 the build asserts" "4" \
  "$(find "$CHK" -name '*.sh' | wc -l | tr -d ' ')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "health checks — the build REFUSES a check that cannot parse"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# A required check that does not parse exits non-zero on every boot. greenboot reads that as a
# failed boot, decrements the counter, and after two boots rolls the machine back — to an image
# which, if the broken check shipped in the base, also has it. That is every machine in a school
# stuck in a rollback loop, and it is a syntax error.
#
# The suite already parses the scripts in the repo directly. That is not the same assertion: it
# proves the current scripts are fine, not that the BUILD would refuse a bad one. `bash -n` here is
# the gate, and deleting it leaves both the scripts and this suite green.
HC_BLOCK="$(extract_between "$U" '^for dir in check/required\.d' '^done$')"

hc_run() { # <root> [extra-file-name] [extra-file-body]
  local root="$1" d
  for d in check/required.d check/wanted.d green.d red.d; do
    mkdir -p "$root/ua/greenboot/$d"
    printf '#!/usr/bin/bash\nexit 0\n' > "$root/ua/greenboot/$d/10-ok.sh"
  done
  [ -n "${2:-}" ] && printf '%s\n' "$3" > "$root/ua/greenboot/check/required.d/$2"
  ROOT="$root" UA="$root/ua" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$ROOT\$2\")\"; install -m \"\${3:-0644}\" \"\$1\" \"\$ROOT\$2\"; did \"wrote \$2\"; }
$HC_BLOCK"
}

R="$(newroot)"
run_check gb.checks-parse green "every shipped check parses" -- hc_run "$R"
assert_file "the required check was installed into /usr/lib, not /etc" "$R/usr/lib/greenboot/check/required.d/10-ok.sh"
assert_file "and so were the wanted checks"                            "$R/usr/lib/greenboot/check/wanted.d/10-ok.sh"
assert_file "and green.d"                                              "$R/usr/lib/greenboot/green.d/10-ok.sh"
assert_file "and red.d"                                                "$R/usr/lib/greenboot/red.d/10-ok.sh"

# THE REFUSAL. `if then` with no condition is the ordinary shape of a half-finished edit.
R="$(newroot)"
run_check gb.checks-parse red "a required check that does not parse" -- hc_run "$R" 99-broken.sh 'if then
  echo hi
fi'
assert_has "says the file is not valid bash"          "is not valid bash"           "$T_LAST_OUT"
assert_has "and what it would cost"                   "fails on every boot"          "$T_LAST_OUT"
assert_nofile "and refused to install it"             "$R/usr/lib/greenboot/check/required.d/99-broken.sh"

R="$(newroot)"
run_check gb.checks-parse red "an unterminated quote in a check" -- hc_run "$R" 98-quote.sh 'echo "unterminated'

# A directory with no scripts in it at all is a silently disarmed stage.
R="$(newroot)"
for d in check/required.d check/wanted.d green.d red.d; do mkdir -p "$R/ua/greenboot/$d"; done
run_check gb.checks-parse red "a greenboot directory with no scripts in it" -- bash -c "$PRE
install_file() { :; }
ROOT='$R' UA='$R/ua'
$HC_BLOCK"
assert_has "names the empty directory" "no scripts in" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the ExecStart drop-in — systemd APPENDS unless the drop-in clears it first"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# A drop-in that sets ExecStart without an empty `ExecStart=` line first does not REPLACE the vendor
# command, it adds to it. The machine then runs bootc's `--apply` (which reboots as soon as a
# deployment is staged) AND ours (which waits until nobody is using the laptop) — so it reboots out
# from under a logged-in student, in exactly the case our wrapper exists to prevent.
#
# `grep -qx 'ExecStart='` is an exact whole-line match for the CLEARING line. Weakened to `grep -q`
# it matches `ExecStart=/usr/libexec/auros/auros-update` — the very line whose presence is not the
# question — and can never fail.
EXEC_BLOCK="$(extract_between "$U" "^grep -q.*'ExecStart='" 'does not clear ExecStart' \
  | rootify /usr/lib/systemd/system)"

exec_run() { # <root> <drop-in body>
  local root="$1"
  mkdir -p "$root/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d"
  printf '%s\n' "$2" > "$root/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-auros.conf"
  ROOT="$root" bash -c "$PRE
$EXEC_BLOCK"
}

R="$(newroot)"
run_check update.execstart green "the drop-in we actually ship" \
  -- exec_run "$R" "$(cat "$REPO/update-agent/systemd/bootc-fetch-apply-updates.service.d/10-auros.conf")"

# THE ONE THAT MATTERS: ours is set, the vendor's is never cleared.
R="$(newroot)"
run_check update.execstart red "ExecStart is set but never cleared — systemd would run BOTH commands" \
  -- exec_run "$R" '[Service]
ExecStart=/usr/libexec/auros/auros-update'
assert_has "explains that both commands would run" "both bootc" "$T_LAST_OUT"

R="$(newroot)"
run_check update.execstart red "the drop-in has no ExecStart lines at all" -- exec_run "$R" '[Service]
Nice=10'

# A commented clearing line is not a clearing line.
R="$(newroot)"
run_check update.execstart red "the clearing line is commented out" -- exec_run "$R" '[Service]
#ExecStart=
ExecStart=/usr/libexec/auros/auros-update'

# And the shipped file must be the thing that passes, or the check and the payload disagree.
assert_has "the shipped drop-in clears ExecStart first" "
ExecStart=
ExecStart=/usr/libexec/auros/auros-update" \
  "$(cat "$REPO/update-agent/systemd/bootc-fetch-apply-updates.service.d/10-auros.conf")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the signing key — which key, and never a private one"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# This block had NO tests, and it is the block that decides what a customer's machine will trust for
# the rest of its life. Two specific failures are each one operator away:
#
#   `[ ! -s prod ] && [ -s dev ]` -> `||`   the DEVELOPMENT key is used even when a production key
#                                           exists, and the image RECORDS ITSELF as production —
#                                           so the publish guard that reads the kind back out of
#                                           the image waves it through.
#   the PRIVATE-key refusal made never-match  a private signing key is baked into every customer
#                                           image, and the build log says "key in /usr".
KEY_BLOCK="$(extract_between "$U" '^KEY_SRC="\$SIGN/keys/auros\.pub"' '^found "key in /usr' \
  | rootify /usr/lib/auros /usr/lib/pki/containers)"

REAL_DEV_KEY="$REPO/signing/keys/auros-development.pub"
[ -s "$REAL_DEV_KEY" ] || t_abort "signing/keys/auros-development.pub is missing — this group would be testing invented keys only"
FAKE_PROD_KEY='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEcHJvZHVjdGlvbktleUZpeHR1cmVG
b3JBdXJvc1Rlc3RzT25seU5vdEFSZWFsS2V5QUFBQUFBQUFBQT09
-----END PUBLIC KEY-----'

key_run() { # <root> <prod-key-body|''> <dev-key-body|''>
  local root="$1"
  mkdir -p "$root/sign/keys" "$root/usr/lib/auros" "$root/usr/lib/pki/containers"
  [ -n "$2" ] && printf '%s\n' "$2" > "$root/sign/keys/auros.pub"
  [ -n "$3" ] && printf '%s\n' "$3" > "$root/sign/keys/auros-development.pub"
  ROOT="$root" SIGN="$root/sign" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$2\")\"; install -m \"\${3:-0644}\" \"\$1\" \"\$2\"; did \"wrote \$2\"; }
$KEY_BLOCK"
}

R="$(newroot)"
run_check signing.key green "only the development key is present" -- key_run "$R" '' "$(cat "$REAL_DEV_KEY")"
assert_eq  "the image records itself as development" "development" "$(cat "$R/usr/lib/auros/signing-key-kind" 2>/dev/null || true)"
assert_has "and the build says so out loud"          "DEVELOPMENT signing key" "$T_LAST_OUT"
assert_has "naming the thing it cannot do"           "CANNOT be published"     "$T_LAST_OUT"

R="$(newroot)"
run_check signing.key green "only a production key is present" -- key_run "$R" "$FAKE_PROD_KEY" ''
assert_eq  "the image records itself as production" "production" "$(cat "$R/usr/lib/auros/signing-key-kind" 2>/dev/null || true)"

# THE SELECTION. Both keys on disk is the ordinary state once a human has minted the production key
# and nobody has deleted the development one. Production must win, and the INSTALLED BYTES must be
# the production key's — otherwise every machine verifies against a throwaway credential while the
# image, and therefore the publish guard, says "production".
R="$(newroot)"
run_check signing.key green "BOTH keys are present — production must win" -- key_run "$R" "$FAKE_PROD_KEY" "$(cat "$REAL_DEV_KEY")"
assert_eq  "recorded as production" "production" "$(cat "$R/usr/lib/auros/signing-key-kind" 2>/dev/null || true)"
assert_eq  "and the key that was installed is the PRODUCTION key, byte for byte" \
  "$FAKE_PROD_KEY" "$(cat "$R/usr/lib/pki/containers/auros.pub" 2>/dev/null || true)"
assert_not "the development key was not installed" "$(sed -n '2p' "$REAL_DEV_KEY")" \
  "$(cat "$R/usr/lib/pki/containers/auros.pub" 2>/dev/null || true)"
assert_not "and no development warning was printed" "DEVELOPMENT signing key" "$T_LAST_OUT"

# An empty production key file is not a production key. `-s`, not `-e`: a zero-byte auros.pub is
# what `touch` leaves behind, and treating it as present would select nothing at all.
R="$(newroot)"
mkdir -p "$R/sign/keys"; : > "$R/sign/keys/auros.pub"
run_check signing.key green "a ZERO-BYTE auros.pub falls through to the development key" \
  -- key_run "$R" '' "$(cat "$REAL_DEV_KEY")"

R="$(newroot)"
run_check signing.key red "neither key exists" -- key_run "$R" '' ''
assert_has "refuses the build rather than completing it" "REFUSED rather than completed" "$T_LAST_OUT"
assert_has "and explains what the image would do"        "refuse every update"            "$T_LAST_OUT"

R="$(newroot)"
run_check signing.key red "the key file is not a PEM public key" -- key_run "$R" 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 auros@example' ''
assert_has "says what it is not" "not a PEM public key" "$T_LAST_OUT"

# THE PRIVATE KEY. A PEM carrying both halves passes `BEGIN PUBLIC KEY` and would be installed into
# /usr/lib/pki/containers on every customer machine. This is the refusal that has to work.
for priv in 'PRIVATE KEY' 'EC PRIVATE KEY' 'RSA PRIVATE KEY' 'ENCRYPTED PRIVATE KEY'; do
  R="$(newroot)"
  run_check signing.key red "the key file also carries a $priv block" -- key_run "$R" "$FAKE_PROD_KEY
-----BEGIN $priv-----
bm90YXJlYWxwcml2YXRla2V5YnV0aXRsb29rc2xpa2VvbmU=
-----END $priv-----" ''
  assert_has "says it contains a PRIVATE key" "contains a PRIVATE key" "$T_LAST_OUT"
  assert_nofile "and installed nothing"       "$R/usr/lib/pki/containers/auros.pub"
done

# The keys we actually ship must be the ones that pass. Checked against the payload, not recited.
assert_has "the development key is a PEM public key" "BEGIN PUBLIC KEY" "$(cat "$REAL_DEV_KEY")"
assert_not "and carries no private half"             "PRIVATE KEY"      "$(cat "$REAL_DEV_KEY")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "policy.json — the embedded validator, which is the whole of D8"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# D8: Aurora's base policy ends in a docker "" catch-all of insecureAcceptAnything, so
# `bootc switch --enforce-container-sigpolicy` succeeds while verifying nothing. Every piece of the
# fix looks like success on its own. This validator is what makes the combination checkable at build
# time, and it had no tests at all — so each of its refusals was a line of Python nobody had ever
# seen say no.
#
# The validator is EXTRACTED from the heredoc in build/30-update-agent.sh and run as a program.
# Nothing here re-implements it.
VALIDATOR_SRC="$(extract_raw "$U" '^import json,sys$' '^PY$' | sed '$d')"
case "$VALIDATOR_SRC" in
  *"insecureAcceptAnything"*) ;;
  *) t_abort "the extracted policy.json validator does not mention insecureAcceptAnything — the heredoc moved and this group is testing something else" ;;
esac
VALIDATOR="$(newroot)/validate_policy.py"
printf '%s\n' "$VALIDATOR_SRC" > "$VALIDATOR"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$VALIDATOR" \
  || t_abort "the extracted validator is not valid python — the extraction range is wrong, and every 'red' case below would pass for the wrong reason"

SCOPE="ghcr.io/aarohkandy"
pol_run() { # <json>
  local f; f="$(newroot)/policy.json"
  printf '%s\n' "$1" > "$f"
  python3 "$VALIDATOR" "$f" "$SCOPE"
}

# The real file, with the scope substituted exactly as the build does it.
REAL_POLICY="$(sed "s|@AUROS_SCOPE@|$SCOPE|g" "$REPO/signing/policy.json")"
run_check signing.policy green "the policy.json we actually ship" -- pol_run "$REAL_POLICY"
assert_has "names the scope and the key it resolved" "sigstoreSigned(/usr/lib/pki/containers/auros.pub, matchRepository)" "$T_LAST_OUT"
assert_has "and PRINTS the consequence of the catch-all rather than filing it as a footnote" \
  "AND NOTHING ELSE" "$T_LAST_OUT"

# ── the global default ───────────────────────────────────────────────────────────────────────────
# bootc's enforce-container-sigpolicy guard reads the GLOBAL DEFAULT ONLY. A default of
# insecureAcceptAnything is the D8 failure itself: everything else in the file can be perfect.
run_check signing.policy red "the global default is insecureAcceptAnything — the D8 failure" -- pol_run '{
  "default": [{ "type": "insecureAcceptAnything" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }] } }
}'
assert_has "names the guard that would reject the image" "enforce-container-sigpolicy" "$T_LAST_OUT"
run_check signing.policy red "there is no global default at all" -- pol_run '{
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }] } }
}'

# ── the scoped rule ──────────────────────────────────────────────────────────────────────────────
run_check signing.policy red "no transports.docker entry for our scope — the D8 failure, in our own file" -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "ghcr.io/someoneelse": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }] } }
}'
run_check signing.policy red "the scope entry exists but is not sigstoreSigned" -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "insecureAcceptAnything" }] } }
}'

# ── signedIdentity ───────────────────────────────────────────────────────────────────────────────
# cosign signatures carry only a repository. matchExact is containers/image's DEFAULT, and it would
# reject every signature we make — which means no machine ever updates again, and, worse, it would
# make check U4's negative test pass for the wrong reason.
for si in matchExact matchRepoDigestOrExact remapIdentity; do
  run_check signing.policy red "signedIdentity is $si" -- pol_run '{
    "default": [{ "type": "reject" }],
    "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "'"$si"'" } }] } }
  }'
  assert_has "explains that cosign carries only a repository" "cosign signatures carry only a repository" "$T_LAST_OUT"
done
run_check signing.policy green "signedIdentity is exactRepository" -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "exactRepository" } }] } }
}'
run_check signing.policy red "signedIdentity is missing entirely, so the default matchExact applies" -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub" }] } }
}'

# ── keyPath ──────────────────────────────────────────────────────────────────────────────────────
# A policy pointing at a key that is not there means every update is refused for the life of the
# machine — in a school, months later, with no terminal. The path is where the build puts the key
# and nowhere else.
for kp in /etc/pki/other.pub /usr/lib/pki/containers/aurora.pub /usr/share/pki/auros.pub; do
  run_check signing.policy red "keyPath is $kp" -- pol_run '{
    "default": [{ "type": "reject" }],
    "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "'"$kp"'", "signedIdentity": { "type": "matchRepository" } }] } }
  }'
  assert_has "names the path it found" "unexpected keyPath" "$T_LAST_OUT"
done

# ── the docker "" catch-all ──────────────────────────────────────────────────────────────────────
# Two answers are reviewed and written down: insecureAcceptAnything (the recorded trade) and reject
# (the strict alternative). ANY THIRD ANSWER is how a policy stops meaning what its documentation
# says — and `signedBy` with somebody else's key is a third answer that looks perfectly reasonable
# in a diff.
run_check signing.policy green 'transports.docker[""] rejects — the strict alternative' -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }], "": [{ "type": "reject" }] } }
}'
assert_has "says what that buys" "can be pulled" "$T_LAST_OUT"
run_check signing.policy green 'there is no transports.docker[""] entry at all' -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }] } }
}'
assert_has "says the global default applies instead" "the global default (reject) applies" "$T_LAST_OUT"
run_check signing.policy red 'transports.docker[""] is signedBy someone else key — an unreviewed third answer' -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }], "": [{ "type": "signedBy", "keyPath": "/usr/lib/pki/containers/someoneelse.pub" }] } }
}'
assert_has "says an unreviewed option is the failure mode" "unreviewed third option" "$T_LAST_OUT"
run_check signing.policy red 'transports.docker[""] mixes reject and insecureAcceptAnything' -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }], "": [{ "type": "reject" }, { "type": "insecureAcceptAnything" }] } }
}'

# ── strictness that containers/image itself imposes ──────────────────────────────────────────────
# ParanoidUnmarshalJSONObject ERRORS on an unrecognised key rather than ignoring it. A "$comment"
# would stop the policy loading, and a policy that does not load is a machine that cannot pull
# anything at all — including its own updates.
run_check signing.policy red "an explanatory top-level key that containers/image would reject" -- pol_run '{
  "$comment": "explaining the policy inside the policy",
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" } }] } }
}'
assert_has "says they are rejected, not ignored" "it does not ignore them" "$T_LAST_OUT"
run_check signing.policy red "an unrecognised key inside a requirement" -- pol_run '{
  "default": [{ "type": "reject" }],
  "transports": { "docker": { "'"$SCOPE"'": [{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub", "signedIdentity": { "type": "matchRepository" }, "comment": "why" }] } }
}'
run_check signing.policy red "the file does not parse as JSON at all" -- pol_run '{ "default": [ }'
assert_has "says so plainly" "does not parse" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "registries.d — a more specific scope in another file turns verification off silently"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# containers-registries.d(5): only the MOST-PRECISELY matching scope is used, and there may be at
# most one instance of any key under `docker` across all files. Either rule broken means our
# use-sigstore-attachments is never applied — containers/image then looks for no signature, finds
# none, and enforcement stops. Nothing on the machine looks wrong.
REGD_BLOCK="$(extract_between "$U" '^for other in /etc/containers/registries\.d/' '^did "use-sigstore-attachments enabled' \
  | rootify /etc/containers/registries.d)"

regd_run() { # <root> <extra-name|''> <extra-body>
  local root="$1"
  mkdir -p "$root/etc/containers/registries.d"
  printf 'docker:\n  "%s":\n    use-sigstore-attachments: true\n' "$SCOPE" > "$root/etc/containers/registries.d/auros.yaml"
  [ -n "$2" ] && printf '%s\n' "$3" > "$root/etc/containers/registries.d/$2"
  ROOT="$root" AUROS_SCOPE="$SCOPE" bash -c "$PRE
$REGD_BLOCK"
}

R="$(newroot)"
run_check signing.registries green "ours is the only file" -- regd_run "$R" '' ''
R="$(newroot)"
run_check signing.registries green "another file covers a different registry entirely" -- regd_run "$R" other.yaml 'docker:
  "docker.io":
    use-sigstore-attachments: false'
R="$(newroot)"
run_check signing.registries green "another file covers a DIFFERENT namespace on the same registry" -- regd_run "$R" other.yaml 'docker:
  "ghcr.io/someoneelse":
    use-sigstore-attachments: false'

# THE SILENT OVERRIDE. A file defining ghcr.io/<ns>/auros-base is MORE SPECIFIC than ours, so ours
# is ignored entirely for that repository — which is the repository every machine updates from.
R="$(newroot)"
run_check signing.registries red "another file defines a MORE SPECIFIC scope under ours" -- regd_run "$R" other.yaml 'docker:
  "'"$SCOPE"'/auros-base":
    use-sigstore-attachments: false'
assert_has "explains that only the most precise scope is used" "MORE SPECIFIC" "$T_LAST_OUT"
assert_has "and that verification would quietly stop"          "quietly stop working" "$T_LAST_OUT"

# The duplicate. Forbidden even when the two settings agree: the merge itself fails.
R="$(newroot)"
run_check signing.registries red "another file defines the SAME scope as ours" -- regd_run "$R" dup.yaml 'docker:
  "'"$SCOPE"'":
    use-sigstore-attachments: true'
assert_has "cites the rule" "forbids the same key in two files" "$T_LAST_OUT"

R="$(newroot)"
run_check signing.registries red "the duplicate is in a .yml rather than a .yaml" -- regd_run "$R" dup.yml 'docker:
  "'"$SCOPE"'":
    use-sigstore-attachments: true'
R="$(newroot)"
run_check signing.registries red "the duplicate scope is unquoted" -- regd_run "$R" dup.yaml 'docker:
  '"$SCOPE"':
    use-sigstore-attachments: true'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "install-time enforcement — the row with no external symptom"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Without enforce-container-sigpolicy = true, bootc records the deployment as signature mode
# "insecure" and IGNORES policy.json entirely, however correct policy.json looks. There is no
# symptom on the machine. `= false` is one word away and would pass any check that merely greps for
# the setting's NAME.
TOML_BLOCK="$(extract_between "$U" "^grep -qE '\\^enforce-container-sigpolicy" 'does not set enforce-container-sigpolicy' \
  | rootify /usr/lib/bootc/install)"

toml_run() { # <root> <body>
  local root="$1"
  mkdir -p "$root/usr/lib/bootc/install"
  printf '%s\n' "$2" > "$root/usr/lib/bootc/install/30-auros.toml"
  ROOT="$root" bash -c "$PRE
$TOML_BLOCK"
}

R="$(newroot)"
run_check signing.sigpolicy green "the 30-auros.toml we actually ship" -- toml_run "$R" "$(cat "$REPO/signing/install/30-auros.toml")"
R="$(newroot)"
run_check signing.sigpolicy red "the setting says false" -- toml_run "$R" '[install]
enforce-container-sigpolicy = false'
R="$(newroot)"
run_check signing.sigpolicy red "the setting is absent" -- toml_run "$R" '[install]
root-fs-type = "btrfs"'
R="$(newroot)"
run_check signing.sigpolicy red "the setting is commented out" -- toml_run "$R" '[install]
#enforce-container-sigpolicy = true'
R="$(newroot)"
run_check signing.sigpolicy red "the value is a quoted string rather than the boolean" -- toml_run "$R" '[install]
enforce-container-sigpolicy = "true"'

t_finish "30-update-agent.sh"

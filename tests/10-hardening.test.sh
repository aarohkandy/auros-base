#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/10-hardening.test.sh — the hardening layer's build-time assertions and its runtime assertion,
# against a synthetic fake root.
#
# The SELinux kernel-argument check has its own file (tests/kargs-check.test.sh) because it is the
# check that failed in both directions on the same day and it earned one. Everything else the
# hardening layer asserts is here.
#
# WHAT IS ACTUALLY AT STAKE, per claim, because that is what decides how hard to test each one:
#
#   SELinux enforcing   an image that ships SELINUX=permissive is an image where every confinement
#                       we sell is advisory. The build-time check is on the CONFIG FILE; the runtime
#                       check is on /sys/fs/selinux/enforce. Both are here, both in both directions.
#   sshd masked         "masked, not merely disabled" is the whole claim. A disabled unit is one
#                       `systemctl enable` away from running, and sshd.socket starts on connection
#                       while disabled. A test that only checks "not enabled" would pass the exact
#                       state the claim exists to exclude, so the DISABLED-BUT-NOT-MASKED case is
#                       tested explicitly and must go red.
#   firewalld           default-deny inbound. The failure that matters is a zone file that exists and
#                       whose target is ACCEPT — configured and not effective, B5's category.
#   telemetry           hardening/telemetry.tsv is a promise printed into the build console. Every
#                       unit-mask row must actually end up masked; a row that silently does nothing
#                       is a privacy claim we would be making falsely.
#   no NOPASSWD         a sudoers drop-in that sorts AFTER ours wins over ours. The ordering is the
#                       check, and "sorts before" vs "sorts after" must produce opposite answers.
#
# Nothing below copies the code it tests. Each block is extracted from the shipping script at run
# time, and an extraction that matches nothing aborts the suite rather than passing vacuously.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

H="$REPO/build/10-hardening.sh"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
# The shim (and any other stub) must be ahead of the real tools for every block this file runs.
# Without this the build scripts' GNU `sed -i` silently became a BSD `sed -i <suffix>` and corrupted
# the file it was meant to edit, while still exiting 0.
export PATH="$STUBS:$PATH"

printf '10-hardening.sh — build-time and runtime assertions  (%s)\n' "$T_SED_MODE"

# The shared preamble every extracted block needs: the logging vocabulary from 00-common.sh, with
# die() actually exiting non-zero so a refusal is observable as one.
PRE='set -uo pipefail
step() { :; }
did()  { echo "DID $*"; }
found(){ echo "FOUND $*"; }
warn() { echo "WARN $*"; }
die()  { echo "DIE $*" >&2; exit 1; }
record(){ :; }
auros_stamp(){ :; }
AUROS_WRITTEN_LIST=/dev/null
'

# mask_unit() and enable_unit() live in 00-common.sh and are extracted from it. Three blocks in
# 10-hardening.sh are nothing but calls to them (sshd, the telemetry loop, dnf-automatic), and a
# stubbed-out mask_unit would make all three test their own stub. 00-common.test.sh owns proving
# that mask_unit/enable_unit are themselves correct; here they are the real thing so that the CALLS
# are what is under test.
MASK_FN="$(extract_fn "$REPO/build/00-common.sh" mask_unit | rootify /etc/systemd/system /usr/lib/systemd/system)"
ENABLE_FN="$(extract_fn "$REPO/build/00-common.sh" _unit_wantedby | rootify /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system)
$(extract_fn "$REPO/build/00-common.sh" enable_unit | rootify /etc/systemd/system /usr/lib/systemd/system)"
UNIT_STUBS='have_unit() { [ -e "$ROOT/usr/lib/systemd/system/$1" ]; }
_systemctl_offline() { return 0; }   # exits 0 and does nothing — the realistic adversary
'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "SELinux — the config file assertion, at build time"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The shipping line is `grep -qx 'SELINUX=enforcing' /etc/selinux/config || die ...`. -qx is an exact
# whole-line match on purpose: `SELINUX=enforcing_maybe` and a commented-out line are both things a
# looser pattern would accept.
SELINUX_CHECK="$(extract_lines "$H" "grep -qx 'SELINUX=enforcing'" | rootify /etc/selinux/config)"

selinux_case() { # <config body>
  local root; root="$(newroot)"; mkdir -p "$root/etc/selinux"
  printf '%s\n' "$1" > "$root/etc/selinux/config"
  ROOT="$root" bash -c "$PRE
$SELINUX_CHECK"
}

run_check selinux.config green "SELINUX=enforcing, as we ship it" -- selinux_case "$(cat "$REPO/hardening/selinux-config")"
run_check selinux.config red   "SELINUX=permissive"               -- selinux_case 'SELINUX=permissive
SELINUXTYPE=targeted'
run_check selinux.config red   "SELINUX=disabled"                 -- selinux_case 'SELINUX=disabled'
run_check selinux.config red   "the line is commented out"        -- selinux_case '#SELINUX=enforcing'
run_check selinux.config red   "the value has a trailing comment" -- selinux_case 'SELINUX=enforcing # for now'
run_check selinux.config red   "leading whitespace before the key" -- selinux_case '  SELINUX=enforcing'
run_check selinux.config red   "the file is empty"                -- selinux_case ''

# The file we actually ship has to be the thing that passes, or the check and the payload disagree
# and one of them is wrong. Asserted separately from the synthetic cases so that editing
# hardening/selinux-config is immediately visible here.
assert_has "the shipped selinux-config says enforcing" "SELINUX=enforcing" "$(cat "$REPO/hardening/selinux-config")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "sshd — masked, and specifically NOT merely disabled"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The runtime assertion is what a customer's machine actually runs, so it is what gets tested hardest.
# hardening-assert.sh carries the AUROS_TEST_ROOT seam (same as 40-no-new-failed-units.sh) and is run
# here UNMODIFIED with a stub systemctl whose answers are dictated per case.
#
# `masked` must pass. `disabled`, `enabled`, `static` and `indirect` must all fail — and `disabled` is
# the one that matters, because it is the state somebody reaches for when they mean "off" and it is
# precisely the state the claim excludes.
HA="$REPO/hardening/hardening-assert.sh"
[ -f "$HA" ] || t_abort "hardening/hardening-assert.sh is missing"
grep -q 'AUROS_TEST_ROOT' "$HA" || t_abort "hardening-assert.sh has no AUROS_TEST_ROOT seam — this test would be testing the laptop, not the image"

ha_stubs() { # <dir> <sshd-state> <firewalld: running|stopped|absent> <zone> <target> <services> <sshd-active: yes|no>
  local d="$1"
  stub "$d" systemctl <<SH
#!/usr/bin/env bash
unit=""
for a in "\$@"; do case "\$a" in -*) ;; *) [ -z "\$unit" ] && [ "\$a" != "is-enabled" ] && [ "\$a" != "is-active" ] && [ "\$a" != "list-unit-files" ] && unit="\$a" ;; esac; done
case "\${1:-}" in
  list-unit-files) case "\$unit" in sshd.service|sshd.socket) [ "$2" = absent ] && exit 0; echo "\$unit  $2"; exit 0 ;; *) exit 0 ;; esac ;;
  is-enabled)      case "\$unit" in sshd.service|sshd.socket) [ "$2" = absent ] && { echo "Failed to get unit file state: No such file or directory" >&2; exit 1; }; echo "$2"; exit 0 ;; *) echo static; exit 0 ;; esac ;;
  is-active)       case "\$unit" in
                     firewalld.service)          [ "$3" = running ] && exit 0 || exit 3 ;;
                     sshd.service|sshd.socket)   [ "${7:-no}" = yes ] && exit 0 || exit 3 ;;
                     *) exit 3 ;;
                   esac ;;
esac
exit 1
SH
  if [ "$3" = absent ]; then rm -f "$d/firewall-cmd"; else
  stub "$d" firewall-cmd <<SH
#!/usr/bin/env bash
case "\$*" in
  *--get-default-zone*) echo "$4" ;;
  *--get-target*)       echo "$5" ;;
  *--list-services*)    echo "$6" ;;
  *--list-ports*)       echo "" ;;
  *) exit 1 ;;
esac
SH
  fi
}

ha_case() { # <sshd-state> <firewalld> <zone> <target> <services> [selinux: 1|0|absent] [sudoers body] [sshd-active]
  local root d
  root="$(newroot)"; d="$root/bin"; mkdir -p "$d" "$root/sys/fs/selinux" "$root/etc/sudoers.d"
  ha_stubs "$d" "$1" "$2" "$3" "$4" "$5" "${8:-no}"
  case "${6:-1}" in
    absent) : ;;
    *) printf '%s' "${6:-1}" > "$root/sys/fs/selinux/enforce" ;;
  esac
  printf '%s\n' "${7:-# nothing}" > "$root/etc/sudoers"
  env -i PATH="$d:$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" AUROS_TEST_ROOT="$root" \
    bash "$HA"
}

t_exempt hardening.runtime \
  "a whole-script smoke run of hardening-assert.sh, not a check: it proves the runtime assertion
       completes and reports each claim. Every individual assertion inside it is exercised in both
       directions below under hardening.sshd / .selinux / .firewall / .nopasswd."
GOOD=(masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1)
run_check hardening.runtime green "everything in force" -- ha_case "${GOOD[@]}"
assert_has "reports sshd.service masked" "sshd.service masked" "$T_LAST_OUT"
assert_has "reports SELinux enforcing"   "SELinux enforcing"   "$T_LAST_OUT"

for state in disabled enabled static indirect linked; do
  run_check hardening.sshd red "sshd is '$state', not masked" \
    -- ha_case "$state" running auros "%%REJECT%%" "dhcpv6-client mdns" 1
  assert_has "names the state it found" "is '$state' — expected masked" "$T_LAST_OUT"
done
run_check hardening.sshd green "sshd is masked" -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1
run_check hardening.sshd green "sshd is not present on the image at all" \
  -- ha_case absent running auros "%%REJECT%%" "dhcpv6-client mdns" 1

# The state no configuration file can describe: the unit file says masked and a process is
# nevertheless listening. That is what a getty-style race or a hand-started daemon looks like, and a
# check that only read `is-enabled` would call it healthy.
run_check hardening.sshd red "sshd is masked AND a process is running anyway" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1 '# nothing' yes
assert_has "says the machine is accepting inbound ssh" "is ACTIVE" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "SELinux — the runtime assertion, on the kernel rather than the file"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The build-time check can only read a config file, and a config file is not a running kernel. This
# is the assertion that would notice `enforcing=0` typed at the GRUB prompt and never removed —
# exactly the recovery path hardening/kargs-selinux.toml deliberately leaves open.
run_check hardening.selinux green "/sys/fs/selinux/enforce is 1" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1
run_check hardening.selinux red "/sys/fs/selinux/enforce is 0 (permissive)" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 0
assert_has "says permissive, not 'not enabled'" "SELinux is permissive" "$T_LAST_OUT"
run_check hardening.selinux red "selinuxfs is absent — the kernel booted without SELinux" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" absent
assert_has "says the kernel booted without it" "the kernel booted without it" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "firewalld — default-deny inbound, asserted against the running firewall"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
run_check hardening.firewall green "zone auros, target REJECT, our two services" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1
run_check hardening.firewall green "target spelled DROP" \
  -- ha_case masked running auros "DROP" "dhcpv6-client mdns" 1
run_check hardening.firewall red "the default zone is not ours" \
  -- ha_case masked running public "%%REJECT%%" "dhcpv6-client mdns" 1
run_check hardening.firewall red "our zone exists but its target is ACCEPT — configured, not effective" \
  -- ha_case masked running auros "ACCEPT" "dhcpv6-client mdns" 1
run_check hardening.firewall red "firewalld is not running at all" \
  -- ha_case masked stopped auros "%%REJECT%%" "dhcpv6-client mdns" 1
run_check hardening.firewall red "firewall-cmd is missing, so the firewall cannot be asserted" \
  -- ha_case masked absent auros "%%REJECT%%" "dhcpv6-client mdns" 1
assert_has "refuses to trust what it cannot check" "so it is not trusted" "$T_LAST_OUT"

# The allowlist is a promise with exactly two entries. ssh is the one that must never appear, and the
# reason it is tested by name is that "sshd is masked so a hole would be a hole to nothing" is an
# argument that stops being true the moment somebody unmasks sshd.
run_check hardening.firewall-allowlist green "the allowlist is exactly dhcpv6-client and mdns" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1
for extra in ssh http samba cockpit; do
  run_check hardening.firewall-allowlist red "the zone also allows '$extra'" \
    -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns $extra" 1
  assert_has "names the unexpected service" "unexpected inbound service '$extra'" "$T_LAST_OUT"
done

# The zone file we ship must be the thing that passes. Checked against the payload, not recited.
ZONE="$REPO/hardening/firewalld-zone-auros.xml"
assert_has "shipped zone is default-deny"      'target="%%REJECT%%"'    "$(cat "$ZONE")"
assert_has "shipped zone allows dhcpv6-client" 'name="dhcpv6-client"'   "$(cat "$ZONE")"
assert_has "shipped zone allows mdns"          'name="mdns"'            "$(cat "$ZONE")"
assert_eq  "shipped zone allows nothing else"  "2" "$(grep -c '<service name=' "$ZONE" | tr -d ' ')"
assert_not "shipped zone does not allow ssh"   'name="ssh"'             "$(cat "$ZONE")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "no passwordless sudo — the runtime half"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
run_check hardening.nopasswd green "no NOPASSWD anywhere" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1 '# nothing here'
run_check hardening.nopasswd red "a NOPASSWD rule in /etc/sudoers" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1 '%wheel ALL=(ALL) NOPASSWD: ALL'
run_check hardening.nopasswd green "a COMMENTED NOPASSWD line is not a rule" \
  -- ha_case masked running auros "%%REJECT%%" "dhcpv6-client mdns" 1 '# %wheel ALL=(ALL) NOPASSWD: ALL'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "no passwordless sudo — the build-time half, where ORDERING is the whole check"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# sudo reads /etc/sudoers.d in lexical order and the LAST matching rule wins. So a NOPASSWD drop-in
# that sorts after 50-auros-baseline defeats it, and one that sorts before it does not. Those two
# cases must produce opposite answers; an implementation that treated any NOPASSWD as fatal would
# fail every build on a base that ships one, and one that ignored ordering would ship passwordless
# root. Both mistakes are one comparison operator apart.
NOPASS_BLOCK="$(extract_between "$H" '^nopass_after=""' 'no passwordless sudo escalation' \
  | rootify /etc/sudoers.d /etc/sudoers)"

nopass_case() { # <filename-in-sudoers.d or ''> <content> [extra-file] [extra-content]
  local root; root="$(newroot)"; mkdir -p "$root/etc/sudoers.d"
  printf '# base\n' > "$root/etc/sudoers"
  printf 'Defaults timestamp_timeout=0\n' > "$root/etc/sudoers.d/50-auros-baseline"
  [ -n "$1" ] && printf '%s\n' "$2" > "$root/etc/sudoers.d/$1"
  [ -n "${3:-}" ] && printf '%s\n' "$4" > "$root/etc/sudoers.d/$3"
  ROOT="$root" bash -c "$PRE
$NOPASS_BLOCK"
}

run_check hardening.nopasswd-order green "nothing but our own baseline" -- nopass_case '' ''
run_check hardening.nopasswd-order red "a NOPASSWD drop-in that sorts AFTER ours wins over ours" \
  -- nopass_case '90-local' '%wheel ALL=(ALL) NOPASSWD: ALL'
assert_has "names the offending file"  "90-local" "$T_LAST_OUT"
assert_has "explains what it would grant" "passwordless root" "$T_LAST_OUT"
run_check hardening.nopasswd-order green "a NOPASSWD drop-in that sorts BEFORE ours is overridden" \
  -- nopass_case '10-vendor' '%wheel ALL=(ALL) NOPASSWD: ALL'
assert_has "says ours wins, rather than staying silent" "our rule wins" "$T_LAST_OUT"
run_check hardening.nopasswd-order green "a commented NOPASSWD sorting after ours is not a rule" \
  -- nopass_case '90-local' '# %wheel ALL=(ALL) NOPASSWD: ALL'
run_check hardening.nopasswd-order red "one harmless drop-in before and one hostile one after" \
  -- nopass_case '10-vendor' '%wheel ALL=(ALL) NOPASSWD: /usr/bin/id' '99-late' 'ALL ALL=(ALL) NOPASSWD: ALL'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "telemetry — every unit-mask row in telemetry.tsv actually ends up masked"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# hardening/telemetry.tsv is not a list of intentions. build/10-hardening.sh prints a MASKED line to
# the build console for each row, and that console output ships (spec §7 — the website streams it).
# A row that quietly does nothing would be a privacy claim we make falsely to a customer who can read
# it. So: build a fake image containing every unit the table names, run the real loop over the real
# table, and assert one /dev/null symlink per unit-mask row.
TSV="$REPO/hardening/telemetry.tsv"
TELEM_BLOCK="$(extract_between "$H" '^while IFS=.*read -r -u 3 kind target rationale' '^done 3< ')"

TELEM_PRE="$PRE"'
have_unit() { [ -e "$ROOT/usr/lib/systemd/system/$1" ]; }
have_pkg()  { case " $FAKE_PKGS " in *" $1 "*) return 0;; *) return 1;; esac; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
rpm() { echo "1.0-1"; }
_systemctl_offline() { return 0; }
'"$MASK_FN
$ENABLE_FN"

MASK_ROWS="$(awk -F'\t' '$1=="unit-mask"{print $2}' "$TSV")"
KEEP_ROWS="$(awk -F'\t' '$1=="unit-keep"{print $2}' "$TSV")"
[ -n "$MASK_ROWS" ] || t_abort "telemetry.tsv has no unit-mask rows — this test would be vacuous"

telem_run() { # <root>
  ROOT="$1" FAKE_PKGS="libreport geoclue2" tsv="$TSV" bash -c "$TELEM_PRE
$TELEM_BLOCK"
}

# All units present: every unit-mask row must produce a /dev/null symlink.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $MASK_ROWS; do : > "$R/usr/lib/systemd/system/$u"; done
# A unit-keep row's unit needs a real [Install] section, because "KEPT ON" is a claim that
# enable_unit() succeeded on it — and enable_unit resolves WantedBy=. An empty file here would make
# the kept units die, which would have hidden the hole rather than exposing it.
for u in $KEEP_ROWS; do printf '[Install]\nWantedBy=timers.target\n' > "$R/usr/lib/systemd/system/$u"; done
run_check telemetry.loop green "the whole table runs against an image containing every unit" -- telem_run "$R"
for u in $MASK_ROWS; do
  assert_symlink_to "masked $u" "$R/etc/systemd/system/$u" /dev/null
  assert_has "and said so in the build console" "MASKED    $u" "$T_LAST_OUT"
done
for u in $KEEP_ROWS; do
  assert_nofile "did NOT mask the deliberately-kept $u" "$R/etc/systemd/system/$u"
  assert_has "and named it as kept on purpose" "KEPT ON   $u" "$T_LAST_OUT"
  # THE ASSERTION THAT MAKES "KEPT ON" TRUE RATHER THAN PRINTED. A unit-keep row that is reported
  # but never enabled is a false statement in a build console a customer reads (spec §7), and it is
  # exactly what the arm looks like with its enable_unit call deleted.
  assert_symlink_to "and actually ENABLED $u, not merely announced it" \
    "$R/usr/lib/systemd/system/timers.target.wants/$u" "../$u"
done

# Units absent: the loop must say ABSENT rather than claim it masked something that was never there.
# "We looked and it was not there" is the deliverable; "we assumed" is not.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
run_check telemetry.loop green "the table runs against an image containing none of the units" -- telem_run "$R"
for u in $MASK_ROWS; do
  assert_has "reported $u absent rather than masked" "ABSENT    $u" "$T_LAST_OUT"
  assert_nofile "and invented no mask link for $u" "$R/etc/systemd/system/$u"
done

# THE RED CASE. A unit that is present but cannot be masked must stop the build rather than print a
# MASKED line about it. Without this, the loop's failure mode is a build console that says MASKED for
# a unit that is still live — a true-looking sentence that is false, streamed to a customer.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $MASK_ROWS; do : > "$R/usr/lib/systemd/system/$u"; done
chmod 0500 "$R/etc/systemd/system"
run_check telemetry.loop red "a row's unit is present and cannot be masked" -- telem_run "$R"
chmod 0700 "$R/etc/systemd/system"

# An unknown kind must be reported, not silently skipped: a typo in the first column would otherwise
# remove a row from the hardening with no trace anywhere.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
BADTSV="$R/telemetry.tsv"; printf 'unit-msak\tabrtd.service\ttypo in the kind column\n' > "$BADTSV"
out="$(ROOT="$R" FAKE_PKGS="" tsv="$BADTSV" bash -c "$TELEM_PRE
$TELEM_BLOCK" 2>&1)"
assert_has "an unrecognised kind is reported by name" "unknown kind 'unit-msak'" "$out"
t_exempt telemetry.unknown-kind \
  "a warn(), not a die(): the table is data other layers append to, and an unknown kind must be
       visible without stopping a build over a row nobody is using. Asserted on the MESSAGE above
       rather than on an exit code, so there is no exit code to score in two directions."


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "upstream modules-load.d — zfs and v4l2loopback masked to /dev/null (D43, proposed)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The claim is the /etc symlink to /dev/null that modules-load.d(5) documents as the vendor-file
# override. The red cases are an ln that does nothing (the assertion must notice, not trust the
# loop) and a real directory already sitting at the override path (ln puts the link INSIDE it).
MLD_BLOCK="$(extract_between "$H" '^for f in zfs.conf v4l2loopback.conf; do' 'forced loads of zfs and v4l2loopback masked' \
  | rootify /etc/modules-load.d /usr/lib/modules-load.d)"
mld_run() { # <root> [extra shell run before the block]
  ROOT="$1" bash -c "$PRE
${2-}
$MLD_BLOCK"
}
R="$(newroot)"; mkdir -p "$R/usr/lib/modules-load.d"
printf 'zfs\n' > "$R/usr/lib/modules-load.d/zfs.conf"; printf 'v4l2loopback\n' > "$R/usr/lib/modules-load.d/v4l2loopback.conf"
run_check hardening.mld-mask green "the base ships both upstream files" -- mld_run "$R"
assert_symlink_to "zfs.conf is masked"          "$R/etc/modules-load.d/zfs.conf" /dev/null
assert_symlink_to "v4l2loopback.conf is masked" "$R/etc/modules-load.d/v4l2loopback.conf" /dev/null
R="$(newroot)"
run_check hardening.mld-mask green "a base without the files is still masked" -- mld_run "$R"
assert_symlink_to "zfs.conf is masked even so" "$R/etc/modules-load.d/zfs.conf" /dev/null
R="$(newroot)"
run_check hardening.mld-mask red "ln silently does nothing" -- mld_run "$R" 'ln() { :; }'
assert_has "names the file still live" "zfs.conf is not a symlink to /dev/null" "$T_LAST_OUT"
R="$(newroot)"; mkdir -p "$R/etc/modules-load.d/v4l2loopback.conf"
run_check hardening.mld-mask red "a directory already occupies the override path" -- mld_run "$R"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the initramfs forces zfs/v4l2loopback — modprobe.blacklist= must block each (D43, run 35616444839)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The masks above held and both modules loaded anyway: upstream's initramfs carries its own
# modules-load.d. A fake initramfs here is an empty file plus <img>.d/ holding its tree; the lsinitrd
# stub lists that tree the way lsinitrd does and prints a file with -f, header lines included.
# The kargs.d file is the SHIPPING hardening/kargs-modules.toml, so dropping a module from it is red.
INITRD_BLOCK="$(extract_between "$H" '^have_cmd lsinitrd' 'initramfs read)"$' \
  | rootify /usr/lib/modules /usr/lib/bootc/kargs.d)"
KARGS_FN="$(extract_fn "$H" _auros_effective_kargs | rootify /usr/lib/bootc/kargs.d /usr/lib/ostree-boot)"
LSINITRD_STUB='have_cmd() { command -v "$1" >/dev/null 2>&1; }
lsinitrd() {
  if [ "$1" = -f ]; then printf "initramfs:/%s\n====\n" "$2"; cat "$3.d/$2"; printf "====\n"; return; fi
  [ -d "$1.d" ] || return 1
  (cd "$1.d" && find . -type f | sed "s#^\./#-rw-r--r--   1 root root  4 Sep 15 20:33 #")
}'
initrd_run() { # <root> [extra shell]
  ROOT="$1" bash -c "$PRE
$KARGS_FN
${2-$LSINITRD_STUB}
$INITRD_BLOCK"
}
# mkinitrd <root> <module>... — a fake initramfs forcing each module through its own .conf
mkinitrd() {
  local r="$1" d; shift
  d="$r/usr/lib/modules/7.1.8-200.fc44.x86_64"
  mkdir -p "$d/initramfs.img.d/usr/lib/modules-load.d" "$d/initramfs.img.d/usr/lib/modules/x"
  : > "$d/initramfs.img"; : > "$d/initramfs.img.d/usr/lib/modules/x/ext4.ko"
  printf '# vendor\nfuse\n' > "$d/initramfs.img.d/usr/lib/modules-load.d/fuse-overlayfs.conf"
  for m in "$@"; do printf '%s\n' "$m" > "$d/initramfs.img.d/usr/lib/modules-load.d/$m.conf"; done
}
shipkargs() { mkdir -p "$1/usr/lib/bootc/kargs.d"; cp "$REPO/hardening/kargs-modules.toml" "$1/usr/lib/bootc/kargs.d/20-auros-modules.toml"; }

R="$(newroot)"; mkinitrd "$R" zfs v4l2loopback; shipkargs "$R"
run_check hardening.initrd-block green "upstream's initramfs, shipped kargs" -- initrd_run "$R"
assert_has "names what the initrd forces" "zfs" "$T_LAST_OUT"
R="$(newroot)"; mkinitrd "$R"
run_check hardening.initrd-block green "an initramfs that forces neither needs no karg" -- initrd_run "$R"
R="$(newroot)"; mkinitrd "$R" zfs v4l2loopback
run_check hardening.initrd-block red "upstream's initramfs, no karg (run 35616444839)" -- initrd_run "$R"
assert_has "names the module" "loads zfs in the initrd" "$T_LAST_OUT"
R="$(newroot)"; mkinitrd "$R" zfs v4l2loopback; mkdir -p "$R/usr/lib/bootc/kargs.d"
printf 'kargs = ["modprobe.blacklist=v4l2loopback"]\n' > "$R/usr/lib/bootc/kargs.d/20-x.toml"
run_check hardening.initrd-block red "only v4l2loopback blocked" -- initrd_run "$R"
assert_has "names zfs as unblocked" "no modprobe.blacklist=zfs" "$T_LAST_OUT"
R="$(newroot)"; mkinitrd "$R" zfs; mkdir -p "$R/usr/lib/bootc/kargs.d"
printf 'kargs = ["module_blacklist=zfs"]\n' > "$R/usr/lib/bootc/kargs.d/20-x.toml"
run_check hardening.initrd-block red "module_blacklist= (EPERM, fails the unit) is not accepted" -- initrd_run "$R"
assert_has "for the right reason" "no modprobe.blacklist=zfs" "$T_LAST_OUT"
R="$(newroot)"; mkinitrd "$R" zfs; shipkargs "$R"
run_check hardening.initrd-block red "lsinitrd missing" -- initrd_run "$R" 'have_cmd() { command -v "$1" >/dev/null 2>&1; }'
assert_has "says lsinitrd is missing" "lsinitrd is missing" "$T_LAST_OUT"
R="$(newroot)"; mkinitrd "$R" zfs; shipkargs "$R"
run_check hardening.initrd-block red "lsinitrd lists nothing (must not read as 'forces nothing')" -- initrd_run "$R" \
  "$LSINITRD_STUB"'
lsinitrd() { :; }'
assert_has "says the listing was empty" "listed nothing recognisable" "$T_LAST_OUT"
R="$(newroot)"; shipkargs "$R"
run_check hardening.initrd-block red "no initramfs in the image" -- initrd_run "$R"
assert_has "says there is no initramfs" "initramfs.img in this image" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "mcelog — skipped on CPUs it refuses (run 35616444839: AMD family 25, degraded)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
MCE_BLOCK="$(extract_between "$H" '^if \[ -e /usr/lib/systemd/system/mcelog.service \]' '^fi$' \
  | rootify /usr/lib/systemd/system /usr/sbin)"
mce_run() { # <root>
  ROOT="$1" H="$REPO/hardening" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$2\")\"; cp \"\$1\" \"\$2\"; }
$MCE_BLOCK"
}
mkmce() { # <root> <mcelog binary text>
  mkdir -p "$1/usr/lib/systemd/system" "$1/usr/sbin"
  printf '[Service]\nExecStart=/usr/sbin/mcelog --daemon --foreground\n' > "$1/usr/lib/systemd/system/mcelog.service"
  printf '%s\n' "$2" > "$1/usr/sbin/mcelog"
}
DROPIN=usr/lib/systemd/system/mcelog.service.d/10-auros-cpu-supported.conf
R="$(newroot)"; mkmce "$R" $'\x7fELF --is-cpu-supported  Exit with return code'
run_check hardening.mcelog green "mcelog with --is-cpu-supported gets the drop-in" -- mce_run "$R"
assert_has "the drop-in gates on mcelog's own test" "ExecCondition=/usr/sbin/mcelog --is-cpu-supported" "$(cat "$R/$DROPIN" 2>/dev/null)"
R="$(newroot)"
run_check hardening.mcelog green "no mcelog on the base" -- mce_run "$R"
assert_nofile "and no drop-in" "$R/$DROPIN"
R="$(newroot)"; mkmce "$R" $'\x7fELF an older mcelog'
run_check hardening.mcelog red "an mcelog without --is-cpu-supported would skip on Intel too" -- mce_run "$R"
assert_has "for the right reason" "has no --is-cpu-supported" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "sshd — BOTH units, because sshd.socket starts sshd on an incoming connection"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The file's own header says "masked, not disabled ... sshd.socket would start on connection even
# while sshd.service is disabled". Nothing tested that the LOOP actually covers sshd.socket: deleting
# it from `for u in sshd.service sshd.socket` left every suite green while the image shipped a socket
# unit that starts sshd on demand. The claim was in a comment; the check was not anywhere.
SSHD_BLOCK="$(extract_between "$H" '^masked_any=0' 'may not ship openssh-server')"

sshd_run() { # <root>
  ROOT="$1" bash -c "$PRE
$UNIT_STUBS
$MASK_FN
$SSHD_BLOCK"
}

R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
: > "$R/usr/lib/systemd/system/sshd.service"; : > "$R/usr/lib/systemd/system/sshd.socket"
run_check hardening.sshd-mask green "an image that ships both sshd units" -- sshd_run "$R"
assert_symlink_to "sshd.service is a symlink to /dev/null" "$R/etc/systemd/system/sshd.service" /dev/null
assert_symlink_to "SO IS sshd.socket — the unit that starts sshd on connection while the service is masked" \
  "$R/etc/systemd/system/sshd.socket" /dev/null
assert_has "the build console names the service" "masked sshd.service" "$T_LAST_OUT"
assert_has "and names the socket separately"     "masked sshd.socket"  "$T_LAST_OUT"

# The socket alone. Some layouts ship socket activation without the service being enabled at all,
# and a loop that only knew about sshd.service would report "not present" and mask nothing.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
: > "$R/usr/lib/systemd/system/sshd.socket"
run_check hardening.sshd-mask green "an image that ships ONLY sshd.socket" -- sshd_run "$R"
assert_symlink_to "the socket is still masked" "$R/etc/systemd/system/sshd.socket" /dev/null
assert_has "and the absent service is reported, not claimed" "sshd.service not present" "$T_LAST_OUT"

R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
run_check hardening.sshd-mask green "a base with no openssh-server at all" -- sshd_run "$R"
assert_has "warns rather than silently claiming success" "no sshd units were found to mask" "$T_LAST_OUT"

# The refusal: a unit is present and cannot be masked. Printing "masked sshd.socket" for a socket
# that is still live is the false-claim failure the whole telemetry section is written against.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
: > "$R/usr/lib/systemd/system/sshd.service"; : > "$R/usr/lib/systemd/system/sshd.socket"
chmod 0500 "$R/etc/systemd/system"
run_check hardening.sshd-mask red "sshd is present and masking cannot be completed" -- sshd_run "$R"
chmod 0700 "$R/etc/systemd/system"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "firewalld DefaultZone — the post-check exists because the sed has silently failed before"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# `sed -i` is edited in place rather than the file being replaced, so that the other knobs in a
# package-owned firewalld.conf survive. The failure that makes the post-check necessary is not
# hypothetical: a BSD `sed -i` in this repository already exited 0 while writing nothing. In that
# state the machine's default zone stays `public` — inbound ACCEPT for whatever public allows — and
# every downstream check reads a file that looks configured.
#
# So the post-check is `grep -qx 'DefaultZone=auros'`. Weakened to `grep -q 'DefaultZone'` it matches
# the UNCHANGED line and can never fail. That is the permanently-green shape again, in a new place.
FW_BLOCK="$(extract_between "$H" '^\[ -f /etc/firewalld/firewalld\.conf \]' '^record wrote-file /etc/firewalld/firewalld\.conf$' \
  | rootify /etc/firewalld/firewalld.conf)"

STOCK_FWCONF='DefaultZone=public
CleanupOnExit=yes
Lockdown=no
IPv6_rpfilter=yes
FirewallBackend=nftables'

fw_run() { # <root> [nosed]
  local sdir path="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
  if [ "${2:-}" = nosed ]; then
    sdir="$1/sedbin"; mkdir -p "$sdir"
    # A sed that exits 0 and changes nothing. This is not a straw man: it is what GNU-style
    # `sed -i 's/…/…/' file` does on a BSD sed, which is how this repo lost an edit once already.
    stub "$sdir" sed <<'SH'
#!/usr/bin/env bash
exit 0
SH
    path="$sdir:$path"
  fi
  ROOT="$1" PATH="$path" bash -c "$PRE
$FW_BLOCK"
}

R="$(newroot)"; mkdir -p "$R/etc/firewalld"; printf '%s\n' "$STOCK_FWCONF" > "$R/etc/firewalld/firewalld.conf"
run_check hardening.defaultzone green "a stock firewalld.conf with DefaultZone=public" -- fw_run "$R"
assert_has "the default zone is now ours"  "DefaultZone=auros"  "$(cat "$R/etc/firewalld/firewalld.conf")"
assert_not "and the old value is gone"     "DefaultZone=public" "$(cat "$R/etc/firewalld/firewalld.conf")"
# In place, not replaced: the other knobs in a package-owned file must survive.
assert_has "FirewallBackend survived the edit" "FirewallBackend=nftables" "$(cat "$R/etc/firewalld/firewalld.conf")"
assert_has "IPv6_rpfilter survived the edit"   "IPv6_rpfilter=yes"        "$(cat "$R/etc/firewalld/firewalld.conf")"

# THE CASE THE POST-CHECK EXISTS FOR. sed exits 0, writes nothing, and the file still says `public`.
R="$(newroot)"; mkdir -p "$R/etc/firewalld"; printf '%s\n' "$STOCK_FWCONF" > "$R/etc/firewalld/firewalld.conf"
run_check hardening.defaultzone red "sed exits 0 and changes nothing — the machine keeps zone 'public'" -- fw_run "$R" nosed
assert_has "says the edit did not take" "DefaultZone did not take" "$T_LAST_OUT"
assert_has "and the file really was left alone" "DefaultZone=public" "$(cat "$R/etc/firewalld/firewalld.conf")"

# A conf with the key spelled some other way, or absent: appending blind would put DefaultZone=auros
# into a file firewalld may not read the same way, so the build refuses instead.
R="$(newroot)"; mkdir -p "$R/etc/firewalld"; printf 'CleanupOnExit=yes\nFirewallBackend=nftables\n' > "$R/etc/firewalld/firewalld.conf"
run_check hardening.defaultzone red "firewalld.conf has no DefaultZone line at all" -- fw_run "$R"
assert_has "refuses to append blind" "refusing to append blind" "$T_LAST_OUT"

R="$(newroot)"; mkdir -p "$R/etc/firewalld"
run_check hardening.defaultzone red "firewalld is installed but firewalld.conf is missing" -- fw_run "$R"

# A commented-out DefaultZone is not a DefaultZone. The `^\s*DefaultZone=` presence test would match
# a line beginning with whitespace, but not one beginning with '#'.
R="$(newroot)"; mkdir -p "$R/etc/firewalld"; printf '#DefaultZone=public\nFirewallBackend=nftables\n' > "$R/etc/firewalld/firewalld.conf"
run_check hardening.defaultzone red "the DefaultZone line is commented out" -- fw_run "$R"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "dnf countme — a MEASURED number, and the one-repo case is the common one"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The build console prints "DISABLED dnf countme in N repository file(s)" or "ABSENT". Both are
# claims about this image. The guard is `[ "$countme_before" -gt 0 ]`, and off-by-one there
# (`-gt 1`) is invisible to any test that only ever builds two repo files: an image with exactly one
# countme=1 repo — which is the ordinary Fedora layout — would ship with the census still on while
# the console said ABSENT.
CM_BLOCK="$(extract_between "$H" '^countme_before=0' '^fi$' | rootify /etc/yum.repos.d)"

cm_run() { # <root> [nosed]
  local sdir path="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
  if [ "${2:-}" = nosed ]; then
    sdir="$1/sedbin"; mkdir -p "$sdir"
    stub "$sdir" sed <<'SH'
#!/usr/bin/env bash
exit 0
SH
    path="$sdir:$path"
  fi
  ROOT="$1" PATH="$path" bash -c "$PRE
$CM_BLOCK"
}
cm_repo() { printf '[%s]\nname=%s\nbaseurl=https://example.invalid/%s\nenabled=1\ncountme=%s\ngpgcheck=1\n' "$1" "$1" "$1" "$2"; }

# PORTABILITY NOTE, so a future reader does not add a case that fails on half the machines: the
# shipping patterns use `\s`, which is GNU. On a BSD sed/grep `\s` is not a whitespace class, so
# `^\s*countme` degenerates to `^s*countme` — which still matches `countme=1` at column 0 and would
# NOT match `  countme=1`. Every fixture here therefore writes the key at column 0, where the two
# interpretations agree, so these cases mean the same thing on the image (GNU) and on the laptop.
# The leading-whitespace case is deliberately absent rather than silently host-dependent.

# EXACTLY ONE. The common case, and the one an off-by-one guard skips.
R="$(newroot)"; mkdir -p "$R/etc/yum.repos.d"; cm_repo fedora 1 > "$R/etc/yum.repos.d/fedora.repo"
run_check hardening.countme green "exactly ONE repository file has countme=1" -- cm_run "$R"
assert_has "the console says it disabled one"  "DISABLED  dnf countme in 1 repository file(s)" "$T_LAST_OUT"
assert_has "and the file really says countme=0" "countme=0" "$(cat "$R/etc/yum.repos.d/fedora.repo")"
assert_not "with no countme=1 left in it"       "countme=1" "$(cat "$R/etc/yum.repos.d/fedora.repo")"

# Two, so the count in the sentence is a measurement rather than a constant.
R="$(newroot)"; mkdir -p "$R/etc/yum.repos.d"
cm_repo fedora 1 > "$R/etc/yum.repos.d/fedora.repo"
cm_repo updates 1 > "$R/etc/yum.repos.d/updates.repo"
cm_repo extra 0 > "$R/etc/yum.repos.d/extra.repo"
run_check hardening.countme green "two of three repository files have countme=1" -- cm_run "$R"
assert_has "the number printed is the number found" "DISABLED  dnf countme in 2 repository file(s)" "$T_LAST_OUT"
assert_not "and nothing anywhere still says countme=1" "countme=1" "$(cat "$R"/etc/yum.repos.d/*.repo)"

R="$(newroot)"; mkdir -p "$R/etc/yum.repos.d"; cm_repo fedora 0 > "$R/etc/yum.repos.d/fedora.repo"
run_check hardening.countme green "repository files exist and none has countme=1" -- cm_run "$R"
assert_has "reports ABSENT as a finding" "ABSENT    dnf countme" "$T_LAST_OUT"

R="$(newroot)"
run_check hardening.countme green "there is no /etc/yum.repos.d at all" -- cm_run "$R"
assert_has "says there was nothing to check" "nothing to check for countme" "$T_LAST_OUT"

# The refusal: the rewrite silently did nothing, so countme is still on. Printing DISABLED here
# would be a privacy claim we make falsely to someone who can read the build console.
R="$(newroot)"; mkdir -p "$R/etc/yum.repos.d"; cm_repo fedora 1 > "$R/etc/yum.repos.d/fedora.repo"
run_check hardening.countme red "the rewrite exits 0 and countme is still enabled" -- cm_run "$R" nosed
assert_has "says how many are still enabled" "countme still enabled in 1" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "dnf-automatic — masked when present, untouched when not"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# On a composed read-only /usr a dnf-automatic timer cannot succeed. Left live it fails every night,
# and a unit that fails every night is how people learn to ignore failed units — which is what check
# 40-no-new-failed-units.sh depends on them not doing. The `if have_pkg dnf-automatic` guard is one
# `!` away from inverting, and nothing exercised either branch.
# ANCHOR NOTE — this bit me three times in one afternoon and is worth stating once:
# AN EXTRACTION ANCHOR MUST NOT CONTAIN THE TEXT ITS OWN MUTATION EDITS. Anchored on
# `^if have_pkg dnf-automatic; then`, inverting that very guard to `if ! have_pkg` made the
# extraction match nothing, and the suite ABORTED instead of failing. An abort is still a red, so
# prove-red.sh scored it "caught" — but the abort means "I could not test this", not "this is
# wrong", and a test that can only abort is not testing the behaviour at all. `.*` across the part
# that can change keeps the range anchored while letting the mutant through to the assertions.
DNFA_BLOCK="$(extract_between "$H" '^if .*have_pkg dnf-automatic' '^fi$')"
DNFA_TIMERS="dnf-automatic.timer dnf-automatic-install.timer dnf-automatic-notifyonly.timer dnf-automatic-download.timer"

dnfa_run() { # <root> <have_pkg: yes|no>
  ROOT="$1" DNFA="$2" bash -c "$PRE
have_pkg() { [ \"\$DNFA\" = yes ]; }
$UNIT_STUBS
$MASK_FN
$DNFA_BLOCK"
}

R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $DNFA_TIMERS; do : > "$R/usr/lib/systemd/system/$u"; done
run_check hardening.dnf-automatic green "dnf-automatic is installed and all four timers are present" -- dnfa_run "$R" yes
for u in $DNFA_TIMERS; do
  assert_symlink_to "masked $u" "$R/etc/systemd/system/$u" /dev/null
done

# The other branch. `have_pkg` false must touch nothing — and must say so, because "we looked and it
# was not there" is the deliverable for this whole section.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $DNFA_TIMERS; do : > "$R/usr/lib/systemd/system/$u"; done
run_check hardening.dnf-automatic green "dnf-automatic is NOT installed" -- dnfa_run "$R" no
assert_has "reports it absent, with the bootc reasoning" "ABSENT    dnf-automatic" "$T_LAST_OUT"
for u in $DNFA_TIMERS; do
  assert_nofile "masked nothing: $u was left alone" "$R/etc/systemd/system/$u"
done

R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $DNFA_TIMERS; do : > "$R/usr/lib/systemd/system/$u"; done
chmod 0500 "$R/etc/systemd/system"
run_check hardening.dnf-automatic red "the package is installed and the timers cannot be masked" -- dnfa_run "$R" yes
chmod 0700 "$R/etc/systemd/system"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the protected-set spot-check at the end of hardening"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# 90-cleanup.sh runs the full protected-set assertion, but that is forty minutes and five build steps
# later. This spot-check is here so that a hardening step which removed the update path fails in the
# build log next to its cause. It names two commands, and bootc is the one that matters: bootc IS the
# update path, and an image without it can never be patched again. Dropping it from the list leaves a
# check that can only notice a missing systemctl.
SPOT_BLOCK="$(extract_between "$H" '^for c in ' '^did "protected set spot-check')"

spot_run() { # <present commands...>
  local d; d="$(stubdir)"
  local c
  for c in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$c"; chmod 0755 "$d/$c"; done
  # env -i so only the stub directory is searched: the laptop running this test has a real
  # systemctl-ish PATH and would make every case pass. bash is invoked by ABSOLUTE path, because a
  # PATH holding only the stubs cannot find bash either — and `exit 127, env: bash: not found` is a
  # red that would have scored as the refusal this case wants, for entirely the wrong reason.
  env -i PATH="$d" HOME=/nonexistent "$BASH" -c "$PRE
have_cmd() { command -v \"\$1\" >/dev/null 2>&1; }
$SPOT_BLOCK"
}

run_check hardening.spotcheck green "bootc and systemctl are both present" -- spot_run bootc systemctl
run_check hardening.spotcheck red   "bootc was removed — the image could never be patched again" -- spot_run systemctl
assert_has "names bootc specifically" "bootc is missing after hardening" "$T_LAST_OUT"
run_check hardening.spotcheck red   "systemctl was removed" -- spot_run bootc
assert_has "names systemctl specifically" "systemctl is missing after hardening" "$T_LAST_OUT"
run_check hardening.spotcheck red   "both were removed" -- spot_run

t_finish "10-hardening.sh"

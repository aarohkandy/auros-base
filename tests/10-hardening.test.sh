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
MASK_FN="$(extract_fn "$REPO/build/00-common.sh" mask_unit | rootify /etc/systemd/system /usr/lib/systemd/system)"

TELEM_PRE="$PRE"'
have_unit() { [ -e "$ROOT/usr/lib/systemd/system/$1" ]; }
have_pkg()  { case " $FAKE_PKGS " in *" $1 "*) return 0;; *) return 1;; esac; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
rpm() { echo "1.0-1"; }
_systemctl_offline() { return 0; }
enable_unit() { echo "ENABLED $1"; }
'"$MASK_FN"

MASK_ROWS="$(awk -F'\t' '$1=="unit-mask"{print $2}' "$TSV")"
KEEP_ROWS="$(awk -F'\t' '$1=="unit-keep"{print $2}' "$TSV")"
[ -n "$MASK_ROWS" ] || t_abort "telemetry.tsv has no unit-mask rows — this test would be vacuous"

telem_run() { # <root>
  ROOT="$1" FAKE_PKGS="libreport geoclue2" tsv="$TSV" bash -c "$TELEM_PRE
$TELEM_BLOCK"
}

# All units present: every unit-mask row must produce a /dev/null symlink.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
for u in $MASK_ROWS $KEEP_ROWS; do : > "$R/usr/lib/systemd/system/$u"; done
run_check telemetry.loop green "the whole table runs against an image containing every unit" -- telem_run "$R"
for u in $MASK_ROWS; do
  assert_symlink_to "masked $u" "$R/etc/systemd/system/$u" /dev/null
  assert_has "and said so in the build console" "MASKED    $u" "$T_LAST_OUT"
done
for u in $KEEP_ROWS; do
  assert_nofile "did NOT mask the deliberately-kept $u" "$R/etc/systemd/system/$u"
  assert_has "and named it as kept on purpose" "KEPT ON   $u" "$T_LAST_OUT"
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

t_finish "10-hardening.sh"

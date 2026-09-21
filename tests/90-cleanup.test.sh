#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/90-cleanup.test.sh — the last build step, against a synthetic fake root.
#
# 90-cleanup.sh has two jobs and both of them are claims we make in public:
#
#   "nothing from the build survives into the image"      — the build scripts, the package caches,
#                                                            the logs written while installing.
#   "nothing non-deterministic survives either"           — check S7 builds twice and compares
#                                                            content digests.
#
# and one job that is a safety gate rather than housekeeping:
#
#   "nothing this build did removed the update path"      — check S10. A recipe that prunes its own
#                                                            update path produces a machine we can
#                                                            never patch again, which is exactly the
#                                                            abandoned laptop we sell against.
#
# THE MOST IMPORTANT BLOCK IN THAT FILE, by its own comment, is the per-machine identity removal: an
# image is installed onto every machine in a school, so anything unique-per-machine that survives the
# build becomes shared-across-the-fleet. One baked ssh host key means one stolen laptop authenticates
# as all of them. Those are tested here in both directions — the check has to notice.
#
# A BUG THIS FILE FOUND AND THE FIX IS NOW PINNED BY THE CASE BELOW:
#   check_one()'s `*) return 0 ;;` default meant a typo in protected.list's KIND column produced
#   "PROTECTED ok" for a row that checked nothing at all. `fatal<TAB>cmb<TAB>bootc` passed on an
#   image with no bootc. The protected set was one silently-inert row away from being decoration, in
#   the file whose entire purpose is to make an unpatchable machine unshippable.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

C="$REPO/build/90-cleanup.sh"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
# The shim (and any other stub) must be ahead of the real tools for every block this file runs.
# Without this the build scripts' GNU `sed -i` silently became a BSD `sed -i <suffix>` and corrupted
# the file it was meant to edit, while still exiting 0.
export PATH="$STUBS:$PATH"

printf '90-cleanup.sh — the last build step  (%s)\n' "$T_SED_MODE"

PRE='set -uo pipefail
step() { :; }
did()  { echo "DID $*"; }
found(){ echo "FOUND $*"; }
warn() { echo "WARN $*"; }
die()  { echo "DIE $*" >&2; exit 1; }
record(){ :; }
'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the protected set — check_one(), one case per kind, each in both directions"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
CHECK_ONE="$(extract_fn "$C" check_one)"

one_case() { # <kind> <target> [present-pkg] [present-unit] [file:content]
  local root; root="$(newroot)"
  local bin="$root/bin"; mkdir -p "$bin"
  # have_cmd / have_pkg / have_unit come from 00-common.sh; they are stubbed here because their own
  # behaviour is 00-common's to test, not this block's.
  printf '%s' "${5:-}" > "$root/content" 2>/dev/null || true
  ROOT="$root" FAKE_PKG="${3:-}" FAKE_UNIT="${4:-}" bash -c "$PRE
have_cmd()  { [ \"\$1\" = \"${3:-}\" ]; }
have_pkg()  { [ \"\$1\" = \"${3:-}\" ]; }
have_unit() { [ \"\$1\" = \"${4:-}\" ]; }
$CHECK_ONE
check_one '$1' '$2'"
}

run_check protected.kind-cmd  green "cmd bootc, and bootc is on PATH"        -- one_case cmd  bootc bootc
run_check protected.kind-cmd  red   "cmd bootc, and bootc is gone"           -- one_case cmd  bootc ""
run_check protected.kind-pkg  green "pkg greenboot, and it is installed"     -- one_case pkg  greenboot greenboot
run_check protected.kind-pkg  red   "pkg greenboot, and it is not"           -- one_case pkg  greenboot ""
run_check protected.kind-unit green "unit the timer, and systemd knows it"   -- one_case unit bootc-fetch-apply-updates.timer "" bootc-fetch-apply-updates.timer
run_check protected.kind-unit red   "unit the timer, and systemd does not"   -- one_case unit bootc-fetch-apply-updates.timer "" ""

R="$(newroot)"; mkdir -p "$R/usr/lib/bootc/kargs.d"
run_check protected.kind-path green "path that exists" -- bash -c "$PRE
$CHECK_ONE
check_one path '$R/usr/lib/bootc/kargs.d'"
run_check protected.kind-path red "path that does not exist" -- bash -c "$PRE
$CHECK_ONE
check_one path '$R/usr/lib/bootc/nope'"

# The `content` kind exists because a bare path check would be VACUOUS for exactly the file D8 is
# about: /etc/containers/policy.json is present on the upstream base already and verifies nothing.
# So both halves matter — the file existing, and the file saying the right thing.
R="$(newroot)"; mkdir -p "$R/etc/containers"
printf '{"transports":{"docker":{"ghcr.io/aarohkandy":[{"type":"sigstoreSigned"}]}}}\n' > "$R/etc/containers/policy.json"
run_check protected.kind-content green "content, and the file matches" -- bash -c "$PRE
$CHECK_ONE
check_one content '$R/etc/containers/policy.json::sigstoreSigned'"
printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "$R/etc/containers/policy.json"
run_check protected.kind-content red "content, and the file EXISTS but does not match — the D8 state" -- bash -c "$PRE
$CHECK_ONE
check_one content '$R/etc/containers/policy.json::sigstoreSigned'"
rm -f "$R/etc/containers/policy.json"
run_check protected.kind-content red "content, and the file is absent" -- bash -c "$PRE
$CHECK_ONE
check_one content '$R/etc/containers/policy.json::sigstoreSigned'"

# THE REGRESSION. An unrecognised kind must refuse, not pass. `return 0` here meant a typo in the
# KIND column of protected.list silently disabled that protection and printed "PROTECTED ok".
for typo in cmb pkgs untit contents ''; do
  run_check protected.unknown-kind red "an unknown kind '${typo:-<empty>}' is refused, not treated as satisfied" \
    -- one_case "$typo" bootc ""
done
run_check protected.unknown-kind green "a recognised kind is not refused" -- one_case cmd bootc bootc

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the protected set — the whole loop, against the list we actually ship"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The list is real; only the image around it is synthetic. A `fatal` row that is not satisfied must
# stop the build; a `pending` row that is not satisfied must be reported loudly and must NOT, because
# those are installed by build steps this script does not own and one task's unlanded work cannot be
# allowed to block every build in the repo.
PLIST="$REPO/hardening/protected.list"
[ -f "$PLIST" ] || t_abort "hardening/protected.list is missing"
LOOP="$(extract_between "$C" '^if \[ -n "\$plist" \]; then' '^did "protected set intact"')"

FATAL_CMDS="$(awk -F'\t' '$1=="fatal" && $2=="cmd"{print $3}' "$PLIST")"
FATAL_PKGS="$(awk -F'\t' '$1=="fatal" && $2=="pkg"{print $3}' "$PLIST")"
FATAL_PATHS="$(awk -F'\t' '$1=="fatal" && $2=="path"{print $3}' "$PLIST")"
[ -n "$FATAL_CMDS" ] || t_abort "protected.list has no fatal cmd rows — this test would be vacuous"

loop_case() { # <drop-cmd> <drop-path>
  local root; root="$(newroot)"
  local cmds="$FATAL_CMDS" paths="$FATAL_PATHS" p
  [ -n "$1" ] && cmds="$(printf '%s\n' $cmds | grep -vx "$1" || true)"
  for p in $FATAL_PATHS; do
    [ "$p" = "${2:-}" ] && continue
    mkdir -p "$root/$(dirname "$p")" 2>/dev/null || true
    : > "$root/$p" 2>/dev/null || mkdir -p "$root/$p"
  done
  ROOT="$root" plist="$PLIST" PRESENT_CMDS="$(printf '%s' "$cmds" | tr '\n' ' ')" PRESENT_PKGS="$(printf '%s' "$FATAL_PKGS greenboot" | tr '\n' ' ')" bash -c "$PRE
have_cmd()  { case \" \$PRESENT_CMDS \" in *\" \$1 \"*) return 0;; *) return 1;; esac; }
have_pkg()  { case \" \$PRESENT_PKGS \" in *\" \$1 \"*) return 0;; *) return 1;; esac; }
have_unit() { return 1; }
fatal_missing=""
pending_missing=""
$CHECK_ONE
check_one() { local kind=\"\$1\" target=\"\$2\"
  case \"\$kind\" in
    cmd) have_cmd \"\$target\" ;;
    pkg) have_pkg \"\$target\" ;;
    unit) have_unit \"\$target\" ;;
    path) [ -e \"\$ROOT\$target\" ] ;;
    content) f=\"\${target%%::*}\"; pat=\"\${target#*::}\"; [ -f \"\$ROOT\$f\" ] && grep -qE -- \"\$pat\" \"\$ROOT\$f\" ;;
    *) die \"unknown kind \$kind\" ;;
  esac
}
$LOOP"
}

run_check protected.loop green "every fatal row satisfied; pending rows are not, and that is allowed" -- loop_case '' ''
assert_has "reports the pending rows loudly" "NOT YET PRESENT" "$T_LAST_OUT"
assert_has "and explains why they are not fatal" "S10 will refuse to publish" "$T_LAST_OUT"

for c in $FATAL_CMDS; do
  run_check protected.loop red "the build removed '$c' — a fatal row" -- loop_case "$c" ''
  assert_has "refuses to produce the image" "PROTECTED SET BROKEN" "$T_LAST_OUT"
  assert_has "names what went missing" "cmd:$c" "$T_LAST_OUT"
done
for p in $FATAL_PATHS; do
  run_check protected.loop red "the build removed '$p' — a fatal row" -- loop_case '' "$p"
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "no build context survives"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The assertion is `[ ! -e "$AUROS_BUILD_DIR" ] || die`. The failure it exists for is an rm that
# returned 0 while leaving something behind — a mount, a busy file, an immutable attribute — which is
# invisible to `rm -rf`'s exit code and would ship every build script into a customer's image.
CTX_BLOCK="$(extract_between "$C" 'rm -rf "\$AUROS_BUILD_DIR"' 'did "removed the build context')"

ctx_case() { # <undeletable?>
  local root; root="$(newroot)"
  mkdir -p "$root/tmp/auros-build/build" "$root/tmp" "$root/var/tmp"
  cp "$C" "$root/tmp/auros-build/build/90-cleanup.sh"
  if [ "$1" = undeletable ]; then chmod 0500 "$root/tmp/auros-build"; fi
  AUROS_BUILD_DIR="$root/tmp/auros-build" bash -c "$PRE
$(printf '%s' "$CTX_BLOCK" | sed 's#rm -rf /tmp/\* /var/tmp/\* 2>/dev/null || true##')"
  local rc=$?
  chmod 0700 "$root/tmp/auros-build" 2>/dev/null || true
  return $rc
}

run_check cleanup.context green "the build context is removed and the removal is verified" -- ctx_case deletable
run_check cleanup.context red   "something survived the removal" -- ctx_case undeletable
assert_has "says what still exists" "still exists after removing it" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "per-machine identity — the most important block in the file"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# An image goes onto every machine in a school. Anything unique-per-machine that survives the build
# becomes shared across the fleet: one baked ssh host key means one stolen image authenticates as
# every laptop; a populated machine-id breaks per-machine journald and DHCP identity at once.
#
# machine-id must be EMPTY, not absent: empty is the documented signal that makes systemd provision a
# fresh id on first boot, while absent is not the same thing. Both wrong states are tested.
IDENT_BLOCK="$(extract_between "$C" "^if compgen -G '/etc/ssh/ssh_host_\*'" '^fi$' \
  | rootify /etc/ssh /var/lib/systemd/random-seed /var/lib/random-seed)
$(extract_between "$C" '^: > /etc/machine-id' '^did "removed any baked systemd random seed"' \
  | rootify /etc/machine-id /var/lib/systemd/random-seed /var/lib/random-seed)"

ident_case() {
  local root; root="$(newroot)"
  mkdir -p "$root/etc/ssh" "$root/var/lib/systemd" "$root/var/lib"
  printf 'PRIVATE KEY\n'  > "$root/etc/ssh/ssh_host_ed25519_key"
  printf 'ssh-ed25519 AA\n' > "$root/etc/ssh/ssh_host_ed25519_key.pub"
  printf 'PRIVATE KEY\n'  > "$root/etc/ssh/ssh_host_rsa_key"
  printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "$root/etc/machine-id"
  printf 'entropy'        > "$root/var/lib/systemd/random-seed"
  ROOT="$root" bash -c "$PRE
$IDENT_BLOCK" >/dev/null 2>&1
  printf '%s' "$root"
}

R="$(ident_case)"
assert_eq  "removed every baked ssh host key" "0" "$(ls -1 "$R/etc/ssh/" 2>/dev/null | wc -l | tr -d ' ')"
assert_file "machine-id still exists"          "$R/etc/machine-id"
assert_eq  "machine-id is EMPTY, not deleted"  "0" "$(wc -c < "$R/etc/machine-id" | tr -d ' ')"
assert_nofile "the random seed is gone"        "$R/var/lib/systemd/random-seed"

# The direction that matters: a test that only ran the removal would pass even if the removal were a
# no-op, because it would be asserting the same state it created. So assert that the fixture really
# did start in the bad state — otherwise the four assertions above prove nothing.
R2="$(newroot)"; mkdir -p "$R2/etc/ssh"; printf 'PRIVATE KEY\n' > "$R2/etc/ssh/ssh_host_ed25519_key"
assert_file "control: the fixture does start with a baked host key" "$R2/etc/ssh/ssh_host_ed25519_key"
t_exempt cleanup.identity \
  "this block removes state rather than deciding anything, so it has no exit code to score in two
       directions. The direction is asserted on the FILESYSTEM instead: the fixture is built in the
       unsafe state, the block is run, and the unsafe state must be gone. The control two lines above
       is what stops that from being a test of its own fixture."
_t_record cleanup.identity green

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "/var/log is empty, and package leftovers are gone"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# /var/log is both a lint failure (`bootc container lint` checks it) and a determinism failure: its
# contents are a minute-by-minute record of the build, so two builds of the same tree differ in it.
ROOTIFY_LOG=(/var/log /var/lib/systemd/catalog/database /var/cache/man /var/lib/rpm-state /root/.cache /root/.dnf /root/.rpmdb /etc /usr)
LOG_BLOCK="$(extract_between "$C" '^if \[ -d /var/log \]; then' '^fi$' | rootify "${ROOTIFY_LOG[@]}")
$(extract_between "$C" '^leftovers="' '^fi$' | rootify "${ROOTIFY_LOG[@]}")"

R="$(newroot)"
mkdir -p "$R/var/log/journal/abc" "$R/etc" "$R/usr/share"
printf 'build log\n' > "$R/var/log/dnf.log"
printf 'x\n'         > "$R/var/log/journal/abc/system.journal"
printf 'old\n'       > "$R/etc/sudoers.rpmnew"
printf 'old\n'       > "$R/usr/share/thing.rpmorig"
out="$(ROOT="$R" bash -c "$PRE
$LOG_BLOCK" 2>&1)"
assert_eq  "/var/log has no entries left" "0" "$(find "$R/var/log" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_file "but /var/log itself still exists" "$R/var/log"
assert_nofile "the .rpmnew leftover is gone"   "$R/etc/sudoers.rpmnew"
assert_nofile "the .rpmorig leftover is gone"  "$R/usr/share/thing.rpmorig"
assert_has "and said which leftovers it removed" "removing package leftover" "$out"

# The same block against an image that was already clean must say so rather than claim it removed
# something. "We looked and there was nothing" and "we removed things" are different sentences and
# the build console ships both.
R="$(newroot)"; mkdir -p "$R/var/log" "$R/etc" "$R/usr"
out="$(ROOT="$R" bash -c "$PRE
$LOG_BLOCK" 2>&1)"
assert_has "reports no leftovers when there are none" "no .rpmnew/.rpmorig leftovers" "$out"
assert_not "and does not claim to have removed any"   "removing package leftover" "$out"
t_exempt cleanup.logs \
  "housekeeping, not a decision: this block removes files and cannot refuse anything, so it has no
       red direction. It is asserted on the resulting filesystem and on the two DIFFERENT sentences it
       prints for a dirty and a clean image, which is where a silent no-op would show up."
_t_record cleanup.logs green
# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "determinism — dnf5's history journal does not ship (the S7 cause in run 35564325340)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
DNF5_BLOCK="$(extract_between "$C" '^sqlite_sidecars="' '^did "dnf5 history journal checked"' | rootify /usr/lib/sysimage)"
dnf5_root() {
  local r; r="$(newroot)"; mkdir -p "$r/usr/lib/sysimage/libdnf5"
  printf 'main db\n' > "$r/usr/lib/sysimage/libdnf5/transaction_history.sqlite"
  printf 'wal\n'     > "$r/usr/lib/sysimage/libdnf5/transaction_history.sqlite-wal"
  printf 'shm\n'     > "$r/usr/lib/sysimage/libdnf5/transaction_history.sqlite-shm"
  printf '%s' "$r"
}
dnf5_run() { ROOT="$1" PATH="${2:-$PATH}" bash -c "$PRE
$DNF5_BLOCK"; }
R="$(dnf5_root)"
run_check cleanup.dnf5 green "the journal files are removed and the check is satisfied" -- dnf5_run "$R"
assert_nofile "transaction_history.sqlite-wal is gone" "$R/usr/lib/sysimage/libdnf5/transaction_history.sqlite-wal"
assert_nofile "transaction_history.sqlite-shm is gone" "$R/usr/lib/sysimage/libdnf5/transaction_history.sqlite-shm"
assert_file   "the history database itself is kept"   "$R/usr/lib/sysimage/libdnf5/transaction_history.sqlite"
# RED: an rm that does nothing (a read-only layer, a changed path) must fail the build, not ship.
NORM="$(stubdir)"; printf '#!/bin/sh\nexit 0\n' > "$NORM/rm"; chmod +x "$NORM/rm"
R="$(dnf5_root)"
run_check cleanup.dnf5 red "a journal that survives removal fails the build" -- dnf5_run "$R" "$NORM:$PATH"
assert_has "…and says why" "would differ (S7)" "$T_LAST_OUT"
R="$(newroot)"; mkdir -p "$R/usr/lib/sysimage/libdnf5"
assert_has "a clean image says there was nothing, not that it removed something" "no dnf5 history journal" "$(dnf5_run "$R" 2>&1)"


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "determinism — nothing the cleanup writes carries a timestamp"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Check S7 builds the image twice in one CI run and compares content digests. The manifest ships in
# the image and is the customer-readable account of what the build did, so it is the file most likely
# to acquire a timestamp in a hurry. It is sorted rather than appended-in-order for the same reason:
# two builds whose steps interleaved differently must still produce the same bytes.
MAN_BLOCK="$(extract_between "$C" '^if \[ -f "\$AUROS_MANIFEST" \]; then' '^fi$')"
R="$(newroot)"; mkdir -p "$R/usr/lib/auros"
printf '40-windows-feel\twrote-file\t/etc/xdg/kdeglobals\n10-hardening\tmasked-unit\tsshd.service\n00-common\twrote-file\t/usr/lib/auros/release\n' \
  > "$R/usr/lib/auros/build-steps.tsv"
out="$(AUROS_MANIFEST="$R/usr/lib/auros/build-steps.tsv" SOURCE_DATE_EPOCH=1789504430 bash -c "$PRE
$MAN_BLOCK" 2>&1)"
assert_eq "the manifest is sorted" \
  "00-common	wrote-file	/usr/lib/auros/release" \
  "$(head -1 "$R/usr/lib/auros/build-steps.tsv")"
assert_not "the manifest carries no ISO date" "$(date -u +%Y-%m-%d)" "$(cat "$R/usr/lib/auros/build-steps.tsv")"
t_exempt cleanup.manifest \
  "sorting and re-stamping, with no refusal to make. Asserted on the resulting bytes, which is the
       only thing check S7 can see."
_t_record cleanup.manifest green

# The shipped scripts must not write a timestamp into anything that lands in the image. Grepping for
# a date call in the build scripts is cheap and catches the reintroduction directly.
for f in "$REPO"/build/*.sh; do
  bad_date="$(grep -nE '^[^#]*\$\(date[^)]*\)' "$f" | grep -v 'SOURCE_DATE_EPOCH' || true)"
  if [ -z "$bad_date" ]; then
    ok "no unpinned date(1) call lands in an image file: $(basename "$f")"
  else
    bad "$(basename "$f") calls date(1) outside SOURCE_DATE_EPOCH — check S7 compares two builds: $bad_date"
  fi
done


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the protected set — the FALLBACK, for when protected.list was not preserved"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# `plist=""` is not a hypothetical: the list is copied into the image by 10-hardening.sh, and this
# script runs after the build context has been deleted. If that copy ever fails to arrive, the
# fallback is the entire protected-set gate — and it is two command names. bootc is the one that
# matters, because bootc IS the update path: an image without it can never be patched again, by
# anyone, for the life of the machine.
#
# The loop group above always supplies the real list, so the fallback branch had never run.
FALLBACK_BLOCK="$(extract_between "$C" '^if \[ -n "\$plist" \]; then' '^did "protected set intact"')"

fallback_run() { # <present commands...>
  local d c
  d="$(stubdir)"
  for c in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$c"; chmod 0755 "$d/$c"; done
  # bash by absolute path: a PATH holding only the stubs cannot find bash either, and
  # "env: bash: not found" is a red that a case expecting a refusal would score as a success.
  env -i PATH="$d" HOME=/nonexistent "$BASH" -c "$PRE
have_cmd()  { command -v \"\$1\" >/dev/null 2>&1; }
have_pkg()  { return 1; }
have_unit() { return 1; }
plist=\"\"
fatal_missing=\"\"
pending_missing=\"\"
check_one() { return 1; }
$FALLBACK_BLOCK"
}

run_check protected.fallback green "no protected.list, and both fallback commands are present" -- fallback_run bootc systemctl
assert_has "says the protected set is intact" "protected set intact" "$T_LAST_OUT"

run_check protected.fallback red "no protected.list, and bootc is gone — an unpatchable image" -- fallback_run systemctl
assert_has "refuses to produce the image" "PROTECTED SET BROKEN" "$T_LAST_OUT"
assert_has "and names bootc"              "cmd:bootc"            "$T_LAST_OUT"
assert_has "saying what it costs"         "never update"         "$T_LAST_OUT"

run_check protected.fallback red "no protected.list, and systemctl is gone" -- fallback_run bootc
assert_has "names systemctl" "cmd:systemctl" "$T_LAST_OUT"
run_check protected.fallback red "no protected.list and neither command is present" -- fallback_run

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "build scratch files do not ship"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# `rm -rf /tmp/* /var/tmp/*` sits in the middle of the build-context removal and has no assertion
# after it, so deleting it is completely silent. What it costs is not dramatic — leftover scratch
# files are a determinism problem (check S7 builds twice and compares content digests) and a small
# disclosure one, since whatever a build step happened to write to /tmp ships to a customer.
#
# The ctx group above deliberately seds this line OUT of the block before running it, because the
# literal `/tmp/*` in a test running on a laptop is not something to point at the real /tmp. That
# left the line itself untested by anything. Here the same block is run with /tmp and /var/tmp
# REWRITTEN INTO THE FAKE ROOT instead of removed, so the line under test is the shipping line.
SCRATCH_BLOCK="$(extract_between "$C" 'rm -rf "\$AUROS_BUILD_DIR"' 'did "removed the build context' \
  | rootify /var/tmp /tmp)"
SCRATCH_ROOTED=1
case "$SCRATCH_BLOCK" in
  *'$ROOT/tmp/'*) ;;
  *) SCRATCH_ROOTED=0 ;;
esac
if [ "$SCRATCH_ROOTED" = 0 ]; then
  bad "the build-inputs block no longer removes anything under /tmp — every build scratch file would ship in the image, and check S7 (build twice, compare content digests) would fail far from the cause"
  note "the block was NOT executed: with nothing to rootify, its /tmp/* would have been the laptop's real /tmp"
  _t_record cleanup.scratch red
fi
if [ "$SCRATCH_ROOTED" = 1 ]; then

scratch_run() { # <root>
  ROOT="$1" AUROS_BUILD_DIR="$1/tmp/auros-build" bash -c "$PRE
$SCRATCH_BLOCK"
}

R="$(newroot)"
mkdir -p "$R/tmp/auros-build/build" "$R/tmp/scratch" "$R/var/tmp"
printf 'a package list step 20 wrote\n' > "$R/tmp/leftover"
printf 'x\n'                            > "$R/tmp/scratch/nested"
printf 'a tarball somebody downloaded\n' > "$R/var/tmp/leftover"
# THE CONTROL. Without these, the four assertions below would be a test of their own fixture: an
# empty /tmp is also a /tmp with nothing left in it, and `rm -rf` on nothing exits 0.
assert_file "control: the fixture starts with a scratch file in /tmp"     "$R/tmp/leftover"
assert_file "control: and a nested one"                                   "$R/tmp/scratch/nested"
assert_file "control: and one in /var/tmp"                                "$R/var/tmp/leftover"

run_check cleanup.scratch green "the build-inputs removal runs over a dirty /tmp" -- scratch_run "$R"
assert_nofile "/tmp/leftover does not ship"     "$R/tmp/leftover"
assert_nofile "nor does /tmp/scratch"           "$R/tmp/scratch"
assert_nofile "nor does /var/tmp/leftover"      "$R/var/tmp/leftover"
assert_nofile "and the build context is gone"   "$R/tmp/auros-build"
assert_file   "while the directories themselves survive" "$R/tmp"

fi

t_exempt cleanup.scratch \
  "the shipping line is \`rm -rf /tmp/* /var/tmp/* 2>/dev/null || true\` — deliberately non-fatal,
       because a scratch file that will not delete is a determinism problem and not a reason to fail
       an otherwise good build. It has no exit code of its own to score in two directions. The
       direction is asserted on the FILESYSTEM instead: the fixture is built dirty (the three control
       assertions above), the line is run, and the dirt must be gone. Removing the line makes those
       assertions fail, which is the property this group exists for."

t_finish "90-cleanup.sh"

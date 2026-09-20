#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# auros-base/tests/prove-red.sh — prove the test suite can catch the bugs it was written for.
#
# WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL
#
# tests/run-all.sh going green tells you the assertions agree with the code. It does not tell you the
# assertions would DISAGREE with wrong code — and that is the only question that matters, because the
# two failures this repository has already shipped were both assertions that could not disagree with
# anything:
#
#   permanently RED    `grep selinux=0` matched its own file's explanatory comment
#   permanently GREEN  `tr -d '[:space:]'` deleted the newlines, so `^selinux=0$` never matched
#
# So each case below REINTRODUCES a specific bug into a scratch copy of the repository and requires
# the suite that is supposed to notice to go red. A case that stays green is reported as a failure of
# this file, not of the mutation: it means the test is decoration.
#
# Nothing here touches the working tree. Each mutation runs against its own `cp -R` copy under a
# temporary directory, which is removed afterwards.
#
# RUN:  bash auros-base/tests/prove-red.sh
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

c() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
PASS=0; FAIL=0; FAILED=()
WORK="$(mktemp -d "${TMPDIR:-/tmp}/auros-prove-red.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# mutate <label> <suite-relative-path> <expect-lines...> — copies the repo, applies the mutation from
# stdin (a python3 program with $REPO as cwd), runs the suite, and requires it to FAIL.
#
# `expect` is an optional substring that must appear in the failing output, so that a mutation which
# happens to break the suite for an unrelated reason is not counted as the test having caught the bug.
# ONLY="<substring>" as the first argument runs just the mutations whose label matches. The whole
# file copies the repository once per case, so iterating on one of them without this is slow enough
# that somebody would stop running it.
ONLY="${1:-}"
n=0
mutate() { # <label> <suite> [expect-substring]
  local label="$1" suite="$2" expect="${3:-}"
  if [ -n "$ONLY" ]; then case "$label" in *"$ONLY"*) ;; *) cat >/dev/null; return ;; esac; fi
  n=$((n+1))
  local dir="$WORK/m$n"
  cp -R "$REPO" "$dir"
  rm -rf "$dir/.git"
  local prog; prog="$(cat)"
  if ! (cd "$dir" && printf '%s' "$prog" | python3 -) >"$WORK/mut.log" 2>&1; then
    printf '  %s %s\n' "$(c 31 'SETUP')" "$label — the mutation itself did not apply; the code it edits has moved"
    sed 's/^/        /' "$WORK/mut.log"
    FAIL=$((FAIL+1)); FAILED+=("$label (mutation failed to apply)")
    return
  fi
  local out rc
  out="$(cd "$dir" && bash "$suite" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  %s %s\n' "$(c 31 'NOT CAUGHT')" "$label"
    printf '        %s\n' "$(c 31 "$suite stayed GREEN with the bug reintroduced — that test is decoration")"
    FAIL=$((FAIL+1)); FAILED+=("$label")
  elif [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
    printf '  %s %s\n' "$(c 31 'WRONG RED')" "$label"
    printf '        %s\n' "the suite failed, but not on [$expect] — it may be failing for an unrelated reason"
    printf '%s\n' "$out" | grep -E 'FAIL|ABORT' | head -5 | sed 's/^/        /'
    FAIL=$((FAIL+1)); FAILED+=("$label (wrong reason)")
  else
    printf '  %s   %s\n' "$(c 32 'caught')" "$label"
    printf '%s\n' "$out" | grep -E '^ +FAIL' | head -2 | sed 's/^ *FAIL */          → /'
    PASS=$((PASS+1))
  fi
  rm -rf "$dir"
}

printf '%s\n' "$(c 1 'Reintroducing each bug these tests were written for. Every one must be caught.')"
printf '\n%s\n' "$(c 1 'build/10-hardening.sh — the SELinux kernel-argument check')"

mutate "the pre-2026-09-20 per-line kargs reader: a multi-line TOML array is invisible to it" \
       tests/kargs-check.test.sh "on its own line inside the array" <<'MUT'
import re
p = 'build/10-hardening.sh'
s = open(p).read()
start = s.index('_auros_effective_kargs() {')
# Replace only the kargs.d loop, leaving the ostree-boot half intact, so the mutation is exactly the
# old implementation of the part that changed and nothing else.
loop_start = s.index('  for f in /usr/lib/bootc/kargs.d/*.toml; do', start)
loop_end = s.index('  done\n', loop_start) + len('  done\n')
old = '''  for f in /usr/lib/bootc/kargs.d/*.toml; do
    [ -e "$f" ] || continue
    sed 's/#.*$//' "$f" | sed -n 's/.*kargs[[:space:]]*=[[:space:]]*\\[\\(.*\\)\\].*/\\1/p' | tr ',' '\\n' | tr -d '"'"'"' []'
  done
'''
open(p, 'w').write(s[:loop_start] + old + s[loop_end:])
MUT

mutate "the permanently-green original: tr -d '[:space:]' eats the newlines too" \
       tests/kargs-check.test.sh <<'MUT'
p = 'tests/kargs-check.test.sh'
s = open(p).read()
# The bug lived in the CALLER, which is why the test reproduces the caller. Mutating the test's copy
# of the caller is mutating the thing that shipped.
assert "tr -d ' \\t'" in s
open(p, 'w').write(s.replace("tr -d ' \\t'", "tr -d '[:space:]'"))
MUT

printf '\n%s\n' "$(c 1 'build/00-common.sh — the preflight')"

mutate "no image-name check: a FROM naming any registry at all is accepted" \
       tests/00-common.test.sh "FROM names" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
start = s.index('  local upstream_image mirror_image')
end = s.index('  did "base image: ${UPSTREAM_IMAGE:-$lock_image}"')
open(p, 'w').write(s[:start] + s[end:])
MUT

mutate "the digest comparison is dropped, so base.lock and the Containerfile may disagree" \
       tests/00-common.test.sh "preflight.digest" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  if [ "$UPSTREAM_DIGEST" != "$lock_digest" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, '  if false; then'))
MUT

mutate "mask_unit trusts systemctl's exit code instead of the filesystem" \
       tests/00-common.test.sh "mask_unit" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  [ "$(readlink -f "$link")" = "/dev/null" ] || die "failed to mask $u'
assert old in s
i = s.index(old)
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '  :' + s[j:])
MUT

printf '\n%s\n' "$(c 1 'hardening — the runtime assertion')"

mutate "sshd 'disabled' is accepted as good enough, instead of requiring 'masked'" \
       tests/10-hardening.test.sh "hardening.sshd" <<'MUT'
p = 'hardening/hardening-assert.sh'
s = open(p).read()
old = '  if [ "$state" = "masked" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, '  if [ "$state" = "masked" ] || [ "$state" = "disabled" ]; then'))
MUT

mutate "the firewall zone target is no longer checked, so ACCEPT passes" \
       tests/10-hardening.test.sh "hardening.firewall" <<'MUT'
p = 'hardening/hardening-assert.sh'
s = open(p).read()
old = '    "%%REJECT%%"|REJECT|DROP) pass "zone auros target is \'$target\' (default-deny)" ;;'
assert old in s
open(p, 'w').write(s.replace(old, '    *) pass "zone auros target is \'$target\'" ;;\n    "@never@")'))
MUT

mutate "the NOPASSWD ordering test is inverted: a drop-in sorting AFTER ours is called harmless" \
       tests/10-hardening.test.sh "hardening.nopasswd-order" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = '  if [[ "$(basename "$f")" > "50-auros-baseline" ]]; then'
assert old in s
open(p, 'w').write(s.replace(old, '  if [[ "$(basename "$f")" < "50-auros-baseline" ]]; then'))
MUT

printf '\n%s\n' "$(c 1 'build/30-update-agent.sh — the safety-critical layer')"

mutate "the greenboot capability map is removed, so an image with no rollback trigger builds" \
       tests/30-update-agent.test.sh "greenboot.capabilities" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
start = s.index('if [ ${#_gb_missing[@]} -gt 0 ]; then')
end = s.index('did "greenboot capabilities verified')
open(p, 'w').write(s[:start] + s[end:])
MUT

mutate "the GRUB fragment is checked for existence but not for boot_counter logic" \
       tests/30-update-agent.test.sh "greenboot.grub-fragment" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "grep -q 'boot_counter' \"$GB_FRAGMENT\" || die"
assert old in s
open(p, 'w').write(s.replace(old, "true || die"))
MUT

mutate "a required health check returns 0 unconditionally — installed, and rollback silently off" \
       tests/30-update-agent.test.sh "gb.30-timer" <<'MUT'
p = 'update-agent/greenboot/check/required.d/30-update-timer-enabled.sh'
s = open(p).read()
old = 'fail() { echo "FAIL: $*" >&2; exit 1; }'
assert old in s
open(p, 'w').write(s.replace(old, 'fail() { echo "FAIL: $*" >&2; exit 0; }'))
MUT

mutate "the black-screen check stops waiting for the display manager and just passes" \
       tests/30-update-agent.test.sh "gb.20-graphical" <<'MUT'
p = 'update-agent/greenboot/check/required.d/20-graphical-target.sh'
s = open(p).read()
old = '    wait_for_active display-manager.service \\'
assert old in s
open(p, 'w').write(s.replace(old, '    true || wait_for_active display-manager.service \\'))
MUT

mutate "the network check demands internet connectivity — the bug that rolls a school back overnight" \
       tests/30-update-agent.test.sh "OFFLINE" <<'MUT'
p = 'update-agent/greenboot/check/required.d/10-network-stack.sh'
s = open(p).read()
old = 'state="$(nmcli -t -f STATE general status 2>/dev/null || echo unknown)"'
assert old in s
open(p, 'w').write(s.replace(old, old + '\n[ "$state" = connected ] || fail "no connectivity"'))
MUT

mutate "GREENBOOT_MAX_BOOT_ATTEMPTS is appended without deleting the old line, so the file gains two" \
       tests/30-update-agent.test.sh "greenboot.max-attempts" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "sed -i '/^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=/d' \"$CONF\""
assert old in s
open(p, 'w').write(s.replace(old, 'true'))
MUT

mutate "the build and the health check drift onto two different timer names" \
       tests/30-update-agent.test.sh "same timer" <<'MUT'
p = 'update-agent/greenboot/check/required.d/30-update-timer-enabled.sh'
s = open(p).read()
old = 'TIMER=bootc-fetch-apply-updates.timer'
assert old in s
open(p, 'w').write(s.replace(old, 'TIMER=uupd.timer'))
MUT

printf '\n%s\n' "$(c 1 'build/40-windows-feel.sh — the Windows-familiarity layer')"

mutate "the double-click check goes back to a group-blind grep" \
       tests/40-windows-feel.test.sh "click.double" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
start = s.index('_auros_ini_value() {')
end = s.index('record windows-default "double-click"')
new = """grep -qx 'SingleClick=false' /etc/xdg/kdeglobals \\
  || die "SingleClick=false is not in /etc/xdg/kdeglobals"
did "double-click to open is set system-wide"
"""
open(p, 'w').write(s[:start] + new + s[end:])
MUT

mutate "a stray Discover backend on disk is no longer a build failure" \
       tests/40-windows-feel.test.sh "discover.backends" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '[ -z "$stray" ] || die'
assert old in s
open(p, 'w').write(s.replace(old, '[ -z "$stray" ] || true || die'))
MUT

mutate "the Flathub key hash is no longer pinned — the network decides which key verifies every app" \
       tests/40-windows-feel.test.sh "flathub.pin" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '[ "$actual" = "$FLATHUB_SHA256" ] \\'
assert old in s
open(p, 'w').write(s.replace(old, '[ -n "$actual" ] \\'))
MUT

printf '\n%s\n' "$(c 1 'build/90-cleanup.sh — the protected set')"

mutate "an unknown kind in protected.list passes unconditionally again" \
       tests/90-cleanup.test.sh "protected.unknown-kind" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
i = s.index('    *)    die "protected.list names an unknown kind')
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '    *)    return 0 ;;' + s[j:])
MUT

mutate "a fatal protected row no longer stops the build" \
       tests/90-cleanup.test.sh "protected.loop" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = 'if [ -n "$fatal_missing" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, 'if false; then'))
MUT

mutate "baked ssh host keys are left in the image — every laptop shares one host identity" \
       tests/90-cleanup.test.sh "host key" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = '  rm -f /etc/ssh/ssh_host_*'
assert old in s
open(p, 'w').write(s.replace(old, '  true'))
MUT

mutate "the build context removal is no longer verified, so a surviving context ships" \
       tests/90-cleanup.test.sh "cleanup.context" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = '[ ! -e "$AUROS_BUILD_DIR" ] || die'
assert old in s
open(p, 'w').write(s.replace(old, '[ -e "$AUROS_BUILD_DIR" ] || true || die'))
MUT

printf '\n%s\n' "$(c 1 'policy — the B5 rule')"

mutate "a mode asserts its polkit rule by checking the file exists, and attempts nothing" \
       tests/20-policy.test.sh "B5 lint" <<'MUT'
import os
os.makedirs('policy/hurried', exist_ok=True)
open('policy/hurried/assert.sh', 'w').write('''#!/usr/bin/bash
. /usr/share/auros/policy/lib/assert-lib.sh "$@"
a_controls
a_expect_mode hurried
a_pk_hard_deny "canary.rules-loaded" org.auros.policy.control-deny
a_suite_no_root            hard
a_suite_no_software        hard
a_suite_no_network_change  hard
a_suite_update_timer       hard
a_suite_policy_immutable   hard
a_suite_kde_kiosk          hard
if [ -f /etc/sudoers.d/90-auros-hurried ]; then
    a_ok "sudo.blocked" "the sudoers drop-in is installed"
else
    a_bad "sudo.blocked" "the sudoers drop-in is missing"
fi
a_finish hurried
''')
os.chmod('policy/hurried/assert.sh', 0o755)
MUT

mutate "a mode stops attempting the KDE doors it tells the customer are shut" \
       tests/20-policy.test.sh "a_suite_kde_kiosk" <<'MUT'
p = 'policy/locked/assert.sh'
s = open(p).read()
old = 'a_suite_kde_kiosk          hard'
assert old in s
open(p, 'w').write(s.replace(old, '# a_suite_kde_kiosk          hard'))
MUT

# The suites stay; only the LEVEL changes. That is the realistic regression — somebody copies a line
# from locked/assert.sh — and it is the one a "does this file call the suites?" check cannot see.
mutate "open runs the suites at 'hard' instead of 'control', so no denial can be shown to be ours" \
       tests/20-policy.test.sh "cannot be shown to be ours" <<'MUT'
import re
p = 'policy/open/assert.sh'
s = open(p).read()
s2 = re.sub(r'^(a_suite_[a-z_]+ +)control', r'\1hard', s, flags=re.M)
assert s2 != s
open(p, 'w').write(s2)
MUT

printf '\n%s\n' "$(c 1 'the harness itself')"

mutate "an extraction stops matching — the suite must ABORT, not quietly test an empty program" \
       tests/90-cleanup.test.sh "HARNESS ABORT" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = 'check_one() {'
assert old in s
open(p, 'w').write(s.replace(old, 'check_one_renamed() {'))
MUT

mutate "a check is exercised in only one direction — the direction audit must fail the suite" \
       tests/90-cleanup.test.sh "only ever" <<'MUT'
import re
p = 'tests/90-cleanup.test.sh'
s = open(p).read()
# Delete every red case for one check id, leaving its green cases in place. A suite that still passes
# has a direction audit that does not audit anything.
s2 = re.sub(r'^run_check protected\.kind-cmd  red .*\n', '', s, flags=re.M)
assert s2 != s
open(p, 'w').write(s2)
MUT

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%s\n' "$(c 32 "$PASS/$((PASS+FAIL)) reintroduced bugs were caught by the suite that owns them.")"
  [ "$PASS" -gt 0 ] || { printf '%s\n' "$(c 31 'but no mutation actually ran — a filter that matches nothing is not a pass')"; exit 1; }
else
  printf '%s\n' "$(c 31 "$PASS caught, $FAIL NOT CAUGHT:")"
  for f in "${FAILED[@]}"; do printf '    · %s\n' "$f"; done
  printf '\n%s\n' "$(c 31 'A test that stays green with its bug reintroduced is not a test (D19).')"
fi
[ "$FAIL" -eq 0 ]

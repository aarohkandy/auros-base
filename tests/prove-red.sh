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
  # A here-string, not `printf | grep -q`: under pipefail, grep -q exiting on an early match kills
  # printf mid-write with SIGPIPE (141) and the MATCH reads as a miss. A 42 KB suite output with the
  # expected text in its first 4 KB made "no image-name check" a WRONG RED in 1-3% of runs on Linux.
  elif [ -n "$expect" ] && ! grep -qF -- "$expect" <<<"$out"; then
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

# H01 — THE FLAGSHIP. This mutation used to edit tests/kargs-check.test.sh, because the test carried
# its own copy of the caller. That meant the mutation proved the TEST's copy was checked, not that
# the shipping line was. Mutating build/10-hardening.sh instead left every case green until the test
# was rewired to extract the real line (2026-09-20).
mutate "the permanently-green original: tr -d '[:space:]' eats the newlines too, IN THE SHIPPING CALLER" \
       tests/kargs-check.test.sh "a genuine selinux=0" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = "_auros_bad_kargs=$(_auros_effective_kargs | tr -d ' \\t'"
assert old in s, "the shipping caller no longer has the tr this mutation edits"
open(p, 'w').write(s.replace(old, "_auros_bad_kargs=$(_auros_effective_kargs | tr -d '[:space:]'"))
MUT

# H02 — the alternation. Same cause as H01: the regex being exercised was the test's copy.
mutate "enforcing=0 is dropped from the shipping forbidden-karg regex" \
       tests/kargs-check.test.sh "a genuine enforcing=0" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = "grep -E '^(selinux=0|enforcing=0)$'"
assert old in s
i = s.index('_auros_bad_kargs=')
j = s.index('\n', i)
line = s[i:j]
assert old in line, "the alternation is no longer on the _auros_bad_kargs line"
open(p, 'w').write(s[:i] + line.replace(old, "grep -E '^(selinux=0)$'") + s[j:])
MUT

# H04 — comment stripping. Removing it reopens the path to the ORIGINAL permanently-RED bug, where
# prose in a comment was read as configuration.
mutate "comment stripping is removed from _auros_effective_kargs, so prose becomes configuration" \
       tests/kargs-check.test.sh "comment containing a whole bracketed kargs array" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = """    sed 's/#.*$//' "$f" | tr '\\n' ' ' \\"""
assert old in s
open(p, 'w').write(s.replace(old, """    cat "$f" | tr '\\n' ' ' \\"""))
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

mutate "C02: mask_unit's presence test becomes OR, so a unit only systemctl can see is 'ABSENT'" \
       tests/00-common.test.sh "systemctl knows the unit" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  if ! have_unit "$u" && [ ! -e "/usr/lib/systemd/system/$u" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, '  if ! have_unit "$u" || [ ! -e "/usr/lib/systemd/system/$u" ]; then'))
MUT

mutate "C03: enable_unit accepts a unit with no WantedBy, and reports it enabled" \
       tests/00-common.test.sh "no WantedBy target" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  [ "$linked" -eq 1 ] || die "$u has no WantedBy target'
assert old in s
open(p, 'w').write(s.replace(old, '  [ "$linked" -ge 0 ] || die "$u has no WantedBy target'))
MUT

mutate "C04: enable_unit's fallback symlink points at itself instead of at the unit file" \
       tests/00-common.test.sh "enable_unit" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '    ln -sfn "../$u" "/usr/lib/systemd/system/$t.wants/$u"'
assert old in s
open(p, 'w').write(s.replace(old, '    ln -sfn "$u" "/usr/lib/systemd/system/$t.wants/$u"'))
MUT

mutate "C05: pkg_ensure stops verifying with rpm, so 'installed' becomes dnf's opinion" \
       tests/00-common.test.sh "did not install" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '    have_pkg "$p" || die "$p did not install'
assert old in s
i = s.index(old)
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '    :' + s[j:])
MUT

mutate "C06: pkg_ensure's early return fires on every call, so nothing is ever installed" \
       tests/00-common.test.sh "pkg_ensure" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  if [ ${#missing[@]} -eq 0 ]; then return 0; fi'
assert old in s
open(p, 'w').write(s.replace(old, '  if [ ${#missing[@]} -ge 0 ]; then return 0; fi'))
MUT

mutate "C07: --setopt=install_weak_deps=False is dropped, so hardening drags in weak deps" \
       tests/00-common.test.sh "weak dependencies are refused" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '      "$mgr" install -y --setopt=install_weak_deps=False "${missing[@]}"'
assert old in s
open(p, 'w').write(s.replace(old, '      "$mgr" install -y "${missing[@]}"'))
MUT

mutate "C11: the D21 mirror naming convention loses its anchor, so any name containing it is a base" \
       tests/00-common.test.sh "contains the mirror name but is not it" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = "grep -qE '/auros-upstream-mirror$'"
assert old in s
open(p, 'w').write(s.replace(old, "grep -qE '/auros-upstream-mirror'"))
MUT

mutate "C12: install_file stops recording what it wrote, so the mtime re-stamp covers nothing" \
       tests/00-common.test.sh "recorded its destination" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '''  install -m "$mode" "$src" "$dest"
  auros_stamp "$dest"
  printf '%s\\n' "$dest" >> "$AUROS_WRITTEN_LIST"'''
assert old in s
open(p, 'w').write(s.replace(old, '''  install -m "$mode" "$src" "$dest"
  auros_stamp "$dest"'''))
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

mutate "H13: sshd.socket is dropped from the mask loop — sshd starts on an incoming connection" \
       tests/10-hardening.test.sh "sshd.socket" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = 'for u in sshd.service sshd.socket; do'
assert old in s
open(p, 'w').write(s.replace(old, 'for u in sshd.service; do'))
MUT

mutate "H06: a unit-keep row is announced as KEPT ON and never actually enabled" \
       tests/10-hardening.test.sh "actually ENABLED" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = '''    unit-keep)
      if have_unit "$target"; then
        enable_unit "$target"'''
assert old in s
open(p, 'w').write(s.replace(old, '''    unit-keep)
      if have_unit "$target"; then
        :'''))
MUT

mutate "H07: the countme guard is off by one, so a single countme=1 repo ships enabled" \
       tests/10-hardening.test.sh "DISABLED  dnf countme in 1" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = '  if [ "$countme_before" -gt 0 ]; then'
assert old in s
open(p, 'w').write(s.replace(old, '  if [ "$countme_before" -gt 1 ]; then'))
MUT

mutate "H10: the dnf-automatic guard is inverted — the timers stay live on a read-only /usr" \
       tests/10-hardening.test.sh "masked dnf-automatic.timer" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = 'if have_pkg dnf-automatic; then'
assert old in s
open(p, 'w').write(s.replace(old, 'if ! have_pkg dnf-automatic; then'))
MUT

mutate "H11: bootc is dropped from the end-of-hardening spot-check" \
       tests/10-hardening.test.sh "bootc was removed" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = 'for c in bootc systemctl; do\n  have_cmd "$c" || die "$c is missing after hardening'
assert old in s
open(p, 'w').write(s.replace(old, 'for c in systemctl; do\n  have_cmd "$c" || die "$c is missing after hardening'))
MUT

mutate "H12: the DefaultZone post-check matches the line it was supposed to change" \
       tests/10-hardening.test.sh "DefaultZone did not take" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = "grep -qx 'DefaultZone=auros' /etc/firewalld/firewalld.conf"
assert old in s
open(p, 'w').write(s.replace(old, "grep -q 'DefaultZone' /etc/firewalld/firewalld.conf"))
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

mutate "U01: the required-check count becomes -ge 4, so a fifth rollback trigger ships quietly" \
       tests/30-update-agent.test.sh "a FIFTH rollback trigger" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = '[ "$req" = "4" ] || die'
assert old in s
open(p, 'w').write(s.replace(old, '[ "$req" -ge 4 ] || die'))
MUT

mutate "U02: the private-key refusal is made never-match — a signing key is baked into every image" \
       tests/30-update-agent.test.sh "contains a PRIVATE key" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "if grep -q 'BEGIN .*PRIVATE KEY' \"$KEY_SRC\"; then"
assert old in s
open(p, 'w').write(s.replace(old, "if grep -q '^$BEGIN .*PRIVATE KEY' \"$KEY_SRC\"; then"))
MUT

mutate "U03: key selection becomes OR, so the DEVELOPMENT key is used even when a production key exists" \
       tests/30-update-agent.test.sh "BOTH keys are present" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = 'if [ ! -s "$KEY_SRC" ] && [ -s "$SIGN/keys/auros-development.pub" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, 'if [ ! -s "$KEY_SRC" ] || [ -s "$SIGN/keys/auros-development.pub" ]; then'))
MUT

mutate "U04: the validator stops rejecting an insecureAcceptAnything global default — the D8 failure" \
       tests/30-update-agent.test.sh "the global default is insecureAcceptAnything" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = 'if any(r.get("type")=="insecureAcceptAnything" for r in p["default"]):'
assert old in s
open(p, 'w').write(s.replace(old, 'if False:'))
MUT

mutate "U05: the validator accepts signedIdentity matchExact — no cosign signature would ever verify" \
       tests/30-update-agent.test.sh "signedIdentity is matchExact" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = 'if si not in ("matchRepository","exactRepository"):'
assert old in s
open(p, 'w').write(s.replace(old, 'if si not in ("matchRepository","exactRepository","matchExact","matchRepoDigestOrExact","remapIdentity"):'))
MUT

mutate "U06: the unreviewed third catch-all option is no longer refused" \
       tests/30-update-agent.test.sh "unreviewed third answer" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "elif catchall:\n    bad('transports.docker[\"\"] is %r"
assert old in s
open(p, 'w').write(s.replace(old, "elif catchall:\n    print('transports.docker[\"\"] is %r"))
MUT

mutate "U11: the validator stops checking keyPath, so a policy can point at a key that is not there" \
       tests/30-update-agent.test.sh "unexpected keyPath" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = 'if kp!="/usr/lib/pki/containers/auros.pub": bad("unexpected keyPath %r" % kp)'
assert old in s
open(p, 'w').write(s.replace(old, 'pass'))
MUT

mutate "U07: the registries.d more-specific-scope check is made never-match" \
       tests/30-update-agent.test.sh "MORE SPECIFIC scope under ours" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = '}/" "$other"; then'
assert s.count(old) == 1, "the more-specific-scope grep is no longer the only line of its shape"
open(p, 'w').write(s.replace(old, '}/@never@" "$other"; then'))
MUT

mutate "U07b: the registries.d duplicate-scope check is made never-match" \
       tests/30-update-agent.test.sh "the SAME scope as ours" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = '?:" "$other"; then'
assert s.count(old) == 1, "the duplicate-scope grep is no longer the only line of its shape"
open(p, 'w').write(s.replace(old, '?:@never@" "$other"; then'))
MUT

mutate "U08: enforce-container-sigpolicy is checked by name only, so '= false' ships" \
       tests/30-update-agent.test.sh "the setting says false" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "grep -qE '^enforce-container-sigpolicy[[:space:]]*=[[:space:]]*true' /usr/lib/bootc/install/30-auros.toml"
assert old in s
open(p, 'w').write(s.replace(old, "grep -qE '^enforce-container-sigpolicy' /usr/lib/bootc/install/30-auros.toml"))
MUT

mutate "U09: the bash -n gate on greenboot health checks is removed" \
       tests/30-update-agent.test.sh "does not parse" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = '    bash -n "$f" || die "$f is not valid bash'
assert old in s
i = s.index(old)
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '    :' + s[j:])
MUT

mutate "U10: the ExecStart clearing check stops being a whole-line match" \
       tests/30-update-agent.test.sh "never cleared" <<'MUT'
p = 'build/30-update-agent.sh'
s = open(p).read()
old = "grep -qx 'ExecStart=' /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-auros.conf"
assert old in s
open(p, 'w').write(s.replace(old, "grep -q 'ExecStart=' /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-auros.conf"))
MUT

# SYSTEM-REVIEW §2.4 / H4: the freshness canary measured registry reachability, so a fleet whose
# publisher had stopped stayed green forever. Reverting the image-age verdict to "ignored" is exactly
# the pre-fix behaviour, and test C8 (stale image, fresh fetch stamp) has to see it.
mutate "the freshness check ignores the booted image's age again, so a stopped publisher stays green" \
       update-agent/tests/run-tests.sh "C8 stale image + fresh fetch stamp exits 1" <<'MUT'
p = 'update-agent/greenboot/check/wanted.d/70-update-freshness.sh'
s = open(p).read()
old = 'exit "${image_rc}"'
assert s.count(old) == 2, "the image-age verdict is no longer folded into both OK exits"
open(p, 'w').write(s.replace(old, 'exit 0'))
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

mutate "W02: the welcome-page count drops to -ge 1, so the honest Windows-programs page can vanish" \
       tests/40-windows-feel.test.sh "the honest page went missing" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '[ "$pages" -ge 2 ] || die'
assert old in s
open(p, 'w').write(s.replace(old, '[ "$pages" -ge 1 ] || die'))
MUT

mutate "the image stops writing /etc/plasma-setup-done, so KDE's wizard takes seat0 on first boot" \
       tests/40-windows-feel.test.sh "[plasma-setup] plasma-setup 6.7.5's own conditions" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = "  | install_text \"$PS_DONE\" 0644\n"
assert old in s
open(p, 'w').write(s.replace(old, "  >/dev/null\n"))
MUT

mutate "the first-boot account detector counts system accounts as people, hiding the no-user gap" \
       tests/40-windows-feel.test.sh "today's image: system accounts only" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = "$3>=1000 && $3<60000"
assert old in s
open(p, 'w').write(s.replace(old, "$3>=900 && $3<60000"))
MUT

mutate "auros-accounts keeps the enrolment secret on disk after using it" \
       tests/accounts.test.sh "the enrolment file is deleted" <<'MUT'
p = 'desktop/accounts/auros-accounts'
s = open(p).read()
old = '  rm -f "$BUNDLE"; rmdir'
assert old in s
open(p, 'w').write(s.replace(old, '  : "$BUNDLE"; rmdir'))
MUT

mutate "auros-accounts finishes with nobody able to sign in, so the laptop shows an empty sign-in screen" \
       tests/accounts.test.sh "no enrolment file on the install media" <<'MUT'
p = 'desktop/accounts/auros-accounts'
s = open(p).read()
old = '[ "$capable" -gt 0 ] || fail'
assert old in s
open(p, 'w').write(s.replace(old, '[ "$capable" -ge 0 ] || fail'))
MUT

mutate "auros-accounts passes a plain-text password to chpasswd -e" \
       tests/accounts.test.sh "a plain password in the enrolment file is never used" <<'MUT'
p = 'desktop/accounts/auros-accounts'
s = open(p).read()
old = "      '$'*) pairs+="
assert old in s
open(p, 'w').write(s.replace(old, "      *) pairs+="))
MUT

mutate "the build stops failing on an enrolment directory baked into the image" \
       tests/40-windows-feel.test.sh "an enrolment directory baked into the image" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '[ ! -e "$ENROL_DIR" ] || die'
assert old in s
open(p, 'w').write(s.replace(old, 'true || die'))
MUT

mutate "W06: enable_user_unit stops verifying the link, so the first-run wizard never runs for anyone" \
       tests/40-windows-feel.test.sh "ln exits 0 and creates no link" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  [ -e "$dir/$u" ] || die "could not enable $u for $t"'
assert old in s
i = s.index(old)
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '  :' + s[j:])
MUT

mutate "W06b: enable_user_unit stops checking the unit file exists before linking to it" \
       tests/40-windows-feel.test.sh "the user unit was never installed" <<'MUT'
p = 'build/00-common.sh'
s = open(p).read()
old = '  [ -f "/usr/lib/systemd/user/$u" ] || die "cannot enable $u'
assert old in s
i = s.index(old)
j = s.index('\n', i)
open(p, 'w').write(s[:i] + '  :' + s[j:])
MUT

printf '\n%s\n' "$(c 1 'build/45-restore.sh — the Linux-side restore')"

mutate "R01: the sha256 comparison is dropped, so whatever the URL serves is installed" \
       tests/45-restore.test.sh "the binary changed after it was pinned" <<'MUT'
p = 'build/45-restore.sh'
s = open(p).read()
old = '[ "$got" = "$2" ] || die "sha256 mismatch'
assert old in s
open(p, 'w').write(s.replace(old, 'true || die "sha256 mismatch'))
MUT

mutate "R02: the switch goes quiet — OFF installs nothing and no longer says so" \
       tests/45-restore.test.sh "says RESTORE IS OFF" <<'MUT'
p = 'build/45-restore.sh'
s = open(p).read()
old = '  warn "RESTORE IS OFF'
assert old in s
open(p, 'w').write(s.replace(old, '  : "RESTORE IS OFF'))
MUT

mutate "R03: the post-install binary assertion is deleted" \
       tests/45-restore.test.sh "restore.assert" <<'MUT'
p = 'build/45-restore.sh'
s = open(p).read()
old = '[ -x "$R$EXEC" ] || die'
assert old in s
open(p, 'w').write(s.replace(old, 'true || die'))
MUT

mutate "R04: the WantedBy target is hardcoded instead of read from the unit" \
       tests/45-restore.test.sh "linked for default.target too" <<'MUT'
p = 'build/45-restore.sh'
s = open(p).read()
old = 'for t in $TARGETS; do enable_user_unit "$UNIT" "$t"; done'
assert old in s
open(p, 'w').write(s.replace(old, 'enable_user_unit "$UNIT" graphical-session.target'))
MUT

mutate "W07: the widget check goes back to a bare grep, so a comment naming a widget passes for it" \
       tests/40-windows-feel.test.sh "only a comment still mentions" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '''grep -qF "addWidget(\\"org.kde.plasma.$w\\")" "$l"'''
assert old in s
open(p, 'w').write(s.replace(old, 'grep -q "org.kde.plasma.$w" "$l"'))
MUT

mutate "W08: a new layout ships in desktop/lookandfeel but the build never validates it" \
       tests/40-windows-feel.test.sh "exactly the ones the build validates" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = 'LNF_IDS="org.auros.windows.desktop org.auros.shelf.desktop org.auros.simple.desktop org.auros.mac.desktop"'
assert old in s
open(p, 'w').write(s.replace(old, 'LNF_IDS="org.auros.windows.desktop org.auros.shelf.desktop org.auros.mac.desktop"'))
MUT

mutate "W09: the defaults-file id check is dropped, so a package copied from Windows and never edited ships" \
       tests/40-windows-feel.test.sh "defaults names the Windows package" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = '''  grep -qx "LookAndFeelPackage=$id" "$pkg/contents/defaults" 2>/dev/null \\
    || die'''
assert old in s
open(p, 'w').write(s.replace(old, '''  true \\
    || die'''))
MUT

mutate "W10: the mac layout ships in desktop/lookandfeel but the build never validates it" \
       tests/40-windows-feel.test.sh "exactly the ones the build validates" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = 'org.auros.simple.desktop org.auros.mac.desktop"'
assert old in s
open(p, 'w').write(s.replace(old, 'org.auros.simple.desktop"'))
MUT

mutate "W11: the Windows taskbar's floating check is dropped, so a floating taskbar ships again" \
       tests/40-windows-feel.test.sh "the taskbar floats" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = "grep -qx 'panel.floating = false;' \"$LAYOUT\" \\"
assert old in s
open(p, 'w').write(s.replace(old, "true \\"))
MUT

mutate "W12: kimpanel leaves the build's widget list, so a layout without the input-method indicator ships" \
       tests/40-windows-feel.test.sh "drops the input-method indicator" <<'MUT'
p = 'build/40-windows-feel.sh'
s = open(p).read()
old = 'for w in kickoff icontasks systemtray digitalclock kimpanel; do'
assert old in s
open(p, 'w').write(s.replace(old, 'for w in kickoff icontasks systemtray digitalclock; do'))
MUT

mutate "W13: set-desktop-layout passes an unknown name through instead of refusing it" \
       tests/40-windows-feel.test.sh "says which names exist" <<'MUT'
p = 'desktop/set-desktop-layout'
s = open(p).read()
old = '  *) die "usage: set-desktop-layout'
assert old in s
open(p, 'w').write(s.replace(old, '  *) ID="org.auros.$1.desktop" ;;\n  --never-matches--) die "usage: set-desktop-layout'))
MUT

mutate "W14: set-desktop-layout matches LookAndFeelPackage in any group, not only [KDE]" \
       tests/40-windows-feel.test.sh "not the [General] copy" <<'MUT'
p = 'desktop/set-desktop-layout'
s = open(p).read()
old = 'k && index($0, "LookAndFeelPackage=") == 1'
assert s.count(old) == 2
open(p, 'w').write(s.replace(old, 'index($0, "LookAndFeelPackage=") == 1'))
MUT

mutate "W15: auros-first-run trusts /etc/auros/desktop-layout without checking the package ships" \
       tests/40-windows-feel.test.sh "does not ship → Windows" <<'MUT'
p = 'desktop/welcome/auros-first-run'
s = open(p).read()
i = s.index('    if [[ $chosen =~')
j = s.index('; then', i)
open(p, 'w').write(s[:i] + '    if [[ -n $chosen ]]' + s[j:])
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

mutate "X04: the no-protected.list fallback drops bootc, so an unpatchable image passes the gate" \
       tests/90-cleanup.test.sh "bootc is gone" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = '''  for c in bootc systemctl; do
    have_cmd "$c" || fatal_missing="$fatal_missing cmd:$c"'''
assert old in s
open(p, 'w').write(s.replace(old, '''  for c in systemctl; do
    have_cmd "$c" || fatal_missing="$fatal_missing cmd:$c"'''))
MUT

mutate "X05: build scratch files are no longer removed, so /tmp ships in the image" \
       tests/90-cleanup.test.sh "no longer removes anything under /tmp" <<'MUT'
p = 'build/90-cleanup.sh'
s = open(p).read()
old = 'rm -rf /tmp/* /var/tmp/* 2>/dev/null || true'
assert old in s
open(p, 'w').write(s.replace(old, 'true'))
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

mutate "P01: the base's default policy mode becomes 'locked', so every matrix result describes another image" \
       tests/20-policy.test.sh "the base builds OPEN" <<'MUT'
p = 'build/20-policy.sh'
s = open(p).read()
old = 'MODE="${AUROS_POLICY:-open}"'
assert old in s
open(p, 'w').write(s.replace(old, 'MODE="${AUROS_POLICY:-locked}"'))
MUT

# Run 35566336512 — B5's first real boot aborted in 56 ms, and the fragment could not say why.
mutate "B5 run 35566336512: the bus probe is Peer.Ping, which the stock system bus refuses to a non-root sender" \
       policy/tests/assert-lib.test.sh "a live bus that refuses Peer.Ping" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = '/org/freedesktop/DBus org.freedesktop.DBus.GetId 2>&1)'
assert old in s
open(p, 'w').write(s.replace(old, '/ org.freedesktop.DBus.Peer.Ping 2>&1)'))
MUT

mutate "B5 run 35566336512: the abort reason sits above the three lines B5 keeps" \
       policy/tests/assert-lib.test.sh "named in the last three lines" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = "printf '\\nRESULT: fail (assertion aborted before it could prove anything): %s\\n' \"$1\""
assert old in s
open(p, 'w').write(s.replace(old, "printf '\\nRESULT: fail (assertion aborted before it could prove anything)\\n'"))
MUT

mutate "pkcheck 3 read as the challenge: every auth_admin answer (2) becomes an 'error' under managed" \
       policy/tests/assert-lib.test.sh "managed accepts pkcheck 2" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = '1|2) a_ok "$id" "$action -- not authorised for this user (pkcheck $rc)" ;;'
assert old in s
open(p, 'w').write(s.replace(old, '1|3) a_ok "$id" "$action -- not authorised for this user (pkcheck $rc)" ;;'))
MUT

# Run 35616444839 — B5 on the open control: pkcheck 127 for an action this base never registers, and
# manage-units "refused outright" because the harness's wheel user tripped an upstream wheel-only rule.
mutate "B5 run 35616444839: a failed pkaction enumeration is read as 'the action is not registered'" \
       policy/tests/assert-lib.test.sh "dead pkaction + 127 => FAIL" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = 'local list; list="$(pkaction 2>/dev/null)" || return 1'
assert old in s
open(p, 'w').write(s.replace(old, 'local list; list="$(pkaction 2>/dev/null)" || return 0'))
MUT

mutate "B5 run 35616444839: a probe subject in wheel is accepted as the unprivileged case" \
       policy/tests/assert-lib.test.sh "a subject in wheel => ABORT" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = 'if grep -qx wheel <<<'
assert old in s
open(p, 'w').write(s.replace(old, 'if grep -qx wheel-never-matches <<<'))
MUT

mutate "B5 run 35616444839: the harness runs assert-policy as its wheel test user again" \
       policy/tests/assert-lib.test.sh "B5 runs assert-policy via runuser" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = '  if ! "$ASSERT" "$POLICY_MODE" >'
assert old in s
open(p, 'w').write(s.replace(old, '  if ! runuser -u "$TEST_USER" -- "$ASSERT" "$POLICY_MODE" >'))
MUT

mutate "B11 run 35616444839: avc_summary drops the denied object, so 'unlabeled_t:file' names no file" \
       tests/b11-diag.test.sh "fold to 2x" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = 'print comm " " s "->" t ":" c " {" p "}" obj'
assert old in s
open(p, 'w').write(s.replace(old, 'print comm " " s "->" t ":" c " {" p "}"'))
MUT

printf '\n%s\n' "$(c 1 'workflow run: blocks — pipe into grep -q under pipefail')"

mutate "build.yml's cosign flag probe goes back to piping its --help into grep -q (SIGPIPE drops the flag)" \
       tests/shell-idioms.test.sh "build.yml:" <<'MUT'
p = '.github/workflows/build.yml'
s = open(p).read()
old = '! grep -q -- "${FLAG%%=*}" <<<"$(cosign sign --help 2>&1)"'
assert old in s
# The pipe is chr(124) so this file does not itself carry the idiom shell-idioms.test.sh scans for.
open(p, 'w').write(s.replace(old, '! cosign sign --help 2>&1 ' + chr(124) + ' grep -q -- "${FLAG%%=*}"'))
MUT

printf '\n%s\n' "$(c 1 'D21 — the mirror gate in build.yml plan')"

mutate "H6: D21 goes back to a ::warning:: when the mirror is populated and FROM still points upstream" \
       tests/d21-gate.test.sh "the build FAILS" <<'MUT'
p = '.github/workflows/build.yml'
s = open(p).read()
old = "resolve-upstream.sh assert already accepts it.\"\n            exit 1\n"
assert old in s
open(p, 'w').write(s.replace(old, "resolve-upstream.sh assert already accepts it.\"\n"))
MUT

printf '\n%s\n' "$(c 1 'org.opencontainers.image.created — the image age bootc reports')"

mutate "the image.created LABEL is dropped, so laptops report Aurora's build date" \
       tests/image-created.test.sh "the shipping Containerfile" <<'MUT'
p = 'Containerfile'
s = open(p).read()
old = 'LABEL org.opencontainers.image.created="${IMAGE_CREATED}"\n'
assert old in s
open(p, 'w').write(s.replace(old, ''))
MUT

mutate "the flatten stops refusing a declared LABEL the built image lacks" \
       tests/image-created.test.sh "missing a declared label" <<'MUT'
p = '.github/workflows/build.yml'
s = open(p).read()
old = '[ -n "$v" ] || { echo "::error::the Containerfile declares LABEL $k but the built image has no value for it"; exit 1; }'
assert old in s
open(p, 'w').write(s.replace(old, '[ -n "$v" ] || continue'))
MUT

printf '\n%s\n' "$(c 1 'B2/B11 diagnostics name what they count')"

mutate "taint_flags reads the kernel's letter table off by one" \
       tests/b11-diag.test.sh "b11taint" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = 'L=PFSRMBUDAWCIOELKXTNJ'
assert old in s
open(p, 'w').write(s.replace(old, 'L=GPFSRMBUDAWCIOELKXTNJ'))
MUT

mutate "tainted_modules names every module, tainting or not" \
       tests/b11-diag.test.sh "b11module" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = '[ -n "$t" ] && { f=${f%/taint}; out="$out ${f##*/}($t)"; }'
assert old in s
open(p, 'w').write(s.replace(old, '{ f=${f%/taint}; out="$out ${f##*/}($t)"; }'))
MUT

mutate "avc_summary stops folding identical denials" \
       tests/b11-diag.test.sh "b11avc" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = '| sort | uniq -c | sort -rn | head -15'
assert old in s
open(p, 'w').write(s.replace(old, '| sed "s/^/1 /" | head -15'))
MUT

mutate "masked_modules_state reports not-loaded whatever /sys/module says" \
       tests/b11-diag.test.sh "b11masked" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = 'if [ -d "${1:-/sys/module}/$m" ]; then'
assert old in s
open(p, 'w').write(s.replace(old, 'if false; then'))
MUT

mutate "10-hardening stops masking upstream's zfs modules-load.d file" \
       tests/10-hardening.test.sh "mld-mask" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = 'ln -sfn /dev/null "/etc/modules-load.d/$f"'
assert old in s
open(p, 'w').write(s.replace(old, '[ "$f" = zfs.conf ] || ' + old))
MUT

mutate "10-hardening accepts an initramfs that forces a module no karg blocks (run 35616444839)" \
       tests/10-hardening.test.sh "initrd-block" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = '*" $m "*) ;;'
assert old in s
open(p, 'w').write(s.replace(old, '*) ;;', 1))
MUT

mutate "kargs-modules.toml stops blocking zfs" \
       tests/10-hardening.test.sh "initrd-block" <<'MUT'
p = 'hardening/kargs-modules.toml'
s = open(p).read()
old = '"modprobe.blacklist=zfs", '
assert old in s
open(p, 'w').write(s.replace(old, ''))
MUT

mutate "10-hardening reads an empty initramfs listing as 'forces nothing'" \
       tests/10-hardening.test.sh "initrd-block" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = "grep -q 'usr/lib/modules/' <<<"
assert old in s
open(p, 'w').write(s.replace(old, "true || grep -q 'usr/lib/modules/' <<<"))
MUT

mutate "the mcelog drop-in is installed without checking mcelog has --is-cpu-supported" \
       tests/10-hardening.test.sh "mcelog" <<'MUT'
p = 'build/10-hardening.sh'
s = open(p).read()
old = "grep -aq -- '--is-cpu-supported' /usr/sbin/mcelog \\\n"
assert old in s
open(p, 'w').write(s.replace(old, "true || grep -aq -- '--is-cpu-supported' /usr/sbin/mcelog \\\n"))
MUT

mutate "the mcelog drop-in loses its ExecCondition" \
       tests/10-hardening.test.sh "mcelog" <<'MUT'
p = 'hardening/mcelog-cpu-supported.conf'
s = open(p).read()
old = 'ExecCondition=/usr/sbin/mcelog --is-cpu-supported'
assert old in s
open(p, 'w').write(s.replace(old, ''))
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

printf '\n%s\n' "$(c 1 'matrix/run — the boot session (run 35566336512: B7/B8/B12 with no user session)')"

mutate "the test wrapper writes autologin only where sddm reads it, on a plasmalogin base" \
       tests/boot-session.test.sh "[autologin] the shipping wrapper" <<'MUT'
p = 'matrix/run/guest/Containerfile.testwrap'
s = open(p).read()
old = 'for d in /etc/plasmalogin.conf.d /etc/sddm.conf.d; do'
assert old in s
open(p, 'w').write(s.replace(old, 'for d in /etc/sddm.conf.d; do'))
MUT

mutate "the test wrapper leaves plasma-setup unfinished, so its 99- autologin takes seat0" \
       tests/boot-session.test.sh "[autologin] the shipping wrapper" <<'MUT'
p = 'matrix/run/guest/Containerfile.testwrap'
s = open(p).read()
old = "      printf 'Plasma Setup completed by the auros-matrix test wrapper\\n' > /etc/plasma-setup-done; \\\n"
assert old in s
open(p, 'w').write(s.replace(old, ''))
MUT

mutate "the agent lists KCMs with a bare kcmshell6 --list, which aborts with no display" \
       tests/boot-session.test.sh "[kcmlist] root, no display" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = 'KCMLIST=$( QT_QPA_PLATFORM=offscreen "$KCMBIN" --list'
assert old in s
open(p, 'w').write(s.replace(old, 'KCMLIST=$( "$KCMBIN" --list'))
MUT

mutate "the session wait accepts wayland-0.lock as a session" \
       tests/boot-session.test.sh "[session] no socket" <<'MUT'
p = 'matrix/run/guest/auros-matrix-agent.sh'
s = open(p).read()
old = '[ -S "$s" ] && { WL=$s; break; }'
assert old in s
open(p, 'w').write(s.replace(old, '[ -e "$s" ] && { WL=$s; break; }'))
MUT

mutate "run-boot.sh counts fail RECORDS, so two boots double the count" \
       tests/boot-session.test.sh "[failcount] 5 checks" <<'MUT'
p = 'matrix/run/run-boot.sh'
s = open(p).read()
old = """FAILS=$(printf '%s' "$FAILED_IDS" | tr ',' '\\n' | grep -c . || true)"""
assert old in s
open(p, 'w').write(s.replace(old, """FAILS=$(grep -c '"status":"fail"' "$CHECKS_FILE" || true)"""))
MUT

printf '\n%s\n' "$(c 1 'accounts — enrolment media, the generator, A4 and A6 (control repo docs/ACCOUNTS.md)')"

mutate "ACCT: make-install-media builds an ISO for an image with accounts and no enrolment file" \
       tests/make-install-media.test.sh "the image declares accounts and no --enrolment is given" <<'MUT'
p = 'tools/make-install-media.sh'
s = open(p).read()
old = '  [ -n "$ENROL" ] || refuse "$REF declares accounts'
assert old in s
open(p, 'w').write(s.replace(old, '  true || refuse "$REF declares accounts'))
MUT

mutate "ACCT: make-install-media puts a plain-text password on the install media" \
       tests/make-install-media.test.sh "a plain-text password in the file" <<'MUT'
p = 'tools/make-install-media.sh'
s = open(p).read()
old = '[[ "$h" =~ ^\\$[^:[:space:]]+$ ]]'
assert old in s
open(p, 'w').write(s.replace(old, '[[ "$h" =~ ^[^:[:space:]]+$ ]]'))
MUT

mutate "ACCT: make-enrolment prints the passwords into a pipe or a file" \
       tests/make-enrolment.test.sh "stdout is a file, not a terminal" <<'MUT'
p = 'tools/make-enrolment.sh'
s = open(p).read()
old = '[ -t 1 ] || refuse'
assert old in s
open(p, 'w').write(s.replace(old, 'true || refuse'))
MUT

mutate "ACCT: auros-accounts expires every password even with A6 switched off (plasmalogin lock-out)" \
       tests/accounts.test.sh "A6 is off by default" <<'MUT'
p = 'desktop/accounts/auros-accounts'
s = open(p).read()
old = 'if [ "${AUROS_EXPIRE_FIRST_PASSWORD:-0}" = 1 ]; then'
assert old in s
open(p, 'w').write(s.replace(old, 'if true; then'))
MUT

mutate "ACCT: auros-accounts leaves anaconda's kickstart copy, with the hashes, in /root" \
       tests/accounts.test.sh "/root/anaconda-ks.cfg deleted" <<'MUT'
p = 'desktop/accounts/auros-accounts'
s = open(p).read()
old = "if grep -qs 'auros/enrolment' \"$k\"; then rm -f \"$k\"; fi"
assert old in s
open(p, 'w').write(s.replace(old, ': "$k"'))
MUT

mutate "ACCT: the admin env script un-hides the Users page for any group NAMED like aurosadmin" \
       tests/20-policy.test.sh "nor a member of a group merely NAMED like it" <<'MUT'
p = 'policy/managed/root/etc/xdg/plasma-workspace/env/50-auros-admin-users-page.sh'
s = open(p).read()
old = '*" aurosadmin "*)'
assert old in s
open(p, 'w').write(s.replace(old, '*aurosadmin*)'))
MUT

mutate "ACCT: B12 audits a pupil as if they were the IT account" \
       desktop/tests/b12-modes.test.sh "locked, a pupil: the Users page refuses to open" <<'MUT'
p = 'desktop/assert-zero-terminal.sh'
s = open(p).read()
old = '[[ " $(id -nG 2>/dev/null) " != *" aurosadmin "* ]]'
assert old in s
open(p, 'w').write(s.replace(old, 'false'))
MUT

mutate "ACCT: B5 accepts a password prompt for account management on a locked machine" \
       policy/tests/assert-lib.test.sh "locked: answerable => FAIL" <<'MUT'
p = 'policy/lib/assert-lib.sh'
s = open(p).read()
old = 'a_deny "$level" "accounts.user-admin"'
assert old in s
open(p, 'w').write(s.replace(old, 'a_deny admin "accounts.user-admin"'))
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

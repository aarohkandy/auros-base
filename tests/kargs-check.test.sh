#!/usr/bin/env bash
# Regression test for the SELinux kernel-argument check in build/10-hardening.sh.
#
# It exists because that check was briefly PERMANENTLY GREEN: `tr -d '[:space:]'` deleted the newlines
# as well as the spaces, collapsing every argument onto one line so `^selinux=0$` could never match.
# A security check that cannot fail is worse than no check, because it is also reassuring.
#
# And before that it was permanently RED, matching its own file's comment explaining that `enforcing=0`
# at the GRUB prompt is a technician's only recovery path. Both directions are represented below.
#
# THIRD FAILURE, found by writing the rest of tests/ around this file: the check read the kargs.d
# files LINE BY LINE, so `kargs = [` on one line and `"selinux=0"` on the next was invisible to it.
# That is valid TOML, bootc accepts it, and the check could not fail on it — the same
# permanently-green shape as the `tr` bug, hiding behind a different mechanism. The multi-line cases
# below are that regression, and they were watched going red against the previous implementation.
#
# Every case is scored in BOTH directions somewhere in this file: no case list here may consist only
# of inputs that are supposed to pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
SAW_FLAGGED=0; SAW_CLEAN=0

# Extract the function under test from the real script, so this cannot drift from what ships.
# An empty extraction would produce an empty program that "passes" every input, so it aborts.
extract() {
  local body
  body="$(sed -n '/^_auros_effective_kargs() {/,/^}/p' "$HERE/build/10-hardening.sh" \
    | sed "s#/usr/lib/bootc/kargs.d#\$ROOT/usr/lib/bootc/kargs.d#; s#/usr/lib/ostree-boot#\$ROOT/usr/lib/ostree-boot#")"
  if [ -z "$body" ]; then
    echo "ABORT: _auros_effective_kargs() not found in build/10-hardening.sh — this test is vacuous" >&2
    exit 90
  fi
  printf '%s\n' "$body"
}
FN="$(extract)"

# run_case <name> <flagged|clean> <kargs.d/10.toml contents> [kargs.d/20.toml contents] [ostree-boot entry]
run_case () {
  local name="$1" want="$2" body="$3" second="${4:-}" bootentry="${5:-}"
  local root; root="$(mktemp -d)"
  mkdir -p "$root/usr/lib/bootc/kargs.d"
  printf '%s\n' "$body" > "$root/usr/lib/bootc/kargs.d/10.toml"
  [ -n "$second" ]    && printf '%s\n' "$second" > "$root/usr/lib/bootc/kargs.d/20.toml"
  if [ -n "$bootentry" ]; then
    mkdir -p "$root/usr/lib/ostree-boot/loader/entries"
    printf '%s\n' "$bootentry" > "$root/usr/lib/ostree-boot/loader/entries/ostree-1.conf"
  fi
  local got
  got=$(ROOT="$root" bash -c "$FN
    bad=\$(_auros_effective_kargs | tr -d ' \t' | grep -E '^(selinux=0|enforcing=0)\$' || true)
    [ -n \"\$bad\" ] && echo flagged || echo clean")
  rm -rf "$root"
  case "$got" in flagged) SAW_FLAGGED=1 ;; clean) SAW_CLEAN=1 ;; esac
  if [ "$got" = "$want" ]; then printf '  ok   %-62s %s\n' "$name" "$got"; PASS=$((PASS+1))
  else printf '  FAIL %-62s got=%s want=%s\n' "$name" "$got" "$want"; FAIL=$((FAIL+1)); fi
}

echo "SELinux kernel-argument check:"
run_case "our real kargs file (comment mentions enforcing=0)" clean   "$(cat "$HERE/hardening/kargs-selinux.toml")"
run_case "a genuine selinux=0"                                flagged '# innocuous
kargs = ["quiet", "selinux=0"]'
run_case "a genuine enforcing=0"                              flagged 'kargs = ["enforcing=0"]'
run_case "selinux=0 as the only argument"                     flagged 'kargs = ["selinux=0"]'
run_case "selinux=0 last among many"                          flagged 'kargs = ["quiet", "rhgb", "selinux=0"]'
run_case "selinux=1 only"                                     clean   'kargs = ["selinux=1"]'
run_case "a comment that merely names selinux=0"              clean   '# never ship selinux=0
kargs = ["selinux=1"]'
run_case "no kargs at all"                                    clean   '# nothing here'
run_case "extra spaces around the arguments"                  flagged 'kargs = [ "quiet" ,  "selinux=0" ]'

echo
echo "multi-line arrays — valid TOML the per-line implementation could not see:"
run_case "selinux=0 on its own line inside the array"         flagged 'kargs = [
  "quiet",
  "selinux=0",
]'
run_case "enforcing=0 on its own line inside the array"       flagged 'kargs = [
  "enforcing=0"
]'
run_case "a multi-line array with nothing wrong in it"        clean   'kargs = [
  "quiet",
  "selinux=1",
]'
run_case "a multi-line array whose comment names selinux=0"   clean   'kargs = [
  # never selinux=0
  "selinux=1",
]'
run_case "the opening bracket alone on the kargs line"        flagged 'kargs =
  ["selinux=0"]'

echo
echo "a second file in kargs.d — the loop, not just the first file:"
run_case "clean first file, hostile second file"              flagged 'kargs = ["quiet"]' 'kargs = ["selinux=0"]'
run_case "hostile first file, clean second file"              flagged 'kargs = ["selinux=0"]' 'kargs = ["quiet"]'
run_case "two clean files"                                    clean   'kargs = ["quiet"]' 'kargs = ["selinux=1"]'
run_case "second file has no kargs key at all"                clean   'kargs = ["selinux=1"]' '# just a comment'

echo
echo "bootloader entries — the second source the function reads:"
run_case "an options= line carrying selinux=0"                flagged 'kargs = ["selinux=1"]' '' 'title Fedora
options root=UUID=x ro selinux=0 quiet'
run_case "an options= line carrying enforcing=0"              flagged 'kargs = ["selinux=1"]' '' 'options root=UUID=x enforcing=0'
run_case "an options= line with nothing wrong in it"          clean   'kargs = ["selinux=1"]' '' 'options root=UUID=x ro quiet rhgb'
run_case "a bootloader entry with no options= line"           clean   'kargs = ["selinux=1"]' '' 'title Fedora
linux /vmlinuz'

echo
echo "documented limits — recorded rather than silently true:"
# rd.selinux=0 disables SELinux policy loading in the INITRAMFS only; the kernel's own selinux=1 and
# systemd's later load still apply, so this is deliberately not treated as a disabling argument. It is
# written down here so that a future reader finds a decision rather than an oversight.
run_case "rd.selinux=0 (initramfs only) is NOT treated as disabling" clean 'kargs = ["selinux=1", "rd.selinux=0"]'
# The anchors are ^ and $ on purpose: a longer argument that merely contains the text must not flag.
run_case "an argument that merely contains the text"          clean   'kargs = ["myapp.selinux=0mode"]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"

# The direction audit, in miniature: a run in which nothing was ever flagged, or nothing was ever
# clean, is a run that proves nothing about the check regardless of how many cases passed.
if [ "$SAW_FLAGGED" != 1 ]; then echo "DIRECTION AUDIT FAIL: no input was ever flagged"; FAIL=$((FAIL+1)); fi
if [ "$SAW_CLEAN" != 1 ];   then echo "DIRECTION AUDIT FAIL: no input was ever clean";  FAIL=$((FAIL+1)); fi
[ "$FAIL" -eq 0 ]

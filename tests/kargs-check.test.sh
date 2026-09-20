#!/usr/bin/env bash
# Regression test for the SELinux kernel-argument check in build/10-hardening.sh.
#
# It exists because that check was briefly PERMANENTLY GREEN: `tr -d '[:space:]'` deleted the newlines
# as well as the spaces, collapsing every argument onto one line so `^selinux=0$` could never match.
# A security check that cannot fail is worse than no check, because it is also reassuring.
#
# And before that it was permanently RED, matching its own file's comment explaining that `enforcing=0`
# at the GRUB prompt is a technician's only recovery path. Both directions are represented below.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

# Extract the function under test from the real script, so this cannot drift from what ships.
extract() {
  sed -n '/^_auros_effective_kargs() {/,/^}/p' "$HERE/build/10-hardening.sh" \
    | sed "s#/usr/lib/bootc/kargs.d#\$ROOT/usr/lib/bootc/kargs.d#; s#/usr/lib/ostree-boot#\$ROOT/usr/lib/ostree-boot#"
}

run_case () { # name, expected(flagged|clean), file-contents
  local name="$1" want="$2" body="$3"
  local root; root="$(mktemp -d)"
  mkdir -p "$root/usr/lib/bootc/kargs.d"
  printf '%s\n' "$body" > "$root/usr/lib/bootc/kargs.d/10.toml"
  local got
  got=$(ROOT="$root" bash -c "$(extract)
    bad=\$(_auros_effective_kargs | tr -d ' \t' | grep -E '^(selinux=0|enforcing=0)\$' || true)
    [ -n \"\$bad\" ] && echo flagged || echo clean")
  rm -rf "$root"
  if [ "$got" = "$want" ]; then printf '  ok   %-58s %s\n' "$name" "$got"; PASS=$((PASS+1))
  else printf '  FAIL %-58s got=%s want=%s\n' "$name" "$got" "$want"; FAIL=$((FAIL+1)); fi
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

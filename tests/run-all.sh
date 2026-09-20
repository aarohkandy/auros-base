#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# auros-base/tests/run-all.sh — every test in this repository that does not need a VM.
#
# This is the layer of testing UNDERNEATH the check matrix: it runs on a laptop, with bash, sed, grep,
# awk, coreutils and python3, in a couple of seconds, on every edit. It cannot tell you that a machine
# boots, that SELinux is enforcing on real hardware, or that a bad image rolls back — those are U1-U5
# and B1-B12 in matrix/, in QEMU, and nothing here replaces them.
#
# What it CAN tell you, cheaply enough to run every time, is whether the assertions that decide
# whether an image ships are capable of saying no. That question is not academic here: the SELinux
# kernel-argument check in build/10-hardening.sh was permanently RED for part of a day and then
# permanently GREEN for an hour, and in neither state was anything wrong with the image.
#
# THE SUITES, and who owns what:
#   tests/*.test.sh                  the build scripts' assertions, against synthetic fake roots
#   tests/kargs-check.test.sh        the SELinux kernel-argument check, which earned its own file
#   policy/tests/*.test.sh           the policy mode primitives and apply-policy
#   desktop/tests/*.test.sh          check B12 per policy mode
#   update-agent/tests/run-tests.sh  the update agent, greenboot health checks and drop-ins
#
# Exit status is 0 only if every suite passed. A suite that ABORTS (exit 90 — usually an extraction
# that matched nothing, meaning the test had stopped testing anything) is reported separately from a
# suite that failed, because the two need different responses: a failure means the code is wrong, an
# abort means the TEST is wrong and until it is fixed you have no information either way.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

c() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

SUITES=()
for f in "$HERE"/*.test.sh "$REPO"/policy/tests/*.test.sh "$REPO"/desktop/tests/*.test.sh; do
  [ -f "$f" ] && SUITES+=("$f")
done
[ -f "$REPO/update-agent/tests/run-tests.sh" ] && SUITES+=("$REPO/update-agent/tests/run-tests.sh")

[ ${#SUITES[@]} -gt 0 ] || { echo "run-all.sh: found no test suites at all — that is a broken checkout, not a pass" >&2; exit 2; }

PASSED=(); FAILED=(); ABORTED=()
VERBOSE="${AUROS_TEST_VERBOSE:-0}"
[ "${1:-}" = "-v" ] && VERBOSE=1

for s in "${SUITES[@]}"; do
  name="${s#$REPO/}"
  out="$(bash "$s" 2>&1)"; rc=$?
  tail_line="$(printf '%s\n' "$out" | grep -E '[0-9]+ (passed|PASSED)' | tail -1 | sed 's/^[[:space:]]*//')"
  case $rc in
    0)  PASSED+=("$name"); printf '%s  %-46s %s\n' "$(c 32 'PASS')" "$name" "${tail_line:-}" ;;
    90) ABORTED+=("$name"); printf '%s %-46s %s\n' "$(c 31 'ABORT')" "$name" "the suite stopped testing anything — fix the test" ;;
    *)  FAILED+=("$name"); printf '%s  %-46s %s\n' "$(c 31 'FAIL')" "$name" "${tail_line:-exit $rc}" ;;
  esac
  if [ "$VERBOSE" = 1 ] || { [ "$rc" != 0 ]; }; then
    printf '%s\n' "$out" | sed 's/^/    │ /'
  fi
done

printf '\n'
printf '%d suite(s): %d passed' "${#SUITES[@]}" "${#PASSED[@]}"
[ ${#FAILED[@]}  -gt 0 ] && printf ', %s' "$(c 31 "${#FAILED[@]} failed")"
[ ${#ABORTED[@]} -gt 0 ] && printf ', %s' "$(c 31 "${#ABORTED[@]} aborted")"
printf '\n'

if [ ${#ABORTED[@]} -gt 0 ]; then
  printf '\n%s\n' "$(c 31 'A suite that aborted proved nothing. Do not read this run as a pass.')"
fi
[ ${#FAILED[@]} -eq 0 ] && [ ${#ABORTED[@]} -eq 0 ]

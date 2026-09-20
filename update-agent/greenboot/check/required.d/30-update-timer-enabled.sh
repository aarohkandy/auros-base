#!/usr/bin/bash
#
# REQUIRED health check -- this machine can still update itself.
#
# "A machine that can't update is a machine we abandoned" -- and an abandoned laptop is the exact
# thing we sell against. So an image that arrives with its own update path broken is an image
# this machine must refuse to keep, which is why this is required.d and not wanted.d.
#
# The unit name is MEASURED, not assumed. Aurora enables uupd.timer and leaves bootc's own
# bootc-fetch-apply-updates.timer present-but-disabled (see update-agent/README.md); we enable
# bootc's and override its ExecStart. If a future base renames the unit, 30-update-agent.sh fails
# the BUILD -- but this check is the backstop that catches it on a machine already in the field.

set -uo pipefail

# ── THE ONE TEST SEAM ───────────────────────────────────────────────────────────────────────────
# Every absolute path below is taken relative to ${AUROS_TEST_ROOT}, which is unset on a real machine
# -- ${R} is then empty and the paths are exactly the paths. tests/30-update-agent.test.sh sets it to
# a scratch tree with stub binaries on PATH, which is how this check is shown to be able to go RED.
# Same seam and same reasoning as 40-no-new-failed-units.sh.
#
# A REQUIRED health check that cannot fail does not merely prove nothing: it silently DISABLES
# rollback while looking installed, because greenboot declares a boot green when every required check
# exits 0. That is the worst outcome in this directory, so every branch here is exercised.
R="${AUROS_TEST_ROOT:-}"

TIMER=bootc-fetch-apply-updates.timer
WRAPPER="${R}/usr/libexec/auros/auros-update"

fail() { echo "FAIL: $*" >&2; exit 1; }

enabled="$(systemctl is-enabled "${TIMER}" 2>&1 || true)"
[[ "${enabled}" == "enabled" || "${enabled}" == "enabled-runtime" ]] \
    || fail "${TIMER} is '${enabled}', not enabled. This machine would never fetch another update."

# Enabled but masked-by-drop-in / never scheduled is the failure this second assertion catches:
# a timer can be enabled and still have no next elapse if something disabled it at runtime.
active="$(systemctl is-active "${TIMER}" 2>&1 || true)"
[[ "${active}" == "active" || "${active}" == "activating" ]] \
    || fail "${TIMER} is enabled but '${active}'. It is not scheduled to run."

[[ -x "${WRAPPER}" ]] \
    || fail "${WRAPPER} is missing or not executable, but the unit's ExecStart points at it. The update run would fail every time."

command -v bootc >/dev/null 2>&1 || fail "bootc is not installed"

next="$(systemctl show "${TIMER}" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
echo "OK: ${TIMER} enabled and ${active}; next elapse: ${next:-unknown}"
exit 0

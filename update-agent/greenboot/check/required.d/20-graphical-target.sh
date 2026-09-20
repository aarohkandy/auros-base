#!/usr/bin/bash
#
# REQUIRED health check -- the machine reached the thing a person logs in to.
#
# This is the runtime half of check B1 ("display manager active / greeter detected within 120 s
# of power-on"). It is the check that makes "fails to reach a login prompt twice => roll back"
# literally true, because without it a machine that boots to a black screen is, as far as
# greenboot is concerned, perfectly healthy.
#
# TIMING: greenboot-healthcheck.service is WantedBy=multi-user.target, and the display manager
# starts later, as part of graphical.target. So this polls. systemd's default TimeoutStartSec of
# 90 s would kill us before our own 120 s deadline, which is why the unit carries a
# TimeoutStartSec=300s drop-in.
#
# KIOSK: per D12 a kiosk image has no display manager binary at all (check S9 asserts that
# against the filesystem). So the assertion is conditional on what the image declares it has --
# but it never degrades to "pass anything". No display manager means we require graphical.target
# instead, which is still a real assertion that the graphical stack came up.
#
# ASSUMPTION about another agent's area, stated per the file-ownership rule: the policy-mode
# layer decides whether a display manager exists. This check reads that off the filesystem
# (${R}/usr/lib/systemd/system/display-manager.service) rather than off a config file, so it stays
# correct no matter how that layer is implemented, and it does not require that layer to write
# anything for us.

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

DEADLINE_SECONDS=120
POLL_SECONDS=2

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_for_active() {
    local unit="$1" waited=0 state
    while (( waited < DEADLINE_SECONDS )); do
        state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
        [[ "${state}" == "active" ]] && { echo "${unit} active after ${waited}s"; return 0; }
        [[ "${state}" == "failed" ]] && { echo "${unit} FAILED after ${waited}s"; return 1; }
        sleep "${POLL_SECONDS}"
        waited=$(( waited + POLL_SECONDS ))
    done
    echo "${unit} still '${state}' after ${DEADLINE_SECONDS}s"
    return 1
}

if [[ -e ${R}/usr/lib/systemd/system/display-manager.service || -e ${R}/etc/systemd/system/display-manager.service ]]; then
    echo "image declares a display manager"
    wait_for_active display-manager.service \
        || fail "this image ships a display manager but it never reached a running state; there is no login prompt"
    echo "OK: display-manager.service is active"
    exit 0
fi

# No display manager: a kiosk image (D12). The graphical stack must still be up, or the kiosk
# session has nothing to draw on.
echo "no display manager in this image -- treating as a kiosk build (D12)"
wait_for_active graphical.target \
    || fail "no display manager AND graphical.target never became active; this machine has no usable screen"
echo "OK: graphical.target is active"
exit 0

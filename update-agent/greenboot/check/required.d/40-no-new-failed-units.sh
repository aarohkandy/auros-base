#!/usr/bin/bash
#
# REQUIRED health check -- this image did not break anything the last good one had working.
#
# The comparison is a SET DIFFERENCE against the last boot that greenboot declared green, not
# against zero. Two reasons:
#
#   * "zero failed units" is check B11's job, in a clean VM, where it is a fair thing to demand.
#     On a real 2013 laptop with a flaky SD reader, demanding zero would roll back every image
#     forever, and the machine would never be patched again.
#   * What we actually care about is a REGRESSION: something that worked on the image we are
#     replacing and does not work on the image we are installing. That is exactly the set of
#     unit names that are failed now and were not failed then.
#
# The baseline is written by green.d/10-auros-record-good-boot.sh, so it only ever reflects a
# boot that passed every required check. It lives in /var, which survives the deployment swap --
# if it lived in the image it would be replaced by the very update we are trying to judge.
#
# First boot has no baseline. That passes, loudly: there is genuinely nothing to regress against
# on a machine's first boot, and failing it would roll back the image the customer just paid for.
#
# ── BOTH SIDES OF THE DIFFERENCE ARE SAMPLED AT THE SAME POINT IN THE BOOT ──────────────────────
#
# They used to not be, and it silently hollowed the check out. This script runs from
# greenboot-healthcheck.service (WantedBy=multi-user.target). green.d runs from
# greenboot-task-runner.service, AFTER boot-complete.target -- strictly later, once the graphical
# stack has had time to fail. So the baseline was a superset sampled late and the current reading
# was sampled early: any unit that failed after multi-user.target -- which is most of the desktop,
# the thing D4 makes the product -- was recorded into the baseline as normal and then never
# observed at check time on the following boot, so it could never register as a regression. The
# bias was toward passing, which is the safe direction for false rollbacks and the useless
# direction for finding real ones.
#
# The fix is to sample ONCE, here, and have green.d promote THIS snapshot rather than take its
# own later one. So this script writes `failed-units.candidate` (stamped with the boot id) and
# green.d/10-auros-record-good-boot.sh renames it to `failed-units.baseline` only if greenboot
# went on to declare this same boot green. That keeps the property that made the baseline
# trustworthy -- only a boot that passed every required check becomes the new normal -- and adds
# the one it was missing, which is that the two sides are comparable at all.
#
# WHERE IN THE BOOT "here" IS, precisely: required.d runs in numeric order and strict mode, so
# 20-graphical-target.sh has already waited for display-manager.service to reach `active` (or,
# on a kiosk image, graphical.target) before this script runs. The sample is therefore taken
# after the graphical stack is up, not before it.
#
# WHAT THIS CHECK STILL CANNOT SEE, stated because the old header claimed coverage the sampling
# did not give: a unit that fails LATER than this point -- between here and boot-complete.target,
# or in a user session afterwards -- is in neither side of the difference and is invisible to
# this check by construction. Zero-failed-units at rest is check B11's job, in a clean VM, where
# demanding it is fair. On a customer's 2013 laptop it is not, for the reason above.

set -uo pipefail

# ── THE ONE TEST SEAM ───────────────────────────────────────────────────────────────────────────
# Every absolute path below is taken relative to ${AUROS_TEST_ROOT}, which is unset on a real
# machine -- ${R} is then empty and the paths are exactly the paths. tests/run-tests.sh sets it to
# a scratch tree with stub binaries on PATH, which is how each branch here is shown to be
# reachable, including the ones that go red (D19: a step that cannot fail is not a check).
R="${AUROS_TEST_ROOT:-}"

STATE_DIR="${R}/var/lib/auros/update-agent"
BASELINE="${STATE_DIR}/failed-units.baseline"
CANDIDATE="${STATE_DIR}/failed-units.candidate"
IGNORE="${R}/etc/auros/update-agent/failed-units.ignore"

boot_id() { cat "${R}/proc/sys/kernel/random/boot_id" 2>/dev/null || echo unknown; }

fail() { echo "FAIL: $*" >&2; exit 1; }

current_failed() {
    systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -v '^$' | sort -u
}

now="$(current_failed)"
echo "failed units now: $(echo "${now}" | grep -c . 2>/dev/null || echo 0)"
[[ -n "${now}" ]] && echo "${now}" | sed 's/^/  now-failed: /'

# Offer THIS snapshot, taken at THIS point in the boot, as the next baseline. green.d promotes it
# only if greenboot goes on to declare this boot green -- so a bad boot can still never launder
# its failures into the new normal, and the two sides of tomorrow's difference are sampled at the
# same moment of the boot as each other. Best effort: if /var is not writable there is nothing
# useful to do about it here and it must not fail the boot.
if mkdir -p "${STATE_DIR}" 2>/dev/null; then
    {
        printf '#boot-id %s\n' "$(boot_id)"
        printf '%s\n' "${now}" | grep -v '^$' || true
    } > "${CANDIDATE}.tmp" 2>/dev/null \
        && mv -f "${CANDIDATE}.tmp" "${CANDIDATE}" 2>/dev/null \
        && echo "offered this snapshot as the next baseline (${CANDIDATE}, boot-id $(boot_id))" \
        || echo "NOTE: could not write ${CANDIDATE}; green.d will fall back to sampling late."
fi

if [[ ! -r "${BASELINE}" ]]; then
    echo "OK: no baseline at ${BASELINE} yet -- this is the first boot greenboot has judged."
    echo "There is nothing to regress against, so this check passes. The baseline is written"
    echo "by green.d once this boot is declared green."
    exit 0
fi

# grep -v '^#' so a baseline written by any version of green.d that promoted the candidate file
# verbatim cannot smuggle its `#boot-id` header in as if it were the name of a failed unit.
before="$(grep -v '^[[:space:]]*#' "${BASELINE}" | grep -v '^$' | sort -u || true)"
echo "failed units at the last green boot: $(echo "${before}" | grep -c . 2>/dev/null || echo 0)"

new="$(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${now}") || true)"

# Units the image explicitly tolerates. Other layers may append to this file; one unit name per
# line, '#' comments allowed. Keeping it in /etc means a site can add a known-bad printer unit
# without us shipping a new image for it.
if [[ -s "${IGNORE}" ]]; then
    ignore="$(grep -v '^[[:space:]]*#' "${IGNORE}" | tr -d '[:blank:]' | grep -v '^$' | sort -u || true)"
    if [[ -n "${ignore}" ]]; then
        new="$(comm -23 <(printf '%s\n' "${new}" | grep -v '^$' | sort -u) <(printf '%s\n' "${ignore}") || true)"
    fi
fi

new="$(printf '%s\n' "${new}" | grep -v '^$' || true)"

if [[ -n "${new}" ]]; then
    echo "${new}" | sed 's/^/  REGRESSED: /' >&2
    fail "$(echo "${new}" | grep -c .) unit(s) are failed now that were working on the last good boot"
fi

echo "OK: no unit failed on this boot that was not already failing on the last good one."
exit 0

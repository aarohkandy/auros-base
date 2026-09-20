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

set -uo pipefail

STATE_DIR=/var/lib/auros/update-agent
BASELINE="${STATE_DIR}/failed-units.baseline"
IGNORE=/etc/auros/update-agent/failed-units.ignore

fail() { echo "FAIL: $*" >&2; exit 1; }

current_failed() {
    systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -v '^$' | sort -u
}

now="$(current_failed)"
echo "failed units now: $(echo "${now}" | grep -c . 2>/dev/null || echo 0)"
[[ -n "${now}" ]] && echo "${now}" | sed 's/^/  now-failed: /'

if [[ ! -r "${BASELINE}" ]]; then
    echo "OK: no baseline at ${BASELINE} yet -- this is the first boot greenboot has judged."
    echo "There is nothing to regress against, so this check passes. The baseline is written"
    echo "by green.d once this boot is declared green."
    exit 0
fi

before="$(sort -u < "${BASELINE}")"
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

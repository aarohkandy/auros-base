#!/usr/bin/bash
#
# Runs only when greenboot has declared the boot GREEN (greenboot-task-runner.service, after
# boot-complete.target). This is what gives 40-no-new-failed-units.sh something to compare
# against, and the reason it compares against a KNOWN-GOOD boot rather than the previous boot:
# a baseline taken from a bad boot would launder that boot's failures into the new normal, and
# the regression check would stop detecting anything. That is the standard way a test suite
# quietly stops testing.
#
# ── WHAT IT PROMOTES, AND WHY IT DOES NOT SAMPLE ────────────────────────────────────────────────
#
# This script used to run `systemctl list-units --state=failed` itself. That is the wrong clock.
# It runs after boot-complete.target; 40-no-new-failed-units.sh runs from
# greenboot-healthcheck.service, WantedBy=multi-user.target, which is strictly EARLIER. So the
# baseline was sampled late and the reading it was compared against was sampled early, the
# baseline was a superset by construction, and any unit that failed after multi-user.target --
# which is most of the desktop -- was written into the baseline as normal and never observed at
# check time on the next boot. It could not register as a regression. The check was biased toward
# passing and nothing said so.
#
# So: 40-no-new-failed-units.sh takes ONE snapshot, at its own sampling point, and writes it to
# failed-units.candidate stamped with the boot id. This script PROMOTES that file, unchanged, and
# only when its boot id is this boot's. Both sides of tomorrow's difference are then sampled at
# the same moment of the boot, and the "only a green boot becomes the baseline" property is
# unchanged -- nothing gets promoted unless greenboot reached this script, which it only does
# after every required check passed.
#
# If the candidate is missing or belongs to a different boot, we fall back to sampling here and
# SAY SO, rather than silently reintroducing the skew.
#
# /var, not /etc and not the image: this has to survive the deployment swap. A baseline shipped
# inside the image would be replaced by the very update we are trying to judge.

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
mkdir -p "${STATE_DIR}"

this_boot="$(cat "${R}/proc/sys/kernel/random/boot_id" 2>/dev/null || echo unknown)"
promoted=no

if [[ -r "${CANDIDATE}" ]]; then
    cand_boot="$(sed -n 's/^#boot-id //p' "${CANDIDATE}" | head -n1)"
    if [[ -n "${cand_boot}" && "${cand_boot}" == "${this_boot}" ]]; then
        # Promote verbatim, minus the header. Same snapshot the healthcheck judged this boot on.
        grep -v '^[[:space:]]*#' "${CANDIDATE}" | grep -v '^$' | sort -u \
            > "${BASELINE}.tmp" 2>/dev/null || : > "${BASELINE}.tmp"
        mv -f "${BASELINE}.tmp" "${BASELINE}"
        rm -f "${CANDIDATE}"
        promoted=yes
        echo "promoted the healthcheck's own snapshot (boot-id ${this_boot}) to the baseline"
    else
        echo "NOTE: ${CANDIDATE} carries boot-id '${cand_boot:-none}', not this boot's (${this_boot}); not promoting it."
    fi
else
    echo "NOTE: no ${CANDIDATE} for this boot."
fi

if [[ "${promoted}" != yes ]]; then
    # Fallback. This is the OLD, skewed sampling point and it is labelled as such: a baseline
    # taken here is later in the boot than the reading it will be compared against, so it can
    # hide a regression in anything that fails after multi-user.target. Better than no baseline,
    # worse than a promoted one, and it should not happen on a healthy machine -- if this line
    # shows up in the boot status every boot, 40-no-new-failed-units.sh is not writing its
    # candidate and that is the thing to fix.
    echo "FALLBACK: sampling failed units HERE (after boot-complete.target). This baseline is"
    echo "sampled later than the check that reads it and can therefore hide a late regression."
    systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -v '^$' | sort -u > "${BASELINE}.tmp" || true
    mv -f "${BASELINE}.tmp" "${BASELINE}"
fi

date -uIseconds > "${STATE_DIR}/last-green-boot"

if command -v bootc >/dev/null 2>&1; then
    bootc status --json 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(((d.get("status") or {}).get("booted") or {}).get("image",{}).get("imageDigest") or "")
except Exception:
    print("")
' > "${STATE_DIR}/last-green-digest" 2>/dev/null || true
fi

echo "recorded green-boot baseline (promoted=${promoted}): $(grep -c . "${BASELINE}" 2>/dev/null || true) failed unit(s), digest $(cat "${STATE_DIR}/last-green-digest" 2>/dev/null || echo unknown)"
exit 0

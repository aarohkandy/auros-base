#!/usr/bin/bash
#
# WANTED health check -- how long since this machine last successfully reached the registry?
#
# Not required.d, and this is U5 again: a school that loses its uplink for a fortnight must not
# have its laptops roll themselves back over it. But an operator should still be able to see, in
# the boot status motd, that a machine has quietly stopped hearing from us. "Still patched in
# four years" is the promise; this is the line that would be red for months before anybody
# noticed otherwise.
#
# ── THIS CHECK WAS WRONG IN BOTH DIRECTIONS AT ONCE. BOTH HALVES ARE FIXED. ────────────────────
#
# 1. A PERMANENT FALSE ALL-CLEAR, which was the serious one, and it was not in this file.
#    libexec/auros-update captured `bootc upgrade`'s exit status through a negation
#    (`if ! out="$(...)"; then rc=$?`), so rc was 0 on every path and the stamp this check reads
#    was refreshed on EVERY timer run regardless of outcome. A laptop that had refused every
#    update for two years reported "last successful update fetch was 0 day(s) ago". Fixed at
#    source; the wrapper now writes last-successful-fetch only after a real success, writes
#    last-fetch-attempt always, and leaves last-error in place on failure.
#
# 2. A GUARANTEED FALSE ALARM ON THE ONE BOOT WHERE NOTHING IS WRONG. An absent stamp was scored
#    PROBLEM. On a freshly installed machine the stamp CANNOT exist: the first timer run is at
#    boot+3min plus up to 10 min of jitter, and greenboot-healthcheck has long since run. So the
#    very first boot a customer ever sees reported "no successful update fetch has ever been
#    recorded on this machine" in the boot status. That is D4's "clean end to end" first boot
#    showing a red line for a condition that is normal, which is how an operator learns to ignore
#    this check before it has ever told them anything true.
#
#    So an absent stamp is only a PROBLEM once a fetch should plausibly have happened. Two clocks
#    have to agree, because either alone is fooled:
#      * uptime, which catches "up for days and still nothing" -- but resets every reboot;
#      * agent-first-seen, written by this check the first time it runs, which catches "has
#        existed across many short boots and still nothing".
#    Below both thresholds: OK, and it says why. Above either: PROBLEM.
#
# ── AND IT WAS BLIND TO THE FAILURE WE ARE MOST LIKELY TO HAVE (SYSTEM-REVIEW §2.4, H4) ─────────
#
# 3. last-successful-fetch is stamped whenever `bootc upgrade` exits 0, and that includes
#    "already up to date; nothing staged". So if WE stop publishing, every laptop reaches the
#    registry every six hours, finds nothing, and reports "0 day(s) ago" -- green, forever. The
#    stamp measures registry reachability, not whether the running image is current.
#
#    So this check now ALSO reads the booted image's build time from `bootc status --json` and
#    goes red when it is older than IMAGE_WARN_AFTER_DAYS, whatever the fetch stamp says. The
#    field is .status.booted.image.timestamp: ImageStatus.timestamp, Option<DateTime<Utc>>,
#    serde camelCase, in bootc v1.16.10 crates/lib/src/spec.rs:206-217 (D25 pins bootc 1.16.10).
#    bootc fills it from the image's org.opencontainers.image.created LABEL, falling back to the
#    config's `created` (crates/lib/src/status.rs:203-209). It is optional, so an absent value is
#    reported, not assumed fresh: a canary that cannot see is not allowed to say green.

set -uo pipefail

# ── THE ONE TEST SEAM ───────────────────────────────────────────────────────────────────────────
# Every absolute path below is taken relative to ${AUROS_TEST_ROOT}, which is unset on a real
# machine -- ${R} is then empty and the paths are exactly the paths. tests/run-tests.sh sets it to
# a scratch tree with stub binaries on PATH, which is how each branch here is shown to be
# reachable, including the ones that go red (D19: a step that cannot fail is not a check).
R="${AUROS_TEST_ROOT:-}"

STATE_DIR="${R}/var/lib/auros/update-agent"
STAMP="${STATE_DIR}/last-successful-fetch"
ATTEMPT="${STATE_DIR}/last-fetch-attempt"
FIRST_SEEN="${STATE_DIR}/agent-first-seen"
WARN_AFTER_DAYS=14

# OWNER-TUNABLE JUDGMENT, not a measured constant. How old may the image a machine is RUNNING be
# before we call it drifting? Upstream Aurora stable rebuilds weekly (D25: cron Tuesday) and our
# nightly relocks when it moves, so a healthy machine's image is ~7 days old plus however long a
# staged update waits for a reboot. 21 days = roughly two missed upstream releases plus a reboot
# that slipped a week. Lower it and machines left on over a holiday go red; raise it and a stalled
# publish pipeline stays green for longer before the fleet says so.
IMAGE_WARN_AFTER_DAYS=21

# OnBootSec=3min + RandomizedDelaySec up to 10min = 13 min before the first run is even due, and
# then it has to pull over whatever the school's uplink is. 45 minutes is that with room, and it
# is far below the 14-day threshold this check exists for, so nothing real hides inside it.
GRACE_SECONDS=2700

now_s="$(date +%s)"

# ── HALF 1: is the image this machine is RUNNING current? ───────────────────────────────────────
# Runs first and never exits: its verdict is carried in image_rc and folded into every exit below,
# so a stale image cannot be masked by a fresh fetch stamp (the exact §2.4 scenario) and a fetch
# failure cannot be masked by a fresh image.
image_rc=0
# python3, not jq: libexec/auros-update does the same, jq is not guaranteed in the image.
booted="$(bootc status --json 2>/dev/null | python3 -c '
import json, re, sys, datetime
try:
    img = json.load(sys.stdin)["status"]["booted"]["image"]
except Exception:
    sys.exit(0)
ts = img.get("timestamp") or ""
digest = img.get("imageDigest") or "unknown-digest"
try:
    # chrono may emit nanoseconds; fromisoformat takes at most microseconds.
    t = datetime.datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", ts).replace("Z", "+00:00"))
    print(int(t.timestamp()), digest)
except Exception:
    print("none", digest)
' 2>/dev/null || true)"
read -r image_s image_digest <<<"${booted}"
if [[ -z "${booted}" ]]; then
    echo "PROBLEM: cannot tell how old the running image is: \`bootc status --json\` gave no booted image." >&2
    image_rc=1
elif [[ ! "${image_s}" =~ ^[0-9]+$ ]]; then
    echo "PROBLEM: the booted image (${image_digest}) carries no build timestamp in \`bootc status --json\` (.status.booted.image.timestamp), so this machine cannot tell whether it is current." >&2
    image_rc=1
else
    image_age_days=$(( (now_s - image_s) / 86400 ))
    if (( image_age_days >= IMAGE_WARN_AFTER_DAYS )); then
        echo "PROBLEM: the running image (${image_digest}) was built ${image_age_days} days ago (threshold ${IMAGE_WARN_AFTER_DAYS}). Whatever the fetch stamp below says, no newer image has reached this machine -- if fetches are succeeding, nothing newer is being published." >&2
        image_rc=1
    else
        echo "OK: the running image (${image_digest}) was built ${image_age_days} day(s) ago."
    fi
fi

# ── HALF 2: can this machine still fetch? ────────────────────────────────────────────────────────
show_last_error() {
    [[ -r "${STATE_DIR}/last-error" ]] && sed 's/^/  /' "${STATE_DIR}/last-error" >&2
    return 0
}

if [[ ! -r "${STAMP}" ]]; then
    # Record when this machine first ran this check, so "never fetched" can be aged across
    # reboots and not just within one. Best effort; an unwritable /var must not turn into noise.
    if [[ ! -r "${FIRST_SEEN}" ]]; then
        mkdir -p "${STATE_DIR}" 2>/dev/null || true
        printf '%s\n' "${now_s}" > "${FIRST_SEEN}" 2>/dev/null || true
    fi
    first_seen_s="$(cat "${FIRST_SEEN}" 2>/dev/null || echo "${now_s}")"
    [[ "${first_seen_s}" =~ ^[0-9]+$ ]] || first_seen_s="${now_s}"
    known_for=$(( now_s - first_seen_s ))

    uptime_s="$(cut -d. -f1 < "${R}/proc/uptime" 2>/dev/null || echo 0)"
    [[ "${uptime_s}" =~ ^[0-9]+$ ]] || uptime_s=0

    if (( known_for < GRACE_SECONDS && uptime_s < GRACE_SECONDS )); then
        echo "OK: no update fetch has completed yet, and none is due yet -- this machine has been"
        echo "up ${uptime_s}s and known to the update agent for ${known_for}s, against a first-run"
        echo "window of ${GRACE_SECONDS}s (OnBootSec=3min + up to 10min jitter + the pull)."
        exit "${image_rc}"
    fi

    if [[ -r "${ATTEMPT}" ]]; then
        echo "PROBLEM: this machine has TRIED to fetch an update (last attempt $(cat "${ATTEMPT}")) and has never once succeeded. It is not being patched." >&2
    else
        echo "PROBLEM: no successful update fetch has ever been recorded on this machine (${STAMP} absent), and it has been up ${uptime_s}s / known for ${known_for}s -- well past the point where the first fetch was due. The update timer may not be running at all; check bootc-fetch-apply-updates.timer." >&2
    fi
    show_last_error
    exit 1
fi

then_s="$(date -d "$(cat "${STAMP}")" +%s 2>/dev/null || echo 0)"
if (( then_s == 0 )); then
    echo "PROBLEM: ${STAMP} is unparseable: $(cat "${STAMP}")" >&2
    exit 1
fi

age_days=$(( (now_s - then_s) / 86400 ))
if (( age_days >= WARN_AFTER_DAYS )); then
    echo "PROBLEM: last successful update fetch was ${age_days} days ago. This machine may be drifting out of support." >&2
    show_last_error
    exit 1
fi

echo "OK: last successful update fetch was ${age_days} day(s) ago."
# A machine that succeeded a fortnight ago and has been failing every six hours since is still
# inside the threshold above, but the operator should see the failures, not just the last win.
if [[ -r "${STATE_DIR}/last-error" ]]; then
    echo "NOTE: the most recent fetch attempt FAILED; the stamp above is from an earlier run."
    sed 's/^/  /' "${STATE_DIR}/last-error"
fi
exit "${image_rc}"

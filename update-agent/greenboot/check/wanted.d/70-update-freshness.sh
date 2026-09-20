#!/usr/bin/bash
#
# WANTED health check -- how long since this machine last successfully reached the registry?
#
# Not required.d, and this is U5 again: a school that loses its uplink for a fortnight must not
# have its laptops roll themselves back over it. But an operator should still be able to see, in
# the boot status motd, that a machine has quietly stopped hearing from us. "Still patched in
# four years" is the promise; this is the line that would be red for months before anybody
# noticed otherwise.

set -uo pipefail

STATE_DIR=/var/lib/auros/update-agent
STAMP="${STATE_DIR}/last-successful-fetch"
WARN_AFTER_DAYS=14

if [[ ! -r "${STAMP}" ]]; then
    echo "PROBLEM: no successful update fetch has ever been recorded on this machine (${STAMP} absent)." >&2
    exit 1
fi

then_s="$(date -d "$(cat "${STAMP}")" +%s 2>/dev/null || echo 0)"
now_s="$(date +%s)"
if (( then_s == 0 )); then
    echo "PROBLEM: ${STAMP} is unparseable: $(cat "${STAMP}")" >&2
    exit 1
fi

age_days=$(( (now_s - then_s) / 86400 ))
if (( age_days >= WARN_AFTER_DAYS )); then
    echo "PROBLEM: last successful update fetch was ${age_days} days ago. This machine may be drifting out of support." >&2
    [[ -r "${STATE_DIR}/last-error" ]] && sed 's/^/  /' "${STATE_DIR}/last-error" >&2
    exit 1
fi

echo "OK: last successful update fetch was ${age_days} day(s) ago."
exit 0

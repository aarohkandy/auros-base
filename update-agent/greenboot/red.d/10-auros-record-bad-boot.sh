#!/usr/bin/bash
#
# Runs when greenboot has declared the boot RED, i.e. just before redboot-auto-reboot decides
# whether to reboot toward a rollback.
#
# The machine is about to restart and, after two of these, land back on the previous image. At
# that point the journal for the failed boots is still on disk but nobody will think to look for
# it, and the customer's report will be "it restarted a few times and then it was fine". This
# writes a breadcrumb to /var -- which survives the rollback -- so that the machine that comes
# back up can say WHICH image failed and WHY, instead of the failure being invisible.
#
# Nothing here may fail the boot further. Best effort, always exits 0.

set -uo pipefail

STATE_DIR=/var/lib/auros/update-agent
mkdir -p "${STATE_DIR}" 2>/dev/null || exit 0
LOG="${STATE_DIR}/red-boots.log"

{
    echo "--- $(date -uIseconds) ---"
    if command -v bootc >/dev/null 2>&1; then
        bootc status --json 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); st=d.get("status") or {}
    b=(st.get("booted") or {}).get("image",{})
    r=(st.get("rollback") or {}).get("image",{})
    print("booted_digest=%s" % (b.get("imageDigest") or "unknown"))
    print("rollback_digest=%s" % (r.get("imageDigest") or "none"))
except Exception as e:
    print("bootc_status_unreadable=%s" % e)
' 2>/dev/null || echo "bootc_status_unreadable=1"
    fi
    echo "boot_counter=$(grub2-editenv list 2>/dev/null | grep '^boot_counter=' || echo unset)"
    echo "failed_units:"
    systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null | sed 's/^/  /' || true
    echo "greenboot_healthcheck_journal:"
    journalctl -b -u greenboot-healthcheck.service --no-pager -n 120 2>/dev/null | sed 's/^/  /' || true
} >> "${LOG}" 2>/dev/null || true

# Keep the file from growing without bound on a machine that red-boots repeatedly.
if [[ -f "${LOG}" ]] && [[ "$(wc -c < "${LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]]; then
    tail -c 524288 "${LOG}" > "${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "${LOG}"
fi

echo "recorded red-boot diagnostics to ${LOG}"
exit 0

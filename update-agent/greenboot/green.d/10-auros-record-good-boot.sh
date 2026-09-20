#!/usr/bin/bash
#
# Runs only when greenboot has declared the boot GREEN (greenboot-task-runner.service, after
# boot-complete.target). This is what gives 40-no-new-failed-units.sh something to compare
# against, and the reason it compares against a KNOWN-GOOD boot rather than the previous boot:
# a baseline taken from a bad boot would launder that boot's failures into the new normal, and
# the regression check would stop detecting anything. That is the standard way a test suite
# quietly stops testing.
#
# /var, not /etc and not the image: this has to survive the deployment swap. A baseline shipped
# inside the image would be replaced by the very update we are trying to judge.

set -uo pipefail

STATE_DIR=/var/lib/auros/update-agent
mkdir -p "${STATE_DIR}"

systemctl list-units --state=failed --plain --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | grep -v '^$' | sort -u > "${STATE_DIR}/failed-units.baseline.tmp" || true
mv -f "${STATE_DIR}/failed-units.baseline.tmp" "${STATE_DIR}/failed-units.baseline"

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

echo "recorded green-boot baseline: $(grep -c . "${STATE_DIR}/failed-units.baseline" 2>/dev/null || echo 0) failed unit(s), digest $(cat "${STATE_DIR}/last-green-digest" 2>/dev/null || echo unknown)"
exit 0

#!/usr/bin/bash
#
# REQUIRED health check -- the network stack came up.
#
# READ THIS BEFORE TIGHTENING IT.
#
# The obvious version of this check is "can we resolve DNS / reach the registry". That version
# would be a bug that destroys schools. A required check that fails rolls the machine back, and
# the uplink being down is not the image's fault. A school whose broadband drops overnight would
# find every laptop rolled back to the previous image in the morning -- and if the outage lasts,
# rolled back again from there, which is the fallback boot and is unrecoverable without a
# technician. U5 says an offline machine must be a no-op. So this check proves the machine's own
# network stack works, and deliberately proves nothing about the internet.
#
# It also must not require a *configured* connection: a laptop on its very first boot has no
# Wi-Fi credentials yet, and failing it there would roll back the image the customer just
# installed.
#
# greenboot-default-health-checks ships 01_repository_dns_check.sh, which does exactly the
# dangerous thing. That subpackage is deliberately not installed -- see update-agent/README.md.

set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

systemctl is-active --quiet NetworkManager.service \
    || fail "NetworkManager.service is not active ($(systemctl is-active NetworkManager.service 2>&1))"

# The daemon answering at all is the property we can assert without punishing an offline site.
command -v nmcli >/dev/null 2>&1 || fail "nmcli is missing; the network stack cannot be inspected"
nmcli -t -f RUNNING general status >/dev/null 2>&1 \
    || fail "NetworkManager is active but not answering nmcli"

state="$(nmcli -t -f STATE general status 2>/dev/null || echo unknown)"
echo "OK: NetworkManager active, general state=${state}"
echo "NOTE: connectivity to the internet is intentionally NOT asserted here (U5)."
exit 0

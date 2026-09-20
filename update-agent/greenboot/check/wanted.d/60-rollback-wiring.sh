#!/usr/bin/bash
#
# WANTED health check -- could this machine actually roll itself back if it had to?
#
# WHY wanted.d AND NOT required.d. This one is a genuine trap and the reasoning is worth keeping.
#
# The failure this check looks for is "GRUB has no boot_counter logic". If that is true and
# boot_counter happens to be SET (staged by greenboot before a reboot), then marking the boot red
# calls redboot-auto-reboot, which reboots -- and GRUB, having no counter logic, never decrements
# and never switches to the rollback entry. The machine reboots forever. A required check here
# would turn "auto-rollback is not wired" into "the laptop is bricked", which is strictly worse
# than the problem it is detecting, and a school has no out-of-band console to escape it with.
#
# So: warn here, and assert it hard where it is safe to assert it --
#   * build/30-update-agent.sh fails the build if 08_greenboot.cfg is not in the bootupd
#     grub2-static configs.d that bootupd assembles into /boot/grub2/grub.cfg
#   * check U3 proves the rollback end to end in a VM before anything ships
#   * auros-update logs the same warning before it stages anything
#
# D9: greenboot's rollback does not work on the composefs/UKI backend -- upstream has not wired
# boot-loader entry counting there. We stay on ostree + GRUB/bootupd deliberately. This check is
# where that constraint becomes observable on a real machine instead of a sentence in a document.
#
# D10: exactly one rollback deployment is retained. Not "recent images", not N. One.

set -uo pipefail

rc=0
problem() { echo "PROBLEM: $*" >&2; rc=1; }

# --- 1. ostree + GRUB backend, not composefs/UKI (D9) ----------------------------------------
if [[ -e /run/ostree-booted ]]; then
    echo "OK: booted via ostree (/run/ostree-booted present)"
else
    problem "/run/ostree-booted is absent. This does not look like the ostree backend; greenboot rollback does not work on composefs/UKI (D9)."
fi

status_json="$(bootc status --json 2>/dev/null || true)"
if [[ -n "${status_json}" ]]; then
    printf '%s' "${status_json}" | python3 - <<'PY' || rc=1
import json,sys
d=json.load(sys.stdin)
st=d.get("status") or {}
booted=st.get("booted") or {}
if booted.get("composefs"):
    print("PROBLEM: booted deployment reports a composefs backend; greenboot rollback is not wired there (D9)", file=sys.stderr)
    sys.exit(1)
rollback=st.get("rollback")
others=st.get("otherDeployments") or []
if rollback is None:
    print("PROBLEM: bootc reports NO rollback deployment. There is nothing to roll back to.", file=sys.stderr)
    sys.exit(1)
print("OK: one rollback deployment retained (D10). otherDeployments=%d" % len(others))
PY
else
    problem "bootc status --json produced nothing"
fi

# --- 2. GRUB actually carries the counter logic ----------------------------------------------
# Measured: greenboot ships /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg, and bootupd
# concatenates every *.cfg in that directory into /boot/grub2/grub.cfg at install time
# (coreos/bootupd src/grubconfigs.rs, read 2026-09-20). If the machine was installed before
# greenboot was added to the image, the fragment is in /usr but NOT in grub.cfg, and
# rollback silently does not exist.
if [[ -r /boot/grub2/grub.cfg ]]; then
    if grep -q 'boot_counter' /boot/grub2/grub.cfg; then
        echo "OK: /boot/grub2/grub.cfg contains boot_counter logic"
    else
        problem "/boot/grub2/grub.cfg has NO boot_counter logic. Auto-rollback will not happen on this machine. Fix with: bootupctl update"
    fi
else
    problem "/boot/grub2/grub.cfg is unreadable; cannot confirm the boot counter is wired"
fi

# --- 3. retry count is the one we documented --------------------------------------------------
conf=/etc/greenboot/greenboot.conf
if [[ -r "${conf}" ]]; then
    attempts="$(grep -E '^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=' "${conf}" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
    if [[ "${attempts}" == "2" ]]; then
        echo "OK: GREENBOOT_MAX_BOOT_ATTEMPTS=2 -- two failed boots, then rollback."
    else
        problem "GREENBOOT_MAX_BOOT_ATTEMPTS is '${attempts:-unset}' (upstream default is 3). Auros ships 2 so that 'fails twice => rollback' is literally true."
    fi
else
    problem "${conf} is missing"
fi

exit "${rc}"

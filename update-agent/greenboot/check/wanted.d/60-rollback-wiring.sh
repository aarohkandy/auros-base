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
# The DECISIVE runtime test for that is section 1b: ostree-finalize-staged.service and
# greenboot-grub2-set-counter.service present on the filesystem. That is true or false whatever
# bootc calls its JSON fields this month, and it is the same property build/30-update-agent.sh
# asserts at build time -- the difference is that this one also covers a machine installed from
# an older image and a base that flips backend under a future rebuild, neither of which a
# build-time guard can see.
#
# D10: exactly one rollback deployment is retained. Not "recent images", not N. One.
#
# EVERY BRANCH BELOW IS REACHABLE. tests/run-tests.sh drives this script against fabricated
# `bootc status` output -- composefs, no-rollback-with-two-deployments, no-rollback-on-a-fresh-
# machine, unparseable JSON -- and asserts the exit status and the message for each. A health
# check nobody has ever seen go red is a decoration (D19).

set -uo pipefail

# ── THE ONE TEST SEAM ───────────────────────────────────────────────────────────────────────────
# Every absolute path this script reads is taken relative to ${AUROS_TEST_ROOT}. On a real machine
# that variable is unset, ${R} is empty, and the paths are exactly the paths -- nothing changes.
# tests/run-tests.sh sets it to a scratch tree and puts stub `bootc`/`systemctl` on PATH, which is
# how every branch below is DEMONSTRATED to be reachable, including the ones that go red. Setting
# it on a real machine requires the ability to edit the environment of a root systemd unit, i.e.
# root already; and the only effect would be to make this check read state that is not there,
# which reports a problem rather than hiding one. A check nobody has watched fail is a decoration
# (D19), and before this seam existed nobody could have watched this one fail -- its whole JSON
# block raised a traceback on every boot instead.
R="${AUROS_TEST_ROOT:-}"

rc=0
problem() { echo "PROBLEM: $*" >&2; rc=1; }

# --- 1. ostree + GRUB backend, not composefs/UKI (D9) ----------------------------------------
if [[ -e "${R}/run/ostree-booted" ]]; then
    echo "OK: booted via ostree (/run/ostree-booted present)"
else
    problem "/run/ostree-booted is absent. This does not look like the ostree backend; greenboot rollback does not work on composefs/UKI (D9)."
fi

# --- 1b. the ostree units the boot counter is actually staged by (D9, at RUNTIME) -------------
# The build asserts these at build time (build/30-update-agent.sh). That covers the image we
# ship; it does not cover a machine that was installed from an older image, nor a base that flips
# to composefs under a future rebuild. greenboot-grub2-set-counter.service is RequiredBy
# ostree-finalize-staged.service -- on the composefs/UKI backend that unit does not exist, the
# counter is never staged, and rollback does not happen while everything else still looks fine.
# This is a FILESYSTEM assertion, so it is true or false regardless of what any JSON field is
# named in whatever bootc version this machine is carrying.
for u in ostree-finalize-staged.service greenboot-grub2-set-counter.service; do
    if [[ -e "${R}/usr/lib/systemd/system/${u}" || -e "${R}/etc/systemd/system/${u}" ]]; then
        echo "OK: ${u} is present"
    else
        problem "${u} is absent. greenboot's boot counter is staged through it; without it nothing decrements the counter and auto-rollback does not happen (D9 -- this is what a composefs/UKI backend looks like from inside the machine)."
    fi
done

# --- 1c. what bootc itself reports about the rollback deployment (D10) -------------------------
# THE BUG THIS REPLACES, because it is worth not repeating:
#
#     printf '%s' "${status_json}" | python3 - <<'PY' ... PY
#
# The heredoc is applied AFTER the pipe and overrides it, so python3 read the HEREDOC as its
# program (which is what `-` asks for) and json.load(sys.stdin) then read an already-consumed
# stdin sitting at EOF. Measured on this machine:
#     json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)   exit 1
# So the block raised on EVERY boot of EVERY machine, `|| rc=1` fired unconditionally, and
# neither the composefs test nor the rollback test ever executed -- while the one channel that
# would report "rollback is not wired on this machine" printed a Python traceback into the boot
# status forever and was therefore guaranteed to be ignored.
#
# You cannot pipe data into a heredoc'd program. Pass a PATH in argv, as
# 50-signature-enforcement.sh already does for policy.json.
status_json="$(bootc status --json 2>/dev/null || true)"
if [[ -n "${status_json}" ]]; then
    status_file="$(mktemp -t auros-rollback-status.XXXXXX 2>/dev/null || printf '/tmp/auros-rollback-status.%s' "$$")"
    printf '%s' "${status_json}" > "${status_file}"
    python3 - "${status_file}" <<'PY' || rc=1
import json, sys

try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception as e:
    print("PROBLEM: could not parse `bootc status --json`: %s" % e, file=sys.stderr)
    sys.exit(1)

st = d.get("status") or {}
booted = st.get("booted") or {}
rollback = st.get("rollback")
staged = st.get("staged")
others = st.get("otherDeployments") or []

# composefs: a positive signal only. bootc's field naming here is not something we have measured
# on this version, so its ABSENCE is not evidence of anything and must not be reported as an
# all-clear -- the decisive runtime test is the unit-file check above, which already ran.
for key in ("composefs", "composefsBacked", "bootOrder"):
    v = booted.get(key)
    if key == "bootOrder":
        if isinstance(v, str) and "composefs" in v.lower():
            print("PROBLEM: booted deployment reports bootOrder=%r; greenboot rollback is not wired on the composefs/UKI backend (D9)" % v, file=sys.stderr)
            sys.exit(1)
    elif v:
        print("PROBLEM: booted deployment reports %s=%r; greenboot rollback is not wired on the composefs/UKI backend (D9)" % (key, v), file=sys.stderr)
        sys.exit(1)

total = len(others) + sum(1 for x in (booted or None, rollback, staged) if x)

if rollback is not None:
    print("OK: one rollback deployment retained (D10). staged=%s otherDeployments=%d"
          % ("yes" if staged else "no", len(others)))
    sys.exit(0)

# No rollback, and that is NORMAL on a machine that has not taken an update yet: there is
# genuinely nothing behind it. Reporting it as a problem would put a red line in the boot status
# of every machine on the one boot where nothing is wrong (D4: "clean end to end").
if total <= 1:
    print("OK: this machine has taken no update yet, so there is no rollback deployment to keep. "
          "Expected until the first update lands; the counter wiring is asserted above and does not "
          "depend on it.")
    sys.exit(0)

print("PROBLEM: bootc reports %d deployment(s) but NO rollback deployment. There is nothing to "
      "roll back to, so a bad update on this machine is not recoverable by the machine."
      % total, file=sys.stderr)
sys.exit(1)
PY
    rm -f "${status_file}"
else
    problem "bootc status --json produced nothing"
fi

# --- 2. GRUB actually carries the counter logic ----------------------------------------------
# Measured: greenboot ships /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg, and bootupd
# concatenates every *.cfg in that directory into /boot/grub2/grub.cfg at install time
# (coreos/bootupd src/grubconfigs.rs, read 2026-09-20). If the machine was installed before
# greenboot was added to the image, the fragment is in /usr but NOT in grub.cfg, and
# rollback silently does not exist.
if [[ -r "${R}/boot/grub2/grub.cfg" ]]; then
    if grep -q 'boot_counter' "${R}/boot/grub2/grub.cfg"; then
        echo "OK: /boot/grub2/grub.cfg contains boot_counter logic"
    else
        problem "/boot/grub2/grub.cfg has NO boot_counter logic. Auto-rollback will not happen on this machine. Fix with: bootupctl update"
    fi
else
    problem "/boot/grub2/grub.cfg is unreadable; cannot confirm the boot counter is wired"
fi

# --- 3. retry count is the one we documented --------------------------------------------------
conf="${R}/etc/greenboot/greenboot.conf"
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

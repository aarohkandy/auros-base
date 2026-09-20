#!/usr/bin/bash
#
# WANTED health check -- is signature enforcement still switched on for this deployment?
#
# WHY THIS IS wanted.d AND NOT required.d, which is not obvious and is the interesting part:
#
# A required check that fails triggers a rollback. Rolling back because enforcement is off would
# not fix anything -- the deployment we roll back to was installed by the same `bootc install`,
# with the same install config, so it has the same setting. We would burn the boot counter, land
# on the fallback deployment, fail there too, and greenboot would then set boot_counter=-1 and
# stop (redboot-auto-reboot exits 2 on a fallback boot). Terminating, but a wasted rollback and
# a machine that looks broken when the real problem is upstream of it.
#
# Enforcement is instead asserted where an assertion can actually stop a bad image from shipping:
#   * at build time, by build/30-update-agent.sh
#   * at install time, by /usr/lib/bootc/install/30-auros.toml (enforce-container-sigpolicy)
#   * as check U4, by signing/verify-enforcement.sh, which proves the NEGATIVE
# This check is the field telemetry for the same fact, not the enforcement mechanism.
#
# THE FIELD THAT MATTERS: bootc records per-deployment how it will verify future fetches.
#   "containerPolicy" -> defer to containers-policy.json. This is what we require.
#   "insecure"        -> no verification will be performed, whatever policy.json says.
# Measured from bootc's own host-v1.schema.json (ImageSignature), read 2026-09-20. If this says
# "insecure", every word we have written about signing is false on this machine.

set -uo pipefail

warn_out=0
note() { echo "$*"; }
problem() { echo "PROBLEM: $*" >&2; warn_out=1; }

command -v bootc >/dev/null 2>&1 || { problem "bootc not installed"; exit "${warn_out}"; }

status_json="$(bootc status --json 2>/dev/null || true)"
[[ -n "${status_json}" ]] || { problem "bootc status --json produced nothing"; exit 1; }

sig="$(printf '%s' "${status_json}" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(((d.get("status") or {}).get("booted") or {}).get("image",{}).get("image",{}).get("signature") or "")
except Exception:
    print("")
' 2>/dev/null)"

case "${sig}" in
    containerPolicy)
        note "OK: booted deployment verifies fetches against containers-policy.json."
        ;;
    insecure)
        problem "booted deployment signature mode is 'insecure'. NO SIGNATURE VERIFICATION IS HAPPENING on this machine, regardless of what /etc/containers/policy.json contains. This machine was installed without enforce-container-sigpolicy."
        ;;
    "")
        problem "could not read the booted deployment's signature mode from bootc status"
        ;;
    *)
        problem "unexpected signature mode '${sig}' (expected containerPolicy)"
        ;;
esac

# The policy file has to actually name our namespace. A policy whose only docker entry is the
# insecureAcceptAnything catch-all "enforces" nothing -- that is D8, verbatim.
POLICY=/etc/containers/policy.json
if [[ -r "${POLICY}" ]]; then
    python3 - "${POLICY}" <<'PY' || problem "policy.json does not carry a sigstoreSigned rule for our namespace (see D8)"
import json,sys
p=json.load(open(sys.argv[1]))
dflt=[r.get("type") for r in p.get("default",[])]
if "insecureAcceptAnything" in dflt:
    print("PROBLEM: policy.json global default is insecureAcceptAnything", file=sys.stderr); sys.exit(1)
docker=(p.get("transports") or {}).get("docker") or {}
scoped=[s for s,rs in docker.items() if s and any(r.get("type")=="sigstoreSigned" for r in rs)]
if not scoped:
    print("PROBLEM: no scoped sigstoreSigned entry under transports.docker", file=sys.stderr); sys.exit(1)
print("OK: sigstoreSigned scopes in policy.json: " + ", ".join(sorted(scoped)))
PY
else
    problem "${POLICY} is missing"
fi

exit "${warn_out}"

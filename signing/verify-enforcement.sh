#!/usr/bin/bash
#
# verify-enforcement.sh -- CHECK U4.
#
#   "offered an unsigned or wrongly-signed image, `bootc upgrade` exits non-zero and the booted
#    digest is UNCHANGED"
#
# Runs ON the machine under test, from inside the image, installed at
# /usr/libexec/auros/verify-enforcement.sh. Emits a JSON summary on stdout for the harness and
# human-readable reasoning on stderr.
#
# ---------------------------------------------------------------------------------------------
# THE THING THIS SCRIPT EXISTS TO NOT DO
# ---------------------------------------------------------------------------------------------
# "We offered it a bad image and it said no" is also what a completely broken machine says. It is
# what you get if the public key is missing, if signedIdentity is wrong, if registries.d never
# enabled sigstore attachments, if the registry is unreachable, or if the policy file does not
# parse. Every one of those makes the machine refuse the GOOD image too, and every one of them
# produces a green U4 if U4 only tests the negative.
#
# So this script is structured as: preconditions, then a POSITIVE CONTROL, then the negatives.
# A failed precondition or a failed positive control exits 2 = INCONCLUSIVE. It is never "pass".
# The gate must treat INCONCLUSIVE as a failure -- matrix/README.md already says skip is not
# pass, and this is the same rule.
#
# Exit codes:  0 = U4 PASS   1 = U4 FAIL   2 = INCONCLUSIVE (treat as fail)
#
# ---------------------------------------------------------------------------------------------
# SAFETY
# ---------------------------------------------------------------------------------------------
# Step 5 asks bootc to switch to an image that must be refused. If the refusal ever stopped
# working, that is a real mutation of a real machine. It is therefore gated on a marker file the
# check-matrix harness creates, or an explicit flag. Absence of the marker exits 2 with a loud
# message -- it does NOT silently skip, because a check that skips itself is the failure mode
# this file is written to prevent.

set -uo pipefail

MARKER=/run/auros-check-matrix
CONF=/etc/auros/signing
POLICY=/etc/containers/policy.json
KEY=/usr/lib/pki/containers/auros.pub
REGD=/etc/containers/registries.d

# ---------------------------------------------------------------------------------------------
# WHICH IMAGES TO OFFER
# ---------------------------------------------------------------------------------------------
# PREFER the images the check matrix already builds. matrix/run/run-update.sh derives signed and
# unsigned variants of the REAL base and serves them under the production reference string
# (ghcr.io/<org>/auros-base@sha256:...), which is the only way the scoped sigstoreSigned rule
# applies at all -- an image served from 10.0.2.x:5000 would fall through the catch-all and
# "refused an unsigned image" would mean nothing. That reasoning is already written down at the
# top of run-update.sh and this script does not second-guess it.
#
# So the harness passes the refs in:
#   verify-enforcement.sh --signed REF --unsigned REF [--wrongkey REF]
#
# The canary tags are a FALLBACK for running this standalone, outside the matrix. They are not the
# preferred path and CI need not build them if the harness supplies refs.
REF_SIGNED=""; REF_UNSIGNED=""; REF_WRONGKEY=""
allow_mutation=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signed)   REF_SIGNED="$2";   shift 2 ;;
        --unsigned) REF_UNSIGNED="$2"; shift 2 ;;
        --wrongkey) REF_WRONGKEY="$2"; shift 2 ;;
        --i-am-a-disposable-test-vm) allow_mutation=1; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

CANARY_REPO_DEFAULT=""
[[ -r "${CONF}/canary-repo" ]] && CANARY_REPO_DEFAULT="$(cat "${CONF}/canary-repo")"
CANARY_REPO="${AUROS_CANARY_REPO:-${CANARY_REPO_DEFAULT}}"
SCOPE_DEFAULT=""
[[ -r "${CONF}/scope" ]] && SCOPE_DEFAULT="$(cat "${CONF}/scope")"
SCOPE="${AUROS_SCOPE:-${SCOPE_DEFAULT}}"

if [[ -n "${CANARY_REPO}" ]]; then
    [[ -n "${REF_SIGNED}"   ]] || REF_SIGNED="${CANARY_REPO}:signed"
    [[ -n "${REF_UNSIGNED}" ]] || REF_UNSIGNED="${CANARY_REPO}:unsigned"
    [[ -n "${REF_WRONGKEY}" ]] || REF_WRONGKEY="${CANARY_REPO}:wrongkey"
fi

[[ -e "${MARKER}" ]] && allow_mutation=1

say()  { printf '%s\n' "$*" >&2; }
head_() { printf '\n== %s ==\n' "$*" >&2; }

RESULTS=()
WRONGKEY_INCONCLUSIVE=0
record() { RESULTS+=("{\"step\":\"$1\",\"status\":\"$2\",\"detail\":$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}"); }

emit() {
    local verdict="$1"
    printf '{"check":"U4","verdict":"%s","booted_digest_before":"%s","booted_digest_after":"%s","steps":[%s]}\n' \
        "${verdict}" "${DIGEST_BEFORE:-}" "${DIGEST_AFTER:-}" "$(IFS=,; echo "${RESULTS[*]:-}")"
}

inconclusive() { say "INCONCLUSIVE: $*"; record "abort" "inconclusive" "$*"; emit inconclusive; exit 2; }
failed()       { say "U4 FAIL: $*";      record "verdict" "fail" "$*";      emit fail;         exit 1; }

bootc_json() { bootc status --json 2>/dev/null; }
booted_digest() { bootc_json | python3 -c '
import json,sys
try: print(((json.load(sys.stdin).get("status") or {}).get("booted") or {}).get("image",{}).get("imageDigest") or "")
except Exception: print("")
' 2>/dev/null; }
staged_digest() { bootc_json | python3 -c '
import json,sys
try: print(((json.load(sys.stdin).get("status") or {}).get("staged") or {}).get("image",{}).get("imageDigest") or "")
except Exception: print("")
' 2>/dev/null; }
spec_image() { bootc_json | python3 -c '
import json,sys
try: print(((json.load(sys.stdin).get("spec") or {}).get("image") or {}).get("image") or "")
except Exception: print("")
' 2>/dev/null; }

# =============================================================================================
head_ "0. Preconditions -- any failure here is INCONCLUSIVE, never a pass"
# =============================================================================================

[[ "$(id -u)" == "0" ]] || inconclusive "must run as root"
command -v bootc   >/dev/null 2>&1 || inconclusive "bootc is not installed"
command -v python3 >/dev/null 2>&1 || inconclusive "python3 is not installed"

PULLER=""
if   command -v skopeo >/dev/null 2>&1; then PULLER=skopeo
elif command -v podman >/dev/null 2>&1; then PULLER=podman
else inconclusive "neither skopeo nor podman is present; the canary pulls cannot be performed"
fi
say "using ${PULLER} for the canary pulls"

[[ -n "${SCOPE}" ]] || inconclusive "no enforced scope known (${CONF}/scope missing and AUROS_SCOPE unset)"
say "enforced scope: ${SCOPE}"
[[ -n "${REF_SIGNED}"   ]] || inconclusive "no signed reference to test with. Pass --signed REF (the harness has one) or build the canary tags."
[[ -n "${REF_UNSIGNED}" ]] || inconclusive "no unsigned reference to test with. Pass --unsigned REF. Without a negative there is no U4 -- reporting inconclusive rather than passing on the strength of an absence."

# EVERY reference must sit inside the enforced scope. An unsigned image served from somewhere else
# falls through the transports.docker[""] catch-all, would be accepted for reasons that have
# nothing to do with our images, and "refused an unsigned image" would mean nothing at all. This is
# the same trap run-update.sh documents at its top, asserted here rather than assumed.
for ref in "${REF_SIGNED}" "${REF_UNSIGNED}" ${REF_WRONGKEY:+"${REF_WRONGKEY}"}; do
    case "${ref}" in
        "${SCOPE}"/*) ;;
        *) inconclusive "${ref} is NOT inside the enforced scope ${SCOPE}. It would be matched by the catch-all instead of our sigstoreSigned rule, and the result would prove nothing." ;;
    esac
done
say "signed:   ${REF_SIGNED}"
say "unsigned: ${REF_UNSIGNED}"
say "wrongkey: ${REF_WRONGKEY:-<not supplied -- step 3 will be reported inconclusive>}"

[[ -s "${KEY}" ]] || inconclusive "${KEY} is missing or empty"
grep -q 'BEGIN PUBLIC KEY' "${KEY}" || inconclusive "${KEY} does not look like a PEM public key"
record "key-present" "pass" "${KEY}"

[[ -r "${POLICY}" ]] || inconclusive "${POLICY} is unreadable"
policy_report="$(python3 - "${POLICY}" "${SCOPE}" <<'PY'
import json,sys
path,scope=sys.argv[1],sys.argv[2]
try: p=json.load(open(path))
except Exception as e:
    print("PARSE-ERROR %s" % e); sys.exit(3)
allowed={"default","transports"}
extra=set(p)-allowed
if extra:
    print("UNKNOWN-KEYS %s" % ",".join(sorted(extra))); sys.exit(3)
if any(r.get("type")=="insecureAcceptAnything" for r in p.get("default",[])):
    print("DEFAULT-INSECURE"); sys.exit(3)
docker=(p.get("transports") or {}).get("docker") or {}
rules=docker.get(scope)
if not rules:
    print("NO-SCOPED-RULE %s" % scope); sys.exit(3)
ss=[r for r in rules if r.get("type")=="sigstoreSigned"]
if not ss:
    print("SCOPE-NOT-SIGSTORESIGNED"); sys.exit(3)
r=ss[0]
si=(r.get("signedIdentity") or {}).get("type")
if si not in ("matchRepository","exactRepository"):
    print("BAD-SIGNEDIDENTITY %s" % si); sys.exit(3)
if not (r.get("keyPath") or r.get("keyPaths")):
    print("NO-KEYPATH"); sys.exit(3)
print("OK scope=%s signedIdentity=%s keyPath=%s catchall=%s" % (
    scope, si, r.get("keyPath") or r.get("keyPaths"),
    "present" if "" in docker else "absent"))
PY
)" || inconclusive "policy.json is not shaped the way D8 requires: ${policy_report}"
say "policy.json: ${policy_report}"
record "policy-shape" "pass" "${policy_report}"

regd_report="$(python3 - "${REGD}" "${SCOPE}" <<'PY'
import os,sys
try: import yaml
except ImportError: yaml=None
d,scope=sys.argv[1],sys.argv[2]
if yaml is None:
    # No PyYAML in the image; fall back to a textual assertion rather than pretending to parse.
    hit=False
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not f.endswith((".yaml",".yml")): continue
        t=open(os.path.join(d,f)).read()
        if scope in t and "use-sigstore-attachments" in t: hit=True
    print("OK-TEXTUAL" if hit else "NO-ATTACHMENTS-ENTRY"); sys.exit(0 if hit else 3)
scopes={}
for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if not f.endswith((".yaml",".yml")): continue
    y=yaml.safe_load(open(os.path.join(d,f))) or {}
    for s,cfg in (y.get("docker") or {}).items():
        if s in scopes:
            print("DUPLICATE-SCOPE %s in %s and %s" % (s,scopes[s],f)); sys.exit(3)
        scopes[s]=f
        if s==scope and not (cfg or {}).get("use-sigstore-attachments"):
            print("SCOPE-PRESENT-BUT-ATTACHMENTS-OFF"); sys.exit(3)
if scope not in scopes:
    print("NO-ENTRY-FOR %s" % scope); sys.exit(3)
# Anything MORE specific than our scope overrides it entirely (containers-registries.d(5):
# "only the configuration for the most-precisely matching scope is used").
more=[s for s in scopes if s!=scope and s.startswith(scope+"/")]
if more:
    print("OVERRIDDEN-BY-MORE-SPECIFIC %s" % ",".join(sorted(more))); sys.exit(3)
print("OK scope=%s file=%s" % (scope, scopes[scope]))
PY
)" || inconclusive "registries.d does not enable sigstore attachments for ${SCOPE}: ${regd_report}. Without it containers/image never looks for a signature, every pull of our images is refused, and the negative tests below would pass for the wrong reason."
say "registries.d: ${regd_report}"
record "registries.d" "pass" "${regd_report}"

sig_mode="$(bootc_json | python3 -c '
import json,sys
try: print(((json.load(sys.stdin).get("status") or {}).get("booted") or {}).get("image",{}).get("image",{}).get("signature") or "")
except Exception: print("")
' 2>/dev/null)"
[[ "${sig_mode}" == "containerPolicy" ]] || inconclusive \
  "booted deployment signature mode is '${sig_mode:-unreadable}', not containerPolicy. This machine does not consult containers-policy.json at all, so nothing below would be evidence of anything. It was installed without enforce-container-sigpolicy."
say "booted deployment verifies against containers-policy.json"
record "install-time-enforcement" "pass" "signature=containerPolicy"

DIGEST_BEFORE="$(booted_digest)"
SPEC_BEFORE="$(spec_image)"
[[ -n "${DIGEST_BEFORE}" ]] || inconclusive "could not read the booted digest"
say "booted digest before: ${DIGEST_BEFORE}"

# =============================================================================================
head_ "1. POSITIVE CONTROL -- the correctly signed canary must be ACCEPTED"
# =============================================================================================
# If this fails, every negative result below is worthless: a machine that refuses everything
# also refuses the bad image. This is the assertion that stops U4 passing vacuously.

try_pull() {
    # Must be an operation that ACTUALLY APPLIES the signature policy. `skopeo inspect` reads a
    # manifest and does not necessarily verify, which would make the unsigned canary look
    # accepted and report a false U4 failure. `copy` verifies. The canary is a few hundred
    # bytes, so copying it costs nothing.
    #
    # --policy is a skopeo GLOBAL flag and has to come before the subcommand.
    local ref="$1" out rc=0 dest
    dest="$(mktemp -d /tmp/auros-canary.XXXXXX)"
    case "${PULLER}" in
        skopeo) out="$(skopeo --policy "${POLICY}" copy "docker://${ref}" "dir:${dest}" 2>&1)" || rc=$? ;;
        podman) out="$(podman pull --signature-policy "${POLICY}" "${ref}" 2>&1)"              || rc=$? ;;
    esac
    rm -rf "${dest}"
    printf '%s' "${out}"
    return "${rc}"
}

if pos_out="$(try_pull "${REF_SIGNED}")"; then
    say "ACCEPTED, as required."
    record "positive-control" "pass" "${CANARY_REPO}:signed accepted"
else
    say "${pos_out}"
    inconclusive "the correctly signed image ${REF_SIGNED} was REFUSED. Enforcement is misconfigured, not strict. Likely causes, in order of likelihood: signedIdentity is not matchRepository; the image was signed with the new bundle format (cosign.lock: --new-bundle-format=false); registries.d attachments; wrong key. Nothing below is evidence until this passes."
fi

# =============================================================================================
head_ "2. NEGATIVE 1 -- an UNSIGNED image, inside our namespace, must be REFUSED"
# =============================================================================================
# This is the test for D8 itself. The unsigned canary sits inside ghcr.io/<ns>, which is covered
# both by our scoped sigstoreSigned rule and by the transports.docker[""] catch-all. If the
# catch-all wins, this is ACCEPTED and enforcement is theatre.

if neg_out="$(try_pull "${REF_UNSIGNED}")"; then
    say "${neg_out}"
    failed "an UNSIGNED image inside ${SCOPE} was ACCEPTED. The insecureAcceptAnything catch-all is winning over the scoped sigstoreSigned rule -- this is exactly the D8 failure, and signature enforcement on this image is doing nothing."
fi
say "refused, as required:"; say "${neg_out}"
record "negative-unsigned" "pass" "$(printf '%s' "${neg_out}" | tail -n2)"

# =============================================================================================
head_ "3. NEGATIVE 2 -- a WRONGLY signed image must be REFUSED"
# =============================================================================================
# Distinct from negative 1 and worth its own step: negative 1 only proves the machine wants *a*
# signature. This proves it checks WHICH key made it. A policy that accepted any valid sigstore
# signature would pass negative 1 and fail here, and anyone with a Fulcio certificate could then
# publish an image our fleet would install.

if [[ -z "${REF_WRONGKEY}" ]]; then
    say "no wrong-key reference supplied."
    say "This is NOT a pass. Step 2 only proves the machine wants *a* signature; without step 3 a"
    say "policy that accepted any valid sigstore signature would look identical, and anyone able to"
    say "sign anything could push an update to the fleet."
    record "negative-wrongkey" "inconclusive" "no --wrongkey reference supplied"
    say "(gate1-exit.yml covers this as U4b from the host side; if that is where it is being proven,"
    say " this step is still reported rather than silently omitted.)"
    WRONGKEY_INCONCLUSIVE=1
elif wrong_out="$(try_pull "${REF_WRONGKEY}")"; then
    say "${wrong_out}"
    failed "an image signed by a DIFFERENT key was ACCEPTED."
else
    say "refused, as required:"; say "${wrong_out}"
    record "negative-wrongkey" "pass" "$(printf '%s' "${wrong_out}" | tail -n2)"
fi

# =============================================================================================
head_ "4. The real thing -- bootc must refuse to deploy the unsigned image"
# =============================================================================================
# Steps 2 and 3 prove the policy engine refuses. This proves the UPDATE PATH refuses, which is
# what the spec's exit condition actually says: "intentionally break the base; the VM must refuse
# the update and stay on the old image."

if (( allow_mutation == 0 )); then
    inconclusive "steps 1-3 passed, but step 4 asks bootc to switch to an image that must be refused, and that is a mutation of a real machine. It is gated on ${MARKER} (created by the check-matrix harness) or the --i-am-a-disposable-test-vm flag. NOT SKIPPED -- reported as inconclusive, because U4 without step 4 is not U4."
fi

say "asking bootc to switch to ${REF_UNSIGNED} ..."
switch_rc=0
switch_out="$(bootc switch --retain "${REF_UNSIGNED}" 2>&1)" || switch_rc=$?
say "${switch_out}"

DIGEST_AFTER="$(booted_digest)"
STAGED_AFTER="$(staged_digest)"
SPEC_AFTER="$(spec_image)"

if (( switch_rc == 0 )); then
    failed "bootc switch to an unsigned image EXITED 0. The update path does not enforce signatures."
fi
say "bootc switch exited ${switch_rc}, as required."

[[ "${DIGEST_AFTER}" == "${DIGEST_BEFORE}" ]] || \
    failed "the booted digest CHANGED (${DIGEST_BEFORE} -> ${DIGEST_AFTER}) after a refused switch."

if [[ -n "${STAGED_AFTER}" ]]; then
    say "a deployment was staged despite the refusal; unstaging before reporting."
    bootc rollback >/dev/null 2>&1 || true
    failed "bootc refused the switch but left ${STAGED_AFTER} STAGED. The machine would have booted an unsigned image at the next restart."
fi

# `bootc switch` rewrites the spec image before it fetches in some versions; put it back so the
# VM is left usable for the remaining checks.
if [[ -n "${SPEC_BEFORE}" && "${SPEC_AFTER}" != "${SPEC_BEFORE}" ]]; then
    say "restoring spec image ${SPEC_AFTER} -> ${SPEC_BEFORE}"
    bootc switch --retain "${SPEC_BEFORE}" >/dev/null 2>&1 \
        || say "WARNING: could not restore the spec image; this VM should be discarded after the run."
fi

record "bootc-refuses" "pass" "rc=${switch_rc}, booted digest unchanged, nothing staged"

# Step 3 carries the same rule as every other step in this file: a step that did not run is not a
# step that passed. Claiming U4 while one of its two negatives was never attempted is exactly the
# vacuous pass this script is built to refuse -- so the summary below can only be printed when
# every step actually ran.
if (( WRONGKEY_INCONCLUSIVE == 1 )); then
    inconclusive "steps 1, 2 and 4 passed, but no wrong-key reference was offered, so 'the machine checks WHICH key signed the image' is UNPROVEN here. Re-run with --wrongkey REF, or score U4 from the host side where gate1-exit.yml covers it as U4b. Not reporting a pass on three quarters of the evidence."
fi

head_ "U4 PASS"
say "The machine accepted a correctly signed image, refused an unsigned one from inside its own"
say "enforced namespace, refused one signed by a foreign key, and refused to deploy any of them"
say "while staying on ${DIGEST_BEFORE}."
record "verdict" "pass" "U4 satisfied"
emit pass
exit 0

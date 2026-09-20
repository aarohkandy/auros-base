#!/usr/bin/bash
#
# 30-update-agent.sh -- the safety-critical layer of auros-base.
#
# Installs three things that are one thing:
#   A. the update agent      -- bootc's timer, greenboot, and the health checks that decide
#                               whether a boot was good enough to keep
#   B. signature enforcement -- D8: the key, registries.d, and a policy that actually verifies
#   C. the U4 harness        -- verify-enforcement.sh, in the image, so the check runs on the
#                               machine it is a claim about
#
# They are one script because they are one property: a machine that updates itself unattended is
# only safe if it can refuse a bad image and recover from a broken one. Either half alone is
# worse than neither.
#
# Idempotent. Every assertion is fail-closed: this script would rather fail the build than
# produce an image that looks configured and is not. That preference is the entire point of the
# file -- read D8 and note that the failure it describes is invisible from inside the image.
#
# Convention: run by ../Containerfile in numeric order; its input files were COPYed to
# /tmp/auros-build/ beforehand.

set -euo pipefail

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n!!! 30-update-agent.sh: %s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------
# AUROS_SCOPE is the registry namespace that signature enforcement applies to. D1 puts the
# namespace in exactly one file (auros.config.json) and has everything else derive from it, so
# this is passed in by the Containerfile as a build arg rather than hardcoded here. The default
# is the documented one; if the Containerfile does not pass it, a rename would silently leave
# this layer enforcing the old namespace, so we echo what we used.
AUROS_SCOPE="${AUROS_SCOPE:-ghcr.io/aarohkandy}"
AUROS_CANARY_REPO="${AUROS_CANARY_REPO:-${AUROS_SCOPE}/auros-canary}"

find_src() {
    local name="$1" c
    for c in "/tmp/auros-build/${name}" "/tmp/auros-build/auros-base/${name}" "/tmp/auros-build"; do
        [[ -d "${c}" ]] && { printf '%s' "${c}"; return 0; }
    done
    return 1
}
UA_SRC="$(find_src update-agent)" || die "cannot find update-agent/ under /tmp/auros-build"
SIGN_SRC="$(find_src signing)"    || die "cannot find signing/ under /tmp/auros-build"
[[ -d "${UA_SRC}/greenboot" ]]    || die "${UA_SRC} does not look like update-agent/ (no greenboot/)"
[[ -f "${SIGN_SRC}/policy.json" ]] || die "${SIGN_SRC} does not look like signing/ (no policy.json)"

say "30-update-agent.sh"
info "update-agent sources: ${UA_SRC}"
info "signing sources:      ${SIGN_SRC}"
info "enforced scope:       ${AUROS_SCOPE}"
info "canary repository:    ${AUROS_CANARY_REPO}"

DNF=dnf5; command -v dnf5 >/dev/null 2>&1 || DNF=dnf
command -v "${DNF}" >/dev/null 2>&1 || die "neither dnf5 nor dnf is available"

# =============================================================================================
say "A1. Assert the platform this layer depends on (D9)"
# =============================================================================================
# greenboot's rollback is implemented by a GRUB boot counter, wired through
# ostree-finalize-staged.service and bootupd's static GRUB config. On the composefs/UKI backend
# upstream has not wired boot-loader entry counting at all, so greenboot rollback DOES NOT WORK
# there. D9 makes staying on ostree + GRUB/bootupd a deliberate constraint rather than a default,
# and a constraint nobody asserts is a preference. These are the assertions.

command -v bootc >/dev/null 2>&1 || die "bootc is not in this image; this is not a bootc base"
info "bootc: $(bootc --version 2>/dev/null || echo present)"

[[ -f /usr/lib/systemd/system/ostree-finalize-staged.service ]] \
    || die "ostree-finalize-staged.service is absent. greenboot's greenboot-grub2-set-counter.service is RequiredBy that unit, so without it the boot counter is never set and auto-rollback (check U3) silently does not exist. If this base has moved to the composefs backend, D9 applies and that is a decision for the human, not something to work around here."
info "ostree-finalize-staged.service present -- ostree backend, boot counter can be staged"

[[ -d /usr/lib/bootupd/grub2-static ]] \
    || die "/usr/lib/bootupd/grub2-static is absent; bootupd's static GRUB config is what assembles greenboot's boot-counter fragment into /boot/grub2/grub.cfg at install time"
info "bootupd static GRUB config directory present"

# =============================================================================================
say "A2. Install greenboot -- NOT preinstalled on Aurora (D9)"
# =============================================================================================
# Verified absent from ublue-os/aurora, bluefin, main, and the Fedora bootc standard/minimal
# manifests; it ships only in the Fedora bootc IoT manifest. Auto-rollback is a headline safety
# property -- a school has one overworked IT person and no out-of-band console -- so this is an
# explicit install, not an assumption.
#
# We install `greenboot` and deliberately NOT `greenboot-default-health-checks`. That subpackage
# ships 01_repository_dns_check.sh as a REQUIRED check, which fails when DNS is unreachable. A
# required check that fails rolls the machine back. A school whose broadband drops overnight
# would find every laptop rolled back in the morning, and then rolled back again, which lands on
# the fallback deployment and needs a technician. U5 says an offline machine is a no-op. Our own
# 10-network-stack.sh asserts the network STACK, never connectivity, for exactly this reason.

if rpm -q greenboot >/dev/null 2>&1; then
    info "greenboot already installed: $(rpm -q greenboot)"
else
    "${DNF}" install -y greenboot || die "could not install greenboot"
    info "installed $(rpm -q greenboot)"
fi
rpm -q greenboot-default-health-checks >/dev/null 2>&1 \
    && info "NOTE: greenboot-default-health-checks is present (not installed by us). Its 01_repository_dns_check.sh is a REQUIRED check that fails when DNS is down -- review before shipping."

for f in /usr/libexec/greenboot/greenboot \
         /usr/libexec/greenboot/greenboot-grub2-set-counter \
         /usr/libexec/greenboot/redboot-auto-reboot \
         /usr/lib/systemd/system/greenboot-healthcheck.service \
         /usr/lib/systemd/system/greenboot-grub2-set-counter.service \
         /usr/lib/systemd/system/redboot-auto-reboot.service; do
    [[ -e "${f}" ]] || die "greenboot is installed but ${f} is missing; the package layout changed"
done

GB_FRAGMENT=/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg
[[ -f "${GB_FRAGMENT}" ]] \
    || die "${GB_FRAGMENT} is missing. bootupd concatenates every *.cfg in that directory into /boot/grub2/grub.cfg at install time; without this fragment GRUB has no boot_counter logic and auto-rollback does not happen, while every other part of greenboot looks correctly installed. This is precisely the kind of silent gap check U3 exists to catch -- fail here instead."
grep -q 'boot_counter' "${GB_FRAGMENT}" || die "${GB_FRAGMENT} exists but contains no boot_counter logic"
info "GRUB boot-counter fragment present and contains boot_counter"

# =============================================================================================
say "A3. Retry count -- make 'fails twice => rollback' literally what happens"
# =============================================================================================
# MEASURED SEMANTICS (greenboot-grub2-set-counter + grub2/08_greenboot.cfg, read 2026-09-20):
#
#   On staging an update, greenboot writes boot_counter=$GREENBOOT_MAX_BOOT_ATTEMPTS and
#   boot_success=0. On each boot, GRUB: if boot_counter is 0 or -1 -> set default=1, i.e. boot
#   the ROLLBACK deployment; otherwise decrement it.
#
#   So MAX=N gives the new image N attempts, and the rollback happens on boot N+1.
#
#   THE REAL UPSTREAM DEFAULT IS 3 -- three attempts at the new image, rollback on the fourth
#   boot. That is the documented default and it is what you get if this block is removed.
#
# Spec 6A says "rolls back automatically if the new image fails to reach a login prompt twice".
# Two attempts means GREENBOOT_MAX_BOOT_ATTEMPTS=2. Not 3, which would be three attempts, and
# not 1, which gives a single attempt and would roll a machine back over one unlucky boot.

CONF=/etc/greenboot/greenboot.conf
[[ -f "${CONF}" ]] || die "${CONF} is missing after installing greenboot"
# Idempotent: drop any uncommented setting, then append ours.
sed -i '/^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=/d' "${CONF}"
cat >> "${CONF}" <<'EOF'

# AUROS: spec 6A -- "rolls back automatically if the new image fails to reach a login prompt
# twice". Upstream's default is 3 (three attempts, rollback on the fourth boot). Two attempts is
# what "twice" means. Do not raise this without changing the sentence we sell.
GREENBOOT_MAX_BOOT_ATTEMPTS=2
EOF
n="$(grep -cE '^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=2$' "${CONF}")"
[[ "${n}" == "1" ]] || die "expected exactly one GREENBOOT_MAX_BOOT_ATTEMPTS=2 in ${CONF}, found ${n}"
grep -q 'DISABLED_HEALTHCHECKS=' "${CONF}" \
    || die "${CONF} no longer defines DISABLED_HEALTHCHECKS; greenboot sources this file under 'set -u' and expands that array unquoted-safe, so an undefined one breaks every health check"
info "GREENBOOT_MAX_BOOT_ATTEMPTS=2 (upstream default is 3)"

# =============================================================================================
say "A4. The update timer -- verified by name, not assumed"
# =============================================================================================
# MEASURED, and this is the finding that matters most in this section:
#
#   Aurora's systemd preset (system_files/shared/usr/lib/systemd/system-preset/89-aurora.preset)
#   enables `uupd.timer`, NOT bootc's own timer. uupd runs `bootc upgrade --quiet --progress-fd 3`
#   -- it STAGES and never reboots -- once a day at 04:00.
#
#   bootc's own bootc-fetch-apply-updates.timer IS in the image (it ships in the bootc RPM) but
#   is not preset-enabled, so it is inert.
#
# If we had assumed bootc's timer was running, this image would stage updates and never apply
# them, U1 would fail, and the cause would look like a bootc bug rather than a preset.
#
# We enable bootc's timer and override its ExecStart. We leave uupd.timer alone: it also updates
# Flatpaks, which is where the customer's applications live (spec 3), and its `bootc upgrade` is
# harmless -- bootc serialises on its own lock and auros-update exits clean when it loses.

TIMER_UNIT=/usr/lib/systemd/system/bootc-fetch-apply-updates.timer
SVC_UNIT=/usr/lib/systemd/system/bootc-fetch-apply-updates.service
[[ -f "${TIMER_UNIT}" && -f "${SVC_UNIT}" ]] || die \
"bootc-fetch-apply-updates.{timer,service} are not at /usr/lib/systemd/system/. bootc has renamed
 or moved its update unit. DO NOT guess a replacement: our drop-ins would attach to nothing and
 the image would ship with no update path at all, which check S10 would catch only if it also
 learned the new name. Find the current unit, update this script and the greenboot check
 30-update-timer-enabled.sh together, and record it in DECISIONS.md."
info "vendor units present: bootc-fetch-apply-updates.{timer,service}"
grep -q 'bootc upgrade' "${SVC_UNIT}" || die "${SVC_UNIT} no longer runs 'bootc upgrade'; re-read it before overriding"

install -d -m 0755 /usr/libexec/auros
install -D -m 0755 "${UA_SRC}/libexec/auros-update" /usr/libexec/auros/auros-update
info "installed /usr/libexec/auros/auros-update"

for d in bootc-fetch-apply-updates.service.d bootc-fetch-apply-updates.timer.d greenboot-healthcheck.service.d; do
    [[ -d "${UA_SRC}/systemd/${d}" ]] || die "missing drop-in source ${UA_SRC}/systemd/${d}"
    install -d -m 0755 "/usr/lib/systemd/system/${d}"
    install -D -m 0644 "${UA_SRC}/systemd/${d}/"*.conf "/usr/lib/systemd/system/${d}/"
    info "drop-in: /usr/lib/systemd/system/${d}/"
done
grep -q '^ExecStart=$' /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-auros.conf \
    || die "the service drop-in does not clear ExecStart first; systemd would APPEND our command to bootc's and the machine would run both"

# =============================================================================================
say "A5. Health checks"
# =============================================================================================
# greenboot's runner globs '*.sh' and sorts by name; required.d runs in STRICT mode, so the first
# failure stops the rest. The numeric prefixes are that order, cheapest and most fundamental
# first. /etc/greenboot is where greenboot looks and where a site can add its own; in a bootc
# image /etc is three-way merged on upgrade, so image-provided files here keep tracking the image
# on machines that have not edited them.

for dir in check/required.d check/wanted.d green.d red.d; do
    install -d -m 0755 "/etc/greenboot/${dir}"
    shopt -s nullglob
    files=( "${UA_SRC}/greenboot/${dir}/"*.sh )
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || die "no scripts found in ${UA_SRC}/greenboot/${dir}"
    for f in "${files[@]}"; do
        bash -n "${f}" || die "${f} is not valid bash"
        install -D -m 0755 "${f}" "/etc/greenboot/${dir}/$(basename "${f}")"
        info "greenboot ${dir}/$(basename "${f}")"
    done
done

install -d -m 0755 /etc/auros/update-agent
install -D -m 0644 "${UA_SRC}/etc/auros/update-agent/failed-units.ignore" /etc/auros/update-agent/failed-units.ignore
install -D -m 0644 "${UA_SRC}/etc/auros/update-agent/apply-policy"        /etc/auros/update-agent/apply-policy
install -D -m 0644 "${UA_SRC}/tmpfiles/auros-update-agent.conf"           /usr/lib/tmpfiles.d/auros-update-agent.conf
info "state dir declared via tmpfiles (NOT mkdir'd: /var in a Containerfile is only a first-boot default)"

# Sanity: the required checks must be exactly the four we reason about in the README. A fifth
# one appearing without the README changing means somebody added a rollback trigger silently.
req_count="$(find /etc/greenboot/check/required.d -name '*.sh' | wc -l | tr -d ' ')"
[[ "${req_count}" == "4" ]] || die "expected 4 required health checks, found ${req_count}. Every required check is a rollback trigger; adding one is a safety decision and belongs in update-agent/README.md and DECISIONS.md, not in a quiet commit."
info "4 required checks, 3 wanted checks"

# =============================================================================================
say "B1. Signature enforcement -- D8"
# =============================================================================================
# Deriving from Aurora gives us NOTHING here. The base policy ends in a docker
# "": [{"type":"insecureAcceptAnything"}] catch-all, so `bootc switch
# --enforce-container-sigpolicy` succeeds while verifying nothing. Everything below ships INSIDE
# the image because a customer's laptop has no other source for it.

KEY_SRC="${SIGN_SRC}/keys/auros.pub"
[[ -s "${KEY_SRC}" ]] || die \
"signing/keys/auros.pub is missing or empty.

 This build is REFUSED rather than completed, on purpose. An image built without the public key
 would carry a policy that references /usr/lib/pki/containers/auros.pub, find nothing there, and
 refuse every update for the rest of the machine's life -- in a school, months later, with no
 terminal and no out-of-band console. Spec 3: an unsigned or untested image can never reach a
 customer; a build that cannot verify signatures should not produce an image at all.

 Generating the key pair is a human action -- it mints a long-lived organisational credential.
 See auros-base/signing/keys/README.md."
grep -q 'BEGIN PUBLIC KEY' "${KEY_SRC}" || die "${KEY_SRC} is not a PEM public key"
grep -q 'BEGIN .*PRIVATE KEY' "${KEY_SRC}" && die "${KEY_SRC} contains a PRIVATE key. Refusing to bake a private key into an image that ships to customers."

install -d -m 0755 /usr/lib/pki/containers
install -D -m 0644 "${KEY_SRC}" /usr/lib/pki/containers/auros.pub
info "public key -> /usr/lib/pki/containers/auros.pub (immutable /usr, not /etc)"

# --- policy.json -----------------------------------------------------------------------------
install -d -m 0755 /etc/containers
sed "s|@AUROS_SCOPE@|${AUROS_SCOPE}|g" "${SIGN_SRC}/policy.json" > /etc/containers/policy.json
chmod 0644 /etc/containers/policy.json

# containers/image parses this with ParanoidUnmarshalJSONObject, which errors on ANY unrecognised
# key -- including a "$comment". A policy that fails to load is a machine that cannot pull
# anything, including its own updates. Re-implement that strictness here so it is caught in CI.
python3 - /etc/containers/policy.json "${AUROS_SCOPE}" <<'PY' || die "policy.json failed validation"
import json,sys
path,scope=sys.argv[1],sys.argv[2]
p=json.load(open(path))
extra=set(p)-{"default","transports"}
assert not extra, "unknown top-level keys %s (containers/image rejects these, it does not ignore them)" % sorted(extra)
assert p.get("default"), "no global default"
assert not any(r.get("type")=="insecureAcceptAnything" for r in p["default"]), \
    "global default is insecureAcceptAnything; bootc's enforce-container-sigpolicy guard reads the GLOBAL DEFAULT ONLY and would reject this"
docker=(p.get("transports") or {}).get("docker") or {}
rules=docker.get(scope)
assert rules, "no transports.docker entry for %s -- this is the D8 failure reproduced in our own file" % scope
ss=[r for r in rules if r.get("type")=="sigstoreSigned"]
assert ss, "the %s entry is not sigstoreSigned" % scope
r=ss[0]
assert (r.get("signedIdentity") or {}).get("type") in ("matchRepository","exactRepository"), \
    "signedIdentity must be matchRepository/exactRepository; cosign signatures carry only a repository and the default matchExact would reject EVERY signature we make"
kp=r.get("keyPath") or (r.get("keyPaths") or [None])[0]
assert kp=="/usr/lib/pki/containers/auros.pub", "unexpected keyPath %r" % kp
for req in (r for rs in docker.values() for r in rs):
    assert set(req)<= {"type","keyPath","keyPaths","keyData","keyDatas","fulcio","pki",
                       "rekorPublicKeyPath","rekorPublicKeyPaths","rekorPublicKeyData",
                       "rekorPublicKeyDatas","signedIdentity"}, "unknown requirement key in %r" % req
print("    policy.json OK: %s -> sigstoreSigned(%s), catch-all %s" % (
    scope, kp, "present for other registries" if "" in docker else "absent"))
PY

# --- registries.d ----------------------------------------------------------------------------
# Without this the sigstoreSigned rule is inert: containers/image never looks for an attachment,
# finds no signature, and refuses every pull of our own images.
install -d -m 0755 /etc/containers/registries.d
sed "s|@AUROS_SCOPE@|${AUROS_SCOPE}|g" "${SIGN_SRC}/registries.d/auros.yaml" > /etc/containers/registries.d/auros.yaml
chmod 0644 /etc/containers/registries.d/auros.yaml

# Two rules from containers-registries.d(5) that silently disable us if violated:
#   1. only the MOST-PRECISELY matching scope is used -- anything more specific hides ours
#   2. at most one instance of any key under `docker` ACROSS ALL FILES -- a duplicate is an error
for other in /etc/containers/registries.d/*.yaml /etc/containers/registries.d/*.yml; do
    [[ -e "${other}" ]] || continue
    [[ "${other}" == /etc/containers/registries.d/auros.yaml ]] && continue
    if grep -qE "^[[:space:]]*['\"]?${AUROS_SCOPE}['\"]?:" "${other}"; then
        die "${other} also defines the scope ${AUROS_SCOPE}. containers-registries.d(5) forbids the same key in two files and the merge will fail."
    fi
    if grep -qE "^[[:space:]]*['\"]?${AUROS_SCOPE}/" "${other}"; then
        die "${other} defines a scope MORE SPECIFIC than ${AUROS_SCOPE}. Only the most-precisely matching scope is used, so our use-sigstore-attachments setting would be ignored entirely and signature verification would quietly stop working."
    fi
done
info "registries.d: use-sigstore-attachments enabled for ${AUROS_SCOPE}, no conflicting scope"

# --- install-time enforcement ----------------------------------------------------------------
install -d -m 0755 /usr/lib/bootc/install
install -D -m 0644 "${SIGN_SRC}/install/30-auros.toml" /usr/lib/bootc/install/30-auros.toml
grep -q '^enforce-container-sigpolicy[[:space:]]*=[[:space:]]*true' /usr/lib/bootc/install/30-auros.toml \
    || die "30-auros.toml does not set enforce-container-sigpolicy = true; without it bootc records the deployment as signature mode 'insecure' and NOTHING is verified, however correct policy.json looks"
info "install config: enforce-container-sigpolicy = true (merged after Aurora's 20-aurora.toml)"

# =============================================================================================
say "C. The U4 harness, in the image"
# =============================================================================================
install -D -m 0755 "${SIGN_SRC}/verify-enforcement.sh" /usr/libexec/auros/verify-enforcement.sh
install -d -m 0755 /etc/auros/signing
printf '%s\n' "${AUROS_SCOPE}"       > /etc/auros/signing/scope
printf '%s\n' "${AUROS_CANARY_REPO}" > /etc/auros/signing/canary-repo
chmod 0644 /etc/auros/signing/scope /etc/auros/signing/canary-repo
info "check U4 -> /usr/libexec/auros/verify-enforcement.sh"
info "  scope=${AUROS_SCOPE} canary=${AUROS_CANARY_REPO}"

# =============================================================================================
say "D. Enable the units -- Fedora's default preset is 'disable', so this is NOT automatic"
# =============================================================================================
# greenboot ships no preset file of its own. On Fedora the trailing preset rule is `disable *`,
# so %systemd_post leaves every greenboot unit DISABLED. An image with greenboot installed and
# not enabled has all the files, passes a naive "is greenboot installed" check, and performs no
# health checks and no rollback whatsoever. This block is the difference between U3 working and
# U3 being a story we tell.

UNITS=(
    bootc-fetch-apply-updates.timer
    greenboot-healthcheck.service
    greenboot-task-runner.service
    greenboot-status.service
    greenboot-grub2-set-counter.service
    greenboot-grub2-set-success.service
    greenboot-rpm-ostree-grub2-check-fallback.service
    redboot-auto-reboot.service
    redboot-task-runner.service
)
for u in "${UNITS[@]}"; do
    [[ -f "/usr/lib/systemd/system/${u}" ]] || die "unit ${u} does not exist in this image"
    systemctl enable "${u}" >/dev/null 2>&1 || die "could not enable ${u}"
    info "enabled ${u}"
done

# Assert the enablement symlinks are really there. `systemctl enable` in a container can no-op
# for a unit with no [Install] section and still exit 0.
check_link() {
    local want="$1"
    compgen -G "${want}" >/dev/null || die "expected enablement symlink ${want} was not created"
}
check_link '/etc/systemd/system/timers.target.wants/bootc-fetch-apply-updates.timer'
check_link '/etc/systemd/system/multi-user.target.wants/greenboot-healthcheck.service'
check_link '/etc/systemd/system/boot-complete.target.requires/greenboot-healthcheck.service'
check_link '/etc/systemd/system/ostree-finalize-staged.service.requires/greenboot-grub2-set-counter.service'
check_link '/etc/systemd/system/redboot.target.wants/redboot-auto-reboot.service'
info "enablement symlinks verified -- including set-counter wired into ostree-finalize-staged (D9)"

# =============================================================================================
say "Summary"
# =============================================================================================
cat <<EOF
    update path      bootc-fetch-apply-updates.timer (bootc's own unit, enabled by us;
                     Aurora preset-enables uupd.timer instead and leaves this one inert)
                     boot+3min, then every 6h, 10min jitter -- U1's 20-minute window vs B6's
                     shared-uplink thundering herd
    apply rule       always stage; reboot only when no active user session (apply-policy=when-idle)
    rollback         greenboot + GRUB boot_counter, GREENBOOT_MAX_BOOT_ATTEMPTS=2
                     => two failed boots, rollback on the third. Upstream default is 3.
                     Exactly ONE rollback deployment is retained (D10).
    health checks    4 required (network stack, graphical target, update timer, no new failed
                     units) + 3 wanted (signature enforcement, rollback wiring, update freshness)
    signing          key    /usr/lib/pki/containers/auros.pub
                     policy /etc/containers/policy.json  (default: reject; ${AUROS_SCOPE} sigstoreSigned)
                     regd   /etc/containers/registries.d/auros.yaml (use-sigstore-attachments)
                     install /usr/lib/bootc/install/30-auros.toml (enforce-container-sigpolicy)
    check U4         /usr/libexec/auros/verify-enforcement.sh
EOF
say "30-update-agent.sh done"

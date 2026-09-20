#!/usr/bin/env bash
# run-update.sh — U1..U5 and R1. If only one part of this harness survives, keep this one.
#
# THE IDEA THAT MAKES IT REAL:
# A local registry serving images under a scope the guest does not trust would make U4 pass vacuously —
# the guest's policy.json is scoped to ghcr.io/<org>, so an image at 10.0.2.x:5000/... would fall
# straight through Aurora's inherited `"": insecureAcceptAnything` catch-all and "refused an unsigned
# image" would mean nothing at all (D8). So the guest is pointed at the harness's registry BY NAME:
# /etc/hosts maps ghcr.io to a guestfwd address, and registries.conf marks ghcr.io insecure so the
# plain-HTTP transport works. The reference string the guest sees is still
# ghcr.io/<org>/auros-base@sha256:..., so the sigstoreSigned rule applies and U4 tests the real thing.
# Marking a registry insecure changes the TRANSPORT. It does not change the SIGNATURE POLICY, which is
# pure crypto over the manifest. That distinction is the whole reason this test is worth running.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$HARNESS_DIR/lib/vm.sh"

IMAGE=''; PROFILE='uefi-modern'; POLICY='open'; RECIPE=''; SIGNING_KEY=''; PUBKEY=''
TEST_USER=auros; TEST_PASSWORD=auros; AUTOLOGIN=1
REG_PORT=5000; GUEST_REG_IP=10.0.2.100; MIGRATION_DIR=''

usage() { cat >&2 <<'USAGE'
usage: run-update.sh --image REF --signing-key KEY [options]
  --image REF          the image under test (the "old" image the VM starts on)
  --signing-key PATH   cosign PRIVATE key used to sign the test images. Its public half must be the
                       key the image ships under /usr/lib/pki/containers/, or the guest will refuse
                       every image and U1 will fail for the wrong reason.
  --pubkey PATH        public half (default: derived from the image's own pki directory)
  --profile ID         profile to run the update group on (default uefi-modern)
  --policy MODE        open|managed|locked|kiosk
  --recipe NAME
  --migration-dir DIR  files to stage as a migration archive for R1 (default: synthetic)
  --out DIR
env: COSIGN_PASSWORD must be set for a password-protected key.
USAGE
exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2;;
    --signing-key) SIGNING_KEY=$2; shift 2;;
    --pubkey) PUBKEY=$2; shift 2;;
    --profile) PROFILE=$2; shift 2;;
    --policy) POLICY=$2; shift 2;;
    --recipe) RECIPE=$2; shift 2;;
    --migration-dir) MIGRATION_DIR=$2; shift 2;;
    --out) AUROS_RUN_DIR=$2; shift 2;;
    -h|--help) usage;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$IMAGE" ] || usage
export AUROS_RUN_DIR TEST_USER TEST_PASSWORD AUTOLOGIN
mkdir -p "$AUROS_RUN_DIR/checks" "$AUROS_RUN_DIR/logs" "$AUROS_RUN_DIR/work"
CHECKS_FILE="$AUROS_RUN_DIR/checks/update.jsonl"; : > "$CHECKS_FILE"
L="$AUROS_RUN_DIR/logs"; W="$AUROS_RUN_DIR/work"
need podman; need qemu-system-x86_64; need node

fail_all() {
  local why=$1 id
  for id in U1 U2 U3 U4 U5 R1; do
    grep -q "\"id\":\"$id\"" "$CHECKS_FILE" 2>/dev/null || { check_begin; record "$id" fail "$why"; }
  done
  exit 1
}

ACCEL=$(accel_mode)
[ "$ACCEL" = kvm ] || [ "$AUROS_ALLOW_TCG" = 1 ] || fail_all "no writable /dev/kvm and AUROS_ALLOW_TCG is unset; the update group involves four boots and would take hours under emulation"
have cosign || fail_all "cosign is not installed. U4 is the only check that proves signing works, and it cannot be run without a signer. cosign is NOT preinstalled on ubuntu-latest; the workflow must add it, pinned (D17)."
[ -n "$SIGNING_KEY" ] || fail_all "no --signing-key. Without one the harness can only offer unsigned images, which would let U4 pass while U1 fails — the exact opposite of proving anything."

# ── the namespace the guest trusts ───────────────────────────────────────────────────────────────
CFG="$META_REPO/auros.config.json"
BASE_IMAGE=$(node -e 'const c=require(process.argv[1]);process.stdout.write(c.baseImage)' "$CFG" 2>/dev/null || echo 'ghcr.io/aarohkandy/auros-base')
REG_HOST=${BASE_IMAGE%%/*}                 # ghcr.io
REPO_PATH=${BASE_IMAGE#*/}                 # aarohkandy/auros-base
TAG=${AUROS_UPDATE_TAG:-matrix}
log "update group · profile=${PROFILE} · guest will see ${BASE_IMAGE}:${TAG} served from the harness"

# The image must ship the key we are about to sign with, or nothing below means anything.
if [ -z "$PUBKEY" ]; then
  KP=$(podman run --rm --network=none --entrypoint= "$IMAGE" sh -c 'ls -1 /usr/lib/pki/containers/ 2>/dev/null | head -1' || true)
  if [ -n "$KP" ]; then
    podman run --rm --network=none --entrypoint= "$IMAGE" cat "/usr/lib/pki/containers/$KP" > "$W/image.pub" 2>/dev/null || true
    [ -s "$W/image.pub" ] && PUBKEY="$W/image.pub"
  fi
fi
if [ -n "$PUBKEY" ]; then
  cosign public-key --key "$SIGNING_KEY" > "$W/signing.pub" 2>/dev/null || true
  if [ -s "$W/signing.pub" ] && ! diff -q <(tr -d ' \n' < "$W/signing.pub") <(tr -d ' \n' < "$PUBKEY") >/dev/null 2>&1; then
    fail_all "the signing key does not match the public key the image ships at /usr/lib/pki/containers/. Every image the harness offers would be refused, U1 would fail and U4 would 'pass' for a reason that has nothing to do with the check."
  fi
else
  warn "the image ships no key under /usr/lib/pki/containers/ — D8 says it must. S10 will have already failed; the update group continues so the failure is visible in both places."
fi

# ── a registry on the host, addressed by the name the policy is scoped to ────────────────────────
REG_CT="auros-matrix-registry-$$"
start_registry() {
  podman rm -f "$REG_CT" >/dev/null 2>&1 || true
  podman run -d --name "$REG_CT" -p "127.0.0.1:${REG_PORT}:5000" "${REGISTRY_IMAGE:-docker.io/library/registry:2}" >/dev/null 2>&1 \
    || return 1
  poll_until 60 "local registry" -- bash -c 'curl -fsS "http://127.0.0.1:'"$REG_PORT"'/v2/" -o /dev/null' || return 1
}
stop_registry() { podman rm -f "$REG_CT" >/dev/null 2>&1 || true; }
trap 'stop_vm; stop_swtpm "$PROFILE"; stop_registry' EXIT
start_registry || fail_all "could not start a local registry container (docker.io/library/registry:2)"

DEST_OPTS=(--dest-tls-verify=false)
push_as() {  # push_as <local image> <tag> ; echoes the pushed digest
  local img=$1 tag=$2
  skopeo copy "${DEST_OPTS[@]}" "containers-storage:$img" "docker://127.0.0.1:${REG_PORT}/${REPO_PATH}:${tag}" >>"$L/registry.log" 2>&1 || return 1
  skopeo inspect --tls-verify=false --no-tags "docker://127.0.0.1:${REG_PORT}/${REPO_PATH}:${tag}" 2>/dev/null \
    | sed -n 's/.*"Digest": *"\(sha256:[a-f0-9]\{64\}\)".*/\1/p' | head -1
}
sign_digest() {  # sign_digest <digest>
  # --new-bundle-format=false keeps the signature discoverable by containers/image (D17, and the whole
  # reason check S8 has two halves).
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign --yes --tlog-upload=false --new-bundle-format=false \
    --key "$SIGNING_KEY" --allow-insecure-registry \
    "127.0.0.1:${REG_PORT}/${REPO_PATH}@${1}" >>"$L/cosign.log" 2>&1
}

# ── three images: A (old), B (the update), C (the one whose greenboot check fails), D (unsigned) ──
log "building the update images"
mk_variant() { # mk_variant <tag> <dockerfile-body-file>
  local tag=$1 body=$2 ctx="$W/variant-$tag"
  rm -rf "$ctx"; mkdir -p "$ctx"; cp "$body" "$ctx/Containerfile"
  podman build --build-arg "BASE=$IMAGE" -t "localhost/auros-matrix-$tag:test" "$ctx" >>"$L/variants.log" 2>&1
}
cat > "$W/df-b" <<'EOF'
ARG BASE
FROM ${BASE}
# The smallest possible change: a marker file. U1 is about whether an update ARRIVES unattended, not
# about what the update contains.
RUN echo "auros-matrix-update-B" > /etc/auros-matrix-generation
EOF
cat > "$W/df-c" <<'EOF'
ARG BASE
FROM ${BASE}
# An image that boots but fails its health check. This is the only honest way to test U3: greenboot's
# required.d is the mechanism a real failing update would trip, so we trip it deliberately.
RUN echo "auros-matrix-update-C" > /etc/auros-matrix-generation && \
    mkdir -p /etc/greenboot/check/required.d && \
    printf '#!/bin/sh\necho "auros-matrix: deliberate greenboot failure (U3)"\nexit 1\n' \
      > /etc/greenboot/check/required.d/99-auros-matrix-fail.sh && \
    chmod +x /etc/greenboot/check/required.d/99-auros-matrix-fail.sh
EOF
cat > "$W/df-d" <<'EOF'
ARG BASE
FROM ${BASE}
RUN echo "auros-matrix-update-D-UNSIGNED" > /etc/auros-matrix-generation
EOF
mk_variant b "$W/df-b" || fail_all "could not build update image B"
mk_variant c "$W/df-c" || fail_all "could not build update image C"
mk_variant d "$W/df-d" || fail_all "could not build update image D"

# ── the wrapper the VM actually boots ────────────────────────────────────────────────────────────
OVL="$W/update-overlay"; rm -rf "$OVL"
mkdir -p "$OVL/etc/containers/registries.conf.d" "$OVL/etc/systemd/system/bootc-fetch-apply-updates.timer.d" "$OVL/etc"
cat > "$OVL/etc/containers/registries.conf.d/99-auros-matrix.conf" <<EOF
# HARNESS ONLY. Points the guest at the check-matrix registry over plain HTTP while keeping the
# reference string — and therefore the signature policy scope — identical to production.
[[registry]]
location = "${REG_HOST}"
insecure = true
EOF
cat > "$OVL/etc/systemd/system/bootc-fetch-apply-updates.timer.d/10-auros-matrix.conf" <<'EOF'
# HARNESS ONLY. Compresses the interval; it does not trigger anything by hand. What U1 proves is that
# the machine updates itself with no human action. What it does not prove is the production interval.
[Timer]
OnBootSec=60s
OnUnitActiveSec=90s
RandomizedDelaySec=0
EOF
mkdir -p "$OVL/usr/lib/systemd/system"
cat > "$OVL/usr/lib/systemd/system/auros-matrix-hosts.service" <<EOF
[Unit]
Description=Auros matrix: point ${REG_HOST} at the harness registry
Before=bootc-fetch-apply-updates.service network-online.target
DefaultDependencies=no
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'grep -q "${REG_HOST}" /etc/hosts || echo "${GUEST_REG_IP} ${REG_HOST}" >> /etc/hosts'
[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$OVL/usr/lib/systemd/system/sysinit.target.wants"
ln -sf ../auros-matrix-hosts.service "$OVL/usr/lib/systemd/system/sysinit.target.wants/auros-matrix-hosts.service"

cat > "$W/config.env" <<CFG
TEST_USER=${TEST_USER}
POLICY_MODE=${POLICY}
SUSPEND_TEST=0
FULL_BOOTS=0
CFG

# R1: the migration archive, on its own disk, exactly as auros-installer is documented to stage it.
MIG_IMG="$W/migration.qcow2"
if [ -z "$MIGRATION_DIR" ]; then
  MIGRATION_DIR="$W/migration-src"; rm -rf "$MIGRATION_DIR"; mkdir -p "$MIGRATION_DIR/files/Documents"
  for i in $(seq 1 200); do printf 'auros synthetic file %s\n' "$i" > "$MIGRATION_DIR/files/Documents/file-$i.txt"; done
fi
( cd "$MIGRATION_DIR" && find files -type f -exec sha256sum {} \; | sort -k2 > manifest.sha256 )
MIG_COUNT=$(wc -l < "$MIGRATION_DIR/manifest.sha256" | tr -d ' ')
if have virt-make-fs; then
  rm -f "$MIG_IMG"; virt-make-fs --type=ext4 --label=AUROS_MIGRATION "$MIGRATION_DIR" "$MIG_IMG" >>"$L/migration.log" 2>&1 || MIG_IMG=''
else
  MIG_IMG=''
fi

WRAP="localhost/auros-matrix-update:test"
build_testwrap "$IMAGE" "$WRAP" "$W/config.env" "$OVL" || fail_all "could not build the update test wrapper"
QCOW=$(build_qcow2 "$WRAP" "$W/disk-update") || fail_all "bootc-image-builder produced no qcow2 for the update run"
chmod 666 "$QCOW" 2>/dev/null || true

# ── push and sign A and B ────────────────────────────────────────────────────────────────────────
DIG_A=$(push_as "$WRAP" "$TAG") || fail_all "could not push image A to the harness registry"
sign_digest "$DIG_A" || fail_all "cosign could not sign image A"
log "A (booted image) = $DIG_A"

VM_NETDEV_EXTRA="guestfwd=tcp:${GUEST_REG_IP}:443-tcp:127.0.0.1:${REG_PORT},guestfwd=tcp:${GUEST_REG_IP}:80-tcp:127.0.0.1:${REG_PORT}"
export VM_NETDEV_EXTRA
SERIAL="$L/update-serial.log"; AGENT="$L/update-agent.log"; QMP="$W/update.qmp"
: > "$SERIAL"; : > "$AGENT"
EXTRA=()
[ -n "$MIG_IMG" ] && EXTRA+=( -drive "file=${MIG_IMG},format=qcow2,if=virtio" )

start_vm "$QCOW" "$PROFILE" "$SERIAL" "$AGENT" "$QMP" "${EXTRA[@]+"${EXTRA[@]}"}" \
  || fail_all "QEMU would not start for the update run"
poll_until "$(scale 900)" "first boot" -- grep_file "$AGENT" '#AUROS-STATUS#' \
  || fail_all "the VM never reported its status; nothing in the update group can be evaluated"
BOOTED_A=$(last_status_field "$AGENT" digest)
log "guest reports booted digest: ${BOOTED_A:-<none>}"

# wait_for_digest <want> <timeout> — poll the agent's status lines for a booted digest change.
wait_for_digest() {
  local want=$1 t=$2
  poll_until "$t" "booted digest == ${want:0:20}…" -- bash -c '[ "$(grep -a "^#AUROS-STATUS#" "$1" | tail -1)" != "" ] && grep -a "^#AUROS-STATUS#" "$1" | tail -1 | grep -q "$2"' _ "$AGENT" "$want"
}

# ── U1 — the update applies with NO human action ─────────────────────────────────────────────────
check_begin
DIG_B=$(push_as "localhost/auros-matrix-b:test" "$TAG") || fail_all "could not push image B"
sign_digest "$DIG_B" || fail_all "cosign could not sign image B"
log "B (the update) = $DIG_B — nothing else is touched from here; the machine must do this itself"
U1_DEADLINE=$(scale 1200)   # U1's criterion is 20 minutes
if wait_for_digest "$DIG_B" "$U1_DEADLINE"; then
  record U1 pass "the VM pulled, staged and rebooted with no host interaction; booted digest moved ${DIG_A} -> ${DIG_B} (timer interval compressed by the harness; the unattended path is unmodified)"
else
  record U1 fail "after ${U1_DEADLINE}s the booted digest is still $(last_status_field "$AGENT" digest) (expected ${DIG_B}). This is the Gate 1 exit condition; read logs/update-serial.log."
fi

# ── U2 — the previous deployment is still there (D10: two, and exactly two) ──────────────────────
check_begin
DEPS=$(last_status_field "$AGENT" deployments)
if [ "${DEPS:-0}" -ge 2 ]; then
  record U2 pass "bootc reports ${DEPS} deployments; the image we would roll back to is still on disk (D10: booted + one rollback is the real guarantee, not N)"
else
  record U2 fail "bootc reports ${DEPS:-unknown} deployment(s). Rollback is only real if the thing to roll back to was never deleted."
fi

# ── U3 — automatic rollback from a deliberately unhealthy image ──────────────────────────────────
check_begin
PRE_U3=$(last_status_field "$AGENT" digest)
DIG_C=$(push_as "localhost/auros-matrix-c:test" "$TAG") || fail_all "could not push image C"
sign_digest "$DIG_C" || fail_all "cosign could not sign image C"
log "C (fails greenboot on purpose) = $DIG_C"
U3_DEADLINE=$(scale 2400)
SAW_C=0
if wait_for_digest "$DIG_C" "$(scale 1200)"; then SAW_C=1; log "the VM booted into C, as intended"; fi
# Now the machine must rescue itself. greenboot marks the boot bad, the counter runs out, GRUB falls
# back, and we must land on the OLD digest — not merely "some digest that is not C".
if poll_until "$U3_DEADLINE" "rollback to ${PRE_U3:0:20}…" -- bash -c 'grep -a "^#AUROS-STATUS#" "$1" | tail -1 | grep -q "$2"' _ "$AGENT" "$PRE_U3"; then
  if [ "$SAW_C" = 1 ]; then
    record U3 pass "booted into the unhealthy image ${DIG_C}, greenboot failed its required.d check, and the machine returned to ${PRE_U3} and reached a prompt without anyone touching it"
  else
    record U3 fail "the machine is on ${PRE_U3}, but it never demonstrably booted into ${DIG_C} — it may simply have refused the update, which is U4's property, not U3's. Rollback is unproven."
  fi
else
  record U3 fail "offered the unhealthy image ${DIG_C}; after ${U3_DEADLINE}s the booted digest is $(last_status_field "$AGENT" digest), not the expected rollback target ${PRE_U3}. A school has no out-of-band console: an update that bricks a machine has to be recoverable by the machine."
fi

# ── U4 — an unsigned image is REFUSED, and refused for the right reason ──────────────────────────
check_begin
PRE_U4=$(last_status_field "$AGENT" digest)
DIG_D=$(push_as "localhost/auros-matrix-d:test" "$TAG") || fail_all "could not push image D"
log "D (deliberately UNSIGNED) = $DIG_D — pushed with no cosign signature at all"
# Give the timer a couple of cycles to try and fail, polling for evidence rather than sleeping blind.
U4_DEADLINE=$(scale 600)
poll_until "$U4_DEADLINE" "an update attempt against the unsigned image" -- bash -c '
  grep -qaE "Source image rejected|signature|Signature|SignatureValidationFailed|policy|invalid" "$1" \
  || grep -a "^#AUROS-STATUS#" "$1" | tail -1 | grep -q "$2"' _ "$SERIAL" "$DIG_D" || true
NOW_U4=$(last_status_field "$AGENT" digest)
SIG_EVIDENCE=$(grep -aoE 'Source image rejected[^"]*|[Ss]ignature verification failed[^"]*|invalid signature[^"]*|SignatureValidationFailed[^"]*' "$SERIAL" 2>/dev/null | head -1)
if [ "$NOW_U4" = "$DIG_D" ]; then
  record U4 fail "the VM BOOTED the unsigned image ${DIG_D}. Signature enforcement is not in force. This is exactly the D8 failure: deriving from Aurora leaves a docker \"\" insecureAcceptAnything catch-all, so enforcement succeeds while verifying nothing."
elif [ "$NOW_U4" != "$PRE_U4" ]; then
  record U4 fail "the booted digest changed from ${PRE_U4} to ${NOW_U4} while an unsigned image was on offer — not to the unsigned image, but the machine did not hold still either"
elif [ -z "$SIG_EVIDENCE" ]; then
  record U4 fail "the booted digest is unchanged (${PRE_U4}), but nothing in the console says the image was rejected for its SIGNATURE. An update that failed because the registry was slow looks identical to one that was refused on policy, and only one of those is the property U4 claims. Refusing to score this as a pass on the strength of an absence."
else
  record U4 pass "unsigned image ${DIG_D} refused, booted digest UNCHANGED at ${PRE_U4}; the guest gave a signature reason: ${SIG_EVIDENCE}"
fi
# The criterion also names `bootc upgrade` explicitly. The guest agent cannot be asked to run it
# (there is no host->guest channel by design), so the unattended timer path above is what we assert.
# See run/README.md, "What U4 does not do".

# ── U5 — registry unreachable: no change, no breakage, retry later ───────────────────────────────
check_begin
PRE_U5=$(last_status_field "$AGENT" digest)
# Re-sign D so the only variable is reachability, then take the registry away before it can be fetched.
sign_digest "$DIG_D" || warn "could not sign D for the U5 phase"
stop_registry
log "registry killed; the machine must now do nothing, gracefully"
U5_DEADLINE=$(scale 600)
poll_until "$U5_DEADLINE" "two failed fetch cycles" -- bash -c 'c=$(grep -ac "bootc-fetch-apply-updates" "$1" 2>/dev/null || echo 0); [ "${c:-0}" -ge 2 ]' _ "$SERIAL" || true
MID_U5=$(last_status_field "$AGENT" digest)
start_registry || warn "could not restart the registry for U5's retry half"
if wait_for_digest "$DIG_D" "$(scale 1200)"; then RETRIED=1; else RETRIED=0; fi
POST_SYS=$(grep -ac 'Failed to start\|emergency mode\|Freezing execution' "$SERIAL" 2>/dev/null || echo 0)
if [ "$MID_U5" != "$PRE_U5" ]; then
  record U5 fail "the booted digest changed to ${MID_U5} while the registry was unreachable"
elif [ "$RETRIED" != 1 ]; then
  record U5 fail "nothing broke while the registry was down (digest held at ${PRE_U5}), but the machine did not pick the update up once the registry came back. 'Retry later' is the half of U5 that matters on school Wi-Fi."
else
  record U5 pass "registry unreachable: booted digest held at ${PRE_U5}, no emergency-mode or freeze messages on the console (${POST_SYS} suspicious lines), and the update applied on its own once the registry returned"
fi

# ── R1 — the migration archive restores and re-verifies ──────────────────────────────────────────
check_begin
if [ -z "$MIG_IMG" ]; then
  record R1 fail "no migration disk could be built on this host: virt-make-fs (libguestfs-tools) is not installed, so R1 had nothing to restore. A missing tool is a fail — otherwise the one check that stands between a school and losing its files quietly stops running."
else
  R1_EVID=$(grep -aoE 'auros-restore[^"]{0,160}' "$SERIAL" 2>/dev/null | head -3 | tr '\n' ' ')
  RESTORED=$(grep -aoE 'restored ([0-9]+) file' "$SERIAL" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$R1_EVID" ]; then
    record R1 fail "a migration disk labelled AUROS_MIGRATION with ${MIG_COUNT} files and a manifest.sha256 was attached, and the guest said nothing about restoring it. The harness assumes auros-installer's Linux side ships an 'auros-restore' unit that consumes that layout (spec §6C) — if the convention differs, this check is what has to change. As written, R1 is the least-grounded check in this harness."
  elif [ "${RESTORED:-0}" != "$MIG_COUNT" ]; then
    record R1 fail "the restore ran but reported ${RESTORED:-no} file(s) against a manifest of ${MIG_COUNT}. Any discrepancy that is swallowed rather than shown is a fail by R1's own wording. Console: ${R1_EVID}"
  else
    record R1 pass "restored and re-verified ${RESTORED}/${MIG_COUNT} files against manifest.sha256 and reported the count: ${R1_EVID}"
  fi
fi

node "$HARNESS_DIR/lib/qmp.mjs" "$QMP" quit 30 >/dev/null 2>&1 || true
stop_vm; stop_swtpm "$PROFILE"; stop_registry
{ printf 'A=%s\nB=%s\nC=%s\nD=%s\n' "$DIG_A" "$DIG_B" "$DIG_C" "$DIG_D"; } > "$W/update-digests.env"

FAILS=$(grep -c '"status":"fail"' "$CHECKS_FILE" || true)
log "update group: ${FAILS} failing check(s)"
[ "${FAILS:-0}" -eq 0 ]

#!/usr/bin/env bash
# run-boot.sh <profile> — B1..B12 for one hardware profile, in QEMU.
#
# Shape of the run:
#   build the test wrapper -> bootc-image-builder -> qcow2 -> boot #1 (full agent suite, including the
#   S3 suspend/wake handshake) -> cold boot #2 (full suite again) -> B3 is the conjunction of the two.
#
# EVERY wait in here is a poll for a marker. There is no `sleep 300 && assert`. A TCG boot that takes
# eleven minutes is a slow boot, not a failed one, and a harness that cannot tell those apart is worse
# than no harness because it produces confident wrong answers.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$HARNESS_DIR/lib/vm.sh"

PROFILE=''; IMAGE=''; QCOW=''; LOCALE=''; KEYMAP=''; POLICY='open'; RECIPE=''
TEST_USER=auros; TEST_PASSWORD=auros; AUTOLOGIN=1
declare -a FLATPAK_REFS=()

usage() { cat >&2 <<'USAGE'
usage: run-boot.sh --profile ID --image REF [options]
  --profile ID        a profile id from matrix/profiles.yaml (required)
  --image REF         image under test (required, unless --qcow2 is given)
  --qcow2 PATH        reuse an already-built disk instead of building one
  --locale LANG       the recipe's declared locale, for B4
  --keymap KM         the recipe's declared keymap, for B4
  --policy MODE       open|managed|locked|kiosk (default open)
  --flatpak-ref REF   repeatable; the recipe's apps, for B9
  --recipe NAME       recipe name (records only)
  --user NAME         test user created in the disk image (default auros)
  --no-autologin      do not inject display-manager autologin (B7/B8/B12 will then fail honestly)
  --out DIR           run directory
env: AUROS_ALLOW_TCG=1 permits running without /dev/kvm (see README, "TCG and the B1 budget")
USAGE
exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=$2; shift 2;;
    --image) IMAGE=$2; shift 2;;
    --qcow2) QCOW=$2; shift 2;;
    --locale) LOCALE=$2; shift 2;;
    --keymap) KEYMAP=$2; shift 2;;
    --policy) POLICY=$2; shift 2;;
    --flatpak-ref) FLATPAK_REFS+=("$2"); shift 2;;
    --recipe) RECIPE=$2; shift 2;;
    --user) TEST_USER=$2; shift 2;;
    --no-autologin) AUTOLOGIN=0; shift;;
    --out) AUROS_RUN_DIR=$2; shift 2;;
    -h|--help) usage;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$PROFILE" ] || usage
[ -n "$IMAGE" ] || [ -n "$QCOW" ] || usage
export AUROS_RUN_DIR TEST_USER TEST_PASSWORD AUTOLOGIN
mkdir -p "$AUROS_RUN_DIR/checks" "$AUROS_RUN_DIR/logs" "$AUROS_RUN_DIR/work"
CHECKS_FILE="$AUROS_RUN_DIR/checks/boot-${PROFILE}.jsonl"; : > "$CHECKS_FILE"
L="$AUROS_RUN_DIR/logs"; W="$AUROS_RUN_DIR/work"

need podman; need qemu-system-x86_64; need node

# fail_all <reason> — a profile that cannot be set up has FAILED. It has not been skipped. The whole
# point of the "skip is not pass" rule is that a check which did not run is not a check that passed,
# and an environment we could not assemble is the loudest possible version of that.
fail_all() {
  local why=$1 id
  for id in B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12; do
    grep -q "\"id\":\"$id\"" "$CHECKS_FILE" 2>/dev/null || { check_begin; record "$id" fail "$why"; }
  done
  exit 1
}

# THE PROFILE IS VALIDATED BEFORE ANYTHING IS BUILT.
# `eval "$(profile.mjs "$PROFILE")"` used to sit AFTER build_qcow2. On an unknown profile id
# profile.mjs exits 2 and prints nothing, so the eval was of an empty string, and the failure landed
# ten minutes later as `P_DISK_GB: unbound variable` — a typo diagnosed as a shell error, after a
# full image build. profile.mjs's own message lists the ids that do exist; it belongs here, before
# the expensive part, where it can be read.
PROFILE_ENV="$(node "$HARNESS_DIR/lib/profile.mjs" "$PROFILE" 2>"$AUROS_RUN_DIR/logs/profile.err")" || {
  fail_all "profile '${PROFILE}' could not be resolved from matrix/profiles.yaml: $(tr '\n' ' ' < "$AUROS_RUN_DIR/logs/profile.err")"
}
eval "$PROFILE_ENV"
[ -n "${P_DISK_GB:-}" ] && [ -n "${P_RAM_MB:-}" ] || fail_all "profile '${PROFILE}' resolved but produced no P_DISK_GB/P_RAM_MB — lib/profile.mjs and this script disagree about the variable names, and every later use would be an unbound-variable error somewhere unhelpful. It printed: $(printf '%s' "$PROFILE_ENV" | tr '\n' ' ')"

ACCEL=$(accel_mode)
if [ "$ACCEL" = tcg ] && [ "$AUROS_ALLOW_TCG" != 1 ]; then
  fail_all "no writable /dev/kvm on this host and AUROS_ALLOW_TCG is not set. The runner probe measured KVM as present and usable after 'chmod 666 /dev/kvm'; a CI job silently falling back to emulation would quietly stop enforcing B1's 120-second budget, so the harness refuses instead."
fi

log "profile ${PROFILE} · accel=${ACCEL} · policy=${POLICY} · image=${IMAGE:-<prebuilt qcow2>}"

# ── the bootable artifact ────────────────────────────────────────────────────────────────────────
cat > "$W/config.env" <<CFG
TEST_USER=${TEST_USER}
LOCALE=${LOCALE}
KEYMAP=${KEYMAP}
POLICY_MODE=${POLICY}
FLATPAK_REFS=${FLATPAK_REFS[*]+${FLATPAK_REFS[*]}}
SUSPEND_TEST=1
FULL_BOOTS=2
CFG

if [ -z "$QCOW" ]; then
  WRAP="localhost/auros-matrix-${PROFILE}:test"
  build_testwrap "$IMAGE" "$WRAP" "$W/config.env" || fail_all "could not build the test wrapper image on top of ${IMAGE}; see logs/testwrap-build.log"
  QCOW=$(build_qcow2 "$WRAP" "$W/disk-${PROFILE}") || fail_all "bootc-image-builder produced no qcow2; see logs/bib.log"
  [ -n "$QCOW" ] && [ -f "$QCOW" ] || fail_all "bootc-image-builder reported success but no .qcow2 exists"
fi
chmod 666 "$QCOW" 2>/dev/null || true

# The profile's disk floor. small-disk exists to prove two deployments plus Flatpaks fit at 64 GB.
# (Already evaluated above, before the build; re-evaluated here so this block still reads on its own.)
eval "$PROFILE_ENV"
VIRT_BYTES=$(qemu-img info --output=json "$QCOW" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)["virtual-size"]||0))}catch{process.stdout.write("0")}})')
WANT_BYTES=$(( P_DISK_GB * 1024 * 1024 * 1024 ))
if [ "${VIRT_BYTES:-0}" -gt "$WANT_BYTES" ]; then
  warn "the produced disk is $((VIRT_BYTES/1024/1024/1024))G, larger than profile ${PROFILE}'s ${P_DISK_GB}G floor — it cannot be shrunk, so this profile is being run on a disk it would not have on real hardware"
  DISK_NOTE="disk floor NOT honoured: image virtual size $((VIRT_BYTES/1024/1024/1024))G > profile ${P_DISK_GB}G"
else
  qemu-img resize "$QCOW" "${P_DISK_GB}G" >/dev/null 2>&1 || warn "qemu-img resize to ${P_DISK_GB}G failed"
  DISK_NOTE="disk sized to profile floor ${P_DISK_GB}G"
fi
log "$DISK_NOTE"

# ── one cold boot ────────────────────────────────────────────────────────────────────────────────
# boot_once <n> -> sets BOOT_OK / BOOT_SECONDS; leaves the agent's records in $CHECKS_FILE
BOOT_OK=0; BOOT_SECONDS=0
boot_once() {
  local n=$1
  local serial="$L/${PROFILE}-boot${n}-serial.log" agentlog="$L/${PROFILE}-boot${n}-agent.log" qmp="$W/${PROFILE}-boot${n}.qmp"
  : > "$serial"; : > "$agentlog"; rm -f "$qmp"
  local t0; t0=$(date +%s)
  if ! start_vm "$QCOW" "$PROFILE" "$serial" "$agentlog" "$qmp"; then
    BOOT_OK=0; BOOT_SECONDS=0
    BOOT_REASON="QEMU could not be started for profile ${PROFILE} (missing firmware, swtpm, or an immediate exit — see logs/${PROFILE}-qemu.log)"
    return 1
  fi
  trap 'stop_vm; stop_swtpm "$PROFILE"' EXIT

  # B1: poll for the greeter. Deadline is generous; the BUDGET is a separate judgement below.
  local login_deadline; login_deadline=$(scale 600)
  if poll_until "$login_deadline" "login prompt" -- bash -c 'grep -qaE "$0" "$1" || grep -qa "#AUROS-BOOT#" "$2"' "$LOGIN_RE" "$serial" "$agentlog"; then
    BOOT_SECONDS=$(( $(date +%s) - t0 )); BOOT_OK=1
  else
    BOOT_SECONDS=$(( $(date +%s) - t0 )); BOOT_OK=0
    BOOT_REASON="no login/greeter marker on the serial console and no agent heartbeat within ${login_deadline}s (accel=${ACCEL})"
    stop_vm; return 1
  fi

  # The agent's suspend handshake: it announces, we arm the wakeup. Both sides wait on events.
  ( if poll_until "$(scale 900)" "agent ready to suspend" -- grep_file "$agentlog" '#AUROS-READY-SUSPEND#'; then
      node "$HARNESS_DIR/lib/qmp.mjs" "$qmp" suspend-cycle "$(scale 600)" >> "$L/${PROFILE}-qmp.log" 2>&1 || true
    fi ) &
  local qmp_helper=$!

  # Wait for the agent to finish this boot's work — or for QEMU to die, which we notice immediately
  # rather than at the end of a timeout.
  #
  # AUROS_AGENT_DEADLINE exists so a PROBE can fail fast. It changes how long we WAIT, never what we
  # CONCLUDE — the same distinction vm.sh's scale() already makes for TCG. A shortened deadline makes
  # a slow-but-correct agent look like a stalled one, so every check that goes unreported under a
  # non-default deadline SAYS SO in its detail (see agent_evidence below). A run that waited seven
  # minutes must never be mistakable for one that waited forty.
  local agent_deadline; agent_deadline=$(scale "${AUROS_AGENT_DEADLINE:-2400}")
  poll_until "$agent_deadline" "agent done (boot ${n})" -- bash -c '
     grep -qa "#AUROS-DONE#" "$1" && exit 0
     kill -0 "$2" 2>/dev/null || exit 0
     exit 1' _ "$agentlog" "$VM_PID" || true
  kill "$qmp_helper" 2>/dev/null || true

  local done_ok=0
  grep_file "$agentlog" '#AUROS-DONE#' && done_ok=1
  harvest_agent "$agentlog" "$CHECKS_FILE"
  node "$HARNESS_DIR/lib/qmp.mjs" "$qmp" quit 30 >/dev/null 2>&1 || true
  stop_vm; stop_swtpm "$PROFILE"
  trap - EXIT
  [ "$done_ok" = 1 ] || { BOOT_REASON="the guest agent never reported #AUROS-DONE# on boot ${n} — QEMU exited early or the agent stalled; read logs/${PROFILE}-boot${n}-serial.log before concluding anything"; return 1; }
  return 0
}

# ── boot 1 ───────────────────────────────────────────────────────────────────────────────────────
check_begin
BOOT_REASON=''
boot_once 1 || true
B1_OK_1=$BOOT_OK; B1_SEC_1=$BOOT_SECONDS
if [ "$B1_OK_1" = 1 ]; then
  if [ "$ACCEL" = kvm ] && [ "$B1_SEC_1" -gt 120 ]; then
    record B1 fail "reached a greeter, but after ${B1_SEC_1}s — B1's criterion is 120s and this run was KVM-accelerated, so the budget applies"
  elif [ "$ACCEL" = kvm ]; then
    record B1 pass "greeter within ${B1_SEC_1}s (budget 120s, accel=kvm)"
  else
    record B1 pass "greeter after ${B1_SEC_1}s. accel=tcg, so the 120s budget was NOT applied — emulated boot time says nothing about a real machine. Only a KVM run can enforce the budget half of B1."
  fi
else
  record B1 fail "${BOOT_REASON:-no greeter}"
fi

# ── boot 2 (cold) — B3 ───────────────────────────────────────────────────────────────────────────
B2_AFTER_1=$(grep -a '"id":"B2"' "$CHECKS_FILE" | tail -1 | grep -c '"status":"pass"' || true)
# The B2 detail of each boot (failed units and why), because B3 is the only record that sees both:
# the fragment keeps one B2, and run 35566336512's bios-legacy B3 said "boot1=0 boot2=0" and nothing else.
b2_detail() { grep -a '"id":"B2"' "$CHECKS_FILE" | tail -1 | node -e 'const l=require("fs").readFileSync(0,"utf8").trim();try{process.stdout.write(JSON.parse(l).detail)}catch{process.stdout.write("<no B2 record>")}'; }
B2_DETAIL_1=$(b2_detail)
check_begin
if [ "$B1_OK_1" != 1 ]; then
  record B3 fail "first boot did not reach a greeter, so there is nothing for a second boot to confirm"
else
  BOOT_REASON=''
  boot_once 2 || true
  B2_AFTER_2=$(grep -a '"id":"B2"' "$CHECKS_FILE" | tail -1 | grep -c '"status":"pass"' || true)
  B2_DETAIL_2=$(b2_detail)
  if [ "$BOOT_OK" = 1 ] && [ "${B2_AFTER_1:-0}" = 1 ] && [ "${B2_AFTER_2:-0}" = 1 ]; then
    record B3 pass "two consecutive cold boots both reached a greeter (${B1_SEC_1}s, ${BOOT_SECONDS}s) and both reported is-system-running=running"
  else
    record B3 fail "boot1 greeter=${B1_OK_1} boot2 greeter=${BOOT_OK}; is-system-running pass on boot1=${B2_AFTER_1:-0} boot2=${B2_AFTER_2:-0}. First-boot provisioning masking a second-boot failure is exactly what B3 is for. boot1 B2: ${B2_DETAIL_1} | boot2 B2: ${B2_DETAIL_2:-<no second boot>} ${BOOT_REASON}"
  fi
fi

# ── anything the agent never reported is a FAIL, never a silence ─────────────────────────────────
#
# And the failure has to say what IS there. "the agent produced no record" is true of four completely
# different situations — QEMU never opened the second serial port, the unit never started, the agent
# started and stalled, or it ran and its output never reached the host — and they have four different
# fixes. So the detail carries the agent log's size, which framing markers it did emit, and its last
# lines. Reading ten of these strings must not require downloading ten artifacts.
agent_evidence() {
  local f
  for f in "$L/${PROFILE}-boot2-agent.log" "$L/${PROFILE}-boot1-agent.log"; do
    [ -s "$f" ] && break
  done
  if [ ! -e "$f" ]; then
    printf 'no agent log exists at %s — QEMU never opened the second serial port, so nothing the guest wrote could have reached the host' "$f"
    return
  fi
  local bytes boot status ready done_ tail_
  bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  boot=$(grep -ac '#AUROS-BOOT#' "$f" 2>/dev/null || true)
  status=$(grep -ac '#AUROS-STATUS#' "$f" 2>/dev/null || true)
  ready=$(grep -ac '#AUROS-READY-SUSPEND#' "$f" 2>/dev/null || true)
  done_=$(grep -ac '#AUROS-DONE#' "$f" 2>/dev/null || true)
  tail_=$(tail -c 400 "$f" 2>/dev/null | tr '\n\r\t' '   ' | tr -cd '[:print:] ')
  printf '%s is %s bytes; markers seen: #AUROS-BOOT#=%s #AUROS-STATUS#=%s #AUROS-READY-SUSPEND#=%s #AUROS-DONE#=%s. ' \
    "${f##*/}" "${bytes:-0}" "${boot:-0}" "${status:-0}" "${ready:-0}" "${done_:-0}"
  if [ "${boot:-0}" = 0 ]; then
    printf 'The agent never announced a boot at all, so auros-matrix-agent.service did not run — check logs/testwrap-build.log for whether `systemctl enable` took, and the serial console for the unit failing. '
  elif [ "${done_:-0}" = 0 ]; then
    printf 'The agent STARTED and never finished: it emitted its boot line but no #AUROS-DONE#, so it stalled inside a check rather than failing to launch. The first thing it does after the status line is `systemctl is-system-running --wait`. '
  fi
  printf 'Last of the log: %s' "${tail_:-<empty>}"
  if [ -n "${AUROS_AGENT_DEADLINE:-}" ] && [ "${AUROS_AGENT_DEADLINE}" != 2400 ]; then
    printf ' — AND NOTE: this run waited only %ss for the agent (AUROS_AGENT_DEADLINE), not the default 2400s. A slow agent and a stalled one are indistinguishable under a shortened deadline, so this result is a PROBE result and is not evidence that the check would fail in CI.' "$AUROS_AGENT_DEADLINE"
  fi
}
AGENT_EVIDENCE="$(agent_evidence)"
for id in B2 B4 B5 B6 B7 B8 B9 B10 B11 B12; do
  if ! grep -qa "\"id\":\"$id\"" "$CHECKS_FILE"; then
    check_begin
    record "$id" fail "the in-guest agent produced no record for ${id} on profile ${PROFILE}. A check that did not report did not pass. ${AGENT_EVIDENCE}"
  fi
done

# ── the compat.tsv row for this profile ──────────────────────────────────────────────────────────
# source=vm, and the physical-only columns stay EMPTY. See hardware/README.md — an empty cell means
# "we did not test this", and that is the truth. Filling them from a VM is how you end up quoting a
# school on Wi-Fi you never observed.
FAILED_IDS=$(node -e '
  const fs=require("fs"); const recs=[];
  for (const l of fs.readFileSync(process.argv[1],"utf8").split("\n")) { if(!l.trim())continue; try{recs.push(JSON.parse(l));}catch{} }
  process.stdout.write([...new Set(recs.filter(o=>o.status!=="pass").map(o=>o.id))].join(","));' "$CHECKS_FILE")
GPU_V=$(node -e 'const fs=require("fs");const last=new Map();for(const l of fs.readFileSync(process.argv[1],"utf8").split("\n")){if(!l.trim())continue;try{const o=JSON.parse(l);last.set(o.id,o)}catch{}}process.stdout.write(last.get("B8")?.status==="pass"?"ok":last.get("B8")?"fail":"")' "$CHECKS_FILE")
AUD_V=$(node -e 'const fs=require("fs");const last=new Map();for(const l of fs.readFileSync(process.argv[1],"utf8").split("\n")){if(!l.trim())continue;try{const o=JSON.parse(l);last.set(o.id,o)}catch{}}process.stdout.write(last.get("B7")?.status==="pass"?"ok":last.get("B7")?"fail":"")' "$CHECKS_FILE")
NOTE="matrix $( [ -z "$FAILED_IDS" ] && echo pass || echo "fail(${FAILED_IDS})"); ${P_SUMMARY}; ${DISK_NOTE}; accel=${ACCEL}; virtio-gpu/ich9-hda software stack only"
{
  # model year source cpu ram_gb firmware wifi trackpad suspend brightness gpu audio webcam verdict notes tested_on tester
  printf 'qemu:%s\t\tvm\t%s\t%s\t%s\t\t\t\t\t%s\t%s\t\tuntested\t%s\t%s\t%s\n' \
    "$PROFILE" "${P_CPU:-qemu-default}" "$(( P_RAM_MB / 1024 ))" "$P_FIRMWARE" \
    "$GPU_V" "$AUD_V" "$NOTE" "$(date -u +%Y-%m-%d)" "auros-matrix/run-boot.sh"
} >> "$AUROS_RUN_DIR/compat-rows.tsv"

# One count per CHECK, not per record: the agent reports B2-B12 on each of FULL_BOOTS boots, so
# counting "status":"fail" lines printed "10 failing check(s) — B5,B7,B8,B12,B11" (run 35566336512).
# A check that failed on either boot failed — the same pessimistic rule matrix/run.sh's collector applies.
FAILS=$(printf '%s' "$FAILED_IDS" | tr ',' '\n' | grep -c . || true)
log "profile ${PROFILE}: ${FAILS} failing check(s)${FAILED_IDS:+ — ${FAILED_IDS}}"
[ "${FAILS:-0}" -eq 0 ]

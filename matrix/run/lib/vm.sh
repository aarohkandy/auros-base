#!/usr/bin/env bash
# vm.sh — build the bootable artifact and drive QEMU. Sourced by run-boot.sh and run-update.sh.
# shellcheck shell=bash

: "${AUROS_ALLOW_TCG:=0}"
: "${AUROS_TCG_FACTOR:=6}"     # TCG is roughly an order of magnitude slower; deadlines scale, results do not.

accel_mode() { if [ -w /dev/kvm ]; then echo kvm; else echo tcg; fi; }

# scale <seconds> — stretch a deadline under emulation. This changes how long we WAIT, never what we
# CONCLUDE. The one place the distinction matters is B1's 120s budget; see run-boot.sh.
scale() { local s=$1; if [ "$(accel_mode)" = tcg ]; then echo $(( s * AUROS_TCG_FACTOR )); else echo "$s"; fi; }

ovmf_code() {
  local sb=${1:-0} f
  if [ "$sb" = 1 ]; then
    for f in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do [ -f "$f" ] && { echo "$f"; return 0; }; done
    return 1
  fi
  for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 1
}
ovmf_vars() {
  local sb=${1:-0} f
  if [ "$sb" = 1 ]; then
    # The MS KEK/db-enrolled variable store. Without it, "Secure Boot on" would be Secure Boot with
    # our own keys, which is not what any OEM ships and not what uefi-secureboot claims to prove.
    for f in /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd; do [ -f "$f" ] && { echo "$f"; return 0; }; done
    return 1
  fi
  for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 1
}

# ── the test wrapper ─────────────────────────────────────────────────────────────────────────────
# build_testwrap <image-under-test> <tag> <config.env path> [overlay dir]
build_testwrap() {
  local base=$1 tag=$2 cfg=$3 overlay=${4:-}
  local ctx="$AUROS_RUN_DIR/work/testwrap"
  rm -rf "$ctx"; mkdir -p "$ctx/overlay"
  cp "$HARNESS_DIR/guest/auros-matrix-agent.sh" "$HARNESS_DIR/guest/auros-matrix-agent.service" "$ctx/"
  cp "$HARNESS_DIR/guest/Containerfile.testwrap" "$ctx/Containerfile"
  cp "$cfg" "$ctx/config.env"
  [ -n "$overlay" ] && [ -d "$overlay" ] && cp -a "$overlay/." "$ctx/overlay/"
  # keep the overlay non-empty so COPY overlay/ / never fails on an empty directory
  mkdir -p "$ctx/overlay/etc"; : > "$ctx/overlay/etc/auros-matrix-overlay"
  log "building test wrapper on top of $base"
  podman build --build-arg "BASE=$base" --build-arg "TEST_USER=${TEST_USER:-auros}" \
    --build-arg "AUTOLOGIN=${AUTOLOGIN:-1}" -t "$tag" "$ctx" > "$AUROS_RUN_DIR/logs/testwrap-build.log" 2>&1 \
    || { tail -30 "$AUROS_RUN_DIR/logs/testwrap-build.log" >&2; return 1; }
  return 0
}

# bib_image — the bootc-image-builder to run: $BIB_IMAGE if set, else bib.lock's pin. Refuses anything
# not pinned by digest. It used to be `:latest` with `podman pull … || true`, so the builder could
# change between two runs of the same matrix and a failed pull was silently replaced by the cache.
bib_image() {
  local img="${BIB_IMAGE:-}"
  [ -n "$img" ] || img="$(sed -n 's/^BIB_IMAGE=//p' "$BASE_REPO/bib.lock" 2>/dev/null | head -1)"
  [[ "$img" =~ @sha256:[a-f0-9]{64}$ ]] || {
    echo "bootc-image-builder '${img:-<unset>}' is not pinned by digest (bib.lock BIB_IMAGE / \$BIB_IMAGE) — refusing" >&2
    return 1
  }
  printf '%s\n' "$img"
}

# build_qcow2 <image> <outdir> — bootc-image-builder. Never pipe this through anything (D19).
build_qcow2() {
  local img=$1 out=$2
  mkdir -p "$out"
  cat > "$AUROS_RUN_DIR/work/bib-config.toml" <<TOML
[[customizations.user]]
name = "${TEST_USER:-auros}"
password = "${TEST_PASSWORD:-auros}"
groups = ["wheel"]

# D26, measured: this image is ~8.4 GB across 257 layers and bib's default root filesystem is too
# small for it — ostree refuses the write with "min-free-space-percent '3%' would be exceeded" rather
# than filling the disk. Without this stanza the boot checks fail at image-build time for a reason
# that has nothing to do with the image.
[[customizations.filesystem]]
mountpoint = "/"
minsize = "${ROOTFS_MINSIZE:-20 GiB}"
TOML
  local bib; bib=$(bib_image) || return 1
  podman pull "$bib" > "$AUROS_RUN_DIR/logs/bib-pull.log" 2>&1 \
    || { tail -20 "$AUROS_RUN_DIR/logs/bib-pull.log" >&2; echo "could not pull bootc-image-builder $bib" >&2; return 1; }
  log "bootc-image-builder -> qcow2 (this is the slow step)"
  podman run --rm --privileged --security-opt label=type:unconfined_t \
    -v "$out":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$AUROS_RUN_DIR/work/bib-config.toml":/config.toml:ro \
    "$bib" \
    --type qcow2 --rootfs "${BIB_ROOTFS:-xfs}" --local "$img" \
    > "$AUROS_RUN_DIR/logs/bib.log" 2>&1 \
    || { tail -40 "$AUROS_RUN_DIR/logs/bib.log" >&2; return 1; }
  find "$out" -name '*.qcow2' | head -1
}

# ── QEMU ─────────────────────────────────────────────────────────────────────────────────────────
# start_vm <qcow2> <profile-id> <serial.log> <agent.log> <qmp.sock> [extra qemu args...]
# Sets VM_PID. Netdev extras (the local registry redirect) come from $VM_NETDEV_EXTRA.
VM_PID=''
start_vm() {
  local qcow=$1 pid=$2 serial=$3 agent=$4 qmp=$5; shift 5
  eval "$(node "$HARNESS_DIR/lib/profile.mjs" "$pid")"
  local accel; accel=$(accel_mode)
  local -a A=()
  local MACHINE="q35,accel=${accel}"
  A+=( -name "auros-${pid}" -smp "${VM_SMP:-4}" -m "$P_RAM_MB" )
  # S3 must be advertised or `systemctl suspend` has nothing to enter and B10 becomes untestable.
  A+=( -global ICH9-LPC.disable_s3=0 )
  if [ -n "$P_CPU" ]; then
    if [ "$P_CPU" = host ] && [ "$accel" != kvm ]; then A+=( -cpu max ); else A+=( -cpu "$P_CPU" ); fi
  else
    [ "$accel" = kvm ] && A+=( -cpu host ) || A+=( -cpu max )
  fi

  case "$P_FIRMWARE" in
    bios) : ;;  # SeaBIOS is QEMU's default; bios-legacy is the absence of pflash, not a flag
    uefi|uefi-sb)
      local sb=0; [ "$P_FIRMWARE" = uefi-sb ] && sb=1
      local code vars
      code=$(ovmf_code "$sb") || { warn "no OVMF firmware for ${P_FIRMWARE}"; return 3; }
      vars=$(ovmf_vars "$sb") || { warn "no OVMF variable store for ${P_FIRMWARE}"; return 3; }
      cp "$vars" "$AUROS_RUN_DIR/work/${pid}-vars.fd"
      A+=( -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code}" )
      A+=( -drive "if=pflash,format=raw,unit=1,file=${AUROS_RUN_DIR}/work/${pid}-vars.fd" )
      if [ "$sb" = 1 ]; then
        # Secure Boot needs SMM, and the pflash must be marked secure, or the firmware will happily
        # boot anything and uefi-secureboot would prove nothing.
        MACHINE="q35,accel=${accel},smm=on"
        A+=( -global driver=cfi.pflash01,property=secure,value=on )
      fi
      ;;
  esac

  if [ "$P_IO_THROTTLE" = 1 ]; then
    A+=( -drive "file=${qcow},format=qcow2,if=none,id=d0,throttling.iops-total=${P_IOPS},throttling.bps-total=${P_BPS}" -device virtio-blk-pci,drive=d0 )
  else
    A+=( -drive "file=${qcow},format=qcow2,if=virtio" )
  fi

  if [ -n "$P_TPM" ]; then
    local tdir="$AUROS_RUN_DIR/work/${pid}-tpm"; mkdir -p "$tdir"
    local -a SW=( swtpm socket --tpmstate "dir=$tdir" --ctrl "type=unixio,path=$tdir/sock" --flags startup-clear )
    [ "$P_TPM" = "2.0" ] && SW+=( --tpm2 )
    "${SW[@]}" >"$AUROS_RUN_DIR/logs/${pid}-swtpm.log" 2>&1 &
    echo $! > "$AUROS_RUN_DIR/work/${pid}-swtpm.pid"
    poll_until 30 "swtpm socket" -- test -S "$tdir/sock" || { warn "swtpm did not come up for TPM ${P_TPM}"; return 3; }
    A+=( -chardev "socket,id=chrtpm,path=$tdir/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm )
    [ "$P_TPM" = "1.2" ] && A+=( -device tpm-tis,tpmdev=tpm0 ) || A+=( -device tpm-crb,tpmdev=tpm0 )
  fi

  A+=( -machine "$MACHINE" )
  # id: so the screenshot phase can name this head to QMP screendump (run-boot.sh). No default -vga is
  # suppressed, so console 0 is still the std VGA and the guest sees two cards, as it always has.
  A+=( -device "virtio-gpu-pci,id=auros-gpu" )
  # B7 needs a sound device to enumerate. No host audio backend: we are checking the stack, not sound.
  A+=( -audiodev "none,id=snd0" -device ich9-intel-hda -device hda-duplex,audiodev=snd0 )
  A+=( -netdev "user,id=n0${VM_NETDEV_EXTRA:+,${VM_NETDEV_EXTRA}}" -device virtio-net-pci,netdev=n0 )
  A+=( -display none -serial "file:${serial}" -serial "file:${agent}" )
  A+=( -qmp "unix:${qmp},server=on,wait=off" )
  A+=( "$@" )

  printf '%s\n' "${A[*]}" > "$AUROS_RUN_DIR/logs/${pid}-qemu-cmdline.txt"
  log "starting QEMU (${pid}, accel=${accel}, ${P_RAM_MB}MB, fw=${P_FIRMWARE}${P_TPM:+, TPM ${P_TPM}})"
  qemu-system-x86_64 "${A[@]}" >>"$AUROS_RUN_DIR/logs/${pid}-qemu.log" 2>&1 &
  VM_PID=$!
  sleep 1
  kill -0 "$VM_PID" 2>/dev/null || { warn "QEMU exited immediately: $(tail -5 "$AUROS_RUN_DIR/logs/${pid}-qemu.log")"; return 3; }
  return 0
}

stop_vm() {
  local pid=${1:-$VM_PID}
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  # a short bounded wait, then insist
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  VM_PID=''
}
stop_swtpm() { local f="$AUROS_RUN_DIR/work/$1-swtpm.pid"; [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; }

vm_alive() { [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; }

# ── serial-log predicates, for poll_until ────────────────────────────────────────────────────────
# B1's criterion is "display manager active / greeter detected". `sddm` was in this alternation as
# the display-manager name and on this base it matches NOTHING: the display manager is
# /usr/bin/plasmalogin, resolved from display-manager.service rather than assumed (run 35550693484).
# The other alternatives carried B1 on the probe boot, so the dead one was never noticed — which is
# how an alternation quietly narrows until one day it is the only one left.
LOGIN_RE='login:|Reached target Graphical|Startup finished|sddm|plasmalogin|Welcome to'
agent_done()   { grep_file "$1" '#AUROS-DONE#'; }
agent_booted() { grep_file "$1" "#AUROS-BOOT# $2\$"; }

# harvest_agent <agent.log> <checks.jsonl> — copy the agent's #AUROS# records into the run's checks
# file. Later records for the same id supersede earlier ones, which is how a second boot updates B2.
harvest_agent() {
  local src=$1 dst=$2
  [ -f "$src" ] || return 0
  grep -a '^#AUROS#' "$src" | sed 's/^#AUROS#//' | while IFS= read -r line; do
    printf '%s\n' "$line" >> "$dst"
  done
}

# last_status_field <agent.log> <digest|deployments|boot>
last_status_field() {
  local src=$1 f=$2
  grep -a '^#AUROS-STATUS#' "$src" 2>/dev/null | tail -1 | sed "s/^#AUROS-STATUS#//" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s.trim())[process.argv[1]]??""))}catch{process.stdout.write("")}})' "$f"
}

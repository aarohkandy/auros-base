#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# auros-base/tools/capture-compat.sh — capture one honest row of hardware/compat.tsv.
#
# RUNS ON A BOOTED AUROS MACHINE. It reads sysfs and procfs. It writes nothing outside the files you
# name with --facts-out / --row-out.
#
# ── WHAT IT IS FOR ───────────────────────────────────────────────────────────────────────────────
#
# SPEC §8: "Build hardware/compat.tsv from hour one. After fifty rows it is the thing competitors
# cannot copy quickly; before then it is how we quote without guessing."
#
# It only becomes that if capturing a row is EASY and HONEST. Those pull in opposite directions, and
# the resolution is the line this script draws down the middle of the row:
#
#   OBSERVABLE      model, year, cpu, ram_gb, firmware, ids, tpm
#                   Machine-readable facts with a path behind each one. The script fills these,
#                   records where it read them, and refuses rather than inventing one.
#
#   HUMAN-ONLY      wifi, trackpad, suspend, brightness, gpu, audio, webcam
#                   Somebody has to shut the lid, press the brightness key, and watch. The script
#                   CANNOT fill these from probing — see the hard refusal in emit_row() — and the
#                   five that hardware/README.md names physical-only are enforced twice.
#
# A tool that guessed the second group would destroy the only thing that makes this table worth
# having. `wpa_supplicant is loaded` is not `the wifi works`: it is a module list. `ACPI reports a
# backlight interface` is not `the brightness key changes the screen`. Every one of those inferences
# is available, cheap, and wrong, and a table full of them reads exactly like a table full of
# observations right up until a school finds out.
#
# ── THE OTHER RULE THIS FILE IS BUILT AROUND ─────────────────────────────────────────────────────
#
#   NEVER GUESS A PATH. When an assertion fails it must print what IS there.
#
# So every probe names the file it read, every refusal lists the directory contents it actually
# found, and the facts file records `fact<TAB>value<TAB>observed_from` for all of it. Four base
# builds were lost to remembered layouts; a laptop is in the room for an afternoon.
#
# ── TESTING SEAM ─────────────────────────────────────────────────────────────────────────────────
#
# AUROS_TEST_ROOT (DECISIONS.md D34) is the one seam a shipped script may carry: unset on a real
# machine, pointed at a synthetic tree by tests/capture-compat.test.sh. Every absolute read in this
# file goes through sysread()/rd(), which prefix it. There is no other environment variable and no
# flag that changes what is observed.
#
# USAGE
#   capture-compat.sh                         probe, print the partial row, print the prompts
#   capture-compat.sh --answers FILE          probe, then fill the human columns from FILE
#   capture-compat.sh --wifi ok --gpu partial --note-gpu "tearing on external display"
#   capture-compat.sh --print-prompts         just the questions, for printing out
#   capture-compat.sh --facts-out P --row-out Q
#   overrides: --model NAME --year YYYY --tester NAME --date YYYY-MM-DD
#   output:    --row-only (row on stdout, nothing else)  --header (print the TSV header)
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

ME="capture-compat"
R="${AUROS_TEST_ROOT:-}"

# ── the schema, in ONE place ─────────────────────────────────────────────────────────────────────
# Column order here is the column order of hardware/compat.tsv. It is checked against the real file
# by tools/quote-from-compat.mjs and by the test suite, so a schema change that forgets one of them
# is a red build rather than a row that lands in the wrong columns.
COLUMNS="model year source cpu ram_gb firmware ids tpm wifi trackpad suspend brightness gpu audio webcam verdict notes tested_on tester"

# The seven a human must answer. Order is COST ORDER (spec/runbook): wifi failing makes the machine
# useless, a webcam failing makes it slightly worse. Test in the order that matches what it costs.
HUMAN_COLUMNS="wifi trackpad suspend brightness gpu audio webcam"

# The five hardware/README.md declares physical-only. A vm row may not claim these at all, and THIS
# script may not fill them by probing under any circumstances. The other two (gpu, audio) are also
# human-answered here; these five are additionally enforced by tools/compat-lint.mjs.
PHYSICAL_ONLY="wifi trackpad suspend brightness webcam"

# DMI placeholders. Vendors ship these instead of leaving the field blank, so treating them as data
# is how "System Product Name" becomes a model in the table competitors cannot copy.
DMI_JUNK="none|not specified|not available|to be filled by o.e.m.|to be filled by oem|system product name|system version|default string|o.e.m.|oem|unknown|x.x.x|\\\$(default string)"

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
warn() { printf '%s: %s\n' "$ME" "$*" >&2; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── reading the machine ──────────────────────────────────────────────────────────────────────────
# rd <abs-path> — first line of a sysfs/procfs file, NULs removed, trailing whitespace stripped.
#
# NOT `tr -d '[:space:]'`. That idiom deleted NEWLINES as well as spaces in build/10-hardening.sh and
# made a check permanently green (DECISIONS.md D19/D34). Here it would silently concatenate two
# sysfs values into one. `head -1` then strip the tail, never the separators.
rd() {
  local p="$R$1"
  [ -r "$p" ] || return 1
  [ -f "$p" ] || return 1
  tr -d '\000' < "$p" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'
}

# lsdir <abs-path> — what IS there, for a refusal message. Prints "(no such directory)" rather than
# nothing, because an empty refusal reads as a tool that did not look.
lsdir() {
  local p="$R$1"
  if [ -d "$p" ]; then
    local n; n="$(ls -A "$p" 2>/dev/null | head -40 | tr '\n' ' ')"
    printf '%s' "${n:-(directory is empty)}"
  else
    printf '(no such directory: %s)' "$1"
  fi
}

# ── the facts file: every value with the path it came from ───────────────────────────────────────
#
# A FILE, not a shell variable. Every probe below is called as `X="$(probe_x)"`, which runs it in a
# SUBSHELL — and a variable assigned in a subshell is discarded when it exits. The first version of
# this script accumulated facts into a string and printed an empty facts table on every run, while
# looking exactly like a script that was recording everything. Same shape as every bug D34 lists: it
# could not fail visibly. A file survives the subshell, so the evidence survives with it.
FACTS_TMP="$(mktemp "${TMPDIR:-/tmp}/auros-capture-facts.XXXXXX")" || die "mktemp failed"
trap 'rm -f "$FACTS_TMP"' EXIT HUP INT TERM
fact() { # <key> <value> <observed_from>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FACTS_TMP"
}
facts_text() { cat "$FACTS_TMP"; }

# probe <key> <abs-path> — read it, record it, echo it. Records a miss as a fact too, because
# "/sys/class/tpm/tpm0 is absent" is an observation and the next person needs to know we looked.
probe() {
  local key="$1" path="$2" v
  if v="$(rd "$path")" && [ -n "$v" ]; then
    fact "$key" "$v" "$path"
    printf '%s' "$v"
    return 0
  fi
  fact "$key" "" "$path (absent or unreadable)"
  return 1
}

is_junk() { # <value> — true if this is a DMI placeholder rather than data
  local v; v="$(lc "$1")"
  [ -z "$v" ] && return 0
  printf '%s' "$v" | grep -Eq "^(${DMI_JUNK})$"
}

slug() { # TSV-safe identifier: no tabs, no runs of whitespace, no leading/trailing punctuation
  printf '%s' "$1" \
    | tr '\t' ' ' \
    | sed -e 's/[[:space:]]\{1,\}/-/g' -e 's/[^A-Za-z0-9._+-]/-/g' \
          -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# ═══ PROBES ═════════════════════════════════════════════════════════════════════════════════════

DMI_DIR=/sys/class/dmi/id

probe_model() {
  local vendor product version composed
  vendor="$(probe dmi.sys_vendor "$DMI_DIR/sys_vendor" || true)"
  product="$(probe dmi.product_name "$DMI_DIR/product_name" || true)"
  version="$(probe dmi.product_version "$DMI_DIR/product_version" || true)"
  probe dmi.product_family "$DMI_DIR/product_family" >/dev/null || true
  probe dmi.board_name "$DMI_DIR/board_name" >/dev/null || true
  probe dmi.chassis_type "$DMI_DIR/chassis_type" >/dev/null || true

  if is_junk "$vendor" && is_junk "$product"; then
    die "no usable DMI identity. sys_vendor=[$vendor] product_name=[$product] product_version=[$version].
    $DMI_DIR contains: $(lsdir "$DMI_DIR")
    A row whose model came from a placeholder cannot be matched against the next machine, which is
    the entire point of the table. Read the label on the bottom of the laptop and pass --model."
  fi

  composed=""
  is_junk "$vendor"  || composed="$vendor"
  is_junk "$product" || composed="${composed:+$composed }$product"
  # product_version carries the human-recognisable name on Lenovo ("ThinkPad T440s" while
  # product_name is "20AQ006HUS"). Appended, never substituted, and only when it adds something.
  if ! is_junk "$version"; then
    case "$(lc "$composed")" in
      *"$(lc "$version")"*) ;;
      *) composed="${composed:+$composed }$version" ;;
    esac
  fi
  slug "$composed"
}

probe_year() {
  # DMI has no manufacture year. bios_date is the closest observable and it is NOT the same thing:
  # a 2012 laptop that took a 2018 firmware update reports 2018. So this is reported as a derived
  # value with its source named, and --year overrides it. Recorded rather than quietly assumed.
  local d y
  d="$(probe dmi.bios_date "$DMI_DIR/bios_date" || true)"
  [ -n "$d" ] || return 1
  y="$(printf '%s' "$d" | grep -Eo '[0-9]{4}' | tail -1)"
  [ -n "$y" ] || return 1
  fact year.derived "$y" "from dmi.bios_date=$d — firmware date, NOT the model year; confirm it"
  printf '%s' "$y"
}

probe_cpu() {
  local v
  v="$(grep -m1 -E '^(model name|Model Name|Processor)[[:space:]]*:' "$R/proc/cpuinfo" 2>/dev/null \
        | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/[[:space:]]*$//')"
  if [ -z "$v" ]; then
    # arm64 /proc/cpuinfo has no "model name". Fall back to the compatible string, which is exact.
    v="$(rd /sys/firmware/devicetree/base/compatible 2>/dev/null || true)"
    [ -n "$v" ] && { fact cpu "$v" "/sys/firmware/devicetree/base/compatible"; printf '%s' "$(slug "$v")"; return 0; }
    fact cpu "" "/proc/cpuinfo (no 'model name' line)"
    return 1
  fi
  fact cpu.raw "$v" "/proc/cpuinfo model name"
  # Deterministic text cleanup, not interpretation: drop the trademark noise and the clock speed
  # that x86 firmware appends, because "Intel(R) Core(TM) i5-4300U CPU @ 1.90GHz" and
  # "Intel(R) Core(TM) i5-4300U CPU @ 1.9GHz" are the same processor and must not become two rows.
  # The untouched string stays in the facts file as cpu.raw, so nothing is lost by this.
  local clean
  clean="$(printf '%s' "$v" \
    | sed -e 's/([RrCc]\{1,2\})//g' -e 's/(TM)//gI' -e 's/(tm)//g' \
          -e 's/[[:space:]]*@[[:space:]]*[0-9.]\{1,\}[[:space:]]*[GM]Hz//' \
          -e 's/ CPU / /g' -e 's/ CPU$//' -e 's/^CPU //' \
          -e 's/ Processor / /g' -e 's/ Processor$//' \
          -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
  [ -n "$clean" ] || clean="$v"
  fact cpu "$clean" "cpu.raw with trademark marks and clock speed removed"
  printf '%s' "$(slug "$clean")"
}

probe_ram_gb() {
  local kb gb
  kb="$(grep -m1 '^MemTotal:' "$R/proc/meminfo" 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
  if [ -z "$kb" ]; then
    fact ram_kb "" "/proc/meminfo (no MemTotal line)"
    return 1
  fi
  fact ram_kb "$kb" "/proc/meminfo MemTotal"
  # MemTotal is always BELOW installed RAM — firmware and the kernel reserve some — so this rounds
  # UP to the next whole GiB. 8 GiB installed reports ~7.7; 4 GiB reports ~3.8. Recorded with the
  # raw kB above so the arithmetic is checkable rather than trusted.
  gb=$(( (kb + 1048575) / 1048576 ))
  [ "$gb" -gt 0 ] || return 1
  fact ram_gb "$gb" "ceil(MemTotal / 1 GiB) — MemTotal excludes firmware-reserved memory"
  printf '%s' "$gb"
}

probe_firmware() {
  # uefi | uefi-sb | bios. NEVER uefi+csm: whether a UEFI-capable firmware booted us through a
  # compatibility module is not observable from a running Linux system. hardware/README.md lists
  # uefi+csm as a value, and a human who inspects the firmware setup screen may write it — this
  # script will not, because it would be a guess wearing the costume of a probe.
  local sb=""
  if [ -d "$R/sys/firmware/efi" ]; then
    fact firmware.efi present /sys/firmware/efi
    sb="$(secureboot_state)"   # secureboot_state records its OWN provenance fact, for the same
                               # subshell reason the facts file exists at all.
    case "$sb" in
      enabled)  printf 'uefi-sb' ;;
      disabled) printf 'uefi' ;;
      *)        printf 'uefi' ;;   # unknown SB state is still UEFI; the facts file carries the doubt
    esac
    return 0
  fi
  fact firmware.efi absent "/sys/firmware/efi (no such directory — booted in legacy/BIOS mode)"
  fact secureboot n/a "legacy boot has no Secure Boot"
  printf 'bios'
}

secureboot_state() {  # prints enabled|disabled|unknown AND records secureboot + its provenance
  # The EFI variable is 5 bytes: a 4-byte attribute prefix then one data byte, 1 = enabled. The GUID
  # is the EFI global variable namespace and is fixed, not guessed.
  local guid=8be4df61-93ca-11d2-aa0d-00e098032b8c
  local f="$R/sys/firmware/efi/efivars/SecureBoot-$guid"
  if [ -r "$f" ]; then
    local last
    last="$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' \n')"
    case "$last" in
      1) fact secureboot enabled  "$f byte 4 = 1"; printf 'enabled';  return 0 ;;
      0) fact secureboot disabled "$f byte 4 = 0"; printf 'disabled'; return 0 ;;
    esac
    fact secureboot unknown "$f exists but byte 4 read as [$last], expected 0 or 1"
    printf 'unknown'; return 0
  fi
  # mokutil is the other honest source. Probed, not assumed present.
  if command -v mokutil >/dev/null 2>&1; then
    local out; out="$(mokutil --sb-state 2>&1)"
    case "$(lc "$out")" in
      *"secureboot enabled"*)  fact secureboot enabled  "mokutil --sb-state: $out"; printf 'enabled';  return 0 ;;
      *"secureboot disabled"*) fact secureboot disabled "mokutil --sb-state: $out"; printf 'disabled'; return 0 ;;
    esac
  fi
  fact secureboot unknown "neither $f nor mokutil could answer. /sys/firmware/efi/efivars holds: $(lsdir /sys/firmware/efi/efivars)"
  printf 'unknown'
}

probe_tpm() {
  # 2.0 | 1.2 | none | (empty = a TPM is present but its version could not be read)
  local d=/sys/class/tpm/tpm0 maj caps
  if [ ! -d "$R$d" ]; then
    if [ -d "$R/sys/class/tpm" ]; then
      fact tpm none "/sys/class/tpm contains: $(lsdir /sys/class/tpm)"
    else
      fact tpm none "/sys/class/tpm (no such directory)"
    fi
    printf 'none'; return 0
  fi
  if maj="$(rd $d/tpm_version_major)" && [ -n "$maj" ]; then
    case "$maj" in
      2) fact tpm 2.0 "$d/tpm_version_major=2"; printf '2.0'; return 0 ;;
      1) fact tpm 1.2 "$d/tpm_version_major=1"; printf '1.2'; return 0 ;;
    esac
    fact tpm "" "$d/tpm_version_major=[$maj] — not 1 or 2, refusing to translate it"
    printf ''; return 0
  fi
  # Pre-4.x kernels expose a TPM 1.2 through caps instead. Read it rather than concluding from age.
  if caps="$(rd $d/caps)" && printf '%s' "$caps" | grep -qi '1\.2'; then
    fact tpm 1.2 "$d/caps: $caps"
    printf '1.2'; return 0
  fi
  fact tpm "" "$d exists but neither tpm_version_major nor caps gave a version. $d contains: $(lsdir $d)"
  printf ''
}

# ── numeric device IDs, never a marketing name ───────────────────────────────────────────────────
# "Intel Wireless" is not a model (skill driver-triage, GATE5-RUNBOOK step 1). These come straight
# out of sysfs as four hex digits each, which is what lspci -nn prints in brackets and what we can
# still match against a different laptop in four years. lspci is NOT required — it is not installed
# on a minimal bootc image, and needing it would be a guess about a CLI that may not exist.

pci_id() { # <sysfs device dir, absolute> -> vvvv:dddd
  local v d
  v="$(rd "$1/vendor")" || return 1
  d="$(rd "$1/device")" || return 1
  printf '%s:%s' "$(lc "${v#0x}")" "$(lc "${d#0x}")"
}

pci_by_class() { # <class prefix, e.g. 0x0300> -> one id per line
  local dir base cls
  for dir in "$R"/sys/bus/pci/devices/*; do
    [ -d "$dir" ] || continue
    base="${dir#$R}"
    cls="$(rd "$base/class")" || continue
    case "$(lc "$cls")" in
      "$1"*) pci_id "$base" && printf '\n' ;;
    esac
  done
}

wifi_ids() {
  # The exact answer first: a netdev with an 802.11 phy. This is the wifi, not something that looks
  # like one. Only if there is no wireless netdev do we fall back to the PCI class.
  local n base dev found=""
  for n in "$R"/sys/class/net/*; do
    [ -e "$n" ] || continue
    base="${n#$R}"
    if [ -d "$n/phy80211" ] || [ -d "$n/wireless" ]; then
      dev="$(cd "$n/device" 2>/dev/null && pwd -P)" || continue
      dev="${dev#$R}"
      local id; id="$(pci_id "$dev")" || continue
      fact "ids.wifi" "pci:$id" "$base/phy80211 -> $dev"
      found="${found:+$found,}pci:$id"
    fi
  done
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  # 0x0280 = "network controller, other", which is where every wifi card lives.
  local id
  for id in $(pci_by_class 0x0280); do
    fact "ids.wifi" "pci:$id" "/sys/bus/pci/devices/* class 0x0280 (no wireless netdev was up)"
    found="${found:+$found,}pci:$id"
  done
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  fact "ids.wifi" "" "no wireless netdev in /sys/class/net and no PCI class 0x0280 device. /sys/class/net holds: $(lsdir /sys/class/net)"
  return 1
}

class_ids() { # <role> <class prefix> <human name>
  local role="$1" cls="$2" found="" id
  for id in $(pci_by_class "$cls"); do
    fact "ids.$role" "pci:$id" "/sys/bus/pci/devices/* class $cls"
    found="${found:+$found,}pci:$id"
  done
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  fact "ids.$role" "" "no PCI device with class $cls ($3). /sys/bus/pci/devices holds: $(lsdir /sys/bus/pci/devices)"
  return 1
}

webcam_ids() {
  # USB interface class 0x0e is UVC video. Read the INTERFACE, then step up to the device for the
  # vendor/product pair — the interface directory has neither.
  local i base parent found="" v d
  for i in "$R"/sys/bus/usb/devices/*:*; do
    [ -d "$i" ] || continue
    base="${i#$R}"
    local ic; ic="$(rd "$base/bInterfaceClass")" || continue
    [ "$(lc "$ic")" = "0e" ] || continue
    parent="$(dirname "$base")/$(basename "$base" | sed 's/:.*//')"
    v="$(rd "$parent/idVendor")" || continue
    d="$(rd "$parent/idProduct")" || continue
    local id="usb:$(lc "$v"):$(lc "$d")"
    case ",$found," in *",$id,"*) continue ;; esac
    fact "ids.webcam" "$id" "$base/bInterfaceClass=0e -> $parent"
    found="${found:+$found,}$id"
  done
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  fact "ids.webcam" "" "no USB interface with bInterfaceClass 0e (UVC video). /sys/bus/usb/devices holds: $(lsdir /sys/bus/usb/devices)"
  return 1
}

probe_ids() {
  local parts="" v
  v="$(wifi_ids)"                       && parts="${parts:+$parts;}wifi=$v"
  v="$(class_ids gpu 0x0300 VGA)"       && parts="${parts:+$parts;}gpu=$v"
  v="$(class_ids audio 0x0403 audio)"   && parts="${parts:+$parts;}audio=$v"
  v="$(class_ids eth 0x0200 ethernet)"  && parts="${parts:+$parts;}eth=$v"
  v="$(webcam_ids)"                     && parts="${parts:+$parts;}webcam=$v"
  printf '%s' "$parts"
}

# ═══ THE PROMPTS ════════════════════════════════════════════════════════════════════════════════
# The exact words a person answers. Written out rather than summarised, because "does the wifi
# work?" and "does it associate to WPA2 on 5 GHz AND 2.4 GHz and stay up for sixty seconds?" produce
# different rows, and only the second one is worth quoting from.

prompt_for() {
  case "$1" in
    wifi)       cat <<'P'
Connect to a WPA2 network on 5 GHz, then to one on 2.4 GHz. Leave each associated for 60 seconds
and load a page. Then walk to the far end of the building and back.
  ok       both bands associate, stay up, and survive the walk
  partial  one band only, or it drops and recovers — say WHICH in the note
  fail     will not associate, or drops and does not recover
P
;;
    trackpad)   cat <<'P'
Move the pointer, tap to click, two-finger scroll, and then type a paragraph with your palms resting
where they normally rest.
  ok       pointer, tap-click and two-finger scroll all work, and the palm does not move the cursor
  partial  some of those — say WHICH in the note (palm rejection is the usual one)
  fail     no pointer, or unusable
P
;;
    suspend)    cat <<'P'
Shut the lid. Wait 60 seconds. Open it. Then do it again after the machine has been idle 30 minutes.
  ok       both times: resumes to the lock screen, wifi reassociates, display comes back
  partial  resumes but something does not come back — say WHAT in the note
  fail     does not resume, or resumes to a black screen, or the battery was flat
P
;;
    brightness) cat <<'P'
Press the brightness-down key until the screen is at its dimmest, then brightness-up to the top.
  ok       the keys change the actual backlight, all the way down and all the way up
  partial  the keys work but the range is wrong, or only the slider works and not the keys
  fail     the keys do nothing to the backlight
P
;;
    gpu)        cat <<'P'
Open the desktop, drag a window around, play a 1080p video full screen, plug in an external display.
  ok       smooth, no tearing, video plays without dropping frames, external display works
  partial  one of those is wrong — say WHICH in the note
  fail     software rendering, unusable desktop, or no external display at all
P
;;
    audio)      cat <<'P'
Play sound through the speakers, then plug in headphones, then unplug them. Test the volume keys and
the internal microphone.
  ok       speakers, headphone switching, volume keys and mic all work
  partial  some of those — say WHICH in the note
  fail     no sound out, or no mic
P
;;
    webcam)     cat <<'P'
Open the camera in a browser video call. Look at the picture.
  ok       a picture appears, right way up, at a usable frame rate
  partial  a picture appears but it is upside down, dark, or very slow — say WHICH
  fail     no picture
P
;;
  esac
}

print_prompts() {
  printf '\n── The seven a person has to answer ─────────────────────────────────────────────\n'
  printf 'In cost order. Wi-Fi failing makes the machine useless; a webcam failing makes it\n'
  printf 'slightly worse. Answer ok / partial / fail. `partial` REQUIRES a note saying which\n'
  printf 'half works — "associates on 2.4 GHz only" is a finding, "mostly works" is a feeling.\n'
  local c
  for c in $HUMAN_COLUMNS; do
    printf '\n\033[1m%s\033[0m\n' "$c"
    prompt_for "$c" | sed 's/^/  /'
  done
  printf '\nThen re-run with the answers, e.g.\n'
  printf '  %s \\\n' "$0"
  printf '    --wifi partial --note-wifi "associates on 2.4 GHz only, 5 GHz not seen" \\\n'
  printf '    --trackpad ok --suspend ok --brightness ok --gpu ok --audio ok --webcam fail \\\n'
  printf '    --tester "%s"\n' "${TESTER:-your-name}"
}

# ═══ ANSWERS ════════════════════════════════════════════════════════════════════════════════════
A_wifi=""; A_trackpad=""; A_suspend=""; A_brightness=""; A_gpu=""; A_audio=""; A_webcam=""
N_wifi=""; N_trackpad=""; N_suspend=""; N_brightness=""; N_gpu=""; N_audio=""; N_webcam=""

get_answer() { eval "printf '%s' \"\$A_$1\""; }
get_note()   { eval "printf '%s' \"\$N_$1\""; }
set_answer() { eval "A_$1=\$2"; }
set_note()   { eval "N_$1=\$2"; }

is_human_column() {
  case " $HUMAN_COLUMNS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

valid_answer() {
  case "$1" in ok|partial|fail) return 0 ;; *) return 1 ;; esac
}

load_answers_file() { # key=value / key: value, one per line, # comments. note-<col> for notes.
  local f="$1" line k v
  [ -r "$f" ] || die "--answers: cannot read $f. The directory holds: $(ls -A "$(dirname "$f")" 2>/dev/null | tr '\n' ' ')"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k="$(printf '%s' "$line" | sed -e 's/[:=].*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    v="$(printf '%s' "$line" | sed -e 's/^[^:=]*[:=][[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$k" in
      note-*) local col="${k#note-}"
              is_human_column "$col" || die "--answers $f: 'note-$col' names no column. The columns are: $HUMAN_COLUMNS"
              set_note "$col" "$v" ;;
      *)      is_human_column "$k" || die "--answers $f: '$k' is not a column a human answers. The columns are: $HUMAN_COLUMNS"
              valid_answer "$v" || die "--answers $f: $k=[$v]. Must be exactly ok, partial or fail. Empty means untested, and the way to say untested is to leave the line out."
              set_answer "$k" "$v" ;;
    esac
  done < "$f"
}

# ═══ THE ROW ════════════════════════════════════════════════════════════════════════════════════

emit_row() {
  local out="" col v
  for col in $COLUMNS; do
    case "$col" in
      model)     v="$MODEL" ;;
      year)      v="$YEAR" ;;
      source)    v="physical" ;;
      cpu)       v="$CPU" ;;
      ram_gb)    v="$RAM" ;;
      firmware)  v="$FIRMWARE" ;;
      ids)       v="$IDS" ;;
      tpm)       v="$TPM" ;;
      verdict)   v="$VERDICT" ;;
      notes)     v="$NOTES" ;;
      tested_on) v="$DATE" ;;
      tester)    v="$TESTER" ;;
      *)         if is_human_column "$col"; then v="$(get_answer "$col")"; else
                   die "internal: column '$col' is in COLUMNS but nothing fills it"
                 fi ;;
    esac

    # ── THE HARD REFUSAL ────────────────────────────────────────────────────────────────────────
    # A physical-only column may hold ONLY what a human passed in on this invocation. If one of them
    # is non-empty and no --<col> or answers-file entry set it, some probe has leaked into it and
    # the row is a fabrication. Refuse rather than print it: a bad row in this file is worse than no
    # row, because we would quote a school from it.
    case " $PHYSICAL_ONLY " in
      *" $col "*)
        if [ -n "$v" ] && [ "$v" != "$(get_answer "$col")" ]; then
          die "internal: column '$col' was filled with [$v] by something other than a human answer.
    $col is physical-only (hardware/README.md): no probe may fill it. Refusing to emit the row."
        fi
        if [ -n "$v" ] && ! valid_answer "$v"; then
          die "internal: $col=[$v] is not ok/partial/fail"
        fi ;;
    esac

    case "$v" in *"	"*) die "internal: column '$col' value contains a TAB, which would shift every later column: [$v]" ;; esac
    out="${out}${out:+	}${v}"
  done
  printf '%s\n' "$out"
}

compute_verdict() {
  # supported | supported-with-caveat | untested.
  # NEVER `unsupported`: that is §9-reserved for the human (spec §9, skill driver-triage). The tool
  # may PROPOSE it, below, with the evidence attached. It may not write it.
  local col a n_ok=0 n_bad=0 n_empty=0
  for col in $HUMAN_COLUMNS; do
    a="$(get_answer "$col")"
    case "$a" in
      ok)           n_ok=$((n_ok+1)) ;;
      partial|fail) n_bad=$((n_bad+1)) ;;
      *)            n_empty=$((n_empty+1)) ;;
    esac
  done
  if [ "$n_empty" -gt 0 ]; then printf 'untested'; return 0; fi
  if [ "$n_bad" -gt 0 ]; then printf 'supported-with-caveat'; return 0; fi
  printf 'supported'
}

# ═══ MAIN ═══════════════════════════════════════════════════════════════════════════════════════

MODEL=""; YEAR=""; TESTER=""; DATE=""; NOTES=""
FACTS_OUT=""; ROW_OUT=""; ROW_ONLY=0; WANT_PROMPTS=""; SHOW_HEADER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model)     MODEL="${2:-}"; shift 2 ;;
    --year)      YEAR="${2:-}";  shift 2 ;;
    --tester)    TESTER="${2:-}"; shift 2 ;;
    --date)      DATE="${2:-}";  shift 2 ;;
    --notes)     NOTES="${2:-}"; shift 2 ;;
    --answers)   load_answers_file "${2:-}"; shift 2 ;;
    --facts-out) FACTS_OUT="${2:-}"; shift 2 ;;
    --row-out)   ROW_OUT="${2:-}"; shift 2 ;;
    --row-only)  ROW_ONLY=1; shift ;;
    --header)    SHOW_HEADER=1; shift ;;
    --print-prompts) WANT_PROMPTS=1; shift ;;
    --note-*)    col="${1#--note-}"
                 is_human_column "$col" || die "$1 names no column. The columns are: $HUMAN_COLUMNS"
                 set_note "$col" "${2:-}"; shift 2 ;;
    --*)         col="${1#--}"
                 if is_human_column "$col"; then
                   valid_answer "${2:-}" || die "$1 ${2:-} — must be exactly ok, partial or fail. To say untested, omit the flag: empty is the honest value for a column nobody tried."
                   set_answer "$col" "${2:-}"; shift 2
                 else
                   die "unknown option $1. Human-answered columns are: $HUMAN_COLUMNS"
                 fi ;;
    -h|--help)   sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unexpected argument [$1]" ;;
  esac
done

if [ "$SHOW_HEADER" = 1 ]; then printf '%s\n' "$(printf '%s' "$COLUMNS" | tr ' ' '\t')"; exit 0; fi
if [ -n "$WANT_PROMPTS" ]; then TESTER="${TESTER:-${SUDO_USER:-${USER:-unknown}}}"; print_prompts; exit 0; fi

# `partial` without a note is not a finding. The runbook and the skill both say so; this enforces it,
# because the note is what makes the row quotable four years from now.
for col in $HUMAN_COLUMNS; do
  if [ "$(get_answer "$col")" = "partial" ] && [ -z "$(get_note "$col")" ]; then
    die "--$col partial needs --note-$col saying WHICH half works.
    \"associates on 2.4 GHz only\" is a finding. \"mostly works\" is a feeling, and a feeling in this
    file is what makes the next quote wrong."
  fi
done

# ── probe ────────────────────────────────────────────────────────────────────────────────────────
fact captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "date -u"
fact capture_host "$(rd /proc/sys/kernel/hostname || printf unknown)" "/proc/sys/kernel/hostname"
fact kernel "$(rd /proc/sys/kernel/osrelease || printf unknown)" "/proc/sys/kernel/osrelease"
[ -n "$R" ] && fact AUROS_TEST_ROOT "$R" "environment — THIS IS NOT A REAL MACHINE"

PROBED_MODEL="$(probe_model)"
MODEL="${MODEL:-$PROBED_MODEL}"
[ -n "$MODEL" ] || die "no model. Pass --model."

PROBED_YEAR="$(probe_year || true)"
YEAR="${YEAR:-$PROBED_YEAR}"

CPU="$(probe_cpu || true)"
RAM="$(probe_ram_gb || true)"
FIRMWARE="$(probe_firmware)"
TPM="$(probe_tpm)"
IDS="$(probe_ids)"
DATE="${DATE:-$(date +%F)}"
TESTER="${TESTER:-${SUDO_USER:-${USER:-unknown}}}"
VERDICT="$(compute_verdict)"

# Notes: the tool composes the caveats it was TOLD, never ones it inferred.
auto_notes=""
for col in $HUMAN_COLUMNS; do
  n="$(get_note "$col")"
  [ -n "$n" ] && auto_notes="${auto_notes:+$auto_notes; }$col: $n"
done
if [ -z "$NOTES" ]; then NOTES="$auto_notes"; elif [ -n "$auto_notes" ]; then NOTES="$NOTES; $auto_notes"; fi
NOTES="$(printf '%s' "$NOTES" | tr '\t' ' ')"

ROW="$(emit_row)" || exit $?

[ -n "$FACTS_OUT" ] && { { printf 'fact\tvalue\tobserved_from\n'; facts_text; } > "$FACTS_OUT" || die "cannot write --facts-out $FACTS_OUT"; }
[ -n "$ROW_OUT" ]   && { printf '%s\n' "$ROW" > "$ROW_OUT" || die "cannot write --row-out $ROW_OUT"; }

if [ "$ROW_ONLY" = 1 ]; then printf '%s\n' "$ROW"; exit 0; fi

# ── report ───────────────────────────────────────────────────────────────────────────────────────
printf '\n\033[1m── observed ───────────────────────────────────────────────────────────────────\033[0m\n'
facts_text | awk -F'\t' '{ printf "  %-18s %-34s %s\n", $1, ($2==""?"(none)":$2), $3 }'
if [ -n "$PROBED_YEAR" ] && [ "$YEAR" = "$PROBED_YEAR" ]; then
  printf '\n  \033[33myear=%s came from the BIOS date, which is not the model year.\033[0m\n' "$YEAR"
  printf '  A 2012 laptop with a 2018 firmware update reports 2018. Confirm it against the label\n'
  printf '  on the bottom of the machine and pass --year if it is wrong.\n'
fi

printf '\n\033[1m── the row so far ─────────────────────────────────────────────────────────────\033[0m\n'
printf '%s\n' "$(printf '%s' "$COLUMNS" | tr ' ' '\t')"
printf '%s\n' "$ROW"

n_empty=0
for col in $HUMAN_COLUMNS; do [ -z "$(get_answer "$col")" ] && n_empty=$((n_empty+1)); done
if [ "$n_empty" -gt 0 ]; then
  printf '\n\033[1m%d of the 7 human columns are EMPTY, and empty is correct.\033[0m\n' "$n_empty"
  printf 'Empty means "nobody tried this", which is true. This tool will not fill them from probing:\n'
  printf 'a loaded module is not a working card, and a table of inferences reads exactly like a table\n'
  printf 'of observations until a school finds out. verdict stays "untested" until all seven are in.\n'
  print_prompts
else
  printf '\nAll seven answered. verdict=%s\n' "$VERDICT"
  if [ "$(get_answer wifi)" = "fail" ]; then
    printf '\n\033[1mPROPOSAL for the human (spec §9):\033[0m wifi=fail. A laptop that cannot join the school\n'
    printf 'network is arguably verdict=unsupported — but declaring a model unsupported decides what we\n'
    printf 'refuse to sell, which is a business decision wearing a technical costume. This tool will not\n'
    printf 'write it. Take the row and the facts file to the human.\n'
  fi
  printf '\nAppend the row to hardware/compat.tsv, then run:  node tools/compat-lint.mjs\n'
fi
[ -n "$FACTS_OUT" ] && printf '\nfacts written to %s\n' "$FACTS_OUT"
exit 0

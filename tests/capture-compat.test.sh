#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/capture-compat.test.sh — tools/capture-compat.sh, driven against synthetic machines.
#
#   bash auros-base/tests/capture-compat.test.sh        (or tests/run-all.sh, which picks it up)
#
# WHAT IS ACTUALLY AT RISK HERE, and it is not a build failing.
#
# capture-compat.sh writes rows into hardware/compat.tsv, which spec §8 calls the thing competitors
# cannot copy quickly and the thing we quote schools from. Every failure mode of this script is
# SILENT and only shows up months later, in front of a customer:
#
#   * a probe quietly filling `wifi` from a loaded module          → we quote a laptop we never tested
#   * a marketing name in `ids`                                    → the row matches nothing, ever
#   * `uefi+csm` inferred from inside a running system             → a firmware claim nobody checked
#   * an empty facts file that looks exactly like a full one       → no evidence behind any of it
#
# None of those turn anything red on their own. So this suite drives the script into each of them on
# purpose, including by MUTATING THE SCRIPT ITSELF where the property has no natural refusal path —
# because a guard that has never been seen to fire is indistinguishable from a comment.
#
# The harness's direction audit (t_finish) fails this suite for any check id observed in only one
# direction. See tests/lib/harness.sh.
#
# RUNTIME, measured rather than guessed: ~47 s of CPU, but **3m47s of wall clock on macOS** — it is
# roughly 2,500 short-lived processes and a Mac spends most of that in process creation (20% CPU
# utilisation across the whole run). On a Linux runner, where spawning is two orders of magnitude
# cheaper, it is seconds. It is the slowest suite in tests/ by a wide margin, and that is a property
# of the laptop rather than of the suite. Stated here so a slow local `run-all.sh` is read as what it
# is; if it ever needs to be cheap on macOS, the lever is fewer `capture` invocations, not fewer
# assertions.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

TOOL="$REPO/tools/capture-compat.sh"
[ -f "$TOOL" ] || t_abort "no such file: $TOOL — $REPO/tools contains: $(ls -A "$REPO/tools" 2>/dev/null | tr '\n' ' ')"

# ── the schema comes OUT OF THE SCRIPT, never out of this test ───────────────────────────────────
# A column list copied here drifts from the shipping one within a week, and then every field
# assertion below reads the wrong column and passes anyway. extract_lines aborts on no match.
COLUMNS_LINE="$(extract_lines "$TOOL" '^COLUMNS=')"
COLUMNS="$(printf '%s' "$COLUMNS_LINE" | sed -e 's/^COLUMNS="//' -e 's/"$//')"
HUMAN_LINE="$(extract_lines "$TOOL" '^HUMAN_COLUMNS=')"
HUMAN_COLUMNS="$(printf '%s' "$HUMAN_LINE" | sed -e 's/^HUMAN_COLUMNS="//' -e 's/"$//')"
PHYS_LINE="$(extract_lines "$TOOL" '^PHYSICAL_ONLY=')"
PHYSICAL_ONLY="$(printf '%s' "$PHYS_LINE" | sed -e 's/^PHYSICAL_ONLY="//' -e 's/"$//')"

col_index() { # <name> -> 1-based position in COLUMNS
  local i=1 c
  for c in $COLUMNS; do
    [ "$c" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i+1))
  done
  t_abort "column '$1' is not in the shipping COLUMNS list, which is: $COLUMNS"
}

field() { # <tsv row> <column name>
  local i; i="$(col_index "$2")"
  printf '%s' "$1" | awk -F'\t' -v n="$i" '{ print $n }'
}

# ── synthetic machines ───────────────────────────────────────────────────────────────────────────
# Every path written here was read out of the script under test, not remembered. If one of them is
# wrong the assertion below fails LOUDLY rather than the probe quietly returning empty, because the
# facts file records "absent or unreadable" against the exact path it tried.

mkmachine() { # -> prints the root dir. Options as KEY=VALUE arguments; see the case below.
  local d; d="$(newroot)"
  mkdir -p "$d/sys/class/dmi/id" "$d/proc/sys/kernel" "$d/sys/bus/pci/devices" \
           "$d/sys/class/net" "$d/sys/bus/usb/devices" "$d/sys/class/tpm"

  # A plausible 2014 business laptop, which is the machine this product exists for.
  printf 'LENOVO\n'          > "$d/sys/class/dmi/id/sys_vendor"
  printf '20AQ006HUS\n'      > "$d/sys/class/dmi/id/product_name"
  printf 'ThinkPad T440s\n'  > "$d/sys/class/dmi/id/product_version"
  printf '03/12/2014\n'      > "$d/sys/class/dmi/id/bios_date"
  printf 'model name\t: Intel(R) Core(TM) i5-4300U CPU @ 1.90GHz\n' > "$d/proc/cpuinfo"
  printf 'MemTotal:        8018344 kB\n' > "$d/proc/meminfo"
  printf 'lab-01\n'          > "$d/proc/sys/kernel/hostname"
  printf '6.11.4-200.fc40.x86_64\n' > "$d/proc/sys/kernel/osrelease"

  local o
  for o in "$@"; do
    case "$o" in
      dmi-junk)
        printf 'System manufacturer\n' > "$d/sys/class/dmi/id/sys_vendor"
        printf 'System Product Name\n' > "$d/sys/class/dmi/id/product_name"
        printf 'Default string\n'      > "$d/sys/class/dmi/id/product_version" ;;
      no-dmi)
        rm -f "$d/sys/class/dmi/id/sys_vendor" "$d/sys/class/dmi/id/product_name" \
              "$d/sys/class/dmi/id/product_version" ;;
      efi-sb-on)   _efi "$d" 1 ;;
      efi-sb-off)  _efi "$d" 0 ;;
      efi-no-var)  mkdir -p "$d/sys/firmware/efi/efivars" ;;
      legacy-bios) : ;;                              # the absence of /sys/firmware/efi IS the fact
      tpm2)        mkdir -p "$d/sys/class/tpm/tpm0"; printf '2\n' > "$d/sys/class/tpm/tpm0/tpm_version_major" ;;
      tpm12-caps)  mkdir -p "$d/sys/class/tpm/tpm0"; printf 'Manufacturer: 0x53544d20\nTCG version: 1.2\n' > "$d/sys/class/tpm/tpm0/caps" ;;
      tpm-garbage) mkdir -p "$d/sys/class/tpm/tpm0"; printf '7\n' > "$d/sys/class/tpm/tpm0/tpm_version_major" ;;
      no-tpm)      : ;;
      pci-full)
        _pci "$d" 0000:03:00.0 8086 08b1 028000
        _pci "$d" 0000:00:02.0 8086 0a16 030000
        _pci "$d" 0000:00:03.0 8086 0a0c 040300
        _pci "$d" 0000:00:19.0 8086 1559 020000 ;;
      wlan-netdev)
        mkdir -p "$d/sys/class/net/wlp3s0/phy80211"
        ln -s ../../../bus/pci/devices/0000:03:00.0 "$d/sys/class/net/wlp3s0/device" ;;
      webcam)
        mkdir -p "$d/sys/bus/usb/devices/1-1" "$d/sys/bus/usb/devices/1-1:1.0"
        printf '04f2\n' > "$d/sys/bus/usb/devices/1-1/idVendor"
        printf 'b39a\n' > "$d/sys/bus/usb/devices/1-1/idProduct"
        printf '0e\n'   > "$d/sys/bus/usb/devices/1-1:1.0/bInterfaceClass" ;;
      usb-not-a-webcam)
        mkdir -p "$d/sys/bus/usb/devices/2-1" "$d/sys/bus/usb/devices/2-1:1.0"
        printf '0bda\n' > "$d/sys/bus/usb/devices/2-1/idVendor"
        printf '0129\n' > "$d/sys/bus/usb/devices/2-1/idProduct"
        printf '08\n'   > "$d/sys/bus/usb/devices/2-1:1.0/bInterfaceClass" ;;   # mass storage
      *) t_abort "mkmachine: unknown option '$o'" ;;
    esac
  done
  printf '%s' "$d"
}

_efi() { # <root> <secure boot byte: 0 or 1>
  mkdir -p "$1/sys/firmware/efi/efivars"
  # 4 attribute bytes then the data byte, which is how the kernel presents every efivar. Written as
  # two literal cases rather than an octal escape built from "$2": `printf '\%03o'` is not an escape
  # sequence, it emits those characters, so the fixture wrote "Secure Boot OFF" while claiming to
  # write ON — a FIXTURE bug that is indistinguishable, from the failure line, from a bug in the
  # code under test. Worth the six lines.
  local f="$1/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  case "$2" in
    1) printf '\006\000\000\000\001' > "$f" ;;
    0) printf '\006\000\000\000\000' > "$f" ;;
    *) t_abort "_efi: secure boot byte must be 0 or 1, got [$2]" ;;
  esac
}

_pci() { # <root> <bdf> <vendor> <device> <class>
  local p="$1/sys/bus/pci/devices/$2"; mkdir -p "$p"
  printf '0x%s\n' "$3" > "$p/vendor"; printf '0x%s\n' "$4" > "$p/device"; printf '0x%s\n' "$5" > "$p/class"
}

capture() { # <root> [args...] -> the row on stdout
  local root="$1"; shift
  AUROS_TEST_ROOT="$root" bash "$TOOL" --row-only --tester t --date 2026-09-21 "$@"
}

# run_capture <id> <green|red> <label> <root> [args...]
run_capture() {
  local id="$1" want="$2" label="$3" root="$4"; shift 4
  run_check "$id" "$want" "$label" -- env AUROS_TEST_ROOT="$root" bash "$TOOL" --row-only --tester t --date 2026-09-21 "$@"
}

group "the schema the script ships is the schema this test reads"
note "COLUMNS         $COLUMNS"
note "HUMAN_COLUMNS   $HUMAN_COLUMNS"
note "PHYSICAL_ONLY   $PHYSICAL_ONLY"

# The row must line up with the real hardware/compat.tsv, which lives in the META repo — a different
# git repository (D6), so it may legitimately not be checked out beside this one. Absent, we say so
# rather than skipping quietly: an unchecked schema is exactly how a row lands in the wrong columns.
REAL_TSV=""
for c in "$REPO/../hardware/compat.tsv" "$REPO/../../hardware/compat.tsv" "${AUROS_COMPAT_TSV:-}"; do
  [ -n "$c" ] && [ -f "$c" ] && { REAL_TSV="$c"; break; }
done
if [ -n "$REAL_TSV" ]; then
  real_header="$(head -1 "$REAL_TSV")"
  mine="$(printf '%s' "$COLUMNS" | tr ' ' '\t')"
  assert_eq "COLUMNS matches the header of $REAL_TSV" "$real_header" "$mine"
else
  note "hardware/compat.tsv not checked out beside auros-base — the column-order assertion did NOT run."
  note "Looked at: $REPO/../hardware/compat.tsv and $REPO/../../hardware/compat.tsv"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "1 — the observable columns are filled from a named path, or not at all"

M="$(mkmachine efi-sb-on tpm2 pci-full wlan-netdev webcam)"
ROW="$(capture "$M")"
assert_eq "model is vendor + product + the human-recognisable version" \
  "LENOVO-20AQ006HUS-ThinkPad-T440s" "$(field "$ROW" model)"
assert_eq "source is always physical — this script only runs on a real machine" \
  "physical" "$(field "$ROW" source)"
assert_eq "year comes from the BIOS date" "2014" "$(field "$ROW" year)"
assert_eq "cpu drops the trademark noise and the clock speed" \
  "Intel-Core-i5-4300U" "$(field "$ROW" cpu)"
assert_eq "ram_gb rounds MemTotal UP — 8018344 kB is an 8 GB machine" "8" "$(field "$ROW" ram_gb)"
assert_eq "tested_on and tester are what was passed in" "2026-09-21" "$(field "$ROW" tested_on)"

group "the facts file carries a path behind every value"
FACTS="$M/facts.tsv"
AUROS_TEST_ROOT="$M" bash "$TOOL" --row-only --tester t --facts-out "$FACTS" >/dev/null
assert_file "a facts file is written" "$FACTS"
# This is the assertion that catches the bug the facts file already had once: every probe runs
# inside `$( )`, so a facts ACCUMULATOR held in a shell variable is discarded by the subshell and
# the file comes out empty while the script looks like it is recording everything.
n_facts="$(grep -c . "$FACTS")"
if [ "$n_facts" -gt 12 ]; then ok "the facts file has $n_facts entries, not the empty file a subshell would leave"
else bad "the facts file has only $n_facts entries — probes are recording into a subshell again"; fi
assert_has "every fact names where it was read" "/sys/class/dmi/id/sys_vendor" "$(cat "$FACTS")"
assert_has "a MISS is recorded too, with the path that was tried" "absent or unreadable" "$(cat "$FACTS")"
assert_has "the raw cpu string is kept, so the cleanup is checkable" "Intel(R) Core(TM) i5-4300U" "$(cat "$FACTS")"
assert_has "the test root is recorded loudly — this is not a real machine" "THIS IS NOT A REAL MACHINE" "$(cat "$FACTS")"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "2 — firmware and Secure Boot: read, never inferred"

assert_eq "Secure Boot enabled reads as uefi-sb" "uefi-sb" \
  "$(field "$(capture "$(mkmachine efi-sb-on)")" firmware)"
assert_eq "Secure Boot disabled reads as uefi, not uefi-sb" "uefi" \
  "$(field "$(capture "$(mkmachine efi-sb-off)")" firmware)"
assert_eq "no /sys/firmware/efi at all is bios" "bios" \
  "$(field "$(capture "$(mkmachine legacy-bios)")" firmware)"
assert_eq "efivars present but no SecureBoot variable is still uefi" "uefi" \
  "$(field "$(capture "$(mkmachine efi-no-var)")" firmware)"

M2="$(mkmachine efi-no-var)"; F2="$M2/f.tsv"
AUROS_TEST_ROOT="$M2" bash "$TOOL" --row-only --facts-out "$F2" >/dev/null
assert_has "an unreadable Secure Boot state is recorded as unknown, with what WAS there" \
  "secureboot	unknown" "$(cat "$F2")"

# uefi+csm is the value hardware/README.md lists that NO probe may produce. Asserted against every
# machine shape, because "it never happened to come out" is not the same as "it cannot".
csm_seen=0
for shape in efi-sb-on efi-sb-off legacy-bios efi-no-var; do
  fw="$(field "$(capture "$(mkmachine "$shape")")" firmware)"
  [ "$fw" = "uefi+csm" ] && csm_seen=1
done
if [ "$csm_seen" = 0 ]; then ok "no machine shape makes the script emit uefi+csm — a human writes that one"
else bad "the script emitted uefi+csm, which is not observable from inside a running system"; fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "3 — tpm: two generations, or nothing, or an honest blank"

assert_eq "tpm_version_major=2 is 2.0"    "2.0"  "$(field "$(capture "$(mkmachine tpm2)")" tpm)"
assert_eq "caps saying TCG version 1.2"   "1.2"  "$(field "$(capture "$(mkmachine tpm12-caps)")" tpm)"
assert_eq "no /sys/class/tpm/tpm0 is none" "none" "$(field "$(capture "$(mkmachine no-tpm)")" tpm)"
# The interesting one. A TPM is present and its version is unreadable: that is a THIRD state, and
# collapsing it into `none` would be a claim ("there is no TPM") built out of a failed read.
assert_eq "a TPM whose version cannot be read leaves tpm EMPTY, not none" "" \
  "$(field "$(capture "$(mkmachine tpm-garbage)")" tpm)"
MG="$(mkmachine tpm-garbage)"; FG="$MG/f.tsv"
AUROS_TEST_ROOT="$MG" bash "$TOOL" --row-only --facts-out "$FG" >/dev/null
assert_has "and it says what it DID find" "tpm_version_major=[7]" "$(cat "$FG")"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "4 — ids are numeric, come from the right device, and say which path found them"

IDS="$(field "$(capture "$(mkmachine pci-full wlan-netdev webcam)")" ids)"
assert_has "wifi is the card behind the 802.11 netdev" "wifi=pci:8086:08b1" "$IDS"
assert_has "gpu from PCI class 0x0300"                 "gpu=pci:8086:0a16"  "$IDS"
assert_has "audio from PCI class 0x0403"               "audio=pci:8086:0a0c" "$IDS"
assert_has "ethernet from PCI class 0x0200"            "eth=pci:8086:1559"  "$IDS"
assert_has "webcam from USB interface class 0e"        "webcam=usb:04f2:b39a" "$IDS"

# A marketing name can never appear, because nothing in the script has access to one: every id is
# built from two four-hex-digit sysfs files. Asserted anyway, as the property rather than the code.
if printf '%s' "$IDS" | grep -Eq '^([a-z]+=(pci|usb):[0-9a-f]{4}:[0-9a-f]{4}(,(pci|usb):[0-9a-f]{4}:[0-9a-f]{4})*)(;[a-z]+=(pci|usb):[0-9a-f]{4}:[0-9a-f]{4}(,(pci|usb):[0-9a-f]{4}:[0-9a-f]{4})*)*$'
then ok "every ids entry is role=bus:vvvv:dddd in lowercase hex"
else bad "ids does not match the numeric shape compat-lint requires: [$IDS]"; fi

IDS_NOCAM="$(field "$(capture "$(mkmachine pci-full wlan-netdev usb-not-a-webcam)")" ids)"
assert_not "a USB mass-storage device is not reported as a webcam" "webcam=" "$IDS_NOCAM"
assert_not "and it is not reported under any other role either"    "usb:0bda" "$IDS_NOCAM"

MF="$(mkmachine pci-full)"; FF="$MF/f.tsv"
AUROS_TEST_ROOT="$MF" bash "$TOOL" --row-only --facts-out "$FF" >/dev/null
assert_has "with no wireless netdev it falls back to PCI class AND says so" \
  "no wireless netdev was up" "$(cat "$FF")"
MW="$(mkmachine pci-full wlan-netdev)"; FW="$MW/f.tsv"
AUROS_TEST_ROOT="$MW" bash "$TOOL" --row-only --facts-out "$FW" >/dev/null
assert_has "with one, the provenance names the netdev it came from" "phy80211" "$(cat "$FW")"

MN="$(mkmachine)"; FN="$MN/f.tsv"
AUROS_TEST_ROOT="$MN" bash "$TOOL" --row-only --facts-out "$FN" >/dev/null
assert_has "a machine with no PCI devices says what /sys/bus/pci/devices held" \
  "/sys/bus/pci/devices holds" "$(cat "$FN")"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "5 — THE POINT OF THE TOOL: the human columns stay empty"

ROW_BARE="$(capture "$(mkmachine efi-sb-on tpm2 pci-full wlan-netdev webcam)")"
for c in $HUMAN_COLUMNS; do
  assert_eq "$c is EMPTY when nobody answered it" "" "$(field "$ROW_BARE" "$c")"
done
assert_eq "verdict stays untested while any of the seven is empty" "untested" "$(field "$ROW_BARE" verdict)"

# And the same machine, with a person's answers, DOES fill them — the control that proves the four
# teen assertions above are not simply a script that produces empty columns.
ROW_FULL="$(capture "$(mkmachine efi-sb-on tpm2 pci-full wlan-netdev webcam)" \
  --wifi ok --trackpad ok --suspend ok --brightness ok --gpu ok --audio ok --webcam ok)"
for c in $HUMAN_COLUMNS; do
  assert_eq "$c is filled when a person answered it" "ok" "$(field "$ROW_FULL" "$c")"
done
assert_eq "all seven ok gives verdict=supported" "supported" "$(field "$ROW_FULL" verdict)"

ROW_MIX="$(capture "$(mkmachine pci-full)" --wifi ok --trackpad ok --suspend ok \
  --brightness partial --note-brightness "lowest step is still bright" \
  --gpu ok --audio ok --webcam fail)"
assert_eq "one failure gives verdict=supported-with-caveat" "supported-with-caveat" "$(field "$ROW_MIX" verdict)"
assert_has "the note reaches the notes column, attributed to its column" \
  "brightness: lowest step is still bright" "$(field "$ROW_MIX" notes)"
assert_eq "an unanswered column among answered ones is still empty" "" \
  "$(field "$(capture "$(mkmachine pci-full)" --wifi ok)" webcam)"
assert_eq "…and drags verdict back to untested" "untested" \
  "$(field "$(capture "$(mkmachine pci-full)" --wifi ok)" verdict)"

# unsupported is §9. The tool may propose it; it may not write it. Exercised on the shape most
# likely to tempt it — a machine that cannot join the network.
ROW_NOWIFI="$(capture "$(mkmachine pci-full)" --wifi fail --trackpad ok --suspend ok \
  --brightness ok --gpu ok --audio ok --webcam ok)"
assert_eq "wifi=fail does NOT become verdict=unsupported" "supported-with-caveat" "$(field "$ROW_NOWIFI" verdict)"
PROPOSAL="$(AUROS_TEST_ROOT="$(mkmachine pci-full)" bash "$TOOL" --tester t --wifi fail --trackpad ok \
  --suspend ok --brightness ok --gpu ok --audio ok --webcam ok 2>&1)"
assert_has "but it is PROPOSED to the human, with the reason" "PROPOSAL for the human" "$PROPOSAL"
assert_has "and the proposal says why it is not the tool's call" "business decision" "$PROPOSAL"

group "--ask, because the person has a laptop open and not a shell open"
# The flag form is eight arguments to compose while holding a screwdriver, and a tool that is
# annoying AT the machine gets filled in afterwards from memory — which is precisely the row this
# whole file exists to prevent. So there is an interactive mode, and it has to enforce the same
# rules in the same place rather than growing a parallel copy of them.
ask() { # <answers on stdin> <root> [args...] -> the row on stdout, prompts on stderr
  local input="$1" root="$2"; shift 2
  printf '%s' "$input" | env AUROS_TEST_ROOT="$root" bash "$TOOL" --ask --row-only --tester t --date 2026-09-21 "$@" 2>/dev/null
}
run_ask() { # <id> <green|red> <label> <input> <root>
  local id="$1" want="$2" label="$3" input="$4" root="$5"
  run_check "$id" "$want" "$label" -- bash -c \
    'printf "%s" "$1" | AUROS_TEST_ROOT="$2" bash "$3" --ask --row-only --tester t' _ "$input" "$root" "$TOOL"
}

ALL_OK="ok
ok
ok
ok
ok
ok
ok
"
run_ask ask-mode green "seven straight answers" "$ALL_OK" "$(mkmachine pci-full)"
ROW_ASK="$(ask "$ALL_OK" "$(mkmachine pci-full)")"
assert_eq "…fills every human column" "ok" "$(field "$ROW_ASK" webcam)"
assert_eq "…and computes the verdict" "supported" "$(field "$ROW_ASK" verdict)"
assert_eq "--row-only --ask puts NOTHING but the row on stdout" "1" \
  "$(printf '%s\n' "$ROW_ASK" | grep -c .)"

# SKIP has to be easy to say, or somebody gives a wrong answer instead of an empty one.
ROW_SKIP="$(ask "ok
skip
ok
ok
ok
ok
ok
" "$(mkmachine pci-full)")"
assert_eq "skip leaves the column EMPTY" "" "$(field "$ROW_SKIP" trackpad)"
assert_eq "…and one skip holds the verdict at untested" "untested" "$(field "$ROW_SKIP" verdict)"

# An invented answer is re-asked rather than accepted or silently dropped.
ROW_RETRY="$(ask "WOBBLE
ok
ok
ok
ok
ok
ok
ok
" "$(mkmachine pci-full)")"
assert_eq "an invented answer is re-asked, and the NEXT answer lands in that column" "ok" \
  "$(field "$ROW_RETRY" wifi)"
RETRY_ERR="$(printf 'yes\nok\nok\nok\nok\nok\nok\nok\n' | env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --ask --row-only --tester t 2>&1 >/dev/null)"
assert_has "and the person is told what IS allowed" "Answer ok, partial, fail, or skip" "$RETRY_ERR"
assert_has "quoting back what they typed" "Got [yes]" "$RETRY_ERR"

# partial without a note is refused HERE too, interactively, and re-asks rather than proceeding.
ROW_PARTIAL="$(ask "partial

partial
associates on 2.4 GHz only
ok
ok
ok
ok
ok
ok
" "$(mkmachine pci-full)")"
assert_eq "an empty note sends it back round, and the second attempt sticks" "partial" \
  "$(field "$ROW_PARTIAL" wifi)"
assert_has "the note lands in notes" "associates on 2.4 GHz only" "$(field "$ROW_PARTIAL" notes)"

# The red half: stdin ending mid-question must refuse and write nothing, not emit a half-row.
run_ask ask-mode red "stdin ends before the seventh question" "ok
ok
ok
" "$(mkmachine pci-full)"
EOF_ERR="$(printf 'ok\n' | env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --ask --row-only --tester t 2>&1 >/dev/null)"
assert_has "the refusal names the column it was asking about" "while asking about 'trackpad'" "$EOF_ERR"
assert_has "…says nothing was written" "Nothing was written" "$EOF_ERR"
assert_has "…and gives the flag form as the way out" "--trackpad ok|partial|fail" "$EOF_ERR"
run_ask ask-mode red "stdin ends while asking for a partial's note" "partial
" "$(mkmachine pci-full)"

group "the prompts are printed, in cost order, as words a person can act on"
PROMPTS="$(bash "$TOOL" --print-prompts)"
for c in $HUMAN_COLUMNS; do assert_has "the prompt for $c is printed" "$c" "$PROMPTS"; done
assert_has "the prompt asks for a specific observation, not an impression" "60 seconds" "$PROMPTS"
assert_has "and says what partial requires" "is a feeling" "$PROMPTS"
# The headings are printed bold, so the ESC byte has to go before sed can match them. `tr -d '\033'`
# deletes exactly one character — NOT `tr -d '[:space:]'`, which also deletes newlines and is the
# idiom that made a hardening check permanently green (D19/D34).
plain_prompts="$(printf '%s' "$PROMPTS" | tr -d '\033')"
heading_order="$(printf '%s' "$plain_prompts" | sed -n 's/^\[1m\([a-z]*\)\[0m$/\1/p' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the seven are asked in COST order — wifi first, webcam last" \
  "$HUMAN_COLUMNS" "$heading_order"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "6 — refusals: each one watched going red, and green on the input it should accept"

run_capture dmi-identity green "usable DMI is accepted"            "$(mkmachine)"
run_capture dmi-identity red   "DMI full of vendor placeholders"   "$(mkmachine dmi-junk)"
run_capture dmi-identity red   "no DMI identity files at all"      "$(mkmachine no-dmi)"
JUNK_OUT="$(AUROS_TEST_ROOT="$(mkmachine dmi-junk)" bash "$TOOL" --row-only 2>&1)"
assert_has "the DMI refusal prints what IS in /sys/class/dmi/id" "contains:" "$JUNK_OUT"
assert_has "and names the placeholder it saw"                    "System Product Name" "$JUNK_OUT"
# The control for the refusal: --model is the documented way past it, and it must work, or the
# person with the laptop open in front of them has no route forward.
run_capture dmi-identity green "--model overrides unusable DMI"   "$(mkmachine dmi-junk)" --model Latitude-E6430

run_capture answer-vocab green "--wifi ok"        "$(mkmachine)" --wifi ok
run_capture answer-vocab green "--wifi fail"      "$(mkmachine)" --wifi fail
run_capture answer-vocab red   "--wifi yes"       "$(mkmachine)" --wifi yes
run_capture answer-vocab red   "--wifi works"     "$(mkmachine)" --wifi works
run_capture answer-vocab red   "--wifi '' (empty means untested, and the way to say it is to omit the flag)" \
  "$(mkmachine)" --wifi ""

run_capture partial-note green "--wifi partial WITH a note" "$(mkmachine)" --wifi partial --note-wifi "2.4 GHz only"
run_capture partial-note red   "--wifi partial with NO note" "$(mkmachine)" --wifi partial
NOTE_OUT="$(AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --wifi partial 2>&1)"
assert_has "the refusal says what a usable note looks like" "associates on 2.4 GHz only" "$NOTE_OUT"

run_capture unknown-flag green "a known human column"  "$(mkmachine)" --trackpad ok
run_capture unknown-flag red   "--wobble, which is no column" "$(mkmachine)" --wobble ok
run_capture unknown-flag red   "--note-wobble, which is no column's note" "$(mkmachine)" --note-wobble x
# --help was reached by the generic `--*` arm and answered "unknown option --help", because `case`
# takes the FIRST matching pattern and `-h|--help` was written last. Nothing about reading the file
# showed that; running it did. Both of these run BEFORE any probe, so they need no machine.
run_check unknown-flag green "--help prints the header comment" -- bash "$TOOL" --help
run_check unknown-flag green "--header prints the schema"       -- bash "$TOOL" --header
assert_eq "--header is exactly the shipping COLUMNS list" \
  "$(printf '%s' "$COLUMNS" | tr ' ' '\t')" "$(bash "$TOOL" --header)"
assert_has "--help says where the line between probe and person is drawn" "HUMAN-ONLY" "$(bash "$TOOL" --help)"

group "the answers file"
AD="$(newroot)"
printf '# a tester filling this in on the machine\nwifi: ok\ntrackpad = ok\nnote-wifi: 5 GHz roams cleanly\n' > "$AD/good"
printf 'wifi: yes\n' > "$AD/bad-value"
printf 'wobble: ok\n' > "$AD/bad-key"
printf 'wifi: partial\n' > "$AD/partial-no-note"
run_check answers-file green "a well-formed answers file" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --answers "$AD/good"
run_check answers-file red   "an answers file with an invented value" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --answers "$AD/bad-value"
run_check answers-file red   "an answers file naming no column" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --answers "$AD/bad-key"
run_check answers-file red   "partial with no note, from a file too" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --answers "$AD/partial-no-note"
run_check answers-file red   "an answers file that does not exist" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --answers "$AD/nope"
ROW_AF="$(capture "$(mkmachine)" --answers "$AD/good")"
assert_eq "the answers file actually fills the column" "ok" "$(field "$ROW_AF" wifi)"
assert_has "and its note reaches notes" "5 GHz roams cleanly" "$(field "$ROW_AF" notes)"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "7 — the guard on the physical-only columns, watched FIRING"
#
# Everything in group 5 shows those columns coming out empty. That is the happy path, and a happy
# path is exactly what a deleted guard also produces. So this MUTATES THE SHIPPING SCRIPT — one line,
# making a probe fill `wifi` — and requires emit_row() to refuse the row. Without this, the guard is
# a comment with an `if` around it.

MUT="$(newroot)/mutants"; mkdir -p "$MUT"
for col in $PHYSICAL_ONLY; do
  m="$MUT/$col.sh"
  # Insert a case arm that fills this column from "a probe", ahead of the generic human-column arm.
  awk -v c="$col" '
    { print }
    /^      firmware\)  v="\$FIRMWARE" ;;$/ { print "      " c ") v=\"ok\" ;;   # MUTANT: a probe filling a physical-only column" }
  ' "$TOOL" > "$m"
  # If the anchor moved, the mutant is a byte-for-byte copy of the script and would PASS — scoring a
  # guard that never ran as a guard that worked. That is the vacuous-test failure this whole
  # directory exists to catch, so it aborts rather than reporting anything.
  cmp -s "$m" "$TOOL" && t_abort "the mutation for '$col' changed nothing — the anchor line in emit_row() moved. Fix this test before trusting any of it."
  run_check physical-only-guard red "a probe filling $col is REFUSED" -- \
    env AUROS_TEST_ROOT="$(mkmachine pci-full)" bash "$m" --row-only --tester t
  assert_has "the refusal for $col names the column and the rule" "physical-only" "$T_LAST_OUT"
done
# The green half: the unmutated script, same machine, emits its row.
run_check physical-only-guard green "the real script emits a row" -- \
  env AUROS_TEST_ROOT="$(mkmachine pci-full)" bash "$TOOL" --row-only --tester t

# The same guard must not fire when a HUMAN supplied the value — otherwise it would be unfalsifiable
# in the other direction: a guard that refuses everything also never lets a bad row through.
run_check physical-only-guard green "a human-supplied wifi=ok passes the guard" -- \
  env AUROS_TEST_ROOT="$(mkmachine pci-full)" bash "$TOOL" --row-only --tester t --wifi ok

group "a TAB in any value would shift every later column"
TABBED="$(newroot)/tab.sh"
sed 's|^      notes)     v="\$NOTES" ;;$|      notes)     v="$(printf "a\\tb")" ;;|' "$TOOL" > "$TABBED"
cmp -s "$TABBED" "$TOOL" && t_abort "the TAB mutation changed nothing — the notes arm in emit_row() moved."
run_check tab-guard red   "a value containing a TAB is refused" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TABBED" --row-only
run_check tab-guard green "the real script's notes are TSV-safe" -- env AUROS_TEST_ROOT="$(mkmachine)" bash "$TOOL" --row-only --notes "$(printf 'a\tb')"
assert_not "a tab passed in --notes is neutralised rather than emitted" "	" "$(field "$(capture "$(mkmachine)" --notes "$(printf 'x\ty')")" notes)"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
group "8 — end to end: the row this tool emits survives the meta repo's own lint"

LINT=""
[ -n "$REAL_TSV" ] && LINT="$(dirname "$(dirname "$REAL_TSV")")/tools/compat-lint.mjs"
if [ -n "$LINT" ] && [ -f "$LINT" ] && command -v node >/dev/null 2>&1; then
  lint_a_row() { # <row> -> exit status of the real compat-lint over a tree containing just that row
    local d; d="$(newroot)"; mkdir -p "$d/hardware"
    { head -1 "$REAL_TSV"; printf '%s\n' "$1"; } > "$d/hardware/compat.tsv"
    ( cd "$d" && node "$LINT" )
  }
  FULL="$(capture "$(mkmachine efi-sb-on tpm2 pci-full wlan-netdev webcam)" \
    --wifi ok --trackpad ok --suspend ok --brightness ok --gpu ok --audio ok --webcam ok)"
  run_check lint-accepts green "compat-lint accepts a completed row from this tool" -- lint_a_row "$FULL"
  run_check lint-accepts green "compat-lint accepts a PARTIAL row (human columns still empty)" -- \
    lint_a_row "$(capture "$(mkmachine efi-sb-on tpm2 pci-full wlan-netdev webcam)")"
  # The red half, so this is a check rather than a demonstration: the same row with the ids column
  # replaced by the marketing name the whole column exists to keep out.
  i="$(col_index ids)"
  MARKETED="$(printf '%s' "$FULL" | awk -F'\t' -v OFS='\t' -v n="$i" '{ $n="wifi=Intel Wireless-AC 7260"; print }')"
  run_check lint-accepts red "and REFUSES the same row with a marketing name in ids" -- lint_a_row "$MARKETED"
  # …and with no ids at all, which is the other way a row stops being matchable.
  EMPTY_IDS="$(printf '%s' "$FULL" | awk -F'\t' -v OFS='\t' -v n="$i" '{ $n=""; print }')"
  run_check lint-accepts red "and REFUSES a physical row with no ids at all" -- lint_a_row "$EMPTY_IDS"
else
  t_exempt lint-accepts "hardware/compat.tsv + tools/compat-lint.mjs (meta repo, D6) are not checked out beside auros-base, or node is absent — the end-to-end lint assertion did not run. Looked for: $REPO/../hardware/compat.tsv"
  note "end-to-end lint check SKIPPED — see the exemption above."
fi

t_finish "capture-compat.sh"

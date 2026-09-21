#!/usr/bin/env bash
# B2/B11 diagnostics in the guest agent NAME what they count. Run 35566336512 reported tainted=12289,
# denials=19 and a degraded system with no names attached, and the host keeps only the fragment.
#
#   b11taint    taint_flags decodes the bitmask per Documentation/admin-guide/tainted-kernels.rst
#   b11module   tainted_modules names a module whose /sys/module/<m>/taint is non-empty, and no other
#   b11masked   masked_modules_state says whether zfs and v4l2loopback (masked by D43) are loaded
#   b11avc      avc_summary names each distinct denial (comm, scontext, tcontext, tclass, perms, object) once
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
AGENT_SH="$REPO/matrix/run/guest/auros-matrix-agent.sh"

TAINT_FN="$(extract_fn "$AGENT_SH" taint_flags)"
MOD_FN="$(extract_fn "$AGENT_SH" tainted_modules)"
AVC_FN="$(extract_fn "$AGENT_SH" avc_summary)"
MASKED_FN="$(extract_fn "$AGENT_SH" masked_modules_state)"

group "taint_flags decodes the kernel's bitmask"
# 12289 = 0x3001 = bits 0, 12, 13 — the value uefi-modern and bios-legacy both reported.
run_snippet b11taint green "12289 -> P(0) O(12) E(13)" "$TAINT_FN"'
[ "$(taint_flags 12289)" = "P(0) O(12) E(13)" ]'
run_snippet b11taint green "0 -> nothing" "$TAINT_FN"'
[ -z "$(taint_flags 0)" ]'
run_snippet b11taint green "bit 9 alone is W, not a neighbour" "$TAINT_FN"'
[ "$(taint_flags 512)" = "W(9)" ]'
run_snippet b11taint red "12288 (no bit 0) does not claim P" "$TAINT_FN"'
case "$(taint_flags 12288)" in *"P("*) exit 0;; *) exit 1;; esac'

group "tainted_modules names the module, from its own taint file"
S="$(newroot)"
mkdir -p "$S/kvmfr" "$S/ext4" "$S/xhci_hcd"
printf 'OE\n' > "$S/kvmfr/taint"; : > "$S/ext4/taint"; : > "$S/xhci_hcd/taint"
run_snippet b11module green "an OE module is named with its letters" "$MOD_FN"'
[ "$(tainted_modules "'"$S"'")" = "kvmfr(OE)" ]'
C="$(newroot)"; mkdir -p "$C/ext4"; : > "$C/ext4/taint"
run_snippet b11module red "a clean module set names nothing" "$MOD_FN"'
[ -n "$(tainted_modules "'"$C"'")" ]'

group "masked_modules_state proves D43's masks held"
N="$(newroot)"; mkdir -p "$N/ext4"
run_snippet b11masked green "neither module loaded" "$MASKED_FN"'
[ "$(masked_modules_state "'"$N"'")" = "zfs=not-loaded v4l2loopback=not-loaded" ]'
Y="$(newroot)"; mkdir -p "$Y/ext4" "$Y/zfs"
run_snippet b11masked red "zfs loaded is not reported as clean" "$MASKED_FN"'
[ "$(masked_modules_state "'"$Y"'")" = "zfs=not-loaded v4l2loopback=not-loaded" ]'

group "avc_summary names each distinct denial once"
J="$(newroot)/journal.txt"
cat > "$J" <<'EOF'
Sep 21 06:40:01 auros kernel: audit: type=1400 audit(1789.1:201): avc:  denied  { read } for  pid=812 comm="foo" name="bar" dev="vda3" ino=12 scontext=system_u:system_r:foo_t:s0 tcontext=system_u:object_r:bar_t:s0 tclass=file permissive=0
Sep 21 06:40:02 auros kernel: audit: type=1400 audit(1789.2:202): avc:  denied  { read } for  pid=813 comm="foo" name="bar" dev="vda3" ino=12 scontext=system_u:system_r:foo_t:s0 tcontext=system_u:object_r:bar_t:s0 tclass=file permissive=0
Sep 21 06:40:03 auros audit[900]: AVC avc:  denied  { write open } for  pid=900 comm="baz" path="/var/x" scontext=system_u:system_r:baz_t:s0 tcontext=system_u:object_r:var_t:s0 tclass=file permissive=0
Sep 21 06:40:04 auros systemd[1]: Started something unrelated.
EOF
run_snippet b11avc green "two identical denials fold to 2x, the other stays 1x" "$AVC_FN"'
out=$(avc_summary < "'"$J"'")
[ "$out" = "2x foo system_u:system_r:foo_t:s0->system_u:object_r:bar_t:s0:file {read} name=bar; 1x baz system_u:system_r:baz_t:s0->system_u:object_r:var_t:s0:file {write open} path=/var/x" ] || { echo "$out"; exit 1; }'
run_snippet b11avc red "a journal with no denials summarises to nothing" "$AVC_FN"'
[ -n "$(printf "Sep 21 systemd[1]: Started x.\n" | avc_summary)" ]'

t_finish b11-diag.test.sh

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/static-matrix.test.sh — the static phase's own probes, against synthetic input.
#
# The first static run of the hardened base (run 35557609009) failed three checks for reasons that
# were the HARNESS, not the image:
#
#   S3   'recipe "true" resolved an EMPTY removal set' — on a base build. run-static.sh passes
#        `--recipe ""`; analyze.mjs's argument parser tested the next argument for truthiness, and ""
#        is falsy, so the recipe became the string "true".
#   S10  'greenboot-rollback.service not installed' — greenboot 0.16.4 ships no such unit
#        (units.known). What arms rollback is greenboot-set-rollback-trigger.service, which the build
#        log shows enabled.
#   S10  '/etc/greenboot/check/required.d/ is empty' — build/30-update-agent.sh installs our four
#        required checks in /usr/lib/greenboot/check/required.d/ (greenboot 0.16 ships both dirs).
#
# And S7/S8 could only ever fail in the static job: S7's evidence is the build job's two builds and
# S8's is the sign job's signature, and sign `needs: static`. `--defer` hands them back.
#
# Every block under test is extracted from the shipping file, per tests/lib/harness.sh.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

RS="$REPO/matrix/run/run-static.sh"
PROBE="$REPO/matrix/run/guest/image-probe.sh"
command -v node >/dev/null 2>&1 || t_abort "node is required to run analyze.mjs"

# ── analyze.mjs, invoked exactly as run-static.sh invokes it ─────────────────────────────────────
ANALYZE_CALL="$(extract_between "$RS" '^node "\$HARNESS_DIR/lib/analyze.mjs"' 'flatpak-result "\$FP_RESULT"')"

W="$(newroot)"
: > "$W/empty.txt"
printf '{"status":"pass","detail":"no flatpak refs declared"}' > "$W/fp.json"
# uupd as the pinned Aurora ships it (all three triggers live), with A4b's system module off.
uupd_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
UUPD_OFF_B64="$(uupd_b64 '{"modules":{"system":{"disable":true},"flatpak":{"disable":false}}}')"
POLICY_B64="$(printf '%s' '{"default":[{"type":"reject"}],"transports":{"docker":{"ghcr.io/aarohkandy":[{"type":"sigstoreSigned","keyPath":"/usr/lib/pki/containers/auros.pub"}]}}}' | base64 | tr -d '\n')"

# good_probe [KEY=VALUE overrides...] — the probe output of a correctly built base, as far as S3/S10 go.
good_probe() {
  {
    printf '%s\n' PROBE_OK=1 BOOTC_BIN=/usr/bin/bootc SYSTEMD_BIN=/usr/lib/systemd/systemd \
      UNIT_BOOTC_FETCH_APPLY_UPDATES_TIMER_PRESENT=1 UNIT_BOOTC_FETCH_APPLY_UPDATES_TIMER_ENABLED=enabled \
      UNIT_GREENBOOT_HEALTHCHECK_SERVICE_PRESENT=1 UNIT_GREENBOOT_HEALTHCHECK_SERVICE_ENABLED=enabled \
      UNIT_GREENBOOT_SET_ROLLBACK_TRIGGER_SERVICE_PRESENT=1 UNIT_GREENBOOT_SET_ROLLBACK_TRIGGER_SERVICE_ENABLED=enabled \
      UNIT_NETWORKMANAGER_SERVICE_PRESENT=1 UNIT_NETWORKMANAGER_SERVICE_ENABLED=enabled \
      UNIT_UUPD_TIMER_ENABLED=enabled UNIT_UUPD_RESUME_TIMER_ENABLED=enabled UNIT_UUPD_ON_AC_SERVICE_PRESENT=1 \
      "UUPD_CONFIG_B64=$UUPD_OFF_B64" GREENBOOT_REQUIRED_COUNT=4 \
      POLICY_JSON=1 "POLICY_JSON_B64=$POLICY_B64" PKI_KEYS=auros.pub, REGISTRIES_D_SIGSTORE_TRUE=1 \
      POLICY_MODE_STAMP=open "$@"
    printf -- '---RPM-NAMES---\nbash\t1\n---END---\n'
  } > "$W/probe.txt"
}

# analyze_says <id> <recipe> — exit 0 iff the check passed. Later KEY= lines win in analyze's parser,
# so overrides passed to good_probe replace the defaults.
analyze_says() {
  local id="$1"
  rm -f "$W/checks.jsonl"
  HARNESS_DIR="$REPO/matrix/run" RECIPE="$2" POLICY=auto SCOPE=ghcr.io/aarohkandy \
    CHECKS_FILE="$W/checks.jsonl" FP_RESULT="$W/fp.json" W="$W" \
    bash -c "cp '$W/empty.txt' '$W/declared-remove.txt'; cp '$W/empty.txt' '$W/install-rpms.txt'; cp '$W/empty.txt' '$W/upstream-rpms.tsv'
$ANALYZE_CALL" >/dev/null || return 9
  grep -q "\"id\":\"$id\",\"status\":\"pass\"" "$W/checks.jsonl" || { grep "\"id\":\"$id\"" "$W/checks.jsonl"; return 1; }
}

group "S3 — a base build (--recipe \"\") is a base build, not a recipe called \"true\""
good_probe
run_check S3-base green 'base build, empty removal set'           -- analyze_says S3 ''
run_check S3-base red   'recipe "school" with an empty removal set' -- analyze_says S3 school

group "S10 — greenboot as 0.16.4 actually ships it"
good_probe
run_check S10-greenboot green 'rollback trigger enabled, 4 required checks' -- analyze_says S10 ''
good_probe UNIT_GREENBOOT_SET_ROLLBACK_TRIGGER_SERVICE_PRESENT=0
run_check S10-greenboot red   'rollback trigger unit absent'                -- analyze_says S10 ''
good_probe UNIT_GREENBOOT_SET_ROLLBACK_TRIGGER_SERVICE_ENABLED=disabled
run_check S10-greenboot red   'rollback trigger present but disabled'       -- analyze_says S10 ''
good_probe GREENBOOT_REQUIRED_COUNT=0
run_check S10-greenboot red   'no required checks anywhere'                 -- analyze_says S10 ''

group "S10 — exactly one thing updates the OS: bootc's timer, and uupd only with its system module off"
good_probe
run_check S10-one-updater green 'uupd on all three triggers, modules.system.disable=true' -- analyze_says S10 ''
good_probe "UUPD_CONFIG_B64=$(uupd_b64 '{"Modules":{"System":{"Disable":"true"}}}')"
run_check S10-one-updater green 'viper reads keys case-insensitively and "true" weakly'   -- analyze_says S10 ''
good_probe UNIT_UUPD_TIMER_ENABLED=disabled UNIT_UUPD_RESUME_TIMER_ENABLED=disabled UNIT_UUPD_ON_AC_SERVICE_PRESENT=0 UUPD_CONFIG_B64=
run_check S10-one-updater green 'nothing starts uupd at all'                                -- analyze_says S10 ''
good_probe "UUPD_CONFIG_B64=$(uupd_b64 '{"modules":{"system":{"disable":false}}}')"
run_check S10-one-updater red   'Aurora default: system module on — two OS updaters'        -- analyze_says S10 ''
good_probe "UUPD_CONFIG_B64=$(uupd_b64 '{"modules":{"flatpak":{"disable":true}}}')"
run_check S10-one-updater red   'system module unset (uupd default is on)'                  -- analyze_says S10 ''
good_probe UUPD_CONFIG_B64=
run_check S10-one-updater red   '/etc/uupd/config.json absent — uupd runs defaults'         -- analyze_says S10 ''
good_probe "UUPD_CONFIG_B64=$(uupd_b64 '{"modules":')"
run_check S10-one-updater red   'config does not parse'                                     -- analyze_says S10 ''
good_probe UNIT_UUPD_TIMER_ENABLED=disabled UNIT_UUPD_RESUME_TIMER_ENABLED=disabled UUPD_CONFIG_B64=
run_check S10-one-updater red   'uupd.timer disabled, but uupd-on-ac.service still starts it' -- analyze_says S10 ''

group "image-probe.sh reads /etc/uupd/config.json byte for byte"
UUPD_LINE="$(extract_lines "$PROBE" '^\[ -e /etc/uupd/config.json \] && emit UUPD_CONFIG_B64' | rootify /etc/uupd)"
[ -n "$UUPD_LINE" ] || t_abort "could not find the UUPD_CONFIG_B64 line in image-probe.sh"
probe_uupd() { # <root> <expected-json> — exit 0 iff the probe emits exactly that file
  ROOT="$1" bash -c "emit() { [ \"\$(printf '%s' \"\$2\" | base64 -d 2>/dev/null || printf '%s' \"\$2\" | base64 -D)\" = '$2' ]; }
$UUPD_LINE"
}
R3="$(newroot)"; mkdir -p "$R3/etc/uupd"; printf '%s' '{"modules":{"system":{"disable":true}}}' > "$R3/etc/uupd/config.json"
run_check probe-uupd-config green 'config present: emitted and decodes to the file'      -- probe_uupd "$R3" '{"modules":{"system":{"disable":true}}}'
run_check probe-uupd-config red   'config absent: nothing emitted'                      -- probe_uupd "$(newroot)" ''

# ── the probe counts the directory the build writes ─────────────────────────────────────────────
group "image-probe.sh counts required checks where build/30-update-agent.sh installs them"
COUNT_LINE="$(extract_lines "$PROBE" '^emit GREENBOOT_REQUIRED_COUNT' | rootify /usr/lib/greenboot /etc/greenboot)"
# The install destination, read from the build script rather than restated here.
INSTALL_PREFIX="$(extract_lines "$REPO/build/30-update-agent.sh" 'install_file "\$f" "/usr/lib/greenboot/\$dir/' \
  | grep -oE '"/usr/lib/greenboot/' | tr -d '"')"
[ -n "$INSTALL_PREFIX" ] || t_abort "could not read the greenboot install prefix from build/30-update-agent.sh"
count_ok() { # <root> — exit 0 iff the probe line reports >= 1 required check
  ROOT="$1" bash -c "emit() { [ \"\$2\" -ge 1 ]; }
$COUNT_LINE"
}
R1="$(newroot)"; mkdir -p "$R1${INSTALL_PREFIX}check/required.d"
for n in 10-network-stack 20-graphical-target 30-update-timer-enabled 40-no-new-failed-units; do
  printf '#!/bin/bash\nexit 0\n' > "$R1${INSTALL_PREFIX}check/required.d/$n.sh"
done
run_check probe-required-count green "four checks under ${INSTALL_PREFIX}check/required.d" -- count_ok "$R1"
R2="$(newroot)"; mkdir -p "$R2/usr/lib/greenboot/check/required.d" "$R2/etc/greenboot/check/required.d"
run_check probe-required-count red   'both required.d dirs empty'                           -- count_ok "$R2"
touch "$R2/usr/lib/greenboot/check/required.d/README"
run_check probe-required-count red   'only a non-.sh file (greenboot globs *.sh)'           -- count_ok "$R2"

group "every greenboot unit the probe asks about is one greenboot 0.16.4 ships (units.known)"
PROBE_UNITS="$(extract_raw "$PROBE" '^for u in bootc-fetch-apply-updates' 'NetworkManager.service; do' \
  | grep -oE 'greenboot[a-z0-9-]*\.service' | sort -u)"
[ -n "$PROBE_UNITS" ] || t_abort "parsed zero greenboot units from the probe's unit loop"
KNOWN="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$REPO/units.known")"
all_known() { local u; for u in "$@"; do grep -qxF "$u" <<<"$KNOWN" || { echo "not in units.known: $u"; return 1; }; done; }
# shellcheck disable=SC2086
run_check probe-units-known green "probe's greenboot units: $(echo $PROBE_UNITS)" -- all_known $PROBE_UNITS
run_check probe-units-known red   'greenboot-rollback.service (the name run 35557609009 probed)' -- all_known greenboot-rollback.service

# ── --defer: S7 and S8 belong to the build and sign jobs in CI ───────────────────────────────────
group "run-static.sh --defer records nothing for a deferred check, and refuses anything but S7/S8"
STUB_FNS='log() { :; }; check_begin() { :; }; have() { return 1; }; record() { echo "recorded $1 $2"; exit 3; }'
S7_BLOCK="$(extract_between "$RS" '^# ── S7 — Determinism' '^# ── S8 — Signature')"
S8_BLOCK="$(extract_between "$RS" '^# ── S8 — Signature' '^# ── verdict')"
run_snippet defer-S7 green 'S7 deferred: not recorded'                "$STUB_FNS; DEFER=' S7 S8 '; SECOND_DIGEST=''; DIGEST=''
$S7_BLOCK"
run_snippet defer-S7 red   'S7 not deferred, no second build: recorded' "$STUB_FNS; DEFER=' '; SECOND_DIGEST=''; DIGEST=''
$S7_BLOCK"
run_snippet defer-S8 green 'S8 deferred: not recorded'                "$STUB_FNS; DEFER=' S7 S8 '; REGISTRY_REF=''
$S8_BLOCK"
run_snippet defer-S8 red   'S8 not deferred, no registry ref: recorded' "$STUB_FNS; DEFER=' S8x '; REGISTRY_REF=''
$S8_BLOCK"

DEFER_ARM="$(extract_lines "$RS" '^    --defer\) ')"
defer_parse() { # <id>
  bash -c "die() { exit 2; }; DEFER=' '; set -- --defer '$1'
while [ \$# -gt 0 ]; do case \"\$1\" in
$DEFER_ARM
esac; done; [ \"\$DEFER\" = ' $1 ' ]"
}
run_check defer-only-S7-S8 green '--defer S7 accepted' -- defer_parse S7
run_check defer-only-S7-S8 green '--defer S8 accepted' -- defer_parse S8
run_check defer-only-S7-S8 red   '--defer S10 refused — deferring must not become a way to silence a check' -- defer_parse S10

t_finish "static-matrix"

#!/usr/bin/env bash
# probe-matrix-verdict.sh <fragment.json> <phase-or-profile> <harness-exit-status>
#
# The ONE assertion probe-matrix.yml makes, and the reason it is a separate file: it has to be
# identical in all three jobs, and a copy-pasted assertion is an assertion that drifts.
#
# WHAT IT ASSERTS, precisely:
#   1. The fragment EXISTS, parses as JSON, has a `profile`, and has at least one check.
#   2. Every check id that `matrix/checks.yaml` declares for this phase appears in the fragment with
#      a status of pass, fail or skip.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT: that any check passed. The image under probe is a bare
# derivative of upstream with one marker file — no policy layer, no greenboot, no signing material.
# Most checks SHOULD record `fail`. A `fail` is the harness working. A MISSING id is the harness
# falling over before it could record a verdict, and that is the bug this probe hunts.
#
# HOW TO WATCH IT GO RED (rule 1 — a check that cannot fail is not a check):
#   delete a `record Sn ...` line from matrix/run/run-static.sh and rerun: that id goes missing and
#   this script exits 1 naming it. Truncate the fragment to `{}` and it exits 1 on shape. Both
#   demonstrated before this file was committed.
set -euo pipefail

FRAG=${1:?usage: probe-matrix-verdict.sh <fragment.json> <phase|profile> <harness-rc>}
LABEL=${2:?}
RC=${3:-unset}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
CHECKS_YAML="$REPO/matrix/checks.yaml"

sum() { printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
fail() { echo "::error::$*"; sum ""; sum "**PROBE FAILED:** $*"; exit 1; }

echo "harness exit status was: ${RC}  (a non-zero status caused by failing CHECKS is expected here)"
sum "## probe-matrix · ${LABEL}"
sum ""
sum "harness exit status: \`${RC}\` — non-zero from failing *checks* is the expected outcome on a bare derivative."
sum ""

# ── 1. shape ─────────────────────────────────────────────────────────────────────────────────────
if [ ! -f "$FRAG" ]; then
  echo "--- what IS in fragments/ ---"; ls -la fragments/ 2>&1 || echo "(no fragments directory at all)"
  fail "no fragment at ${FRAG}. The harness exited ${RC} without recording anything, so nothing can be said about any check. This is the failure mode the probe exists to find."
fi
echo "--- $FRAG ---"; cat "$FRAG"
jq -e '.' "$FRAG" >/dev/null 2>&1 || fail "${FRAG} is not parseable JSON"
jq -e '.profile and (.checks | type == "array") and (.checks | length > 0)' "$FRAG" >/dev/null \
  || fail "${FRAG} has no .profile or no non-empty .checks array"

# ── 2. every declared id reached a verdict ───────────────────────────────────────────────────────
# checks.yaml maps phases to sections. `update` covers the restore section too, because run-update.sh
# records R1 and build.yml merges it into the update fragment.
case "$LABEL" in
  static) SECTIONS='static' ;;
  update) SECTIONS='update restore' ;;
  *)      SECTIONS='boot' ;;   # any profile id is a boot run
esac

EXPECTED=$(
  node -e '
    const fs = require("fs");
    const [file, ...want] = process.argv.slice(1);
    const lines = fs.readFileSync(file, "utf8").split("\n");
    let section = null; const out = [];
    for (const l of lines) {
      const top = l.match(/^([a-z_]+):\s*$/);
      if (top) { section = top[1]; continue; }
      const id = l.match(/^\s+- id:\s*([A-Za-z0-9]+)\s*$/);
      if (id && want.includes(section)) out.push(id[1]);
    }
    if (out.length === 0) { console.error("no ids parsed out of " + file + " for sections " + want.join(",")); process.exit(3); }
    process.stdout.write(out.join(" "));
  ' "$CHECKS_YAML" $SECTIONS
) || fail "could not read the expected check ids out of ${CHECKS_YAML} for section(s) ${SECTIONS}"

echo "checks.yaml declares for [${SECTIONS}]: ${EXPECTED}"

MISSING=''
sum "| check | status | detail |"
sum "|---|---|---|"
for id in $EXPECTED; do
  ST=$(jq -r --arg id "$id" '(.checks[] | select(.id == $id) | .status) // "MISSING"' "$FRAG" | head -1)
  [ -n "$ST" ] || ST=MISSING
  DET=$(jq -r --arg id "$id" '(.checks[] | select(.id == $id) | .detail) // ""' "$FRAG" | head -1 | cut -c1-300 | tr '|' '/')
  printf '%-4s %-8s %s\n' "$id" "$ST" "$DET"
  case "$ST" in
    pass) ICON='✅ pass' ;;
    fail) ICON='❌ fail' ;;
    skip) ICON='⚠️ skip' ;;
    *)    ICON='🚨 **NO VERDICT**'; MISSING="$MISSING $id" ;;
  esac
  sum "| \`$id\` | $ICON | ${DET:-—} |"
done

# Anything the fragment reported that checks.yaml does not declare is also worth seeing — an id typo
# in a `record` call would otherwise look exactly like a missing check.
# NOT written as `EXTRA=$(... | while ...; case ... esac ...)`. A `case` clause's closing `)` inside
# `$( )` is a parse error on bash 3.2 (which is what a macOS developer runs), and the script would
# have died with "syntax error near unexpected token `;;'" on their machine while working on the
# runner. Found by running it locally before committing it.
EXTRA=''
while read -r id; do
  case " $EXPECTED " in
    *" $id "*) ;;
    *) EXTRA="$EXTRA $id" ;;
  esac
done < <(jq -r '.checks[].id' "$FRAG")
if [ -n "${EXTRA// /}" ]; then
  echo "::warning::the fragment reports ids checks.yaml does not declare for [${SECTIONS}]: ${EXTRA}"
  sum ""; sum "Undeclared ids in the fragment: \`${EXTRA}\` — a typo in a \`record\` call looks like a missing check."
fi

N_PASS=$(jq '[.checks[] | select(.status=="pass")] | length' "$FRAG")
N_FAIL=$(jq '[.checks[] | select(.status=="fail")] | length' "$FRAG")
N_SKIP=$(jq '[.checks[] | select(.status=="skip")] | length' "$FRAG")
sum ""
sum "**${N_PASS} pass · ${N_FAIL} fail · ${N_SKIP} skip** out of $(printf '%s' "$EXPECTED" | wc -w | tr -d ' ') declared."

if [ -n "${MISSING// /}" ]; then
  fail "these declared checks produced NO VERDICT at all:${MISSING}. The harness errored past them instead of recording a fail. That is the bug — find where it exited, not why the check would have failed."
fi

echo "OK: every declared check for [${SECTIONS}] reached a verdict."
sum ""
sum "Every declared check reached a verdict. The harness ran and reported honestly; the individual failures are the probe image, not the harness."

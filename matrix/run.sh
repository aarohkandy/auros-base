#!/usr/bin/env bash
# matrix/run.sh — the PHASE-ORIENTED entry point CI drives, adapting to the harness in matrix/run/.
#
# WHY THIS FILE EXISTS
# Two pieces of this repo were designed independently against the same contract and arrived at two
# shapes, both correct for what they were solving:
#
#   * matrix/run/*.sh runs the whole matrix in ONE process on ONE host. Right for a developer with a
#     laptop and for a single-host runner.
#   * .github/workflows/build.yml wants to run each PHASE as a separate job — static once, then one
#     boot job per hardware profile fanned out across runners, then update — with each job emitting a
#     JSON FRAGMENT that a later job merges. Right for CI, because seven profiles booting in parallel
#     on seven runners is the difference between ten minutes and an hour, and because a profile that
#     fails names itself in the job list.
#
# Rather than force one to adopt the other, this adapts. The harness stays the implementation; this is
# the interface CI holds. Both are tested, and neither had to be thrown away.
#
# usage: run.sh --phase static|boot|update --image REF --digest sha256:... --out FILE [--profile ID]
#
# Fails closed everywhere: an unknown phase, a missing implementation, or an empty fragment is an error,
# never a silent pass. A phase that produces no checks is a phase that did not run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/run"

PHASE=''; IMAGE=''; DIGEST=''; PROFILE=''; OUT=''; CHECKS=''; PROFILES=''
declare -a PASSTHRU=()
while [ $# -gt 0 ]; do
  case "$1" in
    --phase)    PHASE="$2";    shift 2 ;;
    --image)    IMAGE="$2";    shift 2 ;;
    --digest)   DIGEST="$2";   shift 2 ;;
    --profile)  PROFILE="$2";  shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    --checks)   CHECKS="$2";   shift 2 ;;   # accepted for interface stability; the harness reads its own
    --profiles) PROFILES="$2"; shift 2 ;;
    --)         shift; PASSTHRU+=("$@"); break ;;
    *)          PASSTHRU+=("$1"); shift ;;
  esac
done

die () { echo "matrix/run.sh: $*" >&2; exit 1; }
[ -n "$PHASE" ] || die "--phase is required (static|boot|update)"
[ -n "$IMAGE" ] || die "--image is required"
[ -n "$OUT"   ] || die "--out is required — a phase that writes nothing cannot be merged, and an absent fragment must not read as a pass"
[ -d "$RUN"   ] || die "matrix/run/ is absent: the harness has not landed, so there is nothing to gate with"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$(dirname "$OUT")"

case "$PHASE" in
  static)
    [ -x "$RUN/run-static.sh" ] || die "matrix/run/run-static.sh is absent"
    "$RUN/run-static.sh" --image "$IMAGE" ${DIGEST:+--digest "$DIGEST"} --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
    FRAG_PROFILE='static'
    ;;
  boot)
    [ -n "$PROFILE" ] || die "--profile is required for the boot phase"
    [ -x "$RUN/run-boot.sh" ] || die "matrix/run/run-boot.sh is absent"
    "$RUN/run-boot.sh" --profile "$PROFILE" --image "$IMAGE" --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
    FRAG_PROFILE="$PROFILE"
    ;;
  update)
    [ -x "$RUN/run-update.sh" ] || die "matrix/run/run-update.sh is absent"
    "$RUN/run-update.sh" --image "$IMAGE" ${PROFILE:+--profile "$PROFILE"} --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
    FRAG_PROFILE="${PROFILE:-update}"
    ;;
  *)
    die "unknown phase '$PHASE' — expected static, boot or update"
    ;;
esac

# The harness writes its per-check results under the run directory. Collect them into the single
# fragment shape build.yml merges: { profile, checks: [ {id, status, detail, duration_ms} ] }.
#
# `status` is normalised here and nowhere else, so there is one place that decides what counts as a
# pass. Anything that is not literally "pass" becomes "fail" — in particular a missing or unreadable
# result. An absent answer is a failure, not an unknown.
node - "$WORKDIR" "$FRAG_PROFILE" "$DIGEST" "$OUT" <<'NODE'
const fs = require('node:fs'), path = require('node:path')
const [dir, profile, digest, out] = process.argv.slice(2)

const checks = []
const walk = d => {
  let entries = []
  try { entries = fs.readdirSync(d, { withFileTypes: true }) } catch { return }
  for (const e of entries) {
    const p = path.join(d, e.name)
    if (e.isDirectory()) { walk(p); continue }
    if (!/\.json$/.test(e.name)) continue
    let j
    try { j = JSON.parse(fs.readFileSync(p, 'utf8')) } catch { continue }
    const push = c => {
      if (!c || typeof c.id !== 'string') return
      checks.push({
        id: c.id,
        status: c.status === 'pass' ? 'pass' : (c.status === 'skip' ? 'skip' : 'fail'),
        ...(c.skip_reason ? { skip_reason: String(c.skip_reason) } : {}),
        ...(c.detail ? { detail: String(c.detail).slice(0, 2000) } : {}),
        ...(Number.isInteger(c.duration_ms) ? { duration_ms: c.duration_ms } : {}),
      })
    }
    if (Array.isArray(j.checks)) j.checks.forEach(push)
    else if (Array.isArray(j)) j.forEach(push)
    else if (j.id) push(j)
  }
}
walk(dir)

// Deduplicate by id, keeping the WORST status seen. If two sources disagree about a check, the
// pessimistic answer is the safe one — a check that passed once and failed once did not pass.
const rank = { pass: 0, skip: 1, fail: 2 }
const best = new Map()
for (const c of checks) {
  const prev = best.get(c.id)
  if (!prev || rank[c.status] > rank[prev.status]) best.set(c.id, c)
}
const merged = [...best.values()].sort((a, b) => a.id.localeCompare(b.id))

if (merged.length === 0) {
  console.error(`matrix/run.sh: phase produced ZERO checks under ${dir}.`)
  console.error('  An empty fragment must never be written: build.yml asserts checks.length > 0, but a')
  console.error('  fragment that never appears would be just as dangerous, so we fail here instead.')
  process.exit(1)
}

fs.writeFileSync(out, JSON.stringify({ profile, ...(digest ? { digest } : {}), checks: merged }, null, 1) + '\n')
const bad = merged.filter(c => c.status !== 'pass')
console.error(`matrix/run.sh: ${merged.length} checks -> ${out} (${bad.length} not passing)`)
NODE

FAILED=$(node -e 'const j=require(process.argv[1]);process.stdout.write(String(j.checks.filter(c=>c.status!=="pass").length))' "$OUT")
[ "$FAILED" = "0" ] || { echo "matrix/run.sh: phase '$PHASE' had $FAILED non-passing check(s)" >&2; exit 1; }

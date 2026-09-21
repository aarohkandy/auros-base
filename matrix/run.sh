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

# THE RUN DIRECTORY, AND WHY IT IS NOT ALWAYS A TEMPORARY ONE.
#
# This used to be an unconditional `mktemp -d` with `trap rm -rf ... EXIT`, which meant the harness
# DELETED ITS OWN EVIDENCE on the way out — every serial console log, every bootc-image-builder log,
# every QEMU command line — and the caller was left with the one-line `detail` string in the
# fragment. build.yml uploads only `fragments/`, so on CI that evidence was not merely unuploaded,
# it no longer existed by the time the upload step ran. Rule 2 of this project is that a failing
# assertion must print what IS there; a harness that destroys the logs cannot obey it.
#
# So: if the caller exports AUROS_RUN_DIR, that directory is used and KEPT. Otherwise the old
# behaviour is unchanged — a temp dir, removed on exit — so nothing that does not ask for logs starts
# accumulating them.
if [ -n "${AUROS_RUN_DIR:-}" ]; then
  WORKDIR="$AUROS_RUN_DIR"
  mkdir -p "$WORKDIR"
else
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
fi
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
#
# THE .jsonl BUG, kept written down because it killed the entire matrix and was invisible.
# Every script under matrix/run/ writes JSON LINES to `checks/<name>.jsonl` — that is what
# common.sh's `record()` appends to, one object per line. This collector matched `/\.json$/`, which
# does not match "static.jsonl", and then `JSON.parse`d the whole file, which a JSON Lines file with
# more than one record can never satisfy. Both halves were wrong, and each alone was fatal.
#
# The consequence was total and silent: EVERY phase found zero checks, printed "phase produced ZERO
# checks", wrote no fragment at all, and exited 1. Not one check in the matrix — not S1, not B1, not
# U1 — could ever have reached a verdict, on any image, however perfect. The matrix had never been
# run, so nothing had ever contradicted it. Reproduced on a two-line synthetic `static.jsonl` before
# this fix, and the same file is what the meta-test now replays.
node - "$WORKDIR" "$FRAG_PROFILE" "$DIGEST" "$OUT" <<'NODE'
const fs = require('node:fs'), path = require('node:path')
const [dir, profile, digest, out] = process.argv.slice(2)

const checks = []
const unreadable = []
const seenFiles = []

// parseRecords(text) -> array of candidate records, from EITHER a whole-file JSON document or a
// JSON Lines stream. A file is never silently discarded: if nothing parses out of it, it is named
// in `unreadable` and the phase fails, because "the results file was corrupt" and "every check
// passed" must never look the same from the outside.
const parseRecords = (text, file) => {
  const trimmed = text.trim()
  if (!trimmed) { unreadable.push(`${file}: empty`); return [] }
  try {
    const j = JSON.parse(trimmed)
    if (Array.isArray(j)) return j
    if (Array.isArray(j.checks)) return j.checks
    if (j.id) return [j]
    unreadable.push(`${file}: parsed as JSON but carries no .id, .checks[] and is not an array`)
    return []
  } catch { /* fall through to JSON Lines */ }
  const out = []
  let badLines = 0
  for (const line of trimmed.split('\n')) {
    const l = line.trim()
    if (!l) continue
    try { out.push(JSON.parse(l)) } catch { badLines++ }
  }
  if (out.length === 0) unreadable.push(`${file}: neither a JSON document nor JSON Lines (${badLines} unparseable line(s))`)
  else if (badLines > 0) unreadable.push(`${file}: ${badLines} unparseable line(s) alongside ${out.length} good one(s)`)
  return out
}

const walk = d => {
  let entries = []
  try { entries = fs.readdirSync(d, { withFileTypes: true }) } catch { return }
  for (const e of entries) {
    const p = path.join(d, e.name)
    if (e.isDirectory()) { walk(p); continue }
    if (!/\.jsonl?$/.test(e.name)) continue
    seenFiles.push(p)
    let text
    try { text = fs.readFileSync(p, 'utf8') } catch (err) { unreadable.push(`${p}: ${err.message}`); continue }
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
    parseRecords(text, p).forEach(push)
  }
}
walk(dir)

if (unreadable.length) {
  console.error('matrix/run.sh: result files the collector could not read:')
  for (const u of unreadable) console.error(`  ${u}`)
  process.exit(1)
}

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
  // Rule 2: print what IS there. The .jsonl bug above presented as exactly this message, and the
  // message said nothing about the two perfectly good result files sitting in the directory.
  console.error(`  result files considered (*.json, *.jsonl): ${seenFiles.length ? seenFiles.join(', ') : 'NONE'}`)
  const all = []
  const list = d => { try { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); e.isDirectory() ? list(p) : all.push(p) } } catch {} }
  list(dir)
  console.error(`  every file under the run directory (${all.length}): ${all.slice(0, 60).join(', ') || 'NONE — the phase wrote nothing at all'}`)
  process.exit(1)
}

fs.writeFileSync(out, JSON.stringify({ profile, ...(digest ? { digest } : {}), checks: merged }, null, 1) + '\n')
const bad = merged.filter(c => c.status !== 'pass')
console.error(`matrix/run.sh: ${merged.length} checks -> ${out} (${bad.length} not passing)`)
NODE

FAILED=$(node -e 'const j=require(process.argv[1]);process.stdout.write(String(j.checks.filter(c=>c.status!=="pass").length))' "$OUT")
[ "$FAILED" = "0" ] || { echo "matrix/run.sh: phase '$PHASE' had $FAILED non-passing check(s)" >&2; exit 1; }

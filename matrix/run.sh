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
MATRIX_CHECKS="${HERE}/checks.yaml"

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

# THE IMPLEMENTATION'S EXIT STATUS IS CAPTURED, NEVER ALLOWED TO KILL THIS SCRIPT.
#
# Every run-*.sh ends by exiting non-zero when any check failed — correctly, because that is how a
# caller learns the phase did not pass. But this script runs under `set -e`, so that exit used to
# abort it AT THE INVOCATION LINE, before the collector below ever ran. The result: on any run with
# a single failing check, NO FRAGMENT WAS WRITTEN AT ALL. The ten verdicts run-static.sh had just
# recorded went into the run directory and nowhere else, and build.yml's next line —
# `jq -e ... fragments/static.json` — failed with "no such file", naming no check.
#
# build.yml's update job even carries the comment "A non-zero harness still writes a fragment
# recording WHICH checks failed, and that fragment is what the gate reads." It did not. Measured on
# a real run: 10 checks recorded, 7 failed, fragments/ empty.
#
# So: capture the status, ALWAYS collect, and re-raise afterwards. A failing phase must leave
# evidence naming what failed; that is the entire purpose of the fragment.
PHASE_RC=0
case "$PHASE" in
  static)
    [ -x "$RUN/run-static.sh" ] || die "matrix/run/run-static.sh is absent"
    "$RUN/run-static.sh" --image "$IMAGE" ${DIGEST:+--digest "$DIGEST"} --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" || PHASE_RC=$?
    FRAG_PROFILE='static'
    ;;
  boot)
    [ -n "$PROFILE" ] || die "--profile is required for the boot phase"
    [ -x "$RUN/run-boot.sh" ] || die "matrix/run/run-boot.sh is absent"
    "$RUN/run-boot.sh" --profile "$PROFILE" --image "$IMAGE" --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" || PHASE_RC=$?
    FRAG_PROFILE="$PROFILE"
    ;;
  update)
    [ -x "$RUN/run-update.sh" ] || die "matrix/run/run-update.sh is absent"
    "$RUN/run-update.sh" --image "$IMAGE" ${PROFILE:+--profile "$PROFILE"} --out "$WORKDIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" || PHASE_RC=$?
    FRAG_PROFILE="${PROFILE:-update}"
    ;;
  *)
    die "unknown phase '$PHASE' — expected static, boot or update"
    ;;
esac
[ "$PHASE_RC" = 0 ] || echo "matrix/run.sh: the ${PHASE} implementation exited ${PHASE_RC}; collecting its records anyway so the fragment says WHICH checks failed" >&2

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
# `--checks` used to be accepted "for interface stability" and ignored. It is read now: the
# collector asserts that every id checks.yaml declares for this phase actually reached a verdict,
# and records a fail for any that did not. A phase that stopped halfway used to be indistinguishable
# from one that ran to the end, because both produced a fragment full of real records.
CHECKS_FILE_FOR_COLLECTOR="$MATRIX_CHECKS"
if [ -n "$CHECKS" ]; then
  if [ -f "$CHECKS" ]; then CHECKS_FILE_FOR_COLLECTOR="$CHECKS"
  else die "--checks '$CHECKS' does not exist. The matrix definition is what 'complete' means; guessing past a missing one is how a half-run phase reads as a full one."; fi
fi
[ -f "$CHECKS_FILE_FOR_COLLECTOR" ] || die "no matrix definition at $CHECKS_FILE_FOR_COLLECTOR"

node - "$WORKDIR" "$FRAG_PROFILE" "$DIGEST" "$OUT" "$PHASE" "$CHECKS_FILE_FOR_COLLECTOR" <<'NODE'
const fs = require('node:fs'), path = require('node:path')
const [dir, profile, digest, out, phase, checksYaml] = process.argv.slice(2)

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
// ONLY checks/. The run directory also holds work/ — bib's config, the flatpak probe result, the
// image manifest — and those are inputs, not verdicts. Walking the whole tree made the strictness
// above fire on them: run 35548492085 died with "manifest.json: parsed as JSON but carries no .id".
// common.sh, run-static.sh, run-boot.sh, run-update.sh and emit-results.mjs all agree that a check
// record lives in <rundir>/checks/, so that is the only directory read.
const checksDir = path.join(dir, 'checks')
walk(checksDir)

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
// ── COMPLETENESS. A check that never reported did not pass. ─────────────────────────────────────
// checks.yaml is the contract; this reads it and fails any id the phase never reached, rather than
// letting a truncated run look like a short one. The `restore` section rides with `update`, because
// run-update.sh records R1 and build.yml merges it into the update fragment.
const SECTIONS = { static: ['static'], boot: ['boot'], update: ['update', 'restore'] }[phase] ?? []
const declared = []
if (SECTIONS.length) {
  let section = null
  for (const l of fs.readFileSync(checksYaml, 'utf8').split('\n')) {
    const top = /^([a-z_]+):\s*$/.exec(l)
    if (top) { section = top[1]; continue }
    const m = /^\s+- id:\s*([A-Za-z0-9]+)\s*$/.exec(l)
    if (m && SECTIONS.includes(section)) declared.push(m[1])
  }
  if (!declared.length) {
    console.error(`matrix/run.sh: parsed ZERO check ids for phase "${phase}" out of ${checksYaml}.`)
    console.error('  The matrix definition is what "complete" means. A definition we cannot read is not an empty one.')
    process.exit(1)
  }
}
for (const id of declared) {
  if (best.has(id)) continue
  best.set(id, {
    id,
    status: 'fail',
    detail: `the ${phase} phase recorded NO verdict for ${id}. checks.yaml declares it, the harness never reached it, and an absent answer is a failure rather than an unknown. The implementation exited before this point — read the run directory's logs, not this string, for where.`,
  })
}

const merged = [...best.values()].sort((a, b) => a.id.localeCompare(b.id))

if (merged.length === 0) {
  console.error(`matrix/run.sh: phase produced ZERO checks under ${dir}.`)
  console.error('  An empty fragment must never be written: build.yml asserts checks.length > 0, but a')
  console.error('  fragment that never appears would be just as dangerous, so we fail here instead.')
  // Rule 2: print what IS there. The .jsonl bug above presented as exactly this message, and the
  // message said nothing about the two perfectly good result files sitting in the directory.
  console.error(`  result files considered under ${checksDir} (*.json, *.jsonl): ${seenFiles.length ? seenFiles.join(', ') : 'NONE'}`)
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

# `require(process.argv[1])` was the bug here, and it is why this line had never been seen to work:
# node treats a relative specifier that does not begin with ./ as a MODULE NAME, and build.yml
# passes exactly that — `--out fragments/static.json`. The fragment was written correctly and then:
#     Error: Cannot find module 'fragments/static.json'
# Under `set -e` that killed run.sh with node's exit 1, so the phase reported failure whatever the
# checks said, INCLUDING a phase in which every check passed. Measured: run 35548759944.
# Read the file; do not import it.
FAILED=$(node -e 'const fs=require("node:fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.checks.filter(c=>c.status!=="pass").length))' "$OUT")
if [ "$FAILED" != "0" ]; then
  echo "matrix/run.sh: phase '$PHASE' had $FAILED non-passing check(s) — see $OUT" >&2
  exit 1
fi
if [ "$PHASE_RC" != 0 ]; then
  # Every recorded check passed and the implementation still exited non-zero. That is not a check
  # failure, it is the harness falling over somewhere it does not record — which is worse, because
  # it is the state that would otherwise be reported as a clean pass.
  echo "matrix/run.sh: every check in $OUT passed, but the ${PHASE} implementation exited ${PHASE_RC}." >&2
  echo "  A harness that fails outside the checks is not a passing run. Refusing to report one." >&2
  exit "$PHASE_RC"
fi

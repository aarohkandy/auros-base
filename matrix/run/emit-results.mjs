#!/usr/bin/env node
// emit-results.mjs — assemble results.json from the run's check fragments, validate it against
// matrix/results.schema.json, and REFUSE TO EMIT ANYTHING THAT DOES NOT VALIDATE.
//
// The schema says it: "Fails closed: anything that does not validate against this schema is treated as
// a FAIL, never as an unknown." So when validation fails this program writes results.invalid.json for
// a human to read, writes NO results.json, and exits non-zero. There is no --force.
//
// usage:
//   emit-results.mjs --run-dir DIR --image REF --digest sha256:… --run-url URL
//                    [--recipe NAME] [--profiles a,b,c] [--update-profile uefi-modern]
//                    [--started-at ISO] [--removal-report FILE] [--pull-delta N] [--out FILE]
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { loadChecks, loadProfiles, requiredFor, DEFAULT_UPDATE_PROFILE, MATRIX_DIR } from './lib/matrix.mjs';
import { validate } from './lib/validate.mjs';

const a = {};
for (let i = 2; i < process.argv.length; i++) {
  if (!process.argv[i].startsWith('--')) continue;
  const k = process.argv[i].slice(2);
  a[k] = process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[++i] : 'true';
}
const RUN_DIR = a['run-dir'] ?? join(process.cwd(), 'matrix-run');
const OUT = a.out ?? join(RUN_DIR, 'results.json');
const UPDATE_PROFILE = a['update-profile'] ?? DEFAULT_UPDATE_PROFILE;
const fail = (m) => { console.error(`emit-results: ${m}`); process.exit(2); };

for (const k of ['image', 'digest', 'run-url']) if (!a[k]) fail(`--${k} is required. A result that cannot be tied to an image and a re-openable CI run is not evidence.`);
if (!/^sha256:[a-f0-9]{64}$/.test(a.digest)) fail(`--digest must be a content digest, not a tag: got "${a.digest}". A tag can be moved after the test passed.`);

const checks = loadChecks();
const allProfiles = loadProfiles();

// ── read the fragments ──────────────────────────────────────────────────────────────────────────
const dir = join(RUN_DIR, 'checks');
if (!existsSync(dir)) fail(`no ${dir} — nothing ran`);
function readJsonl(file) {
  const out = [];
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t) continue;
    let o; try { o = JSON.parse(t); } catch { fail(`unparseable record in ${file}: ${t.slice(0, 120)}`); }
    if (!o.id || !o.status) fail(`record without id/status in ${file}: ${t.slice(0, 120)}`);
    out.push(o);
  }
  return out;
}
// Later records win: a second boot's B2 supersedes the first boot's.
function collapse(records) {
  const m = new Map();
  for (const r of records) m.set(r.id, r);
  return m;
}

const files = readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
const staticRecs = collapse(files.filter((f) => f === 'static.jsonl').flatMap((f) => readJsonl(join(dir, f))));
const updateRecs = collapse(files.filter((f) => f === 'update.jsonl').flatMap((f) => readJsonl(join(dir, f))));
const bootRecs = new Map();   // profile -> Map(id -> rec)
for (const f of files) {
  const m = /^boot-(.+)\.jsonl$/.exec(f);
  if (!m) continue;
  bootRecs.set(m[1], collapse(readJsonl(join(dir, f))));
}

let profileIds = a.profiles ? a.profiles.split(',').map((s) => s.trim()).filter(Boolean) : [...bootRecs.keys()];
if (!profileIds.length) fail('no profiles: neither --profiles nor any checks/boot-*.jsonl fragment');
for (const p of profileIds) if (!allProfiles.ids.includes(p)) fail(`profile "${p}" is not in ${allProfiles.source}`);

// ── assemble ────────────────────────────────────────────────────────────────────────────────────
const clean = (r) => {
  const o = { id: r.id, status: r.status };
  if (r.skip_reason) o.skip_reason = String(r.skip_reason);
  if (r.detail) o.detail = String(r.detail).slice(0, 4000);
  if (Number.isFinite(r.duration_ms)) o.duration_ms = Math.max(0, Math.round(r.duration_ms));
  return o;
};

const profiles = [];
const notes = [];
for (const pid of profileIds) {
  const list = [];
  // Static checks are properties of the IMAGE. They are evaluated once and copied into every profile,
  // with the detail saying so, because the schema has no image-level slot and a missing check must
  // never be mistakable for a passing one.
  for (const id of checks.groups.static) {
    const r = staticRecs.get(id);
    if (r) list.push(clean({ ...r, detail: `[image-level, evaluated once for ${a.digest}] ${r.detail ?? ''}`.trim() }));
    else { list.push({ id, status: 'fail', detail: `no record: the static harness never reported ${id}. A check that did not report did not pass.` }); notes.push(`${pid}: ${id} missing`); }
  }
  const boots = bootRecs.get(pid);
  for (const id of checks.groups.boot) {
    const r = boots?.get(id);
    if (r) list.push(clean(r));
    else { list.push({ id, status: 'fail', detail: `no record: profile ${pid} produced no result for ${id}` }); notes.push(`${pid}: ${id} missing`); }
  }
  if (pid === UPDATE_PROFILE) {
    for (const id of [...checks.groups.update, ...checks.groups.restore]) {
      const r = updateRecs.get(id);
      if (r) list.push(clean(r));
      else { list.push({ id, status: 'fail', detail: `no record: the update harness never reported ${id}` }); notes.push(`${pid}: ${id} missing`); }
    }
  }
  profiles.push({ profile: pid, checks: list });
}

// The verdict written here is a convenience for humans and is recomputed (and ignored) by
// record-pass.mjs. It is computed honestly anyway, because a harness that writes a verdict it does not
// believe is a harness nobody can debug.
const everyOk = profiles.every((p) => {
  const req = new Set(requiredFor(checks, p.profile, UPDATE_PROFILE));
  const byId = new Map(p.checks.map((c) => [c.id, c]));
  return [...req].every((id) => byId.get(id)?.status === 'pass');
});

const results = {
  digest: a.digest,
  image: a.image,
  recipe: a.recipe && a.recipe !== 'null' ? a.recipe : null,
  matrix_version: checks.matrix_version,
  started_at: a['started-at'] ?? isoOf(dir),
  finished_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  run_url: a['run-url'],
  profiles,
  verdict: everyOk ? 'pass' : 'fail',
};

if (a['removal-report'] && existsSync(a['removal-report'])) {
  try {
    const rr = JSON.parse(readFileSync(a['removal-report'], 'utf8'));
    const arr = rr.packages ?? rr.removed ?? [];
    const bytes = arr.reduce((s, e) => s + (Number(e?.bytes ?? e?.size ?? 0) || 0), 0);
    const o = { packages_removed: arr.length, bytes_reclaimed: bytes };
    if (a['pull-delta'] !== undefined && a['pull-delta'] !== 'true') o.pull_size_delta_bytes = Number(a['pull-delta']);
    results.removal_report = o;
  } catch (e) { fail(`--removal-report ${a['removal-report']} does not parse: ${e.message}`); }
} else if (a['pull-delta'] !== undefined && a['pull-delta'] !== 'true') {
  results.removal_report = { packages_removed: 0, bytes_reclaimed: 0, pull_size_delta_bytes: Number(a['pull-delta']) };
}

function isoOf(p) { try { return new Date(statSync(p).birthtimeMs || statSync(p).mtimeMs).toISOString().replace(/\.\d+Z$/, 'Z'); } catch { return new Date().toISOString().replace(/\.\d+Z$/, 'Z'); } }

// ── validate, then and only then write ──────────────────────────────────────────────────────────
const schemaPath = join(MATRIX_DIR, 'results.schema.json');
let errors;
try {
  errors = validate(JSON.parse(readFileSync(schemaPath, 'utf8')), results);
} catch (e) {
  writeFileSync(join(RUN_DIR, 'results.invalid.json'), JSON.stringify(results, null, 2));
  fail(`could not validate against ${schemaPath}: ${e.message}. Wrote results.invalid.json. An unvalidatable result is a FAIL.`);
}
if (errors.length) {
  writeFileSync(join(RUN_DIR, 'results.invalid.json'), JSON.stringify(results, null, 2));
  console.error('emit-results: the assembled result does not validate against results.schema.json:');
  for (const e of errors) console.error(`  - ${e}`);
  fail(`${errors.length} schema violation(s). Wrote ${join(RUN_DIR, 'results.invalid.json')} and NO results.json. An unvalidatable result is a FAIL, never an unknown.`);
}

writeFileSync(OUT, JSON.stringify(results, null, 2) + '\n');
console.log(`emit-results: wrote ${OUT}`);
console.log(`  digest ${results.digest}`);
console.log(`  matrix_version ${results.matrix_version} · ${results.profiles.length} profile(s) · update group on "${UPDATE_PROFILE}"`);
for (const p of results.profiles) {
  const f = p.checks.filter((c) => c.status === 'fail').map((c) => c.id);
  const s = p.checks.filter((c) => c.status === 'skip').map((c) => c.id);
  console.log(`  ${p.profile}: ${p.checks.length} checks, ${f.length} fail${f.length ? ` (${f.join(' ')})` : ''}${s.length ? `, ${s.length} skip (${s.join(' ')}) — a skipped required check counts as a failure` : ''}`);
}
if (notes.length) console.log(`  ${notes.length} check(s) had no record at all and were written as failures`);
console.log(`  advisory verdict: ${results.verdict}  (record-pass.mjs recomputes this and ignores the field)`);

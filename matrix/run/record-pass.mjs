#!/usr/bin/env node
// record-pass.mjs — the only thing permitted to write a pass into attest/passed-digests.tsv.
//
// It RECOMPUTES the verdict from the checks array and IGNORES results.json's own `verdict` field,
// because a field that says "pass" is exactly what a broken or malicious harness would write. It also
// ignores the profile list the harness claims to have run, and derives the bound set itself.
//
// Rules, none of which have a flag:
//   - `skip` on a required check is a FAIL.
//   - a required check with NO record is a FAIL.
//   - a profile that was bound but has no entry is a FAIL.
//   - matrix_version must equal the current checks.yaml, because a pass under an older, weaker matrix
//     is not evidence of a pass under this one.
//   - the digest must be a digest.
//
// compat.tsv rows are appended on EVERY run, pass or fail — a failed VM run is still an observation,
// and the row carries the outcome in its notes. The ledger is appended on a full pass only.
//
// usage: record-pass.mjs --results results.json [--bound-profiles a,b] [--compat-rows FILE]
//                        [--ledger FILE] [--compat-tsv FILE] [--dry-run]
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import { loadChecks, loadProfiles, requiredFor, DEFAULT_UPDATE_PROFILE, META_REPO, MATRIX_DIR } from './lib/matrix.mjs';
import { validate } from './lib/validate.mjs';

const a = {};
for (let i = 2; i < process.argv.length; i++) {
  if (!process.argv[i].startsWith('--')) continue;
  const k = process.argv[i].slice(2);
  a[k] = process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[++i] : 'true';
}
const die = (m) => { console.error(`record-pass: ${m}`); process.exit(1); };
if (!a.results) die('--results is required');

const LEDGER = a.ledger ?? join(META_REPO, 'attest', 'passed-digests.tsv');
const COMPAT = a['compat-tsv'] ?? join(META_REPO, 'hardware', 'compat.tsv');
const UPDATE_PROFILE = a['update-profile'] ?? DEFAULT_UPDATE_PROFILE;
const DRY = a['dry-run'] === 'true';

// ── ASSUMED CONVENTION, and the one thing in this file most likely to need changing. ────────────
// attest/passed-digests.tsv belongs to the publish-gate work item (TASKS 0.5, tools/gate.mjs), which is
// not written yet. These are the columns this harness will write. If gate.mjs defines a different
// header, THIS FILE is the single place to change — and the code below refuses to append to a file
// whose header differs rather than writing a row nobody can read.
const LEDGER_COLUMNS = [
  'digest', 'image', 'recipe', 'matrix_version', 'profiles', 'verdict',
  'results_sha256', 'pull_size_bytes', 'run_url', 'recorded_at', 'recorded_by',
];

const checks = loadChecks();
const known = loadProfiles();

// ── read and re-validate. A result we cannot validate is a FAIL, not an unknown. ────────────────
let results;
try { results = JSON.parse(readFileSync(a.results, 'utf8')); }
catch (e) { die(`${a.results} does not parse: ${e.message}`); }
const schema = JSON.parse(readFileSync(join(MATRIX_DIR, 'results.schema.json'), 'utf8'));
const schemaErrors = validate(schema, results);
if (schemaErrors.length) {
  console.error('record-pass: results.json does not validate:');
  for (const e of schemaErrors) console.error(`  - ${e}`);
  die('refusing to read a verdict out of a document that does not conform to the schema');
}

if (results.matrix_version !== checks.matrix_version) {
  die(`results.json was produced under matrix_version ${results.matrix_version}, but ${checks.source} is now at ${checks.matrix_version}. A pass recorded under an older, weaker matrix is not evidence of a pass under this one — the image must re-qualify.`);
}

// ── the bound profile set, derived here rather than taken on trust ──────────────────────────────
let bound;
if (a['bound-profiles']) bound = a['bound-profiles'].split(',').map((s) => s.trim()).filter(Boolean);
else if (!results.recipe) bound = known.ids;   // a base image runs every profile (vm-check-matrix skill, step 3)
else die(`results.json is for recipe "${results.recipe}" but no --bound-profiles was given. The harness must not be the thing that decides which profiles count, or a broken harness could bind itself to one easy profile and call it a pass.`);
for (const p of bound) if (!known.ids.includes(p)) die(`bound profile "${p}" is not in ${known.source}`);

// ── recompute the verdict ───────────────────────────────────────────────────────────────────────
const byProfile = new Map(results.profiles.map((p) => [p.profile, p]));
const problems = [];
for (const pid of bound) {
  const entry = byProfile.get(pid);
  if (!entry) { problems.push(`${pid}: bound to this image but absent from results.json`); continue; }
  const byId = new Map(entry.checks.map((c) => [c.id, c]));
  for (const id of requiredFor(checks, pid, UPDATE_PROFILE)) {
    const c = byId.get(id);
    if (!c) problems.push(`${pid}/${id}: no record (a check that did not run did not pass)`);
    else if (c.status === 'skip') problems.push(`${pid}/${id}: SKIPPED${c.skip_reason ? ` — "${c.skip_reason}"` : ''} (skip is not pass)`);
    else if (c.status !== 'pass') problems.push(`${pid}/${id}: ${c.status}${c.detail ? ` — ${String(c.detail).slice(0, 200)}` : ''}`);
  }
  for (const c of entry.checks) {
    if (!checks.all.includes(c.id)) problems.push(`${pid}/${c.id}: not a check in ${checks.source} — the harness reported something the matrix does not define`);
  }
}
const extra = results.profiles.map((p) => p.profile).filter((p) => !bound.includes(p));
const computed = problems.length ? 'fail' : 'pass';

console.log(`record-pass: digest ${results.digest}`);
console.log(`  bound profiles: ${bound.join(' ')}${extra.length ? `  (results.json also carries: ${extra.join(' ')})` : ''}`);
console.log(`  harness wrote verdict="${results.verdict}" — ignored`);
console.log(`  RECOMPUTED VERDICT: ${computed}`);
if (results.verdict !== computed) console.log(`  !! the harness's own verdict disagrees with the recomputed one. Trust this line, not that field.`);
for (const p of problems) console.log(`    - ${p}`);

// ── compat.tsv rows: appended whether we passed or not ──────────────────────────────────────────
const COMPAT_HEADER = ['model','year','source','cpu','ram_gb','firmware','wifi','trackpad','suspend','brightness','gpu','audio','webcam','verdict','notes','tested_on','tester'];
const rowsFile = a['compat-rows'] ?? join(dirname(a.results), 'compat-rows.tsv');
let rowsWritten = 0, rowsSkipped = 0;
if (existsSync(rowsFile)) {
  if (!existsSync(COMPAT)) { mkdirSync(dirname(COMPAT), { recursive: true }); writeFileSync(COMPAT, COMPAT_HEADER.join('\t') + '\n'); }
  const current = readFileSync(COMPAT, 'utf8');
  const header = current.split('\n')[0].split('\t');
  if (header.join('\t') !== COMPAT_HEADER.join('\t')) {
    console.error(`record-pass: ${COMPAT} has a header this harness does not recognise; not appending. Expected:\n  ${COMPAT_HEADER.join('\t')}`);
  } else {
    for (const line of readFileSync(rowsFile, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      const cols = line.split('\t');
      // THE HONESTY RULE (hardware/README.md, profiles.yaml): a vm row leaves the physical-only columns
      // EMPTY, and its verdict is never a support claim. Enforced here as well as at the point of
      // writing, because this is the file a customer quote would eventually be built from.
      const idx = (n) => COMPAT_HEADER.indexOf(n);
      if (cols[idx('source')] !== 'vm') { console.error(`record-pass: refusing a non-vm row from the harness: ${line.slice(0, 80)}`); rowsSkipped++; continue; }
      const dirty = ['wifi', 'trackpad', 'suspend', 'brightness', 'webcam'].filter((c) => (cols[idx(c)] ?? '') !== '');
      if (dirty.length) { console.error(`record-pass: refusing a vm row that fills physical-only column(s) ${dirty.join(',')} — a QEMU profile has no Wi-Fi chipset, trackpad, backlight, firmware suspend or webcam, and a filled cell there is manufactured confidence we would later quote a school from`); rowsSkipped++; continue; }
      if (cols[idx('verdict')] !== 'untested') { console.error(`record-pass: refusing a vm row whose verdict is "${cols[idx('verdict')]}" — a vm row is not a statement about a machine, and "unsupported" is a §9 decision reserved for the human`); rowsSkipped++; continue; }
      if (current.includes(line.trim())) { rowsSkipped++; continue; }
      if (!DRY) appendFileSync(COMPAT, line.trimEnd() + '\n');
      rowsWritten++;
    }
  }
  console.log(`  compat.tsv: ${rowsWritten} row(s) appended, ${rowsSkipped} skipped${DRY ? ' (dry run)' : ''}`);
}

// ── the ledger ──────────────────────────────────────────────────────────────────────────────────
if (computed !== 'pass') {
  console.log(`  NOT recording a pass. ${problems.length} problem(s) above.`);
  process.exit(1);
}

const resultsSha = createHash('sha256').update(readFileSync(a.results)).digest('hex');
const pullBytes = (() => { const p = join(dirname(a.results), 'work', 'pull-bytes'); try { return readFileSync(p, 'utf8').trim() || '0'; } catch { return '0'; } })();
const row = [
  results.digest, results.image, results.recipe ?? '-', String(results.matrix_version),
  bound.join(','), 'pass', resultsSha, pullBytes, results.run_url,
  new Date().toISOString().replace(/\.\d+Z$/, 'Z'), 'auros-base/matrix/run/record-pass.mjs',
];
if (row.some((v) => String(v).includes('\t'))) die('a ledger field contains a tab');

if (!existsSync(LEDGER)) {
  if (!DRY) { mkdirSync(dirname(LEDGER), { recursive: true }); writeFileSync(LEDGER, LEDGER_COLUMNS.join('\t') + '\n'); }
  console.log(`  created ${LEDGER} with the assumed column set (see the comment in record-pass.mjs)`);
}
if (existsSync(LEDGER)) {
  const head = readFileSync(LEDGER, 'utf8').split('\n')[0];
  if (head.trim() !== LEDGER_COLUMNS.join('\t')) {
    die(`${LEDGER} has a different header than this harness writes.\n  ledger:  ${head}\n  harness: ${LEDGER_COLUMNS.join('\t')}\nRefusing to append a row the gate cannot read. Reconcile LEDGER_COLUMNS in record-pass.mjs with tools/gate.mjs — do not paper over it.`);
  }
  const body = readFileSync(LEDGER, 'utf8');
  if (body.includes(`\n${results.digest}\t`)) { console.log(`  ${results.digest} is already recorded; not duplicating`); process.exit(0); }
}
if (!DRY) appendFileSync(LEDGER, row.join('\t') + '\n');
console.log(`  RECORDED a full pass for ${results.digest} in ${LEDGER}${DRY ? ' (dry run — nothing written)' : ''}`);

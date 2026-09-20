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
//   - the ledger's column set is IMPORTED from tools/gate.mjs, never restated here, and the row is
//     shown to gate.decide() on a scratch copy before a byte is appended. A row the gate cannot read
//     is not written at all: under gate.mjs one malformed row refuses every digest in the file.
//
// compat.tsv rows are appended on EVERY run, pass or fail — a failed VM run is still an observation,
// and the row carries the outcome in its notes. The ledger is appended on a full pass only.
//
// usage: record-pass.mjs --results results.json [--bound-profiles a,b] [--compat-rows FILE]
//                        [--ledger FILE] [--compat-tsv FILE] [--dry-run]
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
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

const COMPAT = a['compat-tsv'] ?? join(META_REPO, 'hardware', 'compat.tsv');
const UPDATE_PROFILE = a['update-profile'] ?? DEFAULT_UPDATE_PROFILE;
const DRY = a['dry-run'] === 'true';

// ── THE COLUMN SET IS IMPORTED FROM THE GATE, NEVER COPIED ──────────────────────────────────────
// This used to be a hand-written list of 11 columns guessed before tools/gate.mjs existed. gate.mjs
// reads 9, with different names and different semantics (`profiles_passed`/`checks_passed` rather
// than `profiles`/`verdict`), and it refuses ANY ledger whose header differs — which meant every row
// this file could write would have made the gate refuse every digest in the file, not just that row.
// Two files describing the same table from memory is how that happens, so there is now exactly one
// description and this one imports it.
//
// gate.mjs lives in the meta/control repo (D6) and is not always a sibling of auros-base, so it is
// located from the ledger path itself: the ledger is always <meta-root>/attest/passed-digests.tsv,
// so <meta-root>/tools/gate.mjs is next to it. If it cannot be found we DIE rather than fall back to
// a local copy — a recorder that cannot see the gate's column set cannot know the gate will be able
// to read what it writes, and writing anyway is exactly the failure this paragraph describes.
const LEDGER = a.ledger ?? join(META_REPO, 'attest', 'passed-digests.tsv');
const META_ROOT = dirname(dirname(resolve(LEDGER)));
const GATE_CANDIDATES = [join(META_ROOT, 'tools', 'gate.mjs'), join(META_REPO, 'tools', 'gate.mjs')];
const GATE_PATH = GATE_CANDIDATES.find((p) => existsSync(p));
if (!GATE_PATH) {
  die(`cannot find tools/gate.mjs — looked in:\n  ${GATE_CANDIDATES.join('\n  ')}\n` +
      'The ledger column set is defined by the gate that reads it, and is imported from there rather ' +
      'than copied. Point --ledger at <meta-repo>/attest/passed-digests.tsv, or check the meta repo out.');
}
const gate = await import(pathToFileURL(GATE_PATH).href);
if (!Array.isArray(gate.HEADER) || gate.HEADER.length === 0) die(`${GATE_PATH} exports no HEADER — this is not the publish gate`);
if (typeof gate.decide !== 'function') die(`${GATE_PATH} exports no decide() — this is not the publish gate`);
const LEDGER_COLUMNS = [...gate.HEADER];

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

// ── the two set-valued columns the gate actually reads ──────────────────────────────────────────
// `checks_passed` is the set of check IDs that passed on EVERY profile that binds them — the
// intersection over binders, not the union over profiles. It is computed rather than taken as
// `checks.all`, because a check defined in checks.yaml that no profile binds has never been proven
// by anything, and listing it would be a pass manufactured by arithmetic. When that happens the set
// comes up short and the gate refuses with `incomplete-checks`, which is the correct outcome.
// The declared counts (the "/N" suffixes) are what stop a partial pass hiding as a short list.
const checksPassed = checks.all.filter((id) => {
  const binders = bound.filter((pid) => requiredFor(checks, pid, UPDATE_PROFILE).includes(id));
  if (binders.length === 0) return false;
  return binders.every((pid) => {
    const entry = byProfile.get(pid);
    const c = entry && entry.checks.find((x) => x.id === id);
    return !!c && c.status === 'pass';
  });
});

const resultsSha = createHash('sha256').update(readFileSync(a.results)).digest('hex');
const pullBytes = (() => { const p = join(dirname(a.results), 'work', 'pull-bytes'); try { return readFileSync(p, 'utf8').trim() || '0'; } catch { return '0'; } })();
// results_sha256 and pull_size_bytes have no column in the gate's ledger; they are printed here and
// live in the run's artifact rather than being smuggled into a table that cannot hold them.
console.log(`  results.json sha256: ${resultsSha}`);
console.log(`  pull size (bytes):   ${pullBytes}`);

const rowByName = {
  digest: results.digest,
  image: results.image,
  recipe: results.recipe ?? '-',
  matrix_version: String(results.matrix_version),
  profiles_passed: `${bound.join(',')}/${bound.length}`,
  checks_passed: `${checksPassed.join(',')}/${checks.all.length}`,
  run_url: results.run_url,
  recorded_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  recorded_by: 'auros-base/matrix/run/record-pass.mjs',
};
const unknownCols = LEDGER_COLUMNS.filter((c) => !(c in rowByName));
if (unknownCols.length) {
  die(`tools/gate.mjs declares ledger column(s) this recorder has no value for: ${unknownCols.join(', ')}. ` +
      'The gate changed its table and this file has not caught up — fix it here rather than writing an empty cell.');
}
const row = LEDGER_COLUMNS.map((c) => rowByName[c]);
if (row.some((v) => String(v).includes('\t'))) die('a ledger field contains a tab');

// ── the header, read past the ledger's own documentation ────────────────────────────────────────
// attest/passed-digests.tsv opens with a 50-line comment block explaining the format. Reading
// `.split('\n')[0]` therefore compared a sentence beginning "# AUROS ATTESTATION LEDGER" against a
// tab-joined column list, which can never match, so this guard died on every well-formed ledger.
// The header is the first line that is neither blank nor a comment — the same rule parseLedger uses.
const ledgerHeaderOf = (text) => text.split('\n').find((l) => l.trim() !== '' && !l.startsWith('#'));

if (!existsSync(LEDGER)) {
  if (!DRY) { mkdirSync(dirname(LEDGER), { recursive: true }); writeFileSync(LEDGER, LEDGER_COLUMNS.join('\t') + '\n'); }
  console.log(`  created ${LEDGER} with the column set imported from ${GATE_PATH}`);
}
if (existsSync(LEDGER)) {
  const head = ledgerHeaderOf(readFileSync(LEDGER, 'utf8'));
  if (head === undefined) {
    die(`${LEDGER} has no header row — it is empty or entirely comments. The gate refuses such a file outright.`);
  }
  if (head.trim() !== LEDGER_COLUMNS.join('\t')) {
    die(`${LEDGER} has a different header than the gate declares.\n  ledger:  ${head}\n  gate:    ${LEDGER_COLUMNS.join('\t')}\nRefusing to append a row the gate cannot read. The column set comes from ${GATE_PATH}; reconcile the FILE, not this program.`);
  }
  const body = readFileSync(LEDGER, 'utf8');
  if (body.includes(`\n${results.digest}\t`)) { console.log(`  ${results.digest} is already recorded; not duplicating`); process.exit(0); }
}

// ── PROVE THE GATE CAN READ IT, BEFORE WRITING IT ───────────────────────────────────────────────
// The row is appended to a COPY first and the real gate is asked to decide on that copy. If it
// refuses, nothing is written and this program exits non-zero naming the gate's own reason. This is
// not the gate certifying itself: the gate that guards the publish reads the COMMITTED ledger from a
// fresh checkout, in a different job. This is only the recorder refusing to write a row that would
// poison the file — under gate.mjs a single malformed row refuses every digest in it, so a bad append
// here is an outage for every image, not just this one.
{
  const existing = existsSync(LEDGER) ? readFileSync(LEDGER, 'utf8') : LEDGER_COLUMNS.join('\t') + '\n';
  const probe = `${LEDGER}.probe-${process.pid}.tsv`;
  writeFileSync(probe, existing + row.join('\t') + '\n');
  let verdict;
  try {
    verdict = gate.decide({ digest: results.digest, image: results.image }, {
      ledger: probe,
      config: join(META_ROOT, 'auros.config.json'),
      checks: join(MATRIX_DIR, 'checks.yaml'),
      profiles: join(MATRIX_DIR, 'profiles.yaml'),
    });
  } finally { try { unlinkSync(probe); } catch { /* the probe is disposable */ } }
  if (!verdict.allowed) {
    die(`the row this run would write is one the gate REFUSES [${verdict.code}]:\n  ${verdict.reason}\n` +
        `  row: ${row.join(' | ')}\nNothing was written. A row the gate cannot accept is worse than no row, ` +
        'because a malformed ledger refuses every digest in it.');
  }
  console.log(`  gate pre-flight: ALLOW (${verdict.code}) — the committed row will be readable by tools/gate.mjs`);
}

if (!DRY) appendFileSync(LEDGER, row.join('\t') + '\n');
console.log(`  RECORDED a full pass for ${results.digest} in ${LEDGER}${DRY ? ' (dry run — nothing written)' : ''}`);
console.log(`  row: ${row.join('\t')}`);

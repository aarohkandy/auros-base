// S11 — the removal floor — against synthetic before/after package lists.  node --test "matrix/**/*.test.mjs"
//
// The count must come from the images (built-from rpms minus built rpms), never from the plan. The
// first two cases are the whole point: a plan that names 57 while the image lost 1200 passes a floor
// of 1100, and a plan that names 1200 while the image lost 57 fails it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ANALYZE = join(dirname(fileURLToPath(import.meta.url)), 'analyze.mjs');
const pkgs = (n, p = 'pkg') => Array.from({ length: n }, (_, i) => `${p}${i}`);

// before: the built-from image. removed: how many of its packages the built image lacks.
function s11({ before = 1500, removed, plan = [], floor, recipe = 'example-kiosk', probeOk = true, fromFile = true }) {
  const dir = mkdtempSync(join(tmpdir(), 'auros-s11-'));
  const from = pkgs(before);
  const after = [...from.slice(removed), 'auros-added-by-recipe'];
  writeFileSync(join(dir, 'probe.txt'), `PROBE_OK=${probeOk ? 1 : 0}\n---RPM-NAMES---\n${after.map((n) => `${n}\t100`).join('\n')}\n---END---\n`);
  writeFileSync(join(dir, 'from.txt'), from.join('\n') + '\n');
  writeFileSync(join(dir, 'plan.txt'), plan.join('\n') + '\n');
  const out = join(dir, 'out.jsonl');
  const args = [ANALYZE, '--probe', join(dir, 'probe.txt'), '--out', out, '--recipe', recipe, '--policy', 'kiosk',
    '--declared-remove', join(dir, 'plan.txt')];
  if (fromFile) args.push('--from-rpms', join(dir, 'from.txt'));
  if (floor !== undefined) args.push('--floor', String(floor));
  const r = spawnSync(process.execPath, args, { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const rows = readFileSync(out, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const row = rows.find((x) => x.id === 'S11');
  assert.ok(row, 'S11 was not recorded at all');
  return row;
}

test('plan said 57, image removed 1200: floor 1100 PASSES on the measurement', () => {
  const r = s11({ removed: 1200, plan: pkgs(57), floor: 1100 });
  assert.equal(r.status, 'pass', r.detail);
  assert.match(r.detail, /measured 1200 package\(s\) removed/);
});

test('plan said 1200, image removed 57: floor 1100 FAILS on the measurement', () => {
  const r = s11({ removed: 57, plan: pkgs(1200), floor: 1100 });
  assert.equal(r.status, 'fail', r.detail);
  assert.match(r.detail, /measured 57 package\(s\) removed/);
});

// The built image also carries one package the recipe ADDED, so a count by rpm-total difference
// would say 239 here and fail; a count by name says 240.
test('exactly the floor passes; one short fails', () => {
  assert.equal(s11({ removed: 240, floor: 240 }).status, 'pass');
  assert.equal(s11({ removed: 239, floor: 240 }).status, 'fail');
});

test('fails closed: recipe with no floor, unmeasured built-from image, probe that did not run', () => {
  assert.equal(s11({ removed: 1200 }).status, 'fail');
  assert.equal(s11({ removed: 1200, floor: 0 }).status, 'fail');
  const unmeasured = s11({ removed: 1200, floor: 1100, fromFile: false });
  assert.equal(unmeasured.status, 'fail');
  assert.match(unmeasured.detail, /was not measured/, 'an unmeasured count must say so, not report "0 removed"');
  assert.equal(s11({ removed: 1200, floor: 1100, probeOk: false }).status, 'fail');
});

test('a base build (run-static.sh passes --recipe "") declares no floor and passes', () => {
  const r = s11({ removed: 0, recipe: '' });
  assert.equal(r.status, 'pass', r.detail);
  assert.match(r.detail, /base build/);
});

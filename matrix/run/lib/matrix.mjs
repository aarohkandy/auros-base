// matrix.mjs — the one place that reads checks.yaml / profiles.yaml and decides WHICH checks are
// REQUIRED on WHICH profile. record-pass.mjs is the consumer that matters; emit-results.mjs uses it
// only to warn. Keep the policy here and nowhere else.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseYaml } from './yaml-lite.mjs';

export const RUN_DIR = dirname(dirname(fileURLToPath(import.meta.url)));   // .../matrix/run
export const MATRIX_DIR = dirname(RUN_DIR);                                 // .../matrix
export const BASE_REPO = dirname(MATRIX_DIR);                               // .../auros-base
export const META_REPO = dirname(BASE_REPO);                                // .../auros

export function loadChecks(path = join(MATRIX_DIR, 'checks.yaml')) {
  const y = parseYaml(readFileSync(path, 'utf8'));
  if (!Number.isInteger(y.matrix_version)) throw new Error('checks.yaml: matrix_version missing or not an integer');
  const ids = (g) => (y[g] ?? []).map((c) => {
    if (!c || typeof c.id !== 'string') throw new Error(`checks.yaml: entry in "${g}" has no id`);
    return c.id;
  });
  const groups = { static: ids('static'), boot: ids('boot'), update: ids('update'), restore: ids('restore') };
  const all = [...groups.static, ...groups.boot, ...groups.update, ...groups.restore];
  if (new Set(all).size !== all.length) throw new Error('checks.yaml: duplicate check id');
  if (!all.length) throw new Error('checks.yaml: no checks defined — refusing to treat an empty matrix as a gate');
  return { matrix_version: y.matrix_version, groups, all, source: path };
}

export function loadProfiles(path = join(MATRIX_DIR, 'profiles.yaml')) {
  const y = parseYaml(readFileSync(path, 'utf8'));
  const list = y.profiles ?? [];
  if (!list.length) throw new Error('profiles.yaml: no profiles defined');
  return { profiles: list, ids: list.map((p) => p.id), not_provable_in_vm: y.not_provable_in_vm ?? [], source: path };
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// THE REQUIRED-SET POLICY. checks.yaml says boot checks run "once per hardware profile" and that the
// static group runs "against the OCI image", but it does not say how the update/restore groups bind to
// profiles. results.schema.json only has room for checks under a profile. So:
//
//   static (S*)         REQUIRED on every profile. They are properties of the image, not of the
//                       machine definition, so the harness evaluates them once and copies the result
//                       into every profile entry, with `detail` saying so.
//   boot (B*)           REQUIRED on every profile. Genuinely re-run per profile.
//   update+restore      REQUIRED on the designated update profile (default uefi-modern) and recorded
//   (U*, R1)            ONLY there. Absent elsewhere — absent is not `skip`; a profile that never
//                       claimed to run U3 is different from one that skipped it.
//
// This is the harness author's reading, not something checks.yaml states. It is written down here, in
// one place, so that disagreeing with it is a one-line change with a visible diff rather than an
// assumption buried in a shell script.
// ─────────────────────────────────────────────────────────────────────────────────────────────────
export const DEFAULT_UPDATE_PROFILE = 'uefi-modern';

export function requiredFor(checks, profile, updateProfile = DEFAULT_UPDATE_PROFILE) {
  const req = [...checks.groups.static, ...checks.groups.boot];
  if (profile === updateProfile) req.push(...checks.groups.update, ...checks.groups.restore);
  return req;
}

export function readJson(path) { return JSON.parse(readFileSync(path, 'utf8')); }

export function auросConfig() { /* intentionally unused alias guard */ }

export function loadConfig() {
  const p = join(META_REPO, 'auros.config.json');
  if (!existsSync(p)) return null;
  return readJson(p);
}

export function resolveFrom(cwd, p) { return resolve(cwd, p); }

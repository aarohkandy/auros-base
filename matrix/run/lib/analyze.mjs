#!/usr/bin/env node
// analyze.mjs — evaluates the static checks whose logic is set arithmetic or JSON, from the output of
// guest/image-probe.sh. S3, S4, S5, S9 and S10 live here; S1/S2/S6/S7/S8 stay in run-static.sh because
// they are about the registry and the build, not about the image's contents.
//
// Appends JSON Lines to --out, in the same shape common.sh's record() writes.
import { readFileSync, appendFileSync, existsSync } from 'node:fs';

const args = parseArgs(process.argv.slice(2));
const OUT = args.out ?? '/dev/stdout';
const t0 = Date.now();

function parseArgs(a) {
  const o = {};
  for (let i = 0; i < a.length; i++) {
    if (!a[i].startsWith('--')) continue;
    const k = a[i].slice(2);
    // `a[i + 1] &&` was the bug, and it cost S3 on every base build. run-static.sh passes
    // `--recipe ""` for a base image; an EMPTY STRING is falsy, so the flag was treated as a bare
    // boolean and took the literal value 'true'. `isBase` then read the recipe name as "true",
    // S3 stopped holding vacuously over zero packages, and the check recorded
    //   FAIL  recipe "true" resolved an EMPTY removal set
    // on an image that has no recipe and is not supposed to remove anything. Measured on a real run
    // against a bare derivative; the hardened base would have failed S3 the same way, forever.
    // PRESENCE, not truthiness: only an absent token or the next flag ends an option.
    const next = a[i + 1];
    const v = next !== undefined && !next.startsWith('--') ? a[++i] : 'true';
    o[k] = v;
  }
  return o;
}
function rec(id, status, detail) {
  appendFileSync(OUT, JSON.stringify({ id, status, detail: String(detail).slice(0, 4000), duration_ms: Date.now() - t0 }) + '\n');
  process.stdout.write(`  [${status.toUpperCase()}] ${id} — ${detail}\n`);
}
function lines(p) {
  if (!p || !existsSync(p)) return [];
  return readFileSync(p, 'utf8').split('\n').map((s) => s.trim()).filter((s) => s && !s.startsWith('#'));
}

// ── probe output ────────────────────────────────────────────────────────────────────────────────
const probeText = readFileSync(args.probe, 'utf8');
const kv = {};
const rpms = new Map();           // name -> size (bytes, as rpm reports installed size)
{
  let inRpm = false;
  for (const line of probeText.split('\n')) {
    if (line === '---RPM-NAMES---') { inRpm = true; continue; }
    if (line === '---END---') { inRpm = false; continue; }
    if (inRpm) {
      const [n, s] = line.split('\t');
      if (n) rpms.set(n, Number(s) || 0);
      continue;
    }
    const i = line.indexOf('=');
    if (i > 0) kv[line.slice(0, i)] = line.slice(i + 1);
  }
}
if (kv.PROBE_OK !== '1') {
  for (const id of ['S3', 'S4', 'S5', 'S9', 'S10']) rec(id, 'fail', 'in-image probe did not complete; nothing about this image could be established');
  process.exit(0);
}

const isBase = !args.recipe || args.recipe === 'null' || args.recipe === '';
const b64 = (k) => (kv[k] ? Buffer.from(kv[k], 'base64').toString('utf8') : null);

// Upstream package set, if the pinned base image was available to measure against.
const upstream = new Map();
for (const l of lines(args['upstream-rpms'])) {
  const [n, s] = l.split('\t');
  if (n) upstream.set(n, Number(s) || 0);
}
const measuredClosure = upstream.size ? [...upstream.keys()].filter((n) => !rpms.has(n)).sort() : null;

// ── removal report ──────────────────────────────────────────────────────────────────────────────
const SEARCHED = '/usr/share/auros/removal-report.json, /usr/lib/auros/removal-report.json, /etc/auros/removal-report.json';
let report = null, reportErr = null;
if (kv.REMOVAL_REPORT_PATH) {
  try { report = JSON.parse(b64('REMOVAL_REPORT_B64') ?? '{}'); }
  catch (e) { reportErr = `parse error in ${kv.REMOVAL_REPORT_PATH}: ${e.message}`; }
}
// Accept either {"packages":[{name,bytes}...]} or {"packages":["name",...]} or {"removed":[...]}.
function reportEntries(r) {
  if (!r) return null;
  const arr = r.packages ?? r.removed ?? r.removals ?? null;
  if (!Array.isArray(arr)) return null;
  return arr.map((e) => (typeof e === 'string' ? { name: e, bytes: null } : { name: e.name ?? e.package ?? e.nevra, bytes: e.bytes ?? e.size ?? e.bytes_reclaimed ?? null }));
}
const entries = reportEntries(report);
const declaredRemove = lines(args['declared-remove']);

// ── S3 — prune assertions ───────────────────────────────────────────────────────────────────────
{
  const removalSet = entries ? entries.map((e) => e.name).filter(Boolean)
    : declaredRemove.length ? declaredRemove : [];
  const source = entries ? `removal report (${kv.REMOVAL_REPORT_PATH})` : declaredRemove.length ? 'recipe remove: list' : 'none';
  if (!removalSet.length) {
    if (isBase) rec('S3', 'pass', `removal set is empty for a base build; criterion holds vacuously over 0 packages. ${rpms.size} rpms installed.`);
    else rec('S3', 'fail', `recipe "${args.recipe}" resolved an EMPTY removal set (source: ${source}). Subtraction is the product; a recipe that removes nothing is a recipe that was not compiled.`);
  } else {
    const survivors = removalSet.filter((n) => rpms.has(n));
    if (survivors.length) rec('S3', 'fail', `${survivors.length}/${removalSet.length} package(s) marked for removal are still installed: ${survivors.slice(0, 25).join(' ')}${survivors.length > 25 ? ' …' : ''}. Source: ${source}. DO NOT RETRY THIS — upstream re-adding a pruned dependency is what this check is for.`);
    else rec('S3', 'pass', `all ${removalSet.length} package(s) in the removal set are absent (source: ${source}); ${rpms.size} rpms remain installed`);
  }
}

// ── S4 — keep assertions ────────────────────────────────────────────────────────────────────────
{
  const want = lines(args['install-rpms']);
  // Exact rpm NAME matching. No prefix heuristics: "firefox" must not be satisfied by
  // "firefox-langpacks", and a near-miss that silently counts as a hit is how a keep assertion stops
  // asserting anything.
  const missing = want.filter((n) => !rpms.has(n));
  let fp = { status: 'pass', detail: 'no flatpak refs declared' };
  if (args['flatpak-result'] && existsSync(args['flatpak-result'])) {
    try { fp = JSON.parse(readFileSync(args['flatpak-result'], 'utf8')); } catch { fp = { status: 'fail', detail: 'flatpak result file unreadable' }; }
  }
  if (missing.length) rec('S4', 'fail', `declared install: package(s) not present in the image: ${missing.join(' ')}`);
  else if (fp.status !== 'pass') rec('S4', 'fail', `rpm half ok (${want.length} present); flatpak half FAILED: ${fp.detail}`);
  else rec('S4', 'pass', `${want.length} declared rpm(s) present; flatpak: ${fp.detail}`);
}

// ── S5 — the removal report is a measurement, not a claim ───────────────────────────────────────
{
  if (reportErr) rec('S5', 'fail', reportErr);
  else if (!kv.REMOVAL_REPORT_PATH) {
    rec('S5', 'fail', `no removal report found. Searched: ${SEARCHED}. The harness assumes the prune engine writes one there — if it lands somewhere else, this check is the thing to update, not to silence. A base build must still emit one declaring an empty set, so that "we removed nothing" is a recorded measurement rather than a missing file.`);
  } else if (!entries) {
    rec('S5', 'fail', `${kv.REMOVAL_REPORT_PATH} has no "packages" (or "removed") array — cannot read a package set from it`);
  } else {
    const problems = [];
    const names = entries.map((e) => e.name);
    if (names.some((n) => !n)) problems.push('an entry has no package name');
    const noBytes = entries.filter((e) => !(Number.isFinite(e.bytes) && e.bytes >= 0));
    if (entries.length && noBytes.length) problems.push(`${noBytes.length} entr(ies) carry no numeric byte count — "we removed 214 packages" has to come from a measurement`);
    if (entries.length && entries.every((e) => e.bytes === 0)) problems.push('every entry reports 0 bytes, which is not a measurement');

    if (measuredClosure) {
      const rep = new Set(names), meas = new Set(measuredClosure);
      const onlyReport = [...rep].filter((n) => !meas.has(n));
      const onlyMeasured = [...meas].filter((n) => !rep.has(n));
      if (onlyReport.length) problems.push(`${onlyReport.length} package(s) claimed removed but never present in the pinned upstream base: ${onlyReport.slice(0, 10).join(' ')}`);
      if (onlyMeasured.length) problems.push(`${onlyMeasured.length} package(s) are actually gone from the upstream base but absent from the report: ${onlyMeasured.slice(0, 10).join(' ')}`);
      // byte counts, checked against rpm's own installed size in the upstream image
      const off = entries.filter((e) => {
        const u = upstream.get(e.name);
        return u && Number.isFinite(e.bytes) && e.bytes > 0 && Math.abs(e.bytes - u) / u > 0.05;
      });
      if (off.length) problems.push(`${off.length} entr(ies) report a byte count more than 5% from rpm's installed size in the upstream image (e.g. ${off[0].name}: report ${off[0].bytes} vs rpm ${upstream.get(off[0].name)})`);
    }

    const basis = measuredClosure
      ? `set compared against a MEASURED closure (upstream ${upstream.size} rpms − image ${rpms.size} rpms = ${measuredClosure.length} removed)`
      : `set NOT compared against a measured closure — the pinned upstream image was not available locally, so equality with the resolved closure could not be established independently`;

    if (problems.length) rec('S5', 'fail', `${kv.REMOVAL_REPORT_PATH}: ${problems.join('; ')}. ${basis}`);
    else if (!measuredClosure) rec('S5', 'fail', `${kv.REMOVAL_REPORT_PATH} is well-formed (${entries.length} entries) but ${basis}. S5's criterion is equality with the resolved closure, and an unverifiable equality is a FAIL, not an unknown. Pass --upstream-rpms (run-static.sh does this automatically when the pinned base is in local storage).`);
    else rec('S5', 'pass', `${entries.length} entries, all with measured byte counts; ${basis}; sets are equal`);
  }
}

// ── S9 — policy shape ───────────────────────────────────────────────────────────────────────────
{
  const mode = (args.policy && args.policy !== 'auto' ? args.policy : (kv.POLICY_MODE_STAMP || '')).trim();
  const shells = (kv.DESKTOP_SHELL_BINARIES || '').split(' ').filter(Boolean);
  const dms = (kv.DISPLAY_MANAGER_BINARIES || '').split(' ').filter(Boolean);
  if (!mode) {
    rec('S9', 'fail', `policy mode is undeclared. Pass --policy, or stamp it in the image at /usr/lib/auros/policy-mode (which is where build/20-policy.sh puts it). An image whose policy mode cannot be named cannot have its policy shape checked, and an unknown policy is not an open one.`);
  } else if (!['open', 'managed', 'locked', 'kiosk'].includes(mode)) {
    rec('S9', 'fail', `unknown policy mode "${mode}"`);
  } else if (mode === 'kiosk') {
    const found = [...shells, ...dms];
    if (kv.DISPLAY_MANAGER_UNIT === '1') found.push(`/etc/systemd/system/display-manager.service -> ${kv.DISPLAY_MANAGER_UNIT_TARGET || 'unresolved'}`);
    // The binary the unit's own ExecStart names, which is the answer that does not depend on
    // image-probe.sh's hardcoded list being right. On the pinned Aurora base that list matched
    // nothing at all while a display manager was plainly installed (run 35548005729), so a kiosk
    // image could have kept its display manager and this branch would have said it had none.
    if (kv.DISPLAY_MANAGER_EXEC_PRESENT === '1' && kv.DISPLAY_MANAGER_EXEC_PATH) found.push(`${kv.DISPLAY_MANAGER_EXEC_PATH} (named by display-manager.service ExecStart)`);
    if (found.length) rec('S9', 'fail', `policy=kiosk but the image still contains a way to reach a desktop: ${found.join(' ')}. Spec defines kiosk as "no desktop shell exists in the image at all" (D12: the shell and the display manager, not the whole stack).`);
    else rec('S9', 'pass', `policy=kiosk: no plasmashell, no gnome-shell, no display-manager.service and no display-manager binary. Searched shells and the display-manager list, AND resolved display-manager.service's own ExecStart (${kv.DISPLAY_MANAGER_EXEC_PATH || 'no unit, so nothing to resolve'}), so this does not rest on a hardcoded path list being complete.`);
  } else if (mode === 'open') {
    const units = ['managed', 'locked', 'kiosk'].filter((m) => kv[`POLICY_UNIT_${m}`] === '1');
    if (units.length) rec('S9', 'fail', `policy=open but restrictive policy units are present: ${units.join(' ')}`);
    else rec('S9', 'pass', 'policy=open: no restrictive policy units present');
  } else {
    const unit = kv[`POLICY_UNIT_${mode}`] === '1';
    const dir = (kv.AUROS_POLICY_DIRS || '').split(',').filter(Boolean).includes(mode);
    const assertBin = !!kv.POLICY_ASSERT_BIN;
    if (!unit && !dir) rec('S9', 'fail', `policy=${mode} but neither /usr/lib/systemd/system/auros-policy-${mode}.service nor /usr/share/auros/policy/${mode}/ exists`);
    else if (!assertBin) rec('S9', 'fail', `policy=${mode}: the payload is present but /usr/libexec/auros/assert-policy is not — B5 has nothing to run, so "configured" could never be distinguished from "in force"`);
    else rec('S9', 'pass', `policy=${mode}: ${dir ? `/usr/share/auros/policy/${mode}/ present` : `auros-policy-${mode}.service present`}, stamped at /usr/lib/auros/policy-mode, and assert-policy is installed for B5 to run`);
  }
}

// ── S10 — protected set intact, including the D8 signature policy ───────────────────────────────
{
  const problems = [];
  if (!kv.BOOTC_BIN) problems.push('bootc binary absent');
  if (!kv.SYSTEMD_BIN) problems.push('systemd absent');
  const need = [
    ['UNIT_BOOTC_FETCH_APPLY_UPDATES_TIMER', 'bootc-fetch-apply-updates.timer', true],
    ['UNIT_GREENBOOT_HEALTHCHECK_SERVICE', 'greenboot-healthcheck.service', true],
    ['UNIT_NETWORKMANAGER_SERVICE', 'NetworkManager.service', true],
  ];
  for (const [k, name, mustEnable] of need) {
    if (kv[`${k}_PRESENT`] !== '1') problems.push(`${name} not installed${name.startsWith('greenboot') ? ' (D9: greenboot is NOT preinstalled on Aurora — it is an explicit install step, and U3 auto-rollback depends on it)' : ''}`);
    else if (mustEnable && !['enabled', 'enabled-runtime', 'static', 'indirect', 'alias'].includes(kv[`${k}_ENABLED`])) problems.push(`${name} present but is-enabled=${kv[`${k}_ENABLED`]}`);
  }
  if (kv.UNIT_GREENBOOT_ROLLBACK_SERVICE_PRESENT !== '1') problems.push('greenboot-rollback.service not installed — without it a failed boot does not roll back, it just keeps failing');
  if (Number(kv.GREENBOOT_REQUIRED_COUNT || 0) < 1) problems.push('/etc/greenboot/check/required.d/ is empty — greenboot would declare every boot healthy, and U3 could never fire');
  // Two enabled update timers is not a pass. It is two updaters racing, and the loser's failure is
  // the kind of thing that shows up once a month on one machine in a fleet of 180.
  if (['enabled', 'enabled-runtime'].includes(kv.UNIT_UUPD_TIMER_ENABLED) && ['enabled', 'enabled-runtime'].includes(kv.UNIT_BOOTC_FETCH_APPLY_UPDATES_TIMER_ENABLED)) {
    problems.push('both uupd.timer and bootc-fetch-apply-updates.timer are enabled. D22 and build/30-update-agent.sh say exactly one drives updates; two do, and they will collide.');
  }

  // D8: the whole point. Enforcement that verifies nothing is worse than no enforcement.
  const scope = args.scope || 'ghcr.io/aarohkandy';
  if (kv.POLICY_JSON !== '1') problems.push('/etc/containers/policy.json absent');
  else {
    let pol = null;
    try { pol = JSON.parse(b64('POLICY_JSON_B64') ?? '{}'); } catch (e) { problems.push(`policy.json does not parse: ${e.message}`); }
    if (pol) {
      const docker = pol.transports?.docker ?? {};
      const key = Object.keys(docker).find((k) => k === scope || k.startsWith(scope + '/') || scope.startsWith(k + '/')) ?? null;
      if (!key) {
        problems.push(`policy.json has NO transports.docker entry scoped to "${scope}". Derived-from-Aurora images end in a docker "" insecureAcceptAnything catch-all, so enforcement succeeds while verifying nothing (D8). Scopes present: ${Object.keys(docker).map((k) => k === '' ? '""' : k).join(', ') || '(none)'}`);
      } else {
        const reqs = docker[key] ?? [];
        const signed = reqs.filter((r) => r.type === 'sigstoreSigned');
        if (!signed.length) problems.push(`policy.json scope "${key}" exists but its requirement type is ${reqs.map((r) => r.type).join('/') || '(empty)'} — not sigstoreSigned (D8)`);
        else {
          const kp = signed[0].keyPath ?? signed[0].keyPaths?.[0] ?? null;
          const keys = (kv.PKI_KEYS || '').split(',').filter(Boolean);
          if (kp && !keys.some((k) => kp.endsWith('/' + k))) problems.push(`policy.json points at keyPath ${kp} but /usr/lib/pki/containers/ contains [${keys.join(' ') || 'nothing'}] — the key the machine would verify against is not in the image`);
          if (!kp && !signed[0].keyData && !signed[0].fulcio) problems.push('sigstoreSigned entry names neither keyPath, keyData nor fulcio');
        }
      }
      if (Array.isArray(docker['']) && docker[''].some((r) => r.type === 'insecureAcceptAnything') && !key) {
        problems.push('the only matching rule for our namespace is the inherited insecureAcceptAnything catch-all');
      }
    }
  }
  if (kv.REGISTRIES_D_SIGSTORE_TRUE !== '1') problems.push(`no /etc/containers/registries.d/*.yaml sets use-sigstore-attachments: true — without it the machine never looks for the signature at all (D8). Files present: ${kv.REGISTRIES_D_FILES || '(none)'}`);

  if (problems.length) rec('S10', 'fail', problems.join('; '));
  else rec('S10', 'pass', `bootc, update timer, greenboot (healthcheck+rollback), NetworkManager and systemd all present and enabled; policy.json carries a sigstoreSigned rule for ${scope} with its key in the image; registries.d requests sigstore attachments`);
}

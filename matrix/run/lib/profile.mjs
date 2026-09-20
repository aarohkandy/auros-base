#!/usr/bin/env node
// profile.mjs <profile-id> — print shell KEY=VALUE for one entry of matrix/profiles.yaml.
// profiles.yaml is prose-shaped on purpose (it explains what each profile CANNOT prove). This is the
// one place that turns that prose into machine settings, so the mapping is reviewable in a diff.
import { loadProfiles } from './matrix.mjs';

const id = process.argv[2];
const { profiles } = loadProfiles();
const p = profiles.find((x) => x.id === id);
if (!p) { console.error(`profile.mjs: no profile "${id}" in profiles.yaml. Known: ${profiles.map((x) => x.id).join(' ')}`); process.exit(2); }

const fw = String(p.firmware ?? '').toLowerCase();
const out = {
  P_ID: p.id,
  P_RAM_MB: p.ram_mb ?? 8192,
  P_DISK_GB: p.disk_gb ?? 128,
  // firmware: uefi | uefi-sb | bios   (same vocabulary as hardware/compat.tsv's firmware column)
  P_FIRMWARE: fw.includes('seabios') || fw.includes('bios-only') || p.id === 'bios-legacy' ? 'bios'
    // "OVMF (UEFI, Secure Boot off)" must not match as secure boot. The word "off" is load-bearing.
    : /secure\s*boot/.test(fw) && !/\boff\b|disabled/.test(fw) ? 'uefi-sb' : 'uefi',
  // cpu: `host` needs KVM; a named model is what old-cpu is for.
  P_CPU: /nehalem/i.test(String(p.cpu ?? '')) ? 'Nehalem'
    : /sandy/i.test(String(p.cpu ?? '')) ? 'SandyBridge'
    : /host/i.test(String(p.cpu ?? '')) ? 'host' : '',
  P_TPM: /2\.0/.test(String(p.tpm ?? '')) ? '2.0' : /1\.2/.test(String(p.tpm ?? '')) ? '1.2' : '',
  // low-ram asks for a throttled disk "to approximate a 5400rpm spinning disk". 5400rpm ≈ 75 IOPS
  // random, ~80 MB/s sequential. These are the numbers the profile's prose implies; they are a model,
  // not a measurement, and the profile says as much.
  P_IO_THROTTLE: /throttl/i.test(String(p.io ?? '')) ? '1' : '0',
  P_IOPS: 75,
  P_BPS: 80 * 1024 * 1024,
  P_GPU: /virtio/i.test(String(p.gpu ?? '')) || !p.gpu ? 'virtio-gpu' : String(p.gpu),
  P_SUMMARY: String(p.summary ?? '').replace(/\n/g, ' ').trim(),
};
for (const [k, v] of Object.entries(out)) console.log(`${k}=${JSON.stringify(String(v))}`);

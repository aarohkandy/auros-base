#!/usr/bin/env node
// mkarchive.mjs — build a migration archive in the format auros-installer actually writes, for R1.
//
//   node mkarchive.mjs materialize <spec.json> <src-dir>   write a spec's files into a source tree
//   node mkarchive.mjs build <src-dir> <archive-dir>       copy a source tree into an archive; prints
//                                                           the entry count on stdout
//
// <src-dir>'s top-level directories are copy-engine Labels (Documents, Pictures, ...), exactly as
// auros-installer's copyengine.Source{Root, Label} sees them. The archive is what that engine leaves
// on a USB stick: every file at its Stored path under the root, and <root>/_auros/manifest.tsv in the
// `auros-manifest/1` format. auros-restore finds it by that manifest via /proc/self/mountinfo, with
// no volume label involved.
//
// THIS IS A SECOND IMPLEMENTATION of auros-installer/internal/manifest (manifest.go Bytes/wireEscape,
// path.go Sanitize), and it exists only because the CI job that runs R1 has no Go and no checkout of
// the installer. It is pinned, byte for byte, to that repository's real writer:
// r1-fixture.manifest.tsv beside this file is produced by copyengine.Run in the installer's
// internal/restore/r1fixture_test.go, and tests/r1-archive.test.sh requires this script to produce the
// same bytes from r1-fixture.spec.json. If you change anything here, that test is the arbiter.
//
// Deliberately NOT implemented, and refused rather than approximated: case-fold collisions (the
// copy engine de-collides with ~N suffixes, which depend on its walk order), symlinks and other
// non-regular files (the engine quarantines them), and names the engine's CleanRel would rewrite.
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const HEADER = 'auros-manifest/1';
const HEX = '0123456789ABCDEF';
const RESERVED = new Set(('CON PRN AUX NUL COM0 COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 ' +
  'LPT0 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9').split(' '));

const die = (m) => { process.stderr.write(`mkarchive: ${m}\n`); process.exit(1); };
const pct = (b) => '%' + HEX[b >> 4] + HEX[b & 15];

// Both escapes work on UTF-8 BYTES, as the Go code does, and leave bytes >= 0x80 alone.
function escBytes(s, needs) {
  const out = [];
  for (const b of Buffer.from(s, 'utf8')) out.push(needs(b) ? Buffer.from(pct(b)) : Buffer.from([b]));
  return Buffer.concat(out).toString('utf8');
}
// manifest.go wireEscape: protects the FILE FORMAT.
const wireEscape = (s) => escBytes(s, (b) => b < 0x20 || b === 0x7f || b === 0x25);
// path.go sanitizeSegment: protects the DESTINATION FILESYSTEM.
function sanitizeSegment(seg) {
  let out = escBytes(seg, (b) => b < 0x20 || b === 0x7f || '<>:"|?*\\%'.includes(String.fromCharCode(b)));
  const last = out[out.length - 1];
  if (last === '.' || last === ' ') out = out.slice(0, -1) + pct(last.charCodeAt(0));
  const dot = out.indexOf('.');
  const stem = dot >= 0 ? out.slice(0, dot) : out;
  if (out.length > 0 && RESERVED.has(stem.toUpperCase())) out = pct(Buffer.from(out, 'utf8')[0]) + out.slice(1);
  return out;
}
const sanitize = (rel) => rel.split('/').map(sanitizeSegment).join('/');

function walk(dir, rel, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const r = rel ? `${rel}/${name}` : name;
    const st = fs.lstatSync(full, { bigint: true });
    if (st.isDirectory()) walk(full, r, out);
    else if (st.isFile()) out.push({ full, rel: r, st });
    else die(`${full}: not a regular file or directory; the copy engine would quarantine it, and R1 must not depend on quarantine`);
  }
}

function build(src, dest) {
  if (!fs.statSync(src).isDirectory()) die(`${src} is not a directory`);
  const files = [];
  for (const label of fs.readdirSync(src)) {
    const p = path.join(src, label);
    if (!fs.lstatSync(p).isDirectory()) die(`${p}: every top-level entry must be a Label directory (Documents, Pictures, ...)`);
    walk(p, label, files);
  }
  if (files.length === 0) die(`${src} holds no files`);
  const taken = new Map();
  const entries = [];
  let total = 0n;
  for (const f of files) {
    if (/[\\\0]/.test(f.rel) || f.rel[1] === ':') die(`${f.rel}: CleanRel would rewrite or refuse this name`);
    const stored = sanitize(f.rel);
    const fold = stored.toLowerCase();
    if (taken.has(fold)) die(`${f.rel} and ${taken.get(fold)} collide case-insensitively; the engine would de-collide them and this script does not`);
    taken.set(fold, f.rel);
    // ponytail: whole-file read; fine for fixtures, stream it if R1 ever stages gigabytes.
    const data = fs.readFileSync(f.full);
    const to = path.join(dest, ...stored.split('/'));
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.writeFileSync(to, data);
    total += BigInt(data.length);
    entries.push({ path: f.rel, stored, size: data.length, mtime: f.st.mtimeNs,
      sha: createHash('sha256').update(data).digest('hex') });
  }
  // Raw BYTE order, as Go's string comparison. JavaScript's default sort is UTF-16 order, which
  // disagrees for anything above U+FFFF (the spec has a case that proves it).
  entries.sort((a, b) => Buffer.compare(Buffer.from(a.path, 'utf8'), Buffer.from(b.path, 'utf8')));
  let body = HEADER + '\n';
  for (const e of entries) body += [e.sha, e.size, e.mtime, wireEscape(e.path), wireEscape(e.stored)].join('\t') + '\n';
  const digest = createHash('sha256').update(body, 'utf8').digest('hex');
  body += `end\t${entries.length}\t${total}\t${digest}\n`;
  fs.mkdirSync(path.join(dest, '_auros'), { recursive: true });
  fs.writeFileSync(path.join(dest, '_auros', 'manifest.tsv'), body, 'utf8');
  process.stdout.write(`${entries.length}\n`);
}

function materialize(specFile, src) {
  const spec = JSON.parse(fs.readFileSync(specFile, 'utf8'));
  const secs = Number(BigInt(spec.mtime_unix_ns) / 1000000000n);
  if (BigInt(secs) * 1000000000n !== BigInt(spec.mtime_unix_ns)) die('mtime_unix_ns must be whole seconds; utimes cannot set nanoseconds exactly');
  for (const [rel, content] of Object.entries(spec.files)) {
    const p = path.join(src, ...rel.split('/'));
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, content, 'utf8');
    fs.utimesSync(p, secs, secs);
  }
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'build' && a && b) build(a, b);
else if (cmd === 'materialize' && a && b) materialize(a, b);
else die('usage: mkarchive.mjs build <src-dir> <archive-dir> | materialize <spec.json> <src-dir>');

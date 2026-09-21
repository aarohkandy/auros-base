#!/usr/bin/env bash
# R1 builds its migration archive in the format auros-installer really writes, and passes only on what
# auros-restore really reports. SYSTEM-REVIEW §2.23 / H18: until this, R1's fixture was a third
# convention (a labelled ext4 volume with a sha256sum-format manifest.sha256) that nothing reads.
#
#   r1golden   lib/mkarchive.mjs reproduces, byte for byte, the manifest the installer's REAL writer
#              (copyengine.Run) produced from the same spec — auros-installer
#              internal/restore/r1fixture_test.go generates r1-fixture.manifest.tsv and restores it.
#   r1format   the archive run-update.sh builds is a valid auros-manifest/1 archive: header, byte
#              order, trailer count/total/digest, every payload at its Stored path with its hash, and
#              nothing else outside _auros. The OLD fixture is the red case.
#   r1verdict  run-update.sh's r1_verdict, fed by the agent's restore_relay reading a desktop report
#              in auros-restore's real line formats.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
LIB="$REPO/matrix/run/lib"
RUN_UPDATE="$REPO/matrix/run/run-update.sh"
AGENT_SH="$REPO/matrix/run/guest/auros-matrix-agent.sh"
command -v node >/dev/null || t_abort "node is required (run-update.sh already requires it)"

# An independent READER of auros-manifest/1, as manifest.Read and verify.Run define it. It is a test
# oracle, not code under test; the golden comparison above it is what ties both to the Go.
VALIDATE="$(newroot)/validate.py"
cat > "$VALIDATE" <<'PY'
import hashlib, os, re, sys
root = sys.argv[1]
mp = os.path.join(root, '_auros', 'manifest.tsv')
if not os.path.isfile(mp): sys.exit(f'no _auros/manifest.tsv under {root}')
raw = open(mp, 'rb').read()
if b'\r' in raw: sys.exit('CR in manifest')
if not raw.endswith(b'\n'): sys.exit('manifest does not end in LF (truncated)')
lines = raw[:-1].split(b'\n')
if lines[0] != b'auros-manifest/1': sys.exit(f'bad header {lines[0]!r}')
if not lines[-1].startswith(b'end\t'): sys.exit('no trailer')
unesc = lambda s: re.sub(rb'%([0-9A-Fa-f]{2})', lambda m: bytes([int(m.group(1), 16)]), s)
paths, stored, total = [], set(), 0
for ln in lines[1:-1]:
    f = ln.split(b'\t')
    if len(f) != 5: sys.exit(f'entry with {len(f)} fields')
    sha, size, _mt, p, st = f[0].decode(), int(f[1]), int(f[2]), unesc(f[3]), unesc(f[4])
    if paths and p <= paths[-1]: sys.exit(f'entries out of byte order at {p!r}')
    paths.append(p); total += size
    full = os.path.join(root.encode(), *st.split(b'/'))
    data = open(full, 'rb').read() if os.path.isfile(full) else sys.exit(f'payload missing at Stored path {st!r}')
    if len(data) != size or hashlib.sha256(data).hexdigest() != sha: sys.exit(f'payload {st!r} does not match its entry')
    stored.add(st)
cnt, tot, dig = lines[-1].split(b'\t')[1:]
if int(cnt) != len(paths) or int(tot) != total: sys.exit('trailer count/total disagree with the entries')
if hashlib.sha256(b'\n'.join(lines[:-1]) + b'\n').hexdigest() != dig.decode(): sys.exit('trailer digest disagrees with the body')
on_disk = set()
for d, _, fs in os.walk(root.encode()):
    for n in fs:
        rel = os.path.relpath(os.path.join(d, n), root.encode()).replace(os.sep.encode(), b'/')
        if not rel.startswith(b'_auros/'): on_disk.add(rel)
if on_disk != stored: sys.exit(f'volume holds {len(on_disk)} files, manifest lists {len(stored)}')
print(f'{len(paths)} entries, {total} bytes, valid')
PY

build_spec() { # <generator.mjs> <out-dir> — materialize the golden spec and archive it
  node "$1" materialize "$LIB/r1-fixture.spec.json" "$2/src" && node "$1" build "$2/src" "$2/arc" >/dev/null
}

group "the generator reproduces the installer's real writer, byte for byte"
G="$(newroot)"; build_spec "$LIB/mkarchive.mjs" "$G"
run_check r1golden green "mkarchive.mjs on r1-fixture.spec.json == r1-fixture.manifest.tsv" -- cmp "$G/arc/_auros/manifest.tsv" "$LIB/r1-fixture.manifest.tsv"
M="$(newroot)"; sed 's/entries.sort((a, b) => Buffer.compare(.*$/entries.sort((a, b) => (a.path < b.path ? -1 : 1));/' "$LIB/mkarchive.mjs" > "$M/utf16sort.mjs"
cmp -s "$LIB/mkarchive.mjs" "$M/utf16sort.mjs" && t_abort "UTF-16 sort mutation did not apply"
build_spec "$M/utf16sort.mjs" "$M"
run_check r1golden red "…the same generator sorting by JavaScript string order (UTF-16), not bytes" -- cmp "$G/arc/_auros/manifest.tsv" "$M/arc/_auros/manifest.tsv"
run_check r1golden red "…and against the golden" -- cmp "$M/arc/_auros/manifest.tsv" "$LIB/r1-fixture.manifest.tsv"
N="$(newroot)"; sed 's/b === 0x7f || b === 0x25);/b === 0x7f);/' "$LIB/mkarchive.mjs" > "$N/nopct.mjs"
cmp -s "$LIB/mkarchive.mjs" "$N/nopct.mjs" && t_abort "wireEscape mutation did not apply"
build_spec "$N/nopct.mjs" "$N"
run_check r1golden red "…a generator whose wire escape forgets '%'" -- cmp "$N/arc/_auros/manifest.tsv" "$LIB/r1-fixture.manifest.tsv"
cmp -s "$LIB/r1-fixture.spec.json" "$LIB/r1-fixture.manifest.tsv" && t_abort "fixture files are identical — a bad copy"

group "the archive run-update.sh builds is a real auros-manifest/1 archive"
# The code under test comes out of run-update.sh itself.
FN="$(extract_fn "$RUN_UPDATE" r1_build_archive)"
S="$(newroot)"; mkdir -p "$S/src/Documents/synthetic"
for i in $(seq 1 200); do printf 'auros synthetic file %s\n' "$i" > "$S/src/Documents/synthetic/file-$i.txt"; done
node "$LIB/mkarchive.mjs" materialize "$LIB/r1-fixture.spec.json" "$S/src"
COUNT="$(HARNESS_DIR="$REPO/matrix/run" bash -c "$FN"$'\n''r1_build_archive "$1" "$2"' _ "$S/src" "$S/arc")"
assert_eq "r1_build_archive reports the entry count (200 synthetic + 12 spec)" "212" "$COUNT"
run_check r1format green "run-update.sh's default R1 archive" -- python3 "$VALIDATE" "$S/arc"
O="$(newroot)"; mkdir -p "$O/files/Documents"
# THE OLD FIXTURE, as run-update.sh built it before this change (a labelled ext4 volume's contents):
for i in $(seq 1 200); do printf 'auros synthetic file %s\n' "$i" > "$O/files/Documents/file-$i.txt"; done
( cd "$O" && find files -type f -exec shasum -a 256 {} \; | sort -k2 > manifest.sha256 )
run_check r1format red "the OLD fixture: files/ plus a sha256sum-format manifest.sha256" -- python3 "$VALIDATE" "$O"
assert_has "…refused because there is no _auros/manifest.tsv" "no _auros/manifest.tsv" "$T_LAST_OUT"
cp -R "$S/arc" "$O/tampered"; printf 'X' >> "$O/tampered/Documents/synthetic/file-7.txt"
run_check r1format red "a real archive with one payload byte changed" -- python3 "$VALIDATE" "$O/tampered"
cp -R "$S/arc" "$O/extra"; printf 'stray\n' > "$O/extra/Documents/stray.txt"
run_check r1format red "a real archive with a file the manifest does not list" -- python3 "$VALIDATE" "$O/extra"

group "R1's verdict: the agent's relay of auros-restore's desktop report"
VERDICT="$(extract_fn "$RUN_UPDATE" r1_verdict)"
RELAY="$(extract_fn "$AGENT_SH" restore_relay)"
R="$(newroot)"; BIN="$(stubdir)"
printf '#!/bin/sh\necho "auros:x:1000:1000::%s/home:/bin/bash"\n' "$R" | stub "$BIN" getent
printf '#!/bin/sh\nexit 1\n' | stub "$BIN" runuser       # no xdg-user-dir: the relay falls back to ~/Desktop
printf '#!/bin/sh\necho enabled\n' | stub "$BIN" systemctl
# report <dir> <name> <listed> <readback> <matched> <disagreed> <accounted> <of> — the line formats of
# auros-installer internal/restore/report.go RenderReport, pinned there by r1fixture_test.go.
report() {
  mkdir -p "$1"
  printf 'YOUR FILES ARE ON THIS COMPUTER\n\n%s files came across.\n\n--------\nTHE NUMBERS\n\n  in the backup'"'"'s list      %s files\n  written                  %s\n\n  check 1, on the backup drive, before anything was written:\n    %s checked, 0 disagreed\n  check 2, on this computer, after everything was written:\n    %s read back, %s matched, %s disagreed\n    %s of %s entries accounted for\n' \
    "$3" "$3" "$3" "$3" "$4" "$5" "$6" "$7" "$8" > "$1/$2"
}
judge() { # relay the fake home, then run r1_verdict over it against a 212-entry manifest
  PATH="$BIN:$PATH" TEST_USER=auros bash -c "say() { printf '%s\n' \"\$*\"; }"$'\n'"$RELAY"$'\n''restore_relay' > "$R/agent.log"
  local out; out="$(TEST_USER=auros bash -c "$VERDICT"$'\n''r1_verdict "$1" 212' _ "$R/agent.log")"
  printf '%s\n' "$out"; [ "${out%% *}" = pass ]
}
OK_NAME='Your files are here.txt'; BAD_NAME='PLEASE READ — a problem with your files.txt'
reset_home() { rm -rf "$R/home"; mkdir -p "$R/home"; }

reset_home; report "$R/home/Desktop" "$OK_NAME" 212 212 212 0 212 212
run_check r1verdict green "a clean report on the desktop, every count 212" -- judge
assert_has "…and the relay carried the numbers" '"readback":"212"' "$(cat "$R/agent.log")"
reset_home
run_check r1verdict red "no report at all (the restore never ran)" -- judge
assert_has "…and says what the guest had" "auros-restore binary absent" "$T_LAST_OUT"
reset_home; report "$R/home/Desktop" "$BAD_NAME" 212 212 211 1 212 212
run_check r1verdict red "the problem-named report" -- judge
reset_home; report "$R/home/Desktop" "$OK_NAME" 212 211 211 0 211 212
run_check r1verdict red "a clean-named report whose counts are one short" -- judge
reset_home; report "$R/home/Desktop" "$OK_NAME" 200 200 200 0 200 200
run_check r1verdict red "a clean report for a different archive (200, not 212)" -- judge
reset_home; report "$R/home" "$OK_NAME" 212 212 212 0 212 212
run_check r1verdict red "a clean report in the home directory, not on the desktop" -- judge
# The OLD criterion passed on console text. The new one ignores it entirely.
printf 'auros-restore: restored 212 files\n' > "$R/old-serial.log"
run_check r1verdict red "the OLD pass condition: 'auros-restore … restored 212 files' on a console, no relay" -- \
  bash -c "$VERDICT"$'\n''o=$(r1_verdict "$1" 212); echo "$o"; [ "${o%% *}" = pass ]' _ "$R/old-serial.log"

t_finish r1-archive.test.sh

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/matrix-run-collect.test.sh — the collector inside matrix/run.sh, which had never run.
#
# WHAT IT MISSED, and why this file exists:
#
#   matrix/run.sh is the adapter build.yml drives. After a phase finishes it walks the run directory,
#   gathers every per-check record, and writes the single JSON fragment CI merges. It selected files
#   with /\.json$/ and then JSON.parse-d each one whole.
#
#   Every script under matrix/run/ writes JSON LINES to `checks/<name>.jsonl` — that is what
#   common.sh's record() appends to, one object per line. "static.jsonl" does not match /\.json$/,
#   and a multi-record JSON Lines file is not a JSON document. Both halves were wrong, and either
#   alone was fatal.
#
#   So EVERY phase found zero checks, wrote no fragment, and exited 1 — S1, B1, U1, all of them, on
#   any image, however perfect. emit-results.mjs (the single-host path) reads .jsonl correctly, so
#   the two halves of the harness were written against the same contract and disagreed about it, and
#   nothing executed the adapter until the day the hardened image needed it.
#
# The collector is EXTRACTED from matrix/run.sh at run time, never copied. If the heredoc moves or is
# renamed, extract_raw aborts the suite rather than letting this file go green about code nobody runs.
#
# RUN:  bash auros-base/tests/run-all.sh
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"
REPO="$(cd "$HERE/.." && pwd)"
RUNSH="$REPO/matrix/run.sh"

command -v node >/dev/null 2>&1 || t_abort "node is not on PATH; the collector is a node program and this suite would otherwise 'pass' having run nothing"

# ── the code under test, out of the shipping file ────────────────────────────────────────────────
# The heredoc body only: drop the `node - ... <<'NODE'` line and the closing `NODE`.
COLLECTOR="$(extract_raw "$RUNSH" '^node - "\$WORKDIR"' '^NODE$' | sed '1d;$d')"
case "$COLLECTOR" in
  *"walk(checksDir)"*) ;;
  *) t_abort "the block extracted from matrix/run.sh does not contain walk(checksDir) — the collector was rewritten and this test no longer knows what it is testing" ;;
esac
COLLECT_JS="$(newroot)/collect.cjs"   # .cjs, not .mjs: the collector is CommonJS (it uses require)
printf '%s\n' "$COLLECTOR" > "$COLLECT_JS"
node --check "$COLLECT_JS" 2>/dev/null || t_abort "the extracted collector does not parse as JavaScript — the sed range is wrong, and every 'red' case below would pass for the wrong reason"

CHECKS_YAML="$REPO/matrix/checks.yaml"
[ -f "$CHECKS_YAML" ] || t_abort "no matrix/checks.yaml — the completeness pass has no contract to read"

collect() { # collect <rundir> <profile> <digest> <out> [phase] [checks.yaml]
  node "$COLLECT_JS" "$1" "$2" "$3" "$4" "${5-}" "${6-}"
}
collect_phase() { # collect_phase <rundir> <profile> <out> <phase>
  node "$COLLECT_JS" "$1" "$2" '' "$3" "$4" "$CHECKS_YAML"
}
status_of() { node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));const c=j.checks.find(c=>c.id===process.argv[2]);process.stdout.write(c?c.status:"MISSING")' "$1" "$2" 2>/dev/null || printf '?'; }

mkrun() { # mkrun -> echoes a fresh run directory with checks/ and logs/
  local d; d="$(newroot)/run"
  mkdir -p "$d/checks" "$d/logs" "$d/work"
  printf '%s' "$d"
}

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the collector reads what the harness actually writes"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# This is the exact shape common.sh's record() appends: JSON Lines, in checks/<phase>.jsonl.
R="$(mkrun)"
cat > "$R/checks/static.jsonl" <<'EOF'
{"id":"S1","status":"pass","detail":"FROM pinned to base.lock","duration_ms":12}
{"id":"S2","status":"fail","detail":"bootc container lint exited 1","duration_ms":900}
EOF
OUT="$R/frag.json"
run_check collect.jsonl green "two JSON Lines records in checks/static.jsonl are collected" -- collect "$R" static sha256:abc "$OUT"
assert_file "a fragment was written" "$OUT"
assert_eq "both records survived" "2" "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).checks.length))' "$OUT" 2>/dev/null || echo 0)"
assert_eq "S1 kept its pass" "pass" "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.checks.find(c=>c.id==="S1").status)' "$OUT" 2>/dev/null || echo '?')"
assert_eq "S2 kept its fail" "fail" "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.checks.find(c=>c.id==="S2").status)' "$OUT" 2>/dev/null || echo '?')"
assert_eq "the digest under test is carried into the fragment" "sha256:abc" \
  "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).digest||""))' "$OUT" 2>/dev/null || echo '?')"

# The boot phase names its file per profile. A collector that only knew "static.jsonl" would be just
# as broken as one that only knew ".json", and it would be broken only for the boot phase.
R2="$(mkrun)"
printf '%s\n' '{"id":"B1","status":"pass","detail":"greeter within 41s"}' > "$R2/checks/boot-uefi-modern.jsonl"
run_check collect.jsonl green "boot-<profile>.jsonl is collected too" -- collect "$R2" uefi-modern '' "$R2/frag.json"

# ── RED: nothing to collect ──────────────────────────────────────────────────────────────────────
# The phase ran, wrote logs, and recorded no verdict. That must not produce an empty-but-valid
# fragment, because build.yml would read it and the gate would read that.
R3="$(mkrun)"
echo "bootc-image-builder output" > "$R3/logs/bib.log"
run_check collect.jsonl red "a run directory with logs but NO check records is refused" -- collect "$R3" static '' "$R3/frag.json"
assert_nofile "and no fragment was written" "$R3/frag.json"
assert_has "the refusal names the files it did consider" "result files considered" "$T_LAST_OUT"
assert_has "and lists what IS in the run directory, not only what was missing" "bib.log" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "an unreadable result file is named, never skipped"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The collector used to swallow a parse error with `catch { continue }`, which made "the results file
# was corrupt" and "every check passed" indistinguishable from outside. A truncated agent harvest —
# a VM killed mid-write — produces exactly that file.
R4="$(mkrun)"
printf '%s\n' '{"id":"B1","status":"pass","detail":"ok"}' > "$R4/checks/boot-uefi-modern.jsonl"
printf 'not json at all\n{"id":"B2"\n' > "$R4/checks/boot-low-ram.jsonl"
run_check collect.corrupt red "a truncated fragment fails the phase instead of vanishing" -- collect "$R4" uefi-modern '' "$R4/frag.json"
assert_has "the refusal names the corrupt file" "boot-low-ram.jsonl" "$T_LAST_OUT"
assert_nofile "and writes no fragment built from the half that parsed" "$R4/frag.json"

R5="$(mkrun)"
printf '%s\n' '{"id":"B1","status":"pass","detail":"ok"}' > "$R5/checks/boot-uefi-modern.jsonl"
run_check collect.corrupt green "the same path accepts a well-formed file" -- collect "$R5" uefi-modern '' "$R5/frag.json"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "shape normalisation, and the pessimistic merge"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# A whole-document .json fragment (the shape build.yml's own S8 step writes) must still be read.
R6="$(mkrun)"
echo '{"profile":"static","checks":[{"id":"S8","status":"pass","detail":"sig tag discoverable"}]}' > "$R6/checks/s8.json"
run_check collect.jsonl green "a whole-document .json fragment is read as well as .jsonl" -- collect "$R6" static '' "$R6/frag.json"
assert_eq "S8 came through" "pass" "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((j.checks.find(c=>c.id==="S8")||{}).status||"?")' "$R6/frag.json" 2>/dev/null || echo '?')"

# Two sources disagreeing about one id must resolve to the WORSE answer. A check that passed once and
# failed once did not pass — and on a two-boot profile that is not hypothetical: the agent records B2
# on both boots.
R7="$(mkrun)"
cat > "$R7/checks/boot-uefi-modern.jsonl" <<'EOF'
{"id":"B2","status":"pass","detail":"boot 1: is-system-running = running"}
{"id":"B2","status":"fail","detail":"boot 2: degraded, 1 failed unit"}
EOF
collect "$R7" uefi-modern '' "$R7/frag.json" >/dev/null 2>&1 || true
assert_eq "a pass and a fail for one id collapses to fail" "fail" \
  "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((j.checks.find(c=>c.id==="B2")||{}).status||"?")' "$R7/frag.json" 2>/dev/null || echo '?')"
assert_eq "and only one record survives" "1" \
  "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).checks.length))' "$R7/frag.json" 2>/dev/null || echo '?')"

# Anything that is not literally "pass" or "skip" is a fail. An absent answer is a failure, not an
# unknown — that rule lives in exactly one place and this is it.
R8="$(mkrun)"
cat > "$R8/checks/static.jsonl" <<'EOF'
{"id":"S1","status":"unknown","detail":"could not determine"}
{"id":"S2","status":"skip","detail":"","skip_reason":"no registry ref"}
EOF
collect "$R8" static '' "$R8/frag.json" >/dev/null 2>&1 || true
assert_eq "an unrecognised status becomes fail" "fail" \
  "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((j.checks.find(c=>c.id==="S1")||{}).status||"?")' "$R8/frag.json" 2>/dev/null || echo '?')"
assert_eq "skip stays skip, so the gate can refuse it separately" "skip" \
  "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((j.checks.find(c=>c.id==="S2")||{}).status||"?")' "$R8/frag.json" 2>/dev/null || echo '?')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "matrix/run.sh's own verdict line — a phase with a failing check must exit non-zero"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The one-liner at the bottom of run.sh is what turns a fragment into an exit status, and D37 is the
# reason it is tested: `verify` reported PASS on failing suites because a pipe swallowed the status.
VERDICT="$(extract_lines "$RUNSH" '^FAILED=\$\(node -e')"
case "$VERDICT" in
  *'c.status!=="pass"'*) ;;
  *) t_abort "the verdict line in matrix/run.sh no longer counts non-pass checks — this test is now vacuous" ;;
esac
VERDICT_SRC="$VERDICT
"'[ "$FAILED" = "0" ] || exit 1'

F_GREEN="$(newroot)/all-pass.json"
echo '{"profile":"static","checks":[{"id":"S1","status":"pass"},{"id":"S2","status":"pass"}]}' > "$F_GREEN"
run_snippet verdict green "a fragment in which every check passed exits 0" "OUT='$F_GREEN'; $VERDICT_SRC"

F_RED="$(newroot)/one-fail.json"
echo '{"profile":"static","checks":[{"id":"S1","status":"pass"},{"id":"S2","status":"fail"}]}' > "$F_RED"
run_snippet verdict red "one failing check is enough to fail the phase" "OUT='$F_RED'; $VERDICT_SRC"

F_SKIP="$(newroot)/one-skip.json"
echo '{"profile":"static","checks":[{"id":"S1","status":"pass"},{"id":"S2","status":"skip"}]}' > "$F_SKIP"
run_snippet verdict red "a SKIP is not a pass either — a check that did not run did not pass" "OUT='$F_SKIP'; $VERDICT_SRC"

# THE SHAPE CI ACTUALLY PASSES, and the one this line had never been given. build.yml calls
# `--out fragments/static.json` — a bare relative path. `require()` reads that as a MODULE NAME, so
# the verdict line died with "Cannot find module 'fragments/static.json'" on a fragment that had
# just been written correctly, and `set -e` turned that into a failed phase no matter what the
# checks said. Every case above used an absolute path and sailed straight past it.
# Measured: run 35548759944.
REL_DIR="$(newroot)/relcase"; mkdir -p "$REL_DIR/fragments"
echo '{"profile":"static","checks":[{"id":"S1","status":"pass"},{"id":"S2","status":"pass"}]}' > "$REL_DIR/fragments/static.json"
run_snippet verdict green "a RELATIVE --out path, as build.yml passes, is read rather than imported" \
  "cd '$REL_DIR'; OUT=fragments/static.json; $VERDICT_SRC"
echo '{"profile":"static","checks":[{"id":"S1","status":"fail"}]}' > "$REL_DIR/fragments/static.json"
run_snippet verdict red "and a relative path with a failing check still goes red for the RIGHT reason" \
  "cd '$REL_DIR'; OUT=fragments/static.json; $VERDICT_SRC"

# ── work/ is inputs, not verdicts ────────────────────────────────────────────────────────────────
# The run directory also holds bib's config, the flatpak probe result and the image manifest. The
# strictness above fired on them the first time it ran in CI (run 35548492085 died with
# "manifest.json: parsed as JSON but carries no .id"), which turned a diagnostic improvement into a
# harness error of exactly the kind this probe exists to find.
R_W="$(mkrun)"
printf '%s\n' '{"id":"S1","status":"pass","detail":"x"}' > "$R_W/checks/static.jsonl"
echo '{"status":"pass","detail":"no flatpak refs declared"}' > "$R_W/work/flatpak-result.json"
echo '{"schemaVersion":2,"layers":[{"size":1}]}'             > "$R_W/work/manifest.json"
run_check collect.jsonl green "JSON under work/ is ignored, not mistaken for a corrupt record" -- collect "$R_W" static '' "$R_W/frag.json"
assert_eq "only the real record came through" "1" \
  "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).checks.length))' "$R_W/frag.json" 2>/dev/null || echo '?')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "completeness — a check that never reported is recorded as a fail, not omitted"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# A phase that dies halfway leaves a fragment full of REAL records. Nothing about that fragment says
# it is short, and build.yml's only shape assertion is `checks|length > 0`. So the collector reads
# checks.yaml and fills the gap with an explicit fail, which is both the honest verdict and the
# thing that keeps the gate closed.
# The static ids come from checks.yaml, not from this file: S11 was added and these counts broke.
STATIC_IDS="$(python3 -c 'import yaml,sys; print(" ".join(c["id"] for c in yaml.safe_load(open(sys.argv[1]))["static"]))' "$REPO/matrix/checks.yaml")"
N_STATIC="$(printf '%s\n' $STATIC_IDS | wc -l | tr -d ' ')"
[ "$N_STATIC" -ge 10 ] || t_abort "read only [$N_STATIC] static ids from checks.yaml — the parse is wrong, not the collector"
R9="$(mkrun)"
cat > "$R9/checks/static.jsonl" <<'EOF'
{"id":"S1","status":"pass","detail":"FROM pinned"}
{"id":"S2","status":"pass","detail":"lint ok"}
EOF
# The collector WRITES the fragment (exit 0); refusing is the verdict line's job, and the two are
# asserted separately below so that "wrote the evidence" and "refused the run" cannot be confused.
run_check completeness green "a static phase that recorded only S1 and S2 still produces a fragment" -- collect_phase "$R9" static "$R9/frag.json" static
assert_file "and it still wrote the fragment, so the evidence survives" "$R9/frag.json"
assert_eq "S1's real verdict is preserved" "pass" "$(status_of "$R9/frag.json" S1)"
assert_eq "S10, never reached, is recorded as a fail" "fail" "$(status_of "$R9/frag.json" S10)"
assert_eq "every static id in checks.yaml is present" "$N_STATIC"   "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).checks.length))' "$R9/frag.json" 2>/dev/null || echo '?')"
assert_has "and the synthesised detail says the harness never reached it" "recorded NO verdict"   "$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.checks.find(c=>c.id==="S10").detail)' "$R9/frag.json" 2>/dev/null || echo '')"

# GREEN: a complete phase is left alone.
R10="$(mkrun)"
for id in $STATIC_IDS; do
  printf '{"id":"%s","status":"pass","detail":"synthetic"}\n' "$id" >> "$R10/checks/static.jsonl"
done
run_check completeness green "a static phase with every id passes through untouched" -- collect_phase "$R10" static "$R10/frag.json" static
assert_eq "nothing was added" "$N_STATIC"   "$(node -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).checks.length))' "$R10/frag.json" 2>/dev/null || echo '?')"

# The update phase's contract spans two sections of checks.yaml: `update` and `restore` (R1).
R11="$(mkrun)"
printf '%s\n' '{"id":"U1","status":"pass","detail":"x"}' > "$R11/checks/update.jsonl"
collect_phase "$R11" uefi-modern "$R11/frag.json" update >/dev/null 2>&1 || true
assert_eq "R1 is part of the update phase's contract" "fail" "$(status_of "$R11/frag.json" R1)"
assert_eq "and so are U2-U5" "fail" "$(status_of "$R11/frag.json" U5)"

# Boot ids must NOT be demanded of a static phase, or every static run would fail on B1-B12.
assert_eq "a boot id is not demanded of the static phase" "MISSING" "$(status_of "$R10/frag.json" B1)"

# An unreadable contract must not be read as an empty one. This is the completeness pass's own
# version of the bug it exists to catch.
R12="$(mkrun)"
printf '%s\n' '{"id":"S1","status":"pass","detail":"x"}' > "$R12/checks/static.jsonl"
EMPTY_YAML="$(newroot)/nothing.yaml"; printf '# a matrix definition with no ids in it\n' > "$EMPTY_YAML"
run_check completeness red "a checks.yaml that yields zero ids is refused, not treated as no requirements" \
  -- collect "$R12" static '' "$R12/frag.json" static "$EMPTY_YAML"
assert_has "and says so" "parsed ZERO check ids" "$T_LAST_OUT"

# END TO END, the two halves joined: a phase that died after S2 produces a fragment naming every id,
# and matrix/run.sh's verdict line then refuses the run. Neither half alone is the property we want —
# a fragment with no refusal publishes a broken image, and a refusal with no fragment tells nobody why.
run_snippet completeness red "the fragment from a half-finished phase is then refused by the verdict line" \
  "OUT='$R9/frag.json'; $VERDICT_SRC"

t_finish "matrix/run.sh collector"

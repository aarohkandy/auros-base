#!/usr/bin/env bash
# run-static.sh's S1 — FROM pinned to base.lock, by upstream's name or the D21 mirror's.
# Batch 5 (run 35657138253) moved FROM to the mirror; resolve-upstream.sh accepted it, but this S1
# read a base.lock key nobody writes and failed the only static check left. The block under test is
# extracted from the shipping script, never copied.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

BLOCK="$(extract_between "$REPO/matrix/run/run-static.sh" '^# ── S1 — Base is pinned by digest' '^# ── resolve the digest under test')"
DIG="sha256:$(printf 'a%.0s' $(seq 1 64))"
UP=ghcr.io/ublue-os/aurora
MIR=ghcr.io/aarohkandy/auros-upstream-mirror

s1() {  # s1 <FROM image> [--mirror value] — prints the S1 verdict line
  local d; d="$(newroot)"
  printf 'UPSTREAM_IMAGE=%s\nUPSTREAM_DIGEST=%s\n' "$UP" "$DIG" > "$d/base.lock"
  printf 'FROM %s@%s\n' "$1" "$DIG" > "$d/Containerfile"
  MIRROR="${2:-}" LOCK="$d/base.lock" CONTAINERFILE="$d/Containerfile" bash -c '
    read_lock() { sed -n "s/^$1=//p" "$LOCK" | head -1; }
    check_begin() { :; }
    record() { echo "$1 $2: $3"; [ "$2" = pass ]; }
    '"$BLOCK" 2>&1
}

run_check s1 green "FROM names upstream"                                -- s1 "$UP"
run_check s1 green "FROM names the mirror the workflow passes (--mirror)" -- s1 "$MIR" "$MIR"
run_check s1 red   "FROM names the mirror but no --mirror was given"     -- s1 "$MIR"
run_check s1 red   "FROM names some other registry, even with --mirror"  -- s1 ghcr.io/attacker/auros-upstream-mirror "$MIR"
assert_has "…and says which mirror it expected" "--mirror: $MIR" "$T_LAST_OUT"

t_finish static-s1.test.sh

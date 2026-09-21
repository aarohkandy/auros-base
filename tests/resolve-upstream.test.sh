#!/usr/bin/env bash
# tools/resolve-upstream.sh drift / update — the only path that moves base.lock (BLOCKED.md B16).
#
# Both subcommands were dispatched and never defined, so the nightly died with "cmd_update: command
# not found" every night and the pin never moved. `bash -n` passed; nothing ran the script. This runs
# it, against a fake registry (a stub `skopeo` on PATH), on copies of the REAL base.lock and
# Containerfile, so the rewrite is tested against the files it will actually rewrite.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

SCRIPT="$REPO/tools/resolve-upstream.sh"
OLD="$(sed -n 's/^UPSTREAM_DIGEST=//p' "$REPO/base.lock")"
NEW="sha256:$(printf 'b%.0s' $(seq 1 64))"
[ -n "$OLD" ] || t_abort "could not read UPSTREAM_DIGEST from the real base.lock"

# ctx <digest-the-registry-reports> [fail] — sets D to a scratch tree with a stub skopeo answering
# for that digest. Sets a global rather than printing, so newroot's cleanup list survives.
ctx() {
  local d; newroot >/dev/null; d="${T_TMPDIRS[${#T_TMPDIRS[@]}-1]}"
  mkdir -p "$d/tools" "$d/bin"
  cp "$SCRIPT" "$d/tools/"; cp "$REPO/base.lock" "$REPO/Containerfile" "$d/"
  cat > "$d/bin/skopeo" <<SH
#!/usr/bin/env bash
[ "${2:-}" = fail ] && { echo "registry unreachable" >&2; exit 1; }
case "\$*" in
  *--raw*) echo '{"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"size":100},{"size":23}]}' ;;
  *)       echo '{"Digest":"$1","Created":"2026-10-01T01:02:03.123456789Z","Os":"linux","Architecture":"amd64"}' ;;
esac
SH
  chmod +x "$d/bin/skopeo"
  D="$d"
}
rup() { local d="$1"; shift; PATH="$d/bin:$PATH" GITHUB_OUTPUT="$d/out" bash "$d/tools/resolve-upstream.sh" "$@"; }

group "drift"
ctx "$OLD"
run_check drift green "unmoved tag → exit 0" -- rup "$D" drift
assert_has "unmoved → moved=false in GITHUB_OUTPUT" "moved=false" "$(cat "$D/out")"
ctx "$NEW"
run_check drift red "moved tag → non-zero" -- rup "$D" drift
rup "$D" drift >/dev/null 2>&1; rc=$?
assert_eq "…and specifically exit 10, which build.yml reads as 'moved'" 10 "$rc"
assert_has "moved → moved=true in GITHUB_OUTPUT" "moved=true" "$(cat "$D/out")"
ctx "$NEW" fail
rup "$D" drift >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$rc" != 10 ] && ok "unreachable registry → exit $rc, neither 'same' nor 'moved'" \
  || bad "unreachable registry exited $rc — build.yml would read that as a verdict"

group "update"
ctx "$OLD"
cp "$D/base.lock" "$D/lock.before"; cp "$D/Containerfile" "$D/cf.before"
run_check update green "unmoved tag → exit 0" -- rup "$D" update
assert_eq "unmoved → base.lock byte-identical" "" "$(diff "$D/lock.before" "$D/base.lock")"
assert_eq "unmoved → Containerfile byte-identical" "" "$(diff "$D/cf.before" "$D/Containerfile")"
assert_has "unmoved → moved=false" "moved=false" "$(cat "$D/out")"

ctx "$NEW"
run_check update green "moved tag → exit 0 (nightly's step runs under set -e)" -- rup "$D" update
assert_has "moved → moved=true" "moved=true" "$(cat "$D/out")"
assert_has "moved → upstream_digest emitted for the commit message" "upstream_digest=$NEW" "$(cat "$D/out")"
assert_has "base.lock pins the new digest" "UPSTREAM_DIGEST=$NEW" "$(cat "$D/base.lock")"
assert_has "base.lock records the new creation time" "UPSTREAM_CREATED=2026-10-01T01:02:03.123456789Z" "$(cat "$D/base.lock")"
assert_has "base.lock records the measured pull size, not a remembered one" "UPSTREAM_PULL_SIZE_BYTES=123" "$(cat "$D/base.lock")"
assert_not "no trace of the old digest in base.lock" "$OLD" "$(cat "$D/base.lock")"
assert_not "no trace of the old digest in the Containerfile" "$OLD" "$(cat "$D/Containerfile")"
assert_eq "FROM and ARG UPSTREAM_DIGEST both rewritten" 2 "$(grep -c "$NEW" "$D/Containerfile")"
assert_has "SOURCE_DATE_EPOCH default follows the new creation time" "ARG SOURCE_DATE_EPOCH=1790816523" "$(cat "$D/Containerfile")"
assert_has "…and so does its ISO twin, the image.created label default" "ARG IMAGE_CREATED=2026-10-01T01:02:03Z" "$(cat "$D/Containerfile")"
run_check s1 green "S1 (assert, offline) accepts the rewritten tree" -- rup "$D" assert
cp "$D/base.lock" "$D/lock.after"
rup "$D" update >/dev/null 2>&1
assert_eq "idempotent: a second update rewrites nothing" "" "$(diff "$D/lock.after" "$D/base.lock")"

# The half-rewrite that S1 must refuse — proves the post-condition check above can go red.
sed -i.bak "s/^UPSTREAM_DIGEST=.*/UPSTREAM_DIGEST=$OLD/" "$D/base.lock"
run_check s1 red "S1 refuses a lock that disagrees with the Containerfile" -- rup "$D" assert

ctx "$NEW" fail
cp "$D/base.lock" "$D/lock.before"
run_check update red "unreachable registry → update fails" -- rup "$D" update
assert_eq "…and leaves base.lock untouched" "" "$(diff "$D/lock.before" "$D/base.lock")"

t_finish resolve-upstream.test.sh

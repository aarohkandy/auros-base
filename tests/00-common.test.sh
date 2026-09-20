#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/00-common.test.sh — build/00-common.sh's preflight, against a synthetic fake root.
#
# 00-common.sh is the only build script that needs NO extraction: every path it touches is already
# parameterised through an environment variable it reads with a default
# (AUROS_BUILD_DIR, AUROS_PREFIX, AUROS_LIBEXEC). So the REAL FILE IS EXECUTED, unmodified, with
# those pointed at a scratch tree and with rpm/dnf/systemctl stubbed on PATH. Nothing below is a
# copy of the code under test, which is the whole point.
#
# WHAT THE PREFLIGHT IS FOR, and therefore what has to be tested harder than the happy path:
#
#   A build cannot introspect its own FROM line. So this step compares the two things it CAN see —
#   the digest the Containerfile declared and the digest base.lock records — and refuses the build
#   when they disagree. Check S1 in CI is the authoritative version, run from outside against the
#   resolved parent; this is the one that fails in the build log next to its cause.
#
#   Every refusal below is a build that must not happen. The acceptances are one case each; the
#   refusals are most of this file, per spec §6C ("the abort path is tested more than the happy
#   path").
#
# THE D21 CASES ARE THE INTERESTING ONES. Upstream garbage-collects the digest we pin after ~90 days
# (ublue-os/aurora runs ghcr-cleanup weekly with keep-n-tagged: 7), so we mirror it into our own
# namespace and the FROM may legitimately name the mirror instead of upstream. That makes "the image
# name is not what base.lock says" a condition with two opposite correct answers, which is exactly
# the kind of thing that gets implemented as "accept anything" and then never noticed.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

STUBS="$(stubdir)"
install_sed_shim "$STUBS"

# ── the fake machine's binaries ──────────────────────────────────────────────────────────────────
# These are not simulations of dnf and rpm. They are the smallest thing that lets the code under
# test reach its own assertions: `rpm -q` answers "installed" for a package named in $FAKE_PKGS,
# `dnf` exists so auros_pkg_mgr() resolves, and systemctl knows nothing.
stub "$STUBS" rpm <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -q)
    shift
    [ "${1:-}" = "--qf" ] && { fmt="$2"; shift 2; }
    for p in $FAKE_PKGS; do [ "$p" = "${1:-}" ] && { echo "${1}-1.0-1.fc44"; exit 0; }; done
    echo "package ${1:-} is not installed"; exit 1 ;;
  *) exit 1 ;;
esac
SH
stub "$STUBS" dnf <<'SH'
#!/usr/bin/env bash
exit 0
SH
stub "$STUBS" systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
export FAKE_PKGS=""

REAL_LOCK="$REPO/base.lock"
REAL_DIGEST="$(grep -E '^UPSTREAM_DIGEST=' "$REAL_LOCK" | head -1 | cut -d= -f2-)"
REAL_IMAGE="$(grep -E '^UPSTREAM_IMAGE=' "$REAL_LOCK" | head -1 | cut -d= -f2-)"
[ -n "$REAL_DIGEST" ] || t_abort "base.lock has no UPSTREAM_DIGEST — this test would be vacuous"

# ── the fake build context ───────────────────────────────────────────────────────────────────────
# mkctx <lock-body|@real|@none> — returns a fresh root with build/ copied in and base.lock written.
# build/ is COPIED FROM THE REPO rather than faked, because auros_preflight() enumerates the real
# step scripts and reports which of their data directories it can see; faking that would test the
# fake.
mkctx() {
  local body="$1" root ctx
  root="$(newroot)"
  ctx="$root/tmp/auros-build"
  mkdir -p "$ctx"
  cp -R "$REPO/build" "$ctx/build"
  case "$body" in
    @none) : ;;
    @real) cp "$REAL_LOCK" "$ctx/base.lock" ;;
    *)     printf '%s\n' "$body" > "$ctx/base.lock" ;;
  esac
  printf '%s' "$root"
}

# preflight <root> [VAR=VAL ...] — execute the REAL build/00-common.sh against that root.
preflight() {
  local root="$1"; shift
  env -i \
    PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$root" \
    FAKE_PKGS="" \
    AUROS_BUILD_DIR="$root/tmp/auros-build" \
    AUROS_PREFIX="$root/usr/lib/auros" \
    AUROS_LIBEXEC="$root/usr/libexec/auros" \
    SOURCE_DATE_EPOCH=1789504430 \
    "$@" \
    bash "$REPO/build/00-common.sh"
}

printf '00-common.sh — preflight, against a synthetic fake root  (%s)\n' "$T_SED_MODE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the one acceptance"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
t_exempt preflight.happy \
  "a whole-script smoke run, not a check: it exists to prove the preflight completes and writes the
       image's self-record. Every assertion inside it is exercised in both directions under its own id
       below, so a green-only reading here is the correct one."
R="$(mkctx @real)"
run_check preflight.happy green "the real base.lock and a matching UPSTREAM_DIGEST" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "says the digest matched"        "base digest matches base.lock" "$T_LAST_OUT"
assert_has "says the image matched"         "base image matches base.lock"  "$T_LAST_OUT"
assert_file "wrote the in-image lock copy"  "$R/usr/lib/auros/base.lock"
assert_file "wrote the release record"      "$R/usr/lib/auros/release"
assert_file "wrote the build manifest"      "$R/usr/lib/auros/build-steps.tsv"

# The release record is the image's permanent statement about itself. It must contain the LOCK's
# digest, not whatever the build argument happened to say — those are equal here, and the point is
# that the file is derived from the checked value rather than the declared one.
assert_has "release names the locked digest" "AUROS_UPSTREAM_DIGEST=$REAL_DIGEST" "$(cat "$R/usr/lib/auros/release")"
assert_not "release carries no timestamp"    "$(date +%Y-%m-%dT)" "$(cat "$R/usr/lib/auros/release")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "digest mismatch — the realistic mistake: one of the two files edited, the other not"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
OTHER="sha256:$(printf '0%.0s' $(seq 1 64))"

R="$(mkctx @real)"
run_check preflight.digest red "Containerfile digest differs from base.lock" \
  -- preflight "$R" "UPSTREAM_DIGEST=$OTHER" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "names both digests" "digest mismatch" "$T_LAST_OUT"
assert_has "names check S1"     "check S1"        "$T_LAST_OUT"
assert_nofile "and wrote nothing into the image" "$R/usr/lib/auros/release"

# Single-character drift is the case S1's fails_on calls out by name. A check that only catches a
# wholly different digest would pass a typo, and a typo is how this actually goes wrong.
ONECHAR="${REAL_DIGEST%?}$([ "${REAL_DIGEST: -1}" = "a" ] && echo b || echo a)"
R="$(mkctx @real)"
run_check preflight.digest red "one character of the digest differs" \
  -- preflight "$R" "UPSTREAM_DIGEST=$ONECHAR" "UPSTREAM_IMAGE=$REAL_IMAGE"

R="$(mkctx @real)"
run_check preflight.digest green "the digests agree" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "malformed digests — a value that is not a digest at all"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
for bad_digest in \
  "stable" \
  "911281f2aaa42bfd17532c5cef917aba8d7ac8c0faeb1c1edc6a43dc28d0d2f1" \
  "sha512:911281f2aaa42bfd17532c5cef917aba8d7ac8c0faeb1c1edc6a43dc28d0d2f1" \
  ""
do
  R="$(mkctx "UPSTREAM_IMAGE=$REAL_IMAGE
UPSTREAM_TAG=stable
UPSTREAM_DIGEST=$bad_digest")"
  run_check preflight.digest-format red "base.lock UPSTREAM_DIGEST='${bad_digest:-<empty>}'" \
    -- preflight "$R" "UPSTREAM_DIGEST=${bad_digest:-x}" "UPSTREAM_IMAGE=$REAL_IMAGE"
done
R="$(mkctx @real)"
run_check preflight.digest-format green "base.lock UPSTREAM_DIGEST is a sha256 digest" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# A lockfile with every OTHER key but no digest line. This is what a half-applied hand edit looks
# like, and `grep ... | cut` returns empty rather than failing, so without the explicit -n test the
# comparison would be "" != "$UPSTREAM_DIGEST" and the message would be about a mismatch rather than
# about a missing line.
R="$(mkctx "UPSTREAM_IMAGE=$REAL_IMAGE
UPSTREAM_TAG=stable
UPSTREAM_RESOLVED_AT=2026-09-20T21:25:07Z")"
run_check preflight.digest-present red "base.lock has no UPSTREAM_DIGEST line at all" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "says which line is missing" "no UPSTREAM_DIGEST line" "$T_LAST_OUT"
R="$(mkctx @real)"
run_check preflight.digest-present green "base.lock has an UPSTREAM_DIGEST line" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the lockfile is absent, and the build argument is absent"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(mkctx @none)"
run_check preflight.lock-present red "base.lock was not COPYed into the build context" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "names the Containerfile as the cause" "COPYed" "$T_LAST_OUT"
R="$(mkctx @real)"
run_check preflight.lock-present green "base.lock is present" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# UPSTREAM_DIGEST unset is the case that would make the whole assertion vacuous if it were handled by
# defaulting: an unset argument compared against the lock would be "" != digest, which happens to
# fail — but it would fail with the wrong message, and a later refactor that defaulted it to the lock
# value would make the comparison compare the lock against itself and pass on everything.
R="$(mkctx @real)"
run_check preflight.arg-present red "UPSTREAM_DIGEST is not passed in as a build ARG" \
  -- preflight "$R" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "says the Containerfile must pass it" "must pass its FROM digest in as a build ARG" "$T_LAST_OUT"
R="$(mkctx @real)"
run_check preflight.arg-present green "UPSTREAM_DIGEST is passed in" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the build context did not arrive"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(mkctx @real)"; rm -rf "$R/tmp/auros-build/build"
run_check preflight.context red "the COPY of build/ did not land" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"
assert_has "names the missing directory" "is missing" "$T_LAST_OUT"
R="$(mkctx @real)"
run_check preflight.context green "the COPY of build/ landed" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "D21 — the FROM may name the mirror, and may not name anything else"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Upstream deletes the blob we pin (ghcr-cleanup, weekly, keep-n-tagged: 7), so we mirror the pinned
# digest into our own namespace and the FROM may point there instead. `skopeo copy --all` preserves
# the manifest digest, so the mirror is the same bytes under a different name — which is why this is
# a legal second answer rather than a hole. Every OTHER name is a build on a base nobody chose.
MIRROR="ghcr.io/aarohkandy/auros-upstream-mirror"

R="$(mkctx @real)"
run_check preflight.image green "FROM names the upstream base.lock pins" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$REAL_IMAGE"

R="$(mkctx "$(cat "$REAL_LOCK"; printf 'MIRROR_IMAGE=%s\n' "$MIRROR")")"
run_check preflight.image green "FROM names the D21 mirror declared in base.lock" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$MIRROR"
assert_has "says it is the mirror, not upstream" "D21 mirror" "$T_LAST_OUT"

R="$(mkctx @real)"
run_check preflight.image green "FROM names the mirror via AUROS_MIRROR_IMAGE" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$MIRROR" "AUROS_MIRROR_IMAGE=$MIRROR"

# No mirror name supplied anywhere: accepted on the naming convention, and it must SAY that nothing
# verified which mirror it is. Silently accepting would make `*/auros-upstream-mirror` a name anyone
# could register in any namespace and have us build on.
R="$(mkctx @real)"
run_check preflight.image green "FROM matches the mirror naming convention with nothing to verify against" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=ghcr.io/someoneelse/auros-upstream-mirror"
assert_has "warns that it verified nothing" "NAMING CONVENTION" "$T_LAST_OUT"

for wrong in \
  "ghcr.io/ublue-os/bluefin" \
  "ghcr.io/attacker/aurora" \
  "docker.io/library/fedora" \
  "ghcr.io/aarohkandy/auros-base"
do
  R="$(mkctx "$(cat "$REAL_LOCK"; printf 'MIRROR_IMAGE=%s\n' "$MIRROR")")"
  run_check preflight.image red "FROM names '$wrong'" \
    -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$wrong"
  assert_has "says which base was expected" "base image mismatch" "$T_LAST_OUT"
done

# And the one that proves the mirror clause is not a blanket bypass: a DECLARED mirror that the FROM
# does not match must still be refused, even though the FROM looks mirror-ish.
R="$(mkctx "$(cat "$REAL_LOCK"; printf 'MIRROR_IMAGE=%s\n' "$MIRROR")")"
run_check preflight.image red "a declared mirror exists and FROM names a different mirror" \
  -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=ghcr.io/attacker/auros-upstream-mirror"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "mask_unit — masked is a filesystem fact, not a systemctl opinion"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# 10-hardening.sh's central sshd claim is "masked, NOT disabled", because a disabled unit is one
# `systemctl enable` away from running and socket-activated units start on activation while disabled.
# mask_unit() lives here, so it is tested here. Extracted from the shipping file and pointed at a
# fake root; a stub systemctl that exits 0 while doing nothing is the realistic adversary, because
# that is exactly what `systemctl enable` does inside a container.
MASK_FN="$(extract_fn "$REPO/build/00-common.sh" mask_unit \
  | rootify /etc/systemd/system /usr/lib/systemd/system)"
HAVE_UNIT_FN='have_unit() { [ -e "$ROOT/usr/lib/systemd/system/$1" ]; }'
STUB_LIB='die() { echo "die: $*" >&2; exit 1; }
record() { :; }
_systemctl_offline() { return 0; }   # exits 0 and does nothing — the realistic adversary
'"$HAVE_UNIT_FN"

mask_case() { # <root> <unit>
  ROOT="$1" bash -c "$STUB_LIB
$MASK_FN
mask_unit '$2'"
}

R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system"; : > "$R/usr/lib/systemd/system/sshd.service"
run_check mask_unit green "a unit that exists is masked" -- mask_case "$R" sshd.service
assert_symlink_to "and the mask is a symlink to /dev/null" "$R/etc/systemd/system/sshd.service" /dev/null

# A unit that does not exist must return non-zero so the caller can say "not present on this base"
# rather than claim it masked something. 10-hardening.sh's `if mask_unit "$u"; then did "masked"`
# depends on this distinction, and getting it backwards would print a masked-line for a unit that was
# never there — a true-sounding claim about nothing.
R="$(newroot)"
run_check mask_unit red "a unit that does not exist is not reported as masked" -- mask_case "$R" sshd.service
assert_nofile "and no mask link was invented for it" "$R/etc/systemd/system/sshd.service"

# THE CASE THAT MATTERS: the unit was merely DISABLED — no symlink anywhere — and systemctl claims
# success. mask_unit must still produce the /dev/null link itself rather than trusting the exit code.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
: > "$R/usr/lib/systemd/system/sshd.socket"
run_check mask_unit green "systemctl exits 0 and does nothing; mask_unit masks it anyway" -- mask_case "$R" sshd.socket
assert_symlink_to "the link exists despite the no-op systemctl" "$R/etc/systemd/system/sshd.socket" /dev/null

# And the refusal: if the link cannot be made to point at /dev/null, mask_unit must die rather than
# return success. Simulated by making the target an unwritable directory.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system"; : > "$R/usr/lib/systemd/system/sshd.service"
mkdir -p "$R/etc/systemd/system"; chmod 0500 "$R/etc/systemd/system"
run_check mask_unit red "masking cannot be completed — refuses rather than claiming success" -- mask_case "$R" sshd.service
chmod 0700 "$R/etc/systemd/system"

t_finish "00-common.sh"

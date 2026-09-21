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
# The shim (and any other stub) must be ahead of the real tools for every block this file runs.
# Without this the build scripts' GNU `sed -i` silently became a BSD `sed -i <suffix>` and corrupted
# the file it was meant to edit, while still exiting 0.
export PATH="$STUBS:$PATH"

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

# THE ANCHOR ON THAT CONVENTION. `/auros-upstream-mirror$` is the only thing standing between "we
# accepted a mirror we could not verify" and "we accepted anything whose name contains our mirror's
# name". Drop the `$` and ghcr.io/attacker/auros-upstream-mirror-evil becomes a legitimate base:
# a name anybody can register, in any namespace, in the one branch that deliberately verifies
# nothing. The warning above is what makes this branch tolerable, and the anchor is what keeps the
# branch narrow enough for the warning to be honest.
for nearmiss in \
  "ghcr.io/attacker/auros-upstream-mirror-evil" \
  "ghcr.io/attacker/auros-upstream-mirror2" \
  "ghcr.io/attacker/auros-upstream-mirror/base" \
  "ghcr.io/attacker/notauros-upstream-mirror-x"
do
  R="$(mkctx @real)"
  run_check preflight.image red "FROM names '$nearmiss' — contains the mirror name but is not it" \
    -- preflight "$R" "UPSTREAM_DIGEST=$REAL_DIGEST" "UPSTREAM_IMAGE=$nearmiss"
  assert_has "refused as a base nobody chose" "base image mismatch" "$T_LAST_OUT"
  assert_nofile "and wrote no provenance record for it" "$R/usr/lib/auros/release"
done

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


# ── the presence test, which decides whether anything is masked at all ───────────────────────────
# `if ! have_unit "$u" && [ ! -e "/usr/lib/systemd/system/$u" ]; then return 1; fi`
#
# AND, not OR, and the two halves answer different questions. have_unit asks systemctl (which knows
# about aliases, generators and units under /etc); the -e test asks the filesystem about /usr/lib
# specifically. A unit that only ONE of them can see is still a unit, and must still be masked.
#
# The old test stubbed have_unit as `[ -e "$ROOT/usr/lib/systemd/system/$1" ]` — the same question
# twice — so && and || were indistinguishable here. With ||, a unit present in /etc/systemd/system
# but not /usr/lib is reported ABSENT and never masked, and 10-hardening.sh prints "not present on
# this base" about a unit that is sitting there enabled.
mask_case_hu() { # <root> <unit> <have_unit: yes|no>
  ROOT="$1" HU="$3" bash -c "die() { echo \"die: \$*\" >&2; exit 1; }
record() { :; }
_systemctl_offline() { return 0; }
have_unit() { [ \"\$HU\" = yes ]; }
$MASK_FN
mask_unit '$2'"
}

# systemctl knows the unit; /usr/lib does not have a file for it. This is a unit shipped in
# /etc/systemd/system, or an alias, or one a generator produces.
R="$(newroot)"; mkdir -p "$R/etc/systemd/system"
run_check mask_unit green "systemctl knows the unit and /usr/lib has no file for it" -- mask_case_hu "$R" sshd.socket yes
assert_symlink_to "it is masked anyway" "$R/etc/systemd/system/sshd.socket" /dev/null

# The reverse: the file is on disk and systemctl (offline, in a container, with no bus) says nothing.
# That is the ORDINARY case inside an image build, which is what makes getting it wrong expensive.
R="$(newroot)"; mkdir -p "$R/usr/lib/systemd/system" "$R/etc/systemd/system"
: > "$R/usr/lib/systemd/system/abrtd.service"
run_check mask_unit green "/usr/lib has the file and systemctl knows nothing" -- mask_case_hu "$R" abrtd.service no
assert_symlink_to "it is masked anyway" "$R/etc/systemd/system/abrtd.service" /dev/null

# Only when BOTH say no is the unit genuinely absent.
R="$(newroot)"; mkdir -p "$R/etc/systemd/system"
run_check mask_unit red "neither systemctl nor /usr/lib has heard of it" -- mask_case_hu "$R" nosuch.service no
assert_nofile "and nothing was invented for it" "$R/etc/systemd/system/nosuch.service"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "enable_unit — 'enabled' is a symlink that exists, not an exit code"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# enable_unit() had NO tests. It is what puts firewalld.service, auros-flatpak-update.timer and
# auros-hardening-assert.service into service — the firewall, the application update path, and the
# runtime hardening assertion. A unit it failed to enable would be reported "enabled" in the build
# console and would simply never run, on every machine, silently.
#
# Two specific failures are reachable by one-character edits and both are tested here:
#   `[ "$linked" -eq 1 ]` -> `-ge 0`  a unit with no [Install] section is called enabled
#   `ln -sfn "../$u"`     -> `"$u"`   the link points at ITSELF; nothing resolves, nothing starts
ENABLE_FN="$(extract_fn "$REPO/build/00-common.sh" _unit_wantedby | rootify /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system)
$(extract_fn "$REPO/build/00-common.sh" enable_unit | rootify /etc/systemd/system /usr/lib/systemd/system)"

enable_case() { # <root> <unit>
  ROOT="$1" bash -c "die()  { echo \"die: \$*\" >&2; exit 1; }
did()   { echo \"DID \$*\"; }
found() { echo \"FOUND \$*\"; }
record(){ :; }
_systemctl_offline() { return 0; }   # exits 0 and does nothing — what it does inside a container
$ENABLE_FN
enable_unit '$2'"
}

mkunit() { # <root> <unit> <install-section-body>
  mkdir -p "$1/usr/lib/systemd/system"
  printf '[Unit]\nDescription=%s\n\n[Service]\nExecStart=/bin/true\n\n%s' "$2" "$3" > "$1/usr/lib/systemd/system/$2"
}

R="$(newroot)"
mkunit "$R" firewalld.service '[Install]
WantedBy=multi-user.target
'
run_check enable_unit green "a unit with WantedBy=multi-user.target" -- enable_case "$R" firewalld.service
assert_file "the .wants symlink exists" "$R/usr/lib/systemd/system/multi-user.target.wants/firewalld.service"
assert_symlink_to "and it is relative, so it survives being moved with the tree" \
  "$R/usr/lib/systemd/system/multi-user.target.wants/firewalld.service" "../firewalld.service"
# THE ANTI-DANGLING ASSERTION. `ln -sfn "$u"` instead of "../$u" produces a link that points at
# itself, and a self-referential symlink still LOOKS like a symlink. Reading through it is what
# distinguishes a working enable from a decorative one.
assert_has "and reading through the link reaches the real unit file" "Description=firewalld.service" \
  "$(cat "$R/usr/lib/systemd/system/multi-user.target.wants/firewalld.service" 2>/dev/null || echo '<dangling>')"

# Several WantedBy targets on one line is legal and is how timers that want more than one target are
# written. All of them must be linked, not just the first.
R="$(newroot)"
mkunit "$R" auros-flatpak-update.timer '[Install]
WantedBy=timers.target multi-user.target
'
run_check enable_unit green "a unit with two WantedBy targets on one line" -- enable_case "$R" auros-flatpak-update.timer
assert_file "linked into timers.target.wants"      "$R/usr/lib/systemd/system/timers.target.wants/auros-flatpak-update.timer"
assert_file "linked into multi-user.target.wants"  "$R/usr/lib/systemd/system/multi-user.target.wants/auros-flatpak-update.timer"

# Already enabled: idempotent. The whole build must be runnable twice over one filesystem (check S7).
run_check enable_unit green "running it a second time over the same filesystem" -- enable_case "$R" auros-flatpak-update.timer
assert_file "the link is still there" "$R/usr/lib/systemd/system/timers.target.wants/auros-flatpak-update.timer"

# THE REFUSAL. A unit with no [Install] section cannot be enabled by anything — systemd has nowhere
# to link it. Reporting "enabled" for it is the false claim this function exists to make impossible.
R="$(newroot)"
mkunit "$R" auros-hardening-assert.service ''
run_check enable_unit red "a unit with no [Install] section at all" -- enable_case "$R" auros-hardening-assert.service
assert_has "says it cannot be enabled, only started by something else" "no WantedBy target" "$T_LAST_OUT"

R="$(newroot)"
mkunit "$R" oneshot.service '[Install]
RequiredBy=ostree-finalize-staged.service
'
run_check enable_unit red "a unit that is RequiredBy but not WantedBy" -- enable_case "$R" oneshot.service
assert_has "names the limitation rather than silently succeeding" "no WantedBy target" "$T_LAST_OUT"

# And the case where the link cannot be created at all.
R="$(newroot)"
mkunit "$R" firewalld.service '[Install]
WantedBy=multi-user.target
'
chmod 0500 "$R/usr/lib/systemd/system"
run_check enable_unit red "the .wants directory cannot be created" -- enable_case "$R" firewalld.service
chmod 0700 "$R/usr/lib/systemd/system"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "pkg_ensure — 'installed' is rpm's answer afterwards, not the package manager's exit code"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# pkg_ensure() had no tests either, and it installs selinux-policy-targeted, firewalld, sudo, polkit
# and greenboot — the hardening and the rollback path. Three things it does are each one edit from
# being a no-op, and all three would leave the build log saying "installed":
#
#   the early return      `-eq 0` -> `-ge 0` means it never installs anything, ever
#   the install line      dropping --setopt=install_weak_deps=False breaks the subtraction promise
#   the post-verification `have_pkg || die` is what makes "installed" a measurement
PKG_FN="$(extract_lines "$REPO/build/00-common.sh" '^have_(pkg|cmd)\(\)')
$(extract_fn "$REPO/build/00-common.sh" auros_pkg_mgr)
$(extract_fn "$REPO/build/00-common.sh" pkg_ensure)"

pkg_run() { # <root> <installed-after: yes|no> <pkgs...>
  local root="$1" after="$2"; shift 2
  local d="$root/bin"; mkdir -p "$d"
  # rpm -q: answers from $PRESENT, which the dnf5 stub appends to when $AFTER is yes. That is the
  # whole point — the verification reads the world AFTER the install, not the installer's opinion.
  cat > "$d/rpm" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-q" ] && shift
[ "${1:-}" = "--qf" ] && shift 2
p="${1:-}"
grep -qxF "$p" "$PRESENT_FILE" 2>/dev/null && { echo "${p}-1.0-1.fc44"; exit 0; }
echo "package $p is not installed"; exit 1
SH
  # dnf5: records its argv, and installs (or does not) depending on $AFTER. A package manager that
  # exits 0 without installing is the case 00-common.sh's comment names by hand.
  cat > "$d/dnf5" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_FILE"
if [ "$AFTER" = yes ]; then
  for a in "$@"; do case "$a" in -*|install) ;; *) printf '%s\n' "$a" >> "$PRESENT_FILE" ;; esac; done
fi
exit 0
SH
  chmod 0755 "$d/rpm" "$d/dnf5"
  : > "$root/present"; : > "$root/argv"
  local p
  for p in ${PKG_PRESENT:-}; do printf '%s\n' "$p" >> "$root/present"; done
  # The stub directory goes FIRST, not alone: the stubs themselves need grep and bash, and a PATH
  # holding only the stubs makes every case die with "env: bash: not found" — a red that a test
  # expecting a refusal would happily score as the refusal it wanted. auros_pkg_mgr() probes dnf5
  # before dnf and rpm-ostree, so the stub is what resolves whatever else is on this machine.
  env -i PATH="$d:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$root" AFTER="$after" \
      PRESENT_FILE="$root/present" ARGV_FILE="$root/argv" \
      "$BASH" -c "did()   { echo \"DID \$*\"; }
found() { echo \"FOUND \$*\"; }
die()   { echo \"DIE \$*\" >&2; exit 1; }
record(){ :; }
AUROS_PKG_MGR=\"\"
$PKG_FN
pkg_ensure $*"
}

# A package that is missing must actually be handed to the package manager, with the weak-deps flag.
R="$(newroot)"; PKG_PRESENT=""
run_check pkg_ensure green "one missing package, and the package manager installs it" -- pkg_run "$R" yes firewalld
assert_has "the package manager was invoked with the package name" "firewalld" "$(cat "$R/argv")"
assert_has "it was an install"                                     "install"   "$(cat "$R/argv")"
# spec §1.2 is subtraction. A hardening layer that quietly drags in twenty recommended packages is
# the opposite, and nothing else in the repo would notice.
assert_has "weak dependencies are refused" "--setopt=install_weak_deps=False" "$(cat "$R/argv")"
assert_has "and it reports the installed version, not an intention" "installed firewalld" "$T_LAST_OUT"

R="$(newroot)"; PKG_PRESENT=""
run_check pkg_ensure green "several missing packages in one call" -- pkg_run "$R" yes selinux-policy-targeted sudo polkit
for p in selinux-policy-targeted sudo polkit; do
  assert_has "handed $p to the package manager" "$p" "$(cat "$R/argv")"
done

# Idempotence. Running the whole build twice over one filesystem must install nothing the second
# time (check S7 builds twice and compares). `-eq 0` -> `-ge 0` on the early return inverts this:
# the function returns before installing ANYTHING, on every call.
R="$(newroot)"; PKG_PRESENT="firewalld"
run_check pkg_ensure green "the package is already present" -- pkg_run "$R" yes firewalld
assert_eq  "the package manager was not invoked at all" "" "$(cat "$R/argv")"
assert_has "and it says so"  "firewalld already present" "$T_LAST_OUT"

# THE REFUSAL, and the reason the post-verification exists: a package manager that returns 0 without
# installing. `dnf install` does this for a package that is excluded, or filtered by a modular
# filter, or whose transaction was a no-op. Without the `have_pkg || die` the build continues, and
# the image ships without selinux-policy-targeted while the log says "installed selinux-policy-targeted".
R="$(newroot)"; PKG_PRESENT=""
run_check pkg_ensure red "the package manager exits 0 and installs nothing" -- pkg_run "$R" no selinux-policy-targeted
assert_has "says which package did not install" "selinux-policy-targeted did not install" "$T_LAST_OUT"
assert_has "and that rpm is the authority"      "rpm cannot find it"                      "$T_LAST_OUT"


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "install_file — every path it writes is recorded for the mtime re-stamp"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# 90-cleanup.sh re-stamps every path in $AUROS_WRITTEN_LIST with SOURCE_DATE_EPOCH as the last act of
# the build, which is what makes check S7 (build twice, compare content digests) possible. If
# install_file stops appending, the re-stamp covers nothing, and S7 fails forty minutes later in CI
# with no indication that the cause is here.
IF_FN="$(extract_fn "$REPO/build/00-common.sh" auros_stamp)
$(extract_fn "$REPO/build/00-common.sh" install_file)
$(extract_fn "$REPO/build/00-common.sh" install_text)"

R="$(newroot)"
printf 'SELINUX=enforcing\n' > "$R/src"
run_check install_file green "a file is installed from the build context" -- bash -c "
did() { echo \"DID \$*\"; }
die() { echo \"DIE \$*\" >&2; exit 1; }
record(){ :; }
SOURCE_DATE_EPOCH=1789504430
AUROS_WRITTEN_LIST='$R/written'
$IF_FN
install_file '$R/src' '$R/etc/selinux/config' 0644
install_text '$R/usr/lib/auros/release' 0644 <<'EOF'
AUROS_IMAGE_KIND=base
EOF
"
assert_file "the destination exists"                 "$R/etc/selinux/config"
assert_has  "install_file recorded its destination"  "$R/etc/selinux/config"      "$(cat "$R/written" 2>/dev/null || true)"
assert_has  "install_text recorded its destination"  "$R/usr/lib/auros/release"   "$(cat "$R/written" 2>/dev/null || true)"

run_check install_file red "the source file is not in the build context" -- bash -c "
did() { echo \"DID \$*\"; }
die() { echo \"DIE \$*\" >&2; exit 1; }
record(){ :; }
SOURCE_DATE_EPOCH=1789504430
AUROS_WRITTEN_LIST='$R/written'
$IF_FN
install_file '$R/nosuch' '$R/etc/nosuch' 0644"
assert_has "names the Containerfile as the cause" "did not COPY it" "$T_LAST_OUT"

t_finish "00-common.sh"

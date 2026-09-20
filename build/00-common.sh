#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/00-common.sh
#
# Two jobs in one file, on purpose:
#
#   SOURCED   by every other build script (`. /tmp/auros-build/build/00-common.sh`) — it is the shared
#             library: logging that the website's build console streams verbatim, package installation
#             that works whichever package manager this base actually has, offline systemd unit
#             manipulation, and file installation with deterministic timestamps.
#
#   EXECUTED  by the Containerfile's runner as step 00 — it is the preflight: it proves the build
#             context arrived intact, proves the digest this build claims to be derived from matches
#             base.lock, and writes the image's own record of what it is.
#
# Every function here is idempotent. Running the whole build twice over the same filesystem must
# produce the same filesystem, because check S7 builds twice and compares content digests.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Guard against double-sourcing. Sourced twice, the log prefix stack would grow and the manifest
# would gain duplicate rows, and S7 would see two different images from one input.
if [ -n "${AUROS_COMMON_SH:-}" ]; then
  return 0 2>/dev/null || true
fi
AUROS_COMMON_SH=1

# ── Paths ────────────────────────────────────────────────────────────────────────────────────────
# AUROS_BUILD_DIR is where the Containerfile put the build context. Nothing under it survives into
# the image; build/90-cleanup.sh removes it and asserts it is gone.
export AUROS_BUILD_DIR="${AUROS_BUILD_DIR:-/tmp/auros-build}"
# Everything the image knows about itself lives here. /usr, not /etc: on a bootc host /usr is what an
# image update replaces wholesale, while /etc is machine-local and three-way merged, so a fact about
# the image that lived in /etc could be stale or edited and we would have no way to tell.
export AUROS_PREFIX="${AUROS_PREFIX:-/usr/lib/auros}"
export AUROS_LIBEXEC="${AUROS_LIBEXEC:-/usr/libexec/auros}"
# Append-only record of what each build step changed. It ships in the image (it is evidence a
# customer can read) and it contains no timestamps, because a timestamp would make it the one file
# that differs between two otherwise identical builds.
export AUROS_MANIFEST="${AUROS_PREFIX}/build-steps.tsv"
# Paths written through install_file(), so 90-cleanup.sh can normalise their mtimes in one pass.
export AUROS_WRITTEN_LIST="${AUROS_BUILD_DIR}/.auros-written"

# SOURCE_DATE_EPOCH is set by the Containerfile and defaults there to the upstream base image's
# creation time. Every file we create is stamped with it. Without this, two builds a minute apart
# differ in every mtime and S7 can never pass.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

# ── Logging ──────────────────────────────────────────────────────────────────────────────────────
# THIS OUTPUT IS SHIPPED. The website's build console (spec §7) streams genuine build output, so
# every line printed here is a line a customer may read. It therefore has to be true: say what was
# done, not what was intended, and say it after doing it.
AUROS_STEP="${AUROS_STEP:-$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" .sh)}"

_auros_log() { printf 'auros[%s] %s\n' "$AUROS_STEP" "$*"; }

# step  — announces a section. Announcing is not a claim that it worked.
step()  { printf '\n'; _auros_log "── $*"; }
# did   — states a completed fact. Only call it after the thing is true.
did()   { _auros_log "  ✓ $*"; }
# found — states an observation. Used by the telemetry inventory, where "we looked and it was not
#         there" is itself the deliverable.
found() { _auros_log "  · $*"; }
# warn  — something a human should read, that does not stop the build.
warn()  { _auros_log "  ! $*"; }
# die   — stops the build. The message must name what to do about it.
die()   { _auros_log "  ✗ $*"; exit 1; }

# record <action> <detail> — appends a row to the in-image manifest. No timestamp, by design.
record() {
  mkdir -p "$(dirname "$AUROS_MANIFEST")"
  printf '%s\t%s\t%s\n' "$AUROS_STEP" "$1" "${2-}" >> "$AUROS_MANIFEST"
}

# ── Probes ───────────────────────────────────────────────────────────────────────────────────────
have_cmd()  { command -v "$1" >/dev/null 2>&1; }
have_pkg()  { rpm -q "$1" >/dev/null 2>&1; }
have_unit() { [ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]; }

# ── Package installation ─────────────────────────────────────────────────────────────────────────
# WHICH PACKAGE MANAGER THIS BASE HAS IS NOT SOMETHING WE GUESS.
#
# Fedora 44 ships dnf5 as `dnf`, and `dnf5` also exists as its own name. Universal Blue's images have
# historically built with `rpm-ostree install` and have been migrating to dnf5; Aurora's own state at
# the pinned digest is not something this repo has measured. Rather than pick one and find out in CI,
# this resolves at build time and PRINTS WHICH ONE IT USED, so the build console and the build log
# both record the answer instead of us assuming it.
AUROS_PKG_MGR=""
auros_pkg_mgr() {
  if [ -n "$AUROS_PKG_MGR" ]; then printf '%s' "$AUROS_PKG_MGR"; return 0; fi
  if   have_cmd dnf5;       then AUROS_PKG_MGR=dnf5
  elif have_cmd dnf;        then AUROS_PKG_MGR=dnf
  elif have_cmd rpm-ostree; then AUROS_PKG_MGR=rpm-ostree
  else die "no package manager found (looked for dnf5, dnf, rpm-ostree) — cannot install anything"
  fi
  printf '%s' "$AUROS_PKG_MGR"
}

# pkg_ensure <pkg>... — installs only what is missing. Prints what it installed and what was already
# there. Idempotent: a second run installs nothing and says so.
pkg_ensure() {
  local missing=() p mgr
  for p in "$@"; do
    if have_pkg "$p"; then found "$p already present"; else missing+=("$p"); fi
  done
  if [ ${#missing[@]} -eq 0 ]; then return 0; fi
  mgr="$(auros_pkg_mgr)"
  found "installing with $mgr: ${missing[*]}"
  case "$mgr" in
    dnf5|dnf)
      # --setopt=install_weak_deps=False: a hardening layer that quietly drags in twenty
      # recommended packages is the opposite of subtraction (spec §1.2).
      "$mgr" install -y --setopt=install_weak_deps=False "${missing[@]}"
      ;;
    rpm-ostree)
      rpm-ostree install --idempotent -y "${missing[@]}"
      ;;
  esac
  for p in "${missing[@]}"; do
    have_pkg "$p" || die "$p did not install — $mgr returned success but rpm cannot find it"
    did "installed $p ($(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p"))"
    record installed-package "$p"
  done
}

# ── systemd, offline ─────────────────────────────────────────────────────────────────────────────
# There is no running systemd inside an image build, so systemctl has to be told to operate on the
# filesystem rather than on a bus. Two spellings of that are tried, because which one a given
# systemd accepts is version-dependent and this repo has not measured it on the pinned base:
#   1. `systemctl --root=/`   — explicit offline root. Some versions reject "/" specifically.
#   2. `SYSTEMD_OFFLINE=1`    — forces offline mode without naming a root.
# If BOTH fail, the callers below fall back to creating the symlinks systemctl would have created,
# because "masked" and "enabled" are filesystem states, not daemon opinions — and a hardening step
# that silently no-ops is the worst outcome available.
_systemctl_offline() {
  SYSTEMD_OFFLINE=1 systemctl --root=/ "$@" >/dev/null 2>&1 && return 0
  SYSTEMD_OFFLINE=1 systemctl "$@" >/dev/null 2>&1 && return 0
  return 1
}

# The WantedBy targets a unit asks to be started by, read out of its own [Install] section. Used only
# by the manual fallback path.
_unit_wantedby() {
  local u="$1" f
  for f in "/etc/systemd/system/$u" "/usr/lib/systemd/system/$u" "/lib/systemd/system/$u"; do
    if [ -f "$f" ]; then
      sed -n 's/^WantedBy=//p' "$f" | tr ' ' '\n' | grep -v '^$' || true
      return 0
    fi
  done
}

# mask_unit <unit> — masked, not disabled. A disabled unit is one `systemctl enable` away from
# running, and socket-, dbus- and path-activated units start on activation even while disabled.
# Masking points the unit at /dev/null and nothing can activate it.
mask_unit() {
  local u="$1" link="/etc/systemd/system/$1"
  if ! have_unit "$u" && [ ! -e "/usr/lib/systemd/system/$u" ]; then
    return 1
  fi
  _systemctl_offline mask --no-reload "$u" || true
  if [ "$(readlink -f "$link" 2>/dev/null || true)" != "/dev/null" ]; then
    mkdir -p /etc/systemd/system
    ln -sfn /dev/null "$link"
  fi
  [ "$(readlink -f "$link")" = "/dev/null" ] || die "failed to mask $u — $link is not a link to /dev/null"
  record masked-unit "$u"
  return 0
}

# enable_unit <unit> — creates the WantedBy symlinks the unit's [Install] section asks for, and then
# proves they exist. Enablement is verified by looking at the filesystem rather than by trusting
# systemctl's exit code, because the offline paths above are the part we are least sure of.
enable_unit() {
  local u="$1" t linked=0
  _systemctl_offline enable --no-reload "$u" || true

  for t in $(_unit_wantedby "$u"); do
    if [ -e "/etc/systemd/system/$t.wants/$u" ] || [ -e "/usr/lib/systemd/system/$t.wants/$u" ]; then
      linked=1
      continue
    fi
    # Fallback: create the symlink ourselves, in /usr rather than /etc. On a bootc host /usr is
    # replaced wholesale by an image update while /etc is machine-local and three-way merged, so a
    # default that belongs to the image belongs in /usr — and an administrator can still override it
    # with a masking symlink in /etc.
    mkdir -p "/usr/lib/systemd/system/$t.wants"
    ln -sfn "../$u" "/usr/lib/systemd/system/$t.wants/$u"
    [ -e "/usr/lib/systemd/system/$t.wants/$u" ] || die "could not enable $u for $t"
    linked=1
    found "enabled $u for $t by symlink (systemctl offline enable did not do it)"
  done

  [ "$linked" -eq 1 ] || die "$u has no WantedBy target — it cannot be enabled, only started by something else"
  did "enabled $u"
  record enabled-unit "$u"
}

# ── File installation ────────────────────────────────────────────────────────────────────────────
# install_file <src> <dest> [mode]
#   Copies a build-context file into the image, stamps it with SOURCE_DATE_EPOCH, and records the
#   path so 90-cleanup.sh can re-normalise it after every other step has run.
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [ -f "$src" ] || die "build context is missing $src — the Containerfile did not COPY it"
  mkdir -p "$(dirname "$dest")"
  install -m "$mode" "$src" "$dest"
  auros_stamp "$dest"
  printf '%s\n' "$dest" >> "$AUROS_WRITTEN_LIST"
  did "wrote $dest (mode $mode)"
  record wrote-file "$dest"
}

# install_text <dest> <mode> — same, reading the content from stdin.
install_text() {
  local dest="$1" mode="${2:-0644}"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
  chmod "$mode" "$dest"
  auros_stamp "$dest"
  printf '%s\n' "$dest" >> "$AUROS_WRITTEN_LIST"
  did "wrote $dest (mode $mode)"
  record wrote-file "$dest"
}

auros_stamp() {
  # -h so a symlink is stamped rather than its target. Failure is not fatal: a filesystem that
  # cannot set an mtime costs us determinism, not correctness, and S7 is the check that catches it.
  touch -h -d "@${SOURCE_DATE_EPOCH}" "$1" 2>/dev/null || true
}

# ── Preflight (this file, executed rather than sourced) ──────────────────────────────────────────
auros_preflight() {
  AUROS_STEP="00-common"

  step "preflight"

  [ -d "$AUROS_BUILD_DIR/build" ] || die "$AUROS_BUILD_DIR/build is missing — the Containerfile's COPY did not land"
  found "build context at $AUROS_BUILD_DIR:"
  ( cd "$AUROS_BUILD_DIR" && find . -maxdepth 2 -mindepth 1 | sort | sed 's/^/auros[00-common]      /' )

  # Every script in build/ gets a chance to say whether its data files arrived. A script whose data
  # directory is missing is a script that will fail forty lines later for a reason nobody can see.
  local s name datadir
  for s in "$AUROS_BUILD_DIR"/build/[0-9][0-9]-*.sh; do
    [ -e "$s" ] || continue
    name="$(basename "$s" .sh)"
    datadir=""
    # Two conventions are supported and both are checked, so that adding a step never requires
    # editing the Containerfile:
    #   build/<nn>-<name>.d/   data beside the script, always copied with build/
    #   <name-without-prefix>/ a top-level directory, which needs its own COPY line
    [ -d "$AUROS_BUILD_DIR/build/$name.d" ] && datadir="build/$name.d"
    [ -d "$AUROS_BUILD_DIR/${name#[0-9][0-9]-}" ] && datadir="${datadir:+$datadir, }${name#[0-9][0-9]-}"
    found "step $name  data: ${datadir:-none}"
  done

  # ── The digest assertion (check S1's build-time half) ──────────────────────────────────────────
  # A build cannot introspect its own FROM line, so this compares two things it CAN see: the digest
  # the Containerfile declared (passed in as UPSTREAM_DIGEST) and the digest recorded in base.lock.
  # The third leg — that the FROM line actually resolved to that digest — is checkable only from
  # outside, and check S1 in CI is what checks it. This half catches the realistic failure: someone
  # edits the Containerfile and forgets base.lock, or the reverse.
  #
  # We deliberately do not read any upstream-provided image-info file to discover our own base.
  # Trusting the image to tell us what image it is defeats the point of pinning.
  local lock="$AUROS_BUILD_DIR/base.lock" lock_digest lock_image
  [ -f "$lock" ] || die "base.lock was not COPYed into the build context"
  # `|| true` on both: `set -o pipefail` is in force, so a grep that matches nothing would otherwise
  # abort here with no message instead of reaching the explanatory die below.
  lock_digest="$(grep -E '^UPSTREAM_DIGEST=' "$lock" | head -1 | cut -d= -f2- || true)"
  lock_image="$(grep -E '^UPSTREAM_IMAGE=' "$lock" | head -1 | cut -d= -f2- || true)"
  [ -n "$lock_digest" ] || die "base.lock has no UPSTREAM_DIGEST line"
  case "$lock_digest" in sha256:*) ;; *) die "base.lock UPSTREAM_DIGEST is not a sha256 digest: $lock_digest" ;; esac

  if [ -z "${UPSTREAM_DIGEST:-}" ]; then
    die "UPSTREAM_DIGEST is not set — the Containerfile must pass its FROM digest in as a build ARG"
  fi
  if [ "$UPSTREAM_DIGEST" != "$lock_digest" ]; then
    die "digest mismatch: Containerfile says $UPSTREAM_DIGEST, base.lock says $lock_digest — check S1 would fail this image"
  fi
  did "base digest matches base.lock: $lock_digest"
  did "base image: ${UPSTREAM_IMAGE:-$lock_image}"

  # ── The image's record of itself ───────────────────────────────────────────────────────────────
  mkdir -p "$AUROS_PREFIX" "$AUROS_LIBEXEC"
  # Truncated here, before the first install_file, so that a re-run of the whole build does not leave
  # a stale list behind for 90-cleanup.sh to normalise.
  : > "$AUROS_WRITTEN_LIST"
  install_file "$lock" "$AUROS_PREFIX/base.lock" 0644
  install_text "$AUROS_PREFIX/release" 0644 <<EOF
# What this image is. Written by build/00-common.sh. No timestamps: a timestamp here would be the
# one byte that differs between two otherwise identical builds and would fail check S7.
AUROS_IMAGE_NAME=auros-base
AUROS_IMAGE_KIND=base
AUROS_SOURCE_REPO=https://github.com/aarohkandy/auros-base
AUROS_UPSTREAM_IMAGE=${UPSTREAM_IMAGE:-$lock_image}
AUROS_UPSTREAM_TAG=${UPSTREAM_TAG:-unknown}
AUROS_UPSTREAM_DIGEST=${lock_digest}
AUROS_SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
EOF

  found "package manager: $(auros_pkg_mgr)"
  found "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}"
  did "preflight passed"
}

# Sourced or executed? BASH_SOURCE[0] equals $0 only when this file is the program being run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  auros_preflight "$@"
fi

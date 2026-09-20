#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/90-cleanup.sh
#
# Last step. Two jobs:
#
#   1. Nothing from the build survives into the image. Not the scripts, not the data files, not the
#      package-manager caches, not the logs written while installing.
#   2. Nothing non-deterministic survives either. Check S7 builds this image twice in one CI run and
#      compares CONTENT DIGESTS; every file whose bytes differ between two identical builds is a
#      direct failure of that check.
#
# It also runs the protected-set assertion, because this is the first point at which every other
# build step has had its turn and the question "did the build remove part of the update path?" can
# finally be answered.
#
# WHAT WE CANNOT MAKE DETERMINISTIC, SAID OUT LOUD: the RPM database at /usr/lib/sysimage/rpm records
# an install time per package, so its bytes differ between two builds no matter what we do here. That
# is exactly why spec §6B's "byte-identical image out" was amended (PLAN.md §3.3) to "same recipe +
# same pinned base ⇒ same content digest", and why the flatten step (D11,
# `rpm-ostree compose build-chunked-oci --bootc`) is what makes S7 pass rather than this script. We
# remove what we can and name what we cannot.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
. /tmp/auros-build/build/00-common.sh

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "normalise timestamps on everything the build wrote"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Every file written through install_file()/install_text() by any build step recorded its path here.
# They were stamped when written, but a later step may have touched one, so they are re-stamped once
# more now that no step is left to disturb them.
if [ -f "$AUROS_WRITTEN_LIST" ]; then
  n=0
  while IFS= read -r -u 3 f; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || continue
    touch -h -d "@${SOURCE_DATE_EPOCH}" "$f" 2>/dev/null || true
    n=$((n + 1))
  done 3< "$AUROS_WRITTEN_LIST"
  did "re-stamped $n build-written file(s) to SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"
else
  warn "no record of build-written files at $AUROS_WRITTEN_LIST — timestamps were not normalised"
fi

# The manifest is sorted so that two builds whose steps happened to interleave differently still
# produce the same file. It is deliberately kept: it is the image's own account of what was done to
# it, it contains no timestamps, and a customer can read it.
if [ -f "$AUROS_MANIFEST" ]; then
  sort -o "$AUROS_MANIFEST" "$AUROS_MANIFEST"
  touch -h -d "@${SOURCE_DATE_EPOCH}" "$AUROS_MANIFEST" 2>/dev/null || true
  did "build manifest at $AUROS_MANIFEST — $(wc -l < "$AUROS_MANIFEST" | tr -d ' ') recorded changes, sorted"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "package manager caches and history"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# `dnf clean all` is the supported way; the explicit rm afterwards is because "all" has historically
# not meant all. The RPM DATABASE ITSELF IS KEPT — checks S3 and S4 answer "is this package
# installed?" with `rpm -q`, and an image without an rpmdb cannot be checked at all.
mgr="$(auros_pkg_mgr)"
case "$mgr" in
  dnf5|dnf) "$mgr" clean all >/dev/null 2>&1 || warn "$mgr clean all returned non-zero" ;;
  rpm-ostree) rpm-ostree cleanup -m >/dev/null 2>&1 || warn "rpm-ostree cleanup returned non-zero" ;;
esac
did "ran $mgr cache cleanup"

for d in /var/cache/dnf /var/cache/libdnf5 /var/cache/yum /var/cache/PackageKit /var/cache/rpm-ostree \
         /var/lib/dnf /var/lib/PackageKit /var/cache/ldconfig; do
  if [ -e "$d" ]; then
    sz="$(du -sh "$d" 2>/dev/null | cut -f1 || true)"
    rm -rf "${d:?}"
    did "removed $d (${sz:-unknown size})"
  fi
done
# /var/lib/dnf held the transaction history database, whose rows are timestamped — it is both a cache
# and a determinism problem. It is recreated empty on first use.

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "secrets and per-machine identity that must not be baked into an image"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# THIS IS THE MOST IMPORTANT BLOCK IN THIS FILE. An image is installed onto every machine we sell.
# Anything here that is unique-per-machine becomes shared-across-the-fleet.

# ssh host keys. If any step caused openssh-server to generate them, every laptop in the school would
# present the same host identity, and one stolen image would authenticate as all of them.
if compgen -G '/etc/ssh/ssh_host_*' >/dev/null; then
  cnt="$(ls -1 /etc/ssh/ssh_host_* 2>/dev/null | wc -l | tr -d ' ' || true)"
  rm -f /etc/ssh/ssh_host_*
  did "removed ${cnt} baked ssh host key file(s) — they regenerate per machine on first boot"
else
  found "no ssh host keys were baked into the image"
fi

# machine-id must be EMPTY, not absent and not populated. Empty is the documented signal that makes
# systemd provision a fresh id on first boot; a populated one would give every machine in the fleet
# the same identity, which also breaks per-machine journald and DHCP client identifiers.
: > /etc/machine-id
did "/etc/machine-id truncated to zero bytes — each machine generates its own on first boot"

# A baked random seed means every machine starts from the same entropy pool.
rm -f /var/lib/systemd/random-seed /var/lib/random-seed
did "removed any baked systemd random seed"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "logs, temporary files and build inputs"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# /var/log must be empty in the image: `bootc container lint` checks it, and its contents are a
# minute-by-minute record of the build, so it is a determinism problem as well as a lint failure.
if [ -d /var/log ]; then
  find /var/log -mindepth 1 -delete 2>/dev/null || true
  did "emptied /var/log ($(find /var/log -mindepth 1 2>/dev/null | wc -l | tr -d ' ') entries remain)"
fi

rm -rf /var/lib/systemd/catalog/database /var/cache/man /var/lib/rpm-state 2>/dev/null || true
rm -rf /root/.cache /root/.dnf /root/.rpmdb 2>/dev/null || true
did "removed regenerable caches (journal catalogue, man cache, rpm transaction state, root's caches)"

# .rpmnew / .rpmorig are files a package manager left behind when it declined to overwrite something
# we had edited. Shipping them would ship a second, contradictory copy of a config file.
leftovers="$(find /etc /usr -xdev \( -name '*.rpmnew' -o -name '*.rpmorig' \) 2>/dev/null || true)"
if [ -n "$leftovers" ]; then
  printf '%s\n' "$leftovers" | while IFS= read -r f; do found "removing package leftover $f"; rm -f "$f"; done
  did "removed package configuration leftovers"
else
  found "no .rpmnew/.rpmorig leftovers"
fi

# The build inputs themselves. This is the line that makes "nothing from the build survives" true of
# the final filesystem.
rm -rf "$AUROS_BUILD_DIR"
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
[ ! -e "$AUROS_BUILD_DIR" ] || die "$AUROS_BUILD_DIR still exists after removing it"
did "removed the build context at $AUROS_BUILD_DIR"
found "the COPY layer that carried it still exists in the intermediate OCI image; the publish-time flatten (DECISIONS.md D11, rpm-ostree compose build-chunked-oci --bootc) rebuilds the published image from the committed filesystem, so it does not reach a customer"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "protected set — nothing this build did removed the update path"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Check S10 in CI is the gate. This is the same assertion run at the point of damage, so that a bad
# edit fails in the build log next to its cause rather than forty minutes later in the matrix.
#
# The protected list was copied out of the build context before it was deleted, above — so read it
# now from the copy we keep in the image.
plist="${AUROS_PREFIX}/protected.list"
if [ ! -f "$plist" ]; then
  warn "protected.list was not preserved into the image; falling back to the built-in minimum"
  plist=""
fi

fatal_missing=""
pending_missing=""
check_one() {
  local kind="$1" target="$2" file pattern
  case "$kind" in
    cmd)  have_cmd  "$target" ;;
    pkg)  have_pkg  "$target" ;;
    unit) have_unit "$target" ;;
    path) [ -e "$target" ] ;;
    # <file>::<extended-regex>. Used where a bare path check would be vacuous — see protected.list.
    content)
      file="${target%%::*}"
      pattern="${target#*::}"
      [ -f "$file" ] && grep -qE -- "$pattern" "$file"
      ;;
    *)    return 0 ;;
  esac
}

if [ -n "$plist" ]; then
  while IFS=$'\t' read -r -u 3 severity kind target; do
    case "${severity:-}" in ''|'#'*) continue ;; esac
    if check_one "$kind" "$target"; then
      found "PROTECTED ok      $kind $target"
    elif [ "$severity" = "fatal" ]; then
      fatal_missing="$fatal_missing $kind:$target"
    else
      pending_missing="$pending_missing $kind:$target"
    fi
  done 3< "$plist"
else
  for c in bootc systemctl; do
    have_cmd "$c" || fatal_missing="$fatal_missing cmd:$c"
  done
fi

if [ -n "$pending_missing" ]; then
  warn "NOT YET PRESENT:$pending_missing"
  warn "  these are installed by build steps this script does not own — the update agent (task A4) and the"
  warn "  signature trust material (task A5, DECISIONS.md D8). Check S10 will refuse to publish an image"
  warn "  that is still missing them, which is the correct place for that gate. This build continues so"
  warn "  that one task's unlanded work does not block every other build in the repo."
fi
if [ -n "$fatal_missing" ]; then
  die "PROTECTED SET BROKEN:$fatal_missing — something in this build removed part of the base the machine needs to be patchable. Refusing to produce an image we could never update."
fi
did "protected set intact"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "cleanup complete"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
did "image filesystem contains no build scripts, no package caches, no logs, no baked host identity"
found "still non-deterministic by nature, and therefore compared as a CONTENT digest rather than byte-for-byte (check S7): the RPM database's per-package install times, and any file a package's own scriptlet generated at install"

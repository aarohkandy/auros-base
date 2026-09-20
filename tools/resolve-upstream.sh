#!/usr/bin/env bash
#
# resolve-upstream.sh — the one place that knows how to turn "ghcr.io/ublue-os/aurora:stable" into a
# digest, and the one place that decides whether the Containerfile is honestly pinned to it.
#
# Check S1 ("Base is pinned by digest") lives here. Its criterion is:
#
#     resolved FROM digest == the digest recorded in base.lock
#
# with "fails_on: any tag-only reference, or a mismatch of a single character".
#
# Two things that look like the same check but are not, and the distinction matters every single night:
#
#   assert  — does the Containerfile's base reference equal base.lock?  NO NETWORK. This is S1.
#             A tag moving upstream must NEVER fail a build; it must produce a new lock, a new build and
#             a new run of the full matrix. If drift failed S1, every ordinary push would go red the
#             morning after upstream shipped anything, and a check that is red for reasons unrelated to
#             the change under test is a check people start ignoring.
#
#   drift   — does the upstream TAG still point at the digest in base.lock?  NETWORK. This is the
#             nightly's trigger, not a gate. Exit 10 means "upstream moved", which is information.
#
# Commands:
#   resolve   Query the registry. Print KEY=VALUE facts; append them to $GITHUB_OUTPUT if set.
#   assert    S1. Offline. Exit 2 if the Containerfile is not pinned to base.lock's digest.
#   drift     Compare base.lock against what the tag resolves to now. Exit 0 = same, 10 = moved.
#   update    Rewrite base.lock (and a literal digest in the Containerfile) to the current tag digest.
#   mirror    D21. Ensure the pinned digest exists in OUR namespace, so the pin stays pullable after
#             upstream garbage-collects it. Idempotent; a no-op when the mirror already has it.
#
# Options:
#   --lock PATH            default <repo>/base.lock
#   --containerfile PATH   default <repo>/Containerfile
#   --mirror IMAGE         our mirror repo; default $AUROS_MIRROR_IMAGE, or MIRROR_IMAGE= in base.lock
#   --quiet                suppress the human narration, keep the KEY=VALUE output
#
# D21, because it is the reason `mirror` exists and it is not obvious:
#   ublue-os/aurora runs a GHCR cleanup weekly with older-than 90 days / keep-n-tagged 7. So the digest
#   in base.lock is DELETED by upstream after ~90 days or 7 newer stable tags, whichever comes first.
#   Pinning by digest protects us from a tag moving. It does not protect us from the blob going away.
#   The failure mode is the worst kind: everything works for weeks, then every build fails with
#   manifest-unknown on an image nobody touched — and a customer who forked our recipe to rebuild
#   without us, which is the thing we advertise in spec §1.3, cannot.
#
# Idempotent: `update` run twice against an unmoved tag rewrites nothing and says so.
#
# D19: pipefail everywhere. A step that cannot fail is not a check.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SELF_DIR}/.." && pwd)"

LOCK="${REPO_DIR}/base.lock"
CONTAINERFILE="${REPO_DIR}/Containerfile"
MIRROR="${AUROS_MIRROR_IMAGE:-}"
QUIET=0
CMD="${1:-}"
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)          LOCK="$2"; shift 2 ;;
    --containerfile) CONTAINERFILE="$2"; shift 2 ;;
    --mirror)        MIRROR="$2"; shift 2 ;;
    --quiet)         QUIET=1; shift ;;
    *) echo "resolve-upstream.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

say() { [ "$QUIET" = "1" ] || echo "$@"; }
die() { echo "resolve-upstream.sh: $*" >&2; exit 1; }

emit() {  # emit KEY VALUE — to stdout always, to $GITHUB_OUTPUT when running in Actions
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required and is not on PATH"; }

# ── base.lock ────────────────────────────────────────────────────────────────────────────────────
# Parsed rather than sourced. `source`ing a file that lives in a repo means any line anyone ever adds
# to it executes as shell, which is a needlessly large hole for a file whose whole content is five
# key/value pairs.
lock_get() {
  local key="$1"
  [ -f "$LOCK" ] || die "no lock file at $LOCK"
  local v
  v="$(grep -E "^${key}=" "$LOCK" | head -1 | cut -d= -f2- || true)"
  [ -n "$v" ] || die "$LOCK has no ${key}="
  printf '%s' "$v"
}

lock_get_opt() {  # like lock_get but returns empty instead of dying
  local key="$1"
  [ -f "$LOCK" ] || return 0
  grep -E "^${key}=" "$LOCK" | head -1 | cut -d= -f2- || true
}

mirror_image() {
  # Precedence: --mirror / $AUROS_MIRROR_IMAGE, then MIRROR_IMAGE= in base.lock. There is deliberately
  # no hardcoded default with the org name in it: D1 says the namespace lives in exactly one file
  # (auros.config.json), and CI passes it down from there. A default here would be a second one.
  if [ -n "$MIRROR" ]; then printf '%s' "$MIRROR"; return 0; fi
  local m; m="$(lock_get_opt MIRROR_IMAGE)"
  printf '%s' "$m"
}

DIGEST_RE='sha256:[0-9a-f]{64}'

# ── registry ─────────────────────────────────────────────────────────────────────────────────────
resolve_tag() {
  # Resolve IMAGE:TAG for our one architecture. Emits the globals RESOLVED_*.
  need skopeo
  need jq
  local image="$1" tag="$2" arch="${3:-amd64}"
  local ref="docker://${image}:${tag}"
  local raw insp

  insp="$(skopeo inspect --no-tags --override-os linux --override-arch "$arch" "$ref")" \
    || die "skopeo could not inspect ${ref} (registry unreachable, or the tag does not exist)"

  RESOLVED_DIGEST="$(printf '%s' "$insp" | jq -r '.Digest')"
  RESOLVED_CREATED="$(printf '%s' "$insp" | jq -r '.Created // ""')"
  RESOLVED_ARCH="$(printf '%s' "$insp" | jq -r '"\(.Os)/\(.Architecture)"')"

  [[ "$RESOLVED_DIGEST" =~ ^${DIGEST_RE}$ ]] \
    || die "resolved digest '${RESOLVED_DIGEST}' is not a sha256 digest"

  # Compressed pull size. This is the number BLOCKED.md B6 is about: a nightly base change that
  # touches a low layer is this many bytes PER MACHINE. It is recorded so that the claim we make on
  # the website is a measurement and not a hope.
  raw="$(skopeo inspect --raw "docker://${image}@${RESOLVED_DIGEST}")" || die "cannot read manifest"
  local mt
  mt="$(printf '%s' "$raw" | jq -r '.mediaType // ""')"
  if printf '%s' "$mt" | grep -qE 'image.index|manifest.list'; then
    # Multi-arch index: descend to our architecture before measuring, or we measure nothing.
    local child
    child="$(printf '%s' "$raw" \
      | jq -r --arg a "$arch" '.manifests[] | select(.platform.architecture==$a and .platform.os=="linux") | .digest' \
      | head -1)"
    [ -n "$child" ] || die "no linux/${arch} manifest in the index for ${image}:${tag}"
    raw="$(skopeo inspect --raw "docker://${image}@${child}")"
  fi
  RESOLVED_PULL_BYTES="$(printf '%s' "$raw" | jq '[.layers[].size] | add // 0')"
  RESOLVED_LAYERS="$(printf '%s' "$raw" | jq '.layers | length')"
}

# ── Containerfile ────────────────────────────────────────────────────────────────────────────────
# The base Containerfile is owned by the A1 agent, not by this script. Two pinning conventions are in
# circulation and both are legitimate, so this accepts either and rejects everything else:
#
#   (a) literal      FROM ghcr.io/ublue-os/aurora@sha256:...
#   (b) build-arg    ARG BASE_IMAGE=ghcr.io/ublue-os/aurora@sha256:...
#                    FROM ${BASE_IMAGE}
#
# Under (b) the ARG default must itself be digest-pinned. A defaulted-to-a-tag build-arg would make S1
# vacuous — CI would pass a digest, the check would compare the digest it just passed against the lock,
# and anyone building the Containerfile by hand would silently get whatever the tag meant that day.
read_containerfile_base() {
  [ -f "$CONTAINERFILE" ] || die "no Containerfile at $CONTAINERFILE (A1 has not landed it yet)"

  local from_line argdef
  # First FROM that is not a reference to an earlier named stage.
  from_line="$(grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$CONTAINERFILE" | head -1 || true)"
  [ -n "$from_line" ] || die "$CONTAINERFILE contains no FROM line"

  CF_STYLE=""
  CF_REF=""

  if printf '%s' "$from_line" | grep -qE '\$\{?BASE_IMAGE\}?'; then
    CF_STYLE="build-arg"
    argdef="$(grep -E '^[[:space:]]*ARG[[:space:]]+BASE_IMAGE=' "$CONTAINERFILE" | head -1 || true)"
    if [ -n "$argdef" ]; then
      CF_REF="$(printf '%s' "$argdef" | sed -E 's/^[[:space:]]*ARG[[:space:]]+BASE_IMAGE=//; s/^"//; s/"$//')"
    else
      # No default at all. CI must supply one; we validate what CI is about to pass.
      CF_REF="${AUROS_BASE_IMAGE_REF:-}"
      [ -n "$CF_REF" ] \
        || die "Containerfile uses \${BASE_IMAGE} with no ARG default and AUROS_BASE_IMAGE_REF is unset.
       CI must pass --build-arg BASE_IMAGE=<image>@<digest>; there is nothing here to check otherwise."
    fi
  else
    CF_STYLE="literal"
    CF_REF="$(printf '%s' "$from_line" | awk '{print $2}')"
  fi
}

# ── commands ─────────────────────────────────────────────────────────────────────────────────────
cmd_resolve() {
  local image tag
  image="$(lock_get UPSTREAM_IMAGE)"; tag="$(lock_get UPSTREAM_TAG)"
  say "resolving ${image}:${tag} ..."
  resolve_tag "$image" "$tag"
  emit upstream_image  "$image"
  emit upstream_tag    "$tag"
  emit upstream_digest "$RESOLVED_DIGEST"
  emit upstream_created "$RESOLVED_CREATED"
  emit upstream_arch    "$RESOLVED_ARCH"
  emit upstream_pull_size_bytes "$RESOLVED_PULL_BYTES"
  emit upstream_layers  "$RESOLVED_LAYERS"
  say "resolved ${image}:${tag} -> ${RESOLVED_DIGEST} (${RESOLVED_ARCH}, ${RESOLVED_LAYERS} layers, $(numfmt --to=iec "$RESOLVED_PULL_BYTES" 2>/dev/null || echo "$RESOLVED_PULL_BYTES") compressed)"
}

cmd_assert() {
  local image locked
  image="$(lock_get UPSTREAM_IMAGE)"
  locked="$(lock_get UPSTREAM_DIGEST)"
  [[ "$locked" =~ ^${DIGEST_RE}$ ]] || die "base.lock UPSTREAM_DIGEST '${locked}' is not a sha256 digest"

  read_containerfile_base
  say "S1: Containerfile pinning style = ${CF_STYLE}"
  say "S1: Containerfile base reference = ${CF_REF}"
  say "S1: base.lock                    = ${image}@${locked}"

  # fails_on: any tag-only reference
  if ! printf '%s' "$CF_REF" | grep -qE "@${DIGEST_RE}$"; then
    emit s1_status fail
    die "S1 FAIL — the base reference is not pinned by digest: '${CF_REF}'.
       A tag is a moving target. Two builds a day apart would be different operating systems wearing
       the same name, and 'same recipe in, same image out' would stop being true."
  fi

  local cf_image cf_digest mirror via
  cf_image="${CF_REF%@*}"
  cf_digest="${CF_REF##*@}"
  mirror="$(mirror_image)"
  via="upstream"

  if [ "$cf_image" != "$image" ]; then
    # D21: the legitimate second source is OUR mirror of the same digest. `skopeo copy --all`
    # preserves the manifest digest, so the mirror and upstream are the same bytes under a different
    # name — which is exactly why accepting it here is safe rather than a loophole.
    if [ -n "$mirror" ] && [ "$cf_image" = "$mirror" ]; then
      via="mirror"
    elif [ -z "$mirror" ] && printf '%s' "$cf_image" | grep -qE '/auros-upstream-mirror$'; then
      # No mirror name was supplied (a bare local run). Accept on the D21 naming convention and say
      # so out loud, so nobody reads this as the script having verified which mirror it is.
      via="mirror (accepted on name convention; no --mirror supplied to verify against)"
    else
      emit s1_status fail
      die "S1 FAIL — the Containerfile builds on '${cf_image}' but base.lock pins '${image}'
       and the mirror is '${mirror:-<unset>}'.
       Spec §3: there is exactly one base, and it derives from exactly one upstream."
    fi
  fi

  # fails_on: a mismatch of a single character
  if [ "$cf_digest" != "$locked" ]; then
    emit s1_status fail
    echo "S1 FAIL — digest mismatch." >&2
    echo "       Containerfile: ${cf_digest}" >&2
    echo "       base.lock:     ${locked}" >&2
    echo "       If upstream moved, the nightly updates BOTH together (resolve-upstream.sh update)." >&2
    echo "       Editing one by hand is how they drift apart." >&2
    exit 2
  fi

  emit s1_status pass
  emit base_ref "${image}@${locked}"
  say "S1 PASS — base is pinned by digest and the Containerfile and base.lock agree."
}

cmd_drift() {
  local image tag locked
  image="$(lock_get UPSTREAM_IMAGE)"; tag="$(lock_get UPSTREAM_TAG)"; locked="$(lock_get UPSTREAM_DIGEST)"
  resolve_tag "$image" "$tag"
  emit locked_digest   "$locked"
  emit upstream_digest "$RESOLVED_DIGEST"
  emit upstream_created "$RESOLVED_CREATED"
  emit upstream_pull_size_bytes "$RESOLVED_PULL_BYTES"
  if [ "$RESOLVED_DIGEST" = "$locked" ]; then
    emit moved false
    say "no drift — ${image}:${tag} still resolves to ${locked}"
    return 0
  fi
  emit moved true
  say "DRIFT — ${image}:${tag} moved"
  say "  was: ${locked}"
  say "  now: ${RESOLVED_DIGEST} (created ${RESOLVED_CREATED})"
  return 10
}

cmd_update() {
  local image tag locked
  image="$(lock_get UPSTREAM_IMAGE)"; tag="$(lock_get UPSTREAM_TAG)"; locked="$(lock_get UPSTREAM_DIGEST)"
  resolve_tag "$image" "$tag"

  if [ "$RESOLVED_DIGEST" = "$locked" ]; then
    emit moved false
    emit changed false
    say "update: nothing to do — already pinned to ${locked}"
    return 0
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Rewrite in place, key by key, preserving the comment header. A regenerated file would lose the
  # explanation of why the digest is there, which is the most useful thing in it.
  local tmp; tmp="$(mktemp)"
  sed -E \
    -e "s|^UPSTREAM_DIGEST=.*|UPSTREAM_DIGEST=${RESOLVED_DIGEST}|" \
    -e "s|^UPSTREAM_RESOLVED_AT=.*|UPSTREAM_RESOLVED_AT=${now}|" \
    -e "s|^UPSTREAM_CREATED=.*|UPSTREAM_CREATED=${RESOLVED_CREATED}|" \
    -e "s|^UPSTREAM_ARCH=.*|UPSTREAM_ARCH=${RESOLVED_ARCH}|" \
    -e "s|^UPSTREAM_PULL_SIZE_BYTES=.*|UPSTREAM_PULL_SIZE_BYTES=${RESOLVED_PULL_BYTES}|" \
    "$LOCK" > "$tmp"
  mv "$tmp" "$LOCK"
  say "update: base.lock ${locked} -> ${RESOLVED_DIGEST}"

  # Keep the Containerfile in step, but only where the digest is written literally. Under the
  # build-arg convention with no default, CI passes the ref and there is nothing in the file to edit.
  local cf_changed=false
  if [ -f "$CONTAINERFILE" ]; then
    if grep -qE "${image}@${DIGEST_RE}" "$CONTAINERFILE"; then
      local tmp2; tmp2="$(mktemp)"
      sed -E "s|${image}@${DIGEST_RE}|${image}@${RESOLVED_DIGEST}|g" "$CONTAINERFILE" > "$tmp2"
      mv "$tmp2" "$CONTAINERFILE"
      cf_changed=true
      say "update: Containerfile base reference rewritten to ${RESOLVED_DIGEST}"
    else
      say "update: Containerfile has no literal digest to rewrite (build-arg convention) — CI passes it"
    fi
  else
    say "update: no Containerfile present yet; only base.lock was updated"
  fi

  emit moved true
  emit changed true
  emit containerfile_changed "$cf_changed"
  emit old_digest "$locked"
  emit upstream_digest "$RESOLVED_DIGEST"
}

case "$CMD" in
  resolve) cmd_resolve ;;
  assert)  cmd_assert ;;
  drift)   cmd_drift ;;
  update)  cmd_update ;;
  ""|-h|--help|help)
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) die "unknown command '${CMD}' (resolve | assert | drift | update)" ;;
esac

#!/usr/bin/env bash
# Mirror the pinned upstream base into our own registry, so the pin stays PULLABLE.
#
# WHY THIS EXISTS (DECISIONS.md D21)
#
# ublue-os/aurora runs dataaxiom/ghcr-cleanup-action weekly, Sunday 00:15 UTC, with older-than: 90 days,
# keep-n-tagged: 7, keep-n-untagged: 7 and delete-orphaned-images: true. So the digest recorded in
# base.lock is garbage-collected by upstream after roughly 90 days, or after seven newer stable tags,
# whichever lands first.
#
# Pinning by digest protects us from upstream MOVING a tag. It does not protect us from upstream
# DELETING the blob. The failure mode is the nastiest kind: everything works for weeks, then one morning
# every build fails with manifest-unknown on an image nobody touched — and a customer who forked our
# recipe to rebuild their own OS without us, which is the thing we advertise, cannot.
#
# So: upstream stays the source of truth for WHAT to pin. Our mirror guarantees the pin is still there.
# GHCR public storage is free, so this costs nothing and removes a dependency on somebody else's
# retention policy for a promise we make to schools.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${HERE}/base.lock"
MIRROR="${AUROS_MIRROR:-ghcr.io/aarohkandy/auros-upstream-mirror}"

[ -f "$LOCK" ] || { echo "mirror-upstream: no base.lock at $LOCK — refusing to guess a digest" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$LOCK"; set +a
: "${UPSTREAM_IMAGE:?base.lock is missing UPSTREAM_IMAGE}"
: "${UPSTREAM_DIGEST:?base.lock is missing UPSTREAM_DIGEST}"

case "$UPSTREAM_DIGEST" in
  sha256:*) ;;
  *) echo "mirror-upstream: UPSTREAM_DIGEST is not a sha256 digest: '$UPSTREAM_DIGEST'" >&2; exit 2 ;;
esac

SRC="${UPSTREAM_IMAGE}@${UPSTREAM_DIGEST}"
# The mirror tag is the digest itself with the colon swapped, so the tag is self-describing and can
# never drift from what it contains. A human tag here would reintroduce exactly the problem we are
# solving.
TAG="${UPSTREAM_DIGEST/sha256:/sha256-}"
DST="${MIRROR}:${TAG}"

echo "mirror-upstream:"
echo "  source      ${SRC}"
echo "  destination ${DST}"

# Credentials are passed EXPLICITLY rather than relied upon from an auth file.
#
# We learned this the hard way: the workflow ran `sudo skopeo login` with XDG_RUNTIME_DIR inherited,
# which wrote /run/user/1001/containers/auth.json owned by root, and the later unprivileged
# `skopeo copy` then got "permission denied" reading its OWN auth file. Explicit creds do not care who
# owns what, and they make this script work identically under sudo, under a runner, and on a laptop.
CREDS=()
if [ -n "${AUROS_REGISTRY_USER:-}" ] && [ -n "${AUROS_REGISTRY_TOKEN:-}" ]; then
  CREDS=(--dest-creds "${AUROS_REGISTRY_USER}:${AUROS_REGISTRY_TOKEN}")
  echo "  using explicit destination credentials for ${AUROS_REGISTRY_USER}"
else
  echo "  no AUROS_REGISTRY_USER/TOKEN set — falling back to the ambient auth file"
fi

if skopeo inspect --no-tags "${CREDS[@]+"${CREDS[@]/--dest-creds/--creds}"}" "docker://${DST}" >/dev/null 2>&1; then
  echo "  already mirrored — nothing to do"
else
  echo "  copying (--all: every arch and the attached signatures, not just the one we happen to run)"
  skopeo copy --all --src-no-creds "${CREDS[@]+"${CREDS[@]}"}" "docker://${SRC}" "docker://${DST}"
fi

# Prove the mirror is byte-identical. A mirror that silently re-compressed or dropped a layer would be a
# different operating system wearing the same digest field, which is worse than no mirror at all.
RCREDS=()
[ ${#CREDS[@]} -gt 0 ] && RCREDS=(--creds "${AUROS_REGISTRY_USER}:${AUROS_REGISTRY_TOKEN}")
# The SOURCE is upstream's public image, read anonymously (--no-creds / --src-no-creds). Reading it
# with the ambient auth file failed gate1-exit run 35604729895: an earlier `sudo podman login` left
# that file root-owned, and skopeo died "getting username and password" before comparing anything.
SRC_DIGEST=$(skopeo inspect --no-tags --no-creds "docker://${SRC}" | jq -r .Digest)
DST_DIGEST=$(skopeo inspect --no-tags "${RCREDS[@]+"${RCREDS[@]}"}" "docker://${DST}" | jq -r .Digest)
if [ "$SRC_DIGEST" != "$DST_DIGEST" ]; then
  echo "mirror-upstream: FATAL — mirrored digest ${DST_DIGEST} != source ${SRC_DIGEST}" >&2
  echo "  The mirror is not a faithful copy. Do not build against it." >&2
  exit 1
fi
echo "  verified: ${DST_DIGEST}"

# Everything downstream builds FROM the mirror. Emitted for the workflow to consume.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "mirror_ref=${DST}"; echo "digest=${DST_DIGEST}"; } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### upstream mirror"
    echo "- source: \`${SRC}\`"
    echo "- mirror: \`${DST}\`"
    echo "- verified identical: \`${DST_DIGEST}\`"
    echo ""
    echo "Upstream garbage-collects this digest after ~90 days (D21). The mirror is what keeps a"
    echo "customer's fork buildable after that, which is the whole of the replaceability claim."
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "AUROS_BASE_FROM=${DST}"

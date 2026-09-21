#!/usr/bin/env bash
# tools/signing-key.sh — which key signs this build, and whether the built image may be published.
#
#   prepare OUT            write the cosign private key for this build to OUT, and say which kind it is
#   publish-check KIND PUB refuse unless the image is provably production-keyed
#
# Run from the repo root (build.yml does). Tested by tests/signing-key.test.sh.
#
# ── prepare ──────────────────────────────────────────────────────────────────────────────────────
# D32. The key is chosen by the SAME rule build/30-update-agent.sh uses to decide which public key
# goes into the image at /usr/lib/pki/containers/auros.pub (the policy's keyPath): production if
# signing/keys/auros.pub is committed and non-empty, else signing/keys/auros-development.pub. Signing
# with any other key makes a valid signature every machine refuses, so there is NO fallback across
# kinds: a committed production key with a missing COSIGN_PRIVATE_KEY is an error, not a reason to
# sign with the development key.
#
#   production   secret COSIGN_PRIVATE_KEY    (cosign generate-key-pair format, COSIGN_PASSWORD)
#   development  secret AUROS_DEV_SIGNING_KEY (made with `openssl ecparam`, DEVELOPMENT-KEY.md —
#                                              a plain PEM with no password)
#
# cosign 2.6.5 `sign --key` accepts ONLY its own encrypted PEM (pkg/cosign/keys.go LoadPrivateKey:
# "unsupported pem type" for anything else), so a plain PEM is converted with `cosign import-key-pair`,
# encrypted under whatever COSIGN_PASSWORD this job has (empty is fine: cosign takes a SET-but-empty
# COSIGN_PASSWORD as the password). The same job then signs with that same COSIGN_PASSWORD.
#
# ── publish-check ────────────────────────────────────────────────────────────────────────────────
# KIND and PUB are /usr/lib/auros/signing-key-kind and /usr/lib/pki/containers/auros.pub, copied out
# of the built image. The kind file alone is a filename test (SYSTEM-REVIEW §2.14: gate1-exit.yml
# copies a throwaway key over auros.pub and gets kind=production). So the KEY ITSELF is also checked:
# it must not be the development key (fingerprint pinned below, from DEVELOPMENT-KEY.md) and it must
# be the production key committed in this checkout.
set -euo pipefail

DEV_FP=1495cbe4f1a3fc46c082c34098fa3d0b04c6c35ce3c8381f87f04ee08202500b
PROD_PUB=signing/keys/auros.pub
DEV_PUB=signing/keys/auros-development.pub

die() { echo "::error::$*" >&2; exit 1; }
# SHA-256 of the DER public key — the fingerprint DEVELOPMENT-KEY.md records.
fp() { grep -q 'BEGIN PUBLIC KEY' "$1" || return 1; sed '/-----/d' "$1" | base64 -d | sha256sum | cut -d' ' -f1; }
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; echo "$1"; }

prepare() {
  local dest="${1:?usage: prepare OUT}" kind pub secret raw type
  if [ -s "$PROD_PUB" ]; then
    kind=production pub=$PROD_PUB secret=${COSIGN_PRIVATE_KEY:-}
    [ -n "$secret" ] || die "$PROD_PUB is committed, so the image trusts the PRODUCTION key, but COSIGN_PRIVATE_KEY is not set. Not falling back to the development key: every machine would refuse the result."
  elif [ -s "$DEV_PUB" ]; then
    kind=development pub=$DEV_PUB secret=${AUROS_DEV_SIGNING_KEY:-}
    [ -n "$secret" ] || die "no production key is committed, so the image trusts $DEV_PUB, but AUROS_DEV_SIGNING_KEY is not set (D32, signing/keys/DEVELOPMENT-KEY.md)."
  else
    die "neither $PROD_PUB nor $DEV_PUB exists. build/30-update-agent.sh should already have refused the build."
  fi

  export COSIGN_PASSWORD="${COSIGN_PASSWORD-}"
  umask 077
  raw="$dest.in"
  # Only the private-key block: `openssl ecparam -genkey` puts an EC PARAMETERS block first, and
  # cosign reads only the first block.
  printf '%s\n' "$secret" | sed -n '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/p' > "$raw"
  type="$(sed -n 's/^-----BEGIN \(.*\)-----$/\1/p' "$raw" | head -1)"
  case "$type" in
    "ENCRYPTED SIGSTORE PRIVATE KEY"|"ENCRYPTED COSIGN PRIVATE KEY") mv "$raw" "$dest" ;;
    "EC PRIVATE KEY"|"PRIVATE KEY"|"RSA PRIVATE KEY")
      cosign import-key-pair --key "$raw" --output-key-prefix "$dest.import" --yes >/dev/null 2>&1 \
        || { rm -f "$raw" "$dest.import".*; die "cosign import-key-pair refused the $kind key (a $type PEM)."; }
      mv "$dest.import.key" "$dest"; rm -f "$raw" "$dest.import.pub" ;;
    *) rm -f "$raw"; die "the $kind signing secret holds no PEM private key (first block: '${type:-none}')." ;;
  esac

  # Prove the private key matches the public key baked into the image BEFORE anything is signed.
  # A wrong key makes a valid signature that every customer machine rejects, and S8 still passes.
  local derived; derived="$(mktemp)"
  cosign public-key --key "$dest" > "$derived" 2>/dev/null || { rm -f "$derived"; die "cosign could not read the prepared $kind key (wrong COSIGN_PASSWORD?)."; }
  if [ "$(fp "$derived" || true)" != "$(fp "$pub")" ]; then
    rm -f "$derived" "$dest"; die "the $kind private key does not match $pub, the key the image ships. Every image signed with it would be refused."
  fi
  rm -f "$derived"
  out "kind=$kind"
  out "pub=$pub"
}

publish_check() {
  local kindf="${1:?usage: publish-check KIND_FILE PUB_FILE}" pubf="${2:?usage: publish-check KIND_FILE PUB_FILE}" kind got
  kind="$(tr -d '[:space:]' < "$kindf" 2>/dev/null || true)"
  case "$kind" in
    production) ;;
    development) die "REFUSING TO PUBLISH. This image was built with the DEVELOPMENT signing key. It built, booted and passed the matrix — that is what the development key is for. To publish: a human generates a production key pair, commits the public half as $PROD_PUB and sets COSIGN_PRIVATE_KEY and COSIGN_PASSWORD (signing/keys/README.md, BLOCKED.md B10)." ;;
    "") die "the image carries no /usr/lib/auros/signing-key-kind. An image that cannot say which key signed it is not one to publish." ;;
    *) die "unrecognised signing key kind '$kind'. Failing closed." ;;
  esac
  got="$(fp "$pubf" || true)"
  [ -n "$got" ] || die "the image's /usr/lib/pki/containers/auros.pub is missing or not a PEM public key."
  [ "$got" != "$DEV_FP" ] || die "REFUSING TO PUBLISH. The image says 'production' but ships the DEVELOPMENT key (fingerprint $DEV_FP). The kind file is a filename test; the key is not."
  [ -s "$PROD_PUB" ] || die "the image says 'production' but no $PROD_PUB is committed, so its key ($got) is not one we hold."
  [ "$got" = "$(fp "$PROD_PUB" || true)" ] || die "the image's key ($got) is not the production key committed at $PROD_PUB. Refusing."
  echo "signing key: production, fingerprint $got, matches $PROD_PUB — publish permitted"
}

case "${1:-}" in
  prepare) shift; prepare "$@" ;;
  publish-check) shift; publish_check "$@" ;;
  *) echo "usage: $0 prepare OUT | publish-check KIND_FILE PUB_FILE" >&2; exit 2 ;;
esac

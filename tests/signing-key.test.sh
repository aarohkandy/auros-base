#!/usr/bin/env bash
# tools/signing-key.sh — which key signs (D32), and the publish refusal of a development-keyed image.
#
# cosign is a stub on PATH. The keys are fake PEMs carrying a marker line, except the development
# PUBLIC key, which is the real committed one, so the pinned fingerprint is tested against the real
# bytes. No private key is generated anywhere in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

SCRIPT="$REPO/tools/signing-key.sh"
WF="$REPO/.github/workflows/build.yml"

pem() { printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "$1" "$2" "$1"; }
# A fake public key: any base64 body is a "DER" as far as the fingerprint is concerned.
PROD_PUB="$(pem 'PUBLIC KEY' "$(printf 'fake production key' | base64)")"
OTHER_PUB="$(pem 'PUBLIC KEY' "$(printf 'gate1-exit throwaway key' | base64)")"
# Plain PEMs as `openssl ecparam -genkey` writes them (EC PARAMETERS block first), and cosign's own.
DEV_RAW="$(pem 'EC PARAMETERS' BggqhkjOPQMBBw==; pem 'EC PRIVATE KEY' marker=dev)"
PROD_ENC="$(pem 'ENCRYPTED SIGSTORE PRIVATE KEY' marker=prod)"

# ctx [prod] — a scratch checkout with the real dev pub, optionally a committed production pub, and a
# cosign stub. The stub models what matters: import only takes a plain PEM, needs COSIGN_PASSWORD SET
# (it would prompt otherwise), and `sign --key`/`public-key` read only cosign's encrypted format.
ctx() {
  local d; newroot >/dev/null; d="${T_TMPDIRS[${#T_TMPDIRS[@]}-1]}"
  mkdir -p "$d/signing/keys" "$d/bin" "$d/fix"
  cp "$REPO/signing/keys/auros-development.pub" "$d/signing/keys/"
  [ "${1:-}" = prod ] && printf '%s\n' "$PROD_PUB" > "$d/signing/keys/auros.pub"
  cp "$REPO/signing/keys/auros-development.pub" "$d/fix/dev.pub"; printf '%s\n' "$PROD_PUB" > "$d/fix/prod.pub"
  cat > "$d/bin/cosign" <<SH
#!/usr/bin/env bash
[ "\${COSIGN_PASSWORD+set}" = set ] || { echo "no COSIGN_PASSWORD: would prompt" >&2; exit 1; }
arg() { local k=\$1; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$k" ] && { echo "\$2"; return; }; shift; done; }
case "\$1" in
  import-key-pair)
    k=\$(arg --key "\$@"); o=\$(arg --output-key-prefix "\$@")
    grep -q ENCRYPTED <<<"\$(head -1 "\$k")" && { echo "unsupported" >&2; exit 1; }
    m=\$(grep marker= "\$k"); printf -- '-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\n%s\n-----END ENCRYPTED SIGSTORE PRIVATE KEY-----\n' "\$m" > "\$o.key"
    echo pub > "\$o.pub" ;;
  public-key)
    k=\$(arg --key "\$@")
    grep -q 'BEGIN ENCRYPTED SIGSTORE PRIVATE KEY' <<<"\$(head -1 "\$k")" || { echo "unsupported pem type" >&2; exit 1; }
    m=\$(sed -n 's/^marker=//p' "\$k"); cat "$d/fix/\$m.pub" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/bin/cosign"
  D="$d"
}
# prep <env assignments...> — run `prepare` in the scratch checkout with only the named secrets set.
prep() { (cd "$D" && env -u COSIGN_PRIVATE_KEY -u AUROS_DEV_SIGNING_KEY -u COSIGN_PASSWORD \
  PATH="$D/bin:$PATH" GITHUB_OUTPUT="$D/out" "$@" bash "$SCRIPT" prepare "$D/key"); }
pubcheck() { (cd "$D" && bash "$SCRIPT" publish-check "$D/img.kind" "$D/img.pub"); }
image() { printf '%s\n' "$1" > "$D/img.kind"; printf '%s\n' "$2" > "$D/img.pub"; }

# What 30-update-agent.sh would put at /usr/lib/pki/containers/auros.pub in this checkout — extracted
# from the shipping script, so the two rules cannot drift apart unnoticed.
KEYSEL="$(extract_between "$REPO/build/30-update-agent.sh" '^KEY_SRC="\$SIGN/keys/auros.pub"' '^fi$')"
image_key() { SIGN="$D/signing" bash -c "warn() { :; }; $KEYSEL"'
echo "${KEY_SRC#$SIGN/}"'; }

group "dev-key-signs — no production key committed"
ctx
run_check dev-signs green "dev secret only → prepared" -- prep AUROS_DEV_SIGNING_KEY="$DEV_RAW"
assert_has "kind=development" "kind=development" "$(cat "$D/out")"
assert_has "a cosign-format key, converted from the openssl PEM" "BEGIN ENCRYPTED SIGSTORE PRIVATE KEY" "$(cat "$D/key")"
assert_has "the key it verifies with is the one 30-update-agent.sh ships" "pub=signing/$(image_key)" "$(cat "$D/out")"
assert_nofile "no plaintext copy of the secret left behind" "$D/key.in"
run_check dev-signs green "…and a set COSIGN_PASSWORD (the production secret) changes nothing" -- \
  prep AUROS_DEV_SIGNING_KEY="$DEV_RAW" COSIGN_PASSWORD=whatever
ctx
run_check dev-signs red "no AUROS_DEV_SIGNING_KEY → refused" -- prep
assert_has "…saying which secret" "AUROS_DEV_SIGNING_KEY is not set" "$T_LAST_OUT"
run_check dev-signs red "production secret only, no auros.pub → refused (image trusts the dev key)" -- \
  prep COSIGN_PRIVATE_KEY="$PROD_ENC"
run_check dev-signs red "dev secret holding the WRONG key → refused before signing" -- \
  prep AUROS_DEV_SIGNING_KEY="$(pem 'EC PRIVATE KEY' marker=prod)"
assert_has "…as a mismatch" "does not match signing/keys/auros-development.pub" "$T_LAST_OUT"
assert_nofile "…and the key file is removed" "$D/key"
run_check dev-signs red "dev secret that is not a PEM → refused" -- prep AUROS_DEV_SIGNING_KEY=garbage

group "production-key-signs — auros.pub committed"
ctx prod
run_check prod-signs green "COSIGN_PRIVATE_KEY (cosign format) → prepared as-is" -- \
  prep COSIGN_PRIVATE_KEY="$PROD_ENC" COSIGN_PASSWORD=pw
assert_has "kind=production" "kind=production" "$(cat "$D/out")"
assert_has "pub=signing/keys/auros.pub" "pub=signing/keys/auros.pub" "$(cat "$D/out")"
assert_has "…which is the key 30-update-agent.sh ships" "pub=signing/$(image_key)" "$(cat "$D/out")"
ctx prod
run_check prod-signs red "auros.pub committed, only the DEV secret → no fallback, refused" -- \
  prep AUROS_DEV_SIGNING_KEY="$DEV_RAW"
assert_has "…saying so" "Not falling back" "$T_LAST_OUT"
run_check prod-signs red "production secret for a different key → refused" -- \
  prep COSIGN_PRIVATE_KEY="$(pem 'ENCRYPTED SIGSTORE PRIVATE KEY' marker=dev)" COSIGN_PASSWORD=pw

group "publish-refuses-dev-key — judged from the image's own files"
ctx prod
image production "$PROD_PUB"
run_check publish green "kind=production, key = committed auros.pub → permitted" -- pubcheck
image development "$(cat "$REPO/signing/keys/auros-development.pub")"
run_check publish red "kind=development → refused" -- pubcheck
assert_has "…as a development-key refusal" "DEVELOPMENT signing key" "$T_LAST_OUT"
image development "$PROD_PUB"
run_check publish red "kind=development even with the production key in it → refused on the kind alone" -- pubcheck
image production "$(cat "$REPO/signing/keys/auros-development.pub")"
run_check publish red "kind file says production, key is the dev key (SYSTEM-REVIEW §2.14) → refused" -- pubcheck
assert_has "…by the pinned fingerprint" "1495cbe4f1a3fc46c082c34098fa3d0b04c6c35ce3c8381f87f04ee08202500b" "$T_LAST_OUT"
printf '%s\n' "$(cat "$REPO/signing/keys/auros-development.pub")" > "$D/signing/keys/auros.pub"
run_check publish red "dev key COMMITTED as auros.pub (image says production, key matches the repo) → only the pin refuses" -- pubcheck
assert_has "…by the pinned fingerprint" "ships the DEVELOPMENT key" "$T_LAST_OUT"
printf '%s\n' "$PROD_PUB" > "$D/signing/keys/auros.pub"
image production "$OTHER_PUB"
run_check publish red "kind production, a key nobody committed (the gate1-exit bypass) → refused" -- pubcheck
image "" "$PROD_PUB"
run_check publish red "no kind file content → refused" -- pubcheck
image production ""
run_check publish red "no public key in the image → refused" -- pubcheck
ctx
image production "$PROD_PUB"
run_check publish red "no auros.pub committed at all → refused" -- pubcheck

group "build.yml actually calls it"
assert_eq "sign and update jobs prepare the key with it" 2 "$(grep -c 'tools/signing-key.sh prepare' "$WF")"
assert_eq "publish checks with it" 1 "$(grep -c 'tools/signing-key.sh publish-check' "$WF")"
assert_eq "the dev secret is wired into sign and update" 2 "$(grep -c 'secrets.AUROS_DEV_SIGNING_KEY' "$WF")"

t_finish signing-key.test.sh

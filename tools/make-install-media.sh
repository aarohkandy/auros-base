#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# make-install-media.sh — the ONLY supported way to turn a published image into install media.
#
#   tools/make-install-media.sh ghcr.io/<org>/<repo>@sha256:<64 hex> [--enrolment FILE] [--out DIR]
#
# SYSTEM-REVIEW §2.15 / H9 / C8: the person holding the USB stick used to choose which bytes boot on a
# school laptop by typing an image reference. A tag, a staging ref or a local build all produced a
# bootable disk with no ledger lookup and no signature check. This script is the fifth layer that
# attest/README.md's four cannot be extended into. In order, and every step is a refusal unless it
# positively passes:
#
#   1. the reference is ghcr.io/<org>/<repo>@sha256:<digest> — a tag is refused, not resolved
#   2. the control repo's gate says the digest has a FULL recorded pass:
#        node <control-repo>/tools/gate.mjs <digest> --image ghcr.io/<org>/<repo>
#      (the one CLI form build.yml uses; exit 0 = allow, 1 = refused, 2 = undecided — both refusals)
#      and the ledger and gate it consulted are unmodified from their commit
#   3. a PRODUCTION public key exists at signing/keys/auros.pub (the key the image's policy.json
#      trusts) and it is not the development key. There is no dev-key path; see signing/keys/README.md
#   4. `cosign verify --key signing/keys/auros.pub <ref>` passes — the same call as check S8
#   5. bootc-image-builder is pinned by digest in bib.lock
#   6. the enrolment file (owner decision A1, control repo docs/ACCOUNTS.md): an image that declares
#      accounts (/usr/lib/auros/accounts.json) needs --enrolment FILE, or every laptop it installs
#      boots with nobody able to sign in. FILE is tools/make-enrolment.sh's output: root-only (0600 or
#      0400), `name:<crypt(3) hash>` lines, names the image declares, at least one admin. A plain
#      password in it is refused, not hashed: this script never holds a password at all.
#   then: podman pull <ref>, bib --type anaconda-iso, copy the .iso to --out.
#
# With --enrolment the ISO carries the hashes in its kickstart (bib's [customizations.installer.
# kickstart]); a %post writes them, 0600, to /etc/auros/enrolment/accounts.secret on the laptop, where
# auros-accounts.service reads and deletes them on first boot. bib adds only `ostreecontainer` to a
# kickstart it is given (its README), so the kickstart below also carries the unattended-install
# commands. THAT ISO IS A PER-SCHOOL SECRET: anyone holding the stick holds the hashes.
#
# IT NEVER WRITES TO A BLOCK DEVICE. It produces a file and prints the one command a human runs, on a
# Linux machine (D13), with the device left as a placeholder they have to fill in themselves.
#
# Control repo: $AUROS_CONTROL_REPO, default the directory above auros-base (the /Users/…/auros layout).
# Needs: git, node, cosign, podman (rootful — bib mounts /var/lib/containers/storage; run with sudo).
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$HERE/.." && pwd)"
CTL="${AUROS_CONTROL_REPO:-$(dirname "$BASE")}"
KEY="$BASE/signing/keys/auros.pub"
DEVKEY="$BASE/signing/keys/auros-development.pub"
OUT="$PWD/install-media"

refuse() { printf 'make-install-media: REFUSED — %s\n' "$*" >&2; exit 1; }
say()    { printf 'make-install-media: %s\n' "$*" >&2; }

REF=''; ENROL=''
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || refuse "--out needs a directory"; OUT="$2"; shift 2 ;;
    --enrolment) [ $# -ge 2 ] || refuse "--enrolment needs a file"; ENROL="$2"; shift 2 ;;
    -*)    refuse "unknown argument '$1'. There are no flags that skip a check." ;;
    *)     [ -z "$REF" ] || refuse "one image reference only (got '$REF' and '$1')"; REF="$1"; shift ;;
  esac
done
case "$OUT" in /dev|/dev/*) refuse "--out $OUT is under /dev. This script writes a FILE, never a device." ;; esac
[ -n "$REF" ] || refuse "usage: make-install-media.sh ghcr.io/<org>/<repo>@sha256:<digest> [--enrolment FILE] [--out DIR]"

# ── 6a. the enrolment file's own shape, before anything slow runs ────────────────────────────────
# Nothing from it is ever printed: a refusal names the line number, never the line.
ENROL_NAMES=''
if [ -n "$ENROL" ]; then
  [ -f "$ENROL" ] && [ -r "$ENROL" ] || refuse "--enrolment $ENROL is not a readable file"
  perm="$(stat -c %a "$ENROL" 2>/dev/null || stat -f %Lp "$ENROL")"
  case "$perm" in 600|400) ;; *) refuse "--enrolment $ENROL is mode $perm. It must be 0600 or 0400: it opens every laptop this school owns." ;; esac
  ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in ''|'#'*) continue ;; esac
    n="${line%%:*}"; h="${line#*:}"
    [[ "$line" == *:* && "$n" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] \
      || refuse "--enrolment line $ln is not name:<hash>"
    [[ "$h" =~ ^\$[^:[:space:]]+$ ]] \
      || refuse "--enrolment line $ln is not a crypt(3) hash. A plain password is never put on install media; make the file with tools/make-enrolment.sh."
    ENROL_NAMES+="$n"$'\n'
  done < "$ENROL"
  line=''; h=''
  [ -n "$ENROL_NAMES" ] || refuse "--enrolment $ENROL has no name:<hash> lines"
  [ -z "$(printf '%s' "$ENROL_NAMES" | sort | uniq -d)" ] || refuse "--enrolment names an account twice"
fi

# ── 1. digest-pinned reference, never a tag ──────────────────────────────────────────────────────
NAME_RE='ghcr\.io/[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*'
if [[ ! "$REF" =~ ^${NAME_RE}@sha256:[a-f0-9]{64}$ ]]; then
  case "$REF" in
    *@sha256:*) refuse "'$REF' is not ghcr.io/<org>/<repo>@sha256:<64 lowercase hex>. A tag plus a digest is refused too: what is installed must be named by its digest alone." ;;
    *:*)        refuse "'$REF' is a TAG. A tag is a pointer someone can move; install media is made from a digest the ledger recorded. Look the digest up in attest/passed-digests.tsv." ;;
    *)          refuse "'$REF' is not ghcr.io/<org>/<repo>@sha256:<digest>." ;;
  esac
fi
IMAGE="${REF%@*}"
DIGEST="${REF#*@}"

# ── 2. the ledger ────────────────────────────────────────────────────────────────────────────────
GATE="$CTL/tools/gate.mjs"
LEDGER="$CTL/attest/passed-digests.tsv"
[ -f "$GATE" ] || refuse "no gate at $GATE. Set AUROS_CONTROL_REPO to a checkout of the control repo."
# gate.mjs reads the ledger beside itself, so a locally edited ledger would be believed. Refuse one.
git -C "$CTL" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "$CTL is not a git checkout, so nothing says its ledger is the recorded one."
git -C "$CTL" diff --quiet HEAD -- tools/gate.mjs attest/passed-digests.tsv 2>/dev/null \
  || refuse "tools/gate.mjs or attest/passed-digests.tsv in $CTL has uncommitted changes. The ledger that decides this must be the committed one."
say "gate: $GATE @ $(git -C "$CTL" rev-parse --short HEAD) (ledger $LEDGER)"
set +e; node "$GATE" "$DIGEST" --image "$IMAGE"; grc=$?; set -e
case "$grc" in
  0) ;;
  1) refuse "the publish gate has no full recorded pass for $DIGEST. Untested bytes do not go on a school laptop." ;;
  *) refuse "the gate exited $grc — it could not decide, and a gate that cannot decide has not passed anything." ;;
esac

# ── 3. a production key, and only a production key ───────────────────────────────────────────────
[ -s "$KEY" ] || refuse "no production signing key: $KEY does not exist. Minting it is a human action (signing/keys/README.md). There is no development-key path to install media, on purpose."
norm() { tr -d '[:space:]' < "$1"; }
if [ -f "$DEVKEY" ] && [ "$(norm "$KEY")" = "$(norm "$DEVKEY")" ]; then
  refuse "$KEY is the DEVELOPMENT key (signing/keys/DEVELOPMENT-KEY.md). No customer machine is imaged from a development-signed image."
fi

# ── 4. the signature, exactly as S8 checks it ────────────────────────────────────────────────────
cosign verify --key "$KEY" "$REF" >/dev/null \
  || refuse "cosign verify failed for $REF against $KEY."

# ── 5. the builder, pinned ───────────────────────────────────────────────────────────────────────
BIB="$(sed -n 's/^BIB_IMAGE=//p' "$BASE/bib.lock" 2>/dev/null | head -1)"
[[ "$BIB" =~ @sha256:[a-f0-9]{64}$ ]] \
  || refuse "BIB_IMAGE in bib.lock is '${BIB:-<unset>}', not pinned by digest. The builder decides which bytes boot; it is not allowed to float."

# ── build ────────────────────────────────────────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/auros-media.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
podman pull "$BIB" >&2 || refuse "could not pull $BIB"
podman pull "$REF" >&2 || refuse "could not pull $REF"

# ── 6b. the enrolment file against the accounts this image declares ─────────────────────────────
DECLARED="$(podman run --rm --network=none --entrypoint /usr/bin/cat "$REF" /usr/lib/auros/accounts.json 2>/dev/null)" || DECLARED=''
if [ -n "$DECLARED" ]; then
  ACCT="$(printf '%s' "$DECLARED" | python3 -c 'import json,sys
for a in json.load(sys.stdin)["accounts"]: print(a["name"], a["role"])')" \
    || refuse "the image's /usr/lib/auros/accounts.json could not be read"
  [ -n "$ENROL" ] || refuse "$REF declares accounts ($(printf '%s' "$ACCT" | cut -d' ' -f1 | tr '\n' ' ')) but no --enrolment file was given. Every laptop installed from this ISO would boot with nobody able to sign in."
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -q "^$n " <<<"$ACCT" || refuse "--enrolment names '$n', which $REF does not declare. Is this the right school's file?"
  done <<<"$ENROL_NAMES"
  admin_ok=0
  while read -r n r; do
    [ "$r" = admin ] && grep -qx "$n" <<<"$ENROL_NAMES" && admin_ok=1
  done <<<"$ACCT"
  [ "$admin_ok" = 1 ] || refuse "--enrolment gives no first password to any admin account $REF declares. Nobody could administer these laptops."
elif [ -n "$ENROL" ]; then
  refuse "$REF declares no accounts (a kiosk, or built before recipes declared them), so --enrolment has nothing to enrol. Leave it off."
fi

BIBCONF=()
if [ -n "$ENROL" ]; then
  # base64, so no hash character is ever interpreted by TOML, the kickstart parser or the %post shell.
  B64="$(grep -v '^#' "$ENROL" | grep . | base64 | tr -d '\n')"
  cat > "$WORK/config.toml" <<EOF
[customizations.installer.kickstart]
contents = """
text --non-interactive
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --noswap --type=lvm --fstype=xfs
network --bootproto=dhcp --device=link --activate --onboot=on
reboot --eject

%post --erroronfail
umask 077
mkdir -p /etc/auros/enrolment
echo '$B64' | base64 -d > /etc/auros/enrolment/accounts.secret
chmod 0600 /etc/auros/enrolment/accounts.secret
%end
"""
EOF
  B64=''
  chmod 0600 "$WORK/config.toml"
  BIBCONF=(-v "$WORK/config.toml":/config.toml:ro)
  say "enrolment: $(printf '%s' "$ENROL_NAMES" | grep -c .) first password(s) go into this ISO's kickstart, as hashes"
fi
say "bootc-image-builder -> anaconda-iso (slow)"
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$WORK":/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  ${BIBCONF[@]+"${BIBCONF[@]}"} \
  "$BIB" --type anaconda-iso --rootfs xfs "$REF" >&2 \
  || refuse "bootc-image-builder failed"

SRC="$(find "$WORK" -name '*.iso' | head -1)"
[ -n "$SRC" ] || refuse "bootc-image-builder exited 0 and produced no .iso"
mkdir -p "$OUT"
ISO="$OUT/$(basename "$IMAGE")-${DIGEST:7:12}.iso"
cp "$SRC" "$ISO"
( cd "$OUT" && f="$(basename "$ISO")" && { sha256sum "$f" 2>/dev/null || shasum -a 256 "$f"; } > "$f.sha256" )

cat <<EOF

Install media: $ISO
  image    $REF
  gate     full recorded pass (control repo @ $(git -C "$CTL" rev-parse --short HEAD))
  signed   cosign verify ok against signing/keys/auros.pub
  builder  $BIB
  enrolment ${ENROL:-none}

$( [ -z "$ENROL" ] || printf 'THIS ISO CARRIES THE SCHOOL'"'"'S FIRST-PASSWORD HASHES. Handle the file and every stick made from it\nlike a key: keep them apart from the password sheet, and wipe the sticks when enrolment is done.\n\n' )
This script does not write to any device. On a LINUX machine (D13), find the stick with \`lsblk\`,
make sure it is the stick and not a disk you care about, and run the one command below with
/dev/DEVICE replaced. This ISO is an UNATTENDED installer: it erases the first disk of the laptop it
boots on. Copy any data off that laptop first (spec §4.1, GATE5-RUNBOOK step 3).

  sudo dd if=$ISO of=/dev/DEVICE bs=4M conv=fsync status=progress
EOF

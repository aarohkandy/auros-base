#!/usr/bin/env bash
# tools/make-install-media.sh — every refusal seen red, the happy path seen green (D19).
#
# Runs the REAL script, copied into a scratch auros-base tree beside a scratch control repo, with node,
# cosign and podman stubbed on PATH. The stubs log their argv so the test can assert the contract
# (gate.mjs's one CLI form, cosign's S8 call, bib by digest) rather than just an exit code. A stub
# `dd` records any call: the script must never write a device, so that file must never appear.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

SCRIPT="$REPO/tools/make-install-media.sh"
HEX="$(printf 'a%.0s' $(seq 1 64))"
GOOD="ghcr.io/auros-org/auros-base@sha256:$HEX"
PINNED="$(sed -n 's/^BIB_IMAGE=//p' "$REPO/bib.lock")"
[ -n "$PINNED" ] || t_abort "could not read BIB_IMAGE from the real bib.lock"

# ctx — fresh scratch: $D/auros/auros-base/{tools,signing/keys,bib.lock}, $D/auros/{tools/gate.mjs,attest}
# as a committed git repo, and $D/bin stubs. Behaviour knobs are env vars read by the stubs.
ctx() {
  local d; newroot >/dev/null; d="${T_TMPDIRS[${#T_TMPDIRS[@]}-1]}"
  local b="$d/auros/auros-base"
  mkdir -p "$b/tools" "$b/signing/keys" "$d/auros/tools" "$d/auros/attest" "$d/bin" "$d/out"
  cp "$SCRIPT" "$b/tools/"; cp "$REPO/bib.lock" "$b/"
  cp "$REPO/signing/keys/auros-development.pub" "$b/signing/keys/"
  printf -- '-----BEGIN PUBLIC KEY-----\nPRODUCTIONKEYPRODUCTIONKEY\n-----END PUBLIC KEY-----\n' > "$b/signing/keys/auros.pub"
  echo '// stub gate; `node` is stubbed' > "$d/auros/tools/gate.mjs"
  printf 'digest\timage\n' > "$d/auros/attest/passed-digests.tsv"
  git -C "$d/auros" init -q && git -C "$d/auros" add tools attest \
    && git -C "$d/auros" -c user.email=t@t -c user.name=t commit -qm fixture || t_abort "git fixture failed"
  cat > "$d/bin/node" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$d/node.log"; exit "\${STUB_GATE_RC:-0}"
SH
  cat > "$d/bin/cosign" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$d/cosign.log"; exit "\${STUB_COSIGN_RC:-0}"
SH
  cat > "$d/bin/podman" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$d/podman.log"
# the image's declared accounts: \$STUB_ACCOUNTS names a file standing in for /usr/lib/auros/accounts.json
case " \$* " in *" --entrypoint /usr/bin/cat "*)
  [ -n "\${STUB_ACCOUNTS:-}" ] && exec cat "\$STUB_ACCOUNTS"; exit 1 ;; esac
if [ "\$1" = run ]; then
  for a in "\$@"; do case "\$a" in *:/config.toml:ro) c="\${a%:/config.toml:ro}"; cp "\$c" "$d/config.captured"; ls -l "\$c" > "$d/config.mode";; esac; done
  while [ \$# -gt 0 ]; do case "\$1" in -v) case "\$2" in *:/output) o="\${2%:/output}";; esac; shift 2;; *) shift;; esac; done
  [ "\${STUB_BIB_NOISO:-0}" = 1 ] || { mkdir -p "\$o/bootiso"; echo iso > "\$o/bootiso/install.iso"; }
fi
exit 0
SH
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/dd.called"\n' "$d" > "$d/bin/dd"
  chmod +x "$d/bin/"*
  D="$d"; B="$(cd "$b" && pwd)"
}
mim() { ( cd "$D" && PATH="$D/bin:$PATH" AUROS_CONTROL_REPO="$D/auros" bash "$B/tools/make-install-media.sh" "$@" --out "$D/out" ); }

group "happy path"
ctx
run_check ref green "ledger pass + production key + cosign ok + pinned bib → ISO" -- mim "$GOOD"
out="$T_LAST_OUT"
assert_file "the .iso is in --out, named repo + 12 hex of the digest" "$D/out/auros-base-${HEX:0:12}.iso"
assert_file "…with a sha256 beside it" "$D/out/auros-base-${HEX:0:12}.iso.sha256"
assert_eq "gate called in build.yml's one CLI form" "$D/auros/tools/gate.mjs sha256:$HEX --image ghcr.io/auros-org/auros-base" "$(cat "$D/node.log")"
assert_eq "cosign verify is S8's call, against signing/keys/auros.pub" "verify --key $B/signing/keys/auros.pub $GOOD" "$(cat "$D/cosign.log")"
assert_has "bib pulled by its pinned digest" "pull $PINNED" "$(cat "$D/podman.log")"
assert_has "bib run by its pinned digest, anaconda-iso, of the digest ref" "$PINNED --type anaconda-iso --rootfs xfs $GOOD" "$(cat "$D/podman.log")"
assert_not "no :latest anywhere podman was asked for" ":latest" "$(cat "$D/podman.log")"
assert_nofile "dd was never executed" "$D/dd.called"
assert_has "prints the write command with the device as a placeholder" "of=/dev/DEVICE" "$out"
assert_not "the script source has no '|| true'" "|| true" "$(cat "$SCRIPT")"

# green for every id, so the direction audit sees each check accept good input
for id in gate key cosign bib ctl out; do ctx; run_check "$id" green "happy path passes the $id check" -- mim "$GOOD"; done

group "enrolment (owner decision A1) — first-password hashes into the ISO's kickstart"
FAKE='$6$fakesalt$FAKEHASHFORTESTSONLY'
SCHOOL='{"schema":1,"accounts":[{"display_name":"Pupil","name":"pupil","role":"user"},{"display_name":"School IT","name":"school-it","role":"admin"}]}'
enrol() { # <body> [mode] — an enrolment file in the scratch dir
  printf '%s\n' "$1" > "$D/enrol"; chmod "${2:-600}" "$D/enrol"
}
ctx; printf '%s' "$SCHOOL" > "$D/accounts.json"; enrol "# made by make-enrolment.sh"$'\n'"school-it:$FAKE"$'\n'"pupil:$FAKE"
export STUB_ACCOUNTS="$D/accounts.json"
run_check enrol green "declared accounts + a 0600 hash file → ISO" -- mim "$GOOD" --enrolment "$D/enrol"
out="$T_LAST_OUT"
assert_has "bib got the kickstart config" "config.toml:/config.toml:ro" "$(cat "$D/podman.log")"
K="$(cat "$D/config.captured" 2>/dev/null)"
assert_has "…as [customizations.installer.kickstart]" "[customizations.installer.kickstart]" "$K"
assert_has "…with the unattended install bib no longer adds itself" "clearpart --all --initlabel" "$K"
assert_has "…and a %post writing the file where auros-accounts reads it" "> /etc/auros/enrolment/accounts.secret" "$K"
assert_has "…root-only" "chmod 0600 /etc/auros/enrolment/accounts.secret" "$K"
assert_not "…with no ostreecontainer line (bib adds it; its README)" "ostreecontainer" "$K"
b64="$(sed -n "s/^echo '\(.*\)' | base64 -d.*/\1/p" <<<"$K")"
assert_eq "the %post payload decodes to exactly the hash lines, comment dropped" \
  "school-it:$FAKE"$'\n'"pupil:$FAKE" "$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
assert_has "the config file bib read was 0600" "-rw-------" "$(cat "$D/config.mode" 2>/dev/null)"
assert_not "no hash is printed" "FAKEHASH" "$out"
assert_has "the ISO is called a secret" "FIRST-PASSWORD HASHES" "$out"

ctx; printf '%s' "$SCHOOL" > "$D/accounts.json"; export STUB_ACCOUNTS="$D/accounts.json"
run_check enrol red "the image declares accounts and no --enrolment is given" -- mim "$GOOD"
assert_has "…says nobody could sign in" "nobody able to sign in" "$T_LAST_OUT"
assert_not "…before bib ran" "--type anaconda-iso" "$(cat "$D/podman.log")"

ctx; enrol "school-it:not-a-real-password"
run_check enrol red "a plain-text password in the file" -- mim "$GOOD" --enrolment "$D/enrol"
assert_has "…refused as not a hash" "not a crypt(3) hash" "$T_LAST_OUT"
assert_not "…never echoed" "not-a-real-password" "$T_LAST_OUT"
assert_nofile "…before the gate ran" "$D/node.log"

ctx; enrol "school-it:$FAKE" 644
run_check enrol red "an enrolment file other accounts can read" -- mim "$GOOD" --enrolment "$D/enrol"
assert_has "…says its mode" "mode 644" "$T_LAST_OUT"

ctx; enrol "school-it:$FAKE"$'\n'"school-it:$FAKE"
run_check enrol red "an account named twice" -- mim "$GOOD" --enrolment "$D/enrol"

ctx; printf '%s' "$SCHOOL" > "$D/accounts.json"; export STUB_ACCOUNTS="$D/accounts.json"; enrol "school-it:$FAKE"$'\n'"head-teacher:$FAKE"
run_check enrol red "a name this image does not declare (the wrong school's file?)" -- mim "$GOOD" --enrolment "$D/enrol"
assert_has "…names it" "head-teacher" "$T_LAST_OUT"

ctx; printf '%s' "$SCHOOL" > "$D/accounts.json"; export STUB_ACCOUNTS="$D/accounts.json"; enrol "pupil:$FAKE"
run_check enrol red "no admin gets a first password" -- mim "$GOOD" --enrolment "$D/enrol"

unset STUB_ACCOUNTS
ctx; enrol "school-it:$FAKE"
run_check enrol red "an image that declares no accounts (kiosk), given --enrolment" -- mim "$GOOD" --enrolment "$D/enrol"
ctx
run_check enrol green "an image that declares no accounts, no --enrolment" -- mim "$GOOD"
assert_not "…and bib gets no kickstart" "/config.toml" "$(cat "$D/podman.log")"

group "refusals"
ctx
run_check ref red "a tag is refused" -- mim "ghcr.io/auros-org/auros-base:hardened"
assert_has "…and says it is a tag" "is a TAG" "$T_LAST_OUT"
run_check ref red "tag+digest is refused" -- mim "ghcr.io/auros-org/auros-base:hardened@sha256:$HEX"
run_check ref red "a non-ghcr registry is refused" -- mim "localhost:5000/auros-base@sha256:$HEX"
run_check ref red "a short digest is refused" -- mim "ghcr.io/auros-org/auros-base@sha256:${HEX:0:63}"
assert_nofile "no refusal reached the gate" "$D/node.log"

ctx; export STUB_GATE_RC=1; run_check gate red "gate exit 1 (no recorded pass) is refused" -- mim "$GOOD"; unset STUB_GATE_RC
assert_nofile "…before cosign ran" "$D/cosign.log"
assert_nofile "…and before podman ran" "$D/podman.log"
ctx; export STUB_GATE_RC=2; run_check gate red "gate exit 2 (undecided) is refused" -- mim "$GOOD"; unset STUB_GATE_RC

ctx; echo "x" >> "$D/auros/attest/passed-digests.tsv"
run_check ctl red "a locally edited ledger is refused" -- mim "$GOOD"
assert_has "…because it is edited" "uncommitted changes" "$T_LAST_OUT"
assert_nofile "…without asking the gate" "$D/node.log"
ctx; rm -rf "$D/auros/.git"
run_check ctl red "a control repo that is not a git checkout is refused" -- mim "$GOOD"

ctx; rm "$B/signing/keys/auros.pub"
run_check key red "no production key → refused" -- mim "$GOOD"
assert_has "…and says so" "no production signing key" "$T_LAST_OUT"
ctx; cp "$B/signing/keys/auros-development.pub" "$B/signing/keys/auros.pub"
run_check key red "the development key copied to auros.pub → refused" -- mim "$GOOD"
assert_nofile "…before cosign ran" "$D/cosign.log"

ctx; export STUB_COSIGN_RC=1; run_check cosign red "cosign verify failing → refused" -- mim "$GOOD"; unset STUB_COSIGN_RC
assert_nofile "…before podman ran" "$D/podman.log"

ctx; sed -i.bak 's#^BIB_IMAGE=.*#BIB_IMAGE=quay.io/centos-bootc/bootc-image-builder:latest#' "$B/bib.lock"
run_check bib red "bib at :latest → refused" -- mim "$GOOD"
assert_nofile "…before podman ran" "$D/podman.log"
ctx; export STUB_BIB_NOISO=1; run_check bib red "bib exits 0 with no .iso → refused" -- mim "$GOOD"; unset STUB_BIB_NOISO

ctx; run_check out red "--out under /dev is refused" -- bash -c "cd $D && PATH=$D/bin:\$PATH AUROS_CONTROL_REPO=$D/auros bash $B/tools/make-install-media.sh $GOOD --out /dev/sdz"
assert_has "…by the /dev guard" "is under /dev" "$T_LAST_OUT"
assert_nofile "dd was never executed on any path" "$D/dd.called"

group "vm.sh — bib pinned by digest, fails loudly"
VM="$REPO/matrix/run/lib/vm.sh"
FN="$(extract_fn "$VM" bib_image)"
ctx
run_snippet vmbib green "bib.lock's digest pin is accepted" "BASE_REPO=$B; $FN
bib_image"
assert_eq "…and it is exactly the pin" "$PINNED" "$(bash -c "BASE_REPO=$B; $FN
bib_image")"
run_snippet vmbib red "BIB_IMAGE=…:latest is refused" "BIB_IMAGE=quay.io/centos-bootc/bootc-image-builder:latest BASE_REPO=$B; $FN
bib_image"
run_snippet vmbib red "no bib.lock is refused" "BASE_REPO=$D/nowhere; $FN
bib_image"
BQ="$(extract_fn "$VM" build_qcow2)"
assert_not "build_qcow2 no longer names :latest" ":latest" "$BQ"
assert_not "build_qcow2 no longer swallows a failed pull" "|| true" "$BQ"

t_finish make-install-media.test.sh

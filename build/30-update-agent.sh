#!/usr/bin/bash
# 30-update-agent.sh -- the safety-critical layer of auros-base.
#
# Runs inside the image build from auros-base/Containerfile, in numeric order. Idempotent,
# -euo pipefail, and says what it did.
#
# ── THREE THINGS THAT ARE ONE THING ──────────────────────────────────────────────────────────────
#
#   A. the update agent      bootc's own timer, greenboot, and the health checks that decide
#                            whether a boot was good enough to keep
#   B. signature enforcement D8: key, registries.d, policy and install config that actually verify
#   C. the U4 harness        verify-enforcement.sh, in the image, so the check runs on the machine
#                            it is a claim about
#
# They live in one script because they are one property: a machine that updates itself unattended
# is only safe if it can refuse a bad image and recover from a broken one. Either half alone is
# worse than neither -- unattended updates with no rollback is a fleet-wide brick waiting for a bad
# night, and rollback with no signature check is a fleet that will faithfully recover into whatever
# anyone pushes to the registry.
#
# ── FAIL-CLOSED, EVERYWHERE ──────────────────────────────────────────────────────────────────────
#
# Every assertion here would rather fail the build than produce an image that looks configured and
# is not. Read D8 and notice that the failure it describes is INVISIBLE from inside the image: the
# files are present, the flag is accepted, the command exits 0, and nothing is verified. The whole
# design principle of this file is that such a state must be unreachable at build time, because it
# is undetectable later.
set -euo pipefail

. /tmp/auros-build/build/00-common.sh

UA="${AUROS_BUILD_DIR}/update-agent"
SIGN="${AUROS_BUILD_DIR}/signing"
[ -d "$UA/greenboot" ]   || die "$UA is missing or is not update-agent/ -- the Containerfile must COPY update-agent/ to $AUROS_BUILD_DIR/"
[ -f "$SIGN/policy.json" ] || die "$SIGN is missing or is not signing/ -- the Containerfile must COPY signing/ to $AUROS_BUILD_DIR/"

# ── The enforced namespace ───────────────────────────────────────────────────────────────────────
# D1 puts the namespace in exactly one file (auros.config.json) so that a rename is one file plus a
# registry re-tag. auros.config.json lives in the meta repo and is not in this build context, so
# rather than hardcode a second copy of the name, this derives it from the source repo URL that
# 00-common.sh already wrote into the image. A rename therefore propagates here on its own.
# AUROS_SCOPE in the environment overrides, which is how CI builds against a scratch namespace.
auros_scope_default() {
  local rel="$AUROS_PREFIX/release" repo org
  if [ -r "$rel" ]; then
    repo="$(grep -E '^AUROS_SOURCE_REPO=' "$rel" | head -1 | cut -d= -f2- || true)"
    org="$(printf '%s' "$repo" | sed -n 's#^https://github\.com/\([^/]*\)/.*#\1#p')"
  fi
  printf 'ghcr.io/%s' "${org:-aarohkandy}"
}
AUROS_SCOPE="${AUROS_SCOPE:-$(auros_scope_default)}"
AUROS_CANARY_REPO="${AUROS_CANARY_REPO:-${AUROS_SCOPE}/auros-canary}"

step "update agent and signature enforcement"
found "enforced scope:    $AUROS_SCOPE"
found "canary repository: $AUROS_CANARY_REPO"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "A1. assert the platform auto-rollback depends on (D9)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# greenboot's rollback is a GRUB boot counter, wired through ostree-finalize-staged.service and
# bootupd's static GRUB config. On the composefs/UKI backend upstream has never wired boot-loader
# entry counting, so greenboot rollback DOES NOT WORK THERE AT ALL. D9 makes staying on
# ostree + GRUB/bootupd a deliberate constraint rather than a default -- and a constraint nobody
# asserts is only a preference. These are the assertions that make it a constraint.

have_cmd bootc || die "bootc is not in this image -- this is not a bootc base and nothing below applies"
found "bootc: $(bootc --version 2>/dev/null || echo present)"

[ -f /usr/lib/systemd/system/ostree-finalize-staged.service ] || die \
  "ostree-finalize-staged.service is absent. greenboot's greenboot-grub2-set-counter.service is RequiredBy that unit, so without it the boot counter is never staged and auto-rollback (check U3) silently does not exist. If this base has moved to the composefs backend, D9 applies and that is a decision for the human, not something to work around here."
did "ostree backend confirmed -- the boot counter can be staged"

[ -d /usr/lib/bootupd/grub2-static ] || die \
  "/usr/lib/bootupd/grub2-static is absent. bootupd concatenates every *.cfg in its configs.d into /boot/grub2/grub.cfg at install time, and that is the only path by which greenboot's boot-counter logic reaches GRUB."
did "bootupd static GRUB config present"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "A2. install greenboot -- NOT preinstalled on Aurora (D9)"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Verified absent from ublue-os/aurora, bluefin, main, and the Fedora bootc standard/minimal
# manifests; it ships only in the Fedora bootc IoT manifest.
#
# We install `greenboot` and DELIBERATELY NOT `greenboot-default-health-checks`. That subpackage
# ships 01_repository_dns_check.sh as a REQUIRED check, and a required check that fails rolls the
# machine back. A school whose broadband drops overnight would find every laptop rolled back in the
# morning, then rolled back again from there -- which is the fallback boot and needs a technician
# per machine. U5 says an offline machine is a no-op. Our own 10-network-stack.sh asserts the
# network STACK and never connectivity, for exactly this reason.

pkg_ensure greenboot

if have_pkg greenboot-default-health-checks; then
  warn "greenboot-default-health-checks is installed (not by us). Its 01_repository_dns_check.sh is a REQUIRED check that fails when DNS is unreachable, which would roll a machine back over a school's broadband outage. Review before shipping."
fi

# Assert the CAPABILITIES we depend on, not a remembered file list.
#
# greenboot 0.16.4 reorganised itself and the old list was from 0.15: `greenboot-grub2-set-counter`
# and `redboot-auto-reboot` no longer exist as separate binaries or units. What replaced them is
# `greenboot-set-rollback-trigger.service`, and the grub fragment now ships in the package itself.
# Verified by building the package and reading `rpm -ql` (probe-greenboot.yml, run 35542125710)
# rather than by guessing a second time.
#
# Naming capabilities rather than paths means the next reorganisation produces a legible failure
# ("nothing arms the rollback trigger") instead of a filename nobody recognises.
_gb_missing=()
_gb_need() { # capability, then one or more paths that would satisfy it
  local cap="$1"; shift
  local f
  for f in "$@"; do [ -e "$f" ] && { found "$cap -> $f"; return 0; }; done
  _gb_missing+=("$cap (looked for: $*)")
}
_gb_need "the greenboot runner"          /usr/libexec/greenboot/greenboot
_gb_need "the health-check unit"         /usr/lib/systemd/system/greenboot-healthcheck.service
# THE one that makes rollback real. Without something arming a rollback trigger, every other part of
# greenboot still looks correctly installed and check U3 is a fiction.
_gb_need "something that arms rollback"  /usr/lib/systemd/system/greenboot-set-rollback-trigger.service \
                                         /usr/lib/systemd/system/greenboot-grub2-set-counter.service \
                                         /usr/libexec/greenboot/greenboot-grub2-set-counter
_gb_need "the success target"            /usr/lib/systemd/system/greenboot-success.target
_gb_need "the GRUB boot-counter fragment" /usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg

if [ ${#_gb_missing[@]} -gt 0 ]; then
  printf 'auros[30-update-agent]   greenboot is installed but these capabilities are absent:\n' >&2
  printf 'auros[30-update-agent]     - %s\n' "${_gb_missing[@]}" >&2
  printf 'auros[30-update-agent]   what the package ACTUALLY ships:\n' >&2
  rpm -ql greenboot 2>/dev/null | sed 's/^/auros[30-update-agent]     /' >&2
  die "greenboot's layout does not provide what auto-rollback needs. The file list above is ground truth -- update the capability map, do not delete the check."
fi
did "greenboot capabilities verified (runner, health-check unit, rollback trigger, success target, GRUB fragment)"

GB_FRAGMENT=/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg
[ -f "$GB_FRAGMENT" ] || die \
  "$GB_FRAGMENT is missing. Without it GRUB has no boot_counter logic, auto-rollback does not happen, and EVERY OTHER PART of greenboot still looks correctly installed. That is precisely the silent gap check U3 exists to catch -- fail here, where it is cheap."
grep -q 'boot_counter' "$GB_FRAGMENT" || die "$GB_FRAGMENT exists but has no boot_counter logic in it"
did "GRUB boot-counter fragment present"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "A3. retry count -- make 'fails twice ⇒ rollback' literally what happens"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# MEASURED SEMANTICS, from greenboot-grub2-set-counter and grub2/08_greenboot.cfg:
#
#   staging an update writes boot_counter=$GREENBOOT_MAX_BOOT_ATTEMPTS and boot_success=0.
#   each boot, GRUB: if boot_counter is 0 or -1 -> set default=1 (the ROLLBACK deployment);
#                    otherwise decrement it.
#
#   So MAX=N gives the new image N attempts and rolls back on boot N+1.
#
#   THE REAL UPSTREAM DEFAULT IS 3 -- three attempts, rollback on the fourth boot. That is what you
#   get if this block is deleted.
#
# Spec §6A says "rolls back automatically if the new image fails to reach a login prompt twice".
# Twice is 2. Not 3, and not 1 -- 1 would roll a machine back over a single unlucky boot.

CONF=/etc/greenboot/greenboot.conf
[ -f "$CONF" ] || die "$CONF is missing after installing greenboot"
sed -i '/^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=/d' "$CONF"
cat >> "$CONF" <<'EOF'

# AUROS: spec §6A -- "rolls back automatically if the new image fails to reach a login prompt
# twice". Upstream's default is 3 (three attempts, rollback on the fourth boot). Two attempts is
# what "twice" means. Do not raise this without changing the sentence we sell.
GREENBOOT_MAX_BOOT_ATTEMPTS=2
EOF
auros_stamp "$CONF"
printf '%s\n' "$CONF" >> "$AUROS_WRITTEN_LIST"
n="$(grep -cE '^[[:space:]]*GREENBOOT_MAX_BOOT_ATTEMPTS=2$' "$CONF" || true)"
[ "$n" = "1" ] || die "expected exactly one GREENBOOT_MAX_BOOT_ATTEMPTS=2 in $CONF, found $n"
# greenboot sources this file under `set -u` and expands DISABLED_HEALTHCHECKS as an array. If our
# edit ever removed that definition, every health check would abort before running -- which
# greenboot would report as a failure, on every boot, forever.
grep -q 'DISABLED_HEALTHCHECKS=' "$CONF" || die "$CONF no longer defines DISABLED_HEALTHCHECKS"
did "GREENBOOT_MAX_BOOT_ATTEMPTS=2 (upstream default is 3)"
record greenboot-max-boot-attempts 2

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "A4. the update timer -- verified by name, not assumed"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# MEASURED, and this is the most consequential finding in this step:
#
#   Aurora's preset (system_files/shared/usr/lib/systemd/system-preset/89-aurora.preset) enables
#   `uupd.timer`, NOT bootc's timer. uupd runs `bootc upgrade --quiet --progress-fd 3` -- it STAGES
#   and never reboots -- once a day at 04:00.
#
#   bootc's own bootc-fetch-apply-updates.timer IS present (it ships in the bootc RPM) and is NOT
#   preset-enabled, so it is inert.
#
# Had we assumed bootc's timer was running, this image would stage updates and never apply them,
# check U1 would fail, and the cause would look like a bootc bug rather than a systemd preset.
#
# We enable bootc's timer and override its ExecStart. uupd.timer is left alone: it also updates
# Flatpaks, which is where the customer's applications live (spec §3). The two can collide on
# bootc's lock; auros-update retries once and then exits clean, so a collision costs one skipped
# cycle and never a failed unit.

TIMER_UNIT=/usr/lib/systemd/system/bootc-fetch-apply-updates.timer
SVC_UNIT=/usr/lib/systemd/system/bootc-fetch-apply-updates.service
{ [ -f "$TIMER_UNIT" ] && [ -f "$SVC_UNIT" ]; } || die \
  "bootc-fetch-apply-updates.{timer,service} are not in /usr/lib/systemd/system/. bootc has renamed or moved its update unit. DO NOT guess a replacement: our drop-ins would attach to nothing and this image would ship with no update path at all. Find the current unit name, change this script AND the greenboot check 30-update-timer-enabled.sh together, and record it in DECISIONS.md."
grep -q 'bootc upgrade' "$SVC_UNIT" || die "$SVC_UNIT no longer runs 'bootc upgrade' -- re-read it before overriding its ExecStart"
did "vendor units present and still run bootc upgrade"

install_file "$UA/libexec/auros-update" "$AUROS_LIBEXEC/auros-update" 0755

for d in bootc-fetch-apply-updates.service.d bootc-fetch-apply-updates.timer.d greenboot-healthcheck.service.d; do
  [ -d "$UA/systemd/$d" ] || die "missing drop-in source $UA/systemd/$d"
  for c in "$UA/systemd/$d"/*.conf; do
    install_file "$c" "/usr/lib/systemd/system/$d/$(basename "$c")" 0644
  done
done

# systemd APPENDS to a vendor ExecStart unless the drop-in clears it first. Without the empty
# `ExecStart=` line the machine would run bootc's `--apply` command AND ours, which means it would
# reboot out from under a logged-in user in exactly the case our wrapper exists to prevent.
grep -qx 'ExecStart=' /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-auros.conf \
  || die "the service drop-in does not clear ExecStart= first; systemd would run both bootc's command and ours"
did "ExecStart replaced, not appended"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "A5. health checks"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# greenboot's runner globs '*.sh' and sorts by name; required.d runs in STRICT mode, so the first
# failure stops the rest. The numeric prefixes are that order: most fundamental first.
#
# WHERE OUR CHECKS GO, and this changed with greenboot 0.16.
#
# 0.16 added /usr/lib/greenboot/{check/required.d,check/wanted.d,green.d,red.d} alongside the /etc
# ones, and that distinction is exactly the one a bootc image should care about:
#
#   /usr/lib  is IMAGE-lifecycled. It is replaced wholesale by every update and cannot drift.
#   /etc      is MACHINE state, three-way merged on upgrade, and editable on the machine.
#
# OUR required checks are rollback triggers — they are the safety property we sell, and a machine
# where somebody deleted one has silently lost its ability to recover from a bad update, while still
# looking correctly configured. So ours go in /usr/lib, where they come back with every image.
#
# /etc stays available for a SITE to add its own checks without us cutting an image. greenboot reads
# both, which is why 0.16 has both.

for dir in check/required.d check/wanted.d green.d red.d; do
  found "$dir:"
  shopt -s nullglob
  files=( "$UA/greenboot/$dir"/*.sh )
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || die "no scripts in $UA/greenboot/$dir"
  for f in "${files[@]}"; do
    bash -n "$f" || die "$f is not valid bash -- a health check that cannot parse fails on every boot"
    install_file "$f" "/usr/lib/greenboot/$dir/$(basename "$f")" 0755
  done
done

install_file "$UA/etc/auros/update-agent/failed-units.ignore" /etc/auros/update-agent/failed-units.ignore 0644
install_file "$UA/etc/auros/update-agent/apply-policy"        /etc/auros/update-agent/apply-policy        0644
# State lives in /var, declared via tmpfiles.d rather than mkdir'd: content written to /var in a
# Containerfile is only a first-boot default. More to the point, a baseline of "what was working
# before" stored inside the image would be replaced by the very update it exists to judge.
install_file "$UA/tmpfiles/auros-update-agent.conf" /usr/lib/tmpfiles.d/auros-update-agent.conf 0644

# EVERY REQUIRED CHECK IS A ROLLBACK TRIGGER. Adding one is a safety decision, not a refactor, so
# the count is asserted here and reasoned about in update-agent/README.md. If this fails, the right
# response is to write down why the new check is worth a rollback -- not to change the number.
req="$(find /usr/lib/greenboot/check/required.d -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"
[ "$req" = "4" ] || die "expected 4 required health checks, found $req. Every required check can roll a machine back; adding one belongs in update-agent/README.md and DECISIONS.md, not in a quiet commit."
did "4 required checks (rollback triggers), 3 wanted checks (reported only)"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "B1. signature enforcement -- D8"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Deriving from Aurora gives us NOTHING here. The base policy ends in a docker
# "": [{"type":"insecureAcceptAnything"}] catch-all, so `bootc switch --enforce-container-sigpolicy`
# succeeds while verifying nothing. All four pieces below must be true and EACH ONE ALONE LOOKS
# LIKE SUCCESS.

# A PRODUCTION key if we have one; otherwise the DEVELOPMENT key, which is enough to build and boot
# but is refused at publish time (signing/keys/DEVELOPMENT-KEY.md).
#
# The distinction matters because the two questions are different. "Can this image be built and
# exercised?" needs a key that EXISTS, so the policy references something real and the signature
# machinery can be tested end to end. "Can this image be trusted by a school?" needs a key whose
# CUSTODY someone is accountable for. Conflating them either blocks all testing until a human mints a
# credential, or ships a throwaway key to a customer. Neither is acceptable, so the build tells them
# apart and records which one it used.
KEY_SRC="$SIGN/keys/auros.pub"
AUROS_KEY_KIND=production
if [ ! -s "$KEY_SRC" ] && [ -s "$SIGN/keys/auros-development.pub" ]; then
  KEY_SRC="$SIGN/keys/auros-development.pub"
  AUROS_KEY_KIND=development
  warn "using the DEVELOPMENT signing key. This image can be built, booted and matrix-tested; it CANNOT be published to a customer-facing tag. See signing/keys/DEVELOPMENT-KEY.md."
fi
[ -s "$KEY_SRC" ] || die \
"no signing key: neither signing/keys/auros.pub nor signing/keys/auros-development.pub. This build is REFUSED rather than completed.

   An image built without the key would carry a policy referencing /usr/lib/pki/containers/auros.pub,
   find nothing there, and refuse every update for the rest of that machine's life -- in a school,
   months later, with no terminal and no out-of-band console. Spec §3: an unsigned or untested image
   can never reach a customer; a build that cannot verify signatures should not produce an image.

   Generating the key pair is a human action -- it mints a long-lived organisational credential.
   See auros-base/signing/keys/README.md, and signing/RISKS.md R3."
grep -q 'BEGIN PUBLIC KEY' "$KEY_SRC" || die "$KEY_SRC is not a PEM public key"
# Written into the image itself rather than exported as a build variable. The publish step reads it
# back OUT of the built image, so a workflow cannot claim "production" for an image built with the
# development key — the answer travels with the artifact, not alongside it.
printf '%s\n' "$AUROS_KEY_KIND" > /usr/lib/auros/signing-key-kind
chmod 0644 /usr/lib/auros/signing-key-kind
did "signing key kind recorded in the image: $AUROS_KEY_KIND"
if grep -q 'BEGIN .*PRIVATE KEY' "$KEY_SRC"; then
  die "$KEY_SRC contains a PRIVATE key. Refusing to bake a signing key into an image that ships to customers."
fi
install_file "$KEY_SRC" /usr/lib/pki/containers/auros.pub 0644
found "key in /usr (immutable, replaced by an image update) rather than /etc (machine-local)"

# ── policy.json ──────────────────────────────────────────────────────────────────────────────────
sed "s|@AUROS_SCOPE@|${AUROS_SCOPE}|g" "$SIGN/policy.json" | install_text /etc/containers/policy.json 0644

# containers/image parses this with ParanoidUnmarshalJSONObject, which ERRORS on any unrecognised
# key rather than ignoring it -- a "$comment" would stop the policy loading, and a policy that does
# not load is a machine that cannot pull anything, including its own updates. This re-implements
# that strictness so it is caught in CI and never on a laptop.
python3 - /etc/containers/policy.json "$AUROS_SCOPE" <<'PY' || die "policy.json failed validation -- see the line above"
import json,sys
path,scope=sys.argv[1],sys.argv[2]
def bad(m):
    print("  ✗ policy.json: %s" % m, file=sys.stderr); sys.exit(1)
try: p=json.load(open(path))
except Exception as e: bad("does not parse: %s" % e)
extra=set(p)-{"default","transports"}
if extra: bad("unknown top-level keys %s -- containers/image REJECTS these, it does not ignore them" % sorted(extra))
if not p.get("default"): bad("no global default")
if any(r.get("type")=="insecureAcceptAnything" for r in p["default"]):
    bad("global default is insecureAcceptAnything; bootc's enforce-container-sigpolicy guard reads the GLOBAL DEFAULT ONLY and would reject this image")
docker=(p.get("transports") or {}).get("docker") or {}
rules=docker.get(scope)
if not rules: bad("no transports.docker entry for %s -- that IS the D8 failure, reproduced in our own file" % scope)
ss=[r for r in rules if r.get("type")=="sigstoreSigned"]
if not ss: bad("the %s entry exists but is not sigstoreSigned" % scope)
r=ss[0]
si=(r.get("signedIdentity") or {}).get("type")
if si not in ("matchRepository","exactRepository"):
    bad("signedIdentity is %r; cosign signatures carry only a repository and the default matchExact would reject EVERY signature we make -- which would also make U4's negative test pass for the wrong reason" % si)
kp=r.get("keyPath") or (r.get("keyPaths") or [None])[0]
if kp!="/usr/lib/pki/containers/auros.pub": bad("unexpected keyPath %r" % kp)
known={"type","keyPath","keyPaths","keyData","keyDatas","fulcio","pki","rekorPublicKeyPath",
       "rekorPublicKeyPaths","rekorPublicKeyData","rekorPublicKeyDatas","signedIdentity"}
for req in (q for rs in docker.values() for q in rs):
    u=set(req)-known
    if u: bad("unknown requirement key(s) %s" % sorted(u))
print("  ✓ %s -> sigstoreSigned(%s, %s)" % (scope, kp, si))
# The catch-all is a deliberate trade (signing/policy.json.README.md, "The \"\" catch-all stays"),
# but "catch-all kept for other registries" reads as a footnote about tidiness. It is not. Printing
# the CONSEQUENCE is the difference between a decision that stays visible and one that quietly
# becomes the thing everybody assumes was never there.
catchall=[r.get("type") for r in (docker.get("") or [])]
if catchall==["insecureAcceptAnything"]:
    print('  ! transports.docker[""] is insecureAcceptAnything: signature enforcement applies to %s'
          ' AND NOTHING ELSE. `bootc switch docker.io/<anything>` is accepted UNSIGNED on this image,'
          ' and "default": reject never answers because this entry is more specific. Deliberate --'
          ' see signing/policy.json.README.md. The only claim this image supports is "nobody but us'
          ' can update it from our own namespace".' % scope)
elif catchall==["reject"]:
    print('  ✓ transports.docker[""] rejects; only %s and any registry enumerated above can be pulled' % scope)
elif catchall:
    bad('transports.docker[""] is %r, which is neither insecureAcceptAnything (the recorded trade) '
        'nor reject (the strict alternative). An unreviewed third option here is how a policy stops '
        'meaning what its documentation says.' % catchall)
else:
    print('  ✓ no transports.docker[""] entry; the global default (reject) applies to every other registry')
PY

# ── registries.d ─────────────────────────────────────────────────────────────────────────────────
# Without this the sigstoreSigned rule is INERT: containers/image never looks for an attachment,
# finds no signature, and refuses every pull of our own images -- which would look like a registry
# outage rather than a configuration error.
sed "s|@AUROS_SCOPE@|${AUROS_SCOPE}|g" "$SIGN/registries.d/auros.yaml" | install_text /etc/containers/registries.d/auros.yaml 0644

# Two rules from containers-registries.d(5) that disable us silently if violated:
#   1. only the MOST-PRECISELY matching scope is used -- anything more specific hides ours entirely
#   2. at most one instance of any key under `docker` ACROSS ALL FILES -- a duplicate is an error
for other in /etc/containers/registries.d/*.yaml /etc/containers/registries.d/*.yml; do
  [ -e "$other" ] || continue
  if [ "$other" = /etc/containers/registries.d/auros.yaml ]; then continue; fi
  if grep -qE "^[[:space:]]*['\"]?${AUROS_SCOPE}['\"]?:" "$other"; then
    die "$other also defines the scope $AUROS_SCOPE. containers-registries.d(5) forbids the same key in two files; the merge fails and no signature is ever read."
  fi
  if grep -qE "^[[:space:]]*['\"]?${AUROS_SCOPE}/" "$other"; then
    die "$other defines a scope MORE SPECIFIC than $AUROS_SCOPE. Only the most-precisely matching scope is used, so our use-sigstore-attachments setting would be ignored entirely and signature verification would quietly stop working."
  fi
done
did "use-sigstore-attachments enabled for $AUROS_SCOPE, no conflicting or more-specific scope"

# ── install-time enforcement ─────────────────────────────────────────────────────────────────────
# Merged after Aurora's 20-aurora.toml (alphanumeric order). Without this, bootc records the
# deployment as signature mode "insecure" and IGNORES policy.json entirely, however correct
# policy.json looks. That row has no external symptom at all.
install_file "$SIGN/install/30-auros.toml" /usr/lib/bootc/install/30-auros.toml 0644
grep -qE '^enforce-container-sigpolicy[[:space:]]*=[[:space:]]*true' /usr/lib/bootc/install/30-auros.toml \
  || die "30-auros.toml does not set enforce-container-sigpolicy = true"
did "install config sets enforce-container-sigpolicy = true"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "C. check U4, in the image"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
install_file "$SIGN/verify-enforcement.sh" "$AUROS_LIBEXEC/verify-enforcement.sh" 0755
printf '%s\n' "$AUROS_SCOPE"       | install_text /etc/auros/signing/scope       0644
printf '%s\n' "$AUROS_CANARY_REPO" | install_text /etc/auros/signing/canary-repo 0644

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "D. enable the units -- Fedora's default preset is 'disable', so this is NOT automatic"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# greenboot ships NO systemd preset of its own, and Fedora's trailing preset rule is `disable *`.
# So %systemd_post leaves every greenboot unit DISABLED. An image with greenboot installed and not
# enabled has every file in place, passes any naive "is greenboot installed?" check, and performs
# no health checks and no rollback whatsoever. This block is the difference between U3 working and
# U3 being a story we tell.
#
# WHY NOT 00-common.sh's enable_unit(): it resolves only WantedBy=, and dies on a unit that has
# none. Four of greenboot's units are RequiredBy-only --
# greenboot-grub2-set-counter.service is `RequiredBy=ostree-finalize-staged.service`, which is
# precisely the link that stages the boot counter (D9). Handled here rather than by changing
# 00-common.sh, which belongs to another task; worth folding in later.

auros_enable() {
  local u="$1" f="" cand t linked=0
  for cand in "/usr/lib/systemd/system/$u" "/etc/systemd/system/$u"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  [ -n "$f" ] || die "unit $u does not exist in this image"

  _systemctl_offline enable --no-reload "$u" || true

  local kind dir
  for kind in WantedBy:wants RequiredBy:requires; do
    for t in $(sed -n "s/^${kind%%:*}=//p" "$f" | tr ' ' '\n' | grep -v '^$' || true); do
      dir="${kind##*:}"
      if [ -e "/etc/systemd/system/$t.$dir/$u" ] || [ -e "/usr/lib/systemd/system/$t.$dir/$u" ]; then
        linked=1; continue
      fi
      # /usr, not /etc: on a bootc host an image update replaces /usr wholesale, while /etc is
      # machine-local and three-way merged. A default that belongs to the image belongs in /usr,
      # and an administrator can still override it with a mask in /etc.
      mkdir -p "/usr/lib/systemd/system/$t.$dir"
      ln -sfn "../$u" "/usr/lib/systemd/system/$t.$dir/$u"
      [ -e "/usr/lib/systemd/system/$t.$dir/$u" ] || die "could not enable $u for $t ($dir)"
      linked=1
      found "linked $u into $t.$dir (offline systemctl enable did not)"
    done
  done

  [ "$linked" -eq 1 ] || die "$u declares neither WantedBy nor RequiredBy -- it cannot be enabled"
  did "enabled $u"
  record enabled-unit "$u"
}

# THE UNITS THAT ACTUALLY EXIST, verified by building greenboot and reading `rpm -ql`
# (probe-greenboot.yml, run 35542125710) rather than remembered from an older release.
#
# greenboot 0.16.4 ships exactly three units. This list previously named NINE, six of which do not
# exist in this version — greenboot-task-runner, greenboot-status, greenboot-grub2-set-counter,
# greenboot-grub2-set-success, greenboot-rpm-ostree-grub2-check-fallback, and both redboot units.
# 0.16 collapsed all of that into one binary driven by greenboot-healthcheck.service.
#
# Enabling a unit that does not exist is not a harmless no-op: `auros_enable` dies on it, which is
# how this was caught, and the alternative — tolerating it — would have produced an image where
# nothing arms rollback and every part still looked enabled.
for u in bootc-fetch-apply-updates.timer \
         greenboot-healthcheck.service \
         greenboot-set-rollback-trigger.service; do
  auros_enable "$u"
done

# Enablement is verified against the FILESYSTEM, not against systemctl's exit code: `systemctl
# enable` in a container can no-op and still exit 0. These four are the links that each make one
# specific safety property real, and any of them missing is a silent loss of that property.
assert_link() {
  [ -e "/etc/systemd/system/$1" ] || [ -e "/usr/lib/systemd/system/$1" ] \
    || die "enablement link $1 was not created -- $2"
}
# The assertion DERIVES its expected links from the unit files rather than hardcoding target names.
#
# Hardcoding is what put six nonexistent units in the list above, and it would have done the same
# here: a link like `ostree-finalize-staged.service.requires/greenboot-grub2-set-counter.service`
# names both a unit and a target from a version we are not running. Reading WantedBy and RequiredBy
# out of the unit that is actually installed cannot drift, because it has nothing to drift from.
#
# What stays hardcoded is the part that is genuinely OUR requirement rather than greenboot's: that
# these three units are enabled AT ALL. That list is short, and each entry names the safety property
# it makes real.
assert_unit_enabled() { # unit, consequence-if-missing
  local u="$1" why="$2" n=0 t pair d directive
  # systemd's DIRECTORY suffix and its DIRECTIVE are different words: the directive WantedBy creates a
  # `.wants` directory, and RequiredBy creates `.requires`. Deriving one from the other — which is what
  # this did, producing "WantsBy" and "RequiresBy" — matches nothing, so every unit appeared to declare
  # no install section and the build failed claiming bootc's own timer could not be enabled.
  #
  # They are spelled out as pairs rather than transformed. Two hardcoded words cannot drift; a
  # transformation between two things that only look related can, and did.
  for pair in "wants:WantedBy" "requires:RequiredBy"; do
    d="${pair%%:*}"; directive="${pair##*:}"
    for t in $(sed -n "s/^${directive}=//p" "/usr/lib/systemd/system/$u" 2>/dev/null | tr ' ' '\n'); do
      [ -n "$t" ] || continue
      if [ -e "/usr/lib/systemd/system/$t.$d/$u" ] || [ -e "/etc/systemd/system/$t.$d/$u" ]; then
        n=$((n+1)); found "$u -> $t.$d"
      else
        die "$u declares ${directive}=$t but the link was not created -- $why"
      fi
    done
  done
  [ "$n" -gt 0 ] || die "$u is installed but declares no WantedBy or RequiredBy, so enabling it did nothing -- $why"
}
assert_unit_enabled bootc-fetch-apply-updates.timer        "the machine would never fetch an update"
assert_unit_enabled greenboot-healthcheck.service          "no health check would run, and every boot would be declared good"
assert_unit_enabled greenboot-set-rollback-trigger.service "nothing would arm the rollback trigger and auto-rollback (U3) would silently not exist (D9)"
did "every enablement link verified on disk, derived from the units themselves"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
step "summary"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
found "update path   bootc-fetch-apply-updates.timer (bootc's own unit, enabled by us; Aurora"
found "              preset-enables uupd.timer instead and leaves this one inert)"
found "              boot+3min, then every 6h, 10min jitter -- U1's 20-minute window vs B6's"
found "              3.5 GB-per-machine shared uplink"
found "apply rule    always stage; reboot only with no active user session (apply-policy=when-idle)"
found "rollback      greenboot + GRUB boot_counter, GREENBOOT_MAX_BOOT_ATTEMPTS=2"
found "              two failed boots, rollback on the third. Upstream default is 3."
found "              exactly ONE rollback deployment is retained (D10)"
found "health        4 required (network stack, graphical target, update timer, no new failed"
found "              units) + 3 wanted (signature enforcement, rollback wiring, freshness)"
found "signing       key     /usr/lib/pki/containers/auros.pub"
found "              policy  /etc/containers/policy.json (default reject; $AUROS_SCOPE sigstoreSigned)"
found "              regd    /etc/containers/registries.d/auros.yaml (use-sigstore-attachments)"
found "              install /usr/lib/bootc/install/30-auros.toml (enforce-container-sigpolicy)"
found "check U4      $AUROS_LIBEXEC/verify-enforcement.sh"
did "update agent and signature enforcement installed"

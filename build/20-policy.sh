#!/usr/bin/bash
# 20-policy.sh -- install the Auros policy payload into the image, and activate the base's own mode.
#
# Runs inside the image build, from auros-base/Containerfile, in numeric order with the other
# build/*.sh scripts. Idempotent, -euo pipefail, and says what it did.
#
# ── WHAT THIS SCRIPT PUTS IN THE IMAGE, AND WHY IT IS ALL FOUR MODES ─────────────────────────────
#
# There is exactly ONE base image (spec section 3). So the base cannot BE `locked`, or `kiosk`, or
# any other single mode -- it would stop being one base the moment a second customer wanted a
# different one. What the base carries instead is the whole mechanism:
#
#     /usr/share/auros/policy/        all four modes' file trees, lists and assertions
#     /usr/libexec/auros/apply-policy activate one of them
#     /usr/libexec/auros/assert-policy prove at runtime which one is in force
#
# and a customer recipe selects a mode in its own derived layer with a single line:
#
#     RUN /usr/libexec/auros/apply-policy locked
#
# That is what spec section 6A means by "declarative and switchable per-recipe". The modes are data
# in one image, not four images.
#
# ── THE BASE'S OWN MODE IS `open`, DELIBERATELY ──────────────────────────────────────────────────
#
# Not because open is a default worth having, but because the base image is tested against the full
# check matrix and two of those checks only hold in open: B1 wants a login prompt (kiosk has none by
# design) and B12 wants installing software, joining Wi-Fi, adding a printer and changing the
# language to be reachable through the GUI (locked answers no to three of those on purpose). A base
# stamped anything else would make the matrix lie about one mode or the other.
#
# AUROS_POLICY=<mode> overrides it, which is how CI builds a single-mode image to run B5 against.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# THE CONVENTION: the Containerfile COPYs each script's own directory into /tmp/auros-build/ before
# running the scripts. The fallback to the source tree is for running this by hand outside a build.
# ASSUMPTION, recorded because the Containerfile belongs to another task: the policy directory
# arrives at /tmp/auros-build/policy.
for candidate in "${AUROS_BUILD_DIR:-/tmp/auros-build}/policy" "$SELF/../policy"; do
    if [ -d "$candidate" ]; then SRC="$(cd "$candidate" && pwd)"; break; fi
done
[ -n "${SRC:-}" ] || {
    echo "[20-policy] FATAL: cannot find the policy payload. Looked in ${AUROS_BUILD_DIR:-/tmp/auros-build}/policy and $SELF/../policy." >&2
    exit 1
}

DEST=/usr/share/auros/policy
LIBEXEC=/usr/libexec/auros

echo "[20-policy] policy payload source: $SRC"

# ── 1. the payload ───────────────────────────────────────────────────────────────────────────────
# Removed and recopied rather than merged: a stale mode file left behind from a previous build of a
# renamed mode would be installed by apply-policy and never noticed.
rm -rf "$DEST"
install -d -m 0755 "$DEST"
cp -a "$SRC/." "$DEST/"
chown -R root:root "$DEST"
find "$DEST" -type d -exec chmod 0755 {} +
find "$DEST" -type f -exec chmod 0644 {} +
find "$DEST" -name 'assert.sh' -exec chmod 0755 {} +
# sudoers drop-ins keep 0440 in the payload as well as after installation, so that a copy of the
# payload is never a copy of a file sudo would refuse to read.
find "$DEST" -path '*/sudoers.d/*' -exec chmod 0440 {} +
find "$DEST" -path '*/libexec/auros/*' -exec chmod 0755 {} +
echo "[20-policy] installed the policy payload to $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files, 4 modes)"

# ── 2. the two entry points ──────────────────────────────────────────────────────────────────────
install -d -m 0755 "$LIBEXEC"
install -m 0755 "$SRC/apply-policy"  "$LIBEXEC/apply-policy"
install -m 0755 "$SRC/assert-policy" "$LIBEXEC/assert-policy"
rm -f "$DEST/apply-policy" "$DEST/assert-policy"
echo "[20-policy] installed $LIBEXEC/apply-policy and $LIBEXEC/assert-policy"

# ── 3. weak dependencies, before anything else in this build installs or removes a package ───────
# Recommends: is how a removed package comes back on the NEXT transaction -- including transactions
# in a customer recipe's own layer, which is why it is set globally here rather than passed per
# command. See policy-lib.sh, auros_disable_weak_deps.
# shellcheck source=/dev/null
. "$DEST/lib/policy-lib.sh"
auros_disable_weak_deps

# ── 4. activate the base's mode ──────────────────────────────────────────────────────────────────
MODE="${AUROS_POLICY:-open}"
echo "[20-policy] activating base policy mode: $MODE"
"$LIBEXEC/apply-policy" "$MODE"

# ── 5. say what is now true, in terms the next person can check ──────────────────────────────────
cat <<EOS
[20-policy] ----------------------------------------------------------------
[20-policy] policy layer complete.
[20-policy]   mode stamped on this image : $(cat /usr/lib/auros/policy-mode)
[20-policy]   modes available to recipes : open managed locked kiosk
[20-policy]   a recipe selects one with  : RUN /usr/libexec/auros/apply-policy <mode>
[20-policy]   prove it in a booted VM    : /usr/libexec/auros/assert-policy [--json]
[20-policy]   build report               : /usr/lib/auros/policy/applied.json
[20-policy]   for a school IT reader     : $DEST/README.md and $DEST/<mode>/description.md
[20-policy] ----------------------------------------------------------------
EOS

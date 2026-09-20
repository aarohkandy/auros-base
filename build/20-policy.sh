#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/20-policy.sh
#
# Installs the policy payload into the image and activates the base's own mode.
#
# ── WHY ALL FOUR MODES GO INTO ONE IMAGE ─────────────────────────────────────────────────────────
#
# There is exactly ONE base image (spec §3). So the base cannot BE `locked`, or `kiosk`, or any other
# single mode — it would stop being one base the moment a second customer wanted a different one.
# What the base carries instead is the whole mechanism:
#
#     /usr/share/auros/policy/          all four modes' file trees, lists and assertions
#     /usr/libexec/auros/apply-policy   activate one of them
#     /usr/libexec/auros/assert-policy  prove at runtime which one is in force
#
# and a customer recipe selects a mode in its own derived layer with a single line:
#
#     RUN /usr/libexec/auros/apply-policy locked
#
# That is what spec §6A means by "declarative and switchable per-recipe". Four modes as data in one
# image, not four images. Four images would mean a CVE is four rebuilds, and one rebuild is the thing
# we sell.
#
# ── THE BASE'S OWN MODE IS `open`, DELIBERATELY ──────────────────────────────────────────────────
#
# Not because open is a default worth having, but because the base is tested against the full check
# matrix and two of those checks only hold literally in open: B1 wants a login prompt (kiosk has none
# by design) and B12 wants installing software, joining Wi-Fi, adding a printer and changing the
# language each reachable through the GUI (locked answers no to three of those on purpose). A base
# stamped anything else would make the matrix lie about one mode or the other.
#
# Idempotent, per 00-common.sh's contract: running the whole build twice over the same filesystem
# must produce the same filesystem, because check S7 builds twice and compares content digests.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

. "${AUROS_BUILD_DIR:-/tmp/auros-build}/build/00-common.sh"

SRC="${AUROS_BUILD_DIR}/policy"
DEST=/usr/share/auros/policy
LIBEXEC="${AUROS_LIBEXEC:-/usr/libexec/auros}"

[ -d "$SRC" ] || die "$SRC is missing — the Containerfile's COPY of policy/ did not land. Every mode, every assertion and both entry points live in it; there is nothing to fall back to."

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "the policy payload — four modes as data in one image"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Removed and recopied rather than merged: a stale file left behind from a previous build of a
# renamed mode would be installed by apply-policy and never noticed.
rm -rf "$DEST"
install -d -m 0755 "$DEST"
cp -a "$SRC/." "$DEST/"
chown -R root:root "$DEST"
find "$DEST" -type d -exec chmod 0755 {} +
find "$DEST" -type f -exec chmod 0644 {} +
find "$DEST" -name 'assert.sh'         -exec chmod 0755 {} +
find "$DEST" -path '*/libexec/auros/*' -exec chmod 0755 {} +
# sudoers drop-ins keep 0440 inside the payload as well as after installation, so that a copy of the
# payload is never a copy of a file sudo would silently refuse to read.
find "$DEST" -path '*/sudoers.d/*'     -exec chmod 0440 {} +
did "installed the policy payload to $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files, 4 modes)"
record installed-payload "$DEST"

# The two entry points move out of the payload: one is called by recipes, one by the check matrix,
# and neither should be reachable only through a path that names a mode.
install_file "$SRC/apply-policy"  "$LIBEXEC/apply-policy"  0755
install_file "$SRC/assert-policy" "$LIBEXEC/assert-policy" 0755
rm -f "$DEST/apply-policy" "$DEST/assert-policy"
did "recipes select a mode with: RUN $LIBEXEC/apply-policy <open|managed|locked|kiosk>"
did "the check matrix proves it with: $LIBEXEC/assert-policy   (check B5)"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "activating the base's policy mode"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
MODE="${AUROS_POLICY:-open}"

if [ "$MODE" != open ]; then
  warn "AUROS_POLICY=$MODE — this base is being built as a single-mode image."
  warn "ORDERING HAZARD, and it is real rather than theoretical: build/40-windows-feel.sh runs AFTER"
  warn "this step and installs /etc/xdg/kdeglobals as a whole file, which removes the three KDE Kiosk"
  warn "groups apply-policy merges into it ([KDE Action Restrictions], [KDE Control Module"
  warn "Restrictions], [KDE URL Restrictions]). polkit, sudoers, PAM, dconf and the unit masks are"
  warn "unaffected — the enforcement survives — but the KDE-application restrictions would not."
  warn "Run '$LIBEXEC/apply-policy $MODE' again as the LAST step of this image build, or build the"
  warn "mode in a derived layer as a recipe does, which is the supported path and runs after 40."
fi

found "activating: $MODE"
"$LIBEXEC/apply-policy" "$MODE"
record policy-mode "$MODE"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "what is now true"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
[ -r /usr/lib/auros/policy-mode ] || die "apply-policy did not write /usr/lib/auros/policy-mode — the image has no mode stamp, so check B5 has nothing to assert against"
did "mode stamped on this image : $(cat /usr/lib/auros/policy-mode)"
did "modes available to recipes : open managed locked kiosk"
did "build report               : /usr/lib/auros/policy/applied.json"
found "for a school IT reader    : $DEST/README.md and $DEST/<mode>/description.md"

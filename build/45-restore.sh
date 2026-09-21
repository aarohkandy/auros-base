#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/45-restore.sh
#
# The Linux half of the migration (spec §6C, BLOCKED.md B15, SYSTEM-REVIEW N2): auros-installer's
# cmd/auros-restore and its systemd USER unit, which restores a school's files from the verified
# archive at first login. The archive is the user's only copy by then, so this step installs exactly
# the bytes somebody pinned, or nothing.
#
# PROVENANCE — a pinned artifact with a sha256, not a build. The base never compiles the restore and
# never fetches anything unpinned: build/45-restore.d/restore.pin names each artifact by https URL and
# sha256, and a byte that does not hash to its pin fails the build before it is installed. Compiling
# it here instead (a Go stage from a pinned installer commit) would put a Go toolchain image and a
# module download into the base's supply chain and change the Containerfile while check S7 is being
# investigated on it. The installer's own CI is where the restore is built, tested and proven red.
# The source commit is recorded in the image's build manifest.
#
# THE SWITCH is restore.pin. Empty: this step installs nothing, writes nothing, and says OFF in the
# build log. Half-filled: the build fails. There is no third state.
#
# DERIVED, NOT HARDCODED, and from the file that will actually run: the binary goes where the unit's
# ExecStart= says, and the unit is enabled for exactly the targets its own [Install] WantedBy= names.
# If the installer moves either, the image follows rather than shipping a unit that points at nothing.
# The one fixed choice is the unit DIRECTORY: this is a `systemd --user` unit (it runs as the person
# whose files they are; BLOCKED.md B19), so it lives in /usr/lib/systemd/user.
#
# AUROS_TEST_ROOT is the one seam (D34): unset in a real build, pointed at a scratch tree by
# tests/45-restore.test.sh so the post-install assertions read the tree the test installed into.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

. "${AUROS_BUILD_DIR:-/tmp/auros-build}/build/00-common.sh"
AUROS_STEP="45-restore"

R="${AUROS_TEST_ROOT:-}"
PIN="$AUROS_BUILD_DIR/build/45-restore.d/restore.pin"
USER_UNITS=/usr/lib/systemd/user

step "the Linux-side restore (auros-installer cmd/auros-restore)"

[ -f "$PIN" ] || die "$PIN is missing — it is the restore's on/off switch; put it back (empty = off)"
pin() { sed -n "s/^$1=//p" "$PIN" | tail -1; }
COMMIT="$(pin RESTORE_SOURCE_COMMIT)"
BIN_URL="$(pin RESTORE_BIN_URL)";   BIN_SHA="$(pin RESTORE_BIN_SHA256)"
UNIT_URL="$(pin RESTORE_UNIT_URL)"; UNIT_SHA="$(pin RESTORE_UNIT_SHA256)"

if [ -z "$COMMIT$BIN_URL$BIN_SHA$UNIT_URL$UNIT_SHA" ]; then
  warn "RESTORE IS OFF — $PIN pins nothing, so this image has NO Linux-side restore (BLOCKED.md B15). A machine migrated onto it will not bring anyone's files back from the archive. Nothing was installed."
  exit 0
fi

# ── the pin: all or nothing ──────────────────────────────────────────────────────────────────────
for kv in "RESTORE_SOURCE_COMMIT=$COMMIT" "RESTORE_BIN_URL=$BIN_URL" "RESTORE_BIN_SHA256=$BIN_SHA" \
          "RESTORE_UNIT_URL=$UNIT_URL" "RESTORE_UNIT_SHA256=$UNIT_SHA"; do
  [ -n "${kv#*=}" ] || die "restore.pin is half-filled: ${kv%%=*} is empty. Pin all five or none."
done
printf '%s' "$COMMIT" | grep -qxE '[0-9a-f]{40}' || die "RESTORE_SOURCE_COMMIT is not a 40-hex commit: $COMMIT"
for h in "$BIN_SHA" "$UNIT_SHA"; do
  printf '%s' "$h" | grep -qxE '[0-9a-f]{64}' || die "restore.pin sha256 is not 64 lowercase hex: $h"
done
for u in "$BIN_URL" "$UNIT_URL"; do
  case "$u" in https://*) ;; *) die "restore.pin URL is not https: $u" ;; esac
done
UNIT="$(basename "$UNIT_URL")"
case "$UNIT" in *.service) ;; *) die "RESTORE_UNIT_URL must end in the unit's file name (*.service), got: $UNIT" ;; esac

# ── fetch and verify, before anything is installed ───────────────────────────────────────────────
TMP="$AUROS_BUILD_DIR/restore-fetch"   # inside the build context, so 90-cleanup.sh removes it
mkdir -p "$TMP"
fetch() { # <url> <sha256> <dest>
  curl -fsSL --proto '=https' --retry 3 -o "$3" "$1" || die "could not fetch $1"
  local got; got="$(sha256sum "$3" | awk '{print $1}')"
  [ "$got" = "$2" ] || die "sha256 mismatch for $1: pinned $2, fetched $got — refusing to install bytes nobody pinned"
  did "fetched $1 (sha256 $got, matches the pin)"
}
fetch "$UNIT_URL" "$UNIT_SHA" "$TMP/unit"
fetch "$BIN_URL"  "$BIN_SHA"  "$TMP/bin"

# ── derive the binary's path and the targets from the unit itself ────────────────────────────────
[ "$(grep -c '^ExecStart=' "$TMP/unit" || true)" = 1 ] || die "$UNIT must have exactly one ExecStart= — cannot tell which binary it runs"
EXEC="$(sed -n 's/^ExecStart=//p' "$TMP/unit" | awk '{print $1}')"
case "$EXEC" in
  /usr/*) ;;
  *) die "$UNIT's ExecStart runs '$EXEC'. The image can only ship a binary under /usr (bootc replaces /usr; /etc and /var are machine-local)." ;;
esac
TARGETS="$(sed -n '/^\[Install\]/,/^\[/s/^WantedBy=//p' "$TMP/unit" | tr ' ' '\n' | grep -v '^$' || true)"
[ -n "$TARGETS" ] || die "$UNIT has no WantedBy= in its [Install] section — nothing would ever start it"

# ── install, enable, and prove it ────────────────────────────────────────────────────────────────
install_file "$TMP/bin"  "$EXEC"                0755
install_file "$TMP/unit" "$USER_UNITS/$UNIT"    0644
for t in $TARGETS; do enable_user_unit "$UNIT" "$t"; done

[ -x "$R$EXEC" ] || die "the restore binary is not an executable at $EXEC after install — $UNIT would fail at every login"
[ -f "$R$USER_UNITS/$UNIT" ] || die "$USER_UNITS/$UNIT is missing after install — the restore would never run"
for t in $TARGETS; do
  [ -e "$R$USER_UNITS/$t.wants/$UNIT" ] || die "$UNIT is not enabled for $t — the restore would never run"
done

record restore-source-commit "$COMMIT"
did "restore installed: $EXEC, $USER_UNITS/$UNIT, enabled for: $(printf '%s ' $TARGETS)(from auros-installer $COMMIT)"

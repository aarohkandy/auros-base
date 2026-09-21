#!/usr/bin/env bash
# tests/45-restore.test.sh — build/45-restore.sh: the Linux-side restore, pinned or absent.
#
# The REAL script is executed, unmodified. Its build context (AUROS_BUILD_DIR) is a scratch tree whose
# build/00-common.sh is a small fake library — logging, an install_file that writes under $ROOT —
# plus the REAL enable_user_unit, extracted from build/00-common.sh and rootified. curl is a stub that
# serves fixtures by URL basename, so nothing here touches the network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

S="$REPO/build/45-restore.sh"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
command -v sha256sum >/dev/null 2>&1 || stub "$STUBS" sha256sum <<'SH'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
SH
stub "$STUBS" curl <<'SH'
#!/usr/bin/env bash
# Serves $FIXTURES/<basename of the URL> to the -o path. A missing fixture is a failed download.
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; --proto|--retry) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
[ -f "$FIXTURES/$(basename "$url")" ] || exit 22
cp "$FIXTURES/$(basename "$url")" "$out"
SH
export PATH="$STUBS:$PATH"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

printf '45-restore.sh — the Linux-side restore  (%s)\n' "$T_SED_MODE"

EUU_FN="$(extract_fn "$REPO/build/00-common.sh" enable_user_unit | rootify /usr/lib/systemd/user)"
COMMIT=d3136a7f9bcb10ba34be2276f2dc33b6df908336

# The shape of the real unit at auros-installer d3136a7: a user unit, one ExecStart with an argument,
# WantedBy=graphical-session.target. Its name and paths were read from that file, not guessed.
REAL_UNIT='[Unit]
Description=Bring your files across from your old Windows computer
ConditionPathExists=!%S/auros-restore/done

[Service]
Type=oneshot
ExecStart=/usr/libexec/auros/auros-restore --quiet

[Install]
WantedBy=graphical-session.target'

# setup <root> <unit-body> [install-mode: real|noop] — writes the fixtures and the fake build context.
setup() {
  local root="$1" ctx="$1/ctx"
  mkdir -p "$ctx/build/45-restore.d" "$root/fx"
  printf '%s\n' "$2" > "$root/fx/auros-restore.service"
  printf '\177ELF fake restore binary\n' > "$root/fx/auros-restore-linux-amd64"
  local inst='mkdir -p "$ROOT$(dirname "$2")"; install -m "${3:-0644}" "$1" "$ROOT$2"; did "wrote $2"'
  # noop: the binary's install reports success and writes nothing (the unit still lands, so the
  # failure has to come from the post-install assertion rather than from enable_user_unit).
  [ "${3:-real}" = noop ] && inst='case "$2" in *.service) mkdir -p "$ROOT$(dirname "$2")"; install -m "${3:-0644}" "$1" "$ROOT$2" ;; esac; did "wrote $2"'
  cat > "$ctx/build/00-common.sh" <<LIB
step()  { echo "STEP \$*"; }
did()   { echo "DID \$*"; }
found() { echo "FOUND \$*"; }
warn()  { echo "WARN \$*"; }
die()   { echo "DIE \$*" >&2; exit 1; }
record(){ printf '%s\t%s\n' "\$1" "\${2-}" >> "\$ROOT/manifest"; }
auros_stamp(){ :; }
install_file() { $inst; }
$EUU_FN
LIB
}
pin() { # <root> <commit> <bin-url> <bin-sha> <unit-url> <unit-sha>
  printf 'RESTORE_SOURCE_COMMIT=%s\nRESTORE_BIN_URL=%s\nRESTORE_BIN_SHA256=%s\nRESTORE_UNIT_URL=%s\nRESTORE_UNIT_SHA256=%s\n' \
    "$2" "$3" "$4" "$5" "$6" > "$1/ctx/build/45-restore.d/restore.pin"
}
good_pin() { # <root> — every field correct for the fixtures
  pin "$1" "$COMMIT" https://example.invalid/r/auros-restore-linux-amd64 "$(sha "$1/fx/auros-restore-linux-amd64")" \
    "https://example.invalid/raw/$COMMIT/packaging/systemd/auros-restore.service" "$(sha "$1/fx/auros-restore.service")"
}
run45() { ROOT="$1" AUROS_TEST_ROOT="$1" AUROS_BUILD_DIR="$1/ctx" AUROS_WRITTEN_LIST="$1/written" FIXTURES="$1/fx" bash "$S"; }

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the switch — off is loud and installs nothing; the shipped pin is off"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(newroot)"; setup "$R" "$REAL_UNIT"
cp "$REPO/build/45-restore.d/restore.pin" "$R/ctx/build/45-restore.d/restore.pin"
run_check restore.switch green "the pin as committed (all empty)" -- run45 "$R"
assert_has "says RESTORE IS OFF in the build log" "RESTORE IS OFF" "$T_LAST_OUT"
assert_nofile "installs no binary"   "$R/usr/libexec/auros/auros-restore"
assert_nofile "installs no unit"     "$R/usr/lib/systemd/user/auros-restore.service"
assert_nofile "records nothing in the manifest" "$R/manifest"

R="$(newroot)"; setup "$R" "$REAL_UNIT"
run_check restore.switch red "the pin file is missing" -- run45 "$R"
R="$(newroot)"; setup "$R" "$REAL_UNIT"; pin "$R" "$COMMIT" "" "" "" ""
run_check restore.switch red "half-filled: a commit and nothing else" -- run45 "$R"
assert_has "names the empty field" "RESTORE_BIN_URL is empty" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the pin — what counts as pinned"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"
run_check restore.pin green "a well-formed pin" -- run45 "$R"
bad_pin() { # <sed expression applied to a good pin>
  local root; root="$(newroot)"; setup "$root" "$REAL_UNIT"; good_pin "$root"
  sed -i "$1" "$root/ctx/build/45-restore.d/restore.pin"; run45 "$root"
}
run_check restore.pin red "a branch name instead of a commit" -- bad_pin 's/^RESTORE_SOURCE_COMMIT=.*/RESTORE_SOURCE_COMMIT=feat-linux-restore/'
run_check restore.pin red "an http:// binary URL"              -- bad_pin 's#^RESTORE_BIN_URL=https#RESTORE_BIN_URL=http#'
run_check restore.pin red "a short sha256"                     -- bad_pin 's/^\(RESTORE_BIN_SHA256=.\{10\}\).*/\1/'
run_check restore.pin red "a unit URL that is not a .service"  -- bad_pin 's#auros-restore.service$#latest#'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the hash — bytes nobody pinned are never installed"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"
run_check restore.hash green "both artifacts match their pins" -- run45 "$R"
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"; printf 'tampered\n' >> "$R/fx/auros-restore-linux-amd64"
run_check restore.hash red "the binary changed after it was pinned" -- run45 "$R"
assert_has "says sha256 mismatch" "sha256 mismatch" "$T_LAST_OUT"
assert_nofile "and installed nothing" "$R/usr/libexec/auros/auros-restore"
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"; printf '# edited\n' >> "$R/fx/auros-restore.service"
run_check restore.hash red "the unit changed after it was pinned" -- run45 "$R"
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"; rm "$R/fx/auros-restore-linux-amd64"
run_check restore.hash red "the binary cannot be downloaded" -- run45 "$R"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "derived from the unit — the binary goes where ExecStart says, links go where WantedBy says"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(newroot)"; setup "$R" "$REAL_UNIT"; good_pin "$R"
run_check restore.derive green "the real unit's shape" -- run45 "$R"
assert_file "binary at the ExecStart path" "$R/usr/libexec/auros/auros-restore"
assert_file "unit in the user unit directory" "$R/usr/lib/systemd/user/auros-restore.service"
assert_symlink_to "enabled for graphical-session.target, relative link" \
  "$R/usr/lib/systemd/user/graphical-session.target.wants/auros-restore.service" "../auros-restore.service"
assert_has "the source commit is in the manifest" "restore-source-commit	$COMMIT" "$(cat "$R/manifest" 2>/dev/null)"
run_check restore.derive green "idempotent: a second run over the same tree" -- run45 "$R"

# Nothing about graphical-session.target or /usr/libexec is baked into the step: move them in the unit
# and the image follows.
MOVED="$(printf '%s\n' "$REAL_UNIT" | sed -e 's#^ExecStart=.*#ExecStart=/usr/bin/auros-restore#' -e 's#^WantedBy=.*#WantedBy=default.target graphical-session.target#')"
R="$(newroot)"; setup "$R" "$MOVED"; good_pin "$R"
run_check restore.derive green "a unit that moved its binary and added a target" -- run45 "$R"
assert_file "binary followed ExecStart" "$R/usr/bin/auros-restore"
assert_file "linked for default.target too" "$R/usr/lib/systemd/user/default.target.wants/auros-restore.service"

R="$(newroot)"; setup "$R" "$(printf '%s\n' "$REAL_UNIT" | sed '/^WantedBy=/d')"; good_pin "$R"
run_check restore.derive red "a unit with no WantedBy= — nothing would ever start it" -- run45 "$R"
R="$(newroot)"; setup "$R" "$(printf '%s\n' "$REAL_UNIT" | sed 's#^ExecStart=.*#ExecStart=/var/lib/auros-restore#')"; good_pin "$R"
run_check restore.derive red "ExecStart outside /usr — not something an image can ship" -- run45 "$R"
R="$(newroot)"; setup "$R" "$(printf '%s\nExecStart=/usr/bin/true\n' "$REAL_UNIT")"; good_pin "$R"
run_check restore.derive red "two ExecStart= lines — which binary is the restore?" -- run45 "$R"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the assertions — an install that says it worked and did not"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
R="$(newroot)"; setup "$R" "$REAL_UNIT" real; good_pin "$R"
run_check restore.assert green "a real install" -- run45 "$R"
R="$(newroot)"; setup "$R" "$REAL_UNIT" noop; good_pin "$R"
run_check restore.assert red "the binary's install reports success and writes nothing" -- run45 "$R"
assert_has "the post-install assertion is what refused it" "not an executable" "$T_LAST_OUT"

t_finish "45-restore.sh"

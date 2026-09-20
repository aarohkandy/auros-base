#!/usr/bin/env bash
# Every systemd unit our build scripts ENABLE must be one the image actually ships.
#
# Three consecutive base builds failed on unit names from an older greenboot. Each failure cost a
# full image build — twelve minutes of CI — to learn one name. This catches the same mistake in a
# second, on a laptop, before anything is pushed.
#
# It deliberately checks only ENABLEMENT, not every mention. A comment or a fallback path in a
# capability list may legitimately name a unit from another version; enabling one is always a bug,
# because `auros_enable` dies on a unit that is not there.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KNOWN="$HERE/units.known"
PASS=0; FAIL=0

# No `mapfile` here: macOS ships bash 3.2 and this test has to run on the machine where the mistake
# is made, not only in CI. A guard that only runs in CI costs a twelve-minute round trip to consult.
[ -f "$KNOWN" ] || { echo "units.known is missing — cannot verify anything, failing closed"; exit 2; }
KNOWN_LIST=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$KNOWN")
[ -n "$KNOWN_LIST" ] || { echo "units.known is empty — failing closed rather than passing vacuously"; exit 2; }

is_known () { printf '%s\n' "$KNOWN_LIST" | grep -qxF "$1"; }

# The enable list: the `for u in ... ; do auros_enable` block.
ENABLED=$(sed -n '/^for u in /,/auros_enable/p' "$HERE/build/30-update-agent.sh" \
    | grep -oE '[a-z0-9@._-]+\.(service|timer|target|path|socket)' | sort -u)
ASSERTED=$(grep -oE 'assert_unit_enabled [a-z0-9@._-]+\.(service|timer|target|path|socket)' "$HERE/build/30-update-agent.sh" \
    | awk '{print $2}' | sort -u)
ALL=$(printf '%s\n%s\n' "$ENABLED" "$ASSERTED" | grep -v '^$' | sort -u)

echo "units referenced for enablement:"
if [ -z "$ENABLED" ]; then
  echo "  FAIL  parsed ZERO units from the enable block — the parser has drifted from the script,"
  echo "        so this test would pass on anything. That is worse than a wrong unit name."
  FAIL=$((FAIL+1))
fi
for u in $ALL; do
  [ -n "$u" ] || continue
  if is_known "$u"; then printf '  ok    %s\n' "$u"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s is not in units.known\n' "$u"
    printf '        Enabling a unit the image does not ship fails the build after a full image build.\n'
    printf '        If the package really does ship it, add it to units.known with the rpm -ql run that\n'
    printf '        proves it. Do not add it because a build wanted it.\n'
    FAIL=$((FAIL+1))
  fi
done

# The guard must be able to go red. Prove it rather than assuming.
if is_known 'greenboot-task-runner.service'; then
  echo "  FAIL  a unit known NOT to exist in greenboot 0.16.4 is listed as known — units.known is wrong"
  FAIL=$((FAIL+1))
else
  echo "  ok    a known-absent unit (greenboot-task-runner.service) is correctly rejected"
  PASS=$((PASS+1))
fi


# ── The install-directive parse ─────────────────────────────────────────────────────────────────
# systemd's DIRECTORY suffix and its DIRECTIVE are different words: WantedBy creates `.wants`,
# RequiredBy creates `.requires`. Deriving one from the other produced "WantsBy" and "RequiresBy",
# which match nothing — so every unit looked like it declared no install section, and the build
# failed claiming bootc's own timer could not be enabled. A real unit file is the only thing that
# would have caught it, so here is one.
echo
echo "install-directive parse:"
UT=$(mktemp -d); mkdir -p "$UT/usr/lib/systemd/system"
printf '[Unit]\nDescription=t\n\n[Install]\nWantedBy=timers.target\n'          > "$UT/usr/lib/systemd/system/x.timer"
printf '[Install]\nRequiredBy=ostree-finalize-staged.service\n'                  > "$UT/usr/lib/systemd/system/y.service"
printf '[Unit]\nDescription=no install section at all\n'                          > "$UT/usr/lib/systemd/system/z.service"

parse () { sed -n "s/^$2=//p" "$UT/usr/lib/systemd/system/$1" 2>/dev/null; }
expect () { # file, directive, expected
  local got; got=$(parse "$1" "$2")
  if [ "$got" = "$3" ]; then printf '  ok    %-12s %-10s -> %s\n' "$1" "$2" "${3:-<nothing>}"; PASS=$((PASS+1))
  else printf '  FAIL  %-12s %-10s -> %s (want %s)\n' "$1" "$2" "${got:-<nothing>}" "${3:-<nothing>}"; FAIL=$((FAIL+1)); fi
}
expect x.timer   WantedBy    timers.target
expect y.service RequiredBy  ostree-finalize-staged.service
expect z.service WantedBy    ""
# The exact bug: the wrong spellings must find nothing, so a future "clever" derivation goes red here.
expect x.timer   WantsBy     ""
expect y.service RequiresBy  ""
rm -rf "$UT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

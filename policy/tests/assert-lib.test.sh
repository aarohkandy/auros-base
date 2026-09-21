#!/usr/bin/env bash
# ==================================================================================================
# assert-lib.test.sh — prove the runtime assertion primitives can go RED, and for the right reason.
#
# D19: "a step that cannot fail is not a check." An audit found two ways this library was decoration:
#
#   1. Several attempts in the shared suites fail for `aurosprobe` on an OPEN image too — it is a
#      sessionless system account in no privileged group, /etc is root-owned and /usr is read-only —
#      so their failure under `locked` proved nothing. They are now labelled corroborating, and
#      a_pk_not_hard_denied is the negative control that goes RED if the discriminating half ever
#      stops discriminating.
#   2. The KDE-Kiosk half of `locked` had NOTHING attempting it. a_kde_door now attempts it by
#      asking a KDE application to run a script and looking for the marker the script leaves.
#
# Both are tested here, in both directions, against stubs. Nothing touches the host.
# ==================================================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/assert-lib.sh"
[ -r "$LIB" ] || { echo "cannot find lib/assert-lib.sh"; exit 2; }

PASS=0; FAILED=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED+1)); if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/        /'; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# A stub KDE application. `konsole -e <script>` runs the script when the door is open and refuses
# when $KDE_DOOR=shut — which is what KAuthorized("shell_access") does on a locked image.
cat > "$BIN/konsole" <<'EOS'
#!/usr/bin/env bash
if [ "${KDE_DOOR:-open}" = shut ]; then echo "You do not have permission to open a terminal" >&2; sleep 30; fi
[ "${1:-}" = "-e" ] && exec "$2"
exit 0
EOS
cat > "$BIN/kioclient6" <<'EOS'
#!/usr/bin/env bash
if [ "${KDE_DOOR:-open}" = shut ]; then echo "refused" >&2; sleep 30; fi
[ "${1:-}" = "exec" ] && exec "$2"
exit 0
EOS
# A stub pkcheck whose answer comes from $PK_RC, so the three polkit judgements can be driven.
cat > "$BIN/pkcheck" <<'EOS'
#!/usr/bin/env bash
[ "${PK_RC:-1}" = 0 ] || echo "stub pkcheck: answer ${PK_RC:-1}" >&2
exit "${PK_RC:-1}"
EOS
# A stub pkaction: the live authority's enumeration. $PKACTION=dead fails it as a dead polkitd would.
# org.example.gone is the one id it never lists -- an action no installed mechanism registers.
cat > "$BIN/pkaction" <<'EOS'
#!/usr/bin/env bash
[ "${PKACTION:-live}" = dead ] && { echo 'Error enumerating actions: Cannot connect' >&2; exit 1; }
printf '%s\n' org.auros.policy.control-allow org.example.action org.freedesktop.policykit.exec \
    org.freedesktop.NetworkManager.enable-disable-network ${PK_EXTRA:-}
EOS
# A stub id that reports $ID_GROUPS for -nG and defers to the real one otherwise.
cat > "$BIN/id" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = -nG ] && [ -n "${ID_GROUPS:-}" ]; then echo "$ID_GROUPS"; exit 0; fi
exec /usr/bin/id "$@"
EOS
# A stub dbus-send that enforces what the stock system-bus policy enforces for an unprivileged sender
# (measured on dbus-broker 37 and dbus-daemon 1.16, Fedora 43): methods on the org.freedesktop.DBus
# interface of the driver are allowed, org.freedesktop.DBus.Peer.Ping is refused. $BUS=dead refuses
# everything, as a bus that is really not there would.
cat > "$BIN/dbus-send" <<'EOS'
#!/usr/bin/env bash
if [ "${BUS:-live}" = dead ]; then
    echo 'Failed to open connection to "system" message bus: Connection refused' >&2; exit 1
fi
for a in "$@"; do case "$a" in
    org.freedesktop.DBus.Peer.*) echo 'Error org.freedesktop.DBus.Error.AccessDenied: Sender is not authorized to send message' >&2; exit 1 ;;
esac; done
echo 'method return'; exit 0
EOS
# macOS has no coreutils `timeout`, which every attempt primitive in the library uses. The image
# does (coreutils is in the protected set), so this stub is a host-portability shim for the test and
# not a change to what is being tested: it reproduces the exit-124-on-timeout contract the library
# relies on.
if ! command -v timeout >/dev/null 2>&1; then
cat > "$BIN/timeout" <<'EOS'
#!/usr/bin/env bash
secs=$1; shift
"$@" &
pid=$!
# The watchdog must not hold the caller's stdout: `kill "$watchdog"` stops the subshell but not the
# sleep inside it, and an orphaned sleep keeping a $( ) pipe open made every call wait the full
# timeout — 1407 s for this suite on macOS.
( sleep "$secs"; kill -9 "$pid" 2>/dev/null; exit 0 ) >/dev/null 2>&1 </dev/null & watchdog=$!
wait "$pid"; rc=$?
kill "$watchdog" 2>/dev/null
[ "$rc" -ge 128 ] && rc=124
exit "$rc"
EOS
fi
chmod 0755 "$BIN"/*
export ID_GROUPS="${ID_GROUPS:-aurosprobe}"  # never the host user's own groups
export PATH="$BIN:$PATH"
export AUROS_KDE_SETTLE=3 AUROS_ASSERT_TIMEOUT=6

# shellcheck disable=SC1090
. "$LIB"

reset() { A_PASS=0; A_FAIL=0; A_LINES=(); A_CORROBORATING=(); A_CONTROL_DISCRIMINATING=(); A_CONTROL_NON_DISCRIMINATING=(); }
last()  { printf '%s' "${A_LINES[*]: -1}"; }

echo "── a_kde_door: the attempt is capable of SUCCEEDING, which is what makes a refusal evidence ─"
reset; KDE_DOOR=open a_kde_door kde.konsole open konsole "konsole -e <script>" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "open image + open door => pass" || no "open image + open door => pass" "$(last)"

reset; KDE_DOOR=shut a_kde_door kde.konsole open konsole "konsole -e <script>" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "open image + SHUT door => FAIL (the control catches a probe that can never succeed)" \
                  || no "open image + SHUT door => FAIL" "$(last)"
grep -q 'artefact of the probe' <<<"$(last)" \
    && ok "  ...and says every KAuthorized denial elsewhere would be an artefact" \
    || no "  ...and says every KAuthorized denial elsewhere would be an artefact" "$(last)"

echo "── a_kde_door: locked ──────────────────────────────────────────────────────────────────────"
reset; KDE_DOOR=shut a_kde_door kde.konsole shut konsole "konsole -e <script>" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "locked + shut door => pass" || no "locked + shut door => pass" "$(last)"

reset; KDE_DOOR=open a_kde_door kde.konsole shut konsole "konsole -e <script>" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "locked + OPEN door => FAIL — a shell ran through konsole" || no "locked + OPEN door => FAIL" "$(last)"
grep -q 'kdeglobals' <<<"$(last)" \
    && ok "  ...and names the kdeglobals ordering hazard as the usual cause" \
    || no "  ...and names the kdeglobals ordering hazard as the usual cause" "$(last)"

echo "── a_kde_door: a missing binary is only acceptable when the mode removed it ────────────────"
reset; a_kde_door kde.missing shut /nonexistent-kde-binary "a door that is gone" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "expect=shut + absent binary => pass (the door does not exist)" || no "expect=shut + absent binary => pass" "$(last)"
reset; a_kde_door kde.missing open /nonexistent-kde-binary "a door that is gone" -- -e @SCRIPT@ >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "expect=open + absent binary => FAIL (the control cannot establish anything)" || no "expect=open + absent binary => FAIL" "$(last)"

echo "── a_pk_not_hard_denied: the negative control that stops the polkit half from rotting ──────"
for rc in 0 2; do
    reset; PK_RC=$rc a_pk_not_hard_denied ctl org.example.action >/dev/null 2>&1
    [ "$A_FAIL" = 0 ] && ok "open image answers pkcheck $rc => control passes" || no "open image answers pkcheck $rc => control passes" "$(last)"
done
reset; PK_RC=1 a_pk_not_hard_denied ctl org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "open image answers pkcheck 1 => control FAILS" || no "open image answers pkcheck 1 => control FAILS" "$(last)"
grep -q 'artefact of the probe subject' <<<"$(last)" \
    && ok "  ...and says a locked denial of that action would be an artefact" \
    || no "  ...and says a locked denial of that action would be an artefact" "$(last)"

echo "── the locked/managed distinction is still enforced ────────────────────────────────────────"
# pkcheck.c: 2 is the challenge ("requires authentication and -u wasn't passed"), 3 is "dismissed",
# which needs -u and so never happens here. Reading 3 as the challenge made every auth_admin action an
# "error" in every mode.
reset; PK_RC=2 a_pk_hard_deny x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "locked rejects pkcheck 2 (that is managed behaviour)" || no "locked rejects pkcheck 2" "$(last)"
grep -q "managed' behaviour" <<<"$(last)" && ok "  ...and calls it managed behaviour, not an error" || no "  ...and calls it managed behaviour, not an error" "$(last)"
reset; PK_RC=2 a_pk_admin_only x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "managed accepts pkcheck 2 (an administrator could authorise this)" || no "managed accepts pkcheck 2" "$(last)"
reset; PK_RC=3 a_pk_admin_only x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "managed does NOT accept pkcheck 3 (dismissed) as an answer" || no "managed does not accept pkcheck 3" "$(last)"
reset; PK_RC=0 a_pk_admin_only x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "managed rejects pkcheck 0" || no "managed rejects pkcheck 0" "$(last)"

echo "── a_controls: the preconditions, against a bus that behaves like the real system bus ───────"
# Run 35566336512: B5 aborted in 56 ms on the first real boot, because the bus probe was Peer.Ping,
# which the stock system-bus policy refuses to every unprivileged sender. The abort said nothing about
# WHICH precondition failed, because the reason sat above the three lines B5 copies into its detail.
ctl() { ( a_controls ) 2>&1; }
out="$(PK_RC=0 ctl)"; rc=$?
[ "$rc" = 0 ] && ok "a live bus that refuses Peer.Ping but answers the driver => controls pass" \
              || no "a live bus that refuses Peer.Ping => controls pass" "$out"
out="$(BUS=dead PK_RC=0 ctl)"; rc=$?
[ "$rc" = 1 ] && ok "a dead bus => ABORT (never a pass)" || no "a dead bus => ABORT" "$out"
grep -q 'RESULT: fail (assertion aborted.*D-Bus is not reachable' <<<"$(tail -3 <<<"$out")" \
    && ok "  ...and the precondition is named in the last three lines, which is all B5 keeps" \
    || no "  ...and the precondition is named in the last three lines" "$out"
grep -q 'Connection refused' <<<"$(tail -3 <<<"$out")" \
    && ok "  ...with what dbus-send actually said" || no "  ...with what dbus-send actually said" "$out"
out="$(PK_RC=127 ctl)"; rc=$?
[ "$rc" = 1 ] && ok "control-allow not authorised => ABORT (never a pass)" || no "control-allow not authorised => ABORT" "$out"
grep -q 'control-allow returned pkcheck 127 (stub pkcheck: answer 127)' <<<"$(tail -3 <<<"$out")" \
    && ok "  ...naming the pkcheck answer and its message in the last three lines" \
    || no "  ...naming the pkcheck answer and its message" "$out"

echo "── an unregistered action (run 35616444839: PackageKit is not on this base) ───────────────"
reset; PK_RC=127 a_deny hard pkg.gone org.example.gone >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "locked + action polkit does not enumerate => pass" || no "locked + unregistered => pass" "$(last)"
[ "${#A_CORROBORATING[@]}" = 1 ] && ok "  ...counted as corroborating, never primary" || no "  ...counted as corroborating"
reset; PK_RC=127 a_deny control pkg.gone org.example.gone >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && grep -q '^note|control.pkg.gone|.*not registered' <<<"$(last)" \
    && ok "open control + unregistered => a note, not a failure" || no "open control + unregistered => note" "$(last)"
reset; PKACTION=dead PK_RC=127 a_deny hard pkg.gone org.example.gone >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "pkaction cannot enumerate + pkcheck 127 => FAIL (an error is never absence)" || no "dead pkaction + 127 => FAIL" "$(last)"
reset; PK_RC=127 a_deny control x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "a REGISTERED action answering 127 => FAIL (an error is not an answer)" || no "registered + 127 => FAIL" "$(last)"

echo "── the probe subject is not an administrator ───────────────────────────────────────────────"
out="$(ID_GROUPS='auros wheel' PK_RC=0 ctl)"; rc=$?
[ "$rc" = 1 ] && grep -q 'is in wheel' <<<"$(tail -3 <<<"$out")" \
    && ok "a subject in wheel => ABORT, named in the last three lines" || no "a subject in wheel => ABORT" "$out"
out="$(ID_GROUPS='aurosprobe' PK_RC=0 ctl)"; rc=$?
[ "$rc" = 0 ] && ok "a subject in no admin group => controls pass" || no "a non-admin subject => controls pass" "$out"
AGENT="$HERE/../../matrix/run/guest/auros-matrix-agent.sh"
if grep -q runuser <<<"$(grep -E '"\$ASSERT" "\$POLICY_MODE"' "$AGENT")"; then
    no "B5 runs assert-policy via runuser as the harness's wheel user, so it never drops to aurosprobe"
else
    ok "B5 runs assert-policy as root, so assert-policy itself drops to aurosprobe"
fi

echo "── a_suite_accounts: A4 shows the Users page to aurosadmin, so polkit must stop the pupil ───"
export PK_EXTRA=org.freedesktop.accounts.user-administration
reset; PK_RC=1 a_suite_accounts hard >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "locked: user-administration refused outright => pass" || no "locked: refused outright => pass" "$(last)"
reset; PK_RC=2 a_suite_accounts hard >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "locked: user-administration answerable with a password => FAIL" || no "locked: answerable => FAIL" "$(last)"
reset; PK_RC=2 a_suite_accounts admin >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "managed: user-administration needs the IT password => pass" || no "managed: needs the IT password => pass" "$(last)"
reset; PK_RC=0 a_suite_accounts admin >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "managed: a pupil AUTHORISED to manage accounts => FAIL" || no "managed: pupil authorised => FAIL" "$(last)"
reset; PK_RC=1 a_suite_accounts control >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "open: refused outright on the control => FAIL (a locked refusal would not be ours)" || no "open control: refused => FAIL" "$(last)"
unset PK_EXTRA

echo "── a_deny refuses to guess ─────────────────────────────────────────────────────────────────"
reset; a_deny nonsense x org.example.action >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "an unknown level is a FAIL, not a silent default" || no "an unknown level is a FAIL" "$(last)"

echo "── evidence classification: session-dependent actions never red the base on a guess ────────"
reset; PK_RC=1 a_deny control net.enable org.freedesktop.NetworkManager.enable-disable-network session-dependent >/dev/null 2>&1
[ "$A_FAIL" = 0 ] && ok "a session-dependent action answering 1 on open is RECORDED, not a base failure" || no "session-dependent answering 1 is recorded" "$(last)"
[ "${#A_CONTROL_NON_DISCRIMINATING[@]}" = 1 ] && ok "  ...and lands in the non-discriminating list" || no "  ...and lands in the non-discriminating list"
reset; PK_RC=2 a_deny control net.enable org.freedesktop.NetworkManager.enable-disable-network session-dependent >/dev/null 2>&1
grep -q 'PROMOTE' <<<"$(last)" && ok "  ...and says PROMOTE when the measurement shows it DOES discriminate" || no "  ...says PROMOTE" "$(last)"
reset; PK_RC=1 a_deny control root.pkexec-policy org.freedesktop.policykit.exec >/dev/null 2>&1
[ "$A_FAIL" = 1 ] && ok "a PRIMARY action answering 1 on open still FAILS the control" || no "a primary action answering 1 still fails" "$(last)"
reset; PK_RC=1 a_deny hard net.enable org.freedesktop.NetworkManager.enable-disable-network session-dependent >/dev/null 2>&1
[ "${#A_CORROBORATING[@]}" = 1 ] && ok "under locked it is counted as corroborating, not primary" || no "under locked it is corroborating"

echo "── the update timer list is shared, and includes uupd (D22) ───────────────────────────────"
grep -qx 'uupd.timer' <<<"$(printf '%s\n' "${A_UPDATE_TIMERS[@]}")" \
    && ok "A_UPDATE_TIMERS includes uupd.timer" || no "A_UPDATE_TIMERS includes uupd.timer"
if grep -qE "for t in [^\"]*(bootc-fetch|rpm-ostreed)" "$HERE/../open/assert.sh"; then
    no "open/assert.sh still keeps its own hand-written timer list"
else
    ok "open/assert.sh iterates A_UPDATE_TIMERS rather than a second copy"
fi
grep -q 'A_UPDATE_TIMERS' "$HERE/../open/assert.sh" \
    && ok "open/assert.sh references the shared array by name" || no "open/assert.sh references the shared array by name"

echo "── corroborating attempts are declared as such ─────────────────────────────────────────────"
reset; a_corroborate c1 "a thing that fails everywhere" -- /usr/bin/false >/dev/null 2>&1
[ "${#A_CORROBORATING[@]}" = 1 ] && ok "a_corroborate records the id for the a_finish summary" || no "a_corroborate records the id"
grep -q 'corroborating' <<<"$(last)" && ok "  ...and labels the line" || no "  ...and labels the line" "$(last)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]

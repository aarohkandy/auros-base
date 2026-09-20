#!/usr/bin/bash
# kiosk/assert.sh -- prove policy mode KIOSK is in force, inside a booted VM. Check B5.
#
# Kiosk asserts everything locked asserts, and then the claim that only kiosk makes:
#
#     there is no desktop on this machine, and no sequence of keystrokes at it ends in a prompt.
#
# That claim is checked three separate times by three separate mechanisms, because it is the one
# claim in the whole product a customer can disprove by pressing a key:
#
#   apply-policy  fails the BUILD if any binary in absent-binaries.list survives the removal pass.
#   check S9      asserts the same list against the OCI image, statically, with no VM.
#   this file     asserts it again inside the running machine, where symlinks, PATH and a live
#                 filesystem can disagree with what the image layer looked like.
#
# HARNESS NOTE, flagged because it changes how B5 has to be run for this mode: a kiosk image has
# getty masked and no display manager, so there is no console to drive this from. The matrix has to
# reach the VM over ssh or the QEMU guest agent for the kiosk profile. There is no way around that
# which does not also put a login prompt on the machine, which would defeat the mode.
. /usr/share/auros/policy/lib/assert-lib.sh "$@"

printf 'Auros policy assertion: KIOSK\n'
printf 'as %s (uid %s) on %s\n\n' "$(id -un)" "$(id -u)" "$(uname -n)"

a_controls
a_expect_mode kiosk

printf '\n-- the canary: is our rule file actually loaded? --------------------------------------\n'
a_pk_hard_deny "canary.rules-loaded" org.auros.policy.control-deny

printf '\n-- there is no desktop on this machine --------------------------------------------------\n'
# Read from the shipped list rather than repeating it here: one list, checked by the build, by S9
# and by this file. A binary added to the list is immediately checked in all three places.
LIST=/usr/share/auros/policy/kiosk/absent-binaries.list
if [ ! -r "$LIST" ]; then
    a_bad "shell.list" "$LIST is missing from the image, so the absence claim cannot be checked against the list the build used"
else
    while IFS= read -r b; do
        b="${b%%#*}"; b="${b//[[:space:]]/}"
        [ -n "$b" ] || continue
        a_absent "shell.absent.$b" "$b"
    done < "$LIST"
fi

printf '\n-- there is no way to a second session --------------------------------------------------\n'
# chvt is the direct attempt: if the VT switch works, the compositor was started with cage -s and
# Ctrl+Alt+F2 leaves the kiosk. See auros-kiosk-session for why -s is deliberately not passed.
if command -v chvt >/dev/null 2>&1; then
    a_must_fail "session.chvt" "chvt 2 (switch to another virtual terminal)" -- chvt 2
else
    a_ok "session.chvt" "chvt is absent from the image"
fi
for u in 'getty@tty1.service' 'getty@tty2.service' 'serial-getty@ttyS0.service' 'debug-shell.service'; do
    state="$(systemctl is-enabled "$u" 2>&1 || true)"
    case "$state" in
        masked*)   a_ok  "session.$u" "$u is masked" ;;
        *"No such file"*|not-found*) a_ok "session.$u" "$u does not exist on this image" ;;
        *)         a_bad "session.$u" "$u is '$state' -- a text console on a kiosk machine is a way past the application for anyone holding any credentials" ;;
    esac
done
dm="$(systemctl is-enabled display-manager.service 2>&1 || true)"
case "$dm" in
    masked*|*"No such file"*|not-found*) a_ok "session.display-manager" "display-manager.service is $dm" ;;
    *) a_bad "session.display-manager" "display-manager.service is '$dm' on a kiosk image" ;;
esac

printf '\n-- the application is actually running ---------------------------------------------------\n'
# An image with the desktop removed and no application running is not a kiosk, it is a brick that
# passes every check which only looks at what was deleted. This block is what stops a green S9 from
# being mistaken for a working product.
if systemctl is-active --quiet auros-kiosk.service; then
    a_ok "app.service" "auros-kiosk.service is active"
else
    a_bad "app.service" "auros-kiosk.service is $(systemctl is-active auros-kiosk.service 2>&1 || true) -- the machine has no desktop AND no application"
fi
COMP=""
[ -r /usr/lib/auros/policy/kiosk-compositor ] && COMP="$(cat /usr/lib/auros/policy/kiosk-compositor)"
if [ -z "$COMP" ]; then
    a_bad "app.compositor-record" "no compositor was recorded at build time"
elif pgrep -u auroskiosk -x "$COMP" >/dev/null 2>&1; then
    a_ok "app.compositor" "the recorded compositor ($COMP) is running as auroskiosk"
else
    a_bad "app.compositor" "the build recorded '$COMP' but no such process is running as auroskiosk"
fi
if [ -r /etc/auros/kiosk.conf ] && grep -q '^KIOSK_EXEC=".\+"' /etc/auros/kiosk.conf; then
    a_ok "app.configured" "an application is configured: $(sed -n 's/^KIOSK_EXEC="\(.*\)"$/\1/p' /etc/auros/kiosk.conf | head -c 120)"
else
    a_bad "app.configured" "/etc/auros/kiosk.conf names no application"
fi

printf '\n-- the account the application runs as has nothing ---------------------------------------\n'
shell="$(getent passwd auroskiosk | cut -d: -f7)"
case "$shell" in
    */nologin|*/false) a_ok "app.account-shell" "auroskiosk has $shell as its shell" ;;
    "")                a_bad "app.account-shell" "the auroskiosk account does not exist" ;;
    *)                 a_bad "app.account-shell" "auroskiosk has a real shell ($shell) -- anything that reaches this account reaches a prompt" ;;
esac

a_suite_no_root            hard
a_suite_no_software        hard
a_suite_no_network_change  hard
a_suite_update_timer       hard
a_suite_policy_immutable

printf '\n-- what kiosk still guarantees, same as every other mode --------------------------------\n'
a_must_succeed "floor.session" "the probe account can run an ordinary command" -- /usr/bin/id

a_finish kiosk

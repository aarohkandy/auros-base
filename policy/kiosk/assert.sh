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
# WHAT THIS BLOCK USED TO CLAIM, AND WHY THAT CLAIM IS GONE:
#
#   It ran `chvt 2` and inferred from the failure that the compositor had been started without
#   cage's `-s`. Both halves were wrong.
#
#   `chvt` opens /dev/tty0 or /dev/console and issues VT_ACTIVATE, which requires
#   CAP_SYS_TTY_CONFIG or ownership of the tty. `aurosprobe` is a sessionless system account with
#   neither, so the call fails with EACCES on every machine in every mode -- including a stock
#   Aurora desktop with no policy applied at all. D19: **a step that cannot fail is not a check.**
#
#   The inference was also wrong in mechanism. `-s` binds Ctrl+Alt+Fn inside cage's own wlroots
#   session; an unprivileged `chvt` from an unrelated process never reaches that code path, so a
#   green `session.chvt` was not evidence about `-s`. And the weston fallback has no equivalent of
#   the omitted flag -- libweston's DRM backend binds VT switching unconditionally -- so on that
#   path VT switching genuinely works and the old assertion noticed neither which compositor was
#   running nor that it mattered.
#
# THE PROPERTY THAT ACTUALLY HOLDS is the one description.md promises the customer: every text
# console is switched off, so a VT switch by ANY route lands on a blank console and never on a text
# prompt. That is asserted directly, against the unit state AND against what is running, and the
# compositor's own VT posture is asserted separately below against its real argv.
for u in 'getty@.service' 'getty@tty1.service' 'getty@tty2.service' 'getty@tty3.service' \
         'autovt@.service' 'serial-getty@.service' 'serial-getty@ttyS0.service' \
         'console-getty.service' 'debug-shell.service'; do
    state="$(systemctl is-enabled "$u" 2>&1 || true)"
    case "$state" in
        masked*)   a_ok  "session.$u" "$u is masked" ;;
        *"No such file"*|not-found*) a_ok "session.$u" "$u does not exist on this image" ;;
        *)         a_bad "session.$u" "$u is '$state' -- a text console on a kiosk machine is a way past the application for anyone holding any credentials" ;;
    esac
done
# The unit state is the configuration. This is the observation: a getty that was already running
# when the mask was applied is still sitting on a VT, and `is-enabled` would not say so.
RUNNING_GETTY="$(systemctl list-units --type=service --state=running --no-legend \
                 'getty@*' 'serial-getty@*' 'autovt@*' 'console-getty.service' 'debug-shell.service' \
                 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
if [ -z "${RUNNING_GETTY// /}" ]; then
    a_ok "session.no-getty-running" "no getty or debug shell is running on any VT or serial line"
else
    a_bad "session.no-getty-running" "these console units are RUNNING despite the masks: $RUNNING_GETTY"
fi
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

printf '\n-- and the compositor itself cannot be asked to switch away ------------------------------\n'
# Read what the build RECORDED, then check the process that is actually running against it. The
# record alone would be a configuration file; the argv is the observation.
VT_RECORD=""
[ -r /usr/lib/auros/policy/kiosk-vt-switch ] && VT_RECORD="$(cat /usr/lib/auros/policy/kiosk-vt-switch)"
KPID="$(pgrep -u auroskiosk -x "${COMP:-none}" 2>/dev/null | head -1)"
case "$VT_RECORD" in
  cage-no-vt-switch)
    if [ -z "$KPID" ]; then
        a_bad "session.vt-flag" "the build recorded the cage path, but no cage process is running to inspect"
    elif [ ! -r "/proc/$KPID/cmdline" ]; then
        a_bad "session.vt-flag" "/proc/$KPID/cmdline is not readable by this subject, so the compositor's flags cannot be observed. The record says cage was started without -s; without the argv that is a claim, not a check."
    else
        VT_BAD=""
        while IFS= read -r _arg; do
            [ "$_arg" = "--" ] && break
            case "$_arg" in -*s*) VT_BAD="$_arg"; break ;; esac
        done < <(tr '\0' '\n' < "/proc/$KPID/cmdline")
        if [ -n "$VT_BAD" ]; then
            a_bad "session.vt-flag" "cage is running with '$VT_BAD' before the -- separator. -s enables VT switching, which is the flag auros-kiosk-session deliberately omits; with it, Ctrl+Alt+F2 leaves the kiosk session."
        else
            a_ok "session.vt-flag" "cage (pid $KPID) was started without -s, observed in its own argv"
        fi
    fi
    ;;
  weston-vt-switch-possible)
    # HONEST LIMIT, recorded rather than hidden, and repeated to the customer in description.md.
    # libweston's DRM backend binds VT switching unconditionally -- there is no flag to omit. The
    # customer-facing promise still holds, because every getty is masked (asserted above) so a
    # switch lands on a blank console, but the mechanism is weaker than on the cage path and the
    # difference belongs in the open.
    a_note "session.vt-flag" "this image uses the WESTON fallback. libweston binds VT switching unconditionally, so Ctrl+Alt+Fn does leave the compositor. It lands on a blank console because every getty is masked (session.* above), not because the switch was prevented. Recorded in kiosk/description.md."
    [ -n "$KPID" ] && a_ok "session.compositor-running" "weston (pid $KPID) is running as auroskiosk" \
                   || a_bad "session.compositor-running" "the build recorded weston but no weston process is running as auroskiosk"
    ;;
  *)
    a_bad "session.vt-flag" "the build recorded no VT-switch posture at /usr/lib/auros/policy/kiosk-vt-switch (found '${VT_RECORD:-nothing}'). apply-policy writes it; an image without it was built by something that did not, and the mode's central claim would be unverifiable."
    ;;
esac

a_suite_no_root            hard
a_suite_no_software        hard
a_suite_no_network_change  hard
a_suite_update_timer       hard
a_suite_policy_immutable   hard

# The KDE applications that consult KAuthorized were deleted from this image, so the doors are
# checked as ABSENT rather than as refused -- absence is the stronger statement and absent-binaries
# .list already gates the build on it. Any that survived upstream renaming are still attempted, and
# a shell running through one of them is a fail.
a_suite_kde_kiosk          absent

printf '\n-- what kiosk still guarantees, same as every other mode --------------------------------\n'
a_must_succeed "floor.session" "the probe account can run an ordinary command" -- /usr/bin/id

a_finish kiosk

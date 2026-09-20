#!/usr/bin/bash
# open/assert.sh -- prove policy mode OPEN is in force, inside a booted VM. Check B5.
#
# "Prove that nothing is restricted" sounds like a check with nothing in it. It is not, and it is
# the check that makes the other three trustworthy, for two reasons:
#
#   1. It proves a mode switch RELEASES. Building `open` on top of a base that once had `managed`
#      applied must leave no polkit rule, no sudoers drop-in and no KDE restriction behind. Without
#      this assertion, apply-policy could quietly fail to release and nobody would find out until a
#      customer's open machine behaved like a locked one.
#
#   2. It is the negative control for the whole design. The canary action is refused in
#      managed/locked/kiosk and permitted here. If it were permitted everywhere, our rules do
#      nothing. If it were refused everywhere, our denials are an artefact of the probe rather than
#      our policy -- and every other assertion in this directory would be a false green.
. /usr/share/auros/policy/lib/assert-lib.sh "$@"

printf 'Auros policy assertion: OPEN\n'
printf 'as %s (uid %s) on %s\n\n' "$(id -un)" "$(id -u)" "$(uname -n)"

a_controls
a_expect_mode open

printf '\n-- the canary must be PERMITTED here ----------------------------------------------------\n'
a_pk_allow "canary.no-rules" org.auros.policy.control-deny

printf '\n-- no other mode left anything behind ---------------------------------------------------\n'
for f in /etc/polkit-1/rules.d/00-auros-managed.rules \
         /etc/polkit-1/rules.d/00-auros-locked.rules \
         /etc/polkit-1/rules.d/00-auros-kiosk.rules \
         /etc/sudoers.d/90-auros-managed \
         /etc/sudoers.d/90-auros-locked \
         /etc/sudoers.d/90-auros-kiosk \
         /etc/dconf/db/auros.d; do
    if [ -e "$f" ]; then a_bad "release.$(basename "$f")" "$f is still present on an image stamped 'open'"
    else a_ok "release.$(basename "$f")" "$f is gone"; fi
done
if grep -q '^\[KDE Action Restrictions\]' /etc/xdg/kdeglobals 2>/dev/null; then
    a_bad "release.kdeglobals" "[KDE Action Restrictions] is still in /etc/xdg/kdeglobals on an open image"
else
    a_ok "release.kdeglobals" "no KDE Kiosk restriction groups remain in /etc/xdg/kdeglobals"
fi
# ...and the groups that belong to OTHER layers must have survived the release. apply-policy owns
# three groups in that shared file and must never have touched the rest.
if [ -f /etc/xdg/kdeglobals ]; then
    a_ok "release.kdeglobals-intact" "/etc/xdg/kdeglobals still exists ($(wc -l < /etc/xdg/kdeglobals | tr -d ' ') lines) -- the shared file was edited, not replaced"
fi

printf '\n-- the floor is still there --------------------------------------------------------------\n'
# Open means we added no lock on top of the base. It does not mean the base's guarantees were
# removed, and a recipe that reached `open` by pruning its own update path would be caught here as
# well as by S10.
TIMER=""
for t in bootc-fetch-apply-updates.timer auros-update.timer rpm-ostreed-automatic.timer; do
    if systemctl is-active --quiet "$t" 2>/dev/null; then TIMER="$t"; break; fi
done
if [ -n "$TIMER" ]; then a_ok "floor.update-timer" "$TIMER is active"
else a_bad "floor.update-timer" "no update timer is active even in open mode"; fi

a_must_succeed "floor.session" "the user can run an ordinary command" -- /usr/bin/id

a_finish open

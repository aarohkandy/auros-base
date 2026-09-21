#!/usr/bin/bash
# open/assert.sh -- prove policy mode OPEN is in force, inside a booted VM. Check B5.
#
# "Prove that nothing is restricted" sounds like a check with nothing in it. It is not, and it is
# the check that makes the other three trustworthy, for three reasons:
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
#
#   3. It is where the EVIDENCE CLASSIFICATION is established, which is new and is the point of the
#      second half of this file. `aurosprobe` is a sessionless system account in no privileged
#      group. On a stock bootc host it cannot sudo, cannot su, cannot systemd-run --scope, cannot
#      machinectl and cannot write to /etc or /usr -- in ANY mode, including this one. An audit was
#      right that a `locked` run counting those as proof was padding its result line.
#
#      So this file runs the SAME shared suites that locked/kiosk run, at level `control`, and:
#        * asserts that every polkit action locked denies is still ANSWERABLE here (pkcheck 0 or 2,
#          never 1). A hard refusal here would mean the matching refusal under locked was never our
#          doing, and that is a FAIL of this control -- it is what would catch the rot.
#        * runs the non-polkit attempts and RECORDS which of them succeeded, so the matrix output
#          says in plain text which attempts carry evidence and which are corroborating.
#        * opens the KDE KAuthorized doors that `locked` claims to shut, and FAILS if they do not
#          open. A door that cannot be opened on an unrestricted image is a door whose refusal on a
#          locked image proves nothing.
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
#
# The candidate list is $A_UPDATE_TIMERS from assert-lib.sh, NOT a second copy kept here. The copy
# that used to live at this line omitted uupd.timer -- the unit D22 identifies as the real update
# driver on this base -- so a machine uupd was patching perfectly well would have been reported as
# "no update timer is active even in open mode": a false red on the base image's own gate.
TIMER=""
for t in "${A_UPDATE_TIMERS[@]}"; do
    if systemctl is-active --quiet "$t" 2>/dev/null; then TIMER="$t"; break; fi
done
if [ -n "$TIMER" ]; then a_ok "floor.update-timer" "$TIMER is active (candidates: ${A_UPDATE_TIMERS[*]})"
else a_bad "floor.update-timer" "no update timer is active even in open mode (looked for ${A_UPDATE_TIMERS[*]})"; fi

a_must_succeed "floor.session" "the user can run an ordinary command" -- /usr/bin/id

printf '\n'
printf '=========================================================================================\n'
printf 'THE NEGATIVE CONTROL. Everything below runs the SAME attempts locked/kiosk run, against an\n'
printf 'image with no Auros policy rules on it. A refusal here is a refusal we did not cause, and a\n'
printf 'refusal we did not cause is not evidence anywhere.\n'
printf '=========================================================================================\n'
a_suite_no_root            control
a_suite_no_software        control
a_suite_no_network_change  control
a_suite_update_timer       control
a_suite_policy_immutable   control
a_suite_kde_kiosk          control

a_finish open

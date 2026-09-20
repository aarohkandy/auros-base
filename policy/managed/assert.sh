#!/usr/bin/bash
# managed/assert.sh -- prove policy mode MANAGED is in force, inside a booted VM. Check B5.
#
# Managed's promise is narrower than locked's, and the assertion has to be narrower with it or it
# asserts a product we did not sell. The promise is exactly:
#
#     an ordinary user cannot change this machine WITHOUT AN ADMINISTRATOR'S PASSWORD.
#
# So every polkit answer below must be "not for this user" -- pkcheck 1 (no) and 3 (an administrator
# could authorise this) are both correct. What would be wrong is 0.
#
# What this file must NOT do is quietly assert locked's stricter promise and pass anyway. If it did,
# managed and locked would be indistinguishable in CI while being different products in a school,
# and a recipe could ship the wrong one with a full green matrix behind it.
. /usr/share/auros/policy/lib/assert-lib.sh "$@"

printf 'Auros policy assertion: MANAGED\n'
printf 'as %s (uid %s) on %s\n\n' "$(id -un)" "$(id -u)" "$(uname -n)"

a_controls
a_expect_mode managed

printf '\n-- the canary: is our rule file actually loaded? --------------------------------------\n'
a_pk_admin_only "canary.rules-loaded" org.auros.policy.control-deny

a_suite_no_root            admin
a_suite_no_software        admin
a_suite_no_network_change  admin
a_suite_update_timer       admin
a_suite_policy_immutable

printf '\n-- what managed deliberately still allows -----------------------------------------------\n'
a_pk_allow "allowed.shutdown" org.freedesktop.login1.power-off
a_must_succeed "allowed.session" "the user can run an ordinary command" -- /usr/bin/id
# Managed keeps the terminal, because a managed machine has a competent adult behind it some of the
# time and taking the terminal away is what `locked` is for. Asserting its PRESENCE is what stops
# managed and locked quietly converging into the same mode over a handful of commits.
if command -v konsole >/dev/null 2>&1; then
    a_ok "allowed.terminal" "a terminal emulator is present, as managed intends"
else
    a_note "allowed.terminal" "no konsole on this image -- not a failure, but managed never asked for it to be removed"
fi

a_finish managed

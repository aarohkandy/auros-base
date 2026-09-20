#!/usr/bin/bash
# locked/assert.sh -- prove policy mode LOCKED is in force, inside a booted VM. Check B5.
#
# Run by /usr/libexec/auros/assert-policy, which re-execs it as an unprivileged account.
# Exit 0 = the mode is in force. Exit non-zero = it is not, whatever the configuration files say.
#
# Nothing here reads a configuration file and draws a conclusion. Every line attempts the thing the
# mode promises is impossible, and fails if the attempt succeeds. B5's fails_on is
# "configured-but-not-effective", and the reason is commercial: telling a school their machines are
# locked down when they are not is worse than not locking them down.
#
# The attempt suites live in lib/assert-lib.sh because locked, managed and kiosk make the same
# promises about root, software, network and updates and differ only in the ANSWER. Three copies
# drift; one copy with a parameter does not.
. /usr/share/auros/policy/lib/assert-lib.sh "$@"

printf 'Auros policy assertion: LOCKED\n'
printf 'as %s (uid %s) on %s\n\n' "$(id -un)" "$(id -u)" "$(uname -n)"

a_controls
a_expect_mode locked

printf '\n-- the canary: is our rule file actually loaded? --------------------------------------\n'
# org.auros.policy.control-deny defaults to allow_any=yes and is denied only by
# 00-auros-locked.rules. A refusal here is positive proof that the rules are installed, parsed and
# being evaluated for THIS subject -- which is what turns every other denial below into evidence
# rather than an artefact of a probe process with no logind session.
a_pk_hard_deny "canary.rules-loaded" org.auros.policy.control-deny

a_suite_no_root            hard
a_suite_no_software        hard
a_suite_no_network_change  hard
a_suite_update_timer       hard
a_suite_policy_immutable

printf '\n-- what locked deliberately still allows ------------------------------------------------\n'
# Asserted as PERMITTED on purpose. A mode that also broke shutting the lid and reading the battery
# is a machine a school stops using in week two, and "it got too locked down to use" is a product
# failure no security property makes up for.
a_pk_allow "allowed.shutdown" org.freedesktop.login1.power-off
a_must_succeed "allowed.session" "the user can run an ordinary command" -- /usr/bin/id

printf '\n-- and the two things locked does NOT claim, recorded rather than hidden ----------------\n'
a_note "limit.user-flatpak" "a user with a shell can still install a Flatpak into their own home. No privilege, not on the system, gone when the profile resets. kiosk is the mode that removes this."
a_note "limit.grub"         "anyone who can restart the machine and edit the boot menu can get root on any Linux machine unless the boot menu has a password. That password belongs to the hardening layer, not to this mode."

a_finish locked

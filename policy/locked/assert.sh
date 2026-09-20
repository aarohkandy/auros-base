#!/usr/bin/bash
# locked/assert.sh -- prove policy mode LOCKED is in force, inside a booted VM. Check B5.
#
# Run by /usr/libexec/auros/assert-policy, which re-execs it as an unprivileged account.
# Exit 0 = the mode is in force. Exit non-zero = it is not, whatever the configuration files say.
#
# Every block below attempts the thing the mode promises is impossible. Nothing below reads a config
# file and draws a conclusion from it.
. /usr/share/auros/policy/lib/assert-lib.sh "$@"

printf 'Auros policy assertion: LOCKED\n'
printf 'as %s (uid %s) on %s\n\n' "$(id -un)" "$(id -u)" "$(uname -n)"

a_controls
a_expect_mode locked

printf '\n-- the canary: is our rule file actually loaded? --------------------------------------\n'
# org.auros.policy.control-deny defaults to allow_any=yes. The ONLY thing that can refuse it is
# 00-auros-locked.rules. A denial here is positive proof the rules are installed, parsed and being
# evaluated for this subject -- which is what turns every denial below into evidence.
a_pk_hard_deny "canary.rules-loaded" org.auros.policy.control-deny

printf '\n-- try to get root ---------------------------------------------------------------------\n'
a_must_fail "root.sudo"        "sudo -n true"                      -- sudo -n true
a_must_fail "root.sudo-shell"  "sudo -n /usr/bin/bash -c id"       -- sudo -n /usr/bin/bash -c id
a_must_fail "root.pkexec"      "pkexec /usr/bin/id (no agent)"     -- pkexec --disable-internal-agent /usr/bin/id
a_pk_hard_deny "root.pkexec-policy" org.freedesktop.policykit.exec
# su will fail on any machine with no root password, so on its own it proves little. It is here
# because the PAM restriction is a real second lock and its absence should be visible, and it is
# labelled honestly rather than counted as the primary evidence.
a_must_fail "root.su"          "su -c id root (corroborating, not primary)" -- su -c id root
if command -v machinectl >/dev/null 2>&1; then
    a_must_fail "root.machinectl" "machinectl shell" -- machinectl shell .host
else
    a_ok "root.machinectl" "machinectl is absent from the image"
fi
a_must_fail "root.systemd-run"  "systemd-run --scope (system manager)" -- systemd-run --scope --quiet /usr/bin/id

printf '\n-- try to install software -------------------------------------------------------------\n'
a_pk_hard_deny "pkg.rpmostree-policy" org.projectatomic.rpmostree1.install-uninstall-packages
a_pk_hard_deny "pkg.packagekit"       org.freedesktop.packagekit.package-install
a_pk_hard_deny "pkg.flatpak-system"   org.freedesktop.Flatpak.app-install
if command -v rpm-ostree >/dev/null 2>&1; then
    a_must_fail "pkg.rpmostree" "rpm-ostree install nano" -- rpm-ostree install --idempotent nano
fi
if command -v flatpak >/dev/null 2>&1; then
    a_must_fail "pkg.flatpak" "flatpak install --system" -- flatpak install --system -y --noninteractive flathub org.gnome.Calculator
fi
# HONEST LIMIT, and it is deliberately NOT asserted as a pass:
#   `flatpak install --user` needs no polkit authorisation, and flatpak has no supported system-wide
#   switch that disables user-scope installs. A user with a shell can install a Flatpak into their
#   own home directory. It runs with no privilege, it is not on the system, and it goes away when
#   the profile is reset. `locked` therefore does not claim to prevent it -- locked/description.md
#   says so to the customer in the same words. The mode that removes this path is `kiosk`, because
#   kiosk removes the shell.
a_note "pkg.flatpak-user" "not asserted: user-scope Flatpak installs are outside what locked claims (see description.md)"

printf '\n-- try to change the network -----------------------------------------------------------\n'
a_pk_hard_deny "net.modify-system" org.freedesktop.NetworkManager.settings.modify.system
a_pk_hard_deny "net.control"       org.freedesktop.NetworkManager.network-control
a_pk_hard_deny "net.enable"        org.freedesktop.NetworkManager.enable-disable-network
if command -v nmcli >/dev/null 2>&1; then
    a_must_fail "net.off"  "nmcli networking off"  -- nmcli networking off
    a_must_fail "net.add"  "nmcli connection add"  -- nmcli connection add type dummy ifname auros-probe0 con-name auros-probe
fi

printf '\n-- try to stop the machine updating itself ---------------------------------------------\n'
# The unit name is the update layer's to choose (task A4). We look for the one that is actually
# active rather than assuming a name, and we say which we found. If none is active that is a FAIL:
# a machine that is not updating itself is the abandoned laptop we sell against, and check S10
# asserts the same thing from outside.
TIMER=""
for t in bootc-fetch-apply-updates.timer auros-update.timer rpm-ostreed-automatic.timer; do
    if systemctl is-active --quiet "$t" 2>/dev/null; then TIMER="$t"; break; fi
done
if [ -z "$TIMER" ]; then
    a_bad "update.timer-active" "no update timer is active (looked for bootc-fetch-apply-updates.timer, auros-update.timer, rpm-ostreed-automatic.timer)"
else
    a_ok "update.timer-active" "$TIMER is active"
    a_pk_hard_deny "update.manage-units" org.freedesktop.systemd1.manage-units
    a_must_fail "update.stop"    "systemctl stop $TIMER"    -- systemctl stop "$TIMER"
    a_must_fail "update.disable" "systemctl disable $TIMER" -- systemctl disable "$TIMER"
    a_must_fail "update.mask"    "systemctl mask $TIMER"    -- systemctl mask "$TIMER"
    # The attempts failing is not the same as the timer surviving. Check the timer.
    if systemctl is-active --quiet "$TIMER"; then
        a_ok "update.timer-survived" "$TIMER is still active after three attempts to stop it"
    else
        a_bad "update.timer-survived" "$TIMER is NO LONGER ACTIVE after the attempts above -- one of them worked"
    fi
fi

printf '\n-- try to edit the policy itself -------------------------------------------------------\n'
a_must_fail "self.sudoers"  "write a new sudoers drop-in"  -- /usr/bin/install -m 0440 /dev/null /etc/sudoers.d/00-auros-probe
a_must_fail "self.polkit"   "write a new polkit rule"      -- /usr/bin/install -m 0644 /dev/null /etc/polkit-1/rules.d/00-auros-probe.rules
a_must_fail "self.stamp"    "overwrite the mode stamp"     -- /usr/bin/tee /usr/lib/auros/policy-mode
a_must_fail "self.kdeglobals" "overwrite /etc/xdg/kdeglobals" -- /usr/bin/tee /etc/xdg/kdeglobals

printf '\n-- what locked deliberately still allows ------------------------------------------------\n'
# Asserted as PERMITTED on purpose. A mode that also broke shutting the lid and reading the battery
# would be a machine a school stops using in week two, and "it got too locked down to use" is a
# product failure that no security property makes up for.
a_pk_allow "allowed.shutdown" org.freedesktop.login1.power-off
a_must_succeed "allowed.session" "the user can run an ordinary command" -- /usr/bin/id

a_finish locked

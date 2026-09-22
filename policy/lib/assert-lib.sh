#!/usr/bin/bash
# assert-lib.sh -- runtime assertion helpers for Auros policy modes.
#
# Sourced by policy/<mode>/assert.sh, which the check matrix runs inside a BOOTED VM as check B5.
#
# THE RULE THIS FILE EXISTS TO ENFORCE:
#
#   An assertion may not read a configuration file and conclude that a restriction is in force.
#   It must ATTEMPT THE FORBIDDEN THING and observe the attempt fail.
#
# B5's fails_on is "configured-but-not-effective", and the reason is commercial, not academic: we
# would otherwise tell a school their machines are locked down when they are not. A file being
# present is the weakest possible evidence that it is being obeyed.
#
# THE SECOND RULE, which is subtler and is how this kind of test usually rots:
#
#   A denial is only evidence if the same subject could have been ALLOWED something.
#
#   Most polkit actions default to auth_admin for a subject with no active logind session. A probe
#   process started by a test harness often has no session. Such a probe is refused everything, in
#   every mode, including `open` -- so a lazily written `locked` assertion passes on an image where
#   our rules were never installed. That is a false green on the single claim a customer can
#   disprove by pressing a key.
#
#   a_controls() below runs three positive controls and ABORTS THE WHOLE RUN if any of them fails.
#   org.auros.policy.control-allow is the important one: it is our own action, allow_any=yes, and no
#   mode rule ever touches it. If pkcheck says no to that, the subject cannot be authorised for
#   anything and every other denial in the run is meaningless.
#
# THE THIRD RULE, added 2026-09-20 after an audit found that half of a `locked` run was padding:
#
#   Every attempt declares whether it is PRIMARY evidence or CORROBORATING, and the claim is
#   settled by running the same attempt on an `open` image rather than by asserting it here.
#
#   `aurosprobe` is a sysusers system account in no privileged group with no logind session. On a
#   stock bootc host `sudo -n true`, `su -c id root`, `systemd-run --scope`, `machinectl shell` and
#   every write to /etc or /usr fail for that subject in EVERY mode, including `open`. Their failure
#   under `locked` is therefore not by itself evidence that `locked` did anything. They stay --
#   they would catch a real regression, e.g. a sudoers drop-in that accidentally grants ALL -- but
#   they are labelled `corroborating` and a_finish prints the list, so nobody reads a green
#   `root.sudo` as proof of the mode.
#
#   The discriminating half is the pkcheck calls, because pkcheck distinguishes 1 (refused outright)
#   from 2 (an administrator could authorise this). `open` answers 2 where `locked` answers 1, and
#   open/assert.sh now asserts exactly that with a_deny at level `control`: if an action answers 1
#   on an image with no Auros rules installed, the negative control FAILS and says so, because a
#   denial of that action under `locked` would be an artefact of the probe rather than our policy.
#
#   The same reasoning is applied to the KDE half of the mode by a_suite_kde_kiosk: the attempt
#   creates a marker file through a KDE application and observes whether the marker appears, and
#   `open` asserts that it DOES. An attempt that cannot succeed anywhere proves nothing anywhere.

set -uo pipefail

A_PASS=0
A_FAIL=0
A_LINES=()
A_JSON=0
A_TIMEOUT=${AUROS_ASSERT_TIMEOUT:-25}

# Attempts whose failure does not, on its own, discriminate this mode from `open`. Populated by
# a_corroborate; printed by a_finish so the distinction is visible in the CI log and in the JSON.
A_CORROBORATING=()
# Populated by a_control_observe, which only ever runs in open/assert.sh.
A_CONTROL_DISCRIMINATING=()
A_CONTROL_NON_DISCRIMINATING=()

# ── the update timers: ONE list ──────────────────────────────────────────────────────────────────
# D22: uupd, not bootc-fetch-apply-updates, is the real update driver on this base. Every consumer
# iterates this array. A second hand-maintained copy in open/assert.sh omitted uupd.timer and would
# have reported "no update timer is active" on a machine uupd was patching perfectly well -- a false
# red on the base image's own gate.
A_UPDATE_TIMERS=(bootc-fetch-apply-updates.timer uupd.timer auros-update.timer rpm-ostreed-automatic.timer)

a_json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

a_ok()  { A_PASS=$(( A_PASS + 1 )); A_LINES+=("pass|$1|$2"); printf 'PASS  %-34s %s\n' "$1" "$2"; }
a_bad() { A_FAIL=$(( A_FAIL + 1 )); A_LINES+=("fail|$1|$2"); printf 'FAIL  %-34s %s\n' "$1" "$2"; }
a_note(){ A_LINES+=("note|$1|$2"); printf '      %-34s %s\n' "$1" "$2"; }

# The reason goes on the RESULT line as well as the FAIL line: B5's detail is the TAIL of this
# output (auros-matrix-agent.sh), and run 35566336512 reported an abort whose reason had been cut
# off above the last three lines -- a red nobody could act on without re-booting the image.
a_abort() {
    printf 'FAIL  %-34s %s\n' "control" "$1"
    printf '\nRESULT: fail (assertion aborted before it could prove anything): %s\n' "$1"
    printf 'The run was stopped rather than reported, because an assertion that cannot observe a\n'
    printf 'permitted action cannot prove a forbidden one. A green result here would be a false green.\n'
    exit 1
}

# ── the attempt primitives ───────────────────────────────────────────────────────────────────────
# stdin is /dev/null on every attempt: sudo, su and pkexec all prompt, and a prompt with a terminal
# behind it turns a test into a hang. A hang in CI eventually reads as flakiness, and flakiness
# eventually reads as "retry it", which is how a gate stops being a gate.

a_must_fail() {   # a_must_fail <id> <description> -- <command...>
    local id="$1" desc="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    local out rc
    out="$(timeout "$A_TIMEOUT" "$@" 2>&1 </dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        a_bad "$id" "$desc -- IT SUCCEEDED. $(printf '%s' "$out" | head -1)"
    elif [ "$rc" -eq 124 ]; then
        a_bad "$id" "$desc -- timed out after ${A_TIMEOUT}s; a hang is not a denial"
    else
        a_ok "$id" "$desc -- refused (exit $rc)"
    fi
}

# a_corroborate -- an attempt that fails on an `open` image too, so its failure here is consistent
# with the mode but is not by itself evidence of it. Same mechanics as a_must_fail; different label,
# and the id is recorded so a_finish can list them. See THE THIRD RULE at the top of this file.
a_corroborate() {  # a_corroborate <id> <description> -- <command...>
    local id="$1" desc="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    A_CORROBORATING+=("$id")
    a_must_fail "$id" "$desc [corroborating]" -- "$@"
}

a_must_succeed() {  # a_must_succeed <id> <description> -- <command...>
    local id="$1" desc="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    local out rc
    out="$(timeout "$A_TIMEOUT" "$@" 2>&1 </dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then a_ok "$id" "$desc"; else a_bad "$id" "$desc -- failed (exit $rc): $(printf '%s' "$out" | head -1)"; fi
}

# a_control_observe -- run an attempt on an UNLOCKED image and judge nothing. Its only job is to
# record, in the matrix output, whether this attempt is capable of succeeding for this subject at
# all. An attempt that fails here as well is one whose failure elsewhere carries no information, and
# that fact belongs in the log rather than in somebody's head.
a_control_observe() {  # a_control_observe <id> <description> -- <command...>
    local id="$1" desc="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    local out rc
    out="$(timeout "$A_TIMEOUT" "$@" 2>&1 </dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        A_CONTROL_DISCRIMINATING+=("$id")
        a_note "control.$id" "$desc -- SUCCEEDED here. Its failure under locked/kiosk is therefore evidence."
    else
        A_CONTROL_NON_DISCRIMINATING+=("$id")
        a_note "control.$id" "$desc -- failed here too (exit $rc). CORROBORATING ONLY elsewhere."
    fi
}

a_absent() {  # a_absent <id> <binary> -- the forbidden thing cannot be attempted because it is gone
    local id="$1" bin="$2" p
    for p in "$(command -v "$bin" 2>/dev/null)" "/usr/bin/$bin" "/usr/sbin/$bin" "/usr/libexec/$bin" "/bin/$bin"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            a_bad "$id" "$bin is still on this machine at $p"
            return
        fi
    done
    a_ok "$id" "$bin is absent from the image"
}

# ── polkit ───────────────────────────────────────────────────────────────────────────────────────
# pkcheck exit codes, from polkit's src/programs/pkcheck.c (measured on Fedora 43, polkit 126):
#   0 authorised; 1 not authorised; 2 a CHALLENGE -- authorisation could be obtained by authenticating
#   ("Authorization requires authentication and -u wasn't passed"); 3 the authentication dialog was
#   DISMISSED, which cannot happen without -u; 126/127 an error (no authority, polkitd not running).
# This file used to read 3 as the challenge and 2 as an error. It was never observed doing so, because
# every B5 run until 35566336512 aborted before the first pkcheck; on the first real one an
# auth_admin action would have read as "pkcheck returned 2 (error)" in every mode.
# We care about the difference between 1 and 2, because it IS the difference between
# `locked` and `managed` -- and, per THE THIRD RULE, it is the only thing in a_suite_no_root,
# a_suite_no_software and a_suite_no_network_change that discriminates at all.
a_pk() { pkcheck --action-id "$1" --process "$$" >/dev/null 2>&1; echo $?; }

# a_pk_unregistered <action> -- true only when polkit ITSELF says the action does not exist.
# pkcheck answers 127 for "Action X is not registered" (polkitbackendinteractiveauthority.c) and for
# every other error alike, so 127 alone is never read as absence. The proof is a SUCCESSFUL, non-empty
# enumeration by the live authority (pkaction) that does not contain the id. Run 35616444839 B5:
# org.freedesktop.packagekit.package-install -> 127, because upstream Aurora ships no PackageKit and
# build/40-windows-feel.sh removes what is left.
a_pk_unregistered() {
    local list; list="$(pkaction 2>/dev/null)" || return 1
    [ -n "$list" ] || return 1
    ! grep -qxF "$1" <<<"$list"
}

a_pk_hard_deny() {  # locked/kiosk: the answer is no, and no password changes it
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        0) a_bad "$id" "$action -- AUTHORISED. The mode is not in force for this action." ;;
        1) a_ok  "$id" "$action -- refused outright (pkcheck 1)" ;;
        2) a_bad "$id" "$action -- answerable with an administrator password (pkcheck 2). That is 'managed' behaviour; 'locked' requires a hard refusal." ;;
        *) a_bad "$id" "$action -- pkcheck returned $rc (error). An error is not a denial." ;;
    esac
}

a_pk_admin_only() {  # managed: not now, but an administrator at this machine could
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        0) a_bad "$id" "$action -- AUTHORISED without any administrator. The mode is not in force." ;;
        1|2) a_ok "$id" "$action -- not authorised for this user (pkcheck $rc)" ;;
        *) a_bad "$id" "$action -- pkcheck returned $rc (error). An error is not a denial." ;;
    esac
}

# a_pk_not_hard_denied -- THE NEGATIVE CONTROL, run only by open/assert.sh.
#
# On an image with no Auros policy rules installed, an action that `locked` denies must still be
# answerable: 0 (yes) or 2 (an administrator could authorise this). If it answers 1 HERE, then the
# same answer under `locked` was never our doing -- it is the base's own default for a subject with
# no session -- and the corresponding line in locked/assert.sh is decoration. That is a FAIL of this
# control, not a pass, and it is the check that stops this whole directory from rotting into a list
# of denials nobody caused.
a_pk_not_hard_denied() {
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        0) a_ok  "$id" "$action -- permitted here (pkcheck 0). A refusal under managed/locked/kiosk is ours." ;;
        2) a_ok  "$id" "$action -- answerable with an administrator password here (pkcheck 2). A HARD refusal under locked is ours." ;;
        1) a_bad "$id" "$action -- refused OUTRIGHT (pkcheck 1) on an image carrying no Auros policy rules. A denial of this action under locked/kiosk is therefore an artefact of the probe subject, not evidence of the mode. Either give the probe a session, or drop this action from the suite -- do not leave it reporting a pass it did not earn." ;;
        *) a_bad "$id" "$action -- pkcheck returned $rc (error) on the negative control. An error is not an answer." ;;
    esac
}

a_pk_allow() {
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    if [ "$rc" = 0 ]; then a_ok "$id" "$action -- permitted, as this mode intends"
    else a_bad "$id" "$action -- NOT permitted (pkcheck $rc), but this mode does not restrict it"; fi
}

# ── the controls, run first, fatal on failure ────────────────────────────────────────────────────
a_controls() {
    [ "$(id -u)" != 0 ] || a_abort "running as root. A root process is authorised for everything on any machine in any mode; nothing it fails to do proves anything about this one."

    if grep -qx aurosadmin <<<"$(id -nG 2>/dev/null | tr ' ' '\n')"; then
        a_abort "the probe account is in the aurosadmin group. It is supposed to be the unprivileged case."
    fi
    # wheel is the base's admin group (50-default.rules addAdminRule) and upstream rules key on it:
    # 22-ublue-rebase-systemd.rules calls action.lookup("unit").startsWith() for wheel members, which
    # throws when pkcheck passes no unit detail, and polkit turns a throwing rule into NOT_AUTHORIZED.
    # Run 35616444839 B5 ran as the harness's wheel user and read that as manage-units refused outright.
    if grep -qx wheel <<<"$(id -nG 2>/dev/null | tr ' ' '\n')"; then
        a_abort "the probe subject $(id -un) is in wheel, the base's administrator group. Its polkit answers are an administrator's (and hit upstream wheel-only rules), not the unprivileged case. Run assert-policy as root so it drops to aurosprobe."
    fi

    command -v pkcheck >/dev/null 2>&1 || a_abort "pkcheck is not installed. Without it the difference between 'refused outright' and 'an administrator could authorise this' cannot be observed, and that difference is the difference between locked and managed."

    # GetId on the bus driver, NOT org.freedesktop.DBus.Peer.Ping. The stock system-bus policy
    # (/usr/share/dbus-1/system.conf: default deny send_type=method_call, re-allowing only the
    # org.freedesktop.DBus, Introspectable and Properties interfaces on the driver) refuses Peer.Ping
    # from any unprivileged sender -- "AccessDenied: Sender is not authorized to send message" on
    # dbus-broker 37, the same on dbus-daemon 1.16. This probe used Ping, so on a real image it
    # reported a live bus as dead and aborted every non-root run: run 35566336512, B5, in 56 ms.
    local out rc
    out="$(timeout 10 dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.GetId 2>&1)" \
        || a_abort "the system D-Bus is not reachable from this process (dbus-send ... org.freedesktop.DBus.GetId said: $(printf '%s' "$out" | head -2 | tr '\n' ' ')). Every polkit denial below would then be a dead bus rather than a policy decision."

    out="$(pkcheck --action-id org.auros.policy.control-allow --process "$$" 2>&1)"; rc=$?
    [ "$rc" = 0 ] || a_abort "the positive control action org.auros.policy.control-allow returned pkcheck $rc ($(printf '%s' "$out" | head -2 | tr '\n' ' ')). It is our own action, allow_any=yes, and no mode rule touches it. If this subject cannot be authorised for THAT, it cannot be authorised for anything, and every denial in this run would be an artefact of the probe rather than evidence of the policy."

    a_ok "control.subject" "running unprivileged as $(id -un) (uid $(id -u)), not in aurosadmin"
    a_ok "control.bus"    "the system D-Bus answers this process"
    a_ok "control.polkit" "org.auros.policy.control-allow is authorised, so a refusal below is a real refusal"
}

a_expect_mode() {
    local want="$1" got="none"
    [ -r /usr/lib/auros/policy-mode ] && got="$(cat /usr/lib/auros/policy-mode)"
    if [ "$got" = "$want" ]; then
        a_ok "mode.stamp" "the image is stamped '$want' (/usr/lib/auros/policy-mode, on the read-only /usr)"
    else
        a_bad "mode.stamp" "the image is stamped '$got' but this assertion is for '$want'"
    fi
}

# ── shared attempt suites ────────────────────────────────────────────────────────────────────────
#
# These live in the library rather than in each mode's assert.sh for one reason: locked, managed and
# kiosk make the SAME promises about root, software, network and updates, and differ only in whether
# the answer is "no" or "not without the administrator password". Three copies of the same attempts
# drift apart -- one gains a check, another does not, and eventually two modes are indistinguishable
# in CI while being different products in the field.
#
# $1 is the LEVEL:
#   hard      locked/kiosk -- the answer is no, and no password changes it
#   admin     managed      -- not for this user, but an administrator at this machine could
#   control   open         -- the negative control. Nothing is restricted here, so the polkit answer
#                             must not be a hard refusal, and the non-polkit attempts are run purely
#                             to record whether they are capable of succeeding at all.

# a_deny <level> <id> <action> [evidence]
#
# `evidence` classifies the polkit answer, and it exists because not every polkit default is the
# same shape:
#
#   primary            (the default) The action's upstream default is auth_admin/auth_admin_keep for
#                      allow_any, so a SESSIONLESS subject is answered 3 on an unlocked image and 1
#                      on a locked one. open/assert.sh FAILS if such an action answers 1 there,
#                      because that would mean the matching refusal under locked was never our doing.
#
#   session-dependent  The action's upstream default is allow_active=yes with a stricter allow_any,
#                      so the answer for a sessionless subject depends on the base's own policy
#                      rather than on ours, and could be 1 on an open image too. Counting such an
#                      answer as proof of `locked` would be exactly the padding this file's THIRD
#                      RULE is about -- so it is recorded as corroborating in every mode, and the
#                      negative control REPORTS it rather than failing the base image on a guess
#                      about an upstream default that none of us has measured on this base.
#
#                      When the control observes 0 or 2 for one of these on the open image, it says
#                      PROMOTE: that is a measurement showing the action does discriminate, and the
#                      classification should be tightened to `primary` in the same commit that
#                      records the measurement (D24 -- the measurement wins).
a_deny() {
    local level="$1" id="$2" action="$3" evidence="${4:-primary}"
    if [ "$evidence" = session-dependent ] && [ "$level" != control ]; then
        A_CORROBORATING+=("$id")
    fi
    # No mechanism on the image offers this action, so there is nothing to authorise in ANY mode.
    # True of the promise, but it discriminates nothing: corroborating under every mode, a note on
    # the control, never primary.
    if a_pk_unregistered "$action"; then
        case "$level" in
            hard|admin) A_CORROBORATING+=("$id")
                        a_ok "$id" "$action -- not registered with polkit on this image (pkaction enumerates it nowhere): no installed mechanism offers it [corroborating]" ;;
            control)    a_note "control.$id" "$action -- not registered with polkit on this image, so it cannot discriminate between modes here" ;;
            *)          a_bad "$id" "a_deny was called with unknown level '$level' -- refusing to guess which promise to assert" ;;
        esac
        return
    fi
    case "$level" in
        hard)    a_pk_hard_deny       "$id" "$action" ;;
        admin)   a_pk_admin_only      "$id" "$action" ;;
        control)
            if [ "$evidence" = session-dependent ]; then a_pk_control_record "$id" "$action"
            else a_pk_not_hard_denied "$id" "$action"; fi ;;
        *)       a_bad "$id" "a_deny was called with unknown level '$level' -- refusing to guess which promise to assert" ;;
    esac
}

# The negative control for a session-dependent action: observe, classify, never fail the base on it.
a_pk_control_record() {
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        1) A_CONTROL_NON_DISCRIMINATING+=("$id")
           a_note "control.$id" "$action -- refused outright (pkcheck 1) on this unlocked image too. CORROBORATING ONLY: a refusal of it under locked/kiosk is the base's own default for a sessionless subject, not our rule." ;;
        0|2) A_CONTROL_DISCRIMINATING+=("$id")
           a_note "control.$id" "$action -- answerable here (pkcheck $rc). PROMOTE: this action DOES discriminate on this base, so change its a_deny evidence argument from session-dependent to primary and record the measurement." ;;
        *) a_bad "control.$id" "$action -- pkcheck returned $rc (error) on the negative control. An error is not an answer." ;;
    esac
}

# a_try <level> <id> <desc> -- <cmd...>
# The non-polkit attempts. Under hard/admin they are corroborating; under control they are observed
# and not judged. Routing them through one function is what keeps the open run and the locked run
# attempting the SAME things, which is the only way the control means anything.
a_try() {
    local level="$1"; shift
    if [ "$level" = control ]; then a_control_observe "$@"; else a_corroborate "$@"; fi
}

a_suite_no_root() {
    local level="$1"
    printf '\n-- try to get root ---------------------------------------------------------------------\n'
    # PRIMARY: the one answer that differs between an open image and a locked one for this subject.
    a_deny "$level" "root.pkexec-policy" org.freedesktop.policykit.exec
    # CORROBORATING: all of these fail for a sessionless system account on a stock `open` image too.
    # They stay because they would catch a real regression -- a sudoers drop-in that granted ALL, a
    # root password that got set -- but they are not what proves the mode. open/assert.sh runs the
    # identical list at level `control` and prints which of them succeeded there.
    a_try "$level" "root.sudo"        "sudo -n true"                      -- sudo -n true
    a_try "$level" "root.sudo-shell"  "sudo -n bash -c id"                -- sudo -n /usr/bin/bash -c id
    a_try "$level" "root.pkexec"      "pkexec id, with no auth agent"     -- pkexec --disable-internal-agent /usr/bin/id
    a_try "$level" "root.su"          "su -c id root"                     -- su -c id root
    a_try "$level" "root.systemd-run" "systemd-run --scope on the system manager" -- systemd-run --scope --quiet /usr/bin/id
    if command -v machinectl >/dev/null 2>&1; then
        a_try "$level" "root.machinectl" "machinectl shell .host" -- machinectl shell .host
    else
        a_ok "root.machinectl" "machinectl is absent from the image"
    fi
}

a_suite_no_software() {
    local level="$1"
    printf '\n-- try to install software -------------------------------------------------------------\n'
    a_deny "$level" "pkg.rpmostree-policy" org.projectatomic.rpmostree1.install-uninstall-packages
    a_deny "$level" "pkg.packagekit"       org.freedesktop.packagekit.package-install
    a_deny "$level" "pkg.flatpak-system"   org.freedesktop.Flatpak.app-install
    # NOT attempted at level `control`. These two would CHANGE the open image if they succeeded, and
    # the open image is the base that the rest of the matrix -- S3, S6, S10, U1 -- is measuring at
    # the same time. An attempt that alters the thing under test is not a control, it is a
    # contaminant. The polkit answers above are the discriminating half in any case, and these two
    # are corroborating everywhere else.
    if [ "$level" != control ]; then
        if command -v rpm-ostree >/dev/null 2>&1; then
            a_corroborate "pkg.rpmostree" "rpm-ostree install nano" -- rpm-ostree install --idempotent nano
        fi
        if command -v flatpak >/dev/null 2>&1; then
            a_corroborate "pkg.flatpak" "flatpak install --system from flathub" -- flatpak install --system -y --noninteractive flathub org.gnome.Calculator
        fi
    else
        a_note "pkg.attempts" "not attempted on the open control: a successful rpm-ostree or flatpak install would modify the very image S3/S6/S10/U1 are measuring. The polkit answers above carry the evidence."
    fi
    # HONEST LIMIT, deliberately NOT asserted as a pass:
    #   `flatpak install --user` needs no polkit authorisation, and flatpak has no supported
    #   system-wide switch that disables user-scope installs. A user with a shell can install a
    #   Flatpak into their own home directory. It runs with no privilege, it is not on the system,
    #   and it goes away when the profile is reset. `locked` does not claim to prevent it, and
    #   locked/description.md tells the customer so in the same words. The mode that removes this
    #   path is `kiosk`, because kiosk removes the shell.
    a_note "pkg.flatpak-user" "not asserted: user-scope Flatpak installs are outside what this mode claims (see description.md)"
}

a_suite_no_network_change() {
    local level="$1"
    printf '\n-- try to change the network -----------------------------------------------------------\n'
    # settings.modify.system is auth_admin_keep for allow_any upstream, so it discriminates for a
    # sessionless subject and is primary. The other two carry allow_active=yes in NetworkManager's
    # own policy, so whether a sessionless probe is answered 1 or 2 on an OPEN image depends on the
    # base's defaults and not on us. Nobody here has measured that on this base -- D5: this machine
    # cannot boot one -- so they are classified session-dependent rather than guessed at, and the
    # control prints PROMOTE if the measurement turns out to support tightening them.
    a_deny "$level" "net.modify-system" org.freedesktop.NetworkManager.settings.modify.system
    a_deny "$level" "net.control"       org.freedesktop.NetworkManager.network-control       session-dependent
    a_deny "$level" "net.enable"        org.freedesktop.NetworkManager.enable-disable-network session-dependent
    # Same reasoning as the package attempts: `nmcli networking off` succeeding on the open control
    # would take the network away from a VM that U1/U5 are about to use.
    if [ "$level" != control ] && command -v nmcli >/dev/null 2>&1; then
        a_corroborate "net.off" "nmcli networking off" -- nmcli networking off
        a_corroborate "net.add" "nmcli connection add type dummy" -- nmcli connection add type dummy ifname auros-probe0 con-name auros-probe
    elif [ "$level" = control ]; then
        a_note "net.attempts" "not attempted on the open control: taking the network off a VM that U1/U5 are about to use would contaminate the run. The polkit answers above carry the evidence."
    fi
}

a_suite_update_timer() {
    local level="$1" t found=0
    printf '\n-- try to stop the machine updating itself ---------------------------------------------\n'
    # The unit names belong to the update layer (task A4), not to this one, and there is more than
    # one: D22 records that uupd -- not bootc-fetch-apply-updates -- is the real update driver on
    # this base, and build/30-update-agent.sh enables both paths. So this does not stop at the first
    # timer it finds: a mode that blocks one and not the other is a mode under which a user can
    # half-disable updates, and "half" is not a state the product has a word for.
    #
    # ONE list, $A_UPDATE_TIMERS, shared with open/assert.sh's floor check. A second hand-kept copy
    # is how uupd.timer went missing from one of them.
    #
    # If NONE is active that is a FAIL, not a skip: a machine that is not updating itself is
    # precisely the abandoned laptop we sell against. Check S10 asserts the same thing from outside.
    a_deny "$level" "update.manage-units" org.freedesktop.systemd1.manage-units
    for t in "${A_UPDATE_TIMERS[@]}"; do
        systemctl is-active --quiet "$t" 2>/dev/null || continue
        found=1
        a_ok "update.active.$t" "$t is active"
        # Under `control` we do NOT attempt to stop the timer. The open image is a machine under
        # test that the rest of the matrix expects to keep updating itself; an attempt that happened
        # to succeed would leave U1 looking at a machine we disabled. The polkit answer above is the
        # discriminating half in any case.
        if [ "$level" != control ]; then
            a_corroborate "update.stop.$t"    "systemctl stop $t"    -- systemctl stop "$t"
            a_corroborate "update.disable.$t" "systemctl disable $t" -- systemctl disable "$t"
            a_corroborate "update.mask.$t"    "systemctl mask $t"    -- systemctl mask "$t"
            # Three attempts failing is not the same as the timer surviving. Ask the timer.
            if systemctl is-active --quiet "$t"; then
                a_ok "update.survived.$t" "$t is still active after three attempts to stop it"
            else
                a_bad "update.survived.$t" "$t is NO LONGER ACTIVE after the attempts above -- one of them worked"
            fi
        fi
    done
    [ "$found" = 1 ] || a_bad "update.timer-active" "no update timer is active (looked for ${A_UPDATE_TIMERS[*]})"
}

# a_suite_accounts <level> -- owner decision A4 (control repo docs/ACCOUNTS.md §3): on managed the
# Users page is SHOWN only to aurosadmin members (policy/managed/root/etc/kde5rc), on locked to everyone
# so a pupil can choose their own password there (§5); either way what stops
# a pupil managing accounts is polkit alone, and this is where that is attempted. The probe is never
# in aurosadmin (a_controls aborts if it is), so it is the pupil case. accountsservice's own default
# for user-administration is auth_admin for every subject, so this is primary evidence: `open`
# answers 2 (open/assert.sh, level control), managed must not answer 0, locked must answer 1.
a_suite_accounts() {
    local level="$1"
    printf '\n-- try to manage accounts (A4: the Users page is for aurosadmin only) --------------------\n'
    a_deny "$level" "accounts.user-admin" org.freedesktop.accounts.user-administration
    # The pupil's ONE account change, in every desktop mode: their own password (owner decisions,
    # ACCOUNTS.md §5). 10-auros-own-password.rules grants it only to a subject in an active local
    # session, and this probe has none, so accountsservice's own default answers: auth_admin, pkcheck 2.
    #   1  this mode's deny swallowed it -- the pupil's only door is shut (00-auros-<mode>.rules must
    #      leave change-own-password out of its guarded set)
    #   0  granted to a subject with NO session -- a daemon could give itself a password
    # B12 (desktop/assert-zero-terminal.sh) proves the grant itself, from inside a real session.
    local rc; rc="$(a_pk org.freedesktop.accounts.change-own-password)"
    case "$rc" in
        2) a_ok  "accounts.own-password" "org.freedesktop.accounts.change-own-password -- not refused outright, and not granted without a session (pkcheck 2)" ;;
        1) a_bad "accounts.own-password" "org.freedesktop.accounts.change-own-password -- REFUSED OUTRIGHT (pkcheck 1): a pupil cannot choose their own password, which is the one change every mode allows" ;;
        0) a_bad "accounts.own-password" "org.freedesktop.accounts.change-own-password -- AUTHORISED for a subject with no session (pkcheck 0): the grant must be for a person at the seat only" ;;
        *) a_bad "accounts.own-password" "org.freedesktop.accounts.change-own-password -- pkcheck returned $rc (error). An error is not an answer." ;;
    esac
}

# a_suite_policy_immutable -- WHAT THIS ACTUALLY PROVES, stated plainly because the name oversells it.
#
# All four writes below fail for any unprivileged account on any bootc host in any mode: /etc is
# root-owned and /usr is read-only. That is a property of the BASE IMAGE, not of the policy mode,
# and an audit was right to call a `locked` run that counted them as mode evidence padded.
#
# They are kept, and they are run in `open` as well, for two honest reasons:
#   1. As a floor. If a future change made /etc group-writable, or shipped a sudoers drop-in that
#      granted the probe a write, these would go red -- in every mode, which is correct.
#   2. As the negative control for themselves. Running them at level `control` in open/assert.sh
#      puts "these four failed on an unlocked image too" into the matrix output, so no reader
#      mistakes them for evidence about locked.
a_suite_policy_immutable() {
    local level="${1:-hard}"
    printf '\n-- try to edit the policy itself (a FLOOR property of the base, not of this mode) -------\n'
    a_try "$level" "self.sudoers"    "write a new sudoers drop-in"   -- /usr/bin/install -m 0440 /dev/null /etc/sudoers.d/00-auros-probe
    a_try "$level" "self.polkit"     "write a new polkit rule"       -- /usr/bin/install -m 0644 /dev/null /etc/polkit-1/rules.d/00-auros-probe.rules
    a_try "$level" "self.stamp"      "overwrite the mode stamp"      -- /usr/bin/tee /usr/lib/auros/policy-mode
    a_try "$level" "self.kdeglobals" "overwrite /etc/xdg/kdeglobals" -- /usr/bin/tee /etc/xdg/kdeglobals
    if [ "$level" != control ]; then
        a_note "self.scope" "these four fail on an OPEN image too (open/assert.sh runs the same list as its control). They are the base's read-only-/usr and root-owned-/etc floor, not this mode."
    fi
}

# ── KDE Kiosk (KAuthorized), the half of `locked` that had nothing attempting it ──────────────────
#
# D3 justifies choosing KDE on the grounds that "the KDE Kiosk framework is the only lockdown
# mechanism strong enough to make our locked and kiosk policy modes provable rather than merely
# configured", and locked/description.md tells the customer verbatim that Dolphin's "Open Terminal
# Here", Kate's terminal panel and the run-command box are switched off. Until this suite existed,
# nothing on the machine attempted any of it: the claim rested on a .ini file merged into
# /etc/xdg/kdeglobals and believed.
#
# That file is also the single most fragile artefact in the mode. build/40-windows-feel.sh runs
# AFTER build/20-policy.sh and installs /etc/xdg/kdeglobals as a WHOLE FILE, which removes the three
# KDE Kiosk groups apply-policy merged into it. polkit, sudoers, PAM, dconf and the unit masks all
# survive that; the KDE restrictions do not. 20-policy.sh warns about the ordering at build time.
# This suite is what notices it at runtime.
#
# THE ATTEMPT, and why it observes a marker file rather than an exit code:
#   KAuthorized is a library check inside the KDE application, evaluated before it opens a window,
#   so QT_QPA_PLATFORM=offscreen reaches it. But a denied Konsole puts up a KMessageBox and its exit
#   code is not a documented contract, and a modal error dialog under an offscreen platform is a
#   hang waiting to be scored as flakiness. So we do not read an exit code. We ask the application
#   to run a script that touches a marker, wait, and look for the marker:
#
#       marker present  => the door is OPEN, a shell ran
#       marker absent   => the door is SHUT, nothing ran
#
#   The same attempt is made on `open` with expect=open, where the marker MUST appear. If it does
#   not, the KDE runtime cannot start headless for this subject and every KAuthorized denial in this
#   matrix is an artefact -- so open/assert.sh goes red and says exactly that, instead of every
#   other mode going green on an attempt that could never have succeeded.
A_KDE_SETTLE=${AUROS_KDE_SETTLE:-10}

a_kde_bin() {  # first of the KDE binaries that exists, printed; non-zero if none
    local b; for b in "$@"; do command -v "$b" >/dev/null 2>&1 && { printf '%s' "$b"; return 0; }; done; return 1
}

# a_kde_door <id> <expect: open|shut> <binary> <description> -- <args...>
# @SCRIPT@ in the args is replaced with the path of a script that touches the marker.
a_kde_door() {
    local id="$1" expect="$2" bin="$3" desc="$4"; shift 4; [ "${1:-}" = "--" ] && shift
    local dir marker script a rc=0
    local -a args=()

    if ! command -v "$bin" >/dev/null 2>&1; then
        if [ "$expect" = shut ]; then
            a_ok "$id" "$desc -- $bin is not on this image, so this door does not exist"
        else
            a_bad "$id" "$desc -- $bin is absent, so this control cannot show that the attempt is capable of succeeding. Without it, a refusal of the same attempt under locked/kiosk proves nothing."
        fi
        return
    fi

    dir="$(mktemp -d "${TMPDIR:-/tmp}/auros-kde.XXXXXX" 2>/dev/null)" || {
        a_bad "$id" "$desc -- no writable temporary directory, so the attempt could not be made at all. An attempt that was not made is not a denial."
        return
    }
    marker="$dir/a-shell-ran"
    script="$dir/open-a-shell"
    # /bin/sh, not /usr/bin/bash: the only thing this script has to do is prove that SOMETHING ran
    # it, and the narrowest possible interpreter dependency is the right one for a probe. (It also
    # lets policy/tests/assert-lib.test.sh drive this function on a host that is not Fedora.)
    { printf '#!/bin/sh\n'; printf 'touch %s\n' "$marker"; printf 'exit 0\n'; } > "$script"
    chmod 0755 "$script"
    mkdir -p "$dir/home/.config" "$dir/home/.cache" "$dir/home/.local/share" "$dir/run"
    chmod 0700 "$dir/run"

    for a in "$@"; do args+=("${a//@SCRIPT@/$script}"); done

    # A private HOME so the result is about /etc/xdg, which is where our restriction lives, and not
    # about whatever a previous run left in the probe account's own config.
    env QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES='*=false' QT_ACCESSIBILITY=0 \
        HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/.config" \
        XDG_CACHE_HOME="$dir/home/.cache" XDG_DATA_HOME="$dir/home/.local/share" \
        XDG_RUNTIME_DIR="$dir/run" \
        timeout "$A_TIMEOUT" "$bin" "${args[@]}" >/dev/null 2>&1 </dev/null &
    local pid=$! i=0
    while [ "$i" -lt "$A_KDE_SETTLE" ] && [ ! -e "$marker" ]; do sleep 1; i=$(( i + 1 )); done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || rc=$?
    pkill -u "$(id -u)" -x "$bin" >/dev/null 2>&1 || true

    if [ -e "$marker" ]; then
        if [ "$expect" = open ]; then
            a_ok "$id" "$desc -- a shell RAN through $bin. This subject can open this door, so a refusal of it under managed/locked/kiosk is evidence."
        else
            a_bad "$id" "$desc -- A SHELL RAN through $bin. KAuthorized did not stop it, so the sentence we print in locked/description.md ('Dolphin's Open Terminal Here, Kate's terminal panel and the run-command box are all switched off') is FALSE on this image. The usual cause is /etc/xdg/kdeglobals being replaced as a whole file after apply-policy ran -- see the kdeglobals ordering hazard in policy/README.md."
        fi
    else
        if [ "$expect" = shut ]; then
            a_ok "$id" "$desc -- refused: no shell ran within ${A_KDE_SETTLE}s"
        else
            a_bad "$id" "$desc -- no shell ran within ${A_KDE_SETTLE}s on an image that restricts nothing. The KDE runtime cannot be exercised headlessly by this subject, which means every KAuthorized denial recorded elsewhere in this matrix is an artefact of the probe rather than evidence of the mode. Fix the probe or stop claiming the KDE restrictions in description.md."
        fi
    fi
    rm -rf "$dir"
}

# a_kde_cascade <id> <key> <want> -- corroborating only: KDE's OWN config cascade resolves the key,
# which is strictly stronger than grepping /etc/xdg/kdeglobals (it honours $XDG_CONFIG_DIRS ordering
# and the [$i] immutability marker) but is still a read, so it is never primary evidence.
a_kde_cascade() {
    local id="$1" key="$2" want="$3" kr got
    kr="$(a_kde_bin kreadconfig6 kreadconfig5)" || { a_note "$id" "no kreadconfig on this image; the corroborating read was skipped (the attempt above is the evidence)"; return; }
    got="$(env QT_QPA_PLATFORM=offscreen "$kr" --file kdeglobals --group "KDE Action Restrictions" --key "$key" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        a_note "$id" "KDE's own cascade resolves [KDE Action Restrictions] $key=$got [corroborating]"
    else
        a_bad "$id" "KDE's own cascade resolves [KDE Action Restrictions] $key='${got:-<unset>}', not '$want'. The group did not survive the merge into /etc/xdg/kdeglobals."
    fi
}

# a_suite_kde_kiosk <level>
#   hard      locked  -- every door must be shut
#   allow     managed -- the terminal is deliberately KEPT, so the doors must be OPEN. Asserting
#                        that is what stops managed and locked quietly converging.
#   control   open    -- nothing is restricted, so the doors must be OPEN. This is the control that
#                        makes `hard` mean something.
#   absent    kiosk   -- the KDE applications were deleted; a_absent covers them, and a door that
#                        does not exist is checked as absence rather than as refusal.
a_suite_kde_kiosk() {
    local level="$1" expect konsole kioclient
    case "$level" in
        hard)          expect=shut ;;
        allow|control) expect=open ;;
        absent)        expect=shut ;;
        *) a_bad "kde.level" "a_suite_kde_kiosk called with unknown level '$level'"; return ;;
    esac
    printf '\n-- try to reach a shell through a KDE application (KAuthorized) ------------------------\n'

    konsole="$(a_kde_bin konsole konsole5 || true)"
    kioclient="$(a_kde_bin kioclient6 kioclient5 kioclient || true)"

    if [ "$level" = absent ]; then
        # kiosk removed them. Say so as absence -- "the binary is gone" is a stronger statement than
        # "the binary refused", and absent-binaries.list already gates the build on it.
        [ -n "$konsole" ]   && a_bad "kde.konsole.absent"   "konsole is still on a kiosk image at $(command -v "$konsole")" \
                            || a_ok  "kde.konsole.absent"   "no konsole on this image"
        [ -n "$kioclient" ] && a_note "kde.kioclient.present" "$kioclient survived the removal pass (it comes from kde-cli-tools, which the dependency closure keeps -- D12). The door is attempted below anyway, so if KAuthorized is not shutting it this goes red." \
                            || a_ok  "kde.kioclient.absent"  "no kioclient on this image"
    fi

    if [ -n "$konsole" ] || [ "$expect" = open ]; then
        a_kde_door "kde.konsole" "$expect" "${konsole:-konsole}" \
                   "konsole -e <script> (action/shell_access)" -- -e @SCRIPT@
    fi
    if [ -n "$kioclient" ] || [ "$expect" = open ]; then
        # KIO's OpenUrlJob consults the same KAuthorized shell_access before it will execute a local
        # binary, so this is a second, independent door through one gate. Dolphin's "Open Terminal
        # Here" and Kate's terminal panel are the same gate reached from a GUI we cannot script.
        a_kde_door "kde.kioclient" "$expect" "${kioclient:-kioclient6}" \
                   "kioclient exec <script> (action/shell_access via KIO)" -- exec @SCRIPT@
    fi

    case "$level" in
        hard)   a_kde_cascade "kde.cascade.shell_access" shell_access false
                a_kde_cascade "kde.cascade.run_command"  run_command  false ;;
        allow)  a_note "kde.cascade" "managed does not restrict shell_access; nothing to corroborate" ;;
        control) a_note "kde.cascade" "open restricts nothing; the two doors above are the control" ;;
    esac
}

a_finish() {
    local mode="$1"
    printf '\n'
    if [ "${#A_CORROBORATING[@]}" -gt 0 ]; then
        printf 'EVIDENCE CLASSIFICATION -- %d of the attempts above are CORROBORATING, not primary:\n' "${#A_CORROBORATING[@]}"
        printf '  %s\n' "${A_CORROBORATING[*]}"
        printf '  These fail for this probe subject on an OPEN image too (it is a sessionless system\n'
        printf '  account, /etc is root-owned and /usr is read-only), so their failure here is\n'
        printf '  consistent with the mode but does not on its own prove it. open/assert.sh runs the\n'
        printf '  same attempts as an explicit negative control and prints which of them succeeded.\n'
        printf '  The primary evidence for this mode is the pkcheck answers (1 vs 2) and the KDE\n'
        printf '  KAuthorized doors, both of which differ between open and locked for this subject.\n\n'
    fi
    if [ "${#A_CONTROL_NON_DISCRIMINATING[@]}" -gt 0 ] || [ "${#A_CONTROL_DISCRIMINATING[@]}" -gt 0 ]; then
        printf 'NEGATIVE CONTROL -- what this unlocked image allowed the probe subject to do:\n'
        printf '  succeeded here (so a refusal elsewhere is evidence): %s\n' "${A_CONTROL_DISCRIMINATING[*]:-none}"
        printf '  failed here too (corroborating only elsewhere):      %s\n\n' "${A_CONTROL_NON_DISCRIMINATING[*]:-none}"
    fi
    if [ "$A_FAIL" -eq 0 ]; then
        printf 'RESULT: pass (%d attempts, %d failures) mode=%s\n' "$A_PASS" "$A_FAIL" "$mode"
    else
        printf 'RESULT: fail (%d attempts, %d failures) mode=%s\n' "$A_PASS" "$A_FAIL" "$mode"
    fi
    if [ "$A_JSON" = 1 ]; then
        local l first=1
        printf '\n--- json ---\n{"mode":"%s","verdict":"%s","passed":%d,"failed":%d,"corroborating":"%s","control_discriminating":"%s","control_non_discriminating":"%s","attempts":[' \
               "$(a_json_str "$mode")" "$([ "$A_FAIL" -eq 0 ] && echo pass || echo fail)" "$A_PASS" "$A_FAIL" \
               "$(a_json_str "${A_CORROBORATING[*]:-}")" \
               "$(a_json_str "${A_CONTROL_DISCRIMINATING[*]:-}")" \
               "$(a_json_str "${A_CONTROL_NON_DISCRIMINATING[*]:-}")"
        for l in "${A_LINES[@]}"; do
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"status":"%s","id":"%s","detail":"%s"}' \
                "$(a_json_str "${l%%|*}")" \
                "$(a_json_str "$(printf '%s' "$l" | cut -d'|' -f2)")" \
                "$(a_json_str "$(printf '%s' "$l" | cut -d'|' -f3-)")"
        done
        printf ']}\n'
    fi
    [ "$A_FAIL" -eq 0 ]
}

for _a in "$@"; do [ "$_a" = "--json" ] && A_JSON=1; done

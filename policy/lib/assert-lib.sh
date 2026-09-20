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

set -uo pipefail

A_PASS=0
A_FAIL=0
A_LINES=()
A_JSON=0
A_TIMEOUT=${AUROS_ASSERT_TIMEOUT:-25}

a_json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

a_ok()  { A_PASS=$(( A_PASS + 1 )); A_LINES+=("pass|$1|$2"); printf 'PASS  %-34s %s\n' "$1" "$2"; }
a_bad() { A_FAIL=$(( A_FAIL + 1 )); A_LINES+=("fail|$1|$2"); printf 'FAIL  %-34s %s\n' "$1" "$2"; }
a_note(){ printf '      %-34s %s\n' "$1" "$2"; }

a_abort() {
    printf 'FAIL  %-34s %s\n' "control" "$1"
    printf '\nRESULT: fail (assertion aborted before it could prove anything)\n'
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

a_must_succeed() {  # a_must_succeed <id> <description> -- <command...>
    local id="$1" desc="$2"; shift 2; [ "${1:-}" = "--" ] && shift
    local out rc
    out="$(timeout "$A_TIMEOUT" "$@" 2>&1 </dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then a_ok "$id" "$desc"; else a_bad "$id" "$desc -- failed (exit $rc): $(printf '%s' "$out" | head -1)"; fi
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
# pkcheck exit codes: 0 authorised, 1 not authorised, 2 error, 3 authorisation could be obtained by
# authenticating. We care about the difference between 1 and 3, because it IS the difference between
# `locked` and `managed`.
a_pk() { pkcheck --action-id "$1" --process "$$" >/dev/null 2>&1; echo $?; }

a_pk_hard_deny() {  # locked/kiosk: the answer is no, and no password changes it
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        0) a_bad "$id" "$action -- AUTHORISED. The mode is not in force for this action." ;;
        1) a_ok  "$id" "$action -- refused outright (pkcheck 1)" ;;
        3) a_bad "$id" "$action -- answerable with an administrator password (pkcheck 3). That is 'managed' behaviour; 'locked' requires a hard refusal." ;;
        *) a_bad "$id" "$action -- pkcheck returned $rc (error). An error is not a denial." ;;
    esac
}

a_pk_admin_only() {  # managed: not now, but an administrator at this machine could
    local id="$1" action="$2" rc; rc="$(a_pk "$action")"
    case "$rc" in
        0) a_bad "$id" "$action -- AUTHORISED without any administrator. The mode is not in force." ;;
        1|3) a_ok "$id" "$action -- not authorised for this user (pkcheck $rc)" ;;
        *) a_bad "$id" "$action -- pkcheck returned $rc (error). An error is not a denial." ;;
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

    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx aurosadmin; then
        a_abort "the probe account is in the aurosadmin group. It is supposed to be the unprivileged case."
    fi

    command -v pkcheck >/dev/null 2>&1 || a_abort "pkcheck is not installed. Without it the difference between 'refused outright' and 'an administrator could authorise this' cannot be observed, and that difference is the difference between locked and managed."

    timeout 10 dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 \
        || a_abort "the system D-Bus is not reachable from this process. Every polkit denial below would then be a dead bus rather than a policy decision."

    local rc; rc="$(a_pk org.auros.policy.control-allow)"
    [ "$rc" = 0 ] || a_abort "the positive control action org.auros.policy.control-allow returned pkcheck $rc. It is our own action, allow_any=yes, and no mode rule touches it. If this subject cannot be authorised for THAT, it cannot be authorised for anything, and every denial in this run would be an artefact of the probe rather than evidence of the policy."

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

a_finish() {
    local mode="$1"
    printf '\n'
    if [ "$A_FAIL" -eq 0 ]; then
        printf 'RESULT: pass (%d attempts, %d failures) mode=%s\n' "$A_PASS" "$A_FAIL" "$mode"
    else
        printf 'RESULT: fail (%d attempts, %d failures) mode=%s\n' "$A_PASS" "$A_FAIL" "$mode"
    fi
    if [ "$A_JSON" = 1 ]; then
        local l first=1
        printf '\n--- json ---\n{"mode":"%s","verdict":"%s","passed":%d,"failed":%d,"attempts":[' \
               "$(a_json_str "$mode")" "$([ "$A_FAIL" -eq 0 ] && echo pass || echo fail)" "$A_PASS" "$A_FAIL"
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

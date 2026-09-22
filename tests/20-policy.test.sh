#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/20-policy.test.sh — the policy layer's build step, and the B5 rule that governs every mode's
# runtime assertion.
#
# ── THE RULE ─────────────────────────────────────────────────────────────────────────────────────
#
# matrix/checks.yaml B5 has `fails_on: configured-but-not-effective`, and policy/lib/assert-lib.sh
# states the consequence in its own header:
#
#     An assertion may not read a configuration file and conclude that a restriction is in force.
#     It must ATTEMPT THE FORBIDDEN THING and observe the attempt fail.
#
# The reason is commercial rather than academic. A polkit rule file that is present but not loaded, a
# KDE Kiosk group that apply-policy merged into /etc/xdg/kdeglobals and build/40-windows-feel.sh then
# overwrote as a whole file — both leave every configuration file exactly where it should be. An
# assertion that reads those files reports a locked machine. The machine is not locked. We would be
# telling a school their laptops are locked down when they are not, and the claim is one a student
# can disprove by pressing a key.
#
# ── WHAT THIS FILE ADDS THAT THE OTHER POLICY TESTS DO NOT ───────────────────────────────────────
#
#   policy/tests/assert-lib.test.sh   the attempt PRIMITIVES can go red, and for the right reason
#   policy/tests/policy-lib.test.sh   apply-policy's file manipulation
#   desktop/tests/b12-modes.test.sh   B12 per mode, against the real assert-zero-terminal.sh
#   HERE                              (a) the B5 LINT: a static scan of every mode's assert.sh for
#                                         decisions reached by reading a file with nothing attempted,
#                                         which is the failure B5 is named after; and
#                                     (b) build/20-policy.sh's own assertions.
#
# The lint is the part that keeps working after everyone who remembers B5 has moved on. It is itself
# demonstrated red, against a synthetic mode whose assert.sh greps a file and calls it proof — which
# is exactly what a fifth mode written in a hurry would look like.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

P="$REPO/build/20-policy.sh"
POL="$REPO/policy"
STUBS="$(stubdir)"
install_sed_shim "$STUBS"
export PATH="$STUBS:$PATH"

printf '20-policy.sh — the policy payload, and the B5 rule every mode must obey  (%s)\n' "$T_SED_MODE"

PRE='set -uo pipefail
step() { :; }
did()  { echo "DID $*"; }
found(){ echo "FOUND $*"; }
warn() { echo "WARN $*"; }
die()  { echo "DIE $*" >&2; exit 1; }
record(){ :; }
'

MODES="$(for d in "$POL"/*/; do m="$(basename "$d")"; [ -f "$d/assert.sh" ] && printf '%s\n' "$m"; done)"
[ -n "$MODES" ] || t_abort "no policy/<mode>/assert.sh found — this test would be vacuous"
printf '       modes found: %s\n' "$(printf '%s' "$MODES" | tr '\n' ' ')"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "THE B5 LINT — a decision reached by reading a file, with nothing attempted"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# HOW IT WORKS, so that a future reader can argue with it rather than delete it:
#
#   Every a_ok/a_bad call is a DECISION. The lint walks back from each decision to the conditional
#   that governs it and asks whether that conditional is nothing but a file predicate — `[ -e`,
#   `[ -f`, `[ -r`, a bare `grep` on a path, `cat`. If it is, and no attempt primitive appears in the
#   same conditional, the decision was reached by reading a file.
#
#   Such a decision is not automatically wrong. `open`'s release checks are exactly this on purpose:
#   "no other mode left its rule file behind" is a statement about FILES and there is nothing to
#   attempt. So the lint does not ban them — it requires each one to be on the allowlist below with a
#   sentence saying why reading a file is the right evidence there. A new one that nobody argued for
#   fails the suite.
#
# The allowlist is `<mode>:<check-id>  <reason>`. Adding a line to it is a deliberate act.
ALLOW=$(cat <<'ALLOWLIST'
open:release.*          apply-policy RELEASING a mode is a statement about files, by construction: the
                        claim is "this rule file is gone", and there is no forbidden operation to
                        attempt because the whole point is that nothing is restricted here. The
                        effectiveness half is covered by the canary — open/assert.sh requires
                        org.auros.policy.control-deny to be PERMITTED, which no file check could fake.
kiosk:shell.list        reads the absent-binaries list to know WHAT to attempt. The decision it makes
                        is only "the list is missing", which is a genuine inability to run the check
                        and is reported as a failure rather than skipped. Every entry in the list is
                        then put through a_absent, which is an attempt.
kiosk:app.configured    /etc/auros/kiosk.conf naming an application is a configuration fact and
                        nothing else can stand in for it. The EFFECTIVENESS half is asserted
                        separately and by observation: app.service must be active and app.compositor
                        must find the recorded compositor actually running as auroskiosk.
kiosk:app.compositor-record   reads what the build recorded. It exists to make the NEXT assertion
                        possible (compare the record against the running process) and goes red when
                        the record is missing, which is the only thing it claims.
kiosk:session.vt-flag   reads the build's recorded VT posture, then checks the RUNNING compositor's
                        own /proc/<pid>/cmdline against it. The file read alone is explicitly
                        insufficient and the code says so: "without the argv that is a claim, not a
                        check".
ALLOWLIST
)

LINT_OUT="$(
python3 - "$POL" <<'PY'
import os, re, sys
root = sys.argv[1]
ATTEMPT = re.compile(r'\b(a_must_fail|a_must_succeed|a_corroborate|a_control_observe|a_try|a_deny|'
                     r'a_absent|a_pk|a_pk_allow|a_pk_hard_deny|a_pk_admin_only|a_pk_not_hard_denied|'
                     r'a_kde_door|a_suite_[a-z_]+|pkcheck|systemctl is-active|pgrep|getent)\b')
FILEPRED = re.compile(r'(\[\s+-[efrsdx]\s|\[\[\s+-[efrsdx]\s|\bgrep\b|\bcat\b|\bsed -n\b)')
DECISION = re.compile(r'^\s*(a_ok|a_bad)\s+"([^"]+)"')

findings = []
for mode in sorted(os.listdir(root)):
    f = os.path.join(root, mode, 'assert.sh')
    if not os.path.isfile(f):
        continue
    lines = open(f).read().splitlines()
    for i, line in enumerate(lines):
        m = DECISION.match(line)
        if not m:
            continue
        # Walk back to the governing conditional: the nearest if/elif/case/&&-test above, within a
        # short window. Beyond that the decision is unconditional and is not a file-read decision.
        cond = None
        for j in range(i, max(-1, i - 12), -1):
            l = lines[j]
            if re.match(r'^\s*(if|elif)\s', l) or re.search(r'^\s*case\s', l):
                cond = l
                break
            if re.match(r'^\s*(for|while)\s', l):
                break
        if cond is None:
            continue
        if FILEPRED.search(cond) and not ATTEMPT.search(cond):
            findings.append("%s:%s\t%s\t%s" % (mode, m.group(2), os.path.basename(f), cond.strip()[:90]))
print("\n".join(findings))
PY
)"

# A lint that finds nothing might mean the code is clean — or that the scanner is broken. Both look
# identical from the outside, which is the permanently-green shape again. So the scanner is first
# pointed at a mode written the WRONG way, and has to find it.
SYNTH="$(newroot)/policy"; mkdir -p "$SYNTH/badmode"
cat > "$SYNTH/badmode/assert.sh" <<'BAD'
#!/usr/bin/bash
. /usr/share/auros/policy/lib/assert-lib.sh "$@"
a_controls
a_expect_mode badmode
# This is the anti-pattern in its natural habitat: the rule file is present, therefore the rule is in
# force. It is not. The file could be unparseable, the daemon could have failed to load it, or a
# later drop-in could override it, and every one of those states passes this.
if [ -f /etc/polkit-1/rules.d/00-auros-badmode.rules ]; then
    a_ok "root.blocked" "the polkit rule file is installed"
else
    a_bad "root.blocked" "the polkit rule file is missing"
fi
if grep -q 'shell_access=false' /etc/xdg/kdeglobals; then
    a_ok "kde.shell" "shell_access is set to false"
else
    a_bad "kde.shell" "shell_access is not set"
fi
a_finish badmode
BAD
SYNTH_OUT="$(
python3 - "$SYNTH" <<'PY'
import os, re, sys
root = sys.argv[1]
ATTEMPT = re.compile(r'\b(a_must_fail|a_must_succeed|a_corroborate|a_control_observe|a_try|a_deny|'
                     r'a_absent|a_pk|a_pk_allow|a_pk_hard_deny|a_pk_admin_only|a_pk_not_hard_denied|'
                     r'a_kde_door|a_suite_[a-z_]+|pkcheck|systemctl is-active|pgrep|getent)\b')
FILEPRED = re.compile(r'(\[\s+-[efrsdx]\s|\[\[\s+-[efrsdx]\s|\bgrep\b|\bcat\b|\bsed -n\b)')
DECISION = re.compile(r'^\s*(a_ok|a_bad)\s+"([^"]+)"')
findings = []
for mode in sorted(os.listdir(root)):
    f = os.path.join(root, mode, 'assert.sh')
    if not os.path.isfile(f):
        continue
    lines = open(f).read().splitlines()
    for i, line in enumerate(lines):
        m = DECISION.match(line)
        if not m:
            continue
        cond = None
        for j in range(i, max(-1, i - 12), -1):
            l = lines[j]
            if re.match(r'^\s*(if|elif)\s', l) or re.search(r'^\s*case\s', l):
                cond = l; break
            if re.match(r'^\s*(for|while)\s', l):
                break
        if cond is None:
            continue
        if FILEPRED.search(cond) and not ATTEMPT.search(cond):
            findings.append("%s:%s" % (mode, m.group(2)))
print("\n".join(findings))
PY
)"
assert_has "the lint catches a polkit rule asserted by file existence"  "badmode:root.blocked" "$SYNTH_OUT"
assert_has "the lint catches a KDE restriction asserted by grep"        "badmode:kde.shell"    "$SYNTH_OUT"

# Now the real modes. Every finding must be on the allowlist, by mode and check id.
allowed() { # <mode:id>
  local key="$1" pat
  while IFS= read -r line; do
    case "$line" in ''|[[:space:]]*) continue ;; esac
    pat="${line%% *}"
    case "$key" in $pat) return 0 ;; esac
  done <<EOF
$ALLOW
EOF
  return 1
}

unexplained=0
if [ -n "$LINT_OUT" ]; then
  while IFS=$'\t' read -r key file cond; do
    [ -n "$key" ] || continue
    if allowed "$key"; then
      ok "B5 lint: $key reads a file, and the allowlist says why"
    else
      bad "B5 lint: $key in $file decides from a file with nothing attempted — that is the 'configured but not effective' state B5 exists to catch. Either attempt the forbidden operation, or add a line to the allowlist in this file saying why reading is the right evidence.  [$cond]"
      unexplained=$((unexplained+1))
    fi
  done <<EOF
$LINT_OUT
EOF
else
  ok "B5 lint: no mode decides anything by reading a configuration file"
fi
[ "$unexplained" -eq 0 ] && ok "B5 lint: every file-read decision in every mode is accounted for"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "every mode ATTEMPTS the operations its own promises are about"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# The lint above catches a decision made the wrong way. This catches the other shape: a mode that
# makes a promise and then asserts NOTHING about it at all — which no scan of the assertions it did
# write could ever notice.
#
# The suites are the mechanism, shared so that locked, managed and kiosk cannot drift into asserting
# three different things about the same promise. The ANSWER differs per mode (hard / admin / control
# / absent / allow); the attempt does not.
SUITES="a_suite_no_root a_suite_no_software a_suite_no_network_change a_suite_update_timer a_suite_policy_immutable a_suite_kde_kiosk"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  f="$POL/$m/assert.sh"
  for s in $SUITES; do
    if grep -qE "^[[:space:]]*$s([[:space:]]|\$)" "$f"; then
      ok "$m/assert.sh runs $s"
    else
      bad "$m/assert.sh never calls $s — that promise is asserted by nothing on the machine"
    fi
  done
  # The canary is what turns every denial in the run into evidence rather than an artefact of a probe
  # with no logind session. A mode without one can pass on an image where our rules never installed.
  if grep -qE '^[[:space:]]*a_pk_(hard_deny|admin_only|allow) +"canary' "$f"; then
    ok "$m/assert.sh has a canary — a refusal our rules alone cause"
  else
    bad "$m/assert.sh has no canary assertion; every denial in it could be an artefact of the probe subject"
  fi
  grep -qE '^[[:space:]]*a_controls' "$f" \
    && ok "$m/assert.sh runs the positive controls before anything else" \
    || bad "$m/assert.sh does not run a_controls — a subject that can be authorised for nothing makes every denial meaningless"
  grep -qE "^[[:space:]]*a_expect_mode +$m" "$f" \
    && ok "$m/assert.sh asserts it is running against a '$m' image" \
    || bad "$m/assert.sh does not assert the image's own mode stamp — it could be auditing a different mode entirely"
done <<EOF
$MODES
EOF

# open/assert.sh is the negative control for the whole design and has one extra obligation: it must
# run the same suites at level `control`, so the matrix output says in plain text which attempts fail
# on an UNRESTRICTED image too. Without that, a refusal that has nothing to do with our policy reads
# as evidence for it.
OPEN="$POL/open/assert.sh"
n_control="$(grep -cE '^[[:space:]]*a_suite_[a-z_]+ +control' "$OPEN" | tr -d ' ')"
if [ "${n_control:-0}" -ge 5 ]; then
  ok "open/assert.sh runs $n_control suites at level 'control' — the negative control is real"
else
  bad "open/assert.sh runs only ${n_control:-0} suites at level 'control'; a denial under locked cannot be shown to be ours"
fi
assert_has "open requires the canary to be PERMITTED, which no file check could fake" \
  "a_pk_allow \"canary" "$(cat "$OPEN")"

# managed must NOT quietly assert locked's stricter promise. If it did, the two modes would be
# indistinguishable in CI while being different products in a school.
MANAGED="$POL/managed/assert.sh"
assert_not "managed does not use locked's hard-deny canary" 'a_pk_hard_deny "canary' "$(cat "$MANAGED")"
assert_has "managed uses the admin-only canary instead"     'a_pk_admin_only "canary' "$(cat "$MANAGED")"
assert_has "managed keeps the terminal, and attempts it"    'a_suite_kde_kiosk          allow' "$(cat "$MANAGED")"
assert_has "locked shuts the terminal, and attempts it"     'a_suite_kde_kiosk          hard'  "$(cat "$POL/locked/assert.sh")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "build/20-policy.sh — the mode stamp, without which check B5 has nothing to assert against"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
STAMP_BLOCK="$(extract_between "$P" '^\[ -r /usr/lib/auros/policy-mode \]' '^did "mode stamped on this image' \
  | rootify /usr/lib/auros/policy-mode)"

stamp_case() { # <mode or 'absent'>
  local root; root="$(newroot)"; mkdir -p "$root/usr/lib/auros"
  [ "$1" = absent ] || printf '%s\n' "$1" > "$root/usr/lib/auros/policy-mode"
  ROOT="$root" bash -c "$PRE
$STAMP_BLOCK"
}
run_check policy.stamp green "apply-policy wrote the mode stamp" -- stamp_case open
assert_has "and prints which mode it is" "open" "$T_LAST_OUT"
run_check policy.stamp red "apply-policy did not write the mode stamp" -- stamp_case absent
assert_has "says B5 would have nothing to assert against" "nothing to assert against" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the payload — all four modes as data in one image, with the permissions they need"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Spec §3: there is exactly ONE base image, so the base cannot BE a mode. It carries the mechanism and
# a recipe selects a mode in its own derived layer. That only works if every mode's payload actually
# arrives — and if assert.sh arrives EXECUTABLE, because check B5 runs it.
#
# The sudoers drop-ins keep 0440 inside the payload as well as after installation, so that a copy of
# the payload is never a copy of a file sudo would silently refuse to read. That is a mode whose
# restrictions do not apply, with no error anywhere.
# DEST and SRC are the script's own variables, set above the extracted range, so they are supplied
# here rather than rewritten — pointing DEST at the fake root is the whole mechanism.
PAYLOAD_BLOCK="$(extract_between "$P" '^rm -rf "$DEST"' '^record installed-payload')"
stub "$STUBS" chown <<'SH'
#!/usr/bin/env bash
exit 0
SH

R="$(newroot)"
DEST="$R/usr/share/auros/policy"
run_check policy.payload green "the real policy/ tree installs" \
  -- env SRC="$POL" DEST="$DEST" bash -c "$PRE
$PAYLOAD_BLOCK"
while IFS= read -r m; do
  [ -n "$m" ] || continue
  assert_file "$m/assert.sh reached the payload" "$DEST/$m/assert.sh"
  if [ -x "$DEST/$m/assert.sh" ]; then ok "$m/assert.sh is executable — check B5 can run it"
  else bad "$m/assert.sh is NOT executable; check B5 would be unable to run it and the mode would be unverifiable"; fi
done <<EOF
$MODES
EOF
assert_file "the shared assertion library reached the payload" "$DEST/lib/assert-lib.sh"
for f in $(find "$DEST" -path '*/sudoers.d/*' -type f 2>/dev/null); do
  perm="$(ls -l "$f" | cut -c1-10)"
  case "$perm" in
    -r--r-----) ok "$(basename "$(dirname "$(dirname "$f")")")'s sudoers drop-in is 0440 inside the payload too" ;;
    *) bad "$f is $perm inside the payload; sudo silently refuses to read a sudoers file with the wrong mode, so the mode's restrictions would not apply and nothing would say so" ;;
  esac
done

# The two entry points must NOT remain inside the payload: one is called by recipes, one by the check
# matrix, and neither should be reachable only through a path that names a mode.
ENTRY_BLOCK="$(extract_between "$P" '^install_file "$SRC/apply-policy"' '^did "the check matrix proves it with')"
out="$(SRC="$POL" DEST="$DEST" LIBEXEC="$R/libexec" bash -c "$PRE
install_file() { mkdir -p \"\$(dirname \"\$2\")\"; cp \"\$1\" \"\$2\"; chmod \"\$3\" \"\$2\"; }
$ENTRY_BLOCK" 2>&1)"
assert_file  "apply-policy is installed where recipes call it"  "$R/libexec/apply-policy"
assert_file  "assert-policy is installed where the matrix calls it" "$R/libexec/assert-policy"
assert_nofile "apply-policy no longer sits inside the payload"  "$DEST/apply-policy"
assert_nofile "assert-policy no longer sits inside the payload" "$DEST/assert-policy"

# THE ORDERING HAZARD, which is real rather than theoretical and is written down in 20-policy.sh
# itself: build/40-windows-feel.sh runs AFTER this step and installs /etc/xdg/kdeglobals as a WHOLE
# FILE, removing the three KDE Kiosk groups apply-policy merged into it. polkit, sudoers, PAM, dconf
# and the unit masks survive; the KDE restrictions do not. The warning has to still be there, and
# the runtime suite that would notice has to still be wired up.
assert_has "20-policy.sh still warns about the 40-windows-feel ordering hazard" "40-windows-feel.sh" "$(cat "$P")"
assert_has "and locked's assertion still attempts the KDE doors that hazard would open" \
  "a_suite_kde_kiosk" "$(cat "$POL/locked/assert.sh")"
t_exempt policy.payload \
  "one acceptance: the payload either installs or the build dies on a shell error, and there is no
       input that makes it refuse. Its real content is asserted on the resulting FILESYSTEM above —
       every mode's assert.sh present and executable, every sudoers drop-in 0440, both entry points
       moved out of the payload — which is where a silent partial install would show."


# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "build/20-policy.sh — which mode the BASE is built as, when nobody says"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Spec §3: there is exactly one base image, and it is built `open`. Every matrix result for the base
# — B1 and B12 especially — is a statement about an OPEN image, and a recipe selects its own mode in
# a derived layer. Change the default and the matrix keeps passing while describing something else:
# B12's "install an application through the GUI" would be measuring a locked image that forbids it.
#
# The default lives in one parameter expansion, `${AUROS_POLICY:-open}`, and nothing read it back.
MODE_BLOCK="$(extract_between "$P" '^MODE="' '^record policy-mode')"

mode_run() { # <root> [AUROS_POLICY value|'']
  local root="$1"
  mkdir -p "$root/libexec"
  # A recording stub rather than the real apply-policy: what is under test is WHICH MODE the build
  # asks for, not what apply-policy then does with it (policy/tests/ owns that).
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" > "%s/asked-for"\n' "$root" > "$root/libexec/apply-policy"
  chmod 0755 "$root/libexec/apply-policy"
  if [ -n "${2:-}" ]; then
    LIBEXEC="$root/libexec" AUROS_POLICY="$2" bash -c "$PRE
$MODE_BLOCK"
  else
    env -u AUROS_POLICY LIBEXEC="$root/libexec" bash -c "$PRE
$MODE_BLOCK"
  fi
}

R="$(newroot)"
run_check policy.base-mode green "AUROS_POLICY is unset — the base builds OPEN" -- mode_run "$R" ''
assert_eq  "apply-policy was asked for 'open'" "open" "$(cat "$R/asked-for" 2>/dev/null || true)"
assert_has "and said which mode it was activating" "activating: open" "$T_LAST_OUT"
assert_not "with no single-mode warning, because this is not a single-mode image" "single-mode image" "$T_LAST_OUT"

# The override still has to work — a recipe building a locked image is the supported path, and it
# must carry the ordering warning, because 40-windows-feel.sh runs afterwards and rewrites kdeglobals.
R="$(newroot)"
run_check policy.base-mode green "AUROS_POLICY=locked is honoured" -- mode_run "$R" locked
assert_eq  "apply-policy was asked for 'locked'" "locked" "$(cat "$R/asked-for" 2>/dev/null || true)"
assert_has "and the ordering hazard is stated"   "ORDERING HAZARD" "$T_LAST_OUT"

R="$(newroot)"
run_check policy.base-mode green "AUROS_POLICY=open explicitly is the same as unset" -- mode_run "$R" open
assert_eq  "apply-policy was asked for 'open'" "open" "$(cat "$R/asked-for" 2>/dev/null || true)"
assert_not "and no warning, because it IS the default" "single-mode image" "$T_LAST_OUT"

# The refusal: apply-policy failing must stop the build. An image whose mode was never applied but
# which still gets stamped is the worst of both.
R="$(newroot)"
mkdir -p "$R/libexec"; printf '#!/usr/bin/env bash\nexit 1\n' > "$R/libexec/apply-policy"; chmod 0755 "$R/libexec/apply-policy"
run_check policy.base-mode red "apply-policy itself fails" -- bash -c "$PRE
set -e
LIBEXEC='$R/libexec'
$MODE_BLOCK"

group "A4 — the Users page: hidden by default in /etc/kde5rc, shown to an aurosadmin session"
# The hide must be a per-KEY immutable in kde5rc: KConfig reads kde5rc first, so a group-level [$i]
# there would lock [KDE Control Module Restrictions] before /etc/xdg/kdeglobals adds its pages.
a4_hide() { # <kde5rc> <kdeglobals ini>
  grep -qxF '[KDE Control Module Restrictions]' "$1" && grep -qxF 'kcm_users[$i]=false' "$1" \
    && ! grep -q '^kcm_users' "$2"
}
A4BIN="$(stubdir)"
printf '#!/bin/sh\n[ "$1" = -nG ] && echo "$A4_GROUPS"\n' > "$A4BIN/id"; chmod +x "$A4BIN/id"
a4_env() { # <groups> <script> — sourced as startplasma would; 0 iff the session skips kde5rc
  A4_GROUPS="$1" PATH="$A4BIN:$PATH" sh -c ". '$2'; [ \"\${KDE_SKIP_KDERC:-}\" = 1 ]"
}
for m in managed; do
  run_check policy.a4-hide green "$m: kcm_users hidden in kde5rc (per key), not in the kdeglobals group" \
    -- a4_hide "$POL/$m/root/etc/kde5rc" "$POL/$m/kdeglobals/20-control-module-restrictions.ini"
  ENV="$POL/$m/root/etc/xdg/plasma-workspace/env/50-auros-admin-users-page.sh"
  run_check policy.a4-env green "$m: an aurosadmin member's session skips kde5rc" -- a4_env "school-it aurosadmin" "$ENV"
  run_check policy.a4-env red   "$m: a pupil's session does not"                 -- a4_env "pupil" "$ENV"
  run_check policy.a4-env red   "$m: nor a member of a group merely NAMED like it" -- a4_env "pupil aurosadmins" "$ENV"
done
B="$(newroot)"; sed 's/^\[KDE Control Module Restrictions\]$/[KDE Control Module Restrictions][$i]/' "$POL/managed/root/etc/kde5rc" > "$B/kde5rc"
run_check policy.a4-hide red "a group-level [\$i] in kde5rc (would lock out kdeglobals' pages)" \
  -- a4_hide "$B/kde5rc" "$POL/managed/kdeglobals/20-control-module-restrictions.ini"
printf '[KDE Control Module Restrictions][$i]\nkcm_users=false\n' > "$B/ini"
run_check policy.a4-hide red "kcm_users still in the immutable kdeglobals group (no session could show it)" \
  -- a4_hide "$POL/managed/root/etc/kde5rc" "$B/ini"

# Owner decision (2): on locked a pupil may choose their own password in the GUI, so the Users page
# is no longer hidden there. What still stops them managing accounts is polkit (below and B5/B12).
run_check policy.a4-locked-shown red "locked: no kde5rc hides the Users page from a pupil" \
  -- test -e "$POL/locked/root/etc/kde5rc"
run_check policy.a4-locked-shown green "managed still hides it (the control for the line above)" \
  -- test -e "$POL/managed/root/etc/kde5rc"

group "own password: the ONE account change a pupil makes — the real rule files, evaluated"
# polkit's JS API, as far as these files use it (polkit(8) "AUTHORIZATION RULES"): rule files run in
# lexical order and the first rule returning a value decides. `default` = no rule answered, so
# accountsservice's own default applies (auth_admin for change-own-password and user-administration).
PKJS="$(newroot)/pk.js"
cat > "$PKJS" <<'JS'
const fs = require("fs"), vm = require("vm");
const [files, id, user, groups, local, active] = [process.argv[2].split(":"), ...process.argv.slice(3)];
const rules = [];
const R = { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin", AUTH_SELF: "auth_self", NOT_HANDLED: null };
const polkit = { Result: R, addRule: f => rules.push(f), addAdminRule() {}, log() {} };
for (const f of files.filter(f => fs.existsSync(f)).sort((a, b) => a.split("/").pop() < b.split("/").pop() ? -1 : 1))
  vm.runInNewContext(fs.readFileSync(f, "utf8"), { polkit });
const subject = { user, local: local === "1", active: active === "1", isInGroup: g => groups.split(",").includes(g) };
for (const r of rules) { const v = r({ id }, subject); if (v) { console.log(v); process.exit(0); } }
console.log("default");
JS
OWN=org.freedesktop.accounts.change-own-password
UADM=org.freedesktop.accounts.user-administration
pk_says() { # <mode> <action> <user> <groups> <local 0|1> <active 0|1> <expected answer>
  local got; got="$(node "$PKJS" "$POL/$1/root/etc/polkit-1/rules.d/00-auros-$1.rules:$POL/common/root/etc/polkit-1/rules.d/10-auros-own-password.rules" "$2" "$3" "$4" "$5" "$6")" || return 2
  echo "$1 $2 $3 -> $got"; [ "$got" = "$7" ]
}
if command -v node >/dev/null 2>&1; then
  for m in locked managed open; do
    run_check policy.own-password green "$m: a pupil at the seat may choose their own password" -- pk_says $m $OWN pupil pupil 1 1 yes
    run_check policy.own-password red   "$m: …a service account with no session may not (upstream default applies)" -- pk_says $m $OWN aurosprobe aurosprobe 0 0 yes
  done
  run_check policy.own-password red   "kiosk: nobody signs in, so nobody chooses a password"              -- pk_says kiosk $OWN auroskiosk auroskiosk 1 1 yes
  run_check policy.own-password green "locked: a pupil managing accounts is refused outright"            -- pk_says locked $UADM pupil pupil 1 1 no
  run_check policy.own-password green "locked: …and so is changing their own name or picture (ONLY the password)" \
    -- pk_says locked org.freedesktop.accounts.change-own-user-data pupil pupil 1 1 no
  run_check policy.own-password green "locked: the IT account may manage accounts, with its password" -- pk_says locked $UADM school-it school-it,aurosadmin 1 1 auth_admin
  run_check policy.own-password red   "locked: the pupil is NOT granted account management"              -- pk_says locked $UADM pupil pupil 1 1 yes
else
  t_exempt policy.own-password "node is not installed here; the rule files cannot be evaluated"
fi

t_finish "20-policy.sh"

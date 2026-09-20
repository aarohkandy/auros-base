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

t_finish "20-policy.sh"

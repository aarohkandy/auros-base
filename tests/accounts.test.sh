#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# tests/accounts.test.sh — desktop/accounts/auros-accounts, the first-boot account creator.
#
# The SHIPPING script is run, rootified onto a fake machine, with useradd/usermod/chpasswd/getent/stat
# stubbed against that machine's passwd and shadow. What must hold (control repo docs/ACCOUNTS.md):
#   - the declared accounts exist afterwards, and an admin is in the policy's admin group
#   - first passwords come only from the enrolment file, only as crypt(3) hashes, only through
#     chpasswd -e on stdin, and the file is gone afterwards whatever happened
#   - zero accounts that can sign in is a failure ON SCREEN (issue text + marker), never a done-marker
#   - no hash or password ever appears in what the script prints
# Every value below is an obviously fake placeholder. None is a password anyone uses.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

S="$REPO/desktop/accounts/auros-accounts"
[ -s "$S" ] || t_abort "no $S"
SCRIPT="$(rootify /usr/lib/auros /etc/auros /var/lib/auros /etc/issue.d /run/auros < "$S")"
printf 'auros-accounts — first-boot accounts from the recipe\n'

FAKE_HASH='$6$fakesalt$FAKEHASHFORTESTSONLY'

STUBS="$(stubdir)"
stub "$STUBS" getent <<'EOF'
#!/usr/bin/env bash
case "$1" in passwd) f="$ROOT/etc/passwd" ;; shadow) f="$ROOT/etc/shadow" ;; *) exit 2 ;; esac
grep "^$2:" "$f" 2>/dev/null || exit 2
EOF
stub "$STUBS" useradd <<'EOF'
#!/usr/bin/env bash
# expects exactly: useradd -m -c <display> <name>
[ "$1" = -m ] && [ "$2" = -c ] && [ $# -eq 4 ] || { echo "useradd stub: unexpected args $*" >&2; exit 2; }
echo "useradd $4" >> "$ROOT/calls"
n=$(( $(wc -l < "$ROOT/etc/passwd") + 1000 ))
printf '%s:x:%s:%s:%s:/var/home/%s:/bin/bash\n' "$4" "$n" "$n" "$3" "$4" >> "$ROOT/etc/passwd"
printf '%s:!!:20000:0:99999:7:::\n' "$4" >> "$ROOT/etc/shadow"
EOF
stub "$STUBS" usermod <<'EOF'
#!/usr/bin/env bash
[ "$1" = -a ] && [ "$2" = -G ] || exit 2
echo "$3:$4" >> "$ROOT/etc/group.members"
EOF
stub "$STUBS" chpasswd <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -e ] || { echo "chpasswd stub: called without -e" >&2; exit 2; }
while IFS=: read -r n h; do
  echo "$n:$h" >> "$ROOT/chpasswd.in"
  awk -F: -v OFS=: -v n="$n" -v h="$h" '$1==n {$2=h} {print}' "$ROOT/etc/shadow" > "$ROOT/shadow.new"
  mv "$ROOT/shadow.new" "$ROOT/etc/shadow"
done
EOF
stub "$STUBS" stat <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_STAT:-0:600}"
EOF
stub "$STUBS" plymouth <<'EOF'
#!/usr/bin/env bash
echo "plymouth $*" >> "$ROOT/calls"
EOF

# machine <mode> <accounts.json body or 'none'> <enrolment file body or 'none'>
machine() {
  local root; root="$(newroot)"
  mkdir -p "$root/usr/lib/auros" "$root/etc/auros/enrolment"
  printf 'root:x:0:0:root:/root:/bin/bash\nadm:x:3:4:adm:/var/adm:/sbin/nologin\n' > "$root/etc/passwd"
  printf 'root:!:20000::::::\nadm:*:20000::::::\n' > "$root/etc/shadow"
  printf '%s\n' "$1" > "$root/usr/lib/auros/policy-mode"
  [ "$2" = none ] || printf '%s\n' "$2" > "$root/usr/lib/auros/accounts.json"
  if [ "$3" = none ]; then rmdir "$root/etc/auros/enrolment"; else printf '%s\n' "$3" > "$root/etc/auros/enrolment/accounts.secret"; fi
  printf '%s' "$root"
}
run() { ROOT="$1" FAKE_STAT="${2:-0:600}" PATH="$STUBS:$PATH" bash -c "$SCRIPT"; }

TWO='{"schema":1,"accounts":[{"display_name":"Pupil","name":"pupil","role":"user"},{"display_name":"School IT","name":"school-it","role":"admin"}]}'

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "a managed school laptop, first boot, with its enrolment file"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
M="$(machine managed "$TWO" "school-it:$FAKE_HASH")"
run_check accounts green "both declared accounts, the admin's first password from the file" -- run "$M"
OUT="$T_LAST_OUT"
assert_has "pupil created"                         "pupil:x:"            "$(cat "$M/etc/passwd")"
assert_has "school-it created with its display name" "School IT"         "$(cat "$M/etc/passwd")"
assert_eq  "the admin joins aurosadmin, not wheel"  "aurosadmin:school-it" "$(cat "$M/etc/group.members")"
assert_has "the hash reached shadow"               "school-it:$FAKE_HASH:" "$(cat "$M/etc/shadow")"
assert_eq  "chpasswd -e got exactly the declared hash, on stdin" "school-it:$FAKE_HASH" "$(cat "$M/chpasswd.in")"
assert_nofile "the enrolment file is deleted"      "$M/etc/auros/enrolment/accounts.secret"
assert_nofile "and its directory"                  "$M/etc/auros/enrolment"
assert_file   "the done-marker is written"         "$M/var/lib/auros/accounts.done"
assert_nofile "no failure notice on screen"        "$M/etc/issue.d/50-auros-accounts.issue"
assert_not "the hash is never printed"             'FAKEHASH'            "$OUT"
assert_has "pupil without a password is said, not hidden" "pupil has no password yet" "$OUT"

run_check accounts green "the second boot: accounts exist, nothing re-created" -- run "$M"
assert_eq "useradd ran once per account, ever" "2" "$(grep -c '^useradd' "$M/calls")"

O="$(machine open "$TWO" "school-it:$FAKE_HASH")"
run_check accounts green "an open laptop" -- run "$O"
assert_eq "the admin joins wheel there" "wheel:school-it" "$(cat "$O/etc/group.members")"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "nobody can sign in — refused, on screen"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
N="$(machine managed "$TWO" none)"
run_check accounts red "no enrolment file on the install media" -- run "$N"
assert_has    "the reason is in the sign-in console's issue text" "NO ACCOUNT ANYONE CAN SIGN IN WITH" \
              "$(cat "$N/etc/issue.d/50-auros-accounts.issue" 2>/dev/null)"
assert_file   "the display-manager marker is set"   "$N/run/auros/accounts-failed"
assert_nofile "no done-marker, so the next boot retries" "$N/var/lib/auros/accounts.done"
assert_has    "and the boot splash is told"          "plymouth display-message" "$(cat "$N/calls")"

C="$(machine managed "$TWO" 'school-it:not-a-real-password')"
run_check accounts red "a plain password in the enrolment file is never used" -- run "$C"
assert_nofile "chpasswd never saw it"               "$C/chpasswd.in"
assert_not    "and it is never printed"             "not-a-real-password" "$T_LAST_OUT"
assert_nofile "the file is still deleted"           "$C/etc/auros/enrolment/accounts.secret"

L="$(machine managed "$TWO" "school-it:$FAKE_HASH")"
run_check accounts red "an enrolment file other accounts could read" -- run "$L" 0:644
assert_nofile "it is deleted unused"                "$L/etc/auros/enrolment/accounts.secret"
assert_nofile "and nothing was set from it"         "$L/chpasswd.in"

X="$(machine managed "$TWO" "intruder:$FAKE_HASH")"
run_check accounts red "the file names only an account the recipe never declared" -- run "$X"
assert_nofile "no password set for it"              "$X/chpasswd.in"

B="$(machine managed '{"schema":1,"accounts":[{"display_name":"x","name":"x;rm -rf /","role":"admin"}]}' "school-it:$FAKE_HASH")"
run_check accounts red "an account name the recipe compiler would have refused" -- run "$B"
assert_not    "nothing reached useradd"             "useradd" "$(cat "$B/calls" 2>/dev/null)"
assert_nofile "the enrolment file is still deleted" "$B/etc/auros/enrolment/accounts.secret"

Y="$(machine managed '{"schema":1,"accounts":[{"display_name":"Adm","name":"adm","role":"admin"}]}' "adm:$FAKE_HASH")"
run_check accounts red "a declared name that is a system account on this machine" -- run "$Y"

Z="$(machine managed none "school-it:$FAKE_HASH")"
run_check accounts red "an image built without a list of accounts" -- run "$Z"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "kiosk: nobody signs in"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
K="$(machine kiosk none "school-it:$FAKE_HASH")"
run_check accounts green "a kiosk with a stray enrolment file" -- run "$K"
assert_nofile "the secret is deleted unused"        "$K/etc/auros/enrolment/accounts.secret"
assert_nofile "no account created"                  "$K/calls"
assert_file   "done"                                "$K/var/lib/auros/accounts.done"

t_finish "auros-accounts"

#!/usr/bin/env bash
# The boot harness's desktop session — why B7, B8 and B12 failed in run 35566336512, and the log line
# that miscounted them. Every block under test is extracted from the shipping file.
#
#   autologin  Containerfile.testwrap writes [Autologin] where plasmalogin — this base's display
#              manager — actually reads it. Emulates plasmalogin v6.7.0's lookup
#              (src/common/MainConfigLoader.cpp): /usr/lib/plasmalogin/plasmalogin.conf.d/*, then
#              /etc/plasmalogin.conf.d/*, then /etc/plasmalogin.conf, later overriding earlier. The
#              old wrapper wrote only /etc/sddm.conf.d/, which plasmalogin never opens. The next one
#              did not write /etc/plasma-setup-done, so KDE plasma-setup's 99-plasma-setup.conf
#              (User=plasma-setup) outranked our 00- file and the wizard took seat0 (run 35616444839).
#   kcmlist    the agent's `kcmshell6 --list` survives having no display. kcmshell6 builds its
#              QApplication before it parses --list (kcmutils src/kcmshell/main.cpp), so as root in a
#              systemd unit it aborted, listed nothing, and B12 reported installed KCMs as absent.
#   session    the agent waits for the user's wayland socket, and when there is none says what it saw.
#   failcount  run-boot.sh counts failing CHECKS, not records; the agent reports each check per boot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
WRAP="$REPO/matrix/run/guest/Containerfile.testwrap"
AGENT_SH="$REPO/matrix/run/guest/auros-matrix-agent.sh"
RUN_BOOT="$REPO/matrix/run/run-boot.sh"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "autologin lands where plasmalogin reads it"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
AL_SRC="$(extract_raw "$WRAP" 'AUTOLOGIN}" = "1" \]; then' '^    fi; ' | sed 's/ *\\$//' | rootify /etc)"
bash -n <<<"$AL_SRC" || t_abort "the extracted autologin block does not parse"

# plasmalogin_user <root> — the [Autologin] User plasmalogin would use, or nothing.
plasmalogin_user() {
  local r=$1 f u='' v
  for f in "$r"/usr/lib/plasmalogin/plasmalogin.conf.d/* "$r"/etc/plasmalogin.conf.d/* "$r"/etc/plasmalogin.conf; do
    [ -f "$f" ] || continue
    v=$(awk -F= '/^\[/{g=$0} g=="[Autologin]" && $1=="User"{print $2}' "$f" | tail -1)
    [ -n "$v" ] && u=$v
  done
  printf '%s' "$u"
}
# boot_like_aurora <root> — what Aurora's first boot does before plasmalogin reads its config.
#   /etc/plasmalogin.conf: Fedora's sample, every key commented (plasma-login-manager.spec Source13).
#   plasma-setup.service, ConditionPathExists=!/etc/plasma-setup-done (files/plasma-setup.service.in),
#   runs bootutil, which writes 99-plasma-setup.conf (src/bootutil/bootutil.cpp:28,84-86).
boot_like_aurora() {
  printf '[Autologin]\n#Relogin=false\n#Session=\n#User=\n' > "$1/etc/plasmalogin.conf"
  [ -e "$1/etc/plasma-setup-done" ] && return 0
  mkdir -p "$1/etc/plasmalogin.conf.d"
  printf '[Autologin]\nUser=plasma-setup\nSession=plasma\n' > "$1/etc/plasmalogin.conf.d/99-plasma-setup.conf"
}
autologin_case() { # <src> <AUTOLOGIN> -> exit 0 iff plasmalogin would autologin "auros" into plasma
  local R; R="$(newroot)"
  ROOT="$R" TEST_USER=auros AUTOLOGIN="$2" bash -c "$1" || return 2
  boot_like_aurora "$R"
  [ "$(plasmalogin_user "$R")" = auros ] || { echo "plasmalogin would autologin: [$(plasmalogin_user "$R")]; files: $(cd "$R" && find etc -type f)"; return 1; }
  grep -rqx 'Session=plasma' "$R"/etc/plasmalogin.conf.d || { echo "no Session=plasma"; return 1; }
}
run_check autologin green "the shipping wrapper: plasmalogin autologins the test user" -- autologin_case "$AL_SRC" 1
run_check autologin red "AUTOLOGIN=0 (--no-autologin): no autologin" -- autologin_case "$AL_SRC" 0
OLD_AL="$(sed 's# \$ROOT/etc/plasmalogin.conf.d##' <<<"$AL_SRC")"
[ "$OLD_AL" != "$AL_SRC" ] || t_abort "the sddm-only mutation did not apply"
run_check autologin red "run 35566336512's wrapper — /etc/sddm.conf.d only — autologins nobody on plasmalogin" -- autologin_case "$OLD_AL" 1
NOFLAG_AL="$(/usr/bin/grep -v 'plasma-setup-done' <<<"$AL_SRC")"
[ "$NOFLAG_AL" != "$AL_SRC" ] || t_abort "the no-marker mutation did not apply"
run_check autologin red "run 35616444839's wrapper — no plasma-setup-done — seat0 goes to plasma-setup" -- autologin_case "$NOFLAG_AL" 1
assert_has "…and it names the wizard's user" "would autologin: [plasma-setup]" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "B12's KCM listing works with no display"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
KL="$(extract_lines "$AGENT_SH" '^KCMLIST=')"
S="$(stubdir)"
# Behaves as kcmutils' kcmshell6 does: no platform to connect to -> Qt aborts before --list is read.
stub "$S" kcmshell6 <<'SH'
#!/usr/bin/env bash
if [ "${QT_QPA_PLATFORM:-}" != offscreen ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
  echo 'qt.qpa.xcb: could not connect to display' >&2
  echo 'This application failed to start because no Qt platform plugin could be initialized.' >&2
  exit 134
fi
[ "${1:-}" = --list ] && printf '%s\n' 'The following modules are available:' 'kcm_networkmanagement - Network' 'kcm_printer_manager - Printers' 'kcm_regionandlang - Region'
SH
kcm_case() { env -u WAYLAND_DISPLAY -u DISPLAY KCMBIN="$S/kcmshell6" bash -c "$1"'
  for k in kcm_networkmanagement kcm_printer_manager kcm_regionandlang; do grep -q -- "$k" <<<"$KCMLIST" || { echo "missing $k"; exit 1; }; done'; }
run_check kcmlist green "root, no display: the three KCMs are listed" -- kcm_case "$KL"
OLD_KL='KCMLIST=$( "$KCMBIN" --list 2>/dev/null || true )'
[ "$OLD_KL" != "$KL" ] || t_abort "the shipping KCMLIST line is the old one"
run_check kcmlist red "run 35566336512's bare kcmshell6 --list lists nothing" -- kcm_case "$OLD_KL"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "the session wait finds the user's wayland socket, or says what it saw"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
SW="$(extract_between "$AGENT_SH" '^UID_T=\$(id -u' '^fi$' | rootify /run/user /etc /usr/lib)"
S2="$(stubdir)"
printf '#!/bin/sh\necho 1000\n' | stub "$S2" id
printf '#!/bin/sh\necho "c1 961 plasmalogin seat0 tty1"\n' | stub "$S2" loginctl
printf '#!/bin/sh\necho "plasmalogin[900]: Unable to find autologin session entry plasma"\n' | stub "$S2" journalctl
session_case() { # <root> -> exit 0 iff a session socket was found
  PATH="$S2:$PATH" ROOT="$1" TEST_USER=auros SESSION_WAIT=0 bash -c 'say() { printf "%s\n" "$*"; }
'"$SW"'
[ -n "$WL" ] && [ -z "$SESSION_DIAG" ]'
}
fake_dm() { # <root>
  mkdir -p "$1/etc/systemd/system" "$1/usr/lib/systemd/system" "$1/etc/sddm.conf.d" "$1/run/user/1000"
  : > "$1/usr/lib/systemd/system/plasmalogin.service"
  ln -s "$1/usr/lib/systemd/system/plasmalogin.service" "$1/etc/systemd/system/display-manager.service"
  printf '[Autologin]\nUser=auros\n' > "$1/etc/sddm.conf.d/00-auros-matrix-autologin.conf"
  : > "$1/run/user/1000/wayland-0.lock"   # a lock file is not a session
}
R1="$(newroot)"; fake_dm "$R1"
(cd "$R1/run/user/1000" && python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("wayland-0")') \
  || t_abort "could not create a unix socket for the green case"
run_check session green "a wayland socket in /run/user/UID is the session" -- session_case "$R1"
R2="$(newroot)"; fake_dm "$R2"
run_check session red "no socket (only its .lock): no session" -- session_case "$R2"
assert_has "…and it says so" "NO GRAPHICAL SESSION for auros" "$T_LAST_OUT"
assert_has "…naming the display manager" "display manager [plasmalogin.service]" "$T_LAST_OUT"
assert_has "…where autologin was actually written, and for whom" "sddm.conf.d/00-auros-matrix-autologin.conf(User=auros)" "$T_LAST_OUT"
assert_has "…and whether the first-boot wizard was completed" "/etc/plasma-setup-done ABSENT" "$T_LAST_OUT"
assert_has "…what logind has" "plasmalogin seat0" "$T_LAST_OUT"
assert_has "…and what the display manager logged" "Unable to find autologin session entry" "$T_LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
group "run-boot.sh counts failing checks, not records"
# ═════════════════════════════════════════════════════════════════════════════════════════════════
FC="$(extract_between "$RUN_BOOT" '^FAILED_IDS=\$(node -e' 'CHECKS_FILE")$')
$(extract_lines "$RUN_BOOT" '^FAILS=')"
CF="$(newroot)/boot-uefi-modern.jsonl"
{ echo '{"id":"B1","status":"pass"}'
  for b in 1 2; do for id in B2 B5 B7 B8 B11 B12; do
    st=fail; [ "$id" = B2 ] && st=pass; echo "{\"id\":\"$id\",\"status\":\"$st\"}"; done; done
  echo '{"id":"B3","status":"pass"}'; } > "$CF"
# B9 failed on boot 1 and passed on boot 2: failed (the collector's pessimistic rule).
printf '%s\n' '{"id":"B9","status":"fail"}' '{"id":"B9","status":"pass"}' >> "$CF"
fc_case() { CHECKS_FILE="$CF" bash -c "$1"'
echo "FAILS=$FAILS FAILED_IDS=$FAILED_IDS"; [ "$FAILS" = 6 ] && [ "$FAILED_IDS" = B5,B7,B8,B11,B12,B9 ]'; }
command -v node >/dev/null || t_abort "node is required (run-boot.sh requires it)"
run_check failcount green "5 checks failing on both boots + 1 on one boot = 6, each named once" -- fc_case "$FC"
OLD_FC="$(sed 's/^FAILS=.*/FAILS=$(grep -c '"'"'"status":"fail"'"'"' "$CHECKS_FILE" || true)/' <<<"$FC")"
[ "$OLD_FC" != "$FC" ] || t_abort "the fail-count mutation did not apply"
run_check failcount red "run 35566336512's grep -c counts records" -- fc_case "$OLD_FC"
assert_has "…and gets 11 for 6 checks" "FAILS=11" "$T_LAST_OUT"

t_finish "boot-session"

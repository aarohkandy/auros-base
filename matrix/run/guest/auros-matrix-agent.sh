#!/usr/bin/env bash
# auros-matrix-agent — runs INSIDE the test VM and reports B2..B12 over the second serial port.
#
# Why a serial port and not ssh: ssh would need a key, a network path and a listening daemon, each of
# which is a thing that can be broken by the very image we are testing. A serial port works on a machine
# whose networking is dead, which is exactly the machine we most need to hear from.
#
# Framing (the host parses these, everything else is noise):
#   #AUROS-BOOT# <n>            boot counter, first line of every boot
#   #AUROS#{json}               one check record
#   #AUROS-STATUS#{json}        booted digest / deployment count, emitted every boot
#   #AUROS-READY-SUSPEND#       the host should arm the QMP wakeup now
#   #AUROS-DONE# <phase>        end of this boot's work
#
# NOTHING here sleeps waiting for a result. Where we must wait, we wait on the event (`--wait`,
# a poll for a marker), because a fixed sleep scores a slow machine as a broken one.
set -uo pipefail

CFG=/usr/local/lib/auros-matrix/config.env
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"
: "${TEST_USER:=auros}"
: "${LOCALE:=}"
: "${KEYMAP:=}"
: "${POLICY_MODE:=open}"
: "${FLATPAK_REFS:=}"
: "${SUSPEND_TEST:=1}"
: "${FULL_BOOTS:=2}"

STATE=/var/lib/auros-matrix
mkdir -p "$STATE"
N=$(( $(cat "$STATE/boots" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$STATE/boots"

PORT=/dev/ttyS1
[ -w "$PORT" ] || PORT=/dev/console
exec 3>"$PORT"
say() { printf '%s\n' "$*" >&3; printf '%s\n' "$*"; }

T0=0
tick() { T0=$(date +%s%3N); }
emit() { # emit <id> <status> <detail>
  local id=$1 st=$2 d=${3-}
  local dur=0; [ "$T0" -gt 0 ] && dur=$(( $(date +%s%3N) - T0 )); T0=0
  d=${d//\\/\\\\}; d=${d//\"/\\\"}; d=$(printf '%s' "$d" | tr '\n\r\t' '   ')
  say "#AUROS#{\"id\":\"$id\",\"status\":\"$st\",\"detail\":\"$d\",\"duration_ms\":$dur}"
}
asuser() { runuser -u "$TEST_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$TEST_USER" 2>/dev/null || echo 1000)" "$@"; }

say "#AUROS-BOOT# $N"

# ── status: the booted digest. Everything in the update group is decided by this line. ────────────
# Three ways to read it, because neither jq nor python3 is guaranteed to exist in a pruned image, and
# "we could not read the digest" must never be indistinguishable from "the digest did not change".
booted_digest() {
  local j=$1 d=''
  if command -v jq >/dev/null 2>&1; then
    # Explicitly .status.booted — never a recursive search, which could return the STAGED digest and
    # make U1 report success for an update that has not actually taken effect yet.
    d=$(printf '%s' "$j" | jq -r '.status.booted.image.imageDigest // .status.booted.image.image.digest // empty' 2>/dev/null | head -1)
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  fi
  # No jq: narrow the JSON text to the "booted" object and take the digest from there. Crude, but it
  # cannot accidentally read the STAGED digest and call it the booted one, which is the mistake that
  # would make U1 and U4 both lie.
  d=$(printf '%s' "$j" | tr ',' '\n' | sed -n '/"booted"/,/"rollback"/p' | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
  [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  # Last resort: the human-readable form. The booted deployment is the one carrying the bullet.
  bootc status 2>/dev/null | sed -n '/[*] /,$p' | grep -oE 'sha256:[a-f0-9]{64}' | head -1
}

deployment_count() {
  local n=0
  if command -v ostree >/dev/null 2>&1; then
    n=$(ostree admin status 2>/dev/null | grep -cE '^[*[:space:]] [A-Za-z]' || echo 0)
  fi
  if [ "${n:-0}" -eq 0 ]; then
    n=$(bootc status 2>/dev/null | grep -cE '^[[:space:]]*(booted|staged|rollback):' || echo 0)
  fi
  printf '%s' "${n:-0}"
}

status_line() {
  local j dig n
  j=$(bootc status --json 2>/dev/null || echo '{}')
  dig=$(booted_digest "$j" | tr -d '\n')
  n=$(deployment_count)
  say "#AUROS-STATUS#{\"boot\":$N,\"digest\":\"${dig}\",\"deployments\":${n:-0}}"
}
status_line

FULL=0
[ "$N" -le "$FULL_BOOTS" ] && FULL=1
[ "${FORCE_FULL:-0}" = 1 ] && FULL=1

if [ "$FULL" != 1 ]; then
  say "#AUROS-DONE# status-only"
  exit 0
fi

# ── B2 — Not degraded. `--wait` blocks until startup finishes; that is a poll, not a sleep. ───────
tick
SYS=$(systemctl is-system-running --wait 2>/dev/null || true)
if [ "$SYS" = running ]; then emit B2 pass "systemctl is-system-running = running"
else
  FAILED=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  emit B2 fail "systemctl is-system-running = ${SYS:-<no answer>}; failed units: ${FAILED:-none}"
fi

# ── B4 — Locale and keyboard, exactly as declared ────────────────────────────────────────────────
tick
LC=$(localectl status 2>/dev/null | sed -n 's/.*System Locale: LANG=\(.*\)/\1/p' | head -1)
KM=$(localectl status 2>/dev/null | sed -n 's/.*VC Keymap: *\(.*\)/\1/p' | head -1)
if [ -z "$LOCALE" ] && [ -z "$KEYMAP" ]; then
  emit B4 pass "no locale/keymap declared for this image (base build); observed LANG=${LC:-unset} keymap=${KM:-unset}"
elif [ "$LC" = "$LOCALE" ] && { [ -z "$KEYMAP" ] || [ "$KM" = "$KEYMAP" ]; }; then
  emit B4 pass "LANG=$LC keymap=$KM == declared"
else
  emit B4 fail "declared LANG=$LOCALE keymap=$KEYMAP but observed LANG=${LC:-unset} keymap=${KM:-unset} — a Marathi recipe that boots in English is not a partial success"
fi

# ── B5 — Policy in force at RUNTIME, not merely configured ───────────────────────────────────────
tick
ASSERT="/usr/libexec/auros/policy-assert-${POLICY_MODE}"
P_PROBLEMS=''
if [ -x "$ASSERT" ]; then
  if ! runuser -u "$TEST_USER" -- "$ASSERT" > /tmp/policy-assert.log 2>&1; then
    P_PROBLEMS="${ASSERT} exited non-zero: $(tail -3 /tmp/policy-assert.log | tr '\n' ' ')"
  fi
else
  P_PROBLEMS="no runtime assertion script at ${ASSERT} (harness assumption about the policy layer's layout)"
fi
case "$POLICY_MODE" in
  locked|kiosk)
    # Corroboration the harness owns, independent of whatever the policy layer ships.
    if runuser -u "$TEST_USER" -- sudo -n true 2>/dev/null; then P_PROBLEMS="$P_PROBLEMS; unprivileged user obtained sudo without a password"; fi
    if runuser -u "$TEST_USER" -- rpm-ostree install --dry-run vim >/dev/null 2>&1; then P_PROBLEMS="$P_PROBLEMS; unprivileged user can stage a package install"; fi
    ;;
esac
if [ -n "$P_PROBLEMS" ]; then emit B5 fail "policy=${POLICY_MODE}: ${P_PROBLEMS#; }"
else emit B5 pass "policy=${POLICY_MODE}: ${ASSERT} passed as an unprivileged user, and the harness's own probes agree"; fi

# ── B6 — Network ─────────────────────────────────────────────────────────────────────────────────
tick
NM=$(systemctl is-active NetworkManager 2>/dev/null || echo inactive)
LEASE=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -E '^[a-z0-9]+:ethernet:connected' | head -1)
ROUTE=$(ip route show default 2>/dev/null | head -1)
DNSOK=no
for h in ghcr.io flathub.org example.com; do
  if getent hosts "$h" >/dev/null 2>&1; then DNSOK="$h"; break; fi
done
if [ "$NM" = active ] && [ -n "$LEASE" ] && [ -n "$ROUTE" ] && [ "$DNSOK" != no ]; then
  emit B6 pass "NetworkManager active; ${LEASE%%:*} connected; default route '${ROUTE}'; DNS resolved ${DNSOK}"
else
  emit B6 fail "NetworkManager=${NM}; virtio-net connected=${LEASE:-none}; default route=${ROUTE:-none}; DNS=${DNSOK}"
fi

# ── B7 — Audio ───────────────────────────────────────────────────────────────────────────────────
tick
PW=$(asuser systemctl --user is-active pipewire 2>/dev/null || echo inactive)
WP=$(asuser systemctl --user is-active wireplumber 2>/dev/null || echo inactive)
SINKS=$(asuser wpctl status 2>/dev/null | awk '/Sinks:/{f=1;next}/^ *$/{f=0}f' | grep -cE '[0-9]+\.' || echo 0)
if [ "$PW" = active ] && [ "$WP" = active ] && [ "${SINKS:-0}" -ge 1 ]; then
  emit B7 pass "pipewire+wireplumber active for ${TEST_USER}; wpctl enumerates ${SINKS} sink(s)"
else
  emit B7 fail "pipewire=${PW} wireplumber=${WP} sinks=${SINKS:-0} (the VM presents an ich9-intel-hda device; zero sinks means the stack, not the hardware)"
fi

# ── B8 — Graphics ────────────────────────────────────────────────────────────────────────────────
tick
UID_T=$(id -u "$TEST_USER" 2>/dev/null || echo 1000)
WL=$(ls /run/user/"$UID_T"/wayland-* 2>/dev/null | head -1)
SESS=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$TEST_USER" '$3==u{print $1; exit}')
STYPE=$( [ -n "$SESS" ] && loginctl show-session "$SESS" -p Type --value 2>/dev/null || echo '')
CRASH=$(journalctl -b --no-pager 2>/dev/null | grep -icE 'kwin_wayland.*(crash|segfault|core-dump)|plasmashell.*(segfault|core-dump)' || echo 0)
DRM=$(ls /sys/class/drm/ 2>/dev/null | grep -c '^card' || echo 0)
if [ "$POLICY_MODE" = kiosk ]; then
  if [ "${DRM:-0}" -ge 1 ] && [ "${CRASH:-0}" -eq 0 ]; then emit B8 pass "policy=kiosk: no desktop session by design; virtio-gpu present (${DRM} card node(s)); no compositor crash in the journal"
  else emit B8 fail "policy=kiosk: drm cards=${DRM} compositor crashes=${CRASH}"; fi
elif [ -n "$WL" ] && [ "$STYPE" = wayland ] && [ "${CRASH:-0}" -eq 0 ]; then
  emit B8 pass "wayland socket ${WL##*/}, session type wayland, ${DRM} drm card node(s), no compositor crash"
else
  emit B8 fail "wayland socket=${WL:-none} session type=${STYPE:-none} drm cards=${DRM} compositor crashes=${CRASH}"
fi

# ── B9 — Flatpaks ────────────────────────────────────────────────────────────────────────────────
tick
if ! command -v flatpak >/dev/null 2>&1; then
  emit B9 fail "flatpak is not installed in the image; userspace apps are supposed to come from Flathub (spec §3)"
else
  REMOTE=$(flatpak remotes --columns=name 2>/dev/null | grep -c '^flathub$' || echo 0)
  BAD=''
  for ref in $FLATPAK_REFS; do
    if ! flatpak install -y --noninteractive flathub "$ref" >/tmp/fp.log 2>&1; then BAD="$BAD ${ref}(install)"; continue; fi
    id=$ref; case "$ref" in */*) id=$(printf '%s' "$ref" | cut -d/ -f2);; esac
    ls /var/lib/flatpak/exports/share/applications/"${id}".desktop >/dev/null 2>&1 || BAD="$BAD ${ref}(no .desktop)"
  done
  if [ "${REMOTE:-0}" -lt 1 ]; then emit B9 fail "no 'flathub' remote configured"
  elif [ -n "$BAD" ]; then emit B9 fail "flathub remote present but:${BAD}"
  else emit B9 pass "flathub remote present; $(printf '%s' "$FLATPAK_REFS" | wc -w) app(s) installed with a .desktop each"; fi
fi

# ── B12 — Zero-terminal audit (D4) ───────────────────────────────────────────────────────────────
# The criterion is "the responsible .desktop entries and GUI components exist and launch". We assert
# exactly that and no more: we do NOT claim a window was mapped (see run/README.md).
tick
declare -A CAPS
case "$POLICY_MODE" in
  kiosk) CAPS=() ;;  # a kiosk image promises no in-session install/printer/language UI; nothing to audit
  *) CAPS=( [install-an-application]=org.kde.discover.desktop
            [wifi]=kcm_networkmanagement
            [printer]=kcm_printer_manager
            [language]=kcm_regionandlang ) ;;
esac
B12_BAD=''; B12_OK=''
KCMBIN=$(command -v kcmshell6 || command -v kcmshell5 || echo kcmshell6)
KCMLIST=$( "$KCMBIN" --list 2>/dev/null || true )
for cap in "${!CAPS[@]}"; do
  thing=${CAPS[$cap]}
  launched=0
  if [ "${thing##*.}" = desktop ]; then
    if [ -e "/usr/share/applications/$thing" ] || [ -e "/var/lib/flatpak/exports/share/applications/$thing" ]; then
      appid=${thing%.desktop}
      ( asuser gtk-launch "$appid" ) >"/tmp/b12-${cap}.log" 2>&1 &
      for _ in $(seq 1 15); do
        if pgrep -u "$TEST_USER" -f "$appid" >/dev/null 2>&1; then launched=1; break; fi
        sleep 2
      done
      pkill -u "$TEST_USER" -f "$appid" >/dev/null 2>&1 || true
      if [ "$launched" = 1 ]; then B12_OK="$B12_OK ${cap}(launched)"; else B12_BAD="$B12_BAD ${cap}(${thing} exists but never started)"; fi
    else
      B12_BAD="$B12_BAD ${cap}(no ${thing})"
    fi
  else
    if printf '%s' "$KCMLIST" | grep -q "$thing"; then
      ( asuser "$KCMBIN" "$thing" ) >"/tmp/b12-${cap}.log" 2>&1 &
      for _ in $(seq 1 15); do
        if pgrep -u "$TEST_USER" -f "$thing" >/dev/null 2>&1; then launched=1; break; fi
        sleep 2
      done
      pkill -u "$TEST_USER" -f "$thing" >/dev/null 2>&1 || true
      if [ "$launched" = 1 ]; then B12_OK="$B12_OK ${cap}(launched)"; else B12_BAD="$B12_BAD ${cap}(KCM ${thing} listed but never started)"; fi
    else
      B12_BAD="$B12_BAD ${cap}(no KCM ${thing})"
    fi
  fi
done
if [ "${#CAPS[@]}" -eq 0 ]; then
  emit B12 pass "policy=kiosk: the image makes no in-session install / Wi-Fi / printer / language promise, so there is nothing that could require a terminal"
elif [ -n "$B12_BAD" ]; then
  emit B12 fail "no GUI path for:${B12_BAD}. D4 is binding: if a promise needs a command line it stops being a promise."
else
  emit B12 pass "GUI path present for:${B12_OK} (existence + launch asserted; window mapping NOT asserted)"
fi

# ── B10 — Suspend and resume (APPROXIMATION ONLY, per checks.yaml) ───────────────────────────────
if [ "$SUSPEND_TEST" = 1 ]; then
  FAILED_BEFORE=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
  say "#AUROS-READY-SUSPEND#"
  tick
  # The host arms a QMP wakeup on seeing that marker. We give it a moment to arm, then go down.
  ( sleep 8; systemctl suspend ) >/dev/null 2>&1 &
  # Wait for the resume to have happened: the kernel logs PM: suspend exit on the way back up.
  RESUMED=0
  for _ in $(seq 1 60); do
    if journalctl -b -k --no-pager 2>/dev/null | grep -qE 'PM: suspend exit|PM: resume from suspend'; then RESUMED=1; break; fi
    sleep 5
  done
  SYS2=$(systemctl is-system-running 2>/dev/null || true)
  FAILED_AFTER=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
  if [ "$RESUMED" = 1 ] && [ "$SYS2" = running ] && [ "$FAILED_AFTER" -le "$FAILED_BEFORE" ]; then
    emit B10 pass "S3 suspend and QMP wakeup: kernel logged resume, system-running, no new failed units. APPROXIMATION — this proves the software path, not a real machine's firmware."
  else
    emit B10 fail "resume_logged=${RESUMED} is-system-running=${SYS2:-?} failed units ${FAILED_BEFORE}->${FAILED_AFTER}"
  fi
else
  emit B10 fail "suspend test was disabled for this run; B10 has no result and an absent result is a fail, not a skip"
fi

# ── B11 — Journal is clean. Last, so it catches damage done by everything above. ─────────────────
tick
AVC=$(journalctl -b --no-pager 2>/dev/null | grep -cE 'avc: *denied' || echo 0)
OOPS=$(journalctl -b -k --no-pager 2>/dev/null | grep -cE 'Oops:|kernel BUG at|general protection fault|Call Trace:' || echo 0)
TAINT=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)
FAILED_U=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
NFAIL=$(printf '%s' "$FAILED_U" | wc -w)
if [ "${AVC:-0}" -eq 0 ] && [ "${OOPS:-0}" -eq 0 ] && [ "${TAINT:-0}" -eq 0 ] && [ "${NFAIL:-0}" -eq 0 ]; then
  emit B11 pass "0 SELinux denials, 0 kernel oops, tainted=0, 0 failed units"
else
  emit B11 fail "SELinux denials=${AVC} kernel oops/BUG=${OOPS} tainted=${TAINT} failed units=${NFAIL} (${FAILED_U:-none}). A non-zero taint flag needs a DECISIONS.md entry, not an exception in this script."
fi

status_line
say "#AUROS-DONE# full"

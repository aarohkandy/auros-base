#!/usr/bin/env bash
#
# update-agent/tests/run-tests.sh -- the update agent's own tests.
#
# WHY THIS FILE EXISTS
#
# An audit found two fatal bugs in this layer, and the thing they had in common is more important
# than either bug:
#
#   * libexec/auros-update captured `bootc upgrade`'s exit status through a NEGATION
#     (`if ! out="$(...)"; then rc=$?`), which is 0 exactly when the command failed. The entire
#     offline/error branch was unreachable, and the freshness stamp -- the only mechanism in the
#     design that notices a machine which has stopped being patched -- was refreshed on every
#     timer run whatever happened. A laptop that had refused every update for two years reported
#     "last successful update fetch was 0 day(s) ago".
#
#   * greenboot/check/wanted.d/60-rollback-wiring.sh piped JSON into `python3 - <<'PY'`. The
#     heredoc overrides the pipe, so python read the heredoc as its program and then read an
#     already-consumed stdin. The block raised a traceback on EVERY boot of EVERY machine and
#     neither of its two tests ever executed.
#
# Both had been code-reviewed, both were extensively commented, and both had been "verified" by a
# check matrix that never looked at the state they write. Neither could have been caught by
# reading. Both are caught in under a second by running the script with a stub that fails.
#
# D19: a step that cannot fail is not a check. That applies to these scripts, and it applies to
# this file. Every test below has been watched to FAIL against the code as it was before the fix;
# `--self-test` re-demonstrates that on demand by reintroducing each bug into a scratch copy and
# asserting the test goes red.
#
# RUN:  bash update-agent/tests/run-tests.sh            # the suite
#       bash update-agent/tests/run-tests.sh --self-test # + prove the suite catches the old bugs
#
# Runs on macOS and on Linux with nothing but bash, python3 and coreutils. It does NOT need
# podman, qemu, a VM or a running systemd -- that is the point: this is the layer of testing that
# is cheap enough to run on every edit, underneath the VM check matrix, not a replacement for it.
# U1..U5 in matrix/ remain the only proof that the real machine does the real thing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UA="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0; FAILED_NAMES=()
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- expected [$2] got [$3]"; fi
}
# assert_has <label> <needle> <haystack>
assert_has() {
  case "$3" in *"$2"*) ok "$1";; *) bad "$1 -- output did not contain [$2]"; printf '%s\n' "$3" | sed 's/^/        | /' >&2;; esac
}
# assert_not <label> <needle> <haystack>
assert_not() {
  case "$3" in *"$2"*) bad "$1 -- output unexpectedly contained [$2]"; printf '%s\n' "$3" | sed 's/^/        | /' >&2;; *) ok "$1";; esac
}
assert_file() { if [ -e "$2" ]; then ok "$1"; else bad "$1 -- $2 does not exist"; fi; }
assert_nofile(){ if [ -e "$2" ]; then bad "$1 -- $2 exists and should not"; else ok "$1"; fi; }

# ── the fake machine ────────────────────────────────────────────────────────────────────────────
# A scratch root plus stub binaries on PATH. The scripts under test are run UNMODIFIED, straight
# out of the tree; AUROS_TEST_ROOT is the single seam they honour and it is empty on a real
# machine. Nothing here rewrites, copies or sed-patches the code being tested, because a test that
# edits its subject is testing the edit.
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/auros-ua-tests.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
STUBS="$TMPROOT/bin"; mkdir -p "$STUBS"

# GNU `date -d` is what the image has; macOS `date` does not have it. Use the real one when it is
# GNU and a python shim otherwise, and SAY which, so a green run on a laptop is not mistaken for a
# green run on the target.
if date -d @0 +%s >/dev/null 2>&1; then
  DATE_MODE="host GNU date"
else
  DATE_MODE="python shim (host date is not GNU)"
  cat > "$STUBS/date" <<'SH'
#!/usr/bin/env python3
import sys, datetime, time
a = sys.argv[1:]
def out(s): print(s)
if a[:1] == ["-uIseconds"]:
    out(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","+00:00")); sys.exit(0)
if a[:1] == ["-d"] and len(a) >= 3 and a[2] == "+%s":
    s = a[1].strip()
    try:
        if s.startswith("@"): out(str(int(float(s[1:])))); sys.exit(0)
        out(str(int(datetime.datetime.fromisoformat(s).timestamp()))); sys.exit(0)
    except Exception:
        sys.exit(1)
if a[:1] == ["+%s"]:
    out(str(int(time.time()))); sys.exit(0)
if a[:1] == ["-d"] and len(a) == 2 and a[1].startswith("@"):
    out(str(int(float(a[1][1:])))); sys.exit(0)
sys.exit(1)
SH
  chmod +x "$STUBS/date"
fi

# sleep: the retry path waits LOCK_RETRY_SECONDS=60. Stubbing the binary keeps the production
# script free of a "make the timeout small for tests" knob, which is a knob that eventually ships.
cat > "$STUBS/sleep" <<'SH'
#!/bin/sh
echo "stub-sleep ${1}s" >&2
exit 0
SH

# bootc: behaviour driven by files in the fake root, so a test says what the machine is doing.
#   $ROOT/.stub/bootc-status.json   -> what `bootc status --json` prints ('' means print nothing)
#   $ROOT/.stub/bootc-status-rc     -> its exit status (default 0)
#   $ROOT/.stub/bootc-upgrade-rc    -> `bootc upgrade` exit status (default 0)
#   $ROOT/.stub/bootc-upgrade-out   -> what it prints
#   $ROOT/.stub/bootc-calls         <- appended: every invocation, for asserting what ran
cat > "$STUBS/bootc" <<'SH'
#!/usr/bin/env bash
S="${AUROS_TEST_ROOT}/.stub"; mkdir -p "$S"
printf '%s\n' "$*" >> "$S/bootc-calls"
case "$1" in
  status)
    [ -f "$S/bootc-status.json" ] && cat "$S/bootc-status.json"
    exit "$(cat "$S/bootc-status-rc" 2>/dev/null || echo 0)" ;;
  upgrade)
    [ -f "$S/bootc-upgrade-out" ] && cat "$S/bootc-upgrade-out"
    exit "$(cat "$S/bootc-upgrade-rc" 2>/dev/null || echo 0)" ;;
  --version) echo "bootc 1.16.10 (stub)"; exit 0 ;;
esac
exit 0
SH

# systemctl: list-units --state=failed reads one unit name per line from $ROOT/.stub/failed-units
cat > "$STUBS/systemctl" <<'SH'
#!/usr/bin/env bash
S="${AUROS_TEST_ROOT}/.stub"
if [ "$1" = "list-units" ]; then
  [ -f "$S/failed-units" ] || exit 0
  while read -r u; do [ -n "$u" ] && printf '%s loaded failed failed stub unit\n' "$u"; done < "$S/failed-units"
  exit 0
fi
exit 0
SH

# loginctl: session list from $ROOT/.stub/sessions, lines of "<id> <active> <class>"
cat > "$STUBS/loginctl" <<'SH'
#!/usr/bin/env bash
S="${AUROS_TEST_ROOT}/.stub"
case "$1" in
  list-sessions) [ -f "$S/sessions" ] && awk '{print $1"  "$1"  stub  seat0"}' "$S/sessions"; exit 0 ;;
  show-session)
    id=$2
    [ -f "$S/sessions" ] || exit 1
    line=$(awk -v i="$id" '$1==i{print}' "$S/sessions"); [ -n "$line" ] || exit 1
    case " $* " in *" -p Active "*) echo "$line" | awk '{print $2}';; *" -p Class "*) echo "$line" | awk '{print $3}';; esac
    exit 0 ;;
esac
exit 0
SH
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# new_root [--healthy] -> echoes a fresh fake root
new_root() {
  local r; r="$(mktemp -d "$TMPROOT/root.XXXXXX")"
  mkdir -p "$r/.stub" "$r/var/lib/auros/update-agent" "$r/etc/auros/update-agent" \
           "$r/etc/greenboot" "$r/boot/grub2" "$r/run" "$r/usr/lib/systemd/system" \
           "$r/etc/systemd/system" "$r/proc/sys/kernel/random"
  printf '3f2b1c8a-0000-4000-8000-000000000001\n' > "$r/proc/sys/kernel/random/boot_id"
  printf '60.00 100.00\n' > "$r/proc/uptime"
  cp "$UA/etc/auros/update-agent/apply-policy" "$r/etc/auros/update-agent/apply-policy"
  cp "$UA/etc/auros/update-agent/failed-units.ignore" "$r/etc/auros/update-agent/failed-units.ignore"
  if [ "${1:-}" = "--healthy" ]; then
    : > "$r/run/ostree-booted"
    : > "$r/usr/lib/systemd/system/ostree-finalize-staged.service"
    : > "$r/usr/lib/systemd/system/greenboot-grub2-set-counter.service"
    printf 'if [ -n "${boot_counter}" ]; then decrement; fi\n' > "$r/boot/grub2/grub.cfg"
    printf 'GREENBOOT_MAX_BOOT_ATTEMPTS=2\nDISABLED_HEALTHCHECKS=()\n' > "$r/etc/greenboot/greenboot.conf"
  fi
  printf '%s' "$r"
}

# run_script <script> <root> -> stdout+stderr on fd1, exit status in $RC
RC=0
run_script() {
  local script=$1 root=$2; shift 2
  local out
  out="$(AUROS_TEST_ROOT="$root" bash "$script" "$@" 2>&1)"; RC=$?
  printf '%s' "$out"
}

epoch_iso() { # epoch_iso <seconds-ago>
  python3 -c 'import sys,datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).replace(microsecond=0).isoformat())' "$1"
}

printf '\033[1mAuros update-agent tests\033[0m   (date: %s)\n' "$DATE_MODE"

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "A. libexec/auros-update -- the fetch status is actually captured"
# ════════════════════════════════════════════════════════════════════════════════════════════════
AU="$UA/libexec/auros-update"

# A1 -- a failed fetch must be SEEN. This is the fatal one. Before the fix rc was 0 on this path,
# so the script fell through to the success branch and stamped last-successful-fetch.
r="$(new_root --healthy)"
echo 125 > "$r/.stub/bootc-upgrade-rc"
printf 'Source image rejected: invalid signature\n' > "$r/.stub/bootc-upgrade-out"
printf '{"status":{"booted":{"image":{"imageDigest":"sha256:aaa"}}}}\n' > "$r/.stub/bootc-status.json"
out="$(run_script "$AU" "$r")"
assert_eq  "A1 a rejected image exits 0 (U5: not a failed unit)" 0 "$RC"
assert_has "A1 says so on the console" "AUROS-UPDATE-FETCH-FAILED rc=125" "$out"
assert_file "A1 writes last-error" "$r/var/lib/auros/update-agent/last-error"
assert_file "A1 writes last-fetch-attempt" "$r/var/lib/auros/update-agent/last-fetch-attempt"
assert_nofile "A1 does NOT write last-successful-fetch" "$r/var/lib/auros/update-agent/last-successful-fetch"
assert_not "A1 does not claim it staged anything" "already up to date" "$out"

# A2 -- THE REGRESSION ITSELF: an existing freshness stamp must not be refreshed by a failure.
# This is the assertion that would have turned "patched for two years" into a red line.
r="$(new_root --healthy)"
STALE="$(epoch_iso 2592000)"   # 30 days ago
printf '%s\n' "$STALE" > "$r/var/lib/auros/update-agent/last-successful-fetch"
echo 1 > "$r/.stub/bootc-upgrade-rc"
printf '{"status":{"booted":{"image":{"imageDigest":"sha256:aaa"}}}}\n' > "$r/.stub/bootc-status.json"
out="$(run_script "$AU" "$r")"
assert_eq "A2 still exits 0" 0 "$RC"
assert_eq "A2 the 30-day-old stamp is UNCHANGED after a failed fetch" \
  "$STALE" "$(cat "$r/var/lib/auros/update-agent/last-successful-fetch")"

# A3 -- and a real success does clear the error and move the stamp.
r="$(new_root --healthy)"
printf 'boom\n' > "$r/var/lib/auros/update-agent/last-error"
echo 0 > "$r/.stub/bootc-upgrade-rc"
printf '{"status":{"booted":{"image":{"imageDigest":"sha256:aaa"}}}}\n' > "$r/.stub/bootc-status.json"
out="$(run_script "$AU" "$r")"
assert_eq  "A3 exits 0" 0 "$RC"
assert_has "A3 says the fetch succeeded" "AUROS-UPDATE-FETCH-OK" "$out"
assert_file "A3 writes last-successful-fetch" "$r/var/lib/auros/update-agent/last-successful-fetch"
assert_nofile "A3 removes last-error" "$r/var/lib/auros/update-agent/last-error"
assert_has "A3 nothing staged -> says so" "already up to date" "$out"

# A4 -- a transient `bootc status` failure must not kill the unit (set -e + pipefail).
r="$(new_root --healthy)"
echo 1 > "$r/.stub/bootc-status-rc"
: > "$r/.stub/bootc-status.json"
echo 0 > "$r/.stub/bootc-upgrade-rc"
out="$(run_script "$AU" "$r")"
assert_eq  "A4 unreadable bootc status does not abort the script" 0 "$RC"
assert_has "A4 degrades to 'unknown'" "booted digest before: unknown" "$out"
assert_has "A4 still ran the upgrade" "AUROS-UPDATE-FETCH-OK" "$out"

# A5 -- the retry path. First attempt fails, second succeeds: the stamp must move.
r="$(new_root --healthy)"
cat > "$STUBS/bootc-flaky-state" <<'X'
X
printf '{"status":{"booted":{"image":{"imageDigest":"sha256:aaa"}}}}\n' > "$r/.stub/bootc-status.json"
echo 7 > "$r/.stub/bootc-upgrade-rc"
( sleep 0 ) # keep shellcheck honest
out="$(AUROS_TEST_ROOT="$r" bash -c '
  # flip the stub to success the moment the first upgrade has been recorded
  ( while :; do if grep -q "^upgrade" "$AUROS_TEST_ROOT/.stub/bootc-calls" 2>/dev/null; then echo 0 > "$AUROS_TEST_ROOT/.stub/bootc-upgrade-rc"; break; fi; done ) &
  bash "$1" 2>&1' _ "$AU")"; RC=$?
assert_eq  "A5 retry path exits 0" 0 "$RC"
assert_has "A5 announced the retry" "retrying in 60s" "$out"

# A6 -- source guard: the construct that caused the fatal must not come back.
if grep -nE 'if[[:space:]]+![[:space:]]+[A-Za-z_][A-Za-z0-9_]*="\$\(' "$AU" >/dev/null; then
  bad "A6 auros-update still captures an exit status through a negation (\$? is the NEGATION's status, always 0 on failure)"
else
  ok "A6 no 'if ! var=\$(...)' status capture remains in auros-update"
fi
if grep -n 'bootc_json | json_get' "$AU" | grep -qv '|| true'; then
  bad "A6 a 'bootc_json | json_get' substitution is missing '|| true'; under set -e + pipefail it aborts the unit"
else
  ok "A6 every bootc_json|json_get substitution is guarded with || true"
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "B. 60-rollback-wiring.sh -- every branch is reachable, and the healthy case is GREEN"
# ════════════════════════════════════════════════════════════════════════════════════════════════
RW="$UA/greenboot/check/wanted.d/60-rollback-wiring.sh"
HEALTHY='{"status":{"booted":{"image":{"imageDigest":"sha256:new"}},"rollback":{"image":{"imageDigest":"sha256:old"}},"otherDeployments":[]}}'

# B1 -- the whole point of the fatal: on a healthy machine this must be SILENT AND GREEN. Before
# the fix it emitted a Python traceback and exited 1 on every boot of every machine forever.
r="$(new_root --healthy)"; printf '%s' "$HEALTHY" > "$r/.stub/bootc-status.json"
out="$(run_script "$RW" "$r")"
assert_eq  "B1 healthy machine exits 0" 0 "$RC"
assert_not "B1 no Python traceback" "Traceback" "$out"
assert_has "B1 reports the rollback deployment" "one rollback deployment retained" "$out"

# B2 -- composefs (D9): rollback does not work there at all.
r="$(new_root --healthy)"
printf '%s' '{"status":{"booted":{"image":{"imageDigest":"sha256:new"},"composefs":true},"rollback":{"image":{}},"otherDeployments":[]}}' > "$r/.stub/bootc-status.json"
out="$(run_script "$RW" "$r")"
assert_eq  "B2 composefs backend exits 1" 1 "$RC"
assert_has "B2 names composefs and D9" "composefs/UKI backend (D9)" "$out"
assert_not "B2 no Python traceback" "Traceback" "$out"

# B3 -- deployments exist but none is the rollback: the real D10 failure.
r="$(new_root --healthy)"
printf '%s' '{"status":{"booted":{"image":{"imageDigest":"sha256:new"}},"rollback":null,"otherDeployments":[{"image":{}},{"image":{}}]}}' > "$r/.stub/bootc-status.json"
out="$(run_script "$RW" "$r")"
assert_eq  "B3 3 deployments and no rollback exits 1" 1 "$RC"
assert_has "B3 says there is nothing to roll back to" "NO rollback deployment" "$out"

# B4 -- a machine that has never updated has no rollback, and that is NORMAL. Getting this wrong
# puts a red line in the boot status of every machine on its first boot (D4: clean end to end).
r="$(new_root --healthy)"
printf '%s' '{"status":{"booted":{"image":{"imageDigest":"sha256:new"}},"rollback":null,"otherDeployments":[]}}' > "$r/.stub/bootc-status.json"
out="$(run_script "$RW" "$r")"
assert_eq  "B4 never-updated machine exits 0" 0 "$RC"
assert_has "B4 explains why" "has taken no update yet" "$out"

# B5 -- garbage from bootc: a clear sentence, not a stack trace.
r="$(new_root --healthy)"; printf 'not json at all' > "$r/.stub/bootc-status.json"
out="$(run_script "$RW" "$r")"
assert_eq  "B5 unparseable status exits 1" 1 "$RC"
assert_has "B5 says it could not parse" "could not parse" "$out"
assert_not "B5 no Python traceback" "Traceback" "$out"

# B6 -- the RUNTIME composefs detection the design was missing entirely.
r="$(new_root --healthy)"; printf '%s' "$HEALTHY" > "$r/.stub/bootc-status.json"
rm -f "$r/usr/lib/systemd/system/ostree-finalize-staged.service"
out="$(run_script "$RW" "$r")"
assert_eq  "B6 missing ostree-finalize-staged.service exits 1" 1 "$RC"
assert_has "B6 names the unit" "ostree-finalize-staged.service is absent" "$out"

# B7 -- GRUB with no counter logic: rollback silently does not exist.
r="$(new_root --healthy)"; printf '%s' "$HEALTHY" > "$r/.stub/bootc-status.json"
printf 'menuentry stuff\n' > "$r/boot/grub2/grub.cfg"
out="$(run_script "$RW" "$r")"
assert_eq  "B7 grub.cfg without boot_counter exits 1" 1 "$RC"
assert_has "B7 gives the fix" "bootupctl update" "$out"

# B8 -- upstream's default of 3 would make "fails twice" a lie.
r="$(new_root --healthy)"; printf '%s' "$HEALTHY" > "$r/.stub/bootc-status.json"
printf 'GREENBOOT_MAX_BOOT_ATTEMPTS=3\nDISABLED_HEALTHCHECKS=()\n' > "$r/etc/greenboot/greenboot.conf"
out="$(run_script "$RW" "$r")"
assert_eq  "B8 MAX_BOOT_ATTEMPTS=3 exits 1" 1 "$RC"
assert_has "B8 says what Auros ships" "Auros ships 2" "$out"

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "C. 70-update-freshness.sh -- quiet on a first boot, loud on a machine that has gone dark"
# ════════════════════════════════════════════════════════════════════════════════════════════════
FR="$UA/greenboot/check/wanted.d/70-update-freshness.sh"

# C1 -- first boot: no stamp yet, and none is due. Must be GREEN.
r="$(new_root)"; printf '60.00 100.00\n' > "$r/proc/uptime"
out="$(run_script "$FR" "$r")"
assert_eq  "C1 first boot exits 0" 0 "$RC"
assert_has "C1 explains that none is due yet" "none is due yet" "$out"

# C2 -- up for five days with no successful fetch: that machine is not being patched.
r="$(new_root)"; printf '432000.00 100.00\n' > "$r/proc/uptime"
out="$(run_script "$FR" "$r")"
assert_eq  "C2 five days up with no fetch exits 1" 1 "$RC"

# C3 -- short uptime but the agent has known this machine for three days across reboots.
r="$(new_root)"; printf '60.00 100.00\n' > "$r/proc/uptime"
python3 -c 'import time,sys;open(sys.argv[1],"w").write(str(int(time.time())-259200)+"\n")' \
  "$r/var/lib/auros/update-agent/agent-first-seen"
out="$(run_script "$FR" "$r")"
assert_eq  "C3 known for 3 days with no fetch exits 1 despite a 60s uptime" 1 "$RC"
assert_has "C3 points at the timer" "bootc-fetch-apply-updates.timer" "$out"

# C4 -- it has tried and always failed: a different, worse sentence than "never tried".
r="$(new_root)"; printf '432000.00 100.00\n' > "$r/proc/uptime"
epoch_iso 300 > "$r/var/lib/auros/update-agent/last-fetch-attempt"
printf 'rc=125\noutput<<EOF\nSource image rejected\nEOF\n' > "$r/var/lib/auros/update-agent/last-error"
out="$(run_script "$FR" "$r")"
assert_eq  "C4 tried-and-never-succeeded exits 1" 1 "$RC"
assert_has "C4 distinguishes it from 'never tried'" "has never once succeeded" "$out"
assert_has "C4 quotes the last error" "Source image rejected" "$out"

# C5 -- a fetch yesterday is fine.
r="$(new_root)"; epoch_iso 86400 > "$r/var/lib/auros/update-agent/last-successful-fetch"
out="$(run_script "$FR" "$r")"
assert_eq  "C5 a one-day-old stamp exits 0" 0 "$RC"
assert_has "C5 reports the age" "1 day(s) ago" "$out"

# C6 -- twenty days is the condition this check exists for.
r="$(new_root)"; epoch_iso 1728000 > "$r/var/lib/auros/update-agent/last-successful-fetch"
out="$(run_script "$FR" "$r")"
assert_eq  "C6 a twenty-day-old stamp exits 1" 1 "$RC"
assert_has "C6 says it may be drifting out of support" "drifting out of support" "$out"

# C7 -- succeeded recently but failing right now: still green, but the failures are shown.
r="$(new_root)"; epoch_iso 86400 > "$r/var/lib/auros/update-agent/last-successful-fetch"
printf 'rc=125\n' > "$r/var/lib/auros/update-agent/last-error"
out="$(run_script "$FR" "$r")"
assert_eq  "C7 recent success with a current failure exits 0" 0 "$RC"
assert_has "C7 but surfaces the current failure" "most recent fetch attempt FAILED" "$out"

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "D. 40-no-new-failed-units + green.d -- both sides sampled at the same point"
# ════════════════════════════════════════════════════════════════════════════════════════════════
NF="$UA/greenboot/check/required.d/40-no-new-failed-units.sh"
GD="$UA/greenboot/green.d/10-auros-record-good-boot.sh"
SD="$r"

# D1 -- first boot: no baseline, passes, and offers a candidate.
r="$(new_root --healthy)"; printf 'flaky-sdcard.service\n' > "$r/.stub/failed-units"
out="$(run_script "$NF" "$r")"
assert_eq   "D1 first boot passes" 0 "$RC"
assert_file "D1 offers a candidate baseline" "$r/var/lib/auros/update-agent/failed-units.candidate"
assert_has  "D1 the candidate is stamped with this boot" "boot-id 3f2b1c8a" \
  "$(head -1 "$r/var/lib/auros/update-agent/failed-units.candidate" | sed 's/#boot-id /boot-id /')"

# D2 -- green.d promotes THAT snapshot rather than taking its own later one. To prove it is the
# promotion and not a re-sample, the machine's failed set is CHANGED before green.d runs -- which
# is exactly what "the desktop fails after multi-user.target" looks like.
printf 'flaky-sdcard.service\nplasma-late.service\n' > "$r/.stub/failed-units"
out="$(run_script "$GD" "$r")"
assert_eq  "D2 green.d exits 0" 0 "$RC"
assert_has "D2 says it promoted the healthcheck's snapshot" "promoted the healthcheck's own snapshot" "$out"
assert_eq  "D2 the baseline is the EARLY snapshot, not the late re-sample" \
  "flaky-sdcard.service" "$(cat "$r/var/lib/auros/update-agent/failed-units.baseline")"
assert_nofile "D2 the candidate is consumed" "$r/var/lib/auros/update-agent/failed-units.candidate"

# D3 -- THE BUG THIS FIXES. A unit that fails late got into the old baseline and could then never
# be seen as a regression, because the check reads earlier than green.d sampled. With promotion,
# the same unit failing at CHECK time on the next boot is a regression and the boot goes red.
printf '3f2b1c8a-0000-4000-8000-000000000002\n' > "$r/proc/sys/kernel/random/boot_id"   # next boot
printf 'flaky-sdcard.service\nplasma-late.service\n' > "$r/.stub/failed-units"
out="$(run_script "$NF" "$r")"
assert_eq  "D3 a newly failed unit is a regression -> exit 1" 1 "$RC"
assert_has "D3 names it" "REGRESSED: plasma-late.service" "$out"

# D4 -- the pre-existing failure alone is not a regression.
printf 'flaky-sdcard.service\n' > "$r/.stub/failed-units"
out="$(run_script "$NF" "$r")"
assert_eq  "D4 an already-failing unit is not a regression" 0 "$RC"

# D5 -- the site's ignore list suppresses a known-bad unit.
printf 'flaky-sdcard.service\nplasma-late.service\n' > "$r/.stub/failed-units"
printf '# site\nplasma-late.service\n' >> "$r/etc/auros/update-agent/failed-units.ignore"
out="$(run_script "$NF" "$r")"
assert_eq "D5 an ignored unit does not roll the machine back" 0 "$RC"

# D6 -- a candidate from a different boot must not be promoted, and the fallback must announce
# itself rather than quietly restoring the skew.
r="$(new_root --healthy)"
printf '#boot-id 00000000-dead-4000-8000-000000000000\nold.service\n' \
  > "$r/var/lib/auros/update-agent/failed-units.candidate"
printf 'late.service\n' > "$r/.stub/failed-units"
out="$(run_script "$GD" "$r")"
assert_eq  "D6 stale candidate -> green.d exits 0" 0 "$RC"
assert_has "D6 refuses to promote it" "not this boot's" "$out"
assert_has "D6 and says the fallback is skewed" "FALLBACK" "$out"
assert_eq  "D6 fell back to sampling here" "late.service" "$(cat "$r/var/lib/auros/update-agent/failed-units.baseline")"

# D7 -- the header line can never be mistaken for a unit name.
r="$(new_root --healthy)"
printf '#boot-id 3f2b1c8a-0000-4000-8000-000000000001\n' > "$r/var/lib/auros/update-agent/failed-units.baseline"
: > "$r/.stub/failed-units"
out="$(run_script "$NF" "$r")"
assert_eq "D7 a '#boot-id' line in a baseline is not counted as a failed unit" 0 "$RC"
assert_has "D7 baseline reads as empty" "failed units at the last green boot: 0" "$out"

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "E. systemd drop-ins -- the schedule is what the comments say it is"
# ════════════════════════════════════════════════════════════════════════════════════════════════
# OnBootSec=, OnUnitInactiveSec=, OnActiveSec=, OnStartupSec=, OnUnitActiveSec= and OnCalendar=
# are LIST settings: a drop-in APPENDS to the vendor value and only an empty assignment resets the
# list. Without the resets this file did not set the cadence, it doubled it -- the vendor's
# OnBootSec=1h and OnUnitInactiveSec=8h stayed live alongside ours, doubling the B6 uplink load
# the RandomizedDelaySec number was computed to bound.
TD="$UA/systemd/bootc-fetch-apply-updates.timer.d/10-auros.conf"
body() { sed 's/[[:space:]]*#.*$//' "$1" | grep -vE '^[[:space:]]*(#|$)'; }
for setting in OnActiveSec OnBootSec OnStartupSec OnUnitActiveSec OnUnitInactiveSec OnCalendar; do
  first="$(body "$TD" | grep -n "^${setting}=" | head -1 || true)"
  if [ -z "$first" ]; then
    bad "E1 ${setting}= has no empty reset in the timer drop-in (the vendor value would survive)"
  elif [ "${first#*:}" = "${setting}=" ]; then
    ok "E1 ${setting}= is reset before any value is assigned"
  else
    bad "E1 the first ${setting} line is '${first#*:}', not an empty reset -- the vendor value survives alongside it"
  fi
done
assert_eq "E2 OnBootSec is set exactly once after the reset" "1" \
  "$(body "$TD" | grep -c '^OnBootSec=3min$')"
assert_eq "E3 OnUnitInactiveSec is set exactly once after the reset" "1" \
  "$(body "$TD" | grep -c '^OnUnitInactiveSec=6h$')"
assert_eq "E4 RandomizedDelaySec replaces the vendor's 2h" "1" \
  "$(body "$TD" | grep -c '^RandomizedDelaySec=10min$')"
assert_has "E5 Persistent is stated, not assumed" "Persistent=false" "$(body "$TD")"

SVCD="$UA/systemd/bootc-fetch-apply-updates.service.d/10-auros.conf"
assert_has "E6 the service drop-in clears ExecStart before setting ours" "ExecStart=
ExecStart=/usr/libexec/auros/auros-update" "$(body "$SVCD")"
if body "$SVCD" | grep -q '^SuccessExitStatus='; then
  bad "E7 SuccessExitStatus= is back. SuccessExitStatus=0 is a no-op (0 is already success) and implies a protection it does not provide."
else
  ok "E7 no no-op SuccessExitStatus= line"
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
group "F. every shipped script parses, and greenboot will actually run it"
# ════════════════════════════════════════════════════════════════════════════════════════════════
# greenboot globs '*.sh' and sorts by name. A check without that extension is never run and
# nothing tells you.
for d in check/required.d check/wanted.d green.d red.d; do
  n=0
  for f in "$UA/greenboot/$d"/*; do
    [ -e "$f" ] || continue
    n=$((n+1))
    case "$f" in *.sh) ;; *) bad "F $f is in $d but does not end in .sh -- greenboot will never run it";; esac
    bash -n "$f" 2>/dev/null || bad "F $f is not valid bash"
  done
  [ "$n" -gt 0 ] || bad "F $d is empty"
done
bash -n "$AU" 2>/dev/null && ok "F libexec/auros-update parses" || bad "F libexec/auros-update does not parse"
req=$(ls "$UA/greenboot/check/required.d"/*.sh 2>/dev/null | wc -l | tr -d ' ')
assert_eq "F required.d still has exactly 4 rollback triggers (build/30-update-agent.sh asserts this)" "4" "$req"
ok "F all greenboot scripts end in .sh and parse"

# ════════════════════════════════════════════════════════════════════════════════════════════════
if [ "${1:-}" = "--self-test" ]; then
group "G. SELF-TEST -- reintroduce each fatal into a scratch copy and confirm the suite goes red"
  SC="$TMPROOT/scratch"; mkdir -p "$SC"

  # G1: put the negated status capture back into a copy of auros-update and check A1/A2 fail.
  cp "$AU" "$SC/auros-update"
  python3 - "$SC/auros-update" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace('upgrade_out="$(stage_attempt 2>&1)" || upgrade_rc=$?',
            'if ! upgrade_out="$(stage_attempt 2>&1)"; then upgrade_rc=$?; fi',1)
open(p,"w").write(s)
PY
  r="$(new_root --healthy)"; echo 125 > "$r/.stub/bootc-upgrade-rc"
  printf '{"status":{"booted":{"image":{"imageDigest":"sha256:a"}}}}\n' > "$r/.stub/bootc-status.json"
  STALE="$(epoch_iso 2592000)"; printf '%s\n' "$STALE" > "$r/var/lib/auros/update-agent/last-successful-fetch"
  AUROS_TEST_ROOT="$r" bash "$SC/auros-update" >/dev/null 2>&1
  if [ "$(cat "$r/var/lib/auros/update-agent/last-successful-fetch")" = "$STALE" ]; then
    bad "G1 the old negated-capture bug did NOT refresh the stamp -- test A2 would not have caught it"
  else
    ok "G1 the old bug refreshes the stamp after a rejected image; test A2 catches it"
  fi

  # G2: put the heredoc-over-pipe back and check B1 (the HEALTHY case) fails.
  cp "$RW" "$SC/60.sh"
  python3 - "$SC/60.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('    python3 - "${status_file}" <<\'PY\' || rc=1',
            '    printf \'%s\' "${status_json}" | python3 - <<\'PY\' || rc=1',1)
s=s.replace('    with open(sys.argv[1]) as fh:\n        d = json.load(fh)',
            '    d = json.load(sys.stdin)',1)
open(p,"w").write(s)
PY
  r="$(new_root --healthy)"; printf '%s' "$HEALTHY" > "$r/.stub/bootc-status.json"
  o="$(AUROS_TEST_ROOT="$r" bash "$SC/60.sh" 2>&1)"; rc2=$?
  if [ "$rc2" -ne 0 ]; then
    ok "G2 the old heredoc bug fails on a HEALTHY machine (exit ${rc2}); test B1 catches it"
  else
    bad "G2 the old heredoc bug passed the healthy case -- test B1 would not have caught it"
  fi
  case "$o" in *Traceback*) ok "G2 and it was a Python traceback in the boot status, as reported";;
    *) bad "G2 expected a traceback from the reintroduced bug, got: $o";; esac

  # G3: remove the empty resets from a copy of the timer drop-in and check E1 fails.
  cp "$TD" "$SC/timer.conf"
  grep -v -E '^(OnActiveSec|OnBootSec|OnStartupSec|OnUnitActiveSec|OnUnitInactiveSec|OnCalendar)=$' "$TD" > "$SC/timer.conf"
  first="$(sed 's/[[:space:]]*#.*$//' "$SC/timer.conf" | grep -vE '^[[:space:]]*(#|$)' | grep -n '^OnBootSec=' | head -1)"
  if [ "${first#*:}" = "OnBootSec=" ]; then
    bad "G3 stripping the resets left one behind; test E1 is not measuring what it claims"
  else
    ok "G3 without the resets the first OnBootSec line is '${first#*:}'; test E1 catches it"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '\nfailed:\n'; for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0

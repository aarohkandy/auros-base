#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# auros-base/tests/lib/harness.sh — the fake-root test harness for the build scripts.
#
# WHY THIS EXISTS
#
# build/*.sh run inside a container build against a real Fedora filesystem. That makes them expensive
# to exercise — the honest run is 8.4 GB of image and ~7 minutes — and expense is why they have
# already shipped two bugs today, in opposite directions, in the SAME check:
#
#   permanently RED    `grep selinux=0` matched its own file's explanatory comment, so the build
#                      failed over the sentence explaining why the argument is dangerous.
#   permanently GREEN  the fix used `tr -d '[:space:]'`, which deletes NEWLINES as well as spaces.
#                      Every kernel argument collapsed onto one line, so `^selinux=0$` could never
#                      match and the check passed on every possible input.
#
# The second is the worse one, and it is the one this harness is designed around:
#
#   ═══════════════════════════════════════════════════════════════════════════════════════════════
#   A CHECK THAT CANNOT FAIL IS NOT A CHECK. (DECISIONS.md D19)
#   ═══════════════════════════════════════════════════════════════════════════════════════════════
#
# So this harness does not merely let you assert that a check passes on good input. It TRACKS, per
# check id, whether that check has been observed going green AND observed going red, and t_finish()
# FAILS THE SUITE for any check that was only ever seen in one direction. A test that only ever
# demonstrates the happy path is, by construction, a test that cannot tell you the check works.
#
# The escape hatch is t_exempt <id> <reason>, which is deliberately noisy: it prints the reason into
# the run output, so a one-directional check is a sentence somebody wrote rather than an omission
# nobody noticed.
#
# ── THE SECOND RULE: NEVER COPY THE CODE UNDER TEST ──────────────────────────────────────────────
#
# tests/kargs-check.test.sh established the pattern and it is the pattern here: the function or block
# being tested is EXTRACTED FROM THE SHIPPING SCRIPT at run time. A copied assertion drifts from the
# real one within a week, and then the test is green about code nobody runs.
#
# extract_fn/extract_between therefore ABORT THE WHOLE SUITE (exit 90) on an empty extraction. An
# extraction that silently matches nothing produces an empty program, and an empty program passes
# every input — which is the permanently-green failure again, one level up, in the test harness. It
# has to be impossible here or the rest of this is theatre.
#
# ── WHAT THIS HARNESS IS NOT ─────────────────────────────────────────────────────────────────────
#
# It is not a substitute for the VM check matrix. It cannot tell you that SELinux is actually
# enforcing on a booted machine (that is B11/U-series), only that the assertion which decides whether
# to ship would have refused a bad image. It runs on a laptop with bash, sed, grep and coreutils, in
# under a second, on every edit — which is the layer of testing underneath the matrix, not instead
# of it.
#
# RUN:  bash auros-base/tests/run-all.sh
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

# NOTE: deliberately NOT `set -e`. A harness that aborts on the first non-zero exit cannot run a test
# whose whole purpose is to observe a non-zero exit.
set -uo pipefail

T_PASS=0
T_FAIL=0
T_FAILED_NAMES=()
# Space-delimited registries of which check ids have been seen in each direction. bash 3.2 (which is
# what macOS ships, and this harness has to run on the machine the work happens on) has no
# associative arrays, so these are flat strings queried with a padded substring match.
T_SEEN_GREEN=" "
T_SEEN_RED=" "
T_EXEMPT=" "
T_EXEMPT_NOTES=()
T_TMPDIRS=()
T_LAST_OUT=""

_t_c() { # colour, only when stdout is a terminal
  if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

ok()    { T_PASS=$((T_PASS+1)); printf '  %s   %s\n' "$(_t_c 32 ok)" "$*"; }
bad()   { T_FAIL=$((T_FAIL+1)); T_FAILED_NAMES+=("$*"); printf '  %s %s\n' "$(_t_c 31 FAIL)" "$*"; }
group() { printf '\n%s\n' "$(_t_c 1 "$*")"; }
note()  { printf '       %s\n' "$*"; }

# t_abort must kill the SUITE, not just the subshell it was called from.
#
# It used to be a plain `exit 90`, and extract_between() is called inside `$( ... )` — so an
# extraction that matched nothing printed HARNESS ABORT, exited the command substitution, and the
# suite carried on with an EMPTY block and reported dozens of confusing failures instead of one clear
# one. Same family of bug as everything this directory exists to catch: an abort that cannot abort.
T_MAIN_PID=$$
t_abort() {
  printf '\n%s %s\n' "$(_t_c 31 'HARNESS ABORT:')" "$*" >&2
  kill -s TERM "$T_MAIN_PID" 2>/dev/null
  exit 90
}
trap 'printf "\n%s\n" "$(_t_c 31 "HARNESS ABORTED — the suite proved nothing and is not a pass.")" >&2; t_cleanup; exit 90' TERM

# ── assertions ───────────────────────────────────────────────────────────────────────────────────
assert_eq()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2] got [$3]"; fi; }
assert_has()    { case "$3" in *"$2"*) ok "$1";; *) bad "$1 — output did not contain [$2]"; _t_dump "$3";; esac; }
assert_not()    { case "$3" in *"$2"*) bad "$1 — output unexpectedly contained [$2]"; _t_dump "$3";; *) ok "$1";; esac; }
assert_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 — $2 does not exist"; fi; }
assert_nofile() { if [ -e "$2" ]; then bad "$1 — $2 exists and must not"; else ok "$1"; fi; }
assert_symlink_to() { # label, link, target
  local got; got="$(readlink "$2" 2>/dev/null || true)"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 — $2 -> [${got:-<not a symlink>}], expected [$3]"; fi
}
_t_dump() { printf '%s\n' "$1" | sed 's/^/          | /' >&2; }

# ── the direction registry ───────────────────────────────────────────────────────────────────────
# Every run_check() records which way the check under test went. t_finish() then refuses to pass a
# suite in which some check was only ever observed in one direction.
_t_record() { # <id> <green|red>
  case "$2" in
    green) case "$T_SEEN_GREEN" in *" $1 "*) ;; *) T_SEEN_GREEN="$T_SEEN_GREEN$1 ";; esac ;;
    red)   case "$T_SEEN_RED"   in *" $1 "*) ;; *) T_SEEN_RED="$T_SEEN_RED$1 ";;   esac ;;
  esac
}

# t_exempt <id> <reason> — declare that a check is deliberately one-directional here. The reason is
# printed in the run output; it is meant to be read and argued with, not to make a warning go away.
t_exempt() {
  case "$T_EXEMPT" in *" $1 "*) ;; *) T_EXEMPT="$T_EXEMPT$1 ";; esac
  T_EXEMPT_NOTES+=("$1: $2")
}

# ── running a check ──────────────────────────────────────────────────────────────────────────────
# run_check <id> <green|red> <label> -- <command...>
#
#   green = the command must exit 0   (the check accepted this input)
#   red   = the command must exit != 0 (the check REFUSED this input)
#
# The naming is deliberate. `expected exit 1` invites writing a test that asserts today's exit code;
# `red` asks the question that matters, which is whether a bad image would have been stopped.
run_check() {
  local id="$1" want="$2" label="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local out rc got
  out="$("$@" 2>&1)"; rc=$?
  T_LAST_OUT="$out"
  if [ "$rc" -eq 0 ]; then got=green; else got=red; fi
  _t_record "$id" "$got"
  if [ "$got" = "$want" ]; then
    ok "[$id] $label → $got"
  else
    bad "[$id] $label → got $got, wanted $want (exit $rc)"
    _t_dump "$out"
  fi
}

# run_snippet <id> <green|red> <label> <shell-source> — run a chunk of shell (typically an extracted
# function plus a call to it) in a clean subshell and score it. `bash -c` rather than eval so that a
# `set -e` or an `exit` inside the extracted code behaves as it does in the real script.
run_snippet() {
  local id="$1" want="$2" label="$3" src="$4"
  run_check "$id" "$want" "$label" -- bash -c "$src"
}

# ── extraction: the code under test comes out of the shipping file, never out of this test ───────
# An empty extraction is an abort, not a skip. A sed range that matches nothing yields an empty
# program, and an empty program exits 0 on every input — the permanently-green bug, reproduced
# inside the thing that is supposed to catch it.
extract_fn() { # <file> <function-name>
  local f="$1" n="$2" body
  [ -f "$f" ] || t_abort "extract_fn: no such file: $f"
  body="$(sed -n "/^${n}() {/,/^}/p" "$f")"
  [ -n "$body" ] || t_abort "extract_fn: '${n}()' not found in $f — the function was renamed or deleted and this test is now testing nothing."
  case "$body" in
    *"${n}() {"*) ;;
    *) t_abort "extract_fn: extraction from $f does not start at ${n}() — check the sed range" ;;
  esac
  printf '%s\n' "$body"
}

extract_between() { # <file> <start-regex> <end-regex>
  local f="$1" body
  [ -f "$f" ] || t_abort "extract_between: no such file: $f"
  body="$(sed -n "/$2/,/$3/p" "$f")"
  [ -n "$body" ] || t_abort "extract_between: empty extraction from $f between [$2] and [$3] — the block moved or was deleted, so this test is vacuous."
  printf '%s\n' "$body"
}

# extract_lines <file> <regex> — every line matching regex. Used where the thing under test is a
# single assertion line rather than a function.
extract_lines() {
  local f="$1" body
  [ -f "$f" ] || t_abort "extract_lines: no such file: $f"
  body="$(grep -E -- "$2" "$f" || true)"
  [ -n "$body" ] || t_abort "extract_lines: nothing in $f matches [$2] — this test is vacuous."
  printf '%s\n' "$body"
}

# rootify — rewrite absolute paths in extracted code so it operates on a fake root. Every prefix that
# gets rewritten must be passed explicitly: a blanket s#/#$ROOT/# would also rewrite /bin/sh and the
# regexes inside the code.
#
# ONE PASS, LONGEST PREFIX FIRST. Applying the rewrites as separate `s###` expressions produced
# `$ROOT$ROOT/etc/sudoers.d` — the second expression matched `/etc/sudoers` inside the text the first
# one had already rewritten. The extracted code then globbed a directory that did not exist, found no
# files, and CONCLUDED THAT NO NOPASSWD RULE WAS PRESENT. A passing test, about nothing. So the
# prefixes become one ERE alternation, ordered longest first, and every position is matched once.
rootify() { # reads code on stdin, takes absolute prefixes as arguments
  local alt="" p esc
  for p in $(printf '%s\n' "$@" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-); do
    esc="$(printf '%s' "$p" | sed -e 's/[.*^$+?(){}|]/\\&/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g')"
    alt="${alt:+$alt|}$esc"
  done
  [ -n "$alt" ] || { cat; return 0; }
  sed -E "s#($alt)#\\\$ROOT&#g"
}

# ── the fake machine ─────────────────────────────────────────────────────────────────────────────
newroot() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/auros-fakeroot.XXXXXX")" || t_abort "mktemp failed"
  mkdir -p "$d/etc" "$d/usr/lib" "$d/usr/bin" "$d/usr/libexec" "$d/var/log" "$d/tmp"
  T_TMPDIRS+=("$d")
  printf '%s' "$d"
}

t_cleanup() { local d; for d in ${T_TMPDIRS+"${T_TMPDIRS[@]}"}; do rm -rf "$d"; done; }

# stubdir — a directory to put on PATH in front of everything, holding fake system binaries.
stubdir() { local d; d="$(newroot)/bin"; mkdir -p "$d"; printf '%s' "$d"; }

# stub <dir> <name> — writes a stub from stdin and makes it executable.
stub() {
  local d="$1" n="$2"
  mkdir -p "$d"
  cat > "$d/$n"
  chmod 0755 "$d/$n"
}

# ── portability: the image has GNU sed, this laptop may not ──────────────────────────────────────
# `sed -i 's/x/y/' f` is GNU. BSD sed requires `sed -i '' 's/x/y/' f`. The build scripts are written
# for the image, so on a BSD host the harness puts a shim on PATH rather than editing the code under
# test — and SAYS it did, so a green run on a laptop is never mistaken for a green run on the target.
T_SED_MODE="host GNU sed"
install_sed_shim() { # <stubdir>
  if printf 'x\n' | sed -i -e 's/x/y/' /dev/null 2>/dev/null; then return 0; fi
  # Probe properly: write a scratch file and try a GNU-style in-place edit on it.
  local probe; probe="$(mktemp "${TMPDIR:-/tmp}/auros-sedprobe.XXXXXX")"
  printf 'x\n' > "$probe"
  if sed -i 's/x/y/' "$probe" 2>/dev/null && [ "$(cat "$probe")" = "y" ]; then
    rm -f "$probe"; T_SED_MODE="host GNU sed"; return 0
  fi
  rm -f "$probe" "$probe"* 2>/dev/null || true
  T_SED_MODE="BSD sed + GNU -i shim"
  stub "$1" sed <<'SH'
#!/usr/bin/env bash
# GNU `sed -i` compatibility shim for BSD sed. Only -i is translated; everything else passes through.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -i) args+=(-i ''); shift ;;
    -i*) args+=(-i ''); set -- "-${1#-i}" "${@:2}" ;;   # -iE -> -i '' -E
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/sed "${args[@]}"
SH
}

# ── finish ───────────────────────────────────────────────────────────────────────────────────────
t_finish() {
  local name="$1" id oneway=0
  printf '\n'

  # THE META-CHECK. Every check id that was exercised must have been seen both green and red, unless
  # a reason was written down. This is what stops this suite from becoming the thing it exists to
  # prevent.
  group "direction audit — every check must have been seen to FAIL, not only to pass"
  for id in $T_SEEN_GREEN $T_SEEN_RED; do
    case "$T_EXEMPT" in *" $id "*) continue ;; esac
    local g=0 r=0
    case "$T_SEEN_GREEN" in *" $id "*) g=1 ;; esac
    case "$T_SEEN_RED"   in *" $id "*) r=1 ;; esac
    if [ "$g" = 1 ] && [ "$r" = 1 ]; then continue; fi
    if [ "$g" = 1 ]; then
      bad "[$id] was only ever GREEN. Nothing here demonstrates it can refuse a bad input, so it is not a check yet (D19)."
    else
      bad "[$id] was only ever RED. Nothing here demonstrates it accepts a good input, so it would fail every build."
    fi
    oneway=1
  done
  [ "$oneway" = 0 ] && ok "every check id was observed both accepting a good input and refusing a bad one"

  if [ ${#T_EXEMPT_NOTES[@]} -gt 0 ]; then
    printf '\n%s\n' "$(_t_c 1 'declared one-directional, with reasons:')"
    local n; for n in "${T_EXEMPT_NOTES[@]}"; do note "· $n"; done
  fi

  printf '\n'
  if [ "$T_FAIL" -eq 0 ]; then
    printf '%s  %s\n' "$(_t_c 32 "${name}:")" "$(_t_c 1 "$T_PASS passed, 0 failed")"
  else
    printf '%s  %s\n' "$(_t_c 31 "${name}:")" "$(_t_c 1 "$T_PASS passed, $T_FAIL FAILED")"
    local f; for f in "${T_FAILED_NAMES[@]}"; do printf '    · %s\n' "$f"; done
  fi
  t_cleanup
  [ "$T_FAIL" -eq 0 ]
}

trap t_cleanup EXIT

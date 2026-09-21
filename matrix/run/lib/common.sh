#!/usr/bin/env bash
# common.sh — shared plumbing for the check-matrix harness. Source it; do not execute it.
#
# D19 (standing rule): every script sets -euo pipefail. A step that cannot fail is not a check.

set -euo pipefail

RUN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(dirname "$RUN_LIB_DIR")"
MATRIX_DIR="$(dirname "$HARNESS_DIR")"
BASE_REPO="$(dirname "$MATRIX_DIR")"
META_REPO="$(dirname "$BASE_REPO")"
export RUN_LIB_DIR HARNESS_DIR MATRIX_DIR BASE_REPO META_REPO

: "${AUROS_RUN_DIR:=${PWD}/matrix-run}"
: "${AUROS_POLL_INTERVAL:=3}"        # seconds between polls. NEVER used as a substitute for a marker.
: "${AUROS_VERBOSE:=1}"

mkdir -p "$AUROS_RUN_DIR/checks" "$AUROS_RUN_DIR/logs" "$AUROS_RUN_DIR/work"

log()  { [ "$AUROS_VERBOSE" = "0" ] || printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '%s  WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s  FATAL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 2; }

now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || date +%s000; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# json_str <text> — emit a JSON string literal. Pure-bash-safe for the control characters we produce.
json_str() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  s=${s//$'\n'/\\n}
  # strip anything else below 0x20 rather than emit invalid JSON
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

# ─── check records ───────────────────────────────────────────────────────────────────────────────
# Every script writes JSON Lines to $CHECKS_FILE. emit-results.mjs aggregates them. One line per
# check; the LAST line for an id wins, so a re-evaluation can supersede an earlier provisional record.
: "${CHECKS_FILE:=$AUROS_RUN_DIR/checks/unknown.jsonl}"

_CHECK_T0=0
check_begin() { _CHECK_T0=$(now_ms); }

# record <id> <pass|fail|skip> <detail> [skip_reason]
record() {
  local id=$1 status=$2 detail=${3-} reason=${4-}
  local dur=0
  if [ "${_CHECK_T0}" -gt 0 ]; then dur=$(( $(now_ms) - _CHECK_T0 )); fi
  [ "$dur" -ge 0 ] || dur=0
  _CHECK_T0=0
  case "$status" in pass|fail|skip) ;; *) die "record: bad status '$status' for $id" ;; esac
  {
    printf '{"id":%s,"status":%s,"detail":%s,"duration_ms":%s' \
      "$(json_str "$id")" "$(json_str "$status")" "$(json_str "$detail")" "$dur"
    [ -n "$reason" ] && printf ',"skip_reason":%s' "$(json_str "$reason")"
    printf '}\n'
  } >> "$CHECKS_FILE"
  case "$status" in
    pass) log "  [PASS] $id — $detail" ;;
    fail) log "  [FAIL] $id — $detail" ;;
    skip) log "  [SKIP] $id — $reason" ;;
  esac
}

# pass_if <id> <exit-code> <detail-on-pass> <detail-on-fail>
pass_if() {
  local id=$1 rc=$2 okd=${3-ok} bad=${4-failed}
  if [ "$rc" -eq 0 ]; then record "$id" pass "$okd"; else record "$id" fail "$bad"; fi
}

any_failed() {
  local f=${1:-$CHECKS_FILE}
  [ -f "$f" ] || return 1
  grep -q '"status":"fail"' "$f"
}

# ─── polling ─────────────────────────────────────────────────────────────────────────────────────
# poll_until <timeout_s> <label> -- <command...>
#
# Polls a predicate until it is true or the deadline passes. This is the ONLY approved way to wait for
# anything in this harness. A fixed `sleep N` followed by an assertion scores a slow-but-correct boot as
# a failure, which is exactly the lie a TCG runner tells. If you find yourself writing `sleep 120`,
# write a marker and poll for it instead.
poll_until() {
  local timeout=$1 label=$2; shift 2
  [ "${1-}" = "--" ] && shift
  local deadline=$(( $(date +%s) + timeout )) n=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@"; then
      log "    poll '$label' satisfied after ${n} polls"
      return 0
    fi
    n=$(( n + 1 ))
    sleep "$AUROS_POLL_INTERVAL"
  done
  log "    poll '$label' TIMED OUT after ${timeout}s (${n} polls)"
  return 1
}

# grep_file <file> <ere> — predicate form, safe when the file does not exist yet.
grep_file() { [ -f "$1" ] && grep -qaE "$2" "$1"; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1${2:+ ($2)}"; }

# have <tool> — soft probe. A MISSING TOOL IS NEVER A SKIP. Callers must turn it into a fail with a
# detail naming the tool, so the run goes red rather than quietly narrowing what is being tested.
have() { command -v "$1" >/dev/null 2>&1; }

# tool_missing_detail <tool> — what a "not installed" message has to carry to be worth reading.
#
# THE HOUR THIS COST. run 35548903285 failed U1-U5 and R1 with "cosign is not installed. cosign is
# NOT preinstalled on ubuntu-latest; the workflow must add it". The workflow HAD added it, with
# sigstore/cosign-installer, and the job's own inventory step printed
#     cosign                 /home/runner/.cosign/cosign
# The harness runs under `sudo -E`, and sudo resets PATH to its secure_path
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin). A tool installed into
# the runner tool cache is on the RUNNER's PATH and invisible to root. build.yml's update job has
# exactly this shape, so U1-U5 and R1 would have failed this way on every real build — and the
# message would have sent whoever read it to go add a step that was already there.
#
# So: say which PATH was searched, and say whether the binary exists somewhere outside it. Those
# are different problems with different fixes, and they used to produce the same sentence.
tool_missing_detail() {
  local t=$1 hits='' root
  # Bounded, and only runs on the failure path. These are the trees where a CI-installed tool hides.
  for root in /opt/hostedtoolcache /usr/local /home /root /snap; do
    [ -d "$root" ] || continue
    hits="$hits $(find "$root" -maxdepth 5 -name "$t" -type f -perm -u+x 2>/dev/null | head -3 | tr '\n' ' ')"
  done
  hits=$(printf '%s' "$hits" | tr -s ' ' | sed 's/^ //;s/ $//')
  # The detail string is truncated downstream (2000 chars in matrix/run.sh's collector). A developer
  # laptop's PATH can be longer than that on its own and would push the useful half off the end.
  local shown_path=$PATH
  [ ${#shown_path} -le 400 ] || shown_path="${shown_path:0:400}… (${#PATH} chars)"
  if [ -n "$hits" ]; then
    printf '%s is NOT on the PATH this process was given (%s), but it EXISTS at: %s. That is the sudo trap: sudo replaces PATH with its secure_path, so a tool the workflow installed into the runner tool cache is invisible to `sudo -E`. Invoke as `sudo -E env "PATH=$PATH" ...`, or symlink the binary into /usr/local/bin.' "$t" "$shown_path" "$hits"
  else
    printf '%s is not on PATH (%s) and no executable of that name exists under /opt/hostedtoolcache, /usr/local, /home, /root or /snap either, so it is genuinely not installed on this host.' "$t" "$shown_path"
  fi
}

# ─── image helpers ───────────────────────────────────────────────────────────────────────────────
# podman_in <image> <cmd...> — run a command inside the image under test, read-only, no network.
podman_in() {
  local img=$1; shift
  podman run --rm --network=none --entrypoint= "$img" "$@"
}

# image_digest <ref> — resolve to a content digest. Never accept a tag as an answer.
image_digest() {
  local ref=$1 d=''
  if [[ "$ref" == *"@sha256:"* ]]; then printf '%s' "${ref#*@}"; return 0; fi
  d=$(skopeo inspect --no-tags "docker://$ref" 2>/dev/null | sed -n 's/.*"Digest": *"\(sha256:[a-f0-9]\{64\}\)".*/\1/p' | head -1) || true
  [ -n "$d" ] || d=$(podman image inspect "$ref" --format '{{.Digest}}' 2>/dev/null || true)
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

read_lock() {  # read_lock UPSTREAM_DIGEST
  local key=$1 f="$BASE_REPO/base.lock"
  [ -f "$f" ] || die "base.lock not found at $f"
  sed -n "s/^${key}=//p" "$f" | head -1
}

#!/usr/bin/env bash
# tools/heartbeat.sh — the stall alarm, the max-age forced rebuild, and the nightly-red issue.
# A stub `gh` on PATH serves canned API JSON and applies the script's REAL --jq filters with jq, so
# the field names and filters are exercised, not just the branching.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

SCRIPT="$REPO/tools/heartbeat.sh"
NOW=1790000000                                   # fixed clock (2026-09-21T...)
iso() { python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
ago() { iso $(( NOW - $1 * 86400 )); }           # ago <days>

S="$(stubdir)"; LOG="$S/../gh.log"
stub "$S" gh <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
[ -n "${GH_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
jq=""; prev=""; for a in "$@"; do [ "$prev" = --jq ] && jq="$a"; prev="$a"; done
case "$*" in
  *build.yml/runs*)   body="$GH_BUILD_RUNS" ;;
  *nightly.yml/runs*) body="$GH_NIGHTLY_RUNS" ;;
  *actions/runs/*/jobs*) all="$*"; id="${all#*actions/runs/}"; id="${id%%/*}"; v="GH_JOBS_$id"; body="${!v}" ;;
  "issue list"*)      body="$GH_ISSUES" ;;
  *) exit 0 ;;
esac
if [ -n "$jq" ]; then printf '%s' "$body" | jq -r "$jq"; else printf '%s' "$body"; fi
SH

hb() { PATH="$S:$PATH" GH_LOG="$LOG" GH_REPO=o/r HEARTBEAT_NOW=$NOW MAX_UPSTREAM_AGE_DAYS=21 MAX_BUILD_AGE_DAYS=7 \
       GITHUB_OUTPUT= bash "$SCRIPT" "$@"; }
# forced — exit 0 iff `force` decided to rebuild. `force` itself always exits 0 (it must not redden drift).
forced() { case "$(hb force 2>&1)" in *force_rebuild=true*) return 0 ;; *) return 1 ;; esac; }

NONE='{"workflow_runs":[]}'
runs() { printf '{"workflow_runs":[{"id":%s,"run_started_at":"%s"}]}' "$1" "$2"; }
jobs() { printf '{"jobs":[{"name":"drift","conclusion":"success"},{"name":"rebuild and gate / publish · gated on the committed ledger","conclusion":"%s"}]}' "$1"; }
export GH_BUILD_RUNS GH_NIGHTLY_RUNS GH_ISSUES GH_FAIL GH_JOBS_41 GH_JOBS_42

group "stall — red when upstream's image is older than MAX_UPSTREAM_AGE_DAYS"
run_check stall green "upstream created 5 days ago" -- hb stall "$(ago 5)"
run_check stall green "fractional-second timestamp as skopeo writes it, 21 days (boundary)" -- hb stall "$(ago 21 | sed 's/Z$/.123456789Z/')"
run_check stall red   "upstream created 30 days ago" -- hb stall "$(ago 30)"
assert_has "the red names the stall and what to check" "appears STALLED" "$T_LAST_OUT"
run_check stall red   "missing creation time is red, not green" -- hb stall ""
run_check stall red   "garbage creation time is red" -- hb stall "yesterday"

group "force — rebuild when the last successful base build on main is MAX_BUILD_AGE_DAYS old"
GH_FAIL=""; GH_NIGHTLY_RUNS="$NONE"
GH_BUILD_RUNS="$(runs 1 "$(ago 2)")"
run_check forced red   "build.yml push succeeded 2 days ago → no forced rebuild" -- forced
GH_BUILD_RUNS="$(runs 1 "$(ago 8)")"
run_check forced green "build.yml push succeeded 8 days ago → forced" -- forced
GH_BUILD_RUNS="$NONE"
run_check forced green "no successful build ever → forced (fail closed)" -- forced
GH_BUILD_RUNS="$(runs 1 "$(ago 8)")"; GH_NIGHTLY_RUNS="$(runs 41 "$(ago 1)")"; GH_JOBS_41="$(jobs success)"
run_check forced red   "old push build, but a nightly-triggered build succeeded yesterday → no force" -- forced
GH_JOBS_41="$(jobs skipped)"
run_check forced green "green nightly whose build was SKIPPED is not a build → forced" -- forced
GH_FAIL=1
run_check forced green "GitHub API failing → forced (fail closed)" -- forced
GH_FAIL=""
hb force >/dev/null 2>&1; assert_eq "force never fails the drift job, even when forcing" 0 "$?"

group "alert — one deduplicated nightly-red issue"
: > "$LOG"; GH_ISSUES='[]'
run_check alert green "red, no open issue" -- hb alert red
assert_has "…creates the issue with the label" "issue create --label nightly-red" "$(cat "$LOG")"
: > "$LOG"; GH_ISSUES='[{"number":7}]'
run_check alert green "red, issue #7 open" -- hb alert red
assert_has "…comments on #7" "issue comment 7" "$(cat "$LOG")"
assert_not "…and does not open a duplicate" "issue create" "$(cat "$LOG")"
: > "$LOG"
run_check alert green "green, issue #7 open" -- hb alert green
assert_has "…closes #7" "issue close 7" "$(cat "$LOG")"
: > "$LOG"; GH_ISSUES='[]'
run_check alert green "green, nothing open" -- hb alert green
assert_not "…touches no issue" "issue close" "$(cat "$LOG")"
GH_FAIL=1
run_check alert red "GitHub unreachable → the alert job fails loudly, not silently" -- hb alert red
GH_FAIL=""
run_check alert red "unknown verdict is refused" -- hb alert maybe

t_finish heartbeat.test.sh

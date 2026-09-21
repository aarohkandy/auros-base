#!/usr/bin/env bash
# Every dispatched subcommand is a defined function; every subcommand a workflow calls is dispatched.
# BLOCKED.md B16 — see tests/lib/dispatch_check.py for the rules and their limits.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
CHECK="$HERE/lib/dispatch_check.py"

group "this repository"
run_check dispatch green "every shell script and workflow in auros-base" -- python3 "$CHECK" "$REPO"
[ "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import dispatch_check as d; print(len(d.shell_files(sys.argv[2])))' "$HERE/lib" "$REPO")" -gt 20 ] \
  && ok "the scan found the repository's shell scripts (not an empty walk)" \
  || bad "the scan found almost no shell scripts — it is walking the wrong tree"

group "the bug B16 actually was, reintroduced into a copy of the shipping script"
S="$(newroot)"; mkdir -p "$S/tools"
sed -e 's/^cmd_update() {/cmd_update_gone() {/' "$REPO/tools/resolve-upstream.sh" > "$S/tools/resolve-upstream.sh"
grep -q '^cmd_update_gone() {' "$S/tools/resolve-upstream.sh" || t_abort "mutation did not apply — cmd_update's definition moved"
run_check dispatch red "resolve-upstream.sh dispatching an undefined cmd_update" -- python3 "$CHECK" "$S" "$S/tools/resolve-upstream.sh"
assert_has "…and the failure names the missing function" "dispatches 'cmd_update'" "$T_LAST_OUT"

group "a workflow calling a subcommand the script never had (gate1-exit.yml's old 'mirror')"
W="$(newroot)"; mkdir -p "$W/tools" "$W/.github/workflows"
cp "$REPO/tools/resolve-upstream.sh" "$W/tools/"
printf 'jobs:\n  x:\n    steps:\n      - run: ./tools/resolve-upstream.sh mirror\n' > "$W/.github/workflows/w.yml"
run_check wfcall red "./tools/resolve-upstream.sh mirror" -- python3 "$CHECK" "$W"
assert_has "…and the failure lists what IS dispatched" "dispatches only:" "$T_LAST_OUT"
printf 'jobs:\n  x:\n    steps:\n      - run: ./tools/resolve-upstream.sh update\n' > "$W/.github/workflows/w.yml"
run_check wfcall green "./tools/resolve-upstream.sh update" -- python3 "$CHECK" "$W"

t_finish dispatch.test.sh

#!/usr/bin/env bash
# tools/heartbeat.sh — the nightly's answer to "every way it fails reports green" (SYSTEM-REVIEW §2.3, H1, H3).
#
#   stall <upstream_created>   exit 1 if upstream's image is older than MAX_UPSTREAM_AGE_DAYS.
#                              "No change. Not rebuilding" for three weeks is a stall, not a quiet week.
#   force                      emit force_rebuild=true|false: true when the last successful base build
#                              on main is older than MAX_BUILD_AGE_DAYS, so our own layer's dnf packages
#                              get re-resolved even though upstream did not move. Fails CLOSED: if the
#                              last build cannot be determined, that is a rebuild, not a skip.
#   alert red|green            open-or-comment ONE issue labelled nightly-red on red; close it on green.
#
# Env: GH_REPO (owner/name), GH_TOKEN for gh; HEARTBEAT_NOW (epoch) overrides the clock, for tests.
set -euo pipefail

LABEL=nightly-red
NOW="${HEARTBEAT_NOW:-$(date -u +%s)}"

say()  { echo "$@"; }
emit() { printf '%s=%s\n' "$1" "$2"; [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
# ISO-8601 (fractional seconds allowed) -> epoch. Same conversion resolve-upstream.sh uses.
epoch() { python3 -c 'import sys,datetime,re; s=re.sub(r"\.\d+","",sys.argv[1]).replace("Z","+00:00"); print(int(datetime.datetime.fromisoformat(s).timestamp()))' "$1" 2>/dev/null; }

cmd_stall() {
  local created="${1:-}" max="${MAX_UPSTREAM_AGE_DAYS:?}" t days
  t="$(epoch "$created")" || { echo "::error::upstream creation time '${created}' is missing or unparseable — cannot prove upstream is alive, so this is red."; exit 1; }
  days=$(( (NOW - t) / 86400 ))
  if [ "$days" -gt "$max" ]; then
    echo "::error::Upstream appears STALLED: ghcr.io/ublue-os/aurora:stable was created ${created}, ${days} days ago (limit ${max}). The nightly would otherwise say 'No change. Not rebuilding' and stay green while the fleet goes unpatched. Check: ublue-os/aurora CI (is stable failing to publish?), Fedora release/mass-rebuild freezes, and whether UPSTREAM_TAG in base.lock is still the tag upstream publishes."
    exit 1
  fi
  say "upstream image is ${days} days old (limit ${max})"
}

# Newest successful base build on main, as an epoch; returns non-zero if it cannot say. Two routes
# build the base: a push to main runs build.yml directly; the nightly calls it as the `rebuild and
# gate` job, and those runs are listed under nightly.yml, not build.yml. Every call is checked
# explicitly: `set -e` does not apply inside a function called from an `if`.
last_build() {
  local best=0 t id started n runs
  t="$(gh api "repos/${GH_REPO:?}/actions/workflows/build.yml/runs?branch=main&event=push&status=success&per_page=1" \
        --jq '.workflow_runs[0].run_started_at // empty')" || return 1
  if [ -n "$t" ]; then best="$(epoch "$t")" || return 1; fi
  # ponytail: only the 10 newest green nightlies are scanned; enough while MAX_BUILD_AGE_DAYS <= 10.
  runs="$(gh api "repos/${GH_REPO}/actions/workflows/nightly.yml/runs?branch=main&status=success&per_page=10" \
            --jq '.workflow_runs[] | [.id, .run_started_at] | @tsv')" || return 1
  while IFS=$'\t' read -r id started; do
    [ -n "$id" ] || continue
    n="$(gh api "repos/${GH_REPO}/actions/runs/${id}/jobs?per_page=100" \
          --jq '[.jobs[] | select((.name | startswith("rebuild and gate")) and .conclusion == "success")] | length')" || return 1
    if [ "$n" -gt 0 ]; then
      t="$(epoch "$started")" || return 1
      [ "$t" -le "$best" ] || best="$t"
      break
    fi
  done <<< "$runs"
  [ "$best" -gt 0 ] || return 1
  echo "$best"
}

cmd_force() {
  local max="${MAX_BUILD_AGE_DAYS:?}" t days
  if ! t="$(last_build)" || [ -z "$t" ]; then
    echo "::warning::could not find a successful base build on main — forcing a rebuild (fail closed)"
    emit force_rebuild true; return 0
  fi
  days=$(( (NOW - t) / 86400 ))
  if [ "$days" -ge "$max" ]; then
    say "last successful base build was ${days} days ago (limit ${max}) — forcing a rebuild to re-resolve our own packages"
    emit force_rebuild true
  else
    say "last successful base build was ${days} days ago (limit ${max})"
    emit force_rebuild false
  fi
}

cmd_alert() {
  local verdict="${1:-}" run_url="${RUN_URL:-(run url not set)}" n
  case "$verdict" in red|green) ;; *) echo "usage: heartbeat.sh alert red|green" >&2; exit 2 ;; esac
  n="$(gh issue list --label "$LABEL" --state open --limit 1 --json number --jq '.[0].number // empty')"
  if [ "$verdict" = green ]; then
    [ -z "$n" ] || gh issue close "$n" --comment "Nightly green again: ${run_url}"
    say "green${n:+ — closed #$n}"; return 0
  fi
  if [ -n "$n" ]; then
    gh issue comment "$n" --body "Still red: ${run_url}"
  else
    gh label create "$LABEL" --force --color B60205 --description "The nightly base build is red" >/dev/null
    gh issue create --label "$LABEL" --title "nightly is red" \
      --body "The nightly failed: ${run_url}. This issue is updated on every red nightly and closed by the next green one."
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  stall) cmd_stall "$@" ;;
  force) cmd_force ;;
  alert) cmd_alert "$@" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac

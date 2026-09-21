#!/usr/bin/env bash
# D21's gate in build.yml's plan job ("Is D21 actually in force?"), run from the shipping workflow.
# SYSTEM-REVIEW §2.18 / H6: it was only a ::warning::. It must now fail the build when the mirror
# verifiably holds base.lock's digest but FROM still points upstream, and only warn when the
# mirror cannot be seen (flipping FROM then would break the build).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"

STEP="$(python3 - "$REPO/.github/workflows/build.yml" <<'PY'
import sys, yaml
for s in yaml.safe_load(open(sys.argv[1]))['jobs']['plan']['steps']:
    if s.get('name') == 'Is D21 actually in force?':
        print(s['run'])
PY
)"
[ -n "$STEP" ] || t_abort "no 'Is D21 actually in force?' step in build.yml's plan job — the gate moved or was deleted"

W="$(newroot)"; cp "$REPO/base.lock" "$W/"
DIGEST="$(grep -m1 '^UPSTREAM_DIGEST=' "$REPO/base.lock" | cut -d= -f2)"
UP="$(stubdir)";   stub "$UP" skopeo   <<<$'#!/bin/sh\necho "$*" > "${SKOPEO_ARGS:-/dev/null}"; exit 0'
DOWN="$(stubdir)"; stub "$DOWN" skopeo <<<$'#!/bin/sh\necho "manifest unknown" >&2; exit 1'
gate() { # <stub-dir> <base_via>
  (cd "$W" && PATH="$1:$PATH" BASE_VIA="$2" MIRROR=ghcr.io/example/auros-upstream-mirror \
     SKOPEO_ARGS="$W/args" bash -euo pipefail -c "$STEP")
}

group "FROM already via the mirror"
run_check d21 green "base_via=mirror passes without asking the registry" -- gate "$DOWN" mirror

group "FROM via upstream"
run_check d21 red "mirror holds base.lock's digest -> the build FAILS" -- gate "$UP" upstream
assert_has "…and says which line to flip, to what" "Flip the FROM line to 'ghcr.io/example/auros-upstream-mirror@${DIGEST}'" "$T_LAST_OUT"
assert_eq "…having inspected the mirror BY base.lock's digest" \
  "inspect --raw docker://ghcr.io/example/auros-upstream-mirror@${DIGEST}" "$(cat "$W/args" 2>/dev/null)"
run_check d21 green "mirror not visibly populated -> warning only (flipping would break the build)" -- gate "$DOWN" upstream
assert_has "…and the warning is emitted" "::warning::FROM still resolves against upstream" "$T_LAST_OUT"

group "no digest to check against"
sed -i.bak '/^UPSTREAM_DIGEST=/d' "$W/base.lock"
run_check d21 red "base.lock without UPSTREAM_DIGEST fails rather than guessing" -- gate "$UP" upstream

t_finish d21-gate.test.sh

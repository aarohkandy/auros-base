#!/usr/bin/env bash
# org.opencontainers.image.created — what `bootc status` reports as the image's age.
#
# The LABEL is inherited from Aurora unless we set it (2026-09-15T20:28:34Z on the pinned digest), and
# the publish-time flatten drops every Containerfile LABEL unless it is passed back with --label
# (measured on stage-35550863705). So three things have to hold, and each is run here from the
# shipping file rather than copied:
#   1. the Containerfile sets it, from an ARG whose default is SOURCE_DATE_EPOCH's default in ISO form;
#   2. build.yml derives the value from SOURCE_DATE_EPOCH (deterministic: S7 builds twice);
#   3. build.yml's flatten carries every declared LABEL across, and refuses one with no value.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/harness.sh"
CF="$REPO/Containerfile"; WF="$REPO/.github/workflows/build.yml"
iso() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }

group "Containerfile"
cf_check() { # <containerfile> — the label is set from IMAGE_CREATED, whose default matches SOURCE_DATE_EPOCH's
  local sde def
  grep -qxF 'LABEL org.opencontainers.image.created="${IMAGE_CREATED}"' "$1" || { echo "no image.created LABEL from IMAGE_CREATED"; return 1; }
  sde="$(sed -n 's/^ARG SOURCE_DATE_EPOCH=//p' "$1")"; def="$(sed -n 's/^ARG IMAGE_CREATED=//p' "$1")"
  [ -n "$sde" ] && [ "$def" = "$(iso "$sde")" ] || { echo "ARG IMAGE_CREATED=$def is not SOURCE_DATE_EPOCH=$sde in ISO form"; return 1; }
}
run_check cf green "the shipping Containerfile" -- cf_check "$CF"
W="$(newroot)"
grep -v '^LABEL org.opencontainers.image.created=' "$CF" > "$W/no-label"
run_check cf red "…without the LABEL line (Aurora's date is inherited)" -- cf_check "$W/no-label"
sed 's/^ARG SOURCE_DATE_EPOCH=.*/ARG SOURCE_DATE_EPOCH=1790816523/' "$CF" > "$W/drifted"
run_check cf red "…with SOURCE_DATE_EPOCH moved and IMAGE_CREATED left behind" -- cf_check "$W/drifted"

step() { # <job> <step-name> — the run: block, from the shipping workflow
  python3 - "$WF" "$1" "$2" <<'PY'
import sys, yaml
for s in yaml.safe_load(open(sys.argv[1]))['jobs'][sys.argv[2]]['steps']:
    if s.get('name') == sys.argv[3]:
        print(s['run'])
PY
}

group "build.yml derives the label from SOURCE_DATE_EPOCH"
SDE_STEP="$(step build 'Deterministic inputs')"
[ -n "$SDE_STEP" ] || t_abort "no 'Deterministic inputs' step in build.yml's build job"
B="$(stubdir)"
stub "$B" git  <<<$'#!/bin/sh\necho "$FAKE_EPOCH"'
# GNU `date -u -d @N +FMT` (the runner's), emulated so this runs on macOS too.
stub "$B" date <<<$'#!/usr/bin/env python3\nimport sys,time\na=sys.argv[1:]\ne=int(next(x for x in a if x.startswith("@"))[1:])\nprint(time.strftime(next(x for x in a if x.startswith("+"))[1:], time.gmtime(e)))'
derive() { # <epoch> — prints the IMAGE_CREATED the step exports
  : > "$W/env"
  PATH="$B:$PATH" FAKE_EPOCH="$1" GITHUB_ENV="$W/env" GITHUB_OUTPUT=/dev/null bash -euo pipefail -c "$SDE_STEP" >/dev/null
  sed -n 's/^IMAGE_CREATED=//p' "$W/env"
}
assert_eq "commit time 1789504430 -> the label value" "2026-09-15T20:33:50Z" "$(derive 1789504430)"
assert_eq "same commit, second build -> the same value (S7 builds twice)" "$(derive 1789504430)" "$(derive 1789504430)"
assert_eq "a later commit -> a later value (it is ours, not a constant)" "2026-10-01T01:02:03Z" "$(derive 1790816523)"
S7_STEP="$(step build 'Build and flatten, twice')"
assert_has "the build passes it in as the build argument the LABEL reads" '--build-arg IMAGE_CREATED="$IMAGE_CREATED"' "$S7_STEP"

group "build.yml's flatten carries the Containerfile's labels across"
LOOP="$(printf '%s\n' "$S7_STEP" | sed -n '/local -a label_args=()/,/^  done$/p')"
[ -n "$LOOP" ] || t_abort "the label loop in 'Build and flatten, twice' moved"
assert_has "…and they reach build-chunked-oci" '"${label_args[@]}"' "$S7_STEP"
stub "$B" sudo <<<$'#!/bin/sh\nexec "$@"'
stub "$B" skopeo <<<$'#!/bin/sh\ncat "$FAKE_CONFIG"'
labels() { # <config.json> — the --label arguments the loop would pass
  (cd "$REPO" && PATH="$B:$PATH" FAKE_CONFIG="$1" bash -euo pipefail -c \
     "f() { $LOOP
      printf '%s\n' \"\${label_args[@]}\"; }; raw=x; f")
}
jq -n '{config:{Labels:{"org.opencontainers.image.created":"2026-10-01T01:02:03Z","org.opencontainers.image.title":"auros-base",
  "org.opencontainers.image.description":"d","org.opencontainers.image.source":"s","org.opencontainers.image.documentation":"d",
  "org.opencontainers.image.url":"u","org.opencontainers.image.vendor":"Auros","org.opencontainers.image.licenses":"Apache-2.0",
  "org.opencontainers.image.base.name":"n","org.opencontainers.image.base.digest":"sha256:x","dev.auros.recipe":"base",
  "dev.auros.image.kind":"base","dev.auros.upstream.image":"i","dev.auros.upstream.tag":"t","dev.auros.upstream.digest":"sha256:x",
  "containers.bootc":"1","org.opencontainers.image.version":"44.20260915.2"}}}' > "$W/cfg.json"
run_check labels green "a built image with every declared label" -- labels "$W/cfg.json"
assert_has "image.created is passed to the flatten" "org.opencontainers.image.created=2026-10-01T01:02:03Z" "$T_LAST_OUT"
assert_not "containers.bootc is left to --bootc" "containers.bootc=" "$T_LAST_OUT"
assert_not "Aurora's own labels are not carried (only what the Containerfile declares)" "image.version=" "$T_LAST_OUT"
jq 'del(.config.Labels["org.opencontainers.image.created"])' "$W/cfg.json" > "$W/cfg-missing.json"
run_check labels red "a built image missing a declared label fails rather than publishing without it" -- labels "$W/cfg-missing.json"

t_finish image-created.test.sh

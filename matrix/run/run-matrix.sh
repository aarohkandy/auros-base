#!/usr/bin/env bash
# run-matrix.sh — the whole matrix, in the order that wastes the least time when something is broken:
# static first (seconds), then one boot run per bound profile, then the update group, then results.
#
# Fan-out: --jobs N runs profiles concurrently on this host. From an agent context, prefer one subagent
# per profile, each invoking run-boot.sh and returning ONLY "PROFILE pass|fail" plus its log path —
# the per-profile logs are large and a caller that reads them all loses the thread (spec §8).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

IMAGE=''; RECIPE=''; RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-local-$(date +%s)}"
PROFILES=''; JOBS=1; UPDATE_PROFILE='uefi-modern'; SKIP_UPDATE=0; RECORD=1
declare -a PASSTHRU=()

usage() { cat >&2 <<'USAGE'
usage: run-matrix.sh --image REF [options] [-- <args passed to run-static.sh and run-boot.sh>]
  --image REF            image under test (required)
  --recipe NAME          recipe name; omitted means this is the base image and ALL profiles are bound
  --profiles a,b,c       profiles to run (default: all of profiles.yaml for a base image)
  --update-profile ID    which profile carries the update group (default uefi-modern)
  --jobs N               run N profiles concurrently (RAM is the constraint: 8 GB each)
  --run-url URL          the CI run anyone can reopen (default: derived from GitHub env)
  --no-update            skip the update group entirely — it will then be recorded as failing, because
                         an absent result is a failure; use only when iterating on boot checks
  --no-record            do not touch the ledger or compat.tsv
  --out DIR              run directory
USAGE
exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2;;
    --recipe) RECIPE=$2; shift 2;;
    --profiles) PROFILES=$2; shift 2;;
    --update-profile) UPDATE_PROFILE=$2; shift 2;;
    --jobs) JOBS=$2; shift 2;;
    --run-url) RUN_URL=$2; shift 2;;
    --no-update) SKIP_UPDATE=1; shift;;
    --no-record) RECORD=0; shift;;
    --out) AUROS_RUN_DIR=$2; shift 2;;
    --) shift; PASSTHRU=("$@"); break;;
    -h|--help) usage;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$IMAGE" ] || usage
export AUROS_RUN_DIR
mkdir -p "$AUROS_RUN_DIR/checks" "$AUROS_RUN_DIR/logs" "$AUROS_RUN_DIR/work"
STARTED=$(now_iso)

if [ -z "$PROFILES" ]; then
  [ -z "$RECIPE" ] || die "a recipe must name its profiles: pass --profiles (its hardware_profile: field, plus uefi-modern always)"
  PROFILES=$(node "$HARNESS_DIR/lib/profile.mjs" --list)
fi
IFS=',' read -r -a PROFILE_LIST <<< "$PROFILES"
log "matrix: image=$IMAGE recipe=${RECIPE:-<base>} profiles=${PROFILE_LIST[*]} update-on=$UPDATE_PROFILE"

# ── static ───────────────────────────────────────────────────────────────────────────────────────
STATIC_RC=0
"$HARNESS_DIR/run-static.sh" --image "$IMAGE" ${RECIPE:+--recipe "$RECIPE"} --out "$AUROS_RUN_DIR" \
  "${PASSTHRU[@]+"${PASSTHRU[@]}"}" || STATIC_RC=$?
if [ "$STATIC_RC" -ne 0 ]; then
  log "STATIC FAILED — not booting anything. Assembling results so the failure is recorded against the digest."
fi

# ── boot, per profile ────────────────────────────────────────────────────────────────────────────
if [ "$STATIC_RC" -eq 0 ]; then
  run_one() {
    local p=$1
    if "$HARNESS_DIR/run-boot.sh" --profile "$p" --image "$IMAGE" ${RECIPE:+--recipe "$RECIPE"} \
         --out "$AUROS_RUN_DIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" > "$AUROS_RUN_DIR/logs/run-boot-$p.log" 2>&1; then
      echo "$p pass  $AUROS_RUN_DIR/logs/run-boot-$p.log"
    else
      echo "$p fail  $AUROS_RUN_DIR/logs/run-boot-$p.log"
    fi
  }
  if [ "$JOBS" -gt 1 ]; then
    for p in "${PROFILE_LIST[@]}"; do
      while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 2; done
      run_one "$p" &
    done
    wait
  else
    for p in "${PROFILE_LIST[@]}"; do run_one "$p"; done
  fi

  if [ "$SKIP_UPDATE" = 0 ]; then
    "$HARNESS_DIR/run-update.sh" --image "$IMAGE" --profile "$UPDATE_PROFILE" ${RECIPE:+--recipe "$RECIPE"} \
      --out "$AUROS_RUN_DIR" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" > "$AUROS_RUN_DIR/logs/run-update.log" 2>&1 \
      && echo "update pass  $AUROS_RUN_DIR/logs/run-update.log" \
      || echo "update fail  $AUROS_RUN_DIR/logs/run-update.log"
  else
    warn "--no-update: U1..U5 and R1 will be recorded as failures, because an absent result is a failure"
  fi
fi

# ── results ──────────────────────────────────────────────────────────────────────────────────────
DIGEST=$(cat "$AUROS_RUN_DIR/work/digest" 2>/dev/null || true)
[ -n "$DIGEST" ] || DIGEST=$(image_digest "$IMAGE" || true)
[ -n "$DIGEST" ] || die "no content digest for $IMAGE — results cannot be keyed to a tag"
IMG_NAME=${IMAGE%@*}; IMG_NAME=${IMG_NAME%:*}

node "$HARNESS_DIR/emit-results.mjs" --run-dir "$AUROS_RUN_DIR" --image "$IMG_NAME" --digest "$DIGEST" \
  --run-url "$RUN_URL" ${RECIPE:+--recipe "$RECIPE"} --profiles "$PROFILES" \
  --update-profile "$UPDATE_PROFILE" --started-at "$STARTED"
EMIT_RC=$?

if [ "$RECORD" = 1 ] && [ "$EMIT_RC" -eq 0 ]; then
  node "$HARNESS_DIR/record-pass.mjs" --results "$AUROS_RUN_DIR/results.json" --bound-profiles "$PROFILES" \
    --update-profile "$UPDATE_PROFILE" --compat-rows "$AUROS_RUN_DIR/compat-rows.tsv" || exit 1
else
  exit "${EMIT_RC:-1}"
fi

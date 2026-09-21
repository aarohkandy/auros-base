#!/usr/bin/env bash
# run-static.sh — S1..S10 against the OCI image. No VM. Seconds, not minutes.
#
# CONTRACT WITH THE CALLER: exit 0 only if every static check passed. A non-zero exit means DO NOT
# PROCEED TO BOOT CHECKS — there is no point spending twenty minutes booting an image that failed lint,
# and more importantly a harness that carries on after a red static run trains people to read a red run
# as normal.
#
# Every unevaluable check is a FAIL. There is no "could not determine" in a gate.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

IMAGE=''; DIGEST=''; REGISTRY_REF=''; SECOND_DIGEST=''; CONTAINERFILE=''; BUDGET=''; POLICY='auto'
RECIPE=''; COSIGN_KEY=''; SCOPE=''; LEDGER="$META_REPO/attest/passed-digests.tsv"
declare -a INSTALL_RPMS=() FLATPAK_REFS=() REMOVE_PKGS=()

usage() { sed -n '2,20p' "$0"; cat >&2 <<'USAGE'

usage: run-static.sh --image REF [options]
  --image REF             image under test: a local podman ref or a registry ref (required)
  --digest sha256:...     content digest under test (resolved from --image when omitted)
  --registry-ref REF      the PUSHED, SIGNED reference; required for S8
  --second-digest sha256: digest of the second build of identical inputs; required for S7
  --containerfile PATH    Containerfile whose FROM is checked against base.lock (default: auros-base/Containerfile)
  --budget-bytes N        declared compressed-pull budget for S6
  --policy MODE           open|managed|locked|kiosk (default: read from the image)
  --recipe NAME           recipe name; omit for a base build
  --install-rpm PKG       repeatable
  --flatpak-ref REF       repeatable
  --remove-pkg PKG        repeatable (the recipe's declared remove: list)
  --cosign-key PATH       public key for S8; default: the key the IMAGE itself ships
  --ledger PATH           attest ledger, read for S6's previous-digest comparison
  --out DIR               run directory (default $PWD/matrix-run)
USAGE
exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2;;
    --digest) DIGEST=$2; shift 2;;
    --registry-ref) REGISTRY_REF=$2; shift 2;;
    --second-digest) SECOND_DIGEST=$2; shift 2;;
    --containerfile) CONTAINERFILE=$2; shift 2;;
    --budget-bytes) BUDGET=$2; shift 2;;
    --policy) POLICY=$2; shift 2;;
    --recipe) RECIPE=$2; shift 2;;
    --install-rpm) INSTALL_RPMS+=("$2"); shift 2;;
    --flatpak-ref) FLATPAK_REFS+=("$2"); shift 2;;
    --remove-pkg) REMOVE_PKGS+=("$2"); shift 2;;
    --cosign-key) COSIGN_KEY=$2; shift 2;;
    --ledger) LEDGER=$2; shift 2;;
    --out) AUROS_RUN_DIR=$2; shift 2;;
    -h|--help) usage;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$IMAGE" ] || usage
export AUROS_RUN_DIR
mkdir -p "$AUROS_RUN_DIR/checks" "$AUROS_RUN_DIR/logs" "$AUROS_RUN_DIR/work"
CHECKS_FILE="$AUROS_RUN_DIR/checks/static.jsonl"; : > "$CHECKS_FILE"
W="$AUROS_RUN_DIR/work"; L="$AUROS_RUN_DIR/logs"

need podman; need node
CFG="$META_REPO/auros.config.json"
if [ -z "$SCOPE" ] && [ -f "$CFG" ]; then
  SCOPE=$(node -e 'const c=require(process.argv[1]);process.stdout.write(`${c.registry}/${c.org}`)' "$CFG")
fi
: "${SCOPE:=ghcr.io/aarohkandy}"
[ -n "$CONTAINERFILE" ] || CONTAINERFILE="$BASE_REPO/Containerfile"

log "static matrix · image=$IMAGE · recipe=${RECIPE:-<base>} · scope=$SCOPE"

# ── S1 — Base is pinned by digest ────────────────────────────────────────────────────────────────
check_begin
LOCK_IMG=$(read_lock UPSTREAM_IMAGE); LOCK_DIG=$(read_lock UPSTREAM_DIGEST)
if [ ! -f "$CONTAINERFILE" ]; then
  record S1 fail "no Containerfile at $CONTAINERFILE — the FROM line is what S1 checks, and an absent build file cannot be pinned (pass --containerfile if it lives elsewhere)"
else
  FROM_LINE=$(grep -iE '^[[:space:]]*FROM[[:space:]]' "$CONTAINERFILE" | head -1 | sed 's/[[:space:]]\+/ /g')
  FROM_REF=$(printf '%s' "$FROM_LINE" | awk '{print $2}')
  if [[ "$FROM_REF" != *"@sha256:"* ]]; then
    record S1 fail "FROM is not pinned by digest: '${FROM_LINE}'. A tag is a moving target; two builds a day apart would be different operating systems wearing the same name."
  else
    FROM_IMG=${FROM_REF%@*}; FROM_DIG=${FROM_REF#*@}
    if [ "$FROM_DIG" != "$LOCK_DIG" ]; then
      record S1 fail "FROM digest $FROM_DIG != base.lock UPSTREAM_DIGEST $LOCK_DIG"
    elif [ "$FROM_IMG" != "$LOCK_IMG" ] && [ "$FROM_IMG" != "$(read_lock UPSTREAM_MIRROR)" ]; then
      # D21: upstream garbage-collects the digest we pin, so the base mirrors it into our own
      # namespace and FROM may resolve against the mirror. The DIGEST is what S1 is really about, and
      # it is identical either way; the image name may be upstream's or base.lock's UPSTREAM_MIRROR.
      record S1 fail "FROM image $FROM_IMG is neither base.lock UPSTREAM_IMAGE ($LOCK_IMG) nor UPSTREAM_MIRROR ($(read_lock UPSTREAM_MIRROR | sed 's/^$/unset/'))"
    else
      record S1 pass "FROM ${FROM_IMG}@${FROM_DIG} == base.lock exactly"
    fi
  fi
fi

# ── resolve the digest under test ────────────────────────────────────────────────────────────────
if [ -z "$DIGEST" ]; then DIGEST=$(image_digest "$IMAGE" || true); fi
if [[ ! "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  warn "could not resolve a content digest for $IMAGE — results.json cannot be keyed to a tag"
  DIGEST=''
fi
printf '%s' "${DIGEST}" > "$W/digest"
log "digest under test: ${DIGEST:-<unresolved>}"

# ── S2 — Container lint ──────────────────────────────────────────────────────────────────────────
check_begin
if podman run --rm --network=none --entrypoint= "$IMAGE" bootc container lint > "$L/s2-lint.log" 2>&1; then
  record S2 pass "bootc container lint exited 0 ($(wc -l < "$L/s2-lint.log" | tr -d ' ') lines, see logs/s2-lint.log)"
else
  record S2 fail "bootc container lint exited non-zero: $(tail -5 "$L/s2-lint.log" | tr '\n' ' ')"
fi

# ── in-image probe (feeds S3, S4, S5, S9, S10) ───────────────────────────────────────────────────
log "probing the image"
if ! podman run --rm -i --network=none --entrypoint= "$IMAGE" bash -s -- "$SCOPE" \
      < "$HARNESS_DIR/guest/image-probe.sh" > "$W/probe.txt" 2> "$L/probe.err"; then
  warn "image probe exited non-zero; analyze.mjs will fail the checks that depend on it"
fi

# The pinned upstream base, when it is in local storage, lets S5 compare the removal report against a
# MEASURED closure instead of believing it. In CI it is always local — it is the build's FROM.
: > "$W/upstream-rpms.tsv"
UP_REF="${LOCK_IMG}@${LOCK_DIG}"
if podman image exists "$UP_REF" 2>/dev/null; then
  log "measuring the pinned upstream package set for S5"
  podman run --rm --network=none --entrypoint= "$UP_REF" rpm -qa --qf '%{NAME}\t%{SIZE}\n' 2>/dev/null | sort > "$W/upstream-rpms.tsv" || : > "$W/upstream-rpms.tsv"
else
  warn "pinned upstream $UP_REF is not in local storage — S5 cannot verify the removal closure independently and will fail closed"
fi

printf '%s\n' "${INSTALL_RPMS[@]+"${INSTALL_RPMS[@]}"}" > "$W/install-rpms.txt"
printf '%s\n' "${REMOVE_PKGS[@]+"${REMOVE_PKGS[@]}"}" > "$W/declared-remove.txt"

# ── S4, flatpak half — do the declared refs resolve on Flathub? ──────────────────────────────────
FP_RESULT="$W/flatpak-result.json"
if [ ${#FLATPAK_REFS[@]} -eq 0 ]; then
  printf '{"status":"pass","detail":"no flatpak refs declared"}' > "$FP_RESULT"
else
  BAD=''; METHOD=''
  if have flatpak; then METHOD=flatpak; elif have curl; then METHOD=flathub-api; fi
  if [ -z "$METHOD" ]; then
    printf '{"status":"fail","detail":"cannot resolve flatpak refs: %s AND %s A missing tool is a FAIL, not a skip — otherwise the check quietly stops testing."}' "$(tool_missing_detail flatpak)" "$(tool_missing_detail curl)" > "$FP_RESULT"
  else
    for ref in "${FLATPAK_REFS[@]}"; do
      appid=$ref; case "$ref" in */*) appid=$(printf '%s' "$ref" | cut -d/ -f2);; esac
      ok=1
      if [ "$METHOD" = flatpak ]; then
        flatpak remote-info --system flathub "$ref" >/dev/null 2>&1 || flatpak remote-info --system flathub "$appid" >/dev/null 2>&1 || ok=0
      else
        curl -fsS --max-time 20 "https://flathub.org/api/v2/appstream/${appid}" -o /dev/null 2>/dev/null || ok=0
      fi
      [ "$ok" = 1 ] || BAD="$BAD $ref"
    done
    if [ -n "$BAD" ]; then printf '{"status":"fail","detail":"unresolvable on Flathub (via %s):%s"}' "$METHOD" "$BAD" > "$FP_RESULT"
    else printf '{"status":"pass","detail":"%d ref(s) resolve on Flathub via %s"}' "${#FLATPAK_REFS[@]}" "$METHOD" > "$FP_RESULT"; fi
  fi
fi

node "$HARNESS_DIR/lib/analyze.mjs" \
  --probe "$W/probe.txt" --out "$CHECKS_FILE" \
  --recipe "$RECIPE" --policy "$POLICY" --scope "$SCOPE" \
  --declared-remove "$W/declared-remove.txt" --install-rpms "$W/install-rpms.txt" \
  --upstream-rpms "$W/upstream-rpms.tsv" --flatpak-result "$FP_RESULT"

# ── S6 — Size budget ─────────────────────────────────────────────────────────────────────────────
# Measured as COMPRESSED PULL SIZE, because that is the number that lands on a school's uplink
# (BLOCKED.md B6), and it is the same unit as base.lock's UPSTREAM_PULL_SIZE_BYTES.
# THE SOURCE MATTERS, AND THE OLD ORDER GOT IT BACKWARDS.
# `containers-storage:` was tried FIRST. That store keeps layers UNCOMPRESSED, so its manifest
# reports `application/vnd.oci.image.layer.v1.tar` and sizes that are nothing like a pull. Measured
# on run 35548005729 against a bare derivative of the pinned base: 257 layers, 8,439,590,767 bytes,
# every layer `...layer.v1.tar`. base.lock records the same upstream as 3,758,096,384 bytes
# compressed. So S6 was reporting a number 2.2x too large and calling it "compressed pull size",
# and any budget set to make it pass would have been a budget for the wrong quantity.
#
# The unit S6 is about is what lands on a school's uplink (BLOCKED.md B6). That can only be read
# from a REGISTRY. So: the registry first, and local storage only as a fallback that says plainly
# it cannot answer the question.
check_begin
PULL_BYTES=''; PULL_SOURCE=''; PULL_COMPRESSED=0; LAYER_TYPES=''
if have skopeo; then
  REG_SRC=''
  if [ -n "$REGISTRY_REF" ]; then REG_SRC="docker://$REGISTRY_REF"
  elif [[ "$IMAGE" == *.*/* ]] || [[ "$IMAGE" == *:*/* ]]; then REG_SRC="docker://$IMAGE"; fi
  if [ -n "$REG_SRC" ] && skopeo inspect --raw "$REG_SRC" > "$W/manifest.json" 2>"$L/s6-skopeo.log"; then
    PULL_SOURCE="$REG_SRC"
  elif skopeo inspect --raw "containers-storage:$IMAGE" > "$W/manifest.json" 2>>"$L/s6-skopeo.log"; then
    PULL_SOURCE="containers-storage:$IMAGE"
  fi
  if [ -s "$W/manifest.json" ]; then
    # The layer media types decide whether this is a pull size at all. Asked, not assumed.
    read -r PULL_BYTES PULL_COMPRESSED LAYER_TYPES <<<"$(node -e '
      const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const ls=m.layers||[];
      const bytes=ls.reduce((a,l)=>a+(l.size||0),0)+(m.config?.size||0);
      const types=[...new Set(ls.map(l=>l.mediaType||"?"))];
      const compressed=ls.length>0 && types.every(t=>/gzip|zstd/.test(t)) ? 1 : 0;
      process.stdout.write(`${bytes} ${compressed} ${types.join(",")}`);' "$W/manifest.json" || echo '0 0 unreadable')"
  fi
fi
printf '%s' "${PULL_BYTES:-0}" > "$W/pull-bytes"
if [ -z "$PULL_BYTES" ] || [ "$PULL_BYTES" = "0" ]; then
  record S6 fail "could not measure the compressed pull size (skopeo inspect --raw produced nothing usable from ${PULL_SOURCE:-any source}). An unmeasured size is a fail — subtraction is the product, and a product we cannot weigh is a product we cannot sell."
elif [ "$PULL_COMPRESSED" != "1" ]; then
  record S6 fail "measured ${PULL_BYTES} B from ${PULL_SOURCE}, but its layers are [${LAYER_TYPES}] — UNCOMPRESSED. That is the on-disk size, not the download. S6's unit is what lands on a school's uplink, and local container storage cannot answer that: on the pinned base the two differ by more than a factor of two (8.44 GB on disk vs base.lock's 3.76 GB compressed). Pass --registry-ref pointing at the pushed image, or run S6 against a registry reference."
elif [ -z "$BUDGET" ]; then
  record S6 fail "measured compressed pull size ${PULL_BYTES} bytes from ${PULL_SOURCE}, but NO BUDGET IS DECLARED. Pass --budget-bytes. An undeclared budget is not an infinite budget; it is an image that can grow forever without anyone noticing."
else
  PREV=''
  if [ -f "$LEDGER" ]; then
    PREV=$(awk -F'\t' '
      NR==1 { for(i=1;i<=NF;i++) col[$i]=i; c=col["pull_size_bytes"]; next }
      { if (c > 0) { v=$c; if (v ~ /^[0-9]+$/ && v+0 > 0) last=v } }
      END { if (last) print last }' "$LEDGER" 2>/dev/null || true)
  fi
  MSG="measured ${PULL_BYTES} B compressed pull (from ${PULL_SOURCE}, layers [${LAYER_TYPES}]) vs budget ${BUDGET} B"
  if [ "$PULL_BYTES" -gt "$BUDGET" ]; then
    record S6 fail "$MSG — over budget by $(( PULL_BYTES - BUDGET )) B"
  elif [ -n "$PREV" ] && [ "$PREV" -gt 0 ] && [ "$PULL_BYTES" -gt $(( PREV + PREV / 10 )) ]; then
    record S6 fail "$MSG; within budget but a ${PULL_BYTES}B image is more than 10% larger than the last published digest (${PREV}B)"
  elif [ -n "$PREV" ]; then
    record S6 pass "$MSG; previous published ${PREV} B (delta $(( PULL_BYTES - PREV )) B)"
  else
    record S6 pass "$MSG; no previous published digest in ${LEDGER##*/}, so the 10% regression half has no baseline yet — it starts applying at the second publish"
  fi
fi

# ── S7 — Determinism ─────────────────────────────────────────────────────────────────────────────
check_begin
if [ -z "$SECOND_DIGEST" ]; then
  record S7 fail "no second build supplied. S7's criterion is 'built twice in one CI run from identical inputs, the two builds produce the same CONTENT DIGEST' — the harness does not build, so the workflow must build twice and pass --second-digest. Absent evidence of determinism is not evidence of determinism."
elif [ -z "$DIGEST" ]; then
  record S7 fail "cannot compare: the digest under test did not resolve"
elif [ "$SECOND_DIGEST" = "$DIGEST" ]; then
  record S7 pass "both builds produced $DIGEST"
else
  record S7 fail "build A $DIGEST != build B $SECOND_DIGEST — same recipe and same pinned base produced two different images"
fi

# ── S8 — Signature is DISCOVERABLE, not merely valid ─────────────────────────────────────────────
# Both halves required (D17). cosign 3.x defaults to OCI 1.1 referrer bundles that containers/image
# cannot see: `cosign verify` keeps passing while the laptop that has to install the image finds no
# signature at all, and that failure is silent.
check_begin
if [ -z "$REGISTRY_REF" ]; then
  record S8 fail "no --registry-ref. S8 is a statement about what a customer's laptop can find in the registry, so it cannot be evaluated against a local image. See run/README.md 'The S8 ordering problem'."
elif ! have cosign; then
  record S8 fail "$(tool_missing_detail cosign) A missing verifier is a fail."
elif ! have skopeo; then
  record S8 fail "$(tool_missing_detail skopeo) The discoverability half of S8 cannot be evaluated without it."
else
  KEY="$COSIGN_KEY"
  if [ -z "$KEY" ]; then
    # Verify with the key the IMAGE ships — that is the key the customer's machine will use (D8).
    KP=$(sed -n 's/^PKI_KEYS=//p' "$W/probe.txt" | head -1 | cut -d, -f1)
    if [ -n "$KP" ]; then
      podman run --rm --network=none --entrypoint= "$IMAGE" cat "/usr/lib/pki/containers/$KP" > "$W/image.pub" 2>/dev/null || true
      [ -s "$W/image.pub" ] && KEY="$W/image.pub"
    fi
  fi
  REG_IMG=${REGISTRY_REF%@*}; REG_IMG=${REG_IMG%:*}
  SIGTAG="sha256-${DIGEST#sha256:}.sig"
  VERIFY_RC=1
  if [ -n "$KEY" ]; then
    cosign verify --key "$KEY" ${AUROS_COSIGN_VERIFY_ARGS:-} "$REGISTRY_REF" > "$L/s8-cosign.log" 2>&1 && VERIFY_RC=0 || VERIFY_RC=$?
  else
    cosign verify ${AUROS_COSIGN_VERIFY_ARGS:-} "$REGISTRY_REF" > "$L/s8-cosign.log" 2>&1 && VERIFY_RC=0 || VERIFY_RC=$?
  fi
  TAG_FOUND=0
  skopeo list-tags "docker://$REG_IMG" > "$W/tags.json" 2>"$L/s8-skopeo.log" || true
  grep -q "$SIGTAG" "$W/tags.json" 2>/dev/null && TAG_FOUND=1
  if [ "$VERIFY_RC" -ne 0 ] && [ "$TAG_FOUND" -ne 1 ]; then
    record S8 fail "cosign verify failed AND no legacy .sig tag ($SIGTAG) on $REG_IMG: $(tail -3 "$L/s8-cosign.log" | tr '\n' ' ')"
  elif [ "$VERIFY_RC" -ne 0 ]; then
    record S8 fail "the .sig tag exists but cosign verify failed: $(tail -3 "$L/s8-cosign.log" | tr '\n' ' ')"
  elif [ "$TAG_FOUND" -ne 1 ]; then
    record S8 fail "cosign verify PASSED but skopeo finds no ${SIGTAG} tag on ${REG_IMG}. This is the silent failure D17 describes: the signature exists in a format containers/image cannot read, so every customer machine would refuse (or, worse, not look). Sign with --new-bundle-format=false."
  else
    record S8 pass "cosign verify ok with ${KEY:+the key the image ships}${KEY:-ambient identity}, and ${SIGTAG} is present on ${REG_IMG} where containers/image will look for it"
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────────────────────────
FAILS=$(grep -c '"status":"fail"' "$CHECKS_FILE" || true)
SKIPS=$(grep -c '"status":"skip"' "$CHECKS_FILE" || true)
log "static: $(wc -l < "$CHECKS_FILE" | tr -d ' ') checks recorded, ${FAILS} failed, ${SKIPS} skipped"
if [ "${FAILS:-0}" -gt 0 ] || [ "${SKIPS:-0}" -gt 0 ]; then
  log "STATIC FAILED — the caller must NOT proceed to boot checks"
  exit 1
fi
log "static passed"

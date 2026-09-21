# CI — what runs, what it needs, and how to read it when it is red

Five workflows live in `.github/workflows/`. Two are measurement artefacts and stay. Three are the
build.

| File | Trigger | What it is |
|---|---|---|
| `build.yml` | push to `main`, PR to `main`, `workflow_call` | **The only path to `:hardened`.** Build, check, sign, gate, publish. |
| `nightly.yml` | `schedule` 04:17 UTC, `workflow_dispatch` | Re-resolve upstream; if it moved, relock and run `build.yml`; then notify `auros-recipes`. |
| `gate1-exit.yml` | `workflow_dispatch`, `schedule` Mon 06:40 UTC | Runs the Gate 1 exit condition literally and reports a binary result with its own limits attached. |
| `probe.yml` | manual | Runner capability probe. Evidence, not build. **Do not delete.** |
| `probe-boot.yml` | manual | Image → qcow2 → QEMU → login prompt. Evidence, not build. **Do not delete.** |

---

## 1. `build.yml`

### The shape

```
plan ──► build ──┬──► static ──┐
                 └──► boot ×7 ─┴──► sign ──► update ──► publish ──► cleanup
```

| Job | Does | Proves |
|---|---|---|
| `plan` | reads `auros.config.json` and `matrix/*.yaml`; runs `tools/resolve-upstream.sh assert` | **S1** |
| `build` | mirrors the pinned upstream digest (D21); builds **twice**; flattens each with `rpm-ostree compose build-chunked-oci --bootc` (D2/D11); compares content digests; pushes an **unsigned** `stage-<run_id>` tag | **S7** |
| `static` | `matrix/run.sh --phase static` against the staging digest | **S2–S6, S9, S10** |
| `boot` | one job per entry in `matrix/profiles.yaml`, fanned out | **B1–B12** |
| `sign` | cosign **keyed** signing with the key the image trusts, then proves the signature is *discoverable* | **S8** |
| `update` | `matrix/run.sh --phase update`, handing the harness the private key | **U1–U5, R1** |
| `publish` | assembles `results.json`, records the ledger row, **runs the gate**, moves `:hardened` | spec §4.3 |
| `cleanup` | notes the staging tags it cannot delete | nothing; it is housekeeping |
| `keep-nightly-enabled` | re-enables `nightly.yml` on every push to `main` | see §5 |

The boot fan-out is **read from `matrix/profiles.yaml`**, not typed into the workflow. Adding a profile
to that file adds a boot job, with no CI edit. That is deliberate: a profile list that has to be kept in
sync by hand drifts, and the drift is silent.

### The no-bypass property

Spec §4.3 asks for a gate "that cannot be overridden by a flag". The claim, stated so you can check it
rather than believe it:

- `build.yml` has **no `workflow_dispatch:` trigger**. There is no button.
- Its `workflow_call:` declares **no `inputs:` and no `secrets:`**. A caller cannot parameterise it.
- **No job and no step sets `continue-on-error`.**
- `sign`, `update` and `publish` are gated on `needs.plan.outputs.publishable`, which is computed from
  `github.event_name` and `github.ref_name` alone.
- In `publish`, the `Promote to :hardened` step is **unconditional** and sits **after** `THE GATE`. With
  `bash -euo pipefail` (D19), a non-zero `gate.mjs` ends the job before promotion.
- The gate **fails closed**. A missing `gate.mjs`, a missing `matrix/run.sh`, a missing `Containerfile`,
  zero result fragments, or a fragment that does not parse all stop the run. Absence of evidence is
  treated as a fail, never as an unknown.

I checked the file for a bypass path and there is none. This is also checked mechanically — the audit
that verifies all six bullets above is in §7, and it is short enough to paste into a terminal.

The four layers that actually hold, per PLAN.md §3.2 — the CI gate is only the first:

1. `publish` reads the ledger through `tools/gate.mjs` and refuses a digest with no recorded pass.
2. GHCR write is held only by the workflow's `GITHUB_TOKEN`; the operator's own token has no
   `write:packages` (D7).
3. Install-time signature policy on the machine (D8), so an image that somehow reached the registry
   still cannot be installed.
4. The `PreToolUse` hook, as defence in depth. It constrains one agent in one harness and is not the
   guarantee, whatever spec §8 implies.

### What reaches the registry, and when

| Ref | When | Signed? | Reachable by a customer? |
|---|---|---|---|
| `:stage-<run_id>` | before any check runs | **no** | No. D8's in-image policy is `sigstoreSigned` for the whole `ghcr.io/aarohkandy` scope, so an unsigned image fails it. |
| `@sha256:…` | after static + boot pass | yes | Only by someone who hand-types the digest. No tag points at it. |
| `:hardened`, `:<date>`, `:<sha12>` | after `gate.mjs` exits 0 | yes | **Yes.** This is the tag machines follow, so this is the tag the gate protects. |

### Signing is keyed, not keyless — and that is not the instruction I was given

The brief for these workflows said "sign with cosign keyless via OIDC". **The landed image policy makes
that wrong**, so the workflows do not do it. `signing/policy.json` says:

```json
{ "type": "sigstoreSigned", "keyPath": "/usr/lib/pki/containers/auros.pub",
  "signedIdentity": { "type": "matchRepository" } }
```

A keyless signature carries a Fulcio certificate, not that key. A machine enforcing this policy would
find no signature matching `auros.pub`, refuse every update forever, and do it at 3am in a school months
after anybody remembered there was a choice. **The image's policy decides the signing method; CI does not
get a vote.** Switching to keyless would mean changing `policy.json` first and waiting for every machine
in the field to install an image containing the new policy — the same ordering problem
`signing/keys/README.md` describes for key rotation.

Before signing, the step derives the public half of `COSIGN_PRIVATE_KEY` and **diffs it against
`signing/keys/auros.pub`**. Signing with the wrong key produces a perfectly valid signature that every
customer machine rejects — and S8 would still pass, because the `.sig` tag would be discoverable. That
check is the difference between "we signed it" and "they can verify it".

Signing happens *before* the gate on purpose. U1–U5 have to exercise the real enforcement path, and an
unsigned image cannot do that — the VM would refuse a good image and U1 would fail for the wrong reason.
What the gate protects is the tag, because the tag is what a machine resolves.

### Determinism (S7), and why it is measured the way it is

`checks.yaml` asks for "the same CONTENT DIGEST" from two builds of identical inputs. The workflow
compares the **`rootfs.diff_ids`** of the two flattened images, hashed together.

`diff_ids` are the sha256 of each *uncompressed* layer. So this is an identity of the filesystem itself:
immune to gzip settings, and immune to the `created` timestamp, neither of which has anything to do with
what we built. Comparing full manifest digests would have gone red for reasons that are not regressions,
and a check that is red for the wrong reasons is a check people learn to retry.

`SOURCE_DATE_EPOCH` comes from the commit timestamp, and `podman build --timestamp` uses it. Without
that, every file mtime differs between the two builds and S7 measures the clock.

When S7 fails, the step also diffs the **pre-flatten** diff_ids. That answers the first question you will
have at 2am — is the nondeterminism ours or the chunker's — without a second CI run.

---

## 2. `nightly.yml`

1. `tools/resolve-upstream.sh update` re-resolves `ghcr.io/ublue-os/aurora:stable`.
2. **No movement → no rebuild.** PLAN.md 2.5: children rebuild when the base digest or the recipe
   changes, not unconditionally. A 180-machine site does not need a 3.5 GB pull for a build that
   produced identical bytes (BLOCKED.md B6).
3. **Movement →** commit the new `base.lock`, then call `build.yml`. Same jobs, same gate. It calls the
   workflow rather than reimplementing it, because two copies of a publish path means one of them is out
   of date and you find out which the hard way.
4. On a successful publish, notify `auros-recipes`.

### The commit-then-build ordering, which looks wrong and is not

The nightly pushes `base.lock` with `GITHUB_TOKEN`, and **a push made with `GITHUB_TOKEN` never triggers
a workflow**. So the commit alone would rebuild nothing. That is why the `build` job calls `build.yml`
directly, and why every checkout in `build.yml` uses `github.ref_name` — the branch **tip** — rather than
the triggering SHA. The tip includes the commit the nightly just made.

The cost is a small race: a push landing in the seconds between the relock commit and the checkout would
be picked up too. It would still go through the full matrix, so the failure mode is "we tested slightly
more than we meant to", which is the safe direction.

### Propagation to `auros-recipes`

**Verified**, not assumed: `auros-recipes/.github/workflows/propagate.yml` listens for
`repository_dispatch: types: [base-published]` and also polls `*/10`. It re-resolves the published
digest itself and ignores `client_payload`, so the payload we send is for a human reading the run.

- **With `AUROS_DISPATCH_TOKEN`:** instant dispatch.
- **Without it:** the step logs a notice, writes an explanation to the run summary, and exits 0. The
  nightly does **not** fail. D18 — the default `GITHUB_TOKEN` is issued *for the repository containing
  the workflow* and cannot authenticate `POST /repos/{other}/{repo}/dispatches`. (The commonly-cited
  recursion rule is not the cause; the docs exempt `repository_dispatch`.) The `*/10` poll covers it.
  Gate 2 allows 20 minutes and a 10-minute poll fits, subject to BLOCKED.md B7.

Failing the nightly over an absent notification would turn a base that published perfectly well into a
red build, and red builds that are not about the change under test are how a team stops reading them.

---

## 3. `gate1-exit.yml`

Runs the Gate 1 exit condition and reports a verdict a person can interrogate. It publishes only
ephemeral `gate1-<run_id>` tags, and asserts at the start and end of the run that `:hardened` did not
move.

**Leg A** — build V1, sign it, install it to a qcow2, boot it, log in. Apply a trivial change → V2 under
the same tag. Start the clock. **Do nothing for 20 minutes** and require the booted digest to become V2.

**Leg B** — push V3 to the same tag **unsigned**; require `bootc upgrade` to exit non-zero with the
booted digest unchanged. Then sign V3 with a **throwaway key** and require the same refusal — that
second half proves the policy checks *whose* signature it is, not merely that one exists. Then require
the refusal to hold on the **unattended** path too, because that is the path a school lives on.

**The verdict is the AND of exactly those two legs.** Supplementary evidence is reported and never
counted, because a verdict that includes whatever happened to be green is not a verdict.

### Three things it deliberately does not claim

- **The trivial change is a derived layer, not a git commit re-entering CI.** A literal commit-and-
  retrigger needs a credential `GITHUB_TOKEN` does not have. The thing under test is identical: a new
  digest appears under the tag the machine follows, and nobody touches the machine.
- **Cross-repo propagation is NOT PROVEN without `AUROS_DISPATCH_TOKEN`.** The report says so in those
  words. An in-run surrogate builds a recipe `FROM` the tag and confirms it inherits the new digest —
  that proves the rebuild *graph*, and the report labels it a surrogate. It does not prove that
  `auros-recipes` CI noticed on its own.
- **D8 is a precondition of Leg B, not a bonus.** Before anything else, the run asserts
  `.status.booted.image.image.signature == "containerPolicy"` (D25). If enforcement is Aurora's
  `insecureAcceptAnything` catch-all, a refusal proves nothing, so Leg B reports **NOT PROVEN** rather
  than PASS. Without this assertion the whole workflow could be green and mean nothing — which is
  precisely the trap D8 describes.

### The finding this workflow is most likely to surface first

D22: the update driver on this base is **`uupd.timer`**, shipping `OnCalendar=*-*-* 04:00:00` with
`RandomizedDelaySec=15m`. That is **once a day**.

**A daily timer cannot satisfy a 20-minute exit condition.** The workflow reads the timer's real next
elapse, and if it is beyond the budget it reports the literal claim as **NOT PROVEN**, then triggers the
unit by hand and measures the *mechanism* separately, labelled a surrogate. Those are different findings
and conflating them would either hide a broken updater or condemn a working one.

The resolution is a product decision, not a CI fix: either the base ships a drop-in shortening the
interval, or "within 20 minutes" is not a promise we make. Raise it with the human before changing
either.

---

## 4. Secrets

| Secret | Required? | Used by | What happens without it |
|---|---|---|---|
| `GITHUB_TOKEN` | automatic | everything | n/a |
| `COSIGN_PRIVATE_KEY` | **required** | `sign` and `update` in `build.yml`, `gate1-exit.yml` | **Nothing publishes.** The `sign` job fails with a pointer to `signing/keys/README.md`, and `gate1-exit` refuses to start rather than produce a report where Leg A fails and Leg B passes vacuously. This is fail-closed and intended. |
| `COSIGN_PASSWORD` | **required** | as above | as above |
| `AUROS_DISPATCH_TOKEN` | **optional** | `nightly.yml` (dispatch + ledger push), `build.yml` (ledger push), `gate1-exit.yml` (dispatch leg) | Nothing fails. Dispatch is skipped with a notice and the `*/10` poll carries propagation. The ledger row lives only as a build artifact for that run. `gate1-exit` reports the dispatch leg as **NOT PROVEN**. |

`AUROS_DISPATCH_TOKEN` should be a fine-grained PAT with, at minimum:

- `contents: write` on `aarohkandy/auros-recipes` — to fire `repository_dispatch`;
- `contents: write` on `aarohkandy/auros` — to commit the ledger row to `attest/passed-digests.tsv`.

Two repositories, one token, by design — but if you would rather not have a single credential able to
write to both, split it into two secrets and change the two `env:` lines that reference it. Every use is
individually non-fatal, so a token scoped to only one of the two degrades cleanly on the other.

`AUROS_DISPATCH_TOKEN` affects notification and record-keeping only — it cannot influence whether an
image publishes. `COSIGN_PRIVATE_KEY` can, but only in one direction: without it, nothing publishes.
**No secret can cause a publish that would not otherwise happen.**

### The keypair does not exist yet, and that is currently a hard blocker

`signing/keys/auros.pub` is deliberately absent, and `build/30-update-agent.sh` fails the build without
it. So **no build can currently succeed**, by design — see `signing/keys/README.md`. A dummy key would
produce an image that looks exactly like the product and refuses every update forever.

Minting the keypair is **§9-reserved**: it creates a long-lived organisational credential and is not an
agent action. The human runs `cosign generate-key-pair` (pinned to the version in `signing/cosign.lock`),
commits `auros.pub`, and sets the two secrets.

---

## 5. Free-tier limits that actually apply here

All four repos are public (PLAN.md 2.3), which changes most of these.

| | |
|---|---|
| **Actions minutes** | Free and unmetered on standard GitHub-hosted runners for public repos. The 2,000-minute figure is the *private* repo allowance and does not apply. |
| **Concurrent jobs** | 20 on the Free plan. The boot fan-out is 7, so a `build.yml` run peaks at about 8 concurrent jobs. Two overlapping runs fit; three start queueing. |
| **Job timeout** | 6 hours, hard. `gate1-exit` is set to 330 minutes for that reason. |
| **Workflow run timeout** | 35 days. Not a constraint here. |
| **Artifact + log retention** | 90 days by default. The Gate 1 report is an artifact, so **evidence older than 90 days stops being re-openable** — which matters because GATE.md requires evidence anyone can reopen. Long-lived evidence belongs in `docs/evidence/`, committed. |
| **Artifact storage** | Free for public repos. |
| **GHCR** | Free storage and bandwidth for public packages. The D21 mirror therefore costs nothing. |
| **`GITHUB_TOKEN` API rate limit** | 1,000 requests/hour/repository. Nowhere near. |
| **Cron granularity** | 5 minutes minimum, and **scheduled runs are delayed under load, sometimes by a lot** (BLOCKED.md B7). Every cron here is deliberately off the hour. |
| **cosign** | Version, bundle-format flag and installer action all come from `signing/cosign.lock` (**v2.6.5**, not the v3 line — on v3 `--new-bundle-format` defaults to true and every signature becomes invisible to `containers/image`). The `uses:` ref cannot be an expression, so `sigstore/cosign-installer@v4.1.2` is written out **and asserted against the lock** at run time. |
| **Runner image** | Pinned to `ubuntu-24.04`, never `ubuntu-latest` (D23) — `ubuntu-latest` migrates to 26.04 between 2026-10-19 and 2026-11-19, and an OS migration under a build that boots VMs is a week we do not have. |
| **Runner disk** | Measured 145 G total, 110 G free after the cleanup step (`docs/evidence/2026-09-20-runner-probe.md`). Do **not** move podman's graphroot to `/mnt`: probe-boot revision 1 did, and it broke `bootc-image-builder`, which mounts the host store at its default path and then finds a libpod DB pointing elsewhere. |

### The 60-day rule

**GitHub disables a scheduled workflow on a public repository after 60 days of repository inactivity.**
The failure mode is the worst kind available: nothing goes red, the nightly simply stops, and the first
symptom is an unpatched fleet months later. Everything this company sells is downstream of that cron.

What is in place, and honestly what each is worth:

1. `nightly.yml` calls the workflow-enable API on every run. **This is a no-op while enabled and cannot
   rescue a workflow that is already disabled** — a disabled workflow does not run, so the step does not
   run either.
2. `build.yml`'s `keep-nightly-enabled` job calls the same API on every push to `main`. **This one can
   rescue it**, because pushes still trigger workflows. It closes the window where somebody pushes after
   the nightly was silently switched off.
3. `nightly.yml`'s `schedule-health` job reads `pushed_at` and emits a warning at **45 days**, naming the
   number of days left.

Neither (1) nor (2) helps a repository with no pushes and no upstream movement for 60 days. The only
reliable mitigation is **repository activity**, or a human clicking *Enable workflow* in the Actions tab.
Treat the 45-day warning as an action item, not a notice.

---

## 6. How to read a failure

Start with the job name. Then:

| Symptom | What it means | Do |
|---|---|---|
| `plan` fails on **S1** | The Containerfile is not pinned to `base.lock`, or is pinned to a tag. | Do not edit one side by hand — that is how they drift. Run `./tools/resolve-upstream.sh update`. |
| `plan` fails on "the gate must exist" | `tools/gate.mjs`, `matrix/run.sh` or `Containerfile` is missing. | Fail-closed, working as intended. An image that cannot be gated must not exist. |
| **S3** goes red overnight | Upstream re-added a package a recipe removes. | **This is the check doing its job.** `checks.yaml` is explicit: it "must not be treated as flakiness or retried away". Retrying until green ships a kiosk image with a desktop in it. |
| **S7** fails | Two builds of identical inputs diverged. | Read the pre-flatten diff in the same step: it localises the cause to our build or to the chunker. |
| **S8** fails on the skopeo half while `cosign verify` passes | The cosign 3.x new-bundle-format regression (D17). | Check `--new-bundle-format=false` was actually applied — the step warns if the flag is absent. Then check `containers/container-libs#388`. **Never** drop the skopeo half; a green `cosign verify` is not evidence a laptop can verify us. |
| **U4** passes but `gate1-exit` says D8 is not in force | Enforcement is nominal. | The image's own policy is Aurora's `insecureAcceptAnything` catch-all. U4 passed vacuously. This is D8, and it is load-bearing. |
| `publish` fails at **THE GATE** | `gate.mjs` recomputed the verdict and disagreed. | Read `results.json` in the artifacts. The harness's own `verdict` field is ignored on purpose — a field that says `"pass"` is exactly what a broken harness would write. |
| Everything green, nothing published | The run was a PR, or not on `main`. | Expected. |
| `nightly` green, no rebuild | Upstream did not move. | Expected. The summary says so. |
| `manifest unknown` on the upstream base | **D21.** Upstream garbage-collected the digest we pin. | The mirror should already have it. If neither has it, re-resolve with `update` and mirror the new digest immediately. |

Rule that overrides all of the above, from `.claude/skills/vm-check-matrix/SKILL.md`: when a check fails,
**do not disable it, do not add a flag, do not mark it `continue-on-error`.** Write it to `BLOCKED.md`
with the digest and the run URL, take the next unblocked task, surface it at the next checkpoint. A
matrix that can be argued with is not a gate.

---

## 7. Audit the no-bypass claim yourself

```bash
python3 - <<'PY'
import yaml, sys
d = yaml.safe_load(open(".github/workflows/build.yml"))
on = d[True] if True in d else d["on"]          # PyYAML parses bare `on:` as the boolean True
jobs, bad = d["jobs"], []
if "workflow_dispatch" in on: bad.append("workflow_dispatch trigger")
wc = on.get("workflow_call") or {}
if wc.get("inputs"):  bad.append("workflow_call inputs")
if wc.get("secrets"): bad.append("workflow_call secrets")
for jn, j in jobs.items():
    if j.get("continue-on-error"): bad.append(f"job {jn}")
    for st in j.get("steps", []) or []:
        if st.get("continue-on-error"): bad.append(f"step {jn}/{st.get('name')}")
pub   = jobs["publish"]
names = [s.get("name", "") for s in pub["steps"]]
gate  = names.index("THE GATE")
prom  = next(i for i, n in enumerate(names) if n.startswith("Promote"))
if gate > prom:                 bad.append("gate runs after promotion")
if pub["steps"][prom].get("if"): bad.append("promotion is conditional")
for jn in ("sign", "update", "publish"):
    if jobs[jn]["if"] != "needs.plan.outputs.publishable == 'true'": bad.append(f"{jn} if-guard")
print("packages:write ->", [n for n, j in jobs.items()
                            if (j.get("permissions") or {}).get("packages") == "write"])
print("FAIL:" if bad else "OK — no bypass path", bad or "")
sys.exit(1 if bad else 0)
PY
```

Note the `d[True]` line: PyYAML parses a bare `on:` key as the boolean `True`, which is a genuinely
confusing thing to hit at 2am.

---

## 8. Interfaces these workflows assume

Five agents are writing in this repo. These are the contracts `build.yml` depends on that it does not
own. Each is **assumed**, and each fails closed rather than silently, so a wrong assumption produces a
red build and not a bad publish.

### `matrix/run.sh` — the check-matrix harness (TASKS A8)

**Verified by READING the landed harness, and — until 2026-09-21 — never by running it.** `matrix/run.sh`
was adapted to this interface in commit `b1806cc`. The sentence that used to stand here said "verified
against the landed harness, not assumed", which was a claim about evidence that did not exist: the two
programs agreed on paper and disagreed in every way that mattered. See **"What the first execution
found"** below before trusting anything in this section.

```
matrix/run.sh --phase static|boot|update
              --image  <ghcr ref pinned by digest>
              --digest <sha256:…>
              [--profile <id>]              # required for boot; passed for update so the fragment
                                            # lands under a real profile rather than the synthetic one
              --checks   matrix/checks.yaml
              --profiles matrix/profiles.yaml
              --out      <fragment.json>
              [-- <args passed through to the phase script>]
```

It writes one **fragment**:

```json
{ "profile": "static",
  "checks": [ { "id": "S2", "status": "pass", "detail": "…", "duration_ms": 1234 } ] }
```

`publish` merges the fragments into one `results.json` matching `matrix/results.schema.json`, grouping by
`.profile`. The harness buckets the static phase under the synthetic profile `static`, so `build.yml`'s
own hand-written fragments (S1, S7, S8) use `"profile": "static"` too — otherwise the static checks
scatter across two buckets for no reason. Boot fragments use the real profile id.

**The update phase does not take images from CI.** `matrix/run/run-update.sh` stands up its own registry
on the host, serves the image under the name the in-image policy is scoped to, and mints the old, new and
tampered variants itself. All it needs is:

```
matrix/run.sh --phase update --profile uefi-modern --image <ref> … -- --signing-key /tmp/auros.key
```

That key is the **private** half of what the image ships at `/usr/lib/pki/containers/auros.pub`. The
harness refuses to run without it, and its reasoning is worth repeating: with no key it could only offer
unsigned images, so **U4 would pass while U1 failed** — which looks like a working lock and is the exact
opposite of proving anything.

It also refuses to run without a writable `/dev/kvm` unless `AUROS_ALLOW_TCG=1`. **CI does not set that.**
The update group is four boots; under emulation it would exceed the 6-hour job limit and prove nothing.

#### How to run the probe

```
workflow_dispatch          static / boot / update as booleans, plus a profile
push to probe/**           static + boot
push to probe-update/**    the update group alone (it is long; do not make it share a run)
```

It builds `FROM` the digest in `base.lock` plus one marker file — the same trivial derivative
`probe-boot.yml` uses, and no `ostree container commit` (D20) — and drives `matrix/run.sh` with
build.yml's exact command lines. Two knobs exist, **for the probe only, and `build.yml` must not set
either**: `AUROS_AGENT_DEADLINE` (default 2400s per boot, probe uses 420) and
`AUROS_DEADLINE_DIVISOR` (probe uses 6). Both shorten the *waiting* and never the *conclusion* — any
check that fails on a shortened deadline carries a sentence in its own `detail` saying so, so a probe
result cannot be read as a CI one. `AUROS_RUN_DIR` makes `matrix/run.sh` keep its run directory
instead of deleting it, which is what makes the logs uploadable at all.

The boot and update phases print a per-minute heartbeat naming the size and last lines of every
serial and agent log, because GitHub serves no job log until the job ends and these phases run for
over an hour.

#### What the first execution found — 2026-09-21

`.github/workflows/probe-matrix.yml` runs all three phases against a trivial derivative of the pinned
base, with build.yml's exact command lines, so harness bugs cost a five-minute probe instead of a
fifty-minute build. Checks that fail on that image are expected; what the probe asserts is that every id
`matrix/checks.yaml` declares reaches a **verdict**.

Before the first run, the harness could not have produced a single verdict for any check, on any image:

| found | consequence |
|---|---|
| the collector matched `/\.json$/` and `JSON.parse`d whole files; every run-\*.sh writes JSON **Lines** to `checks/*.jsonl` | every phase reported "ZERO checks", wrote no fragment, exited 1 |
| `set -e` aborted `run.sh` at the phase invocation, because each run-\*.sh exits non-zero when a check fails | **no fragment on any failing run.** build.yml's `jq -e … fragments/static.json` failed with "no such file", naming no check |
| the verdict line used `require(process.argv[1])` on `--out fragments/static.json` | `Cannot find module` → the phase failed even when every check passed |
| `analyze.mjs` read `--recipe ""` as the literal string `true` | S3 failed on **every base build** with `recipe "true" resolved an EMPTY removal set` |
| the run directory was `mktemp -d` + `trap rm -rf EXIT` | every serial console, bib and QEMU log was deleted before the upload step ran |
| S6 measured `containers-storage:`, whose layers are `application/vnd.oci.image.layer.v1.tar` | 8,439,590,767 B reported as a "compressed pull size"; base.lock records the same upstream at 3,758,096,384 B |
| `sudo -E` alone: sudo replaces PATH with its secure_path | U1–U5 and R1 all failed "cosign is not installed" while the job printed `/home/runner/.cosign/cosign` |
| `base.lock`'s `UPSTREAM_PULL_SIZE_BYTES` was `3758096384` — exactly 3.5 GiB | not a measurement. The real figure, read off ghcr.io against the pinned digest with the resolver's own definition, is **3,706,306,117 B across 256 `…tar+zstd` layers**. 1.4% out, and S6 budgets against it |
| `push_as()` sent skopeo's stderr to `/dev/null` | sixteen minutes of qcow2, then U1–U5 and R1 all failed with one sentence — "could not push image A to the harness registry" — while `registry.log` ended with "Writing manifest to image destination". The push had *succeeded*; the read-back on the next line was what failed, and its message had been discarded |
| `image-probe.sh` looked for a display manager in a list of six hardcoded paths | the list matched **nothing**. This base's display manager is `/usr/bin/plasmalogin` (`display-manager.service` → `plasmalogin.service`). S9's kiosk branch would have certified "no display-manager binary" on an image that still shipped one, and `vm.sh`'s greeter regex carried a dead `sddm` alternative |
| the profile was resolved by `eval` **after** `build_qcow2` | an unknown profile id surfaced ten minutes later as `P_DISK_GB: unbound variable`, with `profile.mjs`'s own "Known: …" list swallowed |

**What the run also confirmed working**, since a probe that only finds bugs is not reporting honestly:
S1, S2, S3 and S4 pass on the derivative; the in-image probe returns 2,168 rpms and a readable
`policy.json`; and S5's measured removal closure against the pinned upstream is **exactly 0 packages in
both directions**, so the closure arithmetic does not manufacture phantom removals on an unchanged
package set.

**`build.yml` still needs three changes of its own**, and they are not harness bugs:

1. The `static` job passes no `--budget-bytes`, no `--second-digest` and no `--registry-ref`, so **S6, S7
   and S8 fail by construction** — on a perfect image, forever. S6 additionally cannot be answered at all
   from local storage, since its unit is the compressed download.
2. The `update` job must invoke the harness as `sudo -E env "PATH=$PATH" …` or cosign stays invisible to
   root, and must install `libguestfs-tools` or `virt-make-fs` is missing and R1 fails closed before
   looking at anything.
   None of this is a guess about what the checks want. `matrix/run/ci/check-matrix.yml` — the harness
   author's own reference workflow — passes `--second-digest`, `--budget-bytes` and a
   `--registry-ref` pointing at an `auros-base-staging` repository, installs `libguestfs-tools`
   alongside qemu and swtpm, and invokes the scripts **without `sudo`**. `build.yml` adopted the
   phase interface and dropped every argument the checks are evaluated from. Diff the two files.

3. `run-static.sh` records its own S1/S7/S8 verdicts while the `build` and `sign` jobs write separate
   fragments for the same three ids. The merge in `publish` concatenates without deduplicating and the
   verdict is `all(.status == "pass")`, so **the duplicate fails poison the result regardless of the
   image**. This is the S8 ordering problem in `matrix/run/README.md`, now with a measured consequence.

### `tools/gate.mjs` — the publish gate (TASKS 0.5, meta repo)

```
node meta/tools/gate.mjs record --results results.json --ledger meta/attest/passed-digests.tsv --checks matrix/checks.yaml
node meta/tools/gate.mjs check  --digest <sha256:…> --results results.json --ledger … --checks …
```

`record` appends a row only if it recomputes a pass. `check` exits 0 only if the ledger has a pass for
that exact digest under the current `matrix_version`. Non-zero, missing, or throwing all stop the
publish.

**If the real CLI differs, `build.yml` is what must change — not the gate.** Two of these flags are
guesses and the gate is not.

### `Containerfile` (TASKS A1)

Either convention works and `resolve-upstream.sh assert` accepts both:

```dockerfile
FROM ghcr.io/ublue-os/aurora@sha256:…
# or
ARG BASE_IMAGE=ghcr.io/ublue-os/aurora@sha256:…
FROM ${BASE_IMAGE}
```

CI always passes `--build-arg BASE_IMAGE=<locked ref>`; an unused build arg is a warning, not an error.
A tag-only `FROM`, or an `ARG` defaulted to a tag, fails S1 — the default has to be digest-pinned too,
or S1 becomes vacuous and anyone building the file by hand gets whatever the tag meant that day.

Per **D21**, `FROM` should point at `ghcr.io/aarohkandy/auros-upstream-mirror@<same digest>`.
`skopeo copy --all` preserves the manifest digest, so the mirror is the same bytes under a name we
control. The mirror is populated by `build.yml` on every publishable run whether or not `FROM` uses it
yet, so flipping the `FROM` line is a one-line change with nothing else to coordinate. Until it is
flipped, `plan` emits a warning rather than failing — A1 owns that file, not CI.

### Mirroring (D21) is `tools/mirror-upstream.sh`, not this workflow

`build.yml` calls it and does not reimplement it. It landed purpose-built while these workflows were
being written; `resolve-upstream.sh` only *recognises* a `FROM` line pointing at the mirror, for S1.
Its env var is `AUROS_MIRROR` (not `AUROS_MIRROR_IMAGE`, which is `resolve-upstream.sh`'s).

### Flattening (D11) currently lives in `build.yml`, not the Containerfile

`rpm-ostree compose build-chunked-oci --bootc` runs as a CI step, because it is a *publish* step and
publishing is CI's job. If TASKS A6 lands it in the build scripts instead, delete the step here — do not
let both exist. **Open interface question; settle it before A6 merges.**

---

## 9. What is unproven

None of this has run. Written on 2026-09-20; nothing below has a run ID.

**Unproven, and load-bearing:**

- That `rpm-ostree compose build-chunked-oci --bootc --from … --output containers-storage:…` works with
  those flags on this base. If the flags differ, **every build fails** until it is fixed. That is
  deliberate — publishing an unflattened image would make the product's central claim ("we removed 214
  packages") true on disk and false on the wire, which is the one thing D2 exists to prevent.
- That `cosign v3.1.3` still accepts `--new-bundle-format=false`. The flag is deprecated upstream
  ("this will be the only supported format in future versions"). The step checks `--help` and warns
  rather than dying if it has gone, and **S8 is what catches the consequence**.
- That S7 is actually green — i.e. that two builds of this Containerfile produce identical `diff_ids`.
  RPM database ordering has historically not been deterministic. If it is not, S7 blocks every publish
  and the honest options are to fix the source of the variance or to amend `checks.yaml` in
  `DECISIONS.md`. **Do not weaken it quietly.**
- That a `gate1-exit` VM reaches SSH at all. `probe-boot.yml` got as far as a qcow2; the login prompt is
  still under test (GATE.md).
- That `tools/gate.mjs` accepts the flags in §8. **It does not exist yet** — `tools/` in the meta repo
  holds `compat-lint.mjs` and `honesty-gate.mjs` only. `plan` fails the build until it lands, which is
  the correct behaviour: an image that cannot be gated must not exist. `matrix/run.sh` **does** exist and
  its interface is verified.

**Blocked outright, today:**

- `signing/keys/auros.pub` does not exist, and `build/30-update-agent.sh` fails the build without it.
  **No build can currently succeed.** That is by design (`signing/keys/README.md`) and it is a §9-reserved
  human action, not something to work around.
- `tools/gate.mjs` does not exist in the meta repo. `plan` fails early and loudly.

**Known to be false, and handled:**

- The default `GITHUB_TOKEN` cannot dispatch to `auros-recipes` (D18). Handled by falling back to the
  `*/10` poll and saying so.
- A daily `uupd.timer` cannot satisfy a 20-minute propagation claim (D22). Handled by reporting **NOT
  PROVEN** instead of quietly substituting a surrogate.

**Out of scope for any of this, permanently:** everything in `matrix/profiles.yaml` →
`not_provable_in_vm`. A full green matrix means the software is sound. It does not mean a particular
2013 ThinkPad works, and a green CI badge must never be read as if it did.

---

## Unit tests — the layer underneath the check matrix

`bash tests/run-all.sh` · `bash tests/prove-red.sh` · CI: `.github/workflows/unit-tests.yml`

The check matrix costs ~40 minutes, 8.4 GB and a KVM runner, so it cannot run on every edit. These
run in seconds on a laptop with nothing but bash, sed, grep, awk, coreutils and python3 — no podman,
no QEMU, no registry.

**They prove a different thing and it is worth being precise about which.** The matrix proves a real
machine does the real thing (U1–U5, B1–B12). These prove that the assertions deciding whether an
image ships are **capable of saying no**. That is not a hypothetical distinction here: the SELinux
kernel-argument check in `build/10-hardening.sh` was permanently RED for part of a day and then
permanently GREEN for an hour, and in neither state was anything wrong with the image.

| suite | covers |
|---|---|
| `tests/00-common.test.sh` | the preflight: digest mismatch, malformed digest, absent lockfile, D21's mirror-vs-upstream FROM rule, `mask_unit` |
| `tests/10-hardening.test.sh` | SELinux config and kernel state, sshd masked-not-disabled, firewalld default-deny, the NOPASSWD ordering rule, every `telemetry.tsv` unit-mask row |
| `tests/20-policy.test.sh` | the **B5 lint** — a static scan for any mode asserting a restriction by reading a file — plus the mode stamp and the payload's permissions |
| `tests/30-update-agent.test.sh` | greenboot's capability map, the GRUB boot counter, `MAX_BOOT_ATTEMPTS`, and **every required.d health check driven into every failure branch it has** |
| `tests/40-windows-feel.test.sh` | double-click (group-aware), Discover's backends on disk, the Flathub key pin, the taskbar layout, the first-run stamps |
| `tests/90-cleanup.test.sh` | the protected set per kind, the build context, baked machine identity, `/var/log`, determinism |
| `tests/kargs-check.test.sh` | the SELinux kernel-argument check, 24 cases, both directions |
| `policy/tests/`, `desktop/tests/`, `update-agent/tests/` | the policy primitives, B12 per mode, the update agent |

### Two rules the harness enforces mechanically

**The direction audit.** `tests/lib/harness.sh` records whether each check id has been seen going
green *and* going red, and fails the suite for any check observed in only one direction. Exempting
one requires `t_exempt <id> <reason>`, and the reason is printed in the run output.

**Never copy the code under test.** Every block is extracted from the shipping script at run time
with `extract_fn` / `extract_between`, which abort the whole suite on an empty extraction or on a
block that does not parse. A sed range that quietly matches nothing yields an empty program, and an
empty program passes every input — the permanently-green bug, one level up, inside the thing meant to
catch it.

### `prove-red.sh`

27 mutations, each reintroducing a specific bug into a scratch copy and requiring the suite that owns
it to go red *for the stated reason*. A suite that stays green with its bug put back is decoration,
and this is the only thing that can tell the difference. Run one with
`bash tests/prove-red.sh "<substring of the label>"`.

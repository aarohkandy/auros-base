# Signing, and signature enforcement that is not theatre

Spec §3: *an unsigned or untested image can never reach a customer.* Enforced mechanically, not by
convention.

This directory contains the mechanism. It also contains one finding that **contradicts the plan
this work was handed**, in a way that would have shipped a product where signing appeared to work
and did not. That finding is first, because everything else depends on it.

---

## 0. NOTHING IN THIS DIRECTORY HAS BEEN MEASURED. Read this before quoting any of it.

`signing/keys/auros.pub` **does not exist**. The directory contains `.gitkeep` and `README.md`:

```
$ ls -la auros-base/signing/keys/
-rw-r--r--  0 .gitkeep
-rw-r--r--  ... README.md
```

`build/30-update-agent.sh` does `[ -s "$KEY_SRC" ] || die`, which is correct and fail-closed — and
which means **the base image build dies at step 30 and no Auros image has ever been produced.**

The consequence for every claim on this page, stated so nobody has to infer it:

| Claim | Status |
|---|---|
| the key ships at `/usr/lib/pki/containers/auros.pub` | **never built** |
| `policy.json`'s `keyPath` points at it and the scoped entry beats the catch-all | **never built, never booted** |
| `registries.d` makes the `sigstoreSigned` rule non-inert | **never built, never booted** |
| `30-auros.toml` sets `enforce-container-sigpolicy` at install time | **never installed** |
| check **U4** — an unsigned image in our namespace is refused | **has never run, not once** |
| `verify-enforcement.sh` proves the chain end to end | **has never run against a real image** |

The chain was traced by reading the files and it is correct **as written**: the scope derivation in
`build/30-update-agent.sh` yields `ghcr.io/<org>` from `AUROS_SOURCE_REPO`; `containers/image`
resolves docker scopes most-specific-first, so `ghcr.io/<org>` beats the `""` catch-all regardless
of key order in the JSON; and the build-time validator genuinely checks `keyPath`, `signedIdentity`
and the absence of a global-default catch-all — it was exercised against six mutated policies and
went red on three of them.

**Correct on paper is not evidence.** `bootc switch --enforce-container-sigpolicy` against an
unsigned `ghcr.io/<org>` image *should* fail per these files, and **no measurement in this
repository demonstrates that it does.** Until it has, this directory describes a design, not a
property, and no website copy, GATE.md row or customer sentence may say otherwise.

### What makes it measurable

One §9-reserved human action — it mints a long-lived organisational credential, which is not an
agent's decision (spec §9, and `signing/keys/README.md`):

1. `cosign generate-key-pair`
2. commit `auros-base/signing/keys/auros.pub`
3. set `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` as repository secrets

The second credential the pipeline now needs is `AUROS_DISPATCH_TOKEN` (D18, BLOCKED.md B2): the
publish gate reads the ledger from a fresh clone of the control repo, so a pass that cannot be
pushed there is a pass no gate will see, and `build.yml`'s `record` job fails rather than letting
the publish proceed on evidence nobody can re-read.

---

## 1. Keyless via Actions OIDC does not work for our consumer. We sign with a key pair.

The task, PLAN.md §A5 and D17 all describe **cosign keyless via GitHub Actions OIDC**. Read
directly on 2026-09-20, that cannot be verified by the machines we sell:

**`containers/image` matches Fulcio certificate identities against e-mail SANs only.**
`signature/fulcio_cert.go`:

```go
// == Validate the OIDC subject
if !slices.Contains(untrustedCertificate.EmailAddresses, f.subjectEmail) {
        return nil, internal.NewInvalidSignatureError(...)
}
// FIXME: Match more subject types? Cosign does:
// - .URIs (CAN be issued by Fulcio)
// - OtherName values in SAN (CAN be issued by Fulcio)
```

And `containers-policy.json(5)` makes it mandatory, not optional:

> If `fulcio` is present … **Both `oidcIssuer` and `subjectEmail` are mandatory**, exactly
> specifying the expected identity provider, and the identity of the user obtaining the Fulcio
> certificate.

A GitHub Actions workflow identity is a **URI** SAN
(`https://github.com/<org>/<repo>/.github/workflows/<file>@<ref>`), never an e-mail. There is no
value of `subjectEmail` that matches it. So a `fulcio` policy block **cannot express our CI
identity**, and `containers/image` — which is what podman and bootc use on the customer's laptop —
cannot verify a keyless, Actions-signed image at all.

This is the same *shape* of failure as D8 and D17, and it is the third one in a row: **the thing
that verifies in CI is not the thing that verifies on the laptop.** `cosign verify` would be green
the entire time.

**Therefore: we sign with a cosign key pair (`keyPath`), and `policy.json` uses `keyPath`, not
`fulcio`.** This is also why `ublue-os` ships a `cosign.pub` in its image template rather than
using keyless — worth knowing that the ecosystem already walked into this.

> ⚠ **This needs an amendment in `DECISIONS.md`.** That file is not ours to write. The substance
> is: *D8's requirement stands unchanged; the signing method changes from keyless to a cosign key
> pair, because `containers/image` cannot match a URI SAN and a GitHub Actions OIDC identity has
> no e-mail SAN.* Until that amendment exists, this README is the only place the contradiction is
> recorded.

**What we lose, stated honestly:** keyless has no long-lived secret to protect, and a transparency
log entry tied to a specific workflow run. With a key pair we hold a private key in a GitHub
Actions secret, and compromising that secret means someone can sign an image our whole fleet will
install. `keys/README.md` covers rotation, which is the part that can strand a fleet if done in
the wrong order.

**What would change this:** `containers/image` learning to match URI SANs (the `FIXME` above is
upstream's own note that it should). Track it alongside `RISKS.md` R1.

---

## 2. Why any of this is needed — D8, restated so nobody re-derives it wrongly

Deriving from Aurora gives us **nothing** here. The base `policy.json` ends in a docker
`"": [{"type":"insecureAcceptAnything"}]` catch-all, so

```
bootc switch --enforce-container-sigpolicy ghcr.io/aarohkandy/auros-base
```

**succeeds while verifying nothing.** `ublue-os/image-template`, the officially recommended path,
ships no `policy.json` and no `registries.d` entry for your own namespace.

Four things must all be true, and **each one alone looks like success**:

| | Ships as | If it is missing |
|---|---|---|
| our public key | `/usr/lib/pki/containers/auros.pub` | policy references a file that isn't there; every pull fails, forever, with no terminal to fix it from |
| `use-sigstore-attachments: true` for our scope | `/etc/containers/registries.d/auros.yaml` | `containers/image` never *looks* for a signature — it behaves as if none exists |
| a **scoped** `sigstoreSigned` rule that beats the catch-all | `/etc/containers/policy.json` | the catch-all wins and enforcement is theatre — **this is D8 itself** |
| install-time enforcement | `/usr/lib/bootc/install/30-auros.toml` | bootc records the deployment as signature mode `insecure` and **ignores `policy.json` entirely**, however correct it looks |

That last row is the one with no external symptom at all. `bootc status --json` reports it at
`.status.booted.image.image.signature` — `containerPolicy` (good) or `insecure` (nothing is being
verified). `verify-enforcement.sh` aborts as INCONCLUSIVE if it is not `containerPolicy`, because
every other result would be meaningless.

Scope precedence and the deliberate retention of the catch-all are explained in
`policy.json.README.md`. Short version: the scoped entry wins by **specificity**, not by
position, and `transports.docker[""]` stays so that distrobox and every other legitimate image
still work.

**The residual, because it is easy to overstate what this buys.** The catch-all means signature
enforcement applies to *our namespace and nothing else*. `bootc switch docker.io/anything` on a
shipped machine is accepted unsigned; `"default": [{"type":"reject"}]` never answers, because the
docker transport's own `""` entry is more specific than the global default. `open` policy mode
leaves the user with sudo, so this is reachable. The claim we are entitled to make is
**"nobody but us can update this machine from our own namespace"** — not "this machine refuses
tampered images", and not "only we can update it". `policy.json.README.md` carries the full
wording; any copy on the website has to match it.

---

## 3. `--new-bundle-format=false`, and why cosign is pinned to **v2.6.5**

`cosign.lock` pins `COSIGN_VERSION=v2.6.5`.

`containers/image` cannot read new-format OCI 1.1 referrer bundles. The issue that would fix that
— **`containers/container-libs#388`, "Support Sigstore bundle format"** — has been **open since
2025-10-12**, last touched 2026-05-25, 7 comments, no fix (checked 2026-09-20). Meanwhile
`cosign verify` reads the new format perfectly well.

So the failure mode is: **CI goes green, the customer's laptop finds no signature at all.** Silent.
That is why check **S8** requires *both* `cosign verify` passing *and* `skopeo` finding the legacy
`.sig` tag on the registry. A green `cosign verify` is not evidence that a customer can verify us.

Measured by reading `cmd/cosign/cli/options/sign.go` at each tag on 2026-09-20:

| | `--new-bundle-format` default | deprecated? |
|---|---|---|
| cosign **v3.1.3** (2026-08-06) | `true` | **yes** — *"this will be the only supported format in future versions"* |
| cosign **v2.6.5** (2026-08-06) | `false` | no |

Both are current; they were released the same day. **We pin the 2.6 line** because there the format
our customers can actually read is the *default*, not an override we are one forgotten flag away
from losing. We still pass `--new-bundle-format=false` explicitly — belt and braces, and it
documents the intent at the call site.

Per **D17** this is a time-boxed position, not a permanent one. See `RISKS.md` **R1**.

---

## 4. Signing in CI

`cosign.lock` is the only place a version appears. CI reads it; nothing hardcodes.

```yaml
permissions:
  contents: read
  packages: write        # publish
  # id-token: write is NOT needed: we are not using keyless (§1)

steps:
  - name: Pin cosign
    run: |
      set -euo pipefail
      . auros-base/signing/cosign.lock
      echo "COSIGN_VERSION=$COSIGN_VERSION" >> "$GITHUB_ENV"

  - uses: sigstore/cosign-installer@v4.1.2
    with:
      cosign-release: ${{ env.COSIGN_VERSION }}

  - name: Sign by digest, never by tag
    env:
      COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
      COSIGN_PASSWORD:    ${{ secrets.COSIGN_PASSWORD }}
    run: |
      set -euo pipefail
      cosign sign --yes \
        --new-bundle-format=false \
        --key env://COSIGN_PRIVATE_KEY \
        "${IMAGE}@${DIGEST}"
```

Three things in there are load-bearing:

* **Sign the digest, never the tag.** A tag can be moved after the signature is made. The check
  matrix already binds a pass to a digest for the same reason (`matrix/README.md`).
* **Sign after the matrix passes, publish after signing.** Signing an image that has not passed
  would create a correctly signed artifact that no machine should install, and the signature is
  the thing that tells a laptop it is safe.
* `cosign-installer` is pinned to a tag in `cosign.lock` too, so a compromised action release
  cannot quietly swap the binary.

### Which images U4 is offered — the harness's, not ours

`matrix/run/run-update.sh` already derives signed and unsigned variants of the **real base** and
serves them under the production reference string `ghcr.io/<org>/auros-base@sha256:…` (it maps
`ghcr.io` to a local guestfwd address and marks that registry insecure — which changes the
*transport* and not the *signature policy*). That is a better negative control than anything this
directory could invent, because it is the actual product image with the signature removed.

So `verify-enforcement.sh` takes them as arguments:

```
verify-enforcement.sh --signed REF --unsigned REF --wrongkey REF
```

Every reference must be **inside the enforced scope**, and the script refuses to run if one is
not. An unsigned image served from `10.0.2.100:5000/...` would be matched by the
`transports.docker[""]` catch-all rather than by our rule, so refusing it would prove nothing at
all. `run-update.sh` documents that trap at the top of the file; this script asserts it rather
than assuming it.

### `canary/` — the standalone fallback, not the preferred path

`canary/` builds a `FROM scratch` image of a few hundred bytes for running this check **outside**
the matrix, when no harness refs are available. CI need not build it if the harness supplies refs.
If it is built, it is pushed to `<registry>/<org>/auros-canary` as `:signed`, `:unsigned` and
`:wrongkey`, and:

* it must be **inside** the enforced namespace — refusing an image from outside our scope proves
  nothing about our images;
* it must never appear in a recipe's `FROM` line. It lives in `auros-canary`, not `auros-base`,
  and carries `org.auros.never-use-as-base=true`.

`:unsigned` is not a violation of *"an unsigned image can never reach a customer"* — it is not a
product image, it cannot boot, and no recipe can reach it. It is the only way to prove the lock is
locked.

---

## 5. `verify-enforcement.sh` — check U4

> **A test that would pass vacuously is worse than no test.**

"We offered it a bad image and it said no" is *also* what a completely broken machine says. It is
what you get if the public key is missing, if `signedIdentity` is wrong, if `registries.d` never
enabled attachments, if the registry is unreachable, or if `policy.json` does not parse. Every one
of those makes the machine refuse the **good** image too — and every one produces a green U4 if U4
only tests the negative.

So the script is ordered: preconditions → **positive control** → negatives → the real thing.

| | |
|---|---|
| **0** | root, `bootc`, `python3`, a policy-applying puller; key is a real PEM; `policy.json` has no unknown keys, a non-insecure default, a scoped `sigstoreSigned` rule with `matchRepository`; `registries.d` enables attachments for exactly our scope with nothing more specific overriding it; **booted signature mode is `containerPolicy`**; canary is inside the enforced scope |
| **1** | **positive control** — the signed image must be **accepted** |
| **2** | the unsigned image, *inside our namespace*, must be **refused** — this is the D8 test: if the catch-all were winning it would be accepted |
| **3** | the wrong-key image must be **refused** — proves the machine checks *which* key, not merely that a signature exists |
| **4** | `bootc switch` to the unsigned image exits non-zero, the **booted digest is unchanged**, and **nothing was left staged** |

**Exit codes: `0` pass, `1` fail, `2` INCONCLUSIVE.** A failed precondition or a failed positive
control is **2, never 0**. The gate must treat 2 as a failure — `matrix/README.md` already
establishes that a skip is not a pass, and this is the same rule.

Step 4 mutates a real machine, so it is gated on `/run/auros-check-matrix` (created by the
harness) or `--i-am-a-disposable-test-vm`. Without either it exits **2 with a loud message** — it
does **not** silently skip, because a check that skips itself is the exact failure this file
exists to prevent.

The same rule applies to step 3. If no `--wrongkey` reference is offered, the script reports
**inconclusive, not pass** — even though steps 1, 2 and 4 all passed. Step 2 only proves the
machine wants *a* signature; without step 3, a policy that accepted any valid sigstore signature
would look identical, and anyone able to sign anything could push an update to the fleet.
`gate1-exit.yml` covers that case from the host side as **U4b**; if that is where it is being
proven, this step still reports rather than quietly disappearing.

This script is a **complement to** the host-side U4 in `run-update.sh`, not a replacement. It adds
the thing the host cannot see: `run-update.sh` scores U4 a *failure* when the booted digest is
unchanged but "nothing in the console says the image was rejected for its SIGNATURE", because an
update that failed on a slow registry looks identical to one refused on policy. Running from
inside the guest, this script captures the policy engine's own refusal text and asserts the
configuration that produced it.

The script is installed at `/usr/libexec/auros/verify-enforcement.sh`, with the scope and canary
repository written to `/etc/auros/signing/` at build time — so the check runs on the machine it is
a claim about, not against a description of it.

---

## 6. What this layer still cannot promise

* **Root can turn it off.** `/etc/containers/policy.json` is editable by root on the machine, and
  `/etc` is three-way merged on upgrade, so a local edit persists. This stops a *remote attacker
  or a compromised registry*, not the machine's owner. Nothing in a bootc image can do otherwise,
  and we should not imply it does.
* **Secure Boot is a separate property.** Signature enforcement is about the container image, not
  the boot chain. See `matrix/profiles.yaml` → `uefi-secureboot`.
* **The key pair is a secret we now hold.** See `keys/README.md`, particularly the rotation order
  — getting it wrong strands every machine that has not updated yet, with no way in.

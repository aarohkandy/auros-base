# Signing, and signature enforcement that is not theatre

Spec §3: *an unsigned or untested image can never reach a customer.* Enforced mechanically, not by
convention.

This directory contains the mechanism. It also contains one finding that **contradicts the plan
this work was handed**, in a way that would have shipped a product where signing appeared to work
and did not. That finding is first, because everything else depends on it.

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

### The canary images — check U4's negative controls

`canary/` builds a `FROM scratch` image of a few hundred bytes and CI pushes it to
`<registry>/<org>/auros-canary` under three tags:

| tag | signed with | must be |
|---|---|---|
| `:signed` | the production key | **ACCEPTED** — the positive control |
| `:unsigned` | nothing | **REFUSED** |
| `:wrongkey` | a throwaway key generated during the run | **REFUSED** |

It lives in `auros-canary`, not `auros-base`, and it must never appear in a recipe's `FROM` line.
It is inside the enforced namespace on purpose: refusing an image from *outside* our scope would
prove nothing about our images.

`:unsigned` is not a violation of *"an unsigned image can never reach a customer"* — it is not a
product image, it cannot boot, it is labelled `org.auros.never-use-as-base=true`, and no recipe
can reach it. It is the only way to prove the lock is locked.

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
| **1** | **positive control** — `:signed` must be **accepted** |
| **2** | `:unsigned`, *inside our namespace*, must be **refused** — this is the D8 test: if the catch-all were winning it would be accepted |
| **3** | `:wrongkey` must be **refused** — proves the machine checks *which* key, not merely that a signature exists |
| **4** | `bootc switch` to `:unsigned` exits non-zero, the **booted digest is unchanged**, and **nothing was left staged** |

**Exit codes: `0` pass, `1` fail, `2` INCONCLUSIVE.** A failed precondition or a failed positive
control is **2, never 0**. The gate must treat 2 as a failure — `matrix/README.md` already
establishes that a skip is not a pass, and this is the same rule.

Step 4 mutates a real machine, so it is gated on `/run/auros-check-matrix` (created by the
harness) or `--i-am-a-disposable-test-vm`. Without either it exits **2 with a loud message** — it
does **not** silently skip, because a check that skips itself is the exact failure this file
exists to prevent. Step 3's separate existence matters too: step 2 only proves the machine wants
*a* signature; without step 3, a policy that accepted any valid sigstore signature would pass, and
anyone with a Fulcio certificate could push an update to the fleet.

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

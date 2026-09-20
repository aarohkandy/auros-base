# The check matrix

This directory is the answer to one question: **what does "passed" mean?**

Spec §4.3: *never publish an image that has not booted in a VM and passed the full check matrix. Enforce
with a CI gate that cannot be overridden by a flag.* Everything here exists to make that sentence
mechanical rather than aspirational.

## The shape

| File | What it is |
|---|---|
| `checks.yaml` | 28 binary checks in four groups: static (image), boot (QEMU), update/rollback, restore. |
| `profiles.yaml` | The QEMU machine definitions a recipe can bind to, and — as importantly — what each one *cannot* prove. |
| `results.schema.json` | The shape the harness emits, keyed by digest. `tools/gate.mjs` reads it and fails closed. |

## Three properties that are easy to lose and expensive to lose

**A pass is bound to a digest, never to a tag.** A tag can be moved after the test passed, which would let
an untested image inherit a passing record. The ledger stores `sha256:…` and the gate compares the whole
string.

**`skip` is not `pass`.** A skipped required check counts as a failure. This is the single most common way
a test suite quietly stops testing anything.

**The harness's own `verdict` field is ignored.** `tools/gate.mjs` recomputes the verdict from the checks
array, because a field that says `"pass"` is exactly what a broken or malicious harness would write.

## Bumping `matrix_version` invalidates history

A pass recorded under an older, weaker matrix is not evidence of a pass under this one. When you add a
check or tighten a criterion, bump `matrix_version` in `checks.yaml`; every previously recorded pass stops
counting and images must re-qualify. That is the intended cost — it is what stops the matrix from decaying
into a formality.

## The checks that exist because something specific went wrong

Most of these are ordinary. Four are not, and the reasoning is worth keeping:

- **S3 (prune assertions)** exists because the base is rebuilt nightly against upstream, and upstream can
  re-add a dependency that drags a removed package back in. Without S3, a kiosk image ships with a desktop
  inside it and nobody notices until a customer does. Some mornings S3 will be red through no fault of
  ours. **That is correct behaviour and must not be retried away.**

- **S8 (signature discoverable)** requires both `cosign verify` *and* `skopeo` finding the legacy `.sig`
  tag. cosign 3.x defaults to new-format OCI 1.1 referrer bundles that `containers/image` cannot see, so
  `cosign verify` keeps passing while the laptop that has to install the image cannot find a signature at
  all. The failure is silent. A green `cosign verify` is not sufficient evidence.

- **U3 (automatic rollback)** exists because a school has one overworked IT person and no out-of-band
  console. An update that bricks a machine is not recoverable by the customer, so it has to be recoverable
  by the machine.

- **B12 (zero-terminal audit)** exists because of the product directive (D4). If installing an app,
  joining Wi-Fi, adding a printer or changing the language requires a command line, then "feel like
  personalized Windows" is marketing rather than a property of the thing we shipped.

## What this matrix cannot tell you

Everything in `profiles.yaml → not_provable_in_vm`: real Wi-Fi association, trackpad gestures, brightness
keys, true firmware suspend, webcam, battery, GPU acceleration on GMA-era hardware, and whether a vendor's
firmware honours `BootNext`.

Those are physical-only, they live in `hardware/compat.tsv` with `source=physical`, and **no customer
quote is ever generated from a `vm` row.** A full green matrix means the software is sound. It does not
mean a particular 2013 ThinkPad works, and we must never let a green matrix be read as if it did.

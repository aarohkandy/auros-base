# auros-development.pub — a DEVELOPMENT key. Never a customer key.

**Fingerprint (SHA-256 of the DER public key):** `1495cbe4f1a3fc46c082c34098fa3d0b04c6c35ce3c8381f87f04ee08202500b`
**Generated:** 2026-09-20, by the build agent, with `openssl ecparam -name prime256v1`.

## What this is for

`build/30-update-agent.sh` refuses to build without a public key, and it is right to: an image whose
policy references a key that is not present would **refuse every update for the rest of that machine's
life** — in a school, months later, with no terminal and no out-of-band console.

That refusal blocked Gate 1, which asks only that the base *builds in CI and boots in a VM*. Building
and booting do not require a key anyone trusts; they require a key that **exists**, so the image is
internally coherent and the signature machinery can be exercised end to end.

So this key exists to make the image coherent under test. It is **not** a key any customer should ever
trust, and the build enforces that rather than relying on this file being read:

| With a development key | With a production key |
|---|---|
| build ✓ · boot ✓ · check matrix ✓ · sign a staged image ✓ · verify it ✓ | all of that |
| **publish to a customer-facing tag ✗ — refused** | publish ✓ |

## Before a single customer machine exists

A production key is a **human action** — it mints a long-lived organisational credential whose custody
matters more than its cryptography. See `signing/keys/README.md` and `signing/RISKS.md` R3.

Rotating away from this key costs a re-sign of everything published under it. That is cheap now, while
nothing is published, and expensive later. **Do it before the first pilot.**

## Where the private half is

In the `AUROS_DEV_SIGNING_KEY` Actions secret of this repository, and **nowhere else** — not on the
build agent's machine, not in this repo, not in any log. It is deliberately a throwaway: if it leaks,
the correct response is to generate another one and forget this ever existed, because nothing of value
is signed with it.

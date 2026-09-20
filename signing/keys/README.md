# `auros.pub` goes here, and it is deliberately not in the repo yet

`build/30-update-agent.sh` **fails the build** if `signing/keys/auros.pub` is missing. That is on
purpose and it is not a placeholder waiting to be filled in with something convenient.

## Why there is no dummy key checked in

A dummy key would make the build succeed and produce an image that looks exactly like the real
product: policy in place, registries.d in place, a public key at the documented path, every file
present. It would verify signatures against a key nobody holds, so it would refuse every update
forever — and it would refuse them at 3 a.m. on a machine in a school, months after anyone
remembers there was a placeholder. The build failing loudly today is cheaper than that by an
enormous margin.

Fail-closed is also the only honest reading of spec §3: *an unsigned or untested image can never
reach a customer*. A build that cannot verify signatures should not produce an image at all.

## What needs to exist

| File | Where it lives | Who can see it |
|---|---|---|
| `auros.pub` | this directory, committed, public | everyone — it is a public key |
| `auros.key` | **GitHub Actions secret `COSIGN_PRIVATE_KEY`** | nobody, including us, after it is set |
| key password | **GitHub Actions secret `COSIGN_PASSWORD`** | as above |

## Generating it — a human action, not an agent one

This mints a long-lived credential for the organisation. It is §9-reserved territory and it is
not something to do from an agent session.

```
cosign generate-key-pair                 # writes cosign.pub and cosign.key
mv cosign.pub auros-base/signing/keys/auros.pub
gh secret set COSIGN_PRIVATE_KEY --repo aarohkandy/auros-base < cosign.key
gh secret set COSIGN_PASSWORD    --repo aarohkandy/auros-base
shred -u cosign.key
```

Pin cosign to the version in `../cosign.lock` before running that.

## Rotation

Rotating this key is **not** a CI change. A machine in the field verifies against the key that is
baked into the image it is currently running, so a new key only takes effect once a machine has
already installed an image containing it.

The only safe order is:

1. Add the new key beside the old one and sign with **both** (`keyPaths` accepts a list — the
   policy's `keyPath` becomes `keyPaths: [old, new]`).
2. Wait until the fleet has taken an update containing both. Confirm from the console, not from
   an assumption.
3. Drop the old key from the policy, keep signing with the new one only.

Skipping step 2 strands every machine that has not updated yet: it will refuse the image that
would have taught it the new key, and there is no way in for anyone without physical access. That
is the single worst outcome this whole layer exists to prevent, and it is reachable by one
impatient commit.

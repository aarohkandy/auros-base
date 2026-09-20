# Tracked risks — signing and the update path

Owned by this directory. Each entry has a trigger that would make it real, a detection mechanism
that is a *check* rather than a hope, and what we do when it fires.

> These are risks, not blockers: none of them stops work today. **R1 and R2 belong in the repo's
> `BLOCKED.md` / `DECISIONS.md` as well** — those files are another agent's to write, so the text
> is here in a form that can be lifted verbatim.

---

## R1 — cosign may drop the format our customers can read · OPEN · D17

**The situation.** `containers/image` cannot read new-format OCI 1.1 referrer bundles.
`containers/container-libs#388` — the fix — has been **open since 2025-10-12**, last activity
2026-05-25, no fix (checked 2026-09-20). Meanwhile cosign's `--new-bundle-format` is **deprecated
upstream**: *"this will be the only supported format in future versions."*

If cosign removes the old format before #388 lands, every signature we make becomes invisible to
podman and bootc, and there is **no workaround** — not a flag, not a downgrade path for machines
already in the field.

**Why it is quiet.** `cosign verify` reads the new format perfectly. CI stays green while the
customer's laptop finds no signature at all.

**Position.** Pinned to **cosign v2.6.5**, where the legacy format is the *default* and the flag is
not deprecated — rather than v3.1.3, where it is both. We still pass `--new-bundle-format=false`
explicitly. `cosign.lock` is the only place the version appears.

**Detection.** Check **S8** — `cosign verify` passing **and** `skopeo` finding the legacy `.sig`
tag. Both halves required, because the first alone passed throughout the cosign 3.x breakage.

**Review trigger.** Any of: #388 closes; cosign v2.6.x goes end-of-life; S8 goes red. A pin is not
a fix, it is a clock.

---

## R2 — keyless via Actions OIDC is not verifiable by our consumer · OPEN · amends D17/PLAN §A5

**The finding.** `containers/image` matches Fulcio identities against **e-mail SANs only**
(`signature/fulcio_cert.go`), and `containers-policy.json(5)` makes `subjectEmail` **mandatory**
inside a `fulcio` block. A GitHub Actions workflow identity is a **URI** SAN. No value of
`subjectEmail` matches it, so a keyless, Actions-signed image cannot be verified by podman or
bootc on a customer's machine.

**Consequence.** We sign with a **cosign key pair**, and `policy.json` uses `keyPath`. Documented
in `README.md` §1.

**What this costs.** We now hold a long-lived private key in a GitHub Actions secret. Compromise of
that secret means someone can sign an image the whole fleet installs. Keyless had no such secret.

**Needs a human decision:** an amendment in `DECISIONS.md` recording the method change, and the key
generation itself (`keys/README.md`) — minting an organisational credential is §9 territory.

**Review trigger.** `containers/image` learning to match URI SANs. Upstream's own `FIXME` says it
should.

---

## R3 — the build cannot complete until the key pair exists · OPEN · blocks the first base build

`build/30-update-agent.sh` **fails** if `signing/keys/auros.pub` is absent. Deliberate: an image
built without it would reference a key that isn't there and refuse every update for the rest of
the machine's life, in a school, months later, with no terminal.

**Needs the human** to run `cosign generate-key-pair` (pinned version), commit `auros.pub`, and set
`COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` as repository secrets. Procedure in `keys/README.md`.

**No workaround, and none should be invented.** A placeholder key is the failure mode this fail-
closed behaviour exists to prevent.

---

## R4 — key rotation can strand a fleet · OPEN · permanent operational hazard

A machine verifies against the key baked into the image it is **currently running**. Publish an
image signed only by a new key and every machine that has not yet updated will refuse the very
image that would have taught it that key. There is no way in without physical access.

**Mitigation.** The three-step order in `keys/README.md`: ship both keys (`keyPaths` accepts a
list), wait for the fleet to take it — confirmed from the console, not assumed — then drop the old
one. **Step 2 is the one that gets skipped**, and skipping it is unrecoverable at fleet scale.

**Detection.** Nothing in CI can catch this; it is a property of the fleet, not the image. It
belongs to the console (spec §6E) when that exists. Until then it is procedure, which is weaker,
and saying so is part of the mitigation.

---

## R5 — greenboot's rollback is wired at install time, and can be absent without any symptom · OPEN

Greenboot's boot counter lives in `/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg`, which
**bootupd concatenates into `/boot/grub2/grub.cfg` when the machine is installed**. A machine
installed before greenboot entered the image has every greenboot file, every unit enabled, a green
boot status — and no `boot_counter` in GRUB. Auto-rollback simply does not exist on it.

D9 compounds this: on the **composefs/UKI** backend the counter is never wired at all, because
upstream has not implemented boot-loader entry counting there.

**Detection, in three places because one is not enough:**
* build time — `30-update-agent.sh` fails if the fragment is missing or if
  `ostree-finalize-staged.service` is absent (the composefs tell)
* runtime — `60-rollback-wiring.sh`, deliberately `wanted.d`: see `update-agent/README.md` for why
  making it required would turn "cannot roll back" into "reboots forever"
* pre-ship — check **U3**, end to end in a VM

**Recovery on an affected machine:** `bootupctl update`. That is a terminal command, which D4 says
is not a thing we may require of a customer — so if this is ever observed in the field it needs a
GUI path or a console action, not an instruction in an e-mail.

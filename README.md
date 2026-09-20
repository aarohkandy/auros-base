# auros-base

`ghcr.io/aarohkandy/auros-base:hardened`

The single Auros base image. Every laptop Auros ever installs boots something derived from this
repository, and derived from it by addition only.

---

## What this is

A Fedora [bootc](https://bootc-dev.github.io/bootc/) image — an operating system shipped as an OCI
container image. It derives from [Universal Blue's Aurora](https://getaurora.dev) (KDE Plasma) at a
**pinned digest**, and adds the things a machine needs in order to be safely maintained for years by
someone who is not a Linux administrator:

| Layer | What it does | Owned by |
|---|---|---|
| Pinned base | `FROM` an exact upstream digest recorded in [`base.lock`](base.lock), never a tag | `Containerfile` |
| Hardening | SELinux enforcing, sshd masked, default-deny firewall, telemetry off, sudo/polkit baseline, automatic Flatpak updates | [`build/10-hardening.sh`](build/10-hardening.sh) |
| Signature trust | Our public key, `registries.d` and a `sigstoreSigned` policy entry, **inside the image** | build step, task A5 |
| Policy modes | `open` · `managed` · `locked` · `kiosk`, each with a runtime assertion | build step, task A3 |
| Update agent | bootc update timer, greenboot health checks, automatic rollback | build step, task A4 |
| Cleanup | Nothing from the build survives; nothing non-deterministic survives | [`build/90-cleanup.sh`](build/90-cleanup.sh) |

The image is not the product. The *maintained* image is. This repository is rebuilt nightly against
upstream, and an image only reaches a customer if it passed every check in
[`matrix/checks.yaml`](matrix/checks.yaml) — which is machine-enforced, not a convention.

---

## Why there is exactly one

Not one per customer. Not one per hardware generation. Not one per policy mode. One.

The reason is the only promise that matters when you sell a fleet of 2012-era laptops to a school
with one overworked IT person: **a CVE response is one rebuild.** This image rebuilds, every customer
recipe rebuilds because it derives from it, and every machine picks the new image up on next boot.
Patching never requires touching more than one file.

A second base would end that. Two bases mean two rebuilds, then four, then a matrix nobody keeps
green, and eventually a customer running a build that quietly stopped being patched. Every pressure
to fork the base — a driver, a kernel pin, a held-back package version — is therefore answered the
same way: **a customer who needs the base forked is a customer we decline**, surfaced to a human as a
decision rather than solved by branching.

The costs of holding this line are real and are written down rather than hidden:

- The `kiosk` policy mode removes the desktop **shell** and display manager rather than building up
  from a minimal image, so a kiosk build is larger than a purpose-built one would be. We report the
  measured size, not an aspirational one. ([D12](../DECISIONS.md))
- Pruned packages would otherwise still be downloaded as bytes in a lower layer, so we flatten at
  publish with `rpm-ostree compose build-chunked-oci --bootc`. ([D2](../DECISIONS.md), [D11](../DECISIONS.md))

---

## What a customer inherits

A recipe in [`auros-recipes`](https://github.com/aarohkandy/auros-recipes) is about ten lines of YAML.
It may add packages, set locale and keyboard, choose a policy mode, apply branding, and prune. It
inherits all of the following without asking for any of it:

**Security posture**
- SELinux **enforcing**, with `selinux=1` pinned as a kernel argument so it cannot be switched off at
  the bootloader. Re-asserted at every boot by `/usr/libexec/auros/hardening-assert`; a machine whose
  SELinux went permissive reports a degraded boot instead of looking fine.
- **sshd masked**, not disabled — masking survives a stray `systemctl enable` and stops socket
  activation, which a disabled unit does not. A drop-in additionally turns off root login, password
  authentication and forwarding for the case where an administrator deliberately unmasks it.
- **firewalld default-deny inbound.** The default zone is `auros`: everything rejected except
  IPv6 address configuration and mDNS. mDNS is allowed for one stated reason — driverless printer
  discovery, which check B12 requires to work without a terminal.
- No passwordless sudo. Installing or removing system software requires an administrator password
  even from an active local session.
- Kernel pointers and the kernel ring buffer are not readable by unprivileged users; crash dumps are
  not written to disk.

**No telemetry, and an inventory rather than a claim.** The build walks
[`hardening/telemetry.tsv`](hardening/telemetry.tsv) against the actual image and prints every row as
`PRESENT` or `ABSENT` along with what it did. ABRT's reporting units are masked; Fedora's Count Me
census is turned off in every repository file that had it on, and the count printed is measured;
Plasma User Feedback is pinned to zero system-wide. Two things are named and **deliberately left
on** — `fwupd-refresh.timer`, because contacting the LVFS is the only way a firmware CVE reaches a
2013 laptop, and `geoclue2`, because Plasma's automatic timezone and night colour use it and removing
it has a visible cost. A privacy claim with a quiet exception is a false claim, so the exceptions are
in the build log.

**Maintainability**
- The previous deployment is kept on disk, and a machine that fails to reach a login prompt returns
  to it by itself. Exactly one rollback deployment is retained — not N; anything implying otherwise
  would be false. ([D10](../DECISIONS.md))
- System Flatpaks update daily, with a three-hour random delay so that 180 machines on one school
  uplink do not all update at the same instant.
- The operating system itself is not updated by a package manager. There is no `dnf-automatic` here,
  because it would be writing to a composed, read-only `/usr`: the image is replaced wholesale.

**A record of itself.** Every image carries `/usr/lib/auros/release` (what it is and what upstream
digest it came from), `/usr/lib/auros/base.lock`, `/usr/lib/auros/build-steps.tsv` (every change the
build made, sorted, no timestamps) and `/usr/lib/auros/protected.list`. You can ask a running laptop
what it is without access to this repository.

**What it does NOT inherit:** applications. Those come from Flathub via the recipe, they update
themselves, and they are explicitly not our security surface. The image owns everything that can root
the machine; Flatpaks own everything else.

---

## Verify a published image's signature yourself

You do not have to take our word for any of this, and you should not.

You need [`cosign`](https://github.com/sigstore/cosign) and
[`skopeo`](https://github.com/containers/skopeo). Both are in Fedora
(`dnf install cosign skopeo`) and Homebrew (`brew install cosign skopeo`). Nothing below needs
`podman`, root, or the image itself downloaded.

```bash
IMAGE=ghcr.io/aarohkandy/auros-base
TAG=hardened

# 1 ── Resolve the tag to a digest, and work with the digest from here on.
#      A tag can be moved after the fact; a digest cannot.
DIGEST=$(skopeo inspect --format '{{.Digest}}' "docker://$IMAGE:$TAG")
echo "$DIGEST"

# 2 ── Verify the signature. Keyless: there is no Auros private key to steal, because there is no
#      Auros private key. The signature is bound to a short-lived certificate issued to a GitHub
#      Actions workflow in THIS repository, and the identity below is what you are actually trusting.
cosign verify \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  --certificate-identity-regexp='^https://github\.com/aarohkandy/auros-base/\.github/workflows/.+@refs/heads/main$' \
  "$IMAGE@$DIGEST"

# 3 ── Verify the signature is DISCOVERABLE, which is a different question and not an academic one.
#      cosign 3.x defaults to new-format OCI 1.1 referrer bundles that containers/image cannot see.
#      A green `cosign verify` with only a new-format bundle means YOUR LAPTOP CANNOT FIND THE
#      SIGNATURE AT ALL, and that failure is silent. This is the legacy `.sig` tag that bootc and
#      podman actually look for:
skopeo inspect --raw "docker://$IMAGE:${DIGEST/:/-}.sig" > /dev/null && echo "legacy .sig tag present"

# 4 ── Check the image is built from the upstream we say it is, without cloning this repo.
skopeo inspect "docker://$IMAGE@$DIGEST" \
  | grep -E 'org.opencontainers.image.base.(name|digest)|dev.auros'
```

Step 2 and step 3 are both required. Step 2 answers "is this signature valid?" and step 3 answers
"can the machine that has to install this image find the signature?" — and it is entirely possible
for the first to be yes while the second is no. That pair is check **S8** in
[`matrix/checks.yaml`](matrix/checks.yaml), and it exists because we would rather find that out here
than in a school. ([D17](../DECISIONS.md))

**As of this commit, nothing has been published yet.** The commands above are the ones that will work
against the first published image; running them today will tell you the manifest is unknown, which is
the correct answer. The first publish happens when Gate 1 passes, and a publish is refused mechanically
for any digest without a recorded full-matrix pass.

### How a laptop enforces this on its own

Verifying by hand is the audit. The enforcement is in the image: Auros ships its own public key under
`/usr/lib/pki/containers/`, its own `/etc/containers/registries.d/` entry with
`use-sigstore-attachments: true`, and a **`sigstoreSigned`** policy entry for `ghcr.io/aarohkandy`
that is evaluated *before* any catch-all.

This is not inherited from upstream and it is the single most load-bearing correction in the project.
Aurora's `policy.json` ends with an `insecureAcceptAnything` catch-all, so
`bootc switch --enforce-container-sigpolicy` against a derived image **succeeds while verifying
nothing**. Enforcement that verifies nothing is worse than no enforcement, because it produces a green
result. Check **U4** — offer the machine a wrongly-signed image and require that `bootc upgrade` exits
non-zero and the booted digest is unchanged — is what proves the policy is real. ([D8](../DECISIONS.md))

You can read the policy off any running Auros machine:

```bash
cat /etc/containers/policy.json
bootc status --json | grep -i image
```

---

## Build it yourself

This is a feature we advertise rather than a footnote. If Auros vanishes, a customer rebuilds their
exact operating system from public files.

```bash
git clone https://github.com/aarohkandy/auros-base
cd auros-base
podman build -t localhost/auros-base:hardened -f Containerfile .
```

Requires Linux with `podman` (a container build cannot produce a Fedora root filesystem from macOS or
Windows). The build prints, step by step, exactly what it changed — that output is not decoration, it
is the same stream the website's build console shows, and it is generated by measuring the image
rather than by echoing intentions.

---

## Repository conventions

`Containerfile` copies the build context to `/tmp/auros-build` and runs `build/*.sh` in **numeric
order** inside the image build. Every script:

- sets `-euo pipefail` and sources `build/00-common.sh`,
- is **idempotent** — running the whole build twice over one filesystem must produce one filesystem,
  because check S7 builds twice and compares content digests,
- **echoes what it did**, after doing it. That output is shipped to customers; it has to be true.

A step's data files live either in `build/<nn>-<name>.d/` (copied automatically — prefer this) or in
a top-level directory, which needs its own `COPY` line in the `Containerfile`. `build/00-common.sh`
prints which data directories each step can actually see, so a missing `COPY` appears as a named line
in the build log.

| Path | Purpose |
|---|---|
| `Containerfile` | Pinned `FROM`, the build-script runner, `ostree container commit`, OCI labels |
| `base.lock` | The pinned upstream digest. Resolved by CI, **never edited by hand** |
| `build/00-common.sh` | Shared library (sourced) and build preflight (executed) |
| `build/10-hardening.sh` | The hardening layer |
| `build/90-cleanup.sh` | Removes build artefacts and non-determinism; asserts the protected set |
| `hardening/` | Data files for `10-hardening.sh`, one file per concern, each explaining itself |
| `matrix/` | The check matrix — the definition of "passed" |

Nothing in `build/` may remove anything in `hardening/protected.list`: bootc, the update path,
greenboot, NetworkManager, systemd. A recipe that prunes its own update path produces a machine we
can never patch again, which is precisely the abandoned laptop we sell against. `90-cleanup.sh`
asserts it at build time and check **S10** refuses to publish without it.

> **Housekeeping note for whoever adds CI:** this repository has no `.containerignore`. The
> `Containerfile` enumerates the directories it copies specifically so that `.git` and `matrix/`
> stay out of the image build, but a `.containerignore` would make that robust rather than careful.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).

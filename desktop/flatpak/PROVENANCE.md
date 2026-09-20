# flathub.flatpakrepo — provenance

| | |
|---|---|
| Source | `https://dl.flathub.org/repo/flathub.flatpakrepo` |
| Fetched | 2026-09-20 |
| Bytes | 4040 |
| sha256 | `3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a` |

The file is shipped **verbatim**, byte for byte as Flathub publishes it, and `build/40-windows-feel.sh`
re-checks that sha256 at build time before installing it. If the file in this repo is ever edited — by
anyone, for any reason — the base build fails rather than silently shipping a remote definition and a
signing key that nobody reviewed.

**Why a pinned copy and not a fetch at build time.** The GPGKey line in this file is the key Flatpak will
use to verify every application a customer ever installs. Downloading it fresh inside each nightly build
would mean the trust root of the entire application layer changes whenever the network says it does, with
no diff and no review. Pinning makes a key rotation a visible pull request.

**When Flathub rotates its key**, the correct response is: fetch the new file, commit it as a diff that a
human reads, update the sha256 above and in `build/40-windows-feel.sh`. Do not automate this.

**Installed to** `/etc/flatpak/remotes.d/flathub.flatpakrepo`. Per `flatpak-remote(5)`: *"System-wide
remotes can be statically preconfigured by dropping flatpakrepo(5) files into /usr/share/flatpak/remotes.d/
and /etc/flatpak/remotes.d/. If a file with the same name exists in both, the file under /etc will take
precedence."* This is the only mechanism that works on bootc: `flatpak remote-add` at build time would
write into `/var/lib/flatpak`, and `/var` is machine-local state that an OCI image does not carry.

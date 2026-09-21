# `desktop/` — the Windows-familiarity layer

Owned by `build/40-windows-feel.sh`. Implements TASKS.md **A10** and DECISIONS.md **D4**, and provides
the implementation of check **B12**.

D4 is a binding human directive, not a preference:

> *"make sure people can still use it, if it can run exe and feel like windows that'd be amazing but not
> completely required, make it clean end to end, make it feel like personalized windows rather than linux
> rn which needs you to memorize books of commands and stuff"*

The organising rule for everything in this directory: **a setting a user has to find is a setting that is
not set.** Nothing here is left to the user, to the installer, or to a first-boot prompt.

---

## What is here

```
desktop/
├── xdg/                         → /etc/xdg/…            system-wide KDE defaults (cascading)
│   ├── kdeglobals                  double-click, look-and-feel, animation speed
│   ├── kwinrc                      window buttons, Aero Snap, one desktop, Meta = Start
│   ├── kglobalshortcutsrc          Meta+E, Meta+D, Meta+L  (also copied to /etc/skel)
│   ├── kcminputrc  plasmarc  dolphinrc  ksmserverrc
│   ├── user-dirs.defaults          Windows folder names, and no Templates/Public
│   └── plasma-workspace/env/10-auros-flatpak-paths.sh
├── lookandfeel/org.auros.windows.desktop/
│   ├── contents/defaults           appearance defaults
│   └── contents/layouts/org.kde.plasma.desktop-layout.js   ← this file IS the taskbar
├── lookandfeel/org.auros.shelf.desktop/    alternative: browser-first, apps centred (same structure)
├── lookandfeel/org.auros.simple.desktop/   alternative: three big buttons, a menu, the clock
├── flatpak/flathub.flatpakrepo     pinned, hash-checked → /etc/flatpak/remotes.d/
├── welcome/                        first-run flow (plasma-welcome + our pages + the oneshot)
├── compat/                         the .exe capability, D16-shaped
├── skel/                           (created by the build script, not stored here)
├── assert-zero-terminal.sh         check B12 (mode-aware; reads /usr/lib/auros/policy/claims.env)
├── tests/b12-modes.test.sh         proves B12 goes red per mode, against stubs (D19)
└── EXE-COMPATIBILITY.md            the honest compatibility statement
```

---

## The four decisions worth arguing about

**1. `/etc/xdg`, not `/etc/skel`.** KConfig cascades: every KDE config file is read from
`$XDG_CONFIG_DIRS` (default `/etc/xdg`) and the user's own file is layered on top. A value in `/etc/xdg`
therefore reaches every user — *including accounts that already exist* — and keeps tracking the image as
the image is rebuilt nightly. A copy dropped in `/etc/skel` is a snapshot frozen at account-creation
time that never updates again. `/etc/skel` is used for exactly two things, both deliberate:
`kglobalshortcutsrc` (kglobalaccel does not reliably merge cascaded defaults) and a desktop icon.

**2. We match the shape, not the skin.** No Windows-alike icon theme, no fake Start orb, no XP window
decoration. Prohibition §4.2 is one reason: the closer it looks to Windows, the more every underlying
difference reads as a betrayal rather than a difference. The other is maintenance — a third-party clone
theme is an unmaintained dependency inside an image we rebuild every night, which is exactly what check
S3 exists to catch. So we match *where things are*, *what a click does*, and *what a key does*, and keep
Breeze's own appearance, which is legible and maintained by people who are not us.

**3. Discover loses its system-update button.** Removing the PackageKit and rpm-ostree backends means a
user can never be offered "install this rpm", which cannot work on an image-based OS, or `rpm-ostree`
layering, which would quietly take the machine off the image we test and sign. The cost is that Discover
no longer shows OS updates. Updates on Auros are automatic and unattended (A4), so there is nothing for
a user to press — but *"is my computer up to date?"* is a real question, and right now it is answered
only by a sentence in the orientation page. **If A4 ships a GUI status entry, the welcome page should
link it.** The fwupd backend is kept: firmware updates are not packages, they work fine here, and on
2012-2018 hardware they occasionally fix a trackpad.

**4. We use KDE's wizard rather than writing one.** `plasma-welcome` already covers language, network
and finding applications, is translated far beyond anything we could manage, and is maintained by the
people who maintain the desktop it introduces. Its README documents exactly two extension points and we
use both: `intro-customization.desktop` for the first screen's text, and numbered QML files in
`extra-pages/` for our own pages (orientation, and the honest page about Windows programs). Writing our
own would have been a second thing to keep working through a nightly rebuild.

---

## How B12 is made testable

`assert-zero-terminal.sh` is installed into the image as `/usr/libexec/auros/assert-zero-terminal` and
run **inside the booted VM, as an ordinary user, inside their graphical session**.

```
/usr/libexec/auros/assert-zero-terminal --json /tmp/b12.json
```

| exit | meaning |
|---|---|
| 0 | every assertion passed → record B12 `pass` |
| 1 | at least one failed → record B12 `fail` |
| 2 | could not be evaluated (no session, or `--no-launch`) → **not a pass**, ever |

`--json` writes the `results.schema.json` check object for `B12` (`{"id","status","detail"}`).

It asserts existence *and launch* for each of B12's four tasks, because a `.desktop` entry whose `Exec`
points at a binary a prune step removed still exists — it is a menu entry that does nothing, which to
our user is indistinguishable from a broken computer, and it is exactly what a nightly rebuild against a
moving upstream produces. "Launches" is defined mechanically: the process is started and must still be
alive six seconds later. A missing KCM, a missing binary or a plugin that fails to load all exit
immediately.

It additionally checks the things D4 asked for that B12's wording does not name: double-click as the
user's session actually resolves it, a taskbar containing a start menu and task buttons, the Windows
folder names present and `Templates`/`Public` absent, and the first-run flow being installed and enabled.

### B12 is evaluated against the recipe's policy MODE, not against `open`

B12's four tasks are written in `checks.yaml` against what an `open` image does, because the base is
an open image. Three of the four policy modes deliberately do something else, and evaluating them
against `open`'s list is not a strict test — it is an **unshippable recipe**:

| mode | install an app | Wi-Fi | printer | language |
|---|---|---|---|---|
| `open` | `seat` | `seat` | `seat` | `seat` |
| `managed` | `admin` | `admin` | `seat` | `seat` |
| `locked` | **`none`** | **`none`** | `seat` | **`none`** |
| `kiosk` | `n/a` | `n/a` | `n/a` | `n/a` |

* **`seat`** — any user at the machine, through the GUI. Asserted as before: the entry or KCM exists
  *and* launches.
* **`admin`** — the GUI offers it and asks for the administrator password. Asserted identically, and
  `pkcheck` must answer 0 or 3. **A password is not a terminal**: D4 forbids needing a command line,
  not needing a credential.
* **`none`** — `locked` removes it from the seat on purpose and tells the customer so. B12 asserts the
  **opposite**: the KDE Control Module must refuse to open, and `pkcheck` must answer **1**. This is
  not a skip — it goes red if the restriction leaks (the machine offers a door it then slams) and red
  if the restriction quietly stops being applied. It is the only runtime check that would notice
  `build/40-windows-feel.sh` rewriting `/etc/xdg/kdeglobals` after `20-policy.sh` merged the KDE
  Kiosk groups into it, which is a real ordering hazard that `20-policy.sh` warns about at build time
  and nothing else observes at run time.
* **`n/a`** — kiosk has no session. The kiosk criterion is asserted instead: `auros-kiosk.service` is
  active, an application is configured, and no desktop shell, display manager or terminal emulator
  survived the removal pass.

The criteria come from `/usr/lib/auros/policy/claims.env`, which `apply-policy` writes at build time
from `policy/<mode>/mode.env`. **A missing or unreadable claims file is exit 2, never a fall-back to
`open`** — silently auditing a locked image against open's list is how three of the four modes became
unpublishable in the first place, and silently auditing an open image against locked's list would be
worse, because it would report a pass for a machine offering none of what we sold.

`--mode <name>` overrides the stamp, for testing and for asserting that an image is *not* some other
mode.

### Proving that B12 can still go red

`tests/b12-modes.test.sh` drives the real script against stubbed `systemctl`, `kcmshell6`, `pkcheck`
and `flatpak`, and asserts both directions for each mode — including the two regressions that matter:
a `locked` image whose network settings page opens anyway, and a `kiosk` image where `konsole`
survived. It runs anywhere `bash` does and touches nothing on the host:

```
bash auros-base/desktop/tests/b12-modes.test.sh
```

---

## VERIFY — what we could not test from here, and the one command each

DECISIONS.md D5: the development machine is macOS/arm64 with no podman, no qemu and no cosign, so
**nothing in this directory has been executed.** Every line was written against documentation and
against the source of the projects concerned. These are the specific claims most likely to be wrong, in
descending order of how much they would cost, each with the command that settles it in the VM.

| | claim | how to settle it | if it is wrong |
|---|---|---|---|
| **VERIFY-1** | `plasmarc [Defaults] defaultContainmentPlugin` makes the desktop a Folder View (icons on the desktop, as on Windows) | `kreadconfig6 --file plasmarc --group Defaults --key defaultContainmentPlugin`, then look at whether `~/Desktop` contents appear | Cosmetic. Every entry it would surface is also in the start menu; the desktop icon in `/etc/skel/Desktop` is a bonus, not a dependency. |
| **VERIFY-2** | `_launch=` entries in `kglobalshortcutsrc` bind Meta+E to the file manager in Plasma 6 | press Meta+E; `kreadconfig6 --file kglobalshortcutsrc --group org.kde.dolphin.desktop --key _launch` | Loses one shortcut. Everything remains reachable from the taskbar. |
| **VERIFY-3** | the layout script produces one panel with all six widgets | `grep -c '^\[Containments\]' ~/.config/plasma-org.kde.plasma.desktop-appletsrc`; `assert-zero-terminal` covers the two that matter | **Serious.** No taskbar is the loudest possible failure of this layer. The script removes panels before creating ours, so it can be re-run by hand from the GUI. |
| **VERIFY-4** | our two QML pages render inside `plasma-welcome` | run `plasma-welcome` and look at the screen | **Not machine-checkable, and we are not pretending otherwise.** A QML syntax error would drop the page silently. This needs a human or a screenshot in the VM run. |
| **VERIFY-5** | `bottles-cli new --bottle-name X --environment application` works in the current Flatpak | `flatpak run --command=bottles-cli com.usebottles.bottles new --help` | The materialiser gives up after three attempts and leaves Bottles fully usable by hand, which is still a GUI path. |
| **VERIFY-6** | `graphical-session.target.wants` is reached in a Plasma 6 session | `systemctl --user is-active auros-first-run.service`; `~/.local/state/auros/first-run.log` | **Serious.** First-run never runs: no taskbar, no welcome. Alternative is `plasma-workspace.target`. |
| **VERIFY-7** | `plasma-print-manager` supplies a KCM named `kcm_printer_manager` | `kcmshell6 --list | grep -i print` | The audit already accepts three names and falls back to `system-config-printer`. Add the real name to `first_kcm`. |

The things that are **not** guesses, because they were read from the relevant documentation on
2026-09-20 and the package names were confirmed against `packages.fedoraproject.org`:
`/etc/flatpak/remotes.d/*.flatpakrepo` as the static system-remote mechanism (`flatpak-remote(5)`);
`intro-customization.desktop` and `extra-pages/NN-Name.qml` as plasma-welcome's two extension points
(its README); `/etc/flatpak/preinstall.d/*.preinstall` with `[Flatpak Preinstall <id>]`
(`flatpak-preinstall(1)`); and the existence of `plasma-welcome`, `plasma-discover-flatpak`,
`plasma-discover-packagekit`, `plasma-discover-rpm-ostree`, `plasma-print-manager`, `plasma-nm` and
`system-config-printer` in Fedora.

---

## Known gaps, written down rather than discovered later

- **GAP-1 — two copies of the orientation.** `welcome/extra-pages/01-AurosOrientation.qml` and
  `welcome/orientation.html` say the same things in two languages, and nothing checks that they agree.
  The HTML is the degraded path for an image without `plasma-welcome`. If they drift, the fallback is
  the one that will be stale.
- **GAP-2 — our two wizard pages are English-only.** Strings are plain literals, because `i18n()` is
  only defined when a `KLocalizedContext` is attached to the QML engine and a page that throws on load
  is worse than a page in English. This sits badly against check B4 ("in their language") and against a
  Marathi recipe in particular. It is a gap in *our two pages*; the rest of the wizard, the desktop, the
  folder names and every application are localised by their own projects.
- **GAP-3 — the mDNS port is open and nothing runs on it.** `build/10-hardening.sh` adds `mdns` to
  the default firewall zone and says in its own build log that it does so *"because check B12 requires
  that adding a printer works without a terminal"* — but no step in this build enables
  `avahi-daemon`, and driverless printer discovery is mDNS. As it stands we have neither the discovery
  nor the smaller attack surface. USB printers and printer-by-IP-address still work from the GUI.
  Enabling a network-facing daemon on every machine in a school is a hardening decision, so this layer
  does not make it: `40-windows-feel.sh` emits a `warn` naming the situation on every build, and the
  audit prints it. **Owner: whoever owns `10-hardening.sh`.**
- **GAP-4 — no GUI answer to "is my computer up to date?"** See decision 3 above. Belongs with A4.

---

## Assumptions about other people's files

Nothing in this directory writes outside `desktop/` and `build/40-windows-feel.sh`. Three conventions
are assumed, each chosen so that being wrong degrades quietly rather than breaking a build:

1. **`Containerfile` COPYs `desktop/` to `${AUROS_BUILD_DIR}/desktop/`** (`/tmp/auros-build/desktop/`)
   and runs `build/*.sh` in numeric order. If that path is wrong the script dies at the top with a
   message that says so. `40-windows-feel.sh` sources `build/00-common.sh` and goes through its
   `pkg_ensure` / `install_file` / `install_text` / `record` helpers for everything, so every file it
   writes is stamped with `SOURCE_DATE_EPOCH` and listed in the in-image manifest — check **S7**
   (determinism) fails if a step writes files any other way. The one thing it does not borrow is
   `enable_unit`, which is system-scope only; the two `systemd --user` units are enabled by a local
   `enable_user_unit` built on the same verify-the-filesystem principle. Build-time facts land in
   `/usr/lib/auros/desktop-facts.env`, with a stable symlink at `/usr/share/auros/desktop-facts.env`
   that the audit reads, and **carry no timestamp**, for the same S7 reason.
2. **A recipe with `compat_layer: true` emits a flatpak preinstall drop-in** at
   `/etc/flatpak/preinstall.d/<name>.preinstall` containing `[Flatpak Preinstall com.usebottles.bottles]`.
   This layer never writes that file. `auros-bottles-setup` checks for the app at run time and exits
   quietly when it is absent, so the capability can be switched on in a later recipe build with no
   change here.
3. **Wallpaper and branding belong to the theme layer** (`theme-generate`, the recipe's `branding:`
   block). The layout script deliberately sets no wallpaper: pointing at an image path this layer does
   not ship would hand a customer a black desktop the day the theme layer renamed a file.

---

## Re-running first-run without a terminal

If a machine reaches a user with no taskbar — VERIFY-3 or VERIFY-6 having gone wrong in the field — the
repair has to be doable by a school's IT person from the GUI, or D4 is broken at the worst possible
moment. It is: **Start menu → Help and Getting Started** reopens the wizard, and deleting
`first-run.v1.stamp` in `~/.local/state/auros/` from the file manager (Ctrl+H shows hidden folders) makes
the layout reapply at the next login. The layout script removes existing panels before building ours, so
re-running it produces one taskbar and never two.

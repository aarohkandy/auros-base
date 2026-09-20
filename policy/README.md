# Policy modes

Four ways the same image can behave: **open**, **managed**, **locked**, **kiosk**.

A customer recipe picks one. There is still exactly one base image — the modes are data inside it,
not four images. A recipe selects its mode in its own derived layer with one line:

```dockerfile
RUN /usr/libexec/auros/apply-policy locked
```

and proves it in a booted VM with one more:

```
/usr/libexec/auros/assert-policy
```

---

## Choosing between them

*(Longer versions, written for a school IT reader, are in `<mode>/description.md`. Read those with
the customer; read the table below to narrow it down first.)*

| | **open** | **managed** | **locked** | **kiosk** |
|---|---|---|---|---|
| **In one line** | A normal computer. The person using it is its administrator. | Anyone can use it. Changing it asks for the IT password, at the machine. | A full desktop that cannot be changed from the seat. | One application, full screen. There is no desktop. |
| **Who it's for** | A teacher's own laptop. The one dev desktop. | The default for a school. Classroom and library machines. | Exam rooms. Public machines. Laptops that go home. | Catalogue terminals. Reception sign-in. Corridor displays. |
| Install software | yes | IT password | **no** | **no** |
| Get root (`sudo`/`pkexec`) | yes | IT password | **no** | **no** |
| Change network config | yes | IT password | **no** | **no** |
| Stop the update timer | yes | IT password | **no** | **no** |
| Terminal present | yes | yes | yes *(KDE's doors to it are shut)* | **removed** |
| Desktop present | yes | yes | yes | **removed** |
| Login screen | yes | yes | yes | **removed** |
| Fix a machine by walking up to it | yes | yes | no — ship a new image | no — reimage it |

**The one question that settles managed vs. locked:** *where does the IT password live?* Managed's
security **is** that password. If it is on a sticky note in the staff room, managed is open with
extra steps. Locked removes the password as a mechanism at the seat entirely — nothing changes in
front of the machine, and changes reach the fleet as a new image instead.

**The one question that settles locked vs. kiosk:** *does this machine need a desktop at all?* If it
runs one application, kiosk is a smaller promise and a much stronger one, because the thing a user
would escape into is not on the disk.

---

## What each mode installs

Everything is under `<mode>/root/`, a mirror of the filesystem that `apply-policy` copies in while
recording a manifest. The manifest is what makes a mode switch *release* the previous mode rather
than layer on top of it.

| Mechanism | Path | open | managed | locked | kiosk |
|---|---|---|---|---|---|
| polkit rules | `/etc/polkit-1/rules.d/00-auros-<mode>.rules` | — | `AUTH_ADMIN` | `NO` | `NO` + default-deny for the app account |
| polkit admin identity | (same file) | default (`wheel`) | `unix-group:aurosadmin` | `unix-group:aurosadmin` | `unix-group:aurosadmin` |
| sudoers | `/etc/sudoers.d/90-auros-<mode>` | — | deny-all, re-grant root + `aurosadmin` | same, plus `timestamp_timeout=0` | same |
| PAM | `/etc/pam.d/su` | — | `pam_wheel group=aurosadmin` | same | same |
| KDE Kiosk | `/etc/xdg/kdeglobals` | — | action restrictions | + `shell_access`, URL and KCM restrictions | + everything, as defence in depth |
| dconf | `/etc/dconf/db/auros.d/` | — | lockdown + locks | same | + printing, save-to-disk, log-out |
| systemd presets | `/usr/lib/systemd/system-preset/85-auros-<mode>.preset` | — | yes | yes | yes |
| units masked | | — | `debug-shell` | `debug-shell` | + `getty@`, `serial-getty@`, `display-manager`, `sddm`, `gdm` |
| packages removed | | — | — | — | `kiosk/remove.list` |
| session | | SDDM → Plasma | SDDM → Plasma | SDDM → Plasma | `auros-kiosk.service` → cage → one app |

### The two shared files, and how they are handled

`/etc/xdg/kdeglobals` and `/etc/pam.d/su` belong to more than one build layer. The
Windows-familiarity layer (D4) owns `[KDE]` in kdeglobals — `SingleClick=false` and friends — and a
theme layer owns the colour groups.

`apply-policy` therefore **merges, never overwrites**. It owns exactly three groups
(`KDE Action Restrictions`, `KDE Control Module Restrictions`, `KDE URL Restrictions`), rewrites only
those, and leaves every other byte alone. `/etc/pam.d/su` is edited through a marker-guarded,
idempotent insertion that keeps `pam_rootok` first so root can still `su`.

A layer that clobbered kdeglobals would silently undo double-click-to-open, and the symptom would
surface a week later as *"the machines feel wrong"*, with nothing in any log. This is checked in
`open/assert.sh`, which asserts both that our groups are gone **and** that the file still exists with
its other content.

### The kdeglobals ordering hazard — confirmed, not hypothetical

`build/40-windows-feel.sh` installs `/etc/xdg/kdeglobals` **as a whole file**, and it runs at step 40,
*after* this layer at step 20. So in a base build it removes the three KDE Kiosk groups apply-policy
merged in.

**In practice this does not bite, and it is worth being precise about why:**

- The base image is `open`, which writes no KDE restriction groups at all. Nothing is lost.
- A customer recipe activates its mode in its **own derived layer**, which runs after every base
  build script including 40. Our merge then preserves `[KDE]` and `SingleClick=false` untouched — the
  direction that matters is safe, and `open/assert.sh` asserts the shared file survived.

**It does bite in one place:** building a single-mode base with `AUROS_POLICY=locked`, which is the
path this README suggests for running B5 in CI. `20-policy.sh` prints a loud warning in exactly that
case and names the fix: re-run `apply-policy` as the last step, or build the mode in a derived layer
like a recipe does.

Note what is *not* affected even then: polkit, sudoers, PAM, dconf and the unit masks all survive,
because none of them shares a file with another layer. The enforcement is intact; only the
KDE-application restrictions would be missing. That is the right way round, and it is why the
enforcement was never put in kdeglobals in the first place.

*(Owned by another task, so flagged rather than edited: `40-windows-feel.sh` merging its groups
instead of installing the file wholesale — or simply running before 20 — would remove the hazard
entirely.)*

### A note on `/etc` and ostree

Most of the above lives in `/etc`, which ostree three-way-merges on upgrade. That is what makes a
fleet-wide mode switch work: a file we shipped, that nobody edited locally, is replaced or removed to
match the new image, so shipping `open` to a `locked` fleet really does release the locks. A file an
administrator edited by hand survives. That is ostree's contract and it is the right behaviour, but
it means a hand-edited policy file on one machine is a machine that stops matching its recipe.

---

## Proving a mode, which is the part that matters

Check **B5** fails a mode that is *configured but not effective*. Every mode ships
`<mode>/assert.sh`, run inside the booted VM by `/usr/libexec/auros/assert-policy`. The rule those
scripts follow, without exception:

> **An assertion may not read a configuration file and conclude that a restriction is in force. It
> must attempt the forbidden thing and observe the attempt fail.**

For `locked`, as an unprivileged user, that means actually running: `sudo`, `pkexec`, `su`,
`systemd-run --scope`, `machinectl shell`, `rpm-ostree install`, `flatpak install --system`,
`nmcli networking off`, `nmcli connection add`, `systemctl stop/disable/mask` the update timer, and
writes to the policy files themselves. Each one is observed to fail, and the update timer is then
asked whether it is still running — because three attempts failing is not the same as the timer
surviving.

### The false-green this design exists to prevent

A denial is only evidence if the same subject could have been **allowed** something.

Most polkit actions default to `auth_admin` for a subject with no active logind session, and a probe
process started by a test harness often has no session. Such a probe is refused everything, in every
mode, **including `open`** — so a lazily written `locked` assertion passes green on an image where our
rules were never installed at all. That is a false green on the single claim a customer can disprove
by pressing a key.

Three things prevent it:

1. **`org.auros.policy.control-allow`** — our own polkit action, `allow_any=yes`, which no mode rule
   ever touches. `pkcheck` must return 0 for it in every mode. If it does not, the run **aborts**
   rather than reporting: a subject that cannot be authorised for anything proves nothing by being
   refused.
2. **`org.auros.policy.control-deny`** — our own action, also `allow_any=yes` by default, denied
   *only* by the mode's rule file. A refusal here is positive proof the rules are loaded, parsed and
   being evaluated for this subject.
3. **`open/assert.sh` is the negative control.** It asserts the canary is *permitted* and that no
   other mode left a file behind. If the canary were refused in open too, our denials would be an
   artefact of the probe rather than our policy — and every other assertion here would be worthless.

`assert-policy` also **refuses to run as root** and re-execs as the unprivileged `aurosprobe`
account, because root is allowed to do all of these things on any machine in any mode.

### locked vs. managed is a difference the assertions can see

`pkcheck` exit 1 means *no*; exit 3 means *an administrator could authorise this*. `locked` requires
1 and **fails on 3**; `managed` accepts either and fails only on 0. Without that distinction the two
modes would be indistinguishable in CI while being different products in a school, and a recipe could
ship the wrong one behind a full green matrix.

---

## Kiosk

Kiosk boots straight into one application. There is no desktop, no login screen, no taskbar, no file
manager, and no text console: `plasmashell`, the display managers and the terminal emulators are
**removed from the image**, `getty@` is masked, and the account the application runs as has
`/usr/sbin/nologin` as its shell.

The session is `auros-kiosk.service` → **cage** (a Wayland kiosk compositor) → the one application
named in `/etc/auros/kiosk.conf`. `cage` is deliberately started **without `-s`**, which is the flag
that enables VT switching; without it there is nowhere for `Ctrl+Alt+F2` to go.

**We deliberately do not use greetd.** greetd is a login/display manager by function, and check S9
asserts that no display-manager binary exists on a kiosk image. We would rather have no such binary
at all than ship one and then argue about whether it counts. systemd starts the compositor directly;
there is no greeter because there is nobody to greet.

**A kiosk image with no application named is a brick.** `apply-policy` refuses to build one — a black
screen would pass every check that only looks at what was removed.

### What kiosk costs you — D12, recorded so nobody is surprised

**Our kiosk image is meaningfully larger than a purpose-built minimal one, and that is deliberate.**

The obvious way to build a kiosk is up from `fedora-bootc minimal`. We do not, because that would be
a second base image, and spec §3 says exactly one. The cost of two bases is that a CVE stops being
one rebuild — which is the thing we sell. So kiosk is built by **subtracting from the one base**: it
removes the shell and the display manager, the binaries a user could reach a desktop through, and the
shared libraries that the dependency closure will not release **stay**.

`apply-policy` measures `/usr` before and after and writes the real figure to
`/usr/lib/auros/policy/applied.json` as `usr_bytes_before` / `usr_bytes_after` /
`usr_bytes_reclaimed`. **We report that measured number.** We do not quote the size of a minimal
kiosk image we did not build. (Those are uncompressed on-disk bytes; compressed pull size is a
different and more important number, measured separately as `pull_size_delta_bytes` in
`results.json` — see D2 and BLOCKED.md B6.)

If that trade ever stops being worth it, it is a §9 decision for the human, not something to fix by
forking.

### The second cost, which is operational

A kiosk machine with a broken kiosk service has **no local console to fix it from**. It repairs
itself when an update fails — greenboot rolls it back to the previous deployment — but a machine that
needs hands is a machine you reimage or reach through the GRUB path. For an appliance in a lobby that
is usually the right trade. Confirm with the customer that it is, before selling it to them.

*(Harness note for check B5: because there is no console, the kiosk profile has to be driven over ssh
or the QEMU guest agent. There is no way around that which does not put a login prompt on the
machine, which would defeat the mode.)*

---

## The removal traps, and exactly how each is handled

Three separate mechanisms fight package removal on a Fedora/ostree image. All three fail **quietly**,
which is the part that matters — a quiet failure here ships a kiosk with a desktop inside it.

### 1. `protected_packages`

dnf refuses to remove anything named in `/etc/dnf/protected.d/*.conf` or in the `protected_packages`
option. Handled **two ways**, because different dnf versions honour different ones:
`--setopt=protected_packages=` on the transaction, **and** `/etc/dnf/protected.d` moved aside for the
duration and restored by an `EXIT` trap — so a failure mid-transaction never leaves the image's own
protections switched off.

### 2. Weak dependencies (`install_weak_deps`)

`Recommends:` pulls a removed package straight back in on the **next** transaction. The transaction
that undoes our removal is usually the *customer recipe's* install layer, which we do not control —
so `install_weak_deps=False` is written into `/etc/dnf/dnf.conf` **globally**, in a marker-guarded
block, rather than passed per-command. Check **S3** is what catches it if this ever fails.

### 3. comps group membership

Removing a package leaves its comps group marked installed, and the next `dnf group upgrade` in any
later layer reinstates it. Nothing errors; the image is simply wrong. `auros_unmark_groups` tries
both dnf verbs (`group mark remove`, then `group remove`), then **checks** with
`dnf group list --installed`, then **warns loudly and records it in `applied.json` as
`comps_groups_still_marked`** if a group is still marked. It does not pretend to have succeeded.

### And the removal ladder itself

`dnf remove` → `rpm-ostree override remove` → **stop**. Both mechanisms appear in ublue's own build
scripts depending on the day and the upstream, so we detect rather than assume, and then verify every
package with `rpm -q` — because a removal that reports success and leaves the package installed is the
one outcome that must never happen.

**`rpm -e --nodeps` is deliberately not in the ladder.** It would make almost any removal "succeed"
and leave the rpmdb with unsatisfiable `Requires`, so the customer recipe's install layer fails later,
on a different day, for a reason nobody can trace back to here. We would rather fail the build than
ship an image whose package database we broke to make a check go green.

### The post-condition is a binary list, not a package list

`kiosk/remove.list` says what to remove. **`kiosk/absent-binaries.list` is what is actually
asserted.** A package can be renamed, split or absorbed upstream overnight; the binary a student
would use to reach a desktop cannot hide from `command -v`. That list is checked three times, by three
independent mechanisms: `apply-policy` fails the build, check **S9** asserts it statically against the
OCI image, and `kiosk/assert.sh` asserts it again inside the running machine.

If a binary survives, **do not edit `absent-binaries.list`.** Find the package that now provides it,
add that to `remove.list`, and let the build stay red until it is gone. Some mornings this will be red
through no fault of ours; that is S3 and S9 doing their jobs, and it must not be retried away.

### And the guard pointing the other way

`kiosk/keep.list` is never removed by anything here. `apply-policy` snapshots which of those packages
were installed before it started, and **fails the build** if the removal transaction took any of them
with it — directly or as a dependency cascade. `dnf remove plasma-workspace` looks surgical right up
until the closure decides systemd is no longer required by anything. A recipe that prunes its own
update path produces a machine we can never patch again: precisely the abandoned laptop we sell
against. Check **S10** asserts the same set from outside; this guard means the image cannot be built
in the first place.

---

## Honest limits — what these modes do NOT do

Stated here, and stated again to the customer in `locked/description.md` in the same words.

**`locked` does not remove the terminal.** A user with a shell can still run things as themselves in
their own home directory, including `flatpak install --user`. Flatpak has no supported system-wide
switch that disables user-scope installs, and it does not go through polkit. Such an app has no
privilege, is not on the system, and disappears when the profile is reset. `locked` therefore claims
*no root, no system software change, no network change, no stopping updates* — and nothing wider.
The mode that removes this path is `kiosk`, because kiosk removes the shell. `assert.sh` records this
limit as a note rather than asserting a pass for it.

**Physical access to the boot menu defeats every mode here.** Anyone who can restart a laptop and edit
the kernel command line gets root on any Linux machine. The GRUB superuser password that closes this
belongs to the **hardening layer**, not to this one. If a customer's machines go home with students,
confirm it is set.

**The dconf locks only govern GTK/GNOME applications.** Plasma does not use dconf. They are a real
second lock on a second toolkit, not the enforcement. polkit and sudoers are the enforcement.

**KDE Action Restrictions only govern KDE applications.** `action/shell_access=false` closes Dolphin's
"Open Terminal Here", Kate's terminal panel and the run-command box. It does not stop `/usr/bin/bash`
from existing.

**A systemd preset file is a declaration, not an enforcement.** It only affects units with no
enablement state, and only when something runs `systemctl preset`. The preset files here are shipped
as the declarative statement of intent — and `apply-policy` runs the real `enable`/`disable`/`mask`
for every line in them, so the built image carries the state rather than an intention about it.

---

## Cross-layer assumptions

Recorded rather than assumed silently, because these files are owned by other tasks.

| Assumption | Owner | If it is wrong |
|---|---|---|
| The Containerfile COPYs `policy/` to `/tmp/auros-build/policy` before running `build/*.sh` | Containerfile | `20-policy.sh` falls back to `$SELF/../policy`, and fails loudly naming both paths if neither exists |
| The update timers are `bootc-fetch-apply-updates.timer` **and** `uupd.timer` | A4 (update agent) | Confirmed against `build/30-update-agent.sh`: Aurora ships `uupd.timer` as well as bootc's own timer. The assertions attempt to stop **every** active timer among four candidates, not the first — a mode that blocks one and not the other lets a user half-disable updates. None active is a **fail**, never a skip |
| Something puts the school's IT account into the `aurosadmin` group | first-boot setup | `apply-policy` prints a loud multi-line warning at build time; `AUROS_ADMIN_USERS="name"` sets it at build time instead |
| A GRUB superuser password is set | A2 (hardening) | Physical access defeats every mode here; recorded as a note in `locked/assert.sh` and in *Honest limits* above |
| `/etc/xdg/kdeglobals` is also written by the Windows-familiarity layer | A10 / `40-windows-feel.sh` | **Confirmed, and it is an ordering hazard rather than an assumption** — see *The kdeglobals ordering hazard* below |
| Check **B1** ("reaches a login prompt") has a kiosk clause | matrix | **Kiosk cannot pass B1 as written** — there is no login prompt, by design. B1 needs `kiosk ⇒ the kiosk session is active and the application process is running`. `kiosk/assert.sh` already asserts exactly that. Flagged, not edited: `checks.yaml` is not this task's file |

---

## Files

```
policy/
├── apply-policy              → /usr/libexec/auros/apply-policy    activate a mode (build time)
├── assert-policy             → /usr/libexec/auros/assert-policy   prove a mode (run time)
├── lib/policy-lib.sh         build-time helpers: removal ladder, traps, merges, manifests
├── lib/assert-lib.sh         runtime helpers: attempt primitives, controls, shared suites
├── common/root/              shipped in EVERY mode: the polkit canaries, aurosadmin, aurosprobe
├── open/                     description.md · mode.env · assert.sh
├── managed/                  + root/ · kdeglobals/
├── locked/                   + root/ · kdeglobals/
└── kiosk/                    + root/ · kdeglobals/ · remove.list · absent-binaries.list
                                · keep.list · remove-groups.list
```

`../build/20-policy.sh` installs all of it into the image and activates the base's own mode, which is
`open` — not because open is a default worth having, but because the base is tested against the full
matrix and checks **B1** and **B12** only hold literally in open. `AUROS_POLICY=<mode>` overrides it,
which is how CI builds a single-mode image to run B5 against.

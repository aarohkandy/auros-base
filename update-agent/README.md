# The update agent

Everything in here exists to make one sentence from spec §6A literally true:

> Machine-side update agent: pulls on boot, stages, keeps the previous image on disk, **rolls back
> automatically if the new image fails to reach a login prompt twice.**

A school has one overworked IT person and no out-of-band console. An update that bricks a machine
is not recoverable by the customer, so it has to be recoverable by the machine.

---

## Measured facts this layer is built on

Everything below was read from upstream source on **2026-09-20**, not remembered. Three of them
contradicted the assumptions the work started from, and each one would have shipped a broken
product.

| Fact | Where it was read | Why it changed the design |
|---|---|---|
| Aurora preset-enables **`uupd.timer`**, not bootc's timer | `ublue-os/aurora` `system_files/shared/usr/lib/systemd/system-preset/89-aurora.preset` | bootc's own `bootc-fetch-apply-updates.timer` is in the image but **inert**. Assuming it ran would have produced an image that stages updates and never applies them — U1 fails, and the cause looks like a bootc bug. |
| `uupd` runs `bootc upgrade --quiet`, i.e. **stages and never reboots**; daily at 04:00 | `ublue-os/uupd` `drv/system/system.go`, `uupd.timer` | Aurora's update path alone cannot satisfy U1's "pulls, stages **and reboots** within 20 minutes". |
| bootc timer defaults: `OnBootSec=1h`, `OnUnitInactiveSec=8h`, `RandomizedDelaySec=2h` | `bootc-dev/bootc` `systemd/bootc-fetch-apply-updates.timer` | Up to three hours to first check. U1 allows twenty minutes. |
| `greenboot` is **absent** from Aurora and from Fedora bootc standard/minimal | D9 | Explicit install, asserted at build time. |
| `GREENBOOT_MAX_BOOT_ATTEMPTS` default is **3** | `fedora-iot/greenboot` `etc/greenboot/greenboot.conf`, `usr/libexec/greenboot/greenboot-grub2-set-counter` | The documented default gives *three* attempts. "Twice" means 2. |
| Greenboot's GRUB counter ships as `/usr/lib/bootupd/grub2-static/configs.d/08_greenboot.cfg` | `fedora-iot/greenboot` `greenboot.spec` | Auto-rollback depends on **bootupd assembling that fragment into `/boot/grub2/grub.cfg`**, which happens at install time. If the fragment is missing, everything else about greenboot looks perfect and rollback silently does not exist. |
| bootupd concatenates every `*.cfg` in `configs.d` into `grub.cfg` | `coreos/bootupd` `src/grubconfigs.rs` | Confirms the above works on our path, and gives `30-update-agent.sh` something concrete to assert. |
| `greenboot-grub2-set-counter.service` is `RequiredBy=ostree-finalize-staged.service` | `fedora-iot/greenboot` unit file | This is the D9 constraint made mechanical: on the composefs backend that unit does not exist, the counter is never staged, and rollback does not happen. The build asserts `ostree-finalize-staged.service` is present. |
| Greenboot ships **no systemd preset**; Fedora's trailing rule is `disable *` | `greenboot.spec` `%post` | `%systemd_post` leaves every greenboot unit **disabled**. An image with greenboot installed-but-not-enabled passes any naive "is greenboot there?" check and performs no health checks and no rollback at all. |

---

## How "fails twice ⇒ rollback" actually works

`GREENBOOT_MAX_BOOT_ATTEMPTS=2`, and the arithmetic matters because off-by-one here is the
difference between a machine that recovers and a machine that doesn't.

When an update is staged, `greenboot-grub2-set-counter` writes `boot_counter=2` and
`boot_success=0`. Then, on every boot, the GRUB fragment does:

```
if boot_counter is set and boot_success = 0:
    if boot_counter is 0 or -1:  set default=1   # boot the ROLLBACK deployment
    else:                        decrement boot_counter
```

| Boot | `boot_counter` on entry | Boots | Health check | Result |
|---|---|---|---|---|
| 1 | 2 → 1 | the **new** image | fails | `redboot-auto-reboot` reboots |
| 2 | 1 → 0 | the **new** image | fails | reboots |
| 3 | 0 → −1 | the **rollback** image | — | machine is back, on the old digest |

Two attempts at the new image, rollback on the third boot. `MAX=3` (the upstream default) gives
three attempts; `MAX=1` gives one, which would roll a machine back over a single unlucky boot.

On a green boot, `greenboot-grub2-set-success` clears the counter and sets `boot_success=1`.

`redboot-auto-reboot` refuses to reboot when there are ≤ 1 bootloader entries, and refuses again
once `boot_counter=-1` (it is already on the fallback). So the loop always terminates — there is
no path here that reboots a laptop forever.

**D10: exactly one rollback deployment is retained.** Not "any recent image". `bootc` exposes no
verb for pinning more, and nothing here or on the website may imply otherwise.

---

## The apply rule, and why it is not just `--apply`

Upstream's `bootc-fetch-apply-updates.service` runs `bootc upgrade --apply --quiet`, which reboots
as soon as a new deployment is staged. On a server that is correct. In a classroom it means that
three minutes after a student opens the laptop — every morning after a nightly base rebuild — the
machine restarts underneath them. D4 does not survive that.

So `/usr/libexec/auros/auros-update` replaces the ExecStart and:

1. **always** fetches and stages;
2. reboots **only** when logind reports no `Active`, `Class=user` session.

The greeter is `Class=greeter` and deliberately does not count. If it did, a laptop sitting at the
login screen would never update — which is most laptops most of the time — and U1, which runs
against a VM sitting at exactly that greeter, could never pass.

`/etc/auros/update-agent/apply-policy` takes `when-idle` (shipped default), `never`, or `always`.

> **Assumption about another agent's area, flagged rather than solved.** If the first-boot guided
> setup (D4) leaves the VM **autologged into a desktop**, that is an `Active`/`Class=user` session,
> `auros-update` will stage without rebooting, and **U1 will fail** — correctly, because the
> shipped behaviour would be to wait. If that happens, the fix is a decision about the boot
> experience, not a hack here. The `always` policy exists as the escape hatch, but using it for a
> test means the test no longer describes what customers get.

**Failure policy.** Registry unreachable, or `uupd` holding the bootc lock, exits **0**. U5 says an
offline machine is a no-op, and a non-zero exit becomes a failed unit, which
`40-no-new-failed-units.sh` would then read as a regression — rolling a machine back because the
school's uplink blinked. A breadcrumb goes to `/var/lib/auros/update-agent/last-error`, and
`70-update-freshness.sh` surfaces a machine that has gone quiet for a fortnight.

---

## The timer numbers

```
OnBootSec=3min   OnUnitInactiveSec=6h   RandomizedDelaySec=10min
```

`RandomizedDelaySec` is a direct trade between two checks that pull in opposite directions:

* **U1** wants the whole pull-stage-reboot cycle inside 20 minutes.
* **B6** says the base is **3.5 GB** and a 180-machine school shares one uplink — firing every
  laptop at once is a ~630 GB event.

Ten minutes is the largest spread that still fits (3 + 10 = 13 minutes worst case, leaving seven
for the pull and the reboot). **If U1's window ever widens, widen this first.** `Persistent=` is
deliberately unset so a missed window cannot fire a catch-up run during the first minute of a
lesson.

---

## The health checks

`required.d` runs in **strict** mode — the first failure stops the rest — and **every required
check is a rollback trigger.** That is why there are exactly four, why `30-update-agent.sh`
asserts the count is four, and why adding a fifth is a safety decision that belongs in
`DECISIONS.md` rather than in a quiet commit.

### Required — failing these rolls the machine back

| | Asserts |
|---|---|
| `10-network-stack.sh` | NetworkManager is active and answering `nmcli` |
| `20-graphical-target.sh` | the display manager reached `active` within 120 s — or, on a kiosk image with no display manager (D12), `graphical.target` did |
| `30-update-timer-enabled.sh` | `bootc-fetch-apply-updates.timer` is enabled **and** scheduled, the wrapper is executable, `bootc` exists |
| `40-no-new-failed-units.sh` | no unit is failed now that was working on the last **green** boot |

### The two judgement calls in that list

**`10-network-stack.sh` deliberately does not test connectivity.** The obvious version of this
check — "can we resolve DNS / reach the registry" — is a bug that destroys schools. A required
check that fails rolls the machine back, and the uplink being down is not the image's fault. A
school whose broadband drops overnight would find every laptop rolled back in the morning, then
rolled back again from there, which is the fallback boot and needs a technician per machine. U5
says offline is a no-op.

This is also why **`greenboot-default-health-checks` is not installed**: its
`01_repository_dns_check.sh` is a *required* check that does exactly that.

**`40-no-new-failed-units.sh` compares against the last green boot, not against zero.** Zero
failed units is check B11's job, in a clean VM, where it is a fair thing to demand. On a real 2013
laptop with a flaky SD reader, demanding zero would roll back every image forever and the machine
would never be patched again. What we care about is a *regression*: something that worked on the
image being replaced and doesn't on the image being installed. The baseline is written by `green.d`
only after a boot passes every required check, so a bad boot can never launder its failures into
the new normal — which is the standard way a test suite quietly stops testing.

### Wanted — logged and shown in the boot status, never a rollback trigger

| | Asserts |
|---|---|
| `50-signature-enforcement.sh` | the booted deployment's signature mode is `containerPolicy`, and `policy.json` really carries a scoped `sigstoreSigned` rule |
| `60-rollback-wiring.sh` | ostree backend (not composefs — D9), one rollback deployment (D10), `boot_counter` logic present in `grub.cfg`, `MAX_BOOT_ATTEMPTS=2` |
| `70-update-freshness.sh` | a successful fetch happened within 14 days |

**Why `60-rollback-wiring.sh` is `wanted.d` and not `required.d` — this is the trap in the whole
design.** The condition it detects is "GRUB has no `boot_counter` logic". If that is true *and*
`boot_counter` happens to be set, then marking the boot red calls `redboot-auto-reboot`, which
reboots — and GRUB, having no counter logic, never decrements and never switches to the rollback
entry. **The machine reboots forever.** A required check here would turn "auto-rollback is not
wired" into "the laptop is bricked", which is strictly worse than the problem it detects, on a
machine with no console to escape through.

So it warns here, and the same fact is asserted where asserting it is safe: the **build fails** if
the bootupd GRUB fragment is missing, **check U3** proves the rollback end-to-end in a VM before
anything ships, and `auros-update` logs it before staging.

`50-signature-enforcement.sh` is `wanted.d` for a different reason: rolling back would not fix it.
The deployment we would roll back to was installed by the same `bootc install` with the same
config, so it has the same setting. We would burn the boot counter for nothing.

---

## Files, and where they land

```
systemd/bootc-fetch-apply-updates.timer.d/10-auros.conf    -> /usr/lib/systemd/system/…
systemd/bootc-fetch-apply-updates.service.d/10-auros.conf  -> /usr/lib/systemd/system/…
systemd/greenboot-healthcheck.service.d/10-auros.conf      -> /usr/lib/systemd/system/…
libexec/auros-update                                       -> /usr/libexec/auros/auros-update
greenboot/check/required.d/*.sh                            -> /etc/greenboot/check/required.d/
greenboot/check/wanted.d/*.sh                              -> /etc/greenboot/check/wanted.d/
greenboot/green.d/*.sh, greenboot/red.d/*.sh               -> /etc/greenboot/…
etc/auros/update-agent/{apply-policy,failed-units.ignore}  -> /etc/auros/update-agent/
tmpfiles/auros-update-agent.conf                           -> /usr/lib/tmpfiles.d/
```

Three details that are easy to get wrong:

* greenboot's runner globs **`*.sh`** and sorts by name. A check without that extension is never
  run, and nothing tells you.
* State lives in **`/var/lib/auros/update-agent`**, declared via `tmpfiles.d`. Content written to
  `/var` in a Containerfile is only a first-boot default. More to the point, a baseline stored in
  the image would be replaced by the very update it is meant to judge.
* The drop-in for the service **clears `ExecStart=` first**. Without the empty line systemd
  *appends* to bootc's command and the machine runs both.

## Interaction with `uupd`, left in place on purpose

Aurora's `uupd.timer` stays enabled: it updates Flatpaks, which is where the customer's
applications live (spec §3), and we do not want to own that. Its `bootc upgrade` can collide with
ours — bootc serialises on its own lock and the loser errors out. `auros-update` retries once
after 60 s and then exits clean, so a collision costs one skipped cycle and never a failed unit.

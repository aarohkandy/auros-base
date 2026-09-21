# The update agent

Everything in here exists to make one sentence from spec §6A literally true:

> Machine-side update agent: pulls on boot, stages, keeps the previous image on disk, **rolls back
> automatically if the new image fails to reach a login prompt twice.**

A school has one overworked IT person and no out-of-band console. An update that bricks a machine
is not recoverable by the customer, so it has to be recoverable by the machine.

## Status, honestly — 2026-09-20

| Clause of that sentence | Where it stands |
|---|---|
| pulls on boot | **built**, timer drop-in; effective schedule asserted by `tests/` group E, not yet by the build |
| stages | **built**; a failed fetch is now actually detected and recorded (it was not — see "Failure policy") |
| keeps the previous image on disk | **built**; U2 asserts two deployments |
| rolls back automatically after two failed boots | **built and UNPROVEN.** Every part is installed and asserted at build time. **Check U3, the only thing that proves it fires, has never reached a verdict** — one missing line in `matrix/run/run-update.sh`, detailed below. |

Two fatal bugs were found in this layer by audit on 2026-09-20 and are fixed: a fetch failure that
could not be detected, and a rollback-wiring check whose two tests never ran. Both are described
in place, with the measurement that proves it, and both now have a test that goes red without the
fix. Nothing about the *claim* changed; what changed is that parts of it were not true yet.

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

> ### ⚠ THE ROLLBACK HALF OF THIS LAYER IS BUILT AND **UNPROVEN**. Read this before quoting U3.
>
> Check **U3 is the only evidence anywhere that auto-rollback works at all** — build-time guards
> prove the mechanism is *installed*, U3 is the only thing that proves it *fires*. As of
> 2026-09-20 **no run has ever reached a U3 verdict**, and the reason is one missing line in
> another agent's file.
>
> `matrix/run/run-update.sh:19` sets **`AUTOLOGIN=1`**, and its overlay block at lines 159–190
> writes only `registries.conf.d`, a timer drop-in and a hosts unit. It never creates
> `/run/auros-check-matrix` and never overwrites `apply-policy`. So on the harness VM there is
> always an `Active`, `Class=user` session, `auros-update` takes the `machine_in_use` branch,
> logs *"someone is using this machine"* and exits 0 without rebooting. **U1** (`run-update.sh:246`)
> and **U3** (`run-update.sh:280`) therefore cannot reach their digest transitions. The same
> marker gates step 4 of `signing/verify-enforcement.sh:322`, which exits 2 INCONCLUSIVE without
> it.
>
> This is not a bug in either half. It is D4 and U1 pulling in opposite directions, and the
> harness's autologin is what makes the tension visible.
>
> **The fix is one line in the harness overlay**, alongside the two HARNESS ONLY files
> `run-update.sh` already writes into the guest:
>
> ```sh
> # in run-update.sh's $OVL, next to the existing HARNESS ONLY overlays
> mkdir -p "$OVL/run" && touch "$OVL/run/auros-check-matrix"
> ```
>
> `/run` is tmpfs, so the marker cannot exist on a machine that was not deliberately put into
> test mode and it can never ship. `auros-update` already honours it (see section 1 of the
> script). The precedent is the harness's own: it already notes that its compressed timer
> interval proves the machine updates itself but "does not prove the production interval".
>
> **That file is another agent's and is deliberately not edited here**, per the ownership rule.
> Flagged, with the exact diff, and it is the single highest-value line in the repo right now.
>
> **What must not happen** is shipping `apply-policy=always` as the default to make U1 green.
> That would reboot every school laptop three minutes after a student opens it, which is the
> exact behaviour this wrapper exists to prevent. `etc/auros/update-agent/apply-policy` stays
> `when-idle`.

**Failure policy, and the thing that made it a lie until 2026-09-20.** Registry unreachable, or
`uupd` holding the bootc lock, exits **0**. U5 says an offline machine is a no-op, and a non-zero
exit becomes a failed unit, which `40-no-new-failed-units.sh` would then read as a regression —
rolling a machine back because the school's uplink blinked.

Exiting 0 is not the same as succeeding, and the difference is the whole point. `auros-update`
writes three files under `/var/lib/auros/update-agent`:

| | Written |
|---|---|
| `last-fetch-attempt` | every run, success or failure |
| `last-successful-fetch` | **only** after `bootc upgrade` returned 0 |
| `last-error` | on failure; **removed** on success |

and one greppable console token per outcome, `AUROS-UPDATE-FETCH-OK` /
`AUROS-UPDATE-FETCH-FAILED rc=N`, so the check matrix can read the outcome off a serial log
without a host→guest channel.

> **This did not work, at all, until it was fixed.** The status was captured as
> `if ! upgrade_out="$(stage_attempt 2>&1)"; then upgrade_rc=$?`, and `$?` there is the status of
> the **negation**, which is 0 exactly when the command failed. Measured, both shells:
>
> ```
> $ f(){ return 7; }; rc=0; if ! out="$(f)"; then rc=$?; fi; echo $rc
> 0                                        # bash 3.2.57 (macOS) and 5.2.21 (Linux)
> $ f(){ return 7; }; rc=0; out="$(f)" || rc=$?; echo $rc
> 7
> ```
>
> So `upgrade_rc` was 0 on every path, the whole offline/error branch was unreachable dead code,
> and a registry outage, an HTTP 500, a corrupt manifest **and a rejected signature** all fell
> through to the success path — deleting `last-error` and writing a fresh `last-successful-fetch`
> immediately after printing the rejection. `70-update-freshness.sh` is the only mechanism in the
> design that notices a machine that has quietly stopped being patched, and its stamp was
> refreshed on every timer run whatever happened, so it could never fire. **A laptop that had
> refused every update for two years reported "last successful update fetch was 0 day(s) ago."**
>
> Fixed by capturing the status directly (`upgrade_out="$(stage_attempt 2>&1)" || upgrade_rc=$?`).
> `tests/run-tests.sh` A1–A2 assert the stamp does not move after a rejected image, and
> `--self-test` reintroduces the old construct and confirms the test goes red.

---

## The timer numbers

```
OnBootSec=3min   OnUnitInactiveSec=6h   RandomizedDelaySec=10min   Persistent=false
```

`RandomizedDelaySec` is a direct trade between two checks that pull in opposite directions:

* **U1** wants the whole pull-stage-reboot cycle inside 20 minutes.
* **B6** says the base is **3.5 GB** and a 180-machine school shares one uplink — firing every
  laptop at once is a ~630 GB event.

Ten minutes is the largest spread that still fits (3 + 10 = 13 minutes worst case, leaving seven
for the pull and the reboot). **If U1's window ever widens, widen this first.**

### The drop-in did not set that schedule. It doubled it.

`OnBootSec=`, `OnUnitInactiveSec=`, `OnActiveSec=`, `OnStartupSec=`, `OnUnitActiveSec=` and
`OnCalendar=` are **list settings** in `systemd.timer(5)` — *"may be specified more than once, in
which case the timer unit will trigger multiple times"* — and a drop-in **appends** to the vendor
value. Resetting a list requires an **empty assignment first**, which this file did not have.

So bootc's own `OnBootSec=1h` and `OnUnitInactiveSec=8h` — quoted in this file's own header as
measured facts — stayed **live alongside ours**. A shipped machine fired at boot+3min **and**
boot+1h, then re-triggered at **both** 6h and 8h after every run: roughly double the documented
cadence, which doubles exactly the B6 uplink load the `RandomizedDelaySec` number was computed to
bound. `RandomizedDelaySec` is a scalar and did correctly replace the vendor's 2h, which is why
the jitter was right and the trigger times were not.

`Persistent=` was described as "deliberately NOT set" — but a drop-in that *omits* a setting does
not clear it, so that sentence was only true if the vendor unit happened not to set one, and the
file never asserted that. It is now stated explicitly.

The drop-in therefore clears every trigger list before assigning ours, and `tests/run-tests.sh`
group **E** asserts that each reset appears *before* any valued assignment for the same setting —
so a future edit that drops one goes red rather than silently doubling the fleet's traffic again.

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
image being replaced and doesn't on the image being installed.

The baseline is still only ever written after a boot passes every required check, so a bad boot
can never launder its failures into the new normal — that is the standard way a test suite quietly
stops testing. But **both sides of the difference are now sampled at the same point in the boot,
and they were not before.**

> The check runs from `greenboot-healthcheck.service` (`WantedBy=multi-user.target`); `green.d`
> runs from `greenboot-task-runner.service`, **after `boot-complete.target`** — strictly later,
> once the graphical stack has had time to fail. So the baseline was a superset sampled late and
> the current reading was sampled early. Any unit that failed after `multi-user.target` — which is
> most of the desktop, the thing D4 makes the product — was written into the baseline as normal
> and then never observed at check time on the next boot, so **it could never register as a
> regression.** The bias was toward passing, which is the safe direction for false rollbacks and
> the useless direction for finding real ones.
>
> Fixed by sampling **once**: `40-no-new-failed-units.sh` writes `failed-units.candidate`, stamped
> with the boot id, and `green.d/10-auros-record-good-boot.sh` **promotes that file** if greenboot
> goes on to declare the same boot green. A candidate from a different boot is refused and
> `green.d` falls back to its old late sample while saying loudly that it did.
> `tests/run-tests.sh` D2–D3 prove the promotion by changing the machine's failed set *between*
> the healthcheck and `green.d` and asserting the baseline is the early snapshot.

**What this check still cannot see**, stated because the old text claimed coverage the sampling
did not give: a unit that fails *later* than the healthcheck — between there and
`boot-complete.target`, or in a user session afterwards — is in neither side of the difference and
is invisible here by construction. `20-graphical-target.sh` runs first and waits for
`display-manager.service`, so the sample is at least taken after the graphical stack is up; beyond
that it is B11's territory, in a VM, where demanding zero is fair.

### Wanted — logged and shown in the boot status, never a rollback trigger

| | Asserts |
|---|---|
| `50-signature-enforcement.sh` | the booted deployment's signature mode is `containerPolicy`, and `policy.json` really carries a scoped `sigstoreSigned` rule |
| `60-rollback-wiring.sh` | ostree backend (not composefs — D9), the counter units exist, a rollback deployment is retained once there is one to retain (D10), `boot_counter` logic in `grub.cfg`, `MAX_BOOT_ATTEMPTS=2` |
| `70-update-freshness.sh` | the **running** image (`.status.booted.image.timestamp`) is under 21 days old — a fresh fetch stamp alone cannot pass it, since "nothing new" is also a successful fetch (SYSTEM-REVIEW §2.4) — **and** a successful fetch happened within 14 days, once one was *due* |

> **Both wanted checks were broken in the same way and neither could be noticed.**
>
> `60-rollback-wiring.sh` piped `bootc status --json` into `python3 - <<'PY'`. The heredoc is
> applied *after* the pipe and overrides it, so python read the **heredoc** as its program and
> `json.load(sys.stdin)` then read an already-consumed stdin at EOF. Reproduced on bash 3.2.57 and
> 5.2.21: `json.decoder.JSONDecodeError: Expecting value: line 1 column 1`, exit 1. The block
> raised on **every boot of every machine**, `|| rc=1` fired unconditionally, and **neither the
> composefs test nor the rollback test ever executed.** Because it is `wanted.d` it did not roll
> anything back — it printed a Python traceback into the boot status forever, so the one channel
> that would report *"rollback is not wired on this machine"* cried wolf permanently and was
> guaranteed to be ignored. Fixed by passing the JSON as a **file path in argv**, the way
> `50-signature-enforcement.sh:65` already does for `policy.json`.
>
> `70-update-freshness.sh` scored an absent stamp as PROBLEM. On a fresh install the stamp
> *cannot* exist — the first timer run is at boot+3min plus jitter, long after
> `greenboot-healthcheck` — so the **very first boot a customer ever sees** reported "no successful
> update fetch has ever been recorded on this machine". That is D4's "clean end to end" first boot
> showing red for a condition that is normal, which is how an operator learns to ignore a check
> before it has ever told them anything true. Combined with the `auros-update` bug above it was
> wrong in *both* directions: a false alarm on the one boot where nothing was wrong, and a
> permanent false all-clear thereafter. Now an absent stamp is OK only while a fetch is not yet
> plausibly due — judged on **two** clocks, uptime and an `agent-first-seen` marker, because
> uptime alone is reset by every reboot.

**Two things `60-rollback-wiring.sh` now asserts that nothing did before.** D9 says greenboot's
rollback does not work on the composefs/UKI backend at all. The build-time guards in
`build/30-update-agent.sh` are real, but they only cover build time — nothing detected a machine
installed from an older image, or a base flipped to composefs under a future rebuild. The check
now tests for `ostree-finalize-staged.service` and `greenboot-grub2-set-counter.service` on the
filesystem, which is decisive regardless of what bootc calls its JSON fields this month. And "no
rollback deployment" is only a PROBLEM once the machine has more than one deployment — a machine
that has never taken an update has nothing behind it, and reporting that as a fault would be the
same first-boot red line `70` was just cured of.

**Why `60-rollback-wiring.sh` is `wanted.d` and not `required.d` — this is the trap in the whole
design.** The condition it detects is "GRUB has no `boot_counter` logic". If that is true *and*
`boot_counter` happens to be set, then marking the boot red calls `redboot-auto-reboot`, which
reboots — and GRUB, having no counter logic, never decrements and never switches to the rollback
entry. **The machine reboots forever.** A required check here would turn "auto-rollback is not
wired" into "the laptop is bricked", which is strictly worse than the problem it detects, on a
machine with no console to escape through.

So it warns here, and the same fact is asserted where asserting it is safe: the **build fails** if
the bootupd GRUB fragment is missing, `auros-update` logs it before staging, and **check U3 is
where the rollback would be proved end to end in a VM — see the box above: U3 has never reached a
verdict, so that proof does not exist yet.**

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
tests/run-tests.sh                                         -> NOT installed. Host-side.
```

Three details that are easy to get wrong:

* greenboot's runner globs **`*.sh`** and sorts by name. A check without that extension is never
  run, and nothing tells you.
* State lives in **`/var/lib/auros/update-agent`**, declared via `tmpfiles.d`. Content written to
  `/var` in a Containerfile is only a first-boot default. More to the point, a baseline stored in
  the image would be replaced by the very update it is meant to judge.
* The drop-in for the service **clears `ExecStart=` first**. Without the empty line systemd
  *appends* to bootc's command and the machine runs both.
* The same is true of the **timer**, and it is less obvious because there is no single line to
  clear: `OnBootSec=`, `OnUnitInactiveSec=`, `OnActiveSec=`, `OnStartupSec=`, `OnUnitActiveSec=`
  and `OnCalendar=` are *list* settings, so a drop-in adds a trigger rather than moving one. Each
  needs its own empty assignment first. `RandomizedDelaySec=` and `Persistent=` are scalars and do
  replace — which is exactly why this was invisible: the jitter looked right while the machine was
  firing twice as often as the file said.

## Tests

```sh
bash update-agent/tests/run-tests.sh              # 89 assertions
bash update-agent/tests/run-tests.sh --self-test  # + reintroduce each fixed bug, confirm it goes red
```

No podman, no QEMU, no VM, no running systemd — bash, python3 and coreutils. The scripts are run
**unmodified out of the tree** against a scratch root (`AUROS_TEST_ROOT`, empty on a real machine)
with stub `bootc`, `systemctl`, `loginctl` and `sleep` on `PATH`. Nothing is sed-patched or copied
first, because a test that edits its subject is testing the edit.

**Measured:** 94/94 including `--self-test`, on macOS 27 / bash 3.2.57 and on Linux 6.17 /
bash 5.2.21 / GNU coreutils 9.4 / python 3.12.3 (2026-09-20). The macOS run shims `date -d`, which
is GNU-only, and says so in its header; the Linux run uses the real thing.

Why this exists at all: the two fatal bugs fixed here had both been written with care, commented at
length, and "verified" by a check matrix that never read the state they write. Neither could have
been found by reading. Both are found in under a second by running the script with a stub that
fails. **D19: a step that cannot fail is not a check** — and that applies to this file too, which
is what `--self-test` is for.

| Group | What it would catch |
|---|---|
| A | `auros-update` swallowing a fetch failure; the freshness stamp moving after a rejected image; `set -e` killing the unit on a transient `bootc status`; the negated-capture construct returning |
| B | every branch of `60-rollback-wiring.sh`, **including that a healthy machine is green** — the fatal made the healthy case red, so a test of only the failure paths would have passed |
| C | `70-update-freshness.sh` shouting on a first boot, staying quiet on a machine that has gone dark, or staying green on a stale image because the fetch stamp is fresh |
| D | the baseline and the reading being sampled at different points in the boot |
| E | a trigger list losing its empty reset and the fleet's update traffic silently doubling |
| F | a health check that greenboot will never run (wrong extension), or a fifth rollback trigger arriving quietly |

---

## What this layer asks of files it does not own

Three assertions belong in other agents' files. They are listed here with the exact change so
nobody has to rediscover them, and **they are not edited from here**, per the ownership rule.

**1. `matrix/run/run-update.sh` — the one that matters.** Add the check-matrix marker to the
overlay. Without it U1 and U3 cannot reach a verdict, and **U3 is the only evidence anywhere that
auto-rollback fires.** See the box under "The apply rule".

```sh
mkdir -p "$OVL/run" && touch "$OVL/run/auros-check-matrix"
```

Its own timer overlay at lines 168–174 has the **same list-setting bug** this layer just fixed:
`OnBootSec=60s` / `OnUnitActiveSec=90s` accumulate on top of the vendor's values rather than
replacing them. Add empty resets there too, or the harness is not testing the interval it thinks
it is.

**2. `matrix/run/run-update.sh` — U5 must read the state it just caused.** U5 currently passes
without looking at either file the update agent writes. After the registry-outage phase it should
assert, in the guest:

* `/var/lib/auros/update-agent/last-error` **exists**, and
* `/var/lib/auros/update-agent/last-successful-fetch` is **unchanged** across the outage,

or, with no host→guest channel, grep the serial log for `AUROS-UPDATE-FETCH-FAILED` during the
outage and `AUROS-UPDATE-FETCH-OK` after the registry returns. Both tokens are emitted for exactly
this purpose. Nothing in `matrix/run/` reads the freshness stamp or the `wanted.d` results today,
which is why CI could not have caught the fatal above either.

**3. `build/30-update-agent.sh` — measure the timer, do not describe it.** The drop-in now clears
each trigger list before setting it; assert the *effective* result rather than the file contents:

```sh
systemd-analyze cat-config systemd/bootc-fetch-apply-updates.timer   # or
systemctl show bootc-fetch-apply-updates.timer -p TimersMonotonic
```

`tests/run-tests.sh` group E asserts the drop-in's shape, which is as far as a test outside a
running systemd can go. Only the build can assert what systemd actually computed.

*(Also: `update-agent/tests/` is copied into the build context by the `COPY update-agent/` line
and is never installed into the image. Harmless — a few tens of KB of context. Excludable if the
build ever cares.)*

---

## Interaction with `uupd`, left in place on purpose

Aurora's `uupd.timer` stays enabled: it updates Flatpaks, which is where the customer's
applications live (spec §3), and we do not want to own that. Its `bootc upgrade` can collide with
ours — bootc serialises on its own lock and the loser errors out. `auros-update` retries once
after 60 s and then exits clean, so a collision costs one skipped cycle and never a failed unit.

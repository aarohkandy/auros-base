# `matrix/run/` — the harness that executes the check matrix

`../checks.yaml` and `../profiles.yaml` define what "passed" means. This directory is the machinery
that goes and finds out, and writes the answer to `results.json` in the shape `../results.schema.json`
demands.

**The contract files are not mine.** Nothing here edits `checks.yaml`, `profiles.yaml` or
`results.schema.json`. If a check cannot be implemented honestly, the answer is to say so — in this
file and in the check's `detail` string — not to soften the check.

---

## Running it

```bash
# everything, base image, all seven profiles
matrix/run/run-matrix.sh --image localhost/auros-base:hardened --budget-bytes 4500000000

# the pieces, which is what CI actually calls
matrix/run/run-static.sh  --image localhost/auros-base:hardened --second-digest sha256:… --budget-bytes N
matrix/run/run-boot.sh    --profile low-ram --image localhost/auros-base:hardened
matrix/run/run-update.sh  --image localhost/auros-base:hardened --signing-key cosign.key
node matrix/run/emit-results.mjs --run-dir matrix-run --image … --digest sha256:… --run-url …
node matrix/run/record-pass.mjs  --results matrix-run/results.json
```

Needs: `podman`, `qemu-system-x86_64`, `node`, and for the full set `skopeo`, `cosign`, `swtpm`,
`ovmf`, `libguestfs-tools`. It runs on any Linux box with `/dev/kvm`; `ci/check-matrix.yml` is a
reference GitHub Actions workflow that does the same thing on `ubuntu-24.04`.

There are **no runtime dependencies to install.** `lib/yaml-lite.mjs` and `lib/validate.mjs` are small
on purpose: if `npm install` could fail, then a bad network could turn a FAIL into a "could not
evaluate", and the schema is explicit that an unvalidatable result is a FAIL.

## How the pieces talk

```
run-static.sh ─┐                          checks/static.jsonl
run-boot.sh  ──┼─► one JSON Line per check ─► checks/boot-<profile>.jsonl ─► emit-results.mjs
run-update.sh ─┘                          checks/update.jsonl                     │
                                                                                  ▼
                                                        validate against results.schema.json
                                                                                  │
                                                        ┌─────────────────────────┴──────────┐
                                                 fails: results.invalid.json,         passes: results.json
                                                        NO results.json, exit 2              │
                                                                                             ▼
                                                                                   record-pass.mjs
                                                                    recompute verdict · append compat rows
                                                                    · ledger only on a full pass
```

Later records for the same id supersede earlier ones, which is how boot 2 updates boot 1's `B2`.

## Four properties, and where each one lives

**A pass is bound to a digest.** `emit-results.mjs` refuses a `--digest` that is not
`sha256:[a-f0-9]{64}`. A tag can be moved after the test passed.

**`skip` is not `pass`.** `record-pass.mjs` treats a skipped required check as a failure, and treats a
required check with *no record at all* as a failure too — absence is the quieter version of the same
problem. Nothing in the harness emits `skip` for a check it simply could not run: it emits `fail` with
a detail saying why. Missing tool, missing firmware, missing argument — all red.

**The harness's own `verdict` is ignored.** `record-pass.mjs` recomputes it from the checks array and
prints a loud line when the two disagree. It also derives the bound profile set itself rather than
believing the one in the file.

**Static failure stops the run.** `run-static.sh` exits non-zero and `run-matrix.sh` does not boot
anything. Seconds instead of twenty minutes, and, more importantly, nobody gets trained to read a red
run as normal.

## Which checks are required on which profile

`checks.yaml` says boot checks run once per profile and static checks run against the image, but it
does not say how the update group binds to profiles, and the schema has room for checks only *under* a
profile. The reading this harness uses lives in one function, `requiredFor()` in `lib/matrix.mjs`:

| group | required on | recorded |
|---|---|---|
| `S1`–`S10` | every profile | evaluated **once** against the image, copied into each profile with `detail` saying so |
| `B1`–`B12` | every profile | genuinely re-run per profile |
| `U1`–`U5`, `R1` | the update profile only (default `uefi-modern`) | only there — *absent* elsewhere, which is not the same as `skip` |

If you disagree with that reading, it is a one-line change with a visible diff. That is the point of
putting it in one place.

## Polling, and why there is no `sleep`

Every wait is a poll for a marker with a deadline: `poll_until` in `lib/common.sh`, the QMP `SUSPEND`
event in `lib/qmp.mjs`, `systemctl is-system-running --wait` in the guest. A fixed sleep followed by an
assertion scores a slow-but-correct boot as a failure, and under TCG every boot is slow. Deadlines
scale by `AUROS_TCG_FACTOR` when there is no KVM; **what we conclude never scales.**

**TCG and the B1 budget.** `run-boot.sh` refuses to run without `/dev/kvm` unless `AUROS_ALLOW_TCG=1`.
B1's criterion has two halves — *reaches a greeter* and *within 120 s* — and only the first is
meaningful under emulation. Under TCG the harness passes B1 on the marker and says in the detail that
the budget was not applied. That is a real weakening, so it is not the default: CI has KVM (measured),
and a job silently degrading to emulation would quietly stop enforcing half of B1.

---

# What I could not fully implement, and why

This is the section to read before trusting a green run.

### The booted artifact is not byte-for-byte the image under test
`guest/Containerfile.testwrap` adds a oneshot agent unit, a test user, and display-manager autologin
(B7/B8/B12 need a live desktop session and there is nobody in the room to type a password). The update
run additionally adds an `/etc/hosts` entry, a `registries.conf.d` snippet and a timer drop-in. The
digest recorded in `results.json` is the **image under test**, and the wrapper file is short and
commented so you can see exactly what sat on top. It touches nothing any check looks at. If you ever
find yourself adding a line to that file to make a check pass, you are no longer testing the product.

### U1 compresses the update interval
The timer drop-in sets `OnBootSec=60s`/`OnUnitActiveSec=90s`. The harness never triggers an update by
hand — that would destroy the word "unattended", which is the entire content of U1. What U1 proves is
that the machine updates itself with no human action. What it does **not** prove is the production
interval.

### U4 does not literally run `bootc upgrade`
U4's wording names the command. There is no host→guest control channel by design (the agent reports
over a serial port; nothing sends it instructions, so nothing can be injected into the guest by
whatever we are testing). So what is asserted is the unattended path: the unsigned image is offered,
the booted digest does not move, and `.status.booted.image.image.signature` still reads
`containerPolicy` (D25). **Crucially, "the digest did not change" alone is not scored as a pass** — an
update that failed because the registry was slow looks identical to one refused on policy, so U4 also
requires a signature-shaped rejection on the console or a still-verified booted image. Refusing to
score a pass on the strength of an absence is the whole reason this check exists.

### U4's registry trick, which is the part most worth understanding
A local registry serving `10.0.2.100:5000/...` would make U4 pass vacuously: the guest's `policy.json`
is scoped to `ghcr.io/<org>`, so an image under any other name falls straight through Aurora's
inherited `"": insecureAcceptAnything` catch-all (D8). So the guest is pointed at the harness's
registry **by name** — `/etc/hosts` maps `ghcr.io` to a QEMU `guestfwd` address, and `registries.conf`
marks `ghcr.io` insecure so plain HTTP works. The reference string stays
`ghcr.io/<org>/auros-base@sha256:…`, so the `sigstoreSigned` rule applies and the test is real.
Marking a registry insecure changes the **transport**; it does not change the **signature policy**,
which is crypto over the manifest.

### The S8 ordering problem — unresolved, and not mine to resolve alone
S8 asks whether a customer's laptop can *find* the signature in the registry. That cannot be answered
before the image is in a registry, and spec §6A says publish only on a full pass. The harness takes
`--registry-ref` and fails closed without one; the workflow has to push to a **staging** repository,
sign there, run the matrix, and promote on a pass. `ci/check-matrix.yml` shows that shape. Whoever owns
the publish workflow (A7) has to agree to it, and until they do, S8 is red.

### S5 can only be rigorous when the pinned upstream image is in local storage
S5 asks whether the removal report equals the *resolved removal closure*. The harness does not re-derive
a dependency closure; it **measures** one, by diffing `rpm -qa` in the pinned upstream base against
`rpm -qa` in the image, and compares the report to that — including per-package byte counts against
rpm's own installed sizes (5% tolerance). In CI the upstream image is always local, because it is the
build's `FROM`. Run it somewhere the upstream image is absent and S5 fails closed rather than
downgrading to "the file looks well-formed".

### Checks that are vacuously true for the base image, on purpose
For a base build with no recipe, S3's removal set and S4's install set are empty, so both hold over
zero packages, and B4 has no declared locale to compare against. Each says so in its `detail`. **S5 is
the exception:** a base build must still ship a removal report declaring an empty set, so that "we
removed nothing" is a recorded measurement rather than a missing file. That is a small demand on the
prune engine and it is stated here because I did not write that code.

### B12 asserts existence and launch, not window mapping
The zero-terminal audit checks that the responsible `.desktop` entry or KCM exists and that launching
it produces a process that is still alive fifteen seconds later. It does **not** assert that a window
was mapped — window enumeration under Wayland is not reliably scriptable. checks.yaml's own wording is
"the responsible .desktop entries and GUI components exist and launch", which is what is implemented,
but D4 is a promise about whether a person can actually do the thing, and a launched process is weaker
evidence than a visible window. A human should look at a screenshot before we tell a school this is
true. For `policy=kiosk` the audited capability set is empty by construction, because a kiosk image
makes no in-session install/printer/language promise; that is an assumption about what kiosk means and
it is worth an argument if you disagree.

### R1 is the least grounded check here
It builds a synthetic archive (`files/` plus a `manifest.sha256`) on a disk labelled
`AUROS_MIGRATION`, attaches it, and looks for the guest reporting a restore and a matching file count.
That layout is **an assumed convention** — `auros-installer`'s Linux side (work item C8) is not written
yet, so there is nothing to conform to. If the real convention differs, this check is what changes. It
also needs `virt-make-fs` (libguestfs-tools) and fails closed without it.

### `small-disk`'s real point is measured but not gated
`profiles.yaml` says small-disk proves "install plus TWO deployments plus Flatpaks fit with ≥15% free".
No check id in `checks.yaml` expresses that, so the harness reports the disk situation in the run log
and the compat row and **cannot fail the gate on it**. Adding a check would mean editing `checks.yaml`,
which is not mine. Worth raising: per D26 the image is ~8.4 GB and needs a ≥20 GiB root filesystem, so
64 GB is close to the real floor rather than a comfortable margin.

### Profiles that need tooling we might not have
`uefi-secureboot` needs `OVMF_VARS_4M.ms.fd` (Microsoft's keys — enrolling our own would prove nothing
an OEM ships) and `tpm12`/`uefi-secureboot` need `swtpm`. If they are missing the **whole profile
fails**; it is not skipped. `run-boot.sh`'s `fail_all` writes the reason into all twelve boot checks so
the results file says what happened rather than going quiet.

### What no VM run can establish, said once more
Everything in `profiles.yaml → not_provable_in_vm`. Every compat row this harness writes is
`source=vm`, leaves `wifi`, `trackpad`, `suspend`, `brightness` and `webcam` **empty**, and carries
`verdict=untested` — because the row is not a statement about a machine at all. `gpu` and `audio` are
filled from B8/B7 and mean "the virtio-gpu / ich9-hda software stack works", which the `notes` column
says explicitly. `record-pass.mjs` re-checks all of this before appending, and the repo's independent
`tools/compat-lint.mjs` checks it again afterwards. B10 (suspend) is a software-path approximation and
`checks.yaml` already says so — which is why `suspend` stays empty even though B10 ran.

### One convention I had to assume, and where it will bite
`attest/passed-digests.tsv` belongs to work item 0.5 / `tools/gate.mjs`, which is not written yet.
`record-pass.mjs` declares the columns it writes in `LEDGER_COLUMNS` at the top of the file, creates the
ledger with that header if it is absent, and **refuses to append to a ledger whose header differs**,
naming both. Reconcile the two lists; do not paper over a mismatch, because a row the gate cannot parse
is a pass that does not exist.

Two smaller assumptions, both read out of the other agents' files rather than guessed, and both worth
re-checking if a check fails oddly: the removal report at `/usr/share/auros/removal-report.json` (three
paths are searched and the failure names all three), and the policy layer's
`/usr/libexec/auros/assert-policy` plus the `/usr/lib/auros/policy-mode` stamp, which is what B5 runs.

---

## Fanning out

From CI, one job per profile (`strategy.matrix`), `fail-fast: false` — one red profile must not hide
the others, because the gate needs all of them.

From an agent, one subagent per profile, each invoking `run-boot.sh --profile <id>` and returning
**only** `"<profile> pass|fail"` plus the path to its log. The logs are large and a caller that reads
all seven loses the thread (spec §8). `run-matrix.sh` prints exactly that line per profile, so it is
also the local shape.

## When a check fails

Do not disable it, do not add a flag, do not wrap it in `continue-on-error`. There is no `--force` in
this directory and adding one would be a `DECISIONS.md` entry, not a commit. Write the failure to
`BLOCKED.md` with the digest and the run URL, take the next unblocked task, surface it at the next
checkpoint.

**S3 especially.** It goes red when upstream re-adds a package a recipe removed. That is the check
working. Retrying it until it passes ships a kiosk image with a desktop inside it.

#!/usr/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — build/10-hardening.sh
#
# The hardening layer, written for one specific machine: a 2012–2018 laptop in a school, with one
# overworked IT person, no out-of-band console, and a user who must never need a terminal (D4).
#
# That reader changes the answers. Every setting below is either (a) something that reduces what an
# attacker can reach, or (b) something that keeps the machine recoverable by the machine itself. A
# setting that is neither — a CIS checkbox that breaks printing, say — is not here, and where one was
# considered and rejected the rejection is written down rather than left as a silent omission.
#
# Everything this script does is asserted again at runtime by /usr/libexec/auros/hardening-assert,
# because a configuration file that is present but not in force is worse than none: we would be
# telling a school their machines are hardened when they are not.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
. /tmp/auros-build/build/00-common.sh

H="${AUROS_BUILD_DIR}/hardening"
[ -d "$H" ] || die "hardening/ is not in the build context — the Containerfile must COPY it to $H"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "SELinux — enforcing"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# WHAT CANNOT BE ASSERTED HERE, STATED PLAINLY: `getenforce` inside this build reports the state of
# the machine running podman, not the state of the image being built. An assertion on it would pass
# on a hardened runner and pass on an unhardened one, which makes it worse than no assertion. What is
# assertable at build time is the configuration; what is assertable at runtime is the behaviour, and
# auros-hardening-assert.service does that on every boot.

pkg_ensure selinux-policy-targeted

install_file "$H/selinux-config" /etc/selinux/config 0644
grep -qx 'SELINUX=enforcing' /etc/selinux/config || die "/etc/selinux/config does not say enforcing after writing it"
did "SELinux mode set to enforcing, policy targeted"

# Kernel arguments for a bootc image come from /usr/lib/bootc/kargs.d/*.toml. Confidence note: this
# directory is the documented bootc mechanism, but `bootc container lint` does NOT validate it, so a
# malformed file here fails at install time rather than at build time. The file we ship is four
# tokens long precisely because nothing checks it for us.
install_file "$H/kargs-selinux.toml" /usr/lib/bootc/kargs.d/10-auros-selinux.toml 0644
did "kernel argument selinux=1 pinned via /usr/lib/bootc/kargs.d (enforcing=1 deliberately NOT set — see the file for why)"

# An argument that switches SELinux off, shipped by anyone, defeats all of the above.
if grep -RIs -E 'selinux=0|enforcing=0' /usr/lib/bootc/kargs.d /usr/lib/ostree-boot 2>/dev/null | grep -q .; then
  die "something in this image ships a kernel argument that disables SELinux: $(grep -RIsl -E 'selinux=0|enforcing=0' /usr/lib/bootc/kargs.d /usr/lib/ostree-boot 2>/dev/null | tr '\n' ' ')"
fi
did "no image-supplied kernel argument disables SELinux"

# Labelling note, so nobody goes looking for a restorecon that is not here: bootc applies SELinux
# labels from the policy across the tree at install time, and running restorecon inside an
# unprivileged build container is unreliable (there is no selinuxfs to read the active policy from).
# We do not call it, and check B11 — zero SELinux denials in the journal — is what proves the labels
# that actually got applied are right.

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "sshd — masked, not disabled"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# A school laptop has no reason to accept inbound ssh. "Disabled" is one `systemctl enable` away from
# on, and sshd.socket would start on connection even while sshd.service is disabled. Masking points
# both at /dev/null, so nothing — not activation, not a preset, not an errant enable — starts them.
#
# The package is NOT removed. Removal is a subtraction decision and belongs to the recipe prune list
# (spec §6B), where it shows up in removal-report.json and the customer can see it. Deleting it here
# would also take the ssh CLIENT with it on some dependency layouts, which a managed fleet may need.

masked_any=0
for u in sshd.service sshd.socket; do
  if mask_unit "$u"; then did "masked $u"; masked_any=1; else found "$u not present on this base"; fi
done
[ "$masked_any" -eq 1 ] || warn "no sshd units were found to mask — this base may not ship openssh-server at all"

# For the case where an administrator deliberately unmasks it later: what comes back should not be
# stock. sshd reads sshd_config.d in lexical order and takes the FIRST value for each keyword.
if [ -d /etc/ssh ]; then
  install_file "$H/sshd-hardening.conf" /etc/ssh/sshd_config.d/10-auros-hardening.conf 0600
  did "sshd drop-in installed: root login off, passwords off, forwarding off (applies only if someone unmasks it)"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "firewalld — default-deny inbound"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
pkg_ensure firewalld

# Print the real before/after rather than claiming one. The stock `public` zone's allowlist is read
# off this image, not recited from memory, so the line the build console streams is measured.
if [ -f /usr/lib/firewalld/zones/public.xml ]; then
  # `|| true`: pipefail is in force and a zone with no <service> lines is a legitimate answer.
  stock="$(grep -o 'service name="[^"]*"' /usr/lib/firewalld/zones/public.xml | cut -d'"' -f2 | tr '\n' ' ' || true)"
  found "stock 'public' zone allows inbound: ${stock:-(none)}"
fi

install_file "$H/firewalld-zone-auros.xml" /usr/lib/firewalld/zones/auros.xml 0644

# DefaultZone lives in /etc/firewalld/firewalld.conf, which is a package-owned full file. Edited in
# place rather than replaced, because replacing it would silently reset every other knob in it to
# whatever this script happened to know about on the day it was written.
[ -f /etc/firewalld/firewalld.conf ] || die "firewalld is installed but /etc/firewalld/firewalld.conf is missing"
grep -qE '^\s*DefaultZone=' /etc/firewalld/firewalld.conf \
  || die "firewalld.conf has no DefaultZone line to change — refusing to append blind"
sed -i 's/^\s*DefaultZone=.*/DefaultZone=auros/' /etc/firewalld/firewalld.conf
grep -qx 'DefaultZone=auros' /etc/firewalld/firewalld.conf || die "DefaultZone did not take"
auros_stamp /etc/firewalld/firewalld.conf
record wrote-file /etc/firewalld/firewalld.conf
did "default firewall zone set to 'auros' — inbound REJECT, allowlist: dhcpv6-client, mdns"
found "mdns is allowed on purpose: driverless printer discovery is mDNS, and check B12 requires that adding a printer works without a terminal"
found "ssh is NOT in the allowlist"

enable_unit firewalld.service

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "telemetry — inventory, then action"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# The rule for this section is: LIST WHAT YOU FOUND. Every row of hardening/telemetry.tsv is printed
# whether it is present or not, because "we looked and it was not there" is a finding and "we assumed
# it was not there" is not. Two things are named and deliberately left alone; they are printed too,
# because a privacy claim with a quiet exception is a false claim.

tsv="$H/telemetry.tsv"
[ -f "$tsv" ] || die "hardening/telemetry.tsv missing from the build context"

while IFS=$'\t' read -r -u 3 kind target rationale; do
  case "${kind:-}" in ''|'#'*) continue ;; esac
  case "$kind" in
    unit-mask)
      if mask_unit "$target"; then
        did "MASKED    $target — $rationale"
      else
        found "ABSENT    $target (nothing to mask)"
      fi
      ;;
    unit-keep)
      if have_unit "$target"; then
        enable_unit "$target"
        did "KEPT ON   $target — $rationale"
      else
        found "ABSENT    $target (cannot keep what is not here)"
      fi
      ;;
    unit-report)
      if have_unit "$target"; then
        found "PRESENT   $target — $rationale"
      else
        found "ABSENT    $target"
      fi
      ;;
    pkg-report)
      if have_pkg "$target"; then
        found "PRESENT   $target ($(rpm -q --qf '%{VERSION}-%{RELEASE}' "$target")) — $rationale"
      else
        found "ABSENT    $target"
      fi
      ;;
    *) warn "telemetry.tsv: unknown kind '$kind' for '$target' — ignored" ;;
  esac
done 3< "$tsv"

# ── DNF "countme", measured rather than assumed ──────────────────────────────────────────────────
# Fedora's Count Me census is set per repository with `countme=1`. There is no single documented
# global off-switch, so this counts the repositories that have it on, turns each one off, and counts
# again. The number printed is a measurement of this image.
countme_before=0
if compgen -G '/etc/yum.repos.d/*.repo' >/dev/null; then
  countme_before="$(grep -lsE '^\s*countme\s*=\s*1' /etc/yum.repos.d/*.repo 2>/dev/null | wc -l | tr -d ' ' || true)"
  countme_before="${countme_before:-0}"
  if [ "$countme_before" -gt 0 ]; then
    sed -i -E 's/^\s*countme\s*=\s*1/countme=0/' /etc/yum.repos.d/*.repo
    countme_after="$(grep -lsE '^\s*countme\s*=\s*1' /etc/yum.repos.d/*.repo 2>/dev/null | wc -l | tr -d ' ' || true)"
    countme_after="${countme_after:-0}"
    [ "$countme_after" = "0" ] || die "countme still enabled in $countme_after repo files after disabling it"
    did "DISABLED  dnf countme in $countme_before repository file(s)"
    record disabled-countme "$countme_before repo files"
  else
    found "ABSENT    dnf countme — no repository file in this image has countme=1"
  fi
else
  found "ABSENT    /etc/yum.repos.d/*.repo — nothing to check for countme"
fi

# ── Plasma User Feedback ─────────────────────────────────────────────────────────────────────────
install_file "$H/plasma-user-feedback" /etc/xdg/PlasmaUserFeedback 0644
did "PINNED    Plasma User Feedback to level 0 system-wide"

found "the OS itself does not phone home: it is replaced wholesale by bootc pulling a signed image, and the only outbound request that involves is a registry GET"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "sudo and polkit — the baseline the policy modes tighten"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
pkg_ensure sudo polkit

install_file "$H/sudoers-baseline" /etc/sudoers.d/50-auros-baseline 0440

# visudo -c is the only real check; a syntax error in sudoers.d makes sudo refuse to run AT ALL,
# which on a machine with no ssh and no terminal-literate user is unrecoverable in the field.
if have_cmd visudo; then
  visudo -cf /etc/sudoers.d/50-auros-baseline >/dev/null || die "the sudoers file we just wrote does not parse — refusing to ship it"
  visudo -c >/dev/null || die "the complete sudoers configuration does not parse after adding our file"
  did "sudoers validated with visudo (both our file and the merged configuration)"
else
  warn "visudo is not present on this base, so the sudoers file could not be validated at build time — check B5 is the only thing that will catch a syntax error"
fi

# A NOPASSWD rule that sorts AFTER ours wins over ours. That is the only case that matters, and it is
# checked rather than assumed. Anything sorting before ours is overridden and is reported, not fatal.
nopass_after=""
nopass_before=""
for f in /etc/sudoers.d/*; do
  [ -f "$f" ] || continue
  grep -qsE '^[^#]*NOPASSWD' "$f" || continue
  if [[ "$(basename "$f")" > "50-auros-baseline" ]]; then
    nopass_after="$nopass_after $f"
  else
    nopass_before="$nopass_before $f"
  fi
done
if grep -qsE '^[^#]*NOPASSWD' /etc/sudoers; then nopass_before="$nopass_before /etc/sudoers"; fi
if [ -n "$nopass_before" ]; then found "NOPASSWD found in$nopass_before — sorts before 50-auros-baseline, so our rule wins"; fi
if [ -n "$nopass_after" ]; then
  die "a NOPASSWD rule in$nopass_after sorts after 50-auros-baseline and would grant passwordless root — fix the ordering or remove the rule"
fi
did "no passwordless sudo escalation is in force"

install_file "$H/polkit-baseline.rules" /usr/share/polkit-1/rules.d/10-auros-baseline.rules 0644
did "polkit baseline: installing, removing or updating system software requires an administrator password even from an active local session"
found "everything else is left at the distribution default, so the policy modes (task A3) have a coherent baseline to tighten"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "kernel and crash-dump baseline"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
install_file "$H/sysctl-auros.conf" /usr/lib/sysctl.d/10-auros-hardening.conf 0644
did "kernel.dmesg_restrict=1 and kernel.kptr_restrict=1 — kernel addresses and the ring buffer are no longer readable by unprivileged users"

install_file "$H/coredump-auros.conf" /usr/lib/systemd/coredump.conf.d/10-auros.conf 0644
did "systemd-coredump Storage=none — crash backtraces still reach the journal, the memory image is not written to disk"
found "this is a privacy setting and a disk-floor setting: the small-disk profile's 64 GB has to hold two bootc deployments, which is what makes rollback possible"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "automatic updates for the userspace we own"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# On a bootc host there is no package manager updating the running system: the image is replaced
# wholesale, and the timer that does it belongs to the update agent (task A4). Installing
# dnf-automatic here would be theatre against a read-only, composed /usr.
if have_pkg dnf-automatic; then
  for u in dnf-automatic.timer dnf-automatic-install.timer dnf-automatic-notifyonly.timer dnf-automatic-download.timer; do
    if mask_unit "$u"; then
      did "masked $u — it cannot write to a composed read-only /usr, and a timer that fails nightly teaches people to ignore failures"
    fi
  done
else
  found "ABSENT    dnf-automatic — correct for a bootc host; the OS updates by image replacement, not by package"
fi

# What IS ours to keep patched automatically is the Flatpak set, which is where every application
# lives. ASSUMPTION: the Flathub remote and the application set are configured by the recipe layer,
# not here. This timer is a no-op on an image with no system Flatpaks.
install_file "$H/auros-flatpak-update.service" /usr/lib/systemd/system/auros-flatpak-update.service 0644
install_file "$H/auros-flatpak-update.timer"   /usr/lib/systemd/system/auros-flatpak-update.timer   0644
enable_unit auros-flatpak-update.timer
did "system Flatpaks update daily, with a 3-hour random delay so a 180-machine school does not update on one uplink at one instant"

found "the operating system's own updates are task A4's bootc timer — this script does not touch the update path, which is protected (check S10)"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "runtime assertions"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
install_file "$H/hardening-assert.sh" "${AUROS_LIBEXEC}/hardening-assert" 0755
install_file "$H/auros-hardening-assert.service" /usr/lib/systemd/system/auros-hardening-assert.service 0644
enable_unit auros-hardening-assert.service
did "every boot re-checks SELinux enforcing, sshd masked, firewalld default-deny, no NOPASSWD — and degrades the boot if any of them is not true"
found "ASSUMPTION for task A4: this script is also a valid greenboot required.d check (nonzero exit = fail). Referencing it from /etc/greenboot/check/required.d/ would make a machine whose hardening silently regressed roll itself back. This script does not write that reference — that directory belongs to A4."

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "protected set definition"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Copied into the image so that build/90-cleanup.sh can assert against it AFTER the build context has
# been deleted, and so that the published image carries its own definition of what may not be pruned.
# ASSUMPTION: auros-recipes/schema/PROTECTED.md does not exist yet. When it does, it is authoritative
# and hardening/protected.list should be generated from it rather than maintained alongside it.
install_file "$H/protected.list" "${AUROS_PREFIX}/protected.list" 0644
did "protected set definition shipped at ${AUROS_PREFIX}/protected.list"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
step "hardening summary"
# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# Nothing protected was touched by this script: it masks sshd and dnf-automatic and changes
# configuration. It removes no package. The full protected-set assertion runs in 90-cleanup.sh, after
# every other build step has had its turn.
for c in bootc systemctl; do
  have_cmd "$c" || die "$c is missing after hardening — something in this step removed part of the protected set"
done
did "protected set spot-check passed (bootc, systemctl present); the full check runs in 90-cleanup.sh"
did "hardening complete"

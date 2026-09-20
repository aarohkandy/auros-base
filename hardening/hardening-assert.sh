#!/usr/bin/bash
# AUROS — /usr/libexec/auros/hardening-assert
#
# The runtime half of build/10-hardening.sh. Everything the hardening step configured is asserted here
# against the running system, because a configuration file that is present but not in force is worse
# than no configuration at all: we would be telling a school their machines are locked down when they
# are not (matrix/checks.yaml B5's reasoning, applied to the hardening layer).
#
# Nothing in the build container can stand in for this. `getenforce` inside a build reports the
# BUILDER's SELinux state, not the image's, so asserting it at build time would be theatre.
#
# Contract: prints one line per assertion, exits 0 only if every assertion passed. That is deliberately
# the same contract greenboot requires of /etc/greenboot/check/required.d/*, so the update agent
# (task A4) can reference this script from there without a wrapper. This file does not install that
# reference — task A4 owns that directory.
set -uo pipefail

FAIL=0
pass() { printf 'auros-hardening-assert: PASS  %s\n' "$*"; }
fail() { printf 'auros-hardening-assert: FAIL  %s\n' "$*"; FAIL=1; }

# ── SELinux ──────────────────────────────────────────────────────────────────────────────────────
# /sys/fs/selinux/enforce is read directly rather than via getenforce, because libselinux-utils is
# not guaranteed to survive a recipe's prune list and an assertion that disappears with a tool is not
# an assertion.
if [ ! -e /sys/fs/selinux/enforce ]; then
  fail "SELinux is not enabled at all (/sys/fs/selinux/enforce absent) — the kernel booted without it"
elif [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ]; then
  pass "SELinux enforcing"
else
  fail "SELinux is permissive — expected enforcing"
fi

# ── sshd is off, and off in the way we said ──────────────────────────────────────────────────────
for u in sshd.service sshd.socket; do
  if ! systemctl list-unit-files "$u" >/dev/null 2>&1 || [ -z "$(systemctl list-unit-files --no-legend "$u" 2>/dev/null)" ]; then
    pass "$u not present on this system"
    continue
  fi
  state="$(systemctl is-enabled "$u" 2>/dev/null || true)"
  if [ "$state" = "masked" ]; then
    pass "$u masked"
  else
    fail "$u is '$state' — expected masked"
  fi
  if systemctl is-active --quiet "$u" 2>/dev/null; then
    fail "$u is ACTIVE — this machine is accepting inbound ssh"
  fi
done

# ── firewalld default-deny inbound ───────────────────────────────────────────────────────────────
if ! command -v firewall-cmd >/dev/null 2>&1; then
  fail "firewall-cmd missing — the firewall cannot be asserted, so it is not trusted"
elif ! systemctl is-active --quiet firewalld.service; then
  fail "firewalld is not running — inbound traffic is unfiltered"
else
  pass "firewalld running"
  zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
  if [ "$zone" = "auros" ]; then
    pass "default firewall zone is 'auros'"
  else
    fail "default firewall zone is '$zone' — expected 'auros'"
  fi
  target="$(firewall-cmd --permanent --zone=auros --get-target 2>/dev/null || true)"
  case "$target" in
    "%%REJECT%%"|REJECT|DROP) pass "zone auros target is '$target' (default-deny)" ;;
    *)                        fail "zone auros target is '$target' — expected REJECT or DROP" ;;
  esac
  svcs="$(firewall-cmd --zone=auros --list-services 2>/dev/null || true)"
  for s in $svcs; do
    case "$s" in
      dhcpv6-client|mdns) ;;
      *) fail "zone auros allows unexpected inbound service '$s'" ;;
    esac
  done
  [ -n "$svcs" ] && pass "zone auros inbound allowlist: $svcs"
  if firewall-cmd --zone=auros --list-ports 2>/dev/null | grep -q '[0-9]'; then
    fail "zone auros has open ports beyond the service allowlist: $(firewall-cmd --zone=auros --list-ports)"
  fi
fi

# ── sudo: no passwordless escalation anywhere in the effective configuration ─────────────────────
if grep -rlsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q .; then
  fail "NOPASSWD rule in force: $(grep -rlsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | tr '\n' ' ')"
else
  pass "no NOPASSWD sudo rule"
fi

if [ "$FAIL" -eq 0 ]; then
  printf 'auros-hardening-assert: all assertions passed\n'
else
  printf 'auros-hardening-assert: FAILED — the hardening layer is not in force on this machine\n'
fi
exit "$FAIL"

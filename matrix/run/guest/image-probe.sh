#!/usr/bin/env bash
# image-probe.sh — runs INSIDE the image under test, with no network, and prints KEY=VALUE lines.
# One podman invocation instead of a dozen. Never exits non-zero for a check result: the caller decides
# what a value means. It exits non-zero only when it cannot run at all.
#
# Usage (from the host):  podman run --rm -i --network=none --entrypoint= IMG bash -s -- SCOPE < image-probe.sh
set -uo pipefail
SCOPE=${1:-ghcr.io/aarohkandy}

emit() { printf '%s=%s\n' "$1" "${2-}"; }
exists() { [ -e "$1" ] && echo 1 || echo 0; }

# ── unit state, computed from the filesystem. No dbus in a container, so `systemctl --root=/` is the
#    only honest way to ask "would this be enabled on a real boot?".
unit_enabled() {
  local u=$1 out=''
  if command -v systemctl >/dev/null 2>&1; then
    out=$(systemctl --root=/ is-enabled "$u" 2>/dev/null | tail -1) || true
  fi
  if [ -z "$out" ]; then
    # Fallback: a .wants symlink is what "enabled" physically means.
    if ls /etc/systemd/system/*.wants/"$u" /usr/lib/systemd/system/*.wants/"$u" \
          /etc/systemd/system/*.requires/"$u" /usr/lib/systemd/system/*.requires/"$u" >/dev/null 2>&1; then out=enabled; else out=unknown; fi
  fi
  printf '%s' "$out"
}
unit_present() {
  local u=$1
  for d in /usr/lib/systemd/system /etc/systemd/system /lib/systemd/system; do
    [ -e "$d/$u" ] && { echo 1; return; }
  done
  echo 0
}

emit PROBE_OK 1
emit OS_ID "$( . /usr/lib/os-release 2>/dev/null && printf '%s %s' "${ID:-?}" "${VERSION_ID:-?}" )"

# ── S10: the protected set ───────────────────────────────────────────────────────────────────────
emit BOOTC_BIN "$(command -v bootc || echo '')"
# uupd.timer is probed but not required: Aurora preset-enables it and the Auros update agent
# deliberately leaves it inert while enabling bootc's own timer (build/30-update-agent.sh, D22).
# Two enabled updaters racing each other is worth seeing, which is why it is here at all.
for u in bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service uupd.timer \
         greenboot-healthcheck.service greenboot-set-rollback-trigger.service NetworkManager.service; do
  k=$(printf '%s' "$u" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')
  emit "UNIT_${k}_PRESENT" "$(unit_present "$u")"
  emit "UNIT_${k}_ENABLED" "$(unit_enabled "$u")"
done
emit SYSTEMD_BIN "$( [ -x /usr/lib/systemd/systemd ] && echo /usr/lib/systemd/systemd || command -v systemd || echo '' )"
emit GREENBOOT_REQUIRED_D "$(exists /etc/greenboot/check/required.d)"

# ── D8: signature policy, shipped INSIDE the image. This is the check that stops us from believing
#    `--enforce-container-sigpolicy` means anything.
emit POLICY_JSON "$(exists /etc/containers/policy.json)"
if [ -e /etc/containers/policy.json ]; then
  emit POLICY_JSON_B64 "$(base64 -w0 < /etc/containers/policy.json 2>/dev/null || base64 < /etc/containers/policy.json | tr -d '\n')"
fi
RD=''
for f in /etc/containers/registries.d/*.yaml /etc/containers/registries.d/*.yml; do
  [ -e "$f" ] || continue
  RD="$RD $f"
  if grep -qs 'use-sigstore-attachments: *true' "$f"; then emit REGISTRIES_D_SIGSTORE_TRUE 1; fi
  if grep -qs -- "$SCOPE" "$f"; then emit REGISTRIES_D_SCOPE_MATCH 1; fi
done
emit REGISTRIES_D_FILES "${RD# }"
emit PKI_KEYS "$(ls -1 /usr/lib/pki/containers/ 2>/dev/null | tr '\n' ',' )"

# ── S9: policy shape. The spec defines kiosk as a statement about the filesystem, so we ask the
#    filesystem rather than a config file.
SHELLS=''
for b in /usr/bin/plasmashell /usr/bin/gnome-shell /usr/bin/startplasma-wayland /usr/bin/startplasma-x11; do
  [ -e "$b" ] && SHELLS="$SHELLS $b"
done
emit DESKTOP_SHELL_BINARIES "${SHELLS# }"
# NEVER GUESS A PATH. This list is a guess, and on the pinned Aurora base it MATCHED NOTHING while
# /etc/systemd/system/display-manager.service existed — measured, run 35548005729. A hardcoded list
# that misses the display manager the image actually ships would make S9's kiosk branch assert
# "no display-manager binary" about a path nobody uses. So the list is the fast path, and the three
# lines under it are the ones that answer the question from the image instead of from memory:
# what display-manager.service points at, and what its ExecStart actually runs.
DMS=''
for b in /usr/bin/sddm /usr/bin/gdm /usr/sbin/gdm /usr/bin/lightdm /usr/bin/greetd /usr/libexec/gdm-binary \
         /usr/libexec/sddm /usr/bin/sddm-greeter /usr/bin/lxdm /usr/bin/xdm /usr/bin/ly; do
  [ -e "$b" ] && DMS="$DMS $b"
done
emit DISPLAY_MANAGER_BINARIES "${DMS# }"
emit DISPLAY_MANAGER_UNIT "$(exists /etc/systemd/system/display-manager.service)"
DM_UNIT=/etc/systemd/system/display-manager.service
emit DISPLAY_MANAGER_UNIT_TARGET "$(readlink -f "$DM_UNIT" 2>/dev/null || echo '')"
emit DISPLAY_MANAGER_EXECSTART "$(sed -n 's/^ExecStart=//p' "$DM_UNIT" 2>/dev/null | head -1)"
# The binary the unit would actually run, resolved from its own ExecStart rather than from a list.
DM_EXEC=$(sed -n 's/^ExecStart=//p' "$DM_UNIT" 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^[-@+!]*//')
emit DISPLAY_MANAGER_EXEC_PRESENT "$( [ -n "$DM_EXEC" ] && [ -e "$DM_EXEC" ] && echo 1 || echo 0 )"
emit DISPLAY_MANAGER_EXEC_PATH "$DM_EXEC"
# WHERE THE LOGIN MANAGER READS ITS CONFIG. The test wrapper writes autologin so that B7, B8 and B12
# have a live desktop session. On this base the display manager is /usr/bin/plasmalogin (measured,
# run 35550693484), which never reads /etc/sddm.conf.d/ — where the wrapper wrote it until run
# 35566336512 showed B7/B8/B12 failing with no session. It now writes /etc/plasmalogin.conf.d/ too;
# /etc/plasmalogin.conf, if the image ships one, is read LAST and would override it. Emit what EXISTS.
DMCONF=''
for d in /etc/sddm.conf.d /usr/lib/sddm/sddm.conf.d /usr/share/sddm/sddm.conf.d \
         /etc/plasmalogin.conf.d /usr/lib/plasmalogin/plasmalogin.conf.d \
         /etc/sddm.conf /etc/plasmalogin.conf; do
  [ -e "$d" ] && DMCONF="$DMCONF $d"
done
emit DISPLAY_MANAGER_CONF_PATHS "${DMCONF# }"
emit DISPLAY_MANAGER_AUTOLOGIN_FOUND "$(grep -rls '^\[Autologin\]' /etc/sddm.conf.d /etc/sddm.conf /etc/plasmalogin.conf.d /etc/plasmalogin.conf /usr/lib/sddm 2>/dev/null | tr '\n' ',')"
emit AUROS_POLICY_DIRS "$(ls -1 /usr/share/auros/policy 2>/dev/null | tr '\n' ',')"
emit AUROS_POLICY_UNITS "$(ls -1 /usr/lib/systemd/system/ 2>/dev/null | grep -c '^auros-policy-' || true)"
for m in open managed locked kiosk; do
  emit "POLICY_UNIT_${m}" "$(unit_present "auros-policy-${m}.service")"
done
# The real conventions, read from auros-base/build/20-policy.sh rather than guessed:
#   mode stamp           /usr/lib/auros/policy-mode
#   runtime assertion    /usr/libexec/auros/assert-policy [mode]
#   payload              /usr/share/auros/policy/<mode>/
emit POLICY_MODE_STAMP "$(cat /usr/lib/auros/policy-mode 2>/dev/null || echo '')"
emit POLICY_ASSERT_BIN "$( [ -x /usr/libexec/auros/assert-policy ] && echo /usr/libexec/auros/assert-policy || echo '' )"
emit POLICY_APPLY_BIN "$( [ -x /usr/libexec/auros/apply-policy ] && echo /usr/libexec/auros/apply-policy || echo '' )"
# greenboot runs '*.sh' from BOTH dirs; build/30-update-agent.sh installs ours in the /usr/lib one.
emit GREENBOOT_REQUIRED_COUNT "$(ls -1 /usr/lib/greenboot/check/required.d/*.sh /etc/greenboot/check/required.d/*.sh 2>/dev/null | wc -l | tr -d ' ')"

# ── S5 / S3: the removal report, wherever the prune engine put it.
REPORT=''
for p in /usr/share/auros/removal-report.json /usr/lib/auros/removal-report.json /etc/auros/removal-report.json; do
  [ -e "$p" ] && { REPORT=$p; break; }
done
emit REMOVAL_REPORT_PATH "$REPORT"
if [ -n "$REPORT" ]; then
  emit REMOVAL_REPORT_B64 "$(base64 -w0 < "$REPORT" 2>/dev/null || base64 < "$REPORT" | tr -d '\n')"
fi

# ── B12 groundwork (evaluated at runtime, but their absence is knowable statically too).
for d in org.kde.discover org.kde.plasma-systemmonitor org.kde.dolphin systemsettings org.kde.kcalc; do
  emit "DESKTOP_${d//[.-]/_}" "$( ls /usr/share/applications/${d}.desktop >/dev/null 2>&1 && echo 1 || echo 0 )"
done
emit FLATPAK_BIN "$(command -v flatpak || echo '')"
emit FLATHUB_REMOTE_FILE "$(ls -1 /etc/flatpak/remotes.d/ 2>/dev/null | tr '\n' ',')"

# ── S3 / S5: the full installed package set, which is how we measure what was removed instead of
#    trusting a number someone wrote into a report.
if command -v rpm >/dev/null 2>&1; then
  emit RPM_COUNT "$(rpm -qa 2>/dev/null | wc -l | tr -d ' ')"
  echo "---RPM-NAMES---"
  rpm -qa --qf '%{NAME}\t%{SIZE}\n' 2>/dev/null | sort
  echo "---END---"
else
  emit RPM_COUNT 0
fi
exit 0

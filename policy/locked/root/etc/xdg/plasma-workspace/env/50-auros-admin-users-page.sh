# Auros policy (managed/locked) — sourced by startplasma for every Plasma session, before the session's
# environment is handed to D-Bus and systemd (plasma-workspace startplasma.cpp: runEnvironmentScripts,
# then syncDBusEnvironment).
#
# An aurosadmin member's session skips /etc/kde5rc, which is the file that hides the Users page
# (kcm_users) from everyone else. Owner decision A4, control repo docs/ACCOUNTS.md §3.
case " $(id -nG 2>/dev/null) " in
  *" aurosadmin "*) export KDE_SKIP_KDERC=1 ;;
esac

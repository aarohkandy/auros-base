#!/bin/sh
# Auros — installed to /etc/xdg/plasma-workspace/env/10-auros-flatpak-paths.sh
# Sourced by Plasma at session start.
#
# WHY THIS EXISTS: every application on this system comes from Flathub (spec §3).  Flatpak exports the
# .desktop files of installed apps under /var/lib/flatpak/exports/share and ~/.local/share/flatpak/
# exports/share.  Those paths reach the start menu through /etc/profile.d/flatpak.sh — which is sourced
# by a LOGIN shell.  A graphical session started by SDDM is not always a login shell, and when it is not,
# an app the user just installed in Discover does not appear in the start menu.  The user's conclusion is
# "it did not install", and the fix they would be told online is a terminal command.  That is precisely
# the failure D4 forbids, so we make the session set the path itself.
#
# Idempotent: adds each path only if it is not already present.

for _auros_dir in /var/lib/flatpak/exports/share "$HOME/.local/share/flatpak/exports/share"; do
    case ":${XDG_DATA_DIRS:-}:" in
        *":$_auros_dir:"*) ;;
        *) XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:$_auros_dir" ;;
    esac
done
export XDG_DATA_DIRS
unset _auros_dir

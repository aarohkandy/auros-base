# Locked

**A full desktop that cannot be changed from the seat. Changes arrive as a new image.**

## Who this is for

An exam room. A public-access machine. A cart of laptops that goes home with students. Anywhere the
honest answer to "who might try to get around this" is "somebody with time and an internet search".

## What a student can do

Use the computer normally. It is a full desktop with all of your applications, your language, your
look. It does not feel like a locked machine to somebody who is using it to do their work.

## What nobody can do at the machine -- including your IT person

- Install or remove any system software.
- Change the network configuration, or turn networking off.
- Start, stop, disable or mask any system service, **including the automatic update**.
- Get root, by any route: `sudo`, `pkexec`, `su`, `machinectl`, `systemd-run`.
- Change the time, the hostname, the language, or the accounts on the machine.
- Reach a terminal from inside a KDE application -- Dolphin's "Open Terminal Here", Kate's terminal
  panel, and the run-command box are all switched off. We check this by actually trying it on every
  build: the test machine asks a KDE application to run a command and fails the build if anything
  runs. It is not a setting we tick and hope for.

In `managed` these things ask for a password. In `locked` the answer is no, and there is no password
that changes it. The IT account can still authenticate for a few specific things, but the ordinary
user's answer is refusal rather than a prompt.

## How you change a locked machine, then

You change the recipe and the machine picks up the new image on its next reboot. That is the whole
model: the fleet is edited in one file in one git repository, not at thirty keyboards.

## What locked deliberately does NOT do, stated plainly

**It does not remove the terminal from the machine.** A student who knows Linux can still open a shell
and run things as themselves, in their own home directory. What they cannot do with that shell is
anything on the list above -- no root, no system change, no stopping updates. A Flatpak they install
into their own home folder has no privileges and disappears when the profile is reset.

If "no shell at all" is the requirement, that is `kiosk`, and it is a different machine.

**The KDE restriction covers KDE applications, not the whole machine.** It is a toolkit-level
control, not a kernel one, and it does not delete `/usr/bin/bash`. A student who reaches a shell by
some other route still cannot do anything on the list above -- that is what the rest of the mode is
for -- but "no shell at all" is `kiosk`, not this.

**It also assumes physical security of the boot process.** Anyone who can restart the laptop and edit
the boot menu can get root on any Linux machine, ours included, unless the boot menu itself has a
password. That password is part of the base image's hardening, not this policy mode. If your machines
go home with students, confirm it is set.

## Cost to you

A locked machine cannot join a new Wi-Fi network by itself. If the laptop leaves the building and needs
to get onto a home network, locked is the wrong mode -- use `managed`.

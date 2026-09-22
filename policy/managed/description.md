# Managed

**Anyone can use it. Changing it asks for the IT password, at the machine.**

## Who this is for

The default for a school. A shared classroom machine, a library machine, a loaner. Students use it all
day; the IT person can sit down at any of them, type their password, and fix something without
rebuilding anything or going near a terminal.

## What a student can do

Use the computer. Everything on it, every app you installed, files, printing, the browser, log in and
log out, shut it down.

## What a student cannot do without the IT password

- Install or remove software -- system packages, Flatpaks from the software centre, anything.
- Change the machine's network configuration, or turn Wi-Fi networking off.
- Start, stop or disable any system service, including the automatic update.
- Get root: no `sudo`, no `pkexec`, no administrator rights of any kind.
- Change the machine's time, hostname, language, or the user accounts on it.
- Open the System Settings pages that control those things -- they are hidden, so the machine does not
  offer a door it is going to slam.

The IT account (the recipe's `admin`) sees one page the students do not: **Users**, where it changes
anyone's password, including its own, after typing its own password. The one account change a student
makes is their own password: the first time they sign in, that page opens for them to choose it.

## What happens when they try

A password box appears and asks for an **administrator's** password. The student does not have it.
The IT person does, and typing it once allows exactly the one thing that was asked for -- there is no
fifteen-minute window afterwards where anything else goes through.

## Why you might choose `locked` instead

Managed's security is the IT password. If that password is on a sticky note in the staff room, managed
becomes open. `locked` removes the password as a mechanism at the seat entirely: nothing can be changed
in front of the machine, by anybody, and changes reach the fleet as a new image instead.

Choose managed when you want to be able to fix a machine by walking up to it. Choose locked when you
would rather nobody could.

# Open

**A normal computer. The person using it is its administrator.**

## Who this is for

A teacher's own laptop. A staff machine. The one dense developer desktop. Anyone whose machine is
theirs, who will install things, and who you would not want to be a helpdesk ticket for.

## What the person using it can do

Everything. Install software, change the network, change the language, add printers, open a terminal
if they want one, and turn off the automatic updates if they decide to.

Open is not "unhardened". The base image's hardening is still there, updates still arrive on their own,
the image is still signed and verified at install, and the previous image is still on disk to roll back
to. Open means **we did not add a lock on top of that** -- it does not mean we took the floor away.

## What it does NOT do

It does not stop the person using the machine from breaking it. If that person is a fourteen-year-old
who has just discovered what a terminal is, this is the wrong mode and `managed` is the right one.

## The one thing to know before choosing it

If you give a classroom set of thirty machines `open`, you have thirty machines in thirty different
states by March. The value of the product is that every machine is the same machine. Open is correct
for a handful of individual people, and wrong for a fleet.

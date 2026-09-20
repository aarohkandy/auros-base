# Kiosk

**One application, full screen, from power-on. There is no desktop on the machine.**

## Who this is for

A library catalogue terminal. A sign-in station at reception. A display in a corridor. A room full of
machines that exist to run one browser at one address and nothing else.

## What it does

The machine powers on and the application is there. There is no login screen, no desktop, no taskbar,
no start menu, no file manager and no way to minimise the application, because none of those things
exist on the image.

This is not a desktop with the icons hidden. The desktop shell and the login manager have been
**deleted from the image**. `Ctrl+Alt+F2` does not produce a text prompt, because the text consoles are
switched off too. The account the application runs as has no shell at the end of it.

## What you have to decide before ordering it

**Which application.** A kiosk image with no application named is a brick, so the build refuses to
produce one. You tell us the application and, for a browser, the address.

## What it costs you -- both of these are real

**The image is bigger than you would expect for something this small.** A kiosk machine and a full
classroom desktop are built from the same base image, on purpose. That is what lets a security fix
reach every machine you own from one rebuild. The price is that the kiosk image still carries shared
libraries it no longer has an application for. We will tell you the real measured size. We will not
quote you the size of a minimal image we did not build.

**A broken kiosk machine is recovered by reimaging it, not by fixing it.** Because there is no console
and no desktop, there is nothing to log into when something goes wrong. The machine repairs itself
automatically if an update fails -- it rolls back to the previous image on its own -- but if you need to
get into one, you restart it and use the boot menu, or you reimage it. For an appliance in a lobby this
is usually the right trade. Confirm that it is, for you, before you choose it.

## What you still get

Automatic nightly-built updates, signature verification at install, and automatic rollback if an
update fails to boot -- exactly the same as every other mode. A kiosk is not a lesser machine; it is
the same machine with one job.

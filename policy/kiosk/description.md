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
**deleted from the image**. `Ctrl+Alt+F2` does not produce a text prompt, because every text console
on the machine is switched off -- so the key combination, if it does anything at all, reaches a blank
screen and never a login. The account the application runs as has no shell at the end of it.

We check both halves of that on every build, on the running machine: that no text console is enabled
*and* that none is running, and that the compositor was started without the option that would let it
switch away. It is not a setting we tick and hope for.

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

## One honest footnote about how the screen is drawn

Normally the machine uses a compositor called **cage**, which we start without the option that binds
`Ctrl+Alt+F2` at all -- so on that machine the key combination is dead twice over: the compositor
never listens for it, and there is no console for it to reach.

Very occasionally cage is not available when your image is built. The alternative, **weston**, has no
equivalent option: it always listens for `Ctrl+Alt+F2`. The promise above still holds -- the key lands
on a blank screen, because every console is off -- but it holds for one reason instead of two, and
that is a weaker machine than the one we describe. So **we do not ship it silently**: the build stops
and a human has to decide, and if we do ship it, the machine reports the difference and you will see
it named in your build report as `weston-vt-switch-possible`.

## What you still get

Automatic nightly-built updates, signature verification at install, and automatic rollback if an
update fails to boot -- exactly the same as every other mode. A kiosk is not a lesser machine; it is
the same machine with one job.

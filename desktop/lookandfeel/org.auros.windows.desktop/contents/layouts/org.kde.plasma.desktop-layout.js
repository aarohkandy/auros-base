// Auros — the Windows-shaped Plasma layout.
//
// This file is the taskbar.  Plasma's panel arrangement is not a config file you can drop in /etc; it
// lives in a generated per-user file (plasma-org.kde.plasma.desktop-appletsrc) whose contents are
// produced by running a layout script through plasmashell.  So the shippable, image-side artefact is
// this script, and /usr/libexec/auros/auros-first-run feeds it to plasmashell once per user.
//
// IDEMPOTENT BY CONSTRUCTION: it removes every existing panel before building ours.  Running it twice
// gives you one taskbar, not two.  That property is what lets the first-run service be safe to re-run
// and what lets a support person repair a panel a user has dismantled, from the GUI, without a terminal.
//
// The layout, left to right, is Windows 7/10 order:
//
//   [Start] [ task buttons ..................................... ] [tray] [clock] [show desktop]
//

var existingPanels = panels();
for (var i = 0; i < existingPanels.length; ++i) {
    existingPanels[i].remove();
}

var panel = new Panel("org.kde.panel");
panel.location = "bottom";
// 44 logical pixels.  Windows 10's taskbar is 40.  We go slightly taller because the clock shows the
// date under the time (as Windows does) and because the target user is frequently 62 years old on a
// 1366x768 screen.  Legibility beats pixel thrift.
panel.height = 44;
panel.hiding = "none";
// Flush with the bottom edge, as the Windows taskbar is.  Unset, a scripted panel floats with a gap
// under it: floating is a Panel property (plasma-workspace shell/scripting/panel.h, Q_PROPERTY floating)
// whose getter falls back to readEntry("floating", true) (shell/scripting/panel.cpp).
panel.floating = false;

// ── Start ────────────────────────────────────────────────────────────────────────────────────────
// Kickoff is the Windows-7-shaped menu: search box at the top, categories, power buttons.  The
// alternatives (Application Dashboard, Kicker) are respectively a full-screen grid and a bare cascading
// menu, and neither is what the muscle memory expects.
panel.addWidget("org.kde.plasma.kickoff");

// ── Task buttons ─────────────────────────────────────────────────────────────────────────────────
// Icon-only grouped buttons, which has been the Windows default since Windows 7 ("always combine,
// hide labels").  Pinned entries use preferred:// URLs so the pins follow whatever the RECIPE chose as
// the browser and file manager — this layer must not hardcode an application a customer did not buy.
var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "preferred://filemanager",
    "preferred://browser",
    "applications:org.kde.discover.desktop"
]);
// Never group windows so aggressively that a user cannot find the one they were typing in.
tasks.writeConfig("groupingStrategy", 1);
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("showOnlyCurrentScreen", false);

// ── Spacer, so the tray and clock sit hard right the way they do on Windows ───────────────────────
panel.addWidget("org.kde.plasma.marginsseparator");

// ── Input method indicator ───────────────────────────────────────────────────────────────────────
// The same condition as upstream's default panel (plasma-desktop layout-templates/
// org.kde.plasma.desktop.defaultPanel/contents/layout.js), copied verbatim including the list: for
// languages that pull in an input method (Marathi, Hindi, Tamil, ...) Plasma's own default panel adds
// kimpanel, so a user can see and switch how they are typing.  Without it our panel was the odd one out.
var langIds = ["as", "bn", "bo", "brx", "doi", "gu", "hi", "ja", "kn", "ko", "kok", "ks", "lep",
               "mai", "ml", "mni", "mr", "ne", "or", "pa", "sa", "sat", "sd", "si", "ta", "te",
               "th", "ur", "vi", "zh_CN", "zh_TW"];
if (langIds.indexOf(languageId) != -1) {
    panel.addWidget("org.kde.plasma.kimpanel");
}

// ── System tray ──────────────────────────────────────────────────────────────────────────────────
// Network, volume, battery, removable media, clipboard.  This is the notification area.
panel.addWidget("org.kde.plasma.systemtray");

// ── Clock ────────────────────────────────────────────────────────────────────────────────────────
var clock = panel.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateDisplayFormat", "BelowTime");

// ── Show desktop ─────────────────────────────────────────────────────────────────────────────────
// The sliver at the far right-hand end of the Windows taskbar.
panel.addWidget("org.kde.plasma.showdesktop");

// We deliberately do NOT set a wallpaper here.  Branding and wallpaper belong to the theme layer
// (the `theme-generate` skill and the recipe's `branding:` block); setting an image path this layer
// does not ship would give a customer a black desktop the day the theme layer changed its filenames.

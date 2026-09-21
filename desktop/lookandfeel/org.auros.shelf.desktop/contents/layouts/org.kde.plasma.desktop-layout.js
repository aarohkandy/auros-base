// Auros — the "shelf" layout: browser-first, in the shape a pupil already knows from a school laptop.
//
// Why it exists: most US K-12 pupils learn on a Chromebook, and our first customer profile already lives
// in Google Workspace or a browser-based system (SPEC §1).  For them the computer IS the browser, and the
// screen they know has a launcher at the bottom left, pinned apps centred on the shelf, and status at the
// bottom right.  Evidence and the ranking are in the control repo, docs/DESKTOP-LAYOUTS.md.
//
// We copy the SHAPE, not the look (same rule as org.auros.windows.desktop, prohibition §4.2): Breeze,
// Plasma's own launcher, no imitation icons or names.
//
//   [Launcher] ........ [ browser | files | software ] ........ [tray] [clock]
//
// Same contract as the Windows layout, because auros-first-run feeds whichever layout it is given
// through the same evaluateScript call: idempotent (removes every panel first), no wallpaper, pins by
// preferred:// so the recipe's chosen browser and file manager are what appear.
//
// Every applet id and config key below was checked against KDE source (plasma-desktop and
// plasma-workspace master, 2026-09-20); see docs/DESKTOP-LAYOUTS.md for the list.  Still true of
// this file: it has never been run by a real plasmashell.  Nothing here has been seen on a screen.

var existingPanels = panels();
for (var i = 0; i < existingPanels.length; ++i) {
    existingPanels[i].remove();
}

var panel = new Panel("org.kde.panel");
panel.location = "bottom";
panel.height = 48;
panel.hiding = "none";
// The shelf this imitates is attached to the screen edge, not floating above it.
panel.floating = false;

// ── Launcher, bottom left ────────────────────────────────────────────────────────────────────────
// Kickoff, with the app list as a grid rather than a list, because the launcher people know is a grid
// of app icons under a search box.  0 = Grid, 1 = List (kickoff main.xml).
var launcher = panel.addWidget("org.kde.plasma.kickoff");
launcher.currentConfigGroup = ["General"];
launcher.writeConfig("favoritesDisplay", 0);
launcher.writeConfig("applicationsDisplay", 0);

// ── Pinned apps, centred ─────────────────────────────────────────────────────────────────────────
// Two expanding spacers either side of the task manager are how Plasma centres it.
panel.addWidget("org.kde.plasma.panelspacer");

var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
// The browser first: in this layout it is the main application, not one of several.
tasks.writeConfig("launchers", [
    "preferred://browser",
    "preferred://filemanager",
    "applications:org.kde.discover.desktop"
]);
tasks.writeConfig("groupingStrategy", 1);
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("showOnlyCurrentScreen", false);

panel.addWidget("org.kde.plasma.panelspacer");

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

// ── Status area, bottom right ────────────────────────────────────────────────────────────────────
// Network, volume, battery.  Wi-Fi from here is one of check B12's four tasks, so the tray is not
// optional in any Auros layout.
panel.addWidget("org.kde.plasma.systemtray");

var clock = panel.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateDisplayFormat", "BelowTime");

// No wallpaper, for the reason given at the end of the Windows layout.

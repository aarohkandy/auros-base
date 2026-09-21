// Auros — the top-bar-and-dock layout, in the shape a Mac user already knows.
//
// The owner asked for it by name.  Evidence (and the lack of it) is in the control repo,
// docs/DESKTOP-LAYOUTS.md §2.8: the realistic user is someone on an orphaned 2017-2018 Mac.
//
// We copy the SHAPE, not the look (same rule as org.auros.windows.desktop, prohibition §4.2): Breeze,
// Plasma's own launcher and icons, no imitation logo, nothing named after anybody else's product.
//
//   top:     [menu] [the active app's menus] ............................ [tray] [clock]
//   bottom:                 [ browser | files | software | open apps ]
//
// Same contract as the other layouts, because auros-first-run feeds whichever layout it is given
// through the same evaluateScript call: idempotent (removes every panel first), no wallpaper, pins by
// preferred:// so the recipe's chosen browser and file manager are what appear.
//
// Every applet id, config key and panel property below was checked against KDE source (plasma-desktop
// and plasma-workspace master, 2026-09-20): applet ids from plasma_add_applet() in each CMakeLists,
// panel properties from shell/scripting/panel.cpp.  It has never been run by a real plasmashell.
// Nothing here has been seen on a screen.

var existingPanels = panels();
for (var i = 0; i < existingPanels.length; ++i) {
    existingPanels[i].remove();
}

// ── Top bar ──────────────────────────────────────────────────────────────────────────────────────
var top = new Panel("org.kde.panel");
top.location = "top";
// Upstream's own top-bar template (plasma-desktop layout-templates/org.kde.plasma.desktop.appmenubar)
// uses gridUnit * 1.5.  32 is a little taller than that, for the same legibility reason the Windows
// layout gives: a 1366x768 screen and a user who may be 62.
top.height = 32;
top.hiding = "none";
// A menu bar is attached to the screen edge.  floating is a Panel property (shell/scripting/panel.h,
// Q_PROPERTY floating); unset, it defaults to true (panel.cpp, readEntry("floating", true)).
top.floating = false;

// The menu.  Kickoff, not a copy of anybody's logo menu: it is where apps, settings and power live,
// and B12's windows-shape check requires it (desktop/assert-zero-terminal.sh reads the panel for it).
top.addWidget("org.kde.plasma.kickoff");

// The global menu: the focused application's own File/Edit/View menus, in the top bar.  The kded
// module that collects them autoloads (plasma-workspace appmenu/appmenu.json X-KDE-Kded-autoload).
// Applications that do not export their menus keep them in their own window, so nothing is lost.
top.addWidget("org.kde.plasma.appmenu");

// Pushes status and the clock hard right.  panelspacer [General] expanding defaults to true.
top.addWidget("org.kde.plasma.panelspacer");

// Input method indicator — the same condition as upstream's default panel
// (plasma-desktop layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js), copied
// verbatim including the list, so a Marathi or Hindi user can see and switch their typing method.
var langIds = ["as", "bn", "bo", "brx", "doi", "gu", "hi", "ja", "kn", "ko", "kok", "ks", "lep",
               "mai", "ml", "mni", "mr", "ne", "or", "pa", "sa", "sat", "sd", "si", "ta", "te",
               "th", "ur", "vi", "zh_CN", "zh_TW"];
if (langIds.indexOf(languageId) != -1) {
    top.addWidget("org.kde.plasma.kimpanel");
}

// Network, volume, battery.  Wi-Fi from here is one of check B12's four tasks.
top.addWidget("org.kde.plasma.systemtray");

var clock = top.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
// BesideTime is a valid choice (digital-clock main.xml, dateDisplayFormat: Adaptive/BesideTime/
// BelowTime); a 32px bar has no room for the date below the time.
clock.writeConfig("dateDisplayFormat", "BesideTime");

// ── Dock ─────────────────────────────────────────────────────────────────────────────────────────
var dock = new Panel("org.kde.panel");
dock.location = "bottom";
dock.height = 56;
dock.hiding = "none";
// Centred, and only as long as its icons: alignment "center" (anything but left/right) and
// lengthMode "fit" (panel.cpp setAlignment / setLengthMode).  A dock sits a little off the edge, so
// this one floats — the only Auros panel that does.
dock.alignment = "center";
dock.lengthMode = "fit";
dock.floating = true;

var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "preferred://browser",
    "preferred://filemanager",
    "applications:org.kde.discover.desktop"
]);
tasks.writeConfig("groupingStrategy", 1);
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("showOnlyCurrentScreen", false);

// No wallpaper, for the reason given at the end of the Windows layout.

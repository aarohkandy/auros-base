// Auros — the "simple" layout: three big buttons, a menu, and the clock.
//
// Who it is for: a six-year-old, an eighty-year-old at a library digital-skills session, an adult on
// their first computer.  The same need that produced Apple's Assistive Access and Windows' multi-app
// kiosk: fewer things on screen, each of them larger.  Evidence and ranking are in the control repo,
// docs/DESKTOP-LAYOUTS.md.
//
//   [Menu]   [  BROWSER  ] [  FILES  ] [  HELP  ]   .........................   [tray] [clock]
//
// This is a LAYOUT, not a lockdown.  It puts three things in front of the user; it does not stop them
// opening a fourth from the menu.  A recipe that needs "only these apps exist" has two honest tools
// for that already: prune (the apps are not on the disk) and policy: locked.  Hiding the menu here
// would only move the problem, and would leave a machine with no GUI path to settings, which is how
// check B12 fails.
//
// Same contract as the Windows layout: idempotent (removes every panel first), no wallpaper, pins by
// preferred:// so the recipe's chosen browser and file manager are what appear.
//
// Every applet id and config key below was checked against KDE source (plasma-desktop and
// plasma-workspace master, 2026-09-20); see docs/DESKTOP-LAYOUTS.md.  Still true of this file: it has
// never been run by a real plasmashell.  Nothing here has been seen on a screen.

var existingPanels = panels();
for (var i = 0; i < existingPanels.length; ++i) {
    existingPanels[i].remove();
}

var panel = new Panel("org.kde.panel");
panel.location = "bottom";
// 72 logical pixels, against the Windows layout's 44.  Icon size in an icons-only task manager follows
// panel thickness, so this is what makes the three buttons big.  On a 1366x768 screen it costs about
// 4% more of the height than the Windows layout, which is the trade this layout exists to make.
panel.height = 72;
panel.hiding = "none";
panel.floating = false;

// ── Menu ─────────────────────────────────────────────────────────────────────────────────────────
// Kept, deliberately (see the header): it is the way to settings, Wi-Fi help, and log out.  Its
// favourites are shown as a grid of large icons rather than a list.  0 = Grid (kickoff main.xml).
var menu = panel.addWidget("org.kde.plasma.kickoff");
menu.currentConfigGroup = ["General"];
menu.writeConfig("favoritesDisplay", 0);
menu.writeConfig("applicationsDisplay", 0);

// ── The three buttons ────────────────────────────────────────────────────────────────────────────
// The web, your files, and the Auros welcome/help app — not the app store.  An app store is the one
// thing on a shared "simple" machine that turns into a support call.  A recipe that wants different
// three is a recipe field (docs/DESKTOP-LAYOUTS.md, "how a recipe selects a layout").
var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "preferred://browser",
    "preferred://filemanager",
    "applications:org.auros.Welcome.desktop"
]);
tasks.writeConfig("groupingStrategy", 1);
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("showOnlyCurrentScreen", false);
// Twice the default gap between buttons, so a shaky hand or a small finger hits the one it meant.
tasks.writeConfig("iconSpacing", 2);

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

// ── Tray and clock ───────────────────────────────────────────────────────────────────────────────
// Wi-Fi from the tray is one of check B12's four tasks, so the tray stays in every Auros layout.
panel.addWidget("org.kde.plasma.systemtray");

var clock = panel.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateDisplayFormat", "BelowTime");

// No show-desktop button and no pager: each is one more thing to press by accident and then not
// understand what happened.  No wallpaper, for the reason given at the end of the Windows layout.

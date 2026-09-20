// Auros — installed to /usr/share/plasma/plasma-welcome/extra-pages/02-AurosWindowsPrograms.qml
//
// The honest page.  Prohibition §4.2 says we never claim an app migrates when it does not, and that we
// say so "everywhere, prominently".  A welcome wizard that showed only the good news would be exactly
// the place that rule was written about, so the bad news gets its own screen, before the user has
// invested a week in the machine.
//
// See desktop/EXE-COMPATIBILITY.md for the long form, and DECISIONS.md D16 for why Office and Adobe are
// named here rather than footnoted.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.Page {
    title: "Your old Windows programs"

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            Layout.fillWidth: true
            level: 2
            wrapMode: Text.WordWrap
            text: "Your files came across. Your programs did not."
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Documents, pictures, downloads, bookmarks, printers and Wi-Fi settings were copied over. Programs are different: a program installed on Windows cannot be moved to this computer, in the same way a program from a phone cannot be moved to a laptop. You install the replacement here instead, from Discover, and it is usually free."
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: true
            type: Kirigami.MessageType.Warning
            text: "Microsoft Office and Adobe programs do not run on this computer, and we do not have a way to make them run. If you need Office, use Office on the web in your browser, or keep one Windows machine for it. Anyone who tells you otherwise has not tried it."
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Some simple Windows programs can be run here through a tool called Bottles, if your organisation asked for it. It is not a guarantee and it is not fast on a computer this old. Test the exact program you care about before you rely on it, and ask us first if it matters."
        }

        Item { Layout.fillHeight: true }
    }
}

// Auros — installed to /usr/share/plasma/plasma-welcome/extra-pages/01-AurosOrientation.qml
//
// plasma-welcome loads every QML file in extra-pages/ whose name is prefixed with a number and a dash,
// in numeric order, and shows them just before its own "Get Involved" page.  The root item must inherit
// Kirigami.Page.
//
// This is the "here is where things are" screen: one screen, no scrolling on a 1366x768 display, and it
// names the four things a person coming off Windows looks for in the first five minutes.
//
// NOT LOCALISED YET, and that is a real gap rather than an oversight — see desktop/README.md, GAP-2.
// Strings are plain literals on purpose: i18n() is only defined when a KLocalizedContext is attached to
// the QML engine, and a page that throws on load is worse than a page in English.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.Page {
    title: "Where things are"

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading {
            Layout.fillWidth: true
            level: 2
            wrapMode: Text.WordWrap
            text: "Four things, and then you know your way around."
        }

        Repeater {
            model: ListModel {
                ListElement {
                    icon: "start-here-kde-symbolic"
                    heading: "The button at the bottom left is the Start menu"
                    body: "Everything installed on this computer is in there. Start typing to search, exactly as you would on Windows. Tapping the Windows key on the keyboard opens it too."
                }
                ListElement {
                    icon: "system-file-manager"
                    heading: "Your files are in Documents, Pictures, Downloads and Desktop"
                    body: "The same names as before. Open the folder icon on the taskbar, or press the Windows key and E. Double-click to open anything — single-clicking only selects it."
                }
                ListElement {
                    icon: "plasmadiscover"
                    heading: "Install programs from Discover"
                    body: "It is the shopping-bag icon on the taskbar. Search for what you want and press Install. You will never be asked for a command, and you do not need to find anything on the internet to download."
                }
                ListElement {
                    icon: "update-none"
                    heading: "Updates happen by themselves, overnight"
                    body: "There is no update button to remember and nothing to click. If an update ever goes wrong, this computer puts the previous version back on its own the next time it starts."
                }
            }

            delegate: Kirigami.AbstractCard {
                Layout.fillWidth: true
                contentItem: RowLayout {
                    spacing: Kirigami.Units.largeSpacing
                    Kirigami.Icon {
                        source: model.icon
                        Layout.preferredWidth: Kirigami.Units.iconSizes.large
                        Layout.preferredHeight: Kirigami.Units.iconSizes.large
                        Layout.alignment: Qt.AlignTop
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Heading {
                            Layout.fillWidth: true
                            level: 4
                            wrapMode: Text.WordWrap
                            text: model.heading
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: model.body
                        }
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            text: "You can open this guide again at any time: Start menu → Help and Getting Started."
        }
    }
}

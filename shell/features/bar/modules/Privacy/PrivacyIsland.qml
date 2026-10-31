pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import qs.common

// Privacy island: ledger of which apps are using the microphone,
// camera and screen right now. One row per app no matter how many
// targets it holds: app icon, app name with media kinds, window titles,
// and the used targets stacked as color-coded glyphs on the right
// (mic-on green, camera purple, screen-capture orange). Glyphs with a
// PipeWire handle are toggle buttons (cut + remember, click again to
// re-link); handle-less ones stay plain. The module feeds live rows;
// the island closes itself when the last indicator goes idle.
//
// NOTE: anchorItem / anchorWindow / barPosition live on the shared
// host, never here - redeclaring them shadows the host wiring and
// silently breaks positioning.
Item {
  id: root

  // Live rows from the module:
  // [{app, icon, targets: [{key, icon, colorKey, label, classText,
  // titleText, actionable, linkIds, severed}], line1, line2}].
  property var rows: []

  // A target button was clicked: per-node access toggle in the module
  // (cut + remember pairs, or re-link them).
  signal invokeRequested(string app, string key)

  readonly property int rowH: 52
  readonly property int headH: 34
  // Fixed right column: three 22px hit boxes + gaps, right-aligned so
  // shorter stacks hug the card edge instead of drifting.
  readonly property int stackW: 3 * 22 + 2 * 5

  property int islandContentWidth: 380
  // The empty state carries a glyph above its line, so the reserve comes
  // from its measured column instead of a fixed row height.
  property int islandContentHeight: 2 * Ui.outerPad + root.headH + Ui.s
    + (root.rows.length > 0 ? root.rows.length * root.rowH : Math.ceil(empty.implicitHeight))
  property bool islandSelfAnimating: false
  property var islandHost: null

  // Content lent to the shared host: incubated on show, destroyed
  // after the close fade. The card sizes from islandContentHeight above.
  Column {
    anchors.fill: parent
    spacing: Ui.s

    // Section header mirrors the network/color-picker convention: small
    // foreground_1 glyph at 70% before the caps title.
    Item {
      width: parent.width
      height: root.headH

      Row {
        id: headRow

        spacing: Ui.s

        Icon {
          anchors.verticalCenter: parent.verticalCenter
          name: "incognito"
          colorKey: "foreground_1"
          size: 14
          opacity: 0.7
        }

        Title {
          level: 2
          anchors.verticalCenter: parent.verticalCenter
          text: "PRIVACY"
        }
      }

      Title {
        level: 4
        width: parent.width
        anchors.top: headRow.bottom
        anchors.topMargin: 2
        text: "Live microphone, camera and screen use."
      }
    }

    Column {
      width: parent.width
      spacing: 0
      visible: root.rows.length > 0

      Repeater {
        model: root.rows

          delegate: Item {
            id: rowItem

            required property var modelData
            required property int index

            width: parent.width
            height: root.rowH

          // Zebra striping (Finder-style) from the shared row: even rows
          // carry the faint band. Decorative - the rows below are info,
          // not controls.
          ZebraRow {
            anchors.fill: parent
            rowIndex: index
            interactive: false
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Ui.s
            anchors.rightMargin: Ui.s
            spacing: Ui.s

            Item {
              width: 24
              height: 24
              anchors.verticalCenter: parent.verticalCenter

              IconImage {
                anchors.centerIn: parent
                width: 24
                height: 24
                source: String(modelData.icon ?? "")
                visible: source !== ""
                asynchronous: true
              }
            }

            Column {
              width: parent.width - 24 - root.stackW - 2 * parent.spacing - 2 * Ui.s
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1

              // App title continued with a target-colored dot and the
              // media class per used target ("Discord • Stream/Input/Video").
              // Clipped, not just elided: rich text can outgrow elision
              // and paint over the icon stack.
              Text {
                width: parent.width
                text: String(modelData.line1 ?? "")
                textFormat: Text.RichText
                font.family: Ui.fontFamily
                font.pixelSize: Ui.fontS
                color: Ui.solid("foreground_0")
                elide: Text.ElideRight
                clip: true
              }

              Title {
                level: 4
                width: parent.width
                text: String(modelData.line2 ?? "")
                elide: Text.ElideRight
                visible: text !== ""
              }
            }

            Item {
              width: root.stackW
              height: parent.height

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5

                Repeater {
                  model: modelData.targets ?? []

                  // Actionable targets (pipewire streams, mic mute) are
                  // buttons: hover wash, pointer cursor, click invokes.
                  // Anything without a handle (direct-V4L2 watchers) stays
                  // a plain glyph in the same style.
                  delegate: Item {
                    id: targetBtn

                    required property var modelData

                    readonly property bool actionable: modelData.actionable === true
                    // Severed (cut, not yet restored) targets dim but stay
                    // clickable so the same button re-links them.
                    readonly property bool dimmed: modelData.severed === true

                    width: 22
                    height: 22
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                      anchors.fill: parent
                      radius: RoundingPolicy.radius
                      color: tapArea.containsMouse && actionable
                        ? Ui.tint(String(modelData.colorKey ?? "foreground_1"), 0.15)
                        : "transparent"
                    }

                    Icon {
                      anchors.centerIn: parent
                      name: String(modelData.icon ?? "")
                      colorKey: String(modelData.colorKey ?? "foreground_1")
                      size: 15
                      opacity: dimmed ? 0.4 : 1
                    }

                    MouseArea {
                      id: tapArea

                      anchors.fill: parent
                      visible: actionable
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.invokeRequested(String(rowItem.modelData.app ?? ""),
                          String(targetBtn.modelData.key ?? ""))
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // Empty state: centered shield-lock at half opacity over the reason.
    // The 50% fade rides the glyph alone - the line has to stay readable,
    // so it keeps the level's own muted color. The asset tags only its
    // shield outline class="indicator", so the accent greens the shield and
    // leaves the lock in body tone.
    Column {
      id: empty

      width: parent.width
      visible: root.rows.length === 0
      spacing: Ui.s

      Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: "shield-lock"
        colorKey: "foreground_1"
        accentKey: "green"
        size: 48
        opacity: 0.5
      }

      Title {
        level: 5
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "No apps using your devices"
      }
    }
  }
}

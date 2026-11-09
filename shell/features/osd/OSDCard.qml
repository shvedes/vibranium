pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.osd

// Shared OSD card body. Same visuals on the desktop Overlay layer
// (OSDView.qml) and inside each lock surface (LockscreenSurfaceView.qml):
// session-lock surfaces render above all layer-shell windows, so the
// desktop PanelWindow alone can never show over an active lock.
// The card reads the OSD singleton directly; parents only position it
// (horizontal center + bottom offset on Y) and gate `visible`.
// Core layout:
//  - hasText (label !== ""): icon on the left (32px) + text above bar (Titles), bar thin below
//  - noText (label === ""): icon centered + bar bold next to it, both centered in card
Card {
  id: root

  // Vertical breathing room for the OSD card. Slimmer than Ui.outerPad
  // (14): a 1.5s flash overlay needs less chrome than a resident island.
  readonly property bool hasText: OSD.label !== ""
  captureInput: false
  readonly property int padV: 10
  readonly property int padH: 14

  readonly property real availableWidth: Math.max(0, root.maxWidth)
  // One reading width: 320px, or the window when it is narrower. The label
  // elides inside it rather than resizing the card, so a meter never jumps
  // width between two presses.
  readonly property real minWidth: Math.min(320, root.availableWidth)
  property real maxWidth: 9999
  width: root.minWidth
  height: body.implicitHeight + 2 * root.padV
  opacity: OSD.visible ? 1 : 0
  border.color: Ui.tint("accent", 1)

  Behavior on opacity {
    enabled: OSD.animationsEnabled
    NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
  }

  Item {
    id: body
    anchors.fill: parent
    anchors.topMargin: root.padV
    anchors.bottomMargin: root.padV
    anchors.leftMargin: root.padH
    anchors.rightMargin: root.padH
    implicitHeight: root.hasText ? colText.implicitHeight : colPlain.implicitHeight

    // Text variant: icon left (scaled to box) + text above thin bar
    Column {
      id: colText
      width: parent.width
      spacing: Ui.s
      visible: root.hasText

      Row {
        width: parent.width
        spacing: Ui.m

        // Icon box: the Icon always tries to fit the whole box it's in.
        // The box is a square; Icon.size is bound to the box size so the
        // glyph rasterizes at the box's logical size and stays crisp via
        // Icon.qml's DPR correction (sourceSize = canvas * devicePixelRatio).
        Item {
          id: iconBoxText
          width: 26
          height: 26
          Icon {
            anchors.centerIn: parent
            // Fit the whole box: use the smaller side so the glyph never
            // overflows, but the box here is square so it's just box size.
            size: Math.min(iconBoxText.width, iconBoxText.height)
            name: OSD.iconName
            colorKey: "foreground_0"
            // Muted: only the off-mark goes red (class="indicator" in
            // volume-off/mic-off); plain glyphs ignore the accent.
            accentKey: OSD.muted ? "red" : ""
            dimTiers: OSD._dimTiersFor(OSD.kind, OSD.value, OSD.muted)
          }
        }

        Column {
          width: parent.width - iconBoxText.width - Ui.m
          spacing: 2

          Title {
            level: 1
            width: parent.width
            text: OSD.label
            elide: Text.ElideRight
          }

          Title {
            level: 4
            width: parent.width
            text: OSD.kind === "brightness" ? "Brightness"
              : OSD.kind === "microphone" ? "Microphone" : "Volume"
            elide: Text.ElideRight
          }
        }
      }

      ProgressBar {
        width: parent.width
        // When brightness is negative (gamma dimming) the background is dim red but the
        // filled part must still show progress. Map -90..0 to 10..100 so bar never looks empty;
        // use 100 + value (e.g. -30 -> 70% fill) so deeper dim = less fill.
        value: OSD.kind === "brightness" && OSD.value < 0 ? Math.max(0, 100 + OSD.value) : (OSD.muted ? 0 : OSD.value)
        dimWhenEmpty: false
        glideMs: 150
        fillColor: OSD.muted ? Ui.solid("red") : Theme.color("accent")
        animationsEnabled: OSD.animationsEnabled
        color: OSD.kind === "brightness" && OSD.value < 0 ? Ui.tint("red", 0.18) : Theme.color("background_2")
      }

    }

    // No-text variant: icon centered + bar bold next to it, both centered in card.
    // Progress bar spans vertically bold (tall) across the row.
    // The whole Column is centered in the body so icon+bar are centered when no text.
    Column {
      id: colPlain
      width: parent.width
      spacing: Ui.s
      visible: !root.hasText
      anchors.centerIn: parent

      Row {
        id: rowNoText
        width: parent.width
        spacing: Ui.m

        Item {
          id: iconBoxPlain
          width: 30
          height: 30
          Icon {
            anchors.centerIn: parent
            size: Math.min(iconBoxPlain.width, iconBoxPlain.height)
            name: OSD.iconName
            colorKey: "foreground_0"
            accentKey: OSD.muted ? "red" : ""
            dimTiers: OSD._dimTiersFor(OSD.kind, OSD.value, OSD.muted)
          }
        }

        ProgressBar {
          id: barPlain
          // Vertically bold: spans the Row's height. 10px reads bold vs
          // the thin 6px text variant while keeping the card low, and the
          // Row centers it vertically with the Icon. The width consumes
          // the remaining card width so the bar feels span-wide.
          // When brightness is negative, background (not fill) is dim red (0.18) but fill
          // still shows (100 + value, e.g. -30 -> 70%).
          width: parent.width - iconBoxPlain.width - parent.spacing
          height: 20
          anchors.verticalCenter: parent.verticalCenter
          value: OSD.kind === "brightness" && OSD.value < 0 ? Math.max(0, 100 + OSD.value) : (OSD.muted ? 0 : OSD.value)
          dimWhenEmpty: false
          glideMs: 150
          fillColor: OSD.muted ? Ui.solid("red") : Theme.color("accent")
          animationsEnabled: OSD.animationsEnabled
          color: OSD.kind === "brightness" && OSD.value < 0 ? Ui.tint("red", 0.18) : Theme.color("background_2")
        }
      }

    }
  }
}

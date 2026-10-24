pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
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
  // Media payload (kind "nowplaying") renders its own branch below;
  // the meter branches stay hidden while it is up.
  readonly property bool isMedia: OSD.kind === "nowplaying"
  captureInput: false
  readonly property int padV: 10
  readonly property int padH: 14

  readonly property real availableWidth: Math.max(0, root.maxWidth)
  readonly property real minWidth: Math.min(320, root.availableWidth)
  readonly property real naturalWidth: 2 * root.padH + artBox.width + Ui.m + textCol.implicitWidth
  property real maxWidth: 9999
  width: Math.min(root.availableWidth, 480, Math.max(root.minWidth, root.naturalWidth))
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
    implicitHeight: root.isMedia ? colMedia.implicitHeight : (root.hasText ? colText.implicitHeight : colPlain.implicitHeight)

    // Media variant: 64px art box left + text lines right (track
    // level 1, artist/album level 3). Art box shows the real cover
    // (OSD gates on Ready, so no skeleton); with no art url the album
    // glyph spins instead.
    Column {
      id: colMedia
      width: parent.width
      spacing: Ui.s
      visible: root.isMedia

      Row {
        width: parent.width
        spacing: Ui.m

        Item {
          id: artBox
          width: 64
          height: 64

          // True round clip (Rectangle clip is rectangular and keeps
          // the spinning square's corners): the house MultiEffect mask
          // idiom from ColorPickerOverlay (lensClip/lensMask).
          Item {
            id: artMask
            anchors.fill: parent
            layer.enabled: true
            layer.smooth: true
            layer.samples: 4
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: circleMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1.0
            }

            // The mask never moves: only this inner box rotates, so the
            // square cover's corners are clipped to the circle at every
            // angle (rotating the mask itself sweeps them out of frame).
            Item {
              id: spinBox

              anchors.fill: parent

              Image {
                id: coverArt
                anchors.fill: parent
                visible: coverArt.status === Image.Ready
                source: OSD.artUrl
                asynchronous: true
                // Keep the last-good raster painted while a new URL
                // decodes (same contract as Icon.qml).
                retainWhileLoading: true
                cache: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 256
                sourceSize.height: 256
                antialiasing: true
              }

              Icon {
                anchors.centerIn: parent
                visible: !coverArt.visible
                size: 48
                name: "music-album"
                colorKey: "foreground_0"
                transformOrigin: Item.Center
              }

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 8000
                loops: Animation.Infinite
                running: true
                paused: !OSD.visible || !root.isMedia || OSD.transportPaused
              }
            }
          }

          Rectangle {
            id: circleMask

            anchors.fill: parent
            radius: 32 // Round art mask is circular shape (half of 64px box), not corner rounding.
            visible: false
            layer.enabled: true
            layer.smooth: true
            layer.samples: 4
          }
        }

        Column {
          id: textCol

          // Content width: longest line sizes the card (up to the
          // window); longer still elides inside the clamped slot.
          width: Math.min(textCol.implicitWidth,
            Math.max(0, root.availableWidth - 2 * root.padH - artBox.width - Ui.m))
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3

          Repeater {
            model: OSD.lines

            Item {
              id: mediaLine

              required property var modelData
              required property int index
              implicitWidth: lineIcon.implicitWidth + 6 + lineText.implicitWidth
              height: Math.max(lineIcon.implicitHeight, lineText.implicitHeight)

              Icon {
                id: lineIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                name: String(mediaLine.modelData.icon ?? "")
                colorKey: mediaLine.index === 0 ? "accent" : "foreground_0"
                size: 16
              }

              Title {
                id: lineText
                level: mediaLine.index === 0 ? 1 : 3
                font.bold: mediaLine.index === 0 ? true : false
                font.pixelSize: mediaLine.index === 0 ? 14 : Ui.fontS
                color: mediaLine.index === 0 ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
                anchors.left: lineIcon.right
                anchors.leftMargin: 6
                width: Math.min(implicitWidth, Math.max(0, textCol.width - lineIcon.implicitWidth - 6))
                anchors.verticalCenter: parent.verticalCenter
                text: String(mediaLine.modelData.text ?? "")
                elide: Text.ElideRight
              }
            }
          }

          Title {
            visible: OSD.lines.length === 0
            width: parent.width
            level: 1
            text: OSD.label
            elide: Text.ElideRight
          }
        }
      }

      // Track progress row: elapsed, bar, total (Spotify order).
      TextMetrics {
        id: progressTimeMetrics

        font.family: Ui.fontFamily
        font.pixelSize: Ui.fontXs
        text: OSD.totalText || "0:00"
      }

      readonly property real timeTextWidth: Math.ceil(progressTimeMetrics.advanceWidth)

      Row {
        visible: OSD.progressPct >= 0
        width: parent.width
        spacing: Ui.m

        Title {
          id: timeElapsed
          level: 4
          anchors.verticalCenter: parent.verticalCenter
          width: colMedia.timeTextWidth
          horizontalAlignment: Text.AlignRight
          text: OSD.elapsedText
          elide: Text.ElideRight
        }

        ProgressBar {
          width: Math.max(0, parent.width - 2 * parent.spacing - 2 * colMedia.timeTextWidth)
          anchors.verticalCenter: parent.verticalCenter
          value: OSD.progressPct
          dimWhenEmpty: false
          glideMs: 150
          fillColor: Theme.color("accent")
          animationsEnabled: OSD.animationsEnabled
          opacity: OSD.transportPaused ? 0.5 : 1
          color: Theme.color("background_2")

          Behavior on opacity {
            enabled: OSD.animationsEnabled
            NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
          }
        }

        Title {
          id: timeProg
          level: 4
          anchors.verticalCenter: parent.verticalCenter
          width: colMedia.timeTextWidth
          horizontalAlignment: Text.AlignRight
          text: OSD.totalText
          elide: Text.ElideRight
        }
      }
    }

    // Text variant: icon left (scaled to box) + text above thin bar + mic peak below
    Column {
      id: colText
      width: parent.width
      spacing: Ui.s
      visible: root.hasText && !root.isMedia

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
      visible: !root.hasText && !root.isMedia
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

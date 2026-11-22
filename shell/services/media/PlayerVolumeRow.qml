pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Mpris
import qs.common
import qs.services
import "../../common/NowPlaying.js" as NP
import "../../common/math/Range.js" as Range
import "../../common/text/Format.js" as Format

// The active client's own volume row: [mute icon][lane][percentage]. Shared by
// the Now Playing island and the player view so the capability gate, the
// write path and the click/drag/wheel contract have one implementation. The
// caller owns only geometry; a client that refuses a write stays visible but
// dimmed with a forbidden cursor on its lane.
Row {
  id: root

  required property var player
  property real slotSize: 18
  property real fontPx: Ui.fontXs
  property real laneGap: Ui.s / 2
  property real rowHeight: 18
  property real trackHeight: 6
  // A caller that stacks this under a seek row can inset the glyph and the
  // readout so this lane starts and ends on the same x as the seek lane.
  property real leadInset: 0
  property real trailInset: 0
  property bool animationsEnabled: true

  signal activated()

  height: root.rowHeight
  spacing: root.laneGap
  visible: root.player !== null
  opacity: root.capable ? 1 : 0.5

  Behavior on opacity {
    enabled: root.animationsEnabled
    NumberAnimation {
      duration: Ui.fastMs
      easing.type: Easing.OutCubic
    }
  }

  readonly property bool capable: MediaState.volumeCapable(root.player)
  readonly property real volume: root.player !== null
    ? NP.normalizeVolume(root.player.volume) : 0

  TextMetrics {
    id: percentMetrics

    font.family: Ui.fontFamily
    font.pixelSize: root.fontPx
    text: "100%"
  }
  readonly property real percentW: Math.ceil(percentMetrics.advanceWidth)

  function setRatio(ratio) {
    const changed = MediaState.setPlayerVolume(root.player, ratio)
    if (changed) root.activated()
    return changed
  }

  function adjust(direction) {
    const d = Number(direction)
    if (!root.capable || !isFinite(d) || d === 0) return false
    return root.setRatio(NP.adjustedVolume(root.volume, d, Audio.step))
  }

  function toggleMute() {
    if (!root.capable) return false
    const next = NP.togglePlayerVolume(root.player, 0.5)
    const wasPlaying = root.player !== null
      && root.player.playbackState === MprisPlaybackState.Playing
    const changed = root.setRatio(next)
    if (changed && next === 0) NP.setMuteResumePending(root.player, wasPlaying)
    // Muting pauses some clients; that is a transport call the user did not
    // make and no pad on either surface suggests one.
    if (changed && next === 0 && wasPlaying && root.player.canPause === true) {
      root.player.pause()
    }
    return changed
  }

  Item {
    width: root.leadInset
    height: 1
  }

  Item {
    // Row lays children out from the top; give the glyph its own row-height
    // slot so a small icon stays centred on the bar.
    width: root.slotSize
    height: root.rowHeight

    IconButton {
      anchors.centerIn: parent
      name: Audio.volumeIconFor(root.volume, false)
      colorKey: "foreground_1"
      accentKey: root.volume <= 0.01 ? "red" : ""
      dimTiers: Audio.volumeDimTiersFor(root.volume, false)
      iconSize: root.slotSize
      slotSize: root.slotSize
      flat: true
      cornerRadius: RoundingPolicy.radius
      animationsEnabled: root.animationsEnabled
      actionable: root.capable
      onClicked: root.toggleMute()

      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
          if (!root.adjust(event.angleDelta.y)) return
          event.accepted = true
        }
      }
    }
  }

  Item {
    id: volLane

    width: Math.max(0, root.width - root.leadInset - root.trailInset
      - root.slotSize - root.percentW - 4 * root.laneGap)
    height: root.height
    anchors.verticalCenter: parent.verticalCenter

    property bool dragging: false
    property real pressX: 0

    Rectangle {
      width: parent.width
      height: root.trackHeight
      anchors.verticalCenter: parent.verticalCenter
      color: Ui.tint("foreground_1", 0.25)

      Rectangle {
        width: parent.width * Range.clamp01(root.volume)
        height: parent.height
        color: Ui.solid("accent")

        Behavior on width {
          enabled: root.animationsEnabled && !volLane.dragging
          NumberAnimation {
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      anchors.topMargin: -Math.max(6, root.trackHeight)
      anchors.bottomMargin: -Math.max(6, root.trackHeight)
      hoverEnabled: true
      cursorShape: root.capable ? Qt.PointingHandCursor : Qt.ForbiddenCursor
      acceptedButtons: Qt.LeftButton
      onPressed: mouse => {
        if (!root.capable) return
        volLane.pressX = mouse.x
      }
      onPositionChanged: mouse => {
        if (!root.capable || !pressed) return
        if (Math.abs(mouse.x - volLane.pressX) > 6) {
          volLane.dragging = true
          root.setRatio(mouse.x / width)
        }
      }
      onReleased: mouse => {
        if (root.capable) root.setRatio(mouse.x / width)
        volLane.dragging = false
      }
      onCanceled: volLane.dragging = false
    }

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: event => {
        if (!root.adjust(event.angleDelta.y)) return
        event.accepted = true
      }
    }
  }

  Item {
    width: root.trailInset
    height: 1
  }

  Text {
    width: root.percentW
    anchors.verticalCenter: parent.verticalCenter
    horizontalAlignment: Text.AlignRight
    text: Format.percent(root.volume)
    color: Ui.tint("foreground_1", 0.55)
    font.pixelSize: root.fontPx
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
    elide: Text.ElideRight
  }
}

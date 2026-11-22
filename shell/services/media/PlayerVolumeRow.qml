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

  IconButton {
    name: Audio.volumeIconFor(root.volume, false)
    colorKey: "foreground_1"
    accentKey: root.volume <= 0.01 ? "red" : ""
    dimTiers: Audio.volumeDimTiersFor(root.volume, false)
    // The SVG has internal padding, so a glyph sized at the slot paints
    // visibly smaller than the bar's row. Scale it up from the row height
    // instead; the shipped volume tiers then read at the bar's height.
    iconSize: Math.round(root.rowHeight * 1.3)
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

  Item {
    id: volLane

    width: Math.max(0, root.width - root.slotSize - root.percentW - 2 * root.laneGap)
    height: root.height
    anchors.verticalCenter: parent.verticalCenter

    property bool dragging: false
    property real pressX: 0

    Rectangle {
      width: parent.width
      height: 6
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
      anchors.topMargin: -6
      anchors.bottomMargin: -6
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

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Mpris
import qs.common

// Shuffle and loop transport pad, shared by the Now Playing island and the
// player view. Both modes write straight to the MPRIS object: the display
// properties read it back, so there is no shadow state to drift and the pad
// stays live after whichever surface opened the client goes away. The tint
// crossfade keeps the state change in one fixed, clipped slot.
Item {
  id: root

  required property var player
  required property string mode // "shuffle" | "loop"
  property real slotSize: 30
  property real iconSize: 20
  property bool animationsEnabled: true

  signal activated()

  readonly property bool shuffling: root.mode === "shuffle"
    && root.player !== null && (root.player.shuffle ?? false)
  readonly property bool looping: root.mode === "loop" && root.player !== null
    && root.player.loopState !== undefined
    && root.player.loopState !== MprisLoopState.None
  readonly property bool loopOne: root.mode === "loop" && root.player !== null
    && root.player.loopState === MprisLoopState.Track
  // A client that advertises the flag but refuses control must leave the pad
  // dim and the write unattempted.
  readonly property bool canAct: root.player !== null
    && root.player.canControl !== false
    && (root.mode === "shuffle"
      ? root.player.shuffleSupported !== false
      : root.player.loopSupported !== false)
  readonly property bool active: root.mode === "shuffle" ? root.shuffling : root.looping
  readonly property string glyph: root.mode === "shuffle"
    ? "shuffle" : (root.loopOne ? "repeat-1" : "repeat")

  width: root.slotSize
  height: root.slotSize

  property real tint: root.active ? 1 : 0
  Behavior on tint {
    enabled: root.animationsEnabled
    NumberAnimation {
      duration: Ui.slowMs
      easing.type: Easing.OutCubic
    }
  }

  IconButton {
    id: btn

    anchors.fill: parent
    name: root.glyph
    colorKey: "foreground_0"
    iconSize: root.iconSize
    slotSize: root.slotSize
    flat: true
    cornerRadius: RoundingPolicy.radius
    animationsEnabled: root.animationsEnabled
    actionable: root.canAct
    opacity: live ? 1 : 0.4
    iconOpacity: 1 - root.tint
    onClicked: root.activate()

    Icon {
      anchors.centerIn: parent
      name: root.glyph
      colorKey: "accent"
      size: root.iconSize
      opacity: (btn.live ? 1 : 0.4) * root.tint
    }
  }

  // None -> repeat-all -> repeat-one -> None, the MPRIS loop cycle.
  function activate() {
    if (!root.canAct) return
    if (root.mode === "shuffle") {
      root.player.shuffle = !root.shuffling
    } else {
      root.player.loopState = root.player.loopState === MprisLoopState.None
        ? MprisLoopState.Playlist
        : (root.player.loopState === MprisLoopState.Playlist
          ? MprisLoopState.Track : MprisLoopState.None)
    }
    root.activated()
  }
}

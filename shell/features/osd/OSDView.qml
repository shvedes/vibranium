pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.osd

// OSD surface. Passive, click-through, Overlay layer, horizontally
// centered, vertically fixed at the bottom side of the screen
// (`shell.osd.offset` px above the bottom edge).
// The card body lives in OSDCard.qml. Session-lock surfaces render above
// all layer-shell windows, so this window stays unmapped while the session
// is locked (OSD.desktopSuppressed) and no OSD is shown over the lockscreen.
PanelWindow {
  id: win

  screen: Ui.primaryScreen ?? Quickshell.screens[0] ?? null
  // The mapping rule lives with the rest of the OSD's policy (OSD.qml):
  // a payload is up, including its exit fade, and the lock is not
  // suppressing the desktop surface.
  visible: OSD.surfaceVisible
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  mask: Region { width: 0; height: 0 }

  WlrLayershell.namespace: "vibranium:osd"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Placement: meter kinds sit `offset` px above the bottom edge;
  // the now-playing card uses its own position + offset. Horizontal
  // is always centered.
  OSDCard {
    id: card
    anchors.horizontalCenter: parent.horizontalCenter
    maxWidth: Math.max(0, win.width - 24)
    readonly property bool onTop: card.isMedia && OSD.nowPlayingPosition === "top"
    readonly property int parkOffset: card.isMedia ? OSD.nowPlayingOffset : OSD.offset
    readonly property real preferredY: card.onTop
      ? card.parkOffset
      : win.height - card.height - card.parkOffset
    readonly property real maxY: Math.max(12, win.height - card.height - 12)
    y: Math.max(12, Math.min(card.preferredY, card.maxY))
  }
}

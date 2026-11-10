pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.osd
import "../../common/math/Range.js" as Range

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

  // Placement: `shell.osd.offset` px above the bottom edge, horizontally
  // centered.
  OSDCard {
    id: card
    anchors.horizontalCenter: parent.horizontalCenter
    maxWidth: Math.max(0, win.width - 24)
    readonly property real preferredY: win.height - card.height - OSD.offset
    readonly property real maxY: Math.max(12, win.height - card.height - 12)
    y: Range.clamp(card.preferredY, 12, card.maxY)
  }
}

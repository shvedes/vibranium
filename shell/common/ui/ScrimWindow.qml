pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common

// Shared scrim window - common PanelWindow chrome for menu, launcher,
// power, clipboard, wallpaper picker and pass. Keeps anchors, transparent color
// and close-fade in one place so every overlay shares the same dim timing.
PanelWindow {
  id: root

  property real dim: 0.45
  property bool overlayOpen: false
  property bool isPrimary: false
  // Kill switch: disables the close fade; the overlay still snaps
  // to final opacity. Defaults on for consumers off the menu.
  property bool animationsEnabled: true

  signal closeRequested()

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true

  default property alias content: container.data

  // Arms the close fade; see the note on the Behavior below for why this is a
  // handler rather than a binding.
  onOverlayOpenChanged: scrimFade.enabled = root.animationsEnabled && !root.overlayOpen

  Item {
    id: scrimContent
    anchors.fill: parent
    opacity: root.overlayOpen ? 1 : 0
    // Only the CLOSE animates. Every consumer of this window is summoned by a
    // keypress or a click, and the surface is mapped within a few ms of that
    // input, so an opacity Behavior that eases up from zero spends the whole
    // of fastMs painting nothing the user asked for - the launcher measures
    // mapped at +4ms and still needs fastMs to become visible, all of it
    // here. The same fade on the way out reads as polish, so it stays.
    //
    // Deliberately no mapped hold for this fade (no `visible || fading`
    // staging): consumers unmap on the close tick, and the compositor's own
    // layersOut fade animates the unmap. Holding the surface mapped through
    // our fade first plays two fades back-to-back - dim lifts, then the
    // opaque card fades - which reads as a flash after the close. Tried;
    // reverted.
    //
    // `enabled` is armed from onOverlayOpenChanged rather than bound to
    // overlayOpen: overlayOpen drives this opacity target too, and the engine
    // does not order those two re-evaluations, so a binding reads the previous
    // value on the opening turn and animates the summon anyway. A signal
    // handler runs before the binding pump, which is the order this needs.
    // Default false, so the window's first open (construction to visible)
    // cannot animate either.
    Behavior on opacity {
      id: scrimFade
      enabled: false
      NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
    }

    Rectangle {
      id: scrim
      anchors.fill: parent
      color: "#000000"
      opacity: root.dim
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.isPrimary
      onClicked: root.closeRequested()
    }

    Item {
      id: container
      anchors.fill: parent
    }
  }
}

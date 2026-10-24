pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.services as Svc
import qs.features.bar

// Power profile indicator. Purely presentational: it paints the live
// profile served by the PowerProfile service (which owns the D-Bus observation
// and the `qs ipc call powerProfile` control verbs) - icon for
// performance/power-saver, nothing for balanced, generic icon when the
// daemon is unreachable. Balanced collapses the slot footprint entirely,
// so switching profiles never leaves a hanging gap; the module itself
// stays registered and ordered. Clicks do nothing: profile control lives
// in services/power/PowerProfile, never here.
CollapsibleSlot {
  id: root

  // Painted only when there is an icon to show: balanced reserves no space,
  // performance/power-saver and an unreachable daemon take the icon width.
  readonly property bool hasIcon: Svc.PowerProfile.iconName !== ""

  // Collapsible slot (see CollapsibleSlot.qml): zero width while idle
  // so it leaves no gap.
  collapseShown: root.hasIcon

  Icon {
    id: glyph

    // Pinned to the trailing edge the box grows from: the right zone is
    // right-anchored, so the slot's right edge stays screen-fixed during
    // the slide. The Icon item is exactly slot-sized and paints its glyph
    // centered inside, so a flush-right anchor centers the glyph at rest;
    // mid-slide the item's left overflow is clipped and the glyph holds
    // still on screen, revealed progressively (no half-slot drift).
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: Svc.PowerProfile.iconName
    colorKey: "foreground_0"
    opacity: root.fade
    visible: opacity > 0
  }

  // Display-only module: no switching from the bar, and no child click
  // surface exists to reach.
  fillButtons: Qt.NoButton

  ToolTipBind {
    active: root.hovered
    text: "Power profile: " + Svc.PowerProfile.profileName
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }
}

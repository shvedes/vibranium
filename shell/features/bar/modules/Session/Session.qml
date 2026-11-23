pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.bar
import qs.features.powerMenu

// Session module. A single button that opens the logout / power menu (the
// same overlay the keybind "power toggle" and the settings power page use)
// on click. It carries no state of its own - presence and behavior live in
// PowerMenu. It is a standalone bar slot: movable like any other module,
// with no expansion trigger to pass on to a neighbor.
BarModule {
  id: root

  // Icon geometry comes from the bar tokens (fixed slot / optical canvas);
  // the pill is exactly one slot wide so the hover/click target stays
  // constant across glyphs.
  readonly property real slotWidth: root.iconSlot

  implicitWidth: root.slotWidth

  // The logout door opens inward: the arrow points back at the session
  // instead of out of it.
  Icon {
    anchors.centerIn: parent
    name: "logout"
    colorKey: "foreground_0"
  }

  fillButtons: Qt.LeftButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.RightButton) {
      root.clickCommand("rightClick")
      return
    }
    PowerMenu.toggle()
  }

  barTipText: "Session - power options"
}

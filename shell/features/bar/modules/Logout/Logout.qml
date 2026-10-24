pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.bar
import qs.features.powerMenu

// Logout module. A single button in the right zone that opens the logout /
// power menu (the same overlay the keybind "power toggle" and the settings
// power page use) on click. It carries no state of its own - presence and
// behavior live in PowerMenu.
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

  ToolTipBind {
    active: root.hovered
    text: "Session - power options"
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  // Hover is the tray's expansion trigger (see BarView.trayTriggerHovered):
  // while the mouse sits on this icon the tray module stays slid out, so
  // the cursor can move straight onto the tray icons. Per-window state, so
  // each monitor's bar behaves independently.
  onHoveredChanged: if (root.barWindow) root.barWindow.trayTriggerHovered = root.hovered
}

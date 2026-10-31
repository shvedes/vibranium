pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.bar

// Update indicator. Owned slot that appears only while an update is
// pending: it paints the update icon with a tooltip and opens the update
// TUI on left click. The module owns no logic - it mirrors the
// `update.available` bus topic published by the Update service (Bus.latest
// replays the last payload, so a module enabled after a publish is correct
// on frame one) and never imports the service.
CollapsibleSlot {
  id: root

  // Last payload from the update service's topic; null before the first
  // publish (the module stays hidden until the service says otherwise).
  readonly property var state: Bus.latest("update.available")

  // Mirrors the service's live availability; hidden state takes no space
  // (the collapse matches the owned-indicator convention).
  readonly property bool on: root.state?.available ?? false

  // Collapsible slot (see CollapsibleSlot.qml): zero width while idle
  // so it leaves no gap.
  collapseShown: root.on

  Icon {
    // Pinned to the trailing edge the box grows from (right-anchored zone):
    // the Icon item is slot-sized and paints its glyph centered inside, so
    // a flush-right anchor centers the glyph at rest and holds it
    // screen-fixed while the slot grows (left overflow is clipped).
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: "update"
    colorKey: "green"
    opacity: root.fade
    visible: opacity > 0
  }

  // Left click opens the update TUI, or runs
  // shell.statusbar.updateLeftClick when that is set. Right click is not
  // accepted, so it passes through and does nothing.
  fillButtons: Qt.LeftButton
  onClicked: mouse => root.clickCommand("leftClick", "vb-launch-tui -- vb-update")

  // Shown only while an update is pending and hovered.
  ToolTipBind {
    active: root.on && root.hovered
    text: root.state?.tooltipText ?? ""
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }
}

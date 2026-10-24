pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Dropdown action button: flat, corners follow RoundingPolicy, hover- and
// `accent` (accent for connect/disconnect, red for forget) - the same
// language as the menu/launcher confirm buttons, sized for in-dropdown
// rows. Used inside the shared DropdownSlot by the network and bluetooth
// islands.
//
// Disabled is a full state, not just a click guard: visuals key off
// `enabled` itself (never hover/press alone, which can stick), the click
// surface gates on it, and the shared disabled fade applies - same
// treatment as Button/IconButton.
Rectangle {
  id: btn

  property string text: ""
  property color accent: Theme.color("red")

  signal clicked()

  height: Ui.buttonHeight
  radius: RoundingPolicy.radius
  opacity: btn.enabled ? 1 : Ui.disabledOpacity
  color: {
    if (!btn.enabled) return "transparent"
    if (area.containsPress) return Ui.alpha(btn.accent, 0.2)
    if (area.containsMouse) return Ui.alpha(btn.accent, 0.12)
    return "transparent"
  }
  border.width: 1
  border.color: Ui.alpha(btn.accent, (area.containsMouse && btn.enabled) ? 0.7 : 0.45)
  scale: (area.containsPress && btn.enabled) ? 0.97 : 1

  Behavior on color {
    ColorAnim {}
  }
  Behavior on border.color {
    ColorAnim {}
  }

  Text {
    anchors.centerIn: parent
    text: btn.text
    visible: btn.text !== ""
    color: btn.accent
    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
    font.bold: true
    textFormat: Text.PlainText
  }

  MouseArea {
    id: area

    anchors.fill: parent
    enabled: btn.enabled
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: btn.clicked()
  }
}

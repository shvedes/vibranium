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
// surface refuses presses and reports the forbidden cursor, and the shared
// disabled fade applies - same treatment as Button/IconButton.
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
    hoverEnabled: true
    // `enabled: false` on the area would drop it out of hover delivery, and an
    // inert button could then never show the forbidden cursor. The gate rides
    // the accepted buttons instead: no button, no click, hover still reported.
    acceptedButtons: btn.enabled ? Qt.LeftButton : Qt.NoButton
    cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
    onClicked: btn.clicked()
  }
}

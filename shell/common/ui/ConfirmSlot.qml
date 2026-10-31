pragma ComponentBehavior: Bound
import QtQuick
import qs.common

// Drop-in staged confirmation slot: hint -> armed -> confirmed.
// Replaces the 3-step Rectangle+MouseArea triplicated in Entry and
// LauncherEntry. Panels track stage externally; this is pure view.
DropdownSlot {
  id: root

  property int stage: 0
  property string confirmText: "Delete"
  property string hintText: "Press Delete to remove"
  property string armedText: "<b><u>Press again to confirm</u></b>"

  signal confirmed()
  // Declared and never raised by the component; ui-rest's probe connects
  // onCancelled and pins the count at zero. A consumer that wires it hangs
  // silently, so the empty surface stays until something emits it.
  signal cancelled()

  Column {
    x: Ui.m
    width: parent.width - 2 * Ui.m
    spacing: Ui.s

    Text {
      width: parent.width
      text: root.stage >= 2 ? root.armedText : root.hintText
      color: Ui.tint("foreground_1", 0.6)
      font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
      textFormat: Text.StyledText
      wrapMode: Text.WordWrap
    }

    Rectangle {
      width: parent.width
      height: Ui.buttonHeight
      radius: RoundingPolicy.radius
      color: root.stage >= 2
        ? (area.containsPress ? Qt.darker(Theme.color("red"), 1.2) : Theme.color("red"))
        : (area.containsPress ? Ui.tint("red", 0.12) : "transparent")
      border.width: 1
      border.color: root.stage >= 2 ? Theme.color("red") : Ui.tint("red", 0.45)
      Behavior on color { ColorAnim {} }
      Behavior on border.color { ColorAnim {} }

      Text {
        anchors.centerIn: parent
        text: root.confirmText
        color: root.stage >= 2 ? Theme.color("background_0") : Theme.color("red")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        font.bold: root.stage >= 2
        textFormat: Text.PlainText
        Behavior on color { ColorAnim {} }
      }

      MouseArea {
        id: area
        anchors.fill: parent
        onClicked: {
          root.confirmed()
        }
      }
    }
  }
}

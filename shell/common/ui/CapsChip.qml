pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// CapsLock indicator chip shared by the lockscreen and the polkit dialog.
// Sized from its own label, driven by its active input, and fading/scaling
// between states; consumers only position it.
Rectangle {
  id: root

  property bool active: false
  readonly property bool on: root.active

  width: label.implicitWidth + 24
  height: label.implicitHeight + 10
  radius: RoundingPolicy.radius
  color: Ui.tint("yellow", 0.08)
  border.width: 1
  border.color: Ui.tint("yellow", 0.45)
  opacity: root.on ? 1 : 0
  scale: root.on ? 1 : 0.9

  Behavior on opacity {
    NumberAnimation {
      duration: 150
    }
  }
  Behavior on scale {
    NumberAnimation {
      duration: 150
    }
  }

  Text {
    id: label

    anchors.centerIn: parent
    text: "CAPS LOCK"
    color: Theme.color("yellow")
    font.pixelSize: 11
    font.family: Ui.fontFamily
    font.bold: true
    font.letterSpacing: 2
  }
}

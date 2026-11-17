pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// CapsLock indicator chip: sized from its own label, driven by its active
// input, and fading/scaling between states; consumers only position it. The
// password fields draw caps on their own glyphs (PasswordBox.capsActive), so
// no surface instantiates this today; it remains the label-form indicator for
// a surface that wants one.
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
      duration: MotionPolicy.duration(150)
    }
  }
  Behavior on scale {
    NumberAnimation {
      duration: MotionPolicy.duration(150)
    }
  }

  Text {
    id: label

    anchors.centerIn: parent
    text: "CAPS LOCK"
    color: Theme.color("yellow")
    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
    font.bold: true
    font.letterSpacing: 2
  }
}

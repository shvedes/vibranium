pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// The bar's small filled pill: one line of tabular copy in a themed
// background, sized from its own text and glided as the digits narrow so
// a countdown breathes instead of snapping every tick.
//
// Timer, Caffeine and Recording all hand-rolled this same rectangle
// (padding, radius, text size and width tween were copied three times).
// The chrome lives here once; a module only says what it says, which
// palette leaf fills it, and which edge of the slot it holds.
Rectangle {
  id: root

  property string text: ""
  // Palette key for the fill.
  property string backgroundKey: "background_2"
  // Label color, already resolved (some pills invert the fill).
  property color foreground: Ui.solid("foreground_0")
  // The row has zero gap, so the pill docks on the same inset the module's
  // glyph uses. Right is the time-module default; Recording holds the left.
  property bool alignRight: true

  anchors.verticalCenter: parent.verticalCenter
  anchors.right: root.alignRight ? parent.right : undefined
  anchors.left: root.alignRight ? undefined : parent.left
  anchors.rightMargin: root.alignRight ? Bar.slotInset : 0
  anchors.leftMargin: root.alignRight ? 0 : Bar.slotInset
  width: label.implicitWidth + 8
  height: label.implicitHeight
  radius: RoundingPolicy.radius
  color: Ui.solid(root.backgroundKey)

  Behavior on width {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.slowMs }
  }

  Title {
    id: label

    anchors.centerIn: parent
    level: 3
    font.pixelSize: Bar.pillFontSize
    color: root.foreground
    text: root.text
  }
}

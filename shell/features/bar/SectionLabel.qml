pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One island section heading: a small glyph before a caps title.
//
// The battery, Bluetooth, printer and volume islands each hand-rolled this
// row, so the glyph size, its opacity, the spacing and the title level were
// written five times. The heading is a Row, not a strip: the caller anchors it
// to the left of its own line, which is what leaves the right end free for a
// trailing control.
Row {
  id: root

  // Shipped asset name; the heading renders whatever the caller names.
  property string icon: ""
  property string text: ""

  spacing: Ui.s

  Icon {
    anchors.verticalCenter: parent.verticalCenter
    name: root.icon
    colorKey: "foreground_1"
    size: 14
    opacity: 0.7
  }

  Title {
    level: 2
    anchors.verticalCenter: parent.verticalCenter
    text: root.text
  }
}

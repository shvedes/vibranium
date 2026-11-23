pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One island section heading: a small glyph before a caps title.
//
// The battery, Bluetooth, printer and volume islands each hand-rolled this
// row, so the glyph size, its opacity, the spacing and the title level were
// written many times. The heading is a Row, not a strip: the caller anchors it
// to the left of its own line, which is what leaves the right end free for a
// trailing control.
Row {
  id: root

  // Shipped asset name; the heading renders whatever the caller names.
  property string icon: ""
  property string text: ""

  // Optional trailing content for a heading whose title is not a plain caps
  // label (Network's hover crossfade). Set hasTrailing when supplying it:
  // the plain Title then yields to the caller's content, which the slot
  // sizes to. With the default false the row is exactly glyph + Title.
  property bool hasTrailing: false
  default property alias trailing: trailingSlot.data

  spacing: Ui.s

  Icon {
    anchors.verticalCenter: parent.verticalCenter
    name: root.icon
    colorKey: "foreground_1"
    size: 14
    opacity: 0.7
  }

  Title {
    visible: !root.hasTrailing
    level: 2
    anchors.verticalCenter: parent.verticalCenter
    text: root.text
  }

  Row {
    id: trailingSlot

    visible: root.hasTrailing
    anchors.verticalCenter: parent.verticalCenter
    spacing: 0
  }
}

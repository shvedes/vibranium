pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Shared checkbox: 14px box, corners follow RoundingPolicy, accent fill
// with centered checkmark. No internal MouseArea; parent handles toggle
// (delegate rowArea or header row). Visual only - hover and cursor
// affordances are the parent's business.
//
// An inert box is the whole contract, and the table's two placements
// disagree about who owns the click: the package delegate paints this box
// above the row's own click surface, the header paints its click surface
// above the box. A self-toggling control serves only the first of those.
// Measured with synthesized input on both orders, a native CheckBox in the
// delegate's position takes the click and leaves the row at zero clicks,
// and the same click in the header's position reaches the header area and
// never reaches the control. The size policy, the accent fill, the
// checkmark and the border tint stay here for the reason the interaction
// does.
//
// The pointer contract above is unchanged: there is still no MouseArea
// here and the parent still owns the click.
Rectangle {
  id: root

  property bool checked: false
  // Optional size override for non-list contexts; 0 means 14px default.
  property real size: 0
  readonly property real boxSize: root.size > 0 ? root.size : 14

  implicitWidth: root.boxSize
  implicitHeight: root.boxSize
  width: root.boxSize
  height: root.boxSize
  radius: RoundingPolicy.radius
  color: root.checked ? Ui.solid("accent") : "transparent"
  border.width: 1
  border.color: root.checked ? Ui.solid("accent") : Ui.tint("foreground_1", 0.45)

  Text {
    visible: root.checked
    anchors.centerIn: parent
    text: "\u2713"
    color: Ui.solid("background_0")
    font.pixelSize: 13
    font.bold: true
    textFormat: Text.PlainText
  }
}

pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Selectable list row with Finder-style zebra striping: the shared row
// behind table-like lists (ArchUpdates packages, weather suggestions,
// weather forecast days).
//
// Library idiom, square and click-only unless opted in: even rows carry
// a faint band, the keyboard cursor renders a stronger accent band, and
// an opt-in hover wash exists for rows that are themselves the control
// (pickers, suggestion lists). Hover never overrides the selected band.
// Consumers that hand-roll the band Rectangle plus a fill
// MouseArea should use this instead.
//
// NOTE on translucency: all three bands are translucent tints selected
// by a ternary. This was render-probed offscreen (opaque black card
// behind the rows): faint zebra, subtle selected blue, invisible odd
// rows - all correct. A capture over a TRANSPARENT background flattens
// translucent fills to opaque, so a probe that reports solid bands is
// measuring the capture, not the paint. Do not "fix" the ternary on the
// strength of a transparent-background capture.
Item {
  id: root

  // Zero-based position; even rows carry the faint band.
  property int rowIndex: 0
  // Keyboard cursor / active row highlight.
  property bool selected: false
  // Faint band color for even rows.
  property color bandColor: Ui.tint("foreground_1", 0.05)
  // Cursor band color for the selected row.
  property color selectedColor: Ui.tint("accent", 0.22)
  // Click surface. False for decorative rows (skeletons, forecast days)
  // that only want the band.
  property bool interactive: true
  // Pointer cursor on hover (click affordance for fully-clickable rows).
  // Off by default: checkbox tables keep the arrow and signal clicks
  // through their controls instead.
  property bool hoverCursor: false
  // Hover highlight for interactive rows. Off by default: checkbox tables
  // stay click-only per the table contract. Opt in where the row itself
  // is the control (pickers, suggestion lists).
  property bool hoverable: false
  property color hoverColor: Ui.tint("foreground_1", 0.10)
  readonly property bool hovered: root.hoverable && hoverArea.containsMouse

  signal clicked(mouse: var)

  Rectangle {
    anchors.fill: parent
    color: root.selected ? root.selectedColor
      : (root.hovered ? root.hoverColor
        : (root.rowIndex % 2 === 0 ? root.bandColor : "transparent"))
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    visible: root.interactive
    hoverEnabled: root.hoverable || root.hoverCursor
    cursorShape: root.hoverCursor ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: mouse => root.clicked(mouse)
  }
}

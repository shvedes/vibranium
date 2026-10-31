pragma ComponentBehavior: Bound

import QtQuick

// Debug bounds overlay for Icon (VIBRANIUM_DEBUG_BAR_ICONS=1), compiled
// once and shared through Loader.source so production icons pay only the
// dormant Loader, never an inline Component.
//
// HOST CONTRACT: instantiated only by Icon.qml's debugLoader, which fills
// the icon slot and carries a `canvas` custom property (the optical canvas
// in logical px). Red = outer slot (hit target), blue = optical canvas
// (the painted content).
Item {
  id: root

  // In from the host Loader (see contract above). Nested children read
  // this alias: their own parent is this root, not the Loader.
  readonly property real canvas: parent.canvas

  anchors.fill: parent

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.color: "red"
    border.width: 1
  }

  Rectangle {
    anchors.centerIn: parent
    width: root.canvas
    height: root.canvas
    color: "transparent"
    border.color: "blue"
    border.width: 1
  }
}

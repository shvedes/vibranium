pragma ComponentBehavior: Bound

import QtQuick

// Full-surface net that dismisses a popup/surface when the pointer is pressed
// anywhere outside its card. Declare it before the card so content clicks never
// fall through to it. Visually inert and hover-free: it only ever catches
// presses, never paints or tracks the pointer. Hosts supply the open condition
// through `gate` and wire `onDismissed` to their own close action.
MouseArea {
  id: root

  anchors.fill: parent
  acceptedButtons: Qt.AllButtons

  // Open condition: the net only intercepts presses while the surface is open.
  property bool gate: true

  signal dismissed()

  enabled: root.gate
  onPressed: root.dismissed()
}

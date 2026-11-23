pragma ComponentBehavior: Bound

import QtQuick

// Swallows every pointer button inside a keyboard-driven card. Declare it as
// the last child so it sits above rows, slots and fields: a click then lands
// on nothing instead of falling through to the scrim under the card. Hover is
// deliberately not taken - a menu paints no hover state - so the pointer
// keeps answering with nothing while the keys own navigation and activation.
MouseArea {
  anchors.fill: parent
  z: 10000
  acceptedButtons: Qt.AllButtons
}

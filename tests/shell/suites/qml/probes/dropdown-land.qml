import QtQuick
import qs.common

// A landed slot must still follow its content: landing disables the easing,
// not the live height binding. This probe lands a slot, shrinks its body and
// reads the slot back on the following turn.

Rectangle {
  id: root
  width: 400
  height: 600

  DropdownSlot {
    id: slot
    width: 200
    gap: 4
    nestedContent: Component {
      Rectangle { width: 30; height: 40; objectName: "body"; color: "blue" }
    }
    Rectangle { width: 30; height: 20; objectName: "inline"; color: "red" }
  }

  property bool completed: false

  Component.onCompleted: console.log("##KV## probe.error=none")

  Timer {
    interval: 16
    repeat: true
    running: !root.completed
    property int turn: 0
    onTriggered: {
      turn++
      if (turn === 1) {
        slot.open = true
      } else if (turn === 30) {
        console.log("##KV## slot.before=" + slot.height.toFixed(1))
        slot.land()
      } else if (turn === 31) {
        console.log("##KV## slot.after=" + slot.height.toFixed(1))
        console.log("##KV## slot.held=" + slot._held)
        if (slot._nested) slot._nested.height = 8
      } else if (turn === 32) {
        console.log("##KV## slot.shrunk=" + slot.height.toFixed(1))
        console.log("##KV## slot.completed=true")
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}

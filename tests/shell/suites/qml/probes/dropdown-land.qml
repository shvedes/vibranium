import QtQuick
import qs.common

// A landed slot must still follow its content: landing disables the easing,
// not the live height binding. The landing slot here is landed, shrunk and
// read back; it then drives a stale land (land() then release() before the
// deferred write) to prove a released slot cannot be frozen on an old hold.
// A second, never-landed slot is closed and observed to prove no deferred
// body outlives the fold. The slots are separate: the rapid land/release
// churn of the stale test perturbs the landing slot's tween, so the fold is
// measured on a clean one.

Rectangle {
  id: root
  width: 400
  height: 600

  DropdownSlot {
    id: landSlot
    width: 200
    gap: 4
    nestedContent: Component {
      Rectangle { width: 30; height: 40; objectName: "body"; color: "blue" }
    }
    Rectangle { width: 30; height: 20; objectName: "inline"; color: "red" }
  }

  DropdownSlot {
    id: foldSlot
    width: 200
    gap: 4
    nestedContent: Component {
      Rectangle { width: 30; height: 40; objectName: "body"; color: "blue" }
    }
    Rectangle { width: 30; height: 20; objectName: "inline"; color: "red" }
  }

  property bool completed: false

  // Captured from signals so the fold assertions do not depend on which
  // turn the fade lands on: the body must be alive while closing and gone
  // the moment closeFinished fires.
  property bool closeFired: false
  property bool bodySeenDuringClose: false
  property bool noBodyAtFinish: true

  Connections {
    target: foldSlot

    function onClosingChanged() {
      if (foldSlot.closing && foldSlot.nestedItem !== null)
        root.bodySeenDuringClose = true
    }

    function onCloseFinished() {
      root.closeFired = true
      if (foldSlot.nestedItem !== null) root.noBodyAtFinish = false
    }
  }

  Component.onCompleted: console.log("##KV## probe.error=none")

  Timer {
    interval: 16
    repeat: true
    running: !root.completed
    property int turn: 0
    onTriggered: {
      turn++
      if (turn === 1) {
        landSlot.open = true
        foldSlot.open = true
      } else if (turn === 20) {
        foldSlot.open = false
      } else if (turn === 30) {
        console.log("##KV## slot.before=" + landSlot.height.toFixed(1))
        landSlot.land()
      } else if (turn === 31) {
        console.log("##KV## slot.after=" + landSlot.height.toFixed(1))
        console.log("##KV## slot.held=" + landSlot._held)
        if (landSlot._nested) landSlot._nested.height = 8
      } else if (turn === 32) {
        console.log("##KV## slot.shrunk=" + landSlot.height.toFixed(1))
      } else if (turn === 33) {
        // Clear the legitimate hold, then queue a deferred write and retire
        // its hold in the same turn. The write must not land a stale target.
        landSlot.release()
        landSlot.land()
        landSlot.release()
      } else if (turn === 34) {
        console.log("##KV## slot.staleLandedHold=" + landSlot._landedHold)
        console.log("##KV## slot.staleHeld=" + landSlot._held)
      } else if (turn === 35) {
        // A fresh land after the release must still apply: the epoch guard
        // retires stale writes, not legitimate ones.
        landSlot.land()
      } else if (turn === 36) {
        console.log("##KV## slot.relandHold=" + landSlot._landedHold)
        console.log("##KV## slot.relandHeld=" + landSlot._held)
        landSlot.release()
      } else if (turn === 60) {
        console.log("##KV## slot.foldCloseFired=" + root.closeFired)
        console.log("##KV## slot.bodyDuringFold=" + root.bodySeenDuringClose)
        console.log("##KV## slot.noBodyAtFinish=" + root.noBodyAtFinish)
        console.log("##KV## slot.bodyAfterFold=" + (foldSlot.nestedItem !== null))
        console.log("##KV## slot.closingAfterFold=" + foldSlot.closing)
        console.log("##KV## slot.completed=true")
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}

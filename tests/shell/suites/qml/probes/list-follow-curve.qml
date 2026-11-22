import QtQuick
import Quickshell
import qs.common

// Follow seats use the bar's fast-start curve because a held key restarts the
// tween on every repeat. The larger reveal seats keep the gentle curve.

Item {
  id: root
  width: 400
  height: 240

  property bool completed: false

  List {
    id: followList
    width: 200
    height: 200
    model: 40
    delegate: Rectangle { width: 200; height: 34; color: "transparent" }
  }

  // A snapped land defers its follow one turn. Two lands to the same row in
  // one turn, with different view heights, must retire the older follow by
  // seat epoch: only the newer geometry is allowed to seat the view.
  List {
    id: deferredList
    width: 200
    height: 200
    model: 40
    delegate: Rectangle { width: 200; height: 34; color: "transparent" }
  }

  Component.onCompleted: console.log("##KV## probe.error=none")

  Timer {
    interval: 40
    repeat: true
    running: !root.completed
    property int turn: 0
    onTriggered: {
      turn++
      if (turn === 1) {
        followList.seatTo(40, true, "follow")
        console.log("##KV## curve.follow=" + followList.debugScrollEasing)
      } else if (turn === 2) {
        followList.seatTo(300, true, "reveal")
        console.log("##KV## curve.reveal=" + followList.debugScrollEasing)
        console.log("##KV## curve.outCubic=" + Easing.OutCubic)
        console.log("##KV## curve.inOutCubic=" + Easing.InOutCubic)
      } else if (turn === 3) {
        deferredList.traceDebug = true
        // Both seats name the same row in the same turn. The second is a
        // newer intent (its internal seatTo(0) bumps _seatEpoch), so the
        // first one's deferred follow must retire instead of re-seating
        // against the old viewH.
        deferredList.seat(0, "land", true, 20)
        deferredList.seat(0, "land", true, 400)
        console.log("##KV## deferred.seatsScheduled=true")
      } else if (turn === 4) {
        deferredList.traceDebug = false
        console.log("##KV## deferred.finalY=" + deferredList.contentY)
        console.log("##KV## deferred.newTarget=" +
          deferredList.centerTarget(0, 400))
        console.log("##KV## completed=true")
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}

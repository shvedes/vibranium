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
        console.log("##KV## completed=true")
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}

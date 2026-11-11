// Probe: common/process/StreamGuard.qml - the spawn window, line currency,
// deliberate stop and the failure/respawn path, driven over a real event loop.
//
// The child is a plain `sh -c` so the probe owns exactly what the guard is
// asked to supervise: one build that prints a line and stays alive, and one
// that exits immediately so the failure path is a real exit rather than a
// fabricated call.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root

  property int phase: 0
  property string lineText: ""
  property bool armed1: false
  property bool degraded1: false
  property bool armed2: true

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value))
  }

  StreamGuard {
    id: ok
    command: ["sh", "-c", "echo hello; sleep 30"]
    scope: "probe"
    key: "ok"
    spawnWatchMs: 200
    backoffBaseMs: 100
    backoffCapMs: 400
    onLine: data => root.lineText = data
  }

  StreamGuard {
    id: dead
    command: ["sh", "-c", "exit 3"]
    scope: "probe"
    key: "dead"
    spawnWatchMs: 200
    backoffBaseMs: 100
    backoffCapMs: 400
  }

  Timer {
    interval: 150
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) {
        ok.start()
      } else if (root.phase === 3) {
        root.armed1 = ok.armed
        root.degraded1 = ok.degraded
        ok.stop()
      } else if (root.phase === 4) {
        root.armed2 = ok.armed
        root.kv("line", root.lineText)
        root.kv("armed.after.start", root.armed1)
        root.kv("degraded.after.start", root.degraded1)
        root.kv("armed.after.stop", root.armed2)
        dead.start()
      } else if (root.phase === 7) {
        root.kv("dead.degraded", dead.degraded)
        root.kv("dead.fails", dead.fails)
        root.kv("dead.armed", dead.armed)
        console.log("##DONE##")
      }
    }
  }
}

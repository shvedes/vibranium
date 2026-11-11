// Benchmark probe: List.rowTop's prefix sum.
//
// rowTop is walked on every programmatic seat (a restore, a centerTarget, a
// followCursor off-screen). The old implementation summed rowHeightAt(i) per
// row, which re-derived _avg() and re-resolved the identity through
// rowIdentity on every step. The new one carries the fallback once and reads
// the row set's resolved identity array. Both are measured here over the same
// list and the same row count, so the number is the cost of the walk itself.
//
//   bash tests/shell/bench/list-rowtop.sh
//
// Not a suite: it lives outside suites/ so run-all.sh does not discover it.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 640
  height: 480

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value))
  }

  function mk(n) {
    const out = []
    for (let i = 0; i < n; i++) out.push("row" + i)
    return out
  }

  property var rows: mk(4000)
  // The row count walked. A count no delegate exists for keeps itemAtIndex
  // out of the measurement, which is the case rowTop's table path exists for.
  readonly property int steps: 4000
  readonly property int iters: 200

  List {
    id: bench
    width: parent.width
    height: parent.height
    model: root.rows
    delegate: Rectangle {
      width: bench.width
      height: 34
      color: "transparent"
    }
  }

  // The retired implementation, byte for byte: rowHeightAt per row plus the
  // gap. The new rowTop is asked for the same index.
  function oldRowTop(index) {
    let y = 0
    for (let i = 0; i < index; i++) {
      y += bench.rowHeightAt(i)
      y += bench.spacing
    }
    return y
  }

  function time(fn) {
    const t0 = Date.now()
    let sink = 0
    for (let it = 0; it < root.iters; it++) sink += fn(root.steps)
    kv("sink", sink)
    return Date.now() - t0
  }

  Timer {
    interval: 200
    repeat: false
    running: true
    onTriggered: {
      if (bench.count < root.steps) {
        kv("error", "list has " + bench.count + " rows")
        console.log("##DONE##")
        return
      }
      const oldMs = root.time(root.oldRowTop)
      const newMs = root.time(i => bench.rowTop(i))
      kv("rows", bench.count)
      kv("old.ms", oldMs)
      kv("new.ms", newMs)
      kv("old.us_per_walk", (oldMs * 1000 / root.iters).toFixed(1))
      kv("new.us_per_walk", (newMs * 1000 / root.iters).toFixed(1))
      kv("speedup", newMs > 0 ? (oldMs / newMs).toFixed(2) : "inf")
      console.log("##DONE##")
    }
  }
}

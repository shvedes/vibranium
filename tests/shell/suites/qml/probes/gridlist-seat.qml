// Probe: shell/common/ui/GridList.qml - the single seat funnel and the wrap
// sweep's edge release, driven in a real event loop and sampled frame by
// frame.
//
// GridList is the grid twin of List. It seats with positionViewAtIndex (cell
// accurate, immune to header/spacer arithmetic) and runs one wrap sweep.
// Before the funnel, five sites wrote the view position and a deferred
// Idle.run rewind wrote the captured sweepY0 back two turns later. A seat
// that landed between the wrap gesture and that rewind was undone one frame
// after it landed - a wrong frame followed by a glide from the stale value.
//
// Two things are pinned here, both as consecutive-frame observations:
//
//   1. EVERY programmatic seat (page, settle, reveal, jump) goes through the
//      same funnel as a keyboard step. The funnel owns a write counter; each
//      entry point must take exactly one seat, the same as moveBy does.
//   2. A page step taken after a wrap gesture is never pulled back to the
//      captured sweepY0. The wrap's sweep starts from the view's LIVE
//      contentY on the seat's change edge, so no later frame may show the
//      step being undone. The sweep itself is still sampled gliding on a
//      plain wrap, so the motion is not simply removed.
//
// The trailing two cells are non-selectable so a Down step off cell 39 wraps
// to cell 37 - the only shape that arms the sweep. A 400x200 viewport over
// 40 cells of 100x80 gives 800px of content and a 600px scroll range.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 640
  height: 480

  property int phase: 0
  property int threw: 0
  property var cyTrace: []        // every g contentY change: "phase:cy:sweeping"
  property var g2Trace: []        // every g2 contentY change: "phase:cy"
  property int stepMark: -1       // trace index right after the page step

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function safe(key, fn) {
    try { kv(key, fn()) }
    catch (e) { threw++; kv(key + ".threw", "" + (e && e.message ? e.message : e)) }
  }

  GridList {
    id: g
    width: 400
    height: 200
    cellWidth: 100
    cellHeight: 80
    cols: 4
    isSelectable: i => i < 38
    firstSelectable: () => 0
    lastSelectable: () => 37
    model: root.cells
    delegate: Component { Item { width: 100; height: 80 } }
    onContentYChanged: root.cyTrace.push(root.phase + ":" + Math.round(contentY) + ":" + (sweeping ? 1 : 0))
  }
  // A fresh grid for the page-step frame trace. The first one has a settled
  // layout and a history of seats, so its auto-scroll lands before the wrap
  // arms; a newly built grid keeps the origin at the top until the seat.
  GridList {
    id: gs
    width: 400
    height: 200
    cellWidth: 100
    cellHeight: 80
    cols: 4
    isSelectable: i => i < 38
    firstSelectable: () => 0
    lastSelectable: () => 37
    model: root.cells
    delegate: Component { Item { width: 100; height: 80 } }
    onContentYChanged: root.cyTrace.push(root.phase + ":" + Math.round(contentY) + ":" + (sweeping ? 1 : 0))
  }

  // A separate grid for the plain-wrap glide, untouched by a foreign seat.
  GridList {
    id: g2
    width: 400
    height: 200
    cellWidth: 100
    cellHeight: 80
    cols: 4
    isSelectable: i => i < 38
    firstSelectable: () => 0
    lastSelectable: () => 37
    model: root.cells
    delegate: Component { Item { width: 100; height: 80 } }
    onContentYChanged: root.g2Trace.push(root.phase + ":" + Math.round(contentY))
  }
  property var cells: {
    const a = []
    for (let i = 0; i < 40; i++) a.push("c" + i)
    return a
  }

  property var plan: [
    "", "defaults", "",
    "pathPage", "pathSettle", "pathReveal", "pathJump", "pathKey",
    "armWrap", "", "", "", "", "", "", "", "", "", "", "", "", "wrapEnd",
    "plainWrap", "", "", "", "", "", "", "", "", "", "", "", "plainEnd",
    "finish"
  ]

  Timer {
    interval: 10
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      const f = root.plan[root.phase]
      if (f) root[f]()
    }
  }

  // The funnel's write counter, sampled around one call of each entry point.
  function seatDelta(fn) {
    if (typeof g.seatTo !== "function") return "no-funnel"
    const before = g._seatWrites
    fn()
    return g._seatWrites - before
  }

  function defaults() {
    kv("probe.error", "none")
    kv("g.count", g.count)
    kv("g.maxY", Math.max(0, g.contentHeight - g.height))
    kv("g.hasSeatTo", typeof g.seatTo === "function")
    kv("g.writesStart", g._seatWrites === undefined ? "undefined" : g._seatWrites)
  }
  function pathPage() { kv("path.page", seatDelta(() => g.pageBy(0.5))) }
  function pathSettle() { kv("path.settle", seatDelta(() => g.settle(5))) }
  function pathReveal() { kv("path.reveal", seatDelta(() => g.reveal(10))) }
  function pathJump() { kv("path.jump", seatDelta(() => g.jumpEnd(true))) }
  function pathKey() { kv("path.key", seatDelta(() => g.moveBy(0, -1))) }

  // Arm the wrap sweep, then land a page step in the SAME turn, before any
  // deferred rewind can fire. The step value is the wrap target itself, so
  // a fixed build starts its sweep from live contentY and stays put. The
  // cursor and offset are set in this one turn so the view has not polished
  // a settled layout that would move the origin under the wrap.
  function armWrap() {
    gs.contentY = 0
    gs.gotoCell(39, false)
    const before = gs._seatWrites
    gs.moveCell(1)
    kv("wrap.sweeping", gs.sweeping)
    kv("wrap.y0", Math.round(gs.sweepY0))
    kv("wrap.to", Math.round(gs.sweepTo))
    root.stepMark = root.cyTrace.length
    gs.contentY = gs.sweepTo
    kv("wrap.afterStep", Math.round(gs.contentY))
    kv("wrap.releaseSeat", gs._seatWrites === undefined ? "no-funnel" : gs._seatWrites - before)
  }
  function wrapEnd() {
    const after = root.cyTrace.slice(root.stepMark)
    kv("wrap.trace", after.join(" "))
    // Count frames that fall back to the captured origin or below the step.
    let back = 0
    const step = gs.sweepTo
    for (const entry of after) {
      const cy = Number(entry.split(":")[1])
      if (cy < step - 0.5) back++
    }
    kv("wrap.backwards", back)
    kv("wrap.sweepingAfter", gs.sweeping)
  }

  // A plain wrap on a clean grid, with no foreign seat: the sweep must still
  // glide from its live start toward the target over consecutive frames.
  function plainWrap() {
    g2.contentY = 0
    g2.gotoCell(39, false)
    g2.moveCell(1)
    kv("plain.sweeping", g2.sweeping)
    kv("plain.y0", Math.round(g2.sweepY0))
    kv("plain.to", Math.round(g2.sweepTo))
  }
  function plainEnd() {
    kv("plain.trace", root.g2Trace.slice(-6).join(" "))
    kv("plain.sweepingAfter", g2.sweeping)
  }

  function finish() {
    kv("probe.threw", root.threw)
    kv("probe.completed", true)
    console.log("##DONE##")
  }
}

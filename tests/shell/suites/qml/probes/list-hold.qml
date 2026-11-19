import QtQuick
import Quickshell
import qs.common

// A held arrow/tab re-arms the content ease on every repeat. The bar and the
// content take one short linear leg together, so the bar holds the viewport
// centre while rows slide one at a time: no creeping bar, no one-frame full-row
// teleport, and no snap at the clamp boundary where centring stops. A wrap over
// the ends is one lap, not another leg of the hold, and keeps its own pace.

Item {
  id: root
  width: 400
  height: 300

  property bool completed: false
  property int turn: 0
  property var cys: []
  property var bars: []
  property var offs: []
  property var pins: []

  List {
    id: hold
    width: 300
    height: 200
    model: 40
    smoothScroll: true
    delegate: Rectangle { width: 300; height: 48; color: "transparent" }
  }

  function kv(k, v) { console.log("##KV## " + k + "=" + v) }
  function barScreenY() {
    const hl = hold.highlightItem
    return hl ? hl.y - hold.contentY : -1
  }
  function centreOffset() {
    const it = hold.currentItem
    if (!it) return -1e6
    return it.y + it.height / 2 - hold.contentY - hold.height / 2
  }

  Component.onCompleted: kv("probe.error", "none")

  Timer {
    interval: 16
    repeat: true
    running: !root.completed
    onTriggered: {
      root.turn++
      if (root.turn === 1) {
        // Start mid-list so every step has room to centre; at the very top
        // the clamp holds contentY at 0 and centring is impossible.
        hold.settle(10, false)
      } else if (root.turn <= 22) {
        // A repeat step every other frame (~32ms). Read the centre offset at
        // the step boundary, where the previous leg has landed; mid-leg the
        // row is still sliding into the centre under a pinned bar by design.
        if (root.turn % 2 === 0) {
          root.offs.push(root.centreOffset())
          hold.move(1, undefined, true)
        }
        root.cys.push(hold.contentY)
        root.bars.push(root.barScreenY())
        root.pins.push(hold.debugHoldLegMs > 0)
      } else if (root.turn === 23) {
        kv("hold.legArmed", root.pins[3] === true)
        let s0 = root.bars[3], lo = s0, hi = s0
        let maxStep = 0
        for (let i = 4; i < root.cys.length; i++) {
          lo = Math.min(lo, root.bars[i])
          hi = Math.max(hi, root.bars[i])
          maxStep = Math.max(maxStep, Math.abs(root.cys[i] - root.cys[i - 1]))
        }
        let maxOff = 0
        for (let i = 1; i < root.offs.length; i++) {
          maxOff = Math.max(maxOff, Math.abs(root.offs[i]))
        }
        kv("hold.barSpread", Math.round((hi - lo) * 10) / 10)
        kv("hold.barPinned", (hi - lo) < 0.5)
        kv("hold.maxFrameStep", Math.round(maxStep * 10) / 10)
        kv("hold.rowH", Math.round(hold.rowHeightAt(0) * 10) / 10)
        kv("hold.noTeleport", maxStep < hold.rowHeightAt(0))
        kv("hold.maxCentreOffset", Math.round(maxOff * 10) / 10)
        kv("hold.centred", maxOff < 15)
      } else if (root.turn === 55) {
        // The hold has long landed: the short leg is spent and the bar sits
        // on its row, so the next step takes the normal single-step glide.
        const idx = hold.currentIndex
        kv("after.legSpent", hold.debugHoldLegMs === 0)
        kv("after.landed", Math.abs(hold.contentY - hold.centerTarget(idx)) < 0.5)
        kv("after.barOnRow", Math.abs(root.barScreenY()
          - (hold.rowTop(idx) - hold.contentY)) < 0.5)
        // A wrap is a lap over the whole list, not a hold leg: no short leg,
        // and the seat keeps its length-derived pace.
        hold.currentIndex = hold.count - 1
        hold.contentY = hold.clampY(Infinity)
        hold.move(1, undefined, true)
        kv("wrap.noLeg", hold.debugHoldLegMs === 0)
        kv("wrap.toFirst", hold.currentIndex === 0)
        kv("wrap.sweep", hold._sweepMs)
        kv("wrap.lengthPaced", hold._sweepMs > Ui.fastMs)
        console.log("##DONE##")
        root.completed = true
      }
    }
  }
}

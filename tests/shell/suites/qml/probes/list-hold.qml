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
  // Ten repeats, each measured at the landing edge of its own short leg.
  property int steps: 0
  property int lastStepTurn: 0
  property bool measuring: true
  property int resultTurn: -1
  property var cys: []
  property var bars: []
  property var pins: []
  property var offs: []

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

  // A repeat leg is Ui.fastMs / 4 = 30ms, while this timer runs every 16ms.
  // Sampling "two timer turns after the step" reads the centre BEFORE the
  // animation's second frame when the two clocks are out of phase: under
  // full-suite load that observed 21.7-23.3px, half of a 48px row, although
  // the leg lands at zero offset. Measure at the completion edge instead.
  // The 15px ceiling stays: on a landed leg the cursor centre must coincide
  // with the viewport centre, so a limit well below a third of the fixture's
  // 48px row still rejects both an unfinished leg and a whole-row cut.
  function reportHold() {
    const s0 = bars.length > 0 ? bars[0] : barScreenY()
    let lo = s0, hi = s0
    let maxStep = 0
    let fractional = 0
    for (let i = 1; i < cys.length; i++) {
      const d = Math.abs(cys[i] - cys[i - 1])
      maxStep = Math.max(maxStep, d)
      // Read the raw step, not its printed one-decimal rounding: a 30.04px
      // frame prints as "30" and a string check would call an eased leg an
      // integer cut. At least one genuinely fractional frame per hold is
      // the edge an eased leg has and a whole-row teleport does not.
      if (d > 0 && Math.abs(d - Math.round(d)) > 0.001) fractional++
    }
    for (let i = 0; i < bars.length; i++) {
      lo = Math.min(lo, bars[i])
      hi = Math.max(hi, bars[i])
    }
    let legArmed = false
    for (let i = 0; i < pins.length; i++) {
      if (pins[i] === true) { legArmed = true; break }
    }
    let maxOff = 0
    for (let i = 0; i < offs.length; i++) {
      maxOff = Math.max(maxOff, Math.abs(offs[i]))
    }
    kv("hold.legArmed", legArmed)
    kv("hold.barSpread", Math.round((hi - lo) * 10) / 10)
    kv("hold.barPinned", (hi - lo) < 0.5)
    kv("hold.maxFrameStep", Math.round(maxStep * 10) / 10)
    kv("hold.fractionalFrames", fractional)
    kv("hold.rowH", Math.round(hold.rowHeightAt(0) * 10) / 10)
    kv("hold.noTeleport", maxStep < hold.rowHeightAt(0))
    kv("hold.samples", offs.length)
    kv("hold.maxCentreOffset", Math.round(maxOff * 10) / 10)
    kv("hold.centred", maxOff < 15)
  }

  Component.onCompleted: kv("probe.error", "none")

  // contentY is written once per animation frame by the list's one seat
  // writer. Reading it on that edge measures the actual frame step: polling
  // it on a 16ms timer samples two clocks that drift under load, where one
  // whole eased leg (a 50px row pitch) can fall between two timer turns and
  // look like a one-frame teleport. The centre offset stays on the landing
  // edge below; this is only the frame-step sample.
  Connections {
    target: hold
    function onContentYChanged() {
      if (root.measuring) root.cys.push(hold.contentY)
    }
  }

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
        return
      }
      if (!root.measuring) {
        // The last short leg has landed and been measured. Leave it well
        // behind, then read the landed state and the wrap.
        if (root.turn < root.resultTurn + 30) return
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
        return
      }

      // The bar and the arm flag are polled on the timer; the frame step is
      // sampled on contentY's own write edge (above). The centre offset is
      // only meaningful once the leg has landed: mid-leg the row is still
      // sliding into the centre by design.
      root.bars.push(root.barScreenY())
      root.pins.push(hold.debugHoldLegMs > 0)

      // A repeat arrives at the key's cadence, but never before the previous
      // leg has landed. Waiting for this edge is what keeps the measurement
      // off a frame that the 30ms leg has not reached yet.
      if (hold.debugAnimRunning || hold.debugHoldLegMs > 0) return
      if (root.turn - root.lastStepTurn < 2) return
      if (root.steps === 0) {
        // The settle landed: take the first repeat step now. Its own landing
        // is the first offset that gets measured.
        root.steps = 1
        root.lastStepTurn = root.turn
        hold.move(1, undefined, true)
        return
      }
      root.offs.push(root.centreOffset())
      if (root.steps < 10) {
        root.steps++
        root.lastStepTurn = root.turn
        hold.move(1, undefined, true)
      } else {
        root.reportHold()
        root.measuring = false
        root.resultTurn = root.turn
      }
    }
  }
}

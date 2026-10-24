// Probe: the instantiation policy of shell/common/ui/List.qml - how many
// delegates a list actually builds, as a function of model size, and whether
// the cacheBuffer policy at List.qml:1420 does what Ui.qml:96-106 claims.
//
// Why this needs its own probe: `list-test.sh` pins the policy's CONSTANTS
// (listFullRows 150, the 100000px small-list buffer, the 300px wall buffer).
// Constants are what the source says; this measures what the engine does with
// them. Nothing else in the tree can answer "is the last row of a 150-row list
// a live delegate", because that is a property of Qt's prefetch, not of any
// QML expression - and it is the load-bearing claim behind the policy: the
// Ui.qml comment says a sub-threshold list "instantiate[s] every delegate, so
// layout is exact and wrap seats never traverse estimates", and that every
// consumer of a small list depends on it (the `autoCache` comment at
// List.qml:1416-1418 names the menu and the launcher).
//
// The cap's stated purpose is cost ("A cost cap in rows, the unit cost scales
// with"). Cost has two parts, and only one of them is worth asserting:
//
//   - HOW MANY delegates exist. Deterministic, machine-independent, and
//     exactly the quantity the cap is meant to bound. Pinned below.
//   - HOW LONG they take to build. Real, but it is a property of this
//     machine's CPU and of the offscreen platform plugin, so asserting a
//     millisecond figure here would be a flaky test wearing a number as a
//     costume. Measured, reported, and deliberately not asserted.
//
// The delegate is mandatory, for the reason list.qml's own header spells out:
// a QQuickListView that never receives one never gets its model at all, so
// every fixture below supplies one.
//
// Fixture geometry is held constant so the only variable is model size: a
// 300x300 viewport, Ui.rowMinH (34) delegates, List.qml's default 2px spacing
// - a 36px row pitch, so the viewport holds eight rows and a whole 150-row
// list is 5382px of content.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 640
  height: 480

  property int phase: 0
  property int threw: 0
  // Build cost, reported but not asserted - see the header.
  property real buildMs: -1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      threw++
      kv(key + ".threw", "" + (e && e.message ? e.message : e))
    }
  }

  // ---- fixtures --------------------------------------------------------

  function mk(n) {
    const out = []
    for (let i = 0; i < n; i++) out.push("row" + i)
    return out
  }

  readonly property int threshold: Ui.listFullRows

  // One row below the threshold, one row at it, and two walls: the smallest
  // wall (past the threshold by 50) and a 4-digit one (the case the policy
  // exists for). The last two must cost the same to hold.
  property var rowsSub: mk(threshold - 1)
  property var rowsAt: mk(threshold)
  property var rowsWall: mk(threshold + 50)
  property var rowsHuge: mk(2000)
  property var rows8: mk(8)

  component Row: List {
    width: 300
    height: 300
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // A sub-threshold list, and one exactly at the threshold: the policy reads
  // `count < listFullRows`, so these two are on opposite sides of the branch.
  Row {
    id: sub
    model: root.rowsSub
  }

  Row {
    id: atThreshold
    model: root.rowsAt
  }

  // The 200-row wall and the 4-digit wall, otherwise identical.
  Row {
    id: wall
    model: root.rowsWall
  }

  Row {
    id: huge
    model: root.rowsHuge
  }

  // The compatibility gate: autoCache false is documented as restoring a zero
  // buffer, and the menu and launcher are named as depending on the far end
  // being instantiated - so the gate has to actually be load-bearing.
  //
  // Both fixtures below hold rows that FIT the viewport, because with a zero
  // buffer a row the viewport cannot show is simply not built: a 149-row list
  // in 300px loses its far end whichever way the gate is set, which would
  // make the gate look inert. Eight rows at a 36px pitch is 250px, so the
  // whole list is inside the viewport and the buffer is the only variable.
  Row {
    id: noCache
    autoCache: false
    model: root.rowsWall
  }

  Row {
    id: noCacheSmall
    autoCache: false
    model: root.rows8
  }

  // The paired control for the same eight rows with the buffer left on.
  Row {
    id: control
    model: root.rows8
  }

  // ---- helpers ---------------------------------------------------------

  // The authoritative count: how many indices have a live delegate.
  //
  // The obvious proxy - contentItem.children.length - is not it. Measured on
  // a 149-row sub-threshold list it reads 151, two more than the model
  // holds, because contentItem carries view-internal items alongside the
  // delegates. Both numbers are reported below so the gap stays visible, but
  // only this one drives the assertions: it asks the engine the question the
  // policy is about ("does row N exist?") instead of counting objects in a
  // container the view also uses for its own bookkeeping.
  //
  // itemAtIndex does NOT instantiate; it answers null for a row the view has
  // not built, which is exactly the distinction under test.
  function live(v) {
    let n = 0
    for (let i = 0; i < v.count; i++) {
      if (v.itemAtIndex(i) !== null && v.itemAtIndex(i) !== undefined) n++
    }
    return n
  }

  // contentItem's raw child count, reported beside the real one.
  function children(v) {
    return v.contentItem ? v.contentItem.children.length : -1
  }

  // A delegate is live when itemAtIndex hands back an item rather than null.
  // This is the direct form of the claim: not "a count looks right" but "the
  // far row exists".
  function isLive(v, i) {
    return v.itemAtIndex(i) !== null && v.itemAtIndex(i) !== undefined
  }

  // ---- phases ----------------------------------------------------------

  // The branch itself: the buffer each side of the threshold resolves to, so
  // the measurements below are attributable to this expression and not to
  // anything else about the fixtures.
  function buffers() {
    safe("b.sub", function() { return sub.cacheBuffer })
    safe("b.subCount", function() { return sub.count })
    safe("b.at", function() { return atThreshold.cacheBuffer })
    safe("b.atCount", function() { return atThreshold.count })
    safe("b.wall", function() { return wall.cacheBuffer })
    safe("b.wallCount", function() { return wall.count })
    safe("b.huge", function() { return huge.cacheBuffer })
    safe("b.hugeCount", function() { return huge.count })
    safe("b.noCache", function() { return noCache.cacheBuffer })
    safe("b.noCacheSmall", function() { return noCacheSmall.cacheBuffer })
    safe("b.control", function() { return control.cacheBuffer })
    safe("b.threshold", function() { return root.threshold })
    safe("b.rowPitch", function() { return Ui.rowMinH + sub.spacing })
    safe("b.viewportRows", function() {
      return Math.floor(sub.height / (Ui.rowMinH + sub.spacing))
    })
    // The gap between "children of contentItem" and "rows with a delegate".
    safe("b.subChildren", function() { return children(sub) })
    safe("b.wallChildren", function() { return children(wall) })
    safe("b.hugeChildren", function() { return children(huge) })
  }

  // Sub-threshold: the whole list is instantiated, far end included. This is
  // the contract the wrap seats and the exact layout depend on.
  function smallFull() {
    safe("s.count", function() { return sub.count })
    safe("s.live", function() { return live(sub) })
    root.firstSubLive = live(sub)
    safe("s.liveIsWhole", function() { return live(sub) === sub.count })
    safe("s.lastLive", function() { return isLive(sub, sub.count - 1) })
    safe("s.midLive", function() { return isLive(sub, Math.floor(sub.count / 2)) })
    // The measured-height table therefore has no gaps to estimate through.
    safe("s.knownH", function() { return Object.keys(sub._knownH).length })
    safe("s.knownHWhole", function() {
      return Object.keys(sub._knownH).length === sub.count
    })
    // And the same holds one row below the threshold and exactly at it: the
    // branch is `< listFullRows`, so 150 itself is a wall.
    safe("s.atCount", function() { return atThreshold.count })
    safe("s.atLive", function() { return live(atThreshold) })
    safe("s.atBufferIsWall", function() {
      return atThreshold.cacheBuffer === Ui.listFullBuffer ? "small" : "wall"
    })
    safe("s.atLastLive", function() { return isLive(atThreshold, atThreshold.count - 1) })
  }

  // Above the threshold: instantiation is bounded, and - the load-bearing
  // property - the bound does not move with the model.
  function wallBounded() {
    safe("w.count", function() { return wall.count })
    safe("w.live", function() { return live(wall) })
    root.firstWallLive = live(wall)
    safe("w.liveLtCount", function() { return live(wall) < wall.count })
    safe("w.lastLive", function() { return isLive(wall, wall.count - 1) })
    safe("w.midLive", function() { return isLive(wall, Math.floor(wall.count / 2)) })
    safe("w.knownH", function() { return Object.keys(wall._knownH).length })
    // The wall is estimated, not measured: the table knows far fewer rows
    // than the model holds, which is what makes the cap free.
    safe("w.knownLtCount", function() { return Object.keys(wall._knownH).length < wall.count })
    safe("w.avgH", function() { return wall._avgH })
    safe("w.tableTotal", function() { return Math.round(wall.tableTotal()) })
    safe("w.tableTotalFormula", function() {
      return wall.count * (Ui.rowMinH + wall.spacing) - wall.spacing
    })
    safe("w.tableMatchesContent", function() {
      return Math.abs(wall.tableTotal() - wall.contentHeight) < 1
    })
  }

  // A 4-digit model must not cost more to hold than a 200-row one. This is
  // the assertion that turns "a cost cap in rows" from a claim into a fact:
  // the live delegate count is the cost driver, and it is flat.
  function hugeCostsTheSame() {
    safe("h.count", function() { return huge.count })
    safe("h.live", function() { return live(huge) })
    root.firstHugeLive = live(huge)
    safe("h.liveEqWall", function() { return live(huge) === live(wall) })
    safe("h.liveLtCount", function() { return live(huge) < huge.count })
    safe("h.lastLive", function() { return isLive(huge, huge.count - 1) })
    safe("h.tableTotal", function() { return Math.round(huge.tableTotal()) })
    safe("h.tableTotalFormula", function() {
      return huge.count * (Ui.rowMinH + huge.spacing) - huge.spacing
    })
    safe("h.knownH", function() { return Object.keys(huge._knownH).length })
    // Still usable: the cursor can be seated into a wall it cannot see.
    safe("h.settleIndex", function() {
      huge.settle(huge.count - 1, true)
      return huge.currentIndex
    })
    safe("h.settleInRange", function() {
      return huge.currentIndex >= 0 && huge.currentIndex < huge.count
    })
  }

  // The compat gate. autoCache false restores a zero buffer, so the same 200
  // rows instantiate strictly fewer delegates - the buffer is the whole
  // difference between the two fixtures.
  function gateIsLoadBearing() {
    safe("g.buffer", function() { return noCache.cacheBuffer })
    safe("g.live", function() { return live(noCache) })
    safe("g.wallLive", function() { return live(wall) })
    safe("g.fewerThanBuffered", function() { return live(noCache) < live(wall) })
    safe("g.lastLive", function() { return isLive(noCache, noCache.count - 1) })
    // Eight rows at a 36px pitch is 250px, inside the 300px viewport, so the
    // whole list is built with the buffer off. That is what makes the gate
    // safe to expose: turning it off costs prefetch, not correctness, for
    // anything the viewport already covers.
    safe("g.smallCount", function() { return noCacheSmall.count })
    safe("g.smallLive", function() { return live(noCacheSmall) })
    safe("g.smallWhole", function() { return live(noCacheSmall) === noCacheSmall.count })
    safe("g.smallLastLive", function() {
      return isLive(noCacheSmall, noCacheSmall.count - 1)
    })
    // The paired control: the same eight rows with the buffer ON.
    safe("g.bufferedSmallLive", function() { return live(control) })
    safe("g.bufferedSmallWhole", function() { return live(control) === control.count })
  }

  // The cost figure, measured and deliberately not asserted. Building the
  // 4-digit list from an empty model is the single most expensive thing any
  // consumer of this component can ask for on open or on a filter keystroke,
  // so it is worth having in the output even though its value belongs to the
  // machine rather than to the component.
  function buildCost() {
    root.buildMs = -1
    const t0 = Date.now()
    huge.model = []
    huge.model = root.rowsHuge
    root.buildMs = Date.now() - t0
    kv("c.buildMs", Math.round(root.buildMs))
    kv("c.buildRows", huge.count)
    kv("c.buildLive", live(huge))
    // The same swap on a sub-threshold list, for the ratio the comment
    // asserts ("the unit cost scales with") measured rather than claimed.
    const t1 = Date.now()
    sub.model = []
    sub.model = root.rowsSub
    kv("c.smallBuildMs", Date.now() - t1)
    kv("c.smallBuildRows", sub.count)
    kv("c.smallBuildLive", live(sub))
  }

  // The measurement has to have stopped moving by the time it is read, or
  // "bounded" would only mean "bounded so far". The counts taken in the phases
  // above are held here and re-compared a beat later, so every assertion is
  // "still the same number" rather than "a number".
  property int firstSubLive: -1
  property int firstWallLive: -1
  property int firstHugeLive: -1

  function settled() {
    safe("z.subLive", function() { return live(sub) })
    safe("z.wallLive", function() { return live(wall) })
    safe("z.hugeLive", function() { return live(huge) })
    safe("z.subUnchanged", function() { return live(sub) === root.firstSubLive })
    safe("z.wallUnchanged", function() { return live(wall) === root.firstWallLive })
    safe("z.hugeUnchanged", function() { return live(huge) === root.firstHugeLive })
    safe("z.hugeStillFlat", function() { return live(huge) === live(wall) })
    safe("z.subStillWhole", function() { return live(sub) === sub.count })
    safe("z.probeThrew", function() { return root.threw })
  }

  function finish() {
    kv("probe.error", "none")
    kv("probe.threw", root.threw)
    console.log("##DONE##")
  }

  property var plan: [
    "", "buffers", "smallFull", "wallBounded", "hugeCostsTheSame",
    "gateIsLoadBearing", "buildCost", "", "", "settled", "finish"
  ]

  Timer {
    id: pump
    interval: 12
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase < root.plan.length) {
        const f = root.plan[root.phase]
        if (f) root[f]()
      }
    }
  }
}

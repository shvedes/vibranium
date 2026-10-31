// Probe: shell/common/ui/List.qml - the selection state machine, the
// keyboard-navigation step functions and the scroll/velocity model, driven
// in a real event loop and read back.
//
// Why this works offscreen: QT_QPA_PLATFORM=offscreen suppresses the render
// loop, not the binding, layout or animation passes. A ListView placed in a
// live scene gets its delegates polished, its contentHeight settled and its
// NumberAnimation driven, so selection, the measured height table, the seat
// writer and an in-flight content tween are all observable here.
//
// THE DELEGATE IS NOT OPTIONAL, and that is the one hard requirement of this
// probe. A QQuickListView that never receives a `delegate` never gets its
// model: count stays 0, currentIndex stays -1, contentHeight stays 0, and
// every selection entry point reports "nothing to do" without any error. The
// first draft of this probe declared `model: rows` and nothing else, saw
// count 0 on a list with eight rows, and nearly recorded that as a component
// bug. `List.qml` sets no delegate of its own - every consumer supplies one -
// so the probe supplies one too, which is the real usage anyway.
//
// Everything after construction is driven from the phase counter, one
// function per turn, so a value that is only correct once bindings have
// settled is read after it settled and a tween is read while it is still in
// flight.
//
// Three defects this probe pins as they are today, each with the reason it is
// wrong in the driver's notes: `wrap: false` does not clamp (move() mods
// unconditionally), `restoreAt()` seats the cursor on a non-selectable row
// when nothing in the list is selectable, and a `seatTo` that does not move
// the view returns before the ownership reset, leaving a stale cursor claim
// armed. All are asserted as observed, so a fix turns the suite red instead of
// passing silently.

import QtQuick
import Quickshell
import qs.common

Item {
  id: root
  width: 640
  height: 480

  property int phase: 0
  property int threw: 0
  // Every _sweepMs the engine itself writes during a traversal, so the
  // "a sweep is never longer than _sweepMaxMs" invariant is checked against
  // the component's own writes rather than against a call the probe made.
  property var sweepTrace: []
  property var trace: []
  property int mf: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // safe() keeps one failed read from taking the whole run down: the key that
  // failed is simply never printed, which the driver reports as "the probe
  // never printed key X" rather than as a wrong number.
  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      threw++
      kv(key + ".threw", "" + (e && e.message ? e.message : e))
    }
  }

  // ---- fixtures --------------------------------------------------------
  //
  // One list per behaviour cluster. All delegates are 34px (Ui.rowMinH)
  // unless the case is about row height, so every geometry number below is
  // 34 tall with 2px spacing - a 36px row pitch.

  function mk(n) {
    const out = []
    for (let i = 0; i < n; i++) out.push("row" + i)
    return out
  }

  property var rows8: mk(8)
  property var rows6: mk(6)
  property var rows30: mk(30)
  property var replacement: mk(9)
  // The slotrow delegate's shape, driven by the probe: a resting row, and a
  // row whose slot is unfolding toward the destination it publishes.
  property real slotRowH: Ui.rowMinH
  property real slotRowSettled: Ui.rowMinH
  // The claim as it stood the moment the slot opened, so the constancy
  // assertion below has something to compare against.
  property real claimBeforeUnfold: -1
  // The claimed row's slot duration, as a real row publishes it.
  property int slotRowMs: 0
  // Which row carries the open slot. Only ONE row is ever tall in a real
  // delegate (a dropdown belongs to the row it opened on), and the height
  // table is a per-row sum, so inflating every row would make the settled
  // total describe a page that does not exist.
  property int slotClaim: -1
  // The two viewports, from the row geometry rather than written out: ten
  // resting rows are 10 * (rowMinH + spacing) - spacing, which is a viewport
  // that shows all of them, and six of the twenty is one that does not.
  readonly property real slotroomRestH: 10 * (Ui.rowMinH + base.spacing) - base.spacing
  readonly property real slotwallViewH: 6 * (Ui.rowMinH + base.spacing) - base.spacing

  // Defaults only, never mutated. Every documented default is read here.
  List {
    id: base
    width: 300
    height: 300
    model: root.rows8
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // wrap:false - the clamping case. Eight rows in a 300px viewport, so the
  // content fits and nothing scrolls: the only variable is the cursor.
  List {
    id: clamp
    width: 300
    height: 300
    wrap: false
    model: root.rows8
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // A hole in the middle of the predicate.
  List {
    id: skipper
    width: 300
    height: 120
    isSelectable: i => i !== 2
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // The last row is the hole: jumpEnd(true) has to stop on 4.
  List {
    id: tailHole
    width: 300
    height: 120
    isSelectable: i => i !== 5
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // Nothing is selectable anywhere.
  List {
    id: nothingOk
    width: 300
    height: 120
    isSelectable: i => false
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // One row: every step is a documented no-op.
  List {
    id: solo
    width: 300
    height: 300
    model: ["only"]
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // No rows at all. Every public entry point has to survive this.
  List {
    id: empty
    width: 300
    height: 300
    model: []
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // 200 rows: past Ui.listFullRows, so the cache buffer drops and the height
  // table - not the live layout - answers rowTop/tableTotal.
  List {
    id: wall
    width: 300
    height: 120
    model: mk(200)
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // The animated seat: smoothScroll on, a 30-row wall in a 120px viewport.
  List {
    id: smooth
    width: 300
    height: 120
    smoothScroll: true
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // scrolloff needs a viewport taller than its own margin to hold anything.
  List {
    id: wide
    width: 300
    height: 400
    scrolloff: 2
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // The snapping land: thirty rows in a 120px viewport, so the row a land
  // names can only be placed by a follow - the content does not fit.
  List {
    id: landing
    width: 300
    height: 120
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // A delegate carrying slotMotionMs, which is what the resize duration keys
  // off. plainHeight is the same list without it.
  List {
    id: slotty
    width: 300
    height: 300
    model: root.rows6
    delegate: Component {
      Item {
        property int slotMotionMs: 200
        width: ListView.view.width
        height: 40
      }
    }
  }

  List {
    id: plainHeight
    width: 300
    height: 300
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: 40 } }
  }

  // The growth claim's two regimes (see growClaim), same slot-shaped
  // delegate: slotRow drives the row's live height and the destination it
  // publishes as settledHeight, which is the property rowSettledHeight
  // reads - so a probe drives the real contract rather than a stand-in.
  //
  //   slotroom - ten rows in a viewport that shows all of them, so there is
  //              no scroll room at all and a slot on the last row can only be
  //              revealed by a taller region. This is the shape a capped
  //              card has: the resting region IS the content, so a dropdown
  //              on the bottom row has nowhere to scroll to.
  //   slotwall - twenty rows in a viewport that shows six, so the same slot
  //              on a row with more content below it is a scroll, not a
  //              resize. This is the shape a page longer than its cap has.
  List {
    id: slotroom
    width: 300
    height: slotroomRestH
    model: 10
    // slotMotionMs is the property revealSlotMs reads: it is how a row says
    // how long its own slot takes, and it is non-zero only while that slot is
    // open or mid-close. Carried here so the published duration is the real
    // contract rather than a number the probe made up.
    delegate: Component {
      Item {
        readonly property int slotMotionMs:
          index === root.slotClaim ? root.slotRowMs : 0
        width: ListView.view.width
        height: index === root.slotClaim ? root.slotRowH : Ui.rowMinH
        readonly property real settledHeight:
          index === root.slotClaim ? root.slotRowSettled : Ui.rowMinH
      }
    }
  }

  List {
    id: slotwall
    width: 300
    height: slotwallViewH
    model: 20
    delegate: Component {
      Item {
        width: ListView.view.width
        height: index === root.slotClaim ? root.slotRowH : Ui.rowMinH
        readonly property real settledHeight:
          index === root.slotClaim ? root.slotRowSettled : Ui.rowMinH
      }
    }
  }

  // Identity collision: every row claims the same identity key.
  List {
    id: dupe
    width: 300
    height: 120
    rowIdentity: i => "same"
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // measureGuard says no: nothing may be learned.
  List {
    id: guarded
    width: 300
    height: 120
    measureGuard: i => false
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // maxKnownH 6 against 30 measurable rows: the eviction has to bite.
  List {
    id: bounded
    width: 300
    height: 120
    maxKnownH: 6
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // Breathing room below the last row, and a matched twin without it.
  List {
    id: trailing
    width: 300
    height: 120
    trailSpace: 40
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  List {
    id: twin
    width: 300
    height: 120
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // The velocity floor taken away: the table term has to carry scrollVel.
  List {
    id: noVpx
    width: 300
    height: 120
    scrollVpx: 0
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // restingContentHeight claiming the content fits: the seat has to hold.
  List {
    id: resting
    width: 300
    height: 120
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // A second instance in the same scene, for the no-shared-state check.
  List {
    id: sibling
    width: 200
    height: 90
    model: root.rows6
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // A list short enough that every delegate is instantiated, so every step
  // really seats - and with smoothScroll on, so the seat is animated and the
  // pre-armed sweep is not released in the same turn. Two conditions, both
  // needed: on the default (instant) seat path seatTo clears _sweepMs itself,
  // and on a 200-row wall the cursor's delegate is usually not instantiated
  // yet, so no seat starts inside move() at all.
  List {
    id: sweeper
    width: 300
    height: 120
    smoothScroll: true
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // The row-set transitions, read through their own enabled gates.
  List {
    id: rowmotion
    width: 300
    height: 120
    model: root.rows6
    delegate: Component { Rectangle { width: ListView.view.width; height: Ui.rowMinH; color: "red" } }
  }

  // Hold-span fixture: a land seat must still hold the gate several
  // turns later. Turns drain inside one frame while the displaced
  // flight spans wall time, so a turn-counted release lets go
  // pre-flight; the wall floor below is what spans it. Headless turns
  // drain in milliseconds, so a hold read here is the floor working.
  List {
    id: holdback
    width: 300
    height: 300
    rowMotion: true
    highlightMotion: true
    model: root.rows8
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // Pin fixture: eight rows in a viewport that shows them all, so every
  // row is instantiated and the cursor row's geometry is the real one.
  List {
    id: pinned
    width: 300
    height: 300
    model: root.rows8
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // Keep-arm fixture: a list over a KEYED model, so the model's content can
  // change while the model itself stays the same object - the shape the
  // menu's search projection has (the rows it installs keep the uids of
  // the rows they replace, so the row under the cursor stays at its index
  // and the cursor never moves). The card grows under it, which is what the
  // projection's reserved chevron does to the width of the rows.
  property var keepRows: [
    { uid: "k0", label: "Keep zero" },
    { uid: "k1", label: "Keep one" },
    { uid: "k2", label: "Keep two" }
  ]
  ScriptModel {
    id: keepModel
    values: root.keepRows
    objectProp: "uid"
    comparisonMode: ObjectComparison.Identity
  }
  List {
    id: kept
    width: 300
    height: 300
    model: keepModel
    rowIdentity: index => String(keepModel.values[index]?.uid ?? index)
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }

  // Swap-scroll fixture: thirty rows in a 120px viewport, so the view has
  // somewhere to be that is not the top.
  List {
    id: scrolled
    width: 300
    height: 120
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }
  property var rows29: mk(29)
  property var rows30b: mk(30)

  // Settle fixture: the same shape as the swap-scroll one, and for the
  // same reason - a list with room to scroll is the only shape where a
  // removal at the tail of the content costs the view anything.
  List {
    id: settleList
    width: 300
    height: 120
    model: root.rows30
    delegate: Component { Item { width: ListView.view.width; height: Ui.rowMinH } }
  }
  property real settleBefore: 0
  property real settleY: 0
  property real settleBar: -1
  property real settleBarAfterClaim: -1
  property real settleBarAfterScroll: -1

  // Tail-swap fixture: twelve rows in a 120px viewport. A removal at the END
  // of the model moves no survivor, so the healed content owes exactly one
  // row of scroll (44px) and nothing else - and that is the one shape a model
  // swap can turn into the whole list jumping, because every position the
  // view passes through on the way is painted.
  //
  // The rows are born at their floor and reach their resting height a turn
  // later, which is what the clipboard's own replacement rows do (their text
  // is not laid out at birth) and what makes the content under-report its
  // own extent right after the write. A fixture whose rows were simply
  // shorter cannot reproduce it: the swap's scroll bound would be computed
  // against a settled content and there would be nothing to survive.
  List {
    id: tail
    width: 300
    height: 120
    // No item recycling: the model reset has to recreate the rows for them
    // to be newborn, which is the state under test.
    reuseItems: false
    model: root.rows12
    delegate: Component {
      Item {
        id: td
        width: ListView.view.width
        property int born: root.phase
        height: (root.phase - td.born) > 1 ? 42 : 34
        Component.onCompleted: td.born = root.phase
      }
    }
  }
  property var rows12: mk(12)
  property var rows11: mk(11)
  property real tailBefore: 0
  property var tailTrace: []
  property int tailGen: 0
  property int tailTurn: 0
  property int tailTurnsAtEnd: -1

  // ---- the event loop --------------------------------------------------

  // One turn per step, and a long tail of empty turns after the animated seat
  // so the content tween is sampled in flight and again after it lands.
  property var plan: [
    "", "defaults", "arithShort", "arithWall", "arithEmpty",
    "selDown", "selWrap", "selClamp", "selPredicate", "selAllBad",
    "selTailHole", "selSolo", "selRestore", "emptySweep", "modelSwap",
    "scrollModel", "scrolloff", "landSeat", "landFollow", "landSwap", "landSwapFollow",
    "landHint",
    "seats", "seatHold", "pursuit", "growClaim",
    "seatHoldEarly", "sweepState",
    "motionGate", "animStart", "animSample1", "animSample2", "animSample3",
    "layout", "tableBounds", "isolation", "nonMutation",
    "barPin", "keepArm", "keepArmBar", "keepArmMove", "swapScroll",
    "swapTailPark", "swapTailWrite",
    "swapTailSample", "swapTailSample", "swapTailSample",
    "swapTailSample", "swapTailSample", "swapTailSample",
    "swapTailEnd", "swapTailIdle", "swapTailYield",
    "settlePark", "", "", "", "holdScreen",
    "settlePark", "", "", "", "settleArm", "settleRelease",
    "settleSample", "settleSample", "settleSample", "settleSample",
    "settleSample", "settleSample", "settleSample", "settleSample",
    "settleSample", "settleSample", "settleSample", "settleSample",
    "settleSample", "settleSample", "settleSample", "settleSample",
    "settleLanded",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "animLanded", "animRest", "final", "finish"
  ]

  Timer {
    id: pump
    interval: 8
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

  Component.onCompleted: {
    kv("probe.error", "none")
    smooth.motionFinished.connect(function () { root.mf++ })
  }

  // ---- steps -----------------------------------------------------------

  // The documented defaults, and what a freshly constructed list already
  // knows. A ListView seats currentIndex 0 on a non-empty model, so the
  // initial selection of this component is row 0, not -1.
  function defaults() {
    kv("d.count", base.count)
    kv("d.initialIndex", base.currentIndex)
    kv("d.initialItem", base.currentItem === null ? "null" : "live")
    kv("d.emptyInitialIndex", empty.currentIndex)
    kv("d.soloInitialIndex", solo.currentIndex)
    kv("d.wrap", base.wrap)
    kv("d.centerCursor", base.centerCursor)
    kv("d.smoothScroll", base.smoothScroll)
    kv("d.scrolloff", base.scrolloff)
    kv("d.selectionHighlight", base.selectionHighlight)
    kv("d.highlightMotion", base.highlightMotion)
    kv("d.highlightMotion.isGate", base.highlightMotion === MotionPolicy.enabled)
    kv("d.rowMotion", base.rowMotion)
    kv("d.isSelectable.isFn", typeof base.isSelectable)
    kv("d.isSelectable.default", base.isSelectable(3))
    kv("d.rowIdentity.isFn", typeof base.rowIdentity)
    kv("d.rowIdentity.default", base.rowIdentity(4))
    kv("d.measureGuard.default", base.measureGuard(2))
    kv("d.identityRevision", base.identityRevision)
    kv("d.maxKnownH", base.maxKnownH)
    kv("d.seatsInstant", base._seatsInstant)
    kv("d.sweepMs", base._sweepMs)
    kv("d.sweepMaxMs", base._sweepMaxMs)
    kv("d.highlightHandoff", base._highlightHandoff)
    kv("d.scrollVpx", base.scrollVpx)
    kv("d.trailSpace", base.trailSpace)
    kv("d.autoRevealIndex", base.autoRevealIndex)
    kv("d.autoRevealEnabled", base.autoRevealEnabled)
    kv("d.pursuitAnimated", base.pursuitAnimated)
    kv("d.spacing", base.spacing)
    kv("d.clip", base.clip)
    kv("d.boundsBehavior", base.boundsBehavior)
    kv("d.snapMode", base.snapMode)
    kv("d.interactive", base.interactive)
    kv("d.keyNavigationEnabled", base.keyNavigationEnabled)
    kv("d.wheelSteps", base.wheelSteps)
    kv("d.autoCache", base.autoCache)
    kv("d.highlightFollows", base.highlightFollowsCurrentItem)
    kv("d.highlightSet", base.highlight !== null)
    kv("d.cacheBuffer.small", base.cacheBuffer)
    kv("d.cacheBuffer.wall", wall.cacheBuffer)
    kv("d.listFullRows", Ui.listFullRows)
    kv("d.cacheThreshold", wall.count >= Ui.listFullRows)
    kv("d.fastMs", Ui.fastMs)
    kv("d.slowMs", Ui.slowMs)
    kv("d.rowMinH", Ui.rowMinH)
    kv("d.s", Ui.s)
    // centreCursor is documented as advisory: setting it must change nothing.
    smooth.centerCursor = false
    kv("d.centerCursor.advisory", smooth.centerCursor === false)
    smooth.centerCursor = true
    kv("d.centerCursor.restored", smooth.centerCursor)
  }

  // The duration-from-distance function on a short table, where scrollVel()
  // is still the scrollVpx floor.
  function arithShort() {
    kv("s.tableTotal", base.tableTotal())
    kv("s.contentHeight", base.contentHeight)
    kv("s.height", base.height)
    kv("s.tableMaxY", base.tableMaxY())
    kv("s.scrollVel", base.scrollVel())
    kv("s.scrollVel.isFloor", base.scrollVel() === base.scrollVpx)
    kv("s.step.0", base.stepMs(0))
    kv("s.step.0.4", base.stepMs(0.4))
    kv("s.step.1", base.stepMs(1))
    kv("s.step.100", base.stepMs(100))
    kv("s.step.719", base.stepMs(719))
    kv("s.step.720", base.stepMs(720))
    kv("s.step.2520", base.stepMs(2520))
    kv("s.step.2521", base.stepMs(2521))
    kv("s.step.1e6", base.stepMs(1e6))
    kv("s.step.negative", base.stepMs(-1))
    kv("s.step.nan", base.stepMs(NaN))
    kv("s.step.inf", base.stepMs(Infinity))
    kv("s.step.positive", base.stepMs(0) > 0 && base.stepMs(1e6) > 0)
    kv("s.step.leMax", base.stepMs(1e6) <= base._sweepMaxMs)
    kv("s.step.atMax", base.stepMs(1e6) === base._sweepMaxMs)
    // Monotone non-decreasing across the whole sampled range.
    const d = [0, 0.4, 1, 100, 719, 720, 2520, 2521, 1e6]
    let mono = true
    for (let i = 1; i < d.length; i++) {
      if (base.stepMs(d[i]) < base.stepMs(d[i - 1])) mono = false
    }
    kv("s.step.monotonic", mono)
    kv("s.step.floor", base.stepMs(1) === Ui.fastMs)
    // The same list with the velocity floor removed.
    kv("nv.scrollVel", noVpx.scrollVel())
    kv("nv.scrollVel.isTableTerm", noVpx.scrollVel() === noVpx.tableTotal() * 4)
    kv("nv.step.100", noVpx.stepMs(100))
    kv("nv.step.1000", noVpx.stepMs(1000))
    kv("nv.step.5000", noVpx.stepMs(5000))
    kv("nv.step.leMax", noVpx.stepMs(1e9) <= noVpx._sweepMaxMs)
  }

  // The same function on a long table, where the table term owns scrollVel
  // and the durations get real rather than pinned to the floor.
  function arithWall() {
    kv("w.count", wall.count)
    kv("w.contentHeight", wall.contentHeight)
    kv("w.tableTotal", wall.tableTotal())
    kv("w.tableMaxY", wall.tableMaxY())
    kv("w.scrollVel", wall.scrollVel())
    kv("w.scrollVel.isTableTerm", wall.scrollVel() === wall.tableTotal() * 4)
    kv("w.scrollVel.gtVpx", wall.scrollVel() > wall.scrollVpx)
    kv("w.step.0", wall.stepMs(0))
    kv("w.step.100", wall.stepMs(100))
    kv("w.step.1000", wall.stepMs(1000))
    kv("w.step.4000", wall.stepMs(4000))
    kv("w.step.5000", wall.stepMs(5000))
    kv("w.step.10000", wall.stepMs(10000))
    kv("w.step.20000", wall.stepMs(20000))
    kv("w.step.1e9", wall.stepMs(1e9))
    const d = [0, 1, 100, 1000, 4000, 5000, 10000, 20000, 1e9]
    let mono = true
    for (let i = 1; i < d.length; i++) {
      if (wall.stepMs(d[i]) < wall.stepMs(d[i - 1])) mono = false
    }
    kv("w.step.monotonic", mono)
    kv("w.step.aboveFloor", wall.stepMs(10000) > Ui.fastMs)
    kv("w.step.atMax", wall.stepMs(1e9) === wall._sweepMaxMs)
    kv("w.step.leMax", wall.stepMs(1e9) <= wall._sweepMaxMs)
    // A seat can never be longer than the content, so the reachable ceiling
    // is well under _sweepMaxMs: the cap is a guard, not the working value.
    kv("w.step.fullLength", wall.stepMs(wall.tableMaxY()))
    kv("w.step.fullLength.le250", wall.stepMs(wall.tableMaxY()) <= 250)
    kv("w.step.fullLength.geFloor", wall.stepMs(wall.tableMaxY()) >= Ui.fastMs)
  }

  // Every arithmetic path with no table at all. No division by a zero height
  // is allowed to escape here.
  function arithEmpty() {
    kv("e.count", empty.count)
    kv("e.contentHeight", empty.contentHeight)
    kv("e.tableTotal", empty.tableTotal())
    kv("e.tableMaxY", empty.tableMaxY())
    kv("e.scrollVel", empty.scrollVel())
    kv("e.scrollVel.isFloor", empty.scrollVel() === empty.scrollVpx)
    kv("e.step.0", empty.stepMs(0))
    kv("e.step.1", empty.stepMs(1))
    kv("e.step.1e6", empty.stepMs(1e6))
    kv("e.step.neg", empty.stepMs(-7))
    kv("e.step.isFinite", isFinite(empty.stepMs(1e6)) && isFinite(empty.scrollVel()))
    kv("e.clampY.inf", empty.clampY(Infinity))
    kv("e.clampY.nan", empty.clampY(NaN))
    kv("e.clampY.big", empty.clampY(99999))
    kv("e.rowHeightAt0", empty.rowHeightAt(0))
    kv("e.rowHeightAt0.isRowMinH", empty.rowHeightAt(0) === Ui.rowMinH)
    kv("e.fitHeight", empty.fitHeight(300, 0))
    kv("e.centerTarget", empty.centerTarget(0))
    kv("e.followTarget", empty.followTarget(0))
  }

  // Selection: the plain down/up walk on a wrapping list.
  function selDown() {
    kv("sd.start", base.currentIndex)
    kv("sd.down1", base.move(1))
    kv("sd.at1", base.currentIndex)
    kv("sd.down2", base.move(1))
    kv("sd.at2", base.currentIndex)
    kv("sd.up1", base.move(-1))
    kv("sd.at1b", base.currentIndex)
    kv("sd.zero", base.move(0))
    kv("sd.atZero", base.currentIndex)
    kv("sd.changed", base.move(1))
    kv("sd.at3", base.currentIndex)
    // move() is documented to return true when the index changed.
    kv("sd.returnsBool", typeof base.move(1) === "boolean")
  }

  // Selection: wrap:true cycles both ends.
  function selWrap() {
    // A full lap returns to where it started and reports it.
    base.settle(3, false)
    let hops = 0
    for (let i = 0; i < 8; i++) if (base.move(1)) hops++
    kv("w2.lapHops", hops)
    kv("w2.lapLanded", base.currentIndex)
  }

  // Selection: wrap:false clamps at either end and still skips holes.
  function selClamp() {
    clamp.settle(0, false)
    kv("c.atTop", clamp.currentIndex)
    kv("c.upAtTop", clamp.move(-1))
    kv("c.afterUpAtTop", clamp.currentIndex)
    kv("c.clampedUp", clamp.currentIndex === 0)
    kv("c.wrappedUp", clamp.currentIndex === 7)
    clamp.settle(7, false)
    kv("c.atEnd", clamp.currentIndex)
    kv("c.downAtEnd", clamp.move(1))
    kv("c.afterDownAtEnd", clamp.currentIndex)
    kv("c.clampedDown", clamp.currentIndex === 7)
    kv("c.wrappedDown", clamp.currentIndex === 0)
    // An unseated cursor: Down lands on row 0, Up on the last row.
    clamp.currentIndex = -1
    kv("c.unseatedIndex", clamp.currentIndex)
    kv("c.unseatedDown", clamp.move(1))
    kv("c.unseatedDownAt", clamp.currentIndex)
    clamp.currentIndex = -1
    kv("c.unseatedUp", clamp.move(-1))
    kv("c.unseatedUpAt", clamp.currentIndex)
    kv("c.unseatedUpExpected", 7)
    kv("c.wrapIsFalse", clamp.wrap === false)
    clamp.wrap = true
    clamp.settle(0, false)
    kv("w2.wrapIsTrue", clamp.wrap)
    kv("w2.atTop", clamp.currentIndex)
    kv("w2.up", clamp.move(-1))
    kv("w2.afterUp", clamp.currentIndex)
    clamp.settle(7, false)
    kv("w2.atEnd", clamp.currentIndex)
    kv("w2.down", clamp.move(1))
    kv("w2.afterDown", clamp.currentIndex)
    clamp.wrap = false
  }

  // Selection: isSelectable as a predicate, skipped in both directions.
  function selPredicate() {
    skipper.settle(1, false)
    kv("p.at1", skipper.currentIndex)
    kv("p.downSkips2", skipper.move(1))
    kv("p.afterDown", skipper.currentIndex)
    kv("p.upSkips2", skipper.move(-1))
    kv("p.afterUp", skipper.currentIndex)
    // A hole at the end of a downward walk wraps onto the first selectable.
    skipper.settle(1, false)
    for (let i = 0; i < 5; i++) skipper.move(1)
    kv("p.lapLanded", skipper.currentIndex)
    kv("p.neverOnHole", skipper.currentIndex !== 2)
    // settle() lands on the nearest selectable at or after the request.
    skipper.settle(2, false)
    kv("p.settleOnHole", skipper.currentIndex)
    skipper.settle(-3, false)
    kv("p.settleBelowRange", skipper.currentIndex)
    skipper.settle(99, false)
    kv("p.settleAboveRange", skipper.currentIndex)
    skipper.settle(0, false)
    kv("p.settleExact", skipper.currentIndex)
  }

  // Nothing selectable anywhere: every motion is a no-op and nothing throws.
  function selAllBad() {
    kv("n.index", nothingOk.currentIndex)
    kv("n.down", nothingOk.move(1))
    kv("n.up", nothingOk.move(-1))
    kv("n.afterDown", nothingOk.currentIndex)
    kv("n.jumpEndLast", nothingOk.jumpEnd(true))
    kv("n.jumpEndFirst", nothingOk.jumpEnd(false))
    kv("n.afterJump", nothingOk.currentIndex)
    nothingOk.settle(3, false)
    kv("n.afterSettle", nothingOk.currentIndex)
    kv("n.seatsInstant", nothingOk._seatsInstant)
  }

  // The last row is the hole, so jumpEnd(true) has to stop one short of it.
  function selTailHole() {
    tailHole.settle(0, false)
    kv("h.at0", tailHole.currentIndex)
    kv("h.jumpLast", tailHole.jumpEnd(true))
    kv("h.afterJumpLast", tailHole.currentIndex)
    kv("h.jumpLast.sane", tailHole.currentIndex === 4)
    kv("h.jumpFirst", tailHole.jumpEnd(false))
    kv("h.afterJumpFirst", tailHole.currentIndex)
    tailHole.settle(4, false)
    kv("h.downFrom4", tailHole.move(1))
    kv("h.afterDownFrom4", tailHole.currentIndex)
    kv("h.neverOnHole", tailHole.currentIndex !== 5)
  }

  // A one-element model: both step directions are documented no-ops.
  function selSolo() {
    kv("o.count", solo.count)
    kv("o.index", solo.currentIndex)
    kv("o.down", solo.move(1))
    kv("o.up", solo.move(-1))
    kv("o.after", solo.currentIndex)
    kv("o.stillOnRow0", solo.currentIndex === 0)
    kv("o.jumpLast", solo.jumpEnd(true))
    kv("o.jumpFirst", solo.jumpEnd(false))
    kv("o.settle9", solo.settle(9, false))
    kv("o.afterSettle", solo.currentIndex)
    kv("o.item", solo.currentItem === null ? "null" : "live")
  }

  // restoreAt: the exact seat protocol, including the clamp and the forward
  // scan past a non-selectable index.
  function selRestore() {
    smooth.settle(0, false)
    smooth.restoreAt(9, 300)
    kv("r.index", smooth.currentIndex)
    kv("r.y", smooth.contentY)
    kv("r.sweeping", smooth._sweeping)
    kv("r.seatsInstant", smooth._seatsInstant)
    kv("r.sweepMs", smooth._sweepMs)
    kv("r.exactY", smooth.contentY === 300)
    smooth._endSweep()
    kv("r.sweepingAfterEnd", smooth._sweeping)
    kv("r.seatsAfterEnd", smooth._seatsInstant)
    smooth.restoreAt(999, 300)
    kv("r.clampedHigh", smooth.currentIndex)
    smooth.restoreAt(-9, 0)
    kv("r.clampedLow", smooth.currentIndex)
    kv("r.lowY", smooth.contentY)
    skipper.settle(0, false)
    skipper.restoreAt(2, 0)
    kv("r.scanPastHole", skipper.currentIndex)
    // Seed an unseated cursor: no selectable row means restoreAt is a no-op.
    nothingOk.currentIndex = -1
    nothingOk.currentIndex = -1
    nothingOk.restoreAt(4, 0)
    kv("r.allBadIndex", nothingOk.currentIndex)
    kv("r.allBadLandsOnHole", nothingOk.currentIndex === 4)
    kv("r.allBadNotUndone", nothingOk.move(1))
  }

  // The empty model, through every public entry point. The contract is that
  // none of them throw and none of them leave state armed.
  function emptySweep() {
    kv("x.count", empty.count)
    kv("x.index", empty.currentIndex)
    kv("x.item", empty.currentItem === null ? "null" : "live")
    kv("x.moveDown", empty.move(1))
    kv("x.moveUp", empty.move(-1))
    kv("x.moveZero", empty.move(0))
    empty.settle(2, true)
    kv("x.settleIndex", empty.currentIndex)
    kv("x.settleUnarmsSeats", empty._seatsInstant === false)
    empty.reveal(1, true)
    kv("x.revealY", empty.contentY)
    empty.revealEnd(1)
    kv("x.revealEndIndex", empty.autoRevealIndex)
    kv("x.jumpLast", empty.jumpEnd(true))
    kv("x.jumpFirst", empty.jumpEnd(false))
    empty.restoreAt(1, 40)
    kv("x.restoreIndex", empty.currentIndex)
    kv("x.restoreSweeping", empty._sweeping)
    empty.pageBy(1)
    kv("x.pageY", empty.contentY)
    kv("x.seatTo", empty.seatTo(500, true))
    kv("x.trackCursor", (empty.trackCursor(0, true), empty.contentY))
    kv("x.followCursor", (empty.followCursor(0, true), empty.contentY))
    empty.learnLive()
    kv("x.knownH", JSON.stringify(empty._knownH))
    kv("x.identityError", empty.identityError)
    kv("x.rowTop", empty.rowTop(0))
    kv("x.reveal0", (empty.reveal(0, true), empty.contentY))
  }

  // Replacing the model, and shrinking it under a live cursor.
  function modelSwap() {
    base.settle(5, false)
    kv("ms.beforeIndex", base.currentIndex)
    kv("ms.beforeKnownH", Object.keys(base._knownH).length)
    base.model = root.replacement
    kv("ms.afterCount", base.count)
    kv("ms.afterIndex", base.currentIndex)
    // onModelChanged drops the height table wholesale: the old keys describe
    // rows that no longer exist.
    kv("ms.knownHCleared", JSON.stringify(base._knownH))
    kv("ms.sumHCleared", base._sumH)
    kv("ms.countHCleared", base._countH)
    kv("ms.avgHCleared", base._avgH)
    kv("ms.tableTotalAfter", base.tableTotal())
    kv("ms.rowHeightAfter", base.rowHeightAt(0))
    // Shrink under a cursor parked past the new end.
    base.settle(8, false)
    kv("ms.at8", base.currentIndex)
    base.model = root.rows6
    kv("ms.shrunkCount", base.count)
    kv("ms.shrunkIndex", base.currentIndex)
    kv("ms.inRange", base.currentIndex >= 0 && base.currentIndex < base.count)
    kv("ms.moveAfterShrink", base.move(1))
    kv("ms.indexAfterMove", base.currentIndex)
    kv("ms.inRangeAfterMove", base.currentIndex < base.count)
    kv("ms.jumpEndAfterShrink", (base.jumpEnd(true), base.currentIndex))
    kv("ms.shrunkTableTotal", base.tableTotal())
    kv("ms.shrunkClamp", base.clampY(Infinity))
    kv("ms.shrunkContentY", base.contentY)
    // And back to nothing at all.
    base.model = []
    kv("ms.emptyCount", base.count)
    kv("ms.emptyIndex", base.currentIndex)
    kv("ms.emptyMove", base.move(1))
    kv("ms.emptyTableTotal", base.tableTotal())
    kv("ms.emptyClamp", base.clampY(Infinity))
  }

  // A pinned bar origin. What it is FOR: a consumer seats a repair target
  // after a model swap, but the index adjustment the swap deals lands a
  // frame after that swap's window closes - the cursor goes to row 0 on
  // its own, and an unpinned bar follows it there and then travels the
  // whole list back to the row the repair named. So the origin is armed
  // explicitly, and what is asserted here is the invariant that makes it
  // hold: a cursor move must not re-take a pinned geometry, and no path
  // may leave the pin standing.
  function barPin() {
    pinned.settle(0, false)
    pinned.jumpEnd(true)
    // The hold describes where the bar sat on the SCREEN, so the origin
    // is the row's distance from the view's top and not its place in the
    // content. The two are the same number on a list that is not
    // scrolled, which is why the difference needs a list that is.
    const origin = pinned.currentItem.y - pinned.contentY
    kv("bp.index", pinned.currentIndex)
    kv("bp.pinArms", pinned.pinHighlight())
    kv("bp.pinned", pinned._hlPin)
    kv("bp.originY", pinned._hlY)
    kv("bp.originIsCursorRow", pinned._hlY === origin)
    // The swap's echo: an out-of-engine index write, which is what a
    // model reset does to the cursor once the choreography window closed.
    pinned.currentIndex = 0
    kv("bp.echoIndex", pinned.currentIndex)
    kv("bp.echoIsTopRow", pinned.currentIndex === 0)
    kv("bp.pinSurvivesEcho", pinned._hlPin)
    kv("bp.originSurvivesEcho", pinned._hlY === origin)
    // A pin already standing keeps the origin it was armed with, so a
    // second swap inside the same delete cannot re-take it from a cursor
    // that has already moved onto the row being eased away from.
    kv("bp.secondPinKeeps", (pinned.pinHighlight(), pinned._hlY === origin))
    // Unpinning hands the bar back to live cursor geometry - which is the
    // seat the release performs.
    pinned.unpinHighlight()
    kv("bp.unpinDrops", pinned._hlPin === false)
    // A gesture takes the bar back from a pinned origin: the user is
    // naming a row, and a bar still easing from another transition's
    // origin would leave the cursor somewhere it is not.
    pinned.pinHighlight()
    kv("bp.repinArms", pinned._hlPin)
    pinned.move(1)
    kv("bp.userSeatDropsPin", pinned._hlPin === false)
    // A landing does not: that is how the repair seat stays inside the
    // pin's window at all.
    pinned.pinHighlight()
    pinned.seat(2, "land")
    kv("bp.landKeepsPin", pinned._hlPin)
    pinned.unpinHighlight()
    // With no cursor row there is nothing to pin.
    pinned.seat(-1, "land")
    kv("bp.pinWithoutCursor", pinned.pinHighlight() === false)
    kv("bp.endsUnpinned", pinned._hlPin === false)
    // A hold dropped while the pin was up - clearing the cursor is the one
    // writer that drops it - leaves the pin inert, so a re-pin takes the
    // hold again rather than reporting a pin the bar is not reading.
    pinned.seat(3, "land")
    kv("bp.pinArmsAgain", pinned.pinHighlight() && pinned._hlPin)
    pinned.seat(-1, "land")
    kv("bp.holdDropped", pinned._hlHeld === false)
    pinned.seat(3, "land")
    kv("bp.repinTakesHold", pinned.pinHighlight())
    kv("bp.repinArms", pinned._hlPin)
    kv("bp.repinHeld", pinned._hlHeld)
    pinned.unpinHighlight()
  }

  // The selection bar is the ListView's highlight: a child of its
  // contentItem that is not a delegate. The delegates in this probe are
  // plain Items, and the bar is the only child that paints, so a colour
  // is what tells the two apart.
  function barWidth(list) {
    const kids = list.contentItem.children
    for (let i = 0; i < kids.length; i++) {
      const k = kids[i]
      if (k && k.color !== undefined && k.radius !== undefined) return k.width
    }
    return -1
  }
  // The bar's place ON THE SCREEN: its place in the content minus the
  // content's own offset. The two are different numbers whenever the
  // view is not at the top, and the difference is the whole point: a
  // hold that keeps the bar where the user left it has to survive the
  // content moving under it.
  function barScreenY(list) {
    const kids = list.contentItem.children
    for (let i = 0; i < kids.length; i++) {
      const k = kids[i]
      if (k && k.color !== undefined && k.radius !== undefined) return k.y - list.contentY
    }
    return -1
  }

  // The held bar keeps its place on the SCREEN when the content moves
  // under it. A hold that remembered the row's place in the CONTENT would
  // drag the bar along with the content, and the tail delete - which
  // shortens the content and rides the view down with it - would leave
  // the bar a whole row below the place the user left it, off the bottom
  // edge of the list, from where it flies back in.
  //
  // The fixture is parked at the bottom of its content first, and the
  // turns after it are the point: a hold describes a ROW, so the row has
  // to be a live delegate before there is any geometry to describe, and
  // the row the cursor is on is only instantiated once the view has
  // arrived at it.
  function settlePark() {
    // A LAND seat, not a jump: the land holds the bar still (the lease
    // zeroes the durations), so the bar is where it belongs the moment
    // the view arrives instead of gliding there over the next 120ms.
    settleList.settle(29, false)
  }
  function holdScreen() {
    kv("hs.parked", settleList.contentY > 0)
    kv("hs.live", settleList.currentItem !== null)
    const before = barScreenY(settleList)
    kv("hs.barAt", before)
    kv("hs.pinned", settleList.pinHighlight())
    kv("hs.held", settleList._hlHeld)
    // The content moves under the held bar: the view is scrolled up by
    // forty pixels, so every row's place in the content is unchanged and
    // every row's place on the screen has moved down by forty.
    settleList.seatTo(settleList.contentY - 40, false, "probe")
    kv("hs.scrolled", settleList.contentY)
    kv("hs.barAfter", barScreenY(settleList))
    kv("hs.barHeld", barScreenY(settleList) === before)
    settleList.unpinHighlight()
  }
  // The tail settle. A removal at the END of the content is the one
  // change the view cannot absorb for free: the content loses exactly
  // the space the view was resting on, so the bound comes down by a
  // whole row and the view is corrected in one step.
  //
  // The settle holds that space through the write - so the content's
  // extent does not change and the view does not move - and gives it
  // back over the motion budget, so the content shrinks by exactly that
  // much while the view rides it down.
  function settleArm() {
    root.settleBefore = settleList.contentHeight
    root.settleY = settleList.contentY
    root.settleBar = barScreenY(settleList)
    kv("sl.beforeHeight", settleList.contentHeight)
    kv("sl.beforeY", settleList.contentY)
    kv("sl.beforeBar", root.settleBar)
    // The bar is pinned to the place the user left it, as a consumer
    // doing a tail delete does.
    kv("sl.pinned", settleList.pinHighlight())
    // The write claims the space the removed row stood in.
    kv("sl.claimed", settleList.claimSettle(44))
    kv("sl.settling", settleList.settling)
    kv("sl.claimHeight", settleList.contentHeight)
    kv("sl.claimY", settleList.contentY)
    kv("sl.claimBar", barScreenY(settleList))
  }
  function settleRelease() {
    settleList.releaseSettle()
    kv("sl.releasing", settleList.settling)
  }
  // A turn of the settle, sampled on the way down: the content shrinks
  // by the space that was held and the view rides it down, so the two
  // stay on the same bound the whole way.
  function settleSample() {
    root.settleBarAfterScroll = barScreenY(settleList)
    kv("sl.sampleHeight", settleList.contentHeight)
    kv("sl.sampleY", settleList.contentY)
    kv("sl.sampleBar", root.settleBarAfterScroll)
  }
  function settleLanded() {
    kv("sl.endHeight", settleList.contentHeight)
    kv("sl.endY", settleList.contentY)
    kv("sl.endBar", barScreenY(settleList))
    kv("sl.heightBack", settleList.contentHeight === root.settleBefore)
    kv("sl.atBottom", settleList.contentY === settleList.clampY(Infinity))
    kv("sl.barHeld", barScreenY(settleList) === root.settleBar)
    kv("sl.settled", settleList.settling === false)
    kv("sl.pinReleased", settleList._hlPin === false)
  }

  // The cursor-keep arm, and the two things it must not do. A consumer
  // arms the keep before its model write, so the view can put the cursor
  // back on the row a model change took it from. A projection that keeps
  // the row under the cursor at the same index moves no index at all, so
  // the model never spends the arm - and it then outlives the change it
  // was armed for.
  //
  // What that costs, both of them read here: the bar stands on the width
  // the card had when the arm was taken, so a card that grew under the
  // pin (the menu's search projection reserves a chevron the page rows
  // did not) shows its selection a chevron short of the row it is on;
  // and the restore the arm triggers undoes the first cursor move the
  // user makes, because the arm answers an index change the user made
  // with a cursor the user did not ask for.
  function keepArm() {
    kept.currentIndex = 0
    kept.keepCursor()
    kv("ka.armed", kept._keepCursor)
    // The card grows under the arm.
    kept.width = 316
    // The projection: the row under the cursor keeps its uid and its
    // index, so the cursor does not move and the arm is not spent.
    root.keepRows = [
      { uid: "k0", label: "Keep zero" },
      { uid: "q1", label: "Other one" },
      { uid: "q2", label: "Other two" }
    ]
    kv("ka.indexAfterWrite", kept.currentIndex)
    kv("ka.armAfterWrite", kept._keepCursor)
    kv("ka.heldW", kept._hlW)
  }

  // The bar, a turn after the write, with the arm still standing and the
  // card wider than the width the arm froze.
  function keepArmBar() {
    kv("ka.liveW", kept.currentItem ? kept.currentItem.width : -1)
    kv("ka.barW", barWidth(kept))
  }

  // The first key step. It moves the cursor, and the arm does not take it
  // back.
  function keepArmMove() {
    kv("ka.moved", kept.move(1))
    kv("ka.indexAfterMove", kept.currentIndex)
    kv("ka.armAfterMove", kept._keepCursor)
    kv("ka.pinAfterMove", kept._hlPin)
    kv("ka.barWAfterMove", barWidth(kept))
  }

  // The scroll a swap drops. Replacing the model resets the view to the top
  // and the view puts the old offset back a frame later, so a list with room
  // to scroll paints its first entry for a frame before snapping down - the
  // lap that reads as the whole list jumping. What is asserted is the turn
  // itself: the offset is back before the call returns, because a frame is
  // all it takes to be seen.
  function swapScroll() {
    scrolled.settle(0, false)
    scrolled.jumpEnd(true)
    const y = scrolled.contentY
    kv("ss.parked", y > 0)
    let gen = 0
    // A replacement of the same length, seated by nobody: the offset the
    // user was reading at is the offset they keep.
    scrolled.swapRun(++gen, v => true, () => { scrolled.model = root.rows30b })
    kv("ss.sameLengthY", scrolled.contentY)
    kv("ss.sameLengthKept", scrolled.contentY === y)
    // Shorter content: the offset clamps onto the new bottom. Not short of
    // it, and never back to the top.
    scrolled.swapRun(++gen, v => true, () => { scrolled.model = root.rows29 })
    kv("ss.shorterY", scrolled.contentY)
    kv("ss.shorterIsBottom", scrolled.contentY === scrolled.clampY(Infinity))
    kv("ss.shorterNotTop", scrolled.contentY > 0)
    // A consumer that seats inside the window has said where the view
    // belongs, and the restore stands down for it: a membership change that
    // seats to the top still goes to the top.
    scrolled.swapRun(++gen, v => true, () => {
      scrolled.model = root.rows30b
      scrolled.settle(0, true)
    })
    kv("ss.consumerSeatWins", scrolled.contentY === 0)
  }

  // The same swap sampled over the turns AFTER the write, which is where the
  // motion lives: the model write is one turn, and the replacement content
  // re-measures over the turns after it, so the position the swap leaves in
  // its own turn is not the position the user ends up looking at. Read in the
  // write's turn alone, this case looks correct.
  function swapTailPark() {
    tail.settle(0, false)
    tail.jumpEnd(true)
    root.tailBefore = tail.contentY
    kv("st.before", tail.contentY)
    kv("st.beforeHeight", tail.contentHeight)
  }
  function swapTailWrite() {
    tail.swapRun(++root.tailGen, v => true, () => { tail.model = root.rows11 })
    kv("st.writeY", tail.contentY)
    kv("st.writeHeight", tail.contentHeight)
    kv("st.writeHold", tail._swapHold)
    kv("st.writeWatch", tail._swapWatching)
  }
  function swapTailSample() {
    root.tailTurn++
    kv("st.y" + root.tailTurn, tail.contentY)
    kv("st.h" + root.tailTurn, tail.contentHeight)
    if (root.tailTrace.length < 24) {
      root.tailTrace.push([tail.contentY, tail.contentHeight])
    }
  }
  function swapTailEnd() {
    const bottom = Math.max(0, tail.contentHeight - tail.height)
    const trace = root.tailTrace.concat([[tail.contentY, tail.contentHeight]])
    kv("st.after", tail.contentY)
    kv("st.afterHeight", tail.contentHeight)
    kv("st.bottom", bottom)
    kv("st.atBottom", tail.contentY === bottom)
    // Where the content stopped re-measuring, and whether the view was
    // already there. This is the assertion the fix rests on: the heal is
    // the last chance the swap has to put the view where the healed
    // content puts it, and reading it any later turn only proves a later
    // writer corrected it, which is the defect (a reveal gliding the view
    // the rest of the way back).
    let healedFrom = -1
    for (let i = 0; i < trace.length; i++) {
      if (trace[i][1] === trace[trace.length - 1][1]) { healedFrom = i; break }
    }
    kv("st.healedFrom", healedFrom)
    let held = healedFrom >= 0
    for (let i = Math.max(0, healedFrom); i < trace.length; i++) {
      if (trace[i][0] !== bottom) held = false
    }
    kv("st.settledAtHeal", held)
    let low = trace[0][0]
    let high = trace[0][0]
    for (let i = 0; i < trace.length; i++) {
      if (trace[i][0] < low) low = trace[i][0]
      if (trace[i][0] > high) high = trace[i][0]
    }
    kv("st.min", low)
    kv("st.max", high)
    kv("st.neverHigh", high <= root.tailBefore + 0.5)
    kv("st.holdRetired", tail._swapHold === false)
    kv("st.turnsAtEnd", tail._swapHoldTurns)
    root.tailTurnsAtEnd = tail._swapHoldTurns
    kv("st.trace", trace.map(function(v) {
      return Math.round(v[0]) + "/" + Math.round(v[1])
    }).join(","))
  }
  // A turn after the hold released. Its watch is a running timer, so a
  // release that left it running would keep this list waking once a frame
  // for the rest of the session, and the turn counter is what says whether
  // it did.
  function swapTailIdle() {
    kv("st.turnsLater", tail._swapHoldTurns)
    kv("st.watchStopped", tail._swapWatching === false)
    kv("st.stillAtBottom", tail.contentY === tail.clampY(Infinity))
  }
  // A hold is not an override. A seat that moves the view takes contentY
  // back, and the hold gives way in that same turn - not a tick later,
  // which would re-assert over the tween the seat started and stop it.
  function swapTailYield() {
    tail.swapRun(++root.tailGen, v => true, () => { tail.model = root.rows12 })
    kv("sy.armed", tail._swapHold)
    tail.seatTo(120, false, "consumer")
    kv("sy.released", tail._swapHold === false)
    kv("sy.watchStopped", tail._swapWatching === false)
    kv("sy.kept", tail.contentY)
    kv("sy.isTheConsumerSeat", tail.contentY === 120)
  }
  // The scroll model: page steps, the real-bounds clamp, and the
  // reconciliation that catches a contentY written outside seatTo.
  function scrollModel() {
    wall.settle(0, false)
    kv("sm.startY", wall.contentY)
    kv("sm.startIndex", wall.currentIndex)
    wall.pageBy(1)
    kv("sm.page1Y", wall.contentY)
    kv("sm.page1Expected", wall.height)
    wall.pageBy(1)
    kv("sm.page2Y", wall.contentY)
    kv("sm.page2Expected", 2 * wall.height)
    wall.pageBy(0.5)
    kv("sm.pageHalfY", wall.contentY)
    wall.pageBy(0)
    kv("sm.pageZeroY", wall.contentY)
    wall.pageBy(99)
    kv("sm.pageFarY", wall.contentY)
    kv("sm.pageFarAtBound", wall.contentY === wall.clampY(Infinity))
    wall.pageBy(-99)
    kv("sm.pageBackY", wall.contentY)
    kv("sm.pageBackAtTop", wall.contentY === 0)
    // A contentY written behind seatTo's back is reconciled, not trusted.
    wall.contentY = 1e9
    kv("sm.reconcileHigh", wall.contentY)
    wall.contentY = -500
    kv("sm.reconcileLow", wall.contentY)
    kv("sm.reconciledToBound", wall.contentY === 0)
    // trailSpace scrolls with the content: the bound is the content height
    // including the footer, not a fixed view-sized margin.
    kv("sm.trailTableTotal", trailing.tableTotal())
    kv("sm.trailContentHeight", trailing.contentHeight)
    kv("sm.trailMaxY", trailing.tableMaxY())
    kv("sm.trailRowTop0", trailing.rowTop(0))
    kv("sm.trailClamp", trailing.clampY(Infinity))
    // A matched twin with no trail space: the two differ by exactly the trail.
    twin.settle(0, false)
    kv("sm.twinTableTotal", twin.tableTotal())
    kv("sm.twinMaxY", twin.tableMaxY())
    kv("sm.trailDelta", trailing.tableMaxY() - twin.tableMaxY())
    kv("sm.trailAddsBound", trailing.tableMaxY() > twin.tableMaxY())
    kv("sm.trailRowTopSame", trailing.rowTop(0) === twin.rowTop(0))
  }

  // scrolloff: the view holds while the cursor is inside the margin band.
  function scrolloff() {
    wide.settle(0, false)
    kv("so.scrolloff", wide.scrolloff)
    kv("so.height", wide.height)
    kv("so.count", wide.count)
    kv("so.tableMaxY", wide.tableMaxY())
    kv("so.y0", wide.contentY)
    kv("so.centerTarget2", wide.centerTarget(2))
    kv("so.followTarget2", wide.followTarget(2))
    kv("so.heldAt2", wide.followTarget(2) === -1)
    kv("so.centerTarget1", wide.centerTarget(1))
    kv("so.followTarget1", wide.followTarget(1))
    // Moving through the margin band leaves the view where it is.
    wide.move(1)
    kv("so.at1", wide.currentIndex)
    wide.move(1)
    kv("so.at2", wide.currentIndex)
    kv("so.y2", wide.contentY)
    kv("so.heldView", wide.contentY === 0)
    // A held row takes no claim: _followIdx still names the last row that
    // actually seated the view, not the row the cursor is sitting on.
    kv("so.heldFollowIdx", wide._followIdx)
    kv("so.heldNoClaim", wide._followIdx !== wide.currentIndex)
    // Past the margin the view glides and the claim follows the cursor.
    for (let i = 0; i < 8; i++) wide.move(1)
    kv("so.at10", wide.currentIndex)
    kv("so.y10", wide.contentY)
    kv("so.glided", wide.contentY > 0)
    kv("so.glideFollowIdx", wide._followIdx)
    // scrolloff 0 is pure centre hold: the same target is never -1 mid-list.
    kv("so.zeroScrolloffFollow", wall.followTarget(10))
  }

  // The snapping land: the seat names a row, and the follow that places it
  // runs a turn later, so the view is read in the turn after the seat.
  //
  // The seat itself moves nothing: the row is placed by the follow, not by
  // the index write. A land that never follows leaves the row where the
  // view happened to be - off screen, in a list this shape - and the caller
  // that asked for the row to be placed gets nothing.
  function landSeat() {
    landing.settle(10, true)
    kv("ls.idx", landing.currentIndex)
    kv("ls.yAtSeat", landing.contentY)
    kv("ls.want", landing.centerTarget(10))
  }
  function landFollow() {
    kv("ls.yAfterFollow", landing.contentY)
    kv("ls.placed", landing.contentY > 0)
    kv("ls.centred", landing.contentY === landing.centerTarget(10))
    // The claim names the row that was followed.
    kv("ls.followIdx", landing._followIdx)
  }

  // A land inside a swap window does not follow. The window owns the view
  // in its own time, and a follow inside it would fight the hold that is
  // keeping the view where the model change left it.
  function landSwap() {
    landing.beginSwap()
    const y = landing.contentY
    landing.settle(20, true)
    kv("ls.swapIdx", landing.currentIndex)
    kv("ls.swapYAtSeat", landing.contentY)
    kv("ls.swapYBefore", y)
  }
  function landSwapFollow() {
    kv("ls.swapYAfter", landing.contentY)
    kv("ls.swapHeld", landing.contentY === landing._swapY)
    landing.endSwap()
  }

  // The placement height: a viewport that is still growing to a height the
  // consumer knows. The centre names the viewport the row is going to be
  // in, and the bound it is held to is the range that viewport will have.
  function landHint() {
    kv("ls.hintCentre", landing.centerTarget(10, 400))
    kv("ls.hintBound", landing.tableTotal() - 400)
    kv("ls.plainCentre", landing.centerTarget(10))
  }

  // The seat writer and its bookkeeping: every seat bumps the epoch, the
  // cursor claims are owned per tween, and the pure targets agree with each
  // other.
  function seats() {
    wall.settle(0, false)
    kv("st.epoch0", wall._seatEpoch)
    wall.seatTo(200, false, "probe")
    kv("st.epoch1", wall._seatEpoch)
    kv("st.seatY", wall.contentY)
    kv("st.epochAdvanced", wall._seatEpoch > 0)
    kv("st.clampedSeat", wall.seatTo(1e9, false) === wall.clampY(Infinity))
    kv("st.nanSeat", wall.seatTo(NaN, false))
    kv("st.infSeat", wall.seatTo(Infinity, false) === wall.clampY(Infinity))
    // A follow claims the running tween; any other seat takes the claim away.
    wall.followCursor(4, false)
    kv("st.followIdx", wall._followIdx)
    kv("st.pursuitIdxAfterFollow", wall._pursuitIdx)
    wall.pageBy(1)
    kv("st.followIdxAfterPage", wall._followIdx)
    // A seat that moves the view clears every claim but its own.
    wall._followIdx = 4
    wall._pursuitIdx = 4
    wall.seatTo(wall.contentY + 40, false)
    kv("st.claimAfterMovingSeat", wall._followIdx + "," + wall._pursuitIdx)
    // A seat whose target is where the view already is returns before the
    // ownership reset, so the claims it never owned survive it.
    wall._followIdx = 4
    wall._pursuitIdx = 4
    wall.seatTo(wall.contentY, false)
    kv("st.claimAfterNoopSeat", wall._followIdx + "," + wall._pursuitIdx)
    kv("st.noopSeatKeepsClaims", wall._followIdx === 4 && wall._pursuitIdx === 4)
    kv("st.noopSeatEpoch", wall._seatEpoch)
    // Classified seats: a land holds the stillness lease while step and
    // click pre-empt it at once. Clearing to -1 takes no lease.
    kv("st.seatFn", typeof wall.seat === "function")
    wall.seat(4, "land")
    kv("st.seatLandHolds", wall._seatsInstant)
    kv("st.seatLandLease", wall._stillLease !== 0)
    wall.seat(5, "step")
    kv("st.seatStepPreempts", wall._seatsInstant === false)
    kv("st.seatStepLease", wall._stillLease === 0)
    wall.seat(6, "click")
    kv("st.seatClickPreempts", wall._seatsInstant === false)
    kv("st.seatClickLease", wall._stillLease === 0)
    wall.seat(-1, "land")
    kv("st.seatClearNoLease", wall._stillLease === 0)
    // rowTop is the sum of measured heights plus spacing; row 0 is 0 by
    // construction and is never extrapolated.
    kv("st.rowTop0", wall.rowTop(0))
    kv("st.rowTop5", wall.rowTop(5))
    kv("st.rowTopExpected", 5 * (Ui.rowMinH + base.spacing))
    kv("st.rowTopBeyondCount", wall.rowTop(200))
    kv("st.rowTopBeyondExpected", 200 * (Ui.rowMinH + base.spacing))
    kv("st.rowTopNegative", wall.rowTop(-1))
    // centerTarget is the pure seat the follow would take, clamped to bounds.
    kv("st.centerTarget4", wall.centerTarget(4))
    kv("st.centerTargetFormula", wall.rowTop(4) + Ui.rowMinH / 2 - wall.height / 2)
    kv("st.centerTargetOutOfRange", wall.centerTarget(9999))
    kv("st.centerTargetNegative", wall.centerTarget(-1))
    kv("st.followTargetOutOfRange", wall.followTarget(9999))
  }

  // The hold spans wall time, not turns: arm a land seat here, read it
  // several pump turns later in seatHoldEarly (still inside the floor),
  // and read its release in final() (floor long elapsed).
  function seatHold() {
    holdback.seat(2, "land", true)
    kv("lh.leaseArmed", holdback._stillLease !== 0)
    kv("lh.durZero", holdback.highlightMoveDuration === 0)
  }
  function seatHoldEarly() {
    kv("lh.leaseHeld", holdback._stillLease !== 0)
    kv("lh.durStillZero", holdback.highlightMoveDuration === 0)
  }

  // reveal / revealEnd and the pursuit claim they set up.
  function pursuit() {
    smooth.settle(0, false)
    // Same-index step seat: retires the settle landing lease without
    // moving the cursor, so the reveal below is read on its own terms.
    // reveal() is scroll-only and takes no lease of its own.
    smooth.seat(0, "step")
    kv("pu.revealOutOfRange", (smooth.reveal(9999, true), smooth.contentY))
    kv("pu.revealNegative", (smooth.reveal(-3, true), smooth.autoRevealIndex))
    smooth.reveal(20, true)
    kv("pu.reveal20Y", smooth.contentY)
    kv("pu.reveal20Expected", smooth.rowTop(20) + Ui.rowMinH - smooth.height)
    kv("pu.revealArmsSeats", smooth._seatsInstant)
    kv("pu.revealKeepsCursor", smooth.currentIndex)
    // The claim, and the two motions it can be answered by. The claim is the
    // row's destination in content coordinates, and which motion runs is
    // decided by the CONSUMER's comparison - claim less the scroll offset,
    // against the height it is showing - so a list on its own cannot be told
    // which one it is in. Both are driven here explicitly.
    smooth.revealEnd(25)
    kv("pu.revealEndIndex", smooth.autoRevealIndex)
    kv("pu.revealEndClaim", smooth.revealNeedH)
    kv("pu.revealEndClaimFormula", smooth.rowTop(25) + Ui.rowMinH)
    // The claim is satisfied once the region covers it, and the reveal margin
    // is why it is satisfied with room to spare.
    kv("pu.claimOvershoot", smooth.height + smooth.contentY
      - smooth.revealNeedH)
    kv("pu.rowRevealed", smooth._rowRevealed())
    // A region GROWING toward a claim this list is also short of: the two
    // SHARE the deficit. The region's target is sized against where the
    // content will sit (the row's top, not the current offset), so it is
    // already asking for less than the whole shortfall and the list has to
    // take the rest - the pursuit is not silenced while the region travels,
    // or the entries above a tall dropdown stay put and the window grows by
    // the whole unfold. The shortfall is forced by shrinking the region,
    // which is the state a card is in mid-tween.
    const settledY = smooth.contentY
    smooth.height = 120
    smooth.contentY = settledY - 200
    // What a splitting consumer publishes: the claim less where the content
    // WILL sit, plus the margin. Restated here so the assertions below are
    // about the LIST's answer to a number a consumer would really send, not
    // about one the probe invented.
    const splitTarget = smooth.revealNeedH
      - Math.max(smooth.contentY, smooth.rowTop(smooth.autoRevealIndex)) + Ui.s
    kv("pu.splitTarget", splitTarget)
    kv("pu.splitIsSmaller", splitTarget
      < smooth.revealNeedH - smooth.contentY + Ui.s)
    // The whole shortfall, measured before anyone moves: this is what the
    // region used to ask for on its own.
    kv("pu.shortBy", smooth.revealNeedH - smooth.contentY - smooth.height)
    // En route - the region is mid-tween, so shorter than its own target, and
    // it cannot be carrying the claim. The list seats its share.
    smooth.height = 20
    smooth.growthH = splitTarget
    kv("pu.regionEnRoute", smooth.growthH > smooth.height + 0.5)
    smooth.pursue()
    kv("pu.seatedDuringGrowth", smooth.contentY)
    kv("pu.seatedUp", smooth.contentY > settledY - 200)
    // The region has LANDED on that target with the list short of the split's
    // own position, so the claim is not satisfied and the pursuit is not
    // finished. This is the case that used to strand it: the landed test
    // reads "the region owns the reveal" and is written the other way round,
    // so a region sized for a different scroll than the one in force silences
    // the list exactly when it has to move, and the row's bottom stays under
    // the region's edge. That is the clipped dropdown.
    smooth.height = splitTarget
    smooth.contentY = smooth.contentY - 50
    kv("pu.landedStillShort", smooth.revealNeedH - smooth.contentY + Ui.s
      - smooth.height)
    smooth.pursue()
    kv("pu.landedSeatedTo", smooth.contentY)
    kv("pu.landedMovedOn", smooth.contentY > 0)
    // A region that carries the claim ON ITS OWN, sized for the scroll in
    // force (no split in play): the pursuit owes nothing and must not move, or
    // the two chase each other at the crossover.
    const landedY = smooth.contentY
    smooth.growthH = smooth.revealNeedH - smooth.contentY + Ui.s
    smooth.pursue()
    kv("pu.claimSatisfiedBy", smooth.revealNeedH - smooth.contentY
      + Ui.s <= smooth.height)
    kv("pu.stillHeld", smooth.contentY)
    kv("pu.stillHeldIsLanded", smooth.contentY === landedY)
    // No region claiming it: the list owns the reveal and seats on its own.
    // This is every list that is not inside a growing card, and the reason
    // `growthH` exists rather than the list testing its own height.
    smooth.growthH = -1
    smooth.height = 120
    smooth.pursue()
    kv("pu.seatWhenUnclaimed", smooth.contentY > settledY - 200)
    smooth.growthH = -1
    smooth.height = 120
    // The scroll half, on a list that can scroll: the claim lands inside the
    // region, so the region is not short and the seat is the reveal.
    wall.revealEnd(199)
    kv("pu.wallClaim", wall.revealNeedH)
    kv("pu.wallNeedBelowViewH", wall.revealNeedH - wall.contentY <= wall.height)
    kv("pu.wallSeatedY", wall.contentY)
    kv("pu.wallSeatedExpected", wall.rowTop(199) + Ui.rowMinH + Ui.s - wall.height)
    smooth.height = 120
    smooth.autoRevealIndex = -1
    kv("pu.rowRevealedIdle", smooth._rowRevealed())
    kv("pu.pursuitDisabled", (smooth.autoRevealEnabled = false, smooth.pursue(), smooth.contentY))
    smooth.autoRevealEnabled = true
    kv("pu.pursuitAnimated", smooth.pursuitAnimated)
    // A seat that claims nothing must not be left armed.
    kv("pu.followIdxIdle", smooth._followIdx)
    kv("pu.pursuitIdxIdle", smooth._pursuitIdx)
  }

  // revealNeedH: who reveals a claim, and by how much.
  //
  // Two lists with the same slot-shaped delegate, differing only in whether
  // the claim is reachable by scrolling:
  //
  //   slotroom - three rows in a 200px viewport, so the content already fits
  //              and there is nothing to scroll. A slot that does not fit
  //              here can only be revealed by a taller region.
  //   slotwall - twelve rows in a 120px viewport, so scrolling covers a slot
  //              of the same size and no region is claimed at all.
  //
  // The window shape the region growth describes is the same one the
  // consumer applies (growForSlot: max(base, need)), so the probe applies it
  // to the viewport directly. That makes the handover observable: as the
  // region grows to the claim, the pursuit goes quiet and the scroll it had
  // started unwinds.
  function growClaim() {
    root.slotRowH = Ui.rowMinH
    root.slotRowSettled = Ui.rowMinH
    root.slotClaim = 9
    slotroom.autoRevealIndex = 9
    kv("gc.restingY", slotroom.contentY)
    kv("gc.restingRoom", slotroom.tableMaxY() - slotroom.contentY)
    // A resting last row sits exactly on the region's bottom edge, so the
    // reveal margin is all that is missing and nothing is claimed: this is
    // the closed state, before any slot opens.
    kv("gc.restingShortfall", slotroom.rowTop(9) + Ui.rowMinH + Ui.s - slotroom.height)
    kv("gc.restingNeed", slotroom.revealNeedH)
    // The slot opens. The card's region IS its content here, so the room to
    // scroll is only what the slot itself added, and the row's destination
    // (250px of dropdown plus the reveal margin) needs more than that: there
    // is nothing but a taller region that can reveal it.
    root.slotRowSettled = 250
    // The scroll room is the content below the row, and it is what decides
    // grow-vs-scroll - on the CONSUMER's side, because that is a comparison
    // against the height it owns. Here the room is read directly to show the
    // two shapes: a last row has none, a middle row has plenty.
    kv("gc.room", slotroom.tableMaxY() - slotroom.contentY)
    kv("gc.destinationShortfall", slotroom.rowTop(9) + 250 + Ui.s - slotroom.height)
    kv("gc.roomCannotCover", slotroom.tableMaxY() - slotroom.contentY
      < slotroom.rowTop(9) + 250 + Ui.s - slotroom.height)
    // The claim is published the moment the slot opens, from the row's
    // destination, before a pixel of the dropdown has moved.
    root.slotRowMs = 167
    kv("gc.needAtRest", slotroom.revealNeedH)
    kv("gc.needAtRestFormula", slotroom.rowTop(9) + 250 - slotroom.contentY)
    root.claimBeforeUnfold = slotroom.revealNeedH
    // Mid-unfold: the claim is the row's SETTLED bottom and does not move
    // while the slot animates. That constancy is the contract - it is what
    // lets a surface tween to the claim instead of chasing it, and it is what
    // gives the collapse a target at all.
    root.slotRowH = 150
    kv("gc.needMid", slotroom.revealNeedH)
    kv("gc.claimConstantWhileUnfolding",
      slotroom.revealNeedH === root.claimBeforeUnfold)
    kv("gc.claimAtRest", root.claimBeforeUnfold)
    kv("gc.aboveResting", slotroom.revealNeedH > root.slotroomRestH)
    // The consumer's rule, applied the way a surface applies it: the region
    // asks for the stretch of the deficit no scroll can reach - the claim less
    // the row's own top - and the list takes the rest. Both numbers come from
    // settled geometry, so the pair converges in one evaluation each and
    // neither is re-derived from the other's live value.
    const claimNow = slotroom.revealNeedH
    const claimedTop = slotroom.rowTop(9)
    const splitTarget = claimNow - Math.max(slotroom.contentY, claimedTop) + Ui.s
    kv("gc.splitTarget", splitTarget)
    kv("gc.splitTargetFormula", claimNow - claimedTop + Ui.s)
    kv("gc.wholeDeficit", claimNow - slotroom.contentY + Ui.s)
    kv("gc.splitIsSmaller", splitTarget < claimNow - slotroom.contentY + Ui.s)
    slotroom.growthH = splitTarget
    slotroom.height = splitTarget
    slotroom.pursue()
    kv("gc.listSeat", slotroom.contentY)
    kv("gc.pairSatisfies", slotroom.contentY + slotroom.height
      - claimNow - Ui.s <= 0.5)
    kv("gc.noGapUnderDropdown", Math.abs(slotroom.contentY + slotroom.height
      - (claimedTop + 250)) < 0.01)
    // The crossover, which is where the bounce lived. Growing the region to
    // the BARE claim - what the loop above did, and what a consumer sizing
    // itself to the claim without the reveal margin still does - puts the
    // row's settled bottom EXACTLY on the region's edge. The list reveals by
    // `bottom + Ui.s`, so it still reads that row as owed a margin-sized
    // seat, takes it, and that seat moves the scroll offset the consumer's
    // own arithmetic reads: the region retargeted, the card grew back, the
    // list seated again. Two writers, one number, no arbitration - the live
    // shell's answer to it was a card bouncing on some opens and not others.
    //
    // So the target CARRIES the margin, the region lands on that, and both
    // sides then read the same expression. The readings below are the guard:
    // the bare target owes the list a seat, the margin target owes it none,
    // and a region that has not arrived yet owes it the whole thing.
    slotroom.growthH = claimNow - claimedTop
    slotroom.height = slotroom.growthH
    slotroom.pursue()
    kv("gc.bareTargetOwes", claimNow + Ui.s - slotroom.contentY
      - slotroom.height)
    kv("gc.bareTargetSeats", slotroom.contentY)
    slotroom.growthH = splitTarget
    slotroom.height = splitTarget
    slotroom.pursue()
    kv("gc.seatAfterLanding", slotroom.contentY)
    kv("gc.nothingOwed", slotroom.contentY + slotroom.height
      - claimNow - Ui.s <= 0.5)
    // Short of its own target, the region is not carrying the claim and the
    // list is not finished: the pursuit seats the row's top into place. This
    // is every frame of the open, and the one where a silence would pin the
    // entries above the dropdown in place while the window grew alone.
    slotroom.contentY = 0
    slotroom.height = splitTarget - 90
    slotroom.pursue()
    kv("gc.shortRegionStillSeats", slotroom.contentY)
    kv("gc.shortRegionOwes", claimNow + Ui.s - slotroom.contentY
      - slotroom.height)
    // And with no region claiming it, the list owns the reveal outright and
    // seats on its own - the case for every list not inside a growing card.
    slotroom.growthH = -1
    slotroom.height = claimNow - 200
    slotroom.pursue()
    kv("gc.seatAlone", slotroom.contentY)
    kv("gc.seatAloneMoved", slotroom.contentY > 0)
    // Fully out, the claim is the whole destination and the region's edge is
    // the dropdown's bottom edge.
    root.slotRowH = 250
    kv("gc.needFull", slotroom.revealNeedH)
    kv("gc.needAboveResting", slotroom.revealNeedH > root.slotroomRestH)
    kv("gc.fullIsBottomEdge", Math.abs(slotroom.revealNeedH
      - (slotroom.rowTop(9) + 250)) < 0.01)
    // The close: the claim is released (the slot is shut, so there is nothing
    // to reveal) and the duration the row publishes is what a surface animates
    // the collapse over. -1 while the slot is still open or closing, because
    // that is the signal to use the slot's own time rather than a fixed one.
    kv("gc.slotMsOpen", slotroom.revealSlotMs)
    slotroom.autoRevealIndex = -1
    kv("gc.claimAfterClose", slotroom.revealNeedH)
    kv("gc.slotMsIdle", slotroom.revealSlotMs)
    // The same slot on a page with content below the claimed row. The
    // library still publishes the claim - it is the row's destination either
    // way, and it cannot know what height a consumer is showing - but here
    // the claim is SMALLER than the viewport, so a consumer's
    // max(base, need) holds the card still and the list scrolls the dropdown
    // into view instead. This is the shape the jump was reported in.
    root.slotClaim = 5
    slotwall.autoRevealIndex = 5
    root.slotRowH = 150
    root.slotRowSettled = 150
    kv("gc.wallRoom", slotwall.tableMaxY() - slotwall.contentY)
    kv("gc.wallShortfall", slotwall.rowTop(5) + 150 - slotwall.height)
    kv("gc.wallRoomCovers", slotwall.tableMaxY() - slotwall.contentY
      >= slotwall.rowTop(5) + 150 - slotwall.height)
    kv("gc.wallNeed", slotwall.revealNeedH)
    // The consumer's own comparison, and the whole decision in one number:
    // the claim less the scroll offset, against the height being shown. The
    // claim is the row's top plus its 150px slot, so at contentY 0 it lands
    // 150px into a 214px viewport - 64px INSIDE it. This row is therefore a
    // scroll and the card does not move: the shape a longer menu is in, and
    // the one that used to jump.
    kv("gc.wallNeedRelative", slotwall.revealNeedH - slotwall.contentY)
    kv("gc.wallShortBy", slotwall.revealNeedH - slotwall.contentY
      - slotwall.height)
    kv("gc.wallHeightUnchanged", slotwall.height)
    // No claim at all is -1, so a consumer reads one value for "no slot".
    slotwall.autoRevealIndex = -1
    kv("gc.noClaimNeed", slotwall.revealNeedH)
    root.slotRowH = Ui.rowMinH
    root.slotRowSettled = Ui.rowMinH
    root.slotClaim = -1
  }

  // The sweep state: the documented defaults, the ceiling, and the handoff
  // window a consumer opens by asking move() for a duration.
  function sweepState() {
    // reveal() seats no cursor and takes no landing lease, so this reads
    // the lease state the pursuit phase left behind: false with no land
    // seat holding the gate.
    kv("sw.revealUnarmedNextTurn", smooth._seatsInstant === false)
    wall.settle(0, false)
    kv("sw.defaultOff", wall._sweepMs)
    kv("sw.defaultMeansNoSweep", wall._sweepMs === -1)
    kv("sw.handoffDefault", wall._highlightHandoff)
    kv("sw.seatsDefault", wall._seatsInstant)
    kv("sw.seatsLeaseHeld", wall._stillLease !== 0)
    kv("sw.max", wall._sweepMaxMs)
    // move() with an explicit duration opens the handoff window and clamps it
    // into [Ui.fastMs, Ui.slowMs].
    wall.move(1, 5)
    kv("sw.handoffArmed", wall._highlightHandoff)
    kv("sw.sweepTiny", wall._sweepMs)
    kv("sw.sweepTinyAtFloor", wall._sweepMs === Ui.fastMs)
    wall.move(1, 100000)
    kv("sw.sweepHuge", wall._sweepMs)
    kv("sw.sweepHugeAtCeiling", wall._sweepMs === Ui.slowMs)
    kv("sw.sweepWithinMax", wall._sweepMs <= wall._sweepMaxMs)
    wall.move(1, 0)
    kv("sw.noHandoffAtZero", wall._highlightHandoff)
    kv("sw.releasedAfterSeat", wall._sweepMs)
    // A whole traversal, recording every value the engine itself writes. A
    // seat that never moves the view releases the pre-arm straight back to
    // -1, so an armed sample is what a real sweep looks like.
    sweeper.settle(0, false)
    sweepTrace = []
    for (let i = 0; i < 8; i++) {
      sweeper.move(1)
      sweepTrace.push(sweeper._sweepMs)
    }
    sweeper.jumpEnd(true)
    sweepTrace.push(sweeper._sweepMs)
    sweeper.jumpEnd(false)
    sweepTrace.push(sweeper._sweepMs)
    for (let i = 0; i < 4; i++) {
      sweeper.move(1)
      sweepTrace.push(sweeper._sweepMs)
    }
    let armed = 0
    let lo = 1e9
    let hi = -1e9
    for (let i = 0; i < sweepTrace.length; i++) {
      const v = sweepTrace[i]
      if (v >= 0) {
        armed++
        if (v < lo) lo = v
        if (v > hi) hi = v
      }
    }
    kv("sw.traversalSteps", sweepTrace.length)
    kv("sw.traversalArmed", armed)
    kv("sw.traversalHadSweeps", armed > 0)
    kv("sw.traversalMax", hi)
    kv("sw.traversalMin", lo)
    kv("sw.traversalLeMax", hi <= sweeper._sweepMaxMs)
    kv("sw.traversalGeFloor", armed === 0 || lo >= Ui.fastMs)
    kv("sw.traversalAboveFloor", hi > Ui.fastMs)
    // A short step is a floor, an end jump is the real distance: the same
    // stepMs on both.
    kv("sw.stepShort", sweeper.stepMs(36))
    kv("sw.stepEndJump", sweeper.stepMs(sweeper.clampY(Infinity)))
    // The sweep is what the highlight duration reads.
    wall._sweepMs = 250
    kv("sw.durationFromSweep", wall.highlightMoveDuration)
    wall._sweepMs = -1
    kv("sw.durationAfterClear", wall.highlightMoveDuration === (wall.highlightMotion ? Ui.fastMs : 0))
    wall._sweepMs = -1
  }

  // Motion gating: the two gates the component exposes, and what they do to
  // the durations the delegate behaviours read.
  function motionGate() {
    // The sweep armed by the previous step is still in flight one turn later,
    // because that seat was animated. It is read again in final(), long after
    // the tween has landed.
    kv("sw.sweepStillArmed", sweeper._sweepMs >= 0)
    kv("mg.motionEnabled", MotionPolicy.enabled)
    kv("mg.highlightMotion.isGate", base.highlightMotion === MotionPolicy.enabled)
    kv("mg.rowMotionDefault", base.rowMotion)
    kv("mg.durationWithGate", base.highlightMoveDuration)
    kv("mg.duration.matchesGate",
      base.highlightMoveDuration === (MotionPolicy.enabled ? Ui.fastMs : 0))
    base.highlightMotion = false
    kv("mg.gateOff", base.highlightMotion)
    kv("mg.durationGateOff", base.highlightMoveDuration)
    kv("mg.gateOffIsZero", base.highlightMoveDuration === 0)
    base.highlightMotion = true
    kv("mg.gateForcedOn", base.highlightMotion)
    kv("mg.durationForcedOn",
      base.highlightMoveDuration === (MotionPolicy.enabled ? Ui.fastMs : 0))
    base.highlightMotion = MotionPolicy.enabled
    kv("mg.gateRestored", base.highlightMotion === MotionPolicy.enabled)
    // selectionHighlight is the other half of the same gate.
    base.selectionHighlight = false
    kv("mg.highlightCleared", base.highlight === null)
    kv("mg.durationNoBar", base.highlightMoveDuration)
    base.selectionHighlight = true
    kv("mg.highlightRestored", base.highlight !== null)
    // An in-flight slot owns the bar's height, so the resize duration is
    // zeroed while the move duration is not: the two are separate gates.
    kv("mg.slotMs", slotty._currentSlotMotionMs)
    kv("mg.slotResizeDuration", slotty.highlightResizeDuration)
    kv("mg.slotMoveDuration", slotty.highlightMoveDuration)
    kv("mg.slotResizeIsZero", slotty.highlightResizeDuration === 0)
    kv("mg.plainSlotMs", plainHeight._currentSlotMotionMs)
    kv("mg.plainResizeDuration", plainHeight.highlightResizeDuration)
    kv("mg.slotsAreSeparate", slotty.highlightMoveDuration === plainHeight.highlightMoveDuration)
    // The row-set transitions are gated on rowMotion and nothing else.
    kv("mg.addEnabled", rowmotion.add.enabled)
    kv("mg.removeEnabled", rowmotion.remove.enabled)
    kv("mg.addDisplacedEnabled", rowmotion.addDisplaced.enabled)
    kv("mg.removeDisplacedEnabled", rowmotion.removeDisplaced.enabled)
    kv("mg.addEnabled.isRowMotion", rowmotion.add.enabled === rowmotion.rowMotion)
    rowmotion.rowMotion = true
    kv("mg.addEnabledAfter", rowmotion.add.enabled)
    kv("mg.removeEnabledAfter", rowmotion.remove.enabled)
    rowmotion.rowMotion = false
    kv("mg.addEnabledRestored", rowmotion.add.enabled)
  }

  // Launch the animated seat. Five steps in one turn: the last one owns the
  // tween, and its target is a real seat so the tween is in flight when the
  // next turn comes round.
  function animStart() {
    smooth.settle(0, false)
    kv("an.index0", smooth.currentIndex)
    kv("an.y0", smooth.contentY)
    kv("an.target", smooth.centerTarget(5))
    kv("an.stepMs", smooth.stepMs(smooth.centerTarget(5)))
    kv("an.durationFloor", smooth.stepMs(smooth.centerTarget(5)) >= Ui.fastMs)
    for (let i = 0; i < 5; i++) smooth.move(1)
    kv("an.index5", smooth.currentIndex)
    kv("an.sweepArmed", smooth._sweepMs)
    kv("an.mfBefore", root.mf)
    kv("an.smoothScroll", smooth.smoothScroll)
  }

  function animSample1() {
    trace.push(smooth.contentY)
    kv("an.y1", smooth.contentY)
    kv("an.y1.moved", smooth.contentY > 0)
    kv("an.y1.inFlight", smooth.contentY < smooth.centerTarget(5))
    kv("an.mf1", root.mf)
    kv("an.followIdx1", smooth._followIdx)
  }

  function animSample2() {
    trace.push(smooth.contentY)
    kv("an.y2", smooth.contentY)
    kv("an.y2.rising", smooth.contentY > trace[0])
    kv("an.y2.inFlight", smooth.contentY < smooth.centerTarget(5))
    kv("an.mf2", root.mf)
  }

  function animSample3() {
    trace.push(smooth.contentY)
    kv("an.y3", smooth.contentY)
    kv("an.y3.rising", smooth.contentY > trace[1])
    kv("an.y3.inFlight", smooth.contentY < smooth.centerTarget(5))
    kv("an.mf3", root.mf)
    kv("an.sweepDuring", smooth._sweepMs)
  }

  // The tween has had twenty turns; it must have landed and reported.
  function animLanded() {
    kv("an.yLanded", smooth.contentY)
    kv("an.yLanded.exact", smooth.contentY === smooth.centerTarget(5))
    kv("an.mfLanded", root.mf)
    kv("an.mfFiredOnce", root.mf === 1)
    kv("an.sweepAfter", smooth._sweepMs)
    kv("an.followIdxAfter", smooth._followIdx)
    kv("an.pursuitIdxAfter", smooth._pursuitIdx)
    kv("an.samplesDistinct", trace[0] !== trace[1] && trace[1] !== trace[2])
    kv("an.samplesMonotonic", trace[0] < trace[1] && trace[1] < trace[2])
    kv("an.sampleCount", trace.length)
    kv("an.epochAdvanced", smooth._seatEpoch > 0)
  }

  // A seat interrupted mid-flight by a restore must not claim a landing it
  // never made: stop() does not emit motionFinished.
  function animRest() {
    kv("ar.mfBefore", root.mf)
    smooth.move(1)
    smooth.restoreAt(3, 100)
    kv("ar.sweeping", smooth._sweeping)
    kv("ar.seatsInstant", smooth._seatsInstant)
    kv("ar.y", smooth.contentY)
    kv("ar.exactRestore", smooth.contentY === 100)
  }

  // Layout: what the view derives from the model, and the row height floor.
  // Read on slotty, not on base: the model-swap step emptied base on purpose.
  function layout() {
    kv("la.count", slotty.count)
    kv("la.contentHeight", slotty.contentHeight)
    kv("la.contentHeightFormula", 6 * 40 + 5 * slotty.spacing)
    kv("la.tableTotal", slotty.tableTotal())
    kv("la.tableMatchesLayout", slotty.tableTotal() === slotty.contentHeight)
    kv("la.contentHeightPositive", slotty.contentHeight > 0)
    kv("la.implicitWidth", slotty.implicitWidth)
    kv("la.implicitHeight", slotty.implicitHeight)
    kv("la.hasNoImplicitSize", slotty.implicitWidth === 0 && slotty.implicitHeight === 0)
    kv("la.contentWidth", slotty.contentWidth)
    kv("la.emptyContentHeight", empty.contentHeight)
    kv("la.emptyTableTotal", empty.tableTotal())
    kv("la.emptyIsZero", empty.contentHeight === 0 && empty.tableTotal() === 0)
    // The row height floor: an unmeasured row falls back to Ui.rowMinH, and a
    // measured row is the measurement, not the floor.
    kv("la.emptyRowHeight", empty.rowHeightAt(0))
    kv("la.emptyRowHeight.isFloor", empty.rowHeightAt(0) === Ui.rowMinH)
    kv("la.wallRowHeight", wall.rowHeightAt(1))
    kv("la.wallRowHeight.isFloor", wall.rowHeightAt(1) === Ui.rowMinH)
    kv("la.measuredRowHeight", slotty.rowHeightAt(0))
    kv("la.measuredRowHeight.isDelegate", slotty.rowHeightAt(0) === 40)
    kv("la.measuredAboveFloor", slotty.rowHeightAt(0) > Ui.rowMinH)
    kv("la.delegateHeight", slotty.itemAtIndex(0) === null
      ? "null" : slotty.itemAtIndex(0).height)
    kv("la.rowTop3", slotty.rowTop(3))
    kv("la.rowTop3Formula", 3 * (40 + slotty.spacing))
    // A list whose content fits never moves the view, whatever the cursor does.
    kv("la.fitsHeight", slotty.contentHeight <= slotty.height)
    kv("la.centerTarget0", slotty.centerTarget(0))
    kv("la.followTarget0", slotty.followTarget(0))
    kv("la.tableMaxY0", slotty.tableMaxY())
    for (let i = 0; i < 5; i++) slotty.move(1)
    kv("la.fittingListIndex", slotty.currentIndex)
    kv("la.shortListY", slotty.contentY)
    kv("la.shortListStillZero", slotty.contentY === 0)
    // fitHeight measures against real delegates and refuses when there are none.
    kv("la.fitHeight.100", slotty.fitHeight(100, 0))
    kv("la.fitHeight.100.expected", 2 * 40 + 1 * slotty.spacing)
    kv("la.fitHeight.1000.max3", slotty.fitHeight(1000, 3))
    kv("la.fitHeight.0", slotty.fitHeight(0, 0))
    kv("la.fitHeight.empty", empty.fitHeight(300, 0))
  }

  // The measured height table's own contract: what may be learned, how a key
  // is derived, the bound, and the collision report.
  function tableBounds() {
    kv("tb.rowKey0", base._rowKey(0))
    kv("tb.rowKey5", base._rowKey(5))
    kv("tb.rowKey.isString", typeof base._rowKey(3) === "string")
    // A non-callable or null-returning rowIdentity degrades to the index.
    wall.rowIdentity = 42
    kv("tb.rowKeyNonCallable", wall._rowKey(3))
    wall.rowIdentity = i => null
    kv("tb.rowKeyNull", wall._rowKey(3))
    wall.rowIdentity = i => undefined
    kv("tb.rowKeyUndef", wall._rowKey(3))
    wall.rowIdentity = i => i
    kv("tb.rowKeyRestored", wall._rowKey(7))
    // noteMeasured refuses everything outside a real row height, and refuses
    // every index the current model does not have. Each case is run on its own
    // cleared table so the reading is only about that one guard.
    plainHeight._clearHeightTable()
    kv("tb.clearedKnown", JSON.stringify(plainHeight._knownH))
    plainHeight.noteMeasured(-1, 44)
    kv("tb.refuse.negativeIndex", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(9999, 44)
    kv("tb.refuse.pastModel", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, 0)
    kv("tb.refuse.zeroHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, -5)
    kv("tb.refuse.negativeHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, 2500)
    kv("tb.refuse.overMaxHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, "44")
    kv("tb.refuse.stringHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, NaN)
    kv("tb.refuse.nanHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(0, Infinity)
    kv("tb.refuse.infiniteHeight", Object.keys(plainHeight._knownH).length)
    plainHeight._clearHeightTable()
    plainHeight.noteMeasured(1, undefined)
    kv("tb.refuse.undefinedHeight", Object.keys(plainHeight._knownH).length)
    kv("tb.refuse.sumUntouched", plainHeight._sumH)
    kv("tb.refuse.countUntouched", plainHeight._countH)
    plainHeight.noteMeasured(0, 1)
    kv("tb.minAccepted", plainHeight._knownH["0"])
    plainHeight.noteMeasured(0, 2000)
    kv("tb.maxAccepted", plainHeight._knownH["0"])
    plainHeight.noteMeasured(0, 40)
    kv("tb.lastAccepted", plainHeight._knownH["0"])
    kv("tb.sumH", plainHeight._sumH)
    kv("tb.countH", plainHeight._countH)
    kv("tb.avgH", plainHeight._avgH)
    plainHeight.noteMeasured(0, 40)
    kv("tb.idempotentSum", plainHeight._sumH)
    kv("tb.idempotentCount", plainHeight._countH)
    kv("tb.idempotentAvg", plainHeight._avgH)
    kv("tb.rowHeightAt0", plainHeight.rowHeightAt(0))
    // measureGuard refuses everything.
    guarded._clearHeightTable()
    guarded.settle(0, false)
    kv("tb.guardKnown", JSON.stringify(guarded._knownH))
    kv("tb.guardCount", guarded._countH)
    // The bound evicts, and the average follows what is kept.
    bounded._clearHeightTable()
    bounded.settle(0, false)
    kv("tb.boundedSize", Object.keys(bounded._knownH).length)
    kv("tb.boundedCount", bounded._countH)
    kv("tb.boundedLeMax", bounded._countH <= bounded.maxKnownH)
    kv("tb.boundedAvg", bounded._avgH)
    kv("tb.boundedStillLearns", bounded.rowHeightAt(0) >= Ui.rowMinH)
    // A contested identity is refused for learning and reported.
    kv("tb.dupeError", dupe.identityError)
    kv("tb.dupeError.isString", typeof dupe.identityError === "string")
    kv("tb.dupeKnown", JSON.stringify(dupe._knownH))
    kv("tb.dupeFingerprint", dupe._idFingerprint)
    dupe.rowIdentity = i => i
    dupe.identityRevision = 1
    kv("tb.dupeErrorCleared", dupe.identityError)
    kv("tb.dupeFingerprintAfter", dupe._idFingerprint)
    dupe.settle(0, false)
    kv("tb.dupeLearns", Object.keys(dupe._knownH).length)
    // restingContentHeight claiming the content fits holds the seat.
    resting.settle(0, false)
    for (let i = 0; i < 6; i++) resting.move(1)
    kv("tb.restingIndex", resting.currentIndex)
    kv("tb.restingFollow", resting.followTarget(6))
    kv("tb.restingCenter", resting.centerTarget(6))
    resting.restingContentHeight = resting.height
    kv("tb.restingHeld", resting.followTarget(6) === -1)
    kv("tb.restingUnheld", resting.followTarget(6) === resting.centerTarget(6))
    kv("tb.restingTargetExists", resting.centerTarget(6) > 0)
    resting.restingContentHeight = 0
    kv("tb.restingResumed", resting.followTarget(6) === resting.centerTarget(6))
  }

  // Two lists in one scene must not share anything. Every private field is
  // written on one and read on the other to prove it.
  function isolation() {
    kv("is.baseIndex", base.currentIndex)
    kv("is.siblingIndex", sibling.currentIndex)
    kv("is.indicesDiffer", base.currentIndex !== sibling.currentIndex)
    base._sweepMs = 300
    base._seatsInstant = true
    base._highlightHandoff = true
    base._knownH = { "poison": 999 }
    base._sumH = 999
    base._countH = 1
    base._avgH = 999
    base._idOwner = { "poison": -1 }
    base._touchH = { "poison": 1 }
    base._idFingerprint = "poison"
    base._followIdx = 3
    base._pursuitIdx = 4
    kv("is.siblingSweep", sibling._sweepMs)
    kv("is.siblingSeats", sibling._seatsInstant)
    kv("is.siblingHandoff", sibling._highlightHandoff)
    kv("is.siblingKnown", JSON.stringify(sibling._knownH))
    kv("is.siblingSum", sibling._sumH)
    kv("is.siblingCount", sibling._countH)
    kv("is.siblingAvg", sibling._avgH)
    kv("is.siblingOwner", JSON.stringify(sibling._idOwner))
    kv("is.siblingTouch", JSON.stringify(sibling._touchH))
    kv("is.siblingFingerprint", sibling._idFingerprint)
    kv("is.siblingFollow", sibling._followIdx)
    kv("is.siblingPursuit", sibling._pursuitIdx)
    kv("is.siblingDuration", sibling.highlightMoveDuration)
    kv("is.ownDuration", base.highlightMoveDuration)
    kv("is.noLeak", sibling._sweepMs === -1 && sibling._seatsInstant === false
      && sibling._highlightHandoff === false
      && sibling._knownH["poison"] === undefined
      && sibling._sumH !== 999 && sibling._countH !== 1 && sibling._avgH !== 999
      && sibling._idOwner["poison"] === undefined
      && sibling._touchH["poison"] === undefined
      && sibling._idFingerprint !== "poison"
      && sibling._followIdx !== 3 && sibling._pursuitIdx !== 4
      && sibling.highlightMoveDuration !== 0)
    // A tableTotal on the sibling is still its own arithmetic.
    kv("is.siblingTableTotal", sibling.tableTotal())
    kv("is.siblingScrollVel", sibling.scrollVel())
    base._clearHeightTable()
    kv("is.baseCleared", JSON.stringify(base._knownH))
    kv("is.siblingSurvived", Object.keys(sibling._knownH).length > 0)
  }

  // The model the caller handed in must come back exactly as it went in.
  // A source read cannot confirm this: the height table, the delegate model
  // and the seat writer all walk the same array.
  function nonMutation() {
    kv("nm.rows8", JSON.stringify(root.rows8) === JSON.stringify(mk(8)))
    kv("nm.rows6", JSON.stringify(root.rows6) === JSON.stringify(mk(6)))
    kv("nm.rows30", JSON.stringify(root.rows30) === JSON.stringify(mk(30)))
    kv("nm.replacement", JSON.stringify(root.replacement) === JSON.stringify(mk(9)))
    kv("nm.rows8.length", root.rows8.length)
    kv("nm.rows8.first", root.rows8[0])
    kv("nm.rows8.last", root.rows8[7])
    kv("nm.isArray", Array.isArray(root.rows30))
    kv("nm.noExtraKeys", Object.keys(root.rows30).length === 30)
  }

  // The restored tables still behave, and the wide list's animated seat is
  // reported too - a stop must not invent a landing.
  function final() {
    kv("fin.wallIndex", wall.currentIndex)
    kv("fin.wallIndexInRange", wall.currentIndex >= 0 && wall.currentIndex < wall.count)
    kv("fin.wallKnown", Object.keys(wall._knownH).length)
    kv("fin.wallAvg", wall._avgH)
    kv("fin.wallTableTotalPositive", wall.tableTotal() > 0)
    kv("fin.emptyCount", empty.count)
    kv("fin.soloCount", solo.count)
    kv("fin.mfTotal", root.mf)
    // Long after that animated traversal landed, nothing is still armed.
    kv("fin.sweeperSweep", sweeper._sweepMs)
    kv("fin.sweeperFollow", sweeper._followIdx)
    kv("fin.sweeperPursuit", sweeper._pursuitIdx)
    // The hold-span seat from seatHold: wall floor elapsed an age ago,
    // so the lease has observed-released and durations are re-armed.
    kv("fin.holdReleased", holdback._stillLease === 0)
    kv("fin.holdDurRearmed", holdback.highlightMoveDuration !== 0)
    kv("fin.probeThrew", root.threw)
  }

  function finish() {
    kv("probe.threw", root.threw)
    console.log("##DONE##")
  }
}

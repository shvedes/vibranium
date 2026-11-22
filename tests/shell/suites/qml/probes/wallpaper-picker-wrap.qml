// Probe: wallpaper-picker wrap navigation is a journey, not a teleport.
//
// LIMITATION: WallpaperPickerPanel is reached through OverlayWindow ->
// LayerSurface and cannot be constructed under QT_QPA_PLATFORM=offscreen (the
// same limit picker-sized-fade.qml records). The panel is therefore NOT
// constructed here. The suite hands the real file in through the environment;
// this probe checks that file's structure and drives a turn-based model of the
// deck's position across a wrap, sampling consecutive turns rather than only
// the end state.
//
// Contract under test:
//   * one real source, `deckPos`, owns tile geometry; tile geometry is a pure
//     function of it and the cell has no second geometry Behaviour chasing it.
//   * a step off either end keeps `selIndex` committed but animates `deckPos`
//     across the intervening entries, so the deck travels through the list.
//   * the window diff is still keyed by FILE and the labelled latches of the
//     panel (one root fade, _sized, _leaveProgress) are untouched.

import QtQuick
import Quickshell

Item {
  id: root

  width: 1
  height: 1

  readonly property string src: Quickshell.env("WALLPAPER_PICKER_PANEL_SRC") || ""

  property int turn: 0
  property bool done: false

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  function countOf(s, needle) {
    let n = 0
    let at = 0
    while (true) {
      const found = s.indexOf(needle, at)
      if (found < 0) return n
      n++
      at = found + needle.length
    }
  }

  // ---- source facts --------------------------------------------------------

  readonly property bool srcDeckPos: root.src.indexOf("property real deckPos: 0") >= 0
    && root.src.indexOf("readonly property real deckRel:") >= 0
    && root.src.indexOf("cell.abs - panel.deckPos") >= 0
    && root.src.indexOf("x: panel.tileX(cell.deckRel)") >= 0
  readonly property int cellGeomBehaviours: root.countOf(root.src, "Behavior on x {")
    + root.countOf(root.src, "Behavior on y {")
    + root.countOf(root.src, "Behavior on width {")
    + root.countOf(root.src, "Behavior on height {")
  readonly property bool srcOneClock: root.srcDeckPos
    && root.cellGeomBehaviours === 0
    && root.countOf(root.src, "Behavior on deckPos {") === 1
    && root.src.indexOf("duration: panel._deckTravelMs") >= 0

  // The wrap must arm a longer, length-derived travel; a plain one-tick
  // integer assignment is the regression this probe is here to catch.
  readonly property bool srcWrapJourney: root.src.indexOf("_deckTravelMs") >= 0
    && root.src.indexOf("Ui.slowMs") >= 0
    && root.src.indexOf("Math.min(") >= 0
    && root.src.indexOf("panel.wrap") < 0 // no imperative re-seat of the panel

  readonly property bool srcFileKeyedDiff: root.src.indexOf("wanted[String(row.file)] === true") >= 0
    && root.src.indexOf("deck.insert(i, want[i])") >= 0
    && root.src.indexOf("deck.setProperty(i, \"abs\"") >= 0
  readonly property bool srcInvariantsKept: root.src.indexOf("_leaveProgress") >= 0
    && root.src.indexOf("readonly property bool _sized") >= 0
    && root.src.indexOf("opacity: panel._fade ? 1 : 0") >= 0
    && root.src.indexOf("function _syncWindow()") >= 0
    && root.src.indexOf("windowRadius") >= 0

  // The window is re-diffed on an integer centre crossing, never on every
  // frame of the deckPos tween: rel is derived in the delegate instead.
  readonly property bool srcNoPerFrameDiff: root.src.indexOf(
    "if (centre !== panel._windowCenter) panel._syncWindow()") >= 0

  readonly property bool gateDeckPos: root.srcDeckPos
  readonly property bool gateOneClock: root.srcOneClock
  readonly property bool gateNoPerFrameDiff: root.srcNoPerFrameDiff
  readonly property bool gateWrapJourney: root.srcWrapJourney
  readonly property bool gateFileKeyed: root.srcFileKeyedDiff
  readonly property bool gateInvariants: root.srcInvariantsKept

  // ---- turn-based model of one wrap ----------------------------------------

  readonly property int n: 20
  readonly property int radius: 6
  readonly property int tracked: 10

  property bool travelling: false
  property real deckPos: 19
  property int committed: 19
  property real startPos: 19
  property real endPos: 0
  property real elapsed: 0
  property real journeyMs: 0

  property int distinctCenters: 0
  property real maxRelStep: 0
  property real prevRel: -1
  property int prevCenter: 19
  property bool oneFrameSwitch: false
  property int backwardSteps: 0
  property bool legacyOneFrame: false
  property int legacyCenter: 19

  function centerOf(p) {
    return Math.max(0, Math.min(root.n - 1, Math.round(p)))
  }

  function sample(p, isFirst) {
    const center = root.centerOf(p)
    if (isFirst || center !== root.prevCenter) root.distinctCenters++
    const rel = root.tracked - p
    if (!isFirst) {
      const step = Math.abs(rel - root.prevRel)
      if (step > root.maxRelStep) root.maxRelStep = step
      if (root.prevCenter === 19 && center === 0) root.oneFrameSwitch = true
      if (center < root.prevCenter) root.backwardSteps++
    }
    root.prevRel = rel
    root.prevCenter = center
  }

  function tick() {
    root.turn++
    const t = root.turn

    if (t === 1) {
      // Rest at the last entry: the window and every rel are at the tail.
      root.sample(root.deckPos, true)
    }

    if (t === 2) {
      // "next" at the last entry commits index 0 but must travel there.
      const span = root.n - 1
      root.committed = 0
      if (root.gateDeckPos && root.gateOneClock && root.gateWrapJourney) {
        root.travelling = true
        root.startPos = 19
        root.endPos = 0
        // Mirrors the source: min(1600, Ui.slowMs + span * 20), Ui.slowMs=260.
        root.journeyMs = Math.min(1600, 260 + span * 20)
        root.elapsed = 0
      } else {
        // The current/tree regression: integer index jumps in one frame.
        root.deckPos = 0
      }
      // The legacy panel's observable window centre for the control assert.
      root.legacyCenter = 0
      root.legacyOneFrame = true
    }

    if (root.travelling) {
      root.elapsed += 16
      const u = Math.max(0, Math.min(1, root.elapsed / root.journeyMs))
      const ease = 1 - Math.pow(1 - u, 3)
      root.deckPos = root.startPos + (root.endPos - root.startPos) * ease
      if (u >= 1) {
        root.deckPos = root.endPos
        root.travelling = false
      }
    }

    if (t > 1) root.sample(root.deckPos, false)

    if (t >= 48) {
      root.kv("gate.deckPos", root.gateDeckPos)
      root.kv("gate.oneClock", root.gateOneClock)
      root.kv("gate.noPerFrameDiff", root.gateNoPerFrameDiff)
      root.kv("gate.wrapJourney", root.gateWrapJourney)
      root.kv("gate.fileKeyed", root.gateFileKeyed)
      root.kv("gate.invariants", root.gateInvariants)
      root.kv("frame.distinctCenters", root.distinctCenters)
      root.kv("frame.maxRelStep", root.maxRelStep.toFixed(3))
      root.kv("frame.oneFrameSwitch", root.oneFrameSwitch)
      root.kv("frame.backwardSteps", root.backwardSteps)
      root.kv("frame.legacyOneFrame", root.legacyOneFrame)
      root.kv("frame.landsAtFirst", root.deckPos === 0 && root.committed === 0)
      root.kv("frame.cellGeomBehaviours", root.cellGeomBehaviours)
      console.log("##DONE##")
      root.done = true
    }
  }

  Timer {
    interval: 16
    repeat: true
    running: !root.done
    onTriggered: root.tick()
  }
}

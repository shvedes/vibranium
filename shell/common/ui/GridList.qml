pragma ComponentBehavior: Bound
import QtQuick
import qs.common
import "NavKeys.js" as NavKeys
import "../math/Range.js" as Range

// GridList twin of List (common/ui/List.qml) for layout:"grid" pages.
// List covers vertical ListView only; grid pages had nowhere to go, so
// cursor motion lived inline in MenuPanel. This is the first lib home
// for that motion: cell and row steps with selectable skip, page steps
// and end jumps, end-to-end wrap sweep and settle, and the reveal
// transitions a keyed row-set change runs. Consumers bind isSelectable,
// cols, firstSelectable, lastSelectable and syncAnimated; the view owns
// the sweep state.
//
// Settle and sweep mirror the List contract: snap seats instantly with
// zeroed motion, a plain step cancels any in-flight sweep. Every programmatic
// seat - keyboard step, page, settle, reveal, jump and the wrap release -
// goes through seatTo, the one funnel for the view position.
//
// Keep-bespoke, not Grid adopters: TrayMenu pointer-only Repeater,
// WeatherIsland suggestion Repeater. Neither is a grid page.
GridView {
  id: root

  // Cells are NOT recycled -- see List.qml. Delegates with imperative
  // state (menu/Entry, grid cells) must not be reused across rows.
  reuseItems: false

  // Predicate deciding which indices motion may land on; defaults to
  // accepting everything. MenuPanel binds its isSelectableIndex.
  property var isSelectable: index => true
  // Columns per row; MenuPanel binds its live gridCols.
  property int cols: 1
  // End targets for wrap repair; MenuPanel binds its first and last
  // selectable index helpers.
  property var firstSelectable: () => -1
  property var lastSelectable: () => -1

  // Emitted by activate() when the current cell has no activate() of its own
  // (the List half of the same contract, same reason: neither view type
  // declares an activated signal).
  signal activated(int index)

  // Whether a row-set change glides. The consumer owns the decision (its
  // sync plan); a cell appearing or disappearing is the same event a
  // ListView row makes, so the two renderers answer it identically
  // instead of one of them popping. Defaults off, so a consumer that has
  // no row-sync policy of its own gets no cell motion.
  property bool syncAnimated: false

  // Reveal motion, the same four transition blocks the menu's list runs,
  // so a conditional cell and a conditional row answer one policy. A new
  // cell fades in, a departing one fades out while it slides up, and
  // every cell the change displaces glides into its new slot. Suppressed
  // entirely for a wholesale swap, where the view is rebuilt with nothing
  // left to displace.
  //
  // Nothing here can move the card: a transition animates a cell's y and
  // opacity, and a grid page's height is the model's row count times a
  // fixed cell side, never delegate geometry - which is why the weave
  // (headers and spacers as model slots) composes the same way whether
  // the cells animate or not.
  add: Transition {
    enabled: MotionPolicy.enabled && root.syncAnimated
    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Ui.fastMs }
    Glide {
      property: "y"
      from: ViewTransition.item
        ? ViewTransition.item.y - ViewTransition.item.height : 0
    }
  }
  addDisplaced: Transition {
    enabled: MotionPolicy.enabled && root.syncAnimated
    Glide { property: "y" }
  }
  remove: Transition {
    enabled: MotionPolicy.enabled && root.syncAnimated
    NumberAnimation { property: "opacity"; to: 0; duration: Ui.fastMs }
    Glide {
      property: "y"
      to: ViewTransition.item
        ? ViewTransition.item.y - ViewTransition.item.height : 0
    }
  }
  removeDisplaced: Transition {
    enabled: MotionPolicy.enabled && root.syncAnimated
    Glide { property: "y" }
  }

  // Wrap-sweep state. The wrap cursor lands on the opposite end while
  // the viewport teleports; the sweep waits for that seat's contentY edge
  // and eases end to end from the live offset. Targets are the ends, never
  // a cell lookup: headers and spacers make per-item math unreliable.
  property bool sweeping: false
  property real sweepY0: 0
  property real sweepTo: 0
  // Generation for the wrap's edge release. A newer seat retires the pending
  // release, so a late contentY edge cannot start a stale sweep.
  property int _sweepGen: 0
  // One increment per programmatic seat, so a consumer can check that every
  // entry point takes the same funnel. Mirrors List._seatWrites.
  property int _seatWrites: 0

  NumberAnimation {
    id: sweep

    target: root
    property: "contentY"
    to: root.sweepTo
    // The wrap tween's travel is derived from its own live endpoints, not
    // handed in as a copied scalar. List's highlight binds to its content
    // tween the same way: one clock per engine, no duration passed between
    // components. A restart re-reads this binding from the current sweep.
    duration: Math.min(650,
      Math.round(Ui.fastMs
        + (Math.abs(root.sweepTo - root.sweepY0) / Math.max(1, root.height)) * 140))
    easing.type: Easing.OutCubic
  }

  // A plain step, settle or drag supersedes any in-flight wrap sweep.
  // Bumping the generation retires the pending edge release with it: a newer
  // intent must not start a stale sweep when contentY next changes.
  function cancelSweep() {
    root.sweeping = false
    root._sweepGen++
    sweep.stop()
  }

  // The single funnel for the view position. Every seat cancels any in-flight
  // wrap, clamps the target to the live scroll range, then applies it, so no
  // call site owns a cancellation of its own. `snap === true` (or a cell
  // index) seats that cell with positionViewAtIndex, which is cell-accurate
  // across headers and spacers; "sweep" starts the wrap tween from the view's
  // LIVE offset; otherwise `y` is clamped and assigned outright.
  function seatTo(y, snap) {
    root.cancelSweep()
    root._seatWrites++
    const maxY = Math.max(0, root.contentHeight - root.height)
    const target = isFinite(y) ? Range.clamp(y, 0, maxY) : 0
    if (snap === "sweep") {
      // No rewind to a captured value. The sweep's from is the live contentY
      // at the seat edge, so a step that landed after the gesture is kept.
      sweep.to = target
      sweep.restart()
      return target
    }
    if (snap === true || (typeof snap === "number" && snap >= 0)) {
      root.positionViewAtIndex(y, GridView.Contain)
      return root.contentY
    }
    root.contentY = target
    return target
  }

  function sweepToEnd(toEnd) {
    if (!MotionPolicy.enabled || root.count === 0) return
    const maxY = Math.max(0, root.contentHeight - root.height)
    const target = toEnd ? maxY : 0
    const y0 = root.contentY
    if (Math.abs(target - y0) < root.height) return
    root.cancelSweep()
    // sweepY0 feeds the tween's live duration; there is no rewind write. The
    // seat's contentY edge releases the sweep from the offset it lands on,
    // guarded by this generation so an older edge cannot fire it.
    root.sweepY0 = y0
    root.sweepTo = target
    root.sweeping = true
    // The first contentY write is the edge that releases this pending wrap;
    // without a running tween there is no first write and the sweep would
    // stay latched forever.
    sweep.restart()
  }

  // The wrap gesture seats the cursor at the far end; the view's contentY
  // edge is the signal that the seat actually landed. That is the release -
  // not a turn budget - so no deferred rewind can undo a seat that arrived
  // after the gesture. The sweep animation's own writes are excluded because
  // `sweeping` is cleared before the tween restarts.
  onContentYChanged: {
    if (!root.sweeping) return
    root._releaseSweep(root._sweepGen)
  }

  function _releaseSweep(gen) {
    if (gen !== root._sweepGen || !root.sweeping) return
    root.sweeping = false
    root.seatTo(root.sweepTo, "sweep")
  }

  // The current cell as an untyped value. `currentItem` is declared as
  // QQuickItem, and a delegate is free to be any Item with or without an
  // activate() - reading that member off a QQuickItem is a missing-property
  // diagnostic for every consumer that follows this contract. Going through a
  // `var`-returning function is what makes the duck-typed probe legal here,
  // and it is the same reason List.activate reads it the way it does.
  function _currentCell(): var { return root.currentItem }

  // Grid cursor movement. Cells step along the flat sequence; callers
  // step rows via moveRow. Clamps into [0, count-1].
  function gotoCell(idx, snap) {
    const n = root.count
    if (n === 0) return false
    idx = Range.clamp(idx, 0, n - 1)
    if (idx === root.currentIndex) return false
    root.currentIndex = idx
    // A wrap owns the viewport through sweepToEnd, so it takes no seat. Any
    // other step seats this cell through the funnel, which also retires a
    // pending wrap release.
    if (snap !== false) root.seatTo(idx, true)
    return true
  }

  function moveCell(step) {
    const n = root.count
    if (n === 0) return false
    let idx = root.currentIndex
    if (idx < 0 || idx >= n) idx = step < 0 ? n : -1
    const start = idx
    let cand = idx + step
    while (cand >= 0 && cand < n && !root.isSelectable(cand))
      cand += step
    if (cand < 0) cand = root.firstSelectable()
    else if (cand >= n) cand = root.lastSelectable()
    const wrapped = (step > 0 && cand < start) || (step < 0 && cand > start)
    if (!root.gotoCell(cand, !wrapped)) return false
    if (wrapped) root.sweepToEnd(step > 0)
    return true
  }

  function moveRow(step) {
    const n = root.count
    if (n === 0) return false
    const cols = Math.max(1, root.cols)
    let idx = root.currentIndex
    // Unseated cursor: Down lands on the very first cell, Up on the last.
    if (idx < 0 || idx >= n) idx = step < 0 ? n - 1 : -1
    const start = idx
    let cand = idx + step * cols
    const dir = step > 0 ? 1 : -1
    while (cand >= 0 && cand < n && !root.isSelectable(cand))
      cand += dir
    if (cand < 0) cand = root.firstSelectable()
    else if (cand >= n) cand = root.lastSelectable()
    const wrapped = (step > 0 && cand < start) || (step < 0 && cand > start)
    if (!root.gotoCell(cand, !wrapped)) return false
    if (wrapped) root.sweepToEnd(step > 0)
    return true
  }

  // A horizontal step, scoped to the cursor's own row. The flat sequence
  // moveCell walks would step off the right edge of one row into the first
  // cell of the next, which is exactly what makes Up/Down redundant on a
  // grid - and it lands the cursor a whole row away from where the key said.
  //
  // NavKeys.cell owns the geometry (it is the answer that knows about the
  // short last row); the loop here is the selectable skip moveRow has, and
  // it gives up once a lap returns the cell it started on, so a row whose
  // every cell is chrome answers false instead of looping.
  //
  // No wrap sweep: that tween is a vertical page effect (its targets are the
  // ends of the page), and a horizontal step never leaves the row.
  function moveColumn(step) {
    const n = root.count
    if (n === 0) return false
    const idx = root.currentIndex
    // Unseated cursor lands on the first selectable cell, the same answer
    // moveRow gives before it has a row to step from.
    if (idx < 0 || idx >= n) return root.gotoCell(root.firstSelectable())
    const start = idx
    let cand = NavKeys.cell(idx, n, root.cols, step, 0, true)
    for (let k = 0; k < n && !root.isSelectable(cand); k++)
      cand = NavKeys.cell(cand, n, root.cols, step, 0, true)
    if (cand === start) return false
    return root.gotoCell(cand)
  }

  // --- keyboard navigation contract (NavKeys.js, IslandNav.qml) ---
  //
  // The island key router knows a direction and a target, not a grid: it
  // calls moveBy(dx, dy) for the four arrows and activate() for Enter. A
  // vertical direction is a row step and a horizontal one is a column step,
  // and a diagonal takes the vertical half, because no key produces one.
  function moveBy(dx, dy): bool {
    if (dy !== 0) return root.moveRow(dy < 0 ? -1 : 1)
    if (dx !== 0) return root.moveColumn(dx < 0 ? -1 : 1)
    return false
  }

  // Enter on the current cell, same two-way contract as List.activate: a
  // delegate's own activate() wins, anything else reports through
  // `activated`, and no cell answers false.
  function activate(): bool {
    const idx = root.currentIndex
    if (idx < 0 || idx >= root.count) return false
    const it = root._currentCell()
    if (it !== null && it !== undefined && typeof it.activate === "function") {
      it.activate()
      return true
    }
    root.activated(idx)
    return true
  }

  // Seat on a real cell: chrome slots (headers/spacers) are skipped,
  // scanning forward then wrapping. Snap is accepted for List parity
  // and ignored: grid seating is always instant.
  function settle(idx, snap) {
    const count = root.count
    if (count === 0) return
    const start = Range.clamp(idx, 0, count - 1)
    let target = start
    for (let k = 0; k < count; k++) {
      const probe = (start + k) % count
      if (root.isSelectable(probe)) {
        target = probe
        break
      }
    }
    root.currentIndex = target
    root.seatTo(target, true)
  }

  // Bring a cell into view without moving the cursor.
  function reveal(idx) {
    if (idx < 0 || idx >= root.count) return
    root.seatTo(idx, true)
  }

  // Page motions: a page step clamps contentY by a factor of the viewport
  // height, an end jump seats the cursor on the selectable end cell. Both
  // take the funnel, so both retire a pending wrap release on the way; the
  // sweep can no longer write contentY a second time and undo a step that
  // just landed.

  // A page step is a hard cut through the funnel, not the wrap tween: that
  // tween's targets are the ends and it gives up below a full viewport, so
  // it cannot express a partial step at all.
  function pageBy(factor) {
    if (root.count === 0) return
    const maxY = Math.max(0, root.contentHeight - root.height)
    const raw = root.contentY + root.height * factor
    // Non-finite step (unlaid-out view, bad factor) degenerates to the
    // top, the rule List.clampY states, because Flickable would hold a
    // NaN offset for the rest of the view's life.
    const target = isFinite(raw) ? Range.clamp(raw, 0, maxY) : 0
    if (Math.abs(target - root.contentY) < 0.5) return
    root.seatTo(target, false)
  }

  // List.jumpEnd still pre-arms a content-tween FLOOR from the follow
  // target (see _sweepMs), but its highlight no longer takes a copied
  // duration: the bar reads the content tween's own live duration. Grid
  // seating has no bar twin, and the reason for the other half differs:
  // trackCursor is the center-lock follow seat, which is not where a
  // jump belongs - the end cell itself, seated at the viewport edge, is.
  function jumpEnd(last) {
    const n = root.count
    if (n === 0) return
    const target = last ? root.lastSelectable() : root.firstSelectable()
    if (target < 0) return
    // An end the cursor already sits on is re-seated rather than
    // refused: a page step moves the view without the cursor, so the
    // cursor can already be the end cell while the view is not, and the
    // jump has to bring the view to it either way.
    if (!root.gotoCell(target)) root.reveal(target)
  }
}

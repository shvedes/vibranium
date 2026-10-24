pragma ComponentBehavior: Bound
import QtQuick
import qs.common
import "NavKeys.js" as NavKeys

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
// zeroed motion, a plain step cancels any in-flight sweep.
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
  // the viewport teleports; the sweep rewinds past that snap deferred
  // and eases end to end instead. Targets are the ends, never a cell
  // lookup: headers and spacers make per-item math unreliable.
  property bool sweeping: false
  property real sweepY0: 0
  property real sweepTo: 0

  NumberAnimation {
    id: sweep

    target: root
    property: "contentY"
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
  }

  // A plain step, settle or drag supersedes any in-flight wrap sweep.
  function cancelSweep() {
    root.sweeping = false
    sweep.stop()
  }

  function sweepToEnd(toEnd) {
    if (!MotionPolicy.enabled || root.count === 0) return
    const maxY = Math.max(0, root.contentHeight - root.height)
    const target = toEnd ? maxY : 0
    // Pre-snap position: gotoCell's Contain snap lands on next polish.
    const y0 = root.contentY
    if (Math.abs(target - y0) < root.height) return
    const pages = Math.abs(target - y0) / Math.max(1, root.height)
    root.sweepY0 = y0
    root.sweepTo = target
    root.sweeping = true
    sweep.duration = Math.min(650, Math.round(Ui.fastMs + pages * 140))
    Idle.run(() => {
      if (!root.sweeping) return
      root.sweeping = false
      sweep.stop()
      root.contentY = root.sweepY0
      sweep.to = root.sweepTo
      sweep.restart()
    }, 2)
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
  function gotoCell(idx) {
    const n = root.count
    if (n === 0) return false
    idx = Math.min(Math.max(0, idx), n - 1)
    if (idx === root.currentIndex) return false
    root.currentIndex = idx
    root.positionViewAtIndex(idx, GridView.Contain)
    return true
  }

  function moveCell(step) {
    const n = root.count
    if (n === 0) return false
    root.cancelSweep()
    let idx = root.currentIndex
    if (idx < 0 || idx >= n) idx = step < 0 ? n : -1
    const start = idx
    let cand = idx + step
    while (cand >= 0 && cand < n && !root.isSelectable(cand))
      cand += step
    if (cand < 0) cand = root.firstSelectable()
    else if (cand >= n) cand = root.lastSelectable()
    const wrapped = (step > 0 && cand < start) || (step < 0 && cand > start)
    if (!root.gotoCell(cand)) return false
    if (wrapped) root.sweepToEnd(step > 0)
    return true
  }

  function moveRow(step) {
    const n = root.count
    if (n === 0) return false
    root.cancelSweep()
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
    if (!root.gotoCell(cand)) return false
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
    root.cancelSweep()
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
    root.cancelSweep()
    const start = Math.min(Math.max(0, idx), count - 1)
    let target = start
    for (let k = 0; k < count; k++) {
      const probe = (start + k) % count
      if (root.isSelectable(probe)) {
        target = probe
        break
      }
    }
    root.currentIndex = target
    root.positionViewAtIndex(target, GridView.Contain)
  }

  // Bring a cell into view without moving the cursor.
  function reveal(idx) {
    if (idx < 0 || idx >= root.count) return
    root.positionViewAtIndex(idx, GridView.Contain)
  }

  // Page motions: a page step clamps contentY by a factor of the
  // viewport height, an end jump seats the cursor on the selectable end
  // cell. Both take the view position outright, and both drop an
  // in-flight sweep on the way: that sweep writes contentY a second
  // time, on the next turn, snapping back to the end the cursor just
  // left, so a page step taken without the cancel would be undone a
  // frame after it landed.

  // A page step writes contentY outright rather than driving the sweep.
  // List routes a page through seatTo because seatTo is that file's only
  // contentY writer; a grid page has no such funnel, its cursor steps
  // seat with positionViewAtIndex, and the one tween this file owns is
  // the wrap sweep - whose targets are the ends and which gives up below
  // a full viewport, so it cannot express a partial step at all. The
  // write is the same hard cut every other grid seat takes.
  function pageBy(factor) {
    if (root.count === 0) return
    const maxY = Math.max(0, root.contentHeight - root.height)
    const raw = root.contentY + root.height * factor
    // Non-finite step (unlaid-out view, bad factor) degenerates to the
    // top, the rule List.clampY states, because Flickable would hold a
    // NaN offset for the rest of the view's life.
    const target = isFinite(raw) ? Math.min(Math.max(0, raw), maxY) : 0
    if (Math.abs(target - root.contentY) < 0.5) return
    root.cancelSweep()
    root.contentY = target
  }

  // List.jumpEnd pre-arms the highlight bar's sweep duration from the
  // follow target and then calls trackCursor. Grid seating has no twin
  // for either, and the reasons differ: the pre-arm exists to hand a
  // bar tween the same duration as a content tween, and trackCursor is
  // the center-lock follow seat, which is not where a jump belongs -
  // the end cell itself, seated at the viewport edge, is.
  function jumpEnd(last) {
    const n = root.count
    if (n === 0) return
    const target = last ? root.lastSelectable() : root.firstSelectable()
    if (target < 0) return
    root.cancelSweep()
    // An end the cursor already sits on is re-seated rather than
    // refused: a page step moves the view without the cursor, so the
    // cursor can already be the end cell while the view is not, and the
    // jump has to bring the view to it either way.
    if (!root.gotoCell(target)) root.reveal(target)
  }
}

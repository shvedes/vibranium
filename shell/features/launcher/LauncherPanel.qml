pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.launcher
import qs.features.clipboard
import "LauncherLib.js" as LauncherLib
import "../../common/ui/SlotGrowth.js" as SlotGrowth

// The launcher card: search bar over a compact result list, built from the
// same region math and chrome tokens as MenuPanel so the two surfaces read
// as siblings. All state (mode, query, results) lives in the AppLauncher
// service - this file is rendering plus the keyboard model.
//
// KEYBOARD MODEL (list-first, like MenuPanel):
// The list holds the focus from the open, so Delete/Ctrl-D and the other
// list binds work from the first key. Typing feeds the filter: the first
// printable flips into filter mode with that key applied, and the caret
// is live from there on. Arrows/Tab/PageUp/Down move selection in either
// mode without surrendering the caret once filtering.
//   any typing (list) -> filter + filters live
//   arrows/tab     move selection
//   enter          activate current row (or run armed action)
//   delete/ctrl+d  remove current row, from the list or the filtered field
//   ctrl+i         toggle description
//   backspace      empty field: peel action/info/mode, then de-focus to list
//   esc            single ESC close when in normal root, otherwise peel
//
// The list-mode routes below are the seat: a summon runs before its
// surface holds the keyboard, so the first printable key still feeds the
// filter and the mode follows once the grant lands.
PanelCard {
  id: panel

  maxHeight: 600
  hardMaxHeight: 1200
  vPad: Ui.outerPad + 8
  hPad: Ui.outerPad
  baseWidth: 380
  rowIconW: 26
  rowBadgeW: 22
  _maxLabelW: 420

  count: list.count
  contentHeight: list.contentHeight
  // A keystroke is a real resize, so the card glides to its fitted height
  // even inside the show gate. Without this the open's first layout and a
  // filter tick arriving together made the card snap: the resize the user
  // was typing towards landed as a jump.
  sizeMotionDuringGate: AppLauncher.entry !== ""
  property real _latchedListH: -1
  property bool _fitPending: false
  property int _fitAttempts: 0
  exactListH: panel._latchedListH
  fitPending: panel._fitPending
  rows: AppLauncher.results
  // The gap between rows is the LIST's, read rather than assumed: the card
  // sums the same gap the list places, so the region's bottom edge stays on
  // a row boundary whatever a surface decides to space its rows by.
  rowSpacing: list.spacing
  rowLimit: panel.slotLimit
  readonly property int slotLimit: {
    const rows = panel.rows || []
    const first = rows[0]
    const second = rows[1]
    const activeClip = rows.length > 1
      && first
      && first.clip === true
      && second
      && second.kind === "separator"
    const target = activeClip ? 11 : 10
    let contentRows = 0
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]
      if (!row || row.kind === "separator") continue
      contentRows++
      if (contentRows >= target) return i + 1
    }
    return rows.length
  }
  // The list owns the growth claim (List.revealNeedH) and the rule that turns
  // it into a region lives once, in SlotGrowth.js - the same one MenuPanel
  // uses, so a description or delete confirm on a result row cannot be sized
  // by a different geometry than a dropdown in the settings menu.
  //
  // `slotOpen` is separate from the region override because a slot that fits
  // in the resting region asks for no resize while still making the content
  // taller; see PanelCard._latchRestingBuffer.
  slotOpen: list.revealNeedH > 0
  slotRegionH: SlotGrowth.regionForSlot(
    list, panel.restingListH, panel.screenMaxListH, Ui.s)

  readonly property bool searching: AppLauncher.entry !== ""
  readonly property bool primarySurface: visible

  // The show gate opening ends the open-time snap: height changes tween
  // again from here (typing, late arrivals). Fires a full gate interval
  // after the open, so no sizing instant shares its turn.
  onShownChanged: {
    if (panel.shown) panel.sizeSnap = false
  }

  Component.onCompleted: { AppLauncher._attachPanel(panel); panel.syncRows(); panel.queueFit() }
  Component.onDestruction: AppLauncher._detachPanel(panel)
  TapHandler { onTapped: panel.focusSearch() }

  function focusSearch() { focusCtrl.grabFilter() }

  Connections {
    target: AppLauncher
    function onResultsChanged() {
      panel.syncRows()
      if (!panel.searching) panel.recalcWidth()
      panel.closeTrailingInfo()
      panel.closeDelete()
      panel.queueFit()
    }

    function onVisibleChanged() {
      if (!AppLauncher.visible) {
        // Arm the open-time snap while hidden: the next open's first
        // sizing instant lands in the same turn as the show gate closing,
        // and a Behavior reads the gate's pre-turn value - so a height
        // delta to a new row set (a fresh clipboard suggestion, a changed
        // pool) would glide instead of spawning. Armed here, a turn early,
        // the snap is already in force when the height changes. Released
        // by input while visible (onEntryChanged) or when the gate opens
        // (onShownChanged), so typing still glides.
        panel.sizeSnap = true
        return
      }
      AppLauncher.pendingDelete = null
      // sizeSnap stays as the close armed it: the open sizes itself
      // under that snap and never inherits a glide from the gate.
      panel.show()
      panel._openSeat = true
      panel.syncRowsNow()
      panel.queueFit()
      searchField.text = ""
      // List-first: the list holds the seat, so Delete/Ctrl-D work from
      // the first key. The first printable flips into filter mode via
      // handleKey, like every other filter surface. A request made before
      // the compositor's keyboard grant records nothing, and the grant
      // runs PanelFocus.reassert() again.
      focusCtrl.grabList()
    }
    function onEntryChanged() {
      if (searchField.text !== AppLauncher.entry) searchField.text = AppLauncher.entry
      // User input while visible ends the open-time snap: the resize the
      // typing drives glides like any other. Guarded on visible so the
      // close-path reset (which runs hidden) cannot disarm the snap the
      // close just armed.
      if (AppLauncher.visible) panel.sizeSnap = false
    }
    function onModeChanged() {
      panel.closeTrailingInfo()
      if (!AppLauncher.visible) return
      if (AppLauncher.mode !== "normal") {
        panel._modeExitFade = false
        panel.focusSearch()
        panel.playModeEnter()
      } else {
        panel.playModeExit()
      }
    }
  }

  // One deferred model install per frame: results are rebuilt wholesale per
  // keystroke, so a burst (e.g. prefix entry) would otherwise diff once per
  // intermediate row set. Coalescing to the next event-loop turn batches the
  // burst into a single install - the latest rows always win.
  property bool _rowsPending: false
  // Model-swap generation: burst swaps must not re-arm on a stale
  // frame (see both re-arms in the deferred swap below).
  property int _swapGen: 0
  // Open-seat flag: armed on visible open, forces a first-normal
  // seat so a stale cursor never survives a summon.
  property bool _openSeat: false
  // First selectable index that is not a clipboard suggestion. The
  // suggestion row (kind "file" with clip:true) sits above the idle list
  // but must never be the automatic focus on open - see AppLauncher.
  function _firstNormalIndex() {
    for (let i = 0; i < panel.rows.length; i++) {
      const r = panel.rows[i]
      if (!r) continue
      if (r.clip === true) continue
      if (r.kind === "separator") continue
      if (!list.isSelectable(i)) continue
      return i
    }
    // No normal row - select nothing so the clipboard suggestion never
    // takes the automatic focus. It stays keyboard-reachable by arrows.
    return -1
  }
  // Launcher rows. Every row change - a filter tick, a re-rank, the
  // application list arriving from DesktopEntries, a delete - assigns a new
  // record array, so the List keeps its measured-height table (keyed by uid
  // below) instead of losing it to unkeyed estimates. The panel never assigns
  // `list.model` directly; installRows() is its single writer, and
  // panel._records is the array the view reads.
  //
  // The key is the record `uid`, which every producer namespaces ("app:",
  // "web:", "clip:", "file:", "time:", and the engine families "fx:" and
  // "unit:" with the target unit after the colon, because those two answer
  // with a row per reading) or names outright ("calc"), so it
  // identifies a row for the height table and the guard rather than for the
  // view: the view diffs by index. The separator is the one record with no
  // uid - keyedRows files it under the "sep:" namespace, which no producer
  // emits, so it cannot collide with a real uid - and a recomputed set
  // carries at most one separator, so it cannot repeat.
  //
  // That missing field has one measured cost: the height table has no
  // identity to match the separator on across a re-rank that changes its
  // neighbours' order, so the separator relearns its 12px instead of
  // carrying it - invisible on a hairline with no slot.
  // Stamping the synthesized key onto the record would hide it, at the
  // price of the panel writing a field into a record the service owns.
  //
  // The view's rows and `panel.rows` are two arrays that agree only
  // immediately after a successful install. Six readers index one by the
  // other's index - _firstNormalIndex and isSelectable take a view index into
  // panel.rows, and toggleInfoCurrent, toggleDeleteCurrent and
  // activateCurrent take list.currentIndex into panel.rows - so a refused
  // install leaves the view on the previous set with panel.rows already moved
  // on, and a cursor action would name the record the cursor is not on.
  // Nothing the shipped producers emit can refuse an install, and every
  // other keyed panel accepts the same exposure, so this inherits that
  // discipline rather than inventing a second scheme.
  // The live row objects the view shows. The List reads this array
  // directly as its model: ListView diffs array swaps by index, so a filter
  // tick that mints fresh records updates each slot in place and drops only
  // the slots beyond the new end - removed rows never linger visible the way
  // they do under a keyed ScriptModel with pooled reuse. The records reach
  // the delegate whole, as modelData - there is no wrapper role to unwrap.
  property var _records: []
  // Identity epoch for the height table. A plain array reports neither a
  // revision nor a key-set flag, so the panel owns the counter: installRows
  // folds the key sequence into _lastSeq and every sequence that differs from
  // the last one advances the epoch. A counter and not the sequence itself,
  // because a sequence returns to an earlier value when rows are reordered
  // back and the epoch must never repeat an earlier value
  // (List.identityRevision).
  // Advanced at the model's single write site rather than from a binding over
  // the value it reads: that is a loop, and the engine warns about it on
  // every pass.
  property int _epoch: 0
  property var _lastSeq: ""
  readonly property int identityRevision: panel._epoch
  property string _modelError: ""

  // The identity one record is filed under, in one place: keyedRows
  // deduplicates on it, installRows folds the epoch's key sequence from it,
  // and the head-stability read computes both of its heads through it. ""
  // means the record carries no usable identity and the row set is refused.
  function _rowKey(rec) {
    if (!rec) return ""
    const uid = rec.uid
    if (uid !== undefined && uid !== null) return String(uid)
    return String(rec.kind ?? "") === "separator" ? "sep:" : ""
  }

  // The row set this panel's own guard accepts, and the row objects the
  // delegate reads: the view shows the records whole, as modelData, so the
  // record has to BE the row rather than a wrapper beside it.
  //
  // This is also where the identity vocabulary stays. Two live rows on one
  // identity is a failure the height table cannot absorb: it refuses to
  // measure either of them, sets identityError, and reports that to nobody
  // by deliberate design (List.identityError). The height table degrades with
  // nothing anywhere saying why, and the panel builds the rows, so the
  // panel is where the check belongs.
  function keyedRows() {
    const src = panel.rows
    if (!Array.isArray(src)) { panel._modelError = "not_array"; return null }
    const rows = new Array(src.length)
    const seen = Object.create(null)
    for (let i = 0; i < src.length; i++) {
      const rec = src[i]
      if (!rec) { panel._modelError = "invalid_row"; return null }
      const key = panel._rowKey(rec)
      if (key.trim() === "") { panel._modelError = "missing_key"; return null }
      if (seen[key] !== undefined) { panel._modelError = "duplicate_key"; return null }
      seen[key] = true
      rows[i] = rec
    }
    return rows
  }

  function installRows() {
    const rows = panel.keyedRows()
    // A refused set writes nothing at all: the previous rows stay on screen
    // until a set that passes arrives. Nothing outside this panel writes the
    // model, so there is no drift to repair and no second verb to fall back
    // from. The refusal is the whole of the guard: a set this guard refuses
    // is one no write would have installed.
    if (rows === null) return
    panel._modelError = ""
    // The model's single write: the view reads panel._records directly, so
    // this assignment is the diff.
    panel._records = rows
    // The identity epoch, advanced here and nowhere else: this is the model's
    // one write, so it is the only place a new key sequence can appear. A
    // payload-only install - a new calc result, a fresh time string, an icon
    // toggle - leaves the sequence alone and so keeps the measured heights,
    // while a key-set change advances the epoch and prunes the rows the new
    // key set drops. NUL separates the keys and no key can hold one (they are
    // namespaced or fixed names), so the join cannot forge a boundary
    // between two rows.
    //
    // INVARIANT (payload-in-place, no rebuild): a payload-only install must
    // keep every visible delegate - same uid, new record objects, changed
    // label/sub - with no rebuild animation. The epoch gate above is what
    // keeps it: the sequence is key-only, so a payload change advances
    // nothing, the height table is kept, and the index-diffed array swap
    // rebinds the live rows' modelData in place instead of recreating them.
    // Do not advance the epoch here for payload reasons and do not key the
    // sequence on anything but identity: either one turns a subtext tick
    // into a remove-plus-insert and the entry repaints instead of updating.
    const seq = rows.map(r => panel._rowKey(r)).join("\u0000")
    if (seq !== panel._lastSeq) {
      panel._lastSeq = seq
      panel._epoch++
    }
  }

  function queueFit() {
    const rows = panel.rows || []
    if (rows.length === 0) {
      panel._latchedListH = -1
      panel._fitPending = false
      return
    }
    // Size from the model NOW, in the same turn as the rows, and let the
    // measured fit correct it when it lands.
    //
    // Without this the card is painted at the PREVIOUS row set's height for
    // as long as the measurement is in flight - at least two event-loop turns
    // and up to 24 frame-paced retries - because PanelCard.restingListH holds
    // the last committed fit across a pending one on purpose, to keep the card
    // still across a keystroke. Those two together are the staged shift a
    // filter tick shows: the rows arrive at their new count, the card stays
    // where it was, and the height catches up afterwards in one step.
    //
    // The model height is the whole-row sum, so the card's bottom edge lands on
    // a row boundary in the same frame the rows do, which is the rule the
    // window exists to keep. The measurement that follows is the authority and
    // still wins; where the two differ it is the probe's documented
    // underestimate of the delegates' ceil(FontMetrics.height) floor, which
    // vanishes at an integral scale factor and shows at a fractional one, so
    // the correction is bounded by that and not by the row set.
    //
    // Ahead of the pending check on purpose: keystrokes arrive faster than the
    // fit settles and the row set has already changed again by then, so the
    // model is re-read there too - otherwise the card would track the second
    // keystroke's rows at the first one's height.
    //
    // The guard is not defensive noise: with no resolved ceiling snappedListH
    // answers 0, and PanelCard._latchRestingFit accepts 0 as a measurement
    // (it only refuses a negative one), so an unguarded write pins
    // _restingFitH at 0 and the pending branch hands the card an empty
    // region's height - which is a collapse, not a stale value.
    const model = panel.snappedListH(panel.availListH)
    if (model > 0) panel._latchedListH = model
    if (panel._fitPending) {
      panel._fitAttempts = 0
      if (fitRetryTimer.fitCallback !== null) fitRetryTimer.restart()
      return
    }
    panel._fitPending = true
    panel._fitAttempts = 0
    const fail = () => {
      panel._latchedListH = -1
      panel._fitPending = false
    }
    // Two waits, two budgets: geometry in motion outlives a few frames,
    // while a count that has not caught up resolves in one. Function
    // declarations, not arrows: they hoist, and a `const` above its first
    // use reports qt.qml.usedbeforedeclared.
    function retrySettle() {
      if (panel._fitAttempts < 24) {
        panel._fitAttempts++
        fitRetryTimer.fitCallback = tryFit
        fitRetryTimer.restart()
        return
      }
      fail()
    }
    function retryFit() {
      if (panel._fitAttempts < 8) {
        panel._fitAttempts++
        fitRetryTimer.fitCallback = tryFit
        fitRetryTimer.restart()
        return
      }
      fail()
    }
    function tryFit() {
      if (!panel._fitPending) return
      fitRetryTimer.stop()
      fitRetryTimer.fitCallback = null
      const rows = panel.rows || []
      if (rows.length === 0) {
        panel._latchedListH = -1
        panel._fitPending = false
        return
      }
      // Motion and a swap in flight defer the measurement - the row is
      // about to be a different height, and the next frame reads it right.
      // An open but RESTING description or delete confirm does not: nothing
      // about it is about to change, so the fit gives up instead of spending
      // its budget on it, and the region falls back to the card's resting
      // buffer, which re-latches from the live content.
      let movingSlot = false
      let restingSlot = false
      const kids = list.contentItem.children
      for (let i = 0; i < kids.length; i++) {
        const d = kids[i]
        if (!(d instanceof LauncherEntry)) continue
        if (d.slotMotionMs > 0) { movingSlot = true; break }
        if (d.descSlotH > 0 || d.deleteSlotH > 0) restingSlot = true
      }
      if (list._inSwap || movingSlot) {
        retrySettle()
        return
      }
      if (restingSlot) {
        fail()
        return
      }
      if (list.count !== rows.length) {
        retryFit()
        return
      }
      const fit = list.fitHeight(panel.availListH, panel.slotLimit)
      if (fit < 0 && rows.length > 0) {
        retryFit()
        return
      }
      panel._latchedListH = fit
      panel._fitPending = false
      // Settled relatch for the card's resting buffer: this point is only
      // reached with no slot in motion, no resting slot heights and the
      // count matched, so the live contentHeight is resting content for the
      // current row set. A row set that changed while a slot was open
      // skipped the count-driven latch (gated by slotOpen), and the slot
      // edge itself must not latch (mid-collapse) - this is the one place
      // that reads settled content for the new set.
      panel._latchRestingBuffer()
    }
    Qt.callLater(() => {
      if (!panel._fitPending) return
      Qt.callLater(tryFit)
    })
  }

  // Frame-paced fit retries. Re-posting through Qt.callLater instead paced
  // the wait on event-loop turns, which is both unbounded (the wait above
  // never reached its own give-up) and busy: it rescanned every live
  // delegate per turn for as long as the condition held, competing with the
  // polish it was waiting on. A timer paces the retry; the attempt budget
  // bounds it.
  Timer {
    id: fitRetryTimer

    property var fitCallback: null
    interval: 16
    repeat: false
    onTriggered: {
      const retry = fitRetryTimer.fitCallback
      fitRetryTimer.fitCallback = null
      if (typeof retry === "function") retry()
    }
  }

  function syncRowsNow() {
    // Synchronous open-path seat: runs the pending-rows body inline
    // without callLater when rows are already computed, so the first
    // frame maps at final size and scroll. Returns false when the
    // deferred syncRows() must handle it (cold boot with no rows yet).
    if (panel.rows.length === 0) return false
    // The open owns the first paint, so an open seat steals a pending
    // deferred install instead of bailing behind it: the facade computes
    // before the visible flip, which schedules exactly such an install
    // while hidden, and bailing would paint the stale set first and land
    // the fresh one a turn later - the post-open growth. The stolen flag
    // only cancels the deferral: the scheduled callback still fires and
    // reinstalls the same set, which is a sequence-identical no-op. The
    // open-seat path below never calls _maybeSwapFade, so the
    // close-armed sizeSnap stays in force across the stolen install.
    if (panel._rowsPending) {
      if (panel._openSeat !== true) return false
      panel._rowsPending = false
    }
    // Open seat: never reuse the cursor, install with zeroed durations,
    // first-normal selection, origin scroll. The diff keeps the delegates
    // a previous summon already built, which is the table the List would
    // otherwise re-measure from nothing.
    if (panel._openSeat === true) {
      panel._openSeat = false
      const openIdx = panel._firstNormalIndex()
      list.beginSwap()
      panel.installRows()
      list.seat(openIdx >= 0 ? openIdx : -1, "land")
      list.seatTo(0, false, "launcher-open")
      list.endSwap()
      return true
    }
    const idx = panel._firstNormalIndex()
    // Durations are zeroed around the install either way so the seat never
    // glides, and an identical row set needs no separate skip: the model's
    // `values` reassignment is the diff and a re-rank that keeps the key
    // sequence advances no epoch. Regime flips mask the rebuild flash (see
    // _maybeSwapFade).
    panel._maybeSwapFade()
    list.beginSwap()
    panel.installRows()
    list.seat(idx >= 0 ? idx : -1, "land")
    list.seatTo(0, false, "launcher-swap")
    list.endSwap()
    return true
  }
  // Kinds rendered as one synthetic row by design (never a filterable
  // pool) - single definition lives in LauncherLib (shared with the
  // service counter gate).
  function _synthKind(kind) {
    return LauncherLib.isSynthKind(kind)
  }
  // Regime change between the live model and the pending rows:
  // app pool <-> engine answer (any row counts), or a kind switch within
  // single engine answers (web fallback -> live time row, app-single ->
  // calc). The install below rebuilds every delegate for these, so the
  // caller masks it with playSwapFade(). Multi<->multi filtering within one
  // side never fades.
  function _needsSwapFade() {
    // The live row's payload, not list.model[0]: the model is a
    // QAbstractItemModel and indexes to undefined. Read before the diff
    // lands (see _maybeSwapFade), so it is the record the view still shows.
    const live = list.count === 1 ? list.itemAtIndex(0) : null
    const cur = live && live.modelData ? live.modelData : null
    const nxt = panel.rows.length === 1 ? panel.rows[0] : null
    const curS = cur && panel._synthKind(String(cur.kind ?? "")) ? String(cur.kind) : ""
    const nxtS = nxt && panel._synthKind(String(nxt.kind ?? "")) ? String(nxt.kind) : ""
    if ((curS === "") !== (nxtS === "")) return true
    if (curS !== "" && curS !== nxtS) return true
    // Multi-row engine answers (unit/fx/color lists): the single-row reads
    // above see any count other than 1 as "not synth" on that side, so an
    // app-single -> unit-list flip read "" vs "" and rebuilt with no mask
    // at all. The full-set regime test below covers exactly those flips;
    // within-regime multi-row updates (unit readings 6 -> 4 while typing)
    // stay unfaded, as does app<->app filtering.
    if (panel._regimeOf(panel._records) !== panel._regimeOf(panel.rows)) return true
    return false
  }
  // Which side of the app-pool <-> engine-answer divide a row set sits on.
  // One predicate for the fade test above and the geometry snap in
  // _maybeSwapFade, so the two can never disagree about what a flip is.
  // Pass raw record arrays (panel._records for the live set, panel.rows
  // for the pending one).
  function _regimeOf(set) {
    return LauncherLib.allSynthKinds(Array.isArray(set) ? set : [])
  }
  // Regime fade with mode-exit suppression: X->normal already played
  // the backward slide, so the swap underneath must not start a second
  // fade over it. Consumes the flag either way; a stale flag (exit with
  // no following sync, practically impossible - modes always rebuild)
  // clears on the next sync or mode entry instead of leaking.
  function _maybeSwapFade() {
    // Either directional fade already owns listBox.opacity: an enter/exit
    // slide is playing, so a second opacity tween over it reads as a jump,
    // not a fade. Consume both flags either way; a stale flag clears here
    // instead of leaking into the next sync.
    const skip = panel._modeExitFade === true || panel._modeEnterFade === true
    panel._modeExitFade = false
    panel._modeEnterFade = false
    // A mode transition and a cross-regime flip both keep the card gliding
    // to its fitted size while the content motion masks the delegate
    // rebuild underneath: snapping the edge here is what read as a jump
    // with animations on, since the resize tween never ran. Same-regime
    // installs keep gliding, so every row-set change resizes
    // the same way.
    // Set on every sync before the install it governs, so no stale value can
    // outlive the row set it was decided for.
    panel.sizeSnap = false
    if (skip) return
    // The fade still masks a delegate rebuild - regime flip or same-regime
    // kind switch (calc<->web) - while the card glides underneath it, so
    // the replacement reads as a fade rather than a flash.
    const _fadeVerdict = panel._needsSwapFade()
    if (_fadeVerdict) panel.playSwapFade()
  }
  function syncRows() {
    if (panel._rowsPending) return
    panel._rowsPending = true
    Qt.callLater(() => {
      panel._rowsPending = false
      // A row set that grows under a seated list (the application list
      // arriving from DesktopEntries after a cold open) resets the
      // ListView's currentIndex to 0, so the highlight would paint on the
      // suggestion then glide 0 -> idx. Zero the highlight durations around
      // the install so the correction lands instantly on the first desktop
      // entry.
      const clipHeaded = panel.rows.length > 0 && panel.rows[0].clip === true
      panel._swapGen++
      const g = panel._swapGen
      const idx = panel._firstNormalIndex()
      if (clipHeaded) {
        // Clipboard suggestion heads the list: rest at the top without
        // fighting centerCursor. settle(idx, true) snaps instantly with
        // no pin vs pursuit fight and no negative overshoot.
        list.swapRun(g, v => v === panel._swapGen, () => {
          panel._maybeSwapFade()
          panel.installRows()
          panel._openSeat = false
          if (idx >= 0) list.settle(idx, true)
          else list.seat(-1, "land")
        })
        // settle(idx, true) seats instantly through the List guards, so
        // no pin timer is needed to hold the origin.
      } else {
        // Same bottom-flicker as MenuPanel: a filter install resets the
        // index while the glide is armed. Snap, then re-arm.
        // Double-deferred: polish + settle land after the install.
        list.swapRun(g, v => v === panel._swapGen, () => {
          // Head identity BEFORE the diff: the key the model still files
          // row 0 under, read off the panel's own live records rather than
          // a live delegate so it does not depend on row 0 being
          // instantiated, and resolved through _rowKey so it names the same
          // string the guard deduplicated on and the epoch's sequence is
          // folded from. installRows() runs below, after which the answer
          // is the new head's.
          const oldHead = list.count > 0 ? panel._rowKey(panel._records[0] ?? null) : ""
          const newHead = panel._rowKey(panel.rows[0] ?? null)
          // Regime flip masks the rebuild flash underneath (snap to 0
          // here, the diff applied below in the same block).
          panel._maybeSwapFade()
          panel.installRows()
          // Head-stable filter tick: the head record survived with the same
          // key AND the cursor already sits on it, so keep cursor, scroll
          // and highlight parked instead of re-settling row 0. The open
          // seat never takes this keep - it always settles first-normal.
          const headStable = oldHead !== "" && newHead !== "" && oldHead === newHead
          const openSeat = panel._openSeat === true
          panel._openSeat = false
          if (!openSeat && headStable && list.currentIndex === idx) {
            // Model already installed above; cursor already home.
            // Nothing to do - deliberately no settle(), no contentY touch.
          } else if (idx >= 0) list.settle(idx, true)
          else list.seat(-1, "land")
        })
       }
       panel.queueFit()
       Qt.callLater(() => {
         focusCtrl.reassert()
       })
    })
  }

  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: AppLauncher.visible
  }
  property alias mode: focusCtrl.mode

  function currentRow() { return list.currentItem }
  function moveSelection(direction) {
    const prev = panel.currentRow()
    if (!list.move(direction)) return
    if (prev && panel.currentRow() !== prev) panel.closeTrailingInfo()
  }

  property int _infoIndex: -1
  function toggleInfoCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) return
    const rec = panel.rows[idx]
    if (!rec || rec.desc === "") return
    _infoIndex = _infoIndex === idx ? -1 : idx
    list.autoRevealIndex = _infoIndex
  }

  // Whether the current row is one the delete flow may act on. The search
  // field arms its destructive keys from this, so with nothing removable under
  // the cursor Delete keeps editing the query instead of being swallowed.
  readonly property bool deleteKeyAvailable: {
    const idx = list.currentIndex
    const rec = idx >= 0 && idx < panel.rows.length ? panel.rows[idx] : null
    return !!rec && rec.kind === "app" && rec.removable === true
  }

  // Three-step delete: hint -> armed -> confirm.
  function toggleDeleteCurrent() {
    const idx = list.currentIndex
    // Different row: close current and open for the new one.
    if (_deleteIndex >= 0 && _deleteIndex !== idx) closeDelete()
    // Same row: advance stage.
    if (_deleteIndex === idx) {
      if (_deleteStage >= 2) {
        panel.acceptDelete()
        return
      }
      _deleteStage++
      if (_deleteStage === 1) AppLauncher.requestDelete(panel.rows[idx])
      list.autoRevealIndex = idx
      return
    }
    // Fresh open.
    const rec = idx >= 0 && idx < panel.rows.length ? panel.rows[idx] : null
    if (rec && rec.removable === true) {
      _deleteIndex = idx
      _deleteStage = 1
      AppLauncher.requestDelete(rec)
      list.autoRevealIndex = idx
    }
  }
  property int _deleteIndex: -1
  property int _deleteStage: 0
  function closeDelete() { _deleteIndex = -1; _deleteStage = 0; list.autoRevealIndex = -1; AppLauncher.pendingDelete = null }
  function closeTrailingInfo() { _infoIndex = -1; list.autoRevealIndex = -1 }

  // Modal accept: while the delete confirmation is open, Enter/Space (and
  // the search field's accepted) confirm the deletion instead of launching
  // the row. Deliberately works from any stage - the open dialog is the
  // confirmation itself.
  function acceptDelete() {
    AppLauncher.confirmDelete()
    panel.closeDelete()
  }

  function activateCurrent() {
    // The delete confirmation takes precedence over row activation.
    if (panel._deleteIndex >= 0) { panel.acceptDelete(); return }
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) {
      const fb = panel._firstNormalIndex()
      if (fb >= 0) list.settle(fb, true)
      else if (panel.rows.length > 0) list.seat(-1, "land")
      return
    }
    AppLauncher.activate(panel.rows[idx])
  }

  function escapeChain() {
    if (panel._deleteIndex >= 0) { panel.closeDelete(); return }
    if (panel._infoIndex >= 0) { panel.closeTrailingInfo(); return }
    if (AppLauncher.mode !== "normal") {
      // Back out to the query, not to the list: the seat is the field, and
      // the query the mode was entered with stays in it either way.
      if (AppLauncher.entry !== "") { AppLauncher.exitMode(); focusCtrl.grabFilter(); return }
      AppLauncher.exitMode()
      focusCtrl.grabFilter()
      return
    }
    // Normal mode: ESC always closes the surface, even from the
    // focused field with a query.
    AppLauncher.close()
  }

  // Backspace on an empty focused field de-focuses to the list, like the
  // other menus - but it never closes the surface. Fires only from the
  // field (InputField.backspaceEmpty), so the field is empty here by
  // construction. Peels delete/info/mode first, mirroring escapeChain.
  function backspaceEmptyChain() {
    if (panel._deleteIndex >= 0) { panel.closeDelete(); return }
    if (panel._infoIndex >= 0) { panel.closeTrailingInfo(); return }
    if (AppLauncher.mode !== "normal") {
      AppLauncher.exitMode()
      focusCtrl.grabList()
      return
    }
    if (AppLauncher.entry !== "") {
      AppLauncher.submit("")
      if (searchField.text !== "") searchField.text = ""
      focusCtrl.grabList()
      return
    }
    focusCtrl.grabList()
  }

  function scrollBy(factor) { list.pageBy(factor) }
  function jumpEnd(last) { list.jumpEnd(last) }

  // Ctrl-V with an inactive search box: append the clipboard text to the
  // query. No focus is stolen - the field stays unfocused, the query
  // updates through AppLauncher.submit() and the list re-filters where it
  // stands. Text comes from the resident Clipboard singleton (the same
  // history the controller subscribes to) instead of a wl-paste child ->
  // no spawn per paste; newlines collapse to spaces because the query is
  // a single line.
  function pasteIntoSearch() {
    const hist = Clipboard.history
    if (!hist || hist.length === 0) return
    const entry = hist[0]
    if (!entry) return
    // Text-only paste -> image/file/secret rows never leak bytes into the
    // query: only the text, url and network flavours are pasted.
    const kind = String(entry.type ?? "")
    if (kind !== "text" && kind !== "url" && kind !== "network") return
    const clip = String(entry.raw ?? "").replace(/[\r\n]+/g, " ").trim()
    if (clip === "") return
    AppLauncher.submit(AppLauncher.entry + clip)
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const meta = event.modifiers & Qt.MetaModifier

    // Ctrl-V with an inactive search box: paste the clipboard into the
    // query without stealing focus. With the field focused, TextInput's
    // native paste consumes the key before it ever reaches here.
    if (k === Qt.Key_V && ctrl && !meta && focusCtrl.mode === "list") {
      panel.pasteIntoSearch()
      event.accepted = true
      return
    }

    if ((k === Qt.Key_D && ctrl) || k === Qt.Key_Delete) {
      panel.toggleDeleteCurrent()
      event.accepted = true
      return
    }
    if (k === Qt.Key_I && ctrl) { panel.toggleInfoCurrent(); event.accepted = true; return }
    if (k === Qt.Key_F && ctrl) { focusCtrl.grabFilter(); event.accepted = true; return }

    switch (k) {
      case Qt.Key_Down:
        if (panel._deleteIndex < 0) { panel.moveSelection(1); event.accepted = true; return }
        break
      case Qt.Key_Tab:
        if (panel._deleteIndex >= 0) panel.closeDelete()
        panel.moveSelection(1); event.accepted = true; return
      case Qt.Key_Up:
        if (panel._deleteIndex < 0) { panel.moveSelection(-1); event.accepted = true; return }
        break
      case Qt.Key_Backtab:
        if (panel._deleteIndex >= 0) panel.closeDelete()
        panel.moveSelection(-1); event.accepted = true; return
      case Qt.Key_PageUp: panel.scrollBy(-0.8); event.accepted = true; return
      case Qt.Key_PageDown: panel.scrollBy(0.8); event.accepted = true; return
      case Qt.Key_Home: panel.jumpEnd(false); event.accepted = true; return
      case Qt.Key_End: panel.jumpEnd(true); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter: panel.activateCurrent(); event.accepted = true; return
      case Qt.Key_Escape: panel.escapeChain(); event.accepted = true; return
      case Qt.Key_Backspace:
      case Qt.Key_Delete:
        if (panel._deleteIndex >= 0) { panel.closeDelete(); event.accepted = true; return }
        if (focusCtrl.mode === "list") { focusCtrl.grabFilter(); event.accepted = true; return }
        break
      case Qt.Key_Space:
        // in list mode, Space activates like Enter (menu parity) except when filtering
        if (focusCtrl.mode === "list" && !searchField.focused) { panel.activateCurrent(); event.accepted = true; return }
        break
    }

    if (!ctrl && !meta && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
      if (focusCtrl.mode === "list") {
        // feed first key to filter, like MenuPanel
        // handle prefix directly so a prefix key does not become plain text
        const pref = AppLauncher.enabledPrefixes
        for (let i = 0; i < pref.length; i++) {
          if (event.text === pref[i]) {
            searchField.text = ""
            AppLauncher.enterMode(pref[i], "")
            focusCtrl.grabFilter()
            event.accepted = true
            return
          }
        }
        // Single write through the field pipeline: type() assigns once and
        // emits one edited() -> submit(), so a press can never edit twice.
        searchField.type(event.text)
        focusCtrl.grabFilter()
        event.accepted = true
        return
      }
    }
  }

  Keys.onPressed: event => panel.handleKey(event)

  Item {
    id: filterBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.hPad
    anchors.rightMargin: panel.hPad
    anchors.topMargin: panel.vPad
    height: Ui.filterH
    // Shared search bar (qs.common.InputField) configured with the launcher
    // preset: row-height box, wide text inset, counter occupying the
    // right slot while visible.
    InputField {
      id: searchField
      anchors.fill: parent
      implicitHeight: Ui.filterH
      basePadding: Ui.l
      focusColor: Ui.solid("accent")
       placeholder: AppLauncher.placeholder
       inputRole: "search"
       clearable: false
       chipActive: AppLauncher.mode !== "normal"

      chipText: AppLauncher.chipLabel
      chipIcon: AppLauncher.chipIcon
      chipColorKey: AppLauncher.chipColorKey
      chipBoxed: AppLauncher.chipBoxed
      prefixes: AppLauncher.enabledPrefixes
      activePrefix: AppLauncher.modePlugin ? String(AppLauncher.modePlugin.keyword ?? "") : ""
      counterVisible: AppLauncher.showCounter
      counterMatched: AppLauncher.matchedCount
      counterTotal: AppLauncher.totalCount
      // The native text control consumes Delete/Ctrl-D before a Keys handler
      // on this wrapper can see them; the field takes them ahead of editing
      // while the current row is removable.
      deleteKeys: panel.deleteKeyAvailable
      onEdited: AppLauncher.submit(searchField.text)
      onAccepted: panel.activateCurrent()
      onEscaped: panel.escapeChain()
      onPrefixEntered: (prefix, payload) => AppLauncher.enterMode(prefix, payload)
      // Only fires with an empty field in filter mode.
      onBackspaceEmpty: panel.backspaceEmptyChain()
      onDeleteRequested: panel.toggleDeleteCurrent()
    }
  }

  // Mode-enter fade: entering a plugin mode fades the row set in place
  // (opacity 0->1, fastMs, OutCubic), no slide: a mode switch has no
  // spatial direction, and the slide read as a submenu push that never
  // lands. The tween starts transparent and masks the binary-list
  // model reset underneath.
  // Arms _modeEnterFade so the deferred row sync landing behind this
  // fade does not start a second opacity tween over it (see
  // _maybeSwapFade): two writers on listBox.opacity read as a jump.
  function playModeEnter() {
    panel._modeEnterFade = true
    modeEnterShift.x = 0
    if (!MotionPolicy.enabled) {
      modeEnterAnim.stop()
      listBox.opacity = 1
      return
    }
    swapFadeAnim.stop()
    modeEnterAnim.restart()
  }

  ParallelAnimation {
    id: modeEnterAnim

    NumberAnimation {
      target: listBox
      property: "opacity"
      from: 0
      to: 1
      duration: Ui.fastMs
      easing.type: Easing.OutCubic
    }
  }

  // Regime-swap fade: app-pool <-> engine-answer flips (any row counts,
  // or a kind switch within single engine answers, e.g. web fallback ->
  // live time row) always reset the model, so delegates rebuild under a
  // flash. Opacity-only, no slide: kind switches have no spatial direction.
  // Callers snap this immediately BEFORE assigning the model in the same
  // block, so the first painted frame already hides the swap and fades back
  // in. Cross-regime callers additionally snap the card edge (see
  // _maybeSwapFade): this tween covers listBox only, not card geometry.
  function playSwapFade() {
    modeEnterAnim.stop()
    modeEnterShift.x = 0
    if (!MotionPolicy.enabled) {
      swapFadeAnim.stop()
      listBox.opacity = 1
      return
    }
    swapFadeAnim.restart()
  }

  NumberAnimation {
    id: swapFadeAnim
    target: listBox
    property: "opacity"
    from: 0
    to: 1
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
  }

  // Backward exit without motion: leaving a plugin mode snaps back to the
  // app list instead of sliding or fading. The rows still install through
  // the deferred sync one turn later - the same path as a filter tick - so
  // the exit reads as instant typing feedback rather than a transition.
  // Arms _modeExitFade so the swap underneath does not start a second fade
  // (see _maybeSwapFade).
  property bool _modeExitFade: false
  property bool _modeEnterFade: false
  function playModeExit() {
    panel._modeExitFade = true
    modeEnterAnim.stop()
    swapFadeAnim.stop()
    modeEnterShift.x = 0
    listBox.opacity = 1
  }

  Item {
    id: listBox
    anchors.top: filterBar.bottom
    anchors.topMargin: Ui.listTopGap
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.hPad
    anchors.rightMargin: panel.hPad
    height: panel.listRegionH
    transform: Translate { id: modeEnterShift; x: 0 }
    Item {
      id: listContent
      anchors.fill: parent
      // Never hidden. A pending fit is a REGION question, not a content one:
      // the rows are already correct and the bar already holds its geometry
      // across the swap (List._holdHighlight), so there is nothing stale on
      // screen to hide. The menu does not do this either; its _fitPending
      // only selects a region height.
      List {
        id: list
        anchors.fill: parent
        interactive: false
        // Plain array model: the view diffs swaps by index, so a filter tick
        // that mints fresh records rebinds each slot in place and drops only
        // the tail - no pooled keyed reuse to leave removed rows visible.
        model: panel._records
        // Never learn row heights while a description or delete slot is
        // open: slot-inflated rows would poison the average (short seats,
        // phantom scroll). Re-measure heals on the next visit after close.
        measureGuard: idx => panel._deleteIndex < 0 && panel._infoIndex < 0
        // Height table keyed by row identity: results are rebuilt wholesale
        // per recompute and re-ranked on every keystroke, so index keys would
        // hand a measured height to whichever row slid into that slot. The
        // key is the record's own `uid` - the same field the guard
        // deduplicates through - so a table entry always describes the row
        // holding it, and keyedRows refuses a set with a missing or repeated
        // key, so the keys are unique by the time they reach here. The
        // separator is the one record with no uid at all: the index
        // fallback answers an absent field, and what it answers cannot be one
        // of the uids, because no producer emits a bare index string.
        rowIdentity: index => String(panel._records[index]?.uid ?? index)
        // Identity epoch for the height table. The panel owns the counter and
        // advances it at the model's one write, and only when the key
        // SEQUENCE changed: a payload-only change (a new calc result, a fresh
        // time string, an icon toggle) keeps the measured heights, while a
        // key-set change advances the epoch and prunes the rows the new key
        // set drops.
        //
        // A COUNTER and not a fingerprint of the key sequence: List requires a
        // revision that never repeats an earlier value, and re-ranking back
        // to a previous key sequence is a real launcher gesture (arrow back
        // through a prefix, or a query that widens and narrows again), which
        // would repeat a fingerprint.
        identityRevision: panel.identityRevision
        // Cursor-row gate (menu parity): the bar snaps only while the
        // focused row stages something (tracks its slot 1:1); a slot left
        // behind must not freeze the bar mid-move.
        highlightMotion: MotionPolicy.enabled && panel._infoIndex !== list.currentIndex
          && panel._deleteIndex !== list.currentIndex
        // Center-lock scrolloff: keyboard steps keep the cursor riding
        // the viewport middle while scrolling is possible (menu parity
        // with MenuPanel/PassPanel). Steps ease while animations run,
        // jump while off.
        centerCursor: true
        smoothScroll: MotionPolicy.enabled
        // Separator rows (clipboard-suggestion divider) never take the
        // keyboard cursor - move()/settle() walk straight past them.
        // Wrap stays on (menu parity: Tab/S-Tab cycle the ends); the
        // big-list teleport in List clamps overshoot so a wrap landing can
        // never strand the cursor below the window.
        isSelectable: i => {
          const r = i >= 0 && i < panel.rows.length ? panel.rows[i] : null
          return !(r && r.kind === "separator")
        }
        trailSpace: 0
        clip: true
        // Instantiation policy lives in List (Ui.listFullRows/listFullBuffer):
        // app pools top out near 100 rows, so every delegate is live and wrap
        // seats land on real geometry. Untouched for big lists.
        autoCache: true
        // The list is the reveal mechanism for open slots in every
        // regime - the card only grows when the slot cannot fit, so
        // pursuit must be able to scroll the open row into view even on
        // short lists. The pursuit timer only runs while a slot is open
        // (autoRevealIndex >= 0).
        autoRevealEnabled: true
        pursuitAnimated: true
        delegate: LauncherEntry { infoOpen: panel._infoIndex >= 0 && panel._infoIndex === index; deleteOpen: panel._deleteIndex >= 0 && panel._deleteIndex === index; deleteStage: panel._deleteIndex >= 0 && panel._deleteIndex === index ? panel._deleteStage : 0; onActivated: () => panel.activateCurrent(); onDeleteConfirm: () => panel.toggleDeleteCurrent() }
      }
    }
    Text {
      anchors.centerIn: parent
      visible: list.count === 0 && AppLauncher.visible
      text: panel.searching ? "No matches" : "Empty"
      color: Ui.tint("foreground_1", 0.4)
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      font.italic: true
      textFormat: Text.PlainText
    }
  }

  readonly property alias input: searchField.input

  function probeFocus() { return focusCtrl.probe() }
}

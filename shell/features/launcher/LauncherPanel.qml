pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.launcher
import qs.features.clipboard
import "LauncherLib.js" as LauncherLib
import "../../common/ui/SlotGrowth.js" as SlotGrowth
import "../../common/ui/PanelKeys.js" as PanelKeys

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
//   backspace      empty field: peel action/info/mode, then de-focus to list;
//                  empty list: close the launcher
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
  // Wide enough for a whole reading ("low Earth orbit speed = 27608.4 km/h")
  // beside the AC that names it; the card still clamps to its screen.
  _maxLabelW: 520
  // The sub line is the ANSWER for every engine row - "low Earth orbit speed
  // is 27608.4 kilometres per hour" - so the card measures it and grows to fit
  // rather than eliding the end of the result. An app row's sub is a
  // description, and following it would size the card to a paragraph, so the
  // policy follows the row set: engine answers fit, the application list does
  // not.
  fitSub: panel._fitsSub
  readonly property bool _fitsSub: {
    const rows = panel.rows || []
    const first = rows[0]
    if (!first) return false
    const k = String(first.kind ?? "")
    return k === "calc" || k === "unit" || k === "constants" || k === "fx"
      || k === "color" || k === "time" || k === "web"
  }

  count: list.count
  contentHeight: list.contentHeight
  // A keystroke is a real resize, so the card glides to its fitted height
  // even inside the show gate. Without this the open's first layout and a
  // filter tick arriving together made the card snap: the resize the user
  // was typing towards landed as a jump.
  sizeMotionDuringGate: AppLauncher.entry !== ""
  property real _latchedListH: -1
  property bool _fitPending: false
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
    // The generation-guarded form of `if (panel.shown) panel.sizeSnap = false`.
    if (panel.shown) panel.setSnap("shown", panel._snapGen)
  }

  Component.onCompleted: { AppLauncher._attachPanel(panel); panel.syncRows(); panel.queueFit() }
  Component.onDestruction: AppLauncher._detachPanel(panel)

  function focusSearch() { focusCtrl.grabFilter() }

  Connections {
    target: AppLauncher
    function onResultsChanged() {
      panel.syncRows()
      if (!panel.searching) panel.recalcWidth()
      panel.closeTrailingInfo()
      panel.closeDelete()
      // Deliberately no queueFit() here. `results` is assigned a turn before
      // the install (syncRows defers it), so a fit armed on this signal sizes
      // the card from rows the view has NOT shown yet - queueFit writes that
      // model height into PanelCard's resting fit, the region moves in this
      // turn, and until the install lands the card's clip edge cuts through a
      // row that is still on screen. The tail of syncRows arms it in the turn
      // the rows actually land (the "model NOW, in the same turn as the rows"
      // contract), and onVisibleChanged/Component.onCompleted cover the open
      // and the cold construction.
    }

    function onVisibleChanged() {
      if (!AppLauncher.visible) {
        panel.closeNotice()
        // A staged delete belongs to the summon that opened it. The
        // results-change path also closes it, but a close need not publish a
        // different row set (idle rows are unchanged) and a quick reopen
        // cancels the close settle before it recomputes, so the confirmation
        // would otherwise greet the next open on a row it may not even name.
        panel.closeDelete()
        // Arm the open-time snap while hidden: the next open's first
        // sizing instant lands in the same turn as the show gate closing,
        // and a Behavior reads the gate's pre-turn value - so a height
        // delta to a new row set (a fresh clipboard suggestion, a changed
        // pool) would glide instead of spawning. Armed here, a turn early,
        // the snap is already in force when the height changes. A fresh
        // generation makes only this open's gate or visible input able to
        // release it; a hidden recompute that republishes rows in between
        // runs the fade path but never touches the arm.
        panel.setSnap("close-arm", ++panel._snapGen)
        return
      }
      // Clears the panel's delete state and the facade's staged row together,
      // so a reload replay that skips the hidden edge cannot carry either in.
      panel.closeDelete()
      // A notice left live by a close that outran its timer would otherwise
      // repaint on the first frame of this open with its remaining time.
      panel.closeNotice()
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
      // typing drives glides like any other. The generation-guarded form of
      // `if (AppLauncher.visible) panel.sizeSnap = false` - guarded on visible
      // so the close-path reset (which runs hidden) cannot disarm the snap
      // the close just armed.
      if (AppLauncher.visible) panel.setSnap("input", panel._snapGen)
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
  // The open-time sizing snap is one labelled state with a single writer.
  // close() mints a fresh arm generation; the gate and visible input release
  // only that generation, so a late release from an older open cannot clear
  // the snap the close just armed for this one.
  property int _snapGen: 0
  property string _snapReason: ""
  function setSnap(reason, gen) {
    if (gen !== panel._snapGen) return
    panel._snapReason = reason
    // Both raw writes live here and nowhere else: close arms the open's
    // first sizing, the gate and visible input release it for typing.
    if (reason === "close-arm") panel.sizeSnap = true
    else panel.sizeSnap = false
  }
  // Open-seat flag: armed on visible open, forces a first-normal
  // seat so a stale cursor never survives a summon.
  property bool _openSeat: false
  // First selectable index that is not a clipboard suggestion. The
  // suggestion row (kind "file" with clip:true) sits above the idle list
  // but must never be the automatic focus on open - see AppLauncher.
  function _firstNormalIndex() {
    for (let i = 0; i < panel._records.length; i++) {
      const r = panel.currentRecord(i)
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
  // Cursor decisions read this array, never panel.rows. A refused install
  // leaves the producer array ahead of the view, so a key action that indexed
  // it would name a record the cursor is not on. panel.rows is producer input
  // to keyedRows() only; every seat and key action resolves its record through
  // currentRecord() on the model the view holds.
  //
  // The live row objects the view shows. The List reads this array
  // directly as its model: ListView diffs array swaps by index, so a filter
  // tick that mints fresh records updates each slot in place and drops only
  // the slots beyond the new end - removed rows never linger visible the way
  // they do under a keyed ScriptModel with pooled reuse. The records reach
  // the delegate whole, as modelData - there is no wrapper role to unwrap.
  property var _records: []
  // The view's row at an index (default: under the cursor). One read behind
  // every cursor decision and every seat: the view holds _records, while
  // panel.rows is producer input that can be ahead of it after a refusal.
  function currentRecord(idx) {
    const i = idx === undefined ? list.currentIndex : idx
    return i >= 0 && i < panel._records.length ? panel._records[i] : null
  }
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

  // LNC-1: one settled-edge waiter replaces the fit poll. queueFit arms a
  // single {fn, guard} waiter; _fitReady is one derivation of the four live
  // signals the fit actually depends on (swap window, slot motion, count,
  // content polish) and its change handler drains the waiter. An attempt
  // counter can no longer be spent by a settle wait before a fit gets its
  // turn: there is no shared budget for the four waits.
  property var _fitWaiters: []
  property int _fitFallbackAttempts: 0

  // The measured fit, read live: fitHeight re-checks the row count, the
  // per-row measured heights and contentHeight, so the derivation tracks all
  // of those edges without a snapshot or a retry.
  function _fitCandidate() { return list.fitHeight(panel.availListH, panel.slotLimit) }

  // 1 = a slot is open or folding (wait for its motion-finished edge),
  // 2 = a slot is open but resting (give up: the region falls back to the
  //     card's resting buffer), 0 = no slot claims the region.
  // Reading each delegate's live motion/heights makes this derivation follow
  // the same edges the old 16 ms poll only sampled.
  function _fitSlotVerdict() {
    const kids = list.contentItem.children
    let resting = false
    for (let i = 0; i < kids.length; i++) {
      const d = kids[i]
      if (!(d instanceof LauncherEntry)) continue
      if (d.slotMotionMs > 0) return 1
      if (d.descSlotH > 0 || d.deleteSlotH > 0) resting = true
    }
    return resting ? 2 : 0
  }

  readonly property bool _fitReady: panel._fitReadyEval()
  function _fitReadyEval() {
    const ws = panel._fitWaiters
    if (ws.length === 0) return false
    const rows = panel.rows || []
    if (rows.length === 0) return true
    if (!ws[0].guard || !ws[0].guard()) return false
    if (list._inSwap) return false
    const verdict = panel._fitSlotVerdict()
    if (verdict === 1) return false
    if (verdict === 2) return true
    if (list.count !== rows.length) return false
    return panel._fitCandidate() >= 0
  }

  on_FitReadyChanged: if (panel._fitReady) panel._drainFit()
  function _drainFit() {
    while (panel._fitWaiters.length > 0 && panel._fitReady) {
      const w = panel._fitWaiters[0]
      // A newer row set retires this fit even if no queueFit landed yet.
      if (w.guard && !w.guard()) {
        panel._fitWaiters = []
        panel._fitPending = false
        return
      }
      // Drop before the callback (MenuPanel._drainSettled shape): a waiter
      // queued by a waiter drains in the same call, before the binding has
      // re-evaluated its guard against the row set the callback installed.
      panel._fitWaiters = panel._fitWaiters.slice(1)
      panel._fitPending = false
      fitFallback.stop()
      w.fn()
    }
  }

  function whenFit(fn, guard) {
    // One waiter, latest rows win: a fit armed for a row set that has since
    // changed is retired here instead of latching a stale height.
    panel._fitWaiters = [{ fn: fn, guard: guard }]
    panel._fitPending = true
    panel._fitFallbackAttempts = 0
    fitFallback.restart()
    // One deferral: install and polish in the same turn, then read the edges.
    // Not a retry - from here the waiter is released by real signals.
    Qt.callLater(panel._drainFit)
  }

  function _fitGiveUp() {
    panel._fitWaiters = []
    panel._fitPending = false
    panel._latchedListH = -1
  }

  function _fitCommit() {
    const rows = panel.rows || []
    if (rows.length === 0) {
      panel._fitGiveUp()
      return
    }
    // Re-read on the release frame: a waiter queued by a waiter can drain
    // before the binding re-evaluated its guard against the installed rows.
    if (panel._fitSlotVerdict() === 2) {
      panel._fitGiveUp()
      return
    }
    const fit = panel._fitCandidate()
    if (fit < 0) {
      panel._fitGiveUp()
      return
    }
    panel._latchedListH = fit
    panel._fitPending = false
    // Settled relatch for the card's resting buffer: this point is reached
    // with no slot in motion, no resting slot heights and the count matched,
    // so the live contentHeight is resting content for the current row set.
    panel._latchRestingBuffer()
  }

  function queueFit() {
    const rows = panel.rows || []
    if (rows.length === 0) {
      panel._fitGiveUp()
      fitFallback.stop()
      return
    }
    // Size from the model NOW, in the same turn as the rows, and let the
    // measured fit correct it when it lands.
    //
    // Without this the card is painted at the PREVIOUS row set's height for
    // as long as the measurement is in flight: PanelCard.restingListH holds
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
    // The guard is not defensive noise: with no resolved ceiling snappedListH
    // answers 0, and PanelCard._latchRestingFit accepts 0 as a measurement
    // (it only refuses a negative one), so an unguarded write pins
    // _restingFitH at 0 and the pending branch hands the card an empty
    // region's height - which is a collapse, not a stale value.
    const model = panel.snappedListH(panel.availListH)
    if (model > 0) panel._latchedListH = model
    whenFit(panel._fitCommit, () => (panel.rows || []) === rows)
  }

  // The only bounded fallback, and it covers one genuinely edgeless case: a
  // row whose delegate is never instantiated, so fitHeight stays negative and
  // no content signal follows to wake the waiter. Every other wait is
  // released by a live edge through _fitReady; this only stops a permanent
  // park when no edge can arrive.
  Timer {
    id: fitFallback

    interval: 16
    repeat: false
    onTriggered: {
      if (panel._fitWaiters.length === 0) return
      panel._drainFit()
      if (panel._fitWaiters.length === 0) return
      if (panel._fitFallbackAttempts < 24) {
        panel._fitFallbackAttempts++
        fitFallback.restart()
        return
      }
      panel._fitGiveUp()
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
    // the fresh one a turn later - the post-open growth. The generation
    // bump below is what really cancels the deferral: its closure captured
    // the previous one and retires on the mismatch instead of reinstalling
    // and settling a second row set over this seat. The open-seat path never
    // calls _maybeSwapFade, so the close-armed snap stays in force.
    if (panel._rowsPending) {
      if (panel._openSeat !== true) return false
      panel._rowsPending = false
    }
    // Both branches own the install from here. Mint the generation before
    // either beginSwap so a deferred syncRows from the hidden recompute is
    // retired by the same counter its own live check reads.
    panel._swapGen++
    // Open seat: never reuse the cursor, install with zeroed durations,
    // first-normal selection, origin scroll. The diff keeps the delegates
    // a previous summon already built, which is the table the List would
    // otherwise re-measure from nothing.
    if (panel._openSeat === true) {
      panel._openSeat = false
      list.beginSwap()
      panel.installRows()
      // Seat from the model that was just installed: a refusal left the old
      // set in the view, and that is the set the cursor has to name.
      const openIdx = panel._firstNormalIndex()
      list.seat(openIdx >= 0 ? openIdx : -1, "land")
      list.seatTo(0, false, "launcher-open")
      list.endSwap()
      return true
    }
    // Durations are zeroed around the install either way so the seat never
    // glides, and an identical row set needs no separate skip: the model's
    // `values` reassignment is the diff and a re-rank that keeps the key
    // sequence advances no epoch. Regime flips mask the rebuild flash (see
    // _maybeSwapFade).
    panel._maybeSwapFade()
    list.beginSwap()
    panel.installRows()
    // Read the seat from the installed model, not the pending producer rows.
    const idx = panel._firstNormalIndex()
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
    // Glide enablement belongs to PanelCard: its size Behaviors run when
    // `shown || sizeMotionDuringGate`, so a regime flip while visible keeps
    // gliding without a write here. This same path runs from a hidden sync
    // after close (a recompute republishing rows), where writing the snap
    // would disarm the open's first sizing - leave the arm to its own gate.
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
    // Captured at schedule time, not read at fire time: the open seat (or a
    // newer sync) can bump _swapGen in between, and this deferred install
    // must retire instead of settling a second row set over the seat.
    const scheduledGen = panel._swapGen
    Qt.callLater(() => {
      if (scheduledGen !== panel._swapGen) return
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
      if (clipHeaded) {
        // Clipboard suggestion heads the list: rest at the top without
        // fighting centerCursor. settle(idx, true) snaps instantly with
        // no pin vs pursuit fight and no negative overshoot.
        list.swapRun(g, v => v === panel._swapGen, () => {
          panel._maybeSwapFade()
          panel.installRows()
          // The seat names the row the view now holds, even if the install
          // was refused and this is the previous set.
          const idx = panel._firstNormalIndex()
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
          const idx = panel._firstNormalIndex()
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
  function moveSelection(direction, autoRepeat) {
    const prev = panel.currentRow()
    // A held key re-arms the follow before the last leg can land. Passing the
    // repeat through lets List take one short leg with the bar, so the cursor
    // stays pinned to the viewport centre while the rows slide through it
    // (menu parity - without this the bar drifts off centre on a fast hold).
    if (!list.move(direction, undefined, autoRepeat === true)) return
    if (prev && panel.currentRow() !== prev) panel.closeTrailingInfo()
  }

  property int _infoIndex: -1
  function toggleInfoCurrent() {
    const idx = list.currentIndex
    const rec = panel.currentRecord()
    if (!rec || rec.desc === "") return
    _infoIndex = _infoIndex === idx ? -1 : idx
    list.autoRevealIndex = _infoIndex
  }

  // Whether the current row is one the delete flow may act on. The search
  // field arms its destructive keys from this, so with nothing removable under
  // the cursor Delete keeps editing the query instead of being swallowed.
  readonly property bool deleteKeyAvailable: {
    const rec = panel.currentRecord()
    return !!rec && rec.kind === "app" && rec.removable === true
  }

  // The row uses this to decide whether the refused-delete notice covers the
  // inline description or the title. Same key the controller reads to put
  // the description in `sub` versus the expandable `desc` slot.
  readonly property bool showDescriptions: Settings.value("shell.launcher.showDescriptions") === true

  // A refused Delete still gets an answer: the row at this index shows a red
  // "not deletable" notice for 1.5s. The notice owns its state and timers here
  // in the resident panel rather than in a delegate, so a close can clear it
  // before the next summon paints - a delegate reused across opens kept the
  // notice and its remaining time alive otherwise.
  property int _noticeIndex: -1
  property bool _noticeOn: false
  property bool _noticeMotion: false

  function flashNotDeletable(idx) {
    // Arm motion before the text changes: SlideSwap reads `duration` in the
    // same turn its `text` flips, so setting _noticeOn first would snap the
    // notice in and only animate its return.
    panel._noticeMotion = true
    panel._noticeIndex = idx
    panel._noticeOn = true
    noticeTimer.restart()
  }
  function closeNotice() {
    noticeTimer.stop()
    noticeMotionTimer.stop()
    panel._noticeIndex = -1
    panel._noticeOn = false
    panel._noticeMotion = false
  }

  Timer {
    id: noticeTimer
    interval: 1500
    onTriggered: {
      panel._noticeOn = false
      // Keep motion armed through the return swap, then release it.
      noticeMotionTimer.restart()
    }
  }
  Timer {
    id: noticeMotionTimer
    interval: Ui.normalMs + 40
    onTriggered: panel._noticeMotion = false
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
      if (_deleteStage === 1) AppLauncher.requestDelete(panel.currentRecord())
      list.autoRevealIndex = idx
      return
    }
    // Fresh open.
    const rec = panel.currentRecord()
    if (rec && rec.removable === true) {
      _deleteIndex = idx
      _deleteStage = 1
      AppLauncher.requestDelete(rec)
      list.autoRevealIndex = idx
      return
    }
    // A regular app has no delete to arm. Say so in the row rather than
    // swallowing the key into a no-op the user cannot distinguish from a
    // dropped keypress.
    if (rec && rec.kind === "app") panel.flashNotDeletable(idx)
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
    const rec = panel.currentRecord()
    if (!rec) {
      const fb = panel._firstNormalIndex()
      if (fb >= 0) list.settle(fb, true)
      else if (panel._records.length > 0) list.seat(-1, "land")
      return
    }
    AppLauncher.activate(rec)
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
  // query and hand the caret to the field. Pasted text is a query the user
  // means to keep editing, so leaving the list in charge would drop it on the
  // next keystroke - that press types into a field the query never reached.
  // Text comes from the resident Clipboard singleton (the same history the
  // controller subscribes to) instead of a wl-paste child -> no spawn per
  // paste; InputField owns the flavor rule and the single-line folding.
  function pasteIntoSearch() {
    if (!searchField.pasteText(Clipboard.history)) return
    focusCtrl.grabFilter()
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const meta = event.modifiers & Qt.MetaModifier

    // Ctrl-V with an inactive search box: paste the clipboard into the
    // query and take the caret. With the field focused, TextInput's native
    // paste consumes the key before it ever reaches here.
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

    switch (PanelKeys.route(k, Qt, focusCtrl.mode === "list", searchField.focused)) {
      case "next":
        // A staged delete owns Down/Tab: Tab closes it and moves, Down is
        // refused so the row under the cursor cannot slip away mid-confirm.
        if (panel._deleteIndex >= 0) {
          if (k !== Qt.Key_Tab) break
          panel.closeDelete()
        }
        panel.moveSelection(1, event.isAutoRepeat === true); event.accepted = true; return
      case "prev":
        if (panel._deleteIndex >= 0) {
          if (k !== Qt.Key_Backtab) break
          panel.closeDelete()
        }
        panel.moveSelection(-1, event.isAutoRepeat === true); event.accepted = true; return
      case "pageUp": panel.scrollBy(-0.8); event.accepted = true; return
      case "pageDown": panel.scrollBy(0.8); event.accepted = true; return
      case "first": panel.jumpEnd(false); event.accepted = true; return
      case "last": panel.jumpEnd(true); event.accepted = true; return
      case "activate": panel.activateCurrent(); event.accepted = true; return
      case "escape": panel.escapeChain(); event.accepted = true; return
      case "back":
        if (panel._deleteIndex >= 0) { panel.closeDelete(); event.accepted = true; return }
        if (focusCtrl.mode === "list") {
          // An empty field in list mode has nothing left to hand back to: taking
          // the field again would only bounce to the empty-field chain and loop.
          // Close the surface instead. A query still goes to the field, where a
          // native Backspace trims it one character at a time.
          if (searchField.text !== "") focusCtrl.grabFilter()
          else AppLauncher.close()
          event.accepted = true
          return
        }
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
        // with MenuPanel). Steps ease while animations run,
        // jump while off.
        smoothScroll: MotionPolicy.enabled
        // Separator rows (clipboard-suggestion divider) never take the
        // keyboard cursor - move()/settle() walk straight past them.
        // Wrap stays on (menu parity: Tab/S-Tab cycle the ends); the
        // big-list teleport in List clamps overshoot so a wrap landing can
        // never strand the cursor below the window.
        isSelectable: i => {
          const r = panel.currentRecord(i)
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
        delegate: LauncherEntry {
          infoOpen: panel._infoIndex >= 0 && panel._infoIndex === index
          deleteOpen: panel._deleteIndex >= 0 && panel._deleteIndex === index
          deleteStage: panel._deleteIndex >= 0 && panel._deleteIndex === index ? panel._deleteStage : 0
          showDescriptions: panel.showDescriptions
          noticeTarget: panel._noticeIndex >= 0 && panel._noticeIndex === index
          noticeOn: panel._noticeOn
          noticeMotion: panel._noticeMotion
        }
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

  PointerGuard {}
}

pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.clipboard

// Clipboard card - two-pane layout: list on left, preview on right.
// Declarative via PanelCard + PanelFocus; a six-row window at rest.
PanelCard {
  id: panel

  maxHeight: 520
  hardMaxHeight: 800
  // The compact window, in the shared vocabulary: six rows at rest and the
  // rest under scroll. A CAP on the shared fit, not a substitute for it - the
  // region's own sum decides how many of the six actually fit, and the ones
  // that do not go under scroll like every other row on every other card.
  rowLimit: 6
  outerPad: Ui.outerPad
  filterH: Ui.filterH
  listTopGap: Ui.listTopGap
  emptyMinH: Ui.emptyMinH
  count: list.count
  contentHeight: list.contentHeight
  rows: panel._records
  // The gap between rows is the LIST's, read rather than assumed: the card
  // sums the same gap the list places, and a literal in the card would put
  // the region's bottom edge off the row boundary the day a surface spaced
  // its rows differently.
  rowSpacing: list.spacing
  // Every entry on this surface is one row shape, so the card is told what
  // that shape is instead of guessing. The row records carry `title` and
  // `subLeft`, not the `label`/`sub` the shared vocabulary reads, and a row
  // the vocabulary cannot read measures as an empty one - 34px
  // against a real 47, which is a plausible lie rather than a visible
  // failure. Stated here, the measured two-line row this panel already
  // uses for its own readout answers for every row.
  rowHeightFn: (row) => panel.rowH
  // No in-flow slots on this surface, so nothing ever asks the card to
  // grow: no slot is open, so the resting region stands and no override is
  // offered. (Forwarding the list's raw claim would be wrong here: this
  // surface never had one - see PanelCard.slotRegionH.)
  slotOpen: false
  slotRegionH: -1

  // The window's box, owned by the shared two-pane metrics so this card and
  // the wallpaper picker are the same size by construction rather than by two
  // matching sets of arithmetic. Nothing below reads the selection, the row
  // count or the entry type: a window that moves as you arrow through entries
  // drags the pane out from under the thing being read.
  TwoPaneMetrics { id: metrics }
  // The card's own box, pinned to the metrics box on purpose. PanelCard sizes
  // itself from the row set, and a surface whose whole job is holding two
  // panes side by side must not resize as the selection changes - a window
  // that reflows under a reading pane moves the thing being read. So `width`
  // and `height` are stated here instead of inherited, and the row set drives
  // nothing about this window's size. `boxW` is written once because both the
  // card's base and its own cap need the same number.
  readonly property int boxW: metrics.totalW + 2 * panel.outerPad
  baseWidth: panel.boxW
  width: Math.min(panel.boxW, parent ? parent.width - 64 : metrics.totalW)
  height: Math.min(panel.regionChromeH + metrics.contentH, panel.hardMaxHeight)

  readonly property bool searching: Clipboard.query !== ""
  // Dead filter: the viewed source holds nothing to query - normal view
  // reads normalCount, pinned view reads pinnedCount. Both empty means
  // dead in both views; a pinned view with nothing pinned is dead too.
  readonly property bool filterDead: Clipboard.showPinned
    ? Clipboard.pinnedCount === 0 : Clipboard.normalCount === 0

  // This panel's own row: a title and the timestamp line, which renders
  // whether or not there is a sub, so every entry is two lines and a bare
  // title is exactly as tall as a titled one. Measured from the fonts through
  // the shared probe rather than off the list - a reading of whichever
  // delegates happen to be instantiated is a function of scroll position, slot
  // state and model churn, and a probe of one row multiplied by six stops
  // being a row boundary the moment a row grows anything at all.
  //
  // The measurement is the two-pane metrics' own: this row shape IS the
  // shape that budget sizes the window from, so a second probe of the same
  // two strings would be a second answer to a question the window is already
  // answering, and the two caches would drift the moment the probe string
  // changed. `rowHeightFn` above and the region's own sum read this one.
  readonly property real rowH: metrics.rowH

  readonly property bool primarySurface: visible

  // The panel tree attaching is the panel becoming reachable: `_attachPanel` is
  // what lets `status()` answer and what routes post-delete selection repair
  // back to a live panel.
  Component.onCompleted: {
    Clipboard._attachPanel(panel)
    panel.syncRows()
  }
  Component.onDestruction: Clipboard._detachPanel(panel)
  TapHandler { onTapped: focusCtrl.grabFilter() }

  Connections {
    target: Clipboard
    function onFilteredChanged() {
      if (panel.pendingDeleteIndex >= 0 || panel._deleteInFlight) {
        panel.syncRows(true)
      } else if (panel.filteredKeys() === panel._lastSeq) {
        // Same key set: a landed probe reinstalled payloads, not
        // membership. Keep the seat instead of settling to the top.
        panel.syncRows(true)
      } else {
        panel.syncRows(false)
      }
    }
    function onVisibleChanged() {
      if (!Clipboard.visible) {
        panel._openSeat = false
        return
      }
      panel._openSeat = true
      panel.show()
      searchField.text = ""
      focusCtrl.grabList()
      // Fresh summon parks at the top: the panel instance outlives close,
      // so a stale contentY/currentIndex would greet the next open.
      list.settle(0, true)
      list.seatTo(0, false, "clipboard-open")
      // The preview lands with no fade: it is already showing whatever it
      // shows, and fading on open reads as an empty pane that fills late.
      // Fades belong to entry switches, which _stage still performs.
      preview.snapOpen()
      Qt.callLater(() => { if (panel._openSeat) panel._openSeat = false })
    }
    function onModeChanged() {
      Qt.callLater(focusCtrl.reassert)
    }
  }

  function syncRows(keepIndex) {
    // Row identity shifts on any model change - an open confirm dropdown
    // must not survive it.
    panel.closeDelete()
    // Model swaps recreate delegates and reset currentIndex: land the
    // sliding bar instantly, then re-arm the glide for pure focus
    // moves (MenuPanel bottom-flicker parity).
    panel._swapGen++
    const g = panel._swapGen
    const prev = list.currentIndex
    const openSeat = panel._openSeat === true
    list.swapRun(g, v => v === panel._swapGen, () => {
      // Pin the bar before the model write, while the cursor still stands
      // on the row the user was looking at. A tail delete (the focused
      // last entry going away) is the one removal no survivor row moves
      // for, so the repair seat below is the only motion the user sees -
      // while the swap deals an index adjustment of its own a frame after
      // this window closes, parking the cursor, and a bar that followed
      // it, on row 0 until the commit re-asserts the target. Pinned to the
      // place the user left the bar, it stands there instead of taking a
      // lap of the list, and a settle that holds the view still gives
      // the bar no travel at all. The target is only known after
      // installRows (see the count below), so a seat that is not the tail
      // repair drops the pin again in the same turn.
      if (keepIndex === true && prev >= 0) list.pinHighlight()
      // The tail settle claims the freed row's space BEFORE the write, so
      // the write itself changes nothing about the content's extent: the
      // view does not move, the scroll range does not change under the
      // finger, and the space is given back when the settle ends.
      panel._claimSettle()
      panel.installRows()
      if (openSeat) {
        list.unpinHighlight()
        list.settle(0, true)
        list.seatTo(0, false, "clipboard-open")
        panel._openSeat = false
      } else if (keepIndex === true && prev >= 0) {
        const n = panel.rows.length
        const target = n === 0 ? -1 : Math.min(prev, n - 1)
        // Repair seats land: the stillness lease holds the bar across
        // the reflow instead of gliding it from the swap's reset position
        // at the top of the list. A tail delete has no reflow to hold for,
        // so its bar stays pinned and is released at the commit, which is
        // where the one leg it owes is seated (see onDeleteCommitted).
        const tailDelete = panel.pendingDeleteIndex >= 0
          && panel.pendingDeleteIndex >= n
        if (!tailDelete) list.unpinHighlight()
        if (target >= 0) {
          list.seat(target, "land")
        } else {
          list.seat(-1, "land")
        }
        panel._pendingRepairGen = g
        panel._pendingRepairTarget = target
      } else {
        list.unpinHighlight()
        list.settle(0, true)
      }
    })
    Qt.callLater(focusCtrl.reassert)
  }

  // The source emptied under an open panel: drop a stale query - but
  // only when one is pending, because clearQuery also exits pinned
  // mode on an empty query, which would eject an explicit visit to an
  // empty pinned view - and park the focus back in the list. A
  // filter-mode keyboard with an unfocused field goes nowhere (see
  // PanelFocus.grabFilter), so the mode must come along, which
  // grabList does.
  onFilterDeadChanged: {
    if (!panel.filterDead) return
    searchField.text = ""
    if (Clipboard.query !== "") Clipboard.clearQuery()
    focusCtrl.grabList()
  }

  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: Clipboard.visible
  }
  readonly property alias input: searchField.input
  property alias mode: focusCtrl.mode
  function grabList() { focusCtrl.grabList() }
  function grabFilter() { focusCtrl.grabFilter() }
  function reassertFocus() { focusCtrl.reassert() }
  function focusSearch() { focusCtrl.grabFilter() }

  function currentRow() { return list.currentItem }
  function moveSelection(dir) {
    if (!list.move(dir)) return
    // Leaving the armed row closes its confirm dropdown.
    if (panel._deleteIndex >= 0 && panel._deleteIndex !== list.currentIndex) panel.closeDelete()
  }

  function scrollBy(factor) { list.pageBy(factor) }
  function jumpEnd(last) { list.jumpEnd(last) }

  function activateCurrent() {
    // Open confirm takes precedence over activation, like the launcher.
    // Only the armed row itself confirms; landing on another row (click)
    // just closes the dropdown.
    if (panel._deleteIndex >= 0) {
      if (list.currentIndex === panel._deleteIndex) { panel.acceptDelete(); return }
      panel.closeDelete()
    }
    let idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) {
      if (panel.rows.length === 0) return
      idx = 0
      list.settle(0, true)
    }
    // Pending-delete rows stay visible but inert: no copy, no pin.
    const row = panel.rows[idx]
    if (row && Clipboard.optimistic.isPending(row.id)) return
    // A row already flagged missing opens nothing: Enter arms the same
    // staged delete confirm a pinned row gets, instead of re-probing.
    if (row && row.missing === true) { panel.stageDeleteAt(idx); return }
    Clipboard.activateAt(idx)
  }
  function togglePinCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) return
    const row = panel.rows[idx]
    if (row && Clipboard.optimistic.isPending(row.id)) return
    Clipboard.togglePinAt(idx)
  }
  // Deletion is buffered in the service; remember where the request came
  // from so selection can be repaired once the commit lands.
  property int pendingDeleteIndex: -1
  property bool _deleteInFlight: false
  property int _pendingRepairGen: -1
  property int _pendingRepairTarget: -1
  // Three-step confirm state for pinned rows: hint -> armed -> confirm.
  property int _deleteIndex: -1
  property int _deleteStage: 0
  // Model-swap generation: re-arms restore the glide only for the
  // latest swap (see syncRows).
  property int _swapGen: 0
  property bool _openSeat: false
  // The record array the model shows. installRows is its only writer - one
  // path, nothing behind it - and the List reads it directly. The records
  // are the service's own entry objects rather than copies of them.
  property var _records: []
  // Clipboard rows keyed on the record id for the height table and the
  // guard. The service assigns that id once and never reuses it. The view
  // diffs array swaps by index: fresh records rebind each slot in place and
  // only the tail beyond the new end leaves - no keyed pooled reuse to leave
  // removed rows visible in one slot. The records reach the delegate whole,
  // as modelData: there is no wrapper role to unwrap.
  // Identity epoch for the height table. A plain array reports neither a
  // revision nor a key-set flag, so the panel owns the counter: installRows
  // folds the key sequence into _lastSeq, and every sequence that differs
  // from the last one advances the epoch. A counter and not the sequence
  // itself, because a sequence returns to an earlier value when rows are
  // reordered back and the epoch must never repeat one (List.qml:329).
  // Advanced from the model's single write site rather than from a binding
  // over the value it reads: that is a loop, and the engine reports one on
  // every pass.
  property int _epoch: 0
  property var _lastSeq: ""
  readonly property int identityRevision: panel._epoch
  // The key sequence the model showed before the current sync, kept for
  // the delete reflow alone: the rows a removal pushed up are found by
  // diffing the two sequences (see armSlideFrom).
  property var _prevKeys: []
  property string _modelError: ""

  // The row set this panel's own guard accepts. Two live rows on one
  // record id is the failure List.qml cannot absorb, because it refuses to
  // measure either of them and the height table degrades with nothing
  // anywhere saying why - so the guard stays here.
  function keyedRows() {
    const src = Clipboard.filtered
    if (!Array.isArray(src)) { panel._modelError = "not_array"; return null }
    const rows = new Array(src.length)
    const seen = Object.create(null)
    for (let i = 0; i < src.length; i++) {
      const rec = src[i]
      if (!rec || rec.id === undefined || rec.id === null) {
        panel._modelError = "invalid_row"
        return null
      }
      const key = String(rec.id)
      if (key.trim() === "") { panel._modelError = "missing_key"; return null }
      if (seen[key] !== undefined) { panel._modelError = "duplicate_key"; return null }
      seen[key] = true
      rows[i] = rec
    }
    return rows
  }

  // Key sequence of the live filtered set, folded exactly like installRows
  // folds the installed one: equal sequences mean a payload-only
  // reinstall (a landed probe), which keeps its seat.
  function filteredKeys() {
    const src = Clipboard.filtered
    if (!Array.isArray(src)) return ""
    const keys = new Array(src.length)
    for (let i = 0; i < src.length; i++) {
      const rec = src[i]
      keys[i] = String(rec && rec.id !== undefined && rec.id !== null ? rec.id : "?")
    }
    return keys.join("\u0000")
  }

  function installRows() {
    const rows = panel.keyedRows()
    // A refused set writes nothing at all: the previous rows stay on screen
    // until a set that passes arrives.
    if (rows === null) return
    panel._modelError = ""
    const prev = panel._prevKeys
    // The model's single write: the view reads panel._records directly.
    panel._records = rows
    // The identity epoch, advanced here and nowhere else: this is the model's
    // one write, so it is the only place a new key sequence can appear. The
    // sequence is folded from the QML array this panel owns. NUL separates
    // the keys and a record id is a number
    // or its decimal string, so the join cannot forge a boundary between two
    // rows.
    const keys = rows.map(r => String(r.id))
    const seq = keys.join("\u0000")
    if (seq !== panel._lastSeq) {
      panel._lastSeq = seq
      panel._epoch++
    }
    panel._prevKeys = keys
    panel.armSlideFrom(prev, keys)
  }

  function closeDelete() {
    _deleteIndex = -1
    _deleteStage = 0
    list.autoRevealIndex = -1
  }
  // Post-delete reflow: rows below the removed one slide up into the
  // vacated position. A keyed removal reuses every surviving delegate,
  // so no delegate is born to arm itself - the panel arms the shifted
  // rows straight from the rows that left (see armSlideFrom), and the
  // armed state must be ready before the commit lands.
  property real _slideOffset: 0
  property string _slideMode: "normal"
  property int _slideGen: -1
  function _armSlide(from) {
    // The row's height AS IT STANDS, and that is the whole reason this reads a
    // delegate instead of the constant: the caller arms the reflow BEFORE it
    // closes the confirm slot, so a live row is still carrying the expanded
    // height and the rows below have to move by that much or the space the
    // removed row leaves is never taken up. The resting row height is the
    // fallback for a row that is not instantiated, where there is no open
    // slot to account for either. (It is not
    // PanelCard.rowRestHeight: these records carry `title`, not `label`, so
    // the shared text probe floors it at rowMinH.)
    const it = list.itemAtIndex(from)
    _slideOffset = (it ? it.height : panel.rowH) + list.spacing
    _slideMode = Clipboard.mode
    _slideGen = panel._swapGen + 1
  }
  // --- the tail settle ---
  //
  // Deleting the LAST entry of a scrolled list is the one removal the
  // view cannot absorb for free: the row that leaves is the one the
  // view stands on, so the content loses exactly the space the view was
  // resting on and the bound comes down by a whole row. The correction
  // is instant - the content cannot hold a stale extent and the bound
  // IS the bound - so the list jumps a row and the highlight bar goes
  // with it.
  //
  // The settle gives that space back over the panel's motion budget
  // instead of all at once. The list holds it through the write, so the
  // write changes nothing about the content's extent, and gives it back
  // afterwards, so the content shrinks by exactly the row that left
  // while the view rides it down: the rows settle into the freed space,
  // the scroll range closes with them, and the bar - which the swap
  // pinned to the place the user left it - stands still throughout.
  // The mechanics live in the list (see List.claimSettle); this is the
  // half that knows when a removal settles.
  //
  // The space is the removed row's own slot: its height plus the gap
  // below it, which is the same number the reflow arms the rows below
  // the cut with (see _armSlide).
  property real _settleSpace: 0
  function _armSettle(idx) {
    panel._settleSpace = 0
    // Only the last row settles: any other removal leaves the content's
    // extent short by a row ABOVE the view, which costs the view nothing.
    if (idx !== list.count - 1) return
    // Only a list with room to scroll settles. A list that fits has no
    // bottom to stand on, and the space the settle would hold would
    // make a list that did not scroll scroll.
    const bottom = list.clampY(Infinity)
    if (bottom <= 0) return
    // Only a view that stands ON the bottom settles: anywhere else the
    // content loses space the view was not using and the bound does not
    // move under it.
    if (list.contentY < bottom - 0.5) return
    panel._settleSpace = panel._slideOffset
  }
  // The write claims the space: the list holds it through the write, so
  // the content's extent is unchanged by it and the view does not move.
  function _claimSettle() {
    if (panel._settleSpace <= 0) return
    list.claimSettle(panel._settleSpace)
    panel._settleSpace = 0
  }
  // The affected set comes from the rows that left between the previous sync
  // and this one. A single array assignment carries no operation report,
  // so the two key sequences answer the same question. A row is "gone"
  // exactly when
  // the previous set held its id and the new one does not, and walking the
  // previous sequence from index 0 makes the first such row the LOWEST
  // removed index. A removal is the only way a previous key can disappear,
  // so the first such row IS the lowest removed one; a set that only reorders
  // or grows drops nothing and arms nothing.
  // Every row below the cut moved up by the removal. Arming walks the
  // PRE-change slots from `from` to the old end: the survivors below the
  // cut live there whether or not the view has processed the removal yet.
  // A post-change lookup (`from..n-1`) races the relayout - the trailing
  // instance it finds is the row being released, so the arm lands on a
  // dying delegate and the real last entry teleports. Pre-change slots
  // are valid on both sides of that race: afterwards, the overhang lookup
  // simply misses (null) and the doomed instance's own arm dies with it.
  // A set that only reorders or grows drops nothing, so nothing is armed
  // for it. The filler skeletons below the list glide with the same
  // offset: they ride contentHeight, which lands instantly, so without
  // their own arm they teleport while the rows ease.
  function armSlideFrom(prevKeys, nextKeys) {
    if (panel.pendingDeleteIndex < 0) return
    // The mode guard skips the slide when the commit also flipped the
    // list (the last pinned row leaving @ mode reshuffles everything);
    // the generation guard skips stale offsets from a prior delete.
    if (panel._slideMode !== Clipboard.mode) return
    if (panel._slideGen !== panel._swapGen) return
    const live = Object.create(null)
    for (let i = 0; i < nextKeys.length; i++) live[nextKeys[i]] = true
    let from = -1
    for (let i = 0; i < prevKeys.length; i++) {
      if (live[prevKeys[i]] !== true) { from = i; break }
    }
    if (from < 0) return
    // Rows that did not move are never armed: the head above the cut keeps
    // its slots, and removing the last row moves no survivor at all (the
    // loop below then arms only the released instance, harmlessly).
    for (let i = from; i < prevKeys.length; i++) {
      const it = list.itemAtIndex(i)
      if (it && typeof it.armSlide === "function") it.armSlide(panel._slideOffset)
    }
    skeletonBox.armSlide(panel._slideOffset)
  }
  // The three stages a removal passes through, named. Which stage a press landed
  // on is the difference between "nothing happened" and "it is waiting for a
  // second press", and the panel gives no other signal for the middle stage.
  function fastDelete(idx) {
    const row = panel.rows[idx]
    if (!row || Clipboard.optimistic.isPending(row.id)) return
    panel._armSlide(idx)
    panel._armSettle(idx)
    pendingDeleteIndex = idx
    panel._deleteInFlight = true
    Clipboard.requestDelete(row.id)
  }
  // Delete/Ctrl+D entry point: pinned rows are deliberate, so they get
  // the staged confirm; unpinned rows keep the fast single-press delete.
  function deleteCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) return
    const row = panel.rows[idx]
    if (!row || Clipboard.optimistic.isPending(row.id)) return
    if (row.pinned === true) { panel.toggleDeleteCurrent(); return }
    panel.fastDelete(idx)
  }
  // The staged confirm exists because a PINNED row is deliberate: one press must
  // not delete it. So the first press only arms, and a user pressing Delete once
  // and seeing nothing happen needs to be able to read that the row armed rather
  // than the press having been lost.
  function toggleDeleteCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) {
      panel.closeDelete()
      return
    }
    const row = panel.rows[idx]
    if (!row || row.pinned !== true) {
      panel.closeDelete()
      return
    }
    panel.stageDeleteAt(idx)
  }
  // One staging body for every path that arms the confirm: the Delete key
  // on pinned rows, and Enter on rows already flagged missing. Same
  // hint -> armed -> confirm either way.
  function stageDeleteAt(idx) {
    if (panel._deleteIndex === idx) {
      if (panel._deleteStage >= 2) {
        panel.acceptDelete()
        return
      }
      panel._deleteStage++
      list.autoRevealIndex = idx
      return
    }
    panel._deleteIndex = idx
    panel._deleteStage = 1
    list.autoRevealIndex = idx
  }
  function acceptDelete() {
    const idx = panel._deleteIndex
    const row = idx >= 0 && idx < panel.rows.length ? panel.rows[idx] : null
    if (row) panel._armSlide(idx)
    if (row) panel._armSettle(idx)
    panel.closeDelete()
    if (!row || Clipboard.optimistic.isPending(row.id)) return
    pendingDeleteIndex = idx
    panel._deleteInFlight = true
    Clipboard.requestDelete(row.id)
  }
  // Runs after the service committed the removal. syncRows(true) already
  // landed on the same target while the gate was held - a second write
  // is the flicker, so this is a no-op safety net only.
  function onDeleteCommitted(id) {
    const from = panel.pendingDeleteIndex
    panel.pendingDeleteIndex = -1
    panel._deleteInFlight = false
    if (from < 0) { list.unpinHighlight(); return }
    // If syncRows(true) already landed on the same target while the
    // gate was held - a second write is the flicker - do nothing.
    const n = panel.rows.length
    const want = n === 0 ? -1 : Math.min(from, n - 1)
    if (list.currentIndex !== want) {
      // Else land through the classified seat: the lease holds the bar
      // still across the reflow, with observed release.
      if (want >= 0) list.seat(want, "land")
      else list.seat(-1, "land")
    }
    // A tail delete in a long list ends fully scrolled to the new last
    // row: the swap-turn follow seats before the new delegates are laid
    // out, so it parks on stale geometry. Re-reveal once the commit has
    // landed and the layout is real; a row already in view holds still.
    // A lease held here would snap the highlight bar instead of easing it,
    // so release it first.
    //
    // A settle is standing: the view never left the bottom, because the
    // content kept its extent through the write, so there is nothing to
    // re-reveal - and the lease must stay held, because the bar is pinned
    // and a re-armed duration would make it lag the view down the settle.
    if (from >= n && want >= 0 && !list.settling) {
      list._stillPreempt()
      list.reveal(want, false)
    }
    // The settle ends here: the space the removed row stood in goes back
    // and the content closes over it.
    list.releaseSettle()
    // The tail delete's one leg, seated here: the bar is still pinned to
    // the place the user left it, and unpinning hands it to live cursor
    // geometry, which the seat above has already put on the new last
    // entry. A list that does not scroll hands the bar one eased row of
    // travel from where the user was to where the focus went; a settle
    // that held the view still has already brought the focus under the
    // bar, and the handover is not a move at all. Released on every path
    // out of here, so a pin can never outlive its commit - and a standing
    // settle holds the release, because the live row is not where the bar
    // stands until the view has ridden the freed space down (the list
    // releases the pin when the settle lands).
    list.unpinHighlight()
  }
  // The destructive one, and the one a mis-press is unrecoverable from.
  function clearAll() { Clipboard.clearAll() }

  // Escape is a ladder: each rung consumes it, and only the last one closes the
  // panel.
  function escapeChain() {
    // The open confirm is modal: Escape cancels it before anything else.
    if (panel._deleteIndex >= 0) {
      panel.closeDelete()
      return
    }
    if (Clipboard.query !== "") {
      Clipboard.clearQuery()
      searchField.text = ""
      return
    }
    if (focusCtrl.mode === "filter" || searchField.focused) {
      focusCtrl.grabList()
      return
    }
    if (Clipboard.mode === "pinned") {
      Clipboard.exitPinned()
      return
    }
    Clipboard.close()
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const shift = event.modifiers & Qt.ShiftModifier
    const meta = event.modifiers & Qt.MetaModifier
    const alt = event.modifiers & Qt.AltModifier

    // Ctrl-J/K scroll only the preview pane text; the list cursor never
    // moves from this branch. Requires list focus so filter typing and
    // text editing are untouched.
    if (ctrl && focusCtrl.mode === "list" && !searchField.focused) {
      if (k === Qt.Key_J) { preview.scrollText(40); event.accepted = true; return }
      if (k === Qt.Key_K) { preview.scrollText(-40); event.accepted = true; return }
    }

    if (k === Qt.Key_P && ctrl && focusCtrl.mode === "list" && !searchField.focused) { panel.togglePinCurrent(); event.accepted = true; return }

    if ((k === Qt.Key_D && ctrl && focusCtrl.mode === "list" && !searchField.focused) || k === Qt.Key_Delete) {
      if (shift) { panel.clearAll(); event.accepted = true; return }
      panel.deleteCurrent(); event.accepted = true; return
    }

    if (k === Qt.Key_F && ctrl) { focusCtrl.grabFilter(); event.accepted = true; return }

    switch (k) {
      case Qt.Key_Down:
      case Qt.Key_Tab:
        panel.moveSelection(1); event.accepted = true; return
      case Qt.Key_Up:
      case Qt.Key_Backtab:
        panel.moveSelection(-1); event.accepted = true; return
      case Qt.Key_PageUp: panel.scrollBy(-0.8); event.accepted = true; return
      case Qt.Key_PageDown: panel.scrollBy(0.8); event.accepted = true; return
      case Qt.Key_Home: panel.jumpEnd(false); event.accepted = true; return
      case Qt.Key_End: panel.jumpEnd(true); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter: panel.activateCurrent(); event.accepted = true; return
      case Qt.Key_Escape: panel.escapeChain(); event.accepted = true; return
      case Qt.Key_Backspace:
        if (focusCtrl.mode === "list") { focusCtrl.grabFilter(); event.accepted = true; return }
        break
      case Qt.Key_Space:
        if (focusCtrl.mode === "list" && !searchField.focused) { panel.activateCurrent(); event.accepted = true; return }
        break
    }

    if (!ctrl && !meta && !alt && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
      if (focusCtrl.mode === "list") {
        const pref = ["@"]
        for (let i = 0; i < pref.length; i++) {
          if (event.text === pref[i]) {
            const wasFilter = searchField.focused || focusCtrl.mode === "filter"
            searchField.text = ""
            Clipboard.enterPinned("")
            if (wasFilter) focusCtrl.grabFilter()
            else focusCtrl.grabList()
            event.accepted = true
            return
          }
        }
        // A dead filter takes no query; "@" above still enters pinned.
        if (panel.filterDead) { event.accepted = true; return }
        Clipboard.submit(event.text)
        searchField.text = event.text
        focusCtrl.grabFilter()
        event.accepted = true
        return
      }
    }
  }

  Keys.onPressed: event => panel.handleKey(event)

  // Skeleton row: a static mock of one resting clipboard entry - 20px
  // icon slot, title bar, sub bar with the timestamp reserve on the
  // right. Bar slots carry the entry's own line boxes through hidden
  // probe Texts (RowHeightProbe pattern: invisible, explicit width,
  // NoWrap), so each bar sits exactly where its text line would.
  // Static by design, no shimmer: chrome matches the island skeletons
  // (tint @0.14, 0.55 opacity, 2px corners).
  component SkeletonEntry: Item {
    id: skel

    // Repeater-fed, like every other delegate in the tree: the bare
    // `index` read at the instantiation site resolves to nothing at
    // runtime (ReferenceError), so the stagger reads the declared
    // property instead.
    required property int index
    property real titleFrac: [0.66, 0.48, 0.57][index % 3]

    opacity: 0.55

    Text {
      id: titleProbe

      visible: false
      width: 1
      wrapMode: Text.NoWrap
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily
      text: "Mg"
      textFormat: Text.PlainText
    }

    Text {
      id: subProbe

      visible: false
      width: 1
      wrapMode: Text.NoWrap
      font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
      text: "00:00"
      textFormat: Text.PlainText
    }

    // Mock of the entry's mainLine: same margins, same column spacing,
    // icon slot centered against the two-line column.
    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Ui.m
      anchors.rightMargin: Ui.m
      anchors.topMargin: Ui.rowPadV
      height: titleSlot.height + 1 + subSlot.height

      Rectangle {
        id: iconSlot

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 20
        height: 20
        radius: RoundingPolicy.radius
        color: Ui.tint("foreground_1", 0.14)
      }

      Column {
        anchors.left: iconSlot.right
        anchors.leftMargin: Ui.s
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1

        Item {
          id: titleSlot

          width: parent.width
          height: titleProbe.implicitHeight

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * skel.titleFrac
            height: 8
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.14)
          }
        }

        Item {
          id: subSlot

          width: parent.width
          height: subProbe.implicitHeight

          Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - timeSlot.width - Ui.s)
            height: 6
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.14)
          }

          Rectangle {
            id: timeSlot

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: subProbe.implicitWidth
            height: 6
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.14)
          }
        }
      }
    }
  }

  // --- top filter bar spans full width ---
  Item {
    id: filterBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    anchors.topMargin: panel.outerPad
    height: panel.filterH

    InputField {
      id: searchField
      anchors.fill: parent
      implicitHeight: panel.filterH
      basePadding: Ui.l
      focusColor: Ui.solid("accent")
       placeholder: Clipboard.showPinned ? "Filter pinned..." : "Filter clipboard..."
       inputRole: "filter"
       filterIconAlways: true
      // Dead while the viewed source is empty: no query to take, no
      // focus to hold. "@" still enters pinned mode from list keys.
      enabled: !panel.filterDead
      clearable: false
       chipActive: Clipboard.showPinned

      // Pinned mode swaps the boxed "@ pinned" chip for the bare pin glyph,
      // the same way the launcher's web-search mode swaps "Web:" for its
      // webapp glyph (unboxed icon alone, no text).
      chipIcon: Clipboard.showPinned ? "pin" : ""
      chipColorKey: "foreground_1"
      chipText: ""
      chipBoxed: false
      prefixes: ["@"]
      counterVisible: true
      counterMatched: Clipboard.matchedCount
      counterTotal: Clipboard.showPinned ? Clipboard.pinnedCount : Clipboard.normalCount
      onEdited: text => Clipboard.submit(text)
      onAccepted: panel.activateCurrent()
      onEscaped: panel.escapeChain()
      onPrefixEntered: (prefix, payload) => {
        if (prefix === "@") Clipboard.enterPinned(payload)
      }
      onBackspaceEmpty: {
        if (Clipboard.mode === "pinned") Clipboard.exitPinned()
        else Clipboard.stepBack()
      }
    }
  }

  // --- split content: list left, preview right ---
  Item {
    id: contentRow
    anchors.top: filterBar.bottom
    anchors.topMargin: panel.listTopGap
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    anchors.bottom: parent.bottom
    anchors.bottomMargin: panel.outerPad
    // The content area, and the list and the preview pane are the same box:
    // one height, one width decision, both from the shared metrics.
    height: metrics.contentH

    // Single vertical hairline between list and preview (Divider tone),
    // centered in the shared gap rather than drawn as a 1px box on the
    // preview's own edge.
    Rectangle {
      width: 1
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      x: metrics.leftW + (metrics.gap - 1) / 2
      color: Ui.tint("background_3", 1)
    }

    Row {
      anchors.fill: parent
      spacing: metrics.gap

      // Left list
      Item {
        id: listBox
        width: metrics.leftW
        height: parent.height
        clip: true

        List {
          id: list
          onCurrentIndexChanged: selProbeDebounce.restart()
          anchors.fill: parent
          // -> 16 is Ui.l, so the gutter reads a token verbatim.
          anchors.rightMargin: Ui.l
          // Plain array model: filtered syncs assign a new array the view
          // diffs by index.
          model: panel._records
          // Non-interactive default (List): no flick re-anchoring, and
          // the library wheel handler steps one entry per notch.
          // highlightMotion glides for focus moves - cursor-row gate
          // (menu parity): the bar snaps only while the focused row
          // stages its confirm (tracks it 1:1); an armed row left behind
          // must not freeze the bar mid-move. The card takes no growth
          // claim (fixed 6-row window), so gate on the slot state.
          highlightMotion: MotionPolicy.enabled && panel._deleteIndex !== list.currentIndex
          // Fixed 3-row margin (vim-style scrolloff): with the panel's
          // 6-row window the view starts moving when the cursor reaches
          // the 4th row; the glide follows the same gate as the focus.
          scrolloff: 3
          smoothScroll: MotionPolicy.enabled
          // Never learn while a pinned-row delete confirm is open (see
          // LauncherPanel): slot-inflated heights poison the table.
          measureGuard: idx => panel._deleteIndex < 0
          // Height table keyed by row identity: history writes reorder
          // rows and async thumbnail loads grow them in place - index
          // keys would describe the wrong row after the first mutation.
          // The key is the record id, so a table entry always describes the
          // row holding it. The `?? index` fallback is what keeps a row
          // renderable and measurable for a record the key lookup cannot
          // name.
          rowIdentity: index => String(panel._records[index]?.id ?? index)
          // Identity epoch for the height table: it advances only when a
          // sync changed the key SEQUENCE, so a payload-only change (a pin
          // flip, a fresh timeStr, a loaded thumbnail) keeps the measured
          // heights while a key-set change advances the epoch and prunes
          // the rows the new key set drops. A plain array has neither a
          // key-set flag nor a revision to read, so this is the panel's own
          // counter - see its declaration for why it is a counter and not
          // the sequence.
          identityRevision: panel.identityRevision
          trailSpace: 0
          clip: true
          autoRevealEnabled: true
          delegate: ClipboardEntry {
            restHeight: panel.rowH
            deleteOpen: panel._deleteIndex === index
            deleteStage: panel._deleteIndex === index ? panel._deleteStage : 0
            onActivated: () => panel.activateCurrent()
            onDeleteConfirm: () => panel.toggleDeleteCurrent()
          }
        }

        ScrollBar {
          flickable: list
          anchors.top: parent.top
          anchors.topMargin: 4
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 4
          thickness: 4
          autoHide: false
        }

        // Filler skeleton rows under short lists, up to the six-row
        // window: live rows stay live, the rest of the viewport holds
        // its footprint. Count and offset follow the live list, so a
        // filter narrows the live set and the skeletons take the rest.
        // Glides with the rows on delete (see armSlideFrom): the top
        // margin lands instantly with contentHeight, so the Translate
        // below carries the reflow instead.
        Column {
          id: skeletonBox
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: Ui.l
          anchors.top: parent.top
          anchors.topMargin: Math.min(list.contentHeight + (list.count > 0 ? list.spacing : 0), parent.height)
          spacing: list.spacing
          opacity: 0.8
          visible: list.count > 0 && list.count < metrics.rows
          clip: true

          transform: Translate { id: skeletonSlideTf }
          function armSlide(offset) {
            if (!MotionPolicy.enabled) return
            skeletonSlideTf.y = offset
            skeletonSlideAnim.from = offset
            skeletonSlideAnim.to = 0
            skeletonSlideAnim.restart()
          }
          NumberAnimation {
            id: skeletonSlideAnim
            target: skeletonSlideTf
            property: "y"
            duration: Ui.fastMs
            easing.type: Easing.OutCubic
          }

          Repeater {
            model: Math.max(0, metrics.rows - list.count)

            delegate: SkeletonEntry {
              width: parent.width
              height: panel.rowH
            }
          }
        }

        // Fully empty: dim veil over the full-window skeletons, the
        // EmptyState icon + copy above it (ArchUpdates up-to-date pattern).
        Rectangle {
          anchors.fill: parent
          visible: list.count === 0 && Clipboard.visible
          color: Ui.tint("background_0", 0.45)
        }

        // Empty list: clipboard-check with a green check over the copy
        // (library-wide EmptyState, same style as the menus). A filter
        // with no hits keeps the menus' filter-x + "No matches" pair.
        EmptyState {
          anchors.centerIn: parent
          width: Math.max(0, parent.width - 32)
          visible: list.count === 0 && Clipboard.visible
          // Icon-only when not searching: no copy under the glyph.
          text: panel.searching ? "No matches" : ""
          iconName: panel.searching ? "filter-x" : "clipboard-check"
          iconColorKey: "foreground_1"
          iconAccentKey: panel.searching ? "red" : "green"
        }
      }

      // Right preview - always visible
      Item {
        id: previewBox
        width: metrics.previewW
        height: parent.height
        readonly property var cur: list.currentIndex >= 0 && list.currentIndex < panel.rows.length
          ? panel.rows[list.currentIndex] : null
        // Keyed off the painted entry, not the live selection: a payload
        // racing the pane's fade never decorates the outgoing contents.
        readonly property var pdata: (preview.paintId >= 0 && Clipboard.previewData[preview.paintId]) ? Clipboard.previewData[preview.paintId] : ({})

        ClipboardPreview {
          id: preview
          anchors.fill: parent
          entry: previewBox.cur
          previewData: previewBox.pdata
        }
      }
    }
  }

  // Ask the service to prepare lazy preview payloads for the current row.
  // -> Debounced ~120ms single-shot so fast arrowing probes only the
  // -> settled row; single-flight preempt in the service stays.
  Timer {
    id: selProbeDebounce
    interval: Ui.fastMs
    repeat: false
    onTriggered: panel.requestForSelection()
  }
  function requestForSelection() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) return
    const row = panel.rows[idx]
    Clipboard.requestPreviewData(row.id, row)
  }

  function probeFocus() { return focusCtrl.probe() }
}

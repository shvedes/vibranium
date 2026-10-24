pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib
import "../../common/text/EditUtils.js" as EditUtils
import "../../common/ui/RowMetrics.js" as RowMetrics
import "../../common/ui/SlotGrowth.js" as SlotGrowth

// The menu card. Compact "name | value" list under a full-width filter,
// key-hint footer below.
//
// Keep-bespoke root: stays a plain Rectangle instead of PanelCard.
//
// The reason is only the grid. PanelCard answers the other two blockers:
// `rowLimit` carries the ten-row resting cap, and `rowHeightFn` is the hook
// for per-text row estimates, called ahead of the
// label/sub vocabulary (PanelCard.rowLimit, PanelCard.rowHeightFn). A stale
// "cannot be shared" note is worse
// than none - it authorizes a second implementation of the sizing rule
// without anyone having to argue for it, which is how that rule drifted and
// how a summoned card came to paint the previous menu's height.
//
// Grid is the part PanelCard has no concept of at all. The trajectory
// machinery below (hold, animated height, generation counters) is the second
// reason it cannot be declarative: a card's size is a function of the
// present, and this panel's is a function of history. Converging the two is
// real work and is not implied by a bug fix; see the sizing rule, which is
// stated once in modelListH rather than once per chain.
//
// KEYBOARD MODEL (list-first):
// One Keys handler on the panel root serves both modes - events bubble up
// from whatever holds focus (the filter TextInput in filter mode, a plain
// sink item in list mode). The field consumes printable characters itself
// while focused; everything it declines lands here and drives the list.
// In list mode printable keys flip into filter mode with that key applied.
//
//   arrows/tab     move selection (dropdown-aware)
//   enter          activate / pick option
//   + - left right step number/range rows
//   ctrl+i         expand description
//   esc            de-focus filter / clear query -> collapse -> back -> close
//   backspace      same chain as esc, but only while the field is inactive;
//                  with the field active (or an inline editor open) it is the
//                  field's, because text under the caret is not a row
//   delete         arm the filter from list mode
//   any typing     filters across every page of the bundle
//   "/"            quick-filters the CURRENT page (sub/desc/options)
//
// SPLIT MAP (one owner each, no behavior change): this file stays one
// root, sectioned into three regions - Grid (grid pages: gridMode,
// gridCellSpec, gridCols, composeGridRows, spacer/header pools), ListHost
// (row-set delivery: rowsModel, fit/height trajectory, rowSyncPlan,
// recomputeRows, the list view), SearchScope (filter field, scoped "/"
// quick-filter, word editing, search-driven rows).
Rectangle {
  id: panel

  // Shell chrome follows Hypr rounding like every other surface.
  radius: RoundingPolicy.radius

  // Ceiling handed down by the view (70% of screen height).
  property real maxHeight: 600

  // Focus is unified via PanelFocus (qs.common) so list/filter ownership
  // matches Launcher/PowerMenu. Editor rows still win over the field.
  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: Menu.open
  }
  property alias mode: focusCtrl.mode
  readonly property alias keySink: focusCtrl.keySink
  // Public handle for the list view (debug verbs drive cursor/scroll
  // through it); ids are component-scoped, so external callers need this.
  property alias listView: list

  readonly property string currentPageId: Menu.frame ? Menu.frame.id : ""
  readonly property bool searching: Menu.searching
  // "/" quick-filter: trims the current page's rows (not cross-page search).
  readonly property bool scopedSearching: Menu.scopedActive

  // Sliding-highlight motion gate: the selection bar glides for pure
  // focus shifts between resting rows, including while a query is
  // present - entry-to-entry moves animate the same filtered or not.
   // The focused row's slot still gates resize tracking, but a move to
   // another row keeps the native highlight glide while the old slot closes.
   readonly property bool highlightMotion: MotionPolicy.enabled
     && !panel.cursorSlotOpen && !panel._swapping

   // Cursor-row slot state (model-level, synchronous): only the focused
   // row's own slot suppresses height animation. A slot left behind on
   // another row must not freeze the bar mid-move; the handoff uses the
   // closing slot duration and finishes natively. Reads the model, never
   // delegates, so it flips the same tick as the index.
  readonly property bool cursorSlotOpen: {
    Menu.rev
    const view = panel.listView
    const idx = view ? view.currentIndex : -1
    const it = idx >= 0 && idx < panel.rowsModel.length ? panel.rowsModel[idx] : null
    return it ? (Menu.infoOpen(it) || Menu.isExpanded(it)) : false
  }

  // --- grid pages ---

  // The page deciding rendering layout: while searching, results inherit
  // the ENTRY page's mode (an emoji bundle filters within its own grid);
  // otherwise the current page decides.
  function layoutPage() {
    if (!Menu.bundle) return null
    if (panel.searching) return Menu.bundle.byId[Menu.bundle.entry] || null
    return Menu.pageById(panel.currentPageId)
  }

  readonly property bool gridMode: {
    const pg = panel.layoutPage()
    return !!pg && pg.layout === "grid"
  }

  // Cell side hint from the layout page; a floor keeps degenerate
  // declarations usable.
  readonly property real gridCellSpec: {
    const pg = panel.layoutPage()
    return pg && typeof pg.cell === "number" && pg.cell > 16 ? pg.cell : 46
  }

  // Columns fit the card's inner width; cells stretch to fill it exactly,
  // staying square-ish via the shared side length.
  readonly property real gridInnerW: Math.max(0, panel.width - 2 * Ui.outerPad)
  readonly property int gridCols: Math.max(1, Math.floor(panel.gridInnerW / panel.gridCellSpec))
  readonly property real gridSide: panel.gridCols > 0
    ? Math.floor(panel.gridInnerW / panel.gridCols) : panel.gridCellSpec

  readonly property int gridRows: Math.ceil(panel.rowsModel.length / panel.gridCols)
  readonly property real gridContentH: panel.gridRows * panel.gridSide

  // Frozen chrome slots so the row diff treats spacers as unchanged
  // between recompositions (identity, not value, is compared).
  property var _spacerPool: []
  property var _headerPool: ({})

  function spacerAt(i) {
    while (_spacerPool.length <= i)
      _spacerPool.push({
        type: "spacer",
        uid: "sp#" + _spacerPool.length,
        selectable: false
      })
    return _spacerPool[i]
  }

  function headerFor(sec) {
    if (_headerPool[sec] === undefined)
      _headerPool[sec] = {
        type: "header",
        uid: "hdr:" + sec,
        label: sec,
        selectable: false
      }
    return _headerPool[sec]
  }

  // Weave section headers into a flat cell list: a new section tag starts
  // a fresh row with a full-width header slot followed by invisible
  // spacers up to the next column boundary. `cols` defaults to the live
  // layout; startup preload passes the deterministic count derived from
  // the page declaration so a closed-window weave matches what the open
  // card will compute.
  function composeGridRows(items, cols) {
    const c = cols !== undefined ? cols : panel.gridCols
    const out = []
    let lastSec = null
    const padToRowEnd = () => {
      while (out.length % c !== 0)
        out.push(spacerAt(out.length))
    }
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      const sec = String(it.section ?? "")
      if (sec !== "" && sec !== lastSec) {
        padToRowEnd()
        out.push(headerFor(sec))
        while (out.length % c !== 0)
          out.push(spacerAt(out.length))
        lastSec = sec
      }
      out.push(it)
    }
    return out
  }

  // Both ends of the model come from the lib's one edge scan; the
  // selector is this panel's because it is also what List.isSelectable
  // and the grid's own cursor are handed.
  function firstSelectableIndex() {
    return MenuLib.selectableEdge(panel.rowsModel, panel.isSelectableIndex, false)
  }

  function lastSelectableIndex() {
    return MenuLib.selectableEdge(panel.rowsModel, panel.isSelectableIndex, true)
  }

  // Guard-filtered rows: managed identity-stable model (a naive binding
  // would rebuild delegates mid-interaction).
  property var rowsModel: []
  property real _latchedListH: -1
  property bool _fitPending: false
  property int _fitAttempts: 0
  property int _fitGen: 0
  property int _transitionGen: 0
  property bool _transitionActive: false
  // True while the transition in flight is a summon rather than a navigation.
  // The two are sized from opposite answers: a navigation glides from the
  // height the user can see, a summon has no card on screen yet and is born
  // at the height its own row set implies. Cleared wherever _transitionActive
  // is, so it is exactly "the spawn owns the card right now".
  property bool _summoning: false
  property bool _heightAnimating: false
  // The height the transition in flight latched as its starting point.
  // Written by beginPageTransition and by both branches of
  // _startHeightTransition/finishHeightTransition.
  //
  // NOTHING READS IT. listRegionH's pending-fit branch asks _currentListH,
  // which is the same number by another route and also covers a tween
  // already in flight; preferring the latched number here is the
  // filter-expand jump. It is kept written because it is part of the hold's
  // bookkeeping, but nothing depends on it, so treat it as removable.
  property real _heldListH: -1
  property real _committedListH: -1
  property real _animatedListH: -1
  property real _heightTargetH: -1
  property int _heightAnimGen: -1
  property int _pendingSlideDepth: -1
  readonly property real exactListH: panel._latchedListH

  property var _seenBundle: null

  function _restingFallbackH() {
    if (panel._committedListH >= 0) {
      if (panel._committedListH > 0)
        return Math.min(panel._committedListH, panel.screenMaxListH)
    }
    return panel.snappedListH(panel.cappedAvailH)
  }

  function _currentListH() {
    if ((panel._transitionActive || panel._heightAnimating)
      && panel._animatedListH > 0) return panel._animatedListH
    // The size actually on screen, which an open slot has changed. A page
    // transition freezes here so the new page glides from the height the
    // user can see; reading the resting size instead (as this did) made
    // navigating away from a page with an open dropdown jump.
    if (panel._slotRegionH > 0) return panel._slotRegionH
    if (panel._claimListH > 0) return panel._claimListH
    if (panel._committedListH > 0) return panel._committedListH
    if (panel._animatedListH > 0) return panel._animatedListH
    return panel._restingFallbackH()
  }

  function _invalidatePageCallbacks() {
    panel._transitionGen++
    panel._fitGen++
    panel._fitPending = false
    panel._fitAttempts = 0
    panel._quiesceDisarm()
    panel._heightAnimating = false
    panel._heightTargetH = -1
    panel._heightAnimGen = -1
    panel._transitionActive = false
    panel._summoning = false
    // A row glide the surface no longer shows must not hold the fit shut
    // on the next summon.
    panel._rowsMoving = false
    rowsMotionTimer.stop()
    fitRetryTimer.stop()
    fitRetryTimer.fitCallback = null
    panel._pendingSlideDepth = -1
    panel._heldListH = -1
    panel._animatedListH = -1
    // The resting size this surface was showing when it closed, and the
    // measurement that produced it, describe the menu that was open. Carried
    // into the next summon they are what a freshly spawned card sized itself
    // from: it painted the previous menu's box through the open fade and
    // snapped to the summoned page's own height a few frames in. The next
    // summon measures its own.
    panel._committedListH = -1
    panel._latchedListH = -1
    heightAnim.stop()
    slideAnim.stop()
    // The slot region belongs to a row of the page being left, so it is
    // released with everything else here. Left in place it would keep
    // overriding the new page's size, which is the empty gap under a short
    // submenu.
    panel._releaseSlotRegion()
    list.autoRevealIndex = -1
    list._followIdx = -1
    pageHost.x = 0
    pageHost.opacity = 1
  }

  function beginPageTransition(summon) {
    const gen = ++panel._transitionGen
    // The place owed to the page being left: it belongs to the row set that
    // page had, and the page on screen now is a different one. The new
    // page's restore arms its own.
    panel._placeIdx = -1
    // A summon claims the marker, and only a summon does: a page navigation
    // that lands inside the same opening window is still part of that spawn,
    // and the show gate snaps it regardless (see _startHeightTransition).
    if (summon === true) panel._summoning = true
    // Armed on the summon edge only: a navigation mid-flight is not a spawn
    // and has no inherited size to be measured against.
    if (summon === true) panel._armSpawnProbe()
    panel._fitGen++
    panel._fitPending = false
    panel._fitAttempts = 0
    // Freeze at the size the card is actually showing. The read has to
    // come before the animating flag is dropped, because _currentListH
    // answers from the last committed resting size once it is - a
    // navigation landing on a content-driven tween in flight would
    // otherwise snap the card back to where that tween started.
    //
    // A summon freezes nothing: there is no card on screen to read a size
    // off, so the read hands back the box of the menu that was open before
    // this one and the height chain holds that number through the open
    // fade - a long menu's height painted into a short menu's spawn, then
    // snapped to the summoned page's own size once the fit landed. The
    // summoned row set is the only size a spawn has; modelListH answers
    // from it.
    const held = panel._summoning ? -1 : Math.max(0, panel._currentListH())
    panel._heightAnimating = false
    panel._heightTargetH = -1
    panel._heightAnimGen = -1
    fitRetryTimer.stop()
    fitRetryTimer.fitCallback = null
    heightAnim.stop()
    slideAnim.stop()
    panel._heldListH = held
    panel._animatedListH = held
    // The hold has captured whatever the card is showing, open slot included,
    // so the claim about the page being left can go: the transition owns the
    // size from here and the region would only fight it.
    panel._releaseSlotRegion()
    panel._transitionActive = true
    panel._pendingSlideDepth = Menu.stack.length
    pageHost.x = 0
    pageHost.opacity = 0
    if (summon === true) listBox.lastDepth = Menu.stack.length
    return gen
  }

  function _finishPageTransition(gen) {
    if (gen !== panel._transitionGen || !panel._transitionActive
      || panel._fitPending || panel._heightAnimating) return
    const depth = panel._pendingSlideDepth
    panel._transitionActive = false
    panel._summoning = false
    // The transition's end is where the card owns its final size, so it is
    // also where the spawn probe's window closes. A spawn that never got
    // here did not settle - a close landed inside the fit - and keeping
    // `armed` would have the next unrelated height change report as its
    // first frame.
    if (panel._spawnArmed) {
      panel._spawnSettledH = panel.regionChromeH + panel.renderedListH
      panel._spawnArmed = false
    }
    panel._pendingSlideDepth = -1
    if (Menu.open && depth >= 0) listBox.slideFor(depth, gen)
    // The card owns its final size now, and so does the viewport the rows
    // sit in: the place the follow policy puts the focused row in can be
    // named for real.
    panel._placeFocusedRow()
  }

  // One height tween with two owners. `gen` is the page transition that
  // owns the card, or -1 for a content-driven resize (a conditional
  // reveal, a search filter) that has no transition to finish. A resize
  // the model asked for is no different from one the user asked for, and it
  // is the one that repeats under the cursor, so it rides the same tween.
  function _startHeightTransition(target, gen) {
    if (gen >= 0 && (gen !== panel._transitionGen || !panel._transitionActive)) return
    const next = Math.max(0, Math.min(target, panel.screenMaxListH))
    const current = Math.max(0, panel._currentListH())
    // The show gate, honoured here for the first time. The width Behavior
    // below already gates on `shown`, and the comment on the no-Behavior
    // block states the rule for both axes: before the opening layout
    // settles, a real size change must not animate. The summoned row set is
    // installed a turn or two after the card is already up, so the fit that
    // follows a summon measures the page being left, and a tween here would
    // carry the card from its height to the summoned one - a 176ms resize of
    // the whole card across the open fade, the exact artifact the gate exists
    // to prevent. Snapping hands the open fade a card that is already its own
    // size.
    //
    // `searching` is the width gate's own escape: a keystroke landing inside
    // the gate window is a real resize the user asked for, not the opening
    // layout, and tweening it is what the card has always done.
    const gateShut = !panel.shown && !panel.searching && !panel.scopedSearching
    if (!MotionPolicy.enabled || gateShut || current <= 0 || next <= 0
      || Math.abs(next - current) < 0.5) {
      panel._heightAnimating = false
      panel._heightAnimGen = gen
      heightAnim.stop()
      panel._heightTargetH = next
      panel._animatedListH = next
      panel._committedListH = next
      panel._heldListH = next
      if (gen >= 0) Qt.callLater(() => panel._finishPageTransition(gen))
      return
    }
    panel._heightAnimating = false
    heightAnim.stop()
    panel._heightAnimating = true
    panel._heightTargetH = next
    panel._heightAnimGen = gen
    panel._animatedListH = current
    heightAnim.from = current
    heightAnim.to = next
    heightAnim.restart()
  }

  function finishHeightTransition() {
    if (heightAnim.running) return
    const gen = panel._heightAnimGen
    const target = panel._heightTargetH
    // A stale generation means a newer transition already owns the card,
    // and a pending fit means a newer size is on its way. Either way the
    // tween is done: drop the animating flag so the region binding reads
    // the live size again instead of parking on a dead target.
    if (gen >= 0 && (gen !== panel._transitionGen || !panel._transitionActive)) {
      panel._heightAnimating = false
      return
    }
    if (gen >= 0 && panel._fitPending) {
      panel._heightAnimating = false
      return
    }
    if (target < 0) {
      panel._heightAnimating = false
      return
    }
    panel._heightAnimating = false
    panel._animatedListH = target
    panel._committedListH = target
    panel._heldListH = target
    if (gen >= 0) Qt.callLater(() => panel._finishPageTransition(gen))
  }

  // The region size the model implies, with no fit latch in the path.
  // Every other sizing branch lives in listRegionH; this one exists
  // because the recovery path runs right after clearing that latch, and
  // reading the region back there hands over the height the fit was
  // supposed to replace.
  function _modelListH() {
    if (panel.gridMode) return panel.listRegionH
    if (panel.rowsModel.length === 0)
      return Math.min(Ui.emptyMinH, panel.cappedAvailH)
    // The resting fit, never an open slot's growth. This value is latched
    // into exactListH, and the growth is applied on top of the region by
    // growForSlot rather than folded into it - so a slot that opened while
    // a page transition was mid-fit cannot leave the latch holding a
    // dropdown's height after the dropdown closed.
    return Math.max(0, Math.min(
      panel.snappedListH(panel.cappedAvailH), panel.screenMaxListH))
  }

  function _resolveFit(fit, fitGen, transitionGen) {
    if (fitGen !== panel._fitGen) return
    if (panel._transitionActive && transitionGen !== panel._transitionGen) return
    if (panel._transitionActive && !Menu.open) return
    const measured = fit >= 0
    // A fit that could not be measured sizes the card from the model.
    // Routing the failure through listRegionH instead re-derives it from
    // the committed height, which is the value the fit was replacing: the
    // card then keeps its old size until some unrelated event queues
    // another fit, and a page that gained or lost conditional rows never
    // changes size at all.
    const target = measured
      ? Math.min(fit, panel.screenMaxListH)
      : panel._modelListH()
    // Navigation and content-driven resizes share the one tween; a page
    // transition takes the gen so its slide waits for the height, and a
    // plain resize passes -1 because it has no slide to finish.
    //
    // The tween is armed BEFORE the latch is published below. Writing
    // _latchedListH invalidates listRegionH synchronously and the card
    // height binding reads that region on the same tick, so a tween
    // started after the write would find the card already at its new size
    // and pull it back to the old one before gliding forward.
    panel._startHeightTransition(target,
      panel._transitionActive && transitionGen === panel._transitionGen
        ? transitionGen : -1)
    if (!measured || (fit === 0 && panel.rowsModel.length > 0))
      panel._latchedListH = -1
    else panel._latchedListH = fit
  }

  // --- row-set delivery policy ---
  //
  // "Do these rows glide, and is this a wholesale rebuild" is ONE
  // question with two answers, asked here and nowhere else. A call site
  // states only what it knows - why the row set is being recomposed - and
  // this function adds the input only the panel can see, so no call site
  // can be silently overruled.
  //
  // Intents:
  //
  //   "rebuild" - the row set is being replaced wholesale for a reason
  //     that is not a row appearing or disappearing: page navigation, a
  //     new bundle, search teardown, the open-time reconcile, a startup
  //     preload. Wholesale install, no row motion.
  //   "reveal"  - rows were gained or lost in place while the user is
  //     looking: a showIf commit, a guard verdict, the "/" filter, a
  //     search keystroke, a column re-weave. Keyed incremental install,
  //     with the add/remove transitions running unless the projection is
  //     a ranked search (see rowSyncPlan).
  //
  // Any other intent is a rebuild. An unrecognised intent is the safe
  // reading, never an accidental glide.
  //
  // A wholesale install CANNOT glide, and that is a property of the
  // mechanism rather than a policy preference. The whole new set arrives
  // through one model write, so a wholesale row set is a clear and a
  // refill: the rows that leave have nothing left to animate them out,
  // and the ones that arrive have no gap that reads as "a row appeared
  // here". What a caller could ask for instead is the whole new set
  // fading in over an empty list, which is the clear-and-refill the bulk
  // path exists to perform, in slow motion, underneath a
  // beginSwap/endSwap window that assumes a masked refill.
  //
  // What silences it is the gate and not the write: syncAnimated is false
  // for every wholesale plan, and it is exactly what List.rowMotion and
  // GridList.syncAnimated read, so no add, remove or displaced transition
  // runs. The plan therefore never answers yes to both, and a caller that
  // wants a rebuild says "rebuild" and never asks for motion, so there is
  // no second answer sitting there ignored.
  function rowSyncPlan(intent, rowCount) {
    // Named here rather than folded into one boolean expression: a
    // projection wider than the visible list is the state that makes an
    // incremental install impossible rather than merely undesirable. The
    // row set and the installed array are in step by construction - nothing
    // outside this panel writes the model - so an incremental install is
    // refused here because the projection is too wide to show, not because
    // the model is behind.
    const wideProjection = panel.searching && rowCount > Ui.listFullRows
    const reveal = intent === "reveal"
    // Scoped filtering on a giant page churns the whole installed set per
    // keystroke; animating that reads as shimmer and gaps, so it installs
    // incrementally (the cursor reseat is explicit) but without motion.
    // Small pages keep the reveal motion.
    const frame = Menu.frame
    const srcPage = frame ? Menu.pageById(frame.id) : null
    const scopedGiant = reveal && Menu.scopedActive && !panel.searching
      && !!srcPage && Array.isArray(srcPage.items) && srcPage.items.length > Ui.listFullRows
    const wholesale = !reveal || wideProjection
    // A ranked search projection is not an in-place delta: every keystroke
    // re-ranks the whole hit set, so most rows change slot and the ones
    // that survive are reordered around them. Animating that leaves the
    // list mid-flight when the next keystroke lands - rows easing into
    // slots that have moved on, a removed row's gap still occupied by the
    // delegate that is leaving it, neighbours gliding to positions the
    // re-rank is about to invalidate. Search installs instantly instead.
    // The "/" quick-filter keeps its motion on small pages: it only removes
    // rows, which is the case the transitions were built for.
    const ranked = panel.searching
    // The motion policy is part of the ANSWER, not only a term in the
    // transition's own enabled binding: the row-motion latch must not
    // hold the fit open for motion the kill-switch has just removed.
    // Giant installs never glide, whatever the intent: a fade per added
    // row plus a glide per displaced one reads as shimmer across a hundred
    // rows (translucent rows, travelling gaps) instead of a reveal, so
    // they land instantly like a wholesale install. Small sets keep the
    // motion. The latch and the published flag both read glide, so gating
    // here keeps them as one.
    const glide = !wholesale && !ranked && !scopedGiant && rowCount <= Ui.listFullRows && MotionPolicy.enabled
    const blocker = reveal
      ? (wideProjection ? "wide-projection"
        : (ranked ? "ranked-projection" : ""))
      : intent
    return {
      intent: intent,
      wholesale: wholesale,
      glide: glide,
      blocker: blocker
    }
  }

  // Diagnostic: the plan the most recent install was resolved with. Not
  // read by any binding, so publishing it costs the install nothing.
  property var _lastSyncPlan: null

  function recomputeRows(intent) {
    // Nothing to render while closed - and skipping keeps killswitch
    // closes free of four-digit row churn. Reopening re-triggers
    // through the stack/query/bundle connections.
    if (!Menu.open) return
    // Degenerate-geometry guard: before the window's configure lands,
    // grid math runs with junk column counts and would weave a throwaway
    // model (plus a full delegate rebuild when real geometry arrives).
    // onGridColsChanged re-triggers recomposition once width settles;
    // minimum card widths keep cols > 1 in every legitimate layout.
    if (panel.gridMode && panel.gridCols <= 1 && !panel.searching) return
    let candidate
    if (panel.searching) {
      // Sectioning (bucket per owning page, separators opening each group)
      // is a pure transform - it
      // lives in MenuLib next to search/buildIndex.
      //
      // The resolver is Menu.pageById, not a bundle-only map: an indexed
      // picker registers its rows under a dynamic page id (Menu.indexExternal
      // via injectPage), and pageById spans bundle, dynamic and option pages.
      // A bundle-only map left every such hit unresolvable, which cost the row
      // its uid as well as its type and call, and keyedRows refuses an install
      // on the first unkeyable row - so one font family or keybinding anywhere
      // in the hit set suppressed the whole result, and a query with real
      // matches read as a dead search bar.
      candidate = MenuLib.groupSearchResults(Menu.results, Menu.pageById, Menu.isVisible)
    } else if (panel.scopedSearching) {
      // "/" quick-filter: already scoped by the lib to the current page's
      // visible fields. A trim, not the cross-page search - grid chrome
      // stays woven on grid pages.

      candidate = Menu.scopedRows.slice()
      if (!panel.searching)
        candidate = panel.composeGridRows(candidate)
    } else {
      // Read the target page FRESH: panel.currentPageId (a cached var
      // binding) hands back the PREVIOUS page inside change handlers,
      // which would latch restore-protection onto the wrong page and let
      // mid-swap cursor churn pollute the destination's saved state.
      const pgId = Menu.frame ? Menu.frame.id : ""
      const pg = Menu.pageById(pgId)
      const src = pg ? pg.items : []
      candidate = src.filter(item => Menu.isVisible(item))
      // Grid pages weave section headers and row-fill spacers into the
      // flat slot list; search results stay flat (no chrome mid-filter).
      if (!panel.searching)
        candidate = panel.composeGridRows(candidate)
    }

    // Giant unranked pages install the head window only: the viewport shows
    // a dozen rows and typing narrows the rest, so installing thousands is
    // open-time model churn for rows no delegate shows. The cap matches
    // listFullRows, which keeps the installed set in the wall regime (a
    // smaller cap would fully instantiate every installed delegate
    // instead). Ranked global results stay whole and grid pages keep their
    // chrome; small pages never reach this branch. The hint rides the same
    // bare separator shape groupSearchResults weaves into result sets.
    if (!panel.searching && !panel.gridMode && candidate.length > Ui.listFullRows) {
      const total = candidate.length
      candidate = candidate.slice(0, Ui.listFullRows)
      candidate.push({
        type: "separator",
        uid: "sep:cap-hint",
        label: (total - Ui.listFullRows) + " more - keep typing to narrow"
      })
    }

    const records = panel.keyedRows(candidate)
    if (records === null) {
      panel._invalidatePendingRows()
      return
    }

    const plan = panel.rowSyncPlan(intent, records.length)
    const prev = panel.rowsModel
    if (prev.length === candidate.length) {
      let same = true
      for (let i = 0; i < candidate.length; i++) {
        if (prev[i] !== candidate[i]) {
          same = false
          break
        }
      }
      // A rebuild is unconditional: it exists because the MODEL is out of
      // step with the row set, and a candidate that compares equal says
      // nothing about that. A reveal is a delta, so an equal candidate
      // means there is nothing to reveal.
      if (same && !plan.wholesale) return
    }

    // Height caches BEFORE the swap: bindings evaluate synchronously on
    // assignment and would otherwise snap from cold-cache fallbacks with
    // no re-notification to correct them (short pages stuck scrollable).
    panel.cacheRowHeights(candidate)
    if (!panel.syncRowsList(candidate, plan, records)) return
    // A close latch belongs to a row this model still lists. `candidate` is
    // the authoritative "what the model will show", so the reconcile needs
    // no view timing: keyed sync destroys a delegate exactly when its key
    // leaves, so anything pruned here has no delegate left to report.
    Menu.pruneSlotCloses(candidate)
    panel.rowsModel = candidate
    panel.queueFit()
    panel.recalcWidth()
  }

  function queueFit() {
    const rows = panel.rowsModel || []
    if (panel._fitPending) {
      panel._fitAttempts = 0
      if (fitRetryTimer.fitCallback !== null) fitRetryTimer.restart()
      return
    }
    fitRetryTimer.stop()
    fitRetryTimer.fitCallback = null
    const fitGen = ++panel._fitGen
    const transitionGen = panel._transitionGen
    if (panel.gridMode || rows.length === 0) {
      panel._latchedListH = -1
      panel._fitPending = false
      panel._fitAttempts = 0
      panel._resolveFit(-1, fitGen, transitionGen)
      return
    }
    // Without motion the measured fit cannot be absorbed, so it is not run.
    // It needs two event-loop turns plus 16ms retries before the delegates
    // it reads exist, and every one of those is a real frame once no tween
    // covers it: the card would hold the provisional height, render the row
    // build inside it, then re-snap to the delegate measurement. That is the
    // staged resize, not an instant one.
    //
    // The model height is a measurement, not an estimate - rowRestHeight
    // drives real Text probes and caches per string - so it is committed as
    // final here. The latch is left to _resolveFit, which arms the height
    // before publishing it; a write above that would invalidate the region
    // binding a turn early.
    if (!MotionPolicy.enabled) {
      panel._resolveFit(
        panel.snappedListH(panel.availListH, Math.min(10, rows.length)),
        fitGen, transitionGen)
      return
    }
    panel._fitPending = true
    panel._fitAttempts = 0
    const fail = () => {
      if (fitGen !== panel._fitGen) return
      fitRetryTimer.stop()
      fitRetryTimer.fitCallback = null
      panel._latchedListH = -1
      panel._fitPending = false
      panel._fitAttempts = 0
      panel._resolveFit(-1, fitGen, transitionGen)
    }
    function retryFit(reason) {
      if (fitGen !== panel._fitGen || !panel._fitPending) return
      if (panel._fitAttempts < 8) {
        panel._fitAttempts++
        fitRetryTimer.fitCallback = tryFit
        fitRetryTimer.restart()
        return
      }
      fail()
    }
    function retrySettle() {
      if (fitGen !== panel._fitGen || !panel._fitPending) return
      // The longer of the two waits, on purpose: a swap settles within a
      // few event-loop turns, while a slot outlives its own height tween
      // by the close grace DropdownSlot holds it for, so the geometry
      // budget gives up mid-motion. Bounded anyway: a wait that re-posts
      // itself with Qt.callLater never reaches fail(), for it rescans every
      // live delegate once per event-loop turn for as
      // long as the condition holds, competing with the row transitions it
      // was waiting for, and when the condition does clear late the card
      // is still sized from the fit it was waiting to replace.
      if (panel._fitAttempts < 24) {
        panel._fitAttempts++
        fitRetryTimer.fitCallback = tryFit
        fitRetryTimer.restart()
        return
      }
      fail()
    }
    function tryFit() {
      if (fitGen !== panel._fitGen || !panel._fitPending) {
        return
      }
      fitRetryTimer.stop()
      fitRetryTimer.fitCallback = null
      const current = panel.rowsModel || []
      if (panel.gridMode || current.length === 0) {
        panel._latchedListH = -1
        panel._fitPending = false
        panel._fitAttempts = 0
        panel._resolveFit(-1, fitGen, transitionGen)
        return
      }
      let expanding = panel.expansionNeedH > 0
      if (!expanding) {
        const kids = list.contentItem.children
        for (let i = 0; i < kids.length; i++) {
          const d = kids[i]
          if (!(d instanceof Entry)) continue
          if (d.slotMotionMs > 0 || d.descSlotH > 0 || d.expandSlotH > 0) {
            expanding = true
            break
          }
        }
      }
      if (list._inSwap || Menu.slotClosing || expanding) {
        retrySettle()
        return
      }
      if (panel._rowsMoving) {
        // The resting height cannot be measured yet, but the card does not
        // have to wait for the slide to finish before following it: the
        // MODEL already knows how tall the new row set is, and the model
        // path reads no delegate geometry, so it is immune to exactly the
        // transition the measurement is being held off for. Size from it
        // so the two motions run together, and let the latch re-queue
        // correct the estimate once the rows rest. The estimate runs a
        // couple of pixels per row under the real delegates, so the
        // correction is a glide too small to read.
        panel._latchedListH = -1
        panel._fitPending = false
        panel._fitAttempts = 0
        panel._resolveFit(-1, fitGen, transitionGen)
        return
      }
      // Rest-state shortcut: no row open, closing, or holding info
      // anywhere in the installed set, so every row is at its model
      // height and waiting for delegates only chains event-loop turns
      // behind filtering. Live delegates are covered by the expanding
      // scan above; the store covers rows no delegate shows yet. Pages
      // with an open slot keep the measured path below.
      let anyOpen = false
      for (let i = 0; i < current.length; i++) {
        const st = current[i]
        if (!st) continue
        if (Menu.isExpanded(st) || Menu.isSlotClosing(st) || Menu.infoOpen(st)) {
          anyOpen = true
          break
        }
      }
      if (!anyOpen) {
        panel._latchedListH = -1
        panel._fitPending = false
        panel._fitAttempts = 0
        panel._resolveFit(-1, fitGen, transitionGen)
        return
      }
      if (list.count !== current.length) {
        retryFit("count-mismatch")
        return
      }
      if (panel.availListH <= 0 || list.width <= 0 || list.height <= 0) {
        retryFit("geometry-unresolved")
        return
      }
      const fit = list.fitHeight(panel.availListH, Math.min(10, current.length))
      if (fit < 0 && current.length > 0) {
        retryFit("fit-failed")
        return
      }
      if (fitGen !== panel._fitGen) {
        return
      }
      panel._latchedListH = fit
      panel._fitPending = false
      panel._fitAttempts = 0
      panel._resolveFit(fit, fitGen, transitionGen)
    }
    Qt.callLater(() => {
      if (fitGen !== panel._fitGen) return
      Qt.callLater(tryFit)
    })
  }

  // Fit retry beat, named (one frame): re-runs a fit that landed
  // mid-settle on the next frame rather than spinning.
  readonly property int fitRetryMs: 16
  Timer {
    id: fitRetryTimer

    property var fitCallback: null
    interval: panel.fitRetryMs
    repeat: false
    onTriggered: {
      const retry = fitRetryTimer.fitCallback
      fitRetryTimer.fitCallback = null
      if (typeof retry === "function") retry()
    }
  }

  // The one thing the add/remove transitions read (see the transition
  // block on `list` and, for grid pages, on GridList). Published from the
  // plan and from nothing else: a second writer would be a second policy.
  property bool syncAnimated: false
  // The record array the model shows. This array IS the model's whole data
  // path and _writeRecords is its only writer. The records are the panel's
  // own row objects rather than wrappers beside them: the views hand the
  // delegate the record whole and in one role, so a wrapper is a second
  // object per row that every field read in Entry and GridCell would have
  // to unwrap first.
  property var _records: []
  // Plain array model: both views read panel._records directly, so an install
  // is one array assignment the views diff by index - fresh records rebind
  // each slot in place and only the tail beyond the new end leaves. A keyed
  // ScriptModel with pooled reuse instead leaves removed rows visible in one
  // slot on wholesale fresh swaps (proven by probe).
  // Identity epoch for List's height table. A plain array reports neither
  // a revision nor a key-set flag, so the panel owns the counter, and it
  // advances at the model's single write site rather than from a binding
  // over the value it reads - that is a loop, and the engine warns about
  // it on every pass.
  //
  // It advances only when the key SEQUENCE changed, so a payload-only
  // change keeps the measured heights and a key-set change prunes the
  // rows the new key set no longer claims. A counter rather than the
  // sequence itself because List.identityRevision wants a revision that never
  // repeats an earlier value, and walking back into a page returns to the
  // sequence that page had before - which is ordinary here, every page has
  // its own rows and the user visits them repeatedly.
  property int _epoch: 0
  property var _lastSeq: ""
  // Memo for keySeq: the joined sequence is recomputed only when the array
  // instance changes -> same string, no behavior change.
  property var _keySeqSrc: null
  property string _keySeqVal: ""
  // Height-cache warm marker: the candidate instance already shaped by
  // cacheRowHeights -> recalcWidth skips its second warm for the same instance.
  property var _warmedHeightsFor: null
  // Tracked open-slot row: uid plus index of the row holding expanded or
  // info-open state -> onRevChanged checks it O(1), scans only when absent.
  property string _openSlotUid: ""
  property int _openSlotIdx: -1
  readonly property int identityRevision: panel._epoch
  // Display model: a ScriptModel over `_records`. Reassigning `values` diffs
  // the row set inside the model rather than resetting the view, so a row
  // that appears or disappears with a condition is INSERTED or REMOVED, and
  // the view's transitions run on those - which is what makes a conditional
  // reveal animate.
  //
  // A plain array cannot say that. Assigning one resets the model: every
  // delegate is destroyed and rebuilt, so there is no arriving or leaving
  // row for a transition to act on, and the cursor - which the reset takes
  // to the head with it - goes with it. The keyed rows and the identity
  // epoch above are the other half of the same contract: the epoch says
  // when the KEY SEQUENCE changed, which is what the view's height table
  // needs, and the model says WHICH ROWS changed, which is what the
  // transitions need.
  ScriptModel {
    id: listModel
    values: panel._records
    // The identity keyedRows() mints, lifted onto the row itself so the
    // record the delegate receives IS the row and the body reads
    // `modelData.<field>`.
    objectProp: "uid"
    // Identity compares a payload by reference, which is what these rows are
    // built under: the menu mints fresh row objects every pass, so a payload
    // change is always a new reference. The default (Structure) would compare
    // by content instead.
    comparisonMode: ObjectComparison.Identity
  }
  property bool _rowsPending: false
  property var _pendingCandidate: null
  // The two answers travel together, so the deferred install cannot
  // receive one without the other.
  property var _pendingPlan: null
  property int _pendingGen: 0
  property int _swapGen: 0
  property int _swapPendingGen: -1
  property bool _swapping: false
  property string _modelError: ""

  // The key sequence the identity epoch compares on, and the open-time
  // reconcile compares the model against. Folded from the row array this
  // panel owns.
  //
  // NUL separates the keys, and MenuLib.uidKey strips every control
  // character out of an item id and a page id (MenuLib.js:343, because the
  // verdict channel a uid reaches is line-oriented), so a row uid cannot
  // hold one and the join cannot forge a boundary between two rows. The
  // one raw string that reaches a uid is a grid section label, woven into
  // "hdr:" + label; a NUL in one would make two different row sets share a
  // sequence, which costs a missed reconcile and a table that re-learns -
  // never a wrong install.
  function keySeq(rows) {
    // Memoized on the array identity -> one join per distinct instance.
    if (rows === panel._keySeqSrc) return panel._keySeqVal
    const pool = Array.isArray(rows) ? rows : []
    const keys = new Array(pool.length)
    for (let i = 0; i < pool.length; i++) {
      const item = pool[i]
      keys[i] = String(item && item.uid !== undefined && item.uid !== null
        ? item.uid : "")
    }
    const seq = keys.join("\u0000")
    panel._keySeqSrc = rows
    panel._keySeqVal = seq
    return seq
  }

  // The row set this panel's own guard accepts, and the records the views
  // show. The guard keeps the keyed-model validate vocabulary: four rows
  // in, four rows out is not an install the height table can absorb when
  // two share one identity (List refuses both, prunes both, raises an
  // identityError nobody reports), so the codes name the refusals this
  // panel can still make. What the array took away is the report on
  // everything else: nothing names a plan that could not be applied, a
  // payload that is not an object, or a state the model drifted into,
  // because a single array assignment it cannot be asked to violate has no
  // such states.
  //
  // Why the refusal has to stay: two live rows on one identity is the one
  // failure List.qml cannot absorb. It refuses to measure either of them,
  // prunes both from the table and raises identityError - and that
  // property is reported by nobody, by design (List.identityError), so a
  // duplicate that reached the model would degrade the height table with
  // nothing anywhere saying why. Measured: three rows in, three out, both
  // duplicates rendered, identityError "duplicate_identity", the table
  // left holding only the row that had the identity to itself.
  //
  // The array is fresh, holding the caller's own row objects. A fresh
  // array is what makes an install observable at all: assigning the array
  // the model already holds would not notify, and a rebuild whose candidate
  // is element-wise identical to the row set already installed - the same
  // objects, the same order, which recomputeRows installs rather than
  // dropping - is exactly that case.
  function keyedRows(candidate) {
    if (!Array.isArray(candidate)) {
      panel._modelError = "not_array"
      return null
    }
    const rows = new Array(candidate.length)
    const seen = Object.create(null)
    for (let i = 0; i < candidate.length; i++) {
      const item = candidate[i]
      if (!item || item.uid === undefined || item.uid === null) {
        panel._modelError = "invalid_row"
        return null
      }
      const key = String(item.uid)
      if (key.trim() === "") {
        panel._modelError = "missing_key"
        return null
      }
      if (seen[key] !== undefined) {
        panel._modelError = "duplicate_key"
        return null
      }
      seen[key] = true
      rows[i] = item
    }
    panel._modelError = ""
    return rows
  }

  // The array assignment is the model's single write: the views read
  // panel._records directly, so there is no result to inspect and no second
  // verb to fall back from: the write lands, or the array handed to it was
  // not one - and keyedRows above has already answered the only question
  // this panel's rows can get wrong.
  //
  // `keepRow` says whether the cursor should stay on the ROW it was on
  // across the write. The view is the only thing that knows a row by
  // identity and the only thing that knows a change is coming, so it is
  // the one that can put the cursor back - but only a caller that wants
  // the cursor to stay may ask for it. A caller that seats the cursor
  // itself (the search projections, which seat the head of the new order)
  // must not: the keep answers a model change by restoring the row the
  // cursor was on, and a projection that keeps that row at the same index
  // moves no index at all, so the keep would outlive the change it was
  // armed for - holding the bar at a width the card has already left, and
  // swallowing the first cursor move the user makes afterwards.
  function _writeRecords(records, keepRow) {
    // The model is about to change, and a model change moves the cursor off
    // the row it was on. The view puts it back on that row - the view is the
    // only thing that knows a row by identity, and this is the only thing
    // that knows a change is coming.
    if (keepRow !== false) list.keepCursor()
    panel._records = records
    // A model replacement ends user-motion provenance: any cursor move
    // after this point is the view adjusting, not the user asking, until
    // the next seat. Without this, a native adjustment landing on some
    // row would be persisted by track() as a remembered seat.
    list._lastSeatCause = "land"
    // The identity epoch, advanced here and nowhere else: this is the
    // model's one write, so it is the only place a new key sequence can
    // appear.
    const seq = panel.keySeq(records)
    if (seq !== panel._lastSeq) {
      panel._lastSeq = seq
      panel._epoch++
    }
  }

  // Quiesce handshake for motionless installs. Back-to-back array
  // assignments while the view is still applying the previous one would
  // strand delegates under the keyed model: extra children that keep showing
  // at stale positions, so two rows read as overlaid in one slot. Healthy
  // loops apply within the gaps the debounce already leaves and never trip
  // this; starved loops serialize instead of corrupting. Motion installs
  // never gate (transitions churn legitimately) and the wait is bounded, so
  // filtering can never freeze.
  property bool _quiesceArmed: false
  property int _quiesceEvents: 0
  property int _quiesceSeen: 0
  property double _quiesceArmedAt: 0
  readonly property int _quiesceWaitMs: 2000

  function _quiesceDisarm() {
    panel._quiesceArmed = false
    panel._quiesceEvents = 0
    panel._quiesceSeen = 0
    panel._quiesceArmedAt = 0
  }

  function _quiesceArm() {
    panel._quiesceArmed = true
    panel._quiesceEvents = 0
    panel._quiesceSeen = 0
    panel._quiesceArmedAt = Date.now()
  }

  // True when a motionless install may write: nothing outstanding, the
  // outstanding write quiesced (no new structural churn since the last
  // check), or the wait ran out. Callers re-queue through the normal
  // coalescing when held, so the latest wins and nothing freezes.
  function _quiesceReady() {
    if (!panel._quiesceArmed) return true
    if (panel._quiesceEvents === panel._quiesceSeen
      || Date.now() - panel._quiesceArmedAt > panel._quiesceWaitMs) {
      panel._quiesceDisarm()
      return true
    }
    panel._quiesceSeen = panel._quiesceEvents
    return false
  }

  Connections {
    target: list.contentItem
    function onChildrenChanged() {
      if (panel._quiesceArmed) panel._quiesceEvents++
    }
  }

  function _releaseSwap() {
    if (panel._swapping) {
      panel._swapGen++
      list.endSwap()
      panel._swapping = false
    }
    panel._swapPendingGen = -1
  }

  // True when the candidate holds the very same row objects, in order, as
  // the installed model. Same uids alone are not enough to skip: a fresh
  // container rebuild mints new objects (payloads refreshed), and only the
  // model write hands those to the delegates. Same references mean there
  // is literally nothing to publish - and reassigning the array anyway
  // resets the native view, whose cursor adjustment paints one wrong frame
  // (the Help tail) with the highlight gliding there and back.
  function _sameRecords(records) {
    const cur = panel._records
    if (!Array.isArray(records) || !Array.isArray(cur)
      || records.length !== cur.length) return false
    for (let i = 0; i < records.length; i++) {
      if (records[i] !== cur[i]) return false
    }
    return true
  }

  function _invalidatePendingRows() {
    panel._pendingGen++
    panel._pendingCandidate = null
    panel._pendingPlan = null
    panel._releaseSwap()
  }

  // Clear the cursor ahead of a model write while a summon is settling.
  // Whatever the view holds - a stale tail index, a rebind-seated head, a
  // native clamp - is gone a turn later, and the index diff carries
  // whatever is under the cursor across the swap (clamping a stale row to
  // the new tail: the Help-first frame). A cleared cursor survives the
  // diff untouched, so every frame until the landing seat is empty rather
  // than wrong. Outside a summon this is a no-op by contract: callers only
  // invoke it on the install paths below while _summonSeat is armed.
  function _clearCursorForSwap() {
    if (!panel._summonSeat) return
    if (panel.gridMode) {
      if (grid.currentIndex !== -1) grid.currentIndex = -1
      return
    }
    list._hlHeld = false
    if (list.currentIndex !== -1) list.seat(-1, "land", true)
  }

  function _installRows(records, plan, generation) {
    if (generation !== panel._pendingGen) return
    // Motionless installs wait for the previous motionless write to land
    // (see _quiesceReady); motion installs proceed as before. Held payloads
    // re-queue through the normal coalescing, so the latest wins.
    if (!plan.glide && !panel._quiesceReady()) {
      panel._queueRows(records, plan)
      return
    }
    panel._releaseSwap()
    // The plan answers row motion for the whole install; a wholesale one
    // has already answered no, so publishing it here needs no second test.
    panel.syncAnimated = plan.glide

    if (!plan.wholesale) {
      panel._clearCursorForSwap()
      if (!panel._sameRecords(records)) {
        panel._writeRecords(records, !panel.searching && !panel.scopedSearching)
        if (plan.glide) panel._quiesceDisarm()
        else panel._quiesceArm()
      }
       if (generation !== panel._pendingGen) return
       // A re-ranked projection has no cursor worth keeping: the write holds
       // the current ITEM and only shifts its index, so a cursor parked on a
       // hit that survived the re-rank followed it down the ranking - often
       // past the fold, leaving the selection bar nowhere near the row the
       // user just typed. Both search modes seat the head here instead,
       // where the new order is already installed - which is why the write
       // above does not ask the view to keep the cursor's row either: the
       // two answers are opposites, and the head is the one this path wants.
       if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
       // A launch still settling. The launch wants the head of the row set as
       // it stands, and the head is what a re-seat names - a dead link coming
       // back or a guard verdict landing above the head leaves the highlight
       // one row too low with nothing left to correct it, so the wholesale
       // path already re-asserts, and the summons that break are exactly the
       // ones whose last install is this one. Deferred, because the view
       // applies the array swap after this returns.
       else if (panel._summonSeat) Idle.run(() => panel._reseatFrameSel(), 2)
       // A reveal with no launch in it: a showIf verdict, a guard verdict, a
       // "/" filter. The row set moved under the cursor, and the cursor goes
       // with the row it was on: the row that appeared or disappeared above
       // it must not move it, and the row it was on must not be lost. The
       // view owns that - a replaced model takes the cursor with it, and
       // List gives the row back by identity.
       panel.queueFit()
       return
    }

     panel._swapGen++
     const g = panel._swapGen
     const sameContent = panel._sameRecords(records)
     if (!sameContent) {
       list.beginSwap()
       panel._swapping = true
     }
      panel._swapPendingGen = generation
      panel._clearCursorForSwap()
      if (!sameContent) {
        // The same answer as the incremental path above: the search
        // projections seat the head of the new order instead of keeping
        // the cursor's row, so they do not ask the view to keep it.
        panel._writeRecords(records, !panel.searching && !panel.scopedSearching)
        // Wholesale never glides, so every write here arms the handshake.
        panel._quiesceArm()
      }
 
    Idle.run(() => {
      if (panel._swapGen !== g || panel._pendingGen !== generation) {
        if (panel._swapGen === g) panel._releaseSwap()
        panel._reseatFrameSel()
        return
      }
      if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
      Qt.callLater(() => {
        if (panel._swapGen !== g || panel._pendingGen !== generation) {
          if (panel._swapGen === g) panel._releaseSwap()
          panel._reseatFrameSel()
          return
        }
         panel._swapping = false
         panel._swapPendingGen = -1
         list.endSwap()
         if (panel._swapGen !== g || panel._pendingGen !== generation) {
           panel._reseatFrameSel()
           return
         }

        panel.queueFit()
        if (!panel.searching && !panel.scopedSearching) {
           panel.applyFrameState()
           if (list && typeof list.unpinHighlight === "function") list.unpinHighlight()
           if (list) list._keepCursor = false
         }
        // The install's own landing, checked once more - but on a later
        // turn, because that is when the moves land. applyFrameState seats
        // the row it was asked for, yet the view carries the cursor across
        // the moves this install just published, and the view applies
        // its diff after the install returns: re-asserting here is right for
        // an instant and the cursor is out of it again by the next one. The
        // bail paths above cover an install that never got this far.
        Idle.run(() => panel._reseatFrameSel(), 2)
      })
    }, 2)
  }

  function _queueRows(records, plan) {
    if (records === null) {
      panel._invalidatePendingRows()
      return
    }
    panel._pendingCandidate = records
    panel._pendingPlan = plan
     panel._pendingGen++
     if (panel._swapping && panel._swapPendingGen !== panel._pendingGen)
       panel._releaseSwap()
     if (panel._rowsPending) return
     panel._rowsPending = true
     Idle.run(() => {
       if (!panel._rowsPending) return
       const generation = panel._pendingGen
       const candidate = panel._pendingCandidate
       const install = panel._pendingPlan
       panel._pendingCandidate = null
       panel._pendingPlan = null
       panel._rowsPending = false
       if (candidate === null || generation !== panel._pendingGen) return
       panel._installRows(candidate, install, generation)
     })
  }

  // Arm the latch and start its window together: the sync that arms it is
  // the one whose install makes the rows move.
  property bool _rowsMoving: false

  // `plan` is rowSyncPlan's answer, handed in by the one entry point that
  // has the intent and the row count (recomputeRows). This function installs
  // it and never re-derives it.
  function syncRowsList(candidate, plan, records) {
    const keyed = records === undefined ? panel.keyedRows(candidate) : records
    if (keyed === null) {
      panel._invalidatePendingRows()
      return false
    }
    // The last resolved plan, for the probe: a row set that stopped
    // animating is otherwise indistinguishable from one that never
    // changed, and those are different bugs in different places.
    panel._lastSyncPlan = plan
    // Only a wholesale install loses the cursor, so only it needs the
    // remembered seat protected from the tracking a model change
    // triggers. An incremental apply keeps the current item and shifts
    // its index, which is the correct answer for a row set that gained
    // or lost entries above the cursor; re-seating from the saved index
    // there moved the cursor onto a different row. Latching only real
    // swaps also keeps a content delta from parking scroll persistence
    // until some later navigation ends the window.
    if (plan.wholesale && !panel.searching && Menu.open)
      Menu.beginRestore(panel.currentPageId)
    // Arm the row-motion latch whenever this sync will glide rows. The
    // fit measures the RESTING height off live delegate geometry, and a
    // gliding row is not at rest: an inserted row is parented at the y it
    // is sliding away from, and a removed one is still parented at the y
    // it is sliding out of. Measuring inside that window returns the
    // layout the rows are leaving, and because the delegate count already
    // matches the model the result looks like a valid measurement and is
    // kept - which is how a three-row page keeps a six-row card. The
    // latch holds the fit for exactly the transition's own duration, the
    // same shape as Menu.slotClosing holds it for a closing slot.
    if (plan.glide) {
      panel._rowsMoving = true
      rowsMotionTimer.restart()
    } else if (panel._rowsPending) {
      // A queued install never wrote, so no rows glide for it: a latch
      // armed by the plan it supersedes (search teardown's reveal,
      // coalesced away by the rebuild behind it) must not outlive it, or
      // the landing fit measures from the model estimate while the
      // delegates it will show are already at rest.
      panel._rowsMoving = false
      rowsMotionTimer.stop()
    }
    panel._queueRows(keyed, plan)
    return true
  }

  // Row-motion latch, true while an add/remove glide is still running.
  // Gated on MotionPolicy, so a kill-switched shell never waits for a
  // transition that has a zero duration.
  Timer {
    id: rowsMotionTimer

    interval: MotionPolicy.duration(Ui.fastMs) + 20
    repeat: false
    onTriggered: {
      panel._rowsMoving = false
      // The rows have come to rest, so the height they imply is finally
      // measurable. Nothing else will queue a fit on its own: the one
      // that gave up already committed. A closed surface has no resting
      // geometry to measure, and the next summon fits itself.
      if (Menu.open) panel.queueFit()
    }
  }

  // Column-count changes (card settling after summon, resizes) invalidate
  // woven header/spacer slot positions - recompose once the width stops
  // moving rather than chasing every animation frame.
  property int _seenGridCols: 0

  onGridModeChanged: {
    // Renderer swap mid-summon rebinds the views' models (list model goes
    // null <-> array), and a native rebind seats head on rows the
    // install below is about to replace. Clear while the launch is still
    // settling so the write below starts empty too; the landing seats head.
    if (Menu.open && panel._summonSeat) panel._clearCursorForSwap()
  }

  onGridColsChanged: {
    if (!Menu.open || panel.searching) return
    if (panel._seenGridCols === panel.gridCols) return
    recompTimer.restart()
  }

  Timer {
    id: recompTimer

    interval: 260

    onTriggered: {
      if (!Menu.open || panel.searching) return
      panel._seenGridCols = panel.gridCols
      // Keyed, not wholesale. A column change is a re-weave of the
      // header/spacer slots, which the keyed sync expresses as insert,
      // remove and move, so the cursor keeps its row and the
      // repositioning glides. Forcing a bulk install here made every
      // width change a clear-and-refill: the view was emptied for a
      // tick, the cursor landed on row 0, and the remembered seat came
      // back a frame later - a visible jump to the first entry on every
      // summon and every back navigation, since both resize the card.
      // Most columns do not reach a header at all, and the candidate
      // then compares equal, which is the early return doing its job.
      panel.recomputeRows("reveal")
    }
  }

  onSearchingChanged: {
    // A query is the user asking for something else, so the launch that
    // wanted the head is over - whether or not the projection ever moves
    // the cursor, which a query with no hits does not.
    panel._summonSeat = false
    // A search re-projects the row set, so any reveal claim the previous
    // projection (or an open slot on the page being searched) held no longer
    // names a row in this one. Leaving it in place made pursuit chase a
    // ghost index once the model shrank, scrolling the list off into empty
    // space. Drop it before the rebuild below re-seats anything.
    list.autoRevealIndex = -1
    list._followIdx = -1
    list.contentY = 0
    // A search re-projects the rows: any slot close in flight on the page
    // being searched is no longer relevant to this projection.
    Menu.slotClosing = false
    // A search re-projects the rows, so any slot-driven region growth from
    // the page being searched no longer applies to this projection. Release
    // it so pursuit is not silenced (or mis-sized) by a stale claim.
    panel._releaseSlotRegion()
    // QoL: picking a search result clears the bar and returns focus to the list.
    // consumePendingResult already does this for keyboard, but mouse via
    // Entry's "result" jumpTo only resets the service query - the field and
    // mode linger. This handler makes both paths consistent and is idempotent
    // when consumePendingResult has already cleared them.
    // Defer focus/text work outside the navigation event: switching focus
    // synchronously while the Enter that triggered the jump is still
    // delivering would re-fire the same Enter on the new page's first row
    // (e.g. Settings -> General).
    if (!panel.searching && Menu.open) {
      Qt.callLater(() => {
        if (!panel.searching && Menu.open) {
          if (searchField.text !== "") searchField.text = ""
          if (panel.mode === "filter") focusCtrl.grabList()
        }
      })
    }
    // Leaving search replaces the whole projection with the page's rows:
    // an identity swap, not a row appearing or disappearing, and the
    // cursor is re-seated from the page's remembered frame.
    if (!panel.searching) panel.recomputeRows("rebuild")
  }
  onCurrentPageIdChanged: {
    // A new page means a new row set: any reveal claim from the page being
    // left (an open slot, a search projection) no longer names a row here,
    // and a stale out-of-bounds index would make pursuit scroll the new
    // list into empty space. Drop it before the transition/rebuild below.
    list.autoRevealIndex = -1
    list._followIdx = -1
    Menu.slotClosing = false
    list.contentY = 0
    let transitionGen = -1
    if (Menu.open) transitionGen = panel.beginPageTransition(false)
    else panel._invalidatePageCallbacks()
    // A new page is a new row set under a slide that masks the refill;
    // the old page's cursor index has no meaning here. Cancel any
    // deferred reveal/install left over from the leaving page first, so
    // it cannot land on the destination page.
    panel._invalidatePendingRows()
    panel.recomputeRows("rebuild")
    if (transitionGen < 0) return
    Qt.callLater(() => {
      if (transitionGen !== panel._transitionGen
        || !Menu.open || !panel._transitionActive) return
      const depth = panel._pendingSlideDepth
      if (depth < 0) return
      panel._pendingSlideDepth = -1
      listBox.slideFor(depth, transitionGen, true)
    })
  }

  // Open-slot lookup without a full scan. The tracked uid/index names the
  // row holding expanded or info-open state -> O(1) check on every rev bump.
  // Returns -2 when the tracked uid is absent, which is the only case that
  // falls back to the full scan below.
  function _trackedOpenIdx() {
    const uid = panel._openSlotUid
    const at = panel._openSlotIdx
    if (uid === "" || at < 0 || at >= panel.rowsModel.length) return -2
    const it = panel.rowsModel[at]
    if (!it || String(it.uid) !== uid) return -2
    if (Menu.isExpanded(it) || Menu.infoOpen(it)) return at
    return -2
  }

  // Full scan for the open-slot row, preferring the last (bottom-most) match.
  // Refreshes the tracked uid/index -> the rev handler stays O(1) while the
  // open row is stable, and the answer is the one a full scan gives.
  function _scanOpenSlot() {
    let found = -1
    let uid = ""
    for (let i = 0; i < panel.rowsModel.length; i++) {
      const it = panel.rowsModel[i]
      if (it && (Menu.isExpanded(it) || Menu.infoOpen(it))) {
        found = i
        uid = String(it.uid)
      }
    }
    panel._openSlotUid = uid
    panel._openSlotIdx = found
    return found
  }

  // One route for every service-side trigger of recompute/refresh/open.
  Connections {
    target: Menu

    // A bash guard verdict landed, so guarded rows appear or disappear
    // under the user exactly like showIf rows do. Same reveal intent, so
    // the same add/remove transitions run; only the 400ms guard debounce
    // in front of it is specific to this mechanism.
    function onGuardWhenChanged() {
      panel.recomputeRows("reveal")
    }

     function onResultsChanged() {
       // The projection is the caller's row set here, and whether it is
       // wide enough to install wholesale is the plan's business, not
       // this handler's. Off-search the candidate is the page's own rows
       // and compares equal, so the early return keeps this inert.
       panel.recomputeRows("reveal")
     }

    function onScopedActiveChanged() {
      // The "/" filter trims the page it was armed on, so the launch that
      // wanted the head of the untrimmed page is over - same reason as the
      // query above.
      panel._summonSeat = false
      // QoL: picking a filtered entry clears the filter bar and returns focus to the list.
      // Defer outside the activation event for the same reason as onSearchingChanged:
      // grabbing list focus synchronously while the Enter that triggered the
      // submenu push is still in flight would deliver that same Enter to the
      // new page (Settings push -> General).
      if (!Menu.scopedActive && Menu.open) {
        Qt.callLater(() => {
          if (!Menu.scopedActive && Menu.open) {
            if (searchField.text !== "") searchField.text = ""
            if (panel.mode === "filter") focusCtrl.grabList()
          }
        })
      }
      // Arming or clearing the "/" filter trims and restores the CURRENT
      // page's rows: rows leave and come back in place, so this is a
      // reveal like any other.
      panel.recomputeRows("reveal")
    }

     function onScopedRowsChanged() {
       panel.recomputeRows("reveal")
     }

     function onBundleChanged() {
      // Cache-reuse summons reassign the SAME containers, so a rebuild here
      // would burn hundreds of ms re-appending four-digit row counts.
      // Only genuinely new containers (different page objects) rebuild;
      // cursor/scroll reset happens via applyFrameState in onOpenChanged.
      // A new container also invalidates the text metrics: the label and
      // breadcrumb keys it brought are not the ones the maps hold, and a
      // reused summon must keep the warm ones.
      if (Menu.bundle === panel._seenBundle) return
      panel._seenBundle = Menu.bundle
      panel.clearMetricCaches()
      panel._quiesceDisarm()
      // Different containers mean a different row set outright, and the
      // metric maps above were just dropped with nothing to glide.
      panel.recomputeRows("rebuild")
    }

    // A store change flipped a showIf verdict - reveal/hide animated.
    // The reveal intent arms the add/remove transitions so the row slides
    // out from under its parent instead of popping.
    function onCondRevChanged() {
      panel.scheduleCondReveal()
    }

    // A store mutation can hand focus around (editor adoption, collapse);
    // reassertFocus is idempotent and near-free when focus is already
    // correct, so riding rev keeps the glue exact without polling.
    function onRevChanged() {
      panel.reassertFocus()
      // Any in-flow slot (expandSlot for selects/editors, descSlot for
      // Ctrl+I) must be fully revealed. Delegates handle it when
      // instantiated, but last-row slots may be outside viewport cache
      // when toggled, so ensure it generically here — no per-component code.
      // Tracked row first -> full scan only when the tracked uid is absent.
      let revealIdx = panel._trackedOpenIdx()
      if (revealIdx === -2) revealIdx = panel._scanOpenSlot()
      if (revealIdx >= 0) {
        list.autoRevealIndex = revealIdx
        // For last-row, force End to guarantee desc/dropdown not clipped
        // when contentHeight < view height (no scroll needed otherwise)
        if (revealIdx === panel.rowsModel.length - 1) list.revealEnd(revealIdx)
      } else {
        const cur = list.autoRevealIndex
        if (cur >= 0) {
          if (cur >= panel.rowsModel.length) {
            list.autoRevealIndex = -1
          } else {
            const it = panel.rowsModel[cur]
            if (it && !Menu.infoOpen(it) && !Menu.isExpanded(it)) list.autoRevealIndex = -1
          }
        }
      }
      // Expand/collapse rides the store rev: grow for the open dropdown,
      // fall back to the closed measure when it shuts. Idempotent -
      // assigning the settled width notifies nothing.
      panel._applyDropdownWidth()
    }

    function onOpenChanged() {
      if (Menu.open) {
        // The summon edge, and the only one: this runs on the open itself,
        // before any row set or fit belongs to the new page, which is what
        // makes it the right place to read the height the card is leaving
        // behind.
        panel.beginPageTransition(true)
        // A launch from closed wants its first entry. Held for as long as the
        // launch keeps installing, not spent on the first seat: the entry page
        // composes before its dead links and guard verdicts resolve, and the
        // install that puts a missing row back lands above the seat.
        panel._summonSeat = true
        panel.resetSeat()
        // Clear the cursor synchronously on both views. The new row set
        // installs deferred (and a reopen of the same row set does not
        // install at all), so the first frames would otherwise show the
        // outgoing view's stale index - the tail of whatever was open
        // before (Utilities "Close all windows", Main "Help"). Worse,
        // the index diff then carries that stale row across the
        // swap and clamps it to the new tail: parking head here is
        // discarded by the swap that follows. A cleared cursor (-1) holds
        // no bar and takes no lease, and the array swap keeps it cleared, so
        // every frame until the landing seat is empty rather than wrong;
        // the wholesale install below (or the identical-set callLater
        // path) seats the real head. Also drops the list's held highlight
        // geometry, which beginSwap would otherwise latch at the stale
        // tail row for the whole swap window.
        list._hlHeld = false
        list.seat(-1, "land", true)
        grid.currentIndex = -1
        // The model is out of step with the row set, so this is a
        // rebuild by definition, and the page slide begun above is what
        // masks the refill. Asking for row motion here would only mean
        // asking the plan a question it has to decline - a wholesale
        // install replaces the whole set, and gliding a clear-and-refill
        // means fading the whole page in over an empty list.
        //
        // Out of step is a real state here and not only between installs:
        // recomputeRows publishes rowsModel synchronously and the install
        // behind it is deferred, so a close that lands inside that window
        // leaves the row set composed and the model still holding the
        // previous one - and a pending install the close invalidated is
        // never coming.
        //
        // The comparison is the two key SEQUENCES - what the model last
        // wrote against what the row set now says. A plain array publishes
        // neither a row count nor a synchronization flag, so a "did the
        // model change?" question has no property left to ask it with.
        // Two key sequences answer
        // the same question exactly, and stay exact for two row sets of
        // equal length, which a count could not separate.
        if (panel.keySeq(panel.rowsModel) !== panel._lastSeq) {
          panel.recomputeRows("rebuild")
        }
        panel.shown = false
        showGate.restart()
        searchField.text = ""
        // No seat here, and the reason is the whole of A. recomputeRows above
        // composes rowsModel synchronously but installs it through the
        // deferred _queueRows path, so at this instant the ListView still
        // holds the OUTGOING page's rows. A seat taken now reads the row set
        // it is supposed to seat against one install too early: it measures
        // the previous bundle, and the swap that follows discards the result.
        //
        // That is not theoretical. The summon reached Utilities with the
        // warm view still holding index 3 from ThemePicker, no seat ran at
        // all, and the cursor was never placed anywhere - it was left where
        // the previous menu left it. Utilities composes 9 rows, a guard takes
        // one to 8, and the view clamps the inherited index to count-1, which
        // is the last row. "Close all windows" was not chosen; it was the
        // residue.
        //
        // The wholesale install already seats once the rows have landed
        // (_installRows), which is the only point at which a seat can be
        // correct. It is not the last word: the launch keeps installing
        // behind itself as dead links and guard verdicts resolve, and
        // _reseatFrameSel answers each of those while _summonSeat is armed.
        // When the summon reuses an identical row set there is no
        // install to wait for, so that case is queued explicitly - but
        // only when no install is in flight and the view already shows
        // these rows. Seating against an outgoing view (or one about to
        // be swapped) parks the cursor on a row that is gone a turn
        // later, and the native adjustment lands it on the tail: the
        // Help-first frame. The install's own landing seats whenever
        // anything is still pending.
        if (panel.keySeq(panel.rowsModel) === panel._lastSeq
          && panel._rowsPending === false
          && panel.keySeq(panel._records) === panel._lastSeq)
          Qt.callLater(() => panel.applyFrameState())
        focusCtrl.grabList()
        panel.queueFit()
      } else {
        panel._invalidatePageCallbacks()
        panel._condPending = false
        panel.mode = "list"
        // A place owed to a page that is being closed: the row it names is
        // gone with the page, and the next menu to open has a row set of
        // its own.
        panel._placeIdx = -1
        // A summon that closed before its seat ran leaves the launch armed, and the
        // next thing to read it is a submenu push - which owns a remembered
        // row of its own and must not be dragged to the top by a launch that
        // never landed.
        panel._summonSeat = false
        panel.resetSeat()
        // The close edge of the spawn probe. A summon interrupted before its
        // transition finished never settled, and a half-open window would let
        // the NEXT menu to open measure its first frame against this one's
        // baseline. An interrupted spawn has no verdict to give, so the record
        // goes rather than being reported.
        panel._spawnArmed = false
        panel._spawnPrevH = -1
        panel._spawnLayoutH = -1
        panel._spawnSettledH = -1
      }
    }
  }

  // --- deferred conditional reveals ---
  //
  // A showIf verdict flips the moment the parent option's value commits,
  // which is exactly when its select dropdown starts easing shut. Rows
  // gated by that option would otherwise pop in/out under the still-
  // animating parent. Defer the re-filter until the dropdown settles
  // (Menu.slotClosing - armed synchronously at the collapse choke point
  // before the value commits), then reveal with the usual add/remove
  // transitions.

  property bool _condPending: false

  function scheduleCondReveal() {
    if (!panel._condPending && !Menu.slotClosing) {
      panel.recomputeRows("reveal")
      return
    }
    // Dropdown still easing shut: park until the row's slot reports.
    panel._condPending = true
  }

  // Signal-driven instead of 16ms polling: Menu.slotClosing goes up
  // synchronously at collapse and comes down when the row's own slot says
  // its close landed, so the window is that slot's real slotMs + 20 - a
  // tall dropdown holds the re-filter until its own close ends instead of a
  // fixed guess. No blind polling.
  Connections {
    target: Menu
    function onSlotClosingChanged() {
      if (!Menu.slotClosing && panel._condPending && Menu.open) {
        panel._condPending = false
        panel.recomputeRows("reveal")
      }
    }
  }

  // Region math: the card is three anchored boxes - outer padding,
  // filter block, gap, then the list region. Nothing is nested inside a
  // positioner, so every gap is structural and symmetric by construction.
  // A page may declare its own ceiling (pickers stay compact); the
  // screen-share default applies otherwise. Follows the CURRENT page so
  // navigation resizes sensibly.
  //
  // Read off Menu.frame directly, not off currentPageId. currentPageId is a
  // cached projection of the same thing, and it only re-evaluates when
  // something reads it - so seating a new stack leaves this whole chain
  // clean and stale, answering from the page that was on screen before. A
  // clean binding is not re-evaluated by reading it, so nothing on the open
  // path could correct it in time: the first fit of a theme picker open was
  // committed against the previous ceiling and the resulting 542px card was
  // the first painted frame, one frame at a 177px lower top edge before the
  // corrected 365px fit landed. Depending on Menu.frame makes the chain dirty
  // the moment the stack is seated, which is the invalidation the cached
  // projection lacks.
  readonly property int pageMaxHeight: {
    const pg = Menu.pageById(Menu.frame ? Menu.frame.id : "")
    return pg && typeof pg.maxHeight === "number" && pg.maxHeight > 120
      ? Math.round(pg.maxHeight) : 0
  }

  readonly property real effMaxHeight: panel.pageMaxHeight > 0
    ? Math.min(panel.pageMaxHeight, panel.maxHeight) : panel.maxHeight

  readonly property real regionChromeH: Ui.chromeHeight(Ui.outerPad, Ui.filterH, Ui.listTopGap)

  readonly property real availListH: Ui.availHeight(panel.effMaxHeight, panel.regionChromeH)

  // The inter-row gap is the LIST's, read rather than assumed: every sum
  // below places the same gap the list places, and a literal in this file
  // would put the region's bottom edge off a row boundary the day a surface
  // spaced its rows differently.
  readonly property real rowSpacing: list.spacing

  // Whole-row sum, and whole-row prefix, both from the shared arithmetic in
  // RowMetrics. The row set is a PARAMETER and not `panel.rowsModel`: the fit
  // path sums a set that is not installed yet, and a question about "how tall
  // is this row set" is asked once or not at all. The grid branch in
  // snappedListH below stays local - it answers about cells, not rows.
  function _sumRowsH(rows, maxRows) {
    return RowMetrics.contentH(rows, maxRows, panel.rowRestHeight, panel.rowSpacing)
  }

  function _snappedRowsH(rows, avail, maxRows) {
    const limit = Math.max(0, Math.min(avail, panel.screenMaxListH))
    return RowMetrics.snappedH(rows, maxRows, limit, panel.screenMaxListH,
      panel.rowRestHeight, panel.rowSpacing)
  }

  // Library page-size cap: at most 10 entries visible at rest on list
  // pages, the rest under the center-lock scrolloff. Keeps long pages
  // compact everywhere instead of filling 70% of the screen. Falls back
  // to the screen share when 10 rows don't fit it. Dropdown growth still
  // reaches the screen ceiling (screenMaxListH below stays uncapped).
  //
  // This is a CEILING, not a target: it is the smaller of what the screen
  // allows and what 10 rows need, so a page whose rows are tall gets fewer
  // and a page that declares its own maxHeight gets fewer still. Nothing in
  // the tree declared one - three undeclared constants did, across the
  // pickers, and the smallest of them silently cost the theme picker half
  // its rows while making the card shorter than pages showing more.
  // `rowPolicyBound` below reports which of the two is holding the size, so
  // an override is something a reader can see rather than infer.
  readonly property real cappedAvailH: {
    const avail = panel.availListH
    // Grid cards never size from row heights (gridRows * gridSide, see
    // snappedListH/listRegionH and the width rule below), so summing the
    // row set here is pure first-open cost: every cache miss shapes through
    // the probes, and providers stamp per-row fonts (previewFontFamily)
    // that each resolve on first use.
    if (panel.gridMode) return avail
    if (panel.rowsModel.length === 0) return avail
    const total = panel._sumRowsH(panel.rowsModel, 10)
    panel._tenRowH = total
    return Math.min(avail, total)
  }

  // What the ten-row cap asked for on its own, and whether the screen (or a
  // page ceiling above it) is what actually decided the size. Diagnostic, and
  // the honest answer to "why does this page show N rows": below the cap
  // because the rows are tall, or because a page declared a ceiling.
  property real _tenRowH: 0
  readonly property bool rowPolicyBound: panel._tenRowH > 0
    && panel.availListH < panel._tenRowH

  // "Is a slot open, and how tall is the tallest one" - the panel's own
  // signal about in-flow expansion (ctrl+i description, dropdown, inline
  // editor, expandable body). It gates the fit and the sweep, so it must
  // read LIVE geometry and track both directions while a slot eases.
  //
  // It is a ROW height and nothing sizes the region from it: comparing it
  // against listRegionH as though it were one is a category error, because
  // a 218px row is not a 376px region, and that mismatch is why a growth
  // path keyed on it never fired for any page with more than one row. The
  // region's growth has its own quantity, in the one place the card and the
  // viewport read their height (growForSlot, fed by List.revealNeedH), so
  // the two questions stay separate: this one asks whether a slot is open,
  // that one asks whether the window has to move.
  readonly property real expansionNeedH: {
    const kids = list.contentItem.children
    let need = 0
    for (let i = 0; i < kids.length; i++) {
      const d = kids[i]
      if (!(d instanceof Entry)) continue
      if (d.descSlotH <= 0 && d.expandSlotH <= 0) continue
      if (d.height > need) need = d.height
    }
    return need
  }

  // How long a slot-driven resize should take: the claimed row's own slot
  // duration, so the card and the dropdown run at one speed. Read from the
  // list rather than from the panel's own slot walk: the row that owns the
  // claim is the list's business, and a claim on a row that is not the cursor
  // row (a description opened on a row the cursor has since left) still has to
  // be timed correctly.
  //
  // LATCHED, and that is the fix for the collapse running on the wrong clock.
  // The row publishes this only while its slot is open OR closing, and the
  // claim is released the instant the slot starts closing - so by the time the
  // region begins its way back down, the live figure is already 0 and the
  // naive read fell back to the fixed resize duration. Traced: a 120ms slot
  // collapsing over 160ms, the card visibly late. The latch holds the last
  // figure the row published, which is the slot's own duration, and clears
  // when the resize that used it has finished.
  readonly property int _slotRegionMs: {
    const live = panel.listView ? panel.listView.revealSlotMs : 0
    return live > 0 ? live : panel._slotMsLatch
  }
  property int _slotMsLatch: 0
  // The same figure, read the way the tween needs it: DIRECTLY, not through
  // the binding above. A binding is evaluated lazily, so reading
  // _slotRegionMs in the same synchronous turn that set _slotMsLatch returns
  // the pre-write value - which is how the open armed at the fixed resize
  // duration while the collapse armed at the slot's, and the two directions
  // of one motion ran on different clocks.
  function _slotDurationMs() {
    const live = list.revealSlotMs
    if (live > 0) return live
    return panel._slotMsLatch > 0 ? panel._slotMsLatch : Ui.resizeMs
  }

  // The resting size is what the fallbacks measure against, so it is
  // re-latched the moment the last slot closes and the live geometry is a
  // slot-inflated height again. On the closing edge only: expansionNeedH
  // changes every frame of an unfold, and writing the same resting value
  // on each of them is a per-frame write that can also land in the middle
  // of a fit's own commit.
  onExpansionNeedHChanged: {
    if (panel.expansionNeedH > 0) return
    if (!panel._transitionActive && !panel._heightAnimating && !panel._fitPending)
      panel._committedListH = panel.listRegionH
  }

  // Content height as of the last idle moment (no open/closing slot).
  // Diagnostic only since the per-text estimate cache landed: sizing reads
  // modelContentH() because sampled contentHeight extrapolates mid-layout
  // and latches stale on static pages. Kept for probe comparison.
  property real restingBufH: 0

  // Absolute ceiling from the screen (injected by MenuView); the normal
  // resting cap stays maxHeight. Only the growth path may exceed it.
  property real hardMaxHeight: 1200

  readonly property real screenMaxListH: Math.max(availListH,
    hardMaxHeight - panel.regionChromeH)

  function rowFontFamily(itm) {
    const family = itm && typeof itm.previewFontFamily === "string" ? itm.previewFontFamily : ""
    return family !== "" ? family : Ui.fontFamily
  }
  function rowHeightKey(text, family) {
    return String(family) + "\u0001" + String(text)
  }

  // Rest height of one row from the MODEL alone - the same numbers
  // Entry.qml derives from its texts (desc/expand slots are closed at
  // rest). Delegate-walking is forbidden here: ListView instantiates
  // lazily, so any sum over the created set changes while scrolling,
  // which resized the card on every tick and opened pages half-cut.
  // Line heights are per-text, shaped in recomputeRows ahead of the swap
  // and cached by string: glyph overflow is content-dependent ("App launcher"
  // renders a pixel taller than "Mg"), so proxies drifted +4px per sub
  // row and cut the snap. Fallbacks cover strings recalcWidth never saw.
  //
  // A height binding (cappedAvailH, restingContentHeight, listRegionH)
  // reaches this function, so a cold string is measured from inside that
  // binding's own evaluation. Nothing written here may be a property the
  // binding reads: the maps, the metric counters and _metricCap are all read
  // on the way here, and writing one re-invalidates the binding mid-pass.
  // Inserting a key and moving the probe family are both safe - a key
  // insertion is a member write and _rowProbeFamily is a plain property the
  // height bindings never read - and the miss accounting goes through
  // _metricFillMissed, which spends the shared budget held outside the
  // property system.
  function rowRestHeight(itm) {
    if (!itm) return Ui.rowMinH
    // Group separators carry the breadcrumb as their label; the delegate
    // (Entry sepH) adds the same top-plus-bottom breathing below, so the
    // two stay one number. Unlabeled separators keep the bare 10px line.
    if (itm.type === "separator") {
      const label = String(itm.label ?? "")
      if (label === "") return 10
      const family = panel.rowFontFamily(itm)
      const sepKey = panel.rowHeightKey(label, family)
      let sepH = panel._subHCache[sepKey]
      if (sepH === undefined) {
        panel._rowProbeFamily = family
        measureRowSub.text = label
        sepH = measureRowSub.implicitHeight
        panel._metricFillMissed()
        panel._subHCache[sepKey] = sepH
      }
      return sepH + 6
    }
    const family = panel.rowFontFamily(itm)
    const labelKey = panel.rowHeightKey(itm.label, family)
    let labelColH = panel._labelHCache[labelKey]
    if (labelColH === undefined) {
      panel._rowProbeFamily = family
      measureRowLabel.text = itm.label
      labelColH = measureRowLabel.implicitHeight
      panel._metricFillMissed()
      panel._labelHCache[labelKey] = labelColH
    }
    const light = typeof itm.light === "string" ? itm.light : ""
    if (light !== "") {
      // Theme rows: the title line, the swatch strip, and the one spacing unit
      // between them (Entry.qml's lbl + paletteRow). The strip is dots alone,
      // so the dot size is the whole line and nothing here needs a probe.
      labelColH += 1 + 8
    } else {
      const subText = panel.restSubText(itm)
      if (subText !== "") {
        const subKey = panel.rowHeightKey(subText, family)
        let sh = panel._subHCache[subKey]
        if (sh === undefined) {
          panel._rowProbeFamily = family
          measureRowSub.text = subText
          sh = measureRowSub.implicitHeight
          panel._metricFillMissed()
          panel._subHCache[subKey] = sh
        }
        labelColH += 1 + sh // Entry StyledText sub line
      }
    }
    return Math.max(Ui.rowMinH, labelColH + 2 * Ui.rowPadV)
  }

  // Sub line a row renders at rest: live provider value, the declared
  // sub, or the leading accent copy. Shared by rowRestHeight (estimate)
  // and recalcWidth (cache fill) so both shape the same string. The lead
  // counts: lead-only rows render two lines with an empty muted copy, and
  // the estimate must reserve both.
  function restSubText(itm) {
    if (!itm) return ""
    const ov = Menu.subFor(itm)
    if (ov !== "") return ov
    const sub = String(itm.sub ?? "")
    if (sub !== "") return sub
    // Same font metrics as the muted copy (fontXs both), so the height
    // cache stays exact.
    return typeof itm.subLead === "string" ? itm.subLead : ""
  }

  // Largest prefix of the MODEL's row heights that fits avail with no
  // entry cut in half. Deterministic per rowsModel: scrolling, delegate
  // creation and search swaps never change it for the same rows.
  // The inter-row gap is the list's own, read through rowSpacing above.
  function snappedListH(avail, maxRows) {
    const limit = Math.max(0, Math.min(avail, panel.screenMaxListH))
    if (panel.gridMode) {
      if (panel.gridSide <= 0 || panel.rowsModel.length === 0) return 0
      if (panel.gridSide > limit)
        return Math.min(panel.gridSide, panel.screenMaxListH)
      return Math.min(Math.floor(limit / panel.gridSide) * panel.gridSide,
        Math.min(panel.gridContentH, panel.screenMaxListH))
    }
    if (panel.rowsModel.length === 0) return 0
    return panel._snappedRowsH(panel.rowsModel, limit, maxRows)
  }

  // Full model content height - the resting "everything in one shot"
  // size. Replaces the stale contentHeight sampling as the region base.
  // The inter-row gap is the list's own spacing, which is not part of
  // delegate height but counts toward contentHeight.
  function modelContentH() {
    const rows = panel.rowsModel || []
    // Giant pages extrapolate from the head sample: the first listFullRows
    // rows are cache-backed through rowRestHeight, and the sole caller is
    // the list's restingContentHeight fits-check, where any giant set reads
    // scrollable either way, so the extrapolation is exact where it matters.
    if (rows.length > Ui.listFullRows) {
      let headH = 0
      for (let i = 0; i < Ui.listFullRows; i++) headH += panel.rowRestHeight(rows[i])
      return headH / Ui.listFullRows * rows.length + panel.rowSpacing * (rows.length - 1)
    }
    return RowMetrics.contentH(panel.rowsModel || [], 0, panel.rowRestHeight, panel.rowSpacing)
  }

  readonly property real listRegionH: {
    if (panel.gridMode) {
      if (panel.rowsModel.length === 0) return Math.min(Ui.emptyMinH, panel.cappedAvailH)
      return Math.min(panel.gridContentH, panel.snappedListH(panel.availListH))
    }
    const avail = panel.cappedAvailH
    if (panel.rowsModel.length === 0) return Math.min(Ui.emptyMinH, avail)
    if (panel._fitPending || panel.exactListH < 0) {
      // A fit in flight must show the size that is ALREADY on screen, not a
      // size re-derived from the row set that is arriving. Re-deriving is
      // wrong in one direction only, which is why this read as a filter-only
      // bug: _restingFallbackH answers from the committed height when there
      // is one, and a committed height is the size on screen, so a SHRINK
      // coincidentally got the right number. An EXPAND has no such accident
      // - the committed height is the old, smaller one - so the fallback
      // became the new, larger model height, the card jumped straight to it,
      // and the tween that followed then eased from the stale _animatedListH
      // to the height the card was already at. A resize that jumps, cancels
      // itself out and restarts, on every filter keystroke that grew the card.
      //
      // So the size on screen wins outright while a fit is pending. The
      // measured fit lands a turn or two later and the tween that follows it
      // carries the card across from here, which is the motion the whole
      // height chain exists to produce.
      const onScreen = panel._currentListH()
      const fallback = onScreen > 0 ? onScreen : panel._restingFallbackH()
      return Math.min(fallback, panel.screenMaxListH)
    }
    if (list.count === 0) return Math.min(Ui.emptyMinH, avail)
    // The resting region: the list's own size with nothing open. An open
    // slot does NOT change it - growth is a separate term applied where
    // the card and the viewport read their height (growForSlot), so a slot
    // can never reach the fitted size the next page transition or restore
    // measures against, and a slot that opened mid-transition cannot leave
    // a dropdown's height latched in exactListH.
    return Math.min(panel.exactListH, panel.screenMaxListH)
  }

  // Growth for an open slot. NOT a binding: it reads list.revealNeedH and
  // list.contentY, and the result feeds this panel's height - so as a binding
  // it would close a loop through the viewport and Qt would drop the value
  // (the live shell logged 70,000 binding loops that way). Called imperatively
  // by _latchClaim, which writes the result into the plain _claimListH the
  // height chain reads. A plain property written from a change handler cannot
  // be part of a binding cycle, which is the whole reason the arithmetic is
  // here and not in the list.
  //
  // `base` is the region the card is already showing. The claim is the row's
  // destination bottom in content coordinates, so the shortfall is measured
  // against where the content actually sits:
  //
  //   need <= base  the row is already inside the region; the dropdown is
  //                 revealed by the rows below it sliding down. No resize.
  //   need >  base  the region grows by exactly the shortfall.
  //
  // Past the screen ceiling the region stops and screenMaxListH is how far it
  // may go; growForSlot refuses anything past that, so the list scrolls the
  // dropdown instead.
  function growForSlot(base) {
    // A grid page is not a column of rows: its slots are cells, and the card
    // is sized by the grid's own geometry, so the column rule does not apply.
    if (panel.gridMode) return base
    return SlotGrowth.regionForSlot(list, base, panel.screenMaxListH, Ui.s)
  }

  // Width fits the longest visible entry: its label or sub line, plus
  // whatever the row reserves on the right (toggle, chevron, value slot,
  // dropdown) and the card's own chrome. Imperative recompute (NOT a
  // binding): measuring mutates the helper probes, so a declarative
  // contentW would depend on what it writes - an instant binding loop.
  //
  // The measurement itself, with nothing under or over it: the card is
  // exactly as wide as the widest row in it, so every row's text and every
  // value slot lands with room to spare. 0 means "not measured yet", and the
  // width binding answers it with the card's floor - a cold frame, not a
  // claim about the content.
  property real contentW: 0

  // Closed-row width: what recalcWidth measured with every dropdown shut.
  // The card rests here; an open select dropdown widens past it through
  // _applyDropdownWidth and falls back to it on close.
  property real _closedContentW: 0

  // Value probe. TextMetrics, because that is what Entry's own value slots
  // shape with (valueMetrics/selectMetrics/pctMetrics), so a trail reserved
  // here is the trail the slot renders. The LABEL probes below are Text for
  // the same reason: that is what a label renders with.
  TextMetrics {
    id: measureValue

    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
  }

  // Prototype matching Entry's sub line exactly (see Entry subMain):
  // it renders StyledText, whose line box runs ~2px taller than the
  // PlainText metrics above. The whole-row snap needs the real number.
  Text {
    id: measureSubStyled

    visible: false
    text: "Mg"
    font.pixelSize: Ui.fontXs
    font.family: panel._rowProbeFamily
    textFormat: Text.StyledText
  }

  // The group separator's own label: a Text, because a separator renders
  // one (Entry sepText) and the width has to be the width of what is drawn.
  Text {
    id: measureSepLabel

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: panel._rowProbeFamily
    font.bold: true
    textFormat: Text.PlainText
  }

  // Imperative per-text probes, shared by the width pass (recalcWidth) and
  // the height pass (rowRestHeight/cacheRowHeights): both read the same
  // probes and both cache by string, so one shaping serves both.
  //
  // They are Text items rather than TextMetrics on purpose. The two do not
  // agree: for the same string, family and size, TextMetrics.width is a
  // couple of pixels off Text.implicitWidth in either direction ("Deep
  // Forest" 84 vs 85.8, "Grape Soda" 79 vs 78). A reservation shaped with
  // TextMetrics is therefore a reservation for a string nobody draws, and
  // with no floor under it the card came up short by exactly that.
  // Never read from bindings - the passes own their text.
  Text {
    id: measureRowLabel

    visible: false
    font.pixelSize: Ui.fontL
    font.family: panel._rowProbeFamily
    textFormat: Text.PlainText
  }
  Text {
    id: measureRowSub

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: panel._rowProbeFamily
    textFormat: Text.StyledText
  }

  // Dropdown option probes. OptionRow paints its label at Ui.fontM under
  // the system family - never the value slot's fontS the trail is reserved
  // with and never the themed row family - so the width pass shapes
  // options here instead of reusing either of those probes.
  Text {
    id: measureOptLabel

    visible: false
    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
  }
  Text {
    id: measureOptLight

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
  }

  // Family the row probes shape with. Assigning font.family on a probe
  // writes the font GROUP, and Qt counts a group write from inside a
  // binding evaluation as a loop on that binding, whether or not the
  // binding reads anything of the probe, so a height binding that falls
  // back to measurement would report one per row. The probes take the
  // family from this plain property instead, which no height binding
  // reads, and the family still lands on the probe before its line box
  // is measured.
  property string _rowProbeFamily: Ui.fontFamily

  // Persistent width caches for recalcWidth - survives across keystrokes
  // so typing "c" -> "cu" reuses the same label/path shapings.
  property var _labelWCache: ({})
  property var _subWCache: ({})
  property var _optWCache: ({})
  // Per-text line-height caches for the whole-row snap (see
  // rowRestHeight). Same lifetime as the width caches.
  property var _labelHCache: ({})
  property var _subHCache: ({})

  // Every key in those five dictionaries is a row string, and row strings
  // are not a closed set: each bundle contributes its own labels, and each
  // search hit adds a breadcrumb key ("Settings > General > Displays"), so
  // a session that walks many bundles would otherwise grow the maps for as
  // long as the panel lives. One shared budget over all four keeps the
  // bound total; spending it drops every map at once rather than tracking
  // per-entry ages, which costs a re-shaping pass on the next open and no
  // bookkeeping in between. One giant page files ~1870 labels x height+width,
  // so 2048 evicts mid-open; 8192 covers it with headroom.
  readonly property int _metricCap: 8192
  // Keys the imperative recompute points have inserted (recalcWidth,
  // cacheRowHeights) since the last drop.
  property int _metricCount: 0
  // Keys the four maps hold, counted by BOTH fill paths. A member of a
  // plain object rather than a property of its own: the height-binding
  // fallback inserts from inside a binding evaluation and must not write a
  // reactive property the height bindings read, while the imperative
  // recount needs the same number so that one cap covers both paths
  // instead of each of them spending the whole of it.
  property var _metricLive: ({ n: 0 })

  // Text metrics are only valid for the font and the palette they were
  // shaped under, and only describe the rows of one bundle generation.
  // Both a bundle swap and a theme swap drop the maps; a font change
  // arrives with the theme swap, since a theme carries the font choice.
  // Drop the metrics and re-shape the model under whatever they are about to
  // become. Both the width and the height pass read the label/sub maps, and both
  // are shaped under one font and one theme: a change to either invalidates
  // every measurement, and neither pass runs again until the next row
  // install - which for an open card is the next navigation, or never.
  function reshapeMetrics() {
    panel.clearMetricCaches()
    panel.cacheRowHeights(panel.rowsModel)
    panel.recalcWidth()
  }

  function clearMetricCaches() {
    // The counters go first. Assigning a map notifies, and a height binding
    // re-evaluating right there refills the fresh map through rowRestHeight,
    // so zeroing them afterwards would drop the count of keys that are
    // still live and the budget would stop describing the maps.
    panel._metricLive.n = 0
    panel._metricCount = 0
    panel._warmedHeightsFor = null
    panel._labelWCache = ({})
    panel._subWCache = ({})
    panel._optWCache = ({})
    panel._labelHCache = ({})
    panel._subHCache = ({})
  }

  // Drop the maps without reassigning them: deleting a key emits no change,
  // so a caller inside a binding evaluation stays uninvalidated.
  // Reassignment is reserved for clearMetricCaches, which only runs from
  // imperative call sites.
  function _dropMetricMaps() {
    for (const cache of [panel._labelWCache, panel._subWCache,
      panel._optWCache, panel._labelHCache, panel._subHCache]) {
      // Over a snapshot of the keys: deleting the one for-in is standing on
      // makes the iteration skip the next, which strands half the map while
      // the budget reports the maps as empty.
      const keys = Object.keys(cache)
      for (let i = 0; i < keys.length; i++) delete cache[keys[i]]
    }
    // Maps dropped in place -> any warmed instance is cold again.
    panel._warmedHeightsFor = null
  }

  // Called on every cache miss from an imperative recompute, before the
  // value is stored, and it accounts for the key the caller is about to add.
  // Reports the eviction so the caller can re-shape what the drop took with
  // it. The budget is what the maps hold, which the height-binding fallback
  // spends from the same pool, and the live count is optional so this also
  // runs against a bare counter and cap.
  function _metricMissed() {
    const live = panel._metricLive
    if (panel._metricCount >= panel._metricCap
        || (live !== undefined && live.n >= panel._metricCap)) {
      panel.clearMetricCaches()
      if (live !== undefined) live.n++
      return true
    }
    panel._metricCount++
    if (live !== undefined) live.n++
    return false
  }

  // The same accounting for the fills rowRestHeight performs from inside a
  // height binding, and for the key the caller is about to add. The maps it
  // fills, the counters and _metricCap are all dependencies of that binding,
  // so a spent budget drops the maps IN PLACE, which holds all four inside
  // _metricCap without a reactive write. Such a drop strands _metricCount,
  // which the live count no longer depends on, so the stranded counter only
  // makes the imperative path drop earlier.
  function _metricFillMissed() {
    const live = panel._metricLive
    if (live.n >= panel._metricCap) {
      panel._dropMetricMaps()
      live.n = 0
    }
    live.n++
  }

  Connections {
    target: Theme
    function onColorsChanged() { panel.reshapeMetrics() }
  }

  // The system font lands asynchronously (a gsettings/ini probe behind
  // SystemFont.family) and every shaping here is done under it. A card
  // measured against the fallback family would keep that width once the
  // real one arrived - a few pixels short of every row - and nothing else
  // re-runs the pass until the next navigation.
  Connections {
    target: SystemFont
    function onFamilyChanged() { panel.reshapeMetrics() }
  }

  // Unified value-column width for perfect bar alignment (lib addition).
  // When a page shows ≥2 little bars, all value boxes share the same
  // width so bars form one column. Updated in recalcWidth().
  //
  // This is the PRODUCER of the shared column; MenuLib.valueSlotW is the
  // consumer rule Entry.qml applies, and the two are not a pair of halves
  // to be merged: recalcWidth measures the widest value on the page with
  // the shared probe, then mirrors the number into Menu.unifiedBarValueW
  // so the delegates can read one number instead of each re-deriving it.
  property int unifiedValueW: 0

  function _widestStepperWidth(items) {
    let maxW = 0
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it.type !== "range" && it.type !== "number") continue
      // The same string the row's own slot shapes (see _valueProbeText), so
      // the shared column is never narrower than a value it has to hold.
      measureValue.text = panel._valueProbeText(it)
      maxW = Math.max(maxW, measureValue.width)
    }
    if (maxW > 0) maxW = Math.min(maxW + 6, 140)
    return maxW
  }

  // Trailing width a row reserves. This is the SAME rule the row renders
  // (Entry's trail cluster), read from the same tokens and the same shared
  // slot formula, because the card has to be as wide as the row is and the
  // row is drawn before any card has measured anything. The widgets are
  // Ui.toggleW / Ui.chevronW / Ui.optMarkW - the very properties Entry
  // binds them to - and the value columns go through MenuLib.valueSlotW
  // with the pads and caps Entry passes it. A reservation that came up
  // short has nowhere to hide: there is no floor under it, so the label
  // elides.
  //
  // The one deliberate excess is a select's widest option rather than its
  // current one (Entry renders the current label): a value that grows when
  // the user picks a longer option must not re-cut the card under the row
  // that holds it.
  function trailWidthFor(itm) {
    switch (itm.type) {
      case "toggle":
        return Ui.toggleW
      case "submenu":
        return Ui.chevronW
      case "expandable":
        // The chevron only rides a row that has something to unfold.
        return (itm.desc !== undefined && itm.desc !== null && String(itm.desc) !== "")
          || (itm.body !== undefined && itm.body !== null && String(itm.body) !== "")
          ? Ui.chevronW : 0
      case "option":
        return Ui.optMarkW
      case "progress": {
        if (panel.unifiedValueW > 0) return Ui.barW + Ui.barGap + panel.unifiedValueW
        measureValue.text = "100 %"
        return Ui.barW + Ui.barGap + MenuLib.valueSlotW(0, measureValue.width, 4, 80)
      }
      case "number": {
        if (panel.unifiedValueW > 0) return panel.unifiedValueW
        measureValue.text = panel._valueProbeText(itm)
        return MenuLib.valueSlotW(0, measureValue.width, 6, 140)
      }
      case "range": {
        if (panel.unifiedValueW > 0) return Ui.barW + Ui.barGap + panel.unifiedValueW
        measureValue.text = panel._valueProbeText(itm)
        return Ui.barW + Ui.barGap + MenuLib.valueSlotW(0, measureValue.width, 6, 140)
      }
      case "select": {
        if (itm.var === "" && itm.onSelect !== "" && itm.onSelect !== undefined) return 0
        // Reserve for the widest option so the card never elides the value.
        let maxW = 0
        for (const o of (itm.options ?? [])) {
          measureValue.text = o.label
          maxW = Math.max(maxW, measureValue.width)
        }
        if (maxW === 0) {
          const cur = Menu.stateOf(itm).value
          let label = ""
          for (const o of (itm.options ?? [])) if (o.value === cur) { label = o.label; break }
          measureValue.text = label !== "" ? label : "value"
          maxW = measureValue.width
        }
        return MenuLib.valueSlotW(0, maxW, 0, 220)
      }
      case "text": {
        // Placeholder is what an empty row shows; the stored value is what
        // a filled one shows, and it is free-form (a path, a query). Both,
        // under the cap Entry applies to the slot itself.
        const v = String(itm.placeholder ?? "")
        measureValue.text = v !== "" ? v : "value"
        const phW = measureValue.width
        const cur = Menu.stateOf(itm).value
        const curS = String(cur ?? "")
        if (curS !== "") {
          measureValue.text = curS
          return MenuLib.valueSlotW(0, Math.max(phW, measureValue.width), 0, 180)
        }
        return MenuLib.valueSlotW(0, phW, 0, 180)
      }
      default:
        return 0
    }
  }

  // Card-coordinate width a select's inline dropdown needs so none of its
  // entries elides. The closed row only reserves the widest option through
  // the capped value slot (fontS, 220 cap), while OptionRow paints every
  // entry full-width at fontM: a long option fits the slot's reservation
  // on the row and still clips inside its own expansion. Shaped at
  // OptionRow's own size, through the same grid and inner margins the
  // expansion renders (optsGrid inset, option side margins, the gap kept
  // from an optional light note). Two-column dropdowns (>6 options) hold
  // half a row per cell, so the grid needs twice the widest entry plus
  // the column gap. Input kinds need nothing: their editors live in the
  // value slot the trail already reserves.
  function _dropdownNeedW(itm) {
    const opts = itm.options ?? []
    let maxOpt = 0
    let maxLight = 0
    for (let k = 0; k < opts.length; k++) {
      const o = opts[k] ?? {}
      const label = o.label ?? String(o.value ?? "")
      const light = String(o.light ?? "")
      const key = label + "\u0001" + light
      let shaped = panel._optWCache[key]
      if (shaped === undefined) {
        measureOptLabel.text = label
        let lw = 0
        if (light !== "") {
          measureOptLight.text = light
          lw = measureOptLight.implicitWidth
        }
        shaped = { o: measureOptLabel.implicitWidth, l: lw }
        panel._metricMissed()
        panel._optWCache[key] = shaped
      }
      if (shaped.o > maxOpt) maxOpt = shaped.o
      if (shaped.l > maxLight) maxLight = shaped.l
    }
    if (opts.length === 0) return 0
    // Card coordinates: rowChromeW carries the card padding, the row side
    // margins and the label spacing; the remainder is the dropdown's own
    // chrome (grid inset, option side margins, light gap) plus the text.
    if (MenuLib.optionColumnCount(opts.length) > 1)
      return panel.rowChromeW() + 5 * Ui.m - Ui.s + 16 + 2 * (maxOpt + maxLight)
    return panel.rowChromeW() + 2 * Ui.m - Ui.s + 8 + maxOpt + maxLight
  }

  // Width the open select dropdown needs right now, or 0 when no select
  // dropdown is open. Closed rows keep the capped value-slot reservation,
  // so the card rests at the closed measure and only grows for the
  // expansion that is actually on screen - then falls back on close.
  function _openSelectNeedW() {
    // Fast path: the tracked open-slot row, exact while one row is open.
    const at = panel._trackedOpenIdx()
    if (at >= 0) {
      const one = panel.rowsModel[at]
      if (one && one.type === "select" && Menu.isExpanded(one)
          && Array.isArray(one.options) && one.options.length > 0)
        return panel._dropdownNeedW(one)
    }
    // Otherwise (untracked, or an info row sitting beside an open
    // dropdown) take the widest open select on the page.
    let best = 0
    for (let i = 0; i < panel.rowsModel.length; i++) {
      const it = panel.rowsModel[i]
      if (!it || it.type !== "select" || !Menu.isExpanded(it)) continue
      if (!Array.isArray(it.options) || it.options.length === 0) continue
      const need = panel._dropdownNeedW(it)
      if (need > best) best = need
    }
    return best
  }

  // Grow the card for the open dropdown, shrink it back on close. The
  // width binding clamps to the viewport and onWidthChanged arms the
  // settle reveal, so the entries unveil with the growth instead of
  // starting a beat elided - the same treatment a wider page gets.
  function _applyDropdownWidth() {
    panel.contentW = Math.max(panel._closedContentW, panel._openSelectNeedW())
  }

  // What Entry's valueMetrics shapes for a numeric row: the widest reading
  // the row can show, or its own numeric fallback when it has none. The
  // provider's display override wins over the row's own, because that is
  // what the slot renders.
  function _valueProbeText(itm) {
    const widest = Menu.widestDisplayFor(itm)
    if (widest) return String(widest)
    return MenuLib.widestValueString(itm) || "888.88"
  }

  // What a row costs before any of its own content: the card's padding on
  // both sides, the row's side margins inside it, and the one spacing unit
  // the label column keeps clear of the trail cluster. Entry's own anchors
  // (mainLine's Ui.m margins, listBox's outerPad, labelCol's rightMargin)
  // are the same three numbers; the card adds them up per row and the row
  // applies them one by one, which is why they live in one function.
  function rowChromeW() {
    return Ui.outerPad * 2 + Ui.m * 2 + Ui.s
  }

  // Declared page width is deliberately NOT part of the width rule below.
  // A page that names one (settings sections, manifests, injected pickers)
  // carries it, and the settings schema names 420 for every page it
  // generates: a card sized by that number opens 50% wider than the rows in
  // it, and nothing about the page could narrow it again. Sizing reads the
  // rows, so a card is exactly as wide as its
  // content; Menu.pageById still carries `width` for a bundle that
  // declares one, but no card is sized by it.
  //
  // The width Behavior (see below) smooths navigation between pages whose
  // content measures differently.

  function recalcWidth() {
    if (panel.gridMode) {
      // A grid page has no row text to shape, and its columns are derived
      // FROM this width, so there is nothing to measure: the module default
      // is the grid's own size. Written on every grid pass so a grid summon
      // never inherits the list width of the page before it.
      panel._closedContentW = Ui.defWidth
      panel.contentW = Ui.defWidth
      return
    }
    const items = panel.rowsModel
    // Compute unified value-column width first so all little bars share one column.
    const hasMultipleBars = items.filter(it => it && (it.type === "range" || it.type === "progress")).length >= 2
    if (hasMultipleBars) {
      panel.unifiedValueW = panel._widestStepperWidth(items)
      // Publish to Menu singleton so delegates (Entry) can read it without
      // needing a direct panel reference (delegates are in separate file).
      if (typeof Menu !== "undefined" && Menu.unifiedBarValueW !== undefined) Menu.unifiedBarValueW = panel.unifiedValueW
    } else {
      panel.unifiedValueW = 0
      if (typeof Menu !== "undefined" && Menu.unifiedBarValueW !== undefined) Menu.unifiedBarValueW = 0
    }
    // The pass measures the page's own width and never consults the
    // viewport. The card is content-sized, so the window is sized to the
    // card, and a viewport read here reports whatever width the previous
    // contentW produced - on a cold summon the cardMinW floor, which is a
    // plausible few hundred pixels rather than an obviously unresolved
    // zero. Measured against that, a "stop once a row is already wider
    // than the screen" exit fires on row 0 and answers with that one row's
    // width instead of the page's widest, and the card then widens once the
    // window reports its real width.
    //
    // The viewport clamp belongs where it already is, in the width binding.
    // A content width that reads the viewport is circular: the window cannot
    // be sized until contentW is written, and contentW cannot be written
    // correctly until the window is sized.
    //
    // A giant page installs its head window only (see recomputeRows), so the
    // pass shapes at most that many rows, and every string it sees is a
    // dictionary hit the second time.
    const headN = Math.min(items.length, Ui.listFullRows)
    // SYNCHRONOUS: the card paints on the turn this runs in, and a
    // contentW that arrives a turn after that turn is a resize the user
    // watches the window do.
    //
    // The probes do not need the deferral. A Text answers implicitWidth from
    // its own content on the turn its text is assigned - a probe read cold,
    // before any layout pass, returns the same number as one read a turn
    // later ("grinning face with smiling eyes..." 476px both ways, and every
    // other string identical). What makes a cold read look unreliable is the
    // empty-page shape a deferral also produces: contentW stays 0, and 0 is
    // indistinguishable from "no rows".
    let maxRow = 0
    for (let i = 0; i < headN; i++) {
      const it = items[i]
      if (!it || !it.label) continue
      // Row chrome and icon column, both the row's own numbers
      // (rowChromeW, Ui.rowIconW). The column is reserved for an icon NAME
      // or a glyph (the emoji picker's rows), whichever Entry paints there -
      // reserving only the name left a glyph row 28px narrower than it
      // renders, and the label clipped against its own preview.
      let w = panel.rowChromeW()
      if (it.icon || (it.glyph !== undefined && it.glyph !== null
        && String(it.glyph) !== "")) w += Ui.rowIconW + Ui.s
      let labelW = 0
      {
        // Shaped in the row's OWN font: a theme row draws its name in the
        // font it previews, which is routinely wider than the system one
        // (rowFontFamily, the family the height pass already uses). The
        // cache is keyed by family AND string for the same reason the height
        // maps are (rowHeightKey): one string under two fonts is two
        // widths, and a font picker page holds both.
        //
        // Search results take this path too. A per-character estimate would
        // keep a keystroke off the shaping path, and it costs correctness
        // twice over: it guesses 7px per character against a
        // 13px font, so a result whose glyphs run wide comes up short, and
        // the 360 cap it shares with the measured branch elides the longest
        // names outright (the emoji picker: a 536px row in a 420px card).
        // Shaping a result row is a dictionary hit once the string has been
        // seen, and a miss is one TextMetrics assignment.
        const family = panel.rowFontFamily(it)
        const labelKey = panel.rowHeightKey(it.label, family)
        labelW = panel._labelWCache[labelKey]
        if (labelW === undefined) {
          panel._rowProbeFamily = family
          measureRowLabel.text = it.label
          labelW = measureRowLabel.implicitWidth
          panel._metricMissed()
          panel._labelWCache[labelKey] = labelW
        }
        // Sub line: lead + muted copy + trailing accent. The card must fit
        // the widest of label/sub, otherwise the subtext elides. Use the
        // displayed sub (provider override wins) so the measure matches
        // what Entry.qml actually paints.
        const dispSub = (typeof Menu !== "undefined"
          && typeof Menu.subFor === "function")
          ? (Menu.subFor(it) || it.sub) : it.sub
        const subKey = family + "\u0001" + String(it.subLead || "") + "\u0001"
          + String(dispSub || "") + "\u0001" + String(it.subAccent || "")
        let subW = panel._subWCache[subKey]
        if (subW === undefined) {
          let sw = 0
          panel._rowProbeFamily = family
          if (it.subLead) {
            measureRowSub.text = it.subLead
            sw += measureRowSub.implicitWidth + 4
          }
          if (dispSub) {
            measureSubStyled.text = MenuLib.styledMarkup(String(dispSub))
            sw += measureSubStyled.implicitWidth
          }
          if (it.subAccent) {
            measureRowSub.text = it.subAccent
            sw += (sw > 0 ? 4 : 0) + measureRowSub.implicitWidth
          }
          subW = sw
          panel._metricMissed()
          panel._subWCache[subKey] = subW
        }
        if (subW > labelW) labelW = subW
      }
      w += labelW
      // Every search result is a link forward, so the card reserves the
      // chevron on results whatever the row's own type is (Entry reads
      // `searchResult`, not the type, to decide).
      if (panel.searching) w += Ui.chevronW
      w += trailWidthFor(it)
      if (w > maxRow) maxRow = w
    }
    // Group separators / search breadcrumbs may be the widest line.
    if (!panel.searching) {
      for (let i = 0; i < headN; i++) {
        const it = items[i]
        if (!it || it.type !== "separator") continue
        const lbl = String(it.label || "")
        if (lbl === "") continue
        panel._rowProbeFamily = panel.rowFontFamily(it)
        measureSepLabel.text = lbl
        const sw = measureSepLabel.implicitWidth + panel.rowChromeW()
        if (sw > maxRow) maxRow = sw
      }
    }
    // The rows are installed and laid out at the card's CURRENT width
    // before this write lands, so a page whose content measures wider opens
    // with its longest copy already clipped. Arm the settle flag HERE, at
    // the decision, rather than on the first width change a turn later: the
    // rows then reveal with the growth instead of starting a beat elided.
    if (Math.abs(maxRow - panel.width) > 0.5) panel._armWidthSettle()
    panel._closedContentW = maxRow
    panel._applyDropdownWidth()
    // A drop in the width pass takes the height maps with it, and this runs
    // last in recomputeRows: re-shape the live model so the height bindings
    // never find it cold. Skipped when the pre-swap warm already shaped this
    // same instance -> one warm per install.
    if (items !== panel._warmedHeightsFor) panel.cacheRowHeights(items)
  }

  // Shape each distinct label/sub once for the whole-row snap (see
  // rowRestHeight). Runs in recomputeRows ahead of the rowsModel swap, so
  // height bindings always read warm caches; post-warmup iterations are
  // pure dictionary hits. Two passes: spending the budget drops every map,
  // so the rows shaped before that are cold again, and re-shaping them is
  // exactly what has to stay out of a binding evaluation. A page holding
  // more distinct strings than the cap cannot be warmed whole - its tail
  // rows measure themselves through the rowRestHeight fallback.
  function cacheRowHeights(items) {
    // Grid pages never read these caches: their height is pure model math
    // (gridRows * gridSide, see snappedListH/listRegionH), so shaping every
    // label/sub here is pure first-open cost. Grid height is pure model
    // math (gridRows * gridSide), so shaping every label/sub on a grid
    // page would pay thousands of synchronous Text shapings for numbers
    // no reader uses.
    if (panel.gridMode) {
      panel._warmedHeightsFor = items
      return
    }
    // Giant pages warm the head window only: shaping every label/sub on a
    // 4-digit page is seconds of open-time font work. Tail rows resolve
    // through the rowRestHeight fallback, which shapes on demand and stays
    // cache-backed afterwards. The stamp below still covers the whole
    // instance so the tail never re-triggers a full warm.
    const headN = Math.min(items.length, Ui.listFullRows)
    for (let pass = 0; pass < 2; pass++) {
      let evicted = false
      for (let i = 0; i < headN; i++) {
        const it = items[i]
        if (!it) continue
        const family = panel.rowFontFamily(it)
        const labelKey = panel.rowHeightKey(it.label, family)
        if (it.label !== undefined && it.label !== ""
            && panel._labelHCache[labelKey] === undefined) {
          panel._rowProbeFamily = family
          measureRowLabel.text = it.label
          if (panel._metricMissed()) evicted = true
          panel._labelHCache[labelKey] = measureRowLabel.implicitHeight
        }
        const subText = panel.restSubText(it)
        if (subText !== "") {
          const subKey = panel.rowHeightKey(subText, family)
          if (panel._subHCache[subKey] === undefined) {
            panel._rowProbeFamily = family
            measureRowSub.text = subText
            if (panel._metricMissed()) evicted = true
            panel._subHCache[subKey] = measureRowSub.implicitHeight
          }
        }
      }
      if (!evicted) {
        panel._warmedHeightsFor = items
        return
      }
    }
    panel._warmedHeightsFor = items
  }

  // Size animations stay disabled until the opening layout has fully
  // settled - otherwise the first real sizing catches the Behavior and
  // the card visibly grows on every summon (gap geometry rendering
  // mid-flight). Re-armed per open via onOpenChanged + showGate.
  property bool shown: false

  Timer {
    id: showGate

    interval: Ui.resizeMs + Ui.fastMs

    onTriggered: panel.shown = true
  }

  Behavior on width {
    enabled: MotionPolicy.enabled
      && (panel.shown || panel.searching || panel.scopedSearching)
    Glide { duration: Ui.resizeMs }
  }

  // The card is between two widths. The rows read this to reveal their copy
  // along with the growth instead of eliding it away and snapping it back
  // (see Entry.textReveal).
  //
  // Debounced off the card's own width, not read off the animation: Qt runs
  // a CLONE of a declared Behavior animation, so the declared Glide never
  // receives a target and its `running` is false forever (see Glide.qml).
  // Every frame of the glide re-arms the timer, so it fires one beat after
  // the LAST width change, and a flag that outlives its motion by that much
  // is inert anyway - a row whose copy fits is at reveal 1 either way.
  property bool _widthSettling: false

  function _armWidthSettle() {
    panel._widthSettling = true
    widthSettle.restart()
  }

  onWidthChanged: panel._armWidthSettle()
  readonly property bool widthSettling: panel._widthSettling

  Timer {
    id: widthSettle

    // Long enough that a dropped frame cannot clear the flag mid-glide
    // (seven frames at the shell's rate), short enough that the card is read
    // as settled about a beat after the motion that took it there.
    interval: Ui.fastMs
    onTriggered: panel._widthSettling = false
  }

  // No Behavior on height: the slot-driven region is tweened explicitly in
  // _syncSlotRegion, and the card has to read the SAME animated number as the
  // viewport (they are one box). A Behavior here would ease the card a second
  // time on top of the region tween, so the card would lag the viewport by a
  // frame of easing and the gap between them is exactly what clips the last
  // row. Page transitions and fits keep their own tween (heightAnim ->
  // _animatedListH), which renderedListH already prefers.
  //
  // The show gate still applies: before the opening layout settles, a real
  // size change must not animate (the card would visibly resize on summon).

  // The height the row set on screen implies, before any delegate of it has
  // been measured, or -1 when the question does not apply. One rule with two
  // situations, and they are the same rule: a transition with nothing to hold
  // asks the model, and so does a fit with nothing to hold. A summon is the
  // first - there is no card on screen to read a size off, so holding the
  // previous menu's box is what made a short menu paint a long menu's height
  // through the open fade and then snap. A navigation out of a row-less page
  // is the second. A navigation that HAS a height to glide from is never
  // asked: the hold outranks this in the chains below.
  //
  // The ten-row cap and the whole-row snap are the fit's own resting-page
  // arithmetic (see _modelListH); the only difference is that this reads no
  // delegate, so it can answer from inside a height binding. Both chains read
  // it, so the card and the viewport cannot disagree about the size the card
  // is being created at.
  //
  // A live slot and a height tween in flight outrank it: a dropdown opened
  // inside the opening window, and a search keystroke landing there, are
  // sizes the user asked for.
  readonly property real modelListH: {
    if (panel._heightAnimating || panel._slotRegionH > 0) return -1
    // The measured fit owns the card from the moment it lands, and it keeps
    // owning it while the NEXT fit is in flight. A committed fit is the size
    // on screen, so a pending measurement only has to be waited out: the hold
    // further down reads it (as does listRegionH's on-screen branch, which is
    // what this answer outranks) and the tween that follows carries the card
    // across from there.
    //
    // The `_fitPending` half of this test answered for a keystroke instead. A
    // row set changed, queueFit armed, and exactListH still carried the
    // PREVIOUS row set's measurement, so the provisional height below stood in
    // for a measurement that had not arrived: the card jumped straight to it,
    // and _startHeightTransition then eased from the remembered size to a
    // height the card was already at. That is the whole visible shape of a
    // filter tick - the pre-keystroke size, then the glide to the results -
    // and it repeats on every keystroke that changes the row count.
    if (panel.exactListH >= 0) return -1
    if (panel.rowsModel.length === 0) return -1
    // A HOLD owns the card whenever there is one. This is the same test both
    // height chains run before they ask, and it is the whole condition: a
    // transition that latched a visible height glides from it, and a model
    // answer that outranked the hold would put the card at its destination
    // before the tween started - the card jumps, the tween then eases from
    // the old height to the height it is already at, and the motion reads as
    // a jump that cancels itself out and restarts.
    //
    // So the model answers exactly when a hold does NOT exist and nothing has
    // been measured for this surface yet, which is two real cases and no
    // others:
    //
    //   a summon, which has no card on screen to read a size off and latches
    //     nothing (beginPageTransition) - there the model is the only size
    //     there is;
    //
    //   a navigation whose source page had no rows to hold, where the hold
    //     is zero and the destination is the only answer available.
    //
    // Both arrive with exactListH below zero, which is what the test above
    // reads: a summon clears it on the close edge (_invalidatePageCallbacks)
    // and a row-less source clears it when its own empty fit resolves, so the
    // two tests above say the same thing as this one and neither can admit a
    // keystroke into the model.
    //
    // Grid needs no exemption of its own: it asks through this same path, and
    // a grid entry page is routinely the first thing a summon shows.
    if ((panel._transitionActive || panel._heightAnimating)
      && panel._animatedListH > 0) return -1
    // A COMMITTED size is a hold too, and this is the one the tests above miss.
    // `exactListH` is the fit latch, and a fit that could not be measured drops
    // it to -1 while the card is still standing at the last committed height:
    // `tryFit`'s _rowsMoving branch does exactly that on every keystroke of a
    // filter whose rows glide in, and `fail()` does it whenever the budget runs
    // out, and an empty row set does it in queueFit. So `-1` on the latch is
    // not "this surface has no size", it is "this surface has no MEASUREMENT",
    // and the two are different questions.
    //
    // The cost of reading it as the first one is the whole visible artifact: the
    // card is showing _committedListH, `renderedListH` reads this answer above
    // listRegionH - whose pending branch is holding that same size on purpose -
    // and the card is at the provisional height a turn before the tween that
    // owns it starts. _startHeightTransition then reads _currentListH(), which
    // knows only the committed vocabulary, so the tween eases from the size the
    // card has just left: the card jumps to the target, springs back, and glides
    // to the target again. Measured on a backspace in the scoped filter, which
    // glides its rows on every keystroke: 212 -> 511 in one turn, then 293 ->
    // 358 -> 408 -> 511, a 300px jump and a full re-glide to the height it was
    // already at. A keystroke that NARROWS the row set shows one clean glide,
    // which is why it reads as a delete-only defect: narrowing lands a fit, and
    // a landed fit outranks this answer on its own.
    //
    // Both holds are the ones _currentListH() reads, in its order, so the two
    // chains cannot disagree about what the card is showing. The summon and the
    // row-less navigation are untouched: neither commits a height, so both
    // still reach the model, which is the only size they have.
    if (panel._claimListH > 0 || panel._committedListH > 0) return -1
    const provisional = panel.snappedListH(panel.availListH, 10)
    return provisional > 0 ? provisional : -1
  }

  readonly property real layoutListH: {
    // The page transition's own tween outranks the slot region, and outranks
    // the model too: navigation is the bigger motion and it owns the card for
    // its duration, gliding from the height the user can see.
    if ((panel._transitionActive || panel._heightAnimating)
      && panel._animatedListH > 0) return panel._animatedListH
    if (panel._slotRegionH > 0) return panel._slotRegionH
    // After the hold, never before it. A navigation that reached the model
    // answer first jumped straight to the destination and then animated to
    // where it already was; modelListH's own guard refuses to answer while a
    // hold exists, so the order here is the second half of that one rule.
    if (panel.modelListH > 0) return panel.modelListH
    // The viewport and the card are the same box, so they must agree on
    // the list height at ALL times - not merely once the fit settles.
    // Anything the viewport shows below the card's own height is drawn
    // where the card clips it, and anything the card shows above the
    // viewport is never drawn at all.
    //
    // They disagree for the whole of a height tween if the viewport keeps
    // reading listRegionH: the card follows `_animatedListH` while
    // listRegionH is still the previously committed fit. Measured on a
    // reveal, the gap reached a full row (49px) and GREW from zero, which
    // pushed the LAST row clean outside the viewport - it slid away,
    // vanished for the duration, and popped back when the fit landed. The
    // last row is the one that shows it because the bottom of the list is
    // where the two heights part company. Mirrors renderedListH, which is
    // the value the card itself is using.
    return panel._claimListH > 0 ? panel._claimListH : panel.listRegionH
  }

  // The card's own list height, and the value `height` is bound to. The same
  // chain as layoutListH above, in the same order, and it has to stay that
  // way: the card and the viewport are one box, and a disagreement between
  // them is a row drawn outside the card or clipped by it.
  readonly property real renderedListH: {
    if ((panel._transitionActive || panel._heightAnimating)
      && panel._animatedListH > 0) return panel._animatedListH
    if (panel._slotRegionH > 0) return panel._slotRegionH
    if (panel.modelListH > 0) return panel.modelListH
    return panel.listRegionH
  }


  // --- slot-driven region ---
  //
  // The card and the viewport are the same box, so they have to move as one.
  // That rules out a Behavior on the card's height: the card would glide while
  // listBox snapped to the target, and the gap between them is exactly what
  // clips rows (see layoutListH). So the region is animated ONCE, here, and
  // both boxes read this number.
  //
  // -1 means "no slot is driving the region", which is every page transition,
  // fit and resting state: those keep their own machinery (_animatedListH,
  // heightAnim) and fall through to the base.
  property real _slotRegionH: -1
  // The region the claim asks for, LATCHED. A plain property, written
  // imperatively by _latchClaim, and the only slot-driven input the height
  // chain reads. Two rules earn that:
  //
  // - It must not be a binding. The claim comes from the list and the result
  //   becomes this panel's height, so a binding would close the loop
  //   height -> claim -> height. A plain property written from a change
  //   handler sits outside the binding graph entirely.
  // - It must not be a per-frame re-read either. The claim is constant for
  //   the whole unfold (that is the library's contract), so re-reading it on
  //   a timer would buy nothing and would make the tween's own writes look
  //   like inputs.
  property real _claimListH: -1

  NumberAnimation {
    id: slotRegionAnim
    target: panel
    property: "_slotRegionH"
    easing.type: Easing.OutCubic
    duration: panel._slotRegionMs > 0 ? panel._slotRegionMs : Ui.resizeMs
    // The duration is assigned per arm in _armSlotRegion, from the same
    // sources read directly; the binding above is only the idle default.
    onFinished: {
      // A collapse RELEASES when it lands. Parking the region at the resting
      // size instead looks harmless and is not: _slotRegionH outranks the page
      // transition's own tween in the height chain, so a value left there is a
      // permanent override, and every later navigation to a page of a
      // different height is ignored - a short submenu arrives inside the tall
      // parent's box with the difference as empty space under the list, and
      // going back up does not restore it either. -1 hands the size back to
      // listRegionH, which is what the region was folded back to anyway.
      if (panel._claimListH < 0) {
        panel._slotRegionH = -1
        panel._slotMsLatch = 0
      }
    }
  }

  // Re-read the claim and re-arm. Every caller is an EVENT, never a frame:
  // the claim appearing, moving or going away, the duration changing, and a
  // seat landing (the scroll branch moves the content, which moves where the
  // claim lands relative to the viewport).
  function _latchClaim() {
    // Latch the slot's own duration while the row is publishing it. The claim
    // goes live a tick BEFORE the row reports a duration - Entry raises
    // `expanded` on the keystroke, and the slot's `open` binding (and with it
    // slotMotionMs) has not propagated yet - so the first arm may run at the
    // fallback pace rather than the slot's own. That is the prompt one: the
    // growth starts with the unfold instead of after it, and the recorded
    // figure still gives the collapse and the pursuit seat the true pace.
    //
    // MONOTONIC, for the same reason Entry's own latch is: a duration can only
    // be measured upwards, and the only thing that makes the live figure
    // smaller is the dropdown's content going away - which happens one tick
    // into a close, exactly when the collapse needs the number. Taking the
    // latest figure instead of the largest armed the open at 200ms and its
    // collapse at 120ms, the two directions of one motion on two clocks.
    const live = list.revealSlotMs
    if (live > panel._slotMsLatch) panel._slotMsLatch = live
    const base = panel._restingFallbackH()
    const want = panel.growForSlot(base)
    // Latch a GROWTH or nothing, never the resting size. growForSlot answers
    // "what would the region be", which with no claim is simply the base - and
    // latching that made the latch a second, staler copy of the region: it
    // then outranked listRegionH in the height chain, so every later fit,
    // filter keystroke or page change was computed and then ignored, and the
    // card kept the size it had. The latch means "a slot is driving the
    // region", and only a real growth says so.
    const grown = want > base + 0.5 ? want : -1
    // A pace-only change never re-arms the tween. The row publishes its
    // slot duration progressively as its content lays out, so a pace rise
    // with an unchanged target would restart the running tween on every
    // layout step: each restart resets the easing velocity and extends
    // the duration, and the region crawls instead of travelling - it lands
    // after the unfold it was meant to accompany, which reads as the
    // window jumping to the grown size afterwards. The latch above still
    // records the rise (the collapse and the pursuit seat both read it);
    // only the in-flight tween is left alone. A changed target still
    // re-arms through _syncSlotRegion below.
    if (grown > 0 && Math.abs(grown - panel._claimListH) < 0.5) {
      // Unchanged, but the list's copy of the target still has to track the
      // scroll offset: the claim is content-space, so a seat that does not
      // change the target can still change whether the region is short of it.
      list.growthH = panel._claimListH
      return
    }
    if (grown < 0 && panel._claimListH < 0 && panel._slotRegionH < 0) {
      list.growthH = -1
      return
    }
    // A slot is still open: never release an established growth mid-unfold.
    // Re-evaluating against the now-grown region can report "fits now",
    // which would drop _slotRegionH to -1 and flash/crop the window.
    // But a claim that has settled to a SMALLER value (a transient huge
    // claim from a mid-layout delegate) must not be trapped: keeping it
    // leaves the card grown to a height nothing fills. Release in that case.
    if (grown < 0 && panel._claimListH > 0 && list.revealNeedH > 0
        && !Menu.slotClosing
        && list.revealNeedH >= panel._claimListH - 0.5) {
      list.growthH = panel._claimListH
      return
    }
    panel._claimListH = grown
    list.growthH = grown
    panel._syncSlotRegion()
  }

  // Move the region to the latch.
  //
  // The show gate is honoured for a size the card is being OPENED at, not for
  // a slot the user just expanded: the gate exists so the first real sizing
  // after a summon does not animate (the opening layout is still settling and
  // the resize would be visible on open), and a dropdown opened inside that
  // window is not that resize - it is a deliberate user action, and gating it
  // made the card snap open instead. Traced: no "open" arm at all, only the
  // instant branch, for every dropdown opened in the first 280ms of a summon.
  //
  // So the gate's real question is "is the card still finding its size?", which
  // is the summon transition and its pending fit - both of which are states
  // this panel already tracks.
  function _syncSlotRegion() {
    const target = panel._claimListH
    const settling = panel._transitionActive || panel._fitPending
    if (!MotionPolicy.enabled || settling) {
      if (slotRegionAnim.running) slotRegionAnim.stop()
      const moved = target > 0 && Math.abs(target - panel._slotRegionH) > 0.5
      panel._slotRegionH = target > 0 ? target : -1
      if (!target) panel._slotMsLatch = 0
      // The region is reaching its destination in this turn with no tween, so
      // the row's slot must arrive with it rather than ease into a box that is
      // already there. Only when the region actually MOVED: re-latching an
      // unchanged claim is bookkeeping, and landing the slot on it would write
      // the row's height from inside the claim's own evaluation - a loop
      // through height -> revealNeedH -> this function.
      if (moved) panel._settleClaimRow()
      return
    }
    if (!(target > 0)) {
      // No claim. Fall back to the resting base, and that is a real tween on
      // the way DOWN - the collapse, which had no animation at all while the
      // region tracked the slot's live height. It releases on landing (see
      // slotRegionAnim.onFinished), so the region is transient: it exists only
      // while a slot is opening, open or closing, and the resting size belongs
      // to the ordinary chain.
      // The resting region plainly, for the same reason as the open branch:
      // this is where the card returns TO, and growForSlot would fold a claim
      // back in (there is none here, but the two must not depend on that).
      const rest = panel._restingFallbackH()
      if (!(rest > 0) || panel._slotRegionH < 0) {
        if (slotRegionAnim.running) slotRegionAnim.stop()
        panel._slotRegionH = -1
        return
      }
      if (Math.abs(rest - panel._slotRegionH) < 0.5) {
        if (slotRegionAnim.running) slotRegionAnim.stop()
        panel._slotRegionH = -1
        return
      }
      panel._armSlotRegion(rest)
      return
    }
    // A live claim. The tween starts from the RESTING region, so the base is
    // read plainly - growForSlot already applies the growth, and using it here
    // made `from` equal `to` and the card snapped open instead of animating
    // (traced: a 145 -> 558 resize with no "open" arm logged at all, because
    // the tween it should have started was never armed).
    if (panel._slotRegionH < 0) panel._slotRegionH = panel._restingFallbackH()
    if (Math.abs(target - panel._slotRegionH) < 0.5) return
    panel._armSlotRegion(target)
    panel._armSlotRegion(target)
  }

  // Tell the claimed row that its unfold resizes the region, so the row can
  // land its slots instead of easing them (see DropdownSlot.settle).
  //
  // Reached through the list's own claim rather than through a signal, because
  // the row is the thing that owns the slots and only the row knows whether
  // one is open. The claim is a delegate that may have been recycled, so the
  // identity is checked against the live index before it is touched.
  function _settleClaimRow() {
    const index = list.autoRevealIndex
    if (index < 0) return
    const row = list.itemAtIndex(index)
    if (!row || typeof row._settleSlots !== "function") return
    row._settleSlots()
  }

  // Hand the size back to the ordinary chain, at once. Navigation and close
  // are the only callers: both abandon the row the claim was about, and
  // neither wants a region tween interpolating towards a page that is no
  // longer on screen.
  function _releaseSlotRegion() {
    if (slotRegionAnim.running) slotRegionAnim.stop()
    panel._claimListH = -1
    panel._slotRegionH = -1
    panel._slotMsLatch = 0
    // The region stops owning the reveal the moment it lets go of the claim,
    // and the list has to hear that from here rather than infer it from its
    // own height: on a page where this panel REFUSES the growth (a dropdown
    // taller than the screen) the height never reaches the claim, and a
    // height-based test on the list's side would keep yielding to a region
    // that is not growing and never reveal the row at all.
    list.growthH = -1
  }

  function _armSlotRegion(to) {
    slotRegionAnim.stop()
    slotRegionAnim.from = panel._slotRegionH
    slotRegionAnim.to = to
    // Read directly, not through the _slotRegionMs binding: a binding is
    // evaluated lazily, so reading it in the same turn that set the latch
    // returned the pre-write value, and the two directions of one motion ran
    // on different clocks.
    slotRegionAnim.duration = panel._slotDurationMs()
    slotRegionAnim.restart()
  }

  Connections {
    target: panel.listView

    // The claim appearing, moving or going away, and the duration that tells
    // the tween how fast to travel. The resting base is read inside the
    // handler rather than watched, because it is derived from the row set and
    // a fit landing under an open slot must not re-arm the tween (the fit is
    // held while a slot is open - see tryFit).
    //
    // Deliberately NOT onHeightChanged: this tween WRITES the viewport height
    // (both boxes read _slotRegionH), so re-arming on it would restart the
    // animation from its own current value every frame - a tween that never
    // arrives, which is a region that crawls. The claim and its duration are
    // the only inputs; a base change under an open slot is not a thing that
    // happens, because the fit is held.
    function onRevealNeedHChanged() { panel._latchClaim() }
    function onRevealSlotMsChanged() { panel._latchClaim() }
  }

  width: {
    // Content decides the width: the widest row this page shows, plus
    // whatever that row reserves on the right (see recalcWidth) - the
    // title and the sub line at rest, the open dropdown's entries while
    // one is expanded (see _applyDropdownWidth).
    //
    // One floor, and a small one: never narrower than Ui.cardMinW, so a
    // page of six short submenus opens as a card rather than a strip. It
    // is also what an unmeasured card answers with, since with nothing
    // shaped yet there is no content to size to.
    //
    // Everything else that could hold a card open is out: the declared page
    // width the settings schema names 420 for on every page it
    // generated, 260 in the pass, 300 on the card, 420 for grids. Each of
    // them makes the card wider than the text in it, and the excess shows
    // up as empty gutter down both sides of every row.
    //
    // The outer clamp is the viewport, not a sizing rule: a card is
    // centered on the screen and must not run off either edge.
    const wanted = Math.max(panel.contentW, Ui.cardMinW)
    return Math.min(wanted, parent ? parent.width - 64 : Ui.defWidth)
  }

  // The footer must stay inside the card: the list ceiling accounts for
  // the outer padding too, or the total overshoots and the hints slide
  // past the window edge. The cap is hardMaxHeight so the growth path
  // can actually reach its ceiling; resting pages stay under maxHeight
  // via the region base.
  height: Math.min(panel.regionChromeH + panel.renderedListH, panel.hardMaxHeight)

  // --- spawn probe ---
  //
  // Whether a summoned card is born at its own size or arrives wearing the
  // previous menu's box. That question had exactly one answer before, and it
  // was a human watching a fade: the card was right or it visibly resized
  // under the scrim, and nothing in the tree could say which. This is the
  // number, so a regression is a value rather than an impression.
  //
  // The window of interest is the frames between `Menu.open` and the fit that
  // measures the delegates - the same window the show gate exists for, and
  // the one a spawn that remembers its predecessor spends painting the old
  // size. What must hold is that the first laid-out frame already carries the
  // summoned row set's height.
  //
  // Read the three figures, not the verdict: `carried` is the assertion, and
  // the numbers beside it are what make a failure diagnosable rather than
  // just detectable. `prevH` is the height the card had while the PREVIOUS
  // menu was up, so a failure here is self-describing - it names the box the
  // spawn inherited.
  //
  // A cold card has no previous height to compare against, and says so
  // (prevH -1, no verdict) instead of reporting a vacuous pass.
  property real _spawnPrevH: -1
  property real _spawnLayoutH: -1
  property real _spawnSettledH: -1
  property bool _spawnArmed: false
  readonly property bool _spawnCold: panel._spawnPrevH < 0

  // Armed on the summon edge and disarmed by the transition's own end, so
  // the probe measures the spawn and cannot keep sampling a card that has
  // since been navigated, resized or closed.
  //
  // A summon into a bundle whose entry page is the SAME page the card already
  // shows produces no height change at all, so there is no spawn to judge and
  // the record stays disarmed. That is not a gap: the artifact needs a size
  // change to be visible, and the case that cannot change size cannot carry
  // one.
  function _armSpawnProbe() {
    // Armed from beginPageTransition, which runs on the open edge before the
    // summoned row set is composed - so the card's height here is still the
    // one it is leaving, which is the whole point of the baseline.
    //
    // The guard is what makes a summon readable as a spawn. Menu.open and
    // Menu.frame are separate properties, so which one lands first is not
    // something to rely on: if the page change is seen first, this runs as a
    // navigation and the baseline would already be the NEW page's height,
    // which compares equal to the first frame and reports a vacuous pass.
    // Requiring the surface to be open - rather than merely not-yet-closed -
    // is the one condition that means "this is a spawn, not a navigation".
    if (!Menu.open) return
    panel._spawnPrevH = panel.height
    panel._spawnLayoutH = -1
    panel._spawnSettledH = -1
    panel._spawnArmed = true
  }

  // The first laid-out height of the spawn, latched once.
  //
  // A PROPERTY CHANGE, not a rendered frame. There is no render hook in this
  // shell to take (no FrameAnimation, no afterRendering anywhere in the tree),
  // and the gap that matters is not "which frame painted" but "which height
  // was the first one the spawn produced" - a question about the value, which
  // is what a binding change reports. On a correct spawn this latches the
  // summoned size; on the bug it latches the inherited one. Both are the
  // geometry in effect when the frame painted, because a QML binding
  // re-evaluates and paints in the same polish.
  //
  // `renderedListH` rather than `height`: this is a value read, so it
  // re-evaluates on demand and latches what the card is actually showing,
  // rather than whatever the `height` binding last produced - which for a
  // reused warm card is the PREVIOUS menu's value, and would make the probe
  // report the bug it exists to catch as the healthy state.
  onRenderedListHChanged: {
    if (panel._spawnArmed && panel._spawnLayoutH < 0)
      panel._spawnLayoutH = panel.regionChromeH + panel.renderedListH
  }

  // The verdict, as a number and a boolean. `drift` is the gap the user saw:
  // how far the first frame sat from where the card came to rest.
  function probeSpawn() {
    const settled = panel._spawnSettledH
    const first = panel._spawnLayoutH
    return {
      // False once the spawn has settled, which is the normal state between
      // summons: the record below is a completed verdict, not a live one.
      armed: panel._spawnArmed,
      cold: panel._spawnCold,
      prevH: Math.round(panel._spawnPrevH),
      firstH: first < 0 ? -1 : Math.round(first),
      settledH: settled < 0 ? -1 : Math.round(settled),
      // Positive means the first frame was TALLER than the resting size, the
      // direction a spawn that inherited a longer previous menu drifts.
      drift: (first < 0 || settled < 0) ? -1 : Math.round(first - settled),
      // A carried box, named as one: the first frame matched the previous
      // menu's height while the card went on to settle somewhere else.
      carried: !panel._spawnCold && first >= 0 && settled >= 0
        && Math.abs(first - panel._spawnPrevH) < 0.5
        && Math.abs(settled - panel._spawnPrevH) >= 0.5
    }
  }

  color: Ui.solid("background_0")
  border.width: Ui.cardBorder
  border.color: Ui.solid("background_3")
  // Contents ride along with the growing/shrinking card: anything past
  // the animated bounds stays clipped instead of painting over the desk.
  clip: true

  anchors.centerIn: parent

  onRowsModelChanged: {
    // Model swap drops the tracked open-slot row -> next rev re-scans once.
    panel._openSlotUid = ""
    panel._openSlotIdx = -1
    panel.queueFit()
    // No seat here. A wholesale install seats itself when its deferred
    // release lands (see _installRows), and an incremental apply has
    // nothing to seat: the keyed sync keeps the current item and shifts
    // its index, which is already the right answer. Re-running the
    // restore on top of that forced the view back to the pre-change
    // scroll offset and zeroed the highlight durations, so every
    // conditional reveal snapped the selection bar and yanked the
    // viewport mid-glide.
    Qt.callLater(panel.reassertFocus)
  }

  Component.onCompleted: Qt.callLater(panel.applyFrameState)

  // --- frame persistence ---

  // One choke point for every push: saves the parent frame first, so
  // back navigation restores the exact viewport at entrance regardless
  // of the entry path (click, Enter, search consume).
  function pushPage(pageId) {
    panel.checkpoint()
    Menu.push(pageId)
  }

  function track() {
    if (!Menu.open || panel.searching || panel.scopedSearching) return
    // Grid pages forget their cursor by design - every summon starts at
    // the top (see applyFrameState), so there is nothing to persist.
    if (panel.gridMode) return
    // A pending navigation selection outranks any currentIndex churn -
    // the ListView's stale index (e.g. 2 after a cached reopen) must
    // not be persisted before applyFrameState seats the intended row.
    if (Menu.pendingSel >= 0) return
    if (Menu.frame && Menu._restorePending[Menu.frame.id] === true) return
    if (list._sweeping === true) return
    // Cursor memory is user motion only: a native index adjustment after
    // a model swap (or a programmatic landing) must never become the
    // remembered seat that a later summon restores.
    if (list._lastSeatCause !== "step" && list._lastSeatCause !== "click") return
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rowsModel.length) return
    // Mid-swap guard: a dying delegate from the previous model is still
    // truthy here, but its payload no longer matches the model slot -
    // persisting that transient would clobber the remembered cursor.
    const row = panel.gridMode ? grid.currentItem : list.currentItem
    // A dying delegate from the previous model generation is still
    // truthy here; uid must match the live rowsModel slot or the
    // transient would clobber the remembered cursor.
    const mItem = panel.rowsModel[idx]
    if (!row || !mItem || !row.itm || row.itm.uid !== mItem.uid) return
    if (Menu.frame && Menu._restorePending[Menu.frame.id] === true) return
    Menu.saveFrame(idx, panel.gridMode ? grid.contentY : list.contentY, mItem.uid)
  }

  // Unconditional flush for push navigation: unlike track() it ignores
  // _sweeping / _restorePending, so entering a submenu mid-tween or
  // mid-restore still saves the live cursor and scroll.
  function checkpoint() {
    if (!Menu.open || !Menu.frame) return
    // A pending navigation selection means the model on screen is about to be
    // replaced by a DIFFERENT page's rows, so the index describes that page and
    // not this frame. applyFrameState consumes the intent and drops this
    // frame's record with it, so saving here would only leave a record
    // describing a projection that is already gone.
    if (Menu.pendingSel >= 0) return
    if (panel.gridMode) return
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rowsModel.length) return
    const itm = panel.rowsModel[idx]
    if (!itm) return
    // Filtered: the model is a trim of this page, not the page. Its index
    // would seat Back on whatever row sits at that number once the trim is
    // dropped, and its contentY is a short list's offset, which means nothing
    // to the full-height page underneath. Re-anchor on the uid - the trim
    // holds the very same item objects - and keep no offset, so the return
    // centres the row instead of a viewport this page never had.
    if (panel.searching || panel.scopedSearching) {
      const at = Menu.visibleIndexOfUid(Menu.frame.id, itm.uid)
      if (at < 0) return
      Menu.saveFrame(at, undefined, itm.uid)
      return
    }
    Menu.saveFrame(idx, list.contentY, itm.uid)
  }

  // Where a row sits in the LIVE model, by uid. Scanning the model rather than
  // the page's items is deliberate: the model is what the cursor has to land
  // on, and an install still in flight is exactly what can leave it out of
  // step with the frame - in which case this reports -1 and the caller keeps
  // the saved index. -1 when the row is not in the model at all.
  function indexOfUid(uid) {
    if (uid === undefined || uid === null || uid === "") return -1
    const rows = panel.rowsModel
    for (let i = 0; i < rows.length; i++) {
      const it = rows[i]
      if (it && it.uid === uid) return i
    }
    return -1
  }

  // View-agnostic cursor seat: both views share rowsModel ordering, so
  // one index drives either. `snap` threads to List.settle so restores
  // land instantly while keyboard steps still ease. `viewH` is the height
  // of the viewport the row is being placed in, for a viewport that is
  // still growing to it (see List.centerTarget).
  function viewSettle(idx, snap, viewH) {
    if (panel.gridMode) {
      grid.settle(idx, snap)
      return
    }
    list.settle(idx, snap, viewH)
  }

  // The seat every filtered install ends on, shared by the bundle search
  // and the "/" quick-filter. The best match is the head of the new
  // projection, and the list has to show it: an install that keeps the
  // current item would otherwise carry the cursor onto whatever survived
  // the re-rank. Re-ranks snap, so the viewport and the selection bar
  // stay stationary while results update instead of gliding/flickering.
  function seatFilteredHead() {
    // Both views scan forward from 0 to the first cell they can focus, so
    // a head a guard disabled lands on the best row that can take it.
    if (panel.gridMode) {
      grid.settle(0, true)
      return
    }
    list.settle(0, true)
  }

  // What the view is seated on, and what it is owed when the row set moves
  // underneath it. Qt's ListView holds the same ROW across the moves an
  // install publishes and only shifts its index, so an index taken before
  // the move names a different row after it - and a summon that took its
  // index against a half-built page is owed a row that page never had. An
  // index past the end of a shorter row set is the clamp that started this.
  property int _frameSel: -1
  property string _frameSelId: ""
  // The row that seat is for, named by identity. The index above describes
  // the row set that existed when it was taken; a row appearing or
  // disappearing above it turns that number into a different row, and only
  // the uid survives the move.
  property string _frameSelUid: ""
  // The identity epoch the seat was taken against. A cursor move is the
  // user's only when the row set has not shifted underneath it since, which
  // is what separates "arrowed down a row" from "an install carried the
  // cursor down with the row it was on".
  property int _seatEpoch: -1
  // The focused row's place in the view, owed until the page has settled.
  // -1 = nothing owed.
  //
  // A restore places the row in the turn it runs, and that turn is early:
  // the rows above the row have not measured yet and the card is still
  // resizing, so the place the row is put in is a provisional one - the
  // row lands near where it belongs and stays there. The place is owed
  // until the page settles, and then it is placed for real.
  property int _placeIdx: -1
  // Armed on the summon edge and held until the launch stops being one: a
  // menu launched from closed wants its first entry, every time. A fresh
  // summon already asks for that (openFile/openJson clear viewState and stack
  // the entry frame at sel 0), but the request was implicit - it rode in on
  // an empty viewState - so nothing downstream could tell it from a revisit.
  //
  // Held rather than spent, because a launch composes its entry page before
  // its dead links and guard verdicts resolve: the first install can be a
  // page with its head link missing, and the install that puts it back
  // inserts a row ABOVE the seat, which the view absorbs by carrying the
  // cursor down with the row it was already on. So this names the head of the
  // row set as it stands and re-resolves it after every install the launch
  // triggers. Submenu pushes, back navigation and search landings never set
  // it: they own a remembered row and must keep it.
  property bool _summonSeat: false

  // Forget the seat and every name it was held by. Both edges call this - the
  // summon before arming, the close instead of arming - because the owner id
  // has to go with it: a stale one would make the entry page's first
  // applyFrameState read as another page's seat and retire the launch.
  function resetSeat() {
    panel._frameSel = -1
    panel._frameSelId = ""
    panel._frameSelUid = ""
    panel._seatEpoch = -1
  }

  // A launch ends when the cursor is somewhere the launch did not put it.
  // Read from the index-change handler, where the row the view settled on is
  // known: a key step, a click or a search landing names a row that is not
  // the seat, and from then on the row set owns the cursor again.
  //
  // An install moves the cursor with the row it is on and advances the epoch
  // to do it, so while the row set is still shifting under the seat an index
  // change says nothing about who asked for it - that is the launch's own
  // convergence, and the re-assert is what answers it.
  function releaseSummonSeat() {
    if (!panel._summonSeat) return
    if (panel._epoch !== panel._seatEpoch) return
    const idx = panel.gridMode ? grid.currentIndex : list.currentIndex
    // A cleared cursor is nowhere, not somewhere the launch did not put
    // it: programmatic clears (summon edge, pre-write) must not retire the
    // launch, or the re-seat they exist for never runs and the cursor is
    // left cleared - or later seated from stale memory.
    if (idx < 0) return
    const rows = panel.rowsModel
    const it = idx >= 0 && idx < rows.length ? rows[idx] : null
    if (!it || String(it.uid) !== panel._frameSelUid) panel._summonSeat = false
  }

  // What the view is seated on now, by identity. Recorded after every seat so
  // the next row-set change re-anchors on the row rather than on the number
  // it happened to hold.
  function recordSeat() {
    const idx = panel.gridMode ? grid.currentIndex : list.currentIndex
    const rows = panel.rowsModel
    const it = idx >= 0 && idx < rows.length ? rows[idx] : null
    panel._frameSel = idx
    panel._frameSelId = Menu.frame ? Menu.frame.id : ""
    panel._frameSelUid = it ? String(it.uid) : ""
    panel._seatEpoch = panel._epoch
  }

  // Re-assert the remembered seat, for the frame that asked for it and only
  // once the row set can carry it: across frames this would move a cursor
  // nobody asked to move, and an index past the end is the clamp that
  // started this.
  //
  // A launch is the exception and names no index at all: its seat is the head
  // of the row set as it stands, because the row set it was first given is
  // not the row set the launch ends up showing.
  function _reseatFrameSel() {
    if (!Menu.open || !Menu.frame) return
    if (Menu.frame.id !== panel._frameSelId) return
    if (panel.searching || panel.scopedSearching) return
    if (panel.gridMode) return
    if (panel._summonSeat) {
      // An empty row set is not a page with no head, it is a page that has
      // not arrived: recording a seat against it would leave the launch
      // looking landed.
      if (list.count <= 0) return
      viewSettle(0, true)
      panel.recordSeat()
      return
    }
    if (panel._frameSel < 0) return
    // The row the seat was taken FOR, not the number it was taken at: a guard
    // verdict landing, a section revealing or a dead link coming back can all
    // move rows in between, and a stale index then names whatever now sits
    // there. The index is only the fallback for a row the model no longer
    // carries.
    let want = panel._frameSel
    const at = panel.indexOfUid(panel._frameSelUid)
    if (at >= 0) want = at
    if (want >= list.count) return
    if (list.currentIndex === want) return
    viewSettle(want, true)
    panel.recordSeat()
  }

  // Put the focused row back where it belongs, now that the page has
  // settled: the rows above it have measured and the card owns its final
  // size, so the place the follow policy puts the row in can be named for
  // real.
  //
  // The user has moved on by the time this runs - a key step or a wheel
  // notch takes the cursor elsewhere - and then the row they are on now is
  // the one that matters: the follow policy places it, and this placement
  // is dropped.
  function _placeFocusedRow() {
    const idx = panel._placeIdx
    if (idx < 0) return
    panel._placeIdx = -1
    if (panel.listView.currentIndex !== idx) return
    // The placement, not a seat: the cursor is already on the row, and a
    // landing would take the stillness lease and hold the selection bar
    // still for a gesture the user has not made. The viewport has settled
    // by now, so the placement is against the height it really has.
    panel.listView.placeRow(idx)
    panel.listView.forceLayout()
  }

  function applyFrameState() {
    // Consume a navigation-intended selection exactly once; it outranks
    // anything scroll tracking persisted during the model swap.
    const pending = Menu.pendingSel
    Menu.pendingSel = -1
    if (panel.searching || panel.scopedSearching) {
      if (list.count > 0 || grid.count > 0) viewSettle(pending >= 0 ? pending : 0)
      return
    }
    const f = Menu.frame
    if (!f) return
    let sel
    let y
    // -1 = keep whatever viewSettle positioned (jump-to-row navigation):
    // forcing y=0 after positionViewAtIndex would yank a below-the-fold
    // target back to the top and hide the cursor.
    let keepY = false
    if (pending >= 0) {
      sel = pending
      keepY = true
      const vs = Object.assign({}, Menu.viewState)
      delete vs[f.id]
      Menu.viewState = vs
    } else if (panel.gridMode) {
      // Grid pages always summon at the top - no remembered cursor.
      sel = 0
      y = 0
    } else {
      const saved = Menu.savedFor(f.id)
      sel = saved ? saved.sel : f.sel
      y = saved ? saved.y : 0
      // Re-anchor on the row the seat was taken FOR, not on the number it was
      // taken at. A guard batch landing, a section revealing or a trim dropped
      // can all move rows in between, and a stale index then names whatever
      // now sits there. The uid survives all of those; the index is only a
      // fallback for a row the model no longer carries.
      if (saved && saved.uid !== undefined) {
        const at = panel.indexOfUid(saved.uid)
        if (at >= 0) {
          // The saved offset described the viewport with THIS row in it. Once
          // the row has moved, that offset points elsewhere, so drop it and
          // let the seat centre the row instead.
          if (at !== sel) y = undefined
          sel = at
        }
      }
    }
    // A launch from closed wants its first entry, whatever the view happens
    // to be holding. Stated here rather than left to the empty viewState, so
    // the seat below and every re-assert after it name the same row.
    //
    // What ends the launch is a request naming something else: a pending
    // selection is a push or a search landing, and a frame this seat does not
    // already own is a back navigation returning to a page that kept a
    // remembered row of its own. Everything else is the launch still
    // settling - its own installs keep the intent armed, and their re-assert
    // resolves the head against whatever they installed.
    if (panel._summonSeat
      && (pending >= 0 || (panel._frameSelId !== "" && f.id !== panel._frameSelId)))
      panel._summonSeat = false
    if (panel._summonSeat && pending < 0) {
      sel = 0
      y = 0
    }
    // All pages settle synchronously so the first paint is already at
    // the restored cursor - no row-0 frame, no top-to-center tween.
    // Snap only when no explicit pending selection exists (restore);
    // jump-to-row navigation keeps its settle-and-correct behavior.
    // Seating reads viewport geometry, so seating into the restored
    // viewport never emits a corrective scroll for track to persist.
    const snapRestore = pending < 0
    // The viewport the rows are about to sit in: the card is still the size
    // of the page being left, and it grows to this page's own height as the
    // transition runs. A placement against the height the viewport has NOW
    // names the centre of a viewport that no longer exists - and the engine
    // corrects the view to the real one, visibly, as the card grows. The
    // placement is asked for against the height the viewport is growing to.
    const viewH = panel.gridMode ? 0 : panel._modelListH()
    // Restore path only (pending leaves y undefined): exact seat via
    // the lib - index plus entrance scroll, no glide, no trailing
    // re-center. settle() would recenter deferred and wipe the scroll.
    const seatScroll = snapRestore && !panel.gridMode && y !== undefined
    if (seatScroll) list.restoreAt(sel, y)
    else viewSettle(sel, snapRestore, viewH)
    panel.recordSeat()
    // The place the focused row goes, owed until the page has settled: the
    // seat above runs while the rows above the row are still measuring and
    // the card is still resizing, so the place it puts the row in is a
    // provisional one. The row is the one the cursor is on, not the one the
    // seat asked for: a seat that scanned forward onto the next selectable
    // row landed on a different row than it was given.
    panel._placeIdx = panel.gridMode ? -1 : list.currentIndex
    // Back-navigation seat zeroes highlight durations for two ticks via
    // restoreAt: re-arm at once when settled so a wrap one frame later
    // still glides instead of snapping.
    if (!Menu.slotClosing && panel.expansionNeedH <= 0) list._endSweep()
    Qt.callLater(() => {
      if (!Menu.frame || Menu.frame.id !== f.id || panel.searching) {
        Menu.endRestore(f.id)
        return
      }
      Menu.endRestore(f.id)
    })
  }

  // --- keyboard routing ---

  // Single route for the search field's text edits. While the "/" scoped
  // filter is armed, edits narrow the CURRENT page; otherwise they drive
  // the global bundle search.
  function onFieldEdited(text) {
    if (panel.scopedSearching) Menu.setScopedQuery(text)
    else Menu.setQuery(text)
  }

  function currentRow() {
    return panel.gridMode ? grid.currentItem : list.currentItem
  }

  // Grid motion lives in GridList (common/ui/GridList.qml); these stay
  // thin wrappers so cursor correctness keeps one implementation.

  // Remove the current cell from its backing set via its declared forget
  // command. "@forget" routes to the owning page's api (native JSON
  // state); anything else runs as a shell command template. No-op on
  // cells without one; the owner refreshes the grid asynchronously.
  function forgetCurrent() {
    const idx = grid.currentIndex
    if (idx < 0 || idx >= panel.rowsModel.length) return false
    const itm = panel.rowsModel[idx]
    if (!itm || typeof itm.delCommand !== "string" || itm.delCommand === "")
      return false
    const value = itm.value !== undefined ? String(itm.value) : ""
    if (itm.delCommand === "@forget") {
      const api = Menu.dynamicApi(panel.currentPageId)
      if (!api || typeof api.forget !== "function") return false
      api.forget(value)
      return true
    }
    Menu.runCommand(itm.delCommand, value)
    return true
  }

  function moveGridCell(step) { grid.moveCell(step) }

  function moveGridRow(step) { grid.moveRow(step) }

  function stepCurrent(direction) {
    if (panel.gridMode) return
    const row = list.currentItem
    if (row && row.hasStepper) row.stepBy(direction)
  }

  function moveSelection(direction) {
    if (panel.gridMode) {
      panel.moveGridCell(direction)
      return
    }
    const prev = panel.currentRow()
    // An open dropdown consumes the arrows first.
    if (prev && prev.dropdownOpen && !prev.confirmOpen && prev.moveOption(direction)) return
    if (!list.move(direction)) return
    // Leaving a row collapses whatever it had open (info bodies, dropdowns
    // and editors alike) - nothing trails the cursor. The seat tracks
    // live layout while the slots ease shut (follow retarget), so no
    // close-then-move sequencing is needed.
    const now = panel.currentRow()
    if (prev && now && prev !== now && prev.expanded) prev.collapse()
    panel.closeTrailingInfo()
  }

  // ctrl-i descriptions belong to the ACTIVE entry: moving the cursor
  // closes whatever description was left open behind. The close is
  // deferred out of the ListView's own notification path - mutating
  // service state mid-layout is re-entrancy fuel for escape handling.
  property var _lastCursorItem: null

  function closeTrailingInfo() {
    const idx = list.currentIndex
    const cur = idx >= 0 && idx < panel.rowsModel.length ? panel.rowsModel[idx] : null
    const prev = panel._lastCursorItem
    panel._lastCursorItem = cur
    if (prev && prev !== cur && prev.uid !== undefined && Menu.infoOpen(prev)) {
      Menu.setInfo(prev, false)
    }
  }

  // Deferred search-result consumption (see activateCurrent).
  property var pendingResult: null

  // Upper bound on the MOTION half of whenSettled's wait, in wall-clock ms.
  // It is the sum of the longest of each term `quiet` reads - the fit's own
  // retry budget (24 * fitRetryTimer.interval), Menu's slot-close bound
  // (Ui.slowMs + 60), the scroll sweep List caps at List._sweepMaxMs, the
  // height tween (Ui.resizeMs) and the page slide (Ui.fastMs + 20) - plus the
  // install latency in front of them. Only reached when the panel never
  // comes to rest; a normal jump fires as soon as it does, and a jump that
  // does reach this runs its request late rather than dropping it.
  readonly property int _settleWaitMs: 2000

  // Settle-gated expand: runs `fn` once the teleport has landed and
  // every animation finished.
  // Conditions match what the issue requires: full menu shown and
  // all motion done.
  //
  // The two halves of the predicate are bounded differently because they are
  // different kinds of wait. `rowOk` is structural - the target delegate has
  // to exist and be under the cursor - and the install that creates it is a
  // pair of idle hops behind the call that asked for it, so a dozen attempts
  // covers it and a longer budget would only poll a loop with nothing left
  // to do. `quiet` is the panel's own motion, and every term in it is a tween
  // of known length: a jump to a row far down the list runs List's scroll
  // sweep behind the height tween the fit arms, which together outlast a
  // dozen attempts, so a callback bounded by attempt count alone would
  // expire mid-scroll and be dropped -
  // on precisely the long jumps that needed it. That half is bounded in
  // wall-clock time instead, and the two bounds are not interchangeable: only
  // the motion one can be overrun and still delivered, because only it is
  // reached with a row in hand.
  //
  // Neither bound drops a request that could still run. The motion deadline
  // runs `fn` late rather than discarding it, and the structural bound has
  // nothing to run - no delegate means no target. The one remaining exit is
  // the menu closing, where the panel the request was aimed at is gone.
  function whenSettled(fn, guard) {
    const deadline = Date.now() + panel._settleWaitMs
    let tries = 0
    const tick = () => {
      tries++
      const row = panel.currentRow()
      if (row && (guard ? guard(row) : true)) {
        const quiet = !panel._swapping && !Menu.slotClosing
          && !panel._fitPending && !panel._transitionActive
          && !panel._heightAnimating && !slideAnim.running
          && list._sweeping !== true && list.moving !== true
          && Menu.pendingSel < 0
        if (quiet) {
          fn(row)
          return
        }
        // The deadline is a LATENCY cap, not a drop threshold. The row is
        // here and the guard passed, so the work is well-defined; running it
        // late against a panel that has not quite finished moving is a
        // visible-but-recoverable state, whereas dropping it is an action the
        // user asked for and never gets, with nothing on screen to say why.
        // A tween that outlives the budget is the panel's problem to fix,
        // not the request's to lose.
        if (Date.now() >= deadline) {
          fn(row)
          return
        }
      } else if (tries > 12) {
        // The other bound, and it is not the same kind of thing: there is no
        // row to operate on, so there is nothing to run late. The delegate
        // the jump was aiming at never materialised - a page that went away,
        // or a guard still false - and the request has no target.
        return
      }
      if (!Menu.open) return
      // Two turns per attempt, not one, because the install that creates the
      // target delegate is a pair of idle hops behind the call that asked for
      // it. Re-polling on every single turn spent the structural budget
      // before the row could arrive; Idle.run also coalesces, so several
      // waiters share one flush instead of each holding the loop open.
      Idle.run(tick, 2)
    }
    tick()
  }

  function consumePendingResult() {
    const it = panel.pendingResult
    panel.pendingResult = null
    if (!it || !Menu.open || it.pageId === undefined) return
    const capturedQ = (Menu.query || "").toLowerCase().trim()
    if (!Menu.jumpTo(it.pageId, it.row)) return
    // A selection leaves search behind: bar cleared, cursor on the row.
    Menu.clearQuery()
    searchField.text = ""
    focusCtrl.grabList()
    if (list) {
      if (typeof list.unpinHighlight === "function") list.unpinHighlight()
      list._keepCursor = false
    }
    // Submenu results teleport into their menu; action results run
    // right away - search results are commands, not parking spots.
    if (it.type === "submenu" && it.page) {
      // The teleport never displays the parent: the push below supersedes
      // its landing before anything installs, so seed the parent's memory
      // here - the link, uid-anchored with no offset, the way checkpoint
      // saves a filtered landing - and retire its restore. Left alone the
      // parent keeps no memory (checkpoint early-returns on the pending
      // landing jumpTo just armed) and a stale restore-pending, so Back
      // falls back to the raw stack slot instead of the entered link.
      const linkAt = Menu.visibleIndexOfUid(it.pageId, it.uid)
      if (linkAt >= 0) Menu.saveFrame(linkAt, undefined, String(it.uid))
      const vs = Object.assign({}, Menu.viewState)
      delete vs[it.page]
      Menu.viewState = vs
      Menu.endRestore(it.pageId)
      panel.pushPage(it.page)
      return
    }
    if (it.type === "action") {
      panel.activateItem(it)
      return
    }
    if (it.type === "select") {
      // The option the query names, so the dropdown opens with the cursor
      // on it instead of on whatever the row's stored value left there.
      const exact = MenuLib.bestOptionIndex(it.options, capturedQ, it.label)
      const targetUid = it.uid !== undefined && it.uid !== null ? String(it.uid) : ""
      panel.whenSettled((row) => {
        row.setExpanded(true)
        if (exact >= 0) Qt.callLater(() => {
          const r2 = panel.currentRow()
          if (r2 && r2.isSelect && r2.itm && String(r2.itm.uid) === targetUid) r2.optionIndex = exact
        })
      }, (row) => row.isSelect)
      return
    }
    if (it.type === "number" || it.type === "range" || it.type === "text") {
      panel.whenSettled((row) => row.openEditor(), (row) => row.hasEditor)
      return
    }
    // Non-action hits just teleport – second Enter will operate it.
  }

  function activateCurrent(shift) {
    // A debounced scoped query may still be pending: apply it now and
    // re-drive activation once the install it queues has landed, so Enter
    // never picks from a set the field has already left behind.
    if (Menu.flushScoped()) {
      Qt.callLater(() => panel.activateCurrent(shift))
      return
    }
    // Grid cells: activation dispatches on row type - actions run their
    // command, submenu cells push their target page (category links);
    // nothing else can appear on a well-formed grid page. Holds while
    // filtering too: an emoji query filters within its own grid, and the
    // field's onAccepted routes here - reading the list view then would
    // use an unbound index and swallow Enter.
    if (panel.gridMode) {
      const idx = grid.currentIndex
      if (idx < 0 || idx >= panel.rowsModel.length) {
        viewSettle(Math.max(0, grid.currentIndex))
        return
      }
      const itm = panel.rowsModel[idx]
      if (!itm || itm.selectable === false) {
        viewSettle(Math.max(0, grid.currentIndex))
        return
      }
      if (itm.type === "submenu" && itm.page !== "") {
        panel.pushPage(itm.page)
        return
      }
      panel.activateItem(itm)
      return
    }
    const row = list.currentItem
    if (!row) {
      // Transient delegate rebuild (model swap): re-seat the cursor so
      // the very next press lands instead of silently vanishing.
      list.settle(Math.max(0, list.currentIndex))
      return
    }
    if (panel.searching) {
      // Route from the merged copy itself - order-proof against any
      // results/rowsModel misalignment. Consume OUTSIDE the input event:
      // jump/push/grabList switch focus mid-delivery otherwise, and the
      // same Enter re-fires on whatever row ends up under the cursor.
      panel.pendingResult = panel.rowsModel[list.currentIndex]
      Qt.callLater(panel.consumePendingResult)
      return
    }
    // Generic confirm (recording stop etc.) lives in same slot as dropdown
    if (row && row.confirmOpen) {
      row.activate()
      return
    }
    if (row.dropdownOpen) {
      row.pickCurrent()
      return
    }
    row.activate()
  }

  // Run one action item outside the Entry pipeline: page-command bundles
  // share plain-action semantics. Pages owned by a service may provide an
  // insert callback for usage/state - it runs alongside the shell command
  // so clipboard/paste still happens via the page's vb-emoji-insert.
  function activateItem(itm) {
    if (!itm || itm.type !== "action") return
    // Grid cells and search hits never become an Entry delegate, so this is
    // the decision point for the rows that bypass activate() above. `value`
    // rides along because a grid cell paints exactly that string and no
    // label, so the label alone would not say what the user picked.
    // DEBUG, and gated for the reason the other two choice sites are: the
    // question "why did the shell just do that" is a DEBUG question, and a
    // menu row is not an answer to it on its own. `value` still rides along,
    // because a grid cell paints exactly that string and no label.
    const api = Menu.dynamicApi(panel.currentPageId)
    if (api && typeof api.insert === "function") {
      api.insert(String(itm.value ?? ""))
    }
    if (itm.call !== "") {
      Menu.runCall(itm.call, itm.value !== undefined ? itm.value : "")
      if (itm.keepOpen !== true) Menu.close()
      return
    }
    let cmd = itm.command ?? ""
    if (cmd === "") {
      const pg = Menu.pageById(panel.currentPageId)
      if (pg && typeof pg.command === "string") cmd = pg.command
    }
    if (cmd !== "") {
      Menu.runCommand(cmd, itm.value !== undefined ? itm.value : "")
    }
    if (itm.keepOpen !== true) Menu.close()
  }

  function toggleInfoCurrent() {
    const row = list.currentItem
    if (row) row.toggleInfo()
  }

  function escapeChain() {
    // "/" trigger armed: Esc while typing only de-focuses the box - the
    // query text and the trim both stay, so arrow-key browsing keeps the
    // filtered page. A second Esc (list mode) drops the trim and restores
    // the full page; it never falls through to the cross-page search.
    // Empty input is the exception: there is nothing to keep filtered,
    // so one Esc both de-focuses AND leaves Filter mode instead of
    // parking in list-focus with an empty trim still armed.
    if (panel.scopedSearching) {
      if (panel.mode === "filter" && searchField.text !== "") {
        focusCtrl.grabList()
        return
      }
      Menu.clearScoped()
      searchField.text = ""
      focusCtrl.grabList()
      return
    }
    if (panel.searching) {
      Menu.clearQuery()
      if (searchField.text !== "") searchField.text = ""
      focusCtrl.grabList()
      return
    }
    // Leaving the filter never closes the menu - Esc hands control back
    // to the rows so browsing can continue.
    if (panel.mode === "filter") {
      focusCtrl.grabList()
      return
    }
    const row = panel.currentRow()
    // An open ctrl+i description is the outermost layer on this row -
    // Esc peels it first, before touching expansions or the stack.
    if (row && Menu.infoOpen(row.itm)) {
      Menu.setInfo(row.itm, false)
      return
    }
    if (row && row.expanded) {
      row.collapse()
      return
    }
    if (Menu.stack.length > 1) {
      Menu.pop()
      focusCtrl.grabList()
      return
    }
    Menu.close()
  }

  // Backspace with empty input leaves Filter mode the way Esc with empty
  // input does - but it never pops the stack or closes the menu. Fires only
  // from the field (InputField.backspaceEmpty), so the field is empty here
  // by construction; the scoped trim is still armed (empty query shows the
  // full page), which is exactly what has to go.
  function backspaceEmptyChain() {
    if (panel.scopedSearching) {
      Menu.clearScoped()
      if (searchField.text !== "") searchField.text = ""
      focusCtrl.grabList()
      return
    }
    if (panel.searching) {
      Menu.clearQuery()
      if (searchField.text !== "") searchField.text = ""
      focusCtrl.grabList()
      return
    }
    if (panel.mode === "filter") {
      focusCtrl.grabList()
      return
    }
  }

  function scrollBy(factor) {
    if (panel.gridMode) {
      grid.pageBy(factor)
      return
    }
    list.pageBy(factor)
  }

  // End jumps. Both branches ask the same edge scan, so Home and End cannot
  // land on different rows.
  //
  // The grid branch is GridList's own. The list branch is not List.jumpEnd's:
  // that one re-seats through the center-lock follow, which puts a jumped-to
  // row in the middle of the viewport, while the reveal keyboard steps get
  // here want Home top-visible and End bottom-visible instead of stranding
  // the cursor past the edge. The edge scan is shared (MenuLib), the landing
  // is this panel's.
  function jumpEnd(last) {
    if (panel.rowsModel.length === 0) return
    if (panel.gridMode) {
      grid.jumpEnd(last)
      return
    }
    const target = MenuLib.selectableEdge(panel.rowsModel, panel.isSelectableIndex, last)
    if (target >= 0) {
      list.seat(target, "step")
      list.reveal(target)
    }
  }

  function isSelectableIndex(index) {
    const m = panel.rowsModel
    if (index < 0 || index >= m.length) return false
    return m[index].selectable === true && !Menu.isDisabled(m[index])
  }

  function focusIndex(index) {
    if (!panel.isSelectableIndex(index)) return false
    if (panel.gridMode) grid.currentIndex = index
    else list.seat(index, "click")
    return true
  }

  // --- search-field word editing (readline parity with LauncherPanel) ---

  readonly property alias _searchInput: searchField.input

  function eraseWord() {
    if (panel.mode !== "filter") return
    searchField.eraseWord()
  }

  function wordBackward() {
    if (panel.mode !== "filter") return
    searchField.wordBackward()
  }

  function wordForward() {
    if (panel.mode !== "filter") return
    searchField.wordForward()
  }

  // Key names the routing table understands, with their Qt codes. The
  // table is a plain .js library and may not name a Qt constant, so the
  // vocabulary lives here - once, and the reverse lookup is derived from
  // it so a name and its code cannot drift. A press whose code is not in
  // here routes nowhere, which is what a key the table has no case for
  // did before.
  readonly property var _keyCodes: ({
    left: Qt.Key_Left, right: Qt.Key_Right,
    up: Qt.Key_Up, down: Qt.Key_Down,
    tab: Qt.Key_Tab, backtab: Qt.Key_Backtab,
    home: Qt.Key_Home, endKey: Qt.Key_End,
    pageUp: Qt.Key_PageUp, pageDown: Qt.Key_PageDown,
    escape: Qt.Key_Escape, space: Qt.Key_Space,
    backspace: Qt.Key_Backspace, deleteKey: Qt.Key_Delete,
    returnKey: Qt.Key_Return, enterKey: Qt.Key_Enter,
    plus: Qt.Key_Plus, equal: Qt.Key_Equal,
    minus: Qt.Key_Minus, underscore: Qt.Key_Underscore,
    keyI: Qt.Key_I, keyF: Qt.Key_F, keyD: Qt.Key_D
  })

  readonly property var _keyNames: {
    const byCode = ({})
    for (const name in panel._keyCodes) byCode[panel._keyCodes[name]] = name
    return byCode
  }

  // What the routing table gets to look at, and nothing more.
  //
  // The three row-derived fields are getters, not values: the staged
  // confirmation probe reaches a provider callback, and reading it for
  // every keystroke would spend one on a decision only Delete reads. The
  // cursor row itself is read at most once per press, and only on the
  // routes that name it.
  function keyRouteCtx(event) {
    let row = null
    let rowRead = false
    const cur = () => {
      if (!rowRead) {
        row = panel.currentRow()
        rowRead = true
      }
      return row
    }
    return {
      key: panel._keyNames[event.key] || "",
      ctrl: (event.modifiers & Qt.ControlModifier) !== 0,
      meta: (event.modifiers & Qt.MetaModifier) !== 0,
      mode: panel.mode,
      grid: panel.gridMode,
      field: searchField.focused === true,
      text: event.text,
      get editor() { const r = cur(); return !!r && r.editorOpen === true },
      get del() {
        const r = cur()
        return !!r && !!r.itm && typeof r.itm.delCommand === "string"
          && r.itm.delCommand !== ""
      },
      get confirm() {
        const r = cur()
        return !!r && Menu.confirmFor(r.itm) !== null
      }
    }
  }

  // Single key route for both modes. The routing table decides which
  // effect a press takes; this dispatches it. Every delegate read, cursor
  // write and focus grab is below - the table above it takes state, never
  // an item, so focus ownership stays entirely in this file.
  function handleKey(event) {
    const r = MenuLib.keyRoute(panel.keyRouteCtx(event))
    if (r === null) return
    const arg = r.arg
    switch (r.name) {
      case "info":
        panel.toggleInfoCurrent()
        break
      case "filter":
        focusCtrl.grabFilter()
        break
      // A cell with no forget command leaves the key alone, so a Delete
      // on a read-only grid page still does nothing instead of closing.
      case "forget":
        if (panel.forgetCurrent()) event.accepted = true
        return
      case "cell":
        panel.moveGridCell(arg)
        break
      case "gridRow":
        panel.moveGridRow(arg)
        break
      // The caret already took the key; nothing is left to do but say so.
      case "swallow":
        break
      case "delete": {
        const drow = panel.currentRow()
        if (drow) drow.requestDelete()
        break
      }
      case "confirm":
        panel.activateCurrent(false)
        break
      case "activate":
        panel.activateCurrent(event.modifiers & Qt.ShiftModifier)
        break
      case "activateNoShift":
        panel.activateCurrent(false)
        break
      case "move":
        panel.moveSelection(arg)
        break
      case "step":
        panel.stepCurrent(arg)
        break
      // An open dropdown takes the side arrow first; a numeric row
      // behind it steps.
      case "optionOrStep": {
        const row = panel.currentRow()
        if (row && row.dropdownOpen && !row.confirmOpen
          && row.moveOption(arg * row.optionColumnStride)) {
          event.accepted = true
          return
        }
        panel.stepCurrent(arg)
        break
      }
      case "escape":
        panel.escapeChain()
        break
      case "end":
        panel.jumpEnd(arg)
        break
      case "page":
        panel.scrollBy(arg)
        break
      case "scoped":
        // "/" arms the in-page quick-filter: focus the box and trim the
        // CURRENT page's rows. The trigger itself is not part of the
        // query.
        Menu.beginScoped()
        searchField.text = ""
        focusCtrl.grabFilter()
        break
      case "query":
        // Pages that declare filterDefault narrow themselves instead of
        // searching the bundle: arm the scoped filter on the first
        // keystroke. onFieldEdited already routes edits by scopedActive,
        // so arming here covers every entry path with no lifecycle of its
        // own (close resets it like a manual "/" arm).
        if (!Menu.scopedActive) {
          const pg = Menu.pageById(Menu.frame ? Menu.frame.id : "")
          if (pg && pg.filterDefault === true) Menu.beginScoped()
        }
        // Apply the key the way the field WOULD have, rather than assuming
        // the field is empty. Reaching this route means list mode, and list
        // mode does not mean the field is blank: `PanelFocus.grabFilter`
        // declares the mode only once the field reports focus, so a press
        // that arrives before the compositor has granted keyboard focus
        // leaves the mode at "list" with the character already in the field.
        // Replacing the field's text with the bare key on the next press
        // threw the earlier one away, so a word typed into that window came
        // out as its last letter - the search looked like it needed several
        // characters before it took. `type()` is the field's own pipeline, so
        // the query is set by the same `edited` signal every other keystroke
        // uses, and the caret ends up where the field would have put it.
        searchField.type(searchField.text + arg)
        focusCtrl.grabFilter()
        break
      // The switch named this key and a guard declined it: the field
      // keeps it, so it goes through unclaimed.
      default:
        return
    }
    event.accepted = true
  }

  Keys.onPressed: event => panel.handleKey(event)

  // Focus glue - editor rows always win; otherwise delegate to
  // PanelFocus so list/filter ownership matches other panels.
  // Every path that can move focus lands here (field focus, model swaps,
  // open/close, rev). No polling.
  function reassertFocus() {
    if (!Menu.open) return
    const row = list.currentItem
    if (row && row.editorOpen) {
      row.grabEditorFocus()
      return
    }
    // Keep PanelFocus' serviceVisible in sync (it watches Menu.open)
    // and let it decide list vs filter ownership.
    if (searchField.focused || focusCtrl.mode === "filter" || panel.searching) {
      focusCtrl.mode = "filter"
      if (!searchField.focused) searchField.grabFocus()
      return
    }
    if (!focusCtrl.keySink.activeFocus) focusCtrl.keySink.forceActiveFocus()
  }

  function debugSetCurrentIdx(idx) {
    list.seat(idx, "step")
    return list.currentIndex
  }

  // Ground truth for `menu probe`. A function, not a binding: the IPC
  // call is the only reader, so nothing should re-evaluate this on every
  // cursor move or geometry tick.
  function probeSnapshot() {
    const row = list.currentItem
    return JSON.stringify({
      autoRevealIndex: list.autoRevealIndex,
      contentY: list.contentY,
      page: panel.currentPageId,
      searching: panel.searching,
      query: Menu.query,
      mode: panel.mode,
      layout: panel.gridMode ? "grid" : "list",
      index: panel.gridMode ? grid.currentIndex : list.currentIndex,
      count: panel.gridMode ? grid.count : list.count,
      hlY: !panel.gridMode && list.highlightItem ? Math.round(list.highlightItem.y) : -1,
      // Motion-gate ground truth for headless wrap diagnosis: which term
      // of highlightMotion is false, and what the highlight would do.
      hlMoveMs: panel.gridMode ? grid.highlightMoveDuration : list.highlightMoveDuration,
      hlMotion: panel.gridMode ? grid.highlightMotion : list.highlightMotion,
      swapping: panel._swapping,
      animsOn: MotionPolicy.enabled,
      // Row-sync ground truth: the flag the add/remove transitions read,
      // and why the plan answered the way it did. A blocker naming
      // "wide-projection" means the row set changed and the install was
      // still wholesale; "ranked-projection" means a search re-rank
      // installed incrementally with the row motion held off.
      syncAnimated: panel.syncAnimated,
      syncIntent: panel._lastSyncPlan ? panel._lastSyncPlan.intent : "",
      syncBlocker: panel._lastSyncPlan ? panel._lastSyncPlan.blocker : "",
      gridCols: panel.gridCols,
      gridCell: panel.gridSide,
      searchFocused: searchField.focused,
      rowType: row ? row.ptype : "",
      expanded: row ? row.expanded === true : false,
      dropdownOpen: row ? row.dropdownOpen === true : false,
      editorOpen: row ? row.editorOpen === true : false,
      infoOpen: row ? row.infoOpen === true : false,
      optionIndex: row ? row.optionIndex : -1,
      subText: row ? row.subText : "",
      value: row && row.st ? String(row.st.value ?? "") : "",
      displayValue: row ? String(row.numericDisplay ?? "") : "",
      toggleOn: row ? !!row.toggleOn : false,
      stChecked: row && row.st ? !!row.st.checked : false,
      timerActive: row ? Menu.confirmFor(row.itm) !== null : false,
      timerFormatted: row ? String(row.numericDisplay ?? "") : "",
      labelWidth: row ? row.labelWidth : 0,
      // The cursor row's elision verdict: its label column against what its
      // label and sub line need. True means the card is too narrow for this
      // row's text, which is what a wrong width pass looks like from here.
      textElided: row ? row.textElided : false,
      labelNeeded: row ? row.labelNeeded : 0,
      // 1 unless the card is mid-width, in which case it is how much of the
      // row's copy fits right now (the reveal the glide rides).
      textReveal: row ? row.textReveal : 1,
      descSlotH: row ? row.descSlotH : 0,
      width: panel.width,
      // The measurement the width rule is handed: the widest row on this
      // page, shaped from real font metrics. `width` above is this clamped
      // to the viewport, so the two differ exactly by that clamp.
      contentW: panel.contentW,
      widthSettling: panel.widthSettling,
      slotsOpen: panel.expansionNeedH > 0,
      // What the open slot did to the card: -1 means the list scrolls the
      // dropdown into view and the card stands still, a height means the card
      // grew to carry it.
      revealNeedH: list.revealNeedH,
      grownListH: panel.growForSlot(panel.listRegionH),
      // Scroll-breakdown ground truth: where the view stands, what it
      // thinks the content is, and what bound the last seat was held to.
      // `blank` > 0 is trailing empty space under the last row - the
      // signature of a seat that landed past the real content.
      contentH: list.contentHeight,
      tableTotal: list.tableTotal(),
      tableMaxY: list.tableMaxY(),
      blank: list.contentY + list.height - list.contentHeight,
      growthH: list.growthH,
      rowTop: list.rowTop(list.autoRevealIndex),
      claimH: panel._claimListH,
      slotRegionH: panel._slotRegionH,
      committedH: panel._committedListH,
      rowsMoving: panel._rowsMoving,
      fitPending: panel._fitPending,
      transition: panel._transitionActive,
      geom: {
        padTop: filterBar.y,
        filterY: filterBar.y,
        filterH: filterBar.height,
        listY: listBox.y,
        filterToListGap: listBox.y - (filterBar.y + filterBar.height),
        listH: listBox.height,
        cardH: panel.height,
        gridY: panel.gridMode ? grid.contentY : -1
      },
      // Which constraint set the resting size, and what the ten-row cap
      // would have asked for on its own. `rowPolicyBound` true alongside a
      // non-zero `pageMaxHeight` means a page ceiling pre-empted the row
      // policy - the failure mode that had three undeclared constants behind
      // it, and the reason this is on the probe rather than in a comment
      // only.
      tenRowH: panel._tenRowH,
      rowPolicyBound: panel.rowPolicyBound,
      pageMaxHeight: panel.pageMaxHeight,
      // Spawn verdict for the last summon: whether the card was born at its
      // own size or opened wearing the previous menu's box. `carried` true is
      // the regression this whole record exists to catch.
      spawn: panel.probeSpawn()
    })
  }

  // Filter block: standalone header component.
  Item {
    id: filterBar

    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Ui.outerPad
    height: Ui.filterH

    InputField {
      id: searchField

      anchors.fill: parent
       inputRole: panel.scopedSearching ? "filter" : "search"
      // The filter chip must stay put while the "/" quick-filter is armed,
      // focused or not: with the default (false) the first Esc (de-focus,
      // trim kept) hid the chip, gliding it to the field center while the
      // query slid left - the reported flash. Every other filter bar sets
      // this true; the menu is the only one that toggles inputRole.
      filterIconAlways: true
      clearable: false

      // Ghost hint flips to "Filter" while the "/" in-page quick-filter
      // is armed, so "Search" never implies the global cross-page search.
      placeholder: panel.scopedSearching ? "Filter..." : "Search..."

      onEdited: text => panel.onFieldEdited(text)
      // TextInput consumes Enter to emit accepted; route it here since
      // it never reaches the panel handler while the field holds focus.
      onAccepted: text => panel.activateCurrent(false)
      onEscaped: panel.escapeChain()
      // Backspace on an empty field leaves Filter mode, like Esc with empty
      // input does - but never pops or closes (Launcher parity: stepBack
      // only exits the mode). Regular search already exits via query-empty;
      // the "/" filter stays armed with an empty query by design, so without
      // this it could never be left by Backspace.
      onBackspaceEmpty: panel.backspaceEmptyChain()
      // Clicking in or out of the field moves focus natively; assert
      // ownership immediately instead of waiting for the healer.
      onFocusedChanged: Qt.callLater(panel.reassertFocus)
    }
  }

  // List box: its own region below the filter, separated by a structural
  // gap. Height = content when short, clamped to the available ceiling.
  Item {
    id: listBox

    anchors.top: filterBar.bottom
    anchors.topMargin: Ui.listTopGap
    anchors.left: parent.left
    anchors.leftMargin: Ui.outerPad
    anchors.right: parent.right
    anchors.rightMargin: Ui.outerPad
     height: panel.layoutListH

    // Submenu navigation slide: entering pushes content in from the
    // right, popping brings it back from the left. One container-level
    // motion - delegates stay untouched.
    property int lastDepth: -1

    function slideFor(depth, transitionGen, launchWhileMasked) {
      // Closed surface never slides: a closed menu runs no row rebuild,
      // so any page-id churn it sees must not consume the first-open
      // seat or start the tween off-screen.
      if (!Menu.open) return
      if (transitionGen !== undefined && transitionGen !== panel._transitionGen) return
      if (panel._fitPending || panel._transitionActive) {
        if (launchWhileMasked !== true) return
      }
      // First appearance after cold boot (lastDepth -1): seat the page
      // instantly. Animating here reads as a left-to-right slide of the
      // selected background on open.
      if (listBox.lastDepth === -1) {
        listBox.lastDepth = depth
        slideAnim.stop()
        pageHost.x = 0
        pageHost.opacity = 1
        return
      }
      // Same depth, no navigation (summon-time page switch after the
      // open seat above): snap, never slide.
      if (depth === listBox.lastDepth) {
        slideAnim.stop()
        pageHost.x = 0
        pageHost.opacity = 1
        return
      }
      // Every navigation tweens, including the first: seating the first
      // push leaves opacity at 1 while the raw swap (model reset,
      // delegate pop-in, card resize, scroll settle) plays out visibly,
      // which reads as a bounce. The tween starts at opacity 0 and
      // masks the swap underneath. Measured: the first tween runs
      // frame-clean, caches fill synchronously before it starts.
      const dir = depth >= listBox.lastDepth ? 1 : -1
      listBox.lastDepth = depth
      // Kill switch: snap the page into place and stop any in-flight
      // slide instead of running the tween.
      if (!MotionPolicy.enabled) {
        slideAnim.stop()
        pageHost.x = 0
        pageHost.opacity = 1
        return
      }
      pageHost.x = dir * 48
      pageHost.opacity = 0
      slideX.from = dir * 48
      slideX.to = 0
       slideFade.from = 0
       slideFade.to = 1
       slideAnim.restart()
    }

    NumberAnimation {
      id: heightAnim

      target: panel
      property: "_animatedListH"
      duration: Ui.resizeMs
      easing.type: Easing.OutCubic
      onFinished: panel.finishHeightTransition()
    }

      ParallelAnimation {
        id: slideAnim

        NumberAnimation {
          id: slideX
           target: pageHost
           property: "x"
           to: 0
           duration: Ui.fastMs + 20
           easing.type: Easing.OutCubic
        }
        NumberAnimation {
          id: slideFade
           target: pageHost
           property: "opacity"
           to: 1
           duration: Ui.fastMs + 20
           easing.type: Easing.OutCubic
       }
     }

     Item {
       id: pageHost

      x: 0
      y: 0
      width: listBox.width
      height: listBox.height

      List {
        id: list

        visible: !panel.gridMode
        // Unbound while the grid shows: the grid renders the same row set,
        // so Entry delegates (Texts, TextMetrics, icons, slots) built here
        // would be shaped, measured and tracked for rows nobody sees -
        // thousands of them on picker bundles. Every grid-mode reader of
        // this view branches to the grid or tolerates an empty one.
        model: panel.gridMode ? null : listModel
        // Center-lock scrolloff: keyboard steps keep the cursor riding
        // the viewport middle while scrolling is possible. Steps ease
        // while animations run, jump while off.
        centerCursor: true
        smoothScroll: MotionPolicy.enabled
        // Row-set motion is library-driven (see common/ui/List): the
        // transitions and the emerge-from-behind effect live there, so every
        // list reveals the same way. Only the GATE is the panel's - it knows
        // whether this row set is gliding or was rebuilt wholesale.
        rowMotion: panel.syncAnimated
        // Small lists stay fully instantiated (same gate as the
        // launcher): a far-end wrap target always has a live delegate,
        // so the follow tweens to measured geometry instead of snapping
        // through positionViewAtIndex on a missing item.
         autoCache: true
         // Sliding selection lives in common/ui/List (library-driven):
        // one bar gliding behind transparent delegates. Only the motion
        // gate stays here - it snaps while searching and while any slot
        // is open or closing.
        highlightMotion: panel.highlightMotion

        anchors.fill: parent
        interactive: false
        // NO trailing space here: outerPad below the region is the single
        // bottom-gap authority. An in-content pad would stack with it on
        // short lists (22px) while scrollable lists showed only 10.
        trailSpace: 0

        // The list is the reveal mechanism for open slots in every
        // regime - the card only grows when the slot cannot fit, so
        // pursuit must be able to scroll the open row into view even on
         // hugging pages. Pursuit follows the open row's live geometry
         // while a slot is open (autoRevealIndex >= 0).
        autoRevealEnabled: true
        // An open slot must be chased, not snapped: the pursuit re-derives
        // its bottom-align seat on every height step and bends the tween
        // already in flight (List.qml pursue), so a dropdown unfolding
        // under the cursor glides and still rests on the seat the snap
        // took. Same flag the launcher sets; MotionPolicy stays the only
        // animation gate (List multiplies it in).
        //
        // No page-transition gate: heightAnim tweens the CARD height
        // (_animatedListH -> renderedListH), while this view's height is
        // the live layoutListH binding, so a transition never ramps the
        // viewport a pursuit target is derived from.
        pursuitAnimated: true
        restingContentHeight: panel.gridMode ? 0 : panel.modelContentH()

        rowIdentity: index => {
          if (index < 0 || index >= list.count) return String(index)
          // `?? index` is the floor under the identity, and what it is for
          // is the sharing: an empty lookup that reached the table as the
          // string "undefined" would be one key claimed by every such row,
          // and a contested identity is refused for learning. Degrading to
          // the index keeps one row on one entry.
          //
          // Read off the MODEL rather than off panel._records: the model is
          // what the view is reading, and the two are briefly out of step
          // while the model is diffing.
          return String(listModel.values[index]?.uid ?? index)
        }
        // Identity epoch for the height table: advances only when an
        // install changed the key sequence, so a payload-only change
        // keeps the measured heights and a key-set change prunes the rows
        // the new key set no longer claims. A ScriptModel has no key-set
        // flag and no revision, so panel.identityRevision is the counter -
        // see its declaration for why it is a counter and not the
        // sequence.
        //
        // It is the only way a key-set change is visible to the table.
        // The model diffs a changed row set instead of replacing it, so
        // the table is not cleared on every install any more; what is left
        // is the count, the two endpoint identities and this term. The
        // table re-learns from the live delegates on the next seat (small
        // lists are fully instantiated, so live geometry answers every
        // seat meanwhile), and the epoch prunes the rows the new key set
        // drops.
        identityRevision: panel.identityRevision
        clip: true

        isSelectable: index => panel.isSelectableIndex(index)
        // Never learn a row while ITS OWN description/dropdown/editor
        // slot is open: slot-inflated rows poison the average (short
        // far-end seats). Per-row store state, never global geometry:
        // expansionNeedH stays raised through the whole close ease and
        // would block learning settled rows too (including separators,
        // which are never visited and would sit at the average
        // forever). State flips the same tick as the keypress, and the
        // close latch is this row's own, so an unrelated slot closing
        // somewhere else never holds a settled row out of the table.
        measureGuard: index => {
          const it = index >= 0 && index < panel.rowsModel.length ? panel.rowsModel[index] : null
          return it ? (!Menu.isSlotClosing(it) && !Menu.infoOpen(it) && !Menu.isExpanded(it)) : true
        }

        Component.onCompleted: panel.restingBufH = contentHeight

        onCurrentIndexChanged: {
          panel.closeTrailingInfo()
          panel.releaseSummonSeat()
          panel.track()
        }
        // A seat that landed has moved the content, so where the claim sits
        // relative to the viewport has changed. The claim itself is constant
        // for an unfold; contentY is the other term in the shortfall, and it
        // only moves on a real seat - never per frame, so re-latching here
        // cannot restart the region tween.
        onMotionFinished: {
          panel.track()
          panel._latchClaim()
        }
        onMovingChanged: if (!moving) panel.track()

        // Conditionally revealed rows slide out from behind the row above
        // them (their "parent"); hidden ones slide back and fade. Neighbors
        // ease into place. Suppressed entirely for wholesale swaps (search,
        // page navigation, bundle load) where everything changes at once.
        //
        // `syncAnimated` is the whole policy, published once by
        // _installRows from the row-sync plan; GridList runs the same
        // four transitions off the same flag. Nothing here decides when
        // rows should move, so nothing here can decide it twice.
        delegate: Entry {
          id: rowItem

          itm: modelData
          sel: list.currentIndex === index
          searchResult: panel.searching
          // The card is mid-width for as long as the width glide runs; the
          // row uses it to reveal its copy with the growth.
          cardSettling: panel.widthSettling
          width: list.width

          // Closes the loop the model's per-row close latch opens.
          // setExpanded/setInfo arm it at the collapse choke point, where no
          // DropdownSlot is in scope, and only the row's own slot knows when
          // the close landed - it publishes that by dropping `closing` in the
          // same tick it emits closeFinished. slotMotionMs is that window in
          // one number (non-zero while any of the row's slots is open OR
          // mid-close), so going still IS the close reaching its end, for a
          // short slot and a tall one alike. A reopen inside the grace
          // window never goes still, so the latch just re-arms.
          Connections {
            target: rowItem

            function onSlotMotionMsChanged() {
              if (rowItem.slotMotionMs > 0) return
              Menu.slotCloseFinished(rowItem.itm)
            }
          }
        }
      }

      // Grid twin of the list for layout:"grid" pages (MenuLib buildPage).
      // Shares the model - one rowsModel truth, two renderers - and rides
      // the same wholesale/incremental sync the list feeds from.
      GridList {
        id: grid

        visible: panel.gridMode
        anchors.fill: parent
        interactive: false
        // Mirror of the list's unbind above: while a list page shows, cell
        // delegates for its rows would instantiate here for nobody.
        model: panel.gridMode ? listModel : null
        clip: true
        keyNavigationEnabled: false
        isSelectable: index => panel.isSelectableIndex(index)
        cols: panel.gridCols
        firstSelectable: () => panel.firstSelectableIndex()
        lastSelectable: () => panel.lastSelectableIndex()
        // The grid renders the same row set through the same sync, so it
        // answers the same reveal question: a conditional cell glides on
        // a grid page exactly as a conditional row does on a list page.
        // The decision itself stays in the panel's sync plan, and the
        // card is unaffected either way - grid height is gridRows *
        // gridSide, pure model math, so no cell transition can reach it.
        syncAnimated: panel.syncAnimated

        cellWidth: panel.gridSide
        cellHeight: panel.gridSide
        boundsBehavior: Flickable.StopAtBounds

        // Declarative category headers: consecutive cells sharing a
        // section tag group under one full-width label. This build's
        // GridView ships without native sections, so headers ride in the
        // model as non-selectable slots (composeGridRows); GridCell
        // paints header/spacer slots accordingly.
        onCurrentIndexChanged: {
          panel.releaseSummonSeat()
          panel.track()
        }
        onMovingChanged: {
          // A drag/flick wins over an in-flight wrap sweep.
          if (grid.moving) grid.cancelSweep()
        }

        delegate: GridCell {
          sel: grid.currentIndex === index

          onActivated: () => panel.activateCurrent(false)
        }
      }
    }

    // Dead center of the empty list box. Filter/search with no hits
    // shows the mode glyph above the copy (bar-island pattern):
    // scoped "/" filter -> filter-x + "No matches", global search ->
    // search-alert + "No results", both two-tone with a red indicator.
    // The ThemePicker page ("themes") keeps its palette glyph instead.
    // A truly empty page stays text-only.
    EmptyState {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - 32)
      visible: (panel.gridMode ? grid.count : list.count) === 0 && Menu.open
      text: panel.searching ? "No results" : panel.scopedSearching ? "No matches" : "Empty page"
      iconName: {
        if (!panel.searching && !panel.scopedSearching) return ""
        if (panel.currentPageId === "themes") return "theme"
        if (panel.searching) return "search-alert"
        return "filter-x"
      }
      iconColorKey: "foreground_1"
      iconAccentKey: {
        if (!panel.searching && !panel.scopedSearching) return ""
        if (panel.currentPageId === "themes") return ""
        return "red"
      }
    }
  }

  // keySink now lives inside PanelFocus (focusCtrl.keySink) so
  // panel.keySink alias above stays compatible with tests.
}

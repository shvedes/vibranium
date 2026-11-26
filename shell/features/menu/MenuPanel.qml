pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick as QQ
import Quickshell
import qs.common
import qs.features.clipboard
import qs.features.menu
import "MenuLib.js" as MenuLib
import "MenuLayout.js" as MenuLayout
import "MenuRows.js" as MenuRows
import "MenuQuiesce.js" as MenuQuiesce
import "MenuSpawnProbe.js" as MenuSpawnProbe
import "../../common/math/Range.js" as Range
import "../../common/ui/PanelKeys.js" as PanelKeys
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
    // Qualified by the root id: an unqualified `searchField` here names
    // PanelFocus's own property, so the assignment was a self-binding the
    // engine drops as a loop - leaving the gate with no field and the "/"
    // filter armed but never focused.
    searchField: panel.searchField
    serviceVisible: Menu.open
  }
  property alias mode: focusCtrl.mode
  // Public handle for the list view (debug verbs drive cursor/scroll
  // through it); ids are component-scoped, so external callers need this.
  property alias listView: list

  readonly property string currentPageId: Menu.frame ? Menu.frame.id : ""
  readonly property bool searching: Menu.searching
  // "/" quick-filter: the service publishes the arm (scopedActive) and the
  // live view state (scopedSearching = armed AND a query exists). Derive the
  // view from the query-aware state: arming the field alone changes no rows
  // and no geometry. Field routing and filter chrome read the arm instead.
  readonly property bool scopedSearching: Menu.scopedSearching

  // Sliding-highlight motion gate: the selection bar glides for pure
  // focus shifts between resting rows, including while a query is
  // present - entry-to-entry moves animate the same filtered or not.
  // The focused row's slot still gates resize tracking, but a move to
  // another row keeps the native highlight glide while the old slot closes.
  readonly property bool highlightMotion: MotionPolicy.enabled
    && !panel.cursorSlotOpen && !panel._swapping
    // The first spawn sizes the card and its rows for the first time in the
    // process. Until that entrance settles, row geometry is provisional and
    // the bar's Behavior would ease from it to the settled row - the focused
    // background sliding into place on the first open only. Later opens have
    // warm geometry, so the gate is spent after the first show.
    && (panel.shown || panel._everShown)

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
    const pg = MenuLib.layoutPageOf(Menu.bundle, panel.searching, panel.installedPage,
      Menu.pageById, panel.currentPageId)
    // A summon has a bundle and an entry page before it has an installed page
    // or a frame id. Without this fallback the first width pass measures the
    // grid page as a LIST (its long keyword labels), settles on a wider card,
    // and then re-measures to the grid's own width - resizing the grid along
    // the way. The bundle entry is the page this open is about to show.
    return pg || (Menu.bundle ? Menu.bundle.byId[Menu.bundle.entry] : null)
  }

  readonly property bool gridMode: {
    const pg = panel.layoutPage()
    return !!pg && pg.layout === "grid"
  }

  // Cell side hint from the layout page; the library owns the floor that
  // keeps a degenerate declaration usable.
  readonly property real gridCellSpec: MenuLib.gridCellSpec(panel.layoutPage())

  // Columns fit the card's inner width; cells stretch to fill it exactly,
  // staying square-ish via the shared side length.
  // The grid's column count and side come from the SETTLED width. Reading the
  // animated width made a cold summon fit at the previous page's width (4
  // columns, side 55) and then refit when the tween reached 8 columns / side
  // 49 - the bottom row was cut and the card shrank a few frames later.
  readonly property var gridGeometry: MenuLib.gridGeometry(
    panel.widthTarget, Ui.outerPad, panel.gridCellSpec)
  readonly property int gridCols: panel.gridGeometry.cols
  readonly property real gridSide: panel.gridGeometry.side

  // Frozen chrome slots so the row diff treats spacers as unchanged
  // between recompositions (identity, not value, is compared).
  property var _gridPool: MenuLayout.createPool()

  // Weave section headers into a flat cell list: a new section tag starts
  // a fresh row with a full-width header slot followed by invisible
  // spacers up to the next column boundary. `cols` defaults to the live
  // layout; startup preload passes the deterministic count derived from
  // the page declaration so a closed-window weave matches what the open
  // card will compute.
  function composeGridRows(items, cols) {
    return MenuLayout.composeGridRows(_gridPool, items,
      cols !== undefined ? cols : panel.gridCols)
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

  // The page record this panel LAID OUT, with the row set below it. Written in
  // one place - the install (recomputeRows) - and read by every layout answer
  // that needs the page: the width engine's declared width and the row-sync
  // plan. Deliberately NOT Menu.page (a binding over pageId) and not
  // Menu.frame: both still name the outgoing page while a change handler runs,
  // which is how the card came back from the idle timer list (declared 340)
  // carrying that width onto the page it returned to.
  property var installedPage: null
  property string installedPageId: ""

  // The page's rows: every declared row stays installed, and one that cannot
  // be used renders muted (Menu.isUnavailable). Managed identity-stable model
  // (a naive binding would rebuild delegates mid-interaction).
  property var rowsModel: []
  property real _latchedListH: -1
  property bool _fitPending: false
  // The page transition that owned the fit when it was armed. _resolveFit
  // refuses a fit whose transition generation has moved on; the fit is now
  // committed from a reactive edge rather than a closure that captured this.
  property int _fitTransGen: -1
  property int _fitGen: 0
  property int _transitionGen: 0
  property bool _transitionActive: false
  // Bumped on a search/filter mode edge. A nested row that sees a new value
  // is being torn down by the projection swap, not left by a child step, so
  // it must not fold the outgoing child's canonical state (Entry.qml reads
  // this through _projectionRev).
  property int projectionRev: 0
  // True while the transition in flight is a summon rather than a navigation.
  // The two are sized from opposite answers: a navigation glides from the
  // height the user can see, a summon has no card on screen yet and is born
  // at the height its own row set implies. Cleared wherever _transitionActive
  // is, so it is exactly "the spawn owns the card right now".
  property bool _summoning: false
  // A navigation chosen while the opening layout is still settling. The show
  // gate suppresses the spawn's own fit; it must not suppress this resize.
  property bool _navInGate: false
  property bool _heightAnimating: false
  // The height the transition in flight latched as its starting point.
  // Written by beginPageTransition and by both branches of
  // _startHeightTransition/finishHeightTransition.
  //
  property real _committedListH: -1
  property real _animatedListH: -1
  property real _heightTargetH: -1
  property int _heightAnimGen: -1
  // An expanded row restored from a search projection owns the resize through
  // its live slot height. The search card's height is the floor until that row
  // arrives; a resting-page fit must not tween underneath its unfold.
  property real _restoreSlotStartH: -1
  property bool _searchReturnOpen: false
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
    panel._quiesceDisarm()
    panel._heightAnimating = false
    panel._heightTargetH = -1
    panel._heightAnimGen = -1
    panel._transitionActive = false
    panel._summoning = false
    panel._navInGate = false
    // A row glide the surface no longer shows must not hold the fit shut
    // on the next summon.
    panel._rowsMoving = false
    rowsMotionTimer.stop()
    panel._pendingSlideDepth = -1
    panel._animatedListH = -1
    panel._restoreSlotStartH = -1
    panel._searchReturnOpen = false
    panel._scopedReturnOpen = false
    panel._modeRestoreFitOwned = false
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
    Menu.trace("panel.clear", { site: "pageExit", auto: list.autoRevealIndex })
    list.autoRevealIndex = -1
    list._followIdx = -1
    pageHost.x = 0
    panel._pageSlideOpacity = 1
  }

  function beginPageTransition(summon) {
    panel._handoffReveal = false
    const gen = ++panel._transitionGen
    // The place owed to the page being left: it belongs to the row set that
    // page had, and the page on screen now is a different one. The new
    // page's restore arms its own.
    panel._placeIdx = -1
    // A summon claims the marker, and only a summon does. A page navigation
    // that lands inside the opening window is a new intent from the user, not
    // a continuation of the spawn: it takes the visible height as its hold
    // and escapes the show gate (see _startHeightTransition).
    panel._summoning = summon === true
    // The summon's own page assignment also lands here, at the depth the open
    // just claimed. A deeper stack is a page the user pushed, so its resize
    // must animate even though the opening layout has not settled yet.
    if (summon === false && !panel.shown
      && Menu.stack.length > Math.max(0, listBox.lastDepth))
      panel._navInGate = true
    // Armed on the summon edge only: a navigation mid-flight is not a spawn
    // and has no inherited size to be measured against.
    if (summon === true) panel._armSpawnProbe()
    panel._fitGen++
    panel._fitPending = false
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
    heightAnim.stop()
    slideAnim.stop()
    panel._animatedListH = held
    // The hold has captured whatever the card is showing, open slot included,
    // so the claim about the page being left can go: the transition owns the
    // size from here and the region would only fight it.
    panel._releaseSlotRegion()
    panel._transitionActive = true
    panel._pendingSlideDepth = Menu.stack.length
    pageHost.x = 0
    panel._pageSlideOpacity = 0
    if (summon === true) listBox.lastDepth = Menu.stack.length
    return gen
  }

  function _finishPageTransition(gen) {
    if (gen !== panel._transitionGen || !panel._transitionActive
      || panel._fitPending || panel._heightAnimating) return
    const depth = panel._pendingSlideDepth
    panel._transitionActive = false
    panel._summoning = false
    panel._navInGate = false
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
  // fromH names the height the card is showing when the caller has already
  // cleared the slot region that owned it. The ordinary callers omit it and
  // read the live chain; a close release needs the pre-clear value because
  // the region goes away in the same turn the claim does.
  function _startHeightTransition(target, gen, fromH) {
    if (gen >= 0 && (gen !== panel._transitionGen || !panel._transitionActive)) return
    Menu.trace("panel.heightArm", {
      want: Math.round(target * 10) / 10, gen: gen,
      cur: Math.round(panel._currentListH() * 10) / 10,
      claim: Math.round(panel._claimListH * 10) / 10,
      searching: panel.searching
    })
    const next = Range.clamp(target, 0, panel.screenMaxListH)
    const current = Math.max(0, fromH !== undefined ? fromH : panel._currentListH())
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
    // `searching` and `_navInGate` are the gate's escapes: a keystroke or a
    // submenu pick landing inside the window is a real resize the user asked
    // for, not the opening layout, and tweening it is what the card has always
    // done for search.
    const gateShut = !panel.shown && !panel.searching && !panel.scopedSearching
      && !panel._navInGate
    // A live slot claim owns the card's size through _slotRegionH, animated
    // at the slot's own pace. A fit tween to the RESTING size takes precedence
    // in layoutListH for its whole duration (it prefers _animatedListH over
    // the region) and shrinks the card under an expanded dropdown. While the
    // region owns the size, commit the resting fit without tweening.
    const slotOwns = panel._claimListH > 0 || panel._slotRegionH > 0
    if (!MotionPolicy.enabled || gateShut || slotOwns || current <= 0 || next <= 0
      || Math.abs(next - current) < 0.5) {
      panel._heightAnimating = false
      panel._heightAnimGen = gen
      heightAnim.stop()
      panel._heightTargetH = next
      panel._animatedListH = next
      panel._committedListH = next
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
    // The fit tween owned the card for a short-dropdown restore. With it
    // landed, the normal region chain can own the size again.
    panel._modeRestoreFitOwned = false
    Menu.trace("panel.heightDone", {
      target: Math.round(panel._heightTargetH * 10) / 10,
      claim: Math.round(panel._claimListH * 10) / 10,
      gen: panel._heightAnimGen
    })
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
    // The fit that just landed owns the resting size. Re-deriving from the
    // model here can read a filter's old latch and collapse the card even
    // though the tween delivered the restored page's height.
    panel._committedListH = panel._handoffReveal && target > 0
      ? target : panel._modelListH()
    panel._handoffReveal = false
    if (gen >= 0) Qt.callLater(() => panel._finishPageTransition(gen))
  }

  // The region size the model implies, with no fit latch in the path.
  // Every other sizing branch lives in listRegionH; this one exists
  // because the recovery path runs right after clearing that latch, and
  // reading the region back there hands over the height the fit was
  // supposed to replace.
  function _modelListH() {
    if (panel.gridMode) {
      if (panel.rowsModel.length === 0)
        return Math.min(Ui.emptyMinH, panel.cappedAvailH)
      // The fit's own answer must be the row set's size, not listRegionH's
      // on-screen hold: a pending fit reads this to learn where to GLIDE to.
      return Math.min(panel._gridContentH(), panel.snappedListH(panel.availListH))
    }
    if (panel.rowsModel.length === 0)
      return Math.min(Ui.emptyMinH, panel.cappedAvailH)
    // The resting fit, never an open slot's growth. This value is latched
    // into exactListH, and the growth is applied on top of the region by
    // growForSlot rather than folded into it - so a slot that opened while
    // a page transition was mid-fit cannot leave the latch holding a
    // dropdown's height after the dropdown closed.
    return Range.clamp(
      panel.snappedListH(panel.cappedAvailH), 0, panel.screenMaxListH)
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
    if (panel._restoreSlotStartH >= 0 && !panel._transitionActive) {
      panel._committedListH = target
      panel._latchedListH = measured ? fit : -1
      return
    }
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
    const srcPage = panel.installedPage
    return MenuLayout.rowSyncPlan({
      intent: intent,
      rowCount: rowCount,
      searching: panel.searching,
      scopedActive: Menu.scopedActive,
      sourceCount: !!srcPage && Array.isArray(srcPage.items) ? srcPage.items.length : 0,
      fullRows: Ui.listFullRows,
      animationsEnabled: MotionPolicy.enabled
    })
  }

  // Diagnostic: the plan the most recent install was resolved with. Not
  // read by any binding, so publishing it costs the install nothing.
  property var _lastSyncPlan: null

  function recomputeRows(intent, sameTurn) {
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
    // The page record these rows belong to, read from the FRAME rather than from
    // Menu.page (a binding over pageId, still the outgoing page inside a change
    // handler - the same reason the branch below reads the id fresh). Published
    // as the panel's layout page here, so the width pass and the row-sync plan
    // read the page this row set belongs to instead of asking a singleton
    // mid-transition.
    panel.installedPageId = Menu.frame ? Menu.frame.id : ""
    panel.installedPage = panel.installedPageId !== "" ? Menu.pageById(panel.installedPageId) : null
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
      // The query rides along so a row that names a section the user typed
      // (the Blur link, under "blur") can lead the list instead of being
      // filed under the page it lives on, after the rows it opens.
      candidate = MenuLib.groupSearchResults(Menu.results, Menu.pageById, Menu.isVisible, Menu.query)
    } else if (panel.scopedSearching) {
      // "/" quick-filter stays on this page, but a nested match now renders
      // as a flat top-level result row - the same visual language as global
      // search - carrying the group chain its landing walks to open the real
      // nesting. A row that matched in its own right keeps its subtree.
      candidate = MenuLib.scopedResultRows(
        panel.installedPage, Menu.scopedQuery)
      if (!panel.searching && panel.gridMode)
        candidate = panel.composeGridRows(candidate)
    } else {
      // Read the target page FRESH: panel.currentPageId (a cached var
      // binding) hands back the PREVIOUS page inside change handlers,
      // which would latch restore-protection onto the wrong page and let
      // mid-swap cursor churn pollute the destination's saved state.
      const pg = panel.installedPage
      const src = pg ? pg.items : []
      // isListed, not isVisible: a blocked row keeps its slot and is drawn
      // under a mute box, so the row set only changes when the page itself is
      // rebuilt.
      candidate = src.filter(item => Menu.isListed(item))
      // Only grid pages weave section headers and row-fill spacers into the
      // flat slot list. Running this on a list page padded every labelled
      // separator out to the grid column count, so plain menus grew blank
      // spacer rows that the cursor could land on. Search results stay flat.
      if (!panel.searching && panel.gridMode)
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

    // Publish the row set before the install. A search projection installs
    // synchronously now, and its head seat resolves selectable rows against
    // rowsModel; publishing after the install left the seat scanning the
    // outgoing set, which parked the cursor on the incoming set's leading
    // separator. The equality check above still compares against the outgoing
    // set, captured in `prev`.
    panel.rowsModel = candidate
    if (!panel.syncRowsList(candidate, plan, records, sameTurn)) return
    panel.projectRows(candidate)
    // A close latch belongs to a row this model still lists. `candidate` is
    // the authoritative "what the model will show", so the reconcile needs
    // no view timing: keyed sync destroys a delegate exactly when its key
    // leaves, so anything pruned here has no delegate left to report.
    Menu.pruneSlotCloses(candidate)
    // Width first: a grid fit reads gridGeometry, which now uses widthTarget,
    // so the target must already describe THIS page's row set when the fit
    // resolves - otherwise the first frame is sized from the old page's width.
    metrics.recalcWidth()
    panel.queueFit()
  }

  // Whether this install can be sized from the MODEL: nothing open, closing,
  // moving or swapping anywhere, so every row rests at RowGeometry's height
  // and no delegate has to be read. The measured path exists to absorb an
  // open slot's live geometry; without one it defers two event-loop turns and
  // retries for a number the model already knows exactly. A ranked search
  // projection is the shape this matters most for: it never renders a slot,
  // and it re-installs on every keystroke.
  // Whether any installed row is open, closing or holding its description.
  // The resting-fit shortcut and the retry probe both have to answer this,
  // and they have to answer it the same way: a row one of them counts as
  // resting and the other does not is a card sized from a delegate the other
  // is still waiting for. Model-level, so it covers rows no delegate shows.
  function _anyRowOpen(rows) {
    const pool = Array.isArray(rows) ? rows : []
    for (let i = 0; i < pool.length; i++) {
      const it = pool[i]
      if (it && (Menu.isExpanded(it) || Menu.infoOpen(it) || Menu.isSlotClosing(it)))
        return true
    }
    return false
  }

  function _restFitReady() {
    if (panel.expansionNeedH > 0) return false
    if (Menu.slotClosing || panel._rowsMoving || list._inSwap) return false
    if (panel._anyRowOpen(panel.rowsModel)) return false
    if (panel._anyRowMoving()) return false
    return true
  }

  // Whether any live row delegate is still opening, closing or moving its
  // slot. Those fields live on the delegates only, so the model cannot answer
  // this and the resting-fit shortcut and the retry probe must ask the same
  // question.
  function _anyRowMoving() {
    const kids = list.contentItem ? list.contentItem.children : []
    for (let i = 0; i < kids.length; i++) {
      const d = kids[i]
      if (!(d instanceof Entry)) continue
      if (d.slotMotionMs > 0 || d.descSlotH > 0 || d.expandSlotH > 0) return true
    }
    return false
  }

  // The model height is final: publish it without waiting for delegates.
  // The latch is left to _resolveFit, which arms the height before publishing
  // it; a write here would invalidate the region binding a turn early.
  function _fitModelFromPending() {
    panel._fitPending = false
    panel._resolveFit(-1, panel._fitGen, panel._fitTransGen)
  }

  // A pending fit can commit a measurement only once every motion that would
  // move a delegate has stopped and the view can actually measure. Those are
  // live states, so the answer is a derivation rather than the outcome of a
  // bounded poll: a tween that outlasts a retry budget used to leave the card
  // sized from the fit it was waiting to replace. The predicate reads the
  // delegate scan and the count inside the binding, so QML re-arms it on the
  // row, slot and install edges that change the answer. Geometry and count
  // get explicit re-arms too (see the list Connections below) for the case
  // where a measurement fails while this verdict stays true.
  readonly property bool _fitSettled: !list._inSwap && !Menu.slotClosing
    && panel.expansionNeedH <= 0 && !panel._anyRowMoving()
    && list.count === (panel.rowsModel || []).length
    && panel.availListH > 0 && list.width > 0 && list.height > 0

  on_FitSettledChanged: if (panel._fitSettled) panel._tryFit()

  function _tryFit() {
    if (!panel._fitPending || !panel._fitSettled) return
    const rows = panel.rowsModel || []
    if (panel.gridMode || rows.length === 0 || panel._rowsMoving
      || !panel._anyRowOpen(rows)) {
      // The resting height cannot be measured yet, but the card does not
      // have to wait for the slide to finish before following it: the model
      // knows how tall the row set is and reads no delegate geometry.
      panel._fitModelFromPending()
      return
    }
    const fit = list.fitHeight(panel.availListH, Math.min(10, rows.length))
    // A fit that cannot be measured sizes the card from the model (see
    // _resolveFit). A later edge that makes the delegates measurable queues
    // a new fit and corrects it; nothing waits on a budget here.
    if (fit < 0) {
      panel._fitModelFromPending()
      return
    }
    panel._fitPending = false
    panel._resolveFit(fit, panel._fitGen, panel._fitTransGen)
  }

  function queueFit() {
    const rows = panel.rowsModel || []
    // A summon installs its grid rows a turn after the open edge. Fitting the
    // empty set first drops the card to chrome height for one frame; the
    // install's own fit immediately below is the one that matters.
    if (panel.gridMode && rows.length === 0 && !panel.shown) return
    if (panel._fitPending) {
      panel._tryFit()
      return
    }
    const fitGen = ++panel._fitGen
    panel._fitTransGen = panel._transitionGen
    if (panel.gridMode || rows.length === 0) {
      panel._fitPending = false
      panel._resolveFit(-1, fitGen, panel._fitTransGen)
      return
    }
    // Without motion the measured fit cannot be absorbed, so it is not run:
    // its two event-loop turns would each be a real frame and the card would
    // show the row build before snapping to the measurement. The model height
    // is a measurement of its own (rowRestHeight drives real Text probes), so
    // it is final here.
    if (!MotionPolicy.enabled) {
      panel._fitPending = false
      panel._resolveFit(
        panel.snappedListH(panel.availListH, Math.min(10, rows.length)),
        fitGen, panel._fitTransGen)
      return
    }
    // A fit queued while a slot is open cannot reach _fitSettled: the slot
    // keeps expansionNeedH above zero until it closes, which is exactly the
    // state a result landing or a mode restore installs into. The model's
    // resting height is final and the slot's growth is carried by the region,
    // so commit from the model now instead of leaving a fit pending forever.
    if (panel._restFitReady() || (!panel._transitionActive && panel._anyRowOpen(rows))) {
      panel._fitModelFromPending()
      return
    }
    panel._fitPending = true
    panel._tryFit()
  }

  // The rows' own height, with no delegate read. Final - not an estimate - for
  // a card too young to have anything open on it, and that is the whole
  // condition queueFit's measurement turns wait on, so a caller that knows it
  // holds can commit the height now instead of three frames from now.
  function fitFromModel() {
    panel._fitGen++
    panel._fitPending = false
    panel._resolveFit(-1, panel._fitGen, panel._transitionGen)
  }

  Connections {
    target: list

    // A failed measurement can recover on an edge that leaves _fitSettled
    // true (a delegate finally lays out, a count heals, a swap releases).
    function onCountChanged() { panel._tryFit() }
    function onContentHeightChanged() { panel._tryFit() }
    function on_InSwapChanged() { panel._tryFit() }
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
    // Memoized on the array identity -> one fold per distinct instance.
    if (rows === panel._keySeqSrc) return panel._keySeqVal
    const seq = MenuLib.rowKeySeq(rows)
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
    const guarded = MenuLib.rowSetGuard(candidate)
    return guarded.rows
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
  // Where the cursor belongs in `next`, given where it was in the CURRENT row
  // set (panel._records). The row is named by its uid in the payload this panel
  // owns, never by asking the view: the view still holds the row set being
  // replaced, so an identity lookup through it answers with the row that
  // inherited the old index - in a menu, a separator. When that row is gone (a
  // Delete on the row under the cursor) the answer is the nearest row that can
  // hold a cursor: forward from the old index, else backward, so the cursor
  // never parks on a separator or on the Add row. rowsModel already holds the
  // set that is landing, which is what the selectable test must answer for.
  // -1 means there is no row to put it on.
  function cursorIndexAfter(fromIndex, next) {
    return MenuRows.cursorIndexAfter(panel._records, fromIndex, next,
      (i) => panel.isSelectableIndex(i))
  }

  function _writeRecords(records, keepRow) {
    // A cleared search restores the row saved at entry, not the result row
    // the cursor is on now. Arm that row by identity at the model's single
    // write site, so both install shapes (keyed and wholesale) hand the same
    // target to the view before it replaces the row set. The view restores
    // it from the page rows it is adopting: no seat against the outgoing
    // one-row projection, and no second correction once the page lands.
    const armSavedRow = !panel.searching && !panel.scopedSearching && !panel.gridMode
      && !panel._searchClearByResult && panel._searchReturnIdx >= 0
      && panel._searchReturnUid !== ""
      && panel._searchReturnPage === (Menu.frame ? Menu.frame.id : "")
    if (armSavedRow)
      list.keepRow(panel._searchReturnUid, panel._searchReturnY, panel._modelListH())
    // An install that changes the row COUNT is a live row edit, not a
    // re-order: a row was added or removed under the cursor while the cursor
    // stayed on the row the user was looking at. Two answers follow, and this
    // is the only place that holds the row set the view is leaving AND the one
    // it is about to read.
    //
    // 1. The cursor's ROW keeps its place at a new index, resolved in the
    //    payload: a lookup in the view answers with whatever row inherited the
    //    old index (in a menu, a separator), because the view still holds the
    //    previous row set. reseatAfter applies the index once the count has
    //    moved (see List.onCountChanged).
    // 2. The bar is put where the row is in the same frame instead of gliding
    //    across the gap the edit opened - a glide from the row's old y to its
    //    new one is a bar covering the bottom of the row above and the top of
    //    the row below. Re-orders (equal counts) keep the ordinary glide.
    const countEdit = panel._records !== null && panel._records.length !== records.length
    // A projection seats its own head (see _installRows and seatFilteredHead),
    // so it must not arm the identity restore: the arm is consumed by the
    // count change the head seat races, and applying it afterwards puts the
    // cursor back on the row it held before the query at whatever index that
    // row now has - the last row of a narrowed projection, not the head.
    if (countEdit && keepRow !== false) {
      list.snapHighlight()
      list.reseatAfter(panel.cursorIndexAfter(list.currentIndex, records))
    }
    // The model is about to change, and a model change moves the cursor off
    // the row it was on. The view puts it back on that row - the view is the
    // only thing that knows a row by identity, and this is the only thing
    // that knows a change is coming. A count edit is the exception: the
    // destination above already names the row, and arming the identity
    // restore as well would spend the arm on the stale lookup this avoids.
    if (keepRow !== false && !countEdit) list.keepCursor()
    else if (keepRow !== false) list.pinHighlight()
    panel._records = records
    // The saved-row target is resolved against the row set the view is
    // adopting. Apply that set in this turn so the first frame after the
    // erase already carries the target row instead of the empty projection.
    if (armSavedRow) {
      list.forceLayout()
      list.restoreKeptRow()
    }
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

  // The four gate values the rules read, and the write that puts a decided
  // state back. MenuQuiesce owns what they become; these properties are the
  // reactive half.
  function _quiesceLoad() {
    return {
      armed: panel._quiesceArmed,
      events: panel._quiesceEvents,
      seen: panel._quiesceSeen,
      armedAt: panel._quiesceArmedAt
    }
  }

  function _quiesceStore(state) {
    panel._quiesceArmed = state.armed
    panel._quiesceEvents = state.events
    panel._quiesceSeen = state.seen
    panel._quiesceArmedAt = state.armedAt
  }

  function _quiesceDisarm() {
    panel._quiesceStore(MenuQuiesce.idle())
  }

  function _quiesceArm() {
    panel._quiesceStore(MenuQuiesce.armed(Date.now()))
  }

  // True when a motionless install may write: nothing outstanding, the
  // outstanding write quiesced (no new structural churn since the last
  // check), or the wait ran out. Callers re-queue through the normal
  // coalescing when held, so the latest wins and nothing freezes.
  function _quiesceReady() {
    const verdict = MenuQuiesce.check(panel._quiesceLoad(), Date.now(),
      panel._quiesceWaitMs)
    panel._quiesceStore(verdict.state)
    return verdict.ready
  }

  Connections {
    target: list.contentItem
    function onChildrenChanged() {
      if (panel._quiesceArmed)
        panel._quiesceStore(MenuQuiesce.note(panel._quiesceLoad()))
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
    return MenuRows.sameRecords(panel._records, records)
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
  function _clearCursorForSwap(records) {
    // A search exit replaces the hit projection with the page and restores
    // the row saved at entry. The hit's index names nothing in the outgoing
    // projection once the page is armed, and the view would paint it under
    // the bar until the page rows land. Clear it for the swap, exactly as a
    // summon does: an empty frame until the saved row is restored is the
    // correct answer, and the identity target fills it on the model edge.
    const savedReturn = !panel.gridMode && panel._searchReturnPending
      && !panel._searchClearByResult && panel._searchReturnUid !== ""
      && panel._searchReturnPage === (Menu.frame ? Menu.frame.id : "")
    if (!panel._summonSeat && !savedReturn) return
    if (panel.gridMode) {
      if (grid.currentIndex !== -1) grid.currentIndex = -1
      return
    }
    // A cursor whose ROW the incoming set still lists crosses the write
    // instead of being cleared for it: _writeRecords arms the identity
    // restore (hence keepCursor/PinHighlight), the bar holds the row's
    // geometry, and the landing seat finds the cursor already where it was.
    // Clearing it in this case made the first open of a page drop its
    // selection bar - and the row under it - for one frame every time:
    // the install cleared a cursor it then put back on the very same row.
    if (panel._summonSeat && panel._cursorSurvives(records)) return
    list._hlHeld = false
    if (list.currentIndex !== -1) list.seat(-1, "land", true)
  }

  // Whether the row under the cursor is still in `records`. Looked up by uid
  // in the payload, never in the view: the view has not adopted the new set
  // yet, so a lookup there answers with whatever row inherited the index.
  function _cursorSurvives(records) {
    return MenuRows.cursorSurvives(panel._records, list.currentIndex, records)
  }

  function _installRows(records, plan, generation, sameTurn) {
    if (generation !== panel._pendingGen) return
    // Motionless installs wait for the previous motionless write to land
    // (see _quiesceReady); motion installs proceed as before. Held payloads
    // re-queue through the normal coalescing, so the latest wins.
    // A same-turn page install is one wholesale replacement with its own swap
    // window; holding it for the previous motionless write is what leaves the
    // outgoing page's rows painted in the new box on back navigation.
    if (!plan.glide && sameTurn !== true && !panel._quiesceReady()) {
      panel._queueRows(records, plan, true)
      return
    }
    panel._releaseSwap()
    // The plan answers row motion for the whole install; a wholesale one
    // has already answered no, so publishing it here needs no second test.
    panel.syncAnimated = plan.glide
    // A seat a navigation already owns: the push armed it and its landing
    // seat is the only answer for this row set. It is read before the write,
    // because a row set arriving under it must not put the cursor anywhere of
    // its own (see both branches below).
    const navSeat = Menu.pendingSel >= 0

    if (!plan.wholesale) {
      panel._clearCursorForSwap(records)
      // A projection is a new row set, not a delta: the view goes to the
      // head before the write, so the model change has no old offset to
      // anchor to. Anchoring while scrolled is what leaves an origin gap
      // (originY) above row 0 - the empty space a re-ranked search opens
      // over, with the head row pushed down by the offset it remembered.
      // Both projections seat the head on every keystroke. A filter is a trim,
      // so the cursor stays on the top result while the rows under it shrink
      // away - the conventional filter behavior. The row held at arm time is
      // remembered separately (see _scopedReturn*) and given back on clear.
      if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
      if (!panel._sameRecords(records)) {
        panel._writeRecords(records,
          !navSeat && !panel.searching && !panel.scopedSearching
          && !panel._searchReturnPending)
        if (plan.glide) panel._quiesceDisarm()
        else panel._quiesceArm()
      }
      if (generation !== panel._pendingGen) return
      // A re-ranked projection has no cursor worth keeping: the write holds
      // the current ITEM and only shifts its index, so a cursor parked on a
      // hit that survived the re-rank followed it down the ranking - often
      // past the fold, leaving the selection bar nowhere near the row the
      // user just typed. Both projections seat the head here, where the new
      // order is already installed.
      if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
      // A launch still settling. The launch wants the head of the row set as
      // it stands, and the head is what a re-seat names - a dead link coming
      // back or a guard verdict landing above the head leaves the highlight
      // one row too low with nothing left to correct it, so the wholesale
      // path already re-asserts, and the summons that break are exactly the
      // ones whose last install is this one. Deferred, because the view
      // applies the array swap after this returns.
      else if (panel._summonSeat) Idle.run(() => panel._reseatFrameSel(), 2)
      // A page change whose rebuild was superseded by an in-place install -
      // the push is queued, and the page's own owner recomposes behind it
      // (the font page's current-font read). The wholesale path would have
      // consumed the navigation seat; this one landed instead, so it does.
      // Deferred for the same reason as the re-seat above.
      else if (navSeat) Idle.run(() => panel.applyFrameState(), 2)
      // A reveal with no launch in it: a showIf verdict, a guard verdict, a
      // "/" filter. The row set moved under the cursor, and the cursor goes
      // with the row it was on: the row that appeared or disappeared above
      // it must not move it, and the row it was on must not be lost. The
      // view owns that - a replaced model takes the cursor with it, and
      // List gives the row back by identity.
      panel.queueFit()
      return
    }

    // The same answer as the incremental path above: park the view at the
    // head before the write, so the swap captures and restores the top
    // rather than the offset the previous query was scrolled to.
    if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
    panel._swapGen++
    const g = panel._swapGen
    const sameContent = panel._sameRecords(records)
    if (!sameContent) {
      list.beginSwap()
      panel._swapping = true
      // The pending generation describes the swap that is actually running.
      // Set for an install that begins no swap it is a claim nobody retires,
      // and the deferred release below then stamps a swap-recency window on a
      // write that replaced nothing.
      panel._swapPendingGen = generation
    }
    panel._clearCursorForSwap(records)
    if (!sameContent) {
        // The same answer as the incremental path above: the search
        // projections seat the head of the new order instead of keeping
        // the cursor's row, so they do not ask the view to keep it.
        panel._writeRecords(records, !panel.searching && !panel.scopedSearching
          && !panel._searchReturnPending)
        // Wholesale never glides, so every write here arms the handshake.
        panel._quiesceArm()
        // The summon's own install: the deferred fit below lands three turns
        // after the card is already on screen, so the region held a
        // provisional height and the card grew once - on the first open of a
        // page and never again, because a later open installs nothing. The
        // show gate has not released, so no click can have opened a row; with
        // nothing open and nothing closing, the model height is final.
        if (!panel.shown && !panel.searching && !panel.scopedSearching
          && panel.expansionNeedH <= 0 && !Menu.slotClosing) panel.fitFromModel()
      }

    // A page swap owns the whole frame: it is one wholesale replacement, so
    // there is no outgoing highlight to hand off and recomputeRows has already
    // run the fit in this turn. Closing the swap here (instead of two or three
    // turns later) is what stops the card from painting a held highlight and
    // re-fitting itself across several frames. The only thing left for a later
    // turn is the re-seat safety net, which is invisible when it lands on the
    // row the same-turn seat already chose.
    if (sameTurn === true) {
      if (panel._swapping) {
        panel._swapping = false
        panel._swapPendingGen = -1
        list.endSwap()
      }
      // A search install also comes through this same-turn branch. The seat
      // saved at entry belongs to the EXIT install, not to the keystrokes
      // that build the projection: consuming it here left the erase with no
      // saved seat, so the page restore kept the result row by identity for
      // a frame (the Reload flash) before another seat corrected it.
      const leavingSearch = !panel.searching
      // A result landing owns the page cursor. Its query clear still comes
      // through this edge, but there is no saved seat to restore: keep the
      // whole restore block (fit recommit, settle waiter, re-seat) out of
      // the landing's way and let the navigation's pending seat win.
      const restoreSeat = leavingSearch && !panel._searchClearByResult
      const returnIdx = restoreSeat ? panel._searchReturnIdx : -1
      const returnY = restoreSeat ? panel._searchReturnY : -1
      if (leavingSearch) {
        panel._searchReturnIdx = -1
        panel._searchReturnY = -1
        panel._searchReturnUid = ""
      }
      if (panel.searching || panel.scopedSearching) panel.seatFilteredHead()
      else {
        if (typeof list.unpinHighlight === "function") list.unpinHighlight()
        list._keepCursor = false
        // A search restore installs the page's rows through this same-turn
        // branch. Arming the claim here would let pursuit read the projection's
        // transient short viewport and scroll a row that was already in view;
        // the fit sizes the card from the restored rows in this turn. With no
        // saved seat to honour, the ordinary path still arms immediately.
        if (returnIdx < 0) panel._rearmOpenSlot()
      }
      Idle.run(() => {
        // A result landing owns the page cursor. Re-asserting the page's
        // remembered frame here would pull the cursor off the row the
        // navigation just seated, one turn after it lands.
        if (!panel._searchClearByResult) panel._reseatFrameSel()
        if (panel.searching) {
          panel._restoreSeatPending = false
          return
        }
        // The frame does not always hold this page's seat. When the row held
        // at search entry is still expanded, restore the cursor and the scroll
        // offset: the bar is the slot's only background, and the offset keeps
        // the unfolded list inside the viewport.
        if (returnIdx >= 0 && returnIdx < panel.rowsModel.length) {
          const it = panel.rowsModel[returnIdx]
          if (it && (Menu.isExpanded(it) || Menu.infoOpen(it))) {
            if (returnY >= 0) list.restoreAt(returnIdx, returnY)
            else if (list.currentIndex !== returnIdx) list.seat(returnIdx, "land")
          }
        }
        if (returnIdx >= 0) {
          // A fit queued by the projection can never settle while an open
          // slot holds expansionNeedH above zero. Retire it here: the
          // restored model is the final size, and committing it directly is
          // what lets the claim arm against the viewport the page will show.
          panel._fitPending = false
          panel._fitGen++
          panel._recommitRestingH()
          panel._restoreSeatPending = false
          // Arm the claim only when the restored card has stopped moving.
          // Arming against the projection's short viewport seats the row
          // past its saved offset and leaves the page scrolled wrong.
          panel.whenSettled(function() {
            // A result can clear the query and land on another page, or on a
            // different row of the same page. Either way the landing owns the
            // cursor; the seat saved at search entry belongs to an intent the
            // result superseded.
            if (panel._searchClearByResult
              || (panel._searchReturnPage !== ""
                && Menu.frame && Menu.frame.id !== panel._searchReturnPage)) {
              panel._searchReturnPage = ""
              list.dropKeepRow()
              panel._finishModeRestore()
              panel._searchClearByResult = false
              return
            }
            panel._searchReturnPage = ""
            panel._finishModeRestore()
            panel._rearmOpenSlot()
            panel._followSlotRow()
            panel._latchClaim()
            if (returnY >= 0) list.restoreAt(returnIdx, returnY)
            list.dropKeepRow()
          }, function(row) {
            return panel._modeRestoreSettled(row, returnIdx,
              panel._searchReturnPage, panel._searchClearByResult)
          })
        }
      }, 2)
      return
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
        if (panel._swapping) {
          panel._swapping = false
          panel._swapPendingGen = -1
          list.endSwap()
        }
        if (panel._swapGen !== g || panel._pendingGen !== generation) {
          panel._reseatFrameSel()
          return
        }

        // The restore install is a separate pass from the rev that cleared
        // the claim; re-derive it here so the fit reads the restored rows.
        if (!panel.searching && !panel.scopedSearching) panel._rearmOpenSlot()
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

  function _queueRows(records, plan, defer, sameTurn) {
    if (records === null) {
      panel._invalidatePendingRows()
      return
    }
    panel._pendingCandidate = records
    panel._pendingPlan = plan
    panel._pendingGen++
    if (panel._swapping && panel._swapPendingGen !== panel._pendingGen)
      panel._releaseSwap()
    // A page swap takes over a still-queued install: its own flush would land
    // the new candidate a turn late. The superseded closure returns on the
    // cleared latch below, so only this turn writes.
    if (panel._rowsPending && sameTurn !== true) return
    panel._rowsPending = true
    const flush = () => {
      if (!panel._rowsPending) return
      const generation = panel._pendingGen
      const candidate = panel._pendingCandidate
      const install = panel._pendingPlan
      panel._pendingCandidate = null
      panel._pendingPlan = null
      panel._rowsPending = false
      if (candidate === null || generation !== panel._pendingGen) return
      // Search projections flush in this turn through the `searching` term
      // below, not through the caller's sameTurn flag. Carry that decision
      // into the install so a wide ranked set gets the same-turn swap close
      // and seat as a page swap instead of the multi-turn finalize.
      const installNow = sameTurn === true || panel.searching || panel.scopedSearching
      panel._installRows(candidate, install, generation, installNow)
    }
    // A page swap, like a search projection, installs in this turn instead of
    // on the next event-loop hop. recomputeRows has already published
    // rowsModel and resized the card synchronously, so deferring only the
    // view's model paints the resized window with the outgoing page's rows
    // for a frame - visible on cold boot (no slide tween) and on back
    // navigation, where the short submenu's rows sit in the taller card.
    // Search is already a Qt.callLater turn out of the field's text-change
    // signal; navigation runs from the page-id handler, and neither writes
    // the property that triggered it. A write the quiesce handshake has not
    // settled still defers, through the forced path in _installRows, so
    // back-to-back installs cannot strand delegates.
    if (defer !== true && (sameTurn === true || panel.searching || panel.scopedSearching)) {
      flush()
      return
    }
    Idle.run(flush)
  }

  // Arm the latch and start its window together: the sync that arms it is
  // the one whose install makes the rows move.
  property bool _rowsMoving: false

  // `plan` is rowSyncPlan's answer, handed in by the one entry point that
  // has the intent and the row count (recomputeRows). This function installs
  // it and never re-derives it.
  function syncRowsList(candidate, plan, records, sameTurn) {
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
    panel._queueRows(keyed, plan, false, sameTurn)
    return true
  }

  // Row-motion latch, true while the view's add/remove-displaced glide is
  // still running. ListView does not publish an end edge for those
  // transitions, so this is a grace window matched to their source clock
  // (Ui.fastGraceMs), not a guess at readiness: the live fit verdict below
  // still gates every measurement. Gated on MotionPolicy through the token,
  // so a kill-switched shell never waits for a transition that is off.
  Timer {
    id: rowsMotionTimer

    interval: Ui.fastGraceMs
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

  function _reweaveOnWidth() {
    if (!Menu.open || panel.searching) return
    if (panel._seenGridCols === panel.gridCols) return
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
    panel.recomputeRows("reveal", true)
  }

  onGridColsChanged: {
    if (!Menu.open || panel.searching) return
    if (panel._seenGridCols === panel.gridCols) return
    // No width ease to ride (motion off, or no tween in flight): the
    // geometry is final now, so re-weave in this turn and publish card
    // and rows together. A live glide owns the width; its landing edge
    // does the re-weave once, on the final column count.
    if (!panel.shown || !MotionPolicy.enabled || !widthAnim.running)
      panel._reweaveOnWidth()
  }

  Connections {
    target: widthAnim

    function onFinished() { panel._reweaveOnWidth() }
  }

  onSearchingChanged: {
    panel.projectionRev++
    // A new query is a newer cursor intent than the seat the previous exit
    // was restoring; the row target must not fight the projection's head.
    if (panel.searching) list.dropKeepRow()
    // A query is the user asking for something else, so the launch that
    // wanted the head is over - whether or not the projection ever moves
    // the cursor, which a query with no hits does not.
    panel._summonSeat = false
    // Only ENTERING search retires the page's claim. This handler also runs
    // on the erase edge, when the restore install re-arms the claim for a
    // still-expanded row. Teardown there drops that claim, leaves the card at
    // the resting size and strips the region from the open dropdown.
    if (panel.searching) {
      // Grid pages seat their cursor on GridList, not List. Reading List here
      // saved -1, and the search-exit restore only starts its fade-in when a
      // seat was saved, leaving a grid card blank after the query was erased.
      const at = panel.gridMode ? Math.max(0, grid.currentIndex) : list.currentIndex
      panel._searchReturnIdx = at
      panel._searchReturnPage = Menu.frame ? Menu.frame.id : ""
      panel._restoreSeatPending = at >= 0
      const saved = panel.rowsModel[at]
      panel._searchReturnUid = saved ? String(saved.uid) : ""
      // The live contentY can already be a transient: entering search takes
      // focus, and a follow may centre the row before this handler runs. The
      // page's remembered frame is the seat the user actually left, so use
      // it when it names the same row; otherwise the live offset is all
      // there is.
      const remembered = Menu.frame ? Menu.savedFor(Menu.frame.id) : null
      const sameRow = !!(remembered && saved
        && String(remembered.uid) === String(saved.uid))
      panel._searchReturnY = panel.gridMode ? -1
        : sameRow ? (typeof remembered.y === "number" ? remembered.y : -1)
        : list.contentY
      panel._searchReturnOpen = !!saved
        && (Menu.isExpanded(saved) || Menu.infoOpen(saved))
      panel._modeReturnGrows = panel._modeWillGrow(list.currentItem)
      panel._beginModeRestore("search")
      list.contentY = 0
    } else {
      panel._pinModeRestoreFloor(panel._searchReturnOpen,
        panel._searchClearByResult)
      panel._searchReturnOpen = false
    }
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
          // A result selection fades the query on its own clock; clearing it
          // here would drop the text in one frame before that fade lands.
          if (searchField.text !== "" && !panel.handoffActive)
            searchField.text = ""
          if (panel.mode === "filter") focusCtrl.grabList()
        }
      })
    }
    // Leaving search replaces the whole projection with the page's rows:
    // an identity swap, not a row appearing or disappearing, and the
    // cursor is re-seated from the page's remembered frame.
    // The card is resized to the page's rows in this turn. Install them in
    // this turn too: a deferred _records would paint the outgoing search
    // projection (separators and all) in the full-page box for a frame.
    // resetSearch writes query, not the field, so this cannot re-enter.
    if (!panel.searching) panel.recomputeRows("rebuild", true)
  }
  onCurrentPageIdChanged: {
    // A row target names a row on the page that saved it. A page change is
    // a newer intent, so the target retires with the old page.
    list.dropKeepRow()
    panel._restoreSlotStartH = -1
    panel._searchReturnOpen = false
    panel._scopedReturnOpen = false
    panel._modeRestoreFitOwned = false
    // A new page means a new row set: any reveal claim from the page being
    // left (an open slot, a search projection) no longer names a row here,
    // and a stale out-of-bounds index would make pursuit scroll the new
    // list into empty space. Drop it before the transition/rebuild below.
    Menu.trace("panel.clear", { site: "pageChange", auto: list.autoRevealIndex })
    list.autoRevealIndex = -1
    list._followIdx = -1
    list.contentY = 0
    let transitionGen = -1
    if (Menu.open) transitionGen = panel.beginPageTransition(false)
    else panel._invalidatePageCallbacks()
    // A new page is a new row set under a slide that masks the refill;
    // the old page's cursor index has no meaning here. Cancel any
    // deferred reveal/install left over from the leaving page first, so
    // it cannot land on the destination page.
    panel._invalidatePendingRows()
    // Install the landing row set in this turn, alongside the resize: the
    // card owns the new box now and a deferred _records would paint the
    // outgoing page's rows into it for a frame.
    panel.recomputeRows("rebuild", true)
    if (transitionGen < 0) return
    // The model reset parks the cursor at the head on its own. With the
    // install now in this turn, seat the frame's remembered row here too so
    // the first painted frame already highlights the link we came back to.
    // The same-turn install closes its own swap before this seat runs, so no
    // later applyFrameState is left to move the cursor again.
    panel.applyFrameState()
    const depth = panel._pendingSlideDepth
    if (depth < 0) return
    // A page that will not tween has nothing to hide the swap behind, so
    // reveal it in this turn too. Deferring the snap left the freshly resized
    // card empty for a frame (cold boot and motion off); a real slide still
    // starts a turn later, masked by its own fade.
    if (listBox.lastDepth === -1 || !MotionPolicy.enabled
      || depth === listBox.lastDepth) {
      panel._pendingSlideDepth = -1
      listBox.slideFor(depth, transitionGen, true)
      return
    }
    Qt.callLater(() => {
      if (transitionGen !== panel._transitionGen
        || !Menu.open || !panel._transitionActive) return
      if (panel._pendingSlideDepth < 0) return
      const pendingDepth = panel._pendingSlideDepth
      panel._pendingSlideDepth = -1
      listBox.slideFor(pendingDepth, transitionGen, true)
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

  // --- shared mode restore ---
  // Search and the scoped filter project a row set away and hand it back.
  // Their seats differ - global search re-seats from the frame, the filter
  // resolves a uid and a group child - but the geometry contract does not.
  // These four rules live here once so a fix to one mode cannot drift out of
  // the other; the mode handlers only supply their seat and their claim tail.

  // Mode arm: retire any floor left by a previous clear, drop the claim that
  // names a row of the outgoing projection, and hand the dropdown's shrink
  // to the one height tween instead of snapping the card to the resting size.
  function _beginModeRestore(site) {
    panel._restoreSlotStartH = -1
    Menu.trace("panel.clear", { site: site, auto: list.autoRevealIndex })
    list.autoRevealIndex = -1
    list._followIdx = -1
    const from = panel._currentListH()
    const base = panel._restingFallbackH()
    panel._releaseSlotRegion()
    if (from > base + 0.5 && !panel._heightAnimating
      && !panel._transitionActive && panel.shown && MotionPolicy.enabled)
      panel._startHeightTransition(base, -1, from)
  }

  // Whether the row open at arm time grows the card past the page's resting
  // height. A dropdown that fits the page needs no slot-driven restore: the
  // fit tween owns the card from the projection's height to the page's height.
  property bool _modeReturnGrows: false
  property bool _modeRestoreFitOwned: false

  function _modeWillGrow(row) {
    return !!row && row.settledHeight > panel._modelListH() + 0.5
  }

  // Mode clear with an expanded row: pin the outgoing card height as the
  // floor the restored slot unfolds from. Without it the fit commits the
  // full page resting size on the swap and the last dropdown is cut off.
  // A dropdown that already fits the page is the other case: leave the
  // region clear and let the fit tween carry the card the whole way.
  function _pinModeRestoreFloor(open, blocked) {
    if (!open || blocked || panel.gridMode) return
    if (!panel._modeReturnGrows) {
      // With motion off the fit snaps, so there is no tween to own and no
      // onFinished to retire the gate.
      panel._modeRestoreFitOwned = MotionPolicy.enabled
      return
    }
    panel._restoreSlotStartH = panel._currentListH()
    panel._slotRegionH = panel._restoreSlotStartH
    panel._heightAnimating = false
    heightAnim.stop()
    panel._animatedListH = -1
    panel._heightTargetH = -1
  }

  // The settle edge that retires the floor: the saved row is back under the
  // cursor and its slot has reached the height the fit measured. A landing
  // that superseded the saved seat (`blocked`), or a page change, retires it
  // immediately instead of leaving a waiter parked on a row that never came.
  function _modeRestoreSettled(row, idx, page, blocked) {
    if (panel._restoreSlotStartH < 0 || blocked
      || (page !== "" && Menu.frame && Menu.frame.id !== page)) return true
    return list.currentIndex === idx
      && Math.abs(row.height - row.settledHeight) < 0.5
  }

  // Common geometry completion. The mode handler still owns its own seat and
  // claim choreography; this is the one place the card stops being a mode
  // projection and starts being the page again.
  function _finishModeRestore() {
    panel._restoreSlotStartH = -1
    panel._recommitRestingH()
  }

  // Re-derive the open-slot claim from the CURRENT row set. The service rev
  // handler derives it on state changes; the search restore installs the
  // original rows in a separate pass. Both paths need this derivation so an
  // expanded row always has a reveal claim, a grown card and a region.
  function _rearmOpenSlot() {
    // A mode swap still owes the page its saved seat. Any arm here would read
    // the projection's short viewport and move a row that was already in view;
    // the restore edge clears this gate once the card has settled.
    if (panel._restoreSeatPending) return
    // A nested close holds the claim clear until its restore has settled;
    // re-arming sooner chases a shrinking target and moves the view again.
    if (panel._nestedSeatPending) return
    // A result handoff owns the claim: its group arms it on the expansion
    // edge, when the settled height already includes the dropdown. Re-arming
    // here against the trimmed row would reveal its collapsed top instead.
    if (panel._handoffReveal) return
    let revealIdx = panel._trackedOpenIdx()
    if (revealIdx === -2) revealIdx = panel._scanOpenSlot()
    if (Menu.traceEnabled) {
      let open = []
      for (let i = 0; i < panel.rowsModel.length; i++) {
        const it = panel.rowsModel[i]
        if (it && (Menu.isExpanded(it) || Menu.infoOpen(it)))
          open.push(i + ":" + String(it.id ?? "") + ":" + String(it.uid ?? ""))
      }
      Menu.trace("panel.rearm", {
        found: revealIdx, count: panel.rowsModel.length,
        searching: panel.searching, scoped: panel.scopedSearching,
        auto: list.autoRevealIndex, open: open.join("|")
      })
    }
    if (revealIdx >= 0) {
      list.autoRevealIndex = revealIdx
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
  }

  // A mode swap replaces the row set while an open slot keeps expansionNeedH
  // above zero, so the "last slot closed" commit never runs for the restored
  // page. Recommit the resting size from the restored model here instead:
  // _committedListH is the base every size derivation reads, and leaving the
  // projection's one-row latch there made the card and window resize from a
  // height no restored row owns.
  function _recommitRestingH() {
    if (panel._transitionActive || panel._heightAnimating || panel._fitPending) return
    panel._latchedListH = -1
    panel._committedListH = panel._modelListH()
  }

  // One route for every service-side trigger of recompute/refresh/open.
  Connections {
    target: Menu

    // A bash guard verdict landed, so guarded rows appear or disappear
    // under the user exactly like showIf rows do. Same reveal intent, so
    // the same add/remove transitions run; only the 400ms guard debounce
    // in front of it is specific to this mechanism.
    function onGuardWhenChanged() {
      // This reveal is debounced upstream, so publishing it same-turn is
      // safe: sameTurn bypasses the quiesce hold and geometry and rows
      // land together instead of the card resizing a turn before its rows.
      panel.recomputeRows("reveal", true)
    }

    function onResultsChanged() {
      // The projection is the caller's row set here, and whether it is
      // wide enough to install wholesale is the plan's business, not
      // this handler's. Off-search the candidate is the page's own rows
      // and compares equal, so the early return keeps this inert.
      panel.recomputeRows("reveal")
    }

    // The arm itself only owns the field and the key route. Leaving it clears
    // the bar and hands focus back; geometry follows the query-aware state in
    // onScopedSearchingChanged below. Deferred outside the activation event
    // so an Enter that pushes a page cannot re-fire on the new page's row.
    function onScopedActiveChanged() {
      if (Menu.scopedActive || !Menu.open) return
      Qt.callLater(() => {
        if (!Menu.scopedActive && Menu.open) {
          if (searchField.text !== "") searchField.text = ""
          if (panel.mode === "filter") focusCtrl.grabList()
        }
      })
    }

    // Arming the field changes the filter chrome and the key route, not the
    // row set. The projection follows the query-aware state, so this handler
    // runs only when the view actually enters or leaves a filtered set.
    function onScopedSearchingChanged() {
      panel.projectionRev++
      panel._summonSeat = false
      const leaving = !panel.scopedSearching
      if (!leaving) {
        // Arming: remember where on the page the user stood. A nested hit is
        // rendered at the top register while the filter is up and the group
        // row underneath it is unmounted, so this is the only copy of the seat
        // that survives until the page comes back.
        panel._scopedReturnIdx = list.currentIndex
        panel._scopedReturnY = list.contentY
        panel._restoreSeatPending = list.currentIndex >= 0
        const it = list.currentIndex >= 0 && list.currentIndex < panel.rowsModel.length
          ? panel.rowsModel[list.currentIndex] : null
        panel._scopedReturnUid = it && it.uid !== undefined ? String(it.uid) : ""
        panel._scopedReturnPage = Menu.frame ? Menu.frame.id : ""
        panel._scopedReturnOpen = !!it
          && (Menu.isExpanded(it) || Menu.infoOpen(it))
        const rowItem = list.currentItem
        panel._modeReturnGrows = panel._modeWillGrow(rowItem)
        panel._scopedReturnChild = rowItem && rowItem.isGroup
          ? rowItem.childIndex : -1
        panel._beginModeRestore("filter")
      }
      if (leaving) {
        panel._pinModeRestoreFloor(panel._scopedReturnOpen,
          panel._scopedClearByAction)
        panel._scopedReturnOpen = false
      }
      // Arming or clearing the "/" filter trims and restores the CURRENT
      // page's rows: rows leave and come back in place, so this is a
      // reveal like any other. Clearing also restores the full page box in
      // this turn, so the restored rows have to land in it this turn too.
      panel.recomputeRows("reveal", leaving)
      if (!leaving) return
      // The restored rows are installed now. Arm the reveal on this edge,
      // before the slot's first unfold frame: waiting for a settled waiter
      // let the row grow halfway and made the region publish a height the
      // card had never shown. The row's live height then drives the card.
      const returnRow = panel.rowsModel[panel._scopedReturnIdx]
      // A fit-owned restore keeps the saved scroll fixed while the viewport
      // grows: pursuit would scroll down to keep the short dropdown in view
      // and the final seat would then snap it back. The reveal is armed at
      // the end of that restore instead.
      if (panel._scopedReturnIdx >= 0 && returnRow && Menu.isExpanded(returnRow)
        && !panel._modeRestoreFitOwned)
        list.autoRevealIndex = panel._scopedReturnIdx
      // Seat the captured row back after the page's rows are installed. The
      // uid names the row, not the number it had in the trim; the scroll goes
      // back with it so an expanded group's slot is still inside the viewport.
      Idle.run(() => {
        const idx = panel._scopedReturnIdx
        const y = panel._scopedReturnY
        const uid = panel._scopedReturnUid
        const child = panel._scopedReturnChild
        const samePage = Menu.frame && Menu.frame.id === panel._scopedReturnPage
        panel._scopedReturnIdx = -1
        panel._scopedReturnY = -1
        panel._scopedReturnUid = ""
        panel._scopedReturnPage = ""
        panel._scopedReturnChild = -1
        if (panel._scopedClearByAction) {
          panel._scopedClearByAction = false
          panel._restoreSeatPending = false
          // The filter's fit was queued for the trimmed row set and can never
          // settle while the result's group is open. Retire it so the landing
          // owns the reveal and its settled waiter can run.
          panel._fitPending = false
          panel._fitGen++
          // A flat result's landing owns the reveal: its group expands AFTER
          // the rows are restored and Entry arms the claim on that edge,
          // when the row's settled height already includes the dropdown.
          // Re-arming here would pursue the still-collapsed row's top and
          // leave the page scrolled short of the manual reveal.
          return
        }
        if (Menu.scopedActive || !Menu.open || !samePage) {
          panel._restoreSeatPending = false
          return
        }
        let at = uid !== "" ? panel.indexOfUid(uid) : -1
        if (at < 0) at = idx
        if (at >= 0 && at < panel.rowsModel.length) {
          // A filter that narrowed this group to a non-seatable child left its
          // child cursor at -1. Restore it BEFORE the scroll seat: the group's
          // bar and push are derived from the focused child, so seating the
          // scroll first would be chased by a second offset once the cursor
          // lands on that child again.
          const rowItem = panel.gridMode ? grid.currentItem : list.itemAtIndex(at)
          if (child >= 0 && rowItem && rowItem.isGroup
            && typeof rowItem.childIndex === "number") {
            const kids = rowItem.groupChildren.length
            rowItem.childIndex = Range.clamp(child, 0, Math.max(0, kids - 1))
          }
          if (y >= 0) list.restoreAt(at, y, panel._modelListH())
          else if (list.currentIndex !== at) list.seat(at, "land")
          panel.recordSeat()
        }
        // The row the cursor came back to may still own an open slot. The
        // filter projection dropped its reveal claim; re-derive it against the
        // restored rows so the card, region and bar grow back together. Its
        // resting size is likewise the restored model's, not the trim's: no
        // slot closed on this edge to commit it through the usual path.
        // A fit queued by an intermediate filter query never settles while
        // the restored group is open. Retire it and commit the restored
        // model's size here, then re-arm against that final viewport.
        panel._fitPending = false
        panel._fitGen++
        panel._restoreSeatPending = false
        panel.whenSettled(function() {
          panel._finishModeRestore()
          if (y >= 0) list.restoreAt(at, y, panel._modelListH())
          // The filter left a claim and growth sized for its one-row trim.
          // Clear them before re-arming, or the stale growth makes pursuit
          // seat the restored group at its row top instead of the saved
          // scroll offset.
          // The row's reveal rose while the filter was being cleared, before
          // the stale claim was released. No edge remains to re-latch it, so
          // do it here with the row's final geometry - but only when the
          // restored page actually had a growth claim to begin with.
          const hadClaim = panel._claimListH > 0
          panel._releaseSlotRegion()
          panel._followSlotRow()
          if (hadClaim) panel._latchClaim()
          // The projection cleared the claim with the filter rows. Re-arm it
          // on THIS edge, not a turn later: deferring let the restored slot
          // unfold halfway before the claim appeared, so the region was
          // published from a height the card had never shown and jumped.
          if (!Menu.scopedActive && list.autoRevealIndex < 0)
            list.autoRevealIndex = at
        }, function(row) {
          // The filter's page check already ran in the seat pass above, so
          // only the shared floor and settled-row verdict gates the finish.
          return panel._modeRestoreSettled(row, at, "", false)
        })
      }, 2)
    }

    function onScopedProjectionRevChanged() {
      panel.recomputeRows("reveal", true)
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
      panel._resetNestedSeat()
      metrics.clearShapeCache()
      panel._quiesceDisarm()
      // Different containers mean a different row set outright, and the
      // metric maps above were just dropped with nothing to glide. A genuine
      // new container is one wholesale swap, so publish it same-turn.
      panel.recomputeRows("rebuild", true)
    }

    // A store change flipped a showIf verdict - reveal/hide animated.
    // The reveal intent arms the add/remove transitions so the row slides
    // out from under its parent instead of popping.
    function onCondRevChanged() {
      panel.scheduleCondReveal()
      panel.seatPastUnavailable()
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
      panel._rearmOpenSlot()
      // Expand/collapse rides the store rev: grow for the open dropdown,
      // fall back to the closed measure when it shuts. Idempotent -
      // assigning the settled width notifies nothing.
      metrics.applyDropdownWidth()
    }

    function onOpenChanged() {
      if (Menu.open) {
        // The summon edge, and the only one: this runs on the open itself,
        // before any row set or fit belongs to the new page, which is what
        // makes it the right place to read the height the card is leaving
        // behind.
        panel.beginPageTransition(true)
      panel._resetNestedSeat()
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
        // warm view still holding index 3 from the previous page, no seat ran at
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
          panel.applyFrameState()
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
      panel.recomputeRows("reveal", true)
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
        panel.recomputeRows("reveal", true)
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
  // path could correct it in time: the first fit of a picker open was
  // committed against the previous ceiling and the resulting 542px card was
  // the first painted frame, one frame at a 177px lower top edge before the
  // corrected 365px fit landed. Depending on Menu.frame makes the chain dirty
  // the moment the stack is seated, which is the invalidation the cached
  // projection lacks.
  readonly property int pageMaxHeight: {
    // On a cold first summon the frame and the bundle can land in separate
    // turns: reading only the frame gives no ceiling for that one fit, so a
    // picker that declares a ceiling sizes from the screen share and then
    // snaps down. The bundle's entry page is the page this open is about to
    // show, and is already installed by the time the first fit runs.
    const pg = Menu.pageById(Menu.frame ? Menu.frame.id : "")
      || Menu.pageById(Menu.bundle ? Menu.bundle.entry : "")
    return pg && typeof pg.maxHeight === "number" && pg.maxHeight > 120
      ? Math.round(pg.maxHeight) : 0
  }

  // A page may declare its own ceiling, including one taller than the panel's
  // default. The default still applies to pages that name none.
  readonly property real effMaxHeight: panel.pageMaxHeight > 0
    ? Math.min(panel.pageMaxHeight, panel.hardMaxHeight) : panel.maxHeight

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

  // Live row count, not the cached `gridContentH` binding: inside the install
  // that publishes rowsModel, the derived gridRows binding can still hold the
  // OUTGOING set's count, which made the first fit see 0 rows and drop the
  // card to chrome height for one frame.
  function _gridContentH() {
    return Math.ceil((panel.rowsModel || []).length / Math.max(1, panel.gridCols))
      * panel.gridSide
  }

  function _snappedRowsH(rows, avail, maxRows) {
    const limit = Range.clamp(avail, 0, panel.screenMaxListH)
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
  // pickers, and the smallest of them silently cost a picker half
  // its rows while making the card shorter than pages showing more.
  // `rowPolicyBound` below reports which of the two is holding the size, so
  // an override is something a reader can see rather than infer.
  readonly property real cappedAvailH: {
    const avail = panel.availListH
    // Grid cards never size from row heights (gridRows * gridSide, see
    // snappedListH/listRegionH and the width rule below), so the row set is
    // not worth summing here even though the sum is now plain arithmetic.
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
  property int _slotMsLatch: 0

  // The resting size is what the fallbacks measure against, so it is
  // re-latched the moment the last slot closes and the live geometry is a
  // slot-inflated height again. On the closing edge only: expansionNeedH
  // changes every frame of an unfold, and writing the same resting value
  // on each of them is a per-frame write that can also land in the middle
  // of a fit's own commit.
  onExpansionNeedHChanged: {
    if (panel.expansionNeedH > 0) return
    Menu.trace("panel.expNeed0", {
      need: panel.expansionNeedH,
      regionH: Math.round(panel.listRegionH * 10) / 10,
      slotRegion: Math.round(panel._slotRegionH * 10) / 10,
      claim: Math.round(panel._claimListH * 10) / 10,
      model: Math.round(panel._modelListH() * 10) / 10,
      resting: Math.round(panel._restingFallbackH() * 10) / 10,
      committed: Math.round(panel._committedListH * 10) / 10
    })
    if (!panel._transitionActive && !panel._heightAnimating && !panel._fitPending) {
      // listRegionH reads the slot region here: the slot is empty but the
      // region has not been released. Latching that value would install the
      // grown size as the resting size and leave an empty band under the last
      // row. The resting size is the model's answer, not the live region.
      panel._committedListH = panel._modelListH()
    }
  }

  // Content height as of the last idle moment (no open/closing slot).
  // Diagnostic only since the per-text estimate cache landed: sizing reads
  // modelContentH() because sampled contentHeight extrapolates mid-layout
  // and latches stale on static pages. Kept for probe comparison.

  // Absolute ceiling from the screen (injected by MenuView); the normal
  // resting cap stays maxHeight. Only the growth path may exceed it.
  property real hardMaxHeight: 1200

  readonly property real screenMaxListH: Math.max(availListH,
    hardMaxHeight - panel.regionChromeH)

  // What the layout needs to know about a row, resolved ONCE per install (see
  // projectRows): the sub line it will draw, the widest display a value slot
  // can be asked to hold, and the rest height its own line registers produce.
  //
  // WHY A SIDE MAP AND NOT KEYS ON THE ROW. The rows are Menu's own records,
  // and a layout fact is not a property of a bundle; stamping it onto the
  // record would publish it in `dump` and travel with the page. The map is
  // keyed by uid, which keyedRows has already proven unique across the model,
  // and is rebuilt wholesale on install - so it is bounded by the installed
  // row set, not by a session.
  property var _rowFacts: ({})

  // Resolve every provider answer the layout reads, at the one moment a row set
  // is installed. Heights and widths then measure a projection instead of
  // calling a provider hook in the middle of a measurement - a dispatch that
  // can allocate, run a user surface, or depend on the very geometry being
  // computed.
  function projectRows(rows) {
    const facts = {}
    for (let i = 0; i < rows.length; i++) {
      const it = rows[i]
      if (!it || it.uid === undefined || it.uid === null) continue
      facts[String(it.uid)] = panel._factsFor(it)
    }
    panel._rowFacts = facts
  }

  // One row's layout facts, resolved once per install. The line registers are
  // the row's own: a Latin-only row takes RowGeometry's primary tokens while
  // a row that reaches a fallback face takes its taller pair, so one Arabic
  // label does not inflate every row on the page.
  function _factsFor(it) {
    if (it.type === "separator") {
      const lbl = String(it.label ?? "")
      const lineH = RowGeometry.subHFor(lbl)
      return {
        sub: "",
        widest: "",
        restH: Number(it.sepHeight) > 0 ? Number(it.sepHeight)
          : RowGeometry.restSeparatorFor(lbl !== "", lineH)
      }
    }
    // One provider resolution for both facts (see Menu.rowFactsFor): the
    // install runs per keystroke over the whole projection.
    const f = Menu.rowFactsFor(it)
    const kind = MenuLib.restKind(it, f.sub)
    const labelH = RowGeometry.labelHFor(String(it.label ?? ""))
    const subH = RowGeometry.subHFor(RowGeometry.subSampleFor(it, f.sub))
    return {
      sub: f.sub,
      widest: f.widest,
      restH: RowGeometry.restHFor(kind, labelH, subH)
    }
  }

  // The projection for one row, with a cold fallback for a row no install has
  // seen (a delegate built from a record the panel has not adopted). The
  // fallback is the only path here that asks a provider, and it is not on the
  // install path.
  function rowFacts(itm) {
    if (!itm) return {
      sub: "", widest: "",
      restH: RowGeometry.primaryRestH("line")
    }
    const hit = panel._rowFacts[String(itm.uid)]
    if (hit !== undefined) return hit
    return panel._factsFor(itm)
  }

  // The card's WIDTH rule (see MenuWidth): the page's rows measured through
  // the shaping probes, cached and bounded, with the open-dropdown growth.
  // Heights are RowGeometry's and never consult any of it.
  MenuWidth {
    id: metrics
    host: panel
  }
  // Late-boot icon prewarm. The panel persists from boot across open/close, so
  // its warmer decodes menu glyphs into Qt's shared pixmap cache at THIS
  // window's DPR before the first summon creates any delegates. Menu rows
  // paint at Ui.rowIconW, the same side the consuming Icon uses.
  IconWarmer {
    id: iconWarmer
    side: Ui.rowIconW
  }
  function prewarmIcons(list) { iconWarmer.warm(list) }
  // Content width as the width engine measured it. The card's width binding and
  // the saved frame read this projection; only the engine writes it.
  readonly property real contentW: metrics.contentW

  // Rest height of one row from the MODEL alone - RowGeometry's rule, which
  // the delegate applies to its own lines (desc/expand slots are closed at
  // rest). A row's height is a function of its KIND: a title line, plus the
  // second line the row spends on a sub line or on a theme's swatch strip,
  // plus the row's vertical padding, floored at Ui.rowMinH.
  //
  // Nothing here shapes a string, and that is the point. The estimate used to
  // measure each label and sub through probe Texts and cache the line box by
  // string, because a laid-out line box is not one number per font - "App
  // launcher" renders a pixel taller than "Mg", a fallback face taller still -
  // so the card and the delegate agreed only while both shaped the same text.
  // The line is pinned on both sides now, so there is nothing to measure, no
  // dictionary of strings to bound, and no reason for a height binding to read
  // a probe at all.
  //
  // Delegate-walking is forbidden here: ListView instantiates lazily, so any
  // sum over the created set changes while scrolling, which resized the card
  // on every tick and opened pages half-cut.
  function rowRestHeight(itm) {
    if (!itm) return Ui.rowMinH
    // The height was projected once, when this row set was installed: the
    // estimate reads the projection and never re-classifies (or asks a
    // provider) behind a binding. A separator is projected too, so its
    // breadcrumb and the delegate's sepH stay one number.
    return panel.rowFacts(itm).restH
  }

  // Largest prefix of the MODEL's row heights that fits avail with no
  // entry cut in half. Deterministic per rowsModel: scrolling, delegate
  // creation and search swaps never change it for the same rows.
  // The inter-row gap is the list's own, read through rowSpacing above.
  function snappedListH(avail, maxRows) {
    const limit = Range.clamp(avail, 0, panel.screenMaxListH)
    if (panel.gridMode) {
      if (panel.gridSide <= 0 || panel.rowsModel.length === 0) return 0
      if (panel.gridSide > limit)
        return Math.min(panel.gridSide, panel.screenMaxListH)
      return Math.min(Math.floor(limit / panel.gridSide) * panel.gridSide,
        Math.min(panel._gridContentH(), panel.screenMaxListH))
    }
    if (panel.rowsModel.length === 0) return 0
    return panel._snappedRowsH(panel.rowsModel, limit, maxRows)
  }

  // Full model content height - the resting "everything in one shot"
  // size. Replaces the stale contentHeight sampling as the region base.
  // The inter-row gap is the list's own spacing, which is not part of
  // delegate height but counts toward contentHeight.
  function modelContentH() {
    // The whole set, whatever its size: a row height is RowGeometry's
    // arithmetic on the row's kind, so a four-digit page costs a walk and no
    // shaping. The head-sample extrapolation this used to carry existed only
    // to keep per-string measurement off a giant page.
    return panel._sumRowsH(panel.rowsModel || [], 0)
  }

  readonly property real listRegionH: {
    if (panel.gridMode) {
      if (panel.rowsModel.length === 0) return Math.min(Ui.emptyMinH, panel.cappedAvailH)
      // The same hold the list branch has: while a fit is pending the card
      // must keep the size already on screen. Without it a grid search reads
      // gridContentH from the OUTGOING row set for one frame, jumps to that
      // height, then tweens back to the results' real size.
      if (panel._fitPending || panel.exactListH < 0) {
        const onScreen = panel._currentListH()
        const fallback = onScreen > 0 ? onScreen : panel._restingFallbackH()
        return Math.min(fallback, panel.screenMaxListH)
      }
      return Math.min(panel._gridContentH(), panel.snappedListH(panel.availListH))
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

  // Size animations stay disabled until the opening layout has fully
  // settled - otherwise the first real sizing catches the Behavior and
  // the card visibly grows on every summon (gap geometry rendering
  // mid-flight). Re-armed per open via onOpenChanged + showGate.
  property bool shown: false
  property bool _everShown: false

  Timer {
    id: showGate

    interval: Ui.resizeMs + Ui.fastMs

    onTriggered: {
      panel.shown = true
      panel._everShown = true
    }
  }

  // A close driven resize rides the slot's own pace. resizeMs spans about two
  // slot folds, and a Behavior clone keeps the template's duration, so both
  // would hold the card in a resize past the fold. The width is tweened
  // explicitly instead, the same way the card height is.
  property real _widthNow: Ui.defWidth
  NumberAnimation {
    id: widthAnim

    target: panel
    property: "_widthNow"
    easing.type: Easing.OutCubic
  }
  function _syncWidth() {
    const target = panel.widthTarget
    if (Math.abs(target - panel._widthNow) < 0.5) return
    const animated = MotionPolicy.enabled
      && (panel.shown || panel.searching || panel.scopedSearching)
    // A shrink with a live slot duration latch is a close driven resize: it
    // lands with the fold. An open or an unrelated resize keeps the normal
    // pace; those edges have no latch to read.
    const slotPace = panel._slotMsLatch > 0 ? panel._slotMsLatch
      : (list.revealSlotMs > 0 ? list.revealSlotMs : 0)
    const pace = target < panel._widthNow && slotPace > 0
      ? Math.max(Ui.fastMs, slotPace) : Ui.resizeMs
    widthAnim.stop()
    if (animated) {
      widthAnim.from = panel._widthNow
      widthAnim.to = target
      widthAnim.duration = pace
      Menu.trace("panel.widthArm", {
        from: Math.round(widthAnim.from * 10) / 10,
        to: Math.round(target * 10) / 10, ms: pace,
        closing: Menu.slotClosing, latch: panel._slotMsLatch
      })
      widthAnim.restart()
    } else {
      panel._widthNow = target
    }
  }

  // The card is between two widths. The rows read this to reveal their copy
  // along with the growth instead of eliding it away and snapping it back
  // (see Entry.textReveal). This is the explicit width tween above, not a
  // declared Behavior clone (whose `running` never sees a target, Glide.qml):
  // `widthAnim` is restarted by _syncWidth, so its running state IS the glide.
  // Reading it live keeps the verdict from outliving the motion: a row whose
  // copy already fits rests at reveal 1 either way. A cold frame has nothing
  // to unveil from and a snapped width has no glide to unveil against, so
  // both are excluded here.
  readonly property bool widthSettling: panel.shown
    && MotionPolicy.enabled && widthAnim.running

  // No Behavior on height: the slot-driven region is written straight from
  // the row's own unfold in _followSlotRow, and the card reads the SAME number
  // as the viewport (they are one box). A Behavior here would ease the card a
  // second time on top of the row's motion, so the card would lag the viewport
  // and the gap between them is exactly what clips the last row. Page
  // transitions and fits keep their own tween (heightAnim ->
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
    // A query's provisional answer is never the row set's size: the results
    // are installed a turn later, so the outgoing rows would size the card
    // for one frame. The fit after the install owns that resize.
    if (panel.searching || panel.scopedSearching) return -1
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
    // `tryFit`'s unmeasurable branch does exactly that on every keystroke of
    // a filter whose rows glide in, and an empty row set does it in queueFit.
    // So `-1` on the latch is not "this surface has no size", it is "this
    // surface has no MEASUREMENT", and the two are different questions.
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

  // The single clock for a slot-driven card: the row's own unfold. The row
  // publishes a new height each frame of its slot animation; the region is
  // simply that height, clamped to the resting region and the screen ceiling.
  // - The floor keeps a still-short slot from shrinking the card. A row with a
  //   slot that FITS the resting region never crosses it, so the list scrolls
  //   instead - growForSlot's decision is carried by the claim guard below.
  // - The ceiling keeps a row taller than the screen from growing the card
  //   past it; growForSlot refuses those and hands the rest to the list.
  // - A fold keeps following its live height until the row reaches rest, then
  //   the region is released - there is no second tween to hand off to.
  function _followSlotRow() {
    if (panel._modeRestoreFitOwned) return
    // The folding row, not the row under the cursor: a step taken mid-close
    // moves the cursor, but the card still has to follow the row that folds.
    const row = panel._closePageMode && panel._closeRow
      ? panel._closeRow : list.currentItem
    const live = row && row.height > row.restHeight + 0.5 ? row.height : -1
    const claimed = panel._claimListH > 0 || Menu.slotClosing
      || panel._nestedSeatPending || panel._trackingCloseSeat || panel._closePageMode
    // No claim and no fold in flight: the region is clear and the list
    // scrolls. Only the region is cleared here. The CLAIM belongs to
    // _latchClaim's revealNeedH lifecycle - clearing it from a row-height
    // handler (the row is still at rest on the first frames of an unfold)
    // hides the growth for the whole animation and lands the card in one
    // frame when the claim reappears at the end of the pursuit.
    // A close latch alone is not a growth claim. If the claim was already
    // released, following the closing row's live height here would latch a
    // region sized to the OUTGOING fit - a height no row in the new projection
    // owns. Only an armed claim may grow the card through the region.
    // A slot that will need growth must start following the row's live
    // height on the FIRST unfold frame. Waiting for the claim to latch reads
    // a snapshot taken after the row has already grown, which lands the card
    // at that snapshot in one frame. growForSlot is the same verdict the
    // claim uses, read here without waiting for the claim's edge.
    // A live slot height already above the row's rest height is the verdict:
    // the region below floors out at the resting base when a slot fits, so
    // following it costs nothing, and it starts on the first unfold frame
    // instead of waiting for growForSlot's settled geometry.
    // During a filter install the outgoing delegate can keep folding after
    // rowsModel already names the new projection. Its height cannot drive
    // this projection's region, even if it still occupies the same index.
    const projected = list.currentIndex >= 0
      ? panel.rowsModel[list.currentIndex] : null
    const filterSlot = !panel.searching && !panel.scopedSearching
      || (!!row && (row.expanded === true || row.infoOpen === true))
    const needsGrowth = live > 0 && !Menu.slotClosing
      && row.itm === projected && filterSlot
    if (panel._restoreSlotStartH >= 0 && !needsGrowth) return
    if ((!claimed || panel._claimListH <= 0) && !needsGrowth) {
      const from = panel._slotRegionH
      const base = panel._restingFallbackH()
      panel._slotRegionH = -1
      // A close releases the claim in the turn the slot starts folding, while
      // the row is still tall. The region alone cannot carry that shrink: it
      // is gone now, so the card would fall from the grown height to rest in
      // one frame. Hand the height it was showing to the card's own single
      // tween, which lands on the resting region with intermediate frames.
      // One clock and one writer (_animatedListH); no second tween or retry.
      if (from > base + 0.5 && !panel._heightAnimating
        && !panel._transitionActive && panel.shown && MotionPolicy.enabled)
        panel._startHeightTransition(base, -1, from)
      return
    }
    // During a result handoff the filter's old one-row latch can still be the
    // resting answer when the group's claim arms, so the region would drop to
    // the trimmed height for a frame before the group unfolds. The page fit
    // that the handoff is revealing is the real base on that edge.
    const base = panel._restoreSlotStartH >= 0
      ? panel._restoreSlotStartH
      : (panel._handoffReveal && panel._animatedListH > 0
        ? panel._animatedListH : panel._restingFallbackH())
    // The group's claim is the handoff's landing: from here on the normal
    // resting base applies and the reveal flag can retire.
    if (panel._claimListH > 0) panel._handoffReveal = false
    // The claim arms a tick before the row's first slot step. The row is
    // still at its rest height on that edge, so there is no live height to
    // follow - but clearing the region there let the height chain fall
    // through to the full claim and flashed the card to the dropdown's
    // destination for one frame before the first step brought it back.
    // Holding the resting region across the gap keeps the card where it is
    // until the slot actually grows; from then on it follows the live row.
    panel._slotRegionH = live > 0
      ? Math.max(base, Math.min(live, panel.screenMaxListH)) : base
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
  // Both read this one number. A mode clear arms it at the outgoing card's
  // height so a restored slot has a floor to unfold from; from the first grow
  // frame on, _followSlotRow() is the only writer and drives it straight from
  // the row's own unfold. There is no second animation for the card, so there
  // is no handoff between two clocks at the end of an unfold.
  //
  // -1 means "no slot is driving the region", which is every page transition,
  // fit and resting state: those keep their own machinery (_animatedListH,
  // heightAnim) and fall through to the base.
  property real _slotRegionH: -1

  // A live slot owns the card's size from its first frame. A fit tween still
  // in flight keeps its own destination and hands over at its end, jumping
  // from that destination to the region. Yield at the moment the region is
  // published, while both still agree, so the one derived chain follows the
  // row's live geometry. Called by both region writers.
  function _yieldFitToRegion() {
    if (panel._modeRestoreFitOwned) return
    if (panel._slotRegionH <= 0 || !panel._heightAnimating
      || panel._transitionActive || Menu.slotClosing) return
    panel._heightAnimating = false
    panel._animatedListH = -1
    panel._heightTargetH = -1
    heightAnim.stop()
  }
  // The region the claim asks for, LATCHED. A plain property, written
  // imperatively by _latchClaim. It is the scroll/region SPLIT decision for
  // the list and the gate for a card growth; the card's actual height is the
  // row's live height (_slotRegionH), not this target. Two rules earn that:
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

  property real traceCardW: panel.width
  onTraceCardWChanged: if (Menu.traceEnabled) Menu.trace("panel.cardW", {
    w: Math.round(traceCardW * 10) / 10,
    content: Math.round(panel.contentW * 10) / 10,
    settling: panel.widthSettling,
    searching: panel.searching
  })

  property real traceCardH: panel.height
  onTraceCardHChanged: if (Menu.traceEnabled) Menu.trace("panel.cardH", {
    h: Math.round(panel.height * 10) / 10,
    listH: Math.round(panel.listRegionH * 10) / 10,
    committed: Math.round(panel._committedListH * 10) / 10,
    claim: Math.round(panel._claimListH * 10) / 10,
    region: Math.round(panel._slotRegionH * 10) / 10,
    animating: panel._heightAnimating,
    transition: panel._transitionActive,
    fit: panel._fitPending
  })

  property real traceRegionH: panel._slotRegionH
  onTraceRegionHChanged: if (Menu.traceEnabled) Menu.trace("panel.regionV", {
    h: Math.round(traceRegionH * 10) / 10,
    claim: Math.round(panel._claimListH * 10) / 10
  })

  // Re-read the claim. Every caller is an EVENT, never a frame: the claim
  // appearing, moving or going away, the duration changing, and a seat landing
  // (the scroll branch moves the content, which moves where the claim lands
  // relative to the viewport). The card itself does not need this turn - it
  // follows the row's live height frame by frame through _followSlotRow.
  function _latchClaim() {
    const current = list.currentItem
    if ((panel.searching || panel.scopedSearching) && current
      && (current.itm !== panel.rowsModel[list.currentIndex]
        || (!current.expanded && !current.infoOpen))) {
      panel._releaseSlotRegion()
      return
    }
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
    const base = panel._restoreSlotStartH >= 0
      ? panel._restoreSlotStartH : panel._restingFallbackH()
    let want = panel.growForSlot(base)
    // A nested restore holds the reveal claim clear, which makes growForSlot
    // answer "fits" while the parent's slot is still folding. The row itself
    // still publishes its live height on every step; use that so the card's
    // claim follows the fold down instead of being released and re-armed
    // after the seat lands.
    if (want <= base + 0.5 && panel._nestedSlotLive()) {
      const row = list.currentItem
      if (row && row.height > row.restHeight + 0.5) want = row.height
    }
    // Latch a GROWTH or nothing, never the resting size. growForSlot answers
    // "what would the region be", which with no claim is simply the base - and
    // latching that made the latch a second, staler copy of the region: it
    // then outranked listRegionH in the height chain, so every later fit,
    // filter keystroke or page change was computed and then ignored, and the
    // card kept the size it had. The latch means "a slot is driving the
    // region", and only a real growth says so.
    const grown = want > base + 0.5 ? want : -1
    // An unchanged target still needs its list-side copy refreshed: the claim
    // is content-space, so a seat that does not change the target can change
    // whether the region is short of it. The card itself needs no second
    // write - its region follows the row's live height, independent of pace.
    if (grown > 0 && Math.abs(grown - panel._claimListH) < 0.5) {
      // Unchanged, but the list's copy of the target still has to track the
      // scroll offset: the claim is content-space, so a seat that does not
      // change the target can still change whether the region is short of it.
      list.growthH = panel._claimListH
      // A slot opened in the same chain can find the region released while
      // the claim this size already stands; re-derive it from the live row.
      panel._followSlotRow()
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
    // The card height reads BOTH the claim and the region. Publishing the
    // claim first left a frame with a grown claim and a stale -1 region: the
    // card jumped to the claim's destination, then dropped to the resting
    // region when _followSlotRow caught up, then grew back - the one-frame
    // jump on a deep landing. Publish the region the row is actually showing
    // before the claim goes live so the pair never disagrees.
    if (grown > 0) {
      const currentRow = list.currentItem
      const liveH = currentRow && currentRow.height > currentRow.restHeight + 0.5
        ? currentRow.height : -1
      if (liveH > 0)
        panel._slotRegionH = Math.max(base, Math.min(liveH, panel.screenMaxListH))
      else if (panel._slotRegionH < 0)
        panel._slotRegionH = base
      panel._yieldFitToRegion()
    }
    panel._claimListH = grown
    list.growthH = grown
    panel._followSlotRow()
  }

  // A nested child's slot feeds its height into the page row frame by frame,
  // so the row's live height already includes it; no special case is needed
  // in _followSlotRow, only in the grow decision above when the claim is held
  // clear by a nested restore.
  function _nestedSlotLive() {
    const row = list.currentItem
    return !!(row && row.nestedSlotLive === true)
  }

  // Hand the size back to the ordinary chain. Navigation, close and a row that
  // no longer has a live slot are the callers: all abandon the row the claim
  // was about, and none wants a stale region outranking the height chain.
  function _releaseSlotRegion() {
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

  Connections {
    target: panel.listView

    // The claim says WHETHER the region grows and how far the list still owes;
    // the row's own height change (connected below) says HOW FAR IT HAS GROWN.
    // The resting base is read inside the handler rather than watched, because
    // it is derived from the row set and a fit landing under an open slot must
    // not disturb the claim (the fit is held while a slot is open - see tryFit).
    function onRevealNeedHChanged() { panel._latchClaim() }
    function onRevealSlotMsChanged() { panel._latchClaim() }
  }

  // Content decides the width: the widest row this page shows, plus
  // whatever that row reserves on the right (see recalcWidth) - the
  // title and the sub line at rest, the open dropdown's entries while
  // one is expanded (see MenuWidth.applyDropdownWidth).
  //
  // One floor, and a small one: never narrower than Ui.cardMinW, so a
  // page of six short submenus opens as a card rather than a strip. It
  // is also what an unmeasured card answers with, since with nothing
  // shaped yet there is no content to size to.
  //
  // The outer clamp is the viewport, not a sizing rule: a card is
  // centered on the screen and must not run off either edge.
  readonly property real widthTarget: {
    // A grid page has no label to shape and its columns come from this width.
    // The host width is itself derived from the card, so clamping against it
    // on a cold boot yielded 250 -> 4 columns -> a 732px fit, then 420 ->
    // 8 columns -> 709px a few frames later. The grid's width is fixed.
    if (panel.gridMode) return Ui.defWidth
    // The host has no width until its first layout. A zero-width host is
    // not room for a card: clamping against `0 - 64` yields a negative card
    // width. Use the default card width as the room until the host has one.
    const room = parent && parent.width > 0 ? parent.width - 64 : Ui.defWidth
    return Math.min(Math.max(panel.contentW, Ui.cardMinW), room)
  }
  onWidthTargetChanged: panel._syncWidth()
  width: panel._widthNow

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
  // how far the first frame sat from where the card came to rest; the rule
  // itself is MenuSpawnProbe's.
  function probeSpawn() {
    const v = MenuSpawnProbe.verdict(panel._spawnPrevH, panel._spawnLayoutH,
      panel._spawnSettledH)
    // False once the spawn has settled, which is the normal state between
    // summons: the record is a completed verdict, not a live one.
    v.armed = panel._spawnArmed
    return v
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
    // A dying delegate from the previous model generation is still truthy
    // here; its uid must match the live rowsModel slot or persisting that
    // transient would clobber the remembered cursor. The restore-pending
    // check above already ran, and nothing between it and here changes the
    // frame, so re-testing it was a second answer to one question.
    const row = panel.gridMode ? grid.currentItem : list.currentItem
    const mItem = panel.rowsModel[idx]
    if (!row || !mItem || !row.itm || row.itm.uid !== mItem.uid) return
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
  // the re-rank. Re-ranks snap, so the selection bar does not glide after
  // the head while results update.
  function seatFilteredHead() {
    // Both views scan forward from 0 to the first cell they can focus, so
    // a head a guard disabled lands on the best row that can take it.
    if (panel.gridMode) {
      grid.settle(0, true)
      return
    }
    // A pinned bar belongs to an install that is about to put the cursor
    // back on the row it was on. A projection is the opposite - the cursor
    // goes to the head - and the pin would keep the bar on the geometry
    // captured before the query while the cursor moved off that row.
    list.unpinHighlight()
    list._hlHeld = false
    // The head is usually not index 0: every result set opens with a section
    // separator, and List.seat only returns the view to the top for index 0.
    // Any other row is left to the follow, which measures the outgoing
    // delegates during a re-rank and either holds or seats to a stale offset.
    // restoreAt names both halves of the answer in one motionless seat: the
    // first selectable row, and the top of the content.
    list.restoreAt(0, 0)
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
    want = panel.seatableNear(want)
    if (want < 0) return
    if (list.currentIndex === want) return
    viewSettle(want, true)
    panel.recordSeat()
  }

  // Put the focused row back where it belongs, now that the page has
  // settled: the rows above it have measured and the card owns its final
  // size, so the place the follow policy puts the row in can be named for
  // real.
  //
  // The user has moved on by the time this runs - a key step takes the
  // cursor elsewhere - and then the row they are on now is the one that
  // matters: the follow policy places it, and this placement is dropped.
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
    if (pending >= 0) {
      sel = pending
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
    // The seat may name a row a condition has since made unavailable: land on
    // the nearest row that can hold the cursor instead of parking it there.
    const takeable = panel.seatableNear(sel)
    if (takeable >= 0) sel = takeable
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
    // Pass the final viewport height: on a synchronous page install the live
    // contentHeight/height still describe the outgoing page, and clamping
    // against them would paint the parent at the top for a couple of frames.
    if (seatScroll) list.restoreAt(sel, y, viewH)
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
  // The query is published on the next event-loop turn, never from inside the
  // field's own text-change signal. Qt finishes a TextInput change
  // (QQuickTextInputPrivate::finishChange) and then evaluates the QML handlers
  // synchronously; a query published there reinstalls the row model and
  // remeasures the card inside that frame. That nested rebuild matches the
  // shape Qt 6.12's V4 has crashed on: sameValueZero on a freed string, via
  // the Map lookups the search and width passes do, while the query text is
  // still held by the change being finished. Deferring keeps the search out
  // of that frame; the field still echoes the key immediately and the results
  // land one turn later.
  function onFieldEdited(text) {
    const publish = () => {
      // The arm owns the route, not the view: the first character reaches
      // the scoped query even though the projection is still the plain page.
      if (Menu.scopedActive) {
        // An empty query leaves the filter armed by design only when it was
        // armed with no query at all. Erasing a real query is a cancel: the
        // scope must go, or its arm-time seat is never handed back.
        if (text === "") Menu.clearScoped()
        else Menu.setScopedQuery(text)
      } else Menu.setQuery(text)
    }
    const query = Menu.scopedActive ? Menu.scopedQuery : Menu.query
    // Only the first character of a mode and its erase are edges. Re-ranking
    // a live query installs its rows immediately, as before.
    if ((text === "") !== (query === "")) {
      // Hide only the frame the row set swaps. The restored card then grows
      // to the page while its content is already drawn: the resize is the
      // reveal, not a curtain held until the height has landed.
      panel.fadeModeChange(publish)
    } else Qt.callLater(publish)
  }

  function focusFilter(mode) {
    focusCtrl.openMode = mode === "list" ? "list" : "filter"
    focusCtrl.reassert()
    if (focusCtrl.openMode === "filter") focusCtrl.grabFilter()
  }

  function currentRow() {
    return panel.gridMode ? grid.currentItem : list.currentItem
  }

  // The deepest open child under the page cursor. Delete/Ctrl+D and other
  // row verbs must act on the row the user is actually looking at, not on
  // its outer group (a nested folder would otherwise turn its parent into a
  // deletion confirmation).
  function focusedRow() {
    let row = panel.currentRow()
    for (let depth = 0; depth < 4 && row && row.isGroup
      && typeof row._focusedChildRow === "function"; depth++) {
      if (row.childIndex < 0) break
      const kid = row._focusedChildRow()
      if (!kid || !kid.itm || typeof kid.itm.delCommand !== "string"
        || kid.itm.delCommand === "") break
      row = kid
    }
    return row
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

  // --- nested row reveal seat ---
  // A group child's slot is content inside its parent's row. Opening one asks
  // the list to reveal that row; closing one returns the scroll offset under
  // the user's view, on the slot's own clock. This lives on the panel because
  // the panel owns the list - a delegate must not drive List internals itself.
  property real _nestedSeatY: -1
  property bool _nestedSeatPending: false
  // Scroll offset at the FIRST reveal claim on this page. The nested seat
  // holds the child activation offset, which includes the parent's reveal
  // shift; the page-level origin is the offset with no reveal at all.
  property real _revealOriginY: -1
  function _trackRevealOrigin() {
    if (list.autoRevealIndex >= 0 && panel._revealOriginY < 0) {
      panel._revealOriginY = list.contentY
      Menu.trace("panel.origin", { y: Math.round(list.contentY * 10) / 10 })
    }
  }
  // Restore the reveal shift while the slot folds, not after it. The row
  // height publishes one value per frame, so driving contentY from the same
  // value keeps the scroll, the list extent and the card on one clock. A
  // separate tween would land the height first and scroll afterwards.
  property bool _closePageMode: false
  property real _closeStartY: -1
  property real _closeStartH: -1
  property real _closeRestH: -1
  // The row whose slot is folding. Cursor moves during the fold must not
  // retarget the restore at whichever row the selection lands on next.
  property var _closeRow: null
  function _beginPageClose(row) {
    panel._closeRow = row
    panel._closePageMode = true
    panel._closeStartY = list.contentY
    panel._closeStartH = row.height
    panel._closeRestH = row.restHeight
    panel._trackingCloseSeat = true
    // The page close abandons any nested seat: the offset owed is the page
    // origin, not the nested one. There is no deferred pin any more - the
    // nested restore is a live function of its own row - but clear the seat so
    // a later reveal cannot capture a stale offset from this fold.
    panel._nestedSeatY = -1
    panel._nestedCloseStartY = -1
    panel._nestedSeatPending = false
    Menu.trace("panel.pageClose", {
      from: Math.round(panel._closeStartY * 10) / 10,
      to: Math.round(panel._revealOriginY * 10) / 10,
      h: Math.round(panel._closeStartH * 10) / 10,
      rest: Math.round(panel._closeRestH * 10) / 10
    })
    panel._trackCloseSeat()
  }
  // A page or bundle swap destroys the delegate that held the nested slot,
  // so its close never lands. Drop the remembered seat at those edges; a
  // stale offset would be restored into an unrelated page on the next open.
  function _resetNestedSeat() {
    _nestedSeatY = -1
    _revealOriginY = -1
    _closePageMode = false
    _trackingCloseSeat = false
  }

  function beginNestedReveal() {
    // Each nested slot owns its own reveal origin. A chain of groups reaches
    // deeper offsets at every level; keeping the first seat would return a
    // deep slot's close past the position its own open started from.
    //
    // A close restore can still be in flight when this reveal arrives (a
    // re-open on the tail of the key that just committed the row). Its target
    // is the real pre-open seat; the live contentY is mid-tween, and taking
    // that as the seat leaves the top-level rows shifted by one slot after
    // the next commit.
    const hadPendingSeat = panel._nestedSeatPending && panel._nestedSeatY >= 0
    const seat = hadPendingSeat ? panel._nestedSeatY : list.contentY
    _nestedSeatY = seat
    _nestedSeatPending = false
    _trackingCloseSeat = false
    _closePageMode = false
    _closeRow = null
    Menu.trace("panel.reveal", {
      seat: Math.round(_nestedSeatY * 10) / 10, pending: hadPendingSeat,
      cY: Math.round(list.contentY * 10) / 10, cur: list.currentIndex,
      auto: list.autoRevealIndex
    })
    // A close leaves the claim cleared. Re-arm it so the list's own pursuit
    // can seat the child into view before its slot unfolds.
    if (list.autoRevealIndex < 0 && list.currentIndex >= 0)
      list.autoRevealIndex = list.currentIndex
  }

  function beginNestedRestore(paceMs) {
    Menu.trace("panel.restore", {
      seat: Math.round(_nestedSeatY * 10) / 10,
      cY: Math.round(list.contentY * 10) / 10,
      pace: paceMs, auto: list.autoRevealIndex, anim: list.debugAnimRunning
    })
    // Each close owns its own seat. The pin of a previous close clears the
    // shared seat, so a later close in the same chain would otherwise get no
    // tracking at all and its row would collapse with the scroll frozen.
    const hadSeat = _nestedSeatY >= 0
    _nestedSeatPending = hadSeat
    // One paced seat back to the nested origin, on the closing slot's own
    // duration and curve: it starts and lands with the fold, so the scroll
    // and the close are one motion. No deferred writer is needed - the pin
    // that used to follow this seat was the source of the late stale write,
    // and removing it leaves nothing that can fire after a parent close.
    const row = list.currentItem
    _nestedCloseStartY = list.contentY
    // Suspend the page-level pursuit while the child folds; its target is the
    // parent's settled bottom, which is still below the view here.
    Menu.trace("panel.clear", { site: "nestedRestore", auto: list.autoRevealIndex })
    list.autoRevealIndex = -1
    _trackingCloseSeat = true
    // A nested slot opened in the same chain as its parent's page reveal can
    // capture the PRE-reveal offset: both seats are still 0 while the reveal
    // is about to take the page row to 159. That scroll belongs to the parent,
    // which restores it on its own close. Nothing in this nested fold owes a
    // page-level seat, so scrolling to the captured offset here would yank
    // the still-open parent out of view and make the fit wake up and correct
    // it one frame later.
    const sameAsPageOrigin = panel._revealOriginY >= 0
      && Math.abs(panel._nestedSeatY - panel._revealOriginY) < 0.5
    if (hadSeat && !sameAsPageOrigin
      && Math.abs(list.contentY - _nestedSeatY) > 0.5)
      list.seatTo(_nestedSeatY, true, "nested-restore", paceMs)
  }
  property real _nestedCloseStartY: -1

  property bool _trackingCloseSeat: false
  function _closeSeatDone() {
    if (!panel._trackingCloseSeat) return
    panel._trackingCloseSeat = false
    if (panel._closePageMode) {
      const y = panel._revealOriginY
      // The last height change lands the row at rest; put the offset exactly
      // on its origin so a fractional frame cannot leave it a pixel short.
      if (y >= 0 && list && Math.abs(list.contentY - y) > 0.05)
        list.seatTo(y, false, "close-land")
      Menu.trace("panel.closeLand", {
        from: Math.round(panel._closeStartY * 10) / 10,
        to: Math.round(y * 10) / 10,
        cY: Math.round(list.contentY * 10) / 10
      })
      // Nested closes share this page-level origin; only the page row's own
      // close consumes it. Clearing it at a nested edge would make the last
      // fold restore to a mid-chain offset instead of the pre-open offset.
      panel._revealOriginY = -1
      panel._closePageMode = false
      panel._closeRow = null
      panel._closeStartY = -1
      panel._closeStartH = -1
      panel._closeRestH = -1
      panel._nestedSeatY = -1
      panel._nestedCloseStartY = -1
      panel._nestedSeatPending = false
    }
  }
  function _trackCloseSeat() {
    const row = panel._closePageMode ? panel._closeRow : list.currentItem
    if (!row || !_trackingCloseSeat) return
    let target
    if (panel._closePageMode) {
      const span = Math.max(1, panel._closeStartH - panel._closeRestH)
      const p = Range.clamp01((panel._closeStartH - row.height) / span)
      const origin = panel._revealOriginY >= 0 ? panel._revealOriginY : panel._closeStartY
      target = panel._closeStartY + (origin - panel._closeStartY) * p
      Menu.trace("panel.closeUnison", {
        p: Math.round(p * 100) / 100,
        h: Math.round(row.height * 10) / 10,
        target: Math.round(target * 10) / 10,
        cY: Math.round(list.contentY * 10) / 10
      })
    } else {
      // The paced nested-restore seat owns the scroll for this fold. Starting
      // on the same edge with the slot's own duration and curve already makes
      // the two one motion; a second writer here would only cut the ride short
      // and land the remainder in one frame.
      return
    }
    if (Math.abs(target - list.contentY) >= 0.05)
      list.seatTo(target, false, "close-track")
  }

  function nestedSlotFinished() {
    Menu.trace("panel.finished", {
      seat: Math.round(_nestedSeatY * 10) / 10,
      cY: Math.round(list.contentY * 10) / 10,
      auto: list.autoRevealIndex, anim: list.debugAnimRunning
    })
    // A PARENT close that began while this slot was still folding owns the
    // offset now: its page close rides the fold down and lands on the
    // pre-open origin by itself. The nested seat belongs to the open that
    // close has already scrolled back past; writing it here would push the
    // old offset back over the restore.
    if (panel._closePageMode) {
      panel._nestedSeatPending = false
      return
    }
    // The paced restore seat lands on the origin; nothing is left to write.
    // Drop the seat so a later reveal cannot capture a stale offset.
    panel._nestedSeatY = -1
    panel._nestedCloseStartY = -1
    panel._nestedSeatPending = false
    // The parent slot is settled now. Re-arming its reveal claim against the
    // settled geometry keeps the next step from dragging the view.
    if (list.currentIndex >= 0) panel._rearmOpenSlot()
  }

  function moveGridCell(step) { grid.moveCell(step) }

  function moveGridRow(step) { grid.moveRow(step) }

  function stepCurrent(direction) {
    if (panel.gridMode) return
    const row = list.currentItem
    if (row && row.isGroup) {
      // +/- belongs to the focused child when it is a number or range, just
      // as it belongs to a page row of that type.
      const childRow = row._focusedChildRow ? row._focusedChildRow() : null
      if (childRow && childRow.hasStepper) {
        childRow.stepBy(direction)
        return
      }
      return
    }
    if (row && row.hasStepper) row.stepBy(direction)
  }

  function moveSelection(direction, autoRepeat) {
    if (panel.gridMode) {
      panel.moveGridCell(direction)
      return
    }
    const prev = panel.currentRow()
    if (Menu.traceEnabled) {
      const c = prev && prev._focusedChildRow ? prev._focusedChildRow() : null
      Menu.trace("key.move", {
        dir: direction,
        row: prev ? String(prev.itm?.id ?? "") : "",
        dropdown: !!(prev && prev.dropdownOpen),
        expanded: !!(prev && prev.expanded),
        child: c ? String(c.itm?.id ?? "") : "",
        childExpanded: !!(c && c.expanded),
        childDropdown: !!(c && c.dropdownOpen)
      })
    }
    // An open dropdown consumes the arrows first.
    if (prev && prev.dropdownOpen && !prev.confirmOpen && prev.moveOption(direction)) return
    if (!list.move(direction, undefined, autoRepeat === true)) return
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
  // Cursor index and offset at search entry. Erasing a query returns to the
  // page rows; when the frame has no seat for this page, an expanded row keeps
  // its slot and grown card while the selection bar - the slot's only
  // background - sits on another row. Restore the entry position.
  property int _searchReturnIdx: -1
  property real _searchReturnY: -1
  property string _searchReturnPage: ""
  // The saved row by identity. The exit write replaces the projection with
  // the page, and the saved index may not exist in the projection at all -
  // the view restores this row once the page's model has landed (see
  // List.keepRow), so no seat runs against a row set that cannot hold it.
  property string _searchReturnUid: ""
  // True for the install that leaves global search back onto the page. That
  // install must not carry the result row across the model swap by identity:
  // the row under the cursor is a search hit, and the seat the user left is
  // restored separately. Letting _writeRecords keep it paints the hit under
  // the bar for one frame before the saved seat wins - the Reload flash.
  readonly property bool _searchReturnPending: panel._searchReturnIdx >= 0
    && !panel._searchClearByResult
  // A result landing owns the cursor on the page it lands on. Its query clear
  // still runs through the search edge; without a token the search restore
  // waiter cannot tell that the seat it saved belongs to an older intent.
  property bool _searchClearByResult: false
  // Same contract for the "/" filter. Its projection is a trim of the current
  // page, so a hit that is not on the page (a nested child shown at the top
  // register) destroys the delegate the cursor was on. Capture the page seat
  // at arm time and give it back on clear, or the page returns with the bar
  // on row 0 and a scroll offset no page row owns.
  property int _scopedReturnIdx: -1
  property real _scopedReturnY: -1
  property string _scopedReturnUid: ""
  property string _scopedReturnPage: ""
  property int _scopedReturnChild: -1
  // The filter was armed on an expanded row, so its clear restores an open
  // slot whose unfold drives the card. The trim's height is that grow's floor.
  property bool _scopedReturnOpen: false
  // Armed while a mode swap owes the page its old cursor and scroll seat.
  // Every claim rearm waits for this to clear: an arm made against the
  // projection's transient short viewport seats the restored row past where
  // the user left it. The restore edge owns the claim until it has settled.
  property bool _restoreSeatPending: false
  // Set by a row that cleared the filter by ACTING on a result. That row is
  // now open (or its command ran), so the arm-time seat belongs to a different
  // intent and must not pull the cursor back off it.
  property bool _scopedClearByAction: false

  // A programmatic landing moves the cursor without the gesture's
  // "leaving a row collapses it" step. Fold every other open slot on the page
  // so an expansion from before the query cannot trail the result row.
  function _collapseOtherOpenRows(keepUid) {
    for (let i = 0; i < panel.rowsModel.length; i++) {
      const it = panel.rowsModel[i]
      if (!it || String(it.uid) === keepUid) continue
      if (!Menu.isExpanded(it) && !Menu.infoOpen(it)) continue
      const row = list.itemAtIndex(i)
      if (row && typeof row.collapse === "function") row.collapse()
      else {
        Menu.setExpanded(it, false)
        Menu.setInfo(it, false)
      }
    }
  }

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

  // Search-result landings operate on the target row only after the teleport
  // and every panel motion have come to rest. The wait used to be a two-turn
  // Idle poll with a structural attempt cap and a wall-clock motion deadline:
  // it could catch a momentarily quiet gap, or run late against a panel still
  // moving. Quiet is now one derivation of the live signals, and the target
  // row is read inside that binding, so QML re-evaluates it on every motion
  // edge and on the row's arrival (including guard properties that settle a
  // frame after install). A waiter runs exactly once, on the first frame
  // where both hold - no attempts, no deadline, no snapshots.
  property var _settledWaiters: []

  function _settledRowOk() {
    if (panel._settledWaiters.length === 0) return false
    const row = panel.currentRow()
    if (!row) return false
    const w = panel._settledWaiters[0]
    return !w.guard || !!w.guard(row)
  }

  readonly property bool _settledReady: Menu.open
    && !panel._swapping && !Menu.slotClosing
    && !panel._fitPending && !panel._transitionActive
    && !panel._heightAnimating && !slideAnim.running
    && list._sweeping !== true && list.moving !== true
    && Menu.pendingSel < 0
    && panel._settledRowOk()

  on_SettledReadyChanged: if (panel._settledReady) panel._drainSettled()

  function _drainSettled() {
    // One settled frame can satisfy several waiters - a landing's own waiter
    // and the reveal-arm it queued after expanding. Releasing only the first
    // leaves the rest parked on a verdict that will not change again.
    while (panel._settledWaiters.length > 0 && panel._settledReady) {
      const w = panel._settledWaiters[0]
      // Dropping the waiter first so the binding cannot re-enter on the same
      // frame; the row is captured before any callback can change the cursor.
      const row = panel.currentRow()
      // A waiter queued by a waiter drains in the SAME call, before the
      // _settledReady binding has re-evaluated its guard against the row the
      // seat just chose. Checking the guard here as well keeps that re-entrant
      // drain from consuming the waiter with a stale row and abandoning the
      // landing it was waiting for.
      if (!row || (w.guard && !w.guard(row))) return
      panel._settledWaiters = panel._settledWaiters.slice(1)
      w.fn(row)
    }
  }

  function whenSettled(fn, guard) {
    panel._settledWaiters = panel._settledWaiters.concat([{ fn: fn, guard: guard }])
    // A deferred drain lets the _settledReady binding see the new waiter
    // (and its guard) before it decides anything; draining inline here let a
    // nested waiter run against the previous frame's cursor.
    Qt.callLater(panel._drainSettled)
  }

  Connections {
    target: Menu

    // A request aimed at a panel that is gone has no target. Clearing here
    // also releases waiters whose row never arrived because that page went
    // away, so they cannot fire on an unrelated row of a later open.
    function onOpenChanged() {
      if (!Menu.open) {
        panel._settledWaiters = []
        // A close mid-fade otherwise leaves the text input invisible.
        panel.finishResultFade()
        // A mode edge abandoned by a close owes no seat. Leaving the gate
        // armed would silence every claim rearm on the next summon, and a
        // staged action could publish onto a closed panel.
        panel._restoreSeatPending = false
        panel._searchReturnPage = ""
        list.dropKeepRow()
        panel._viewFadeAction = null
        viewFadeOut.stop()
        viewFadeIn.stop()
        panel.viewFade = 1
      }
    }
  }

  // A result selection is a two-phase handoff. ONE value drives it: 0 is
  // the search results in focus, 0.5 is the page-switch edge, 1 is the
  // target page revealed. Four presentations read this value; none of them
  // owns a clock of its own. The two phases keep the L1 edge for the page
  // switch (commitResultFade runs in the first animation's onFinished), but
  // every derived presentation is L2: a function of the one live value.
  //
  // Start just above zero so the guards that read `handoffActive` are true
  // on the very first frame, before the animation has advanced.
  property real handoff: 0
  readonly property bool handoffActive: panel.handoff > 0
  // A filtered result reveals a restored page with a fit; that fit's target
  // is the committed resting size, not the filter's old one-row latch.
  property bool _handoffReveal: false
  // Phase progress in [0,1]; both are pure normalisations of the one value.
  readonly property real handoffOutK: Math.min(panel.handoff * 2, 1)
  readonly property real handoffInK: Math.max(0, (panel.handoff - 0.5) * 2)
  // The old phase-one Linear 1->0 and phase-two OutCubic 0.3->1 shapes,
  // expressed as functions of handoff. There is no pageHost tween left.
  readonly property real handoffPageOpacity: panel.handoff <= 0.5
    ? 1 - panel.handoffOutK
    : 0.3 + 0.7 * (1 - Math.pow(1 - panel.handoffInK, 3))
  // Query text is the eased complement: the old 1->0 OutCubic textFadeAnim.
  readonly property real handoffTextOpacity: Math.pow(1 - panel.handoffOutK, 3)
  // Non-handoff page motion (submenu slide, open seat) keeps its own value;
  // the handoff presentation overlays it without either writing the other.
  property real _pageSlideOpacity: 1

  property var _resultPending: null

  function beginResultFade(it) {
    if (panel.handoffActive) panel.finishResultFade()
    if (!MotionPolicy.enabled) return
    panel._resultPending = it
    // Cycle breaker: the deferred text clear, focus reassert and slide guard
    // all read this value on the start edge; a pure edge cannot start its own
    // clock, so the first frame is written here before they run.
    panel.handoff = 0.0001
    focusCtrl.grabList()
    handoffOutAnim.restart()
  }

  // Phase two: the query still names this hit, so commit the landing while
  // pageHost is hidden and let the new rows fade in.
  function commitResultFade() {
    const it = panel._resultPending
    panel._resultPending = null
    if (!panel.handoffActive) return
    // The L1 edge is here: the page switches only when phase one finishes.
    // The non-handoff fallback is already the revealed value, so the frame
    // where handoff reaches 1 cannot fall back to a hidden page.
    panel._pageSlideOpacity = 1
    if (!Menu.open || (Menu.query === "" && !(it && it.scopedResult))) {
      panel.finishResultFade()
      return
    }
    panel.applyResult(it)
  }

  function finishResultFade() {
    if (panel.handoff <= 0) return
    handoffOutAnim.stop()
    handoffInAnim.stop()
    panel._resultPending = null
    // The revealed end state is handoff 1. On this edge the driver returns
    // to its idle origin so ordinary submenu slides own pageHost again;
    // handing the fallback the revealed value keeps that swap seamless.
    panel.handoff = 0
    panel._pageSlideOpacity = 1
    // The group branch releases the index-follow hold on its expansion
    // edge; clearing it here would let the row-set echo follow the still
    // collapsed group to the viewport top.
    // A close or a superseded selection is retired here too: leaving a
    // partial value behind would hold the handoff guards shut forever.
  }

  NumberAnimation {
    id: handoffOutAnim
    target: panel
    property: "handoff"
    from: 0.0001
    to: 0.5
    // Linear over a full clock: OutCubic spent most of its duration already
    // at zero, which read as a few still frames before the page switched.
    duration: Ui.fastMs
    easing.type: Easing.Linear
    onFinished: panel.commitResultFade()
  }

  NumberAnimation {
    id: handoffInAnim
    target: panel
    property: "handoff"
    from: 0.5
    to: 1
    duration: Ui.fastMs
    easing.type: Easing.Linear
    onFinished: panel.finishResultFade()
  }

  // Entering or leaving search/filter mode is the same kind of handoff as a
  // result landing, with the row-set swap at the hidden midpoint instead of a
  // page jump. ONE value drives it; the page view, the query text, the ghost
  // and the field's accent border are functions of that value, so none of
  // them can fade on a clock of its own or land a frame apart.
  property real viewFade: 1
  property var _viewFadeAction: null

  function _startModeFadeIn() {
    viewFadeIn.restart()
  }

  function fadeModeChange(action) {
    if (!MotionPolicy.enabled) {
      action()
      return
    }
    // A mode edge already in flight owns the clock. Replacing its action
    // without restarting keeps fast typing from holding the view hidden.
    if (panel._viewFadeAction !== null) {
      panel._viewFadeAction = action
      return
    }
    panel._viewFadeAction = action
    viewFadeOut.from = panel.viewFade
    viewFadeOut.restart()
  }

  // The curve is the result handoff's: a full shared clock down to zero,
  // then a reveal that starts at 0.3 so the first frame is never an empty
  // card. A mode swap and a result landing read as the same motion.
  NumberAnimation {
    id: viewFadeOut
    target: panel
    property: "viewFade"
    to: 0
    duration: Math.max(1, Math.floor(Ui.fastMs / 2))
    easing.type: Easing.Linear
    onFinished: {
      const action = panel._viewFadeAction
      panel._viewFadeAction = null
      if (action) action()
      panel._startModeFadeIn()
    }
  }

  NumberAnimation {
    id: viewFadeIn
    target: panel
    property: "viewFade"
    from: 0.3
    to: 1
    duration: Math.max(1, Math.ceil(Ui.fastMs / 2))
    easing.type: Easing.OutCubic
  }

  function consumePendingResult() {
    const it = panel.pendingResult
    panel.pendingResult = null
    if (!it || !Menu.open || it.pageId === undefined) return
    if (!Menu.hasPage(it.pageId)) return
    panel.beginResultFade(it)
    if (panel.handoffActive) return
    panel.applyResult(it)
  }

  function applyResult(it) {
    if (it.scopedResult) {
      // A filtered nested entry stays on this page. Entry left the filter
      // armed so its rows could fade out; clearing it here restores the full
      // rows under the masked page, then the group branch below walks the
      // chain to the entry's real nesting. No stack reset, no page jump.
      panel._scopedClearByAction = true
      // The filtered card latched the trimmed one-row height. Dropping that
      // latch makes the region read the size actually on screen while the
      // restored rows measure, instead of snapping back to the trimmed size
      // for a frame when the fit lands.
      panel._latchedListH = -1
      panel._handoffReveal = true
      // The restored row set echoes a currentIndex change that is not a
      // gesture; its generic follow would precede the group's own reveal.
      if (list) list.suppressIndexFollow = true
      Menu.clearScoped()
    } else if (!Menu.jumpTo(it.pageId, it.row)) {
      return
    } else {
      panel._searchClearByResult = true
      Menu.clearQuery()
    }
    if (panel.handoffActive) {
      // The same value continues from the switch edge to 1; the page's
      // 0.3-to-1 reveal is a derivation of it, not a second animation.
      handoffInAnim.restart()
    }
    // Emptying the field here starts the placeholder's own Ui.fastMs fade
    // on the same edge as the page reveal; the text control stays
    // transparent until that reveal lands.
    searchField.text = ""
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
      // A staged confirmation is the row's dropdown, and the row is where it
      // renders: a hit that carries one lands on its page and arms it there
      // through the row's own activation - the path a browsed row takes -
      // instead of dispatching the action blind and closing the menu.
      if (Menu.confirmFor(it)) {
        const targetUid = it.uid !== undefined && it.uid !== null ? String(it.uid) : ""
        panel.whenSettled((row) => {
          if (row.itm && String(row.itm.uid) === targetUid) row.activate()
        }, (row) => row.confirm !== null && row.itm !== null
          && String(row.itm.uid) === targetUid)
        return
      }
      panel.activateItem(it)
      return
    }
    if (it.type === "group") {
      // The hit names the row that opens the dropdown; the query can also name
      // one of its children. Seat that child so redirecting lands on the
      // matching entry instead of leaving the arrow walk to the user.
      // groupSearchResults resolves the child once for both display and
      // landing; a hit that names none opens the group on its first child.
      // A hit on a group's own label carries the group uid directly and no
      // child chain. It still has to land on that row and open it: without a
      // target uid the seating below is skipped and the page opens with an
      // unselected, unexpanded group.
      const targetUid = it.groupUid !== undefined && it.groupUid !== null
        && String(it.groupUid) !== ""
        ? String(it.groupUid)
        : (it.uid !== undefined && it.uid !== null ? String(it.uid) : "")
      if (targetUid !== "" && list) Qt.callLater(function() {
        const idx = Menu.visibleIndexOfUid(it.pageId, targetUid)
        Menu.trace("result.seatPage", { idx: idx, uid: targetUid })
        if (idx < 0) return
        // A scoped flat result restores the page rows under the handoff; the
        // generic land-follow would seat the collapsed row at the viewport
        // top before its slot grows. The expansion below owns that reveal.
        if (it.scopedResult) list.landIndex(idx)
        else list.seat(idx, "land")
      })
      Menu.trace("result.group", {
        label: String(it.label ?? ""), type: String(it.type ?? ""),
        uid: String(it.uid ?? ""), groupUid: String(it.groupUid ?? ""),
        childUids: Array.isArray(it.childUids) ? it.childUids.join("|") : "",
        childUid: String(it.childUid ?? "")
      })
      const chain = Array.isArray(it.childUids) && it.childUids.length > 0
        ? it.childUids.slice()
        : ((it.childUid !== undefined && it.childUid !== null)
          ? [ String(it.childUid) ] : [])
      // The restore after clearing the query can pull the cursor back to the
      // frame's old index. Re-seat the target row on the settled edge, then
      // walk the nested chain by uid. Each level waits for its own group row
      // to arrive and settle instead of retrying a fixed number of turns - a
      // slow install simply holds the waiter until the row is really there.
      function groupUidMatches(row, uid) {
        return !!row && row.isGroup === true && !!row.itm
          && String(row.itm.uid) === uid
      }

      // Seat each level by uid, opening the nested group on the way down.
      // Gated children drop out of the live dropdown, so resolve against
      // what each level actually lists. `rows` holds the group rows already
      // walked; a nested group is read from its parent's loader after the
      // expansion has published its children.
      const seatRows = []
      function seatLevel(n, rows) {
        const r2 = rows[n]
        const expected = n === 0 ? targetUid : chain[n - 1]
        Menu.trace("result.seat", {
          n: n, want: chain[n], expected: expected,
          row: r2 && r2.itm ? String(r2.itm.uid) : "",
          isGroup: !!(r2 && r2.isGroup)
        })
        if (!groupUidMatches(r2, expected)) return
        const kids = r2.groupChildren
        let found = -1
        for (let i = 0; i < kids.length; i++) {
          if (kids[i] && String(kids[i].uid) === chain[n]) { found = i; break }
        }
        if (found < 0) return
        r2.childIndex = found
        if (n + 1 >= chain.length) return
        const childRow = r2._focusedChildRow ? r2._focusedChildRow() : null
        if (!childRow || !childRow.isGroup) return
        childRow.setExpanded(true)
        // A nested group row is hosted inside its parent's loader, never in
        // the page list, so panel.currentRow() cannot name it. Walk the live
        // delegate we just expanded instead of waiting for a page row that
        // never arrives.
        rows[n + 1] = childRow
        seatLevel(n + 1, rows)
      }
      // The filter's fit can stay pending while the result's group is open,
      // which would hold a settled waiter shut forever. The restored page
      // rows are installed in this turn; resolve the target by index on the
      // next one instead of waiting on a gate the new opening invalidates.
      Qt.callLater(function() {
        // The action-clear retired the filter's fit, but the page's resting
        // size is only known once the restored rows are installed. Commit it
        // before expanding: a claim latched against the one-row trim would
        // size the card to the dropdown instead of to the page.
        panel._recommitRestingH()
        const idx = Menu.visibleIndexOfUid(it.pageId, targetUid)
        if (idx >= 0 && list) {
          if (list.currentIndex !== idx) list.seat(idx, "land")
          list.forceLayout()
        }
        // A landing owns the whole page: a group left open by the row the
        // user was on before the query has no reason to stay unfolded once
        // the result puts the cursor on a different group.
        panel._collapseOtherOpenRows(targetUid)
        const row = idx >= 0 && list ? list.itemAtIndex(idx) : null
        if (!groupUidMatches(row, targetUid)) return
        seatRows[0] = row
        if (list) list.suppressIndexFollow = false
        row.setExpanded(true)
        // The child delegates load in the group's own Loader. One turn after
        // the expansion is enough for the focused child to exist; waiting on
        // the fit here would inherit the filter's still-pending measurement.
        Qt.callLater(function() {
          seatRows[0] = row
          seatLevel(0, seatRows)
          // A programmatic landing has no gesture to arm the reveal claim.
          // Do it on the settled edge: latching while the projection's fit is
          // still being replaced reads its one-row base and grows the card to
          // the dropdown instead of keeping the restored page's size.
          if (list && idx >= 0) {
            panel.whenSettled(function() {
              panel._recommitRestingH()
              list.autoRevealIndex = idx
              panel._latchClaim()
            })
          }
        })
      })
      return
    }
    // Input rows land focused like every other entry: the query selects the
    // row, not its editor or dropdown. Both were opened on arrival before,
    // which took focus off the row the hit named. A second Enter operates it.
  }

  function activateCurrent(shift) {
    // A debounced scoped query may still be pending: apply it now and
    // re-drive activation once the install it queues has landed, so Enter
    // never picks from a set the field has already left behind. (The global
    // query needs no flush - setQuery publishes it on the keystroke.)
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
    // A staged flow owns Escape ahead of the field and the filter: step back
    // one stage, keeping the values already typed in earlier stages.
    const frow = panel.focusedRow()
    if (frow && frow.isFlow && frow.flowIndex > 0
      && typeof frow.backFlow === "function" && frow.backFlow()) return
    // Armed but no character typed: the view never changed, so there is no
    // trim to clear and no seat to hand back. Leave the filter mode itself.
    if (Menu.scopedActive && !panel.scopedSearching) {
      panel.onFieldEdited("")
      focusCtrl.grabList()
      return
    }
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
      panel.onFieldEdited("")
      searchField.text = ""
      focusCtrl.grabList()
      return
    }
    if (panel.searching) {
      panel.onFieldEdited("")
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
    // Esc peels from the innermost slot outward. Each nested group owns its
    // focused child, so walk that chain to its end before touching an outer
    // row's slot: a group at any depth keeps its own expansion for the next
    // keystroke.
    let deep = row
    const chain = [row ? String(row.itm?.id ?? "") : ""]
    for (let depth = 0; depth < 4 && deep && deep.isGroup
      && typeof deep._focusedChildRow === "function"; depth++) {
      const kid = deep._focusedChildRow()
      if (!kid) break
      // Only an open layer is something Esc can peel. Descending into a
      // focused leaf that has no slot would leave `deep` on a row with
      // nothing to close and fall through to the toplevel row's collapse.
      if (!kid.expanded && !Menu.infoOpen(kid.itm)) break
      deep = kid
      chain.push(String(kid.itm?.id ?? ""))
    }
    Menu.trace("panel.escape", {
      chain: chain.join(" > "),
      deep: deep ? String(deep.itm?.id ?? "") : "",
      deepOpen: !!(deep && (deep.expanded || Menu.infoOpen(deep.itm))),
      topOpen: !!(row && row.expanded)
    })
    if (deep && deep !== row) {
      if (deep.isFlow) {
        // The editor may have already stepped the flow back on this same
        // Escape. Do not fold the row it just reopened.
        if (deep.flowBackConsumed) {
          deep.flowBackConsumed = false
          return
        }
        if (deep.flowIndex > 0 && typeof deep.backFlow === "function"
          && deep.backFlow()) return
      }
      if (Menu.infoOpen(deep.itm)) {
        Menu.setInfo(deep.itm, false)
        return
      }
      if (deep.expanded) {
        deep.collapse()
        return
      }
    }
    // An open ctrl+i description is the outermost layer on this row -
    // Esc peels it first, before touching expansions or the stack.
    if (row && Menu.infoOpen(row.itm)) {
      Menu.setInfo(row.itm, false)
      return
    }
    // A staged flow's text stage handles Esc in its own field; the select
    // stage has no field to swallow the key, so without this step Esc folds
    // the whole wizard instead of returning to the previous stage (e.g.
    // from "generate / enter" back to the filename input).

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
    if (Menu.scopedActive && !panel.scopedSearching) {
      panel.onFieldEdited("")
      focusCtrl.grabList()
      return
    }
    if (panel.scopedSearching) {
      panel.onFieldEdited("")
      if (searchField.text !== "") searchField.text = ""
      focusCtrl.grabList()
      return
    }
    if (panel.searching) {
      panel.onFieldEdited("")
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
      && !Menu.isUnavailable(m[index])
  }

  // Nearest row that can take the cursor: forward first, then back, like the
  // ends scan. A remembered or requested seat can name a store-gated row whose
  // condition stopped holding while the cursor was elsewhere.
  function seatableNear(index) {
    const n = panel.rowsModel.length
    if (n === 0) return -1
    const start = Range.clamp(Math.round(index), 0, n - 1)
    for (let i = start; i < n; i++) {
      if (panel.isSelectableIndex(i)) return i
    }
    for (let i = start - 1; i >= 0; i--) {
      if (panel.isSelectableIndex(i)) return i
    }
    return -1
  }

  // A store write or guard verdict can strand the cursor on a row that just
  // went muted. The row stays installed (it only turns muted), so no install
  // moves the cursor: step to the next row that can take it, forward first,
  // else back.
  function seatPastUnavailable() {
    const idx = panel.gridMode ? grid.currentIndex : list.currentIndex
    if (idx < 0 || idx >= panel.rowsModel.length) return
    if (panel.isSelectableIndex(idx)) return
    const rows = panel.rowsModel
    let target = -1
    for (let i = idx + 1; i < rows.length && target < 0; i++) {
      if (panel.isSelectableIndex(i)) target = i
    }
    for (let i = idx - 1; i >= 0 && target < 0; i--) {
      if (panel.isSelectableIndex(i)) target = i
    }
    if (target < 0) return
    if (panel.gridMode) grid.settle(target, false)
    else list.seat(target, "step")
  }

  function focusIndex(index) {
    if (!panel.isSelectableIndex(index)) return false
    if (panel.gridMode) grid.currentIndex = index
    else list.seat(index, "click")
    return true
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
      // A group's inline editor lives on the focused child, not on the
      // page row the cursor sits on. Without this the child's caret keys
      // route as menu navigation and Tab can leave the open editor.
      get editor() {
        const r = cur()
        if (!r) return false
        if (r.editorOpen === true) return true
        const c = typeof r._focusedChildRow === "function" ? r._focusedChildRow() : null
        return !!c && c.editorOpen === true
      },
      get del() {
        const r = panel.focusedRow()
        return !!r && !!r.itm && typeof r.itm.delCommand === "string"
          && r.itm.delCommand !== ""
      },
      get confirm() {
        const r = cur()
        return !!r && Menu.confirmFor(r.itm) !== null
      },
      // True for every dropdown that is NOT an option/group selector: those
      // keep their arrows (optionOrStep); everything else swallows them.
      get dropdown() {
        let r = cur()
        while (r) {
          if (r.dropdownOpen !== true)
            return r.expanded === true || r.descInSlot === true || r._shellClosing === true
          r = r.isGroup ? r._focusedChildRow() : null
        }
        return false
      }
    }
  }

  // Single key route for both modes. The routing table decides which
  // effect a press takes; this dispatches it. Every delegate read, cursor
  // write and focus grab is below - the table above it takes state, never
  // an item, so focus ownership stays entirely in this file.
  function handleKey(event) {
    // Ctrl-V pastes the clipboard into the query from the list. The field has
    // no caret there, so the native paste never sees the key; pasting lands
    // through the field's own pipeline and then takes the caret, so the next
    // keystroke extends the pasted query instead of replacing it.
    if (PanelKeys.pasteRoute(event.key, event.modifiers, Qt)) {
      // An open editor owns the key even when its own paste declined it (a
      // validator refused the paste): routing it into the query would pull
      // the filter's focus off the editor mid-edit - the same rule that makes
      // a letter the editor refused a swallow rather than a query key.
      const row = panel.currentRow()
      if (row && row.editorOpen === true) { event.accepted = true; return }
      if (panel.searchField.pasteText(Clipboard.history)) focusCtrl.grabFilter()
      event.accepted = true
      return
    }
    if (Menu.traceEnabled) {
      const ctx = panel.keyRouteCtx(event)
      Menu.trace("key.route", {
        key: ctx.key, editor: ctx.editor, field: ctx.field, mode: ctx.mode,
        row: panel.currentRow() ? String(panel.currentRow().itm?.id ?? "") : "",
        route: (MenuLib.keyRoute(ctx) || {}).name || ""
      })
    }
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
      // The caret, an editor or a blocking dropdown owns the key. Say so:
      // leaving it unaccepted lets Tab walk focus out of the open dialog.
      case "swallow":
        event.accepted = true
        break
      case "delete": {
        const drow = panel.focusedRow()
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
        panel.moveSelection(arg, event.isAutoRepeat === true)
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
        // Arming an empty filter projects the same rows: no content changes,
        // so nothing fades. The first character is the edge that does.
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
    const child = row && row._focusedChildRow ? row._focusedChildRow() : null
    if (Menu.traceEnabled) {
      Menu.trace("focus.reassert", {
        rowEditor: !!(row && row.editorOpen),
        childEditor: !!(child && child.editorOpen),
        child: child ? String(child.itm?.id ?? "") : "",
        search: searchField.focused, sink: focusCtrl.keySink.activeFocus
      })
    }
    if (child && child.editorOpen) {
      child.grabEditorFocus()
      return
    }
    if (row && row.editorOpen) {
      row.grabEditorFocus()
      return
    }
    // Keep PanelFocus' serviceVisible in sync (it watches Menu.open)
    // and let it decide list vs filter ownership.
    // A result handoff keeps the query alive through the results' fade-out.
    // Reasserting filter focus here would put the border back on the field
    // until the page switch, fading it with the reveal instead of the fold.
    if (!panel.handoffActive
      && (searchField.focused || focusCtrl.mode === "filter" || panel.searching)) {
      focusCtrl.mode = "filter"
      if (!searchField.focused) searchField.grabFocus()
      return
    }
    if (!focusCtrl.keySink.activeFocus) focusCtrl.keySink.forceActiveFocus()
  }

  function debugSetCurrentIdx(idx) {
    const previous = panel.currentRow()
    list.seat(idx, "step")
    if (previous && previous !== panel.currentRow()) {
      if (previous.expanded) previous.collapse()
      panel.closeTrailingInfo()
    }
    return list.currentIndex
  }

  // Ground truth for `menu probe`. A function, not a binding: the IPC
  // call is the only reader, so nothing should re-evaluate this on every
  // cursor move or geometry tick.
  function probeSnapshot() {
    const row = list.currentItem
    const gv = row && row.isGroup ? row._groupView : null
    const cr = row && row._focusedChildRow ? row._focusedChildRow() : null
    const ir = cr && cr._focusedChildRow ? cr._focusedChildRow() : null
    const dr = ir && ir._focusedChildRow ? ir._focusedChildRow() : null
    const igv = cr && cr._groupView ? cr._groupView : null
    const next = list && list.currentIndex >= 0
      ? list.itemAtIndex(list.currentIndex + 1) : null
    // The ghost is shell-painted inside InputField and already carries an
    // objectName, so the probe need not add a property to the shared field.
    let ghostOpacity = -1
    const fieldKids = searchField.children
    for (let i = 0; i < fieldKids.length; ++i) {
      if (fieldKids[i].objectName === "ghost") {
        ghostOpacity = Math.round(fieldKids[i].opacity * 1000) / 1000
        break
      }
    }
    const opts = cr && cr.optionList ? cr.optionList : []
    const optVal = cr && cr.st && cr.st.value !== undefined
      ? String(cr.st.value) : ""
    return JSON.stringify({
      nextRowY: next ? Math.round(next.y * 10) / 10 : -1,
      rowBottom: row ? Math.round((row.y + row.height) * 10) / 10 : -1,
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
      hlH: !panel.gridMode && list.highlightItem ? Math.round(list.highlightItem.height) : -1,
      hlW: !panel.gridMode && list.highlightItem ? Math.round(list.highlightItem.width) : -1,
      hlVisible: !panel.gridMode && list.highlightItem ? list.highlightItem.visible : false,
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
      // Result-handoff ground truth: the one progress value and the four
      // presentations derived from it, sampled together for frame-level
      // assertions that they cannot drift into separate tweens.
      handoff: Math.round(panel.handoff * 1000) / 1000,
      handoffActive: panel.handoffActive,
      pageOpacity: Math.round(pageHost.opacity * 1000) / 1000,
      textOpacity: Math.round(searchField.input.opacity * 1000) / 1000,
      fieldHandoff: Math.round(searchField.handoff * 1000) / 1000,
      fieldBorder: String(searchField.border.color),
      ghostOpacity: ghostOpacity,
      rowType: row ? row.ptype : "",
      rowLabel: row && row.itm ? String(row.itm.label ?? "") : "",
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
      // Nested group child motion, for live glide/settle diagnosis.
      rowH: row ? Math.round(row.height * 10) / 10 : 0,
      rowSettledH: row ? Math.round(row.settledHeight * 10) / 10 : 0,
      rowExpandSlotH: row ? Math.round(row.expandSlotH * 10) / 10 : 0,
      rowDescSlotH: row ? Math.round(row.descSlotH * 10) / 10 : 0,
      grpImplicitH: gv ? Math.round(gv.implicitHeight * 10) / 10 : 0,
      grpHeight: gv ? Math.round(gv.height * 10) / 10 : 0,
      grpColH: gv && gv.groupCol ? Math.round(gv.groupCol.height * 10) / 10 : 0,
      // In-dropdown scrolloff ground truth. `capped` is the decision to stop
      // growing the row and scroll behind the clipped box; `scrollY` is the
      // column's live translation. A long group must show capped true, a
      // scrollY that changes with the cursor, and a bar that stays in view.
      slotCeilingH: list.slotCeilingH,
      grpCeilingH: gv ? Math.round(gv.ceilingH * 10) / 10 : -1,
      grpNaturalH: gv ? Math.round(gv.naturalH * 10) / 10 : -1,
      grpViewportH: gv ? Math.round(gv.viewportH * 10) / 10 : -1,
      grpCapped: gv ? gv.capped : false,
      grpScrollY: gv ? Math.round(gv.scrollY() * 10) / 10 : -1,
      grpFadeTop: gv ? gv.moreAbove : false,
      grpFadeBottom: gv ? gv.moreBelow : false,
      grpFadeTopOpacity: gv && gv.fadeTop ? Math.round(gv.fadeTop.opacity * 100) / 100 : -1,
      grpFadeBottomOpacity: gv && gv.fadeBottom
        ? Math.round(gv.fadeBottom.opacity * 100) / 100 : -1,
      // Same ground truth one level down, for a nested group dropdown.
      innerGroupScrollY: igv ? Math.round(igv.scrollY() * 10) / 10 : -1,
      innerGroupViewportH: igv ? Math.round(igv.viewportH * 10) / 10 : -1,
      innerGroupNaturalH: igv ? Math.round(igv.naturalH * 10) / 10 : -1,
      innerGroupCapped: igv ? igv.capped : false,
      innerGroupChildIndex: igv && cr ? cr.childIndex : -1,
      grpChildCount: gv && gv.childrenRepeater ? gv.childrenRepeater.count : 0,
      childIndex: gv ? row.childIndex : -1,
      childLabel: cr && cr.itm ? String(cr.itm.label ?? "") : "",
      childLabelW: cr ? Math.round(cr.labelWidth * 10) / 10 : -1,
      childLabelNeeded: cr ? Math.round(cr.labelNeeded * 10) / 10 : -1,
      childElided: cr ? cr.textElided : false,
      childValueW: cr && cr.debugValueText ? Math.round(cr.debugValueText.width * 10) / 10 : -1,
      childValueTextW: cr && cr.debugValueText
        ? Math.round(cr.debugValueText.implicitWidth * 10) / 10 : -1,
      childValueX: cr && cr.debugValueText ? Math.round(cr.debugValueText.x * 10) / 10 : -1,
      childUnit: cr && cr.itm ? String(cr.itm.unit ?? "") : "",
      childSlotMs: cr ? cr.slotMotionMs : 0,
      guardDisabledKeys: Object.keys(Menu.guardDisabled).join("|"),
      childUid: cr && cr.itm ? String(cr.itm.uid ?? "") : "",
      childGuardDisabled: cr && cr.itm ? Menu.guardDisabled[String(cr.itm.uid ?? "")] : null,
      childModelSelectable: cr && cr.itm ? cr.itm.selectable : null,
      childDisabled: cr && cr.itm ? Menu.isDisabled(cr.itm) : false,
      childUnavailable: cr && cr.itm ? Menu.isUnavailable(cr.itm) : false,
      childSelectable: cr ? cr.selectable === true : false,
      childEnabled: cr ? cr.enabled === true : false,
      childActive: cr && cr.itm ? String(cr.itm.active ?? "") : "",
      childType: cr ? cr.ptype : "",
      childOptionCount: cr ? cr.optionCount : -1,
      childOptionIndex: cr ? cr.optionIndex : -1,
      childChosenIndex: cr ? cr.chosenIndex : -1,
      childOptions: JSON.stringify(opts.map(function(o, i) {
        return { i: i, label: String((o && o.label) ?? ""),
          value: String((o && o.value) ?? ""),
          chosen: String((o && o.value) ?? "") === optVal }
      })),
      childExpanded: cr ? cr.expanded === true : false,
      childIsGroup: cr ? cr.isGroup === true : false,
      childDropdownOpen: cr ? cr.dropdownOpen === true : false,
      childIndexInner: cr ? cr.childIndex : -1,
      childGroupKids: cr && cr.groupChildren ? cr.groupChildren.length : 0,
      deepIdx: dr ? dr.childIndex : -1,
      deepLabel: dr && dr.itm ? String(dr.itm.label ?? "") : "",
      deepExpanded: dr ? dr.expanded === true : false,
      innerIdx: ir ? ir.childIndex : -1,
      innerLabel: ir && ir.itm ? String(ir.itm.label ?? "") : "",
      innerExpanded: ir ? ir.expanded === true : false,
      innerExpandH: ir ? Math.round(ir.expandSlotH * 10) / 10 : -1,
      innerSlotY: ir ? Math.round(ir.debugSlotY * 10) / 10 : -1,
      innerSlotH: ir ? Math.round(ir.debugSlotH * 10) / 10 : -1,
      innerMainBottom: ir && ir.debugMainLine
        ? Math.round((ir.debugMainLine.y + ir.debugMainLine.height) * 10) / 10 : -1,
      innerNestedBarH: ir ? Math.round(ir.nestedBarH * 10) / 10 : -1,
      innerFocusBarY: igv && igv.focusBar ? Math.round(igv.focusBar.y * 10) / 10 : -1,
      innerFocusBarH: igv && igv.focusBar ? Math.round(igv.focusBar.height * 10) / 10 : -1,
      innerGroupH: igv ? Math.round(igv.height * 10) / 10 : -1,
      innerGroupImplicit: igv ? Math.round(igv.implicitHeight * 10) / 10 : -1,
      innerColH: igv && igv.groupCol ? Math.round(igv.groupCol.height * 10) / 10 : -1,
      innerRowY: ir ? Math.round(ir.y * 10) / 10 : -1,
      innerEditorH: ir ? Math.round(ir.debugEditorH * 10) / 10 : -1,
      innerSlotMs: ir ? ir.slotMotionMs : 0,
      innerBarH: igv ? Math.round(igv.focusBarH * 10) / 10 : -1,
      innerBox: igv ? Math.round(igv.boxNeed * 10) / 10 : -1,
      childDescH: cr ? Math.round(cr.descSlotH * 10) / 10 : 0,
      childExpandH: cr ? Math.round(cr.expandSlotH * 10) / 10 : 0,
      childFlowIdx: cr && cr.isFlow ? cr.flowIndex : -1,
      childBuilds: cr ? cr.debugExpBuilds : -1,
      childGhostLabels: cr ? cr.debugGhostLabels : "",
      pushProg: gv ? Math.round(gv.pushProgress * 1000) / 1000 : -1,
      boxTarget: gv ? Math.round(gv.boxTarget * 10) / 10 : -1,
      curY: list.currentItem ? Math.round(list.currentItem.y * 10) / 10 : -1,
      curH: list.currentItem ? Math.round(list.currentItem.height * 10) / 10 : -1,
      childMainBottom: cr && cr.debugMainLine
        ? Math.round((cr.debugMainLine.y + cr.debugMainLine.height) * 10) / 10 : -1,
      childSlotY: cr ? Math.round(cr.debugSlotY * 10) / 10 : -1,
      childSlotH: cr ? Math.round(cr.debugSlotH * 10) / 10 : -1,
      childEditorH: cr ? Math.round(cr.debugEditorH * 10) / 10 : -1,
      grpBarY: gv && gv.focusBar ? Math.round(gv.focusBar.y * 10) / 10 : -1,
      grpBarH: gv && gv.focusBar ? Math.round(gv.focusBar.height * 10) / 10 : -1,
      grpBarOpacity: gv && gv.focusBar
        ? Math.round(gv.focusBar.opacity * 100) / 100 : -1,
      grpBarVisible: gv && gv.focusBar ? gv.focusBar.visible : false,
      grpColY: gv && gv.groupCol ? Math.round(gv.groupCol.y * 10) / 10 : -1,
      focusRestH: gv ? Math.round(gv.focusRestH * 10) / 10 : 0,
      focusBarH: gv ? Math.round(gv.focusBarH * 10) / 10 : 0,
      liveExtra: gv ? Math.round(gv.liveExtra * 10) / 10 : 0,
      topHalf: gv ? gv.topHalf : false,
      pushUp: gv ? Math.round(gv.pushUp * 10) / 10 : 0,
      roomAbove: gv ? Math.round(gv.roomAbove * 10) / 10 : 0,
      roomBelow: gv ? Math.round(gv.roomBelow * 10) / 10 : 0,
      overflow: gv ? Math.round(gv.overflow * 10) / 10 : 0,
      boxNeed: gv ? Math.round(gv.boxNeed * 10) / 10 : 0,
      animRunning: list.debugAnimRunning,
      sweepMs: list.debugSweepMs,
      pursuitIdx: list.debugPursuitIdx,
      followIdx: list.debugFollowIdx,
      seatsInstant: list.debugSeatsInstant,
      hlResizeMs: list.highlightResizeDuration,
      // Spawn verdict for the last summon: whether the card was born at its
      // own size or opened wearing the previous menu's box. `carried` true is
      // the regression this whole record exists to catch.
      spawn: panel.probeSpawn()
    })
  }

  // --- deep live trace -------------------------------------------------
  // A frame sampler for the running shell. Armed only by `debugDeep`, it
  // records every visible row and every open dropdown at each tick, beside
  // the reactive verdicts that decide the card and the viewport. The test
  // suite reads the ring with `probeDeep` and asserts frame sequences, not
  // just the state a gesture happens to end in.

  property bool deepArmed: false
  property string deepPhase: ""
  property var deepFrames: []
  readonly property int deepLimit: 600

  function _deepNum(v) {
    return Math.round(Number(v || 0) * 10) / 10
  }

  function _deepRow(r, depth) {
    if (!r || depth > 5) return null
    const gv = r.isGroup && r._groupView ? r._groupView : null
    const kids = []
    const repeater = gv ? gv.childrenRepeater : null
    if (repeater) {
      for (let i = 0; i < repeater.count; i++) {
        const it = repeater.itemAt(i)
        if (it && it.liveRow) kids.push(_deepRow(it.liveRow, depth + 1))
      }
    }
    return {
      id: r.itm && r.itm.id !== undefined ? String(r.itm.id) : "",
      label: r.itm ? String(r.itm.label ?? "") : "",
      type: r.ptype,
      idx: r.index !== undefined ? r.index : -1,
      y: panel._deepNum(r.y), h: panel._deepNum(r.height),
      settled: panel._deepNum(r.settledHeight),
      barH: panel._deepNum(r.nestedBarH),
      barSettled: panel._deepNum(r.nestedSettledBarH),
      expanded: r.expanded === true, dropdown: r.dropdownOpen === true,
      editor: r.editorOpen === true, info: r.infoOpen === true,
      descH: panel._deepNum(r.descSlotH),
      expandH: panel._deepNum(r.expandSlotH),
      optionIndex: r.optionIndex, optionCount: r.optionCount,
      childIndex: r.childIndex,
      childCount: r.groupChildren ? r.groupChildren.length : 0,
      group: gv ? {
        h: panel._deepNum(gv.height),
        natural: panel._deepNum(gv.naturalH),
        viewport: panel._deepNum(gv.viewportH),
        ceiling: panel._deepNum(gv.ceilingH),
        capped: gv.capped === true,
        colH: panel._deepNum(gv.groupCol ? gv.groupCol.height : 0),
        colY: panel._deepNum(gv.groupCol ? gv.groupCol.y : 0),
        barY: panel._deepNum(gv.focusBar ? gv.focusBar.y : 0),
        barH: panel._deepNum(gv.focusBar ? gv.focusBar.height : 0),
        scroll: panel._deepNum(gv.scrollY()),
        overflow: panel._deepNum(gv.overflow),
        box: panel._deepNum(gv.boxNeed),
        push: Math.round(gv.pushProgress * 1000) / 1000
      } : null,
      children: kids
    }
  }

  function deepSnapshot() {
    const rows = []
    for (let i = 0; i < list.count; i++) {
      const it = list.itemAtIndex(i)
      if (it) rows.push(_deepRow(it, 0))
    }
    const n = panel._deepNum
    return {
      t: Date.now() % 1000000,
      phase: panel.deepPhase,
      an: MotionPolicy.enabled,
      base: JSON.parse(panel.probeSnapshot()),
      rows: rows,
      card: {
        h: n(panel.height), listH: n(listBox.height), listY: n(listBox.y),
        filterH: n(filterBar.height), chrome: n(panel.regionChromeH),
        rendered: n(panel.renderedListH), model: n(panel.modelListH),
        claim: n(panel._claimListH), region: n(panel._slotRegionH),
        committed: n(panel._committedListH), hardMax: n(panel.hardMaxHeight),
        max: n(panel.maxHeight), fitPending: panel._fitPending,
        rowsMoving: panel._rowsMoving, transition: panel._transitionActive,
        heightAnimating: panel._heightAnimating,
        viewFade: Math.round(panel.viewFade * 1000) / 1000,
        handoff: Math.round(panel.handoff * 1000) / 1000
      },
      scroll: {
        contentY: n(list.contentY), contentH: n(list.contentHeight),
        maxY: n(list.tableMaxY()), h: n(list.height),
        moving: list.moving, sweeping: list._sweeping,
        animating: list.debugAnimRunning, clip: list.clip
      }
    }
  }

  function deepStart(phase) {
    panel.deepFrames = []
    panel.deepPhase = String(phase || "")
    panel.deepArmed = true
    deepTimer.restart()
    return "deep on"
  }

  function deepMark(phase) {
    panel.deepPhase = String(phase || "")
    return panel.deepPhase
  }

  function deepStop() {
    panel.deepArmed = false
    deepTimer.stop()
    return "deep off"
  }

  function deepFramesJson(from, count) {
    return JSON.stringify(panel.deepFrames.slice(from, from + count))
  }

  QQ.Timer {
    id: deepTimer
    interval: 16
    repeat: true
    running: panel.deepArmed
    onTriggered: {
      if (panel.deepFrames.length >= panel.deepLimit) panel.deepFrames.shift()
      panel.deepFrames.push(panel.deepSnapshot())
    }
  }

  // Filter block: the header component owns the field's input contract (role,
  // chip, hint, the four routes); the panel keeps what those routes do and
  // reads the field through the alias below, so SearchScope's call sites are
  // unchanged.
  MenuFilterBar {
    id: filterBar

    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Ui.outerPad
    height: Ui.filterH
    scoped: Menu.scopedActive
    // The result handoff and the mode fade are two readings of one field
    // contract: the border and ghost leave with whichever transition is
    // running, and the query text fades with the view it belongs to.
    handoff: Math.max(panel.handoff, 1 - panel.viewFade)
    queryOpacity: panel.handoffTextOpacity * panel.viewFade

    onEdited: text => panel.onFieldEdited(text)
    // TextInput consumes Enter to emit accepted; route it here since it
    // never reaches the panel handler while the field holds focus.
    onAccepted: text => panel.activateCurrent(false)
    onEscaped: panel.escapeChain()
    // Backspace on an empty field leaves Filter mode, like Esc with empty
    // input does - but never pops or closes (Launcher parity: stepBack
    // only exits the mode). Regular search already exits via query-empty;
    // the "/" filter stays armed with an empty query by design, so without
    // this it could never be left by Backspace.
    onBackspaceEmpty: panel.backspaceEmptyChain()
    // Clicking in or out of the field moves focus natively; assert ownership
    // immediately instead of waiting for the healer.
    onFieldFocusChanged: Qt.callLater(panel.reassertFocus)
  }

  // The field itself, for the text/focus/word-editing routes below.
  property alias searchField: filterBar.field

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
      // A search-result handoff derives pageHost opacity from handoff. Keep
      // the depth bookkeeping current but leave that value alone; a
      // same-depth snap here would show the whole swap in one frame.
      if (panel.handoffActive) {
        listBox.lastDepth = depth
        return
      }
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
        panel._pageSlideOpacity = 1
        return
      }
      // Same depth, no navigation (summon-time page switch after the
      // open seat above): snap, never slide.
      if (depth === listBox.lastDepth) {
        slideAnim.stop()
        pageHost.x = 0
        panel._pageSlideOpacity = 1
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
        panel._pageSlideOpacity = 1
        return
      }
      pageHost.x = dir * 48
      panel._pageSlideOpacity = 0
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
      // A short-dropdown mode restore grows the whole card on this tween,
      // so it starts from rest instead of OutCubic's steep first frame.
      easing.type: panel._modeRestoreFitOwned
        ? Easing.InOutCubic : Easing.OutCubic
      onFinished: panel.finishHeightTransition()
    }

      ParallelAnimation {
        id: slideAnim

        NumberAnimation {
          id: slideX
          target: pageHost
          property: "x"
          to: 0
          duration: Ui.fastGraceMs
          easing.type: Easing.OutCubic
        }
        NumberAnimation {
          id: slideFade
          target: panel
          property: "_pageSlideOpacity"
          to: 1
          duration: Ui.fastGraceMs
          easing.type: Easing.OutCubic
      }
    }

    Item {
      id: pageHost

      x: 0
      y: 0
      width: listBox.width
      height: listBox.height
      // One presentation of the two shared progress values: the result
      // handoff owns the page-swap edges, and viewFade masks a mode switch.
      // Outside both, the ordinary submenu slide value shows through.
      opacity: (panel.handoffActive
        ? panel.handoffPageOpacity : panel._pageSlideOpacity) * panel.viewFade

      List {
        id: list

        traceDebug: Menu.traceEnabled
        visible: !panel.gridMode
        // The card's own screen ceiling, published for delegates that host a
        // scrollable dropdown. A long group caps its viewport against this so
        // the row it publishes back is one the card can grow to show, instead
        // of a column whose lower children are clipped by the window.
        slotCeilingH: panel.screenMaxListH
        // Unbound while the grid shows: the grid renders the same row set,
        // so Entry delegates (Texts, TextMetrics, icons, slots) built here
        // would be shaped, measured and tracked for rows nobody sees -
        // thousands of them on picker bundles. Every grid-mode reader of
        // this view branches to the grid or tolerates an empty one.
        model: panel.gridMode ? null : listModel
        // Center-lock scrolloff: keyboard steps keep the cursor riding
        // the viewport middle while scrolling is possible. Steps ease
        // while animations run, jump while off.
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
        onAutoRevealIndexChanged: panel._trackRevealOrigin()
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
            || (modelData && modelData.scopedResult === true)
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
              const ms = rowItem.slotMotionMs
              Menu.trace("panel.slotMs", {
                id: String(rowItem.itm?.id ?? ""), ms: ms,
                closing: Menu.isSlotClosing(rowItem.itm),
                slots: panel.expansionNeedH
              })
              // The row's motion is one of the signals the fit's settle gate
              // reads; re-check the pending fit on both the open and the
              // landing edge, not only when the row goes still.
              panel._tryFit()
              if (ms > 0) return
              panel._closeSeatDone()
              // The collapse has landed: the width pace may drop its slot
              // latch now (it was held for the fold that just finished).
              panel._slotMsLatch = 0
              Menu.slotCloseFinished(rowItem.itm)
            }

            function onHeightChanged() {
              // One clock: the row's own unfold drives the card and viewport.
              // The region follow is a plain write (no tween to re-arm), so
              // per-frame updates are exactly what it needs.
              panel._followSlotRow()
              if (panel._trackingCloseSeat) panel._trackCloseSeat()
            }

            function onSlotCloseStarted() {
              // This edge is the last fold of a reveal chain: the page row's
              // slot closes with no nested child open. The scroll returns at
              // this slot's pace, not on a timer.
              Menu.trace("panel.closeStart", {
                id: String(rowItem.itm?.id ?? ""), ms: rowItem.slotMotionMs,
                expanded: rowItem.expanded, info: rowItem.infoOpen
              })
              if (!rowItem.expanded && !rowItem.infoOpen)
                panel._beginPageClose(rowItem)
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
        }
      }
    }

    // Dead center of the empty list box. Filter/search with no hits
    // shows the mode glyph above the copy (bar-island pattern):
    // scoped "/" filter -> filter-x + "No matches", global search ->
    // search-alert + "No results", both two-tone with a red indicator.
    // A truly empty page stays text-only.
    EmptyState {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - 32)
      visible: (panel.gridMode ? grid.count : list.count) === 0 && Menu.open
      text: panel.searching ? "No results" : panel.scopedSearching ? "No matches" : "Empty page"
      iconName: {
        if (!panel.searching && !panel.scopedSearching) return ""
        if (panel.searching) return "search-alert"
        return "filter-x"
      }
      iconColorKey: "foreground_1"
      iconAccentKey: {
        if (!panel.searching && !panel.scopedSearching) return ""
        return "red"
      }
    }
  }

  PointerGuard {}

  // --- DIAGNOSTIC frame sync (armed only by `debugTrace on`) ---
  // One compact geometry record per display frame while a trace is on. A
  // one-frame jump of the top-level entries shows up here as a single row
  // where cY/cardY/curY/hlY change far more than their neighbours, together
  // with the one-shot flags that were live at that instant.
  Timer {
    interval: 16
    repeat: true
    running: Menu.traceEnabled && Menu.open
    onTriggered: {
      const it = list.currentItem
      const hl = list.highlightItem
      Menu.trace("frame.sync", {
        t: Date.now() % 100000,
        cY: Math.round(list.contentY * 10) / 10,
        cH: Math.round(list.contentHeight * 10) / 10,
        vH: Math.round(list.height * 10) / 10,
        cardH: Math.round(panel.height * 10) / 10,
        cardY: Math.round(panel.y * 10) / 10,
        hlY: hl ? Math.round(hl.y * 10) / 10 : -1,
        hlH: hl ? Math.round(hl.height * 10) / 10 : -1,
        curY: it ? Math.round(it.y * 10) / 10 : -1,
        curH: it ? Math.round(it.height * 10) / 10 : -1,
        reg: Math.round(panel._slotRegionH * 10) / 10,
        claim: Math.round(panel._claimListH * 10) / 10,
        live: Math.round(panel._slotRegionH * 10) / 10,
        slot: Menu.slotClosing, nest: panel._nestedSeatPending,
        track: panel._trackingCloseSeat, pg: panel._closePageMode,
        anim: list.debugAnimRunning, auto: list.autoRevealIndex,
        seatN: Math.round(panel._nestedSeatY * 10) / 10,
        seatO: Math.round(panel._revealOriginY * 10) / 10
      })

    }
  }

  onHeightChanged: if (Menu.traceEnabled) Menu.trace("frame.cardH", {
    h: Math.round(panel.height * 10) / 10, y: Math.round(panel.y * 10) / 10,
    live: Math.round(panel._slotRegionH * 10) / 10,
    reg: Math.round(panel._slotRegionH * 10) / 10,
    slot: Menu.slotClosing, nest: panel._nestedSeatPending
  })
  onYChanged: if (Menu.traceEnabled) Menu.trace("frame.cardY", {
    y: Math.round(panel.y * 10) / 10, h: Math.round(panel.height * 10) / 10
  })

  // keySink lives inside PanelFocus (focusCtrl.keySink); callers use it
  // directly, with no panel-level alias.
}

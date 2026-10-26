pragma ComponentBehavior: Bound
import QtQuick
import qs.common
import "./RowMetrics.js" as RowMetrics

// Declarative card frame that replaces the triplicated region geometry,
// shown-gate animation and width/height chrome in every panel.
//
// Panels use it as a drop-in Rectangle:
//   PanelCard {
//     id: card
//     maxHeight: Math.round(parent.height * 0.7)
//     hardMaxHeight: Math.round(parent.height * 0.92)
//     baseWidth: 360
//     count: list.count
//     contentHeight: list.contentHeight
//     slotOpen: list.revealNeedH > 0
//     slotRegionH: SlotGrowth.regionForSlot(
//       list, card.restingListH, card.screenMaxListH, Ui.s) // -1 = no override
//     rows: panel.rows  // for width fitting
//     // children: filterBar + listBox, anchored to parent
//   }
// Geometry is pure declarative; showGate re-arms via show().
Rectangle {
  id: root

  property real maxHeight: 600
  property real hardMaxHeight: 1200
  property int outerPad: Ui.outerPad
  property int vPad: outerPad
  property int hPad: outerPad
  property int filterH: Ui.filterH
  property int listTopGap: Ui.listTopGap
  // Panels without a filter bar (pass vault) opt out of the filter
  // chrome so the card hugs the list instead of keeping a phantom gap.
  // Defaults on - every existing consumer keeps its geometry.
  property bool hasFilter: true
  property int emptyMinH: Ui.emptyMinH
  property int baseWidth: Ui.defWidth

  // Content-driven inputs.
  property int count: 0
  property real contentHeight: 0
  // A DECIDED region override, or -1 for none: the region the card should
  // show while one of its rows has an open in-flow slot, already worked out by
  // whoever owns the list through SlotGrowth.js.
  //
  // The region override is a DECIDED height, not the list's raw claim. A
  // claim is an absolute position in CONTENT coordinates, and comparing it
  // against a region without first removing the scroll offset asks the card
  // to become as tall as the row's distance down the page: on a scrollable
  // list the further down a row sits, the more the window grows, so a
  // dropdown on the last folder in the password manager expands the window by
  // its own scroll offset when there was ample room to scroll instead. The
  // arithmetic lives in SlotGrowth.js, so the rule is written once.
  //
  // A card is a box that knows how tall it is; it has no business knowing what
  // a claim means. Consumers with no slot growth at all pass -1 and get the
  // resting region, which is what they always got.
  property real slotRegionH: -1
  // Whether a row currently has an in-flow slot open, whatever the card does
  // about it. Separate from `slotRegionH` because a dropdown that fits makes
  // the content taller while asking for no resize - the list scrolls it - so
  // "a slot is open" and "the card grows" are different facts about one
  // gesture. See _latchRestingBuffer.
  property bool slotOpen: false
  property real bottomReserve: 0
  property real exactListH: -1
  property bool fitPending: false
  property int rowLimit: 0
  property var rows: []
  // The gap between two rows, which is the LIST's `spacing` and not a
  // number this card gets to choose: the list places the gap, and a card
  // that assumed its own value would put the region's bottom edge off the
  // row boundary the moment a surface spaced its rows differently. Read
  // from the list rather than defaulted per panel, so a surface that
  // changes its spacing cannot leave the region behind.
  property real rowSpacing: 2
  // A consumer's own resting-height function, for rows this card cannot
  // read: (row) -> resting height. Null is the ordinary case, and the
  // label/sub vocabulary below answers instead.
  //
  // This is the escape from a shared vocabulary that does not fit, and it
  // is deliberately a FUNCTION rather than a `restH` field on the row
  // record. A field would have to be computed into the model, and a model
  // that carries pixel heights is a model that has to be re-derived
  // whenever the fonts land; a function keeps the arithmetic here and lets
  // the surface that owns the row's real shape answer for it.
  //
  // It exists because a floor is not an answer. A row whose title field is
  // not `label` measured as an empty row, and the empty row's height is a
  // perfectly plausible number - so the wrong region looked like a right
  // one and cost two debugging round trips before the consumer answered
  // for itself. A surface whose rows are uniform states that here and
  // stops guessing.
  property var rowHeightFn: null

  // Width fitting.
  property int contentW: baseWidth
  property int _maxLabelW: 360
  property int rowIconW: 24
  property int rowBadgeW: 0

  // Chrome.
  readonly property real regionChromeH: root.hasFilter
    ? 2 * vPad + filterH + listTopGap
    : 2 * vPad
  readonly property real availListH: Math.max(0, maxHeight - regionChromeH - root.bottomReserve)
  readonly property real screenMaxListH: Math.max(availListH,
    hardMaxHeight - regionChromeH - root.bottomReserve)

  // Resting buffer - last idle contentHeight (no open slot) so the card
  // matches live delegate geometry exactly (model math undershoots by
  // ~2px/row: TextMetrics vs implicitHeight). The region takes the max
  // of model math and the latch: a birth-transient sample can only pull
  // down to the model floor, never below it - the viewport breathing
  // that briefly scrolled short lists (maxY flapping 0/39 on a 3-row
  // view). Overshoot samples are cosmetic empty space and heal on the
  // next latch. Slot growth bypasses the resting region entirely (see
  // restingListH/listRegionH), so an open slot cannot poison this latch.
  property real restingBufH: 0
  property string _rowSetKey: ""
  function _rowSetKeyForRows() {
    const rows = root.rows
    if (!rows || rows.length !== 1) return null
    const row = rows[0]
    if (!row) return "1|?"
    const shape = String(row.sub ?? row.subLeft ?? "") === "" ? "1" : "2"
    return "1|single:" + shape
  }
  // A slot-inflated contentHeight is never the resting size, so the latch
  // is skipped for as long as one is open: the caller's own close edge
  // re-arms it (onSlotOpenChanged).
  //
  // The gate is `slotOpen`, NOT the region override, and the two are separate
  // inputs on purpose. A dropdown that fits in the resting region makes the
  // content taller while asking for no resize at all - the list scrolls it
  // into view - so "a slot is open" and "the card must grow" are different
  // facts about the same gesture. Deriving the first from the second would
  // latch an inflated contentHeight as the resting size on exactly the
  // dropdowns that never resize the card.
  function _latchRestingBuffer() {
    if (root._restingPending || root.slotOpen) return
    root._restingPending = true
    Qt.callLater(() => {
      root._restingPending = false
      if (!root.slotOpen) root.restingBufH = root.contentHeight
    })
  }
  property bool _restingPending: false
  // Latched on count/row-generation changes only: contentHeight ticks
  // every frame while estimates churn during scroll, and latching those
  // resizes the viewport under a moving view (stale seats, drift).
  onCountChanged: {
    // A real row-set change ends the fit-recovery window too: a keystroke
    // landing mid-close may legitimately fit larger than before, and the
    // monotone ceiling would refuse it.
    root._fitRecovering = false
    root._latchRestingBuffer()
  }
  onRowsChanged: {
    const key = root._rowSetKeyForRows()
    if (key !== null && key === root._rowSetKey) return
    root._rowSetKey = key
    root._fitRecovering = false
    if (root.slotOpen) return
    root.restingBufH = 0
    root._latchRestingBuffer()
  }
  // Closing edge only. The resting FIT is stale the moment the slot shuts -
  // it was measured against an inflated content, so it has to be re-read -
  // while the resting BUFFER must not be re-latched here: the edge fires the
  // moment the claim releases, with the slot still mid-collapse and the live
  // contentHeight still inflated by its remainder. Latching that remainder
  // poisons the buffer by the slot's leftover share and the card stays a few
  // pixels taller. The buffer re-latches on row-set changes (count/rows,
  // gated settled by slotOpen) and after measured fits the consumer
  // relatches once settled - both read resting content, never a collapse.
  onSlotOpenChanged: {
    if (root.slotOpen) {
      root._fitRecovering = false
    } else {
      // Only enter recovery if the slot actually inflated the fit, so an
      // ordinary open/close of a slot that changed nothing costs nothing.
      root._fitRecovering = root.exactListH > root._restingFitH + 0.5
    }
    root._latchRestingFit()
  }

  // The measured height of exactly the rows this card renders, or 0 while no
  // measurement exists.
  //
  // restingBufH is the WHOLE list's content height, so it reaches a capped
  // viewport through the cap's share of the ESTIMATED height and never
  // through its row COUNT. A cap is not N average rows: the launcher's cap
  // holds a 12px separator beside ten full-height rows, and count scaling
  // charges that separator a whole row. On its twelve-row cap that is 36px
  // of phantom height - most of a row - and the ceiling in rowLimitRegion
  // then trims it, so the trim lands mid-row and the last entry is cut
  // through the middle. Scaling by the estimated share keeps the
  // composition instead: the separator stays a separator, a run of taller
  // rows keeps its share, and the answer is the height those rows really
  // occupy - up to the per-row gap between the TextMetrics probe and the
  // delegate's own line box, which is what this term is here to heal.
  //
  // An uncapped card renders every row, so its share is the whole and the
  // answer is restingBufH unchanged.
  readonly property real cappedBufH: {
    if (root.rows.length <= 0 || !(root.restingBufH > 0)) return 0
    const estCap = modelContentH()
    if (!(estCap > 0)) return 0
    const estAll = modelContentH(0)
    if (!(estAll > 0)) return 0
    return root.restingBufH * estCap / estAll
  }

  // Region for a row-limit card, the shape the launcher drives. The cap is
  // what this card renders, so BOTH terms are measured over the capped row
  // set:
  //
  // - snappedListH already stops at the cap, and `avail` is never the right
  //   answer for a capped list: ten rows are not as tall as the window
  //   unless ten rows happen to fill it. Returning `avail` for the
  //   over-cap case is what made the card breathe by the difference every
  //   time a result count crossed the cap.
  // - cappedBufH is the model's FULL content height (1223px for 25 rows)
  //   reduced to the cap, so it keeps its purpose - healing the model math's
  //   ~2px/row underestimate - without letting an uncapped list claim the
  //   window.
  //
  // Every term is a whole-row sum, which is the whole point: the region's
  // bottom edge has to be the bottom edge of a row, or the last row renders
  // cut. `avail` is a screen number and lands mid-row, so it is a CEILING
  // to test against, never an answer - a cap taller than the window is
  // answered with the largest whole prefix that fits instead.
  //
  // An open in-flow slot claims the region outright, exactly as the final
  // branches below do: a single-row regime (the function graph, a lone
  // description) must size the card to its one row instead of reserving the
  // whole window and leaving the card mostly empty beneath it.
  function rowLimitRegion(avail) {
    const total = root.rows.length
    const shown = total > 0 ? Math.min(root.rowLimit, total) : 0
    if (shown <= 0) return 0
    const est = snappedListH(avail)
    const healed = Math.max(est, root.cappedBufH)
    return healed <= avail + 0.5 ? healed : est
  }

  // The fit, held at its last value measured with NO slot open.
  //
  // `exactListH` is a live measurement: a consumer computes it with
  // `list.fitHeight(avail)`, and that walk reads each row's CURRENT height, so
  // an open dropdown inflates it - and inflates the `y` of every row beneath
  // it besides. Handing that to `restingListH`, which is documented as the
  // height of the row set "with nothing open", is the category error that made
  // a dropdown on the FIRST row of the password manager grow the window: the
  // fit said 532, the resting region believed it, and the growth rule was
  // never consulted at all. The `slotOpen` gate on `restingBufH` cannot catch
  // this, because the dominant term is `exactListH` and that arrives
  // unmeasured-by-the-gate, every frame.
  //
  // So the fit is latched, and only re-read when nothing is open - the same
  // idiom `restingBufH` already uses for the same reason, one term up. With no
  // slot open the latch tracks `exactListH` exactly, so the ordinary case is
  // unchanged; with one open the card holds the size it had, and whether it
  // grows at all becomes the slot override's decision (SlotGrowth.js) rather
  // than the fit's.
  property real _restingFitH: -1
  // Set when a slot shuts, cleared when the fit has come back down. See
  // _latchRestingFit: the recovery is monotone for a reason.
  property bool _fitRecovering: false
  function _latchRestingFit() {
    if (root.slotOpen) return
    const h = root.exactListH
    if (!(h >= 0)) return
    if (root._fitRecovering) {
      // A close is still collapsing. The claim is released the moment the slot
      // STARTS closing, so `slotOpen` falls while the content is still the
      // tall one - latching here took the inflated fit (532) and then snapped
      // to the real one (292) a few frames later, which is the small jump on
      // close. For a plain open/close the row set does not change, so the
      // resting fit can only come back DOWN to what it was: accept a falling
      // fit, refuse a rising one until it does.
      if (h > root._restingFitH + 0.5) return
      root._fitRecovering = false
    }
    if (Math.abs(h - root._restingFitH) < 0.5) return
    root._restingFitH = h
  }
  onExactListHChanged: root._latchRestingFit()
  Component.onCompleted: {
    root._latchRestingFit()
  }
  // A real refit ends the recovery window: a keystroke that lands mid-close may
  // legitimately fit LARGER than before, and the monotone ceiling would refuse
  // it. onRowsChanged / onCountChanged / onFitPendingChanged are declared with
  // the resting-buffer latches below, and they clear it there - QML allows one
  // handler per signal, so all four edges live together.
  onFitPendingChanged: {
    if (root.fitPending) root._fitRecovering = false
  }

  // The resting region: what the row set is worth with nothing open. An
  // open slot never reaches it - growth is applied on top of it
  // (listRegionH) - so a slot cannot resize the fitted size the next fit
  // measures against, and one that opened mid-transition cannot leave a
  // dropdown's height behind in the latch.
  readonly property real restingListH: {
    const avail = root.availListH
    if (root.count === 0) return Math.min(root.emptyMinH, avail)
    // A pending fit means the exact measurement is on its way, and
    // `_restingFitH` still carries the PREVIOUS row set's committed height.
    // That is the number on screen right now, so holding it is what keeps
    // the card still across a keystroke. Re-deriving a guess from the model
    // while the fit is in flight is what made the region jump under every
    // filter tick (a 33-row list reading `avail` for a frame, then its real
    // fitted height on the next) - the card breathing once per key press.
    // The guess is kept only for a fit with nothing to hold, which is the
    // first one after an open.
    if (root.fitPending) {
      if (root._restingFitH >= 0) {
        return Math.min(root._restingFitH, root.screenMaxListH)
      }
      return root.rowLimitRegion(avail)
    }
    if (root._restingFitH >= 0) {
      // Floor, not ceiling: a fit that sampled a newborn delegate can land
      // short, and the region must not follow it down. The floor is the
      // MODEL's height for the same capped rows, which is a whole-row sum
      // and so keeps the answer on a row boundary. The old term here took
      // restingBufH (a whole-list number that has no business sizing a
      // capped viewport) and min'd it against the estimate prefix, which
      // degenerates to the estimate itself - the one value in this card
      // that is neither measured nor row-aligned, and the one that wins the
      // max whenever it counts a row the real geometry does not fit.
      const floorH = Math.min(root.snappedListH(avail), root.screenMaxListH)
      return Math.min(Math.max(root._restingFitH, floorH), root.screenMaxListH)
    }
    if (root.rowLimit > 0) return root.rowLimitRegion(avail)
    const modelH = modelContentH()
    const contentH = Math.max(modelH, root.restingBufH)
    if (contentH > 0 && contentH <= avail) return contentH
    return snappedListH(avail)
  }

  // Resting region, raised to a slot override when one is supplied.
  //
  // `slotRegionH` is a DECIDED region, not a claim: the consumer ran it
  // through SlotGrowth.js against its own resting region, so the scroll-first
  // test, the scroll-offset subtraction and the reveal margin are already
  // settled by the time a number arrives here. This card only clamps it to the
  // screen ceiling and takes the larger of the two.
  //
  // max() and not a replacement: an override below the resting region means the
  // consumer decided the list can scroll the slot into view instead, and the
  // resting region is the floor in that case - the card is never smaller than
  // the rows it is showing.
  readonly property real listRegionH: {
    const base = root.restingListH
    const want = root.slotRegionH
    if (!(want > 0)) return base
    return Math.min(Math.max(base, want), root.screenMaxListH)
  }

  readonly property real cardHeight: Math.min(
    root.regionChromeH + root.listRegionH + root.bottomReserve, root.hardMaxHeight)

  // The card's own size, per change. Every panel's window follows from this
  // one number, so it is the first thing to look at when a card is the wrong
  // height: `resting` is the region it settled at, `slot` is the override
  // that beat it, and `chrome` is the filter bar above the list.

  // The measured width, not the card's animated width: the tween tick on
  // `width` below is the journey and this is the destination the measuring
  // pass produced for it.

  // The resting buffer latch. This is the one number that is a measurement
  // rather than a derivation, so its transitions are where a card that
  // breathes once per keystroke is visible.

  // The latched fit, and the recovery window that lets a falling fit through
  // while refusing a rising one. Both travel together because the recovery
  // only exists to stop a rising fit from re-latching a stale row set.

  // Show gate - animations disabled until first layout settles.
  property bool shown: false
  // Escape hatch for the gate, and the answer to "why is a card I just typed
  // into teleporting instead of resizing". The gate exists so the FIRST
  // layout after an open cannot animate: the card is constructed on the
  // empty-list floor and its first real sizing arrives a turn or two later,
  // and tweening that would grow the card visibly on every summon.
  //
  // A consumer whose row set is being driven by live input re-opens the size
  // tweens for the duration, because a keystroke landing inside the gate
  // window is a real resize and not that first layout. Without it the card
  // snapped to its fitted height and the resize the user was typing towards
  // arrived as a jump. MenuPanel already carves out exactly this for its
  // own width; the shared card needs it on both axes.
  //
  // Safe to set from the input state: the open's own sizing resolves within
  // a couple of event-loop turns of the summon, so no keystroke can reach
  // the row set before that first layout has already landed.
  //
  // Consumer contract: a surface with a live filter binds this to its query
  // state (launcher: entry, pass: filterText, power: searching). The card
  // cannot derive it - a row-set change inside the gate is either the
  // opening layout or a keystroke, and only the surface holding the field
  // knows which. A filter surface that leaves this unbound snaps every
  // resize typed inside the window.
  property bool sizeMotionDuringGate: false
  // Snap switch for regime replacements (launcher app-pool <-> engine
  // answer). While true the size tweens below stand down and the card takes
  // its fitted size instantly, so a row-set replacement lands opacity-only
  // under the caller's fade instead of gliding its edge there. Default
  // false: no consumer that never sets it can observe any change.
  property bool sizeSnap: false
  Timer {
    id: showGate
    interval: Ui.resizeMs + Ui.fastMs
    onTriggered: root.shown = true
  }
  function show() {
    root.shown = false
    // The measured fit is dropped, deliberately, and against a "latch it at
    // open" reading: a fit latched at open survives the close. Five views
    // keep their card alive across open/close - `active: win.primary` in
    // PowerMenuView, ClipboardView, AppLauncherView, WallpaperPickerView and
    // pass (PassController) - so
    // this card is a warm object that outlives the surface, and _restingFitH
    // is a cache of the last row set it measured. Kept across a close, it is
    // the previous surface's size, and restingListH's fitPending branch
    // (line 319) prefers it over the model for exactly as long as the next
    // fit takes to land: the card opens at the height the last card had, then
    // corrects. That is the same defect MenuPanel has, from the same cause -
    // trajectory state outliving the presentation - and it is invisible on a
    // surface whose row set does not change size between opens.
    //
    // The recovery window goes with it. It is scoped to a slot collapsing, and
    // a slot cannot be mid-close across an open; leaving it set would make the
    // monotone ceiling refuse this open's first genuine fit if it came in
    // larger than the size being dropped.
    root._restingFitH = -1
    root._fitRecovering = false
    root.restingBufH = 0
    // contentHeight is NOT cleared: it races delegate birth at open, and the
    // max() floor in restingListH already covers the model side for it.
    showGate.restart()
  }

  // Size tweens follow the global animation switch. PanelCard is
  // menu-scoped (only MenuLib overlay panels consume it), so the policy
  // is wired here at library level like OverlayWindow.
  Behavior on width {
    enabled: MotionPolicy.enabled
      && !root.sizeSnap
      && (root.shown || root.sizeMotionDuringGate)
    Glide { duration: Ui.resizeMs }
  }

  // Height tweens too, but only over the RESTING term. A card whose row
  // set changes under it - a folder entered, a filter narrowing, a
  // delete that took the last row - snapped to its new size, which read
  // as a jump rather than a resize, and every consumer of this card
  // inherited it. An in-flow slot is the exception: when the consumer's
  // override asks for more room the region is already following the slot,
  // because the slot is animating itself, and a second tween on the sum
  // would put a lagging easing on top of the motion it is meant to
  // follow. So the tween stands down for exactly that case and the
  // height is read as it happens. The children are anchored, so they ride
  // the card and the rows are revealed as it grows.
  Behavior on height {
    enabled: MotionPolicy.enabled
      && !root.sizeSnap
      && (root.shown || root.sizeMotionDuringGate)
      && root.listRegionH <= root.restingListH + 0.5
    Glide { duration: Ui.resizeMs }
  }

  // The size tweens, per frame. Both stand down for the first layout after
  // an open and, for height, for a card whose row set is changing under it -
  // so a run of ticks is a real resize and a gap is one of those two cases.

  // Pre-layout floor: parent.width reads 0 before the first polish,
  // which would cap the width at -64 and offset the centered card for
  // a frame. Uncapped base until laid out; identical after.
  width: parent && parent.width > 64 ? Math.min(Math.max(root.contentW, root.baseWidth), parent.width - 64) : Math.max(root.contentW, root.baseWidth)
  height: root.cardHeight
  color: Ui.solid("background_0")
  radius: RoundingPolicy.radius
  border.width: Ui.cardBorder
  border.color: Ui.solid("background_3")
  clip: true
  anchors.centerIn: parent

  // Width measuring - coalesced to one pass per frame. TextMetrics, and the
  // row's own label assigned per measurement: a WIDTH is genuinely a property
  // of the string, so a probe of one fixed string is the wrong tool here too.
  TextMetrics { id: measureLabel; text: "Mg"; font.pixelSize: Ui.fontL; font.family: Ui.fontFamily }

  // Height measuring - a real Text's line box instead, which is what every row
  // delegate reads. The "Mg" probe this replaces could not stand in for a
  // row's own label on two counts: it is a different string, and it is a
  // different quantity, since TextMetrics.height is the glyph bounding box
  // while Text.implicitHeight is the laid-out line box. It answered 17.141 +
  // 1 + 13.188 = 31.328 for the label column where the real Text gives 18 + 1
  // + 14 = 33, so the estimate said 45.328 for a row that settles at 47. That
  // is 1.672px a row, 18px over a twelve-row cap, and it cut that cap's last
  // entry through the middle - the shortfall being the fractional slack the
  // delegate's own ceil(FontMetrics.height) floor rounds away, which is why it
  // only appeared at fractional scale factors.
  RowHeightProbe { id: rowProbe }
  function rowRestHeight(itm) {
    if (!itm) return Ui.rowMinH
    if (typeof root.rowHeightFn === "function") return root.rowHeightFn(itm)
    if (itm.kind === "separator" || itm.kind === "delimiter" || itm.type === "separator") return 12
    // Entry-shaped rows (clipboard/pass history) carry the second line
    // as subLeft instead of sub; both paint one sub line under the
    // title, so both count here. Without this the model underestimates
    // two-line rows as single-line (3x34+4=106 vs real 3x47+4=145) and
    // the region clips live rows.
    //
    // A negative answer is the probe saying it could not measure, not a
    // short row - the text is there, the line box is not resolved yet, or
    // the row carries no title field this vocabulary knows. It floors
    // rather than propagating, because a negative height in a row sum
    // would silently shrink every row after it; the distinction survives
    // in `rowHeightFn`, which is how a surface with a row shape this
    // vocabulary cannot read answers for itself instead of being
    // measured as empty.
    const h = rowProbe.measure(itm.label, itm.sub ?? itm.subLeft ?? "")
    return h > 0 ? h : Ui.rowMinH
  }
  function snappedListH(avail) {
    return RowMetrics.snappedH(root.rows, root.rowLimit, avail,
      root.screenMaxListH, root.rowRestHeight, root.rowSpacing)
  }
  // Summed height of a row set: complete rows plus the list's inter-row
  // gap. `maxRows` overrides the card's own cap and 0 means every row,
  // which is the uncapped total cappedBufH needs in order to weigh the
  // cap's share of it. A whole-row sum either way, so every height built
  // from this lands on a row boundary.
  function modelContentH(maxRows) {
    return RowMetrics.contentH(root.rows,
      maxRows === undefined ? root.rowLimit : maxRows,
      root.rowRestHeight, root.rowSpacing)
  }
  property bool _widthPending: false
  function recalcWidth() {
    if (root._widthPending) return
    root._widthPending = true
    Qt.callLater(() => {
      root._widthPending = false
      if (!root.rows || root.rows.length === 0) {
        root.contentW = root.baseWidth
        return
      }
      let maxRow = 0
      const limit = Math.min(root.rows.length, 200)
      for (let i = 0; i < limit; i++) {
        const it = root.rows[i]
        if (!it || !it.label) continue
        let w = Ui.m * 2 + root.outerPad * 2 + 10
        if (it.icon) w += root.rowIconW
        if (it.badge) w += root.rowBadgeW
        measureLabel.text = it.label
        w += Math.min(measureLabel.width, root._maxLabelW)
        maxRow = Math.max(maxRow, w)
      }
      root.contentW = Math.max(maxRow, root.baseWidth)
      // The coalesced measuring pass, after the coalescing: one line per
      // real pass rather than one per keystroke, carrying the row count it
      // walked and the width it arrived at. `label` is the row's own text,
      // which the pass assigned to the probe - it is shell row data, and it
      // is never anything the user typed into a field.
    })
  }
}

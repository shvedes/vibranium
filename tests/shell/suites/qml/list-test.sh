#!/bin/bash
# Suite: common/ui/List.qml - the selection state machine, the keyboard step
# functions and the scroll/velocity model, driven through a real event loop.
#
# List.qml is the component every menu, launcher, panel and island list is
# built from, so a bug in it is a bug in every list in the UI. It owns three
# machines: which index the cursor is on (currentIndex, isSelectable, wrap),
# how a step is routed (move/settle/reveal/pageBy/jumpEnd/restoreAt), and how
# the view is seated (seatTo, the measured height table, stepMs/scrollVel).
# This suite drives all three against a live Quickshell and reads the result
# back, which is the only way to reach them: the same source read that
# confirms the arithmetic also cannot see whether a step lands on a
# non-selectable row, and cannot confirm the model comes back unmutated.
#
# The probe supplies a `delegate` to every list. That is not a workaround, it
# is the contract: List.qml sets no delegate of its own, and a QQuickListView
# that never receives one never gets its model at all - count 0, currentIndex
# -1, contentHeight 0, and every selection entry point reports "nothing to
# do" with no error anywhere. Recorded as a note below, because a probe (or a
# consumer) that forgets it sees a component that looks broken and is not.
#
# What is NOT covered here, and is not claimed: rendered pixels, real key
# events from a compositor (the step functions are called directly, which is
# the routing the panels use), a user drag/flick, the selection bar's painted
# rectangle (ListView parents the highlight outside contentItem, so its
# geometry is not reachable from here - the durations that drive it are), and
# the ViewTransition add/remove choreography in flight (a transition defers
# the model change, so its mid-flight state is not deterministic to sample).

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "list" "common/ui/List.qml: selection, keyboard steps and the scroll/velocity model"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/list.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing during construction" "none" "$(qp_get probe.error)"
t_eq "and no observation in the whole run threw" "0" "$(qp_get probe.threw)"

# --- the documented defaults -------------------------------------------------

t_section "the defaults the source documents, read off a live instance"
qp_assert "a model of eight rows is seen whole" d.count 8
qp_assert "the initial cursor is row 0" d.initialIndex 0
qp_assert "and it is a real delegate, not a null placeholder" d.initialItem live
qp_assert "an empty model has no cursor" d.emptyInitialIndex -1
qp_assert "a one-row model seats row 0" d.soloInitialIndex 0
qp_assert "wrap defaults to on" d.wrap true
qp_assert "centerCursor is retained" d.centerCursor true
qp_assert "smoothScroll defaults off" d.smoothScroll false
qp_assert "scrolloff defaults to a pure centre hold" d.scrolloff 0
qp_assert "the selection bar is on" d.selectionHighlight true
qp_assert "rowMotion defaults off" d.rowMotion false
qp_assert "isSelectable is a callable predicate" d.isSelectable.isFn function
qp_assert "which accepts every index by default" d.isSelectable.default true
qp_assert "rowIdentity is a callable predicate" d.rowIdentity.isFn function
qp_assert "which is the index itself by default" d.rowIdentity.default 4
qp_assert "measureGuard accepts by default" d.measureGuard.default true
qp_assert "identityRevision starts at 0" d.identityRevision 0
qp_assert "the height table is bounded at 1024 entries" d.maxKnownH 1024
qp_assert "the instant-seat gate starts closed" d.seatsInstant false
qp_assert "the sweep override starts at -1, meaning no sweep" d.sweepMs -1
qp_assert "the sweep ceiling is 420ms" d.sweepMaxMs 420
qp_assert "the highlight handoff starts closed" d.highlightHandoff false
qp_assert "the traverse velocity floor is 6000 px/s" d.scrollVpx 6000
qp_assert "trailSpace starts at zero" d.trailSpace 0
qp_assert "nothing is being auto-revealed" d.autoRevealIndex -1
qp_assert "auto reveal is enabled" d.autoRevealEnabled true
qp_assert "pursuit seats are instant by default" d.pursuitAnimated false
qp_assert "rows are 2px apart" d.spacing 2
qp_assert "the view clips" d.clip true
qp_assert "flicking stops at the bounds" d.boundsBehavior 0
# Pinned as 1 (SnapToItem) until this. Qt implements snapping by writing
# contentY itself, which made it a second writer on the one property
# seatTo owns - and not a tween, so it landed as a step. Snap points move
# whenever a delegate resizes, so an unfolding slot re-aimed the snap every
# frame: measured live on a dropdown opening, Qt wrote 49 into a reveal
# tween running 0 -> 34, once per frame, for the whole 120ms. That was the
# jump. Nothing in this list pages or sections, so there was no snap to
# take; with it off, seatTo is the only writer and the reveal is one ease.
t_eq "snapping is off, so seatTo is the only contentY writer" "0" "$(qp_get d.snapMode)"
qp_assert "the view is non-interactive by default" d.interactive false
qp_assert "and owns no key navigation" d.keyNavigationEnabled false
qp_assert "wheel stepping is on by default" d.wheelSteps true
qp_assert "the compatibility cache gate is on" d.autoCache true
qp_assert "the bar is decoupled from contentY" d.highlightFollows false
qp_assert "a highlight component is installed" d.highlightSet true
qp_assert "a sub-threshold list instantiates everything" d.cacheBuffer.small 100000
qp_assert "at the threshold the buffer drops to 300" d.cacheBuffer.wall 300
qp_assert "the threshold is 150 rows" d.listFullRows 150
qp_assert "and the 200-row wall is past it" d.cacheThreshold true
qp_assert "the fast duration token is 120ms" d.fastMs 120
qp_assert "the slow duration token is 260ms" d.slowMs 260
qp_assert "the minimum row height is 34" d.rowMinH 34
qp_assert "the spacing unit is 8" d.s 8
t_note "List.qml sets no delegate, and a QQuickListView that has never been given one never receives its model: count, currentIndex and contentHeight all stay 0/-1 and every step function reports a no-op with no warning. Every list here supplies one, as every real consumer does."
t_note "centerCursor is documented as advisory, and setting it false changes nothing the engine does"
qp_assert "turning it off is accepted" d.centerCursor.advisory true
qp_assert "and putting it back works" d.centerCursor.restored true

# --- stepMs and scrollVel ----------------------------------------------------

t_section "stepMs(): a duration from a distance, over a short table"
qp_assert "eight 34px rows with 2px gaps is a 286px table" s.tableTotal 286
qp_assert "which is exactly the laid-out content height" s.contentHeight 286
qp_assert "in a 300px viewport nothing can scroll" s.tableMaxY 0
qp_assert "so scrollVel is still the 6000 px/s floor" s.scrollVel 6000
qp_assert "as the source says: max(scrollVpx, tableTotal * 4)" s.scrollVel.isFloor true
qp_assert "a zero distance is the fast floor, not zero" s.step.0 120
qp_assert "a sub-pixel distance is the floor too" s.step.0.4 120
qp_assert "one pixel is the floor" s.step.1 120
qp_assert "a hundred pixels is the floor" s.step.100 120
qp_assert "just under the floor distance is the floor" s.step.719 120
qp_assert "exactly the floor distance is the floor" s.step.720 120
qp_assert "at the ceiling distance it is 420" s.step.2520 420
qp_assert "and above it, still 420" s.step.2521 420
qp_assert "a distance past any table lands on the ceiling" s.step.1e6 420
qp_assert "a negative distance is the floor" s.step.negative 120
qp_assert "NaN is the floor, not a NaN duration" s.step.nan 120
qp_assert "Infinity is the floor, not a zero duration" s.step.inf 120
qp_assert "no distance produces a zero or negative duration" s.step.positive true
qp_assert "no distance exceeds the ceiling" s.step.leMax true
qp_assert "and the ceiling is exactly _sweepMaxMs" s.step.atMax true
qp_assert "stepMs never decreases as the distance grows" s.step.monotonic true
qp_assert "and it is the fast floor that floors it" s.step.floor true

t_section "scrollVel(): the table term takes over from the floor"
qp_assert "with scrollVpx 0 the 1078px table drives it" nv.scrollVel 4312
qp_assert "which is exactly tableTotal * 4" nv.scrollVel.isTableTerm true
qp_assert "a hundred pixels is still the floor there" nv.step.100 120
qp_assert "a thousand pixels is a real 232ms" nv.step.1000 232
qp_assert "five thousand pixels is on the ceiling" nv.step.5000 420
qp_assert "and nothing escapes the ceiling" nv.step.leMax true

t_section "stepMs() over a long table, where durations are not all the floor"
qp_assert "the wall holds 200 rows" w.count 200
qp_assert "which lay out to 7198px" w.contentHeight 7198
qp_assert "and the measured table agrees exactly" w.tableTotal 7198
qp_assert "leaving 7078px of scroll" w.tableMaxY 7078
qp_assert "now the table term owns the velocity" w.scrollVel.isTableTerm true
qp_assert "and it is above the 6000 floor" w.scrollVel.gtVpx true
qp_assert "zero is the floor" w.step.0 120
qp_assert "a hundred pixels is the floor" w.step.100 120
qp_assert "a thousand pixels is the floor at this speed" w.step.1000 120
qp_assert "four thousand pixels is 139ms" w.step.4000 139
qp_assert "five thousand pixels is 174ms" w.step.5000 174
qp_assert "ten thousand pixels is 347ms" w.step.10000 347
qp_assert "twenty thousand pixels is on the ceiling" w.step.20000 420
qp_assert "an absurd distance is still the ceiling" w.step.1e9 420
qp_assert "the sequence is monotone across the whole range" w.step.monotonic true
qp_assert "and it does leave the floor" w.step.aboveFloor true
qp_assert "the ceiling is _sweepMaxMs" w.step.atMax true
qp_assert "a full-length page is 246ms" w.step.fullLength 246
t_note "a real seat can never be longer than the content, and scrollVel is 4x the table height, so the longest seat a default-policy list can run is 250ms. _sweepMaxMs 420 is a guard, not a working value: reaching it needs a distance no seat can produce, or a consumer raising scrollVpx."
qp_assert "which is under 250ms" w.step.fullLength.le250 true
qp_assert "and over the fast floor" w.step.fullLength.geFloor true

t_section "the same arithmetic with no table at all: no division by a zero height"
qp_assert "an empty model has no content height" e.contentHeight 0
qp_assert "and no table" e.tableTotal 0
qp_assert "and nothing to scroll" e.tableMaxY 0
qp_assert "so the velocity is the floor again" e.scrollVel.isFloor true
qp_assert "a zero distance is the floor" e.step.0 120
qp_assert "one pixel is the floor" e.step.1 120
qp_assert "a huge distance is the ceiling, not Infinity" e.step.1e6 420
qp_assert "a negative distance is the floor" e.step.neg 120
qp_assert "nothing in that path returned a non-finite value" e.step.isFinite true
qp_assert "clampY(Infinity) is the top" e.clampY.inf 0
qp_assert "clampY(NaN) is the top too" e.clampY.nan 0
qp_assert "and so is an absurd contentY" e.clampY.big 0
qp_assert "an unmeasured row falls back to Ui.rowMinH" e.rowHeightAt0 34
qp_assert "which is the 34 the token declares" e.rowHeightAt0.isRowMinH true
qp_assert "fitHeight has nothing to measure and says so" e.fitHeight -1
qp_assert "centreTarget has no row to centre" e.centerTarget -1
qp_assert "and followTarget holds" e.followTarget -1

# --- selection ---------------------------------------------------------------

t_section "selection: a plain walk down and back up"
qp_assert "the walk starts at row 0" sd.start 0
qp_assert "down reports that it moved" sd.down1 true
qp_assert "and lands on row 1" sd.at1 1
qp_assert "again" sd.down2 true
qp_assert "on row 2" sd.at2 2
qp_assert "up reports that it moved" sd.up1 true
qp_assert "and lands back on row 1" sd.at1b 1
qp_assert "a zero step is a no-op" sd.zero false
qp_assert "and does not move the cursor" sd.atZero 1
qp_assert "a real step still works after it" sd.changed true
qp_assert "landing on row 2" sd.at3 2
qp_assert "move() answers with a boolean" sd.returnsBool true

t_section "selection: wrap:true cycles both ends"
qp_assert "the wrap:false cursor can be set to wrap" w2.wrapIsTrue true
qp_assert "at the top" w2.atTop 0
qp_assert "up wraps and reports a move" w2.up true
qp_assert "to the last row" w2.afterUp 7
qp_assert "at the end" w2.atEnd 7
qp_assert "down wraps and reports a move" w2.down true
qp_assert "back to the first row" w2.afterDown 0
qp_assert "eight steps on an eight-row list all move" w2.lapHops 8
qp_assert "and a full lap lands where it started" w2.lapLanded 3

t_section "wrap:false clamps at either end while skipping holes"
qp_assert "the list really has wrap off" c.wrapIsFalse true
qp_assert "the cursor starts at the top" c.atTop 0
qp_assert "up from the top is a no-op" c.upAtTop false
qp_assert "and remains at the first row" c.afterUpAtTop 0
qp_assert "the cursor is clamped upward" c.clampedUp true
qp_assert "it did not wrap upward" c.wrappedUp false
qp_assert "the cursor is at the end" c.atEnd 7
qp_assert "down from the end is a no-op" c.downAtEnd false
qp_assert "and remains at the last row" c.afterDownAtEnd 7
qp_assert "the cursor is clamped downward" c.clampedDown true
qp_assert "it did not wrap downward" c.wrappedDown false
qp_assert "clearing the cursor leaves it at -1" c.unseatedIndex -1
qp_assert "down from an unseated cursor lands on row 0" c.unseatedDownAt 0
qp_assert "up from an unseated cursor lands on the LAST row" c.unseatedUpAt 7
t_note "An unseated cursor enters from the end the key travels toward: Down lands on row 0 and Up on the last row, matching GridList's moveCell/moveRow behavior."

t_section "isSelectable as a predicate: the walk skips what it refuses"
qp_assert "parked on row 1, before the hole at 2" p.at1 1
qp_assert "down reports a move" p.downSkips2 true
qp_assert "and lands on row 3, past the hole" p.afterDown 3
qp_assert "up reports a move" p.upSkips2 true
qp_assert "and lands back on row 1" p.afterUp 1
qp_assert "five steps round a six-row list never reach the hole" p.lapLanded 1
qp_assert "the cursor is never on a refused index" p.neverOnHole true
qp_assert "settle(2) scans forward to the next selectable" p.settleOnHole 3
qp_assert "settle below the range clamps to the first selectable" p.settleBelowRange 0
qp_assert "settle above the range clamps to the last" p.settleAboveRange 5
qp_assert "and settle on a good index is exact" p.settleExact 0

t_section "a list where nothing is selectable: every motion is a no-op"
qp_assert "the cursor stays where it was" n.index 0
qp_assert "down moves nothing" n.down false
qp_assert "up moves nothing" n.up false
qp_assert "and the cursor has not budged" n.afterDown 0
qp_assert "jumpEnd(true) does nothing" n.afterJump 0
qp_assert "jumpEnd(false) does nothing either" n.jumpEndFirst undefined
qp_assert "and settle leaves the cursor alone" n.afterSettle 0
qp_assert "with the instant-seat flag released, not stuck on" n.seatsInstant false

t_section "jumpEnd() lands on the last SELECTABLE row, not the last row"
qp_assert "parked at the top" h.at0 0
qp_assert "jumpEnd(true) finds the last selectable" h.jumpLast.sane true
qp_assert "which is row 4, not the refused row 5" h.afterJumpLast 4
qp_assert "jumpEnd(false) goes to the first" h.jumpFirst undefined
qp_assert "row 0" h.afterJumpFirst 0
qp_assert "stepping down from row 4 moves" h.downFrom4 true
qp_assert "and wraps over the refused last row" h.afterDownFrom4 0
qp_assert "never landing on the hole" h.neverOnHole true

t_section "a one-element model: every step is a no-op"
qp_assert "the list holds one row" o.count 1
qp_assert "which is row 0" o.index 0
qp_assert "down is a no-op" o.down false
qp_assert "up is a no-op" o.up false
qp_assert "and the cursor has not moved" o.stillOnRow0 true
qp_assert "jumpEnd(true) is a no-op" o.jumpLast undefined
qp_assert "jumpEnd(false) is a no-op" o.jumpFirst undefined
qp_assert "settle(9) leaves it on row 0" o.afterSettle 0
qp_assert "and the cursor item is real" o.item live

t_section "restoreAt(): the exact cursor-plus-offset seat"
qp_assert "the cursor lands on the requested index" r.index 9
qp_assert "and the offset exactly" r.y 300
qp_assert "not approximately" r.exactY true
qp_assert "the restore-sweep window is open" r.sweeping true
qp_assert "and the instant-seat flag is armed with it" r.seatsInstant true
qp_assert "with no sweep armed, because the seat is instant" r.sweepMs -1
qp_assert "_endSweep() closes the window" r.sweepingAfterEnd false
qp_assert "and releases the instant-seat flag" r.seatsAfterEnd false
qp_assert "an index past the end clamps to the last row" r.clampedHigh 29
qp_assert "an index below zero clamps to the first" r.clampedLow 0
qp_assert "taking the offset with it" r.lowY 0
qp_assert "a non-selectable index scans forward" r.scanPastHole 3

qp_assert "restoreAt(4) leaves an all-refused list unseated" r.allBadIndex -1
qp_assert "so it does not land on a refused row" r.allBadLandsOnHole false
qp_assert "and the cursor remains safely unseated" r.allBadNotUndone false

# --- the empty model ---------------------------------------------------------

t_section "the empty model, through every public entry point: nothing throws"
qp_assert "no rows" x.count 0
qp_assert "no cursor" x.index -1
qp_assert "and no cursor item" x.item null
qp_assert "down is false" x.moveDown false
qp_assert "up is false" x.moveUp false
qp_assert "a zero step is false" x.moveZero false
qp_assert "settle leaves the cursor at -1" x.settleIndex -1
qp_assert "and releases the instant-seat flag rather than leaving it armed" x.settleUnarmsSeats true
qp_assert "reveal cannot move the view" x.revealY 0
qp_assert "revealEnd claims nothing" x.revealEndIndex -1
qp_assert "jumpEnd(true) is a no-op" x.jumpLast undefined
qp_assert "jumpEnd(false) is a no-op" x.jumpFirst undefined
qp_assert "restoreAt returns before writing anything" x.restoreIndex -1
qp_assert "and leaves the restore window shut" x.restoreSweeping false
qp_assert "pageBy cannot move the view" x.pageY 0
qp_assert "seatTo clamps to the top" x.seatTo 0
qp_assert "trackCursor is a no-op" x.trackCursor 0
qp_assert "followCursor is a no-op" x.followCursor 0
qp_assert "learnLive learns nothing" x.knownH '{}'
qp_assert "and reports no identity error" x.identityError ''
qp_assert "row 0 is still at the top" x.rowTop 0
qp_assert "and reveal(0) cannot move it" x.reveal0 0

# --- model replacement -------------------------------------------------------

t_section "the model is replaced, emptied and shrunk under a live cursor"
qp_assert "the cursor was on row 5" ms.beforeIndex 5
qp_assert "with the table measured" ms.beforeKnownH 8
qp_assert "replacing it with nine rows is seen whole" ms.afterCount 9
qp_assert "the cursor is re-seated onto the new set" ms.afterIndex 0
qp_assert "the height table is dropped with the old rows" ms.knownHCleared '{}'
qp_assert "the sum goes to zero" ms.sumHCleared 0
qp_assert "the entry count goes to zero" ms.countHCleared 0
qp_assert "and the average goes back to 'nothing known'" ms.avgHCleared -1
qp_assert "the new table is measured from the new layout" ms.tableTotalAfter 322
qp_assert "shrinking to six rows with the cursor on row 8" ms.at8 8
qp_assert "the model is six rows now" ms.shrunkCount 6
qp_assert "the cursor is inside the new range" ms.inRange true
qp_assert "stepping still works" ms.moveAfterShrink true
qp_assert "and stays inside the range" ms.inRangeAfterMove true
qp_assert "jumpEnd(true) reaches the new last row" ms.jumpEndAfterShrink 5
qp_assert "the table follows the shrink" ms.shrunkTableTotal 214
qp_assert "and there is nothing left to scroll" ms.shrunkClamp 0
qp_assert "so the view is at the top" ms.shrunkContentY 0
qp_assert "emptying the model empties the view" ms.emptyCount 0
qp_assert "with no cursor" ms.emptyIndex -1
qp_assert "and no step to take" ms.emptyMove false
qp_assert "and no table" ms.emptyTableTotal 0
qp_assert "and no scroll range" ms.emptyClamp 0

# --- the scroll model --------------------------------------------------------

t_section "pageBy(): a viewport-sized step, clamped to real bounds"
qp_assert "the wall starts at the top" sm.startY 0
qp_assert "one page is one viewport" sm.page1Y 120
qp_assert "which is what the source says" sm.page1Expected 120
qp_assert "two pages" sm.page2Y 240
qp_assert "are two viewports" sm.page2Expected 240
qp_assert "a half page is a half viewport" sm.pageHalfY 300
qp_assert "a zero page moves nothing" sm.pageZeroY 300
qp_assert "an absurd page lands on the real bound" sm.pageFarY 7078
qp_assert "which is the bound itself" sm.pageFarAtBound true
qp_assert "stepping back past the top stops at the top" sm.pageBackY 0
qp_assert "exactly" sm.pageBackAtTop true

t_section "a contentY written behind seatTo's back is reconciled, not trusted"
qp_assert "an absurd contentY is pulled back to the bound" sm.reconcileHigh 7078
qp_assert "a negative one is pulled back to the top" sm.reconcileLow 0
qp_assert "exactly" sm.reconciledToBound true

t_section "trailSpace scrolls with the content instead of padding the viewport"
qp_assert "40px of trail makes the table 1118px" sm.trailTableTotal 1118
qp_assert "and the laid-out content height agrees" sm.trailContentHeight 1118
qp_assert "so the scroll bound is 998" sm.trailMaxY 998
qp_assert "row 0 has not moved" sm.trailRowTop0 0
qp_assert "clampY agrees" sm.trailClamp 998
qp_assert "a matched list without trail space is 1078px" sm.twinTableTotal 1078
qp_assert "and scrolls 958" sm.twinMaxY 958
qp_assert "so the trail adds exactly its own 40px to the bound" sm.trailDelta 40
qp_assert "the bound really is wider" sm.trailAddsBound true
qp_assert "and it did not move the rows themselves" sm.trailRowTopSame true

# --- scrolloff ---------------------------------------------------------------

t_section "scrolloff holds the view inside a margin band around the centre"
qp_assert "scrolloff is 2 rows" so.scrolloff 2
qp_assert "on a 400px viewport" so.height 400
qp_assert "holding 30 rows" so.count 30
qp_assert "with 678px of scroll available" so.tableMaxY 678
qp_assert "the view starts at the top" so.y0 0
qp_assert "row 2 is inside the margin, so the follow target is a hold" so.heldAt2 true
qp_assert "and row 1 is not, so it gets a real target" so.followTarget1 0
t_note "the hold lives in followTarget (-1), not centerTarget: centerTarget(2) is a real 0 here. followTarget returning -1 is the signal every caller uses for 'no seat coming'."
qp_assert "stepping to row 1 moves" so.at1 1
qp_assert "stepping to row 2 moves" so.at2 2
qp_assert "but the view has not moved at all" so.y2 0
qp_assert "which is the whole point of the margin" so.heldView true
qp_assert "a held row takes no claim of its own" so.heldNoClaim true
qp_assert "stepping out to row 10 still moves the cursor" so.at10 10
qp_assert "and now the view glides" so.glided true
qp_assert "to 141px" so.y10 141
qp_assert "with scrolloff 0 the same row is a plain centre follow" so.zeroScrolloffFollow 317

# --- the snapping land --------------------------------------------------------

t_section "a snapping land places the row it names, a turn after the seat"
t_note "The seat writes the index and nothing else: the row is placed by the follow, which is deferred a turn so that it reads the healed geometry. A land whose follow never runs leaves the row wherever the view happened to be - in a list this shape, off screen - and the caller that asked for the row to be placed gets nothing."
qp_assert "the cursor lands on the row" ls.idx 10
qp_assert "the seat itself moves no view" ls.yAtSeat 0
qp_assert "the centre is where the follow puts it" ls.want 317
qp_assert "and a turn later the view is there" ls.yAfterFollow 317
qp_assert "so the row was placed" ls.placed true
qp_assert "and it is the centre the policy names" ls.centred true
qp_assert "with the claim on the row that was followed" ls.followIdx 10

t_section "a land inside a swap window leaves the view to the window"
t_note "The swap window owns the view in its own time: the hold it arms re-asserts the offset the model change left behind, and a follow inside the window would fight it. The launcher settles inside a swap for exactly this reason - the row it names is placed by the install, not by a follow."
qp_assert "the cursor lands on the row" ls.swapIdx 20
qp_assert "the view is where the window found it" ls.swapYBefore 317
qp_assert "and the seat moved nothing" ls.swapYAtSeat 317
qp_assert "a turn later it is still there" ls.swapYAfter 317
qp_assert "so nothing followed the row" ls.swapHeld true

t_section "a placement can name the viewport it is growing to"
t_note "The centre of a viewport that is still growing to a height is the centre of a viewport that no longer exists, and a placement outside the range the viewport will have is corrected by the engine as it grows - a visible drag of the content. A consumer that knows the height its viewport is growing to says so, and the placement names the centre of the viewport the row is going to be in."
qp_assert "the centre is the one of that viewport" ls.hintCentre 177
qp_assert "and not the one of the viewport in hand" ls.plainCentre 317
qp_assert "the bound is the range that viewport will have" ls.hintBound 678

# --- the seat writer ---------------------------------------------------------

t_section "seatTo(): the single contentY writer, and what it owns"
qp_assert "the epoch has been bumped by earlier seats" st.epochAdvanced true
qp_assert "a seat to 200 lands there" st.seatY 200
qp_assert "a seat past the end clamps to the bound" st.clampedSeat true
qp_assert "a NaN target degenerates to the top" st.nanSeat 0
qp_assert "an infinite target clamps to the bound" st.infSeat true
qp_assert "a follow claims the tween it started" st.followIdx 4
qp_assert "and clears any pursuit claim" st.pursuitIdxAfterFollow -1
qp_assert "a page seat takes the follow claim away" st.followIdxAfterPage -1
qp_assert "a seat that really moves clears every claim" st.claimAfterMovingSeat "-1,-1"
qp_assert "a seat that does not move leaves both claims standing" st.claimAfterNoopSeat "4,4"
t_note "LOW: seatTo() returns at List.qml:507 when the target is already the view position, which is BEFORE the ownership reset at List.qml:515-516. So a no-op seat leaves a stale _followIdx/_pursuitIdx armed. pursue() reads exactly those claims (List.qml:913) to decide whether a running tween is its own, so a claim left behind by a no-op seat can let a pursuit re-aim a tween it does not own. _seatEpoch is still bumped, which is the part the deferred retries guard on."
qp_assert "and the epoch was still bumped" st.noopSeatEpoch 19

t_section "seat(): one entry where an index write meets the highlight policy"
qp_assert "seat() is a callable entry" st.seatFn true
qp_assert "a land seat holds the gate" st.seatLandHolds true
qp_assert "on a live lease token" st.seatLandLease true
qp_assert "a step seat pre-empts the hold" st.seatStepPreempts true
qp_assert "a step seat retires the token" st.seatStepLease true
qp_assert "a click seat pre-empts the hold" st.seatClickPreempts true
qp_assert "a click seat retires the token" st.seatClickLease true
qp_assert "clearing to -1 takes no lease" st.seatClearNoLease true

t_section "a pinned bar origin survives the cursor moving under it"
qp_assert "pinHighlight() is a callable entry" bp.pinArms true
qp_assert "the pin stands" bp.pinned true
qp_assert "and the origin is the cursor row's geometry" bp.originIsCursorRow true
qp_assert "the swap's echo moves the cursor to the top row" bp.echoIsTopRow true
qp_assert "the pin stands through it" bp.pinSurvivesEcho true
t_note "THIS is the assertion the fix rests on. A model reset deals the view an index adjustment a frame after the swap window closes, so between a repair seat and the commit that confirms it the cursor is wherever the view echoed to. An unpinned bar follows the cursor there and then travels the whole list back to the repaired row - the lap the tail delete used to make. A pinned hold outranks live geometry, so the echo cannot become the origin the next motion starts from."
qp_assert "and the origin is still the row it was armed on" bp.originSurvivesEcho true
qp_assert "a second pin keeps the origin it was armed with" bp.secondPinKeeps true
qp_assert "unpinning drops it" bp.unpinDrops true
qp_assert "a gesture takes the bar back from a pinned origin" bp.userSeatDropsPin true
qp_assert "a landing seat does not: the repair seat is inside the window" bp.landKeepsPin true
qp_assert "with no cursor row there is nothing to pin" bp.pinWithoutCursor true
qp_assert "and no path leaves the pin standing" bp.endsUnpinned true
qp_assert "a pin re-arms on a fresh row" bp.pinArmsAgain true
qp_assert "a hold dropped while pinned is gone" bp.holdDropped true
qp_assert "so a re-pin takes it again" bp.repinTakesHold true
qp_assert "and the pin is armed on real geometry" bp.repinArms true

t_section "the cursor-keep arm: a gesture is not swallowed, and the bar keeps its width"
t_note "The arm exists so a model change can be answered by putting the cursor back on the row it took from. It is spent by the first index change after the write - and a projection that keeps the row under the cursor at the same index moves NO index at all, so the model never spends it. That is the menu's search projection: the rows it installs keep the uids of the rows they replace, so the cursor stays where it was and the arm outlives the change it was armed for. Two things follow, and both are asserted here. The bar stands on the width the card had when the arm was taken, so a card that grew under the pin shows its selection short of the row it is on. And the restore the arm triggers answers the user's own cursor move by putting the cursor back where it was - so the first key step is swallowed and the second one lands."
qp_assert "the arm is armed" ka.armed true
qp_assert "the projection left the cursor on its row" ka.indexAfterWrite 0
qp_assert "so the arm is still standing" ka.armAfterWrite true
qp_assert "the held width is the width the card had" ka.heldW 300
qp_assert "the live row is as wide as the card now" ka.liveW 316
qp_assert "and the bar is as wide as the live row, not as wide as the held width" ka.barW 316
t_note "The width is the list's width - every row in a list is as wide as the list - so the live row answers it and the held copy is only the stand-in for the window where no row is there to read. A pin holds the ORIGIN of a motion, not the size of the bar."
qp_assert "the first step reports a move" ka.moved true
qp_assert "and the cursor is on the next row" ka.indexAfterMove 1
t_note "A gesture ends the arm rather than feeding it: the restore exists to undo the cursor adjustment a MODEL change deals the view, and a gesture is a newer intent than an arm that outlived its model change."
qp_assert "the arm is spent" ka.armAfterMove false
qp_assert "and the pin with it" ka.pinAfterMove false
qp_assert "the bar is still the live width" ka.barWAfterMove 316

t_section "a swap hands back the scroll the model write dropped"
t_note "This is the whole-list jump. Replacing the model with a DIFFERENT length releases the delegates, and the view drops the offset to the top and puts it back a frame later - so the first entry is painted for a frame before the list snaps down to where it was. A same-length replacement keeps the offset on its own; the shortening cases below are the ones that need the swap to hand it back, and every read is in the turn the swap returned in, because a frame is all it takes for the lap to be seen."
qp_assert "the fixture is parked away from the top" ss.parked true
qp_assert "a same-length replacement keeps the offset" ss.sameLengthKept true
qp_assert "shorter content clamps onto the new bottom" ss.shorterIsBottom true
qp_assert "and never back to the top" ss.shorterNotTop true
qp_assert "a consumer seat inside the window wins over the restore" ss.consumerSeatWins true

t_section "a tail swap walks the view to the healed bottom, not to the transient one"
t_note "THE list jump, sampled over the turns after the write. A model write destroys the delegates that were giving the content its extent, and the replacements report their floor until their payload lays out, so every bound taken in the write's own turn is short and Qt enforces the same short bound on contentY. A removal at the END of the model then leaves the view parked where the half-built content put it - short of the healed bottom by the row that is still coming - and the heal cannot walk it back, because the healed bound only ever admits what is already there. Whatever seats next (a reveal, a pursuit, a commit repair) then glides it the rest of the way, and the user watches the list leave and come back. The fixture's rows are born at their floor on purpose: with settled rows the swap heals inside its own turn and there is nothing here to survive."
qp_assert "the fixture is parked at its bottom before the swap" st.before 406
qp_assert "which is twelve 44px rows less the 120px viewport" st.beforeHeight 526
qp_assert "the write turn bounds the view by the half-built content" st.writeHeight 394
qp_assert "which is what parked it short of where the content is going" st.writeY 274
qp_assert "and the swap armed a hold to keep re-asserting the offset" st.writeHold true
qp_assert "with its watch running, which is what the hold is" st.writeWatch true
t_note "The assertion the fix rests on: the heal is the last chance the swap has to put the view where the healed content puts it. Read at any later turn it would only prove that a later writer corrected the view, which is the defect."
qp_assert "and the view was on the healed bottom from the heal onward" st.settledAtHeal true
qp_assert "which is where it stays" st.atBottom true
qp_assert "the healed bottom is the pre-delete offset less exactly one row" st.bottom 362
qp_assert "the hold released itself without another writer" st.holdRetired true
qp_assert "and its watch stopped with it, rather than waking once a frame forever" st.watchStopped true
qp_assert "with the view still on the healed bottom a turn later" st.stillAtBottom true
qp_assert "the view never passed above the offset it was captured at" st.neverHigh true

t_section "a hold yields to the next writer, in the turn it happens"
t_note "The hold is not an override. Every seat that moves the view is a claim about where the view belongs - a wheel step, the scrollbar, a consumer's own repair - and re-asserting over one would stop the very tween that seat started. Yielding a tick later is still a fight, so it has to happen inside the contentY change the seat made."
qp_assert "the swap armed a hold again" sy.armed true
qp_assert "a consumer seat released it at once" sy.released true
qp_assert "and took the watch down with it" sy.watchStopped true
qp_assert "with the view on the consumer's own position" sy.kept 120

t_section "a land seat holds across turns until the wall floor elapses"
qp_assert "arming takes the lease" lh.leaseArmed true
qp_assert "and zeroes durations" lh.durZero true
qp_assert "several turns later the hold is still on" lh.leaseHeld true
qp_assert "with durations still zero" lh.durStillZero true

t_section "a held bar keeps its place on the SCREEN when the content moves under it"
t_note "The hold is about where the user last saw the bar, and the screen is where they saw it. A hold that remembered the row's place in the CONTENT dragged the bar along with the content whenever a swap moved the content under it - and the tail delete moves it: the content loses its last row and the view rides the freed space down, which left the bar a whole row BELOW the place the user left it, off the bottom edge of the list, from where it flew back in."
qp_assert "the fixture is parked away from the top" hs.parked true
qp_assert "the cursor's row is a live delegate" hs.live true
qp_assert "the bar has a place on the screen" hs.barAt 86
qp_assert "the hold took it" hs.pinned true
qp_assert "and the geometry is held" hs.held true
qp_assert "the view really moved" hs.scrolled 918
qp_assert "the bar is still where the user left it" hs.barAfter 86
qp_assert "which is the whole point" hs.barHeld true

t_section "a tail settle holds the freed space through the write and gives it back over the motion budget"
t_note "A removal at the END of the content is the one change the view cannot absorb for free: the content loses exactly the space the view was resting on, so the bound comes down by a whole row and the view is corrected in one step - the list jumps a row, and the highlight bar goes with it. The settle holds that space through the write, so the content's extent does not change at all, and gives it back over the motion budget, so the content shrinks by exactly that much while the view rides it down."
qp_assert "the content is a wall the view can stand at the bottom of" sl.beforeHeight 1078
qp_assert "and the view is on its bottom" sl.beforeY 958
qp_assert "with the bar on the last row" sl.beforeBar 86
qp_assert "the bar is pinned to that place" sl.pinned true
qp_assert "the settle took the space" sl.claimed true
qp_assert "and reports that it is standing" sl.settling true
qp_assert "the content's extent grew by exactly the space that was held" sl.claimHeight 1122
qp_assert "so the view did not move either" sl.claimY 958
qp_assert "and the bar did not move" sl.claimBar 86
qp_assert "the space goes back" sl.releasing true
qp_assert "the content shrank by exactly the space that was held" sl.endHeight 1078
qp_assert "the view rode it down to the new bottom" sl.endY 958
qp_assert "and stands on the bound" sl.atBottom true
qp_assert "the bar never moved" sl.endBar 86
qp_assert "which is the whole point" sl.barHeld true
qp_assert "the settle released itself" sl.settled true
qp_assert "and the pin with it" sl.pinReleased true

t_section "rowTop and centerTarget: the pure geometry behind every seat"
qp_assert "row 0 is 0 by construction" st.rowTop0 0
qp_assert "row 5 is five measured rows plus five gaps" st.rowTop5 180
qp_assert "which is the source formula" st.rowTopExpected 180
qp_assert "a negative index is 0, never extrapolated backwards" st.rowTopNegative 0
qp_assert "an index past the model extrapolates from the table" st.rowTopBeyondCount 7200
qp_assert "so a row about to arrive can still be placed" st.rowTopBeyondExpected 7200
qp_assert "centerTarget(4) is the row's centre minus half the viewport" st.centerTarget4 101
qp_assert "which the source formula confirms" st.centerTargetFormula 101
qp_assert "an index past the model has no centre" st.centerTargetOutOfRange -1
qp_assert "nor does a negative one" st.centerTargetNegative -1
qp_assert "and followTarget agrees on both" st.followTargetOutOfRange -1

# --- reveal and pursuit ------------------------------------------------------

t_section "reveal() brings a row into view without moving the cursor"
qp_assert "an out-of-range index is refused" pu.revealOutOfRange 0
qp_assert "and a negative one claims nothing" pu.revealNegative -1
qp_assert "reveal(20) bottom-aligns it" pu.reveal20Y 634
qp_assert "at exactly the row's bottom edge minus the viewport" pu.reveal20Expected 634
qp_assert "the snap takes no landing lease" pu.revealArmsSeats false
qp_assert "and leaves the cursor where it was" pu.revealKeepsCursor 0
qp_assert "revealEnd claims the last row" pu.revealEndIndex 25
# The claim is the row's DESTINATION in content coordinates, which is all the
# library publishes: the shortfall and the grow-vs-scroll decision are both
# comparisons against a height the consumer owns, and the consumer sizes its
# region from this number - so asking in the library would close a loop
# through the height.
qp_assert "the claim is the row's destination, in content coordinates" pu.revealEndClaim 934
qp_assert "which is exactly the row's bottom edge" pu.revealEndClaimFormula 934
qp_assert "a seat that satisfies it overshoots by the reveal margin" pu.claimOvershoot 8
qp_assert "so the row is revealed with the margin inside the viewport" pu.rowRevealed true

t_section "a tall row SHARES the reveal: the list scrolls, the region grows"
qp_assert "a region's target sized for the scroll in force" pu.splitTarget 42
qp_assert "is smaller than one sized for the whole shortfall" pu.splitIsSmaller true
qp_assert "and the whole shortfall is 192px" pu.shortBy 192
qp_assert "a region still in flight is not carrying the claim" pu.regionEnRoute true
qp_assert "so the list seats its share while it travels" pu.seatedDuringGrowth 900
qp_assert "up from where it was" pu.seatedUp true
t_note "The two motions used to be exclusive by accident rather than by decision: a row that FITS grew not at all and the list scrolled it, a row that does not fit grew by the entire deficit and the list stood still. A row taller than the region on a short page is the case in between and it got the second half - the entries above stayed fully visible while the window grew past its own bottom border to carry a dropdown that had scroll available. The region's target is now sized against where the content WILL sit (the row's top, 900 here) so it asks for 42 rather than 320, and the list takes the 858 in between. Both numbers come from settled geometry, so neither moves while the unfold runs."

t_section "a region that has landed and is still short does not silence the list"
qp_assert "50px short with the region on its own target" pu.landedStillShort 50
qp_assert "so the list still moves" pu.landedSeatedTo 900
qp_assert "and it is not left where it was" pu.landedMovedOn true
t_note "This is the clipped dropdown, and it was the landed test's own doing: _regionOwnsReveal answers 'the reveal is the region's, not mine', and the comparison was written the other way round, so it silenced the pursuit precisely when the region was short of the claim. Invisible while the region was sized for the current scroll (the two always compared equal), and a stall the moment it was sized for a different one."

t_section "a claim the region already covers is a scroll, and only a scroll"
qp_assert "a region sized for the scroll in force satisfies the claim" pu.claimSatisfiedBy true
qp_assert "and the list does not move for it" pu.stillHeld 900
qp_assert "not by a pixel" pu.stillHeldIsLanded true
qp_assert "with no region claiming it, the list seats on its own" pu.seatWhenUnclaimed true
t_note "A row with content below it claims nothing past the region"
qp_assert "a row with content below it claims nothing past the region" pu.wallClaim -1
qp_assert "and the claim lands inside the viewport it has" pu.wallNeedBelowViewH true
qp_assert "so the seat is the reveal, to the row's bottom edge" pu.wallSeatedY 7078
qp_assert "7078 against the 7086 the same formula gives" pu.wallSeatedExpected 7086
qp_assert "with no claim at all, nothing is pending" pu.rowRevealedIdle true
qp_assert "pursuit seats are instant" pu.pursuitAnimated false
qp_assert "so no tween is left claimed" pu.followIdxIdle -1
qp_assert "on either count" pu.pursuitIdxIdle -1
t_note "reveal(index, snap) is scroll-only: it seats no cursor and takes no landing lease, so the gate reads false right after a snap reveal with no land seat holding it. sw.revealUnarmedNextTurn pins that read."
qp_assert "the next turn has released it" sw.revealUnarmedNextTurn true

# --- revealNeedH: who reveals a claim -------------------------------------
#
# The one number a surface reads to decide whether its region has to grow.
# Two lists, same slot-shaped delegate: one whose content already fits (so
# there is nothing to scroll and only a taller region can reveal the claim)
# and one with rows below the claim (so scrolling covers it and the region
# must not move at all).
t_section "revealNeedH: the claim, and who acts on it"
qp_assert "on a list with rows below, the scroll room covers the shortfall" gc.wallRoomCovers true
qp_assert "the claim is the row's destination all the same" gc.wallNeed 330
t_note "The library cannot answer grow-vs-scroll: that is a comparison against the height a consumer is showing, and the consumer sizes its region FROM this number, so asking here would close a loop through the height - the live shell logged 70,000 binding loops before the claim was made pure content-space geometry. The claim is the row's destination and nothing else; the consumer's own comparison is what holds the card still."
qp_assert "which is the row's top plus its 150px slot" gc.wallNeedRelative 150
qp_assert "and 64px inside the 214px viewport it already has" gc.wallShortBy -64
qp_assert "so the card does not move a pixel for it" gc.wallHeightUnchanged 214
qp_assert "with no claim at all the value is also -1" gc.noClaimNeed -1

t_section "the last row with a tall slot: the region and the list SHARE it"
qp_assert "the last row's destination is 224px past the region" gc.destinationShortfall 224
qp_assert "and the 216px the slot itself added cannot cover it" gc.room 216
qp_assert "so the region has to carry part of it" gc.roomCannotCover true
t_note "the shortfall counts the reveal margin and the room does not need to: scrolling can only put a last row's dropdown flush against the bottom edge, and the margin term is what says no."
qp_assert "at rest the claim is already the destination" gc.needAtRest 574
qp_assert "which is the row's bottom edge" gc.needAtRestFormula 574
qp_assert "and it exceeds the resting region" gc.aboveResting true
qp_assert "mid-unfold the claim has not moved" gc.claimConstantWhileUnfolding true
qp_assert "it is the same 574 it was at rest" gc.claimAtRest 574
t_note "Constancy is the contract, not an optimisation. A claim that tracked the row's LIVE height would have to be chased every frame, and it would vanish on the first tick of a close (the settled height drops to zero the moment a slot shuts) - so the region would have no collapse target at all and would snap shut."
qp_assert "the region asks for the claim less the row's own top" gc.splitTarget 258
qp_assert "which is the same number read the other way" gc.splitTargetFormula 258
qp_assert "against 366 for the whole deficit" gc.wholeDeficit 366
qp_assert "so the split is the smaller ask" gc.splitIsSmaller true
qp_assert "and the list takes the rest" gc.listSeat 316
qp_assert "the pair satisfies the claim" gc.pairSatisfies true
qp_assert "with the region's edge exactly on the destination" gc.noGapUnderDropdown true
t_note "The two motions used to be exclusive by accident rather than by decision: a row that FITS grew not at all and the list scrolled it, a row that does not fit grew by the entire deficit and the list stood still. This row is the case in between and it got the second half - 366px of window for a dropdown the list could have carried 108px of, with the entries above it left fully visible. The region's target is now sized against where the content WILL sit (the row's top, 324) so it asks for 258, and the list seats to 316 - which is the bound, because a last row's dropdown can be brought flush against the region's bottom edge but never a margin clear of it, at any region size. Both numbers come from settled geometry, so neither moves while the unfold runs."

t_section "the crossover: the margin on both sides, or the bounce"
t_note "A region sized to the BARE claim puts the row's settled bottom EXACTLY on the region's edge, and the list reveals by bottom + Ui.s - so it still read that row as owed a margin-sized seat, took it, and that seat moved the scroll offset the region's own arithmetic reads. The region retargeted, the card grew back, the list seated again: two writers, one number, no arbitration. It showed up on the live shell as a card bouncing on some opens and not others, because which way it went turned on which side of a half-pixel the arithmetic fell. The fix is one expression with the margin on both sides."
qp_assert "a region sized to the bare claim owes this list 8px" gc.bareTargetOwes 8
qp_assert "and the list takes them" gc.bareTargetSeats 324
qp_assert "a region on the margin target owes it nothing" gc.seatAfterLanding 316
qp_assert "which is the claim being satisfied, not merely covered" gc.nothingOwed true
qp_assert "a region that has not arrived yet owes the list everything" gc.shortRegionOwes 90
qp_assert "and the list still seats" gc.shortRegionStillSeats 324
qp_assert "with no region claiming it, the list owns the reveal outright" gc.seatAloneMoved true
qp_assert "and seats on its own" gc.seatAlone 200
qp_assert "fully out, the claim is the whole destination" gc.needFull 574
qp_assert "which is still exactly the bottom edge" gc.fullIsBottomEdge true
t_note "Growth and scroll are two answers to one question, and the question is answered from settled geometry, so a surface applies the claim and the pursuit reads the same answer to stay quiet: one motion, chosen once per unfold."

t_section "revealSlotMs: the duration a surface animates a slot-driven resize over"
qp_assert "a live claim publishes the row's own slot duration" gc.slotMsOpen 167
qp_assert "closing the claim releases it" gc.claimAfterClose -1
qp_assert "and the duration returns to 'not a slot'" gc.slotMsIdle 0
t_note "This is what makes the collapse animate at all, and at the slot's own speed rather than a fixed one. The row publishes it, so a claim on a row the cursor has since left is still timed correctly."

# --- the sweep ---------------------------------------------------------------

t_section "the sweep: the documented defaults and the ceiling"
qp_assert "_sweepMs defaults to -1" sw.defaultOff -1
qp_assert "which is the source's 'off' sentinel" sw.defaultMeansNoSweep true
qp_assert "the highlight handoff starts closed" sw.handoffDefault false
qp_assert "a land settle holds the instant-seat gate" sw.seatsDefault true
qp_assert "on a live stillness lease" sw.seatsLeaseHeld true
qp_assert "and the ceiling is 420" sw.max 420
qp_assert "a duration request opens the handoff window" sw.handoffArmed true
qp_assert "a 5ms request is floored to 120" sw.sweepTiny 120
qp_assert "which is Ui.fastMs" sw.sweepTinyAtFloor true
qp_assert "a 100s request is capped to 260" sw.sweepHuge 260
qp_assert "which is Ui.slowMs" sw.sweepHugeAtCeiling true
qp_assert "and it is inside the sweep ceiling" sw.sweepWithinMax true
qp_assert "a zero request opens no window" sw.noHandoffAtZero false
qp_assert "and leaves no sweep armed" sw.releasedAfterSeat -1

t_section "a sweep is never longer than _sweepMaxMs, checked on the engine's own writes"
t_note "an armed _sweepMs only exists on the animated seat path or while a handoff is open: with the default instant seat, seatTo (List.qml:531) clears the pre-arm in the same turn, and on a 200-row wall the cursor's delegate is usually not instantiated yet so no seat starts inside move() at all. The traversal below is therefore on a 30-row list with smoothScroll on, where every step really seats."
qp_assert "fourteen steps and end jumps were traced" sw.traversalSteps 14
qp_assert "thirteen of them armed a real sweep" sw.traversalArmed 13
qp_assert "so armed sweeps do exist" sw.traversalHadSweeps true
qp_assert "the longest is 160ms" sw.traversalMax 160
qp_assert "the shortest is the 120ms floor" sw.traversalMin 120
qp_assert "and nothing exceeded the 420ms ceiling" sw.traversalLeMax true
qp_assert "nor fell under the floor" sw.traversalGeFloor true
qp_assert "so a sweep does vary with distance" sw.traversalAboveFloor true
qp_assert "a one-row step is 120ms" sw.stepShort 120
qp_assert "and a full-length jump is 160ms" sw.stepEndJump 160
qp_assert "the armed sweep is still running one turn later" sw.sweepStillArmed true
qp_assert "the highlight duration reads the armed sweep" sw.durationFromSweep 250
qp_assert "a cleared sweep falls back to the default glide" sw.durationAfterClear true
t_note "with smoothScroll off - the default - the highlight's move duration is only ever 0 or Ui.fastMs, because the instant seat path clears the sweep. A consumer that wants bar and content to land together has to turn smoothScroll on; the two gates are independent properties and nothing forces that pairing."

# --- motion gating -----------------------------------------------------------

t_section "motion gating: the gate decides the duration, and only the duration"
qp_assert "highlightMotion IS the global gate" mg.highlightMotion.isGate true
qp_assert "rowMotion defaults off, unlike the highlight" mg.rowMotionDefault false
qp_assert "the move duration follows the gate exactly" mg.duration.matchesGate true
qp_assert "turning the gate off is accepted" mg.gateOff false
qp_assert "and the duration goes to zero" mg.durationGateOff 0
qp_assert "not to the floor and not negative" mg.gateOffIsZero true
qp_assert "forcing it on is accepted too" mg.gateForcedOn true
qp_assert "and then the duration follows the global gate, not the local one" mg.durationForcedOn true
qp_assert "restoring it" mg.gateRestored true
qp_assert "switching the bar off uninstalls the highlight" mg.highlightCleared true
qp_assert "and zeroes the duration" mg.durationNoBar 0
qp_assert "switching it back on reinstalls it" mg.highlightRestored true
t_note "a motion gate never blocks a value, only its motion: with the gate off the duration is exactly 0, so the value still lands - which is the contract MotionPolicy documents. The suite asserts the 0 rather than a fallback duration, because a fallback is what a broken gate would look like."

t_section "an in-flight slot owns the bar's height but not its position"
qp_assert "a delegate reporting slotMotionMs is read through" mg.slotMs 200
qp_assert "the resize duration is zeroed while it is" mg.slotResizeDuration 0
qp_assert "the move duration is not" mg.slotMoveDuration 120
qp_assert "so the two durations are separate gates" mg.slotsAreSeparate true
qp_assert "a delegate without the property reports 0" mg.plainSlotMs 0
qp_assert "and its resize duration is the normal one" mg.plainResizeDuration 120

t_section "rowMotion gates all four row-set transitions and nothing else"
qp_assert "the add transition is off" mg.addEnabled false
qp_assert "the remove transition is off" mg.removeEnabled false
qp_assert "the add-displaced transition is off" mg.addDisplacedEnabled false
qp_assert "the remove-displaced transition is off" mg.removeDisplacedEnabled false
qp_assert "and each one reads rowMotion" mg.addEnabled.isRowMotion true
qp_assert "turning rowMotion on enables the add transition" mg.addEnabledAfter true
qp_assert "and the remove transition" mg.removeEnabledAfter true
qp_assert "turning it off again disables them" mg.addEnabledRestored false

# --- the animation, sampled in flight ---------------------------------------

t_section "a real content tween, sampled in flight"
t_note "this is the assertion a source read cannot make. seatTo starts a NumberAnimation on contentY with a distance-derived duration; if the duration were a constant, or the animation were not wired, the first sample would already equal the last."
qp_assert "the seat starts from the top" an.y0 0
qp_assert "five steps put the cursor on row 5" an.index5 5
qp_assert "whose centre seat is 137px" an.target 137
qp_assert "a 137px step runs for 120ms" an.stepMs 120
qp_assert "so it is at the floor for a short step" an.durationFloor true
qp_assert "and the seat armed a sweep" an.sweepArmed 120
qp_assert "nothing has reported a landing yet" an.mfBefore 0
qp_assert "one turn later the tween has moved off the origin" an.y1.moved true
qp_assert "and has not landed" an.y1.inFlight true
qp_assert "still in flight on the second turn" an.y2.inFlight true
qp_assert "and moved further" an.y2.rising true
qp_assert "still in flight on the third" an.y3.inFlight true
qp_assert "and moved further again" an.y3.rising true
qp_assert "the follow claim names the cursor's row throughout" an.followIdx1 5
qp_assert "the sweep is still armed mid-flight" an.sweepDuring 120
qp_assert "the three samples are distinct values" an.samplesDistinct true
qp_assert "and they rise monotonically" an.samplesMonotonic true
qp_assert "three samples were taken" an.sampleCount 3
t_match "the first sample is a real interpolated position" '^[0-9]+\.[0-9]+$' "$(qp_get an.y1)"
t_match "and so is the second" '^[0-9]+\.[0-9]+$' "$(qp_get an.y2)"
t_match "and the third" '^[0-9]+\.[0-9]+$' "$(qp_get an.y3)"

t_section "...and it lands on the exact target and says so"
qp_assert "the tween lands on the centre target" an.yLanded 137
qp_assert "exactly, not approximately" an.yLanded.exact true
qp_assert "motionFinished fired once" an.mfFiredOnce true
qp_assert "and only once" an.mfLanded 1
qp_assert "the sweep is released on landing" an.sweepAfter -1
qp_assert "the follow claim is released with it" an.followIdxAfter -1
qp_assert "and the pursuit claim" an.pursuitIdxAfter -1
qp_assert "the seat epoch moved during the traversal" an.epochAdvanced true

t_section "an interrupted seat does not report a landing it never made"
qp_assert "one landing has been reported so far" ar.mfBefore 1
qp_assert "restoreAt opens the restore window" ar.sweeping true
qp_assert "and arms the instant seat" ar.seatsInstant true
qp_assert "the view is at the restored offset" ar.y 100
qp_assert "exactly" ar.exactRestore true
t_note "a seat interrupted by scrollAnim.stop() never emits motionFinished (List.qml:1026 and the restore path stop the tween; only the natural onFinished at List.qml:175 reports). So a consumer tracking motion through that signal - ListFrameState, per common/ui/README.md - sees the seat as still in flight, which is the safer of the two wrong answers but is not a report of where the view came to rest."

# --- layout ------------------------------------------------------------------

t_section "layout: what the view derives from the model"
qp_assert "the list is holding six rows" la.count 6
qp_assert "six 40px rows with 2px gaps is 250px" la.contentHeight 250
qp_assert "which is the source formula" la.contentHeightFormula 250
qp_assert "and the measured table agrees exactly" la.tableMatchesLayout true
qp_assert "so a non-empty model has a positive content height" la.contentHeightPositive true
qp_assert "a Flickable has no implicit width" la.implicitWidth 0
qp_assert "and no implicit height" la.implicitHeight 0
qp_assert "neither of which the model can move" la.hasNoImplicitSize true
qp_assert "the content width is left unset" la.contentWidth -1
t_note "List derives a HEIGHT from the model and no width at all: implicitWidth/implicitHeight are 0 for every model because a Flickable has no implicit size, and contentWidth stays -1. A consumer must give the view a width; the row heights come out of the delegate."
qp_assert "an empty model has no content height" la.emptyContentHeight 0
qp_assert "and no table" la.emptyTableTotal 0
qp_assert "both zero, not negative" la.emptyIsZero true
qp_assert "an unmeasured row falls back to the 34px floor" la.emptyRowHeight 34
qp_assert "which is Ui.rowMinH" la.emptyRowHeight.isFloor true
qp_assert "an unvisited row of the wall does too" la.wallRowHeight 34
qp_assert "which is Ui.rowMinH again" la.wallRowHeight.isFloor true
qp_assert "a measured row is the measurement, not the floor" la.measuredRowHeight 40
qp_assert "which is the delegate's own height" la.measuredRowHeight.isDelegate true
qp_assert "and it is above the floor" la.measuredAboveFloor true
qp_assert "the live delegate agrees" la.delegateHeight 40
qp_assert "row 3 starts at three rows plus three gaps" la.rowTop3 126
qp_assert "which is the source formula" la.rowTop3Formula 126
t_note "the Ui.rowMinH floor applies to rows the table has not measured. A delegate taller than 34 is measured and used as-is, so 'row height relates to Ui.rowMinH' holds for the fallback, not as a clamp."

t_section "a list whose content fits never moves the view"
qp_assert "250px of content in a 300px viewport fits" la.fitsHeight true
qp_assert "so the centre target for row 0 is the top" la.centerTarget0 0
qp_assert "and the follow target is a hold" la.followTarget0 -1
qp_assert "with nothing to scroll" la.tableMaxY0 0
qp_assert "stepping to row 5 still moves the cursor" la.fittingListIndex 5
qp_assert "but the view has not moved a pixel" la.shortListStillZero true

t_section "fitHeight() measures against real delegates"
qp_assert "82px is two 40px rows and one gap" la.fitHeight.100 82
qp_assert "which the source formula confirms" la.fitHeight.100.expected 82
qp_assert "with a row cap it stops at the third row" la.fitHeight.1000.max3 124
qp_assert "no room for even one row is -1" la.fitHeight.0 -1
qp_assert "and an empty model has nothing to measure" la.fitHeight.empty -1

# --- the height table --------------------------------------------------------

t_section "the height table's own guards"
qp_assert "the default identity is the index, as a string key" tb.rowKey0 0
qp_assert "for any index" tb.rowKey5 5
qp_assert "_rowKey always answers with a string" tb.rowKey.isString true
qp_assert "a non-callable rowIdentity degrades to the index" tb.rowKeyNonCallable 3
qp_assert "a null identity degrades to the index" tb.rowKeyNull 3
qp_assert "an undefined identity degrades to the index" tb.rowKeyUndef 3
qp_assert "and putting it back works" tb.rowKeyRestored 7
t_note "the degradation is deliberate and documented (List.qml:252-260): a missing or non-callable rowIdentity must never throw out of a binding, and one shared 'null' key would collapse every row onto a single height entry."
qp_assert "a cleared table is empty" tb.clearedKnown '{}'
qp_assert "a negative index is refused" tb.refuse.negativeIndex 0
qp_assert "an index past the model is refused" tb.refuse.pastModel 0
qp_assert "a zero height is refused" tb.refuse.zeroHeight 0
qp_assert "a negative height is refused" tb.refuse.negativeHeight 0
qp_assert "a height over 2000 is refused" tb.refuse.overMaxHeight 0
qp_assert "a non-number height is refused" tb.refuse.stringHeight 0
qp_assert "NaN is refused" tb.refuse.nanHeight 0
qp_assert "Infinity is refused" tb.refuse.infiniteHeight 0
qp_assert "an undefined height is refused" tb.refuse.undefinedHeight 0
qp_assert "and none of them touched the sum" tb.refuse.sumUntouched 0
qp_assert "or the entry count" tb.refuse.countUntouched 0
qp_assert "1px is inside the accepted range" tb.minAccepted 1
qp_assert "2000px is inside it too" tb.maxAccepted 2000
qp_assert "and 40px is learned" tb.lastAccepted 40
qp_assert "the sum tracks it" tb.sumH 40
qp_assert "the entry count is one" tb.countH 1
qp_assert "and the average is that entry" tb.avgH 40
qp_assert "re-learning the same height does not double it" tb.idempotentSum 40
qp_assert "nor add a second entry" tb.idempotentCount 1
qp_assert "nor move the average" tb.idempotentAvg 40
qp_assert "and rowHeightAt reads it back" tb.rowHeightAt0 40

t_section "measureGuard: a consumer that says no is never learned from"
qp_assert "nothing was learned" tb.guardKnown '{}'
qp_assert "and no entry exists" tb.guardCount 0

t_section "maxKnownH: the bound evicts, and the average follows what is kept"
qp_assert "30 measurable rows against a bound of 6 leaves 6 entries" tb.boundedSize 6
qp_assert "and _countH agrees" tb.boundedCount 6
qp_assert "which is inside the bound" tb.boundedLeMax true
qp_assert "the surviving average is still a real height" tb.boundedAvg 34
qp_assert "and rows still resolve through the fallback" tb.boundedStillLearns true

t_section "a contested identity is refused for learning and reported verbatim"
qp_assert "six rows claiming one identity are reported" tb.dupeError duplicate_identity
qp_assert "as a string a consumer can show" tb.dupeError.isString true
qp_assert "and nothing is learned for them" tb.dupeKnown '{}'
qp_assert "the fingerprint records the collision" tb.dupeFingerprint '0@6:same|same'
qp_assert "fixing the identity and declaring the revision clears it" tb.dupeErrorCleared ''
qp_assert "and the fingerprint becomes revision@count:first|last" tb.dupeFingerprintAfter '1@6:0|5'
qp_assert "after which the table learns again" tb.dupeLearns 6
t_note "clearing the collision needs the revision, not just the new rowIdentity: the fingerprint at List.qml:282-283 is built from identityRevision, count and the two endpoint identities, so an in-place identity swap with the same count and endpoints is invisible without it. A consumer that mutates identities without declaring one leaves the code permanently - documented at List.qml:238-252."

t_section "restingContentHeight: a claim that the content fits holds the seat"
qp_assert "row 6 has a real centre seat" tb.restingTargetExists true
qp_assert "and followTarget agrees with it by default" tb.restingFollow 173
qp_assert "the target is the same number" tb.restingCenter 173
qp_assert "claiming the content fits holds it" tb.restingHeld true
qp_assert "even though the centre target still exists" tb.restingUnheld false
qp_assert "and withdrawing the claim resumes the seat" tb.restingResumed true
t_note "the guard is at List.qml:578: restingContentHeight above zero AND at or below the viewport height. So it holds only when the claim is 'the content fits' - a claim of 4000 against a 120px viewport does NOT hold, which is right, because that claim is not saying the content fits."

# --- instance isolation ------------------------------------------------------

t_section "two lists in one scene share nothing"
qp_assert "the two cursors are independent" is.indicesDiffer true
t_note "every private field on List is an instance property, and a module-level scratch anywhere in the component would show up here: the probe writes a poison value into one list's sweep, seat, handoff, height table, ownership map, touch stamps, fingerprint and both cursor claims, then reads all of them back on a second list in the same scene."
qp_assert "the sibling's sweep is untouched" is.siblingSweep -1
qp_assert "the sibling's instant-seat gate is untouched" is.siblingSeats false
qp_assert "the sibling's handoff is untouched" is.siblingHandoff false
qp_assert "the sibling's table has none of the poison" is.noLeak true
qp_assert "the sibling's table is its own" is.siblingKnown '{"0":34,"1":34,"2":34}'
qp_assert "its sum is its own" is.siblingSum 102
qp_assert "its entry count is its own" is.siblingCount 3
qp_assert "its average is its own" is.siblingAvg 34
qp_assert "its ownership map is its own" is.siblingOwner '{"0":0,"1":1,"2":2,"3":3,"4":4,"5":5}'
qp_assert "its touch stamps are its own" is.siblingTouch '{"0":1,"1":2,"2":3}'
qp_assert "its fingerprint is its own" is.siblingFingerprint '0@6:0|5'
qp_assert "its follow claim is its own" is.siblingFollow 0
qp_assert "its pursuit claim is its own" is.siblingPursuit -1
qp_assert "and its bar duration is unaffected" is.siblingDuration 120
qp_assert "while the poisoned one is zeroed" is.ownDuration 0
qp_assert "the sibling's own table total is its own arithmetic" is.siblingTableTotal 214
qp_assert "and so is its velocity" is.siblingScrollVel 6000
qp_assert "clearing the poisoned table works" is.baseCleared '{}'
qp_assert "and the sibling's table survived it" is.siblingSurvived true

# --- non-mutation ------------------------------------------------------------

t_section "the model the caller handed in comes back untouched"
t_note "a real invariant and one a source read cannot confirm: the height table, the delegate model, the seat writer and the reconciliation handler all walk the caller's array, and a single sort or splice in any of them would corrupt a menu's option list in place."
qp_assert "the eight-row model is byte-identical" nm.rows8 true
qp_assert "the six-row model is byte-identical" nm.rows6 true
qp_assert "the thirty-row model is byte-identical" nm.rows30 true
qp_assert "the replacement model is byte-identical" nm.replacement true
qp_assert "and is still an array" nm.isArray true
qp_assert "of the length it started with" nm.rows8.length 8
qp_assert "with its first element intact" nm.rows8.first row0
qp_assert "and its last" nm.rows8.last row7
qp_assert "carrying no keys but its indices" nm.noExtraKeys true

t_section "everything is released once the run is over"
qp_assert "the wall's cursor is inside its model" fin.wallIndexInRange true
qp_assert "its table is still readable" fin.wallTableTotalPositive true
qp_assert "the animated traversal's sweep is released" fin.sweeperSweep -1
qp_assert "its follow claim is released" fin.sweeperFollow -1
qp_assert "its pursuit claim is released" fin.sweeperPursuit -1
qp_assert "the hold-span seat released after the wall floor" fin.holdReleased true
qp_assert "and its durations re-armed" fin.holdDurRearmed true
qp_assert "the empty list is still empty" fin.emptyCount 0
qp_assert "the one-row list still has its row" fin.soloCount 1
qp_assert "only the one tween that really landed ever reported" fin.mfTotal 1
qp_assert "and no observation in the whole run threw" fin.probeThrew 0

t_summary

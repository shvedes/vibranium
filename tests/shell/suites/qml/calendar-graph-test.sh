#!/bin/bash
# Suite: Calendar and FunctionGraph - the two wrappers that turn an already
# unit-tested library into pixels.
#
# CalendarLib.js and FuncLib.js are covered from node by
# suites/js/math-calc-color.test.mjs and
# suites/js/services-calendar-weather.test.mjs, so the arithmetic in them is
# not what this file is for. What IS what this file is for is the WRAPPER:
#
#   * does the QML compute the right thing FROM ITS OWN PROPERTIES, and hand
#     FuncLib/CalendarLib the same arguments a reader of the source would say
#     it hands them? A wrapper that drops or re-derives a library result is
#     invisible to the node suites
#   * does it stay consistent with the library across the boundaries that
#     matter - a month that needs five or six weeks, February in a leap year
#     and in a common year, December rolling into January, a graph domain that
#     is empty, reversed, equal-ended, or full of poles
#   * does a NaN or an Infinity ever reach a geometry property, which is what
#     makes an item collapse to nothing on screen
#
# The probe (probes/calendar-graph.qml) therefore imports both libraries
# itself and asserts wrapper-output == library-output for identical inputs,
# rather than only asserting the resulting numbers.
#
# Everything is date-pinned. Calendar defaults selectedDate AND today to
# `new Date()`, and QJSEngine's Date is the real clock, so every instance in
# the probe is constructed with an explicit fixed date. 2024 (leap) and 2023
# (common) are both used deliberately. No assertion here reads the clock.
#
# Remaining confirmed behavior is asserted directly. The formerly unbounded
# graph grid and dropped calendar input are covered by bounded-grid and queued
# delta contracts below; the writable viewMonth edge case remains documented.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "calendar-graph" "Calendar's month grid and FunctionGraph's plot: the wrappers, over a real event loop"
require_qs

trap qp_teardown EXIT

PROBE="$TESTS_SHELL_DIR/suites/qml/probes/calendar-graph.qml"

# ---------------------------------------------------------------------------
# Run 1: the main probe.
# ---------------------------------------------------------------------------

if ! qp_run "$PROBE" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the probe reached the end of its event loop"
t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
t_eq "it ran in the full (not wide-domain) mode" "full" "$(qp_get mode)"
t_eq "the wide-domain loader stayed inactive" "skipped" "$(qp_get wide.built)"
t_eq "the event loop actually turned" "true" "$(qp_get recap.eventLoopRan)"
t_eq "it got through every phase" "28" "$(qp_get recap.phases)"
t_eq "and printed its completion key last" "true" "$(qp_get probe.finished)"

# ---------------------------------------------------------------------------
# Settling
# ---------------------------------------------------------------------------

t_section "the values the pump settled on"
# Phase 1 reports the Component.onCompleted reading next to the settled one.
# On this host they agree for both components, which is asserted rather than
# assumed - if a future Qt made the layout pass matter here, this is the
# assertion that notices.
t_eq "the calendar's height is final after the first tick" "274" "$(qp_get settle.cal.implicitHeight)"
t_eq "and the item has taken that height" "274" "$(qp_get settle.cal.height)"
t_eq "which is what the onCompleted snapshot said too" "274" "$(qp_get settle.cal.snapHeight)"
t_eq "so the snapshot was not premature here" "true" "$(qp_get settle.cal.heightMatchesSnapshot)"
t_eq "the grid was already whole at snapshot time" "42" "$(qp_get settle.cal.snapCells)"
t_eq "and still is" "42" "$(qp_get settle.cal.cells)"
t_eq "the graph's sample count is final" "280" "$(qp_get settle.graph.sampleN)"
t_eq "the snapshot agreed about that too" "true" "$(qp_get settle.graph.sampleNMatchesSnapshot)"
t_eq "the graph item is as wide as its implicit width" "280" "$(qp_get settle.graph.width)"
t_eq "which is the documented default" "280" "$(qp_get settle.graph.implicitWidth)"
t_eq "the plot box plus header is not collapsed" "173" "$(qp_get settle.graph.implicitHeight)"
# A probe top-level Item is not in a Window, so Window.window is null and the
# DPR expression must take its 1 fallback. What matters is that it is never 0
# or NaN: the Canvas size and scale are both divided by it.
t_eq "with no window the DPR falls back to 1" "1" "$(qp_get settle.dpr)"
t_eq "and is a usable positive number" "true" "$(qp_get settle.dprPositive)"
# Colour SHAPE only - the palette lands milliseconds after boot and the RGB
# channels are theme values, so only the form is asserted here.
t_eq "the mat colour is a bare rgb triple before tinting" "solid6" "$(qp_get settle.colour.bg)"
t_eq "a tinted colour is already argb" "argb8" "$(qp_get settle.colour.axis)"

# ---------------------------------------------------------------------------
# Calendar geometry
# ---------------------------------------------------------------------------

t_section "Calendar paints from the CalendarLib constants"
t_eq "the cell width" "42" "$(qp_get cal.cellW)"
t_eq "the cell height" "28" "$(qp_get cal.cellH)"
t_eq "the cell gap" "2" "$(qp_get cal.cellGap)"
t_eq "the grid width" "306" "$(qp_get cal.gridW)"
t_eq "the grid height" "178" "$(qp_get cal.gridH)"
t_eq "the title height" "24" "$(qp_get cal.titleH)"
t_eq "the year-block height" "32" "$(qp_get cal.yearBlockH)"
t_eq "the weekday-row height" "16" "$(qp_get cal.weekdayRowH)"
t_eq "the grid's vertical offset" "96" "$(qp_get cal.gridY)"
t_eq "the year block's offset" "32" "$(qp_get cal.yearBlockY)"
t_eq "the weekday row's offset" "72" "$(qp_get cal.weekdayRowY)"
t_eq "the width a host should size to" "306" "$(qp_get cal.desiredWidth)"
t_eq "the height a host should size to" "274" "$(qp_get cal.desiredHeight)"
t_eq "the item took that width" "306" "$(qp_get cal.width)"
t_eq "and that height" "274" "$(qp_get cal.height)"
t_eq "its implicit size is the same width" "306" "$(qp_get cal.implicitWidth)"
t_eq "and the same height" "274" "$(qp_get cal.implicitHeight)"
t_eq "weekStart defaults to Monday" "1" "$(qp_get cal.weekStartDefault)"
t_eq "which is 1, not 0" "true" "$(qp_get cal.weekStartIsMonday)"

t_section "the geometry is internally consistent, not just correct"
# These are RELATIONS between the wrapper's own numbers. A missing padding
# term, a stale token or a reordered block shows up as a false, not as a
# magic-number drift that needs updating here.
t_eq "gridW is 7 cells and 6 gaps" "true" "$(qp_get id.gridW)"
t_eq "gridH is 6 rows and 5 gaps" "true" "$(qp_get id.gridH)"
t_eq "the desired width is the grid width" "true" "$(qp_get id.desiredWidth)"
t_eq "the desired height is the grid offset plus the grid" "true" "$(qp_get id.desiredHeight)"
t_eq "the year block sits one spacing unit under the title" "true" "$(qp_get id.yearBlockY)"
t_eq "the weekday row sits one unit under the year block" "true" "$(qp_get id.weekdayRowY)"
t_eq "the grid offset is the end of the whole QML block chain" "true" "$(qp_get id.gridYFromQmlChain)"
t_eq "the Repeater's last column lands exactly on the grid edge" "true" "$(qp_get id.lastColumnFits)"
t_eq "the Repeater's last row lands exactly on the grid edge" "true" "$(qp_get id.lastRowFits)"
t_eq "the item's size is its desired size" "true" "$(qp_get id.itemSizeIsDesired)"
t_eq "and so is its implicit size" "true" "$(qp_get id.implicitIsDesired)"
# CalendarLib.js cannot import the Ui singleton, so it duplicates Ui.s as a
# literal SP = 8 (CalendarLib.js:136) while the QML block chain uses Ui.s.
# gridY comes from the JS side and yearBlockY/weekdayRowY from the QML side,
# so this identity is the only thing keeping the duplication honest - change
# Ui.s and the two halves of the layout drift apart silently.
t_note "gridY is computed in CalendarLib.js from a duplicated SP = 8 (CalendarLib.js:136) while Calendar.qml computes yearBlockY/weekdayRowY from Ui.s (Calendar.qml:55-56); the two agree only because Ui.s is still 8, and id.gridYFromQmlChain is the assertion that notices the day it stops"
t_eq "selectedKey is the library's key for the selection" "true" "$(qp_get lib.selectedKey)"
t_eq "and it is the documented yyyy-MM-dd form" "true" "$(qp_get id.selectedKeyFormat)"

t_section "the wrapper does not re-derive what the library already knows"
# ClockIsland sizes its card from CalendarLib.gridW / contentHeight WITHOUT
# instantiating a calendar (ClockIsland.qml:30-33), precisely so the two cannot
# drift. If the wrapper re-derived any of these numbers, the card and the
# widget would disagree with no local test able to see it.
t_eq "the cell width is the library's" "true" "$(qp_get lib.cellW)"
t_eq "the cell height is the library's" "true" "$(qp_get lib.cellH)"
t_eq "the cell gap is the library's" "true" "$(qp_get lib.cellGap)"
t_eq "the title height is the library's" "true" "$(qp_get lib.titleH)"
t_eq "the year-block height is the library's" "true" "$(qp_get lib.yearBlockH)"
t_eq "the weekday-row height is the library's" "true" "$(qp_get lib.weekdayRowH)"
t_eq "the grid width is the library's" "true" "$(qp_get lib.gridW)"
t_eq "the grid height is the library's" "true" "$(qp_get lib.gridH)"
t_eq "the grid offset is the library's" "true" "$(qp_get lib.gridY)"
t_eq "and the desired height is the library's contentHeight" "true" "$(qp_get lib.contentHeight)"
t_eq "which is the number the clock island sizes from" "true" "$(qp_get lib.gridWFeedsHost)"

# ---------------------------------------------------------------------------
# The month grid
# ---------------------------------------------------------------------------

t_section "a six-week month: September 2024"
# 1 September 2024 is a Sunday, so with weekStart 1 the grid needs six rows
# and the last one is still September. A grid that dropped the trailing days
# would show only 36 cells, or a 41st cell that repeats the 1st.
t_eq "the grid is always 42 cells" "42" "$(qp_get g6.len)"
t_eq "all 42 keys are distinct" "42" "$(qp_get g6.uniqueKeys)"
t_eq "the 42 days are consecutive, with no gap or repeat" "yes" "$(qp_get g6.consecutive)"
t_eq "30 of them are in September" "30" "$(qp_get g6.inMonth)"
t_eq "which is September's length" "30" "$(qp_get g6.daysInMonth)"
t_eq "the last in-month row is row 5, so all six are used" "5" "$(qp_get g6.lastInMonthRow)"
t_eq "and only its first cell is still September" "1000000" "$(qp_get g6.row5Mask)"
t_eq "the first cell is Monday 26 August" "2024-08-26" "$(qp_get g6.firstKey)"
t_eq "which is the weekStart" "1" "$(qp_get g6.firstWeekday)"
t_eq "the last cell is 6 October" "2024-10-06" "$(qp_get g6.lastKey)"
t_eq "and it is correctly marked as next month" "false" "$(qp_get g6.lastIsInMonth)"
t_eq "the grid spans the whole six weeks" "2024-08-26..2024-10-06" "$(qp_get g6.span)"
t_eq "the 30th of September is in the last row" "true" "$(qp_get g6.sep30IsLastRow)"
t_eq "the selected day appears exactly once" "1" "$(qp_get g6.selectedCount)"
t_eq "at index 16" "16" "$(qp_get g6.sep11At)"
t_eq "today is marked exactly once" "1" "$(qp_get g6.todayCount)"
t_eq "and there are 12 weekend cells in six rows" "12" "$(qp_get g6.weekendCount)"
t_eq "row 0 runs Monday to Sunday" "1234560" "$(qp_get g6.row0)"
# The wrapper passes viewYear/viewMonth/weekStart/today straight through, so
# the whole cell array must be byte-identical to the library's.
t_eq "and every cell matches CalendarLib.monthGrid exactly" "true" "$(qp_get g6.sameAsLib)"

t_section "a five-week month: June 2024"
# 1 June 2024 is a Saturday and June has 30 days, so five rows suffice and
# the sixth row is entirely July. The fixed grid must still SHOW those seven
# July days - that is the whole reason monthGrid is hard-wired to 42.
t_eq "the grid is still 42 cells" "42" "$(qp_get g5.len)"
t_eq "all keys are distinct" "42" "$(qp_get g5.uniqueKeys)"
t_eq "and consecutive" "yes" "$(qp_get g5.consecutive)"
t_eq "30 days are in June" "30" "$(qp_get g5.inMonth)"
t_eq "the last in-month row is row 4" "4" "$(qp_get g5.lastInMonthRow)"
t_eq "so the entire sixth row is next month" "0000000" "$(qp_get g5.row5Mask)"
t_eq "the grid starts on Monday 27 May" "2024-05-27" "$(qp_get g5.firstKey)"
t_eq "and ends on Sunday 7 July" "2024-07-07" "$(qp_get g5.lastKey)"
t_eq "1 July is present, at the top of the sixth row" "35" "$(qp_get g5.jul1At)"
t_eq "the selected day appears exactly once" "1" "$(qp_get g5.selectedCount)"
t_eq "and the cells match the library" "true" "$(qp_get g5.sameAsLib)"

t_section "February in a leap year and in a common year"
# This is the classic wrapper bug: a hard-coded 365, or a day number computed
# with the wrong year's length, and only one of the two Februaries is wrong.
t_eq "February 2024 has 29 in-month cells" "29" "$(qp_get feb.leap.inMonth)"
t_eq "which is February 2024's length" "29" "$(qp_get feb.leap.daysInMonth)"
t_eq "29 February is in the grid" "31" "$(qp_get feb.leap.feb29At)"
t_eq "and is correctly marked in-month" "true" "$(qp_get feb.leap.feb29InMonth)"
t_eq "its key is the 29th of February 2024" "2024-02-29" "$(qp_get feb.leap.feb29Key)"
t_eq "1 March follows it immediately" "32" "$(qp_get feb.leap.march1At)"
t_eq "no key repeats" "42" "$(qp_get feb.leap.uniqueKeys)"
t_eq "and the days are consecutive across the leap day" "yes" "$(qp_get feb.leap.consecutive)"
t_eq "the cells match the library" "true" "$(qp_get feb.leap.sameAsLib)"
t_eq "February 2023 has 28 in-month cells" "28" "$(qp_get feb.common.inMonth)"
t_eq "which is February 2023's length" "28" "$(qp_get feb.common.daysInMonth)"
t_eq "there is NO 29 February in a common year" "-1" "$(qp_get feb.common.feb29At)"
t_eq "1 March is at index 30, one earlier than in the leap year" "30" "$(qp_get feb.common.mar1At)"
t_eq "no key repeats" "42" "$(qp_get feb.common.uniqueKeys)"
t_eq "and the days are consecutive" "yes" "$(qp_get feb.common.consecutive)"
t_eq "the cells match the library" "true" "$(qp_get feb.common.sameAsLib)"
t_eq "the two Februaries differ by exactly the leap day" "1" "$(qp_get feb.delta)"
t_eq "and the common year really has no 29 February" "true" "$(qp_get feb.commonHasNo29)"

t_section "a month that fits in four whole weeks: February 2021"
# The extreme of the fixed grid: 1 February 2021 is a Monday, so February
# fills rows 0-3 exactly and rows 4 and 5 are entirely March. A grid sized to
# the month would be a third shorter; the point of 42 is that it never moves.
t_eq "the grid is 42 cells, not 28" "42" "$(qp_get g4.len)"
t_eq "28 days are in February" "28" "$(qp_get g4.inMonth)"
t_eq "the last in-month row is row 3" "3" "$(qp_get g4.lastInMonthRow)"
t_eq "so row 4 is entirely March" "0000000" "$(qp_get g4.row4Mask)"
t_eq "and so is row 5" "0000000" "$(qp_get g4.row5Mask)"
t_eq "1 March is at index 28" "28" "$(qp_get g4.mar1At)"
t_eq "the grid ends on 14 March" "2021-03-14" "$(qp_get g4.lastKey)"
t_eq "no key repeats" "42" "$(qp_get g4.uniqueKeys)"
t_eq "and the days are consecutive" "yes" "$(qp_get g4.consecutive)"

t_section "December rolls into January, and January back into December"
# The two year boundaries in opposite directions. A grid that dropped leading
# or trailing days would show 35 or 36 cells here, and the missing days are
# exactly the ones a user needs to click.
t_eq "December 2024 has 31 in-month cells" "31" "$(qp_get dec.inMonth)"
t_eq "no key repeats" "42" "$(qp_get dec.uniqueKeys)"
t_eq "and the days are consecutive across midnight" "yes" "$(qp_get dec.consecutive)"
t_eq "the grid starts on Monday 25 November" "2024-11-25" "$(qp_get dec.firstKey)"
t_eq "and ends on 5 January 2025" "2025-01-05" "$(qp_get dec.lastKey)"
t_eq "31 December is at index 36" "36" "$(qp_get dec.dec31At)"
t_eq "1 January 2025 is at index 37" "37" "$(qp_get dec.jan1At)"
t_eq "5 January 2025 is the last cell" "41" "$(qp_get dec.jan5At)"
t_eq "and those January days are shown, not dropped" "true" "$(qp_get dec.janCellsShown)"
t_eq "1 January is correctly marked as NOT in December" "false" "$(qp_get dec.jan1InMonth)"
t_eq "and carries the new year" "2025" "$(qp_get dec.jan1Year)"
t_eq "with January's month index" "0" "$(qp_get dec.jan1Month)"
t_eq "the last row is two December days then five January" "1100000" "$(qp_get dec.row5Mask)"
t_eq "the cells match the library" "true" "$(qp_get dec.sameAsLib)"
# January 2024 begins exactly on the weekStart, so with weekStart 1 there is
# no leading day at all - and that is the correct answer, not a dropped one.
t_eq "January 2024 starts on the 1st with a Monday week" "2024-01-01" "$(qp_get jan.mondayFirst)"
t_eq "so it has no leading December day" "true" "$(qp_get jan.mondayNoLeading)"
# The same month with a Sunday weekStart must gain exactly one leading day,
# from the PREVIOUS December, and must not mistake it for January.
t_eq "with a Sunday week start it starts on 31 December" "2023-12-31" "$(qp_get jan.sundayFirst)"
t_eq "that leading cell is marked as not in January" "false" "$(qp_get jan.sundayLeadingInMonth)"
t_eq "and carries the previous year" "2023" "$(qp_get jan.sundayLeadingYear)"
t_eq "January still has all 31 of its own days" "31" "$(qp_get jan.sundayInMonth)"
t_eq "and the grid ends on 10 February" "2024-02-10" "$(qp_get jan.sundayLastKey)"
# January 2023 is the other direction: it starts on a Sunday, so a Monday
# weekStart needs six leading December 2022 days.
t_eq "January 2023 reaches back into December 2022" "2022-12-26" "$(qp_get jan23.firstKey)"
t_eq "and that leading cell is from 2022" "2022" "$(qp_get jan23.leadingYear)"
t_eq "January still has its own 31 days" "31" "$(qp_get jan23.inMonth)"
t_eq "with no gap or repeat across the year boundary" "yes" "$(qp_get jan23.consecutive)"

t_section "today is marked wherever it lands, and only there"
# The todayKey argument is threaded through the wrapper (Calendar.qml:67). A
# today that falls in the trailing month must still be marked, because the
# user can see and click that cell.
t_eq "a today in the trailing month is marked exactly once" "1" "$(qp_get trailtoday.count)"
t_eq "on 2 October 2024, at index 37" "37" "$(qp_get trailtoday.at)"
t_eq "and is not confused for a September day" "false" "$(qp_get trailtoday.inMonth)"
t_eq "1 October is also out of month" "false" "$(qp_get trailtoday.oct1InMonth)"
t_eq "while 30 September, one cell earlier, is in month" "true" "$(qp_get trailtoday.sep30InMonth)"
t_eq "and the cells match the library's" "true" "$(qp_get trailtoday.sameAsLib)"
t_eq "a today outside the grid marks nothing" "0" "$(qp_get awaytoday.count)"
t_eq "without disturbing the grid" "42" "$(qp_get awaytoday.len)"
t_eq "which is still consecutive" "yes" "$(qp_get awaytoday.consecutive)"

# ---------------------------------------------------------------------------
# viewMonth / viewYear
# ---------------------------------------------------------------------------

t_section "viewMonth at the ends of its range is fine"
t_eq "month 11 reads back as 11" "11" "$(qp_get vm11.month)"
t_eq "and shows a full December" "31" "$(qp_get vm11.inMonth)"
t_eq "which is the December grid" "true" "$(qp_get vm11.isDecember)"
t_eq "month 0 reads back as 0" "0" "$(qp_get vm0.month)"
t_eq "and shows a full January" "31" "$(qp_get vm0.inMonth)"
t_eq "which is the January grid" "true" "$(qp_get vm0.isJanuary)"

t_section "FINDING: viewMonth past the end of the year is not normalised"
# viewYear/viewMonth are plain writable ints. The library is tolerant - new
# Date(2024, 12, 1) IS January 2025 - but monthGrid compares every cell
# against the RAW month and year (CalendarLib.js:109), so an out-of-range
# month matches nothing at all.
t_note "FINDING Calendar.qml:31-32 declares viewYear/viewMonth as bare writable ints with no normalisation. Writing viewMonth: 12 leaves viewYear 2024 and viewMonth 12, and monthGrid(2024, 12, ...) returns the 30-Dec-2024..9-Feb-2025 grid with inMonth false for ALL 42 cells (CalendarLib.js:109 compares cellMonth === month), so every day renders in the dimmed neighbouring-month colour and the selected day has no highlight. Writing viewMonth: -1 does the same for 27-Nov-2023..7-Jan-2024. Not reachable from the running shell today - only stepMonth/selectDay write the view, and they go through CalendarLib.stepMonth, which rolls the year - but it is one host assignment away, and the title (Qt.formatDate on new Date(viewYear, viewMonth, 1)) will read January 2025 while viewYear still says 2024."
t_eq "viewMonth 12 reads back out of range" "12" "$(qp_get vm12.month)"
t_eq "while viewYear stays 2024 - the year does not roll" "2024" "$(qp_get vm12.year)"
t_eq "so the month is not in the 0..11 range" "false" "$(qp_get vm12.inRange)"
t_eq "and the grid matches December 2024 + January 2025" "2024-12-30..2025-02-09" \
  "$(printf '%s..%s' "$(qp_get vm12.firstKey)" "$(qp_get vm12.lastKey)")"
t_eq "but NOT ONE of its 42 cells claims to be in month" "0" "$(qp_get vm12.inMonth)"
t_eq "so the selected day is nowhere to be found" "0" "$(qp_get vm12.selectedCount)"
t_eq "viewMonth -1 reads back out of range too" "-1" "$(qp_get vmneg.month)"
t_eq "and it is not in range" "false" "$(qp_get vmneg.inRange)"
t_eq "its grid is November 2023 + January 2024" "2023-11-27..2024-01-07" \
  "$(printf '%s..%s' "$(qp_get vmneg.firstKey)" "$(qp_get vmneg.lastKey)")"
t_eq "with again no cell in month" "0" "$(qp_get vmneg.inMonth)"
t_eq "and no visible selection" "0" "$(qp_get vmneg.selectedCount)"

t_section "viewYear/viewMonth are seeded from selectedDate, and the binding is one-way"
t_eq "a fresh calendar views its selection's month" "2024/8" "$(qp_get v.mover.before)"
t_eq "assigning selectedDate moves the view with it" "2023/2" "$(qp_get v.mover.after)"
t_eq "the view followed the new selection" "true" "$(qp_get v.mover.followsSelection)"
t_eq "and the key and day number agree" "2023-03-03" "$(qp_get v.mover.keyAfter)"
t_eq "3 March 2023 is day 62" "62" "$(qp_get v.mover.doyAfter)"
# Calendar.qml:28-30 documents the takeover: stepMonth and selectDay assign the
# view explicitly, which breaks the seeding binding, so a later selectedDate
# no longer moves the view. That is why goToToday() assigns the view too.
t_note "Calendar.qml:28-30 documents that viewYear/viewMonth are seeded from selectedDate by binding and that stepMonth/selectDay 'assign explicitly, which takes over from the binding'. The consequence - which the comment does not state - is that after ANY month step a host's selectedDate writes stop moving the view, so the only way back is goToToday() or another explicit assignment. Pinned below so a change to the ownership model is visible."
t_eq "after a step, the view is the stepped month" "2024/9" "$(qp_get v.broken.afterStep)"
t_eq "a later selectedDate is still taken" "2020-06-06" "$(qp_get v.broken.selectionTook)"
t_eq "but it no longer moves the view" "2024/9" "$(qp_get v.broken.viewAfterNewSelection)"
t_eq "the view really is unchanged" "true" "$(qp_get v.broken.viewUnchanged)"

# ---------------------------------------------------------------------------
# weekStart
# ---------------------------------------------------------------------------

t_section "weekStart moves the first column, and the labels follow it"
t_eq "the default is 1" "1" "$(qp_get ws.default)"
t_eq "weekStart 0 puts Sunday first" "0123456" "$(qp_get ws.zero.row0)"
t_eq "so the first cell is a Sunday" "0" "$(qp_get ws.zero.firstWeekday)"
t_eq "1 September 2024 itself" "2024-09-01" "$(qp_get ws.zero.firstKey)"
# The weekday LABELS come from CalendarLib.weekdayOrder(weekStart) through the
# Repeater (Calendar.qml:241) and the grid's first row comes from the same
# weekStart. If the wrapper ever normalised weekStart for one and not the
# other, the header would disagree with the columns under it.
t_eq "the label order for a Sunday week matches the grid" "0123456" "$(qp_get ws.zero.labelOrder)"
t_eq "and they agree" "true" "$(qp_get ws.labelsMatchGrid.zero)"
t_eq "weekStart 1 puts Monday first" "1234560" "$(qp_get ws.one.row0)"
t_eq "with matching labels" "1234560" "$(qp_get ws.one.labelOrder)"
t_eq "and they agree too" "true" "$(qp_get ws.labelsMatchGrid.one)"

t_section "an out-of-range weekStart is normalised, not obeyed"
# The property is a typed int, so only integers ever reach the library - but
# an integer outside 0..6 is entirely plausible from a host that computes it.
t_eq "weekStart 7 normalises to 0" "0" "$(qp_get ws.seven.normalisedTo)"
t_eq "and the row starts on Sunday" "0123456" "$(qp_get ws.seven.row0)"
t_eq "the grid is still 42 cells, not 49" "42" "$(qp_get ws.seven.len)"
t_eq "with no repeated key" "42" "$(qp_get ws.seven.unique)"
t_eq "and no gap" "yes" "$(qp_get ws.seven.consecutive)"
t_eq "the row is still a permutation of the 7 weekdays" "true" "$(qp_get ws.seven.rowIsPermutation)"
t_eq "weekStart -1 normalises to 6, Saturday" "6" "$(qp_get ws.negOne.normalisedTo)"
t_eq "so the row starts on Saturday" "6012345" "$(qp_get ws.negOne.row0)"
t_eq "the grid is still 42 cells" "42" "$(qp_get ws.negOne.len)"
t_eq "with no repeated key" "42" "$(qp_get ws.negOne.unique)"
t_eq "and no gap" "yes" "$(qp_get ws.negOne.consecutive)"
t_eq "the row is still a permutation" "true" "$(qp_get ws.negOne.rowIsPermutation)"
t_eq "weekStart 99 normalises to 1" "1" "$(qp_get ws.neg99.normalisedTo)"
t_eq "so the row starts on Monday again" "1234560" "$(qp_get ws.neg99.row0)"
t_eq "the grid is still 42 cells" "42" "$(qp_get ws.neg99.len)"
t_eq "with no repeated key" "42" "$(qp_get ws.neg99.unique)"
t_eq "and no gap" "yes" "$(qp_get ws.neg99.consecutive)"
t_eq "the row is still a permutation" "true" "$(qp_get ws.neg99.rowIsPermutation)"
t_eq "weekStart 6 is Saturday-first, in range" "6012345" "$(qp_get ws.six.row0)"
t_eq "a Sunday-first row is a permutation" "true" "$(qp_get ws.zero.rowIsPermutation)"
t_skip "weekStart accepts a fractional value and a weekday name" \
  "weekStart is a typed int, so 3.6 is a load-time QML type error (Invalid property assignment: int expected) and \"monday\" cannot be passed at all; CalendarLib.normalizeWeekStart's Math.round and weekday-name branches are unreachable through the component"
t_skip "the weekday label Text objects themselves" \
  "the labels live in a Repeater delegate whose id is file-private to Calendar.qml, so the rendered strings cannot be read from outside; what is asserted is CalendarLib.weekdayOrder(weekStart), the exact expression the delegate is bound to"

# ---------------------------------------------------------------------------
# daySelected
# ---------------------------------------------------------------------------

t_section "daySelected carries the newly chosen date, once per choice"
# Driven through selectDay(), which is what the cell MouseArea calls
# (Calendar.qml:325). There is no compositor offscreen, so onClicked itself
# cannot be synthesised - see the skips at the end of this section.
t_eq "nothing has been selected yet" "0" "$(qp_get sel.count0)"
t_eq "and the calendar is on its selection's month" "2024/8" "$(qp_get sel.view0)"
t_eq "with 11 September selected" "2024-09-11" "$(qp_get sel.date0)"
t_eq "one selection emits exactly one signal" "1" "$(qp_get sel.count1)"
t_eq "carrying 15 September 2024" "2024-09-15" "$(qp_get sel.log1)"
t_eq "and selectedDate agrees" "2024-09-15" "$(qp_get sel.date1)"
t_eq "so the signal is not one selection stale" "2024-09-15" "$(qp_get sel.emitted1)"
t_eq "15 September is day 259 of a leap year" "259" "$(qp_get sel.doy1)"
t_eq "the view did not move - still September" "2024/8" "$(qp_get sel.view1)"
t_eq "a second selection emits a second signal" "2" "$(qp_get sel.count2)"
t_eq "carrying BOTH dates, in order" "2024-09-15,2024-09-20" "$(qp_get sel.log2)"
t_eq "and selectedDate is the second one" "2024-09-20" "$(qp_get sel.date2)"
t_eq "so the second emit is not a repeat of the first" "true" "$(qp_get sel.noStaleSecond)"
t_eq "20 September is day 264" "264" "$(qp_get sel.doy2)"
t_eq "and 72% of the year is behind it" "72" "$(qp_get sel.progress2)"
# Clicking a greyed trailing cell. selectDay assigns viewYear/viewMonth from
# the CLICKED cell, so the view follows into the next month - most calendars
# do this, but it means one click both selects and navigates.
t_note "selectDay() assigns viewYear/viewMonth from the clicked cell (Calendar.qml:98-99), so selecting a greyed trailing cell in the next month ALSO moves the view into that month, with no slide animation because _sliding is untouched. Defensible, but surprising: one click changes two things."
t_eq "selecting the trailing 1 October emits a third signal" "3" "$(qp_get sel.count3)"
t_eq "carrying all three dates in order" "2024-09-15,2024-09-20,2024-10-01" "$(qp_get sel.log3)"
t_eq "the selection is 1 October 2024" "2024-10-01" "$(qp_get sel.neighbourDate)"
t_eq "and the view followed it into October" "2024/9" "$(qp_get sel.neighbourView)"
t_eq "which is now a complete month" "31" "$(qp_get sel.neighbourInMonth)"
# An impossible day. new Date() rolls forward silently, so the host's argument
# and the emitted date disagree and nothing is reported.
t_note "selectDay(2023, 1, 29) does not exist, and new Date(2023, 1, 29) rolls silently to 1 March 2023 (Calendar.qml:97). The signal carries 2023-03-01, selectedDate is 2023-03-01, and the view is left on February 2023 - so a caller that passes a day number it computed wrongly gets a different day and no error. Only reachable from a host computing day numbers itself; the grid never offers a cell whose key is not that day."
t_eq "the impossible day still emits" "4" "$(qp_get sel.overflowCount)"
t_eq "rolled forward to 1 March 2023" "2023-03-01" "$(qp_get sel.overflowKey)"
t_eq "and left the view on February" "2023/1" "$(qp_get sel.overflowView)"
t_eq "goToToday() emits as well" "5" "$(qp_get sel.todayCount)"
t_eq "carrying the full history" \
  "2024-09-15,2024-09-20,2024-10-01,2023-03-01,2024-09-11" "$(qp_get sel.todayLog)"
t_eq "landing exactly on the pinned today" "2024-09-11" "$(qp_get sel.todayDate)"
t_eq "and taking the view to today's month" "2024/8" "$(qp_get sel.todayView)"
t_eq "today is day 255 of 2024" "255" "$(qp_get sel.todayDoy)"
t_eq "and is visible in the grid" "1" "$(qp_get sel.todayInGrid)"
t_eq "no assertion anywhere read the real clock" "true" "$(qp_get sel.noClockRead)"
t_eq "the signal count matches the number of log entries" "true" "$(qp_get recap.selCountMatches)"

# ---------------------------------------------------------------------------
# stepMonth
# ---------------------------------------------------------------------------

t_section "stepMonth coalesces inputs received during an active slide"
t_eq "the slide duration is the 120ms token" "120" "$(qp_get st.slideMs)"
t_eq "a fresh calendar is on September 2024" "2024/8" "$(qp_get st.a.before)"
t_eq "one stepMonth(1) moves to October immediately" "2024/9" "$(qp_get st.a.after1)"
t_eq "and puts the component into the sliding state" "true" "$(qp_get st.a.sliding)"
t_eq "queued deltas wait until the current transition settles" "2024/9" "$(qp_get st.a.afterSecondCall)"
t_eq "the third step is queued too" "2024/9" "$(qp_get st.a.afterThirdCall)"
t_eq "the backward year jump is accumulated, not applied mid-slide" "2024/9" "$(qp_get st.a.afterYearJump)"
t_eq "zero is ignored without changing the queued delta" "2024/9" "$(qp_get st.a.afterZeroDelta)"
t_eq "the net queued delta is -10 months" "-10" "$(qp_get st.a.pendingDelta)"
t_eq "the queued delta is applied when the slide settles" "2023/11" "$(qp_get st.a.afterQueued)"
t_eq "the pending delta is cleared after it is applied" "0" "$(qp_get st.a.pendingAfter)"
t_eq "rapid three forward steps coalesce into two additional months" "2024/11" "$(qp_get st.rapid.afterCoalesced)"
t_eq "the rapid calendar clears its pending delta" "0" "$(qp_get st.rapid.pendingAfter)"
# A separate calendar that has no queued delta can step again after settling.
t_eq "after the slide finishes the guard is released" "false" "$(qp_get st.b.sliding)"
t_eq "so stepMonth(-1) lands, back to August" "2024/7" "$(qp_get st.b.afterMinus1)"
t_eq "and re-arms the slide for the next one" "true" "$(qp_get st.b.slidingDuring)"
t_eq "so a settled calendar really does step" "true" "$(qp_get st.b.worked)"

t_section "stepping across a year boundary rolls the year"
# This is the path the library is actually asked for: stepMonth() calls
# CalendarLib.stepMonth, which builds new Date(year, month + delta, 1) and so
# handles the rollover the way the direct viewMonth assignment does not.
t_eq "the calendar starts on December 2024" "2024/11" "$(qp_get st.c.before)"
t_eq "with no slide in flight" "false" "$(qp_get st.c.sliding)"
t_eq "one step forward gives January 2025" "2025/0" "$(qp_get st.c.after)"
t_eq "month AND year both rolled" "true" "$(qp_get st.c.rolledToNextYear)"
t_eq "the new grid is a full January" "31" "$(qp_get st.c.januaryLength)"
t_eq "reaching back into December 2024" "2024-12-30" "$(qp_get st.c.firstKey)"
t_eq "with 1 January present and correct" "2025-01-01" "$(qp_get st.c.jan1Key)"
t_eq "and no gap across the boundary" "yes" "$(qp_get st.c.consecutive)"
t_eq "and no repeated key" "42" "$(qp_get st.c.unique)"
t_eq "stepping back from January 2024 gives December 2023" "2023/11" "$(qp_get st.d.after)"
t_eq "month AND year both rolled back" "true" "$(qp_get st.d.rolledToPrevYear)"
t_eq "and that December is complete" "31" "$(qp_get st.d.decemberLength)"
t_eq "with no gap" "yes" "$(qp_get st.d.consecutive)"
t_eq "and no repeated key" "42" "$(qp_get st.d.unique)"

# ---------------------------------------------------------------------------
# FunctionGraph: sampling
# ---------------------------------------------------------------------------

t_section "FunctionGraph's documented defaults"
t_eq "the plot height" "150" "$(qp_get g.graphH)"
t_eq "the x domain, lower" "-10" "$(qp_get g.xMin)"
t_eq "the x domain, upper" "10" "$(qp_get g.xMax)"
t_eq "fill mode is off by default" "false" "$(qp_get g.fillHeight)"
t_eq "the header is on by default" "true" "$(qp_get g.showHeader)"
t_eq "the implicit width" "280" "$(qp_get g.implicitWidth)"
t_eq "x^2 samples into a usable array" "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get g.sample.ok)"
t_eq "with no NaN and no Infinity" "280/0/0" "$(qp_get g.sample.counts)"
t_eq "one sample per requested column" "280" "$(qp_get g.sample.len)"
t_eq "and the wrapper handed FuncLib exactly its own properties" "true" "$(qp_get g.wrapsLib)"
t_eq "the same call into the library gives the same answer" \
  "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get g.sampleOkFromLib)"
t_eq "a sine over the default domain is all finite" "yes(len=280,finite=280,nan=0,valid=280)" \
  "$(qp_get g.sin.ok)"
t_eq "and its auto-fitted range brackets +/-1" "true" "$(qp_get g.sin.brackets)"

t_section "the sample count is per pixel column, and clamped at both ends"
t_eq "an item 420px tall still samples 280 columns" "280" "$(qp_get g.tall.sampleN)"
t_eq "a 12px-tall plot box still samples 280 columns" "280" "$(qp_get g.short.sampleN)"
t_eq "so graphH does not move the sample count" "true" "$(qp_get g.heightIndependentOfSampleN)"
t_eq "a 12px plot box is that much shorter overall" "35" "$(qp_get g.short.implicitHeight)"
t_eq "a 420px item still reports 173, because graphH sizes the plot" "173" "$(qp_get g.tall.implicitHeight)"
# _sampleN = max(80, min(300, round(graphBox.width || root.width || 240)))
# (FunctionGraph.qml:78). graphBox is anchored to the item, so the count is
# driven by width and nothing else.
t_eq "width 0 falls through both operands to the 240 default" "240" "$(qp_get cl.zeroWidth)"
t_eq "and really produces 240 samples, not 0" "240" "$(qp_get cl.zeroWidth.len)"
t_eq "all of them usable" "yes(len=240,finite=240,nan=0,valid=240)" "$(qp_get cl.zeroWidth.ok)"
t_eq "a 12px-wide box clamps UP to the 80 floor" "80" "$(qp_get cl.narrow12)"
t_eq "and really produces 80 samples" "80" "$(qp_get cl.narrow.len)"
t_eq "79px clamps up too" "80" "$(qp_get cl.w79)"
t_eq "80px is exactly the floor" "80" "$(qp_get cl.w80)"
t_eq "300px is exactly the ceiling" "300" "$(qp_get cl.w300)"
t_eq "301px clamps down to the ceiling" "300" "$(qp_get cl.w301)"
t_eq "and really produces 300 samples" "300" "$(qp_get cl.w301.len)"
t_eq "5000px clamps down as well" "300" "$(qp_get cl.w5000)"
t_eq "with 300 samples, not 5000" "300" "$(qp_get cl.huge.len)"
t_eq "so the floor holds" "true" "$(qp_get cl.atLeast80)"
t_eq "and so does the ceiling" "true" "$(qp_get cl.atMost300)"
t_eq "the zero-width fallback is the documented 240" "true" "$(qp_get cl.fallsBackTo240)"

t_section "and the count is stable across event-loop turns"
t_eq "280 on the first read" "280" "$(qp_get st.count.a)"
t_eq "280 on the second" "280" "$(qp_get st.count.b)"
t_eq "280 on the third" "280" "$(qp_get st.count.c)"
t_eq "a narrow graph is 80 on both reads" "80/80" \
  "$(printf '%s/%s' "$(qp_get st.count.narrow.a)" "$(qp_get st.count.narrow.b)")"
t_eq "a wide graph is 300 on both reads" "300/300" \
  "$(printf '%s/%s' "$(qp_get st.count.huge.a)" "$(qp_get st.count.huge.b)")"
t_eq "so the count is derived from the settled width, not the snapshot" "true" \
  "$(qp_get st.matchesWidth.280)"
t_eq "including the zero-width fallback" "true" "$(qp_get st.matchesWidth.zero)"
t_eq "and the clamped-down case" "true" "$(qp_get st.matchesWidth.301)"
t_eq "the plot box is non-empty in both directions" "true" "$(qp_get st.plotBoxNonEmpty)"
t_note "graphBox is a file-private id inside FunctionGraph.qml, so its own width/height cannot be read from outside the component. _sampleN (which is derived from graphBox.width) and implicitHeight (which is derived from graphBox.height in fixed mode) are the observable stand-ins, and both are asserted above. The Canvas's own painted/available state is equally unreachable; see the skips at the end of the suite."

t_section "the header and the fill mode are honest about their size"
# In fixed mode implicitHeight is the header block plus Ui.s plus graphH, so
# turning the header off leaves exactly graphH - which is the only way to read
# graphBox.height through a public property.
t_eq "with the header, 150 + a 23px header block" "173" "$(qp_get g.headerOn.implicitHeight)"
t_eq "without it, exactly the plot height" "150" "$(qp_get g.headerOff.implicitHeight)"
t_eq "so the header block is 23px" "23" "$(qp_get g.headerBlock)"
t_eq "and hiding the header removes the whole block, margin included" "true" \
  "$(qp_get g.headerIsThemeless)"
# FunctionGraph.qml:36-43: in fill mode it reports max(80, graphH) as a
# resting estimate rather than the live box height, because reporting the live
# height would close height -> implicitHeight -> height.
t_note "FunctionGraph.qml:36-43 reports a resting estimate (max(80, graphH) + the header block) in fill mode, deliberately not the live plot-box height, to avoid a binding loop. The consequence, asserted here, is that implicitHeight in fill mode is IDENTICAL for a 400px host and a 0px host and identical to fixed mode - so the 80px floor in graphBox.height (FunctionGraph.qml:151) cannot be observed through any public property."
t_eq "a 400px fill host reports the resting estimate" "173" "$(qp_get g.fill400.implicitHeight)"
t_eq "and a fill host with no explicit height reports the same" "173" "$(qp_get g.fill0.implicitHeight)"
t_eq "so the estimate does not track the host" "true" "$(qp_get g.fillIndependent)"
t_eq "and it matches fixed mode exactly" "true" "$(qp_get g.fillEqualsFixed)"

# ---------------------------------------------------------------------------
# FunctionGraph: degenerate bodies and domains
# ---------------------------------------------------------------------------

t_section "degenerate bodies: nothing to plot, and nothing thrown"
# Every one of these comes back null - a null sample, which the painter handles
# by drawing the grid and no curve (FunctionGraph.qml:201-203, :263). The
# assertion is "the sample is null", not a particular count.
t_eq "an empty body yields no sample" "null" "$(qp_get d.empty.ok)"
t_eq "and _sample really is null" "true" "$(qp_get d.empty.isNull)"
t_eq "a constant expression, which is not a function of x" "null" "$(qp_get d.const.ok)"
t_eq "yields no sample" "true" "$(qp_get d.const.isNull)"
t_eq "an unknown word after the variable" "null" "$(qp_get d.chat.ok)"
t_eq "yields no sample" "true" "$(qp_get d.chat.isNull)"
t_eq "a half-typed expression" "null" "$(qp_get d.incomplete.ok)"
t_eq "yields no sample" "true" "$(qp_get d.incomplete.isNull)"
t_eq "a division by zero literal" "null" "$(qp_get d.zeroDiv.ok)"
t_eq "yields no sample rather than an all-Infinity array" "true" "$(qp_get d.zeroDiv.isNull)"
# The host is documented to pass the STRIPPED body (FunctionGraph.qml:11-12)
# and sampleFunction compiles its argument directly, without stripBody. So the
# prefixes the parser itself knows how to remove are unreachable here.
t_note "FunctionGraph.qml:11-12 says the host sets 'the stripped plottable body', and FuncLib.sampleFunction really does call compileBody on its argument without stripBody. So a raw 'y = x^2' - a shape the parser's own stripBody handles - samples to null and the graph renders an empty viewport, with no error anywhere. ClipboardPreview strips first, so this is a contract, not a bug; pinned so that a host which stops stripping is caught here."
t_eq "an unstripped 'y = x^2' body yields no sample" "null" "$(qp_get d.prefixed.ok)"
t_eq "even though FuncLib can parse that query" "true" "$(qp_get d.lib.prefixedIsValid)"
t_eq "a bare 'x' IS sampled, because that is the sampler's job" \
  "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get d.bareX.ok)"
t_eq "with every column finite" "280/0/0" "$(qp_get d.bareX.counts)"

t_section "degenerate domains: reversed, zero-width, and NaN"
# FuncLib.sampleFunction returns null when !(xMax > xMin) (FuncLib.js:439),
# which covers equal, reversed AND any NaN endpoint - the guard is a single
# comparison, so there is no way to slip an empty or reversed domain past it.
t_eq "an equal-ended domain yields no sample" "null" "$(qp_get d.eqDomain.ok)"
t_eq "with the endpoints it was given" "3/3" \
  "$(printf '%s/%s' "$(qp_get d.eqDomain.xMin)" "$(qp_get d.eqDomain.xMax)")"
t_eq "a reversed domain yields no sample" "null" "$(qp_get d.revDomain.ok)"
t_eq "with the endpoints it was given, un-swapped" "5/-5" \
  "$(printf '%s/%s' "$(qp_get d.revDomain.xMin)" "$(qp_get d.revDomain.xMax)")"
t_eq "a NaN domain yields no sample" "null" "$(qp_get d.nanMin.ok)"
t_eq "and the NaN really is on xMin" "true" "$(qp_get d.nanMin.xMinIsNaN)"

t_section "degenerate functions: poles, and NaN kept as NaN"
# FuncLib keeps a non-finite sample as NaN so the painter can break the path
# at an asymptote (FuncLib.js:429-433, :451-459; FunctionGraph.qml:278-282
# turns a NaN into a pen-up). So the property that matters is NOT "every
# sample is finite" - it is that no Infinity survives into ys, that the
# non-finite entries are exactly NaN, and that the auto-fitted range is still
# finite and ordered so py() never divides by zero.
t_note "The task brief for this suite suggested asserting 'the sample is empty or every entry is finite' for the degenerate bodies. That is not the component's contract and asserting it would be asserting a bug: FuncLib.js:429-433 and :451-459 deliberately keep non-finite samples as NaN so FunctionGraph.qml:278-282 can break the path at an asymptote instead of drawing a vertical streak. What is asserted instead, and what actually matters, is: no entry is ever +/-Infinity, every non-finite entry is exactly NaN, ys.length equals the requested count, yMin/yMax are finite with yMax > yMin, and valid > 0."
t_eq "sqrt(x) over [-10, 10] samples 280 columns" "280" "$(qp_get d.sqrt.len)"
t_eq "half of them are NaN - the negative half" "140/140/0" "$(qp_get d.sqrt.counts)"
t_eq "and the sample is still usable" "yes(len=280,finite=140,nan=140,valid=140)" "$(qp_get d.sqrt.ok)"
t_eq "its auto-fitted range is finite and ordered" "true" "$(qp_get d.sqrt.rangeFinite)"
t_eq "and does not dip below the real square root" "true" "$(qp_get d.sqrt.rangeNonNegative)"
t_eq "sqrt over a domain with no non-negative x yields no sample" "null" "$(qp_get d.sqrtNeg.ok)"
t_eq "because nothing is finite" "true" "$(qp_get d.sqrtNeg.isNull)"
t_eq "log(x) over [-10, 10] also has 140 NaN columns" "140/140/0" "$(qp_get d.log.counts)"
t_eq "and its range is finite and ordered" "true" "$(qp_get d.log.rangeFinite)"
t_eq "the -Infinity from log(0) did not survive into ys" "0" \
  "$(qp_get d.log.counts | awk -F/ '{print $3}')"
t_eq "so the sample is usable" "yes(len=280,finite=140,nan=140,valid=140)" "$(qp_get d.log.ok)"
# 1/x is the interesting one: over [-10, 10] the sample lands on x = 0 only
# when (count - 1) is divisible by 20, so 280 columns miss the pole and 281
# columns hit it exactly once. The one column must be NaN, not Infinity.
t_note "1/x over the default [-10, 10] domain samples x = 0 exactly when the column count makes 20*i/(n-1) land on an integer, i.e. when n-1 is divisible by 20. So the default 280 columns MISS the pole and produce an all-finite array, while 281 columns hit it exactly once. Both are correct; the point pinned here is that the pole column becomes NaN (a pen-up) and never Infinity."
t_eq "280 columns miss the 1/x pole entirely" "280/0/0" "$(qp_get d.recip280.counts)"
t_eq "and the sample is usable" "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get d.recip280.ok)"
t_eq "281 columns hit it exactly once" "280/1/0" "$(qp_get d.recip281.counts)"
t_eq "as a NaN, not an Infinity" "yes(len=281,finite=280,nan=1,valid=280)" "$(qp_get d.recip281.ok)"
t_eq "so 281 columns and 280 valid samples" "true" "$(qp_get d.recip281.nanIsPole)"
t_eq "tan(x) survives its own poles via the 1e6 spike cutoff" \
  "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get d.tan.ok)"
t_eq "with every column finite" "280/0/0" "$(qp_get d.tan.counts)"
# A zero plot height is a host mistake, but it must not reach the sampler.
t_eq "a zero plot height does not change the sample count" "280" "$(qp_get d.zeroH.sampleN)"
t_eq "nor empty the sample" "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get d.zeroH.ok)"
t_eq "it only removes the plot box" "23" "$(qp_get d.zeroH.implicitHeight)"
t_eq "leaving a finite, non-collapsed height" "true" "$(qp_get d.zeroH.heightFinite)"

t_section "the same degenerate inputs, straight through FuncLib"
# Checked against the library directly to prove the wrapper is a pass-through
# rather than a filter; wide domains are also exercised through a component in
# the bounded-grid characterization at the end of this suite.
t_eq "x^2 over +/-1e6 has every sample above the 1e6 cutoff" "null" "$(qp_get lib.hugeSpan.x2)"
t_eq "so it yields no sample at all" "true" "$(qp_get lib.hugeSpan.x2IsNull)"
t_eq "while sin over the same span is all finite" "yes(len=280,finite=280,nan=0,valid=280)" \
  "$(qp_get lib.hugeSpan.sin)"
t_eq "with all 280 columns valid" "280" "$(qp_get lib.hugeSpan.sinCount)"
t_eq "and the array is still 280 long" "true" "$(qp_get lib.hugeSpan.spanOk)"
t_eq "an infinite domain yields no sample" "null" "$(qp_get lib.infDomain)"
t_eq "because -Infinity + Infinity never produces a number" "true" "$(qp_get lib.infDomainIsNull)"
t_eq "a NaN lower bound yields no sample" "null" "$(qp_get lib.nanMin)"
t_eq "a NaN upper bound yields no sample" "null" "$(qp_get lib.nanSpan)"
t_eq "an equal-ended domain yields no sample" "null" "$(qp_get lib.eqDomain)"
t_eq "a reversed domain yields no sample" "null" "$(qp_get lib.revDomain)"
t_eq "a 1e-9-wide domain still yields a usable sample" \
  "yes(len=280,finite=280,nan=0,valid=280)" "$(qp_get lib.tinyDomain)"
t_eq "an empty body yields no sample" "null" "$(qp_get lib.empty)"
t_eq "a constant yields no sample" "null" "$(qp_get lib.const)"
t_eq "an unknown word yields no sample" "null" "$(qp_get lib.xchat)"
t_eq "a half-typed expression yields no sample" "null" "$(qp_get lib.incomplete)"
t_eq "a malformed one yields no sample" "null" "$(qp_get lib.syntax)"
# FuncLib's own count clamp is [2, 400] (FuncLib.js:437) with a default of
# 120, which is wider than the wrapper's [80, 300] - so the two can never
# disagree about the length for any width a host can set.
t_eq "a count of 0 falls back to the library's 120" "120/0/0" "$(qp_get lib.nZero)"
t_eq "a NaN count does too" "120/0/0" "$(qp_get lib.nNaN)"
t_eq "a count of 500 clamps to 400" "400/0/0" "$(qp_get lib.nOver)"
t_eq "a count of 1 clamps up to 2" "2/0/0" "$(qp_get lib.nUnder)"
t_eq "the library's floor is 2 columns" "2" "$(qp_get lib.nAtMin)"
t_eq "and its ceiling 400" "400" "$(qp_get lib.nAtMax)"
t_eq "and an absent count defaults to 120" "120" "$(qp_get lib.nDefault)"

# ---------------------------------------------------------------------------
# _niceStep
# ---------------------------------------------------------------------------

t_section "_niceStep: positive and finite for every span, including degenerate"
# _niceStep is the axis-step maths (FunctionGraph.qml:86-93). It returns a
# positive finite step even when the span is degenerate or non-finite, so the
# horizontal grid loop cannot divide by zero or feed an invalid stride.
t_eq "a 1e-9 span gives a positive finite nice step" "2e-10|pos|fin|nice" "$(qp_get ns.tiny)"
t_eq "a span of 1" "0.2|pos|fin|nice" "$(qp_get ns.one)"
t_eq "a span of 1000" "200|pos|fin|nice" "$(qp_get ns.thousand)"
t_eq "a span of 0 falls back to 1" "1|pos|fin|nice" "$(qp_get ns.zero)"
t_eq "a negative span falls back to 1 too" "1|pos|fin|nice" "$(qp_get ns.negative)"
t_eq "and so does NaN" "1|pos|fin|nice" "$(qp_get ns.nan)"
t_eq "a span of 0.5" "0.1|pos|fin|nice" "$(qp_get ns.half)"
t_eq "a span of 10" "2|pos|fin|nice" "$(qp_get ns.ten)"
t_eq "a span of 100" "20|pos|fin|nice" "$(qp_get ns.hundred)"
t_eq "a span of 1e6" "200000|pos|fin|nice" "$(qp_get ns.million)"
t_eq "so all three degenerate spans give a positive step" "true" \
  "$(qp_get ns.degeneratePositive)"
t_eq "and a finite one" "true" "$(qp_get ns.degenerateFinite)"
t_eq "an infinite span falls back to a positive finite step" \
  "1|pos|fin|nice" "$(qp_get ns.infinite)"

t_section "_niceStep is monotonic, and always a nice 1/2/5 x 10^k"
t_eq "it never decreases as the span grows" "true" "$(qp_get nsn.monotonic)"
t_eq "and every step in a 17-decade sweep is nice" "true" "$(qp_get nsn.allNice)"
t_contains "a span of 0.1 gives 0.02" "0.1=0.02," "$(qp_get nsn.series)"
t_contains "a span of 1 gives 0.2" "1=0.2," "$(qp_get nsn.series)"
t_contains "a span of 10 gives 2" "10=2," "$(qp_get nsn.series)"
t_contains "a span of 100 gives 20" "100=20," "$(qp_get nsn.series)"
t_contains "a span of 1000 gives 200" "1000=200," "$(qp_get nsn.series)"
t_contains "a span of 1e6 gives 200000" "1000000=200000," "$(qp_get nsn.series)"
t_eq "the step never exceeds the span it divides" "true" "$(qp_get nsn.stepUnderSpan)"
t_eq "and leaves at least one division across the span" "true" "$(qp_get nsn.atLeastTwoSteps)"
# The painter asks for Math.ceil(y0/step) .. Math.floor(y1/step), so a
# non-nice step shows up as a lopsided grid rather than a crash. Over the
# default sine the auto-fitted range is about [-1.34, 1.34], i.e. 2.68 wide.
t_eq "so the default sine's range gets a step of 0.5" "0.5" "$(qp_get nsn.forSineRange)"

# ---------------------------------------------------------------------------
# Nothing degenerate escapes into a geometry property
# ---------------------------------------------------------------------------

t_section "no NaN or Infinity reaches a geometry property in either component"
# A NaN in width/height makes Qt drop the whole item, so this is the check
# that a hostile input degrades to a plain wrong number rather than to a
# component that has collapsed to nothing on screen.
t_eq "23 calendar geometry and derived values checked" "23" "$(qp_get fin.cal.count)"
t_eq "none of them is non-finite" "0" "$(qp_get fin.cal.badCount)"
t_eq "and every cell's numeric fields are finite" "0" "$(qp_get fin.cells.badCount)"
t_eq "with a well-formed key on all 42" "true" "$(qp_get fin.cells.allFinite)"
t_eq "18 graphs checked, across bodies, domains and sizes" "18" "$(qp_get fin.graphs.count)"
t_eq "none of them has a non-finite size, DPR or sample range" "0" "$(qp_get fin.graphs.badCount)"
t_eq "so nothing collapsed" "true" "$(qp_get fin.graphs.allFinite)"
t_eq "a NaN xMin is the one NaN that gets through" "true" "$(qp_get fin.nanMinIsNaN)"
t_eq "and the sampler's own guard stops it there" "true" "$(qp_get fin.nanMinSampleNull)"

# ---------------------------------------------------------------------------
# The nine theme-derived colours
# ---------------------------------------------------------------------------

t_section "the palette is read through two different doors, and says so"
# Theme.color() and Ui.solid() hand back a bare #rrggbb; Ui.tint() wraps the
# same value with an alpha and comes back #aarrggbb. The alpha channel is a
# Ui.tint ARGUMENT, not a theme value, so it is exact - only the RGB channels
# are theme-dependent and those are deliberately not asserted.
t_eq "nine colour properties in total" "9" "$(qp_get col.count)"
t_eq "none of them is empty" "true" "$(qp_get col.nonEmpty)"
t_eq "all nine are a well-formed colour" "true" "$(qp_get col.allWellFormed)"
t_eq "the four solid ones are bare rgb triples" "true" "$(qp_get col.solidsAreSixDigit)"
t_eq "the mat (background_1)" "solid6" "$(qp_get col.bg)"
t_eq "the plot fill (background_0)" "solid6" "$(qp_get col.plotBg)"
t_eq "the border (background_3)" "solid6" "$(qp_get col.border)"
t_eq "the curve (accent)" "solid6" "$(qp_get col.curve)"
t_eq "the minor grid is tinted at 0.45" "argb8/115" "$(qp_get col.minor)"
t_eq "the major grid is tinted at 0.95" "argb8/242" "$(qp_get col.major)"
t_eq "the axis is tinted at 0.55" "argb8/140" "$(qp_get col.axis)"
t_eq "the range labels are the same tint of the same key" "argb8/140" "$(qp_get col.label)"
t_eq "so the label colour IS the axis colour" "true" "$(qp_get col.labelIsAxis)"
t_eq "0.45 scaled to 0..255" "true" "$(qp_get col.alpha45)"
t_eq "0.95 scaled to 0..255" "true" "$(qp_get col.alpha95)"
t_eq "0.55 scaled to 0..255" "true" "$(qp_get col.alpha55)"
# Qt.alpha short-circuits at a = 1, so the fully-opaque title comes back as a
# bare 6-digit colour instead of #ffrrggbb. Worth pinning: an assertion that
# "every Ui.tint result is 8-digit" would fail on this one for a good reason.
t_note "FunctionGraph._title is Ui.tint(\"foreground_0\", 1), and Qt.alpha short-circuits at a = 1, so it returns the bare #rrggbb rather than #ffrrggbb (col.title). The other four tinted properties really are #aarrggbb. Pinned because a test that assumed all Ui.tint results carry an alpha channel would fail here for a reason that is not a bug."
t_eq "so the title is a bare opaque colour" "solid6" "$(qp_get col.titleShape)"
t_eq "with no alpha channel for argb8Alpha to read" "-1" "$(qp_get col.titleAlpha)"
t_eq "and is exactly Ui.solid of the same key" "true" "$(qp_get col.titleIsOpaque)"
t_eq "a tinted colour is not the same string as an untiled one" "true" "$(qp_get col.minorIsNot)"

# ---------------------------------------------------------------------------
# Run 2: wide and invalid domains are constructed through the real component.
# This must come last because qp_run replaces _QP_OUT.
# ---------------------------------------------------------------------------

t_section "wide and non-finite domains keep painting bounded"
t_eq "the default domain asks for 21 gridlines" "21" "$(qp_get lib.gridlines.default)"
t_eq "a zero-length domain asks for 1" "1" "$(qp_get lib.gridlines.zero)"
t_eq "the wide domain keeps grid density pixel-bounded" "true" "$(qp_get lib.gridlines.hugeBounded)"
t_eq "the x step stays finite for an infinite span" "true" "$(qp_get lib.gridlines.infiniteXStepFinite)"
t_eq "the y step falls back for an infinite span" "1" "$(qp_get lib.gridlines.infiniteStep)"

export VB_CG_WIDE=1e100
if qp_run "$PROBE" 40; then
  wide_outcome="finished"
else
  wide_outcome="failed"
fi
unset VB_CG_WIDE

t_eq "the huge finite domain completes the probe" "finished" "$wide_outcome"
t_eq "the wide-domain run built its graph" "yes" "$(qp_get wide.built)"
t_eq "and reported the domain it was given" "1e100" "$(qp_get mode.wideDomain)"
t_eq "gridline count remains bounded" "21" "$(qp_get wide.gridLines)"
t_eq "the infinite-domain graph is built" "true" "$(qp_get wide.infiniteBuilt)"
t_eq "its grid-step helper stays finite" "true" "$(qp_get wide.infiniteStepFinite)"
t_eq "and its sample is rejected" "true" "$(qp_get wide.infiniteSampleNull)"

# ---------------------------------------------------------------------------
# Not reachable headlessly. Recorded as coverage gaps, never as passes.
# ---------------------------------------------------------------------------

t_section "what this technique cannot reach"
t_skip "the MouseArea on a day cell (a real click on a real day)" \
  "QT_QPA_PLATFORM=offscreen has no compositor, so onClicked cannot be synthesised; daySelected is driven through selectDay(), which is the exact call the handler makes (Calendar.qml:325), but the handler's own mouse.button discrimination (left selects, right goes to today) is untested"
t_skip "the header chevron MouseAreas and the grid-background right-click" \
  "same reason: Calendar.qml:151-158, :174-181 and :268-272 are never entered"
t_skip "the wheel handler" \
  "onWheel is a mouse event; the onWheel -> stepMonth(+/-1) mapping and its direction (negative angleDelta.y steps forward) are unverified"
t_skip "Keys.onLeftPressed / RightPressed / UpPressed / DownPressed" \
  "synthetic key events are not delivered to an item without a window; the +/-1 and +/-12 month mapping is only covered through stepMonth() directly, not through the key handlers"
t_skip "the slide animation's in-flight position" \
  "gridHost.x and gridHost.opacity are file-private ids, so only the _sliding flag is observable - the probe can see that a slide started and that it finished, not where the grid was at 40ms"
t_skip "the month title text" \
  "monthTitle is a file-private id, so Qt.formatDate(new Date(viewYear, viewMonth, 1), 'MMMM yyyy') cannot be read back; the grid is asserted instead, and it is derived from the same two properties"
t_skip "rendered pixels of the plot" \
  "the Canvas is a file-private id, so Canvas.painted/available and the painted path are unreachable; what is asserted is everything the paint READS - the sample, the step, the colours and the box geometry - plus the cost of one real repaint in the characterisation run"
t_skip "the weekday labels' rendered text and the day numbers' rendered text" \
  "both live in Repeater delegates with file-private ids; the library expressions driving them (weekdayOrder, cell.day) are asserted directly instead"
t_skip "hover states" \
  "containsMouse needs a real pointer; the chevron/underline colour changes on hover and today are unverified"

t_summary

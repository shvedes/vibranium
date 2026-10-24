// Probe: the two wrappers that turn a tested library into pixels - the month
// grid (Calendar.qml) and the y=f(x) plot (FunctionGraph.qml).
//
// Both are thin over libraries that node already covers (CalendarLib.js,
// FuncLib.js), so the interesting question is not "does the maths work" but
// "does the QML wrapper compute the right thing FROM ITS OWN PROPERTIES, and
// does it stay consistent with the library across month boundaries and
// degenerate graph domains". A wrapper that drops a library result,
// mis-transforms it, or lets a NaN reach a geometry property is invisible to
// the node suites, and this is the file that catches it. So the probe imports
// the libraries itself and asserts wrapper-output == library-output for the
// same inputs, rather than only asserting the numbers.
//
// WHY A PUMP AND NOT A SNAPSHOT. Two reasons, and they are different.
//   * Calendar's month slide is a real 120ms (Ui.fastMs) animation behind a
//     one-in-flight flag, so "is the component still sliding, and does a
//     SECOND stepMonth land?" is not observable synchronously at all.
//   * FunctionGraph derives its sample count from `graphBox.width`, and
//     graphBox is anchored to the item, so _sampleN is only final after a
//     layout pass.
// So each phase reports and the next runs on a later event-loop turn, 40ms
// apart, and the stepMonth phases are spaced 160ms+ apart so they always
// clear the slide. Phase 1 additionally reports the Component.onCompleted
// value NEXT TO the settled one for every quantity that could plausibly have
// moved; on this host they agree, and that is asserted as a fact rather than
// assumed.
//
// DETERMINISM. Calendar defaults selectedDate AND today to `new Date()` and
// would make every date assertion a coin flip, so every instance below is
// constructed with an explicit fixed date. 2024 (a leap year) and 2023 (a
// common year) are both used on purpose: the leap-year day number is the
// classic thing a wrapper loses, so it is asserted at both year ends and on
// 29 February.
//
// NO REAL CLICKS. There is no compositor under QT_QPA_PLATFORM=offscreen, so
// MouseArea.onClicked cannot be synthesised. daySelected is driven through the
// component's own public functions - selectDay() and goToToday() - which are
// exactly what the MouseArea handlers call (Calendar.qml:325, :271, :324).
// What that does NOT cover is noted in the suite: the MouseArea itself, the
// hover colours, the wheel handler and the Keys handlers.
//
// Wide and non-finite x domains are exercised by a second probe run. The
// renderer chooses a nice grid interval from the plot width, so grid work is
// bounded by visible resolution; invalid domains paint the background and
// return without entering either axis loop.

pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell
import qs.common
import "common/ui/CalendarLib.js" as CalLib
import "common/math/FuncLib.js" as FuncLib

Item {
  id: root

  width: 760
  height: 520

  // A second run of this same probe, with VB_CG_WIDE set, builds one
  // wide-domain graph and reports its selected tick spacing.
  readonly property bool wideMode: String(Quickshell.env("VB_CG_WIDE") || "") !== ""

  property int phase: 0
  property int selCount: 0
  property string selLog: ""

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // ---- grid helpers ----------------------------------------------------
  // Shared summaries so every grid is measured the same way, and the
  // assertions can be "equal" instead of "looks right".

  function cellCount(c) { return c.cells.length }

  function keySetCount(c) {
    const seen = {}
    let dup = 0
    for (let i = 0; i < c.cells.length; i++) {
      if (seen[c.cells[i].key]) dup++
      seen[c.cells[i].key] = true
    }
    return c.cells.length - dup
  }

  // Consecutive-day check: a grid that silently drops or repeats a day at a
  // month or year boundary fails here. "yes" or "break@<index>".
  function consecutive(c) {
    for (let i = 1; i < c.cells.length; i++) {
      const a = c.cells[i - 1]
      const b = c.cells[i]
      const gap = Math.round(
        (new Date(b.year, b.month, b.day) - new Date(a.year, a.month, a.day)) / 86400000)
      if (gap !== 1) return "break@" + i + "(" + a.key + "->" + b.key + ")"
    }
    return "yes"
  }

  function countWhere(c, field, want) {
    let n = 0
    for (let i = 0; i < c.cells.length; i++) {
      if (Boolean(c.cells[i][field]) === want) n++
    }
    return n
  }

  function inMonthCount(c) { return countWhere(c, "inMonth", true) }

  // Index of the last row (0-based) that still holds a day of the viewed
  // month. 3 = a 4-week month, 4 = 5 weeks, 5 = 6 weeks, -1 = none.
  function lastInMonthRow(c) {
    let last = -1
    for (let i = 0; i < c.cells.length; i++) {
      if (c.cells[i].inMonth) last = Math.floor(i / 7)
    }
    return last
  }

  function rowInMonthMask(c, row) {
    let mask = ""
    for (let j = 0; j < 7; j++) mask += c.cells[row * 7 + j].inMonth ? "1" : "0"
    return mask
  }

  function selectedCount(c) {
    let n = 0
    for (let i = 0; i < c.cells.length; i++) {
      if (c.cells[i].key === c.selectedKey) n++
    }
    return n
  }

  function todayCount(c) {
    let n = 0
    for (let i = 0; i < c.cells.length; i++) if (c.cells[i].today) n++
    return n
  }

  function weekendCount(c) {
    let n = 0
    for (let i = 0; i < c.cells.length; i++) if (c.cells[i].weekend) n++
    return n
  }

  // The weekday of each cell in row 0, as one string. weekStart 1 must give
  // "1234560" (Mon..Sun) and weekStart 0 must give "0123456".
  function row0Weekdays(c) {
    let s = ""
    for (let j = 0; j < 7; j++) s += c.cells[j].weekday
    return s
  }

  // What the WEEKDAY LABELS are driven from: CalendarLib.weekdayOrder(), read
  // through the Repeater delegate (Calendar.qml:241). The wrapper passes
  // root.weekStart straight through, so the labels and the grid's first row
  // must agree - if the wrapper ever normalised weekStart for one and not the
  // other, this is where it shows.
  function labelOrder(c) {
    const order = CalLib.weekdayOrder(c.weekStart)
    let s = ""
    for (let j = 0; j < 7; j++) s += order[j]
    return s
  }

  function keysFromTo(c, a, b) {
    return c.cells[a].key + ".." + c.cells[b].key
  }

  function keyAt(c, i) { return c.cells[i].key }

  function monthOfKeyAt(c, i) { return c.cells[i].month }

  function yearOfKeyAt(c, i) { return c.cells[i].year }

  function inMonthAt(c, i) { return c.cells[i].inMonth }

  function todayAt(c, i) { return c.cells[i].today }

  // ---- sample helpers --------------------------------------------------
  // The property that matters for a plot over a hostile domain is NOT "every
  // sample is finite" - FuncLib deliberately keeps non-finite samples as NaN
  // so the painter can break the path at an asymptote (FuncLib.js:429-433,
  // 451-459, and FunctionGraph.qml:278-282 turns a NaN into a pen-up). The
  // property that matters is:
  //   1. no entry is ever +/-Infinity   (an Infinity y would make py() NaN
  //      and would poison the percentile range)
  //   2. every non-finite entry is exactly NaN
  //   3. ys.length equals the requested sample count
  //   4. yMin/yMax are finite and yMax > yMin, so py() never divides by 0
  //   5. valid > 0, i.e. there is something to draw at all
  // so that is what sampleOk() reports, as a single yes/no per case.

  function sampleOk(s) {
    if (s === null) return "null"          // nothing to plot: handled, painted as an empty grid
    if (!s || !s.ys) return "noArray"
    let inf = 0
    let other = 0
    let finite = 0
    let nan = 0
    for (let i = 0; i < s.ys.length; i++) {
      const y = s.ys[i]
      if (typeof y !== "number") { other++; continue }
      if (y === y) finite++
      else nan++
      if (y === Infinity || y === -Infinity) inf++
    }
    const rangeOk = isFinite(s.yMin) && isFinite(s.yMax) && s.yMax > s.yMin
    const countOk = s.ys.length > 0
    const validOk = s.valid > 0 && s.valid === finite
    if (inf > 0 || other > 0 || !rangeOk || !countOk || !validOk) {
      return "BAD(len=" + s.ys.length + ",fin=" + finite + ",nan=" + nan
        + ",inf=" + inf + ",other=" + other + ",valid=" + s.valid
        + ",rangeOk=" + rangeOk + ")"
    }
    return "yes(len=" + s.ys.length + ",finite=" + finite + ",nan=" + nan
      + ",valid=" + s.valid + ")"
  }

  // Just the numbers, for the "finite vs NaN" questions.
  function sampleCounts(s) {
    if (s === null) return "null"
    let finite = 0
    let nan = 0
    let inf = 0
    for (let i = 0; i < s.ys.length; i++) {
      const y = s.ys[i]
      if (y === Infinity || y === -Infinity) inf++
      else if (typeof y !== "number" || y !== y) nan++
      else finite++
    }
    return finite + "/" + nan + "/" + inf
  }

  // ---- alpha / colour shape -------------------------------------------

  function argb8Alpha(c) {
    const s = String(c)
    if (!/^#[0-9a-fA-F]{8}$/.test(s)) return -1
    return parseInt(s.slice(1, 3), 16)
  }

  function isSolid6(c) { return /^#[0-9a-fA-F]{6}$/.test(String(c)) }

  function colourShape(c) {
    const s = String(c)
    if (/^#[0-9a-fA-F]{8}$/.test(s)) return "argb8"
    if (/^#[0-9a-fA-F]{6}$/.test(s)) return "solid6"
    return "other:" + s
  }

  // ---- _niceStep helpers ----------------------------------------------

  // The mantissa of a step relative to its own power of ten. A "nice" step is
  // 1, 2, 5 or 10 x 10^k (FunctionGraph.qml:85-93).
  function stepMantissa(step) {
    if (!(step > 0) || !isFinite(step)) return "n/a"
    const mag = Math.pow(10, Math.floor(Math.log(step) / Math.LN10))
    const m = step / mag
    return (m === 1 || m === 2 || m === 5 || m === 10) ? "nice" : "NOTNICE:" + m
  }

  function stepReport(g, span) {
    const st = g._niceStep(span)
    return String(st) + "|" + (st > 0 ? "pos" : "NOTPOS") + "|" + (isFinite(st) ? "fin" : "NOTFIN")
      + "|" + stepMantissa(st)
  }

  // ---- Calendar instances ---------------------------------------------
  // Every one of these gets an explicit selectedDate AND today. Two years on
  // purpose: 2024 has 366 days, 2023 has 365.

  // Six-week month: September 2024 starts on a Sunday, so with weekStart 1 it
  // needs six leading/trailing rows and the last row is part September.
  Calendar { id: sep24; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  // Five-week month: June 2024 (Saturday start, 30 days) - the sixth row is
  // entirely July, and must be shown rather than dropped.
  Calendar { id: jun24; selectedDate: new Date(2024, 5, 15); today: new Date(2024, 5, 15) }
  // February in a leap year and in a common year.
  Calendar { id: feb24; selectedDate: new Date(2024, 1, 15); today: new Date(2024, 1, 15) }
  Calendar { id: feb23; selectedDate: new Date(2023, 1, 15); today: new Date(2023, 1, 15) }
  // February 2021 fits in four whole rows - the extreme of the fixed grid.
  Calendar { id: feb21; selectedDate: new Date(2021, 1, 15); today: new Date(2021, 1, 15) }
  // December 2024 rolls forward into January 2025.
  Calendar { id: dec24; selectedDate: new Date(2024, 11, 15); today: new Date(2024, 11, 15) }
  // January 2024 starts exactly on the weekStart, so it has no leading days;
  // with weekStart 0 it must gain one from the PREVIOUS December.
  Calendar { id: jan24; selectedDate: new Date(2024, 0, 15); today: new Date(2024, 0, 15) }
  Calendar { id: jan24sun; selectedDate: new Date(2024, 0, 15); today: new Date(2024, 0, 15); weekStart: 0 }
  Calendar { id: jan23; selectedDate: new Date(2023, 0, 15); today: new Date(2023, 0, 15) }
  // Today sitting in the trailing (next) month must still be marked once.
  Calendar { id: trailToday; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 9, 2) }
  // Today outside the grid entirely must mark nothing.
  Calendar { id: awayToday; selectedDate: new Date(2024, 8, 11); today: new Date(2025, 4, 17) }

  // weekStart out of range, in both directions. The property is `int`, so a
  // fractional or string value is a load-time QML type error, not something
  // the component can normalise - only integers reach the library.
  Calendar { id: ws7; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); weekStart: 7 }
  Calendar { id: wsNeg1; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); weekStart: -1 }
  Calendar { id: ws99; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); weekStart: 99 }
  Calendar { id: ws0; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); weekStart: 0 }
  Calendar { id: ws6; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); weekStart: 6 }

  // Out-of-range viewMonth, written straight to the public property.
  Calendar { id: vm12; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); viewMonth: 12 }
  Calendar { id: vmNeg1; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); viewMonth: -1 }
  // In-range extremes, for contrast.
  Calendar { id: vm11; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); viewMonth: 11 }
  Calendar { id: vm0; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11); viewMonth: 0 }

  // Date-mapping instances: one per fixed day of interest.
  Calendar { id: dJan1Leap; selectedDate: new Date(2024, 0, 1); today: new Date(2024, 0, 1) }
  Calendar { id: dDec31Leap; selectedDate: new Date(2024, 11, 31); today: new Date(2024, 11, 31) }
  Calendar { id: dDec31Common; selectedDate: new Date(2023, 11, 31); today: new Date(2023, 11, 31) }
  Calendar { id: dFeb29Leap; selectedDate: new Date(2024, 1, 29); today: new Date(2024, 1, 29) }
  Calendar { id: dMar1Common; selectedDate: new Date(2023, 2, 1); today: new Date(2023, 2, 1) }
  Calendar { id: dFeb28Leap; selectedDate: new Date(2024, 1, 28); today: new Date(2024, 1, 28) }
  Calendar { id: dJan5; selectedDate: new Date(2024, 0, 5); today: new Date(2024, 0, 5) }
  Calendar { id: dDec5; selectedDate: new Date(2024, 11, 5); today: new Date(2024, 11, 5) }

  // A calendar whose view binding is still live (nothing has assigned
  // viewYear/viewMonth yet).
  Calendar { id: mover; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  // One whose view has already been assigned by stepMonth, so the binding is
  // gone (Calendar.qml:28-30 documents that takeover).
  Calendar { id: brokenBinding; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }

  // Selection driver.
  Calendar { id: sel; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  // goToToday driver: selection is deliberately elsewhere from today.
  Calendar { id: gotoCal; selectedDate: new Date(2023, 1, 3); today: new Date(2024, 8, 11) }

  // Four stepMonth drivers, one per phase, so the 120ms slide guard never
  // makes one test's slide swallow the next test's call.
  Calendar { id: stA; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  Calendar { id: stB; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  Calendar { id: stRapid; selectedDate: new Date(2024, 8, 11); today: new Date(2024, 8, 11) }
  Calendar { id: stC; selectedDate: new Date(2024, 11, 15); today: new Date(2024, 11, 15) }
  Calendar { id: stD; selectedDate: new Date(2024, 0, 15); today: new Date(2024, 0, 15) }

  Connections {
    target: sel
    function onDaySelected(d) {
      root.selCount = root.selCount + 1
      root.selLog = root.selLog + (root.selLog === "" ? "" : ",") + CalLib.keyForDate(d)
    }
  }
  Connections {
    target: gotoCal
    function onDaySelected(d) {
      root.selCount = root.selCount + 1
      root.selLog = root.selLog + (root.selLog === "" ? "" : ",") + CalLib.keyForDate(d)
    }
  }

  // ---- FunctionGraph instances ----------------------------------------

  // Fixed defaults. In Qt 6.11 an Item's width/height default to its implicit
  // size, so a FunctionGraph with no explicit width still measures
  // implicitWidth (280) and the sample count follows that.
  FunctionGraph { id: gDef; funcBody: "x^2" }
  FunctionGraph { id: gSin; width: 280; funcBody: "sin(x)" }
  // width: 0 exercises the `|| 240` fallback in the sample-count expression
  // (FunctionGraph.qml:78) - the divide-by-a-zero-width-box guard.
  FunctionGraph { id: gZeroW; width: 0; funcBody: "x^2" }
  FunctionGraph { id: gNarrow; width: 12; funcBody: "x^2" }
  FunctionGraph { id: gW79; width: 79; funcBody: "x^2" }
  FunctionGraph { id: gW80; width: 80; funcBody: "x^2" }
  FunctionGraph { id: gW300; width: 300; funcBody: "x^2" }
  FunctionGraph { id: gW301; width: 301; funcBody: "x^2" }
  FunctionGraph { id: gHuge; width: 5000; funcBody: "x^2" }
  // 281 columns is the one sample count that lands exactly on x = 0 over
  // [-10, 10], which is how 1/x gets sampled through its pole.
  FunctionGraph { id: gRecip281; width: 281; funcBody: "1/x" }
  FunctionGraph { id: gRecip280; width: 280; funcBody: "1/x" }
  // Same width, different height: the sample count must not move.
  FunctionGraph { id: gTall; width: 280; height: 420; funcBody: "x^2" }
  FunctionGraph { id: gShort; width: 280; graphH: 12; funcBody: "x^2" }
  FunctionGraph { id: gNoHeader; width: 280; showHeader: false; funcBody: "sin(x)" }
  FunctionGraph { id: gFill400; width: 280; height: 400; fillHeight: true; funcBody: "x^2" }
  FunctionGraph { id: gFill0; width: 280; fillHeight: true; funcBody: "x^2" }
  FunctionGraph { id: gZeroH; width: 280; graphH: 0; funcBody: "x^2" }
  // Degenerate bodies and domains. All of these are inside the default
  // [-10, 10] domain except where noted, so none of them can trip the
  // grid-loop blow-up described at the top of this file.
  FunctionGraph { id: gEmpty; width: 280; funcBody: "" }
  FunctionGraph { id: gConst; width: 280; funcBody: "2+2" }
  FunctionGraph { id: gChat; width: 280; funcBody: "x chat" }
  FunctionGraph { id: gIncomplete; width: 280; funcBody: "x+" }
  FunctionGraph { id: gPrefixed; width: 280; funcBody: "y = x^2" }
  FunctionGraph { id: gBareX; width: 280; funcBody: "x" }
  FunctionGraph { id: gEqDomain; width: 280; funcBody: "x^2"; xMin: 3; xMax: 3 }
  FunctionGraph { id: gRevDomain; width: 280; funcBody: "x^2"; xMin: 5; xMax: -5 }
  FunctionGraph { id: gNaNMin; width: 280; funcBody: "x^2"; xMin: Math.sqrt(-1) }
  FunctionGraph { id: gSqrt; width: 280; funcBody: "sqrt(x)" }
  FunctionGraph { id: gSqrtNeg; width: 280; funcBody: "sqrt(x)"; xMin: -10; xMax: -1 }
  FunctionGraph { id: gLog; width: 280; funcBody: "log(x)" }
  FunctionGraph { id: gTan; width: 280; funcBody: "tan(x)" }
  FunctionGraph { id: gZeroDiv; width: 280; funcBody: "x/0" }
  // Wide and non-finite graph fixtures are built only by the second run.
  Loader {
    id: wideLoader
    active: root.wideMode
    asynchronous: false
    sourceComponent: Component {
      FunctionGraph {
        width: 280
        funcBody: "sin(x)"
        xMin: -Math.abs(Number(Quickshell.env("VB_CG_WIDE")))
        xMax: Math.abs(Number(Quickshell.env("VB_CG_WIDE")))
      }
    }
  }
  Loader {
    id: infiniteLoader
    active: root.wideMode
    asynchronous: false
    sourceComponent: Component {
      FunctionGraph { width: 280; funcBody: "sin(x)"; xMin: -Infinity; xMax: Infinity }
    }
  }

  // ---- the event loop --------------------------------------------------
  // 40ms so that four phases (160ms) clear Calendar's 120ms month slide
  // (Ui.fastMs) - see the stepMonth phases below.

  Timer {
    id: pump
    interval: 40
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      if (root.phase === 1) p1Settle()
      else if (root.phase === 2) p2Constants()
      else if (root.phase === 3) p3Identities()
      else if (root.phase === 4) p4GridSixWeek()
      else if (root.phase === 5) p5GridFiveWeek()
      else if (root.phase === 6) p6GridFebruary()
      else if (root.phase === 7) p7GridBoundaries()
      else if (root.phase === 8) p8GridEdges()
      else if (root.phase === 9) p9ViewMonthRange()
      else if (root.phase === 10) p10DateMapping()
      else if (root.phase === 11) p11ViewBinding()
      else if (root.phase === 12) p12WeekStart()
      else if (root.phase === 13) p13SelectOne()
      else if (root.phase === 14) p14StepGuard()
      else if (root.phase === 15) p15SelectMore()
      else if (root.phase === 16) p16GraphDefaults()
      else if (root.phase === 17) p17GraphDegenerate()
      else if (root.phase === 18) p18LibDegenerate()
      else if (root.phase === 19) p19StepAfterSettle()
      else if (root.phase === 20) p20SampleClamp()
      else if (root.phase === 21) p21SampleStable()
      else if (root.phase === 22) p22NiceStep()
      else if (root.phase === 23) p23StepYearForward()
      else if (root.phase === 24) p24NiceStepNice()
      else if (root.phase === 25) p25Finiteness()
      else if (root.phase === 26) p26Colours()
      else if (root.phase === 27) p27StepYearBack()
      else if (root.phase === 28) p28Recap()
      else finish()
    }
  }

  // The onCompleted snapshot. Reported, not asserted on its own: the point is
  // to show that some of it is only final after a layout pass.
  property real snapHeight: -1
  property int snapSampleN: -1
  property int snapCells: -1

  Component.onCompleted: {
    kv("probe.error", "none")
    kv("mode", root.wideMode ? "wide" : "full")
    kv("mode.wideDomain", root.wideMode ? Quickshell.env("VB_CG_WIDE") : "none")
    kv("wide.built", root.wideMode ? (wideLoader.item ? "yes" : "no") : "skipped")
    kv("wide.gridStep", root.wideMode && wideLoader.item
      ? wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268) : "skipped")
    kv("wide.gridLines", root.wideMode && wideLoader.item
      ? Math.floor(wideLoader.item.xMax / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268))
        - Math.ceil(wideLoader.item.xMin / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268)) + 1
      : "skipped")
    kv("wide.gridLinesBounded", root.wideMode && wideLoader.item
      && Number.isFinite(wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268))
      && Number.isFinite(Math.floor(wideLoader.item.xMax / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268))
        - Math.ceil(wideLoader.item.xMin / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268)) + 1)
      && Math.floor(wideLoader.item.xMax / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268))
        - Math.ceil(wideLoader.item.xMin / wideLoader.item._xStep(wideLoader.item.xMax - wideLoader.item.xMin, 268)) + 1 <= 24)
    kv("wide.infiniteBuilt", root.wideMode && infiniteLoader.item !== null)
    kv("wide.infiniteStepFinite", root.wideMode && infiniteLoader.item !== null
      && isFinite(infiniteLoader.item._xStep(Infinity, 268)))
    kv("wide.infiniteSampleNull", root.wideMode && infiniteLoader.item !== null
      && infiniteLoader.item._sample === null)
    try {
      snapHeight = sep24.implicitHeight
      snapSampleN = gDef._sampleN
      snapCells = sep24.cells.length
    } catch (e) {
      kv("probe.error", "snapshot: " + (e && e.message ? e.message : e))
    }
  }

  // ---- phase 1: what settled, and what the snapshot would have said -----

  function p1Settle() {
    kv("settle.cal.implicitHeight", sep24.implicitHeight)
    kv("settle.cal.height", sep24.height)
    kv("settle.cal.snapHeight", root.snapHeight)
    kv("settle.cal.heightMatchesSnapshot", sep24.implicitHeight === root.snapHeight)
    kv("settle.cal.cells", cellCount(sep24))
    kv("settle.cal.snapCells", root.snapCells)
    kv("settle.graph.sampleN", gDef._sampleN)
    kv("settle.graph.snapSampleN", root.snapSampleN)
    kv("settle.graph.sampleNMatchesSnapshot", gDef._sampleN === root.snapSampleN)
    kv("settle.graph.implicitWidth", gDef.implicitWidth)
    kv("settle.graph.width", gDef.width)
    kv("settle.graph.implicitHeight", gDef.implicitHeight)
    kv("settle.dpr", gDef._dpr)
    kv("settle.dprPositive", gDef._dpr > 0 && isFinite(gDef._dpr))
    // The theme palette lands milliseconds after boot, so the colour SHAPE is
    // asserted and the exact palette value is not.
    kv("settle.colour.bg", colourShape(gDef._bg))
    kv("settle.colour.axis", colourShape(gDef._axis))
  }

  // ---- phase 2: the geometry the wrapper paints from ---------------------

  function p2Constants() {
    kv("cal.cellW", sep24.cellW)
    kv("cal.cellH", sep24.cellH)
    kv("cal.cellGap", sep24.cellGap)
    kv("cal.gridW", sep24.gridW)
    kv("cal.gridH", sep24.gridH)
    kv("cal.titleH", sep24.titleH)
    kv("cal.yearBlockH", sep24.yearBlockH)
    kv("cal.weekdayRowH", sep24.weekdayRowH)
    kv("cal.gridY", sep24.gridY)
    kv("cal.yearBlockY", sep24.yearBlockY)
    kv("cal.weekdayRowY", sep24.weekdayRowY)
    kv("cal.desiredWidth", sep24.desiredWidth)
    kv("cal.desiredHeight", sep24.desiredHeight)
    kv("cal.width", sep24.width)
    kv("cal.height", sep24.height)
    kv("cal.implicitWidth", sep24.implicitWidth)
    kv("cal.implicitHeight", sep24.implicitHeight)
    kv("cal.weekStartDefault", sep24.weekStart)
    kv("cal.weekStartIsMonday", sep24.weekStart === 1)
  }

  // ---- phase 3: internal consistency, and agreement with the library ----
  // Every value here is a RELATION between the wrapper's own numbers, so a
  // missing padding term or a stale token shows up as a mismatch rather than
  // as a magic-number drift.

  function p3Identities() {
    const c = sep24
    kv("id.gridW", c.gridW === 7 * c.cellW + 6 * c.cellGap)
    kv("id.gridH", c.gridH === 6 * c.cellH + 5 * c.cellGap)
    kv("id.desiredWidth", c.desiredWidth === c.gridW)
    kv("id.desiredHeight", c.desiredHeight === c.gridY + c.gridH)
    kv("id.yearBlockY", c.yearBlockY === c.titleH + Ui.s)
    kv("id.weekdayRowY", c.weekdayRowY === c.yearBlockY + c.yearBlockH + Ui.s)
    // gridY comes from the JS library, which duplicates Ui.s as a literal (SP
    // = 8, CalendarLib.js:136) because a .js file cannot import a singleton.
    // The QML block chain above uses Ui.s instead, so the two only agree while
    // Ui.s is still 8 - this is the assertion that keeps the duplication honest.
    kv("id.gridYFromQmlChain", c.gridY === c.weekdayRowY + c.weekdayRowH + Ui.s)
    // The Repeater's own x/y formulas (Calendar.qml:283-284) have to land the
    // last column and row exactly on the grid box's far edge, or the grid is
    // narrower/shorter than it claims to be.
    kv("id.lastColumnFits", 6 * (c.cellW + c.cellGap) + c.cellW === c.gridW)
    kv("id.lastRowFits", 5 * (c.cellH + c.cellGap) + c.cellH === c.gridH)
    kv("id.itemSizeIsDesired", c.width === c.desiredWidth && c.height === c.desiredHeight)
    kv("id.implicitIsDesired",
      c.implicitWidth === c.desiredWidth && c.implicitHeight === c.desiredHeight)
    // Wrapper == library, same inputs, no re-derivation in between.
    kv("lib.cellW", c.cellW === CalLib.cellW)
    kv("lib.cellH", c.cellH === CalLib.cellH)
    kv("lib.cellGap", c.cellGap === CalLib.cellGap)
    kv("lib.titleH", c.titleH === CalLib.titleH)
    kv("lib.yearBlockH", c.yearBlockH === CalLib.yearBlockH)
    kv("lib.weekdayRowH", c.weekdayRowH === CalLib.weekdayRowH)
    kv("lib.gridW", c.gridW === CalLib.gridW)
    kv("lib.gridH", c.gridH === CalLib.gridH)
    kv("lib.gridY", c.gridY === CalLib.gridY)
    // contentHeight is what ClockIsland sizes its card from, and it must be
    // the same number the calendar's own desiredHeight is.
    kv("lib.contentHeight", c.desiredHeight === CalLib.contentHeight)
    kv("lib.gridWFeedsHost", CalLib.gridW === c.desiredWidth)
    // A host's key property: selectedKey is the documented "yyyy-MM-dd" form.
    kv("lib.selectedKey", c.selectedKey === CalLib.keyForDate(c.selectedDate))
    kv("id.selectedKeyFormat", /^(\d{4})-(\d{2})-(\d{2})$/.test(c.selectedKey))
  }

  // ---- phase 4: the six-week grid (September 2024) ---------------------

  function p4GridSixWeek() {
    const c = sep24
    kv("g6.len", cellCount(c))
    kv("g6.uniqueKeys", keySetCount(c))
    kv("g6.consecutive", consecutive(c))
    kv("g6.inMonth", inMonthCount(c))
    kv("g6.daysInMonth", new Date(2024, 9, 0).getDate())
    kv("g6.lastInMonthRow", lastInMonthRow(c))
    kv("g6.row5Mask", rowInMonthMask(c, 5))
    kv("g6.firstKey", keyAt(c, 0))
    kv("g6.firstWeekday", c.cells[0].weekday)
    kv("g6.lastKey", keyAt(c, 41))
    kv("g6.lastIsInMonth", inMonthAt(c, 41))
    kv("g6.selectedCount", selectedCount(c))
    kv("g6.todayCount", todayCount(c))
    kv("g6.weekendCount", weekendCount(c))
    kv("g6.row0", row0Weekdays(c))
    kv("g6.labelOrder", labelOrder(c))
    // Wrapper == library for the whole grid, not just its length.
    kv("g6.sameAsLib", JSON.stringify(c.cells) === JSON.stringify(
      CalLib.monthGrid(2024, 8, 1, "2024-09-11")))
    kv("g6.span", keysFromTo(c, 0, 41))
    kv("g6.firstIsMonday", c.cells[0].key === "2024-08-26")
    kv("g6.sep11At", indexOfKey(c, "2024-09-11"))
    kv("g6.sep30IsLastRow", c.cells[35].key === "2024-09-30" && c.cells[35].inMonth)
    kv("g6.oct6After", c.cells[41].key === "2025-10-06" ? "wrong" : c.cells[41].key)
  }

  function indexOfKey(c, key) {
    for (let i = 0; i < c.cells.length; i++) if (c.cells[i].key === key) return i
    return -1
  }

  // ---- phase 5: the five-week grid (June 2024) -------------------------

  function p5GridFiveWeek() {
    const c = jun24
    kv("g5.len", cellCount(c))
    kv("g5.uniqueKeys", keySetCount(c))
    kv("g5.consecutive", consecutive(c))
    kv("g5.inMonth", inMonthCount(c))
    kv("g5.daysInMonth", new Date(2024, 6, 0).getDate())
    kv("g5.lastInMonthRow", lastInMonthRow(c))
    kv("g5.row5Mask", rowInMonthMask(c, 5))
    kv("g5.firstKey", keyAt(c, 0))
    kv("g5.lastKey", keyAt(c, 41))
    kv("g5.jul1At", indexOfKey(c, "2024-07-01"))
    kv("g5.selectedCount", selectedCount(c))
    kv("g5.sameAsLib", JSON.stringify(c.cells) === JSON.stringify(
      CalLib.monthGrid(2024, 5, 1, "2024-06-15")))
  }

  // ---- phase 6: February, leap year and common year --------------------

  function p6GridFebruary() {
    const a = feb24
    const b = feb23
    kv("feb.leap.inMonth", inMonthCount(a))
    kv("feb.leap.daysInMonth", new Date(2024, 2, 0).getDate())
    kv("feb.leap.lastInMonthRow", lastInMonthRow(a))
    kv("feb.leap.feb29At", indexOfKey(a, "2024-02-29"))
    kv("feb.leap.feb29InMonth", inMonthAt(a, indexOfKey(a, "2024-02-29")))
    kv("feb.leap.feb29Key", keyAt(a, indexOfKey(a, "2024-02-29")))
    kv("feb.leap.march1At", indexOfKey(a, "2024-03-01"))
    kv("feb.leap.uniqueKeys", keySetCount(a))
    kv("feb.leap.consecutive", consecutive(a))
    kv("feb.leap.sameAsLib", JSON.stringify(a.cells) === JSON.stringify(
      CalLib.monthGrid(2024, 1, 1, "2024-02-15")))
    kv("feb.common.inMonth", inMonthCount(b))
    kv("feb.common.daysInMonth", new Date(2023, 2, 0).getDate())
    kv("feb.common.lastInMonthRow", lastInMonthRow(b))
    kv("feb.common.feb29At", indexOfKey(b, "2023-02-29"))
    kv("feb.common.mar1At", indexOfKey(b, "2023-03-01"))
    kv("feb.common.uniqueKeys", keySetCount(b))
    kv("feb.common.consecutive", consecutive(b))
    kv("feb.common.sameAsLib", JSON.stringify(b.cells) === JSON.stringify(
      CalLib.monthGrid(2023, 1, 1, "2023-02-15")))
    // The two Februaries differ by exactly the leap day, and the common year
    // has no 29 February cell at all.
    kv("feb.delta", inMonthCount(a) - inMonthCount(b))
    kv("feb.commonHasNo29", indexOfKey(b, "2023-02-29") === -1)
  }

  // ---- phase 7: year boundaries, both directions -----------------------

  function p7GridBoundaries() {
    const dec = dec24
    kv("dec.len", cellCount(dec))
    kv("dec.inMonth", inMonthCount(dec))
    kv("dec.uniqueKeys", keySetCount(dec))
    kv("dec.consecutive", consecutive(dec))
    kv("dec.firstKey", keyAt(dec, 0))
    kv("dec.lastKey", keyAt(dec, 41))
    kv("dec.dec31At", indexOfKey(dec, "2024-12-31"))
    kv("dec.jan1At", indexOfKey(dec, "2025-01-01"))
    kv("dec.jan5At", indexOfKey(dec, "2025-01-05"))
    kv("dec.jan1InMonth", inMonthAt(dec, indexOfKey(dec, "2025-01-01")))
    kv("dec.jan1Year", yearOfKeyAt(dec, indexOfKey(dec, "2025-01-01")))
    kv("dec.jan1Month", monthOfKeyAt(dec, indexOfKey(dec, "2025-01-01")))
    kv("dec.janCellsShown", indexOfKey(dec, "2025-01-05") >= 0)
    kv("dec.row5Mask", rowInMonthMask(dec, 5))
    kv("dec.sameAsLib", JSON.stringify(dec.cells) === JSON.stringify(
      CalLib.monthGrid(2024, 11, 1, "2024-12-15")))
    // January 2024 with weekStart 1 starts exactly on the 1st, so there is no
    // leading December day; with weekStart 0 there must be exactly one.
    const a = jan24
    const b = jan24sun
    const c = jan23
    kv("jan.mondayFirst", keyAt(a, 0))
    kv("jan.mondayNoLeading", indexOfKey(a, "2023-12-31") === -1)
    kv("jan.sundayFirst", keyAt(b, 0))
    kv("jan.sundayLeadingInMonth", inMonthAt(b, 0))
    kv("jan.sundayLeadingYear", yearOfKeyAt(b, 0))
    kv("jan.sundayInMonth", inMonthCount(b))
    kv("jan.sundayLastKey", keyAt(b, 41))
    kv("jan23.firstKey", keyAt(c, 0))
    kv("jan23.leadingYear", yearOfKeyAt(c, 0))
    kv("jan23.inMonth", inMonthCount(c))
    kv("jan23.consecutive", consecutive(c))
  }

  // ---- phase 8: a month that fits in four weeks, and today elsewhere ----

  function p8GridEdges() {
    const c = feb21
    kv("g4.len", cellCount(c))
    kv("g4.inMonth", inMonthCount(c))
    kv("g4.lastInMonthRow", lastInMonthRow(c))
    kv("g4.row4Mask", rowInMonthMask(c, 4))
    kv("g4.row5Mask", rowInMonthMask(c, 5))
    kv("g4.mar1At", indexOfKey(c, "2021-03-01"))
    kv("g4.lastKey", keyAt(c, 41))
    kv("g4.uniqueKeys", keySetCount(c))
    kv("g4.consecutive", consecutive(c))
    // today in the trailing month: marked exactly once, on a cell that is not
    // in the viewed month.
    const t = trailToday
    kv("trailtoday.count", todayCount(t))
    kv("trailtoday.at", indexOfKey(t, "2024-10-02"))
    kv("trailtoday.inMonth", inMonthAt(t, indexOfKey(t, "2024-10-02")))
    kv("trailtoday.oct1InMonth", inMonthAt(t, indexOfKey(t, "2024-10-01")))
    kv("trailtoday.sep30InMonth", inMonthAt(t, indexOfKey(t, "2024-09-30")))
    kv("trailtoday.sameAsLib", JSON.stringify(t.cells) === JSON.stringify(
      CalLib.monthGrid(2024, 8, 1, "2024-10-02")))
    // today outside the grid: nothing is marked, and the grid is still whole.
    const a = awayToday
    kv("awaytoday.count", todayCount(a))
    kv("awaytoday.len", cellCount(a))
    kv("awaytoday.consecutive", consecutive(a))
  }

  // ---- phase 9: viewMonth out of range ---------------------------------
  // viewYear/viewMonth are plain writable ints, not normalised. monthGrid
  // itself is tolerant - new Date(2024, 12, 1) is January 2025 - but it
  // compares each cell against the RAW month and year, so an out-of-range
  // viewMonth makes every cell "not in month".

  function p9ViewMonthRange() {
    kv("vm11.month", vm11.viewMonth)
    kv("vm11.year", vm11.viewYear)
    kv("vm11.inMonth", inMonthCount(vm11))
    kv("vm11.firstKey", keyAt(vm11, 0))
    kv("vm11.isDecember", vm11.viewMonth === 11 && inMonthCount(vm11) === 31)
    kv("vm0.month", vm0.viewMonth)
    kv("vm0.year", vm0.viewYear)
    kv("vm0.inMonth", inMonthCount(vm0))
    kv("vm0.firstKey", keyAt(vm0, 0))
    kv("vm0.isJanuary", vm0.viewMonth === 0 && inMonthCount(vm0) === 31)
    kv("vm12.month", vm12.viewMonth)
    kv("vm12.year", vm12.viewYear)
    kv("vm12.inMonth", inMonthCount(vm12))
    kv("vm12.selectedCount", selectedCount(vm12))
    kv("vm12.firstKey", keyAt(vm12, 0))
    kv("vm12.lastKey", keyAt(vm12, 41))
    kv("vm12.inRange", vm12.viewMonth >= 0 && vm12.viewMonth <= 11)
    kv("vmneg.month", vmNeg1.viewMonth)
    kv("vmneg.year", vmNeg1.viewYear)
    kv("vmneg.inMonth", inMonthCount(vmNeg1))
    kv("vmneg.selectedCount", selectedCount(vmNeg1))
    kv("vmneg.firstKey", keyAt(vmNeg1, 0))
    kv("vmneg.lastKey", keyAt(vmNeg1, 41))
    kv("vmneg.inRange", vmNeg1.viewMonth >= 0 && vmNeg1.viewMonth <= 11)
  }

  // ---- phase 10: the date mapping --------------------------------------

  function p10DateMapping() {
    kv("d.jan1Leap.doy", dJan1Leap.dayOfYear)
    kv("d.jan1Leap.daysInYear", dJan1Leap.daysInYear)
    kv("d.jan1Leap.progress", dJan1Leap.yearProgress)
    kv("d.jan1Leap.key", dJan1Leap.selectedKey)
    kv("d.dec31Leap.doy", dDec31Leap.dayOfYear)
    kv("d.dec31Leap.daysInYear", dDec31Leap.daysInYear)
    kv("d.dec31Leap.progress", dDec31Leap.yearProgress)
    kv("d.dec31Leap.key", dDec31Leap.selectedKey)
    kv("d.dec31Common.doy", dDec31Common.dayOfYear)
    kv("d.dec31Common.daysInYear", dDec31Common.daysInYear)
    kv("d.dec31Common.progress", dDec31Common.yearProgress)
    kv("d.dec31Common.key", dDec31Common.selectedKey)
    kv("d.feb29Leap.doy", dFeb29Leap.dayOfYear)
    kv("d.feb29Leap.daysInYear", dFeb29Leap.daysInYear)
    kv("d.feb29Leap.progress", dFeb29Leap.yearProgress)
    kv("d.feb29Leap.key", dFeb29Leap.selectedKey)
    kv("d.mar1Common.doy", dMar1Common.dayOfYear)
    kv("d.mar1Common.daysInYear", dMar1Common.daysInYear)
    kv("d.feb28Leap.doy", dFeb28Leap.dayOfYear)
    // 1 January, 31 December and 29 February are the three places a leap
    // year and a common year disagree, and the wrapper has to carry that
    // difference rather than a hard-coded 365.
    kv("d.leapDelta", dDec31Leap.dayOfYear - dDec31Common.dayOfYear)
    kv("d.leapDeltaYear", dDec31Leap.daysInYear - dDec31Common.daysInYear)
    kv("d.doyDeltaAtFeb29", dMar1Common.dayOfYear - dFeb29Leap.dayOfYear)
    // The library computes the same numbers from the same inputs.
    kv("d.lib.jan1Leap", dJan1Leap.dayOfYear === CalLib.dayOfYear(2024, 0, 1))
    kv("d.lib.dec31Leap", dDec31Leap.dayOfYear === CalLib.dayOfYear(2024, 11, 31))
    kv("d.lib.dec31Common", dDec31Common.dayOfYear === CalLib.dayOfYear(2023, 11, 31))
    kv("d.lib.feb29Leap", dFeb29Leap.dayOfYear === CalLib.dayOfYear(2024, 1, 29))
    kv("d.lib.daysInYear", dDec31Leap.daysInYear === CalLib.daysInYear(2024)
      && dDec31Common.daysInYear === CalLib.daysInYear(2023))
    kv("d.lib.progress", dDec31Leap.yearProgress === CalLib.yearProgressPercent(2024, 11, 31))
    // "yyyy-MM-dd" is the documented key form: zero-padded, no Date object.
    kv("d.key.jan5", dJan5.selectedKey)
    kv("d.key.dec5", dDec5.selectedKey)
    kv("d.key.isString", typeof dJan5.selectedKey)
    kv("d.key.matchesDoc", /^\d{4}-\d{2}-\d{2}$/.test(dJan5.selectedKey))
    // The property is named yearProgress but holds a PERCENT (0..100), not a
    // 0..1 fraction - ProgressBar takes it as a 0..100 value.
    kv("d.progressIsPercent", dDec31Leap.yearProgress === 100 && dJan1Leap.yearProgress === 0)
    kv("d.progressFractionWouldBe", CalLib.yearProgress(2024, 11, 31))
  }

  // ---- phase 11: view state and the binding takeover --------------------

  function p11ViewBinding() {
    kv("v.mover.before", mover.viewYear + "/" + mover.viewMonth)
    mover.selectedDate = new Date(2023, 2, 3)
    kv("v.mover.after", mover.viewYear + "/" + mover.viewMonth)
    kv("v.mover.followsSelection", mover.viewYear === 2023 && mover.viewMonth === 2)
    kv("v.mover.keyAfter", mover.selectedKey)
    kv("v.mover.doyAfter", mover.dayOfYear)
    // Once stepMonth/selectDay has assigned viewYear/viewMonth the binding is
    // gone, and later selectedDate writes stop moving the view. Documented at
    // Calendar.qml:28-30, and it is why goToToday() assigns the view itself.
    brokenBinding.stepMonth(1)
    kv("v.broken.afterStep", brokenBinding.viewYear + "/" + brokenBinding.viewMonth)
    brokenBinding.selectedDate = new Date(2020, 5, 6)
    kv("v.broken.viewAfterNewSelection",
      brokenBinding.viewYear + "/" + brokenBinding.viewMonth)
    kv("v.broken.selectionTook", brokenBinding.selectedKey)
    kv("v.broken.viewUnchanged", brokenBinding.viewYear === 2024 && brokenBinding.viewMonth === 9)
  }

  // ---- phase 12: weekStart --------------------------------------------

  function p12WeekStart() {
    kv("ws.default", sep24.weekStart)
    kv("ws.zero", ws0.weekStart)
    kv("ws.zero.row0", row0Weekdays(ws0))
    kv("ws.zero.firstWeekday", ws0.cells[0].weekday)
    kv("ws.zero.firstKey", keyAt(ws0, 0))
    kv("ws.zero.labelOrder", labelOrder(ws0))
    kv("ws.one.row0", row0Weekdays(sep24))
    kv("ws.one.labelOrder", labelOrder(sep24))
    kv("ws.labelsMatchGrid.zero", row0Weekdays(ws0) === labelOrder(ws0))
    kv("ws.labelsMatchGrid.one", row0Weekdays(sep24) === labelOrder(sep24))
    // Out of range in both directions, and a large value.
    kv("ws.seven.row0", row0Weekdays(ws7))
    kv("ws.seven.normalisedTo", CalLib.normalizeWeekStart(7, 1))
    kv("ws.seven.len", cellCount(ws7))
    kv("ws.negOne.row0", row0Weekdays(wsNeg1))
    kv("ws.negOne.normalisedTo", CalLib.normalizeWeekStart(-1, 1))
    kv("ws.negOne.len", cellCount(wsNeg1))
    kv("ws.neg99.row0", row0Weekdays(ws99))
    kv("ws.neg99.normalisedTo", CalLib.normalizeWeekStart(99, 1))
    kv("ws.neg99.len", cellCount(ws99))
    kv("ws.six.row0", row0Weekdays(ws6))
    // Normalisation must not produce an empty or 8-wide grid: still 42 cells,
    // still 7 distinct weekdays per row, still consecutive days.
    kv("ws.seven.unique", keySetCount(ws7))
    kv("ws.seven.consecutive", consecutive(ws7))
    kv("ws.negOne.unique", keySetCount(wsNeg1))
    kv("ws.negOne.consecutive", consecutive(wsNeg1))
    kv("ws.neg99.unique", keySetCount(ws99))
    kv("ws.neg99.consecutive", consecutive(ws99))
    kv("ws.seven.rowIsPermutation", isPermutation(row0Weekdays(ws7)))
    kv("ws.negOne.rowIsPermutation", isPermutation(row0Weekdays(wsNeg1)))
    kv("ws.neg99.rowIsPermutation", isPermutation(row0Weekdays(ws99)))
    kv("ws.zero.rowIsPermutation", isPermutation(row0Weekdays(ws0)))
  }

  function isPermutation(weekdayString) {
    if (weekdayString.length !== 7) return false
    const seen = {}
    for (let i = 0; i < 7; i++) {
      const w = Number(weekdayString[i])
      if (w < 0 || w > 6 || seen[w]) return false
      seen[w] = true
    }
    return true
  }

  // ---- phase 13/14: daySelected ----------------------------------------
  // Driven through selectDay(), which is exactly what the cell MouseArea
  // calls (Calendar.qml:325). There is no compositor to click with.

  function p13SelectOne() {
    kv("sel.count0", root.selCount)
    kv("sel.view0", sel.viewYear + "/" + sel.viewMonth)
    kv("sel.date0", sel.selectedKey)
    sel.selectDay(2024, 8, 15)
    kv("sel.count1", root.selCount)
    kv("sel.log1", root.selLog)
    kv("sel.date1", sel.selectedKey)
    kv("sel.emitted1", lastKey(root.selLog))
    kv("sel.view1", sel.viewYear + "/" + sel.viewMonth)
    kv("sel.doy1", sel.dayOfYear)
    // A second selection must carry the SECOND date, not repeat the first.
    sel.selectDay(2024, 8, 20)
    kv("sel.count2", root.selCount)
    kv("sel.log2", root.selLog)
    kv("sel.date2", sel.selectedKey)
    kv("sel.emitted2", lastKey(root.selLog))
    kv("sel.noStaleSecond", lastKey(root.selLog) === sel.selectedKey)
    kv("sel.doy2", sel.dayOfYear)
    kv("sel.progress2", sel.yearProgress)
  }

  function lastKey(log) {
    if (log === "") return ""
    const parts = log.split(",")
    return parts[parts.length - 1]
  }

  // ---- phase 14: the month-slide queue ---------------------------------
  // Deltas that arrive during a slide accumulate and start after it settles.

  function p14StepGuard() {
    kv("st.slideMs", Ui.fastMs)
    kv("st.a.before", stA.viewYear + "/" + stA.viewMonth)
    stA.stepMonth(1)
    kv("st.a.after1", stA.viewYear + "/" + stA.viewMonth)
    kv("st.a.sliding", stA._sliding)
    stA.stepMonth(1)
    kv("st.a.afterSecondCall", stA.viewYear + "/" + stA.viewMonth)
    stA.stepMonth(1)
    kv("st.a.afterThirdCall", stA.viewYear + "/" + stA.viewMonth)
    stA.stepMonth(-12)
    kv("st.a.afterYearJump", stA.viewYear + "/" + stA.viewMonth)
    stA.stepMonth(0)
    kv("st.a.afterZeroDelta", stA.viewYear + "/" + stA.viewMonth)
    kv("st.a.pendingDelta", stA._pendingMonthDelta)
    stRapid.stepMonth(1)
    stRapid.stepMonth(1)
    stRapid.stepMonth(1)
    kv("st.rapid.immediateMonth", stRapid.viewMonth)
    kv("st.rapid.pending", stRapid._pendingMonthDelta)
  }

  // ---- phase 15: FunctionGraph defaults and a well-formed sample --------

  function p16GraphDefaults() {
    kv("g.graphH", gDef.graphH)
    kv("g.xMin", gDef.xMin)
    kv("g.xMax", gDef.xMax)
    kv("g.fillHeight", gDef.fillHeight)
    kv("g.showHeader", gDef.showHeader)
    kv("g.implicitWidth", gDef.implicitWidth)
    kv("g.funcBody", gDef.funcBody)
    kv("g.sample.ok", sampleOk(gDef._sample))
    kv("g.sample.counts", sampleCounts(gDef._sample))
    kv("g.sample.len", gDef._sample ? gDef._sample.ys.length : "null")
    kv("g.sampleN", gDef._sampleN)
    kv("g.sampleOkFromLib", sampleOk(FuncLib.sampleFunction("x^2", -10, 10, gDef._sampleN)))
    // The wrapper must hand FuncLib exactly its own properties, unmodified.
    kv("g.wrapsLib", gDef._sample !== null
      && gDef._sample.ys.length === FuncLib.sampleFunction("x^2", -10, 10, gDef._sampleN).ys.length
      && gDef._sample.yMin === FuncLib.sampleFunction("x^2", -10, 10, gDef._sampleN).yMin
      && gDef._sample.yMax === FuncLib.sampleFunction("x^2", -10, 10, gDef._sampleN).yMax)
    // A sine over the default domain: every column finite, and the auto-fitted
    // range brackets the curve.
    kv("g.sin.ok", sampleOk(gSin._sample))
    kv("g.sin.counts", sampleCounts(gSin._sample))
    kv("g.sin.brackets", gSin._sample !== null && gSin._sample.yMin < -1 && gSin._sample.yMax > 1)
    // Height does not drive the sample count: it is per pixel COLUMN.
    kv("g.tall.sampleN", gTall._sampleN)
    kv("g.short.sampleN", gShort._sampleN)
    kv("g.heightIndependentOfSampleN", gTall._sampleN === gDef._sampleN && gShort._sampleN === gDef._sampleN)
    kv("g.tall.implicitHeight", gTall.implicitHeight)
    kv("g.short.implicitHeight", gShort.implicitHeight)
    // The header contributes its own height plus Ui.s; hiding it removes both,
    // which is the only way to read graphBox.height exactly.
    kv("g.headerOn.implicitHeight", gDef.implicitHeight)
    kv("g.headerOff.implicitHeight", gNoHeader.implicitHeight)
    kv("g.headerBlock", gDef.implicitHeight - gNoHeader.implicitHeight)
    kv("g.headerIsThemeless", gNoHeader.implicitHeight === gDef.graphH)
    // fillHeight reports a resting estimate, not the host height: reporting the
    // live box height would close a binding loop (FunctionGraph.qml:36-43).
    kv("g.fill400.implicitHeight", gFill400.implicitHeight)
    kv("g.fill0.implicitHeight", gFill0.implicitHeight)
    kv("g.fillIndependent", gFill400.implicitHeight === gFill0.implicitHeight)
    kv("g.fillEqualsFixed", gFill400.implicitHeight === gDef.implicitHeight)
  }

  // ---- phase 16: degenerate bodies and domains, on the component --------

  function p17GraphDegenerate() {
    kv("d.empty.ok", sampleOk(gEmpty._sample))
    kv("d.empty.isNull", gEmpty._sample === null)
    kv("d.const.ok", sampleOk(gConst._sample))
    kv("d.const.isNull", gConst._sample === null)
    kv("d.chat.ok", sampleOk(gChat._sample))
    kv("d.chat.isNull", gChat._sample === null)
    kv("d.incomplete.ok", sampleOk(gIncomplete._sample))
    kv("d.incomplete.isNull", gIncomplete._sample === null)
    kv("d.eqDomain.ok", sampleOk(gEqDomain._sample))
    kv("d.eqDomain.isNull", gEqDomain._sample === null)
    kv("d.eqDomain.xMin", gEqDomain.xMin)
    kv("d.eqDomain.xMax", gEqDomain.xMax)
    kv("d.revDomain.ok", sampleOk(gRevDomain._sample))
    kv("d.revDomain.isNull", gRevDomain._sample === null)
    kv("d.revDomain.xMin", gRevDomain.xMin)
    kv("d.revDomain.xMax", gRevDomain.xMax)
    kv("d.nanMin.ok", sampleOk(gNaNMin._sample))
    kv("d.nanMin.isNull", gNaNMin._sample === null)
    kv("d.nanMin.xMinIsNaN", isNaN(gNaNMin.xMin))
    // sqrt over negatives: half the columns are NaN on purpose (the painter
    // breaks the path there), and the range still has to be usable.
    kv("d.sqrt.ok", sampleOk(gSqrt._sample))
    kv("d.sqrt.counts", sampleCounts(gSqrt._sample))
    kv("d.sqrt.len", gSqrt._sample ? gSqrt._sample.ys.length : "null")
    kv("d.sqrt.valid", gSqrt._sample ? gSqrt._sample.valid : "null")
    kv("d.sqrt.rangeFinite", gSqrt._sample !== null
      && isFinite(gSqrt._sample.yMin) && isFinite(gSqrt._sample.yMax)
      && gSqrt._sample.yMax > gSqrt._sample.yMin)
    kv("d.sqrt.rangeNonNegative", gSqrt._sample !== null && gSqrt._sample.yMin >= 0)
    // sqrt over a domain with no non-negative x at all: nothing to draw.
    kv("d.sqrtNeg.ok", sampleOk(gSqrtNeg._sample))
    kv("d.sqrtNeg.isNull", gSqrtNeg._sample === null)
    // log through zero and negatives: -Infinity and NaN both arrive at the
    // sampler, and neither may survive into ys.
    kv("d.log.ok", sampleOk(gLog._sample))
    kv("d.log.counts", sampleCounts(gLog._sample))
    kv("d.log.valid", gLog._sample ? gLog._sample.valid : "null")
    kv("d.log.rangeFinite", gLog._sample !== null
      && isFinite(gLog._sample.yMin) && isFinite(gLog._sample.yMax)
      && gLog._sample.yMax > gLog._sample.yMin)
    // 1/x: with 280 columns the sampler never lands exactly on x = 0, with 281
    // it does, and that one column must become NaN rather than Infinity.
    kv("d.recip280.counts", sampleCounts(gRecip280._sample))
    kv("d.recip280.ok", sampleOk(gRecip280._sample))
    kv("d.recip281.counts", sampleCounts(gRecip281._sample))
    kv("d.recip281.ok", sampleOk(gRecip281._sample))
    kv("d.recip281.nanIsPole", gRecip281._sample !== null
      && gRecip281._sample.ys.length === 281 && gRecip281._sample.valid === 280)
    kv("d.tan.ok", sampleOk(gTan._sample))
    kv("d.tan.counts", sampleCounts(gTan._sample))
    // x/0 compiles and evaluates to Infinity everywhere: the 1e6 spike cutoff
    // turns it into a sample with no finite values, i.e. null.
    kv("d.zeroDiv.ok", sampleOk(gZeroDiv._sample))
    kv("d.zeroDiv.isNull", gZeroDiv._sample === null)
    // A body the component is NOT supposed to receive: the host strips the
    // "y =" prefix (FunctionGraph.qml:11-12), and sampleFunction does not.
    kv("d.prefixed.ok", sampleOk(gPrefixed._sample))
    kv("d.prefixed.isNull", gPrefixed._sample === null)
    kv("d.lib.prefixedIsValid", FuncLib.tryParseFunction("y = x^2") !== null)
    // A bare "x" IS a real function for the sampler (it is the launcher's
    // job to reject it, not the graph's).
    kv("d.bareX.ok", sampleOk(gBareX._sample))
    kv("d.bareX.counts", sampleCounts(gBareX._sample))
    // A zero plot height must not produce a zero/NaN sample count.
    kv("d.zeroH.sampleN", gZeroH._sampleN)
    kv("d.zeroH.ok", sampleOk(gZeroH._sample))
    kv("d.zeroH.implicitHeight", gZeroH.implicitHeight)
    kv("d.zeroH.heightFinite", isFinite(gZeroH.implicitHeight))
  }

  // ---- phase 17: the same degenerate domains, straight through FuncLib --
  // These are checked against the library directly because a component
  // instance with a wide domain would wedge the probe in the paint (see the
  // header comment), and because calling the library with the same arguments
  // the wrapper uses is what proves the wrapper is a pass-through.

  function p18LibDegenerate() {
    kv("lib.hugeSpan.x2", sampleOk(FuncLib.sampleFunction("x^2", -1e6, 1e6, 280)))
    kv("lib.hugeSpan.x2IsNull", FuncLib.sampleFunction("x^2", -1e6, 1e6, 280) === null)
    kv("lib.hugeSpan.sin", sampleOk(FuncLib.sampleFunction("sin(x)", -1e6, 1e6, 280)))
    kv("lib.hugeSpan.sinCount", FuncLib.sampleFunction("sin(x)", -1e6, 1e6, 280).valid)
    kv("lib.hugeSpan.spanOk", FuncLib.sampleFunction("sin(x)", -1e6, 1e6, 280).ys.length === 280)
    kv("lib.infDomain", sampleOk(FuncLib.sampleFunction("x^2", -Infinity, Infinity, 280)))
    kv("lib.infDomainIsNull", FuncLib.sampleFunction("x^2", -Infinity, Infinity, 280) === null)
    kv("lib.nanMin", sampleOk(FuncLib.sampleFunction("x^2", Math.sqrt(-1), 10, 280)))
    kv("lib.nanSpan", sampleOk(FuncLib.sampleFunction("x^2", 0, Math.sqrt(-1), 280)))
    kv("lib.eqDomain", sampleOk(FuncLib.sampleFunction("x^2", 7, 7, 280)))
    kv("lib.revDomain", sampleOk(FuncLib.sampleFunction("x^2", 7, -7, 280)))
    kv("lib.tinyDomain", sampleOk(FuncLib.sampleFunction("x^2", 0, 1e-9, 280)))
    kv("lib.empty", sampleOk(FuncLib.sampleFunction("", -10, 10, 280)))
    kv("lib.const", sampleOk(FuncLib.sampleFunction("2+2", -10, 10, 280)))
    kv("lib.xchat", sampleOk(FuncLib.sampleFunction("x chat", -10, 10, 280)))
    kv("lib.incomplete", sampleOk(FuncLib.sampleFunction("x+", -10, 10, 280)))
    kv("lib.syntax", sampleOk(FuncLib.sampleFunction("x^^2", -10, 10, 280)))
    // The sample count the wrapper asks for is inside the library's own
    // [2, 400] clamp, so the two never disagree about the length.
    kv("lib.nZero", sampleCounts(FuncLib.sampleFunction("x^2", -10, 10, 0)))
    kv("lib.nNaN", sampleCounts(FuncLib.sampleFunction("x^2", -10, 10, Math.sqrt(-1))))
    kv("lib.nOver", sampleCounts(FuncLib.sampleFunction("x^2", -10, 10, 500)))
    kv("lib.nUnder", sampleCounts(FuncLib.sampleFunction("x^2", -10, 10, 1)))
    kv("lib.nAtMin", FuncLib.sampleFunction("x^2", -10, 10, 1).ys.length)
    kv("lib.nAtMax", FuncLib.sampleFunction("x^2", -10, 10, 500).ys.length)
    kv("lib.nDefault", FuncLib.sampleFunction("x^2", -10, 10, undefined).ys.length)
    // Grid density depends on plot width rather than domain magnitude.
    const defaultStep = gDef._xStep(20, 268)
    const hugeStep = gDef._xStep(2e6, 268)
    const infiniteStep = gDef._xStep(Infinity, 268)
    kv("lib.gridlines.default", Math.floor(10 / defaultStep) - Math.ceil(-10 / defaultStep) + 1)
    kv("lib.gridlines.huge", Math.floor(1e6 / hugeStep) - Math.ceil(-1e6 / hugeStep) + 1)
    kv("lib.gridlines.zero", Math.floor(0) - Math.ceil(0) + 1)
    kv("lib.gridlines.hugeBounded", Number.isFinite(hugeStep) && hugeStep > 0
      && Math.floor(1e6 / hugeStep) - Math.ceil(-1e6 / hugeStep) + 1 <= Math.floor(268 / 12) + 2)
    kv("lib.gridlines.infiniteXStepFinite", Number.isFinite(infiniteStep) && infiniteStep > 0)
    kv("lib.gridlines.infiniteStep", gDef._niceStep(Infinity))
    kv("lib.gridlines.infiniteXStep", gDef._xStep(Infinity, 268))
  }

  // ---- phase 18: stepMonth again, once the slide has finished -----------

  function p19StepAfterSettle() {
    kv("st.a.afterQueued", stA.viewYear + "/" + stA.viewMonth)
    kv("st.a.pendingAfter", stA._pendingMonthDelta)
    kv("st.rapid.afterCoalesced", stRapid.viewYear + "/" + stRapid.viewMonth)
    kv("st.rapid.pendingAfter", stRapid._pendingMonthDelta)
    kv("st.b.sliding", stB._sliding)
    kv("st.b.before", stB.viewYear + "/" + stB.viewMonth)
    stB.stepMonth(-1)
    kv("st.b.afterMinus1", stB.viewYear + "/" + stB.viewMonth)
    kv("st.b.slidingDuring", stB._sliding)
    kv("st.b.worked", stB.viewMonth === 7)
  }

  // ---- phase 19: the sample-count clamp --------------------------------

  function p20SampleClamp() {
    kv("cl.zeroWidth", gZeroW._sampleN)
    kv("cl.narrow12", gNarrow._sampleN)
    kv("cl.w79", gW79._sampleN)
    kv("cl.w80", gW80._sampleN)
    kv("cl.w300", gW300._sampleN)
    kv("cl.w301", gW301._sampleN)
    kv("cl.w5000", gHuge._sampleN)
    kv("cl.zeroWidth.len", gZeroW._sample ? gZeroW._sample.ys.length : "null")
    kv("cl.zeroWidth.ok", sampleOk(gZeroW._sample))
    kv("cl.narrow.len", gNarrow._sample ? gNarrow._sample.ys.length : "null")
    kv("cl.w301.len", gW301._sample ? gW301._sample.ys.length : "null")
    kv("cl.huge.len", gHuge._sample ? gHuge._sample.ys.length : "null")
    kv("cl.atLeast80", gNarrow._sampleN >= 80 && gW79._sampleN >= 80)
    kv("cl.atMost300", gW301._sampleN <= 300 && gHuge._sampleN <= 300)
    kv("cl.fallsBackTo240", gZeroW._sampleN === 240)
  }

  // ---- phase 20: the count is stable and derived from the settled width --

  function p21SampleStable() {
    kv("st.count.a", gDef._sampleN)
    kv("st.count.b", gDef._sampleN)
    kv("st.count.c", gDef._sampleN)
    kv("st.count.narrow.a", gNarrow._sampleN)
    kv("st.count.narrow.b", gNarrow._sampleN)
    kv("st.count.huge.a", gHuge._sampleN)
    kv("st.count.huge.b", gHuge._sampleN)
    // The count is per pixel column of the plot box, which is anchored to the
    // item - so it tracks width and is final only after a layout pass.
    kv("st.matchesWidth.zero", gZeroW._sampleN === 240)
    kv("st.matchesWidth.280", gDef._sampleN === 280)
    kv("st.matchesWidth.301", gW301._sampleN === 300)
    kv("st.plotBoxNonEmpty", gDef._sampleN >= 80 && gDef.implicitHeight > 0)
  }

  // ---- phase 21/23: _niceStep ------------------------------------------

  function p22NiceStep() {
    kv("ns.tiny", stepReport(gDef, 1e-9))
    kv("ns.one", stepReport(gDef, 1))
    kv("ns.thousand", stepReport(gDef, 1000))
    kv("ns.zero", stepReport(gDef, 0))
    kv("ns.negative", stepReport(gDef, -1000))
    kv("ns.nan", stepReport(gDef, Math.sqrt(-1)))
    kv("ns.infinite", stepReport(gDef, Infinity))
    kv("ns.half", stepReport(gDef, 0.5))
    kv("ns.ten", stepReport(gDef, 10))
    kv("ns.hundred", stepReport(gDef, 100))
    kv("ns.million", stepReport(gDef, 1e6))
    kv("ns.degeneratePositive", gDef._niceStep(0) > 0 && gDef._niceStep(-1000) > 0
      && gDef._niceStep(Math.sqrt(-1)) > 0)
    kv("ns.degenerateFinite", isFinite(gDef._niceStep(0)) && isFinite(gDef._niceStep(-1000))
      && isFinite(gDef._niceStep(Math.sqrt(-1))))
  }

  function p24NiceStepNice() {
    const asc = [0.0001, 0.001, 0.01, 0.1, 0.5, 1, 2, 5, 10, 50, 100, 500, 1000, 5000,
      10000, 100000, 1e6]
    let mono = true
    let allNice = true
    let prev = -1
    let report = ""
    for (let i = 0; i < asc.length; i++) {
      const st = gDef._niceStep(asc[i])
      if (st < prev) mono = false
      if (stepMantissa(st) !== "nice") allNice = false
      prev = st
      report += asc[i] + "=" + st + ","
    }
    kv("nsn.monotonic", mono)
    kv("nsn.allNice", allNice)
    kv("nsn.series", report)
    // Step never exceeds the span it is dividing, and is never so small that
    // the grid loop would run away.
    kv("nsn.stepUnderSpan", gDef._niceStep(1) <= 1 && gDef._niceStep(1000) <= 1000)
    kv("nsn.atLeastTwoSteps", gDef._niceStep(1000) * 2 <= 1000 || gDef._niceStep(1000) < 1000)
    // The painter asks for Math.ceil(y0/step) .. Math.floor(y1/step), so a
    // step that is not nice shows up as a lopsided grid. With the default
    // sine the range is about [-1.34, 1.34], so the step must be 0.5.
    kv("nsn.forSineRange", gDef._niceStep(1.34 - -1.34))
  }

  // ---- phase 22/26: stepping across a year boundary --------------------

  function p23StepYearForward() {
    kv("st.c.before", stC.viewYear + "/" + stC.viewMonth)
    kv("st.c.sliding", stC._sliding)
    stC.stepMonth(1)
    kv("st.c.after", stC.viewYear + "/" + stC.viewMonth)
    kv("st.c.rolledToNextYear", stC.viewYear === 2025 && stC.viewMonth === 0)
    kv("st.c.januaryLength", inMonthCount(stC))
    kv("st.c.firstKey", keyAt(stC, 0))
    kv("st.c.consecutive", consecutive(stC))
    kv("st.c.unique", keySetCount(stC))
    kv("st.c.jan1Key", keyAt(stC, indexOfKey(stC, "2025-01-01")))
  }

  function p27StepYearBack() {
    kv("st.d.before", stD.viewYear + "/" + stD.viewMonth)
    kv("st.d.sliding", stD._sliding)
    stD.stepMonth(-1)
    kv("st.d.after", stD.viewYear + "/" + stD.viewMonth)
    kv("st.d.rolledToPrevYear", stD.viewYear === 2023 && stD.viewMonth === 11)
    kv("st.d.decemberLength", inMonthCount(stD))
    kv("st.d.consecutive", consecutive(stD))
    kv("st.d.unique", keySetCount(stD))
  }

  // ---- phase 13 continued: neighbour-month day, out-of-range day, today --

  function p15SelectMore() {
    // A day from the TRAILING (next) month of the September grid: the
    // selection lands on October AND the view follows it.
    sel.selectDay(2024, 9, 1)
    kv("sel.count3", root.selCount)
    kv("sel.log3", root.selLog)
    kv("sel.neighbourDate", sel.selectedKey)
    kv("sel.neighbourView", sel.viewYear + "/" + sel.viewMonth)
    kv("sel.neighbourInMonth", inMonthCount(sel))
    // An impossible day rolls forward the way new Date() does, silently.
    sel.selectDay(2023, 1, 29)
    kv("sel.overflowCount", root.selCount)
    kv("sel.overflowKey", sel.selectedKey)
    kv("sel.overflowView", sel.viewYear + "/" + sel.viewMonth)
    // goToToday(): emits as well, and takes the view with it.
    gotoCal.goToToday()
    kv("sel.todayCount", root.selCount)
    kv("sel.todayLog", root.selLog)
    kv("sel.todayDate", gotoCal.selectedKey)
    kv("sel.todayView", gotoCal.viewYear + "/" + gotoCal.viewMonth)
    kv("sel.todayDoy", gotoCal.dayOfYear)
    kv("sel.todayInGrid", selectedCount(gotoCal))
    kv("sel.noClockRead", sel.selectedKey !== "" && gotoCal.selectedKey === "2024-09-11")
  }

  // ---- phase 24: nothing in either component's geometry is NaN ---------

  function p25Finiteness() {
    const nums = [
      sep24.cellW, sep24.cellH, sep24.cellGap, sep24.gridW, sep24.gridH, sep24.titleH,
      sep24.yearBlockH, sep24.weekdayRowH, sep24.gridY, sep24.yearBlockY, sep24.weekdayRowY,
      sep24.desiredWidth, sep24.desiredHeight, sep24.width, sep24.height, sep24.implicitWidth,
      sep24.implicitHeight, sep24.dayOfYear, sep24.daysInYear, sep24.yearProgress,
      sep24.viewYear, sep24.viewMonth, sep24.weekStart
    ]
    let bad = 0
    for (let i = 0; i < nums.length; i++) if (!isFinite(nums[i])) bad++
    kv("fin.cal.badCount", bad)
    kv("fin.cal.allFinite", bad === 0)
    kv("fin.cal.count", nums.length)
    // Every cell's geometry-bearing fields are finite too.
    let cellBad = 0
    for (let i = 0; i < sep24.cells.length; i++) {
      const c = sep24.cells[i]
      if (!isFinite(c.year) || !isFinite(c.month) || !isFinite(c.day) || !isFinite(c.weekday)) cellBad++
      if (typeof c.key !== "string" || c.key === "") cellBad++
    }
    kv("fin.cells.badCount", cellBad)
    kv("fin.cells.allFinite", cellBad === 0)
    const graphs = [gDef, gSin, gZeroW, gNarrow, gTall, gShort, gNoHeader, gFill400,
      gFill0, gZeroH, gSqrt, gLog, gTan, gRecip281, gEmpty, gEqDomain, gRevDomain, gNaNMin]
    let gBad = 0
    for (let i = 0; i < graphs.length; i++) {
      const g = graphs[i]
      if (!isFinite(g._sampleN)) gBad++
      if (!isFinite(g.width) || !isFinite(g.height)) gBad++
      if (!isFinite(g.implicitWidth) || !isFinite(g.implicitHeight)) gBad++
      if (!isFinite(g._dpr) || g._dpr <= 0) gBad++
      if (!isFinite(g.xMin) && g !== gNaNMin) gBad++
      if (!isFinite(g.graphH)) gBad++
      const s = g._sample
      if (s !== null && (!isFinite(s.yMin) || !isFinite(s.yMax) || !(s.yMax > s.yMin))) gBad++
    }
    kv("fin.graphs.badCount", gBad)
    kv("fin.graphs.allFinite", gBad === 0)
    kv("fin.graphs.count", graphs.length)
    // A NaN domain is the one NaN that is allowed through, and it is caught
    // by the sampler's own guard rather than reaching a geometry property.
    kv("fin.nanMinIsNaN", isNaN(gNaNMin.xMin))
    kv("fin.nanMinSampleNull", gNaNMin._sample === null)
  }

  // ---- phase 25: the nine theme-derived colours ------------------------
  // Structure and alpha only. The palette lands milliseconds after boot and
  // the RGB channels are theme values, so asserting them would be asserting
  // the theme; the alpha channel is a Ui.tint argument and is exact.

  function p26Colours() {
    const solids = { bg: gDef._bg, plotBg: gDef._plotBg, border: gDef._border, curve: gDef._curve }
    const tints = { minor: gDef._minor, major: gDef._major, axis: gDef._axis,
      label: gDef._label, title: gDef._title }
    const names = ["bg", "plotBg", "border", "curve", "minor", "major", "axis", "label", "title"]
    let bad = 0
    let solidBad = 0
    let emptyBad = 0
    for (const name in solids) {
      if (String(solids[name]) === "") emptyBad++
      if (!isSolid6(solids[name])) solidBad++
      if (colourShape(solids[name]) === "other") bad++
    }
    for (const name in tints) {
      if (String(tints[name]) === "") emptyBad++
      if (colourShape(tints[name]) === "other") bad++
    }
    kv("col.count", names.length)
    kv("col.nonEmpty", emptyBad === 0)
    kv("col.allWellFormed", bad === 0)
    // Theme.color() and Ui.solid() return a bare #rrggbb; Ui.tint() wraps the
    // same value with an alpha, so it comes back #aarrggbb.
    kv("col.solidsAreSixDigit", solidBad === 0)
    kv("col.minor", colourShape(gDef._minor) + "/" + argb8Alpha(gDef._minor))
    kv("col.major", colourShape(gDef._major) + "/" + argb8Alpha(gDef._major))
    kv("col.axis", colourShape(gDef._axis) + "/" + argb8Alpha(gDef._axis))
    kv("col.label", colourShape(gDef._label) + "/" + argb8Alpha(gDef._label))
    kv("col.title", colourShape(gDef._title) + "/" + argb8Alpha(gDef._title))
    kv("col.titleShape", colourShape(gDef._title))
    kv("col.titleAlpha", argb8Alpha(gDef._title))
    kv("col.bg", colourShape(gDef._bg))
    kv("col.plotBg", colourShape(gDef._plotBg))
    kv("col.border", colourShape(gDef._border))
    kv("col.curve", colourShape(gDef._curve))
    // The alphas are the Ui.tint arguments (0.45, 0.95, 0.55, 0.55) scaled to
    // 0..255, so they are exact regardless of which theme is loaded.
    kv("col.alpha45", argb8Alpha(gDef._minor) === Math.round(0.45 * 255))
    kv("col.alpha95", argb8Alpha(gDef._major) === Math.round(0.95 * 255))
    kv("col.alpha55", argb8Alpha(gDef._axis) === Math.round(0.55 * 255))
    kv("col.labelIsAxis", gDef._label === gDef._axis)
    // Ui.tint(k, 1) short-circuits, so the fully-opaque title comes back as a
    // bare 6-digit colour instead of #ffrrggbb.
    kv("col.titleIsOpaque", gDef._title === Ui.solid("foreground_0"))
    kv("col.minorIsNot", gDef._minor !== gDef._bg)
  }

  // ---- phase 27: the wide-domain run's marker, and a recap -------------

  function p28Recap() {
    kv("recap.phases", root.phase)
    kv("recap.selCount", root.selCount)
    kv("recap.selLog", root.selLog)
    kv("recap.eventLoopRan", root.phase > 1)
    kv("recap.selCountMatches", root.selCount === countLogEntries(root.selLog))
  }

  function countLogEntries(log) {
    if (log === "") return 0
    return log.split(",").length
  }

  function finish() {
    pump.running = false
    kv("probe.finished", true)
    console.log("##DONE##")
  }
}

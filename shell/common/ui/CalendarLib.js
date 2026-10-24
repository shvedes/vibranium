// Pure calendar and date math for the Calendar widget (qs.common).
//
// Everything here is locale- and Qt-free so it can be unit tested under
// node (tests/shell/suites/js/services-calendar-weather.test.mjs); the QML
// owns day/month naming through Qt.locale(). Month indices follow JS Date
// conventions (0 = January).
// Weekday indices match JS Date.getDay() and QML Locale enums
// (0 = Sunday ... 6 = Saturday).

.pragma library

.import "../text/Format.js" as Format

var MS_PER_DAY = 86400000

// ---- keys and week handling ----------------------------------------------

// Two-digit zero padding, canonicalized in common/text/Format.js so the
// calendar, clipboard and notification clocks share one spelling.
function pad2(value) {
  return Format.pad2(value)
}

// Stable "yyyy-MM-dd" identity for a day, so grid cells compare against
// today and each other without dragging Date objects through bindings.
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

// Coerce a week start into 0..6; null/undefined/nonsense falls back to
// `fallback` (itself defaulting to Monday). Accepts numbers and names.
var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

function normalizeWeekStart(value, fallback) {
  var configured = null
  if (typeof value === "number") {
    if (isFinite(value)) configured = ((Math.round(value) % 7) + 7) % 7
  } else {
    var text = String(value === undefined || value === null ? "" : value)
      .replace(/^\s+|\s+$/g, "").toLowerCase()
    for (var i = 0; i < WEEKDAY_NAMES.length; i++)
      if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) { configured = i; break }
    if (configured === null) {
      var parsed = parseInt(text, 10)
      if (isFinite(parsed)) configured = ((parsed % 7) + 7) % 7
    }
  }
  if (configured !== null) return configured
  var fallbackStart = null
  if (typeof fallback === "number") fallbackStart = normalizeWeekStart(fallback, null)
  else if (typeof fallback === "string") fallbackStart = normalizeWeekStart(fallback, null)
  return fallbackStart === null ? 1 : fallbackStart
}

// Weekday indices in display order for a given week start.
function weekdayOrder(weekStart) {
  var start = normalizeWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

// ---- year progress --------------------------------------------------------

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

// Share of the year already behind you: whole days completed over days in
// the year, so January 1 reads 0% and December 31 reads 100%.
function yearProgress(year, month, day) {
  var total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

// ---- month grid -----------------------------------------------------------

// Always six rows of seven days. A fixed grid keeps the calendar exactly
// the same height in every month, so stepping through the year never makes
// the popup jump under the pointer. Cells carry everything the view needs:
// a stable key, the real year/month/day, whether the day belongs to the
// viewed month, whether it is a weekend, and whether it is today.
function monthGrid(year, month, weekStart, todayKey) {
  var start = normalizeWeekStart(weekStart, 1)
  var leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  var cursor = new Date(year, month, 1 - leading)
  var today = String(todayKey || "")
  var cells = []

  for (var i = 0; i < 42; i++) {
    var cellYear = cursor.getFullYear()
    var cellMonth = cursor.getMonth()
    var cellDay = cursor.getDate()
    cells.push({
      key: dateKey(cellYear, cellMonth, cellDay),
      year: cellYear,
      month: cellMonth,
      day: cellDay,
      weekday: cursor.getDay(),
      inMonth: cellMonth === month && cellYear === year,
      weekend: cursor.getDay() === 0 || cursor.getDay() === 6,
      today: dateKey(cellYear, cellMonth, cellDay) === today
    })
    cursor.setDate(cursor.getDate() + 1)
  }
  return cells
}

function stepMonth(year, month, delta) {
  var target = new Date(year, Number(month) + Number(delta), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

// ---- geometry (the single source of truth for the calendar's layout) ----
// Calendar.qml paints from these, and hosts (e.g. ClockIsland) size their
// card from them without an instantiated calendar, so the two can never
// drift apart.
var cellW = 42
var cellH = 28
var cellGap = 2
var titleH = 24
var yearBlockH = 32
var weekdayRowH = 16

// Spacing token between the header blocks (Ui.s = 8; duplicated here
// because .js files cannot import the QML Ui singleton).
var SP = 8

// Width of the 7-day grid.
var gridW = 7 * cellW + 6 * cellGap
// Height of the 6-week grid.
var gridH = 6 * cellH + 5 * cellGap
// Vertical offset where the day grid starts (title + year + weekday rows).
var gridY = titleH + SP + yearBlockH + SP + weekdayRowH + SP
// Full painted height of the calendar widget.
var contentHeight = gridY + gridH

if (typeof module !== "undefined") {
  module.exports = {
    dateKey: dateKey,
    keyForDate: keyForDate,
    normalizeWeekStart: normalizeWeekStart,
    weekdayOrder: weekdayOrder,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    monthGrid: monthGrid,
    stepMonth: stepMonth
  }
}

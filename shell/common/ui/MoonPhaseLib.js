// Pure lunar-phase math for the clock's calendar island.
//
// Mean synodic phase against the 2000-01-06 18:14 UTC new moon. The real
// orbit is not uniform, so a painted phase can sit up to about a day off the
// astronomical instant, and the event times are approximate for the same
// reason. The island only needs a disc, a name and a rough time for a
// calendar day, so the small approximation is deliberate: no ephemeris, no
// Qt, no network, no location. Phase is the same worldwide for a given
// instant; the Moon's parallax between two observers is far below the
// accuracy of this calculation, so there is nothing geographic to look up.
//
// A day is identified by its local calendar fields rebuilt as UTC midnight,
// the same convention CalendarLib uses for its day keys. The answer therefore
// changes at local midnight and never depends on the host timezone or on the
// time of day the island happens to be opened.

.pragma library

var MS_PER_DAY = 86400000
var SYNODIC_MONTH = 29.530588853
var NEW_MOON_EPOCH = Date.UTC(2000, 0, 6, 18, 14)

// Eight equal bins centred on new, first quarter, full and last quarter.
// A bin is centred so the principal phase sits inside its own bin, not on
// its boundary.
var BIN = 0.125
var HALF_BIN = 0.0625
var PHASE_NAMES = [
  "New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
  "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"
]
var SHORT_NAMES = [
  "New", "Waxing cres.", "First quarter", "Waxing gib.",
  "Full", "Waning gib.", "Last quarter", "Waning cres."
]
var PRINCIPAL = [true, false, true, false, true, false, true, false]

function wrap01(value) {
  if (!isFinite(value)) return 0
  let f = value % 1
  return f < 0 ? f + 1 : f
}

// 0 = new moon, 0.25 = first quarter, 0.5 = full, 0.75 = last quarter.
function fraction(year, month, day) {
  const t = Date.UTC(Number(year), Number(month), Number(day))
  if (!isFinite(t)) return 0
  return wrap01((t - NEW_MOON_EPOCH) / MS_PER_DAY / SYNODIC_MONTH)
}

function forDate(date) {
  if (!date || !isFinite(date.getTime())) return 0
  return fraction(date.getFullYear(), date.getMonth(), date.getDate())
}

function phaseIndex(f) {
  const i = Math.floor((wrap01(f) + HALF_BIN) / BIN)
  return i % 8
}

// Lit share of the disc: 0 at new, 1 at full.
function illumination(f) {
  const p = wrap01(f)
  return (1 - Math.cos(2 * Math.PI * p)) / 2
}

function percent(f) {
  return Math.round(illumination(f) * 100)
}

function phaseName(f) {
  return PHASE_NAMES[phaseIndex(f)]
}

function phaseShort(f) {
  return SHORT_NAMES[phaseIndex(f)]
}

function isWaxing(f) {
  return wrap01(f) < 0.5
}

function isPrincipal(f) {
  return PRINCIPAL[phaseIndex(f)]
}

// Days since the preceding new moon.
function ageDays(f) {
  return wrap01(f) * SYNODIC_MONTH
}

function record(date) {
  const f = forDate(date)
  return {
    date: date,
    fraction: f,
    illumination: illumination(f),
    percent: percent(f),
    name: phaseName(f),
    short: phaseShort(f),
    waxing: isWaxing(f),
    principal: isPrincipal(f),
    ageDays: ageDays(f)
  }
}

// The selected day plus `count - 1` following days, as consecutive calendar
// days. Defaults to six: "today and the next five".
function forecast(date, count) {
  if (!date || !isFinite(date.getTime())) return []
  let n = count === undefined || count === null ? 6 : Number(count)
  if (!isFinite(n) || n < 0) n = 0
  n = Math.min(14, Math.floor(n))
  const base = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  const out = []
  for (let i = 0; i < n; i++) {
    const day = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i)
    const entry = record(day)
    entry.offset = i
    out.push(entry)
  }
  return out
}

// Nearest principal phase on or after the day, within `limit` days. The island
// uses this as the selected day's "additional info"; a principal phase lands
// at least every eight days, so fourteen covers the search.
//
// The returned `at` is the approximate instant of that quarter cycle. It is
// found by measuring how far the day's fraction sits from the nearest quarter
// and scaling by the synodic month. Formatting is left to the caller so the
// shared ClockFmt primitive can apply the shell's 12/24-hour setting. The
// mean orbit makes this rough, but it is genuinely a time rather than a date.
function nextPrincipal(date, limit) {
  if (!date || !isFinite(date.getTime())) return null
  let span = limit === undefined || limit === null ? 14 : Number(limit)
  if (!isFinite(span) || span < 0) span = 14
  span = Math.min(60, Math.floor(span))
  const base = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  for (let i = 0; i <= span; i++) {
    const day = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i)
    const f = forDate(day)
    if (isPrincipal(f)) {
      const target = Math.round(f * 4) / 4
      const at = new Date(day.getTime() + (target - f) * SYNODIC_MONTH * MS_PER_DAY)
      return { name: phaseName(f), days: i, date: day, at: at }
    }
  }
  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    wrap01: wrap01,
    fraction: fraction,
    forDate: forDate,
    phaseIndex: phaseIndex,
    illumination: illumination,
    percent: percent,
    phaseName: phaseName,
    phaseShort: phaseShort,
    isWaxing: isWaxing,
    isPrincipal: isPrincipal,
    ageDays: ageDays,
    record: record,
    forecast: forecast,
    nextPrincipal: nextPrincipal
  }
}

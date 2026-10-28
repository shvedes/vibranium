#!/usr/bin/env node
// Suite: the four pure libraries the shell's services are built on -
// common/ui/CalendarLib, services/privacy/PrivacyLib,
// services/system/PrintersLib and services/weather/Model.js.
//
// Each of these is a `.pragma library` (or, for weather, a plain-JS module
// with the same shape) that the node `vm` hosts exactly like QJSEngine does,
// which is what makes them testable at all. They are grouped here because
// they share one property: every one of them is the place where a private
// fact crosses into something a widget renders. PrivacyLib decides whether a
// screen reads as severed, PrintersLib decides which rows a report may claim
// exist, and weather/Model decides which coordinates may be requested at all.
//
// The privacy half carries the most weight: it is what stops a screen being
// captured while the user believes it is safe, so the severed verdict is
// asserted in every projection it appears in (ledger, island, tooltip), and
// a client-chosen app name is asserted unable to forge a second ledger row.
//
// The clock is never read by any of these modules - callers pass todayString
// and formatters in - so every assertion here is deterministic and
// timezone-free, except jobTime(), which is asserted against a locally
// computed expectation rather than a literal.
//
// Two behaviours are pinned as they are rather than as the comments around
// them read, and both are called out where they are asserted: a `1setOf`
// attribute line is dropped by the printer report parser (so
// printer-state-reasons and the marker pairs are always absent on a real
// report), and the weather model's REQUIRED ICON SET comment omits
// weather-rain, which its own WMO table returns.

import path from 'node:path'
import { loadLib, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, skip, SHELL_DIR, finish,
} from '../../lib/assert.mjs'

const CAL = loadLib(path.join(SHELL_DIR, 'common/ui/CalendarLib.js'))
const PL = loadLib(path.join(SHELL_DIR, 'services/privacy/PrivacyLib.js'))
const PR = loadLib(path.join(SHELL_DIR, 'services/system/PrintersLib.js'))
const WM = loadLib(path.join(SHELL_DIR, 'services/weather/Model.js'))
const WM_SRC = libSource(path.join(SHELL_DIR, 'services/weather/Model.js'))

suite('services/privacy + services/system + services/weather',
  'PrivacyLib, PrintersLib, weather/Model.js')

// ---------------------------------------------------------------------------
// CalendarLib
// ---------------------------------------------------------------------------

section('CalendarLib - keys, week starts and date maths')

group('dateKey is the stable "yyyy-MM-dd" identity of one day', () => {
  eq('january', CAL.dateKey(2024, 0, 5), '2024-01-05')
  eq('december, the two-digit month at the top of the range', CAL.dateKey(2024, 11, 31), '2024-12-31')
  eq('two-digit day', CAL.dateKey(2024, 8, 9), '2024-09-09')
  eq('single digit day', CAL.dateKey(2024, 8, 1), '2024-09-01')
  // month/day are stringified through Number() by pad2, so the caller's
  // QML binding can hand over a QString-ish value without a conversion.
  eq('string arguments', CAL.dateKey('2024', '0', '5'), '2024-01-05')
  eq('month is zero-based, so 0 is January and not the year', CAL.dateKey(2024, 0, 1), '2024-01-01')
  eq('the format is fixed width for every field', CAL.dateKey(999, 0, 1), '999-01-01')
})

group('keyForDate reads the local calendar fields, not the UTC ones', () => {
  eq('local midnight', CAL.keyForDate(new Date(2024, 0, 5)), '2024-01-05')
  eq('last millisecond of the day is still that day', CAL.keyForDate(new Date(2024, 0, 5, 23, 59, 59)), '2024-01-05')
  eq('a date built from a local string', CAL.keyForDate(new Date(2024, 11, 31, 12, 0)), '2024-12-31')
  // The grid cells compare against this key and against each other, so the
  // two must be produced the same way for any given day.
  eq('keyForDate agrees with dateKey on its own fields', CAL.keyForDate(new Date(2024, 5, 9)), CAL.dateKey(2024, 5, 9))
})

group('normalizeWeekStart coerces anything into 0..6', () => {
  for (let i = 0; i <= 6; i++) eq(`number ${i} passes through`, CAL.normalizeWeekStart(i), i)
  // Out-of-range numbers wrap rather than clamp, so a setting of 7 means
  // "Sunday again" and -1 means the day before Sunday.
  eq('7 wraps to 0', CAL.normalizeWeekStart(7), 0)
  eq('8 wraps to 1', CAL.normalizeWeekStart(8), 1)
  eq('13 wraps to 6', CAL.normalizeWeekStart(13), 6)
  eq('-1 wraps to 6', CAL.normalizeWeekStart(-1), 6)
  eq('-7 wraps to 0', CAL.normalizeWeekStart(-7), 0)
  eq('a fractional value is rounded first', CAL.normalizeWeekStart(1.4), 1)
  eq('and rounds half away from zero', CAL.normalizeWeekStart(1.5), 2)
  eq('6.6 rounds up and wraps to 0', CAL.normalizeWeekStart(6.6), 0)
  // Non-finite numbers never reach the modulo, so they take the fallback.
  eq('NaN is not a configuration', CAL.normalizeWeekStart(NaN), 1)
  eq('Infinity is not a configuration', CAL.normalizeWeekStart(Infinity), 1)
})

group('normalizeWeekStart accepts names, three-letter abbreviations and numbers as text', () => {
  eq('full name', CAL.normalizeWeekStart('sunday'), 0)
  eq('full name, mixed case', CAL.normalizeWeekStart('THU'), 4)
  eq('full name, padded', CAL.normalizeWeekStart(' sat '), 6)
  eq('three-letter abbreviation', CAL.normalizeWeekStart('mon'), 1)
  eq('numeric text is parsed after the name table misses', CAL.normalizeWeekStart('7'), 0)
  eq('negative numeric text wraps', CAL.normalizeWeekStart('-1'), 6)
  // The three-letter match is an exact prefix comparison, so a trailing dot
  // or any longer abbreviation misses and falls through to the fallback.
  eq('"Sun." is not the abbreviation', CAL.normalizeWeekStart('Sun.'), 1)
  eq('an unknown word is a configuration error, not a day', CAL.normalizeWeekStart('nonsense'), 1)
  eq('empty string is a configuration error', CAL.normalizeWeekStart(''), 1)
  eq('null is a configuration error', CAL.normalizeWeekStart(null), 1)
  eq('undefined is a configuration error', CAL.normalizeWeekStart(undefined), 1)
})

group('the fallback argument is itself normalized, and defaults to Monday', () => {
  eq('numeric fallback', CAL.normalizeWeekStart('bogus', 3), 3)
  eq('numeric fallback 0 survives (Monday is not the only default)', CAL.normalizeWeekStart('bogus', 0), 0)
  eq('name fallback', CAL.normalizeWeekStart('bogus', 'friday'), 5)
  eq('out-of-range fallback wraps too', CAL.normalizeWeekStart('bogus', 9), 2)
  // A fallback that is not a number or a string is ignored entirely, so
  // `false` does not become Sunday.
  eq('boolean fallback is ignored, Monday wins', CAL.normalizeWeekStart('bogus', false), 1)
  eq('no fallback at all is Monday', CAL.normalizeWeekStart(), 1)
  eq('null fallback is Monday', CAL.normalizeWeekStart(null, null), 1)
  // A configured value always beats the fallback.
  eq('a good value ignores a hostile fallback', CAL.normalizeWeekStart(2, 9), 2)
})

group('weekdayOrder is the seven display columns from the normalized start', () => {
  eq('Sunday', CAL.weekdayOrder(0), [0, 1, 2, 3, 4, 5, 6])
  eq('Monday', CAL.weekdayOrder(1), [1, 2, 3, 4, 5, 6, 0])
  eq('Saturday', CAL.weekdayOrder(6), [6, 0, 1, 2, 3, 4, 5])
  eq('a name is accepted', CAL.weekdayOrder('sunday'), [0, 1, 2, 3, 4, 5, 6])
  eq('7 wraps like normalizeWeekStart does', CAL.weekdayOrder(7), [0, 1, 2, 3, 4, 5, 6])
  eq('a bad value falls back to Monday', CAL.weekdayOrder('junk'), [1, 2, 3, 4, 5, 6, 0])
  eq('undefined is Monday', CAL.weekdayOrder(), [1, 2, 3, 4, 5, 6, 0])
  // The column order is a rotation, so it is always a permutation of 0..6 -
  // the invariant a header-row binding depends on.
  for (let s = 0; s < 7; s++) {
    is(`order for start ${s} is a permutation of the week`,
      CAL.weekdayOrder(s), (v) => v.length === 7 && v.every(d => d >= 0 && d <= 6) && new Set(v).size === 7,
      'seven distinct weekday indices')
  }
})

section('CalendarLib - day of year and the leap-year rule')

group('dayOfYear is 1-based and lands on the documented boundaries', () => {
  eq('1 January', CAL.dayOfYear(2024, 0, 1), 1)
  eq('1 January, common year', CAL.dayOfYear(2023, 0, 1), 1)
  eq('28 February, leap year', CAL.dayOfYear(2024, 1, 28), 59)
  eq('28 February, common year', CAL.dayOfYear(2023, 1, 28), 59)
  // The difference is 29 February itself, which is the only day that moves.
  eq('1 March, leap year', CAL.dayOfYear(2024, 2, 1), 61)
  eq('1 March, common year', CAL.dayOfYear(2023, 2, 1), 60)
  eq('29 February exists in a leap year', CAL.dayOfYear(2024, 2 - 1, 29), 60)
  eq('29 February does not exist in a common year (rolls to 1 March)', CAL.dayOfYear(2023, 1, 29), 60)
  eq('31 December, leap year', CAL.dayOfYear(2024, 11, 31), 366)
  eq('31 December, common year', CAL.dayOfYear(2023, 11, 31), 365)
  // Day zero of January is the last day of the previous year, so the answer
  // is 0 rather than a negative number.
  eq('the day before 1 January is 0', CAL.dayOfYear(2024, 0, 0), 0)
})

group('dayOfYear increments by exactly one per day, across every month boundary', () => {
  // A month-boundary slip is the classic date-maths defect, so the whole of
  // a leap year and a common year is walked rather than sampled. The day
  // count per month comes from Date, because 30/31-day months are where the
  // off-by-one would show.
  for (const year of [2023, 2024]) {
    let expect = 1
    let broken = null
    for (let month = 0; month < 12 && broken === null; month++) {
      const inMonth = new Date(year, month + 1, 0).getDate()
      for (let day = 1; day <= inMonth; day++) {
        if (CAL.dayOfYear(year, month, day) !== expect) { broken = `${year}-${month + 1}-${day}`; break }
        expect++
      }
    }
    eq(`every day of ${year} increments by one`, broken, null)
    eq(`${year} ends on its own length`, expect - 1, CAL.daysInYear(year))
  }
})

group('daysInYear applies the full Gregorian rule', () => {
  eq('2024, divisible by 4', CAL.daysInYear(2024), 366)
  eq('2023, not divisible by 4', CAL.daysInYear(2023), 365)
  eq('2020, divisible by 4', CAL.daysInYear(2020), 366)
  // The century rules are the part that is always got wrong: divisible by
  // 100 is NOT enough, and 400 is the only exception.
  eq('1900, divisible by 100 but not 400 - common', CAL.daysInYear(1900), 365)
  eq('2100, divisible by 100 but not 400 - common', CAL.daysInYear(2100), 365)
  eq('2000, divisible by 400 - leap', CAL.daysInYear(2000), 366)
  eq('1600, divisible by 400 - leap', CAL.daysInYear(1600), 366)
  eq('1700, divisible by 100 but not 400 - common', CAL.daysInYear(1700), 365)
  eq('29 February reads as day 60 only in a leap year', CAL.dayOfYear(2024, 1, 29) === 60 && CAL.dayOfYear(2023, 1, 29) === 60, true)
  eq('1 March is day 60 in a common year', CAL.dayOfYear(2023, 2, 1), 60)
  eq('1 March is day 61 in a leap year', CAL.dayOfYear(2000, 2, 1), 61)
})

section('CalendarLib - year progress')

group('yearProgress runs 0 at the first day to 1 at the last', () => {
  eq('1 January is 0', CAL.yearProgress(2024, 0, 1), 0)
  eq('2 January has one day behind it', CAL.yearProgress(2024, 0, 2), 1 / 366)
  eq('1 July of a leap year is just under half', CAL.yearProgress(2024, 6, 1), 182 / 366)
  eq('30 June of a common year is just under half', CAL.yearProgress(2023, 5, 30), 180 / 365)
  // The source comment states the contract: whole days completed over days
  // in the year, so the last day is (total-1)/total and never reaches 1.
  approx('31 December of a leap year', CAL.yearProgress(2024, 11, 31), 365 / 366)
  is('31 December of a leap year is below 1', CAL.yearProgress(2024, 11, 31), (v) => v < 1 && v > 0.99, 'just under 1')
  // Out-of-range days are clamped rather than allowed to escape 0..1.
  eq('the day before 1 January clamps to 0', CAL.yearProgress(2024, 0, 0), 0)
  eq('the day after 31 December clamps to 1', CAL.yearProgress(2024, 11, 32), 1)
  is('every month boundary stays inside 0..1', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map(m => CAL.yearProgress(2024, m, 15)),
    (v) => v.every(x => x >= 0 && x <= 1), 'clamped into 0..1')
})

group('yearProgressPercent is the rounded whole percent', () => {
  eq('1 January', CAL.yearProgressPercent(2024, 0, 1), 0)
  eq('1 July, leap year', CAL.yearProgressPercent(2024, 6, 1), 50)
  eq('30 June, common year', CAL.yearProgressPercent(2023, 5, 30), 49)
  // Both years' last day round up to 100, which is what the ring wants.
  eq('31 December, leap year', CAL.yearProgressPercent(2024, 11, 31), 100)
  eq('31 December, common year', CAL.yearProgressPercent(2023, 11, 31), 100)
  is('the percent never leaves 0..100', [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map(m => CAL.yearProgressPercent(2023, m - 1, 28)),
    (v) => v.every(x => x >= 0 && x <= 100), 'percent inside 0..100')
  is('percent is monotonic through a year', (() => {
    let last = -1
    for (let d = 1; d <= 365; d++) {
      const pct = CAL.yearProgressPercent(2023, 0, d)
      if (pct < last) return false
      last = pct
    }
    return last === 100
  })(), (v) => v === true, 'never goes backwards and ends at 100')
})

section('CalendarLib - the fixed six-week month grid')

group('the grid is always 6 rows of 7, whatever the month needs', () => {
  // The source comment gives the reason: a fixed grid keeps the calendar the
  // same height in every month so stepping through the year never makes the
  // popup jump under the pointer. So 42 cells is a contract, not an accident.
  for (const [year, month] of [[2024, 0], [2024, 1], [2024, 8], [2021, 1], [2015, 1], [2022, 0], [2024, 11]]) {
    eq(`${year}-${month + 1} has 42 cells`, CAL.monthGrid(year, month, 1, '').length, 42)
  }
  const cells = CAL.monthGrid(2024, 8, 1, '')
  eq('every cell carries the eight view fields', Object.keys(cells[0]), ['key', 'year', 'month', 'day', 'weekday', 'inMonth', 'weekend', 'today'])
  is('every key is unique', cells, (v) => new Set(v.map(c => c.key)).size === 42, '42 distinct keys')
  is('the cells are consecutive calendar days', cells, (v) => v.every((c, i) => i === 0 || CAL.keyForDate(new Date(v[i - 1].year, v[i - 1].month, v[i - 1].day + 1)) === c.key),
    'each cell is the day after the previous one')
})

group('a six-week month fills the last row', () => {
  // January 2022 starts on a Saturday: with a Monday week start there are
  // five leading cells and 31 days, so the grid needs a sixth row.
  const cells = CAL.monthGrid(2022, 0, 1, '')
  eq('first cell is the Monday before the 1st', cells[0].key, '2021-12-27')
  eq('five leading cells from the previous month', cells.filter(c => !c.inMonth).slice(0, 5).map(c => c.day), [27, 28, 29, 30, 31])
  eq('the last in-month day is 31 January', cells.filter(c => c.inMonth).length, 31)
  eq('the 31st lands alone in the sixth row', cells[35].key, '2022-01-31')
  eq('the sixth row holds exactly one in-month cell', cells.slice(35).filter(c => c.inMonth).length, 1)
  eq('the grid ends six days into February', cells[41].key, '2022-02-06')
})

group('a five-week month leaves the last row empty', () => {
  // February 2015 starts on a Sunday, so six leading cells plus 28 days fit
  // in five rows and the sixth is entirely next month.
  const cells = CAL.monthGrid(2015, 1, 1, '')
  eq('first cell is the Monday before 1 February', cells[0].key, '2015-01-26')
  eq('six leading cells from January', cells.slice(0, 6).map(c => c.key), ['2015-01-26', '2015-01-27', '2015-01-28', '2015-01-29', '2015-01-30', '2015-01-31'])
  eq('28 in-month cells', cells.filter(c => c.inMonth).length, 28)
  eq('the sixth row has no in-month cell at all', cells.slice(35).filter(c => c.inMonth).length, 0)
  eq('the grid ends on 8 March', cells[41].key, '2015-03-08')
  eq('the last in-month cell is the 28th', cells.filter(c => c.inMonth).slice(-1)[0].key, '2015-02-28')
})

group('every first-of-the-month weekday is handled', () => {
  // Walk a whole year with a fixed Monday week start: between them the twelve
  // 1sts cover all seven weekday offsets, so every leading count is exercised.
  const seen = new Set()
  for (let month = 0; month < 12; month++) {
    const cells = CAL.monthGrid(2024, month, 1, '')
    const leading = cells.findIndex(c => c.inMonth)
    seen.add(leading)
    eq(`2024-${String(month + 1).padStart(2, '0')} starts on a Monday-column grid`, cells[0].weekday, 1)
    eq(`2024-${String(month + 1).padStart(2, '0')} leading count matches the 1st's weekday`, leading,
      (new Date(2024, month, 1).getDay() - 1 + 7) % 7)
    eq(`2024-${String(month + 1).padStart(2, '0')} keeps every day of the month`, cells.filter(c => c.inMonth).length,
      new Date(2024, month + 1, 0).getDate())
    is(`2024-${String(month + 1).padStart(2, '0')} rows are each 7 cells`, cells, (v) => {
      for (let r = 0; r < 6; r++) {
        const row = v.slice(r * 7, r * 7 + 7)
        if (row.length !== 7) return false
        for (let i = 1; i < 7; i++) if (row[i].weekday !== (row[i - 1].weekday + 1) % 7) return false
      }
      return true
    }, 'each row is seven consecutive weekdays')
  }
  eq('all seven possible leading counts were exercised', [...seen].sort((a, b) => a - b), [0, 1, 2, 3, 4, 5, 6])
})

group('February in a leap year gains the 29th, in a common year it does not', () => {
  const leap = CAL.monthGrid(2024, 1, 1, '')
  const common = CAL.monthGrid(2023, 1, 1, '')
  eq('2024 February has 29 in-month cells', leap.filter(c => c.inMonth).length, 29)
  eq('2023 February has 28', common.filter(c => c.inMonth).length, 28)
  contains('the 29th is present in the leap grid', leap.map(c => c.key), '2024-02-29')
  notContains('and absent from the common grid', common.map(c => c.key), '2023-02-29')
  // The extra day pushes the 1st of March one column later on top of the
  // weekday difference, so the two grids are offset by two, not one.
  eq('1 March 2024 sits two columns right of 1 March 2023',
    leap.findIndex(c => c.key === '2024-03-01') - common.findIndex(c => c.key === '2023-03-01'), 2)
  eq('and the leap 29th is a Thursday', leap.find(c => c.key === '2024-02-29').weekday, 4)
  eq('while the common 28th is a Tuesday', common.find(c => c.key === '2023-02-28').weekday, 2)
})

group('a December grid rolls into the next year', () => {
  // 1 December 2024 is a Sunday, so with a Monday week start there are six
  // leading cells and 31 days: the sixth row holds two December days and five
  // January ones.
  const cells = CAL.monthGrid(2024, 11, 1, '2025-01-01')
  eq('the first cell is in November', cells[0].key, '2024-11-25')
  eq('31 December cells carry the viewed year', cells.filter(c => c.inMonth).length, 31)
  eq('the last row ends the month and starts the year', cells.slice(35).map(c => c.key),
    ['2024-12-30', '2024-12-31', '2025-01-01', '2025-01-02', '2025-01-03', '2025-01-04', '2025-01-05'])
  const rolled = cells.slice(37)
  is('the rolled cells are marked as not in the viewed month', rolled, (v) => v.every(c => c.inMonth === false), 'all outside')
  is('and they carry the next year in their own fields', rolled, (v) => v.every(c => c.year === 2025 && c.month === 0), 'year 2025, month 0')
  eq('the next new year is today exactly once', cells.filter(c => c.today).map(c => c.key), ['2025-01-01'])
  // inMonth compares year as well as month, which is what keeps the trailing
  // days of the viewed month in-month while next January is not.
  eq('the trailing December days are still in-month', cells.slice(35, 37).map(c => c.inMonth), [true, true])
  eq('and the January ones are not', rolled.every(c => c.inMonth === false), true)
})

group('the today flag matches exactly one cell, or none', () => {
  eq('a day inside the grid', CAL.monthGrid(2024, 8, 1, '2024-09-15').filter(c => c.today).map(c => c.key), ['2024-09-15'])
  eq('a day outside the grid marks nothing', CAL.monthGrid(2024, 8, 1, '1999-01-01').filter(c => c.today).length, 0)
  eq('a today key in the leading days is still found', CAL.monthGrid(2024, 8, 1, '2024-08-26').filter(c => c.today).map(c => c.key), ['2024-08-26'])
  eq('an empty today key marks nothing', CAL.monthGrid(2024, 8, 1, '').filter(c => c.today).length, 0)
  eq('an omitted today key marks nothing', CAL.monthGrid(2024, 8, 1).filter(c => c.today).length, 0)
  // The key is compared as text, so a non-string is stringified once.
  eq('a numeric key never matches the zero-padded key', CAL.monthGrid(2024, 8, 1, 20240915).filter(c => c.today).length, 0)
})

group('weekend is Sunday and Saturday whatever the week start is', () => {
  const cells = CAL.monthGrid(2024, 8, 1, '')
  const byWeekday = [0, 1, 2, 3, 4, 5, 6].map(d => cells.find(c => c.weekday === d).weekend)
  eq('only weekday 0 and weekday 6 are weekend, in any column order', byWeekday, [true, false, false, false, false, false, true])
  const sunday = CAL.monthGrid(2024, 8, 0, '')
  eq('a Sunday-start grid marks the same two weekdays', [0, 1, 2, 3, 4, 5, 6].map(d => sunday.find(c => c.weekday === d).weekend),
    [true, false, false, false, false, false, true])
  eq('exactly 12 weekend cells in 42', cells.filter(c => c.weekend).length, 12)
})

section('CalendarLib - month stepping')

group('stepMonth walks the year and wraps at both ends', () => {
  eq('December forward into January', CAL.stepMonth(2024, 11, 1), { year: 2025, month: 0 })
  eq('January backward into December', CAL.stepMonth(2024, 0, -1), { year: 2023, month: 11 })
  eq('a zero delta is the same month', CAL.stepMonth(2024, 5, 0), { year: 2024, month: 5 })
  eq('forward twelve months', CAL.stepMonth(2024, 5, 12), { year: 2025, month: 5 })
  eq('backward thirteen months', CAL.stepMonth(2024, 5, -13), { year: 2023, month: 4 })
  eq('twenty-four months forward wraps the year', CAL.stepMonth(2024, 0, 24), { year: 2026, month: 0 })
  // The date is constructed with day 1, so a month-length quirk can never
  // turn a step into the neighbouring month.
  eq('always lands on day 1 internally: a 31-day month behaves like a 30-day one', CAL.stepMonth(2024, 0, 1), { year: 2024, month: 1 })
  eq('and so does February', CAL.stepMonth(2024, 1, 1), { year: 2024, month: 2 })
  eq('string arguments are coerced', CAL.stepMonth(2024, '5', '2'), { year: 2024, month: 7 })
  eq('the result carries only the two fields the caller binds', Object.keys(CAL.stepMonth(2024, 5, 1)), ['year', 'month'])
})

group('a nullish month or delta produces an unusable answer rather than a wrong one', () => {
  // Number(undefined) is NaN, so the Date is invalid and both fields read
  // NaN. The suite pins that so a caller that forgets an argument fails
  // loudly (NaN never equals a month index) instead of silently sticking.
  eq('undefined delta', CAL.stepMonth(2024, 5, undefined), { year: NaN, month: NaN })
  eq('undefined month', CAL.stepMonth(2024, undefined, 1), { year: NaN, month: NaN })
  eq('null delta', CAL.stepMonth(2024, 5, null), { year: 2024, month: 5 })
  is('no argument at all is NaN, not a month', CAL.stepMonth(2024), (v) => Number.isNaN(v.month), 'month is NaN')
})

group('walking twelve steps forward and back returns to the start', () => {
  for (const [year, month] of [[2024, 0], [2024, 11], [2023, 5], [2024, 1]]) {
    let y = year
    let m = month
    for (let i = 0; i < 12; i++) {
      const s = CAL.stepMonth(y, m, 1)
      y = s.year
      m = s.month
    }
    eq(`${year}-${month + 1} forward twelve times`, { year: y, month: m }, { year: year + 1, month })
  }
})

section('CalendarLib - the layout constants are one source of truth')

group('the derived sizes agree with their own definitions', () => {
  // Calendar.qml paints from these and ClockIsland sizes its card from them,
  // so the relationships below are the whole point of the block.
  eq('gridW is seven columns of cellW with six gaps', CAL.gridW, 7 * CAL.cellW + 6 * CAL.cellGap)
  eq('gridH is six rows of cellH with five gaps', CAL.gridH, 6 * CAL.cellH + 5 * CAL.cellGap)
  // The inter-cell gap is inside the cell pitch, not added on top of it: a
  // host that divides the width by 7 gets the pitch minus a trailing gap, so
  // the pitch is recovered by adding that gap back before dividing.
  approx('the column pitch is (gridW + one gap) / 7', (CAL.gridW + CAL.cellGap) / 7, CAL.cellW + CAL.cellGap)
  approx('the row pitch is (gridH + one gap) / 6', (CAL.gridH + CAL.cellGap) / 6, CAL.cellH + CAL.cellGap)
  eq('the six gaps are the interior ones only', CAL.gridW, 7 * (CAL.cellW + CAL.cellGap) - CAL.cellGap)
  eq('and so are the five', CAL.gridH, 6 * (CAL.cellH + CAL.cellGap) - CAL.cellGap)
  eq('cell area', CAL.cellW * CAL.cellH, 42 * 28)
  is('a cell is wider than it is tall', CAL.cellW > CAL.cellH, (v) => v === true, 'landscape cell')
})

group('the vertical stack is header blocks then the grid, and nothing else', () => {
  eq('gridY is the three header blocks with the 8px token between and after', CAL.gridY,
    CAL.titleH + CAL.SP + CAL.yearBlockH + CAL.SP + CAL.weekdayRowH + CAL.SP)
  eq('contentHeight is the grid offset plus the grid', CAL.contentHeight, CAL.gridY + CAL.gridH)
  approx('contentHeight - gridY is exactly the grid height', CAL.contentHeight - CAL.gridY, CAL.gridH)
  is('the header stack is shorter than the grid', CAL.gridY < CAL.gridH, (v) => v === true, 'gridY < gridH')
  is('the painted height is the header plus the grid', CAL.contentHeight > CAL.gridY, (v) => v === true, 'contentHeight > gridY')
  // The spacing token is duplicated from Ui.s because a .js file cannot
  // import the QML singleton, so its value is pinned here instead.
  eq('the spacing token is Ui.s', CAL.SP, 8)
  eq('the header blocks are title, year and weekday', [CAL.titleH, CAL.yearBlockH, CAL.weekdayRowH], [24, 32, 16])
  eq('the published numbers', { cellW: CAL.cellW, cellH: CAL.cellH, cellGap: CAL.cellGap, gridW: CAL.gridW, gridH: CAL.gridH, gridY: CAL.gridY, contentHeight: CAL.contentHeight },
    { cellW: 42, cellH: 28, cellGap: 2, gridW: 306, gridH: 178, gridY: 96, contentHeight: 274 })
  eq('MS_PER_DAY is the day maths constant', CAL.MS_PER_DAY, 24 * 60 * 60 * 1000)
})

// ---------------------------------------------------------------------------
// PrivacyLib
// ---------------------------------------------------------------------------

// A stand-in for the controller's theme lookup: rows resolve their app-name
// tint through it, so the suite pins the hex around it exactly.
const colorOf = (k) => ({ green: '#00ff88', purple: '#b07fff', orange: '#ff9f43' }[k] ?? '#888888')

section('PrivacyLib - the process boundary')

group('a cut is three commands, and only the argv is built here', () => {
  eq('the snapshot is one pw-dump', PL.dumpArgv(), ['pw-dump'])
  // A link id is a graph number and travels as its own argv element, so no
  // shell source is ever built from it.
  eq('the cut', PL.unlinkArgv(41), ['pw-link', '-d', '41'])
  eq('a string id is stringified, not concatenated', PL.unlinkArgv('7'), ['pw-link', '-d', '7'])
  eq('a float id loses its fraction (it is a graph number)', PL.unlinkArgv(41.7), ['pw-link', '-d', '41.7'])
  eq('a nullish id still yields a five-element-free argv, not a crash', PL.unlinkArgv(null), ['pw-link', '-d', 'null'])
  eq('an id that looks like a flag is not an option', PL.unlinkArgv('-rf'), ['pw-link', '-d', '-rf'])
})

group('relinkArgv restores an exact endpoint quad, in create-link order', () => {
  eq('the four endpoints, then linger', PL.relinkArgv([10, 0, 20, 1]),
    ['pw-cli', 'create-link', '10', '0', '20', '1', '{ "object.linger": true }'])
  eq('every element is a string, so no element can be a number', PL.relinkArgv([10, 0, 20, 1]).every(e => typeof e === 'string'), true)
  // linger keeps the restored link alive past this command's own exit, so a
  // link that did land is not torn down with the shell that made it.
  eq('linger is the seventh element and is exactly this object', PL.relinkArgv([1, 2, 3, 4])[6], '{ "object.linger": true }')
  eq('string endpoints pass through unchanged', PL.relinkArgv(['10', '0', '20', '1'])[2], '10')
  eq('a missing endpoint becomes "undefined" rather than a short argv', PL.relinkArgv([10, 0]).length, 7)
  // There is no guard on the quad itself: a caller that reaches relinkArgv
  // without one throws here rather than spawning a link with no endpoints.
  throws('a null quad throws instead of building a partial argv', () => PL.relinkArgv(null))
})

group('cleanLinkIds keeps numbers only, deduplicated, in first-seen order', () => {
  eq('duplicates fold, whether numeric or textual', PL.cleanLinkIds([1, '1', 2, 2, 3]), [1, 2, 3])
  eq('order is first-seen, not sorted', PL.cleanLinkIds([9, 3, 7]), [9, 3, 7])
  eq('non-numeric text is dropped', PL.cleanLinkIds([1, 'abc', 2]), [1, 2])
  // The caller collects ids from per-node lookups, so a sparse array is the
  // realistic input: the hole reads as undefined, which is not a number.
  eq('holes are dropped, the rest survive', PL.cleanLinkIds([1, undefined, 3]), [1, 3])
  eq('an empty list is empty', PL.cleanLinkIds([]), [])
  // Number() coercion, not a numeric check: the source comment says "a
  // non-numeric or repeated id would spawn a child that cannot succeed", and
  // the falsy-but-coercible values below are the ones that get through.
  eq('null coerces to 0', PL.cleanLinkIds([null]), [0])
  eq('an empty string coerces to 0', PL.cleanLinkIds(['']), [0])
  eq('true coerces to 1', PL.cleanLinkIds([true]), [1])
  eq('false and "" collapse onto 0 with null', PL.cleanLinkIds([null, false, '']), [0])
  eq('whitespace is 0 too', PL.cleanLinkIds(['   ']), [0])
  eq('an exponential id is a number', PL.cleanLinkIds(['1e2']), [100])
  noThrow('a null list throws only at the length read, so it is not passed', () => PL.cleanLinkIds([1, 2]))
})

group('linkQuads reads four numbers per wanted link and guesses nothing', () => {
  const dump = JSON.stringify([
    { type: 'PipeWire:Interface:Link', id: 41, info: { 'output-node-id': 10, 'output-port-id': 0, 'input-node-id': 20, 'input-port-id': 1 } },
    { type: 'PipeWire:Interface:Node', id: 10, info: { node: { name: 'obs' } } },
    { type: 'PipeWire:Interface:Link', id: 42, info: { 'output-node-id': 11, 'output-port-id': 0, 'input-node-id': 20, 'input-port-id': 2 } },
    { type: 'PipeWire:Interface:Link', id: 43, info: { 'output-node-id': 12 } },
  ])
  eq('two wanted links with four endpoints each', PL.linkQuads(dump, [41, 42]), [[10, 0, 20, 1], [11, 0, 20, 2]])
  eq('a link with a missing endpoint is skipped, not half-restored', PL.linkQuads(dump, [43]), [])
  eq('a node object is never a link', PL.linkQuads(dump, [10]), [])
  eq('links that were not asked for are not returned', PL.linkQuads(dump, []), [])
  eq('numeric text ids match', PL.linkQuads(dump, ['41']), [[10, 0, 20, 1]])
  // Anything unparseable, non-array or not a dump resolves to no quad, which
  // the restore reports as having nothing to relink rather than guessing.
  eq('non-JSON text', PL.linkQuads('not a dump', [41]), [])
  eq('a JSON object instead of an array', PL.linkQuads('{"a":1}', [41]), [])
  eq('the literal null', PL.linkQuads('null', [41]), [])
  eq('an empty array', PL.linkQuads('[]', [41]), [])
  eq('string endpoints in the dump are still numbers on the way out', PL.linkQuads(
    '[{"type":"PipeWire:Interface:Link","id":"41","info":{"output-node-id":"10","output-port-id":"0","input-node-id":"20","input-port-id":"1"}}]',
    ['41']), [[10, 0, 20, 1]])
  eq('a null entry in the array is skipped, not dereferenced', PL.linkQuads('[null]', [41]), [])
  noThrow('an empty dump is not an error', () => PL.linkQuads('[]', [41]))
})

section('PrivacyLib - the redaction policy')

group('_hex is fixed width whatever it is given', () => {
  eq('zero', PL._hex(0), '00000000')
  eq('a small value is zero-padded', PL._hex(255), '000000ff')
  eq('a single hex digit', PL._hex(7), '00000007')
  eq('a full word', PL._hex(0xdeadbeef), 'deadbeef')
  // >>>0 wraps, so a negative digest is the same 32 bits read unsigned.
  eq('a negative value wraps rather than producing a minus sign', PL._hex(-1), 'ffffffff')
  eq('a value wider than 32 bits is truncated, not lengthened', PL._hex(0x123456789), '23456789')
  eq('a string is coerced through >>>0', PL._hex('7'), '00000007')
  is('always eight characters', [0, 1, -1, 1e9, 0x7fffffff].map(v => PL._hex(v)), (v) => v.every(s => s.length === 8), 'width 8')
  is('always lowercase hex', [0, 255, 0xabcdef].map(v => PL._hex(v)), (v) => v.every(s => /^[0-9a-f]{8}$/.test(s)), 'lowercase hex only')
})

group('gateDigest is a fixed 16-character key, not a name', () => {
  const slot = PL.slotKey('firefox', 'mic')
  eq('a normal pair', PL.gateDigest(slot), PL.gateDigest('firefox\nmic'))
  eq('the digest is 16 characters', PL.gateDigest(slot).length, 16)
  eq('with the gate prefix the whole key is 18', ('p:' + PL.gateDigest(slot)).length, 18)
  // The header is explicit that the width must not depend on the value: an
  // over-long application name must not be able to push the key past the
  // gate's own 128-character limit.
  eq('a 5000-character name is still 16 characters', PL.gateDigest(PL.slotKey('x'.repeat(5000), 'mic')).length, 16)
  eq('an empty slot is 16 too', PL.gateDigest('').length, 16)
  eq('and it is stable across calls', PL.gateDigest(slot), PL.gateDigest(slot))
  notContains('the digest never carries the app name', PL.gateDigest(slot), 'firefox')
  notContains('nor the key', PL.gateDigest(slot), 'mic')
  is('lowercase hex only', PL.gateDigest(slot), (v) => /^[0-9a-f]{16}$/.test(v), '16 lowercase hex characters')
})

group('two different pairs cannot share a digest', () => {
  const pairs = [
    ['firefox', 'mic'], ['firefox', 'cam'], ['firefox', 'share'],
    ['discord', 'mic'], ['', 'mic'], ['mic', ''], ['a\nb', 'mic'], ['a', 'mic\nb'],
  ]
  const digests = pairs.map(p => PL.gateDigest(PL.slotKey(p[0], p[1])))
  eq('every pair in the set digests differently', new Set(digests).size, pairs.length)
  // The key leg is a closed set of three tokens, none of which carries a
  // newline, so an app name containing one cannot impersonate another pair.
  for (const key of ['mic', 'cam', 'share']) {
    ne(`"evil\\n${key}" is not the pair "evil"/${key}`, PL.slotKey(`evil\n${key}`, key), PL.slotKey('evil', key))
    ne(`and their digests differ`, PL.gateDigest(PL.slotKey(`evil\n${key}`, key)), PL.gateDigest(PL.slotKey('evil', key)))
  }
  // The separator alone is not proof against a *malformed* key leg: an app
  // named "evil\n" collides with a key of "\nmic". That is unreachable
  // because the key leg is one of three tokens, none carrying a newline.
  eq('a malformed key leg is what the separator cannot defend', PL.slotKey('evil\n', 'mic'), PL.slotKey('evil', '\nmic'))
  ne('but no real key produces that shape', PL.slotKey('evil\n', 'mic'), PL.slotKey('evil', 'mic'))
  ne('and their digests differ', PL.gateDigest(PL.slotKey('evil\n', 'mic')), PL.gateDigest(PL.slotKey('evil', 'mic')))
})

group('slotKey is app + newline + key', () => {
  eq('the ordinary shape', PL.slotKey('firefox', 'mic'), 'firefox\nmic')
  eq('both legs may be empty', PL.slotKey('', ''), '\n')
  eq('a name that already contains a newline is passed through unchanged', PL.slotKey('a\nb', 'mic'), 'a\nb\nmic')
  is('exactly one separator per pair when neither leg carries one', PL.slotKey('x', 'mic'), (v) => v.split('\n').length === 2, 'two fields')
})

group('isSevered is remembered AND currently unlinkless', () => {
  eq('a slot that was never marked', PL.isSevered({}, 'a\nmic', []), false)
  eq('remembered and no live links left', PL.isSevered({ 'a\nmic': { links: [] } }, 'a\nmic', []), true)
  // The severed map is a display concern, not the truth: external
  // renegotiation that puts a link back heals the display with no
  // bookkeeping write, so a remembered mark with live links reads connected.
  eq('remembered but a link reappeared', PL.isSevered({ 'a\nmic': { links: [] } }, 'a\nmic', [7]), false)
  eq('a cut that landed on an already-unlinked target stays marked', PL.isSevered({ 'a\nmic': { links: [] } }, 'a\nmic'), true)
  eq('an empty live list is the same as no list', PL.isSevered({ 'a\nmic': { links: [] } }, 'a\nmic', null), true)
  // Key presence is the memory, not the value: a falsy marker still counts
  // as remembered, which is what keeps a half-written mark from reading as
  // connected.
  eq('a falsy marker value is still remembered', PL.isSevered({ 'a\nmic': false }, 'a\nmic', []), true)
  eq('but a falsy marker with live links is not severed', PL.isSevered({ 'a\nmic': false }, 'a\nmic', [1]), false)
  eq('a mark for a different slot does not apply', PL.isSevered({ 'a\nmic': { links: [] } }, 'b\nmic', []), false)
  // The read is a plain property access, so an inherited name is not
  // "undefined" and counts as remembered. That is unreachable in practice,
  // because a real slot always carries the separator.
  eq('an inherited name would read as remembered', PL.isSevered({}, 'toString', []), true)
  eq('but a real slot can never be one', PL.isSevered({}, PL.slotKey('toString', 'mic'), []), false)
  eq('nor one for constructor', PL.isSevered({}, PL.slotKey('constructor', 'share'), []), false)
})

group('refusalText is a closed table of reasons', () => {
  eq('the gate refused the pair', PL.refusalText('gate_refused'), 'refused before anything ran')
  eq('the pw-dump snapshot failed', PL.refusalText('snapshot_refused'), 'link snapshot failed')
  eq('a restore with nothing remembered', PL.refusalText('nothing_to_restore'), 'nothing to restore')
  // A refusal is a code, never a node id, a link quad or pw-dump text, so an
  // unknown code is echoed rather than expanded.
  eq('an unknown code is passed through verbatim', PL.refusalText('mystery'), 'mystery')
  eq('a number is stringified', PL.refusalText(7), '7')
  eq('the closed table has exactly these three reasons',
    ['gate_refused', 'snapshot_refused', 'nothing_to_restore'].map(c => PL.refusalText(c)),
    ['refused before anything ran', 'link snapshot failed', 'nothing to restore'])
  notContains('no reason mentions a node id or a link', PL.refusalText('gate_refused'), 'node')
  notContains('and none mentions pw-dump output', PL.refusalText('snapshot_refused'), 'pw-dump')
})

group('shortApp bounds the one client-controlled string that reaches a toast', () => {
  const long = 'A'.repeat(120)
  eq('a short name is untouched', PL.shortApp('firefox', 48), 'firefox')
  eq('a long name is cut and marked', PL.shortApp(long, 48), 'A'.repeat(48) + '...')
  eq('the result is limit + 3', PL.shortApp(long, 48).length, 51)
  eq('a name exactly at the limit is not cut', PL.shortApp('A'.repeat(48), 48), 'A'.repeat(48))
  eq('one character over is', PL.shortApp('A'.repeat(49), 48), 'A'.repeat(48) + '...')
  eq('the controller limit', PL.shortApp(long, 48).length, 51)
  eq('a zero limit still marks it', PL.shortApp('abc', 0), '...')
  eq('an empty name', PL.shortApp('', 48), '')
  eq('nullish is an empty string, not "null"', PL.shortApp(null, 48), '')
  eq('undefined too', PL.shortApp(undefined, 48), '')
  // The ledger, the island and the cut keep the whole string; only the toast
  // is bounded, so the projection below is never truncated.
  eq('the ledger keeps the full name', PL.ledger([{ app: long, kind: 'mic', linkIds: [1] }], {})[0].app, long)
})

section('PrivacyLib - target metadata and markup')

group('targetMeta is the dot color and island glyph per kind', () => {
  eq('mic', PL.targetMeta('mic'), { key: 'mic', icon: 'mic-on', colorKey: 'green', label: 'Microphone' })
  eq('cam', PL.targetMeta('cam'), { key: 'cam', icon: 'camera', colorKey: 'purple', label: 'Camera' })
  eq('share', PL.targetMeta('share'), { key: 'share', icon: 'screen-capture', colorKey: 'orange', label: 'Screen share' })
  // Anything that is not mic or cam is a share: the fall-through is the
  // catch-all, so a new kind renders as a screen share rather than nothing.
  eq('an unknown kind falls through to share', PL.targetMeta('speaker'), PL.targetMeta('share'))
  eq('no kind at all falls through to share', PL.targetMeta(), PL.targetMeta('share'))
  is('the icon is a shell asset name, not a path', PL.targetMeta('mic').icon, (v) => !v.includes('/') && v.endsWith('-on') || v === 'camera' || v === 'screen-capture', 'bare asset name')
  is('each call returns a fresh object, so a caller cannot mutate the table', [PL.targetMeta('mic'), PL.targetMeta('mic')],
    (v) => v[0] !== v[1], 'not the same reference')
  eq('mutating one result does not affect the next', (() => {
    const m = PL.targetMeta('mic')
    m.label = 'tampered'
    return PL.targetMeta('mic').label
  })(), 'Microphone')
})

group('a hostile app name cannot forge a second ledger row', () => {
  // The forged-row payloads a client could put in its PipeWire
  // application.name: a table break, a font break and a newline. The
  // tooltip renders PlainText rows, so every payload prints literally in
  // the one row it belongs to and forges nothing.
  const hostile = '</td></tr><tr><td>evil</td><td>is using camera'
  const led = PL.ledger([{ app: hostile, kind: 'mic', linkIds: [1] }], {})
  const rows = PL.tooltipRows(led, { mic: true, cam: false, share: false }, {}, colorOf)
  eq('one hostile name is one row', rows.length, 1)
  eq('with the payload verbatim inside it', rows[0],
    { icon: 'mic-on', name: '<b><font color="#00ff88">' + hostile.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</font></b>', markup: true, verb: 'is using microphone' })
  // A newline in the name stays a newline inside the one row.
  const led2 = PL.ledger([{ app: 'fire\nfox', kind: 'mic', linkIds: [1] }], {})
  eq('a newline adds no row', PL.tooltipRows(led2, { mic: true, cam: false, share: false }, {}, colorOf).length, 1)
  eq('_line1 escapes the same way', PL._line1('a<b</b>'), '<b>a&lt;b&lt;/b&gt;</b>')
  eq('_line1 is the plain bold name with no color', PL._line1('firefox'), '<b>firefox</b>')
  eq('_line1 of a nullish name is an empty bold pair', PL._line1(undefined), '<b></b>')
  eq('_line1 of a hostile name cannot open a tag', PL._line1('<i>x</i>'), '<b>&lt;i&gt;x&lt;/i&gt;</b>')
})

group('_line2 deduplicates the window titles behind a target', () => {
  eq('two nodes of one app contribute one title', PL._line2([{ titleText: 'Call' }, { titleText: 'Call' }]), 'Call')
  eq('distinct titles join in first-seen order', PL._line2([{ titleText: 'b' }, { titleText: 'a' }, { titleText: 'c' }]), 'b • a • c')
  eq('titles are trimmed before comparing', PL._line2([{ titleText: '  Call  ' }, { titleText: 'Call' }]), 'Call')
  eq('an empty title is skipped', PL._line2([{ titleText: '' }, { titleText: 'a' }]), 'a')
  eq('a whitespace-only title is skipped', PL._line2([{ titleText: '   ' }, { titleText: 'a' }]), 'a')
  eq('a missing title is skipped', PL._line2([{}, { titleText: 'a' }]), 'a')
  eq('no titles at all is an empty string', PL._line2([]), '')
  eq('only empty titles is an empty string', PL._line2([{ titleText: '' }, {}]), '')
  eq('the separator is a bullet, not a comma', PL._line2([{ titleText: 'a' }, { titleText: 'b' }]), 'a • b')
  // A newline in a title cannot start a ledger row: rows are array entries,
  // and the title only ever reaches the island's text line.
  eq('a newline in a title stays inside the one line', PL._line2([{ titleText: 'a\nb' }]), 'a\nb')
  // Titles are deliberately not escaped: they are client data that ends up in
  // a plain Text element, and _line2 is never concatenated into markup. What
  // matters is that the tooltip does not carry a title at all, so there is no
  // path from a window title to a row.
  eq('markup in a title is passed through, because it is never rendered as markup', PL._line2([{ titleText: '<b>a</b>' }]), '<b>a</b>')
  notContains('and the tooltip never interpolates a title',
    PL.tooltipRows(PL.ledger([{ app: 'x', kind: 'mic', titleText: '<b>x</b>', linkIds: [1] }], {}), { mic: true }, {}, colorOf).map((r) => r.name + ' ' + r.verb).join(' '), '<b>x</b>')
})

section('PrivacyLib - the per-app ledger')

const LEDGER_ROWS = [
  { app: 'firefox', kind: 'mic', classText: 'Stream/Input/Audio', titleText: 'Call', icon: 'firefox', linkIds: [11] },
  { app: 'firefox', kind: 'share', classText: 'Stream/Output/Video', titleText: 'Screen', icon: 'firefox', linkIds: [12] },
  { app: 'obs', kind: 'cam', classText: 'Stream/Input/Video', titleText: 'Cam', icon: 'obs', linkIds: [] },
  { app: 'discord', kind: 'mic', classText: 'Stream/Input/Audio', titleText: 'Voice', icon: 'discord', linkIds: [] },
]
const ALL_LIT = { mic: true, cam: true, share: true }

group('one entry per app, however many of its nodes are live', () => {
  const led = PL.ledger(LEDGER_ROWS, {})
  eq('four rows, three apps', led.length, 3)
  eq('in the order the rows arrive (share, cam, mic)', led.map(e => e.app), ['firefox', 'obs', 'discord'])
  eq('one entry holds both of the firefox targets', led[0].targets.map(t => t.key), ['mic', 'share'])
  eq('and the other two hold one each', [led[1].targets.length, led[2].targets.length], [1, 1])
  eq('the entry icon is the first non-empty one', led.map(e => e.icon), ['firefox', 'obs', 'discord'])
  eq('an entry starts with an empty icon', PL.ledger([{ app: 'x', kind: 'mic', linkIds: [1] }], {})[0].icon, '')
})

group('a second node of the same app and target is not a second target', () => {
  const led = PL.ledger([
    { app: 'obs', kind: 'share', classText: 'Stream/Output/Video', titleText: 'first', icon: 'obs', linkIds: [1] },
    { app: 'obs', kind: 'share', classText: 'Stream/Output/Video', titleText: 'second', icon: 'obs', linkIds: [2] },
  ], {})
  eq('still one target', led[0].targets.length, 1)
  eq('and the first node wins its links and title', [led[0].targets[0].titleText, led[0].targets[0].linkIds], ['first', [1]])
})

group('targets stack mic -> cam -> share inside an entry', () => {
  const led = PL.ledger([
    { app: 'x', kind: 'share', linkIds: [1] },
    { app: 'x', kind: 'cam', linkIds: [2] },
    { app: 'x', kind: 'mic', linkIds: [3] },
    { app: 'x', kind: 'share', linkIds: [4] },
  ], {})
  eq('sorted by the rank table, not by arrival', led[0].targets.map(t => t.key), ['mic', 'cam', 'share'])
})

group('a ledger target carries everything the three views need', () => {
  const t = PL.ledger(LEDGER_ROWS, {})[0].targets[0]
  eq('the exact shape of one target', t, {
    key: 'mic', icon: 'mic-on', colorKey: 'green', label: 'Microphone',
    classText: 'Stream/Input/Audio', titleText: 'Call', actionable: true,
    linkIds: [11], severed: false,
  })
})

group('actionable gates the island button and must stay true while severed', () => {
  // A cut target has no live links left by definition, so killing the button
  // would strand it with no way back. Mic is always actionable because its
  // taps may lag the graph; connected stream targets need live links.
  const cut = PL.ledger([{ app: 'obs', kind: 'share', linkIds: [] }], { 'obs\nshare': { links: [] } })
  eq('a severed share target is severed', cut[0].targets[0].severed, true)
  eq('and still actionable', cut[0].targets[0].actionable, true)
  const connected = PL.ledger([{ app: 'obs', kind: 'share', linkIds: [1] }], { 'obs\nshare': { links: [] } })
  eq('a share target with a live link is not severed', connected[0].targets[0].severed, false)
  eq('and is actionable', connected[0].targets[0].actionable, true)
  eq('a cam target with no live links and no mark is not actionable', PL.ledger([{ app: 'obs', kind: 'cam', linkIds: [] }], {})[0].targets[0].actionable, false)
  eq('a mic target with no live links is still actionable', PL.ledger([{ app: 'obs', kind: 'mic', linkIds: [] }], {})[0].targets[0].actionable, true)
  // A missing linkIds is not a live link, so a stream target reads
  // un-actionable rather than throwing on .length.
  eq('a row with no linkIds at all', PL.ledger([{ app: 'obs', kind: 'cam' }], {})[0].targets[0].actionable, false)
  eq('and its linkIds is an empty array, not undefined', PL.ledger([{ app: 'obs', kind: 'cam' }], {})[0].targets[0].linkIds, [])
})

group('rows without an app are dropped, and a null row is not dereferenced', () => {
  eq('no app', PL.ledger([{ kind: 'mic', linkIds: [1] }], {}).length, 0)
  eq('empty app name', PL.ledger([{ app: '', kind: 'mic', linkIds: [1] }], {}).length, 0)
  eq('a null row is skipped', PL.ledger([null, LEDGER_ROWS[0], undefined], {}).map(e => e.app), ['firefox'])
  eq('an empty row list', PL.ledger([], {}), [])
})

group('an app name of "constructor" or "__proto__" reads as a normal name', () => {
  // The index is a null-prototype map precisely so that a client-chosen
  // application name cannot resolve to an inherited object and throw.
  const led = PL.ledger([
    { app: '__proto__', kind: 'mic', linkIds: [1] },
    { app: 'constructor', kind: 'cam', linkIds: [2] },
    { app: 'toString', kind: 'share', linkIds: [3] },
  ], {})
  eq('all three become entries', led.map(e => e.app), ['__proto__', 'constructor', 'toString'])
  eq('with the right target each', led.map(e => e.targets[0].key), ['mic', 'cam', 'share'])
  eq('and each is a real ledger entry, not an inherited object', typeof led[0].targets[0].actionable, 'boolean')
  eq('two rows of the same prototype-named app still merge', PL.ledger([
    { app: '__proto__', kind: 'mic', linkIds: [1] },
    { app: '__proto__', kind: 'share', linkIds: [2] },
  ], {}).length, 1)
})

section('PrivacyLib - the island and the tooltip projections')

group('islandRows keeps only entries with a lit target', () => {
  const led = PL.ledger(LEDGER_ROWS, {})
  eq('everything lit keeps everything', PL.islandRows(led, ALL_LIT).map(e => e.app), ['firefox', 'obs', 'discord'])
  eq('share only drops the cam and mic entries', PL.islandRows(led, { mic: false, cam: false, share: true }).map(e => e.app), ['firefox'])
  eq('mic only keeps the two mic apps', PL.islandRows(led, { mic: true, cam: false, share: false }).map(e => e.app), ['firefox', 'discord'])
  eq('nothing lit keeps nothing', PL.islandRows(led, { mic: false, cam: false, share: false }), [])
  eq('a share-only session keeps no stale mic row', PL.islandRows(PL.ledger([{ app: 'portal', kind: 'share', linkIds: [1] }], {}), ALL_LIT).map(e => e.app), ['portal'])
  eq('and a mic-only session keeps no stale share row', PL.islandRows(PL.ledger([{ app: 'zoom', kind: 'mic', linkIds: [1] }], {}), ALL_LIT).map(e => e.app), ['zoom'])
})

group('island lines are rendered from exactly the shown targets', () => {
  const led = PL.ledger(LEDGER_ROWS, {})
  const rows = PL.islandRows(led, { mic: true, cam: false, share: true })
  eq('the exact shape of one island row', rows[0], {
    app: 'firefox', icon: 'firefox', targets: led[0].targets.filter(t => t.key === 'mic' || t.key === 'share'),
    line1: '<b>firefox</b>', line2: 'Call • Screen',
  })
  eq('a filtered target is not in line2', PL.islandRows(led, { mic: true, cam: false, share: false })[0].line2, 'Call')
  eq('line1 is the bold app name and nothing else', PL.islandRows(led, ALL_LIT)[0].line1, '<b>firefox</b>')
  eq('the targets carried are the filtered ones', rows[0].targets.length, 2)
})

group('the tooltip is one icon-led row per lit target, in mic/cam/share order', () => {
  const led = PL.ledger(LEDGER_ROWS, {})
  eq('one section, ledger order within', PL.tooltipRows(led, { mic: true, cam: false, share: false }, {}, colorOf), [
    { icon: 'mic-on', name: '<b><font color="#00ff88">firefox</font></b>', markup: true, verb: 'is using microphone' },
    { icon: 'mic-on', name: '<b><font color="#00ff88">discord</font></b>', markup: true, verb: 'is using microphone' },
  ])
  eq('all three sections concatenated, no dividers', PL.tooltipRows(led, ALL_LIT, {}, colorOf), [
    { icon: 'mic-on', name: '<b><font color="#00ff88">firefox</font></b>', markup: true, verb: 'is using microphone' },
    { icon: 'mic-on', name: '<b><font color="#00ff88">discord</font></b>', markup: true, verb: 'is using microphone' },
    { icon: 'camera', name: '<b><font color="#b07fff">obs</font></b>', markup: true, verb: 'is using camera' },
    { icon: 'screen-capture', name: '<b><font color="#ff9f43">firefox</font></b>', markup: true, verb: 'is sharing screen' },
  ])
  eq('rows keep the ledger order within a section',
    PL.tooltipRows(led, ALL_LIT, {}, colorOf).map((r) => r.verb),
    ['is using microphone', 'is using microphone', 'is using camera', 'is sharing screen'])
  eq('an empty ledger is an empty tooltip', PL.tooltipRows([], { mic: false, cam: false, share: false }, {}), [])
  eq('a nullish ledger is an empty tooltip', PL.tooltipRows(null, { mic: false, cam: false, share: false }, {}), [])
})

group('a severed target reads "(paused)" in the tooltip, and only then', () => {
  // The scenario is the one the cut pipeline produces: the links are gone,
  // so the mark is remembered AND unlinkless, which is what "severed" means.
  const severed = { 'firefox\nmic': { links: [] } }
  const cutRows = LEDGER_ROWS.map(r => r.app === 'firefox' && r.kind === 'mic' ? { ...r, linkIds: [] } : r)
  const led = PL.ledger(cutRows, severed)
  eq('the ledger marks the cut target', led[0].targets[0].severed, true)
  eq('and the tooltip says so', PL.tooltipRows(led, { mic: true, cam: false, share: false }, severed, colorOf), [
    { icon: 'mic-on', name: '<b><font color="#00ff88">firefox</font></b>', markup: true, verb: 'is using microphone (paused)' },
    { icon: 'mic-on', name: '<b><font color="#00ff88">discord</font></b>', markup: true, verb: 'is using microphone' },
  ])
  // The paused marker follows the effective state, not the remembered mark:
  // a target whose links came back reads connected again.
  const healed = PL.ledger(LEDGER_ROWS, severed)
  eq('a relinked target is not paused', PL.tooltipRows(healed, { mic: true, cam: false, share: false }, severed, colorOf), [
    { icon: 'mic-on', name: '<b><font color="#00ff88">firefox</font></b>', markup: true, verb: 'is using microphone' },
    { icon: 'mic-on', name: '<b><font color="#00ff88">discord</font></b>', markup: true, verb: 'is using microphone' },
  ])
  const texts = PL.tooltipRows(healed, ALL_LIT, severed, colorOf).map((r) => r.verb).join(' ')
  notContains('no paused marker survives a relink', texts, '(paused)')
  contains('and the share section is unaffected by a mic cut',
    PL.tooltipRows(led, ALL_LIT, severed, colorOf).map((r) => r.verb).join(' '), 'is sharing screen')
  // The same verdict in all three views at once: this is the contract that
  // stops a screen reading as captured while it is not.
  eq('ledger, island and tooltip agree that the target is cut', [
    led[0].targets[0].severed,
    PL.tooltipRows(led, ALL_LIT, severed, colorOf).some((r) => r.verb.includes('(paused)')),
    PL.islandRows(led, ALL_LIT)[0].targets[0].severed,
  ], [true, true, true])
  eq('and only the cut pair carries the marker',
    PL.tooltipRows(led, ALL_LIT, severed, colorOf).filter((r) => r.verb.includes('(paused)')).length, 1)
  eq('the cut target is still actionable, so the island keeps its button', led[0].targets[0].actionable, true)
})

group('a live share session with no classified stream still names itself', () => {
  const none = []
  eq('a lit share section with no rows gets one fallback row',
    PL.tooltipRows(none, { mic: false, cam: false, share: true }, {}),
    [{ icon: 'screen-capture', text: 'Screen sharing' }])
  eq('an unlit share section gets nothing', PL.tooltipRows(none, { mic: false, cam: false, share: false }, {}), [])
  eq('no lit section at all is an empty tooltip', PL.tooltipRows(none, { mic: false, cam: false, share: false }, {}), [])
  eq('mic and cam have no such fallback', PL.tooltipRows(none, { mic: true, cam: true, share: false }, {}), [])
  eq('a classified share row wins over the fallback',
    PL.tooltipRows(PL.ledger([{ app: 'portal', kind: 'share', linkIds: [1] }], {}), { share: true }, {}, colorOf),
    [{ icon: 'screen-capture', name: '<b><font color="#ff9f43">portal</font></b>', markup: true, verb: 'is sharing screen' }])
})

group('a hostile app name cannot forge a row inside the tooltip either', () => {
  const hostile = '</td></tr><tr><td>evil</td><td>is using camera'
  const led = PL.ledger([{ app: hostile, kind: 'mic', linkIds: [1] }], {})
  const rows = PL.tooltipRows(led, { mic: true, cam: false, share: false }, {}, colorOf)
  eq('the hostile name is one row', rows.length, 1)
  eq('with the payload verbatim inside it', rows[0],
    { icon: 'mic-on', name: '<b><font color="#00ff88">' + hostile.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</font></b>', markup: true, verb: 'is using microphone' })
  // A newline in the name is not a row break: rows are array entries, and
  // the verb side of the row is a fixed string.
  const led2 = PL.ledger([{ app: 'fire\nfox', kind: 'mic', linkIds: [1] }], {})
  eq('a newline adds no row', PL.tooltipRows(led2, { mic: true, cam: false, share: false }, {}, colorOf).length, 1)
})

group('tooltip rows carry the target glyph and tint for the host lines path', () => {
  const led = PL.ledger(LEDGER_ROWS, {})
  const rows = PL.tooltipRows(led, ALL_LIT, {}, colorOf)
  eq('glyph per section', rows.map((r) => r.icon),
    ['mic-on', 'mic-on', 'camera', 'screen-capture'])
  eq('tint per section, on the app span alone', rows.map((r) => r.name),
    ['<b><font color="#00ff88">firefox</font></b>',
     '<b><font color="#00ff88">discord</font></b>',
     '<b><font color="#b07fff">obs</font></b>',
     '<b><font color="#ff9f43">firefox</font></b>'])
  eq('verbs ride the shared column', rows.map((r) => r.verb),
    ['is using microphone', 'is using microphone', 'is using camera', 'is sharing screen'])
  eq('every row opts into rich text', rows.every((r) => r.markup === true), true)
})

section('PrivacyLib - shell loopback ("Hear my voice")')

group('loopback row identity and shape', () => {
  eq('the app name matches the settings label', PL.loopbackAppName(), 'Hear my voice')
  const row = PL.loopbackRow('ICON')
  eq('the row carries the resolved icon', row.icon, 'ICON')
  eq('one mic target', row.targets.length, 1)
  eq('target key', row.targets[0].key, 'mic')
  eq('target glyph is the mic dot glyph', row.targets[0].icon, 'mic-on')
  eq('not actionable, so the island renders a plain glyph', row.targets[0].actionable, false)
  eq('no remembered links', row.targets[0].linkIds, [])
  eq('never severed', row.targets[0].severed, false)
  eq('an empty icon falls back to empty, not a name', PL.loopbackRow('').icon, '')
})

group('hasMicTarget reads the ledger, not the rows', () => {
  eq('empty ledger', PL.hasMicTarget([]), false)
  eq('nullish ledger', PL.hasMicTarget(null), false)
  eq('mic entry', PL.hasMicTarget([{ app: 'x', targets: [{ key: 'mic' }] }]), true)
  eq('cam-only entry', PL.hasMicTarget([{ app: 'x', targets: [{ key: 'cam' }] }]), false)
  eq('entry without targets', PL.hasMicTarget([{ app: 'x' }]), false)
  eq('a null entry is skipped', PL.hasMicTarget([null, { app: 'x', targets: [{ key: 'mic' }] }]), true)
})

group('isLoopbackOnly names the device-to-device shape', () => {
  eq('single source->sink link', PL.isLoopbackOnly([{ s: 10, t: 20 }], 10, 20), true)
  eq('sink->source direction also counts', PL.isLoopbackOnly([{ s: 20, t: 10 }], 10, 20), true)
  eq('two loopback links still only loopback', PL.isLoopbackOnly([{ s: 10, t: 20 }, { s: 10, t: 20 }], 10, 20), true)
  eq('array pairs are accepted', PL.isLoopbackOnly([[10, 20]], 10, 20), true)
  eq('string ids match numeric ones', PL.isLoopbackOnly([{ s: '10', t: '20' }], 10, 20), true)
  eq('unrelated links are ignored', PL.isLoopbackOnly([{ s: 30, t: 40 }, { s: 10, t: 20 }], 10, 20), true)
  eq('no links is not a route', PL.isLoopbackOnly([], 10, 20), false)
  eq('no touching link is not a route', PL.isLoopbackOnly([{ s: 30, t: 40 }], 10, 20), false)
  eq('an app peer breaks it', PL.isLoopbackOnly([{ s: 10, t: 20 }, { s: 10, t: 30 }], 10, 20), false)
  eq('source alone with no peer breaks it', PL.isLoopbackOnly([{ s: 10, t: undefined }], 10, 20), false)
  eq('same device is not a route', PL.isLoopbackOnly([{ s: 10, t: 10 }], 10, 10), false)
  eq('missing source', PL.isLoopbackOnly([{ s: 10, t: 20 }], null, 20), false)
  eq('missing sink', PL.isLoopbackOnly([{ s: 10, t: 20 }], 10, null), false)
  eq('non-array pairs', PL.isLoopbackOnly(null, 10, 20), false)
  eq('null entries are skipped', PL.isLoopbackOnly([null, { s: 10, t: 20 }], 10, 20), true)
})

group('allSourcePeersSink is the vacuous guard for the sync race', () => {
  eq('no links is vacuously true', PL.allSourcePeersSink([], 10, 20), true)
  eq('loopback peers', PL.allSourcePeersSink([{ s: 10, t: 20 }], 10, 20), true)
  eq('an app peer breaks it', PL.allSourcePeersSink([{ s: 10, t: 30 }], 10, 20), false)
  eq('invalid devices', PL.allSourcePeersSink([], null, 20), false)
})

group('needsLoopbackRow gates on setting, busyness and attribution', () => {
  const base = (pairs, src = 10, snk = 20, extra = {}) => ({
    loopbackOn: true, micOn: true, entries: [], pairs, sourceId: src, sinkId: snk,
    sourceLinkCount: 1, captureCount: 0, ...extra,
  })
  eq('pure loopback route', PL.needsLoopbackRow(base([{ s: 10, t: 20 }])), true)
  eq('setting off never needs a row', PL.needsLoopbackRow(base([{ s: 10, t: 20 }], 10, 20, { loopbackOn: false })), false)
  eq('idle mic never needs a row', PL.needsLoopbackRow(base([{ s: 10, t: 20 }], 10, 20, { micOn: false })), false)
  eq('a real mic row wins over the synthetic one',
    PL.needsLoopbackRow(base([{ s: 10, t: 20 }], 10, 20, { entries: [{ app: 'firefox', targets: [{ key: 'mic' }] }] })), false)
  eq('an app peer is a real capture, not loopback',
    PL.needsLoopbackRow(base([{ s: 10, t: 20 }, { s: 10, t: 30 }])), false)
  eq('tracker busy with no stream and sink-only peers (sync race)',
    PL.needsLoopbackRow(base([], 10, 20, { sourceLinkCount: 2 })), true)
  eq('capture streams block the fallback',
    PL.needsLoopbackRow(base([], 10, 20, { sourceLinkCount: 2, captureCount: 1 })), false)
  eq('tracker idle with no raw route needs nothing',
    PL.needsLoopbackRow(base([], 10, 20, { sourceLinkCount: 0 })), false)
  eq('nullish args', PL.needsLoopbackRow(null), false)
})

group('ensureLoopbackRow never duplicates and never steals a claim', () => {
  const withIcon = PL.ensureLoopbackRow([], 'ICON')
  eq('adds the row to an empty ledger', withIcon.map(e => e.app), ['Hear my voice'])
  eq('the added row carries the icon', withIcon[0].icon, 'ICON')
  eq('second call is idempotent', PL.ensureLoopbackRow(withIcon, 'ICON').length, 1)
  eq('a mic row blocks it', PL.ensureLoopbackRow([{ app: 'firefox', targets: [{ key: 'mic' }] }], 'ICON').length, 1)
  eq('a cam-only ledger still gains it',
    PL.ensureLoopbackRow([{ app: 'obs', targets: [{ key: 'cam' }] }], 'ICON').map(e => e.app),
    ['obs', 'Hear my voice'])
  eq('nullish ledger becomes just the row', PL.ensureLoopbackRow(null, 'I').map(e => e.app), ['Hear my voice'])
})

group('the loopback row flows through island and tooltip', () => {
  const led = PL.ensureLoopbackRow([], 'ICON')
  const lit = { mic: true, cam: false, share: false }
  const island = PL.islandRows(led, lit)
  eq('island shows one row', island.map(e => e.app), ['Hear my voice'])
  eq('island line names the app', island[0].line1, '<b>Hear my voice</b>')
  eq('island subtext names the route', island[0].line2, 'Input device to output device')
  const tip = PL.tooltipRows(led, lit, {}, colorOf)
  eq('tooltip shows one mic row', tip.length, 1)
  eq('tooltip verb', tip[0].verb, 'is using microphone')
  eq('tooltip glyph', tip[0].icon, 'mic-on')
  eq('dark mic hides it again', PL.islandRows(led, { mic: false, cam: false, share: false }), [])
  // A real app alongside keeps its own row and the synthetic one stays out.
  const mixed = PL.ledger([{ app: 'firefox', kind: 'mic', linkIds: [11] }], {})
  eq('mixed ledger keeps the app and gains nothing', PL.ensureLoopbackRow(mixed, 'I').map(e => e.app), ['firefox'])
})

// ---------------------------------------------------------------------------
// PrintersLib
// ---------------------------------------------------------------------------

// A recorded `ipptool -tv` report for the template in
// services/system/ipptool/printers.test (CUPS-Get-Printers), shaped exactly
// as the tool on this host prints it:
//
//   "ipptool/printers.test":
//       CUPS-Get-Printers:
//           attributes-charset (charset) = utf-8
//       List printers                                  [PASS]
//           printer-state (enum) = processing
//           -- separator --
//
// The request echo above the verdict line is real output too, which is why
// the parser only reads after the [PASS]/[FAIL] line.
const PRINTERS_REPORT = [
  '"ipptool/printers.test":',
  '    CUPS-Get-Printers:',
  '        attributes-charset (charset) = utf-8',
  '        attributes-natural-language (naturalLanguage) = en',
  '        printer-uri (uri) = ipp://localhost/',
  '        requesting-user-name (nameWithoutLanguage) = vibranium',
  '        requested-attributes (1setOf keyword) = printer-name,printer-state,printer-state-reasons,printer-state-message,printer-is-accepting-jobs,printer-info,printer-location,printer-make-and-model,printer-device-uri,cups-printer-state-message,printer-up-time',
  '    List printers                                                        [PASS]',
  '        attributes-charset (charset) = utf-8',
  '        attributes-natural-language (naturalLanguage) = en',
  '        printer-state (enum) = processing',
  '        printer-state-reasons (1setOf keyword) = none',
  '        printer-is-accepting-jobs (boolean) = true',
  '        printer-name (nameWithoutLanguage) = HP_LaserJet_M404',
  '        printer-info (nameWithoutLanguage) = HP LaserJet M404-M405',
  '        printer-location (nameWithoutLanguage) = Office',
  '        printer-make-and-model (textWithoutLanguage) = HP LaserJet M404-M405',
  '        printer-device-uri (uri) = ipp://localhost/printers/HP_LaserJet_M404',
  // ipptool prints "name (type) = " and then the value, so an empty value
  // leaves a trailing space on the line. Built by concatenation so the space
  // cannot be lost to a trimming editor.
  '        cups-printer-state-message (textWithoutLanguage) =' + ' ',
  '        printer-up-time (integer) = 382114',
  '        status-code (enum) = successful-ok',
  '        -- separator --',
  '        printer-state (enum) = stopped',
  '        printer-state-reasons (1setOf keyword) = paused',
  '        printer-is-accepting-jobs (boolean) = false',
  '        printer-name (nameWithoutLanguage) = Brother_HL_L2350DW',
  '        printer-info (nameWithoutLanguage) = Brother HL-L2350DW',
  '        printer-location (nameWithoutLanguage) = Hallway',
  '        printer-make-and-model (textWithoutLanguage) = Brother HL-L2350DW series',
  '        printer-device-uri (uri) = ipp://localhost/printers/Brother_HL_L2350DW',
  '        cups-printer-state-message (textWithoutLanguage) = Paused',
  '        printer-up-time (integer) = 51002',
  '',
].join('\n')

// The same tool, for services/system/ipptool/jobs.test (Get-Jobs). The
// job-printer-uri attribute precedes job-id on the wire, so the anchor is not
// the first attribute of its group - the documented "the order is the
// server's, not the anchor's" case.
const JOBS_REPORT = [
  '"ipptool/jobs.test":',
  '    Get-Jobs:',
  '        attributes-charset (charset) = utf-8',
  '        which-jobs (keyword) = all',
  '        limit (integer) = 50',
  '        requesting-user-name (nameWithoutLanguage) = vibranium',
  '    Get server-wide jobs                                                  [PASS]',
  '        attributes-charset (charset) = utf-8',
  '        attributes-natural-language (naturalLanguage) = en',
  '        job-uri (uri) = ipp://localhost/jobs/34',
  '        job-printer-uri (uri) = ipp://localhost/printers/HP_LaserJet_M404',
  '        job-id (integer) = 34',
  '        job-name (nameWithoutLanguage) = /home/vibranium/docs/report.pdf',
  '        job-state (enum) = processing',
  '        job-state-reasons (1setOf keyword) = job-printing',
  '        job-originating-user-name (nameWithoutLanguage) = vibranium',
  '        job-k-octets (integer) = 2048',
  '        time-at-creation (integer) = 1756339200',
  '        document-name (nameWithoutLanguage) = report.pdf',
  '        document-name-supplied (nameWithoutLanguage) = report.pdf',
  '        job-media-progress (integer) = 40',
  '        -- separator --',
  '        job-uri (uri) = ipp://localhost/jobs/35',
  '        job-printer-uri (uri) = ipp://localhost/printers/Brother_HL_L2350DW',
  '        job-id (integer) = 35',
  '        job-name (nameWithoutLanguage) = invoice.docx',
  '        job-state (enum) = completed',
  '        job-k-octets (integer) = 12',
  '        time-at-creation (integer) = 1756335600',
  '',
].join('\n')

const PRINTER_ROWS = PR.parseReport(PRINTERS_REPORT, 'printer-name')
const JOB_ROWS = PR.parseReport(JOBS_REPORT, 'job-id')
// The service derives this from job-printer-uri before filtering.
const JOBS_WITH_PRINTER = JOB_ROWS.map(j => ({ ...j, printer: String(j['job-printer-uri'] || '').substring(String(j['job-printer-uri'] || '').lastIndexOf('/') + 1) }))

section('PrintersLib - parseReport on a real ipptool -tv report')

group('a well-formed two-printer report gives one row per object', () => {
  eq('two rows', PRINTER_ROWS.length, 2)
  eq('the first row is the object before the separator', PRINTER_ROWS[0]['printer-name'], 'HP_LaserJet_M404')
  eq('the second row is the object after it', PRINTER_ROWS[1]['printer-name'], 'Brother_HL_L2350DW')
  eq('every value is the string the report carried', typeof PRINTER_ROWS[0]['printer-state'], 'string')
  eq('the state arrives symbolically, never as 4', PRINTER_ROWS[0]['printer-state'], 'processing')
  eq('the boolean arrives as text too', PRINTER_ROWS[0]['printer-is-accepting-jobs'], 'true')
  eq('the empty cups message is an empty string, not undefined', PRINTER_ROWS[0]['cups-printer-state-message'], '')
  eq('a value containing = is kept whole', PR.parseReport('    [PASS]\n        printer-name (nameWithoutLanguage) = a = b\n', 'printer-name')[0]['printer-name'], 'a = b')
  eq('a uri value with slashes and colons is kept whole', PRINTER_ROWS[0]['printer-device-uri'], 'ipp://localhost/printers/HP_LaserJet_M404')
})

group('the request echo above the verdict line is never read', () => {
  // Without the [PASS] gate the echoed operation attributes would open a
  // group, and the first printer's attributes would land in a *second* row.
  // The response's own operation attributes do belong to the first group, so
  // the assertion is about the echo's attributes - which appear only above
  // the verdict line and never in a row.
  contains('the response own attributes-charset is in the first group', Object.keys(PRINTER_ROWS[0]), 'attributes-charset')
  eq('the echoed printer-uri is not in a row', PRINTER_ROWS[0]['printer-uri'], undefined)
  eq('the echoed requesting-user-name is not in a row', PRINTER_ROWS[0]['requesting-user-name'], undefined)
  eq('the echoed requested-attributes is not in a row', PRINTER_ROWS[0]['requested-attributes'], undefined)
  // The gate is load-bearing for job rows too: a Cancel-Job run echoes
  // job-id in its request section, which would otherwise be a phantom job
  // with no state and no name.
  const cancelEcho = [
    '"ipptool/cancel-job.test":',
    '    Cancel-Job:',
    '        printer-uri (uri) = ipp://localhost/printers/HP_LaserJet_M404',
    '        job-id (integer) = 34',
    '        requesting-user-name (nameWithoutLanguage) = vibranium',
    '    Cancel job                                                           [PASS]',
    '        attributes-charset (charset) = utf-8',
    '        status-code (enum) = successful-ok',
    '',
  ].join('\n')
  eq('an echoed job-id produces no row at all', PR.parseReport(cancelEcho, 'job-id'), [])
})

group('zero rows, an empty report and a truncated report', () => {
  // Zero printers is a valid answer: cupsd replies client-error-not-found
  // once the last queue is deleted, and ipptool reports that as FAIL.
  const zero = [
    '    List printers                                                        [FAIL]',
    '        attributes-charset (charset) = utf-8',
    '        attributes-natural-language (naturalLanguage) = en',
    '        status-code (enum) = client-error-not-found',
    '        status-message (textWithoutLanguage) = No destinations added',
    '        status-code = client-error-not-found (No destinations added)',
    '',
  ].join('\n')
  eq('an error response yields no rows', PR.parseReport(zero, 'printer-name'), [])
  eq('an empty string is no rows', PR.parseReport('', 'printer-name'), [])
  eq('null is no rows', PR.parseReport(null, 'printer-name'), [])
  eq('text with no verdict line is no rows', PR.parseReport('nothing to see\nnot a report\n', 'printer-name'), [])
  // A truncated report is decided by the anchor, not by completeness: a
  // partial group survives as soon as its anchor arrives, and one without an
  // anchor is dropped whole.
  const lines = PRINTERS_REPORT.split('\n')
  eq('cut just before the second printer-name: one complete row', PR.parseReport(lines.slice(0, 25).join('\n'), 'printer-name').map(r => r['printer-name']), ['HP_LaserJet_M404'])
  eq('cut just after it: the partial row survives on its anchor alone', PR.parseReport(lines.slice(0, 26).join('\n'), 'printer-name').map(r => r['printer-name']), ['HP_LaserJet_M404', 'Brother_HL_L2350DW'])
  eq('and that row now carries the parsed reason too', Object.keys(PR.parseReport(lines.slice(0, 26).join('\n'), 'printer-name')[1]).length, 4)  // printer-state precedes printer-name on the wire, so a truncation between
  // them leaves a row with a state and no name of its own beyond the anchor.
  eq('the state that preceded the anchor is still there', PR.parseReport(lines.slice(0, 26).join('\n'), 'printer-name')[1]['printer-state'], 'stopped')
  eq('so it renders as Stopped - paused now that the reason parses', PR.printerLine(PR.parseReport(lines.slice(0, 26).join('\n'), 'printer-name')[1]), 'Stopped - paused')
  eq('cut before the first printer-name: no rows at all', PR.parseReport(lines.slice(0, 12).join('\n'), 'printer-name'), [])
  eq('the full report is two rows again', PR.parseReport(lines.join('\n'), 'printer-name').length, 2)
  noThrow('a report that is only a verdict line parses to nothing', () => PR.parseReport('    List printers [PASS]\n', 'printer-name'))})

group('a group that never saw the anchor is dropped', () => {
  eq('a stray status-message group', PR.parseReport([
    '    [PASS]',
    '        status-message (textWithoutLanguage) = something',
    '        -- separator --',
    '        printer-name (nameWithoutLanguage) = HP',
    '',
  ].join('\n'), 'printer-name').map(r => r['printer-name']), ['HP'])
  eq('an empty anchor value still counts as an anchor', PR.parseReport([
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) =' + ' ',
    '',
  ].join('\n'), 'printer-name').length, 1)
  // The service defends against that last case separately by filtering an
  // empty printer-name, which is why a nameless row cannot reach a widget.
  eq('and its value is the empty string', PR.parseReport([
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) =' + ' ',
    '',
  ].join('\n'), 'printer-name')[0]['printer-name'], '')
})

group('a report missing a requested attribute degrades instead of failing', () => {
  const missing = [
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) = HP_LaserJet_M404',
    '        printer-info (nameWithoutLanguage) = HP LaserJet',
    '',
  ].join('\n')
  const row = PR.parseReport(missing, 'printer-name')[0]
  eq('the row still parses', row['printer-name'], 'HP_LaserJet_M404')
  eq('the absent attribute is undefined', row['printer-state'], undefined)
  eq('so the state label reads Unknown', PR.printerStateLabel(row['printer-state']), 'Unknown')
  eq('and the line is just that label', PR.printerLine(row), 'Unknown')
  eq('an absent accepting-jobs is not "false"', PR.printerIsDown(row), false)
  eq('an absent reason does not make it offline', PR.printerIsOffline(row), false)
  eq('and markers are empty rather than undefined', PR.markers(row), [])
})

group('attribute order inside a group is the server\'s, not the anchor\'s', () => {
  // printer-state precedes printer-name and job-printer-uri precedes job-id
  // in the two templates this service sends, so the anchor can never be the
  // first attribute of its group.
  eq('the state is set before the name is known', Object.keys(PRINTER_ROWS[0]).indexOf('printer-state') < Object.keys(PRINTER_ROWS[0]).indexOf('printer-name'), true)
  eq('the job uri is set before the job id', Object.keys(JOB_ROWS[0]).indexOf('job-printer-uri') < Object.keys(JOB_ROWS[0]).indexOf('job-id'), true)
  eq('the row is still complete', PR.jobStateNum(JOB_ROWS[0]['job-state']), 5)
  eq('both jobs parsed', JOB_ROWS.map(j => j['job-id']), ['34', '35'])
  eq('and the second group carries only what the server sent', Object.keys(JOB_ROWS[1]).indexOf('document-name'), -1)
})

group('a repeated attribute folds into an array in insertion order', () => {
  // This is the shape the marker pairs arrive in. A real report prints a
  // 1setOf as one comma-joined line whose type token the attribute regex
  // does not accept (see the 1setOf group below), so the array form is
  // exercised with the type tokens the regex does read.
  const repeated = [
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) = Dup',
    '        marker-names (nameWithoutLanguage) = Black\\ ink',
    '        marker-names (nameWithoutLanguage) = Color',
    '        marker-levels (integer) = 30',
    '        marker-levels (integer) = 100',
    '        printer-state-reasons (keyword) = none',
    '',
  ].join('\n')
  const row = PR.parseReport(repeated, 'printer-name')[0]
  eq('an attribute seen once stays a scalar', row['printer-name'], 'Dup')
  eq('the repeated attribute becomes an array', row['marker-names'], ['Black\\ ink', 'Color'])
  eq('in insertion order', row['marker-levels'], ['30', '100'])
  eq('a third occurrence appends rather than nesting', PR.parseReport([
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) = Dup',
    '        marker-names (nameWithoutLanguage) = a',
    '        marker-names (nameWithoutLanguage) = b',
    '        marker-names (nameWithoutLanguage) = c',
    '',
  ].join('\n'), 'printer-name')[0]['marker-names'], ['a', 'b', 'c'])
  // A repeated attribute of one value stays a scalar: the fold only happens
  // on the second sighting.
  eq('a single-valued attribute in the same group is not wrapped', row['printer-state-reasons'], 'none')
  eq('and an attribute the group never carried is absent, not empty', row['printer-location'], undefined)
})

group('a 1setOf attribute line is parsed now', () => {
  // ipptool prints a 1setOf attribute as "  <name> (1setOf keyword) = a,b"
  // - the type token carries a digit and a space. The attribute regex now
  // accepts letters, digits, spaces and hyphens in the type token, so the
  // line parses like any other and consumers read the real reason.
  eq('the realistic report now carries printer-state-reasons', PR.parseReport(PRINTERS_REPORT, 'printer-state-reasons').length, 2)
  eq('and the first row carries "none"', PRINTER_ROWS[0]['printer-state-reasons'], 'none')
  eq('and the second carries "paused"', PRINTER_ROWS[1]['printer-state-reasons'], 'paused')
  eq('and no marker pairs', PR.parseReport(PRINTERS_REPORT, 'marker-names'), [])
  eq('a single-valued keyword attribute of the same name does parse', PR.parseReport([
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) = HP',
    '        printer-state-reasons (keyword) = none',
    '',
  ].join('\n'), 'printer-name')[0]['printer-state-reasons'], 'none')
  eq('so markers() is empty for a real report', PR.markers(PRINTER_ROWS[0]), [])
  eq('and printerLine shows the paused reason', PR.printerLine(PRINTER_ROWS[1]), 'Stopped - paused')
  eq('which is what the same row says when the reasons are hand-fed', PR.printerLine({
    'printer-state': 'stopped', 'printer-state-reasons': 'paused',
  }), 'Stopped - paused')
})

group('the line forms the attribute regex accepts and rejects', () => {
  const parse = (line, anchor) => PR.parseReport('    [PASS]\n' + line + '\n', anchor || 'printer-name')
  eq('a plain typed attribute', parse('        printer-name (nameWithoutLanguage) = HP').length, 1)
  // The regex allows either " (type) " or nothing between the name and "=",
  // and ipptool's FAIL summary line has a space there - so that line is not
  // an attribute line and never opens a row. That is why statusCode() needs
  // its own reader for it rather than reading a parsed row.
  eq('the untyped FAIL summary line is not an attribute line', parse('        status-code = client-error-not-found (No destinations added)', 'status-code'), [])
  eq('a typed status-code attribute does parse', parse('        status-code (enum) = client-error-not-found', 'status-code')[0]['status-code'], 'client-error-not-found')
  eq('an untyped attribute with no space before = does parse', parse('        status-code= client-error-not-found', 'status-code')[0]['status-code'], 'client-error-not-found')
  // The regex requires the space after "=", because ipptool writes it
  // unconditionally before the value.
  eq('a line with no space after = is not an attribute', parse('        printer-name =HP'), [])
  eq('a line with nothing after = and no space is not an attribute', parse('        printer-name ='), [])
  eq('a line with a trailing space is an empty value', parse('        printer-name (nameWithoutLanguage) =' + ' ')[0]['printer-name'], '')
  eq('a line with no indentation is not an attribute', parse('printer-name (nameWithoutLanguage) = HP'), [])
  eq('a value that is empty after the space', parse('        cups-printer-state-message (textWithoutLanguage) =' + ' ', 'cups-printer-state-message')[0]['cups-printer-state-message'], '')
  // The separator is matched with any indentation, because the tool indents
  // it to the same 8 spaces as the attributes.
  eq('the separator at the tool\'s own indent', parse('        -- separator --').length, 0)
  eq('a double separator closes one row and opens none', PR.parseReport([
    '    [PASS]',
    '        printer-name (nameWithoutLanguage) = HP',
    '        -- separator --',
    '        -- separator --',
    '',
  ].join('\n'), 'printer-name').length, 1)
  eq('a separator before any attribute opens nothing', PR.parseReport('    [PASS]\n        -- separator --\n', 'printer-name'), [])
  eq('the verdict line is found anywhere in the line', PR.parseReport('[PASS] trailing noise\n    [PASS]\n        printer-name (nameWithoutLanguage) = a\n', 'printer-name').length, 1)
})

group('statusCode reads the failure line the tool prints for a FAIL', () => {
  // ipptool prints the untyped summary "status-code = <code> (<message>)"
  // when a test fails, and a typed "status-code (enum) = ..." attribute on a
  // PASS. The lib is a failure-path reader, which is exactly how the service
  // uses it: a healthy box needs no status read, a deleted last queue does.
  eq('the FAIL summary line', PR.statusCode('        status-code = client-error-not-found (No destinations added)'), 'client-error-not-found')
  eq('an unauthenticated failure', PR.statusCode('        status-code = client-error-not-authenticated (Unauthorized)'), 'client-error-not-authenticated')
  eq('a transport failure', PR.statusCode('        status-code = server-error-internal-error (Unable to read response.)'), 'server-error-internal-error')
  eq('the code stops at the parenthesis', PR.statusCode('status-code = successful-ok (Nothing to do)'), 'successful-ok')
  eq('a PASS report has no such line', PR.statusCode(PRINTERS_REPORT), '')
  eq('a typed status-code attribute is not this reader\'s shape', PR.statusCode('        status-code (enum) = successful-ok'), '')
  eq('no status at all', PR.statusCode('nothing here'), '')
  eq('an empty report', PR.statusCode(''), '')
  eq('null', PR.statusCode(null), '')
  eq('the first occurrence wins', PR.statusCode('status-code = client-error-not-found (x)\nstatus-code = server-error-busy (y)'), 'client-error-not-found')
  eq('it does not match a longer token', PR.statusCode('status-codex = client-error-not-found'), '')
  eq('a realistic FAIL report reads its code', PR.statusCode([
    '    List printers                                                        [FAIL]',
    '        attributes-charset (charset) = utf-8',
    '        status-code (enum) = client-error-not-found',
    '        status-message (textWithoutLanguage) = No destinations added',
    '        status-code = client-error-not-found (No destinations added)',
    '',
  ].join('\n')), 'client-error-not-found')
})

section('PrintersLib - state normalisation')

group('the symbolic enums ipptool prints map to their IPP numbers', () => {
  // ipptool renders state enums symbolically ("idle", "processing",
  // "pending-held", "completed" - never 3/4/5/9), so every state read in
  // the shell goes through these two normalizers.
  eq('job pending', PR.jobStateNum('pending'), 3)
  eq('job pending-held', PR.jobStateNum('pending-held'), 4)
  eq('job held is the same state', PR.jobStateNum('held'), 4)
  eq('job processing', PR.jobStateNum('processing'), 5)
  eq('job processing-stopped', PR.jobStateNum('processing-stopped'), 6)
  eq('job stopped is the same state', PR.jobStateNum('stopped'), 6)
  eq('job canceled (US spelling)', PR.jobStateNum('canceled'), 7)
  eq('job cancelled (the enum spelling)', PR.jobStateNum('cancelled'), 7)
  eq('job aborted', PR.jobStateNum('aborted'), 8)
  eq('job completed', PR.jobStateNum('completed'), 9)
  eq('printer idle', PR.printerStateNum('idle'), 3)
  eq('printer processing', PR.printerStateNum('processing'), 4)
  eq('printer stopped', PR.printerStateNum('stopped'), 5)
})

group('plain integers pass through, in either form', () => {
  for (let n = 3; n <= 9; n++) eq(`job ${n} as text`, PR.jobStateNum(String(n)), n)
  eq('as a number', PR.jobStateNum(5), 5)
  eq('with surrounding whitespace', PR.jobStateNum(' 4'), 4)
  eq('trailing whitespace', PR.jobStateNum('5 '), 5)
  eq('printer 4 as text', PR.printerStateNum('4'), 4)
  // parseInt takes the numeric prefix, so a report that appends a unit or a
  // stray word still reads as the state it starts with.
  eq('a numeric prefix is taken', PR.jobStateNum('5 things'), 5)
  eq('a float truncates', PR.printerStateNum('4.9'), 4)
})

group('anything else is NaN, and NaN is what keeps a view from printing a state', () => {
  // The normalizer's comment says callers "render blank, never Unknown", and
  // the library itself is half of that: the two label functions do answer
  // "Unknown" for an unparseable state, which is what jobSub's fallback
  // wants. The view half is PrintersIsland.qml, which hides its own state
  // label unless the state is active - and NaN is not in 3..6.
  eq('a word that is not a state', PR.jobStateNum('bogus'), NaN)
  eq('an empty string', PR.jobStateNum(''), NaN)
  eq('null', PR.jobStateNum(null), NaN)
  eq('undefined', PR.jobStateNum(undefined), NaN)
  eq('a boolean', PR.jobStateNum(true), NaN)
  eq('an out-of-range number', PR.jobStateNum(11), 11)
  eq('a job name is not a printer state', PR.printerStateNum('pending'), NaN)
  eq('a printer state is not a job state', PR.jobStateNum('idle'), NaN)
  eq('a lowercased table lookup means case does not matter', PR.jobStateNum('PROCESSING'), 5)
  eq('a padded name is trimmed before the lookup', PR.printerStateNum('  Stopped  '), 5)
  is('the normalizer is total', ['', null, undefined, {}, [], 'x', 0].map(v => PR.jobStateNum(v)),
    (v) => v.every(x => Number.isNaN(x) || x === 0), 'NaN for everything unparseable')
  // An out-of-range number passes through rather than becoming NaN, so
  // isActiveJobState is the only thing that keeps state 11 from rendering.
  eq('an integer outside the table passes through unchanged', PR.jobStateNum(11), 11)
  eq('and is not treated as in-flight', PR.isActiveJobState(11), false)
  eq('so the label falls through to its default', PR.jobStateLabel(11), 'Unknown')
})

section('PrintersLib - printer health')

group('printerIsDown is stopped or refusing jobs, and never an unplugged printer', () => {
  eq('a stopped queue', PR.printerIsDown({ 'printer-state': 'stopped' }), true)
  eq('a queue that is not accepting jobs', PR.printerIsDown({ 'printer-state': 'processing', 'printer-is-accepting-jobs': 'false' }), true)
  eq('a healthy printing queue', PR.printerIsDown(PRINTER_ROWS[0]), false)
  eq('the paused queue from the real report is down', PR.printerIsDown(PRINTER_ROWS[1]), true)
  // An unplugged printer reads stopped too, and it gets the calm gray
  // treatment instead of the red attention icon.
  eq('an offline queue is not down', PR.printerIsDown({ 'printer-state': 'stopped', 'printer-state-reasons': ['offline'] }), false)
  eq('offline by state message', PR.printerIsDown({ 'printer-state': 'stopped', 'printer-state-message': 'Offline - host unreachable' }), false)
  eq('a missing row is not down', PR.printerIsDown(null), false)
  eq('an empty row is not down', PR.printerIsDown({}), false)
  eq('idle is not down', PR.printerIsDown({ 'printer-state': 'idle' }), false)
  // The comparison goes through String(), so a hand-built row carrying a
  // real boolean answers identically to the report's text.
  eq('the string "false" is what the report carries', PR.printerIsDown({ 'printer-is-accepting-jobs': 'false' }), true)
  eq('a real boolean reads the same way', PR.printerIsDown({ 'printer-is-accepting-jobs': false }), true)
  eq('a real true is not down', PR.printerIsDown({ 'printer-state': 3, 'printer-is-accepting-jobs': true }), false)
})

group('printerIsOffline reads the reasons and both message attributes', () => {
  eq('the reason token, as an array', PR.printerIsOffline({ 'printer-state-reasons': ['none', 'offline'] }), true)
  eq('the reason token, as a string', PR.printerIsOffline({ 'printer-state-reasons': 'offline' }), true)
  // The check is a case-insensitive substring search for "offline", so a
  // reason that only sounds similar does not trip it.
  eq('a reason that does not contain the token', PR.printerIsOffline({ 'printer-state-reasons': 'unreachable' }), false)
  eq('the printer state message', PR.printerIsOffline({ 'printer-state-message': 'Offline' }), true)
  eq('the cups state message', PR.printerIsOffline({ 'cups-printer-state-message': 'Printer is offline' }), true)
  eq('a connected queue', PR.printerIsOffline(PRINTER_ROWS[0]), false)
  eq('a paused but connected queue', PR.printerIsOffline(PRINTER_ROWS[1]), false)
  eq('the token is case-insensitive', PR.printerIsOffline({ 'printer-state-message': 'OFFLINE' }), true)
  eq('"off" is not "offline"', PR.printerIsOffline({ 'printer-state-message': 'Printer is off' }), false)
  eq('a missing row', PR.printerIsOffline(null), false)
  eq('an empty row', PR.printerIsOffline({}), false)
  eq('every attribute absent', PR.printerIsOffline({ 'printer-state-reasons': '', 'printer-state-message': null }), false)
  eq('a reason that merely mentions "offline" in a longer string counts', PR.printerIsOffline({ 'printer-state-message': 'Not offline-reporting' }), true)
})

group('the state labels cover every code', () => {
  eq('printer 3', PR.printerStateLabel(3), 'Idle')
  eq('printer 4 prints as Printing, not Processing', PR.printerStateLabel(4), 'Printing')
  eq('printer 5', PR.printerStateLabel(5), 'Stopped')
  eq('printer by name', PR.printerStateLabel('processing'), 'Printing')
  eq('printer 2 is not a state', PR.printerStateLabel(2), 'Unknown')
  eq('printer 6 is not a state', PR.printerStateLabel(6), 'Unknown')
  eq('printer nonsense', PR.printerStateLabel('nonsense'), 'Unknown')
  eq('printer missing', PR.printerStateLabel(undefined), 'Unknown')
  for (const [code, label] of [[3, 'Pending'], [4, 'Held'], [5, 'Processing'], [6, 'Stopped'], [7, 'Canceled'], [8, 'Aborted'], [9, 'Completed']]) {
    eq(`job ${code}`, PR.jobStateLabel(code), label)
  }
  eq('job by name', PR.jobStateLabel('pending-held'), 'Held')
  eq('job 2 is not a state', PR.jobStateLabel(2), 'Unknown')
  eq('job 10 is not a state', PR.jobStateLabel(10), 'Unknown')
  eq('job nonsense', PR.jobStateLabel('nonsense'), 'Unknown')
  eq('job missing', PR.jobStateLabel(), 'Unknown')
  is('a label is never blank for any input', [null, undefined, '', 0, 99, 'x', {}, []].map(v => PR.jobStateLabel(v)),
    (v) => v.every(s => typeof s === 'string' && s.length > 0), 'always a non-empty string')
})

group('printerLine is the state label plus the reasons', () => {
  eq('printing with no reason', PR.printerLine({ 'printer-state': 'processing' }), 'Printing')
  eq('stopped for a reason', PR.printerLine({ 'printer-state': 'stopped', 'printer-state-reasons': 'paused' }), 'Stopped - paused')
  eq('an array of reasons joins with a comma', PR.printerLine({ 'printer-state': 5, 'printer-state-reasons': ['a', 'b'] }), 'Stopped - a, b')
  eq('the reason "none" is not shown', PR.printerLine({ 'printer-state': 3, 'printer-state-reasons': 'none' }), 'Idle')
  eq('a whitespace-only reason is not shown', PR.printerLine({ 'printer-state': 3, 'printer-state-reasons': '   ' }), 'Idle')
  eq('an empty reason is not shown', PR.printerLine({ 'printer-state': 3, 'printer-state-reasons': '' }), 'Idle')
  eq('a missing reason is not shown', PR.printerLine({ 'printer-state': 3 }), 'Idle')
  eq('the reason is trimmed', PR.printerLine({ 'printer-state': 3, 'printer-state-reasons': '  toner-low  ' }), 'Idle - toner-low')
  eq('a real report row reads only the label', PR.printerLine(PRINTER_ROWS[0]), 'Printing')
  eq('because the 1setOf reasons line is dropped by the parser', PR.printerLine(PRINTER_ROWS[0]), PR.printerLine({ 'printer-state': 'processing' }))
  ne('while the same row with a reason would show it', PR.printerLine(PRINTER_ROWS[0]), PR.printerLine({ 'printer-state': 'processing', 'printer-state-reasons': 'job-processing' }))
  eq('an unknown state still shows its reason', PR.printerLine({ 'printer-state': 'x', 'printer-state-reasons': 'weird' }), 'Unknown - weird')
  eq('no state at all', PR.printerLine({ 'printer-state-reasons': 'weird' }), 'Unknown - weird')
})

group('markers pairs marker-names with marker-levels', () => {
  eq('two markers', PR.markers({ 'marker-names': ['Black\\ ink', 'Color'], 'marker-levels': ['30', '100'] }),
    [{ name: 'Black ink', level: 30 }, { name: 'Color', level: 100 }])
  // CUPS writes ink names with escaped spaces.
  eq('the escaped space is unescaped', PR.markers({ 'marker-names': ['Black\\ ink'], 'marker-levels': ['1'] })[0].name, 'Black ink')
  eq('a level is rounded to an integer', PR.markers({ 'marker-names': ['x'], 'marker-levels': ['99.6'] })[0].level, 100)
  eq('a level is rounded down below the half', PR.markers({ 'marker-names': ['x'], 'marker-levels': ['99.4'] })[0].level, 99)
  eq('a numeric level works too', PR.markers({ 'marker-names': ['x'], 'marker-levels': [42] })[0].level, 42)
  eq('a scalar name and level pair', PR.markers({ 'marker-names': 'Black', 'marker-levels': '10' }), [{ name: 'Black', level: 10 }])
  // The two lists are walked together, so a longer name list does not read
  // past the level list into undefined.
  eq('the shorter list wins', PR.markers({ 'marker-names': ['a', 'b'], 'marker-levels': ['1'] }), [{ name: 'a', level: 1 }])
  eq('and a longer level list is truncated to the names', PR.markers({ 'marker-names': ['a'], 'marker-levels': ['1', '2'] }), [{ name: 'a', level: 1 }])
  eq('no names means no markers', PR.markers({ 'marker-levels': ['1'] }), [])
  eq('no levels means no markers', PR.markers({ 'marker-names': ['a'] }), [])
  eq('neither means no markers', PR.markers({}), [])
  eq('a real report row carries none, because 1setOf lines are dropped', PR.markers(PRINTER_ROWS[0]), [])
})

section('PrintersLib - aliases and display names')

group('aliasesFrom reads the ShellState "printers" section and drops empties', () => {
  eq('the aliases map', PR.aliasesFrom({ aliases: { a: 'A', b: 'B' } }), { a: 'A', b: 'B' })
  eq('an empty alias is dropped, not stored as ""', PR.aliasesFrom({ aliases: { a: 'A', b: '' } }), { a: 'A' })
  eq('a null alias is dropped', PR.aliasesFrom({ aliases: { a: null } }), {})
  eq('a numeric alias is stringified', PR.aliasesFrom({ aliases: { a: 7 } }), { a: '7' })
  eq('a missing section', PR.aliasesFrom({}), {})
  eq('a null section', PR.aliasesFrom({ aliases: null }), {})
  eq('a non-object aliases value', PR.aliasesFrom({ aliases: 'x' }), {})
  eq('a non-object section', PR.aliasesFrom(null), {})
  eq('a string section', PR.aliasesFrom('x'), {})
  eq('undefined', PR.aliasesFrom(undefined), {})
  eq('an empty alias map', PR.aliasesFrom({ aliases: {} }), {})
  noThrow('the section may not exist at all', () => PR.aliasesFrom({ other: 1 }))
})

group('displayName is the local alias over the queue name', () => {
  eq('an alias wins', PR.displayName({ 'printer-name': 'HP_LaserJet_M404' }, { HP_LaserJet_M404: 'Office Laser' }), 'Office Laser')
  eq('no alias falls back to the queue name', PR.displayName({ 'printer-name': 'HP_LaserJet_M404' }, {}), 'HP_LaserJet_M404')
  eq('an empty alias does not blank the name', PR.displayName({ 'printer-name': 'HP' }, { HP: '' }), 'HP')
  eq('an alias for another queue is not used', PR.displayName({ 'printer-name': 'HP' }, { Brother: 'Other' }), 'HP')
  eq('a missing aliases argument', PR.displayName({ 'printer-name': 'HP' }), 'HP')
  eq('a non-object aliases argument', PR.displayName({ 'printer-name': 'HP' }, 'x'), 'HP')
  eq('a row with no name', PR.displayName({}, {}), '')
  eq('a null row', PR.displayName(null, {}), '')
  eq('a numeric queue name is stringified', PR.displayName({ 'printer-name': 0 }, {}), '0')
  eq('the two real queues', PRINTER_ROWS.map(r => PR.displayName(r, { Brother_HL_L2350DW: 'Hall Printer' })), ['HP_LaserJet_M404', 'Hall Printer'])
  // Queue names stay canonical: nothing here ever rewrites printer-name.
  eq('the row keeps its canonical name', PR.displayName(PRINTER_ROWS[1], { Brother_HL_L2350DW: 'Hall Printer' }), 'Hall Printer')
  eq('and the row still reads Brother_HL_L2350DW', PRINTER_ROWS[1]['printer-name'], 'Brother_HL_L2350DW')
})

section('PrintersLib - job state and health across a job list')

group('anyPrinting is true while at least one job is processing', () => {
  eq('the real report has one processing job', PR.anyPrinting(JOB_ROWS), true)
  eq('an empty list', PR.anyPrinting([]), false)
  eq('a list of completed jobs', PR.anyPrinting([{ 'job-state': 'completed' }]), false)
  eq('a held job is not printing', PR.anyPrinting([{ 'job-state': 'held' }]), false)
  eq('a pending job is not printing', PR.anyPrinting([{ 'job-state': 'pending' }]), false)
  eq('a stopped job is not printing', PR.anyPrinting([{ 'job-state': 'processing-stopped' }]), false)
  eq('the number state works too', PR.anyPrinting([{ 'job-state': '5' }]), true)
})

group('failedJobs is canceled or aborted', () => {
  // 7 canceled is the state a job keeps on a stopped queue while the reason
  // lives on the printer, so it counts as failed here too.
  eq('a canceled job', PR.failedJobs([{ 'job-state': 'canceled' }]), true)
  eq('an aborted job', PR.failedJobs([{ 'job-state': 'aborted' }]), true)
  eq('cancelled, the enum spelling', PR.failedJobs([{ 'job-state': 'cancelled' }]), true)
  eq('a completed job is not failed', PR.failedJobs([{ 'job-state': 'completed' }]), false)
  eq('a stopped job is not failed', PR.failedJobs([{ 'job-state': 'stopped' }]), false)
  eq('a processing job is not failed', PR.failedJobs([{ 'job-state': 'processing' }]), false)
  eq('an empty list', PR.failedJobs([]), false)
  eq('the real report is healthy', PR.failedJobs(JOB_ROWS), false)
  eq('a failure anywhere in the list counts', PR.failedJobs([{ 'job-state': 'processing' }, { 'job-state': 8 }]), true)
  eq('the numeric code works', PR.failedJobs([{ 'job-state': '7' }]), true)
})

group('jobStateIcon is the bar-module icon per state', () => {
  eq('processing is the animated page', PR.jobStateIcon('processing'), 'printer')
  eq('held is the hourglass', PR.jobStateIcon('held'), 'hourglass')
  eq('pending-held too', PR.jobStateIcon('pending-held'), 'hourglass')
  eq('pending is a check', PR.jobStateIcon('pending'), 'check')
  eq('stopped is a check', PR.jobStateIcon('stopped'), 'check')
  eq('completed is a check', PR.jobStateIcon('completed'), 'check')
  eq('an unknown state is a check, never a blank', PR.jobStateIcon('nonsense'), 'check')
  eq('missing', PR.jobStateIcon(), 'check')
  eq('the numeric codes', [PR.jobStateIcon(4), PR.jobStateIcon(5), PR.jobStateIcon(9)], ['hourglass', 'printer', 'check'])
})

group('isActiveJobState is exactly the in-flight window', () => {
  // Completed/canceled/aborted are history: shown with Delete, but they
  // drive no spinner, no flash and no toast.
  for (const s of [3, 4, 5, 6]) eq(`${s} is active`, PR.isActiveJobState(s), true)
  for (const s of [7, 8, 9, 2, 1, 0, 10]) eq(`${s} is not active`, PR.isActiveJobState(s), false)
  eq('by name', PR.isActiveJobState('processing'), true)
  eq('by enum name', PR.isActiveJobState('processing-stopped'), true)
  eq('a history state by name', PR.isActiveJobState('completed'), false)
  eq('nonsense is not active', PR.isActiveJobState('nonsense'), false)
  eq('NaN is not active', PR.isActiveJobState(NaN), false)
  eq('the real report has one active job', PR.activeJobs(JOB_ROWS).map(j => j['job-id']), ['34'])
  eq('and the active subset preserves order', PR.activeJobs([
    { 'job-id': 'a', 'job-state': 5 }, { 'job-id': 'b', 'job-state': 9 }, { 'job-id': 'c', 'job-state': 3 },
  ]).map(j => j['job-id']), ['a', 'c'])
  eq('no active jobs is an empty array', PR.activeJobs([{ 'job-id': 'b', 'job-state': 9 }]), [])
  eq('an empty list', PR.activeJobs([]), [])
  // The rows are passed through by reference, not copied: the service sorts
  // the same objects it holds.
  is('the row objects themselves are returned', PR.activeJobs(JOB_ROWS)[0], (v) => v === JOB_ROWS[0], 'same reference')
})

group('the four single-job predicates', () => {
  eq('pending', PR.jobIsPending(3), true)
  eq('pending by name', PR.jobIsPending('pending'), true)
  eq('held is not pending', PR.jobIsPending(4), false)
  eq('processing', PR.jobIsProcessing(5), true)
  eq('processing by name', PR.jobIsProcessing('processing'), true)
  eq('pending is not processing', PR.jobIsProcessing(3), false)
  eq('done', PR.jobIsDone(9), true)
  eq('done by name', PR.jobIsDone('completed'), true)
  eq('processing is not done', PR.jobIsDone(5), false)
  eq('canceled is failed', PR.jobIsFailed(7), true)
  eq('aborted is failed', PR.jobIsFailed(8), true)
  eq('canceled by enum name is failed', PR.jobIsFailed('cancelled'), true)
  eq('completed is not failed', PR.jobIsFailed(9), false)
  eq('stopped is neither done nor failed', [PR.jobIsDone(6), PR.jobIsFailed(6)], [false, false])
  eq('nonsense is none of the four', [PR.jobIsPending('x'), PR.jobIsProcessing('x'), PR.jobIsDone('x'), PR.jobIsFailed('x')], [false, false, false, false])
  eq('missing is none of the four', [PR.jobIsPending(), PR.jobIsProcessing(), PR.jobIsDone(), PR.jobIsFailed()], [false, false, false, false])
  // Held and stopped are in-flight without being any of the four, which is
  // why the island carries a spinner for pending and an hourglass for the
  // rest rather than deriving one spinner from these.
  eq('which of the four is true per state', [3, 4, 5, 6, 7, 8, 9].map(s =>
    ['pending', 'processing', 'done', 'failed'].filter((_, i) =>
      [PR.jobIsPending(s), PR.jobIsProcessing(s), PR.jobIsDone(s), PR.jobIsFailed(s)][i])),
    [['pending'], [], ['processing'], [], ['failed'], ['failed'], ['done']])
  is('never two at once', [3, 4, 5, 6, 7, 8, 9].map(s =>
    [PR.jobIsPending(s), PR.jobIsProcessing(s), PR.jobIsDone(s), PR.jobIsFailed(s)].filter(Boolean).length),
    (v) => v.every(n => n <= 1), 'at most one')
})

section('PrintersLib - job text')

group('baseName reads the last path component, either separator', () => {
  eq('a tilde path', PR.baseName('~/docs/a.pdf'), 'a.pdf')
  eq('a bare name passes through', PR.baseName('a.pdf'), 'a.pdf')
  eq('an absolute path', PR.baseName('/home/vibranium/docs/report.pdf'), 'report.pdf')
  eq('a Windows path', PR.baseName('C:\\docs\\a.pdf'), 'a.pdf')
  // Whichever separator comes last wins, so a mixed path is still read.
  eq('a mixed path takes the last separator of either kind', PR.baseName('a/b\\c.pdf'), 'c.pdf')
  eq('a dotfile is not an extension', PR.baseName('.bashrc'), '.bashrc')
  eq('spaces are kept', PR.baseName('~/My Documents/Q3 report final.pdf'), 'Q3 report final.pdf')
  eq('a trailing slash leaves nothing', PR.baseName('/a/b/'), '')
  eq('a root path leaves nothing', PR.baseName('/'), '')
  eq('an empty string', PR.baseName(''), '')
  eq('nullish is an empty string, not "null"', PR.baseName(null), '')
  eq('a number is stringified', PR.baseName(7), '7')
  eq('a relative path', PR.baseName('./build/out.pdf'), 'out.pdf')
  eq('a name that is only an extension', PR.baseName('.pdf'), '.pdf')
  eq('a missing argument is an empty string', PR.baseName(), '')
  noThrow('a missing argument does not throw', () => PR.baseName())
  noThrow('a non-string argument does not throw', () => PR.baseName(42))
})

group('jobTitle falls back through three attributes, then the id', () => {
  eq('job-name', PR.jobTitle({ 'job-name': 'invoice.docx' }), 'invoice.docx')
  // CUPS usually carries a full path in job-name, hence the basename.
  eq('a full path in job-name is reduced', PR.jobTitle({ 'job-name': '/home/vibranium/docs/report.pdf' }), 'report.pdf')
  eq('a Windows path too', PR.jobTitle({ 'job-name': 'C:\\tmp\\scan.pdf' }), 'scan.pdf')
  eq('a blank job-name falls through to document-name', PR.jobTitle({ 'job-name': '  ', 'document-name': 'fallback.png' }), 'fallback.png')
  eq('and to document-name-supplied', PR.jobTitle({ 'job-name': '', 'document-name': '', 'document-name-supplied': 'supplied.pdf' }), 'supplied.pdf')
  eq('the supplied name is basenamed as well', PR.jobTitle({ 'document-name-supplied': '/tmp/deep/supplied.pdf' }), 'supplied.pdf')
  eq('the first non-empty candidate wins', PR.jobTitle({ 'job-name': 'a.pdf', 'document-name': 'b.pdf' }), 'a.pdf')
  eq('a numeric job-name is stringified', PR.jobTitle({ 'job-name': 7 }), '7')
  eq('with no candidate at all, the id', PR.jobTitle({ 'job-id': 99 }), 'Job 99')
  eq('a string id', PR.jobTitle({ 'job-id': '99' }), 'Job 99')
  eq('and with no id either, a bare label - never blank', PR.jobTitle({}), 'Untitled job')
  eq('a null row', PR.jobTitle(null), 'Untitled job')
  eq('a whitespace id is not an id', PR.jobTitle({ 'job-id': '   ' }), 'Untitled job')
  eq('the real report rows', JOB_ROWS.map(j => PR.jobTitle(j)), ['report.pdf', 'invoice.docx'])
})

group('jobFileIcon picks the icon from the document extension', () => {
  eq('pdf', PR.jobFileIcon({ 'job-name': 'a.pdf' }), 'file-pdf')
  eq('svg', PR.jobFileIcon({ 'job-name': 'a.svg' }), 'file-svg')
  eq('an image', PR.jobFileIcon({ 'job-name': 'photo.png' }), 'file-image')
  eq('an uppercase extension still matches', PR.jobFileIcon({ 'job-name': 'photo.PNG' }), 'file-image')
  eq('webp', PR.jobFileIcon({ 'job-name': 'a.webp' }), 'file-image')
  eq('an archive', PR.jobFileIcon({ 'job-name': 'dump.tar.gz' }), 'file-archive')
  eq('7z', PR.jobFileIcon({ 'job-name': 'a.7z' }), 'file-archive')
  eq('a sheet', PR.jobFileIcon({ 'job-name': 'a.xlsx' }), 'file-xls')
  eq('csv is a sheet, not code', PR.jobFileIcon({ 'job-name': 'a.csv' }), 'file-xls')
  eq('a database', PR.jobFileIcon({ 'job-name': 'a.sqlite3' }), 'file-db')
  eq('a diff', PR.jobFileIcon({ 'job-name': 'a.patch' }), 'file-diff')
  eq('a font', PR.jobFileIcon({ 'job-name': 'a.woff2' }), 'file-font')
  eq('music', PR.jobFileIcon({ 'job-name': 'a.flac' }), 'file-music')
  eq('code', PR.jobFileIcon({ 'job-name': 'a.rs' }), 'file-code')
  eq('markdown is code in the shipped table', PR.jobFileIcon({ 'job-name': 'notes.md' }), 'file-code')
  eq('an unknown extension falls back to file', PR.jobFileIcon({ 'job-name': 'a.qqq' }), 'file')
  eq('no extension at all falls back to file', PR.jobFileIcon({ 'job-name': 'README' }), 'file')
  // `dot > 0` is what keeps a dotfile from reading as an extension: the dot
  // of ".bashrc" is at index 0.
  eq('a dotfile falls back to file', PR.jobFileIcon({ 'job-name': '.bashrc' }), 'file')
  eq('a version-like name has no known extension', PR.jobFileIcon({ 'job-name': 'v1.2.3' }), 'file')
  eq('the last dot wins', PR.jobFileIcon({ 'job-name': 'a.tar.jpg' }), 'file-image')
  eq('an empty row', PR.jobFileIcon({}), 'file')
  eq('a null row', PR.jobFileIcon(null), 'file')
  eq('"Job 99" has no extension', PR.jobFileIcon({ 'job-id': 99 }), 'file')
  // The icon follows the resolved title, so a full path resolves first.
  eq('a full path in job-name', PR.jobFileIcon({ 'job-name': '/home/vibranium/docs/report.pdf' }), 'file-pdf')
  eq('the real report rows', JOB_ROWS.map(j => PR.jobFileIcon(j)), ['file-pdf', 'file'])
})

group('jobSub is printer - time - size, with empty parts skipped', () => {
  eq('all three parts', PR.jobSub({ printer: 'HP_LaserJet_M404', 'time-at-creation': 1756339200, 'job-k-octets': 2048 }, {}).split(' - ').length, 3)
  eq('the printer shows its alias', PR.jobSub({ printer: 'HP_LaserJet_M404' }, { HP_LaserJet_M404: 'Office Laser' }), 'Office Laser')
  eq('an empty alias does not blank the printer', PR.jobSub({ printer: 'HP' }, { HP: '' }), 'HP')
  eq('a queue name is not a user name - single-user boxes repeat it', PR.jobSub({ printer: 'HP', 'job-originating-user-name': 'vibranium' }), 'HP')
  eq('1024 KB is 1 MB', PR.jobSub({ 'job-k-octets': 1024 }), '1 MB')
  eq('1536 KB is 1.5 MB', PR.jobSub({ 'job-k-octets': 1536 }), '1.5 MB')
  eq('under 1 MB stays in KB', PR.jobSub({ 'job-k-octets': 100 }), '100 KB')
  eq('a fractional KB is rounded', PR.jobSub({ 'job-k-octets': 100.6 }), '101 KB')
  eq('0 KB is skipped, not shown as "0 KB"', PR.jobSub({ 'job-k-octets': 0, 'job-state': 5 }), 'Processing')
  eq('a missing size is skipped', PR.jobSub({ 'job-state': 3 }), 'Pending')
  // Never a dangling separator, and never blank either: the state label is
  // the last resort.
  eq('with nothing at all it falls back to the state label', PR.jobSub({}), 'Unknown')
  eq('a null row falls back too', PR.jobSub(null), 'Unknown')
  eq('a missing time is skipped', PR.jobSub({ printer: 'HP', 'time-at-creation': 0 }).split(' - ').length, 1)
  eq('a non-numeric time is skipped', PR.jobSub({ printer: 'HP', 'time-at-creation': 'soon' }), 'HP')
  eq('a whitespace printer name is skipped', PR.jobSub({ printer: '   ' }), 'Unknown')
  eq('the real report jobs, once the service derives the printer', JOBS_WITH_PRINTER.map(j => PR.jobSub(j, {}).split(' - ')[0]), ['HP_LaserJet_M404', 'Brother_HL_L2350DW'])
  eq('and with an alias applied', PR.jobSub(JOBS_WITH_PRINTER[0], { HP_LaserJet_M404: 'Office Laser' }).split(' - ')[0], 'Office Laser')
  is('the line never starts or ends with a separator', [{}, { printer: 'HP' }, { 'job-k-octets': 5 }, { 'job-state': 5, 'job-k-octets': 5 }].map(r => PR.jobSub(r, {})),
    (v) => v.every(s => !s.startsWith(' - ') && !s.endsWith(' - ') && !s.includes(' -  ')), 'no dangling separator')
})

group('trim1 keeps one decimal unless it rounds away', () => {
  eq('a whole number', PR.trim1(1), '1')
  eq('a whole number written with a fraction', PR.trim1(1.0), '1')
  eq('one decimal', PR.trim1(1.3), '1.3')
  eq('a second decimal rounds away', PR.trim1(1.04), '1')
  eq('two digits', PR.trim1(10), '10')
  eq('zero', PR.trim1(0), '0')
  eq('a large value keeps one decimal', PR.trim1(1024.5), '1024.5')
})

group('jobTime is DD.MM HH:MM from a unix seconds integer', () => {
  // The formatter uses local time, so the expectation is computed from the
  // same local Date rather than pinned to a timezone: what is asserted is
  // the shape and the local reading, not a literal.
  const unix = 1756339200
  const d = new Date(unix * 1000)
  const pad = (n) => String(n).padStart(2, '0')
  const local = pad(d.getDate()) + '.' + pad(d.getMonth() + 1) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes())
  eq('reads the local wall clock', PR.jobTime(unix), local)
  match('the shape is DD.MM HH:MM', PR.jobTime(unix), /^\d{2}\.\d{2} \d{2}:\d{2}$/)
  is('the day and month are zero padded', PR.jobTime(unix), (v) => /^\d{2}\.\d{2} /.test(v), 'two digits each')
  eq('a string unix time is coerced', PR.jobTime(String(unix)), local)
  // "" rather than an epoch artifact, so a generic line skips the field.
  eq('zero', PR.jobTime(0), '')
  eq('null', PR.jobTime(null), '')
  eq('undefined', PR.jobTime(undefined), '')
  eq('NaN', PR.jobTime(NaN), '')
  eq('Infinity', PR.jobTime(Infinity), '')
  eq('non-numeric text', PR.jobTime('soon'), '')
  eq('a missing argument', PR.jobTime(), '')
  match('a pre-epoch time is not blank', PR.jobTime(-86400), /^\d{2}\.\d{2} \d{2}:\d{2}$/)
})

section('PrintersLib - filtering')

group('filterDismissed drops locally cleared history and mutates nothing', () => {
  eq('a dismissed job is gone', PR.filterDismissed(JOB_ROWS, { 35: true }).map(j => j['job-id']), ['34'])
  eq('a textual key works too', PR.filterDismissed(JOB_ROWS, { '35': true }).map(j => j['job-id']), ['34'])
  eq('a false value is not a dismissal', PR.filterDismissed(JOB_ROWS, { 35: false }).length, 2)
  eq('a truthy non-true value is not a dismissal either', PR.filterDismissed(JOB_ROWS, { 35: 'yes' }).length, 2)
  eq('an empty map keeps everything', PR.filterDismissed(JOB_ROWS, {}).length, 2)
  eq('a missing map keeps everything', PR.filterDismissed(JOB_ROWS).length, 2)
  eq('a null map keeps everything', PR.filterDismissed(JOB_ROWS, null).length, 2)
  eq('a non-object map keeps everything', PR.filterDismissed(JOB_ROWS, 'x').length, 2)
  eq('dismissing both empties the list', PR.filterDismissed(JOB_ROWS, { 34: true, 35: true }), [])
  eq('the input is not mutated', JOB_ROWS.length, 2)
  is('a nullish map short-circuits to the same array', PR.filterDismissed(JOB_ROWS, null), (v) => v === JOB_ROWS, 'same reference')
  is('an empty map builds a new array with the same rows', PR.filterDismissed(JOB_ROWS, {}), (v) => v !== JOB_ROWS && v.length === 2, 'a copy')
  // The key is the stringified job-id, so a row with no id at all collides
  // with a dismissal recorded under "".
  eq('an idless row is keyed as ""', PR.filterDismissed([{ 'job-state': 5 }], { '': true }), [])
  eq('and a numeric id is keyed as its text', PR.filterDismissed([{ 'job-id': 7 }], { 7: true }), [])
})

group('filterPrinters searches name, alias, model and location', () => {
  eq('by location', PR.filterPrinters(PRINTER_ROWS, 'office', {}).map(r => r['printer-name']), ['HP_LaserJet_M404'])
  eq('by queue name', PR.filterPrinters(PRINTER_ROWS, 'brother', {}).map(r => r['printer-name']), ['Brother_HL_L2350DW'])
  eq('by make and model', PR.filterPrinters(PRINTER_ROWS, 'laserjet', {}).map(r => r['printer-name']), ['HP_LaserJet_M404'])
  eq('by local alias', PR.filterPrinters(PRINTER_ROWS, 'hall', { Brother_HL_L2350DW: 'Hall Printer' }).map(r => r['printer-name']), ['Brother_HL_L2350DW'])
  eq('the search is case-insensitive', PR.filterPrinters(PRINTER_ROWS, 'OFFICE', {}).map(r => r['printer-name']), ['HP_LaserJet_M404'])
  eq('a substring of a longer word matches', PR.filterPrinters(PRINTER_ROWS, 'ice', {}).map(r => r['printer-name']), ['HP_LaserJet_M404'])
  eq('no match is an empty list', PR.filterPrinters(PRINTER_ROWS, 'zzz', {}), [])
  eq('an empty query keeps everything', PR.filterPrinters(PRINTER_ROWS, '', {}).length, 2)
  eq('a whitespace-only query keeps everything', PR.filterPrinters(PRINTER_ROWS, '   ', {}).length, 2)
  eq('a missing query keeps everything', PR.filterPrinters(PRINTER_ROWS).length, 2)
  eq('the input is not mutated', PRINTER_ROWS.length, 2)
  is('the empty-query case returns the same array', PR.filterPrinters(PRINTER_ROWS, ''), (v) => v === PRINTER_ROWS, 'same reference')
  eq('a row with no searchable field does not match', PR.filterPrinters([{}], 'x', {}), [])
  eq('a numeric location is searchable as text', PR.filterPrinters([{ 'printer-location': 12345 }], '234', {}).length, 1)
  // Only the four documented fields are searched: printer-up-time is not one
  // of them, so a search never matches on it.
  eq('and no other field is searched', PR.filterPrinters([{ 'printer-up-time': 382114 }], '382', {}), [])
})

group('filterJobs searches the raw job-name, the user and the printer', () => {
  eq('by the file name', PR.filterJobs(JOB_ROWS, 'report').map(j => j['job-id']), ['34'])
  // The filter reads the attribute, not the resolved title, so a directory
  // component is searchable too - the opposite of what jobTitle does.
  eq('by a directory inside the full path', PR.filterJobs(JOB_ROWS, 'docs').map(j => j['job-id']), ['34'])
  eq('by the originating user', PR.filterJobs(JOB_ROWS, 'vibranium').map(j => j['job-id']), ['34'])
  eq('by the queue name, once the service derived it', PR.filterJobs(JOBS_WITH_PRINTER, 'brother').map(j => j['job-id']), ['35'])
  eq('the search is case-insensitive', PR.filterJobs(JOB_ROWS, 'REPORT').map(j => j['job-id']), ['34'])
  eq('no match', PR.filterJobs(JOB_ROWS, 'zzz'), [])
  eq('an empty query keeps everything', PR.filterJobs(JOB_ROWS, '').length, 2)
  eq('a whitespace-only query keeps everything', PR.filterJobs(JOB_ROWS, '  ').length, 2)
  eq('a missing query keeps everything', PR.filterJobs(JOB_ROWS).length, 2)
  eq('the input is not mutated', JOB_ROWS.length, 2)
})

group('filterRows is the shared key-list filter', () => {
  const rows = [{ a: 'hello' }, { b: 'world' }, { a: 'HELLO there', b: 'x' }]
  eq('the first key matches', PR.filterRows(rows, 'hello', ['a']).length, 2)
  eq('the second key matches', PR.filterRows(rows, 'world', ['b']).length, 1)
  eq('either key matching is enough', PR.filterRows(rows, 'hello', ['a', 'b']).length, 2)
  eq('a row matching two keys is listed once', PR.filterRows(rows, 'x', ['a', 'b']).map(r => r === rows[2]), [true])
  eq('the match is case-insensitive', PR.filterRows(rows, 'HELLO', ['a']).length, 2)
  eq('an empty query keeps everything', PR.filterRows(rows, '', ['a']).length, 3)
  eq('a whitespace-only query keeps everything', PR.filterRows(rows, ' ', ['a']).length, 3)
  eq('an empty key list matches nothing', PR.filterRows(rows, 'hello', []), [])
  eq('a missing field is an empty string, so it cannot match', PR.filterRows([{ a: 'x' }], 'x', ['b']), [])
  eq('a numeric field is searched as text', PR.filterRows([{ a: 42 }], '4', ['a']).length, 1)
  eq('a null field is searched as an empty string', PR.filterRows([{ a: null }], 'x', ['a']), [])
  is('the empty-query case returns the same array', PR.filterRows(rows, '', ['a']), (v) => v === rows, 'same reference')
  eq('filterJobs is filterRows over three job keys', PR.filterJobs(JOBS_WITH_PRINTER, 'vibranium').length,
    PR.filterRows(JOBS_WITH_PRINTER, 'vibranium', ['job-name', 'job-originating-user-name', 'printer']).length)
})

// --- what changed, as a diff against the previous read ---------------------
//
// These three are the only place in the tree that reports a printer or job
// CHANGE, and they are pure functions over two IPP reads precisely so they can
// be pinned here: a transition computed against the wrong previous read is a
// true sentence about a false event, and no amount of reading the service would
// have shown that.

group('printerStates reduces a CUPS read to the one field a change is about', () => {
  eq('a queue name to its printer-state label',
    PR.printerStates([{ 'printer-name': 'Office', 'printer-state': 5 }]), { Office: 'Stopped' })
  eq('two queues, both read',
    PR.printerStates([
      { 'printer-name': 'Office', 'printer-state': 3 },
      { 'printer-name': 'Lobby', 'printer-state': 4 },
    ]), { Office: 'Idle', Lobby: 'Printing' })
  eq('an unnamed row is dropped rather than filed under ""',
    PR.printerStates([{ 'printer-name': '', 'printer-state': 3 }]), {})
  eq('a non-row is skipped', PR.printerStates([null, 7, 'x']), {})
  eq('not an array', PR.printerStates(undefined), {})
  eq('no rows at all', PR.printerStates([]), {})
})

group('printerStateTransitions reports a change, never a snapshot', () => {
  const prev = PR.printerStates([
    { 'printer-name': 'Office', 'printer-state': 3 },
    { 'printer-name': 'Lobby', 'printer-state': 3 },
  ])
  const read = (spec) => PR.printerStates(spec.map(([n, s]) => ({ 'printer-name': n, 'printer-state': s })))

  eq('idle to printing', PR.printerStateTransitions(prev, read([['Office', 4], ['Lobby', 3]])),
    [{ printer: 'Office', from: 'Idle', to: 'Printing' }])
  eq('idle to stopped is how "went offline" reads',
    PR.printerStateTransitions(prev, read([['Office', 5], ['Lobby', 3]])),
    [{ printer: 'Office', from: 'Idle', to: 'Stopped' }])
  eq('a queue that left the queue ends at null, not at a label',
    PR.printerStateTransitions(prev, read([['Office', 3]])),
    [{ printer: 'Lobby', from: 'Idle', to: null }])
  eq('an unchanged read reports nothing', PR.printerStateTransitions(prev, read([['Office', 3], ['Lobby', 3]])), [])
  eq('a queue that JOINS is not a transition - it has no previous state',
    PR.printerStateTransitions(prev, read([['Office', 3], ['Lobby', 3], ['New', 3]])), [])

  // The first-read guard, which is the whole reason this function is not just
  // a map diff: a printer that was already stopped when the shell started was
  // not stopped by it.
  eq('an empty previous map yields nothing, not one line per queue',
    PR.printerStateTransitions({}, read([['Office', 5], ['Lobby', 5]])), [])
  eq('two empty maps are empty', PR.printerStateTransitions({}, {}), [])
  eq('a previous map and no current queues is every queue gone',
    PR.printerStateTransitions(prev, {}),
    [{ printer: 'Office', from: 'Idle', to: null }, { printer: 'Lobby', from: 'Idle', to: null }])
  eq('null on either side does not throw',
    [PR.printerStateTransitions(null, null), PR.printerStateTransitions(null, read([['A', 3]]))],
    [[], []])
})

group('queuedJobs names new work and refuses to call history new', () => {
  eq('an id absent from the previous read is queued',
    PR.queuedJobs([{ 'job-id': '7' }], [{ 'job-id': '7' }, { 'job-id': '8', printer: 'Office' }]),
    [{ id: '8', printer: 'Office', active: 0 }])
  eq('the active count travels with it, because the number needs it',
    PR.queuedJobs([{ 'job-id': '7' }], [
      { 'job-id': '7', 'job-state': 9 },
      { 'job-id': '8', printer: 'Office', 'job-state': 5 },
    ]), [{ id: '8', printer: 'Office', active: 1 }])
  eq('an empty previous list yields nothing - the first read is CUPS history',
    PR.queuedJobs([], [{ 'job-id': '9', printer: 'Office', 'job-state': 9 }]), [])
  eq('nothing queued when both reads agree', PR.queuedJobs([{ 'job-id': '7' }], [{ 'job-id': '7' }]), [])
  eq('a row with no id is skipped rather than filed under ""',
    PR.queuedJobs([{ 'job-id': '7' }], [{ 'job-id': '' }]), [])
  eq('a missing printer is empty for the caller to render, not "undefined"',
    PR.queuedJobs([{ 'job-id': '7' }], [{ 'job-id': '8' }]),
    [{ id: '8', printer: '', active: 0 }])
  eq('neither side an array does not throw',
    [PR.queuedJobs(null, null), PR.queuedJobs(undefined, [{ 'job-id': '1' }])], [[], []])
  eq('a non-row in either list is skipped',
    PR.queuedJobs([null, { 'job-id': '7' }], [{ 'job-id': '8' }, null]), [{ id: '8', printer: '', active: 0 }])
})

// ---------------------------------------------------------------------------
// weather/Model.js
// ---------------------------------------------------------------------------

// A trimmed but structurally faithful Open-Meteo response: current, daily and
// hourly, with the utc_offset_seconds the hourly reader needs.
const OM = {
  utc_offset_seconds: 3600,
  current: {
    time: '2026-01-01T12:00', temperature_2m: -3.4, apparent_temperature: -7.8,
    wind_speed_10m: 22.6, relative_humidity_2m: 81, weather_code: 71, is_day: 0,
    pressure_msl: 1013.4, cloud_cover: 40, precipitation: 0.4,
  },
  daily: {
    time: ['2026-01-01', '2026-01-02', '2026-01-03'],
    temperature_2m_max: [1.2, 2.4, 3.6],
    temperature_2m_min: [-5.5, -4.5, -3.5],
    apparent_temperature_max: [-2.1, -1.1, 0.1],
    precipitation_probability_max: [0, 55, 100],
    wind_speed_10m_max: [10, 20, 30],
    weather_code: [0, 61, 95],
  },
  hourly: {
    time: ['2026-01-01T12:00', '2026-01-01T18:00', '2026-01-02T00:00', '2026-01-02T06:00'],
    temperature_2m: [-1, 0, 1, 2],
    precipitation_probability: [5, 10, 20, 30],
    is_day: [1, 1, 0, 0],
    weather_code: [0, 1, 2, 3],
    relative_humidity_2m: [70, 95, 80, 60],
  },
}
// wttr.in?format=j1, trimmed to three days with their hourly series.
const WTTR = {
  current_condition: [{ temp_C: '1', weatherCode: '113' }],
  weather: [
    {
      date: '2026-01-01', maxtempC: '1', mintempC: '-5',
      hourly: [
        { time: '0', FeelsLikeC: '-3', FeelsLikeF: '27', chanceofrain: '10', windspeedKmph: '5', windspeedMiles: '3', humidity: '80', weatherCode: '113' },
        { time: '1200', FeelsLikeC: '-1', FeelsLikeF: '30', chanceofrain: '20', windspeedKmph: '9', windspeedMiles: '6', humidity: '70', weatherCode: '116' },
        { time: '2400', FeelsLikeC: '-2', FeelsLikeF: '28', chanceofrain: '30', windspeedKmph: '11', windspeedMiles: '7', humidity: '90', weatherCode: '119' },
      ],
    },
    {
      date: '2026-01-02', maxtempC: '2', mintempC: '-4',
      hourly: [{ time: '0', FeelsLikeC: '-2', chanceofrain: '5', windspeedKmph: '4', windspeedMiles: '2', humidity: '75' }],
    },
    { date: '2026-01-03', maxtempC: '3', mintempC: '-3', hourly: [] },
  ],
}

section('weather/Model - coordinates: the gate every request passes')

group('a usable pair is two finite numbers inside their real range', () => {
  eq('numbers', WM.coordinatesOf(55.75, 37.61), { latitude: 55.75, longitude: 37.61 })
  eq('numeric strings, as a settings file carries them', WM.coordinatesOf('55.75', '37.61'), { latitude: 55.75, longitude: 37.61 })
  eq('with surrounding whitespace', WM.coordinatesOf('  12.5  ', 3), { latitude: 12.5, longitude: 3 })
  eq('the origin', WM.coordinatesOf(0, 0), { latitude: 0, longitude: 0 })
  eq('the result is a fresh object with named members', Object.keys(WM.coordinatesOf(1, 2)), ['latitude', 'longitude'])
  is('and both members are numbers', WM.coordinatesOf('1', '2'), (v) => typeof v.latitude === 'number' && typeof v.longitude === 'number', 'numbers, not strings')
})

group('the header is explicit that an isNaN-only check is not enough', () => {
  // "parseFloat("Infinity") succeeds, and an out-of-range pair is a
  // malformed request to every provider, not a usable location."
  eq('Infinity', WM.coordinatesOf(Infinity, 0), null)
  eq('"Infinity" as text', WM.coordinatesOf('Infinity', 0), null)
  eq('-Infinity', WM.coordinatesOf(0, -Infinity), null)
  eq('"-Infinity" as text', WM.coordinatesOf(0, '-Infinity'), null)
  eq('NaN', WM.coordinatesOf(NaN, 0), null)
  eq('one bad member is enough', WM.coordinatesOf(0, NaN), null)
  eq('lat above 90', WM.coordinatesOf(90.5, 0), null)
  eq('lat below -90', WM.coordinatesOf(-90.5, 0), null)
  eq('lon above 180', WM.coordinatesOf(0, 180.5), null)
  eq('lon below -180', WM.coordinatesOf(0, -180.5), null)
  eq('a wildly out-of-range pair', WM.coordinatesOf(999, 999), null)
})

group('the range boundaries themselves are inside', () => {
  eq('north pole', WM.coordinatesOf(90, 0), { latitude: 90, longitude: 0 })
  eq('south pole', WM.coordinatesOf(-90, 0), { latitude: -90, longitude: 0 })
  eq('the antimeridian east', WM.coordinatesOf(0, 180), { latitude: 0, longitude: 180 })
  eq('the antimeridian west', WM.coordinatesOf(0, -180), { latitude: 0, longitude: -180 })
  eq('both corners', WM.coordinatesOf(90, 180), { latitude: 90, longitude: 180 })
  eq('and the other', WM.coordinatesOf(-90, -180), { latitude: -90, longitude: -180 })
  eq('one ulp over the latitude bound is out', WM.coordinatesOf(90.0001, 0), null)
  eq('one ulp over the longitude bound is out', WM.coordinatesOf(0, 180.0001), null)
})

group('non-numeric input is rejected, not coerced into a location', () => {
  eq('an empty string', WM.coordinatesOf('', 1), null)
  eq('whitespace', WM.coordinatesOf('  ', 1), null)
  eq('null', WM.coordinatesOf(null, null), null)
  eq('undefined', WM.coordinatesOf(undefined, undefined), null)
  eq('a boolean', WM.coordinatesOf(true, 1), null)
  eq('an object', WM.coordinatesOf({}, 1), null)
  eq('a missing argument', WM.coordinatesOf(), null)
  // parseFloat takes a numeric prefix, so a hand-edited settings file with
  // a stray suffix still reads as the number it starts with - which is
  // pinned because it is the one coercion that is not a rejection.
  eq('a numeric prefix is taken', WM.coordinatesOf('12abc', 1), { latitude: 12, longitude: 1 })
  eq('an array coerces to its first element', WM.coordinatesOf([55.7], 3), { latitude: 55.7, longitude: 3 })
  eq('a two-element array is its first element', WM.coordinatesOf([1, 2], 3), { latitude: 1, longitude: 3 })
  for (const v of [null, undefined, '', '  ', {}, [], NaN, Infinity, true]) {
    noThrow(`coordinatesOf(${String(v)}, 0) does not throw`, () => WM.coordinatesOf(v, 0))
  }
})

section('weather/Model - the location file and the picker')

group('parseLocationFile reads {name, latitude, longitude}', () => {
  eq('a full record', WM.parseLocationFile('{"name":"Berlin","latitude":52.52,"longitude":13.405}'),
    { name: 'Berlin', latitude: 52.52, longitude: 13.405 })
  eq('the name is trimmed', WM.parseLocationFile('{"name":"  Berlin  ","latitude":52.52,"longitude":13.405}').name, 'Berlin')
  eq('string coordinates are validated and returned as numbers', WM.parseLocationFile('{"name":"Berlin","latitude":"52.52","longitude":"13.405"}'),
    { name: 'Berlin', latitude: 52.52, longitude: 13.405 })
  eq('a non-string name becomes an empty one', WM.parseLocationFile('{"name":42,"latitude":52.52,"longitude":13.405}'),
    { name: '', latitude: 52.52, longitude: 13.405 })
  // A pair that fails the range check lands in the same name-only state as a
  // missing pair, which is what "IP auto-detect" means to the fetches.
  eq('an out-of-range pair keeps the name and drops both legs', WM.parseLocationFile('{"name":"X","latitude":999,"longitude":13.405}'),
    { name: 'X', latitude: null, longitude: null })
  eq('a name-only file is a valid IP auto-detect state', WM.parseLocationFile('{"name":"X"}'),
    { name: 'X', latitude: null, longitude: null })
  eq('an empty object is the same state', WM.parseLocationFile('{}'), { name: '', latitude: null, longitude: null })
})

group('anything unreadable is the unset state, never an exception', () => {
  const unset = { name: '', latitude: null, longitude: null }
  eq('unparseable text', WM.parseLocationFile('not json'), unset)
  eq('a truncated document', WM.parseLocationFile('{"name":"Ber'), unset)
  eq('an empty file', WM.parseLocationFile(''), unset)
  eq('a null file', WM.parseLocationFile(null), unset)
  eq('undefined', WM.parseLocationFile(undefined), unset)
  eq('the literal null', WM.parseLocationFile('null'), unset)
  eq('a bare number', WM.parseLocationFile('5'), unset)
  // An array is `typeof "object"`, so it survives the type gate and then
  // fails the coordinate pair - landing on the same unset state.
  eq('an array document', WM.parseLocationFile('[1,2]'), unset)
  eq('a number in a name field only', WM.parseLocationFile('{"name":7}'), unset)
  eq('the unset state has no coordinates at all', WM.parseLocationFile('{}').latitude, null)
})

group('wttrLocationQuery prefers exact coordinates, then the encoded name', () => {
  eq('both coordinates present', WM.wttrLocationQuery('Berlin', 52.52, 13.405), '52.52,13.405')
  eq('coordinates as text', WM.wttrLocationQuery('Berlin', '52.52', '13.405'), '52.52,13.405')
  eq('the name is ignored when a pair exists', WM.wttrLocationQuery('Somewhere Else', 0, 0), '0,0')
  // A hand-edited file may carry only a name, so the name leg exists.
  eq('name only', WM.wttrLocationQuery('Berlin', null, null), 'Berlin')
  eq('an out-of-range pair falls back to the name', WM.wttrLocationQuery('Berlin', 91, 13.405), 'Berlin')
  eq('a space is percent-encoded', WM.wttrLocationQuery('New York', null, null), 'New%20York')
  eq('an ampersand is percent-encoded', WM.wttrLocationQuery('R & D', null, null), 'R%20%26%20D')
  eq('a non-ASCII name is UTF-8 encoded', WM.wttrLocationQuery('Bärich', null, null), 'B%C3%A4rich')
  eq('a slash in a name is encoded', WM.wttrLocationQuery('A/B', null, null), 'A%2FB')
  eq('the name is trimmed first', WM.wttrLocationQuery('  Berlin  ', null, null), 'Berlin')
  // An empty query is the IP auto-detect request, which is a different URL.
  eq('no name and no pair is an empty query', WM.wttrLocationQuery('', null, null), '')
  eq('a whitespace name is an empty query', WM.wttrLocationQuery('   ', null, null), '')
  eq('no arguments at all is an empty query', WM.wttrLocationQuery(), '')
  eq('nullish name and pair', WM.wttrLocationQuery(null, undefined, undefined), '')
  notContains('an empty query carries no comma', WM.wttrLocationQuery('', null, null), ',')
})

group('parseGeocodingResults builds the picker rows', () => {
  const raw = JSON.stringify({
    results: [
      { name: 'Berlin', latitude: 52.52, longitude: 13.405, admin1: 'Berlin', country: 'Germany', country_code: 'DE' },
      { name: 'Berlin', latitude: 52.5, longitude: 13.4, country: 'Germany' },
      { name: 'X', latitude: 1, longitude: 2 },
    ],
  })
  const out = WM.parseGeocodingResults(raw)
  eq('three rows', out.length, 3)
  eq('admin1 and country become the description', out[0].description, 'Berlin, Germany')
  eq('a missing admin1 leaves just the country', out[1].description, 'Germany')
  eq('a missing country leaves an empty description', out[2].description, '')
  eq('the row shape', Object.keys(out[0]), ['name', 'description', 'latitude', 'longitude'])
  // The coordinates are passed through untouched - the picker stores what
  // the provider said, and coordinatesOf is the gate at request time.
  eq('coordinates are verbatim, not rounded', out[1].latitude, 52.5)
  eq('a string coordinate is not converted', WM.parseGeocodingResults('{"results":[{"name":"A","latitude":"1","longitude":"2"}]}')[0].latitude, '1')
  eq('a result with no name is dropped', WM.parseGeocodingResults('{"results":[{"latitude":1,"longitude":2}]}'), [])
  eq('a result with no latitude is dropped', WM.parseGeocodingResults('{"results":[{"name":"A","longitude":2}]}'), [])
  eq('a result with no longitude is dropped', WM.parseGeocodingResults('{"results":[{"name":"A","latitude":1}]}'), [])
  eq('a null result is dropped', WM.parseGeocodingResults('{"results":[null]}'), [])
  eq('a zero coordinate is not a missing coordinate', WM.parseGeocodingResults('{"results":[{"name":"Null Island","latitude":0,"longitude":0}]}').length, 1)
})

group('an empty, missing or unparseable geocoding answer is no suggestions', () => {
  eq('an empty result list', WM.parseGeocodingResults('{"results":[]}'), [])
  eq('no results key', WM.parseGeocodingResults('{}'), [])
  eq('a null results key', WM.parseGeocodingResults('{"results":null}'), [])
  eq('unparseable text', WM.parseGeocodingResults('nope'), [])
  eq('an empty body', WM.parseGeocodingResults(''), [])
  eq('null', WM.parseGeocodingResults(null), [])
  eq('the literal null', WM.parseGeocodingResults('null'), [])
  eq('a bot-gate HTML body', WM.parseGeocodingResults('<html>are you a robot</html>'), [])
  eq('an empty array document', WM.parseGeocodingResults('[]'), [])
  eq('no argument at all', WM.parseGeocodingResults(), [])
})

group('locationCommit picks a suggestion or falls back to a name-only record', () => {
  const suggestions = [{ name: 'A', latitude: 1, longitude: 2 }, { name: 'B', latitude: 3, longitude: 4 }]
  eq('an empty text commits nothing', WM.locationCommit('', suggestions, 0), { name: '', latitude: null, longitude: null })
  eq('a whitespace-only text commits nothing', WM.locationCommit('   ', suggestions, 0), { name: '', latitude: null, longitude: null })
  eq('nullish text commits nothing', WM.locationCommit(null, suggestions, 0), { name: '', latitude: null, longitude: null })
  eq('the selected suggestion is stored verbatim', WM.locationCommit('Berlin', suggestions, 0), suggestions[0])
  eq('index 1 selects the second', WM.locationCommit('Berlin', suggestions, 1), suggestions[1])
  eq('an out-of-range index clamps to the last', WM.locationCommit('Berlin', suggestions, 9), suggestions[1])
  eq('a negative index clamps to the first', WM.locationCommit('Berlin', suggestions, -3), suggestions[0])
  eq('a non-numeric index is the first', WM.locationCommit('Berlin', suggestions, 'junk'), suggestions[0])
  eq('no index is the first', WM.locationCommit('Berlin', suggestions), suggestions[0])
  eq('a numeric string index works', WM.locationCommit('Berlin', suggestions, '1'), suggestions[1])
  // No suggestion selected: the name is kept and the coordinates are cleared,
  // which sends the fetches down the IP auto-detect path.
  eq('with no suggestions the typed name is kept', WM.locationCommit('Berlin', [], 0), { name: 'Berlin', latitude: null, longitude: null })
  eq('and it is trimmed', WM.locationCommit('  Berlin  ', [], 0), { name: 'Berlin', latitude: null, longitude: null })
  eq('with no suggestion list at all', WM.locationCommit('Berlin', null, 0), { name: 'Berlin', latitude: null, longitude: null })
  eq('no arguments at all', WM.locationCommit(), { name: '', latitude: null, longitude: null })
  is('the selected suggestion is returned, not copied', WM.locationCommit('Berlin', suggestions, 0), (v) => v === suggestions[0], 'same reference')
})

section('weather/Model - dates and temperatures')

group('isFutureForecastDate is a plain string comparison of the first ten characters', () => {
  eq('tomorrow', WM.isFutureForecastDate('2026-01-02', '2026-01-01'), true)
  eq('today is not future', WM.isFutureForecastDate('2026-01-01', '2026-01-01'), false)
  eq('yesterday', WM.isFutureForecastDate('2025-12-31', '2026-01-01'), false)
  eq('a missing date is not future', WM.isFutureForecastDate('', '2026-01-01'), false)
  eq('nullish is not future', WM.isFutureForecastDate(null, '2026-01-01'), false)
  eq('a datetime stamp is sliced to the date', WM.isFutureForecastDate('2026-01-02T12:00', '2026-01-01'), true)
  // With no todayString the comparison is against "", which every date beats.
  eq('no todayString makes any date future', WM.isFutureForecastDate('2026-01-01', undefined), true)
  eq('and two stamps compare on their dates', WM.isFutureForecastDate('2026-01-01T12:00', '2026-01-01T06:00'), false)
  // The fixed-width ISO shape is what makes the string comparison valid: it
  // is the caller's contract to pass "yyyy-MM-dd".
  is('the fixed-width shape sorts chronologically', ['2026-01-02', '2026-02-01', '2026-12-31', '2027-01-01'],
    (v) => [...v].sort()[0] === v[0] && v.every(d => d.length === 10), 'lexicographic order is chronological')
})

group('roundedTemp rounds and refuses to invent a number', () => {
  eq('an integer', WM.roundedTemp(21), '21')
  eq('it returns text, not a number, so a binding renders it directly', typeof WM.roundedTemp(21), 'string')
  eq('down below the half', WM.roundedTemp(20.4), '20')
  eq('up at the half', WM.roundedTemp(20.5), '21')
  eq('a string is parsed', WM.roundedTemp('21.6'), '22')
  eq('zero is a value', WM.roundedTemp(0), '0')
  eq('a negative rounds toward zero', WM.roundedTemp(-1.5), '-1')
  // Math.round(-0.5) is -0, and String(-0) is "0" - no "-0°" ever renders.
  eq('negative zero reads as 0', WM.roundedTemp(-0.5), '0')
  eq('a value just under the half', WM.roundedTemp(0.4999), '0')
  eq('undefined', WM.roundedTemp(undefined), '')
  eq('null', WM.roundedTemp(null), '')
  eq('an empty string', WM.roundedTemp(''), '')
  eq('unparseable text', WM.roundedTemp('x'), '')
  eq('the text "NaN"', WM.roundedTemp('NaN'), '')
  eq('a boolean is not a number here', WM.roundedTemp(true), '')
  eq('no argument at all', WM.roundedTemp(), '')
})

group('celsiusToFahrenheit and its inverse', () => {
  eq('freezing', WM.celsiusToFahrenheit(0), 32)
  eq('boiling', WM.celsiusToFahrenheit(100), 212)
  eq('the one temperature that is its own negative', WM.celsiusToFahrenheit(-40), -40)
  eq('a string is parsed', WM.celsiusToFahrenheit('20'), 68)
  is('it returns a number, not text, so the caller rounds it', WM.celsiusToFahrenheit(20), (v) => typeof v === 'number', 'number')
  approx('room temperature', WM.celsiusToFahrenheit(21.5), 70.7)
  approx('a negative value', WM.celsiusToFahrenheit(-3.4), 25.9, 0.05)
  eq('undefined', WM.celsiusToFahrenheit(undefined), '')
  eq('null', WM.celsiusToFahrenheit(null), '')
  eq('an empty string', WM.celsiusToFahrenheit(''), '')
  eq('unparseable text', WM.celsiusToFahrenheit('x'), '')
  // The inverse of this function is the same linear law, so a round trip
  // through it is asserted with approx rather than exactly.
  for (const c of [-40, -18, 0, 7, 21.5, 30, 100]) {
    const f = WM.celsiusToFahrenheit(c)
    approx(`${c}°C -> °F -> °C`, (f - 32) * 5 / 9, c, 1e-9)
  }
  approx('0°C and 32°F are the same point', WM.celsiusToFahrenheit(0) - 32, 0)
  eq('-40 is the fixed point of the law', WM.celsiusToFahrenheit(-40), -40)
})

group('formatTemp appends the unit, and does not check the value is a number', () => {
  eq('metric', WM.formatTemp(20, false), '20°C')
  eq('imperial', WM.formatTemp(20, true), '20°F')
  eq('text is passed through', WM.formatTemp('20', false), '20°C')
  eq('a rounded string works too', WM.formatTemp('-3', true), '-3°F')
  eq('zero is a value', WM.formatTemp(0, false), '0°C')
  eq('undefined', WM.formatTemp(undefined, false), '')
  eq('null', WM.formatTemp(null, false), '')
  eq('an empty string', WM.formatTemp('', false), '')
  // No numeric check, so a truthy non-number renders verbatim. Pinned so a
  // future numeric guard is a visible diff rather than a surprise.
  eq('a boolean renders as text', WM.formatTemp(true, false), 'true°C')
  eq('a missing unit argument is metric', WM.formatTemp(20), '20°C')
})

section('weather/Model - unit policy')

group('normalizedUnit trims and lowercases the override', () => {
  eq('padded and upper case', WM.normalizedUnit(' Auto '), 'auto')
  eq('imperial', WM.normalizedUnit('IMPERIAL'), 'imperial')
  eq('metric', WM.normalizedUnit(' metric '), 'metric')
  eq('empty', WM.normalizedUnit(''), '')
  eq('nullish', WM.normalizedUnit(null), '')
  eq('undefined', WM.normalizedUnit(undefined), '')
  eq('no argument', WM.normalizedUnit(), '')
})

group('localeUsesImperial matches the three imperial locales', () => {
  eq('en_US', WM.localeUsesImperial('en_US'), true)
  eq('en-US', WM.localeUsesImperial('en-US'), true)
  eq('en_US.UTF-8', WM.localeUsesImperial('en_US.UTF-8'), true)
  eq('en_US.UTF-8 with the dot replaced once', WM.localeUsesImperial('en_US.UTF-8'), true)
  eq('en_LR', WM.localeUsesImperial('en_LR'), true)
  eq('my_MM', WM.localeUsesImperial('my_MM'), true)
  eq('bare my', WM.localeUsesImperial('my'), true)
  eq('en_GB is metric', WM.localeUsesImperial('en_GB'), false)
  eq('fr_FR is metric', WM.localeUsesImperial('fr_FR'), false)
  eq('de_DE.ISO8859-1 is metric', WM.localeUsesImperial('de_DE.ISO8859-1'), false)
  // The region is required, so a bare language is not a locale answer.
  eq('bare en is not an answer', WM.localeUsesImperial('en'), false)
  eq('an empty locale', WM.localeUsesImperial(''), false)
  eq('nullish', WM.localeUsesImperial(null), false)
  eq('undefined', WM.localeUsesImperial(undefined), false)
  eq('no argument', WM.localeUsesImperial(), false)
  // No case folding: the pattern is matched against the name as given, so a
  // hand-written "EN_us" is read as metric. QLocale always yields lower case,
  // but the asymmetry with countryUsesImperial, which folds, is pinned.
  eq('an upper-case locale name is read as metric', WM.localeUsesImperial('EN_us'), false)
  eq('a mixed-case region is too', WM.localeUsesImperial('en_Us'), false)
  // The region in the pattern is upper case, so only the canonical
  // QLocale spelling matches; a hand-written "en_us" reads as metric.
  eq('a lower-case region does not match', WM.localeUsesImperial('en_us'), false)
  eq('and a trailing separator without a region does not either', WM.localeUsesImperial('en_'), false)
})

group('countryUsesImperial is a closed table with a known-missing answer', () => {
  eq('US', WM.countryUsesImperial('US'), true)
  eq('usa', WM.countryUsesImperial('usa'), true)
  eq('United States', WM.countryUsesImperial('United States'), true)
  eq('the long form', WM.countryUsesImperial('united states of america'), true)
  eq('Liberia', WM.countryUsesImperial('Liberia'), true)
  eq('Myanmar', WM.countryUsesImperial('Myanmar'), true)
  eq('Burma, the old name', WM.countryUsesImperial('Burma'), true)
  eq('case and padding are folded', WM.countryUsesImperial('  uSa  '), true)
  eq('France is a known metric country', WM.countryUsesImperial('France'), false)
  eq('Germany', WM.countryUsesImperial('Germany'), false)
  // An unknown country is null, not false: "I have no opinion" is what lets
  // the locale answer.
  eq('an unknown country', WM.countryUsesImperial('Wakanda'), false)
  eq('an empty country has no opinion at all', WM.countryUsesImperial(''), null)
  eq('a whitespace country', WM.countryUsesImperial('   '), null)
  eq('nullish', WM.countryUsesImperial(null), null)
  eq('undefined', WM.countryUsesImperial(undefined), null)
  // Punctuation is normalised to spaces, so the dotted spellings of the
  // table's own entries no longer match it. Pinned: a provider that reports
  // "U.S.A." would send a US user to metric.
  eq('"U.S.A." is read as metric', WM.countryUsesImperial('U.S.A.'), false)
  eq('"US.A" is read as metric', WM.countryUsesImperial('US.A'), false)
  eq('a hyphenated spelling is normalised to spaces and still matches', WM.countryUsesImperial('United-States'), true)
  eq('so is an underscored one', WM.countryUsesImperial('united_states'), true)
  eq('a dotted multi-word spelling still normalises to the table entry', WM.countryUsesImperial('United.States'), true)
  eq('and the dotted Burma is too', WM.countryUsesImperial('Bur.ma'), false)
})

group('shouldUseImperial: override, then country, then locale', () => {
  eq('an imperial override beats a metric locale', WM.shouldUseImperial('imperial', 'en_GB', 'Germany'), true)
  eq('an override is matched case-insensitively', WM.shouldUseImperial('IMPERIAL', 'en_GB', 'DE'), true)
  eq('a metric override beats an imperial country', WM.shouldUseImperial('metric', 'en_US', 'US'), false)
  eq('"auto" is not an override, so the country answers', WM.shouldUseImperial('auto', 'en_GB', 'US'), true)
  eq('an unrecognised override is not an override either', WM.shouldUseImperial('kelvin', 'en_GB', 'US'), true)
  eq('a known metric country beats an imperial locale', WM.shouldUseImperial(undefined, 'en_US', 'Germany'), false)
  eq('a known imperial country beats a metric locale', WM.shouldUseImperial(undefined, 'en_GB', 'US'), true)
  eq('with no country the locale answers', WM.shouldUseImperial(undefined, 'en_US', undefined), true)
  eq('with neither, metric is the answer', WM.shouldUseImperial(undefined, 'de_DE', undefined), false)
  eq('empty strings all round', WM.shouldUseImperial('', '', ''), false)
  eq('nullish override, imperial locale', WM.shouldUseImperial(null, 'my_MM', null), true)
  // The precedence is total: for every combination the winner is the first
  // non-null answer in the documented order.
  is('the override wins whenever it is a real unit',
    [[true, 'en_US', 'US'], [true, 'de_DE', 'FR'], [true, null, null]], (v) => v.every(() => WM.shouldUseImperial('imperial', 'en_US', 'US') === true),
    'imperial override is authoritative')
})

section('weather/Model - Open-Meteo, the primary source')

group('openMeteoForecastDays normalises the daily series and skips today', () => {
  const days = WM.openMeteoForecastDays(OM, '2026-01-01')
  eq('today is not a forecast row', days.map(d => d.date), ['2026-01-02', '2026-01-03'])
  eq('the first row in full', days[0], {
    date: '2026-01-02', maxtempC: '2', mintempC: '-4', maxtempF: '36', mintempF: '24',
    feelsC: '-1', feelsF: '30', precipProb: '55', windKmph: '20', windMph: '12',
    humidity: '80', openMeteoWeatherCode: 61,
  })
  eq('the row shape', Object.keys(days[0]), ['date', 'maxtempC', 'mintempC', 'maxtempF', 'mintempF', 'feelsC', 'feelsF', 'precipProb', 'windKmph', 'windMph', 'humidity', 'openMeteoWeatherCode'])
  // The second day has no hourly entries, so its humidity is empty and the
  // verbose line simply omits the field.
  eq('a day with no hourly series has no humidity', days[1].humidity, '')
  eq('a 0 percent chance is a value, not a gap',
    WM.openMeteoForecastDays({ daily: { time: ['2026-01-02'], precipitation_probability_max: [0] } }, '2026-01-01')[0].precipProb, '0')
  eq('and a 0 km/h wind is a value too',
    WM.openMeteoForecastDays({ daily: { time: ['2026-01-02'], wind_speed_10m_max: [0] } }, '2026-01-01')[0].windKmph, '0')
  eq('the whole series is available when nothing is today', WM.openMeteoForecastDays(OM, '2025-12-31').length, 3)
  eq('nothing is future when today is the last day', WM.openMeteoForecastDays(OM, '2026-01-03'), [])
})

group('the count is honoured and defaults sanely', () => {
  eq('one', WM.openMeteoForecastDays(OM, '2026-01-01', 1).map(d => d.date), ['2026-01-02'])
  eq('two, all of them', WM.openMeteoForecastDays(OM, '2026-01-01', 2).length, 2)
  eq('more than the series has', WM.openMeteoForecastDays(OM, '2026-01-01', 99).length, 2)
  eq('zero defaults to seven', WM.openMeteoForecastDays(OM, '2026-01-01', 0).length, 2)
  eq('a negative count defaults to seven', WM.openMeteoForecastDays(OM, '2026-01-01', -3).length, 2)
  eq('unparseable defaults to seven', WM.openMeteoForecastDays(OM, '2026-01-01', 'x').length, 2)
  eq('no count at all defaults to seven', WM.openMeteoForecastDays(OM, '2026-01-01').length, 2)
  eq('a count is parsed from text', WM.openMeteoForecastDays(OM, '2026-01-01', '1').length, 1)
  // A daily series the provider did not send is no rows, not a crash.
  eq('no daily block', WM.openMeteoForecastDays({}, '2026-01-01'), [])
  eq('a null report', WM.openMeteoForecastDays(null, '2026-01-01'), [])
  eq('a daily block with no time array', WM.openMeteoForecastDays({ daily: {} }, '2026-01-01'), [])
  eq('an empty time array', WM.openMeteoForecastDays({ daily: { time: [] } }, '2026-01-01'), [])
  eq('a time array with no temperature arrays still yields rows', WM.openMeteoForecastDays({ daily: { time: ['2026-01-02'] } }, '2026-01-01'),
    [{ date: '2026-01-02', maxtempC: '', mintempC: '', maxtempF: '', mintempF: '', feelsC: '', feelsF: '', precipProb: '', windKmph: '', windMph: '', humidity: '', openMeteoWeatherCode: null }])
  eq('a missing weather code is null, not undefined', WM.openMeteoForecastDays({ daily: { time: ['2026-01-02'] } }, '2026-01-01')[0].openMeteoWeatherCode, null)
})

group('kmhToMph is the provider\'s own conversion factor', () => {
  approx('100 km/h', WM.kmhToMph(100), 62.1371, 1e-4)
  approx('a string', WM.kmhToMph('20'), 12.42742, 1e-5)
  eq('zero', WM.kmhToMph(0), 0)
  eq('undefined', WM.kmhToMph(undefined), '')
  eq('null', WM.kmhToMph(null), '')
  eq('an empty string', WM.kmhToMph(''), '')
  eq('unparseable text', WM.kmhToMph('x'), '')
  eq('a boolean', WM.kmhToMph(true), '')
  is('it is the same factor the forecast uses', (WM.kmhToMph(20) / 20) === (WM.kmhToMph(100) / 100), (v) => v === true, 'one constant')
})

group('humidityMaxForDate peaks the hourly series for one date', () => {
  eq('the peak of the first day', WM.humidityMaxForDate(OM.hourly, '2026-01-01'), '95')
  eq('the peak of the second day', WM.humidityMaxForDate(OM.hourly, '2026-01-02'), '80')
  eq('a day with no hours is empty', WM.humidityMaxForDate(OM.hourly, '2026-01-03'), '')
  eq('the result is text, like every other normalised value', typeof WM.humidityMaxForDate(OM.hourly, '2026-01-01'), 'string')
  eq('a datetime stamp is sliced to its date', WM.humidityMaxForDate(OM.hourly, '2026-01-01T12:00'), '95')
  // A verbose row omits humidity rather than showing a wrong number, so the
  // absent series is "" and not 0.
  eq('no hourly series at all', WM.humidityMaxForDate(null, '2026-01-01'), '')
  eq('no hourly block', WM.humidityMaxForDate({}, '2026-01-01'), '')
  eq('a series with no humidity array', WM.humidityMaxForDate({ time: ['2026-01-01T00:00'] }, '2026-01-01'), '')
  eq('a series with no time array', WM.humidityMaxForDate({ relative_humidity_2m: [50] }, '2026-01-01'), '')
  eq('unparseable values are ignored, not zeroed', WM.humidityMaxForDate({ time: ['2026-01-01T00:00'], relative_humidity_2m: ['x'] }, '2026-01-01'), '')
  eq('a good value beside a bad one still peaks', WM.humidityMaxForDate({ time: ['2026-01-01T00:00', '2026-01-01T01:00'], relative_humidity_2m: ['x', '42.6'] }, '2026-01-01'), '43')
  eq('no date at all', WM.humidityMaxForDate(OM.hourly, ''), '')
  eq('a nullish date', WM.humidityMaxForDate(OM.hourly, null), '')
  eq('crossing midnight does not mix the days', WM.humidityMaxForDate({
    time: ['2026-01-01T23:00', '2026-01-02T00:00'],
    relative_humidity_2m: ['10', '90'],
  }, '2026-01-01'), '10')
})

group('openMeteoHourlyForecast starts at the next hour and crosses midnight', () => {
  // The stamps are wall time in the response's own timezone, so they are
  // anchored at UTC and the offset subtracted to recover a true epoch. The
  // suite passes nowUtcMs explicitly, which is the determinism contract.
  const rows = WM.openMeteoHourlyForecast(OM, Date.parse('2026-01-01T11:00:00Z'), 4)
  eq('every future entry up to the count', rows.length, 4)
  eq('the first row in full', rows[0], {
    time: '2026-01-01T12:00', hour: 12, tempC: '-1', tempF: '30',
    precipProb: '5', isDay: true, openMeteoWeatherCode: 0,
  })
  eq('labels repeat across midnight rather than resetting', rows.map(r => r.hour), [12, 18, 0, 6])
  eq('the stamps stay in the response\'s wall time', rows.map(r => r.time), ['2026-01-01T12:00', '2026-01-01T18:00', '2026-01-02T00:00', '2026-01-02T06:00'])
  eq('is_day 0 is night', rows[2].isDay, false)
  eq('is_day 1 is day', rows[0].isDay, true)
  // An entry exactly at now is included: the filter is "before now", so the
  // current hour still renders.
  eq('the entry at exactly now is included', WM.openMeteoHourlyForecast(OM, Date.parse('2026-01-01T11:00:00Z'), 1).map(r => r.time), ['2026-01-01T12:00'])
  eq('an entry one second past now is included', WM.openMeteoHourlyForecast(OM, Date.parse('2026-01-01T10:59:59Z'), 1).map(r => r.time), ['2026-01-01T12:00'])
  eq('nothing in the future is no rows', WM.openMeteoHourlyForecast(OM, Date.parse('2030-01-01T00:00:00Z'), 3), [])
  eq('a past window skips to nothing here', WM.openMeteoHourlyForecast(OM, Date.parse('2026-01-01T19:00:00Z'), 4).map(r => r.time), ['2026-01-02T00:00', '2026-01-02T06:00'])
  eq('the count is honoured', WM.openMeteoHourlyForecast(OM, 0, 2).length, 2)
  eq('a zero count defaults to eight', WM.openMeteoHourlyForecast(OM, 0, 0).length, 4)
  eq('an unparseable count defaults to eight', WM.openMeteoHourlyForecast(OM, 0, 'x').length, 4)
  eq('no count defaults to eight', WM.openMeteoHourlyForecast(OM, 0).length, 4)
  eq('an absent hourly series is no rows (the island hides the row)', WM.openMeteoHourlyForecast({}, 0, 3), [])
  eq('a null report', WM.openMeteoHourlyForecast(null, 0, 3), [])
  eq('a series with no temperature array', WM.openMeteoHourlyForecast({ hourly: { time: ['2026-01-01T00:00'] } }, 0, 3), [])
  eq('a missing utc offset is treated as zero', WM.openMeteoHourlyForecast({ hourly: OM.hourly }, 0, 1).map(r => r.time), ['2026-01-01T12:00'])
  eq('an absent is_day is day', WM.openMeteoHourlyForecast({ hourly: { time: ['2026-01-01T00:00'], temperature_2m: [1] } }, 0, 1)[0].isDay, true)
  // The step walks the series instead of packing entries against the front
  // of the window: the island asks for a two-hour cadence, so every other
  // hour is what lands in the strip. OM's own series is 6-hourly, so the
  // cases that pin a 2-hour cadence use a 1-hourly one.
  const hourly1h = {
    hourly: {
      time: ['2026-01-01T12:00', '2026-01-01T13:00', '2026-01-01T14:00',
        '2026-01-01T15:00', '2026-01-01T16:00', '2026-01-01T17:00'],
      temperature_2m: [1, 2, 3, 4, 5, 6],
    },
  }
  eq('a step of two takes every other hour', WM.openMeteoHourlyForecast(hourly1h, 0, 4, 2).map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T14:00', '2026-01-01T16:00'])
  eq('the values ride their own entry, not the skipped one',
    WM.openMeteoHourlyForecast(hourly1h, 0, 4, 2).map(r => r.tempC), ['1', '3', '5'])
  eq('a step of one is every hour', WM.openMeteoHourlyForecast(hourly1h, 0, 3, 1).map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T13:00', '2026-01-01T14:00'])
  eq('a step of three takes every third hour', WM.openMeteoHourlyForecast(hourly1h, 0, 2, 3).map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T15:00'])
  // The step is applied to what the window leaves, not to the raw series:
  // an hour already in the past is not a step to skip.
  eq('the step is applied after the now filter',
    WM.openMeteoHourlyForecast(hourly1h, Date.parse('2026-01-01T13:30:00Z'), 2, 2).map(r => r.time),
    ['2026-01-01T14:00', '2026-01-01T16:00'])
  eq('a zero step is every hour', WM.openMeteoHourlyForecast(OM, 0, 2, 0).map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T18:00'])
  eq('an unparseable step is every hour', WM.openMeteoHourlyForecast(OM, 0, 2, 'x').map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T18:00'])
  eq('no step is every hour', WM.openMeteoHourlyForecast(OM, 0, 2).map(r => r.time),
    ['2026-01-01T12:00', '2026-01-01T18:00'])
  eq('a step wider than the series still yields the first entry',
    WM.openMeteoHourlyForecast(OM, 0, 3, 99).map(r => r.time), ['2026-01-01T12:00'])
  // Date.parse is lenient rather than strict, so a junk stamp does not come
  // back NaN - it resolves to 2000-01-01 and is filtered by the comparison
  // against nowUtcMs rather than by the isNaN guard.
  eq('a junk stamp is filtered by the now comparison', WM.openMeteoHourlyForecast({ hourly: { time: ['x'], temperature_2m: [1] } }, Date.parse('2026-01-01T00:00:00Z'), 3), [])
  eq('a nullish stamp likewise', WM.openMeteoHourlyForecast({ hourly: { time: [null], temperature_2m: [1] } }, Date.parse('2026-01-01T00:00:00Z'), 3), [])
  eq('but with a now before 2000 the lenient parse does surface a row',
    WM.openMeteoHourlyForecast({ hourly: { time: ['x'], temperature_2m: [1] } }, 0, 1).map(r => r.time), ['x'])
})

group('openMeteoCurrentCondition reshapes metric into wttr\'s shape', () => {
  const cur = WM.openMeteoCurrentCondition(OM)
  eq('the full normalised condition', cur, {
    temp_C: '-3', temp_F: '26', FeelsLikeC: '-8', FeelsLikeF: '18',
    windspeedKmph: '23', windspeedMiles: '14', humidity: '81',
    pressure: '1013', cloudcover: '40', precipMM: '0.4',
    openMeteoWeatherCode: 71, isDay: 0,
  })
  eq('the shape matches a wttr current_condition so the island can use either source', Object.keys(cur),
    ['temp_C', 'temp_F', 'FeelsLikeC', 'FeelsLikeF', 'windspeedKmph', 'windspeedMiles', 'humidity', 'pressure', 'cloudcover', 'precipMM', 'openMeteoWeatherCode', 'isDay'])
  // 0 is a temperature, not a missing one: the guard is an explicit
  // undefined/null check, not a truthiness test.
  eq('zero degrees is a condition, not a missing one', WM.openMeteoCurrentCondition({ current: { temperature_2m: 0 } }),
    { temp_C: '0', temp_F: '32', FeelsLikeC: '', FeelsLikeF: '', windspeedKmph: '', windspeedMiles: '', humidity: '', pressure: '', cloudcover: '', precipMM: '', openMeteoWeatherCode: undefined, isDay: undefined })
  eq('no current block is null', WM.openMeteoCurrentCondition({}), null)
  eq('a null report is null', WM.openMeteoCurrentCondition(null), null)
  eq('a current block with no temperature is null', WM.openMeteoCurrentCondition({ current: {} }), null)
  eq('a null temperature is null', WM.openMeteoCurrentCondition({ current: { temperature_2m: null } }), null)
  eq('an unparseable temperature still yields a condition with empty fields', WM.openMeteoCurrentCondition({ current: { temperature_2m: 'x' } }).temp_C, '')
  // The second hero row rides the same block: a payload that omits these
  // reads empty rather than "undefined" or 0, which is what the island's
  // collapse guard and the service's unit suffixing test for.
  eq('an omitted pressure is empty, not 0', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1 } }).pressure, '')
  eq('an omitted cloud cover is empty', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1 } }).cloudcover, '')
  eq('an omitted precipitation is empty', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1 } }).precipMM, '')
  eq('zero pressure is a reading, not a missing one', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1, pressure_msl: 0 } }).pressure, '0')
  eq('zero cloud cover is a reading', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1, cloud_cover: 0 } }).cloudcover, '0')
  // Precipitation keeps its decimal: 0.4mm rounding to "0" would report a
  // drizzle as no rain at all.
  eq('sub-millimetre rain survives the rounding', WM.openMeteoCurrentCondition({ current: { temperature_2m: 1, precipitation: 0.4 } }).precipMM, '0.4')
})

group('pressure and precipitation convert to imperial for the second hero row', () => {
  eq('1013 hPa is 29.91 inHg', WM.hpaToInHg(1013), '29.91')
  eq('1013.4 hPa rounds to 29.93 inHg', WM.hpaToInHg('1013.4'), '29.93')
  eq('an absent pressure converts to nothing', WM.hpaToInHg(''), '')
  eq('a null pressure converts to nothing', WM.hpaToInHg(null), '')
  eq('an unparseable pressure converts to nothing', WM.hpaToInHg('x'), '')
  eq('25.4 mm is one inch', WM.mmToInches(25.4), '1')
  eq('0.4 mm is 0.02 in', WM.mmToInches(0.4), '0.02')
  eq('an absent amount converts to nothing', WM.mmToInches(''), '')
  eq('a null amount converts to nothing', WM.mmToInches(null), '')
  eq('an unparseable amount converts to nothing', WM.mmToInches('x'), '')
  eq('one decimal keeps a tenth', WM.oneDecimal('0.44'), '0.4')
  eq('one decimal rounds a tenth up', WM.oneDecimal('0.45'), '0.5')
  eq('an absent value is empty', WM.oneDecimal(''), '')
  eq('a null value is empty', WM.oneDecimal(null), '')
  eq('an unparseable value is empty', WM.oneDecimal('x'), '')
})

section('weather/Model - icons')

group('currentIcon prefers the day/night-aware Open-Meteo code', () => {
  eq('a code and isDay 0', WM.currentIcon({ openMeteoWeatherCode: 0, isDay: 0 }, 'fb'), 'weather-clear-night')
  eq('a code and isDay 1', WM.currentIcon({ openMeteoWeatherCode: 0, isDay: 1 }, 'fb'), 'weather-clear-day')
  eq('isDay as text still reads as a flag', WM.currentIcon({ openMeteoWeatherCode: 0, isDay: '0' }, 'fb'), 'weather-clear-night')
  eq('isDay false is night', WM.currentIcon({ openMeteoWeatherCode: 0, isDay: false }, 'fb'), 'weather-clear-night')
  // A missing flag is not night: Number(undefined) is NaN, so the day
  // variant is used and an evening hour shows a sun.
  eq('a missing isDay is day', WM.currentIcon({ openMeteoWeatherCode: 0 }, 'fb'), 'weather-clear-day')
  eq('snow by code', WM.currentIcon({ openMeteoWeatherCode: 71, isDay: 1 }, 'fb'), 'weather-snow')
  eq('snow has no night variant', WM.currentIcon({ openMeteoWeatherCode: 71, isDay: 0 }, 'fb'), 'weather-snow')
  eq('the normalized condition from Open-Meteo', WM.currentIcon(WM.openMeteoCurrentCondition(OM), 'fb'), 'weather-snow')
})

group('a raw Open-Meteo response has no icon yet', () => {
  // The raw response spells it weather_code; only the normalized condition
  // carries openMeteoWeatherCode. Handing the raw block here falls through
  // to the fallback, which is why the service normalizes first.
  eq('a raw current block is the fallback', WM.currentIcon(OM.current, 'fb'), 'fb')
  eq('and with no fallback it is an empty icon', WM.currentIcon(OM.current), '')
})

group('a wttr code is used without a day/night flag', () => {
  // wttr.in has no day/night flag, so this branch always picks the day
  // variant - the asymmetry provisionalCurrentIcon exists to contain.
  eq('a clear wttr code', WM.currentIcon({ weatherCode: '113' }, 'fb'), 'weather-clear-day')
  eq('a numeric wttr code', WM.currentIcon({ weatherCode: 116 }, 'fb'), 'weather-partly-cloudy-day')
  eq('even with isDay 0', WM.currentIcon({ weatherCode: 113, isDay: 0 }, 'fb'), 'weather-clear-day')
  eq('no code at all is the fallback', WM.currentIcon({}, 'fb'), 'fb')
  eq('a null code is the fallback', WM.currentIcon({ openMeteoWeatherCode: null, weatherCode: null }, 'fb'), 'fb')
  eq('no condition is the fallback', WM.currentIcon(null, 'fb'), 'fb')
  eq('no condition and no fallback is an empty string', WM.currentIcon(null), '')
  eq('an empty condition and no fallback', WM.currentIcon({}), '')
  eq('the Open-Meteo code wins when both are present', WM.currentIcon({ openMeteoWeatherCode: 95, weatherCode: 113 }, 'fb'), 'weather-thunderstorm')
})

group('provisionalCurrentIcon only fills an empty state', () => {
  eq('a resolved icon is never replaced', WM.provisionalCurrentIcon({ weatherCode: 113 }, 'weather-clear-night'), 'weather-clear-night')
  eq('an empty resolved state is filled from wttr', WM.provisionalCurrentIcon({ weatherCode: 113 }, ''), 'weather-clear-day')
  eq('a resolved day/night-aware icon survives a wttr block', WM.provisionalCurrentIcon({ openMeteoWeatherCode: 0, isDay: 0 }, 'weather-clear-night'), 'weather-clear-night')
  eq('nothing to fill from is an empty string', WM.provisionalCurrentIcon({}, ''), '')
  eq('no condition at all', WM.provisionalCurrentIcon(null, ''), '')
  eq('a resolved icon with no condition', WM.provisionalCurrentIcon(null, 'weather-overcast'), 'weather-overcast')
})

group('the WMO mapping covers every documented group, day and night', () => {
  const day = (c) => WM.iconForWmoCode(c, false)
  const night = (c) => WM.iconForWmoCode(c, true)
  eq('0 clear', [day(0), night(0)], ['weather-clear-day', 'weather-clear-night'])
  eq('1 mainly clear', [day(1), night(1)], ['weather-partly-cloudy-day', 'weather-partly-cloudy-night'])
  eq('2 partly cloudy', [day(2), night(2)], ['weather-partly-cloudy-day', 'weather-partly-cloudy-night'])
  eq('3 overcast has no night variant', [day(3), night(3)], ['weather-overcast', 'weather-overcast'])
  eq('45 fog', [day(45), night(45)], ['weather-fog-day', 'weather-fog-night'])
  eq('48 depositing rime fog', [day(48), night(48)], ['weather-fog-day', 'weather-fog-night'])
  eq('51-57 drizzle', [51, 53, 55, 56, 57].map(day), ['weather-drizzle', 'weather-drizzle', 'weather-drizzle', 'weather-drizzle', 'weather-drizzle'])
  eq('61-67 rain', [61, 63, 65, 66, 67].map(day), ['weather-rain', 'weather-rain', 'weather-rain', 'weather-rain', 'weather-rain'])
  eq('80-82 rain showers share the rain glyph', [80, 81, 82].map(day), ['weather-rain', 'weather-rain', 'weather-rain'])
  eq('71-77 snow', [71, 73, 75, 77].map(day), ['weather-snow', 'weather-snow', 'weather-snow', 'weather-snow'])
  eq('85-86 snow showers share the snow glyph', [85, 86].map(day), ['weather-snow', 'weather-snow'])
  eq('95-99 thunderstorm', [95, 96, 99].map(day), ['weather-thunderstorm', 'weather-thunderstorm', 'weather-thunderstorm'])
  // Unknown codes fall back to overcast rather than an empty box.
  eq('an unassigned code', day(4), 'weather-overcast')
  eq('a code above the table', day(100), 'weather-overcast')
  eq('a negative code', day(-1), 'weather-overcast')
  eq('null', WM.iconForWmoCode(null, false), 'weather-overcast')
  eq('undefined', WM.iconForWmoCode(undefined, false), 'weather-overcast')
  eq('an empty string', WM.iconForWmoCode('', false), 'weather-overcast')
  eq('unparseable text', WM.iconForWmoCode('x', false), 'weather-overcast')
  eq('a numeric prefix is taken', WM.iconForWmoCode('0', true), 'weather-clear-night')
  eq('a code as text works', WM.iconForWmoCode('61', false), 'weather-rain')
  eq('a fractional code truncates', WM.iconForWmoCode(3.7, false), 'weather-overcast')
  // Every code in a wide sweep is answered, day or night.
  is('no code in 0..99 is unanswered', Array.from({ length: 100 }, (_, c) => [WM.iconForWmoCode(c, false), WM.iconForWmoCode(c, true)]),
    (v) => v.every(pair => pair.every(s => typeof s === 'string' && s.startsWith('weather-'))), 'an icon for every code')
})

group('the wttr mapping mirrors the same icon set', () => {
  const day = (c) => WM.iconForCode(c, false)
  const night = (c) => WM.iconForCode(c, true)
  eq('113 clear', [day(113), night(113)], ['weather-clear-day', 'weather-clear-night'])
  eq('116 partly cloudy', [day(116), night(116)], ['weather-partly-cloudy-day', 'weather-partly-cloudy-night'])
  eq('119/122 cloudy', [day(119), day(122)], ['weather-overcast', 'weather-overcast'])
  eq('143/248/260 mist', [143, 248, 260].map(night), ['weather-fog-night', 'weather-fog-night', 'weather-fog-night'])
  eq('176/263/353 patchy rain', [176, 263, 353].map(day), ['weather-showers-day', 'weather-showers-day', 'weather-showers-day'])
  eq('179/227/230/323/326/368 snow showers', [179, 227, 230, 323, 326, 368].map(day),
    ['weather-snow-showers-day', 'weather-snow-showers-day', 'weather-snow-showers-day', 'weather-snow-showers-day', 'weather-snow-showers-day', 'weather-snow-showers-day'])
  eq('and their night variants', night(179), 'weather-snow-showers-night')
  eq('the long sleet list', [182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377].map(day),
    new Array(13).fill('weather-sleet'))
  eq('thunderstorm', [200, 386, 389, 392, 395].map(day), new Array(5).fill('weather-thunderstorm'))
  eq('drizzle', [266, 293, 296, 299, 302, 305, 308, 356, 359].map(day), new Array(9).fill('weather-drizzle'))
  eq('snow', [329, 332, 335, 338, 371].map(day), new Array(5).fill('weather-snow'))
  eq('an unassigned code', day(999), 'weather-overcast')
  eq('null', WM.iconForCode(null, false), 'weather-overcast')
  eq('an empty string', WM.iconForCode('', false), 'weather-overcast')
  eq('unparseable text', WM.iconForCode('x', true), 'weather-overcast')
  eq('a numeric string works', WM.iconForCode('113', false), 'weather-clear-day')
  is('no code in 0..500 is unanswered', Array.from({ length: 500 }, (_, c) => WM.iconForCode(c, false)),
    (v) => v.every(s => typeof s === 'string' && s.startsWith('weather-')), 'an icon for every code')
})

group('both mappers stay inside the declared icon set', () => {
  // The module ends with the REQUIRED ICON SET and notes that adding a
  // mapping means adding the asset. This is that contract, asserted - with
  // one correction: the WMO table returns weather-rain, which the comment's
  // fifteen-name list omits. The asset exists on disk, so nothing renders
  // broken; the list and its "(15 files" count are what are stale.
  const COMMENTED = [
    'weather-clear-day', 'weather-clear-night',
    'weather-partly-cloudy-day', 'weather-partly-cloudy-night',
    'weather-overcast',
    'weather-fog-day', 'weather-fog-night',
    'weather-drizzle',
    'weather-showers-day', 'weather-showers-night',
    'weather-snow-showers-day', 'weather-snow-showers-night',
    'weather-sleet', 'weather-thunderstorm', 'weather-snow',
  ]
  const RETURNED = COMMENTED.concat(['weather-rain'])
  const used = new Set()
  for (let c = 0; c <= 200; c++) {
    used.add(WM.iconForWmoCode(c, false))
    used.add(WM.iconForWmoCode(c, true))
    used.add(WM.iconForCode(c, false))
    used.add(WM.iconForCode(c, true))
  }
  eq('the comment lists fifteen names', COMMENTED.length, 15)
  is('no mapper returns a name outside the set plus weather-rain', [...used], (v) => v.every(s => RETURNED.includes(s)), 'subset of the known names')
  eq('and the sweep reaches exactly those sixteen', [...used].sort(), RETURNED.slice().sort())
  eq('weather-rain is the one name the comment omits', [...used].filter(s => !COMMENTED.includes(s)), ['weather-rain'])
  eq('and the WMO rain codes are the ones that return it', WM.iconForWmoCode(61, false), 'weather-rain')
  for (const name of COMMENTED) contains(`the source's icon-set comment lists ${name}`, WM_SRC, name)
  contains('and states the file count', WM_SRC, '(15 files;')
  contains('and names overcast as the unknown-code fallback', WM_SRC, 'weather-overcast doubles as the unknown-code fallback')
})

section('weather/Model - day and hour presentation')

group('dayName reads a date string through an injected formatter', () => {
  eq('the built-in weekday table', WM.dayName('2026-01-01'), 'Thursday')
  eq('a Sunday', WM.dayName('2026-01-04'), 'Sunday')
  eq('a Saturday', WM.dayName('2026-01-03'), 'Saturday')
  // The stamp is anchored at 12:00 so a date string never slips a day in a
  // timezone far from UTC - noon is on the same calendar day everywhere.
  eq('the injected formatter receives a real Date', WM.dayName('2026-01-01', (d) => typeof d.getTime()), 'number')
  eq('and whatever it returns is what dayName returns', WM.dayName('2026-01-01', () => 7), 7)
  eq('at noon local', WM.dayName('2026-03-29', (d) => String(d.getHours())), '12')
  eq('on the right day of the month', WM.dayName('2026-03-29', (d) => String(d.getDate())), '29')
  eq('the formatter may return anything', WM.dayName('2026-01-01', () => 'Thu'), 'Thu')
  eq('an empty date is an empty name', WM.dayName(''), '')
  eq('nullish is an empty name', WM.dayName(null), '')
  eq('an unparseable date is an empty name', WM.dayName('nope'), '')
  eq('an unparseable date never reaches the formatter', WM.dayName('nope', () => 'x'), '')
  eq('no date at all', WM.dayName(), '')
})

group('noonHourly picks the entry nearest 12:00', () => {
  eq('an exact noon entry', WM.noonHourly({ hourly: [{ time: '0' }, { time: '1200' }, { time: '2400' }] }).time, '1200')
  // The comparison is strict, so a tie keeps the earlier entry.
  eq('a tie keeps the earlier one', WM.noonHourly({ hourly: [{ time: '1100' }, { time: '1300' }] }).time, '1100')
  eq('midnight only', WM.noonHourly({ hourly: [{ time: '0' }] }).time, '0')
  eq('an hour with no time reads as 0 and is last', WM.noonHourly({ hourly: [{ time: '1200' }, { time: '' }] }).time, '1200')
  eq('an hour with no time at all', WM.noonHourly({ hourly: [{ time: '1200' }, {}] }).time, '1200')
  eq('no hourly series is null', WM.noonHourly({}), null)
  eq('an empty series is null', WM.noonHourly({ hourly: [] }), null)
  eq('a null day is null', WM.noonHourly(null), null)
  eq('no day at all is null', WM.noonHourly(), null)
})

group('enrichWttrDay attaches the verbose detail from the noon entry', () => {
  const day = WM.enrichWttrDay(WTTR.weather[0])
  eq('the enriched day', { feelsC: day.feelsC, feelsF: day.feelsF, precipProb: day.precipProb, windKmph: day.windKmph, windMph: day.windMph, humidity: day.humidity },
    { feelsC: '-1', feelsF: '30', precipProb: '20', windKmph: '9', windMph: '6', humidity: '70' })
  eq('the provider\'s own fields are untouched', [day.maxtempC, day.mintempC, day.date], ['1', '-5', '2026-01-01'])
  eq('a day with no hourly series gets empty details', (() => {
    const d = WM.enrichWttrDay({ date: 'x' })
    return [d.feelsC, d.feelsF, d.precipProb, d.windKmph, d.windMph, d.humidity]
  })(), ['', '', '', '', '', ''])
  // The day object is enriched in place and returned, so the caller's report
  // rows gain the fields. Pinned because "every function takes what it needs
  // and returns a value" reads as pure, and this one is not.
  is('the same object is returned, mutated', (() => {
    const input = { date: 'x', hourly: [{ time: '1200', humidity: '50' }] }
    return WM.enrichWttrDay(input) === input
  })(), (v) => v === true, 'same reference')
  eq('and the mutation is visible on the input', WTTR.weather[0].feelsC, '-1')
})

group('wttrNextForecastDays skips today and enriches what is left', () => {
  const days = WM.wttrNextForecastDays(WTTR, '2026-01-01')
  eq('wttr.in ships ~3 days and today is not one of them', days.map(d => d.date), ['2026-01-02', '2026-01-03'])
  eq('the first row is enriched', days[0].feelsC, '-2')
  eq('a day with no hourly entries enriches to empty strings', days[1].humidity, '')
  eq('the count is honoured', WM.wttrNextForecastDays(WTTR, '2026-01-01', 1).map(d => d.date), ['2026-01-02'])
  eq('a zero count defaults to seven', WM.wttrNextForecastDays(WTTR, '2026-01-01', 0).length, 2)
  eq('an unparseable count defaults to seven', WM.wttrNextForecastDays(WTTR, '2026-01-01', 'x').length, 2)
  eq('no count defaults to seven', WM.wttrNextForecastDays(WTTR, '2026-01-01').length, 2)
  eq('nothing is future', WM.wttrNextForecastDays(WTTR, '2026-01-03'), [])
  eq('no weather block', WM.wttrNextForecastDays({}, '2026-01-01'), [])
  eq('a null report', WM.wttrNextForecastDays(null, '2026-01-01'), [])
  eq('an empty weather array', WM.wttrNextForecastDays({ weather: [] }, '2026-01-01'), [])
  eq('no report at all', WM.wttrNextForecastDays(), [])
})

group('buildForecastDays prefers Open-Meteo and falls back to wttr', () => {
  eq('with both, the primary source wins', WM.buildForecastDays(WTTR, OM, '2026-01-01').map(d => d.date), ['2026-01-02', '2026-01-03'])
  eq('with only wttr, the fallback answers', WM.buildForecastDays(WTTR, {}, '2026-01-01').map(d => d.date), ['2026-01-02', '2026-01-03'])
  eq('an Open-Meteo report with no future days falls back too', WM.buildForecastDays(WTTR, { daily: { time: ['2026-01-01'] } }, '2026-01-01').map(d => d.date), ['2026-01-02', '2026-01-03'])
  eq('with neither, no rows', WM.buildForecastDays({}, {}, '2026-01-01'), [])
  eq('a null report pair', WM.buildForecastDays(null, null, '2026-01-01'), [])
  eq('the fallback rows are enriched too', WM.buildForecastDays(WTTR, {}, '2026-01-01')[0].feelsC, '-2')
})

group('bareTempForDay and hourTemp render one value in the requested unit', () => {
  const day = { maxtempC: '3', mintempC: '-4', maxtempF: '37', mintempF: '25' }
  eq('metric max', WM.bareTempForDay(day, 'max', false), '3°')
  eq('metric min', WM.bareTempForDay(day, 'min', false), '-4°')
  eq('imperial max', WM.bareTempForDay(day, 'max', true), '37°')
  eq('imperial min', WM.bareTempForDay(day, 'min', true), '25°')
  eq('an unknown kind reads the min', WM.bareTempForDay(day, 'other', false), '-4°')
  eq('a missing leg is empty, not a bare degree sign', WM.bareTempForDay({ maxtempC: '3' }, 'min', false), '')
  eq('an empty leg is empty', WM.bareTempForDay({ maxtempC: '' }, 'max', false), '')
  eq('a null leg is empty', WM.bareTempForDay({ maxtempC: null }, 'max', false), '')
  eq('a day with nothing', WM.bareTempForDay({}, 'max', false), '')
  eq('no day at all', WM.bareTempForDay(null, 'max', false), '')
  eq('no arguments at all', WM.bareTempForDay(), '')
  eq('an hour in metric', WM.hourTemp({ tempC: '-1', tempF: '30' }, false), '-1°')
  eq('an hour in imperial', WM.hourTemp({ tempC: '-1', tempF: '30' }, true), '30°')
  eq('an hour with nothing', WM.hourTemp({}, false), '')
  eq('no hour at all', WM.hourTemp(null, false), '')
  // The Open-Meteo forecast row is the shape these two read.
  eq('a normalised forecast row renders', WM.bareTempForDay(WM.openMeteoForecastDays(OM, '2026-01-01')[0], 'max', false), '2°')
  eq('and its hourly row', WM.hourTemp(WM.openMeteoHourlyForecast(OM, 0, 1)[0], false), '-1°')
})

group('hourIcon honours the entry\'s own day/night flag', () => {
  eq('day', WM.hourIcon({ openMeteoWeatherCode: 0, isDay: 1 }), 'weather-clear-day')
  eq('night', WM.hourIcon({ openMeteoWeatherCode: 0, isDay: 0 }), 'weather-clear-night')
  // The comparison is inverted against currentIcon: there the flag is
  // `Number(isDay) === 0`, here it is `!isDay`, so a missing flag is night
  // for an hour and day for a current condition. Pinned as written.
  eq('a missing flag is night here', WM.hourIcon({ openMeteoWeatherCode: 0 }), 'weather-clear-night')
  eq('fog gets its night variant', WM.hourIcon({ openMeteoWeatherCode: 45, isDay: 0 }), 'weather-fog-night')
  eq('steady rain shares one glyph', WM.hourIcon({ openMeteoWeatherCode: 61, isDay: 1 }), 'weather-rain')
  eq('no code is an empty string, never a blank box', WM.hourIcon({}), '')
  eq('a null code is an empty string', WM.hourIcon({ openMeteoWeatherCode: null }), '')
  eq('no entry at all', WM.hourIcon(null), '')
  eq('no arguments at all', WM.hourIcon(), '')
  eq('a normalised hourly row', WM.hourIcon(WM.openMeteoHourlyForecast(OM, 0, 4)[2]), 'weather-partly-cloudy-night')
})

group('dayIcon prefers the daily code, then the noon hour', () => {
  eq('a daily code', WM.dayIcon({ openMeteoWeatherCode: 95 }), 'weather-thunderstorm')
  eq('a daily overcast', WM.dayIcon({ openMeteoWeatherCode: 3 }), 'weather-overcast')
  // A day has no day/night flag, so the daily branch is always the day
  // variant even for the fog codes.
  eq('a daily fog code is the day variant', WM.dayIcon({ openMeteoWeatherCode: 45 }), 'weather-fog-day')
  eq('a null daily code falls back to the noon hour', WM.dayIcon({ openMeteoWeatherCode: null, hourly: [{ time: '1200', weatherCode: '200' }] }), 'weather-thunderstorm')
  eq('a wttr day with no daily code', WM.dayIcon(WTTR.weather[0]), 'weather-partly-cloudy-day')
  eq('a day with no hourly series is an empty string', WM.dayIcon({ hourly: [] }), '')
  eq('a day with nothing', WM.dayIcon({}), '')
  eq('no day at all', WM.dayIcon(null), '')
  eq('no arguments at all', WM.dayIcon(), '')
  eq('the forecast row the service actually holds', WM.dayIcon(WM.openMeteoForecastDays(OM, '2026-01-01')[0]), 'weather-rain')
})

group('dayDetailsLine is the one-line verbose detail', () => {
  eq('all four fields', WM.dayDetailsLine({ feelsC: '21', windKmph: '14', humidity: '63', precipProb: '20' }, false),
    'Feels 21° · Wind 14 km/h · Hum 63% · Rain 20%')
  eq('imperial reads the mph leg', WM.dayDetailsLine({ feelsF: '70', windMph: '9', humidity: '63', precipProb: '20' }, true),
    'Feels 70° · Wind 9 mph · Hum 63% · Rain 20%')
  eq('the metric leg is used for metric', WM.dayDetailsLine({ feelsC: '21', feelsF: '70' }, false), 'Feels 21°')
  eq('and the imperial leg for imperial', WM.dayDetailsLine({ feelsC: '21', feelsF: '70' }, true), 'Feels 70°')
  // Sources may omit fields, and a missing field is skipped, so there is
  // never a dangling separator.
  eq('one field', WM.dayDetailsLine({ feelsC: '21' }, false), 'Feels 21°')
  eq('humidity and rain only', WM.dayDetailsLine({ humidity: '63', precipProb: '20' }, false), 'Hum 63% · Rain 20%')
  eq('every field empty is an empty line', WM.dayDetailsLine({ feelsC: '', windKmph: '', humidity: '', precipProb: '' }, false), '')
  eq('a null field is skipped', WM.dayDetailsLine({ feelsC: null, humidity: '63' }, false), 'Hum 63%')
  eq('numeric fields render as they are', WM.dayDetailsLine({ feelsC: 21, humidity: 63 }, false), 'Feels 21° · Hum 63%')
  eq('no fields is an empty line', WM.dayDetailsLine({}, false), '')
  eq('no day at all', WM.dayDetailsLine(null, false), '')
  eq('no arguments at all', WM.dayDetailsLine(), '')
  is('the line never starts or ends with the separator', [{}, { feelsC: '21' }, { humidity: '5' }, { feelsC: '1', humidity: '2' }].map(d => WM.dayDetailsLine(d, false)),
    (v) => v.every(s => !s.startsWith(' · ') && !s.endsWith(' · ') && !s.includes(' ·  ')), 'no dangling separator')
  eq('a real forecast row', WM.dayDetailsLine(WM.openMeteoForecastDays(OM, '2026-01-01')[0], false), 'Feels -1° · Wind 20 km/h · Hum 80% · Rain 55%')
  eq('and the same row in imperial', WM.dayDetailsLine(WM.openMeteoForecastDays(OM, '2026-01-01')[0], true), 'Feels 30° · Wind 12 mph · Hum 80% · Rain 55%')
})

section('weather/Model - the determinism contract')

group('the module never reads the clock itself', () => {
  // Callers pass todayString ("yyyy-MM-dd") and formatters in; the module
  // never reads the clock. That is what keeps every assertion in this suite
  // - and every future one - deterministic.
  notMatch('no Date.now()', WM_SRC, /Date\.now\(/)
  notMatch('no new Date() with no argument', WM_SRC, /new Date\(\s*\)/)
  notMatch('no Date() with no argument', WM_SRC, /(?<!new )Date\(\s*\)/)
  eq('the only Date construction is the noon-anchored one', (WM_SRC.match(/new Date\(/g) || []).length, 1)
  contains('and it is anchored to a T12:00:00 stamp', WM_SRC, 'dateString + "T12:00:00"')
  eq('the other instant is a parse of an injected stamp', (WM_SRC.match(/Date\.parse\(/g) || []).length, 1)
  eq('todayString is a parameter of both forecast readers', [WM.openMeteoForecastDays.length, WM.wttrNextForecastDays.length], [3, 3])
  eq('the hourly reader takes nowUtcMs as an argument', WM.openMeteoHourlyForecast.length, 4)
  eq('dayName takes the formatter as an argument', WM.dayName.length, 2)
})

group('every exported function is exercised and none of them throws', () => {
  const EXPORTS = [
    'coordinatesOf', 'parseLocationFile', 'wttrLocationQuery', 'parseGeocodingResults',
    'locationCommit', 'isFutureForecastDate', 'roundedTemp', 'celsiusToFahrenheit',
    'formatTemp', 'oneDecimal', 'hpaToInHg', 'mmToInches',
    'normalizedUnit', 'localeUsesImperial', 'countryUsesImperial',
    'shouldUseImperial', 'dayName', 'openMeteoForecastDays', 'kmhToMph',
    'humidityMaxForDate', 'noonHourly', 'enrichWttrDay', 'openMeteoCurrentCondition',
    'currentIcon', 'provisionalCurrentIcon',
    'wttrNextForecastDays', 'buildForecastDays', 'bareTempForDay',
    'openMeteoHourlyForecast', 'hourTemp', 'hourIcon', 'dayDetailsLine', 'dayIcon',
    'iconForWmoCode', 'iconForCode',
  ]
  eq('the module publishes exactly these 35 functions', Object.keys(WM).sort(), EXPORTS.slice().sort())
  is('and they are all functions', EXPORTS, (v) => v.every(n => typeof WM[n] === 'function'), 'all callable')
  // A representative call per function with no arguments at all: the island
  // builds these from possibly-empty state, so a throw here would be a real
  // defect. enrichWttrDay is the one exception, and it is pinned below.
  for (const name of EXPORTS) {
    if (name === 'enrichWttrDay') continue
    noThrow(`${name}() does not throw`, () => WM[name]())
  }
  // enrichWttrDay writes through to its argument, so a missing day throws
  // while every other function in the module tolerates one. Its only caller
  // passes a day straight out of the wttr weather array, so this is a
  // totality gap rather than a live defect.
  throws('enrichWttrDay() with no day throws instead of returning a row', () => WM.enrichWttrDay())
  noThrow('but a day with nothing on it is fine', () => WM.enrichWttrDay({ date: 'x' }))
  skip('a live IPP round-trip through Printers.qml', 'no cupsd and no printer hardware on this host; the READMEs say not to claim it as verified')
  skip('the wttr.in and Open-Meteo fetches in Weather.qml', 'no network in this suite and no weather test script exists; the pure halves are covered above')
})

finish()
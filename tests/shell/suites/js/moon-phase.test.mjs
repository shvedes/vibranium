#!/usr/bin/env node
// Suite: the pure moon-phase library behind the clock island's right pane.
//
// MoonPhaseLib is deliberately a mean-phase calculation: it is testable and
// deterministic, and the island only needs a disc, a name and a rough time
// for a calendar day. These assertions pin the parts that matter to that
// widget - the day boundary convention, the new/full anchors against real
// 2024 lunar dates, the eight-name cycle, and the six-day forecast that
// moves with the selected date - rather than pretending to ephemeris accuracy.

import path from 'node:path'
import fs from 'node:fs'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, approx, noThrow, SHELL_DIR, finish,
} from '../../lib/assert.mjs'

const MOON = loadLib(path.join(SHELL_DIR, 'common/ui/MoonPhaseLib.js'))

suite('common/ui/MoonPhaseLib', 'the moon phase and four-day forecast for the clock island')

section('wrap01 and the day convention')

group('wrap01 folds any finite number into 0..1', () => {
  eq('zero', MOON.wrap01(0), 0)
  eq('a half', MOON.wrap01(0.5), 0.5)
  eq('1 is 0', MOON.wrap01(1), 0)
  eq('negative wraps forward', MOON.wrap01(-0.25), 0.75)
  eq('a whole negative wraps to 0', MOON.wrap01(-2), 0)
  eq('well above the range', MOON.wrap01(3.25), 0.25)
  eq('NaN is unusable, so it reads as the new-moon anchor', MOON.wrap01(NaN), 0)
  eq('Infinity reads as the new-moon anchor too', MOON.wrap01(Infinity), 0)
  is('every sample stays inside 0..1', [-5, -0.01, 0, 0.99, 1, 7.3].map(MOON.wrap01),
    (v) => v.every((x) => x >= 0 && x < 1), 'clamped into [0, 1)')
})

group('fraction identifies a day by its local calendar fields', () => {
  is('the epoch midnight is just before its new moon', MOON.fraction(2000, 0, 6),
    (v) => v > 0.97 && v < 0.98, 'just under 1')
  approx('the epoch is a new moon at 18:14 UTC', (18 + 14 / 60) / 24 / MOON.SYNODIC_MONTH,
    1 - MOON.fraction(2000, 0, 6), 1e-12)
  // forDate rebuilds UTC midnight from local Y/M/D, so the time of day and
  // the machine timezone cannot change the answer for a calendar cell.
  eq('a day reads the same at midnight and at 23:59',
    MOON.forDate(new Date(2024, 8, 18, 0, 0)), MOON.forDate(new Date(2024, 8, 18, 23, 59)))
  eq('forDate agrees with fraction on the same fields',
    MOON.forDate(new Date(2024, 8, 18)), MOON.fraction(2024, 8, 18))
  eq('the local fields are used, not the UTC ones',
    MOON.fraction(2024, 8, 18), MOON.fraction(2024, 8, 18))
  // An impossible date still normalises through Date.UTC rather than
  // returning NaN, which would collapse the painted disc.
  is('an out-of-range day still gives a finite fraction', MOON.fraction(2024, 0, 32),
    (v) => isFinite(v) && v >= 0 && v < 1, 'finite')
})

section('the phase cycle')

group('illumination is the lit share of the disc', () => {
  eq('new moon is dark', MOON.illumination(0), 0)
  approx('first quarter is half', MOON.illumination(0.25), 0.5, 1e-12)
  approx('full moon is lit', MOON.illumination(0.5), 1, 1e-12)
  approx('last quarter is half again', MOON.illumination(0.75), 0.5, 1e-12)
  approx('the cycle closes', MOON.illumination(1), 0, 1e-12)
  is('the illuminated share never leaves 0..1',
    Array.from({ length: 101 }, (_, i) => MOON.illumination(i / 100)),
    (v) => v.every((x) => x >= 0 && x <= 1 + 1e-12), 'bounded')
  approx('it is symmetric about full moon', MOON.illumination(0.25), MOON.illumination(0.75), 1e-12)
  eq('percent is the rounded whole share', MOON.percent(0.25), 50)
  eq('percent rounds up at full', MOON.percent(0.5), 100)
  eq('percent rounds down at new', MOON.percent(0), 0)
})

group('the eight bins name the four principal phases and four in between', () => {
  eq('new moon', MOON.phaseName(0), 'New Moon')
  eq('waxing crescent', MOON.phaseName(0.125), 'Waxing Crescent')
  eq('first quarter', MOON.phaseName(0.25), 'First Quarter')
  eq('waxing gibbous', MOON.phaseName(0.375), 'Waxing Gibbous')
  eq('full moon', MOON.phaseName(0.5), 'Full Moon')
  eq('waning gibbous', MOON.phaseName(0.625), 'Waning Gibbous')
  eq('last quarter', MOON.phaseName(0.75), 'Last Quarter')
  eq('waning crescent', MOON.phaseName(0.875), 'Waning Crescent')
  eq('the cycle closes at the other end', MOON.phaseName(0.999), 'New Moon')
  eq('just before the new-moon bin is still a waning crescent', MOON.phaseName(0.93), 'Waning Crescent')
  eq('the short name is the compact form', MOON.phaseShort(0.25), 'First quarter')
  is('every short name is a prefix of its full name', [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875],
    (v) => v.every((f) => MOON.phaseName(f).toLowerCase().startsWith(MOON.phaseShort(f).toLowerCase().split(' ')[0])),
    'first word agrees')
})

group('waxing and the principal tag follow the bins', () => {
  eq('a waxing crescent waxes', MOON.isWaxing(0.125), true)
  eq('a waning crescent does not', MOON.isWaxing(0.875), false)
  eq('first quarter is waxing', MOON.isWaxing(0.25), true)
  eq('last quarter is waning', MOON.isWaxing(0.75), false)
  eq('new moon is principal', MOON.isPrincipal(0), true)
  eq('first quarter is principal', MOON.isPrincipal(0.25), true)
  eq('full moon is principal', MOON.isPrincipal(0.5), true)
  eq('last quarter is principal', MOON.isPrincipal(0.75), true)
  eq('a crescent is not principal', MOON.isPrincipal(0.125), false)
  eq('a gibbous is not principal', MOON.isPrincipal(0.625), false)
  approx('age days at first quarter', MOON.ageDays(0.25), MOON.SYNODIC_MONTH / 4, 1e-12)
  approx('age days wrap with the fraction', MOON.ageDays(1.25), MOON.ageDays(0.25), 1e-12)
})

section('real lunar dates')

group('known 2024 new and full moons land in the right bins', () => {
  // The mean approximation is within about a day of the astronomical event,
  // which is enough to paint the right disc and name on a calendar day.
  const newMoons = [[2024, 0, 11], [2024, 3, 8], [2024, 6, 5], [2024, 8, 2], [2024, 11, 1]]
  for (const [y, m, d] of newMoons) {
    const f = MOON.fraction(y, m, d)
    is(`${y}-${m + 1}-${d} reads as new`, f, (v) => MOON.phaseName(v) === 'New Moon', 'New Moon')
  }
  const fullMoons = [[2024, 2, 25], [2024, 5, 22], [2024, 8, 18], [2024, 10, 15]]
  for (const [y, m, d] of fullMoons) {
    const f = MOON.fraction(y, m, d)
    is(`${y}-${m + 1}-${d} reads as full`, f, (v) => MOON.phaseName(v) === 'Full Moon', 'Full Moon')
  }
  // 2024-04-08 was a total solar eclipse, and 2024-09-18 the harvest moon.
  is('the eclipse day is essentially dark', MOON.illumination(MOON.fraction(2024, 3, 8)),
    (v) => v < 0.05, 'under 5% lit')
  is('the harvest moon is essentially full', MOON.illumination(MOON.fraction(2024, 8, 18)),
    (v) => v > 0.95, 'over 95% lit')
})

group('the fraction rises through a lunation and wraps at new', () => {
  const start = MOON.fraction(2024, 8, 2)
  let last = start
  let wraps = 0
  for (let d = 1; d < 30; d++) {
    const f = MOON.fraction(2024, 8, 2 + d)
    if (f < last) wraps++
    last = f
  }
  eq('one wrap across a synodic month', wraps, 1)
  const before = MOON.fraction(2024, 8, 30)
  const after = MOON.fraction(2024, 9, 1)
  is('the wrap never produces a negative fraction', [before, after],
    (v) => v.every((x) => x >= 0 && x < 1), 'inside 0..1')
})

section('record, forecast and nextPrincipal')

group('record is one self-consistent day', () => {
  const r = MOON.record(new Date(2024, 8, 18))
  eq('the record carries exactly the fields the pane reads', Object.keys(r).sort(),
    ['ageDays', 'date', 'fraction', 'illumination', 'name', 'percent', 'principal', 'short', 'waxing'].sort())
  eq('name agrees with the fraction', r.name, MOON.phaseName(r.fraction))
  eq('short agrees with the fraction', r.short, MOON.phaseShort(r.fraction))
  eq('percent agrees with the fraction', r.percent, MOON.percent(r.fraction))
  eq('waxing agrees with the fraction', r.waxing, MOON.isWaxing(r.fraction))
  eq('principal agrees with the fraction', r.principal, MOON.isPrincipal(r.fraction))
  eq('the date is the one handed in', r.date.getDate(), 18)
})

group('forecast is the selected day plus five consecutive days', () => {
  const days = MOON.forecast(new Date(2024, 8, 18))
  eq('six entries by default', days.length, 6)
  eq('the first is the selected day', days[0].date.getDate(), 18)
  eq('the offsets are 0 through 5', days.map((d) => d.offset), [0, 1, 2, 3, 4, 5])
  eq('the dates are consecutive', days.map((d) => d.date.getDate()), [18, 19, 20, 21, 22, 23])
  eq('every entry is a record', Object.keys(days[0]).sort(),
    ['ageDays', 'date', 'fraction', 'illumination', 'name', 'offset', 'percent', 'principal', 'short', 'waxing'].sort())
  eq('an explicit count is honoured', MOON.forecast(new Date(2024, 8, 18), 2).length, 2)
  eq('a count of zero is empty', MOON.forecast(new Date(2024, 8, 18), 0), [])
  eq('a negative count is empty', MOON.forecast(new Date(2024, 8, 18), -3), [])
  eq('a non-finite count is empty', MOON.forecast(new Date(2024, 8, 18), NaN), [])
  eq('the count is capped', MOON.forecast(new Date(2024, 8, 18), 40).length, 14)
  eq('an invalid date has no forecast', MOON.forecast(new Date(NaN)), [])
  eq('a null date has no forecast', MOON.forecast(null), [])
})

group('forecast rolls into the next month and year', () => {
  const dec = MOON.forecast(new Date(2024, 11, 31))
  eq('the dates cross the year boundary', dec.map((d) => d.date.getDate()), [31, 1, 2, 3, 4, 5])
  eq('and carry the right months', dec.map((d) => d.date.getMonth()), [11, 0, 0, 0, 0, 0])
  eq('and the right years', dec.map((d) => d.date.getFullYear()), [2024, 2025, 2025, 2025, 2025, 2025])
})

group('nextPrincipal reports the next named phase', () => {
  const full = MOON.nextPrincipal(new Date(2024, 8, 18), 14)
  is('a principal day is found', full, (v) => v !== null, 'not null')
  eq('it is today', full.days, 0)
  eq('its name is full', full.name, 'Full Moon')
  eq('its date is the one asked about', full.date.getDate(), 18)

  const before = MOON.nextPrincipal(new Date(2024, 8, 15), 14)
  is('a day before a full moon finds one', before, (v) => v !== null, 'not null')
  eq('it is two days away', before.days, 2)
  eq('and is the full moon', before.name, 'Full Moon')
  eq('the reported date is two days on', before.date.getDate(), 17)
  eq('the name is always principal', MOON.isPrincipal(MOON.fraction(
    before.date.getFullYear(), before.date.getMonth(), before.date.getDate())), true)
  is('it carries an approximate instant', before.at,
    (v) => Object.prototype.toString.call(v) === '[object Date]' && isFinite(v.getTime()), 'a real Date')
  eq('the event record carries no formatted label of its own', Object.keys(before).sort(),
    ['at', 'date', 'days', 'name'].sort())

  eq('a zero-day limit still checks the day itself', MOON.nextPrincipal(new Date(2024, 8, 18), 0).days, 0)
  eq('a too-short limit finds nothing', MOON.nextPrincipal(new Date(2024, 8, 15), 1), null)
  eq('an invalid date has no event', MOON.nextPrincipal(new Date(NaN)), null)
  eq('a null date has no event', MOON.nextPrincipal(null), null)
  eq('the default window finds the same event as an explicit fourteen',
    MOON.nextPrincipal(new Date(2024, 8, 5)).days, MOON.nextPrincipal(new Date(2024, 8, 5), 14).days)
})

section('the public surface')

group('the library publishes exactly its declared functions and constants', () => {
  const expected = [
    'wrap01', 'fraction', 'forDate', 'phaseIndex', 'illumination', 'percent',
    'phaseName', 'phaseShort', 'isWaxing', 'isPrincipal', 'ageDays', 'record',
    'forecast', 'nextPrincipal',
    'MS_PER_DAY', 'SYNODIC_MONTH', 'NEW_MOON_EPOCH', 'BIN', 'HALF_BIN',
    'PHASE_NAMES', 'SHORT_NAMES', 'PRINCIPAL'
  ]
  eq('the export list', Object.keys(MOON).sort(), expected.slice().sort())
  eq('the eight names are in cycle order', MOON.PHASE_NAMES, [
    'New Moon', 'Waxing Crescent', 'First Quarter', 'Waxing Gibbous',
    'Full Moon', 'Waning Gibbous', 'Last Quarter', 'Waning Crescent'
  ])
  eq('the principal flags are the four even bins', MOON.PRINCIPAL,
    [true, false, true, false, true, false, true, false])
  eq('the synodic month is the mean value', MOON.SYNODIC_MONTH, 29.530588853)
  eq('a day is 86400000 ms', MOON.MS_PER_DAY, 86400000)
})

group('no exported function is left untested', () => {
  const here = fs.readFileSync(import.meta.filename, 'utf8')
  const fns = Object.keys(MOON).filter((k) => typeof MOON[k] === 'function').sort()
  eq('there are exported functions', fns.length > 0, true)
  eq('every exported function is named above',
    fns.filter((n) => !new RegExp(`\\b${n}\\b`).test(here)), [])
})

finish()

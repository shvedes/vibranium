#!/usr/bin/env node
// Suite: the pure solar-time library behind the clock island's day pane.
//
// SunLib is a NOAA-style mean solar-position calculation. It needs no
// network, no Qt and no location lookup: the caller hands it a calendar day
// and a coordinate pair, and it returns event instants. These assertions
// cover the geometry that matters to the pane - ordering, seasonal sign,
// the equator baseline, polar extremes and graceful invalid input - plus a
// few pinned spans so a change to the algorithm is visible.

import path from 'node:path'
import fs from 'node:fs'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, is, approx, match, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const SUN = loadLib(path.join(SHELL_DIR, 'common/ui/SunLib.js'))

suite('common/ui/SunLib', 'solar times and day length for the clock island')

section('coordinate validation')

group('validPair accepts finite in-range numbers, including text', () => {
  eq('a normal pair', SUN.validPair(51.5, -0.12), { latitude: 51.5, longitude: -0.12 })
  eq('numeric text is coerced', SUN.validPair('40', '-74'), { latitude: 40, longitude: -74 })
  eq('zero is a real coordinate', SUN.validPair(0, 0), { latitude: 0, longitude: 0 })
  eq('the poles are in range', SUN.validPair(90, 180), { latitude: 90, longitude: 180 })
  eq('NaN latitude is refused', SUN.validPair(NaN, 0), null)
  eq('NaN longitude is refused', SUN.validPair(0, NaN), null)
  eq('a latitude past the pole is refused', SUN.validPair(91, 0), null)
  eq('a longitude past the date line is refused', SUN.validPair(0, 181), null)
  eq('text that is not a number is refused', SUN.validPair("51°N", 0), null)
})

section('the hour angle and its polar limits')

group('hourAngle turns zenith, latitude and declination into a span', () => {
  const a = SUN.hourAngle(SUN.ZENITH_SUNRISE, 0, 0)
  is('at the equator on the equinox there is an angle', a.angle,
    (v) => isFinite(v) && v > 0, 'finite positive')
  approx('it is a little over 90 degrees from refraction', a.angle, 90.833, 0.01)
  eq('zero declination at the north pole in summer is a polar day',
    SUN.hourAngle(90.833, 90, 23.44).polar, 'day')
  eq('and at the south pole in summer it is a polar night',
    SUN.hourAngle(90.833, -90, 23.44).polar, 'night')
})

group('solar terms are bounded and seasonal', () => {
  const jun = SUN.solarTerms(new Date(2024, 5, 21))
  const dec = SUN.solarTerms(new Date(2024, 11, 21))
  is('the equation of time stays within a quarter hour', jun.eqtime,
    (v) => v > -20 && v < 20, 'minutes')
  is('declination is within the tropics in June', jun.decl,
    (v) => v > 0.35 && v < 0.41, 'radians')
  is('declination is negative in December', dec.decl, (v) => v < -0.35, 'radians')
})

section('one day of sun')

group('the record is ordered and complete', () => {
  const r = SUN.forDate(new Date(2024, 5, 21), 51.5, -0.12)
  eq('the record carries the fields the pane reads', Object.keys(r).sort(),
    ['date', 'dawn', 'dayLengthMinutes', 'dusk', 'latitude', 'longitude',
      'polar', 'solarNoon', 'sunrise', 'sunset'].sort())
  is('sunrise precedes solar noon', r.sunrise.getTime() < r.solarNoon.getTime(), (v) => v === true, 'ordered')
  is('solar noon precedes sunset', r.solarNoon.getTime() < r.sunset.getTime(), (v) => v === true, 'ordered')
  is('civil dawn precedes sunrise', r.dawn.getTime() < r.sunrise.getTime(), (v) => v === true, 'ordered')
  is('sunset precedes civil dusk', r.sunset.getTime() < r.dusk.getTime(), (v) => v === true, 'ordered')
  eq('the pair is carried through', [r.latitude, r.longitude], [51.5, -0.12])
  eq('the date is the one asked about', r.date.getDate(), 21)
})

group('the equator is twelve hours year round', () => {
  for (const d of [new Date(2024, 0, 1), new Date(2024, 5, 21), new Date(2024, 11, 21)]) {
    const r = SUN.forDate(d, 0, 0)
    is('day length is near twelve hours', r.dayLengthMinutes,
      (v) => v >= 720 && v <= 735, '12h to 12h15m')
  }
  eq('the June span is pinned', SUN.span(SUN.forDate(new Date(2024, 5, 21), 0, 0).dayLengthMinutes), '12h 07m')
})

group('seasons flip across the equator', () => {
  const summer = SUN.forDate(new Date(2024, 5, 21), 51.5, -0.12)
  const winter = SUN.forDate(new Date(2024, 11, 21), 51.5, -0.12)
  is('a northern summer day is long', summer.dayLengthMinutes, (v) => v > 990, 'over 16.5h')
  is('a northern winter day is short', winter.dayLengthMinutes, (v) => v < 480, 'under 8h')
  // Refraction lengthens both solstices, so the pair sums to more than 24h
  // rather than cancelling the way a geometric, horizon-free model would.
  is('the two solstices sum to a little over a day',
    summer.dayLengthMinutes + winter.dayLengthMinutes,
    (v) => v >= 1440 && v <= 1500, 'just over 24h')
  eq('the London June span is pinned', SUN.span(summer.dayLengthMinutes), '16h 39m')
  eq('the London December span is pinned', SUN.span(winter.dayLengthMinutes), '7h 50m')

  const south = SUN.forDate(new Date(2024, 11, 21), -33.9, 151.2)
  is('a southern summer day is long', south.dayLengthMinutes, (v) => v > 850, 'over 14h')
})

group('polar days and nights have no crossing times', () => {
  const day = SUN.forDate(new Date(2024, 5, 21), 78, 15)
  eq('a June polar day is flagged', day.polar, 'day')
  eq('it has no sunrise', day.sunrise, null)
  eq('it has no sunset', day.sunset, null)
  eq('and reports a full day of light', day.dayLengthMinutes, 1440)

  const night = SUN.forDate(new Date(2024, 11, 21), 78, 15)
  eq('a December polar night is flagged', night.polar, 'night')
  eq('it has no sunrise either', night.sunrise, null)
  eq('and reports no daylight', night.dayLengthMinutes, 0)
})

group('invalid inputs yield no record rather than bogus times', () => {
  eq('an invalid date', SUN.forDate(new Date(NaN), 51.5, 0), null)
  eq('a null date', SUN.forDate(null, 51.5, 0), null)
  eq('an invalid latitude', SUN.forDate(new Date(2024, 5, 21), NaN, 0), null)
  eq('an out-of-range longitude', SUN.forDate(new Date(2024, 5, 21), 0, 200), null)
})

section('presentation and public surface')

group('span formats a duration for the pane', () => {
  eq('zero', SUN.span(0), '0h 00m')
  eq('a short day', SUN.span(470), '7h 50m')
  eq('a padded minute', SUN.span(725), '12h 05m')
  eq('a long day', SUN.span(999), '16h 39m')
  eq('a negative duration clamps to zero', SUN.span(-5), '0h 00m')
  eq('text is coerced', SUN.span('725'), '12h 05m')
})

group('the library publishes exactly its declared surface', () => {
  eq('the export list', Object.keys(SUN).sort(),
    ['RAD', 'ZENITH_SUNRISE', 'ZENITH_CIVIL', 'MINUTES_PER_DAY',
      'validPair', 'solarTerms', 'hourAngle', 'atMinutes', 'forDate', 'span'].sort())
  match('the sunrise zenith keeps the refraction correction', String(SUN.ZENITH_SUNRISE), /^90\.833/)
  eq('civil twilight is six degrees below', SUN.ZENITH_CIVIL, 96)
  eq('a day is 1440 minutes', SUN.MINUTES_PER_DAY, 1440)

  const here = fs.readFileSync(import.meta.filename, 'utf8')
  const fns = Object.keys(SUN).filter((k) => typeof SUN[k] === 'function').sort()
  eq('there are exported functions', fns.length > 0, true)
  eq('every exported function is named above',
    fns.filter((n) => !new RegExp(`\\b${n}\\b`).test(here)), [])
})

finish()

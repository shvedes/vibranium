#!/usr/bin/env node
// Suite: Weather refresh-cycle isolation (SVC-5).
//
//   shell/services/weather/Weather.qml   refresh, _startWttrFallback,
//                                        _abortForecast/_abortDailyForecast,
//                                        _get, _startForecast/_startDailyForecast,
//                                        _onForecast/_onDailyForecast
//
// Limitation: Weather is a Singleton whose two legs are XMLHttpRequest fetches
// to wttr.in and open-meteo. Under `QT_QPA_PLATFORM=offscreen` the network is
// not exercised and there is no way to hold a ~40 s response until a chosen
// moment, so the live two-cycle race cannot be observed here. This suite reads
// the real QML, lifts the handlers by brace matching, and drives two overlapping
// cycles against a stub transport whose answers the test delivers by hand.
// What is pinned is the mechanism: a refresh boundary retires the previous
// cycle's handles and generation, and a late answer from a retired generation
// cannot publish a report - not the provider payloads themselves.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const SERVICE = fs.readFileSync(
  path.join(SHELL_DIR, 'services', 'weather', 'Weather.qml'), 'utf8')

// Lift a block by brace matching so nested ifs and closures survive intact.
// The shipped QML is the only source of truth: nothing is copied into this
// suite.
function bracedBody(src, firstBrace, label) {
  if (firstBrace < 0) throw new Error(`${label} has no body`)
  let depth = 0
  for (let j = firstBrace; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(firstBrace + 1, j)
    }
  }
  throw new Error(`${label} body never closes`)
}

function extractFunction(src, name) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) throw new Error(`Weather.qml has no ${head}`)
  return bracedBody(src, src.indexOf('{', at), head)
}

const REFRESH = extractFunction(SERVICE, 'refresh')
const WTTR_FALLBACK = extractFunction(SERVICE, '_startWttrFallback')
const ABORT_FORECAST = extractFunction(SERVICE, '_abortForecast')
const ABORT_DAILY = extractFunction(SERVICE, '_abortDailyForecast')
const GET = extractFunction(SERVICE, '_get')
const START_FORECAST = extractFunction(SERVICE, '_startForecast')
const START_DAILY = extractFunction(SERVICE, '_startDailyForecast')
const ON_FORECAST = extractFunction(SERVICE, '_onForecast')
const ON_DAILY = extractFunction(SERVICE, '_onDailyForecast')

// Pure model calls the two answer handlers make; none of them is under test.
const Model = {
  provisionalCurrentIcon: (_cond, cur) => cur || 'icon-wttr',
  currentIcon: (cur, old) => (cur ? 'icon-om' : old),
  openMeteoCurrentCondition: (p) => (p && p.current ? { temp_C: '10' } : null),
}
const Qt = { callLater: (fn) => fn() }

function makeSim(coords = false) {
  const requests = []
  const root = {
    _fetchGeneration: 0,
    _forecastReq: null,
    _dailyReq: null,
    report: null,
    dailyForecastReport: null,
    conditionIcon: '',
    _forecastSettled: false,
    forecastRetries: 0,
    dailyForecastRetries: 0,
    wttrFallbackActive: false,
    _forecastUnavailable: false,
    hasConfiguredCoordinates: coords,
    savingLocation: false,
    savingLocationQueryStarted: false,
    locationQuery: 'Auto',
    _hasCoordinates: () => coords,
  }
  // Stub transport. A handle carries the generation it was issued in and the
  // test can deliver an answer through onDone directly, bypassing the dead flag
  // that lives in the real _get so the generation guard is what is exercised.
  root._get = (url, _timeoutMs, onDone) => {
    const handle = {
      dead: false,
      gen: root._fetchGeneration,
      url,
      abort() { this.dead = true },
      onDone,
    }
    requests.push(handle)
    return handle
  }
  root.finishSavingLocation = () => {}
  root.refreshDailyForecast = () => {}
  root.scheduleForecastRetry = () => {}
  root.scheduleDailyForecastRetry = () => {}

  // `with (root)` reproduces QML scope for the lifted bodies. They reference
  // root explicitly; Model/Qt and the function's own parameters come from
  // outside, so a bare `text`/`url` in a lifted body still resolves.
  const bind = (body, params = []) => {
    const fn = new Function('root', 'Model', 'Qt', ...params, `with (root) {\n${body}\n}`)
    return (...args) => fn(root, Model, Qt, ...args)
  }
  root.refresh = bind(REFRESH)
  root._startWttrFallback = bind(WTTR_FALLBACK)
  root._abortForecast = bind(ABORT_FORECAST)
  root._abortDailyForecast = bind(ABORT_DAILY)
  root._startForecast = bind(START_FORECAST)
  root._startDailyForecast = bind(START_DAILY, ['url'])
  root._onForecast = bind(ON_FORECAST, ['text', 'code', 'host'])
  root._onDailyForecast = bind(ON_DAILY, ['text', 'code', 'host'])

  return {
    root,
    requests,
    forecast: () => requests.filter((h) => h.url.includes('wttr.in')),
    daily: () => requests.filter((h) => h.url.includes('open-meteo')),
  }
}

const WTTR = (marker) => JSON.stringify({
  marker,
  current_condition: [{ temp_C: marker, humidity: '50' }],
  nearest_area: [{ areaName: [{ value: marker }], latitude: '0', longitude: '0' }],
})
const DAILY = (marker) => JSON.stringify({ marker, current: { temperature_2m: 10 } })

suite('weather cycles', 'refresh generations retire stale provider answers')

// ---------------------------------------------------------------------------
section('a new refresh retires the previous cycle')

group('refresh bumps the generation and aborts both in-flight legs', () => {
  const sim = makeSim(false)
  sim.root.refresh()
  eq('the first cycle minted generation 1', sim.root._fetchGeneration, 1)
  eq('the first cycle issued one wttr request', sim.forecast().length, 1)
  const h1 = sim.forecast()[0]
  eq('the handle carries generation 1', h1.gen, 1)

  sim.root.refresh()
  eq('the second cycle minted generation 2', sim.root._fetchGeneration, 2)
  eq('the second cycle aborted the old wttr handle', h1.dead, true)
  eq('the second cycle issued a fresh wttr handle', sim.forecast().length, 2)
  eq('the fresh handle carries generation 2', sim.forecast()[1].gen, 2)
})

// ---------------------------------------------------------------------------
section('a late wttr answer cannot publish after a new cycle')

group('an old provider answer does not overwrite the new cycle report', () => {
  const sim = makeSim(false)
  sim.root.refresh()
  const h1 = sim.forecast()[0]
  sim.root.refresh()
  const h2 = sim.forecast()[1]

  h2.onDone(WTTR('C2'), '', 'wttr.in')
  eq('the live cycle published its report', sim.root.report.marker, 'C2')

  h1.onDone(WTTR('C1'), '', 'wttr.in')
  eq('the retired generation did not overwrite report', sim.root.report.marker, 'C2')
  eq('conditionIcon was not rewritten by the stale answer', sim.root.conditionIcon, 'icon-wttr')
})

group('a stale answer does not clear the live handle', () => {
  const sim = makeSim(false)
  sim.root.refresh()
  const h1 = sim.forecast()[0]
  sim.root.refresh()
  const h2 = sim.forecast()[1]
  eq('the live slot holds the new handle', sim.root._forecastReq, h2)

  h1.onDone(WTTR('C1'), '', 'wttr.in')
  eq('report stays empty: the stale answer was dropped', sim.root.report, null)
  eq('the live handle survived the stale answer', sim.root._forecastReq, h2)
})

// ---------------------------------------------------------------------------
section('the open-meteo leg retires its generation too')

group('a stale daily answer cannot overwrite the new cycle', () => {
  const sim = makeSim(true)
  let n = 0
  sim.root.refreshDailyForecast = () =>
    sim.root._startDailyForecast('https://api.open-meteo.com/v1/forecast?seq=' + (++n))

  sim.root.refresh()
  const d1 = sim.daily()[0]
  sim.root.refresh()
  const d2 = sim.daily()[1]
  eq('the old daily handle was aborted', d1.dead, true)
  eq('daily handles carry distinct generations', [d1.gen, d2.gen], [1, 2])

  d2.onDone(DAILY('D2'), '', 'api.open-meteo.com')
  eq('the live daily answer published', sim.root.dailyForecastReport.marker, 'D2')
  d1.onDone(DAILY('D1'), '', 'api.open-meteo.com')
  eq('the stale daily answer did not overwrite it', sim.root.dailyForecastReport.marker, 'D2')
})

// ---------------------------------------------------------------------------
section('the wttr fallback boundary is a cycle boundary')

group('entering the fallback aborts the spent leg and bumps the generation', () => {
  const sim = makeSim(true)
  sim.root._dailyReq = sim.root._get(
    'https://api.open-meteo.com/v1/forecast?old', 5000, () => {})
  const spent = sim.daily()[0]
  const before = sim.root._fetchGeneration

  sim.root._startWttrFallback()
  eq('the generation was bumped at the boundary', sim.root._fetchGeneration, before + 1)
  eq('the spent daily handle was aborted', spent.dead, true)
  eq('the fallback latch is set', sim.root.wttrFallbackActive, true)
  eq('the forecast handle carries the new generation', sim.forecast()[0].gen, before + 1)
})

// ---------------------------------------------------------------------------
section('the guard lives at the boundary and in each callback')

group('generation is bumped and handles aborted at cycle boundaries', () => {
  match('refresh bumps the cycle generation', REFRESH, /_fetchGeneration\+\+/)
  contains('refresh aborts the forecast leg', REFRESH, '_abortForecast()')
  contains('refresh aborts the daily leg', REFRESH, '_abortDailyForecast()')
  match('the fallback boundary bumps the generation', WTTR_FALLBACK, /_fetchGeneration\+\+/)
  contains('the fallback boundary aborts the daily leg', WTTR_FALLBACK, '_abortDailyForecast()')
})

group('the handle carries a generation and every answer checks it', () => {
  contains('_get stamps the handle with a generation', GET, 'gen:')
  contains('the dead flag on the handle is preserved', GET, 'dead: false')
  match('_startForecast drops a stale generation', START_FORECAST,
    /gen\s*!==\s*root\._fetchGeneration/)
  match('_startDailyForecast drops a stale generation', START_DAILY,
    /gen\s*!==\s*root\._fetchGeneration/)
})

group('the geocode generation and labelled latches are preserved', () => {
  contains('geocode generation still exists', SERVICE, '_geocodeGeneration')
  contains('geocode debounce is still 300 ms', SERVICE, 'interval: 300')
  contains('the retry bursts are still 2500 ms', SERVICE, 'interval: 2500')
})

finish()

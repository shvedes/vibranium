#!/usr/bin/env node
// Suite: marquee - the shared scroll gate.
//
// Scrolling a clipped title is how the full text is read at all. The animation
// setting governs motion, not whether the text can be revealed, so the gate is
// overflow alone. These tests pin that split at the primitive rather than
// relying on every QML caller to remember it.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, notContains, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const M = loadLib(path.join(SHELL, 'common', 'motion', 'Marquee.js'))
const DI = fs.readFileSync(path.join(SHELL, 'features', 'bar', 'modules',
  'Downloader', 'DownloaderIsland.qml'), 'utf8')
const NI = fs.readFileSync(path.join(SHELL, 'features', 'bar', 'modules',
  'NowPlaying', 'NowPlayingIsland.qml'), 'utf8')

suite('marquee', 'the shared text-scroll overflow gate')

section('scrollable')
group('overflow is the only gate', () => {
  eq('a real overflow scrolls', M.scrollable(24), true)
  eq('half a pixel is not an overflow', M.scrollable(0.5), false)
  eq('just over half a pixel scrolls', M.scrollable(0.6), true)
  eq('zero does not scroll', M.scrollable(0), false)
  eq('negative overflow does not scroll', M.scrollable(-10), false)
  eq('a non-number does not scroll', M.scrollable(NaN), false)
  eq('infinity does not scroll', M.scrollable(Infinity), false)
  eq('a numeric string works', M.scrollable('12'), true)
})

section('legMs keeps its reading pace')
group('the duration is clamped', () => {
  eq('the floor', M.legMs(0), 1800)
  eq('a short overflow still gets the floor', M.legMs(-5), 1800)
  eq('a long overflow is capped', M.legMs(100000), 9000)
  eq('a malformed overflow uses the floor', M.legMs(NaN), 1800)
})

section('endpointPauseMs - one published dwell for every marquee row')
group('the pause is one named value in the shared library', () => {
  is('Marquee publishes endpointPauseMs', M.endpointPauseMs,
    (v) => typeof v === 'function', 'a function')
  eq('the shared endpoint pause is 400ms',
    typeof M.endpointPauseMs === 'function' ? M.endpointPauseMs() : null, 400)
  eq('the constant is published too', M.ENDPOINT_PAUSE_MS, 400)
})
group('every QML marquee consumes that value, never a literal', () => {
  notContains('DownloaderIsland has no literal 400ms pause', DI, 'duration: 400')
  notContains('NowPlayingIsland has no literal 400ms endpoint', NI,
    'endpointPauseMs: 400')
  eq('three Downloader boxes publish the pause',
    (DI.match(/endpointPauseMs: Marquee\.endpointPauseMs\(\)/g) || []).length, 3)
  eq('three NowPlaying rows publish the pause',
    (NI.match(/endpointPauseMs: Marquee\.endpointPauseMs\(\)/g) || []).length, 3)
  eq('six Downloader pauses read the property',
    (DI.match(/duration: \w+\.endpointPauseMs/g) || []).length, 6)
  eq('six NowPlaying pauses read the property',
    (NI.match(/duration: \w+\.endpointPauseMs/g) || []).length, 6)
})
group('the leg curve and overflow gate stay where they were', () => {
  eq('three Downloader leg calls', (DI.match(/Marquee\.legMs\(overflow\)/g) || []).length, 3)
  eq('three NowPlaying leg calls', (NI.match(/Marquee\.legMs\(overflow\)/g) || []).length, 3)
  eq('three Downloader overflow gates', (DI.match(/Marquee\.scrollable\(overflow\)/g) || []).length, 3)
  eq('three Downloader scroll resets', (DI.match(/onStopped: \w+\.x = 0/g) || []).length, 3)
  eq('three NowPlaying scroll resets', (NI.match(/onStopped: \w+Text\.x = 0/g) || []).length, 3)
})

finish()

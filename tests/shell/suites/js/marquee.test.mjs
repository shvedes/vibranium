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
import { suite, section, group, eq, is, contains, notContains, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const M = loadLib(path.join(SHELL, 'common', 'motion', 'Marquee.js'))
const DI = fs.readFileSync(path.join(SHELL, 'features', 'bar', 'modules',
  'Downloader', 'DownloaderIsland.qml'), 'utf8')
const NI = fs.readFileSync(path.join(SHELL, 'features', 'bar', 'modules',
  'NowPlaying', 'NowPlayingIsland.qml'), 'utf8')
const LE = fs.readFileSync(path.join(SHELL, 'features', 'launcher',
  'LauncherEntry.qml'), 'utf8')
const SL = fs.readFileSync(path.join(SHELL, 'common', 'ui', 'ScrollLabel.qml'), 'utf8')

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
group('no call site carries a pause literal', () => {
  notContains('DownloaderIsland has no literal 400ms pause', DI, 'duration: 400')
  notContains('NowPlayingIsland has no literal 400ms endpoint', NI,
    'endpointPauseMs: 400')
  notContains('LauncherEntry has no literal 400ms endpoint either', LE,
    'endpointPauseMs: 400')
})

section('ScrollLabel owns the mechanics in one place')
group('the shared type is the only reader of the timing library', () => {
  contains('ScrollLabel imports the shared timing library', SL,
    'import "../motion/Marquee.js" as Marquee')
  contains('the endpoint beat is the shared value', SL,
    'property int endpointPauseMs: Marquee.endpointPauseMs()')
  contains('the overflow gate is the shared one', SL,
    '&& Marquee.scrollable(overflow)')
  contains('the leg duration is the shared one', SL,
    'readonly property int legMs: Marquee.legMs(overflow)')
  eq('both endpoint beats read the shared pause',
    (SL.match(/duration: root\.endpointPauseMs/g) || []).length, 2)
  eq('both travelling legs read the shared duration',
    (SL.match(/duration: root\.legMs/g) || []).length, 2)
})
group('one reset puts the label back at the head', () => {
  contains('reset parks the label at the head', SL, 'label.x = 0')
  eq('every way the question can change calls reset',
    ['onWidthChanged: root.reset()', 'onTextChanged: root.reset()',
      'onScrollingChanged: root.reset()', 'Component.onCompleted: root.reset()']
      .every(s => SL.includes(s)), true)
  contains('a stopped leg also parks at the head', SL, 'onStopped: label.x = 0')
})
group('the former call sites instantiate ScrollLabel instead of hand-rolling', () => {
  eq('three Downloader rows use ScrollLabel',
    (DI.match(/\bScrollLabel \{/g) || []).length, 3)
  eq('three NowPlaying rows use ScrollLabel',
    (NI.match(/\bScrollLabel \{/g) || []).length, 3)
  contains('every Downloader row gates its own scrolling', DI,
    'scrolling: previewPaneInput.overTitle')
  contains('the playlist title gates on hover', DI,
    'scrolling: plTitleHover.hovered')
  contains('the history title gates on hover', DI,
    'scrolling: histTitleHover.hovered')
  contains('the NowPlaying title gates on marqueeEnabled and the copied link', NI,
    'scrolling: root.marqueeEnabled && !root.linkCopied')
  eq('two more NowPlaying rows gate on marqueeEnabled',
    (NI.match(/scrolling: root\.marqueeEnabled$/gm) || []).length, 2)
  eq('the NowPlaying rows keep their zero head pause',
    (NI.match(/startPauseMs: 0/g) || []).length, 3)
  notContains('Downloader no longer reads the timing library itself', DI,
    'Marquee.js')
  notContains('NowPlaying no longer reads the timing library itself', NI,
    'Marquee.js')
})

section('the launcher sub line scrolls only where it is focused')
group('current row marquees, the rest read from the left', () => {
  contains('the launcher reads ScrollLabel from qs.common', LE, 'import qs.common')
  notContains('the launcher no longer imports the timing library itself', LE,
    'Marquee.js')
  eq('one ScrollLabel carries the sub line',
    (LE.match(/\bScrollLabel \{/g) || []).length, 1)
  contains('only the current row may scroll', LE, 'scrolling: subMarquee.current')
  contains('currentness is the view cursor, not a row flag', LE,
    'row.ListView.view.currentIndex === row.index')
  contains('the shared type owns the overflow gate', LE,
    'visible: subText.scrollable')
  contains('an unfocused row elides on the right, keeping its left edge', LE,
    'elide: Text.ElideRight')
  eq('only the title still middle-elides, never the sub',
    (LE.match(/Text\.ElideMiddle/g) || []).length, 1)
})

finish()

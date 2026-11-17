#!/usr/bin/env node
// Suite: marquee - the shared scroll gate.
//
// Scrolling a clipped title is how the full text is read at all. The animation
// setting governs motion, not whether the text can be revealed, so the gate is
// overflow alone. These tests pin that split at the primitive rather than
// relying on every QML caller to remember it.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const M = loadLib(path.join(SHELL, 'common', 'motion', 'Marquee.js'))

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

finish()

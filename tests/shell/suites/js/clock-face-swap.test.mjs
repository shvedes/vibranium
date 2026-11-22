#!/usr/bin/env node
// Suite: the clock's rendered face swap (BAR-13).
//
//   shell/features/bar/modules/Clock/Clock.qml   one animated swap, three derived faces
//
// Limitation: a bar module is a BarModule and cannot be constructed under
// QT_QPA_PLATFORM=offscreen. This suite reads the shipped QML, lifts the
// face derivations by brace matching, and drives them over a swap timeline,
// including the interrupted swap a fast wheel produces. It pins the single
// source and the frames it paints, not the pixels: compositor delivery of
// the wheel events stays source-level only.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, approx, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const CLOCK = fs.readFileSync(path.join(SHELL_DIR, 'features', 'bar', 'modules',
  'Clock', 'Clock.qml'), 'utf8')

// Lift a function body by brace matching and drive it over a swap timeline.
function clockFn(name) {
  const at = CLOCK.indexOf(`function ${name}(`)
  if (at < 0) return ''
  const open = CLOCK.indexOf('{', at)
  let depth = 0
  for (let i = open; i < CLOCK.length; i++) {
    if (CLOCK[i] === '{') depth++
    if (CLOCK[i] === '}' && --depth === 0) return CLOCK.slice(open + 1, i)
  }
  return ''
}
const faceOpacityBody = clockFn('faceOpacity')
const faceYBody = clockFn('faceY')
const beginSwapBody = clockFn('beginSwap')
const faceOpacity = (root, i) => new Function('root', 'i', faceOpacityBody)(root, i)
const faceY = (root, i) => new Function('root', 'i', faceYBody)(root, i)

suite('clock-face-swap', 'BAR-13: one animated swap owns the rendered faces')

section('the single source')
group('one animated scalar drives the rendered faces', () => {
  match('swap is a real with a settled default', CLOCK, /\bproperty real swap:\s*1\b/)
  contains('one animation targets swap', CLOCK, 'property: "swap"')
  match('face opacity derives from swap', faceOpacityBody, /root\.swap/)
  match('face y derives from swap', faceYBody, /root\.swap/)
  match('fromFace is captured once', CLOCK, /\bproperty int fromFace:/)
  match('toFace is declared alongside it', CLOCK, /\bproperty int toFace:/)
  match('one shown-face value is derived from swap', CLOCK, /\breadonly property int shownFace:/)
  match('lastFaceIndex survives as the breaker', CLOCK, /\bproperty int lastFaceIndex:/)
})
group('the swap path has no direct opacity or y writes', () => {
  notMatch('beginSwap never assigns a face opacity', beginSwapBody, /\.opacity\s*=/)
  notMatch('beginSwap never assigns a face y', beginSwapBody, /\.y\s*=/)
  notMatch('no face-layer opacity assignment remains', CLOCK,
    /(?:f|incoming|outgoing|faceAt\([^)]*\))\.opacity\s*=/)
  notMatch('no face-layer y assignment remains', CLOCK,
    /(?:f|incoming|outgoing|faceAt\([^)]*\))\.y\s*=/)
})
group('the preserved contracts are still present', () => {
  contains('the wheel bank is intact', CLOCK, 'property int wheelBank: 0')
  contains('the notch is intact', CLOCK, 'readonly property int wheelNotch: 120')
  contains('the live today derivation is intact', CLOCK, 'property date today: clock.date')
  contains('the clock tick is intact', CLOCK, 'onDateChanged: root.refreshLabel()')
  contains('the cycle latch is intact', CLOCK, 'root.wheelBank = 0')
  contains('the first paint still seeds the layers', CLOCK, 'root.beginSwap(false)')
})

section('the frames over a swap timeline')
group('the three faces follow the one scalar', () => {
  const travel = 20
  const settled = { swap: 1, fromFace: -1, toFace: 0, fromOpacity: 0, fromY: 0, toOpacity: 0, toY: 0, exitY: 0 }
  eq('settled: only the clock face is visible', [0, 1, 2].map(i => faceOpacity(settled, i)), [1, 0, 0])
  eq('settled: every face is at rest', [0, 1, 2].map(i => faceY(settled, i)), [0, 0, 0])

  const s = { swap: 0, fromFace: 0, toFace: 1, fromOpacity: 1, fromY: 0, toOpacity: 0, toY: travel, exitY: -travel }
  eq('start: the outgoing face is still fully visible', faceOpacity(s, 0), 1)
  eq('start: the incoming face is offscreen', faceOpacity(s, 1), 0)
  eq('start: the incoming face sits at the entry offset', faceY(s, 1), travel)
  eq('start: the third face is parked', faceOpacity(s, 2), 0)

  s.swap = 0.5
  eq('mid: the two live faces share the opacity', [faceOpacity(s, 0), faceOpacity(s, 1)], [0.5, 0.5])
  eq('mid: the faces cross on the y axis', [faceY(s, 0), faceY(s, 1)], [-travel / 2, travel / 2])

  s.swap = 1
  eq('end: only the incoming face is visible', [0, 1, 2].map(i => faceOpacity(s, i)), [0, 1, 0])
  eq('end: the outgoing face parked offscreen', faceY(s, 0), -travel)
  eq('end: the incoming face is at rest', faceY(s, 1), 0)
})
group('an interruption interpolates from what is on screen', () => {
  const travel = 20
  // Face 0 was leaving (opacity 0.4) and face 1 arriving (opacity 0.6) when
  // a second wheel step turns 1 into the outgoing face toward 2.
  const s = { swap: 0, fromFace: 1, toFace: 2, fromOpacity: 0.6, fromY: 0.4 * travel, toOpacity: 0, toY: -travel, exitY: travel }
  eq('the reversed face keeps its opacity', faceOpacity(s, 1), 0.6)
  eq('the reversed face keeps its y', faceY(s, 1), 0.4 * travel)
  eq('the abandoned face is parked at zero', faceOpacity(s, 0), 0)
  s.swap = 0.5
  approx('the outgoing face keeps fading out', faceOpacity(s, 1), 0.3)
  approx('the incoming face keeps fading in', faceOpacity(s, 2), 0.5)
  s.swap = 1
  eq('the interruption settles on the new face', [0, 1, 2].map(i => faceOpacity(s, i)), [0, 0, 1])
  eq('and the old outgoing face parked offscreen', faceY(s, 1), travel)
})

finish()

#!/usr/bin/env node
// Suite: inhibitor cycle rule. The core cycle methods are evaluated from the
// real QML source with a stubbed owner, so the bar click and the CLI are
// checked against the same code. No compositor, logind or PAM is involved.
import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

suite('inhibitor-cycle', 'targetSec-based cycling from the real core methods')

const src = fs.readFileSync(path.join(SHELL_DIR, 'services/power/Inhibitor.qml'), 'utf8')

function fn(name) {
  const marker = 'function ' + name + '('
  const at = src.indexOf(marker)
  if (at < 0) throw new Error('no function ' + name)
  const open = src.indexOf('{', at + marker.length)
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return 'function ' + name + '() {' + src.slice(open + 1, i) + '}'
    }
  }
  throw new Error('unbalanced function ' + name)
}

const root = {
  active: false,
  infinite: false,
  targetSec: 0,
  deadlineMs: 0,
  _finiteDurations: [300, 600, 900, 1800],
  start(sec) {
    root.targetSec = sec
    root.active = true
    root.infinite = sec === 0
    return true
  },
  stop() {
    root.active = false
    root.targetSec = 0
    root.infinite = false
    return true
  }
}
const now = { value: 1_000_000 }
const api = new Function('root', 'Date', [
  fn('cycleForward'), fn('cycleBackward'), fn('_remainingValue'),
  'return { cycleForward: cycleForward, cycleBackward: cycleBackward, _remainingValue: _remainingValue }'
].join('\n'))(root, { now: () => now.value })

function reset(seconds = 0, active = false) {
  root.active = active
  root.targetSec = seconds
  root.infinite = active && seconds === 0
  root.deadlineMs = now.value + seconds * 1000
}
function state() {
  return root.active ? (root.infinite ? 'infinite' : root.targetSec) : 'off'
}

section('named cycle chain')

group('forward steps through all names and stops at the tail', () => {
  reset()
  const forward = []
  for (let i = 0; i < 6; i++) { api.cycleForward(); forward.push(state()) }
  eq('off -> 300 -> 600 -> 900 -> 1800 -> infinite -> off', forward.join(' > '),
    '300 > 600 > 900 > 1800 > infinite > off')
})

group('backward steps through all names and stops at the head', () => {
  reset()
  const backward = []
  for (let i = 0; i < 6; i++) { api.cycleBackward(); backward.push(state()) }
  eq('off -> infinite -> 1800 -> 900 -> 600 -> 300 -> off', backward.join(' > '),
    'infinite > 1800 > 900 > 600 > 300 > off')
})

section('custom targets')

group('a custom finite target steps from the live value', () => {
  reset(450, true)
  api.cycleForward()
  eq('450 forward -> 600', state(), 600)
  reset(450, true)
  api.cycleBackward()
  eq('450 backward -> 300', state(), 300)
  reset(2000, true)
  api.cycleForward()
  eq('2000 forward -> infinite', state(), 'infinite')
  reset(2000, true)
  api.cycleBackward()
  eq('2000 backward -> 1800', state(), 1800)
  reset(100, true)
  api.cycleBackward()
  eq('100 backward -> off', state(), 'off')
})

group('the cycle ignores a stale remembered index', () => {
  reset(450, true)
  root.cycleIndex = -1 // a stale value that the old rule would have used
  api.cycleForward()
  eq('computed from targetSec', state(), 600)
})

section('remaining')

group('remaining follows the owner edge', () => {
  reset()
  eq('off is null', api._remainingValue(), null)
  reset(0, true)
  eq('active infinite is 0', api._remainingValue(), 0)
  reset(600, true)
  eq('a fresh finite target is whole seconds', api._remainingValue(), 600)
  now.value += 599_500
  eq('a partial second rounds up', api._remainingValue(), 1)
  now.value += 2000
  eq('past the deadline stays at one until the edge', api._remainingValue(), 1)
})

finish()

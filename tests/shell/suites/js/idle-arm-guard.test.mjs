#!/usr/bin/env node
// Suite: idle-arm-guard - no timer can be armed without a positive seconds value.
//
// The regression: a settings read path that published canonical `seconds`
// rows met a daemon that still computed `t.minutes * 60`. undefined * 60 is
// NaN, which a QML int timeout coerces to 0. An IdleMonitor with timeout 0
// reports idle on its first event, so the shipped suspend command ran within
// a second of boot or an unlock. This suite drives the daemon's own arm
// helper and its fire() guard with mixed and malformed rows, and checks the
// source never derives a threshold from a missing minutes field.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const SL = loadLib(path.join(SHELL_DIR, 'common/settings/SettingsLib.js'))
const daemon = fs.readFileSync(path.join(SHELL_DIR, 'services/session/IdleDaemon.qml'), 'utf8')

suite('idle-arm-guard', 'a missing or non-positive seconds field can never arm a timer')

section('source')

group('the daemon never reads a legacy minutes field', () => {
  eq('no t.minutes expression remains', /t\.minutes/.test(daemon), false)
  eq('no minutes conversion remains', /minutes\s*\*\s*60/.test(daemon), false)
  eq('the arm guard exists', /function _armTimeout\(/.test(daemon), true)
  eq('fire consults the guard', /_armTimeout\(row\)\s*<\s*0/.test(daemon), true)
})

section('arm helper')

// Lift _armTimeout from the real source so the test measures the shipped code.
const fnSource = (() => {
  const at = daemon.indexOf('function _armTimeout(row)')
  if (at < 0) return ''
  const open = daemon.indexOf('{', at)
  let depth = 0
  for (let i = open; i < daemon.length; i++) {
    if (daemon[i] === '{') depth++
    else if (daemon[i] === '}') {
      depth--
      if (depth === 0) return daemon.slice(at, i + 1)
    }
  }
  return ''
})()
const armTimeout = new Function(fnSource + '\nreturn _armTimeout')()

group('canonical seconds rows are armed', () => {
  eq('600 seconds', armTimeout({ seconds: 600 }), 600)
  eq('900 seconds', armTimeout({ seconds: 900 }), 900)
  eq('1 second', armTimeout({ seconds: 1 }), 1)
})

group('mixed and malformed rows are refused', () => {
  eq('legacy minutes only', armTimeout({ minutes: 10 }), -1)
  eq('missing field', armTimeout({ action: 'lock' }), -1)
  eq('both fields are ambiguous and refused', armTimeout({ seconds: 600, minutes: 10 }), -1)
  eq('zero', armTimeout({ seconds: 0 }), -1)
  eq('negative', armTimeout({ seconds: -600 }), -1)
  eq('fractional', armTimeout({ seconds: 0.5 }), -1)
  eq('infinite', armTimeout({ seconds: Infinity }), -1)
  eq('string', armTimeout({ seconds: '600' }), -1)
  eq('null row', armTimeout(null), -1)
})

section('read path')

group('the settings read path always produces canonical seconds', () => {
  const legacy = [
    { minutes: 10, action: 'command', command: 'vb-shell session lock', commandClass: 'lock' },
    { minutes: 15, action: 'command', command: 'vb-shell session suspend', commandClass: 'suspend' }
  ]
  eq('legacy rows validate', SL.validateIdleTimers(legacy), '')
  const canonical = SL.normalizeIdleTimers(legacy)
  eq('both rows armed with whole minutes converted to seconds',
    canonical.map(t => armTimeout(t)), [600, 900])
  eq('no legacy field survives', canonical.every(t => t.minutes === undefined), true)
})
finish()

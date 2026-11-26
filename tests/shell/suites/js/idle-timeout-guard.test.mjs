#!/usr/bin/env node
// Suite: idle-timeout-guard - no malformed or half-migrated timer row may arm
// an idle monitor at zero. The suspend shipped timers are commands; a monitor
// whose timeout is undefined/NaN/0 reports idle on its first event and runs
// `vb-shell session suspend` within a fraction of a second of boot or unlock.
//
// This suite lifts the real _setRows and _armTimeout from IdleDaemon.qml and
// drives them with stubs, including a row in the old minutes-only shape that
// the seconds migration can leave in a user's file. It asserts that such a row
// is refused, not coerced into an immediate fire, and that a canonical seconds
// row reaches the compositor with an unchanged positive threshold.
import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const src = fs.readFileSync(path.join(SHELL_DIR, 'services/session/IdleDaemon.qml'), 'utf8')

function lift(name) {
  const m = new RegExp('function\\s+' + name + '\\s*\\([^)]*\\)\\s*\\{').exec(src)
  if (!m) throw new Error('no function ' + name)
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < src.length; end++) {
    if (src[end] === '{') depth++
    else if (src[end] === '}') { depth--; if (depth === 0) { end++; break } }
  }
  return src.slice(m.index, end)
}

function machine(warnings) {
  const monitors = []
  const root = {
    enabled: true,
    epoch: 7,
    timers: [],
    _monitors: [],
    _activity: null,
    _armTimeout: null
  }
  const monitorComp = {
    createObject(_parent, props) {
      monitors.push(props)
      return { destroy() {} }
    }
  }
  const settleWatch = { stop() { warnings.push('settleStop') }, restart() {} }
  const activityComp = { createObject() { root._activity = { destroy() {} }; return root._activity } }
  const Log = { at() { return { warn(m) { warnings.push('warn:' + m) } } } }
  const fns = new Function('root', 'monitorComp', 'activityComp', 'settleWatch', 'Log',
    lift('_armTimeout') + '\n' + lift('_setRows') +
    '\nroot._armTimeout = _armTimeout\nreturn { _setRows, _armTimeout }')(
      root, monitorComp, activityComp, settleWatch, Log)
  return { root, monitors, ...fns }
}

suite('idle-timeout-guard', 'a malformed timer never arms an immediate idle monitor')

section('resolving an arm threshold')
group('only a finite positive integer seconds value is admissible', () => {
  const s = machine([])
  eq('canonical seconds', s._armTimeout({ seconds: 600, action: 'command' }), 600)
  eq('one second is legal', s._armTimeout({ seconds: 1, action: 'lock' }), 1)
  for (const bad of [
    { minutes: 10, action: 'command', command: 'x' },
    { action: 'command', command: 'x' },
    { seconds: 0, action: 'command', command: 'x' },
    { seconds: -5, action: 'command', command: 'x' },
    { seconds: 1.5, action: 'command', command: 'x' },
    { seconds: NaN, action: 'command', command: 'x' },
    { seconds: Infinity, action: 'command', command: 'x' },
    { seconds: '600', action: 'command', command: 'x' },
    null,
    undefined
  ]) {
    eq('refused: ' + JSON.stringify(bad), s._armTimeout(bad) < 0, true)
  }
})

section('arming from a canonical schedule')
group('a shipped seconds row keeps its threshold', () => {
  const warnings = []
  const s = machine(warnings)
  s.root.timers = [
    { seconds: 600, action: 'command', command: 'vb-shell session lock', commandClass: 'lock' },
    { seconds: 900, action: 'command', command: 'vb-shell session suspend', commandClass: 'suspend' }
  ]
  s._setRows()
  eq('both monitors armed', s.monitors.length, 2)
  eq('first threshold', s.monitors[0].timeout, 600)
  eq('second threshold', s.monitors[1].timeout, 900)
  eq('row indices preserved', s.monitors.map(m => m.rowIndex).join(','), '0,1')
  eq('no refusal', warnings.filter(w => w.startsWith('warn:')).length, 0)
})

group('a legacy minutes row cannot produce a zero threshold', () => {
  const warnings = []
  const s = machine(warnings)
  s.root.timers = [{ minutes: 15, action: 'command', command: 'vb-shell session suspend' }]
  s._setRows()
  eq('nothing armed', s.monitors.length, 0)
  eq('the row was refused', warnings.filter(w => w.startsWith('warn:')).length, 1)
  eq('an activity monitor is still armed', s.root._activity !== null, true)
})

group('mixed schedules refuse only the bad row', () => {
  const warnings = []
  const s = machine(warnings)
  s.root.timers = [
    { minutes: 10, action: 'command', command: 'vb-shell session lock' },
    { seconds: 900, action: 'command', command: 'vb-shell session suspend' }
  ]
  s._setRows()
  eq('one monitor armed', s.monitors.length, 1)
  eq('the canonical threshold survives', s.monitors[0].timeout, 900)
  eq('one refusal', warnings.filter(w => w.startsWith('warn:')).length, 1)
  eq('the armed row keeps its displayed index', s.monitors[0].rowIndex, 1)
})

finish()

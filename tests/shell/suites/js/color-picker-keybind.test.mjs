#!/usr/bin/env node
// Suite: the color-pick keybind works without its statusbar module
// (gateway fallback owner).
//
//   shell/features/bar/Bar.qml          the gateway verbs and the fallback slot
//   shell/features/bar/BarView.qml      the headless engine's real window
//   shell/features/bar/modules/ColorPicker/ColorPicker.qml
//
// A live IpcHandler needs a running shell, so this suite lifts the owner
// methods from the shipped QML by brace matching and drives them with a stub
// root. It pins the contract: `pick` prefers the loaded module when there is
// one, otherwise falls back to the headless engine, a duplicate pick while
// active does not restart capture, and `close` cancels the ACTIVE picker.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, contains, notContains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const BAR = read('features', 'bar', 'Bar.qml')
const BARVIEW = read('features', 'bar', 'BarView.qml')
const MODULE = read('features', 'bar', 'modules', 'ColorPicker', 'ColorPicker.qml')
const CATALOG = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))

function bracedBody(src, firstBrace, label) {
  let depth = 0
  for (let i = firstBrace; i < src.length; i++) {
    if (src[i] === '{') depth++
    if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(firstBrace + 1, i)
    }
  }
  throw new Error(`${label} body never closes`)
}

function functionBody(src, name, from = 0) {
  const at = src.indexOf(`function ${name}(`, from)
  if (at < 0) return ''
  return bracedBody(src, src.indexOf('{', at), name)
}

const PICK = functionBody(BAR, 'ipcPickColor')
const CLOSE = functionBody(BAR, 'ipcCloseColorPick')
const STATUS = functionBody(BAR, 'ipcColorStatus')
const CLAIM = functionBody(BAR, 'claimActivePicker')

const BarIpc = {
  ok: data => ({ v: 1, ok: true, data }),
  silent: () => ({ v: 1, ok: true }),
  fail: (code, message) => ({ v: 1, ok: false, error: { code, message } }),
}

function run(body, root, extra = {}) {
  return new Function('root', 'BarIpc', 'Ui', ...Object.keys(extra), body)(
    root, BarIpc, { primaryScreen: { name: 'eDP-1' } },
    ...Object.values(extra))
}

function stubPicker(result, calls, name, screenName = '') {
  return {
    name,
    beginPick() { calls.push(name); return result },
    cancelPick() { calls.push(name + ':cancel') },
    pickScreen: screenName ? { name: screenName } : null,
    barScreen: null,
    _pickGen: result ? 7 : 0,
  }
}

function rootFor(owner, fallback, active = null) {
  return { _pickerOwner: owner, _pickerFallback: fallback, _activePicker: active }
}

suite('color-picker-keybind', 'the pick verb works with no statusbar module')

section('the verbs are lifted from the gateway owner')
group('scope', () => {
  contains('pick is lifted', PICK, 'beginPick()')
  contains('close is lifted', CLOSE, 'cancelPick()')
  contains('status is lifted', STATUS, 'available:')
  contains('a duplicate pick is a no-op', PICK, 'if (root._activePicker)')
  notContains('no dead-end native error', PICK, 'error: no screen to pick on')
})

section('pick delegates to a live picker')
group('module owner', () => {
  const calls = []
  const owner = stubPicker(true, calls, 'owner')
  const fallback = stubPicker(true, calls, 'fallback')
  eq('a loaded module wins silently', 'data' in run(PICK, rootFor(owner, fallback)), false)
  eq('only the owner was asked', calls.join(','), 'owner')
})
group('headless fallback (module disabled)', () => {
  const calls = []
  const fallback = stubPicker(true, calls, 'fallback')
  eq('the keybind still starts a pick silently',
    'data' in run(PICK, rootFor(null, fallback)), false)
  eq('the engine was asked', calls.join(','), 'fallback')
})
group('no screen', () => {
  const calls = []
  const fallback = stubPicker(false, calls, 'fallback')
  const verdict = run(PICK, rootFor(null, fallback))
  eq('a refused pick is unavailable', verdict.error.code, 'unavailable')
  eq('the engine was asked', calls.join(','), 'fallback')
})
group('nothing at all', () => {
  const verdict = run(PICK, rootFor(null, null))
  eq('a missing fallback is a clean error', verdict.error.code, 'unavailable')
})
group('duplicate pick', () => {
  const calls = []
  const owner = stubPicker(true, calls, 'owner')
  const verdict = run(PICK, rootFor(owner, null, owner))
  eq('an active pick is unchanged and silent', 'data' in verdict, false)
  eq('capture was not restarted', calls.join(','), '')
})

section('close cancels the ACTIVE picker only')
group('owner and active differ', () => {
  const calls = []
  const owner = stubPicker(true, calls, 'owner')
  const active = stubPicker(true, calls, 'active')
  eq('close is a silent no-op', 'data' in run(CLOSE, rootFor(owner, null, active)), false)
  eq('the active picker was cancelled', calls.join(','), 'active:cancel')
})
group('nothing active', () => {
  const calls = []
  const owner = stubPicker(true, calls, 'owner')
  eq('close reports unchanged silently',
    'data' in run(CLOSE, rootFor(owner, null)), false)
  eq('nobody was cancelled', calls.join(','), '')
})

section('status reports a reachable picker')
group('health', () => {
  const fallback = stubPicker(true, [], 'fallback', 'HDMI-A-1')
  eq('available with only the engine', run(STATUS, rootFor(null, fallback)).data.available, true)
  eq('not picking until a module stamps itself',
    run(STATUS, rootFor(null, fallback)).data.picking, false)
  eq('the screen is reported', run(STATUS, rootFor(null, fallback)).data.screen, 'HDMI-A-1')
  eq('no picker is unavailable', run(STATUS, rootFor(null, null)).data.available, false)
})

section('the CLI completion query is retired')
group('no result row or owner state survives', () => {
  eq('the catalog has no result row', CATALOG.findRow('colorPicker.result'), null)
  notContains('the owner registers no result closure', BAR, '"colorPicker.result"')
  notContains('no completion record slot', BAR, '_colorPickResult')
  notContains('no completion function', BAR, 'ipcColorPickResult')
  notContains('the module stamps no completion', MODULE, 'noteColorPick')
  notContains('pick publishes no completion id', PICK, 'generation')
})

section('claim retires a previous picker before stamping a new one')
group('claim', () => {
  const calls = []
  const previous = stubPicker(true, calls, 'previous')
  const next = stubPicker(true, calls, 'next')
  const root = rootFor(next, null, previous)
  eq('claim accepts a picker', run(CLAIM, root, { picker: next }), true)
  eq('the previous picker was cancelled', calls.join(','), 'previous:cancel')
})

section('the engine lives in a real window and does not steal the owner')
group('wiring', () => {
  contains('BarView is a real surface', BARVIEW, 'LayerSurface {')
  const loaderAt = BARVIEW.indexOf('Loader {')
  const loader = bracedBody(BARVIEW, BARVIEW.indexOf('{', loaderAt), 'engine loader')
  contains('a ColorPicker engine is declared in BarView', loader, 'ColorPicker {')
  contains('the engine loader is gated to the primary screen', loader,
    'active: win.screen === Ui.primaryScreen')
  contains('the engine registers as the fallback owner', loader,
    'Bar.registerFallbackPicker(pickerEngine)')
  contains('the engine releases the fallback on teardown', loader,
    'Bar.unregisterFallbackPicker(pickerEngine)')
  eq('the engine never sets barScreen', loader.includes('barScreen:'), false)
  contains('Bar exposes the fallback slot', BAR, 'property Item _pickerFallback: null')
  contains('Bar exposes the active picker slot', BAR, 'property var _activePicker: null')
  contains('Bar accepts a fallback registration', BAR,
    'function registerFallbackPicker(m: Item)')
  contains('the module owner still needs a real barScreen', MODULE,
    'readonly property bool _ipcOwner: root.barScreen !== null')
  contains('the module stamps the active picker', MODULE, 'Bar.claimActivePicker(root)')
  contains('teardown clears the active picker', MODULE, 'Bar.clearActivePicker(root)')
})

finish()

#!/usr/bin/env node
// Suite: the color-pick keybind works without its statusbar module
// (IPC fallback owner).
//
//   shell/features/bar/Bar.qml          the IPC verbs and the fallback slot
//   shell/features/bar/BarView.qml      the headless engine's real window
//   shell/features/bar/modules/ColorPicker/ColorPicker.qml
//
// A live IpcHandler needs a running shell, so this suite lifts the two verbs
// from the shipped QML by brace matching and drives them with a stub root.
// It pins the contract: `pick` prefers the loaded module when there is one,
// otherwise falls back to the headless engine, and never reports "no picker
// module loaded" as a dead end.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, contains, notContains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const BAR = read('features', 'bar', 'Bar.qml')
const BARVIEW = read('features', 'bar', 'BarView.qml')
const MODULE = read('features', 'bar', 'modules', 'ColorPicker', 'ColorPicker.qml')

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

// Scope the verbs to the colorPicker handler: Bar.qml hosts other IpcHandlers
// with their own status().
const targetAt = BAR.indexOf('target: "colorPicker"')
const handlerAt = BAR.lastIndexOf('IpcHandler {', targetAt)
const HANDLER = bracedBody(BAR, BAR.indexOf('{', handlerAt), 'IpcHandler')
const PICK = functionBody(HANDLER, 'pick')
const STATUS = functionBody(HANDLER, 'status')

function run(body, root) {
  return new Function('root', body)(root)
}

function stubPicker(result, calls, name) {
  return {
    name,
    beginPick() {
      calls.push(name)
      return result
    }
  }
}

function rootFor(owner, fallback) {
  return { _pickerOwner: owner, _pickerFallback: fallback }
}

suite('color-picker-keybind', 'the pick verb works with no statusbar module')

section('the verb source is lifted from the right handler')
group('scope', () => {
  contains('the colorPicker target is present', HANDLER, 'target: "colorPicker"')
  contains('pick is lifted', PICK, 'beginPick()')
  contains('status is lifted', STATUS, 'healthy')
  notContains('pick has no dead-end error', PICK, 'no picker module loaded')
})

section('pick delegates to a live picker')
group('module owner', () => {
  const calls = []
  const owner = stubPicker(true, calls, 'owner')
  const fallback = stubPicker(true, calls, 'fallback')
  eq('a loaded module wins', run(PICK, rootFor(owner, fallback)), 'ok')
  eq('only the owner was asked', calls.join(','), 'owner')
})
group('headless fallback (module disabled)', () => {
  const calls = []
  const fallback = stubPicker(true, calls, 'fallback')
  eq('the keybind still starts a pick', run(PICK, rootFor(null, fallback)), 'ok')
  eq('the engine was asked', calls.join(','), 'fallback')
})
group('no screen', () => {
  const calls = []
  const fallback = stubPicker(false, calls, 'fallback')
  eq('a refused pick is reported', run(PICK, rootFor(null, fallback)), 'error: no screen to pick on')
  eq('the engine was asked', calls.join(','), 'fallback')
})
group('nothing at all', () => {
  eq('a missing fallback is a clean error', run(PICK, rootFor(null, null)),
    'error: no picker available')
})

section('status reports a reachable picker')
group('health', () => {
  const fallback = stubPicker(true, [], 'fallback')
  const alive = JSON.parse(run(STATUS, rootFor(null, fallback)))
  eq('healthy with only the engine', alive.healthy, true)
  eq('unit is still colorPicker', alive.unit, 'colorPicker')
})

section('the engine lives in a real window and does not steal the owner')
group('wiring', () => {
  // The sampler is a Canvas: a pick cannot commit unless its onPaint runs,
  // and that needs a window scene graph. A Singleton child registers and
  // maps the overlay but never paints, so the engine belongs in BarView.
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
  // No barScreen is assigned to the engine, so ColorPicker._ipcOwner stays
  // false and beginPick() falls back to Ui.primaryScreen.
  eq('the engine never sets barScreen', loader.includes('barScreen:'), false)
  contains('Bar exposes the fallback slot', BAR, 'property Item _pickerFallback: null')
  contains('Bar accepts a fallback registration', BAR,
    'function registerFallbackPicker(m: Item)')
  contains('the module owner still needs a real barScreen', MODULE,
    'readonly property bool _ipcOwner: root.barScreen !== null')
})

finish()

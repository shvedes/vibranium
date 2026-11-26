#!/usr/bin/env node
// Suite: launcher gateway QoL contracts - `history is-empty` means empty,
// actions are silent successes, and branch rows are bare nouns.
import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, contains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = (await import('../../lib/qmlloader.mjs')).loadLib(
  path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const SRC = fs.readFileSync(path.join(SHELL_DIR, 'features/launcher/AppLauncher.qml'), 'utf8')

function body(name) {
  const at = SRC.indexOf(`function ${name}(`)
  if (at < 0) return ''
  let depth = 0
  for (let i = SRC.indexOf('{', at); i < SRC.length; i++) {
    if (SRC[i] === '{') depth++
    if (SRC[i] === '}') {
      depth--
      if (depth === 0) return SRC.slice(SRC.indexOf('{', at) + 1, i)
    }
  }
  return ''
}

function run(name, root, extra = {}) {
  const ok = data => (data === undefined ? { v: 1, ok: true } : { v: 1, ok: true, data })
  const err = (code, message) => ({ v: 1, ok: false, error: { code, message } })
  const args = Object.keys(extra)
  return new Function('root', 'LauncherLib', '_ok', '_error', 'id', ...args, body(name))(
    root,
    {
      usageHistoryEmpty: (has, map) => !has && Object.keys(map || {}).length === 0
    },
    ok, err, extra.id === undefined ? null : extra.id,
    ...args.map(key => extra[key]))
}

suite('launcher-gateway-qol', 'empty history, silent reloads and bare branch nouns')

section('history is-empty')
group('verdict is inverted from the old hasHistory', () => {
  const empty = { usageKnown: true, hasUsageHistory: false, usageMap: {} }
  const full = { usageKnown: true, hasUsageHistory: true, usageMap: { a: 1 } }
  const unknown = { usageKnown: false, hasUsageHistory: false, usageMap: {} }
  eq('empty history is true', run('_historyGateway', empty).data, true)
  eq('populated history is false', run('_historyGateway', full).data, false)
  eq('unknown history stays unavailable', run('_historyGateway', unknown).error.code, 'unavailable')
})

section('reload is silent')
group('success and no-op return no data', () => {
  const base = { pluginsKnown: true, _knownPlugin: () => true }
  const ok = { ok: true, ids: ['calc'], failed: [] }
  const ctrl = {
    _demandTransient: () => ({ reloadPlugins: () => ok, pluginStatus: () => ({ enabled: true }) })
  }
  const bulk = run('_pluginsReload', Object.assign({}, base, ctrl), {})
  const one = run('_pluginsReload', Object.assign({}, base, ctrl, {
    _knownPlugin: id => id === 'calc'
  }), { id: 'calc' })
  eq('bulk reload has no data', 'data' in bulk, false)
  eq('single reload has no data', 'data' in one, false)
  const noopCtrl = {
    _demandTransient: () => ({ pluginStatus: () => ({ enabled: false }) })
  }
  const noop = run('_pluginsReload', Object.assign({}, base, noopCtrl, {
    _knownPlugin: id => id === 'calc'
  }), { id: 'calc' })
  eq('disabled no-op has no data', 'data' in noop, false)
  const failedCtrl = {
    _demandTransient: () => ({ reloadPlugins: () => ({ ok: false, failed: ['calc'] }) })
  }
  const failed = run('_pluginsReload', Object.assign({}, base, failedCtrl), {})
  eq('a failure keeps its diagnostic', failed.error.code, 'backend')
  eq('catalog bulk reload is silent', C.findRow('appLauncher.plugin.reload').output.kind, 'none')
  eq('catalog single reload is silent', C.findRow('appLauncher.plugin.id.reload').output.kind, 'none')
})

section('panel and plugin actions are silent')
group('success carries no data', () => {
  const pendingOpen = { visible: false, _openWaiting: false, controllerState: 'ready',
    open() { this._openWaiting = true } }
  eq('pending open has no data', 'data' in run('_openGateway', pendingOpen), false)
  const pendingToggle = { visible: false, _openWaiting: false,
    toggle() { this._openWaiting = true } }
  eq('pending toggle has no data', 'data' in run('_toggleGateway', pendingToggle), false)
  const pluginRoot = { pluginsKnown: true, _knownPlugin: () => true,
    _demandTransient: () => ({ setPluginEnabled: () => true }) }
  eq('enable has no data',
    'data' in run('_pluginEnable', pluginRoot, { id: 'calc', enabled: true }), false)
  eq('disable has no data',
    'data' in run('_pluginEnable', pluginRoot, { id: 'calc', enabled: false }), false)
  for (const id of ['appLauncher.open', 'appLauncher.close', 'appLauncher.toggle',
    'appLauncher.plugin.enable', 'appLauncher.plugin.disable',
    'appLauncher.plugin.toggle']) {
    eq(`${id} is silent`, C.findRow(id).output.kind, 'none')
  }
})

section('branch rows are bare nouns')
group('no optional placeholders', () => {
  for (const id of ['appLauncher.history', 'appLauncher.plugin', 'appLauncher.plugin']) {
    eq(`${id} has one literal word`, C.findRow(id).words.length, 1)
    eq(`${id} keeps its examples`, C.findRow(id).examples.length > 0, true)
  }
  contains('history branch still documented', SRC, '"appLauncher.history.is-empty"')
})

finish()

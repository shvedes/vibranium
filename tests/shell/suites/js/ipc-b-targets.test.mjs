#!/usr/bin/env node
// Suite: 01B catalog rows - the app, appLauncher and audio gateway commands.
// Pure records and the shared grammar: no Qt engine and no live shell. The
// plugin half evaluates the shipped built-ins in the qmlloader harness and
// checks that their named ipc closures exist and return typed values.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib, loadPlugin } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const L = loadLib(path.join(SHELL_DIR, 'features/launcher/LauncherLib.js'))

suite('ipc-b-targets', 'typed app, launcher and audio gateway rows')

section('catalog shape')

group('the three B targets exist with complete metadata', () => {
  for (const id of ['app', 'appLauncher', 'audio']) {
    const t = C.findTarget(id)
    eq(`${id}: target`, t !== null, true)
    for (const r of t.rows.filter(r => r.route === 'gateway')) {
      eq(`${r.id}: summary or parent label`,
        (typeof r.summary === 'string' && r.summary.length > 0)
        || (typeof r.labelSummary === 'string' && r.labelSummary.length > 0), true)
      eq(`${r.id}: output`, r.output && typeof r.output.kind === 'string', true)
      eq(`${r.id}: notes`, Array.isArray(r.notes), true)
      eq(`${r.id}: examples`, Array.isArray(r.examples) && r.examples.length > 0, true)
      eq(`${r.id}: grammar compiles`, P.compile(r.words).ok, true)
    }
  }
})

group('fixed allowlists and no generic dispatch', () => {
  eq('app ids are an explicit two-app list', L.builtinIpcVerbs('unknown'), [])
  eq('every built-in id has a fixed verb set', L.builtinIpcVerbs('time'), ['lookup', 'convert'])
  eq('binary has no feature verbs', L.builtinIpcVerbs('binary'), [])
  eq('the generic app call row is presentation only', C.findRow('app.call').helpOnly, true)
  eq('the generic app call row is not dispatchable', C.publicRowIds().includes('app.call'), false)
})

section('argument grammar')

function match(id, argv) {
  const row = C.findRow(id)
  eq(`${id}: row`, row !== null, true)
  return P.match(row.words, argv)
}

group('apps', () => {
  eq('app open validates the enum', match('app.open', ['open', 'audioMixer']).args.ID, 'audioMixer')
  eq('a misspelled app is refused', match('app.open', ['open', 'AudioMixer']).ok, false)
  eq('close consumes every id in order',
    match('app.close', ['close', 'audioMixer', 'imageViewer']).args.ID,
    ['audioMixer', 'imageViewer'])
  eq('call list keeps its fixed keyword', match('app.call.list', ['call', 'list', 'imageViewer']).ok, true)
  eq('openPath takes the path as one ref',
    match('app.call.imageViewer.openPath', ['call', 'imageViewer', 'openPath', '/a b.png']).args.PATH,
    '/a b.png')
  eq('openTab validates the five tabs',
    match('app.call.audioMixer.openTab', ['call', 'audioMixer', 'openTab', 'graph']).ok, true)
  eq('an unknown tab is refused',
    match('app.call.audioMixer.openTab', ['call', 'audioMixer', 'openTab', 'other']).ok, false)
})

group('audio steps and setters', () => {
  eq('bare volume up', match('audio.volume.up', ['volume', 'up']).ok, true)
  eq('explicit step keyword', match('audio.volume.up', ['volume', 'up', 'step', '10']).args.N, 10)
  eq('bare number is not an explicit step', match('audio.volume.up', ['volume', 'up', '10']).ok, false)
  eq('a fractional step is refused', match('audio.volume.up', ['volume', 'up', 'step', '1.5']).ok, false)
  eq('an over-cap step is refused', match('audio.volume.up', ['volume', 'up', 'step', '201']).ok, false)
  eq('the old flat set spellings are not dispatchable',
    C.publicRowIds().filter(id => /^audio\.set\./.test(id) || id === 'audio.set'), [])
  eq('volume set', match('audio.volume.set', ['volume', 'set', '80']).args.N, 80)
  eq('microphone set', match('audio.microphone.set', ['microphone', 'set', '0']).args.N, 0)
  eq('stream set', match('audio.stream.set', ['stream', 'n1.2', 'set', '75']).args.N, 75)
  eq('stream mute', match('audio.stream.mute', ['stream', 'n1.2', 'mute', 'true']).args.BOOL, true)
  eq('stream route', match('audio.stream.route', ['stream', 'n1.2', 'route', 'n1.4']).args.DEVICE, 'n1.4')
  eq('stream route takes optional verbose', match('audio.stream.route',
    ['stream', 'n1.2', 'route', 'n1.4', 'verbose']).ok, true)
  eq('a wrong stream verb is refused', match('audio.stream.set', ['stream', 'n1.2', 'mute', 'true']).ok, false)
})

group('launcher', () => {
  eq('plugins list', match('appLauncher.plugin.list', ['plugin', 'list']).ok, true)
  eq('plugin status', match('appLauncher.plugin.status', ['plugin', 'calc', 'status']).args.ID, 'calc')
  eq('plugin enable', match('appLauncher.plugin.enable', ['plugin', 'calc', 'enable']).ok, true)
  eq('plugin reload', match('appLauncher.plugin.id.reload', ['plugin', 'calc', 'reload']).ok, true)
  eq('bulk reload is not a plugin id', match('appLauncher.plugin.reload', ['plugin', 'reload']).ok, true)
  eq('built-in command', match('appLauncher.plugin.command.calc.eval', ['plugin', 'command', 'calc', 'eval', '2+2']).args.EXPR, '2+2')
  eq('empty query is refused', match('appLauncher.plugin.command.websearch.url', ['plugin', 'command', 'websearch', 'url', '']).ok, false)
})

group('launcher history spellings', () => {
  eq('history is-empty', match('appLauncher.history.is-empty', ['history', 'is-empty']).ok, true)
  eq('history show', match('appLauncher.history.show', ['history', 'show']).ok, true)
  eq('history clear', match('appLauncher.history.clear', ['history', 'clear']).ok, true)
  const retired = ['hasHistory', 'showHistory', 'clearHistory', 'rescanApps', 'rescan']
  for (const id of retired) {
    eq(`${id}: no catalog row`, C.findRow('appLauncher.' + id), null)
    eq(`${id}: no public verb`, C.topLevelVerbs('appLauncher').includes(id), false)
  }
})

group('audio device and microphone spellings', () => {
  eq('sink list', match('audio.sink.list', ['sink', 'list']).ok, true)
  eq('sink set', match('audio.sink.set', ['sink', 'set', 'n1.2']).args.ID, 'n1.2')
  eq('source list', match('audio.source.list', ['source', 'list']).ok, true)
  eq('source set', match('audio.source.set', ['source', 'set', 'n1.3']).args.ID, 'n1.3')
  eq('microphone up', match('audio.microphone.up', ['microphone', 'up', 'step', '10']).args.N, 10)
  eq('microphone down', match('audio.microphone.down', ['microphone', 'down']).ok, true)
  eq('microphone toggle', match('audio.microphone.toggle', ['microphone', 'toggle']).ok, true)
  eq('volume toggle', match('audio.volume.toggle', ['volume', 'toggle']).ok, true)
  eq('volume get', match('audio.volume.get', ['volume', 'get']).ok, true)
  eq('microphone get', match('audio.microphone.get', ['microphone', 'get']).ok, true)
  for (const id of ['audio.volume.get', 'audio.microphone.get']) {
    eq(`${id}: typed record output`, C.findRow(id).output.kind, 'record')
    eq(`${id}: has an example`, C.findRow(id).examples.length > 0, true)
  }
  const audioSrc = fs.readFileSync(path.join(SHELL_DIR, 'services/audio/Audio.qml'), 'utf8')
  const getter = audioSrc.slice(audioSrc.indexOf('function _getLevel('),
    audioSrc.indexOf('function _toggleMute('))
  eq('get uses the existing level projection', getter.includes('Ipc.levelOf(device)'), true)
  eq('get performs no write', /setSinkVolume|setSourceVolume|setSinkMuted|setSourceMuted/.test(getter), false)
  eq('get shows no OSD', /_showSinkOSD|_showSourceOSD/.test(getter), false)
  eq('get demands no controller', /_demand|openController/.test(getter), false)
  const retired = ['volumeUp', 'volumeDown', 'volumeToggle', 'micUp', 'micDown', 'micToggle',
    'sinks', 'sources', 'setDefault.sink', 'setDefault.source']
  for (const id of retired) {
    eq(`${id}: no catalog row`, C.findRow('audio.' + id), null)
  }
})

section('per-plugin help table')

group('the eight built-in ids each have a discoverable, side-effect-free page', () => {
  const ids = ['calc', 'unit', 'constants', 'color', 'time', 'fx', 'websearch', 'binary']
  eq('table keys', Object.keys(L.BUILTIN_PLUGIN_HELP).sort(), [...ids].sort())
  for (const id of ids) {
    const page = L.pluginHelpPage(id)
    eq(`${id}: page`, page !== null, true)
    eq(`${id}: usage`, page.usage, `vb-shell appLauncher plugin command ${id}`)
    eq(`${id}: has a concrete example`, page.examples.length > 0, true)
    eq(`${id}: points at plugins list`, page.notes.some(n => n.includes('vb-shell appLauncher plugin list')), true)
    eq(`${id}: examples point at plugins list`, page.examples.includes('vb-shell appLauncher plugin list'), true)
    for (const c of page.commands) {
      eq(`${c.id}: documents its argument`, c.arguments.length > 0, true)
      eq(`${c.id}: argument summary`, typeof c.arguments[0].summary === 'string' && c.arguments[0].summary.length > 0, true)
      eq(`${c.id}: usage has a placeholder`, /<[A-Z_]+>/.test(c.usage), true)
      eq(`${c.id}: has a concrete example`, c.examples.some(e => e.includes('vb-shell appLauncher plugin command ')), true)
    }
  }
  eq('unknown id has no fabricated page', L.pluginHelpPage('nope'), null)
  eq('non-string id has no page', L.pluginHelpPage(undefined), null)
  eq('binary has no feature commands', L.pluginHelpPage('binary').commands, [])
})

group('exact documented spellings still match their rows', () => {
  const forms = [
    ['appLauncher.plugin.command.calc.eval', ['plugin', 'command', 'calc', 'eval', '5+5']],
    ['appLauncher.plugin.command.unit.convert', ['plugin', 'command', 'unit', 'convert', '1 light years']],
    ['appLauncher.plugin.command.constants.lookup', ['plugin', 'command', 'constants', 'lookup', 'speed of light']],
    ['appLauncher.plugin.command.color.parse', ['plugin', 'command', 'color', 'parse', '#ff8800']],
    ['appLauncher.plugin.command.time.lookup', ['plugin', 'command', 'time', 'lookup', 'Berlin']],
    ['appLauncher.plugin.command.time.convert', ['plugin', 'command', 'time', 'convert', '7:55pm cst']],
    ['appLauncher.plugin.command.fx.convert', ['plugin', 'command', 'fx', 'convert', '1 USD to EUR']],
    ['appLauncher.plugin.command.websearch.url', ['plugin', 'command', 'websearch', 'url', 'shell ipc']]
  ]
  for (const [id, argv] of forms) eq(`${id}: matches`, match(id, argv).ok, true)
  eq('a wrong plugin is not a documented form',
    match('appLauncher.plugin.command.calc.eval', ['plugin', 'command', 'color', 'eval', '5+5']).ok, false)
  eq('a wrong verb is not a documented form',
    match('appLauncher.plugin.command.calc.eval', ['plugin', 'command', 'calc', 'parse', '5+5']).ok, false)
})

group('parent pages collapse the individual commands', () => {
  const t = C.findTarget('appLauncher')
  const generic = C.findRow('appLauncher.plugin')
  eq('generic plugin row exists', generic !== null, true)
  eq('generic plugin usage', P.usage(generic.words), 'plugin')
  eq('generic row is help-only', generic.helpOnly, true)
  for (const r of t.rows.filter(r => r.id.indexOf('appLauncher.plugin.') === 0)) {
    if (r.helpOnly) continue
    eq(`${r.id}: hidden from parent pages`, r.parentHidden, true)
    eq(`${r.id}: keeps its metadata`, Array.isArray(r.examples) && r.examples.length > 0, true)
  }
  eq('the generic row is not callable', C.publicRowIds().includes('appLauncher.plugin'), false)
  eq('the generic row is still in the manifest', C.allRowIds().includes('appLauncher.plugin'), true)
})

group('the app exemplar matches the authoritative snapshots', () => {
  const host = fs.readFileSync(path.join(SHELL_DIR, 'features/apps/AppHost.qml'), 'utf8')
  const app = C.findTarget('app')
  eq('the target summary is exact', app.summary, "Manage Vibranium's Quickshell apps")
  eq('the root note is exact', app.notes,
    ["Use 'vb-shell app call help' to see available per-app calls"])
  eq('list summary', C.findRow('app.list').summary, 'List all known apps')
  eq('open label', C.findRow('app.open').labelSummary, 'Open an app by ID')
  eq('open verb help has no summary', C.findRow('app.open').summary, '')
  eq('close label', C.findRow('app.close').labelSummary || C.findRow('app.close').summary, 'Close apps by ID')
  eq('toggle label', C.findRow('app.toggle').labelSummary, 'Toggle an app window')
  eq('toggle verb help has no summary', C.findRow('app.toggle').summary, '')
  eq('call branch summary', app.branches.call.summary, 'Explicit per-app commands')
  eq('call branch note', app.branches.call.notes, ["Use 'vb-shell app list' to see available apps"])
  eq('call branch usage is required', app.branches.call.usage, 'vb-shell app call <ID>')
  eq('call branch examples', app.branches.call.examples,
    ['vb-shell app call list audioMixer', 'vb-shell app call audioMixer help'])
  eq('call list command summary', C.findRow('app.call.list').summary,
    'List supported commands for ID')
  eq('call list is a help-kind reply', C.findRow('app.call.list').output.kind, 'help')
  for (const id of ['app.list', 'app.open', 'app.close', 'app.toggle', 'app.call.list',
    'app.call.audioMixer.openTab', 'app.call.audioMixer.selectTab',
    'app.call.audioMixer.status', 'app.call.imageViewer.openPath',
    'app.call.imageViewer.status']) {
    eq(`${id}: no Output prose`, C.findRow(id).output.summary, '')
  }
  for (const id of ['app.open', 'app.close', 'app.toggle',
    'app.call.audioMixer.openTab', 'app.call.audioMixer.selectTab',
    'app.call.imageViewer.openPath']) {
    eq(`${id}: silent success`, C.findRow(id).output.kind, 'none')
  }
  eq('app open returns the silent frame',
    /function _open\(id\)[\s\S]*?return _ok\(\)\n  \}/.test(host), true)
  eq('app toggle returns the silent frame',
    /function _toggle\(id\)[\s\S]*?return _ok\(\)\n  \}/.test(host), true)
  eq('a close with nothing open is silent success',
    host.includes('if (open === 0) return _ok()'), true)
  eq('app openPath returns the silent frame',
    /function _openPath\(path\)[\s\S]*?return _ok\(\)\n  \}/.test(host), true)
  eq('app openTab returns the silent frame',
    /function _openTab\(tab\)[\s\S]*?return _ok\(\)\n  \}/.test(host), true)
  eq('app selectTab returns the silent frame',
    /function _selectTab\(tab\)[\s\S]*?return _ok\(\)\n  \}/.test(host), true)
  for (const payload of ['open: true, state: "accepted"', 'open: !open',
    'state: "accepted", url: answer.url', 'state: "accepted", tab: tab',
    'tab: tab']) {
    eq(`app action payload is gone: ${payload}`, host.includes(payload), false)
  }
  for (const id of ['app.open', 'app.close', 'app.toggle']) {
    eq(`${id}: no Arguments`, C.findRow(id).arguments, [])
    eq(`${id}: no Notes`, C.findRow(id).notes, [])
  }
  eq('the owner builds one descriptor for both spellings',
    (host.match(/function _callHelp\(id\)/g) || []).length, 1)
  eq('the describe seam is registered', host.includes('}, root._describeApp)'), true)
  eq('the describe seam cannot fabricate pages',
    host.includes('if (!rest || rest.length !== 2 || rest[0] !== "call") return null'), true)
  const exact = [
    'Audio mixer: native Pavucontrol replacement, with Pipewire node graph included',
    'Open audioMixer with <TAB> focused',
    'Select a <TAB> in existing window',
    'audioMixer status',
    'Valid tab ids are: apps, devices, recording, configuration, graph',
    'vb-shell app call audioMixer openTab configuration',
    'A simple, Vibranium-native image viewer',
    'Open an image in <PATH>',
    'ImageViewer status',
    'vb-shell app call imageViewer openPath /home/user/Pictures/my-image.png'
  ]
  for (const text of exact) {
    eq(`AppHost publishes the exact string: ${text}`, host.includes(text), true)
  }
  eq('the mixer status summary is literal', host.includes('literalSummary: true'), true)
})

section('owner registration')

group('every new row has one constant closure', () => {
  const files = {
    app: fs.readFileSync(path.join(SHELL_DIR, 'features/apps/AppHost.qml'), 'utf8'),
    appLauncher: fs.readFileSync(path.join(SHELL_DIR, 'features/launcher/AppLauncher.qml'), 'utf8'),
    audio: fs.readFileSync(path.join(SHELL_DIR, 'services/audio/Audio.qml'), 'utf8')
  }
  for (const id of Object.keys(files)) {
    const src = files[id]
    eq(`${id}: registers`, src.includes('IpcRouter.register("' + id + '"'), true)
    eq(`${id}: unregisters`, src.includes('IpcRouter.unregister("' + id + '"'), true)
    if (id === 'appLauncher') {
      // The Bash vb-shell client still dispatches natively, so five thin
      // aliases are retained. Each delegates to the SAME owner action; only
      // the four verbs 01B retires are absent.
      eq('launcher probe retained', src.includes('debugConfirmNavigation'), true)
      for (const verb of ['plugins', 'pluginSet', 'usage', 'reload']) {
        eq(`launcher native ${verb} retired`, src.includes(`function ${verb}(`), false)
      }
      for (const verb of ['open', 'close', 'toggle', 'hasHistory', 'clearHistory']) {
        eq(`launcher native ${verb} retained`, src.includes(`function ${verb}(`), true)
      }
      eq('open delegates to the owner action', src.includes('function open(): string { return root._openVerb() }'), true)
      eq('toggle delegates to the owner action', src.includes('function toggle(): string { return root._toggleVerb() }'), true)
      eq('close delegates to the facade close', /function close\(\): string \{\s*root\.close\(\)\s*return "ok"/.test(src), true)
      eq('hasHistory uses the published verdict', /function hasHistory\(\): string \{\s*if \(!root\.usageKnown\) return "unavailable"/.test(src), true)
      eq('clearHistory uses the controller writer', src.includes('ctrl.clearUsageHistory() ? "ok" : "unavailable"'), true)
      const nativeHelp = src.slice(src.indexOf('function help('), src.indexOf('function ping('))
      eq('native help names only the retained aliases',
        ['clearHistory', 'close', 'hasHistory', 'open', 'toggle'].every(v => nativeHelp.includes(`name: "${v}"`)), true)
      eq('native help does not advertise retired verbs',
        ['plugins', 'pluginSet', 'usage', 'reload'].some(v => nativeHelp.includes(`name: "${v}"`)), false)
    } else {
      eq(`${id}: no native IpcHandler`, src.includes('IpcHandler'), false)
    }
    const expected = C.findTarget(id).rows
      .filter(r => r.helpOnly !== true
        && (r.route === 'gateway' || r.id === `${id}.status` || r.id === `${id}.ping`))
      .map(r => r.id).sort()
    const found = [...src.matchAll(/"([a-z][a-zA-Z0-9-]*\.[A-Za-z0-9_.-]+)":\s*function/g)]
      .map(m => m[1]).filter(v => v.startsWith(id + '.')).sort()
    eq(`${id}: one closure per row`, expected, found)
  }
})

section('built-in plugin ipc closures')

group('query plugins answer typed data and never activate', () => {
  const api = {
    setting: () => false, shellQuote: s => s, execDetached: () => { throw new Error('must not activate') },
    requestTime: () => {}, cachedTime: () => ({ time: '10:00', date: 'today', code: '' }),
    cachedNet: () => null, cachedSection: () => ({}), setCacheSection: () => {}, cachedOnline: () => true
  }
  const dir = rel => path.join(SHELL_DIR, 'features/launcher/plugins', rel)
  const calc = loadPlugin(dir('calc/main.js'), api)
  const evaled = calc.ipc.eval('2+2*3')
  eq('calc value is numeric', evaled.value, 8)
  eq('calc expression is preserved', evaled.expression, '2+2*3')

  const unit = loadPlugin(dir('unit/main.js'), api)
  const converted = unit.ipc.convert('2 km in miles')
  eq('unit rows', Array.isArray(converted) && converted.length > 0, true)
  eq('unit row fields', Object.keys(converted[0]), ['from', 'to', 'label', 'value'])

  const constants = loadPlugin(dir('constants/main.js'), api)
  const readings = constants.ipc.lookup('speed of sound')
  eq('constant readings', Array.isArray(readings) && readings.length > 0, true)
  eq('reading fields', Object.keys(readings[0]), ['label', 'description', 'value', 'related'])

  const color = loadPlugin(dir('color/main.js'), api)
  const parsed = color.ipc.parse('#ff8800')
  eq('color hex', parsed.hex, '#ff8800')
  eq('color formats are typed', parsed.formats.length > 0 && typeof parsed.formats[0].fmt === 'string', true)

  const time = loadPlugin(dir('time/main.js'), api)
  const cached = time.ipc.lookup('time in Madrid')
  eq('cached time city', cached.city, 'Madrid')
  eq('bare city resolves', time.ipc.lookup('Berlin').city, 'Berlin')
  eq('IANA zone resolves', time.ipc.lookup('Europe/Berlin').timezone, 'Europe/Berlin')
  eq('unknown city is not-found', time.ipc.lookup('Nowhereville'), { error: 'not-found' })
  const misses = []
  const missApi = Object.assign({}, api, {
    cachedTime: () => null,
    requestTime: zone => misses.push(zone)
  })
  const missTime = loadPlugin(dir('time/main.js'), missApi)
  eq('cache miss is accepted', missTime.ipc.lookup('Berlin').state, 'accepted')
  eq('cache miss requests once', misses.length, 1)
  const conv = time.ipc.convert('7:55pm cst')
  eq('time conversion fields', Object.keys(conv),
    ['sourceTime', 'sourceDate', 'sourceOffset', 'localTime', 'localDate', 'localOffset'])

  const web = loadPlugin(dir('websearch/main.js'), api)
  eq('search url is built, not opened', web.ipc.url('two words'),
    'https://www.google.com/search?q=two%20words')
})

finish()

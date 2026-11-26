#!/usr/bin/env node
// Suite: IpcCatalog - the retained public surface is complete, plain and
// registered. The registration check reads the IpcRouter.register blocks in
// the handler files, so a route with no owner fails here rather than at run
// time on a user's machine.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))

const RETAINED = [
  'shell', 'boot', 'log', 'keybindings', 'settings', 'systemFont', 'state', 'watch',
  'notifications', 'osd', 'pass', 'polkit', 'power', 'themePicker', 'themeRemover',
  'wallpaper', 'wallpaperPicker', 'recording', 'timer', 'powerProfile', 'privacy',
  'screenshots', 'session', 'systemUpdates', 'printers',
]

const HANDLERS = [
  'boot/Boot.qml',
  // Batch E owner: the menu gateway's closures are declared inside the
  // registration block, one per public catalog row id.
  'features/menu/Menu.qml',
  // Batch B owners. Their catalog targets are gateway routes registered by
  // the resident facade, not native IpcHandlers, but the registration
  // contract (one closure per public row id) is the same.
  'features/apps/AppHost.qml',
  'features/launcher/AppLauncher.qml',
  'services/audio/Audio.qml',
  'services/tools/Tools.qml',
  'common/settings/Settings.qml',
  'common/settings/SystemFont.qml',
  'common/state/State.qml',
  'common/watch/Watch.qml',
  'features/notifications/Notifications.qml',
  'features/osd/OSD.qml',
  'features/pass/Pass.qml',
  'features/pickers/keybindings/Keybindings.qml',
  'features/pickers/theme/ThemePicker.qml',
  'features/pickers/theme/ThemeRemover.qml',
  'features/polkit/Polkit.qml',
  'features/powerMenu/PowerMenu.qml',
  'features/wallpaper/Wallpaper.qml',
  'features/wallpaperPicker/WallpaperPicker.qml',
  'services/media/Recording.qml',
  'services/media/Timer.qml',
  'services/power/PowerProfile.qml',
  'services/privacy/Privacy.qml',
  'services/screenshots/Screenshots.qml',
  'services/session/Session.qml',
  'services/system/SystemUpdates.qml',
  'services/system/Printers.qml',
  // Batch D owners. hyprlandSettings/idle/inhibitor/session register their
  // gateway closures through the same mechanism. Lockscreen is an in-process
  // Registry owner now, not a public IPC target, so it has no routes here.
  'common/settings/HyprlandSettings.qml',
  'services/session/IdleDaemon.qml',
  'services/power/Inhibitor.qml',
  // Batch C owners: bar (including its color-picker seat), clipboard and
  // the emoji picker. The four clipboard-copy rows are client-owned by design.
  'features/bar/control/BarControl.qml',
  'features/colorPicker/ColorPickerController.qml',
  'features/clipboard/Clipboard.qml',
  'features/pickers/emoji/EmojiPicker.qml',
]

suite('ipc-catalog', 'frozen retained surface: records, grammar, registration')

// ---------------------------------------------------------------------------
section('shape')

group('targets are plain records', () => {
  eq('every retained target is present', RETAINED.filter(id => !C.findTarget(id)), [])
  for (const t of C.Manifest.targets) {
    eq(`${t.id}: id/title/summary/rows/branches (+ optional notes/noExamples/status)`,
      Object.keys(t).filter(k => !['notes', 'noExamples', 'status'].includes(k)).sort(),
      ['branches', 'id', 'rows', 'summary', 'title'])
    eq(`${t.id}: branches is a plain object`, Object.prototype.toString.call(t.branches), '[object Object]')
    const ids = t.rows.map(r => r.id)
    eq(`${t.id}: row ids unique`, new Set(ids).size, ids.length)
  }
  eq('only hyprlandSettings and idle suppress their fallback examples',
    C.Manifest.targets.filter(t => t.noExamples === true).map(t => t.id), ['hyprlandSettings', 'idle'])
  eq('no target advertises the injected status row',
    C.Manifest.targets.filter(t => t.status && t.status.visible === true).map(t => t.id), [])
  eq('osd, polkit, wallpaper, session, inhibitor, idle and colorPicker keep their status data',
    C.Manifest.targets.filter(t => t.status && typeof t.status.summary === 'string').map(t => t.id),
    ['osd', 'polkit', 'wallpaper', 'tools', 'session', 'inhibitor', 'idle', 'colorPicker'])
  eq('osd status names its current state', C.findRow('osd.status').summary,
    "Show the OSD's current state")
  eq('polkit status names the prompt state', C.findRow('polkit.status').summary,
    'Show the authentication prompt state')
  eq('session status names lock and power', C.findRow('session.status').summary,
    'Show session lock and power state')
  const inhibitorStatus = C.findRow('inhibitor.status')
  eq('inhibitor status stays unlisted on its target page', inhibitorStatus.visible, undefined)
  eq('inhibitor status keeps the isActive description', inhibitorStatus.summary,
    'Show whether the inhibitor is active')
  eq('inhibitor status example uses its own target', inhibitorStatus.examples,
    ['vb-shell inhibitor status'])
  const idleStatus = C.findRow('idle.status')
  eq('idle status stays unlisted on its target page', idleStatus.visible, undefined)
  eq('idle status names the daemon', idleStatus.summary,
    "Show the idle daemon's status")
  eq('idle status example uses its own target', idleStatus.examples, ['vb-shell idle status'])
  const ids = C.Manifest.targets.map(t => t.id)
  eq('target ids unique', new Set(ids).size, ids.length)
  eq('target ids sorted by code point', C.targetIds(), [...ids].sort())
})

group('the refactored targets keep their requested descriptions', () => {
  eq('pass manages password-store entries', C.findTarget('pass').summary,
    'Manage password-store entries')
  eq('screenshots captures and annotates', C.findTarget('screenshots').summary,
    'Capture and annotate screenshots')
  eq('session lists its power actions', C.findTarget('session').summary,
    'Lock, log out, suspend, reboot or power off')
  eq('powerProfile chooses the system profile', C.findTarget('powerProfile').summary,
    'Choose the system power profile')
  eq('pass open opens', C.findRow('pass.open').summary, 'Open the password manager page')
  eq('pass toggle toggles', C.findRow('pass.toggle').summary,
    'Toggle the password manager page')
  eq('pass copy teaches two paths', C.findRow('pass.copy').examples.length, 2)
  eq('osd flash has no notes', C.findRow('osd.flash').notes, [])
  eq('powerProfile get asks for the current profile', C.findRow('powerProfile.get').summary,
    'Show the current power profile')
  eq('powerProfile list names the available profiles', C.findRow('powerProfile.list').summary,
    'List available power profiles')
  eq('powerProfile list is headerless lines', C.findRow('powerProfile.list').output.kind, 'lines')
  eq('state describes shell state and runtime queries', C.findTarget('state').summary,
    'Vibranium shell state & runtime queries')
  eq('themePicker refresh rescans folders', C.findRow('themePicker.refresh').summary,
    'Rescan folders for new themes')
  eq('themePicker toggle names the overlay', C.findRow('themePicker.toggle').summary,
    'Toggle the theme picker overlay')
  eq('themePicker open names the overlay', C.findRow('themePicker.open').summary,
    'Open the theme picker overlay')
  eq('themePicker close names the overlay', C.findRow('themePicker.close').summary,
    'Close the theme picker overlay')
  eq('themeRemover uninstalls community themes', C.findTarget('themeRemover').summary,
    'Uninstall community themes')
  eq('themeRemover toggle names the panel', C.findRow('themeRemover.toggle').summary,
    'Toggle the theme remover panel')
  const timerStart = C.findRow('timer.start')
  eq('timer start is the seconds leaf', timerStart.usage, 'start <N>')
  eq('timer start hides its leaf', timerStart.parentHidden, true)
  const timerMinutes = C.findRow('timer.start.minutes')
  eq('timer minutes lives under start', timerMinutes.usage, 'start minutes <N>')
  eq('the old startMinutes verb is gone', C.findRow('timer.startMinutes'), null)
  eq('timer start is a branch', C.findTarget('timer').branches.start.commands,
    ['timer.start', 'timer.start.minutes'])
  eq('wallpaper isEnabled moved into status', C.findRow('wallpaper.isEnabled'), null)
  eq('wallpaper status stays unlisted', C.findRow('wallpaper.status').visible, undefined)
  eq('wallpaper status names the current state', C.findRow('wallpaper.status').summary,
    'Show the current wallpaper state')
  const capture = C.findRow('screenshots.capture')
  eq('capture is a silent action row', capture.route, 'compat')
  eq('capture uses the action adapter', capture.reply.kind, 'action')
  eq('capture names its modifier set', capture.usage,
    'capture [plain|copy|save] screen|region')
  eq('capture accepts modifiers in any order',
    P.match(capture.words, ['capture', 'save', 'plain', 'region']).args.flags, ['save', 'plain'])
  eq('screenshots last replaces lastShot', C.findRow('screenshots.lastShot'), null)
  eq('screenshots last is a text query', C.findRow('screenshots.last').output.kind, 'text')
  eq('plain screen and region are gone',
    C.allRowIds().filter(id => id === 'screenshots.screen' || id === 'screenshots.region'), [])
})

group('rows contain no functions or QML references', () => {
  const leaks = []
  for (const t of C.Manifest.targets) {
    for (const r of t.rows) {
      const allowed = new Set(['arguments', 'examples', 'helpOnly', 'id', 'labelSummary', 'notes', 'options',
        'output', 'parent', 'parentHidden', 'reply', 'formats', 'route', 'summary', 'usage', 'usageOnly', 'visible', 'words'])
      eq(`${r.id}: no unknown field`, Object.keys(r).filter(k => !allowed.has(k)), [])
      eq(`${r.id}: required fields`, ['arguments', 'examples', 'id', 'notes', 'options',
        'output', 'route', 'summary', 'words'].filter(k => !Object.prototype.hasOwnProperty.call(r, k)), [])
      for (const [k, v] of Object.entries(r)) {
        if (typeof v === 'function') leaks.push(`${r.id}.${k}`)
      }
    }
  }
  eq('no closures in rows', leaks, [])
})

// ---------------------------------------------------------------------------
section('JSON argument help')

group('every json argument states its shape and shows a quoted token', () => {
  const noSummary = []
  const noExample = []
  let count = 0
  const quotedJson = (example) => (String(example).match(/'([^']*)'/g) || []).some((q) => {
    try { JSON.parse(q.slice(1, -1)); return true } catch (e) { return false }
  })
  for (const t of C.Manifest.targets) {
    for (const r of t.rows) {
      for (const a of (r.arguments || []).filter((a) => a.type === 'json')) {
        count++
        if (typeof a.summary !== 'string' || a.summary.trim() === '') noSummary.push(r.id)
        if (!(r.examples || []).some(quotedJson)) noExample.push(r.id)
      }
    }
  }
  eq('the audit found every json argument', count, 11)
  eq('every json argument has a shape summary', noSummary, [])
  eq('every json row shows a quoted JSON token', noExample, [])
  const update = C.findRow('systemUpdates.update')
  eq('the update example teaches the JSON array form',
    update.examples.includes('vb-shell systemUpdates update aur \'["artcraft-launcher-bin"]\''), true)
  eq('the update argument names the exact shape',
    /JSON array of package names/.test(update.arguments.find((a) => a.type === 'json').summary), true)
})

// ---------------------------------------------------------------------------
section('grammar and routing')

group('every row compiles to an unambiguous grammar', () => {
  const bad = []
  for (const r of C.allRowIds().map(id => C.findRow(id))) {
    const c = P.compile(r.words)
    if (!c.ok) bad.push(`${r.id}: ${c.error}`)
  }
  eq('all public rows compile', bad, [])
  const row = C.findRow('settings.get')
  eq('a get call matches', P.match(row.words, ['get', 'a.key']).args.key, 'a.key')
  eq('a get call with no key fails', P.match(row.words, ['get']).ok, false)
  const fonts = C.findRow('settings.fonts.reload')
  eq('the fixed keyword branch matches', P.match(fonts.words, ['fonts', 'reload']).ok, true)
  eq('a placeholder cannot steal a fixed keyword', P.match(fonts.words, ['anything', 'reload']).ok, false)
  const dndGet = C.findRow('notifications.dnd.get')
  eq('dnd get matches', P.match(dndGet.words, ['dnd', 'get']).ok, true)
  eq('dnd get rejects an extra word', P.match(dndGet.words, ['dnd', 'get', 'x']).ok, false)
  const dndEnable = C.findRow('notifications.dnd.enable')
  eq('dnd enable matches', P.match(dndEnable.words, ['dnd', 'enable']).ok, true)
  eq('dnd rejects the old on spelling', P.match(dndEnable.words, ['dnd', 'on']).ok, false)
})

group('routes are declared, never inferred', () => {
  const allowed = ['gateway', 'compat', 'injected', 'log-read', 'clipboard-copy']
  const bad = []
  for (const t of C.Manifest.targets) {
    for (const r of t.rows) if (!allowed.includes(r.route)) bad.push(`${r.id}: ${r.route}`)
    const injected = t.rows.filter(r => r.route === 'injected').map(r => r.id)
    const expectedCommon = t.id === 'log'
      ? [`${t.id}.help`]
      : [`${t.id}.help`, `${t.id}.status`, `${t.id}.ping`]
    eq(`${t.id}: help/status/ping injected exactly once`, injected, expectedCommon)
    eq(`${t.id}: help is never owner-routable`, C.publicRowIds().includes(`${t.id}.help`), false)
  }
  eq('unknown routes', bad, [])
  eq('log status is client-owned', C.findRow('log.status').route, 'log-read')
  eq('log ping is client-owned', C.findRow('log.ping').route, 'log-read')
})

group('retired native targets are absent', () => {
  // `idle`, `inhibitor` and `session` are CATALOG targets owned by gateway
  // facades. The lockscreen target was removed outright: its state is read
  // through `session isLocked`, and its owner stays on the in-process bus.
  // `bar`, `clipboard` and `emojiPicker` are now CATALOG gateway targets;
  // their retired spellings were native IpcHandlers, which are gone.
  eq('no lockscreen target', C.findTarget('lockscreen'), null)
  eq('lockscreen is absent from the index ids', C.targetIds().includes('lockscreen'), false)
  eq('no lockscreen row survives', C.allRowIds().filter(id => id.startsWith('lockscreen.')), [])
  eq('session.isLocked is retired', C.findRow('session.isLocked'), null)
  eq('session.reboot.firmware is a public action route',
    C.findRow('session.reboot.firmware').route, 'compat')
  eq('session.reboot.firmware matches only the firmware spelling',
    P.match(C.findRow('session.reboot.firmware').words, ['reboot', 'firmware']).ok, true)
  eq('plain session reboot stays normal',
    P.match(C.findRow('session.reboot').words, ['reboot']).ok, true)
  for (const id of ['lockscreen', 'idleDaemon', 'audioMixer',
    'fontPicker', 'cursorPicker', 'menu', 'launcher']) {
    notContains(`no target ${id}`, id, C.targetIds().join(','))
  }
  // The color picker is a bar-owned feature with a thin top-level alias, not
  // an independent picker service.
  eq('the colorPicker alias is a catalog target', C.findTarget('colorPicker') !== null, true)
  eq('colorPicker publishes only pick and close as owner verbs',
    C.findTarget('colorPicker').rows.filter(r => r.route === 'gateway').map(r => r.words[0]),
    ['pick', 'close'])
  const colorStatus = C.findRow('colorPicker.status')
  eq('colorPicker status keeps its summary', colorStatus.summary,
    "Show the color picker's status")
  eq('colorPicker status keeps its output', colorStatus.output,
    { kind: 'record', summary: '{available,picking,screen}' })
  eq('colorPicker status keeps its notes', colorStatus.notes,
    ["'status', 'ping' and 'help' are available on every target"])
  eq('colorPicker status keeps its example', colorStatus.examples,
    ['vb-shell colorPicker status'])
  eq('colorPicker status stays unlisted', colorStatus.visible, undefined)
  eq('colorPicker has no result query', C.findRow('colorPicker.result'), null)
  // No gateway owner may reintroduce a native target or a generic dispatch.
  const src = fs.readFileSync(path.join(SHELL_DIR, 'features/apps/AppHost.qml'), 'utf8')
  eq('the app host has no native IpcHandler', src.includes('IpcHandler'), false)
  eq('the app host has no generic call adapter', /function\s+call\s*\(/.test(src), false)
  // Retired native spellings must not survive in the D owners.
  const hypr = fs.readFileSync(path.join(SHELL_DIR, 'common/settings/HyprlandSettings.qml'), 'utf8')
  eq('hyprlandSettings has no native toggle', /function\s+toggle\s*\(/.test(hypr), false)
  const lock = fs.readFileSync(path.join(SHELL_DIR, 'features/lock/Lockscreen.qml'), 'utf8')
  eq('lockscreen has no effect toggles', /function\s+toggle(Animations|NowPlaying|PauseMusic|BlurBackground)\s*\(/.test(lock), false)
  eq('lockscreen has no cycleBlurPower', /function\s+cycleBlurPower\s*\(/.test(lock), false)
  eq('lockscreen has no native target', /target:\s*"lockscreen"/.test(lock), false)
  eq('lockscreen publishes no router routes', /IpcRouter\.(?:un)?register\(\s*"lockscreen"/.test(lock), false)
  eq('lockscreen keeps its in-process registry registration',
    lock.includes('Registry.register("lockscreen", root)'), true)
  eq('lockscreen retires its in-process registration',
    lock.includes('Registry.unregister("lockscreen")'), true)
  eq('the registry publishes the requested-or-secure state',
    lock.includes('readonly property bool locked: requested || sessionLock.secure'), true)
  const session = fs.readFileSync(path.join(SHELL_DIR, 'services/session/Session.qml'), 'utf8')
  eq('session registers the firmware reboot closure',
    session.includes('"session.reboot.firmware": function () { return ipc.uefiReboot() }'), true)
  eq('session reads the lock through the neutral registry',
    /Registry\.get\("lockscreen", "locked"\) === true/.test(session), true)
  eq('session no longer publishes an isLocked verb',
    session.includes('function isLocked'), false)
  eq('the session service imports no feature', /import qs\.features/.test(session), false)
  const inh = fs.readFileSync(path.join(SHELL_DIR, 'services/power/Inhibitor.qml'), 'utf8')
  eq('inhibitor handler has no native toggle', /function\s+toggle\(\):\s*string/.test(inh), false)
})

group('top-level verbs', () => {
  eq('timer verbs match the retained offer', C.topLevelVerbs('timer'),
    ['start', 'stop', 'status', 'help', 'ping'])
  eq('settings includes the branch keyword once', C.topLevelVerbs('settings').filter(v => v === 'fonts').length, 1)
  eq('unknown target has no verbs', C.topLevelVerbs('nope'), [])
})

// ---------------------------------------------------------------------------
section('Output prose policy')

group('only raw JSON payload kinds may show Output in text help', () => {
  const jsonKinds = ['value', 'record', 'table']
  const payloadQueries = ['settings.get', 'state.dump', 'systemUpdates.dump',
    'menu.current']
  for (const id of payloadQueries) {
    eq(`${id}: structured payload kind`, jsonKinds.includes(C.findRow(id).output.kind), true)
  }
  const scalars = ['session.lock', 'notifications.dnd.get', 'wallpaper.get',
    'notifications.clear', 'app.call.list', 'audio.stream.mute']
  for (const id of scalars) {
    eq(`${id}: no Output prose`, jsonKinds.includes(C.findRow(id).output.kind), false)
  }
  eq('injected status is text, not a payload query', C.findRow('app.status').output.kind, 'text')
  eq('injected status has no Output prose', C.findRow('app.status').output.summary, '')
  for (const id of ['bar.enable', 'audio.volume.set', 'clipboard.select',
    'colorPicker.pick', 'inhibitor.start']) {
    eq(`${id}: an order has no output`, C.findRow(id).output.kind, 'none')
  }
  eq('hyprland set can publish a verbose record',
    C.findRow('hyprlandSettings.set.value').output.kind, 'record')
  const actionRows = C.Manifest.targets.flatMap(t => t.rows.filter(r => r.reply && r.reply.kind === 'action'))
  eq('every action row declares silence', actionRows.every(r => r.output.kind === 'none'), true)
})

// ---------------------------------------------------------------------------
section('flat help convention')

group('deep rows stay dispatchable but never appear on parent pages', () => {
  const hidden = C.Manifest.targets.flatMap(t => t.rows.filter(r => r.parentHidden === true))
  eq('the audit found hidden branches', hidden.length > 0, true)
  for (const r of hidden) {
    if (r.route === 'gateway' || r.route === 'compat') {
      eq(`${r.id}: still dispatchable`, C.publicRowIds().includes(r.id), true)
    }
    eq(`${r.id}: still has an example`, r.examples.length > 0, true)
  }
  const placeholders = C.Manifest.targets.flatMap(t => t.rows.filter(r => r.helpOnly === true))
  for (const r of placeholders) {
    eq(`${r.id}: never dispatchable`, C.publicRowIds().includes(r.id), false)
    eq(`${r.id}: has an example`, r.examples.length > 0, true)
    eq(`${r.id}: teaches its branch`, P.compile(r.words).ok, true)
  }
  eq('the app call placeholder is one row', C.findRow('app.call').helpOnly, true)
  eq('systemUpdates dump has one placeholder',
    C.findTarget('systemUpdates').rows.filter(r => r.helpOnly === true && r.words[0] === 'dump').length, 1)
  eq('app call list is a help-kind result', C.findRow('app.call.list').output.kind, 'help')
})

group('every branch command is a real catalog row', () => {
  const bad = []
  for (const t of C.Manifest.targets) {
    for (const [key, branch] of Object.entries(t.branches)) {
      for (const id of (branch.commands || [])) {
        if (!C.findRow(id)) bad.push(`${t.id}.${key}:${id}`)
      }
      if ((branch.commands || []).length > 0 && branch.noExamples !== true) {
        if (!Array.isArray(branch.examples) || branch.examples.length === 0) bad.push(`${t.id}.${key}:examples`)
      }
    }
  }
  eq('no dangling or example-less branch', bad, [])
})

// ---------------------------------------------------------------------------
section('stream controller owns list and route-status')

group('retired top-level rows are gone', () => {
  eq('no audio.apps row', C.findRow('audio.apps'), null)
  eq('no audio.routeStatus row', C.findRow('audio.routeStatus'), null)
  eq('audio stream list exists', C.findRow('audio.stream.list') !== null, true)
  eq('audio stream route-status exists', C.findRow('audio.stream.route-status') !== null, true)
  eq('stream controller lists five verbs',
    C.findTarget('audio').branches.stream.commands.length, 5)
  const notes = (C.findTarget('audio').branches.stream.notes || []).join(' ')
  contains('stream note quotes the list command', notes, "'vb-shell audio stream list'")
  eq('stream branch declares no arguments', C.findTarget('audio').branches.stream.arguments || [], [])
  for (const id of ['audio.stream.set', 'audio.stream.mute', 'audio.stream.route']) {
    const words = C.findRow(id).words.filter(w => typeof w === 'string')
    eq(`${id} uses literal verbs`, words.includes(id.split('.')[2]), true)
  }
})

section('quoted command samples in prose')

group('notes quote command samples, examples stay bare', () => {
  const samples = [
    ['app root note', C.findTarget('app').notes[0], "'vb-shell app call help'"],
    ['call branch note', C.findTarget('app').branches.call.notes[0], "'vb-shell app list'"],
    ['plugin placeholder note', C.findRow('appLauncher.plugin').notes[0],
      "'vb-shell appLauncher plugin list'"],
    ['bar module note', C.findRow('bar.module').notes[0], "'vb-shell bar module list'"],
    ['bar trigger note', C.findRow('bar.module.ID.triggerBranch').notes[0],
      "'vb-shell bar module <MODULE> trigger help'"]
  ]
  for (const [label, note, quoted] of samples) {
    eq(`${label} quotes its sample`, note.includes(quoted), true)
  }
  eq('examples stay bare commands',
    C.findRow('app.call.list').examples.includes('vb-shell app call list audioMixer'), true)
})

// ---------------------------------------------------------------------------
section('controller/verb convention')

group('nouns own verbs, never camelCase', () => {
  // Targets that deliberately use controllers. Each controller is a noun
  // placeholder in the target's own page and each of its verbs is a short
  // lowercase/hyphenated action in the controller page.
  const controllers = {
    app: ['call'],
    appLauncher: ['history', 'plugin'],
    audio: ['volume', 'microphone', 'sink', 'source', 'stream'],
    bar: ['module', 'position', 'layout'],
    menu: ['item', 'search', 'open', 'toggle'],
    notifications: ['dnd', 'dismiss'],
    systemUpdates: ['dump'],
    settings: ['fonts'],
    hyprlandSettings: ['set'],
    printers: ['job'],
    clipboard: ['copy']
  }
  const nounPattern = /^[a-z][a-z0-9-]*$/
  const legacyNouns = new Set(['colorPicker', 'position', 'layout'])
  for (const [target, nouns] of Object.entries(controllers)) {
    const t = C.findTarget(target)
    for (const noun of nouns) {
      if (!legacyNouns.has(noun)) {
        eq(`${target}: ${noun} is lowercase/hyphenated`, nounPattern.test(noun), true)
      }
      const placeholder = t.rows.find(r => r.helpOnly === true && r.words[0] === noun)
      eq(`${target}: ${noun} has one placeholder`, !!placeholder, true)
      const branch = t.branches[noun] || {}
      const ids = (branch.commands || [])
        .concat(t.rows.filter(r => r.id.startsWith(`${target}.${noun}.`)).map(r => r.id))
      const leaves = [...new Set(ids)].map(id => C.findRow(id)).filter(r => r && r.helpOnly !== true)
      eq(`${target}: ${noun} hides its verbs`, leaves.length > 0 && leaves.every(r => r.parentHidden === true), true)
    }
  }
  // Every controller verb introduced by this reorganization is lowercase or
  // hyphenated; retained legacy verbs elsewhere are out of scope here.
  for (const id of ['app.call.list', 'appLauncher.history.is-empty', 'appLauncher.history.show',
    'appLauncher.history.clear', 'appLauncher.plugin.status', 'audio.volume.up',
    'audio.volume.down', 'audio.volume.toggle', 'audio.volume.get', 'audio.volume.set',
    'audio.microphone.up', 'audio.microphone.down', 'audio.microphone.toggle',
    'audio.microphone.get', 'audio.microphone.set', 'audio.sink.list', 'audio.sink.set',
    'audio.source.list', 'audio.source.set']) {
    const words = C.findRow(id).words.filter(w => typeof w === 'string')
    for (const word of words) {
      eq(`${id}: ${word} is lowercase/hyphenated`, nounPattern.test(word), true)
    }
  }
  // A target's own page stays short: controllers, not every leaf.
  for (const target of Object.keys(controllers)) {
    const visible = C.findTarget(target).rows.filter(r => r.route !== 'injected'
      && r.parentHidden !== true && r.helpOnly !== true)
    eq(`${target}: flat page stays bounded`, visible.length <= 18, true)
  }
})

// ---------------------------------------------------------------------------
section('registration')

group('every routable catalog id has one owner closure', () => {
  const registered = new Set()
  for (const rel of HANDLERS) {
    const src = fs.readFileSync(path.join(SHELL_DIR, rel), 'utf8')
    const blocks = src.match(/IpcRouter\.register\([\s\S]*?\}\)\s*(?:\n|$)/g) || []
    eq(`${rel}: has a register block`, blocks.length > 0, true)
    for (const block of blocks) {
      for (const m of block.matchAll(/"([a-z][a-zA-Z0-9-]*\.[A-Za-z0-9_.-]+)"/g)) registered.add(m[1])
    }
  }
  const expected = C.publicRowIds()
    .concat(C.Manifest.targets.map(t => `${t.id}.status`), C.Manifest.targets.map(t => `${t.id}.ping`))
    .filter(id => id !== 'log.status' && id !== 'log.ping').sort()
  eq('no route without an owner', expected.filter(id => !registered.has(id)), [])
  eq('no owner without a catalog route', [...registered].filter(id => !expected.includes(id)).sort(), [])
})

group('destruction hooks retire the registration', () => {
  for (const rel of HANDLERS) {
    const src = fs.readFileSync(path.join(SHELL_DIR, rel), 'utf8')
    eq(`${rel}: unregisters`, src.includes('IpcRouter.unregister('), true)
  }
})

finish()

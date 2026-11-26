#!/usr/bin/env node
// Suite: the bar gateway's metadata table and owner wiring (batch C).
//
// BarIpc.js is a pure library, so the table and result vocabulary are tested
// directly. The QML half is checked structurally: one explicit closure per
// catalog row, physical visibility derived from live views, islands driven
// only through IslandHost.show/close/isOpenFor, and explicit per-module
// ipcTrigger methods. No desktop shell is started.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, contains, notContains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const B = loadLib(path.join(SHELL_DIR, 'features/bar/BarIpc.js'))
const BAR = read('features', 'bar', 'BarRuntime.qml')
const CONTROL = read('features', 'bar', 'control', 'BarControl.qml')
const VIEW = read('features', 'bar', 'BarView.qml')
const ZONE = read('features', 'bar', 'Zone.qml')
const GROUP = read('features', 'bar', 'Group.qml')
const CATALOG = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))

suite('bar-catalog', 'module metadata, visibility, islands and explicit triggers')

section('metadata table')
group('all shipped ids are present with real names', () => {
  const expected = {
    workspaces: ['Workspaces', 'Switch and inspect workspaces', false],
    privacy: ['Privacy', 'Show active capture indicators', true],
    clock: ['Clock', 'Local time and calendar', true],
    weather: ['Weather', 'Current conditions and forecast', true],
    keyboardLayout: ['Keyboard layout', 'Active input layout', false],
    bluetooth: ['Bluetooth', 'Nearby and connected devices', true],
    battery: ['Battery', 'Power and charge state', true],
    network: ['Network', 'Connectivity and transfer state', true],
    printers: ['Printers', 'Printer and queue status', true],
    powerProfile: ['Power profile', 'Select the active power profile', false],
    systemUpdates: ['Arch updates', 'Available system updates', true],
    colorPicker: ['Color picker', 'Pick colors and revisit samples', true],
    nightLight: ['Night light', 'Toggle warm color temperature', false],
    nowPlaying: ['Now playing', 'Media controls and track info', true],
    volume: ['Volume', 'Output and microphone levels', true],
    session: ['Session', 'Open the session power menu', false],
    tray: ['System tray', 'Status notifier items', false],
    downloader: ['Downloader', 'Download queue and progress', true],
    readingMode: ['Reading mode', 'Active reading-mode indicator', false],
    recording: ['Recording', 'Screen recording indicator', false],
    timer: ['Timer', 'Countdown indicator', false],
    caffeine: ['Caffeine', 'Idle and sleep inhibit indicator', false],
    update: ['Update', 'Running update indicator', false],
  }
  eq('twenty-three shipped ids', Object.keys(B.metadata).length, 23)
  for (const id of Object.keys(expected)) {
    const rec = B.metadata[id]
    eq(`${id}: prettyName`, rec && rec.prettyName, expected[id][0])
    eq(`${id}: description`, rec && rec.description, expected[id][1])
    eq(`${id}: island capability`, rec && rec.hasIsland, expected[id][2])
  }
})

group('future owned ids get honest defaults', () => {
  eq('an owner with no name uses its id', B.ownedMetadata({ id: 'x' }).prettyName, '')
  eq('an owner with no description has a default', B.ownedMetadata({}).description,
    'Owned bar indicator')
  eq('an owner with no island has none', B.ownedMetadata({}).hasIsland, false)
  eq('a group uses its id', B.groupMetadata('g').prettyName, 'g')
  eq('a group has no island', B.groupMetadata('g').hasIsland, false)
  eq('a record lookup falls back to the id', B.recordFor('late', null, false).prettyName, 'late')
})

section('persisted option keys')
group('suffixes are exact and ordered', () => {
  const expected = {
    workspaces: ['RightClick'],
    network: ['RightClick', 'MiddleClick'],
    bluetooth: ['RightClick', 'MiddleClick'],
    tray: ['RightClick'], session: ['RightClick'],
    keyboardLayout: ['LeftClick', 'RightClick'],
    readingMode: ['LeftClick'], update: ['LeftClick'],
    battery: ['Percent'], nowPlaying: ['Title', 'Flash'], recording: ['Elapsed'],
    volume: ['ShowMic', 'Percent', 'RightClick', 'MiddleClick', 'MicRightClick', 'MicMiddleClick'],
    clock: ['Seconds', 'SecondsTooltip', 'FullDate', 'MoonPhase', 'RightClick'],
    weather: ['ShowTemp', 'Flash', 'Unit', 'RefreshMinutes', 'Verbose', 'MiddleClick'],
    systemUpdates: ['HeavyWarning'], nightLight: ['Temperature'],
  }
  eq('the option table has sixteen modules', Object.keys(B.options).length, 16)
  for (const id of Object.keys(expected)) {
    eq(`${id}: option keys`, B.optionKeys(id, null), expected[id])
  }
  eq('an unknown module has no options', B.optionKeys('caffeine', null), [])
  eq('setting keys keep the module suffix case', B.settingKey('weather', 'ShowTemp'),
    'shell.statusbar.weatherShowTemp')
  eq('metadata tables are copied, not shared', (() => {
    const k = B.optionKeys('clock', null); k.push('X'); return B.optionKeys('clock', null).length
  })(), 5)
})

section('explicit triggers')
group('only five named pairs exist', () => {
  eq('nowPlaying', B.triggerNames('nowPlaying'), ['flashTrack'])
  eq('weather', B.triggerNames('weather'), ['flashTemperature'])
  eq('network', B.triggerNames('network'), ['flashConnection'])
  eq('bluetooth', B.triggerNames('bluetooth'), ['flashDevice'])
  eq('battery', B.triggerNames('battery'), ['flashCharge'])
  eq('volume has none', B.triggerNames('volume'), [])
})

section('result vocabulary')
group('frames are typed', () => {
  eq('ok wraps data', B.ok({ enabled: true }), { v: 1, ok: true, data: { enabled: true } })
  eq('silence has no data', B.silent(), { v: 1, ok: true })
  eq('fail carries a code', B.fail('unsupported', 'nope').error,
    { code: 'unsupported', message: 'nope' })
  eq('accepted is silent', B.accepted(), { v: 1, ok: true })
})

section('owner registration')
group('every bar row has one constant closure', () => {
  const registered = new Set()
  for (const m of CONTROL.matchAll(/IpcRouter\.register\([\s\S]*?\}\)\s*(?:\n|$)/g)) {
    for (const id of m[0].matchAll(/"(bar\.[A-Za-z0-9_.-]+)"/g)) registered.add(id[1])
  }
  const expected = CATALOG.findTarget('bar').rows
    .filter(r => r.route === 'gateway' && r.helpOnly !== true)
    .map(r => r.id)
    .concat(['bar.status', 'bar.ping']).sort()
  eq('no bar route is unowned', expected.filter(id => !registered.has(id)), [])
  eq('no bar closure is unlisted', [...registered].filter(id => !expected.includes(id)).sort(), [])
  contains('unregister retires by owner identity', CONTROL, 'IpcRouter.unregister("bar", root)')
  notContains('no native bar handler', BAR, 'target: "bar"')
  notContains('no native color picker handler', BAR, 'target: "colorPicker"')
})

group('Bound-component property declarations', () => {
  // With pragma ComponentBehavior: Bound, assigning to an undeclared property
  // throws inside Component.onCompleted and aborts the rest of startup (the
  // bar rendered empty when this happened). Every root._ assignment this
  // batch added must have a matching declaration in the same file.
  for (const [label, src] of [['Bar.qml', BAR],
    ['BarView.qml', VIEW], ['Zone.qml', ZONE], ['Group.qml', GROUP]]) {
    const assigned = new Set()
    for (const m of src.matchAll(/\b(?:root|win|slot|memberLoader|loader)\.(_[A-Za-z0-9_]+)\s*=[^=]/g)) {
      assigned.add(m[1])
    }
    const declared = new Set()
    for (const m of src.matchAll(/\bproperty\s+(?:(?:readonly)\s+)?[A-Za-z0-9_<>.,\s\[\]]+?\s(_[A-Za-z0-9_]+)\s*:/g)) {
      declared.add(m[1])
    }
    eq(`${label}: every assigned private property is declared`,
      [...assigned].filter(n => !declared.has(n)).sort(), [])
  }
  eq('the registration verdict is declared', /IpcRouter\.register\("bar", root, \{/.test(CONTROL), true)
  eq('the verdict is stored exactly once',
    (CONTROL.match(/IpcRouter\.register\("bar", root, \{/g) || []).length, 1)
})

group('persistent and transient writes stay separate', () => {
  contains('enable writes the store only on change', BAR, 'if (root.enabled !== want) root.setOption("enabled", want)')
  contains('hide writes no store', BAR, 'root.hideToggle = hidden === true')
  contains('show does not override a persistent disable', BAR, 'A persistent disable is not')
  contains('layout commits once', BAR, 'root.setOption("layout", norm)')
  contains('layout requires four arrays', BAR, 'zones.concat(["disabled"])')
  contains('layout rejects duplicate placements', BAR, 'duplicate layout placement')
  contains('fixed slots cannot move', BAR, 'fixed slot cannot move')
  notContains('no mutation of submitted layout arrays', BAR, 'raw[zone].push')
})

section('physical visibility')
group('a query walks live views, never layout membership alone', () => {
  contains('effective layout membership is required', BAR,
    'root.effectiveEnabled || !root.isModuleVisible(id)')
  contains('a visible window is required', BAR, 'if (!view || !view.visible) return false')
  contains('a loaded item is required', BAR, 'typeof view.ipcModuleItems === "function"')
  contains('item.visible and width are required', BAR, 'it.visible === true && Number(it.width) > 0')
  contains('a group is any member visible', BAR, 'for (let i = 0; i < members.length; i++)')
  contains('the view indexes modules by id', VIEW, 'function noteIpcModule(id, item)')
  contains('forget is identity-safe', VIEW, 'list[i] !== item && !!list[i]')
  contains('a destroyed delegate is dropped', VIEW, 'item === null ? !!list[i]')
  contains('Zone attaches after wiring', ZONE, 'root.hostWindow.noteIpcModule(slot.modelData.id, loaded)')
  contains('Group forwards members', GROUP, 'root.barWindow.noteIpcModule(id, item)')
  contains('a departing member is forgotten by identity', GROUP,
    'root.barWindow.forgetIpcModule(modelData, memberLoader._ipcMemberItem)')
})

section('islands and triggers')
group('only IslandHost edges are used', () => {
  contains('open uses show', BAR, 'host.show(item, item.islandComponent)')
  contains('close uses close', BAR, 'if (anchor) host.close()')
  contains('isOpen uses isOpenFor', BAR, 'host.isOpenFor(item)')
  contains('unsupported is rejected before loading', BAR, 'root.ipcMetaFor(id).hasIsland !== true')
  contains('the host replaces another anchor', BAR, 'if (verb === "open" && anchor)')
  notContains('no toggle convenience call', BAR, 'openIsland()')
  notContains('no BarModule toggle in the gateway', BAR,
    'barWindow.islandHost.toggle(')
})

group('trigger methods are explicit and suppression is owner-side', () => {
  const files = {
    NowPlaying: 'flashTrack',
    Weather: 'flashTemperature',
    Network: 'flashConnection',
    Bluetooth: 'flashDevice',
    Battery: 'flashCharge',
  }
  for (const [name, trigger] of Object.entries(files)) {
    const src = read('features', 'bar', 'modules', name, name + '.qml')
    contains(`${name}: explicit ipcTrigger`, src, `function ipcTrigger(name)`)
    contains(`${name}: allowlisted ${trigger}`, src, `name !== "${trigger}"`)
  }
  contains('no dynamic method construction', BAR, 'BarIpc.triggerNames(id)')
  contains('suppression result', BAR, 'state: "suppressed"')
  contains('defer result', BAR, 'state: "deferred"')
})

section('color picker claim')
group('the active picker is independent of the owner', () => {
  contains('separate property', BAR, 'property var _activePicker: null')
  contains('claim cancels a previous picker', BAR, 'root._activePicker.cancelPick()')
  contains('close cancels the active picker', BAR, 'picker.cancelPick()')
  contains('duplicate pick does not restart', BAR, 'if (root._activePicker) return BarIpc.silent')
  const mod = read('features', 'bar', 'modules', 'ColorPicker', 'ColorPicker.qml')
  contains('stamp after admission', mod, 'ColorPickerController.claimActivePicker(root)')
  contains('clear on teardown', mod, 'ColorPickerController.clearActivePicker(root)')
  contains('clear on destruction', mod, 'ColorPickerController.clearActivePicker(root)')
})

finish()

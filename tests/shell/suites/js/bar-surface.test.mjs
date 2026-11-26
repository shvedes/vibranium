#!/usr/bin/env node
// Suite: the current bar help text and public surface.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const BAR = fs.readFileSync(path.join(SHELL_DIR, 'features/bar/BarRuntime.qml'), 'utf8')
const CONTROL = fs.readFileSync(path.join(SHELL_DIR, 'features/bar/control/BarControl.qml'), 'utf8')

suite('bar-surface', 'exact bar summaries and retired rows')

section('target and summaries')
group('exact strings', () => {
  eq('target summary', C.findTarget('bar').summary, 'Inspect and control the status bar')
  eq('enable', C.findRow('bar.enable').summary, 'Enable the status bar')
  eq('disable', C.findRow('bar.disable').summary, 'Disable the status bar')
  eq('toggle', C.findRow('bar.toggle').summary, 'Toggle the status bar')
  eq('show', C.findRow('bar.show').summary, 'Show the status bar again')
  eq('hide', C.findRow('bar.hide').summary, 'Hide the status bar')
  eq('showToggle', C.findRow('bar.showToggle').summary, 'Temporarily show or hide the status bar')
  eq('module list', C.findRow('bar.module.list').summary, 'Show all known status bar modules')
  eq('island close', C.findRow('bar.module.ID.island.close').summary, "Close one module's island")
  eq('island toggle', C.findRow('bar.module.ID.island.toggle').summary, "Toggle one module's island")
})

section('retired rows are absent')
group('catalog and owner', () => {
  for (const id of ['bar.borderEnable', 'bar.borderDisable', 'bar.borderToggle',
    'bar.colorPicker.pick', 'bar.colorPicker.close', 'bar.colorPicker.status',
    'bar.colorPicker.result', 'bar.colorPicker', 'bar.module.ID.island.isOpen']) {
    eq(`${id} is gone`, C.findRow(id), null)
  }
  eq('no colorPicker branch', C.findTarget('bar').branches.colorPicker, undefined)
  notContains('no border owner method', BAR, 'function ipcSetBorder(')
  notContains('no bar picker closure', BAR, '"bar.colorPicker.')
  eq('module list defaults to all', P.match(C.findRow('bar.module.list').words,
    ['module', 'list']).ok, true)
  eq('module list takes a filter', P.match(C.findRow('bar.module.list').words,
    ['module', 'list', 'visible']).args.FILTER, 'visible')
  eq('module list refuses an unknown filter', P.match(C.findRow('bar.module.list').words,
    ['module', 'list', 'bogus']).ok, false)
  eq('position set is usage-only', C.findRow('bar.position.set').usageOnly, true)
  eq('position toggle is an accepted value',
    C.findRow('bar.position.set').arguments[0].values.includes('toggle'), true)
  eq('island is-open grammar', P.match(C.findRow('bar.module.ID.island.is-open').words,
    ['module', 'clock', 'island', 'is-open']).ok, true)
  eq('module toggle is silent', C.findRow('bar.module.ID.toggle').output.kind, 'none')
  eq('position bare set has no row match',
    P.match(C.findRow('bar.position.set').words, ['position', 'set']).ok, false)
})

section('status and module status projection')
group('typed status frame and toggleable', () => {
  contains('status returns a typed frame', CONTROL, 'data: root.ipcStatus(), format: { kind: "record" }')
  notContains('status no longer stringifies JSON', CONTROL, 'JSON.stringify(root.ipcStatus())')
  contains('status projection uses hidden', BAR, 'hidden: root.hideToggle')
  notContains('no hideToggle key in stateSnapshot', BAR, 'hideToggle: root.hideToggle')
  notContains('no hiddenByOverride result key', BAR, 'hiddenByOverride: root.hideToggle')
  contains('module status uses toggleable', BAR, 'rec.toggleable =')
  notContains('no old configEnablement key', BAR, 'configEnablement')
  eq('hide summary is exact', C.findRow('bar.hide').summary, 'Hide the status bar')
})

section('layout get projection')
group('four slot arrays', () => {
  const src = BAR.slice(BAR.indexOf('function ipcLayout('), BAR.indexOf('function _ipcGroupMember('))
  contains('the record carries disabled', src, 'const out = { left: [], center: [], right: [], disabled: [] }')
  contains('disabled ids are projected', src, 'out.disabled.push')
  contains('enabled marker', src, '"- [*] "')
  contains('disabled marker', src, '"- [] "')
})

finish()

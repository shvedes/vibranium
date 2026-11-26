#!/usr/bin/env node
// Suite: the clipboard controller layout and absence of retired flat verbs.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, contains, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const SRC = fs.readFileSync(path.join(SHELL_DIR, 'features/clipboard/Clipboard.qml'), 'utf8')
const DOCS = fs.readFileSync(path.join(path.dirname(SHELL_DIR), 'docs/user/clipboard.md'), 'utf8')
const BINDS = fs.readFileSync(path.join(path.dirname(SHELL_DIR), 'default/hypr/binds.lua'), 'utf8')

suite('clipboard-controllers', 'window/list/purge/clear controllers')

section('new paths and grammar')
group('controller rows', () => {
  const forms = [
    ['clipboard.window.open', ['window', 'open'], {}],
    ['clipboard.window.open', ['window', 'open', 'pinned'], {}],
    ['clipboard.window.close', ['window', 'close'], {}],
    ['clipboard.window.toggle', ['window', 'toggle'], {}],
    ['clipboard.list.regular', ['list'], {}],
    ['clipboard.list.pinned', ['list', 'pinned'], {}],
    ['clipboard.list.current', ['list', 'current'], {}],
    ['clipboard.purge.regular', ['purge', '0'], { INDEX: '0' }],
    ['clipboard.purge.pinned', ['purge', 'pinned', '0'], { INDEX: '0' }],
    ['clipboard.clear.regular', ['clear'], {}],
    ['clipboard.clear.pinned', ['clear', 'pinned'], {}]
  ]
  for (const [id, argv, args] of forms) {
    const m = P.match(C.findRow(id).words, argv)
    eq(`${argv.join(' ')} matches`, m.ok, true)
    for (const key of Object.keys(args)) eq(`${argv.join(' ')}: ${key}`, m.args[key], args[key])
  }
  eq('window open usage is derived from words', P.usage(C.findRow('clipboard.window.open').words), 'window open [pinned]')
  eq('no PINNED argument record', C.findRow('clipboard.window.open').arguments, [])
  eq('copy entry displays literal alternatives',
    C.findRow('clipboard.copy.entry').usage, 'copy entry regular|pinned <INDEX>')
  eq('copy text displays the dash alternative',
    C.findRow('clipboard.copy.text').usage, 'copy text <TEXT|->')
  eq('copy entry still has an enum BUCKET argument',
    C.findRow('clipboard.copy.entry').arguments[0].type, 'enum')
  eq('copy entry accepts regular',
    P.match(C.findRow('clipboard.copy.entry').words,
      ['copy', 'entry', 'regular', '0']).args.BUCKET, 'regular')
  eq('copy entry still refuses an unknown bucket',
    P.match(C.findRow('clipboard.copy.entry').words,
      ['copy', 'entry', 'other', '0']).ok, false)
})

section('retired rows are absent')
group('catalog, owner, docs and binds', () => {
  for (const id of ['clipboard.windowOpen', 'clipboard.windowClose', 'clipboard.windowToggle',
    'clipboard.windowOpenPinned', 'clipboard.listPinned', 'clipboard.listCurrent',
    'clipboard.purgePinned', 'clipboard.clearHistory', 'clipboard.clearPinned',
    'clipboard.copyEntry']) {
    eq(`${id} is gone`, C.findRow(id), null)
    notContains(`${id} has no closure`, SRC, `"${id}"`)
  }
  notContains('docs have no windowToggle', DOCS, 'clipboard windowToggle')
  notContains('docs have no clearHistory', DOCS, 'clipboard clearHistory')
  notContains('binds use window toggle', BINDS, 'clipboard windowToggle')
  contains('binds use the clear action', BINDS, '"clipboard.clear"')
})

section('no Output prose on clipboard pages')
group('output summaries are empty', () => {
  const t = C.findTarget('clipboard')
  const noisy = t.rows.filter(r => r.output && typeof r.output.summary === 'string'
    && r.output.summary !== '')
  eq(`${noisy.length} rows with Output prose`, noisy, [])
})

section('kept commands are unchanged')
group('pin/unpin/select/copyEntry/status/ping', () => {
  for (const id of ['clipboard.pin', 'clipboard.unpin', 'clipboard.select',
    'clipboard.copy.entry', 'clipboard.status', 'clipboard.ping']) {
    eq(`${id} still exists`, C.findRow(id) !== null, true)
  }
})

finish()

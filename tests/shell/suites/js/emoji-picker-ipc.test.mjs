#!/usr/bin/env node
// Suite: emoji resolution and bundle identity (batch C).
//
// The resolver is lifted verbatim from EmojiPicker.qml and driven against the
// shipped catalogs, parsed the same way the picker parses them. Search scoring
// is the real MenuLib search, so the tie rule is the one the menu uses.
// No menu window, generator or shell is started.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, contains, notContains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const MenuLib = loadLib(path.join(SHELL_DIR, 'features/menu/MenuLib.js'))
const CATALOG = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const SRC = read('features', 'pickers', 'emoji', 'EmojiPicker.qml')

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
function functionBody(name) {
  const at = SRC.indexOf(`function ${name}(`)
  if (at < 0) return ''
  return bracedBody(SRC, SRC.indexOf('{', at), name)
}
const RESOLVE = functionBody('_resolve')
const COPY = functionBody('_ipcCopy')
const STATUS = functionBody('ipcStatus')

function loadCatalog(file) {
  const text = fs.readFileSync(path.join(SHELL_DIR, 'features/pickers/emoji', file), 'utf8')
  return JSON.parse(text.replace(/^\s*\/\/.*$/gm, ''))
}

const entries = []
const byGlyph = Object.create(null)
for (const file of ['emojis.jsonc', 'emojis-all.jsonc']) {
  for (const page of loadCatalog(file).pages) {
    for (const item of page.items) {
      if (!item || typeof item.glyph !== 'string' || byGlyph[item.glyph]) continue
      byGlyph[item.glyph] = true
      const label = String(item.label || '')
      const hay = label.toLowerCase()
      entries.push({ glyph: item.glyph, label: label, hay: hay, words: hay.split(/\s+/) })
    }
  }
}
const root = { _catalog: { entries, byGlyph }, _ensureCatalog: () => root._catalog }
const resolve = id => new Function('root', 'MenuLib', 'id', RESOLVE)(root, MenuLib, id)

suite('emoji-picker-ipc', 'glyph, code point and keyword resolution')

section('catalog')
group('both shipped catalogs are loaded once, in order', () => {
  eq('entry glyphs come first', entries[0].glyph, '😀')
  eq('no glyph is indexed twice', entries.length, Object.keys(byGlyph).length)
  eq('the companion contributes the rest', entries.length > 1000, true)
})

section('resolution')
group('exact glyph', () => {
  eq('a face glyph', resolve('😀'), '😀')
  eq('a companion glyph', resolve('💌'), '💌')
  eq('an unknown glyph is not found', resolve('🚀🚀🚀not-an-emoji'), null)
})
group('U+ code points', () => {
  eq('one code point', resolve('U+1F600'), '😀')
  eq('several code points', resolve('U+2764 U+FE0F'), '❤️')
  eq('lowercase hex', resolve('u+1f600'), null)
  eq('an out-of-range code point is refused', resolve('U+110000'), null)
  eq('a surrogate is refused', resolve('U+D800'), null)
  eq('a code point absent from the catalog is refused', resolve('U+0000'), null)
})
group('label and keyword', () => {
  eq('an exact normalized label', resolve('grinning face cheerful cheery happy'), '😀')
  eq('a token alias', resolve('grinning'), '😀')
  eq('case insensitive', resolve('GRINNING FACE'), '😀')
  eq('a fuzzy search hit', resolve('face with tears'), '😂')
  eq('no match', resolve('zzzznotthere'), null)
  eq('empty input', resolve(''), null)
})

section('bundle identity and fixed bridge')
group('the catalogs are read through parked views', () => {
  notContains('no path is fixed at construction', SRC, 'path: root.bundlePath')
  contains('each view is parked before its read', SRC, 'file.path = ""')
  contains('the read path is reassigned', SRC, 'file.path = paths[f]')
})
group('only the emoji bundle is closed', () => {
  contains('bundle identity is checked', SRC, 'Menu.isBundleOpen(root.bundlePath)')
  contains('opening uses Menu.openFile', SRC, 'Menu.openFile(root.bundlePath)')
  contains('closing uses Menu.close', SRC, 'Menu.close()')
  notContains('no direct toggleFile fallback', SRC, 'Menu.toggleFile')
  notContains('no paste command is run', SRC, 'vb-emoji-insert')
})
group('copy uses one fixed gateway', () => {
  contains('the bridge is exact', SRC, 'Registry.call("clipboard", "writePublicText", glyph)')
  notContains('no arbitrary registry call', SRC, 'Registry.call(a.ID')
  contains('an unresolved copy is not-found', SRC, 'root.fail("not-found", "no such emoji")')
  const root = {
    _resolve: () => '😀',
    _ok: (data, format) => ({ v: 1, ok: true, data: data, format: format }),
    fail: (code, message) => ({ v: 1, ok: false, error: { code: code, message: message } })
  }
  const copy = verdict => new Function('root', 'Registry', 'id', '_ok', COPY)(
    root, { call: () => verdict }, '😀', root._ok)
  eq('an accepted bridge copies', copy({ v: 1, ok: true, data: { glyph: '😀' } }).ok, true)
  eq('a busy bridge is not reported as accepted', copy({ v: 1, ok: false,
    error: { code: 'busy', message: 'copy in progress' } }).error.code, 'busy')
  eq('a missing clipboard service is unavailable', copy(null).error.code, 'unavailable')
})
group('status does not load the cache', () => {
  notContains('status never loads a catalog', STATUS, '_ensureCatalog')
  contains('status reports open', STATUS, 'open:')
  contains('status reports readiness', STATUS, 'catalogReady:')
})
group('successful actions render no text', () => {
  const actions = CATALOG.findTarget('emojiPicker').rows.filter(r => r.route === 'gateway')
  eq('every action declares the none output kind', actions.map(r => r.output.kind),
    ['none', 'none', 'none', 'none'])
  contains('open uses the silent frame', SRC, '{ open: Menu.isBundleOpen(root.bundlePath) }, { kind: "none" }')
  contains('copy uses the silent frame', SRC, '{ glyph: glyph, state: "accepted" }, { kind: "none" }')
  contains('status reports a record', STATUS, '{ kind: "record" }')
  contains('ping returns pong', SRC, 'root._ok("pong")')
})

section('owner registration')
group('every emoji row has one constant closure', () => {
  const registered = new Set()
  for (const m of SRC.matchAll(/IpcRouter\.register\([\s\S]*?\}\)\s*(?:\n|$)/g)) {
    for (const id of m[0].matchAll(/"(emojiPicker\.[A-Za-z0-9_.]+)"/g)) registered.add(id[1])
  }
  const expected = CATALOG.findTarget('emojiPicker').rows
    .filter(r => r.route === 'gateway').map(r => r.id)
    .concat(['emojiPicker.status', 'emojiPicker.ping']).sort()
  eq('no emoji route is unowned', expected.filter(id => !registered.has(id)), [])
  eq('no emoji closure is unlisted', [...registered].filter(id => !expected.includes(id)).sort(), [])
  contains('unregister retires by owner identity', SRC, 'IpcRouter.unregister("emojiPicker", root)')
  notContains('no native emoji handler', SRC, 'target: "emojiPicker"')
})

finish()

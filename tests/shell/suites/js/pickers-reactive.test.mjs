#!/usr/bin/env node
// Suite: picker landing/scans that must retire superseded intents (OVL-10, OVL-11).
//
//   shell/features/pickers/keybindings/Keybindings.qml   open() landing deferral
//   shell/features/pickers/cursor/CursorPicker.qml      size scan answers
//
// Limitation: both are QML singletons driven by Menu, hyprctl/vb-cursor-set
// processes and a watched state file, none of which exist in this node-only
// suite. The real function bodies are lifted out of the shipped QML by brace
// matching and run against stubs, so what is pinned is the retire/publish
// decision and the single-writer shape, not the live process or file reads.
// No frame-level probe is possible offscreen; the deferred landing and the
// stale size answer are asserted at the decision, not at the compositor.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, notMatch, contains, skip, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const KEY = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'pickers', 'keybindings', 'Keybindings.qml'), 'utf8')
const CUR = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'pickers', 'cursor', 'CursorPicker.qml'), 'utf8')

// Lift a function body by brace matching so nested ifs and closures survive.
function liftFunction(src, name, from = 0) {
  const head = `function ${name}(`
  const at = src.indexOf(head, from)
  if (at < 0) return ''
  return liftBraced(src, src.indexOf('{', at))
}

// Lift a brace-delimited block starting at `{` at braceAt.
function liftBraced(src, braceAt) {
  if (braceAt < 0) return ''
  let depth = 0
  for (let j = braceAt; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(braceAt + 1, j)
    }
  }
  return ''
}

// The size-scan onExited is the second handler in the file; anchor it.
function liftSizeExit(src) {
  const at = src.indexOf('id: sizeScanProc')
  const ex = src.indexOf('onExited:', at)
  return liftBraced(src, src.indexOf('{', ex))
}

function liftKeyExit(src) {
  const ex = src.indexOf('onExited:')
  return liftBraced(src, src.indexOf('{', ex))
}

suite('pickers-reactive', 'OVL-10 landing generation + OVL-11 size answer generation')

// ======================================================================
section('OVL-10 - a stale open landing must not push over newer UI')
const OPEN_BODY = liftFunction(KEY, 'open')
const KEY_EXIT_BODY = liftKeyExit(KEY)

function runOpen() {
  const later = []
  const calls = []
  const root = {
    pageId: 'keybindings',
    _landingGen: 0,
    _cached: [],
    _compose: () => { calls.push('compose') },
    _scan: (show) => { calls.push('scan:' + show) },
  }
  const Menu = {
    open: false,
    frame: null,
    openFile: (p) => { calls.push('openFile:' + p) },
    hasDynamicPage: () => true,
    push: (id) => { calls.push('push:' + id) },
  }
  const Qt = { callLater: (fn) => { later.push(fn) } }
  const Paths = { settingsCatalogPath: '/catalog' }
  const fn = new Function('root', 'Menu', 'Qt', 'Paths', OPEN_BODY) // eslint-disable-line no-new-func
  fn(root, Menu, Qt, Paths)
  return { root, later, calls }
}

group('the real open() body carries a captured landing generation', () => {
  contains('Keybindings declares _landingGen', KEY, 'property int _landingGen: 0')
  contains('open() captures it before the deferral', OPEN_BODY, 'const g = root._landingGen')
  contains('the callback retires a superseded landing', OPEN_BODY,
    'if (g !== root._landingGen) return')
  contains('the live frame.id guard is still there', OPEN_BODY,
    'Menu.frame.id === root.pageId')
  // open(), close(), refresh() each bump: a newer intent retires the landing.
  const bumps = KEY.match(/root\._landingGen\+\+/g) || []
  eq('three verbs bump the generation', bumps.length, 3)
})
group('draining a superseded landing does nothing', () => {
  const r = runOpen()
  eq('open queued one landing', r.later.length, 1)
  r.root._landingGen++ // a close/new open landed after this callback was queued
  r.later[0]()
  eq('no page was pushed', r.calls.filter((c) => c === 'push:keybindings').length, 0)
  eq('no refresh scan was started behind it', r.calls.filter((c) => c === 'scan:true').length, 0)
})
group('a live landing still lands and refreshes', () => {
  const r = runOpen()
  r.later[0]()
  eq('the page is pushed once', r.calls.filter((c) => c === 'push:keybindings').length, 1)
  eq('a refresh scan follows it', r.calls.filter((c) => c === 'scan:true').length, 1)
})
group('the failed first scan reads the captured request, not a cleared slot', () => {
  contains('the failure branch uses the captured show', KEY_EXIT_BODY, 'if (show === "open")')
  notMatch('no dead test of _pendingShow after clearing it', KEY_EXIT_BODY,
    /_pendingShow\s*===\s*"open"/)
})
skip('a real open/close/open across two event-loop turns',
  'needs Menu, hyprctl and a compositor; the captured-generation decision is pinned above')

// ======================================================================
section('OVL-11 - a stale size answer must not publish over newer UI')
const EXIT_BODY = liftSizeExit(CUR)
const APPLY_BODY = liftFunction(CUR, 'applyCurrent')

function runSizeExit(genMatches, themeMatches) {
  const calls = []
  const root = {
    _scanGen: 3,
    _currentTheme: 'A',
    _sizeCache: {},
    _updateSizeOptions: (t, s) => { calls.push('update:' + t + ':' + s.join(',')) },
  }
  const sizeScanProc = {
    _scanGen: genMatches ? 3 : 1,
    _theme: themeMatches ? 'A' : 'B',
    _replacePending: false,
  }
  const sizeOut = { text: 'A 24 48' }
  const code = 0
  const fn = new Function('root', 'sizeScanProc', 'sizeOut', 'code', EXIT_BODY) // eslint-disable-line no-new-func
  fn(root, sizeScanProc, sizeOut, code)
  return { root, calls }
}

group('the size answer carries a generation alongside the theme check', () => {
  contains('CursorPicker declares a monotone _scanGen', CUR, 'property int _scanGen: 0')
  contains('_ensureSizes bumps it for each scan', liftFunction(CUR, '_ensureSizes'),
    'root._scanGen++')
  contains('the process captures the generation', liftFunction(CUR, '_ensureSizes'),
    'sizeScanProc._scanGen = root._scanGen')
  contains('onExited retires a stale generation', EXIT_BODY,
    'sizeScanProc._scanGen !== root._scanGen')
  contains('and still checks the theme name', EXIT_BODY, 'root._currentTheme')
})
group('an A->B->A answer with an old generation is retired', () => {
  const r = runSizeExit(false, true)
  eq('the size cache is untouched', r.root._sizeCache, {})
  eq('no options were published', r.calls, [])
})
group('a current generation with the right theme still publishes', () => {
  const r = runSizeExit(true, true)
  eq('the sizes are cached for that theme', r.root._sizeCache.A, [24, 48])
  eq('the options are published', r.calls, ['update:A:24,48'])
})
group('_pendingShow is gone (it was written and cleared but never read)', () => {
  notMatch('no _pendingShow property or write survives', CUR, /_pendingShow/)
})
group('_replacePending is labelled with the process-restart race', () => {
  contains('the flag is still present', CUR, '_replacePending')
  // The comment must sit with the property, naming the restart race it owns.
  const near = CUR.slice(CUR.indexOf('property bool _replacePending') - 260,
    CUR.indexOf('property bool _replacePending') + 80)
  contains('the label names the restart race', near, 'restart')
})
group('the state file is the only writer of the current theme/size', () => {
  notMatch('applyCurrent exists', APPLY_BODY, /^\s*$/)
  contains('_readStateFile routes through applyCurrent', liftFunction(CUR, '_readStateFile'),
    'applyCurrent(')
  const bodyAt = CUR.indexOf('function applyCurrent(')
  const bodyEnd = CUR.indexOf('\n    }', bodyAt)
  const assigns = [...CUR.matchAll(/root\._current(?:Theme|Size)\s*=/g)].map((m) => m.index)
  eq('every assignment lives in applyCurrent',
    assigns.filter((i) => i < bodyAt || i > bodyEnd).length, 0)
  notMatch('setTheme no longer writes the current theme optimistically',
    liftFunction(CUR, 'setTheme'), /_currentTheme\s*=/)
  notMatch('setSize no longer writes the current size optimistically',
    liftFunction(CUR, 'setSize'), /_currentSize\s*=/)
})
group('applyCurrent publishes the state-file values and ensures sizes', () => {
  const calls = []
  const root = { _currentTheme: 'A', _currentSize: 24, _ensureSizes: (t) => { calls.push('sizes:' + t) } }
  const fn = new Function('root', 'theme', 'size', APPLY_BODY) // eslint-disable-line no-new-func
  fn(root, 'B', 32)
  eq('the theme is published', root._currentTheme, 'B')
  eq('the size is published', root._currentSize, 32)
  eq('a new theme triggers a size scan', calls, ['sizes:B'])
  const before = calls.length
  fn(root, 'B', 32)
  eq('an unchanged state writes nothing', calls.length, before)
})
skip('a live vb-cursor-set write seen through the watched state file',
  'needs FileView and the compositor; the applyCurrent publish decision is pinned above')

finish()

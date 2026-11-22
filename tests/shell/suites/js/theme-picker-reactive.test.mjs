#!/usr/bin/env node
// Suite: theme picker scan retirement and focus ownership (WAL-3, WAL-4).
//
//   shell/features/pickers/theme/ThemePicker.qml        _doScan / _finishScan
//   shell/features/pickers/theme/ThemePickerPanel.qml   themeSearch focus
//
// Limitation: both files are QML components driven by FileView,
// FolderListModel and the compositor's keyboard grant, none of which exist in
// this node-only suite. _finishScan is lifted out of the real QML by brace
// matching and run against a stub root, so what is pinned is the publish vs
// retire decision for a queued scan, not the file reads themselves. The focus
// finding is a source check: a keyboard grant cannot be synthesized offscreen,
// so it asserts that no second writer of focusCtrl.mode survives in the panel
// and that the primitive's own healing edge is still present.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, notMatch, contains, skip, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const PICKER = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'pickers', 'theme', 'ThemePicker.qml'), 'utf8')
const PANEL = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'pickers', 'theme', 'ThemePickerPanel.qml'), 'utf8')
const FOCUS = fs.readFileSync(
  path.join(SHELL_DIR, 'common', 'ui', 'PanelFocus.qml'), 'utf8')

// Lift a function body by brace matching so nested ifs and closures survive.
// The shipped QML is the only source of truth: nothing is copied in here.
function liftFunction(src, name) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) return ''
  let depth = 0
  const brace = src.indexOf('{', at)
  if (brace < 0) return ''
  for (let j = brace; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(brace + 1, j)
    }
  }
  return ''
}

const FINISH_BODY = liftFunction(PICKER, '_finishScan')

// Drive _finishScan with a stub root. The sentinels make a publish observable:
// if the handler writes _cached/rows they change away from the sentinel.
function runFinish(queued) {
  const out = [{ label: 'B' }, { label: 'A' }]
  const cacheSentinel = { sentinel: 'cache' }
  const rowsSentinel = { sentinel: 'rows' }
  const calls = []
  const root = {
    _scanGen: 1,
    _scanJob: { gen: 1, i: out.length, out: out },
    _scanQueued: queued,
    _cached: cacheSentinel,
    rows: rowsSentinel,
    _compareAlpha: (a, b) => (a < b ? -1 : a > b ? 1 : 0),
    _buildRows: (data) => ({ built: data }),
    _doScan: () => { calls.push('scan') },
  }
  const st = { gen: 1, out: out }
  const fn = new Function('root', 'st', FINISH_BODY) // eslint-disable-line no-new-func
  fn(root, st)
  return { root, calls, cacheSentinel, rowsSentinel, out }
}

suite('theme-picker-reactive', 'WAL-3 focus writer + WAL-4 queued scan retirement')

// ======================================================================
section('WAL-4 - a queued scan must not publish the interrupted scan rows')
group('the real _finishScan body is present and runnable', () => {
  contains('ThemePicker.qml declares _finishScan', PICKER, 'function _finishScan(st)')
  contains('and the queued request is recorded by _doScan', PICKER, 'root._scanQueued = true')
  notMatch('the lifted body is non-empty', FINISH_BODY, /^\s*$/)
})
group('an unqueued finish still caches and publishes the sorted rows', () => {
  const r = runFinish(false)
  eq('no scan is re-queued', r.calls, [])
  eq('the rows are sorted before publishing', r.root._cached.map((e) => e.label), ['A', 'B'])
  eq('the built rows come from the same data', r.root.rows.built, r.out)
})
group('a queued finish retires the old rows instead of publishing them', () => {
  const r = runFinish(true)
  eq('the old cache stays up', r.root._cached, r.cacheSentinel)
  eq('no stale row set is published for a frame', r.root.rows, r.rowsSentinel)
  eq('the queued scan is started', r.calls, ['scan'])
  eq('the queue flag is consumed', r.root._scanQueued, false)
  eq('the finished job is retired', r.root._scanJob, null)
})
skip('a live directory change mid-scan over a real themes tree',
  'needs FolderListModel and FileView; only the retire decision is pinned here')

// ======================================================================
section('WAL-3 - PanelFocus.mode has one writer')
group('the panel does not declare the mode the primitive owns', () => {
  notMatch('no focusCtrl.mode assignment in ThemePickerPanel', PANEL,
    /\bfocusCtrl\.mode\s*=/)
})
group('the primitive heals a lost field focus on its own', () => {
  contains('PanelFocus watches searchField focus', FOCUS, 'target: root.searchField')
  contains('and reasserts only when nothing holds focus', FOCUS,
    'if (root.unowned()) Qt.callLater(root.reassert)')
})
skip('a field focus request that never grants cannot declare filter mode',
  'needs a compositor keyboard grant; the source-level single-writer check stands in')

finish()

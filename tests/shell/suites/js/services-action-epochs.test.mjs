#!/usr/bin/env node
// Suite: the two service action races (SVC-7, SVC-8).
//
//   shell/services/system/Keyboard.qml    caps/layout writers and their views
//   shell/services/system/Printers.qml    concurrent job-action callbacks
//
// Both services are `pragma Singleton` and need a compositor/CUPS environment,
// so construction is out of reach under QT_QPA_PLATFORM=offscreen. This suite
// reads the shipped QML, lifts the real function bodies and property bindings
// by brace matching, and drives the races over a turn timeline: a j/devices
// reply captured before a local press or an activelayout event, and a slow
// job-action failure landing after a newer success. The mechanism is pinned,
// not the pixels: one writer per published value, a captured generation that
// retires stale callbacks, and the D-Bus coalescer left on its own path.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, is, match, notMatch, contains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const KEYBOARD = read('services', 'system', 'Keyboard.qml')
const PRINTERS = read('services', 'system', 'Printers.qml')

// A `{ ... }` body by brace matching, so nested ifs, closures, comments and
// brace-bearing string literals ("}") all survive the lift.
function bracedBody(src, firstBrace) {
  let depth = 0
  let quote = ''
  let comment = ''
  for (let i = firstBrace; i < src.length; i++) {
    const c = src[i]
    const n = src[i + 1]
    if (comment === 'line') {
      if (c === '\n') comment = ''
      continue
    }
    if (comment === 'block') {
      if (c === '*' && n === '/') { comment = ''; i++ }
      continue
    }
    if (quote) {
      if (c === '\\') { i++; continue }
      if (c === quote) quote = ''
      continue
    }
    if (c === '/' && n === '/') { comment = 'line'; i++; continue }
    if (c === '/' && n === '*') { comment = 'block'; i++; continue }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue }
    if (c === '{') depth++
    if (c === '}') {
      depth--
      if (depth === 0) return src.slice(firstBrace + 1, i)
    }
  }
  throw new Error('body never closes')
}

function functionBody(src, name) {
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return ''
  const brace = src.indexOf('{', at)
  return brace < 0 ? '' : bracedBody(src, brace)
}

// A property declaration, with whether it is a derived (readonly) view.
function binding(src, name) {
  const re = new RegExp(`^[ \\t]*(readonly[ \\t]+)?property[ \\t]+[\\w<>]+[ \\t]+${name}[ \\t]*:[ \\t]*(.+)$`, 'm')
  const m = re.exec(src)
  return m ? { readonly: Boolean(m[1]), expr: m[2].trim() } : null
}

// --- Keyboard: drive the real writers, read the real published view --------

const K_SYNC = functionBody(KEYBOARD, 'sync')
const K_TOGGLE = functionBody(KEYBOARD, 'toggleCaps')
const K_FEED = functionBody(KEYBOARD, 'feedDevices')
const K_PUBLISH = functionBody(KEYBOARD, '_publishLayout')
const K_RAW = functionBody(KEYBOARD, 'onRawEvent')
const K_CAPS = binding(KEYBOARD, 'capsOn')
const K_LAYOUT = binding(KEYBOARD, 'layout')
const K_COUNT = binding(KEYBOARD, 'layoutCount')

function makeKeyboard() {
  const root = {
    capsOn: false,
    layout: "",
    layoutCount: 0,
    deviceBuf: "",
    pendingCapsDelta: 0,
    _capsFact: { caps: false, folded: 0 },
    _layoutFact: { value: "", count: 0, gen: -1 },
    _layoutGen: -1,
    _syncLayoutGen: -1,
  }
  const socket = { connected: false, write() {}, flush() {} }
  const hypr = { requestSocketPath: "/tmp/hypr.sock" }
  const call = (body, argName, arg) => new Function(
    'root', 'devicesSocket', 'Hyprland', argName || '_unused', body,
  )(root, socket, hypr, arg)

  // The single layout publisher, lifted as a function with its two params.
  root._publishLayout = K_PUBLISH
    ? new Function('root', 'value', 'count', K_PUBLISH).bind(null, root)
    : () => {}

  const view = (decl, field) => decl && decl.readonly
    ? new Function('root', `return (${decl.expr})`)(root)
    : root[field]
  return {
    root,
    socket,
    sync: () => call(K_SYNC),
    toggle: () => call(K_TOGGLE),
    feed: (doc) => call(K_FEED, 'line', doc),
    raw: (event) => call(K_RAW, 'event', event),
    caps: () => view(K_CAPS, 'capsOn'),
    layout: () => view(K_LAYOUT, 'layout'),
    count: () => view(K_COUNT, 'layoutCount'),
  }
}

const deviceDoc = (caps, keymap, layout) => JSON.stringify({
  keyboards: [{ capsLock: caps, active_keymap: keymap, layout: layout }],
})

// --- Printers: drive the real action callbacks -----------------------------

const P_ACTION = functionBody(PRINTERS, '_jobAction')
const P_MONITOR = functionBody(PRINTERS, '_onMonitorLine')
const P_ERROR = binding(PRINTERS, 'actionError')

function makePrinters() {
  const root = {
    actionError: "",
    _actionGen: 0,
    vmUnavailable: false,
    _userName: () => "u",
    _monitorFails: 0,
    _completedSeen: false,
    _notifierInterface: "org.cups.cupsd.Notifier",
  }
  root._dbusField = (h, key) => key === "interface"
    ? "org.cups.cupsd.Notifier" : key === "member" ? "JobStateChanged" : ""
  const calls = []
  const timer = { restarts: 0, restart() { this.restarts++ } }
  root.runIpp = (testFile, defs, uri, onDone) => {
    calls.push({ testFile, onDone })
  }
  const Model = {
    statusCode: (text) => {
      const m = /\bstatus-code = ([a-z-]+)/.exec(String(text || ""))
      return m ? m[1] : ""
    },
  }
  const act = new Function(
    'root', 'Model', '_coalesceTimer', 'testFile', 'printerName', 'jobId', P_ACTION,
  )
  return {
    root,
    calls,
    timer,
    act: (file, printer, job) => act(root, Model, timer, file, printer, job),
    done: (i, code, text) => calls[i].onDone(code, text),
    error: () => root.actionError,
    monitor: (header) => new Function('root', '_coalesceTimer', 'line', P_MONITOR)(
      root, timer, header,
    ),
  }
}

suite('services/action-epochs', 'SVC-7 and SVC-8: snapshot and action ordering')

// ---------------------------------------------------------------------------
section('SVC-7: caps and layout have one writer each')

group('one writer per published fact', () => {
  is('capsOn is a derived view', Boolean(K_CAPS && K_CAPS.readonly),
    (v) => v === true, 'readonly property bool capsOn')
  is('layout is a derived view', Boolean(K_LAYOUT && K_LAYOUT.readonly),
    (v) => v === true, 'readonly property string layout')
  is('layoutCount is a derived view', Boolean(K_COUNT && K_COUNT.readonly),
    (v) => v === true, 'readonly property int layoutCount')
  notMatch('toggleCaps never writes the view', K_TOGGLE, /\bcapsOn\s*=/)
  notMatch('feedDevices never writes the view', K_FEED, /\bcapsOn\s*=/)
  notMatch('only the single publisher writes layout',
    KEYBOARD.replace(K_PUBLISH, ''), /root\.layout\s*=/)
  contains('the local press is published as a delta', K_TOGGLE, 'pendingCapsDelta')
  contains('the snapshot folds the pending delta', K_FEED, 'pendingCapsDelta')
  contains('a layout event goes through the one publisher', K_RAW, '_publishLayout')
  contains('a stale reply is gated by the sync generation', K_FEED, '_syncLayoutGen')
})

group('a local press survives a reply captured before it', () => {
  const k = makeKeyboard()
  k.sync()
  k.toggle()
  eq('the press flips the view before any reply', k.caps(), true)
  eq('the press is recorded as a delta', k.root.pendingCapsDelta, 1)
  k.feed(deviceDoc(false, "English (US)", "us"))
  eq('the stale snapshot cannot clobber the press', k.caps(), true)
  eq('the press is still pending after the fold', k.root.pendingCapsDelta, 1)
})

group('an activelayout event survives a reply captured before it', () => {
  const k = makeKeyboard()
  k.sync()
  k.raw({ name: "activelayout", data: "kbd,English (US)" })
  eq('the event publishes its layout', k.layout(), "English (US)")
  k.feed(deviceDoc(false, "Russian", "ru,us"))
  eq('the stale snapshot cannot clobber the event', k.layout(), "English (US)")
  eq('and leaves the layout count alone', k.count(), 0)
})

group('a fresh snapshot still publishes its whole fact', () => {
  const k = makeKeyboard()
  k.sync()
  k.feed(deviceDoc(true, "Russian", "ru,us"))
  eq('caps from the snapshot', k.caps(), true)
  eq('keymap from the snapshot', k.layout(), "Russian")
  eq('layout count from the snapshot', k.count(), 2)
})

group('the fold keeps a later snapshot from undoing a local press', () => {
  const k = makeKeyboard()
  k.sync()
  k.feed(deviceDoc(true, "Russian", "ru,us"))
  k.toggle()
  eq('the press flips the published caps', k.caps(), false)
  k.feed(deviceDoc(true, "Russian", "ru,us"))
  eq('a later snapshot keeps the folded press', k.caps(), false)
  eq('the delta is not counted twice', k.root.pendingCapsDelta, 1)
})

// ---------------------------------------------------------------------------
section('SVC-8: a newer job action retires the older callback')

group('a slow failure cannot overwrite a newer success', () => {
  const p = makePrinters()
  p.act("hold.test", "P", 1)
  p.act("release.test", "P", 2)
  eq('both actions were dispatched', p.calls.length, 2)
  p.done(1, 0, "status-code = successful-ok")
  eq('the newer success clears the error', p.error(), "")
  p.done(0, 1, "status-code = client-error-not-possible")
  eq('the stale failure cannot resurrect the error', p.error(), "")
  eq('only the current callback ordered a refresh', p.timer.restarts, 1)
})

group('a slow success cannot clear a newer failure', () => {
  const p = makePrinters()
  p.act("hold.test", "P", 1)
  p.act("cancel-job.test", "P", 2)
  p.done(1, 1, "status-code = client-error-not-possible")
  eq('the newer failure is published', p.error(), "client-error-not-possible")
  p.done(0, 0, "status-code = successful-ok")
  eq('the stale success cannot clear it', p.error(), "client-error-not-possible")
  eq('only the current callback ordered a refresh', p.timer.restarts, 1)
})

group('a single action still publishes its verdict', () => {
  const p = makePrinters()
  p.act("hold.test", "P", 1)
  p.done(0, 1, "status-code = client-error-not-found")
  eq('a vanished job is not an error', p.error(), "")
  eq('and it still refreshes', p.timer.restarts, 1)
  p.act("hold.test", "P", 2)
  p.done(1, 1, "status-code = client-error-not-authenticated")
  eq('a real failure keeps its IPP token', p.error(), "client-error-not-authenticated")
  eq('a second action minted a second generation', p.root._actionGen, 2)
})

group('the D-Bus coalescer is not gated by the action generation', () => {
  const p = makePrinters()
  p.monitor("signal sender=:1.12 -> dest=(null destination) "
    + "path=/org/cups/cupsd/Notifier; interface=org.cups.cupsd.Notifier; member=JobStateChanged")
  eq('a notifier signal still restarts the coalesce timer', p.timer.restarts, 1)
  notMatch('the monitor path never reads the action generation', P_MONITOR, /_actionGen/)
})

group('the callback guard precedes both writes', () => {
  match('the generation is captured at dispatch', P_ACTION, /const g = \+\+root\._actionGen/)
  const guard = P_ACTION.indexOf('g !== root._actionGen')
  const write = P_ACTION.indexOf('root.actionError =')
  const refresh = P_ACTION.indexOf('_coalesceTimer.restart()')
  is('the guard comes before the error write', guard >= 0 && guard < write,
    (v) => v === true, 'stale failures are refused before publishing')
  is('the guard comes before the refresh', guard >= 0 && guard < refresh,
    (v) => v === true, 'stale callbacks do not order refreshes')
  is('actionError stays a published property', Boolean(P_ERROR && !P_ERROR.readonly),
    (v) => v === true, 'property string actionError')
  contains('the dismiss commit boundary is preserved', PRINTERS, 'function _commitDismissed(next)')
})

finish()

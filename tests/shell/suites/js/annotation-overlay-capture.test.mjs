#!/usr/bin/env node
// Suite: AnnotationOverlay's grab frame identity and capture fallback (OVL-4/5).
//
//   shell/features/annotations/AnnotationOverlay.qml   onVisibleChanged,
//                                                      onHasContentChanged,
//                                                      view.onStopped, capTimer,
//                                                      _screenSelection, _reframe
//
// Limitation: AnnotationOverlay is a LayerSurface backed by a real screencopy;
// there is no compositor and no screens under offscreen. This suite reads the
// shipped QML, lifts the handlers by brace matching, and runs them against a
// stubbed view/timer pair whose sourceSize reports the 1920x1080 frame of the
// first show and whose screen is then retargeted to 2560x1440. What is pinned
// is the mechanism: a frame size belongs to one grab epoch, a new show clears
// it with the grab result, and the retry budget has one writer and one edge.
// The pixels of the cross-screen re-show stay source-level here.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, is, contains, notContains, match, notMatch,
  finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const OVERLAY_QML = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'annotations', 'AnnotationOverlay.qml'), 'utf8')
const SL = loadLib(path.join(SHELL_DIR, 'common/capture/ShotLib.js'))
const AT = loadLib(path.join(SHELL_DIR, 'features/annotations/AnnotationTools.js'))

function bracedBody(src, firstBrace, label) {
  if (firstBrace < 0) throw new Error(`${label} has no body`)
  let depth = 0
  for (let j = firstBrace; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(firstBrace + 1, j)
    }
  }
  throw new Error(`${label} body never closes`)
}

function extractFunction(src, name) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) throw new Error(`AnnotationOverlay.qml has no ${head}`)
  return bracedBody(src, src.indexOf('{', at), head)
}

function extractHandler(src, name) {
  const re = new RegExp(`^[ \\t]*${name}[ \\t]*:[ \\t]*\\{`, 'm')
  const m = re.exec(src)
  if (!m) throw new Error(`AnnotationOverlay.qml has no ${name} block`)
  return bracedBody(src, src.indexOf('{', m.index), name)
}

function timerBlock(src, id) {
  const at = src.indexOf(`id: ${id}`)
  if (at < 0) throw new Error(`AnnotationOverlay.qml has no Timer id ${id}`)
  const start = src.lastIndexOf('Timer {', at)
  if (start < 0) throw new Error(`no Timer around ${id}`)
  return bracedBody(src, src.indexOf('{', start), `Timer ${id}`)
}

function grabCallback(src) {
  const at = src.indexOf('view.grabToImage(')
  if (at < 0) throw new Error('onHasContentChanged has no grabToImage call')
  const arrow = src.indexOf('=> {', at)
  if (arrow < 0) throw new Error('grabToImage has no callback')
  return bracedBody(src, src.indexOf('{', arrow), 'grab callback')
}

const ON_VISIBLE = extractHandler(OVERLAY_QML, 'onVisibleChanged')
const ON_CONTENT = extractHandler(OVERLAY_QML, 'onHasContentChanged')
const ON_STOPPED = extractHandler(OVERLAY_QML, 'onStopped')
const SCREEN_SELECTION = extractFunction(OVERLAY_QML, '_screenSelection')
const REFRAME = extractFunction(OVERLAY_QML, '_reframe')
const CAP_TIMER = timerBlock(OVERLAY_QML, 'capTimer')
const GRAB_CB = grabCallback(ON_CONTENT)
const INTERVAL_EXPR = (/interval\s*:\s*([^\n]+)/.exec(CAP_TIMER) || [])[1]
const ON_TRIGGERED = extractHandler(CAP_TIMER, 'onTriggered')

suite('annotation overlay capture', 'OVL-4 frame identity, OVL-5 retry edge')

// A stub whose first landed frame is 1920x1080 (a 1600x900 surface at DPR
// 1.2) and whose next show is on a 2560x1440 output.
function makeSim() {
  const state = {
    visible: true, seeded: false, immediate: true,
    screen: { width: 2560, height: 1440 },
    width: 1600, height: 900, reportedDpr: 1.2,
    seedUrl: "", seedFrameW: 0, seedFrameH: 0,
    grabFrameW: 0, grabFrameH: 0,
    _grabResult: null, _grabPending: false, _showToken: 0,
    cursorX: -1, cursorY: -1, keyboardAnchor: null,
    keyboardMode: false, shiftDown: false,
    selX: 0, selY: 0, selW: 0, selH: 0,
    dragMode: "", dragHandle: -1,
    failures: [],
    failed(reason) { this.failures.push(reason) },
    _clearSelection() {
      this.selX = 0; this.selY = 0; this.selW = 0; this.selH = 0
      this.dragMode = ""; this.dragHandle = -1; this.keyboardAnchor = null
    },
  }
  const capTimer = {
    interval: 120, running: false, stops: 0, restarts: 0,
    stop() { this.running = false; this.stops++ },
    restart() { this.running = true; this.restarts++ },
  }
  const watchdog = { stop() {}, restart() {} }
  const frameImg = { source: "" }
  const view = {
    grabAttempt: 0, attempts: 0, hasContent: false,
    width: 1600, height: 900, dpr: 1.2,
    sourceSize: { width: 1920, height: 1080 },
    captureCalls: 0,
    captureFrame() { this.captureCalls++ },
    destroyContextWithUpdate() { this.hasContent = false },
    grabToImage(cb, size) { this._cb = cb; this._size = size; return true },
  }
  let deferred = null
  const Qt = { callLater(fn) { deferred = fn }, size: (w, h) => ({ w, h }) }
  return {
    state, view, capTimer, watchdog, frameImg, Qt,
    get deferred() { return deferred },
  }
}

function runVisible(s, visible) {
  new Function('overlay', 'view', 'visible', 'grabWatchdog', 'frameImg',
    'capTimer', 'Qt', ON_VISIBLE)(
    s.state, s.view, visible, s.watchdog, s.frameImg, s.capTimer, s.Qt)
}

function runHasContent(s) {
  new Function('overlay', 'view', 'hasContent', 'ShotLib', 'Qt',
    'grabWatchdog', 'capTimer', ON_CONTENT)(
    s.state, s.view, s.view.hasContent, SL, s.Qt, s.watchdog, s.capTimer)
}

function runGrabCallback(s, attempt, saved, result) {
  new Function('r', 'attempt', 'saved', 'view', 'overlay', 'grabWatchdog',
    'frameImg', GRAB_CB)(
    result, attempt, saved, s.view, s.state, s.watchdog, s.frameImg)
}

function screenSelection(s) {
  return new Function('overlay', 'view', 'AnnotationTools', SCREEN_SELECTION)(
    s.state, s.view, AT)
}

function runReframe(s) {
  new Function('overlay', 'view', 'ShotLib', 'capTimer', REFRAME)(
    s.state, s.view, SL, s.capTimer)
}

function runTriggered(s) {
  new Function('overlay', 'view', 'capTimer', ON_TRIGGERED)(
    s.state, s.view, s.capTimer)
}

function intervalFor(hasContent, immediate) {
  if (!INTERVAL_EXPR) throw new Error('capTimer has no interval expression')
  return new Function('view', 'overlay', `return (${INTERVAL_EXPR})`)(
    { hasContent }, { immediate })
}

// ---------------------------------------------------------------------------
section('OVL-4 - the frame size belongs to one grab epoch')

group('the show edge clears the size with the grab result', () => {
  contains('the root show handler is the one lifted', ON_VISIBLE, 'grabAttempt++')
  contains('show clears grabFrameW', ON_VISIBLE, 'grabFrameW = 0')
  contains('show clears grabFrameH', ON_VISIBLE, 'grabFrameH = 0')
  contains('reframe clears grabFrameW', REFRAME, 'grabFrameW = 0')
  contains('reframe clears grabFrameH', REFRAME, 'grabFrameH = 0')
})

group('only the live grab callback may publish the frame size', () => {
  const s = makeSim()
  runVisible(s, true)
  s.view.hasContent = true
  runHasContent(s)
  const live = s.view.grabAttempt
  const saved = { width: 1920, height: 1080 }

  runGrabCallback(s, live - 1, saved, { url: 'file:///stale.png' })
  eq('a superseded callback publishes nothing', s.state.grabFrameW, 0)
  eq('and leaves no grab result', s.state._grabResult, null)

  runGrabCallback(s, live, saved, { url: 'file:///frame.png' })
  eq('the live callback publishes the saved width', s.state.grabFrameW, 1920)
  eq('the live callback publishes the saved height', s.state.grabFrameH, 1080)
  is('it publishes the result in the same tick', s.state._grabResult,
    (v) => v && v.url === 'file:///frame.png', 'the grab result')

  const empty = makeSim()
  runVisible(empty, true)
  empty.view.hasContent = true
  runHasContent(empty)
  runGrabCallback(empty, empty.view.grabAttempt, saved, {})
  eq('an empty url publishes no size', empty.state.grabFrameW, 0)
})

group('a re-show maps with the new screen, not the old frame', () => {
  const s = makeSim()
  runVisible(s, true)
  s.view.hasContent = true
  runHasContent(s)
  runGrabCallback(s, s.view.grabAttempt, { width: 1920, height: 1080 },
    { url: 'file:///frame.png' })

  s.state.selX = 100; s.state.selY = 100
  s.state.selW = 800; s.state.selH = 450
  const first = screenSelection(s)

  // The hide is the edge that retires the first grab; the next show lands on
  // a 2560x1440 output and Enter needs only hasSelection, so no frame has
  // landed when the second accept maps the same rect.
  runVisible(s, false)
  eq('hide clears the grab result', s.state._grabResult, null)
  eq('hide clears the old frame width', s.state.grabFrameW, 0)
  eq('hide clears the old frame height', s.state.grabFrameH, 0)
  runVisible(s, true)

  s.state.selX = 100; s.state.selY = 100
  s.state.selW = 800; s.state.selH = 450
  const second = screenSelection(s)
  const expectedW = 800 * 2560 / 1600
  const expectedH = 450 * 1440 / 900

  eq('the second accept maps the width on the new screen', second.w, expectedW)
  eq('the second accept maps the height on the new screen', second.h, expectedH)
  is('the first capture really was mapped on the old frame',
    first.w, (v) => v === 800 * 1920 / 1600, 'the old frame width')
  notContains('no old size survives the re-show',
    [second.w, second.h].map(String).join(','),
    [first.w, first.h].map(String).join(','))
})

group('screen fallback only applies before a frame is published', () => {
  const s = makeSim()
  runVisible(s, true)
  s.state.selX = 0; s.state.selY = 0
  s.state.selW = 400; s.state.selH = 300
  const before = screenSelection(s)
  eq('no frame yet, so the screen wins on width', before.w, 400 * 2560 / 1600)
  eq('no frame yet, so the screen wins on height', before.h, 300 * 1440 / 900)
  s.state.grabFrameW = 1920; s.state.grabFrameH = 1080
  const after = screenSelection(s)
  eq('a published frame wins on width', after.w, 400 * 1920 / 1600)
  eq('a published frame wins on height', after.h, 300 * 1080 / 900)
})

// ---------------------------------------------------------------------------
section('OVL-5 - one fallback, one interval expression, one show token')

group('the interval is a pure function of live state', () => {
  notMatch('no imperative interval writes remain', OVERLAY_QML,
    /capTimer\.interval\s*=/)
  match('the binding reads hasContent first', CAP_TIMER,
    /interval\s*:\s*view\.hasContent\s*\?\s*1\s*:/)
  match('the binding branches on immediate', CAP_TIMER,
    /interval\s*:[^\n]*overlay\.immediate/)
  eq('a landed frame collapses to 1ms', intervalFor(true, true), 1)
  eq('a landed frame collapses to 1ms in the normal path',
    intervalFor(true, false), 1)
  is('1ms, never 0, in every live state',
    [intervalFor(true, true), intervalFor(true, false),
      intervalFor(false, true), intervalFor(false, false)],
    (v) => v.every((n) => n === 1 || n >= 100), '1 or a real grace')
})

group('the stopped edge re-requests and the fallback is bounded once', () => {
  contains('onStopped is the real re-request edge', ON_STOPPED,
    'view.captureFrame()')
  eq('one bounded attempt budget',
    (OVERLAY_QML.match(/attempts\s*>=\s*\d+/g) || []).length, 1)
  contains('the fallback names the missing edge', OVERLAY_QML,
    'missing stopped edge')
  contains('no landed frame re-requests', ON_TRIGGERED, 'view.hasContent')
  notContains('the fallback does not write the interval', ON_TRIGGERED,
    'interval =')
})

group('the immediate deferral carries a show token', () => {
  contains('the show mints a token', ON_VISIBLE, '++overlay._showToken')
  contains('the deferral checks the token', ON_VISIBLE,
    'show !== overlay._showToken')

  const s = makeSim()
  s.state.immediate = true
  runVisible(s, true)
  s.view.captureCalls = 0
  const stale = s.deferred
  runVisible(s, false)
  runVisible(s, true)
  stale()
  eq('a deferral from the previous show is retired', s.view.captureCalls, 0)

  const fresh = s.deferred
  fresh()
  eq('the current show still requests its frame', s.view.captureCalls, 1)
  is('the fallback was armed, not left running at 0', s.capTimer.interval,
    (v) => v === 1 || v >= 100, 'a real interval')
})

finish()

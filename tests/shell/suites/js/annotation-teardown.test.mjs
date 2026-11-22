#!/usr/bin/env node
// Suite: annotation editor teardown guards (OVL-3).
//
//   shell/features/annotations/AnnotationEditor.qml   _close(), the eight
//                                                     timers, load promotion
//                                                     and the plate grab
//
// Limitation: AnnotationEditor is a LayerSurface that needs a compositor and a
// real capture; Quickshell.screens is empty under offscreen and there is no
// synthesized cancel. This suite reads the real QML, lifts the relevant
// handlers by brace matching, and runs them against a stubbed session whose
// loadState setter fires onLoadStateChanged the way a QML signal does. What is
// pinned is the mechanism, not the pixels: a late settle tick cannot
// re-reveal the toolbar after _close(), every timer is stopped by _close(),
// and every callback that can outlive the close carries the one guard. The
// visible cancel-during-settle sequence stays source-level here.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, contains, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const EDITOR_QML = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'annotations', 'AnnotationEditor.qml'), 'utf8')

// Lift a block by brace matching so nested ifs and closures survive intact.
// The shipped QML is the only source of truth: nothing is copied into this
// suite.
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
  if (at < 0) throw new Error(`AnnotationEditor.qml has no ${head}`)
  return bracedBody(src, src.indexOf('{', at), head)
}

function extractHandler(src, name) {
  const re = new RegExp(`^[ \\t]*${name}[ \\t]*:[ \\t]*\\{`, 'm')
  const m = re.exec(src)
  if (!m) throw new Error(`AnnotationEditor.qml has no ${name} block`)
  return bracedBody(src, src.indexOf('{', m.index), name)
}

// Every `Timer { ... }` declaration in the file, with its id and body.
function timerBlocks(src) {
  const re = /^[ \t]*Timer[ \t]*\{/gm
  const out = []
  let m
  while ((m = re.exec(src)) !== null) {
    const body = bracedBody(src, src.indexOf('{', m.index), 'Timer')
    const id = (/\bid\s*:\s*([A-Za-z_]\w*)/.exec(body) || [])[1]
    if (id) out.push({ id, body })
  }
  return out
}

function timerBlock(src, id) {
  const found = timerBlocks(src).find((b) => b.id === id)
  if (!found) throw new Error(`AnnotationEditor.qml has no Timer id ${id}`)
  return found
}

const TIMER_IDS = timerBlocks(EDITOR_QML).map((b) => b.id)

// A stubbed session. Stopping a timer records its id, reveal() records the
// call, and assigning loadState runs the lifted onLoadStateChanged inline.
function makeSim() {
  const sim = { stopped: [], revealed: [], zoomCommits: 0, imageLoaded: true }
  const mkTimer = (id) => ({
    id,
    attempts: 0,
    stop() { sim.stopped.push(id) },
    start() {},
    restart() {},
  })
  const timers = {}
  for (const id of TIMER_IDS) timers[id] = mkTimer(id)

  const anim = () => ({ running: false, stop() {}, start() {} })
  const slideAnim = anim()
  const board = {
    isImageLoaded: () => sim.imageLoaded,
    requestPaint() {},
    unloadImage() {},
  }
  const panel = {
    visible: true,
    reveal() { sim.revealed.push('panel.reveal') },
  }
  const editor = {
    _closing: false,
    _closed: false,
    animOn: true,
    imgW: 100,
    imgH: 50,
    boardReady: false,
    _exportSeq: 0,
    _saveCheckSeq: 0,
    _saveTargetPending: false,
    _saveDialogOpen: false,
    _activeOutput: '',
    exporting: false,
    fileUrl: 'file:///tmp/shot.png',
    visible: true,
    _stopProcesses() {},
    _cleanupExportOutput() {},
    _cleanupPreservedOutput() {},
    _finishClose() {},
    _commitBoardZoom() { sim.zoomCommits++ },
  }

  const onLoadStateChanged = new Function(
    'editor', 'loadState', 'panel', 'slideAnim',
    extractHandler(EDITOR_QML, 'onLoadStateChanged'))
  let loadState = 'loading'
  Object.defineProperty(editor, 'loadState', {
    get() { return loadState },
    set(v) {
      loadState = v
      onLoadStateChanged(editor, loadState, panel, slideAnim)
    },
  })
  sim.editor = editor
  sim.panel = panel

  const names = {
    editor, panel, board, slideAnim,
    arrivalAnim: anim(),
    exitAnim: anim(),
    ...timers,
  }
  const args = Object.keys(names)
  const values = Object.values(names)
  const bind = (fnBody) => (...extra) => new Function(...args, fnBody)(...values, ...extra)
  editor._close = bind(extractFunction(EDITOR_QML, '_close'))
  editor._markBoardReady = bind(extractFunction(EDITOR_QML, '_markBoardReady'))
  const settle = timerBlock(EDITOR_QML, 'settleTimer').body
  sim.settleTick = bind(bracedBody(settle, settle.indexOf('{',
    settle.indexOf('onTriggered')), 'settleTimer.onTriggered'))
  return sim
}

suite('annotation teardown', 'the one session guard around _close()')

// ---------------------------------------------------------------------------
section('a late settle tick cannot re-reveal the toolbar')

group('the harness observes a reveal while the editor is still open', () => {
  const sim = makeSim()
  sim.settleTick()
  eq('a live tick promotes the board', sim.editor.boardReady, true)
  eq('a live tick reaches ready', sim.editor.loadState, 'ready')
  eq('a live tick reveals exactly once', sim.revealed.length, 1)
  eq('a live tick commits the board zoom', sim.zoomCommits, 1)
})

group('cancel while the board is still settling', () => {
  const sim = makeSim()
  sim.editor._close()
  eq('close marks the session closing', sim.editor._closing, true)
  eq('close hides the panel', sim.panel.visible, false)
  eq('close itself reveals nothing', sim.revealed.length, 0)

  // The exit animation is running; the board was never promoted. This is the
  // tick from the finding: it used to promote loadState and re-reveal.
  sim.imageLoaded = true
  sim.settleTick()
  eq('a late tick reveals nothing', sim.revealed.length, 0)
  eq('a late tick does not promote the board', sim.editor.boardReady, false)
  eq('a late tick leaves loadState loading', sim.editor.loadState, 'loading')
  eq('a late tick commits no zoom', sim.zoomCommits, 0)

  // Direct entry is guarded too: the probe's onStatusChanged can call this
  // after the close without going through the timer.
  sim.editor._markBoardReady()
  eq('a direct late promotion is inert', sim.editor.boardReady, false)
  eq('a direct late promotion reveals nothing', sim.revealed.length, 0)
})

// ---------------------------------------------------------------------------
section('_close() is the one teardown boundary')

group('every timer the file declares is stopped', () => {
  eq('the file declares eight timers', TIMER_IDS.length, 8)
  const closeBody = extractFunction(EDITOR_QML, '_close')
  for (const id of TIMER_IDS) {
    contains(`${id} is stopped by _close()`, closeBody, `${id}.stop()`)
  }
})

group('every callback that can outlive the close checks the guard', () => {
  for (const { id, body } of timerBlocks(EDITOR_QML)) {
    contains(`${id}.onTriggered checks _closing`, body, 'editor._closing')
  }
  for (const name of ['_markBoardReady', '_grabBlurPlate', '_commitBoardZoom']) {
    contains(`${name} checks _closing`, extractFunction(EDITOR_QML, name), 'editor._closing')
  }
})

finish()

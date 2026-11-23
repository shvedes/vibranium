#!/usr/bin/env node
// Suite: the bar privacy glyph's capture flash and its source-owned dwell.
//
//   shell/features/bar/modules/Privacy/Privacy.qml   the flash state + triggers
//
// A bar module is a BarModule and cannot be constructed under
// QT_QPA_PLATFORM=offscreen (Privacy transitively constructs PanelWindow), so
// this suite reads the shipped QML, lifts the flash handlers and expressions by
// brace matching, and drives them over a turn timeline with a mock service. It
// pins the ownership rule: whichever source armed the glyph owns the dwell,
// that source stopping early releases it at once, and a superseded or
// share-dropped flash cannot be cut short by a stale source edge.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const SRC = read('features', 'bar', 'modules', 'Privacy', 'Privacy.qml')

// --- QML lifting helpers ----------------------------------------------------

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

function functionBody(src, name) {
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return ''
  const brace = src.indexOf('{', at)
  return brace < 0 ? '' : bracedBody(src, brace, name)
}

// A signal handler is either a braced block or a single expression to EOL.
function handlerBody(src, name) {
  const re = new RegExp(`^[ \\t]*${name}[ \\t]*:`, 'm')
  const m = re.exec(src)
  if (!m) return ''
  const at = m.index + m[0].length
  let i = at
  while (i < src.length && /\s/.test(src[i])) i++
  if (src[i] === '{') return bracedBody(src, i, name)
  const end = src.indexOf('\n', at)
  return src.slice(at, end < 0 ? src.length : end).trim()
}

// The dwell Timer is a plain `Timer { id: actionTimer ... }`, not a property
// binding, so find the block by its id and lift that block's onTriggered.
function timerBody(src, id) {
  const re = /\bTimer\s*\{/g
  let m
  while ((m = re.exec(src)) !== null) {
    const body = bracedBody(src, src.indexOf('{', m.index), 'Timer')
    if (new RegExp(`\\bid:\\s*${id}\\b`).test(body)) return body
  }
  return ''
}

// Property expressions run until the next member declaration, so a multi-line
// ternary (captureGlyph / currentGlyph) is lifted whole.
function propertyExpression(src, name) {
  const re = new RegExp(`(?:readonly\\s+)?property\\s+\\w+\\s+${name}\\s*:`)
  const m = re.exec(src)
  if (!m) return ''
  const tail = src.slice(m.index + m[0].length)
  const member = /^\s*(?:readonly\s+)?(?:property|function|Timer|Connections|Component|CrossfadeIcon|on\w+\s*:|\})/m
  const next = member.exec(tail)
  return tail.slice(0, next ? next.index : tail.length).trim()
}

const ON_MIC = functionBody(SRC, 'onMicOnChanged')
const ON_CAM = functionBody(SRC, 'onCamOnChanged')
const ON_SHARE = functionBody(SRC, 'onShareOnChanged')
const FLASH = functionBody(SRC, '_flashAction')
const END = functionBody(SRC, '_endFlash')
const END_FOR = functionBody(SRC, '_endFlashFor')
const TICK = handlerBody(timerBody(SRC, 'actionTimer'), 'onTriggered')
const ACTION_ICON = propertyExpression(SRC, 'actionIcon')
const CAPTURE_GLYPH = propertyExpression(SRC, 'captureGlyph')
const CURRENT_GLYPH = propertyExpression(SRC, 'currentGlyph')

// --- turn-accurate harness --------------------------------------------------

function makeFlash({ seeded = true } = {}) {
  const privacy = { micOn: false, camOn: false, shareOn: false }
  const Core = { Privacy: privacy }
  const root = { _captureSeeded: seeded, flashSource: '' }
  let running = false
  const actionTimer = {
    restart() { running = true },
    stop() { running = false },
  }
  const run = (body, names = [], values = []) =>
    new Function('root', 'Core', 'actionTimer', ...names, body)(root, Core, actionTimer, ...values)
  const value = (expr) => new Function('root', 'Core', `return (${expr})`)(root, Core)

  Object.defineProperty(root, 'actionIcon', { get: () => value(ACTION_ICON) })
  Object.defineProperty(root, 'captureGlyph', { get: () => value(CAPTURE_GLYPH) })
  Object.defineProperty(root, 'currentGlyph', { get: () => value(CURRENT_GLYPH) })

  root._flashAction = (source) => run(FLASH, ['source'], [source])
  root._endFlash = () => run(END)
  root._endFlashFor = (source) => run(END_FOR, ['source'], [source])

  return {
    root,
    privacy,
    get running() { return running },
    mic(v) { privacy.micOn = v; run(ON_MIC) },
    cam(v) { privacy.camOn = v; run(ON_CAM) },
    share(v) { privacy.shareOn = v; run(ON_SHARE) },
    tick() { run(TICK) },
    glyph() { return root.currentGlyph },
  }
}

suite('bar/privacy-flash', 'the capture glyph flash and its source-owned dwell')

// ---------------------------------------------------------------------------
section('the wiring')

group('flash state is the owning source, not just the glyph', () => {
  match('a flashSource is tracked', SRC, /property\s+string\s+flashSource\s*:/)
  contains('the glyph is derived from the source', ACTION_ICON, 'root.flashSource')
  notMatch('no writable actionIcon is left', SRC, /^\s*property\s+string\s+actionIcon\s*:/m)
  match('actionIcon is derived instead', SRC, /readonly\s+property\s+string\s+actionIcon\s*:/)
  contains('the dwell has one clear path', END, 'root.flashSource = ""')
  contains('the timer ends through that path', TICK, 'root._endFlash()')
  contains('a mic start arms the mic source', ON_MIC, 'root._flashAction("mic")')
  contains('a cam start arms the cam source', ON_CAM, 'root._flashAction("cam")')
  contains('a mic end releases its own source', ON_MIC, 'root._endFlashFor("mic")')
  contains('a cam end releases its own source', ON_CAM, 'root._endFlashFor("cam")')
})

group('both capture starts arm the dwell', () => {
  const f = makeFlash()
  eq('idle glyph', f.glyph(), 'incognito')
  f.mic(true)
  eq('mic start shows the mic glyph', f.glyph(), 'mic-on')
  eq('mic start owns the flash', f.root.flashSource, 'mic')
  eq('mic start runs the dwell', f.running, true)
  f.mic(false)
  f.cam(true)
  eq('cam start shows the camera glyph', f.glyph(), 'camera')
  eq('cam start owns the flash', f.root.flashSource, 'cam')
  eq('cam start runs the dwell', f.running, true)
})

// ---------------------------------------------------------------------------
section('an early source stop returns the glyph at once')

group('the owning source ends the dwell', () => {
  const f = makeFlash()
  f.mic(true)
  f.mic(false)
  eq('mic stop clears the owner', f.root.flashSource, '')
  eq('mic stop stops the dwell', f.running, false)
  eq('mic stop returns to incognito', f.glyph(), 'incognito')

  f.cam(true)
  f.cam(false)
  eq('cam stop clears the owner', f.root.flashSource, '')
  eq('cam stop stops the dwell', f.running, false)
  eq('cam stop returns to incognito', f.glyph(), 'incognito')
})

group('the timer still runs out when the source keeps going', () => {
  const f = makeFlash()
  f.mic(true)
  eq('still showing before the tick', f.glyph(), 'mic-on')
  f.tick()
  eq('the tick clears the owner', f.root.flashSource, '')
  eq('the tick returns to incognito', f.glyph(), 'incognito')
  eq('the tick stops the timer', f.running, false)
})

group('an early end re-arms cleanly', () => {
  const f = makeFlash()
  f.mic(true)
  f.mic(false)
  f.mic(true)
  eq('a new start re-arms the owner', f.root.flashSource, 'mic')
  eq('a new start re-shows the glyph', f.glyph(), 'mic-on')
  eq('a new start re-runs the dwell', f.running, true)
})

// ---------------------------------------------------------------------------
section('a stale source edge never cuts a newer flash')

group('a superseded source stopping is inert', () => {
  const f = makeFlash()
  f.mic(true)
  f.cam(true)
  eq('cam owns after takeover', f.root.flashSource, 'cam')
  eq('cam glyph after takeover', f.glyph(), 'camera')
  f.mic(false)
  eq('mic stop leaves the cam owner', f.root.flashSource, 'cam')
  eq('mic stop leaves the cam glyph', f.glyph(), 'camera')
  eq('mic stop leaves the dwell running', f.running, true)
  f.cam(false)
  eq('cam stop ends it', f.glyph(), 'incognito')
})

group('an unrelated source end is inert', () => {
  const f = makeFlash()
  f.cam(true)
  f.mic(false)
  eq('unrelated edge keeps the glyph', f.glyph(), 'camera')
})

group('an end before seeding is inert', () => {
  const f = makeFlash({ seeded: false })
  f.mic(false)
  eq('no flash without seeding', f.glyph(), 'incognito')
  f.mic(true)
  eq('seeding still gates starts', f.root.flashSource, '')
  eq('no glyph without seeding', f.glyph(), 'incognito')
})

// ---------------------------------------------------------------------------
section('a share owns the glyph')

group('a share drops a pending flash', () => {
  const f = makeFlash()
  f.mic(true)
  eq('mic flash is up', f.glyph(), 'mic-on')
  f.share(true)
  eq('share owns the glyph', f.glyph(), 'screen-capture')
  eq('share cleared the flash owner', f.root.flashSource, '')
  eq('share stopped the dwell', f.running, false)
  f.mic(false)
  eq('a stale mic edge is inert', f.glyph(), 'screen-capture')
  f.share(false)
  eq('share end returns to incognito', f.glyph(), 'incognito')
})

group('a flash during a share is refused', () => {
  const f = makeFlash()
  f.share(true)
  f.cam(true)
  eq('no flash owner during a share', f.root.flashSource, '')
  eq('share glyph holds', f.glyph(), 'screen-capture')
  f.cam(false)
  eq('cam edge during share is inert', f.glyph(), 'screen-capture')
  f.share(false)
  eq('share end returns to incognito', f.glyph(), 'incognito')
})

finish()

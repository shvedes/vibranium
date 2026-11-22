#!/usr/bin/env node
// Suite: the bar's one blink clock, shared by the reveal and failure glyphs
// (BAR-7, BAR-14).
//
//   shell/features/bar/RevealFlash.qml                     the one phase clock
//   shell/features/bar/modules/Bluetooth/Bluetooth.qml     nameSlide consumer
//   shell/features/bar/modules/Network/Network.qml         nameSlide consumer
//   shell/features/bar/modules/Downloader/Downloader.qml   counted failure blink
//
// Limitation: a bar module is a BarModule and cannot be constructed under
// QT_QPA_PLATFORM=offscreen; RevealFlash is a plain QtObject and can, but the
// two findings are about the wiring around it. This suite reads the shipped
// QML, lifts the clock handlers and the two expressions by brace matching, and
// drives them over a turn timeline. It pins the mechanism, not the pixels:
// one writer of the phase, no published duration or slide copy, and a counted
// blink that opens on its on colour and ends on the off colour.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const FLASH = read('features', 'bar', 'RevealFlash.qml')
const BLUETOOTH = read('features', 'bar', 'modules', 'Bluetooth', 'Bluetooth.qml')
const NETWORK = read('features', 'bar', 'modules', 'Network', 'Network.qml')
const DOWNLOADER = read('features', 'bar', 'modules', 'Downloader', 'Downloader.qml')

// Lift a `{ ... }` body by brace matching, so nested ifs survive intact.
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

// A handler is either a braced block or a single expression to end of line.
// Missing handlers return '' so the suite records a failure instead of dying.
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

function functionBody(src, name) {
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return ''
  const brace = src.indexOf('{', at)
  return brace < 0 ? '' : bracedBody(src, brace, name)
}

function timerBody(src, id) {
  const at = src.indexOf(`property Timer ${id}: Timer`)
  if (at < 0) return ''
  const brace = src.indexOf('{', at)
  return brace < 0 ? '' : bracedBody(src, brace, id)
}

function componentBlock(src, type) {
  const re = new RegExp(`\\b${type}[ \\t]*\\{`)
  const m = re.exec(src)
  if (!m) return ''
  return bracedBody(src, src.indexOf('{', m.index), type)
}

function expression(src, name) {
  const re = new RegExp(`(?:readonly\\s+)?property\\s+\\w+\\s+${name}\\s*:\\s*([^\\n]+(?:\\n[ \\t]+&&[^\\n]+)?)`)
  return (src.match(re) || [])[1] || ''
}

const GREEN_PHASE = expression(FLASH, 'greenPhase')
const TRIGGER = timerBody(FLASH, 'blinkTimer')
const TICK = handlerBody(TRIGGER, 'onTriggered')
const RUNNING = handlerBody(TRIGGER, 'onRunningChanged')
const REVEALED = handlerBody(FLASH, 'onRevealedChanged')
const ACTIVE = handlerBody(FLASH, 'onActiveChanged')
const PULSE = functionBody(FLASH, 'pulse')

const NAME_SLIDE_RE = /property\s+real\s+nameSlide\s*:\s*([^\n]+)/

// A turn-accurate model of the lifted clock. `restart` goes through stop/start
// so the timer's own running-change edge arms a counted sequence the same way
// the QML engine does; a pulse that arms the count directly still works.
function makeFlash(count, active) {
  const root = { revealed: false, active, count, phase: true, left: 0 }
  let timer
  const call = (body) => new Function('root', 'blinkTimer', 'stop', 'running', body)(
    root, timer, () => timer.stop(), timer.running)
  timer = {
    running: false,
    start() { this.running = true; call(RUNNING) },
    stop() {
      if (!this.running) return
      this.running = false
      call(RUNNING)
    },
    restart() { this.stop(); this.start() },
    trigger() { call(TICK) },
  }
  return {
    root,
    timer,
    pulse() { call(PULSE) },
    reveal(v) { root.revealed = v; call(REVEALED) },
    gate(v) { root.active = v; call(ACTIVE) },
    green() {
      return Boolean(new Function('root', 'blinkTimer', `return (${GREEN_PHASE})`)(root, timer))
    },
  }
}

suite('bar/blink-clock', 'BAR-7 and BAR-14: one clock behind two glyphs')

// ---------------------------------------------------------------------------
section('BAR-7: the reveal owns one phase clock and no copies')

group('the phase has one writer', () => {
  notMatch('the old two-writer tick is gone', FLASH, /_flashTick/)
  match('the phase is declared once', FLASH, /property\s+bool\s+phase\s*:/)
  eq('only one phase declaration', (FLASH.match(/property\s+bool\s+phase\s*:/g) || []).length, 1)
  const writes = (src) => (src.match(/\bphase\s*=/g) || []).length
  eq('the timer is the only writer of the phase', writes(TICK), writes(FLASH))
  notMatch('the reveal edge never writes the phase', REVEALED, /\bphase\s*=/)
  notMatch('the gate edge never writes the phase', ACTIVE, /\bphase\s*=/)
  notMatch('pulse never writes the phase', PULSE, /\bphase\s*=/)
  contains('the reveal edge starts the clock', REVEALED, 'blinkTimer.restart()')
  contains('the reveal edge stops the clock', REVEALED, 'blinkTimer.stop()')
})

group('the published copy and the dead duration are gone', () => {
  notMatch('no colorMs is published', FLASH, /\bcolorMs\b/)
  notMatch('no slowMs is published', FLASH, /\bslowMs\b/)
  notMatch('no nameSlide is published by the primitive', FLASH, /property\s+real\s+nameSlide/)
  contains('the colour is the one derivation', GREEN_PHASE, 'phase')
  contains('the colour is gated by the running clock', GREEN_PHASE, 'blinkTimer.running')
  notMatch('the colour no longer reads the old tick', GREEN_PHASE, /_flashTick/)
})

group('both pill consumers derive the slide from their own two bools', () => {
  for (const [label, src] of [['Bluetooth', BLUETOOTH], ['Network', NETWORK]]) {
    notMatch(`${label} no longer copies reveal.nameSlide`, src, /reveal\s*\.\s*nameSlide/)
    const expr = (src.match(NAME_SLIDE_RE) || [])[1] || ''
    for (const [revealed, island, want] of [
      [false, false, 0], [true, false, 1], [false, true, 1], [true, true, 1],
    ]) {
      let got
      try {
        got = new Function('root', `return (${expr})`)(
          { revealed, islandReveal: island })
      } catch {
        got = 'threw'
      }
      eq(`${label} slide at revealed=${revealed} island=${island}`, got, want)
    }
    contains(`${label} still reads the one glyph colour`, src, 'glyphColor: reveal.glyphColor')
  }
})

// ---------------------------------------------------------------------------
section('BAR-14: the failure blink is the same clock, counted')

group('the module supplies the count and the gate, not a timer', () => {
  const flash = componentBlock(DOWNLOADER, 'RevealFlash')
  contains('the count is five', flash, 'count: 5')
  contains('the active gate is the island', flash, 'active: !root.islandOpen')
  contains('the cadence is the shared blink interval', flash, 'blinkMs: Ui.blinkMs')
  contains('the on colour is red', flash, 'greenColor: Ui.solid("red")')
  contains('the off colour is the resting foreground', flash, 'restingColor: Ui.solid("foreground_0")')
  notMatch('no local blink timer', DOWNLOADER, /^\s*Timer\s*\{/m)
  notMatch('no local on flag', DOWNLOADER, /_blinkOn/)
  notMatch('no local turn counter', DOWNLOADER, /_blinkLeft/)
  const fail = functionBody(DOWNLOADER, '_flashFailure')
  notMatch('_flashFailure writes no blink property', fail, /\w+\s*=/)
  contains('_flashFailure starts the one clock', fail, 'pulse()')
  match('the glyph reads the one derivation', DOWNLOADER, /glyphColor:\s*\w+\.glyphColor/)
})

group('the continuous blink is revealed-driven and ends dark', () => {
  const f = makeFlash(0, true)
  eq('nothing blinks before the reveal', f.timer.running, false)
  f.reveal(true)
  eq('the reveal starts the clock', f.timer.running, true)
  f.timer.trigger()
  eq('the first tick turns the phase off', f.root.phase, false)
  eq('the glyph is off', f.green(), false)
  f.timer.trigger()
  eq('the next tick turns the phase on', f.root.phase, true)
  eq('the glyph is on', f.green(), true)
  f.reveal(false)
  eq('the reveal end stops the clock', f.timer.running, false)
  eq('no green survives the reveal end', f.green(), false)
})

group('a counted blink opens on, ends off, and can be retriggered', () => {
  const f = makeFlash(5, true)
  f.pulse()
  eq('a pulse starts the clock', f.timer.running, true)
  eq('the first phase is the on colour', f.root.phase, true)
  eq('the glyph is on at the open', f.green(), true)
  let onPhases = f.green() ? 1 : 0
  const seen = []
  for (let i = 0; i < 5; i++) {
    f.timer.trigger()
    seen.push(f.green() ? '1' : '0')
    if (f.green()) onPhases++
  }
  eq('five ticks give three on phases', onPhases, 3)
  eq('the sequence ends off', seen[seen.length - 1], '0')
  eq('the clock stops itself', f.timer.running, false)
  eq('the phase is re-armed for the next pulse', f.root.phase, true)
  f.pulse()
  eq('a second pulse restarts the clock', f.timer.running, true)
  eq('a second pulse opens on again', f.green(), true)
})

group('the gate stops a blink that can no longer be seen', () => {
  const f = makeFlash(5, true)
  f.pulse()
  eq('the blink is live before the gate closes', f.timer.running, true)
  f.gate(false)
  eq('closing the gate stops it', f.timer.running, false)
  eq('and the glyph goes dark', f.green(), false)
  f.pulse()
  eq('a pulse while gated is inert', f.timer.running, false)
  f.gate(true)
  f.pulse()
  eq('reopening the gate lets a new pulse run', f.timer.running, true)
})

finish()

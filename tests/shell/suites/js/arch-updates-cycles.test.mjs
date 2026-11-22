#!/usr/bin/env node
// Suite: ArchUpdates queued-cycle isolation (SVC-1).
//
//   shell/services/system/ArchUpdates.qml   refresh, _startFetches,
//                                           _finishRefresh, and both fetch
//                                           Process.onExited handlers
//
// Limitation: ArchUpdates is a Singleton that forks checkupdates and yay, waits
// on the boot gate, and can send a desktop notification. Offscreen Qt has no
// mirror/RPC to query and no notification daemon, so the live two-cycle frame
// cannot be observed here. This suite reads the real QML, lifts the four
// function bodies by brace matching, and drives two overlapping cycles against
// stubbed processes and stdio. What is pinned is the mechanism: a queued cycle
// starts with clean result slots, publishes exactly once, and a retired
// generation cannot publish - not the network answers themselves.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, contains, notContains, match, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const SERVICE = fs.readFileSync(
  path.join(SHELL_DIR, 'services', 'system', 'ArchUpdates.qml'), 'utf8')

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
  if (at < 0) throw new Error(`ArchUpdates.qml has no ${head}`)
  return bracedBody(src, src.indexOf('{', at), head)
}

function extractProcessHandler(src, id, handler) {
  const idAt = src.indexOf(`id: ${id}`)
  if (idAt < 0) throw new Error(`ArchUpdates.qml has no id ${id}`)
  const procAt = src.lastIndexOf('Process {', idAt)
  if (procAt < 0) throw new Error(`ArchUpdates.qml has no Process for ${id}`)
  const block = bracedBody(src, src.indexOf('{', procAt), `Process ${id}`)
  const at = block.indexOf(`${handler}:`)
  if (at < 0) throw new Error(`Process ${id} has no ${handler}`)
  return bracedBody(block, block.indexOf('{', block.indexOf('=>', at)), `${id}.${handler}`)
}

const REFRESH_BODY = extractFunction(SERVICE, 'refresh')
const START_BODY = extractFunction(SERVICE, '_startFetches')
const FINISH_BODY = extractFunction(SERVICE, '_finishRefresh')
const OFFICIAL_BODY = extractProcessHandler(SERVICE, 'refreshProc', 'onExited')
const AUR_BODY = extractProcessHandler(SERVICE, 'aurProc', 'onExited')

// The lifted bodies read unqualified singleton properties (notably the bare
// `refreshQueued = true` in refresh). `with (root)` reproduces QML scope
// resolution instead of leaking a global.
function makeSim(threshold = 2) {
  const publishes = []
  const notifies = []
  const logs = []
  const sim = { publishes, notifies, logs, scheduled: 0 }

  const root = {
    tag: 'archUpdates',
    notifyThreshold: threshold,
    state: 'idle',
    errorText: '',
    updatedAt: 0,
    refreshQueued: false,
    _why: '',
    _whyNext: '',
    _sentAt: 0,
    _fetchGeneration: 0,
    _officialDone: false,
    _aurDone: false,
    _officialPkgs: [],
    _aurPkgs: [],
    _officialErr: '',
    _aurErr: '',
    _packages: [],
  }
  // updatedAt is written once at the end of each completed merge, after state,
  // packages and errorText are all final: one setter write is one publish.
  Object.defineProperty(root, 'updatedAt', {
    configurable: true,
    get() { return this._updatedAt },
    set(v) {
      this._updatedAt = v
      publishes.push({
        seq: publishes.length + 1,
        packages: this.packages.slice(),
        state: this.state,
        errorText: this.errorText,
      })
    },
  })
  Object.defineProperty(root, 'packages', {
    configurable: true,
    get() { return this._packages },
    set(v) { this._packages = v },
  })

  const proc = () => ({ running: false, command: [] })
  const refreshProc = proc()
  const aurProc = proc()
  const notifyProc = proc()
  const refreshOut = { text: '' }
  const refreshErr = { text: '' }
  const aurOut = { text: '' }
  const aurErr = { text: '' }
  const Log = {
    info: (s) => logs.push(`info: ${s}`),
    debug: (s) => logs.push(`debug: ${s}`),
  }

  const refreshFn = new Function('root', 'refreshProc', 'aurProc', 'why',
    `with (root) {\n${REFRESH_BODY}\n}`)
  const startFn = new Function('root', 'refreshProc', 'aurProc',
    `with (root) {\n${START_BODY}\n}`)
  const finishFn = new Function('root', 'Log', 'gen',
    `with (root) {\n${FINISH_BODY}\n}`)
  const officialFn = new Function('root', 'refreshOut', 'refreshErr', 'Log', 'code', 'status',
    `with (root) {\n${OFFICIAL_BODY}\n}`)
  const aurFn = new Function('root', 'aurOut', 'aurErr', 'Log', 'code', 'status',
    `with (root) {\n${AUR_BODY}\n}`)

  root.refresh = (why) => refreshFn(root, refreshProc, aurProc, why)
  root._startFetches = () => startFn(root, refreshProc, aurProc)
  root._finishRefresh = (gen) => finishFn(root, Log, gen)
  root._parse = (text, source) => String(text || '').split('\n')
    .map((s) => s.trim().split(/\s+/)[0]).filter(Boolean).map((name) => ({ name, source }))
  root._notifyAllowed = () => true
  root._scheduleNotifyCheck = () => { sim.scheduled++ }
  root._notifyUpdates = () => {
    notifies.push({ count: root.packages.length })
    notifyProc.running = true
  }

  sim.root = root
  sim.refreshProc = refreshProc
  sim.aurProc = aurProc
  sim.refresh = (why) => root.refresh(why)
  sim.finish = (gen) => root._finishRefresh(gen)
  sim.names = (i) => publishes[i].packages.map((p) => p.name)
  // QML clears running before onExited is delivered; set it first so a queued
  // cycle started inside the handler stays running.
  sim.officialExit = (code, out, err = '') => {
    refreshOut.text = out
    refreshErr.text = err
    refreshProc.running = false
    officialFn(root, refreshOut, refreshErr, Log, code, 0)
  }
  sim.aurExit = (code, out, err = '') => {
    aurOut.text = out
    aurErr.text = err
    aurProc.running = false
    aurFn(root, aurOut, aurErr, Log, code, 0)
  }
  return sim
}

// Cycle 1 is live when the caller's ask queues cycle 2. The follow-up starts
// at the end of cycle 1; its first child exit is where a stale slot would
// otherwise publish a mixed count and a wrong notification.
function driveOverlap(sim, aur1) {
  sim.refresh('timer')
  sim.refresh('caller')
  sim.officialExit(0, 'o1 1 -> 2')
  sim.aurExit(aur1.code, aur1.out, aur1.err)
  sim.officialExit(0, 'n1 1 -> 2\nn2 1 -> 2\nn3 1 -> 2')
  sim.aurExit(0, 'm1 1 -> 2')
}

const C1 = ['o1', 'a1']
const C2 = ['n1', 'n2', 'n3', 'm1']

suite('arch-updates cycles', 'queued fetch generations and clean result slots')

// ---------------------------------------------------------------------------
section('a queued follow-up never publishes a mixed result')

group('two overlapping cycles with both AUR checks healthy', () => {
  const sim = makeSim()
  driveOverlap(sim, { code: 0, out: 'a1 1 -> 2', err: '' })

  eq('one publish per cycle', sim.publishes.length, 2)
  eq('the queued cycle advanced the generation', sim.root._fetchGeneration, 2)
  eq('cycle 1 published only its own data', sim.names(0), C1)
  eq('cycle 2 published only its own data', sim.names(1), C2)
  eq('no published frame mixes the two cycles', sim.publishes.every((p) => {
    const names = p.packages.map((x) => x.name)
    return names.every((n) => C1.includes(n)) || names.every((n) => C2.includes(n))
  }), true)
  eq('one notification, not one per child', sim.notifies.length, 1)
  eq('the notification reports the complete count', sim.notifies[0].count, 4)
})

group('a stale AUR error from cycle 1 does not leak into cycle 2', () => {
  const sim = makeSim()
  driveOverlap(sim, { code: 1, out: '', err: 'rpc down' })

  eq('one publish per cycle', sim.publishes.length, 2)
  eq('cycle 1 keeps its tolerated AUR note', sim.publishes[0].errorText,
    'AUR check failed (rpc down)')
  eq('cycle 2 has no stale AUR note', sim.publishes[1].errorText, '')
  eq('one notification with the complete count', sim.notifies.length, 1)
  eq('the notification count is cycle 2 only', sim.notifies[0].count, 4)
})

// ---------------------------------------------------------------------------
section('a retired generation cannot publish')

group('a late finish from the previous cycle is refused', () => {
  const sim = makeSim()
  driveOverlap(sim, { code: 0, out: 'a1 1 -> 2', err: '' })
  const before = sim.publishes.length
  sim.finish(1)

  eq('no extra publish', sim.publishes.length, before)
  eq('the live result stays intact', sim.names(before - 1), C2)
  eq('the live error text stays intact', sim.publishes[before - 1].errorText, '')
})

// ---------------------------------------------------------------------------
section('the mechanism lives at the cycle boundary')

group('resets and generation are owned by _startFetches', () => {
  notContains('refresh no longer resets the result slots', REFRESH_BODY, '_officialDone')
  contains('_startFetches owns the slot resets', START_BODY, '_officialDone')
  contains('_startFetches bumps the generation', START_BODY, '_fetchGeneration')
  match('_finishRefresh refuses a stale generation', FINISH_BODY,
    /gen\s*!==\s*root\._fetchGeneration/)
  for (const [label, body] of [['official', OFFICIAL_BODY], ['aur', AUR_BODY]]) {
    match(`the ${label} exit captures the generation`, body,
      /const gen\s*=\s*root\._fetchGeneration/)
    contains(`the ${label} exit passes its generation`, body, '_finishRefresh(gen)')
  }
})

finish()

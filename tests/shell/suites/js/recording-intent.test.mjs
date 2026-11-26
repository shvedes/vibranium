#!/usr/bin/env node
// Suite: recording intent (SVC-3).
//
//   shell/services/media/Recording.qml   the marker watch, the click verbs
//                                        and the menu provider guard
//
// Limitation: Recording is a Quickshell singleton wired to Watch.subscribe,
// FileView, ProviderHost, Bus and vb-core-recording. Offscreen has no runtime
// marker file, no watch governor and no recorder process, so this suite lifts
// the shipped handlers by brace matching and drives them against a stubbed
// marker and a spy bus. What is pinned is write ownership and frame order: a
// coalesced watch tick landing while the marker still exists must not publish
// the opposite state after a stop, then correct it. The live helper sequence
// stays source-level here.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, ne, contains, notContains, skip, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const SRC = fs.readFileSync(
  path.join(SHELL_DIR, 'services', 'media', 'Recording.qml'), 'utf8')

// Lift a block by brace matching so nested ifs and closures survive intact.
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

function maybeFunction(src, name) {
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return null
  return bracedBody(src, src.indexOf('{', at), name)
}

// A one-line signal handler compiles as an expression; a braced one is lifted
// as a body. Both are returned as callable source text.
function maybeHandler(src, name) {
  const m = new RegExp(`^[ \\t]*${name}[ \\t]*:[ \\t]*(.+)$`, 'm').exec(src)
  if (!m) return null
  const tail = m[1].trim()
  if (tail.startsWith('{')) {
    return bracedBody(src, m.index + m[0].indexOf('{'), name)
  }
  return tail
}

function maybePropertyExpr(src, name) {
  const re = new RegExp(`(?:readonly\\s+)?property\\s+\\w+\\s+${name}\\s*:\\s*([\\s\\S]*?)(?:\\n\\s*\\n|\\n\\s*(?:readonly\\s+)?property\\b|\\n\\s*function\\b)`)
  const m = re.exec(src)
  return m ? m[1].trim() : null
}

function maybeTimerBody(src, id) {
  const re = /^[ \t]*Timer[ \t]*\{/gm
  let m
  while ((m = re.exec(src)) !== null) {
    const body = bracedBody(src, src.indexOf('{', m.index), 'Timer')
    if (new RegExp(`\\bid\\s*:\\s*${id}\\b`).test(body)) return body
  }
  return null
}

function maybeWatchBody(src) {
  const at = src.indexOf('Watch.subscribe(')
  if (at < 0) return null
  const arrow = src.indexOf('=>', src.indexOf('(text)', at))
  if (arrow < 0) return null
  return bracedBody(src, src.indexOf('{', arrow), 'Watch callback')
}

// The sim owns the marker and the clock. Every write to a file-backed property
// records its value and fires the real onXChanged handler, so the publish log
// is the sequence the bus would have seen, not an end-state snapshot.
function makeSim() {
  const sim = {
    marker: false,
    now: 1_700_000_000_000,
    publishes: [],
    spawns: [],
    ongoingWrites: [],
    startedWrites: [],
    timerStops: 0,
    timerRestarts: 0,
    hasExpiry: false,
  }
  const root = {}
  const Bus = {
    publish(topic, payload) { sim.publishes.push({ topic, payload: { ...payload } }) },
  }
  const Paths = { vibraniumRuntime: '/runtime', vibraniumHome: '/home' }
  const probeFile = {
    path: '',
    waitForJob() { return true },
    text() { return sim.marker ? '4242\n' : '' },
  }
  const Quickshell = {
    execDetached(args) { sim.spawns.push(args.slice()) },
    env() { return 'baremetal' },
  }
  const intentExpiry = {
    intentId: -1,
    restart() { sim.timerRestarts++ },
    stop() { sim.timerStops++ },
  }
  const ProviderHost = {
    claimProvider(name, descriptor) { sim.provider = descriptor; return name },
  }

  const names = {
    root, Bus, Paths, probeFile, Quickshell, ProviderHost, intentExpiry,
    Date: { now: () => sim.now },
  }
  const args = Object.keys(names)
  const values = Object.values(names)
  const bind = (body, params = []) => (...extra) =>
    new Function(...args, ...params, body)(...values, ...extra)
  const call = expr => expr ? bind(expr) : () => {}

  const onOngoing = call(maybeHandler(SRC, 'onOngoingChanged'))
  const onConfirmed = call(maybeHandler(SRC, 'onConfirmedChanged'))

  let ongoing = false
  Object.defineProperty(root, 'ongoing', {
    get: () => ongoing,
    set(v) {
      if (ongoing === v) return
      ongoing = v
      sim.ongoingWrites.push(v)
      onOngoing()
    },
  })
  let confirmed = false
  Object.defineProperty(root, 'confirmed', {
    get: () => confirmed,
    set(v) {
      if (confirmed === v) return
      confirmed = v
      onConfirmed()
    },
  })
  let startedAtMs = 0
  Object.defineProperty(root, 'startedAtMs', {
    get: () => startedAtMs,
    set(v) { startedAtMs = v; sim.startedWrites.push(v) },
  })

  // A tree without the derived fact reads the file-backed value directly,
  // which is exactly the guard the finding pins as the bug.
  const shownExpr = maybePropertyExpr(SRC, 'shownOngoing') || 'root.ongoing'
  const shownFn = bind(`return (${shownExpr})`)
  Object.defineProperty(root, 'shownOngoing', { get: () => shownFn() })

  root.pendingIntent = null
  root._intentSeq = 0
  root._isVm = () => false
  root._notifyVm = () => {}
  const params = { _setIntent: ['want'], _start: ['region'], start: ['region'] }
  for (const name of [
    '_publish', '_syncOngoing', '_refresh', '_setIntent', '_start',
    '_stopOngoing', 'start', 'stop', 'toggle', 'open', 'close',
    '_registerMenuProvider',
  ]) {
    const body = maybeFunction(SRC, name)
    if (body) root[name] = bind(body, params[name])
  }

  // Component.onCompleted registers the provider before the watcher runs.
  if (root._registerMenuProvider) root._registerMenuProvider()

  const watchBody = maybeWatchBody(SRC)
  sim.watchTick = watchBody ? bind(watchBody) : () => root._refresh()

  const timerBody = maybeTimerBody(SRC, 'intentExpiry')
  const trig = timerBody ? maybeHandler(timerBody, 'onTriggered') : null
  sim.hasExpiry = !!trig
  sim.expireTick = trig ? bind(trig) : () => {}
  sim.intentExpiry = intentExpiry
  sim.root = root
  return sim
}

suite('recording intent', 'the state file is the only writer of recording state')

// Both onXChanged handlers publish, so one file flip can emit two payloads with
// the same value. Collapsing consecutive duplicates gives the frame sequence:
// what matters here is that it never carries the opposite value in between.
const framesOf = sim => sim.publishes
  .map(p => p.payload.ongoing)
  .filter((v, i, all) => i === 0 || v !== all[i - 1])

// ---------------------------------------------------------------------------
section('write ownership')

group('the click verbs never touch the file-backed state', () => {
  for (const verb of ['_start', '_stopOngoing']) {
    const body = maybeFunction(SRC, verb)
    notContains(`${verb} does not write ongoing`, body, 'root.ongoing')
    notContains(`${verb} does not write confirmed`, body, 'root.confirmed')
    notContains(`${verb} does not write startedAtMs`, body, 'root.startedAtMs')
  }
})

group('_refresh is the one writer, and it reads the watched file', () => {
  const body = maybeFunction(SRC, '_refresh')
  contains('_refresh probes the marker', body, 'root._syncOngoing()')
  contains('_refresh stamps the start before publishing the flip', body,
    'root.startedAtMs = live ? Date.now() : 0')
  const stamp = body.indexOf('root.startedAtMs = live')
  const flip = body.indexOf('root.ongoing = live')
  eq('the stamp precedes the ongoing flip', stamp >= 0 && flip > stamp, true)
  const watch = maybeWatchBody(SRC)
  contains('the watch callback calls _refresh', watch, 'root._refresh()')
  contains('the subscription is still deferred to the event loop', SRC,
    'Qt.callLater(() => {')
  contains('the marker path is unchanged', SRC,
    'Watch.subscribe(Paths.vibraniumRuntime + "/recording-ongoing"')
})

group('the bus contract is untouched', () => {
  const body = maybeFunction(SRC, '_publish')
  contains('the topic is the same', body, 'Bus.publish("recording.bus"')
  contains('the ongoing key is the same', body, 'ongoing: root.ongoing')
  contains('the stamp key is the same', body, 'startedAt: root.startedAtMs')
  contains('the confirmed key is the same', body, 'confirmed: root.confirmed')
})

// ---------------------------------------------------------------------------
section('a stop never publishes the opposite frame')

group('picking a region waits for actual recording state', () => {
  const sim = makeSim()
  eq('start accepts a region', sim.root.start(true), true)
  eq('the helper opens the region picker', sim.spawns, [
    ['/home/bin/vb-core-recording', '--region'],
  ])
  eq('the recording stays idle while picking', sim.root.shownOngoing, false)
  sim.marker = true
  sim.watchTick()
  eq('the marker publishes the recording', framesOf(sim), [true])
})

group('a coalesced tick before marker deletion is inert', () => {
  const sim = makeSim()
  sim.root.start()
  sim.marker = true
  sim.watchTick()
  const before = sim.publishes.length
  eq('the real start published the running frame', framesOf(sim), [true])

  eq('the menu offers stop while running', sim.root.shownOngoing, true)
  sim.root.stop()
  eq('the menu is collapsed on stop', sim.root.shownOngoing, false)
  eq('the file-backed fact is still true', sim.root.ongoing, true)
  eq('the menu sub is gone', sim.provider.sub(), null)
  eq('the click published nothing', sim.publishes.length, before)

  sim.watchTick()
  eq('a stale tick publishes nothing', sim.publishes.length, before)
  eq('a stale tick leaves the file-backed fact alone', sim.root.ongoing, true)
  eq('the intent survives the stale tick', sim.root.pendingIntent?.want, 'stop')

  sim.marker = false
  sim.watchTick()
  eq('the real deletion publishes the idle frame', framesOf(sim), [true, false])
  eq('no publish after the click carried the old state',
    sim.publishes.slice(before).every(p => p.payload.ongoing === false), true)
  eq('the ongoing value was written twice, not four times', sim.ongoingWrites, [true, false])
  eq('the intent is retired by the file edge', sim.root.pendingIntent, null)
  eq('the deadline timer was stopped on retire', sim.timerStops > 0, true)
  eq('the deadline was rearmed once per click', sim.timerRestarts, 2)
  eq('only the file path wrote the stamp', sim.startedWrites, [sim.now, 0])
  eq('the helper was spawned once per click', sim.spawns, [
    ['/home/bin/vb-core-recording'],
    ['/home/bin/vb-core-recording', '--stop'],
  ])
})

group('the same guard holds before marker creation on start', () => {
  const sim = makeSim()
  sim.root.start()
  eq('the menu expands before the file exists', sim.root.shownOngoing, true)
  eq('the file-backed fact is still false', sim.root.ongoing, false)
  eq('the click published nothing', sim.publishes.length, 0)
  eq('the menu already offers stop', sim.provider.sub(), 'Select to stop recording')

  sim.watchTick()
  eq('a stale tick publishes nothing', sim.publishes.length, 0)
  eq('the intent survives it', sim.root.pendingIntent?.want, 'start')

  sim.marker = true
  sim.watchTick()
  eq('the real creation publishes the running frame', framesOf(sim), [true])
  eq('the stamp pairs with the flip', sim.publishes[sim.publishes.length - 1].payload, {
    ongoing: true,
    startedAt: sim.now,
    confirmed: true,
  })
  eq('ongoing was written once', sim.ongoingWrites, [true])
  eq('the payload keys are stable', Object.keys(sim.publishes[sim.publishes.length - 1].payload),
    ['ongoing', 'startedAt', 'confirmed'])
  eq('the topic is stable', sim.publishes[sim.publishes.length - 1].topic, 'recording.bus')
})

// ---------------------------------------------------------------------------
section('the intent is bounded and generation-guarded')

group('a failed spawn retires on a deadline, not on a poll', () => {
  const sim = makeSim()
  if (!sim.hasExpiry) {
    skip('no intentExpiry timer on this tree', 'the old tree has no bounded grace')
  } else {
    sim.root.start()
    sim.expireTick()
    eq('the grace clears the intent', sim.root.pendingIntent, null)
    eq('the menu returns to file truth', sim.root.shownOngoing, false)
    eq('the grace writes no file-backed state', sim.ongoingWrites, [])
    eq('the grace publishes nothing', sim.publishes.length, 0)
    const body = maybeTimerBody(SRC, 'intentExpiry')
    contains('the grace is one bound deadline', body, 'interval: root._intentGraceMs')
    notContains('the deadline does not repeat', body, 'repeat: true')
    notContains('the deadline does not re-read the file', body, '_syncOngoing')
    notContains('the deadline does not touch the probe', body, 'probeFile')
  }
})

group('a late fire cannot retire a newer intent', () => {
  const sim = makeSim()
  if (!sim.hasExpiry) {
    skip('no intentExpiry timer on this tree', 'the old tree has no bounded grace')
  } else {
    sim.root._start()
    const first = sim.root.pendingIntent.id
    sim.root._stopOngoing()
    const second = sim.root.pendingIntent.id
    ne('a new click mints a new generation', second, first)
    eq('the timer carries the new generation', sim.intentExpiry.intentId, second)

    sim.intentExpiry.intentId = first
    sim.expireTick()
    eq('a stale fire leaves the newer intent alone', sim.root.pendingIntent.id, second)

    sim.intentExpiry.intentId = second
    sim.expireTick()
    eq('the matching fire retires it', sim.root.pendingIntent, null)
  }
})

finish()

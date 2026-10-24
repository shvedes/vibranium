#!/usr/bin/env node
// Reconcile protocol for the persistent default-device loopback
// (shell/services/audio/Audio.qml).
//
// The pure port/link planning already has audio-loopback.test.mjs. This
// suite covers the orchestration around it: the generation-guarded async
// protocol that must converge no matter when the setting flips or the
// default devices arrive.
//
// Method: the loopback functions are extracted textually from Audio.qml and
// evaluated against stubs (Qt.callLater as a manual queue, Exec.runJob as
// manually-completed jobs, ShellState in memory, the real AudioLoopback.js
// for planning). No copies: what is tested is what ships.
//
// Regression: enable, then flip the setting (or have the default devices
// arrive) while reads are still in flight. The stale read completions must
// release the busy flag and reschedule - otherwise the service stops
// reacting to the setting until the next shell restart, which is exactly
// "off regardless of the setting, manual rewiring required".

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, finish, SHELL_DIR } from '../../lib/assert.mjs'

const L = loadLib(path.join(SHELL_DIR, 'common', 'audio', 'AudioLoopback.js'))
const AUDIO_QML = fs.readFileSync(path.join(SHELL_DIR, 'services', 'audio', 'Audio.qml'), 'utf8')

const FNS = [
  '_scheduleLoopback',
  '_reconcileLoopback',
  '_readLoopbackPorts',
  '_reconcileLinks',
  '_readLoopback',
  '_runLoopbackCommands',
  '_sendNextLoopbackRemoval',
  '_sendNextLoopbackCommand',
  '_finishLoopback',
]

// Lift each `function NAME(...) { ... }` out of the QML source by
// brace-matching, so nested blocks and closures survive intact.
function extract(src, name) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) throw new Error(`Audio.qml has no ${head}`)
  let i = src.indexOf('{', at)
  if (i < 0) throw new Error(`Audio.qml ${head} has no body`)
  let depth = 0
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(at, j + 1)
    }
  }
  throw new Error(`Audio.qml ${head} body never closes`)
}

// Fixtures shaped like the real pw-link surfaces: `-o`/`-i` list bare
// `node:port` names, `-l -I` lists `id name` rows with link arrows.
const MIC = { id: 41, name: 'mic' }
const SPEAKER = { id: 71, name: 'speaker' }
const OUTPUTS_TEXT = ['mic:capture_FL', 'mic:capture_FR', 'other:capture_FL'].join('\n') + '\n'
const INPUTS_TEXT = ['speaker:playback_FL', 'speaker:playback_FR', 'other:playback_FL'].join('\n') + '\n'
const EMPTY_LINKS = ''
const PAIR_OUTPUTS = ['mic:capture_FL', 'mic:capture_FR']
const PAIR_INPUTS = ['speaker:playback_FL', 'speaker:playback_FR']

function okPorts(kind) {
  if (kind === 'outputs') return { code: 'ok', stdout: OUTPUTS_TEXT, stderr: '' }
  if (kind === 'inputs') return { code: 'ok', stdout: INPUTS_TEXT, stderr: '' }
  return { code: 'ok', stdout: EMPTY_LINKS, stderr: '' }
}

// One simulated Audio singleton. Qt.callLater is a manual FIFO the test
// flushes when it wants an event-loop turn; Exec.runJob records argv and
// leaves the job pending until the test completes it, so races are
// deterministic: nothing runs unless the test says so.
function makeSim() {
  const sim = {
    queue: [],
    pendingJobs: [],
    issued: [],
    store: {},
    nodes: [MIC, SPEAKER],
    Qt: { callLater(fn) { sim.queue.push(fn) } },
    Loopback: L,
    Core: null,
    Exec: null,
    ShellState: null,
    root: null,
  }
  sim.Core = { PipeWireState: { get nodes() { return sim.nodes } } }
  sim.Exec = {
    runJob(argv, owner, opts) {
      sim.issued.push(argv.slice())
      const job = { argv: argv.slice(), owner, opts }
      sim.pendingJobs.push(job)
      return job
    },
  }
  sim.ShellState = {
    section(name) {
      const v = sim.store[String(name)]
      return v !== undefined ? v : null
    },
    updateSection(name, patch) {
      const cur = sim.store[String(name)]
      const base = cur !== null && typeof cur === 'object' && !Array.isArray(cur) ? cur : {}
      sim.store[String(name)] = Object.assign({}, base, patch)
      return true
    },
  }
  const root = {
    _loopbackError: '',
    _loopbackBusy: false,
    _loopbackQueued: false,
    _loopbackSeeded: false,
    _loopbackOwned: [],
    _loopbackCommands: [],
    _loopbackRemovals: [],
    _loopbackDesired: [],
    _loopbackGeneration: 0,
    _loopbackLinkText: '',
    loopbackTimeoutMs: 5000,
    loopbackOwner: 'audio:loopback',
    loopbackEnabled: false,
    _loopbackSource: null,
    _loopbackSink: null,
    _loopbackSourceId: '',
    _loopbackSinkId: '',
    _loopbackSourceName: '',
    _loopbackSinkName: '',
  }
  sim.root = root
  const bound = FNS.map((n) => `root.${n} = (${extract(AUDIO_QML, n)});`).join('\n')
  const factory = new Function('root', 'Loopback', 'Core', 'Exec', 'ShellState', 'Qt', bound)
  factory(root, L, sim.Core, sim.Exec, sim.ShellState, sim.Qt)
  return sim
}

function flush(sim, cap = 1000) {
  let n = 0
  while (sim.queue.length > 0) {
    if (++n > cap) throw new Error('callLater storm: reconcile keeps rescheduling without settling')
    sim.queue.shift()()
  }
  return n
}

// Complete every pending job: reads answer from the fake graph, writes
// succeed. Classified per job so mixed queues drain in one pass.
function completeAll(sim, fn = okPorts) {
  const jobs = sim.pendingJobs.splice(0, sim.pendingJobs.length)
  for (const job of jobs) {
    const argv = job.argv.join(' ')
    if (argv === 'pw-link -o' || argv === 'pw-link -i' || argv === 'pw-link -l -I') {
      const kind = argv === 'pw-link -o' ? 'outputs' : argv === 'pw-link -i' ? 'inputs' : 'links'
      job.opts.onFinished(fn(kind))
    } else {
      job.opts.onFinished({ code: 'ok', stdout: '', stderr: '' })
    }
  }
}

// Let the system run to quiescence: deferred turns and job completions
// until nothing is pending or queued.
function idle(sim, rounds = 20) {
  for (let i = 0; i < rounds; i++) {
    flush(sim)
    if (sim.pendingJobs.length === 0 && sim.queue.length === 0) return
    completeAll(sim)
  }
  flush(sim)
  if (sim.pendingJobs.length !== 0 || sim.queue.length !== 0) {
    throw new Error('system did not settle: jobs or turns still pending')
  }
}

// The QML change handlers, verbatim in effect: bump the generation, schedule.
function setSetting(sim, on) {
  sim.root.loopbackEnabled = on
  sim.root._loopbackGeneration++
  sim.root._scheduleLoopback()
}

function devicesArrive(sim) {
  sim.root._loopbackSource = MIC
  sim.root._loopbackSink = SPEAKER
  sim.root._loopbackSourceId = L.nodeId(MIC)
  sim.root._loopbackSinkId = L.nodeId(SPEAKER)
  sim.root._loopbackSourceName = L.nodeName(MIC)
  sim.root._loopbackSinkName = L.nodeName(SPEAKER)
  sim.root._loopbackGeneration++
  sim.root._scheduleLoopback()
  sim.root._loopbackGeneration++
  sim.root._scheduleLoopback()
}

// onCompleted, verbatim in effect for the loopback half.
function boot(sim, persisted) {
  if (persisted !== undefined) sim.store.audio = { loopbackPairs: persisted }
  sim.root._loopbackOwned = L.validPairs(sim.ShellState.section('audio')?.loopbackPairs)
  sim.root._loopbackSeeded = true
  sim.Qt.callLater(() => sim.root._scheduleLoopback())
}

const connectsOf = (sim) => sim.issued.filter((a) => a.length === 3 && a[0] === 'pw-link' && a[1] !== '-l')
const removalsOf = (sim) => sim.issued.filter((a) => a.length === 4 && a[1] === '-d')
const readsOf = (sim) => sim.issued.filter((a) => a[0] === 'pw-link' && (a.length === 2 || a[1] === '-l'))

// Drain to quiescence one completion at a time: connect jobs issue
// sequentially (each finish triggers the next), so a single sweep is
// not enough.
function drain(sim, rounds = 50) {
  for (let i = 0; i < rounds; i++) {
    flush(sim)
    if (sim.pendingJobs.length === 0 && sim.queue.length === 0) return
    completeAll(sim)
  }
  flush(sim)
  if (sim.pendingJobs.length !== 0 || sim.queue.length !== 0) {
    throw new Error('system did not settle: jobs or turns still pending')
  }
}

suite('services/audio reconcile', 'loopback generation protocol converges across restarts and mid-flight flips')

section('settled enable')
{
  const sim = makeSim()
  sim.root._loopbackSeeded = true
  devicesArrive(sim)
  idle(sim)
  eq('arrival with the setting off issues no connects', connectsOf(sim).length, 0)
  setSetting(sim, true)
  flush(sim)
  eq('enable issues port and link reads', sim.pendingJobs.length, 3)
  drain(sim)
  eq('plan yields two connect commands', connectsOf(sim).length, 2)
  eq('service settles idle with no error', [sim.root._loopbackBusy, sim.root._loopbackError], [false, ''])
  eq('owned routes persist for the next boot', sim.store.audio.loopbackPairs, [
    { output: PAIR_OUTPUTS[0], input: PAIR_INPUTS[0] },
    { output: PAIR_OUTPUTS[1], input: PAIR_INPUTS[1] },
  ])
}

section('flip while reads are in flight')
group('off lands while port reads are pending', () => {
  const sim = makeSim()
  sim.root._loopbackSeeded = true
  devicesArrive(sim)
  idle(sim)
  setSetting(sim, true)
  flush(sim)
  eq('reads are in flight', sim.pendingJobs.length, 3)
  // The user toggles back off before pw-link answers. The in-flight
  // reconcile is stale; its completions must not wedge the service.
  setSetting(sim, false)
  flush(sim)
  completeAll(sim)
  eq('stale reads leave no job behind', sim.pendingJobs.length, 0)
  drain(sim)
  eq('busy is released after stale completions', sim.root._loopbackBusy, false)
  eq('no error is latched by the abandoned enable', sim.root._loopbackError, '')
  eq('abandoned enable issues no connects', connectsOf(sim).length, 0)
})

section('restart with the setting still on')
group('devices arrive while the boot link read is pending', () => {
  const sim = makeSim()
  const persisted = [
    { output: PAIR_OUTPUTS[0], input: PAIR_INPUTS[0] },
    { output: PAIR_OUTPUTS[1], input: PAIR_INPUTS[1] },
  ]
  sim.root.loopbackEnabled = true
  boot(sim, persisted)
  flush(sim)
  eq('boot issues a link read with no devices yet', sim.pendingJobs.length, 1)
  // PipeWire publishes the defaults while that read is in flight.
  devicesArrive(sim)
  flush(sim)
  completeAll(sim)
  eq('stale boot read leaves no job behind', sim.pendingJobs.length, 0)
  drain(sim)
  eq('boot race still yields two connects', connectsOf(sim).length, 2)
  eq('service settles idle with no error', [sim.root._loopbackBusy, sim.root._loopbackError], [false, ''])
})

finish()

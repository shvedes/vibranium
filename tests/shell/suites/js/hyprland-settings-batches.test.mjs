#!/usr/bin/env node
// Suite: HyprlandSettings overlapping fetch and preset batches (SET-4, SET-5).
//
//   shell/common/settings/HyprlandSettings.qml   _fetchLive, the fetch exit,
//                                               _writeAnimPreset and the
//                                               test -L -> mv -> ln chain
//
// Limitation: HyprlandSettings is a pragma Singleton that forks hyprctl, uses
// FileView/probes against the real config tree, and is driven by compositor
// events. This suite runs under node with no compositor, no hyprctl and no
// config tree, so the live flip-back in the menu cannot be observed here. It
// reads the real QML, lifts the handlers by brace matching, and drives two
// overlapping batches against stubbed processes and stdio. What is pinned is
// the mechanism: each exit merges under its own snapshot, a newer request is
// queued rather than started, and a retired generation cannot publish - not
// the compositor answers themselves.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, contains, notContains, match, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const QML = fs.readFileSync(
  path.join(SHELL_DIR, 'common', 'settings', 'HyprlandSettings.qml'), 'utf8')

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

function liftFunction(src, name, required) {
  const head = `function ${name}(`
  const at = src.indexOf(head)
  if (at < 0) {
    if (required) throw new Error(`HyprlandSettings.qml has no ${head}`)
    return ''
  }
  return bracedBody(src, src.indexOf('{', at), head)
}

function liftProcessHandler(src, id, handler, required = true) {
  const idAt = src.indexOf(`id: ${id}`)
  if (idAt < 0) {
    if (required) throw new Error(`HyprlandSettings.qml has no id ${id}`)
    return ''
  }
  const procAt = src.lastIndexOf('Process {', idAt)
  if (procAt < 0) throw new Error(`HyprlandSettings.qml has no Process for ${id}`)
  const block = bracedBody(src, src.indexOf('{', procAt), `Process ${id}`)
  const at = block.indexOf(`${handler}:`)
  if (at < 0) {
    if (required) throw new Error(`Process ${id} has no ${handler}`)
    return ''
  }
  // Both `onExited: function(...) {` and `onExited: (...) => {` are in the
  // tree; anchor on the arrow when present, otherwise on the label itself.
  const arrowAt = block.indexOf('=>', at)
  const braceAt = arrowAt >= 0 ? block.indexOf('{', arrowAt) : block.indexOf('{', at)
  return bracedBody(block, braceAt, `${id}.${handler}`)
}

const FETCH_BODY = liftFunction(QML, '_fetchLive', true)
const FETCH_EXIT_BODY = liftProcessHandler(QML, 'fetchProc', 'onExited')
// These helpers and the ln exit are absent on the unfixed tree; an absent body
// is an empty string so the source assertions fail as assertions, not crashes.
const MERGE_BODY = liftFunction(QML, '_mergeFetch', false)
const FETCH_DRAIN_BODY = liftFunction(QML, '_drainFetchQueue', false)
const PRESET_BODY = liftFunction(QML, '_writeAnimPreset', true)
const TEST_EXIT_BODY = liftProcessHandler(QML, 'animTestLProc', 'onExited')
const MV_EXIT_BODY = liftProcessHandler(QML, 'animMvProc', 'onExited')
const LN_EXIT_BODY = liftProcessHandler(QML, 'lnProc', 'onExited', false)
const PRESET_DRAIN_BODY = liftFunction(QML, '_drainPresetQueue', false)

// Two different _byKey orders. A batch launched under ORDER_A and answered
// with the int/string pair must not be merged under ORDER_B's slots: that is
// the flip-back the two instance-slot sets produce on the unfixed tree.
const K_SIZE = 'hypr.general.border_size'
const K_COLOR = 'hypr.general.border_color'
const OPTS = {
  [K_SIZE]: { type: 'int', hypr: { kind: 'option', ctl: 'general:border_size',
    file: '$XDG_CONFIG_HOME/hypr/hyprland.conf.d/advanced.lua',
    path: ['general', 'border_size'] } },
  [K_COLOR]: { type: 'string', hypr: { kind: 'option', ctl: 'general:border_color',
    file: '$XDG_CONFIG_HOME/hypr/hyprland.conf.d/advanced.lua',
    path: ['general', 'border_color'] } },
}
const ORDER_A = [K_SIZE, K_COLOR]
const ORDER_B = [K_COLOR, K_SIZE]
const byKey = (order) => {
  const out = {}
  for (const k of order) out[k] = OPTS[k]
  return out
}

const TARGET = '/home/u/.config/hypr/hyprland.conf.d/animations.lua'
const SRC_ALPHA = '/home/u/.config/hypr/animations/alpha.lua'
const SRC_BETA = '/home/u/.config/hypr/animations/beta.lua'

function makeProc(id, extra = {}) {
  const p = Object.assign({ id, running: false, command: [], launches: [] }, extra)
  Object.defineProperty(p, 'running', {
    get() { return this._running },
    set(v) {
      this._running = v
      if (v) this.launches.push({
        command: this.command.slice(),
        gen: this.batchGen,
        keys: this.batchKeys && this.batchKeys.slice(),
        src: this.presetSrc,
        target: this.presetTarget,
      })
    },
  })
  return p
}

function makeSim() {
  const publishes = []
  const probes = []
  const reloads = []
  const changes = []
  const fileReads = []
  const calls = { merges: [], fetchDrains: 0, presetDrains: 0 }

  const root = {
    tag: 'hyprlandSettings',
    _byKey: byKey(ORDER_A),
    values: { [K_SIZE]: 1, [K_COLOR]: '0x22' },
    rev: 0,
    ready: false,
    _writtenKeys: {},
    _fetchGen: 0,
    _fetchQueued: false,
    // instance slots the unfixed tree reads from on exit
    _fetchKeys: [],
    _fetchCtls: [],
    _fetchTypeByCtl: {},
    _fetchBuf: '',
    _animCustomNames: ['alpha', 'beta'],
    _presetGen: 0,
    _presetQueued: null,
    _animPendingSrc: '',
    _animPendingTarget: '',
  }
  // values is written once per merge; snapshot it so "one exit, one publish"
  // is measured rather than assumed.
  Object.defineProperty(root, 'values', {
    configurable: true,
    get() { return this._values },
    set(v) {
      this._values = v
      // The store bumps rev immediately after publishing, so the frame a
      // reader sees carries the new generation, not the one being replaced.
      publishes.push({ size: v[K_SIZE], color: v[K_COLOR], rev: this.rev + 1 })
    },
  })
  root._values = { [K_SIZE]: 1, [K_COLOR]: '0x22' }

  root._expandFile = (p) => String(p)
    .replace('$XDG_CONFIG_HOME', '/home/u/.config')
    .replace('$VIBRANIUM', '/opt/vb')
  root._readFileContent = (p) => { fileReads.push(p); return '' }
  root._fallbackToFiles = () => { calls.merges.push({ fallback: true }) }
  root._markReady = () => { root.ready = true }
  root._reloadHyprland = () => { reloads.push(root.rev) }
  root.optionChanged = (k, v) => { changes.push([k, v]) }

  const fetchProc = makeProc('fetchProc', {
    batchGen: 0, batchKeys: [], batchCtls: [], batchTypeByCtl: {}, batchBuf: '',
  })
  const fetchOut = { text: '' }
  const fetchErr = { text: '' }
  const animTestLProc = makeProc('animTestLProc', { presetGen: 0, presetSrc: '', presetTarget: '' })
  const animMvProc = makeProc('animMvProc', { presetGen: 0, presetSrc: '', presetTarget: '' })
  const lnProc = makeProc('lnProc', { presetGen: 0, presetSrc: '', presetTarget: '' })
  const animProbe = {
    _path: '',
    get path() { return this._path },
    set path(v) { this._path = v; probes.push(v) },
    waitForJob() { return !String(this._path).endsWith('.bak') },
    text() { return '' },
  }

  const SL = {
    validateValue: (opt, value) => {
      if (opt.type === 'int' && typeof value === 'number') return { ok: true, value }
      if (opt.type === 'string' && typeof value === 'string') return { ok: true, value }
      return { ok: false, error: 'bad value' }
    },
  }
  const HE = { hyprGetContent: () => ({ ok: false }) }
  const SU = {
    joinPath: (a, b) => `${a}/${b}`,
    basename: (p) => String(p).split('/').pop(),
  }
  const Paths = { vibraniumHome: '/opt/vb', configHome: '/home/u/.config' }

  const compile = (body, params) => body
    ? new Function(...params, `with (root) {\n${body}\n}`) : null

  const fetchFn = compile(FETCH_BODY, ['root', 'fetchProc', 'fetchOut', 'fetchErr', 'SL', 'HE'])
  const mergeFn = compile(MERGE_BODY, ['root', 'fetchProc', 'fetchOut', 'SL', 'HE', 'code', 'status', 'raw'])
  const fetchExitFn = compile(FETCH_EXIT_BODY,
    ['root', 'fetchProc', 'fetchOut', 'SL', 'HE', 'code', 'status'])
  const fetchDrainFn = compile(FETCH_DRAIN_BODY, ['root'])

  const presetFn = compile(PRESET_BODY, ['root', 'animTestLProc', 'animMvProc', 'lnProc', 'animProbe', 'SU', 'Paths', 'preset'])
  const testExitFn = compile(TEST_EXIT_BODY, ['root', 'animTestLProc', 'animMvProc', 'lnProc', 'animProbe', 'code', 'status'])
  const mvExitFn = compile(MV_EXIT_BODY, ['root', 'animMvProc', 'lnProc', 'code', 'status'])
  const lnExitFn = compile(LN_EXIT_BODY, ['root', 'lnProc', 'code', 'status'])
  const presetDrainFn = compile(PRESET_DRAIN_BODY, ['root'])

  root._fetchLive = () => fetchFn(root, fetchProc, fetchOut, fetchErr, SL, HE)
  root._mergeFetch = (code, status, raw) => {
    calls.merges.push({ code, status, raw })
    if (mergeFn) mergeFn(root, fetchProc, fetchOut, SL, HE, code, status, raw)
  }
  root._drainFetchQueue = () => {
    calls.fetchDrains++
    if (fetchDrainFn) fetchDrainFn(root)
  }
  root._writeAnimPreset = (preset) =>
    presetFn(root, animTestLProc, animMvProc, lnProc, animProbe, SU, Paths, preset)
  root._drainPresetQueue = () => {
    calls.presetDrains++
    if (presetDrainFn) presetDrainFn(root)
  }

  const sim = { root, fetchProc, animTestLProc, animMvProc, lnProc, animProbe,
    publishes, probes, reloads, changes, fileReads, calls }
  sim.fetchLive = () => root._fetchLive()
  // QML clears running before onExited is delivered; do the same here so a
  // follow-up started inside the handler stays running.
  sim.fetchExit = (code, raw, status = 0) => {
    fetchOut.text = raw
    fetchProc.running = false
    fetchExitFn(root, fetchProc, fetchOut, SL, HE, code, status)
  }
  sim.preset = (name) => root._writeAnimPreset(name)
  sim.testExit = (code, status = 0) => {
    animTestLProc.running = false
    testExitFn(root, animTestLProc, animMvProc, lnProc, animProbe, code, status)
  }
  sim.mvExit = (code, status = 0) => {
    animMvProc.running = false
    mvExitFn(root, animMvProc, lnProc, code, status)
  }
  sim.lnExit = (code, status = 0) => {
    lnProc.running = false
    if (lnExitFn) lnExitFn(root, lnProc, code, status)
  }
  return sim
}

// A fetch under ORDER_A is answered first; a second request arrives while it
// is in flight (now under ORDER_B), then A's answer lands before B's.
function driveFetchOverlap(sim) {
  sim.fetchLive()
  sim.root._byKey = byKey(ORDER_B)
  sim.fetchLive()
  sim.fetchExit(0, '[{"int":11},{"str":"0xff"}]')
  sim.fetchExit(0, '[{"str":"0xbb"},{"int":33}]')
}

suite('hyprland-settings batches', 'generation-scoped fetches and preset chains')

// ---------------------------------------------------------------------------
section('a fetch request while a batch runs is queued, not started')

group('two requests collapse to one in-flight process plus one follow-up', () => {
  const sim = makeSim()
  sim.fetchLive()
  sim.fetchLive()

  eq('only the first batch started a process', sim.fetchProc.launches.length, 1)
  eq('the newer request armed the queue', sim.root._fetchQueued, true)
  eq('the generation is owned by a started batch', sim.root._fetchGen, 1)
  eq('the first batch kept its own key snapshot', sim.fetchProc.launches[0].keys, ORDER_A)
})

group('each exit publishes under its own keys and ctls', () => {
  const sim = makeSim()
  driveFetchOverlap(sim)

  eq('the first batch merged its own answer', sim.publishes[0],
    { size: 11, color: '0xff', rev: 1 })
  eq('the follow-up started under the second order', sim.fetchProc.launches[1].keys, ORDER_B)
  eq('the follow-up advanced the generation', sim.fetchProc.launches[1].gen, 2)
  eq('the second batch merged its own answer', sim.publishes[1],
    { size: 33, color: '0xbb', rev: 2 })
  eq('two batches, exactly two publishes', sim.publishes.length, 2)
  eq('the live values are the latest answer', sim.root.values,
    { [K_SIZE]: 33, [K_COLOR]: '0xbb' })
  eq('the fallback path never ran', sim.calls.merges.some((m) => m.fallback), false)
})

group('a retired generation cannot republish', () => {
  const sim = makeSim()
  sim.fetchLive()
  sim.root._fetchGen++ // a newer intent retired the batch still in flight
  const before = sim.publishes.length
  const callsBefore = sim.calls.merges.length

  sim.fetchExit(0, '[{"int":99},{"str":"0xdead"}]')
  sim.fetchExit(0, '[{"int":99},{"str":"0xdead"}]')

  eq('no extra publish from a stale exit', sim.publishes.length, before)
  eq('no merge was attempted for a stale exit', sim.calls.merges.length, callsBefore)
  eq('the values stay at the defaults', sim.root.values,
    { [K_SIZE]: 1, [K_COLOR]: '0x22' })
})

group('_writtenKeys still withholds a pre-reload answer', () => {
  const sim = makeSim()
  sim.root._writtenKeys = { [K_SIZE]: true }
  sim.fetchLive()
  sim.fetchExit(0, '[{"int":11},{"str":"0xff"}]')

  eq('the written key keeps its value', sim.root.values[K_SIZE], 1)
  eq('the other key still lands', sim.root.values[K_COLOR], '0xff')
  eq('one publish', sim.publishes.length, 1)
})

// ---------------------------------------------------------------------------
section('a preset pick while a chain runs is queued, not started')

group('two fast picks leave each chain on its own source and target', () => {
  const sim = makeSim()
  sim.preset('alpha')
  sim.preset('beta')

  eq('only the first chain started a test', sim.animTestLProc.launches.length, 1)
  eq('the newer pick was queued', sim.root._presetQueued, 'beta')
  eq('the generation belongs to the started chain', sim.root._presetGen, 1)

  sim.testExit(1) // target is a regular file: back it up
  eq('the backup move uses this chain target', sim.animMvProc.launches[0].command,
    ['mv', TARGET, `${TARGET}.bak`])
  eq('this chain did not start a second test', sim.animTestLProc.launches.length, 1)

  sim.mvExit(0)
  eq('the ln uses this chain source, not the queued pick', sim.lnProc.launches[0].command,
    ['ln', '-sf', SRC_ALPHA, TARGET])

  sim.lnExit(0)
  eq('the queued pick started after the chain', sim.animTestLProc.launches.length, 2)
  eq('the queued pick has its own source', sim.animTestLProc.launches[1].src, SRC_BETA)
  eq('the queue was consumed', sim.root._presetQueued, null)
  eq('the generation advanced for the follow-up', sim.root._presetGen, 2)

  sim.testExit(0)
  eq('the follow-up ln uses the follow-up source', sim.lnProc.launches[1].command,
    ['ln', '-sf', SRC_BETA, TARGET])
})

group('a stale handler exit retires without touching the live chain', () => {
  const sim = makeSim()
  sim.preset('alpha')
  sim.preset('beta')
  const gen = sim.root._presetGen
  sim.animTestLProc.presetGen = gen - 1

  sim.testExit(1)
  eq('no move was started', sim.animMvProc.launches.length, 0)
  eq('no symlink was written', sim.lnProc.launches.length, 0)
  eq('the queued pick is untouched', sim.root._presetQueued, 'beta')
})

// ---------------------------------------------------------------------------
section('the mechanism is in the handlers, not in the test stubs')

group('fetch is generation-scoped and single-flight', () => {
  contains('_fetchLive refuses a running batch', FETCH_BODY, 'fetchProc.running')
  contains('_fetchLive arms the queue', FETCH_BODY, '_fetchQueued = true')
  match('_fetchLive bumps its generation', FETCH_BODY, /\+\+root\._fetchGen/)
  contains('the exit compares the captured generation', FETCH_EXIT_BODY,
    'fetchProc.batchGen === root._fetchGen')
  contains('the exit drains the queue', FETCH_EXIT_BODY, '_drainFetchQueue()')
  contains('the merge reads the per-run keys', MERGE_BODY, 'fetchProc.batchKeys')
  contains('the merge still respects _writtenKeys', MERGE_BODY,
    'root._writtenKeys[key] === true')
  notContains('the merge no longer reads a shared key slot', MERGE_BODY, 'root._fetchKeys')
})

group('the preset chain carries src, target and generation per run', () => {
  contains('_writeAnimPreset refuses a running chain', PRESET_BODY, 'animTestLProc.running')
  contains('_writeAnimPreset also checks the move and ln legs', PRESET_BODY,
    'animMvProc.running || lnProc.running')
  contains('a newer pick is queued', PRESET_BODY, '_presetQueued = ')
  match('a generation is captured', PRESET_BODY, /\+\+root\._presetGen/)
  contains('the test handler reads its own source', TEST_EXIT_BODY,
    'animTestLProc.presetSrc')
  contains('the move handler reads its own source', MV_EXIT_BODY, 'animMvProc.presetSrc')
  match('the test handler retires a stale generation', TEST_EXIT_BODY,
    /animTestLProc\.presetGen !== root\._presetGen/)
  match('the move handler retires a stale generation', MV_EXIT_BODY,
    /animMvProc\.presetGen !== root\._presetGen/)
  contains('the ln handler drains the queued pick', LN_EXIT_BODY, '_drainPresetQueue()')
  notContains('the global pending source slot is gone', QML, '_animPendingSrc')
})

finish()

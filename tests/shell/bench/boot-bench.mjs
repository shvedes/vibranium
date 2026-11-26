#!/usr/bin/env node
// Phase 5 opt-in boot benchmark engine (headless/common-observable pilot).
//
// This file is the engine behind tests/shell/bench/boot-bench.sh. It never
// edits a suite, a baseline or a production file. It runs the REAL BootPump,
// AsyncLoader, BootTrace recorder and IpcProtocol codec inside an offscreen
// Quickshell probe on the SAME event stream for both variants, measures a
// predeclared common observable, and applies the paired p95 gate logic.
//
// It deliberately makes no boot-endpoint or presentation claim: see
// fullProtocol.blocked in every emitted result.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import { spawn, execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { loadLib } from '../lib/qmlloader.mjs'
import { SHELL_DIR } from '../lib/assert.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..', '..')
const FIX = path.join(ROOT, 'tests', 'shell', 'fixtures', 'boot-bench')
const TMPROOT = fs.existsSync('/tmp/opencode') ? '/tmp/opencode' : os.tmpdir()

const USAGE = `Usage: node tests/shell/bench/boot-bench.mjs --mode=cold --runs=20 [--pilot] [--compare=<baseline.json>]

  --mode=cold|warm   cache protocol (cold: fresh cache per launch; warm: seeded)
  --runs=N           paired blocks requested (minimum 20 for a p95 claim)
  --compare=<file>   compare this run to a pinned result summary
  --pilot            required on this host; runs the labelled headless pilot
  --out=<file>       result summary destination
  --help             this text
`

function usage(rc = 0) {
  process.stdout.write(USAGE)
  process.exit(rc)
}

const argv = process.argv.slice(2)
let runs = 20
let mode = 'cold'
let comparePath = null
let outPath = null
let pilot = false
for (const arg of argv) {
  if (arg === '--help' || arg === '-h') usage(0)
  else if (arg === '--pilot') pilot = true
  else if (arg.startsWith('--runs=')) runs = Number(arg.slice(7))
  else if (arg.startsWith('--mode=')) mode = arg.slice(7)
  else if (arg.startsWith('--compare=')) comparePath = path.resolve(arg.slice(10))
  else if (arg.startsWith('--out=')) outPath = path.resolve(arg.slice(6))
  else { process.stderr.write(`unknown option: ${arg}\n`); usage(2) }
}

if (!Number.isInteger(runs) || runs <= 0) { process.stderr.write('bad --runs\n'); process.exit(2) }
if (mode !== 'cold' && mode !== 'warm') { process.stderr.write('bad --mode\n'); process.exit(2) }

function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')) }
function sha256(value) {
  return createHash('sha256').update(typeof value === 'string' ? Buffer.from(value) : value).digest('hex')
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    const out = {}
    for (const key of Object.keys(value).sort()) out[key] = canonical(value[key])
    return out
  }
  return value
}
function firstLine(command, args, fallback = null, cwd = ROOT) {
  try {
    return execFileSync(command, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
      .split('\n')[0].trim() || fallback
  } catch { return fallback }
}
function percentile(values, q) {
  if (!values.length) return null
  const sorted = values.slice().sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)]
}
function mulberry32(seed) {
  let a = seed >>> 0
  return function () {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const protocol = readJson(path.join(FIX, 'pilot-protocol.json'))
const stream = readJson(path.join(FIX, 'event-stream.json'))
const pinnedProfile = readJson(path.join(FIX, 'host-profile.json'))
const contract = readJson(path.join(FIX, 'contract.json'))
const P = loadLib(path.join(SHELL_DIR, 'common', 'text', 'IpcProtocol.js'))
const PASSES = protocol.endpoint.passesPerLaunch || 1
let parity = { commonObservableStepsEqual: null, parityProbeFrameBytes: null }

// graphDigest is computed from the stream fixture ONLY. Host/build/profile
// facts are emitted under `pin`, never folded into this digest.
const graphDigest = sha256(JSON.stringify(canonical({ id: stream.graphId, rows: stream.rows })))
const streamEnv = JSON.stringify({ graphId: stream.graphId, rows: stream.rows })

function observedPin() {
  let cpuModel = null
  try {
    const info = fs.readFileSync('/proc/cpuinfo', 'utf8')
    const line = info.split('\n').find((l) => /^model name\s*:/.test(l))
    if (line) cpuModel = line.split(':').slice(1).join(':').trim()
  } catch { /* reported as unknown */ }
  let memTotalKiB = null
  try {
    const line = fs.readFileSync('/proc/meminfo', 'utf8').split('\n').find((l) => /^MemTotal:/.test(l))
    if (line) memTotalKiB = Number(line.split(/\s+/)[1])
  } catch { /* reported as unknown */ }
  const settings = pinnedProfile.settings
  const digest = createHash(settings.algorithm || 'sha256')
  for (const rel of settings.sources) {
    digest.update(rel)
    digest.update('\0')
    try { digest.update(fs.readFileSync(path.join(ROOT, rel))) } catch { digest.update('<missing>') }
    digest.update('\0')
  }
  const qsVersion = (firstLine('qs', ['--version'], '') || '').split(/\s+/)[1] || null
  const qtVersion = (firstLine('/usr/lib/qt6/bin/qmllint', ['--version'], '') || '').split(/\s+/)[1] || null
  return {
    build: {
      gitHash: firstLine('git', ['rev-parse', 'HEAD'], null, ROOT) || null,
      quickshell: qsVersion,
      qt: qtVersion
    },
    hardware: {
      cpuModel,
      cpuCount: os.cpus().length,
      memTotalKiB,
      kernel: os.release()
    },
    compositor: {
      profile: 'offscreen-quickshell-probe',
      sessionType: process.env.XDG_SESSION_TYPE || null,
      desktop: process.env.XDG_CURRENT_DESKTOP || null,
      waylandDisplay: process.env.WAYLAND_DISPLAY || null,
      isolatedCompositorProvisioned: !!process.env.VB_BENCH_COMPOSITOR_SOCKET,
      liveShellLaunched: false
    },
    refresh: { hz: null, vrr: 'unobserved', reason: pinnedProfile.refresh.reason },
    outputs: { count: null, observed: [], reason: pinnedProfile.outputs.reason },
    settings: { algorithm: settings.algorithm, sources: settings.sources, digest: digest.digest('hex') }
  }
}

function blockedReasons() {
  const reasons = []
  if (process.env.VB_BENCH_ALLOW_LIVE_SHELL !== '1') {
    reasons.push('live shell launch is not authorized (VB_BENCH_ALLOW_LIVE_SHELL!=1); starting the real shell here would attach to the user session')
  }
  if (!process.env.VB_BENCH_COMPOSITOR_SOCKET) {
    reasons.push('no isolated compositor socket is provisioned (VB_BENCH_COMPOSITOR_SOCKET unset); WAYLAND_DISPLAY belongs to the host session')
  }
  reasons.push('offscreen Quickshell exposes zero screens and no PanelWindow backend, so external IPC readiness of a registered boot target cannot be probed here')
  reasons.push('the registered boot target is present in source but live registration/readiness was not probed; no cold/warm boot endpoint is claimed')
  return reasons
}

const PROBE = `import QtQml
import QtQuick
import Quickshell
import qs.boot
import "boot/BootTrace.js" as BT
import "common/text/IpcProtocol.js" as P

// Generated at run time into a throwaway config mirror (never into the repo).
// The two variants execute the same rows; only the observer differs.
QtObject {
  id: root
  default property list<QtObject> _owned: [ ElapsedTimer { id: mono } ]
  property Component pumpComponent: Component { BootPump {} }
  property Component loaderComponent: Component { AsyncLoader {} }
  property var steps: []
  property var idMap: ({})
  property var trace: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\\n/g, "\\\\n"))
  }
  function step(name) { root.steps.push(name) }

  function makePumpObserver() {
    if (!root.trace) return null
    return {
      openWork: function (source, kind) { return root.trace.openWork(source, kind) },
      closeWork: function (source, token, outcome) { root.trace.closeWork(source, token, outcome) },
      enqueue: function (source, outcome) {
        root.trace.emit("queue.enqueue", { source: source, outcome: outcome })
      },
      dispatch: function (source, token, waitMs) {
        root.trace.emit("queue.dispatch", { source: source, token: token, waitMs: waitMs })
      },
      noteFailure: function (code) { root.step("observerFailure:" + code) }
    }
  }

  function fakeComponent() {
    return Qt.createQmlObject(
      'import QtQml; QtObject { property int status: Component.Ready; function errorString(){ return "" } function createObject(owner, props){ return Qt.createQmlObject("import QtQml; QtObject {}", owner) } }',
      root)
  }

  Component.onCompleted: {
    try { run() } catch (error) { kv("probe.error", String((error && error.message) || error)) }
    console.log("##DONE##")
  }

  // One identical pass over the whole stream. A fresh recorder, pump and
  // loader per pass, so a long measurement run cannot saturate the recorder
  // and flatter one variant. Only the observer differs between variants.
  function pass(rows, traced) {
    var ms = 0
    root.steps = []
    root.idMap = Object.create(null)
    root.trace = traced ? BT.create({ now: function () { return ms } }) : null
    if (root.trace) {
      root.trace.setContext({ source: "launcher", estimate: 0 }, "boot-pilot-graph-v1")
      root.trace.setTokenCap(64)
    }

    var pump = root.pumpComponent.createObject(root)
    pump.now = function () { return ms }
    pump.observer = root.makePumpObserver()

    var loader = root.loaderComponent.createObject(root)
    loader.owner = root
    loader.componentFactory = function (url, mode) { return root.fakeComponent() }
    loader.observer = traced ? {
      attemptOpen: function (url) { return root.trace.openWork("provider:features", "loader") },
      attemptClose: function (id, reason) {
        root.trace.closeWork("provider:features", id, reason === "teardown" ? "teardown" : "callbackReturned")
      }
    } : null
    loader.adopted.connect(function (obj, attempt) { root.step("loader.adopted") })
    loader.failed.connect(function (kind, attempt, detail) { root.step("loader.failed:" + kind) })

    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (row.tMs !== undefined) ms = row.tMs
      if (row.op === "ipc") { root.step("ipc:" + row.name); continue }
      if (row.op === "timer") { root.step("timer:" + row.name); continue }
      if (row.op === "pump") {
        let name = row.name
        pump.enqueue(function () { root.step("pump.callback:" + name) }, row.source)
        root.step("pump.enqueue:" + row.source + ":" + name)
        continue
      }
      if (row.op === "turn") {
        var timer = pump._owned && pump._owned.length ? pump._owned[0] : pump.tick
        timer.stop()
        var turnResult = "ok"
        try { pump._turn() } catch (error) { turnResult = String((error && error.message) || error) }
        root.step("pump.turn:" + turnResult)
        continue
      }
      if (row.op === "loader") { root.step("loader.load:" + row.name); loader.load(); continue }
      if (row.op === "loader.teardown") { loader.teardown(); root.step("loader.teardown"); continue }

      var fields = {}
      var src = row.fields || {}
      for (var key in src) {
        if (Object.prototype.hasOwnProperty.call(src, key)) fields[key] = src[key]
      }
      if (row.causes !== undefined) {
        var refs = []
        for (var c = 0; c < row.causes.length; c++) refs.push(root.idMap[row.causes[c]] || 0)
        fields.causes = refs
      }
      var id = root.trace ? root.trace.emit(row.kind, fields) : 0
      if (id) root.idMap[row.id] = id
      root.step("trace." + row.id)
    }
    pump.shutdown()
    var internal = null
    if (root.trace) {
      var snap = root.trace.snapshot()
      internal = { sealed: snap.sealed, integrityValid: snap.integrity.valid, reservedEntries: snap.coverage.reservedEntries }
    }
    loader.teardown()
    pump.destroy()
    loader.destroy()
    return { steps: root.steps.slice(), internal: internal }
  }

  function run() {
    var variant = Quickshell.env("BB_VARIANT") === "traced" ? "traced" : "inert"
    var traced = variant === "traced"
    var rows = JSON.parse(Quickshell.env("BB_STREAM")).rows
    var passes = Number(Quickshell.env("BB_PASSES")) || 1
    var last = null
    mono.restart()
    for (var p = 0; p < passes; p++) last = pass(rows, traced)
    var totalMs = mono.elapsedMs()

    var frame = P.encode(P.ok({ schema: "boot-bench-pilot-v1", steps: last.steps, ready: true }, "boottime"))

    kv("variant", variant)
    kv("passes", passes)
    kv("totalMs", totalMs)
    kv("steps", JSON.stringify(last.steps))
    kv("frame", frame)
    if (last.internal) {
      kv("internal.sealed", last.internal.sealed)
      kv("internal.integrity", last.internal.integrityValid)
      kv("internal.reservedEntries", last.internal.reservedEntries)
    }
    console.log("##DONE##")
  }
}
`

const cfg = fs.mkdtempSync(path.join(TMPROOT, 'vb-boot-bench-cfg-'))
const cacheDirs = []
try {
  for (const entry of fs.readdirSync(SHELL_DIR)) {
    fs.symlinkSync(path.join(SHELL_DIR, entry), path.join(cfg, entry))
  }
  fs.writeFileSync(path.join(cfg, '__probe.qml'), PROBE)
  if (process.env.BB_DEBUG) fs.writeFileSync('/tmp/opencode/boot-bench-debug-probe.qml', PROBE)
} catch (error) {
  fs.rmSync(cfg, { recursive: true, force: true })
  process.stderr.write(`probe setup failed: ${error.message}\n`)
  process.exit(2)
}

function newCacheDir() {
  const dir = fs.mkdtempSync(path.join(TMPROOT, `vb-boot-bench-cache-${mode}-`))
  cacheDirs.push(dir)
  return dir
}

function countFiles(dir) {
  let n = 0
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) n += countFiles(path.join(dir, entry.name))
      else if (entry.isFile()) n++
    }
  } catch { /* directory already removed */ }
  return n
}

function parseOutput(text, variant) {
  const kv = Object.create(null)
  for (const line of text.split('\n')) {
    const at = line.indexOf('##KV## ')
    if (at < 0) continue
    const body = line.slice(at + 7)
    const eq = body.indexOf('=')
    if (eq > 0) kv[body.slice(0, eq)] = body.slice(eq + 1)
  }
  const totalMs = Number(kv.totalMs)
  const passes = Number(kv.passes)
  const readyMs = passes > 0 ? totalMs / passes : NaN
  const decoded = kv.frame ? P.decode(kv.frame) : null
  if (!text.includes('##DONE##') || kv['probe.error'] || kv.variant !== variant ||
      passes !== PASSES || !Number.isFinite(totalMs) || !Number.isFinite(readyMs) ||
      !kv.steps || !decoded || decoded.format !== 'boottime' ||
      P.asciiBytes(kv.frame) > P.MAX_REPLY_BYTES) {
    return { ok: false, reason: text.includes('##DONE##') ? 'invalidProbeResult' : 'noSentinel', raw: text }
  }
  return {
    ok: true,
    readyMs,
    totalMs,
    passes,
    steps: kv.steps,
    frameBytes: P.asciiBytes(kv.frame),
    internal: kv['internal.sealed'] === undefined ? null : {
      sealed: kv['internal.sealed'] === 'true',
      integrityValid: kv['internal.integrity'] === 'true',
      reservedEntries: Number(kv['internal.reservedEntries'])
    }
  }
}

function runProbe(variant, cacheDir) {
  const timeoutMs = protocol.censoring.timeoutMs
  return new Promise((resolve) => {
    let settled = false
    let out = ''
    let timer = null
    let child = null
    function finish(result) {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      try { process.kill(-pid, 'SIGTERM') } catch { /* already gone */ }
      resolve(result)
    }
    let pid = -1
    try {
      child = spawn('qs', ['--no-color', '-p', path.join(cfg, '__probe.qml')], {
        cwd: cfg,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {
          ...process.env,
          QT_QPA_PLATFORM: 'offscreen',
          XDG_CACHE_HOME: cacheDir,
          BB_VARIANT: variant,
          BB_STREAM: streamEnv,
          BB_PASSES: String(PASSES)
        }
      })
      pid = child.pid
    } catch (error) {
      finish({ ok: false, reason: 'nonStart:' + error.message })
      return
    }
    const collect = (chunk) => {
      out += chunk.toString()
      // qs does not exit on its own here (Qt.quit has no receiver), exactly as
      // in tests/shell/lib/qmlprobe.sh. Resolve on the sentinel, then kill the
      // process group; a timeout is a censored non-completion, not a wait.
      if (out.includes('##DONE##')) finish(parseOutput(out, variant))
    }
    child.stdout.on('data', collect)
    child.stderr.on('data', collect)
    child.on('error', (error) => finish({ ok: false, reason: 'nonStart:' + error.message }))
    child.on('close', () => finish(parseOutput(out, variant)))
    timer = setTimeout(() => finish({ ok: false, reason: 'timeout' }), timeoutMs)
  })
}

async function seed(variant, cacheDir) {
  const r = await runProbe(variant, cacheDir)
  return { variant, ok: r.ok, reason: r.reason || null }
}

function bootstrapEffects(validPairs, primary, baseline) {
  const rng = mulberry32(protocol.statistics.bootstrapSeed)
  const B = protocol.statistics.bootstrapBlocks
  const effects = []
  for (let b = 0; b < B; b++) {
    const sample = []
    for (let k = 0; k < validPairs.length; k++) {
      sample.push(validPairs[Math.floor(rng() * validPairs.length)])
    }
    const cand = sample.map((p) => (baseline ? p.candidate : p.samples[primary].readyMs))
    const base = baseline ? sample.map((p) => p.baseline) : sample.map((p) => p.samples.inert.readyMs)
    const a = percentile(cand, 0.95)
    const z = percentile(base, 0.95)
    if (a !== null && z !== null) effects.push(a - z)
  }
  return { low: percentile(effects, 0.025), high: percentile(effects, 0.975), draws: effects.length }
}

function summary(values) {
  return {
    n: values.length,
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
    min: values.length ? Math.min(...values) : null,
    max: values.length ? Math.max(...values) : null
  }
}

async function main() {
  const observed = observedPin()
  const drift = []
  for (const group of Object.keys(pinnedProfile)) {
    if (!observed[group]) continue
    for (const key of Object.keys(pinnedProfile[group])) {
      const pinned = pinnedProfile[group][key]
      const seen = observed[group][key]
      if (JSON.stringify(pinned) !== JSON.stringify(seen)) {
        drift.push(`${group}.${key}: pinned=${JSON.stringify(pinned)} observed=${JSON.stringify(seen)}`)
      }
    }
  }

  console.log('=== PHASE 5 BOOT BENCH ===')
  console.log('CLASS: PILOT / HEADLESS COMMON OBSERVABLE — NOT a boot endpoint, NOT a presentation claim')
  console.log('FULL PROTOCOL BLOCKED:')
  for (const reason of blockedReasons()) console.log('  - ' + reason)
  if (!pilot) {
    console.log('\nBLOCKED: use --pilot to run the explicitly labelled headless pilot instead.')
    process.exitCode = 77
    return
  }
  console.log('\nEndpoint (predeclared): ' + protocol.endpoint.name + ' — ' + protocol.endpoint.definition)
  console.log(`Blocks requested: ${runs} (randomization seed ${protocol.blocks.seed})`)
  console.log(`Passes per launch: ${PASSES} (reported resolution floor ${(1 / PASSES).toFixed(3)} ms; integer QML clock)`)
  console.log(`Cache protocol (pilot proxy): ${mode} — ${protocol.cache[mode]}`)

  // Logical parity FIRST: no timing is reported if common observables differ.
  const parityCache = newCacheDir()
  const parityTraced = await runProbe('traced', parityCache)
  const parityInert = await runProbe('inert', parityCache)
  const parityOk = parityTraced.ok && parityInert.ok && parityTraced.steps === parityInert.steps
  parity = {
    commonObservableStepsEqual: parityOk,
    parityProbeFrameBytes: parityTraced.frameBytes || null,
    note: 'Same external step sequence on both routes; the framed reply is decoded by the real IpcProtocol before any timing.'
  }
  console.log(`\ncommon-observable parity: ${parityOk ? 'PASS' : 'FAIL'} (identical step sequence, framed reply decoded on both routes)`)
  if (!parityOk) {
    console.log('  traced: ' + JSON.stringify(parityTraced.reason || parityTraced.steps))
    console.log('  inert:  ' + JSON.stringify(parityInert.reason || parityInert.steps))
    if (process.env.BB_DEBUG) {
      console.log('  traced raw: ' + JSON.stringify((parityTraced.raw || '').slice(-2500)))
      console.log('  inert raw:  ' + JSON.stringify((parityInert.raw || '').slice(-2500)))
    }
    console.log('No timings reported.')
    process.exitCode = 1
    return
  }

  const seedResults = []
  let measureCache = null
  if (mode === 'warm') {
    measureCache = newCacheDir()
    seedResults.push(await seed('traced', measureCache))
    seedResults.push(await seed('inert', measureCache))
    console.log(`warm seed launches: ${JSON.stringify(seedResults)}`)
  }

  const rng = mulberry32(protocol.blocks.seed)
  const blocks = []
  let tracedFirst = 0
  for (let i = 0; i < runs; i++) {
    const order = rng() < 0.5 ? ['traced', 'inert'] : ['inert', 'traced']
    if (order[0] === 'traced') tracedFirst++
    const samples = {}
    for (const variant of order) {
      const cacheDir = mode === 'cold' ? newCacheDir() : measureCache
      samples[variant] = await runProbe(variant, cacheDir)
    }
    blocks.push({ index: i, order, samples })
  }

  const censored = { traced: [], inert: [] }
  const valid = []
  for (const block of blocks) {
    for (const v of ['traced', 'inert']) {
      if (!block.samples[v].ok) censored[v].push({ block: block.index, reason: block.samples[v].reason })
    }
    if (block.samples.traced.ok && block.samples.inert.ok) {
      valid.push({
        index: block.index,
        order: block.order,
        samples: block.samples,
        delta: block.samples.traced.readyMs - block.samples.inert.readyMs
      })
    }
  }
  const attempts = runs * 2
  const censorRate = (censored.traced.length + censored.inert.length) / attempts
  const sufficient = valid.length >= protocol.blocks.minimum && censorRate <= 0.1

  const tracedSamples = valid.map((b) => b.samples.traced.readyMs)
  const inertSamples = valid.map((b) => b.samples.inert.readyMs)
  const t = summary(tracedSamples)
  const i = summary(inertSamples)
  const effect = t.p95 !== null && i.p95 !== null ? t.p95 - i.p95 : null
  const ci = sufficient ? bootstrapEffects(valid, 'traced', null) : null
  const overheadBudgetMs = protocol.budget.overheadBudgetMsP95
  const overheadVerdict = !sufficient ? 'INCONCLUSIVE'
    : (ci.high <= overheadBudgetMs ? 'WITHIN_BUDGET' : 'ABOVE_BUDGET')

  console.log(`\ncompleted pairs: ${valid.length}/${runs}; censored traced=${censored.traced.length} inert=${censored.inert.length} (${(censorRate * 100).toFixed(1)}%)`)
  console.log(`randomized order: traced-first ${tracedFirst}/${runs}, inert-first ${runs - tracedFirst}/${runs}`)
  if (sufficient) {
    console.log(`traced (instrumented) readyMs: p50=${t.p50.toFixed(3)} p95=${t.p95.toFixed(3)} ms`)
    console.log(`inert  (disabled proxy) readyMs: p50=${i.p50.toFixed(3)} p95=${i.p95.toFixed(3)} ms`)
    console.log(`paired p95 overhead: ${effect.toFixed(3)} ms; block-resampling 95% CI [${ci.low.toFixed(3)}, ${ci.high.toFixed(3)}] ms`)
    console.log(`paired median delta: ${percentile(valid.map((b) => b.delta), 0.5).toFixed(3)} ms`)
    console.log(`overhead budget p95 <= ${overheadBudgetMs.toFixed(3)} ms: ${overheadVerdict}`)
  } else {
    console.log('INCONCLUSIVE: fewer than 20 complete pairs or >10% censored attempts; no p95 claim.')
  }

  let compare = null
  if (comparePath) {
    const baseline = readJson(comparePath)
    const primary = baseline.primary || 'traced'
    // Accept both a raw engine block (samples.<variant>) and a pinned summary
    // block (<variant>ReadyMs). Both carry the same per-block endpoint value.
    const baseValue = (b) => b.samples ? (b.samples[primary] && b.samples[primary].ok ? b.samples[primary].readyMs : null) : b[primary + 'ReadyMs']
    const baselineValid = (baseline.blocks || []).filter((b) => Number.isFinite(baseValue(b)))
    const paired = valid.slice(0, Math.min(valid.length, baselineValid.length)).map((b, k) => ({
      index: k,
      candidate: b.samples[primary].readyMs,
      baseline: baseValue(baselineValid[k])
    }))
    const baselineMode = baseline.run ? baseline.run.mode : baseline.mode
    const baselineDigest = baseline.pin ? baseline.pin.graphDigest : baseline.graphDigest
    const compatible = baselineMode === mode && baselineDigest === graphDigest
    const compareSufficient = compatible && paired.length >= protocol.blocks.minimum
    const candP95 = percentile(paired.map((p) => p.candidate), 0.95)
    const baseP95 = percentile(paired.map((p) => p.baseline), 0.95)
    const cCI = compareSufficient ? bootstrapEffects(paired, primary, true) : null
    const improvement = candP95 !== null && baseP95 !== null ? candP95 - baseP95 : null
    const perfPass = !!cCI && improvement < 0 && cCI.high <= -protocol.budget.meaningfulImprovementMs
    compare = {
      file: path.relative(ROOT, comparePath),
      compatible,
      primary,
      pairedBlocks: paired.length,
      baselineP95Ms: baseP95,
      candidateP95Ms: candP95,
      effectMs: improvement,
      ci: cCI,
      performancePass: perfPass,
      note: 'Cross-session block-index pairing; weaker than simultaneous A/B. Both sessions use the same seed and stream.'
    }
    console.log(`\n--compare ${compare.file}: compatible=${compatible} paired=${paired.length}`)
    if (compareSufficient) {
      console.log(`candidate-baseline p95: ${improvement.toFixed(3)} ms; CI [${cCI.low.toFixed(3)}, ${cCI.high.toFixed(3)}] ms; performancePass=${perfPass}`)
    } else {
      console.log('compare INCONCLUSIVE (incompatible baseline or too few blocks)')
    }
  }

  let structural = { verdict: 'FAIL', detail: 'not evaluated' }
  try {
    const text = execFileSync(process.execPath, [path.join(HERE, 'unit-catalog-golden.mjs'), '--check', '--no-diff'], {
      cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
    })
    const goldenDigest = sha256(fs.readFileSync(path.join(ROOT, contract.structuralGolden.fixture)))
    structural = {
      verdict: text.includes('matches golden') && goldenDigest === contract.structuralGolden.pinnedFixtureDigest ? 'PASS' : 'STALE',
      detail: text.trim(),
      fixtureDigest: goldenDigest
    }
  } catch (error) {
    structural = { verdict: 'FAIL', detail: String(error.stdout || error.message).trim() }
  }

  const visual = {
    verdict: contract.visualContract.headlessVerdict,
    provenanceDigests: Object.fromEntries(contract.visualContract.files.map((rel) => [rel, sha256(fs.readFileSync(path.join(ROOT, rel)))])),
    note: 'Byte digests are provenance only. No headless probe certifies the visual contract here.'
  }
  const perfForGate = compare ? compare.performancePass : null
  const gate = {
    landed: false,
    performancePass: perfForGate,
    structuralGolden: structural.verdict,
    visualContract: visual.verdict,
    reasons: [
      ...(compare ? (perfForGate ? [] : ['p95 improvement not established beyond paired uncertainty']) : ['no --compare baseline supplied']),
      ...(structural.verdict === 'PASS' ? [] : ['structural golden not verified']),
      'visual contract unverified without a compositor run'
    ]
  }
  console.log(`\nGATE: NOT_LANDED — ${gate.reasons.join('; ')}`)

  const internalDiagnostic = parityTraced.internal || (valid.find((b) => b.samples.traced.internal) || {}).samples?.traced?.internal || null
  const result = {
    schema: 1,
    tool: 'tests/shell/bench/boot-bench.mjs',
    classification: 'PILOT_HEADLESS_COMMON_OBSERVABLE',
    bootEndpointClaim: false,
    presentationClaim: false,
    endpoint: protocol.endpoint,
    fullProtocol: { blocked: true, reasons: blockedReasons() },
    run: {
      mode,
      runs,
      passesPerLaunch: PASSES,
      reportedResolutionFloorMs: 1 / PASSES,
      completedPairs: valid.length,
      randomizationSeed: protocol.blocks.seed,
      tracedFirst,
      censoring: protocol.censoring,
      censored,
      censorRate,
      cache: {
        cold: protocol.cache.cold,
        warm: protocol.cache.warm,
        warmSeedLaunches: seedResults,
        artifactsObservedPerCacheDir: cacheDirs.map(countFiles)
      },
      statistics: protocol.statistics
    },
    pin: {
      pinned: pinnedProfile,
      observed,
      drift,
      graphDigest,
      metadataInsideGraphDigest: false
    },
    parity,
    censoringSummary: {
      nonStarts: [...censored.traced, ...censored.inert].filter((c) => c.reason.startsWith('nonStart')).length,
      timeouts: [...censored.traced, ...censored.inert].filter((c) => c.reason === 'timeout').length
    },
    result: { sufficient, traced: t, inert: i, pairedEffectP95Ms: effect, ci, pairedMedianDeltaMs: percentile(valid.map((b) => b.delta), 0.5), overheadBudgetMs, overheadVerdict },
    diagnosticOnly: { source: 'internal recorder timestamps (traced variant only; never compared to a disabled proxy)', value: internalDiagnostic },
    compare,
    gate: { ...gate, structuralDetail: structural.detail, visualProvenanceDigests: visual.provenanceDigests },
    blocks: valid.map((b) => ({
      index: b.index,
      order: b.order,
      tracedReadyMs: b.samples.traced.readyMs,
      inertReadyMs: b.samples.inert.readyMs,
      deltaMs: b.delta
    })),
    primary: 'traced'
  }
  const dest = outPath || path.join(FIX, `result-${mode}-pilot.json`)
  fs.writeFileSync(dest, JSON.stringify(result, null, 2) + '\n')
  console.log(`\nresult written: ${path.relative(ROOT, dest)}`)
}

main().catch((error) => {
  process.stderr.write(`boot-bench engine error: ${error.stack || error.message}\n`)
  process.exitCode = 2
}).finally(() => {
  for (const dir of cacheDirs) fs.rmSync(dir, { recursive: true, force: true })
  fs.rmSync(cfg, { recursive: true, force: true })
})

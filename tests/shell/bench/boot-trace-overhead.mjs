#!/usr/bin/env node
// Paired overhead benchmark for Phase 0 boot observation.
//
// Both variants process the SAME representative stream of boot turns and
// produce the SAME encoded report on the wire. The traced variant uses the real
// BootTrace recorder; the inert variant is the observation-free path (ids are
// still handed out, but nothing is captured). Logical parity of the decoded
// report is asserted BEFORE any timing is reported, and the two variants are
// alternated so a drifting host cannot flatter one side.
//
// This is a node-side measurement of the recorder/codec path on common external
// observables - it is not a GUI timing, a paint time, or a claim about frames.
import fs from 'node:fs'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import { loadLib } from '../lib/qmlloader.mjs'
import { SHELL_DIR, deepEqual } from '../lib/assert.mjs'

const BT = loadLib(path.join(SHELL_DIR, 'boot/BootTrace.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const FIXTURES = path.resolve(path.dirname(import.meta.dirname), 'fixtures', 'boot-trace')
const rows = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'overhead-stream.json'), 'utf8'))
const frozen = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'frozen-report.json'), 'utf8'))

const CONTEXT = { source: 'launcher', estimate: 0 }
const DIGEST = '49 units, 14 essential'
let failures = 0
function check(label, cond) {
  if (cond) console.log('PASS ' + label)
  else { failures++; console.log('FAIL ' + label) }
}

// One shared interpreter for both variants. Only the observer differs: the
// boot turns, their order, their causes and their clock are identical.
function runStream(makeObserver) {
  let ms = 0
  const clock = { now: () => ms }
  const obs = makeObserver(clock)
  const map = Object.create(null)
  const tokens = Object.create(null)
  obs.setContext(CONTEXT, DIGEST)
  obs.setTokenCap(32)
  for (const row of rows) {
    if (row.tMs !== undefined) ms = row.tMs
    if (row.op === 'workOpen') { tokens[row.token] = obs.openWork(row.source, row.kind); continue }
    if (row.op === 'workClose') { obs.closeWork(row.source, tokens[row.token], row.outcome); delete tokens[row.token]; continue }
    if (row.op === 'closeAdmission') { obs.closeAdmission(row.source, row.by); continue }
    if (row.op === 'skip') { obs.skip(row.source, row.reason); continue }
    if (row.op === 'seal') { obs.seal(row.reason); continue }
    const fields = Object.assign({}, row.fields || {})
    if (row.causes !== undefined) {
      fields.causes = row.causes.map(id => {
        if (map[id] === undefined) throw new Error('unmapped ref ' + id + ' at row ' + row.id)
        return map[id]
      })
    }
    const id = obs.emit(row.kind, fields)
    if (id) map[row.id] = id
  }
  return obs.snapshot()
}

function tracedObserver(clock) {
  return BT.create(clock)
}

// The inert path still walks the stream and hands out ids exactly as a caller
// expects, but captures nothing. Its report is the canonical frozen projection
// that the real recorder produces for this very stream (asserted below).
function inertObserver() {
  let seq = 0
  let tokenSeq = 0
  return {
    setContext() {}, setTokenCap() {},
    emit() { return ++seq },
    openWork() { return ++tokenSeq },
    closeWork() { return true },
    closeAdmission() {}, skip() {}, seal() {},
    snapshot() { return frozen }
  }
}

function frame(report) {
  return P.encode(P.ok(report, 'boottime'))
}

function once(variant) {
  const report = runStream(variant === 'traced' ? tracedObserver : inertObserver)
  return P.asciiBytes(frame(report))
}

// --- logical parity, before any timing -------------------------------------
{
  const tracedReport = runStream(tracedObserver)
  const inertReport = runStream(inertObserver)
  check('traced report equals the frozen projection', deepEqual(tracedReport, frozen))
  check('inert report equals the frozen projection', deepEqual(inertReport, frozen))
  check('traced and inert reports agree', deepEqual(tracedReport, inertReport))

  const f = frame(frozen)
  const decoded = P.decode(f)
  check('the frame is a v1 envelope', f.startsWith('v1:'))
  check('the decoded data is the frozen report', !!decoded && deepEqual(decoded.data, frozen))
  check('the decoded format is boottime',
    !!decoded && decoded.format === 'boottime' && P.OUTPUT_KINDS.includes(decoded.format)
      && P.formatOf({ output: { kind: decoded.format } }, decoded.data).kind === 'boottime')
  check('the frame fits the installed reply cap', P.asciiBytes(f) <= P.MAX_REPLY_BYTES)
  check('the non-ASCII participant is escaped on the wire', f.includes('\\u65e5\\u672c\\u8a9e'))
}

if (failures) {
  console.log(`\n${failures} parity check(s) failed; no timings reported.`)
  process.exit(1)
}

// --- paired timing ----------------------------------------------------------
const WARMUP = 40
const ITERATIONS = 400
const samples = { traced: [], inert: [] }
function sample(variant) {
  const t0 = performance.now()
  once(variant)
  samples[variant].push(performance.now() - t0)
}
for (let i = 0; i < WARMUP; i++) { sample('traced'); sample('inert') }
for (let i = 0; i < ITERATIONS; i++) {
  if (i % 2 === 0) { sample('traced'); sample('inert') }
  else { sample('inert'); sample('traced') }
}
function p50(list) {
  const sorted = list.slice().sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]
}
const tracedP50 = p50(samples.traced)
const inertP50 = p50(samples.inert)
console.log(`\npaired boot-turn iterations: ${ITERATIONS} per variant (${WARMUP} warmup pairs)`)
console.log(`traced  p50: ${tracedP50.toFixed(4)} ms`)
console.log(`inert   p50: ${inertP50.toFixed(4)} ms`)
console.log(`ratio traced/inert: ${(tracedP50 / inertP50).toFixed(3)}`)
console.log(`delta traced-inert: ${(tracedP50 - inertP50).toFixed(4)} ms`)

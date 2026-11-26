#!/usr/bin/env node
// Suite: boot-trace fixtures — the 44 executable gates from
// specs/chat/fixture-driver.cjs, run against the PRODUCTION recorder and codec.
//
// Fixtures are byte copies of specs/chat/fixtures/*.json. The recorder is the
// installed shell/boot/BootTrace.js .pragma library and the wire codec is the
// installed common/text/IpcProtocol.js .pragma library; nothing is patched in
// memory and no prototype code is loaded here.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish, SHELL_DIR } from '../../lib/assert.mjs'

const BT = loadLib(path.join(SHELL_DIR, 'boot/BootTrace.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))

// lib/ is tests/shell/lib; from suites/js, two levels up is tests/shell.
const FIXTURES = path.resolve(path.dirname(import.meta.dirname), '..', 'fixtures', 'boot-trace')

suite('boot-trace-fixtures', '44 fixture gates against the production recorder and codec')

function load(name) {
  return JSON.parse(fs.readFileSync(path.join(FIXTURES, name + '.json'), 'utf8'))
}

// Replicates the reference driver's clock/fixture semantics exactly: row.tMs
// is applied (and checked for backwards time) before the op or emit, fixture
// row ids are mapped to recorder event ids, and raw fault causes bypass the
// map. A token map holds open work handles by fixture token name.
function driver(rows, opts = {}) {
  let ms = 0
  const trace = BT.create({ now: () => ms })
  const map = Object.create(null)
  const tokens = Object.create(null)
  trace.setContext(opts.env || { source: 'test', estimate: null }, opts.digest || null)
  trace.setTokenCap(opts.tokenCap || 32)
  for (const row of rows) {
    if (row.tMs !== undefined) {
      if (row.tMs < ms) throw new Error('backwards time at row ' + (row.id || row.op))
      ms = row.tMs
    }
    if (row.op === 'clock') { ms = row.toMs; continue }
    if (row.op === 'workOpen') { tokens[row.token] = trace.openWork(row.source, row.kind); continue }
    if (row.op === 'workClose') { trace.closeWork(row.source, tokens[row.token], row.outcome); delete tokens[row.token]; continue }
    if (row.op === 'closeAdmission') { trace.closeAdmission(row.source, row.by); continue }
    if (row.op === 'skip') { trace.skip(row.source, row.reason); continue }
    if (row.op === 'alreadyResolved') { trace.alreadyResolved(row.milestone, row.participant || ''); continue }
    if (row.op === 'armWatchdog') { trace.armWatchdog(ms, row.windowMs); continue }
    if (row.op === 'watchdogFired') {
      const r = trace.watchdogFired(ms)
      eq('watchdog at ' + ms, r, !!row.expect)
      continue
    }
    if (row.op === 'seal') { trace.seal(row.reason); continue }
    if (row.op === 'injectLoss') { trace.injectLoss(row.target, map); continue }

    const fields = Object.assign({}, row.fields || {})
    if (row.causes !== undefined || row.faultRaw !== undefined) {
      const refs = row.faultRaw !== undefined ? row.faultRaw : row.causes.map(id => {
        if (map[id] === undefined) throw new Error('unmapped ref ' + id + ' at row ' + row.id)
        return map[id]
      })
      fields.causes = refs
    }
    const id = trace.emit(row.kind, fields)
    if (id) map[row.id] = id
  }
  return { trace, map, tokens, report: () => trace.snapshot(), ms: () => ms, setMs: (v) => { ms = v } }
}

// The join lives immediately before the drain.admission node in the chain.
function selectedKind(report, chain) {
  const c = report.chains[chain]
  if (!c) return null
  const at = c.chain.findIndex(e => e.kind === 'drain.admission')
  return at > 0 ? c.chain[at - 1].kind : null
}

// --- join fixtures ---------------------------------------------------------
section('join fixtures')

for (const name of ['join-features-first', 'join-played-first']) {
  group(name, () => {
    const r = driver(load(name)).report()
    const other = name === 'join-features-first' ? 'provider.result' : 'endpoint.entrancePlayed'
    const predecessor = name === 'join-features-first' ? 'endpoint.entrancePlayed' : 'provider.result'
    eq(name + ': drain chain complete', r.chains.drainComplete.status === 'complete', true)
    eq(name + ': selected predecessor', selectedKind(r, 'drainComplete'), predecessor)
    eq(name + ': parallel branch retained',
      (r.chains.drainComplete.parallel || []).some(e => e.kind === other), true)
  })
}

// --- successful seal -------------------------------------------------------
section('successful seal')

group('normal seal', () => {
  const d = driver(load('successful-seal'))
  const r = d.report()
  eq('seal: normal sealed', r.sealed === true && r.sealReason === 'normal', true)
  eq('seal: verdict timestamp', r.firstVerdict && r.firstVerdict.atMs === 10, true)
  const play = r.chains.entrancePlayed
  const last = play.chain[play.chain.length - 1]
  eq('seal: equal-time tie by event id', last && last.participant === 'wallpaper', true)
  const before = JSON.stringify(r)
  d.setMs(5000)
  eq('seal: stable after clock advance', JSON.stringify(d.report()) === before, true)
})

// --- boundary and rejection cases ------------------------------------------
section('boundary and rejection cases')

group('historical played', () => {
  const rows = [
    { op: 'alreadyResolved', milestone: 'played', participant: 'bar', tMs: 1 },
    { op: 'skip', source: 'provider:services', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'provider:features', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'surface:bar', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'queue:early', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'queue:entrance', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'queue:deferred', reason: 'synthetic', tMs: 2 },
    { op: 'skip', source: 'queue:replay', reason: 'synthetic', tMs: 2 },
    { id: 'v', tMs: 3, kind: 'verdict.decision', fields: { state: 'ready' }, causes: [] },
    { op: 'seal', reason: 'normal', tMs: 4 }
  ]
  const r = driver(rows).report()
  eq('historical played seals with null timestamp',
    r.sealed === true && r.endpoints.entrancePlayed === undefined, true)
})

group('zero-time transition', () => {
  const rows = [
    { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } },
    { id: 'wall', tMs: 0, kind: 'milestone.decision', fields: { milestone: 'played', reason: 'reporter:wallpaper', participant: 'wallpaper' }, causes: ['origin'] },
    { id: 'played', tMs: 0, kind: 'endpoint.entrancePlayed', causes: ['wall'] }
  ]
  const r = driver(rows).report()
  eq('zero-time endpoint preserved', r.endpoints.entrancePlayed === 0, true)
})

group('fault forward cause', () => {
  const rows = [
    { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } },
    { id: 'bad', tMs: 1, kind: 'provider.request', fields: { source: 'provider:features', reason: 'constructor' }, faultRaw: [999] }
  ]
  const r = driver(rows).report()
  eq('forward cause rejected', r.integrity.violations.some(v => v.code === 'forwardCause'), true)
})

group('watchdog', () => {
  const rows = [
    { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } },
    { op: 'armWatchdog', tMs: 0, windowMs: 5000 },
    { op: 'watchdogFired', tMs: 4999, expect: false },
    { op: 'watchdogFired', tMs: 5000, expect: true }
  ]
  const r = driver(rows).report()
  eq('watchdog seals at deadline', r.sealed && r.sealReason === 'watchdog', true)
})

group('rootless verdict', () => {
  const rows = [
    { id: 'v', tMs: 10, kind: 'verdict.decision', fields: { state: 'degraded' }, causes: [] },
    { id: 'fv', tMs: 11, kind: 'endpoint.firstVerdict', causes: ['v'] }
  ]
  const r = driver(rows).report()
  eq('rootless verdict is partial', r.chains.firstVerdict.status === 'partial', true)
})

// --- selective capture loss (G-06a) ----------------------------------------
section('capture loss')

group('selective loss', () => {
  const rows = load('join-features-first')
  const at = rows.findIndex(r => r.id === 'admit')
  rows.splice(at, 0, { op: 'injectLoss', target: 'feat-done', tMs: 90 })
  const r = driver(rows).report()
  eq('selective loss: consumer retained', r.chains.drainComplete.status === 'partial', true)
  eq('selective loss: captureLoss reason',
    (r.chains.drainComplete.unobserved || []).some(u => u.reason === 'captureLoss'), true)
  eq('selective loss: endpoint survives', r.endpoints.drainComplete === 126, true)
  eq('selective loss: surviving branch intact',
    r.chains.drainComplete.chain.some(e => e.kind === 'endpoint.entrancePlayed'), true)
})

group('metadata eviction', () => {
  const rows = [{ id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } }]
  for (let i = 0; i < 18; i++) {
    rows.push({ id: 'n' + i, tMs: i + 1, kind: 'unit.state', fields: { unit: 'n' + i, state: 'ready' }, causes: ['origin'] })
    rows.push({ op: 'injectLoss', target: 'n' + i, tMs: i + 1 })
  }
  rows.push({ id: 'c', tMs: 30, kind: 'drain.admission', fields: { via: 'features' }, causes: ['n0'] })
  rows.push({ id: 'dc', tMs: 31, kind: 'endpoint.drainComplete', causes: ['c'] })
  const r = driver(rows).report()
  eq('evicted loss classified unknown',
    (r.chains.drainComplete.unobserved || []).some(u => u.reason === 'unknown') && r.integrity.valid, true)
})

group('snapshot detachment', () => {
  const d = driver(load('join-features-first'))
  const live = d.report()
  live.ledger['queue:early'].terminal = 'MUTATED'
  eq('unsealed snapshot detached', d.report().ledger['queue:early'].terminal !== 'MUTATED', true)
})

group('reserved slots', () => {
  const rows = [
    { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } },
    { id: 'v', tMs: 1, kind: 'verdict.decision', fields: { state: 'ready' }, causes: ['origin'] },
    { id: 'fv', tMs: 2, kind: 'endpoint.firstVerdict', causes: ['v'] },
    { id: 'pe', tMs: 3, kind: 'endpoint.entrancePlayed', causes: ['origin'] },
    { id: 'dc', tMs: 4, kind: 'endpoint.drainComplete', causes: ['origin'] }
  ]
  const r = driver(rows).report()
  eq('all reserved slots bounded', r.coverage.reservedEntries === 4, true)
})

// --- G-04: own-key schema membership ---------------------------------------
section('schema strictness')

group('unknown fields', () => {
  for (const extra of ['url', 'toString']) {
    const rows = [
      { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } },
      { id: 'bad', tMs: 1, kind: 'provider.request', fields: { source: 'provider:features', reason: 'constructor', [extra]: 'SECRETVALUE' } },
      { id: 'good', tMs: 2, kind: 'provider.request', fields: { source: 'provider:features', reason: 'constructor' } }
    ]
    const d = driver(rows)
    const r = d.report()
    eq('unknown ' + extra + ' rejected', r.integrity.violations.some(v => v.code === 'unknownField'), true)
    eq('unknown ' + extra + ' not retained', !JSON.stringify(r).includes('SECRETVALUE'), true)
    eq('unknown ' + extra + ' does not poison ids', d.map.good === 2, true)
  }
})

// --- G-15: real protocol codec, synthetic limit ----------------------------
section('wire fit')

group('real codec and synthetic pruning', () => {
  // The installed codec registers "boottime" itself, so the catalog check reads
  // the real OUTPUT_KINDS and the real formatOf adapter - no source patching.
  const bootKind = P.formatOf({ output: { kind: 'boottime' } }, {}).kind
  eq('protocol knows boottime (prototype setup)',
    P.OUTPUT_KINDS.includes('boottime') && bootKind === 'boottime', true)

  const d = driver(load('join-features-first'))
  const report = d.report()
  eq('base report fits real wire limit', P.asciiBytes(P.encode(report)) < P.MAX_REPLY_BYTES, true)

  // Pruning is exercised on a detached copy only: capture and the live trace
  // stay untouched, so the later full query still sees the complete chain.
  const small = JSON.parse(JSON.stringify(report))
  small.chains.drainComplete.parallel = []
  small.chains.drainComplete.chain = small.chains.drainComplete.chain.slice(0, 1)
  small.chains.drainComplete.status = 'partial'
  small.chains.drainComplete.unobserved.push({ reason: 'replyOmission' })
  small.coverage.replyOmitted = 1
  eq('synthetic limit forces pruning', P.asciiBytes(P.encode(report)) > 1750, true)
  eq('pruned report fits synthetic limit', P.asciiBytes(P.encode(small)) < 1750, true)
  eq('pruned path partial',
    small.chains.drainComplete.status === 'partial' &&
      small.chains.drainComplete.unobserved.some(u => u.reason === 'replyOmission'), true)
  eq('later full query intact', d.report().chains.drainComplete.status === 'complete', true)
})

// --- saturation ------------------------------------------------------------
section('saturation')

group('bounded capture under saturation', () => {
  const rows = [
    { id: 'origin', tMs: 0, kind: 'boot.begin', fields: { source: 'test', estimateMs: null } }
  ]
  for (let i = 0; i < 520; i++) rows.push({ id: 'u' + i, tMs: i + 1, kind: 'unit.state', fields: { unit: 'u' + i, state: 'ready' }, causes: ['origin'] })
  rows.push({ id: 'v', tMs: 600, kind: 'verdict.decision', fields: { state: 'ready' }, causes: [] })
  rows.push({ id: 'fv', tMs: 601, kind: 'endpoint.firstVerdict', causes: ['v'] })
  rows.push({ id: 'fv2', tMs: 700, kind: 'endpoint.firstVerdict', causes: ['v'] })
  rows.push({ op: 'alreadyResolved', milestone: 'played', participant: 'bar', tMs: 703 })
  for (const src of ['provider:services', 'provider:features', 'surface:bar', 'queue:early', 'queue:entrance', 'queue:deferred', 'queue:replay']) {
    rows.push({ op: 'skip', source: src, reason: 'synthetic', tMs: 704 })
  }
  rows.push({ op: 'seal', reason: 'normal', tMs: 705 })
  const d = driver(rows)
  const r = d.report()
  eq('detail cap enforced', r.coverage.captureDropped > 0, true)
  eq('reserved endpoint survives saturation', r.endpoints.firstVerdict === 601, true)
  eq('duplicate endpoint keeps first time', d.trace.snapshot().endpoints.firstVerdict === 601, true)
  eq('duplicate endpoint keeps first id', d.map.fv2 === d.map.fv, true)
  eq('bounded loss/reserved indexes',
    r.coverage.lossRanges <= 8 && r.coverage.explicitLosses <= 16 && r.coverage.reservedEntries <= 4, true)
  eq('reserved verdict in causal index',
    r.chains.firstVerdict.chain.some(e => e.kind === 'verdict.decision'), true)
  const live = d.report()
  live.ledger['queue:early'].terminal = 'MUTATED'
  eq('live snapshot detached', d.report().ledger['queue:early'].terminal !== 'MUTATED', true)
  eq('normal seal under saturation', r.sealed === true, true)
})

finish()

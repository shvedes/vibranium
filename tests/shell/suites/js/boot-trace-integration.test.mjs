#!/usr/bin/env node
// Suite: boot-trace integration - installed codec/catalog, frozen-report wire
// fit, CLI render_data, static observation purity, and the live-shell boundary.
//
// No fixture is registered in production code. The frozen report is read from
// tests/shell/fixtures/boot-trace/frozen-report.json; the CLI probe imports the
// installed bin/vb-shell module and calls render_data directly.
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync, spawnSync } from 'node:child_process'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, skip, finish, SHELL_DIR } from '../../lib/assert.mjs'

const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const VIBRANIUM_DIR = path.resolve(SHELL_DIR, '..')
const FIXTURES = path.resolve(path.dirname(import.meta.dirname), '..', 'fixtures', 'boot-trace')
const frozen = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'frozen-report.json'), 'utf8'))

suite('boot-trace-integration', 'installed boot.time surface, frozen wire fit, CLI purity')

// --- installed catalog and codec -------------------------------------------
section('installed surface')

group('boot.time is declared', () => {
  eq('boottime is an installed output kind', P.OUTPUT_KINDS.includes('boottime'), true)
  const row = C.findRow('boot.time')
  eq('the boot.time catalog row exists', !!row, true)
  eq('the row lives under the boot target', row.id.slice(0, 5), 'boot.')
  eq('the row has a single literal word', JSON.stringify(row.words), '["time"]')
  eq('the row carries the boottime renderer', row.output.kind, 'boottime')
  eq('the row replies as JSON', row.reply.kind, 'json')
  eq('the boot target is discoverable', !!C.findTarget('boot'), true)
  eq('the time verb matches through the real grammar', P.match(row.words, ['time']).ok, true)
  eq('formatOf keeps boottime', P.formatOf({ output: { kind: 'boottime' } }, frozen).kind, 'boottime')
  eq('an index request validates', P.validateRequest('describe', { v: 1, kind: 'index' }).kind, 'index')
  eq('a boot time request validates',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['boot', 'time'], literalFrom: null }).kind, 'call')
})

group('pre-existing rows and index targets survive', () => {
  for (const id of ['boot.state', 'boot.timeline', 'shell.doctor', 'settings.get', 'state.get', 'notifications.history']) {
    eq('old row ' + id + ' remains', !!C.findRow(id), true)
  }
  const ids = C.targetIds()
  eq('target ids stay sorted', JSON.stringify(ids) === JSON.stringify(ids.slice().sort()), true)
  eq('the boot target is in the index list', ids.includes('boot'), true)
  eq('the shell target is in the index list', ids.includes('shell'), true)
  eq('common verbs are unchanged', JSON.stringify(C.commonRows().map(r => r.id)),
    JSON.stringify(['help', 'status', 'ping']))
})

// --- frozen report wire fit -------------------------------------------------
section('frozen report wire fit')

group('the frozen report is the specimen', () => {
  eq('zero endpoint timestamp survives', frozen.endpoints.firstVerdict, 0)
  eq('nested state survives', frozen.firstVerdict.state, 'ready')
  eq('equal-time tie selected the later id', frozen.chains.entrancePlayed.chain.slice(-1)[0].participant, 'wallpaper')
  eq('the parallel branch is retained', JSON.stringify(frozen.chains.entrancePlayed.parallel.map(e => e.participant)),
    JSON.stringify(['日本語']))
  eq('the ledger is complete', Object.keys(frozen.ledger).length, 7)
  eq('integrity is valid', frozen.integrity.valid, true)
  eq('coverage is bounded', frozen.coverage.reservedEntries, 4)
})

group('encoded frame', () => {
  const frame = P.encode(P.ok(frozen, 'boottime'))
  const decoded = P.decode(frame)
  eq('the frame is a v1 envelope', frame.startsWith('v1:'), true)
  eq('the frame fits the installed reply cap', P.asciiBytes(frame) <= P.MAX_REPLY_BYTES, true)
  eq('the decoded data is the frozen report', decoded.data, frozen)
  eq('the decoded format is boottime', decoded.format, 'boottime')
  eq('the non-ASCII participant is escaped', frame.includes('\\u65e5\\u672c\\u8a9e'), true)
  eq('the escaped frame has no raw non-ASCII byte', /[^\x00-\x7f]/.test(frame), false)
})

// --- CLI render_data --------------------------------------------------------
section('CLI render_data')

const PY = `
import importlib.machinery as im, importlib.util as iu, json, sys
l = im.SourceFileLoader('vbshell', sys.argv[1])
s = iu.spec_from_loader('vbshell', l)
m = iu.module_from_spec(s)
l.exec_module(m)
f = json.load(open(sys.argv[2], encoding='utf-8'))
sys.stdout.write(m.render_data({'data': f}, {'kind': sys.argv[3]}, sys.argv[4] == 'json'))
`
function cliRender(kind, mode) {
  return execFileSync('python3', ['-c', PY, path.join(VIBRANIUM_DIR, 'bin/vb-shell'),
    path.join(FIXTURES, 'frozen-report.json'), kind, mode], { encoding: 'utf8' })
}

group('boottime JSON path', () => {
  let parsed = null
  try { parsed = JSON.parse(cliRender('boottime', 'json')) } catch (error) { parsed = null }
  eq('boottime JSON is parseable', !!parsed, true)
  eq('boottime JSON is the frozen report', parsed, frozen)
  eq('nested state is preserved', parsed && parsed.firstVerdict.state, 'ready')
  eq('zero endpoint timestamp is preserved', parsed && parsed.endpoints.firstVerdict, 0)
})

group('boottime text path', () => {
  const text = cliRender('boottime', 'text')
  eq('the text view names the boot report', text.startsWith('Vibranium boot '), true)
  eq('the text view prints a real zero', text.includes('firstVerdict: 0ms'), true)
  eq('the text view keeps the ledger', text.includes('provider:services'), true)
  eq('the text view keeps the non-ASCII parallel participant', text.includes('日本語'), true)
})

group('other kinds still strip state', () => {
  const plain = cliRender('value', 'json')
  eq('a non-boottime JSON reply is parseable', (() => { try { return !!JSON.parse(plain) } catch { return false } })(), true)
  eq('a non-boottime reply drops nested state', plain.includes('"state"'), false)
})

// --- static purity of the observation hooks ---------------------------------
section('observation purity')

function bodyOf(src, marker) {
  const at = src.indexOf(marker)
  if (at < 0) return ''
  const open = src.indexOf('{', at)
  if (open < 0) return ''
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(open, i + 1)
    }
  }
  return ''
}

const bootSrc = fs.readFileSync(path.join(SHELL_DIR, 'boot/Boot.qml'), 'utf8')
const layoutSrc = fs.readFileSync(path.join(SHELL_DIR, 'common/state/DesktopLayoutState.qml'), 'utf8')
const bootHooks = [
  'function _observeMilestone(', 'function _observeAlreadyResolved(',
  'function _observeServicesDemand(', 'function _observeServicesResult(',
  'function _observeFeaturesDemand(', 'function _observeFeaturesResult(',
  'function _closeQueueLedger(', 'function _completeDrain(',
  'function _noteGatewayRegistration(', 'function _bootReport()',
  'function _wireBytes(', 'function _fitBootReport(',
  'function jsonOf(', 'function time(): string'
]
const layoutHooks = [
  'function noteBootEntranceSettled(', 'function noteBootEntrancePlayed(',
  'function retireBootEntranceParticipant(', 'function _forceBootEntrancePlayed()',
  'function noteBootConstructionSettled('
]

group('Boot.qml observers add no log line', () => {
  for (const marker of bootHooks) {
    const body = bodyOf(bootSrc, marker)
    eq(marker + ' exists', body.length > 0, true)
    eq(marker + ' calls no Log.*', /Log\./.test(body), false)
  }
})

group('DesktopLayoutState.qml wrappers add no log line', () => {
  for (const marker of layoutHooks) {
    const body = bodyOf(layoutSrc, marker)
    eq(marker + ' exists', body.length > 0, true)
    eq(marker + ' calls no Log.*', /Log\./.test(body), false)
  }
})

group('boot registration is observation-only', () => {
  eq('gateway registration is noted after shell register',
    /IpcRouter\.register\("shell"[\s\S]{0,300}_noteGatewayRegistration\("shell"/.test(bootSrc), true)
  eq('gateway registration is noted after boot register',
    /IpcRouter\.register\("boot"[\s\S]{0,1200}_noteGatewayRegistration\("boot"/.test(bootSrc), true)
  const noteBody = bodyOf(bootSrc, 'function _noteGatewayRegistration(')
  eq('a failed gateway registration does not seal', /_sealTrace|Log\./.test(noteBody), false)
  eq('a failed gateway registration still emits an observation',
    noteBody.includes('boot.trace.emit("gateway.registered"'), true)
  eq('the catalog failure path is the only aborted seal in onCompleted',
    /if \(!catalogOk\) \{[\s\S]{0,80}_sealTrace\("aborted"\)/.test(bootSrc), true)
  eq('the native time handler uses the same projection',
    bodyOf(bootSrc, 'function time(): string').includes('boot._bootReport()'), true)
})

// --- the live-shell boundary ------------------------------------------------
section('live shell')

group('vb-shell boot time', () => {
  const live = spawnSync(path.join(VIBRANIUM_DIR, 'bin/vb-shell'), ['boot', 'time'],
    { encoding: 'utf8', timeout: 6000 })
  const reachable = live.status === 0 && live.stdout.trim().startsWith('{')
  if (!reachable) {
    skip('live vb-shell boot time', 'no running shell with a registered boot target on this host')
    skip('live vb-shell boot time --json', 'no running shell with a registered boot target on this host')
    return
  }
  let parsed = null
  try { parsed = JSON.parse(live.stdout.trim()) } catch { parsed = null }
  eq('the live gateway returns a report object', !!parsed, true)
  eq('the live report is sealed', parsed && parsed.sealed, true)
  const liveJson = spawnSync(path.join(VIBRANIUM_DIR, 'bin/vb-shell'), ['boot', 'time', '--json'],
    { encoding: 'utf8', timeout: 6000 })
  let parsedJson = null
  try { parsedJson = JSON.parse(liveJson.stdout.trim()) } catch { parsedJson = null }
  eq('the JSON mode returns the same report', parsedJson, parsed)
})

finish()

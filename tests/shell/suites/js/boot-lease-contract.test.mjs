#!/usr/bin/env node
// Static companion for the Phase 4 conditional lease audit.
//
// The live probe (suites/qml/probes/boot-lease-audit.qml) exercises the neutral
// UnitLease/UnitGate/IpcRouter contract. This suite pins the SHIPPED call sites
// that the probe cannot construct headlessly, plus the fixture contract the
// bash half reads. Nothing here changes a phase string or an API; a failure
// means the pin no longer matches the source and the audit must be redone.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, ne, contains, notContains, is, finish, SHELL_DIR
} from '../../lib/assert.mjs'

const read = (rel) => fs.readFileSync(path.join(SHELL_DIR, rel), 'utf8')
const ROUTER = read('common/bus/IpcRouter.qml')
const LEASE = read('common/runtime/UnitLease.qml')
const GATE = read('common/runtime/UnitGate.qml')
const LAUNCHER = read('features/launcher/AppLauncher.qml')
const LATE = read('boot/BootLate.qml')
const GENERATED_FEATURES = read('boot/generated/features/FeaturesHandlers.qml')
const CATALOG = read('boot/Units.catalog.js')

const FIXTURES = path.resolve(path.dirname(import.meta.dirname), '..', 'fixtures', 'boot-lease')
const fx = (name) => JSON.parse(fs.readFileSync(path.join(FIXTURES, name + '.json'), 'utf8'))

// Slice around a unique marker so a field check cannot be satisfied by a
// different catalog row that happens to use the same words.
function around(src, marker, before = 0, after = 1400) {
  const at = src.indexOf(marker)
  if (at < 0) throw new Error('marker not found: ' + marker)
  return src.slice(Math.max(0, at - before), at + after)
}

suite('boot-lease-contract', 'static pins and fixtures for the conditional lease investigation')

section('fixtures exist, are versioned, and agree on the wire codes')
const moments = fx('moments')
const pending = fx('facade-pending')
const blocked = fx('facade-blocked')
const failed = fx('facade-failed')

const KINDS = {
  moments: 'boot-lease-moments',
  pending: 'boot-lease-facade-pending',
  blocked: 'boot-lease-facade-blocked',
  failed: 'boot-lease-facade-failed'
}
for (const [name, body] of Object.entries({ moments, pending, blocked, failed })) {
  group(name, () => {
    eq(name + ' version', body.version, 1)
    eq(name + ' kind', body.kind, KINDS[name])
    is(name + ' has a description', body.description, (v) => typeof v === 'string' && v.length > 30, 'non-trivial description')
  })
}
eq('shortcut words are the shipped target and verb', moments.shortcutWords, ['appLauncher', 'toggle'])

for (const m of ['before', 'loading', 'adopted']) {
  group('moment ' + m, () => {
    eq(m + ' has no registered target', moments.moments[m].registered, false)
    for (const verb of ['open', 'shortcut']) {
      eq(m + ' ' + verb + ' ok', moments.moments[m][verb].ok, false)
      eq(m + ' ' + verb + ' code', moments.moments[m][verb].code, 'unavailable')
      eq(m + ' ' + verb + ' message', moments.moments[m][verb].message, 'owner not registered')
    }
  })
}
group('facade moment', () => {
  eq('registered', moments.moments.facade.registered, true)
  eq('open ok', moments.moments.facade.open.ok, true)
  eq('shortcut ok', moments.moments.facade.shortcut.ok, true)
})
group('pending versus blocked versus failed', () => {
  eq('pending and blocked wire replies are identical', pending.first, blocked.reply)
  eq('failed controller wire reply is identical too', failed.controllerStartupError.reply, blocked.reply)
  eq('resolver-throw wire reply is identical too', failed.resolverThrows.reply, blocked.reply)
  ne('pending lease error is not the blocked error', pending.error, blocked.error)
  eq('blocked has its own code', blocked.ensure.code, 'dependency_blocked')
  eq('pending ensure is ok with no state built', pending.ensure.state, 'not_started')
  eq('the dropped demand built no controller', pending.constructions, moments.moments.facade.constructions)
  eq('only the recovery built one', pending.recoveredConstructions, pending.constructions + 1)
})

section('IpcRouter: unregistered targets are refused before any owner runs')
contains('the registered guard is in _invokeWords', ROUTER, 'if (!registered(target)) return error("unavailable", "owner not registered")')
const dispatchAt = ROUTER.indexOf('function _invokeWords(argv)')
const guardAt = ROUTER.indexOf('if (!registered(target)) return error("unavailable", "owner not registered")', dispatchAt)
const runAt = ROUTER.indexOf('return _run(target, chosen', dispatchAt)
is('the guard precedes owner dispatch', guardAt > dispatchAt && runAt > guardAt, (v) => v === true, 'guard before _run in _invokeWords')
contains('the shortcut word table pins appLauncher.toggle', ROUTER, '"appLauncher.toggle": ["appLauncher", "toggle"],')
contains('invokeShortcut decodes through _invokeWords', ROUTER, 'Protocol.decode(root._invokeWords(root._shortcutWords[action]))')
contains('the common verbs share the same refusal', ROUTER, 'if (!registered(target)) return error("unavailable", "owner not registered")')

section('the shipped facade registers its gateway handler on singleton completion')
const completion = around(LAUNCHER, 'Component.onCompleted: {', 0, 5000)
contains('registration is inside the completion handler', completion, 'IpcRouter.register("appLauncher", root, {')
contains('the open verb is registered there', completion, '"appLauncher.open": function () { return root._openGateway() },')
contains('the toggle verb is registered there', completion, '"appLauncher.toggle": function () { return root._toggleGateway() },')
const destruction = around(LAUNCHER, 'Component.onDestruction: {', 0, 1400)
contains('unregistration is in the destruction handler', destruction, 'IpcRouter.unregister("appLauncher", root)')
const openGateway = around(LAUNCHER, 'function _openGateway() {', 0, 520)
contains('a refused demand answers busy while loading', openGateway, '_error("busy", "controller is loading")')
contains('a refused demand otherwise answers unavailable', openGateway, '_error("unavailable", "launcher did not open")')
contains('open() demands the lease before showing anything', around(LAUNCHER, 'function open() {', 0, 900), 'const ctrl = lease.demand()')
contains('a null controller is a refused open', around(LAUNCHER, 'function open() {', 0, 900), 'if (ctrl === null) return false')
contains('_openVerb has no retry of its own', around(LAUNCHER, 'function _openVerb() {', 0, 400), 'return root._unavailableVerb()')

section('provider ownership: the resolver constructs the facade')
// The launcher handler row now lives in the provider-private generated type;
// BootLate.qml only imports it and exposes one owned handler object.
contains('BootLate.qml imports the generated features directory', LATE,
  'import "generated/features" as Generated')
eq('BootLate.qml owns exactly one generated handler property',
  (LATE.match(/property var generatedHandlers:/g) || []).length, 1)
notContains('BootLate.qml no longer declares an authored appLauncher handler row', LATE,
  '"appLauncher": {')
const lateRow = around(GENERATED_FEATURES, '"appLauncher": {', 0, 420)
contains('resolver touches the singleton', lateRow, 'resolve: function() { void AppLauncher.tag },')
contains('ready predicate is the facade flag', lateRow, 'ready: function() { return AppLauncher.facadeReady === true },')
contains('teardown reaches the facade', lateRow, 'teardown: function() { AppLauncher.teardownController() }')
const catalogRow = around(CATALOG, 'id: "appLauncher",', 0, 430)
contains('provider is features', catalogRow, 'provider: "features",')
contains('phase is early', catalogRow, 'phase: "early",')
contains('activation is facade', catalogRow, 'activation: "facade",')
contains('the catalog declares a ready predicate', catalogRow, 'hasReady: true,')
contains('the catalog declares a teardown', catalogRow, 'hasTeardown: true')
// A declined resolver therefore means the singleton was never touched: no
// IpcRouter target exists in the deferred window. This is the caveat that
// makes the candidate defect unproven in shipped code.
contains('boot defers a late unit whose half is missing', read('boot/Boot.qml'), 'if (boot._halvesPending > 0) {')

section('UnitGate: the pending and blocked results are distinct at the gate')
contains('a declined resolver leaves the unit unstarted', around(GATE, 'function _defer(record) {', 0, 280), 'record.state = "not_started"')
contains('blocked carries a machine code', around(GATE, 'function _ensureResult(record, lease) {', 0, 560), 'code: "dependency_blocked"')
const ensureResult = around(GATE, 'function _ensureResult(record, lease) {', 0, 620)
contains('every other state passes through ok=true', ensureResult, 'return { ok: true, state: record.state, lease: lease }')
contains('the retry deadline is epoch based', GATE, 'record.nextRetryMs = Date.now() + delay')

section('UnitLease: the phase vocabulary is unchanged')
contains('the public phases are pinned', LEASE, '// unloaded | loading | ready | unavailable | failed. A verb that cannot run')
notContains('no pending phase was introduced', LEASE, '"pending"')
contains('demand goes through UnitGate.ensure', LEASE, 'const result = UnitGate.ensure(host.unitId, host.owner)')
contains('a missing controller is an unavailable load refusal', LEASE, 'host.unloadFor("unavailable", "load")')
contains('a blocked or failed gate answer is unavailable or failed', LEASE, 'host._setState(failed ? "failed" : "unavailable", failed ? "unit" : "gate")')
contains('refresh is the retry for a deferred unit', around(GATE, 'function _refreshRecord(record) {', 0, 400), 'if (record.state === "not_started") {')

finish()

#!/usr/bin/env node
// Suite: Phase 1 pump contract, checked against the shipped QML sources.
//
// The behavioural half lives in suites/qml/boot-pump-test.sh, which drives the
// real BootPump in an engine. This suite pins the wiring that an offscreen
// pump cannot see: Boot's delegation and observer adapter, the qmldir
// registration, and the literal timer/token/rearm/fault-containment shape of
// BootPump.qml. No line numbers are asserted.
import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notContains, finish, SHELL_DIR
} from '../../lib/assert.mjs'

const read = (rel) => fs.readFileSync(path.join(SHELL_DIR, rel), 'utf8')
const stripComments = (src) => src
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/[^\n]*/g, '')

function bodyAt(src, at) {
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
function bodyOf(src, marker) {
  const at = src.indexOf(marker)
  return at < 0 ? '' : bodyAt(src, at)
}
function allBodies(src, marker) {
  const out = []
  let from = 0
  for (;;) {
    const at = src.indexOf(marker, from)
    if (at < 0) return out
    out.push(bodyAt(src, at))
    from = at + marker.length
  }
}
function count(src, regex) {
  return (src.match(regex) || []).length
}
function matchingBrace(src, open) {
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return i
    }
  }
  return src.length - 1
}
// Blanks the body of every `if (... token ...)` block, so a call that is only
// reachable inside a token guard disappears while the rest of the function
// stays visible to the caller's assertions.
function stripTokenGuardedBodies(src) {
  const re = /if\s*\([^)]*\btoken\b[^)]*\)\s*\{/g
  let out = ''
  let pos = 0
  let m
  while ((m = re.exec(src)) !== null) {
    const open = src.indexOf('{', m.index)
    const end = matchingBrace(src, open)
    out += src.slice(pos, open) + '{}'
    pos = end + 1
    re.lastIndex = pos
  }
  return out + src.slice(pos)
}

const bootSrc = stripComments(read('boot/Boot.qml'))
const bootPumpSrc = stripComments(read('boot/BootPump.qml'))
const qmldir = stripComments(read('boot/qmldir'))

suite('boot-pump', 'Boot delegation, observer adapter, module registration and literal pump contract')

// --- Boot.qml ---------------------------------------------------------------
section('Boot.qml delegates the pump')

group('_requestPump is a thin delegation', () => {
  const request = bodyOf(bootSrc, 'function _requestPump(')
  contains('the function exists', request, '{')
  contains('it calls bootPump.enqueue(fn, boot._pumpSource(fn))',
    request, 'bootPump.enqueue(fn, boot._pumpSource(fn))')
  notContains('it does not keep its own pending list', request, '_pumpedFns')
  notContains('it does not restart its own timer', request, 'restart()')
})

group('the old inline pump is gone', () => {
  for (const marker of ['_pumpedFns', '_pumpTurn', 'drainPump']) {
    eq('Boot.qml no longer declares ' + marker, bootSrc.includes(marker), false)
  }
  eq('Boot.qml owns a BootPump', /BootPump\s*\{/.test(bootSrc), true)
})

group('Boot classifies the source by function identity', () => {
  const source = bodyOf(bootSrc, 'function _pumpSource(')
  contains('the classifier exists', source, '{')
  for (const src of ['queue:early', 'queue:entrance', 'queue:deferred', 'queue:replay']) {
    contains('_pumpSource returns ' + src, source, '"' + src + '"')
  }
})

section('Boot.qml adapter and shutdown')

const observerMethods = ['openWork', 'closeWork', 'enqueue', 'dispatch', 'noteFailure']
// Boot's recorder exposes openWork/closeWork directly; queue and dispatch are
// event kinds emitted through the same recorder, and an observer fault is a
// bounded integrity.violation event.
const adapterTargets = {
  openWork: /\bboot\.trace\.openWork\s*\(/,
  closeWork: /\bboot\.trace\.closeWork\s*\(/,
  enqueue: /\bboot\.trace\.emit\(\s*["']queue\.enqueue["']/,
  dispatch: /\bboot\.trace\.emit\(\s*["']queue\.dispatch["']/,
  noteFailure: /\bboot\.trace\.emit\(\s*["']integrity\.violation["'][\s\S]{0,160}observerThrow/
}
group('the five observer adapter methods are implemented', () => {
  for (const method of observerMethods) {
    match(method + ' is a named Boot adapter', bootSrc,
      new RegExp('(?:function\\s+' + method + '\\s*\\(|\\b' + method + '\\s*:\\s*function)'))
    match(method + ' forwards to the trace recorder', bodyOf(bootSrc, 'function ' + method + '('),
      adapterTargets[method])
  }
  match('the adapter is installed on the pump', bootSrc,
    /(?:bootPump\.observer\s*=|observer\s*:\s*[^,\n]*(?:Trace|trace|Observer|boot))/)
})

group('shutdown closes pump tokens from Boot destruction', () => {
  const bodies = allBodies(bootSrc, 'Component.onDestruction:')
  match('a destruction handler exists', JSON.stringify(bodies), /\{/)
  const withShutdown = bodies.filter((body) => body.includes('bootPump.shutdown()'))
  eq('onDestruction calls bootPump.shutdown()', withShutdown.length >= 1, true)
})

// --- module registration ----------------------------------------------------
section('qs.boot module')

group('qmldir registers the pump type', () => {
  match('BootPump is exported by qs.boot', qmldir, /^BootPump\s+\S+\s+BootPump\.qml\s*$/m)
})

// --- BootPump.qml -----------------------------------------------------------
section('BootPump.qml keeps the literal FIFO')

group('the pump is a QtObject with the original frame timer', () => {
  contains('the pump is a QtObject', bootPumpSrc, 'QtObject {')
  match('the timer keeps the 16 ms frame budget', bootPumpSrc, /\binterval\s*:\s*16\b/)
  match('the timer stays one-shot', bootPumpSrc, /\brepeat\s*:\s*false\b/)
  match('the timer drives _turn', bootPumpSrc, /onTriggered\s*:\s*pump\._turn\(\)/)
})

group('enqueue is per entry, per source', () => {
  const enqueue = bodyOf(bootPumpSrc, 'function enqueue(')
  contains('the function exists', enqueue, '{')
  match('an unclassified source falls back to queue:pump', enqueue, /source\s*\|\|\s*["']queue:pump["']/)
  match('duplicates are detected by function identity', enqueue, /\.fn\s*===\s*fn/)
  match('a duplicate is observed', enqueue, /observer\.enqueue\([^)]*["']duplicate["']/)
  match('an accepted enqueue is observed', enqueue, /observer\.enqueue\([^)]*["']accepted["']/)
  match('the accepted entry gets an observer token', enqueue, /observer\.openWork\(/)
  match('every accepted enqueue restarts the timer', enqueue, /tick\.restart\(\)/)
  eq('enqueue does not stop the timer', /tick\.stop\(\)/.test(enqueue), false)
})

group('token 0 is never an active token', () => {
  match('a positive-token guard exists', bootPumpSrc, /\btoken\s*(?:>|!==|!=)\s*0\b/)
  const turn = bodyOf(bootPumpSrc, 'function _turn(')
  match('_turn guards dispatch and close by token', turn, /\btoken\s*(?:>|!==|!=)\s*0\b/)
  const unguarded = stripTokenGuardedBodies(turn)
  eq('_turn never dispatches without a token guard', /observer\.dispatch\s*\(/.test(unguarded), false)
  eq('_turn never closes without a token guard', /observer\.closeWork\s*\(/.test(unguarded), false)
})

group('_turn preserves the original rearm and throw semantics', () => {
  const turn = bodyOf(bootPumpSrc, 'function _turn(')
  contains('_turn exists', turn, '{')
  match('the entry is popped before invocation', turn, /pending\.shift\(\)/)
  match('the callback exception is caught', turn, /catch\s*\(/)
  match('the close outcome distinguishes throw from return', turn,
    /callbackThrew[\s\S]{0,80}callbackReturned|callbackReturned[\s\S]{0,80}callbackThrew/)
  match('the rearm is gated on a normal return', turn,
    /if\s*\(\s*![\w.]*(?:threw|failed|error|didThrow)\b[\s\S]{0,200}?tick\.restart\(\)/)
  match('a still-pending entry is required for the rearm', turn,
    /pending\.length\s*>\s*0/)
  match('the callback error is rethrown', turn, /\bthrow\s+(?:error|e)\b/)
})

group('observer calls are fault-contained', () => {
  for (const method of observerMethods) {
    match('observer.' + method + ' is called by the pump', bootPumpSrc,
      new RegExp('observer\\.' + method + '\\s*\\('))
  }
  const noteFailure = count(bootPumpSrc, /noteFailure\(\s*["']observerThrow["']\s*\)/g)
  eq('an observer throw is reported with the observerThrow code', noteFailure >= 1, true)
  match('the report is inside a try/catch', bootPumpSrc,
    /try\s*\{[^}]*noteFailure\(\s*["']observerThrow["']\s*\)[^}]*\}\s*catch/)
  eq('fault containment has at least two guarded call sites', count(bootPumpSrc, /\btry\s*\{/g) >= 2, true)
})

group('shutdown closes open tokens with teardown', () => {
  const shutdown = bodyOf(bootPumpSrc, 'function shutdown(')
  contains('the pump exposes shutdown()', shutdown, '{')
  match('shutdown closes with teardown', shutdown, /closeWork\([^)]*["']teardown["']/)
  match('shutdown skips token 0', shutdown, /\btoken\s*(?:>|!==|!=)\s*0\b/)
})

finish()

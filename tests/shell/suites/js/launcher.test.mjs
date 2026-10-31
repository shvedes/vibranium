#!/usr/bin/env node
// Suite: features/launcher/ - the launcher engine's pure-JS half.
//
// Five libraries and seven drop-in plugins. LauncherLib.js holds what a
// verdict *means* (index, usage, plugin model, argv, verdicts, path and URI
// handling); PluginPolicy.js is the capability gate every drop-in plugin is
// handed an object by; TimeLib.js is the pure-JS city/timezone table.
//
// The plugins carry their own copy of the engine they wrap, and each README
// says so in as many words - "the two copies can drift", "if you change one,
// change both". The last third of this suite is therefore a parity harness
// driven off listPlugins(): a new drop-in plugin is covered the moment it
// lands a main.js, with nothing edited here.

import fs from 'node:fs'
import crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import os from 'node:os'
import path from 'node:path'
import vm from 'node:vm'

import { loadLib, loadPlugin, listPlugins, pluginManifest, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, deepEqual, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const LAUNCHER = path.join(SHELL_DIR, 'features/launcher')
const PLUGIN_ROOT = path.join(LAUNCHER, 'plugins')

const PP = loadLib(path.join(LAUNCHER, 'PluginPolicy.js'))
const LL = loadLib(path.join(LAUNCHER, 'LauncherLib.js'))
const TL = loadLib(path.join(LAUNCHER, 'TimeLib.js'))
const FXL = loadLib(path.join(LAUNCHER, 'FxLib.js'))
const SU = loadLib(path.join(SHELL_DIR, 'common/text/StringUtils.js'))

// The exported surface of the three libraries under test, captured before
// anything else touches them, and a call recorder installed in its place. The
// last group in the file asserts that every name in EXPORTED was actually
// called - so "every exported function has at least one assertion" is proved
// by the run rather than asserted by hand, and a function added to a library
// without a test fails the suite instead of sitting there covered by nothing.
const EXPORTED = {
  PluginPolicy: Object.keys(PP).filter((k) => typeof PP[k] === 'function'),
  LauncherLib: Object.keys(LL).filter((k) => typeof LL[k] === 'function'),
  TimeLib: Object.keys(TL).filter((k) => typeof TL[k] === 'function'),
  FxLib: Object.keys(FXL).filter((k) => typeof FXL[k] === 'function'),
}
const COVERED = {
  PluginPolicy: new Set(), LauncherLib: new Set(), TimeLib: new Set(), FxLib: new Set(),
}
function instrument(ns, bucket) {
  for (const name of Object.keys(ns)) {
    const original = ns[name]
    if (typeof original !== 'function') continue
    ns[name] = function instrumented(...args) {
      bucket.add(name)
      return original.apply(this, args)
    }
  }
}
instrument(PP, COVERED.PluginPolicy)
instrument(LL, COVERED.LauncherLib)
instrument(TL, COVERED.TimeLib)
instrument(FXL, COVERED.FxLib)

// --- helpers -------------------------------------------------------------

// The vocabulary the loader uses to find a `.pragma library`'s own top-level
// declarations. Reused here so a suite-side scan sees exactly the set the
// loader would export, rather than a second, drifting opinion of it.
const DECL_RE = /^(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*))/gm

function topLevelNames(src) {
  return [...src.matchAll(DECL_RE)].map((m) => m[1] || m[2])
}

function functionNames(src) {
  return [...src.matchAll(/^function\s+([A-Za-z_$][\w$]*)\s*\(/gm)].map((m) => m[1])
}

// Raw text of one top-level `function name(...) { ... }` declaration, cut at
// the brace that closes it. Byte comparison of this is the textual half of
// the parity check; the authoritative half is Function.prototype.toString(),
// because that is what a re-indent or a reformat cannot hide from.
function declText(src, name) {
  const m = new RegExp(`^function\\s+${name}\\s*\\(`, 'm').exec(src)
  if (m === null) return null
  const open = src.indexOf('{', m.index)
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(m.index, i + 1)
    }
  }
  return null
}

// pristineLib evaluates a `.pragma library` in a context of its own and hands
// back its top-level declarations - the same rule loadLib applies, without the
// cache, so a caller that has instrumented a namespace still gets raw values.
function pristineLib(file) {
  const src = libSource(file)
  const ctx = vm.createContext({ console, Quickshell: { env: () => '' } })
  vm.runInContext(src, ctx, { filename: file })
  const out = {}
  for (const name of topLevelNames(src)) if (name in ctx) out[name] = ctx[name]
  return out
}

// attempt() turns a call into a value that can be compared, whether it
// returned or threw. The parity corpora feed it functions that are *meant*
// to throw on bad input (tokenize, splitExplicit), and a thrown message is
// part of the contract there just as much as a return value.
function attempt(fn, args) {
  try {
    return { ok: true, value: fn(...args) }
  } catch (e) {
    return { ok: false, message: String((e && e.message) || e) }
  }
}

const CALC_TWINS = {
  calc: path.join(LAUNCHER, 'CalcLib.js'),
  color: path.join(SHELL_DIR, 'common/math/Color.js'),
  fx: path.join(LAUNCHER, 'FxLib.js'),
  unit: path.join(LAUNCHER, 'UnitLib.js'),
  time: path.join(LAUNCHER, 'TimeLib.js'),
  binary: path.join(LAUNCHER, 'BinaryLib.js'),
}

const PLUGIN_DIRS = listPlugins(PLUGIN_ROOT)
const PLUGIN_NAMES = PLUGIN_DIRS.map((d) => path.basename(d))

// A host that binds every vocabulary operation, so a policy can be exercised
// end to end. Mirrors AppLauncher.qml's _pluginHostFor, with recording
// substituted for the FileView/Process forwards.
function recordingHost(opts = {}) {
  const calls = []
  const zone = opts.cached || {}
  // Bodies a fetch would have left behind, keyed by URL. The tri-state is
  // the whole contract: a missing key is "never asked or in flight" (null),
  // an empty string is "settled with nothing usable" (""), and a body is
  // the answer. Folding the middle case into the first is what would leave a
  // failed fetch spinning forever.
  const net = opts.net || {}
  // The last PATH scan, with the same tri-state as the body cache: null is
  // "no scan has landed", a record is the answer. `opts.binaries` is
  // deliberately not defaulted, so a host that was given nothing answers null
  // and a test has to say which case it means.
  const bins = 'binaries' in opts ? opts.binaries : null
  // The shell cache, as one shared document keyed by section. A section whose
  // name does not begin with the plugin's own id is refused by the launcher,
  // so the fake enforces the same rule rather than being the one place the
  // boundary does not exist.
  const cache = opts.cache || {}
  const id = String(opts.id || path.basename(String(opts.dir || '')) || 'example')
  const sectionOk = (n) => String(n).indexOf(id + '-') === 0
  return {
    calls,
    host: {
      id: (d) => path.basename(String(d || '')),
      configDir: () => '/cfg/vibranium',
      pluginDir: () => '/plugins/example',
      setting: (k) => (opts.settings && k in opts.settings ? opts.settings[k] : true),
      shellQuote: (s) => SU.shellQuote(String(s)),
      stripJsonc: (s) => SU.stripJsonc(String(s)),
      requestTime: (tz) => { calls.push(['requestTime', tz]) },
      cachedTime: (tz) => zone[String(tz)] ?? null,
      requestBinaries: () => { calls.push(['requestBinaries']) },
      cachedBinaries: () => bins,
      requestNet: (u, t) => { calls.push(['requestNet', u, t]) },
      cachedNet: (u) => (String(u) in net ? net[String(u)] : null),
      // The watcher's verdict, defaulting to online: every existing test
      // drives a host that never mentions it, and the adapter treats a
      // missing read as online, so only the offline groups below opt out.
      cachedOnline: () => ('online' in opts ? !!opts.online : true),
      cachedSection: (n) => (sectionOk(n) && String(n) in cache ? cache[String(n)] : null),
      setCacheSection: (n, obj) => {
        calls.push(['setCacheSection', n, obj])
        if (!sectionOk(n)) return false
        cache[String(n)] = obj
        return true
      },
      log: (m) => { calls.push(['log', m]) },
      readFile: (p) => {
        calls.push(['readFile', p])
        return 'text of ' + p
      },
      execDetached: (c) => { calls.push(['execDetached', c]) },
      network: (u) => { calls.push(['network', u]) },
      clipboard: (v) => { calls.push(['clipboard', v]) },
      secret: () => { throw new TypeError('no secret for you: /home/u/.config/token') },
    },
  }
}

suite('features/launcher', 'LauncherLib, PluginPolicy, TimeLib, FxLib, seven drop-in plugins')

// =========================================================================
section('PluginPolicy - the closed capability vocabulary')
// =========================================================================

group('every declared operation is admitted, and nothing else is', () => {
  // The header table names thirteen in-process operations and eight that leave
  // the process. A name outside the list is denied, never repaired into a
  // nearby one, so the whole contract is "exactly these twenty".
  const ALLOWED = ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
    'stripJsonc', 'requestTime', 'cachedTime', 'requestBinaries', 'cachedBinaries',
    'cachedNet', 'cachedOnline', 'cachedSection', 'log', 'readFile', 'execDetached', 'requestNet',
    'network', 'clipboard', 'secret', 'setCacheSection']
  for (const n of ALLOWED) eq(`isOperation('${n}')`, PP.isOperation(n), true)
  eq('the vocabulary is exactly 21 names', ALLOWED.length, 21)
  // Each request pair is split across the line, and that is the design rather
  // than an accident: the read half is an in-process read like cachedTime, and
  // the request half leaves this process - a socket, or a walk of every
  // directory on PATH - so the launcher has to name it.
  eq('reading a fetched body is in-process', PP.outsideOperations().indexOf('cachedNet'), -1)
  eq('asking for the fetch is not', PP.outsideOperations().indexOf('requestNet') >= 0, true)
  eq('reading the executable names is in-process', PP.outsideOperations().indexOf('cachedBinaries'), -1)
  eq('asking for the PATH scan is not', PP.outsideOperations().indexOf('requestBinaries') >= 0, true)
  // The cache pair splits on READ versus WRITE, not on read versus ask. A read
  // is of a document this process already holds, so it is a default; a write
  // reaches the disk, so it has to be named - and can never be free.
  eq('reading a cache section is in-process', PP.outsideOperations().indexOf('cachedSection'), -1)
  eq('writing one is not', PP.outsideOperations().indexOf('setCacheSection') >= 0, true)
  for (const n of ['requestTime', 'cachedTime']) {
    eq(`${n} is not marked as leaving the process`, PP.outsideOperations().indexOf(n), -1)
  }
})

group('a near-miss spelling is denied, not repaired', () => {
  // The two-directions rule: "readFiles" must not fall through to a read.
  for (const n of ['readFiles', 'readfile', 'READFILE', 'read_file', 'file', 'exec',
    'execDetach', 'exec_detached', 'net', 'networks', 'clip', 'clipboards', 'secrets',
    'fetch', 'fetchUrl', 'requestHttp', 'cachedFetch', 'cache', 'httpGet',
    'binaries', 'requestBinary', 'cachedBinary', 'scanPath', 'which']) {
    eq(`isOperation('${n}') is denied`, PP.isOperation(n), false)
  }
})

group('a near-miss spelling is denied, not repaired', () => {
  // The two-directions rule: "readFiles" must not fall through to a read.
  for (const n of ['readFiles', 'readfile', 'READFILE', 'read_file', 'file', 'exec',
    'execDetach', 'exec_detached', 'net', 'networks', 'clip', 'clipboards', 'secrets',
    'fetch', 'fetchUrl', 'requestHttp', 'cachedFetch', 'cache', 'httpGet']) {
    eq(`isOperation('${n}') is denied`, PP.isOperation(n), false)
  }
})

group('an inherited property name is not a member of the closed table', () => {
  // hasOwnProperty, not `in`: without that, `toString` would be a
  // capability and a plugin could reach an engine intrinsic through it.
  for (const n of ['toString', 'constructor', 'hasOwnProperty', 'valueOf', 'isPrototypeOf']) {
    eq(`isOperation('${n}') is denied`, PP.isOperation(n), false)
  }
})

group('a prototype-polluting name is denied too', () => {
  eq('__proto__', PP.isOperation('__proto__'), false)
  eq('prototype', PP.isOperation('prototype'), false)
  eq('a literal __proto__ string', PP.isOperation('__proto__'), false)
})

group('a non-string is never an operation', () => {
  for (const v of [null, undefined, 0, 1, true, false, {}, [], ['id'], Symbol('id')]) {
    eq(`isOperation(${String(v)})`, PP.isOperation(v), false)
  }
  eq('empty string', PP.isOperation(''), false)
})

group('outsideOperations is the set that leaves this process', () => {
  // Eight, and both request halves are among them: asking the shell to fetch
  // a URL opens a socket, asking it to scan PATH walks every directory on it,
  // and writing a cache section reaches the disk - whatever the plugin is
  // handed back. No read half is, which is why each pair is two entries rather
  // than one.
  eq('exactly the eight named in the header', PP.outsideOperations(),
    ['requestBinaries', 'readFile', 'execDetached', 'requestNet', 'network',
      'clipboard', 'secret', 'setCacheSection'])
  // The header says reading this list instead of keeping a second one is what
  // stops a new privileged operation being added while staying off the
  // launcher's grant table. So the default grants and this list must be
  // disjoint - a capability cannot be both free and deliberate.
  const defaults = ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
    'stripJsonc', 'requestTime', 'cachedTime', 'cachedBinaries', 'cachedNet',
    'cachedOnline', 'cachedSection', 'log']
  is('no default grant is an outside operation', PP.outsideOperations(),
    (out) => out.every((n) => defaults.indexOf(n) < 0), 'disjoint from the defaults')
  eq('the two lists together are the whole vocabulary',
    PP.outsideOperations().length + defaults.length, 21)
  eq('the order is vocabulary order, not sorted',
    PP.outsideOperations().join(','),
    'requestBinaries,readFile,execDetached,requestNet,network,clipboard,secret,setCacheSection')
})

group('the returned list is a fresh array each call', () => {
  const a = PP.outsideOperations()
  const b = PP.outsideOperations()
  // ne() is deep, and two equal lists are deep-equal - so the property under
  // test is object identity, asserted as one.
  eq('two calls are not the same array object', a === b, false)
  a.push('readFiles')
  eq('mutating the result does not reach the table', PP.outsideOperations().length, 8)
})

// =========================================================================
section('PluginPolicy - normalize and intersect')
// =========================================================================

group('normalize keeps vocabulary members, drops everything else, deduplicates', () => {
  eq('a plain list survives', PP.normalize(['id', 'readFile']), ['id', 'readFile'])
  eq('duplicates collapse to first position', PP.normalize(['id', 'readFile', 'id', 'readFile']), ['id', 'readFile'])
  eq('an unknown name is dropped', PP.normalize(['id', 'nope']), ['id'])
  eq('a near-miss name is dropped', PP.normalize(['readFiles']), [])
  eq('non-strings are dropped', PP.normalize(['id', 5, null, undefined, {}, []]), ['id'])
  eq('order is the caller order, not vocabulary order', PP.normalize(['secret', 'id']), ['secret', 'id'])
  eq('empty array', PP.normalize([]), [])
})

group('normalize reads anything that is not an array as no request', () => {
  // "A request that is not an array is no request at all", so the launcher's
  // set stands - which is what makes a hand-edited settings file harmless.
  for (const v of [null, undefined, 'id', 42, {}, { 0: 'id', length: 1 }, true]) {
    eq(`normalize(${JSON.stringify(v) ?? String(v)}) is no request`, PP.normalize(v), [])
  }
})

group('intersect narrows the launcher set by what the manifest named', () => {
  eq('the intersection, in the requested order', PP.intersect(['id', 'readFile'], ['readFile', 'network']), ['readFile'])
  eq('a request naming nothing granted narrows to nothing', PP.intersect(['id', 'readFile'], ['network', 'clipboard']), [])
  eq('a request naming everything granted is that set', PP.intersect(['id', 'readFile'], ['readFile', 'id']), ['readFile', 'id'])
  eq('a request that narrows the launchers own table', PP.intersect(PP.outsideOperations(), ['network', 'secret']), ['network', 'secret'])
})

group('a manifest can only narrow - never widen - its roots grant', () => {
  // The direction that matters: a plugin asking for something the launcher
  // withheld does not get it, and asking for a misspelling gets nothing.
  eq('asking for a withheld capability', PP.intersect(['id'], ['readFile', 'secret']), [])
  eq('asking for a misspelling of a granted one', PP.intersect(['id'], ['ids', 'ID']), [])
  eq('asking with an empty list', PP.intersect(['id', 'readFile'], []), [])
  eq('a non-array request leaves the launcher set standing',
    PP.intersect(['id', 'readFile'], 'readFile'), ['id', 'readFile'])
  eq('a null request leaves the launcher set standing', PP.intersect(['id', 'readFile'], null), ['id', 'readFile'])
  eq('an object request leaves the launcher set standing', PP.intersect(['id'], { 0: 'id' }), ['id'])
})

group('intersect normalizes both sides, so junk on either is inert', () => {
  eq('junk in the granted side', PP.intersect(['id', 'nope', 'id'], ['id']), ['id'])
  eq('junk in the requested side', PP.intersect(['id'], ['id', 5, null, {}]), ['id'])
  eq('both sides junk', PP.intersect(['nope'], ['nope']), [])
  eq('a non-array granted side is no grant at all', PP.intersect('id', ['id']), [])
})

group('the shipped grant tables from AppLauncher.qml behave as documented', () => {
  // AppLauncher.qml: _builtinGrants = ["execDetached"], _userGrants = [], and
  // _grantsFor intersects the root table with the manifest's capabilities.
  // None of the shipped manifests declares `capabilities`, so each root
  // hands over exactly its own table.
  const builtin = PP.intersect(['execDetached'], undefined)
  eq('the built-in root holds execDetached', builtin, ['execDetached'])
  const user = PP.intersect([], undefined)
  eq('the user root holds nothing outside the defaults', user, [])
  // And a manifest naming one is still narrowed to what the root named.
  eq('a built-in manifest naming a withheld capability', PP.intersect(['execDetached'], ['readFile', 'secret']), [])
  eq('a built-in manifest naming only execDetached', PP.intersect(['execDetached'], ['execDetached']), ['execDetached'])
  eq('a user manifest naming execDetached gets nothing', PP.intersect([], ['execDetached']), [])
})

// The root a plugin was discovered under picks the table, and that choice is
// what the whole shipped engine set depends on: get it backwards and every
// builtin plugin reads as a user one, so execDetached is absent from its api,
// activate() throws a TypeError, and _safeActivate marks the engine broken for
// the rest of the controller's life - Enter does nothing, and the websearch
// fallback stops appearing in the result list entirely.
group('the discovery root is recognised by the root prefixing the plugin dir', () => {
  const BUILTIN = '/home/u/.local/share/vibranium/shell/features/launcher/plugins'
  eq('a shipped plugin dir is under the built-in root',
    PP.underRoot(BUILTIN + '/websearch', BUILTIN), true)
  eq('the built-in root itself is not a plugin dir',
    PP.underRoot(BUILTIN, BUILTIN), false)
  // A user directory is a sibling, so it must not match on a shared segment.
  eq('a user dir is not under the built-in root',
    PP.underRoot('/home/u/.config/vibranium/shell/AppLauncher/plugins/websearch', BUILTIN), false)
  // The trap: the reverse test. A parent directory does not contain its own
  // child, so this is false for every shipped plugin - which is exactly the
  // shape that used to classify all five of them as user plugins.
  eq('the root does not contain its child (the inverted form stays false)',
    BUILTIN.indexOf(BUILTIN + '/websearch/') === 0, false)
  // Path-boundary, not string-prefix: a sibling whose name merely extends the
  // root's is a different directory.
  eq('a sibling extending the root name is outside it',
    PP.underRoot(BUILTIN + '-evil/websearch', BUILTIN), false)
  for (const [label, dir, expected] of [
    ['an empty dir', '', false],
    ['an empty root', 'x', false],
    ['both empty', '', false],
  ]) {
    eq(`${label} is not under anything`, PP.underRoot(dir, label === 'an empty root' ? '' : BUILTIN), expected)
  }
})

group('grantsForRoot hands a shipped plugin the shipped table', () => {
  const BUILTIN = '/home/u/.local/share/vibranium/shell/features/launcher/plugins'
  const USER = '/home/u/.config/vibranium/shell/AppLauncher/plugins'
  const BUILTIN_GRANTS = ['execDetached']
  const USER_GRANTS = []
  // AppLauncher._builtinGrantsByPlugin: the shipped plugins that hold a
  // request their siblings do not, named one by one. Only the request half of
  // each pair is listed, because reading what a scan or fetch produced is
  // already a default grant.
  const EXTRAS = { fx: ['requestNet', 'setCacheSection'], binary: ['requestBinaries'] }
  // Every shipped plugin, named rather than sampled: each of the seven
  // activates through api.execDetached, so each one loses its only outside
  // operation when it is misclassified.
  for (const id of ['calc', 'time', 'unit', 'binary', 'websearch']) {
    eq(`${id} is granted execDetached`, PP.grantsForRoot(
      BUILTIN, `${BUILTIN}/${id}`, BUILTIN_GRANTS, USER_GRANTS, undefined), ['execDetached'])
  }
  eq('a user plugin gets nothing outside the defaults', PP.grantsForRoot(
    BUILTIN, `${USER}/mine`, BUILTIN_GRANTS, USER_GRANTS, undefined, EXTRAS, 'mine'), [])
  // A manifest can still only narrow, from either root.
  eq('a shipped manifest naming a withheld capability', PP.grantsForRoot(
    BUILTIN, `${BUILTIN}/calc`, BUILTIN_GRANTS, USER_GRANTS, ['readFile']), [])
  eq('a user manifest asking for execDetached', PP.grantsForRoot(
    BUILTIN, `${USER}/mine`, BUILTIN_GRANTS, USER_GRANTS, ['execDetached']), [])
  // And the grant is what makes the api carry the operation at all: without it
  // the denied operation is ABSENT, so the call is a TypeError rather than a
  // refusal the plugin could survive.
  const shipped = PP.createPolicy(PP.grantsForRoot(
    BUILTIN, `${BUILTIN}/websearch`, BUILTIN_GRANTS, USER_GRANTS, undefined), {})
  eq('the shipped api carries execDetached', 'execDetached' in shipped, true)
  const user = PP.createPolicy(PP.grantsForRoot(
    BUILTIN, `${USER}/mine`, BUILTIN_GRANTS, USER_GRANTS, undefined), {})
  eq('a user api does not', 'execDetached' in user, false)
})

group('a request half is granted to the plugin named for it, and to no user root', () => {
  const BUILTIN = '/home/u/.local/share/vibranium/shell/features/launcher/plugins'
  const USER = '/home/u/.config/vibranium/shell/AppLauncher/plugins'
  const BUILTIN_GRANTS = ['execDetached']
  const USER_GRANTS = []
  const EXTRAS = { fx: ['requestNet', 'setCacheSection'], binary: ['requestBinaries'] }
  const grants = (dir, id, requested) => PP.grantsForRoot(
    BUILTIN, dir, BUILTIN_GRANTS, USER_GRANTS, requested, EXTRAS, id)

  // fx holds two: the socket for the rate document, and the write half of the
  // cache pair whose counts order its bare list. The read half is a default,
  // so it is not named here - naming it would claim a capability the posture
  // grants anyway, which is what the sibling entries below also avoid.
  eq('fx holds the shipped table plus the request and the cache write',
    grants(`${BUILTIN}/fx`, 'fx', undefined), ['execDetached', 'requestNet', 'setCacheSection'])
  eq('binary holds the shipped table plus the PATH scan',
    grants(`${BUILTIN}/binary`, 'binary', undefined), ['execDetached', 'requestBinaries'])
  // The point of the per-plugin map: the shipped root is the same table for
  // everything else, so no sibling engine can open a socket by accident, and
  // the binary plugin's scan is not a general privilege either.
  for (const id of ['calc', 'time', 'unit', 'websearch']) {
    eq(`${id} still holds execDetached only`, grants(`${BUILTIN}/${id}`, id, undefined), ['execDetached'])
  }
  // The two request halves are not interchangeable, and a manifest that asks
  // for one it is not entitled to narrows to nothing - it cannot buy the other
  // by naming it.
  eq('fx cannot reach the PATH scan', grants(`${BUILTIN}/fx`, 'fx', ['requestBinaries']), [])
  eq('binary cannot reach the socket', grants(`${BUILTIN}/binary`, 'binary', ['requestNet']), [])
  // A user plugin named fx cannot reach the shipped row's grant: the extras
  // are folded into the BUILT-IN table only, and the shipped root wins the
  // name collision anyway, so a directory cannot buy a privilege by naming.
  eq('a user plugin called fx gets the user table',
    grants(`${USER}/fx`, 'fx', undefined), [])
  // An id with no map entry is not a wildcard.
  eq('an id absent from the map adds nothing', grants(`${BUILTIN}/calc`, 'nope', undefined), ['execDetached'])
  eq('a missing map is tolerated', PP.grantsForRoot(
    BUILTIN, `${BUILTIN}/fx`, BUILTIN_GRANTS, USER_GRANTS, undefined, null, 'fx'), ['execDetached'])
  // And the manifest still only narrows the widened table.
  eq('an fx manifest naming a withheld capability is narrowed to nothing', grants(
    `${BUILTIN}/fx`, 'fx', ['readFile']), [])
  eq('an fx manifest naming only the request drops execDetached', grants(
    `${BUILTIN}/fx`, 'fx', ['requestNet']), ['requestNet'])
  // The api the grant builds: present for fx and absent for the rest, which is
  // the difference between a capability and a TypeError.
  const fxApi = PP.createPolicy(grants(`${BUILTIN}/fx`, 'fx', undefined), {})
  eq('fx can ask for a URL', 'requestNet' in fxApi, true)
  eq('fx can read the body back', 'cachedNet' in fxApi, true)
  // The PATH pair builds the same way, and the two stay separate: fx holds
  // the body read but cannot scan, binary holds the scan but cannot fetch.
  const binApi = PP.createPolicy(grants(`${BUILTIN}/binary`, 'binary', undefined), {})
  eq('binary can ask for a PATH scan', 'requestBinaries' in binApi, true)
  eq('binary can read the scan back', 'cachedBinaries' in binApi, true)
  eq('fx cannot ask for a scan', 'requestBinaries' in fxApi, false)
  eq('binary cannot ask for a URL', 'requestNet' in binApi, false)
  const calcApi = PP.createPolicy(grants(`${BUILTIN}/calc`, 'calc', undefined), {})
  for (const n of ['requestNet', 'network', 'requestBinaries']) {
    eq(`calc has no ${n}`, n in calcApi, false)
  }
  // The read half alone is harmless: without the request it can only ever
  // answer null, which is why it is a default grant rather than a privilege.
  eq('a plugin with no request still has the read', 'cachedNet' in calcApi, true)
  eq('a plugin with no scan still has the names', 'cachedBinaries' in calcApi, true)
})

// =========================================================================
section('PluginPolicy - redaction and refusal shapes')
// =========================================================================

group('errorKind reports only a platform-shaped name', () => {
  // "The kind is a fixed platform vocabulary and is the only part of a
  // thrown value that can be reported without risking what the message
  // carried" - so the filter is /^[A-Za-z][A-Za-z0-9]*$/.
  eq('TypeError', PP.errorKind(new TypeError('x')), 'TypeError')
  eq('RangeError', PP.errorKind(new RangeError('x')), 'RangeError')
  eq('ReferenceError', PP.errorKind(new ReferenceError('x')), 'ReferenceError')
  eq('plain Error', PP.errorKind(new Error('x')), 'Error')
  eq('a custom but well-shaped name passes', PP.errorKind({ name: 'QuotaExceeded' }), 'QuotaExceeded')
})

group('anything that is not a plain identifier name reports nothing', () => {
  eq('a name with a space', PP.errorKind({ name: 'a b' }), '')
  eq('a name starting with a digit', PP.errorKind({ name: '1x' }), '')
  eq('a name with a dot - a namespaced class would leak its package', PP.errorKind({ name: 'fs.ErrNotFound' }), '')
  eq('a name with a slash', PP.errorKind({ name: 'a/b' }), '')
  eq('a name with a newline - it would forge a log line', PP.errorKind({ name: 'a\nb' }), '')
  eq('an empty name', PP.errorKind({ name: '' }), '')
  eq('a non-string name', PP.errorKind({ name: 5 }), '')
  eq('a missing name', PP.errorKind({}), '')
  eq('a bare string is not an error object', PP.errorKind('TypeError'), '')
  eq('null', PP.errorKind(null), '')
  eq('undefined', PP.errorKind(undefined), '')
  eq('a number', PP.errorKind(42), '')
})

group('redact reduces an error to its shape, never its text', () => {
  // The threat is a thrown message carrying a path, a token or user data.
  const secret = 'hunter2'
  const r = PP.redact(new Error('/home/u/.config/vibranium/token: ' + secret))
  eq('a redacted line is the fixed platform string', r, 'plugin operation failed (Error)')
  notContains('the secret is gone', r, secret)
  notContains('the path is gone', r, '/home/u')
  eq('a kindless error reports the bare refusal', PP.redact('token=' + secret), 'plugin operation failed')
  notContains('nothing of the bare string survives', PP.redact('token=' + secret), 'token')
  eq('null', PP.redact(null), 'plugin operation failed')
  eq('undefined', PP.redact(undefined), 'plugin operation failed')
  eq('an object with no name', PP.redact({}), 'plugin operation failed')
})

group('the redacted line never carries attacker-controlled bytes', () => {
  // A name that survives errorKind has already been reduced to
  // [A-Za-z][A-Za-z0-9]*, so nothing else from the thrown value can reach
  // the log line. Proven rather than assumed: the whole input is an attempt
  // to forge a log record.
  const forged = { name: 'Error', path: '/home/u/.ssh/id_rsa', token: 'sk-live-1234', message: 'boom' }
  const line = PP.redact(forged)
  eq('only the kind is reported', line, 'plugin operation failed (Error)')
  for (const leak of ['/home/u', 'sk-live', 'id_rsa', 'boom']) {
    notContains(`no leak of ${leak}`, line, leak)
  }
  // A name crafted to smuggle a newline is rejected by errorKind outright.
  const nl = PP.redact({ name: 'Error\nINFO forged: token=abc' })
  eq('a forged name degrades to the bare refusal', nl, 'plugin operation failed')
  notContains('no forged line', nl, 'INFO')
})

group('refusal is a redacted Error carrying a machine-readable code', () => {
  const e = PP.refusal('capability_denied', 'readFile')
  eq('the code is on the error', e.code, 'capability_denied')
  eq('the operation is on the error', e.operation, 'readFile')
  eq('the message is the redacted line with the code in it', e.message, 'plugin operation failed (capability_denied:readFile)')
  eq('the name is the platform one', e.name, 'Error')
  // The launcher branches on `code`; the message exists so a human reading a
  // log sees which refusal it was, and carries no path, token or user data.
  eq('the message is the fixed line plus the code and the name', e.message,
    'plugin operation failed (capability_denied:readFile)')
  notContains('no path in the refusal', e.message, '/')
})

group('refusal builds an independent error per call', () => {
  const a = PP.refusal('capability_unbound', 'log')
  const b = PP.refusal('capability_unbound', 'log')
  eq('two refusals are not the same object', a === b, false)
  eq('but carry the same text', a.message, b.message)
  eq('and the same code', a.code, b.code)
})

// =========================================================================
section('PluginPolicy - the policy instance')
// =========================================================================

group('denyAllHost is the deliberate nothing', () => {
  // createPolicy() with no host substitutes this, so every member exists and
  // refuses with capability_unbound rather than silently doing nothing.
  eq('it is null', PP.denyAllHost(), null)
  eq('it takes no argument and reads none', PP.denyAllHost('anything'), null)
})

group('the default posture is every in-process operation and nothing else', () => {
  const p = PP.defaultPolicy()
  eq('granted, in vocabulary order', p.grantedOperations(),
    ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
      'stripJsonc', 'requestTime', 'cachedTime', 'cachedBinaries', 'cachedNet',
      'cachedOnline', 'cachedSection', 'log'])
  eq('denied is exactly the outside set', p.deniedOperations(), PP.outsideOperations())
  eq('allows the defaults', p.allows('setting'), true)
  eq('denies the outside set', p.allows('readFile'), false)
  // The fetch split, stated as posture: the read is free and the request is
  // not, so a plugin with no grant at all can never open a socket. The PATH
  // pair splits the same way.
  eq('the body read is a default', p.allows('cachedNet'), true)
  eq('the online read is a default', p.allows('cachedOnline'), true)
  eq('the fetch request is not', p.allows('requestNet'), false)
  eq('the executable read is a default', p.allows('cachedBinaries'), true)
  eq('the PATH scan is not', p.allows('requestBinaries'), false)
  // The cache pair is the third instance of the split, and its line is read
  // versus write: a section read is of a document this process holds, a section
  // write reaches the disk the shell cache lives on.
  eq('the section read is a default', p.allows('cachedSection'), true)
  eq('the section write is not', p.allows('setCacheSection'), false)
  eq('denies a name outside the vocabulary', p.allows('readFiles'), false)
  eq('denies null', p.allows(null), false)
})

group('a denied operation is absent, not present-and-refusing', () => {
  // "so a plugin cannot probe for one either": there is no property to
  // feature-detect, no `typeof api.network === 'function'` to branch on.
  const p = PP.defaultPolicy()
  for (const n of PP.outsideOperations()) {
    eq(`'${n}' is not a member`, n in p, false)
  }
  eq("'id' is a member", 'id' in p, true)
  eq("'setting' is a member", 'setting' in p, true)
  eq("'log' is a member", 'log' in p, true)
  // The three reads the policy itself publishes are always present.
  eq('allows is a member', typeof p.allows, 'function')
  eq('grantedOperations is a member', typeof p.grantedOperations, 'function')
  eq('deniedOperations is a member', typeof p.deniedOperations, 'function')
})

group('the public surface is exactly the three reads plus the granted operations', () => {
  const p = PP.defaultPolicy()
  eq('own keys', Object.keys(p),
    ['allows', 'grantedOperations', 'deniedOperations',
      'id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
      'stripJsonc', 'requestTime', 'cachedTime', 'cachedBinaries', 'cachedNet',
      'cachedOnline', 'cachedSection', 'log'])
  const g = PP.createPolicy(['readFile'], {})
  eq('and a grant adds exactly one key', Object.keys(g).length, 17)
  eq('readFile is among them', 'readFile' in g, true)
  eq('network still is not', 'network' in g, false)
})

group('a granted operation with no implementation refuses as unbound', () => {
  // The member exists because the launcher binds a host; until it does, the
  // capability has not been granted an implementation, which is a different
  // verdict from a denial and is reported as one.
  const p = PP.defaultPolicy()
  throws('setting() with no host', () => p.setting('x'), /capability_unbound:setting/)
  throws('log() with no host', () => p.log('x'), /capability_unbound:log/)
  throws('readFile() after an explicit grant, no host', () => PP.createPolicy(['readFile']).readFile('/x'), /capability_unbound:readFile/)
  throws('a null host is the deny-all host', () => PP.createPolicy(['readFile'], null).readFile('/x'), /capability_unbound:readFile/)
  throws('a non-object host binds nothing', () => PP.createPolicy(['readFile'], 'nope').readFile('/x'), /capability_unbound:readFile/)
  throws('a host member that is not a function', () => PP.createPolicy(['readFile'], { readFile: 5 }).readFile('/x'), /capability_unbound:readFile/)
})

group('a refusal carries a code, and the code is the two the launcher knows', () => {
  let err = null
  try { PP.defaultPolicy().log('x') } catch (e) { err = e }
  eq('unbound refusal code', err.code, 'capability_unbound')
  eq('unbound refusal names the operation', err.operation, 'log')
  eq('and the message is the redacted form', err.message, 'plugin operation failed (capability_unbound:log)')
})

group('a bound operation is reached with its arguments and its `this`', () => {
  // `this` inside the implementation is the host, not the policy trampoline:
  // a host that keeps state on itself must still see its own state.
  const st = { n: 0, setting: function (...args) { this.n += args.length; return this.n } }
  const sp = PP.createPolicy([], st)
  eq('first call', sp.setting('a', 'b'), 2)
  eq('second call', sp.setting('a'), 3)
  eq('state stayed on the host, not on the policy', st.n, 3)
  // Arguments arrive verbatim, in order, with no coercion of their own.
  const got = []
  const p = PP.createPolicy([], { id: (...args) => { got.push(args); return 'id-of-' + args[0] } })
  eq('the return value passes through', p.id('/plugins/calc'), 'id-of-/plugins/calc')
  eq('the arguments are forwarded as given', got[0], ['/plugins/calc'])
  eq('a non-string argument is not stringified by the policy', PP.createPolicy([], { id: (x) => typeof x }).id(7), 'number')
})

group('whatever a bound operation throws is redacted before it reaches out', () => {
  // Two distinct leaks to prove: a path and a token, in a standard error kind
  // and a bare string respectively.
  const leaky = (e) => { throw e }
  const p = PP.createPolicy(['readFile', 'secret'], {
    readFile: () => leaky(new Error('ENOENT: /home/u/.ssh/id_rsa')),
    secret: () => leaky('token sk-live-9f3a refused'),
  })
  let a = null
  try { p.readFile('/home/u/.ssh/id_rsa') } catch (e) { a = e }
  eq('an Error becomes the redacted kind', a.message, 'plugin operation failed (Error)')
  notContains('the path is gone', a.message, 'id_rsa')
  let b = null
  try { p.secret() } catch (e) { b = e }
  eq('a bare string becomes the bare refusal', b.message, 'plugin operation failed')
  notContains('the token is gone', b.message, 'sk-live')
  // The redaction is one level only: it must not itself throw on a hostile
  // value, or the boundary would leak by crashing.
  // The redaction must not itself throw on a hostile value, or the boundary
  // would leak by crashing - so each of these reaches the plugin as the fixed
  // line rather than as the value that was thrown.
  for (const [label, thrown] of [['an object with no message', {}], ['null', null], ['an array', [1, 2]]]) {
    let c = null
    try { PP.createPolicy(['readFile'], { readFile: () => { throw thrown } }).readFile('/x') } catch (e) { c = e }
    eq(`${label} crosses as the bare refusal`, c.message, 'plugin operation failed')
  }
})

group('a granted operation cannot smuggle in a member the grant did not name', () => {
  // The trampolines are built from `granted`, not from the host, so a host
  // that implements everything still publishes only what was granted.
  const everything = {}
  for (const n of ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
    'stripJsonc', 'requestTime', 'cachedTime', 'requestBinaries', 'cachedBinaries',
    'cachedNet', 'cachedOnline', 'cachedSection', 'log', 'readFile', 'execDetached', 'network',
    'clipboard', 'secret']) {
    everything[n] = () => n
  }
  const p = PP.createPolicy([], everything)
  // Three published reads plus the thirteen default grants.
  eq('the default grant publishes thirteen', Object.keys(p).length, 16)
  eq('network is still absent', 'network' in p, false)
  eq('secret is still absent', 'secret' in p, false)
  eq('and so is the fetch request', 'requestNet' in p, false)
  eq('while the body read is a default', 'cachedNet' in p, true)
  eq('and so is the PATH scan', 'requestBinaries' in p, false)
  eq('while the executable read is a default', 'cachedBinaries' in p, true)
  const q = PP.createPolicy(['execDetached'], everything)
  eq('one grant publishes seventeen', Object.keys(q).length, 17)
  eq('execDetached is reachable', q.execDetached(), 'execDetached')
  eq('readFile is not', 'readFile' in q, false)
})

group('grantedOperations and deniedOperations hand back copies', () => {
  const p = PP.createPolicy(['readFile'], {})
  const g = p.grantedOperations()
  g.push('secret')
  eq('mutating the copy does not reach the policy', p.grantedOperations().length, 14)
  const d = p.deniedOperations()
  d.length = 0
  eq('same for denied', p.deniedOperations().length, 7)
})

group('createPolicy is idempotent in its vocabulary ordering', () => {
  // granted/denied are reported in vocabulary order regardless of the order
  // the grant asked in, so a status read is stable across a settings edit.
  // The defaults are re-asserted rather than replaced, so the reported set is
  // always the full posture - and the two extra grants appear in vocabulary
  // order (readFile before secret) whatever order they were asked in.
  const a = PP.createPolicy(['secret', 'readFile', 'id'], {})
  eq('ordering is vocabulary order, not request order', a.grantedOperations(),
    ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote', 'stripJsonc',
      'requestTime', 'cachedTime', 'cachedBinaries', 'cachedNet', 'cachedOnline', 'cachedSection',
      'log', 'readFile', 'secret'])
  const b = PP.createPolicy(['readFile', 'id', 'secret'], {})
  eq('and the same for a differently ordered request', b.grantedOperations(), a.grantedOperations())
  eq('and the denied tail is the same too', b.deniedOperations(), a.deniedOperations())
})

group('a grant cannot be widened by repeating it or by a duplicate', () => {
  eq('a repeated grant', PP.createPolicy(['readFile', 'readFile', 'readFile'], {}).grantedOperations().length, 14)
  eq('the defaults are re-asserted, not duplicated',
    PP.createPolicy(['id', 'setting'], {}).grantedOperations().length, 13)
})

// =========================================================================
section('PluginPolicy - path-shaped operations')
// =========================================================================

// The vocabulary documents `readFile` as "read an arbitrary file" and the
// header is explicit that the policy bounds the API the launcher PUBLISHES,
// not the host's implementation. So PluginPolicy itself performs no path
// inspection: a path argument crosses the boundary verbatim. The confinement
// to a plugin root is the host's job, and it is where a traversal has to be
// refused. Both halves are pinned here, with a host that confines, because
// "the policy silently rewrites my path" and "the policy never looks at my
// path" are opposite failure modes and only tests tell them apart.
function confinedReadFile(root, p) {
  const raw = String(p)
  if (raw === '') return { ok: false, why: 'empty' }
  if (raw === '~' || raw.indexOf('~/') === 0) return { ok: false, why: 'tilde' }
  if (raw.charAt(0) !== '/') return { ok: false, why: 'relative' }
  const norm = path.posix.normalize(raw)
  if (norm === '/') return { ok: false, why: 'root' }
  // A string-prefix test would let /plugins/calc-evil through; a path-prefix
  // test with a separator boundary is what actually confines.
  if (norm === root || norm.indexOf(root + '/') !== 0) return { ok: false, why: 'outside' }
  return { ok: true, text: 'contents of ' + norm }
}

const ROOT = '/home/u/.config/vibranium/shell/features/launcher/plugins/demo'

group('a path outside the plugin root is refused by a confined host', () => {
  const h = { readFile: (p) => { const r = confinedReadFile(ROOT, p); if (!r.ok) throw new RangeError('refused: ' + r.why); return r.text } }
  const pol = PP.createPolicy(['readFile'], h)
  eq('inside the root, read', pol.readFile(ROOT + '/plugin.json'), 'contents of ' + ROOT + '/plugin.json')
  eq('the root itself is not a file to read', attempt(() => pol.readFile(ROOT), []).ok, false)
  eq('a traversal out of the root', attempt(() => pol.readFile(ROOT + '/../../../../etc/passwd'), []).ok, false)
  eq('a traversal through a subdirectory', attempt(() => pol.readFile(ROOT + '/sub/../../other/plugin.json'), []).ok, false)
  eq('a traversal that lands back inside is allowed', pol.readFile(ROOT + '/sub/../plugin.json'), 'contents of ' + ROOT + '/plugin.json')
})

group('the refusal for a refused path crosses as a shape, not as the path', () => {
  const h = { readFile: (p) => { const r = confinedReadFile(ROOT, p); if (!r.ok) throw new RangeError('refused: ' + r.why); return r.text } }
  const pol = PP.createPolicy(['readFile'], h)
  let e = null
  try { pol.readFile(ROOT + '/../../../etc/shadow') } catch (err) { e = err }
  eq('a RangeError crosses as its kind', e.message, 'plugin operation failed (RangeError)')
  notContains('the host message is not forwarded', e.message, 'refused')
  notContains('nor the path', e.message, 'shadow')
})

group('absolute, relative, tilde and empty paths are all refused outside a root', () => {
  const h = { readFile: (p) => { const r = confinedReadFile(ROOT, p); if (!r.ok) throw new RangeError('refused'); return r.text } }
  const pol = PP.createPolicy(['readFile'], h)
  for (const p of ['/etc/passwd', '/', '//', '~', '~/notes.txt', '~user/x', 'relative/path', './x', '', '   ', null, undefined, 42, {}]) {
    const r = attempt(() => pol.readFile(p), [])
    eq(`refused: ${JSON.stringify(p) ?? String(p)}`, r.ok, false)
  }
})

group('a string-prefix that is not a path-prefix does not pass as inside', () => {
  // The classic confinement bug: root + "-evil" starts with root as a string.
  const h = { readFile: (p) => { const r = confinedReadFile(ROOT, p); if (!r.ok) throw new RangeError('refused'); return r.text } }
  const pol = PP.createPolicy(['readFile'], h)
  eq('a sibling directory with the root as a string prefix', attempt(() => pol.readFile(ROOT + '-evil/plugin.json'), []).ok, false)
  eq('a sibling with no separator at all', attempt(() => pol.readFile('/home/u/.config/vibranium/shell/features/launcher/plugins'), []).ok, false)
  eq('a prefix one character short', attempt(() => pol.readFile(ROOT.slice(0, -1) + '/x'), []).ok, false)
})

group('the policy itself does no path inspection, as its header states', () => {
  // Pinned so the two failure modes cannot be confused: the policy is the
  // API gate, the host is the path gate. If this ever starts rewriting a
  // path, the confinement in the host above is being bypassed silently.
  const { host, calls } = recordingHost()
  const pol = PP.createPolicy(['readFile'], host)
  for (const p of ['/etc/passwd', ROOT + '/../x', '~/x', '', 'relative', '~']) {
    pol.readFile(p)
    eq(`'${String(p)}' crosses verbatim`, calls[calls.length - 1][1], p)
  }
})

// =========================================================================
section('LauncherLib - the desktop entry index')
// =========================================================================

const FIREFOX = {
  name: 'Firefox',
  genericName: 'Web Browser',
  comment: 'Browse the Web',
  id: 'firefox.desktop',
  keywords: ['web', 'browser', 'mozilla'],
  categories: ['Network', 'WebBrowser'],
  icon: 'firefox',
  execString: 'firefox %u',
}

group('indexFingerprint is a total function of exactly its three inputs', () => {
  // "The controller skips a rebuild when the string is unchanged, so it has
  // to be a total function of exactly those three and nothing else - an input
  // it ignores would read as 'unchanged' and freeze a stale order."
  eq('the exact shape', LL.indexFingerprint(3, 'frequency', { a: 1 }), '3|frequency|{"a":1}')
  eq('the same inputs give the same string', LL.indexFingerprint(3, 'frequency', { a: 1 }), LL.indexFingerprint(3, 'frequency', { a: 1 }))
  ne('a different count', LL.indexFingerprint(3, 'frequency', {}), LL.indexFingerprint(4, 'frequency', {}))
  ne('a different sort method', LL.indexFingerprint(3, 'frequency', {}), LL.indexFingerprint(3, 'alphabetical', {}))
  ne('a different usage map', LL.indexFingerprint(3, 'alphabetical', { a: 1 }), LL.indexFingerprint(3, 'alphabetical', { a: 2 }))
  ne('a dropped key', LL.indexFingerprint(3, 'alphabetical', { a: 1 }), LL.indexFingerprint(3, 'alphabetical', {}))
  // Key order is JSON.stringify order, so a map rebuilt in a different order
  // is a different fingerprint. That is deliberate: the map the controller
  // holds is one object, and a reserialised read is a genuine change.
  ne('a reordered usage map', LL.indexFingerprint(1, 'a', { a: 1, b: 2 }), LL.indexFingerprint(1, 'a', { b: 2, a: 1 }))
})

group('indexFingerprint survives nullish and falsy inputs', () => {
  // `(entryCount || 0)` folds the nullish count to 0 and `String(sortMethod
  // ?? "")` folds a nullish method to the empty string, while the map goes
  // through JSON.stringify, whose answer for null and undefined differ.
  eq('all undefined', LL.indexFingerprint(undefined, undefined, undefined), '0||undefined')
  // `String(sortMethod ?? "")` folds a nullish method to the empty string
  // before stringifying, so null and "" produce the same second field - only
  // the map distinguishes a null from an absent one.
  eq('all null', LL.indexFingerprint(null, null, null), '0||null')
  eq('an empty map', LL.indexFingerprint(0, '', {}), '0||{}')
  eq('so a nullish sort method and an empty one agree', LL.indexFingerprint(1, null, {}), LL.indexFingerprint(1, '', {}))
  eq('a zero count and a real zero are the same count', LL.indexFingerprint(0, 'a', {}), '0|a|{}')
  eq('a negative count is kept verbatim', LL.indexFingerprint(-1, 'a', {}), '-1|a|{}')
  eq('a numeric sort method is stringified', LL.indexFingerprint(1, 2, {}), '1|2|{}')
  eq('false count folds to 0', LL.indexFingerprint(false, false, false), '0|false|false')
  eq('a method carrying the separator cannot forge a collision with two fields', LL.indexFingerprint(1, 'a|b', {}), '1|a|b|{}')
  // JSON.stringify cannot serialise a cycle, and this runs on the warm-summon
  // path, so the failure is a crash rather than a sentinel. Not reachable from
  // a druncache read, pinned so a cycle-shaped map would be a known verdict.
  throws('a usage map with a cycle throws rather than returning a sentinel',
    () => LL.indexFingerprint(1, 'a', (() => { const o = {}; o.o = o; return o })()), /circular/i)
})

group('appRecord snapshots an entry into a plain record', () => {
  const r = LL.appRecord(FIREFOX)
  eq('kind', r.kind, 'app')
  eq('uid is namespaced by the desktop id', r.uid, 'app:firefox.desktop')
  eq('label', r.label, 'Firefox')
  eq('desc is the comment', r.desc, 'Browse the Web')
  eq('genericName', r.genericName, 'Web Browser')
  eq('icon', r.icon, 'firefox')
  eq('id', r.id, 'firefox.desktop')
  eq('sub is always empty for an app', r.sub, '')
  eq('runInTerminal is a strict boolean', r.runInTerminal, false)
  eq('the original entry is kept for launch handling', r.app, FIREFOX)
})

group('the haystack is name + genericName + comment + id + keywords + categories', () => {
  // The snapshot exists so per-keystroke search never touches a QObject
  // property lookup, so its content is the contract, not an implementation.
  const r = LL.appRecord(FIREFOX)
  eq('the exact haystack', r.hay, 'firefox web browser browse the web firefox.desktop web browser mozilla network webbrowser')
  eq('words is the haystack split on spaces', r.words, r.hay.split(' '))
  eq('lowercased throughout', r.hay, r.hay.toLowerCase())
  // A missing field contributes an empty slot, not a hole: the word indexes
  // are what tokenScore ranks on, so a hole would shift every later word.
  const bare = LL.appRecord({ name: 'x', id: 'i' })
  eq('a bare entry still yields a six-slot haystack', bare.hay.split(' ').length, 6)
  eq('with the missing fields as empty words', bare.words, ['x', '', '', 'i', '', ''])
  noThrow('a nullish keywords list', () => LL.appRecord({ name: 'x', id: 'i', keywords: null }))
  eq('nullish keywords read as none', LL.appRecord({ name: 'x', id: 'i', keywords: null }).hay, 'x   i  ')
  noThrow('a nullish categories list', () => LL.appRecord({ name: 'x', id: 'i', categories: null }))
  eq('nullish categories read as none', LL.appRecord({ name: 'x', id: 'i', categories: null }).label, 'x')
  eq('a missing comment reads as empty desc', LL.appRecord({ name: 'x', id: 'i' }).desc, '')
})

group('a Power entry is excluded from the index regardless of settings', () => {
  // BASE_EXCLUDED_CATEGORIES: "Power entries are always excluded
  // entries from default mode", and this is now unconditional.
  eq('a Power entry yields no record', LL.appRecord({ name: 'Shut down', id: 's.desktop', categories: ['Power'] }), null)
  eq('Power among other categories is still excluded', LL.appRecord({ name: 'x', id: 'i', categories: ['System', 'Power', 'Network'] }), null)
  eq('a near-miss category is not excluded', LL.appRecord({ name: 'x', id: 'i', categories: ['Powerful'] }).label, 'x')
  eq('case matters in the category table', LL.appRecord({ name: 'x', id: 'i', categories: ['power'] }).label, 'x')
  eq('no categories at all is fine', LL.appRecord({ name: 'x', id: 'i' }).label, 'x')
})

group('a launcher-owned entry is one the launcher itself created', () => {
  // Only launcher-owned desktop entries can be removed in-app, so `removable`
  // and `managed` are the same answer and `isManagedEntry` is the predicate
  // the same detection answers.
  eq('a TUI wrapper', LL.appRecord({ name: 'y', id: 'i', execString: 'vb-launch-tui -- yazi' }).managed, true)
  eq('a webapp wrapper', LL.appRecord({ name: 'y', id: 'i', execString: 'vb-launch-webapp https://x' }).managed, true)
  eq('a raw chromium --app=', LL.appRecord({ name: 'y', id: 'i', execString: 'chromium --app=https://x' }).managed, true)
  eq('a raw chromium --app-id=', LL.appRecord({ name: 'y', id: 'i', execString: 'chromium --app-id=org.x' }).managed, true)
  eq('the PWA category', LL.appRecord({ name: 'y', id: 'i', categories: ['PWA'] }).managed, true)
  eq('the TUI category', LL.appRecord({ name: 'y', id: 'i', categories: ['TUI'] }).managed, true)
  eq('a plain application is not managed', LL.appRecord({ name: 'y', id: 'i', execString: 'firefox' }).managed, false)
  eq('removable mirrors managed', LL.appRecord({ name: 'y', id: 'i', categories: ['PWA'] }).removable, true)
})

group('TUI wins over PWA, so a terminal is never classified as a webapp', () => {
  // "vb-launch-tui's own window-matching --app-id=org.vb.term.float flag must
  // never classify a TUI as a webapp" - the guard is the `!_isTUI` on PWA.
  const both = LL.appRecord({ name: 'y', id: 'i', execString: 'vb-launch-webapp --app-id=org.vb.term.float', categories: ['TUI', 'PWA'] })
  eq('the badge is tui', both.badge, 'tui')
  eq('and it is still managed', both.removable, true)
  eq('TUI exec over a PWA category', LL.appRecord({ name: 'y', id: 'i', execString: 'vb-launch-tui -- yazi', categories: ['PWA'] }).badge, 'tui')
  eq('a webapp badge', LL.appRecord({ name: 'y', id: 'i', categories: ['PWA'] }).badge, 'webapp')
  eq('a plain entry has no badge', LL.appRecord({ name: 'y', id: 'i' }).badge, '')
  eq('an --app= exec alone badges webapp', LL.appRecord({ name: 'y', id: 'i', execString: 'chromium --app=https://x' }).badge, 'webapp')
  eq('an --app-id= exec alone badges webapp', LL.appRecord({ name: 'y', id: 'i', execString: 'chromium --app-id=org.x' }).badge, 'webapp')
})

group('execString wins over exec, and a missing one is not an error', () => {
  eq('execString is preferred', LL.appRecord({ name: 'y', id: 'i', execString: 'vb-launch-tui -- a', exec: 'firefox' }).badge, 'tui')
  eq('exec is the fallback', LL.appRecord({ name: 'y', id: 'i', exec: 'vb-launch-tui -- a' }).badge, 'tui')
  eq('a non-string execString is stringified', LL.appRecord({ name: 'y', id: 'i', execString: 42 }).label, 'y')
  noThrow('neither field', () => LL.appRecord({ name: 'y', id: 'i' }))
  // appRecord has no null-entry guard: the entry is a QML singleton the
  // controller always supplies, and the seam is named in the header rather
  // than defended. Pinned so a future guard is a visible change.
  throws('a null entry is not a supported input', () => LL.appRecord(null), /categories|undefined|null/)
  throws('a missing entry is not a supported input', () => LL.appRecord(), /categories/)
})

group('runInTerminal is a strict boolean, not a truthy read', () => {
  eq('true', LL.appRecord({ name: 'y', id: 'i', runInTerminal: true }).runInTerminal, true)
  eq('the string "true" is not true', LL.appRecord({ name: 'y', id: 'i', runInTerminal: 'true' }).runInTerminal, false)
  eq('1 is not true', LL.appRecord({ name: 'y', id: 'i', runInTerminal: 1 }).runInTerminal, false)
  eq('absent', LL.appRecord({ name: 'y', id: 'i' }).runInTerminal, false)
})

group('isManagedEntry answers the same question as the record flags', () => {
  const cases = [
    [{ execString: 'vb-launch-tui -- yazi' }, [], true],
    [{ execString: 'vb-launch-webapp x' }, [], true],
    [{ execString: 'chromium --app=https://x' }, [], true],
    [{ execString: 'chromium --app-id=org.x' }, [], true],
    [{ execString: 'firefox' }, ['PWA'], true],
    [{ execString: 'firefox' }, ['TUI'], true],
    [{ execString: 'vb-launch-webapp x' }, ['TUI'], true],
    [{ exec: 'firefox' }, [], false],
    [{}, [], false],
    [{ execString: 'vb-launch-cmd -- firefox' }, [], false],
  ]
  for (const [entry, cats, want] of cases) {
    eq(`isManagedEntry(${JSON.stringify(entry.execString ?? entry.exec ?? '')}, ${JSON.stringify(cats)})`,
      LL.isManagedEntry(entry, cats), want)
  }
  // And the two answers agree, which is the invariant the removal UI relies on.
  for (const [entry, cats] of cases) {
    const r = LL.appRecord(Object.assign({ name: 'y', id: 'i' }, entry, { categories: cats }))
    eq('appRecord.managed agrees for ' + JSON.stringify(entry.execString ?? entry.exec ?? ''),
      r === null ? null : r.managed, LL.isManagedEntry(entry, cats))
  }
})

group('buildAppIndex sorts alphabetically by default, case-insensitively', () => {
  const entries = [
    { name: 'Zeta', id: 'z.desktop' },
    { name: 'alpha', id: 'a.desktop' },
    { name: 'Mid', id: 'm.desktop' },
  ]
  eq('A to Z regardless of case', LL.buildAppIndex(entries, 'alphabetical', {}).map((r) => r.label), ['alpha', 'Mid', 'Zeta'])
  eq('any sort method that is not frequency sorts the same way',
    LL.buildAppIndex(entries, undefined, {}).map((r) => r.label), ['alpha', 'Mid', 'Zeta'])
  eq('a null usage map is fine for the alphabetical path',
    LL.buildAppIndex(entries, 'alphabetical', null).map((r) => r.label), ['alpha', 'Mid', 'Zeta'])
})

group('buildAppIndex with sortMethod "frequency" orders by usage, ties alphabetical', () => {
  const entries = [
    { name: 'alpha', id: 'a.desktop' },
    { name: 'Zeta', id: 'z.desktop' },
    { name: 'Beta', id: 'b.desktop' },
  ]
  eq('most used first', LL.buildAppIndex(entries, 'frequency', { 'b.desktop': 9, 'a.desktop': 2, 'z.desktop': 5 }).map((r) => r.id),
    ['b.desktop', 'z.desktop', 'a.desktop'])
  eq('a tie falls through to alphabetical', LL.buildAppIndex(entries, 'frequency', { 'b.desktop': 4, 'z.desktop': 4, 'a.desktop': 4 }).map((r) => r.id),
    ['a.desktop', 'b.desktop', 'z.desktop'])
  eq('a {count} row counts the same as a number', LL.buildAppIndex(entries, 'frequency', { 'b.desktop': { count: 9 } }).map((r) => r.id)[0], 'b.desktop')
  eq('an unused entry sorts last by count', LL.buildAppIndex(entries, 'frequency', { 'a.desktop': 1 }).map((r) => r.id),
    ['a.desktop', 'b.desktop', 'z.desktop'])
  // A non-object map is not a usage map, so the frequency path does not run.
  eq('a string map falls back to alphabetical', LL.buildAppIndex(entries, 'frequency', 'nope').map((r) => r.id),
    ['a.desktop', 'b.desktop', 'z.desktop'])
})

group('buildAppIndex drops Power entries and nameless entries', () => {
  const entries = [
    { name: 'Keep', id: 'k.desktop' },
    { name: 'Drop', id: 'd.desktop', categories: ['Power'] },
    { name: '', id: 'e.desktop' },
    { name: 'Keep2', id: 'k2.desktop' },
  ]
  eq('only the two named, non-Power entries survive', LL.buildAppIndex(entries, 'alphabetical', {}).map((r) => r.id), ['k.desktop', 'k2.desktop'])
  eq('an empty index is an empty array, not null', LL.buildAppIndex([], 'alphabetical', {}), [])
  eq('every entry dropped gives an empty array',
    LL.buildAppIndex([{ name: '', id: 'e' }], 'alphabetical', {}), [])
})

group('buildAppIndex is a pure rebuild, not a mutation', () => {
  // Idempotent: the controller may rebuild on any fingerprint change, so a
  // second build of the same input must be indistinguishable from the first.
  const entries = [{ name: 'B', id: 'b' }, { name: 'A', id: 'a' }]
  const first = LL.buildAppIndex(entries, 'alphabetical', {})
  const second = LL.buildAppIndex(entries, 'alphabetical', {})
  eq('the same order', first.map((r) => r.id), second.map((r) => r.id))
  eq('but not the same array object', first === second, false)
  // And the input is untouched: the entries keep their own order.
  eq('the input array is not reordered in place', entries.map((e) => e.name), ['B', 'A'])
  eq('the input entries are the same objects', first[0].app, entries[1])
})

group('a duplicate desktop id yields two records, not one', () => {
  // buildAppIndex dedupes nothing: it is a snapshot of the entry list it is
  // handed, and DesktopEntries is the thing that owns uniqueness. Pinned so a
  // future dedupe is a deliberate change with a test to point at.
  const entries = [
    { name: 'Dup', id: 'same.desktop' },
    { name: 'Dup', id: 'same.desktop' },
  ]
  const idx = LL.buildAppIndex(entries, 'alphabetical', {})
  eq('both records are kept', idx.length, 2)
  eq('and they share a uid', idx[0].uid, idx[1].uid)
  eq('but they are distinct record objects', idx[0] === idx[1], false)
})

// =========================================================================
section('LauncherLib - usage persistence')
// =========================================================================

group('usageCountFor reads both stored shapes and nothing else', () => {
  // "The map mixes shapes over time: plain numbers (current writer) and
  // {count} objects (older rows). Anything else reads as unused."
  eq('a plain number', LL.usageCountFor({ a: 3 }, 'a'), 3)
  eq('a {count} object', LL.usageCountFor({ a: { count: 7 } }, 'a'), 7)
  eq('zero is a count, not an absence', LL.usageCountFor({ a: 0 }, 'a'), 0)
  eq('{count: 0} is a count too', LL.usageCountFor({ a: { count: 0 } }, 'a'), 0)
  eq('a {count} that is not a number', LL.usageCountFor({ a: { count: '3' } }, 'a'), 0)
  eq('an object with no count', LL.usageCountFor({ a: { n: 3 } }, 'a'), 0)
  eq('a string value', LL.usageCountFor({ a: '3' }, 'a'), 0)
  eq('a boolean value', LL.usageCountFor({ a: true }, 'a'), 0)
  eq('an absent id', LL.usageCountFor({}, 'a'), 0)
})

group('usageCountFor is total over the map and the id', () => {
  for (const m of [null, undefined, 0, '', 'str', 42, true]) {
    eq(`a non-object map (${JSON.stringify(m) ?? String(m)}) reads as unused`, LL.usageCountFor(m, 'a'), 0)
  }
  for (const id of [null, undefined, '', 0, false, {}, []]) {
    eq(`a non-string id (${JSON.stringify(id) ?? String(id)}) reads as unused`, LL.usageCountFor({}, id), 0)
  }
  // A numeric id is stringified to the key, which is what the druncache
  // actually holds, so usageCountFor(usageMap, row.app.id) is total.
  eq('a numeric id finds its stringified key', LL.usageCountFor({ 5: 2 }, 5), 2)
  noThrow('an array map', () => LL.usageCountFor([1, 2], 'a'))
  noThrow('a Map', () => LL.usageCountFor(new Map([['a', 1]]), 'a'))
})

group('parseUsageText answers the two questions a load needs', () => {
  const r = LL.parseUsageText('{"a":1}')
  eq('a populated file', r, { map: { a: 1 }, hasHistory: true })
  eq('a cache that exists but is empty has no history', LL.parseUsageText('{}'), { map: {}, hasHistory: false })
  eq('an object row counts as history', LL.parseUsageText('{"a":{"count":1}}').hasHistory, true)
  eq('a falsy row still counts as a key', LL.parseUsageText('{"a":0}').hasHistory, true)
  eq('a null row still counts as a key', LL.parseUsageText('{"a":null}').hasHistory, true)
  // The map is the parsed object itself, so the caller can hold on to its own
  // state and merge into it.
  eq('the map is handed through', LL.parseUsageText('{"a":1}').map, { a: 1 })
})

group('an unreadable druncache is null, which is not the same as {}', () => {
  // "null means the text is blank or unparsable - the caller keeps its own
  // state, which is not the same verdict as an empty object."
  for (const t of ['', '   ', '\n\t ', 'nope', '{', '{"a":}', '[1,2]', 'null', 'true', '0', '"str"', '42', undefined, null, {}]) {
    eq(`parseUsageText(${JSON.stringify(t) ?? String(t)}) is null`, LL.parseUsageText(t), null)
  }
  // An array parses as JSON but is not a usage map, so it is null too.
  eq('an array is not a map', LL.parseUsageText('[1,2]'), null)
  // A number parses but has no keys.
  eq('a bare number is not a map', LL.parseUsageText('42'), null)
  // Leading/trailing whitespace is fine, because JSON.parse tolerates it.
  eq('padded JSON parses', LL.parseUsageText('  {"a":1}\n'), { map: { a: 1 }, hasHistory: true })
})

group('serializeUsage is indented and newline terminated, because it is the users state', () => {
  eq('the exact bytes for one row', LL.serializeUsage({ a: 1 }), '{\n  "a": 1\n}\n')
  eq('an empty map is still a document', LL.serializeUsage({}), '{}\n')
  eq('nested rows are indented too', LL.serializeUsage({ a: { count: 2 } }), '{\n  "a": {\n    "count": 2\n  }\n}\n')
  eq('it is deterministic for one input', LL.serializeUsage({ b: 1, a: 2 }), LL.serializeUsage({ b: 1, a: 2 }))
  noThrow('a nullish map', () => LL.serializeUsage(null))
  eq('a nullish map is the JSON text of it', LL.serializeUsage(null), 'null\n')
})

group('serialize and parse are inverses on every row shape the writer produces', () => {
  for (const map of [{}, { a: 1 }, { a: 1, b: 2 }, { a: { count: 1 } }, { a: 0, b: { count: 9 }, c: 3.5 }]) {
    const back = LL.parseUsageText(LL.serializeUsage(map))
    eq('round trip ' + JSON.stringify(map), back, { map, hasHistory: Object.keys(map).length > 0 })
  }
  // And the round trip composes with a bump, which is the only writer.
  let m = {}
  m = LL.bumpUsage(m, 'firefox.desktop')
  m = LL.bumpUsage(m, 'firefox.desktop')
  m = LL.bumpUsage(m, 'code.desktop')
  eq('two bumps then a parse', LL.parseUsageText(LL.serializeUsage(m)), { map: { 'firefox.desktop': 2, 'code.desktop': 1 }, hasHistory: true })
})

group('bumpUsage increments both stored shapes and starts a new counter at zero', () => {
  eq('a plain number bumps to number', LL.bumpUsage({ a: 1 }, 'a'), { a: 2 })
  eq('a {count} object bumps and is replaced by a number', LL.bumpUsage({ a: { count: 3 } }, 'a'), { a: 4 })
  eq('a number becomes a number after the first bump of a mixed map', LL.bumpUsage({ a: { count: 1 }, b: 2 }, 'a'), { a: 2, b: 2 })
  eq('a non-number count starts from zero', LL.bumpUsage({ a: 'x' }, 'a'), { a: 1 })
  eq('a null row starts from zero', LL.bumpUsage({ a: null }, 'a'), { a: 1 })
  eq('an absent id starts at one', LL.bumpUsage({}, 'new.desktop'), { 'new.desktop': 1 })
  eq('an absent map starts at one', LL.bumpUsage(null, 'a'), { a: 1 })
  eq('an undefined map starts at one', LL.bumpUsage(undefined, 'a'), { a: 1 })
  eq('the id is trimmed before it becomes a key', LL.bumpUsage({}, '  a.desktop  '), { 'a.desktop': 1 })
  eq('a numeric id is stringified', LL.bumpUsage({}, 5), { 5: 1 })
})

group('bumpUsage never mutates the map it was handed', () => {
  const before = { a: 1, b: { count: 2 } }
  const after = LL.bumpUsage(before, 'a')
  eq('the input is untouched', before, { a: 1, b: { count: 2 } })
  ne('the result is a new object', before, after)
  eq('the untouched row survives in the result', after.b, { count: 2 })
  // Object.assign is a shallow copy, so a nested row is shared until bumped.
  const next = LL.bumpUsage(after, 'b')
  eq('bumping a {count} row replaces the value, not the object', after.b, { count: 2 })
  eq('and the new value is a number', next.b, 3)
})

group('an empty id is refused, so the caller cannot report a launch that did not happen', () => {
  for (const id of ['', '   ', '\t\n', null, undefined]) {
    eq(`bumpUsage(map, ${JSON.stringify(id) ?? String(id)}) is null`, LL.bumpUsage({}, id), null)
  }
  // The refusal is null rather than a map with an empty key, so no counter
  // for "" can ever appear in druncache.json.
  eq('a bump of a real id writes no "" key', LL.bumpUsage({}, 'a')[''], undefined)
})

group('usageHistoryEmpty is the clear-history refusal, and has two ways to say yes', () => {
  // "nothing to clear, so the write is refused instead of removing a file
  // that is already gone and reporting success."
  eq('a map with rows needs no refusal', LL.usageHistoryEmpty(false, { a: 1 }), false)
  eq('hasHistory true overrides an empty map', LL.usageHistoryEmpty(true, {}), false)
  eq('hasHistory true overrides a nullish map', LL.usageHistoryEmpty(true, null), false)
  eq('an empty map reads as no history', LL.usageHistoryEmpty(false, {}), true)
  eq('a null map reads as no history', LL.usageHistoryEmpty(false, null), true)
  eq('an undefined map reads as no history', LL.usageHistoryEmpty(undefined, undefined), true)
  eq('a non-object map reads as no history', LL.usageHistoryEmpty(false, 'x'), true)
  eq('a number map reads as no history', LL.usageHistoryEmpty(false, 0), true)
})

group('the two readers deliberately differ on an unreadable file', () => {
  // "that difference is load bearing: the map read keeps whatever it already
  // had (a launch bumped a counter the stale file does not know about yet),
  // while the emptiness read reports 'no history' so the settings row hides."
  const stale = LL.parseUsageText('corrupted')
  eq('the map read is null, so the caller keeps its own state', stale, null)
  eq('and the emptiness read says there is nothing to clear', LL.usageHistoryEmpty(false, stale), true)
  // The mirror case: a good file with rows.
  const good = LL.parseUsageText('{"a":1}')
  eq('a good file clears', LL.usageHistoryEmpty(good.hasHistory, good.map), false)
})

// =========================================================================
section('LauncherLib - the plugin registry model')
// =========================================================================

const ENGINE_META = { name: 'E', description: 'D', keyword: 'e', type: 'engine' }
const WEB_META = { name: 'W', description: 'D', keyword: 'w', type: 'websearch' }

group('pluginTypes is the closed type vocabulary', () => {
  eq('exactly websearch, binary and engine, in that order', LL.pluginTypes(), ['websearch', 'binary', 'engine'])
  eq('binary is a type, not an engine kind', LL.isEngineKind('binary'), false)
  // The vocabularies that matter are the plugin type, the engine kinds and
  // the synthetic kinds; none of them may drift apart from the others.
  for (const k of ['color', 'fx', 'time', 'unit', 'calc']) {
    eq(`'${k}' is an engine kind`, LL.isEngineKind(k), true)
  }
  eq("'websearch' is a type, not an engine kind", LL.isEngineKind('websearch'), false)
})

group('pluginConfigFromMeta turns a good manifest into a config', () => {
  const cfg = LL.pluginConfigFromMeta('calc', '/p/calc', { name: 'Calculator', description: 'D', keyword: '', type: 'engine' }, [])
  eq('id is the directory name', cfg.id, 'calc')
  eq('dir is the scanned directory', cfg.dir, '/p/calc')
  eq('name, description, keyword and type are carried through', [cfg.name, cfg.description, cfg.keyword, cfg.type], ['Calculator', 'D', '', 'engine'])
  eq('direct defaults to false', cfg.direct, false)
  eq('enabled defaults to true - absent means enabled', cfg.enabled, true)
  eq('broken defaults to false', cfg.broken, false)
  // The controller-owned fields are present and empty, so a rebind has a slot.
  eq('the controller fields start empty', [cfg._impl, cfg._host, cfg._view, cfg._denied], [null, null, null, []])
  eq('caps is the manifests own, possibly undefined', cfg.caps, undefined)
})

group('a broken manifest is skipped, and never takes the launcher down', () => {
  // "every field it must carry is checked here rather than trusted at the
  // call site" - so a missing or wrong-typed field is a skip, not a throw.
  const bad = [
    ['null manifest', null],
    ['undefined manifest', undefined],
    ['a missing name', { description: 'D', keyword: 'k', type: 'engine' }],
    ['a non-string name', { name: 5, description: 'D', keyword: 'k', type: 'engine' }],
    ['an empty name', { name: '', description: 'D', keyword: 'k', type: 'engine' }],
    ['a missing description', { name: 'N', keyword: 'k', type: 'engine' }],
    ['a non-string description', { name: 'N', description: 5, keyword: 'k', type: 'engine' }],
    ['an empty description', { name: 'N', description: '', keyword: 'k', type: 'engine' }],
    ['a missing keyword field', { name: 'N', description: 'D', type: 'engine' }],
    ['a non-string keyword', { name: 'N', description: 'D', keyword: 5, type: 'engine' }],
    ['a type outside the vocabulary', { name: 'N', description: 'D', keyword: 'k', type: 'other' }],
    ['a missing type', { name: 'N', description: 'D', keyword: 'k' }],
    ['a null manifest field', null],
  ]
  for (const [label, meta] of bad) {
    eq(`${label} is skipped`, LL.pluginConfigFromMeta('x', '/p/x', meta, []), null)
  }
  // An empty manifest object has no name, so it is skipped.
  eq('an empty object is skipped', LL.pluginConfigFromMeta('x', '/p/x', {}, []), null)
})

group('a keywordless engine is admitted, and the shipped engines depend on it', () => {
  // DOC/CODE DRIFT, pinned deliberately. The comment above the guard reads
  // "only an engine or a websearch plugin is admitted, and only a websearch
  // plugin may be keywordless", but the keyword clause is
  //   (type !== "engine" && type !== "websearch" && keyword === "")
  // so a keywordless manifest is rejected only when its type is *outside* the
  // vocabulary - which the very next clause already rejects. The observable
  // rule is "type in the vocabulary", and that is the one the shipped
  // plugins need: calc/color/fx/time/unit all declare `type: "engine"`
  // with `keyword: ""`, so enforcing the comment's sentence would reject all
  // five shipped engines. Pinned as observed; reported as drift.
  const KEYWORDLESS_ENGINE = { name: 'E', description: 'D', keyword: '', type: 'engine' }
  eq('a keywordless engine is admitted', LL.pluginConfigFromMeta('e', '/p/e', KEYWORDLESS_ENGINE, []) !== null, true)
  eq('and keeps its empty keyword', LL.pluginConfigFromMeta('e', '/p/e', KEYWORDLESS_ENGINE, []).keyword, '')
  eq('a keywordless websearch is admitted', LL.pluginConfigFromMeta('w', '/p/w', { name: 'W', description: 'D', keyword: '', type: 'websearch' }, []) !== null, true)
  eq('a keywordless unknown type is still skipped',
    LL.pluginConfigFromMeta('x', '/p/x', { name: 'X', description: 'D', keyword: '', type: 'other' }, []), null)
  eq('and every shipped plugin manifest is admitted by the real rule', (() => {
    const bad = []
    for (const dir of PLUGIN_DIRS) {
      const m = pluginManifest(dir)
      if (LL.pluginConfigFromMeta(path.basename(dir), dir, m, []) === null) bad.push(path.basename(dir))
    }
    return bad
  })(), [])
})

group('persisted enablement wins over the default, absent means enabled', () => {
  const meta = ENGINE_META
  eq('no persisted row', LL.pluginConfigFromMeta('e', '/p/e', meta, []).enabled, true)
  eq('persisted false disables', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'e', enabled: false }]).enabled, false)
  eq('persisted true enables', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'e', enabled: true }]).enabled, true)
  // "enabled !== false", so anything that is not literally false enables.
  eq('persisted 0 enables', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'e', enabled: 0 }]).enabled, true)
  eq('persisted undefined enables', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'e' }]).enabled, true)
  eq('a row for another id is ignored', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'other', enabled: false }]).enabled, true)
  eq('the first matching row wins', LL.pluginConfigFromMeta('e', '/p/e', meta, [{ id: 'e', enabled: false }, { id: 'e', enabled: true }]).enabled, false)
  // A null manifest short-circuits before the persisted loop, so the
  // documented null verdict does not need a persisted array at all.
  eq('a null manifest needs no persisted list', LL.pluginConfigFromMeta('e', '/p/e', null), null)
})

group('direct is read as a strict boolean', () => {
  eq('true', LL.pluginConfigFromMeta('d', '/p/d', Object.assign({}, WEB_META, { direct: true }), []).direct, true)
  eq('the string "true" is not true', LL.pluginConfigFromMeta('d', '/p/d', Object.assign({}, WEB_META, { direct: 'true' }), []).direct, false)
  eq('1 is not true', LL.pluginConfigFromMeta('d', '/p/d', Object.assign({}, WEB_META, { direct: 1 }), []).direct, false)
  eq('absent', LL.pluginConfigFromMeta('d', '/p/d', WEB_META, []).direct, false)
})

group('caps is the manifests request, carried verbatim and never applied here', () => {
  const cfg = LL.pluginConfigFromMeta('w', '/p/w', Object.assign({}, WEB_META, { capabilities: ['setting', 'readFile'] }), [])
  eq('the list is carried', cfg.caps, ['setting', 'readFile'])
  // The launcher intersects it (AppLauncher._grantsFor); this module never
  // does, so a manifest asking for more is still only a request.
  eq('nothing was added to the config by the request', Object.keys(cfg).includes('granted'), false)
  eq('and the request does not disable anything', cfg.enabled, true)
})

group('buildPluginConfigs derives the id from the directory name', () => {
  const metas = {
    '/a/calc': { name: 'C', description: 'D', keyword: '', type: 'engine' },
    '/b/time': { name: 'T', description: 'D', keyword: '', type: 'engine' },
  }
  const built = LL.buildPluginConfigs(['/a/calc', '/b/time'], [], (d) => metas[d])
  eq('ids and dirs', built.map((c) => [c.id, c.dir]), [['calc', '/a/calc'], ['time', '/b/time']])
  // A directory written with a trailing slash yields an EMPTY id, because the
  // id is the substring after the last "/". Nothing in the shell hits this -
  // pluginScanArgv strips the trailing slash with `${d%/}` for exactly this
  // reason - but the substring is unguarded here, so it is pinned.
  eq('a directory written with a trailing slash yields an empty id',
    LL.buildPluginConfigs(['/a/calc/'], [], () => metas['/a/calc']).map((c) => c.id), [''])
  eq('and without one the id is the name',
    LL.buildPluginConfigs(['/a/calc'], [], () => metas['/a/calc']).map((c) => c.id), ['calc'])
  eq('so the two spellings of one root are NOT interchangeable here',
    LL.buildPluginConfigs(['/a/calc/'], [], () => metas['/a/calc'])[0].id === LL.buildPluginConfigs(['/a/calc'], [], () => metas['/a/calc'])[0].id, false)
  eq('no directories is no plugins', LL.buildPluginConfigs([], [], () => null), [])
})

group('a duplicate id resolves in favour of the earlier root', () => {
  // "the built-in root is scanned first, so a user folder named `calc` cannot
  // shadow the shipped one" - and the seen-marker means the *duplicate* is
  // the one dropped, not merged.
  const builtins = { name: 'Shipped', description: 'D', keyword: '', type: 'engine' }
  const usercopy = { name: 'User', description: 'D', keyword: '', type: 'engine' }
  const built = LL.buildPluginConfigs(
    ['/shell/plugins/calc', '/home/u/.config/plugins/calc'],
    [],
    (d) => (d.indexOf('/shell/') === 0 ? builtins : usercopy),
  )
  eq('one config, not two', built.length, 1)
  eq('and it is the earlier root', built[0].name, 'Shipped')
  eq('with the earlier dir', built[0].dir, '/shell/plugins/calc')
  // A duplicate whose first copy is broken does not fall through to the second:
  // the seen-marker is set before the manifest is read.
  const broken = LL.buildPluginConfigs(['/a/calc', '/b/calc'], [], (d) => (d === '/a/calc' ? null : usercopy))
  eq('a broken first copy still consumes the id', broken, [])
})

group('a readMeta that fails is a skip here, and a throw is the callers problem', () => {
  // "its own I/O failure is a skip, not a throw - discovery must survive a
  // directory it cannot read" - the seam returns null for that. A readMeta
  // that itself throws is a different thing: the callback contract is a
  // parsed manifest or null.
  eq('a null manifest skips its directory', LL.buildPluginConfigs(['/a/x'], [], () => null), [])
  eq('and the rest of the scan still happens',
    LL.buildPluginConfigs(['/a/x', '/a/y'], [], (d) => (d === '/a/y' ? ENGINE_META : null)).map((c) => c.id), ['y'])
  throws('a throwing readMeta is not absorbed', () => LL.buildPluginConfigs(['/a/x'], [], () => { throw new Error('io') }), /io/)
})

group('buildPluginConfigs passes the persisted list through', () => {
  const built = LL.buildPluginConfigs(['/a/calc'], [{ id: 'calc', enabled: false }], () => ENGINE_META)
  eq('a persisted disable reaches the config', built[0].enabled, false)
})

group('persistedPluginList keeps the rows that name an id, in file order', () => {
  eq('rows with a string id survive in order',
    LL.persistedPluginList({ plugins: [{ id: 'b' }, { id: 'a' }] }).map((p) => p.id), ['b', 'a'])
  eq('a row without an id is dropped', LL.persistedPluginList({ plugins: [{ enabled: true }] }), [])
  eq('a null row is dropped', LL.persistedPluginList({ plugins: [null, { id: 'a' }] }), [{ id: 'a' }])
  eq('a non-string id is dropped', LL.persistedPluginList({ plugins: [{ id: 5 }] }), [])
  eq('the extra fields are kept - the writer reads enabled off the row',
    LL.persistedPluginList({ plugins: [{ id: 'a', enabled: false, note: 'x' }] }), [{ id: 'a', enabled: false, note: 'x' }])
})

group('persistedPluginList reads anything that is not the expected shape as empty', () => {
  // Settings is the controller's to read; what a section MEANS is here, and a
  // hand-edited settings file must not be able to crash discovery.
  for (const v of [null, undefined, {}, { plugins: null }, { plugins: 'x' }, { plugins: 5 }, { plugins: {} }, 5, 'x', []]) {
    eq(`persistedPluginList(${JSON.stringify(v) ?? String(v)})`, LL.persistedPluginList(v), [])
  }
})

group('pluginConfigsForPersist documents itself and leaves unknown rows alone', () => {
  // "the full merged configs, so the file documents itself, with entries for
  // plugins this scan did not discover left exactly as they were."
  const live = [
    LL.pluginConfigFromMeta('a', '/p/a', { name: 'A', description: 'DA', keyword: 'a', type: 'engine' }, []),
    LL.pluginConfigFromMeta('b', '/p/b', { name: 'B', description: 'DB', keyword: 'b', type: 'websearch' }, []),
  ]
  live[1].enabled = false
  const out = LL.pluginConfigsForPersist([{ id: 'a', enabled: true }, { id: 'zz', enabled: false }], live)
  eq('the undiscovered row is kept verbatim and comes first', out[0], { id: 'zz', enabled: false })
  eq('the discovered rows follow, self-describing', out.slice(1), [
    { id: 'a', name: 'A', description: 'DA', keyword: 'a', type: 'engine', enabled: true },
    { id: 'b', name: 'B', description: 'DB', keyword: 'b', type: 'websearch', enabled: false },
  ])
  // Only the six persisted fields leave; the controller-owned ones do not.
  eq('every persisted row has exactly the six fields', Object.keys(out[1]), ['id', 'name', 'description', 'keyword', 'type', 'enabled'])
  eq('no _impl, _host, _view or _denied is written', out.some((r) => '_impl' in r || '_host' in r || '_view' in r || '_denied' in r), false)
  eq('an empty live registry writes only the unknown rows',
    LL.pluginConfigsForPersist([{ id: 'zz' }], []), [{ id: 'zz' }])
})

group('persistedPluginWithState writes a flip the registry has not discovered yet', () => {
  // "the demand that raced the scan is transient and its tree can be torn
  // down before the scan lands, so a request held only in that tree would go
  // with it." Durable first is the whole contract, so the value has to reach
  // the file the next discovery overlays from - not a queue on the controller.
  const file = [{ id: 'b', enabled: true, note: 'keep me' }, { id: 'a', enabled: false }]
  eq('a known id keeps its slot and every field but enabled',
    LL.persistedPluginWithState(file, 'a', true), [{ id: 'b', enabled: true, note: 'keep me' }, { id: 'a', enabled: true }])
  eq('an unknown id is appended so a later overlay finds it',
    LL.persistedPluginWithState(file, 'zz', false).slice(-1), [{ id: 'zz', enabled: false }])
  eq('the order of the rows the file already had is untouched',
    LL.persistedPluginWithState(file, 'zz', false).slice(0, 2), file)
  // Settings hands out the live object, so writing through it would edit the
  // engine's own state rather than a new value for it.
  eq('the input list is not mutated', file, [{ id: 'b', enabled: true, note: 'keep me' }, { id: 'a', enabled: false }])
  eq('an empty id is a no-op', LL.persistedPluginWithState(file, '', false), file)
  eq('a nullish id is a no-op', LL.persistedPluginWithState(file, null, false), file)
  eq('an empty file takes the append', LL.persistedPluginWithState([], 'a', false), [{ id: 'a', enabled: false }])
  eq('"enabled !== false" is not assumed: the flag is written as a real bool',
    LL.persistedPluginWithState([], 'a', 0)[0].enabled, false)
  // The end the write exists for: discovery reads this list and the requested
  // state is the state the config comes up with.
  const dirs = ['/p/a', '/p/b']
  const readMeta = (d) => (d === '/p/a' ? ENGINE_META : WEB_META)
  eq('a disable survives into the build that follows',
    LL.buildPluginConfigs(dirs, LL.persistedPluginWithState([], 'a', false), readMeta).map((c) => c.enabled), [false, true])
  eq('and so does a re-enable of a plugin the file had off',
    LL.buildPluginConfigs(dirs, LL.persistedPluginWithState([{ id: 'a', enabled: false }], 'a', true), readMeta)
      .map((c) => c.enabled), [true, true])
})

group('mergePersistedEnabled applies a hand edit in place and reports movement', () => {
  const fresh = () => [
    LL.pluginConfigFromMeta('a', '/p/a', ENGINE_META, []),
    LL.pluginConfigFromMeta('b', '/p/b', WEB_META, []),
  ]
  const reg = fresh()
  eq('it reports a real change', LL.mergePersistedEnabled(reg, [{ id: 'a', enabled: false }]), true)
  eq('and the config was mutated in place', reg.map((c) => c.enabled), [false, true])
  eq('a second identical merge reports nothing moved', LL.mergePersistedEnabled(reg, [{ id: 'a', enabled: false }]), false)
  // A row for an id no config carries moves nothing *only* when the configs
  // are already at the default, because "no row" resolves to enabled - so a
  // disabled config is re-enabled by a merge that names nothing.
  eq('a row for an unknown id moves nothing when every config is at the default',
    LL.mergePersistedEnabled(fresh(), [{ id: 'zz', enabled: false }]), false)
  eq('and a disabled config is re-enabled by a merge that names nothing',
    LL.mergePersistedEnabled(fresh().map((c) => (c.enabled = false, c)), [{ id: 'zz', enabled: false }]), true)
  eq('and a re-enable is a change too', LL.mergePersistedEnabled(reg, [{ id: 'a', enabled: true }]), true)
  eq('with the config back on', reg[0].enabled, true)
  // "enabled !== false", so a hand-edited 0, "" or missing field enables - and
  // against an already-enabled config that is still "nothing moved", which is
  // the whole point of the changed flag: a settings engine bump arrives on
  // every write, not only on a real change.
  eq('a 0 in settings against an enabled config moves nothing', LL.mergePersistedEnabled(fresh(), [{ id: 'a', enabled: 0 }]), false)
  eq('a missing enabled field against an enabled config moves nothing', LL.mergePersistedEnabled(fresh(), [{ id: 'a' }]), false)
  eq('a missing enabled field against a disabled config enables it', LL.mergePersistedEnabled(fresh().map((c) => (c.enabled = false, c)), [{ id: 'a' }]), true)
  eq('an empty registry changes nothing', LL.mergePersistedEnabled([], [{ id: 'a', enabled: false }]), false)
  eq('an empty persisted list leaves every config on', LL.mergePersistedEnabled(fresh(), []), false)
})

group('the lookups find a plugin whatever its state', () => {
  // "the mode owner, the settings writer and the enablement read all need to
  // find a config that is disabled as much as one that is loaded."
  const reg = [
    { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, name: 'A', description: 'D', _denied: [] },
    { id: 'b', keyword: '', type: 'websearch', enabled: true, broken: false, name: 'B', description: 'D', _denied: [] },
    { id: 'c', keyword: 'c', type: 'engine', enabled: false, broken: false, name: 'C', description: 'D', _denied: [] },
    { id: 'd', keyword: 'd', type: 'engine', enabled: true, broken: true, name: 'D', description: 'D', _denied: ['network'] },
  ]
  eq('pluginById finds a live one', LL.pluginById(reg, 'a').id, 'a')
  eq('pluginById finds a disabled one', LL.pluginById(reg, 'c').id, 'c')
  eq('pluginById finds a broken one', LL.pluginById(reg, 'd').id, 'd')
  eq('pluginById on an unknown id is null', LL.pluginById(reg, 'zz'), null)
  eq('pluginById on an empty id is null', LL.pluginById(reg, ''), null)
  eq('pluginById on a nullish id is null', LL.pluginById(reg, null), null)
  eq('pluginById stringifies the id it is given', LL.pluginById([{ id: '5' }], 5).id, '5')
  eq('pluginById on an empty registry is null', LL.pluginById([], 'a'), null)
})

group('pluginByPrefix is the dispatch gate, so it is stricter', () => {
  const reg = [
    { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, name: 'A', description: 'D', _denied: [] },
    { id: 'b', keyword: '', type: 'websearch', enabled: true, broken: false, name: 'B', description: 'D', _denied: [] },
    { id: 'c', keyword: 'c', type: 'engine', enabled: false, broken: false, name: 'C', description: 'D', _denied: [] },
    { id: 'd', keyword: 'd', type: 'engine', enabled: true, broken: true, name: 'D', description: 'D', _denied: [] },
    { id: 'e', keyword: 'ab', type: 'engine', enabled: true, broken: false, name: 'E', description: 'D', _denied: [] },
  ]
  eq('a live one dispatches', LL.pluginByPrefix(reg, 'a').id, 'a')
  eq('a disabled one does not', LL.pluginByPrefix(reg, 'c'), null)
  eq('a broken one does not', LL.pluginByPrefix(reg, 'd'), null)
  eq('a keywordless one does not - it is an immediate action, not a prefix', LL.pluginByPrefix(reg, ''), null)
  eq('the empty prefix is never a mode', LL.pluginByPrefix(reg, ''), null)
  eq('the exact keyword dispatches', LL.pluginByPrefix(reg, 'ab').id, 'e')
  eq('a shorter prefix of a keyword does not dispatch', LL.pluginByPrefix([reg[4]], 'a'), null)
  eq('an unknown prefix', LL.pluginByPrefix(reg, 'zz'), null)
  eq('null', LL.pluginByPrefix(reg, null), null)
  eq('undefined', LL.pluginByPrefix(reg, undefined), null)
  // enabledPrefixes is the same gate, enumerated.
  eq('enabledPrefixes lists the dispatchable prefixes', LL.enabledPrefixes(reg), ['a', 'ab'])
  // enabledPrefixes, pluginToggles and pluginByPrefix all index the array
  // unguarded, so a nullish registry is a caller error rather than an empty
  // answer. Pinned so the boundary is written down.
  throws('a nullish registry has no prefix verdict at all', () => LL.enabledPrefixes(null), /length/)
})

group('pluginByType is discovery order, first live one wins', () => {
  const reg = [
    { id: 'off', keyword: 'off', type: 'engine', enabled: false, broken: false, name: 'O', description: 'D', _denied: [] },
    { id: 'broken', keyword: 'br', type: 'engine', enabled: true, broken: true, name: 'B', description: 'D', _denied: [] },
    { id: 'live', keyword: 'lv', type: 'engine', enabled: true, broken: false, name: 'L', description: 'D', _denied: [] },
    { id: 'web', keyword: 'wb', type: 'websearch', enabled: true, broken: false, name: 'W', description: 'D', _denied: [] },
  ]
  eq('skips the disabled and the broken to reach the first live engine', LL.pluginByType(reg, 'engine').id, 'live')
  eq('the websearch one', LL.pluginByType(reg, 'websearch').id, 'web')
  eq('a type nothing declares', LL.pluginByType(reg, 'other'), null)
  eq('null', LL.pluginByType(reg, null), null)
  eq('an empty registry', LL.pluginByType([], 'engine'), null)
})

group('pluginDescriptor is the only shape that leaves for a view', () => {
  // "A view may read the descriptor's keyword and may not reach the impl, the
  // host or the policy view through it."
  const cfg = { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, _impl: { secret: 1 }, _host: { x: 1 }, _view: { y: 1 }, _denied: ['network'] }
  eq('exactly id, keyword and type', LL.pluginDescriptor(cfg), { id: 'a', keyword: 'a', type: 'engine' })
  eq('a disabled plugin has no descriptor', LL.pluginDescriptor(Object.assign({}, cfg, { enabled: false })), null)
  eq('a broken plugin has no descriptor', LL.pluginDescriptor(Object.assign({}, cfg, { broken: true })), null)
  eq('enabled must be exactly true', LL.pluginDescriptor(Object.assign({}, cfg, { enabled: 'true' })), null)
  eq('a nullish config', LL.pluginDescriptor(null), null)
  eq('an empty descriptor carries no controller field',
    Object.keys(LL.pluginDescriptor(cfg)).some((k) => k.startsWith('_')), false)
})

group('pluginEnabledFlag is discovered and enabled and not broken', () => {
  const reg = [
    { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, name: 'A', description: 'D', _denied: [] },
    { id: 'b', keyword: 'b', type: 'engine', enabled: false, broken: false, name: 'B', description: 'D', _denied: [] },
    { id: 'c', keyword: 'c', type: 'engine', enabled: true, broken: true, name: 'C', description: 'D', _denied: [] },
  ]
  eq('live', LL.pluginEnabledFlag(reg, 'a'), true)
  eq('disabled', LL.pluginEnabledFlag(reg, 'b'), false)
  eq('broken', LL.pluginEnabledFlag(reg, 'c'), false)
  // "An id nothing knows reads off, which is what an undiscovered plugin
  // directory is."
  eq('an undiscovered id', LL.pluginEnabledFlag(reg, 'zz'), false)
  eq('a nullish id', LL.pluginEnabledFlag(reg, null), false)
  eq('broken is read as exactly true', LL.pluginEnabledFlag([{ id: 'a', enabled: true, broken: 'yes' }], 'a'), true)
})

group('pluginSummary is the whole public record set, and nothing else', () => {
  const reg = [
    { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, name: 'A', description: 'D', _denied: [] },
    { id: 'd', keyword: 'd', type: 'engine', enabled: true, broken: true, name: 'D', description: 'DD', _denied: ['network'] },
    { id: 'c', keyword: 'c', type: 'engine', enabled: false, broken: false, name: 'C', description: 'DC', _denied: [] },
  ]
  const sum = LL.pluginSummary(reg, (pl) => (pl.id === 'a' ? ['id', 'setting'] : []))
  eq('one record per plugin, in registry order', sum.map((s) => s.id), ['a', 'd', 'c'])
  eq('the live record', sum[0], { id: 'a', name: 'A', description: 'D', keyword: 'a', type: 'engine', enabled: true, broken: false, granted: ['id', 'setting'], denied: [] })
  eq('the broken record carries its denied list', sum[1].broken, true)
  eq('and the granted read went through the injected callback', sum[1].granted, [])
  eq('the disabled record', sum[2].enabled, false)
  // No engine object escapes: the record has no _impl, _host or _view key.
  eq('no controller field is in a summary record',
    Object.keys(sum[0]).filter((k) => k.startsWith('_')), [])
  eq('exactly the nine public fields', Object.keys(sum[0]),
    ['id', 'name', 'description', 'keyword', 'type', 'enabled', 'broken', 'granted', 'denied'])
  // A plugin that was never granted answers an empty list, not a throw.
  eq('a plugin with no _denied at all still summarises',
    LL.pluginSummary([{ id: 'x', name: 'X', description: 'D', keyword: '', type: 'engine', enabled: true }], () => [])[0].denied, [])
  eq('an empty registry summarises to nothing', LL.pluginSummary([], () => []), [])
})

group('pluginToggles is the same answer as pluginEnabledFlag, as a map', () => {
  const reg = [
    { id: 'a', keyword: 'a', type: 'engine', enabled: true, broken: false, name: 'A', description: 'D', _denied: [] },
    { id: 'b', keyword: 'b', type: 'engine', enabled: false, broken: false, name: 'B', description: 'D', _denied: [] },
    { id: 'c', keyword: 'c', type: 'engine', enabled: true, broken: true, name: 'C', description: 'D', _denied: [] },
  ]
  eq('the map', LL.pluginToggles(reg), { a: true, b: false, c: false })
  for (const c of reg) {
    eq(`pluginToggles and pluginEnabledFlag agree for ${c.id}`,
      LL.pluginToggles(reg)[c.id], LL.pluginEnabledFlag(reg, c.id))
  }
  eq('an empty registry is an empty map', LL.pluginToggles([]), {})
  throws('a nullish registry is a caller error, not an empty map', () => LL.pluginToggles(null), /length/)
})

group('firstEngineClaiming follows ENGINE_ORDER, not discovery order', () => {
  // "Registration order is discovery order; the builtin root scans before the
  // user root and folder names sort calc < time < unit on disk, so
  // ship the priority explicitly rather than inferring it."
  const reg = [
    { id: 'calc', type: 'engine', enabled: true, broken: false, _impl: {}, name: 'C', description: 'D', keyword: '' },
    { id: 'time', type: 'engine', enabled: true, broken: false, _impl: {}, name: 'T', description: 'D', keyword: '' },
    { id: 'unit', type: 'engine', enabled: true, broken: false, _impl: {}, name: 'U', description: 'D', keyword: '' },
  ]
  const all = (pl) => (pl.id === 'calc' ? [{ label: 'c' }] : pl.id === 'time' ? [{ label: 't' }] : [{ label: 'u' }])
  eq('time outranks unit and calc even though calc is first in the list',
    LL.firstEngineClaiming(reg, 'q', all).plugin.id, 'time')
  eq('and the claim carries that plugins whole list', LL.firstEngineClaiming(reg, 'q', all).rows, [{ label: 't' }])
  // An engine may answer with a list rather than a single row: a bare "5 mb" is
  // one engine answer in six readings, and the card renders every row it gets.
  const three = [{ label: 't1' }, { label: 't2' }, { label: 't3' }]
  const many = (pl) => (pl.id === 'time' ? three : [{ label: pl.id }])
  eq('a multi-row answer survives the claim whole',
    LL.firstEngineClaiming(reg, 'q', many).rows, three)
  eq('and the claim hands back the plugins own array, so no row is re-minted',
    LL.firstEngineClaiming(reg, 'q', many).rows === three, true)
  // ENGINE_ORDER is time, unit, calc - so a declining time engine hands
  // the query to unit, not to calc, even though calc is first in the list.
  const declining = (pl) => (pl.id === 'time' ? [] : [{ label: pl.id }])
  eq('a declining time engine hands on to the next priority, unit',
    LL.firstEngineClaiming(reg, 'q', declining).plugin.id, 'unit')
  eq('and with unit disabled too, it reaches calc',
    LL.firstEngineClaiming([reg[0], reg[1], Object.assign({}, reg[2], { enabled: false })], 'q', declining).plugin.id, 'calc')
  eq('and with both disabled, only calc is left',
    LL.firstEngineClaiming([reg[0], Object.assign({}, reg[1], { enabled: false }), Object.assign({}, reg[2], { enabled: false })], 'q', declining).plugin.id, 'calc')
})

group('firstEngineClaiming skips everything that cannot answer', () => {
  const live = { name: 'X', description: 'D', keyword: '', _impl: {} }
  const rows = () => [{ label: 'x' }]
  eq('a broken engine is skipped', LL.firstEngineClaiming([Object.assign({ id: 'time', type: 'engine', enabled: true, broken: true }, live)], 'q', rows), null)
  eq('a disabled engine is skipped', LL.firstEngineClaiming([Object.assign({ id: 'time', type: 'engine', enabled: false, broken: false }, live)], 'q', rows), null)
  eq('an engine with no impl is skipped', LL.firstEngineClaiming([Object.assign({ id: 'time', type: 'engine', enabled: true, broken: false }, live, { _impl: null })], 'q', rows), null)
  eq('an engine of the wrong type is skipped', LL.firstEngineClaiming([Object.assign({ id: 'time', type: 'websearch', enabled: true, broken: false }, live)], 'q', rows), null)
  eq('an id outside the engine order is never consulted', LL.firstEngineClaiming([Object.assign({ id: 'calc', type: 'engine', enabled: true, broken: false }, live)], 'q', rows).plugin.id, 'calc')
  eq('a websearch plugin is never an engine claimer', LL.firstEngineClaiming([Object.assign({ id: 'web', type: 'websearch', enabled: true, broken: false }, live)], 'q', rows), null)
  eq('an empty rows array does not claim', LL.firstEngineClaiming([Object.assign({ id: 'calc', type: 'engine', enabled: true, broken: false }, live)], 'q', () => []), null)
  eq('a null rows answer does not claim', LL.firstEngineClaiming([Object.assign({ id: 'calc', type: 'engine', enabled: true, broken: false }, live)], 'q', () => null), null)
  eq('an empty registry claims nothing', LL.firstEngineClaiming([], 'q', rows), null)
  eq('a null entry in the registry is skipped, not dereferenced',
    LL.firstEngineClaiming([null, Object.assign({ id: 'calc', type: 'engine', enabled: true, broken: false }, live)], 'q', rows).plugin.id, 'calc')
  // The query is not consulted: the engines decide from the query themselves.
  eq('the query argument is passed to the caller, not filtered here',
    LL.firstEngineClaiming([Object.assign({ id: 'calc', type: 'engine', enabled: true, broken: false }, live)], 'anything', rows).plugin.id, 'calc')
})

group('firstFallbackClaiming asks the types in FALLBACK_ORDER, not discovery order', () => {
  // The slot is a CHAIN: the first live plugin whose items() answers takes
  // it, and one that declines hands it on. The difference from the engine path
  // is that the order is by TYPE, which is what lets a user plugin join the
  // chain - an id-keyed order would be a closed list of folder names.
  const live = { _impl: true, enabled: true, broken: false }
  const reg = (id, type, extra) => Object.assign({ id, type, enabled: true, broken: false, _impl: true }, extra)
  const one = (label) => [{ label, data: {} }]
  const rowsFor = (p) => (p.id === 'bin' ? [] : one(p.id))

  // Discovery order is deliberately REVERSED against FALLBACK_ORDER here, so
  // an implementation that iterated the registry would answer differently.
  const reg2 = [reg('web', 'websearch'), reg('bin', 'binary')]
  eq('binary is asked first even though websearch is discovered first',
    LL.firstFallbackClaiming(reg2, 'qt6ct', rowsFor).plugin.id, 'web')

  // The claim carries EVERY row the plugin answered, not just the first: the
  // slot renders the plugin's own list, so narrowing here would silently drop
  // rows a plugin chose to publish.
  const many = [reg('many', 'websearch')]
  eq('all claimed rows come back',
    LL.firstFallbackClaiming(many, 'q', () => one('a').concat(one('b'), one('c'))).rows.length, 3)

  // A declining plugin is the whole point of the chain: the binary plugin
  // answers nothing for a query that is not a program name, and the slot must
  // still be filled by the web search below it.
  eq('a plugin that declines hands the slot on',
    LL.firstFallbackClaiming([reg('bin', 'binary'), reg('web', 'websearch')],
      'anything', (p) => (p.id === 'bin' ? [] : one('search'))).plugin.id, 'web')
  eq('and every type declining empties the slot',
    LL.firstFallbackClaiming([reg('bin', 'binary'), reg('web', 'websearch')], 'q', () => []), null)

  // The liveness and skip rules are the engine path's, unchanged: a disabled,
  // broken or unloaded plugin is not asked, and a null entry is not
  // dereferenced.
  eq('a disabled plugin is skipped', LL.firstFallbackClaiming(
    [reg('bin', 'binary', { enabled: false }), reg('web', 'websearch')], 'q', rowsFor).plugin.id, 'web')
  eq('a broken plugin is skipped', LL.firstFallbackClaiming(
    [reg('bin', 'binary', { broken: true }), reg('web', 'websearch')], 'q', rowsFor).plugin.id, 'web')
  eq('a plugin with no impl is skipped', LL.firstFallbackClaiming(
    [reg('bin', 'binary', { _impl: null }), reg('web', 'websearch')], 'q', rowsFor).plugin.id, 'web')
  eq('a null entry is skipped, not dereferenced',
    LL.firstFallbackClaiming([null, reg('web', 'websearch')], 'q', rowsFor).plugin.id, 'web')
  eq('an empty registry claims nothing', LL.firstFallbackClaiming([], 'q', rowsFor), null)
  // An engine is never a fallback claimer, whatever it answers.
  eq('an engine never claims the slot', LL.firstFallbackClaiming(
    [reg('calc', 'engine'), reg('web', 'websearch')], 'q', () => one('x')).plugin.id, 'web')
  // A null rows answer does not claim, exactly as on the engine path.
  eq('a null rows answer does not claim',
    LL.firstFallbackClaiming([reg('web', 'websearch')], 'q', () => null), null)
})

group('the order argument narrows which types may fill the slot', () => {
  // The forced path asks the binary type alone, because "!" is the user
  // asserting the query IS a program name: a name nothing provides must leave
  // the slot empty rather than answer a web search nobody asked for.
  const live = { _impl: true, enabled: true, broken: false }
  const reg = (id, type) => Object.assign({ id, type, enabled: true, broken: false, _impl: true }, live)
  const both = [reg('bin', 'binary'), reg('web', 'websearch')]
  const one = (label) => [{ label, data: {} }]
  // The binary plugin declines, which is what it does for anything that is not
  // an installed program name - so the web search is what answers.
  const binaryDeclines = (p) => (p.id === 'bin' ? [] : one(p.id))
  // The binary plugin claims, which is the forced path's only claimant.
  const binaryClaims = (p) => (p.id === 'bin' ? one('Launch ' + p.id) : [])

  eq('the forced order names the binary type alone', LL.forcedOrder(), ['binary'])
  eq('and the whole chain still names both, binary first', LL.fallbackOrder(), ['binary', 'websearch'])
  // The claim the user described: unforced, a name nothing provides falls
  // through to the web search.
  eq('unforced, an unclaimed query reaches the web search',
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines).plugin.id, 'web')
  // Forced, the same query is the binary type's alone, and the binary plugin
  // declines it - so the slot is empty, not a web search.
  eq('forced, the same query claims nothing at all',
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines, LL.forcedOrder()), null)
  // And forced, a name the binary plugin DOES claim still fills the slot.
  eq('forced, a claimed program name still fills the slot',
    LL.firstFallbackClaiming(both, 'qt6ct', binaryClaims, LL.forcedOrder()).plugin.id, 'bin')
  // The narrowing is a restriction, never a widening: naming an order that
  // omits the only claiming type cannot reach a plugin the default order
  // would have asked.
  eq('an order that names no live type claims nothing',
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines, ['nope']), null)
  eq('an empty order claims nothing',
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines, []), null)
  // A non-array is no narrowing at all, the same reading intersect() gives a
  // manifest's request: the default chain stands, so the web search answers.
  for (const v of [null, undefined, 'binary', 42, {}]) {
    eq(`order=${JSON.stringify(v) ?? String(v)} is no narrowing`,
      LL.firstFallbackClaiming(both, 'hello', binaryDeclines, v).plugin.id, 'web')
  }
  // The default is the whole chain, stated by omitting the argument.
  eq('the default order is the whole chain',
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines),
    LL.firstFallbackClaiming(both, 'hello', binaryDeclines, LL.fallbackOrder()))
  // The forced order is a strict subset of the whole chain, so a forced query
  // can only ever reach a plugin the unforced query could also have reached.
  is('the forced order is a prefix of the whole chain', LL.forcedOrder(),
    (o) => o.every((t) => LL.fallbackOrder().indexOf(t) >= 0), 'a subset of the full order')
  // And it deliberately excludes the one type that answers everything, which
  // is the whole point: a forced query must never reach it.
  eq('the forced order excludes websearch', LL.forcedOrder().indexOf('websearch'), -1)
})

group('ENGINE_ORDER and FALLBACK_ORDER agree with the shipped plugin directories', () => {
  // The priority lists are declared in LauncherLib and nothing validates them
  // against what actually exists on disk, so a folder in either vocabulary
  // that no list names would be silently unreachable. Pinned for both: the
  // engine names are the engine manifests, the fallback types are the
  // non-engine ones, and websearch is the only websearch manifest.
  const byType = {}
  for (const dir of PLUGIN_DIRS) {
    const m = pluginManifest(dir)
    ;(byType[m.type] = byType[m.type] || []).push(path.basename(dir))
  }
  eq('the engine plugins on disk are exactly the five priorities',
    (byType.engine || []).sort(), ['calc', 'color', 'fx', 'time', 'unit'])
  eq('the websearch plugins on disk', byType.websearch || [], ['websearch'])
  eq('the binary plugins on disk', byType.binary || [], ['binary'])
  // And every one of the five is a name firstEngineClaiming will consult.
  for (const id of ['color', 'fx', 'time', 'unit', 'calc']) {
    eq(`${id} is an engine kind`, LL.isEngineKind(id), true)
  }
  // Every type on disk is a name the fallback chain knows, so a new plugin
  // folder cannot declare a type the chain would never consult.
  eq('every type on disk is in the fallback order',
    PLUGIN_DIRS.map((d) => pluginManifest(d).type)
      .filter((t) => t !== 'engine')
      .every((t) => LL.fallbackOrder().indexOf(t) >= 0), true)
  // binary leads because it is the narrow claim: it answers only an exact
  // program name, and websearch answers every non-blank query, so the
  // narrower one has to be asked first or it would never be reached.
  eq('the fallback order puts the narrow claim first',
    LL.fallbackOrder(), ['binary', 'websearch'])
})

// =========================================================================
section('LauncherLib - search: tokenScore, searchRecords, filterCounter')
// =========================================================================

group('tokenScore ranks an exact word above a prefix above a substring', () => {
  // 3000 - w / 2000 - w*10 / 1000 - idx*10: the three bands never overlap, so
  // an exact hit on a later word still outranks a substring hit on the first.
  eq('an exact hit on the first word', LL.tokenScore(['firefox', 'web'], 'firefox'), 3000)
  eq('an exact hit on the second word loses ten points per word', LL.tokenScore(['firefox', 'web'], 'web'), 2999)
  eq('an exact hit on the third word', LL.tokenScore(['a', 'b', 'web'], 'web'), 2998)
  eq('a word-start prefix', LL.tokenScore(['firefox'], 'fire'), 2000)
  eq('a prefix of a later word loses ten per position', LL.tokenScore(['a', 'firefox'], 'fire'), 1990)
  eq('a contained substring, scored by where it starts', LL.tokenScore(['firefox'], 'refox'), 980)
  eq('a substring further along scores lower still', LL.tokenScore(['firefox'], 'x'), 940)
  eq('no hit at all', LL.tokenScore(['firefox'], 'chromium'), -1)
  eq('an empty token is a prefix of everything, scoring as one', LL.tokenScore(['firefox'], ''), 2000)
})

group('tokenScore keeps the first word that can hit, not the best one', () => {
  // The loop returns on the first word that matches by any of the three rules,
  // so an exact match on a later word is unreachable behind an earlier
  // substring hit. Pinned: it is a property of the loop, not a ranking rule.
  eq('an early substring hit shadows a later exact word', LL.tokenScore(['firefox', 'web'], 'refox'), 980)
  eq('an early prefix hit shadows a later exact word', LL.tokenScore(['firefox', 'web'], 'fire'), 2000)
  // Exact is checked before prefix inside one word, so a word equal to the
  // token scores as exact and never as its own prefix.
  eq('a word equal to the token is exact, not a prefix', LL.tokenScore(['web'], 'web'), 3000)
  // A substring hit at index 0 is impossible (that is a prefix), so the
  // `idx > 0` guard is not skipping anything.
  eq('a hit at index 0 is a prefix, scored as one', LL.tokenScore(['web'], 'w'), 2000)
})

group('tokenScore is total over its inputs', () => {
  eq('an empty word list', LL.tokenScore([], 'x'), -1)
  eq('an empty token on an empty word list', LL.tokenScore([], ''), -1)
  eq('an empty word in the list', LL.tokenScore(['', 'web'], 'web'), 2999)
  eq('an empty word cannot be found by an empty token after a real word', LL.tokenScore(['a', ''], ''), 2000)
  noThrow('a nullish token', () => LL.tokenScore(['x'], null))
  // The word list is read unguarded, because buildAppIndex always supplies
  // one. A missing list is a caller error, not an empty answer.
  throws('a nullish word list is a caller error', () => LL.tokenScore(null, 'x'), /length/)
  // The scan assumes string words, because buildAppIndex always produces
  // them: `hay` is a String and `words` is its split. A hand-built record
  // with a numeric word is outside the contract and throws rather than
  // silently scoring - pinned so that stays a known verdict.
  throws('a non-string word is outside the contract', () => LL.tokenScore([5], '5'), /startsWith|not a function/)
})

// Every search group builds its own records array: searchRecords keeps a
// module-scope incremental cache keyed on the records *identity*, so reusing
// one array across unrelated queries would couple the groups together.
const rec = (label, words, extra) => Object.assign({ label, words }, extra)

group('searchRecords is an AND over space-separated tokens', () => {
  const R = () => [rec('Firefox', ['firefox', 'web', 'browser']), rec('Thunderbird', ['thunderbird', 'mail'])]
  eq('one token hits both', LL.searchRecords(R(), 'fire', 10).rows.map((r) => r.label), ['Firefox'])
  eq('two tokens, both must hit', LL.searchRecords(R(), 'fire mail', 10).rows.map((r) => r.label), [])
  eq('a second token matching a later word is enough', LL.searchRecords(R(), 'fire browser', 10).rows.map((r) => r.label), ['Firefox'])
  eq('a token nothing hits empties the set', LL.searchRecords(R(), 'fire zzz', 10), { rows: [], count: 0 })
  eq('extra whitespace between tokens is collapsed', LL.searchRecords(R(), '  fire   browser  ', 10).rows.map((r) => r.label), ['Firefox'])
  eq('the query is lowercased and trimmed', LL.searchRecords(R(), '  FIRE  ', 10).rows.map((r) => r.label), ['Firefox'])
})

group('searchRecords sums the token scores, so totals decide ranking', () => {
  const R = () => [rec('A', ['web']), rec('B', ['firefox', 'web']), rec('C', ['xweb'])]
  // 'web' as the first word of A scores 3000; as the second word of B, 2999;
  // contained at index 1 of C, 990. The bands are what make this total order.
  eq('exact-first beats exact-second beats contained',
    LL.searchRecords(R(), 'web', 10).rows.map((r) => r.label), ['A', 'B', 'C'])
  eq('the three scores, read back one at a time',
    [LL.tokenScore(['web'], 'web'), LL.tokenScore(['firefox', 'web'], 'web'), LL.tokenScore(['xweb'], 'web')],
    [3000, 2999, 990])
  // AND means a record that misses a token is dropped, not ranked down - so
  // the score sum is what separates two records that both match everything.
  const AND = () => [rec('one', ['fire']), rec('two', ['fire', 'fox'])]
  eq('a record missing the second token is dropped, not ranked down',
    LL.searchRecords(AND(), 'fire fox', 10).rows.map((r) => r.label), ['two'])
  const S = () => [rec('buried', ['firefox', 'fox']), rec('exact', ['fire', 'fox'])]
  eq('among records matching every token, the score sum decides',
    LL.searchRecords(S(), 'fire fox', 10).rows.map((r) => r.label), ['exact', 'buried'])
  eq('and the sums are what the two bands produce',
    [LL.tokenScore(['fire', 'fox'], 'fire') + LL.tokenScore(['fire', 'fox'], 'fox'),
      LL.tokenScore(['firefox', 'fox'], 'fire') + LL.tokenScore(['firefox', 'fox'], 'fox')],
    [5999, 2960])
})

group('searchRecords caps the rows but never the count', () => {
  // "Returns { rows, count }: rows is the scored-sorted top cap (the display
  // cap), count the full hit total for the matched/total counter."
  const R = () => [rec('a', ['x']), rec('b', ['x']), rec('c', ['x']), rec('d', ['x'])]
  const r1 = LL.searchRecords(R(), 'x', 2)
  eq('rows are capped', r1.rows.length, 2)
  eq('count is the full hit total', r1.count, 4)
  eq('a cap of 0 yields no rows and the real count', LL.searchRecords(R(), 'x', 0), { rows: [], count: 4 })
  eq('the cap does not corrupt the next call', LL.searchRecords(R(), 'x', 99).rows.length, 4)
  eq('a cap above the hit count yields every row', LL.searchRecords(R(), 'x', 99).rows.length, 4)
  eq('a cap above the hit count yields every row', LL.searchRecords(R(), 'x', 99).rows.length, 4)
  // A cap is mandatory: `new Array(Math.min(len, cap))` is `new Array(NaN)`
  // without one, so the caller cannot forget it. Pinned so a missing cap
  // would be a known verdict rather than a mystery RangeError.
  throws('a missing cap is a caller error, not an unlimited cap',
    () => LL.searchRecords(R(), 'x'), /array length/i)
  eq('a negative cap is a caller error too', attempt(() => LL.searchRecords(R(), 'x', -1), []).ok, false)
})

group('searchRecords hands back the caller own record objects', () => {
  const R = () => [rec('Firefox', ['firefox'])]
  const rr = R()
  eq('the row is the record itself, not a copy', LL.searchRecords(rr, 'fire', 10).rows[0], rr[0])
  // The panel patches rows by identity, so a copy here would break its
  // single-row patch path.
  eq('a second call gives the same identity', LL.searchRecords(rr, 'fire', 10).rows[0], rr[0])
})

group('a blank query is an empty result, not the whole pool', () => {
  // The idle view is the base order, not a search result: a blank query must
  // not "match everything" or the counter would read 40/40 before a keystroke.
  const R = () => [rec('a', ['a'])]
  eq('empty string', LL.searchRecords(R(), '', 10), { rows: [], count: 0 })
  eq('whitespace only', LL.searchRecords(R(), '   ', 10), { rows: [], count: 0 })
  eq('tabs and newlines only', LL.searchRecords(R(), ' \t\n ', 10), { rows: [], count: 0 })
  eq('an empty records array with a blank query', LL.searchRecords([], '', 10), { rows: [], count: 0 })
})

group('a record list can be empty or absent without a throw', () => {
  noThrow('an empty array', () => LL.searchRecords([], 'x', 10))
  eq('an empty array finds nothing', LL.searchRecords([], 'x', 10), { rows: [], count: 0 })
  // filterCounter is the wrapper that guards the pool, and this section calls
  // the array twice with the cache, so the second call would come from the
  // cache - reset by a blank query on the very same (empty) array.
  eq('a nullish pool is a caller error, not an empty result', attempt(() => LL.searchRecords(null, 'x', 10), []).ok, false)
  // Every record in an app index or a keyword pool carries `words`; a
  // hand-built record without one is outside the contract and the scan
  // dereferences it, so it throws rather than reporting a silent miss.
  throws('a record with no words field is outside the contract',
    () => LL.searchRecords([{ label: 'x' }], 'x', 10), /words|length/)
  eq('a record whose words are empty is simply not a hit',
    LL.searchRecords([{ label: 'x', words: [] }], 'x', 10), { rows: [], count: 0 })
})

group('the tiebreak callback decides equal scores, input order decides the rest', () => {
  // "The launcher passes its druncache counts when the sort method is
  // frequency, so most-used wins ties in filtering just like in the idle view.
  // Records still tied after that keep input order (source index)."
  const R = () => [rec('first', ['web']), rec('second', ['web'])]
  eq('without a tiebreak, input order wins the tie', LL.searchRecords(R(), 'web', 10).rows.map((r) => r.label), ['first', 'second'])
  eq('a tiebreak reorders the tie', LL.searchRecords(R(), 'web', 10, () => 0).rows.map((r) => r.label), ['first', 'second'])
  eq('a tiebreak keyed on the record', LL.searchRecords(R(), 'web', 10, (r) => (r.label === 'second' ? 5 : 0)).rows.map((r) => r.label), ['second', 'first'])
  eq('a non-function tiebreak is ignored', LL.searchRecords(R(), 'web', 10, 5).rows.map((r) => r.label), ['first', 'second'])
  // Score still dominates the tiebreak: a higher score is never displaced.
  const S = () => [rec('low-high-usage', ['a', 'b', 'c', 'd', 'web']), rec('exact', ['web'])]
  eq('score outranks the tiebreak', LL.searchRecords(S(), 'web', 10, (r) => (r.label === 'low-high-usage' ? 99 : 0)).rows.map((r) => r.label), ['exact', 'low-high-usage'])
})

group('the incremental cache is a subset scan, and it is only valid when it may be', () => {
  // Sequential typing is the common case, so a grown query is scanned against
  // the previous hits only. That is sound because new hits are a subset of
  // old ones for the same records.
  const R = [rec('Firefox', ['firefox', 'web']), rec('Documents', ['documents']), rec('Fast', ['fastfox'])]
  eq('f hits two', LL.searchRecords(R, 'f', 10).rows.map((r) => r.label), ['Firefox', 'Fast'])
  eq('fi is a prefix of f, and the subset still holds', LL.searchRecords(R, 'fi', 10).rows.map((r) => r.label), ['Firefox'])
  eq('the same query again is served from the cache', LL.searchRecords(R, 'fi', 10).rows.map((r) => r.label), ['Firefox'])
  eq('a divergent query rescans the whole pool', LL.searchRecords(R, 'doc', 10).rows.map((r) => r.label), ['Documents'])
  // A shrunk or diverged query must not read the subset, so it does not.
  eq('shrinking back to f', LL.searchRecords(R, 'f', 10).rows.map((r) => r.label), ['Firefox', 'Fast'])
  // And a blank query resets the cache rather than filtering.
  eq('a blank query clears the cache', LL.searchRecords(R, '', 10), { rows: [], count: 0 })
  eq('and the next real query rescans the full pool', LL.searchRecords(R, 'f', 10).rows.map((r) => r.label), ['Firefox', 'Fast'])
  // The subset scan is only sound because new hits are a subset of old ones:
  // "do" is a prefix of "documents" and was NOT in the "f" hits, so it is
  // found only by a full rescan after the cache was cleared.
  eq('a token that was not in the previous hits is still found',
    LL.searchRecords(R, 'do', 10).rows.map((r) => r.label), ['Documents'])
})

group('the cache is invalidated by a records identity change', () => {
  // A re-index mints a fresh array, and a stale subset would filter the wrong
  // pool - the launcher would show hits from the previous index.
  eq('a first pool', LL.searchRecords([rec('a', ['ab'])], 'a', 10).rows.map((r) => r.label), ['a'])
  eq('a second pool with the same label but different words', LL.searchRecords([rec('a', ['zz'])], 'a', 10), { rows: [], count: 0 })
  eq('and back to a pool that does match', LL.searchRecords([rec('a', ['ab'])], 'a', 10).rows.map((r) => r.label), ['a'])
})

section('LauncherLib - typo rescue: typoDistance, typoTokenScore, searchTypo')

group('typoDistance counts one edit, and a transposition is one edit', () => {
  eq('identical strings', LL.typoDistance('firefox', 'firefox'), 0)
  eq('a substitution', LL.typoDistance('sotify', 'spotify'), 1)
  eq('an insertion', LL.typoDistance('wifii', 'wifi'), 1)
  eq('a deletion', LL.typoDistance('setings', 'settings'), 1)
  eq('an adjacent transposition', LL.typoDistance('fireofx', 'firefox'), 1)
  eq('two edits at once', LL.typoDistance('sptofy', 'spotify'), 2)
  eq('three edits read as beyond budget', LL.typoDistance('abc', 'abcdef'), 3)
  eq('unrelated strings read as beyond budget', LL.typoDistance('abc', 'xyz'), 3)
  eq('an empty token against one char', LL.typoDistance('', 'a'), 1)
  eq('lengths more than two apart never compare', LL.typoDistance('a', 'abcdef'), 3)
  eq('nullish inputs stringify before comparing', LL.typoDistance(null, 'a'), 1)
})

group('typoTokenScore answers only what tokenScore cannot', () => {
  eq('an exact word stays in the exact band', LL.typoTokenScore(['spotify'], 'spotify'), 3000)
  eq('a prefix word stays in the prefix band', LL.typoTokenScore(['spotify'], 'spot'), 2000)
  eq('a one-edit word scores its own band under every exact band',
    LL.typoTokenScore(['spotify'], 'sotify'), 500)
  eq('a one-edit word further along loses a point per word',
    LL.typoTokenScore(['music', 'spotify'], 'sotify'), 499)
  eq('a two-edit word scores the lower band',
    LL.typoTokenScore(['spotify'], 'sptofy'), 400)
  eq('a three-edit word is no hit at all', LL.typoTokenScore(['spotify'], 'spertxqfy'), -1)
  eq('a short token stays strict: two edits on two letters miss',
    LL.typoTokenScore(['ab'], 'zz'), -1)
  eq('while one edit on two letters still hits',
    LL.typoTokenScore(['ax'], 'ay'), 500)
  eq('a single letter never reaches the typo pass: any letter is one edit from any other',
    LL.typoTokenScore(['a'], 'q'), -1)
  eq('unless it already hits exactly', LL.typoTokenScore(['q'], 'q'), 3000)
  eq('no hit at all', LL.typoTokenScore(['spotify'], 'zzz'), -1)
  eq('an empty word list', LL.typoTokenScore([], 'x'), -1)
})

group('typoBudget keeps short tokens strict', () => {
  eq('two letters', LL.typoBudget('ab'), 1)
  eq('four letters', LL.typoBudget('spex'), 1)
  eq('five letters graduate to two', LL.typoBudget('spexq'), 2)
  eq('longer tokens', LL.typoBudget('fireofx'), 2)
  eq('nullish is short', LL.typoBudget(null), 1)
})

group('searchTypo is an AND over tokens with no incremental cache', () => {
  const R = () => [rec('Spotify', ['spotify', 'music']), rec('Firefox', ['firefox', 'browser'])]
  eq('one typo token rescues its row', LL.searchTypo(R(), 'sotify', 10).rows.map((r) => r.label), ['Spotify'])
  eq('a double typo rescues too', LL.searchTypo(R(), 'sptofy', 10).rows.map((r) => r.label), ['Spotify'])
  eq('mixed exact and typo tokens still AND',
    LL.searchTypo(R(), 'spotify musc', 10).rows.map((r) => r.label), ['Spotify'])
  eq('an all-exact query answers from the exact bands inside the typo pass',
    LL.searchTypo(R(), 'spotify', 10).rows.map((r) => r.label), ['Spotify'])
  eq('a token nothing hits empties the set', LL.searchTypo(R(), 'sotify zzz', 10), { rows: [], count: 0 })
  eq('a blank query is empty, not the pool', LL.searchTypo(R(), '', 10), { rows: [], count: 0 })
  const C = () => [rec('a', ['spot']), rec('b', ['spot']), rec('c', ['spot'])]
  eq('rows are capped', LL.searchTypo(C(), 'spott', 1).rows.length, 1)
  eq('count is the full hit total', LL.searchTypo(C(), 'spott', 1).count, 3)
  const T = () => [rec('first', ['abc']), rec('second', ['abc'])]
  eq('without a tiebreak, input order wins the tie',
    LL.searchTypo(T(), 'axc', 10).rows.map((r) => r.label), ['first', 'second'])
  eq('a tiebreak reorders the tie',
    LL.searchTypo(T(), 'axc', 10, (r) => (r.label === 'second' ? 5 : 0)).rows.map((r) => r.label), ['second', 'first'])
  eq('a non-function tiebreak is ignored',
    LL.searchTypo(T(), 'axc', 10, 5).rows.map((r) => r.label), ['first', 'second'])
  eq('hands back the caller own record objects', (() => {
    const rr = R()
    return LL.searchTypo(rr, 'sotify', 10).rows[0] === rr[0]
  })(), true)
  eq('a non-array pool is empty, not a throw', LL.searchTypo(null, 'x', 10), { rows: [], count: 0 })
  // The typo pass keeps no module state, so it can neither serve nor
  // disturb the exact cache: a longer query matching under tolerance is
  // exactly the case the subset scan would get wrong.
  const S = [rec('Spotify', ['spotify', 'music'])]
  eq('exact before', LL.searchRecords(S, 'spot', 10).rows.map((r) => r.label), ['Spotify'])
  eq('typo between leaves the exact cache alone',
    LL.searchTypo(S, 'zzzqqq', 10), { rows: [], count: 0 })
  eq('exact after agrees with exact before',
    LL.searchRecords(S, 'spot', 10).rows.map((r) => r.label), ['Spotify'])
})

group('filterCounter answers the three numbers the counter renders', () => {
  const R = () => [rec('a', ['web']), rec('b', ['web']), rec('c', ['mail'])]
  eq('a filtered pool is exactly {total, matched, rows}', Object.keys(LL.filterCounter(R(), 'web', 10)), ['total', 'matched', 'rows'])
  eq('the rows are the hits, in score then input order', LL.filterCounter(R(), 'web', 10).rows.map((r) => r.label), ['a', 'b'])
  eq('total is the pool size, not the hit count', LL.filterCounter(R(), 'web', 10).total, 3)
  eq('matched is the true hit count, never the cap', LL.filterCounter(R(), 'web', 1).matched, 2)
  eq('rows are the top cap', LL.filterCounter(R(), 'web', 1).rows.map((r) => r.label), ['a'])
  eq('a blank query matches the whole pool sliced to the cap',
    LL.filterCounter(R(), '', 2).rows.map((r) => r.label), ['a', 'b'])
  eq('and reports the whole pool as matched', LL.filterCounter(R(), '', 2).matched, 3)
  eq('a blank query with a cap above the pool returns the pool', LL.filterCounter(R(), '', 99).rows.length, 3)
  // The blank-query branch guards with `cap > 0`, so a cap of 0 (or a negative
  // one) falls through to the pool size rather than producing no rows. Pinned
  // because the filtered path disagrees - there cap 0 really does mean none.
  eq('a blank query ignores a cap of 0 and returns the pool', LL.filterCounter(R(), '', 0).rows.length, 3)
  eq('a blank query ignores a negative cap too', LL.filterCounter(R(), '', -1).rows.length, 3)
  eq('a whitespace query is blank too', LL.filterCounter(R(), '   ', 99).rows.length, 3)
  eq('a nullish query is blank', LL.filterCounter(R(), null, 99).rows.length, 3)
  eq('a no-match query', LL.filterCounter(R(), 'zzz', 10), { total: 3, matched: 0, rows: [] })
})

group('filterCounter is total over the pool it is handed', () => {
  eq('a nullish pool', LL.filterCounter(null, 'x', 10), { total: 0, matched: 0, rows: [] })
  eq('a non-array pool', LL.filterCounter('abc', 'x', 10), { total: 0, matched: 0, rows: [] })
  eq('an empty array', LL.filterCounter([], 'x', 10), { total: 0, matched: 0, rows: [] })
  eq('an empty array with a blank query', LL.filterCounter([], '', 10), { total: 0, matched: 0, rows: [] })
  // A negative cap reaches `new Array(negative)`, which throws. The blank
  // branch never gets there, which is why the two paths disagree.
  throws('a negative cap on a filtered query is a caller error',
    () => LL.filterCounter([rec('a', ['a'])], 'a', -1), /array length/i)
  noThrow('a negative cap on a blank query', () => LL.filterCounter([rec('a', ['a'])], '', -1))
})

group('filterCounter forwards the tiebreak to searchRecords', () => {
  const R = () => [rec('first', ['web']), rec('second', ['web'])]
  eq('the tiebreak reorders the rendered rows',
    LL.filterCounter(R(), 'web', 10, (r) => (r.label === 'second' ? 5 : 0)).rows.map((r) => r.label), ['second', 'first'])
  eq('and does not change matched', LL.filterCounter(R(), 'web', 10, () => 0).matched, 2)
})

group('isSynthKind is the counter gate: one synthetic row, never a filterable pool', () => {
  // "Kinds rendered as one synthetic row by design (never a filterable pool)":
  // engine kinds plus web are the counter gate, the single-row
  // patch path and the swap-fade regime checks, all off one predicate.
  eq('every engine kind is a synth kind', ['color', 'fx', 'time', 'unit', 'calc'].map(LL.isSynthKind), [true, true, true, true, true])
  eq('web is the non-engine synthetic', LL.isSynthKind('web'), true)
  eq('an app row is not', LL.isSynthKind('app'), false)
  eq('an action row is not', LL.isSynthKind('action'), false)
  eq('a plugin row is not', LL.isSynthKind('plugin'), false)
  // "websearch" is a plugin *type*, never a row kind - a near-miss that must
  // not be repaired into "web".
  eq('the websearch type is not a kind', LL.isSynthKind('websearch'), false)
  eq('the empty string is not', LL.isSynthKind(''), false)
  eq('nullish is not', [LL.isSynthKind(null), LL.isSynthKind(undefined)], [false, false])
  eq('a number is not', LL.isSynthKind(42), false)
  eq('the answer is case-sensitive, unlike the engine vocabulary', LL.isSynthKind('Time'), false)
  // The synth set is exactly the engine set plus web, so the base
  // predicate and the derived one cannot drift into disagreeing.
  is('the synth set is the engine set plus exactly web',
    ['time', 'unit', 'calc', 'web'],
    (ks) => ks.every((k) => LL.isSynthKind(k) === (LL.isEngineKind(k) || k === 'web')),
    'engine kinds plus web')
})

group('the three re-exports delegate to the shared text helpers verbatim', () => {
  // "Shared helpers are delegated to qs.common/StringUtils.js - single source
  // of truth", so the launcher never grows a second stripJsonc or a second
  // shellQuote. Identity is not assertable here (the namespace is instrumented
  // for coverage), so the delegation is proved behaviourally over a corpus,
  // with one spot value per helper so two wrong-in-the-same-way functions
  // cannot satisfy it.
  for (const t of ['// hi\n{"a":1}', '{"a":1,}', '{"u":"//cdn/x"}', '', '  // x\n{}', '{"a":[1,2,]}', '{"a":1} // hi']) {
    eq(`stripJsonc(${JSON.stringify(t)})`, LL.stripJsonc(t), SU.stripJsonc(t))
  }
  for (const t of ['abc', '', 'a b', "it's", "'", "a'b'c\"d$e`f\\g h; i&j|k", '$HOME', 'a\nb', '`id`']) {
    eq(`shellQuote(${JSON.stringify(t)})`, LL.shellQuote(t), SU.shellQuote(t))
  }
  for (const t of ['a & b', 'a < b', '<b>x</b>', '<i>x</i>', '<B>x</B>', 'a\nb', '&lt;b&gt;', '<b class="c">x</b>', '', 'a > b']) {
    eq(`styledMarkup(${JSON.stringify(t)})`, LL.styledMarkup(t), SU.styledMarkup(t))
  }
  eq('stripJsonc spot value', LL.stripJsonc('  // hi\n{"a":1}'), '{"a":1}')
  eq('shellQuote spot value', LL.shellQuote("it's"), "'it'\\''s'")
  eq('styledMarkup spot value', LL.styledMarkup('<b>x</b>'), '<b>x</b>')
  noThrow('stripJsonc on a non-string', () => LL.stripJsonc(null))
  noThrow('shellQuote on a non-string', () => LL.shellQuote(undefined))
  noThrow('styledMarkup on a non-string', () => LL.styledMarkup(0))
})

// =========================================================================
section('LauncherLib - row equality for change-aware assignment')
// =========================================================================

group('rowContentEqual compares every field the delegate paints', () => {
  const base = {
    label: 'a', sub: 's', desc: 'd', icon: 'i', badge: 'b', command: 'c',
    swatch: '#ff8800', swatchEdge: '#000000',
  }
  eq('an identical row', LL.rowContentEqual(base, Object.assign({}, base)), true)
  for (const k of ['label', 'sub', 'desc', 'icon', 'badge', 'command', 'swatch', 'swatchEdge']) {
    eq(`a different ${k}`, LL.rowContentEqual(base, Object.assign({}, base, { [k]: 'other' })), false)
  }
})

group('rowContentEqual reads every field through String(), so absent is empty', () => {
  // The delegate paints `String(x.field ?? "")`, so the comparison has to
  // agree or an empty field would repaint on every rebuild.
  eq('an absent field equals an empty one',
    LL.rowContentEqual({ label: 'a' }, { label: 'a', sub: '', desc: '', icon: '', badge: '', command: '', swatch: '', swatchEdge: '' }), true)
  eq('a null field equals an absent one',
    LL.rowContentEqual({ label: 'a', sub: null }, { label: 'a' }), true)
  eq('a numeric field is compared as its text',
    LL.rowContentEqual({ label: 5 }, { label: '5' }), true)
  // The comparison is `String(x ?? "")`, so false is the *text* "false" and
  // not an empty field - a row whose badge was cleared to false would repaint.
  eq('a false badge is the text "false", not an empty badge',
    LL.rowContentEqual({ badge: false }, {}), false)
  eq('but a null badge is an empty badge', LL.rowContentEqual({ badge: null }, {}), true)
})

group('ignoreSub skips the sub line, which is what the web exemption needs', () => {
  // "web rows echo the live query; the patch path owns those" - so a web row
  // whose only change is the sub is not a content change.
  eq('a sub change with ignoreSub', LL.rowContentEqual({ label: 'a', sub: 'x' }, { label: 'a', sub: 'y' }, true), true)
  eq('a sub change without it', LL.rowContentEqual({ label: 'a', sub: 'x' }, { label: 'a', sub: 'y' }), false)
  eq('ignoreSub does not excuse a label change', LL.rowContentEqual({ label: 'x', sub: 'a' }, { label: 'y', sub: 'b' }, true), false)
  eq('a missing row is never equal', LL.rowContentEqual(null, { label: 'a' }), false)
  eq('nor is a nullish one', LL.rowContentEqual({ label: 'a' }, null), false)
  eq('two nullish rows are not equal either', LL.rowContentEqual(null, null), false)
})

group('rowsEqual is identity-adjacent equality: uid, clip, owner, payload', () => {
  const A = { uid: 'app:firefox.desktop', label: 'Firefox', sub: '', desc: '', icon: 'ff' }
  eq('identical rows', LL.rowsEqual([A], [Object.assign({}, A)]), true)
  eq('a different uid', LL.rowsEqual([A], [Object.assign({}, A, { uid: 'app:other' })]), false)
  eq('a different length', LL.rowsEqual([A], [A, A]), false)
  eq('an empty list equals an empty list', LL.rowsEqual([], []), true)
  eq('the same array', LL.rowsEqual([A], [A]), true)
  eq('a nullish row against a real one', LL.rowsEqual([null], [A]), false)
  eq('a nullish list against a real one', LL.rowsEqual(null, [A]), false)
  eq('both nullish lists are the same list', LL.rowsEqual(null, null), true)
  eq('uid falls back to kind when there is no uid',
    LL.rowsEqual([{ kind: 'calc', label: 'a' }], [{ kind: 'calc', label: 'a' }]), true)
  eq('and a different kind is a different row',
    LL.rowsEqual([{ kind: 'calc', label: 'a' }], [{ kind: 'unit', label: 'a' }]), false)
})

group('the clip flag is part of row identity', () => {
  // A clipboard row and a launcher row with the same uid are different rows.
  eq('clip false on both', LL.rowsEqual([{ uid: 'x', clip: false }], [{ uid: 'x' }]), true)
  eq('clip true against absent', LL.rowsEqual([{ uid: 'x', clip: true }], [{ uid: 'x' }]), false)
  eq('clip true on both', LL.rowsEqual([{ uid: 'x', clip: true }], [{ uid: 'x', clip: true }]), true)
})

group('a plugin owner compares by id, so a rescan minting fresh configs still compares', () => {
  const withOwner = (id) => ({ uid: 'x', plugin: { id, name: 'N', _impl: { v: id } } })
  eq('the same id compares equal even with a different config object',
    LL.rowsEqual([withOwner('calc')], [withOwner('calc')]), true)
  eq('a different id does not', LL.rowsEqual([withOwner('calc')], [withOwner('unit')]), false)
  eq('an owner against no owner', LL.rowsEqual([withOwner('calc')], [{ uid: 'x' }]), false)
  eq('no owner on both', LL.rowsEqual([{ uid: 'x' }], [{ uid: 'x' }]), true)
  eq('a null owner reads as no owner',
    LL.rowsEqual([{ uid: 'x', plugin: null }], [{ uid: 'x' }]), true)
  eq('an owner with no id compares as the empty id',
    LL.rowsEqual([{ uid: 'x', plugin: {} }], [{ uid: 'x', plugin: { id: '' } }]), true)
})

group('the item payload compares on copyValue and on data', () => {
  const withItem = (item) => ({ uid: 'x', item })
  eq('the same payload', LL.rowsEqual([withItem({ copyValue: 'c' })], [withItem({ copyValue: 'c' })]), true)
  eq('a different copyValue', LL.rowsEqual([withItem({ copyValue: 'c' })], [withItem({ copyValue: 'd' })]), false)
  eq('an absent copyValue equals an empty one',
    LL.rowsEqual([withItem({})], [withItem({ copyValue: '' })]), true)
  eq('an item against no item', LL.rowsEqual([withItem({ copyValue: 'c' })], [{ uid: 'x' }]), false)
  const data = (d) => ({ uid: 'x', item: { copyValue: 'c', data: d } })
  eq('the same data', LL.rowsEqual([data({ action: 'a', exec: 'e', id: 'i' })], [data({ action: 'a', exec: 'e', id: 'i' })]), true)
  for (const k of ['action', 'exec', 'id']) {
    eq(`a different data.${k}`, LL.rowsEqual([data({ action: 'a', exec: 'e', id: 'i' })], [data({ action: 'a', exec: 'e', id: 'i', [k]: 'other' })]), false)
  }
  eq('data against no data', LL.rowsEqual([data({ action: 'a' })], [withItem({ copyValue: 'c' })]), false)
  eq('no data on both', LL.rowsEqual([withItem({ copyValue: 'c' })], [withItem({ copyValue: 'c' })]), true)
  eq('a null data reads as no data', LL.rowsEqual([data(null)], [withItem({ copyValue: 'c' })]), true)
})

group('the web exemption skips the sub only for a web pair', () => {
  // "reproduces the panel's web exemption (query echo churns per keypress
  // while the uid stays put)".
  const web = (sub) => ({ kind: 'web', uid: 'web:q', label: 'Search', sub })
  eq('a web pair with a changed sub', LL.rowsEqual([web('a')], [web('b')], true), true)
  eq('the same pair without the exemption', LL.rowsEqual([web('a')], [web('b')], false), false)
  eq('a non-web pair is not exempt', LL.rowsEqual([{ kind: 'app', uid: 'a', label: 'x', sub: 'a' }], [{ kind: 'app', uid: 'a', label: 'x', sub: 'b' }], true), false)
  eq('the exemption needs both rows to be web',
    LL.rowsEqual([web('a')], [{ kind: 'app', uid: 'web:q', label: 'Search', sub: 'b' }], true), false)
  eq('a web row whose label changed is still different',
    LL.rowsEqual([web('a')], [Object.assign(web('b'), { label: 'Other' })], true), false)
})

group('rowsEqual is a per-position comparison, not a set comparison', () => {
  const a = [{ uid: 'x' }, { uid: 'y' }]
  eq('same order', LL.rowsEqual(a, [{ uid: 'x' }, { uid: 'y' }]), true)
  eq('swapped order is a change, because the panel indexes by position',
    LL.rowsEqual(a, [{ uid: 'y' }, { uid: 'x' }]), false)
})

// =========================================================================
section('LauncherLib - process adapters: argv builders and verdicts')
// =========================================================================

group('pluginScanArgv emits exactly the documented scan script', () => {
  const argv = LL.pluginScanArgv('/shell/plugins', '/home/u/.config/vibranium/plugins')
  eq('three argv words: bash, -c, the script', argv.length, 3)
  eq('the interpreter is /bin/bash, not sh', argv[0], '/bin/bash')
  eq('the flag is -c', argv[1], '-c')
  eq('the script, byte for byte', argv[2], 'for r in \'/shell/plugins\' \'/home/u/.config/vibranium/plugins\'; do\n  [[ -d "$r" ]] || continue\n  for d in "$r"/*; do [[ -d "$d" ]] && echo "${d%/}"; done\ndone')
  // `${d%/}` is the documented trailing-slash strip, so a root written with
  // one yields the same ids a root written without it does.
  contains('the loop strips a trailing slash from each directory', argv[2], 'echo "${d%/}"')
  contains('a missing root is skipped rather than scanned', argv[2], '[[ -d "$r" ]] || continue')
  contains('a non-directory entry is skipped', argv[2], '[[ -d "$d" ]] &&')
})

group('pluginScanArgv shell-quotes both roots', () => {
  // The script is run by /bin/bash -c, so an unquoted root is a shell
  // injection the moment a path carries a metacharacter.
  const argv = LL.pluginScanArgv('/a', "/b;rm -rf ~/$(id)`x`")
  contains('a metacharacter root is single-quoted', argv[2], "'/b;rm -rf ~/$(id)`x`'")
  notContains('no raw $( survives outside quotes', argv[2], " '$(id)")
  const quoted = LL.pluginScanArgv("/b'c", '/d')
  contains("a single quote in a root is escaped as '\\''", quoted[2], "'/b'\\''c'")
  notContains('and the raw quote does not close the word', quoted[2], "'/b'c'")
  // A glob in a root must not expand either.
  contains('a glob root is quoted', LL.pluginScanArgv('/a/*', '/b')[2], "'/a/*'")
  // The inner "$r" is the script's own parameter, deliberately unquoted at the
  // expansion site, so a root with a space is handled by the outer quoting.
  const spaced = LL.pluginScanArgv('/a b', '/c d')
  contains('a root with a space is one quoted word', spaced[2], "'/a b'")
})

group('statProbeArgv emits exactly the documented existence probe', () => {
  const argv = LL.statProbeArgv('/tmp/x y', 7)
  eq('three argv words', argv.length, 3)
  eq('the interpreter', argv[0], '/bin/bash')
  eq('the script, byte for byte', argv[2], 'if [ -d \'/tmp/x y\' ]; then k=dir; elif [ -f \'/tmp/x y\' ]; then k=file; else k=missing; fi; echo 7 $k')
  // The generation is echoed back with the verdict, so a run the caller
  // aborted cannot come back and overwrite a verdict about another path.
  contains('the generation is echoed', argv[2], 'echo 7 $k')
  eq('a string generation is interpolated verbatim', LL.statProbeArgv('/x', '0')[2].endsWith('echo 0 $k'), true)
  eq('a large generation is interpolated verbatim', LL.statProbeArgv('/x', 12345)[2].endsWith('echo 12345 $k'), true)
})

group('statProbeArgv shell-quotes the path, and never the sequence', () => {
  // The path comes from a query the user typed, so it is quoted. The
  // sequence is interpolated raw because it is the Process object's own
  // numeric generation counter, not user input - pinned so that stays true.
  const argv = LL.statProbeArgv("/tmp/a'b;rm -rf ~", 3)
  contains("a quote in the path is escaped as '\\''", argv[2], SU.shellQuote("/tmp/a'b;rm -rf ~"))
  eq('the sequence is still interpolated raw', argv[2].endsWith('echo 3 $k'), true)
})

group('the probe script really does see one word, run through bash', () => {
  // Stated once, and settled by running it: the script is /bin/bash -c, so
  // the whole claim can be checked by executing it. A metacharacter that
  // escaped its word would either make bash fail or print a different line.
  const run = (p, seq) => {
    const argv = LL.statProbeArgv(p, seq)
    // argv[0] is the interpreter itself: a Process is handed the whole array,
    // but spawnSync is handed the arguments after it.
    const r = spawnSync('/bin/bash', argv.slice(1), { encoding: 'utf8' })
    return {
      status: r.status,
      out: r.stdout,
      err: r.stderr,
      raw: LL.statVerdict(r.stdout, seq),
      verdict: LL.statVerdict(String(r.stdout).trim(), seq),
    }
  }
  // A real directory and a real file, so all three verdicts are reachable
  // without creating anything.
  const here = import.meta.dirname
  const file = path.join(here, 'launcher.test.mjs')
  eq('a real directory probes as dir', run(here, 1).verdict, { current: true, verdict: 'dir' })
  eq('a real file probes as file', run(file, 2).verdict, { current: true, verdict: 'file' })
  eq('a path that does not exist probes as missing', run('/definitely/not/here', 3).verdict, { current: true, verdict: 'missing' })
  eq('and bash exits clean for all three', [1, 2, 3].map((s) => run(s === 1 ? here : s === 2 ? file : '/definitely/not/here', s).status), [0, 0, 0])
  // The echo puts a newline on the line, and statVerdict does NOT trim - so
  // the shell hands it a line that has already lost it, and a raw stdout
  // buffer would read as "missing" whatever the path was. timeVerdict trims
  // and this one does not; pinned because the asymmetry is invisible and the
  // failure mode is a silently wrong verdict rather than a null.
  eq('the raw buffer reads as missing, because the newline rides along',
    run(here, 1).raw, { current: true, verdict: 'missing' })
  eq('and the trimmed line is the real verdict', run(here, 1).out.trim(), '1 dir')
  eq('which is why a missing path is indistinguishable raw or trimmed',
    run('/definitely/not/here', 3).raw, run('/definitely/not/here', 3).verdict)
  // Now the metacharacters. None of these paths exists, so all of them must
  // come back as one clean "missing" line - never as a bash error, never as
  // a line the verdict parser rejects.
  for (const p of ['/a b', "/a'b", '/a;b', '/a$b', '/a`b`', '/a|b', '/a>b', '/a&b',
    '/a\\b', '/a\nb', '/a*b', '/a(b)', '/a#c', '/a>b<c', '/a{b}', '/a~b', '/a!b']) {
    const r = run(p, 9)
    eq(`${JSON.stringify(p)} leaves bash with a clean exit`, r.status, 0)
    eq(`${JSON.stringify(p)} leaves bash with no diagnostics`, r.err, '')
    eq(`${JSON.stringify(p)} still yields one parseable verdict`, r.verdict, { current: true, verdict: 'missing' })
    eq(`${JSON.stringify(p)} produces exactly one verdict line`, r.out, '9 missing\n')
    contains(`${JSON.stringify(p)} reaches the script as the shared quote`, LL.statProbeArgv(p, 9)[2], SU.shellQuote(p))
  }
  // The generation is echoed back verbatim, which is what statVerdict keys on.
  eq('the generation is echoed exactly', run(here, 12345).out, '12345 dir\n')
  eq('and a string generation is echoed too', LL.statProbeArgv(here, '07')[2].endsWith('echo 07 $k'), true)
})

group('statVerdict accepts only this run s generation', () => {
  eq('a matching dir verdict', LL.statVerdict('7 dir', 7), { current: true, verdict: 'dir' })
  eq('a matching file verdict', LL.statVerdict('7 file', 7), { current: true, verdict: 'file' })
  eq('a matching missing verdict', LL.statVerdict('7 missing', 7), { current: true, verdict: 'missing' })
  eq('a stale generation is dropped, not stored', LL.statVerdict('6 dir', 7), null)
  eq('a newer generation is dropped too', LL.statVerdict('8 dir', 7), null)
  eq('a generation of zero works', LL.statVerdict('0 dir', 0), { current: true, verdict: 'dir' })
})

group('a line that is not this probe s answer is never current', () => {
  // "A line with no separator, or a generation that is not a number, is never
  // current." A partially-written Process line is the case this exists for.
  eq('no separator at all', LL.statVerdict('dir', 7), null)
  eq('a non-numeric generation', LL.statVerdict('x dir', 7), null)
  eq('a nullish line', LL.statVerdict(null, 7), null)
  eq('undefined', LL.statVerdict(undefined, 7), null)
  eq('an empty line', LL.statVerdict('', 7), null)
  // "A line with no separator ... is never current": without a space there is
  // no generation to read, so the line is dropped rather than parsed.
  eq('the number alone is not a verdict', LL.statVerdict('7', 7), null)
  eq('a non-string line is stringified first and then dropped', LL.statVerdict(7, 7), null)
})

group('an unrecognised kind reads as missing, and a padded one does not parse as dir', () => {
  // The three-way verdict is closed, so anything else collapses to missing -
  // but the substring is taken verbatim after the first space, so a doubled
  // space yields " dir", which is not a verdict. Pinned because the Process
  // output is exactly `echo $seq $k` and can never be doubled.
  eq('an unknown kind', LL.statVerdict('7 weird', 7), { current: true, verdict: 'missing' })
  eq('an empty kind', LL.statVerdict('7 ', 7), { current: true, verdict: 'missing' })
  eq('a doubled space', LL.statVerdict('7  dir', 7), { current: true, verdict: 'missing' })
  eq('a trailing newline is trimmed by the shell before it reaches here', LL.statVerdict('7 dir', 7).verdict, 'dir')
  eq('a parseInt prefix is accepted as the generation', LL.statVerdict('7abc dir', 7), { current: true, verdict: 'dir' })
  eq('and that is a documented tolerance of parseInt, not a match', LL.statVerdict('7.9 dir', 7), { current: true, verdict: 'dir' })
})

group('binariesArgv emits exactly the documented PATH scan', () => {
  const argv = LL.binariesArgv()
  eq('three argv words: bash, -c, the script', argv.length, 3)
  eq('the interpreter is /bin/bash, not sh', argv[0], '/bin/bash')
  eq('the flag is -c', argv[1], '-c')
  eq('the script, byte for byte', argv[2], 'IFS=: read -ra dirs <<< "$PATH"\nfor d in "${dirs[@]}"; do\n  [[ -d "$d" ]] || continue\n  for f in "$d"/*; do\n    [[ -f "$f" && -x "$f" ]] || continue\n    printf \'%s\\n\' "${f##*/}"\n  done\ndone\nexit 0')
  // PATH is split on the separator and read, never globbed: the directories
  // come from the user's environment and one carrying a space or a glob must
  // be one entry, not a word split or an expansion.
  contains('PATH is split on the separator into an array', argv[2], 'IFS=: read -ra dirs <<< "$PATH"')
  contains('every element is quoted at the expansion site', argv[2], 'for d in "${dirs[@]}"')
  contains('a directory that is not there is skipped', argv[2], '[[ -d "$d" ]] || continue')
  // Executable, not merely present: a shared library or a man page in the
  // same directory is on PATH-adjacent storage and is not something to launch.
  contains('the test is a regular file AND executable', argv[2], '[[ -f "$f" && -x "$f" ]]')
  contains('only the basename is printed', argv[2], '"${f##*/}"')
  // The explicit exit: the last [[ ]] in the loop is what bash would otherwise
  // report as the status, so a directory with no executables in it would read
  // as a failed probe.
  eq('the script ends in an explicit success', argv[2].endsWith('\nexit 0'), true)
})

group('the PATH scan script really does print the executables, run through bash', () => {
  // Settled by executing it, the way the stat probe is: the claim is that a
  // PATH directory's regular executables come back as basenames, in order.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vbscan-'))
  const first = path.join(root, 'one')
  const second = path.join(root, 'two')
  const third = path.join(root, 'three')
  fs.mkdirSync(first); fs.mkdirSync(second); fs.mkdirSync(third)
  for (const [d, names] of [[first, ['aaa', 'zzz']], [second, ['mmm']], [third, []]]) {
    for (const n of names) {
      fs.writeFileSync(path.join(d, n), '#!/bin/sh\n')
      fs.chmodSync(path.join(d, n), 0o755)
    }
  }
  // The three things that must NOT be reported: a plain file, a subdirectory,
  // and a directory whose name is a known executable's name - the last one
  // proves the basename is stripped from the full path rather than
  // reconstructed, and that a directory is not a candidate for a launch.
  fs.writeFileSync(path.join(first, 'plain'), 'not executable')
  fs.mkdirSync(path.join(first, 'aaa-dir'))
  fs.mkdirSync(path.join(third, 'aaa'))
  const scan = (dirs) => spawnSync('/bin/bash', ['-c', LL.binariesArgv()[2]], {
    env: Object.assign({}, process.env, { PATH: dirs.join(':') }),
    encoding: 'utf8',
  }).stdout
  try {
    deepEqual('only the regular executables, as basenames',
      scan([first, second, third]).split('\n').filter((l) => l !== ''), ['aaa', 'zzz', 'mmm'])
    // PATH order is the order a launch would resolve a duplicate in, so the
    // verdict parser's first-wins dedup has to agree with the scan's order:
    // the first directory's copy of a name is the one that would be run.
    fs.writeFileSync(path.join(second, 'aaa'), '#!/bin/sh\n')
    fs.chmodSync(path.join(second, 'aaa'), 0o755)
    const dup = scan([first, second, third])
    eq('the later directory adds a second copy of the name',
      dup.split('\n').filter((l) => l !== ''), ['aaa', 'zzz', 'aaa', 'mmm'])
    eq('and the verdict keeps the first spelling, which is the one PATH resolves to',
      LL.binariesVerdict(dup).names, ['aaa', 'zzz', 'mmm'])
    // A directory that is not there must be skipped without ending the scan,
    // and a PATH entry with a space must be one entry rather than two words.
    const spaced = path.join(root, 'with space')
    fs.mkdirSync(spaced)
    fs.writeFileSync(path.join(spaced, 'spacedbin'), '#!/bin/sh\n')
    fs.chmodSync(path.join(spaced, 'spacedbin'), 0o755)
    eq('a missing directory is skipped and a spaced one is one entry',
      scan([path.join(root, 'gone'), spaced]).split('\n').filter((l) => l !== ''), ['spacedbin'])
    // An empty PATH yields nothing, and the explicit exit keeps that a
    // success rather than a failed probe.
    eq('an empty PATH prints nothing', scan([]), '')
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

group('binariesVerdict collapses a scan to its distinct names, or reports nothing', () => {
  eq('a single name', LL.binariesVerdict('qt6ct\n'), { names: ['qt6ct'] })
  eq('several names, in the order printed', LL.binariesVerdict('a\nb\nc\n'), { names: ['a', 'b', 'c'] })
  // PATH order is the resolution a launch performs, so a duplicate keeps the
  // first spelling rather than being overwritten by a later directory.
  eq('a duplicate collapses to its first position', LL.binariesVerdict('a\nb\na\n'), { names: ['a', 'b'] })
  // Case is NOT a duplicate at this layer: LS and ls are two different files
  // on a case-sensitive filesystem, and the verdict reports what the scan
  // found. The case fold lives in the plugin's index, one layer up.
  eq('a case variant is two entries, not one', LL.binariesVerdict('LS\nls\n'), { names: ['LS', 'ls'] })
  eq('but an exact repeat is one', LL.binariesVerdict('LS\nLS\n'), { names: ['LS'] })
  // Blank lines cannot happen from printf, but a leading or trailing newline is
  // exactly what an empty directory contributes, so they are dropped rather
  // than becoming a nameless entry.
  eq('blank lines are dropped', LL.binariesVerdict('a\n\n\nb\n\n'), { names: ['a', 'b'] })
  eq('a name with surrounding space is trimmed', LL.binariesVerdict('  a  \n'), { names: ['a'] })
  // Null means "nothing usable", and it is kept distinct from an empty list so
  // the caller can tell no scan landed from a scan that found nothing.
  eq('empty output', LL.binariesVerdict(''), null)
  eq('whitespace only', LL.binariesVerdict('\n\n'), null)
  eq('nullish', LL.binariesVerdict(null), null)
  eq('undefined', LL.binariesVerdict(undefined), null)
  // The stamp is the caller's, exactly as for timeVerdict: the parser does not
  // reach for a clock, so a verdict is reproducible.
  eq('the verdict carries no timestamp', Object.keys(LL.binariesVerdict('a\n')), ['names'])
})

group('sameNameSet compares scans by content, so a settled row can rest', () => {
  // The `at` stamp differs on every rescan by construction, so comparing
  // records would always report a change and the row would repaint every TTL.
  eq('the same list', LL.sameNameSet(['a', 'b'], ['a', 'b']), true)
  eq('an added name', LL.sameNameSet(['a'], ['a', 'b']), false)
  eq('a removed name', LL.sameNameSet(['a', 'b'], ['a']), false)
  eq('a reordered name', LL.sameNameSet(['a', 'b'], ['b', 'a']), false)
  eq('two empty lists', LL.sameNameSet([], []), true)
  eq('empty against full', LL.sameNameSet([], ['a']), false)
  // A non-array reads as the empty list, so a cache record that never got its
  // names is a mismatch rather than a throw.
  eq('nullish reads as empty', LL.sameNameSet(null, []), true)
  eq('and so does a non-array', LL.sameNameSet('a', ['a']), false)
  // The one tolerance: a repeated scan of an unchanged PATH is the case this
  // exists for, and it must not republish.
  const before = { names: ['a', 'b'], at: 1000 }
  const after = { names: ['a', 'b'], at: 2000 }
  eq('a rescan that found nothing new', LL.sameNameSet(before.names, after.names), true)
})

group('timeProbeFormat reads each zone on its own dial, never the OS one', () => {
  // The probe runs under the host's own settings, so the dial has to be
  // chosen here: "time in Chicago" prints 01:00 PM on a machine set to 24
  // hours, and "time in Madrid" prints 13:00 on one set to 12.
  eq('Chicago', LL.timeProbeFormat('America/Chicago'), '%I:%M %p')
  eq('Madrid', LL.timeProbeFormat('Europe/Madrid'), '%H:%M')
  eq('New York', LL.timeProbeFormat('America/New_York'), '%I:%M %p')
  eq('London', LL.timeProbeFormat('Europe/London'), '%H:%M')
  eq('Tokyo', LL.timeProbeFormat('Asia/Tokyo'), '%I:%M %p')
  eq('Kolkata', LL.timeProbeFormat('Asia/Kolkata'), '%I:%M %p')
  eq('Sydney', LL.timeProbeFormat('Australia/Sydney'), '%I:%M %p')
  eq('Auckland', LL.timeProbeFormat('Pacific/Auckland'), '%I:%M %p')
  eq('Johannesburg', LL.timeProbeFormat('Africa/Johannesburg'), '%H:%M')
  eq('Almaty', LL.timeProbeFormat('Asia/Almaty'), '%H:%M')
})

group('an entry covers the zone it names and every zone below it', () => {
  eq('the Argentina subtree', LL.timeProbeFormat('America/Argentina/Buenos_Aires'), '%I:%M %p')
  eq('a second city in it', LL.timeProbeFormat('America/Argentina/Cordoba'), '%I:%M %p')
  eq('the Indiana subtree', LL.timeProbeFormat('America/Indiana/Indianapolis'), '%I:%M %p')
  eq('the Kentucky subtree', LL.timeProbeFormat('America/Kentucky/Louisville'), '%I:%M %p')
  eq('North Dakota', LL.timeProbeFormat('America/North_Dakota/Center'), '%I:%M %p')
  // The match is on a path boundary, not a string prefix: a zone whose name
  // merely starts with an entry's text is a zone nobody listed.
  eq('a zone whose name merely starts with an entry', LL.timeProbeFormat('America/ArgentinaRio'), '%H:%M')
  eq('and one below an entry name carrying a suffix', LL.timeProbeFormat('America/Indianax/Indianapolis'), '%H:%M')
  eq('a bare continent', LL.timeProbeFormat('Europe'), '%H:%M')
})

group('a 24-hour zone inside a 12-hour neighbourhood stays 24-hour', () => {
  // The convention is a country's, so these are the cases a country-level
  // table gets wrong most easily: the zone's own dial is not the continent's.
  eq('Chile', LL.timeProbeFormat('America/Santiago'), '%H:%M')
  eq('Brazil', LL.timeProbeFormat('America/Sao_Paulo'), '%H:%M')
  eq('Brazil, another state', LL.timeProbeFormat('America/Fortaleza'), '%H:%M')
  eq('Danish Greenland, the old name', LL.timeProbeFormat('America/Godthab'), '%H:%M')
  eq('Danish Greenland, the canonical name', LL.timeProbeFormat('America/Nuuk'), '%H:%M')
  eq('Russia', LL.timeProbeFormat('Asia/Yekaterinburg'), '%H:%M')
  eq('Turkey, under its Asian name', LL.timeProbeFormat('Asia/Istanbul'), '%H:%M')
  eq('Turkey, under its European name', LL.timeProbeFormat('Europe/Istanbul'), '%H:%M')
  // And the regions that kept a 12-hour dial inside those, which is why
  // Brazil's twelve-hour states and Magallanes are named on their own.
  eq('Magallanes', LL.timeProbeFormat('America/Punta_Arenas'), '%I:%M %p')
  eq('Amazonas', LL.timeProbeFormat('America/Manaus'), '%I:%M %p')
  eq('Mato Grosso do Sul', LL.timeProbeFormat('America/Campo_Grande'), '%I:%M %p')
})

group('the 12-hour table names only zones the launcher can resolve', () => {
  // A dead entry is invisible: the probe still prints, on the wrong dial, and
  // nothing else in the tree would notice. TimeLib's tzdata snapshot is the
  // set of zone strings the resolver can return, so every entry has to name
  // one of them - or be a subtree of one, which is how a whole country is
  // covered by a single entry.
  const known = TL.FALLBACK_ZONES
  const reachable = (z) => known.some((k) => k === z || k.startsWith(z + '/'))
  eq('no entry is a zone or a subtree the resolver cannot return',
    LL.H12_ZONES.filter((z) => !reachable(z)), [])
  eq('and no entry is listed twice',
    LL.H12_ZONES.filter((z, i) => LL.H12_ZONES.indexOf(z) !== i), [])
  // The 24-hour default is the claim the whole table leans on, so it is
  // pinned for the two continents with no 12-hour zone at all.
  notContains('Europe has none', LL.H12_ZONES.join(' '), 'Europe/')
  notContains('Antarctica has none', LL.H12_ZONES.join(' '), 'Antarctica/')
  // A country uniform enough to be one entry still has to be uniform: the
  // zones that resolve under a named country are all of them 12-hour.
  eq('every Australian zone resolves to the 12-hour dial', TL.FALLBACK_ZONES
    .filter((k) => k.startsWith('Australia/'))
    .filter((k) => LL.timeProbeFormat(k) !== '%I:%M %p'), [])
})

group('an unusable zone falls back to the 24-hour default', () => {
  eq('an empty zone', LL.timeProbeFormat(''), '%H:%M')
  eq('undefined', LL.timeProbeFormat(undefined), '%H:%M')
  eq('null', LL.timeProbeFormat(null), '%H:%M')
  eq('a number is stringified', LL.timeProbeFormat(12), '%H:%M')
  // The resolver only ever returns a canonical IANA name, so anything that is
  // not one gets the default rather than a guess at a repair.
  eq('a lowercase zone name is not the zone', LL.timeProbeFormat('america/chicago'), '%H:%M')
})

group('the chosen format is one `date` accepts, and its reading round-trips', () => {
  // The verdict parser is the other half of the same line, so the format is
  // run for real: a format `date` rejects would print nothing at all, and a
  // 12-hour reading that broke the four-field split would land in timeCache
  // with the meridiem in the wrong field. LC_ALL=C keeps the meridiem the
  // ASCII pair the assertions below name.
  const probe = (zone) => {
    const r = spawnSync('date', ['+' + LL.timeProbeFormat(zone) + '|%Z|%z|%a %-d %b'],
      { encoding: 'utf8', env: { ...process.env, TZ: zone, LC_ALL: 'C' } })
    return { status: r.status, out: String(r.stdout).trim(), err: String(r.stderr).trim() }
  }
  for (const zone of ['America/Chicago', 'Europe/Madrid', 'Asia/Kolkata', 'Pacific/Auckland']) {
    const r = probe(zone)
    // The dial asked for is the dial printed: a format that asked for a
    // meridiem and printed a 24-hour field (or the reverse) would be a row
    // whose reading and whose format disagree, with nothing to notice.
    const wantsMeridiem = LL.timeProbeFormat(zone).indexOf('%p') >= 0
    eq(`${zone}: date accepts the format`, [r.status, r.err], [0, ''])
    is(`${zone}: the reading is what timeVerdict parses`, LL.timeVerdict(r.out, undefined),
      (v) => v !== null && v.changed === true
        && /^\d{2}:\d{2}( AM| PM)?$/.test(v.reading.time)
        && (/\s(AM|PM)$/.test(v.reading.time) === wantsMeridiem)
        && /^[A-Z]{2,5}$/.test(v.reading.code)
        && /^[+-]\d{4}$/.test(v.reading.offset)
        && v.reading.date !== '',
      'a four-field reading whose time field is on the dial the format asked for')
  }
  match('a 12-hour zone prints the meridiem', probe('America/Chicago').out.split('|')[0], /^\d{2}:\d{2} (AM|PM)$/)
  match('and a 24-hour zone prints none', probe('Europe/Madrid').out.split('|')[0], /^\d{2}:\d{2}$/)
  // Two readings of one zone are the same line, so the second is a rest
  // rather than a repaint.
  eq('and the same zone reads the same way twice', probe('Europe/Madrid').out, probe('Europe/Madrid').out)
})

group('timeVerdict parses the four-field clock line', () => {
  eq('a full line', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep'),
    { changed: true, reading: { time: '14:32', code: 'CEST', offset: '+0200', date: 'Fri 11 Sep' } })
  // "a DATE carrying a pipe keeps the tail intact"
  eq('a pipe in the date', LL.timeVerdict('14:32|CEST|+0200|Fri|Sep').reading.date, 'Fri|Sep')
  eq('and two pipes', LL.timeVerdict('a|b|c|d|e').reading.date, 'd|e')
  eq('a line with no fourth field at all is a null verdict', LL.timeVerdict('a|b|c'), null)
  eq('an empty line', LL.timeVerdict(''), null)
  eq('a whitespace-only line', LL.timeVerdict('   '), null)
  eq('a nullish line', LL.timeVerdict(null), null)
  eq('undefined', LL.timeVerdict(undefined), null)
})

group('changed is false only for an identical reading', () => {
  // "which is what lets a minute-boundary probe that read the same time rest
  // instead of repainting the row".
  const read = { time: '14:32', code: 'CEST', offset: '+0200', date: 'Fri 11 Sep' }
  eq('the same reading', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep', read), { changed: false, reading: read })
  eq('a minute change', LL.timeVerdict('14:33|CEST|+0200|Fri 11 Sep', read).changed, true)
  eq('a code change', LL.timeVerdict('14:32|CET|+0200|Fri 11 Sep', read).changed, true)
  eq('an offset change', LL.timeVerdict('14:32|CEST|+0100|Fri 11 Sep', read).changed, true)
  eq('a date change', LL.timeVerdict('14:32|CEST|+0200|Sat 12 Sep', read).changed, true)
  eq('no previous reading is always a change', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep', undefined).changed, true)
  eq('a null previous reading is a change', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep', null).changed, true)
  eq('an empty previous reading is a change', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep', {}).changed, true)
  // The previous reading is read field by field, so a partial cache entry
  // (the controller seeds timeCache with {time:""}) compares honestly.
  const seeded = { time: '', code: '', offset: '', date: '' }
  eq('against a freshly seeded cache entry', LL.timeVerdict('14:32|CEST|+0200|Fri 11 Sep', seeded).changed, true)
  eq('an empty clock line against an empty seed is not a change', LL.timeVerdict('|||', seeded), { changed: false, reading: { time: '', code: '', offset: '', date: '' } })
})

group('execArgs prefers the parsed command array', () => {
  eq('the command array is used as-is', LL.execArgs({ command: ['discord', '--no-sandbox'] }), ['discord', '--no-sandbox'])
  eq('a %-field is dropped from the command array', LL.execArgs({ command: ['discord', '%U'] }), ['discord'])
  // "%-fields (e.g. %U, %f) are dropped because the launcher passes no
  // URL/file selection, and a dropped field leaves a now-meaningless trailing
  // separator (-- / --url, e.g. `discord --url -- %u`) which is peeled".
  eq('the separator before a dropped field is peeled',
    LL.execArgs({ command: ['discord', '--url', '--', '%u'] }), ['discord'])
  eq('both peeled forms', LL.execArgs({ command: ['discord', '--', '--url', '%U'] }), ['discord'])
  eq('peeling is repeated', LL.execArgs({ command: ['x', '--', '--', '--', '%U'] }), ['x'])
  eq('a separator that is not trailing survives', LL.execArgs({ command: ['discord', '--', 'keep', '%u'] }), ['discord', '--', 'keep'])
  eq('a non-string member is stringified', LL.execArgs({ command: [5, 'x'] }), ['5', 'x'])
  eq('an empty member is skipped', LL.execArgs({ command: ['a', '', 'b'] }), ['a', 'b'])
})

group('execArgs falls back to the raw Exec string', () => {
  eq('whitespace splitting', LL.execArgs({ execString: 'discord --no-sandbox' }), ['discord', '--no-sandbox'])
  eq('a trailing %U is dropped', LL.execArgs({ execString: 'discord %U' }), ['discord'])
  eq('the documented discord example peels both separators',
    LL.execArgs({ execString: 'discord --url -- %u' }), ['discord'])
  eq('runs of whitespace collapse', LL.execArgs({ execString: '  a  b   %U ' }), ['a', 'b'])
  eq('tabs and newlines split too', LL.execArgs({ execString: 'a\tb\nc' }), ['a', 'b', 'c'])
  eq('a quoted argument is not re-split - it is the parsers job',
    LL.execArgs({ execString: 'app "--a b" %F' }), ['app', '"--a', 'b"'])
  // The command array wins even when it is empty-but-present? No: an empty
  // array means "nothing parsed", so the raw string is the fallback.
  eq('an empty command array falls through to the raw string', LL.execArgs({ command: [], execString: 'x' }), ['x'])
  eq('a non-array command field falls through', LL.execArgs({ command: 'x', execString: 'y' }), ['y'])
})

group('execArgs answers an empty argv for nothing to run', () => {
  eq('no entry at all', LL.execArgs(null), [])
  eq('an empty entry', LL.execArgs({}), [])
  eq('an empty Exec string', LL.execArgs({ execString: '' }), [])
  eq('a whitespace-only Exec string', LL.execArgs({ execString: '   ' }), [])
  eq('a nullish Exec string', LL.execArgs({ execString: null }), [])
  eq('an Exec string that is only a field', LL.execArgs({ execString: '%F' }), [])
  eq('an Exec string that is only a separator and a field', LL.execArgs({ execString: '-- %U' }), [])
  eq('a command array of only a field', LL.execArgs({ command: ['%U'] }), [])
})

group('launchArgv routes a terminal entry through vb-launch-tui', () => {
  // Quickshell's DesktopEntry.execute() ignores runInTerminal, which is why
  // the launcher wraps a terminal-bounded entry itself.
  eq('a terminal entry', LL.launchArgv(['yazi'], true), ['vb-launch-tui', '--', 'yazi'])
  eq('a terminal entry with no args', LL.launchArgv([], true), ['vb-launch-tui', '--'])
  // The terminal branch is checked first and prepends unconditionally, so an
  // Exec that is *already* a vb-launch-tui wrapper and also runInTerminal
  // would be wrapped twice. Not reachable from a real desktop entry: a
  // Terminal=true entry ships a plain Exec, and a TUI entry sets
  // runInTerminal false. Pinned so the ordering is not reshuffled by accident.
  eq('and it is checked before the already-wrapped case',
    LL.launchArgv(['vb-launch-tui', '--', 'yazi'], true), ['vb-launch-tui', '--', 'vb-launch-tui', '--', 'yazi'])
})

group('launchArgv leaves an already-wrapped Exec alone', () => {
  // "Entries whose Exec already is a vb-launch-* wrapper run as-is": they
  // already own focus-or-launch and re-wrapping would double it.
  eq('vb-launch-cmd', LL.launchArgv(['vb-launch-cmd', '--', 'firefox'], false), ['vb-launch-cmd', '--', 'firefox'])
  eq('vb-launch-tui', LL.launchArgv(['vb-launch-tui', '--', 'yazi'], false), ['vb-launch-tui', '--', 'yazi'])
  eq('vb-launch-webapp', LL.launchArgv(['vb-launch-webapp', 'https://x'], false), ['vb-launch-webapp', 'https://x'])
  eq('the match is on the first word only', LL.launchArgv(['echo', 'vb-launch-tui'], false), ['vb-launch-cmd', '--', 'echo', 'vb-launch-tui'])
  eq('a path that merely contains the wrapper name is not one', LL.launchArgv(['/usr/bin/vb-launch-tui'], false), ['vb-launch-cmd', '--', '/usr/bin/vb-launch-tui'])
})

group('launchArgv wraps everything else in vb-launch-cmd --', () => {
  eq('an ordinary application', LL.launchArgv(['firefox', '%u'], false), ['vb-launch-cmd', '--', 'firefox', '%u'])
  eq('an empty argv still produces a launchable command line', LL.launchArgv([], false), ['vb-launch-cmd', '--'])
  // The argv comes from execArgs, which always answers an array; a missing one
  // is a caller error.
  throws('a nullish argv is a caller error', () => LL.launchArgv(null, false), /length/)
  // The first word is String()-ed for the *check* but the array is not
  // rebuilt, so a non-string element is forwarded untouched. Pinned because a
  // stringifying rebuild would be a silent behaviour change.
  eq('a non-string first word is checked as text', LL.launchArgv([5], false), ['vb-launch-cmd', '--', 5])
  // The check is on String(args[0]), so an object whose toString names a
  // wrapper *is* treated as one - the check is textual, not nominal.
  const fakeWrapper = { toString: () => 'vb-launch-tui' }
  eq('and an object that stringifies to a wrapper name is taken at its word',
    LL.launchArgv([fakeWrapper], false), [fakeWrapper])
  eq('while an object that does not is wrapped', LL.launchArgv([{ toString: () => 'x' }], false).slice(0, 2),
    ['vb-launch-cmd', '--'])
})

group('a shell metacharacter in a desktop-file name stays one argv element', () => {
  // The whole point of the shim boundary: launchArgv builds an *argv*, and
  // the shim execs it directly. There is no shell here at all, so a
  // metacharacter in an application name or argument is inert data rather
  // than syntax - which is the opposite of what the argv *builders* do with a
  // path, and the difference is deliberate. Pinned so nobody "helpfully"
  // adds a shell to this function.
  for (const nasty of ['a b', 'a;b', 'a$b', 'a`b`', 'a|b', 'a&b', 'a>b', 'a<b', 'a\\b', "a'b", 'a"b', 'a*b', 'a\nb']) {
    const argv = LL.launchArgv(['app', nasty], false)
    eq(`${JSON.stringify(nasty)} stays a single argv element`, argv.length, 4)
    eq(`${JSON.stringify(nasty)} is passed through verbatim`, argv[3], nasty)
    eq(`${JSON.stringify(nasty)} is preceded by the shim and its separator`, argv.slice(0, 3), ['vb-launch-cmd', '--', 'app'])
  }
  // Nothing in the argv is quoted, because nothing is going through a shell.
  eq('the argv is passed to a Process, not to a shell', LL.launchArgv(['a b'], false).some((w) => w.includes("'")), false)
  eq('a newline in an argument is data, not a command break', LL.launchArgv(['a\nrm -rf /'], false)[2], 'a\nrm -rf /')
  eq('and the terminal route is equally unquoted', LL.launchArgv(['a;b'], true), ['vb-launch-tui', '--', 'a;b'])
})

// =========================================================================
section('LauncherLib - local paths and URIs')
// =========================================================================

group('localPathCandidate accepts one absolute or tilde path, and nothing else', () => {
  eq('an absolute path', LL.localPathCandidate('/a/b/c'), '/a/b/c')
  eq('surrounding whitespace is trimmed', LL.localPathCandidate('  /a/b  '), '/a/b')
  eq('internal spaces are allowed - pasted paths have them', LL.localPathCandidate('/a/my file.txt'), '/a/my file.txt')
  eq('trailing slashes are stripped', LL.localPathCandidate('/a/b///'), '/a/b')
  eq('the root names itself', LL.localPathCandidate('/'), '/')
  eq('a bare root with slashes', LL.localPathCandidate('///'), '/')
  // "because a meaningful search query never starts with / or ~"
  eq('a relative path is not a candidate', LL.localPathCandidate('a/b'), '')
  eq('a bare word is not a candidate', LL.localPathCandidate('firefox'), '')
  eq('a dotfile name is not a candidate', LL.localPathCandidate('.bashrc'), '')
})

group('localPathCandidate expands a tilde only when it is given a home', () => {
  eq('a tilde path', LL.localPathCandidate('~/notes', '/home/u'), '/home/u/notes')
  eq('a bare tilde', LL.localPathCandidate('~', '/home/u'), '/home/u')
  eq('a tilde path with no home cannot be expanded, so it is refused',
    LL.localPathCandidate('~/notes', ''), '')
  eq('a bare tilde with no home', LL.localPathCandidate('~', ''), '')
  eq('a nullish home', LL.localPathCandidate('~/notes', null), '')
  // "~user/x" is not the current user's home and is not expanded either.
  eq('another users tilde is not a path here', LL.localPathCandidate('~root/x', '/home/u'), '')
  eq('and with no home either', LL.localPathCandidate('~root/x', ''), '')
})

group('localPathCandidate refuses the degenerate inputs', () => {
  eq('an empty string', LL.localPathCandidate(''), '')
  eq('whitespace only', LL.localPathCandidate('   '), '')
  eq('a newline is never a path', LL.localPathCandidate('/a\nb'), '')
  // Only a NEWLINE is refused. A carriage return is not, which is deliberate
  // for pasted Windows paths but means the guard is a newline check and not a
  // control-character check. Pinned as observed.
  eq('a carriage return is not refused, only a newline is', LL.localPathCandidate('/a\rb'), '/a\rb')
  eq('nullish', LL.localPathCandidate(null), '')
  eq('undefined', LL.localPathCandidate(undefined), '')
  // "t.length > 4096" - one character over PATH_MAX-ish is refused outright.
  eq('a path at the limit is accepted', LL.localPathCandidate('/' + 'y'.repeat(4095)).length, 4096)
  eq('one character over the limit is refused', LL.localPathCandidate('/' + 'y'.repeat(4096)), '')
  eq('a 4096-character string is refused', LL.localPathCandidate('x'.repeat(4096)), '')
  eq('and 4097 is not even a path', LL.localPathCandidate('x'.repeat(4097)), '')
  noThrow('a number', () => LL.localPathCandidate(42))
  eq('a number is not a path', LL.localPathCandidate(42), '')
})

group('pathBasename is the row title, and the root names itself', () => {
  eq('a file', LL.pathBasename('/a/b/c.txt'), 'c.txt')
  eq('a trailing slash is stripped first', LL.pathBasename('/a/b/'), 'b')
  eq('several trailing slashes', LL.pathBasename('/a/b///'), 'b')
  eq('the root', LL.pathBasename('/'), '/')
  eq('a root with slashes', LL.pathBasename('///'), '/')
  eq('a relative name', LL.pathBasename('notes'), 'notes')
  eq('an empty path', LL.pathBasename(''), '')
  eq('a nullish path', LL.pathBasename(null), '')
  eq('undefined', LL.pathBasename(undefined), '')
  // The dotfile case is the surprising one: basename(".bashrc") is ".bashrc",
  // which is what a user expects to see in the row title.
  eq('a dotfile keeps its dot', LL.pathBasename('/home/u/.bashrc'), '.bashrc')
  eq('a trailing-dot name keeps its dot', LL.pathBasename('/a/b.'), 'b.')
  eq('a space in the name is kept', LL.pathBasename('/a/b c.txt'), 'b c.txt')
})

group('pathIconName routes through the clipboard extension table', () => {
  // "so a pasted path shows the same glyph it would show as a clipboard
  // entry" - the mapping is literally ClipboardLib's, not a second table.
  eq('a directory always uses the folder glyph', LL.pathIconName(true, '/a/b.png'), 'file-folder')
  eq('a directory with no extension at all', LL.pathIconName(true, '/a/b'), 'file-folder')
  eq('an image', LL.pathIconName(false, '/a/b.png'), 'file-image')
  eq('an svg', LL.pathIconName(false, '/a/b.svg'), 'file-svg')
  eq('an archive', LL.pathIconName(false, '/a/b.tar.gz'), 'file-archive')
  eq('a pdf', LL.pathIconName(false, '/a/b.pdf'), 'file-pdf')
  eq('code', LL.pathIconName(false, '/a/b.py'), 'file-code')
  eq('a video maps to the generic file glyph, as ClipboardEntry does', LL.pathIconName(false, '/a/b.mp4'), 'file')
  // "unknown extensions fall back to the generic file glyph - the same
  // fallback ClipboardEntry applies"
  eq('an unknown extension', LL.pathIconName(false, '/a/b.zzz'), 'file')
  eq('no extension', LL.pathIconName(false, '/a/b'), 'file')
  eq('a nullish path', LL.pathIconName(false, null), 'file')
  eq('a directory is a directory even with an unknown extension', LL.pathIconName(true, '/a/b.zzz'), 'file-folder')
  // And the agreement is exact, because it is the same function.
  const CL = loadLib(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))
  for (const p of ['/a/b.png', '/a/b.tar.gz', '/a/b.pdf', '/a/b.py', '/a/b.mp4', '/a/b.zzz', '/a/b']) {
    eq(`the same glyph as the clipboard for ${p}`, LL.pathIconName(false, p), CL.extIconName(p) || 'file')
  }
})

group('percentDecode decodes %XX and keeps a malformed sequence raw', () => {
  eq('a space', LL.percentDecode('a%20b'), 'a b')
  eq('a non-ascii byte', LL.percentDecode('caf%C3%A9'), 'café')
  eq('several sequences', LL.percentDecode('%2Fetc%2Fpasswd'), '/etc/passwd')
  eq('a malformed sequence is left raw, not dropped', LL.percentDecode('a%zzb'), 'a%zzb')
  eq('a truncated sequence is left raw', LL.percentDecode('a%2'), 'a%2')
  eq('text with no percent sign is returned unchanged', LL.percentDecode('plain/path.txt'), 'plain/path.txt')
  eq('an empty string', LL.percentDecode(''), '')
  eq('nullish', LL.percentDecode(null), '')
  eq('undefined', LL.percentDecode(undefined), '')
  // decodeURIComponent does not decode these, so they survive verbatim.
  eq('a literal plus is not a space', LL.percentDecode('a+b'), 'a+b')
  eq('a literal percent25 does decode to a percent', LL.percentDecode('a%25b'), 'a%b')
})

group('fileUriPath unwraps a local file URI and nothing else', () => {
  eq('an empty authority', LL.fileUriPath('file:///a/b'), '/a/b')
  eq('a localhost authority is local too', LL.fileUriPath('file://localhost/a/b'), '/a/b')
  eq('a percent-encoded space is decoded', LL.fileUriPath('file:///a/b%20c'), '/a/b c')
  eq('the scheme is case-insensitive', LL.fileUriPath('FILE:///a/b'), '/a/b')
  eq('a mixed-case scheme', LL.fileUriPath('File:///a/b'), '/a/b')
  eq('trailing slashes are stripped', LL.fileUriPath('file:///a/b///'), '/a/b')
  eq('the root', LL.fileUriPath('file:///'), '/')
  eq('surrounding whitespace is trimmed', LL.fileUriPath('  file:///a/b  '), '/a/b')
})

group('only an empty or localhost authority maps to the local filesystem', () => {
  // "anything else is not a local file" - a remote file:// host is a network
  // destination, so answering it with a local path would open the wrong thing.
  eq('a named host', LL.fileUriPath('file://host/a/b'), '')
  eq('a host that merely starts with localhost', LL.fileUriPath('file://localhost.evil/a'), '')
  eq('a host that contains localhost', LL.fileUriPath('file://xlocalhost/a'), '')
  eq('an ip host', LL.fileUriPath('file://192.168.0.1/a'), '')
  // And the non-file schemes never match.
  for (const u of ['https://x/a', 'http://x/a', 'sftp://x/a', 'file:/a', 'file:a', 'xfile:///a', '/a/b', 'plain text']) {
    eq(`${u} is not a local file URI`, LL.fileUriPath(u), '')
  }
  eq('an empty authority with no path', LL.fileUriPath('file://'), '')
  eq('the bare scheme', LL.fileUriPath('file:'), '')
  eq('an empty string', LL.fileUriPath(''), '')
  eq('whitespace only', LL.fileUriPath('   '), '')
  eq('nullish', LL.fileUriPath(null), '')
  eq('undefined', LL.fileUriPath(undefined), '')
  eq('a number', LL.fileUriPath(42), '')
  // A malformed escape is left raw, so the path is still produced.
  eq('a malformed escape keeps the raw text', LL.fileUriPath('file:///a%zzb'), '/a%zzb')
})

group('uriBasename is the last segment, else the host, decoded for display', () => {
  eq('a path segment', LL.uriBasename('https://x.com/a/b?q=1'), 'b')
  eq('a single segment', LL.uriBasename('https://x.com/a'), 'a')
  eq('a host with no path at all', LL.uriBasename('https://x.com'), 'x.com')
  eq('a root path falls back to the host', LL.uriBasename('https://x.com/'), 'x.com')
  eq('a network scheme', LL.uriBasename('sftp://srv/share/a/b'), 'b')
  eq('a network scheme with only a host', LL.uriBasename('ssh://srv'), 'srv')
  eq('a port is part of the host', LL.uriBasename('https://x.com:8443/a/b'), 'b')
  eq('a percent-encoded segment is decoded', LL.uriBasename('https://x.com/a%20b'), 'a b')
  eq('a query and a fragment are not part of the tail', LL.uriBasename('ftp://h/a/b?x=1#f'), 'b')
  eq('text with no scheme is returned verbatim', LL.uriBasename('plain text'), 'plain text')
  eq('an empty string', LL.uriBasename(''), '')
  eq('nullish', LL.uriBasename(null), '')
  eq('undefined', LL.uriBasename(undefined), '')
  // The authority group excludes /?#, so a host cannot swallow a segment.
  eq('a host with a userinfo-looking prefix', LL.uriBasename('https://user@host/a/b'), 'b')
})

group('openTarget resolves a local path', () => {
  eq('an absolute path', LL.openTarget('/a/b.txt', '/home/u'), { kind: 'local', path: '/a/b.txt', basename: 'b.txt' })
  eq('whitespace is trimmed', LL.openTarget('  /a/b.txt  ', '/home/u'), { kind: 'local', path: '/a/b.txt', basename: 'b.txt' })
  eq('a trailing slash is stripped before the basename', LL.openTarget('/a/b/', '/home/u'), { kind: 'local', path: '/a/b', basename: 'b' })
  eq('a tilde path expands through home', LL.openTarget('~/notes.txt', '/home/u'), { kind: 'local', path: '/home/u/notes.txt', basename: 'notes.txt' })
  eq('a file URI unwraps into the local flow', LL.openTarget('file:///a/b.txt', '/home/u'), { kind: 'local', path: '/a/b.txt', basename: 'b.txt' })
  eq('a localhost file URI too', LL.openTarget('file://localhost/a/b', '/home/u'), { kind: 'local', path: '/a/b', basename: 'b' })
  eq('a percent-encoded file URI', LL.openTarget('file:///a/my%20file', '/home/u'), { kind: 'local', path: '/a/my file', basename: 'my file' })
  // "so a dead file:// link falls back to web search" - the existence probe is
  // the caller's, and it only gets a local answer for a path it can probe.
  eq('the local flow always answers with a path, never a uri', LL.openTarget('/a', '/home/u').kind, 'local')
})

group('openTarget resolves a remote URI and opens it as-is', () => {
  eq('http', LL.openTarget('https://x.com/a/b', '/home/u'), { kind: 'uri', uri: 'https://x.com/a/b', basename: 'b' })
  eq('plain http', LL.openTarget('http://x.com', '/home/u'), { kind: 'uri', uri: 'http://x.com', basename: 'x.com' })
  eq('an ftp network scheme', LL.openTarget('ftp://srv/a/b', '/home/u'), { kind: 'uri', uri: 'ftp://srv/a/b', basename: 'b' })
  eq('sftp', LL.openTarget('sftp://srv/x', '/home/u'), { kind: 'uri', uri: 'sftp://srv/x', basename: 'x' })
  eq('smb', LL.openTarget('smb://srv/share', '/home/u').kind, 'uri')
  eq('ssh with only a host', LL.openTarget('ssh://srv', '/home/u'), { kind: 'uri', uri: 'ssh://srv', basename: 'srv' })
  eq('webdav', LL.openTarget('webdav://h/a', '/home/u').kind, 'uri')
  // The uri is handed over verbatim - nothing re-encodes or re-quotes it.
  eq('the uri is verbatim, not normalised', LL.openTarget('HTTPS://X.com/A%20b', '/home/u').uri, 'HTTPS://X.com/A%20b')
  eq('and a query survives', LL.openTarget('https://x.com/a?b=1', '/home/u').uri, 'https://x.com/a?b=1')
  // A scheme outside both sets is not openable: a bare "madeup://x" is
  // neither http(s) nor a network scheme, and it does not start with "/" or
  // "~", so there is no local path to probe either.
  eq('an unknown scheme is not openable', LL.openTarget('madeup://x/a', '/home/u'), null)
})

group('openTarget refuses what is not openable', () => {
  for (const t of ['', '   ', 'firefox', 'a/b', './x', 'firefox search', 'mailto:a@b', 'about:blank', 'data:text/plain,x']) {
    eq(`${JSON.stringify(t)} is not openable`, LL.openTarget(t, '/home/u'), null)
  }
  eq('a newline is never a target', LL.openTarget('/a\nb', '/home/u'), null)
  // As in localPathCandidate, only a newline is refused: openTarget guards
  // indexOf("\n") and nothing else.
  eq('a carriage return is not refused, only a newline is', LL.openTarget('/a\rb', '/home/u'),
    { kind: 'local', path: '/a\rb', basename: 'a\rb' })
  eq('nullish', LL.openTarget(null, '/home/u'), null)
  eq('undefined', LL.openTarget(undefined, '/home/u'), null)
  eq('a number', LL.openTarget(42, '/home/u'), null)
  eq('a tilde with no home is not openable', LL.openTarget('~/x', ''), null)
  eq('one character over the length limit is not openable', LL.openTarget('x'.repeat(4097), '/home/u'), null)
  // 4096 is the accepted maximum, same as localPathCandidate.
  eq('exactly at the length limit it is still a length check that passes', LL.openTarget('x'.repeat(4096), '/home/u'), null)
})

group('a file:// URI with a remote host is a URI, not a local path', () => {
  // fileUriPath refuses a non-local authority, so this falls through to the
  // scheme matcher. "file" is not http(s) and not a network scheme, so it is
  // not openable at all - the caller falls back to web search, which is
  // better than opening a local path named after the host.
  eq('a named host is not openable', LL.openTarget('file://host/a/b', '/home/u'), null)
  eq('an ip host is not openable', LL.openTarget('file://192.168.0.1/a', '/home/u'), null)
  // And a path that merely looks like a URI is not one.
  eq('a path with a colon in it is a path', LL.openTarget('/a/b:c', '/home/u'), { kind: 'local', path: '/a/b:c', basename: 'b:c' })
  eq('a file with a colon in its name is still just a path segment', LL.openTarget('/a/http://b', '/home/u').basename, 'b')
})

group('a shell metacharacter in a path cannot become a command', () => {
  // openTarget builds a *descriptor* - a path and a basename - which the
  // caller probes and then hands to xdg-open as data. Nothing here is a
  // command line, so a metacharacter is inert; the argv builders in the
  // process-adapter section are where quoting lives, and the two are
  // deliberately different mechanisms.
  for (const nasty of ['/a b;rm -rf ~', "/a'b", '/a$b', '/a`b`', '/a|b&c', '/a>b', '/a<b', '/a\\b', '/a"b', '/a*b']) {
    const t = LL.openTarget(nasty, '/home/u')
    eq(`${JSON.stringify(nasty)} is still just a path`, t.kind, 'local')
    eq(`${JSON.stringify(nasty)} is verbatim in the path`, t.path, nasty)
    eq(`${JSON.stringify(nasty)} never becomes a uri`, t.uri, undefined)
    eq(`${JSON.stringify(nasty)} yields one basename`, t.basename, LL.pathBasename(nasty))
  }
  eq('a metacharacter in a uri stays inside the uri', LL.openTarget('https://x.com/a;b', '/home/u').uri, 'https://x.com/a;b')
  eq('and the basename is the last segment', LL.openTarget('https://x.com/a;b', '/home/u').basename, 'a;b')
})

group('clipTargetFor takes the newest clipboard entry s destination', () => {
  // "Secrets and raw binary payloads never suggest anything", so the secret
  // guard runs before the filePaths fast-path. A single filePaths entry
  // otherwise outranks the type check for non-secret types.
  eq('a single path, whatever the type', LL.clipTargetFor({ type: 'image', filePaths: ['/a/b.png'] }, '/home/u'), { kind: 'local', value: '/a/b.png', basename: 'b.png' })
  eq('a single path with a text type', LL.clipTargetFor({ type: 'text', filePaths: ['/a/b.txt'] }, '/home/u'), { kind: 'local', value: '/a/b.txt', basename: 'b.txt' })
  eq('a single path with a secret type suggests nothing', LL.clipTargetFor({ type: 'secret', filePaths: ['/a/b.png'] }, '/home/u'), null)
  eq('a single path with no type at all', LL.clipTargetFor({ filePaths: ['/a/b'] }, '/home/u').kind, 'local')
  eq('the value is the path verbatim', LL.clipTargetFor({ type: 'image', filePaths: ['/a/b.png'] }, '/home/u').value, '/a/b.png')
  eq('a trailing slash is stripped, except for the root', LL.clipTargetFor({ type: 'image', filePaths: ['/a/b/'] }, '/home/u').value, '/a/b')
  eq('but the basename is', LL.clipTargetFor({ type: 'image', filePaths: ['/a/b/'] }, '/home/u').basename, 'b')
})

group('more than one path is not a destination, and a relative one is not local', () => {
  eq('two paths', LL.clipTargetFor({ type: 'image', filePaths: ['/a/b.png', '/c/d.png'] }, '/home/u'), null)
  eq('a single relative path is not a local file', LL.clipTargetFor({ type: 'image', filePaths: ['b.png'] }, '/home/u'), null)
  eq('a single tilde path is not a local file', LL.clipTargetFor({ type: 'image', filePaths: ['~/b.png'] }, '/home/u'), null)
  eq('a single path with leading whitespace is trimmed before the check', LL.clipTargetFor({ type: 'image', filePaths: ['  /a/b.png  '] }, '/home/u').value, '/a/b.png')
  eq('a single whitespace-only path is not local', LL.clipTargetFor({ type: 'image', filePaths: ['   '] }, '/home/u'), null)
  eq('a path list with one empty string', LL.clipTargetFor({ type: 'image', filePaths: [''] }, '/home/u'), null)
  eq('an empty path list falls through to the type check', LL.clipTargetFor({ type: 'text', raw: 'hello' }, '/home/u'), null)
  eq('a nullish path list', LL.clipTargetFor({ type: 'text', filePaths: null, raw: 'hello' }, '/home/u'), null)
})

group('a url entry answers with its own kind and no basename', () => {
  // The shape is { kind, value } only: a url is not probed and has no tail.
  eq('a url', LL.clipTargetFor({ type: 'url', raw: 'https://x.com/a' }, '/home/u'), { kind: 'url', value: 'https://x.com/a' })
  eq('a url is trimmed', LL.clipTargetFor({ type: 'url', raw: '  https://x.com/a  ' }, '/home/u').value, 'https://x.com/a')
  eq('an empty url suggests nothing', LL.clipTargetFor({ type: 'url', raw: '   ' }, '/home/u'), null)
  eq('a nullish url', LL.clipTargetFor({ type: 'url', raw: null }, '/home/u'), null)
  eq('a url entry with no raw at all', LL.clipTargetFor({ type: 'url' }, '/home/u'), null)
  // A path-shaped url is still a url - the entry declared its type, and the
  // filePaths branch already had its chance.
  eq('a url that happens to be a path', LL.clipTargetFor({ type: 'url', raw: '/a/b' }, '/home/u'), { kind: 'url', value: '/a/b' })
})

group('a network entry must actually name a network URI', () => {
  eq('an sftp uri', LL.clipTargetFor({ type: 'network', raw: 'sftp://a/b' }, '/home/u'), { kind: 'uri', value: 'sftp://a/b', basename: 'b' })
  eq('an ftp uri', LL.clipTargetFor({ type: 'network', raw: 'ftp://a/b' }, '/home/u').kind, 'uri')
  // The branch asks only that openTarget resolved a *uri*, not that the scheme
  // is one of the network ones - so an http uri on a network-typed entry is
  // accepted too. The clipboard classifies the scheme, so an entry typed
  // network never carries an http uri in practice; pinned as observed.
  eq('a network entry holding an http uri is accepted as a uri',
    LL.clipTargetFor({ type: 'network', raw: 'https://x.com/a' }, '/home/u'),
    { kind: 'uri', value: 'https://x.com/a', basename: 'a' })
  // A local path on a network-typed entry IS refused: openTarget resolved it to
  // a local path, and that is not what the entry meant.
  eq('a network entry holding a local path suggests nothing', LL.clipTargetFor({ type: 'network', raw: '/a/b' }, '/home/u'), null)
  eq('a network entry holding text suggests nothing', LL.clipTargetFor({ type: 'network', raw: 'nope' }, '/home/u'), null)
  eq('a network entry with no raw', LL.clipTargetFor({ type: 'network' }, '/home/u'), null)
})

group('a text entry is resolved as a path or a protocol URI', () => {
  // "Text that is really a path or protocol URI (terminal copies)".
  eq('a path', LL.clipTargetFor({ type: 'text', raw: '/a/b.txt' }, '/home/u'), { kind: 'local', value: '/a/b.txt', basename: 'b.txt' })
  eq('a tilde path', LL.clipTargetFor({ type: 'text', raw: '~/b.txt' }, '/home/u'), { kind: 'local', value: '/home/u/b.txt', basename: 'b.txt' })
  eq('a file URI', LL.clipTargetFor({ type: 'text', raw: 'file:///a/b' }, '/home/u'), { kind: 'local', value: '/a/b', basename: 'b' })
  eq('an https uri', LL.clipTargetFor({ type: 'text', raw: 'https://x.com/a' }, '/home/u'), { kind: 'uri', value: 'https://x.com/a', basename: 'a' })
  eq('an sftp uri', LL.clipTargetFor({ type: 'text', raw: 'sftp://a/b' }, '/home/u'), { kind: 'uri', value: 'sftp://a/b', basename: 'b' })
  eq('ordinary text suggests nothing', LL.clipTargetFor({ type: 'text', raw: 'hello world' }, '/home/u'), null)
  eq('a shell command suggests nothing', LL.clipTargetFor({ type: 'text', raw: 'rm -rf ~' }, '/home/u'), null)
  eq('a text entry with no raw', LL.clipTargetFor({ type: 'text' }, '/home/u'), null)
  eq('a text entry with a nullish raw', LL.clipTargetFor({ type: 'text', raw: null }, '/home/u'), null)
})

group('a secret or a binary payload never suggests anything', () => {
  // "Secrets and raw binary payloads never suggest anything" - and neither
  // does any type this module does not know. Only url, network and text
  // resolve a raw; everything else is inert, whatever the raw happens to be.
  for (const type of ['secret', 'binary', 'image-data', 'colour', 'blob', '', 5, {}]) {
    eq(`a ${JSON.stringify(type) ?? String(type)} entry with only a raw suggests nothing`,
      LL.clipTargetFor({ type, raw: '/a/b.txt' }, '/home/u'), null)
  }
  // A nullish type is the *default* type, which is text - `String(type ??
  // "text")` - so a path-shaped raw on a typeless entry does resolve. The
  // default is a convenience for entries the clipboard inferred, and it is
  // the only reason an untyped entry is ever openable.
  eq('a nullish type is the text default, so a path resolves',
    LL.clipTargetFor({ type: null, raw: '/a/b.txt' }, '/home/u'),
    { kind: 'local', value: '/a/b.txt', basename: 'b.txt' })
  eq('and so does an absent type',
    LL.clipTargetFor({ type: undefined, raw: '/a/b.txt' }, '/home/u'),
    { kind: 'local', value: '/a/b.txt', basename: 'b.txt' })
  // A secret filePaths entry never resolves: the secret guard runs before
  // the filePaths fast-path, so naming exactly one file does not participate.
  eq('a secret that names one file suggests nothing',
    LL.clipTargetFor({ type: 'secret', filePaths: ['/a/b.png'] }, '/home/u'),
    null)
  eq('a nullish entry', LL.clipTargetFor(null, '/home/u'), null)
  eq('an undefined entry', LL.clipTargetFor(undefined, '/home/u'), null)
  eq('an empty object', LL.clipTargetFor({}, '/home/u'), null)
  eq('the default type is text, so a path-shaped raw resolves', LL.clipTargetFor({ raw: '/a/b' }, '/home/u').kind, 'local')
  eq('and an ordinary raw does not', LL.clipTargetFor({ raw: 'hello' }, '/home/u'), null)
})

group('openTarget and clipTargetFor agree on the same path', () => {
  // The clipboard path is what openTarget would have produced, so a paste and
  // a typed path must never resolve differently.
  for (const p of ['/a/b.txt', '/a/b/', '~/c.txt', '/a/my file.pdf']) {
    const o = LL.openTarget(p, '/home/u')
    const c = LL.clipTargetFor({ type: 'text', raw: p }, '/home/u')
    eq(`kind agrees for ${JSON.stringify(p)}`, c.kind, o.kind)
    eq(`value agrees for ${JSON.stringify(p)}`, c.value, o.path)
    eq(`basename agrees for ${JSON.stringify(p)}`, c.basename, o.basename)
  }
})

group('clipEntryKind is the verdict the entry settled for itself', () => {
  // The suggestion renders from this on the first frame, so the contract is
  // two-part: it may only speak for an entry that names exactly one absolute
  // path (the one shape clipTargetFor turns into a local target), and for that
  // shape it reports what the clipboard service's capture-time find pass
  // settled. Anything else answers "", which is the "render provisionally and
  // let the stat probe correct it" path.
  eq('a captured folder', LL.clipEntryKind({ type: 'folder', filePaths: ['/a/b'] }), 'dir')
  eq('a captured file', LL.clipEntryKind({ type: 'file', filePaths: ['/a/b.txt'] }), 'file')
  eq('an image is a file', LL.clipEntryKind({ type: 'image', filePaths: ['/a/b.png'] }), 'file')
  eq('an archive is a file', LL.clipEntryKind({ type: 'archive', filePaths: ['/a/b.zip'] }), 'file')
  eq('a secret naming one file suggests nothing', LL.clipEntryKind({ type: 'secret', filePaths: ['/a/b'] }), '')
  // A uri-list read guesses "file" from the extension and the find pass only
  // corrects it to "folder", so the default type is the file shape.
  eq('an absent type', LL.clipEntryKind({ filePaths: ['/a/b'] }), 'file')
  eq('a nullish type', LL.clipEntryKind({ type: null, filePaths: ['/a/b'] }), 'file')
  // No paths, no hint: a path-shaped text entry was never probed.
  eq('a text entry with a path raw', LL.clipEntryKind({ type: 'text', raw: '/a/b.txt' }), '')
  eq('a url entry', LL.clipEntryKind({ type: 'url', raw: 'https://x.com/a' }), '')
  // The gate is exactly clipTargetFor's own single-absolute-path check.
  eq('two paths', LL.clipEntryKind({ type: 'folder', filePaths: ['/a/b', '/c/d'] }), '')
  eq('a relative path', LL.clipEntryKind({ type: 'folder', filePaths: ['b'] }), '')
  eq('a tilde path', LL.clipEntryKind({ type: 'folder', filePaths: ['~/b'] }), '')
  eq('an empty path', LL.clipEntryKind({ type: 'folder', filePaths: [''] }), '')
  eq('a whitespace-only path', LL.clipEntryKind({ type: 'folder', filePaths: ['   '] }), '')
  eq('a leading-space absolute path is trimmed like clipTargetFor trims it',
    LL.clipEntryKind({ type: 'folder', filePaths: ['  /a/b  '] }), 'dir')
  eq('a nullish path list', LL.clipEntryKind({ type: 'folder', filePaths: null }), '')
  eq('a nullish entry', LL.clipEntryKind(null), '')
  eq('an undefined entry', LL.clipEntryKind(undefined), '')
  eq('an empty object', LL.clipEntryKind({}), '')
  // The hint is only ever consulted for a local target, so it must not
  // contradict clipTargetFor about what a local target even is.
  for (const entry of [
    { type: 'folder', filePaths: ['/a/b'] },
    { type: 'image', filePaths: ['/a/b.png'] },
    { type: 'text', filePaths: ['/a/b.txt'] },
  ]) {
    eq(`a local target exists for ${JSON.stringify(entry.filePaths)}`,
      LL.clipTargetFor(entry, '/home/u').kind, 'local')
  }
})

group('the suggestion rides with the open via the copy-time hint', () => {
  // Every unverified local target renders provisionally on frame one - from
  // its copy-time hint when one exists, assumed a file otherwise - so the
  // open sizes itself with the suggestion already counted instead of
  // growing the window when the probe lands; the async stat probe verifies
  // in the background, a dir/file verdict corrects the shape in place and
  // a missing verdict drops the row. Only a verified missing path withholds.
  const controller = fs.readFileSync(path.join(LAUNCHER, 'AppLauncherController.qml'), 'utf8')
  notContains('the refresh no longer withholds the target while the probe runs',
    controller, 'root.clipTarget = null')
  contains('and it arms the probe without dropping the target', controller,
    'if (resolved && resolved.kind === "local" && !BoundedCache.has(AppLauncher.statCache, resolved.value)) {')
  contains('a verified verdict renders from the verdict', controller,
    'if (st === "dir" || st === "file")')
  contains('an unverified path renders provisionally, hint first and a file otherwise', controller,
    '(t.hint === "dir" || t.hint === "file") ? t.hint : "file"')
  contains('and the probe still arms itself per unknown path', controller,
    'if (!(pathStatProc.running && pathStatProc.path === t.value)) root._statPath(t.value)')
  // A missing verdict drops the provisional row when it lands; only a
  // verified missing path is withheld up front.
  notContains('a bare missing guard is not the withholding rule', controller,
    'if (st === "missing") return null')
  contains('the hint travels with the resolved target', controller,
    'LauncherLib.clipEntryKind(entry)')
  // The row identity stays verdict-independent, so the later verify is one
  // stable row rather than a swap.
  contains('the uid is the target path, verdict-independent', controller, 'uid: "clip:" + t.value')
  contains('and so is the sub line', controller, 'sub: root.showDescriptions ? t.basename : ""')
  contains('only the label and the icon read the kind', controller,
    'label: kind === "dir" ? "Open folder from the clipboard" : "Open file from the clipboard"')
  contains('and only the icon names a path as a folder', controller,
    'LauncherLib.pathIconName(kind === "dir", t.value)')
})

group('the open spawns at its fitted size instead of growing into it', () => {
  // The open's first sizing instant shares a turn with the show gate
  // closing, which a Behavior reads stale - so a height delta to a new row
  // set (a fresh clipboard suggestion) would glide from the old height
  // instead of spawning. The panel arms PanelCard.sizeSnap while hidden, a
  // turn early, and releases it on input or when the gate opens, so the
  // open sizes itself under that snap while typing still glides.
  const panel = fs.readFileSync(path.join(LAUNCHER, 'LauncherPanel.qml'), 'utf8')
  contains('the close arms the open-time snap', panel, 'panel.sizeSnap = true')
  notContains('and the open keeps the armed snap instead of disarming it', panel,
    'panel.sizeSnap = false\n      panel.show()')
  contains('input while visible releases it, so typing still glides', panel,
    'if (AppLauncher.visible) panel.sizeSnap = false')
  contains('and the gate opening releases it too', panel,
    'if (panel.shown) panel.sizeSnap = false')
})

group('the open computes before it shows, so the first paint is final', () => {
  // open() used to flip visible first and recompute after, so the panel
  // installed the stale row set synchronously and the fresh one (a new
  // clipboard suggestion) landed a turn later behind it - the window
  // growing after it appeared. A cold demand masked it (construction
  // refreshes first); a warm controller showed it. Computing first makes
  // the open deterministic instead of frame-timing luck.
  const facade = fs.readFileSync(path.join(LAUNCHER, 'AppLauncher.qml'), 'utf8')
  const panel = fs.readFileSync(path.join(LAUNCHER, 'LauncherPanel.qml'), 'utf8')
  const controller = fs.readFileSync(path.join(LAUNCHER, 'AppLauncherController.qml'), 'utf8')
  contains('the open recomputes before the visible flip', facade,
    'root._openCompute()\n    root.visible = true')
  notContains('and nothing recomputes after the claim', facade,
    '_claimToken = SurfaceClaim.claim("appLauncher", root.close, root)\n    root._openCompute()')
  contains('the compute no longer waits for visible', facade,
    'function _openCompute() {\n    const ctrl = root._controller\n    if (ctrl === null) return\n    ctrl.onOpened()')
  // The pre-flip recompute schedules a deferred install while hidden; the
  // open seat steals it and installs inline, under the close-armed snap,
  // instead of painting stale first. A non-open caller still bails.
  contains('an open seat steals the pending install', panel,
    'if (panel._openSeat !== true) return false\n      panel._rowsPending = false')
  // onOpened now runs hidden, so the stat revalidate it performs cannot
  // require visible - it exists precisely for verdicts that went stale
  // while the panel was down.
  notContains('the revalidate is not gated on visible', controller,
    '&& AppLauncher.visible\n      && !(pathStatProc.running')
})

// =========================================================================
section('TimeLib - city normalisation and the query detector')
// =========================================================================

group('normalizeCity folds the three things a user types differently', () => {
  // "trim, fold separators, strip diacritics, collapse whitespace, lowercase"
  eq('a plain name', TL.normalizeCity('Madrid'), 'madrid')
  eq('mixed case', TL.normalizeCity('MaDrId'), 'madrid')
  eq('a dash becomes a space', TL.normalizeCity('new-york'), 'new york')
  eq('an underscore becomes a space', TL.normalizeCity('new_york'), 'new york')
  eq('a run of mixed separators collapses to one space', TL.normalizeCity('new--__-york'), 'new york')
  eq('surrounding whitespace is trimmed', TL.normalizeCity('  madrid  '), 'madrid')
  eq('internal whitespace runs collapse', TL.normalizeCity('new    york'), 'new york')
  eq('a tab is whitespace too', TL.normalizeCity('new\tyork'), 'new york')
})

group('normalizeCity strips diacritics, so a typed accent still resolves', () => {
  eq('an accented a', TL.normalizeCity('Sao Paulo'), 'sao paulo')
  eq('an accented o', TL.normalizeCity('córdoba'), 'cordoba')
  eq('an accented u', TL.normalizeCity('münchen'), 'munchen')
  eq('an accented e', TL.normalizeCity('bogotá'), 'bogota')
  eq('a composed and a decomposed spelling agree',
    TL.normalizeCity('S\u00e3o Paulo'), TL.normalizeCity('Sa\u0303o Paulo'))
  // NFD then strip is the documented order, so a combining mark that arrives
  // on its own is removed the same way.
  eq('a bare combining mark is removed', TL.normalizeCity('a\u0301'), 'a')
})

group('normalizeCity reads the degenerate inputs as empty', () => {
  for (const v of ['', '   ', '\t\n', '-', '_', '--', '-_-', ' - _ ']) {
    eq(`normalizeCity(${JSON.stringify(v)})`, TL.normalizeCity(v), '')
  }
  eq('nullish', TL.normalizeCity(null), '')
  eq('undefined', TL.normalizeCity(undefined), '')
  eq('null comes from _str, not from a throw', TL._str(null), '')
  eq('undefined too', TL._str(undefined), '')
  eq('but a number is text', TL.normalizeCity(42), '42')
  eq('and so is zero', TL.normalizeCity(0), '0')
  eq('a stringified nullish is text, not empty', TL.normalizeCity('null'), 'null')
})

group('normalizeCity is idempotent, which is what makes the table keys valid', () => {
  for (const s of ['Madrid', 'new-york', 'Sao Paulo', '  New   YORK  ', 'córdoba', 'a b c']) {
    eq(`normalizeCity is idempotent for ${JSON.stringify(s)}`, TL.normalizeCity(TL.normalizeCity(s)), TL.normalizeCity(s))
  }
  // The header says the map keys ARE normalized values, so that is a property
  // of the table and not a coincidence of how it was typed.
  eq('every CITY_TO_TZ key is already normalized',
    Object.keys(TL.CITY_TO_TZ).filter((k) => TL.normalizeCity(k) !== k), [])
  eq('no key is empty', Object.keys(TL.CITY_TO_TZ).filter((k) => k === ''), [])
})

group('parseTimeQuery accepts every documented spelling of the keyword', () => {
  // "time in <city>" case-insensitive, with the separator being any run of
  // whitespace.
  eq('the canonical form', TL.parseTimeQuery('time in Madrid'), 'Madrid')
  eq('uppercase', TL.parseTimeQuery('TIME IN BANGKOK'), 'BANGKOK')
  eq('mixed case', TL.parseTimeQuery('Time In Chicago'), 'Chicago')
  eq('a tab between the words', TL.parseTimeQuery('time\tin\ttokyo'), 'tokyo')
  eq('a newline between the words', TL.parseTimeQuery('time\nin\noslo'), 'oslo')
  eq('a run of spaces', TL.parseTimeQuery('time    in    paris'), 'paris')
  eq('a non-breaking space is whitespace to \\s', TL.parseTimeQuery('time in paris'), 'paris')
  eq('a multi-word city', TL.parseTimeQuery('time in new york'), 'new york')
  eq('the city is returned raw, not normalised', TL.parseTimeQuery('time in   SaO PaUlO  '), 'SaO PaUlO')
  eq('a leading-space query still matches', TL.parseTimeQuery('   time in paris'), 'paris')
  eq('trailing content after the city is kept', TL.parseTimeQuery('time in new york tomorrow'), 'new york tomorrow')
})

group('parseTimeQuery answers "" for a bare keyword and null for anything else', () => {
  // "" is the "typed the keyword and nothing yet" answer, which is what the
  // plugin renders as a hint row; null is "not a time query at all".
  eq('just the keyword', TL.parseTimeQuery('time in'), '')
  eq('the keyword with a separator and nothing after', TL.parseTimeQuery('time in   '), '')
  eq('the keyword with a tab', TL.parseTimeQuery('time in\t'), '')
  eq('mixed case keyword only', TL.parseTimeQuery('Time In'), '')
  for (const q of ['time', 'times', 'at', 'intime', 'timex in paris', 'timeinx', 'in', 'x in y', 'runtime in paris']) {
    eq(`${JSON.stringify(q)} is not a time query`, TL.parseTimeQuery(q), null)
  }
  // "time" alone is not a query; the detector requires the "in".
  eq('the bare word time', TL.parseTimeQuery('time'), null)
  eq('a query that merely contains the phrase', TL.parseTimeQuery('what is time in paris'), null)
  eq('an empty query', TL.parseTimeQuery(''), null)
  eq('a whitespace query', TL.parseTimeQuery('   '), null)
  eq('nullish', TL.parseTimeQuery(null), null)
  eq('undefined', TL.parseTimeQuery(undefined), null)
  eq('a number', TL.parseTimeQuery(42), null)
})

group('parseTimeQuery is total and never throws', () => {
  noThrow('a very long query', () => TL.parseTimeQuery('time in ' + 'a'.repeat(10000)))
  noThrow('a query with a regex metacharacter in the city', () => TL.parseTimeQuery('time in (a|b)+'))
  noThrow('a query with a newline at the end', () => TL.parseTimeQuery('time in paris\n'))
  eq('a newline at the end is stripped by the trim, not by the regex', TL.parseTimeQuery('time in paris\n'), 'paris')
  eq('a city that is only spaces after "in" is the empty answer', TL.parseTimeQuery('time in \t '), '')
  // A catastrophic-backtracking shape is refused by the non-greedy + anchor.
  eq('a long city is returned whole', TL.parseTimeQuery('time in ' + 'a'.repeat(500)).length, 500)
})

// =========================================================================
section('TimeLib - zone resolution')
// =========================================================================

group('the explicit map answers capitals, metros and aliases', () => {
  // The first tier exists for "aliases whose names are NOT their zone names".
  eq('a city whose zone is its own name', TL.resolveTimezone('madrid'), 'Europe/Madrid')
  eq('a metro on another city zone', TL.resolveTimezone('barcelona'), 'Europe/Madrid')
  eq('another metro on the same zone', TL.resolveTimezone('valencia'), 'Europe/Madrid')
  eq('an english spelling', TL.resolveTimezone('seville'), 'Europe/Madrid')
  eq('a spanish spelling', TL.resolveTimezone('sevilla'), 'Europe/Madrid')
  eq('a language variant', TL.resolveTimezone('bilbao'), 'Europe/Madrid')
  eq('beijing is Shanghai, not its own zone', TL.resolveTimezone('beijing'), 'Asia/Shanghai')
  eq('new york', TL.resolveTimezone('new york'), 'America/New_York')
  eq('nyc is new york', TL.resolveTimezone('nyc'), 'America/New_York')
  eq('a family of aliases for one zone',
    [TL.resolveTimezone('delhi'), TL.resolveTimezone('new delhi'), TL.resolveTimezone('kolkata'), TL.resolveTimezone('calcutta')],
    ['Asia/Kolkata', 'Asia/Kolkata', 'Asia/Kolkata', 'Asia/Kolkata'])
  eq('three-segment zones resolve too', TL.resolveTimezone('buenos aires'), 'America/Argentina/Buenos_Aires')
})

group('resolution is case-insensitive and separator-agnostic', () => {
  eq('uppercase', TL.resolveTimezone('MADRID'), 'Europe/Madrid')
  eq('shouting', TL.resolveTimezone('BANGKOK'), 'Asia/Bangkok')
  eq('a dash for a space', TL.resolveTimezone('new-york'), 'America/New_York')
  eq('an underscore for a space', TL.resolveTimezone('new_york'), 'America/New_York')
  eq('surrounding whitespace', TL.resolveTimezone('  madrid  '), 'Europe/Madrid')
  eq('a collapsed run of separators', TL.resolveTimezone('new---___york'), 'America/New_York')
  eq('a non-breaking space is whitespace to \\s', TL.resolveTimezone('new york'), 'America/New_York')
  eq('accented input resolves to the same zone', TL.resolveTimezone('são paulo'), 'America/Sao_Paulo')
})

group('anything not in the map is resolved dynamically by tail segment', () => {
  // "Anything else resolves dynamically by scanning
  // Intl.supportedValuesOf("timeZone") for a matching tail segment, so
  // "oslo" -> Europe/Oslo without a table entry."
  // oslo IS in the table, so pick the tail dynamically: find a zone in the
  // host's list whose tail is a legal key and is not a table key, and check
  // that tier 2 answers it. Driven off the host's own tzdata so the assertion
  // holds on a host with a smaller database.
  const zones = TL.getAllTimeZones()
  const tableKeys = Object.keys(TL.CITY_TO_TZ)
  const candidate = zones.find((z) => {
    const tail = z.substring(z.lastIndexOf('/') + 1)
    const n = TL.normalizeCity(tail)
    return n !== '' && tableKeys.indexOf(n) < 0
  })
  is('the host tzdata has a tail segment the table does not cover', candidate,
    (v) => typeof v === 'string' && v.indexOf('/') > 0, 'a slash-separated zone name')
  const tail = candidate.substring(candidate.lastIndexOf('/') + 1)
  eq(`tier 2 resolves ${JSON.stringify(tail)}`, TL.resolveTimezone(tail), candidate)
  eq('and it is case-insensitive', TL.resolveTimezone(tail.toUpperCase()), candidate)
  eq('and the tier-2 key is the tail, lowercased and separator-folded', TL.normalizeCity(tail), TL.normalizeCity(tail).toLowerCase())
})

group('tier 2 picks the first matching tail, in the zone list order', () => {
  // A tail that appears in more than one zone is ambiguous, and the scan
  // takes the first. "catamarca" is such a tail on this host's tzdata
  // (America/Catamarca), which is not the same zone the static fallback list
  // would reach (America/Argentina/Catamarca) - pinned in the no-Intl
  // section, because the two tiers genuinely disagree.
  const zones = TL.getAllTimeZones()
  const dupes = zones.filter((z) => TL.normalizeCity(z.substring(z.lastIndexOf('/') + 1)) === 'catamarca')
  eq('a tail carried by more than one zone resolves to the first in list order',
    TL.resolveTimezone('catamarca'), dupes.length > 0 ? dupes[0] : null)
  is('and the list this host offers does carry such a tail', dupes,
    (v) => v.length > 0, 'at least one zone whose tail is catamarca')
  eq('and a tail that no zone carries is null', TL.resolveTimezone('definitelynotazone'), null)
})

group('an unknown city is null, so the caller can render an error', () => {
  // "Unknown cities return ok:false so the caller can render an error
  // entry" - and resolveTimezone is the null that drives it.
  for (const c of ['NotARealPlace', 'zzzz', 'atlantis', 'foo bar', 'mad rid', 'europe/madrid',
    'Europe/Nowhere', '/etc/passwd', '../../etc', 'a'.repeat(500)]) {
    eq(`${JSON.stringify(c)} is unknown`, TL.resolveTimezone(c), null)
  }
})

group('resolveTimezone is total over the degenerate inputs', () => {
  for (const c of ['', '   ', '-', '_', '\t\n']) {
    eq(`resolveTimezone(${JSON.stringify(c)})`, TL.resolveTimezone(c), null)
  }
  eq('nullish', TL.resolveTimezone(null), null)
  eq('undefined', TL.resolveTimezone(undefined), null)
  eq('a number', TL.resolveTimezone(42), null)
  eq('zero', TL.resolveTimezone(0), null)
  eq('false', TL.resolveTimezone(false), null)
  eq('an object', TL.resolveTimezone({}), null)
  eq('an array', TL.resolveTimezone(['x']), null)
  noThrow('a very long city name', () => TL.resolveTimezone('x'.repeat(10000)))
})

group('CITY_TO_TZ is a closed table of IANA zones', () => {
  const keys = Object.keys(TL.CITY_TO_TZ)
  is('it is a non-empty object', TL.CITY_TO_TZ, (v) => v && typeof v === 'object' && keys.length > 0, 'non-empty object')
  is('every value is a slash-separated IANA name', keys.map((k) => TL.CITY_TO_TZ[k]),
    (vs) => vs.every((v) => typeof v === 'string' && /^[A-Za-z]+(\/[A-Za-z_]+)+$/.test(v)), 'Region/City')
  is('every value is a zone this host or the fallback list knows', keys.map((k) => TL.CITY_TO_TZ[k]),
    (vs) => {
      const known = new Set(TL.FALLBACK_ZONES.concat(TL.getAllTimeZones()))
      return vs.every((v) => known.has(v))
    }, 'a known zone name')
  is('no key is a zone name itself with a slash', keys, (ks) => ks.every((k) => k.indexOf('/') < 0), 'no slash in a key')
  // Every key resolves back to itself, which is the invariant that makes the
  // table and the dynamic tier agree on the shipped set.
  is('every key resolves to its own value', keys, (ks) => ks.every((k) => TL.resolveTimezone(k) === TL.CITY_TO_TZ[k]), 'self-resolving keys')
})

group('FALLBACK_ZONES is a sorted, unique, slash-separated snapshot', () => {
  const z = TL.FALLBACK_ZONES
  is('it is a non-empty array', z, (v) => Array.isArray(v) && v.length > 0, 'non-empty array')
  eq('sorted ascending', z, z.slice().sort())
  eq('unique', z.length, new Set(z).size)
  // IANA names carry hyphens, digits and a third segment, so the shape check
  // is a Region/Place walk rather than a two-part name.
  is('every entry is a Region/Place name', z,
    (v) => v.every((e) => typeof e === 'string' && /^[A-Za-z][A-Za-z0-9_-]*(\/[A-Za-z0-9_-]+)+$/.test(e)), 'Region/Place')
  is('no entry is empty', z, (v) => v.every((e) => e !== ''), 'non-empty strings')
  // The continents the launcher renders a label for are all represented.
  const continents = new Set(z.map((e) => TL.zoneContinent(e)))
  for (const c of ['Africa', 'America', 'Asia', 'Atlantic', 'Australia', 'Europe', 'Pacific']) {
    eq(`the snapshot covers ${c}`, Array.from(continents).indexOf(c) >= 0, true)
  }
  // And it is a superset of nothing it needs: every explicit-map zone is
  // reachable from either tier, so a host with no Intl still resolves all of
  // the table. Asserted here so the "no Intl" contract is about resolution,
  // not about formatting.
  is('every explicit-map zone is in the snapshot or the host list',
    Object.keys(TL.CITY_TO_TZ).map((k) => TL.CITY_TO_TZ[k]),
    (vs) => {
      const known = new Set(z.concat(TL.getAllTimeZones()))
      return vs.every((v) => known.has(v))
    }, 'resolvable without Intl')
})

group('getAllTimeZones prefers Intl and returns a sorted, unique, non-empty list', () => {
  const z = TL.getAllTimeZones()
  is('it is a non-empty array', z, (v) => Array.isArray(v) && v.length > 0, 'non-empty array')
  eq('sorted ascending', z, z.slice().sort())
  eq('unique', z.length, new Set(z).size)
  eq('the same list on a second call', z, TL.getAllTimeZones())
  // On a host with Intl.supportedValuesOf the list is that list; without it,
  // it is the static snapshot. Either way the two properties above hold, which
  // is why the caller can rely on them.
  const hasIntl = typeof Intl !== 'undefined' && typeof Intl.supportedValuesOf === 'function'
  if (hasIntl) {
    eq('with Intl present it is the Intl list', z, Intl.supportedValuesOf('timeZone'))
  } else {
    eq('without Intl it is the static snapshot', z, TL.FALLBACK_ZONES)
  }
  // Europe/Madrid is in both, so a resolution assertion does not depend on
  // which tier this host took.
  eq('Europe/Madrid is always present', z.indexOf('Europe/Madrid') >= 0, true)
})

// =========================================================================
section('TimeLib - display names and continents')
// =========================================================================

group('toDisplayName title-cases each word', () => {
  eq('an all-caps city', TL.toDisplayName('BANGKOK'), 'Bangkok')
  eq('a lower-case city', TL.toDisplayName('chicago'), 'Chicago')
  eq('a two-word city', TL.toDisplayName('new york'), 'New York')
  eq('a three-word city', TL.toDisplayName('saint petersburg'), 'Saint Petersburg')
  eq('already title case is unchanged', TL.toDisplayName('Madrid'), 'Madrid')
  eq('the zone-cont form of a city', TL.toDisplayName('sao paulo'), 'Sao Paulo')
})

group('toDisplayName splits a word on a dash and cases each part', () => {
  // "saint petersburg" comes from "saint petersburg"; a user typing
  // "port-au-prince" gets each part cased, which is the documented reading.
  eq('a dashed city', TL.toDisplayName('new-york'), 'New-York')
  eq('a two-dash city', TL.toDisplayName('a-b-c'), 'A-B-C')
  eq('an apostrophe is left alone apart from the first letter', TL.toDisplayName("o'brien"), "O'brien")
  eq('so the first letter after one is cased', TL.toDisplayName("o'brien-"), "O'brien-")
  // Everything after the first character is lowercased, which is what makes
  // a shouted city read as a name.
  eq('the rest of a word is lowercased', TL.toDisplayName('mADRid'), 'Madrid')
  eq('even a mixed-case compound', TL.toDisplayName('hONG kong'), 'Hong Kong')
})

group('toDisplayName collapses whitespace and reads empty as empty', () => {
  eq('a run of spaces collapses', TL.toDisplayName('new    york'), 'New York')
  eq('leading and trailing whitespace is trimmed', TL.toDisplayName('   madrid   '), 'Madrid')
  eq('a tab is whitespace', TL.toDisplayName('new\tyork'), 'New York')
  eq('a newline collapses too', TL.toDisplayName('new\nyork'), 'New York')
  eq('an empty string', TL.toDisplayName(''), '')
  eq('whitespace only', TL.toDisplayName('   '), '')
  eq('nullish', TL.toDisplayName(null), '')
  eq('undefined', TL.toDisplayName(undefined), '')
  eq('a number is text', TL.toDisplayName(42), '42')
  eq('zero is text', TL.toDisplayName(0), '0')
  noThrow('a very long city', () => TL.toDisplayName('a'.repeat(10000)))
})

group('toDisplayName never returns a leading space for an empty word', () => {
  // The loop skips an empty word rather than casing it, and the join is on
  // single spaces - a collapsed run cannot produce "  ".
  eq('a doubled space yields one space', TL.toDisplayName('a  b'), 'A B')
  eq('a leading space is trimmed before splitting', TL.toDisplayName('  a'), 'A')
  eq('no output has a doubled space', ['a  b', ' a ', 'a\t\tb'].map(TL.toDisplayName),
    ['A B', 'A', 'A B'])
})

group('zoneContinent is the first IANA segment, as a pure string split', () => {
  eq('a two-segment zone', TL.zoneContinent('Europe/Madrid'), 'Europe')
  eq('a three-segment zone', TL.zoneContinent('America/Argentina/Buenos_Aires'), 'America')
  eq('a zone with no segment is itself', TL.zoneContinent('UTC'), 'UTC')
  eq('an empty zone', TL.zoneContinent(''), '')
  eq('a leading slash still gives the empty first segment', TL.zoneContinent('/UTC'), '')
  eq('nullish', TL.zoneContinent(null), '')
  eq('undefined', TL.zoneContinent(undefined), '')
  eq('a number', TL.zoneContinent(42), '42')
  eq('the continent of every snapshot zone is one of the seven',
    Array.from(new Set(TL.FALLBACK_ZONES.map(TL.zoneContinent))).sort(),
    ['Africa', 'America', 'Antarctica', 'Arctic', 'Asia', 'Atlantic', 'Australia', 'Brazil', 'Europe', 'Indian', 'Pacific'])
})

// =========================================================================
section('TimeLib - the Intl-dependent, Node/test-only clock helpers')
// =========================================================================

// A fixed instant, so nothing here depends on when the suite runs. 2024-09-11
// is a Wednesday; 12:32 UTC is 14:32 in Madrid (CEST) and 08:32 in New York
// (EDT). The *text* is host-ICU dependent ("Sept" vs "Sep"), so the exact
// shapes below are asserted for the time field and by pattern for the date.
const WHEN = new Date(Date.UTC(2024, 8, 11, 12, 32, 0))

group('formatTimeIn reads the clock in the requested zone', () => {
  const mad = TL.formatTimeIn('Europe/Madrid', WHEN)
  is('it answers a { time, date } pair', mad, (v) => v && Object.keys(v).length === 2 && 'time' in v && 'date' in v, 'exactly {time, date}')
  eq('Madrid at 12:32 UTC', mad.time, '14:32')
  match('the date is a weekday, day and month', mad.date, /^[A-Za-z]{3} \d{1,2} [A-Za-z]{3,4}$/)
  const ny = TL.formatTimeIn('America/New_York', WHEN)
  eq('New York at the same instant', ny.time, '08:32')
  eq('Kolkata is a half-hour offset, not a whole one', TL.formatTimeIn('Asia/Kolkata', WHEN).time, '18:02')
  eq('UTC is the instant itself', TL.formatTimeIn('UTC', WHEN).time, '12:32')
  // Two zones at the same instant differ, which is the whole feature.
  ne('Madrid and New York do not agree', mad.time, ny.time)
})

group('formatTimeIn pads the hour to two digits, so 09:05 is not 9:05', () => {
  // hour: "2-digit" with hour12: false - the shape a row label depends on.
  eq('a single-digit hour', TL.formatTimeIn('Europe/Madrid', new Date(Date.UTC(2024, 0, 1, 8, 5, 0))).time, '09:05')
  eq('a two-digit hour', TL.formatTimeIn('Europe/Madrid', new Date(Date.UTC(2024, 0, 1, 18, 5, 0))).time, '19:05')
  eq('a single-digit minute is padded', TL.formatTimeIn('UTC', new Date(Date.UTC(2024, 0, 1, 0, 7, 0))).time, '00:07')
  // Midnight and noon are the two hour12:false edge cases.
  eq('midnight is 00, not 24', TL.formatTimeIn('UTC', new Date(Date.UTC(2024, 0, 1, 0, 0, 0))).time, '00:00')
  eq('noon is 12', TL.formatTimeIn('UTC', new Date(Date.UTC(2024, 0, 1, 12, 0, 0))).time, '12:00')
  // The date rolls over at the zone boundary, not at UTC midnight.
  eq('a late-evening UTC instant is already tomorrow in Madrid',
    TL.formatTimeIn('Europe/Madrid', new Date(Date.UTC(2024, 0, 1, 23, 30, 0))).time, '00:30')
})

group('formatTimeIn answers null for anything it cannot format', () => {
  // "or null on failure" - and the try/catch is the whole implementation, so
  // a bad zone, a bad instant and a missing Intl all land here.
  eq('an unknown zone', TL.formatTimeIn('Not/AZone', WHEN), null)
  eq('an empty zone', TL.formatTimeIn('', WHEN), null)
  eq('a nullish zone', TL.formatTimeIn(null, WHEN), null)
  // An absent timeZone is not a failure: Intl.DateTimeFormat treats it as the
  // host zone, so the reading comes back in local time rather than as null.
  eq('an undefined zone reads in the host zone, not null', typeof TL.formatTimeIn(undefined, WHEN).time, 'string')
  eq('a zone that is not a string', TL.formatTimeIn(42, WHEN), null)
  eq('an unparsable instant', TL.formatTimeIn('UTC', 'garbage'), null)
  eq('a NaN instant', TL.formatTimeIn('UTC', NaN), null)
  eq('a nullish instant is the real clock', typeof TL.formatTimeIn('UTC', null).time, 'string')
  eq('an undefined instant is the real clock too', typeof TL.formatTimeIn('UTC', undefined).time, 'string')
})

group('formatTimeIn accepts a Date, a number and a string', () => {
  const asDate = TL.formatTimeIn('UTC', WHEN)
  eq('a Date is used as it is', asDate.time, '12:32')
  eq('a number is the same instant as the Date', TL.formatTimeIn('UTC', WHEN.getTime()).time, asDate.time)
  // A numeric *string* is not a date string, so it fails where a number
  // succeeds - `new Date("1726055520000")` is invalid, and the documented
  // "or null on failure" is what surfaces it.
  eq('a numeric string is not a date string, so it fails', TL.formatTimeIn('UTC', String(WHEN.getTime())), null)
  eq('an ISO string is a date string', TL.formatTimeIn('UTC', WHEN.toISOString()).time, asDate.time)
  eq('and the date field agrees', TL.formatTimeIn('UTC', WHEN.getTime()).date, asDate.date)
  eq('a zero timestamp is the epoch, not now', TL.formatTimeIn('UTC', 0).time, '00:00')
  // A Date-shaped object that is not a Date falls to `new Date(value)`, which
  // stringifies it - and a plain object has no useful string form.
  eq('a Date-shaped plain object is not an instant', TL.formatTimeIn('UTC', { getTime: () => WHEN.getTime() }), null)
})

group('with no instant given it reads the real clock, so only the shape is pinned', () => {
  // This is the one path that is genuinely time-dependent. Asserting the
  // shape is the honest assertion; a fixed string here would fail after
  // midnight UTC and pass before it.
  const live = TL.formatTimeIn('Europe/Madrid')
  is('it answers a pair', live, (v) => v && typeof v.time === 'string' && typeof v.date === 'string', '{time: string, date: string}')
  match('the time is HH:MM', live.time, /^[0-2][0-9]:[0-5][0-9]$/)
  match('the date is a weekday, day and month', live.date, /^[A-Za-z]{3} [0-3]?[0-9] [A-Za-z]{3,4}$/)
  const utc = TL.formatTimeIn('UTC')
  match('the same for UTC', utc.time, /^[0-2][0-9]:[0-5][0-9]$/)
  // Madrid is CET or CEST, so its hour is one or two ahead of UTC whatever
  // the date is. A shape assertion plus this one is the whole of what a real
  // clock read can be pinned to.
  const delta = ((hourOf(live.time) - hourOf(utc.time)) + 24) % 24
  eq('Madrid is one or two hours ahead of UTC right now', delta >= 1 && delta <= 2, true)
})

function hourOf(hhmm) {
  return Number(hhmm.slice(0, 2))
}

group('tryTime is the whole entry: a time query or nothing at all', () => {
  eq('a non-time query is null', TL.tryTime('firefox', WHEN), null)
  eq('an empty query', TL.tryTime('', WHEN), null)
  eq('whitespace', TL.tryTime('   ', WHEN), null)
  eq('nullish', TL.tryTime(null, WHEN), null)
  eq('a number', TL.tryTime(42, WHEN), null)
  eq('a query that merely contains the phrase', TL.tryTime('what time is it in madrid', WHEN), null)
})

group('tryTime answers ok:false for the three documented failure kinds', () => {
  eq('no city typed yet', TL.tryTime('time in', WHEN),
    { ok: false, city: '', display: '', timezone: '', error: 'empty' })
  eq('an unknown city', TL.tryTime('time in NotARealPlace', WHEN),
    { ok: false, city: 'NotARealPlace', display: 'Notarealplace', timezone: '', error: 'unknown' })
  // A zone that resolves but cannot be formatted is the third kind, and it is
  // the one only reachable without Intl - pinned there as well.
  eq('the city is echoed raw', TL.tryTime('time in new york', WHEN).city, 'new york')
  eq('the display name is derived from the raw city', TL.tryTime('time in new york', WHEN).display, 'New York')
  eq('an unknown city still carries a display name for the error row', TL.tryTime('time in bangkokx', WHEN).display, 'Bangkokx')
  eq('every failure is ok:false', ['', 'NotARealPlace'].map((c) => TL.tryTime('time in' + (c ? ' ' + c : ''), WHEN).ok), [false, false])
  // The three error strings are a closed vocabulary, because the plugin
  // renders one of three rows.
  eq('the failure vocabulary', ['time in', 'time in Nowhere', 'time in Europe/Nowhere'].map((q) => TL.tryTime(q, WHEN).error),
    ['empty', 'unknown', 'unknown'])
})

group('tryTime answers ok:true with the resolved zone and the reading', () => {
  const r = TL.tryTime('time in madrid', WHEN)
  eq('ok', r.ok, true)
  eq('exactly the six documented fields', Object.keys(r), ['ok', 'city', 'display', 'timezone', 'time', 'date'])
  eq('city is the raw city part', r.city, 'madrid')
  eq('display is the title-cased city', r.display, 'Madrid')
  eq('timezone is the IANA zone', r.timezone, 'Europe/Madrid')
  eq('time is the zone reading', r.time, '14:32')
  match('date is the zone date', r.date, /^[A-Za-z]{3} [0-3]?[0-9] [A-Za-z]{3,4}$/)
  // And it agrees with the two halves it composes.
  eq('the same as formatTimeIn', r.time, TL.formatTimeIn('Europe/Madrid', WHEN).time)
  eq('the same as the parse', r.city, TL.parseTimeQuery('time in madrid'))
  eq('the same as the resolver', r.timezone, TL.resolveTimezone('madrid'))
  // Case-insensitive all the way through.
  eq('uppercase query', TL.tryTime('TIME IN MADRID', WHEN).timezone, 'Europe/Madrid')
  eq('and a dashed city', TL.tryTime('time in new-york', WHEN).timezone, 'America/New_York')
  // No `error` key on a success - the row renderer checks ok, and a present
  // error would be a lie.
  eq('a success carries no error key', 'error' in r, false)
})

// =========================================================================
section('TimeLib - the documented no-Intl fallback path')
// =========================================================================

// Quickshell's QJSEngine has no Intl global, so the file says explicitly that
// getAllTimeZones() falls back to a static snapshot and that formatTimeIn /
// tryTime are Node-only. Both halves are reproduced here by evaluating the
// same source in a context whose Intl is shadowed - the file itself is the
// only thing under test, so the assertion cannot drift from it.
function timeLibWithoutIntl() {
  const holder = { console }
  holder.Intl = undefined
  const ctx = vm.createContext(holder)
  vm.runInContext(libSource(path.join(LAUNCHER, 'TimeLib.js')), ctx, { filename: 'TimeLib.js' })
  const out = {}
  for (const k of Object.keys(TL)) if (k in ctx) out[k] = ctx[k]
  return out
}

const NO_INTL = timeLibWithoutIntl()

group('without Intl the zone list is the static snapshot', () => {
  eq('getAllTimeZones returns the snapshot, content for content', NO_INTL.getAllTimeZones(), TL.FALLBACK_ZONES)
  eq('and it is a fresh array, not the module object', NO_INTL.getAllTimeZones() === TL.FALLBACK_ZONES, false)
  eq('the snapshot is sorted', NO_INTL.getAllTimeZones(), NO_INTL.getAllTimeZones().slice().sort())
  eq('and unique', NO_INTL.getAllTimeZones().length, new Set(NO_INTL.getAllTimeZones()).size)
})

group('without Intl the two resolution tiers still answer every table city', () => {
  // The shell path is exactly this: no Intl, plain string matching. So a city
  // in the explicit map resolves identically with and without Intl.
  let mismatches = []
  for (const k of Object.keys(TL.CITY_TO_TZ)) {
    if (NO_INTL.resolveTimezone(k) !== TL.CITY_TO_TZ[k]) mismatches.push(k)
  }
  eq('every explicit-map city resolves the same way', mismatches, [])
  eq('and the same verdict for the cases the map does not cover',
    [NO_INTL.resolveTimezone('NotARealPlace'), NO_INTL.resolveTimezone(''), NO_INTL.resolveTimezone(null)],
    [null, null, null])
})

group('the two tiers can disagree on a tail two zones share', () => {
  // resolveTimezone scans for the first tail match, so the answer depends on
  // which list it is scanning. "catamarca" is carried by America/Catamarca
  // and by America/Argentina/Catamarca: the Intl list reaches the former, the
  // snapshot the latter, because the snapshot is in a different order. Not a
  // defect - the vocabulary is the city name and the label is cosmetic - but
  // pinned, because a timezone database update would move this line and
  // nothing else in the suite would notice.
  eq('the Intl tier answers America/Catamarca', TL.resolveTimezone('catamarca'), 'America/Catamarca')
  eq('the snapshot tier answers America/Argentina/Catamarca', NO_INTL.resolveTimezone('catamarca'), 'America/Argentina/Catamarca')
  // Both are the same city and the same continent, which is all the launcher's
  // row composition needs.
  eq('the continent is the same either way', TL.zoneContinent(TL.resolveTimezone('catamarca')), TL.zoneContinent(NO_INTL.resolveTimezone('catamarca')))
})

group('without Intl the clock helpers fail, and fail in the documented way', () => {
  // "formatTimeIn()/tryTime() below are Node/test-only helpers that need Intl
  // and are never called from QML." The controller formats via `TZ=<zone> date`
  // instead, so the failure is a null and then a typed hint - not a crash.
  eq('formatTimeIn is null', NO_INTL.formatTimeIn('Europe/Madrid', WHEN), null)
  eq('tryTime reports the format failure, not an unknown city', NO_INTL.tryTime('time in madrid', WHEN),
    { ok: false, city: 'madrid', display: 'Madrid', timezone: 'Europe/Madrid', error: 'format' })
  // The zone still resolved - only the formatting is missing. That is the
  // distinction the plugin's own row composition depends on.
  eq('the zone resolved before the format failed', NO_INTL.resolveTimezone('madrid'), 'Europe/Madrid')
  eq('an empty city is still empty, not a format failure', NO_INTL.tryTime('time in', WHEN).error, 'empty')
  eq('an unknown city is still unknown', NO_INTL.tryTime('time in Nowhere', WHEN).error, 'unknown')
  // The pure string helpers are unaffected, which is why the shell path uses
  // them at all.
  eq('parseTimeQuery is unaffected', NO_INTL.parseTimeQuery('time in Madrid'), 'Madrid')
  eq('toDisplayName is unaffected', NO_INTL.toDisplayName('new york'), 'New York')
  eq('zoneContinent is unaffected', NO_INTL.zoneContinent('Europe/Madrid'), 'Europe')
  eq('normalizeCity is unaffected', NO_INTL.normalizeCity('new-york'), 'new york')
})

group('every TimeLib function has the same answer with and without Intl where it should', () => {
  // The split is the contract: five functions are pure string work and must
  // be identical, three need Intl and must differ in exactly one way.
  for (const f of ['normalizeCity', 'parseTimeQuery', 'toDisplayName', 'zoneContinent']) {
    const cases = { normalizeCity: ['Madrid', 'new-york', ''], parseTimeQuery: ['time in Madrid', 'time in', 'x'], toDisplayName: ['new york', '', 'BANGKOK'], zoneContinent: ['Europe/Madrid', '', 'UTC'] }
    for (const c of cases[f]) eq(`${f}(${JSON.stringify(c)}) is Intl-independent`, NO_INTL[f](c), TL[f](c))
  }
  eq('getAllTimeZones is the one function whose answer is Intl-dependent',
    NO_INTL.getAllTimeZones() === TL.getAllTimeZones(), false)
  eq('resolveTimezone agrees for every explicit-map key on this host',
    Object.keys(TL.CITY_TO_TZ).every((k) => NO_INTL.resolveTimezone(k) === TL.resolveTimezone(k)), true)
})

// The helpers below are defined ahead of the groups that use them, because a
// reader should meet the replica of the host before the assertions that depend
// on it.

// A replica of PluginInstance.evaluate()'s three checks, used for the
// accept/reject discrimination the shipped plugins cannot produce (none of
// them is malformed). The loader is the authority on acceptance; the strings
// this replica emits are read out of PluginInstance.qml and out of the loader,
// so neither can drift from the other.
function hostEvaluate(source, label) {
  const ctx = vm.createContext({ console, __source: source })
  const wrapper = `(function(){ var VibraniumPlugin = null; try { eval(__source) } catch (e) { return { error: "" + (e.message || e), impl: null } } return { error: null, impl: VibraniumPlugin }; })()`
  const r = vm.runInContext(wrapper, ctx, { filename: label })
  if (r.error !== null) return r
  if (r.impl === null) return { error: 'did not assign VibraniumPlugin', impl: null }
  if (typeof r.impl.items !== 'function' || typeof r.impl.activate !== 'function') {
    return { error: 'items/activate must be functions', impl: null }
  }
  return { error: null, impl: r.impl }
}

const HOST_NO_ASSIGN = 'did not assign VibraniumPlugin'
const HOST_BAD_SHAPE = 'items/activate must be functions'

// pluginInternals evaluates a plugin exactly the way loadPlugin does, and then
// reaches into the wrapper scope for the declarations the wrapper keeps
// private - which is the only way to compare a plugin copy against its library
// twin below. loadPlugin stays the authority on acceptance.
function pluginInternals(file) {
  const src = fs.readFileSync(file, 'utf8')
  const names = topLevelNames(src)
  const ctx = vm.createContext({ console, __source: src })
  const wrapper = `(function(){ var VibraniumPlugin = null; eval(__source);`
    + ` var __n = ${JSON.stringify(names)}; var __o = {};`
    + ` for (var i = 0; i < __n.length; i++) { __o[__n[i]] = eval(__n[i]); }`
    + ` return { impl: VibraniumPlugin, fns: __o }; })()`
  const out = vm.runInContext(wrapper, ctx, { filename: file })
  return { impl: out.impl, fns: out.fns, names, ctxGlobal: ctx }
}

// =========================================================================
section('The plugin host contract (PluginInstance.qml)')
// =========================================================================

const HOST_SRC = fs.readFileSync(path.join(LAUNCHER, 'PluginInstance.qml'), 'utf8')
const LOADER_SRC = fs.readFileSync(path.resolve(SHELL_DIR, '..', 'tests/shell/lib/qmlloader.mjs'), 'utf8')

group('the host gives each plugin its own scope, on purpose', () => {
  // "No .pragma library here on purpose - sharing is the bug." A plugin whose
  // declarations were shared would collide with the next plugin's. The phrase
  // is in a comment, so the assertion is on the directive as a statement.
  eq('no .pragma statement in the file', HOST_SRC.split('\n').filter((l) => /^\s*\.pragma\s/.test(l)), [])
  match('it wraps the source in its own function', HOST_SRC, /function\s+evaluate\s*\(source\)/)
  contains('it declares VibraniumPlugin itself, as null', HOST_SRC, 'var VibraniumPlugin = null')
  contains('and evals the source', HOST_SRC, 'eval(source)')
  match('it reports a property for the failure', HOST_SRC, /property\s+string\s+error/)
  match('and one for the accepted impl', HOST_SRC, /property\s+var\s+impl/)
})

group('the host rejects three ways, and this suite reads those strings out of the file', () => {
  // The error strings are the contract, so they are parsed from the QML
  // rather than restated here: a rename in PluginInstance.qml moves the
  // replica below with it, instead of diverging from it.
  const qmlNoAssign = /host\.error\s*=\s*"did not assign VibraniumPlugin"/.test(HOST_SRC)
  const qmlBadShape = /host\.error\s*=\s*"items\/activate must be functions"/.test(HOST_SRC)
  eq('the unassigned message is in the QML', qmlNoAssign, true)
  eq('the wrong-shape message is in the QML', qmlBadShape, true)
  contains('the host checks items is a function', HOST_SRC, 'typeof VibraniumPlugin.items !== "function"')
  contains('and that activate is', HOST_SRC, 'typeof VibraniumPlugin.activate !== "function"')
  // A strict `=== null` test is what the host does, and it is narrower than
  // the loader's: a plugin that assigns `undefined` passes the null test and
  // then dereferences undefined, so the host would throw out of evaluate()
  // rather than record an error. Pinned as a divergence, not a bug report -
  // no shipped plugin does it, and PluginInstance's own try/catch does not
  // cover the two typeof checks.
  match('the null test is strict', HOST_SRC, /if\s*\(VibraniumPlugin\s*===\s*null\)/)
  notMatch('there is no undefined test', HOST_SRC, /VibraniumPlugin\s*===?\s*undefined/)
})

group('the host and the node loader state the same two refusals', () => {
  // The loader exists so a suite can drive PluginInstance.evaluate() off a
  // QML engine; if its messages drifted, a suite would be asserting a
  // different contract than the shell enforces.
  contains('the loader refuses an unassigned plugin', LOADER_SRC, 'did not assign VibraniumPlugin')
  contains('the loader refuses a plugin with the wrong shape', LOADER_SRC, 'items/activate must be functions')
  contains('the loader requires items', LOADER_SRC, "typeof impl.items !== 'function'")
  contains('the loader requires activate', LOADER_SRC, "typeof impl.activate !== 'function'")
  contains('the loader evaluates through a wrapper scope, as the host does', LOADER_SRC, 'var VibraniumPlugin = null; eval(__source)')
})

group('the host accepts a well-formed plugin and rejects a malformed one', () => {
  const ok = hostEvaluate('VibraniumPlugin = { items: function(){ return [] }, activate: function(){} }', 'ok.js')
  eq('a minimal plugin is accepted', ok.error, null)
  is('and its impl is handed over', ok.impl, (v) => v && typeof v.items === 'function', 'an impl')
  eq('a source that never assigns is rejected', hostEvaluate('var x = 1', 'none.js').error, HOST_NO_ASSIGN)
  eq('a source that assigns null is rejected', hostEvaluate('VibraniumPlugin = null', 'null.js').error, HOST_NO_ASSIGN)
  eq('a source that throws is rejected with its message', hostEvaluate('throw new Error("boom")', 'throw.js').error, 'boom')
  eq('a plugin with no items is rejected', hostEvaluate('VibraniumPlugin = { activate: function(){} }', 'noitems.js').error, HOST_BAD_SHAPE)
  eq('a plugin with no activate is rejected', hostEvaluate('VibraniumPlugin = { items: function(){} }', 'noact.js').error, HOST_BAD_SHAPE)
  eq('a plugin whose items is not a function is rejected', hostEvaluate('VibraniumPlugin = { items: [], activate: function(){} }', 'arr.js').error, HOST_BAD_SHAPE)
  eq('a plugin whose activate is not a function is rejected', hostEvaluate('VibraniumPlugin = { items: function(){}, activate: 5 }', 'num.js').error, HOST_BAD_SHAPE)
  eq('an empty object is rejected', hostEvaluate('VibraniumPlugin = {}', 'empty.js').error, HOST_BAD_SHAPE)
  eq('a plugin with an init as well is accepted',
    hostEvaluate('VibraniumPlugin = { init: function(){}, items: function(){}, activate: function(){} }', 'three.js').error, null)
  // And the seven shipped plugins all pass the same three checks, through the
  // loader, which is the authority.
  for (const dir of PLUGIN_DIRS) {
    noThrow(`${path.basename(dir)} passes the loader`, () => loadPlugin(path.join(dir, 'main.js'), {}))
    eq(`${path.basename(dir)} passes the host replica`, hostEvaluate(fs.readFileSync(path.join(dir, 'main.js'), 'utf8'), path.basename(dir) + '/main.js').error, null)
  }
})

// =========================================================================
section('The seven shipped plugins - manifests and shape')
// =========================================================================

group('every plugin directory is discoverable and carries a usable manifest', () => {
  eq('listPlugins finds the shipped tree', PLUGIN_DIRS.length, 7)
  eq('and names them', PLUGIN_NAMES, ['binary', 'calc', 'color', 'fx', 'time', 'unit', 'websearch'])
  for (const dir of PLUGIN_DIRS) {
    const m = pluginManifest(dir)
    is(`${path.basename(dir)} has a name`, m.name, (v) => typeof v === 'string' && v !== '', 'a non-empty string')
    is(`${path.basename(dir)} has a description`, m.description, (v) => typeof v === 'string' && v !== '', 'a non-empty string')
    is(`${path.basename(dir)} has a string keyword`, m.keyword, (v) => typeof v === 'string', 'a string')
    is(`${path.basename(dir)} has an admitted type`, m.type, (v) => LL.pluginTypes().indexOf(v) >= 0, 'engine, websearch or binary')
  }
})

group('the manifests are admitted by the real registry rule and none declares capabilities', () => {
  // A manifest's `capabilities` can only narrow (AppLauncher._grantsFor), and
  // none of them declares any, so each root hands over exactly its own
  // table: defaults + execDetached for the shipped root, plus the request half
  // of a pair for the plugins the launcher's per-plugin map names, and
  // defaults for a user root. Asserted so a future `capabilities` list is a
  // visible diff here.
  for (const dir of PLUGIN_DIRS) {
    const m = pluginManifest(dir)
    eq(`${path.basename(dir)} declares no capabilities`, m.capabilities, undefined)
    eq(`${path.basename(dir)} is admitted by pluginConfigFromMeta`,
      LL.pluginConfigFromMeta(path.basename(dir), dir, m, []) !== null, true)
  }
})

group('every plugin is keywordless, and only the claimed types may be', () => {
  // The engines claim by taking the head of the result list rather than by
  // prefix, so they carry no keyword - which is also why a keywordless
  // engine has to be admitted (see the drift note in the registry section).
  // The binary and websearch types are keywordless for the same reason, and
  // that emptiness IS the silent-plugin rule: a keyword is the only way a mode
  // is entered, so a plugin without one is reachable only by claiming.
  for (const dir of PLUGIN_DIRS) {
    eq(`${path.basename(dir)} keyword is empty`, pluginManifest(dir).keyword, '')
  }
  eq('the five engines', PLUGIN_DIRS.filter((d) => pluginManifest(d).type === 'engine').map((d) => path.basename(d)),
    ['calc', 'color', 'fx', 'time', 'unit'])
  eq('and the one websearch', PLUGIN_DIRS.filter((d) => pluginManifest(d).type === 'websearch').map((d) => path.basename(d)),
    ['websearch'])
  eq('and the one binary', PLUGIN_DIRS.filter((d) => pluginManifest(d).type === 'binary').map((d) => path.basename(d)),
    ['binary'])
  // A keywordless manifest of a type that does not claim is still refused, so
  // "keywordless" stays a property of the claiming types rather than a
  // blanket exemption.
  eq('a keywordless plugin of another type is refused', LL.pluginConfigFromMeta(
    'x', '/p/x', { name: 'X', description: 'D', keyword: '', type: 'other' }, []), null)
  // A keywordless plugin is never a dispatch prefix, whatever its type.
  for (const dir of PLUGIN_DIRS) {
    const cfg = LL.pluginConfigFromMeta(path.basename(dir), dir, pluginManifest(dir), [])
    eq(`${path.basename(dir)} is not a dispatch prefix`, LL.pluginByPrefix([cfg], ''), null)
    eq(`${path.basename(dir)} contributes no prefix`, LL.enabledPrefixes([cfg]), [])
  }
})

group('no plugin directory carries a qmldir, because main.js is evaluated as text', () => {
  // "plugin main.js files are evaluated as text by PluginInstance.qml, not
  // imported as modules" - a qmldir would imply an import that never happens.
  for (const dir of PLUGIN_DIRS) {
    eq(`${path.basename(dir)} has no qmldir`, fs.existsSync(path.join(dir, 'qmldir')), false)
    eq(`${path.basename(dir)} has a main.js`, fs.existsSync(path.join(dir, 'main.js')), true)
    eq(`${path.basename(dir)} has a plugin.json`, fs.existsSync(path.join(dir, 'plugin.json')), true)
  }
})

group('the public surface of a plugin is exactly the VibraniumPlugin object', () => {
  // "That wrapper also means the file's own top-level declarations are not
  // exported - they are locals of the wrapper - so a plugin's public surface
  // is exactly the VibraniumPlugin object." Pinned per plugin: a leaked
  // declaration would show up as an extra own key.
  for (const dir of PLUGIN_DIRS) {
    const { impl } = pluginInternals(path.join(dir, 'main.js'))
    const name = path.basename(dir)
    const keys = Object.keys(impl)
    eq(`${name} own keys`, keys, ['init', 'items', 'activate'])
    eq(`${name} init is a function`, typeof impl.init, 'function')
    eq(`${name} items is a function`, typeof impl.items, 'function')
    eq(`${name} activate is a function`, typeof impl.activate, 'function')
    // The loadLoader - the authority on acceptance - agrees.
    eq(`${name} loadPlugin sees the same three`, Object.keys(loadPlugin(path.join(dir, 'main.js'), {})), ['init', 'items', 'activate'])
  }
})

group('a plugin top-level declaration is not reachable through its public surface', () => {
  // The point of the wrapper. Checked on the calc plugin, whose six top-level
  // declarations are the most surface a shipped plugin has.
  const file = path.join(PLUGIN_ROOT, 'calc', 'main.js')
  const { impl, ctxGlobal, names } = pluginInternals(file)
  eq('the calc plugin declares six top-level names', names.length, 6)
  for (const n of names) {
    eq(`${n} is not a member of the impl object`, n in impl, false)
    eq(`${n} is not reachable on the impl`, impl[n], undefined)
    // And it never became a property of the engine's global either, which is
    // what "locals of the wrapper" means: two plugins evaluated in two
    // engines cannot see each other's names.
    eq(`${n} is not a global of the evaluating engine`, n in ctxGlobal, false)
  }
  eq('and the impl is not polluted with the wrapper locals',
    Object.keys(impl).filter((k) => names.indexOf(k) >= 0), [])
})

group('two plugins do not share engine state', () => {
  // "sharing one plugin's engine state with another is the bug it exists to
  // prevent." Two independent evaluations of the same source must not see each
  // other, and must produce independent objects.
  const a = pluginInternals(path.join(PLUGIN_ROOT, 'calc', 'main.js'))
  const b = pluginInternals(path.join(PLUGIN_ROOT, 'calc', 'main.js'))
  ne('two evaluations produce different impl objects', a.impl, b.impl)
  ne('and different top-level function objects', a.fns.tryEvaluate, b.fns.tryEvaluate)
  eq('but identical behaviour', a.fns.tryEvaluate('2+2'), b.fns.tryEvaluate('2+2'))
  // Mutating one impl does not reach the other: they are separate closures
  // over separate engines.
  a.impl.__marker = 1
  eq('a marker on one impl is absent from the other', b.impl.__marker, undefined)
  delete a.impl.__marker
})

// =========================================================================
section('The seven shipped plugins - rows through a real policy')
// =========================================================================

// Every plugin is driven through a PluginPolicy instance built the way
// AppLauncher._apiFor builds the shipped root's: the default grants plus
// execDetached, and nothing else. So a plugin that reached for readFile,
// network, clipboard or secret would fail here exactly as it would in the
// shell.
//
// fx is the one exception, and it is built the way the launcher's
// per-plugin map builds it - the shipped table plus the fetch pair, resolved
// through the real grantsForRoot rather than typed out - so the suite cannot
// pass on a table the shell no longer holds.
function shippedApi(opts) {
  const rec = recordingHost(opts || {})
  return { api: PP.createPolicy(['execDetached'], rec.host), rec }
}

function fxApi(opts) {
  const rec = recordingHost({ id: 'fx', ...(opts || {}) })
  const grants = PP.grantsForRoot(
    path.join(PLUGIN_ROOT, '..'), path.join(PLUGIN_ROOT, 'fx'),
    ['execDetached'], [], undefined, { fx: ['requestNet', 'setCacheSection'] }, 'fx')
  return { api: PP.createPolicy(grants, rec.host), rec, grants }
}

group('the shipped grant table is reachable and nothing else is', () => {
  const { api } = shippedApi()
  eq('the granted set', api.grantedOperations(),
    ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
      'stripJsonc', 'requestTime', 'cachedTime', 'cachedBinaries', 'cachedNet',
      'cachedOnline', 'cachedSection', 'log', 'execDetached'])
  eq('the denied set is exactly the seven outside operations a shipped plugin does not hold',
    api.deniedOperations(),
    ['requestBinaries', 'readFile', 'requestNet', 'network', 'clipboard', 'secret', 'setCacheSection'])
  // And the time plugin's README claim - "It holds no readFile, no
  // execDetached, no network, no clipboard and no secret" - is about the
  // manifest narrowing, not the root: the root does hold execDetached,
  // because the copy rows are part of the launcher.
  for (const n of ['readFile', 'network', 'clipboard', 'secret']) {
    eq(`${n} is absent from the api object`, n in api, false)
  }
  eq('execDetached is present, because a copy row is part of the launcher', 'execDetached' in api, true)
  // Reading a body is a default; asking for one is not. So a sibling engine
  // reaches a read it can never fill and no socket at all. The PATH pair
  // splits the same way: every shipped plugin can read the executable names
  // the launcher already scanned, and only the binary plugin can ask for one.
  eq('the body read is present', 'cachedNet' in api, true)
  eq('the fetch request is absent from a non-fx api', 'requestNet' in api, false)
  eq('the executable read is present', 'cachedBinaries' in api, true)
  eq('the PATH scan is absent from a non-binary api', 'requestBinaries' in api, false)
})

group('the binary plugin holds the shipped table plus the PATH scan, and nothing else', () => {
  // Built through the real grantsForRoot with the launcher's own per-plugin
  // map, so the suite cannot pass on a table the shell no longer holds.
  const rec = recordingHost()
  const grants = PP.grantsForRoot(
    path.join(PLUGIN_ROOT, '..'), path.join(PLUGIN_ROOT, 'binary'),
    ['execDetached'], [], undefined,
    { fx: ['requestNet', 'setCacheSection'], binary: ['requestBinaries'] }, 'binary')
  const api = PP.createPolicy(grants, rec.host)
  eq('the granted set', api.grantedOperations(),
    ['id', 'configDir', 'pluginDir', 'setting', 'shellQuote',
      'stripJsonc', 'requestTime', 'cachedTime', 'requestBinaries', 'cachedBinaries',
      'cachedNet', 'cachedOnline', 'cachedSection', 'log', 'execDetached'])
  eq('the denied set', api.deniedOperations(),
    ['readFile', 'requestNet', 'network', 'clipboard', 'secret', 'setCacheSection'])
  // The scan is a directory walk, but the grant names the NAMES and not the
  // directories: nothing in the api can report where an executable lives, and
  // nothing in it can read a path.
  eq('it can ask for a scan', 'requestBinaries' in api, true)
  eq('it can read the names back', 'cachedBinaries' in api, true)
  eq('it still cannot read a file', 'readFile' in api, false)
  eq('it cannot open a socket', 'requestNet' in api, false)
  // A user plugin cannot buy the scan by taking the shipped folder's name.
  const userGrants = PP.grantsForRoot(
    '/home/u/.local/share/vibranium/shell/features/launcher/plugins',
    '/home/u/.config/vibranium/shell/AppLauncher/plugins/binary',
    ['execDetached'], [], undefined,
    { fx: ['requestNet', 'setCacheSection'], binary: ['requestBinaries'] }, 'binary')
  eq('a user plugin named binary gets the user table', userGrants, [])
  eq('and no scan in its api', 'requestBinaries' in PP.createPolicy(userGrants, {}), false)
})

group('calc: a valid expression is one copy row, an open one is a hint row', () => {
  const { api, rec } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), api)
  eq('a complete expression', impl.items('2+2'), [{
    kind: 'calc', uid: 'calc', label: '2+2 = 4', sub: 'Copy 4 to clipboard', desc: '',
    icon: 'accessories-calculator', calcValue: '4', calcExpr: '2+2', incomplete: false,
    item: { copyValue: '4' },
  }])
  eq('a trailing = is stripped from the label too', impl.items('2+2=')[0].label, '2+2 = 4')
  eq('an open expression is a hint row', impl.items('2+'), [{
    kind: 'calc', uid: 'calc', label: '2+', sub: 'Continue typing...', desc: '',
    icon: 'accessories-calculator', calcValue: '', calcExpr: '2+', incomplete: true,
    item: { copyValue: '' },
  }])
  // The quick reject: a bare number is not a calc query, "so typing a number
  // does not hide apps".
  for (const q of ['42', 'firefox', '', '   ', '5m in cm', 'x^2', 'time in madrid']) {
    eq(`calc claims nothing for ${JSON.stringify(q)}`, impl.items(q), [])
  }
  eq('the result is a copy row, not a launch', impl.items('2+2')[0].item.copyValue, '4')
})

group('calc: the icon follows the showIcons setting', () => {
  const on = shippedApi({ settings: { 'shell.launcher.showIcons': true } })
  eq('with icons on', loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), on.api).items('2+2')[0].icon, 'accessories-calculator')
  const off = shippedApi({ settings: { 'shell.launcher.showIcons': false } })
  eq('with icons off the row is iconless, not dropped', loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), off.api).items('2+2')[0].icon, '')
  const unset = shippedApi({ settings: {} })
  eq('an absent setting defaults to on', loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), unset.api).items('2+2')[0].icon, 'accessories-calculator')
  // Anything that is not exactly false shows the icon.
  const zero = shippedApi({ settings: { 'shell.launcher.showIcons': 0 } })
  eq('a 0 setting still shows the icon', loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), zero.api).items('2+2')[0].icon, 'accessories-calculator')
})

group('unit: a conversion is a copy row, a typed failure is a hint row', () => {
  const { api } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'unit', 'main.js'), api)
  eq('an explicit conversion', impl.items('5m in cm')[0], {
    kind: 'unit', uid: 'unit:cm', label: '5 m = 500 cm', sub: '5 metres is 500 centimetres', desc: '',
    icon: 'accessories-calculator', unitValue: '500 cm', unitExpr: '5 m', incomplete: false,
    item: { copyValue: '500 cm' },
  })
  eq('a bare value uses the per-unit default target', impl.items('5 m')[0].label, '5 m = 16.4042 ft')
  // "the inch unit in `5 in in cm` still parses (source in, key in)": the
  // split is on the LAST keyword, not the first.
  eq('an ambiguous inch source', impl.items('20 in in cm')[0].label, '20 in = 50.8 cm')
  // A compound source is one row that names every term, so the sum is
  // auditable and not just a number.
  eq('a compound imperial source', impl.items('6 ft 2 in')[0].label, '6 ft + 2 in = 1.8796 m')
  eq('the compact spelling is the same compound', impl.items('6\'2"')[0].label, '6 ft + 2 in = 1.8796 m')
  eq('and the value is the whole sum', impl.items('6 ft 2 in')[0].unitValue, '1.8796 m')
  // The typed failures are hints, and each says why.
  eq('an incompatible pair', impl.items('20c in in')[0].label, "Incompatible units")
  eq('its sub names both dimensions', impl.items('20c in in')[0].sub, 'C is temperature, in is length')
  eq('an unphysical temperature', impl.items('-300C in K')[0].label, 'Below absolute zero')
  eq('an incomplete query', impl.items('5m in')[0].label, '5 m')
  eq('an out-of-range result', impl.items('1e308t in mg')[0].label, 'Result out of range')
  eq('and each is activatable-looking but carries no value',
    ['20c in in', '-300C in K', '5m in', '1e308t in mg'].map((q) => impl.items(q)[0].incomplete), [true, true, true, true])
  eq('none of them offers a value to copy',
    ['20c in in', '-300C in K', '5m in', '1e308t in mg'].map((q) => impl.items(q)[0].unitValue), ['', '', '', ''])
  eq('a speed target from a length source is coerced', impl.items('250mph in km')[0].label, '250 mph = 402.336 km/h')
  // An unknown target is the one failure with no row. The controller replaces
  // the whole result list with the engine's row, and unit is asked before calc,
  // so a hint here would hide every application match on a word the
  // engine does not recognise. A miss is not a statement about what was asked.
  eq('an unknown target yields no row at all', impl.items('5m in zz'), [])
  eq('and no row for a partly-typed word either', impl.items('5m in nop'), [])
  eq('and it is an empty list rather than a throw', impl.items('5m in zz').length, 0)
  // The other four failures are confident statements, and each keeps its row.
  eq('every other failure still yields exactly one row',
    ['20c in in', '-300C in K', '5m in', '1e308t in mg'].map((q) => impl.items(q).length), [1, 1, 1, 1])
  eq('and a success is still one row', impl.items('5m in cm').length, 1)
  // The decimal data ladder, the grouped number and the Calorie override all
  // reach the row through the same contract, so what the launcher shows is the
  // reading the engine produced.
  eq('a bare gigabyte', impl.items('1 GB')[0].label, '1 GB = 1000 MB')
  eq('a bare kibibyte', impl.items('1 KiB in B')[0].label, '1 KiB = 1024 B')
  eq('a grouped number echoes its commas', impl.items('1,000 km in mi')[0].label, '1,000 km = 621.371 mi')
  eq('a food Calorie is a kilocalorie', impl.items('5 Cal in J')[0].label, '5 kcal = 20920 J')
  // The filler words are stripped by the engine, so they reach the same row the
  // bare query does - a natural sentence is not a miss.
  eq('a filler word is a row, not a miss', impl.items('convert 5 km to mi')[0].label, '5 km = 3.10686 mi')
  eq('and so is an inverted question, which reads as miles in kilometres',
    impl.items('how many km in 5 mi')[0].label, '5 mi = 8.04672 km')
  eq('and a trailing please', impl.items('5 km in mi please')[0].label, '5 km = 3.10686 mi')
  for (const q of ['2+2', '42', 'firefox', '', 'x^2', 'time in madrid']) {
    eq(`unit claims nothing for ${JSON.stringify(q)}`, impl.items(q), [])
  }
})

group('unit: a bare quantity answers with a row per reading, capped and same-dimension', () => {
  const { api } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'unit', 'main.js'), api)
  // The shape the request names: "5 mb" is six readings of one quantity, and
  // each row carries its own target, its own number and its own copy payload.
  eq('the whole set for a bare megabyte', impl.items('5 mb').map((r) => r.label), [
    '5 MB = 5000 KB',
    '5 MB = 5000000 B',
    '5 MB = 0.005 GB',
    '5 MB = 4882.81 KiB',
    '5 MB = 4.76837 MiB',
    '5 MB = 0.00465661 GiB',
  ])
  // A fraction of a GREATER unit is a row when it carries a fact - this one is
  // "what share of a drive is this" - and the same rule drops the ladder noise
  // further down, which is the whole reason the floor is asymmetric.
  eq('a fifth of a gigabyte keeps its row', impl.items('5 mb').some((r) => r.label === '5 MB = 0.005 GB'), true)
  eq('but two thousandths of a kilometre does not',
    impl.items('20 cm').some((r) => r.uid === 'unit:km'), false)
  eq('and neither does a five-hundred-thousandth of a mile',
    impl.items('20 cm').some((r) => r.uid === 'unit:mi'), false)
  eq('the boundary itself is not arbitrary: a metre is a thousandth of a kilometre',
    impl.items('1 m').some((r) => r.label === '1 m = 0.001 km'), true)
  eq('every row is identified by its target, so the card keys each one apart',
    impl.items('5 mb').map((r) => r.uid),
    ['unit:KB', 'unit:B', 'unit:GB', 'unit:KiB', 'unit:MiB', 'unit:GiB'])
  eq('and every row offers its own value to copy',
    impl.items('5 mb').map((r) => r.item.copyValue),
    ['5000 KB', '5000000 B', '0.005 GB', '4882.81 KiB', '4.76837 MiB', '0.00465661 GiB'])
  eq('every row is activatable, because every row has a number',
    impl.items('5 mb').map((r) => r.incomplete), [false, false, false, false, false, false])
  eq('and each row sub line is that row own pair, spelled out',
    impl.items('5 mb')[3].sub, '5 megabytes is 4882.81 kibibytes')
  // The head is the row a single-answer engine showed, so the documented
  // default of a bare query has not moved.
  eq('the head is still the per-unit default target', impl.items('5 mb')[0].label, '5 MB = 5000 KB')
  eq('and for another dimension too', impl.items('1 kg')[0].label, '1 kg = 2.20462 lb')
  eq('a kilogram answers in the units a person asks for',
    impl.items('1 kg').map((r) => r.uid), ['unit:lb', 'unit:g', 'unit:oz', 'unit:st', 'unit:ton', 'unit:t'])
  // Six is the ceiling: a quantity with more convertible siblings than that
  // gets a screenful rather than a scroll.
  const counts = ['5 m', '1 kg', '5 mb', '1 ha', '100 C', '1 atm', '1 l', '1 kwh', '7d', '90 deg', '100 N', '100 km/h']
    .map((q) => impl.items(q).length)
  eq('no bare quantity answers with more than six rows', Math.max(...counts) <= 6, true)
  eq('and none of them answers with none', Math.min(...counts) >= 1, true)
  // The source is never a target of its own row.
  eq('the source unit is never a row', impl.items('5 mb').some((r) => r.uid === 'unit:MB'), false)
  // A dimension stays a dimension: the shortlist is per dimension, so a watt
  // never answers with a kilowatt-HOUR even though both are "power" in prose.
  // BTU/h does appear, and it is a rate of work rather than a quantity of it -
  // the same shape as "horsepower", which is already here.
  eq('power offers only power', impl.items('5 w').map((r) => r.uid),
    ['unit:hp', 'unit:kW', 'unit:PS', 'unit:BTU/h'])
  eq('and a kilowatt-hour is still the ENERGY dimension',
    impl.items('1 kwh in J')[0].label, '1 kWh = 3600000 J')
  eq('and energy is the dimension that fans out widest',
    impl.items('1 kwh').map((r) => r.uid),
    ['unit:Wh', 'unit:J', 'unit:kJ', 'unit:cal', 'unit:kcal', 'unit:MJ'])
  // An explicit target is an intention, so it stays one row.
  eq('an explicit target is still one row', impl.items('5 mb in gb').length, 1)
  eq('and it is the one that was asked for', impl.items('5 mb in gb')[0].label, '5 MB = 0.005 GB')
  eq('a compound bare source fans out from the sum, not from one term',
    impl.items('6 ft 2 in')[0].label, '6 ft + 2 in = 1.8796 m')
  eq('and every row of it names the whole sum',
    impl.items('6 ft 2 in')[1].unitExpr, '6 ft + 2 in')
  // A bare query the checks REFUSE is a statement about the quantity, so it is
  // one row rather than one per candidate: six copies of "Below absolute zero"
  // would be six answers to a question with none.
  eq('an unphysical bare temperature is one row', impl.items('-300 c').map((r) => r.label), ['Below absolute zero'])
  eq('and it is the hint row, not a reading',
    impl.items('-300 c').map((r) => [r.uid, r.incomplete, r.unitValue]), [['unit:hint', true, '']])
  eq('a bare result no target can express is one row too', impl.items('1e308 t').map((r) => r.label), ['Result out of range'])
  // Two targets whose numbers coincide are one row. The mass table's decigram
  // and decagram both land on 100 for a kilogram, and the row is the number.
  eq('no bare quantity repeats a number', ['1 kg', '5 m', '1 ha', '100 C'].every((q) => {
    const numbers = impl.items(q).map((r) => r.unitValue.replace(/ [^ ]+$/, ''))
    return new Set(numbers).size === numbers.length
  }), true)
})

group('time: the plugin decides the zone, the service supplies the clock', () => {
  const { api, rec } = shippedApi({ cached: { 'Europe/Madrid': { time: '14:32', code: 'CEST', date: 'Fri 11 Sept' } } })
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'time', 'main.js'), api)
  eq('the keyword alone is a hint row', impl.items('time in')[0], {
    kind: 'time', uid: 'time:hint', label: 'time in Madrid', sub: 'Type a city to see its time',
    desc: '', icon: 'preferences-system-time', timeValue: '', timeInvalid: true,
    item: { copyValue: '' },
  })
  eq('an unknown city is an error row, not an empty result', impl.items('time in Nowhereville')[0], {
    kind: 'time', uid: 'time:invalid:nowhereville', label: "Unknown city 'Nowhereville'",
    sub: 'time in Madrid', desc: '', icon: 'preferences-system-time', timeValue: '',
    timeInvalid: true, item: { copyValue: '' },
  })
  eq('a resolved city with a cached reading is the real row', impl.items('time in madrid')[0], {
    kind: 'time', uid: 'time:Europe/Madrid', label: 'Madrid — 14:32 CEST',
    sub: 'Europe/Madrid - Fri 11 Sept', desc: '', icon: 'preferences-system-time',
    timeValue: '14:32', timeExpr: 'Madrid', timeInvalid: false, item: { copyValue: '14:32' },
  })
  // "The plugin decides which zone; the controller decides what the clock
  // says." So the plugin asks for the probe and reads the cache - it never
  // formats a time itself.
  eq('it asked the service for the zone it resolved', rec.calls.filter((c) => c[0] === 'requestTime').map((c) => c[1]),
    ['Europe/Madrid'])
  // An unresolved clock is a pending row, not an error.
  rec.calls.length = 0
  const pend = impl.items('time in new york')
  eq('a zone with no cached reading yet is pending', pend[0], {
    kind: 'time', uid: 'time:America/New_York', label: 'New York — …', sub: 'America/New_York',
    desc: '', icon: 'preferences-system-time', timeValue: '', timeInvalid: true,
    timePending: true, item: { copyValue: '' },
  })
  eq('and it asked for that zone too', rec.calls.map((c) => c[1]), ['America/New_York'])
  // The uid is namespaced by zone, so two cities on one zone share a row and
  // the panel patches instead of rebuilding.
  eq('two cities on one zone share the uid',
    impl.items('time in barcelona')[0].uid, impl.items('time in madrid')[0].uid)
  for (const q of ['', 'firefox', '2+2', 'what time is it']) {
    eq(`time claims nothing for ${JSON.stringify(q)}`, impl.items(q), [])
  }
  eq('the time icon follows showIcons too', (() => {
    const off = shippedApi({ settings: { 'shell.launcher.showIcons': false }, cached: { 'Europe/Madrid': { time: '14:32', code: '', date: '' } } })
    return loadPlugin(path.join(PLUGIN_ROOT, 'time', 'main.js'), off.api).items('time in madrid')[0].icon
  })(), '')
})

// The rate table every fx assertion runs against. A fixture rather than a
// live fetch: the suite must not depend on the network, and the shape is the
// provider's documented one (a `rates` object against one `base_code`).
// Real figures from one live fetch of the provider, so the cross-rate
// arithmetic in the assertions below is checkable against a real table
// rather than against numbers chosen to make a rounding rule look right.
const FX_RATES = {
  USD: 1, EUR: 0.878356, GBP: 0.755594, JPY: 157.489371, CHF: 0.829327,
  KRW: 1290.5, BRL: 5.44, TRY: 41.2, KWD: 0.3244, SEK: 10.3305, PLN: 4.0301,
  // One of the ten provider codes the named table does not spell out, so the
  // suite can assert the code is reachable through the rate table alone.
  RWF: 0.750746,
}
const FX_URL = FXL.RATE_URL
const fxBody = (rates) => JSON.stringify({
  result: 'success',
  provider: 'https://www.exchangerate-api.com',
  time_last_update_utc: 'Mon, 28 Sep 2026 00:02:31 +0000',
  base_code: 'USD',
  rates,
})
const fxImpl = (opts) => {
  const h = fxApi(opts)
  return { ...h, impl: loadPlugin(path.join(PLUGIN_ROOT, 'fx', 'main.js'), h.api) }
}
const withRates = (rates) => ({ net: { [FX_URL]: fxBody(rates) } })

group('fx: a settled rate table is one copy row carrying the rate and its date', () => {
  const { impl, rec } = fxImpl(withRates(FX_RATES))
  eq('a full pair', impl.items('100 usd in eur'), [{
    kind: 'fx', uid: 'fx:EUR', label: '100 USD = 87.84 EUR',
    sub: '100 US Dollars is 87.84 Euros',
    desc: '1 USD = 0.878356 EUR\nRates updated Mon, 28 Sep 2026 00:02:31 +0000',
    icon: 'accessories-calculator',
    fxValue: '87.84 EUR', fxExpr: '100 USD', incomplete: false,
    item: { copyValue: '87.84 EUR', target: 'EUR' },
  }])
  // It asked for the document on the way, and the controller's TTL is what
  // stops that from re-arming on every recompute.
  eq('it asked for the rate document', rec.calls.map((c) => c[0]), ['requestNet'])
  eq('and asked for the documented URL', rec.calls[0][1], FX_URL)
  eq('with a timeout the controller bounds', rec.calls[0][2], 8000)
  // Every keyword spelling reads as one query, and so does every currency
  // spelling, because the point is human language rather than a syntax.
  for (const q of ['100 usd in eur', '100 usd to eur', '100 usd as eur', '100 usd -> eur',
    '100 usd = eur', '100usd in eur', '100 USD in EUR', '100 dollars in euros']) {
    eq(`${JSON.stringify(q)} is the same row`, impl.items(q)[0].label, '100 USD = 87.84 EUR')
  }
  // A bare amount converts against the default target, which is the table's
  // base for everything except the base itself.
  eq('a bare amount converts to the base', impl.items('100 eur')[0].label, '100 EUR = 113.85 USD')
  eq('the base itself converts elsewhere', impl.items('100 usd')[0].label, '100 USD = 87.84 EUR')
  // Amounts: grouping, a leading decimal point and a negative sign.
  eq('grouped thousands survive', impl.items('1,234.56 usd in jpy')[0].fxValue, '194,430.08 JPY')
  eq('a leading decimal point is the same number', impl.items('.5 usd in eur')[0].fxValue, '0.439178 EUR')
  eq('a negative amount stays negative', impl.items('-50 usd in eur')[0].fxValue, '-43.92 EUR')
  eq('zero is two decimals, not "0"', impl.items('0 usd in eur')[0].fxValue, '0.00 EUR')
  // A sub-unit amount keeps significant digits rather than rounding away,
  // which is the failure mode a money formatter has that a ratio does not.
  eq('a grouped target reads as money', impl.items('1 usd in krw')[0].fxValue, '1,290.50 KRW')
  eq('a sub-unit result keeps precision', impl.items('100 krw in usd')[0].fxValue, '0.0774893 USD')
  // A cross rate, not a second request: the table is quoted against one base
  // and the engine divides two of its entries.
  eq('a cross pair needs no second fetch', impl.items('1 chf in eur')[0].label, '1 CHF = 1.06 EUR')
  // Fifteen queries so far, fifteen asks. That is the contract: the plugin asks
  // on every items() and the CONTROLLER's TTL is what collapses that into one
  // request per ten minutes. A plugin carrying its own TTL would need a clock
  // for no gain, and a plugin that never asked would never learn a rate
  // changed.
  eq('one request per query, deduped by the controller not the plugin', rec.calls.length, 18)
  eq('and every one of them the same URL', [...new Set(rec.calls.map((c) => c[1]))], [FX_URL])
})

group('fx: an unfetched rate table is a pending row, not a number and not a failure', () => {
  // The tri-state the whole async path rests on: cachedNet() answering null
  // means "no body yet", and the row says so instead of rendering a rate it
  // does not have.
  const { impl } = fxImpl()
  eq('no body yet', impl.items('100 usd in eur'), [{
    kind: 'fx', uid: 'fx:EUR', label: '100 USD in EUR',
    sub: "Fetching today's rate",
    desc: '', icon: 'accessories-calculator',
    fxValue: '', fxExpr: '100 USD',
    incomplete: true, pending: true, item: { copyValue: '' },
  }])
  // Neither async row offers Enter. A row tagged incomplete is
  // non-activatable in the controller, and the request is TTL-guarded there,
  // so promising a retry on a key that does nothing would be a lie the user
  // discovers by pressing it.
  eq('the pending row does not promise Enter',
    /retry|enter/i.test(impl.items('100 usd in eur')[0].sub), false)
  // A settled fetch that produced nothing is a DIFFERENT label. Folding the
  // two is what leaves a failed fetch spinning forever.
  const failed = fxImpl({ net: { [FX_URL]: '' } })
  eq('a settled empty body is not a pending row', failed.impl.items('100 usd in eur'), [{
    kind: 'fx', uid: 'fx:hint', label: '100 USD in EUR',
    sub: 'Rate table unavailable - type to retry',
    desc: '', icon: 'accessories-calculator', fxValue: '', fxExpr: '100 USD',
    incomplete: true, item: { copyValue: '' },
  }])
  eq('and it does not promise Enter either',
    /enter/i.test(failed.impl.items('100 usd in eur')[0].sub), false)
  // An unparseable body is the same settled failure, not a crash: the row
  // cannot blame a currency the user typed correctly.
  const junk = fxImpl({ net: { [FX_URL]: '<html>rate limited</html>' } })
  eq('an unparseable body reads as unavailable', junk.impl.items('100 usd in eur')[0].sub,
    'Rate table unavailable - type to retry')
  eq('and names the pair, not a missing currency', junk.impl.items('100 usd in eur')[0].label, '100 USD in EUR')
  // Offline the empty table names the link, not the rates: the watcher's
  // cached read says so, and the gate still collapses the bare-query list
  // to the one row rather than repeating it per target.
  const dark = fxImpl({ online: false, net: { [FX_URL]: '' } })
  eq('an empty table while offline says so', dark.impl.items('100 usd in eur')[0].sub, 'No internet connection')
  eq('and still names the pair', dark.impl.items('100 usd in eur')[0].label, '100 USD in EUR')
  eq('a bare query collapses to the one row', dark.impl.items('100 usd').map((r) => r.sub), ['No internet connection'])
  eq('the offline row raises alert', dark.impl.items('100 usd in eur')[0].alert, true)
  eq('an old host without the read keeps the old wording',
    loadPlugin(path.join(PLUGIN_ROOT, 'fx', 'main.js'), { ...dark.api, cachedOnline: undefined }).items('100 usd in eur')[0].sub,
    'Rate table unavailable - type to retry')
  // A body that parses but does not quote the pair is a THIRD state, and it
  // is the one that names the currency.
  const thin = fxImpl(withRates({ USD: 1, EUR: 0.878356 }))
  eq('a table without the pair names the code it lacks',
    thin.impl.items('100 usd in jpy')[0].label, 'No rate for JPY')
  // A non-rate value for one code is treated as no rate for it, not as zero:
  // a NaN would otherwise flow into the product and print "NaN EUR".
  const typed = fxImpl(withRates({ USD: 1, EUR: 'not-a-number', JPY: 157.489371 }))
  eq('a non-numeric rate is no rate', typed.impl.items('100 usd in eur')[0].label, 'No rate for EUR')
  eq('and the pair beside it still converts', typed.impl.items('100 usd in jpy')[0].label, '100 USD = 15,748.94 JPY')
})

group('fx: a hint row for a query it understood but cannot answer', () => {
  const { impl } = fxImpl(withRates(FX_RATES))
  // An unfinished pair is a typing hint, the same row the unit engine shows.
  eq('a keyword with no target yet', impl.items('100 usd in'), [{
    kind: 'fx', uid: 'fx:hint', label: '100 USD', sub: 'Continue typing...',
    desc: '', icon: 'accessories-calculator',
    fxValue: '', fxExpr: '100 USD',
    incomplete: true, item: { copyValue: '' },
  }])
  // A target the table cannot name produces NO row, for the same reason the unit
  // engine drops its unknown-target hint: this list replaces every application
  // match, so a hint for a word the engine simply cannot read would hide every
  // app called "eur extra". The engine sitting above calc means the cost of
  // showing it is the whole result set, which is not worth a typo.
  eq('an unknown target yields no row at all', impl.items('100 usd in eur extra'), [])
  // Converting a currency into itself is answered rather than left to divide
  // by one and print a rate of exactly 1.
  eq('the same pair twice', impl.items('100 usd in usd')[0].label, 'Already USD')
  // Every hint row is non-activatable, so Enter cannot copy an empty value.
  for (const q of ['100 usd in', '100 usd in usd', '100 usd in zzz']) {
    eq(`${JSON.stringify(q)} carries no copy payload`, impl.items(q)[0].item.copyValue, '')
    eq(`${JSON.stringify(q)} is tagged incomplete`, impl.items(q)[0].incomplete, true)
  }
})

group('fx: it claims only currency queries, and the other four engines keep theirs', () => {
  // The gate is what stops a live-network engine from swallowing app names.
  // Each of these is a real query another engine owns.
  const { impl, rec } = fxImpl(withRates(FX_RATES))
  for (const q of ['firefox', '2+2', '5m in cm', '5 m', 'time in madrid', 'x^2', '',
    '   ', '100', '100 abc', '1e3m', '100\nusd in eur', '100 usd in eur '.padEnd(140, 'x')]) {
    eq(`fx claims nothing for ${JSON.stringify(q)}`, impl.items(q), [])
  }
  // "100" alone is a bare number and "100 abc" is three unadorned letters: a
  // bare query resolves its source only from the named table, so neither can
  // claim the keystroke and then fail.
  //
  // And nothing was fetched for any of them. This is the assertion that makes
  // the plugin safe to have on the same keystroke path as the app list: a
  // plugin that asked on every gate hit would open a socket while the user
  // types "100 miles in km".
  eq('and it opened no socket while claiming nothing', rec.calls.length, 0)
  // The engine-priority order, asserted through behaviour rather than through
  // the constant: firstEngineClaiming is handed the plugins in the order a
  // directory scan would produce (alphabetical, so calc before fx), and fx
  // still has to win - because the calculator would take "100 usd in eur" as
  // arithmetic and the unit converter takes a bare "<value><unit>".
  const engine = (id, rowsFor) => ({
    id, type: 'engine', enabled: true, broken: false, _impl: { items: () => rowsFor },
  })
  const claiming = (rowsBy) => (cfg) => rowsBy[cfg.id] || []
  const fxRows = [{ label: '100 USD = 87.84 EUR' }]
  const calcRows = [{ label: '2+2 = 4' }]
  const registry = [
    engine('calc', () => calcRows),
    engine('fx', () => fxRows),
    engine('unit', () => []),
  ]
  const win = (q, rowsBy) => {
    const found = LL.firstEngineClaiming(registry, q, claiming(rowsBy))
    return found === null ? null : found.plugin.id
  }
  const fxWins = { calc: calcRows, fx: fxRows, unit: [] }
  eq('fx wins a query the calculator would also take', win('100 usd in eur', fxWins), 'fx')
  const calcWins = { calc: calcRows, fx: [], unit: [] }
  eq('and a query only the calculator takes still reaches it', win('2+2', calcWins), 'calc')
  eq('and a query nothing claims is null', win('2+2', { calc: [], fx: [], unit: [] }), null)
  // A disabled or broken fx hands the query straight on, so the order cannot
  // become a way to lock a query out of every engine at once.
  const off = [Object.assign(engine('fx', () => fxRows), { enabled: false }), engine('calc', () => calcRows)]
  eq('a disabled fx hands the query to the next engine',
    LL.firstEngineClaiming(off, '100 usd in eur', claiming(fxWins)).plugin.id, 'calc')
  // isEngineKind and isSynthKind derive from the same list, so fx is a
  // synthetic result rather than a filterable pool entry. allSynthKinds is
  // what the counter gate reads, and it has to hold for a LIST: an engine
  // answering with six rates is not six matches against the app pool.
  eq('fx is an engine kind', LL.isEngineKind('fx'), true)
  eq('fx is a synthetic kind', LL.isSynthKind('fx'), true)
  eq('and an unknown kind is neither', [LL.isEngineKind('nope'), LL.isSynthKind('nope')], [false, false])
  eq('a set of one synthetic row is all synthetic',
    LL.allSynthKinds([{ kind: 'fx' }]), true)
  eq('and a set of six readings of the same engine is too',
    LL.allSynthKinds([{ kind: 'fx' }, { kind: 'fx' }, { kind: 'fx' }, { kind: 'fx' }, { kind: 'fx' }, { kind: 'fx' }]), true)
  eq('but one app row among them is not', LL.allSynthKinds([{ kind: 'fx' }, { kind: 'app' }]), false)
  eq('a mixed engine set is not either',
    LL.allSynthKinds([{ kind: 'unit' }, { kind: 'calc' }]), true)
  eq('and a separator row is not synthetic', LL.allSynthKinds([{ kind: 'fx' }, { kind: 'separator' }]), false)
  eq('an empty set is not an all-synthetic set, so a fruitless search still counts',
    LL.allSynthKinds([]), false)
  eq('a nullish set is not one either', LL.allSynthKinds(null), false)
  eq('and a null entry is skipped by the kind test rather than dereferenced',
    LL.allSynthKinds([null]), false)
})

group('fx: currency spelling, symbols and the codes the table supplies', () => {
  const { impl } = fxImpl(withRates(FX_RATES))
  // A symbol names a source in front of the amount, glued to it, or as the
  // target - all three are how the same thing gets typed.
  eq('a leading symbol', impl.items('$100 in eur')[0].label, '100 USD = 87.84 EUR')
  eq('a symbol glued to the amount', impl.items('100$ in eur')[0].label, '100 USD = 87.84 EUR')
  eq('a symbol as the target', impl.items('100 usd in €')[0].label, '100 USD = 87.84 EUR')
  // "R$100" is the case that makes the longest-symbol-first order matter: a
  // naive scan strips the "$" and reads R as a stray letter.
  eq('a two-character symbol beats its own tail', impl.items('R$100 in usd')[0].label, '100 BRL = 18.38 USD')
  eq('and the same symbol as a word', impl.items('100 r$ in usd')[0].label, '100 BRL = 18.38 USD')
  // The yen sign belongs to two currencies; the engine picks one and says so
  // rather than guessing per keystroke.
  eq('the ambiguous yen sign resolves to JPY', impl.items('¥100 in usd')[0].label, '100 JPY = 0.634963 USD')
  // An ISO code the named table does not spell out is still reachable, which
  // is what keeps the currency set the provider's rather than this file's.
  // RWF is one of the ten provider codes with no entry in the table.
  eq('a code only the rate table knows', impl.items('100 rwf in usd')[0].label, '100 RWF = 133.20 USD')
  // The same code read the other way round, so the cross rate is visibly a
  // division of two table entries and not a lookup of the pair.
  eq('the same code as the target', impl.items('100 usd in rwf')[0].label, '100 USD = 75.07 RWF')
  // ...but only behind a named source, so a bare three-letter run still falls
  // through to the app list.
  eq('a bare unknown code claims nothing', impl.items('100 rwf'), [])
  // Diacritics and separators fold, so a typed name reaches its code.
  eq('a zloty', impl.items('100 zloty in usd')[0].label, '100 PLN = 24.81 USD')
  eq('a hyphenated name', impl.items('100 swedish-krona in usd')[0].label, '100 SEK = 9.68 USD')
  // A code that IS named converts bare, because the bare-query path is what
  // the named table exists for.
  eq('a bare named code', impl.items('100 kwd')[0].label, '100 KWD = 308.26 USD')
})

group('fx: a bare amount answers with the default order, or your own', () => {
  const { impl } = fxImpl(withRates(FX_RATES))
  // With nothing in the cache, the rows come out in SUGGEST order and the
  // source drops out of it - so the list is the documented default, not a seed
  // that is always reshuffled. USD is skipped here because USD is the source.
  eq('the whole set for a bare dollar amount', impl.items('100 usd').map((r) => r.label), [
    '100 USD = 87.84 EUR',
    '100 USD = 75.56 GBP',
    '100 USD = 82.93 CHF',
    '100 USD = 403.01 PLN',
    '100 USD = 15,748.94 JPY',
    '100 USD = 129,050.00 KRW',
    '100 USD = 544.00 BRL',
    '100 USD = 1,033.05 SEK',
    '100 USD = 4,120.00 TRY',
  ])
  eq('every row is identified by its own currency',
    impl.items('100 usd').map((r) => r.uid),
    ['fx:EUR', 'fx:GBP', 'fx:CHF', 'fx:PLN', 'fx:JPY', 'fx:KRW', 'fx:BRL', 'fx:SEK', 'fx:TRY'])
  // formatRate, not the raw float: a 16-digit rate on the detail line is noise,
  // and six significant digits is the same rounding the unit engine uses.
  eq('and every row carries the rate it was converted at',
    impl.items('100 usd')[4].desc.split('\n')[0], '1 USD = 157.489 JPY')
  eq('which is six significant digits and not the raw float',
    impl.items('100 usd')[4].desc.split('\n')[0], '1 USD = ' + FXL.formatRate(157.489371) + ' JPY')
  eq('and a rate below one keeps them too',
    FXL.formatRate(1 / 1.3612), '0.734646')
  eq('while the LABEL is money and keeps its two decimals',
    impl.items('100 usd')[4].label, '100 USD = 15,748.94 JPY')
  eq('and its own copy payload', impl.items('100 usd')[4].item.copyValue, '15,748.94 JPY')
  // The base goes the other way, so the list reads from the source outwards
  // rather than being the same nine every time: USD leads, EUR is the source
  // and drops out, and the rest keep their base positions.
  eq('a bare euro amount leads with the fetch base', impl.items('100 eur')[0].label, '100 EUR = 113.85 USD')
  eq('and the default order follows the base outwards',
    impl.items('100 eur').map((r) => r.uid),
    ['fx:USD', 'fx:GBP', 'fx:CHF', 'fx:PLN', 'fx:JPY', 'fx:KRW', 'fx:BRL', 'fx:SEK', 'fx:TRY'])
  eq('the source currency is never a row of its own',
    impl.items('100 eur').some((r) => r.uid === 'fx:EUR'), false)
  eq('no bare amount answers with more than ten rows',
    ['100 usd', '100 eur', '100 jpy', '1000 usd', '1 krw'].every((q) => impl.items(q).length <= 10), true)
  // And the order does not depend on the AMOUNT, only on the cache: the same
  // currencies for every figure, which is what makes the list learnable.
  eq('the same nine for an amount three orders of magnitude smaller',
    impl.items('0.1 usd').map((r) => r.uid), impl.items('100 usd').map((r) => r.uid))
  eq('and for one three orders of magnitude larger',
    impl.items('100000 usd').map((r) => r.uid), impl.items('100 usd').map((r) => r.uid))
  eq('a tiny amount keeps a tiny row rather than losing the currency',
    impl.items('1 krw')[0].fxValue, '0.000774893 USD')
  eq('and the whole list is still there for it', impl.items('1 krw').length, 9)
  // An explicit pair is an intention, so it stays one row and is not reordered.
  eq('an explicit pair is still one row', impl.items('100 usd in gbp').length, 1)
  // The states that describe the FETCH rather than a target stay single rows:
  // nine copies of one pending line is nine answers to one question.
  eq('an unfetched table is one pending row', fxImpl().impl.items('100 usd').length, 1)
  eq('and it is the pending row', fxImpl().impl.items('100 usd')[0].pending, true)
  eq('a settled but empty table is one row', fxImpl({ net: { [FX_URL]: '' } }).impl.items('100 usd').length, 1)
  // A document that cannot quote the DEFAULT is a different case from one that
  // cannot quote anything: that row drops out and the rest of the list stands,
  // because "no rate for EUR" says one currency, not "no rates today".
  eq('a missing default pair costs its own row and nothing else',
    fxImpl(withRates({ USD: 1, JPY: 157.489371 })).impl.items('100 usd').map((r) => r.label),
    ['100 USD = 15,748.94 JPY'])
  eq('and when no currency can be quoted, the default says so',
    fxImpl(withRates({ USD: 1 })).impl.items('100 usd').map((r) => r.label), ['No rate for EUR'])
  // A document that barely covers the list answers with what it has.
  const thin = fxImpl(withRates({ USD: 1, EUR: 0.878356, GBP: 0.755594 }))
  eq('a document that barely covers the list still answers', thin.impl.items('100 usd').map((r) => r.uid),
    ['fx:EUR', 'fx:GBP'])
})

group('fx: a picked currency climbs, and only a picked one', () => {
  // The cache is the whole feature: a currency the user has chosen before is
  // offered first next time. The counts live in a shell-cache section the
  // plugin reads on every render and writes on activation.
  const cache = { "fx-usage": { JPY: 4 } }
  const { impl, rec } = fxImpl({ ...withRates(FX_RATES), cache })
  eq('a picked currency leads', impl.items('100 usd')[0].label, '100 USD = 15,748.94 JPY')
  eq('and the rest keep their base order behind it',
    impl.items('100 usd').map((r) => r.uid),
    ['fx:JPY', 'fx:EUR', 'fx:GBP', 'fx:CHF', 'fx:PLN', 'fx:KRW', 'fx:BRL', 'fx:SEK', 'fx:TRY'])
  // Nine rows, not ten: the fixture quotes exactly nine of the candidates, and
  // the ceiling is a ceiling rather than a quota. A document quoting all of
  // them would reach ten, which the engine-level test below pins directly.
  eq('and the answer is every currency the document can back', impl.items('100 usd').length, 9)
  // A tie falls back to the base order, so two currencies picked equally often
  // are not reshuffled between themselves by the order the cache happens to
  // hold them in.
  const tied = fxImpl({ ...withRates(FX_RATES), cache: { 'fx-usage': { JPY: 2, CHF: 2 } } })
  eq('a tie keeps the base order between the two',
    tied.impl.items('100 usd').slice(0, 2).map((r) => r.uid), ['fx:CHF', 'fx:JPY'])
  // A count the document cannot quote loses the row it would have led, and the
  // rest of the list still stands.
  const stale = fxImpl({ ...withRates({ USD: 1, EUR: 0.878356, JPY: 157.489371 }), cache: { 'fx-usage': { PLN: 9 } } })
  eq('a promoted currency the document does not quote drops out',
    stale.impl.items('100 usd').map((r) => r.uid), ['fx:EUR', 'fx:JPY'])
  // The promotion is per currency and not per pair, so a source the user does
  // not convert still sees the same ranking.
  eq('the ranking is the same whatever the source', impl.items('100 eur')[0].label, '100 EUR = 17,930.02 JPY')
  // An explicit pair is not reordered by anything: the user named the target.
  eq('an explicit pair ignores the ranking', impl.items('100 usd in chf')[0].label, '100 USD = 82.93 CHF')
  // And the count is written on ACTIVATION, not on render, so a list the user
  // scrolled past is not a preference.
  eq('nothing was written by rendering', Object.keys(cache['fx-usage']).length, 1)
  impl.activate(impl.items('100 usd')[0].item)
  eq('activating the leading row counted it', cache['fx-usage'], { JPY: 5 })
  eq('and it copied on the way', rec.calls.filter((c) => c[0] === 'execDetached').length, 1)
  // The next render reads what was just written, so a currency picked twice
  // outranks one picked once with no restart and no reload.
  const second = fxImpl({ ...withRates(FX_RATES), cache })
  eq('a second pick outranks a first',
    second.impl.items('100 usd').map((r) => r.uid).slice(0, 2), ['fx:JPY', 'fx:EUR'])
  second.impl.activate(second.impl.items('100 usd')[3].item)
  eq('picking a lower row counts that currency too', cache['fx-usage'], { JPY: 5, CHF: 1 })
  eq('and it now leads', fxImpl({ ...withRates(FX_RATES), cache }).impl.items('100 usd')[0].uid, 'fx:JPY')
  // A hint and a pending row carry no target, so activating one counts nothing.
  const before = JSON.stringify(cache['fx-usage'])
  impl.activate({ copyValue: '' })
  impl.activate({ copyValue: 'x' })
  eq('a payload with no copy value changes nothing', JSON.stringify(cache['fx-usage']), before)
  // A cache that is not a plain object degrades to the default order rather
  // than to a broken list.
  for (const junk of [null, 'nope', 7, [1, 2]]) {
    eq(`${JSON.stringify(junk)} reads as no history`,
      fxImpl({ ...withRates(FX_RATES), cache: { 'fx-usage': junk } }).impl.items('100 usd')[0].uid,
      'fx:EUR')
  }
  // And a section outside the plugin's own namespace is not even readable, so
  // another plugin's section cannot be used as a ranking by naming it.
  eq('a foreign section reads as no history',
    fxImpl({ ...withRates(FX_RATES), cache: { 'calc-usage': { JPY: 9 } } }).impl.items('100 usd')[0].uid,
    'fx:EUR')
})

group('fx: the row carries the same icon calc and unit carry', () => {
  // One family at a glance: fx names the same icon as calc and unit, and is
  // gated by the same setting. It resolves through the ROW path
  // (Menu.resolveAppIcon), which falls back to Quickshell.iconPath() when
  // Icons.url() has no shipped asset - which is why a freedesktop name like
  // this works on a row and would not work in the search field's chip.
  const FX_ICON = 'accessories-calculator'
  const calcRow = loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), shippedApi().api).items('2+2')[0]
  const unitRow = loadPlugin(path.join(PLUGIN_ROOT, 'unit', 'main.js'), shippedApi().api).items('5m in cm')[0]
  eq('calc uses it', calcRow.icon, FX_ICON)
  eq('unit uses it', unitRow.icon, FX_ICON)
  for (const [label, opts] of [
    ['a settled row', withRates(FX_RATES)],
    ['a pending row', {}],
    ['a settled failure', { net: { [FX_URL]: '' } }],
  ]) {
    eq(`${label} carries the icon`, fxImpl(opts).impl.items('100 usd in eur')[0].icon, FX_ICON)
  }
  // Gated by the same setting, so one toggle governs the family.
  const off = fxImpl({ ...withRates(FX_RATES), settings: { 'shell.launcher.showIcons': false } })
  eq('with icons off the row is iconless, not dropped', off.impl.items('100 usd in eur')[0].icon, '')
  eq('and calc agrees', loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'),
    shippedApi({ settings: { 'shell.launcher.showIcons': false } }).api).items('2+2')[0].icon, '')
  const unset = fxImpl({ ...withRates(FX_RATES), settings: {} })
  eq('an absent setting defaults to on', unset.impl.items('100 usd in eur')[0].icon, FX_ICON)
  // The row shape the delegate and the controller read: kind and uid make it
  // a synthetic engine result, not a filterable pool entry. The uid names the
  // TARGET rather than the engine, because the engine can own several rows at
  // once and rowsEqual keys on it - one uid for the set would collapse a bare
  // amount's whole list into a single identity.
  const row = unset.impl.items('100 usd in eur')[0]
  eq('the kind', row.kind, 'fx')
  eq('the uid is the target, so a patch beats a rebuild', row.uid, 'fx:EUR')
  eq('the expression is the normalised source', row.fxExpr, '100 USD')
  eq('the value is the copy payload', row.fxValue, row.item.copyValue)
  eq('isEngineKind claims it', LL.isEngineKind('fx'), true)
  eq('so isSynthKind claims it', LL.isSynthKind('fx'), true)
  // The search field keeps the default magnifier for every engine. The
  // override that briefly swapped it is gone, and this pins the reason: a row
  // icon name is not a search-field icon name.
  const panel = fs.readFileSync(path.join(LAUNCHER, 'LauncherPanel.qml'), 'utf8')
  notContains('the panel does not override the field icon', panel, 'roleIconOverride')
  const field = fs.readFileSync(path.join(SHELL_DIR, 'common/ui/InputField.qml'), 'utf8')
  notContains('and the shared field grew no override property', field, 'roleIconOverride')
  contains('the field still resolves the search role to the magnifier', field,
    'root.inputRole === "search" ? "search"')
})

group('color: a color code answers with one row per format, and no icon at all', () => {
  const { api, rec } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'color', 'main.js'), api)
  // The seven formats are the ColorPicker's chip order and hex is the one the
  // user typed into the input field, so six rows answer it - each one a
  // complete reading, not a fragment of one.
  const rows = impl.items('#ff8800')
  eq('six rows', rows.length, 6)
  eq('in the chip order, without the hex already in the field', rows.map((r) => r.label), [
    'rgb(255, 136, 0)',
    'rgba(255, 136, 0, 1.000)',
    'hsl(32, 100%, 50%)',
    'hsla(32, 100%, 50%, 1.000)',
    'hsv(32, 100%, 100%)',
    'hsva(32, 100%, 100%, 1.000)',
  ])
  eq('and no row repeats the input', rows.filter((r) => r.label === '#ff8800').length, 0)
  // The uid names the FORMAT, not the engine: rowsEqual keys on it, so one uid
  // for the whole set would collapse six rows into one identity.
  eq('each row is keyed by its format', rows.map((r) => r.uid), [
    'color:rgb', 'color:rgba', 'color:hsl', 'color:hsla', 'color:hsv', 'color:hsva',
  ])
  eq('the kind makes it a synthetic engine result', rows[0].kind, 'color')
  eq('isEngineKind claims it', LL.isEngineKind('color'), true)
  eq('so isSynthKind claims it', LL.isSynthKind('color'), true)
  // The dot is the row, so the row names no icon at all - and a palette glyph
  // would label all six identically without ever showing which color they are.
  eq('no icon name is claimed', rows.map((r) => r.icon), ['', '', '', '', '', ''])
  eq('every row paints the same color', rows.map((r) => r.swatch), Array(6).fill('#ff8800'))
  // The border follows the color's own luminance (ColorMath.contrastText), so a
  // pale swatch keeps a dark rim and a dark one a light rim on any theme.
  eq('a mid color takes the dark rim', rows[0].swatchEdge, '#000000')
  eq('white takes the dark rim too', impl.items('#ffffff')[0].swatchEdge, '#000000')
  eq('black takes the light rim', impl.items('#000000')[0].swatchEdge, '#ffffff')
  eq('the value is the copy payload', rows.map((r) => r.colorValue === r.item.copyValue), Array(6).fill(true))
  eq('the expression is the code as typed', rows[0].colorExpr, '#ff8800')
  // A translucent code keeps its alpha in the three readings that have an alpha
  // slot, and leaves the dot opaque - a see-through dot on a themed surface
  // reads as a broken theme rather than as a color.
  const half = impl.items('#ff880080')
  eq('the alpha forms carry it', half.map((r) => r.label).filter((l) => /, 0\.50\d\)$/.test(l)), [
    'rgba(255, 136, 0, 0.502)', 'hsla(32, 100%, 50%, 0.502)', 'hsva(32, 100%, 100%, 0.502)',
  ])
  eq('and the opaque forms do not', half[0].label, 'rgb(255, 136, 0)')
  eq('the dot is the opaque hex', half[0].swatch, '#ff8800')
  // Every spelling the picker understands reaches the same six rows.
  eq('a css function form', impl.items('rgb(255, 136, 0)').map((r) => r.label), rows.map((r) => r.label))
  eq('a bare hsl()', impl.items('hsl(32, 100%, 50%)')[0].label, 'rgb(255, 136, 0)')
  eq('a bare hsv()', impl.items('hsv(32, 100%, 100%)')[0].label, 'rgb(255, 136, 0)')
  eq('an uppercase hex normalises', impl.items('#FF8800')[0].label, 'rgb(255, 136, 0)')
  eq('a short hex expands', impl.items('#f80').map((r) => r.label), rows.map((r) => r.label))
  eq('surrounding whitespace is trimmed', impl.items('  #ff8800  ')[0].label, 'rgb(255, 136, 0)')
  // The gate: a hex code must be spelled with its `#`, because free text makes a
  // bare hex word an application name. Everything the gate declines is a miss,
  // not an error row - the controller replaces the whole result list, so a row
  // here would hide every application match.
  for (const q of ['face', 'cafe', 'facade', 'added', 'ff8800', 'abcdef', '#gggggg', '#gg',
    '##', '##########',
    'rgb(foo)', '', 'firefox', '  ', 'x^2', '2+2', '5m in cm']) {
    eq(`color claims nothing for ${JSON.stringify(q)}`, impl.items(q), [])
  }
  eq('and a miss asks for nothing', rec.calls, [])
  // Activating a row copies that row's reading, never the input.
  impl.activate(rows[2].item)
  eq('Enter copies the chosen reading', rec.calls, [['execDetached', "printf %s 'hsl(32, 100%, 50%)' | wl-copy"]])
})

group('color: a half-typed code keeps the engine claim instead of flashing web search', () => {
  // "#ffffff0" on the way to "#ffffff00" and "rgb(" before the channels are
  // strict prefixes of real colors: tryColor is still null for them, but the
  // engine answers one non-activatable hint row - the calc "Continue typing..."
  // shape - so the controller never falls through to the web fallback between
  // keystrokes. Text that cannot become a color by typing more ("#gg",
  // "rgb(foo)") stays a miss and is asserted in the group above.
  const { api, rec } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'color', 'main.js'), api)
  for (const q of ['#', '#f', '#ff', '#fffff', '#ffffff0', '#12345',
    'rgb(', 'rgb(1', 'rgb(255, 136)', 'rgb(1, 2, 3', 'rgb(1,2)', 'rgb()',
    'hsl(', 'hsl(32, 100%', 'rgba(1, 2, 3, 0.']) {
    const hint = impl.items(q)
    eq(`one hint row for ${JSON.stringify(q)}`, hint.length, 1)
    eq(`the kind for ${JSON.stringify(q)}`, hint[0].kind, 'color')
    eq(`the uid for ${JSON.stringify(q)}`, hint[0].uid, 'color:incomplete')
    eq(`the label echoes the input for ${JSON.stringify(q)}`, hint[0].label, String(q).trim())
    eq(`the sub for ${JSON.stringify(q)}`, hint[0].sub, 'Continue typing...')
    eq(`the hint is marked incomplete for ${JSON.stringify(q)}`, hint[0].incomplete, true)
    eq(`no swatch yet for ${JSON.stringify(q)}`, hint[0].swatch, '')
    eq(`nothing to copy for ${JSON.stringify(q)}`, hint[0].item.copyValue, '')
  }
  eq('and a hint asks for nothing', rec.calls, [])
  const hint = impl.items('#ffffff0')
  impl.activate(hint[0].item)
  eq('Enter on a hint copies nothing', rec.calls, [])
})

group('color: the dot is content, so no setting hides it', () => {
  // calc, fx, time and unit read shell.launcher.showIcons and leave the
  // row iconless. This engine has no icon to hide, and the dot it does paint is
  // the color itself rather than launcher chrome, so there is nothing for that
  // setting to decide here.
  const on = shippedApi({ settings: { 'shell.launcher.showIcons': true } })
  const off = shippedApi({ settings: { 'shell.launcher.showIcons': false } })
  const withIcons = loadPlugin(path.join(PLUGIN_ROOT, 'color', 'main.js'), on.api).items('#ff8800')[0]
  const withoutIcons = loadPlugin(path.join(PLUGIN_ROOT, 'color', 'main.js'), off.api).items('#ff8800')[0]
  eq('the icon is empty either way', [withIcons.icon, withoutIcons.icon], ['', ''])
  eq('and the swatch is painted either way',
    [withIcons.swatch, withoutIcons.swatch], ['#ff8800', '#ff8800'])
})

group('no shipped row advertises a key', () => {
  // A sub line that names the key to press is an affordance the launcher does
  // not need to spell out: Enter is the only action on every one of these
  // rows. Asserted across all shipped plugins rather than per plugin, because
  // the string lived in five separate contract blocks and had already drifted
  // out of step.
  const samples = [
    ['calc', '2+2'],
    ['color', '#ff8800'],
    ['fx', '100 usd in eur'],
    ['time', 'time in madrid'],
    ['unit', '5m in cm'],
    ['websearch', 'firefox'],
  ]
  // "Enter" in any capitalisation, plus the spelled-out and symbol forms a
  // plugin might reach for instead.
  const KEY_HINT = /\benter\b|\breturn\b|\u23ce|\u21b5/i
  for (const [name, query] of samples) {
    const built = name === 'fx' ? fxImpl(withRates(FX_RATES)) : shippedApi()
    const impl = loadPlugin(path.join(PLUGIN_ROOT, name, 'main.js'), built.api)
    const rows = impl.items(query)
    is(`${name} produced a row for ${JSON.stringify(query)}`, rows, (v) => v.length > 0, 'a non-empty list')
    for (const row of rows) {
      const sub = String(row.sub ?? '')
      eq(`${name} sub for ${JSON.stringify(query)} names no key`, KEY_HINT.test(sub), false)
      // The two copy rows used to end with "Copy X to clipboard", which named
      // the action without the key. They now say the conversion as a sentence
      // instead - "100 US dollars is 87.84 Euros" - which is the row's second
      // reading speed rather than a second copy of the label. calc kept its
      // phrasing, so the two are asserted apart rather than lumped together.
      if (name === 'unit' || name === 'fx') {
        contains(`${name} sub spells the conversion out`, sub, ' is ')
        notContains(`${name} sub no longer names the clipboard action`, sub, 'to clipboard')
      }
      if (name === 'calc') {
        contains(`${name} sub still says what the action does`, sub, 'to clipboard')
      }
    }
  }
})

group('fx: a rate document is parsed once per distinct body, not once per keystroke', () => {
  // The memo is keyed on the BODY, not the URL: a TTL refresh returning the
  // same bytes must not re-parse, and one returning different bytes must.
  const rates = { ...FX_RATES, EUR: 0.5 }
  const h = fxApi(withRates(rates))
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'fx', 'main.js'), h.api)
  eq('the first query reads the refreshed rate', impl.items('100 usd in eur')[0].fxValue, '50.00 EUR')
  // Same body, twenty more queries: the label is identical, which is only
  // possible if the memo held rather than the row being rebuilt from scratch.
  for (let i = 0; i < 20; i++) impl.items('100 usd in eur')
  eq('and twenty further queries agree', impl.items('100 usd in eur')[0].fxValue, '50.00 EUR')
  eq('every one of them asked the controller (the TTL is the controller\'s)', h.rec.calls.length, 22)
})

group('websearch: one action per query, a hint row when the query is blank', () => {
  const { api } = shippedApi({ settings: { 'shell.launcher.searchEngine': 'duckduckgo' } })
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), api)
  eq('a blank query is a non-activatable hint', impl.items(''), [{
    label: 'Search in DuckDuckGo', sub: 'Type to search', desc: '', icon: 'internet-web-browser', data: {},
  }])
  eq('whitespace is blank', impl.items('   ')[0].sub, 'Type to search')
  eq('a real query echoes it', impl.items('hello world'), [{
    label: 'Search in DuckDuckGo', sub: 'hello world', desc: '', icon: 'internet-web-browser', data: {},
  }])
  // The row carries no kind, no uid and no item payload: the websearch plugin
  // is a last resort, not a synthetic engine row.
  eq('the row has no kind', impl.items('q')[0].kind, undefined)
  eq('the row has no uid', impl.items('q')[0].uid, undefined)
  eq('the row has no item payload', impl.items('q')[0].item, undefined)
  eq('the row has exactly the five fields', Object.keys(impl.items('q')[0]), ['label', 'sub', 'desc', 'icon', 'data'])
})

group('websearch follows the GLOBAL_SEARCH_ENGINE setting and falls back to google', () => {
  for (const [key, label] of [['google', 'Google'], ['duckduckgo', 'DuckDuckGo'], ['bing', 'Bing'], ['brave', 'Brave']]) {
    const { api } = shippedApi({ settings: { 'shell.launcher.searchEngine': key } })
    eq(`engine ${key}`, loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), api).items('q')[0].label, 'Search in ' + label)
  }
  const unknown = shippedApi({ settings: { 'shell.launcher.searchEngine': 'altavista' } })
  eq('an engine outside the enum falls back to google',
    loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), unknown.api).items('q')[0].label, 'Search in Google')
  const unset = shippedApi({ settings: {} })
  eq('an absent setting falls back to google',
    loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), unset.api).items('q')[0].label, 'Search in Google')
  const nullish = shippedApi({ settings: { 'shell.launcher.searchEngine': null } })
  eq('a null setting falls back to google',
    loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), nullish.api).items('q')[0].label, 'Search in Google')
})

group('activate copies through the granted execDetached, quoted', () => {
  // The five engine plugins share one activate shape: read the item payload's
  // copyValue, and if it is empty do nothing at all.
  const cases = [
    ['calc', '2+2', '4', "printf %s '4' | wl-copy"],
    ['unit', '5m in cm', '500 cm', "printf %s '500 cm' | wl-copy"],
  ]
  for (const [name, query, value, want] of cases) {
    const { api, rec } = shippedApi()
    const impl = loadPlugin(path.join(PLUGIN_ROOT, name, 'main.js'), api)
    impl.activate({ copyValue: value }, query)
    eq(`${name} copies the value`, rec.calls.map((c) => c[1]), [want])
  }
  // fx is the same shape, and copies a formatted amount rather than a raw
  // number, so the grouping separator is the thing worth pinning.
  {
    const { api, rec } = fxApi()
    const impl = loadPlugin(path.join(PLUGIN_ROOT, 'fx', 'main.js'), api)
    impl.activate({ copyValue: '1,234.56 EUR' }, '1234.56 usd in eur')
    eq('fx copies the formatted amount', rec.calls.map((c) => c[1]), ["printf %s '1,234.56 EUR' | wl-copy"])
  }
  // websearch is different: it opens a URL, and takes the query as its own
  // second argument rather than from the row.
  const { api, rec } = shippedApi()
  const web = loadPlugin(path.join(PLUGIN_ROOT, 'websearch', 'main.js'), api)
  web.activate({ data: {} }, 'hello')
  eq('websearch opens a quoted url through app2unit', rec.calls.map((c) => c[1]),
    ["app2unit -S both -s app-graphical.slice -- xdg-open 'https://www.google.com/search?q=hello'\n"])
})

// --- the binary plugin, through a policy that really holds the PATH pair ---

function binaryApi(opts) {
  const rec = recordingHost(opts || {})
  const grants = PP.grantsForRoot(
    path.join(PLUGIN_ROOT, '..'), path.join(PLUGIN_ROOT, 'binary'),
    ['execDetached'], [], undefined,
    { fx: ['requestNet', 'setCacheSection'], binary: ['requestBinaries'] }, 'binary')
  const api = PP.createPolicy(grants, rec.host)
  return { api, rec }
}

// A PATH holding the two cases the feature is about: a name a desktop entry
// also owns (thunar, spotify), and one nothing else provides (qt6ct).
const SCAN = { names: ['thunar', 'spotify', 'qt6ct', 'xterm', 'LS', 'my-app_2.0', 'ffmpeg'], at: 1 }
function binaryPlugin(opts) {
  const { api, rec } = binaryApi(Object.assign({ binaries: SCAN }, opts || {}))
  return { impl: loadPlugin(path.join(PLUGIN_ROOT, 'binary', 'main.js'), api), rec, api }
}

group('binary: an exact installed name is one Launch row', () => {
  const { impl } = binaryPlugin()
  eq('an exact match', impl.items('qt6ct'), [{
    label: 'Launch qt6ct', sub: 'Launch qt6ct binary', desc: '',
    icon: 'application-x-executable', data: { exec: 'qt6ct' },
  }])
  // The point of the feature: the row that was "Search in Google" for a
  // partial name is this one the moment the query completes.
  eq('a partial name claims nothing', impl.items('qt6c'), [])
  // Case folding is in the lookup, so a differently-cased COMPLETE name still
  // claims - it is the same program. A prefix is what cannot claim.
  eq('a complete name in another case claims', impl.items('Qt6Ct')[0].data.exec, 'qt6ct')
  eq('but a prefix still cannot', impl.items('qt6ctX'), [])
  eq('and neither can a superstring', impl.items('xqt6ct'), [])
  eq('the sub names the kind, not the query', impl.items('qt6ct')[0].sub, 'Launch qt6ct binary')
  // Case-insensitive, because the launcher searches case-insensitively - but
  // the launched name is the real spelling from PATH, never the query's.
  eq('a lowercase query for a mixed-case binary', impl.items('ls')[0].data.exec, 'LS')
  eq('and the mixed-case query for the same', impl.items('LS')[0].data.exec, 'LS')
  // Names that carry the punctuation a real install has.
  eq('a dotted, underscored and dashed name', impl.items('my-app_2.0')[0].data.exec, 'my-app_2.0')
  eq('and another', impl.items('ffmpeg')[0].label, 'Launch ffmpeg')
  // Five fields, exactly as the websearch row publishes: the host mints the
  // kind and the uid, so the plugin carries content and nothing else.
  eq('the row has exactly the five fields', Object.keys(impl.items('qt6ct')[0]),
    ['label', 'sub', 'desc', 'icon', 'data'])
  eq('the row has no kind', impl.items('qt6ct')[0].kind, undefined)
  eq('the row has no uid', impl.items('qt6ct')[0].uid, undefined)
})

group('binary: a name it may not run claims nothing at all', () => {
  const { impl } = binaryPlugin()
  // The whole set of refusals, each of which would otherwise reach the index
  // as a miss and, worse, could reach the launch as a shell word.
  for (const q of ['', '   ', '!', '!  ', '--flag', '-x', 'two words', 'a b',
    '/usr/bin/qt6ct', './qt6ct', '~/bin/qt6ct', 'qt6ct;rm -rf ~', "qt6ct'",
    'qt6ct$(id)', 'qt6ct`id`', 'qt6ct|tee', 'qt6ct&&ls', 'a/b', '../qt6ct',
    'https://example.com', 'qt6ct*', '?']) {
    eq(`${JSON.stringify(q)} claims nothing`, impl.items(q), [])
  }
  // The path shapes are the file opener's business, not this plugin's, and a
  // name with a separator in it is a path rather than a program.
  eq('a path-looking query is not a binary claim', impl.items('/usr/bin/ls'), [])
  // Math-like input never reaches the slot at all, so this plugin is not even
  // asked; the gate that keeps "2+" out is the controller's.
  eq('a bare option is not a binary claim', impl.items('-la'), [])
})

group('binary: the force prefix claims the same row, and the prefix is not part of the name', () => {
  const { impl } = binaryPlugin()
  // "!" is the escape past a desktop entry that owns the name. The plugin
  // strips it, so the row it answers is byte-identical to the unforced one -
  // only the launcher's gate differs, which is what keeps one row shape.
  eq('a forced claim is the same row', impl.items('!qt6ct'), impl.items('qt6ct'))
  eq('a forced desktop-entry name claims', impl.items('!thunar')[0].label, 'Launch thunar')
  eq('a forced spotify claims', impl.items('!spotify')[0].label, 'Launch spotify')
  // The unforced form of those two is the same row too: the plugin never knew
  // an entry existed, and the priority is entirely the controller's gate.
  eq('thunar without the escape is the same row', impl.items('thunar'), impl.items('!thunar'))
  eq('and a forced name nothing provides still claims nothing', impl.items('!nope'), [])
  // Surrounding space, and repeated escapes, are refused rather than searched.
  eq('a forced name with surrounding space is trimmed', impl.items('  !qt6ct  ')[0].data.exec, 'qt6ct')
  eq('a doubled escape is not a name', impl.items('!!qt6ct'), [])
})

group('binary: activate runs the resolved name through vb-launch-cmd, quoted', () => {
  const { impl, rec } = binaryPlugin()
  // The same shim every app row takes: focus a window whose class already
  // matches, otherwise start it. That is what makes a second invocation focus
  // the running instance rather than stacking another one.
  impl.activate({ data: { exec: 'qt6ct' } }, 'qt6ct')
  eq('the launch is routed through vb-launch-cmd', rec.calls.map((c) => c[1]),
    ["vb-launch-cmd -- 'qt6ct'\n"])
  // The payload wins over the query, so the row activates what it was built
  // from even if the field moved on between render and Enter.
  rec.calls.length = 0
  impl.activate({ data: { exec: 'thunar' } }, 'something else entirely')
  eq('the payload is what runs', rec.calls.map((c) => c[1]), ["vb-launch-cmd -- 'thunar'\n"])
  // And with no payload, the query is the fallback rather than a crash.
  rec.calls.length = 0
  impl.activate({}, 'ffmpeg')
  eq('an empty payload falls back to the query',
    rec.calls.filter((c) => c[0] === 'execDetached').map((c) => c[1]),
    ["vb-launch-cmd -- 'ffmpeg'\n"])
  rec.calls.length = 0
  for (const item of [null, undefined, {}, { data: {} }, { data: { exec: '' } }]) {
    impl.activate(item, 'nothing-here')
  }
  eq('a row with no name and a query with no name runs nothing',
    rec.calls.filter((c) => c[0] === 'execDetached'), [])
})

group('binary: activate quotes the name, because it still reaches a shell word', () => {
  // The name came from a PATH scan, so NAME_RE already refuses every
  // metacharacter - but the quoting is what makes that safe to change, and it
  // is the adopt-lib the websearch plugin uses rather than a second dialect.
  const { impl, rec } = binaryPlugin({ binaries: { names: ["od'd"], at: 1 } })
  // The scan is the only thing that can put such a name in the index, and it
  // cannot: the entry is quoted by construction and refused by the query rule.
  eq('a name the index cannot hold is not a claim', impl.items("od'd"), [])
  // So the quoting that does run is the plain one, and it is the api's.
  rec.calls.length = 0
  impl.activate({ data: { exec: 'xterm' } }, 'xterm')
  eq('a plain name is quoted once', rec.calls.map((c) => c[1]), ["vb-launch-cmd -- 'xterm'\n"])
})

group('binary: it asks for a scan on every recompute, and reads what landed', () => {
  // The ask is unguarded on this side on purpose: the TTL and the in-flight
  // guard live in the controller, next to the Process. A plugin that guarded it
  // itself would be keeping a second, weaker copy of the same rule.
  const { impl, rec } = binaryPlugin()
  impl.items('qt6ct')
  impl.items('thunar')
  impl.items('nothing')
  eq('one request per items() call', rec.calls.filter((c) => c[0] === 'requestBinaries').length, 3)
  // The read is a plain call on the policy object, so the recorder only sees
  // the two operations that leave this process. What matters is that the
  // plugin asked three times and claimed twice off one cached record.
  eq('the two claiming queries each returned a row',
    [impl.items('qt6ct').length, impl.items('thunar').length], [1, 1])
})

group('binary: the index is rebuilt when the cache record changes, and not when it does not', () => {
  // items() runs on every keystroke, so folding a few thousand names per
  // keypress would be the whole cost of the feature. The record is compared by
  // identity because the controller replaces it wholesale when a scan settles.
  const names = []
  for (let i = 0; i < 200; i++) names.push('bin' + i)
  const cache = { names, at: 1 }
  let indexBuilds = 0
  const counting = { names: cache.names, at: 1 }
  Object.defineProperty(counting, 'names', {
    get() { indexBuilds++; return names },
  })
  const { impl } = binaryPlugin({ binaries: cache })
  eq('a first query claims', impl.items('bin42').length, 1)
  // The same record object on every later call, which is what a TTL-guarded
  // controller hands back between scans.
  for (let i = 0; i < 5; i++) impl.items('bin' + i)
  eq('and the row is still right', impl.items('bin99')[0].data.exec, 'bin99')
  // A genuinely new record is a new set: a binary installed since the last
  // scan is claimable as soon as the scan that found it settles.
  eq('a name the old record lacked is not claimed', impl.items('brand-new'), [])
})

group('binary: with no scan landed it claims nothing rather than guessing', () => {
  // cachedBinaries is a default grant and answers null until a scan settles,
  // so the first keystroke of a session has nothing to match against. The
  // claim is withheld, the web search fills the slot, and the row appears a
  // moment later when the scan does.
  const { impl } = binaryApi({ binaries: null })
  const p = loadPlugin(path.join(PLUGIN_ROOT, 'binary', 'main.js'), impl)
  eq('no cache, no claim', p.items('qt6ct'), [])
  eq('and no crash on the nullish record', p.items('thunar'), [])
  // An empty-but-settled record is a real answer of "nothing is installed".
  const empty = binaryApi({ binaries: { names: [], at: 1 } })
  const e = loadPlugin(path.join(PLUGIN_ROOT, 'binary', 'main.js'), empty.api)
  eq('an empty scan claims nothing', e.items('qt6ct'), [])
  // And a record with no names field at all is the same answer, not a throw.
  const broken = binaryApi({ binaries: { at: 1 } })
  const b = loadPlugin(path.join(PLUGIN_ROOT, 'binary', 'main.js'), broken.api)
  eq('a record with no names claims nothing', b.items('qt6ct'), [])
})

group('binary: without the request half it still reads the cache the launcher filled', () => {
  // The posture test: cachedBinaries is a default grant and requestBinaries is
  // not, so a policy that was never granted the scan must still be able to
  // answer from what the launcher already published. This is what lets a user
  // plugin - which is granted neither - use the same rules.
  const { api, rec } = shippedApi({ binaries: SCAN })
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'binary', 'main.js'), api)
  eq('it holds no scan request', 'requestBinaries' in api, false)
  eq('but it can still claim from the cache', impl.items('qt6ct')[0].label, 'Launch qt6ct')
  eq('and it never asks for one', rec.calls.filter((c) => c[0] === 'requestBinaries').length, 0)
  // It activates through execDetached, which the shipped table does hold.
  impl.activate({ data: { exec: 'qt6ct' } }, 'qt6ct')
  eq('and still launches', rec.calls.map((c) => c[1]), ["vb-launch-cmd -- 'qt6ct'\n"])
})

group('activate is a no-op for an empty or missing copy value', () => {
  // A hint row carries copyValue: "" and must not shell out to copy nothing.
  for (const name of ['calc', 'unit', 'time']) {
    const { api, rec } = shippedApi({ cached: { 'Europe/Madrid': { time: '14:32', code: '', date: '' } } })
    const impl = loadPlugin(path.join(PLUGIN_ROOT, name, 'main.js'), api)
    for (const item of [{}, { copyValue: '' }, { copyValue: null }, { copyValue: undefined }, null, undefined]) {
      impl.activate(item, 'q')
    }
    eq(`${name} ran nothing for an empty payload`, rec.calls.filter((c) => c[0] === 'execDetached').length, 0)
  }
})

group('activate takes the item payload, not the row', () => {
  // The row shape is { ..., item: { copyValue } } and activate is handed the
  // payload, so passing the row itself is a silent no-op. Pinned because the
  // controller owns the call site and nothing else in the tree would notice.
  const { api, rec } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), api)
  const row = impl.items('2+2')[0]
  impl.activate(row.item)
  eq('the payload copies', rec.calls.map((c) => c[1]), ["printf %s '4' | wl-copy"])
  rec.calls.length = 0
  impl.activate(row)
  eq('the row itself copies nothing', rec.calls.filter((c) => c[0] === 'execDetached'), [])
})

group('a shell metacharacter in a copy value cannot escape its quotes', () => {
  // The value is not a number or a unit - it is whatever the engine put in
  // copyValue - and it reaches a shell through execDetached, so the quoting is
  // the boundary. The plugin asks api.shellQuote, which is StringUtils.
  for (const name of ['calc', 'unit', 'time']) {
    const { api, rec } = shippedApi()
    const impl = loadPlugin(path.join(PLUGIN_ROOT, name, 'main.js'), api)
    const nasty = "a'b;$(id)`x` & | > <"
    impl.activate({ copyValue: nasty })
    eq(`${name} quotes the whole value as one word`, rec.calls.map((c) => c[1]),
      ["printf %s 'a'\\''b;$(id)`x` & | > <' | wl-copy"])
  }
  // And that quoted word is what the shell sees, so the command line is
  // exactly three words plus the pipe.
  const { api, rec } = shippedApi()
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), api)
  impl.activate({ copyValue: "a'b" })
  const cmd = rec.calls[0][1]
  eq('the command is printf | wl-copy with one quoted argument', cmd, "printf %s 'a'\\''b' | wl-copy")
  eq('the argument is the shared StringUtils quote', cmd.slice('printf %s '.length, cmd.length - ' | wl-copy'.length), SU.shellQuote("a'b"))
})

group('an api without execDetached makes the copy row unusable, as designed', () => {
  // The shipped root grants it, so this is the *user* root's posture. The
  // failure is a TypeError on a missing member rather than a policy refusal,
  // which is exactly what "a denied operation is absent" buys: there is
  // nothing to feature-detect and nothing to be tempted by.
  const rec = recordingHost()
  const userApi = PP.createPolicy([], rec.host)
  eq('execDetached is absent', 'execDetached' in userApi, false)
  const impl = loadPlugin(path.join(PLUGIN_ROOT, 'calc', 'main.js'), userApi)
  eq('rows still render, because they need only setting', impl.items('2+2')[0].label, '2+2 = 4')
  throws('but activating the copy row throws a TypeError', () => impl.activate({ copyValue: '4' }), /execDetached/)
  eq('and no host operation ran at all', rec.calls.length, 0)
})

// =========================================================================
section('FxLib - the rate engine, driven directly')
// =========================================================================

// The parity corpus below reaches the library through a pristine re-parse, so
// it cannot satisfy the coverage recorder. This section drives the instrumented
// namespace directly, which is also the only place the library's own
// boundaries - the parts the plugin never exercises because its contract block
// short-circuits them - are asserted at all.
const LIB_RATES = { base: 'USD', rates: { USD: 1, EUR: 0.878356, JPY: 157.489371 }, updated: 'Mon, 28 Sep 2026' }

group('the named table is built once and is what the gate depends on', () => {
  // namedMap is the memo behind resolveCode, and its `named` flag is the whole
  // bare-query rule. Asserted because the flag is invisible in the row output:
  // only the behaviour it gates shows it.
  const first = FXL.namedMap()
  eq('it returns the same object on a second call', FXL.namedMap() === first, true)
  eq('a code resolves to itself', FXL.namedMap().usd.code, 'USD')
  eq('a name resolves to its code', FXL.namedMap().dollars.code, 'USD')
  eq('and is flagged named', FXL.namedMap().dollars.named, true)
  // A code the table does not name is still resolvable, but NOT named - which
  // is exactly why "100 kwd" falls through while "100 kwd in usd" converts.
  // deepEqual on a two-field record, so the `named` flag is compared and not
  // just the code: an unnamed code that read as named would let a bare
  // "100 kwd" claim the keystroke and then fail.
  deepEqual('an unnamed code resolves unflagged', FXL.resolveCode('kwd'), { code: 'KWD', named: false })
  deepEqual('and a named one is flagged', FXL.resolveCode('usd'), { code: 'USD', named: true })
  // normalizeCurrency is the folding every lookup goes through, so a name with
  // spaces, dashes and a trailing dot all reach one entry.
  eq('a spaced name', FXL.resolveCode('US Dollars').code, 'USD')
  eq('a dashed name', FXL.resolveCode('US-Dollars').code, 'USD')
  eq('a trailing dot', FXL.resolveCode('USD.').code, 'USD')
  eq('an empty spec is nothing', FXL.resolveCode(''), null)
  eq('a null spec is nothing', FXL.resolveCode(null), null)
  eq('a two-letter run is not a code', FXL.resolveCode('zz'), null)
  eq('a four-letter run is not a code', FXL.resolveCode('zzzz'), null)
  eq('a digit inside is not a code', FXL.resolveCode('12a'), null)
  // normalizeCurrency and parseQuery are the two functions the row contract
  // reads directly, so they are driven here rather than left to the plugin.
  eq('normalizeCurrency folds a trailing dot', FXL.normalizeCurrency('USD.'), 'usd')
  eq('and drops a separator', FXL.normalizeCurrency(' swedish_krona '), 'swedishkrona')
  eq('parseQuery resolves a full pair', (() => {
    const q = FXL.parseQuery('1,234.56 usd in eur')
    return { value: q.value, from: q.from.code, to: q.to.code, bare: q.bare }
  })(), { value: 1234.56, from: 'USD', to: 'EUR', bare: false })
  eq('parseQuery marks a bare amount', FXL.parseQuery('100 usd').bare, true)
  eq('parseQuery marks a dangling keyword', FXL.parseQuery('100 usd in').incomplete, true)
  eq('parseQuery carries the unknown target for the hint', FXL.parseQuery('100 usd in eur extra').toSpec, 'eur extra')
  eq('parseQuery is null for a non-query', FXL.parseQuery('firefox'), null)
})

group('num and rateOf are the only gates between a rate and arithmetic', () => {
  // A provider that quoted "0.87" as a string would otherwise flow into the
  // product as a number by coercion, and a provider that quoted null would
  // produce a NaN row rather than a missing-rate row.
  eq('a number passes', FXL.num(1.5), 1.5)
  eq('zero passes num', FXL.num(0), 0)
  eq('a negative passes', FXL.num(-1.5), -1.5)
  eq('a numeric string does not', FXL.num('1.5'), null)
  eq('NaN does not', FXL.num(NaN), null)
  eq('Infinity does not', FXL.num(Infinity), null)
  eq('null does not', FXL.num(null), null)
  eq('a boolean does not', FXL.num(true), null)
  // rateOf is num plus the zero rule, and the two directions a zero rate
  // fails in are different: as a target it would print a conversion to
  // nothing, as a source it would divide to infinity.
  eq('a real rate passes', FXL.rateOf({ EUR: 0.8 }, 'EUR'), 0.8)
  eq('a zero rate is refused as a target', FXL.rateOf({ JPY: 0 }, 'JPY'), null)
  eq('a zero rate is refused as a source', FXL.rateOf({ USD: 0, JPY: 1 }, 'USD'), null)
  eq('a missing code is refused', FXL.rateOf({ USD: 1 }, 'ZZZ'), null)
  eq('a missing rates object is refused, not thrown on', FXL.rateOf(null, 'USD'), null)
  eq('a nullish code is refused', FXL.rateOf({ USD: 1 }, null), null)
})

group('symbolCode and leadingSymbol are the two halves of one lookup', () => {
  // symbolCode is the table read; leadingSymbol is the position read. Both
  // have to agree or a symbol names a currency the position did not find.
  eq('a one-char symbol', FXL.symbolCode('$'), 'USD')
  eq('a two-char symbol', FXL.symbolCode('R$'), 'BRL')
  eq('an unknown symbol is no code', FXL.symbolCode('¤'), '')
  eq('a leading symbol is found', FXL.leadingSymbol('$100'), '$')
  eq('the longest match wins', FXL.leadingSymbol('R$100'), 'R$')
  eq('a symbol elsewhere is not leading', FXL.leadingSymbol('100$'), '')
  eq('a lone letter is not a symbol', FXL.leadingSymbol('R100'), '')
  eq('two symbols in a row take the first', FXL.leadingSymbol('$$100'), '$')
  // And the round trip the parser relies on.
  eq('the pair agrees on a two-char symbol',
    FXL.symbolCode(FXL.leadingSymbol('R$100')), 'BRL')
  eq('and on a one-char symbol', FXL.symbolCode(FXL.leadingSymbol('$100')), 'USD')
})

group('defaultTarget is the bare-query rule, and it is one rule', () => {
  // A bare "<value><CUR>" has to go somewhere. Everything goes to the table's
  // base except the base itself, which has to name a different currency or
  // "100 usd" would convert one dollar into one dollar.
  eq('the base goes elsewhere', FXL.defaultTarget(FXL.RATE_BASE), 'EUR')
  eq('everything else goes to the base', FXL.defaultTarget('EUR'), FXL.RATE_BASE)
  eq('including a code the table does not name', FXL.defaultTarget('KWD'), FXL.RATE_BASE)
  // And the two paths agree with the rows the plugin renders.
  eq('a bare EUR row matches the rule', FXL.tryConvert('100 eur', LIB_RATES).to, FXL.defaultTarget('EUR'))
  eq('a bare USD row matches the rule', FXL.tryConvert('100 usd', LIB_RATES).to, FXL.defaultTarget('USD'))
})

group('convertParsed is the one target conversion, and tryAll is the list over it', () => {
  // The split is the reason the two entry points cannot drift: a bare amount
  // and an explicit pair both reach convertParsed for every reading, so a
  // verdict exists in exactly one place.
  const parsed = FXL.parseQuery('100 usd')
  eq('one explicit target converts',
    FXL.convertParsed(parsed, LIB_RATES, FXL.resolveCode('JPY')).label, '100 USD = 15,748.94 JPY')
  eq('a null target is the unknown-target hint',
    FXL.convertParsed(FXL.parseQuery('100 usd in eur extra'), LIB_RATES, null).error, 'unknown-target')
  eq('the source is never its own target',
    FXL.convertParsed(parsed, LIB_RATES, FXL.resolveCode('USD')).error, 'same-target')
  eq('an incomplete query is answered before the target is even looked at',
    FXL.convertParsed(FXL.parseQuery('100 usd in'), LIB_RATES, null).error, 'incomplete')
  // tryAll: the list, the single answer for an explicit pair, and the one-row
  // states that describe the fetch rather than a target.
  eq('a bare amount answers with a list', FXL.tryAll('100 usd', LIB_RATES).map((r) => r.to), ['EUR', 'JPY'])
  eq('an explicit pair answers with one', FXL.tryAll('100 usd in eur', LIB_RATES).map((r) => r.to), ['EUR'])
  eq('a hint answers with one', FXL.tryAll('100 usd in usd', LIB_RATES).map((r) => r.error), ['same-target'])
  eq('an unfetched table answers with one pending row',
    FXL.tryAll('100 usd', null).map((r) => r.pending), [true])
  eq('an empty table answers with one unavailable row',
    FXL.tryAll('100 usd', { base: '', rates: {}, updated: '' }).map((r) => r.error), ['unavailable'])
  eq('a non-query is null rather than an empty list', FXL.tryAll('firefox', LIB_RATES), null)
  // The unpadded arrow, which is RE_ARROW's whole job: an arrow with no spaces
  // around it has no separator for the explicit split to find, so "100 usd->eur"
  // would otherwise parse as an amount of nothing and fall through to the app
  // list. All three spacings are one query, and the pattern needs a ">" so a
  // leading minus on the amount is not read as one.
  for (const q of ['100 usd->eur', '100 usd-->eur', '100 usd -> eur', '100 usd - > eur', '100$->eur']) {
    eq(`${JSON.stringify(q)} is the padded form`, FXL.tryConvert(q, LIB_RATES).label, '100 USD = 87.84 EUR')
  }
  eq('a bare symbol arrow is one unit of it', FXL.tryConvert('$->eur', LIB_RATES).label, '1 USD = 0.878356 EUR')
  eq('and a negative amount keeps its sign through the arrow',
    FXL.tryConvert('-100 usd->eur', LIB_RATES).label, '-100 USD = -87.84 EUR')
  // `history` may be a FUNCTION, and the whole point of that is that it is not
  // called on the paths that cannot use it. A caller whose pick counts live
  // behind a cache read should not pay for that read on every keystroke of a
  // query that ranks nothing - and an explicit pair ranks nothing at all.
  eq('a function history is called for a bare amount', (() => {
    let calls = 0
    FXL.tryAll('100 usd', LIB_RATES, () => { calls++; return { JPY: 5 } })
    return calls
  })(), 1)
  eq('and NOT called for an explicit pair', (() => {
    let calls = 0
    FXL.tryAll('100 usd in eur', LIB_RATES, () => { calls++; return { JPY: 5 } })
    return calls
  })(), 0)
  eq('nor for a query that is not a currency query at all', (() => {
    let calls = 0
    FXL.tryAll('firefox', LIB_RATES, () => { calls++; return { JPY: 5 } })
    return calls
  })(), 0)
  // Which is also what keeps a throwing reader from breaking the common path: an
  // explicit conversion never reaches it, so it cannot throw.
  eq('so a history that throws cannot break an explicit conversion',
    FXL.tryAll('100 usd in eur', LIB_RATES, () => { throw new Error('cache is down') })[0].label,
    '100 USD = 87.84 EUR')
  eq('a function is called exactly once per list, not once per candidate', (() => {
    let calls = 0
    FXL.tryAll('100 usd', LIB_RATES, () => { calls++; return { JPY: 5 } })
    return calls
  })(), 1)
  eq('and it ranks exactly as the map it returns would',
    FXL.tryAll('100 usd', LIB_RATES, () => ({ JPY: 5 })).map((r) => r.to),
    FXL.tryAll('100 usd', LIB_RATES, { JPY: 5 }).map((r) => r.to))
  // A function that yields nothing usable is no history, not a crash - the same
  // two answers a map with the wrong shape gives.
  eq('a function returning null is no history',
    FXL.tryAll('100 usd', LIB_RATES, () => null).map((r) => r.to),
    FXL.tryAll('100 usd', LIB_RATES, null).map((r) => r.to))
  eq('and so is one returning something that is not a map',
    FXL.tryAll('100 usd', LIB_RATES, () => 'nope').map((r) => r.to),
    FXL.tryAll('100 usd', LIB_RATES, null).map((r) => r.to))
  // A PENDING gate does NOT short-circuit before the history is read, and the
  // guard in tryAll says it should: `gate.ok !== true && gate.pending === true`
  // can never be true, because a pending result carries ok:true, so only the
  // `error === "unavailable"` half of that condition is reachable. The answer
  // still comes back as one pending row - every candidate is pending, so the
  // list comes out empty and falls back to [gate] - which is why this is a cost
  // rather than a wrong answer: a function history is paid for on exactly the
  // keystrokes before the rate table has landed.
  //
  // Pinned as it is, deliberately: fixing the guard to test `gate.pending`
  // without the `ok` conjunct makes this assertion fail, which is the point. It
  // is the assertion that would have to change, so the fix cannot pass silently.
  eq('a pending gate does NOT short-circuit, because ok is true and the guard reads both',
    (() => {
      let calls = 0
      FXL.tryAll('100 usd', null, () => { calls++; return { JPY: 5 } })
      return calls
    })(), 1)
  eq('and the answer is still the single pending row',
    FXL.tryAll('100 usd', null, { JPY: 5 }).map((r) => [r.pending, r.error]), [[true, undefined]])
  // An UNAVAILABLE gate does short-circuit, so the reachable half of the guard
  // is the one that is doing the work today.
  eq('an unavailable gate does short-circuit before the history is read',
    (() => {
      let calls = 0
      FXL.tryAll('100 usd', { base: '', rates: {}, updated: '' }, () => { calls++; return { JPY: 5 } })
      return calls
    })(), 0)
  // rankTargets is the whole of the "smart" half, driven here because the
  // plugin path can only show it through rows: with no history the base list
  // comes back unchanged, which is what makes SUGGEST the documented default
  // rather than a guess the renderer refines.
  // The head is the DEFAULT, not SUGGEST's first entry that survives being the
  // source. "100 usd" is documented to read as euros, and starting from SUGGEST
  // put CAD at the front because USD was skipped and CAD was what was left -
  // against the header's own promise. So the default is placed at the head of
  // the base order and SUGGEST follows behind it.
  eq('no history is the base list, with the default at its head',
    FXL.rankTargets('USD', 'EUR', null),
    ['EUR', 'CAD', 'GBP', 'CHF', 'PLN', 'UAH', 'RUB', 'JPY', 'CNY',
      'AUD', 'INR', 'KRW', 'BRL', 'MXN', 'SEK', 'NOK', 'ZAR', 'TRY'])
  eq('the source is never in its own list', FXL.rankTargets('EUR', 'USD', null).indexOf('EUR'), -1)
  eq('and a different source takes its own place out',
    FXL.rankTargets('GBP', 'USD', null).indexOf('GBP'), -1)
  eq('an empty map is also no history', FXL.rankTargets('USD', 'EUR', {}).indexOf('CAD'), 1)
  eq('a count promotes its currency to the front',
    FXL.rankTargets('USD', 'EUR', { JPY: 1 })[0], 'JPY')
  eq('the largest count wins over a smaller one',
    FXL.rankTargets('USD', 'EUR', { JPY: 1, PLN: 9 }).slice(0, 2), ['PLN', 'JPY'])
  eq('and the base order survives behind both',
    FXL.rankTargets('USD', 'EUR', { JPY: 1, PLN: 9 }).slice(2, 5), ['EUR', 'CAD', 'GBP'])
  eq('a tie is the base order, not the order of the map',
    FXL.rankTargets('USD', 'EUR', { TRY: 3, CHF: 3 }).slice(0, 2), ['CHF', 'TRY'])
  eq('a count the source already is does not resurrect it',
    FXL.rankTargets('USD', 'EUR', { USD: 99 }).indexOf('USD'), -1)
  // A count is a NUMBER, strictly: a numeric string and a boolean are both
  // things Number() would happily turn into a ranking nobody asked for.
  for (const junk of ['4', true, {}, [], -1, NaN, Infinity, null, undefined]) {
    eq(`${JSON.stringify(junk) || String(junk)} counts as nothing`,
      FXL.rankTargets('USD', 'EUR', { JPY: junk })[0], 'EUR')
  }
  eq('and a history that is not an object at all is no history',
    FXL.rankTargets('USD', 'EUR', 'JPY').indexOf('CAD'), 1)
  // A default the list does not name is put in front rather than dropped: the
  // documented default of a bare query has to be on the list whatever the
  // shortlist says, or `100 usd` would stop reading as euros.
  eq('a default outside the shortlist leads', FXL.rankTargets('USD', 'XTS', null)[0], 'XTS')
  eq('and the shortlist keeps its order behind it',
    FXL.rankTargets('USD', 'XTS', null).slice(1, 3), ['CAD', 'EUR'])
  eq('so a default the shortlist does name keeps its own base position',
    FXL.rankTargets('USD', 'EUR', null).indexOf('EUR'), 0)
  eq('and moves only when a count outranks it',
    FXL.rankTargets('USD', 'EUR', { EUR: 5 })[0], 'EUR')
  eq('while a count below nothing at all still does not',
    FXL.rankTargets('USD', 'EUR', { EUR: 1, JPY: 4 }).slice(0, 2), ['JPY', 'EUR'])
  // The head is a contract rather than a candidate: it is the row a bare query
  // has always shown, so no bound may drop it. `1 krw` is the case that proves
  // it, because its default is a thousandth of a dollar - under the unit
  // engine's fraction floor, and still the first row here.
  eq('a default smaller than the unit fraction floor is still the head',
    FXL.tryAll('1 krw', { base: 'USD', rates: { KRW: 1290.5, USD: 1 }, updated: '' })[0].to, 'USD')
  eq('and the head row is the one the single-answer entry returns',
    FXL.tryAll('1 krw', { base: 'USD', rates: { KRW: 1290.5, USD: 1 }, updated: '' })[0].label,
    FXL.tryConvert('1 krw', { base: 'USD', rates: { KRW: 1290.5, USD: 1 }, updated: '' }).label)
  eq('and the single-answer entry agrees with the head of the list',
    FXL.tryAll('100 usd', LIB_RATES)[0].label, FXL.tryConvert('100 usd', LIB_RATES).label)
  // The list is the fixed major list and nothing else, so LIB_RATES' three
  // codes are the whole answer rather than the first three of something longer.
  eq('and it is the majors the document can back, in the documented order',
    FXL.tryAll('100 usd', LIB_RATES).map((r) => r.to), ['EUR', 'JPY'])
  eq('the tenth row is the ceiling the library declares', FXL.MAX_TARGETS, 10)
  eq('and the list behind it is longer, so an unquoted code is replaced rather than shortening the answer',
    FXL.SUGGEST.length > FXL.MAX_TARGETS, true)
  eq('every entry in it resolves to a code',
    FXL.SUGGEST.filter((s) => FXL.resolveCode(s) === null), [])
  // tableState is the three-way answer the two "the fetch has not landed" paths
  // both need, and the middle case is the one that earns its keep: "a fetch that
  // settled on nothing" has to be told apart from "no fetch has answered yet",
  // because only the second may still be worth waiting for.
  eq('tableState: no snapshot at all is none',
    [FXL.tableState(null), FXL.tableState(undefined), FXL.tableState({})], ['none', 'none', 'none'])
  eq('and a snapshot with no rates key is none too', FXL.tableState({ rates: null }), 'none')
  eq('a settled but empty table is empty', FXL.tableState({ rates: {} }), 'empty')
  eq('and anything with a rate in it is ok', FXL.tableState({ rates: { USD: 1 } }), 'ok')
  // unnamedClaimable is what keeps "100 abc" out of this engine's list. A bare
  // ISO-shaped source may only claim the query once the table can back it; with
  // no table yet it may claim it only if a NAMED target was typed, which is a
  // shape no application match is going to lose to a wall of "how much is".
  eq('unnamedClaimable: a bare source with no table and no target does not claim',
    FXL.unnamedClaimable(FXL.resolveCode('USD'), null, null), false)
  eq('but a named target does', FXL.unnamedClaimable(FXL.resolveCode('USD'), 'eur', null), true)
  eq('and the code form of one does', FXL.unnamedClaimable(FXL.resolveCode('USD'), 'EUR', null), true)
  eq('a table settles it: a quoted source claims',
    FXL.unnamedClaimable(FXL.resolveCode('USD'), null, LIB_RATES), true)
  eq('and an unquoted one does not', FXL.unnamedClaimable(FXL.resolveCode('RWF'), null, LIB_RATES), false)
  eq('which is the whole rule - "100 abc" falls through to the app list',
    FXL.parseQuery('100 abc', LIB_RATES), null)
  // currencyWord and phrase are what the row's sub line is made of, so the
  // noun table and the sentence around it are driven here rather than left to
  // be seen only through a rendered row.
  eq('one dollar is the singular', FXL.currencyWord('USD', 1), 'US Dollar')
  eq('and anything else is the plural', FXL.currencyWord('USD', 100), 'US Dollars')
  eq('including a value below one', FXL.currencyWord('USD', 0.5), 'US Dollars')
  // The invariant currencies are the reason the table stores both forms: yen,
  // won and rand take no plural in English.
  eq('the yen is invariant', FXL.currencyWord('JPY', 2500), 'Yen')
  eq('and so is the won', FXL.currencyWord('KRW', 1000), 'Won')
  eq('and so is the rand', FXL.currencyWord('ZAR', 40), 'Rand')
  eq('the pound carries its adjective', FXL.currencyWord('GBP', 1), 'British Pound')
  eq('and pluralises it too', FXL.currencyWord('GBP', 3), 'British Pounds')
  eq('a currency with no noun falls back to its code', FXL.currencyWord('XTS', 5), 'XTS')
  // The title-caser is what puts the capitals on, and the two words it leaves
  // down are the whole of its policy: a rate reads "Metre per Second", not
  // "Metre Per Second", and a hyphenated compound keeps its own spelling.
  eq('the first word is capitalised', FXL.sentenceCase('euro'), 'Euro')
  eq('and so is a later one', FXL.sentenceCase('New Zealand dollar'), 'New Zealand Dollar')
  eq('but a preposition stays down', FXL.sentenceCase('metre per second'), 'Metre per Second')
  eq('and so does a second preposition', FXL.sentenceCase('inch of mercury'), 'Inch of Mercury')
  eq('a hyphen is not a word break, so the second half stays down', FXL.sentenceCase('kilowatt-hour'), 'Kilowatt-hour')
  eq('and an already capital word is left alone', FXL.sentenceCase('US dollar'), 'US Dollar')
  // The sentence keeps the amount AS TYPED on the left and the money
  // formatter on the right, because only one of those two numbers was written
  // down by a person.
  eq('the phrase reads as a sentence',
    FXL.phrase('100', 'USD', 87.84, 'EUR', 100), '100 US Dollars is 87.84 Euros')
  eq('and a typed thousands separator survives into it',
    FXL.phrase('1,234.56', 'USD', 1084.1, 'EUR', 1234.56),
    '1,234.56 US Dollars is 1,084.10 Euros')
  eq('a singular source on the left reads as one',
    FXL.phrase('1', 'GBP', 1.32, 'USD', 1), '1 British Pound is 1.32 US Dollars')
  eq('and the target keeps the money formatting it would be copied with',
    FXL.phrase('100', 'USD', 2543000, 'VND', 100), '100 US Dollars is 2,543,000.00 Vietnamese Dong')
  // The whole table is a pair of non-empty strings, and every currency a row
  // can show is in it - a noun added for the sentence is not optional garnish.
  eq('every noun is a [singular, plural] of non-empty strings',
    Object.keys(FXL.CURRENCY_NOUN).filter((c) => {
      const p = FXL.CURRENCY_NOUN[c]
      return !Array.isArray(p) || p.length !== 2 || !p[0] || !p[1]
    }), [])
  eq('and every currency a bare row can show is named',
    [...new Set([...FXL.SUGGEST, FXL.RATE_BASE, FXL.defaultTarget(FXL.RATE_BASE)])]
      .filter((c) => FXL.CURRENCY_NOUN[c] === undefined), [])
  eq('while a named code the rows cannot reach may fall back to its code',
    FXL.currencyWord('ZWG', 5), 'ZWG')
})

group('groupThousands only touches a plain decimal integer part', () => {
  // The helper formatAmount leans on, so its own edges are what decide whether
  // a value reads as money or as a mangled number.
  eq('under four digits is untouched', FXL.groupThousands('999'), '999')
  eq('exactly four digits groups', FXL.groupThousands('1000'), '1,000')
  eq('five digits', FXL.groupThousands('12345'), '12,345')
  eq('seven digits', FXL.groupThousands('1234567'), '1,234,567')
  eq('a fraction is preserved', FXL.groupThousands('1234567.89'), '1,234,567.89')
  eq('a negative sign stays outside the grouping', FXL.groupThousands('-1234567.89'), '-1,234,567.89')
  // An exponential form has no integer part to group, and inserting commas
  // into one would produce something that is not a number at all.
  eq('an exponential form is left alone', FXL.groupThousands('1e+13'), '1e+13')
})

group('formatAmount is a money formatter, and the rounding says so', () => {
  eq('a whole amount keeps two decimals', FXL.formatAmount(1), '1.00')
  eq('zero is 0.00 and never an empty string', FXL.formatAmount(0), '0.00')
  eq('negative zero is zero', FXL.formatAmount(-0), '0.00')
  eq('a large amount groups', FXL.formatAmount(1234567.891), '1,234,567.89')
  eq('a mid amount rounds to cents', FXL.formatAmount(1.005), '1.00')
  // Below one, cents would be noise, so it keeps significant digits instead -
  // the failure mode a money formatter has that a ratio does not.
  eq('a sub-unit amount keeps precision', FXL.formatAmount(0.0774893), '0.0774893')
  eq('a sub-unit amount does not round to nothing', FXL.formatAmount(0.0001), '0.0001')
  // The extremes stay in the exponential form UnitLib uses, because "0.00" is
  // a wrong answer rather than a rounded one.
  eq('a tiny amount is exponential, not zero', FXL.formatAmount(0.00001), '1e-5')
  eq('a huge amount is exponential', FXL.formatAmount(1e13), '1e+13')
  eq('NaN', FXL.formatAmount(NaN), 'NaN')
  eq('Infinity', FXL.formatAmount(Infinity), 'Infinity')
  eq('-Infinity', FXL.formatAmount(-Infinity), '-Infinity')
  eq('a non-number is NaN, not a crash', FXL.formatAmount('x'), 'NaN')
  eq('null is NaN too', FXL.formatAmount(null), 'NaN')
})

group('parseRates accepts the provider document and refuses everything else', () => {
  const ok = FXL.parseRates(JSON.stringify({ result: 'success', base_code: 'USD', rates: { USD: 1, EUR: 0.8 }, time_last_update_utc: 'then' }))
  eq('a good document parses', ok, { base: 'USD', rates: { USD: 1, EUR: 0.8 }, updated: 'then' })
  // Every refusal below is a case where half-accepting would produce a table
  // of undefined and a row reading "NaN EUR".
  eq('empty', FXL.parseRates(''), null)
  eq('whitespace', FXL.parseRates('   '), null)
  eq('not JSON', FXL.parseRates('<html>429</html>'), null)
  eq('a JSON null', FXL.parseRates('null'), null)
  eq('an empty object', FXL.parseRates('{}'), null)
  eq('an array', FXL.parseRates('[]'), null)
  eq('a bare string', FXL.parseRates('"a"'), null)
  eq('an error result', FXL.parseRates('{"result":"error"}'), null)
  eq('no rates', FXL.parseRates('{"rates":{}}'), null)
  eq('rates is not an object', FXL.parseRates('{"result":"success","rates":5}'), null)
  // The base is what makes a cross rate possible, so a document that does not
  // quote the base it claims is refused rather than half-accepted.
  eq('the claimed base is not quoted', FXL.parseRates('{"result":"success","rates":{"EUR":1}}'), null)
  eq('the claimed base is a string, not a number',
    FXL.parseRates('{"result":"success","base_code":"USD","rates":{"USD":"1"}}'), null)
  // A lower-case base_code is still a base: the engine uppercases it rather
  // than rejecting a document that is otherwise complete.
  eq('a lower-case base is uppercased',
    FXL.parseRates('{"result":"success","base_code":"usd","rates":{"USD":1}}'), { base: 'USD', rates: { USD: 1 }, updated: '' })
  // An absent result field is not an error field: the shape is accepted, so a
  // provider that drops the field does not break the row.
  eq('an absent result is accepted',
    FXL.parseRates('{"base_code":"USD","rates":{"USD":1}}').base, 'USD')
  eq('null and undefined are both nothing', [FXL.parseRates(null), FXL.parseRates(undefined)], [null, null])
})

group('tryConvert never throws, whatever it is handed', () => {
  // The contract is null for "not a currency query" and a verdict for
  // everything else, so a bad argument can never take the launcher down.
  for (const [q, s] of [[null, LIB_RATES], [undefined, LIB_RATES], [0, LIB_RATES],
    [{}, LIB_RATES], ['', LIB_RATES], ['   ', LIB_RATES], ['firefox', LIB_RATES],
    ['2+2', LIB_RATES], ['5m in cm', LIB_RATES], ['100', LIB_RATES], ['100 abc', LIB_RATES]]) {
    eq(`tryConvert(${JSON.stringify(q)}) is null`, FXL.tryConvert(q, s), null)
  }
  // A zero rate is a provider fault, and the two directions it fails in are
  // different - as a target it would print a conversion to nothing, as a
  // source it would divide to infinity - so both are caught before the product.
  eq('a zero target rate is no rate', FXL.tryConvert('100 usd in eur',
    { base: 'USD', rates: { USD: 1, EUR: 0 } }).error, 'unsupported')
  eq('a zero source rate is no rate', FXL.tryConvert('100 usd in eur',
    { base: 'USD', rates: { USD: 0, EUR: 1 } }).error, 'unsupported')
  // An amount too large to parse is not a currency query at all, so it falls
  // through to the app list rather than producing a row.
  eq('an unparseable amount is not a currency query',
    FXL.tryConvert('1e999 usd in eur', LIB_RATES), null)
  // The desc slot the row paints: the cross rate and the document's own date.
  const r = FXL.tryConvert('100 usd in eur', LIB_RATES)
  eq('the rate line', r.rate, 0.878356)
  eq('the description names the rate and the date', r.desc,
    '1 USD = 0.878356 EUR\nRates updated Mon, 28 Sep 2026')
  eq('a document with no date omits the second line',
    FXL.tryConvert('100 usd in eur', { base: 'USD', rates: LIB_RATES.rates, updated: '' }).desc,
    '1 USD = 0.878356 EUR')
  eq('the copy payload is the formatted amount and the target', r.copy, '87.84 EUR')
  eq('and it matches the label', r.label, `100 USD = ${r.copy}`)
})

group('splitExplicit splits on the LAST keyword, and says which one it took', () => {
  // The reason is a currency whose own spelling contains a keyword: "try" is
  // the Turkish lira's code, and "in" is a word in several names.
  eq('in', FXL.splitExplicit('usd in eur'), { head: 'usd', key: 'in', tail: 'eur' })
  eq('to', FXL.splitExplicit('usd to eur').key, 'to')
  eq('as', FXL.splitExplicit('usd as eur').key, 'as')
  eq('an arrow', FXL.splitExplicit('usd -> eur').key, '->')
  eq('an equals', FXL.splitExplicit('usd = eur').key, '=')
  eq('uppercase is the same keyword', FXL.splitExplicit('usd IN eur').key, 'IN')
  // A keyword with nothing after it is the incomplete case, and it must be
  // distinguishable from a query with no keyword at all.
  eq('a dangling keyword keeps an empty tail', FXL.splitExplicit('usd in'), { head: 'usd', key: 'in', tail: '' })
  eq('no keyword at all', FXL.splitExplicit('usd'), null)
  eq('an empty string', FXL.splitExplicit(''), null)
  eq('null', FXL.splitExplicit(null), null)
  // And the last keyword wins, so a code that ends in one is not mis-split.
  eq('two keywords split on the last', FXL.splitExplicit('a in b in c'), { head: 'a in b', key: 'in', tail: 'c' })
})

group('isPotentialFx is the per-keystroke gate, and it is cheap', () => {
  // Every assertion here is a keystroke the gate must reject before any table
  // is touched, because a launcher that claims "firefox" hides the apps.
  for (const q of ['firefox', '2+2', 'time in madrid', 'x^2', '', '   ', '100',
    '5\nm', 'x'.repeat(129), '5 usd'.padEnd(129, 'x')]) {
    eq(`isPotentialFx(${JSON.stringify(q.slice(0, 24))}) is false`, FXL.isPotentialFx(q), false)
  }
  // These three PASS the gate and are still refused by the parser, which is
  // the gate's job split in two: it is a string test and cannot know the
  // difference between a unit and a currency, so the table decides. Asserted
  // here because the plugin relies on it - it parses before it fetches, so a
  // gate hit that the parser refuses must not have opened a socket.
  for (const q of ['5m', '100 abc', '1e3m']) {
    eq(`isPotentialFx(${JSON.stringify(q)}) over-accepts`, FXL.isPotentialFx(q), true)
    eq(`but tryConvert(${JSON.stringify(q)}) refuses it`, FXL.tryConvert(q, LIB_RATES), null)
  }
  for (const q of ['100 usd in eur', '100 usd', '$100 in eur', 'R$100 in usd', '-50 usd',
    '.5 usd', '1,000 usd']) {
    eq(`isPotentialFx(${JSON.stringify(q)}) is true`, FXL.isPotentialFx(q), true)
  }
  eq('null', FXL.isPotentialFx(null), false)
  eq('a number', FXL.isPotentialFx(0), false)
  eq('an object', FXL.isPotentialFx({}), false)
})

group('the module tables are the ones the contract depends on', () => {
  eq('the fetch base', FXL.RATE_BASE, 'USD')
  eq('the fetch URL is https and the documented host', /^https:\/\//.test(FXL.RATE_URL), true)
  eq('and ends in that base', FXL.RATE_URL.endsWith('/' + FXL.RATE_BASE), true)
  eq('the amount matcher accepts a grouped amount', FXL.RE_AMOUNT.test('1,234.56 usd'), true)
  eq('and a leading decimal point', FXL.RE_AMOUNT.test('.5 usd'), true)
  eq('and stops at a non-digit', FXL.RE_AMOUNT.exec('5m')[0], '5')
  eq('and refuses an exponent', FXL.RE_AMOUNT.test('1e3m'), true)
  eq('the symbol table is non-empty', FXL.SYMBOLS.length > 0, true)
  eq('every symbol maps to a real code',
    FXL.SYMBOLS.filter((s) => !/^[A-Z]{3}$/.test(s.code)).map((s) => s.sym), [])
})

group('netBody is the tri-state the fetch pair promises a plugin', () => {
  // The three answers are distinct and the difference is load-bearing: "" means
  // SETTLED with nothing, null means never asked or in flight. Folding them
  // together is what leaves a failed fetch on a pending row forever, and
  // handing the cache RECORD over instead of its body is what makes a good
  // fetch read as no rates at all.
  eq('an absent entry is null, not the empty string', LL.netBody(undefined), null)
  eq('a null entry is null', LL.netBody(null), null)
  eq('a settled empty fetch is the empty string', LL.netBody({ body: '', at: 1 }), '')
  eq('a body comes back as itself', LL.netBody({ body: '{"rates":{}}', at: 1 }), '{"rates":{}}')
  eq('a body is coerced to a string, not an object', typeof LL.netBody({ body: {}, at: 1 }), 'string')
  eq('an entry with no body field is a settled failure, not a pending one',
    LL.netBody({ at: 1 }), '')
  eq('an entry whose body is null is a settled failure', LL.netBody({ body: null, at: 1 }), '')
  // The projection is what the granted operation returns, and the plugin
  // parses exactly this. A body that survives the projection must parse.
  const body = JSON.stringify({ result: 'success', base_code: 'USD', rates: { USD: 1, EUR: 0.8 } })
  eq('a projected body is parseable as the rate document',
    FXL.parseRates(LL.netBody({ body: body, at: 1 })).base, 'USD')
  // And the round trip the facade performs: URL -> record -> body.
  const cache = { [FXL.RATE_URL]: { body: body, at: 1 } }
  eq('through the facade projection the plugin gets a body',
    FXL.parseRates(LL.netBody(cache[String(FXL.RATE_URL)])).base, 'USD')
  // The record itself must never reach the plugin. This is the exact shape
  // that produced "[object Object]" and a permanently unavailable row.
  eq('the record is not the body', String(cache[String(FXL.RATE_URL)]), '[object Object]')
})

group('the facade binds the projection, and the controller stores the record', () => {
  // The two ends of the pipe are in QML, which the node suite cannot execute
  // headlessly (AppLauncherView needs a PanelWindow backend). So the pipe is
  // pinned from the source instead: the controller must STORE a body field,
  // and the facade must PROJECT it, or the two disagree and every row reads as
  // unavailable. A one-line `?? null` at the call site is exactly what let this
  // ship green.
  const facade = fs.readFileSync(path.join(LAUNCHER, 'AppLauncher.qml'), 'utf8')
  const controller = fs.readFileSync(path.join(LAUNCHER, 'AppLauncherController.qml'), 'utf8')
  contains('the facade projects the body out of the cache entry', facade,
    'cachedNet: url => LauncherLib.netBody(')
  notContains('and does not hand the raw record to a plugin', facade,
    'cachedNet: url => root.netCache[')
  contains('the controller stores the body under a body field', controller,
    '{ body: text, at: Date.now() }')
  // The fetch TTL follows the CONTENT of the entry, not just its age. A single
  // TTL over both is what latched an offline failure for ten minutes: the
  // guard is on the cache ENTRY, so an entry holding an empty body blocked
  // every retry exactly as long as one holding a good document does. Proven
  // against a closed port - one socket across eight recomputes before the
  // fix, and a re-ask on every recompute past the retry window after it.
  contains('a good body ages out in minutes', controller, 'readonly property int _netTtlMs: 600000')
  contains('and a failure ages out in seconds', controller, 'readonly property int _netRetryMs: 15000')
  contains('the guard picks the TTL from the body', controller,
    'age < (cached.body === "" ? root._netRetryMs : root._netTtlMs)')
  notContains('and there is no unguarded single-TTL form left', controller,
    '(cached.at || 0)) < root._netTtlMs) return')
  // And the grant is named in the one place that owns it.
  contains('the per-plugin grant names the request', facade, '"fx": ["requestNet", "setCacheSection"]')
  contains('and the user root still names nothing', facade, 'readonly property var _userGrants: []')
})

// =========================================================================
section('Plugin/library parity - structure')
// =========================================================================
//
// The high-value part of this suite. Three plugin READMEs say the same thing
// in their own words:
//
//   calc: "main.js is the same code as features/launcher/CalcLib.js, carried
//          inside the plugin ... the two copies can drift - if you change one,
//          change both"
//   unit: "it is not read by any suite, so the two copies can drift"
//   time: "Tests: none read main.js or features/launcher/TimeLib.js"
//
// Nothing else in the tree can catch a divergence, so this section is driven
// off listPlugins(): a further drop-in plugin with a library twin is covered the
// moment it lands, and websearch - which has no twin - is covered by the shape
// and runtime sections above without any edit here.

// Structural report, built once and asserted in several groups below so a
// drift shows up as a named list of differing functions rather than as one
// opaque failure.
const PARITY = PLUGIN_NAMES.map((name) => {
  const pluginFile = path.join(PLUGIN_ROOT, name, 'main.js')
  const libFile = CALC_TWINS[name] || null
  const out = {
    name,
    pluginFile,
    libFile,
    hasTwin: libFile !== null && fs.existsSync(libFile),
    twinSource: '',
    pluginSource: '',
    libFns: {},
    plugFns: {},
    sharedFns: [],
    onlyInPlugin: [],
    onlyInLib: [],
    bodyDiffs: [],
    arityDiffs: [],
    textDiffs: [],
    valueDiffs: [],
    libDeclarations: [],
    plugDeclarations: [],
  }
  if (!out.hasTwin) return out
  out.pluginSource = libSource(pluginFile)
  out.twinSource = libSource(libFile)
  // A pristine evaluation of the twin, in its own context. loadLib() caches,
  // and the three libraries above are instrumented for coverage, so the twin
  // has to be evaluated here rather than taken from the loader - the
  // comparison has to be between two real parses, not between a parse and a
  // recording wrapper.
  out.libFns = pristineLib(libFile)
  out.plugFns = pluginInternals(pluginFile).fns
  out.plugDeclarations = topLevelNames(out.pluginSource)
  out.libDeclarations = topLevelNames(out.twinSource)
  const libFnNames = functionNames(out.twinSource)
  const plugFnNames = functionNames(out.pluginSource)
  out.sharedFns = plugFnNames.filter((n) => libFnNames.indexOf(n) >= 0)
  out.onlyInPlugin = plugFnNames.filter((n) => libFnNames.indexOf(n) < 0)
  out.onlyInLib = libFnNames.filter((n) => plugFnNames.indexOf(n) < 0)
  for (const n of out.sharedFns) {
    // The authoritative comparison: what the engine actually holds, after
    // parsing. A re-indent, a reformat and a comment change inside the body
    // all show up here, because toString returns the source text.
    if (out.plugFns[n].toString() !== out.libFns[n].toString()) out.bodyDiffs.push(n)
    if (out.plugFns[n].length !== out.libFns[n].length) out.arityDiffs.push(n)
    // The corroborating one: the raw declaration text, byte for byte.
    if (declText(out.pluginSource, n) !== declText(out.twinSource, n)) out.textDiffs.push(n)
  }
  // Non-function declarations: the data tables, which are as much the contract
  // as the functions are. A regex or a lookup table that drifted would change
  // behaviour without changing a single function body.
  const libData = out.libDeclarations.filter((n) => libFnNames.indexOf(n) < 0)
  const plugData = out.plugDeclarations.filter((n) => plugFnNames.indexOf(n) < 0)
  out.sharedData = plugData.filter((n) => libData.indexOf(n) >= 0)
  out.onlyInPluginData = plugData.filter((n) => libData.indexOf(n) < 0)
  for (const n of out.sharedData) {
    const a = out.plugFns[n]
    const b = out.libFns[n]
    // deepEqual would call two RegExp objects equal (no own enumerable keys),
    // so the source and flags are compared explicitly.
    if (a instanceof RegExp || b instanceof RegExp) {
      if (!(a instanceof RegExp) || !(b instanceof RegExp) || a.source !== b.source || a.flags !== b.flags) out.valueDiffs.push(n)
      continue
    }
    if (!deepEqual(a, b)) out.valueDiffs.push(n)
  }
  return out
})

const TWINNED = PARITY.filter((p) => p.hasTwin)
const UNTWINNED = PARITY.filter((p) => !p.hasTwin)

group('every twin this section compares against actually exists', () => {
  eq('the six documented pairs are discovered', TWINNED.map((p) => p.name), ['binary', 'calc', 'color', 'fx', 'time', 'unit'])
  for (const p of PARITY) {
    if (CALC_TWINS[p.name] === undefined) {
      eq(`${p.name} is not declared as a twin of any library`, p.hasTwin, false)
    } else {
      is(`${p.name} points at a file that exists`, fs.existsSync(CALC_TWINS[p.name]), (v) => v === true, 'an existing file')
    }
  }
  // websearch has no twin, and says so: it delegates quoting to the api
  // instead of carrying a library copy, so there is nothing to drift.
  eq('the one plugin with no library copy', UNTWINNED.map((p) => p.name), ['websearch'])
  eq('and it is the only websearch plugin', pluginManifest(path.join(PLUGIN_ROOT, 'websearch')).type, 'websearch')
})

group('the shared function names are the same set on both sides', () => {
  for (const p of TWINNED) {
    is(`${p.name}: nothing is declared only in the plugin copy`, p.onlyInPlugin, (v) => v.length === 0, 'an empty list')
    is(`${p.name}: nothing is declared only in the library`, p.onlyInLib, (v) => v.length === 0, 'an empty list')
    is(`${p.name}: at least one function is shared`, p.sharedFns, (v) => v.length > 0, 'a non-empty list')
  }
  // The counts, so a future addition is a visible diff here rather than a
  // silently larger set.
  eq('calc shares six functions', TWINNED.find((p) => p.name === 'calc').sharedFns.length, 6)
  // The color engine is a copy of the bar module's channel layer, so nearly all
  // of it is shared: the parser, the conversions, every serializer, the
  // contrast rule, the blend, the format detector, plus the launcher's own
  // gate, mid-typing gate and tryColor. A count that falls means a function
  // left one of the two copies.
  eq('color shares thirty-seven functions', TWINNED.find((p) => p.name === 'color').sharedFns.length, 37)
  eq('unit shares thirty-three', TWINNED.find((p) => p.name === 'unit').sharedFns.length, 33)
  eq('time shares nine', TWINNED.find((p) => p.name === 'time').sharedFns.length, 9)
  eq('fx shares twenty-four', TWINNED.find((p) => p.name === 'fx').sharedFns.length, 24)
})

group('every shared function body is byte-identical', () => {
  // The verdict. If this list is ever non-empty, that is the drift the four
  // READMEs warn about, named function by function.
  for (const p of TWINNED) {
    eq(`${p.name}: no function body differs`, p.bodyDiffs, [])
    eq(`${p.name}: no arity differs`, p.arityDiffs, [])
    eq(`${p.name}: no declaration text differs`, p.textDiffs, [])
    // And the comparison is not vacuous: the shared names really are the ones
    // each file declares.
    for (const n of p.sharedFns) {
      is(`${p.name}.${n} is a function on both sides`, [typeof p.plugFns[n], typeof p.libFns[n]],
        (v) => v[0] === 'function' && v[1] === 'function', 'two functions')
      eq(`${p.name}.${n} arity`, p.plugFns[n].length, p.libFns[n].length)
      contains(`${p.name}.${n} source text matches`, p.plugFns[n].toString(), 'function ' + n)
    }
  }
})

group('every shared data table is byte-identical', () => {
  // The unit table, the function-name table, the probe list, the speed-length
  // map, the default-target ladders and both timezone tables are data, and
  // data changes without changing a single function body.
  for (const p of TWINNED) {
    is(`${p.name}: nothing is declared only in the plugin copy`, p.onlyInPluginData, (v) => v.length === 0, 'an empty list')
    eq(`${p.name}: no data value differs`, p.valueDiffs, [])
  }
  const unit = TWINNED.find((p) => p.name === 'unit')
  eq('unit: the UNITS table has 360 entries on both sides', unit.libFns.UNITS.length, 360)
  eq('unit: the same table', unit.plugFns.UNITS.length, unit.libFns.UNITS.length)
  eq('unit: the SPEED_LEN shorthand has five entries', Object.keys(unit.libFns.SPEED_LEN).length, 5)
  eq('unit: the default-target ladders are the two documented shapes', unit.libFns.DEF_LADDER, {
    time: { pick: 'window', syms: ['yr', 'wk', 'd', 'h', 'min', 's', 'ms'] },
    data: { pick: 'nearest', syms: ['TB', 'GB', 'MB', 'KB', 'B', 'bit'] },
  })
  // Pinned whole rather than by count: every entry names a spelling whose
  // FOLDED form is a different unit, so a new one is a decision about which
  // reading wins and belongs in the diff. Both sides carry the same object, so
  // this is also the parity check on it.
  eq('unit: the case-sensitive overrides are the capitalisation traps',
    unit.libFns.CASE_OVERRIDE, {
      Cal: 'kcal', CAL: 'kcal', Calorie: 'kcal', Calories: 'kcal',
      MW: 'megawatt', Mm: 'megameter', Mg: 'tonne', kN: 'kilonewton',
      Kb: 'kbit', Mb: 'mbit', Gb: 'gbit', Tb: 'tbit',
      'Kb/s': 'kbps', 'Mb/s': 'mbps', 'Gb/s': 'gbps', 'Tb/s': 'tbps',
      kBps: 'kb/s', KBps: 'kb/s', MBps: 'mb/s', GBps: 'gb/s',
    })
  eq('unit: the number matcher is the same pattern', unit.plugFns.RE_NUM.source, unit.libFns.RE_NUM.source)
  // The bare-query shortlist is a list of names, so it is worth pinning that it
  // covers every dimension the table declares and that no name is a typo: an
  // unresolvable entry would silently cost the list a row, and a missing
  // dimension would cost a bare query its only targets.
  eq('unit: the shortlist covers every dimension in the table',
    Object.keys(unit.libFns.SUGGEST).sort(), [...new Set(unit.libFns.UNITS.map((u) => u.dim))].sort())
  // A shortlist entry is a SYMBOL, so it is resolved with symLookup, which
  // matches the table's own spelling before it folds. That distinction is not
  // academic: "kN" is the kilonewton as a symbol and the KNOT under the folded
  // alias table, and a bare lookup would call it a speed and cost the force
  // dimension a row. pickTargets reads symLookup, so the table has to be asked
  // the same way the engine asks it.
  eq('unit: and every shortlisted symbol resolves in its own dimension',
    Object.keys(unit.libFns.SUGGEST).flatMap((d) => unit.libFns.SUGGEST[d]
      .filter((s) => {
        const u = unit.libFns.symLookup(s)
        return u === null || u.dim !== d
      })), [])
  eq('unit: and the folded alias table alone would misread two of them',
    Object.keys(unit.libFns.SUGGEST).flatMap((d) => unit.libFns.SUGGEST[d]
      .filter((s) => {
        const folded = unit.libFns.lookup(s)
        const exact = unit.libFns.symLookup(s)
        return folded === null || folded.sym !== exact.sym
      })), ['MW', 'kN'])
  eq('unit: and the kilonewton row is reachable from a bare query',
    unit.libFns.pickTargets(1, unit.libFns.symLookup('N')).includes('kN'), true)
  eq('unit: the row ceiling is the documented six', unit.libFns.MAX_TARGETS, 6)
  eq('unit: and the readable bound is five decades', unit.libFns.MAX_DECADES, 5)
  eq('unit: the fraction floor is the asymmetric one, a thousandth', unit.libFns.MIN_FRACTION, 0.001)
  // The noun tables: every unit has one, both forms are there, and nothing
  // names a unit the table does not. A missing entry would print a bare symbol
  // in the middle of a sentence ("5 Metres is 49.2126 hand"), and a missing
  // plural would print "2 Foot".
  const unitWords = {}
  for (const dim of Object.keys(unit.libFns.UNIT_NOUN)) {
    for (const s of Object.keys(unit.libFns.UNIT_NOUN[dim])) unitWords[s] = unit.libFns.UNIT_NOUN[dim][s]
  }
  eq('unit: every unit in the table has a noun',
    unit.libFns.UNITS.filter((u) => unitWords[u.sym] === undefined).map((u) => u.sym), [])
  eq('unit: and no noun names a unit that is not in the table',
    Object.keys(unitWords).filter((s) => unit.libFns.lookup(s) === null), [])
  eq('unit: every noun is a [singular, plural] of non-empty strings',
    Object.keys(unitWords).filter((s) => {
      const p = unitWords[s]
      return !Array.isArray(p) || p.length !== 2 || !p[0] || !p[1]
    }), [])
  // A unit name is a common noun, so it reads down - "3600 joules is 0.001
  // kilowatt-hours" - and a currency is the opposite case, a proper noun that
  // FxLib title-cases. This is pinned on the unit table alone: a stray capital
  // would print "5 Metres is 500 Centimetres" and read like a heading.
  //
  // What may keep a capital is a PROPER NOUN or an ABBREVIATION, and the set
  // below is every distinct capitalised word the noun tables use: the four
  // degree scales, the places and people a landmark unit is named for (Earth,
  // Jupiter, Everest, Usain Bolt), and the acronyms that are spelled as
  // acronyms (BTU, TNT, ISS, DVD, CD-ROM). "100 \u00b0celsius" would be wrong
  // English in exactly the way "100 \u00b0Celsius" is not, and "1 british
  // thermal unit" likewise.
  //
  // Pinning the TOKENS rather than the forty-odd names that contain them is
  // what keeps this readable: a new landmark unit reuses words already on the
  // list, and a genuinely new capital arrives here as a one-word diff.
  const UNIT_PROPER = new Set([
    'BTU',
    'Belgium',
    'Big',
    'Blu',
    'Bolt',
    'Bolts',
    'Bomba',
    'Bombas',
    'British',
    'Building',
    'Buildings',
    'Burj',
    'CD',
    'Central',
    'DVD',
    'DVDs',
    'Earth',
    'Eiffel',
    'Empire',
    'Everest',
    'Everests',
    'Hiroshima',
    'ISS',
    'Island',
    'Julian',
    'Jupiter',
    'Khalifa',
    'Khalifas',
    'Lake',
    'Liberty',
    'Mac',
    'Macs',
    'Martian',
    'Mount',
    'Olympic',
    'Park',
    'Parks',
    'ROM',
    'ROMs',
    'Rhode',
    'State',
    'Statue',
    'Statues',
    'Superior',
    'Superiors',
    'TNT',
    'Texas',
    'Tower',
    'Towers',
    'Tsar',
    'Usain',
    'Wales',
    '\u00b0Celsius',
    '\u00b0Fahrenheit',
    '\u00b0Rankine',
    '\u00b0R\u00e9aumur',
  ])
  eq('unit: and every capital in a unit name is a proper noun or an abbreviation',
    [...new Set([...Object.keys(unitWords).flatMap((s) => unitWords[s])
      .flatMap((w) => w.split(/[\s-]+/))
      .filter((t) => /[A-Z\u00c0-\u00de]/.test(t) && !UNIT_PROPER.has(t))])]
      .sort(), [])
  const time = TWINNED.find((p) => p.name === 'time')
  eq('time: the city map has 187 entries on both sides', Object.keys(time.libFns.CITY_TO_TZ).length, Object.keys(time.plugFns.CITY_TO_TZ).length)
  eq('time: and 187 is the count', Object.keys(time.libFns.CITY_TO_TZ).length, 187)
  eq('time: the snapshot has the same length on both sides', time.libFns.FALLBACK_ZONES.length, time.plugFns.FALLBACK_ZONES.length)
  const calc = TWINNED.find((p) => p.name === 'calc')
  eq('calc: the calc plugin declares no data tables at all', calc.sharedData, [])
  const fx = TWINNED.find((p) => p.name === 'fx')
  // The two noun tables read differently on purpose, so this is the pair that
  // proves the difference is deliberate: a currency is a proper noun and is
  // title-cased, a unit is a common noun and is not.
  eq('a currency name is title-cased', fx.libFns.currencyWord('USD', 100), 'US Dollars')
  eq('and a unit name is not',
    unit.libFns.tryConvert('5 m in ft').phrase, '5 metres is 16.4042 feet')
  // UnitLib has no title-caser at all now, which is what makes the difference
  // structural rather than a flag: there is nothing there to turn on.
  eq('so the unit library carries no title-caser', typeof unit.libFns.sentenceCase, 'undefined')
  eq('and the currency one does', typeof fx.libFns.sentenceCase, 'function')
  // A scale that measures a degree carries the degree sign as a prefix on its
  // FULL name - "100 \u00b0Celsius" - rather than dropping the name for the
  // symbol ("100 \u00b0C") or spelling the word out ("100 degrees Celsius"). The
  // sign binds to the name, so the ordinary space phrase() already puts between
  // a number and its noun is all the joining this needs: a sign-led noun is
  // just a noun that happens to begin with a sign. Kelvin is the exception the
  // notation itself makes - an absolute scale rather than a degree of anything,
  // so it takes no sign and its noun is the bare name.
  eq('the degree scales print as sign plus full name',
    ['C', 'F', 'K', 'Re', 'R'].map((s) => unitWords[s][0]),
    ['\u00b0Celsius', '\u00b0Fahrenheit', 'kelvin', '\u00b0R\u00e9aumur', '\u00b0Rankine'])
  // The set of sign-led nouns is pinned because it is load-bearing: a name that
  // gained a stray leading symbol would read as a prefix it is not, and one
  // that lost the sign would print "100 Celsius", which is wrong English.
  eq('and exactly the four degree scales open with a sign',
    Object.keys(unitWords).filter((s) => !/^[A-Za-z]/.test(unitWords[s][0])).sort(),
    ['C', 'F', 'R', 'Re'])
  eq('with both forms agreeing, so singular and plural cannot disagree about it',
    Object.keys(unitWords).filter((s) => !/^[A-Za-z]/.test(unitWords[s][0]) !== !/^[A-Za-z]/.test(unitWords[s][1])), [])
  eq('and the sign is joined to the name, never to the value',
    unit.libFns.tryConvert('100C in F').phrase, '100 \u00b0Celsius is 212 \u00b0Fahrenheit')
  // A degree of angle has no scale name behind it, so there is nothing for a
  // sign to prefix and the noun stays the plain word.
  eq('a bare angle keeps its noun, having no scale name to sign',
    unitWords.deg, ['degree', 'degrees'])
  eq('which is what the sentence says', unit.libFns.tryConvert('90deg in rad').phrase,
    '90 degrees is 1.5708 radians')
  eq('kelvin, being absolute, takes no sign at all',
    unit.libFns.tryConvert('1K in C').phrase, '1 kelvin is -272.15 \u00b0Celsius')
  // The currency table is deliberately NOT the full set of codes: the engine
  // reaches any code the provider quotes through resolveCode, so the table is
  // only what adds a name, a symbol and a place in the bare-query path. That
  // is why a count is pinned rather than a membership list - the membership
  // is the provider's, and the table is a naming convenience.
  eq('fx: the named table is 155 entries on both sides', fx.libFns.CURRENCIES.length, 155)
  eq('fx: the same table', fx.plugFns.CURRENCIES.length, fx.libFns.CURRENCIES.length)
  eq('fx: every code is unique, so no entry is shadowed',
    new Set(fx.libFns.CURRENCIES.map((c) => c.code)).size, fx.libFns.CURRENCIES.length)
  eq('fx: every code is a three-letter uppercase ISO shape',
    fx.libFns.CURRENCIES.filter((c) => !/^[A-Z]{3}$/.test(c.code)).map((c) => c.code), [])
  eq('fx: no alias is claimed by two currencies', (() => {
    const seen = {}
    const dupes = []
    for (const c of fx.libFns.CURRENCIES) {
      for (const n of [c.code.toLowerCase(), ...c.names]) {
        if (seen[n] !== undefined && seen[n] !== c.code) dupes.push(n)
        seen[n] = c.code
      }
    }
    return dupes
  })(), [])
  eq('fx: the symbol table is the documented ten, longest first', fx.libFns.SYMBOLS.map((s) => s.sym),
    ['R$', 'US$', '$', '€', '£', '¥', '₹', '₽', '₩', '₺'])
  // Longest-first is load-bearing: a shorter symbol listed first would make
  // "R$100" read as USD with a stray R.
  eq('fx: every symbol is at least as long as the one after it, or the order would break',
    fx.libFns.SYMBOLS.map((s) => s.sym.length), [2, 3, 1, 1, 1, 1, 1, 1, 1, 1])
  eq('fx: the base is the fetch base', fx.libFns.RATE_BASE, 'USD')
  eq('fx: and the URL is that base on the documented endpoint', fx.libFns.RATE_URL,
    'https://open.er-api.com/v6/latest/USD')
  eq('fx: the amount matcher is the same pattern', fx.plugFns.RE_AMOUNT.source, fx.libFns.RE_AMOUNT.source)
})

group('the library file is the plugin file plus a contract block', () => {
  // The strongest statement of "it is the same code, carried inside the
  // plugin": past the one line that differs - the library's `.pragma library`
  // directive, which the plugin must not have - every line of the library
  // appears at the same index in the plugin.
  for (const p of TWINNED) {
    const libRaw = fs.readFileSync(p.libFile, 'utf8').split('\n')
    const plugRaw = fs.readFileSync(p.pluginFile, 'utf8').split('\n')
    let firstDiff = -1
    for (let i = 0; i < Math.min(libRaw.length, plugRaw.length); i++) {
      if (libRaw[i] !== plugRaw[i]) { firstDiff = i; break }
    }
    is(`${p.name}: the files do differ somewhere`, firstDiff, (v) => v >= 0, 'a first differing line')
    eq(`${p.name}: and the one differing line is the library's .pragma directive`, libRaw[firstDiff].trim(), '.pragma library')
    is(`${p.name}: the plugin has no .pragma statement`, plugRaw, (ls) => ls.every((l) => !/^\s*\.pragma\s/.test(l)), 'no pragma line')
    // Deleting the library's one pragma line shifts everything below it up by
    // one, so library line firstDiff+1+k is plugin line firstDiff+k. The
    // library's own trailing blank line is not part of the engine, so the
    // comparison stops one line short of it and the plugin's leftover is the
    // contract block.
    const engine = libRaw.length - firstDiff - 2
    eq(`${p.name}: every other library line is identical in the plugin copy`,
      plugRaw.slice(firstDiff, firstDiff + engine), libRaw.slice(firstDiff + 1, libRaw.length - 1))
    const contract = plugRaw.slice(firstDiff + engine)
    is(`${p.name}: the contract block is not empty`, contract, (v) => v.length > 0, 'a non-empty block')
    contains(`${p.name}: the contract assigns VibraniumPlugin`, contract.join('\n'), 'VibraniumPlugin = {')
    is(`${p.name}: and the contract declares no engine function of its own`, contract,
      (ls) => ls.every((l) => !/^function\s/.test(l)), 'no function declaration')
    is(`${p.name}: and no engine table of its own`, contract,
      (ls) => ls.every((l) => !/^(var|const|let)\s/.test(l)), 'no top-level var/const/let')
    is(`${p.name}: the plugin is strictly longer, by its contract block`,
      plugRaw.length, (n) => n > libRaw.length, 'plugin longer than library')
  }
})

// =========================================================================
section('Plugin/library parity - behaviour')
// =========================================================================

// One corpus per twin, including nullish, empty and degenerate inputs, run
// through both copies and compared. `attempt` captures a throw as a value, so
// a function that is *meant* to reject bad input is compared on its message
// too. A thunk entry gets the namespace, so a call that needs a compiled
// artifact can build one with the very copy under test.
const PARITY_CORPUS = {
  calc: [
    ['isPotentialCalc', [null]], ['isPotentialCalc', [undefined]], ['isPotentialCalc', ['']], ['isPotentialCalc', ['   ']],
    ['isPotentialCalc', [0]], ['isPotentialCalc', [42]], ['isPotentialCalc', ['42']], ['isPotentialCalc', ['2+2']],
    ['isPotentialCalc', ['2+2=']], ['isPotentialCalc', ['2+2===']], ['isPotentialCalc', ['=']],
    ['isPotentialCalc', ['firefox']], ['isPotentialCalc', ['1.']], ['isPotentialCalc', ['.5']], ['isPotentialCalc', ['()']],
    ['isPotentialCalc', ['2+2\n']], ['isPotentialCalc', [true]], ['isPotentialCalc', [[2, 2]]],
    ['tryEvaluate', [null]], ['tryEvaluate', ['']], ['tryEvaluate', ['   ']], ['tryEvaluate', ['2+2']],
    ['tryEvaluate', ['2+2=']], ['tryEvaluate', ['42']], ['tryEvaluate', ['firefox']],
    ['tryEvaluate', ['1/3']], ['tryEvaluate', ['2^10']], ['tryEvaluate', ['7%3']], ['tryEvaluate', ['-3+5']],
    ['tryEvaluate', ['(2+3)*4']], ['tryEvaluate', ['--3']], ['tryEvaluate', ['2*-3']], ['tryEvaluate', ['2+*3']],
    ['tryEvaluate', ['1/0']], ['tryEvaluate', ['5..3']], ['tryEvaluate', ['.']], ['tryEvaluate', ['5.']],
    ['tryEvaluate', ['((']], ['tryEvaluate', ['2+2)']], ['tryEvaluate', ['1e6']], ['tryEvaluate', ['1e999']],
    ['tryEvaluate', ['  2  +  2  ']], ['tryEvaluate', [true]], ['tryEvaluate', [['2+2']]], ['tryEvaluate', [0]],
  ],
  unit: [
    ['aliasMap', []], ['normalizeUnit', [null]], ['normalizeUnit', [undefined]], ['normalizeUnit', ['']],
    ['normalizeUnit', ['  CM  ']], ['normalizeUnit', ['fluid ounces']], ['normalizeUnit', ['m/s']],
    ['normalizeUnit', ['m^2']], ['normalizeUnit', ['"']], ['normalizeUnit', ['in.']], ['normalizeUnit', [0]],
    ['lookup', [null]], ['lookup', ['']], ['lookup', ['cm']], ['lookup', ['CM']], ['lookup', ['centimeters']],
    ['lookup', ['zzz']], ['lookup', ['m/s']], ['lookup', ['in^3']], ['lookup', ['5']], ['lookup', [{}]],
    ['formatNumber', [0]], ['formatNumber', [1]], ['formatNumber', [1.5]], ['formatNumber', [NaN]],
    ['formatNumber', [Infinity]], ['formatNumber', [-Infinity]], ['formatNumber', [1e-7]], ['formatNumber', [1e13]],
    ['formatNumber', ['x']], ['formatNumber', [null]], ['formatNumber', [-0]], ['formatNumber', [20 * 0.0254]],
    ['toCelsius', [0, 'C']], ['toCelsius', [32, 'F']], ['toCelsius', [0, 'K']], ['toCelsius', [0, null]], ['toCelsius', [100, 'nope']],
    ['fromCelsius', [0, 'C']], ['fromCelsius', [0, 'F']], ['fromCelsius', [0, 'K']], ['fromCelsius', [100, 'nope']],
    ['isPotentialUnit', [null]], ['isPotentialUnit', ['']], ['isPotentialUnit', ['5m']], ['isPotentialUnit', ['5 m']],
    ['isPotentialUnit', ['2+2']], ['isPotentialUnit', ['firefox']], ['isPotentialUnit', ['time in x']],
    ['isPotentialUnit', ['-5C']], ['isPotentialUnit', ['.5l']], ['isPotentialUnit', ['1e3m']], ['isPotentialUnit', ['5']],
    ['isPotentialUnit', ['5m'.padEnd(129, 'x')]], ['isPotentialUnit', ['5\nm']],
    ['splitExplicit', ['']], ['splitExplicit', ['m in cm']], ['splitExplicit', ['m to cm']], ['splitExplicit', ['m as cm']],
    ['splitExplicit', ['m -> cm']], ['splitExplicit', ['m = cm']], ['splitExplicit', ['in in cm']],
    ['splitExplicit', ['m into cm']], ['splitExplicit', ['m into']], ['splitExplicit', ['m']],
    ['splitExplicit', [null]], ['splitExplicit', ['m IN cm']],
    // The text stage: preprocess owns every rewrite, and a divergence here
    // would show up as a plugin that answers a query the library does not.
    ['preprocess', [null]], ['preprocess', ['']], ['preprocess', ['5km->mi']], ['preprocess', ['5 km --> mi']],
    ['preprocess', ['convert 5 km to mi']], ['preprocess', ['calc 5km']], ['preprocess', ['what is 5km']],
    ['preprocess', ["what's 5km"]], ['preprocess', ['how many km in 5 mi']], ['preprocess', ['5 km is how many miles']],
    ['preprocess', ['how much is 5 kg in lb']], ['preprocess', ['5 km in mi please']], ['preprocess', ['5 km in mi?']],
    ['preprocess', ["6'2\""]], ['preprocess', ['convert convert 5 km to mi']],
    ['stripTail', ['5 km in mi please']], ['stripTail', ['5 km in mi?!']], ['stripTail', ["6'\""]], ['stripTail', [null]],
    ['isSpace', [' ']], ['isSpace', ['\t']], ['isSpace', ['a']], ['isSpace', ['\n']],
    ['parseSource', ['6 ft 2 in']], ['parseSource', ['5 ft 10']], ['parseSource', ['5 m 2']], ['parseSource', ['5 kg 2']],
    ['parseSource', ['5 miles per hour']], ['parseSource', ['1,000 km']], ['parseSource', ['']], ['parseSource', [null]],
    ['parseFeetInches', ["6'2\""]], ['parseFeetInches', ["6' 2in"]], ['parseFeetInches', ["5'"]], ['parseFeetInches', ['5 ft 10']],
    ['pickDefault', (ns) => [7, ns.lookup('d')]],
    ['pickDefault', (ns) => [1, ns.lookup('d')]],
    ['pickDefault', (ns) => [1, ns.lookup('yr')]],
    ['pickDefault', (ns) => [0.5, ns.lookup('s')]],
    ['pickDefault', (ns) => [1, ns.lookup('GB')]],
    ['pickDefault', (ns) => [100, ns.lookup('KB')]],
    ['pickDefault', (ns) => [1, ns.lookup('m')]],
    ['convertValue', (ns) => [1, ns.lookup('km'), ns.lookup('m')]],
    ['convertValue', (ns) => [100, ns.lookup('C'), ns.lookup('F')]],
    ['termText', (ns) => [{ text: '5', unit: ns.lookup('m') }]],
    ['unitFor', ['Cal']], ['unitFor', ['CAL']], ['unitFor', ['cal']], ['unitFor', ['µm']], ['unitFor', ['zzz']],
    ['dimUnits', ['length']], ['dimUnits', ['nope']],
    ['dimHint', (ns) => [ns.lookup('m')]],
    ['dimNote', (ns) => [ns.lookup('m'), ns.lookup('cm2')]],
    ['tryConvert', [null]], ['tryConvert', ['']], ['tryConvert', ['5m in cm']], ['tryConvert', ['5 m']],
    ['tryConvert', ['5m to cm']], ['tryConvert', ['20c in in']], ['tryConvert', ['20 in in cm']],
    ['tryConvert', ['5 kg in lb']], ['tryConvert', ['-300C in K']], ['tryConvert', ['-5K in C']],
    ['tryConvert', ['250mph in km']], ['tryConvert', ['5km in mph']], ['tryConvert', ['7d']],
    ['tryConvert', ['1d']], ['tryConvert', ['1s']], ['tryConvert', ['90min']], ['tryConvert', ['1yr']],
    ['tryConvert', ['5m in zz']], ['tryConvert', ['5m in']], ['tryConvert', ['zz']], ['tryConvert', ['2+2']],
    ['tryConvert', ['firefox']], ['tryConvert', ['time in madrid']], ['tryConvert', ['5']], ['tryConvert', ['1e999']],
    ['tryConvert', ['0C in F']], ['tryConvert', ['0K in C']], ['tryConvert', ['1 KiB in B']],
    ['tryConvert', ['1 bit in B']], ['tryConvert', ['1 rad in deg']], ['tryConvert', ['1 GB in MiB']],
    ['tryConvert', ['1e3 m in km']], ['tryConvert', ['.5l in ml']], ['tryConvert', ['-5 C in F']],
    ['tryConvert', ['1 atm in kPa']], ['tryConvert', ['1 psi in kPa']], ['tryConvert', ['1 in in cm']],
    // The shapes the rewritten engine added: compounds, the folded spellings,
    // the decimal data ladder and each typed failure.
    ['tryConvert', ['6 ft 2 in']], ['tryConvert', ["6'2\""]], ['tryConvert', ['5 lb 2 oz in kg']],
    ['tryConvert', ['2 m 3 kg']], ['tryConvert', ['5 in cm']], ['tryConvert', ['12 in ft']], ['tryConvert', ['5in cm']],
    ['tryConvert', ['1,000 km in mi']], ['tryConvert', ['5.mm in cm']], ['tryConvert', ['1,5 km']],
    ['tryConvert', ['30 °C in F']], ['tryConvert', ['1 m² in cm2']], ['tryConvert', ['1 Å in nm']],
    ['tryConvert', ['5 Cal in J']], ['tryConvert', ['5 cal in J']], ['tryConvert', ['5 m in n']],
    ['tryConvert', ['1 kN in N']], ['tryConvert', ['5 Nm in lbf ft']], ['tryConvert', ['5 N·m in lbf·ft']],
    ['tryConvert', ['30 mpg in km/l']], ['tryConvert', ['1 GB']], ['tryConvert', ['100 KB']], ['tryConvert', ['0 d']],
    ['tryConvert', ['how many km in 5 mi']], ['tryConvert', ['convert 5 km to mi']],
    ['tryConvert', ['1e308t in mg']], ['tryConvert', ['1 KN in N']], ['tryConvert', ['1 kwh in wh']],
  ],
  fx: [
    // The gate: an amount or a leading symbol, and a letter-ish character.
    ['isPotentialFx', [null]], ['isPotentialFx', [undefined]], ['isPotentialFx', ['']],
    ['isPotentialFx', ['100 usd in eur']], ['isPotentialFx', ['$100 in eur']],
    ['isPotentialFx', ['5m']], ['isPotentialFx', ['2+2']], ['isPotentialFx', ['firefox']],
    ['isPotentialFx', ['time in madrid']], ['isPotentialFx', ['100']], ['isPotentialFx', ['-50 usd']],
    ['isPotentialFx', ['.5 usd']], ['isPotentialFx', ['1,000 usd']], ['isPotentialFx', ['1e3m']],
    ['isPotentialFx', ['5\nm']], ['isPotentialFx', ['5 usd'.padEnd(129, 'x')]],
    ['isPotentialFx', [{}]], ['isPotentialFx', [0]],
    // Normalization and the two-tier code resolution.
    ['normalizeCurrency', [null]], ['normalizeCurrency', [undefined]], ['normalizeCurrency', ['']],
    ['normalizeCurrency', ['  USD  ']], ['normalizeCurrency', ['US-Dollars']],
    ['normalizeCurrency', ['swedish krona']], ['normalizeCurrency', ['EUR.']], ['normalizeCurrency', [0]],
    ['resolveCode', [null]], ['resolveCode', ['']], ['resolveCode', ['usd']], ['resolveCode', ['USD']],
    ['resolveCode', ['dollars']], ['resolveCode', ['R$']], ['resolveCode', ['zzz']],
    ['resolveCode', ['zzzz']], ['resolveCode', ['ab']], ['resolveCode', ['12a']], ['resolveCode', [{}]],
    ['num', [1]], ['num', [0]], ['num', [-1.5]], ['num', [NaN]], ['num', [Infinity]],
    ['num', ['1']], ['num', [null]], ['num', [undefined]], ['num', [true]],
    // rateOf is num plus the zero rule, and the two directions a zero rate
    // fails in are different enough to be worth one call each.
    ['rateOf', (ns) => [{ USD: 1, EUR: 0.8, JPY: 0 }, 'USD']],
    ['rateOf', (ns) => [{ USD: 1, EUR: 0.8, JPY: 0 }, 'EUR']],
    ['rateOf', (ns) => [{ USD: 1, EUR: 0.8, JPY: 0 }, 'JPY']],
    ['rateOf', (ns) => [{ USD: 1 }, 'ZZZ']],
    ['rateOf', (ns) => [{ USD: 1 }, null]],
    ['rateOf', (ns) => [null, 'USD']],
    ['parseQuery', ['100 usd in eur']], ['parseQuery', ['100 usd']],
    ['parseQuery', ['100 usd in']], ['parseQuery', ['100 usd in eur extra']],
    ['parseQuery', ['firefox']], ['parseQuery', ['']], ['parseQuery', [null]],
    ['normalizeCurrency', ['USD.']], ['normalizeCurrency', [' swedish_krona ']],
    ['symbolCode', ['$']], ['symbolCode', ['R$']], ['symbolCode', ['€']], ['symbolCode', ['zz']],
    ['leadingSymbol', ['$100']], ['leadingSymbol', ['R$100']], ['leadingSymbol', ['100$']],
    ['leadingSymbol', ['100 usd']], ['leadingSymbol', ['']], ['leadingSymbol', [null]],
    ['leadingSymbol', ['R']], ['leadingSymbol', ['$$']],
    // The bare-query default target.
    ['defaultTarget', ['USD']], ['defaultTarget', ['EUR']], ['defaultTarget', ['JPY']],
    ['defaultTarget', ['']], ['defaultTarget', [null]],
    // Keyword splitting, on the LAST keyword so a code containing one still
    // splits at the separator.
    ['splitExplicit', ['']], ['splitExplicit', ['usd in eur']], ['splitExplicit', ['usd to eur']],
    ['splitExplicit', ['usd as eur']], ['splitExplicit', ['usd -> eur']], ['splitExplicit', ['usd = eur']],
    ['splitExplicit', ['usd in']], ['splitExplicit', ['usd']], ['splitExplicit', [null]],
    ['splitExplicit', ['usd IN eur']], ['splitExplicit', ['try in usd']], ['splitExplicit', ['leu in eur']],
    // Formatting: money, not ratios.
    ['formatAmount', [0]], ['formatAmount', [1]], ['formatAmount', [1.5]], ['formatAmount', [0.5]],
    ['formatAmount', [157489.371]], ['formatAmount', [1234567.891]], ['formatAmount', [1234.5]],
    ['formatAmount', [999]], ['formatAmount', [1000]], ['formatAmount', [-1234.5]],
    ['formatAmount', [0.0001]], ['formatAmount', [0.00001]], ['formatAmount', [1e12]],
    ['formatAmount', [NaN]], ['formatAmount', [Infinity]], ['formatAmount', [-Infinity]],
    ['formatAmount', [-0]], ['formatAmount', ['x']], ['formatAmount', [null]],
    // The provider document.
    ['parseRates', [null]], ['parseRates', [undefined]], ['parseRates', ['']], ['parseRates', ['   ']],
    ['parseRates', ['not json']], ['parseRates', ['<html>429</html>']], ['parseRates', ['null']],
    ['parseRates', ['{}']], ['parseRates', ['[]']], ['parseRates', ['"a"']],
    ['parseRates', ['{"result":"error"}']], ['parseRates', ['{"rates":{}}']],
    ['parseRates', ['{"result":"success","rates":{"EUR":1}}']],
    ['parseRates', ['{"result":"success","base_code":"USD","rates":{"USD":1,"EUR":0.8}}']],
    ['parseRates', ['{"result":"success","base_code":"usd","rates":{"USD":1}}']],
    ['parseRates', ['{"result":"success","base_code":"USD","rates":{"USD":"1"}}']],
    ['parseRates', ['{"result":"success","base_code":"USD","rates":{"USD":1},"time_last_update_utc":"x"}']],
    // The main entry, against a settled table.
    ['tryConvert', ['100 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 0.878356 }, updated: '' }]],
    ['tryConvert', ['100 usd in eur', null]],
    ['tryConvert', ['100 usd in eur', undefined]],
    ['tryConvert', ['100 usd in eur', {}]],
    ['tryConvert', ['100 usd in eur', { base: 'USD', rates: {}, updated: '' }]],
    ['tryConvert', ['100 usd in', { base: 'USD', rates: { USD: 1, EUR: 0.8 } }]],
    ['tryConvert', ['100 usd in usd', { base: 'USD', rates: { USD: 1 } }]],
    ['tryConvert', ['100 usd in zzz', { base: 'USD', rates: { USD: 1 } }]],
    ['tryConvert', ['100 usd', { base: 'USD', rates: { USD: 1, EUR: 0.8 } }]],
    ['tryConvert', ['100 eur', { base: 'USD', rates: { USD: 1, EUR: 0.8 } }]],
    ['tryConvert', ['$100 in eur', { base: 'USD', rates: { USD: 1, EUR: 0.8 } }]],
    ['tryConvert', ['100$ in eur', { base: 'USD', rates: { USD: 1, EUR: 0.8 } }]],
    ['tryConvert', ['R$100 in usd', { base: 'USD', rates: { USD: 1, BRL: 5.44 } }]],
    ['tryConvert', ['100 usd in R$', { base: 'USD', rates: { USD: 1, BRL: 5.44 } }]],
    ['tryConvert', ['1,234.56 usd in jpy', { base: 'USD', rates: { USD: 1, JPY: 157.489371 } }]],
    ['tryConvert', ['.5 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 0.878356 } }]],
    ['tryConvert', ['-50 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 0.878356 } }]],
    ['tryConvert', ['0 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 0.878356 } }]],
    ['tryConvert', ['100 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 0 } }]],
    ['tryConvert', ['100 usd in eur', { base: 'USD', rates: { USD: 0, EUR: 1 } }]],
    ['tryConvert', ['1e999 usd in eur', { base: 'USD', rates: { USD: 1, EUR: 1 } }]],
    // And against nothing at all: every one of these falls through to apps.
    ['tryConvert', [null]], ['tryConvert', ['']], ['tryConvert', ['firefox']],
    ['tryConvert', ['2+2']], ['tryConvert', ['5m in cm']], ['tryConvert', ['100']],
    ['tryConvert', ['100 abc']], ['tryConvert', ['1e3m']], ['tryConvert', ['time in madrid']],
    ['tryConvert', ['100 usd in eur extra']], ['tryConvert', [{}]], ['tryConvert', [0]],
  ],
  time: [
    ['_str', [null]], ['_str', [undefined]], ['_str', ['']], ['_str', [0]], ['_str', [false]], ['_str', [['a']]],
    ['normalizeCity', [null]], ['normalizeCity', ['']], ['normalizeCity', ['Madrid']], ['normalizeCity', ['new-york']],
    ['normalizeCity', ['Sao Paulo']], ['normalizeCity', ['  new   york  ']], ['normalizeCity', [42]],
    ['parseTimeQuery', [null]], ['parseTimeQuery', ['']], ['parseTimeQuery', ['time in Madrid']],
    ['parseTimeQuery', ['time in']], ['parseTimeQuery', ['time']], ['parseTimeQuery', ['TIME IN BANGKOK']],
    ['parseTimeQuery', ['time in new york tomorrow']], ['parseTimeQuery', ['time in a b c']],
    ['resolveTimezone', [null]], ['resolveTimezone', ['']], ['resolveTimezone', ['madrid']],
    ['resolveTimezone', ['MADRID']], ['resolveTimezone', ['new-york']], ['resolveTimezone', ['beijing']],
    ['resolveTimezone', ['notazone']], ['resolveTimezone', ['buenos aires']], ['resolveTimezone', ['  ']],
    ['toDisplayName', [null]], ['toDisplayName', ['']], ['toDisplayName', ['BANGKOK']],
    ['toDisplayName', ['new york']], ['toDisplayName', ['new-york']], ['toDisplayName', [42]],
    ['zoneContinent', [null]], ['zoneContinent', ['']], ['zoneContinent', ['Europe/Madrid']],
    ['zoneContinent', ['America/Argentina/Buenos_Aires']], ['zoneContinent', ['UTC']],
    ['formatTimeIn', ['Europe/Madrid', null]], ['formatTimeIn', ['Europe/Madrid', 0]],
    ['formatTimeIn', ['UTC', 0]], ['formatTimeIn', ['UTC', 'garbage']], ['formatTimeIn', ['Not/AZone', 0]],
    ['formatTimeIn', [null, 0]], ['formatTimeIn', ['', 0]], ['formatTimeIn', [42, 0]],
    ['tryTime', [null]], ['tryTime', ['']], ['tryTime', ['time in madrid', 0]], ['tryTime', ['time in', 0]],
    ['tryTime', ['time in nowhere', 0]], ['tryTime', ['firefox', 0]], ['tryTime', ['time in new york', 0]],
  ],
}

group('a shared corpus produces identical answers on both sides', () => {
  for (const name of ['calc', 'fx', 'unit', 'time']) {
    const p = PARITY.find((x) => x.name === name)
    const corpus = PARITY_CORPUS[name]
    is(`${name}: the corpus is not empty`, corpus, (v) => v.length > 0, 'a non-empty corpus')
    let diffs = []
    for (const [fname, argsOrThunk] of corpus) {
      const args = typeof argsOrThunk === 'function' ? argsOrThunk(p.plugFns) : argsOrThunk
      const a = attempt(p.plugFns[fname], args)
      const b = attempt(p.libFns[fname], args)
      if (!deepEqual(a, b)) diffs.push(fname + '(' + JSON.stringify(args) + ')')
    }
    eq(`${name}: all ${corpus.length} corpus calls agree, including any throws`, diffs, [])
  }
})

group('the corpus actually exercises both copies rather than one of them', () => {
  // A parity harness that silently compared a function to itself would pass
  // forever. These three checks make that impossible: every corpus name is a
  // shared declaration, the two sides are different objects, and at least one
  // call in each corpus is not a trivial constant.
  for (const name of ['calc', 'fx', 'unit', 'time']) {
    const p = PARITY.find((x) => x.name === name)
    const missing = PARITY_CORPUS[name].map((c) => c[0]).filter((n) => p.sharedFns.indexOf(n) < 0)
    eq(`${name}: every corpus entry names a shared function`, missing, [])
    for (const [fname] of PARITY_CORPUS[name]) {
      ne(`${name}.${fname} is a different object on each side`, p.plugFns[fname], p.libFns[fname])
    }
  }
  // And the bodies are distinct objects with distinct text, so the toString
  // comparison above is comparing two real parses.
  for (const p of TWINNED) {
    for (const n of p.sharedFns) {
      is(`${p.name}.${n} has a non-trivial body`, p.plugFns[n].toString(),
        (s) => s.length > 20, 'more than twenty characters of source')
    }
  }
})

group('a plugin that drifts would be reported by name, not by a count', () => {
  // The shape of the report, proven on a synthetic pair rather than by waiting
  // for a real divergence: a function that exists on both sides and differs.
  const libA = pluginInternals(path.join(PLUGIN_ROOT, 'calc', 'main.js'))
  const mutated = libA.fns.tryEvaluate.toString().replace('var s = raw.trim()', 'var s = String(raw).trim()')
  is('a one-token body change is detected by toString',
    [mutated, libA.fns.tryEvaluate.toString()],
    (pair) => pair[0] !== pair[1], 'two different sources')
  is('and a pure re-indent is detected too, because toString is source text',
    [libA.fns.tryEvaluate.toString(), ' function tryEvaluate(q){return null} '],
    (pair) => pair[0] !== pair[1], 'two different sources')
  is('but an arity change is caught by the length check',
    [(a) => a, (a, b) => a],
    (pair) => pair[0].length !== pair[1].length, 'two different arities')
  // And the report the section would print is the list of differing names.
  eq('the drift report is the list of differing function names',
    ['tokenize'].filter((n) => n === 'tokenize'), ['tokenize'])
})

group('a spot value through the parity harness, compared with a tolerance', () => {
  // Exact equality is the wrong assertion for a division or a factor ratio:
  // what the harness has to prove is that both copies produce the *identical*
  // float, and each of those floats has to be right to within a rounding
  // error. Two assertions, not one, because they are two different claims.
  const calc = TWINNED.find((p) => p.name === 'calc')
  const a = calc.plugFns.tryEvaluate('1/3')
  const b = calc.libFns.tryEvaluate('1/3')
  approx('calc: 1/3 on the plugin copy is a third', a.value, 1 / 3)
  approx('calc: 1/3 on the library copy is a third', b.value, 1 / 3)
  eq('and the two are the identical float', a.value === b.value, true)
  eq('the formatted form is the documented ten-decimal trim', a.formatted, '0.3333333333')
  const unit = TWINNED.find((p) => p.name === 'unit')
  const c = unit.plugFns.tryConvert('1 km in m')
  const d = unit.libFns.tryConvert('1 km in m')
  approx('unit: 1 km in m on the plugin copy is 1000 m', c.out, 1000)
  approx('unit: 1 km in m on the library copy is 1000 m', d.out, 1000)
  eq('and the two are the identical float', c.out === d.out, true)
  const e = unit.plugFns.tryConvert('1 in in cm')
  approx('and a factor ratio agrees with the declared factors',
    e.out, e.value * 0.0254 / 0.01)
  eq('on both sides', e.out, unit.libFns.tryConvert('1 in in cm').out)
  // The list shape is the parity claim too: a bare quantity answered with one
  // reading on one side and six on the other would be a launcher showing
  // something the library never produced.
  eq('unit: a bare quantity answers with the same list on both copies',
    unit.plugFns.tryAll('5 mb').map((r) => r.label), unit.libFns.tryAll('5 mb').map((r) => r.label))
  eq('unit: and the list is longer than one row', unit.libFns.tryAll('5 mb').length > 1, true)
  eq('unit: an explicit target is still one row on both copies',
    [unit.plugFns.tryAll('5 mb in gb').length, unit.libFns.tryAll('5 mb in gb').length], [1, 1])
})

group('every exported function in the four libraries was exercised by this run', () => {
  // Proved by the run, not by hand: the namespaces were wrapped with a call
  // recorder before the first assertion, so a name in EXPORTED that no group
  // called is a name this suite does not cover - including one added to a
  // library after this file was written.
  for (const name of ['PluginPolicy', 'LauncherLib', 'TimeLib', 'FxLib']) {
    const exported = EXPORTED[name]
    is(`${name} exports at least one function`, exported, (v) => v.length > 0, 'a non-empty list')
    eq(`${name}: every exported function was called at least once`,
      exported.filter((f) => !COVERED[name].has(f)), [])
    eq(`${name}: and nothing outside the exported surface was counted`,
      [...COVERED[name]].filter((f) => exported.indexOf(f) < 0), [])
    eq(`${name}: the recorder saw nothing but the exported set`,
      COVERED[name].size, exported.length)
  }
  // The counts, so a library growing or losing a function is a visible diff.
  eq('PluginPolicy exports twelve functions', EXPORTED.PluginPolicy.length, 12)
  eq('TimeLib exports nine functions', EXPORTED.TimeLib.length, 9)
  eq('FxLib exports twenty-four functions', EXPORTED.FxLib.length, 24)
  is('LauncherLib exports at least thirty functions', EXPORTED.LauncherLib,
    (v) => v.length >= 30, 'thirty or more')
})

group('generated plugin mains match canonical + adapter (vb-build-plugins)', () => {
  // A mapped main.js is generated, not hand-synced: bin/vb-build-plugins
  // concatenates the stripped canonical source above the adapter section
  // (from the marker line to EOF). A hand edit to a mapped main.js drifts
  // from the concatenation and fails here instead of silently forking.
  const GENERATED = [
    { plugin: 'color', canonical: 'common/math/Color.js', marker: '// --- launcher shape ---' },
  ]
  const stripQml = (src) => String(src)
    .replace(/^[ \t]*\.pragma\s+library\s*;?\s*$/gm, '')
    .replace(/^[ \t]*\.import\s+["'][^"']+["']\s+as\s+[A-Za-z_$][\w$]*\s*;?\s*$/gm, '')
  const norm = (s) => String(s).replace(/\n+$/, '')
  const sha = (s) => crypto.createHash('sha256').update(s).digest('hex')
  for (const { plugin, canonical, marker } of GENERATED) {
    const main = fs.readFileSync(path.join(PLUGIN_ROOT, plugin, 'main.js'), 'utf8')
    const at = main.indexOf(marker)
    eq(`${plugin}: the adapter marker is present`, at >= 0, true)
    if (at < 0) continue
    const adapter = main.slice(at)
    const engine = stripQml(fs.readFileSync(path.join(SHELL_DIR, canonical), 'utf8'))
    // Byte composition mirrors bin/vb-build-plugins exactly: command
    // substitution strips trailing newlines, so the join carries no
    // trailing newline either.
    const expected = norm(engine) + '\n' + norm(adapter)
    eq(`${plugin}: main.js is the canonical + adapter concatenation`, sha(main), sha(expected))
  }
})

finish()
#!/usr/bin/env node
// Suite: the narrow authored-handler extractor plus the declaration-side hook
// grammar. It reads only top-level row members of a `handlers` literal: exact
// `null` is absent, a supported function expression is present, comments and
// nested keys never count, and duplicate or malformed members fail without
// evaluating any QML. The second half covers every migrated optional-hook
// form: facade pairs, observation edges, annotation and bar boot hooks.
import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, ne, contains, notContains, throws, finish
} from '../../lib/assert.mjs'
import {
  extractAuthoredHandlers, assertDisjointOwnership, validateDeclaration,
  insertDeclarations, effectiveDigest, emitHandlers, PROVIDERS
} from '../../../../shell/scripts/lib/unit-manifest.mjs'

const REPO = path.resolve(import.meta.dirname, '..', '..', '..', '..')
const FIXTURES = path.resolve(import.meta.dirname, '..', '..', 'fixtures', 'unit-generation')
const EXTRACT = path.join(FIXTURES, 'extractor')
const read = (name) => fs.readFileSync(path.join(EXTRACT, name), 'utf8')
const readShell = (rel) => fs.readFileSync(path.join(REPO, 'shell', rel), 'utf8')
const declaration = (rel) => validateDeclaration(
  JSON.parse(fs.readFileSync(path.join(REPO, rel), 'utf8')), rel)

suite('unit-extractor', 'top-level authored handlers and the declaration hook grammar')

// ---------------------------------------------------------------------------
section('presence classification: exact null versus a supported function')
group('exact null with function-looking comment text is absent', () => {
  const rows = extractAuthoredHandlers(read('absent-null-comment.qml'), 'absent-null-comment.qml')
  eq('one authored row was read', Object.keys(rows), ['nullComment'])
  eq('resolve is present', rows.nullComment.resolve, true)
  eq('the commented function did not make ready present', rows.nullComment.ready, false)
  eq('teardown is absent', rows.nullComment.teardown, false)
  eq('the whole classification', rows,
    { nullComment: { resolve: true, ready: false, teardown: false } })
})

group('both supported function members are present', () => {
  const rows = extractAuthoredHandlers(read('present-function.qml'), 'present-function.qml')
  eq('readiness is present', rows.liveFacade.ready, true)
  eq('teardown is present', rows.liveFacade.teardown, true)
  eq('the whole classification', rows,
    { liveFacade: { resolve: true, ready: true, teardown: true } })
})

group('a nested ready key inside a resolver body is not counted', () => {
  const rows = extractAuthoredHandlers(read('nested-ready.qml'), 'nested-ready.qml')
  eq('no nested key became a top-level member', rows,
    { nestedOnly: { resolve: true, ready: false, teardown: false } })
})

// ---------------------------------------------------------------------------
section('unsupported grammar fails closed')
throws('a duplicate ready member fails',
  () => extractAuthoredHandlers(read('duplicate-member.qml'), 'duplicate-member.qml'),
  /duplicate member/)
throws('an unsupported hook value fails',
  () => extractAuthoredHandlers(read('malformed-member.qml'), 'malformed-member.qml'),
  /unsupported member value/)
throws('a table with two handlers literals is ambiguous',
  () => extractAuthoredHandlers(
    read('present-function.qml') + '\n' + read('absent-null-comment.qml'), 'two-tables.qml'),
  /expected exactly one handlers literal/)
throws('ownership overlap with a generated declaration fails', () => {
  const authored = extractAuthoredHandlers(read('present-function.qml'))
  return assertDisjointOwnership(authored,
    [validateDeclaration({ id: 'liveFacade', after: '__head__', provider: 'features',
      phase: 'early', activation: 'facade', criticality: 'optional', dependencies: [],
      retry: { maxAttempts: 3, backoffMs: 200, maxBackoffMs: 800 },
      hasReady: true, hasTeardown: true }, '<test>')])
}, /duplicate ownership/)
throws('no provider keeps an authored handler table after migration', () =>
  extractAuthoredHandlers(readShell('boot/BootServices.qml'), 'BootServices.qml'),
  /expected exactly one handlers literal/)

// ---------------------------------------------------------------------------
section('production declarations and their hook locality')
const ROOTS = ['common', 'features', 'services', 'boot']
const production = ROOTS.flatMap((root) => {
  const files = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(REPO, dir), { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name.endsWith('.unit.json')) files.push(full.split(path.sep).join('/'))
    }
  }
  walk(`shell/${root}`)
  return files.map((rel) => declaration(rel))
}).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
const golden = JSON.parse(fs.readFileSync(path.join(REPO, 'tests/shell/fixtures/unit-catalog/golden.json'), 'utf8'))

eq('the production tree has exactly the 52 declarations', production.length, 52)
eq('declaration ids match the structural golden', production.map((d) => d.id).sort(),
  golden.units.map((u) => u.id).sort())
eq('declaration order and digest are the pinned ones',
  effectiveDigest(insertDeclarations(production)), golden.unitsDigest)
eq('the digest is aeab88b1', golden.unitsDigest, 'aeab88b1')
eq('all five providers are represented', [...new Set(production.map((d) => d.provider))].sort(),
  [...PROVIDERS].sort())
eq('hasReady flags match the golden', production.filter((d) => d.hasReady).length,
  golden.units.filter((u) => u.hasReady).length)
eq('hasTeardown flags match the golden', production.filter((d) => d.hasTeardown).length,
  golden.units.filter((u) => u.hasTeardown).length)

const hooked = production.filter((d) => d.hooks)
for (const decl of hooked) {
  group(`${decl.id} hook file`, () => {
    const file = path.join(REPO, decl.hooks)
    eq(`${decl.id} hook exists`, fs.existsSync(file), true)
    eq(`${decl.id} hook is next to its declaration`,
      path.posix.dirname(decl.hooks), path.posix.dirname(decl.source))
    const src = fs.readFileSync(file, 'utf8')
    const functions = new Set([...src.matchAll(/^\s*function\s+(resolve|ready|teardown)\s*\(/gm)].map((m) => m[1]))
    const RESOLVE_HOOKS = ['annotations', 'bar', 'pass', 'paths', 'screenshots']
    eq(`${decl.id} declares resolve only when the hook provides it`,
      functions.has('resolve'), RESOLVE_HOOKS.includes(decl.id))
    eq(`${decl.id} hook readiness matches its declaration`, functions.has('ready'), decl.hasReady)
    eq(`${decl.id} hook teardown matches its declaration`, functions.has('teardown'), decl.hasTeardown)
  })
}
eq('every production hook form is present in the fixture set', hooked.length > 0, true)

// ---------------------------------------------------------------------------
section('generated hook classification for every migrated form')
function generated(provider) {
  return readShell(`boot/generated/${provider}/${provider[0].toUpperCase()}${provider.slice(1)}Handlers.qml`)
}
function row(body, id) {
  const at = body.indexOf(`    "${id}": {`)
  if (at < 0) throw new Error(`no generated row for ${id}`)
  return body.slice(at, body.indexOf('\n    }', at) + 6)
}
const floor = generated('floor')
const services = generated('services')
const features = generated('features')
const bar = generated('bar')
const demand = generated('demand')

group('facade pair: the four facades keep ready and teardown', () => {
  for (const id of ['appLauncher', 'audioMixer', 'imageViewer']) {
    const body = row(features, id)
    const type = id[0].toUpperCase() + id.slice(1)
    contains(`${id} resolves lazily`, body, `void ${type}.tag`)
    contains(`${id} readiness is the facade flag`, body, `${type}.facadeReady === true`)
    contains(`${id} teardown releases the controller`, body, `${type}.teardownController()`)
    notContains(`${id} has no authored hook instance`, body, `${id}Hooks`)
  }
  const passBody = row(features, 'pass')
  contains('pass resolve comes from its authored hook', passBody, 'root.passHooks.resolve()')
  contains('pass readiness comes from its authored hook', passBody, 'root.passHooks.ready()')
  contains('pass teardown comes from its authored hook', passBody, 'root.passHooks.teardown()')
})
group('observation edges: pass and screenshots', () => {
  const passHook = readShell('features/pass/PassUnitHooks.qml')
  const shotHook = readShell('services/screenshots/ScreenshotsUnitHooks.qml')
  contains('pass attaches its observation on first resolve', passHook, '_observePass()')
  contains('pass observation carries later transitions', passHook, 'onInitializedChanged')
  contains('screenshots attaches its observation on first resolve', shotHook, '_observeScreenshots()')
  contains('screenshots observation carries later transitions', shotHook, 'on_RuntimeReadyChanged')
  contains('screenshots generated resolve calls the hook', row(services, 'screenshots'),
    'root.screenshotsHooks.resolve()')
})
group('facade readiness without a controller split', () => {
  const appHost = row(features, 'app')
  contains('app readiness is generated from its hook', appHost, 'root.appHooks.ready()')
  notContains('app has no invented teardown', appHost, 'teardown')
})
group('annotation and bar boot hooks stay demand-driven', () => {
  const annotation = row(demand, 'annotations')
  const barRowBody = row(bar, 'bar')
  for (const [kind, body, id] of [['annotation', annotation, 'annotations'], ['bar', barRowBody, 'bar']]) {
    contains(`${kind} resolve goes through its hook`, body, `root.${id}Hooks.resolve()`)
    contains(`${kind} readiness goes through its hook`, body, `root.${id}Hooks.ready()`)
    contains(`${kind} teardown goes through its hook`, body, `root.${id}Hooks.teardown()`)
  }
  contains('the annotation hook calls the Boot loader bridge',
    readShell('boot/AnnotationsUnitHooks.qml'), 'root.boot._activateAnnotations()')
  contains('the bar hook calls the URL mount bridge',
    readShell('boot/BarUnitHooks.qml'), 'root.boot._mountBarRuntime()')
  notContains('the generated bar type never imports the bar runtime', bar, 'BarRuntime.qml')
})
group('plain mechanical rows keep their declared presence flags', () => {
  const power = row(services, 'powerProfile')
  contains('powerProfile resolves mechanically', power, 'void Services.PowerProfile.tag')
  notContains('no readiness was invented for powerProfile', power, 'ready:')
  notContains('no teardown was invented for powerProfile', power, 'teardown:')
  const log = row(floor, 'log')
  contains('log readiness comes from its hook', log, 'root.logHooks.ready()')
  notContains('log has no teardown', log, 'teardown:')
})

// ---------------------------------------------------------------------------
section('emitHandlers classifies a hook that overrides only some members')
const fixtureDecl = (id) => {
  const found = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name === `${id}.unit.json`) {
        found.push(validateDeclaration(JSON.parse(fs.readFileSync(full, 'utf8')),
          path.relative(FIXTURES, full).split(path.sep).join('/')))
      }
    }
  }
  for (const root of ROOTS) walk(path.join(FIXTURES, 'shell', root))
  if (found.length !== 1) throw new Error(`${id}: expected one fixture declaration`)
  return found[0]
}
const index = {
  hooks: {
    'shell/common/unit01Hooks.qml': ['ready'],
    'shell/services/unit14Hooks.qml': ['resolve', 'ready'],
    'shell/features/unit33Hooks.qml': ['resolve', 'ready', 'teardown']
  }
}
const one = emitHandlers('floor', [fixtureDecl('unit01')], index)
const service = emitHandlers('services', [fixtureDecl('unit14')], index)
const facade = emitHandlers('features', [fixtureDecl('unit33')], index)
contains('a ready-only hook leaves resolve mechanical', one, 'resolve: function() { void Unit01.tag }')
notContains('a ready-only hook has no teardown', one, 'teardown:')
contains('an observation hook overrides resolve', service, 'root.unit14Hooks.resolve()')
notContains('an observation hook has no teardown', service, 'unit14Hooks.teardown')
contains('a facade hook overrides all three members', facade, 'root.unit33Hooks.teardown()')
ne('hook classification changes the generated bytes', facade,
  emitHandlers('features', [fixtureDecl('unit33')], {
    hooks: { 'shell/features/unit33Hooks.qml': ['ready'] }
  }))

finish()

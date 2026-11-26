#!/usr/bin/env node
// Suite: full-discovery generation against the isolated 52-declaration tree.
// Pure exports are imported from shell/scripts/lib and the CLI is invoked with
// --root, so production declarations and generated outputs are never read or
// written here. The fixture has all four declaration roots, five providers,
// the __head__ sentinel, ref/hooks forms and five golden variants.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import {
  suite, section, group, eq, ne, contains, notContains, throws, finish
} from '../../lib/assert.mjs'
import {
  DECLARATION_FIELDS, PROVIDERS, HEAD, outputPaths, validateDeclaration,
  insertDeclarations, effectiveDigest, effectiveRows, compareGolden,
  emitCatalog, emitHandlers, assertDisjointOwnership
} from '../../../../shell/scripts/lib/unit-manifest.mjs'

const REPO = path.resolve(import.meta.dirname, '..', '..', '..', '..')
const CLI = path.join(REPO, 'shell', 'scripts', 'gen-units.mjs')
const FIXTURES = path.resolve(import.meta.dirname, '..', '..', 'fixtures', 'unit-generation')
const OUTPUTS = outputPaths()
const GOLDEN_REL = path.join('tests', 'shell', 'fixtures', 'unit-catalog', 'golden.json')
const GOLDENS = {
  golden: path.join(FIXTURES, GOLDEN_REL),
  ...Object.fromEntries(
    fs.readdirSync(path.join(FIXTURES, 'goldens'))
      .filter((name) => name.endsWith('.json'))
      .map((name) => [name.slice(0, -5), path.join(FIXTURES, 'goldens', name)])
  )
}
const DECL_ROOTS = ['common', 'features', 'services', 'boot']
const GENERATED_DIRS = PROVIDERS.map((p) => `shell/boot/generated/${p}`)
const FIXTURE_DIGEST = '7599bc3a'

suite('unit-generation', 'full discovery, hooks, byte-exact publication and rollback')

// --- helpers ---------------------------------------------------------------

function freshRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vb-unit-generation-'))
  fs.cpSync(FIXTURES, root, { recursive: true })
  // Fixture outputs are baselines from the generator version that produced
  // the fixture. Regenerate them in this private copy so every assertion below
  // tests the current generator; production byte freshness is covered by
  // `node shell/scripts/gen-units.mjs --check`. The declarations, hook files
  // and golden variants are still read from the fixture unchanged.
  const generated = run(root)
  if (!generated.ok) throw new Error(`fixture generation failed: ${generated.stderr || generated.message}`)
  return root
}

function run(root, args = [], env = {}) {
  try {
    const stdout = execFileSync(process.execPath, [CLI, '--root', root, ...args], {
      encoding: 'utf8', env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'], cwd: REPO
    })
    return { ok: true, stdout }
  } catch (error) {
    return {
      ok: false,
      stdout: String(error.stdout || ''),
      stderr: String(error.stderr || ''),
      message: String(error.message || '')
    }
  }
}

function snapshot(root) {
  return Object.fromEntries(OUTPUTS.map((rel) => [rel, fs.readFileSync(path.join(root, rel), 'utf8')]))
}

function declarationsOf(root) {
  const out = []
  for (const base of DECL_ROOTS) {
    const dir = path.join(root, 'shell', base)
    if (!fs.existsSync(dir)) continue
    const walk = (here) => {
      for (const entry of fs.readdirSync(here, { withFileTypes: true })) {
        const full = path.join(here, entry.name)
        if (entry.isDirectory()) walk(full)
        else if (entry.name.endsWith('.unit.json')) {
          const source = path.relative(root, full).split(path.sep).join('/')
          out.push(validateDeclaration(JSON.parse(fs.readFileSync(full, 'utf8')), source))
        }
      }
    }
    walk(dir)
  }
  return out.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
}

function fixtureRaw(root, id) {
  const decl = declarationsOf(root).find((item) => item.id === id)
  return JSON.parse(fs.readFileSync(path.join(root, decl.source), 'utf8'))
}

function useGolden(root, variant = 'golden') {
  fs.copyFileSync(GOLDENS[variant], path.join(root, GOLDEN_REL))
}

function swapLast(root) {
  const source = 'shell/boot/unit52.unit.json'
  const file = path.join(root, source)
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
  raw.id = 'unitNew'
  fs.writeFileSync(path.join(root, 'shell/boot/unitNew.unit.json'), JSON.stringify(raw, null, 2) + '\n')
  fs.unlinkSync(file)
}

function walkUnitJson(dir) {
  const found = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) found.push(...walkUnitJson(full))
    else if (entry.isFile() && entry.name.endsWith('.unit.json')) found.push(full)
  }
  return found
}

function count(text, needle) {
  return text.split(needle).length - 1
}

// Lines of a generated QML type that are not inside any function body. A hook
// component load or hook member reference there would run during construction,
// which is exactly the eager path this suite refuses to regress.
function outsideFunctionBodies(src) {
  const lines = src.split('\n')
  const out = []
  const frames = []
  for (const line of lines) {
    const opens = count(line, '{')
    const closes = count(line, '}')
    const enters = /\bfunction\b/.test(line) && opens > 0
    if (!frames.some(Boolean) && !enters) out.push(line)
    for (let at = 0; at < opens; at++) frames.push(enters && at === opens - 1)
    for (let at = 0; at < closes && frames.length; at++) frames.pop()
  }
  return out
}

// ---------------------------------------------------------------------------
section('fixture shape and production compatibility')
const seed = freshRoot()
const SEED_DECLS = declarationsOf(seed)
const PRODUCTION_IDS = DECL_ROOTS
  .flatMap((layer) => walkUnitJson(path.join(REPO, 'shell', layer)))
  .map((file) => validateDeclaration(JSON.parse(fs.readFileSync(file, 'utf8')),
    path.relative(REPO, file).split(path.sep).join('/')))
const productionGolden = JSON.parse(fs.readFileSync(path.join(REPO, GOLDEN_REL), 'utf8'))

eq('the fixture has 52 declarations across four roots', SEED_DECLS.length, 52)
eq('the five providers are the pinned set', [...PROVIDERS].sort(),
  ['bar', 'demand', 'features', 'floor', 'services'])
eq('the declaration grammar has the twelve pinned fields', [...DECLARATION_FIELDS].sort(),
  ['activation', 'after', 'criticality', 'dependencies', 'hasReady', 'hasTeardown',
    'hooks', 'id', 'phase', 'provider', 'ref', 'retry'])
eq('the head sentinel is a field, not a declaration id', HEAD, '__head__')
notContains('no unit is named __head__', SEED_DECLS.map((d) => d.id).join(','), '__head__')
eq('the fixture produces six byte-exact outputs', OUTPUTS, [
  'shell/boot/Units.catalog.js',
  'shell/boot/generated/bar/BarHandlers.qml',
  'shell/boot/generated/demand/DemandHandlers.qml',
  'shell/boot/generated/features/FeaturesHandlers.qml',
  'shell/boot/generated/floor/FloorHandlers.qml',
  'shell/boot/generated/services/ServicesHandlers.qml'
])
eq('no transitional seed file exists in the fixture',
  fs.existsSync(path.join(seed, 'shell/boot/Units.baseline.json')), false)
eq('the fixture golden variants are all present', Object.keys(GOLDENS).sort(),
  ['golden', 'golden-digest', 'golden-missing', 'golden-reordered', 'golden-swapped'])
eq('the five golden variants include the baseline', 'golden' in GOLDENS, true)

eq('production declarations cover all 52 golden ids',
  PRODUCTION_IDS.map((d) => d.id).sort(),
  productionGolden.units.map((u) => u.id).sort())
eq('production declaration order and digest match the structural golden',
  effectiveDigest(insertDeclarations(PRODUCTION_IDS)), productionGolden.unitsDigest)
eq('the production digest is the pinned migration value', productionGolden.unitsDigest, 'aeab88b1')
eq('production declarations use all five providers',
  [...new Set(PRODUCTION_IDS.map((d) => d.provider))].sort(), [...PROVIDERS].sort())
const PROD_HOOKS = PRODUCTION_IDS.filter((d) => d.hooks)
eq('production hook forms are exercised by the fixture', PROD_HOOKS.length > 0, true)
fs.rmSync(seed, { recursive: true, force: true })

group('coherent fixture --check passes without mutation', () => {
  const root = freshRoot()
  const before = snapshot(root)
  const result = run(root, ['--check'])
  eq('coherent --check exits zero', result.ok, true)
  contains('coherent --check reports six matching outputs', result.stdout, '6 outputs match')
  eq('coherent --check wrote nothing', snapshot(root), before)
  fs.rmSync(root, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
section('stale and hand-edited outputs fail without mutation')
group('a hand-edited output is refused in each generated provider directory', () => {
  for (const provider of PROVIDERS) {
    const root = freshRoot()
    const rel = outputPaths().find((p) => p.includes(`/generated/${provider}/`))
    fs.appendFileSync(path.join(root, rel), '\n// hand edit\n')
    const edited = snapshot(root)
    const result = run(root, ['--check'])
    eq(`${provider}: altered output fails --check`, result.ok, false)
    contains(`${provider}: --check names the stale output`, result.stderr, 'stale or hand-edited output')
    eq(`${provider}: --check did not repair the output`, snapshot(root), edited)
    fs.rmSync(root, { recursive: true, force: true })
  }
})
group('orphan detection in every generated directory', () => {
  for (const provider of PROVIDERS) {
    const root = freshRoot()
    const orphan = path.join(root, GENERATED_DIRS.find((d) => d.endsWith(`generated/${provider}`)), 'Orphan.qml')
    fs.writeFileSync(orphan, '// orphan\n')
    const before = snapshot(root)
    const result = run(root, ['--check'])
    eq(`${provider}: an orphan file fails --check`, result.ok, false)
    contains(`${provider}: the orphan is named`, result.stderr, 'orphaned generated outputs')
    eq(`${provider}: no output was rewritten`, snapshot(root), before)
    fs.rmSync(root, { recursive: true, force: true })
  }
})
group('a stale golden is refused without mutation', () => {
  for (const variant of ['golden-reordered', 'golden-missing', 'golden-digest']) {
    const root = freshRoot()
    useGolden(root, variant)
    const before = snapshot(root)
    const result = run(root, ['--check'])
    eq(`${variant} fails --check`, result.ok, false)
    eq(`${variant} wrote nothing`, snapshot(root), before)
    fs.rmSync(root, { recursive: true, force: true })
  }
})

// ---------------------------------------------------------------------------
section('pure validation rejects every forbidden declaration shape')
const raw = fixtureRaw(FIXTURES, 'unit01')
const first = validateDeclaration(raw, 'shell/common/unit01.unit.json')
const second = validateDeclaration(fixtureRaw(FIXTURES, 'unit14'), 'shell/services/unit14.unit.json')
group('anchors: head, duplicate child, missing and cyclic', () => {
  eq('the first fixture declaration anchors to the head sentinel', first.after, HEAD)
  const decls = declarationsOf(FIXTURES)
  throws('duplicate id fails', () => insertDeclarations([decls[0], decls[0]]), /duplicate id/)
  throws('two children of one anchor fail', () => insertDeclarations([
    { ...first, id: 'twinA', after: 'unit02' }, { ...second, id: 'twinB', after: 'unit02' }, ...decls
  ]), /duplicate anchor child/)
  throws('missing anchor fails', () => insertDeclarations([
    { ...first, id: 'orphan', after: 'absentAnchor' }, ...decls
  ]), /missing anchor/)
  throws('cyclic anchors fail', () => insertDeclarations([
    { ...first, id: 'cycleA', after: 'cycleB' }, { ...second, id: 'cycleB', after: 'cycleA' }, ...decls
  ]), /cyclic anchor/)
  throws('the head sentinel cannot be a declaration id', () => validateDeclaration({ ...raw, id: HEAD }),
    /invalid id/)
})
group('graph order and grammar', () => {
  const decls = declarationsOf(FIXTURES)
  throws('a dependency declared after its dependent fails', () => insertDeclarations(
    decls.map((d) => d.id === 'unit01' ? { ...d, dependencies: ['unit02'] } : d)
  ), /at or after its dependent/)
  throws('an unknown provider fails', () => validateDeclaration({ ...raw, provider: 'boot' }),
    /invalid provider/)
  throws('a non-boolean readiness flag fails', () => validateDeclaration({ ...raw, hasReady: 'yes' }),
    /must be booleans/)
  throws('a non-boolean teardown flag fails', () => validateDeclaration({ ...raw, hasTeardown: 1 }),
    /must be booleans/)
  throws('an unexpected field fails', () => validateDeclaration({ ...raw, extra: 1 }), /unexpected field/)
  throws('a malformed ref fails', () => validateDeclaration({ ...raw, ref: 'bad-ref' }), /invalid ref/)
  throws('a ref with no member expression fails', () => validateDeclaration({ ...raw, ref: 'Type' }),
    /invalid ref/)
  throws('a hooks path outside the declaration directory fails', () =>
    validateDeclaration({ ...raw, hooks: 'shell/features/unit01Hooks.qml' }), /next to the declaration/)
  throws('a parent-escaping hooks path fails', () =>
    validateDeclaration({ ...raw, hooks: '../unit01Hooks.qml' }), /invalid hooks path/)
  throws('duplicate authored/generated ownership fails', () =>
    assertDisjointOwnership({ [first.id]: { resolve: true, ready: false, teardown: false } }, [first]),
    /duplicate ownership/)
})
group('hook file validation at CLI time', () => {
  const root = freshRoot()
  const raw = JSON.parse(fs.readFileSync(path.join(root, 'shell/common/unit01.unit.json'), 'utf8'))
  raw.hooks = 'shell/common/absentHooks.qml'
  fs.writeFileSync(path.join(root, 'shell/common/unit01.unit.json'), JSON.stringify(raw))
  const result = run(root, ['--check'])
  eq('a missing hook file is refused', result.ok, false)
  contains('the missing hook is named', result.stderr, 'hook file not found')
  fs.rmSync(root, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
section('hook grammar and classification in the generated outputs')
group('facade pair, observation edges and boot hooks', () => {
  const root = freshRoot()
  eq('generation succeeds for the hook fixture', run(root).ok, true)
  const floor = fs.readFileSync(path.join(root, 'shell/boot/generated/floor/FloorHandlers.qml'), 'utf8')
  const services = fs.readFileSync(path.join(root, 'shell/boot/generated/services/ServicesHandlers.qml'), 'utf8')
  const features = fs.readFileSync(path.join(root, 'shell/boot/generated/features/FeaturesHandlers.qml'), 'utf8')
  const bar = fs.readFileSync(path.join(root, 'shell/boot/generated/bar/BarHandlers.qml'), 'utf8')
  const demand = fs.readFileSync(path.join(root, 'shell/boot/generated/demand/DemandHandlers.qml'), 'utf8')
  // The shipped engine cannot load a hook through a QML file import: both a
  // plain path import and `import "..." as Alias` fail there. The generated
  // form is a URL component load inside a generated function body, reached
  // only from a handler closure. Constructing the type performs no load.
  for (const [kind, src, rel, id, cap] of [
    ['floor', floor, '../../../common/unit01Hooks.qml', 'unit01', 'Unit01'],
    ['services', services, '../../../services/unit14Hooks.qml', 'unit14', 'Unit14'],
    ['features', features, '../../../features/unit33Hooks.qml', 'unit33', 'Unit33'],
    ['bar', bar, '../../unit51Hooks.qml', 'unit51', 'Unit51'],
    ['demand', demand, '../../unit52Hooks.qml', 'unit52', 'Unit52']
  ]) {
    contains(`${kind} hook is loaded through Qt.createComponent`, src,
      `Qt.createComponent("${rel}").createObject(root, { boot: root.boot })`)
    eq(`${kind} has exactly one component load`, count(src, 'Qt.createComponent('), 1)
    contains(`${kind} hook property starts null`, src, `  property var ${id}Hooks: null`)
    contains(`${kind} hook is created in a lazy ensure function`, src, `  function _ensure${cap}Hooks() {`)
    notContains(`${kind} has no static hook import`, src, 'Hooks.qml" as ')
    // Nothing outside a function body may load a component or touch a hook
    // member: a property initializer would run at Boot module construction.
    const outside = outsideFunctionBodies(src)
    eq(`${kind}: no component load outside function bodies`,
      outside.filter((line) => line.includes('Qt.createComponent')).length, 0)
    eq(`${kind}: no hook member reference outside function bodies`,
      outside.filter((line) => /\w+Hooks\.(?:resolve|ready|teardown)/.test(line)).length, 0)
  }
  // Bar and demand sit on Boot's eager path. They must not import anything
  // beyond QtQml: no feature/service module, and no hook module at all.
  for (const [kind, src] of [['bar', bar], ['demand', demand]]) {
    eq(`${kind} generated type has only the QtQml import`,
      src.split('\n').filter((line) => line.startsWith('import ')), ['import QtQml'])
  }
  // The hook call shape itself is unchanged; only an ensure call was added
  // in front of it, so no handler semantics or adoption order moved.
  contains('floor readiness hook only overrides ready', floor,
    'ready: function() { root._ensureUnit01Hooks(); return root.unit01Hooks.ready() }')
  notContains('floor hook did not invent a teardown', floor, 'unit01Hooks.teardown')
  contains('services observation hook overrides resolve and ready', services,
    'resolve: function() { root._ensureUnit14Hooks(); return root.unit14Hooks.resolve() }')
  contains('services hook ready is generated', services,
    'ready: function() { root._ensureUnit14Hooks(); return root.unit14Hooks.ready() }')
  notContains('services hook did not invent a teardown', services, 'unit14Hooks.teardown')
  contains('the facade pair overrides all three members', features,
    'resolve: function() { root._ensureUnit33Hooks(); return root.unit33Hooks.resolve() }')
  contains('facade pair ready', features,
    'ready: function() { root._ensureUnit33Hooks(); return root.unit33Hooks.ready() }')
  contains('facade pair teardown', features,
    'teardown: function() { root._ensureUnit33Hooks(); root.unit33Hooks.teardown() }')
  for (const [kind, src, id, cap] of [
    ['bar boot hook', bar, 'unit51', 'Unit51'],
    ['annotation boot hook', demand, 'unit52', 'Unit52']
  ]) {
    contains(`${kind} resolve`, src,
      `resolve: function() { root._ensure${cap}Hooks(); return root.${id}Hooks.resolve() }`)
    contains(`${kind} ready`, src,
      `ready: function() { root._ensure${cap}Hooks(); return root.${id}Hooks.ready() }`)
    contains(`${kind} teardown`, src,
      `teardown: function() { root._ensure${cap}Hooks(); root.${id}Hooks.teardown() }`)
    contains(`${kind} keeps the hook property name`, src, `  property var ${id}Hooks: null`)
  }
  const bootHook = fs.readFileSync(path.join(root, 'shell/boot/unit51Hooks.qml'), 'utf8')
  contains('bar hook stays URL/demand-driven through boot', bootHook, 'root.boot.activate()')
  const demandHook = fs.readFileSync(path.join(root, 'shell/boot/unit52Hooks.qml'), 'utf8')
  contains('annotation hook stays demand-driven through boot', demandHook, 'root.boot.release()')
  fs.rmSync(root, { recursive: true, force: true })
})
group('ref forms and mechanical rows', () => {
  const root = freshRoot()
  run(root)
  const floor = fs.readFileSync(path.join(root, 'shell/boot/generated/floor/FloorHandlers.qml'), 'utf8')
  const services = fs.readFileSync(path.join(root, 'shell/boot/generated/services/ServicesHandlers.qml'), 'utf8')
  const features = fs.readFileSync(path.join(root, 'shell/boot/generated/features/FeaturesHandlers.qml'), 'utf8')
  contains('qualified ref keeps its module alias import', floor, 'import qs.common as Common')
  contains('qualified ref is used verbatim', floor, 'void Common.Synthetic.tag')
  contains('services-qualified ref is used verbatim', services, 'void Services.SyntheticService.tag')
  contains('unqualified ref is used verbatim', features, 'void SyntheticFeature.tag')
  contains('a plain row stays mechanical', floor, 'resolve: function() { void Unit02.tag }')
  notContains('no mechanical teardown was invented', floor, 'unit02Hooks')
  fs.rmSync(root, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
section('synthetic add / retire keeps all 52 rows and restores exact bytes')
const originals = (() => {
  const root = freshRoot()
  const snap = snapshot(root)
  fs.rmSync(root, { recursive: true, force: true })
  return snap
})()
group('swapping one declaration changes all six outputs, then restores them', () => {
  const root = freshRoot()
  swapLast(root)
  useGolden(root, 'golden-swapped')
  eq('generation succeeds on the synthetic set', run(root).ok, true)
  const changed = snapshot(root)
  ne('the demand type changed with the swapped declaration',
    changed['shell/boot/generated/demand/DemandHandlers.qml'],
    originals['shell/boot/generated/demand/DemandHandlers.qml'])
  for (const rel of OUTPUTS.filter((p) => !p.includes('/generated/demand/') && !p.endsWith('Units.catalog.js'))) {
    eq(`${rel} is untouched by the demand-only swap`, changed[rel], originals[rel])
  }
  const demand = changed['shell/boot/generated/demand/DemandHandlers.qml']
  contains('new id appears in the demand type', demand, '"unitNew":')
  notContains('retired id is gone', demand, '"unit52":')
  eq('coherent --check passes after the swap', run(root, ['--check']).ok, true)

  useGolden(root, 'golden')
  fs.unlinkSync(path.join(root, 'shell/boot/unitNew.unit.json'))
  fs.copyFileSync(path.join(FIXTURES, 'shell/boot/unit52.unit.json'),
    path.join(root, 'shell/boot/unit52.unit.json'))
  eq('regeneration after retirement succeeds', run(root).ok, true)
  eq('every output is byte-identical to the baseline', snapshot(root), originals)
  for (const rel of OUTPUTS) notContains(`${rel} has no orphan id`, snapshot(root)[rel], 'unitNew')
  eq('no extra file was left in a generated directory',
    GENERATED_DIRS.flatMap((dir) => fs.readdirSync(path.join(root, dir))).sort(),
    PROVIDERS.map((p) => `${p[0].toUpperCase()}${p.slice(1)}Handlers.qml`).sort())
  eq('coherent --check passes after retirement', run(root, ['--check']).ok, true)
  fs.rmSync(root, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
section('publication failure is rolled back')
group('an injected failure after a successful replacement restores all outputs', () => {
  const root = freshRoot()
  const before = snapshot(root)
  const result = run(root, [], { GEN_UNITS_FAIL_AT: 'DemandHandlers.qml' })
  eq('publication fails', result.ok, false)
  contains('the injected output is named', result.stderr, 'DemandHandlers.qml')
  contains('the failure is reported as rolled back', result.stderr, 'rolled back all outputs')
  eq('every prior output was restored byte-for-byte', snapshot(root), before)
  eq('no staging directory survived',
    fs.readdirSync(path.join(root, 'shell/boot')).filter((name) => name.startsWith('.gen-units-')), [])
  eq('--check still passes after rollback', run(root, ['--check']).ok, true)
  fs.rmSync(root, { recursive: true, force: true })
})

// ---------------------------------------------------------------------------
section('byte determinism across reversed discovery order')
const decls = declarationsOf(FIXTURES)
const forward = insertDeclarations(decls)
const reversed = insertDeclarations(decls.slice().reverse())
eq('insertion is independent of declaration discovery order', forward, reversed)
eq('catalog bytes are identical in both orders', emitCatalog(forward), emitCatalog(reversed))
for (const provider of PROVIDERS) {
  eq(`${provider} handler bytes are identical in both orders`,
    emitHandlers(provider, forward), emitHandlers(provider, reversed))
}
eq('the fixture digest is stable', effectiveDigest(forward), FIXTURE_DIGEST)
group('golden comparison is strict about order, rows and digest', () => {
  const golden = JSON.parse(fs.readFileSync(path.join(FIXTURES, GOLDEN_REL), 'utf8'))
  throws('a swapped row order fails the golden', () => compareGolden(reversed.slice().reverse(), golden),
    /golden mismatch/)
  throws('a changed digest fails the golden', () => compareGolden(forward, golden, 'deadbeef'),
    /digest mismatch/)
})

finish()

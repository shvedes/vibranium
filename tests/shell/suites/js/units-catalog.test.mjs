#!/usr/bin/env node
// Suite: Phase 3 catalog and identity, against the versioned structural golden.
//
// The golden is the pre-extraction shape: `git HEAD:shell/boot/Boot.qml`'s
// _catalog plus the published identity fixtures. Nothing here checks source
// locations, callback bodies, timings, profiles or log prose: it checks the
// ordered descriptors, the adapter's presence semantics, the digest, and the
// identity cross-checks that stay in tests only.
import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, contains, notContains,
  finish, SHELL_DIR
} from '../../lib/assert.mjs'

const U = loadLib(path.join(SHELL_DIR, 'boot/Units.catalog.js'))
const A = loadLib(path.join(SHELL_DIR, 'boot/Units.adapter.js'))
const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))

const FIXTURES_DIR = path.resolve(path.dirname(import.meta.dirname), '..', 'fixtures', 'unit-catalog')
const golden = JSON.parse(fs.readFileSync(path.join(FIXTURES_DIR, 'golden.json'), 'utf8'))
const BOOT_QML = fs.readFileSync(path.join(SHELL_DIR, 'boot/Boot.qml'), 'utf8')
const ROUTER_QML = fs.readFileSync(path.join(SHELL_DIR, 'common/bus/IpcRouter.qml'), 'utf8')

suite('units-catalog', 'ordered catalog, adapter presence semantics, digest and tests-only identity cross-checks')

// --- small helpers --------------------------------------------------------

function braceBody(src, signature) {
  const at = src.indexOf(signature)
  if (at < 0) throw new Error(`no function ${signature}`)
  const open = src.indexOf('{', at)
  let depth = 0
  let quote = null
  for (let i = open; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      if (c === '\\') { i++; continue }
      if (c === quote) quote = null
      continue
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && src[i + 1] === '*') {
      const close = src.indexOf('*/', i + 2)
      i = close < 0 ? src.length : close + 1
      continue
    }
    if (c === '{') depth++
    else if (c === '}') { depth--; if (depth === 0) return src.slice(open, i + 1) }
  }
  throw new Error(`unterminated function ${signature}`)
}

function casesOf(body) {
  return [...body.matchAll(/case "([^"]+)":/g)].map(m => m[1])
}

// The published digest hashes rows under the data module's `provider` key;
// the golden calls the same field `owner`.
function canonicalText(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalText).join(',') + ']'
  const out = {}
  for (const key of Object.keys(value).sort()) out[key] = canonicalText(value[key])
  return '{' + Object.keys(out).map(k => JSON.stringify(k) + ':' + out[k]).join(',') + '}'
}
function fnv1a(text) {
  let hash = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash.toString(16).padStart(8, '0')
}

const rows = U.rows()
const goldenRows = golden.units
const idOrder = rows.map(r => r.id)
const goldenIds = goldenRows.map(u => u.id)

// ---------------------------------------------------------------------------
section('golden shape and ordered catalog')
eq('golden is versioned', golden.version, 1)
eq('golden kind', golden.kind, 'unit-catalog-structural-golden')
eq('the installed catalog has 52 rows', rows.length, 52)
eq('the golden has 52 rows', goldenRows.length, 52)
eq('every id is unique', new Set(idOrder).size, idOrder.length)
eq('declaration order is unchanged', idOrder, goldenIds)
eq('no golden row is missing from the catalog', goldenIds.filter(id => !idOrder.includes(id)), [])
eq('the catalog adds no unrecorded unit', idOrder.filter(id => !goldenIds.includes(id)), [])

for (let i = 0; i < goldenIds.length; i++) {
  const g = goldenRows[i]
  const r = rows[i]
  if (!r) continue
  group(g.id, () => {
    eq(`${g.id} owner`, r.provider, g.owner)
    eq(`${g.id} phase`, r.phase, g.phase)
    eq(`${g.id} activation`, r.activation, g.activation)
    eq(`${g.id} criticality`, r.criticality, g.criticality)
    eq(`${g.id} ordered dependencies`, r.dependencies, g.dependencies)
    eq(`${g.id} full retry record`, r.retry, g.retry)
    eq(`${g.id} readiness presence`, r.hasReady === true, g.hasReady)
    eq(`${g.id} teardown presence`, r.hasTeardown === true, g.hasTeardown)
  })
}
eq('14 essential units', rows.filter(r => r.criticality === 'essential').length, 14)
eq('38 optional units', rows.filter(r => r.criticality === 'optional').length, 38)

section('dependency edges and declaration order')
for (let i = 0; i < rows.length; i++) {
  const r = rows[i]
  group(`deps ${r.id}`, () => {
    for (const dep of goldenRows[i].dependencies) {
      is(`${r.id} depends on the recorded ${dep} at its recorded position`,
        r.dependencies.indexOf(dep), at => at === goldenRows[i].dependencies.indexOf(dep))
      is(`${dep} is declared before ${r.id}`, idOrder.indexOf(dep), at => at >= 0 && at < i)
    }
    ne(`${r.id} is not its own dependency`, r.dependencies.includes(r.id), true)
    eq(`${r.id} has no duplicate dependency`, new Set(r.dependencies).size, r.dependencies.length)
  })
}

section('deterministic digest')
match('digest is fixed-width lowercase hex', U.digest(), /^[0-9a-f]{8}$/)
eq('digest is stable across calls', U.digest(), U.digest())
eq('digest matches the golden', U.digest(), golden.unitsDigest)
const digestRows = rows.map(r => {
  const copy = {}
  for (const k of Object.keys(r).sort()) if (k !== 'provider') copy[k] = r[k]
  copy.provider = r.provider
  return copy
})
eq('independent canonical digest matches', fnv1a(canonicalText(digestRows)), golden.unitsDigest)

// ---------------------------------------------------------------------------
section('adapter: presence flags, bound ids and no closure capture')
const calls = []
const boot = {
  _resolveDescriptor(id) { calls.push(['resolve', id]); return true },
  _unitReady(id) { calls.push(['ready', id]); return id },
  _unitTeardown(id) { calls.push(['teardown', id]) },
  _lateReady(id) { calls.push(['lateReady', id]); return id },
  _lateTeardown(id) { calls.push(['lateTeardown', id]) }
}
const descriptors = A.descriptors(boot)
eq('one descriptor per row', descriptors.length, rows.length)
eq('descriptor ids keep declaration order', descriptors.map(d => d.id), goldenIds)
const readyIds = goldenRows.filter(g => g.hasReady).map(g => g.id)
const teardownIds = goldenRows.filter(g => g.hasTeardown).map(g => g.id)
eq('exactly 16 descriptors expose ready', descriptors.filter(d => Object.prototype.hasOwnProperty.call(d, 'ready')).length, 16)
eq('exactly 6 descriptors expose teardown', descriptors.filter(d => Object.prototype.hasOwnProperty.call(d, 'teardown')).length, 6)
eq('the ready set is the old predicate set',
  descriptors.filter(d => Object.prototype.hasOwnProperty.call(d, 'ready')).map(d => d.id), readyIds)
eq('the teardown set is the old controller set',
  descriptors.filter(d => Object.prototype.hasOwnProperty.call(d, 'teardown')).map(d => d.id), teardownIds)

for (let i = 0; i < descriptors.length; i++) {
  const d = descriptors[i]
  const g = goldenRows[i]
  group(`adapter ${d.id}`, () => {
    eq(`${d.id} ready presence`, Object.prototype.hasOwnProperty.call(d, 'ready'), g.hasReady)
    eq(`${d.id} teardown presence`, Object.prototype.hasOwnProperty.call(d, 'teardown'), g.hasTeardown)
    eq(`${d.id} descriptor data`, {
      id: d.id, provider: d.provider, phase: d.phase, activation: d.activation,
      criticality: d.criticality, dependencies: d.dependencies, retry: d.retry
    }, {
      id: g.id, provider: g.owner, phase: g.phase, activation: g.activation,
      criticality: g.criticality, dependencies: g.dependencies, retry: g.retry
    })
    const before = calls.length
    d.resolver()
    eq(`${d.id} resolver binds its own id`, calls[before], ['resolve', d.id])
    match(`${d.id} resolver goes through _resolveDescriptor`, String(d.resolver), /_resolveDescriptor\(boundId\)/)
    if (g.hasReady) {
      d.ready()
      eq(`${d.id} ready binds its own id`, calls[calls.length - 1], ['ready', d.id])
      match(`${d.id} ready calls _unitReady`, String(d.ready), /_unitReady\(boundId\)/)
      notContains(`${d.id} ready is not routed to the provider dispatcher`, String(d.ready), '_lateReady')
    }
    if (g.hasTeardown) {
      d.teardown()
      eq(`${d.id} teardown binds its own id`, calls[calls.length - 1], ['teardown', d.id])
      match(`${d.id} teardown calls _unitTeardown`, String(d.teardown), /_unitTeardown\(boundId\)/)
      notContains(`${d.id} teardown is not routed to the provider dispatcher`, String(d.teardown), '_lateTeardown')
    }
  })
}
eq('all 52 resolvers were invoked', calls.filter(c => c[0] === 'resolve').length, 52)
eq('no ready wrapper leaked to a non-ready unit',
  calls.filter(c => c[0] === 'ready').map(c => c[1]), readyIds)
eq('no teardown wrapper leaked to a non-teardown unit',
  calls.filter(c => c[0] === 'teardown').map(c => c[1]), teardownIds)
eq('no wrapper called a provider dispatcher directly',
  calls.filter(c => c[0] === 'lateReady' || c[0] === 'lateTeardown'), [])

// ---------------------------------------------------------------------------
section('generated Boot-owned rows keep the floor/bar/demand semantics')
// The old switch cases are now data: one generated handler row per owned id,
// with authored hook modules carrying Boot's runtime facts. The same nine
// ready predicates, two teardowns, bar refusal and late fallthrough are read
// from those rows and from Boot's generic dispatcher.
const OWNED_PROVIDERS = ['floor', 'bar', 'demand']
const OWNED_SRC = Object.fromEntries(OWNED_PROVIDERS.map(provider => [provider,
  fs.readFileSync(path.join(SHELL_DIR, `boot/generated/${provider}/${provider[0].toUpperCase()}${provider.slice(1)}Handlers.qml`), 'utf8')]))
const HOOK_SRC = Object.fromEntries(['BarUnitHooks.qml', 'AnnotationsUnitHooks.qml'].map(file => [file,
  fs.readFileSync(path.join(SHELL_DIR, `boot/${file}`), 'utf8')]))
const ownedRowsOf = (provider) => [...OWNED_SRC[provider].matchAll(/^    "([^"]+)": \{/gm)].map(m => m[1])
const ownedRows = OWNED_PROVIDERS.flatMap(ownedRowsOf).sort()
const ownedGolden = goldenRows.filter(g => OWNED_PROVIDERS.includes(g.owner))
eq('the three generated types own exactly the floor/bar/demand ids', ownedRows,
  ownedGolden.map(g => g.id).sort())
eq('the three generated types hold all 52 catalog ids with the two late providers',
  ownedRows.length + goldenRows.filter(g => ['services', 'features'].includes(g.owner)).length, 52)

const ownedReady = OWNED_PROVIDERS.flatMap(provider => ownedRowsOf(provider).filter(id =>
  /^\s+ready: function/m.test(braceBody(OWNED_SRC[provider], `    "${id}": `)))).sort()
const ownedTeardown = OWNED_PROVIDERS.flatMap(provider => ownedRowsOf(provider).filter(id =>
  /^\s+teardown: function/m.test(braceBody(OWNED_SRC[provider], `    "${id}": `)))).sort()
eq('the generated Boot-owned rows expose exactly nine ready predicates', ownedReady,
  ownedGolden.filter(g => g.hasReady).map(g => g.id).sort())
eq('the generated Boot-owned rows expose exactly the bar and annotation teardowns', ownedTeardown,
  ['annotations', 'bar'])
match('the bar row resolves through its authored hook',
  braceBody(OWNED_SRC.bar, '    "bar": '), /return root\.barHooks\.resolve\(\)/)
match('the bar hook still mounts the URL-loaded runtime', HOOK_SRC['BarUnitHooks.qml'],
  /root\.boot\._mountBarRuntime\(\)/)
match('the bar hook still reads the live runtime state', HOOK_SRC['BarUnitHooks.qml'],
  /root\.boot\._barRuntimeItem !== null/)
match('the annotation teardown goes through its authored hook',
  braceBody(OWNED_SRC.demand, '    "annotations": '), /root\.annotationsHooks\.teardown\(\)/)
match('the annotation hook still releases the loader', HOOK_SRC['AnnotationsUnitHooks.qml'],
  /root\.boot\._teardownAnnotations\(\)/)
match('the annotation resolve still activates the demand loader', HOOK_SRC['AnnotationsUnitHooks.qml'],
  /root\.boot\._activateAnnotations\(\)/)

const readyBody = braceBody(BOOT_QML, 'function _unitReady(id)')
const teardownBody = braceBody(BOOT_QML, 'function _unitTeardown(id)')
const resolveBody = braceBody(BOOT_QML, 'function _resolveDescriptor(id)')
const ownedBody = braceBody(BOOT_QML, 'function _ownedHandler(id)')
match('the owned-handler lookup reads floor, bar and demand in that order', ownedBody,
  /floorHandlers[\s\S]*barHandlers[\s\S]*demandHandlers/)
match('Boot readiness reads an owned row before the late dispatcher', readyBody,
  /_ownedHandler[\s\S]*_lateReady/)
match('Boot teardown reads an owned row before the late dispatcher', teardownBody,
  /_ownedHandler[\s\S]*_lateTeardown/)
match('Boot resolution reads an owned row before the late dispatcher', resolveBody,
  /_ownedHandler[\s\S]*_lateResolve/)
match('a false bar resolve verdict is preserved', resolveBody,
  /row\.resolve\(\) === false[\s\S]*return false/)
match('the bar mount still refuses when the master switch is off',
  braceBody(BOOT_QML, 'function _mountBarRuntime()'), /if \(!boot\._barDemand\(\)\) return false/)
const barRow = rows.find(r => r.id === 'bar')
group('bar descriptor resolver', () => {
  const barBoot = { _resolveDescriptor(id) { return id }, _unitReady() {}, _unitTeardown() {} }
  const barDescriptor = A.descriptor(barRow, barBoot)
  eq('adapter dispatches bar through _resolveDescriptor', barDescriptor.resolver(), 'bar')
  match('bar wrapper source uses _resolveDescriptor(boundId)', String(barDescriptor.resolver), /_resolveDescriptor\(boundId\)/)
  eq('a refused bar mount reaches the gate as false',
    A.descriptor(barRow, { _resolveDescriptor() { return false } }).resolver(), false)
})

// ---------------------------------------------------------------------------
section('identity: alias owners, targets and collisions')
const units = new Set(goldenIds)
const offers = golden.identities.registryOffers
const targets = golden.identities.ipcCatalog.targets
const aliases = golden.identities.bootHelpAliases
const displayNames = new Set([...offers.map(o => o.id), ...targets.map(t => t.id)])
for (const alias of aliases) {
  group(`alias ${alias.owner}`, () => {
    is('owner is a unit id', alias.owner, id => units.has(id))
    is('target is an offered or displayed name', alias.target, name => displayNames.has(name))
    const displayed = offers.filter(o => (aliases.find(a => a.owner === o.id) || { target: o.id }).target === alias.target)
    is('no second displayed row claims this alias target', displayed.length, n => n <= 1)
  })
}
eq('alias targets are unique', new Set(aliases.map(a => a.target)).size, aliases.length)
eq('alias owners are unique', new Set(aliases.map(a => a.owner)).size, aliases.length)
const helpNames = offers.map(o => (aliases.find(a => a.owner === o.id) || { target: o.id }).target)
eq('no help row collides with another', new Set(helpNames).size, helpNames.length)
eq('no alias target collides with an alias owner', aliases.filter(a => aliases.some(b => b.target === a.owner)), [])

section('identity: shortcut word paths resolve by fixed words')
// Each word path is resolved through the target's row signatures. Literal
// words must match exactly; argument/flag objects consume path words. The
// action id is never used as a resolver. The menu fixtures stand in for the
// dynamic Paths.settingsCatalogPath prefix.
function matchesWords(row, rest) {
  function consume(wi, ri) {
    if (wi === row.words.length) return ri === rest.length
    const w = row.words[wi]
    if (typeof w === 'string') return rest[ri] === w && consume(wi + 1, ri + 1)
    if (w && Array.isArray(w.optional)) {
      for (let k = 0; ri + k <= rest.length; k++) if (consume(wi + 1, ri + k)) return true
      return false
    }
    if (w && Array.isArray(w.flags)) {
      for (let k = 0; ri + k <= rest.length; k++) if (consume(wi + 1, ri + k)) return true
      return false
    }
    return ri < rest.length && consume(wi + 1, ri + 1)
  }
  return consume(0, 0)
}
function resolveAction(words, includeHelp = false) {
  const target = C.findTarget(words[0])
  if (!target) return []
  return target.rows
    .filter(r => r.route !== 'injected' && (includeHelp || r.helpOnly !== true)
      && matchesWords(r, words.slice(1)))
    .map(r => r.id)
}
const actions = golden.identities.shortcuts.actions
const fixturePrefix = golden.fixtures.settingsCatalogPath
eq('golden shortcut actions are 21', Object.keys(actions).length, 21)
for (const action of Object.keys(actions).sort()) {
  group(action, () => {
    const words = actions[action]
    is('argv starts with a published target', words[0], word => !!C.findTarget(word))
    const hits = resolveAction(words)
    eq(`${action} resolves through fixed words`, hits.length, 1)
    if (action === 'menu.main' || action === 'menu.utilities') {
      contains('menu argv uses the fixture prefix', words[3], fixturePrefix + '#')
      eq(`${action} selects the concrete file row`, hits[0], 'menu.toggle.file')
    }
    if (action === 'screenshots.region' || action === 'screenshots.screen') {
      eq(`${action} selects the capture row`, hits[0], 'screenshots.capture')
    }
  })
}
const menuMain = resolveAction(actions['menu.main'])
const menuToggle = resolveAction(['menu', 'toggle'], true)
eq('menu.main resolves to one row', menuMain, ['menu.toggle.file'])
eq('menu.toggle resolves to the help row', menuToggle, ['menu.toggle'])
ne('menu.main is distinct from menu.toggle', menuMain[0], menuToggle[0])

section('identity: no extra compositor action is admitted')
const routerBlock = ROUTER_QML.slice(ROUTER_QML.indexOf('_shortcutWords: ({'), ROUTER_QML.indexOf('\n  })'))
const routedActions = [...routerBlock.matchAll(/^    "([^"]+)":/gm)].map(m => m[1]).sort()
eq('IpcRouter admits exactly the golden actions', routedActions, Object.keys(actions).sort())
contains('invokeShortcut checks own properties only', ROUTER_QML,
  'Object.prototype.hasOwnProperty.call(root._shortcutWords, action)')
contains('menu paths use the dynamic settings prefix', routerBlock, 'Paths.settingsCatalogPath + "#main"')
contains('the second menu path uses the same prefix', routerBlock, 'Paths.settingsCatalogPath + "#utilities"')

section('golden identity fixtures are internally complete')
eq('milestone names', golden.identities.milestones.milestones, ['construction', 'played', 'settled'])
eq('played participants', golden.identities.milestones.playedParticipants, ['bar', 'wallpaper'])
is('every offer has a published or display title', golden.identities.registryOffers,
  list => list.every(o => typeof o.title === 'string' && o.title !== ''))
is('every recorded verb has a fixed-word signature', golden.identities.ipcCatalog.verbs,
  list => list.every(v => Array.isArray(v.words) && v.words.every(w => typeof w === 'string')))

finish()

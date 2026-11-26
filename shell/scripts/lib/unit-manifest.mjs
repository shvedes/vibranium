// Pure declaration grammar, validation, chain insertion, digest, emission and
// authored-handler extraction for self-registering units.
//
// This module performs no filesystem or process access. The CLI in
// shell/scripts/gen-units.mjs owns qmldir discovery, path resolution, staging
// and publication; Node suites import these functions directly.
//
// Declarations form one linear chain anchored at the virtual `__head__`
// sentinel. The sentinel is never a row or an owner, may have only one child,
// and never enters the catalog, digest or golden projections. The optional
// `ref` and `hooks` fields are implementation hints only: they are stripped
// from every data projection as well.

import path from 'node:path'

export const PROVIDERS = Object.freeze(['floor', 'services', 'features', 'bar', 'demand'])

export const DECLARATION_FIELDS = Object.freeze([
  'id', 'after', 'provider', 'phase', 'activation', 'criticality',
  'dependencies', 'retry', 'hasReady', 'hasTeardown', 'ref', 'hooks'
])

export const HEAD = Object.freeze('__head__')

const REQUIRED_FIELDS = Object.freeze(DECLARATION_FIELDS.filter((field) => field !== 'ref' && field !== 'hooks'))
const PHASES = new Set(['floor', 'visual', 'entrance', 'early', 'deferred', 'first_use', 'on_demand'])
const ACTIVATIONS = new Set(['eager', 'resident', 'facade', 'first_use', 'gated_compat'])
const CRITICALITIES = new Set(['essential', 'optional'])
const RETRY_FIELDS = new Set(['maxAttempts', 'backoffMs', 'maxBackoffMs'])
const MEMBER_NAMES = new Set(['resolve', 'ready', 'teardown'])
const ID_RE = /^[A-Za-z][A-Za-z0-9]*$/
// A QML member expression, never a statement: at least one dot, no calls,
// literals or operators. e.g. Paths.home, Services.Timer.tag, Common.AppState.tag.
const REF_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/
// A repo-relative path to a local *.qml file; '..' segments are refused.
const HOOK_RE = /^(?:[A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+\.qml$/

function fail(message) {
  throw new Error(message)
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value, allowed, label, required = allowed) {
  const keys = Object.keys(value)
  for (const key of keys) if (!allowed.has(key)) fail(`${label}: unexpected field ${JSON.stringify(key)}`)
  for (const key of required) if (!Object.prototype.hasOwnProperty.call(value, key)) fail(`${label}: missing field ${JSON.stringify(key)}`)
}

function nonNegativeInt(value) {
  return Number.isSafeInteger(value) && value >= 0
}

function byPath(a, b) {
  return a < b ? -1 : a > b ? 1 : 0
}

// Validate one data-only declaration and return its canonical field order.
// `source` is supplied by the CLI and is not part of the declaration grammar.
export function validateDeclaration(raw, source = '<declaration>') {
  if (!isPlainObject(raw)) fail(`${source}: declaration must be a JSON object`)
  exactKeys(raw, new Set(DECLARATION_FIELDS), source, REQUIRED_FIELDS)

  if (typeof raw.id !== 'string' || !ID_RE.test(raw.id)) fail(`${source}: invalid id`)
  if (raw.id === HEAD) fail(`${source}: ${HEAD} is a sentinel, not a declaration id`)
  if (typeof raw.after !== 'string' || (!ID_RE.test(raw.after) && raw.after !== HEAD)) {
    fail(`${source}: invalid anchor after`)
  }
  if (raw.after === raw.id) fail(`${source}: id ${raw.id} cannot anchor to itself`)
  if (!PROVIDERS.includes(raw.provider)) fail(`${source}: invalid provider ${JSON.stringify(raw.provider)}`)
  if (!PHASES.has(raw.phase)) fail(`${source}: invalid phase ${JSON.stringify(raw.phase)}`)
  if (!ACTIVATIONS.has(raw.activation)) fail(`${source}: invalid activation ${JSON.stringify(raw.activation)}`)
  if (!CRITICALITIES.has(raw.criticality)) fail(`${source}: invalid criticality ${JSON.stringify(raw.criticality)}`)
  if (typeof raw.hasReady !== 'boolean' || typeof raw.hasTeardown !== 'boolean') {
    fail(`${source}: hasReady and hasTeardown must be booleans`)
  }
  if (!Array.isArray(raw.dependencies)) fail(`${source}: dependencies must be an array`)
  raw.dependencies.forEach((dep, at) => {
    if (typeof dep !== 'string' || !ID_RE.test(dep)) fail(`${source}: invalid dependency at ${at}`)
    if (dep === raw.id) fail(`${source}: ${raw.id} cannot depend on itself`)
    if (raw.dependencies.indexOf(dep) !== at) fail(`${source}: duplicate dependency ${dep}`)
  })
  if (!isPlainObject(raw.retry)) fail(`${source}: retry must be an object`)
  exactKeys(raw.retry, RETRY_FIELDS, `${source}: retry`)
  for (const field of RETRY_FIELDS) {
    if (!nonNegativeInt(raw.retry[field])) fail(`${source}: retry.${field} must be a non-negative integer`)
  }
  if (Object.prototype.hasOwnProperty.call(raw, 'ref')) {
    if (typeof raw.ref !== 'string' || !REF_RE.test(raw.ref)) fail(`${source}: invalid ref ${JSON.stringify(raw.ref)}`)
  }
  if (Object.prototype.hasOwnProperty.call(raw, 'hooks')) {
    if (typeof raw.hooks !== 'string' || !HOOK_RE.test(raw.hooks) || raw.hooks.includes('..')) {
      fail(`${source}: invalid hooks path ${JSON.stringify(raw.hooks)}`)
    }
    const declDir = source.includes('/') ? source.slice(0, source.lastIndexOf('/')) : ''
    const hookDir = raw.hooks.includes('/') ? raw.hooks.slice(0, raw.hooks.lastIndexOf('/')) : ''
    if (hookDir !== declDir) fail(`${source}: hooks path must be next to the declaration`)
  }

  const out = {
    id: raw.id,
    provider: raw.provider,
    phase: raw.phase,
    activation: raw.activation,
    criticality: raw.criticality,
    dependencies: raw.dependencies.slice(),
    retry: {
      maxAttempts: raw.retry.maxAttempts,
      backoffMs: raw.retry.backoffMs,
      maxBackoffMs: raw.retry.maxBackoffMs
    },
    hasReady: raw.hasReady,
    hasTeardown: raw.hasTeardown,
    after: raw.after,
    source
  }
  if (Object.prototype.hasOwnProperty.call(raw, 'ref')) out.ref = raw.ref
  if (Object.prototype.hasOwnProperty.call(raw, 'hooks')) out.hooks = raw.hooks
  return out
}

function projectRow(decl) {
  const out = {
    id: decl.id,
    provider: decl.provider,
    phase: decl.phase,
    activation: decl.activation,
    criticality: decl.criticality,
    dependencies: decl.dependencies.slice(),
    retry: {
      maxAttempts: decl.retry.maxAttempts,
      backoffMs: decl.retry.backoffMs,
      maxBackoffMs: decl.retry.maxBackoffMs
    },
    hasReady: decl.hasReady,
    hasTeardown: decl.hasTeardown,
    source: decl.source
  }
  if (Object.prototype.hasOwnProperty.call(decl, 'ref')) out.ref = decl.ref
  if (Object.prototype.hasOwnProperty.call(decl, 'hooks')) out.hooks = decl.hooks
  return out
}

// Return the effective rows in exact declaration order. There is no seed:
// every row is placed by its anchor, and __head__ inserts at index zero.
// Duplicate anchor children make the chain linear, so the walk is unambiguous.
export function insertDeclarations(declarations) {
  if (!Array.isArray(declarations)) fail('declarations must be an array')

  const owners = new Map()
  declarations.forEach((decl, at) => {
    if (!isPlainObject(decl) || typeof decl.id !== 'string' || typeof decl.after !== 'string') {
      fail(`declaration ${at}: invalid declaration`)
    }
    if (decl.id === HEAD) fail(`${HEAD} is a sentinel, not a declaration`)
    if (owners.has(decl.id)) fail(`duplicate id ${decl.id} (${owners.get(decl.id)}, ${decl.source})`)
    owners.set(decl.id, decl.source)
  })

  const children = new Map()
  for (const decl of declarations) {
    if (decl.after !== HEAD && !owners.has(decl.after)) fail(`${decl.source}: missing anchor ${decl.after}`)
    if (children.has(decl.after)) {
      fail(`${decl.source}: duplicate anchor child for ${decl.after} (also ${children.get(decl.after)})`)
    }
    children.set(decl.after, decl.source)
  }

  // Anchor chains among declarations are legal; cycles are not.
  for (const decl of declarations) {
    const seen = new Set([decl.id])
    let cursor = decl
    while (cursor.after !== HEAD && owners.has(cursor.after)) {
      cursor = declarations.find((d) => d.id === cursor.after)
      if (seen.has(cursor.id)) fail(`cyclic anchor at ${cursor.id} (from ${decl.source})`)
      seen.add(cursor.id)
    }
  }

  const rows = []
  const pending = declarations.slice()
  let cursor = HEAD
  while (pending.length) {
    const at = pending.findIndex((decl) => decl.after === cursor)
    if (at < 0) {
      fail(`unreachable declarations: ${pending.map((d) => `${d.id} after ${d.after}`).join(', ')}`)
    }
    const decl = pending[at]
    rows.push(projectRow(decl))
    pending.splice(at, 1)
    cursor = decl.id
  }

  const positions = new Map(rows.map((row, at) => [row.id, at]))
  for (let at = 0; at < rows.length; at++) {
    const row = rows[at]
    if (!isPlainObject(row.retry)) fail(`${row.id}: missing retry record`)
    for (const dep of row.dependencies) {
      if (!positions.has(dep)) fail(`${row.id}: missing dependency ${dep}`)
      if (positions.get(dep) >= at) fail(`${row.id}: dependency ${dep} is declared at or after its dependent`)
    }
  }
  return rows
}

// Canonical JSON: object keys sorted recursively, arrays kept in order.
export function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']'
  const keys = Object.keys(value).sort()
  return '{' + keys.map((key) => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}'
}

// FNV-1a, 32-bit, fixed eight-digit lowercase hex (as in Units.catalog.js).
export function fnv1a(text) {
  let hash = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash.toString(16).padStart(8, '0')
}

// The same effective descriptor projection as Units.catalog.js digest().
// after/ref/hooks/source are implementation hints and are not projected.
export function effectiveRows(rows) {
  return rows.map((row) => ({
    id: row.id,
    provider: row.provider,
    phase: row.phase,
    activation: row.activation,
    criticality: row.criticality,
    dependencies: row.dependencies.slice(),
    retry: {
      maxAttempts: row.retry.maxAttempts,
      backoffMs: row.retry.backoffMs,
      maxBackoffMs: row.retry.maxBackoffMs
    },
    hasReady: row.hasReady === true,
    hasTeardown: row.hasTeardown === true
  }))
}

export function effectiveDigest(rows) {
  return fnv1a(canonical(effectiveRows(rows)))
}

// Golden comparison: same array order, provider projected as owner. The
// projection is built from effectiveRows so no implementation hint leaks in.
export function compareGolden(rows, golden, digest = effectiveDigest(rows)) {
  if (!isPlainObject(golden) || !Array.isArray(golden.units)) fail('golden: missing units array')
  const projected = effectiveRows(rows).map((row) => {
    const out = {}
    for (const key of Object.keys(row)) out[key === 'provider' ? 'owner' : key] = row[key]
    return out
  })
  if (canonical(projected) !== canonical(golden.units)) {
    let at = 0
    while (at < Math.min(projected.length, golden.units.length) &&
           canonical(projected[at]) === canonical(golden.units[at])) at++
    fail(`golden mismatch at unit ${at}: ` +
      `${projected[at] ? projected[at].id : '<none>'} vs ` +
      `${golden.units[at] ? golden.units[at].id : '<none>'} ` +
      `(${projected.length} candidate rows, ${golden.units.length} golden rows)`)
  }
  if (digest !== golden.unitsDigest) fail(`digest mismatch: candidate ${digest}, golden ${golden.unitsDigest}`)
}

const CATALOG_HEADER = `.pragma library

// Phase 3 ordered catalog: data-only port of Boot.qml's pre-extraction
// \`readonly property var _catalog\` literal (52 rows, declaration order).
// \`provider\` is derived from the pre-extraction resolver site of each id:
//   floor    -> Boot.qml _resolveDescriptor cases (including wallpaper)
//   demand   -> Boot.qml demand-driven annotation loader (annotations)
//   bar      -> Boot.qml _mountBarRuntime (bar)
//   services -> BootServices.qml resolve(id) cases
//   features -> BootLate.qml resolve(id) cases
// hasReady/hasTeardown record whether the old literal declared a function
// for that member; absence changes UnitGate semantics and must survive.
// No closures, no provider imports, no log prose, no durations, no clock.

`

const CATALOG_HELPERS = `// Pure helpers: no validation, no side effects, no wall clock, no environment.
function rows() { return catalog }

function byId(id) {
  for (var i = 0; i < catalog.length; i++) {
    if (catalog[i].id === id) return catalog[i]
  }
  return null
}

// Canonical JSON: object keys sorted recursively, arrays kept in declared
// order, so the digest is independent of object key insertion order.
function _canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value)
  if (Array.isArray(value)) {
    var parts = []
    for (var i = 0; i < value.length; i++) parts.push(_canonical(value[i]))
    return "[" + parts.join(",") + "]"
  }
  var keys = []
  for (var key in value) {
    if (Object.prototype.hasOwnProperty.call(value, key)) keys.push(key)
  }
  keys.sort()
  var fields = []
  for (var j = 0; j < keys.length; j++) {
    fields.push(JSON.stringify(keys[j]) + ":" + _canonical(value[keys[j]]))
  }
  return "{" + fields.join(",") + "}"
}

// FNV-1a, 32-bit, fixed eight-digit lowercase hex.
function _fnv1a(text) {
  var hash = 0x811c9dc5
  for (var i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  var hex = hash.toString(16)
  while (hex.length < 8) hex = "0" + hex
  return hex
}

// Digest over the ordered effective descriptors: all data fields, the full
// retry record, the declared dependency order and the presence flags.
function digest() {
  var effective = []
  for (var i = 0; i < catalog.length; i++) {
    var row = catalog[i]
    effective.push({
      id: row.id,
      provider: row.provider,
      phase: row.phase,
      activation: row.activation,
      criticality: row.criticality,
      dependencies: row.dependencies.slice(),
      retry: {
        maxAttempts: row.retry.maxAttempts,
        backoffMs: row.retry.backoffMs,
        maxBackoffMs: row.retry.maxBackoffMs
      },
      hasReady: row.hasReady === true,
      hasTeardown: row.hasTeardown === true
    })
  }
  return _fnv1a(_canonical(effective))
}
`

function emitCatalogRow(row) {
  const deps = row.dependencies.map((dep) => JSON.stringify(dep)).join(', ')
  return [
    '  {',
    `    id: ${JSON.stringify(row.id)},`,
    `    provider: ${JSON.stringify(row.provider)},`,
    `    phase: ${JSON.stringify(row.phase)},`,
    `    activation: ${JSON.stringify(row.activation)},`,
    `    criticality: ${JSON.stringify(row.criticality)},`,
    `    dependencies: [${deps}],`,
    `    retry: { maxAttempts: ${row.retry.maxAttempts}, backoffMs: ${row.retry.backoffMs}, maxBackoffMs: ${row.retry.maxBackoffMs} },`,
    `    hasReady: ${row.hasReady === true},`,
    `    hasTeardown: ${row.hasTeardown === true}`,
    '  }'
  ].join('\n')
}

export function emitCatalog(rows) {
  return CATALOG_HEADER + 'var catalog = [\n' +
    rows.map(emitCatalogRow).join(',\n') + '\n]\n\n' + CATALOG_HELPERS
}

// --- generated handler types ------------------------------------------------
// One inert QtObject per provider. Nothing is resolved at construction: a
// mechanical resolve only reads a member, and authored hooks are functions.
// Hook objects are created by an `_ensure<Id>Hooks()` function on first handler
// use, never by a property initializer: a URL component load at Boot module
// construction would be a new eager load edge even when no hook method runs.
// The provider qualifier for mechanical refs is data, not an id table:
// services uses `Services.<Type>`, every other provider uses `<Type>`.

const OUTPUTS = Object.freeze({
  floor: Object.freeze({ rel: 'shell/boot/generated/floor/FloorHandlers.qml', qualifier: null }),
  services: Object.freeze({ rel: 'shell/boot/generated/services/ServicesHandlers.qml', qualifier: 'Services' }),
  features: Object.freeze({ rel: 'shell/boot/generated/features/FeaturesHandlers.qml', qualifier: null }),
  bar: Object.freeze({ rel: 'shell/boot/generated/bar/BarHandlers.qml', qualifier: null }),
  demand: Object.freeze({ rel: 'shell/boot/generated/demand/DemandHandlers.qml', qualifier: null })
})

const CATALOG_REL = 'shell/boot/Units.catalog.js'

export function outputPaths() {
  return [CATALOG_REL, ...Object.values(OUTPUTS).map((out) => out.rel)].sort(byPath)
}

export function handlersPath(provider) {
  if (!OUTPUTS[provider]) fail(`invalid provider ${JSON.stringify(provider)}`)
  return OUTPUTS[provider].rel
}

function typeName(id) {
  return id[0].toUpperCase() + id.slice(1)
}

function moduleNames(types, name) {
  const found = types[name]
  return found === undefined ? [] : Array.isArray(found) ? found : [found]
}

// Prefer the real QML singleton name from qmldir over the capitalized id:
// authored ids and type names need not match (osd -> OSD, app -> AppHost).
// Order of preference: exact type, case-insensitive unique type in the
// declaration's own module, declaration filename, then capitalized id.
function resolveTypeName(decl, moduleIndex) {
  const fallback = typeName(decl.id)
  const types = moduleIndex.types || {}
  if (Object.prototype.hasOwnProperty.call(types, fallback)) return fallback
  const candidates = (moduleIndex.typesByLower || {})[decl.id.toLowerCase()] || []
  const own = (moduleIndex.sources || {})[decl.source]
  let chosen = candidates.filter((name) => !own || moduleNames(types, name).includes(own))
  if (!chosen.length) chosen = candidates
  if (chosen.length === 1) return chosen[0]
  const base = path.posix.basename(decl.source || '').replace(/\.unit\.json$/, '')
  if (base && Object.prototype.hasOwnProperty.call(types, base)) return base
  if (chosen.length > 1) fail(`${decl.source}: ambiguous QML type for ${decl.id}: ${chosen.join(', ')}`)
  return fallback
}

function mechanicalBase(provider, decl, moduleIndex) {
  const type = resolveTypeName(decl, moduleIndex)
  const qualifier = OUTPUTS[provider].qualifier
  return qualifier ? `${qualifier}.${type}` : type
}

function memberBase(ref) {
  return ref.slice(0, ref.lastIndexOf('.'))
}

// moduleIndex is produced by the CLI from qmldir files:
//   sources[decl.source] -> module of the nearest qmldir above the declaration
//   types[TypeName]      -> module (or array of modules) declaring that type
//   aliases[Alias]       -> module whose last path segment matches the alias
// Types take precedence over aliases: `Wallpaper.enabled` is an unqualified
// import of qs.features.wallpaper, while `Common.AppState.tag` needs the
// alias import of qs.common.
function importForRoot(root, decl, moduleIndex) {
  const types = moduleIndex.types || {}
  const aliases = moduleIndex.aliases || {}
  const sources = moduleIndex.sources || {}
  if (Object.prototype.hasOwnProperty.call(types, root)) {
    const found = types[root]
    if (Array.isArray(found)) fail(`${decl.source}: ambiguous QML type ${root} in modules ${found.join(', ')}`)
    return { module: found, alias: '' }
  }
  if (Object.prototype.hasOwnProperty.call(aliases, root)) return { module: aliases[root], alias: root }
  if (Object.prototype.hasOwnProperty.call(sources, decl.source)) return { module: sources[decl.source], alias: '' }
  fail(`${decl.source}: cannot resolve QML module for ref root ${root}`)
}

// Authored hooks may override only some members. A member the hook does not
// provide keeps the mechanical/ref-based expression, and that expression's
// module must be imported. With no hook scan (direct suite calls) a hook file
// is assumed to provide every member.
function hookMembers(decl, moduleIndex) {
  if (!decl.hooks) return null
  const hooks = moduleIndex.hooks || {}
  if (!Object.prototype.hasOwnProperty.call(hooks, decl.hooks)) {
    return new Set(['resolve', 'ready', 'teardown'])
  }
  return new Set(hooks[decl.hooks])
}

function usesMechanical(decl, member, members) {
  if (member === 'ready' && !decl.hasReady) return false
  if (member === 'teardown' && !decl.hasTeardown) return false
  return !members || !members.has(member)
}

function emitImports(rows, moduleIndex) {
  const types = moduleIndex.types || {}
  const aliases = moduleIndex.aliases || {}
  const sources = moduleIndex.sources || {}
  const haveIndex = Object.keys(types).length + Object.keys(aliases).length + Object.keys(sources).length > 0
  const imports = new Map()
  for (const decl of rows) {
    const members = hookMembers(decl, moduleIndex)
    if (!usesMechanical(decl, 'resolve', members) &&
        !usesMechanical(decl, 'ready', members) &&
        !usesMechanical(decl, 'teardown', members)) continue
    const ref = decl.ref || `${mechanicalBase(decl.provider, decl, moduleIndex)}.tag`
    const root = ref.slice(0, ref.indexOf('.'))
    if (!haveIndex) continue
    const found = importForRoot(root, decl, moduleIndex)
    imports.set(`${found.module}\u0000${found.alias}`, found)
  }
  return [...imports.values()].sort((a, b) => byPath(a.module, b.module) || byPath(a.alias, b.alias))
}

// Quickshell maps a loaded config to a qs: URL scheme. Under that scheme a
// single-file QML import with `..` segments is resolved as a directory
// (`<Stem> is not a type` / `Namespace ... cannot be used as a type`), and the
// namespace has no usable `create()`. Qt.createComponent with the same
// relative path does resolve and construct the authored hook, so hooks are
// instantiated that way instead of by a static import. The call lives inside a
// generated function body, reached only from a handler closure; construction
// alone performs no component load. The file stem is still derived from the
// basename and checked for uniqueness; hook bodies are functions and never run
// at construction.
function hookStem(hooks) {
  const base = path.posix.basename(hooks)
  if (!base.endsWith('.qml')) fail(`invalid hook file ${JSON.stringify(hooks)}`)
  return base.slice(0, -'.qml'.length)
}

function emitHookImports(rows, output) {
  const out = new Map()
  const stemOwners = new Map()
  const outputDir = path.posix.dirname(output.rel)
  for (const decl of rows) {
    if (!decl.hooks) continue
    const stem = hookStem(decl.hooks)
    if (stemOwners.has(stem)) fail(`${decl.source}: duplicate hook type ${stem} (also ${stemOwners.get(stem)})`)
    stemOwners.set(stem, decl.source)
    const rel = path.posix.relative(outputDir, decl.hooks)
    out.set(stem, { rel, stem })
  }
  return [...out.values()].sort((a, b) => byPath(a.rel, b.rel))
}

export function emitHandlers(provider, declarations, moduleIndex = {}) {
  const output = OUTPUTS[provider]
  if (!output) fail(`invalid provider ${JSON.stringify(provider)}`)
  if (!Array.isArray(declarations)) fail('declarations must be an array')
  const rows = declarations.filter((decl) => decl.provider === provider)

  const lines = ['import QtQml']
  for (const found of emitImports(rows, moduleIndex)) {
    lines.push(found.alias ? `import ${found.module} as ${found.alias}` : `import ${found.module}`)
  }
  // Validates unique hook file stems; no static hook import is emitted.
  const hookImports = emitHookImports(rows, output)
  lines.push(
    '',
    '// Generated by shell/scripts/gen-units.mjs from *.unit.json; do not edit.',
    'QtObject {',
    '  id: root',
    '  property var boot: null'
  )
  // A null initializer is inert: the object itself is created by the ensure
  // function below, only when a handler closure is first invoked.
  for (const decl of rows) {
    if (decl.hooks) lines.push(`  property var ${decl.id}Hooks: null`)
  }
  lines.push('  readonly property var handlers: ({')
  rows.forEach((decl, at) => {
    const hookSet = hookMembers(decl, moduleIndex)
    const ref = decl.ref || `${mechanicalBase(provider, decl, moduleIndex)}.tag`
    const base = memberBase(ref)
    // Keep the established `root.<id>Hooks.<member>()` call in every closure;
    // the ensure call in front of it only moves component creation out of the
    // constructor and onto first handler use.
    const ensure = `root._ensure${typeName(decl.id)}Hooks(); `
    const hooks = `root.${decl.id}Hooks`
    const members = []
    if (usesMechanical(decl, 'resolve', hookSet)) members.push(`      resolve: function() { void ${ref} }`)
    else members.push(`      resolve: function() { ${ensure}return ${hooks}.resolve() }`)
    if (decl.hasReady) {
      if (usesMechanical(decl, 'ready', hookSet)) members.push(`      ready: function() { return ${base}.facadeReady === true }`)
      else members.push(`      ready: function() { ${ensure}return ${hooks}.ready() }`)
    }
    if (decl.hasTeardown) {
      if (usesMechanical(decl, 'teardown', hookSet)) members.push(`      teardown: function() { ${base}.teardownController() }`)
      else members.push(`      teardown: function() { ${ensure}${hooks}.teardown() }`)
    }
    lines.push(`    ${JSON.stringify(decl.id)}: {`)
    lines.push(members.join(',\n'))
    lines.push('    }' + (at < rows.length - 1 ? ',' : ''))
  })
  lines.push('  })')
  // URL component creation is confined to a function body. `root.boot` is
  // read at first use instead of at construction, so the hook sees the Boot
  // object the owning provider assigned to the generated type.
  const byStem = new Map(hookImports.map((hook) => [hook.stem, hook.rel]))
  for (const decl of rows) {
    if (!decl.hooks) continue
    const rel = byStem.get(hookStem(decl.hooks))
    const fn = `_ensure${typeName(decl.id)}Hooks`
    lines.push(
      '',
      `  function ${fn}() {`,
      `    if (root.${decl.id}Hooks === null) {`,
      `      root.${decl.id}Hooks = Qt.createComponent("${rel}").createObject(root, { boot: root.boot })`,
      '    }',
      `    return root.${decl.id}Hooks`,
      '  }'
    )
  }
  lines.push('}')
  return lines.join('\n') + '\n'
}

// --- narrow authored handler extractor -------------------------------------
// Retained as a pure export for suites only. Production generation no longer
// reads authored `handlers` literals: all ownership comes from declarations.

function triviaAt(src, i, label) {
  for (;;) {
    while (i < src.length && /\s/.test(src[i])) i++
    if (src.startsWith('//', i)) {
      const end = src.indexOf('\n', i + 2)
      i = end < 0 ? src.length : end + 1
      continue
    }
    if (src.startsWith('/*', i)) {
      const end = src.indexOf('*/', i + 2)
      if (end < 0) fail(`${label}: unterminated block comment`)
      i = end + 2
      continue
    }
    return i
  }
}

function quotedEnd(src, i, label) {
  const quote = src[i]
  i++
  while (i < src.length) {
    if (src[i] === '\\') { i += 2; continue }
    if (src[i] === quote) return i + 1
    if (quote === '`' && src.startsWith('${', i)) {
      i = balancedEnd(src, i + 1, '{', '}', label) - 1
    }
    i++
  }
  fail(`${label}: unterminated string`)
}

function balancedEnd(src, i, open, close, label) {
  if (src[i] !== open) fail(`${label}: expected ${open}`)
  let depth = 0
  while (i < src.length) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') { i = quotedEnd(src, i, label); continue }
    if (src.startsWith('//', i)) { i = triviaAt(src, i, label); continue }
    if (src.startsWith('/*', i)) { i = triviaAt(src, i, label); continue }
    if (c === open) depth++
    else if (c === close) {
      depth--
      if (depth === 0) return i + 1
    }
    i++
  }
  fail(`${label}: unbalanced ${open}${close}`)
}

function isWordChar(c) {
  return !!c && /[A-Za-z0-9_$]/.test(c)
}

export function extractAuthoredHandlers(source, label = '<authored handlers>') {
  if (typeof source !== 'string') fail(`${label}: source must be a string`)
  const marker = /^[ \t]*(?:readonly[ \t]+)?property[ \t]+var[ \t]+handlers[ \t]*:[ \t]*\([ \t]*\{/gm
  const found = [...source.matchAll(marker)]
  if (found.length !== 1) fail(`${label}: expected exactly one handlers literal, found ${found.length}`)
  const at = () => triviaAt(source, i, label)
  let i = found[0].index + found[0][0].length
  const result = {}

  function readName() {
    const start = at()
    const match = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(source.slice(start))
    if (!match) fail(`${label}: expected member name at offset ${start}`)
    i = start + match[0].length
    return match[0]
  }

  function readString() {
    const start = at()
    if (source[start] !== '"' && source[start] !== "'") fail(`${label}: expected string row key at offset ${start}`)
    const end = quotedEnd(source, start, label)
    const text = source.slice(start + 1, end - 1)
    if (text.includes('\\')) fail(`${label}: escaped row keys are not supported`)
    i = end
    return text
  }

  function readValue() {
    const start = at()
    if (source.startsWith('null', start) && !isWordChar(source[start + 4])) {
      i = start + 4
      if (',}'.includes(source[at()])) return false
      fail(`${label}: null must be followed by a row delimiter`)
    }
    const fn = /^function(?![A-Za-z0-9_$])/.exec(source.slice(start))
    if (fn) {
      i = start + fn[0].length
      i = at()
      if (source[i] === '*') fail(`${label}: generator functions are not supported`)
      // Optional function name before the parameter list; readName advances i.
      if (/^[A-Za-z_$]/.test(source[i] || '')) readName()
      i = triviaAt(source, i, label)
      i = balancedEnd(source, i, '(', ')', label)
      i = triviaAt(source, i, label)
      i = balancedEnd(source, i, '{', '}', label)
      if (',}'.includes(source[at()])) return true
      fail(`${label}: function member must be followed by a row delimiter`)
    }
    fail(`${label}: unsupported member value at offset ${start}`)
  }

  for (;;) {
    i = at()
    if (source[i] === '}') { i++; break }
    const id = readString()
    if (Object.prototype.hasOwnProperty.call(result, id)) fail(`${label}: duplicate row key ${id}`)
    i = triviaAt(source, i, label)
    if (source[i] !== ':') fail(`${label}: expected ':' after row key ${id}`)
    i++
    i = triviaAt(source, i, label)
    if (source[i] !== '{') fail(`${label}: row ${id} must be an object literal`)
    i++
    const members = {}
    for (;;) {
      i = at()
      if (source[i] === '}') { i++; break }
      const name = readName()
      if (!MEMBER_NAMES.has(name)) fail(`${label}: row ${id} has unsupported member ${name}`)
      if (Object.prototype.hasOwnProperty.call(members, name)) fail(`${label}: duplicate member ${name} in row ${id}`)
      i = triviaAt(source, i, label)
      if (source[i] !== ':') fail(`${label}: expected ':' after ${id}.${name}`)
      i++
      members[name] = readValue()
      i = at()
      if (source[i] === ',') {
        i++
        i = at()
        if (source[i] === '}') { i++; break }
        continue
      }
      if (source[i] === '}') { i++; break }
      fail(`${label}: malformed row ${id} after ${name}`)
    }
    if (members.resolve !== true) fail(`${label}: row ${id} has no supported resolve function`)
    result[id] = { resolve: true, ready: members.ready === true, teardown: members.teardown === true }
    i = at()
    if (source[i] === ',') {
      i++
      i = at()
      if (source[i] === '}') { i++; break }
      continue
    }
    if (source[i] === '}') { i++; break }
    fail(`${label}: malformed entry after row ${id}`)
  }
  i = at()
  if (source[i] !== ')') fail(`${label}: handlers literal must end with '})'`)
  return result
}

// Short alias for suites that import the extractor under a generic name.
export const extractHandlers = extractAuthoredHandlers

export function authoredIds(authored) {
  return Object.keys(authored)
}

// Pure ownership check retained for suites; the generator never calls it.
export function assertDisjointOwnership(authored, declarations) {
  for (const decl of declarations) {
    if (Object.prototype.hasOwnProperty.call(authored, decl.id)) {
      fail(`duplicate ownership for ${decl.id}: authored and generated`)
    }
  }
  const seen = new Set()
  for (const [id, owners] of Object.entries(authored)) {
    if (seen.has(id)) fail(`duplicate authored ownership for ${id}`)
    seen.add(id)
    if (!isPlainObject(owners) || owners.resolve !== true) fail(`authored row ${id} has no resolve function`)
  }
}

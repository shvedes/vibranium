#!/usr/bin/env node
// Explicit golden generator / candidate comparator for the Phase 3 catalog.
//
// This file is NOT a test suite (it lives under bench/, outside suites/). It
// has two jobs:
//
//   --write-golden       build the versioned structural golden ONCE from the
//                        pre-extraction catalog in `git HEAD:shell/boot/Boot.qml`
//                        plus the published identity fixtures, and write it.
//   --candidate <path>   snapshot the installed Units.catalog.js (and the same
//                        identity sources) to an explicit destination, print a
//                        line diff against the golden, and fail on a stale
//                        golden or a removed record.
//
// With neither flag the candidate is built in memory and compared, so the
// comparison can be used as a gate without leaving a file behind.
//
// Deliberately absent: durations, timings, profile data, log prose, source
// locations and callback bodies. Only structure, published identity and the
// ordered catalog are pinned.
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { loadLib } from '../lib/qmlloader.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..', '..')
const SHELL = path.join(ROOT, 'shell')
const GOLDEN_PATH = path.join(ROOT, 'tests', 'shell', 'fixtures', 'unit-catalog', 'golden.json')
const CATALOG_JS = path.join(SHELL, 'boot', 'Units.catalog.js')
const BOOT_QML = path.join(SHELL, 'boot', 'Boot.qml')
const BOOTSERVICES_QML = path.join(SHELL, 'boot', 'BootServices.qml')
const BOOTLATE_QML = path.join(SHELL, 'boot', 'BootLate.qml')
const IPC_CATALOG_JS = path.join(SHELL, 'common', 'text', 'IpcCatalog.js')
const IPC_ROUTER_QML = path.join(SHELL, 'common', 'bus', 'IpcRouter.qml')
const DESKTOP_STATE_QML = path.join(SHELL, 'common', 'state', 'DesktopLayoutState.qml')

// A fixed fixture prefix stands in for Paths.settingsCatalogPath: no machine
// path or user config is ever recorded in the golden.
const PREFIX_TOKEN = '__FIXTURE_PREFIX__'
const FIXTURE_PREFIX = '/fixture/vibranium/menu.jsonc'

function usage(rc = 0) {
  const text = `Usage: node tests/shell/bench/unit-catalog-golden.mjs [options]

  --write-golden         rebuild ${path.relative(ROOT, GOLDEN_PATH)} from HEAD
  --candidate <path>     write a candidate snapshot to <path>, then diff
  --check                (default) build a candidate in memory and diff
  --no-diff              suppress the line diff (still fails on a mismatch)
  -h, --help             this text
`
  process.stdout.write(text)
  process.exit(rc)
}

const argv = process.argv.slice(2)
let writeGolden = false
let candidatePath = null
let wantDiff = true
for (let i = 0; i < argv.length; i++) {
  switch (argv[i]) {
    case '--write-golden': writeGolden = true; break
    case '--candidate': candidatePath = argv[++i]; if (!candidatePath) usage(2); break
    case '--check': break
    case '--no-diff': wantDiff = false; break
    case '-h': case '--help': usage(0); break
    default: process.stderr.write(`unknown option: ${argv[i]}\n`); usage(2)
  }
}

// --- canonical form -------------------------------------------------------
// Object keys are sorted recursively. Arrays that are unordered sets are
// sorted where they are built; declared order (units, dependencies, argv) is
// never reordered.
function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value && typeof value === 'object') {
    const out = {}
    for (const key of Object.keys(value).sort()) out[key] = sortKeys(value[key])
    return out
  }
  return value
}
function byKey(fn) { return (a, b) => { const x = fn(a), y = fn(b); return x < y ? -1 : x > y ? 1 : 0 } }

// FNV-1a over the canonical unit rows, byte-for-byte the algorithm published by
// Units.catalog.js. Kept here independently so the golden's expected digest is
// not sourced from the implementation under test.
function canonicalText(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return '[' + value.map(canonicalText).join(',') + ']'
  const keys = Object.keys(value).sort()
  return '{' + keys.map(k => JSON.stringify(k) + ':' + canonicalText(value[k])).join(',') + '}'
}
function fnv1a(text) {
  let hash = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash.toString(16).padStart(8, '0')
}

// --- source readers -------------------------------------------------------

function headBootQml() {
  return execFileSync('git', ['show', 'HEAD:shell/boot/Boot.qml'], {
    cwd: ROOT, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024
  })
}

// Bracket balance that skips strings and comments, modelled on the
// boot-catalog suite's literal extractor.
function literalAt(src, marker) {
  const at = src.indexOf(marker)
  if (at < 0) throw new Error(`no literal at ${JSON.stringify(marker)}`)
  const from = at + marker.length
  const starts = ['[', '(', '{'].map(c => src.indexOf(c, from)).filter(i => i >= 0)
  if (starts.length === 0) throw new Error(`no opening bracket after ${JSON.stringify(marker)}`)
  const start = Math.min(...starts)
  const openers = { '[': ']', '(': ')', '{': '}' }
  let i = start
  const stack = []
  while (i < src.length) {
    const c = src[i]
    if (c === '"' || c === "'" || c === '`') {
      const quote = c
      i++
      while (i < src.length) {
        if (src[i] === '\\') { i += 2; continue }
        if (src[i] === quote) { i++; break }
        i++
      }
      continue
    }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && src[i + 1] === '*') {
      const close = src.indexOf('*/', i + 2)
      i = close < 0 ? src.length : close + 2
      continue
    }
    if (openers[c]) { stack.push(openers[c]); i++; continue }
    if (stack.length && c === stack[stack.length - 1]) {
      stack.pop()
      if (stack.length === 0) return src.slice(start, i + 1)
    }
    i++
  }
  throw new Error(`unterminated literal at ${JSON.stringify(marker)}`)
}

function evaluate(text, bindings = {}) {
  const names = Object.keys(bindings)
  return new Function(...names, 'return (' + text + ')')(...names.map(n => bindings[n]))
}

function ownerMap() {
  const boot = headBootQml()
  const switchText = boot.slice(boot.indexOf('function _resolveDescriptor(id)'),
    boot.indexOf('return true', boot.indexOf('function _resolveDescriptor(id)')))
  const bootIds = [...switchText.matchAll(/case "([^"]+)":/g)].map(m => m[1])
  const files = [[BOOTSERVICES_QML, 'services'], [BOOTLATE_QML, 'features']]
  const owners = new Map()
  for (const id of bootIds) owners.set(id, id === 'annotations' ? 'demand' : 'floor')
  for (const [file, owner] of files) {
    const src = fs.readFileSync(file, 'utf8')
    const block = src.slice(src.indexOf('property var handlers: ({'), src.indexOf('\n  })'))
    if (!block) throw new Error(`no handlers table in ${path.basename(file)}`)
    for (const m of block.matchAll(/^    "([^"]+)":/gm)) owners.set(m[1], owner)
  }
  owners.set('bar', 'bar')
  return owners
}

function unitRow(row, owners) {
  const id = row.id
  const owner = owners.has(id) ? owners.get(id) : row.provider || row.owner
  if (!owner) throw new Error(`no pre-extraction owner for unit ${id}`)
  return {
    id,
    owner,
    phase: row.phase,
    activation: row.activation,
    criticality: row.criticality,
    dependencies: row.dependencies.slice(),
    retry: {
      maxAttempts: row.retry.maxAttempts,
      backoffMs: row.retry.backoffMs,
      maxBackoffMs: row.retry.maxBackoffMs
    },
    hasReady: row.hasReady === true || typeof row.ready === 'function',
    hasTeardown: row.hasTeardown === true || typeof row.teardown === 'function'
  }
}

function baselineUnits() {
  const src = headBootQml()
  const rows = evaluate(literalAt(src, 'readonly property var _catalog: '))
  const owners = ownerMap()
  return rows.map(row => unitRow(row, owners))
}

function installedUnits() {
  const units = loadLib(CATALOG_JS)
  const rows = typeof units.rows === 'function' ? units.rows() : units.catalog
  if (!Array.isArray(rows)) throw new Error('Units.catalog.js exposes no ordered rows()')
  const owners = ownerMap()
  return rows.map(row => unitRow(row, owners))
}

// --- published identity fixtures ------------------------------------------

function ipcCatalogFixture() {
  const C = loadLib(IPC_CATALOG_JS)
  const byId = new Map()
  const add = (r) => {
    if (!r || byId.has(r.id)) return
    byId.set(r.id, {
      id: r.id,
      route: r.route,
      helpOnly: r.helpOnly === true,
      summary: r.summary,
      words: r.words.filter(w => typeof w === 'string')
    })
  }
  for (const t of C.targets) for (const r of t.rows) add(r)
  for (const r of C.commonRows()) add(r)
  return {
    targets: C.targets.map(t => ({ id: t.id, title: t.title, summary: t.summary }))
      .sort(byKey(t => t.id)),
    verbs: [...byId.values()].sort(byKey(v => v.id))
  }
}

function registryOffers() {
  const src = fs.readFileSync(path.join(SHELL, 'common', 'bus', 'Registry.qml'), 'utf8')
  if (!src.includes('function offer(')) throw new Error('Registry.offer missing')
  const files = []
  const walk = (dir) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name)
      if (ent.isDirectory()) walk(p)
      else if (ent.isFile() && (p.endsWith('.qml') || p.endsWith('.js'))) files.push(p)
    }
  }
  walk(SHELL)
  const C = loadLib(IPC_CATALOG_JS)
  const out = []
  const re = /Registry\.offer\(\s*"([^"]+)"\s*,\s*\{/g
  for (const file of files.sort()) {
    const text = fs.readFileSync(file, 'utf8')
    for (let m = re.exec(text); m; m = re.exec(text)) {
      const id = m[1]
      const block = evaluate(literalAt(text.slice(m.index), 'Registry.offer('),
        { IpcCatalog: C, Catalog: C })
      const title = typeof block.title === 'string' ? block.title : ''
      const description = typeof block.description === 'string' ? block.description : ''
      out.push({ id, title, description, verbNames: C.topLevelVerbs(id).sort() })
    }
  }
  const seen = new Set()
  return out.filter(o => (seen.has(o.id) ? false : (seen.add(o.id), true))).sort(byKey(o => o.id))
}

function shortcutWords() {
  const src = fs.readFileSync(IPC_ROUTER_QML, 'utf8')
  const words = evaluate(literalAt(src, 'readonly property var _shortcutWords:'), {
    Paths: { settingsCatalogPath: FIXTURE_PREFIX }
  })
  const out = {}
  for (const action of Object.keys(words).sort()) {
    out[action] = words[action].slice()
  }
  return { fixturePrefix: FIXTURE_PREFIX, actions: out }
}

function bootHelpAliases() {
  const src = fs.readFileSync(BOOT_QML, 'utf8')
  const at = src.indexOf('const rename = ')
  if (at < 0) throw new Error('Boot help alias table missing')
  const rename = evaluate(literalAt(src.slice(at), 'const rename = '))
  return Object.keys(rename).sort().map(owner => ({ owner, target: rename[owner] }))
}

function milestoneParticipants() {
  const src = fs.readFileSync(DESKTOP_STATE_QML, 'utf8')
  const keys = Object.keys(evaluate(literalAt(src, '_bootPlayLeft: ('))).sort()
  const milestones = new Set()
  for (const file of [DESKTOP_STATE_QML, BOOT_QML]) {
    const text = fs.readFileSync(file, 'utf8')
    for (const m of text.matchAll(/_observeMilestone\(\s*"([^"]+)"/g)) milestones.add(m[1])
  }
  return {
    milestones: [...milestones].sort(),
    playedParticipants: keys
  }
}

function identityFixture() {
  return {
    ipcCatalog: ipcCatalogFixture(),
    registryOffers: registryOffers(),
    shortcuts: shortcutWords(),
    bootHelpAliases: bootHelpAliases(),
    milestones: milestoneParticipants()
  }
}

// --- document assembly ----------------------------------------------------

function build(kind, unitsSource) {
  const units = unitsSource()
  // The golden calls the field `owner`; the published digest hashes the same
  // records under the data module's field name `provider`. Only the key name
  // differs, so hash an explicitly renamed copy.
  const digestRows = units.map(u => {
    const copy = {}
    for (const key of Object.keys(u).sort()) if (key !== 'owner') copy[key] = u[key]
    copy.provider = u.owner
    return copy
  })
  return sortKeys({
    version: 1,
    kind,
    sources: {
      catalog: 'git HEAD:shell/boot/Boot.qml (pre-extraction _catalog)',
      identities: 'working tree at golden creation (IpcCatalog, Registry, IpcRouter, Boot help, DesktopLayoutState)'
    },
    canonicalization: {
      objectKeys: 'sorted recursively',
      unorderedSets: 'sorted: targets, verbs, verbNames, offers, aliases, milestones, participants, shortcut action keys',
      declaredOrder: 'preserved: units, dependencies, shortcut argv'
    },
    fixtures: { settingsCatalogPath: FIXTURE_PREFIX },
    unitsDigest: fnv1a(canonicalText(digestRows)),
    units,
    identities: identityFixture()
  })
}

function write(file, doc) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(sortKeys(doc), null, 2) + '\n')
}

// --- comparison -----------------------------------------------------------

const REMOVED = []
function requireRecords(golden, candidate) {
  const gu = new Map(golden.units.map(u => [u.id, u]))
  const cu = new Map(candidate.units.map(u => [u.id, u]))
  for (const id of gu.keys()) if (!cu.has(id)) REMOVED.push(`REMOVED RECORD (missing from candidate): units[${id}]`)
  for (const u of candidate.units) if (!gu.has(u.id)) REMOVED.push(`UNEXPECTED RECORD (candidate only): units[${u.id}]`)
  const gi = golden.identities
  const ci = candidate.identities
  for (const [group, ids] of [
    ['ipcCatalog.targets', gi.ipcCatalog.targets.map(x => x.id)],
    ['ipcCatalog.verbs', gi.ipcCatalog.verbs.map(x => x.id)],
    ['registryOffers', gi.registryOffers.map(x => x.id)],
    ['shortcuts', Object.keys(gi.shortcuts.actions)],
    ['bootHelpAliases', gi.bootHelpAliases.map(x => x.owner)]
  ]) {
    const have = new Set(group === 'ipcCatalog.targets' ? ci.ipcCatalog.targets.map(x => x.id)
      : group === 'ipcCatalog.verbs' ? ci.ipcCatalog.verbs.map(x => x.id)
        : group === 'registryOffers' ? ci.registryOffers.map(x => x.id)
          : group === 'shortcuts' ? Object.keys(ci.shortcuts.actions)
            : ci.bootHelpAliases.map(x => x.owner))
    for (const id of ids) if (!have.has(id)) REMOVED.push(`REMOVED RECORD (missing from candidate): ${group}[${id}]`)
  }
}

function lineDiff(golden, candidate) {
  const a = JSON.stringify(sortKeys(golden), null, 2).split('\n')
  const b = JSON.stringify(sortKeys(candidate), null, 2).split('\n')
  const rows = []
  const n = Math.max(a.length, b.length)
  for (let i = 0; i < n; i++) {
    if (a[i] === b[i]) continue
    rows.push(`  ${String(i + 1).padStart(5)} - ${a[i] === undefined ? '<missing>' : a[i]}`)
    rows.push(`  ${String(i + 1).padStart(5)} + ${b[i] === undefined ? '<missing>' : b[i]}`)
  }
  return rows.slice(0, 120).join('\n') + (rows.length > 120 ? '\n  ... diff truncated' : '')
}

function main() {
  if (writeGolden) {
    const golden = build('unit-catalog-structural-golden', baselineUnits)
    write(GOLDEN_PATH, golden)
    process.stdout.write(`wrote ${path.relative(ROOT, GOLDEN_PATH)} (${golden.units.length} units, digest ${golden.unitsDigest})\n`)
    return
  }

  const golden = JSON.parse(fs.readFileSync(GOLDEN_PATH, 'utf8'))
  const candidate = build('unit-catalog-structural-golden', installedUnits)
  if (candidatePath) write(candidatePath, candidate)
  requireRecords(golden, candidate)

  const installed = loadLib(CATALOG_JS)
  const liveDigest = typeof installed.digest === 'function' ? installed.digest() : null
  const a = JSON.stringify(sortKeys(golden))
  const b = JSON.stringify(sortKeys(candidate))
  if (REMOVED.length === 0 && a === b && liveDigest === golden.unitsDigest) {
    process.stdout.write(`unit catalog matches golden: ${golden.units.length} units, digest ${golden.unitsDigest}` +
      (candidatePath ? `\ncandidate written to ${candidatePath}` : '') + '\n')
    return
  }
  process.stderr.write('STALE GOLDEN or removed record: unit catalog candidate does not match.\n')
  for (const line of REMOVED) process.stderr.write(`  ${line}\n`)
  if (liveDigest !== golden.unitsDigest) {
    process.stderr.write(`  DIGEST: golden ${golden.unitsDigest}, Units.catalog.digest() ${liveDigest}\n`)
  }
  if (wantDiff && a !== b) process.stderr.write(lineDiff(golden, candidate) + '\n')
  process.exit(1)
}

main()

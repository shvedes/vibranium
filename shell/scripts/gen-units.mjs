#!/usr/bin/env node
// Development generator for full self-registration.
//
//   node shell/scripts/gen-units.mjs               publish the six generated outputs
//   node shell/scripts/gen-units.mjs --check       regenerate into a temp tree and
//                                           compare bytes; never mutate outputs
//   node shell/scripts/gen-units.mjs --root <dir>  operate on an isolated fixture tree
//
// Ownership comes only from validated *.unit.json declarations discovered
// under shell/common, shell/features, shell/services and shell/boot. The
// declarations form one chain anchored at the virtual __head__ sentinel; the
// first row is whichever declaration anchors to it. There is no seed file and
// no authored handler table: previously generated output is never an input.
// The golden is read for comparison only and is never written.

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'
import {
  PROVIDERS, validateDeclaration, insertDeclarations, effectiveDigest,
  compareGolden, emitCatalog, emitHandlers, outputPaths, handlersPath
} from './lib/unit-manifest.mjs'

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const GOLDEN = 'tests/shell/fixtures/unit-catalog/golden.json'
const CATALOG_REL = 'shell/boot/Units.catalog.js'
const DISCOVERY_ROOTS = Object.freeze([
  'shell/common', 'shell/features', 'shell/services', 'shell/boot'
])
const GENERATED_DIRS = Object.freeze([
  'shell/boot/generated/floor',
  'shell/boot/generated/services',
  'shell/boot/generated/features',
  'shell/boot/generated/bar',
  'shell/boot/generated/demand'
])
const EXPECTED_ROWS = 52

function fail(message) {
  throw new Error(message)
}

function usage(rc = 0) {
  const text = `Usage: node shell/scripts/gen-units.mjs [options]

  Discovers *.unit.json under shell/common, shell/features, shell/services and
  shell/boot, builds the __head__-anchored chain of 52 declarations, verifies
  the golden and digest, and writes six outputs: Units.catalog.js plus one
  handlers type for each of floor, services, features, bar and demand.

  --root <dir>   use an isolated tree laid out like the repository
  --check        regenerate into a temporary tree and compare bytes; no writes
  -h, --help     show this text
`
  process.stdout.write(text)
  process.exit(rc)
}

function parseArgs(argv) {
  let root = DEFAULT_ROOT
  let check = false
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--check') check = true
    else if (arg === '--root' || arg.startsWith('--root=')) {
      const value = arg === '--root' ? argv[++i] : arg.slice('--root='.length)
      if (!value) fail('--root requires a directory')
      root = path.resolve(value)
    } else if (arg === '-h' || arg === '--help') usage(0)
    else fail(`unknown option: ${arg}`)
  }
  return { root, check }
}

function byPath(a, b) {
  return a < b ? -1 : a > b ? 1 : 0
}

function toPosix(file) {
  return file.split(path.sep).join('/')
}

function isFile(file) {
  try { return fs.statSync(file).isFile() } catch { return false }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    throw new Error(`${toPosix(path.relative(process.cwd(), file))}: ${error.message}`)
  }
}

// Generated and staging directories are never an ownership input, in any root.
function walk(rootDir, accept, found) {
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true }).sort((a, b) => byPath(a.name, b.name))) {
    if (entry.isDirectory()) {
      if (entry.name === 'generated' || entry.name.startsWith('.')) continue
      walk(path.join(rootDir, entry.name), accept, found)
    } else if (entry.isFile() && accept(entry.name)) {
      found.push(path.join(rootDir, entry.name))
    }
  }
}

function discoverDeclarations(root) {
  const files = []
  let existing = 0
  for (const base of DISCOVERY_ROOTS) {
    const dir = path.join(root, base)
    if (!fs.existsSync(dir)) continue // an isolated fixture may use a subset
    if (!fs.statSync(dir).isDirectory()) fail(`source root is not a directory: ${base}`)
    existing++
    walk(dir, (name) => name.endsWith('.unit.json'), files)
  }
  if (!existing) fail(`missing source roots: ${DISCOVERY_ROOTS.join(', ')}`)
  files.sort(byPath)
  return files.map((file) => validateDeclaration(readJson(file), toPosix(path.relative(root, file))))
}

function readModuleName(file, rel) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
  for (const line of lines) {
    const match = /^\s*module\s+([A-Za-z0-9_.-]+)\s*(?:#.*)?$/.exec(line)
    if (match) return match[1]
  }
  fail(`${rel}: qmldir has no module directive`)
}

function aliasForModule(moduleName) {
  const last = moduleName.slice(moduleName.lastIndexOf('.') + 1)
  return last ? last[0].toUpperCase() + last.slice(1) : ''
}

// QML import derivation is data-driven: nearest qmldir for each declaration,
// qmldir type names for unqualified ref roots, and a module's last path segment
// for qualified ref roots. No unit id is named here.
function buildModuleIndex(root, declarations) {
  const qmldirs = []
  for (const base of DISCOVERY_ROOTS) {
    const dir = path.join(root, base)
    if (fs.existsSync(dir)) walk(dir, (name) => name === 'qmldir', qmldirs)
  }
  qmldirs.sort(byPath)

  const types = {}
  const typesByLower = {}
  const aliases = {}
  for (const file of qmldirs) {
    const rel = toPosix(path.relative(root, file))
    const moduleName = readModuleName(file, rel)
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) continue
      const match = /^(?:singleton\s+)?([A-Za-z_][A-Za-z0-9_]*)\s+\d+\.\d+(?:\s+.*)?$/.exec(trimmed)
      if (!match) continue
      const existing = types[match[1]]
      if (existing === undefined) types[match[1]] = moduleName
      else if (typeof existing === 'string') {
        types[match[1]] = existing === moduleName ? existing : [existing, moduleName]
      } else if (!existing.includes(moduleName)) existing.push(moduleName)
      const lower = match[1].toLowerCase()
      if (!typesByLower[lower]) typesByLower[lower] = new Set()
      typesByLower[lower].add(match[1])
    }
    const alias = aliasForModule(moduleName)
    if (alias && aliases[alias] === undefined) aliases[alias] = moduleName
  }

  const sources = {}
  for (const decl of declarations) {
    let dir = path.posix.dirname(decl.source)
    for (;;) {
      const candidate = path.join(root, dir, 'qmldir')
      if (isFile(candidate)) {
        sources[decl.source] = readModuleName(candidate, toPosix(path.relative(root, candidate)))
        break
      }
      if (!dir || dir === '.' || dir === '/') break
      const parent = path.posix.dirname(dir)
      if (parent === dir) break
      dir = parent
    }
    if (!sources[decl.source]) fail(`${decl.source}: no qmldir found above declaration`)
  }
  const byLower = Object.fromEntries(
    Object.entries(typesByLower).map(([name, found]) => [name, [...found].sort(byPath)])
  )
  return { types, typesByLower: byLower, aliases, sources }
}

// A hook file exposes only the members it overrides; the rest keep their
// mechanical expression. Read the source text only: hook bodies never run.
function scanHookMembers(root, declarations) {
  const hooks = {}
  for (const decl of declarations) {
    if (!decl.hooks) continue
    if (decl.hooks.startsWith('shell/boot/generated/')) fail(`${decl.source}: hooks path cannot be generated output`)
    const file = path.resolve(root, decl.hooks)
    if (!isFile(file)) fail(`${decl.source}: hook file not found: ${decl.hooks}`)
    const text = fs.readFileSync(file, 'utf8')
    const found = new Set()
    for (const match of text.matchAll(/^\s*function\s+(resolve|ready|teardown)\s*\(/gm)) found.add(match[1])
    hooks[decl.hooks] = [...found].sort()
  }
  return hooks
}

function buildCandidates(root) {
  const declarations = discoverDeclarations(root)
  const rows = insertDeclarations(declarations)
  if (rows.length !== EXPECTED_ROWS) {
    fail(`expected exactly ${EXPECTED_ROWS} declarations, found ${rows.length}`)
  }
  const digest = effectiveDigest(rows)
  const golden = readJson(path.join(root, GOLDEN))
  compareGolden(rows, golden, digest)

  const moduleIndex = buildModuleIndex(root, declarations)
  moduleIndex.hooks = scanHookMembers(root, declarations)

  const candidates = new Map()
  for (const provider of PROVIDERS) {
    candidates.set(handlersPath(provider), emitHandlers(provider, rows, moduleIndex))
  }
  candidates.set(CATALOG_REL, emitCatalog(rows))
  return { candidates, digest, declarations, rows }
}

function checkOutputs(root, candidates) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gen-units-check-'))
  try {
    for (const [rel, text] of candidates) {
      const staged = path.join(tmp, rel)
      fs.mkdirSync(path.dirname(staged), { recursive: true })
      fs.writeFileSync(staged, text)
    }
    for (const rel of outputPaths()) {
      const dest = path.join(root, rel)
      if (!isFile(dest)) fail(`--check: missing output ${rel}`)
      if (!fs.readFileSync(dest).equals(fs.readFileSync(path.join(tmp, rel)))) {
        fail(`--check: stale or hand-edited output ${rel}`)
      }
    }
    for (const dirRel of GENERATED_DIRS) {
      const dir = path.join(root, dirRel)
      if (!fs.existsSync(dir)) continue
      const expected = new Set(
        outputPaths().filter((rel) => path.posix.dirname(rel) === dirRel)
          .map((rel) => path.posix.basename(rel))
      )
      const extras = fs.readdirSync(dir, { withFileTypes: true })
        .filter((entry) => entry.isFile() && !expected.has(entry.name))
        .map((entry) => path.join(dirRel, entry.name))
      if (extras.length) fail(`--check: orphaned generated outputs: ${extras.join(', ')}`)
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
  }
  process.stdout.write(`gen-units --check: ${candidates.size} outputs match; no files written\n`)
}

// Stage the whole set in a unique per-run directory beside the outputs, with
// staged candidates and recoverable copies in distinct subpaths. Renames are
// on the same filesystem as every destination.
function publish(root, candidates) {
  const staging = fs.mkdtempSync(path.join(root, 'shell/boot', '.gen-units-'))
  const stagedDir = path.join(staging, 'staged')
  const recoveryDir = path.join(staging, 'recovery')
  fs.mkdirSync(stagedDir)
  fs.mkdirSync(recoveryDir)

  for (const [rel, text] of candidates) {
    const staged = path.join(stagedDir, rel)
    fs.mkdirSync(path.dirname(staged), { recursive: true })
    fs.writeFileSync(staged, text)
    const dest = path.join(root, rel)
    if (fs.existsSync(dest)) {
      const recovery = path.join(recoveryDir, rel)
      fs.mkdirSync(path.dirname(recovery), { recursive: true })
      fs.copyFileSync(dest, recovery)
    }
  }

  const replaced = []
  const created = []
  try {
    for (const rel of outputPaths()) {
      if (process.env.GEN_UNITS_FAIL_AT === path.basename(rel)) {
        fail(`injected failure at ${rel} (GEN_UNITS_FAIL_AT)`)
      }
      const dest = path.join(root, rel)
      const existed = fs.existsSync(dest)
      fs.mkdirSync(path.dirname(dest), { recursive: true })
      fs.renameSync(path.join(stagedDir, rel), dest)
      if (existed) replaced.push({ rel, dest, recovery: path.join(recoveryDir, rel) })
      else created.push({ rel, dest })
    }
  } catch (error) {
    const problems = []
    for (const item of replaced.slice().reverse()) {
      try { fs.renameSync(item.recovery, item.dest) }
      catch (restoreError) { problems.push({ ...item, error: restoreError }) }
    }
    for (const item of created.slice().reverse()) {
      try { fs.unlinkSync(item.dest) }
      catch (removeError) { problems.push({ ...item, recovery: null, error: removeError }) }
    }
    if (problems.length) {
      process.stderr.write(`gen-units: rollback incomplete; recovery files preserved at ${staging}\n`)
      for (const item of problems) {
        process.stderr.write(`  destination: ${item.dest}\n  recovery: ${item.recovery || '<new file, no recovery copy>'}\n  error: ${item.error.message}\n`)
      }
      fail(`publication failed (${error.message}); rollback incomplete`)
    }
    fs.rmSync(staging, { recursive: true, force: true })
    fail(`publication failed (${error.message}); rolled back all outputs`)
  }
  fs.rmSync(staging, { recursive: true, force: true })
  process.stdout.write(`gen-units: published ${candidates.size} outputs\n`)
}

function main() {
  const { root, check } = parseArgs(process.argv.slice(2))
  const { candidates, digest, declarations } = buildCandidates(root)
  if (check) checkOutputs(root, candidates)
  else publish(root, candidates)
  process.stdout.write(`gen-units: ${declarations.length} declarations, digest ${digest}\n`)
}

try {
  main()
} catch (error) {
  process.stderr.write(`gen-units: ${error.message}\n`)
  process.exitCode = 1
}

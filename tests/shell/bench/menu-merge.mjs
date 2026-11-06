// Benchmark: composing the menu tree, the path every menu open walks.
//
// Two pipelines over identical real inputs (the shipped catalog, its schema
// defaults, the real MenuLib):
//
//   legacy   what the tree did before unification - each store stringified
//            its half, the menu parsed both halves back, re-normalized every
//            page per merge, and merged the hypr half TWICE (once into the
//            displayed bundle, once into the search bundle).
//
//   unified  one descriptor build per store, one normalization per store
//            generation (cached by payload identity in Menu), appended by
//            reference.
//
// The legacy half reimplements the retired mergeSibling inline on purpose:
// the point is to measure the old shape, so it must not depend on the library
// still carrying the old code.
//
// It also asserts the two pipelines produce the SAME tree - same page ids in
// the same order, same uids in the same order, same index labels - before it
// reports a single timing. A benchmark of a path that quietly changed the
// output would be worse than no benchmark.
//
//   node tests/shell/bench/menu-merge.mjs [iterations]
//
// Not a test suite: it lives outside suites/ so run-all.sh does not discover
// it. Exit status is 1 on a tree mismatch, so it can be used as a check too.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../lib/qmlloader.mjs'

const ROOT = path.resolve(import.meta.dirname, '../../..')
const ARGS = process.argv.slice(2)
const ITER = Number(ARGS.find((a) => /^\d+$/.test(a)) || 40)
const PROFILE = ARGS.includes('--profile')

const SL = loadLib(path.join(ROOT, 'shell/common/settings/SettingsLib.js'))
const MenuLib = loadLib(path.join(ROOT, 'shell/features/menu/MenuLib.js'))

const catalogText = fs.readFileSync(path.join(ROOT, 'shell/common/settings/catalog.jsonc'), 'utf8')
const cat = SL.parseUnifiedCatalog(catalogText)
// What SettingsCatalog hands out: the same document, already parsed, so the
// menu never parses it a second time.
const parsedMenus = cat.menus

// Exactly what the two stores collect: Settings keeps shell+env pages,
// HyprlandSettings keeps hypr pages, both with the catalog's root title.
const shellSections = cat.sections.filter((s) => s.group === 'shell' || s.group === 'env')
const hyprSections = cat.sections.filter((s) => s.group === 'hypr')
const shellSchema = SL.buildSchema(shellSections, cat.rootWidth || 0, cat.rootTitle || '')
const hyprSchema = SL.buildSchema(hyprSections, cat.rootWidth || 0, cat.rootTitle || '')

// Real default values, which is what a fresh install renders.
function defaultsOf(schema) {
  const out = {}
  for (const k in schema.byKey) out[k] = schema.byKey[k].default
  return { __proto__: null, ...out }
}
const shellValues = defaultsOf(shellSchema)
const hyprValues = defaultsOf(hyprSchema)

// --- the retired text merge, reproduced ------------------------------------

function legacySibling(base, text) {
  const raw = JSON.parse(MenuLib.stripJsonc(text))
  const rawPages = Array.isArray(raw) ? raw : Array.isArray(raw.pages) ? raw.pages : [raw]
  const pages = base.pages.slice()
  const byId = Object.assign(Object.create(null), base.byId)
  for (let i = 0; i < rawPages.length; i++) {
    const page = MenuLib.normalizePage(rawPages[i], 'sibling' + i)
    if (byId[page.id] !== undefined) continue
    pages.push(page)
    byId[page.id] = page
  }
  return { entry: base.entry, pages, byId }
}

// --- the two per-open pipelines -------------------------------------------

// Legacy: the stores' strings and the parsed half are amortized exactly the
// way the old store-side rev cache amortized them - a menu open still paid
// for both parses and for every normalization, twice for hypr.
const legacySettingsText = JSON.stringify(SL.buildBundle(shellSchema, shellValues))
const legacyHyprText = JSON.stringify({
  pages: SL.buildBundle(hyprSchema, hyprValues).pages.filter((p) => p.id !== 'settings'),
})

function runLegacy() {
  let base = MenuLib.parseBundle(catalogText)
  base = legacySibling(base, legacySettingsText)
  base = legacySibling(base, legacyHyprText)
  // The old code merged hypr into the search bundle a second time.
  const search = legacySibling(base, legacyHyprText)
  MenuLib.orderSettingsIndex(base)
  MenuLib.orderSettingsIndex(search)
  const scoped = MenuLib.scopeBundle(base, 'settings', [])
  const index = MenuLib.buildIndex(MenuLib.scopeBundle(search, 'settings', []))
  return { bundle: scoped, index: index.length }
}

// Unified: the stores' descriptors and the normalized pages are amortized the
// way the Menu-side identity cache amortizes them - a menu open appends
// references and reorders one page.
const unifiedSettings = SL.buildPages(shellSchema, shellValues)
const unifiedSettingsPages = [MenuLib.normalizePage({
  id: 'settings',
  title: unifiedSettings.indexTitle,
  items: unifiedSettings.index,
}, 'settings')].concat(MenuLib.normalizePages(unifiedSettings.pages))
const unifiedHyprPages = MenuLib.normalizePages(SL.buildPages(hyprSchema, hyprValues).pages)

function runUnified() {
  let base = MenuLib.bundleFromPages(parsedMenus)
  base = MenuLib.mergePages(base, unifiedSettingsPages)
  base = MenuLib.mergePages(base, unifiedHyprPages)
  MenuLib.orderSettingsIndex(base)
  const scoped = MenuLib.scopeBundle(base, 'settings', [])
  const index = MenuLib.buildIndex(scoped)
  return { bundle: scoped, index: index.length }
}

// --- equivalence first -----------------------------------------------------

function shape(bundle) {
  return bundle.pages.map((p) => ({
    id: p.id,
    label: p.label,
    width: p.width,
    layout: p.layout,
    uids: p.items.map((it) => it.uid),
    labels: p.items.map((it) => it.label),
  }))
}

const legacyOut = runLegacy()
const unifiedOut = runUnified()
const legacyShape = JSON.stringify(shape(legacyOut.bundle))
const unifiedShape = JSON.stringify(shape(unifiedOut.bundle))

if (legacyShape !== unifiedShape) {
  const a = JSON.parse(legacyShape)
  const b = JSON.parse(unifiedShape)
  console.error('TREE MISMATCH')
  console.error('  pages legacy/unified:', a.length, b.length)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i]
    const y = b[i]
    if (JSON.stringify(x) === JSON.stringify(y)) continue
    console.error('  page', i, x && x.id, 'vs', y && y.id)
    if (!x || !y) break
    if (x.uids.join() !== y.uids.join()) {
      const n = Math.max(x.uids.length, y.uids.length)
      for (let j = 0; j < n; j++) {
        if (x.uids[j] !== y.uids[j]) {
          console.error('    first uid difference at row', j, ':', x.uids[j], 'vs', y.uids[j])
          break
        }
      }
    }
    break
  }
  process.exit(1)
}
if (legacyOut.index !== unifiedOut.index) {
  console.error(`SEARCH INDEX MISMATCH: legacy ${legacyOut.index} entries, unified ${unifiedOut.index}`)
  process.exit(1)
}

// --- cold build ------------------------------------------------------------

function timeOnce(fn) {
  const t0 = process.hrtime.bigint()
  fn()
  return Number(process.hrtime.bigint() - t0) / 1e6
}

function coldLegacy() {
  const st = JSON.stringify(SL.buildBundle(shellSchema, shellValues))
  const ht = JSON.stringify({ pages: SL.buildBundle(hyprSchema, hyprValues).pages.filter((p) => p.id !== 'settings') })
  const base = MenuLib.parseBundle(catalogText)
  const merged = legacySibling(legacySibling(base, st), ht)
  MenuLib.orderSettingsIndex(merged)
  const scoped = MenuLib.scopeBundle(merged, 'settings', [])
  return MenuLib.buildIndex(scoped).length
}

function coldUnified() {
  const s = SL.buildPages(shellSchema, shellValues)
  const pages = [MenuLib.normalizePage({ id: 'settings', title: s.indexTitle, items: s.index }, 'settings')]
    .concat(MenuLib.normalizePages(s.pages))
  const h = MenuLib.normalizePages(SL.buildPages(hyprSchema, hyprValues).pages)
  const base = MenuLib.bundleFromPages(parsedMenus)
  const merged = MenuLib.mergePages(MenuLib.mergePages(base, pages), h)
  MenuLib.orderSettingsIndex(merged)
  const scoped = MenuLib.scopeBundle(merged, 'settings', [])
  return MenuLib.buildIndex(scoped).length
}

// --- warm per-open ---------------------------------------------------------

const legacyT = []
const unifiedT = []
for (let i = 0; i < ITER; i++) {
  legacyT.push(timeOnce(runLegacy))
  unifiedT.push(timeOnce(runUnified))
}
const coldLegacyT = []
const coldUnifiedT = []
for (let i = 0; i < 5; i++) {
  coldLegacyT.push(timeOnce(coldLegacy))
  coldUnifiedT.push(timeOnce(coldUnified))
}

const median = (xs) => {
  const s = xs.slice().sort((a, b) => a - b)
  return s[(s.length - 1) >> 1]
}
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length
const p95 = (xs) => {
  const s = xs.slice().sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor(s.length * 0.95))]
}
const fmt = (n) => n.toFixed(2).padStart(8) + ' ms'

const pages = unifiedOut.bundle.pages.length
const rows = unifiedOut.bundle.pages.reduce((n, p) => n + p.items.length, 0)

console.log('')
console.log('menu tree composition - real catalog, schema defaults')
console.log(`  ${pages} pages, ${rows} rows, ${unifiedOut.index} search entries`)
console.log('')
console.log(`  ${'pipeline'.padEnd(10)} ${'cold'.padStart(11)} ${'warm med'.padStart(11)} ${'warm mean'.padStart(11)} ${'warm p95'.padStart(11)}`)
console.log(`  ${'legacy'.padEnd(10)} ${fmt(median(coldLegacyT))} ${fmt(median(legacyT))} ${fmt(mean(legacyT))} ${fmt(p95(legacyT))}`)
console.log(`  ${'unified'.padEnd(10)} ${fmt(median(coldUnifiedT))} ${fmt(median(unifiedT))} ${fmt(mean(unifiedT))} ${fmt(p95(unifiedT))}`)
console.log('')
const cut = (1 - median(unifiedT) / median(legacyT)) * 100
console.log(`  warm per open: ${(median(legacyT) - median(unifiedT)).toFixed(2)} ms less, ${cut.toFixed(0)}% off`)
console.log(`  cold build:    ${(median(coldLegacyT) - median(coldUnifiedT)).toFixed(2)} ms less`)
console.log('')

// --- stage breakdown -------------------------------------------------------
//
// Where the remaining per-open time actually goes. Reported as a mean over the
// same iteration count, because the stages are a few hundred microseconds and
// a single median of each would be measuring noise.

if (PROFILE) {
  const stages = {}
  const add = (k, ms) => { stages[k] = (stages[k] || 0) + ms }
  for (let i = 0; i < ITER; i++) {
    let t0 = process.hrtime.bigint()
    const lap = (k) => {
      const now = process.hrtime.bigint()
      add(k, Number(now - t0) / 1e6)
      t0 = now
    }
    let base = MenuLib.bundleFromPages(parsedMenus)
    lap('bundleFromPages(menus)')
    base = MenuLib.mergePages(base, unifiedSettingsPages)
    lap('merge settings')
    base = MenuLib.mergePages(base, unifiedHyprPages)
    lap('merge hypr')
    MenuLib.orderSettingsIndex(base)
    lap('order index')
    const scoped = MenuLib.scopeBundle(base, 'settings', [])
    lap('scope')
    MenuLib.buildIndex(scoped)
    lap('buildIndex')
  }
  // The store side, which a settings write pays: descriptors rebuilt, then
  // normalized again because the generation moved.
  const storeMs = []
  const normMs = []
  for (let i = 0; i < ITER; i++) {
    let t0 = process.hrtime.bigint()
    const built = SL.buildPages(shellSchema, shellValues)
    storeMs.push(Number(process.hrtime.bigint() - t0) / 1e6)
    t0 = process.hrtime.bigint()
    MenuLib.normalizePages(built.pages)
    normMs.push(Number(process.hrtime.bigint() - t0) / 1e6)
  }
  console.log(`  stage breakdown, mean over ${ITER} runs`)
  const total = Object.values(stages).reduce((a, b) => a + b, 0) / ITER
  for (const k of Object.keys(stages)) {
    const ms = stages[k] / ITER
    console.log(`    ${k.padEnd(22)} ${ms.toFixed(3).padStart(7)} ms  ${((ms / total) * 100).toFixed(0).padStart(3)}%`)
  }
  console.log(`    ${'total'.padEnd(22)} ${total.toFixed(3).padStart(7)} ms`)
  console.log(`  store side, per settings write`)
  console.log(`    ${'buildPages'.padEnd(22)} ${(mean(storeMs)).toFixed(3).padStart(7)} ms`)
  console.log(`    ${'normalizePages'.padEnd(22)} ${(mean(normMs)).toFixed(3).padStart(7)} ms`)
  console.log('')
}

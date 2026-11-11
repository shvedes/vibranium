// Benchmark: the three per-keystroke search paths.
//
//   launcher   LauncherLib.searchRecords over a synthetic app index
//   clipboard  ClipboardLib.searchEntries over a synthetic history
//   menu       MenuLib.search over a synthetic page index
//
// Each iteration hands the search a NEW pool array with the same rows, so the
// incremental query caches miss and the measurement is the cold scan a caller
// pays when the pool itself changed. Rows are shared, exactly as a real index
// re-derived from the same entries shares them.
//
//   node tests/shell/bench/search-ranking.mjs [iterations]
//
// Not a test suite: it lives outside suites/ so run-all.sh does not discover
// it. It prints medians and means in milliseconds; there is no pass/fail
// threshold, because a benchmark of a path that quietly stopped returning the
// same rows would be worse than no benchmark. The suites own correctness.

import path from 'node:path'
import { loadLib } from '../lib/qmlloader.mjs'

const ROOT = path.resolve(import.meta.dirname, '../../..')
const ITER = Number(process.argv.find((a) => /^\d+$/.test(a)) || 40)

const L = loadLib(path.join(ROOT, 'shell/features/launcher/LauncherLib.js'))
const C = loadLib(path.join(ROOT, 'shell/features/clipboard/ClipboardLib.js'))
const M = loadLib(path.join(ROOT, 'shell/features/menu/MenuLib.js'))

const WORDS = (
  'terminal settings firefox chromium files editor notes music video image ' +
  'calculator calendar weather network bluetooth audio volume display power ' +
  'session lock screen wallpaper theme color picker clipboard password vault ' +
  'document viewer archive download screenshot record camera monitor keyboard ' +
  'mouse touchpad printer scanner disk memory process system update package'
).split(' ')

function nameFor(i) {
  const a = WORDS[i % WORDS.length]
  const b = WORDS[(i * 7 + 3) % WORDS.length]
  return `${a} ${b} ${i}`
}

// Launcher records: the shape tokenScore reads is `words`, and the tiebreak
// reads `usage`. 1200 rows is a machine with a large desktop-entry set.
const REC_COUNT = 1200
const RECORDS = []
for (let i = 0; i < REC_COUNT; i++) {
  const name = nameFor(i)
  RECORDS.push({ name, words: name.toLowerCase().split(' '), usage: i % 11, kind: 'app', id: 'r' + i })
}

// Clipboard rows: hay/words/title are what deriveEntry leaves on a row.
const CLIP_COUNT = 260
const CLIPS = []
for (let i = 0; i < CLIP_COUNT; i++) {
  const name = nameFor(i)
  const hay = (name + ' text/plain clip row ' + i).toLowerCase()
  CLIPS.push({ id: 'c' + i, title: name, hay, words: hay.split(' '), type: 'text', mime: 'text/plain' })
}

// Menu index: 54 pages x ~6 rows, the shipped catalog's shape. buildPageIndex
// is exercised through normalizePage/buildIndex so the rows carry the hay and
// words the real index carries.
const MENU_PAGES = []
for (let p = 0; p < 54; p++) {
  const items = []
  for (let i = 0; i < 6; i++) {
    const name = nameFor(p * 6 + i)
    items.push({ id: 'i' + i, type: 'action', label: name, sub: 'page ' + p })
  }
  MENU_PAGES.push(M.normalizePage({ id: 'page' + p, title: 'Page ' + p, items }, 'page' + p))
}
const MENU_BUNDLE = M.bundleFromPages(MENU_PAGES.map((p) => ({ id: p.id, title: p.label, items: p._raw })))
const MENU_INDEX = M.buildIndex(MENU_BUNDLE)

const QUERIES = ['a', 'ch', 'chr', 'chro', 'chrom', 'term', 'terminal', 'set', 'settings', 'fire', 'net']

function median(xs) {
  const s = xs.slice().sort((a, b) => a - b)
  return s[(s.length - 1) >> 1]
}
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length
const fmt = (n) => n.toFixed(4).padStart(9) + ' ms'

function series(fn) {
  const out = []
  for (let i = 0; i < ITER; i++) {
    const q = QUERIES[i % QUERIES.length]
    const t0 = process.hrtime.bigint()
    fn(q, i)
    out.push(Number(process.hrtime.bigint() - t0) / 1e6)
  }
  return out
}

// A new pool array per call: same rows, new identity, so the length-aware
// incremental cache misses and the scan is cold.
const launcher = series((q) => L.searchRecords(RECORDS.slice(), q, 8, (r) => r.usage))
const clipboard = series((q) => C.searchEntries(CLIPS, q, 200))
const menu = series((q) => M.search(MENU_INDEX.slice(), q))

console.log('')
console.log('per-keystroke search, cold pool (rows shared, pool array new)')
console.log(`  ${ITER} runs over ${QUERIES.length} queries, median / mean`)
console.log('')
console.log(`  ${'surface'.padEnd(10)} ${'rows'.padStart(6)} ${'median'.padStart(13)} ${'mean'.padStart(13)}`)
console.log(`  ${'launcher'.padEnd(10)} ${String(REC_COUNT).padStart(6)} ${fmt(median(launcher))} ${fmt(mean(launcher))}`)
console.log(`  ${'clipboard'.padEnd(10)} ${String(CLIP_COUNT).padStart(6)} ${fmt(median(clipboard))} ${fmt(mean(clipboard))}`)
console.log(`  ${'menu'.padEnd(10)} ${String(MENU_INDEX.length).padStart(6)} ${fmt(median(menu))} ${fmt(mean(menu))}`)
console.log('')

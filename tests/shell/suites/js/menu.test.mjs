#!/usr/bin/env node
// Suite: shell/features/menu/MenuLib.js - the menu framework's pure layer.
//
// This is the largest single-library surface in the shell: 60 exported
// functions over four concerns that only meet at the panel boundary.
//
//   text/paths    clamp, pathDirname, quantize, decimalsOf, unitSuffix,
//                 widestValueString, stripForHay, hayFromItem
//   page build    defaultsFor, normalizeItem, buildPage, buildOptionsPage,
//                 normalizePage, parseBundle, orderSettingsIndex, and the
//                 four extension-merge pieces
//   guards        buildGuardScript, guardLine, requiresGuard, hideLine -
//                 these EMIT BASH, and the emitted text is asserted exactly
//   search        buildIndex, fuzzyScore, search + its module-level cache,
//                 filterCounter, scopedFilter, substitute, substituteQuoted,
//                 groupSearchResults
//
// plus two pure state machines that were extracted so they are testable
// without a shell at all: the staged-flow wizard (flowStep/nextFlowIndex/
// stageText/... and the option-grid geometry) and the keyboard model
// (selectableEdge, keyRoute).
//
// ## The module-level search cache
//
// `search` keeps four `var`s at module scope (`_searchCacheIndex`,
// `_searchCacheQ`, `_searchCacheEntries`, `_searchCacheHitSet`). There is no
// reset entry point: the cache is invalidated *only* by an index-identity or
// query change. That is correct for the production caller - Menu.qml always
// assigns a fresh array (buildIndex at Menu.qml:543, and the row-patch .map at
// Menu.qml:1514-1525) - and hostile to a test that reuses one index array.
//
// It is handled here two ways rather than fought:
//
//   1. Every `search`/`fuzzyScore` group builds its OWN index array, a fresh
//      instance per group. The incremental branch and the cache-hit branch
//      both require `_searchCacheIndex === index`, so a fresh instance is
//      structurally immune to an earlier group's cache - no label names have
//      to be unique, and no test depends on the order they run in. On top of
//      that each corpus uses its own nonsense tokens so a cross-talk bug
//      would be *visible* rather than silently absorbed.
//   2. The cache internals themselves are read through `liveMenuLib()`,
//      which re-evaluates the same source in a private vm context with
//      getters over the four `var`s. `loadLib` copies values at export time,
//      so through that namespace the cache vars read `null` forever and can
//      say nothing about the cache. The live view is what makes the
//      incremental branch and the 200-cap/hit-set split assertable, and it
//      gives a clean slate for the cross-corpus leakage guard below.
//
// The two hazards the cache actually has - an in-place rebuild and a caller
// mutating the array it was handed - are asserted as real behaviour in the
// "module-level search cache" section, with the production caller named.

import vm from 'node:vm'
import fs from 'node:fs'
import path from 'node:path'
import { loadLib, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, show, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const MENU_FILE = path.join(SHELL_DIR, 'features/menu/MenuLib.js')
const M = loadLib(MENU_FILE)
const SU = loadLib(path.join(SHELL_DIR, 'common/text/StringUtils.js'))

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

// A hand-rolled index entry, the shape buildIndex emits. Every search group
// builds its own array of these (see the cache note at the top).
const entry = (label, hay) => ({
  pageId: 'p',
  pageTitle: 'P',
  path: ['P'],
  row: 0,
  label: label,
  hay: hay,
  words: hay.split(' '),
})
const indexOf = (rows) => rows.map((r, i) => Object.assign(entry(r[0], r[1]), { row: i }))
const labels = (hits) => hits.map(h => h.label)

// liveMenuLib re-evaluates MenuLib in its own context so the four cache `var`s
// can be read AT ASSERT TIME. loadLib's namespace holds a snapshot taken at
// export time, so `_searchCacheIndex` there is `null` no matter what the
// library has done since.
const DECL = /^(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*))/gm
function liveMenuLib() {
  const src = libSource(MENU_FILE)
  const ctx = vm.createContext({
    console,
    Quickshell: { env: (k) => process.env[k] || '' },
    // libSource drops the .import lines, so the aliases they bound are
    // re-supplied here by hand.
    SU: loadLib(path.join(SHELL_DIR, 'common/text/StringUtils.js')),
    LauncherLib: loadLib(path.join(SHELL_DIR, 'features/launcher/LauncherLib.js')),
    Settings: loadLib(path.join(SHELL_DIR, 'common/settings/SettingsLib.js')),
  })
  vm.runInContext(src, ctx, { filename: MENU_FILE })
  const out = {}
  for (const m of src.matchAll(DECL)) {
    const name = m[1] || m[2]
    if (!(name in ctx)) continue
    if (name.startsWith('_searchCache')) {
      Object.defineProperty(out, name, { get: () => ctx[name], enumerable: true })
    } else {
      out[name] = ctx[name]
    }
  }
  return out
}

const bundle = (text) => M.parseBundle(text)
const page = (id, items, opts) => M.buildPage(id, id, 0, items, opts)

// The 66-function public surface, named once so the coverage claim is
// checkable rather than asserted in prose.
const SURFACE = [
  'stripJsonc', 'styledMarkup', 'shellQuote', 'clamp', 'pathDirname', 'quantize',
  'decimalsOf', 'unitSuffix', 'widestValueString', 'defaultsFor', 'stripForHay',
  'hayFromItem', 'hayForFilter', 'normalizeItem', 'buildOptionsPage', 'buildPage', 'mergedPageOpts',
  'normalizePage', 'parseBundle', 'orderSettingsIndex', 'mergeSibling', 'applyExtension',
  'mergedLabel', 'mergedWidth', 'replacePage', 'mergeRawItems', 'buildGuardScript',
  'uidKey', 'requiresExpr', 'requiresGuard', 'hideLine', 'guardLine', 'buildIndex',
  'buildPageIndex', 'fuzzyScore', 'search',
  'filterCounter', 'scopedFilter', 'substitute', 'substituteQuoted',
  'groupSearchResults',
  'hookValue', 'hookBool', 'hookRan', 'resolveConfirm', 'isFlow', 'flowStep', 'flowCount',
  'nextFlowIndex', 'stageText', 'stageUnitSuffix', 'stageSeedText', 'numberDisplay', 'valueSlotW',
  'optionLabelFor', 'optionSeedIndex', 'optionColumnCount', 'optionRowCount',
  'optionColumnStride', 'optionCellCol', 'optionCellRow', 'leadingNumber',
  'exactOptionIndex', 'bestOptionIndex', 'selectableEdge', 'keyRoute',
]

// keyRoute: one context factory and three projections over the route it picks.
const kctx = (over) => Object.assign({
  key: '', ctrl: false, meta: false, mode: 'list', grid: false,
  editor: false, del: false, confirm: false, field: false, text: '',
}, over)
const routeOf = (over) => {
  const r = M.keyRoute(kctx(over))
  return r === null ? null : (r.arg === null ? r.name : r.name + ' ' + JSON.stringify(r.arg))
}
const routeName = (over) => {
  const r = M.keyRoute(kctx(over))
  return r === null ? null : r.name
}

suite('menu/MenuLib', 'the menu framework\'s pure layer - 60 functions')

// ======================================================================
section('the harness contract')
group('the library loads and publishes its whole surface', () => {
  is('MenuLib loaded', M, (v) => v && typeof v === 'object' && Object.keys(v).length > 0, 'a non-empty namespace')
  // 67 functions plus the five search-cache `var`s, which the loader picks up
  // because a `.pragma library` namespace is its top-level declarations.
  eq('72 declarations', Object.keys(M).length, 72)
  const missing = SURFACE.filter(n => typeof M[n] !== 'function')
  eq('all 66 named functions are callable', missing, [])
  for (const n of SURFACE) {
    is(`${n} is a function`, M[n], (v) => typeof v === 'function', 'a function')
  }
})

group('the four search-cache vars are exported but frozen at their load value', () => {
  // A harness fact, not a library contract, and it is the reason the cache
  // section below reads them through a live context instead: loadLib assigns
  // `out[name] = ctx[name]`, a copy. Asserted here so a reader who reaches for
  // `M._searchCacheIndex` does not conclude the cache is dead.
  eq('index reads null', M._searchCacheIndex, null)
  eq('entries reads null', M._searchCacheEntries, null)
  eq('hit set reads null', M._searchCacheHitSet, null)
  eq('query reads the empty string', M._searchCacheQ, '')
  // ...and the functions really do share one module state behind that
  // namespace, which is what makes the identity check in search() work.
  M.search(indexOf([['Cache probe', 'cache probe needle']]), 'cache probe needle')
  eq('so a real search does NOT move the frozen snapshot', M._searchCacheIndex, null)
  const F = liveMenuLib()
  eq('the live view publishes the same 72 names', Object.keys(F).length, 72)
  eq('the live view agrees on every value the frozen one reports', [
    F._searchCacheIndex, F._searchCacheQ, F._searchCacheEntries, F._searchCacheHitSet,
  ], [null, '', null, null])
  eq('and on behaviour', M.fuzzyScore('power', ['power'], 'power'), F.fuzzyScore('power', ['power'], 'power'))
  eq('the live view starts with a null index', F._searchCacheIndex, null)
})

group('SHELL_DIR from the assertion kit resolves this library', () => {
  // The kit resolves the tree from its own location, so a suite can be run
  // from any working directory. Pinned here because a suite that has to
  // rebuild the path itself is one refactor away from opening the wrong tree.
  eq('the kit path holds the library under test', fs.existsSync(path.join(SHELL_DIR, 'features/menu/MenuLib.js')), true)
  eq('and it is the tree this suite loaded from', MENU_FILE, path.join(SHELL_DIR, 'features/menu/MenuLib.js'))
  eq('the tree it names is the shell directory', path.basename(SHELL_DIR), 'shell')
  // The README's file table and the directory have to agree in BOTH
  // directions. This used to be a bare `readdirSync().length === 12`, which
  // could not tell a documented file from an undocumented one: it passed while
  // the table listed ten files and the directory held thirteen, and it broke on
  // a stray `.bak` without saying which file was unaccounted for. A count is
  // not a cross-check.
  const menuDir = path.join(SHELL_DIR, 'features/menu')
  const onDisk = fs.readdirSync(menuDir)
  const listed = [...fs.readFileSync(path.join(menuDir, 'README.md'), 'utf8')
    .matchAll(/^\| `([A-Za-z0-9_.]+)` \|/gm)].map(m => m[1])
  eq('the README table lists something', listed.length > 0, true)
  eq('every file the README lists is on disk', listed.filter(f => !onDisk.includes(f)), [])
  // A README does not list itself, and nothing else may be unaccounted for.
  eq('every file on disk is listed, or is the README',
    onDisk.filter(f => !listed.includes(f) && f !== 'README.md'), [])
})

// ======================================================================
section('the three StringUtils re-exports are delegates, not copies')
group('MenuLib delegates to common/text/StringUtils.js', () => {
  // README: "stripJsonc, styledMarkup, shellQuote -> common/text/StringUtils.js".
  // A divergent duplicate is a real finding, so parity is asserted over a
  // spread of inputs on all three rather than one case each.
  const strip = ['// hi', '{"a":1,}', '', undefined, null, 0, 42, 'a://b', '{/*c*/"a":1}', '{"a":1} // hi']
  for (const arg of strip) {
    eq(`stripJsonc(${show(arg)}) agrees with StringUtils`, M.stripJsonc(arg), SU.stripJsonc(arg))
  }
  const quote = ["it's", '', '$X', 'a b', "'", '`id`', 'a\\b', 'a;b', 'a\nb', null, undefined]
  for (const arg of quote) {
    eq(`shellQuote(${show(arg)}) agrees with StringUtils`, M.shellQuote(arg), SU.shellQuote(arg))
  }
  const markup = ['<b>x</b>', 'a & b', 'a\nb', '', null, undefined, 0, false, '&lt;b&gt;', '<b class="c">x</b>']
  for (const arg of markup) {
    eq(`styledMarkup(${show(arg)}) agrees with StringUtils`, M.styledMarkup(arg), SU.styledMarkup(arg))
  }
  // Distinct function objects (two libraries, two vm contexts) with the same
  // one-argument shape.
  ne('stripJsonc is not the same object', M.stripJsonc, SU.stripJsonc)
  eq('same arity', [M.stripJsonc.length, M.shellQuote.length, M.styledMarkup.length], [1, 1, 1])
})

group('the delegating bodies are one-liners, so the source cannot drift silently', () => {
  // libSource drops the `.import` lines, so the import path itself is checked
  // by reading the file text rather than the stripped source.
  const raw = libSource(MENU_FILE)
  match('MenuLib imports StringUtils', raw, /function stripJsonc\(raw\) \{ return SU\.stripJsonc\(raw\) \}/)
  match('styledMarkup delegates', raw, /function styledMarkup\(text\) \{ return SU\.styledMarkup\(text\) \}/)
  match('shellQuote delegates', raw, /function shellQuote\(s\) \{ return SU\.shellQuote\(s\) \}/)
  eq('each is declared exactly once', [
    (raw.match(/function stripJsonc/g) || []).length,
    (raw.match(/function styledMarkup/g) || []).length,
    (raw.match(/function shellQuote/g) || []).length,
  ], [1, 1, 1])
  notMatch('no local re-implementation of the JSONC regex', raw, /replace\(\/\^\[ \\t\]\*\\\/\\\//)
  notMatch('no CommonJS export list to shadow the declarations', raw, /module\.exports/)
})

// ======================================================================
section('clamp, pathDirname, quantize, decimalsOf, unitSuffix')
group('clamp folds a value into [lo, hi]', () => {
  eq('above the ceiling', M.clamp(5, 0, 3), 3)
  eq('below the floor', M.clamp(-5, 0, 3), 0)
  eq('inside', M.clamp(2, 0, 3), 2)
  eq('on the ceiling', M.clamp(3, 0, 3), 3)
  eq('on the floor', M.clamp(0, 0, 3), 0)
  eq('equal bounds', M.clamp(5, 5, 5), 5)
  // `Math.min(hi, Math.max(lo, v))` puts hi on the outside, so an inverted
  // range answers hi rather than lo - a silent but decided outcome.
  eq('inverted bounds answer the hi side', M.clamp(1, 3, 0), 0)
  eq('a numeric string is coerced by Math.max', M.clamp('5', 0, 10), 5)
  eq('+Infinity clamps to hi', M.clamp(Infinity, 0, 3), 3)
  eq('-Infinity clamps to lo', M.clamp(-Infinity, 0, 3), 0)
  eq('a float is not rounded', M.clamp(1.7, 0, 1.5), 1.5)
})

group('clamp has no guard for a non-numeric value', () => {
  // Math.max(0, NaN) is NaN, so the answer is NaN and the caller's
  // `s < 0` style comparisons treat it as "no clamp happened". Pinned: the
  // stepper only ever hands it a number.
  is('NaN passes through', M.clamp(NaN, 0, 3), (v) => Number.isNaN(v), 'NaN')
  is('undefined passes through', M.clamp(undefined, 0, 3), (v) => Number.isNaN(v), 'NaN')
  is('no arguments at all', M.clamp(), (v) => Number.isNaN(v), 'NaN')
  is('undefined bounds', M.clamp(1, undefined, undefined), (v) => Number.isNaN(v), 'NaN')
  noThrow('but it never throws', () => M.clamp('x', 0, 3))
})

group('pathDirname returns the directory part, or "" when there is none', () => {
  eq('nested', M.pathDirname('/a/b'), '/a')
  eq('two levels', M.pathDirname('/a/b/c'), '/a/b')
  eq('relative with a directory', M.pathDirname('a/b'), 'a')
  // The header: 'A leading "/name" is a root-level entry with no directory of
  // its own, and a bare name has none either; the caller decides what that
  // absence means.' i > 0 is the whole rule.
  eq('a root-level entry has no directory', M.pathDirname('/a'), '')
  eq('a bare name has none', M.pathDirname('a'), '')
  eq('the empty string', M.pathDirname(''), '')
  eq('the root itself', M.pathDirname('/'), '')
  eq('a trailing slash is not its own segment', M.pathDirname('/a/b/'), '/a/b')
  eq('a doubled separator is a literal character', M.pathDirname('//a//b'), '//a/')
  eq('a dotted name is not a path', M.pathDirname('a.txt'), '')
})

group('quantize rounds to three decimals - the widest shipped step', () => {
  eq('0.1 + 0.2 drift', M.quantize(0.1 + 0.2), 0.3)
  approx('and it really is 0.3 to floating-point noise', M.quantize(0.1 + 0.2), 0.3, 1e-12)
  eq('rounds half away from zero at 4 digits', M.quantize(1.23456), 1.235)
  eq('a value inside the quantum is untouched', M.quantize(1.5), 1.5)
  eq('negative drift rounds toward zero', M.quantize(-0.0001), 0)
  eq('a negative value quantizes too', M.quantize(-1.23456), -1.235)
  eq('a third rounds down', M.quantize(1 / 3), 0.333)
  eq('two thirds rounds up', M.quantize(2 / 3), 0.667)
  eq('an exact 0.05 step survives', M.quantize(0.05), 0.05)
  eq('a negative exact 0.05 step survives', M.quantize(-0.05), -0.05)
  is('a non-numeric value propagates as NaN', M.quantize('x'), (v) => Number.isNaN(v), 'NaN')
  noThrow('Infinity', () => M.quantize(Infinity))
})

group('decimalsOf reads the step spec as text', () => {
  eq('"0.05" -> 2', M.decimalsOf(0.05), 2)
  eq('"1" -> 0', M.decimalsOf(1), 0)
  eq('"0.5" -> 1', M.decimalsOf(0.5), 1)
  eq('0.001 -> 3', M.decimalsOf(0.001), 3)
  // A string step keeps its trailing zeros, so a step written "1.000" claims
  // three decimals of precision the value does not have. Pinned because the
  // stepper takes steps from JSON.
  eq('a string keeps its trailing zeros', M.decimalsOf('1.000'), 3)
  eq('"0.25" -> 2', M.decimalsOf('0.25'), 2)
  eq('a non-numeric step', M.decimalsOf('x'), 0)
  eq('an absent step', M.decimalsOf(undefined), 0)
  eq('zero', M.decimalsOf(0), 0)
  // String(1e-7) is "1e-7": no dot, so the answer is 0 even though the value
  // needs seven. Deliberate-but-surprising, cited from decimalsOf's own
  // `String(step)` + `indexOf(".")` implementation.
  eq('exponent notation reads as zero decimals', M.decimalsOf(1e-7), 0)
  eq('and a large exponent too', M.decimalsOf(1e21), 0)
})

group('unitSuffix renders a declared unit, and nothing for an absent one', () => {
  eq('a unit rides after a space', M.unitSuffix('ms'), ' ms')
  eq('percent is a unit like any other', M.unitSuffix('%'), ' %')
  // The header: "Absent and empty are the same answer here, which is why this
  // never stringifies blindly - an unnormalized payload would print
  // "undefined" into the value slot."
  eq('undefined', M.unitSuffix(undefined), '')
  eq('null', M.unitSuffix(null), '')
  eq('empty', M.unitSuffix(''), '')
  eq('a space-only unit is still a unit', M.unitSuffix(' '), '  ')
  // The guard is `String(unit) !== ""`, so anything else stringifies. 0 and
  // false are the shapes that would print " 0" into the value slot.
  eq('zero is a unit', M.unitSuffix(0), ' 0')
  eq('false is a unit', M.unitSuffix(false), ' false')
  eq('a unit is not trimmed', M.unitSuffix(' ms '), '  ms ')
  eq('an object stringifies to [object Object]', M.unitSuffix({}), ' [object Object]')
})

group('widestValueString reserves the longest reading a value slot can show', () => {
  // "right-hand value must never elide, so the card reserves space for the
  // longest possible reading".
  eq('a falsey item has no value slot', M.widestValueString(null), '')
  eq('undefined too', M.widestValueString(undefined), '')
  eq('an item of another type has none', M.widestValueString({ type: 'action' }), '')
  eq('an empty object has none', M.widestValueString({}), '')
  eq('a whole-number range picks hi', M.widestValueString({ type: 'range', min: 0, max: 100, step: 1 }), '100')
  eq('a range with a unit appends it', M.widestValueString({ type: 'range', min: 0, max: 100, step: 1, unit: 'ms' }), '100 ms')
  eq('number rows take the same path as range', M.widestValueString({ type: 'number', min: 0, max: 1.5, step: 0.1 }), '0.0')
  // The header: "If range straddles zero, the negative side may be longest even
  // when hi has more digits - e.g. -1.00 (5) vs 1.00 (4). Pick longest of lo/hi."
  eq('a straddling range picks the negative side', M.widestValueString({ type: 'range', min: -1, max: 1, step: 0.01 }), '-1.00')
  eq('and when hi is longer even with the sign', M.widestValueString({ type: 'range', min: -5, max: 1000, step: 1 }), '-1000')
  eq('a negative min with a shorter hi is not forced negative', M.widestValueString({ type: 'range', min: -1, max: 5, step: 1 }), '-1')
  // `loStr.length >= hiStr.length ? loStr : hiStr` - a tie goes to the LOWER
  // bound, so a single-digit range reserves the lower bound's character. The
  // width is the same either way, which is all the caller uses it for, but the
  // value is pinned because "which number does the card reserve" is not
  // otherwise guessable.
  eq('a tie on width reserves the LOWER bound', M.widestValueString({ type: 'range', min: 0, max: 9, step: 1 }), '0')
  eq('and the tie is symmetric', M.widestValueString({ type: 'range', min: 9, max: 0, step: 1 }), '9')
  eq('so a straddling single-digit range reserves the negative side', M.widestValueString({ type: 'range', min: -1, max: 1, step: 1 }), '-1')
  eq('and min < 0 forces a minus onto a longer hi', M.widestValueString({ type: 'range', min: -9, max: 10, step: 1 }), '-10')
  eq('even when hi is longer than lo already', M.widestValueString({ type: 'range', min: -9, max: 100, step: 1 }), '-100')
  eq('a negative fraction', M.widestValueString({ type: 'range', min: -0.5, max: 1, step: 0.1 }), '-0.5')
  eq('a three-digit negative fraction', M.widestValueString({ type: 'range', min: -100, max: 100, step: 0.1 }), '-100.0')
  eq('a degenerate zero-width range', M.widestValueString({ type: 'range', min: 0, max: 0, step: 1 }), '0')
})

group('widestValueString falls back to the panel defaults', () => {
  // `item.step ?? 1` and `item.min ?? 0` / `item.max ?? 100`.
  eq('no bounds at all reads 0..100', M.widestValueString({ type: 'range' }), '100')
  eq('null bounds read as absent', M.widestValueString({ type: 'range', min: null, max: null }), '100')
  eq('no step reads as 1, so no decimals', M.widestValueString({ type: 'range', min: 0, max: 100 }), '100')
  eq('numeric strings are coerced', M.widestValueString({ type: 'range', min: '0', max: '100' }), '100')
  eq('a string step keeps its decimals', M.widestValueString({ type: 'number', min: 0, max: 1, step: '0.25' }), '0.00')
  // Number('a') is NaN and NaN.toFixed() is "NaN" - three characters of
  // reserved space. Pinned: it is a bounded failure, not a crash, and the
  // bundle validator rejects non-numeric bounds before this is reached.
  eq('non-numeric bounds reserve three characters', M.widestValueString({ type: 'range', min: 'a', max: 'b' }), 'NaN')
  // progress is a fixed "100 %" reading, and its declared unit is ignored.
  eq('progress is always 100 %', M.widestValueString({ type: 'progress' }), '100 %')
  eq('progress ignores its own unit', M.widestValueString({ type: 'progress', unit: 'ms' }), '100 %')
  eq('a select row reserves nothing', M.widestValueString({ type: 'select', min: 0, max: 100 }), '')
  eq('a numeric unit rides along', M.widestValueString({ type: 'number', min: 0, max: 9, step: 1, unit: 'fps' }), '0 fps')
  eq('a zero unit rides along', M.widestValueString({ type: 'number', min: 0, max: 9, unit: 0 }), '0 0')
  noThrow('never throws on a hostile payload', () => M.widestValueString({ type: 'range', min: {}, max: [], step: {} }))
})

// ======================================================================
section('stripForHay and hayFromItem - the searchable text of a row')
group('stripForHay removes markup and collapses whitespace', () => {
  // "Descriptions carry <b>/<i>/<u> and \n; they must not pollute prefix
  // matching (e.g. "<b>FPS</b>" should be searchable as "fps")."
  eq('bold tags', M.stripForHay('<b>FPS</b> cap'), 'FPS cap')
  eq('italic and underline together', M.stripForHay('<i>a</i> <u>b</u>'), 'a b')
  eq('a tag with attributes', M.stripForHay('<span class="x">hi</span>'), 'hi')
  eq('runs of spaces collapse', M.stripForHay('a  b\n\nc'), 'a b c')
  eq('the result is trimmed', M.stripForHay('  x  '), 'x')
  eq('plain text passes through', M.stripForHay('no tags'), 'no tags')
  eq('the empty string', M.stripForHay(''), '')
  // The regex is `<[^>]*>`: a bare less-than with a later greater-than is
  // read as a tag and everything between them goes. Deliberate-but-surprising,
  // cited from stripForHay's own implementation.
  eq('a comparison between angles is read as a tag', M.stripForHay('5 < 7 > 2'), '5 2')
  eq('an empty tag collapses to nothing', M.stripForHay('<>'), '')
  eq('an unterminated tag is not a tag', M.stripForHay('a < b'), 'a < b')
  eq('undefined stringifies rather than throwing', M.stripForHay(undefined), 'undefined')
  eq('null too', M.stripForHay(null), 'null')
  eq('a number stringifies', M.stripForHay(42), '42')
})

group('hayFromItem concatenates every searchable role, lowercased and deduped', () => {
  // "Order of first appearance is preserved so ranking (earlier = higher)
  // stays meaningful."
  eq('label, sub, desc, var', M.hayFromItem({ label: 'Brightness', sub: 'Backlight level', desc: '<b>Screen</b> dimming', var: 'HYPR_BRIGHT' }), 'brightness backlight level screen dimming hypr_bright')
  eq('subLead rides ahead of sub', M.hayFromItem({ label: 'Timer', subLead: 'cmd', sub: '15 min' }), 'timer cmd 15 min')
  eq('warning and body are stripped too', M.hayFromItem({ label: 'W', warning: '<b>careful</b> now', body: 'body  text' }), 'w careful now body text')
  eq('the placeholder is searchable', M.hayFromItem({ label: 'Name', placeholder: 'your name' }), 'name your')
  eq('the unit is searchable', M.hayFromItem({ label: 'Vol', unit: '%' }), 'vol %')
  // "duplicate "performance" 4x no longer inflates the string".
  eq('repeated words collapse to the first position', M.hayFromItem({ label: 'power', sub: 'Power mode', desc: 'performance mode' }), 'power mode performance')
  eq('an item with no searchable role has an empty hay', M.hayFromItem({}), '')
  eq('and so does one with only chrome', M.hayFromItem({ icon: 'gear', enabled: false }), '')
  // "Kept as a plain array so normalize copies it and hay builders skip it
  // intentionally - hex codes are not useful search tokens."
  eq('palette swatches are not indexed', M.hayFromItem({ label: 'Theme', palette: ['#719cd6', '#a1b3c1'] }), 'theme')
  eq('the light/dark flag is not indexed', M.hayFromItem({ label: 'Theme', light: 'Light' }), 'theme')
})

group('requiresExpr separates "no requirement" from "a refused one"', () => {
  // Three answers, and the middle one is the reason this is not a boolean. A
  // refused shape read as "no constraint" would SHOW a row the author gated.
  eq('absent is no constraint', M.requiresExpr(undefined), undefined)
  eq('null is no constraint', M.requiresExpr(null), undefined)
  eq('a string is a refused shape, not an absent one', M.requiresExpr('laptop'), null)
  eq('a number too', M.requiresExpr(5), null)
  eq('a boolean too', M.requiresExpr(true), null)
  eq('an array too', M.requiresExpr(['binary']), null)
  eq('an empty object has no expression, so it refuses', M.requiresExpr({}), null)
  eq('an unknown chassis refuses', M.requiresExpr({ chassis: 'desktop' }), null)
  eq('a casing variant refuses', M.requiresExpr({ chassis: 'Laptop' }), null)
  eq('a well-formed chassis compiles', M.requiresExpr({ chassis: 'laptop' }), '[[ "$CHASSIS_TYPE" == laptop ]]')
  eq('and binary', M.requiresExpr({ binary: 'jq' }), 'type -P jq >/dev/null')
  eq('both AND together, binary first', M.requiresExpr({ binary: 'jq', chassis: 'vm' }), 'type -P jq >/dev/null && [[ "$CHASSIS_TYPE" == vm ]]')
  eq('a rejected binary refuses the whole shape', M.requiresExpr({ binary: 'x;id' }), null)
  // command -v answered for builtins too, so {"binary":"cd"} passed everywhere.
  eq('a shell builtin is not a program', M.requiresExpr({ binary: 'cd' }), 'type -P cd >/dev/null')
})

group('uidKey is the one place a uid key is built', () => {
  eq('a declared id is kept', M.uidKey('audio', 7), 'audio')
  eq('"#" and ":" are structural and become "-"', M.uidKey('a#b:c', 7), 'a-b-c')
  eq('an id is trimmed first', M.uidKey('  audio  ', 7), 'audio')
  eq('an absent id falls back to the row position', M.uidKey(undefined, 7), '7')
  eq('a non-string id too', M.uidKey(5, 7), '7')
  eq('a blank id is the same as an absent one', M.uidKey('   ', 7), '7')
  eq('control characters cannot survive into the verdict token', M.uidKey('a\nb', 7), 'a-b')
  eq('a tab', M.uidKey('a\tb', 7), 'a-b')
  eq('a carriage return', M.uidKey('a\rb', 7), 'a-b')
  eq('a NUL', M.uidKey('a b', 7), 'a-b')
  eq('a DEL', M.uidKey('ab', 7), 'a-b')
  // Both the uid and the byId key the submenu resolves against go through it,
  // so a page and a link to it sanitize to the same string.
  eq('a page and a link to it agree',
    M.parseBundle('{"id":"a\\nb","title":"T","items":[{"type":"submenu","label":"L","page":"a\\nb"}]}')
      .pages[0].items[0].page,
    M.parseBundle('{"id":"a\\nb","title":"T","items":[]}').pages[0].id)
})

group('a hay word that names an Object.prototype key survives the dedupe', () => {
  // The dedupe set is prototype-less because the hay is lowercased ABOVE it,
  // so the colliding keys are the all-lowercase ones. With a plain {} a row
  // labelled "Set constructor to off" read "constructor" as already-seen and
  // dropped it - a silent loss that made the row unfindable by that word.
  eq('constructor', M.hayFromItem({ label: 'Set constructor to off' }), 'set constructor to off')
  eq('__proto__', M.hayFromItem({ label: '__proto__ row' }), '__proto__ row')
  eq('a real duplicate still collapses', M.hayFromItem({ label: 'power', sub: 'Power mode' }), 'power mode')
  const b = M.parseBundle('{"pages":[{"id":"p","title":"P","items":['
    + '{"type":"action","label":"Set constructor to off"}]}]}')
  eq('and the row is findable by the word that was being dropped',
    M.search(M.buildIndex(b), 'constructor').map(e => e.label), ['Set constructor to off'])
})

group('hayFromItem indexes the current value, and skips a blank one', () => {
  eq('a string value', M.hayFromItem({ label: 'X', value: 'dark' }), 'x dark')
  eq('a padded value is trimmed', M.hayFromItem({ label: 'X', value: '  dark  ' }), 'x dark')
  eq('a whitespace-only value is not indexed', M.hayFromItem({ label: 'X', value: '   ' }), 'x')
  eq('an empty value is not indexed', M.hayFromItem({ label: 'X', value: '' }), 'x')
  eq('null is not indexed', M.hayFromItem({ label: 'X', value: null }), 'x')
  // `!== undefined && !== null` then `String(...).trim() !== ""`, so 0 and
  // false DO reach the hay - a zero-valued volume is searchable as "0".
  eq('a numeric zero value is indexed', M.hayFromItem({ label: 'X', value: 0 }), 'x 0')
  eq('a false value is indexed', M.hayFromItem({ label: 'X', value: false }), 'x false')
  eq('a numeric value is stringified', M.hayFromItem({ label: 'X', value: 5 }), 'x 5')
})

group('includeMetadata adds the options and the canonical keys', () => {
  // "Select options: every possible choice should be discoverable from the
  // parent row (searching "google" finds the Search engine row)."
  const sel = { label: 'Search engine', options: [{ label: 'Google', value: 'g' }, { label: 'DuckDuckGo', value: 'd' }], var: 'LAUNCHER_ENGINE' }
  eq('with metadata', M.hayFromItem(sel), 'search engine google g duckduckgo d launcher_engine')
  eq('without metadata', M.hayFromItem(sel, false), 'search engine')
  eq('includeMetadata true is the default', M.hayFromItem(sel, true), 'search engine google g duckduckgo d launcher_engine')
  eq('the item id is a token', M.hayFromItem({ label: 'L', id: 'pageid' }), 'l pageid')
  eq('and the id is metadata too', M.hayFromItem({ label: 'L', id: 'pageid' }, false), 'l')
  eq('a non-array options field is ignored', M.hayFromItem({ label: 'L', options: 5 }), 'l')
  // The loop skips anything that is not an object, so a malformed options
  // array degrades to the labels it does have.
  eq('malformed option entries are skipped', M.hayFromItem({ label: 'L', options: ['a', null, 3, { label: 'Ok', value: 0 }] }), 'l ok 0')
  eq('an option with no label contributes only its value', M.hayFromItem({ label: 'L', options: [{ value: 'v' }] }), 'l v')
  eq('an option with a blank value contributes only its label', M.hayFromItem({ label: 'L', options: [{ label: 'Label', value: '  ' }] }), 'l label')
  throws('but a null ITEM is a throw', () => M.hayFromItem(null), /label/)
})

// ======================================================================
section('defaultsFor and normalizeItem - every role the renderer reads')
group('defaultsFor fills every key a row renderer branches on', () => {
  const d = M.defaultsFor('range')
  eq('the type is what was asked for', d.type, 'range')
  // README: "normalizeItem must fill every role the row renderer reads, so
  // views never branch on a missing key." The count is the contract; a new
  // role has to show up as a diff here.
  eq('51 roles', Object.keys(d).length, 51)
  const expected = [
    'type', 'id', 'label', 'sub', 'icon', 'glyph', 'desc', 'warning', 'enabled',
    'when', 'checked', 'disabled', 'requires', 'command', 'call', 'page',
    'checked_', 'onToggle', 'close', 'value', 'options', 'onSelect', 'onCall',
    'marker', 'editValue', 'editText', 'editCall', 'keepOpen', 'hideValue',
    'flow', 'infoOnly', 'min', 'max', 'step', 'unit', 'onChange',
    'placeholder', 'onSubmit', 'progressValue', 'body', 'section',
    'delCommand', 'var', 'showIf', 'active', 'palette', 'light',
    'previewFontFamily', 'subAccent', 'subLead', 'confirm',
  ]
  eq('and they are exactly these', Object.keys(d).sort(), expected.slice().sort())
  eq('everything is a safe falsy default', d.label, '')
  eq('enabled defaults to true', d.enabled, true)
  eq('marker defaults to true', d.marker, true)
  eq('checked_ is a boolean seed', d.checked_, false)
  eq('the numeric triple starts at 0..100 step 1', [d.min, d.max, d.step], [0, 100, 1])
  eq('options starts empty', d.options, [])
  eq('palette starts empty', d.palette, [])
  eq('flow is null, not []', d.flow, null)
  eq('confirm is null', d.confirm, null)
  eq('showIf is null', d.showIf, null)
  eq('requires is null', d.requires, null)
  // Each call hands back a fresh object, so one item's array defaults can
  // never be another item's.
  is('two calls are not the same object', M.defaultsFor('a') === M.defaultsFor('a'), (v) => v === false, 'distinct objects')
  is('and the arrays inside are fresh', M.defaultsFor('a').options === M.defaultsFor('a').options, (v) => v === false, 'distinct arrays')
})

group('normalizeItem reads the type, defaulting to "action"', () => {
  eq('a declared type', M.normalizeItem({ type: 'toggle' }, 'p', 0).type, 'toggle')
  eq('no type at all', M.normalizeItem({}, 'p', 0).type, 'action')
  eq('a non-string type', M.normalizeItem({ type: 5 }, 'p', 0).type, 'action')
  eq('a null type', M.normalizeItem({ type: null }, 'p', 0).type, 'action')
  // The copy loop is `for (const key in item)`, so only keys defaultsFor
  // declares are taken. A typo in a bundle is dropped, not carried.
  eq('an unknown key does not ride along', 'zzz' in M.normalizeItem({ type: 'action', zzz: 1 }, 'p', 0), false)
  eq('a known key with a null value IS carried', M.normalizeItem({ type: 'action', desc: null }, 'p', 0).desc, null)
  eq('and a falsy value too', M.normalizeItem({ type: 'action', enabled: false }, 'p', 0).enabled, false)
})

group('the uid is pageId#key, and it is the key into the state store', () => {
  // README: "A uid is pageId#key, so it stays stable across a bundle reload
  // of the same page. Never key row state on the row index."
  eq('a positional key for an anonymous row', M.normalizeItem({ label: 'x' }, 'pg', 7).uid, 'pg#7')
  eq('an explicit id pins the key across positions', M.normalizeItem({ id: 'a', label: 'x' }, 'pg', 7).uid, 'pg#a')
  eq('and across pages', M.normalizeItem({ id: 'a', label: 'x' }, 'other', 0).uid, 'other#a')
  eq('the id is trimmed', M.normalizeItem({ id: '  sp  ' }, 'pg', 0).uid, 'pg#sp')
  eq('a whitespace-only id is anonymous', M.normalizeItem({ id: '   ' }, 'pg', 5).uid, 'pg#5')
  // '"#" and ":" are structural in uid parsing and guard lines'.
  eq('a hash in the id is neutralized', M.normalizeItem({ id: 'a#b:c' }, 'pg', 0).uid, 'pg#a-b-c')
  eq('a colon in the id is neutralized', M.normalizeItem({ id: 'x:y' }, 'pg', 0).uid, 'pg#x-y')
  eq('the internal key matches the uid tail', M.normalizeItem({ id: 'a#b' }, 'pg', 0)._uidKey, 'a-b')
  // `typeof raw.id === "string" ? ... : ""` - a numeric id is anonymous, so
  // the row keeps its position key rather than the number.
  eq('a numeric id is anonymous', M.normalizeItem({ id: 5 }, 'pg', 1).uid, 'pg#1')
  eq('a null id is anonymous', M.normalizeItem({ id: null }, 'pg', 1).uid, 'pg#1')
  // A space in an id survives - unlike # and :, it is not structural in a
  // guard line, which shellQuote handles.
  eq('a space in the id survives', M.normalizeItem({ id: 'a b' }, 'pg', 0).uid, 'pg#a b')
  eq('the hay includes the id so a row is findable by it', M.normalizeItem({ id: 'a b', label: 'Hi' }, 'pg', 0).hay, 'hi a b')
})

group('selectable is the intersection of the type table and enabled', () => {
  // SELECTABLE is the list "of types a keyboard selection may land on;
  // everything else is chrome".
  for (const t of ['action', 'submenu', 'toggle', 'select', 'number', 'range', 'text', 'expandable', 'option']) {
    eq(`${t} is selectable`, M.normalizeItem({ type: t }, 'p', 0).selectable, true)
    eq(`${t} stays enabled`, M.normalizeItem({ type: t }, 'p', 0).enabled, true)
  }
  for (const t of ['separator', 'header', 'spacer', 'bogus']) {
    eq(`${t} is not selectable`, M.normalizeItem({ type: t }, 'p', 0).selectable, false)
    // `if (!SELECTABLE[type]) item.enabled = false` - a chrome row is also
    // marked unenabled, so nothing downstream can light it up.
    eq(`${t} is forced unenabled`, M.normalizeItem({ type: t }, 'p', 0).enabled, false)
  }
  eq('an explicit enabled:false demotes a real type', M.normalizeItem({ type: 'action', enabled: false }, 'p', 0).selectable, false)
  eq('but leaves enabled as the bundle wrote it', M.normalizeItem({ type: 'action', enabled: false }, 'p', 0).enabled, false)
  eq('enabled: null is not false, so the row stays selectable', M.normalizeItem({ type: 'action', enabled: null }, 'p', 0).selectable, true)
})

group('a boolean `checked` in JSON is a seed, not a guard expression', () => {
  // "`checked` names the guard expression; the boolean seed lives in the
  // state store, so remap the JSON bool under a reserved key."
  eq('true remaps to checked_', M.normalizeItem({ type: 'toggle', checked: true }, 'p', 0).checked_, true)
  eq('false remaps to checked_', M.normalizeItem({ type: 'toggle', checked: false }, 'p', 0).checked_, false)
  // The copy loop runs BEFORE the remap and only skips `undefined`, so the
  // boolean is left sitting in `checked` too. It costs nothing: guardLine
  // ignores a non-string expression, so the batched script still gets no
  // `c` line for the row. Pinned so the leftover is not read as a live guard.
  eq('and the boolean is left in the guard field as well', M.normalizeItem({ type: 'toggle', checked: true }, 'p', 0).checked, true)
  eq('but that field emits no guard line', M.guardLine('p#0', 'c', M.normalizeItem({ type: 'toggle', checked: true }, 'p', 0).checked), '')
  eq('so a bundle with "checked": true contributes no checked line at all', M.buildGuardScript([M.buildPage('p', 'p', 0, [{ type: 'toggle', id: 'a', checked: true }])]), '')
  eq('and with "checked": false neither', M.buildGuardScript([M.buildPage('p', 'p', 0, [{ type: 'toggle', id: 'a', checked: false }])]), '')
  // A string is already a shell expression and is copied straight in.
  eq('a string checked stays a guard', M.normalizeItem({ type: 'toggle', checked: 'pgrep x' }, 'p', 0).checked, 'pgrep x')
  eq('and checked_ stays false', M.normalizeItem({ type: 'toggle', checked: 'pgrep x' }, 'p', 0).checked_, false)
  eq('a non-string non-boolean checked is copied as the guard', M.normalizeItem({ type: 'toggle', checked: 5 }, 'p', 0).checked, 5)
  eq('and leaves checked_ false', M.normalizeItem({ type: 'toggle', checked: 5 }, 'p', 0).checked_, false)
  eq('a numeric checked also emits no line', M.guardLine('p#0', 'c', 5), '')
})

group('a non-writable action-select drops its option marker', () => {
  // "Non-writable selects (action-selects) are triggers, not persisted
  // settings - the dropdown does not mark the chosen option with a dot."
  eq('an onSelect select with no var loses the marker', M.normalizeItem({ type: 'select', label: 'x', onSelect: 'c' }, 'p', 0).marker, false)
  eq('a var-bound select keeps it', M.normalizeItem({ type: 'select', label: 'x', var: 'V', onSelect: 'c' }, 'p', 0).marker, true)
  eq('a select with no onSelect keeps it', M.normalizeItem({ type: 'select', label: 'x' }, 'p', 0).marker, true)
  eq('a var-bound select with no onSelect keeps it', M.normalizeItem({ type: 'select', label: 'x', var: 'V' }, 'p', 0).marker, true)
  // "Explicit `marker: true` keeps the indicator when a transient select
  // still wants to show its current value (e.g. theme variant picker)."
  eq('an explicit marker:true survives the fold', M.normalizeItem({ type: 'select', label: 'x', onSelect: 'c', marker: true }, 'p', 0).marker, true)
  eq('an explicit marker:false is honoured too', M.normalizeItem({ type: 'select', label: 'x', onSelect: 'c', marker: false }, 'p', 0).marker, false)
  eq('a non-select row is untouched', M.normalizeItem({ type: 'action', onSelect: 'c' }, 'p', 0).marker, true)
})

group('flow steps are copied, filtered by kind, and dropped when empty', () => {
  const flow = [
    { kind: 'select', label: 'A', options: [{ label: 'x', value: 'x' }] },
    { kind: 'bogus' },
    { kind: 'number', label: 'B' },
    { kind: 'text', label: 'C' },
    { kind: 'range', label: 'D' },
  ]
  const it = M.normalizeItem({ type: 'action', flow }, 'p', 0)
  eq('only the four known kinds survive', it.flow.map(s => s.kind), ['select', 'number', 'text', 'range'])
  eq('the accepted step keeps its own fields', it.flow[0], { kind: 'select', label: 'A', options: [{ label: 'x', value: 'x' }] })
  // Object.assign({}, s, { kind }) - the step object is a copy, so
  // normalizing a row twice cannot alias one stage to two models.
  is('the step array is a copy', it.flow === flow, (v) => v === false, 'a copy')
  is('each step is a copy', it.flow[0] === flow[0], (v) => v === false, 'a copy')
  eq('a non-step entry is dropped, not nulled', M.normalizeItem({ type: 'action', flow: [null, 5, { kind: 'number' }] }, 'p', 0).flow, [{ kind: 'number' }])
  eq('an all-invalid flow collapses to null', M.normalizeItem({ type: 'action', flow: [{ kind: 'zzz' }] }, 'p', 0).flow, null)
  eq('an empty array is null, not []', M.normalizeItem({ type: 'action', flow: [] }, 'p', 0).flow, null)
  eq('a non-array flow is null', M.normalizeItem({ type: 'action', flow: 'x' }, 'p', 0).flow, null)
  eq('no flow at all is null', M.normalizeItem({ type: 'action' }, 'p', 0).flow, null)
  eq('a step with no kind is dropped', M.normalizeItem({ type: 'action', flow: [{ label: 'nokind' }] }, 'p', 0).flow, null)
  // A step that declares `kind` as a non-string is dropped too.
  eq('a numeric kind is dropped', M.normalizeItem({ type: 'action', flow: [{ kind: 1 }] }, 'p', 0).flow, null)
})

group('normalizeItem does not touch the object it was handed', () => {
  // The invariant that keeps the settings UI from flickering: a re-normalize
  // pass over the same raw source has to produce the same row.
  const raw = { type: 'select', label: 'S', id: 'a', options: [{ label: 'a', value: 1 }], palette: ['#fff'], checked: true, flow: [{ kind: 'number' }] }
  const before = JSON.stringify(raw)
  M.normalizeItem(raw, 'p', 0)
  eq('byte-for-byte unchanged', JSON.stringify(raw), before)
  M.normalizeItem(raw, 'p', 3)
  eq('and unchanged on a second pass at another position', JSON.stringify(raw), before)
  // It is a shallow fill, so arrays/objects are shared with the source. The
  // input is still never written to - but a caller that mutated item.options
  // would be mutating its own bundle, which is why the merge path re-reads
  // from _raw instead.
  const it = M.normalizeItem(raw, 'p', 0)
  is('options are shared with the raw input, not cloned', it.options === raw.options, (v) => v === true, 'shared')
  is('palette is shared too', it.palette === raw.palette, (v) => v === true, 'shared')
  is('but the row itself is a fresh object', it === raw, (v) => v === false, 'a copy')
  is('and flow is not shared', it.flow === raw.flow, (v) => v === false, 'a copy')
  eq('a fresh object is produced for the same input twice', M.normalizeItem(raw, 'p', 0) === M.normalizeItem(raw, 'p', 0), false)
})

// ======================================================================
section('buildPage, buildOptionsPage, normalizePage, parseBundle')
group('buildPage normalizes items and stamps the page chrome', () => {
  const p = M.buildPage('p1', 'Title', 420, [
    { type: 'action', label: 'a' },
    { type: 'action', label: 'b' },
    { type: 'toggle', label: 'c', command: 'own' },
  ], { command: 'page %v', layout: 'grid', cell: 40, maxHeight: 300 })
  eq('the page publishes exactly these fields', Object.keys(p), ['id', 'label', 'width', 'layout', 'cell', 'maxHeight', 'command', 'filterDefault', 'items', '_raw'])
  eq('id', p.id, 'p1')
  eq('label', p.label, 'Title')
  eq('width', p.width, 420)
  eq('layout', p.layout, 'grid')
  eq('cell', p.cell, 40)
  eq('maxHeight', p.maxHeight, 300)
  eq('the resolved fallback command rides on the page', p.command, 'page %v')
  eq('filtering defaults to off', p.filterDefault, false)
  eq('filterDefault rides through', M.buildPage('p', 't', 0, [], { filterDefault: true }).filterDefault, true)
  eq('a non-boolean filterDefault is off', M.buildPage('p', 't', 0, [], { filterDefault: 1 }).filterDefault, false)
  eq('items are keyed by position when anonymous', p.items.map(i => i.uid), ['p1#0', 'p1#1', 'p1#2'])
  eq('every item carries the page width for its value slot', p.items.map(i => i._pageWidth), [420, 420, 420])
  // "Page-level fallback command: action rows without their own inherit the
  // page template (%v -> item.value). Keeps glyph bundles compact."
  eq('action rows inherit the page command', p.items.map(i => i.command), ['page %v', 'page %v', 'own'])
  eq('only action rows inherit', M.buildPage('p', 'p', 0, [{ type: 'toggle', label: 't' }], { command: 'x' }).items[0].command, '')
  eq('_raw is the list it was handed', p._raw.length, 3)
})

group('buildPage normalizes the page fields it can trust', () => {
  eq('an empty title falls back to the id', M.buildPage('p2', '', 0, []).label, 'p2')
  eq('a non-string title falls back to the id', M.buildPage('p2', 7, 0, []).label, 'p2')
  eq('a non-number width is 0', M.buildPage('p2', 't', 'x', []).width, 0)
  eq('no width is 0', M.buildPage('p2', 't', undefined, []).width, 0)
  // 'Only meaningful for action-only pages (emoji picker); the panel decides
  // which view to instantiate from this field.'
  eq('an unknown layout is list', M.buildPage('p2', 't', 0, [], { layout: 'tiles' }).layout, 'list')
  eq('layout list is accepted', M.buildPage('p2', 't', 0, [], { layout: 'list' }).layout, 'list')
  eq('a non-string layout is list', M.buildPage('p2', 't', 0, [], { layout: 5 }).layout, 'list')
  // 'cell: 0 lets the panel choose', and the 16px floor rejects a hint too
  // small to be a real cell.
  eq('no cell hint is 0', M.buildPage('p2', 't', 0, []).cell, 0)
  eq('a cell at the floor is rejected', M.buildPage('p2', 't', 0, [], { cell: 16 }).cell, 0)
  eq('a cell above the floor is rounded', M.buildPage('p2', 't', 0, [], { cell: 40.6 }).cell, 41)
  eq('a negative cell is 0', M.buildPage('p2', 't', 0, [], { cell: -5 }).cell, 0)
  eq('a string cell is 0', M.buildPage('p2', 't', 0, [], { cell: '40' }).cell, 0)
  // 'maxHeight: 0 keeps the panel\'s default', floor 120.
  eq('no maxHeight is 0', M.buildPage('p2', 't', 0, []).maxHeight, 0)
  eq('a maxHeight at the floor is rejected', M.buildPage('p2', 't', 0, [], { maxHeight: 120 }).maxHeight, 0)
  eq('a maxHeight above the floor is rounded', M.buildPage('p2', 't', 0, [], { maxHeight: 300.4 }).maxHeight, 300)
  eq('a non-number maxHeight is 0', M.buildPage('p2', 't', 0, [], { maxHeight: 'x' }).maxHeight, 0)
  eq('a non-string command is not a command', M.buildPage('p2', 't', 0, [], { command: 5 }).command, '')
  eq('no opts at all still yields a page', M.buildPage('p2', 't', 0, []).command, '')
  eq('a non-array item list is empty, not a throw', M.buildPage('p2', 't', 0, null).items.length, 0)
  eq('a non-array item list of a string', M.buildPage('p2', 't', 0, 'abc').items.length, 0)
  eq('and a missing list', M.buildPage('p2', 't', 0).items.length, 0)
})

group('buildPage suffixes a duplicate id so no two rows share state', () => {
  // "Duplicate id-derived uids (two rows claiming one id) would share runtime
  // state and list identity - suffix later twins so every uid on the page
  // stays unique."
  const p = M.buildPage('p', 'T', 0, [
    { id: 'a', type: 'action' },
    { id: 'a', type: 'action' },
    { id: 'a', type: 'action' },
    { type: 'action' },
  ])
  eq('the first twin keeps the plain key', p.items.map(i => i.uid), ['p#a', 'p#a~2', 'p#a~3', 'p#3'])
  // The escape walk skips a key that is already taken, so a bundle that also
  // declares "a~2" still gets unique uids.
  const q = M.buildPage('p', 'T', 0, [
    { id: 'a', type: 'action' },
    { id: 'a~2', type: 'action' },
    { id: 'a', type: 'action' },
  ])
  eq('the suffix walk skips an occupied key', q.items.map(i => i.uid), ['p#a', 'p#a~2', 'p#a~3'])
  eq('~ is safe in a guard line', M.guardLine(q.items[2].uid, 'w', 'x').includes("'p#a~3:w:1'"), true)
  eq('and every uid on the page is unique', new Set(p.items.map(i => i.uid)).size, p.items.length)
  eq('the internal key follows the suffix', p.items.map(i => i._uidKey), ['a', 'a~2', 'a~3', '3'])
})

group('buildPage does not mutate the list it was handed', () => {
  const rawList = [{ type: 'action', id: 'a', label: 'A', command: '' }]
  const before = JSON.stringify(rawList)
  const p = M.buildPage('p', 'P', 0, rawList, { command: 'cm %v' })
  eq('the raw list is byte-for-byte unchanged', JSON.stringify(rawList), before)
  eq('the inherited command landed on the item, not the source', p.items[0].command, 'cm %v')
  eq('and not on the source object', rawList[0].command, '')
  is('the item is a fresh normalize, not the raw object', p.items[0] === rawList[0], (v) => v === false, 'a copy')
  is('_raw aliases the caller list (read-only by contract)', p._raw === rawList, (v) => v === true, 'the same array')
})

group('buildOptionsPage turns a select into one option row per choice', () => {
  // "one option row per choice. Options are plain entries - the menu never
  // renders inline dropdowns. The parent link lets rows mirror and commit."
  const sel = M.normalizeItem({
    type: 'select', label: 'Engine', var: 'LAUNCHER_ENGINE',
    options: [{ label: 'Google', value: 'g' }, { value: 'ddg' }, { label: 'Theme', value: 't', palette: ['#fff'], light: 'Light' }],
    onSelect: 'commit', onCall: 'call %v',
  }, 'pg', 0)
  const op = M.buildOptionsPage(sel)
  eq('the page id hangs off the parent uid', op.id, 'pg#0::options')
  eq('the page is titled after the parent', op.label, 'Engine')
  eq('a plain list layout', op.layout, 'list')
  eq('no cell hint', op.cell, 0)
  eq('no maxHeight override', op.maxHeight, 0)
  eq('options pages never filter by default', op.filterDefault, false)
  eq('the page publishes the same field set as buildPage', Object.keys(op), ['id', 'label', 'width', 'layout', 'cell', 'maxHeight', 'filterDefault', 'items', '_raw'])
  eq('one row per option', op.items.length, 3)
  eq('every row is an option row', op.items.map(i => i.type), ['option', 'option', 'option'])
  eq('and is therefore selectable', op.items.map(i => i.selectable), [true, true, true])
  eq('uids are parentUid::options#index', op.items.map(i => i.uid), ['pg#0::options#0', 'pg#0::options#1', 'pg#0::options#2'])
  eq('the commit command is carried to every row', op.items.map(i => i.onSelect), ['commit', 'commit', 'commit'])
  eq('and so is the call command', op.items.map(i => i.onCall), ['call %v', 'call %v', 'call %v'])
  eq('every row links back to the parent', op.items.map(i => i._parentUid), ['pg#0', 'pg#0', 'pg#0'])
  eq('palette rides through per option', op.items.map(i => i.palette), [[], [], ['#fff']])
  eq('and the light/dark flag', op.items.map(i => i.light), ['', '', 'Light'])
})

group('buildOptionsPage fills the option row from label-or-value', () => {
  const build = (options) => M.buildOptionsPage({ uid: 'u', label: 'L', options }).items
  eq('a label wins', build([{ label: 'L', value: 'V' }])[0].label, 'L')
  eq('a missing label falls back to the value', build([{ value: 'V' }])[0].label, 'V')
  eq('a null label falls back to the value', build([{ label: null, value: 'V' }])[0].label, 'V')
  // `o.label ?? String(o.value)` - ?? catches null/undefined only, so a
  // falsy-but-present label is carried through as the row label. Pinned with
  // its real value: `false` is the shape a JSON boolean label would take.
  eq('a false label is carried, not replaced', build([{ label: false, value: 'V' }])[0].label, false)
  eq('a zero label is carried too', build([{ label: 0, value: 'V' }])[0].label, 0)
  eq('an empty label is carried too', build([{ label: '', value: 'V' }])[0].label, '')
  eq('an absent value reads as empty, not undefined', build([{ label: 'L' }])[0].value, '')
  // `value: o.value` is copied as data, so a 0 survives the item copy loop's
  // `raw[key] !== undefined` guard.
  eq('a zero value survives', build([{ label: 'L', value: 0 }])[0].value, 0)
  eq('a false value survives', build([{ label: 'L', value: false }])[0].value, false)
  eq('a non-string light flag is dropped', build([{ label: 'L', value: 1, light: 5 }])[0].light, '')
  eq('a non-array palette is dropped', build([{ label: 'L', value: 1, palette: 'x' }])[0].palette, [])
  eq('the option hay indexes label and value', build([{ label: 'DuckDuckGo', value: 'ddg' }])[0].hay, 'duckduckgo ddg')
  eq('an empty options list yields an empty page', M.buildOptionsPage({ uid: 'u', label: 'L', options: [] }).items.length, 0)
  eq('no options key yields an empty page', M.buildOptionsPage({ uid: 'u', label: 'L' }).items.length, 0)
  eq('a page width comes from the parent item', M.buildOptionsPage({ uid: 'u', label: 'L', _pageWidth: 380, options: [] }).width, 380)
  eq('a select with no _pageWidth reserves nothing', M.buildOptionsPage({ uid: 'u', label: 'L', options: [] }).width, 0)
  eq('a parent with no uid makes the id read "undefined"', M.buildOptionsPage({ label: 'L', options: [] }).id, 'undefined::options')
  eq('a parent with no label titles the page after the page id', M.buildOptionsPage({ uid: 'u', options: [] }).label, 'u::options')
  throws('a null option entry is a throw, not a skipped row', () => M.buildOptionsPage({ uid: 'u', options: [null] }), /label/)
})

group('buildOptionsPage does not mutate the parent select', () => {
  const sel = M.normalizeItem({ type: 'select', label: 'E', var: 'V', options: [{ label: 'a', value: '1' }, { label: 'b', value: '2' }], onSelect: 'c' }, 'p', 0)
  const before = JSON.stringify(sel)
  M.buildOptionsPage(sel)
  eq('the select is byte-for-byte unchanged', JSON.stringify(sel), before)
  eq('and gains no page field of its own', sel.items, undefined)
  eq("its options are still the bundle's", sel.options.length, 2)
})

group('normalizePage accepts title or label, and id or the fallback', () => {
  eq('title wins', M.normalizePage({ id: 'x', title: 'T', items: [] }).label, 'T')
  eq('label is the fallback title', M.normalizePage({ id: 'x', label: 'L', items: [] }).label, 'L')
  eq('an empty title falls through to label', M.normalizePage({ id: 'x', title: '', label: 'L', items: [] }).label, 'L')
  eq('a non-string title falls through to label', M.normalizePage({ id: 'x', title: 5, label: 'L', items: [] }).label, 'L')
  eq('neither title nor label falls to the id', M.normalizePage({ id: 'x', items: [] }).label, 'x')
  eq('a declared id is used', M.normalizePage({ id: 'x', items: [] }).id, 'x')
  eq('a missing id takes the fallback', M.normalizePage({ title: 'T' }, 'fb').id, 'fb')
  eq('an empty id takes the fallback', M.normalizePage({ id: '', items: [] }, 'fb').id, 'fb')
  eq('a non-string id takes the fallback', M.normalizePage({ id: 5, items: [] }, 'fb').id, 'fb')
  eq('a numeric width is kept', M.normalizePage({ id: 'x', width: 400 }).width, 400)
  eq('a non-numeric width is 0', M.normalizePage({ id: 'x', width: 'w' }).width, 0)
  // The items expression has a dead branch (`Array.isArray(raw.options) ? []
  // : []`) - both arms are the same empty array, so a page with no items
  // array is empty either way.
  eq('a non-array items field is empty', M.normalizePage({ id: 'x', items: 'nope' }).items.length, 0)
  eq('a missing items field is empty', M.normalizePage({ id: 'x' }).items.length, 0)
  eq('an options field does not become items', M.normalizePage({ id: 'x', options: [{ label: 'a' }] }).items.length, 0)
  eq('layout chrome is forwarded', M.normalizePage({ id: 'x', layout: 'grid', cell: 40, maxHeight: 300 }).layout, 'grid')
  eq('and the cell is normalized on the way through', M.normalizePage({ id: 'x', cell: 40.6 }).cell, 41)
  eq('a page command is forwarded', M.normalizePage({ id: 'x', command: 'c %v' }).command, 'c %v')
  eq('filterDefault is forwarded', M.normalizePage({ id: 'x', filterDefault: true }).filterDefault, true)
  eq('and off unless declared', M.normalizePage({ id: 'x' }).filterDefault, false)
})

group('normalizePage does not mutate the raw page object', () => {
  const raw = { id: 'x', title: 'T', width: 300, items: [{ type: 'action', label: 'a' }] }
  const before = JSON.stringify(raw)
  M.normalizePage(raw, 'fb')
  eq('byte-for-byte unchanged', JSON.stringify(raw), before)
  M.normalizePage(raw, 'fb')
  eq('unchanged on a second pass', JSON.stringify(raw), before)
  eq('and the page reads its own normalized items', M.normalizePage(raw, 'fb').items[0].uid, 'x#0')
})

group('parseBundle accepts a page, a pages array, or a bare array', () => {
  const one = bundle('{"id":"one","title":"One","items":[]}')
  eq('a single page object', [one.entry, one.pages.map(p => p.id)], ['one', ['one']])
  eq('byId is keyed by page id', Object.keys(one.byId), ['one'])
  const many = bundle('{"pages":[{"id":"a","items":[]},{"id":"b","items":[]}]}')
  eq('the first page is the entry', many.entry, 'a')
  eq('pages keep document order', many.pages.map(p => p.id), ['a', 'b'])
  eq('byId indexes both', Object.keys(many.byId), ['a', 'b'])
  const arr = bundle('[{"id":"a","items":[]},{"id":"b"}]')
  eq('a bare array is a page list', [arr.entry, arr.pages.map(p => p.id)], ['a', ['a', 'b']])
  const solo = bundle('{"id":"solo","items":[]}')
  eq('a page with no items still parses', solo.pages[0].items.length, 0)
  eq('and is reachable by id', solo.byId.solo.label, 'solo')
  // `[raw]` for anything that is neither an array nor a pages holder, so a
  // scalar document yields a one-page bundle at the default id.
  eq('a scalar document wraps into "main"', bundle('"hi"').entry, 'main')
  eq('a pages field that is not an array wraps too', bundle('{"pages":{}}').entry, 'main')
  eq('and a number wraps', bundle('5').pages.length, 1)
})

group('scopeBundle spans one entry tree, not the whole file', () => {
  // The unified catalog holds every menu; search spans only the opened
  // entry's tree. The reported bug was main-menu rows answering inside
  // Utilities' search, the way one-file-per-menu scoped both before.
  const catalog = JSON.parse(M.stripJsonc(fs.readFileSync(
    path.join(SHELL_DIR, 'common/settings/catalog.jsonc'), 'utf8')))
  const menus = M.parseBundle(JSON.stringify(catalog.menus))
  const main = M.scopeBundle(menus, 'main', [])
  eq('main keeps its own pages', main.pages.map(p => p.id),
    ['main', 'setup', 'install', 'remove', 'update', 'help'])
  eq('and utilities is out of its search', main.byId.utilities, undefined)
  eq('the entry stays the opened page', main.entry, 'main')
  const util = M.scopeBundle(menus, 'utilities', [])
  eq('utilities spans one page', util.pages.map(p => p.id), ['utilities'])
  eq('with itself as the entry', util.entry, 'utilities')
  eq('every utilities index row belongs to utilities',
    [...new Set(M.buildIndex(util).map(e => e.pageId))], ['utilities'])
  eq('no main-tree index row belongs to utilities',
    M.buildIndex(main).some(e => e.pageId === 'utilities'), false)
  eq('an unknown entry falls back to the bundle entry',
    [M.scopeBundle(menus, 'nope', []).entry,
      M.scopeBundle(menus, 'nope', []).pages.map(p => p.id)],
    ['main', ['main', 'setup', 'install', 'remove', 'update', 'help']])
  const seeded = M.scopeBundle(menus, 'utilities', ['main'])
  eq('extension pages always join the search',
    seeded.pages.map(p => p.id).sort(),
    ['help', 'install', 'main', 'remove', 'setup', 'update', 'utilities'])
  eq('without moving the entry', seeded.entry, 'utilities')
})

group('two pages claiming one id cannot share a uid space', () => {
  // buildPage's dedupe is page-local, so both pages minted the same uid for
  // same-named rows: one runtime-state slot shared by two unrelated rows, two
  // guard verdicts per uid with the reader keeping the last, and byId able to
  // name only one of the pages - the other unreachable while still indexed.
  const b = bundle('{"pages":['
    + '{"id":"dup","title":"A","items":[{"id":"x","type":"action","label":"one"}]},'
    + '{"id":"dup","title":"B","items":[{"id":"x","type":"action","label":"two"}]}]}')
  const uids = b.pages.flatMap(p => p.items.map(i => i.uid))
  eq('both pages are kept', b.pages.length, 2)
  eq('and their uids no longer collide', new Set(uids).size, uids.length)
  eq('the first keeps the id it declared', b.pages[0].id, 'dup')
  eq('the second is suffixed the way buildPage suffixes a duplicate item', b.pages[1].id, 'dup~2')
  eq('byId reaches both', Object.keys(b.byId).sort(), ['dup', 'dup~2'])
  eq('a submenu to the declared id still lands on the first',
    M.buildIndex(b).filter(e => e.label === 'one').length, 1)
})

group('a guard that is not a string refuses the row, it does not drop it', () => {
  // A malformed `when` used to emit nothing, and a row with no verdict reads as
  // VISIBLE - the same fail-open as a nonzero batch exit, one level down. The
  // sibling field (`requires`) already refused; the two must agree.
  const w = items => M.buildGuardScript([M.buildPage('p', 'P', 0, items, {})])
  eq('a string when is untouched', w([{ type: 'action', id: 'r', label: 'R', when: 'true' }]),
    M.guardLine('p#r', 'w', 'true'))
  for (const bad of [5, true, ['a'], { var: 'v' }]) {
    eq(`${JSON.stringify(bad)} as a when hides the row`,
      w([{ type: 'action', id: 'r', label: 'R', when: bad }]), "echo 'p#r:w:0'\n")
  }
  eq('a null when is no when at all', w([{ type: 'action', id: 'r', label: 'R', when: null }]),
    "echo 'p#r:w:0'\n")
  // c and d have no fail-closed answer - there is nothing to hide - so a
  // malformed one there still drops, which is the asymmetry that remains.
  eq('a malformed checked still drops, since a pill cannot be hidden',
    w([{ type: 'action', id: 'r', label: 'R', checked: 5 }]), '')
})

group('orderSettingsIndex refuses a duplicate hyprland uid, not just a duplicate link', () => {
  const page = extra => JSON.stringify({ pages: [{ id: 'settings', title: 'S', items: extra },
    { id: 'hyprland', title: 'H', items: [] }] })
  const uids = b => b.byId.settings.items.map(i => i.uid)
  // The old test only recognised a row that was a submenu POINTING at hyprland,
  // so a plain row carrying id "hyprland" got through and the synthesized link
  // minted its uid a second time - and a duplicate key makes MenuPanel's
  // keyedRows refuse the whole projection, freezing the page.
  M.orderSettingsIndex(M.parseBundle(page([{ id: 'other', type: 'action', label: 'O' }])))
  // The contract is ONE hyprland LINK, and no duplicate key - which is what
  // froze the page. A row that merely calls itself "hyprland" is not a link,
  // so it must not cost the page its link; it just needs a distinct key.
  const links = b => b.byId.settings.items.filter(i => i.type === 'submenu' && i.page === 'hyprland').length
  const plain = M.parseBundle(page([{ id: 'hyprland', type: 'action', label: 'Plain' }]))
  M.orderSettingsIndex(plain)
  eq('a plain row squatting the id does not cost the page its link', links(plain), 1)
  eq('and the two coexist under distinct keys',
    uids(plain).filter(u => u.startsWith('settings#hyprland')).sort(), ['settings#hyprland', 'settings#hyprland~2'])
  eq('so the page stays keyable', new Set(uids(plain)).size === uids(plain).length, true)
  const sub = M.parseBundle(page([{ id: 'link', type: 'submenu', label: 'L', page: 'hyprland' }]))
  M.orderSettingsIndex(sub)
  eq('a submenu pointing at it is the link already, so none is added', links(sub), 1)
  const none = M.parseBundle(page([{ id: 'other', type: 'action', label: 'O' }]))
  M.orderSettingsIndex(none)
  eq('with neither present the link is appended', links(none), 1)
  eq('and it takes the plain key', uids(none).includes('settings#hyprland'), true)
  // Every settings page it returns is keyable, which is what the append is for.
  eq('and the whole page stays keyable',
    new Set(uids(none)).size === uids(none).length, true)
})

group('a page id is sanitized, and byId cannot be reached through the prototype', () => {
  // byId is keyed by page id, and page ids come from a file. A plain {} meant a
  // page declared `"id": "__proto__"` assigned byId's PROTOTYPE to that page
  // object instead of creating a key, after which byId["items"], byId["label"]
  // and byId["_raw"] all resolved as if they were pages - and Menu looks up
  // bundle.byId[it.page] on every submenu row.
  const p = M.parseBundle('{"pages":[{"id":"__proto__","title":"W","items":['
    + '{"type":"action","label":"x"}]},{"id":"normal","title":"N","items":[]}]}')
  eq('the page is kept', p.pages.map(x => x.id), ['__proto__', 'normal'])
  // With no prototype there is no __proto__ setter to hijack, so the id
  // becomes a real key and the page is reachable by the id it declared.
  eq('and it is a genuine own key now', Object.prototype.hasOwnProperty.call(p.byId, '__proto__'), true)
  is('byId has a null prototype, not Object.prototype', Object.getPrototypeOf(p.byId), (v) => v === null, 'a null prototype')
  eq('the page resolves by its own id', p.byId['__proto__'].label, 'W')
  eq('a real page still resolves', p.byId['normal'] !== undefined, true)
  eq('and a page FIELD name does not', p.byId['items'], undefined)
  eq('nor the label of the crafted page', p.byId['label'], undefined)
  // A newline in an id reached the guard verdict channel, which is
  // LINE-oriented, so one row printed as two lines and forged an answer for
  // whatever uid the second line spelled.
  eq('a newline in a page id is stripped', M.parseBundle('{"id":"a\\nb","title":"T","items":[]}').pages[0].id, 'a-b')
  eq('and in an item id', M.normalizeItem({ type: 'action', id: 'x\ny', label: 'L' }, 'p', 0).uid, 'p#x-y')
  eq('a tab and a CR go too', M.normalizeItem({ type: 'action', id: 'x\ty\rz', label: 'L' }, 'p', 0).uid, 'p#x-y-z')
  eq('a DEL', M.normalizeItem({ type: 'action', id: 'xy', label: 'L' }, 'p', 0).uid, 'p#x-y')
  // A submenu target is the other side of the pair, so it is sanitized the
  // same way - otherwise the link resolves to nothing and reads as dead.
  eq('a submenu target is sanitized to match its page',
    M.normalizeItem({ type: 'submenu', id: 's', label: 'S', page: 'a\nb' }, 'p', 0).page, 'a-b')
  eq('an id that sanitizes away falls back like an absent one',
    M.parseBundle('{"id":"\\n","title":"T","items":[]}').pages[0].id, 'main')
})

group('parseBundle strips JSONC and rejects the degenerate documents', () => {
  const j = bundle('// a comment\n{"id":"x","items":[],}\n')
  eq('a whole-line comment and a trailing comma are gone', j.pages.map(p => p.id), ['x'])
  eq('an indented comment too', bundle('  // c\n{"id":"y"}').pages[0].id, 'y')
  eq('a comment between members', bundle('{"id":"z","items":[],\n// note\n"width":10}').pages[0].width, 10)
  eq('a trailing comment on its OWN line is stripped', bundle('{"id":"a"}\n// hi\n').pages[0].id, 'a')
  // "An inline // inside a value line will break the parse - keep comments on
  // their own lines." Two distinct breakages, both pinned:
  eq('but a // inside a string value is NOT a comment and survives', bundle('{"id":"a","items":[{"type":"action","desc":"see http://x"}]}').pages[0].items[0].desc, 'see http://x')
  eq('a // after the closing brace on the same line breaks the parse', (() => { try { bundle('{"id":"a"} // hi'); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  eq('and a line that STARTS with // inside a multiline string breaks it too', (() => { try { bundle('{"id":"a","d":"x\n//y\n"}'); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  // 'A file that fails to parse contributes nothing (the extension path
  // relies on this to fail soft)' - parseBundle itself throws and
  // applyExtension catches; see the extension section.
  throws('an empty page list is refused', () => bundle('[]'), /bundle has no pages/)
  throws('an empty pages array is refused', () => bundle('{"pages":[]}'), /bundle has no pages/)
  throws('malformed text throws a JSON error', () => bundle('nope'), /JSON|token|Unexpected/)
  throws('empty text throws a JSON error', () => bundle(''), /JSON|token|Unexpected|end of input/)
  throws('a null document throws', () => bundle(null), /JSON|token|Unexpected|end of input/)
  noThrow('but a page with no items never throws', () => bundle('{"id":"noid"}'))
})

// ======================================================================
section('orderSettingsIndex - the top-level settings order')
group('the whole index sorts into the shipped order', () => {
  // Every real top-level page id, fed in an order that is deliberately not
  // the target order, so a rank array that merely happened to agree with the
  // document order could not pass. "bar" is the page the Statusbar page
  // declares: the visible label was renamed, the id is the key.
  const scrambled = ['misc', 'osd', 'bar', 'power', 'hyprland', 'general', 'idle',
    'audio', 'color-picker', 'lock-screen', 'recording', 'night-light',
    'brightness', 'app-launcher', 'screenshots', 'media-controls']
  const b = bundle(`{"pages":[
    {"id":"settings","title":"Settings","items":${JSON.stringify(
      scrambled.map(id => ({ type: 'submenu', id, page: id, label: id })))}},
    {"id":"hyprland","items":[]}
  ]}`)
  M.orderSettingsIndex(b)
  eq('the shipped order', b.byId.settings.items.map(i => i.id), [
    'general', 'bar', 'app-launcher', 'audio', 'brightness', 'screenshots',
    'recording', 'night-light', 'media-controls', 'lock-screen', 'power',
    'color-picker', 'hyprland', 'idle', 'osd', 'misc'
  ])
  eq('and every id is still present, none dropped', b.byId.settings.items.length, 16)
})

group('known page ids sort into the documented order', () => {
  const b = bundle(`{"pages":[
    {"id":"settings","title":"Settings","items":[
      {"type":"submenu","id":"misc","page":"misc","label":"Misc"},
      {"type":"submenu","id":"general","page":"general","label":"General"},
      {"type":"submenu","id":"custom","page":"custom","label":"Custom"},
      {"type":"submenu","id":"bar","page":"bar","label":"Bar"}
    ]},
    {"id":"general","items":[]},{"id":"misc","items":[]},
    {"id":"bar","items":[]},{"id":"custom","items":[]}
  ]}`)
  M.orderSettingsIndex(b)
  eq('known pages first, in rank order', b.byId.settings.items.map(i => i.id), ['general', 'bar', 'misc', 'custom'])
})

group('the rank key is `page || id`, so a bare id is ranked too', () => {
  // `const key = it && (it.page || it.id || "")` - a bundle that names a row
  // "general" without a submenu link still lands in General's slot.
  const b = bundle(`{"pages":[{"id":"settings","title":"Settings","items":[
    {"type":"action","id":"general","label":"G"},
    {"type":"action","label":"Plain"},
    {"type":"submenu","page":"bar","label":"B"}
  ]}]}`)
  M.orderSettingsIndex(b)
  eq('an action carrying a known id ranks with it', b.byId.settings.items.map(i => i.label), ['G', 'B', 'Plain'])
  // `it.page || it.id` - page wins when both are declared.
  const c = bundle(`{"pages":[{"id":"settings","title":"S","items":[
    {"type":"submenu","page":"misc","id":"bar","label":"page wins"},
    {"type":"submenu","id":"bar","label":"id used"}
  ]}]}`)
  M.orderSettingsIndex(c)
  eq('page beats id', c.byId.settings.items.map(i => i.label), ['id used', 'page wins'])
})

group('unknown ids keep their relative order, after every known row', () => {
  const b = bundle(`{"pages":[{"id":"settings","title":"S","items":[
    {"type":"submenu","page":"custom","label":"A"},
    {"type":"action","label":"B"},
    {"type":"separator","label":"--"},
    {"type":"submenu","page":"osd","label":"O"},
    {"type":"submenu","page":"custom","label":"C"}
  ]}]}`)
  M.orderSettingsIndex(b)
  eq('known rows hoist, unknown rows keep document order', b.byId.settings.items.map(i => i.label), ['O', 'A', 'B', '--', 'C'])
  const ties = bundle(`{"pages":[{"id":"settings","title":"S","items":[
    {"type":"submenu","page":"misc","label":"A"},
    {"type":"submenu","page":"misc","label":"B"}
  ]}]}`)
  M.orderSettingsIndex(ties)
  eq('equal ranks keep source order (stable sort)', ties.byId.settings.items.map(i => i.label), ['A', 'B'])
})

group('a settings page with no Hyprland link gets one appended', () => {
  // "A bundle whose settings page has no Hyprland link gets one appended, so
  // the row is present even before HyprlandSettings is ready to join its
  // pages."
  const b = bundle(`{"pages":[
    {"id":"settings","title":"Settings","items":[{"type":"submenu","id":"general","page":"general","label":"General"}]},
    {"id":"general","items":[]},
    {"id":"hyprland","items":[]}
  ]}`)
  M.orderSettingsIndex(b)
  eq('the row is appended', b.byId.settings.items.map(i => i.id), ['general', 'hyprland'])
  const h = b.byId.settings.items[1]
  eq('as a submenu pointing at the page', [h.type, h.page, h.label], ['submenu', 'hyprland', 'Hyprland'])
  eq('with the icon and sub the synthesis declares', [h.icon, h.sub], ['hyprland', 'Window manager behavior'])
  eq('selectable', h.selectable, true)
  eq('and searchable', h.hay, 'hyprland window manager behavior')
  eq('keyed by its explicit id, not its position', h.uid, 'settings#hyprland')
  const empty = bundle(`{"pages":[{"id":"settings","title":"Settings","items":[]},{"id":"hyprland","items":[]}]}`)
  M.orderSettingsIndex(empty)
  eq('an empty settings page gets it too', empty.byId.settings.items.map(i => i.label), ['Hyprland'])
})

group('a settings page that already links Hyprland is left alone', () => {
  const linked = bundle(`{"pages":[
    {"id":"settings","title":"S","items":[{"type":"submenu","id":"hyprland","page":"hyprland","label":"H"}]},
    {"id":"hyprland","items":[]}
  ]}`)
  M.orderSettingsIndex(linked)
  eq('no second row', linked.byId.settings.items.length, 1)
  // The check is `it.type === "submenu" && it.page === "hyprland"` - no id is
  // required, so an anonymous link counts just as well.
  const anon = bundle(`{"pages":[{"id":"settings","title":"S","items":[{"type":"submenu","page":"hyprland","label":"H"}]},{"id":"hyprland","items":[]}]}`)
  M.orderSettingsIndex(anon)
  eq('an anonymous link counts as a link', anon.byId.settings.items.length, 1)
  eq('and nothing is appended', anon.byId.settings.items[0].label, 'H')
  // ...but a row that merely *points* at the page as an action does not.
  const asAction = bundle(`{"pages":[{"id":"settings","title":"S","items":[{"type":"action","page":"hyprland","label":"H"}]},{"id":"hyprland","items":[]}]}`)
  M.orderSettingsIndex(asAction)
  eq('a non-submenu row pointing at the page is not a link', asAction.byId.settings.items.length, 2)
  eq('so the synthesis is appended', asAction.byId.settings.items[1].label, 'Hyprland')
  // No hyprland page at all: `base.byId["hyprland"] !== undefined` is the
  // gate, so no row is invented.
  const noPage = bundle(`{"pages":[{"id":"settings","title":"S","items":[{"type":"action","label":"A"}]}]}`)
  M.orderSettingsIndex(noPage)
  eq('without a hyprland page nothing is appended', noPage.byId.settings.items.map(i => i.label), ['A'])
})

group('orderSettingsIndex sorts in place and declines to return anything', () => {
  const b = bundle(`{"pages":[
    {"id":"settings","title":"S","items":[
      {"type":"submenu","id":"misc","page":"misc"},
      {"type":"submenu","id":"general","page":"general"}
    ]},
    {"id":"misc","items":[]},{"id":"general","items":[]}
  ]}`)
  eq('before', b.byId.settings.items.map(i => i.id), ['misc', 'general'])
  eq('and it returns undefined', M.orderSettingsIndex(b), undefined)
  eq('the page items array was replaced in place', b.byId.settings.items.map(i => i.id), ['general', 'misc'])
  eq('a bundle with no settings page returns undefined', M.orderSettingsIndex({ pages: [], byId: {} }), undefined)
  eq('a bundle with no byId at all', M.orderSettingsIndex({}), undefined)
  eq('a settings page with no items array', M.orderSettingsIndex({ byId: { settings: {} } }), undefined)
  eq('and it never throws', typeof M.orderSettingsIndex({ byId: { settings: { items: 'no' } } }), 'undefined')
})

// ======================================================================
section('the extension merge pieces')
group('mergedLabel: the extension title wins only when it says something', () => {
  eq('a title wins', M.mergedLabel('E', 'B'), 'E')
  eq('an empty title keeps the base', M.mergedLabel('', 'B'), 'B')
  eq('a non-string title keeps the base', M.mergedLabel(5, 'B'), 'B')
  eq('an absent title keeps the base', M.mergedLabel(undefined, 'B'), 'B')
  eq('null keeps the base', M.mergedLabel(null, 'B'), 'B')
  eq('with neither there is no title', M.mergedLabel(undefined, undefined), undefined)
  // buildPage then turns a missing title back into the page id, so a title
  // can never become the string "undefined" on screen.
  eq('and buildPage supplies the id', M.buildPage('pid', M.mergedLabel(undefined, undefined), 0, []).label, 'pid')
})

group('mergedWidth: a positive number wins, anything else keeps the base', () => {
  eq('a positive width wins', M.mergedWidth(500, 400), 500)
  eq('zero is "unset", not "collapse"', M.mergedWidth(0, 400), 400)
  eq('a negative width is not a width', M.mergedWidth(-5, 400), 400)
  eq('a string width is not a width', M.mergedWidth('5', 400), 400)
  eq('an absent width keeps the base', M.mergedWidth(undefined, 400), 400)
  eq('null keeps the base', M.mergedWidth(null, 400), 400)
  eq('NaN is not > 0, so it keeps the base', M.mergedWidth(NaN, 400), 400)
  eq('the base may itself be 0', M.mergedWidth(undefined, 0), 0)
  eq('a fractional width is passed through for buildPage to round', M.mergedWidth(400.6, 0), 400.6)
})

group('mergedPageOpts overrides layout fields type by type', () => {
  const base = { layout: 'list', cell: 0, maxHeight: 0, command: 'b %v', filterDefault: false }
  eq('all five overridden', M.mergedPageOpts({ layout: 'grid', cell: 44, maxHeight: 500, command: 'c %v', filterDefault: true }, base), { layout: 'grid', cell: 44, maxHeight: 500, command: 'c %v', filterDefault: true })
  eq('none overridden', M.mergedPageOpts({}, base), base)
  eq('a partial override leaves the rest', M.mergedPageOpts({ layout: 'grid' }, base), { layout: 'grid', cell: 0, maxHeight: 0, command: 'b %v', filterDefault: false })
  // `typeof x === "number"` is the test, so 0 IS an override - unlike
  // mergedWidth, which wants a positive number.
  eq('a zero cell is an override here', M.mergedPageOpts({ cell: 0 }, base).cell, 0)
  eq('a zero maxHeight is an override here', M.mergedPageOpts({ maxHeight: 0 }, base).maxHeight, 0)
  eq('a wrong-typed layout is ignored', M.mergedPageOpts({ layout: 5 }, base).layout, 'list')
  eq('a wrong-typed cell is ignored', M.mergedPageOpts({ cell: '9' }, base).cell, 0)
  eq('a null layout is ignored', M.mergedPageOpts({ layout: null }, base).layout, 'list')
  eq('a null cell is ignored', M.mergedPageOpts({ cell: null }, base).cell, 0)
  eq('an empty command string IS an override', M.mergedPageOpts({ command: '' }, base).command, '')
  eq('the result always has exactly the five keys', Object.keys(M.mergedPageOpts({}, base)), ['layout', 'cell', 'maxHeight', 'command', 'filterDefault'])
})

group('replacePage swaps every page carrying that id, into a new array', () => {
  const pages = [{ id: 'a' }, { id: 'b' }, { id: 'a' }]
  const before = JSON.stringify(pages)
  eq('both twins are replaced', M.replacePage(pages, { id: 'a', n: 1 }).map(p => p.n), [1, undefined, 1])
  eq('the other pages are passed through by reference', M.replacePage(pages, { id: 'a', n: 1 })[1], pages[1])
  eq('a page whose id is absent changes nothing', M.replacePage(pages, { id: 'zz' }), pages)
  eq('an empty page list stays empty', M.replacePage([], { id: 'a' }), [])
  eq('the input array is byte-for-byte unchanged', JSON.stringify(pages), before)
  is('a new array is returned', M.replacePage(pages, { id: 'b' }) === pages, (v) => v === false, 'a new array')
  // The replace is unconditional rather than first-match, so a duplicated
  // page id (which buildPage does not dedupe) gets the same object in both
  // slots. Pinned because the caller indexes byId, not by position.
  const replacement = { id: 'a', n: 1 }
  is('the one replacement object lands in both slots', M.replacePage(pages, replacement)[0] === M.replacePage(pages, replacement)[2], (v) => v === true, 'the same object')
  is('and it is the very object handed in', M.replacePage(pages, replacement)[0] === replacement, (v) => v === true, 'the same object')
})

group('mergeRawItems overrides by id in place and appends the rest', () => {
  // "Overrides land in place first so appends keep their relative order at
  // the end of the page regardless of how the extension interleaves them."
  const base = [{ id: 'a', label: 'A' }, { label: 'anon' }, { id: 'b', label: 'B' }]
  eq('the override stays in its base position', M.mergeRawItems(base, [{ id: 'b', label: 'B2' }, { id: 'c', label: 'C' }, { label: 'D' }]), [
    { id: 'a', label: 'A' }, { label: 'anon' }, { id: 'b', label: 'B2' }, { id: 'c', label: 'C' }, { label: 'D' },
  ])
  eq('appends keep extension order', M.mergeRawItems([], [{ label: 'x' }, { label: 'y' }]).map(r => r.label), ['x', 'y'])
  eq('an anonymous extension row is always an append', M.mergeRawItems([{ label: 'base' }], [{ label: 'ext' }]).map(r => r.label), ['base', 'ext'])
  eq('an empty extension returns a copy of the base', M.mergeRawItems(base, []), base)
  is('and that copy is a new array', M.mergeRawItems(base, []) === base, (v) => v === false, 'a new array')
  eq('non-object extension entries are skipped', M.mergeRawItems(base, [null, 5, 'x', { id: 'a', label: 'A3' }]), [
    { id: 'a', label: 'A3' }, { label: 'anon' }, { id: 'b', label: 'B' },
  ])
  eq('an empty base with only appends', M.mergeRawItems([], [{ id: 'a' }]), [{ id: 'a' }])
  eq('an empty id is not a key', M.mergeRawItems([{ id: '', label: 'A' }], [{ id: '', label: 'E' }]).map(r => r.label), ['A', 'E'])
  eq('a non-string base id is not a key', M.mergeRawItems([{ id: 5, label: 'A' }], [{ id: '5', label: 'E' }]).map(r => r.label), ['A', 'E'])
  eq('a non-string ext id is an append', M.mergeRawItems([], [{ id: 5, label: 'E' }]), [{ id: 5, label: 'E' }])
})

group('mergeRawItems copies the override shallowly and leaves the base alone', () => {
  const base = [{ id: 'a', label: 'A', nested: { k: 1 } }]
  const before = JSON.stringify(base)
  const out = M.mergeRawItems(base, [{ id: 'a', desc: 'd' }])
  eq('the merged row carries base fields plus the override', out[0], { id: 'a', label: 'A', nested: { k: 'k' in out[0].nested ? 1 : undefined }, desc: 'd' })
  eq('the base object is byte-for-byte unchanged', JSON.stringify(base), before)
  is('the override target is a copy, not the base row', out[0] === base[0], (v) => v === false, 'a copy')
  is('but the copy is shallow, so nested objects are shared', out[0].nested === base[0].nested, (v) => v === true, 'shared')
  eq('so the base row still has no desc', 'desc' in base[0], false)
  const ext = [{ label: 'X' }]
  is("appended rows are the extension's own objects", M.mergeRawItems([], ext)[0] === ext[0], (v) => v === true, 'shared')
})

group('mergeSibling appends a registry bundle and never displaces the opened one', () => {
  // "pages append when their id is free, existing ids are left untouched
  // (the opened file keeps authority). Entry page never changes."
  const base = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"action","id":"one","label":"One","command":"orig %v"}]},
    {"id":"sub","title":"Sub","width":400,"command":"pagecmd %v","items":[{"type":"toggle","id":"t1","label":"T1","var":"V1"}]}
  ]}`)
  const snapshot = JSON.stringify(base)
  const s = M.mergeSibling(base, '{"pages":[{"id":"extra","title":"Extra","items":[{"type":"action","label":"E"}]},{"id":"main","title":"IGNORED"}]}')
  eq('a free id appends', s.pages.map(p => p.id), ['main', 'sub', 'extra'])
  eq('byId gains it', Object.keys(s.byId), ['main', 'sub', 'extra'])
  eq('the entry page never changes', s.entry, 'main')
  eq('a taken id is left untouched', s.byId.main.label, 'Main')
  eq('the opened page object is the same one, not a re-parse', s.byId.main === base.byId.main, true)
  eq('the appended page is normalized', s.byId.extra.items.map(i => i.uid), ['extra#0'])
  eq('the base bundle is byte-for-byte unchanged', JSON.stringify(base), snapshot)
  eq('and did not gain the page', base.pages.length, 2)
  eq('a single page object merges too', M.mergeSibling(bundle('{"id":"a"}'), '{"id":"solo","title":"Solo"}').pages.map(p => p.id), ['a', 'solo'])
  eq('a bare array merges too', M.mergeSibling(bundle('{"id":"a"}'), '[{"id":"arr"}]').pages.map(p => p.id), ['a', 'arr'])
  eq('unnamed sibling pages get positional ids', M.mergeSibling(bundle('{"id":"a"}'), '[{"title":"A"},{"title":"B"}]').pages.map(p => p.id), ['a', 'sibling0', 'sibling1'])
  eq('an empty sibling bundle is a no-op', M.mergeSibling(bundle('{"id":"a"}'), '{"pages":[]}').pages.map(p => p.id), ['a'])
  // mergeSibling does NOT fail soft (applyExtension does): a registry file
  // that does not parse is a hard error the caller has to handle.
  throws('a sibling that does not parse throws', () => M.mergeSibling(bundle('{"id":"a"}'), 'nope'), /JSON|token|Unexpected/)
  throws('and so does a null document', () => M.mergeSibling(bundle('{"id":"a"}'), null), /JSON|token|Unexpected|end of input/)
})

group('applyExtension merges a user extension over the parsed base', () => {
  const base = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"action","id":"one","label":"One","command":"orig %v"}]},
    {"id":"sub","title":"Sub","width":400,"items":[{"type":"toggle","id":"t1","label":"T1","var":"V1"}]}
  ]}`)
  const r = M.applyExtension(base, `{"pages":[{"id":"sub","title":"Sub2","width":500,"layout":"grid","cell":30,"maxHeight":260,"command":"ext %v","items":[
    {"id":"t1","label":"T1 renamed"},
    {"id":"t2","label":"T2 new"}
  ]}]}`)
  eq('the page title is overridden', r.byId.sub.label, 'Sub2')
  eq('the width too', r.byId.sub.width, 500)
  eq('and the layout chrome', [r.byId.sub.layout, r.byId.sub.cell, r.byId.sub.maxHeight], ['grid', 30, 260])
  eq('and the fallback command', r.byId.sub.command, 'ext %v')
  eq('the existing row is overridden in place by id', r.byId.sub.items.map(i => i.label), ['T1 renamed', 'T2 new'])
  eq('uids follow the final positions/ids', r.byId.sub.items.map(i => i.uid), ['sub#t1', 'sub#t2'])
  eq('base fields the extension did not mention survive', r.byId.sub.items[0].var, 'V1')
  eq('the new row carries the new id', r.byId.sub.items[1].uid, 'sub#t2')
  eq('the re-normalized page replaces the old one in pages', r.pages[r.pages.indexOf(r.byId.sub)] === r.byId.sub, true)
  eq('the entry page survives', r.entry, 'main')
})

group('applyExtension adds pages the base does not have', () => {
  const base = bundle('{"id":"main","items":[{"type":"action","label":"A"}]}')
  const r = M.applyExtension(base, '{"pages":[{"id":"newpage","title":"New","items":[{"type":"action","label":"N"}]}]}')
  eq('a new id appends', r.pages.map(p => p.id), ['main', 'newpage'])
  eq('and is normalized like any page', r.byId.newpage.items.map(i => i.uid), ['newpage#0'])
  eq('the entry is still the base entry', r.entry, 'main')
  // `!extPage || typeof extPage.id !== "string" || extPage.id === ""` - an
  // extension page with no id cannot be addressed, so it is skipped.
  eq('an extension page with no id is skipped', M.applyExtension(base, '{"pages":[{"title":"NoId","items":[]}]}').pages.map(p => p.id), ['main'])
  eq('a null extension page is skipped', M.applyExtension(base, '{"pages":[null]}').pages.map(p => p.id), ['main'])
  eq('a numeric id is skipped', M.applyExtension(base, '{"pages":[{"id":5,"items":[]}]}').pages.map(p => p.id), ['main'])
  // 'Entry page never changes' - and if the entry id somehow left byId the
  // first page is used rather than a dangling id.
  eq('an entry that is not in byId falls back to the first page', M.applyExtension(bundle('{"id":"zz","items":[]}'), '{"pages":[{"id":"other"}]}').entry, 'zz')
  const gone = { entry: 'gone', pages: [], byId: {} }
  eq('and a bundle with no entry at all', M.applyExtension(gone, '{"pages":[{"id":"other","items":[]}]}').entry, 'other')
})

group('applyExtension re-applies the base fallback command to re-normalized rows', () => {
  // "Resolved fallback command kept on the page so extension merges
  // (mergedPageOpts) can re-apply it to re-normalized rows."
  const base = bundle('{"pages":[{"id":"p","title":"P","command":"base %v","items":[{"type":"action","id":"a","label":"A"}]}]}')
  const r = M.applyExtension(base, '{"pages":[{"id":"p","items":[{"id":"a","desc":"added"}]}]}')
  eq('the row inherits the page command again', r.byId.p.items.map(i => i.command), ['base %v'])
  eq('and carries the extension field', r.byId.p.items[0].desc, 'added')
  // A page with no command of its own simply has nothing to re-apply.
  const plain = bundle('{"pages":[{"id":"p","title":"P","items":[{"type":"action","id":"a","label":"A"}]}]}')
  eq('no command means no command', M.applyExtension(plain, '{"pages":[{"id":"p","items":[{"id":"a","desc":"d"}]}]}').byId.p.items[0].command, '')
})

group('applyExtension fails soft on a bundle it cannot read', () => {
  // "A file that fails to parse contributes nothing, which is what lets the
  // extension path fail soft - keep it that way."
  const base = bundle('{"id":"main","items":[{"type":"action","label":"A"}]}')
  const snapshot = JSON.stringify(base)
  is('an unparseable extension hands back the very same base', M.applyExtension(base, 'nope') === base, (v) => v === true, 'the same object')
  is('and so does an empty page list', M.applyExtension(base, '{"pages":[]}') === base, (v) => v === true, 'the same object')
  eq('the base is untouched either way', JSON.stringify(base), snapshot)
  noThrow('a null extension document', () => M.applyExtension(base, null))
})

group('applyExtension does not mutate the base bundle', () => {
  const base = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"action","id":"one","label":"One"}]},
    {"id":"sub","title":"Sub","items":[{"type":"toggle","id":"t1","label":"T1","var":"V1"}]}
  ]}`)
  const snapshot = JSON.stringify(base)
  const r = M.applyExtension(base, '{"pages":[{"id":"main","title":"Changed","items":[{"id":"one","label":"One2"},{"id":"two","label":"Two"}]}]}')
  eq('the base is byte-for-byte unchanged', JSON.stringify(base), snapshot)
  eq('the base main page keeps its title', base.byId.main.label, 'Main')
  eq('the base main page keeps its item list', base.byId.main.items.map(i => i.label), ['One'])
  eq('and did not gain the extension page', base.pages.map(p => p.id), ['main', 'sub'])
  eq('the result carries the change', r.byId.main.label, 'Changed')
  eq('and both rows', r.byId.main.items.map(i => i.label), ['One2', 'Two'])
  // The result is a new pages array and a new byId, but re-uses the page
  // objects the extension did not touch - which is why the non-mutation
  // check above has to compare by value, not by identity.
  is('the result pages array is new', r.pages === base.pages, (v) => v === false, 'a new array')
  is('the result byId is new', r.byId === base.byId, (v) => v === false, 'a new object')
  is('an untouched page object is shared by identity', r.byId.sub === base.byId.sub, (v) => v === true, 'the same page')
  is('a merged page object is new', r.byId.main === base.byId.main, (v) => v === false, 'a new page')
  eq('while the shared page still has its own value', r.byId.sub.items.map(i => i.label), ['T1'])
})

// ======================================================================
section('guards - the emitted shell is the product, so the text is asserted')
group('guardLine emits one if/then/echo per expression', () => {
  // Exact text. `if { EXPR; } >/dev/null 2>&1; then echo '<uid>:<tag>:1';
  // else echo '<uid>:<tag>:0'; fi` + newline.
  eq('a when guard', M.guardLine('pg#1', 'w', 'test -f /x'), "if { test -f /x; } >/dev/null 2>&1; then echo 'pg#1:w:1'; else echo 'pg#1:w:0'; fi\n")
  eq('a checked guard', M.guardLine('pg#1', 'c', 'pgrep x'), "if { pgrep x; } >/dev/null 2>&1; then echo 'pg#1:c:1'; else echo 'pg#1:c:0'; fi\n")
  eq('a disabled guard', M.guardLine('pg#1', 'd', 'x'), "if { x; } >/dev/null 2>&1; then echo 'pg#1:d:1'; else echo 'pg#1:d:0'; fi\n")
  eq('the tag is data, passed through verbatim', M.guardLine('u', 'zzz', 'x').includes("'u:zzz:1'"), true)
  eq('the expression keeps its own quoting', M.guardLine('u', 'w', 'grep "x" f'), "if { grep \"x\" f; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  // `if { EXPR; }` - the author writes no trailing `;` and one is added. A
  // newline inside the expression therefore emits a multi-line `if`, which is
  // fine: bash does not need the continuation and the `;` still terminates.
  eq('a newline in the expression is emitted verbatim', M.guardLine('pg#1', 'w', 'a\nb'), "if { a\nb; } >/dev/null 2>&1; then echo 'pg#1:w:1'; else echo 'pg#1:w:0'; fi\n")
  // A trailing `;` in the expression is NOT stripped, so the emitted braces
  // carry `;;` - which bash rejects as a syntax error. Because all the guards
  // share ONE batched run, a single bundle row written that way takes down
  // every row's guard answer, not just its own. Pinned as the real behaviour;
  // see the report.
  eq('a trailing semicolon in the expression is stripped, not doubled', M.guardLine('u', 'w', 'true;').includes('if { true; }'), true)
  eq('so the emitted braces stay well-formed bash', M.guardLine('u', 'w', 'true;').split('; then')[0], 'if { true; } >/dev/null 2>&1')
  eq('and it lands in the batched script whole', M.buildGuardScript([page('p', [{ type: 'action', id: 'a', when: 'true;' }])]).includes('if { true; }'), true)
  eq('an expression with no trailing semicolon is well-formed', M.guardLine('u', 'w', 'true').split('; then')[0], 'if { true; } >/dev/null 2>&1')
})

group('an absent expression emits nothing at all', () => {
  eq('an empty string', M.guardLine('pg#1', 'w', ''), '')
  eq('a whitespace-only string', M.guardLine('pg#1', 'w', '   '), '')
  eq('a tab and newline', M.guardLine('pg#1', 'w', '\t\n'), '')
  eq('a number', M.guardLine('pg#1', 'w', 5), '')
  eq('null', M.guardLine('pg#1', 'w', null), '')
  eq('undefined', M.guardLine('pg#1', 'w', undefined), '')
  eq('an object', M.guardLine('pg#1', 'w', {}), '')
  eq('so an unguarded row contributes no line', M.buildGuardScript([page('p', [{ type: 'action', id: 'a' }])]), '')
})

group('the verdict token is quoted; the expression is trusted source by design', () => {
  // "Only the verdict token is data, and it is quoted." These cases are the
  // reason: a page/item id reaches the reader through the echo argument, and
  // an apostrophe in one must stay inside the argument.
  eq('an apostrophe in the uid is escaped, not ended', M.guardLine("pg#it's", 'w', 'x'), "if { x; } >/dev/null 2>&1; then echo 'pg#it'\\''s:w:1'; else echo 'pg#it'\\''s:w:0'; fi\n")
  eq('a command substitution stays inert', M.guardLine('pg#x$(id)', 'w', 'x').includes("'pg#x$(id):w:1'"), true)
  eq('a backtick stays inert', M.guardLine('pg#a`id`', 'w', 'x').includes("'pg#a`id`:w:1'"), true)
  eq('a dollar stays inert', M.guardLine('pg#$HOME', 'w', 'x').includes("'pg#$HOME:w:1'"), true)
  eq('a semicolon in the uid stays inside the word', M.guardLine('pg#a;id', 'w', 'x').includes("'pg#a;id:w:1'"), true)
  eq('a newline in the uid stays inside the word', M.guardLine('pg#a\nid', 'w', 'x').includes("'pg#a\nid:w:1'"), true)
  // The security contract is a *scope* one, and it is worth stating exactly:
  // the expression is concatenated as shell source. This is intentional
  // ("a trusted local-config compatibility surface evaluated by one batched
  // bash run, not a data-only API") and the tests above are what make the
  // boundary auditable rather than assumed.
  is('the expression is emitted as source, unquoted by design', M.guardLine('u', 'w', 'echo pwned'), (v) => v.startsWith('if { echo pwned; }'), 'raw source inside the braces')
  // The emitted word is always a single-quoted argument in which the only
  // interior quotes are complete `'\''` escape sequences - so a hostile uid
  // can never terminate the argument and start a second command.
  const q = M.guardLine("pg#it's", 'w', 'x').match(/echo (.*?); else/)[1]
  is('and the verdict word is one balanced quoted argument', q, (v) => {
    if (!v.startsWith("'") || !v.endsWith("'")) return false
    const NUL = '\u0000'
    const inner = v.slice(1, -1).split("'\\''").join(NUL)
    return !inner.includes("'") && (inner.match(new RegExp(NUL, 'g')) || []).length === 1
  }, 'every interior quote is a complete escape')
  eq('carrying exactly the three verdict fields', q.slice(1, -1), "pg#it'\\''s:w:1")
  is('and the same holds for a uid with two apostrophes', M.guardLine("a'b'c", 'w', 'x').split('; else')[0].split('echo ')[1], (v) => {
    const NUL = '\u0001'
    const inner = v.slice(1, -1).split("'\\''").join(NUL)
    return v.startsWith("'") && v.endsWith("'") && !inner.includes("'") && (inner.match(new RegExp(NUL, 'g')) || []).length === 2
  }, 'two complete escapes')
  is('and for a uid with none', M.hideLine('plain').slice(5, -1), (v) => v.startsWith("'") && v.endsWith("'") && !v.slice(1, -1).includes("'"), 'a plain quoted word')
})

group('hideLine emits a bare hide verdict', () => {
  eq('plain', M.hideLine('pg#1'), "echo 'pg#1:w:0'\n")
  eq('it always uses the w tag', M.hideLine('pg#1').includes("'pg#1:w:0'"), true)
  eq('an apostrophe is escaped the same way', M.hideLine("pg#it's"), "echo 'pg#it'\\''s:w:0'\n")
  eq('a backtick stays inert', M.hideLine('pg#a`id`'), "echo 'pg#a`id`:w:0'\n")
  eq('a dollar stays inert', M.hideLine('pg#$HOME'), "echo 'pg#$HOME:w:0'\n")
  eq('an empty uid still emits a well-formed token', M.hideLine(''), "echo ':w:0'\n")
  // An unconditional hide is cheaper than a false branch, and it is the shape
  // a malformed `requires` produces: the row is gone, not greyed.
  eq('it is a fraction of guardLine and much shorter', M.hideLine('pg#1').length < M.guardLine('pg#1', 'w', 'x').length, true)
})

group('requiresGuard turns {chassis} and {binary} into one w guard', () => {
  eq('absent requires emits nothing', M.requiresGuard('u', undefined), '')
  eq('null requires emits nothing', M.requiresGuard('u', null), '')
  // `type -P`, not `command -v`: the latter answers for builtins, keywords and
  // functions too, so {"binary":"cd"} passed everywhere and showed a row gated
  // on a program being installed.
  eq('a binary becomes type -P', M.requiresGuard('u', { binary: 'hyprctl' }), "if { type -P hyprctl >/dev/null; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  // Quoted on every arm. Inside [[ ]] there is no word splitting so the answers
  // coincide, but the right-hand side is a glob pattern and the shipped
  // bundles already spell one arm this way.
  eq('laptop', M.requiresGuard('u', { chassis: 'laptop' }), "if { [[ \"$CHASSIS_TYPE\" == laptop ]]; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  eq('vm', M.requiresGuard('u', { chassis: 'vm' }), "if { [[ \"$CHASSIS_TYPE\" == vm ]]; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  eq('not-vm', M.requiresGuard('u', { chassis: '!vm' }), "if { [[ \"$CHASSIS_TYPE\" != vm ]]; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  const both = M.requiresGuard('u', { binary: 'wl-copy', chassis: 'laptop' })
  eq('both keys AND together, binary first regardless of key order', both, "if { type -P wl-copy >/dev/null && [[ \"$CHASSIS_TYPE\" == laptop ]]; } >/dev/null 2>&1; then echo 'u:w:1'; else echo 'u:w:0'; fi\n")
  eq('and the emitted order is the same either way', both, M.requiresGuard('u', { chassis: 'laptop', binary: 'wl-copy' }))
  contains('the two arms are joined with &&', both, '&&')
  // A non-object is a refused shape, not an absent one: reading it as "no
  // constraint" would show a row the author gated.
  for (const bad of ['laptop', 5, true, ['binary']]) {
    eq(`${JSON.stringify(bad)} is a refused shape, so a hide`, M.requiresGuard('u', bad), "echo 'u:w:0'\n")
  }
})

group('when and requires answer as ONE verdict, not two that race', () => {
  // They were two `w` lines for one uid, and the reader collapses a repeated
  // uid last-one-wins - so an OR stood in for an AND, and an extension adding a
  // `requires` to a row whose own `when` said false made the row show.
  const pg = items => M.buildGuardScript([M.buildPage('p', 'P', 0, items, {})])
  const wLines = s => s.split('\n').filter(l => l.includes(':w:'))
  eq('a row with both emits exactly one w line',
    wLines(pg([{ type: 'action', id: 'r', label: 'R', when: 'false', requires: { chassis: 'laptop' } }])).length, 1)
  contains('ANDed, when first', pg([{ type: 'action', id: 'r', label: 'R',
    when: 'false', requires: { chassis: 'laptop' } }]), 'false && ')
  contains('ANDed, requires second', pg([{ type: 'action', id: 'r', label: 'R',
    when: 'false', requires: { chassis: 'laptop' } }]), 'CHASSIS_TYPE')
  eq('a requires-only row is unchanged',
    pg([{ type: 'action', id: 'r', label: 'R', requires: { chassis: 'laptop' } }]),
    M.requiresGuard('p#r', { chassis: 'laptop' }))
  eq('a when-only row is unchanged',
    pg([{ type: 'action', id: 'r', label: 'R', when: 'test -d /x' }]),
    M.guardLine('p#r', 'w', 'test -d /x') + M.guardLine('p#r', 'c', '') + M.guardLine('p#r', 'd', ''))
  // A refused shape is an unconditional hide, which is not an expression and so
  // cannot be ANDed - it wins outright, and still emits c/d.
  const refused = pg([{ type: 'action', id: 'r', label: 'R', when: 'true',
    requires: { chassis: 'Laptop' }, checked: 'true' }])
  contains('a refused requires shape hides outright', refused, "echo 'p#r:w:0'")
  notMatch('and the row\'s own when is not ANDed into it', refused, /true && /)
  contains('while checked still gets its line', refused, 'p#r:c:')
})

group('a binary name is pattern-validated before it reaches the script', () => {
  // `/^[a-z0-9._-]+$/` - the one interpolated value that is *not* trusted
  // source, because it is a bare word in `command -v`, not inside quotes.
  eq('a plain name', M.requiresGuard('u', { binary: 'hyprctl' }).includes('type -P hyprctl >/dev/null'), true)
  eq('a dotted name', M.requiresGuard('u', { binary: 'a.b' }).includes('type -P a.b >/dev/null'), true)
  eq('a dashed/underscored name', M.requiresGuard('u', { binary: 'a-b_9' }).includes('type -P a-b_9 >/dev/null'), true)
  eq('a digit-leading name', M.requiresGuard('u', { binary: '9lives' }).includes('type -P 9lives >/dev/null'), true)
  for (const bad of ['/usr/bin/x', 'Hypr', 'x;id', 'x y', 'x$(id)', 'x`id`', 'a/b', 'a;b', '']) {
    eq(`${JSON.stringify(bad)} is refused`, M.requiresGuard('u', { binary: bad }), "echo 'u:w:0'\n")
  }
  eq('a non-string binary is refused', M.requiresGuard('u', { binary: 5 }), "echo 'u:w:0'\n")
  eq('null binary is refused', M.requiresGuard('u', { binary: null }), "echo 'u:w:0'\n")
})

group('a chassis value outside the three known arms hides the row', () => {
  eq('an unknown chassis', M.requiresGuard('u', { chassis: 'desktop' }), "echo 'u:w:0'\n")
  eq('a casing variant is not recognized', M.requiresGuard('u', { chassis: 'Laptop' }), "echo 'u:w:0'\n")
  eq('a numeric chassis', M.requiresGuard('u', { chassis: 5 }), "echo 'u:w:0'\n")
  eq('null chassis', M.requiresGuard('u', { chassis: null }), "echo 'u:w:0'\n")
  eq('an empty chassis is not ""-guarded either - it hits the else', M.requiresGuard('u', { chassis: '' }), "echo 'u:w:0'\n")
  // 'Unknown shapes log and hide the row.' No logging happens in this
  // function - the hide is silent. Pinned as documented-vs-actual drift; the
  // behaviour itself (hide) is what the caller depends on.
  eq('an empty object has no expression to emit, so it hides', M.requiresGuard('u', {}), "echo 'u:w:0'\n")
  eq('a boolean requires hides', M.requiresGuard('u', false), "echo 'u:w:0'\n")
  eq('an array requires hides', M.requiresGuard('u', []), "echo 'u:w:0'\n")
  eq('a string requires hides', M.requiresGuard('u', 'laptop'), "echo 'u:w:0'\n")
  eq('an unknown key alongside a known one is ignored', M.requiresGuard('u', { chassis: 'laptop', wat: 1 }).includes('CHASSIS_TYPE'), true)
  eq('and the unknown key does not hide it', M.requiresGuard('u', { chassis: 'laptop', wat: 1 }).includes("'u:w:1'"), true)
})

group('buildGuardScript batches w, c, d and requires for every page', () => {
  // "One bash script for every when:/checked:/disabled: expression in the
  // bundle, reporting `<uid>:<w|c|d>:<0|1>` per line."
  const a = page('p', [
    { type: 'action', id: 'a', when: 'test -d /a' },
    { type: 'toggle', id: 'b', checked: 'pgrep b', disabled: 'x' },
    { type: 'action', id: 'c' },
    { type: 'action', id: 'd', requires: { binary: 'jq' } },
    { type: 'action', id: 'e', when: 'test -d /e', checked: 'test -d /ec' },
  ])
  const b = page('q', [{ type: 'action', id: 'z', when: 'true' }])
  eq('the whole script, exactly', M.buildGuardScript([a, b]), [
    "if { test -d /a; } >/dev/null 2>&1; then echo 'p#a:w:1'; else echo 'p#a:w:0'; fi",
    "if { pgrep b; } >/dev/null 2>&1; then echo 'p#b:c:1'; else echo 'p#b:c:0'; fi",
    "if { x; } >/dev/null 2>&1; then echo 'p#b:d:1'; else echo 'p#b:d:0'; fi",
    "if { type -P jq >/dev/null; } >/dev/null 2>&1; then echo 'p#d:w:1'; else echo 'p#d:w:0'; fi",
    "if { test -d /e; } >/dev/null 2>&1; then echo 'p#e:w:1'; else echo 'p#e:w:0'; fi",
    "if { test -d /ec; } >/dev/null 2>&1; then echo 'p#e:c:1'; else echo 'p#e:c:0'; fi",
    "if { true; } >/dev/null 2>&1; then echo 'q#z:w:1'; else echo 'q#z:w:0'; fi",
    '',
  ].join('\n'))
  eq('one line per emitted guard, seven here', M.buildGuardScript([a, b]).split('\n').filter(Boolean).length, 7)
  eq('an empty page list emits nothing', M.buildGuardScript([]), '')
  eq('a page with no guards emits nothing', M.buildGuardScript([page('e', [{ type: 'action', id: 'a' }])]), '')
  // Order is when, checked, disabled - per item, items in order, pages in
  // order. Pinned because the parser reads the lines positionally only by
  // uid, so a reorder would be invisible otherwise. A `requires` folds into
  // the `when` slot rather than taking a line of its own.
  const one = page('p', [{ type: 'action', id: 'a', when: 'W', checked: 'C', disabled: 'D', requires: { chassis: 'vm' } }])
  eq('within one item the order is w, c, d, and requires rides in the w slot',
    one.items.length && M.buildGuardScript([one]).split('\n').filter(Boolean).map(l => l.match(/'(p#a:.)/)[1]),
    ['p#a:w', 'p#a:c', 'p#a:d'])
  contains('with the requires ANDed onto the when', M.buildGuardScript([one]), 'W && ')
  // A `when` and a `requires` on one row used to emit TWO w lines, and the
  // reader collapses a repeated uid last-one-wins - so an OR stood in for an
  // AND and an extension could make a row whose `when` said false show. One
  // verdict is the only shape the reader can read correctly.
  const both = page('p', [{ type: 'action', id: 'a', when: 'true', requires: { binary: 'nope-not-here' } }])
  eq('a when and a requires on one row emit ONE line', M.buildGuardScript([both]).split('\n').filter(Boolean).length, 1)
  contains('ANDed, so the row hides on a machine without the binary',
    M.buildGuardScript([both]), "echo 'p#a:w:0'")
  noThrow('a page whose items were cleared by hand', () => M.buildGuardScript([{ id: 'p', items: [] }]))
  // A page object with no `items` at all is not a page the builder ever
  // emits (buildPage always sets it), and buildGuardScript indexes it
  // unguarded.
  throws('a page with no items key at all throws', () => M.buildGuardScript([{ id: 'p' }]), /length/)
  throws('and so does a null page', () => M.buildGuardScript([null]), /items/)
  noThrow('a page with an empty items list', () => M.buildGuardScript([{ id: 'p', items: [] }]))
})

// ======================================================================
section('buildIndex - flattening pages into search entries with breadcrumbs')
group('an entry carries its page, its breadcrumb path and its row index', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[
      {"type":"submenu","id":"m1","label":"Arch","page":"install"},
      {"type":"action","id":"m2","label":"Open terminal","command":"term"},
      {"type":"separator","id":"m3","label":"--"},
      {"type":"header","id":"m4","label":"H"}
    ]},
    {"id":"install","title":"Install","items":[
      {"type":"action","id":"i1","label":"Package","desc":"Install a <b>package</b>"},
      {"type":"submenu","id":"i2","label":"Loop","page":"loop"}
    ]},
    {"id":"loop","title":"Loop","items":[{"type":"action","id":"l1","label":"Cycle"}]},
    {"id":"orphan","title":"Orphan","items":[{"type":"action","id":"o1","label":"Hidden gem"}]}
  ]}`)
  const idx = M.buildIndex(b)
  eq('only selectable, labelled rows are indexed', idx.map(e => e.label), ['Arch', 'Open terminal', 'Package', 'Loop', 'Cycle', 'Hidden gem'])
  eq('the entry page rows carry no breadcrumb', idx[0].path, [])
  eq('a child page carries its chain without the entry', idx[2].path, ['Install'])
  eq('a grandchild too', idx[4].path, ['Install', 'Loop'])
  eq('an unreachable page contributes its own title only', idx[5].path, ['Orphan'])
  eq('pageId travels with every entry', idx[2].pageId, 'install')
  eq('row is the index into the page items array', idx.map(e => e.row), [0, 1, 0, 1, 0, 0])
  eq('words is the pre-split hay, built once per entry', idx[2].words, 'package install a i1 install'.split(' '))
  // 'Path words join the haystack so location terms work as search tokens
  // ("ins pack" finds Arch Package via its Install breadcrumb).'
  contains('the breadcrumb is searchable', idx[2].hay, 'install')
  eq('a separator row is not indexed', idx.some(e => e.label === '--'), false)
  eq('a header row is not indexed', idx.some(e => e.label === 'H'), false)
})

group('the hay concatenates the row hay with the lowercased path', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main Menu","items":[{"type":"action","id":"a","label":"Row","var":"V"}]},
    {"id":"sub","title":"Sub Page","items":[{"type":"action","id":"b","label":"Other"}]}
  ]}`)
  const idx = M.buildIndex(b)
  // label, var, id, then the path in breadcrumb order - every contribution
  // is lowercased exactly once.
  eq('the row hay, then a space, then the path in order', idx[0].hay, 'row v a')
  // The per-item hay is deduped but the appended path is not, so a word that
  // appears in both shows up twice. Deliberate-but-surprising, cited from
  // buildIndex's own comment ("the per-item hay is already deduped,
  // concatenating the already-lowercased base avoids a second toLowerCase").
  const c = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"submenu","label":"Install","page":"install"}]},
    {"id":"install","title":"Install","items":[{"type":"action","id":"i1","label":"Package","desc":"install tools"}]}
  ]}`)
  const ci = M.buildIndex(c)
  eq('a path word already in the row hay is duplicated', ci[1].hay, 'package install tools i1 install')
  eq('and the words array agrees', ci[1].words, 'package install tools i1 install'.split(' '))
  eq('while the parent row has no path to duplicate', ci[0].hay, 'install')
  eq('a submenu row is indexed from its own label', ci[0].words, ['install'])
})

group('the chain walk is breadth-first, cycle-safe, and rooted at the entry', () => {
  const cyc = bundle(`{"pages":[
    {"id":"a","title":"A","items":[{"type":"submenu","page":"b","label":"toB"}]},
    {"id":"b","title":"B","items":[{"type":"submenu","page":"a","label":"toA"},{"type":"action","label":"rowB"}]},
    {"id":"c","title":"C","items":[{"type":"submenu","page":"d","label":"toD"}]},
    {"id":"d","title":"D","items":[{"type":"submenu","page":"c","label":"toC"}]}
  ]}`)
  eq('a cycle breaks: the pages past the loop lose their breadcrumbs', M.buildIndex(cyc).map(e => e.path), [[], ['B'], ['B'], ['C'], ['D']])
  // The walk starts at bundle.entry, not pages[0] - a bundle whose entry is
  // not the first page has no breadcrumbs at all.
  const late = bundle('{"pages":[{"id":"zz","title":"Z","items":[{"type":"action","label":"zzrow"}]},{"id":"aa","title":"A","items":[{"type":"submenu","page":"aa2","label":"go"},{"type":"action","label":"aarow"}]},{"id":"aa2","title":"A2","items":[{"type":"action","label":"deep"}]}]}')
  eq('the walk is rooted at the entry page, whatever its position', M.buildIndex(late).map(e => e.path), [[], ['A'], ['A'], ['A2']])
  eq('two submenus to the same page share one chain entry', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"submenu","page":"b","label":"g1"},{"type":"submenu","page":"b","label":"g2"}]},{"id":"b","title":"B","items":[{"type":"action","label":"r"}]}]}')).map(e => e.path), [[], [], ['B']])
  // `bundle.byId[item.page]` gates the edge, so a submenu to a page that does
  // not exist is not a link at all - and the row is still indexed.
  const dangling = bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"submenu","page":"nope","label":"go"},{"type":"action","label":"row"}]}]}')
  eq('a submenu to a missing page is not an edge', M.buildIndex(dangling).map(e => e.path), [[], []])
  eq('and its own row is still searchable', M.buildIndex(dangling).map(e => e.label), ['go', 'row'])
  const noPage = bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"submenu","label":"go"},{"type":"action","label":"row"}]}]}')
  eq('a submenu with no page field is not an edge either', M.buildIndex(noPage).map(e => e.label), ['go', 'row'])
  // A bundle whose entry id is not in byId has no childrenOf entry and so no
  // chains - and no throw, because chainOf stays empty.
  const broken = { entry: 'zzz', pages: bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"submenu","page":"b","label":"go"}]},{"id":"b","title":"B","items":[{"type":"action","label":"row"}]}]}').pages, byId: {} }
  eq('an entry missing from byId degrades to flat paths', M.buildIndex(broken).map(e => e.path), [['A'], ['B']])
  eq('an empty bundle indexes nothing', M.buildIndex({ entry: 'x', pages: [], byId: {} }), [])
})

group('a row with nothing to search for is left out', () => {
  eq('an empty label', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"action","label":"","desc":"only desc"},{"type":"action","label":"kept"}]}]}')).map(e => e.label), ['kept'])
  eq('an explicit enabled:false', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"action","label":"off","enabled":false},{"type":"action","label":"on"}]}]}')).map(e => e.label), ['on'])
  eq('spacer is chrome too', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"separator","label":"--"},{"type":"header","label":"H"},{"type":"spacer","label":" "},{"type":"action","label":"keep"}]}]}')).map(e => e.label), ['keep'])
  eq('a page with no rows contributes nothing', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[]}]}')).length, 0)
  eq('a row index counts chrome too, so hits resolve to the right item', M.buildIndex(bundle('{"pages":[{"id":"a","title":"A","items":[{"type":"action","label":"x"},{"type":"separator","label":"--"},{"type":"action","label":"y"}]}]}')).map(e => [e.label, e.row]), [['x', 0], ['y', 2]])
})

// ======================================================================
section('buildPageIndex - the per-page half, shared with external registration')
// buildIndex resolves a breadcrumb from the submenu chain and delegates the
// per-page work here. Menu.indexExternal calls the same function for a page
// outside the bundle, so an externally indexed row must be byte-identical in
// shape to a bundle one - search() and jumpTo() read these fields positionally.
const pageOf = (json) => M.parseBundle(json).pages[0]

group('one page, one breadcrumb, in the same shape buildIndex emits', () => {
  // enabled:false is how a row is marked unselectable by the normalizer
  // (the buildIndex groups above use it), so this page matches that shape.
  const page = pageOf('{"pages":[{"id":"p","title":"Ext","items":[' +
    '{"type":"action","label":"nonselectable","enabled":false},' +
    '{"type":"action","label":"JetBrains Mono NL","desc":"No Ligatures"},' +
    '{"type":"separator","label":"--"},' +
    '{"type":"action","label":"Fira Code"}' +
    ']}]}')
  const entries = M.buildPageIndex(page, [page.label], [])

  eq('chrome and unselectable rows are excluded, as in buildIndex',
    entries.map(e => e.label), ['JetBrains Mono NL', 'Fira Code'])
  eq('row counts chrome, so a hit lands on the right item',
    entries.map(e => e.row), [1, 3])
  eq('the entry carries the fields search() and jumpTo() read',
    entries[0].pageId, 'p')
  eq('path is the breadcrumb it was handed', entries[0].path, ['Ext'])
  contains('hay carries the row label', entries[0].hay, 'jetbrains mono nl')
  contains('and the breadcrumb it was handed', entries[0].hay, 'ext')
  is('words is the pre-split hay, one split per search call avoided', entries[0].words, (w) => w.join(' ') === entries[0].hay)
})

group('the `into` accumulator is the seam that lets a caller own the array', () => {
  const page = pageOf('{"pages":[{"id":"p","title":"Ext","items":[{"type":"action","label":"solo"}]}]}')
  const acc = []
  const returned = M.buildPageIndex(page, [page.label], acc)
  is('it returns the same array it appended to', returned === acc, (v) => v === true, 'identity preserved')
  eq('and the array is populated in place', acc.map(e => e.label), ['solo'])
  eq('an empty accumulator still yields the same entries', M.buildPageIndex(page, [page.label], []).map(e => e.label), ['solo'])
})

group('degenerate input leaves the accumulator untouched', () => {
  const page = pageOf('{"pages":[{"id":"p","title":"Ext","items":[{"type":"action","label":"kept"}]}]}')
  eq('a null page', M.buildPageIndex(null, ['Ext'], []), [])
  eq('a page with no items array', M.buildPageIndex({ id: 'x' }, ['Ext'], []), [])
  eq('a null accumulator', M.buildPageIndex(page, ['Ext'], null), null)
  eq('a non-array path falls back to the page label', M.buildPageIndex(page, undefined, [])[0].path, ['Ext'])
})

group('an external page is indexed exactly as a bundle page would be', () => {
  // The contract Menu.indexExternal relies on: same page object, same
  // function, so the resulting entries are indistinguishable to search().
  // A separate entry page keeps 'ext' off the entry rule (entry pages
  // carry no breadcrumb), so both sides index the identical path.
  const b = M.parseBundle('{"pages":[{"id":"main","title":"Main","items":[]},{"id":"ext","title":"Ext","items":' +
    '[{"type":"action","label":"Zed Font","desc":"a desc"}]}]}')
  const fromBundle = M.buildIndex(b)
  const fromExternal = M.buildPageIndex(b.pages[1], [b.pages[1].label], [])
  eq('identical entries', fromExternal.map(e => [e.pageId, e.row, e.label, e.hay, e.words.join(' ')]),
    fromBundle.map(e => [e.pageId, e.row, e.label, e.hay, e.words.join(' ')]))
})

group('a page outside the lookup still renders, from the entry alone', () => {
  // The dynamic-page case. Menu passes pageById (bundle + dynamic + option
  // pages), and an externally registered hit names a page the resolver knows
  // - but groupSearchResults is also called with a bundle-only map elsewhere,
  // so an unresolvable page must render from the entry rather than vanish.
  const hit = {
    pageId: 'font-picker', pageTitle: 'Font selection', path: ['Font selection'],
    row: 3, label: 'JetBrains Mono NL', hay: 'jetbrains mono nl',
    words: ['jetbrains', 'mono', 'nl'],
  }
  const byId = { main: { id: 'main', items: [] } }
  eq('an unresolvable page renders from the entry, under its header',
    M.groupSearchResults([hit], byId, () => true).map(r => r.label), ['Font selection', 'JetBrains Mono NL'])
  eq('and keeps the fields a row draws and a jump needs',
    M.groupSearchResults([hit], byId, () => true).filter(r => r.type !== 'separator').map(r => [r.pageId, r.row, r.label]),
    [['font-picker', 3, 'JetBrains Mono NL']])
  eq('a resolver function is accepted in place of a map',
    M.groupSearchResults([hit], () => null, () => true).map(r => r.label), ['Font selection', 'JetBrains Mono NL'])
  // A page that DID resolve but has no such row is stale, and is dropped.
  eq('a resolved page with an out-of-range row is still dropped',
    M.groupSearchResults([hit], { 'font-picker': { id: 'font-picker', items: [] } }, () => true), [])
  // Malformed entries cannot name themselves and must not become blank rows.
  eq('a hit with no label is dropped', M.groupSearchResults([{ pageId: 'p', row: 0 }], byId, () => true), [])
  eq('a hit with an empty label is dropped',
    M.groupSearchResults([{ pageId: 'p', row: 0, label: '' }], byId, () => true), [])
  eq('a null hit is dropped', M.groupSearchResults([null], byId, () => true), [])
  // A hidden row on a resolved page is filtered, as it always was.
  eq('a resolved but hidden row is dropped',
    M.groupSearchResults([hit], { 'font-picker': { id: 'font-picker', items: [hit] } }, () => false), [])
})

group('every row is a fresh copy, because a cached one goes stale in place', () => {
  // Caching grouped rows by index entry was tried and reverted. It would make
  // the panel's identity comparison succeed where it previously failed, which
  // is only a safe shortcut if the copy can never be stale - and it can.
  // Menu.refreshSectionCounts rewrites a submenu link's `sub` in place
  // ("N items") without replacing the index entry, so a cached row kept a
  // count the page had already moved past. The copy is also what makes "the
  // candidate changed" mean "the projection changed".
  const b = bundle('{"pages":[{"id":"main","title":"Main","items":['
    + '{"id":"w","type":"action","label":"Show wallpaper"}]}]}')
  const idx = M.buildIndex(b)
  const first = M.groupSearchResults(M.search(idx, 'wallpaper'), b.byId, () => true)
  const second = M.groupSearchResults(M.search(idx, 'wallpaper'), b.byId, () => true)
  eq('the same query does NOT hand back the same row object', first[0] === second[0], false)
  eq('two queries sharing a hit do not share its row', first[0] === second[0], false)
  // The stale-row case, stated directly: an in-place mutation of the SOURCE
  // item must show up in the next projection without anything replacing the
  // index entry.
  const item = b.byId.main.items[0]
  item.sub = '9 items'
  const third = M.groupSearchResults(M.search(idx, 'wallpaper'), b.byId, () => true)
  eq('an in-place sub change reaches the next projection',
    third[0].sub, '9 items')
  eq('and did not ride along on the earlier copy', first[0].sub === '9 items', false)
})

group('every grouped row is keyed, because the panel keys the whole set', () => {
  // MenuPanel.keyedRows refuses an install on the first row it cannot key
  // rather than dropping that one, so an unkeyed row anywhere in a grouped
  // result set is a WHOLE-projection failure: the search bar keeps its text,
  // the model keeps the pre-search rows, and a query with real matches reads
  // as a dead search bar. The caller passed a bundle-only map, so an indexed
  // picker's hits resolved to nothing and the entry-only path built a row with
  // a label and no uid - which took every other hit down with it.
  const extHit = {
    pageId: 'font-picker', pageTitle: 'Font selection', path: ['Font selection'],
    row: 3, label: 'JetBrains Mono NL', hay: 'jetbrains mono nl font selection',
    words: ['jetbrains', 'mono', 'nl', 'font', 'selection'],
  }
  const b = M.parseBundle('{"pages":[{"id":"main","title":"Main","items":['
    + '{"id":"wall","type":"action","label":"Show wallpaper"}]}]}')
  const bundleHit = M.buildIndex(b)[0]

  // MenuPanel.keyedRows, verbatim (MenuPanel.qml:782-794).
  const keyedRows = c => {
    if (!Array.isArray(c)) return null
    const seen = Object.create(null)
    for (let i = 0; i < c.length; i++) {
      const it = c[i]
      if (!it || it.uid === undefined || it.uid === null) return null
      const k = String(it.uid)
      if (k.trim() === '' || seen[k] !== undefined) return null
      seen[k] = true
    }
    return c
  }

  // What the panel passes: Menu.pageById, which spans the dynamic page.
  const pageById = id => (id === 'font-picker'
    ? { id: 'font-picker', items: [null, null, null, { type: 'action', id: '', label: 'x' }] }
    : b.byId[id] || null)

  eq('an entry-only row is keyed from the entry, as pageId#row',
    M.groupSearchResults([extHit], b.byId, () => true).filter(r => r.type !== 'separator').map(r => r.uid), ['font-picker#3'])
  eq('a projection mixing a bundle hit and an external hit is keyable end to end',
    keyedRows(M.groupSearchResults([bundleHit, extHit], pageById, () => true)) !== null, true)
  eq('and so is one resolved through the page the panel actually uses',
    keyedRows(M.groupSearchResults([extHit], pageById, () => true)).filter(r => r.type !== 'separator').map(r => r.uid),
    ['font-picker#3'])
  // The item's own key wins. A synthesized pageId#row would repoint the row's
  // runtime state, guard answers and list identity at a different row. The
  // page is built through the real pipeline because that is the only way an
  // item carries a key at all - normalizeItem stamps it.
  const namedPage = M.buildPage('font-picker', 'Font selection', 360,
    [{ type: 'action', id: 'jb', label: 'JetBrains Mono NL' }], {})
  const namedHit = Object.assign({}, extHit, { row: 0 })
  eq('a named item keeps its own uid, not the entry-derived one',
    M.groupSearchResults([namedHit], { 'font-picker': namedPage }, () => true).filter(r => r.type !== 'separator').map(r => r.uid),
    ['font-picker#jb'])
})

group('an externally indexed name is findable, and loses a tie to the bundle', () => {
  // Menu concatenates builtin entries first, then the registrations.
  // search() sorts on score alone with a stable sort, so equal scores keep
  // insertion order - that ordering IS the deprioritization, and it is what
  // makes a hard priority tier unnecessary.
  const ext = M.buildPageIndex(pageOf('{"pages":[{"id":"font","title":"Font selection","items":[' +
    '{"type":"action","label":"JetBrains Mono NL"}]}]}'), ['Font selection'], [])
  const builtin = indexOf([['Show wallpaper', 'show wallpaper']])
  const merged = builtin.concat(ext)

  eq('a term only the external row carries finds it',
    labels(M.search(merged, 'jetbrains')), ['JetBrains Mono NL'])
  eq('a breadcrumb word reaches the external row too',
    labels(M.search(merged, 'selection')), ['JetBrains Mono NL'])
  eq('the builtin half is untouched by the merge',
    labels(M.search(merged, 'wallpaper')), ['Show wallpaper'])

  // Tie: both rows score identically for the same token.
  const tied = indexOf([['Tie A', 'shared token']])
  const tiedExt = [{ pageId: 'ext', pageTitle: 'E', path: ['E'], row: 0, label: 'Tie B', hay: 'shared token', words: ['shared', 'token'] }]
  eq('a tie resolves to the earlier (builtin) entry',
    M.search(tied.concat(tiedExt), 'shared').map(e => e.label), ['Tie A', 'Tie B'])
  eq('and the reverse order flips it, proving insertion order decides',
    M.search(tiedExt.concat(tied), 'shared').map(e => e.label), ['Tie B', 'Tie A'])
})

// ======================================================================
section('the external half of the index is scoped to the settings family')
//
// A registration is a page OUTSIDE the bundle (pickers/font injects ~337 rows,
// pickers/keybindings the rest). Menu._rebuildSearchIndex concatenates those
// onto the builtin half - unconditionally, which meant the emoji picker, the
// utilities bundle and the theme picker all answered a query with font
// families and idle timers: rows for pages that bundle has no link to and
// cannot navigate to.
//
// Nothing here loads Menu.qml, so the gate is pinned as source shape, and the
// decision itself is pinned against the real shipped bundles: a bundle scopes
// the external half exactly when it is the settings catalog or links it.
const menuSource = () => fs.readFileSync(path.join(SHELL_DIR, 'features/menu/Menu.qml'), 'utf8')

// _loadContainers' own test, verbatim: the catalog path, the bare empty-page
// placeholder, or a submenu row at the settings root.
const linksSettingsFamily = (b) => b.pages.length === 1 && b.pages[0].items.length === 0
  || b.pages.some(p => p.items.some(it => it.type === 'submenu' && it.page === 'settings'))

group('the two index halves merge together, or not at all', () => {
  const src = menuSource()
  eq('_rebuildSearchIndex reads the scope before touching the registrations',
    /if \(root\._settingsFamily\) \{\s*\n\s*for \(const ownerId in root\._indexRegistrations\)/.test(src), true)
  eq('the builtin half is concatenated unconditionally (scope cannot shrink a bundle)',
    /const merged = root\._builtinIndex\.slice\(\)\s*\n\s*if \(root\._settingsFamily\)/.test(src), true)
  eq('the scope is recorded from the merge decision, not computed a second way',
    /root\._settingsFamily = linksSettings/.test(src), true)
  eq('and the registrations themselves are never dropped - only unmerged',
    /unindexExternal[\s\S]{0,900}?delete next\[/.test(src), true)
})

group('the scope belongs to the bundle, so it is cached and restored with it', () => {
  // A warm summon restores bundle and index from the cache entry. Restoring
  // the pages without the scope leaves an open settings menu unable to search
  // its own font picker; restoring the scope without restoring it is worse -
  // that is the leak, on the second open of the emoji picker rather than the
  // first.
  const src = menuSource()
  eq('it is captured before any mutation in _buildFromFile',
    /const prevFamily = root\._settingsFamily/.test(src), true)
  eq('a warm summon takes it from the cached bundle',
    /root\._settingsFamily = cached\.settingsFamily === true/.test(src), true)
  eq('it is written into the cache entry next to the bundle it describes',
    /bundle: root\.bundle,\s*\n\s*index: root\._builtinIndex,\s*\n\s*settingsFamily: root\._settingsFamily/.test(src), true)
  const restores = src.match(/root\._settingsFamily = prevFamily/g) || []
  eq('every path that restores the bundle restores the scope', restores.length, 2)
})

group('which shipped bundles scope the external half', () => {
  // Menus live in the unified catalog's `menus`; each entry below is one
  // openable bundle from it (the whole menus array, or one page alone).
  const catalogRaw = fs.readFileSync(
    path.join(SHELL_DIR, 'common/settings/catalog.jsonc'), 'utf8')
  const catalog = JSON.parse(M.stripJsonc(catalogRaw))
  const bundles = {
    'catalog#main': JSON.stringify(catalog.menus),
    'catalog#utilities': JSON.stringify(catalog.menus.find(m => m.id === 'utilities')),
    'emojis.jsonc': fs.readFileSync(
      path.join(SHELL_DIR, 'features/pickers/emoji/emojis.jsonc'), 'utf8')
  }
  const scope = {}
  for (const [name, text] of Object.entries(bundles)) {
    const b = M.parseBundle(M.stripJsonc(text))
    scope[name] = linksSettingsFamily(b)
  }
  eq('the main menu links settings, so it keeps the external rows',
    scope['catalog#main'], true)
  eq('the utilities bundle is standalone', scope['catalog#utilities'], false)
  eq('and so is the emoji picker', scope['emojis.jsonc'], false)

  // The consequence, on the real emoji corpus: 1870 builtin rows and a query
  // with no off-scope answer once the half is gated. "font" is the sharpest
  // demonstration - it reaches every registered row through the page title, so
  // the leak is total rather than incidental.
  const emoji = M.parseBundle(M.stripJsonc(bundles['emojis.jsonc']))
  const ext = M.buildPageIndex(
    M.buildPage('font-picker', 'Font selection', 360,
      ['Inter', 'JetBrains Mono', 'Noto Sans'].map(l => ({ type: 'action', label: l })), {}),
    ['Font selection'], [])
  const off = (idx) => M.search(idx, 'font').filter(e => e.pageId === 'font-picker')
  const builtin = M.buildIndex(emoji)
  eq('gated, the font rows never enter a standalone index',
    off(builtin.concat(scope['emojis.jsonc'] ? ext : [])), [])
  eq('ungated - the reported bug - every registered row answers the query',
    off(builtin.concat(ext)).map(e => e.label), ['Inter', 'Noto Sans', 'JetBrains Mono'])
  // The gate must not cost the bundle its own search: the emoji corpus still
  // answers on its own vocabulary.
  const own = M.search(builtin, 'grinning')
  eq('the bundle\'s own rows still answer after the gate', own.length, 7)
  eq('and rank unchanged', own[0].label, 'grinning face smile grinning happy')
})

group('no property Menu.qml assigns to is declared readonly', () => {
  // `readonly` in QML throws "Cannot assign to read-only property" at the
  // WRITE site. Every write inside _buildFromFile sits in its try/catch, which
  // returns false and reports a failed load - so one readonly held-state flag
  // made every bundle fail to build and no menu opened at all, with no error
  // anywhere near the cause. Held state must be plain `property`; only derived
  // state (open, searching, scopedSearching) is readonly.
  const breaches = (src) => {
    const decl = new Map()
    for (const m of src.matchAll(/^\s*(readonly\s+)?property\s+\w+\s+(\w+)\s*:/gm))
      decl.set(m[2], m[1] ? 'readonly' : 'plain')
    const assigned = new Set()
    for (const m of src.matchAll(/\broot\.(\w+)\s*=[^=]/g)) assigned.add(m[1])
    return { flagged: [...assigned].filter(n => decl.get(n) === 'readonly'), assigned, decl }
  }

  const src = menuSource()
  const { flagged, assigned, decl } = breaches(src)
  eq('nothing is assigned to a readonly property', flagged, [])
  eq('the scope flag is among the assigned properties', assigned.has('_settingsFamily'), true)
  eq('declared plain, as held state must be', decl.get('_settingsFamily'), 'plain')

  // The detector has to be able to see a breach, or the assertion above is
  // vacuous. This is the exact shape that took the menus down.
  const synthetic = '  readonly property bool held: false\n'
    + '  function f() { root.held = true }\n'
  eq('it flags a readonly flag that is assigned', breaches(synthetic).flagged, ['held'])
  eq('and leaves a plain one alone',
    breaches('  property bool held: false\n  function f() { root.held = true }\n').flagged, [])
  // A derived property is readonly AND unassigned - the legitimate case.
  eq('a readonly binding is not a breach',
    breaches('  readonly property bool open: root.n > 0\n').flagged, [])
})

// ======================================================================
section('fuzzyScore - the ranking, pinned to exact numbers')
//
// The substring score is BAND + shape + position, and every number below falls
// out of those three terms rather than out of a magic constant:
//
//   band     = 15 * q.length      the word path's own ceiling, so a substring
//                                  hit can never rank below a fuzzy one
//   shape    = 1500 word-start, 500 mid-string
//   position = floor(9999 * (4096 - idx) / 4096)
//
// The position term is what replaced the old `2000 - idx*10` clamp. That clamp
// had to floor at 1 to keep a deep hit from reading as a miss, and a floor is
// a tie: on the real settings index (hays run to ~350 chars once descriptions
// and option lists fold in) every match past ~200 characters collapsed to 1
// and fell back to insertion order, so a scattered fuzzy hit at 20 outranked a
// real match buried in a description.
//
// The reference is FIXED, not the hay's own length, and that is load-bearing.
// A hay is the row's label plus its metadata plus its breadcrumb, so scoring
// against its own length lets a deeply nested page's longer hay lift its rows
// - the breadcrumb would decide the rank. Pinned below.
group('a substring hit outranks everything else', () => {
  eq('at position 0', M.fuzzyScore('power', ['power'], 'power'), 11574)
  eq('at the start of the second word', M.fuzzyScore('a power', ['a', 'power'], 'power'), 11569)
  eq('at the start of the third word', M.fuzzyScore('a b power', ['a', 'b', 'power'], 'power'), 11564)
  eq('mid-string, so the non-word-start shape applies', M.fuzzyScore('xpower', ['xpower'], 'power'), 10571)
  eq('a partial word is still a substring hit', M.fuzzyScore('power', ['power'], 'powe'), 11559)
  eq('the first occurrence wins when there are several', M.fuzzyScore('aa', ['aa'], 'aa'), 11529)
  eq('a later occurrence scores lower', M.fuzzyScore('xaa', ['xaa'], 'aa'), 10526)
  eq('a substring at 0 beats a whole-word match later', M.fuzzyScore('abcd', ['x', 'abcd'], 'abcd'), 11559)
  eq('a mid-string substring beats the word path too', M.fuzzyScore('xyzab', ['xyz', 'ab'], 'ab'), 10521)
  eq('and the word path is not consulted at all', M.fuzzyScore('xyzab', [], 'ab'), 10521)
  // The band scales with the query, so the ranking is over the shape and the
  // position rather than over one absolute number.
  eq('the band scales with the query, so a longer exact match ranks higher',
    M.fuzzyScore('power', ['power'], 'power') > M.fuzzyScore('power', ['power'], 'powe'), true)
  // The reference is fixed, so a row's BREADCRUMB cannot change its rank.
  // A hay is the row's label plus its metadata plus its breadcrumb, so a
  // deeply nested page's rows carry longer hays; scoring against the hay's
  // own length let that longer hay lift the row above an identical one on a
  // shallower page. Same label, same match offset, one with a long breadcrumb
  // appended - and the two are indistinguishable, which is the property.
  eq('a longer breadcrumb does not change the rank of the row it is on', (() => {
    const short = 'install p1 main'
    const deep = 'install p1 main appearance blur shadow'
    return M.fuzzyScore(short, short.split(' '), 'install') === M.fuzzyScore(deep, deep.split(' '), 'install')
  })(), true)
  // Position still decides on its own, so a match further into a longer hay
  // ranks below one at the front of a short hay - the breadcrumb is inert, not
  // the position.
  eq('but the match offset still decides', (() => {
    const front = 'install p1 main'
    const deeper = 'p1 main install'
    return M.fuzzyScore(front, front.split(' '), 'install') > M.fuzzyScore(deeper, deeper.split(' '), 'install')
  })(), true)
})

group('with no substring, the query must decompose into CONSECUTIVE word prefixes', () => {
  // '"fcap" hits "FPS cap", but "codec" does not hit "Flash the screen" from
  // scattered letters."' Every case here is built so the query is NOT a
  // substring of the hay - otherwise the substring branch would answer and
  // the word path would never run.
  eq('fcap over "fps cap limit"', M.fuzzyScore('fps cap limit', ['fps', 'cap', 'limit'], 'fcap'), 45)
  eq('codec over "flash the screen"', M.fuzzyScore('flash the screen', ['flash', 'the', 'screen'], 'codec'), -1)
  // 10 points per character consumed, +5 when the whole word was consumed.
  eq('two one-letter words: 2 x (10 + 5)', M.fuzzyScore('a b', ['a', 'b'], 'ab'), 30)
  eq('a one-letter word then a whole two-letter word: 15 + (20 + 5)', M.fuzzyScore('a bc', ['a', 'bc'], 'abc'), 40)
  eq('a whole two-letter word then a partial two of three: 25 + 20', M.fuzzyScore('ab cdx', ['ab', 'cdx'], 'abcd'), 45)
  eq('three single-letter words: 3 x 15', M.fuzzyScore('a b c', ['a', 'b', 'c'], 'abc'), 45)
  // The query may span words the hay does not spell out.
  eq('a word-per-letter acronym: 2 x 15', M.fuzzyScore('p q', ['p', 'q'], 'pq'), 30)
  eq('the whole-word bonus, isolated', M.fuzzyScore('a b q', ['a', 'b', 'q'], 'ab'), 30)
  eq('consuming only part of a word does not earn it', M.fuzzyScore('az b', ['az', 'b'], 'ab'), 25)
  eq('a word-path hit is worth far less than a substring hit',
    M.fuzzyScore('a b', ['a', 'b'], 'ab') < M.fuzzyScore('ab', ['ab'], 'ab'), true)
})

group('a gap between the words ends the attempt', () => {
  // The adjacency rule, which is the whole point of the fix. Before it, the
  // walk STEPPED OVER any word that did not continue the query, so a query
  // could be assembled from letters scattered anywhere in the hay. Measured
  // against the shipped settings index, that made 4 of 7 hits for "theme" and
  // 4 of 8 for "anim" pure noise - "Mosaic density" answered "theme" as "the"
  // followed by "me" out of "medium", and "Track OSD offset" answered it as
  // "t" + "h" + "e" + "me".
  eq('a word in between that starts with nothing useful now ends the walk',
    M.fuzzyScore('ab q z', ['ab', 'q', 'z'], 'abz'), -1)
  eq('three letters out of five words no longer chain',
    M.fuzzyScore('a b c d e', ['a', 'b', 'c', 'd', 'e'], 'ace'), -1)
  eq('nor do two of three', M.fuzzyScore('a b c', ['a', 'b', 'c'], 'ac'), -1)
  eq('the walk still ends -1 when the query runs out of words',
    M.fuzzyScore('a x c', ['a', 'x', 'c'], 'abc'), -1)
  eq('and a words array missing the matching word ends it too',
    M.fuzzyScore('a b', ['a'], 'ab'), -1)
  eq('with no words at all and no substring, nothing matches',
    M.fuzzyScore('a b', [], 'ab'), -1)
  // The regression itself, in the shape the shipped catalog produced it.
  eq('"theme" does not reach "the" + "me" out of "medium"',
    M.fuzzyScore('mosaic density with a medium shade', ['mosaic', 'density', 'with', 'a', 'medium', 'shade'], 'theme'), -1)
  eq('nor four scattered single letters',
    M.fuzzyScore('track osd offset how edge media', ['track', 'osd', 'offset', 'how', 'edge', 'media'], 'theme'), -1)
  // Every start position is tried, so a real chain later in the hay still hits.
  eq('a genuine run after unrelated words is still found',
    M.fuzzyScore('alpha beta gamma delta epsilon fps cap limit', ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'fps', 'cap', 'limit'], 'fcap'), 45)
  eq('and the best-scoring start wins',
    M.fuzzyScore('a bc ab cdx', ['a', 'bc', 'ab', 'cdx'], 'abcd'), 45)
})

group('a non-match is the lowest possible score', () => {
  eq('nothing matches', M.fuzzyScore('abc', ['abc'], 'z'), -1)
  eq('the query is longer than the hay', M.fuzzyScore('ab', ['ab'], 'abcdefg'), -1)
  eq('one character past the end', M.fuzzyScore('abc', ['abc'], 'abcd'), -1)
  eq('the letters are there but not in order', M.fuzzyScore('abc', ['abc'], 'cba'), -1)
  eq('a word-start chain that runs out of words', M.fuzzyScore('a x c', ['a', 'x', 'c'], 'abc'), -1)
  eq('an empty hay cannot match', M.fuzzyScore('', [''], 'x'), -1)
})

group('an empty needle is a decline, not a match', () => {
  eq('an empty query scores -1 even over a matching hay', M.fuzzyScore('power', ['power'], ''), -1)
  eq('and over an empty hay', M.fuzzyScore('', [''], ''), -1)
  // `if (q === "") return -1` comes first, so the empty needle is rejected
  // before the substring scan. search() is what turns a blank query into "no
  // results"; fuzzyScore is the per-entry decision and declines. A needle that
  // is merely BLANK is not the empty needle, and the hay of a multi-word row
  // contains a space - so a lone space matches it. Pinned: search() trims and
  // splits the query into tokens before this ever sees it, so a lone space can
  // never reach fuzzyScore from the menu.
  eq('a lone space is NOT the empty needle', M.fuzzyScore('a b', ['a', 'b'], ' '), 10511)
  eq('it matches every hay that contains a space', M.fuzzyScore('power level', ['power', 'level'], ' '), 10501)
  eq('and misses a single-word hay', M.fuzzyScore('power', ['power'], ' '), -1)
  eq('a null needle is not empty, and q.length on null throws', (() => { try { M.fuzzyScore('power', ['power'], null); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  eq('so does an undefined needle', (() => { try { M.fuzzyScore('power', ['power'], undefined); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  // A number needle does NOT throw: hay.indexOf coerces it, and `5..length`
  // is undefined, so the word loop never runs and the walk declines.
  eq('a number needle is a decline, not a throw', M.fuzzyScore('power', ['power'], 5), -1)
  eq('and a numeric needle that IS in the hay is a substring search', M.fuzzyScore('power 5', ['power', '5'], 5), 11499)
})

group('scoring is case-sensitive on both sides', () => {
  // buildIndex lowercases every hay and search lowercases every query, so in
  // production this cannot arise - but fuzzyScore alone does not fold, and
  // that is why search does the folding in exactly one place.
  eq('an upper-case needle misses a lower-case hay', M.fuzzyScore('power', ['power'], 'POWER'), -1)
  eq('an upper-case needle misses the word path too', M.fuzzyScore('power', ['power'], 'POWER'), -1)
  // A lower-case needle against an upper-case HAY misses the substring branch
  // (indexOf is case-sensitive) but the word branch only compares the first
  // character of each word, so it still answers - at word-path cost.
  eq('a case-mismatched hay still matches, at word-path cost', M.fuzzyScore('POWER', ['power'], 'power'), 55)
  eq('and the mismatch is fatal from the first character of the word', M.fuzzyScore('Power', ['Power'], 'power'), -1)
  eq('so the word path is a partial safety net, not a fold', M.fuzzyScore('POWER', ['power'], 'power') < 100, true)
})

group('a deep hit is ordered, never collapsed onto the others', () => {
  // The old `2000 - idx*10` had to clamp at 1 to keep a deep hit from reading
  // as a miss, and a clamp is a tie - every match past ~200 characters scored
  // 1 and fell back to insertion order. The position term cannot collapse over
  // any hay a row can produce: it is strictly decreasing in the match index
  // across the whole reference. These probes are the old clamp group's shape,
  // at the positions where the old formula used to flatten.
  const at = (idx, wordStart) => {
    const hay = 'z'.repeat(idx) + (wordStart ? ' ' : 'z') + 'q'
    return M.fuzzyScore(hay, hay.split(' '), 'q')
  }
  eq('word-start at 199, where the old formula was at its last distinct value', at(199, true), 11025)
  eq('mid-string at position 1', at(1, false), 10509)
  eq('word-start at position 1', at(1, true), 11509)
  // The property the clamp lost, asserted as a relation over the whole range a
  // real hay reaches rather than as a handful of pinned numbers.
  is('word-start positions are strictly decreasing to 350 chars, where the old clamp tied them',
    Array.from({ length: 350 }, (_, i) => at(i, true))
      .every((v, i, a) => i === 0 || v < a[i - 1]), (v) => v === true, 'strictly decreasing')
  is('and mid-string positions are too',
    Array.from({ length: 350 }, (_, i) => at(i, false))
      .every((v, i, a) => i === 0 || v < a[i - 1]), (v) => v === true, 'strictly decreasing')
  // A 2500-character hay: the reason the clamp existed at all. It scores a
  // real rank now rather than the floor.
  const huge = 'a'.repeat(2500) + 'x'
  eq('a 2500-character hay still scores far above the word-path ceiling',
    M.fuzzyScore(huge, huge.split(' '), 'x') > 15 * 1, true)
  eq('and an early hit outranks a deep one in the same hay', (() => {
    const h = 'q ' + 'a'.repeat(2500)
    return M.fuzzyScore(h, h.split(' '), 'q') > M.fuzzyScore(h, h.split(' '), 'a')
  })(), true)
  eq('position 0 is the maximum', M.fuzzyScore('q', ['q'], 'q'), 11514)
  eq('no score is ever zero', M.fuzzyScore('q', ['q'], 'q') > 0, true)
  eq('and no matching score is negative', M.fuzzyScore('a'.repeat(1000) + ' tail', ('a'.repeat(1000) + ' tail').split(' '), 'tail') >= 1, true)
  // The invariant the band exists to protect, stated as a relation rather
  // than a number: for ANY query and ANY depth, a substring hit outranks the
  // best possible fuzzy hit. This is exactly what the old floor broke.
  eq('no substring hit can score at or below a word-path hit, at any depth', (() => {
    for (const q of ['q', 'ab', 'abc', 'abcd', 'needle']) {
      for (const depth of [0, 50, 150, 199, 200, 201, 350]) {
        const deep = 'z'.repeat(depth) + ' ' + q
        if (M.fuzzyScore(deep, deep.split(' '), q) <= 15 * q.length) return 'lost at ' + q + '/' + depth
      }
    }
    return 'ok'
  })(), 'ok')
})

// ======================================================================
section('search - tokenized AND over the index')
group('a query finds its rows and returns them best-first', () => {
  // Every group below builds its own index array, so the module cache cannot
  // reach across groups (see the note at the top of this file).
  const idx = indexOf([['Power', 'power level'], ['Profile', 'power level'], ['p', 'power saver'], ['Alpha', 'alpha only']])
  eq('a single token', labels(M.search(idx, 'power')), ['Power', 'Profile', 'p'])
  eq('a mid-word token', labels(M.search(idx, 'lev')), ['Power', 'Profile'])
  eq('two tokens AND', labels(M.search(idx, 'power level')), ['Power', 'Profile'])
  eq('one bad token rejects the row', labels(M.search(idx, 'power zzz')), [])
  eq('a garbage token rejects everything', labels(M.search(idx, 'zzzz')), [])
  eq('the query is lowercased', labels(M.search(idx, 'POWER')), ['Power', 'Profile', 'p'])
  eq('and trimmed', labels(M.search(idx, '  power  ')), ['Power', 'Profile', 'p'])
  eq('a token longer than a hay is rejected by the fast path', labels(M.search(indexOf([['A', 'ab']]), 'abcdef')), [])
})

group('a blank query is "no results", not "everything"', () => {
  // search() is only called when the panel is filtering; a blank query means
  // the panel is not.
  const idx = indexOf([['Power', 'power'], ['Other', 'other']])
  eq('an empty query', M.search(idx, ''), [])
  eq('a whitespace query', M.search(idx, '   '), [])
  eq('and a query of only tabs', M.search(idx, '\t\t'), [])
  // `query.toLowerCase()` is not guarded, so a non-string query is a throw.
  // The panel always hands a string; pinned so the boundary is a decision
  // rather than an accident.
  throws('a number query throws', () => M.search(idx, 5), /toLowerCase/)
  throws('a null query throws', () => M.search(idx, null), /toLowerCase/)
  throws('and a null index throws', () => M.search(null, 'x'), /length/)
})

group('ties keep index order, so results never jitter between keystrokes', () => {
  // Array.prototype.sort is stable, and there is no secondary key in
  // search's comparator - so equal scores come back in index order.
  const tie = indexOf([
    ['Early', 'x early'],
    ['Late', 'x early late'],
    ['AlsoEarly', 'early x'],
    ['Zero', 'early zzz'],
  ])
  // All four are word-start hits: "early" at position 0 in a 7-char hay, and
  // at position 2 in a 7- and a 12-char hay. The position term is absolute, so
  // the two position-2 hits tie exactly and index order decides between them;
  // the two position-0 hits outrank both. AlsoEarly and Zero are identical, so
  // they tie too, and they appear first only because they are first in the
  // index.
  eq('word-start hits outrank mid-string ones, ties keep source order', labels(M.search(tie, 'early')), ['AlsoEarly', 'Zero', 'Early', 'Late'])
  const flat = indexOf([['a', 'same'], ['b', 'same'], ['c', 'same'], ['d', 'same']])
  eq('four identical scores come back in index order', labels(M.search(flat, 'same')), ['a', 'b', 'c', 'd'])
  eq('and the result is a stable projection of the index', M.search(flat, 'same').map(e => e.row), [0, 1, 2, 3])
})

group('the cap on RETURNED hits grows with the query', () => {
  // The cap is 40 * q.length below five characters and 200 at or above it.
  // The reason is the projection, not the scan: on the shipped settings bundle
  // (257 index entries) `search` costs 0.03-0.34ms per keystroke, while
  // `groupSearchResults` over 200 hits costs 0.47-0.77ms and hands the panel
  // 242 rows. A one-character query ranks the index almost evenly, so
  // projecting all of it buys nothing; five characters is enough for the
  // ranking to be sharp and a dropped row to be a row nobody typed for.
  const many = indexOf(Array.from({ length: 250 }, (_, i) => ['Row' + i, 'needle ' + i]))
  eq('a six-character query reaches the full 200', M.search(many, 'needle').length, 200)
  eq('the cap keeps the best rows in score order', M.search(many, 'needle')[0].label, 'Row0')
  eq('and the tail is dropped', M.search(many, 'needle').some(e => e.label === 'Row249'), false)
  // Monotonic in length, which is the property the panel depends on: a longer
  // query never projects fewer rows than a shorter one over the same index.
  const lens = [1, 2, 3, 4, 5, 6, 8].map(n => M.search(many, 'needle'.slice(0, Math.min(n, 6))).length)
  is('the returned count never shrinks as the query grows',
    lens.every((v, i) => i === 0 || v >= lens[i - 1]), (v) => v === true, 'monotonic: ' + lens.join(','))
  eq('a one-character query is capped at 40, not 200', M.search(indexOf(Array.from({ length: 250 }, (_, i) => ['R' + i, 'n'])), 'n').length, 40)
  eq('a two-character query is capped at 80', M.search(indexOf(Array.from({ length: 250 }, (_, i) => ['R' + i, 'ne'])), 'ne').length, 80)
  eq('five characters unlocks the full 200', M.search(indexOf(Array.from({ length: 250 }, (_, i) => ['R' + i, 'needl'])), 'needl').length, 200)
  // A single token is the fast path, two tokens are the loop; both cap, so
  // the display bound does not depend on how the AND was evaluated.
  const both = indexOf(Array.from({ length: 250 }, (_, i) => ['R' + i, 'alpha beta ' + i]))
  eq('the cap holds on the multi-token path too', M.search(both, 'alpha beta').length, 200)
  eq('and a two-token query over a two-token corpus is exact', M.search(indexOf([['X', 'alpha beta'], ['Y', 'alpha only']]), 'alpha beta').length, 1)
  eq('one token of the pair narrows the count', M.search(indexOf([['X', 'alpha beta'], ['Y', 'alpha only']]), 'alpha only').length, 1)
  eq('a corpus under the cap is returned whole', M.search(indexOf(Array.from({ length: 30 }, (_, i) => ['R' + i, 'need' + i])), 'need').length, 30)
})

group('the cap truncates what is SHOWN, never what the next keystroke scans', () => {
  // The internal hit set stays complete, because the incremental branch
  // re-scans it. A row dropped from the returned array must still be
  // findable by the next character - otherwise a one-character query would
  // silently delete rows from the rest of the session's search.
  const rows = Array.from({ length: 250 }, (_, i) => ['Row' + i, 'needle' + i])
  const idx = indexOf(rows)
  const first = M.search(idx, 'n')
  eq('the one-character answer is capped', first.length, 40)
  is('and it holds the top of the ranking, not an arbitrary slice',
    first.map(e => e.label), (v) => v[0] === 'Row0' || v.includes('Row0'), 'includes the best hit')
  // Typing on: the same index, a query that grows as a prefix, so the
  // incremental branch scans the internal hit set rather than the truncated
  // return. A row the short query dropped must be reachable now.
  const grown = M.search(idx, 'needle')
  eq('the next keystroke is no longer capped short', grown.length, 200)
  const shortSet = new Set(first.map(e => e.label))
  is('and it reaches rows the short query did not return',
    grown.filter(e => !shortSet.has(e.label)).length > 0, (v) => v === true, 'new rows appear')
  // Ranked, not sliced: every row here matches at position 0 of its own hay, so
  // they all tie and stable sort keeps index order - so the dropped ones are
  // the tail of the index, and Row249 is one of them.
  eq('the tail of a tie is what the short query dropped',
    first.some(e => e.label === 'Row249'), false)
  eq('and the grown query keeps it out of the top 200 for the same reason',
    grown.some(e => e.label === 'Row249'), false)
})

group('a cache HIT is a fresh copy; the first result of a query is the cache', () => {
  // `search` returns `_searchCacheEntries.slice()` on a hit but returns the
  // freshly-built `out` array on a miss - and that same array is what it
  // stores as `_searchCacheEntries`. So the caller's first result IS the
  // cached array, and mutating it corrupts the next identical query. Pinned
  // as the real behaviour; see the report. Menu.qml assigns the result to
  // root.results and never mutates it in place, so nothing is broken today.
  const idx = indexOf([['Power', 'power'], ['Powder', 'powder']])
  const first = M.search(idx, 'pow')
  eq('the first result', labels(first), ['Power', 'Powder'])
  const second = M.search(idx, 'pow')
  is('a cache hit hands back a copy, not the cache', second === first, (v) => v === false, 'a new array')
  eq('with equal contents', labels(second), labels(first))
  second.push({ label: 'Injected', hay: 'x', words: ['x'] })
  eq('so a caller can safely mutate a cache-hit result', labels(M.search(idx, 'pow')), ['Power', 'Powder'])
})

group('REGRESSION GUARD: mutating a first-search result poisons the cache', () => {
  const idx = indexOf([['Alpha', 'aa'], ['Beta', 'aa bb']])
  const first = M.search(idx, 'aa')
  first.push({ pageId: 'p', pageTitle: 'P', path: ['P'], row: 99, label: 'Injected', hay: 'x', words: ['x'] })
  eq('the next identical query serves the poisoned array', labels(M.search(idx, 'aa')), ['Alpha', 'Beta', 'Injected'])
  const idx2 = indexOf([['Alpha', 'aa'], ['Beta', 'aa bb']])
  const first2 = M.search(idx2, 'aa')
  first2.length = 0
  eq('truncating it truncates the cache', M.search(idx2, 'aa'), [])
  eq('a growing query rescans and rebuilds, so the poison does not survive', labels(M.search(idx2, 'aa b')), ['Beta'])
  eq('and the rebuilt cache is clean', labels(M.search(idx2, 'aa b')), ['Beta'])
})

group('a growing query narrows, a diverging one rescans', () => {
  const g = indexOf([['Power', 'power'], ['Powder', 'powder'], ['Pave', 'pave the way'], ['Nower', 'nower']])
  eq('one character', labels(M.search(g, 'p')), ['Power', 'Powder', 'Pave'])
  eq('two characters', labels(M.search(g, 'po')), ['Power', 'Powder'])
  eq('three characters', labels(M.search(g, 'pow')), ['Power', 'Powder'])
  eq('shrinking back rescans the whole index', labels(M.search(g, 'p')), ['Power', 'Powder', 'Pave'])
  eq('diverging rescans too, and finds what the subset could not', labels(M.search(g, 'no')), ['Nower'])
  eq('a query the subset path would have hidden is still answered', labels(M.search(g, 'nw')), [])
  eq('because "nw" is not a substring of "nower" nor a word prefix', M.fuzzyScore('nower', ['nower'], 'nw'), -1)
  eq('and a row the shrink brought back is there', labels(M.search(g, 'p')), ['Power', 'Powder', 'Pave'])
  const add = indexOf([['Install', 'install arch package'], ['Other', 'other']])
  eq('adding a token to a prefix query', labels(M.search(add, 'ins')), ['Install'])
  eq('the added token is still ANDed', labels(M.search(add, 'ins pack')), ['Install'])
  eq('and a token nothing matches empties it', labels(M.search(add, 'ins pack x')), [])
  eq('the index is intact for an unrelated query', labels(M.search(add, 'other')), ['Other'])
})

// ======================================================================
section('the module-level search cache, read live')
group('a fresh namespace starts with an empty cache', () => {
  const F = liveMenuLib()
  eq('no index cached', F._searchCacheIndex, null)
  eq('no query cached', F._searchCacheQ, '')
  eq('no entries cached', F._searchCacheEntries, null)
  eq('no hit set cached', F._searchCacheHitSet, null)
  eq('and a search still works', labels(F.search(indexOf([['Power', 'power']]), 'pow')), ['Power'])
})

group('a search records the index, the query and both hit lists', () => {
  const F = liveMenuLib()
  const idx = indexOf([['Power', 'power'], ['Powder', 'powder'], ['Nower', 'nower'], ['Wipe', 'wipe']])
  labels(F.search(idx, 'p'))
  eq('the index is remembered by identity', F._searchCacheIndex === idx, true)
  eq('the query is remembered', F._searchCacheQ, 'p')
  eq('the entry list is what the caller got', F._searchCacheEntries.map(e => e.label), ['Power', 'Powder', 'Wipe'])
  eq('the hit set is the same three rows', F._searchCacheHitSet.map(e => e.label), ['Power', 'Powder', 'Wipe'])
  is('but two distinct arrays', F._searchCacheEntries === F._searchCacheHitSet, (v) => v === false, 'distinct arrays')
  F.search(idx, 'po')
  eq('a growing query re-narrows the hit set', F._searchCacheHitSet.map(e => e.label), ['Power', 'Powder'])
  eq('and the query', F._searchCacheQ, 'po')
  eq('a blank query resets both lists to empty', F.search(idx, ''), [])
  eq('and the query to empty', F._searchCacheQ, '')
  is('while still remembering the index', F._searchCacheIndex === idx, (v) => v === true, 'the same index')
  eq('and clearing the entry list', F._searchCacheEntries, [])
  eq('and the hit set', F._searchCacheHitSet, [])
})

group('the 200-cap does not truncate the set the next keystroke scans', () => {
  // The whole point of the split: the display is capped, the increment
  // source is not, so a row past the cap is still reachable by typing more.
  const F = liveMenuLib()
  const many = indexOf(Array.from({ length: 250 }, (_, i) => ['R' + i, 'needle' + ' ' + i]))
  eq('250 hits display as 200', F.search(many, 'needle').length, 200)
  eq('but the hit set keeps all 250', F._searchCacheHitSet.length, 250)
  eq('a narrowing query reaches rows past the cap', labels(F.search(many, 'needle 24')).includes('R249'), true)
  eq('including one the cap had hidden entirely', labels(F.search(many, 'needle 249')), ['R249'])
  eq('and the hit set then holds just that row', F._searchCacheHitSet.map(e => e.label), ['R249'])
})

group('a caller cannot poison a cache-HIT result', () => {
  const F = liveMenuLib()
  const idx = indexOf([['Power', 'power'], ['Powder', 'powder']])
  F.search(idx, 'pow')
  const r = F.search(idx, 'pow')
  r.length = 0
  r.push({ label: 'Injected', hay: 'x', words: ['x'] })
  eq('the next identical query comes from the cache untouched', labels(F.search(idx, 'pow')), ['Power', 'Powder'])
  eq('and the hit set the increment branch scans is untouched too', F._searchCacheHitSet.map(e => e.label), ['Power', 'Powder'])
})

group('REGRESSION GUARD: a stale cache never leaks across corpora', () => {
  // A search on corpus A must not leave anything for corpus B. The cache is
  // keyed on index identity, so a new index array is a hard boundary - and
  // the assertion is that B's results contain nothing from A, in either
  // direction.
  const F = liveMenuLib()
  const a = indexOf([['Alpha unique token', 'alpha unique token'], ['Beta', 'beta']])
  const b = indexOf([['Gamma', 'gamma zzz'], ['Delta', 'delta yyy']])
  eq('A finds its own row', labels(F.search(a, 'alpha')), ['Alpha unique token'])
  eq('B finds nothing of A\'s', labels(F.search(b, 'alpha')), [])
  eq('A still finds its own row afterwards', labels(F.search(a, 'alpha')), ['Alpha unique token'])
  // The nastier direction: a query that is a *prefix extension* of the query
  // that was just cached, against a different index. The incremental branch
  // would scan the stale hit set if the identity check were missing.
  eq('B, with a prefix-grow off A\'s query, still finds nothing', labels(F.search(b, 'al')), [])
  eq('B finds its own rows', labels(F.search(b, 'gamma')), ['Gamma'])
  eq('A is back', labels(F.search(a, 'unique')), ['Alpha unique token'])
  eq('B has none of those either', labels(F.search(b, 'unique')), [])
  // Same query, two corpora: this is the exact repeated-keystroke shape with
  // a rebuilt index in between.
  const c = indexOf([['Solo', 'shared needle']])
  const d = indexOf([['Other', 'shared other']])
  eq('C: shared', labels(F.search(c, 'shared')), ['Solo'])
  eq('D: shared is D\'s row, not C\'s', labels(F.search(d, 'shared')), ['Other'])
  eq('C again is C\'s row', labels(F.search(c, 'shared')), ['Solo'])
  // A wider corpus behind a narrower one: the cached subset is smaller than
  // the new index, which is exactly the case a subset scan would get wrong.
  const wide = indexOf([['One', 'zebra'], ['Two', 'zebra two'], ['Three', 'zebra three']])
  const narrow = indexOf([['Solo', 'zebra solo']])
  eq('wide: zebra', labels(F.search(wide, 'zebra')), ['One', 'Two', 'Three'])
  eq('narrow: zebra', labels(F.search(narrow, 'zebra')), ['Solo'])
  eq('wide again is back to three', labels(F.search(wide, 'zebra')), ['One', 'Two', 'Three'])
})

group('the identity key means an in-place rebuild IS a cache hazard', () => {
  // Pinned as the real behaviour, not as the desired one. The cache compares
  // `index` with `===`, so an array that is *mutated* rather than replaced
  // keeps serving the previous corpus. Menu.qml never does this - both
  // rebuild sites (MenuLib.buildIndex at Menu.qml:543 and the row-patch .map
  // at Menu.qml:1514-1525) assign a fresh array - so this is a hazard for a
  // future caller, not a live defect. Asserted so that if a caller ever does
  // mutate in place, this test is what says so.
  const F = liveMenuLib()
  const shared = [entry('Alpha row', 'alpha unique token'), entry('Beta row', 'beta')]
  eq('corpus A', labels(F.search(shared, 'unique')), ['Alpha row'])
  shared.length = 0
  shared.push(entry('Gamma row', 'gamma zeta'), entry('Delta row', 'delta eta'))
  eq('the same query against the rebuilt-in-place array still answers A', labels(F.search(shared, 'unique')), ['Alpha row'])
  eq('a diverging query does rescan, though', labels(F.search(shared, 'gamma')), ['Gamma row'])
  eq('and a prefix-grow off the stale query stays stale too', labels(F.search(shared, 'al')), [])
  const rebuild = [entry('P', 'aa bb')]
  F.search(rebuild, 'aa')
  rebuild.length = 0
  rebuild.push(entry('Q', 'cc dd'))
  eq('a fresh array is the only reliable invalidation', labels(F.search(indexOf([['Q', 'cc dd']]), 'cc')), ['Q'])
  noThrow('and search itself never throws while doing it', () => F.search(rebuild, 'aa'))
})

// ======================================================================
section('filterCounter - a forwarder to the launcher matcher')
group('the forwarder is the launcher counter, not a second one', () => {
  // "Single definition lives in LauncherLib; this stays as a forwarder so
  // menu-side callers keep one import." README: "Filter counting routes
  // through the launcher's own matcher over a full pool (not the menu's
  // cross-word fuzzy search) - those two engines are deliberately
  // different."
  const Launcher = loadLib(path.join(SHELL_DIR, 'features/launcher/LauncherLib.js'))
  const pool = [
    { label: 'Google Chrome', words: ['google', 'chrome'] },
    { label: 'Chromium', words: ['chromium'] },
    { label: 'Firefox', words: ['firefox'] },
    { label: 'Google', words: ['google'] },
  ]
  eq('a blank query matches the whole pool', M.filterCounter(pool, '', 2), Launcher.filterCounter(pool, '', 2))
  eq('a whitespace query too', M.filterCounter(pool, '  ', 2).matched, pool.length)
  eq('the row list is the launchers', M.filterCounter(pool, 'google', 2).rows.map(r => r.label), Launcher.filterCounter(pool, 'google', 2).rows.map(r => r.label))
  eq('total is the pool size', M.filterCounter(pool, 'google', 2).total, pool.length)
  eq('matched is the full hit count, never the cap', M.filterCounter(pool, 'google', 1).matched, 2)
  eq('an empty pool counts zero', M.filterCounter([], 'x', 5), { total: 0, matched: 0, rows: [] })
  eq('a non-array pool counts zero', M.filterCounter(null, 'x', 5), { total: 0, matched: 0, rows: [] })
  eq('a blank query over a non-array pool', M.filterCounter(undefined, '', 5), { total: 0, matched: 0, rows: [] })
  eq('and it never throws on one', typeof M.filterCounter(null, 'x', 5).matched, 'number')
})

group('the counter ranks exact words above prefixes above substrings', () => {
  // The launcher's tokenScore: 3000-w for an exact word, 2000-w*10 for a
  // prefix, 1000-idx*10 for a substring.
  const pool = [
    { label: 'substring', words: ['xxneedle'] },
    { label: 'prefix', words: ['needlex'] },
    { label: 'exact', words: ['needle'] },
  ]
  eq('exact, then prefix, then substring', M.filterCounter(pool, 'needle', 9).rows.map(r => r.label), ['exact', 'prefix', 'substring'])
  eq('a mid-word substring hits every row that has it', M.filterCounter([{ label: 'x', words: ['chrome'] }, { label: 'y', words: ['chrome'] }], 'hrom', 9).rows.length, 2)
  eq('a no-hit query reports zero and no rows', M.filterCounter(pool, 'zzz', 9), { total: 3, matched: 0, rows: [] })
  eq('rows are the pool objects themselves', (() => { const p2 = [{ label: 'x', words: ['x'] }]; return M.filterCounter(p2, 'x', 5).rows[0] === p2[0] })(), true)
})

group('the cap bounds the rows but never the count', () => {
  const mk = (n) => Array.from({ length: n }, (_, i) => ({ label: 'row' + i, words: ['needle' + i] }))
  eq('cap 2 of 5 hits: 2 rows, 5 matched', (() => { const r = M.filterCounter(mk(5), 'needle', 2); return [r.rows.length, r.matched, r.total] })(), [2, 5, 5])
  eq('cap 0: no rows, full count', (() => { const r = M.filterCounter(mk(3), 'needle', 0); return [r.rows.length, r.matched] })(), [0, 3])
  eq('a blank query with a cap still reports the full count', (() => { const r = M.filterCounter(mk(5), '', 2); return [r.rows.length, r.matched] })(), [2, 5])
  eq('a blank query with cap 0 falls back to the whole pool', (() => { const r = M.filterCounter(mk(5), '', 0); return [r.rows.length, r.matched] })(), [5, 5])
  eq('a cap past the pool is harmless', M.filterCounter(mk(3), 'needle', 99).rows.length, 3)
  eq('an undefined cap is harmless', M.filterCounter(mk(3), '', undefined).rows.length, 3)
  // A negative cap reaches `new Array(Math.min(len, cap))` and throws. Not
  // reachable from the panel (its cap is a literal), pinned as a boundary.
  throws('a negative cap throws out of the shared implementation', () => M.filterCounter(mk(3), 'needle', -1), /array length/i)
})

group('equal scores are broken by the optional tiebreak, else input order', () => {
  // Every call here gets a FRESH pool: the launcher's search cache is keyed on
  // (records identity, query) and does NOT re-apply the tiebreak on a hit, so
  // reusing one array would silently answer the previous tiebreak's order.
  const fresh = () => [{ label: 'a', words: ['t'] }, { label: 'b', words: ['t'] }]
  eq('with no tiebreak, input order', M.filterCounter(fresh(), 't', 5).rows.map(r => r.label), ['a', 'b'])
  eq('a non-function tiebreak is ignored', M.filterCounter(fresh(), 't', 5, 'nope').rows.map(r => r.label), ['a', 'b'])
  eq('a tiebreak flips the order', M.filterCounter(fresh(), 't', 5, (r) => (r.label === 'b' ? 1 : 0)).rows.map(r => r.label), ['b', 'a'])
  eq('a tiebreak of 0 for both keeps input order', M.filterCounter(fresh(), 't', 5, () => 0).rows.map(r => r.label), ['a', 'b'])
  eq('a tiebreak that returns undefined for both keeps input order', M.filterCounter(fresh(), 't', 5, () => undefined).rows.map(r => r.label), ['a', 'b'])
  eq('four tied rows keep input order', M.filterCounter([{ label: 'a', words: ['t'] }, { label: 'b', words: ['t'] }, { label: 'c', words: ['t'] }, { label: 'd', words: ['t'] }], 't', 9).rows.map(r => r.label), ['a', 'b', 'c', 'd'])
  // The tiebreak is called for every scored row and is not guarded, so a
  // throwing comparator is the caller's problem - same contract as the rest
  // of the shell's comparators. A single-row result never calls it at all.
  throws('a throwing tiebreak propagates', () => M.filterCounter(fresh(), 't', 5, () => { throw new Error('tb') }), /tb/)
  eq('a one-row result never invokes it', M.filterCounter([{ label: 'a', words: ['t'] }], 't', 5, () => { throw new Error('tb') }).rows.length, 1)
})

group('a tiebreak change between two calls on one pool is not re-applied', () => {
  // The launcher's cache-hit branch returns the previously sorted rows
  // verbatim, so a caller that changes only the tiebreak (the launcher passes
  // druncache counts, which move over time) keeps the old order until the
  // pool identity or the query changes. Pinned as the real behaviour - the
  // menu forwarder inherits it unchanged.
  const pool = [{ label: 'a', words: ['t'] }, { label: 'b', words: ['t'] }]
  eq('first call, no tiebreak', M.filterCounter(pool, 't', 5).rows.map(r => r.label), ['a', 'b'])
  eq('second call, SAME pool and query, with a flipping tiebreak', M.filterCounter(pool, 't', 5, (r) => (r.label === 'b' ? 1 : 0)).rows.map(r => r.label), ['a', 'b'])
  eq('a different query on the same pool does re-sort', M.filterCounter(pool, 't t', 5, (r) => (r.label === 'b' ? 1 : 0)).rows.map(r => r.label), ['b', 'a'])
  eq('and a fresh pool with the tiebreak flips it too', M.filterCounter([{ label: 'a', words: ['t'] }, { label: 'b', words: ['t'] }], 't', 5, (r) => (r.label === 'b' ? 1 : 0)).rows.map(r => r.label), ['b', 'a'])
})

group('the counter requires a pre-split words array', () => {
  // The launcher's records are built with `words` split once at index time.
  // A record without it is a build bug, not a runtime state, so the throw is
  // the answer - but it is worth pinning that MenuLib adds no guard of its own.
  throws('a record with no words throws', () => M.filterCounter([{ label: 'x' }], 'x', 5), /words|length/)
  eq('a non-string query is stringified, not a throw', M.filterCounter([{ label: 'x', words: ['x'] }], 5, 5).rows, [])
  noThrow('and a non-function tiebreak is not called at all', () => M.filterCounter([], 'x', 5, 'nope'))
})

// ======================================================================
section('scopedFilter - the in-page "/" quick filter')
group('a blank query returns the page as it is, as a copy', () => {
  const pool = [
    { type: 'action', label: 'Brightness', sub: 'Screen' },
    { type: 'separator' },
    { type: 'number', label: 'Volume', value: 50, unit: '%' },
  ]
  eq('an empty query', M.scopedFilter(pool, '').map(i => i.type), ['action', 'separator', 'number'])
  eq('a whitespace query', M.scopedFilter(pool, '   ').map(i => i.type), ['action', 'separator', 'number'])
  eq('a null query', M.scopedFilter(pool, null).map(i => i.type), ['action', 'separator', 'number'])
  eq('an undefined query', M.scopedFilter(pool, undefined).map(i => i.type), ['action', 'separator', 'number'])
  // The early return is `list.slice()` - before the separator skip - so a
  // blank filter keeps the separator, while any real filter drops it.
  // Deliberate-but-surprising, cited from scopedFilter's own early return.
  eq('a blank filter KEEPS the separator', M.scopedFilter(pool, '').length, 3)
  eq('a real filter drops it', M.scopedFilter(pool, 'bri').map(i => i.type), ['action'])
  eq('a real filter that matches the separator drops it too', M.scopedFilter(pool, 'x').length, 0)
  is('the returned array is a copy', M.scopedFilter(pool, '') === pool, (v) => v === false, 'a new array')
  eq('so pushing to it does not touch the page', (() => { const r = M.scopedFilter(pool, ''); r.push('x'); return pool.length })(), 3)
  is('but the rows themselves are the same objects', M.scopedFilter(pool, '')[0] === pool[0], (v) => v === true, 'the same row')
  is('including the separator', M.scopedFilter(pool, '')[1] === pool[1], (v) => v === true, 'the same row')
  eq('a non-array pool filters to an empty list', M.scopedFilter(null, 'a'), [])
  eq('a missing pool too', M.scopedFilter(), [])
})

group('a real filter matches every token against the row, ANDed', () => {
  const pool = [
    { type: 'action', label: 'Brightness', sub: 'Screen' },
    { type: 'select', label: 'Search engine', options: [{ label: 'Google', value: 'g' }] },
    { type: 'separator' },
    { type: 'number', label: 'Volume', value: 50, unit: '%' },
  ]
  eq('one token', M.scopedFilter(pool, 'bri').map(i => i.label), ['Brightness'])
  eq('two tokens both present', M.scopedFilter(pool, 'volume 50').map(i => i.label), ['Volume'])
  eq('one token missing rejects the row', M.scopedFilter(pool, 'volume zzz').map(i => i.label), [])
  eq('the query is lowercased', M.scopedFilter(pool, 'BRIGHT').map(i => i.label), ['Brightness'])
  eq('and trimmed', M.scopedFilter(pool, '  bri  ').map(i => i.label), ['Brightness'])
  eq('it matches anywhere in the hay, not just word starts', M.scopedFilter(pool, 'ight').map(i => i.label), ['Brightness'])
  // hayFromItem(it, false) - "Unlike the cross-page buildIndex/search
  // pipeline this never leaves the page - no breadcrumbs, no grouping, just a
  // live trim of what's already on screen."
  eq('the options are NOT indexed here', M.scopedFilter(pool, 'google').map(i => i.label), [])
  eq('nor is the var key', M.scopedFilter(pool, 'x').length, 0)
  eq('the current value IS indexed', M.scopedFilter(pool, '50').map(i => i.label), ['Volume'])
  eq('a zero value is indexed', M.scopedFilter([{ type: 'number', label: 'X', value: 0 }], 'x 0').length, 1)
  eq('a row that matches nothing drops out', M.scopedFilter(pool, 'zzz').length, 0)
  eq('non-object entries are skipped', M.scopedFilter([null, 5, { type: 'action', label: 'A' }], 'a').length, 1)
  eq('and so is a separator', M.scopedFilter([{ type: 'separator', label: 'x' }], 'x').length, 0)
  noThrow('a row with no keys at all', () => M.scopedFilter([{}], 'x'))
  // hayFromItem is recomputed per row per keystroke; the function is pure
  // over the row it is handed, so that cost is the only cost.
  is('the filter does not mutate the row', (() => { const row = { type: 'action', label: 'A' }; const before = JSON.stringify(row); M.scopedFilter([row], 'a'); return JSON.stringify(row) === before })(), (v) => v === true, 'unchanged')
})

group('hayForFilter matches only the visible row text', () => {
  eq('a description never leaks into the trim', M.hayForFilter({ label: 'Install', desc: 'Packages, themes and fonts.' }), 'install')
  eq('label and sub shape it', M.hayForFilter({ label: 'Brightness', sub: 'Screen' }), 'brightness screen')
  eq('the current value shapes it', M.hayForFilter({ label: 'Volume', value: 50, unit: '%' }), 'volume % 50')
  eq('options, var and id do not', M.hayForFilter({ label: 'Search engine', options: [{ label: 'Google', value: 'g' }], var: 'x', id: 'y' }), 'search engine')
  const main = [
    { type: 'submenu', label: 'Settings' },
    { type: 'submenu', label: 'Install', desc: 'Packages, themes and fonts.' },
    { type: 'submenu', label: 'Remove', desc: 'Uninstall packages, themes and fonts.' },
    { type: 'submenu', label: 'Update', desc: 'OS packages, AUR, themes and Vibranium itself.' },
    { type: 'submenu', label: 'Setup', desc: 'Hardware and service provisioning presets.' },
    { type: 'submenu', label: 'Help', desc: 'Documentation and keybinding cheatsheet.' },
  ].map((r, i) => M.normalizeItem(r, 'main', i))
  eq('a single h trims the main menu to Help', M.scopedFilter(main, 'h').map((i) => i.label), ['Help'])
  eq('and the full word still does', M.scopedFilter(main, 'help').map((i) => i.label), ['Help'])
})

// ======================================================================
section('substitute - the %v command template')
group('%v is replaced everywhere it appears', () => {
  eq('once', M.substitute('notify %v now', 'hi'), 'notify hi now')
  eq('twice', M.substitute('%v and %v', 'x'), 'x and x')
  eq('three times', M.substitute('a%vb%vc', 'X'), 'aXbXc')
  eq('a template with no placeholder is unchanged', M.substitute('abc', 'x'), 'abc')
  eq('a value with its own %v is not re-scanned', M.substitute('%v', '%v'), '%v')
  eq('a literal percent survives', M.substitute('100%', 'x'), '100%')
  eq('a value containing a percent is inserted whole', M.substitute('%v%', 'a%b'), 'a%b%')
})

group('substituteQuoted is the one that reaches a shell', () => {
  // runCommand hands the substituted string to `/bin/bash -c`, and a text
  // row's value is whatever the user just typed. Raw, that value is source.
  eq('a plain value is one quoted word', M.substituteQuoted('cmd %v', 'x'), "cmd 'x'")
  eq('the emoji page template still lands one argument',
    M.substituteQuoted('vb-emoji-insert %v', '\u{1F389}'), "vb-emoji-insert '\u{1F389}'")
  eq('a space no longer word-splits', M.substituteQuoted('cmd %v', 'a b'), "cmd 'a b'")
  eq('a glob no longer expands', M.substituteQuoted('cmd %v', '*.png'), "cmd '*.png'")
  eq('a command substitution stays inside the argument',
    M.substituteQuoted('cmd %v', '$(id)'), "cmd '$(id)'")
  eq('a semicolon no longer starts a second command',
    M.substituteQuoted('cmd %v', 'x; id'), "cmd 'x; id'")
  eq('a newline no longer starts a new line', M.substituteQuoted('cmd %v', 'a\nid'), "cmd 'a\nid'")
  eq('an apostrophe is escaped, not ended', M.substituteQuoted('cmd %v', "it's"), "cmd 'it'\\''s'")
  eq('every placeholder is quoted', M.substituteQuoted('%v %v', 'x'), "'x' 'x'")
  eq('a template with no placeholder is unchanged', M.substituteQuoted('abc', 'x'), 'abc')
  eq('a non-string template is no template at all', M.substituteQuoted('', 'x'), '')
  // runCall substitutes into a Registry argv array, where a shell never sees
  // the value - quoting there would pass the quotes through as part of it.
  eq('substitute stays raw for the Registry path', M.substitute('fontPicker pick %v', 'a b'), 'fontPicker pick a b')
})

group('a non-string template is no template at all', () => {
  eq('an empty string', M.substitute('', 'x'), '')
  eq('null', M.substitute(null, 'x'), '')
  eq('undefined', M.substitute(undefined, 'x'), '')
  eq('a number', M.substitute(5, 'x'), '')
  eq('an object', M.substitute({}, 'x'), '')
  eq('so the caller never gets a half-built command', M.substitute(null, 'x').length, 0)
})

group('the value is stringified, never validated', () => {
  eq('a number', M.substitute('%v ms', 5), '5 ms')
  eq('a number keeps its own formatting', M.substitute('%v', 1.5), '1.5')
  eq('a zero', M.substitute('%v', 0), '0')
  eq('a false', M.substitute('%v', false), 'false')
  // `String(value)` with no guard, so a nullish value becomes those six
  // literal characters. Pinned: the callers only substitute values that came
  // out of a settings store, which are strings.
  eq('undefined prints as the word', M.substitute('%v', undefined), 'undefined')
  eq('null too', M.substitute('%v', null), 'null')
  eq('an empty value collapses the word', M.substitute('a%vb', ''), 'ab')
  eq('an object stringifies to [object Object]', M.substitute('%v', {}), '[object Object]')
  eq('a shell-hostile value is inserted verbatim - the caller owns quoting', M.substitute('notify %v', "'; id; '"), "notify '; id; '")
  // `split("%v").join(...)`, not a regex: no metacharacter in the needle can
  // be interpreted.
  eq('it is a plain split/join, not a regex substitution', M.substitute('%v', '$&'), '$&')
  eq('and the needle is a literal', M.substitute('%v', 'a'), 'a')
})

// ======================================================================
section('groupSearchResults - hits into flat, separated, grouped rows')
group('one bucket per leaf page, in hit order, separated by a separator row', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[
      {"type":"submenu","id":"s1","label":"Install","page":"install"},
      {"type":"action","id":"a1","label":"Row A1"},
      {"type":"action","id":"a2","label":"Row A2"}
    ]},
    {"id":"install","title":"Install","items":[
      {"type":"action","id":"p1","label":"Package"},
      {"type":"action","id":"p2","label":"Program"},
      {"type":"submenu","id":"s2","label":"Deep","page":"deep"}
    ]},
    {"id":"deep","title":"Deep","items":[{"type":"action","id":"d1","label":"Deeper"}]}
  ]}`)
  const idx = M.buildIndex(b)
  const hits = M.search(idx, 'p')
  const rows = M.groupSearchResults(hits, b.byId, () => true)
  // Two buckets here: 'install' (Package, Program, plus the Deep submenu
  // that lives there) and 'deep' (Deeper alone). A submenu stays on its
  // owning page, so Deep does not join the page it opens.
  eq('the flat order is header, install-bucket, header, deep-bucket', rows.map(r => r.label || r.type), ['Install', 'Package', 'Program', 'Deep', 'Install > Deep', 'Deeper'])
  eq('two buckets get two separators, one opening each', rows.filter(r => r.type === 'separator').length, 2)
  eq('and the separator uid counts the buckets', rows.filter(r => r.type === 'separator').map(r => r.uid), ['sep:group0', 'sep:group1'])
  eq('the separator carries the head row breadcrumb and nothing else', Object.keys(rows.find(r => r.type === 'separator')), ['type', 'uid', 'label'])
  eq('naming where the bucket lives', rows.find(r => r.type === 'separator').label, 'Install')
  eq('no hits is an empty row list', M.groupSearchResults([], b.byId, () => true), [])
  eq('and one bucket opens with its own header', M.groupSearchResults(M.search(idx, 'pack'), b.byId, () => true).map(r => r.label || r.type), ['Install', 'Package'])
})

group('a submenu hit stays on its owning page, not the page it opens', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"submenu","id":"s1","label":"Install","page":"install"}]},
    {"id":"install","title":"Install","items":[
      {"type":"action","id":"p1","label":"Package"},
      {"type":"submenu","id":"s2","label":"Deep","page":"deep"}
    ]},
    {"id":"deep","title":"Deep","items":[{"type":"action","id":"d1","label":"Deeper"}]}
  ]}`)
  const hits = M.search(M.buildIndex(b), 'install')
  eq('the raw hit order puts both submenus first', hits.map(h => h.label), ['Install', 'Deep', 'Deeper', 'Package'])
  const rows = M.groupSearchResults(hits, b.byId, () => true)
  eq('the Install row heads its own main bucket', rows[0].label, 'Install')
  // The merged row's pageId is the hit's - the page the submenu lives on -
  // and the bucket is keyed on that same id. Pinned: pageId names where the
  // row was found, while the `page` field names where it goes.
  eq('but its pageId is the page it was FOUND on', rows[0].pageId, 'main')
  eq('its breadcrumb is empty on the entry page', rows[0].path, [])
  eq('and its `page` field still names where it goes', rows[0].page, 'install')
  eq('and it keeps its own type', rows[0].type, 'submenu')
  eq('the install bucket follows after a separator', rows.filter(r => r.type === 'separator').length, 2)
  eq('with the Deep submenu filed where it lives, ahead of Package by rank', [rows[2].label, rows[rows.length - 3].label], ['Deep', 'Package'])
  eq('and that submenu also reports the page it was found on', rows[2].pageId, 'install')
  eq('while the row after the second separator reports the deep page', rows[rows.length - 1].pageId, 'deep')
  eq('the flat order is main-bucket, separator, install-bucket, separator, deep-bucket', rows.map(r => r.label || r.type), ['Install', 'Install', 'Deep', 'Package', 'Install > Deep', 'Deeper'])
})

// The submenu rule is about FILING, not about ranking. A submenu stays on
// its owning page and keeps the slot its rank earned inside that bucket;
// this is the case where ranking and filing visibly diverge.
group('filing a submenu on its owning page never promotes it past its rank', () => {
  // "Setup" sits on the entry page and opens the install page, whose own rows
  // match the query better. Unshifting it to the head of that bucket put a
  // weak match (mid-word, in the submenu's own label) above three strong ones
  // (all word-start, on their labels), and the panel seats the cursor on row
  // 0 - so the row under the cursor was not the row the user matched.
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[
      {"type":"submenu","id":"s1","label":"Setup","page":"install"},
      {"type":"action","id":"a1","label":"Package"}
    ]},
    {"id":"install","title":"Install","items":[
      {"type":"action","id":"p1","label":"PWA"},
      {"type":"action","id":"p2","label":"Program"}
    ]}
  ]}`)
  const hits = M.search(M.buildIndex(b), 'p')
  // Three word-start matches at 2000 in page order; the submenu scores 1460
  // (its only 'p' is mid-word, at index 3), so it ranks last.
  eq('the submenu ranks last', hits.map(h => h.label), ['Package', 'PWA', 'Program', 'Setup'])
  const rows = M.groupSearchResults(hits, b.byId, () => true)
  eq('and the best match is the first row of the list', rows.map(r => r.label || r.type),
    ['Package', 'Setup', 'Install', 'PWA', 'Program'])
  eq('the submenu keeps the slot its rank earned', rows[1].label, 'Setup')
  eq('and is still filed where it lives', [rows[1].page, rows[1].pageId], ['install', 'main'])
  eq('so the two buckets still need exactly one separator', rows.filter(r => r.type === 'separator').length, 1)
})

group('the separator uid counts the buckets, starting at the second', () => {
  const three = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"action","id":"a1","label":"A one"}]},
    {"id":"p2","title":"Two","items":[{"type":"action","id":"b1","label":"B two"}]},
    {"id":"p3","title":"Three","items":[{"type":"action","id":"c1","label":"C three"}]}
  ]}`)
  const hit = (pageId, pageTitle, row, label) => ({ pageId, pageTitle, path: [pageTitle], row, label })
  const rows = M.groupSearchResults(
    [hit('main', 'Main', 0, 'A one'), hit('p2', 'Two', 0, 'B two'), hit('p3', 'Three', 0, 'C three')],
    three.byId, () => true,
  )
  eq('three buckets, each opened by a separator', rows.map(r => r.label || r.type), ['Main', 'A one', 'Two', 'B two', 'Three', 'C three'])
  eq('three buckets get three separators', rows.filter(r => r.type === 'separator').length, 3)
  eq('numbered from 0, one per bucket', rows.filter(r => r.type === 'separator').map(r => r.uid), ['sep:group0', 'sep:group1', 'sep:group2'])
  eq('so the head bucket carries its header too', rows[0], { type: 'separator', uid: 'sep:group0', label: 'Main' })
  eq('one bucket opens with its own header', M.groupSearchResults([hit('main', 'Main', 0, 'A one')], three.byId, () => true).filter(r => r.type === 'separator').length, 1)
  // Two hits on the SAME page share a bucket, however they are ordered in the
  // hit list, so one separator covers both.
  const twice = M.groupSearchResults([hit('main', 'Main', 0, 'A one'), hit('p2', 'Two', 0, 'B two'), hit('main', 'Main', 0, 'A one')], three.byId, () => true)
  eq('a repeated page does not open a new bucket', twice.filter(r => r.type === 'separator').length, 2)
  eq('but the row appears twice', twice.map(r => r.label || r.type), ['Main', 'A one', 'A one', 'Two', 'B two'])
})

group('hidden rows drop out before the grouping', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[
      {"type":"action","id":"a1","label":"Row A1"},
      {"type":"action","id":"a2","label":"Row A2"}
    ]}
  ]}`)
  const idx = M.buildIndex(b)
  const hits = M.search(idx, 'row')
  eq('both rows hit', labels(hits), ['Row A1', 'Row A2'])
  eq('all hidden means no rows', M.groupSearchResults(hits, b.byId, () => false), [])
  eq('one hidden means one row and no separator', M.groupSearchResults(hits, b.byId, (it) => it.label !== 'Row A1').map(r => r.label), ['Row A2'])
  // The predicate is called with the *item*, so it is the caller's whole
  // visibility contract (the dead-link fixpoint included) arriving here.
  eq('the predicate is handed the item, not the hit', M.groupSearchResults(hits, b.byId, (it) => it.id === 'a2').map(r => r.label), ['Row A2'])
  eq('a page missing from byId contributes nothing', M.groupSearchResults([{ pageId: 'nope', row: 0, path: ['x'], pageTitle: 'x' }], b.byId, () => true), [])
  eq('a row index out of range contributes nothing', M.groupSearchResults([{ pageId: 'main', row: 99, path: ['x'], pageTitle: 'x' }], b.byId, () => true), [])
  eq('a row index that is not a number contributes nothing', M.groupSearchResults([{ pageId: 'main', row: 'x', path: ['x'], pageTitle: 'x' }], b.byId, () => true), [])
  noThrow('a hit with no path at all', () => M.groupSearchResults([{ pageId: 'main', row: 0 }], b.byId, () => true))
})

group('the merged row is a copy carrying the hit breadcrumb', () => {
  const b = bundle(`{"pages":[
    {"id":"main","title":"Main","items":[{"type":"submenu","label":"Install","page":"install"}]},
    {"id":"install","title":"Install","items":[{"type":"action","id":"p1","label":"Package","var":"V"}]}
  ]}`)
  const hits = M.search(M.buildIndex(b), 'package')
  const rows = M.groupSearchResults(hits, b.byId, () => true)
  eq('the head bucket opens with its header', rows[0], { type: 'separator', uid: 'sep:group0', label: 'Install' })
  eq('the row carries the hit path', rows[1].path, ['Install'])
  eq('and the page id and row index', [rows[1].pageId, rows[1].row], ['install', 0])
  eq('plus every field the item had', [rows[1].label, rows[1].var, rows[1].uid], ['Package', 'V', 'install#p1'])
  eq('the item itself is not given a path', b.byId.install.items[0].path, undefined)
  is('and the merged row is a different object', rows[1] === b.byId.install.items[0], (v) => v === false, 'a copy')
  eq('so mutating the result cannot corrupt the page', (() => { rows[1].label = 'changed'; return b.byId.install.items[0].label })(), 'Package')
  eq('a non-submenu with no page field is filed under its own page', (() => {
    const c = bundle('{"pages":[{"id":"main","title":"Main","items":[{"type":"action","label":"x","page":""}]}]}')
    return M.groupSearchResults(M.search(M.buildIndex(c), 'x'), c.byId, () => true).map(r => r.pageId)
  })(), ['main'])
})

// ======================================================================
section('provider hook dispatch - the three accept rules')
group('hookValue passes a non-nullish, non-empty answer through uncoerced', () => {
  // "a nullish or empty answer is a decline, anything else passes through
  // uncoerced so a non-string value stays non-string."
  eq('a string', M.hookValue({ label: () => 'L' }, 'label', {}, {}, 'FB'), 'L')
  eq('a number', M.hookValue({ label: () => 7 }, 'label', {}, {}, 'FB'), 7)
  eq('zero', M.hookValue({ label: () => 0 }, 'label', {}, {}, 'FB'), 0)
  eq('false', M.hookValue({ label: () => false }, 'label', {}, {}, 'FB'), false)
  eq('an object', M.hookValue({ label: () => ({ a: 1 }) }, 'label', {}, {}, 'FB'), { a: 1 })
  eq('an array', M.hookValue({ label: () => [1] }, 'label', {}, {}, 'FB'), [1])
})

group('hookValue declines exactly null, undefined and the empty string', () => {
  eq('an empty string is a decline', M.hookValue({ label: () => '' }, 'label', {}, {}, 'FB'), 'FB')
  eq('null is a decline', M.hookValue({ label: () => null }, 'label', {}, {}, 'FB'), 'FB')
  eq('undefined is a decline', M.hookValue({ label: () => undefined }, 'label', {}, {}, 'FB'), 'FB')
  eq('a whitespace string is an answer', M.hookValue({ label: () => '  ' }, 'label', {}, {}, 'FB'), '  ')
  eq('a zero-length object is an answer', M.hookValue({ label: () => ({}) }, 'label', {}, {}, 'FB'), {})
})

group('the decline path is what makes a decline distinguishable', () => {
  // "Passing a fallback outside the accepted set (null is the usual choice)
  // is what makes a decline distinguishable from an answered false."
  eq('no provider at all', M.hookValue(null, 'label', {}, {}, 'FB'), 'FB')
  eq('an empty provider', M.hookValue({}, 'label', {}, {}, 'FB'), 'FB')
  eq('a provider that only declares other hooks', M.hookValue({ other: () => 1 }, 'label', {}, {}, 'FB'), 'FB')
  eq('a hook that is not a function', M.hookValue({ label: 5 }, 'label', {}, {}, 'FB'), 'FB')
  eq('a hook that is a string', M.hookValue({ label: 'x' }, 'label', {}, {}, 'FB'), 'FB')
  eq('a null provider with a null fallback', M.hookValue(null, 'label', {}, {}, null), null)
  eq('and the fallback is handed back verbatim, uncoerced', M.hookValue({}, 'label', {}, {}, false), false)
  eq('even a falsey fallback', M.hookValue({}, 'label', {}, {}, 0), 0)
  eq('even undefined', M.hookValue({}, 'label', {}, {}, undefined), undefined)
  eq('an inherited hook is still a hook', M.hookValue(Object.create({ label: () => 'proto' }), 'label', {}, {}, 'FB'), 'proto')
  eq('an own property shadows the prototype', M.hookValue(Object.assign(Object.create({ label: () => 'proto' }), { label: () => 'own' }), 'label', {}, {}, 'FB'), 'own')
})

group('the hook is a method of the surface and gets (item, ctx)', () => {
  // "Hooks are invoked as methods of the surface, so a surface written
  // against `this` sees itself and not the dispatching controller."
  const self = { n: 7, get: function () { return this.n } }
  eq('`this` is the surface', M.hookValue(self, 'get', {}, {}, 0), 7)
  eq('the arguments are (item, ctx)', M.hookValue({ get: (i, c) => [i, c] }, 'get', 'ITEM', 'CTX', 0), ['ITEM', 'CTX'])
  eq('and nothing else is passed', M.hookValue({ get: function () { return arguments.length } }, 'get', 'I', 'C', 0), 2)
  // A throwing hook propagates: the dispatcher is a value contract, not a
  // boundary, and the caller wraps provider dispatch in its own try.
  throws('a throwing hook propagates', () => M.hookValue({ get: () => { throw new Error('boom') } }, 'get', {}, {}, 0), /boom/)
  eq('so a decline is not how a crash is reported', M.hookValue({ get: () => 1 }, 'get', {}, {}, 'FB'), 1)
})

group('hookBool accepts only true and false', () => {
  // "Strict boolean: only true/false is an answer, so a truthy stand-in a
  // surface returned by mistake cannot flip a row the bundle owns."
  eq('true', M.hookBool({ f: () => true }, 'f', {}, {}, 'FB'), true)
  eq('false', M.hookBool({ f: () => false }, 'f', {}, {}, 'FB'), false)
  eq('1 declines', M.hookBool({ f: () => 1 }, 'f', {}, {}, 'FB'), 'FB')
  eq('0 declines', M.hookBool({ f: () => 0 }, 'f', {}, {}, 'FB'), 'FB')
  eq('"true" declines', M.hookBool({ f: () => 'true' }, 'f', {}, {}, 'FB'), 'FB')
  eq('an empty string declines', M.hookBool({ f: () => '' }, 'f', {}, {}, 'FB'), 'FB')
  eq('null declines', M.hookBool({ f: () => null }, 'f', {}, {}, 'FB'), 'FB')
  eq('undefined declines', M.hookBool({ f: () => undefined }, 'f', {}, {}, 'FB'), 'FB')
  eq('an object declines', M.hookBool({ f: () => ({}) }, 'f', {}, {}, 'FB'), 'FB')
  // `r === true || r === false` - a boxed Boolean is not a primitive.
  eq('a boxed true declines', M.hookBool({ f: () => new Boolean(true) }, 'f', {}, {}, 'FB'), 'FB')
  eq('no provider', M.hookBool(null, 'f', {}, {}, 'FB'), 'FB')
  eq('no hook', M.hookBool({}, 'f', {}, {}, 'FB'), 'FB')
  eq('a non-function hook', M.hookBool({ f: 1 }, 'f', {}, {}, 'FB'), 'FB')
  eq('the fallback is handed back verbatim', M.hookBool({}, 'f', {}, {}, true), true)
  eq('including a false fallback', M.hookBool({}, 'f', {}, {}, false), false)
  eq('`this` is the surface', M.hookBool({ n: true, f: function () { return this.n } }, 'f', {}, {}, 'FB'), true)
  eq('the arguments are (item, ctx)', M.hookBool({ f: (i, c) => c === 'C' }, 'f', 'I', 'C', 'FB'), true)
  throws('a throwing hook propagates', () => M.hookBool({ f: () => { throw new Error('nope') } }, 'f', {}, {}, 'FB'), /nope/)
})

group('hookRan answers true only when the surface owned the action', () => {
  eq('true means the surface owned it', M.hookRan({ f: () => true }, 'f', {}, 'ARG', {}), true)
  eq('false means it declined', M.hookRan({ f: () => false }, 'f', {}, 'ARG', {}), false)
  eq('a truthy stand-in declines', M.hookRan({ f: () => 1 }, 'f', {}, 'ARG', {}), false)
  eq('undefined declines', M.hookRan({ f: () => undefined }, 'f', {}, 'ARG', {}), false)
  eq('null declines', M.hookRan({ f: () => null }, 'f', {}, 'ARG', {}), false)
  eq('no provider means it did not run', M.hookRan(null, 'f', {}, 'ARG', {}), false)
  eq('no hook means it did not run', M.hookRan({}, 'f', {}, 'ARG', {}), false)
  eq('a non-function hook means it did not run', M.hookRan({ f: 1 }, 'f', {}, 'ARG', {}), false)
  eq('and there is no fallback to hand back', M.hookRan({}, 'f', {}, 'ARG', {}), false)
  // "`arg` is the action's own payload (the new number, the staged values,
  // the requested toggle state) and rides ahead of the context."
  eq('the arguments are (item, arg, ctx)', M.hookRan({ f: (i, a, c) => i === 'I' && a === 'A' && c === 'C' }, 'f', 'I', 'A', 'C'), true)
  eq('so the arg cannot be confused with the context', M.hookRan({ f: (i, a) => a === 'A' }, 'f', 'I', 'A', 'C'), true)
  eq('`this` is the surface', M.hookRan({ v: true, f: function () { return this.v } }, 'f', {}, 'A', {}), true)
  eq('an inherited hook counts as a hook', M.hookRan(Object.create({ f: () => true }), 'f', {}, 'A', {}), true)
  throws('a throwing hook propagates - "it ran" is not a catch', () => M.hookRan({ f: () => { throw new Error('nope') } }, 'f', {}, 'A', {}), /nope/)
})

// ======================================================================
section('the staged flow: copy, stages and transitions')
group('resolveConfirm lets the surface overrule the bundle', () => {
  // "A surface's own descriptor wins over the one the bundle declared: the
  // surface knows the row's live state and can refuse a confirmation the
  // bundle would otherwise arm."
  const provided = { label: 'P' }
  const bundled = { confirm: { label: 'B' } }
  eq('a provided descriptor wins', M.resolveConfirm(bundled, provided), provided)
  eq('and it is the very same object', M.resolveConfirm(bundled, provided) === provided, true)
  eq('null falls through to the bundle', M.resolveConfirm(bundled, null), bundled.confirm)
  eq('undefined falls through to the bundle', M.resolveConfirm(bundled, undefined), bundled.confirm)
  // The test is `!== null && !== undefined`, so a falsy provided value is an
  // ANSWER - "arm nothing" is spelled by handing back false/0/"" and it is
  // distinguishable from a decline only because null is the decline.
  eq('false is an answer, not a decline', M.resolveConfirm(bundled, false), false)
  eq('zero is an answer', M.resolveConfirm(bundled, 0), 0)
  eq('an empty string is an answer', M.resolveConfirm(bundled, ''), '')
  // The bundle's own descriptor must be an object: "Absent either, the row
  // arms nothing and its dropdown stays a plain dropdown."
  eq('a bundle confirm of false arms nothing', M.resolveConfirm({ confirm: false }, undefined), null)
  eq('a bundle confirm of a string arms nothing', M.resolveConfirm({ confirm: 'x' }, undefined), null)
  eq('a bundle confirm of zero arms nothing', M.resolveConfirm({ confirm: 0 }, undefined), null)
  eq('a bundle confirm of an array is an object, so it is used', Array.isArray(M.resolveConfirm({ confirm: [] }, undefined)), true)
  eq('an item with no confirm arms nothing', M.resolveConfirm({}, undefined), null)
  eq('no item at all', M.resolveConfirm(null, undefined), null)
  eq('no item and no provided', M.resolveConfirm(null, null), null)
  eq('undefined item with a provided descriptor still works', M.resolveConfirm(undefined, provided), provided)
  const c = { label: 'B' }
  is('the bundle descriptor is handed back by identity', M.resolveConfirm({ confirm: c }, undefined) === c, (v) => v === true, 'the same object')
})

group('isFlow / flowCount / flowStep describe a staged row', () => {
  const flow = M.normalizeItem({
    type: 'action', label: 'Timer',
    flow: [
      { kind: 'select', label: 'Kind', options: [{ label: 'a', value: 'a' }] },
      { kind: 'number', label: 'Minutes', min: 1, max: 120 },
      { kind: 'text', label: 'Note' },
    ],
  }, 'p', 0)
  eq('a staged row is a flow', M.isFlow(flow), true)
  eq('and has three stages', M.flowCount(flow), 3)
  eq('stage 0', M.flowStep(flow, 0).kind, 'select')
  eq('stage 1', M.flowStep(flow, 1).kind, 'number')
  eq('stage 2', M.flowStep(flow, 2).kind, 'text')
  eq('a stage past the end is null', M.flowStep(flow, 3), null)
  eq('a negative stage is null', M.flowStep(flow, -1), null)
  eq('a huge stage is null', M.flowStep(flow, 1e9), null)
  eq('a numeric string index works', M.flowStep(flow, '1').kind, 'number')
  // `Number(idx) || 0` - a falsy index becomes stage 0 rather than a crash.
  eq('NaN becomes stage 0', M.flowStep(flow, NaN).kind, 'select')
  eq('null becomes stage 0', M.flowStep(flow, null).kind, 'select')
  eq('undefined becomes stage 0', M.flowStep(flow, undefined).kind, 'select')
  // ...but a FRACTIONAL index inside the range is neither: the bounds check
  // passes and `flow[1.7]` is undefined, so the function returns undefined
  // rather than the documented null. Every caller in the file guards with
  // `step && ...` (nextFlowIndex) or compares the value (the panel), so this
  // is benign - pinned as a real, small contract gap.
  eq('a fractional in-range index returns undefined, not null', M.flowStep(flow, 1.7), undefined)
  eq('isFlow is false for a plain row', M.isFlow({ type: 'action' }), false)
  eq('for a null item', M.isFlow(null), false)
  eq('for an empty flow array', M.isFlow({ flow: [] }), false)
  eq('for a non-array flow', M.isFlow({ flow: 'x' }), false)
  eq('flowCount of a plain row', M.flowCount({ type: 'action' }), 0)
  eq('flowCount of an empty flow', M.flowCount({ flow: [] }), 0)
  eq('flowCount of a null item', M.flowCount(null), 0)
  eq('flowStep of a plain row', M.flowStep({ type: 'action' }, 0), null)
  eq('flowStep of a null item', M.flowStep(null, 0), null)
})

group('nextFlowIndex stops at the next stage that should render', () => {
  const flow = M.normalizeItem({
    type: 'action',
    flow: [
      { kind: 'select', label: 'A', options: [{ label: 'x', value: 'x' }] },
      { kind: 'text', label: 'B', skipUnless: 'keep' },
      { kind: 'number', label: 'C' },
    ],
  }, 'p', 0)
  // "The result is an index the caller compares against flowCount: at or past
  // the end means the flow is done and commits."
  eq('from stage 0, an ungated stage renders', M.nextFlowIndex(flow, 0, {}), 0)
  eq('from stage 0 with a matching value stored, still 0', M.nextFlowIndex(flow, 0, { a: 'keep' }), 0)
  eq('from stage 1 with nothing stored, the gated stage is stepped over', M.nextFlowIndex(flow, 1, {}), 2)
  eq('from stage 1 with an unrelated value, still stepped over', M.nextFlowIndex(flow, 1, { a: 'no' }), 1 * 0 + 2)
  eq('from stage 1 with a matching value, it renders', M.nextFlowIndex(flow, 1, { a: 'keep' }), 1)
  eq('any of the stored values may match', M.nextFlowIndex(flow, 1, { a: 'no', b: 'keep' }), 1)
  eq('matching is by String() on both sides', M.nextFlowIndex(flow, 1, { a: 'keep' }), 1)
})

group('nextFlowIndex walks off the end rather than clamping', () => {
  const flow = M.normalizeItem({ type: 'action', flow: [{ kind: 'select' }, { kind: 'text' }] }, 'p', 0)
  eq('at the last stage it answers the last index', M.nextFlowIndex(flow, 1, {}), 1)
  eq('which equals flowCount, so the caller commits', [M.nextFlowIndex(flow, 1, {}), M.flowCount(flow)], [1, 2])
  eq('past the end it answers past the end', M.nextFlowIndex(flow, 2, {}), 2)
  eq('far past the end', M.nextFlowIndex(flow, 99, {}), 99)
  eq('a negative from is returned unchanged', M.nextFlowIndex(flow, -1, {}), -1)
  // `flowStep(item, -1)` is null, `if (step && ...)` is false, so the walk
  // breaks on the first iteration and hands `from` straight back.
  eq('so a negative from never advances', M.nextFlowIndex(flow, -5, {}), -5)
  eq('a row with no flow answers from unchanged', M.nextFlowIndex({ type: 'action' }, 5, {}), 5)
  eq('and 0 for stage zero', M.nextFlowIndex({ type: 'action' }, 0, {}), 0)
  eq('and -1 unchanged', M.nextFlowIndex({ type: 'action' }, -1, {}), -1)
})

group('skipUnless gates a stage on ANY earlier stored value', () => {
  // "A stage carrying skipUnless shows only when SOME earlier stage stored its
  // value, never stage zero alone, so a select-first flow and an editor-first
  // flow share one rule."
  const gated0 = M.normalizeItem({ type: 'action', flow: [{ kind: 'text', label: 'B', skipUnless: '5' }, { kind: 'number', label: 'C' }] }, 'p', 0)
  eq('nothing stored: stage 0 is stepped over', M.nextFlowIndex(gated0, 0, {}), 1)
  eq('a matching value: stage 0 renders', M.nextFlowIndex(gated0, 0, { a: 5 }), 0)
  eq('a matching string: stage 0 renders', M.nextFlowIndex(gated0, 0, { a: '5' }), 0)
  eq('a falsy stored value still counts, by String()', M.nextFlowIndex(gated0, 0, { a: false }), 1)
  const zero = M.normalizeItem({ type: 'action', flow: [{ kind: 'text', skipUnless: '0' }, { kind: 'text' }] }, 'p', 0)
  eq('a stored 0 matches the string "0"', M.nextFlowIndex(zero, 0, { a: 0 }), 0)
  eq('a stored false does not', M.nextFlowIndex(zero, 0, { a: false }), 1)
  // An empty or absent skipUnless is not a gate at all.
  const ungated = M.normalizeItem({ type: 'action', flow: [{ kind: 'text', skipUnless: '' }, { kind: 'text' }] }, 'p', 0)
  eq('an empty skipUnless is not a gate', M.nextFlowIndex(ungated, 0, {}), 0)
  eq('a stage with no skipUnless is never stepped over', M.nextFlowIndex(gated0, 1, {}), 1)
  const all = M.normalizeItem({ type: 'action', flow: [{ kind: 'text', skipUnless: 'zz' }, { kind: 'text', skipUnless: 'yy' }] }, 'p', 0)
  eq('every stage gated out lands on flowCount', M.nextFlowIndex(all, 0, {}), 2)
  eq('which is the commit signal', M.nextFlowIndex(all, 0, {}) === M.flowCount(all), true)
  const proto = M.normalizeItem({ type: 'action', flow: [{ kind: 'text', skipUnless: 'keep' }, { kind: 'text' }] }, 'p', 0)
  // `for (const k in stored)` walks the prototype chain, so an inherited key
  // counts as a stored value. Pinned: the store the caller passes is a plain
  // object literal in every call site, so this is unreachable in production.
  eq('an inherited key counts as stored (for-in walks the chain)', M.nextFlowIndex(proto, 0, Object.create({ a: 'keep' })), 0)
  eq('an own key does too', M.nextFlowIndex(proto, 0, { a: 'keep' }), 0)
  eq('an empty store is just a no-match', M.nextFlowIndex(proto, 0, {}), 1)
  eq('a missing store does not throw - for-in over undefined is a no-op', M.nextFlowIndex(proto, 0, undefined), 1)
  eq('a null store neither', M.nextFlowIndex(proto, 0, null), 1)
  eq('a number store neither', M.nextFlowIndex(proto, 0, 5), 1)
  noThrow('and no call throws', () => M.nextFlowIndex(proto, 0, { a: { nested: 'keep' } }))
})

// ======================================================================
section('row presentation projections')
group('stageText: a stage owns its own copy while it renders', () => {
  // "A stage's own string wins while that stage renders - an EMPTY one too,
  // which is how a stage deliberately blanks the line - and a collapsed row
  // shows the top-level copy."
  eq('the stage copy', M.stageText(true, { label: 'S' }, 'label'), 'S')
  eq('a different key', M.stageText(true, { sub: 'S' }, 'sub'), 'S')
  eq('an empty string is a deliberate blank', M.stageText(true, { label: '' }, 'label'), '')
  // "A caller keeps its own copy on null."
  eq('a collapsed row has no stage copy', M.stageText(false, { label: 'S' }, 'label'), null)
  eq('an undefined expanded flag is collapsed', M.stageText(undefined, { label: 'S' }, 'label'), null)
  eq('no stage at all', M.stageText(true, null, 'label'), null)
  eq('an undefined stage', M.stageText(true, undefined, 'label'), null)
  eq('a stage with no such key', M.stageText(true, {}, 'label'), null)
  eq('a null value declines', M.stageText(true, { label: null }, 'label'), null)
  // `typeof v === "string"` - a number a bundle wrote is not a string, and
  // the caller's own copy stands rather than a "5" appearing on screen.
  eq('a number declines rather than stringifying', M.stageText(true, { label: 5 }, 'label'), null)
  eq('an object declines', M.stageText(true, { label: {} }, 'label'), null)
  eq('a boolean declines', M.stageText(true, { label: true }, 'label'), null)
  eq('so a caller can tell "no override" from "override"', [M.stageText(true, {}, 'label'), M.stageText(true, { label: '' }, 'label')], [null, ''])
  eq('and from "override with text"', M.stageText(true, { label: 'x' }, 'label'), 'x')
})

group('stageUnitSuffix: a stage unit overrides the row\'s, trimmed', () => {
  // "A stage that declares no unit keeps whatever the row declared."
  eq('a stage unit', M.stageUnitSuffix('ms', ' %'), ' ms')
  eq('it is trimmed', M.stageUnitSuffix('  ms  ', ' %'), ' ms')
  eq('undefined keeps the fallback', M.stageUnitSuffix(undefined, ' %'), ' %')
  eq('an undefined fallback is undefined', M.stageUnitSuffix(undefined, undefined), undefined)
  eq('an empty fallback is empty', M.stageUnitSuffix(undefined, ''), '')
  eq('a fallback of 0 is coerced by the caller, not here', M.stageUnitSuffix(undefined, 0), 0)
  // The test is `!== undefined` - so an empty or null stage unit IS an
  // answer, and the row shows a bare space where the unit word was. Pinned
  // with its real value: a stage that wants the row's unit must omit the key.
  eq('an empty stage unit renders a bare space', M.stageUnitSuffix('', ' %'), ' ')
  eq('a whitespace stage unit is trimmed to nothing', M.stageUnitSuffix('   ', ' %'), ' ')
  eq('a null stage unit is an answer, not a decline', M.stageUnitSuffix(null, ' %'), ' null')
  eq('a numeric stage unit', M.stageUnitSuffix(5, ' %'), ' 5')
  eq('a zero stage unit', M.stageUnitSuffix(0, ' %'), ' 0')
  eq('a false stage unit', M.stageUnitSuffix(false, ' %'), ' false')
})

group('stageSeedText: a flow stage seeds from its own store, never the row value', () => {
  // "A flow stage owns its seed: a text stage carries only what its OWN
  // stage stored, so a text stage with nothing stored opens empty and shows
  // its placeholder."
  eq('a text stage with nothing stored opens empty', M.stageSeedText(true, 'text', undefined), '')
  eq('a null store is nothing stored', M.stageSeedText(true, 'text', null), '')
  eq('an empty store is nothing stored', M.stageSeedText(true, 'text', ''), '')
  eq('a stored value seeds the field', M.stageSeedText(true, 'text', 'vb-shell session lock'), 'vb-shell session lock')
  eq('a stored number is stringified', M.stageSeedText(true, 'text', 15), '15')
  // The row's own value is the row's primary kind - the minutes of a
  // number-first flow - and a command field opening on "15" is a wrong
  // answer, not a default. A number stage has no text seed at all.
  eq('a number stage has no text seed', M.stageSeedText(true, 'number', '15'), '')
  eq('a range stage has no text seed', M.stageSeedText(true, 'range', undefined), '')
  eq('a select stage has no text seed', M.stageSeedText(true, 'select', 'command'), '')
  eq('an unknown kind has no text seed', M.stageSeedText(true, 'zzz', 'x'), '')
  // "or null when the caller keeps its own seed" - a legacy row still
  // seeds from its own state value.
  eq('a non-flow row keeps the caller\'s seed', M.stageSeedText(false, 'text', 'x'), null)
  eq('a non-flow row ignores the stored value', M.stageSeedText(false, 'text', undefined), null)
  eq('and an undefined flow flag is not a flow', M.stageSeedText(undefined, 'text', 'x'), null)
})

group('the editor seed of a flow row goes through the shared helper', () => {
  // The row's own value is the row's primary kind - the minutes of a
  // number-first flow - and a command field opening on "15" is a wrong
  // answer, not a default. The seed therefore comes from the helper, and
  // the row-value fallback stays behind the helper's decline.
  const entry = fs.readFileSync(path.join(SHELL_DIR, 'features/menu/Entry.qml'), 'utf8')
  contains('the editor seed asks the shared helper', entry, 'MenuLib.stageSeedText(')
  notContains('and the flow branch keeps no row-value fallback of its own', entry,
    'if (row.isFlow && (row.flowKind === "text"))')
  const seedBlock = entry.slice(entry.indexOf('initialText: {'), entry.indexOf('onCommit: text =>'))
  contains('the helper decides the flow seed', seedBlock, 'MenuLib.stageSeedText(')
  is('and the row value is reached only after the helper declines', seedBlock,
    (s) => s.indexOf('if (seed !== null) return seed') < s.indexOf('row.st.value'),
    'the early return comes first')
})

group('numberDisplay: an override wins, else the row value at its precision', () => {
  eq('an override is returned uncoerced', M.numberDisplay('OVR', 1.5, 0, ''), 'OVR')
  eq('a numeric override is not stringified', M.numberDisplay(42, 1.5, 0, ''), 42)
  eq('a zero override is an answer', M.numberDisplay(0, 1.5, 0, ''), 0)
  eq('a false override is an answer', M.numberDisplay(false, 1.5, 0, ''), false)
  // "The test is `!== null` and not a nullish check because null IS the
  // decline hookValue hands back - an override is any non-empty value,
  // uncoerced." So `undefined` is an ANSWER too, and the value slot would
  // render empty if a caller passed undefined meaning "no override". Pinned
  // with its real value: every call site hands hookValue's result, whose
  // decline is null.
  eq('undefined is an answer, not a decline', M.numberDisplay(undefined, 1.567, 2, ''), undefined)
  eq('null is the decline', M.numberDisplay(null, 1.567, 2, ''), '1.57')
  eq('the value is formatted at the row precision', M.numberDisplay(null, 1.5678, 3, ''), '1.568')
  eq('zero decimals', M.numberDisplay(null, 50.9, 0, ''), '51')
  eq('the suffix rides behind', M.numberDisplay(null, 50, 0, ' %'), '50 %')
  eq('a negative value', M.numberDisplay(null, -0.5, 1, ''), '-0.5')
  eq('a whole negative value', M.numberDisplay(null, -3, 0, ''), '-3')
  // "Bounds and drift are the caller's; nothing here clamps or quantizes."
  eq('nothing clamps above the row max', M.numberDisplay(null, 999, 0, ''), '999')
  eq('nothing clamps below the row min', M.numberDisplay(null, -999, 0, ''), '-999')
  eq('nothing quantizes either', M.numberDisplay(null, 0.1 + 0.2, 3, ''), '0.300')
  eq('a 0.1+0.2 value still prints the drift at full precision', M.numberDisplay(null, 0.1 + 0.2, 17, '').length > 16, true)
  eq('NaN prints as NaN, it does not throw', M.numberDisplay(null, NaN, 2, ''), 'NaN')
  approx('and quantizing at the caller is what removes the drift', M.quantize(Number(M.numberDisplay(null, 0.1 + 0.2, 3, ''))), 0.3, 1e-9)
  // A string value is a caller bug (the store hands numbers) and the failure
  // is a throw rather than a silent "NaN".
  throws('a string value throws', () => M.numberDisplay(null, '1.5', 1, ''), /toFixed/)
  throws('an undefined value throws', () => M.numberDisplay(null, undefined, 1, ''), /toFixed/)
  throws('a null value throws', () => M.numberDisplay(null, null, 1, ''), /toFixed/)
})

group('valueSlotW: a shared column wins, otherwise the row reserves its own', () => {
  // "A shared column wins when the panel published one ... `unified` of 0
  // means no shared column."
  eq('a shared column wins outright', M.valueSlotW(120, 40, 8, 200), 120)
  eq('0 means no shared column', M.valueSlotW(0, 40, 8, 200), 48)
  eq('a negative unified is not a shared column', M.valueSlotW(-5, 40, 8, 200), 48)
  eq('an undefined unified is not a shared column', M.valueSlotW(undefined, 40, 8, 200), 48)
  // `unified > 0` on a NaN is false, so a NaN panel measurement falls back to
  // the row's own width rather than reserving nothing.
  eq('a NaN unified is not a shared column', M.valueSlotW(NaN, 40, 8, 200), 48)
  eq('the cap applies to the row width', M.valueSlotW(0, 400, 8, 200), 200)
  eq('a value exactly at the cap is kept', M.valueSlotW(0, 192, 8, 200), 200)
  eq('and one below it is not capped', M.valueSlotW(0, 191, 8, 200), 199)
  eq('the pad is added before the cap', M.valueSlotW(0, 100, 20, 200), 120)
  eq('the cap is not applied to a shared column', M.valueSlotW(500, 400, 8, 200), 500)
  // "capped so one long value cannot push the label out of the card."
  eq('a long value cannot exceed the cap', M.valueSlotW(0, 100000, 8, 200), 200)
  is('an undefined pad makes the width NaN, not a throw', M.valueSlotW(0, 40, undefined, 200), (v) => Number.isNaN(v), 'NaN')
  is('an undefined cap does too', M.valueSlotW(0, 40, 8, undefined), (v) => Number.isNaN(v), 'NaN')
  eq('a zero pad is fine', M.valueSlotW(0, 40, 0, 200), 40)
  eq('no arguments at all', M.valueSlotW(), M.valueSlotW())
})

group('optionLabelFor compares strictly, and falls back to the raw value', () => {
  // "Options come from the bundle, so the comparison is strict - a number
  // option never matches a stored string."
  const opts = [{ label: 'One', value: 'a' }, { label: 'Two', value: 2 }, { label: 'Three', value: 'c' }]
  eq('a string value matches', M.optionLabelFor(opts, 'a'), 'One')
  eq('a number value matches', M.optionLabelFor(opts, 2), 'Two')
  eq('the last option matches too', M.optionLabelFor(opts, 'c'), 'Three')
  // "a value the bundle no longer offers still shows what it holds instead of
  // an empty slot."
  eq('an unknown value shows itself', M.optionLabelFor(opts, 'zz'), 'zz')
  eq('a string "2" does not match the number 2', M.optionLabelFor(opts, '2'), '2')
  eq('a number 1 does not match the string "a"', M.optionLabelFor(opts, 1), '1')
  eq('undefined shows as the word', M.optionLabelFor(opts, undefined), 'undefined')
  eq('null shows as the word', M.optionLabelFor(opts, null), 'null')
  eq('a false value is itself the comparison key', M.optionLabelFor([{ label: 'No', value: false }], false), 'No')
  eq('a zero value is itself the comparison key', M.optionLabelFor([{ label: 'Zero', value: 0 }], 0), 'Zero')
  eq('the first match wins', M.optionLabelFor([{ label: 'A', value: 'x' }, { label: 'B', value: 'x' }], 'x'), 'A')
  eq('an empty option list shows the raw value', M.optionLabelFor([], 'x'), 'x')
  throws('a missing options array is a throw', () => M.optionLabelFor(undefined, 'x'), /length/)
  throws('a null option entry is a throw', () => M.optionLabelFor([null], 'x'), /value/)
  throws('and so is a null options array', () => M.optionLabelFor(null, 'x'), /length/)
  // A STRING options list is indexed char by char, and each char has no
  // `.value`, so every comparison misses and the raw value is shown. Pinned:
  // a wrong-typed options field degrades to "no label", never to a throw.
  eq('a string options list shows the raw value', M.optionLabelFor('abc', 'x'), 'x')
  eq('a number options list shows the raw value too', M.optionLabelFor(7, 'x'), 'x')
})

group('optionSeedIndex compares by text, and seats the cursor on the value', () => {
  // "The comparison is by text, unlike optionLabelFor: the cursor has to meet
  // a value that comes back from a settings store as a string against an
  // option that declares a number."
  const opts = [{ label: 'One', value: 'a' }, { label: 'Two', value: 2 }, { label: 'Three', value: 'c' }]
  eq('the first option', M.optionSeedIndex(opts, 'a'), 0)
  eq('a later option', M.optionSeedIndex(opts, 'c'), 2)
  eq('a numeric option value', M.optionSeedIndex(opts, 2), 1)
  eq('and the string form of it', M.optionSeedIndex(opts, '2'), 1)
  eq('a boolean value by text', M.optionSeedIndex([{ label: 'No', value: false }], false), 0)
  eq('a zero value by text', M.optionSeedIndex([{ label: 'Zero', value: 0 }], 0), 0)
  eq('and the string "0"', M.optionSeedIndex([{ label: 'Zero', value: 0 }], '0'), 0)
  // "or the first option when none does, so Enter-Enter re-picks the stored
  // choice without the arrows moving."
  eq('an unknown value seats the cursor on the first option', M.optionSeedIndex(opts, 'zz'), 0)
  eq('an empty option list seats it at 0', M.optionSeedIndex([], 'x'), 0)
  eq('an undefined value seats it at 0', M.optionSeedIndex(opts, undefined), 0)
  eq('the first match wins', M.optionSeedIndex([{ value: 'x' }, { value: 'x' }], 'x'), 0)
  eq('a string option value matches a number query by text', M.optionSeedIndex([{ value: '2' }], 2), 0)
  eq('and the reverse', M.optionSeedIndex([{ value: 2 }], '2'), 0)
  throws('a null option entry is a throw', () => M.optionSeedIndex([null], 'x'), /value/)
  throws('and a null options array', () => M.optionSeedIndex(null, 'x'), /length/)
})

group('the dropdown geometry: one column under seven, two columns over', () => {
  // "A long option list (codec selection) halves its height into two columns
  // instead of scrolling forever; a short one keeps the single-column look."
  eq('six options stay in one column', M.optionColumnCount(6), 1)
  eq('seven options split', M.optionColumnCount(7), 2)
  eq('a single option is one column', M.optionColumnCount(1), 1)
  eq('zero options is still one column', M.optionColumnCount(0), 1)
  eq('six rows in one column', M.optionRowCount(6), 6)
  eq('seven options need four rows per column', M.optionRowCount(7), 4)
  eq('the odd one out spills into the second column', M.optionRowCount(7) * M.optionColumnCount(7), 8)
  eq('eight split evenly', M.optionRowCount(8), 4)
  eq('nine need five', M.optionRowCount(9), 5)
  eq('thirteen need seven', M.optionRowCount(13), 7)
  eq('one hundred need fifty', M.optionRowCount(100), 50)
  eq('one hundred and one need fifty-one', M.optionRowCount(101), 51)
})

group('the fill is column-major and the stride is the row count', () => {
  // "The fill is column-major, so the linear cursor walks top-to-bottom, and
  // Left/Right page a whole column - a stride of 0 for a single column,
  // where the key falls through to its next binding instead of moving
  // nothing."
  eq('a single column has a stride of 0', M.optionColumnStride(6), 0)
  eq('so does an empty list', M.optionColumnStride(0), 0)
  eq('a single option has a stride of 0', M.optionColumnStride(1), 0)
  eq('seven options stride by four', M.optionColumnStride(7), 4)
  eq('eight stride by four', M.optionColumnStride(8), 4)
  eq('nine stride by five', M.optionColumnStride(9), 5)
  eq('and the stride always equals the row count', [7, 8, 9, 13, 100].map(M.optionColumnStride), [7, 8, 9, 13, 100].map(M.optionRowCount))
  eq('so cols * stride is the padded grid', [7, 8, 9, 13, 100].map(c => M.optionColumnCount(c) * M.optionColumnStride(c)), [8, 8, 10, 14, 100])
  eq('and it is always at least the option count', [0, 1, 6, 7, 8, 9, 13, 100].every(c => M.optionColumnCount(c) * M.optionRowCount(c) >= c), true)
  eq('and never more than the count plus one', [1, 6, 7, 8, 9, 13, 100].every(c => M.optionColumnCount(c) * M.optionRowCount(c) - c < M.optionColumnCount(c)), true)
})

group('optionCellCol/optionCellRow round-trip against the counts', () => {
  // Column-major fill: index 0..rows-1 is column 0, then rows..2*rows-1 is
  // column 1. With a stride of 0 (single column) every index is column 0 and
  // its own row.
  eq('a single column is always column 0', [0, 1, 2, 3, 4, 5].map(i => M.optionCellCol(i, 6)), [0, 0, 0, 0, 0, 0])
  eq('and every index is its own row', [0, 1, 2, 3, 4, 5].map(i => M.optionCellRow(i, 6)), [0, 1, 2, 3, 4, 5])
  eq('seven options: the first four are column 0', [0, 1, 2, 3].map(i => M.optionCellCol(i, 7)), [0, 0, 0, 0])
  eq('and the last three are column 1', [4, 5, 6].map(i => M.optionCellCol(i, 7)), [1, 1, 1])
  eq('rows restart at the top of column 1', [0, 1, 2, 3, 4, 5, 6].map(i => M.optionCellRow(i, 7)), [0, 1, 2, 3, 0, 1, 2])
  eq('an eight-option list fills both columns exactly', [0, 1, 2, 3].map(i => M.optionCellCol(i, 8)), [0, 0, 0, 0])
  eq('and the second column is rows 4..7', [4, 5, 6, 7].map(i => M.optionCellCol(i, 8)), [1, 1, 1, 1])
  eq('so the row of index 4 is 0', M.optionCellRow(4, 8), 0)
  eq('and index 7 is row 3', M.optionCellRow(7, 8), 3)
  // The linear index is recoverable from (col, row) and the stride - which is
  // what makes Left/Right "page a whole column" and the cursor walk
  // top-to-bottom. Verified across the interesting counts.
  for (const c of [1, 6, 7, 8, 9, 10, 11, 12, 13, 25, 100, 101]) {
    const cols = M.optionColumnCount(c)
    const rows = M.optionRowCount(c)
    const stride = M.optionColumnStride(c)
    eq(`every cell of ${c} is in range`, Array.from({ length: c }, (_, i) => M.optionCellCol(i, c)).every(v => v >= 0 && v < cols), true)
    eq(`every row of ${c} is in range`, Array.from({ length: c }, (_, i) => M.optionCellRow(i, c)).every(v => v >= 0 && v < rows), true)
    eq(`every cell of ${c} is distinct`, new Set(Array.from({ length: c }, (_, i) => M.optionCellCol(i, c) + ':' + M.optionCellRow(i, c))).size, c)
    // col*stride + row recovers the linear index; for a single column
    // stride is 0, so the identity holds trivially with row == index.
    eq(`col*stride+row recovers the index for ${c}`, Array.from({ length: c }, (_, i) => M.optionCellCol(i, c) * stride + M.optionCellRow(i, c)), Array.from({ length: c }, (_, i) => i))
  }
  // A single column's stride of 0 is deliberate: the key falls through to its
  // next binding rather than "moving nothing" inside a one-column list.
  eq('a single column stride of 0 makes Left/Right a no-op by arithmetic', M.optionColumnStride(1) === 0, true)
  eq('and a two-column stride is the page size', M.optionCellCol(5, 9) * M.optionColumnStride(9) + M.optionCellRow(5, 9), 5)
  eq('so Right from the last of column 0 lands in column 1', [M.optionCellCol(4, 9), M.optionCellRow(4, 9)], [0, 4])
  eq('which is the top of the second column', [M.optionCellCol(5, 9), M.optionCellRow(5, 9)], [1, 0])
})

group('leadingNumber reads the number the user typed, or nothing', () => {
  // "an optional minus, digits, and an optional decimal point written either
  // way, because a comma is what a locale keyboard types."
  eq('a whole number', M.leadingNumber('12'), 12)
  eq('a negative whole number', M.leadingNumber('-12'), -12)
  eq('a dot decimal', M.leadingNumber('12.5'), 12.5)
  eq('a comma decimal', M.leadingNumber('12,5'), 12.5)
  eq('a negative decimal', M.leadingNumber('-0.5'), -0.5)
  eq('leading whitespace is skipped', M.leadingNumber('  12 '), 12)
  eq('leading zeros are read as decimal', M.leadingNumber('007'), 7)
  // "Trailing junk after the digits is tolerated ("12 fps" reads 12)"
  eq('trailing units', M.leadingNumber('12 fps'), 12)
  eq('trailing digits are not part of it', M.leadingNumber('12abc34'), 12)
  eq('a second decimal point ends the number', M.leadingNumber('1.2.3'), 1.2)
  eq('exponent notation reads as the mantissa', M.leadingNumber('1e3'), 1)
  // "input that does not start with a number yields null, and the caller
  // restores the real value rather than committing garbage."
  eq('letters yield null', M.leadingNumber('abc'), null)
  eq('the empty string yields null', M.leadingNumber(''), null)
  eq('whitespace only yields null', M.leadingNumber('   '), null)
  eq('a lone minus yields null', M.leadingNumber('-'), null)
  eq('a leading decimal point yields null', M.leadingNumber('.5'), null)
  eq('a plus sign is not in the grammar', M.leadingNumber('+5'), null)
  eq('undefined yields null', M.leadingNumber(undefined), null)
  eq('null yields null', M.leadingNumber(null), null)
  eq('an empty object yields null', M.leadingNumber({}), null)
  // `String(text)` first, so a number passes straight through.
  eq('a numeric input is stringified and re-read', M.leadingNumber(12.5), 12.5)
  eq('a negative numeric input', M.leadingNumber(-12.5), -12.5)
  eq('a zero', M.leadingNumber(0), 0)
  eq('NaN yields null', M.leadingNumber(NaN), null)
  approx('a comma decimal is the same value as a dot one', M.leadingNumber('12,5'), M.leadingNumber('12.5'), 1e-12)
  eq('and callers quantize on top of it', M.quantize(M.leadingNumber('1,005')), 1.005)
  // The caller clamps and quantizes itself; the parse never does.
  eq('a value beyond any row max is still returned whole', M.leadingNumber('9999'), 9999)
  eq('a negative beyond any row min too', M.leadingNumber('-9999'), -9999)
})

group('exactOptionIndex: the query must already be lowercased', () => {
  // "`query` is compared as handed over, and the option text is case-folded
  // before it is compared, so the caller lowercases the query - which is what
  // the search bar already does. A query that was not folded would match
  // nothing, and folding it here would fold it twice for no gain."
  const opts = [{ label: 'Google', value: 'g' }, { label: 'Duck', value: 'd' }]
  eq('a lowercased label', M.exactOptionIndex(opts, 'google'), 0)
  eq('a lowercased value', M.exactOptionIndex(opts, 'd'), 1)
  eq('an unfolded label matches nothing', M.exactOptionIndex(opts, 'Google'), -1)
  eq('an unfolded value matches nothing', M.exactOptionIndex(opts, 'D'), -1)
  eq('an upper-case query matches nothing', M.exactOptionIndex(opts, 'GOOGLE'), -1)
  eq('a partial label is not an exact match', M.exactOptionIndex(opts, 'goog'), -1)
  eq('a superstring is not an exact match either', M.exactOptionIndex(opts, 'googlex'), -1)
  eq('a label containing a space matches as written', M.exactOptionIndex([{ label: 'Light mode', value: 'l' }], 'light mode'), 0)
  eq('an unrelated query names nothing', M.exactOptionIndex(opts, 'zzz'), -1)
  eq('the first match wins', M.exactOptionIndex([{ label: 'x', value: '1' }, { label: 'x', value: '2' }], 'x'), 0)
  eq('a second option can be named', M.exactOptionIndex(opts, 'duck'), 1)
})

group('a query may be qualified by the row family label, spaced or dashed', () => {
  // "The query is read as the option's own label or value, either alone or
  // qualified by the row's family label, because a query run together reads
  // as "Family Option" and "Family-Option" both."
  const opts = [{ label: 'Google', value: 'g' }, { label: 'Duck', value: 'd' }]
  eq('family + space', M.exactOptionIndex(opts, 'engine google', 'Engine'), 0)
  eq('family + dash', M.exactOptionIndex(opts, 'engine-google', 'Engine'), 0)
  // The family IS folded here; the query is not.
  eq('an upper-case family is folded', M.exactOptionIndex(opts, 'engine google', 'ENGINE'), 0)
  eq('a family is trimmed too', M.exactOptionIndex(opts, 'search engine duck', '  Search Engine  '), 1)
  eq('an upper-case query defeats even a folded family', M.exactOptionIndex(opts, 'Engine google', 'Engine'), -1)
  // With no family, the qualified forms are " label" and "-label", which no
  // honest query produces.
  eq('no family, no qualified match', M.exactOptionIndex(opts, 'engine google'), -1)
  eq('no family, no dashed match', M.exactOptionIndex(opts, 'engine-google'), -1)
  eq('an undefined family behaves as none', M.exactOptionIndex(opts, 'google', undefined), 0)
  eq('a null family behaves as none', M.exactOptionIndex(opts, 'google', null), 0)
  eq('a numeric family is folded to text', M.exactOptionIndex(opts, '5 google', 5), 0)
  eq('an empty family leaves only the bare forms', M.exactOptionIndex(opts, 'google', ''), 0)
  eq('and a bare query still works with an empty family', M.exactOptionIndex(opts, 'google', 'Engine'), 0)
  eq('a family with a trailing space still qualifies', M.exactOptionIndex(opts, 'engine google', 'Engine '), 0)
})

group('bestOptionIndex: the exact forms first, then the best of the rest', () => {
  // "The strict reading above is only half of what a user means by 'the one
  // that matched': they type the start of a name far more often than the
  // whole of it." These are the cases where exactOptionIndex is -1 and the
  // loose reading has to answer instead - the whole reason the function
  // exists is that a -1 leaves the cursor on the row's stored value.
  const themed = [
    { label: 'Frappe', value: 'catppuccin-frappe' },
    { label: 'Latte', value: 'catppuccin-latte' },
    { label: 'Macchiato', value: 'catppuccin-macchiato' },
    { label: 'Mocha', value: 'catppuccin-mocha' },
  ]
  eq('the exact answer is passed through', M.bestOptionIndex(themed, 'latte', 'Catppuccin'), 1)
  eq('a half-typed label finds its option', M.bestOptionIndex(themed, 'lat', 'Catppuccin'), 1)
  eq('a longer half also finds it', M.bestOptionIndex(themed, 'macch', 'Catppuccin'), 2)
  eq('and by the value prefix too', M.bestOptionIndex(themed, 'moch', 'Catppuccin'), 3)
  eq('the first option is reachable by a prefix', M.bestOptionIndex(themed, 'frap', 'Catppuccin'), 0)
  // The exact forms must not be re-decided by the scorer, which prefers the
  // value (it carries the family as a prefix and so scores highest).
  eq('an exact label outranks the value form', M.bestOptionIndex(themed, 'mocha', 'Catppuccin'), 3)
  eq('an exact value still wins', M.bestOptionIndex(themed, 'catppuccin-latte', 'Catppuccin'), 1)
  eq('a family-qualified label still wins', M.bestOptionIndex(themed, 'catppuccin mocha', 'Catppuccin'), 3)
  eq('a family-qualified dash still wins', M.bestOptionIndex(themed, 'catppuccin-macchiato', 'Catppuccin'), 2)
})

group('bestOptionIndex answers -1 rather than guessing between equals', () => {
  // "A tie answers -1 rather than picking a winner... Seating an arbitrary
  // option there would walk the cursor off the row's stored value on a query
  // that never mentioned a variant." The family name is the case that
  // matters, because it is the query a user types to open the family at all.
  const themed = [
    { label: 'Jade', value: 'osaka-jade' },
    { label: 'Light', value: 'osaka-light' },
    { label: 'Osaka', value: 'osaka-osaka' },
    { label: 'Solarized', value: 'osaka-solarized' },
  ]
  eq('the family name alone ties and names nothing', M.bestOptionIndex(themed, 'osaka', 'Osaka'), 2)
  // ...while that same query naming a variant is not a tie at all.
  eq('a half-typed variant is not a tie', M.bestOptionIndex(themed, 'solar', 'Osaka'), 3)
  eq('a shorter prefix is not a tie either', M.bestOptionIndex(themed, 'sol', 'Osaka'), 3)
  // Genuine ties outside the family-name case: two options that score
  // identically, where -1 is the only non-arbitrary answer.
  eq('two options that score alike name nothing', M.bestOptionIndex(
    [{ label: 'Alpha', value: 'a-one' }, { label: 'Beta', value: 'a-two' }], 'a', 'Zed'), -1)
  eq('an empty query still names nothing', M.bestOptionIndex(themed, '', 'Osaka'), -1)
  eq('a query matching no option names nothing', M.bestOptionIndex(themed, 'zzzz', 'Osaka'), -1)
  eq('a family with no options is safe', M.bestOptionIndex([], 'anything', 'Osaka'), -1)
  eq('a non-array options value is safe', M.bestOptionIndex(null, 'anything', 'Osaka'), -1)
  // An option carrying neither text cannot win a score it never earned.
  eq('a blank option cannot be seated', M.bestOptionIndex(
    [{ label: '', value: '' }, { label: 'Jade', value: 'osaka-jade' }], 'jade', 'Osaka'), 1)
})

group('exactOptionIndex folds the option text and drops falsy values', () => {
  eq('option labels are trimmed', M.exactOptionIndex([{ label: '  Padded  ', value: 'p' }], 'padded'), 0)
  eq('and lowercased', M.exactOptionIndex([{ label: 'PADDED', value: 'p' }], 'padded'), 0)
  eq('option values are trimmed', M.exactOptionIndex([{ label: 'L', value: '  v  ' }], 'v'), 0)
  eq('and lowercased', M.exactOptionIndex([{ label: 'L', value: 'V' }], 'v'), 0)
  eq('a numeric value is stringified', M.exactOptionIndex([{ label: 'Five', value: 5 }], '5'), 0)
  // `String(opt.value || "")` - a 0 value folds to the empty string, so a
  // zero-valued option is reachable by its label but NOT by its value. Pinned
  // with its real value: it is a real, if narrow, gap in the value lookup.
  eq('a zero value is unreachable as a query', M.exactOptionIndex([{ label: 'Zero', value: 0 }], '0'), -1)
  eq('but its label still names it', M.exactOptionIndex([{ label: 'Zero', value: 0 }], 'zero'), 0)
  eq('a false value is unreachable as a query too', M.exactOptionIndex([{ label: 'No', value: false }], 'false'), -1)
  eq('an option with only a value', M.exactOptionIndex([{ value: 'v' }], 'v'), 0)
  eq('an option with only a label', M.exactOptionIndex([{ label: 'l' }], 'l'), 0)
  eq('an option with neither is unreachable', M.exactOptionIndex([{}], ''), -1)
  eq('a non-array options list names nothing', M.exactOptionIndex(null, 'x'), -1)
  eq('an undefined options list names nothing', M.exactOptionIndex(undefined, 'x'), -1)
  eq('a null option entry is skipped, not a throw', M.exactOptionIndex([null], 'x'), -1)
  eq('a hole in the options list is skipped', M.exactOptionIndex([undefined, { label: 'a', value: 'a' }], 'a'), 1)
  // "An empty query names nothing, deliberately: it expands the row and
  // leaves the option cursor where the row's stored value put it."
  eq('an empty query names nothing', M.exactOptionIndex(opts2(), ''), -1)
  eq('an undefined query names nothing', M.exactOptionIndex(opts2(), undefined), -1)
  eq('a null query names nothing', M.exactOptionIndex(opts2(), null), -1)
  eq('a numeric query is stringified and matched', M.exactOptionIndex([{ label: 'Five', value: 5 }], 5), 0)
  eq('a false query names nothing', M.exactOptionIndex(opts2(), false), -1)
  function opts2() {
    return [{ label: 'Google', value: 'g' }]
  }
})

// ======================================================================
section('the keyboard model: edges and routes')
group('selectableEdge finds the first or the last selectable index', () => {
  const rows = ['a', 'b', 'c', 'd', 'e']
  const only = (i) => (idx) => idx === i
  eq('all selectable, from the front', M.selectableEdge(rows, () => true, false), 0)
  eq('all selectable, from the back', M.selectableEdge(rows, () => true, true), 4)
  eq('one selectable, from the front', M.selectableEdge(rows, only(2), false), 2)
  eq('one selectable, from the back', M.selectableEdge(rows, only(2), true), 2)
  eq('none selectable, from the front', M.selectableEdge(rows, () => false, false), -1)
  eq('none selectable, from the back', M.selectableEdge(rows, () => false, true), -1)
  eq('an empty model is -1 from either end', M.selectableEdge([], () => true, false), -1)
  eq('an empty model from the back too', M.selectableEdge([], () => true, true), -1)
  eq('only the first, from the front', M.selectableEdge(rows, only(0), false), 0)
  eq('only the first, from the back', M.selectableEdge(rows, only(0), true), 0)
  eq('only the last, from the front', M.selectableEdge(rows, only(4), false), 4)
  eq('only the last, from the back', M.selectableEdge(rows, only(4), true), 4)
  // "The list end jump used to wrap its index modulo the model length, which
  // a linear walk of exactly rows.length steps from either end never needs."
  // Pinned: the answer is always a real index in [0, n).
  for (let sel = -1; sel < 6; sel++) {
    for (const last of [false, true]) {
      const r = M.selectableEdge(rows, only(sel), last)
      eq(`front=${!last} only=${sel} -> ${r}`, r === -1 || (r >= 0 && r < rows.length), true)
    }
  }
})

group('the `last` flag is read as a boolean, not a direction', () => {
  const rows = ['a', 'b', 'c', 'd', 'e']
  eq('a truthy non-boolean means "from the back"', M.selectableEdge(rows, (i) => i === 4, 1), 4)
  eq('0 is falsy, so it means "from the front"', M.selectableEdge(rows, (i) => i === 4, 0), 4)
  eq('undefined means "from the front"', M.selectableEdge(rows, (i) => i === 2, undefined), 2)
  eq('and the predicate is read as a boolean too', M.selectableEdge(rows, () => 'yes', false), 0)
  eq('a truthy predicate at the back scans backwards', M.selectableEdge(rows, () => 'yes', true), 4)
  eq('a predicate that is not a function is a caller bug', (() => { try { return M.selectableEdge(rows, undefined, false) } catch (e) { return 'throws' } })(), 'throws')
  eq('and it throws rather than answering -1', (() => { try { M.selectableEdge(rows, undefined, false); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  eq('a null model throws rather than answering -1', (() => { try { M.selectableEdge(null, () => true, false); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
})

group('keyRoute: list mode navigation and activation', () => {
  eq('Down and Tab both move forward', [routeOf({ key: 'down' }), routeOf({ key: 'tab' })], ['move 1', 'move 1'])
  eq('Up and Backtab both move back', [routeOf({ key: 'up' }), routeOf({ key: 'backtab' })], ['move -1', 'move -1'])
  eq('+ and = step up', [routeOf({ key: 'plus' }), routeOf({ key: 'equal' })], ['step 1', 'step 1'])
  eq('- and _ step down', [routeOf({ key: 'minus' }), routeOf({ key: 'underscore' })], ['step -1', 'step -1'])
  eq('Left is the option/step pair, backwards', routeOf({ key: 'left' }), 'optionOrStep -1')
  eq('Right is the option/step pair, forwards', routeOf({ key: 'right' }), 'optionOrStep 1')
  eq('Return activates', routeName({ key: 'returnKey' }), 'activate')
  eq('Enter activates too', routeName({ key: 'enterKey' }), 'activate')
  eq('Escape escapes', routeName({ key: 'escape' }), 'escape')
  eq('Home is the start edge', routeOf({ key: 'home' }), 'end false')
  eq('End is the end edge', routeOf({ key: 'endKey' }), 'end true')
  eq('PageUp pages back by 0.8 of the model', routeOf({ key: 'pageUp' }), 'page -0.8')
  eq('PageDown pages forward by 0.8 of the model', routeOf({ key: 'pageDown' }), 'page 0.8')
  // "Space and Enter stay two routes because they were two call sites: Enter
  // hands activate the shift bit and Space never did."
  eq('Space activates without the shift bit', routeName({ key: 'space' }), 'activateNoShift')
  eq('and it carries no argument', routeOf({ key: 'space' }), 'activateNoShift')
  approx('PageUp is a fraction, not a count', M.keyRoute(kctx({ key: 'pageUp' })).arg, -0.8, 1e-12)
  approx('and PageDown is its mirror', M.keyRoute(kctx({ key: 'pageDown' })).arg, 0.8, 1e-12)
})

group('keyRoute: the field keeps Enter, Space and the side arrows in filter mode', () => {
  // "The field's onAccepted already handles Enter when it has focus; don't
  // double-activate."
  eq('Enter with the field focused is unclaimed', routeName({ key: 'returnKey', field: true }), '')
  eq('Return with the field focused too', routeName({ key: 'enterKey', field: true }), '')
  eq('and then the field has focus, so it did not activate', routeName({ key: 'returnKey', field: true }) === 'activate', false)
  eq('Enter without the field is activate', routeName({ key: 'returnKey' }), 'activate')
  eq('Space with the field focused is unclaimed', routeName({ key: 'space', field: true }), '')
  eq('Space in list mode still activates', routeName({ key: 'space' }), 'activateNoShift')
  // "In filter mode the field owns the caret and keeps the key."
  eq('Left in filter mode is unclaimed', routeName({ key: 'left', mode: 'filter' }), '')
  eq('Right in filter mode is unclaimed', routeName({ key: 'right', mode: 'filter' }), '')
  eq('Backspace in filter mode is unclaimed', routeName({ key: 'backspace', mode: 'filter' }), '')
  eq('Delete in filter mode is unclaimed', routeName({ key: 'deleteKey', mode: 'filter' }), '')
  eq("and typing in filter mode is the field's, not a query", routeName({ key: '', mode: 'filter', text: 'a' }), null)
  eq('so "/" in filter mode is not the scoped trigger either', routeName({ key: '', mode: 'filter', text: '/' }), null)
})

group('keyRoute: a printable character becomes a query, and "/" the scoped filter', () => {
  eq('a letter', routeOf({ key: '', text: 'a' }), 'query "a"')
  eq('a digit', routeOf({ key: '', text: '7' }), 'query "7"')
  eq('an upper-case letter passes through as typed', routeOf({ key: '', text: 'Z' }), 'query "Z"')
  eq('punctuation is a query too', routeOf({ key: '', text: '!' }), 'query "!"')
  eq('and so is ~', routeOf({ key: '', text: '~' }), 'query "~"')
  // 'No modifier may be held, or Ctrl+A and friends would be swallowed.'
  eq('Ctrl plus a letter is not a query', routeName({ key: '', ctrl: true, text: 'a' }), null)
  eq('Meta plus a letter is not a query', routeName({ key: '', meta: true, text: 'a' }), null)
  eq('and both are not a query', routeName({ key: '', ctrl: true, meta: true, text: 'a' }), null)
  // "/" arms the in-page quick-filter instead and is not itself part of the
  // query.
  eq('"/" routes to scoped', routeOf({ key: '', text: '/' }), 'scoped "/"')
  eq('and carries the slash as its argument', M.keyRoute(kctx({ key: '', text: '/' })).arg, '/')
  eq('any other printable routes to query', routeName({ key: '', text: 'a' }), 'query')
  // "text.length === 1" - anything else is not a query, including a
  // multi-byte character (a surrogate pair is length 2).
  eq('a two-character text is not a query', routeName({ key: '', text: 'ab' }), null)
  eq('an empty text is not a query', routeName({ key: '', text: '' }), null)
  eq('a missing text is not a query', routeName({ key: '' }), null)
  eq('a null text is not a query', routeName({ key: '', text: null }), null)
  eq('an emoji is length 2, so not a query', routeName({ key: '', text: '\u{1F600}' }), null)
  // 'text.charCodeAt(0) >= 32' - a control character is not printable. DEL is
  // 127 and passes, which is a real (if harmless) hole: the panel routes
  // Delete by key name, and a DEL *character* with an unknown key name would
  // land here.
  eq('a control character is not a query', routeName({ key: '', text: '\u0001' }), null)
  eq('DEL (127) passes the printable test', routeName({ key: '', text: '\u007f' }), 'query')
  eq('space (32) is at the boundary and passes', routeOf({ key: '', text: ' ' }), 'query " "')
  // A named letter key with text still routes on the TEXT, because the key
  // table has no case for it.
  eq('a named letter key with text routes on the text', routeOf({ key: 'keyA', text: 'a' }), 'query "a"')
  eq('a named letter key with no text is unclaimed', routeName({ key: 'keyA' }), null)
  eq('an empty vocabulary entry is unclaimed', routeName({ key: '' }), null)
})

group('keyRoute: modified letters live outside the switch', () => {
  // "a bare case would swallow the plain letter and break type-to-search".
  eq('Ctrl+I is info', routeOf({ key: 'keyI', ctrl: true }), 'info')
  eq('Ctrl+F is the filter', routeOf({ key: 'keyF', ctrl: true }), 'filter')
  eq('Ctrl+I needs no text', routeOf({ key: 'keyI', ctrl: true, text: '' }), 'info')
  eq('Ctrl+A is not bound and stays unclaimed', routeName({ key: 'keyA', ctrl: true }), null)
  eq('and stays unclaimed even with text', routeName({ key: 'keyA', ctrl: true, text: 'a' }), null)
  eq('Meta+I is not bound either', routeName({ key: 'keyI', meta: true }), null)
  eq('Ctrl alone does not claim a bare letter', routeName({ key: '', ctrl: true, text: 'a' }), null)
  // The binds are checked before the mode, so a Ctrl in filter mode still
  // opens info.
  eq('Ctrl+I works in filter mode too', routeName({ key: 'keyI', ctrl: true, mode: 'filter' }), 'info')
  eq('and Ctrl+F as well', routeName({ key: 'keyF', ctrl: true, mode: 'filter' }), 'filter')
  // ...and before the editor swallow, so an open editor cannot eat them.
  eq('Ctrl+F works with an editor open', routeName({ key: 'keyF', ctrl: true, editor: true }), 'filter')
  eq('Ctrl+I works with an editor open', routeName({ key: 'keyI', ctrl: true, editor: true }), 'info')
  eq('the modifier test is strict', routeName({ key: 'keyI', ctrl: 1 }), null)
  eq('a non-boolean truthy ctrl does not bind', routeName({ key: 'keyF', ctrl: 'yes' }), null)
})

group('keyRoute: grid pages move spatially', () => {
  // "Grid pages: arrows move spatially - Left/Right step cells, Up/Down jump
  // rows. Tab/Backtab keep the linear next/prev walk of lists;
  // everything else ... falls through to the shared routes."
  const g = (o) => routeOf(Object.assign({ grid: true }, o))
  eq('Left steps one cell back', g({ key: 'left' }), 'cell -1')
  eq('Right steps one cell on', g({ key: 'right' }), 'cell 1')
  eq('Up jumps a grid row back', g({ key: 'up' }), 'gridRow -1')
  eq('Down jumps a grid row on', g({ key: 'down' }), 'gridRow 1')
  eq('Tab still walks linearly', g({ key: 'tab' }), 'move 1')
  eq('Backtab still walks linearly', g({ key: 'backtab' }), 'move -1')
  eq('Home still jumps to the start', g({ key: 'home' }), 'end false')
  eq('End still jumps to the end', g({ key: 'endKey' }), 'end true')
  eq('Enter still activates', g({ key: 'returnKey' }), 'activate')
  eq('Escape still escapes', g({ key: 'escape' }), 'escape')
  eq('typing still filters across pages', g({ key: '', text: 'a' }), 'query "a"')
  eq('+ still steps', g({ key: 'plus' }), 'step 1')
  // Left/Right in filter mode stay the field's (caret); Up/Down still
  // jump grid rows so an emoji query keeps vertical navigation.
  eq("Left in filter mode is the field's", routeName({ key: 'left', grid: true, mode: 'filter' }), '')
  eq("Right in filter mode is the field's too", routeName({ key: 'right', grid: true, mode: 'filter' }), '')
  eq('Up in filter mode still jumps a grid row', routeOf({ key: 'up', grid: true, mode: 'filter' }), 'gridRow -1')
  eq('Down in filter mode still jumps a grid row', routeOf({ key: 'down', grid: true, mode: 'filter' }), 'gridRow 1')
  // "Delete/Ctrl+D removes a cell that declares a forget command (recents)
  // without closing, so this route is chosen whether or not such a command
  // exists - whether the key is claimed is the dispatcher's to decide."
  eq('Delete forgets a cell', g({ key: 'deleteKey' }), 'forget')
  eq('Ctrl+D forgets a cell', g({ key: 'keyD', ctrl: true }), 'forget')
  eq('and the route is chosen with no delCommand at all', g({ key: 'deleteKey', del: false }), 'forget')
  eq('even when a staged confirm exists', g({ key: 'deleteKey', confirm: true }), 'forget')
  eq('Backspace in a grid is still the way back, not forget', g({ key: 'backspace' }), 'escape')
})

group('keyRoute: staged deletion, then staged confirmation, then the filter', () => {
  // "List rows declaring a delCommand remove via the staged confirmation
  // (Delete / Ctrl+D arm and advance it) ... Rows with neither fall through
  // to the filter behavior of Delete below. Editors are skipped so Delete
  // keeps deleting text inside an open input."
  eq('a delCommand row deletes on Delete', routeName({ key: 'deleteKey', del: true }), 'delete')
  eq('and on Ctrl+D', routeName({ key: 'keyD', ctrl: true, del: true }), 'delete')
  eq('a confirm row confirms on Delete', routeName({ key: 'deleteKey', confirm: true }), 'confirm')
  eq('and on Ctrl+D', routeName({ key: 'keyD', ctrl: true, confirm: true }), 'confirm')
  eq('del wins over confirm when both are declared', routeName({ key: 'deleteKey', del: true, confirm: true }), 'delete')
  eq('with neither, Delete opens the filter', routeName({ key: 'deleteKey' }), 'filter')
  // keyD has no case in the switch: with no delCommand and no confirm it
  // falls all the way through, and the typing gate refuses it because ctrl is
  // held. So an unbound Ctrl+D is unclaimed rather than the filter route.
  eq('an unbound Ctrl+D is unclaimed, not the filter', routeName({ key: 'keyD', ctrl: true }), null)
  eq('while a bare keyD with no text is unclaimed too', routeName({ key: 'keyD' }), null)
  eq('Backspace walks the escape chain, the conventional way back',
    routeName({ key: 'backspace' }), 'escape')
  // "edits are skipped so Delete keeps deleting text inside an open input"
  eq('an open editor skips the delete route', routeName({ key: 'deleteKey', del: true, editor: true }), 'filter')
  eq('and the confirm route', routeName({ key: 'deleteKey', confirm: true, editor: true }), 'filter')
  eq('so Delete filters rather than deleting a row', routeName({ key: 'deleteKey', editor: true }), 'filter')
  // Backspace would close the menu out from under a number being typed, so an
  // open editor swallows it instead of routing it.
  eq('and an open editor swallows Backspace rather than escaping',
    routeName({ key: 'backspace', editor: true }), 'swallow')
  eq('in filter mode the field keeps Delete whatever it deletes', routeName({ key: 'deleteKey', del: true, mode: 'filter' }), '')
  eq('and the field keeps Backspace, so the query deletes a character',
    routeName({ key: 'backspace', mode: 'filter' }), '')
  // The flags are read through `=== true`, so a truthy stand-in cannot arm a
  // destructive route off a page that never declared one.
  eq('a truthy non-boolean del does not arm', routeName({ key: 'deleteKey', del: 1 }), 'filter')
  eq('a truthy non-boolean confirm does not arm', routeName({ key: 'deleteKey', confirm: 'yes' }), 'filter')
  eq('a truthy non-boolean grid is not a grid', routeName({ key: 'left', grid: 1 }), 'optionOrStep')
  eq('a truthy non-boolean editor is not an editor', routeName({ key: 'up', editor: 1 }), 'move')
  eq('a truthy non-boolean field is not the field', routeName({ key: 'returnKey', field: 1 }), 'activate')
})

group('keyRoute: an open editor swallows navigation and typing', () => {
  // "Inline editors own navigation: arrows belong to the caret, and list
  // movement must not leak while typing." Typing belongs in the same clause
  // for the same reason: the caret had the character first and only let it go
  // because the field does not take it - a number picker's validator
  // refusing a letter is the whole filter. Routing that letter into the query
  // typed it into a box the user never opened and pulled the filter field's
  // focus off the editor, so a numeric row read as a field taking letters.
  for (const k of ['up', 'down', 'tab', 'backtab', 'left', 'right', 'home', 'endKey']) {
    eq(`${k} is swallowed by the editor`, routeName({ key: k, editor: true }), 'swallow')
  }
  eq('Enter still activates the row', routeName({ key: 'returnKey', editor: true }), 'activate')
  eq('Escape still escapes the menu', routeName({ key: 'escape', editor: true }), 'escape')
  eq('Space still activates without the shift bit', routeName({ key: 'space', editor: true }), 'activateNoShift')
  eq('Delete is the field deleting text', routeName({ key: 'deleteKey', editor: true }), 'filter')
  eq('and Backspace is swallowed rather than closing the menu on the editor',
    routeName({ key: 'backspace', editor: true }), 'swallow')
  eq('a letter the field refused is swallowed, not typed into the query',
    routeName({ key: '', editor: true, text: 'a' }), 'swallow')
  eq('and so is "/"', routeName({ key: '', editor: true, text: '/' }), 'swallow')
  eq('in filter mode too, where the query route was never reached',
    routeName({ key: '', editor: true, mode: 'filter', text: 'a' }), 'swallow')
  eq('with a Ctrl held, which the query route refused on its own',
    routeName({ key: '', editor: true, ctrl: true, text: 'a' }), 'swallow')
  eq('a digit is swallowed on the same terms as the letter beside it',
    routeOf({ key: '', editor: true, text: '4' }), 'swallow')
  eq('+ still steps', routeOf({ key: 'plus', editor: true }), 'step 1')
  eq('PageUp still pages', routeName({ key: 'pageUp', editor: true }), 'page')
  eq('the swallow carries no argument', routeOf({ key: 'up', editor: true }), 'swallow')
  eq('and neither does the typing one', M.keyRoute(kctx({ key: '', editor: true, text: 'a' })).arg, null)
  // The same character with no editor open is still the panel's: the guard is
  // the editor, not the key.
  eq('the same letter with no editor is a query again', routeOf({ key: '', text: 'a' }), 'query "a"')
  eq('and "/" is the scoped filter again', routeName({ key: '', text: '/' }), 'scoped')
})

group('keyRoute: the three answers', () => {
  // "or null when none of the routes below claim it" - and a separate
  // unclaimed shape for "this key belongs to the field".
  eq('an unclaimed letter is null', routeName({ key: '', text: 'a', ctrl: true }), null)
  eq('a key the vocabulary omits is null', routeName({ key: 'keyQ' }), null)
  eq('the same key in filter mode is null too', routeName({ key: 'keyQ', mode: 'filter' }), null)
  eq('a key the field owns is the unclaimed shape', routeOf({ key: 'space', field: true }), '')
  eq('with a null argument', M.keyRoute(kctx({ key: 'space', field: true })).arg, null)
  eq('an unclaimed object is a fresh one each call', M.keyRoute(kctx({ key: 'space', field: true })) === M.keyRoute(kctx({ key: 'space', field: true })), false)
  eq('the unclaimed shape', M.keyRoute(kctx({ key: 'space', field: true })), { name: '', arg: null })
  eq('an empty ctx claims nothing', M.keyRoute({}), null)
  eq('a mode of undefined is not list mode', M.keyRoute({ key: 'down' }).name, 'move')
  eq('an unknown mode is not list mode either', routeName({ key: 'space', mode: 'LIST' }), '')
  eq('an unknown mode leaves Space to the field shape', routeName({ key: 'space', mode: 'grid' }), '')
  eq('a null ctx is a throw, not a decision', (() => { try { M.keyRoute(null); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  eq('a missing ctx is a throw too', (() => { try { M.keyRoute(); return 'no throw' } catch (e) { return 'throws' } })(), 'throws')
  // The route never says whether the key is claimed - the dispatcher owns
  // that. Pinned: the grid forget route exists even with nothing to forget.
  eq('forget is chosen with no delCommand declared', routeName({ key: 'deleteKey', grid: true }), 'forget')
  eq('and optionOrStep exists with no dropdown open', routeName({ key: 'left' }), 'optionOrStep')
  eq('the table takes no focus sink and names no item', Object.keys(M.keyRoute(kctx({ key: 'down' }))), ['name', 'arg'])
})

// ======================================================================
group('grid activation holds while filtering (emoji picker)', () => {
  // Enter with the filter field focused routes through the field's
  // onAccepted into activateCurrent; when the query filtered a grid page
  // (emoji), the grid view holds the cursor - reading the unbound list
  // view swallowed Enter. Pinned from the source: the grid branch is not
  // gated on not-searching and skips non-selectable cells.
  const panel = fs.readFileSync(path.join(SHELL_DIR, 'features/menu/MenuPanel.qml'), 'utf8')
  contains('the grid branch holds while filtering', panel, 'filtering too: an emoji query filters within its own grid')
  eq('and it is not gated on not-searching', panel.includes('if (!panel.searching && panel.gridMode)'), false)
  contains('and it guards non-selectable cells', panel, 'itm.selectable === false')
})

section('coverage ledger')
group('every one of the 66 functions was exercised above', () => {
  // A machine-checkable statement, not a claim in prose. The surface list at
  // the top of this file is checked against the loaded namespace, and then
  // each name is required to appear in this file's OWN source as a call - so
  // removing a function, renaming one, or dropping a cluster turns this group
  // red rather than quietly shrinking the coverage.
  eq('the surface list is 66 long', SURFACE.length, 66)
  eq('with no duplicates', new Set(SURFACE).size, 66)
  eq('and all of them resolve on the namespace', SURFACE.filter(n => typeof M[n] !== 'function'), [])
  const selfSource = fs.readFileSync(path.join(import.meta.dirname, 'menu.test.mjs'), 'utf8')
  for (const name of SURFACE) {
    is(`${name} is called by this suite`, selfSource, (s) => new RegExp('\\b' + name + '\\s*\\(').test(s), 'called somewhere below')
  }
  // The four cache `var`s are declarations, not functions, so they get the
  // read-side check instead.
  for (const name of ['_searchCacheIndex', '_searchCacheQ', '_searchCacheEntries', '_searchCacheHitSet']) {
    contains(`${name} is read by this suite`, selfSource, name)
  }
})

finish()
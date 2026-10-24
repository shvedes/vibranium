#!/bin/bash
# Suite: default/vibranium/settings/ - the 30 JSONC files the settings stores
# load at boot, validated by the engine that loads them.
#
# The sibling suites/js/settings.test.mjs drives SettingsLib.js against
# synthetic fixtures and pins every rule it enforces. This one runs the SAME
# library over the REAL catalog on disk, so a rule that is correct in
# isolation cannot be satisfied by a catalog that violates it. Nothing here
# reimplements the engine: the probe loads SettingsLib.js through
# lib/qmlloader.mjs and reports what the real parseOption / parseCatalogDir /
# pruneShowIf / validateValue / validateLayout / validateIdleTimers say, and
# the assertions below are made on those reports.
#
# No Quickshell is started. Paths.qml's four catalog arrays are QML object
# literals, so a node pass lifts each one out (bracket-balanced, comments and
# strings skipped, exactly as boot-catalog-test.sh does for Boot.qml's
# _catalog) and evaluates it against a stub root. The stores are then composed
# the way the three QML stores compose them, namespace derivation included:
#
#   Settings.qml:547-558   misc files not already in shell/env, then
#                          namespaces.push(files[i].indexOf("/misc/") >= 0 ?
#                          "misc" : (files[i].indexOf("/env/") >= 0 ? "env" :
#                          "shell"))
#   MiscSettings.qml:71-84 the same derivation over miscCatalogFiles
#   HyprlandSettings.qml:160  namespaces.push("hypr"), unconditionally
#
# The rules under test, quoted:
#
#   SettingsLib.js:6-8    "Directory decides namespace: shell/* holds only
#                          shell.*, env/* only bare UPPER_SNAKE, hypr/* only
#                          hypr.*, misc/* only misc.*."
#   SettingsLib.js:73     the one cross-namespace exception, SHELL_CROSS_OK
#   SettingsLib.js:285    "Directory decides namespace: the option key must
#                          match the file it was loaded from"
#   SettingsLib.js:568    parseCatalog prunes showIf in strict mode
#   SettingsLib.js:580    "Directory mode keeps unknown refs: stores scan only
#                          their own namespace files, but conditions may point
#                          at another store's keys"
#   SettingsLib.js:606    "Duplicate keys across files are a hard error"
#   SettingsLib.js:617    throw new Error("duplicate option across files: " + k)
#   SettingsLib.js:1301   a submenu item's `page` is a target, so an unknown
#                          one is a menu row that opens nothing
#   Settings.qml:547      the misc/shell overlap that must be filtered out
#                          before the files concatenate, "the catalog treats
#                          duplicate keys across files as a hard error"

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "settings-catalog" "the 30 catalog files on disk, through the real SettingsLib validators"

require_tools node awk sed grep sort paste tr wc cut find

PATHS_QML="$SHELL_DIR/common/Paths.qml"
SETTINGS_DIR="$VIBRANIUM_DIR/default/vibranium/settings"
INDEX_JSONC="$SETTINGS_DIR/_index.jsonc"
SETTINGS_LIB="$SHELL_DIR/common/settings/SettingsLib.js"
SETTINGS_QML="$SHELL_DIR/common/settings/Settings.qml"
MISC_QML="$SHELL_DIR/common/settings/MiscSettings.qml"
HYPR_QML="$SHELL_DIR/common/settings/HyprlandSettings.qml"
LOADER_DIR="$TESTS_SHELL_DIR/lib"

# --------------------------------------------------------------------------
# probe: the real engine over the real files
# --------------------------------------------------------------------------

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vb-settings-catalog.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT

PROBE="$PROBE_DIR/catalog-probe.mjs"
cat >"$PROBE" <<'PROBE_EOF'
// Runs SettingsLib.js over the real catalog and writes one TSV per fact kind
// into $PROBE_OUT. Every record is a fact, never a verdict: the rules live in
// the bash suite, the engine only reports what it parsed.
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const V = process.env.VIBRANIUM_DIR
const OUT = process.env.PROBE_OUT
const LOADER = process.env.QMLLADER

const { loadLib } = await import(pathToFileURL(path.join(LOADER, 'qmlloader.mjs')).href)

const SHELL = path.join(V, 'shell')
const DIR = path.join(V, 'default/vibranium/settings')
const SL = loadLib(path.join(SHELL, 'common/settings/SettingsLib.js'))
const SU = loadLib(path.join(SHELL, 'common/text/StringUtils.js'))

const out = {}
const rec = (file, fields) => {
  const line = fields.map(clean).join('\t')
  out[file] = (out[file] || '') + line + '\n'
}

// A record field is one line of tab-separated text: no tab, no newline, and a
// real value for the empty string so "absent" and "blank" stay distinguishable.
function clean(v) {
  if (v === undefined || v === null) return '-'
  const s = (typeof v === 'string' ? v : String(v)).replace(/[\t\r\n]+/g, ' ').trim()
  return s === '' ? '-' : s
}
const csv = (list) => (list && list.length ? list.map(clean).join(',') : '-')
// The same, for a field an assertion requires to be EMPTY: clean() would turn
// an empty join into "-", which is a value, so those fields bypass it.
const csvEmpty = (list) => (list && list.length ? csv(list) : '')
const j = (v) => (v === undefined ? '-' : JSON.stringify(v))

// A validator that reports success reports it as "". A record field for that
// verdict has to survive the trip, so it is written through a rec() that keeps
// an empty field empty instead of folding it into the absent-value marker.
function recVerdict(file, key, value) {
  const line = key + '\t' + (value === '' ? '' : clean(value))
  out[file] = (out[file] || '') + line + '\n'
}

// --- Paths.qml: lift the four catalog arrays out of the QML source ---------
const pathsSrc = fs.readFileSync(path.join(SHELL, 'common/Paths.qml'), 'utf8')

// The bracket-balanced literal that follows `marker` in `src`, as TEXT. The
// balance skips strings and comments, so a bracket inside either does not
// end the literal early. Null when the marker is absent or the literal is
// unterminated.
function literalText(src, marker) {
  const at = src.indexOf(marker)
  if (at < 0) return null
  const start = src.indexOf('[', at)
  let i = start
  let depth = 0
  let end = -1
  while (i < src.length) {
    const c = src[i]
    if (c === '"' || c === "'") {
      const q = c
      i++
      while (i < src.length) {
        if (src[i] === '\\') { i += 2; continue }
        if (src[i] === q) { i++; break }
        i++
      }
      continue
    }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue }
    if (c === '/' && src[i + 1] === '*') { const close = src.indexOf('*/', i + 2); i = close < 0 ? src.length : close + 2; continue }
    if (c === '[' || c === '(' || c === '{') { depth++; i++; continue }
    if (c === ']' || c === ')' || c === '}') {
      depth--
      if (depth === 0) { end = i; break }
      i++
      continue
    }
    i++
  }
  if (end < 0) return null
  return src.slice(start, end + 1)
}

function literalAfter(marker) {
  const lit = literalText(pathsSrc, marker)
  if (lit === null) return null
  // settingsSchemaDir is the only base the four arrays concatenate onto. A
  // sentinel that cannot occur in a real path keeps the catalog-relative path
  // a pure suffix strip rather than a prefix comparison against the directory
  // under test, which would silently keep every leading "/".
  return new Function('CATALOG', 'return (' + lit.replace(/root\.settingsSchemaDir/g, 'CATALOG') + ')')(STUB)
}

const STUB = '@vibranium-catalog-stub@'
const LISTS = ['shellCatalogFiles', 'envCatalogFiles', 'hyprCatalogFiles', 'miscCatalogFiles']
const rel = (abs) => (abs.indexOf(STUB + '/') === 0 ? abs.slice(STUB.length + 1) : abs)
const lists = {}
for (const name of LISTS) {
  const abs = literalAfter('readonly property var ' + name + ': ')
  if (abs === null) {
    process.stderr.write('no ' + name + ' literal in Paths.qml\n')
    process.exit(1)
  }
  lists[name] = abs.map(rel)
  abs.forEach((a, i) => rec('paths.tsv', [name, i, rel(a)]))
}

// --- namespace derivation, copied from the three stores --------------------
const nsOfPath = (a) => (a.indexOf('/misc/') >= 0 ? 'misc' : (a.indexOf('/env/') >= 0 ? 'env' : 'shell'))
const absOf = (r) => DIR + '/' + r

const miscOnly = lists.miscCatalogFiles.filter(
  (f) => lists.shellCatalogFiles.indexOf(f) < 0 && lists.envCatalogFiles.indexOf(f) < 0)
const settingsFiles = lists.shellCatalogFiles.concat(lists.envCatalogFiles, miscOnly)

// Every distinct file any store loads, in the order Paths.qml names it.
const allFiles = []
for (const name of ['shellCatalogFiles', 'envCatalogFiles', 'hyprCatalogFiles', 'miscCatalogFiles']) {
  for (const f of lists[name]) if (allFiles.indexOf(f) < 0) allFiles.push(f)
}

// A file Paths.qml names but that is not on disk is the regression this suite
// exists to catch, so it is reported as a fact and the suite's own assertions
// fail on it. Crashing here would turn a real defect into a BLOCKED run, which
// is the one classification that must never stand in for a failure.
const textOf = (r) => {
  const p = absOf(r)
  if (!fs.existsSync(p)) return ''
  return fs.readFileSync(p, 'utf8')
}

function compose(files, hardNamespace) {
  const abss = files.map(absOf)
  const namespaces = hardNamespace ? abss.map(() => hardNamespace) : abss.map(nsOfPath)
  return SL.parseCatalogDir(files.map(textOf), namespaces, 250, 'Settings')
}

const stores = {
  settings: () => compose(settingsFiles, null),
  misc: () => compose(lists.miscCatalogFiles, null),
  hypr: () => compose(lists.hyprCatalogFiles, 'hypr'),
}

for (const [name, run] of Object.entries(stores)) {
  const files = name === 'settings' ? settingsFiles
    : name === 'misc' ? lists.miscCatalogFiles : lists.hyprCatalogFiles
  let cat = null
  let threw = ''
  try { cat = run() } catch (e) { threw = String(e.message) }
  if (cat === null) {
    rec('store.tsv', [name, files.length, csv(files), 'threw', threw, '-', '-', '-', '-'])
    continue
  }
  const opts = cat.sections.reduce((a, s) => a + s.options.length, 0)
  const errs = cat.sections.flatMap((s) => (s.errors || []).map((e) => s.page + ': ' + e))
  rec('store.tsv', [name, files.length, csv(files), 'ok', '-', cat.sections.length, opts,
    Object.keys(cat.byKey).length, new Set(cat.sections.map((s) => s.page)).size])
  for (const e of errs) rec('err.tsv', [name, 'parseCatalogDir', e])
}

// The parsed catalogs, once, for the per-file and per-option records. A store
// whose composition throws (a missing file, a cross-file duplicate key) is
// reported as such and contributes no options, so the assertions below fail on
// the store rather than the probe dying.
function safeCompose(name) {
  const empty = { sections: [], pages: [], byKey: {}, rootWidth: 0, rootTitle: '' }
  try {
    return stores[name]()
  } catch (e) {
    return Object.assign({}, empty, { throw: String(e.message) })
  }
}
const S = safeCompose('settings')
const M = safeCompose('misc')
const H = safeCompose('hypr')
for (const [name, cat] of [['settings', S], ['misc', M], ['hypr', H]]) {
  if (cat.throw !== undefined) rec('err.tsv', [name, 'compose', cat.throw])
}

// The option set the shell actually has: the union of the two stores that own
// options of different namespaces. MiscSettings re-parses shell/10-wallpaper
// and its eight options are a subset of the settings store's, so it adds
// nothing and contributes no page (its _adoptCatalog builds a synthetic "misc"
// page it does not publish).
const U = Object.assign({}, S.byKey, H.byKey)

// --- per file -------------------------------------------------------------
// The page list parseCatalogDir builds is the store's files in order, and
// within each file its page objects in order, so the same walk over the raw
// JSONC lines the parsed sections up one-to-one. Re-deriving the file from the
// parsed section instead would be a guess; this is the engine's own order.
function rawPages(f) {
  if (!fs.existsSync(absOf(f))) return []
  const raw = JSON.parse(SU.stripJsonc(textOf(f)))
  return Array.isArray(raw.pages) ? raw.pages
    : (Array.isArray(raw.sections) ? raw.sections : (Array.isArray(raw) ? raw : [raw]))
}

const ownList = (r) => LISTS.filter((n) => lists[n].indexOf(r) >= 0).join('+') || 'unnamed'
for (const f of allFiles) {
  const exists = fs.existsSync(absOf(f))
  let jsonok = 'no'
  let pages = 0
  let opts = 0
  if (exists) {
    try { JSON.parse(SU.stripJsonc(textOf(f))); jsonok = 'yes' } catch (e) { jsonok = 'no' }
    for (const r of rawPages(f)) {
      pages++
      opts += Array.isArray(r.options) ? r.options.length : 0
    }
  }
  rec('file.tsv', [f, ownList(f), exists ? 'yes' : 'no', jsonok, pages, opts,
    exists ? fs.statSync(absOf(f)).size : 0])
}

// --- per file: strict parseCatalog ----------------------------------------
// The legacy single-file parser prunes showIf refs it cannot see, so a clean
// directory file legitimately reports "unknown option" for a condition that
// points into another store. That class is expected here and is checked
// against the union; every OTHER class is a defect in the file.
const UNKNOWN = 'showIf references unknown option'
for (const f of allFiles) {
  if (!fs.existsSync(absOf(f))) {
    rec('err.tsv', [f, 'parseCatalog', 'file is not on disk'])
    continue
  }
  let cat = null
  let threw = ''
  try { cat = SL.parseCatalog(textOf(f)) } catch (e) { threw = String(e.message) }
  if (cat === null) {
    rec('err.tsv', [f, 'parseCatalog', threw])
    continue
  }
  for (const s of cat.sections) {
    for (const e of (s.errors || [])) {
      if (e.indexOf(UNKNOWN) >= 0) {
        const m = /unknown option '([^']+)'/.exec(e)
        rec('ref.tsv', [f, 'strict-unknown', s.page, e.split(':')[0], '-', m ? m[1] : '?', m ? m[1] : '?'])
      } else {
        rec('err.tsv', [f, 'parseCatalog', s.page + ': ' + e])
      }
    }
  }
}

// --- per page -------------------------------------------------------------
const PAGE_FILE = {}
for (const [store, files, cat] of [['settings', settingsFiles, S], ['hypr', lists.hyprCatalogFiles, H], ['misc', lists.miscCatalogFiles, M]]) {
  let at = 0
  for (const f of files) {
    for (let n = 0; n < rawPages(f).length; n++) {
      const s = cat.sections[at++]
      if (s === undefined) break
      PAGE_FILE[store + ' ' + s.page] = f
      rec('page.tsv', [f, store, s.page, s.label, s.icon, s.width, s.showItemCount,
        s.options.length, s.items.length])
    }
  }
  if (at !== cat.sections.length) {
    // A file that is not on disk shortens the walk without the engine
    // producing a section, so the counts diverge here first. Record it and let
    // the suite's own file-level assertions name the missing file, rather than
    // exiting and reporting an unrunnable suite for a real regression.
    rec('err.tsv', [store, 'pageWalk', at + ' raw pages produced ' + cat.sections.length + ' sections'])
  }
}

// --- per option -----------------------------------------------------------
const nsOfKey = (k) => (k.indexOf('hypr.') === 0 ? 'hypr'
  : k.indexOf('misc.') === 0 ? 'misc'
    : k.indexOf('.') >= 0 ? 'shell' : 'env')

for (const [store, cat] of [['settings', S], ['hypr', H]]) {
  for (const sec of cat.sections) {
    const file = PAGE_FILE[store + ' ' + sec.page]
    sec.options.forEach((o, idx) => {
      rec('opt.tsv', [
        file, store, sec.page, idx, o.key, o.type, nsOfKey(o.key),
        o.env ? 'env' : o.hypr ? 'hypr' : o.misc ? 'misc' : 'shell',
        o.visibility, o.hidden ? 'hidden' : 'shown',
        o.values.length, csv(o.values),
        o.valueLabels ? csv(Object.keys(o.valueLabels)) : '-',
        o.valueLabels ? Object.keys(o.valueLabels).length : 0,
        o.valueLabels ? Object.keys(o.valueLabels)
          .filter((k) => typeof o.valueLabels[k] !== 'string' || o.valueLabels[k] === '').length : 0,
        o.min === undefined ? '-' : o.min,
        o.max === undefined ? '-' : o.max,
        o.step, o.unit,
        o.allowEmpty ? 'yes' : 'no',
        o.requires ? (o.requires.chassis || '-') : '-',
        o.requires ? (o.requires.binary || '-') : '-',
        o.showIf ? o.showIf.length : 0,
        j(o.default),
        o.hook || '-',
        o.hypr ? o.hypr.kind : '-',
        o.hypr ? (o.hypr.ctl || '-') : '-',
      ])
    })
    for (const it of (sec.items || [])) {
      rec('item.tsv', [file, sec.page, it && it.type ? it.type : '-',
        it && it.label ? it.label : '-',
        it && it.type === 'submenu' ? (it.page || '-') : '-',
        it && it.when ? 'yes' : 'no',
        it && it.showIf ? it.showIf.length : 0])
    }
  }
}

// --- showIf references, both directions -----------------------------------
for (const [store, cat] of [['settings', S], ['hypr', H]]) {
  for (const sec of cat.sections) {
    const file = PAGE_FILE[store + ' ' + sec.page]
    for (const o of sec.options) {
      if (!o.showIf) continue
      for (const c of o.showIf) {
        rec('ref.tsv', [file, 'option', sec.page, o.key, c.op, j(c.arg), c.var])
      }
    }
    for (const it of (sec.items || [])) {
      if (!it || !it.showIf) continue
      for (const c of it.showIf) {
        rec('ref.tsv', [file, 'item', sec.page, it.label || '-', c.op, j(c.arg), c.var])
      }
    }
  }
}

// Everything below derives further facts from the composed catalogs. A data
// defect that makes one of these throw must surface as a FAILED assertion
// carrying the diagnostic, never as a BLOCKED suite, so the derivation runs
// inside a guard and reports what it could not do.
let derivationFailure = ''
try {
// --- the idle timer list --------------------------------------------------
const idle = U['shell.idle.timers']
if (idle === undefined) {
  rec('scalar.tsv', ['idle.timers.present', 'no'])
} else {
  rec('scalar.tsv', ['idle.timers.present', 'yes'])
  rec('scalar.tsv', ['idle.timers.type', idle.type])
  rec('scalar.tsv', ['idle.timers.visibility', idle.visibility])
  rec('scalar.tsv', ['idle.timers.default', j(idle.default)])
  recVerdict('scalar.tsv', 'idle.timers.validateIdleTimers', SL.validateIdleTimers(idle.default))
  rec('scalar.tsv', ['idle.timers.validateValue.ok', String(SL.validateValue(idle, idle.default).ok)])
  rec('scalar.tsv', ['idle.timers.rows', String(idle.default.length)])
  idle.default.forEach((r, i) => {
    rec('scalar.tsv', ['idle.timers.row' + i + '.minutes', String(r.minutes)])
    rec('scalar.tsv', ['idle.timers.row' + i + '.action', r.action])
    rec('scalar.tsv', ['idle.timers.row' + i + '.command', r.command === undefined ? '-' : r.command])
    rec('scalar.tsv', ['idle.timers.row' + i + '.declared', JSON.stringify(SL.declaredIdleClass(r))])
    rec('scalar.tsv', ['idle.timers.row' + i + '.declaresOwn', String(SL.declaresOwnCommand(r && r.command))])
  })
  const once = SL.normalizeIdleTimers(idle.default)
  const twice = SL.normalizeIdleTimers(once)
  rec('scalar.tsv', ['idle.timers.normalized', j(once)])
  rec('scalar.tsv', ['idle.timers.normalizeIdempotent', String(j(once) === j(twice))])
  recVerdict('scalar.tsv', 'idle.timers.normalizedValid', SL.validateIdleTimers(once))
  rec('scalar.tsv', ['idle.timers.rowsNormalized', j(SL.buildIdleTimerRows(once))])

  // The store's own fallback list - what the daemon arms when a stored list
  // fails validation - is a second spelling of the same default. A
  // disagreement means the timer list a user sees depends on whether their
  // stored config happens to validate, so the two are compared here as the
  // daemon reads them: both normalized, because the catalog ships its
  // classes undeclared and lets the read path fill them.
  const settingsQml = fs.readFileSync(path.join(SHELL, 'common/settings/Settings.qml'), 'utf8')
  const fallbackLit = literalText(settingsQml, 'readonly property var _defaultIdleTimers: ')
  let fallback = null
  if (fallbackLit !== null) {
    try { fallback = new Function('return (' + fallbackLit + ')')() } catch (e) { fallback = null }
  }
  rec('scalar.tsv', ['idle.timers.fallbackPresent', fallback === null ? 'no' : 'yes'])
  rec('scalar.tsv', ['idle.timers.fallback', fallback === null ? '-' : j(fallback)])
  if (fallback !== null) {
    rec('scalar.tsv', ['idle.timers.fallbackNormalized', j(SL.normalizeIdleTimers(fallback))])
    rec('scalar.tsv', ['idle.timers.fallbackMatchesCatalog',
      String(j(SL.normalizeIdleTimers(fallback)) === j(once))])
    recVerdict('scalar.tsv', 'idle.timers.fallbackValid', SL.validateIdleTimers(fallback))
  }
}

// --- the bar layout -------------------------------------------------------
for (const k of Object.keys(U)) {
  if (U[k].type !== 'layout') continue
  const res = SL.validateLayout(U[k].default)
  rec('scalar.tsv', ['layout.key', k])
  recVerdict('scalar.tsv', 'layout.error', res.error === undefined ? '' : res.error)
  const zones = res.value === undefined ? {} : res.value
  rec('scalar.tsv', ['layout.count', String(Object.keys(U).filter((x) => U[x].type === 'layout').length)])
  for (const z of ['left', 'center', 'right', 'disabled']) {
    rec('scalar.tsv', ['layout.' + z, csv(zones[z])])
  }
}

// --- the generated menu bundle --------------------------------------------
const schema = SL.buildSchema(S.pages.concat(H.pages), 250, 'Settings')
const values = {}
for (const k of Object.keys(U)) values[k] = U[k].default
const bundle = SL.buildBundle(schema, values)
const childPages = new Set()
for (const p of S.pages.concat(H.pages)) {
  for (const it of (p.items || [])) {
    if (it && it.type === 'submenu' && typeof it.page === 'string' && it.page !== '') childPages.add(it.page)
  }
}
const index = bundle.pages[0]
rec('scalar.tsv', ['bundle.pages', String(bundle.pages.length)])
rec('scalar.tsv', ['bundle.indexId', index.id])
rec('scalar.tsv', ['bundle.indexTitle', index.title])
rec('scalar.tsv', ['bundle.indexWidth', index.width === undefined ? '-' : String(index.width)])
rec('scalar.tsv', ['bundle.indexItems', String(index.items.length)])
rec('scalar.tsv', ['bundle.childPages', String(childPages.size)])
const inBundle = new Set()
for (const p of bundle.pages) {
  inBundle.add(p.id)
  rec('bundle.tsv', [p.id, p.title, p.width === undefined ? '-' : p.width, p.items.length, p === index ? 'index' : 'page'])
}
const catalogPages = S.pages.concat(H.pages).map((p) => p.page)
for (const id of catalogPages) {
  rec('scalar.tsv', ['bundle.has.' + id, inBundle.has(id) ? 'yes' : 'no'])
}
for (const id of inBundle) {
  if (catalogPages.indexOf(id) < 0) rec('scalar.tsv', ['bundle.extra.' + id, 'yes'])
}

// --- the bash env projection ----------------------------------------------
const envText = SL.renderEnv(schema, values)
const envLines = envText.split('\n').filter((l) => l.indexOf('=') >= 0)
rec('scalar.tsv', ['env.lines', String(envLines.length)])
rec('scalar.tsv', ['env.header', envLines.length > 0 ? envText.split('\n')[0] : ''])
envLines.forEach((l, i) => rec('env.tsv', [i, l]))
rec('scalar.tsv', ['env.expected', String(Object.keys(U).filter((k) => U[k].env).length)])

// --- determinism ----------------------------------------------------------
const sig = (v) => JSON.stringify(v)
rec('scalar.tsv', ['stable.parseCatalogDir', String(sig(stores.settings()) === sig(stores.settings()))])

// --- _index.jsonc ---------------------------------------------------------
const idx = JSON.parse(SU.stripJsonc(fs.readFileSync(path.join(DIR, '_index.jsonc'), 'utf8')))
rec('scalar.tsv', ['index.width', String(idx.width)])
rec('scalar.tsv', ['index.title', idx.title])
rec('scalar.tsv', ['index.keys', csv(Object.keys(idx))])

// --- requires, the closed guard vocabulary --------------------------------
const reqCsv = []
for (const sec of S.pages.concat(H.pages)) {
  for (const o of sec.options) {
    if (!o.requires) continue
    reqCsv.push(sec.page + '/' + o.key + '=' + (o.requires.chassis || '-') + '/' + (o.requires.binary || '-'))
  }
}
rec('scalar.tsv', ['requires.count', String(reqCsv.length)])
rec('scalar.tsv', ['requires.rows', csv(reqCsv)])

// --- icons the pages and items name ---------------------------------------
const iconNames = new Set()
for (const sec of S.pages.concat(H.pages)) {
  if (sec.icon) iconNames.add(sec.icon)
  for (const it of (sec.items || [])) if (it && it.icon) iconNames.add(it.icon)
}
const iconDir = path.join(SHELL, 'assets/icons')
const walk = (d) => {
  const acc = []
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (e.isDirectory()) acc.push(...walk(path.join(d, e.name)))
    else if (e.name.endsWith('.svg')) acc.push(e.name.slice(0, -4))
  }
  return acc
}
const shipped = new Set(walk(iconDir))
rec('scalar.tsv', ['icons.shipped', String(shipped.size)])
const missing = [...iconNames].filter((n) => !shipped.has(n)).sort()
rec('scalar.tsv', ['icons.referenced', String(iconNames.size)])
rec('scalar.tsv', ['icons.missingCount', String(missing.length)])
rec('scalar.tsv', ['icons.missing', csv(missing)])
} catch (e) {
  derivationFailure = String(e && e.message ? e.message : e)
}
recVerdict('scalar.tsv', 'probe.derivationFailure', derivationFailure)

// Every record kind is written even when it is empty, so a reader can tell a
// clean result from a file that was never produced.
const KINDS = ['paths.tsv', 'file.tsv', 'err.tsv', 'page.tsv', 'opt.tsv', 'ref.tsv',
  'item.tsv', 'store.tsv', 'bundle.tsv', 'env.tsv', 'scalar.tsv']
for (const name of KINDS) fs.writeFileSync(path.join(OUT, name), out[name] || '')
process.stdout.write('ok\n')
PROBE_EOF

if ! VIBRANIUM_DIR="$VIBRANIUM_DIR" PROBE_OUT="$PROBE_DIR" QMLLADER="$LOADER_DIR" \
  node "$PROBE" >"$PROBE_DIR/stdout" 2>"$PROBE_DIR/stderr"; then
  t_block "the catalog probe could not run: $(tr '\n' ' ' <"$PROBE_DIR/stderr")"
fi

t_section "the sources this suite reads, and the rules it holds the data to"
t_file "Paths.qml" "$PATHS_QML"
t_file "SettingsLib.js" "$SETTINGS_LIB"
t_file "Settings.qml" "$SETTINGS_QML"
t_file "MiscSettings.qml" "$MISC_QML"
t_file "HyprlandSettings.qml" "$HYPR_QML"
t_file "_index.jsonc" "$INDEX_JSONC"
t_eq "the probe wrote no diagnostics" "" "$(tr '\n' ' ' <"$PROBE_DIR/stderr")"
t_eq "the probe reported success" "ok" "$(tr -d '\n' <"$PROBE_DIR/stdout")"

# The engine's own vocabulary, read back out of the source, so the assertions
# below cannot drift away from the code that enforces them.
t_match "TYPES is the six first-class types" \
  'bool: true' "$(grep -m1 '^  bool: true' "$SETTINGS_LIB")"
t_contains "VISIBILITY is the three-row taxonomy" \
  "const VISIBILITY = { visible: true, hidden: true, internal: true }" \
  "$(grep -m1 '^const VISIBILITY' "$SETTINGS_LIB")"
t_contains "SHELL_CROSS_OK is the one cross-namespace exception" \
  'const SHELL_CROSS_OK = { APP_LAUNCHER_ALWAYS_FOCUS: true, PLAYER_FADE_DURATION: true, "misc.cursorTheme": true, "misc.cursorSize": true }' \
  "$(grep -m1 '^const SHELL_CROSS_OK' "$SETTINGS_LIB")"
t_match "a cross-file duplicate key is a hard error" \
  'throw new Error\("duplicate option across files: "' \
  "$(grep -m1 'duplicate option across files' "$SETTINGS_LIB")"
t_match "directory mode keeps unknown showIf refs" \
  'pruneShowIf\(sections, byKey, false\)' \
  "$(grep -m1 'pruneShowIf(sections, byKey, false)' "$SETTINGS_LIB")"
t_match "single-file mode prunes them" \
  'pruneShowIf\(sections, byKey, true\)' \
  "$(grep -m1 'pruneShowIf(sections, byKey, true)' "$SETTINGS_LIB")"
t_match "the idle class set is closed" \
  'const IDLE_CLASSES = \["", "lock", "suspend"\]' \
  "$(grep -m1 '^const IDLE_CLASSES' "$SETTINGS_LIB")"
t_match "the settings store dedupes misc against shell and env" \
  'Paths\.miscCatalogFiles\.filter' \
  "$(grep -m1 'miscCatalogFiles.filter' "$SETTINGS_QML")"
t_contains "the misc store derives the same namespaces" \
  'files[i].indexOf("/misc/") >= 0 ? "misc" : (files[i].indexOf("/env/") >= 0 ? "env" : "shell")' \
  "$(grep -m1 'indexOf("/misc/")' "$MISC_QML")"
t_match "the hypr store pins every file to the hypr namespace" \
  'namespaces\.push\("hypr"\)' \
  "$(grep -m1 'namespaces.push("hypr")' "$HYPR_QML")"

# --------------------------------------------------------------------------
# records
# --------------------------------------------------------------------------

declare -A SVAL=()
while IFS=$'\t' read -r s_key s_val; do
  SVAL["$s_key"]="$s_val"
done <"$PROBE_DIR/scalar.tsv"

# sval <key> - one scalar fact. An absent key and a fact whose value IS the
# empty string are different answers, so the lookup tests presence, not value.
sval() {
  if [[ -z ${SVAL[$1]+set} ]]; then
    printf '%s' "<unset:${1}>"
  else
    printf '%s' "${SVAL[$1]}"
  fi
}

# Read through sval, so it sits below the helper's own definition: bash does
# not hoist function definitions, so a call ahead of the definition expands to
# nothing and leaves its assertion comparing "" against "".
t_eq "and every fact it derived from the composed catalog" "" "$(sval probe.derivationFailure)"

P_LIST=()
P_IDX=()
P_REL=()
while IFS=$'\t' read -r p_list p_idx p_rel; do
  P_LIST+=("$p_list")
  P_IDX+=("$p_idx")
  P_REL+=("$p_rel")
done <"$PROBE_DIR/paths.tsv"

F_REL=()
F_OWN=()
F_EXISTS=()
F_JSON=()
F_PAGES=()
F_OPTS=()
F_BYTES=()
while IFS=$'\t' read -r f_rel f_own f_exists f_json f_pages f_opts f_bytes; do
  F_REL+=("$f_rel")
  F_OWN+=("$f_own")
  F_EXISTS+=("$f_exists")
  F_JSON+=("$f_json")
  F_PAGES+=("$f_pages")
  F_OPTS+=("$f_opts")
  F_BYTES+=("$f_bytes")
done <"$PROBE_DIR/file.tsv"

E_WHO=()
E_STAGE=()
E_MSG=()
while IFS=$'\t' read -r e_who e_stage e_msg; do
  E_WHO+=("$e_who")
  E_STAGE+=("$e_stage")
  E_MSG+=("$e_msg")
done <"$PROBE_DIR/err.tsv"

G_PAGE=()
G_FILE=()
G_STORE=()
G_LABEL=()
G_ICON=()
G_COUNT=()
G_OPTS=()
G_ITEMS=()
while IFS=$'\t' read -r g_file g_store g_page g_label g_icon _ g_count g_opts g_items; do
  G_FILE+=("$g_file")
  G_STORE+=("$g_store")
  G_PAGE+=("$g_page")
  G_LABEL+=("$g_label")
  G_ICON+=("$g_icon")
  G_COUNT+=("$g_count")
  G_OPTS+=("$g_opts")
  G_ITEMS+=("$g_items")
done <"$PROBE_DIR/page.tsv"

O_FILE=()
O_STORE=()
O_PAGE=()
O_IDX=()
O_KEY=()
O_TYPE=()
O_KEYNS=()
O_ENGNS=()
O_VIS=()
O_SHOWN=()
O_NVAL=()
O_VALUES=()
O_VLKEYS=()
O_VLN=()
O_VLBAD=()
O_MIN=()
O_MAX=()
O_STEP=()
O_UNIT=()
O_EMPTY=()
O_CHASSIS=()
O_BINARY=()
O_SHOWIF=()
O_DEFAULT=()
O_HOOK=()
O_HYPRKIND=()
O_HYPRCTL=()
while IFS=$'\t' read -r o_file o_store o_page o_idx o_key o_type o_keyns o_engns o_vis o_shown \
  o_nval o_values o_vlkeys o_vln o_vlbad o_min o_max o_step o_unit o_empty o_chassis o_binary \
  o_showif o_default o_hook o_hyprkind o_hyprctl; do
  O_FILE+=("$o_file")
  O_STORE+=("$o_store")
  O_PAGE+=("$o_page")
  O_IDX+=("$o_idx")
  O_KEY+=("$o_key")
  O_TYPE+=("$o_type")
  O_KEYNS+=("$o_keyns")
  O_ENGNS+=("$o_engns")
  O_VIS+=("$o_vis")
  O_SHOWN+=("$o_shown")
  O_NVAL+=("$o_nval")
  O_VALUES+=("$o_values")
  O_VLKEYS+=("$o_vlkeys")
  O_VLN+=("$o_vln")
  O_VLBAD+=("$o_vlbad")
  O_MIN+=("$o_min")
  O_MAX+=("$o_max")
  O_STEP+=("$o_step")
  O_UNIT+=("$o_unit")
  O_EMPTY+=("$o_empty")
  O_CHASSIS+=("$o_chassis")
  O_BINARY+=("$o_binary")
  O_SHOWIF+=("$o_showif")
  O_DEFAULT+=("$o_default")
  O_HOOK+=("$o_hook")
  O_HYPRKIND+=("$o_hyprkind")
  O_HYPRCTL+=("$o_hyprctl")
done <"$PROBE_DIR/opt.tsv"

R_FILE=()
R_KIND=()
R_PAGE=()
R_SRC=()
R_OP=()
R_ARG=()
R_TARGET=()
while IFS=$'\t' read -r r_file r_kind r_page r_src r_op r_arg r_target; do
  R_FILE+=("$r_file")
  R_KIND+=("$r_kind")
  R_PAGE+=("$r_page")
  R_SRC+=("$r_src")
  R_OP+=("$r_op")
  R_ARG+=("$r_arg")
  R_TARGET+=("$r_target")
done <"$PROBE_DIR/ref.tsv"

I_FILE=()
I_PAGE=()
I_TYPE=()
I_LABEL=()
I_TARGET=()
I_WHEN=()
I_SHOWIF=()
while IFS=$'\t' read -r i_file i_page i_type i_label i_target i_when i_showif; do
  I_FILE+=("$i_file")
  I_PAGE+=("$i_page")
  I_TYPE+=("$i_type")
  I_LABEL+=("$i_label")
  I_TARGET+=("$i_target")
  I_WHEN+=("$i_when")
  I_SHOWIF+=("$i_showif")
done <"$PROBE_DIR/item.tsv"

ST_NAME=()
ST_FILES=()
ST_RESULT=()
ST_ERR=()
ST_PAGES=()
ST_OPTS=()
ST_BYKEY=()
ST_UNIQ=()
while IFS=$'\t' read -r st_name _st_n st_files st_result st_err st_pages st_opts st_bykey st_uniq; do
  ST_NAME+=("$st_name")
  ST_FILES+=("$st_files")
  ST_RESULT+=("$st_result")
  ST_ERR+=("$st_err")
  ST_PAGES+=("$st_pages")
  ST_OPTS+=("$st_opts")
  ST_BYKEY+=("$st_bykey")
  ST_UNIQ+=("$st_uniq")
done <"$PROBE_DIR/store.tsv"

B_ID=()
B_TITLE=()
B_WIDTH=()
B_ITEMS=()
B_KIND=()
while IFS=$'\t' read -r b_id b_title b_width b_items b_kind; do
  B_ID+=("$b_id")
  B_TITLE+=("$b_title")
  B_WIDTH+=("$b_width")
  B_ITEMS+=("$b_items")
  B_KIND+=("$b_kind")
done <"$PROBE_DIR/bundle.tsv"

EN_KEY=()
EN_VAL=()
while IFS=$'\t' read -r en_key en_val; do
  EN_KEY+=("$en_key")
  EN_VAL+=("$en_val")
done <"$PROBE_DIR/env.tsv"

NP="${#P_REL[@]}"
NF="${#F_REL[@]}"
NO="${#O_KEY[@]}"
NR="${#R_TARGET[@]}"
NI="${#I_LABEL[@]}"
NST="${#ST_NAME[@]}"
NB="${#B_ID[@]}"
NEN="${#EN_KEY[@]}"

# Only the two page-owning stores publish pages: MiscSettings.qml:131 folds the
# misc.* options it adopted into one synthetic "misc" page and returns, so the
# "general" page it re-parses from shell/10-wallpaper.jsonc is the same page
# object the Settings store already owns, not a second one.
G_OWNED=()
for ((i = 0; i < ${#G_PAGE[@]}; i++)); do
  if [[ "${G_STORE[$i]}" == "settings" || "${G_STORE[$i]}" == "hypr" ]]; then
    G_OWNED+=("$i")
  fi
done
NG="${#G_OWNED[@]}"

# The option key set, for the referential walk.
declare -A KNOWN=()
for ((i = 0; i < NO; i++)); do
  KNOWN["${O_KEY[$i]}"]="${O_FILE[$i]}"
done

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

store_field() {
  local want="$1" which="$2" i
  for i in "${!ST_NAME[@]}"; do
    [[ "${ST_NAME[$i]}" == "$want" ]] || continue
    case "$which" in
      FILES) printf '%s' "${ST_FILES[$i]}" ;;
      RESULT) printf '%s' "${ST_RESULT[$i]}" ;;
      ERR) printf '%s' "${ST_ERR[$i]}" ;;
      PAGES) printf '%s' "${ST_PAGES[$i]}" ;;
      OPTS) printf '%s' "${ST_OPTS[$i]}" ;;
      BYKEY) printf '%s' "${ST_BYKEY[$i]}" ;;
      UNIQ) printf '%s' "${ST_UNIQ[$i]}" ;;
      *) return 1 ;;
    esac
    return 0
  done
  return 1
}

# paths_named <list> - one catalog-relative path per line, in Paths.qml order.
paths_named() {
  local want="$1" i
  for i in "${!P_LIST[@]}"; do
    [[ "${P_LIST[$i]}" == "$want" ]] && printf '%s\n' "${P_REL[$i]}"
  done
}

# first_missing <list> - the first file the list names that is not on disk, or
# nothing. A catalog file renamed on disk but not in Paths.qml is silent total
# settings loss, and a file named but absent is the same in the other direction.
first_missing() {
  local want="$1" path
  while read -r path; do
    [[ -f "$SETTINGS_DIR/$path" ]] || { printf '%s' "$path"; return 0; }
  done < <(paths_named "$want")
  return 0
}

# first_prefix_inversion <list> - the first adjacent pair whose numeric prefix
# does not increase, which is what a reordered list means for catalog order.
# The prefix is the leading run of digits in the file's basename, which is the
# convention _index.jsonc documents ("File order (numeric prefixes) is catalog
# order").
first_prefix_inversion() {
  local want="$1" prev="" base cur i
  while read -r cur; do
    base="${cur##*/}"
    i=0
    while [[ ${base:i:1} == [0-9] ]]; do i=$((i + 1)); done
    if ((i == 0)); then
      printf '%s has no numeric prefix' "$cur"
      return 0
    fi
    cur="${base:0:i}"
    if [[ -n $prev ]] && ((10#$cur <= 10#$prev)); then
      printf '%s then %s' "$prev" "$cur"
      return 0
    fi
    prev="$cur"
  done < <(paths_named "$want")
  printf 'none'
}

# list_csv <list> - the list's paths as one comma-joined string.
list_csv() {
  paths_named "$1" | LC_ALL=C sort | paste -sd, -
}

# dangling_refs prints one line per showIf condition that names no option, or
# nothing. A condition on nothing hides its row forever and nothing reports it.
dangling_refs() {
  local out="" i
  for ((i = 0; i < NR; i++)); do
    [[ "${R_KIND[$i]}" == "strict-unknown" ]] && continue
    if [[ -z ${KNOWN[${R_TARGET[$i]}]+set} ]]; then
      out+="${R_FILE[$i]} ${R_KIND[$i]} ${R_SRC[$i]} -> ${R_TARGET[$i]}"$'\n'
    fi
    if [[ "${R_TARGET[$i]}" == "${R_SRC[$i]}" ]]; then
      out+="${R_FILE[$i]} self-reference ${R_SRC[$i]}"$'\n'
    fi
  done
  printf '%s' "${out%$'\n'}"
}

# strict_unknown_unresolved prints the strict-mode unknown refs that do NOT
# resolve against the whole catalog, or nothing.
strict_unknown_unresolved() {
  local out="" i
  for ((i = 0; i < NR; i++)); do
    [[ "${R_KIND[$i]}" == "strict-unknown" ]] || continue
    if [[ -z ${KNOWN[${R_TARGET[$i]}]+set} ]]; then
      out+="${R_FILE[$i]} ${R_SRC[$i]} -> ${R_TARGET[$i]}"$'\n'
    fi
  done
  printf '%s' "${out%$'\n'}"
}

# dangling_submenus prints one line per submenu item whose page is no page.
dangling_submenus() {
  local out="" i target
  local -A pages=()
  for ((i = 0; i < NG; i++)); do pages["${G_PAGE[$i]}"]=1; done
  for ((i = 0; i < NI; i++)); do
    [[ "${I_TYPE[$i]}" == "submenu" ]] || continue
    target="${I_TARGET[$i]}"
    if [[ -z ${pages[$target]+set} ]]; then
      out+="${I_FILE[$i]} ${I_PAGE[$i]}/${I_LABEL[$i]} -> $target"$'\n'
    fi
  done
  printf '%s' "${out%$'\n'}"
}

# uncatalogued_files prints the .jsonc files on disk that no list names, other
# than _index.jsonc, which every store reads by its own name.
uncatalogued_files() {
  local f rel out=""
  while read -r f; do
    rel="${f#"$SETTINGS_DIR"/}"
    [[ "$rel" == "_index.jsonc" ]] && continue
    if ! printf '%s\n' "${P_REL[@]}" | grep -qxF -- "$rel"; then
      out+="$rel"$'\n'
    fi
  done < <(find "$SETTINGS_DIR" -type f -name '*.jsonc' | LC_ALL=C sort)
  printf '%s' "${out%$'\n'}"
}

# overlapping_files prints "path=listA+listB" for every file more than one
# Paths.qml list names, or nothing. More than one is only ever a problem the
# engine cannot see, because parseCatalogDir is handed a deduped list.
overlapping_files() {
  local out="" i
  for ((i = 0; i < NF; i++)); do
    [[ "${F_OWN[$i]}" == *+* ]] || continue
    out+="${F_REL[$i]}=${F_OWN[$i]}"$'\n'
  done
  printf '%s' "${out%$'\n'}"
}

# option_namespace <key> - the namespace the key claims, derived here rather
# than read back from the engine: hypr.*, misc.*, any other dotted path is
# shell.*, a bare key is a bash var in the env namespace.
option_namespace() {
  local key="$1"
  if [[ "$key" == hypr.* ]]; then printf 'hypr'
  elif [[ "$key" == misc.* ]]; then printf 'misc'
  elif [[ "$key" == *.* ]]; then printf 'shell'
  else printf 'env'
  fi
}

# file_namespace <path> - the namespace the file's store asserts. Settings.qml
# and MiscSettings.qml derive it from the path they were handed
# (`indexOf("/misc/")`, else `indexOf("/env/")`, else "shell"), and
# HyprlandSettings.qml pins every file of its own list to "hypr" regardless of
# the path, so the answer is a property of the list the file is in, not of the
# path alone.
declare -A FILE_NS=()
for ((i = 0; i < NF; i++)); do
  # The owning lists arrive in Paths.qml declaration order, and a store reads a
  # file under the namespace of the FIRST list that names it: shell/10-wallpaper
  # is in shellCatalogFiles and in miscCatalogFiles, and every store that loads
  # it derives "shell" from the path, because the misc list carries no misc/
  # path at all.
  case "${F_OWN[$i]%%+*}" in
    shellCatalogFiles) FILE_NS["${F_REL[$i]}"]="shell" ;;
    envCatalogFiles) FILE_NS["${F_REL[$i]}"]="env" ;;
    hyprCatalogFiles) FILE_NS["${F_REL[$i]}"]="hypr" ;;
    miscCatalogFiles) FILE_NS["${F_REL[$i]}"]="misc" ;;
    *) FILE_NS["${F_REL[$i]}"]="-" ;;
  esac
done

# The path rule on its own, without the hypr pin, so the derivation and the pin
# can be asserted separately.
file_namespace_path() {
  local path="$1"
  if [[ "$path" == */misc/* ]]; then printf 'misc'
  elif [[ "$path" == */env/* ]]; then printf 'env'
  else printf 'shell'
  fi
}

file_namespace() { printf '%s' "${FILE_NS[$1]:-}"; }

# The documented cross-namespace exceptions, read out of SettingsLib's own
# constant rather than copied, so the list cannot drift away from the code.
cross_ok_keys() {
  sed -n 's/^const SHELL_CROSS_OK = {\(.*\) }$/\1/p' "$SETTINGS_LIB" |
    tr ',' '\n' | sed 's/: true$//' | tr -d ' "' | LC_ALL=C sort | paste -sd' ' -
}

cross_ok_has() {
  local want="$1" k
  for k in $(cross_ok_keys); do
    [[ "$k" == "$want" ]] && return 0
  done
  return 1
}

# enum_violation <index> - why option <index>'s enum is inconsistent, or
# nothing. parseOption already refuses a default outside `values`; what it does
# not check is that every enum member has a valueLabel, that a valueLabel names
# only a member the option lists, or that a label is a non-empty string
# (enumLabel falls back to prettify for anything else, silently).
enum_violation() {
  local i="$1" out="" v lk
  if [[ "${O_NVAL[$i]}" == "0" ]]; then
    if [[ "${O_VLN[$i]}" != "0" ]]; then out="valueLabels with no values"
    elif [[ "${O_VLBAD[$i]}" != "0" ]]; then out="valueLabels with an empty label"
    fi
    printf '%s' "$out"
    return 0
  fi
  local -A listed=()
  for v in ${O_VALUES[$i]//,/ }; do
    [[ -n $v ]] || continue
    if [[ -n ${listed[$v]+set} ]]; then out="$out;duplicate enum value $v"; continue; fi
    listed[$v]=1
  done
  local -A labelled=()
  for lk in ${O_VLKEYS[$i]//,/ }; do
    [[ -n $lk ]] || continue
    if [[ -n ${labelled[$lk]+set} ]]; then out="$out;duplicate valueLabel $lk"; continue; fi
    labelled[$lk]=1
    if [[ -z ${listed[$lk]+set} ]]; then out="$out;valueLabel for unlisted $lk"; fi
  done
  for v in "${!listed[@]}"; do
    [[ -n ${labelled[$v]+set} ]] || out="$out;no valueLabel for $v"
  done
  [[ "${O_VLBAD[$i]}" == "0" ]] || out="$out;${O_VLBAD[$i]} valueLabel(s) not a non-empty string"
  printf '%s' "${out#;}"
}

# range_violation <index> - why the declared bounds are inconsistent, or
# nothing. The engine checks min < max and the default in range; what it does
# not check is that an int option's range and step are whole numbers, or that a
# defaulted range is not left on a bool (already an engine error).
range_violation() {
  local i="$1"
  local out="" min="${O_MIN[$i]}" max="${O_MAX[$i]}" step="${O_STEP[$i]}"
  if [[ "$min" != "-" && "$max" == "-" ]]; then out="min without max"
  elif [[ "$max" != "-" && "$min" == "-" ]]; then out="max without min"
  elif [[ "$min" != "-" && "$max" != "-" ]] && ! awk -v a="$min" -v b="$max" 'BEGIN { exit !(a < b) }'; then
    out="min $min is not < max $max"
  fi
  if [[ "${O_TYPE[$i]}" == "int" && ! "$step" =~ ^[0-9]+$ ]]; then
    out="$out; int step $step is not a whole number"
  fi
  if [[ "$step" != "-" && ! "$step" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    out="$out; step $step is not a positive number"
  fi
  printf '%s' "${out#;}"
}

# off_page_gates prints one line per option gated on a same-store option that
# lives on a different page, or nothing. A cross-store condition is resolved at
# runtime against the merged byKey, so only a same-store cross-page gate is a
# dead row: conditionsMet consults the store's own byKey and the gate's page is
# what decides whether the row is ever reached.
off_page_gates() {
  local out="" i j tgt tstore tpage
  for ((i = 0; i < NO; i++)); do
    [[ "${O_SHOWIF[$i]}" == "0" ]] && continue
    for ((j = 0; j < NO; j++)); do
      [[ "${O_KEY[$j]}" == "${O_KEY[$i]}" ]] && continue
      [[ "${O_STORE[$j]}" == "${O_STORE[$i]}" ]] || continue
      tgt="${O_KEY[$j]}"
      for ((k = 0; k < NR; k++)); do
        [[ "${R_KIND[$k]}" == "option" && "${R_SRC[$k]}" == "${O_KEY[$i]}" ]] || continue
        [[ "${R_TARGET[$k]}" == "$tgt" ]] || continue
        tpage="${O_PAGE[$j]}"
        tstore="${O_STORE[$i]}"
        if [[ "$tpage" != "${O_PAGE[$i]}" ]]; then
          out+="${tstore} ${O_KEY[$i]} (${O_PAGE[$i]}) -> $tgt (${tpage})"$'\n'
        fi
      done
    done
  done
  printf '%s' "${out%$'\n'}" | LC_ALL=C sort -u | awk '!seen[$0]++'
}

# --------------------------------------------------------------------------
# the cross-file contract: Paths.qml and the directory must agree
# --------------------------------------------------------------------------

t_section "the four lists Paths.qml names, and the files behind them"
t_eq "shellCatalogFiles names 13 files" "13" "$(paths_named shellCatalogFiles | wc -l | tr -d ' ')"
t_eq "envCatalogFiles names 2 files" "2" "$(paths_named envCatalogFiles | wc -l | tr -d ' ')"
t_eq "hyprCatalogFiles names 13 files" "13" "$(paths_named hyprCatalogFiles | wc -l | tr -d ' ')"
t_eq "miscCatalogFiles names 1 file" "1" "$(paths_named miscCatalogFiles | wc -l | tr -d ' ')"

MISSING=0
for list in shellCatalogFiles envCatalogFiles hyprCatalogFiles miscCatalogFiles; do
  first="$(first_missing "$list")"
  t_eq "$list: every file it names exists" "" "$first"
  [[ -z $first ]] || MISSING=$((MISSING + 1))
done
t_eq "no list names a file that is missing" "0" "$MISSING"

# The four directory names the catalog is split into. misc/ is the one with no
# file of its own: MiscSettings reads shell/10-wallpaper.jsonc, which is why the
# overlap below exists at all.
t_eq "every named file sits under shell/, env/, hypr/ or misc/" "" \
  "$(printf '%s\n' "${P_REL[@]}" | while read -r p; do
    case "$p" in
      shell/* | env/* | hypr/* | misc/*) ;;
      *) printf '%s ' "$p" ;;
    esac
  done)"
t_eq "the directory the paths split into is exactly the one on disk" \
  "env hypr shell" \
  "$(find "$SETTINGS_DIR" -mindepth 1 -type d -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
t_eq "and no misc/ directory exists, so miscCatalogFiles can only ride a shell file" \
  "no" "$([[ -d "$SETTINGS_DIR/misc" ]] && printf 'yes' || printf 'no')"
# The two derivations differ for exactly one list, and that difference is the
# hypr store's unconditional pin, not a mismatch.
t_eq "the path rule alone agrees with the store's namespace for every non-hypr file" "" \
  "$(for ((i = 0; i < NF; i++)); do
    ns="$(file_namespace "${F_REL[$i]}")"
    [[ "$ns" == "hypr" ]] && continue
    [[ "$ns" == "$(file_namespace_path "/${F_REL[$i]}")" ]] || printf '%s ' "${F_REL[$i]}"
  done)"
t_eq "and the 13 hypr files are exactly the ones the hypr store pins" "13" \
  "$(for ((i = 0; i < NF; i++)); do
    [[ "$(file_namespace "${F_REL[$i]}")" == "hypr" ]] && printf 'x'
  done | wc -c | tr -d ' ')"

UNCAT="$(uncatalogued_files)"
t_eq "every .jsonc on disk is named by a list (or is _index.jsonc)" "" "$UNCAT"
t_note "_index.jsonc is read by all three stores by its own name (Settings.qml:535, MiscSettings.qml:66, HyprlandSettings.qml:146) rather than through a list, so it is the one catalog file no list names"
t_eq "the only file two lists both name is the documented overlap" \
  "shell/10-wallpaper.jsonc=shellCatalogFiles+miscCatalogFiles" \
  "$(overlapping_files)"

t_section "the misc/shell overlap Settings.qml:547 filters out"
t_eq "miscCatalogFiles[0] is shellCatalogFiles[0]" \
  "$(paths_named shellCatalogFiles | head -1)" "$(paths_named miscCatalogFiles)"
t_eq "miscCatalogFiles overlaps shellCatalogFiles exactly once" "1" \
  "$(comm -12 <(paths_named miscCatalogFiles | LC_ALL=C sort) \
    <(paths_named shellCatalogFiles | LC_ALL=C sort) | wc -l | tr -d ' ')"
t_eq "and does not overlap envCatalogFiles" "0" \
  "$(comm -12 <(paths_named miscCatalogFiles | LC_ALL=C sort) \
    <(paths_named envCatalogFiles | LC_ALL=C sort) | wc -l | tr -d ' ')"
t_eq "so the settings store loads 15 files: 13 shell + 2 env + 0 misc-only" "15" \
  "$(store_field settings FILES | tr ',' '\n' | grep -c .)"
t_eq "every file the settings store loads is a file a list named" "" \
  "$(store_field settings FILES | tr ',' '\n' | while read -r p; do
    printf '%s\n' "${P_REL[@]}" | grep -qxF -- "$p" || printf '%s ' "$p"
  done)"

# --------------------------------------------------------------------------
# every file parses under the real engine
# --------------------------------------------------------------------------

t_section "every catalog file parses: real stripJsonc, JSON.parse, real parseCatalogDir"
BADJSON=0
for ((i = 0; i < NF; i++)); do
  t_eq "${F_REL[$i]} is a readable non-empty file" "yes" \
    "$([[ -s "$SETTINGS_DIR/${F_REL[$i]}" ]] && printf 'yes' || printf 'no')"
  t_ne "${F_REL[$i]} is named by at least one list" "unnamed" "${F_OWN[$i]}"
  if [[ "${F_JSON[$i]}" != "yes" ]]; then
    t_eq "${F_REL[$i]} parses as JSONC" "yes" "no"
    BADJSON=$((BADJSON + 1))
  else
    t_eq "${F_REL[$i]} parses as JSONC under the real stripJsonc" "yes" "yes"
  fi
  t_ne "${F_REL[$i]} is not empty of content" "0" "${F_BYTES[$i]}"
  t_ne "${F_REL[$i]} declares at least one page" "0" "${F_PAGES[$i]}"
  t_ne "${F_REL[$i]} contributes at least one option" "0" "${F_OPTS[$i]}"
done
t_eq "no catalog file failed to parse as JSONC" "0" "$BADJSON"
t_eq "the 28 files declare 43 pages between them" "43" \
  "$(for ((i = 0; i < NF; i++)); do printf '%s\n' "${F_PAGES[$i]}"; done |
    awk '{ s += $1 } END { print s + 0 }')"
t_eq "and 197 options" "197" \
  "$(for ((i = 0; i < NF; i++)); do printf '%s\n' "${F_OPTS[$i]}"; done |
    awk '{ s += $1 } END { print s + 0 }')"

t_section "the three stores compose cleanly, in the way the QML stores compose them"
t_eq "Settings.qml's store parses without an error" "ok" "$(store_field settings RESULT)"
t_eq "MiscSettings.qml's store parses without an error" "ok" "$(store_field misc RESULT)"
t_eq "HyprlandSettings.qml's store parses without an error" "ok" "$(store_field hypr RESULT)"
t_eq "and no store recorded a section error" "" \
  "$(for ((i = 0; i < NST; i++)); do [[ "${ST_RESULT[$i]}" == "ok" ]] || printf '%s ' "${ST_NAME[$i]}"; done)"
t_eq "and no store reported an error while claiming to have composed" "" \
  "$(for ((i = 0; i < NST; i++)); do
    [[ "${ST_RESULT[$i]}" == "ok" && "${ST_ERR[$i]}" != "-" ]] && printf '%s:%s ' "${ST_NAME[$i]}" "${ST_ERR[$i]}"
  done)"
t_eq "and the probe's err.tsv is empty: no store and no file reported anything" "0" \
  "$(grep -c . "$PROBE_DIR/err.tsv")"
t_eq "the settings store's 25 pages carry 94 options" "94" "$(store_field settings OPTS)"
t_eq "the hypr store's 18 pages carry 103 options" "103" "$(store_field hypr OPTS)"
t_eq "the misc store's one page carries 10 options" "10" "$(store_field misc OPTS)"
t_eq "every store's page ids are unique" "" \
  "$(for ((i = 0; i < NST; i++)); do
    [[ "${ST_PAGES[$i]}" == "${ST_UNIQ[$i]}" ]] || printf '%s ' "${ST_NAME[$i]}"
  done)"
t_eq "the two page-owning stores together hold 43 unique pages" "43" \
  "$(( $(store_field settings PAGES) + $(store_field hypr PAGES) ))"
t_eq "and the misc store contributes no page of its own" "1" "$(store_field misc PAGES)"
t_note "MiscSettings.qml:131 builds a synthetic page (id \"misc\") from the misc.* options it adopted and publishes only that, so the \"general\" page it re-parses from shell/10-wallpaper.jsonc never reaches a second bundle"

t_section "per-file strict parse: only the cross-store showIf class may report"
UNKNOWN_RESOLVED="$(strict_unknown_unresolved)"
t_eq "every ref the single-file parser could not see resolves in the whole catalog" \
  "" "$UNKNOWN_RESOLVED"
STRICT_N=0
for ((i = 0; i < NR; i++)); do
  [[ "${R_KIND[$i]}" == "strict-unknown" ]] && STRICT_N=$((STRICT_N + 1))
done
t_note "$STRICT_N showIf conditions name an option in another store (hypr.*), which is what parseCatalogDir's non-strict mode (SettingsLib.js:631) exists to keep; single-file parseCatalog prunes them with a warning, which is the documented behaviour, not a defect"
t_ne "and that class is non-empty, so the check above is not vacuous" "0" "$STRICT_N"

# --------------------------------------------------------------------------
# options, one at a time
# --------------------------------------------------------------------------

t_section "every option: type, namespace and the engine's own verdict"
t_eq "the catalog declares 197 options across the two page-owning stores" "197" "$NO"
declare -A TYPE_COUNT=()
declare -A NS_COUNT=()
declare -A VIS_COUNT=()
for ((i = 0; i < NO; i++)); do
  key="${O_KEY[$i]}"
  at="${O_FILE[$i]} ${O_PAGE[$i]}#$(( ${O_IDX[$i]} + 1 )) $key"
  TYPE_COUNT["${O_TYPE[$i]}"]=$(( ${TYPE_COUNT[${O_TYPE[$i]}]:-0} + 1 ))
  NS_COUNT["${O_KEYNS[$i]}"]=$(( ${NS_COUNT[${O_KEYNS[$i]}]:-0} + 1 ))
  VIS_COUNT["${O_VIS[$i]}"]=$(( ${VIS_COUNT[${O_VIS[$i]}]:-0} + 1 ))

  t_match "$at has a type the engine declares" \
    '^(bool|int|float|string|layout|timers)$' "${O_TYPE[$i]}"
  t_eq "$at derives the namespace its key claims" "$(option_namespace "$key")" "${O_KEYNS[$i]}"
  t_eq "$at and the engine agree on that namespace" "${O_KEYNS[$i]}" "${O_ENGNS[$i]}"
  t_match "$at has one of the three visibilities" \
    '^(visible|hidden|internal)$' "${O_VIS[$i]}"
  if [[ "${O_KEYNS[$i]}" == "$(file_namespace "${O_FILE[$i]}")" ]]; then
    t_eq "$at sits in a file whose store asserts its key's namespace" "match" "match"
  elif cross_ok_has "$key"; then
    t_eq "$at rides a shell page as one of the four documented exceptions" "documented" "documented"
  else
    t_eq "$at sits in a file whose store asserts its key's namespace" "match" "mismatch"
  fi
  case "${O_TYPE[$i]}" in
    layout | timers)
      t_eq "$at is internal-only, never a rendered row" "internal" "${O_VIS[$i]}"
      t_eq "$at is not a rendered row" "hidden" "${O_SHOWN[$i]}" ;;
  esac
done

t_note "type distribution: $(for t in "${!TYPE_COUNT[@]}"; do printf '%s=%s ' "$t" "${TYPE_COUNT[$t]}"; done | LC_ALL=C tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
t_note "namespace distribution: $(for n in "${!NS_COUNT[@]}"; do printf '%s=%s ' "$n" "${NS_COUNT[$n]}"; done | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
t_note "visibility distribution: $(for v in "${!VIS_COUNT[@]}"; do printf '%s=%s ' "$v" "${VIS_COUNT[$v]}"; done | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"

RIDERS=""
for ((i = 0; i < NO; i++)); do
  key="${O_KEY[$i]}"
  if [[ "${O_KEYNS[$i]}" != "$(file_namespace "${O_FILE[$i]}")" ]]; then
    RIDERS="$RIDERS$key "
  fi
done
t_eq "the cross-namespace riders are exactly SHELL_CROSS_OK's four keys" \
  "$(printf '%s\n' $RIDERS | LC_ALL=C sort | paste -sd' ' -)" \
  "$(cross_ok_keys)"

t_section "enum members and their valueLabels"
ENUM_N=0
for ((i = 0; i < NO; i++)); do
  bad="$(enum_violation "$i")"
  if [[ "${O_NVAL[$i]}" == "0" ]]; then
    t_eq "${O_KEY[$i]} declares no label for a free value" "" "$bad"
  else
    ENUM_N=$((ENUM_N + 1))
    t_eq "${O_KEY[$i]}'s enum and its valueLabels agree" "" "$bad"
  fi
done
t_note "$ENUM_N of $NO options are enums; the other $((NO - ENUM_N)) are bool, a bounded number, or one of the two first-class object types"

t_section "ranges and steps"
for ((i = 0; i < NO; i++)); do
  bad="$(range_violation "$i")"
  if [[ "${O_MIN[$i]}" == "-" && "${O_MAX[$i]}" == "-" ]]; then
    t_eq "${O_KEY[$i]} declares a whole range or none" "" "$bad"
  else
    t_eq "${O_KEY[$i]}'s range is a whole, ordered pair" "" "$bad"
  fi
done
t_eq "the two first-class types are the only unbounded-number types" "" \
  "$(for ((i = 0; i < NO; i++)); do
    [[ "${O_TYPE[$i]}" == "bool" && "${O_MIN[$i]}" != "-" ]] && printf '%s ' "${O_KEY[$i]}"
  done)"

t_section "the requires guard, against the closed vocabulary SettingsLib translates to"
t_match "the engine accepts exactly two requires fields" \
  'raw\.requires\.chassis !== undefined' "$(grep -m1 'raw\.requires\.chassis !== undefined' "$SETTINGS_LIB")"
t_match "and requires.binary" \
  'raw\.requires\.binary !== undefined' "$(grep -m1 'raw\.requires\.binary !== undefined' "$SETTINGS_LIB")"
t_eq "the vocabulary the legacy \`when\` translation produces for requires.chassis" \
  '!vm laptop' \
  "$(grep -o 'requires = { chassis: "[^"]*" }' "$SETTINGS_LIB" |
    sed 's/.*chassis: "\([^"]*\)".*/\1/' | LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "and it produces exactly one value for requires.binary" \
  'wiremix' \
  "$(grep -o 'requires = { binary: "[^"]*" }' "$SETTINGS_LIB" |
    sed 's/.*binary: "\([^"]*\)".*/\1/' | LC_ALL=C sort -u | paste -sd' ' -)"
t_eq "the catalog declares 4 guarded options" "4" "$(sval requires.count)"
t_eq "and they are exactly these" \
  "night-light/shell.nightLight.enabled=!vm/- night-light/shell.statusbar.nightLightTemperature=!vm/- power/shell.power.acProfile=laptop/- power/shell.power.batteryProfile=laptop/-" \
  "$(sval requires.rows | tr ',' '\n' | LC_ALL=C sort | paste -sd' ' -)"
BADREQ=""
for ((i = 0; i < NO; i++)); do
  if [[ "${O_CHASSIS[$i]}" != "-" && "${O_CHASSIS[$i]}" != "laptop" && "${O_CHASSIS[$i]}" != "!vm" ]]; then
    BADREQ="$BADREQ${O_KEY[$i]}:chassis=${O_CHASSIS[$i]} "
  fi
  if [[ "${O_BINARY[$i]}" != "-" ]]; then
    BADREQ="$BADREQ${O_KEY[$i]}:binary=${O_BINARY[$i]} "
  fi
done
t_eq "every guard names a value from the closed vocabulary" "" "$BADREQ"
t_note "the third requires field, requires.binary, is declared by the engine (SettingsLib.js:366) and by the wiremix translation (:376) but used by no option in the catalog: no row is gated on a program being installed"

# --------------------------------------------------------------------------
# referential integrity
# --------------------------------------------------------------------------

t_section "referential integrity: every showIf names a real option"
LIVE_N=0
for ((i = 0; i < NR; i++)); do
  [[ "${R_KIND[$i]}" == "strict-unknown" ]] && continue
  LIVE_N=$((LIVE_N + 1))
done
t_eq "the catalog holds 43 live showIf conditions across options and raw items" "43" "$LIVE_N"
t_ne "and there is at least one, so the check is not vacuous" "0" "$LIVE_N"
t_eq "no condition names an option that does not exist, and none is a self-reference" \
  "" "$(dangling_refs)"
SELF_N=0
for ((i = 0; i < NR; i++)); do
  [[ "${R_KIND[$i]}" == "strict-unknown" ]] && continue
  [[ "${R_TARGET[$i]}" != "${R_SRC[$i]}" ]] || SELF_N=$((SELF_N + 1))
done
t_eq "no condition references the key it gates" "0" "$SELF_N"
t_contains "and the engine drops a self-reference unconditionally" \
  'if (k === opt.key)' "$(grep -m1 'if (k === opt.key)' "$SETTINGS_LIB")"
BADOP=""
BADARG=""
for ((i = 0; i < NR; i++)); do
  [[ "${R_KIND[$i]}" == "strict-unknown" ]] && continue
  t_match "${R_FILE[$i]} ${R_KIND[$i]} ${R_SRC[$i]} uses one of eq | neq | in" \
    '^(eq|neq|in)$' "${R_OP[$i]}"
  case "${R_OP[$i]}" in
    in)
      t_match "${R_FILE[$i]} ${R_KIND[$i]} ${R_SRC[$i]}'s in argument is a JSON array" \
        '^\[.*\]$' "${R_ARG[$i]}" ;;
    *)
      t_not_match "${R_FILE[$i]} ${R_KIND[$i]} ${R_SRC[$i]}'s argument is a scalar" \
        '^\[.*\]$' "${R_ARG[$i]}" ;;
  esac
  if [[ "${R_OP[$i]}" != "eq" && "${R_OP[$i]}" != "neq" && "${R_OP[$i]}" != "in" ]]; then
    BADOP="$BADOP${R_KIND[$i]}:${R_SRC[$i]}:${R_OP[$i]} "
  fi
  if [[ "${R_ARG[$i]}" != "true" && "${R_ARG[$i]}" != "false" && "${R_ARG[$i]}" != "null" \
    && ! "${R_ARG[$i]}" =~ ^-?[0-9]+(\.[0-9]+)?$ && "${R_ARG[$i]}" != "["* \
    && ! "${R_ARG[$i]}" =~ ^\"[^\"]*\"$ ]]; then
    BADARG="$BADARG${R_SRC[$i]}:${R_ARG[$i]} "
  fi
done
t_eq "every condition's operator is legal" "" "$BADOP"
t_eq "and every argument is a scalar or a JSON array" "" "$BADARG"

# Which options each condition keys on, and from which file.
CROSSTORE=""
for ((i = 0; i < NR; i++)); do
  [[ "${R_KIND[$i]}" == "strict-unknown" ]] && continue
  tgt="${R_TARGET[$i]}"
  [[ -n ${KNOWN[$tgt]+set} ]] || continue
  if [[ "${KNOWN[$tgt]}" != "${R_FILE[$i]}" ]]; then
    CROSSTORE="$CROSSTORE${R_SRC[$i]} -> $tgt"$'\n'
  fi
done
CROSS_CSV="$(printf '%s' "$CROSSTORE" | LC_ALL=C sort -u | paste -sd, -)"
t_note "the cross-file showIf graph, which is what pruneShowIf's non-strict directory mode exists for: $CROSS_CSV"
t_ne "and it is non-empty, so cross-file conditions are exercised" "" "$CROSS_CSV"

t_eq "no option is gated on a same-store option that lives on a different page" \
  "" "$(off_page_gates)"
t_note "a same-store condition across pages is a dead row: conditionsMet is evaluated against the store's own byKey, so a row on one page gated by an option on another is a menu entry whose visibility the user can never turn on from that page"

t_section "referential integrity: every submenu names a real page"
SUBMENUS=0
for ((i = 0; i < NI; i++)); do
  [[ "${I_TYPE[$i]}" == "submenu" ]] || continue
  SUBMENUS=$((SUBMENUS + 1))
  t_ne "${I_PAGE[$i]}/${I_LABEL[$i]} names a submenu target" "-" "${I_TARGET[$i]}"
  t_match "${I_PAGE[$i]}/${I_LABEL[$i]}'s target is a page id" \
    '^[a-z0-9_-]+$' "${I_TARGET[$i]}"
done
t_eq "the catalog declares 28 submenus" "28" "$SUBMENUS"
t_eq "all $SUBMENUS submenus resolve" "" "$(dangling_submenus)"

t_section "raw items: only raw items carry free bash"
WHEN_N=0
for ((i = 0; i < NI; i++)); do
  t_match "${I_PAGE[$i]}/${I_LABEL[$i]} is a type the menu accepts" \
    '^(action|submenu|toggle|separator|slider|input|checkbox|passthrough)$' "${I_TYPE[$i]}"
  if [[ "${I_WHEN[$i]}" == "yes" ]]; then
    WHEN_N=$((WHEN_N + 1))
    t_eq "${I_PAGE[$i]}/${I_LABEL[$i]} is a raw item, so its when is free bash by design" \
      "yes" "yes"
  fi
done
t_contains "the engine documents that free bash survives only on raw items" \
  "free bash survives only on raw" \
  "$(grep -m1 'free bash survives only on raw' "$SETTINGS_LIB")"
t_note "$WHEN_N of $NI raw items carry a free bash \`when\` guard, which is the one place the schema lets bash through (SettingsLib.js:353)"
HOOKED=0
for ((i = 0; i < NO; i++)); do
  [[ "${O_HOOK[$i]}" == "-" ]] || HOOKED=$((HOOKED + 1))
done
t_eq "no option in the catalog carries a free bash when" "0" "$HOOKED"
t_eq "and no option declares a commit hook either" "0" "$HOOKED"

# --------------------------------------------------------------------------
# the idle timer list
# --------------------------------------------------------------------------

t_section "the idle timer list, through validateIdleTimers and its two helpers"
t_eq "shell.idle.timers is in the catalog" "yes" "$(sval idle.timers.present)"
t_eq "and is the first-class timers type" "timers" "$(sval idle.timers.type)"
t_eq "internal, so it is never a rendered row" "internal" "$(sval idle.timers.visibility)"
t_eq "it ships 2 timers" "2" "$(sval idle.timers.rows)"
t_eq "validateIdleTimers accepts the shipped list" "" "$(sval idle.timers.validateIdleTimers)"
t_eq "validateValue accepts the shipped list as the option's default" \
  "true" "$(sval idle.timers.validateValue.ok)"
t_eq "the two timers are the project's own session verbs" \
  "10 command vb-shell session lock / 15 command vb-shell session suspend" \
  "$(for ((r = 0; r < 2; r++)); do
    printf '%s %s %s / ' "$(sval "idle.timers.row$r.minutes")" \
      "$(sval "idle.timers.row$r.action")" "$(sval "idle.timers.row$r.command")"
  done | sed -e 's| / $||')"
OWN=0
for ((r = 0; r < 2; r++)); do
  t_eq "timer $r declares no class as shipped" '""' "$(sval "idle.timers.row$r.declared")"
  if [[ "$(sval "idle.timers.row$r.declaresOwn")" == "true" ]]; then
    OWN=$((OWN + 1))
  fi
  t_eq "timer $r is a command declaresOwnCommand recognises" "true" \
    "$(sval "idle.timers.row$r.declaresOwn")"
done
t_eq "both timers are a command declaresOwnCommand recognises" "2" "$OWN"
t_eq "so neither may be left undeclared: normalizeIdleTimers fills both" \
  '[{"minutes":10,"action":"command","command":"vb-shell session lock","commandClass":"lock"},{"minutes":15,"action":"command","command":"vb-shell session suspend","commandClass":"suspend"}]' \
  "$(sval idle.timers.normalized)"
t_eq "normalizeIdleTimers is idempotent" "true" "$(sval idle.timers.normalizeIdempotent)"
t_eq "the normalized list still passes validateIdleTimers" "" \
  "$(sval idle.timers.normalizedValid)"
t_eq "buildIdleTimerRows carries the declared class through the write" \
  '[{"minutes":10,"action":"command","command":"vb-shell session lock","commandClass":"lock"},{"minutes":15,"action":"command","command":"vb-shell session suspend","commandClass":"suspend"}]' \
  "$(sval idle.timers.rowsNormalized)"
t_eq "the store's own fallback list is there" "yes" "$(sval idle.timers.fallbackPresent)"
t_eq "and it is the same list the catalog ships, read the way the daemon reads it" \
  "true" "$(sval idle.timers.fallbackMatchesCatalog)"
t_eq "so a stored list that fails validation still arms the shipped timers" "" \
  "$(sval idle.timers.fallbackValid)"
t_eq "the three project session verbs the engine knows by name" \
  'vb-shell lockscreen lock=lock vb-shell session lock=lock vb-shell session suspend=suspend' \
  "$(sed -n '/^const IDLE_VERB_CLASS = {/,/^}/p' "$SETTINGS_LIB" |
    sed -n 's/^[[:space:]]*"\([^"]*\)": "\([^"]*\)",*$/\1=\2/p' | LC_ALL=C sort | paste -sd' ' -)"
t_note "the catalog's shipped timer list is legal exactly as written: both commands are whole-argv-word spellings in IDLE_VERB_CLASS, so the read path declares lock and suspend on the first pass and the writer only has to agree - a catalog row carrying a command outside that set would have to declare its class itself, and validateIdleTimers would refuse an unknown one"

# --------------------------------------------------------------------------
# pages, the layout, and the generated bundle
# --------------------------------------------------------------------------

t_section "page ids are unique, derived and never silently deduped"
t_count "the settings and hypr stores declare 43 pages between them" "43" "$NG"
t_unique "the 44 page ids are distinct" \
  "$(for p in "${G_OWNED[@]}"; do printf '%s\n' "${G_PAGE[$p]}"; done)"
NOICON=0
for p in "${G_OWNED[@]}"; do
  t_ne "${G_PAGE[$p]} has a label" "-" "${G_LABEL[$p]}"
  t_match "${G_PAGE[$p]}'s showItemCount is a boolean" '^(true|false)$' "${G_COUNT[$p]}"
  t_match "${G_PAGE[$p]}'s id is the [a-z0-9_-] form" '^[a-z0-9_-]+$' "${G_PAGE[$p]}"
  [[ "${G_ICON[$p]}" == "-" ]] && NOICON=$((NOICON + 1))
done
t_eq "no page id needed the engine's -2 dedupe suffix" "0" \
  "$(for p in "${G_OWNED[@]}"; do printf '%s\n' "${G_PAGE[$p]}"; done | grep -c -- '-2$' || true)"
t_contains "and the engine only appends that suffix on a collision" \
  'seenPages[page] !== undefined) page = sections[s].page + "-" + n++' \
  "$(grep -m1 'seenPages\[page\] !== undefined' "$SETTINGS_LIB")"
t_note "$NOICON of $NG pages declare no icon: the 7 bar-module-* subpages, hyprland-edit and hyprland-appearance-decoration are reached as submenu rows, and a page with no icon still renders"

t_section "the bar layout, through validateLayout"
t_eq "exactly one option is a layout" "1" "$(sval layout.count)"
t_eq "it is shell.statusbar.layout" "shell.statusbar.layout" "$(sval layout.key)"
t_eq "validateLayout accepts its default" "" "$(sval layout.error)"
t_contains "validateLayout is the one structural gate for a layout value" \
  'function validateLayout(v)' "$(grep -m1 '^function validateLayout' "$SETTINGS_LIB")"
LAYOUT_ZONES=""
for zone in left center right disabled; do
  t_ne "layout.$zone names at least one module" "0" \
    "$(tr ',' '\n' < <(printf '%s\n' "$(sval "layout.$zone")") | wc -l | tr -d ' ')"
  t_eq "layout.$zone holds no duplicate id" "0" \
    "$(tr ',' '\n' < <(printf '%s\n' "$(sval "layout.$zone")") | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"
  t_eq "layout.$zone holds no empty id" "0" \
    "$(tr ',' '\n' < <(printf '%s\n' "$(sval "layout.$zone")") | grep -c '^$')"
  LAYOUT_ZONES="$LAYOUT_ZONES$(printf '%s\n' "$(sval "layout.$zone")" | tr ',' '\n')"$'\n'
done
t_eq "every disabled module is one a live zone also carries" "0" \
  "$(tr ',' '\n' < <(printf '%s\n' "$(sval layout.disabled)") | LC_ALL=C sort -u |
    comm -23 - <(printf '%s' "$LAYOUT_ZONES" | LC_ALL=C sort -u) | grep -c . )"
t_note "layout.disabled lists the 8 modules currently switched off, so all 8 also appear in a live zone: a zone id missing from disabled means the module is on, and a disabled id in no zone at all would be a module the user can never turn back on"

t_section "the generated menu bundle, from the merged schema"
t_eq "buildBundle emits 44 pages: the 43 catalog pages plus the settings index" \
  "44" "$(sval bundle.pages)"
t_eq "the synthetic index is page \"settings\"" "settings" "$(sval bundle.indexId)"
t_eq "its title comes from _index.jsonc" "Settings" "$(sval bundle.indexTitle)"
t_eq "and no width at all: the card measures the rows it shows" "-" \
  "$(sval bundle.indexWidth)"
t_eq "the title is the root chrome _index.jsonc declares" "Settings" "$(sval index.title)"
t_eq "the index links 15 top-level pages: the 28 submenu targets are children" \
  "15" "$(sval bundle.indexItems)"
t_eq "and there are exactly 28 submenu targets" "28" "$(sval bundle.childPages)"
t_eq "exactly one bundle page is the synthetic index" "1" \
  "$(for ((i = 0; i < NB; i++)); do [[ "${B_KIND[$i]}" == "index" ]] && printf 'x'; done | grep -c .)"
t_eq "and it is the one buildBundle unshifted at position 0" "settings" \
  "$(for ((i = 0; i < NB; i++)); do [[ "${B_KIND[$i]}" == "index" ]] && printf '%s' "${B_ID[$i]}"; done)"
DROPPED=""
EXTRA=""
for p in "${G_OWNED[@]}"; do
  if [[ "$(sval "bundle.has.${G_PAGE[$p]}")" != "yes" ]]; then
    DROPPED="$DROPPED${G_PAGE[$p]} "
  fi
done
WIDTHED=""
for ((i = 0; i < NB; i++)); do
  t_ne "${B_ID[$i]} has a title" "-" "${B_TITLE[$i]}"
  t_ne "${B_ID[$i]} carries at least one item" "0" "${B_ITEMS[$i]}"

  if ! for p in "${G_OWNED[@]}"; do printf '%s\n' "${G_PAGE[$p]}"; done |
    grep -qxF -- "${B_ID[$i]}"; then
    EXTRA="$EXTRA${B_ID[$i]} "
  fi
  # No bundle page carries a width: a card measures the rows it shows
  # (MenuPanel sizes from content), so a catalog that named one would be
  # sizing nothing.
  [[ "${B_WIDTH[$i]}" == "-" || -z "${B_WIDTH[$i]}" ]] || WIDTHED="$WIDTHED${B_ID[$i]}:${B_WIDTH[$i]} "
done
t_eq "no bundle page carries a width" "" "$WIDTHED"
t_eq "no catalog page is dropped from the bundle for having nothing visible" "" "$DROPPED"
t_eq "the bundle's only page the catalog does not declare is the index" \
  "settings " "$EXTRA"
t_note "the index links 16 of the 44 pages because buildBundle keeps a page that is a submenu target out of the top level (SettingsLib.js:1349); the 28 children stay reachable through their parent"

t_section "the bash env projection, from the same validated values"
t_eq "renderEnv writes 11 KEY=VAL lines" "11" "$(sval env.lines)"
t_eq "and that is exactly the number of env options in the catalog" "11" "$(sval env.expected)"
t_match "the projection opens with the do-not-edit header" \
  '^# Generated by Vibranium shell\. DO NOT EDIT\.$' "$(sval env.header)"
BADENV=""
for ((i = 0; i < NEN; i++)); do
  line="${EN_VAL[$i]}"
  name="${line%%=*}"
  t_match "env line $i names an UPPER_SNAKE key" '^[A-Z][A-Z0-9_]*$' "$name"
  if [[ "$name" == VIBRANIUM_* ]]; then
    BADENV="$BADENV$name carries the implied prefix; "
  fi
  if [[ -z ${KNOWN[$name]+set} ]]; then
    BADENV="$BADENV$name is not in the catalog; "
  fi
  if [[ "${line#"$name"=}" == "${line#*=}" && "${line#*=}" == "" ]]; then
    BADENV="$BADENV$name has an empty value; "
  fi
done
t_eq "no projected key is unknown, prefixed or empty" "" "$BADENV"
t_unique "the projection names no key twice" "$(for ((i = 0; i < NEN; i++)); do
  printf '%s\n' "${EN_VAL[$i]%%=*}"
done)"
t_eq "a string value is shell-quoted" "PLAYER_FADE_DURATION='off'" \
  "$(printf '%s\n' "${EN_VAL[@]}" | grep '^PLAYER_FADE_DURATION=')"
t_eq "a bool value is a bare true/false" "RECORDING_CAPTURE_SINK=true" \
  "$(printf '%s\n' "${EN_VAL[@]}" | grep '^RECORDING_CAPTURE_SINK=')"

# --------------------------------------------------------------------------
# the stores are deterministic
# --------------------------------------------------------------------------

t_section "the stores are deterministic"
t_eq "parseCatalogDir over the same files twice gives the same result" "true" \
  "$(sval stable.parseCatalogDir)"

t_section "catalog order: the numeric prefixes are the load-bearing part"
t_contains "_index.jsonc documents that the prefix is the order" \
  "File order (numeric prefixes) is catalog order" "$(<"$INDEX_JSONC")"
for list in shellCatalogFiles envCatalogFiles hyprCatalogFiles; do
  t_eq "$list's numeric prefixes strictly increase" "none" "$(first_prefix_inversion "$list")"
  t_sorted "$list is in sorted order too" "$(paths_named "$list")"
done
t_eq "the four lists together name 29 entries for 28 distinct files" "29" "$NP"
t_eq "so the 28 distinct files carry 28 distinct names" "28" \
  "$(printf '%s\n' "${P_REL[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
t_unique "and no file is named twice within the union" \
  "$(printf '%s\n' "${P_REL[@]}" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')"

t_section "page icons: what the catalog names against what the shell ships"
# The shipped count is not pinned: shell/assets/icons/ grows independently of
# the catalog, and a hardcoded total would turn an unrelated icon addition into
# a settings-catalog failure. What matters is the relation between the two sets.
t_ne "the icon set ships at least as many SVGs as the catalog names" \
  "fewer" "$(awk -v s="$(sval icons.shipped)" -v r="$(sval icons.referenced)" \
    'BEGIN { print (s >= r) ? "ok" : "fewer" }')"
t_eq "the catalog names 46 distinct icons" "46" "$(sval icons.referenced)"
t_note "shell/assets/icons/ currently ships $(sval icons.shipped) SVGs, keyed on basename (Icons.qml reads the basename, so two files of one name collide silently). The count is a note and not an assertion: the set grows on its own, and what this suite holds is the relation between it and the catalog, not its size"
MISSING_ICONS="$(sval icons.missing)"
MISSING_N="$(sval icons.missingCount)"
t_note "$MISSING_N of the 46 icon names the catalog declares resolve to no shipped SVG, and Icons.url() returns \"\" for an unknown name (Icons.qml:141) with no diagnostic, so those rows render with no icon: $(printf '%s' "$MISSING_ICONS" | tr ',' ' '). hypr/ declares the bare blur, glow, shadow, animation, layout, mouse, scroll and view-grid where shell/assets/icons/ ships hypr-blur, hypr-glow, hypr-shadow, hypr-animations, hypr-layout-dwindle, hypr-layout-master and hypr-layout-scrolling; apps, tools and view-grid have no shipped counterpart at all. default/vibranium/menus/main.jsonc and utilities.jsonc name only shipped icons, so the drift is specific to the settings catalog"
t_note "recorded as a note because a missing icon is a silent empty string, not a rule the engine enforces; a hard assertion would put a known, already-shipped cosmetic gap into the regression set"

t_summary

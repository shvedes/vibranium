#!/bin/bash
# Suite: shell/common/settings/catalog.jsonc - the one unified file the
# settings stores load at boot, validated by the engine that loads them.
#
# The sibling suites/js/settings.test.mjs drives SettingsLib.js against
# synthetic fixtures and pins every rule it enforces. This one runs the SAME
# library over the REAL catalog on disk, so a rule that is correct in
# isolation cannot be satisfied by a catalog that violates it. Nothing here
# reimplements the engine: the probe loads SettingsLib.js (and MenuLib.js
# for the menus half) through lib/qmlloader.mjs and reports what the real
# parseUnifiedCatalog / parseOption / pruneShowIf / validateValue /
# buildBundle / renderEnv say, and the assertions below are made on those
# reports.
#
# No Quickshell is started. The three stores compose the file the way the
# QML stores compose it - one parse, filtered by ownership:
#
#   Settings.qml         keeps sections with a non-hypr option (shell/env,
#                        plus the misc riders on General)
#   HyprlandSettings.qml keeps the hypr options of hypr-only sections
#   MiscSettings.qml     adopts the misc.* options wherever they ride
#
# The rules under test, quoted:
#
#   SettingsLib.js  "Keys carry their own namespace" (shell.*, bare
#                   UPPER_SNAKE env, hypr.*, misc.*)
#   SettingsLib.js  duplicate keys are a hard error (parseUnifiedCatalog
#                   throws, like parseCatalogDir did across files)
#   SettingsLib.js  showIf refs resolve: the unified file holds every key,
#                   so nothing prunes and nothing dangles
#   MenuLib.js      a submenu item's `page` is a target, so an unknown one
#                   is a menu row that opens nothing

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "settings-catalog" "the unified catalog.jsonc on disk, through the real SettingsLib validators"

require_tools node awk sed grep sort paste tr wc cut find

CATALOG_JSONC="$SHELL_DIR/common/settings/catalog.jsonc"
SETTINGS_LIB="$SHELL_DIR/common/settings/SettingsLib.js"
SETTINGS_QML="$SHELL_DIR/common/settings/Settings.qml"
MISC_QML="$SHELL_DIR/common/settings/MiscSettings.qml"
HYPR_QML="$SHELL_DIR/common/settings/HyprlandSettings.qml"
PATHS_QML="$SHELL_DIR/common/Paths.qml"
MENUS_LIB="$SHELL_DIR/features/menu/MenuLib.js"
ICONS_DIR="$SHELL_DIR/assets/icons"
LOADER_DIR="$TESTS_SHELL_DIR/lib"

# --------------------------------------------------------------------------
# probe: the real engine over the real file
# --------------------------------------------------------------------------

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vb-settings-catalog.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT

PROBE="$PROBE_DIR/catalog-probe.mjs"
cat >"$PROBE" <<'PROBE_EOF'
// Runs SettingsLib.js (+ MenuLib.js for menus) over the real catalog and
// writes one TSV per fact kind into $PROBE_OUT. Every record is a fact,
// never a verdict: the rules live in the bash suite, the engine only
// reports what it parsed.
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const V = process.env.VIBRANIUM_DIR
const OUT = process.env.PROBE_OUT
const LOADER = process.env.QMLLADER

const { loadLib } = await import(pathToFileURL(path.join(LOADER, 'qmlloader.mjs')).href)

const SHELL = path.join(V, 'shell')
const CATALOG = path.join(SHELL, 'common/settings/catalog.jsonc')
const SL = loadLib(path.join(SHELL, 'common/settings/SettingsLib.js'))
const SU = loadLib(path.join(SHELL, 'common/text/StringUtils.js'))
const ML = loadLib(path.join(SHELL, 'features/menu/MenuLib.js'))

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
const j = (v) => (v === undefined ? '-' : JSON.stringify(v))

const text = fs.readFileSync(CATALOG, 'utf8')
let cat = null
let threw = ''
try {
  cat = SL.parseUnifiedCatalog(text)
} catch (e) { threw = String(e && e.message ? e.message : e) }
if (cat === null) {
  rec('meta.tsv', ['threw', threw])
} else {
  const opts = cat.sections.reduce((a, s) => a + s.options.length, 0)
  rec('meta.tsv', ['ok', cat.sections.length, opts, Object.keys(cat.byKey).length,
    new Set(cat.sections.map((s) => s.page)).size,
    Array.isArray(cat.menus) ? cat.menus.length : 0,
    typeof cat.rootTitle === 'string' ? cat.rootTitle : '-'])
  for (const s of cat.sections) {
    for (const e of (s.errors || [])) rec('err.tsv', ['settings', s.page, e])
  }
  // Determinism: the same text twice is the same catalog.
  try {
    const again = SL.parseUnifiedCatalog(text)
    const sig = (c) => c.sections.map((s) => s.page + ':' + s.options.map((o) => o.key).join(',')).join('|')
    rec('stable.tsv', [sig(cat) === sig(again) ? 'true' : 'false'])
  } catch (e) { rec('stable.tsv', ['false']) }

  // Ownership split, mirroring the three QML stores: the page group names
  // the owning store, including the items-only pages that carry no option
  // to infer it from.
  const keptSettings = cat.sections.filter((pg) => pg.group === 'shell' || pg.group === 'env')
  const keptHypr = cat.sections.filter((pg) => pg.group === 'hypr')
  const ungrouped = cat.sections.filter((pg) => pg.group !== 'shell' && pg.group !== 'env' && pg.group !== 'hypr')
  let mixed = 0
  for (const pg of cat.sections) {
    const own = pg.options.filter((o) => !o.hypr)
    const hy = pg.options.filter((o) => o.hypr)
    if (own.length > 0 && hy.length > 0) mixed++
  }
  rec('split.tsv', [keptSettings.length, keptHypr.length, ungrouped.length, mixed])

  // Per-option records.
  const nsOfKey = (k) => (k.indexOf('hypr.') === 0 ? 'hypr'
    : k.indexOf('misc.') === 0 ? 'misc'
      : k.indexOf('.') >= 0 ? 'shell' : 'env')
  for (const sec of cat.sections) {
    sec.options.forEach((o, idx) => {
      rec('opt.tsv', [sec.page, idx, o.key, o.type, nsOfKey(o.key),
        o.env ? 'env' : o.hypr ? 'hypr' : o.misc ? 'misc' : 'shell',
        o.visibility, o.hidden ? 'hidden' : 'shown', o.values.length])
      for (const c of (o.showIf || [])) {
        const known = cat.byKey[c.var] !== undefined
        rec('ref.tsv', [o.key, c.var, known ? 'known' : 'unknown'])
        if (c.var === o.key) rec('err.tsv', [o.key, 'showIf', 'self reference'])
      }
    })
    for (const it of (sec.items || [])) {
      if (it && typeof it === 'object' && it.type === 'submenu' && typeof it.page === 'string' && it.page !== '')
        rec('menuref.tsv', [sec.page, it.page])
      if (it && typeof it === 'object' && typeof it.icon === 'string' && it.icon !== '')
        rec('icon.tsv', [it.icon, 'settings'])
    }
  }
  // Menus half, through the real MenuLib.
  try {
    const bundle = ML.parseBundle(text)
    rec('menumeta.tsv', ['ok', bundle.entry, bundle.pages.length, bundle.pages.map((p) => p.id).join(',')])
    for (const p of bundle.pages) rec('menu.tsv', [p.id, p.items.length])
    for (const p of bundle.pages) {
      for (const it of (p.items || [])) {
        if (it && typeof it === 'object' && it.type === 'submenu' && typeof it.page === 'string' && it.page !== '')
          rec('menuref.tsv', [p.id, it.page])
        if (it && typeof it === 'object' && typeof it.icon === 'string' && it.icon !== '')
          rec('icon.tsv', [it.icon, 'menu'])
      }
    }
  } catch (e) { rec('menumeta.tsv', ['threw', String(e && e.message ? e.message : e)]) }

  // The merged bundle the menu actually renders: every section plus index.
  const values = {}
  for (const k in cat.byKey) values[k] = cat.byKey[k].default
  try {
    const schema = SL.buildSchema(cat.sections, cat.rootWidth || 0, cat.rootTitle || '')
    const b = SL.buildBundle(schema, values)
    rec('bundle.tsv', ['pages', b.pages.length, b.pages[0] ? b.pages[0].id : '-'])
    for (const p of b.pages) rec('bundlepage.tsv', [p.id, (p.items || []).length])
  } catch (e) { rec('bundle.tsv', ['threw', String(e && e.message ? e.message : e)]) }

  // The bash env projection from the same validated values.
  try {
    const schema = SL.buildSchema(cat.sections, cat.rootWidth || 0, cat.rootTitle || '')
    const env = SL.renderEnv(schema, values)
    const lines = String(env).split('\n').filter((l) => l !== '')
    rec('envmeta.tsv', [lines.length])
    for (const l of lines) rec('env.tsv', [l])
  } catch (e) { rec('envmeta.tsv', ['threw', String(e && e.message ? e.message : e)]) }
}

for (const [file, body] of Object.entries(out)) {
  fs.writeFileSync(path.join(OUT, file), body)
}
PROBE_EOF

PROBE_OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vb-settings-catalog-out.XXXXXX")"
PROBE_OUT="$PROBE_OUT_DIR" QMLLADER="$LOADER_DIR" VIBRANIUM_DIR="$VIBRANIUM_DIR" \
  node "$PROBE" || t_fail "the probe over the real catalog did not run"

sval() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$PROBE_OUT_DIR/meta.tsv" 2>/dev/null; }

# --------------------------------------------------------------------------
# layout: one file, and the old directory is gone
# --------------------------------------------------------------------------

t_section "layout: one unified file"
t_file "the unified catalog exists" "$CATALOG_JSONC"
t_no_file "the old settings directory is gone" "$VIBRANIUM_DIR/default/vibranium/settings"
t_no_file "the old menus directory is gone" "$VIBRANIUM_DIR/default/vibranium/menus"
t_no_file "default/vibranium is gone entirely" "$VIBRANIUM_DIR/default/vibranium"
t_contains "Paths.qml points the schema dir at the shell" \
  'vibraniumHome + "/shell/common/settings"' "$(<"$PATHS_QML")"
t_contains "Paths.qml names the unified catalog" \
  'settingsSchemaDir + "/catalog.jsonc"' "$(<"$PATHS_QML")"
t_not_contains "no QML still references the old directory" \
  "default/vibranium" "$(grep -rn 'default/vibranium' "$SHELL_DIR" 2>/dev/null | grep -v 'that directory is gone' || true)"

# --------------------------------------------------------------------------
# the parse itself
# --------------------------------------------------------------------------

t_section "the unified catalog parses"
t_eq "parseUnifiedCatalog does not throw" "ok" "$(cut -f1 "$PROBE_OUT_DIR/meta.tsv")"
PAGES="$(awk -F'\t' '$1=="ok" {print $2}' "$PROBE_OUT_DIR/meta.tsv")"
OPTS="$(awk -F'\t' '$1=="ok" {print $3}' "$PROBE_OUT_DIR/meta.tsv")"
KEYS="$(awk -F'\t' '$1=="ok" {print $4}' "$PROBE_OUT_DIR/meta.tsv")"
PAGEIDS="$(awk -F'\t' '$1=="ok" {print $5}' "$PROBE_OUT_DIR/meta.tsv")"
MENUS="$(awk -F'\t' '$1=="ok" {print $6}' "$PROBE_OUT_DIR/meta.tsv")"
t_eq "the catalog holds 42 settings pages" "42" "$PAGES"
t_eq "the catalog holds 196 options" "196" "$OPTS"
t_eq "every option has a distinct key" "$OPTS" "$KEYS"
t_eq "every page has a distinct id" "$PAGES" "$PAGEIDS"
t_eq "the catalog holds 7 menu pages" "7" "$MENUS"
t_eq "the root title is Settings" "Settings" "$(awk -F'\t' '$1=="ok" {print $7}' "$PROBE_OUT_DIR/meta.tsv")"
t_eq "no section reports a parse error" "0" "$([[ -f "$PROBE_OUT_DIR/err.tsv" ]] && wc -l <"$PROBE_OUT_DIR/err.tsv" || echo 0)"
t_eq "parsing twice gives the same result" "true" "$(cat "$PROBE_OUT_DIR/stable.tsv" 2>/dev/null | cut -f1)"
t_eq "the documented cross-namespace riders still parse" "4" \
  "$(awk -F'\t' '$3=="APP_LAUNCHER_ALWAYS_FOCUS" || $3=="PLAYER_FADE_DURATION" || $3=="misc.cursorTheme" || $3=="misc.cursorSize"' "$PROBE_OUT_DIR/opt.tsv" | wc -l | tr -d ' ')"

# --------------------------------------------------------------------------
# ownership split across the three stores
# --------------------------------------------------------------------------

t_section "ownership split across the three stores"
t_eq "Settings keeps 24 shell/env pages" "24" "$(cut -f1 "$PROBE_OUT_DIR/split.tsv")"
t_eq "HyprlandSettings keeps 18 hypr pages" "18" "$(cut -f2 "$PROBE_OUT_DIR/split.tsv")"
t_eq "every page declares a group" "0" "$(cut -f3 "$PROBE_OUT_DIR/split.tsv")"
t_eq "no page mixes hypr and non-hypr options" "0" "$(cut -f4 "$PROBE_OUT_DIR/split.tsv")"
t_eq "shell options" "80" "$(awk -F'\t' '$5=="shell"' "$PROBE_OUT_DIR/opt.tsv" | wc -l | tr -d ' ')"
t_eq "env options" "11" "$(awk -F'\t' '$5=="env"' "$PROBE_OUT_DIR/opt.tsv" | wc -l | tr -d ' ')"
t_eq "hypr options" "103" "$(awk -F'\t' '$5=="hypr"' "$PROBE_OUT_DIR/opt.tsv" | wc -l | tr -d ' ')"
t_eq "misc options" "2" "$(awk -F'\t' '$5=="misc"' "$PROBE_OUT_DIR/opt.tsv" | wc -l | tr -d ' ')"
t_eq "showIf refs all resolve inside the unified file" "0" \
  "$(awk -F'\t' '$3=="unknown"' "$PROBE_OUT_DIR/ref.tsv" | wc -l | tr -d ' ')"

# --------------------------------------------------------------------------
# menus half
# --------------------------------------------------------------------------

t_section "menus half"
t_eq "MenuLib parses the menus" "ok" "$(cut -f1 "$PROBE_OUT_DIR/menumeta.tsv")"
t_eq "the entry page is main" "main" "$(cut -f2 "$PROBE_OUT_DIR/menumeta.tsv")"
t_eq "the menu ids are main, setup, install, remove, update, help, utilities" \
  "main,setup,install,remove,update,help,utilities" "$(cut -f4 "$PROBE_OUT_DIR/menumeta.tsv")"
t_eq "every submenu target resolves to a menu or settings page" "0" "$( {
  menu_ids="$(cut -f4 "$PROBE_OUT_DIR/menumeta.tsv" | tr ',' '\n')"
  bundle_ids="$(cut -f1 "$PROBE_OUT_DIR/bundlepage.tsv")"
  dead=0
  while IFS=$'\t' read -r _from target; do
    [[ -n $target ]] || continue
    if ! grep -qxF -- "$target" <(printf '%s\n' "$menu_ids") \
      && ! grep -qxF -- "$target" <(printf '%s\n' "$bundle_ids"; printf 'settings\n'); then
      dead=$((dead + 1))
    fi
  done <"$PROBE_OUT_DIR/menuref.tsv"
  printf '%s' "$dead"
} )"

# --------------------------------------------------------------------------
# the generated menu bundle, from the merged schema
# --------------------------------------------------------------------------

t_section "the generated menu bundle, from the merged schema"
t_eq "buildBundle emits 43 pages: the 42 catalog pages plus the settings index" \
  "43" "$(awk -F'\t' '$1=="pages" {print $2}' "$PROBE_OUT_DIR/bundle.tsv")"
t_eq "the synthetic index is page \"settings\"" "settings" \
  "$(awk -F'\t' '$1=="pages" {print $3}' "$PROBE_OUT_DIR/bundle.tsv")"
t_eq "every bundle page carries at least one item" "0" \
  "$(awk -F'\t' '$2==0' "$PROBE_OUT_DIR/bundlepage.tsv" | wc -l | tr -d ' ')"

# --------------------------------------------------------------------------
# the bash env projection, from the same validated values
# --------------------------------------------------------------------------

t_section "the bash env projection, from the same validated values"
t_eq "renderEnv writes 11 KEY=VAL lines" "11" "$(grep -v '^#' "$PROBE_OUT_DIR/env.tsv" | grep -c .)"
t_match "the projection opens with the do-not-edit header" \
  '^# Generated by Vibranium shell\. DO NOT EDIT\.$' "$(head -1 "$PROBE_OUT_DIR/env.tsv")"
BADENV=""
while IFS= read -r line; do
  [[ -n $line ]] || continue
  [[ $line == \#* ]] && continue
  name="${line%%=*}"
  if [[ ! $name =~ ^[A-Z][A-Z0-9_]*$ ]]; then BADENV="$BADENV$name is not UPPER_SNAKE; "; fi
  if [[ $name == VIBRANIUM_* ]]; then BADENV="$BADENV$name carries the implied prefix; "; fi
  if [[ "${line#*=}" == "" ]]; then BADENV="$BADENV$name has an empty value; "; fi
done <"$PROBE_OUT_DIR/env.tsv"
t_eq "no projected key is unknown, prefixed or empty" "" "$BADENV"
t_match "a string value is shell-quoted" "^PLAYER_FADE_DURATION='off'$" \
  "$(grep '^PLAYER_FADE_DURATION=' "$PROBE_OUT_DIR/env.tsv")"

# --------------------------------------------------------------------------
# icons: what the catalog names against what the shell ships
# --------------------------------------------------------------------------

t_section "icons: what the catalog names against what the shell ships"
SHIPPED="$(find "$ICONS_DIR" -type f -name '*.svg' | wc -l | tr -d ' ')"
REFERENCED="$(cut -f1 "$PROBE_OUT_DIR/icon.tsv" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
t_ne "the icon set ships at least as many SVGs as the catalog names" \
  "fewer" "$(awk -v s="$SHIPPED" -v r="$REFERENCED" 'BEGIN { print (s >= r) ? "ok" : "fewer" }')"
t_note "shell/assets/icons/ ships $SHIPPED SVGs against $REFERENCED referenced names; the count is a note and not an assertion"
MISSING="$(while IFS=$'\t' read -r name _where; do
  [[ -n $name ]] || continue
  if [[ ! -f "$ICONS_DIR/$name.svg" ]]; then printf '%s\n' "$name"; fi
done <"$PROBE_OUT_DIR/icon.tsv" | LC_ALL=C sort -u | paste -sd, -)"
t_note "referenced icons with no shipped SVG (silent empty string in Icons.url()): ${MISSING:-none}"
t_eq "menu pages reference no missing icon" "" "$(while IFS=$'\t' read -r name where; do
  [[ $where == menu ]] || continue
  [[ -f "$ICONS_DIR/$name.svg" ]] || printf '%s ' "$name"
done <"$PROBE_OUT_DIR/icon.tsv")"

t_summary

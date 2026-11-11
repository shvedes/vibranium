// Parsing, normalization, guards and search over menu bundles.
//
// A bundle is either a single page object or { "pages": [page, ...] }.
// Pages carry a unique id, a title and an items array. Items are plain
// objects; normalizeItem() fills every role the row renderer reads so
// views never branch on missing keys, and stamps each item with a uid
// usable as a key into the runtime state store held by the Menu service.
//
// Input files may be JSONC: whole-line // comments and trailing commas are
// stripped before parsing. Inline // inside a value line will break the
// parse - keep comments on their own lines. A file that fails to parse
// contributes nothing (the extension path relies on this to fail soft).
.pragma library

.import "../../common/text/StringUtils.js" as SU
.import "../../common/text/Format.js" as Format
.import "../../common/math/Range.js" as Range
.import "../../common/collections/StoreGuards.js" as StoreGuards
// Filter counting over a full pool uses the strict records matcher (not the
// menu's cross-word fuzzy search) - those two engines are deliberately
// different, so the counter reuses the one its caller uses. That matcher
// lives in SearchLib, which keeps the launcher - and ClipboardLib under it -
// out of this file's load graph; nothing else from either is read here.
.import "../../common/text/SearchLib.js" as SL
// SettingsLib is NOT imported. The live section counters are
// Menu.refreshSectionCounts and Menu.recomputeDeadLinks, which walk
// Menu.isVisible and therefore Menu.conditionsMet, in QML where the store
// singletons already are. Keeping SettingsLib out takes 1485 lines of it out
// of the menu's load graph, and it leaves no second evaluator here at all:
// every visibility question is answered by the one above.

function stripJsonc(raw) { return SU.stripJsonc(raw) }
function styledMarkup(text) { return SU.styledMarkup(text) }
function shellQuote(s) { return SU.shellQuote(s) }

// Clamp v into [lo, hi].
function clamp(v, lo, hi) {
  return Range.clamp(v, lo, hi)
}

// Round away float drift from stepping/parsing; 3 decimals covers every
// shipped step size.
function quantize(v) {
  return Range.round(v, 3)
}

// Decimal digits implied by a step spec ("0.05" -> 2, "1" -> 0).
function decimalsOf(step) {
  const s = String(step)
  const dot = s.indexOf(".")
  return dot < 0 ? 0 : s.length - dot - 1
}

// Suffix a numeric value renders behind: a declared unit rides after a
// space, no unit renders nothing. Absent and empty are the same answer
// here, which is why this never stringifies blindly - an unnormalized
// payload would print "undefined" into the value slot.
function unitSuffix(unit) {
  return unit !== undefined && unit !== null && String(unit) !== "" ? " " + String(unit) : ""
}

// Widest display string for a numeric/progress item - right-hand value
// must never elide, so the card reserves space for the longest possible
// reading. Used by MenuPanel to align all little bars in one perfect column.
function widestValueString(item) {
  if (!item) return ""
  const unit = unitSuffix(item.unit)
  const dec = decimalsOf(item.step ?? 1)
  if (item.type === "range" || item.type === "number") {
    const lo = Number(item.min ?? 0)
    const hi = Number(item.max ?? 100)
    const loStr = Format.fixed(lo, dec)
    const hiStr = Format.fixed(hi, dec)
    // If range straddles zero, the negative side may be longest even when
    // hi has more digits - e.g. -1.00 (5) vs 1.00 (4). Pick longest of lo/hi.
    let longest = loStr.length >= hiStr.length ? loStr : hiStr
    // Also consider hi with forced minus when min < 0 but hi positive and longer
    if (Number(item.min) < 0) {
      const negHi = "-" + hiStr
      if (negHi.length > longest.length) longest = negHi
    }
    return longest + unit
  }
  if (item.type === "progress") return "100 %"
  return ""
}

// Types a keyboard selection may land on; everything else is chrome.
// "option" is a runtime-only row generated for select pages.
const SELECTABLE = {
  action: true,
  submenu: true,
  toggle: true,
  select: true,
  number: true,
  range: true,
  text: true,
  expandable: true,
  option: true
}

function defaultsFor(type) {
  return {
    type: type,
    id: "",
    label: "",
    sub: "",
    icon: "",
    // Short display text painted in the row's icon slot (the emoji picker
    // carries one emoji here); rendered by Entry.qml when icon is empty.
    glyph: "",
    desc: "",
    warning: "",
    enabled: true,

    // Guard expressions evaluated in one batched bash run per load:
    // when     hide the row while the expression fails
    // checked  append a checkmark while the expression succeeds
    // disabled row stays listed but goes dim and unselectable
    when: "",
    checked: "",
    disabled: "",
    // Structured visibility (see requiresGuard): {chassis} and/or
    // {binary}. Normalized like showIf so guards evaluate it.
    requires: null,

    // action
    command: "",
    // Registry API call spec: "<target> <method> [args...]" with %v
    // substitution. Resolved through the Registry hub - the declarative
    // alternative to spawning `qs ipc call` shells from inside the menu.
    call: "",

    // submenu
    page: "",

    // toggle
    checked_: false,
    // Command run when a guarded toggle flips (evaluated in flip());
    // missing from the whitelist here it would be dropped at normalize
    // time and the pill would flip optimistically then revert when the
    // guard re-evaluation confirms nothing actually changed.
    onToggle: "",
    // Close the hosting menu right after the toggle flips (Caffeine,
    // Reading mode - fire-and-forget switches). Works for guarded and
    // var-bound toggles alike.
    close: false,

    // select
    value: "",
    options: [],
    onSelect: "",
    onCall: "",
    marker: true,

    // Free-text prompt hosted inside a select row's dropdown. Picking
    // the option whose value equals editValue swaps the dropdown for the
    // editor (prefilled with editText) instead of closing the menu;
    // Enter runs editCall and commits through the Registry hub, so
    // multi-word values arrive as one argument.
    editValue: "",
    editText: "",
    editCall: "",
    // Picking a select option collapses only the dropdown and keeps the
    // menu open. Default false keeps the classic action-select close
    // (recording needs the menu gone before capture UIs run); idle
    // timers opt in because their actions have no capture UI.
    keepOpen: false,
    // Number/range rows: blank the right-hand value slot (the picker
    // still seeds from the full display). Used by one-shot action rows
    // like "Add timer", whose value is an input, not a state readout.
    hideValue: false,

    // Staged input flow: ordered steps rendered one at a time inside a
    // single expansion. Each step is { kind: "select" | "number" |
    // "range" | "text", ...overrides }. Select steps may carry their own
    // options/value/onCall/onSelect; number/range steps carry min/max/
    // step/unit; text steps carry placeholder/initialText. Null means
    // the classic single-type row. Takes precedence over the
    // editValue single-prompt when both are present.
    flow: null,

    // Info-only expandable: click/Enter never expands (no dropdown), the
    // row is reference copy with ctrl+i as its only reveal. Chevron stays
    // hidden so nothing implies an expansion that is not there.
    infoOnly: false,

    // number / range
    min: 0,
    max: 100,
    step: 1,
    unit: "",
    onChange: "",

    // text
    placeholder: "",
    onSubmit: "",

    // progress
    progressValue: 0,

    // expandable
    body: "",

    // grid chrome: section header this cell belongs to (empty = untagged;
    // consecutive equal sections group under one header), and a command
    // template the panel offers Delete/Ctrl+D on (%v -> value).
    section: "",
    delCommand: "",

    // settings binding: canonical option key managed by the settings store.
    // Non-empty rows read/write through the store instead of session state.
    var: "",

    // store-driven visibility conditions (normalized showIf list) - row
    // hides while Settings.conditionsMet fails; UI-only. Bash reality
    // checks keep using the when/disabled guard fields above.
    showIf: null,

    // Data-driven active marker: the row paints as the current choice
    // (accent label and icon) with no guard expression and no shell. A
    // service that tracks the state itself (reads a state file, compares
    // in JS) sets it and re-stamps when the value moves; `checked` stays
    // the bash guard for the store-driven cases.
    active: false,

    // theme picker: palette swatches extracted from colors.list (hex
    // strings like "#719cd6"). Rendered as a row of filled dots under
    // the label in Entry.qml; ignored by search indexing and guards.
    // Kept as a plain array so normalize copies it and hay builders skip
    // it intentionally - hex codes are not useful search tokens.
    palette: [],

    // theme picker: Light/Dark flag derived from theme.info LIGHT field
    // or folder-name heuristic. Shown as "Light" / "Dark" after the icon
    // with a dot separator; not searchable.
    light: "",
    previewFontFamily: "",

    // Trailing accent word for the sub line ("active"): plain text in, a
    // dedicated accent element out - deliberately markup-free, so no
    // escaping is ever needed and bundles pass a bare word only.
    subAccent: "",

    // Leading accent word for the sub line (timer commands): same twin,
    // rendered AHEAD of the muted copy ("cmd * 15 min"). Markup-free,
    // indexed for search like sub.
    subLead: "",

    // Generic staged confirmation for any row (replaces per-service branches
    // in Entry). When present, activation becomes hint -> armed -> confirm
    // instead of the type's default. Core-backed services (timer/recording)
    // synthesize this at runtime; JSON may also declare it directly.
    confirm: null
  }
}

// Strip inline markup and normalize whitespace for hay construction.
// Descriptions carry <b>/<i>/<u> and \n; they must not pollute prefix
// matching (e.g. "<b>FPS</b>" should be searchable as "fps").
function stripForHay(s) {
  // One pass, not two. A run of tags (with the whitespace around or between
  // them) and a plain whitespace run both become one space, so the interior
  // collapses the second pass used to do. Identical output on the whole
  // catalog corpus and a fuzz set; measured 1.92ms -> 1.35ms over 3000
  // description strings.
  //
  // Memoized on the input string: the descriptions this runs over come from
  // the catalog, so a rebuild re-runs the same regex over the same text - the
  // pages are re-normalized whenever the store publishes, and the catalog's
  // descriptions do not move. Keyed by the text and emptied whole when it
  // fills, so a cache that is not paying for itself cannot grow without bound.
  // The cache rides on the function object: a `.pragma library` publishes its
  // top-level declarations, and this is not part of the library's surface.
  const text = String(s)
  let cache = stripForHay._cache
  if (cache === undefined) cache = stripForHay._cache = new Map()
  const hit = cache.get(text)
  if (hit !== undefined) return hit
  const out = text.replace(/(?:\s*<[^>]*>)+\s*|\s+/g, " ").trim()
  if (cache.size >= 512) cache.clear()
  cache.set(text, out)
  return out
}

function hayFromItem(item, includeMetadata) {
  const parts = SL.titleParts(item)
  if (item.desc) parts.push(stripForHay(item.desc))
  if (item.warning) parts.push(stripForHay(item.warning))
  if (item.body) parts.push(stripForHay(item.body))
  if (item.placeholder) parts.push(String(item.placeholder))
  if (item.unit) parts.push(String(item.unit))
  // Current value (select/text/number/range) - stringified for text search.
  if (item.value !== undefined && item.value !== null) {
    const vs = String(item.value).trim()
    if (vs !== "") parts.push(vs)
  }
  if (includeMetadata !== false) {
    // Select options: every possible choice should be discoverable from the
    // parent row (searching "google" finds the Search engine row).
    if (Array.isArray(item.options)) {
      for (let i = 0; i < item.options.length; i++) {
        const o = item.options[i]
        if (!o || typeof o !== "object") continue
        if (o.label) parts.push(String(o.label))
        if (o.value !== undefined && o.value !== null) {
          const ov = String(o.value).trim()
          if (ov !== "") parts.push(ov)
        }
      }
    }
    // Canonical keys help power users ("RECORDING_FPS" -> FPS row) and make
    // extension ids searchable.
    if (item.var) parts.push(String(item.var))
    if (item.id) parts.push(String(item.id))
  }
  // Lowercase once; deduplicate words to keep hay compact for faster
  // indexOf scans (a word repeated 4x would otherwise inflate the
  // string to ~250 chars). Order of first appearance is preserved so
  // ranking (earlier = higher) stays meaningful. The dedupe itself lives
  // in SearchLib.dedupeWords, reached through this file's own SL alias - a
  // plain {} there is a silent data loss keyed off
  // a word ("constructor" / "__proto__" read as already-seen and dropped).
  const raw = parts.join(" ").toLowerCase()
  return SL.dedupeWords(raw.split(/\s+/)).join(" ")
}

// Per-row cache of the scoped-filter haystacks below, so a filter keystroke
// over a page it has already narrowed does not rebuild one hay per row. Weak:
// the rows of a replaced page are collected with their strings.
//
// Keyed by ROW and stamped with the raw visible text the hay was built from,
// not by row alone. The menu mirrors a live value into its row (`it.value`
// follows the settings store) without rebuilding the row, so a row can change
// under the filter; a hay cached against its identity alone would keep
// matching the value it had when the filter first saw it.
var _filterHay = new WeakMap()

// Haystack for the "/" in-page quick-filter: ONLY what the row shows at
// rest (label, subLead, sub, placeholder, unit, current value). Descriptions,
// warnings and bodies need ctrl+i/expansion to be seen, so matching them
// trims by invisible text - typing "h" on the main menu kept every row whose
// description mentions "themes"/"hardware" and felt broken. Cross-page search
// keeps matching everything via hayFromItem; the trim matches what is there.
// The raw (unlowercased, undeduped) visible text of a row: the input the
// filter hay is built from, and the stamp the cache in scopedFilter compares.
// Split out so the two cannot drift over which fields count as visible.
function hayFilterRaw(item) {
  const parts = SL.titleParts(item)
  if (item.placeholder) parts.push(String(item.placeholder))
  if (item.unit) parts.push(String(item.unit))
  if (item.value !== undefined && item.value !== null) {
    const vs = String(item.value).trim()
    if (vs !== "") parts.push(vs)
  }
  return parts.join(" ")
}

function hayFilterOf(raw) {
  const lower = raw.toLowerCase()
  return SL.dedupeWords(lower.split(/\s+/)).join(" ")
}

function hayForFilter(item) {
  return hayFilterOf(hayFilterRaw(item))
}

// The key half of a uid, from a declared id or from the row's position.
//
// "#" and ":" are structural - they delimit uid and the guard verdict token -
// so they cannot survive in a key. Neither can a control character, and that
// one is not cosmetic: the verdict channel is LINE-oriented (the reader splits
// the script's stdout on "\n") while shellQuote preserves a newline verbatim
// inside its single quotes, so a newline in an id made one row's verdict print
// as two lines and forge an answer for whatever uid the second line spelled.
// Page ids reach the same channel, so they are sanitized the same way.
function uidKey(rawId, index) {
  if (typeof rawId !== "string") return String(index)
  const trimmed = rawId.trim()
  if (trimmed === "") return String(index)
  return trimmed.replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
}

function normalizeItem(raw, pageId, index) {
  const type = typeof raw.type === "string" ? raw.type : "action"
  const item = defaultsFor(type)
  for (const key in item) {
    // A null is "no value", the same as an absent key, so the default stands.
    // It does not override: `"label": null` would index as the word "null",
    // and a `"when": null` would be read as a non-string guard and hide the
    // row. In an extension merge a null is therefore also how a field is
    // cleared.
    if (raw[key] !== undefined && key !== "type") item[key] = raw[key]
  }
  // `checked` names the guard expression; the boolean seed lives in the
  // state store, so remap the JSON bool under a reserved key.
  if (typeof raw.checked === "boolean") item.checked_ = raw.checked === true
  // A submenu's target is the OTHER side of the page-id pair, and normalizePage
  // sanitizes the page id - so the reference has to be sanitized the same way
  // or a page id carrying a control character resolves to nothing and the link
  // reads as dead.
  if (typeof item.page === "string" && item.page !== "")
    item.page = uidKey(item.page, item.page)
  // Non-writable selects (action-selects) are triggers, not persisted
  // settings - the dropdown does not mark the chosen option with a dot.
  // Explicit `marker: true` keeps the indicator when a transient select
  // still wants to show its current value (e.g. theme variant picker).
  if (type === "select" && raw.marker === undefined && item.var === "" && item.onSelect !== "") {
    item.marker = false
  }
  if (Array.isArray(raw.flow) && raw.flow.length > 0) {
    const steps = []
    for (let i = 0; i < raw.flow.length; i++) {
      const s = raw.flow[i]
      if (!s || typeof s !== "object") continue
      const kind = s.kind === "number" || s.kind === "range"
        || s.kind === "text" || s.kind === "select" ? s.kind : ""
      if (kind === "") continue
      steps.push(Object.assign({}, s, { kind: kind }))
    }
    item.flow = steps.length > 0 ? steps : null
  } else {
    item.flow = null
  }
  // `!== true`, not falsy: SELECTABLE is a plain object, so a type spelled
  // "toString" or "constructor" found an inherited function there and kept
  // enabled = true on a row that is not selectable.
  if (SELECTABLE[type] !== true) item.enabled = false
  // Stable identity: explicit ids pin the uid across inserts, removals and
  // reorders (dynamic pages rebuild wholesale - positional uids would hand
  // one row's runtime state, guard answers and list identity to another
  // row). Sanitized; buildPage dedupes collisions. Anonymous rows keep
  // positional uids. Internal key rides along for the dedupe pass.
  item._uidKey = uidKey(raw.id, index)
  item.uid = pageId + "#" + item._uidKey
  item.selectable = SELECTABLE[type] === true && item.enabled !== false
  item.hay = hayFromItem(item)
  // The "/" quick-filter's visible-only haystack (hayForFilter) is NOT built
  // here. Only a scoped filter reads it, and most bundles are never filtered
  // that way, so building it on every row of every rebuild paid for a second
  // hay - the same fields lowercased, split and deduped again - for nothing.
  // scopedFilter builds it for a row the first time it filters one and keeps
  // it in its own cache (see there), so the cost moves to the keystroke that
  // actually needs it and is paid once per row.
  return item
}

// Build the page shown when a select row is activated: one option row per
// choice. Options are plain entries - the menu never renders inline
// dropdowns. The parent link lets rows mirror and commit the choice.
function buildPage(id, title, width, rawItems, opts) {
  opts = opts || {}
  const items = []
  const list = StoreGuards.asList(rawItems)
  const seenUid = {}
  for (let i = 0; i < list.length; i++) {
    // A row that is not an object cannot be a row. It is skipped, so one
    // stray null costs that row and nothing else. The position still
    // counts, so the uids of the rows after it do not move.
    if (list[i] === null || typeof list[i] !== "object" || Array.isArray(list[i])) continue
    const it = normalizeItem(list[i], id, i)
    it._pageWidth = typeof width === "number" ? width : 0
    // Duplicate id-derived uids (two rows claiming one id) would share
    // runtime state and list identity - suffix later twins so every uid on
    // the page stays unique. "~" is safe in guard lines and uid parsing.
    if (seenUid[it.uid] !== undefined) {
      let n = 2
      while (seenUid[id + "#" + it._uidKey + "~" + n] !== undefined) n++
      it._uidKey = it._uidKey + "~" + n
      it.uid = id + "#" + it._uidKey
    }
    seenUid[it.uid] = true
    // Page-level fallback command: action rows without their own inherit
    // the page template (%v -> item.value). Keeps glyph bundles compact -
    // thousands of rows share one insertion command instead of repeating
    // it per row.
    // A row that declares a Registry `call` has an action of its own; handing
    // it the page template as well gave it two.
    if (it.type === "action" && it.command === "" && it.call === ""
      && typeof opts.command === "string")
      it.command = opts.command
    items.push(it)
  }
  return {
    id: id,
    label: typeof title === "string" && title !== "" ? title : id,
    width: typeof width === "number" ? width : 0,
    // Rendering mode: "list" (default rows) | "grid" (equal cells, one
    // glyph each). Only meaningful for action-only pages (emoji picker);
    // the panel decides which view to instantiate from this field.
    layout: opts.layout === "grid" ? "grid" : "list",
    // Cell side hint in px for grid pages; 0 lets the panel choose.
    cell: typeof opts.cell === "number" && opts.cell > 16 ? Math.round(opts.cell) : 0,
    // Card ceiling override in px (pickers want compact cards, menus the
    // screen-share default); 0 keeps the panel's default.
    maxHeight: typeof opts.maxHeight === "number" && opts.maxHeight > 120
      ? Math.round(opts.maxHeight) : 0,
    // Resolved fallback command kept on the page so extension merges
    // (mergedPageOpts) can re-apply it to re-normalized rows.
    command: typeof opts.command === "string" ? opts.command : "",
    // Typing narrows this page instead of searching the bundle: for
    // single-page pickers with no nesting (emoji), where a global search
    // has nothing to span. The panel arms the scoped filter on the first
    // keystroke when the current page declares it.
    filterDefault: opts.filterDefault === true,
    items: items,
    // Raw sources kept for later extension merges; merging happens on raw
    // objects so every final page can be re-normalized with fresh uids.
    _raw: list
  }
}

// The page a select opens: one option row per choice.
//
// WHY IT IS HERE AND NOT IN A PANEL. A select is a row that names a set, and
// opening it is the same normalization every other row gets - the same uid
// scheme, the same defaults, the same hay. A panel that built these rows
// itself would be the second place a row's shape is decided, and the two would
// drift on the first field either of them added. So the parent select goes in
// and a PAGE comes out, with the parent's commit and call commands carried onto
// every option row and the parent's uid as the back-link the row uses to mirror
// and commit the choice.
//
// The parent is never written to: reading it is the whole contract, and a page
// field on a row that is also a row is how one row's expansion would leak into
// the next page build.
//
// An option is described by its label, falling back to its value (a JSON
// boolean or a zero is a label, not a missing one - `!== null && !== undefined`,
// never `||`), and anything it carries that a row cannot hold is dropped at the
// boundary rather than copied through: a non-array palette becomes no palette,
// a non-string light flag becomes none.
function buildOptionsPage(sel) {
  const parent = sel || {}
  const uid = parent.uid
  const id = String(uid) + "::options"
  const list = StoreGuards.asList(parent.options)
  const items = []
  for (let i = 0; i < list.length; i++) {
    // A null option is a throw, not a skipped row: the bundle named a choice
    // and cannot say what it is, which is a broken select rather than a short
    // one. buildPage skips a null because a page's raw list is data; an option
    // list is a vocabulary.
    const o = list[i]
    const labelled = o.label !== null && o.label !== undefined
    const it = normalizeItem({
      type: "option",
      label: labelled ? o.label : String(o.value),
      value: o.value,
      onSelect: parent.onSelect,
      onCall: parent.onCall,
      palette: StoreGuards.asList(o.palette),
      light: typeof o.light === "string" ? o.light : ""
    }, id, i)
    // The back-link is a page fact, not a row field: it names the select this
    // page expands, so it is stamped here rather than declared in defaultsFor
    // where every row type would carry a field only option rows use.
    it._parentUid = uid
    items.push(it)
  }
  return {
    id: id,
    label: typeof parent.label === "string" && parent.label !== "" ? parent.label : id,
    width: typeof parent._pageWidth === "number" ? parent._pageWidth : 0,
    // An option page is always a plain list of choices: no cells, no ceiling
    // of its own, and no scoped filter (typing narrows the options through the
    // panel's existing filter, not through a page default).
    layout: "list",
    cell: 0,
    maxHeight: 0,
    filterDefault: false,
    items: items,
    _raw: list
  }
}

// Layout fields an extension may override per page. Absent ext fields
// keep the base page's values.
function mergedPageOpts(extPage, base) {
  return {
    layout: typeof extPage.layout === "string" ? extPage.layout : base.layout,
    cell: typeof extPage.cell === "number" ? extPage.cell : base.cell,
    maxHeight: typeof extPage.maxHeight === "number" ? extPage.maxHeight : base.maxHeight,
    command: typeof extPage.command === "string" ? extPage.command : base.command,
    filterDefault: typeof extPage.filterDefault === "boolean" ? extPage.filterDefault : base.filterDefault
  }
}

function normalizePage(raw, fallbackId) {
  // A page that is not an object (a null in the pages array) is an empty page
  // at its fallback id, as a scalar document already is, instead of a bare
  // TypeError naming nothing.
  if (raw === null || typeof raw !== "object") raw = {}
  const title = typeof raw.title === "string" && raw.title !== "" ? raw.title
    : typeof raw.label === "string" ? raw.label : undefined
  return buildPage(
    // A page id reaches every uid on the page and the guard verdict token
    // with it, so it gets the same sanitizing an item id does - a control
    // character here forges verdicts for the whole page, not one row. An id
    // that sanitizes away to nothing falls back like an absent one, so the
    // fallback id is what the page is reachable by.
    (typeof raw.id === "string" && raw.id !== ""
      ? uidKey(raw.id, "").replace(/^-+$/, "") : "") || fallbackId,
    title,
    typeof raw.width === "number" ? raw.width : 0,
    StoreGuards.asList(raw.items),
    { layout: raw.layout, cell: raw.cell, maxHeight: raw.maxHeight, command: raw.command, filterDefault: raw.filterDefault }
  )
}

function parseBundle(text) {
  const raw = JSON.parse(stripJsonc(text))
  // `[raw]` for anything that is neither an array nor a pages holder is
  // deliberate: a scalar document wraps into a one-page bundle at the default
  // id. Only null is refused, and it is refused HERE because reading raw.pages
  // off it raised a bare TypeError naming nothing about which file was bad.
  // A unified catalog carries both settings `pages` and menu `menus`: the
  // menu always reads `menus` from it, while the settings stores read
  // `pages` through SettingsLib.parseUnifiedCatalog.
  if (raw === null) throw new Error("bundle is null")
  const rawPages = Array.isArray(raw) ? raw : (Array.isArray(raw.menus) ? raw.menus : (Array.isArray(raw.pages) ? raw.pages : [raw]))
  return bundleFromPages(rawPages)
}

// Containers from ALREADY-PARSED page objects: the same normalization and the
// same duplicate-id rule as parseBundle, without the parse. The unified
// catalog is read and parsed once for the settings stores (SettingsCatalog),
// so the menu takes its `menus` from there instead of stripJsonc + JSON.parse
// over the same ~5k lines on every container rebuild - which measured as 80%
// of what was left of a rebuild.
function bundleFromPages(rawPages) {
  const pages = []
  // Prototype-less: the keys are page ids, and they come from a file. A page
  // declared `"id": "__proto__"` did not create a key - it assigned byId's
  // prototype to that page object, after which byId["items"], byId["label"]
  // and byId["_raw"] all resolved as if they were pages, and Menu looks up
  // bundle.byId[it.page] on every submenu row.
  const byId = Object.create(null)
  // Two pages declaring one id are a uid-space collision, not a harmless
  // duplicate: suffix the second the way buildPage suffixes a duplicate item
  // uid. "~" is safe in uid parsing and in a guard line.
  function dedupePage(page, i) {
    if (byId[page.id] === undefined) return page
    return normalizePage(Object.assign({}, rawPages[i], { id: page.id + "~" + (i + 1) }),
      i === 0 ? "main" : "page" + i)
  }
  for (let i = 0; i < rawPages.length; i++) {
    let page = normalizePage(rawPages[i], i === 0 ? "main" : "page" + i)
    // Two pages declaring one id are a uid-space collision, not a harmless
    // duplicate: buildPage's dedupe is page-local, so both mint the same uids
    // for same-named rows, they share one runtime-state slot, buildGuardScript
    // emits two verdicts per uid and the reader keeps the last, and byId can
    // only name one of the pages - leaving the other unreachable while still
    // indexed. Suffix the second, the way buildPage suffixes a duplicate item
    // uid; "~" is safe in uid parsing and in a guard line.
    page = dedupePage(page, i)
    pages.push(page)
    byId[page.id] = page
  }
  if (pages.length === 0) throw new Error("bundle has no pages")
  return {
    entry: pages[0].id,
    pages: pages,
    byId: byId
  }
}

// Top-level settings order, by page id. The misc grab-bag is last.
// Unknown ids (user extensions, future pages) keep their relative order
// after all known rows. A bundle whose settings page has no Hyprland
// link gets one appended, so the row is present even before
// HyprlandSettings is ready to join its pages.
//
// The reorder writes through the page it is handed, which is safe because
// mergePages gives every bundle its OWN page shells: the rows are shared with
// the store's cache, the page object is not, so assigning `page.items` here
// cannot reorder the cache and leak one bundle's layout into the next.
function orderSettingsIndex(base) {
  const order = ["general", "bar", "app-launcher", "audio", "brightness",
    "screenshots", "recording", "night-light", "media-controls",
    "network", "lock-screen", "power", "color-picker", "hyprland", "idle", "osd",
    "misc"]
  const rank = Object.create(null)
  for (let i = 0; i < order.length; i++) rank[order[i]] = i
  const page = base.byId ? base.byId["settings"] : null
  if (!page || !Array.isArray(page.items)) return
  // Appending the synthesized link needs a uid no existing row on the page
  // holds. It is stamped pageId#id, so checking the same key is the check -
  // and it is wider than the submenu test it replaces, which only recognised a
  // row that was a submenu POINTING at hyprland and so let a plain row
  // carrying id "hyprland" through to mint a duplicate uid. A duplicate key
  // makes MenuPanel.keyedRows refuse the whole projection, so the page would
  // render once and then ignore every later add, remove and filter.
  const items = page.items.slice()
  // The link is appended unless one is already there. The uid it stamps is
  // settings#id, so a row that merely CALLS itself "hyprland" - a plain action,
  // not a link - would collide with it, and a duplicate key makes
  // MenuPanel.keyedRows refuse the whole projection, freezing the page. So the
  // collision is resolved by suffixing the key, the way buildPage suffixes a
  // duplicate item uid, rather than by skipping the link: skipping it left the
  // settings page with no Hyprland entry at all, which is a worse answer than
  // either.
  const linked = items.some(it => it && it.type === "submenu" && it.page === "hyprland")
  if (base.byId["hyprland"] !== undefined && !linked) {
    let key = "hyprland"
    for (let n = 2; items.some(it => it && it.uid === "settings#" + key); n++)
      key = "hyprland~" + n
    items.push(normalizeItem(
      { id: key, type: "submenu", label: "Hyprland", sub: "Window manager behavior", icon: "hyprland", page: "hyprland" },
      "settings", items.length))
  }
  const known = []
  const unknown = []
  for (let i = 0; i < items.length; i++) {
    const it = items[i]
    const key = it && (it.page || it.id || "")
    if (key !== "" && rank[key] !== undefined) known.push(it)
    else unknown.push(it)
  }
  known.sort((a, b) => rank[a.page || a.id] - rank[b.page || b.id])
  page.items = known.concat(unknown)
}

// Normalize a store's page descriptors ONE time. Descriptors are the plain
// {id, title, items} objects SettingsLib.buildPages emits; the result is what
// the menu navigates, so a caller that keeps it across container loads must
// leave it alone - mergePages appends by reference and orderSettingsIndex
// copies the one page it reorders.
function normalizePages(descriptors) {
  const out = []
  if (!Array.isArray(descriptors)) return out
  for (let i = 0; i < descriptors.length; i++) {
    const d = descriptors[i]
    const fallback = d && typeof d.id === "string" && d.id !== "" ? d.id : "page" + i
    out.push(normalizePage(d, fallback))
  }
  return out
}

// Append already-normalized pages from another store: the one merge every
// contributor to the tree goes through. Pages are shared by reference - that
// is the point, one normalization per store generation however many bundles
// are built from it - so nothing here mutates them. An id the opened bundle
// already claims keeps the bundle's page, the authority rule the text merge
// used to apply. Returns `base` itself when nothing was added, so a caller can
// compare identity to know whether the tree changed at all.
function mergePages(base, pages) {
  if (!Array.isArray(pages) || pages.length === 0) return base
  let outPages = null
  let outById = null
  for (let i = 0; i < pages.length; i++) {
    const page = pages[i]
    if (!page || typeof page.id !== "string" || page.id === "") continue
    if ((outById === null ? base.byId : outById)[page.id] !== undefined) continue
    if (outPages === null) {
      outPages = base.pages.slice()
      outById = Object.assign(Object.create(null), base.byId)
    }
    // The shell is copied, the rows are not: the bundle owns a page object it
    // may reorder in place (see orderSettingsIndex) while the store's cached
    // page - and every row object in it - stays shared by reference. pages and
    // byId must name the SAME shell, or a reorder would reach one and not the
    // other.
    const shell = Object.assign({}, page)
    outPages.push(shell)
    outById[page.id] = shell
  }
  if (outPages === null) return base
  return {
    entry: base.entry,
    pages: outPages,
    byId: outById
  }
}

// Merge a user extension bundle over a parsed base. Pages match by id;
// page title/width override, items merge by their optional `id` field
// (field-level override) or append when new/anonymous. Pages re-normalize
// from raw sources after merging, so uids always match final positions.
function applyExtension(base, extText) {
  let ext
  try {
    ext = JSON.parse(stripJsonc(extText))
  } catch (e) {
    return base
  }
  // A document that is not an object has nothing to merge; reading .pages off
  // a null threw past the fail-soft path above.
  if (ext === null || typeof ext !== "object") return base
  const extPages = Array.isArray(ext) ? ext : (Array.isArray(ext.pages) ? ext.pages : [ext])
  if (extPages.length === 0) return base

  let pages = base.pages.slice()
  const byId = Object.assign(Object.create(null), base.byId)

  for (let i = 0; i < extPages.length; i++) {
    const extPage = extPages[i]
    if (!extPage || typeof extPage.id !== "string" || extPage.id === "") continue

    const existing = byId[extPage.id]
    if (!existing) {
      const added = normalizePage(extPage, extPage.id)
      pages.push(added)
      byId[added.id] = added
      continue
    }

    const mergedRaw = mergeRawItems(existing._raw, StoreGuards.asList(extPage.items))
    const merged = buildPage(existing.id, mergedLabel(extPage.title, existing.label), mergedWidth(extPage.width, existing.width), mergedRaw, mergedPageOpts(extPage, existing))
    pages = replacePage(pages, merged)
    byId[merged.id] = merged
  }

  return {
    entry: byId[base.entry] ? base.entry : pages[0].id,
    pages: pages,
    byId: byId
  }
}

function mergedLabel(extTitle, baseLabel) {
  return typeof extTitle === "string" && extTitle !== "" ? extTitle : baseLabel
}

function mergedWidth(extWidth, baseWidth) {
  return typeof extWidth === "number" && extWidth > 0 ? extWidth : baseWidth
}

function replacePage(pages, page) {
  const out = []
  for (let i = 0; i < pages.length; i++) {
    out.push(pages[i].id === page.id ? page : pages[i])
  }
  return out
}

function mergeRawItems(baseRaw, extRaw) {
  // Prototype-less: the keys are item ids from a file, and an extension row
  // with id "constructor" found an inherited function here, wrote its override
  // to a nonsense slot and was dropped instead of appended.
  const indexById = Object.create(null)
  for (let i = 0; i < baseRaw.length; i++) {
    const id = baseRaw[i] && typeof baseRaw[i].id === "string" ? baseRaw[i].id : ""
    if (id !== "") indexById[id] = i
  }

  // Overrides land in place first so appends keep their relative order at
  // the end of the page regardless of how the extension interleaves them.
  const out = baseRaw.slice()
  const appends = []
  for (let j = 0; j < extRaw.length; j++) {
    const raw = extRaw[j]
    if (!raw || typeof raw !== "object") continue
    const key = typeof raw.id === "string" ? raw.id : ""
    if (key !== "" && indexById[key] !== undefined) {
      out[indexById[key]] = Object.assign({}, out[indexById[key]], raw)
    } else {
      appends.push(raw)
    }
  }
  for (let a = 0; a < appends.length; a++) {
    out.push(appends[a])
  }
  return out
}

// --- guards ---

// One bash script for every when:/checked:/disabled: expression in the
// bundle, reporting `<uid>:<w|c|d>:<0|1>` per line. The menu opens on the
// previous evaluation's answers, so however long this takes is how long a
// row can contradict the state it describes.
function buildGuardScript(pages) {
  let script = ""
  for (let p = 0; p < pages.length; p++) {
    const items = pages[p].items
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      // `when` and `requires` are INDEPENDENT conditions on one row, so they
      // answer as one verdict, and they are emitted as ONE `w` line for the
      // same uid: the reader collapses a repeated uid last-one-wins, so a
      // second line would let an OR stand in for an AND, and an extension
      // that added a `requires` to a row whose own `when` said false would
      // make the row show. A refused `requires` shape is an unconditional
      // hide, which is not an expression and so cannot be ANDed; it wins
      // outright.
      const rq = requiresExpr(item.requires)
      const when = typeof item.when === "string" ? item.when.trim() : ""
      // A `when` that is not a string is a config error, and the two ways of
      // answering it were a silent drop and a hard hide - the same mistake met
      // two different fates depending on which field carried it. The drop was
      // the worse of the two: the row then rendered with no verdict at all,
      // and a missing verdict reads as VISIBLE, so a typo in a guard unhid the
      // row it was meant to hide. Same fail-open the reader had on a nonzero
      // exit, one level down. Refuse it the way a refused `requires` is
      // refused, and the two fields finally agree.
      if (rq === null || (item.when !== "" && typeof item.when !== "string"))
        script += hideLine(item.uid)
      else if (rq === undefined) script += guardLine(item.uid, "w", when)
      else script += guardLine(item.uid, "w", when === "" ? rq : when + " && " + rq)
      script += guardLine(item.uid, "c", item.checked)
      script += guardLine(item.uid, "d", item.disabled)
    }
  }
  return script
}

// The shell expression a structured `requires` compiles to.
//
// Three answers, and the middle one is the reason this is not a boolean:
// `undefined` means the row declared no requirement at all, `null` means it
// declared one this evaluator refuses, and a string is the expression. An
// absent requirement and a refused one must not collapse - the first is a row
// free to show, the second is a row that cannot prove itself, and treating the
// refused shape as "no constraint" would show a row the author gated.
function requiresExpr(requires) {
  if (requires === undefined || requires === null) return undefined
  // A non-object reaches the property probes below and reads as "declared
  // nothing", which is the one answer that must not be inferred from a shape
  // that is not a requirement at all.
  if (typeof requires !== "object" || Array.isArray(requires)) return null
  const exprs = []
  if (requires.binary !== undefined) {
    // Upper case is a program name too (Hyprland, Xwayland), and the name
    // must be lower case, so a row gated on one is hidden on every machine.
    // The first character may not be a hyphen: it would reach `type` as an
    // option.
    if (typeof requires.binary !== "string"
      || !/^[a-z0-9._-]+$/.test(requires.binary))
      return null
    // `type -P`, not `command -v`. The latter answers for shell builtins,
    // keywords and functions as well as PATH programs, so `{"binary":"cd"}`
    // or `{"binary":"true"}` passed on every machine and showed a row that was
    // gated on a program being installed. `type -P` reports PATH files only.
    exprs.push("type -P " + requires.binary + " >/dev/null")
  }
  if (requires.chassis !== undefined) {
    // Quoted on every arm. Inside [[ ]] there is no word splitting so the
    // answers coincide either way, but the right-hand side is a glob pattern
    // and the shipped bundles already spell one of the three arms this way -
    // an unquoted expansion here was the odd one out.
    if (requires.chassis === "laptop") exprs.push("[[ \"$CHASSIS_TYPE\" == laptop ]]")
    else if (requires.chassis === "vm") exprs.push("[[ \"$CHASSIS_TYPE\" == vm ]]")
    else if (requires.chassis === "!vm") exprs.push("[[ \"$CHASSIS_TYPE\" != vm ]]")
    else return null
  }
  if (exprs.length === 0) return null
  return exprs.join(" && ")
}

// Structured requires ({chassis} and/or {binary}) emitted as a `w` guard
// in the same batch shape. An unknown shape hides the row.
//
// It does not LOG one, and the previous version of this comment said it did.
// A pure library has no logger, and a row silently deleted by a typo in a
// config file is the worst kind of surprise, so the honest options are to give
// the library a channel or to stop claiming one: the refusal is visible in the
// emitted script as an unconditional `echo <uid>:w:0`, which is at least
// checkable, and Menu's own log reports the batch that carried it.
function requiresGuard(uid, requires) {
  const expr = requiresExpr(requires)
  if (expr === undefined) return ""
  if (expr === null) return hideLine(uid)
  return guardLine(uid, "w", expr)
}

// A page id and an item id both reach the reader through the echo
// argument, and neither is sanitized the way a `when` expression is, so
// the verdict token is assembled as data and quoted in one piece. An
// apostrophe in a page or item id then stays inside the argument instead
// of ending it and running whatever follows.
function hideLine(uid) {
  return "echo " + shellQuote(uid + ":w:0") + "\n"
}

function guardLine(uid, tag, expression) {
  if (typeof expression !== "string" || expression.trim() === "") return ""
  // `expression` is config-authored shell source by design and stays that
  // way: when/checked/disabled are a trusted local-config compatibility
  // surface evaluated by one batched bash run, not a data-only API, and
  // this is the only place the menu concatenates it. Extension or remote
  // configuration that must not be able to run source has to arrive as a
  // structured action descriptor (argv plus a call target), never as text
  // on this path. Only the verdict token is data, and it is quoted.
  // A trailing semicolon in the expression is stripped rather than doubled,
  // so the emitted braces stay well-formed bash.
  const expr = expression.trim().replace(/;+$/, "")
  if (expr === "") return ""
  return "if { " + expr + "; } >/dev/null 2>&1"
    + "; then echo " + shellQuote(uid + ":" + tag + ":1")
    + "; else echo " + shellQuote(uid + ":" + tag + ":0") + "; fi\n"
}

// Flatten all selectable items across all pages into search entries.
// Each entry carries its breadcrumb path: the chain of submenu pages from
// the entry page down to the owning page, so hits can show WHERE they live
// (omarchy-style). Unreachable pages contribute their own title only.
// Sub-bundle spanning an entry's reachable pages: the unified catalog holds
// every menu, but search (and the external-half gate) span only the opened
// entry's tree - the way one-file-per-menu scoped both before. Reachability
// follows submenu links inside `base`; `extraIds` (user-extension pages,
// always searched, as before) join the seeds. The entry names the bundle's
// own entry so breadcrumbs read relative to the opened page, as before.
function scopeBundle(base, entryId, extraIds) {
  const seeds = []
  const seed = (id) => {
    if (typeof id !== "string" || id === "" || base.byId[id] === undefined) return
    if (seeds.indexOf(id) < 0) seeds.push(id)
  }
  seed(entryId)
  if (seeds.length === 0) seed(base.entry)
  if (Array.isArray(extraIds)) for (let i = 0; i < extraIds.length; i++) seed(extraIds[i])
  const seen = Object.create(null)
  const queue = seeds.slice()
  for (let i = 0; i < seeds.length; i++) seen[seeds[i]] = true
  // Cursor, not shift(): a page graph this walks is the opened menu's whole
  // reachable set, and shifting moves the tail of the queue for every page.
  let head = 0
  while (head < queue.length) {
    const id = queue[head++]
    const pg = base.byId[id]
    if (!pg || !Array.isArray(pg.items)) continue
    for (let i = 0; i < pg.items.length; i++) {
      const it = pg.items[i]
      if (!it || it.type !== "submenu" || typeof it.page !== "string" || it.page === "") continue
      if (seen[it.page] === true || base.byId[it.page] === undefined) continue
      seen[it.page] = true
      queue.push(it.page)
    }
  }
  const pages = base.pages.filter(p => seen[p.id] === true)
  const byId = Object.create(null)
  for (let i = 0; i < pages.length; i++) byId[pages[i].id] = pages[i]
  let entry = base.entry
  if (typeof entryId === "string" && entryId !== "" && seen[entryId] === true) entry = entryId
  else if (byId[base.entry] === undefined) entry = pages.length > 0 ? pages[0].id : base.entry
  return {
    entry: entry,
    pages: pages,
    byId: byId
  }
}

function buildIndex(bundle) {
  // parent page id -> set of child page ids (via submenu items).
  // Prototype-less throughout: every key here is a page id, so a page named
  // "toString" or "__proto__" would otherwise be read as an inherited member -
  // and `seen["__proto__"] = true` is silently ignored, which made such a page
  // look already-visited and drop it out of the walk entirely.
  const childrenOf = Object.create(null)
  for (const page of bundle.pages) {
    for (let i = 0; i < page.items.length; i++) {
      const item = page.items[i]
      if (item.type !== "submenu" || typeof item.page !== "string"
        || item.page === "" || !bundle.byId[item.page]) continue
      if (!childrenOf[page.id]) childrenOf[page.id] = Object.create(null)
      childrenOf[page.id][item.page] = true
    }
  }

  // Shortest submenu chain from the entry page to each page, excluding
  // the page itself; cycles break via the visited set.
  const chainOf = Object.create(null)
  const queue = [{
    id: bundle.entry,
    chain: []
  }]
  const seen = Object.create(null)
  seen[bundle.entry] = true
  // Cursor, not shift(), for the reason scopeBundle states: the walk visits
  // every reachable page and shifting costs the queue's tail per page.
  let head = 0
  while (head < queue.length) {
    const cur = queue[head++]
    const kids = childrenOf[cur.id]
    if (!kids) continue
    for (const kidId in kids) {
      if (seen[kidId]) continue
      seen[kidId] = true
      const chain = cur.chain.concat([cur.id])
      chainOf[kidId] = chain
      queue.push({
        id: kidId,
        chain: chain
      })
    }
  }

  const entries = []
  for (let p = 0; p < bundle.pages.length; p++) {
    const page = bundle.pages[p]
    // Paths read relative to the main menu: the entry page names no prefix,
    // so neither it nor any chain carries it. "Vibranium > Settings" is just
    // "Settings" - and the entry page's own rows carry no breadcrumb at all.
    const chain = (chainOf[page.id] || []).filter(pid => pid !== bundle.entry)
      .map(pid => bundle.byId[pid].label)
    const path = page.id === bundle.entry ? [] : chain.concat([page.label])
    buildPageIndex(page, path, entries)
  }
  return entries
}

// Index entries for ONE page, appended to `into`. `path` is the breadcrumb
// whose words join every row haystack, so location terms work as search
// tokens ("ins pack" finds Arch Package via its Install breadcrumb).
//
// Shared by buildIndex (bundle pages, which resolve `path` from the submenu
// chain) and Menu.indexExternal (injected pages, which have no bundle parent
// and pass a bare [page.label]). The entry shape is defined here alone so an
// externally indexed row is indistinguishable to search() and jumpTo().
function buildPageIndex(page, path, into) {
  if (!page || !Array.isArray(page.items) || !Array.isArray(into)) return into
  const breadcrumb = Array.isArray(path) ? path : [page.label]
  // Path words join the haystack so location terms work as search
  // tokens ("ins pack" finds Arch Package via its Install breadcrumb).
  const hayBase = breadcrumb.join(" ")
  const hayBaseLower = hayBase.toLowerCase()
  // Deduplicate path words already present in item.hay by building
  // a quick Set per entry? Instead keep it simple: the per-item hay
  // is already deduped, concatenating the already-lowercased base
  // avoids a second toLowerCase per selectable row. An empty breadcrumb
  // (the entry page names no prefix) contributes nothing - appending it
  // would leave a trailing space that splits into a phantom empty word.
  const items = page.items
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    if (!item.selectable || item.label === "") continue
    // item.hay is already lowercased and deduped; hayBaseLower is
    // lowercased once per page.
    const hay = hayBaseLower !== "" ? item.hay + " " + hayBaseLower : item.hay
    into.push({
      pageId: page.id,
      // No pageTitle: the entry carried one and nothing read it. The group
      // separator renders the breadcrumb from `path`, because rows keep
      // their own subtexts, and the page is reachable by pageId for
      // anything that needs the page object.
      path: breadcrumb,
      row: i,
      label: item.label,
      hay: hay,
      words: hay.split(" ")
    })
  }
  return into
}

// Score one haystack against the query. Exact substrings win (earlier and
// word-start positions rank higher), and their scores live in a band above
// everything the word path can pay out for the same query.
//
// That band cannot be a constant. The word path is worth 10 a character plus
// 5 for consuming a whole word, and it never consumes a word for fewer than
// one character, so its ceiling is 15 * q.length - a long query climbs past
// any constant, and an exact hit then ranks below a scattered one. String(q)
// because indexOf folds a non-string needle and the band belongs to the
// needle that was searched for.
//
// Inside the band the position is scored against a FIXED reference length
// rather than the hay's own. Scoring against the hay's own length looks
// tidier and is wrong here: a hay is the row's label plus its metadata plus
// its breadcrumb, so a row on a deeply nested page carries a longer hay and
// an early match inside it would outrank an earlier match in a short hay -
// the breadcrumb would decide the rank. A fixed reference keeps the ordering
// absolute, while the 999
// buckets spread over the whole reference keep it from collapsing. A fixed
// reference has no clamp in it, and a clamp is a tie: a formula that folded
// every match past ~200 chars onto one bucket would let a scattered fuzzy hit
// at 20 outrank a real match buried in a description.
// The reference is far above any real hay - rows reach ~350 characters once
// descriptions and option lists expand - and the 9999 buckets over it leave
// more than two per character, so neighbouring positions stay strictly
// ordered across every length a hay can actually reach. The floor only
// applies past 4096 characters, where a row is pathological either way and a
// tie costs nothing: a hay that long is one no real row reaches.
//
// Otherwise the query must decompose into word prefixes in CONSECUTIVE words -
// "fcap" hits "FPS cap", but "codec" does not hit "Flash the screen" from
// scattered letters, and "theme" does not reach "the" plus "me" out of
// "medium". A word that does not continue the query ends the attempt rather
// than being stepped over; every start position is tried and the best score
// wins, the earliest start breaking a tie. Predictable beats clever for menus.
// `words` is the pre-split haystack (built once per index entry, not per
// keystroke).
function fuzzyScore(hay, words, q) {
  if (q === "") return -1
  const idx = hay.indexOf(q)
  if (idx >= 0) {
    const wordStart = idx === 0 || hay[idx - 1] === " "
    const band = 15 * String(q).length
    // The reference is a literal rather than a module var: the library's
    // top-level surface is part of its contract, and one more declaration
    // would be one more name to keep in step with it.
    const ref = 4096
    const share = idx >= ref ? 0 : Math.floor(9999 * (ref - idx) / ref)
    return band + (wordStart ? 1500 : 500) + share
  }

  let best = -1
  for (let start = 0; start < words.length; start++) {
    let qi = 0
    let score = 0
    for (let w = start; w < words.length && qi < q.length; w++) {
      const word = words[w]
      if (word.charCodeAt(0) !== q.charCodeAt(qi)) break
      let take = 1
      while (take < word.length && qi + take < q.length
        && word.charCodeAt(take) === q.charCodeAt(qi + take)) take++
      qi += take
      score += 10 * take + (take === word.length ? 5 : 0)
    }
    if (qi === q.length && score > best) best = score
  }
  return best
}

// --- incremental search cache ---
// Menu typing is sequential: "p" -> "po" -> "pow" -> "power". Re-scanning
// the full 80-entry index per keystroke is already cheap (<0.5ms), but
// filtering the previous hit set when the query only grows is O(hits)
// instead of O(index) and avoids re-scoring 90% of rows on every press.
var _searchCacheIndex = null
var _searchCacheLen = -1
var _searchCacheQ = ""
var _searchCacheEntries = null
var _searchCacheHitSet = null

// Queries already scored against THIS index, oldest first, as
// { q, hits, rows }. The incremental cache above only helps while the query
// GROWS; backspacing ("power" -> "powe" -> "pow") is a shrink, and a query
// that is not a prefix of the last one is a full scan of the index plus a
// full sort of its hits. Those keys were scored seconds ago against the same
// index, so their hit set and capped projection are still exact. Bounded to
// eight queries because a hit set can be the whole index and the window only
// has to span one editing session. Named with the other cache vars because
// this is module state, not a published function.
var _searchCacheRecent = []

// Tokenized AND-search: every space-separated term must match on its own
// (substring, or word-prefix like "fcap" -> "FPS cap"). "ins pack" finds
// "Install" pages containing "Package"; single garbage tokens reject.
//
// Performance notes:
// - hay is lowercased + deduped at build time, and runs far shorter than a
//   raw label + metadata + breadcrumb concatenation would: measured on the
//   shipped main menu at ~37 chars average, ~135 at the longest
// - hayBase lowercased once per page, not per row
// - per-entry fast reject: token longer than hay -> skip scoring
// - incremental path: when query grows as a string prefix, scan only
//   previous hits (typically 2-8 entries) instead of the full index
// - recent-query path: a query already scored in this editing session
//   (backspace, a removed token, toggling between two queries) is restored
//   from a bounded cache instead of rescanning the index
//
// The index is not a fixed size and must not be reasoned about as one. It is
// the bundle's own selectable rows PLUS every externally registered row
// (Menu.indexExternal), and the external half is the machine's: one entry per
// installed font family, per keybinding, per anything else a picker
// enumerates off-disk. On a machine with 337 fonts the merged index is ~375
// entries even before the settings bundle merges in, so a per-keystroke
// figure quoted against "the settings bundle" alone understates the real scan
// by the whole external half.
function search(index, query) {
  const q = query.toLowerCase().trim()
  // Length-aware identity lives in SearchLib.sameCacheIndex, reached here
  // through this file's own SL alias: the same array with a
  // different length is a different index.
  // Menu.indexExternal appends entries into the array it already searched,
  // and an identity-only key answered the next identical query from before
  // the append, without the new rows. The recent map rides the same test: a
  // hit set scored against another index is not evidence about this one.
  const sameIndex = SL.sameCacheIndex(_searchCacheIndex, _searchCacheLen, index)
  if (!sameIndex) {
    _searchCacheRecent = []
  }
  if (q === "") {
    _searchCacheIndex = index
    _searchCacheLen = index.length
    _searchCacheQ = ""
    _searchCacheEntries = []
    _searchCacheHitSet = []
    return []
  }

  // Cache hit: identical query on same index instance.
  if (SL.identicalQuery(sameIndex, _searchCacheQ, q, _searchCacheEntries)) {
    return _searchCacheEntries.slice()
  }

  // Cache hit: a query already scored in this editing session. Restore it as
  // the active cache as well, so the next forward key narrows from these hits
  // instead of falling back to a full scan. Its projection was capped for
  // this exact query length, which is the only input the cap reads.
  function restoreRecent() {
    for (let i = 0; i < _searchCacheRecent.length; i++) {
      const recent = _searchCacheRecent[i]
      if (recent.q !== q) continue
      _searchCacheIndex = index
      _searchCacheLen = index.length
      _searchCacheQ = q
      _searchCacheHitSet = recent.hits
      _searchCacheEntries = recent.rows
      const at = _searchCacheRecent.indexOf(recent)
      if (at >= 0) {
        _searchCacheRecent.splice(at, 1)
        _searchCacheRecent.push(recent)
      }
      return recent.rows.slice()
    }
    return null
  }
  const recentRows = restoreRecent()
  if (recentRows !== null) return recentRows

  // No empty-token guard: `q` is trimmed and non-empty past the check above,
  // and a non-empty string always yields at least one token, so the branch was
  // unreachable. (The same dead guard sat in SearchLib.searchRecords and
  // ClipboardLib.searchEntries.)
  const tokens = SL.splitTokens(q)

  // Decide scan source: full index vs incremental subset.
  let source = index
  if (SL.narrowsQuery(sameIndex, _searchCacheQ, q, _searchCacheHitSet)) {
    // Query grew as a prefix (user typed another char or added a token);
    // new hits are a subset of the previous hits, so scanning the cached
    // hit set is O(hits) instead of O(index) -> the per-keystroke win.
    source = _searchCacheHitSet
  }

  // Parallel arrays, not one object per hit. A one-character query matches a
  // large share of the index, and minting a fresh {entry, score, pos} for
  // every hit is thousands of short-lived objects on the GUI thread per
  // keypress - garbage the next collection has to walk while the user is still
  // typing. The scan position never has to be stored: it IS the array index.
  function scanSource() {
  const hitEntries = []
  const hitScores = []
  const n = source.length
  const tlen = tokens.length

  // Single-token fast path: avoids inner token loop overhead for the
  // common case of typing the first word.
  if (tlen === 1) {
    const tok = tokens[0]
    for (let i = 0; i < n; i++) {
      const entry = source[i]
      const hay = entry.hay
      if (SL.lengthReject(tok, hay)) continue
      const s = fuzzyScore(hay, entry.words, tok)
      if (s >= 0) {
        hitEntries.push(entry)
        hitScores.push(s)
      }
    }
  } else {
    // Longest token first -> the cheapest reject runs first. The AND total
    // is a sum, so the evaluation order never moves the score or the rank.
    const ordered = tokens.slice().sort((a, b) => b.length - a.length)
    for (let i = 0; i < n; i++) {
      const entry = source[i]
      const hay = entry.hay
      let total = 0
      let ok = true
      for (let t = 0; t < tlen; t++) {
        const tok = ordered[t]
        if (SL.lengthReject(tok, hay)) { ok = false; break }
        const s = fuzzyScore(hay, entry.words, tok)
        if (s < 0) { ok = false; break }
        total += s
      }
      if (ok) {
        hitEntries.push(entry)
        hitScores.push(total)
      }
    }
  }
  return { entries: hitEntries, scores: hitScores }
  }
  const scanned = scanSource()
  const hitEntries = scanned.entries
  const hitScores = scanned.scores

  // If we scanned an incremental subset, the subset already respects the
  // previous query's filter, but the full index might contain entries that
  // match the new query without matching the old prefix (e.g. previous
  // "pow" -> "power" is prefix, so subset is valid; but "pow" -> "wol"
  // is not a prefix, we already fell back to full scan). So subset path
  // is sound and we keep its results.

  // The incremental scan above is the per-keystroke win (O(hits) instead of
  // O(index)); the sort stays. New token scores do NOT preserve the previous
  // rank order in general (e.g. "needle" -> "needle 2" reorders exact hits by
  // the new token's position term), so skipping the re-sort would change the
  // ranking, which is out of scope -> sort every path identically.
  //
  // The hit set is kept in SCAN order, before the sort, and ties rank by that
  // order. Both matter. A subset scan sees the entries in the order they were
  // stored, so storing them score-sorted made a tie rank by the previous
  // query's order, and the same final query listed equal hits differently
  // depending on whether it was typed or pasted. Scan order is index order by
  // induction (the full scan is, and a subset of an ordered set is), which is
  // exactly what a fresh search gives, and the explicit position tiebreak
  // stops the result depending on the engine's sort being stable.
  // Rank an ORDER ARRAY over the parallel hit arrays. The position term is
  // the array index, so equal scores keep scan order exactly as the previous
  // stable sort of score plus explicit position did - and only the returned
  // window is materialized, never the ranked whole.
  const m = hitEntries.length
  // The cap is on what is RETURNED and it grows with what the user has typed:
  // a one-character query ranks the index almost evenly, so handing back the
  // whole index makes the panel project a screenful of rows for a keystroke
  // that says nothing about which row is wanted. Below five characters the
  // cap therefore scales with the query - `40 * q.length`, so ONE character
  // returns 40 and not the 200 the ceiling is: a four-character query gets 160
  // - and from five characters up the ceiling is the whole allowance. The hit
  // set stays complete either way, because the incremental branch above scans
  // it - anything past the cap is one more keystroke away, never one lost.
  const capLen = q.length >= 5 ? 200 : 40 * q.length
  const cap = m > capLen ? capLen : m
  const out = new Array(cap)
  if (m === 1) {
    out[0] = hitEntries[0]
  } else if (m > 1) {
    const order = new Array(m)
    for (let i = 0; i < m; i++) order[i] = i
    order.sort((a, b) => hitScores[b] - hitScores[a] || a - b)
    for (let i = 0; i < cap; i++) out[i] = hitEntries[order[i]]
  }

  _searchCacheIndex = index
  _searchCacheLen = index.length
  _searchCacheQ = q
  _searchCacheHitSet = hitEntries
  _searchCacheEntries = out
  // Remember this query for the editing session (see _searchCacheRecent): the
  // scan-order hits feed the next forward key's subset scan, and the capped
  // projection is what a backspace to this query returns. A recent-hit query
  // returned above, so this list never holds a duplicate.
  _searchCacheRecent.push({ q: q, hits: hitEntries, rows: out })
  if (_searchCacheRecent.length > 8) _searchCacheRecent.shift()
  return out
}

// Filter counter shared with the app launcher (its normal + action modes)
// and the power menu. Both the shell and the matcher are SearchLib's, so the
// menu reaches it directly and the launcher's copy of the pool never enters
// this file's import graph.
function filterCounter(pool, query, cap, tiebreak) {
  return SL.filterRecords(pool, query, cap, tiebreak)
}

// Scoped in-page quick-filter for the menu's "/" trigger: narrows the
// CURRENT page's visible fields to those matching every token, AND-style.
// Unlike the cross-page buildIndex/search pipeline this never leaves the
// page - no breadcrumbs, no grouping, just a live trim of what's already
// on screen. `items` should already be guard-visible.
function scopedFilter(items, query) {
  const list = StoreGuards.asList(items)
  const q = (query ?? "").toLowerCase().trim()
  if (q === "") return list.slice()
  const tokens = q.split(/\s+/).filter(t => t !== "")
  const out = []
  for (let i = 0; i < list.length; i++) {
    const it = list[i]
    if (!it || typeof it !== "object") continue
    if (it.type === "separator") continue
    // The visible-only hay (hayForFilter) is built on the first keystroke that
    // looks at this row and cached against the row object, so every later
    // keystroke over the same page only pays for the raw join and a compare.
    // The cache is a WeakMap and not a property on the row: scopedFilter is
    // documented as read-only over its input, and a row may be a host object
    // that refuses new fields. Rows that arrive with the hay already stamped
    // (older call sites) are read as-is.
    let hay = it.hayNoMeta
    if (typeof hay !== "string") {
      const raw = hayFilterRaw(it)
      const cached = _filterHay.get(it)
      if (cached !== undefined && cached.raw === raw) {
        hay = cached.hay
      } else {
        hay = hayFilterOf(raw)
        _filterHay.set(it, { raw: raw, hay: hay })
      }
    }
    let ok = true
    for (let t = 0; t < tokens.length; t++) {
      if (hay.indexOf(tokens[t]) < 0) {
        ok = false
        break
      }
    }
    if (ok) out.push(it)
  }
  return out
}

// Substitute %v placeholders in command templates.
//
// RAW. The value lands in a command that Menu.runCommand hands to
// `/bin/bash -c`, so a value carrying `;`, `$(...)`, a backtick, a newline or
// a glob is shell source by the time it runs - and a text row's value is
// whatever the user just typed (Entry's submit path), so the injection is
// reachable without a config author doing anything unusual. The value is data
// at every call site here, never source, and the guard emitter already treats
// its data half that way (guardLine runs the verdict token through shellQuote).
//
// Kept separate from substituteQuoted because runCall substitutes into a
// Registry argv array where a shell never sees the value and quoting it would
// pass the quotes through as part of the argument.
function substitute(command, value) {
  if (typeof command !== "string" || command === "") return ""
  return command.split("%v").join(String(value))
}

// substitute for a template that is about to be executed by a shell: the value
// is quoted as ONE word, so a space does not word-split it, a glob does not
// expand, and a metacharacter stays inside it.
function substituteQuoted(command, value) {
  if (typeof command !== "string" || command === "") return ""
  return command.split("%v").join(shellQuote(String(value)))
}

// Group search hits into page sections for result rendering: one bucket
// per owning page, opened by the page's best hit, and rank order inside it.
// A submenu hit stays on the page that OWNS it - the "Animations" link
// stays under "Settings > Hyprland > Appearance" while the rows inside
// the Animations page group under
// "Settings > Hyprland > Appearance > Animations". Filing the link under
// its target page instead collapsed both into one pile headed by the
// parent breadcrumb, which reads as if the child rows live on the parent.
// Hidden items (guard "when") drop out; separator rows open every group
// with a breadcrumb. Returns the flat rows array ready for the list model.
// Sectioning (bucket per owning page, separators opening each group) for
// a ranked hit set.
//
// `lookup` resolves a pageId to a page object. It is a function rather than
// a byId map because an externally indexed hit names a page the bundle never
// declared - Menu.indexExternal registers rows under a dynamic page id - and
// a bundle-only map drops every such hit, which surfaces as "No matches"
// for a query that demonstrably has one. Menu.pageById already spans bundle,
// dynamic and option pages, so it is the resolver both halves need.
//
// A hit that resolves to nothing is still rendered, from the entry alone:
// the entry carries label, hay and row, which is what the row needs to draw
// and what jumpTo needs to resolve. Skipping unresolved pages outright would
// reinstate the silent drop for a page that is registered but not yet
// loaded.
//
// EVERY row this returns is keyed, which is the contract the caller's keyed
// model depends on: it refuses an install on the first unkeyable row rather
// than dropping that one, so an unkeyed row here is a whole-projection
// failure and not a one-row gap. A resolved row is keyed by the item; an
// entry-only row is keyed from the entry. A row that can be neither drawn nor
// keyed does not belong in the result.
//
function groupSearchResults(hits, lookup, isVisible, query) {
  const rows = []
  const buckets = []
  // Prototype-less, like every other map keyed by a page id in this file: a
  // page named "constructor" or "__proto__" read as an existing bucket here and
  // threw on the push below, for every search that reached the page.
  const bucketIndex = Object.create(null)
  // The query, lowercased/trimmed like every other search comparison, is what
  // lets a hit be read as a SECTION rather than as an entry. Absent it (a
  // caller that only wants the sectioning) no hit is hoisted, which is the
  // behaviour every pre-section caller already had.
  const q = typeof query === "string" ? query.toLowerCase().trim() : ""
  // Whether a hit is a SECTION - a row that opens a page, under the query's
  // own name - rather than an entry found inside one.
  //
  // WHY THE LINK NEEDS ITS OWN TIER. Typing a page's name matches the page's
  // link and every row inside it (the breadcrumb joins the row hay), and the
  // link is one row competing against dozens: "blur" ranked the Blur link
  // third and filed it in the Appearance bucket, under "Blurred backdrop"
  // and "Blur strength" from Lock screen, while fifty Blur rows filled the
  // buckets after it. The user asked for a section by name and got everything
  // except it. Hoisting the link turns the answer into what was typed: the
  // section first, its matching entries below.
  //
  // Label-only, literal, and only for a submenu that actually opens a page. A
  // link that matched through its description ("Configure blur under
  // windows") is an entry like any other - a description is not a name. A
  // query of two words ("blur motion") is not a page name, so it stays filed.
  // And a submenu with no `page` is a dead row, not a destination, so it
  // cannot lead the list. Local rather than a top-level helper: the library's
  // declaration list is its published surface, and this is one caller's rule.
  const isSection = (hit, item) => {
    if (q === "") return false
    if (!item || item.type !== "submenu") return false
    if (typeof item.page !== "string" || item.page === "") return false
    return String(hit.label).toLowerCase().indexOf(q) >= 0
  }

  // A fresh copy per hit, every call. A copy cached by index entry would make
  // an identity comparison in the panel succeed where the live candidate
  // fails it, which is only a safe shortcut if the copy can never go stale -
  // and it can. Menu.refreshSectionCounts rewrites a submenu link's `sub` in
  // place ("N items") without replacing the index entry, so a cached row kept
  // a count the page had already moved past. The copy is also what makes "the
  // candidate changed" mean "the projection changed".
  //
  // Object.assign, NOT a spread literal. QML's JS engine rejects object
  // spread ("Expected token `}'") and the parse failure takes the whole
  // library down, which takes every menu surface with it - the node suite
  // accepts the syntax, so only the engine can catch this.
  function mergedRow(hit, item) {
    const row = Object.assign({}, item || {}, {
      label: hit.label,
      hay: hit.hay,
      path: hit.path,
      pageId: hit.pageId,
      row: hit.row
    })
    // An entry-only row has to be KEYED as well as drawn. The panel installs a
    // search projection through a keyed model, and its keying step refuses the
    // WHOLE install on the first row it cannot key instead of skipping that
    // row, so a hit carrying no `uid` took every other hit down with it - a
    // single registered picker row in the set was enough to answer a query
    // that demonstrably had results. The entry already holds the two halves
    // the key is composed from, and an entry that could not name its page is a
    // page whose rows are anonymous (normalizeItem keys a blank id by row
    // index), so this reproduces the key that row WOULD have had rather than
    // inventing one. A resolved item keeps its own uid, so the key a row
    // carries does not move when its page starts resolving.
    if (row.uid === undefined || row.uid === null)
      row.uid = hit.pageId + "#" + hit.row
    return row
  }
  const sections = []
  for (let i = 0; i < hits.length; i++) {
    const hit = hits[i]
    // A hit is only renderable if it can name itself. A row with no label
    // cannot be drawn and cannot be jumped to, so a malformed entry is
    // dropped rather than rendered as an empty row - which is what the
    // entry-only path below would otherwise produce for a bad pageId, a row
    // index past the end, or a non-numeric one.
    if (!hit || typeof hit.label !== "string" || hit.label === "") continue
    const page = typeof lookup === "function" ? lookup(hit.pageId)
      : (lookup ? lookup[hit.pageId] : null)
    const item = page ? page.items[hit.row] : null
    // A page that resolved but has no such row is a stale index entry, and
    // is dropped like any other malformed hit. A page that did NOT resolve is
    // the external case: the entry is the row.
    if (page && !item) continue
    if (page && item && typeof isVisible === "function" && !isVisible(item)) continue

    // Group by the page that owns the row. A submenu link belongs to its
    // parent page, not to the page it opens: grouping by the target merged
    // the link with the target's own rows under one parent header.
    const group = hit.pageId
    if (bucketIndex[group] === undefined) {
      bucketIndex[group] = buckets.length
      buckets.push([])
    }
    // item is null for a page outside the lookup - an externally registered
    // one - so the entry supplies the fields a row draws from. The `type` and
    // `call` the entry cannot carry are the reason an external row needs its
    // page: without them it would render and do nothing on Enter.
    const merged = mergedRow(hit, item)
    // A submenu link whose own LABEL spells the query is the section the user
    // is looking for, and it is hoisted instead of filed (see isSectionHit).
    // The test is on the label, not on the hit, because the hit only says the
    // row matched somewhere: the breadcrumb a section's children inherit means
    // every child of "Blur" matched the moment the user typed the page name,
    // and those children outrank and outnumber the link that names the page.
    if (isSection(merged, item)) {
      sections.push(merged)
      continue
    }
    // `hits` arrives ranked, so appending keeps rank order inside the
    // bucket. Unshifting a submenu to the head of the page it opens would
    // put a weaker match above the stronger ones filed with
    // it: typing "p" in the main bundle would lead the results with "Install"
    // (1920, matched through its description) rather than the best hit
    // "PWA" (2000, matched on its label), and the cursor the caller seats
    // on row 0 would land on the wrong row.
    buckets[bucketIndex[group]].push(merged)
  }
  // Sections lead the list, in hit order - rank order among themselves, since
  // the hit set is already sorted. Their own bucket is skipped entirely below
  // (`sections` rows never enter one), so no link is listed twice. The header
  // names the group rather than a breadcrumb: these rows live in different
  // places, and where each one lives is the thing the header cannot say.
  if (sections.length > 0) {
    rows.push({
      type: "separator",
      uid: "sep:sections",
      label: "Sections"
    })
    for (let s = 0; s < sections.length; s++) rows.push(sections[s])
  }
  // The group header names where the bucket lives: the first row's
    // breadcrumb, which is the best hit's location and the page the rest
    // of the bucket shares it with.
    function groupHeader(bucket, index) {
      const head = bucket[0]
      const headPath = StoreGuards.asList(head && head.path)
      const headLabel = headPath.join(" > ")
      if (headLabel === "") return
      rows.push({
        type: "separator",
        uid: "sep:group" + index,
        label: headLabel,
      })
    }

  for (let b = 0; b < buckets.length; b++) {
    // The group header names where the bucket lives: the first row's
    // breadcrumb, which is the best hit's location and the page the rest
    // of the bucket shares it with. Entries below keep their own
    // subtexts; the path moves out of them and onto this line, which is
    // also what sizes the card for it (a labelled separator carries its
    // label like any row's). Every bucket with a location opens with one,
    // including the first: without it the head group reads as unlocated.
    //
    // A bucket with NO breadcrumb (the entry page) opens with no header at
    // all, not an empty one. The empty header rendered as a plain hairline
    // between two result groups - and next to a submenu's own bare separator
    // it read as a separator row copied out of that submenu. An unlocated
    // bucket simply runs on until the next named header; the absence of a
    // header is not a thing to draw. (An empty bucket, every row of it
    // hoisted into Sections above, opens nothing for the same reason.)
    groupHeader(buckets[b], b)
    for (let j = 0; j < buckets[b].length; j++) {
      rows.push(buckets[b][j])
    }
  }
  return rows
}

// --- provider hook dispatch ---
// A provider surface overlays per-row behavior onto bundle-declared rows by
// id. WHICH surfaces exist is controller state - the registry outlives any
// single open, and a surface may register before the menu does - but what a
// hook's return value MEANS is a value contract, and that is what lives
// here.
//
// Each family below owns exactly one accept rule. A hook returning anything
// outside its rule has declined, and the caller's fallback then decides the
// row. Passing a fallback outside the accepted set (null is the usual
// choice) is what makes a decline distinguishable from an answered false,
// because the dispatcher hands the fallback back verbatim.
//
// Hooks are invoked as methods of the surface, so a surface written against
// `this` sees itself and not the dispatching controller.

// Raw value: a nullish or empty answer is a decline, anything else passes
// through uncoerced so a non-string value stays non-string.
function hookValue(provider, name, item, ctx, fallback) {
  if (!provider) return fallback
  const hook = provider[name]
  if (typeof hook !== "function") return fallback
  const r = hook.call(provider, item, ctx)
  return r !== null && r !== undefined && r !== "" ? r : fallback
}

// Strict boolean: only true/false is an answer, so a truthy stand-in a
// surface returned by mistake cannot flip a row the bundle owns.
//
// The three-line dispatch is spelled out rather than delegated to hookValue
// with a sentinel fallback: a sentinel would be a sixth module-level binding,
// and this library's namespace IS its top-level declarations (the surface is
// pinned by tests/js/menu.test.mjs), so a private marker is not available.
function hookBool(provider, name, item, ctx, fallback) {
  if (!provider) return fallback
  const hook = provider[name]
  if (typeof hook !== "function") return fallback
  const r = hook.call(provider, item, ctx)
  return r === true || r === false ? r : fallback
}

// Ran-or-not: true means the surface owned the action, false means it
// declined and the caller keeps the default. `arg` is the action's own
// payload (the new number, the staged values, the requested toggle state)
// and rides ahead of the context.
//
// There is no fallback to hand back, and `false` is the answer for every
// reason a hook did not run: "it ran" is not something to be toggled by a
// truthy stand-in, and a caller that needs to tell "declined" from "absent"
// asks hookValue instead.
function hookRan(provider, name, item, arg, ctx) {
  if (!provider) return false
  const hook = provider[name]
  if (typeof hook !== "function") return false
  return hook.call(provider, item, arg, ctx) === true
}

// A row's staged-confirmation descriptor. A surface's own descriptor wins
// over the one the bundle declared: the surface knows the row's live state
// and can refuse a confirmation the bundle would otherwise arm. Absent
// either, the row arms nothing and its dropdown stays a plain dropdown.
//
// The provided side is tested with `!== null && !== undefined`, so false, 0
// and "" are ANSWERS - a surface arms nothing by handing back a falsy value,
// and that is distinguishable from declining because null is the decline. The
// bundle side must be an object: a string or a number there is a bundle that
// does not know the shape, and arming a confirmation from it would arm
// whatever the row's renderer happens to do with a truthy scalar.
function resolveConfirm(item, provided) {
  if (provided !== null && provided !== undefined) return provided
  const declared = item === null || item === undefined ? null : item.confirm
  return declared !== null && typeof declared === "object" ? declared : null
}

// Staged-flow helpers: pure, unit-testable, no Menu import.
function isFlow(item) {
  return !!item && Array.isArray(item.flow) && item.flow.length > 0
}

function flowStep(item, idx) {
  if (!isFlow(item)) return null
  const i = Number(idx) || 0
  if (i < 0 || i >= item.flow.length) return null
  return item.flow[i]
}

function flowCount(item) {
  return isFlow(item) ? item.flow.length : 0
}

// The stage a flow renders next, starting at `from`. A stage carrying
// skipUnless shows only when SOME earlier stage stored its value, never
// stage zero alone, so a select-first flow and an editor-first flow
// share one rule. Unmatched stages are stepped over. The result is an
// index the caller compares against flowCount: at or past the end means
// the flow is done and commits.
function nextFlowIndex(item, from, stored) {
  const count = flowCount(item)
  let next = from
  while (next < count) {
    const step = flowStep(item, next)
    if (step && step.skipUnless !== undefined && step.skipUnless !== "") {
      let match = false
      for (const k in stored) {
        if (String(stored[k]) === String(step.skipUnless)) { match = true; break }
      }
      if (!match) { next++; continue }
    }
    break
  }
  return next
}

// --- row presentation projections ---
//
// What a row PUTS ON SCREEN, as values: the copy a stage overrides, the
// text a value slot shows, the width that slot reserves, the option a
// stored value points at, the number typed into an editor, and the
// geometry of the inline dropdown. All of it is pure over the payload
// the model already carries, so a bundle's rows can be checked without a
// shell. None of it reads Menu, a QML item or the state store: the row
// reads those and hands the answer over.

// The shape a row takes at rest: which second line it spends, if any. THE
// rule - MenuPanel's model-side estimate and Entry's own layout both ask this,
// so the card's height and the row it holds cannot classify a row differently.
//
// `providerSub` is the sub line a provider overlay would draw for this row,
// already resolved by the caller: a provider call is the caller's business
// (this library never reads Menu), and the delegate has that very string in
// hand anyway because it renders it. An empty or non-string provider value is
// "no override", and the row's own copy decides on its own.
//
// ORDER MATTERS. A theme row spends its second line on the swatch strip, so
// "theme" is asked first, whatever copy the row carries; a row with any sub
// copy - provider, declared, leading or trailing accent - is "sub"; a row with
// none is a single title line.
function restKind(item, providerSub) {
  if (!item) return "line"
  if (typeof item.light === "string" && item.light !== "") return "theme"
  if (typeof providerSub === "string" && providerSub !== "") return "sub"
  if (item.sub !== undefined && item.sub !== null && String(item.sub) !== "") return "sub"
  if (typeof item.subLead === "string" && item.subLead !== "") return "sub"
  if (typeof item.subAccent === "string" && item.subAccent !== "") return "sub"
  return "line"
}

// Copy a flow stage declares for itself, or null when it declares none.
// A stage's own string wins while that stage renders - an EMPTY one too,
// which is how a stage deliberately blanks the line - and a collapsed row
// shows the top-level copy. A caller keeps its own copy on null. An
// empty accent is spelled at the call site, because an empty accent and
// no accent render the same and only the caller knows that.
function stageText(expanded, step, key) {
  if (!expanded || !step) return null
  const v = step[key]
  return typeof v === "string" ? v : null
}

// A stage's unit overrides the row's own, trimmed, because a stage
// descriptor carries the literal it wants shown. A stage that declares
// no unit keeps whatever the row declared. (The row's own suffix is
// unitSuffix, above.)
//
// The same rule as unitSuffix once a stage does declare one: an empty unit
// renders nothing, not a lone space, and null declares nothing at all.
function stageUnitSuffix(stageUnit, fallback) {
  if (stageUnit === undefined) return fallback
  const u = String(stageUnit).trim()
  return u === "" ? " " : " " + u
}

// The seed an editor opens with, or null when the caller keeps its own
// seed. A flow stage owns its seed: a text stage carries only what its OWN
// stage stored, so a text stage with nothing stored opens empty and shows
// its placeholder. The row's own value is NOT a fallback here - that value
// belongs to the row's primary kind, which in a number-first flow is the
// minutes, and a command field opening on "15" is a wrong answer, not a
// default.
function stageSeedText(isFlow, kind, stored) {
  if (!isFlow) return null
  if (kind !== "text") return ""
  if (stored === undefined || stored === null) return ""
  const s = String(stored)
  return s === "" ? "" : s
}

// Reading for a numeric slot: the provider's display override when it
// answered one, else the row's own value at the row's own precision. The
// test is `!== null` and not a nullish check because null IS the decline
// hookValue hands back - an override is any non-empty value, uncoerced.
// Bounds and drift are the caller's; nothing here clamps or quantizes.
function numberDisplay(override, value, decimals, suffix) {
  if (override !== null) return override
  return value.toFixed(decimals) + suffix
}

// Width a right-hand value slot reserves. A shared column wins when the
// panel published one (it measures the widest value on the page so little
// bars form one vertical line); a lone row reserves its own measured
// content plus a pad, capped so one long value cannot push the label out
// of the card. `unified` of 0 means no shared column.
function valueSlotW(unified, contentW, pad, cap) {
  if (unified > 0) return unified
  return Math.min(contentW + pad, cap)
}

// Label of the option a stored value points at, or the raw value when no
// option claims it: a value the bundle no longer offers still shows what
// it holds instead of an empty slot. Options come from the bundle, so the
// comparison is strict - a number option never matches a stored string.
//
// An option with no label shows its value, as the options page does for the
// same option; returning the bare `label` printed "undefined" into the slot.
function optionLabelFor(options, value) {
  for (let i = 0; i < options.length; i++) {
    const o = options[i]
    if (o.value === value) return o.label ?? String(o.value)
  }
  return String(value)
}

// Index the dropdown cursor opens on: the option carrying the value, or
// the first option when none does, so Enter-Enter re-picks the stored
// choice without the arrows moving. The comparison is by text, unlike
// optionLabelFor: the cursor has to meet a value that comes back from a
// settings store as a string against an option that declares a number.
function optionSeedIndex(options, value) {
  for (let i = 0; i < options.length; i++) {
    if (String(options[i].value) === String(value)) return i
  }
  return 0
}

// Inline dropdown geometry. A long option list (codec selection) halves
// its height into two columns instead of scrolling forever; a short one
// keeps the single-column look. The fill is column-major, so the linear
// cursor walks top-to-bottom, and Left/Right page a whole column - a
// stride of 0 for a single column, where the key falls through to its
// next binding instead of moving nothing.
function optionColumnCount(count) {
  return count > 6 ? 2 : 1
}

function optionRowCount(count) {
  return count > 6 ? Math.ceil(count / 2) : count
}

function optionColumnStride(count) {
  return count > 6 ? Math.ceil(count / 2) : 0
}

function optionCellCol(index, count) {
  return count > 6 ? Math.floor(index / optionRowCount(count)) : 0
}

function optionCellRow(index, count) {
  return count > 6 ? index % optionRowCount(count) : index
}

// Leading number of editor input: an optional minus, digits, and an
// optional decimal point written either way, because a comma is what a
// locale keyboard types. Trailing junk after the digits is tolerated
// ("12 fps" reads 12); input that does not start with a number yields
// null, and the caller restores the real value rather than committing
// garbage. Callers clamp and quantize the result themselves.
//
// A leading dot (".5") and a plus sign are numbers too, and the typographic
// minus sign (U+2212, what a phone keyboard offers) reads as the minus: each
// of them reads as a number rather than as "not a number".
function leadingNumber(text) {
  const m = /^\s*([-\\u2212]?(?:\d+(?:[.,]\d+)?))/.exec(String(text))
  return m === null ? null : Number(m[1].replace("\u2212", "-").replace(",", "."))
}

// Which option a search query names exactly, or -1 when it names none.
// The query is read as the option's own label or value, either alone or
// qualified by the row's family label, because a query run together reads
// as "Family Option" and "Family-Option" both. A filtered select can then
// seat the option the user typed instead of always the first one. An empty
// query names nothing, deliberately: it expands the row and leaves the
// option cursor where the row's stored value put it.
//
// `query` is compared as handed over, and the option text is case-folded
// before it is compared, so the caller lowercases the query - which is what
// the search bar already does. A query that was not folded would match
// nothing, and folding it here would fold it twice for no gain.
//
// The fold is a local arrow rather than a module-level helper on purpose: a
// pragma library exports every top-level declaration, so a shared `optionText`
// was part of the public surface whether or not anyone asked for it. The one
// line below is the whole rule, and both readers spell it the same way.
function exactOptionIndex(options, query, family) {
  const q = String(query)
  if (q === "") return -1
  const lower = SU.lowerTrim
  const fam = SU.lowerTrim(family)
  const list = StoreGuards.asList(options)
  for (let o = 0; o < list.length; o++) {
    const opt = list[o] || {}
    // The fold, not `|| ""`: a value of 0 (the "never" of a timeout) is
    // falsy and would read as an option with no value, so "0" could not name
    // it. The fold itself turns null/undefined into empty and leaves 0 alone.
    const varLower = lower(opt.label)
    const valLower = lower(opt.value)
    if (q === varLower || q === valLower
      || q === fam + " " + varLower || q === fam + "-" + varLower)
      return o
  }
  return -1
}

// Which option a search query names, or -1 when it names none. The strict
// reading above is only half of what a user means by "the one that
// matched": they type the start of a name far more often than the whole
// of it, and a row that opened on its stored value in answer to "lat" was
// not reading the query at all. So the exact forms are tried first, to
// leave every query that already resolves unchanged, and the remainder is
// scored with the same matcher the row itself was found by (fuzzyScore),
// so the option the user half-typed is the one the cursor lands on.
//
// A tie answers -1 rather than picking a winner. A query that hits every
// option equally says nothing about which variant to show - the family
// name, which every option's value carries as its own prefix, is the case
// that matters, since that is the query a user types to open the family in
// the first place. Seating an arbitrary option there would walk the cursor
// off the row's stored value on a query that never mentioned a variant.
// The caller then leaves the cursor where the stored value put it, which is
// the right answer for "open this family"; -1 plus a coin flip is the only
// wrong one.
//
// `query` is compared as handed over, and the option text is case-folded
// before it is compared, so the caller lowercases the query - which is what
// the search bar already does, and what exactOptionIndex above documents.
function bestOptionIndex(options, query, family) {
  const exact = exactOptionIndex(options, query, family)
  if (exact >= 0) return exact
  const q = String(query)
  if (q === "") return -1
  // The same fold exactOptionIndex applies, for the same reason it is local.
  const lower = SU.lowerTrim
  const fam = SU.lowerTrim(family)
  const list = StoreGuards.asList(options)
  let best = -1
  let bestScore = 0
  let tied = false
  for (let o = 0; o < list.length; o++) {
    const opt = list[o] || {}
    const varLower = lower(opt.label)
    const valLower = lower(opt.value)
    if (varLower === "" && valLower === "") continue
    // Value first: it carries the family as a prefix, so a query naming the
    // family alone scores every option at once and ties, which is the case
    // the tie rule above exists for. The label and the two family-qualified
    // spellings are what discriminate a query that means the variant, and
    // the qualified ones are what let a multi-word query ("Osaka solar")
    // reach an option at all - a single hyphen-joined token is one word to
    // fuzzyScore and cannot match across the space.
    let score = 0
    const forms = [valLower, varLower, fam + " " + varLower, fam + "-" + valLower]
    for (let f = 0; f < forms.length; f++) {
      const text = forms[f]
      if (text === "") continue
      const s = fuzzyScore(text, text.split(" "), q)
      if (s > score) score = s
    }
    if (score <= 0) continue
    if (score > bestScore) {
      best = o
      bestScore = score
      tied = false
    } else if (score === bestScore) {
      tied = true
    }
  }
  return tied ? -1 : best
}

// --- keyboard routing ---
//
// Which panel route a key press takes, as a decision over state the panel
// hands over. Nothing here reads a delegate, a cursor, a focus sink or the
// Menu service, so the whole menu keyboard model is drivable without a QML
// item tree, and a key can be checked without building a card.
//
// The caller keeps every side effect. A route is a name plus an argument;
// the panel dispatches, so focus ownership stays where it was: the table
// never takes a focus sink and never names one.

// End of the model keyboard navigation can land on: the first selectable
// index scanning from the front, or the last one scanning from the back,
// and -1 when nothing in the model is selectable. Home, End and the grid's
// end jumps all answer with this, so one scan serves every caller. A walk of
// exactly `rows.length` steps from either end never needs to wrap its index
// modulo the model length: it
// visits every index once and comes back to the end it started from.
function selectableEdge(rows, isSelectable, last) {
  const n = rows.length
  if (n === 0) return -1
  const dir = last ? -1 : 1
  const from = last ? n - 1 : 0
  for (let i = 0; i < n; i++) {
    const idx = from + dir * i
    if (isSelectable(idx)) return idx
  }
  return -1
}

// Which route a key press takes, or null when none of the routes below
// claim it. `ctx` is a plain object the panel fills from its own state:
//
//   key       the press, named from the caller's key vocabulary; "" for a
//             key the vocabulary omits, which no route claims
//   ctrl/meta modifier bits
//   mode      "list" or "filter"
//   grid      the page renders as a grid
//   editor    the current row has an open inline editor
//   del       the current row declares a delCommand
//   confirm   the current row declares a staged confirmation
//   field     the search field holds focus
//   text      the event's text
//
// editor/del/confirm are read through the caller's getters, not up front:
// the confirm probe reaches a provider callback, and asking every
// keystroke would spend a provider call on a decision only Delete reads.
//
// The route says which effect, never whether the key is claimed - that
// belongs to the route, so a Space in filter mode, an Enter under the
// field and a Left in filter mode all stay unclaimed without the caller
// re-deriving a mode check per route.
// The page whose layout rules the card is currently drawing. Search results
// inherit the ENTRY page's mode (an emoji bundle filters within its own grid),
// otherwise the page the panel installed beside the row set decides, and only
// then the navigation singleton's current page. The installed page is read
// before the singleton because the latter is a cached binding that still names
// the outgoing page inside a change handler.
function layoutPageOf(bundle, searching, installedPage, pageById, currentPageId) {
  if (!bundle) return null
  if (searching === true) return bundle.byId[bundle.entry] || null
  if (installedPage) return installedPage
  return pageById(currentPageId)
}

// --- grid geometry ------------------------------------------------------

// The cell side a grid page asks for, with the floor that keeps a degenerate
// declaration usable.
function gridCellSpec(page) {
  return page && typeof page.cell === "number" && page.cell > 16 ? page.cell : 46
}

// Grid geometry from the card width and the outer padding. Columns fit the
// inner width; the side stretches so the cells fill that width exactly, which
// is what keeps a grid page's last column flush with the card.
function gridGeometry(width, outerPad, cellSpec) {
  const innerW = Math.max(0, Number(width) - 2 * Number(outerPad))
  const spec = Number(cellSpec) > 0 ? Number(cellSpec) : 46
  const cols = Math.max(1, Math.floor(innerW / spec))
  const side = cols > 0 ? Math.floor(innerW / cols) : spec
  return { innerW: innerW, cols: cols, side: side }
}

// --- row-set identity ---------------------------------------------------

// The uid sequence a row set is identified by. NUL is the separator because
// uidKey strips every control character out of an item id and a page id, so a
// row uid cannot hold one and the join cannot forge a boundary between rows.
// The panel memoizes this on the array identity; the fold itself is pure.
function rowKeySeq(rows) {
  const pool = Array.isArray(rows) ? rows : []
  const keys = new Array(pool.length)
  for (let i = 0; i < pool.length; i++) {
    const item = pool[i]
    keys[i] = String(item && item.uid !== undefined && item.uid !== null
      ? item.uid : "")
  }
  return keys.join("\u0000")
}

// The row set a keyed model may install, or the refusal code that says why it
// may not. Four rows in and four rows out is not an install a height table can
// absorb when two of them share one identity: List refuses to measure either,
// prunes both and raises identityError, so a duplicate has to be refused at
// this boundary rather than handed on. The codes are the keyed-model validate
// vocabulary; `rows` is a fresh array holding the caller's own row objects,
// which is what makes the install observable.
function rowSetGuard(candidate) {
  if (!Array.isArray(candidate)) return { rows: null, error: "not_array" }
  const rows = new Array(candidate.length)
  const seen = Object.create(null)
  for (let i = 0; i < candidate.length; i++) {
    const item = candidate[i]
    if (!item || item.uid === undefined || item.uid === null)
      return { rows: null, error: "invalid_row" }
    const key = String(item.uid)
    if (key.trim() === "") return { rows: null, error: "missing_key" }
    if (seen[key] !== undefined) return { rows: null, error: "duplicate_key" }
    seen[key] = true
    rows[i] = item
  }
  return { rows: rows, error: "" }
}

function keyRoute(ctx) {
  const k = ctx.key
  const ctrl = ctx.ctrl === true
  const meta = ctx.meta === true
  const list = ctx.mode === "list"
  const unclaimed = { name: "", arg: null }

  // Modified-letter binds live OUTSIDE the switch: a bare case would
  // swallow the plain letter and break type-to-search ("i", "w", ...).
  if (ctrl) {
    if (k === "keyI") return { name: "info", arg: null }
    if (k === "keyF") return { name: "filter", arg: null }
  }

  // Grid pages: arrows move spatially - Left/Right step cells, Up/Down
  // jump rows. Tab/Backtab keep the linear next/prev walk of lists;
  // everything else (Enter, Esc, Home/End, PgUp/PgDn, typing) falls
  // through to the shared routes. Delete/Ctrl+D removes a cell that
  // declares a forget command (recents) without closing, so this route
  // is chosen whether or not such a command exists - whether the key is
  // claimed is the dispatcher's to decide. The filter field active on a
  // grid keeps Left/Right for its caret but still needs Up/Down to jump
  // rows, so both grid states live in one nested route.
  function gridRoute() {
    if (ctx.grid === true && list) {
      if (k === "deleteKey" || (ctrl && k === "keyD")) return { name: "forget", arg: null }
      if (k === "left") return { name: "cell", arg: -1 }
      if (k === "right") return { name: "cell", arg: 1 }
      if (k === "up") return { name: "gridRow", arg: -1 }
      if (k === "down") return { name: "gridRow", arg: 1 }
    }
    if (ctx.grid === true && !list) {
      if (k === "up") return { name: "gridRow", arg: -1 }
      if (k === "down") return { name: "gridRow", arg: 1 }
    }
    return null
  }
  const grid = gridRoute()
  if (grid !== null) return grid

  // Inline editors own navigation: arrows belong to the caret, and list
  // movement must not leak while typing.
  if (ctx.editor === true && (k === "up" || k === "down" || k === "tab"
    || k === "backtab" || k === "left" || k === "right" || k === "home"
    || k === "endKey")) return { name: "swallow", arg: null }

  // List rows declaring a delCommand remove via the staged confirmation
  // (Delete / Ctrl+D arm and advance it), matching the grid-side forget
  // handling above. Rows carrying the generic staged confirmation instead
  // walk the same stages as Enter/click. Rows with neither fall through
  // to the filter behavior of Delete below. Editors are skipped so
  // Delete keeps deleting text inside an open input.
  if (ctx.grid !== true && list && ctx.editor !== true
    && (k === "deleteKey" || (ctrl && k === "keyD"))) {
    if (ctx.del === true) return { name: "delete", arg: null }
    if (ctx.confirm === true) return { name: "confirm", arg: null }
  }

  switch (k) {
    // Same semantics as Enter while the search bar is inactive; while it
    // is, the field keeps the key. Space and Enter stay two routes
    // because they were two call sites: Enter hands activate the shift
    // bit and Space never did, and the parameter is dead today only by
    // luck.
    case "space":
      if (list && ctx.field !== true) return { name: "activateNoShift", arg: null }
      return unclaimed
    case "down":
    case "tab":
      return { name: "move", arg: 1 }
    case "up":
    case "backtab":
      return { name: "move", arg: -1 }
    case "plus":
    case "equal":
      return { name: "step", arg: 1 }
    case "minus":
    case "underscore":
      return { name: "step", arg: -1 }
    // An open dropdown takes a side arrow first and a numeric row behind
    // it steps; whether the dropdown consumed it is the dispatcher's to
    // find out, so the route names both halves. In filter mode the field
    // owns the caret and keeps the key.
    case "left":
    case "right":
      if (!list) return unclaimed
      return { name: "optionOrStep", arg: k === "left" ? -1 : 1 }
    // The field's onAccepted already handles Enter when it has focus;
    // don't double-activate.
    case "returnKey":
    case "enterKey":
      if (ctx.field === true) return unclaimed
      return { name: "activate", arg: null }
    case "escape":
      return { name: "escape", arg: null }
    case "home":
      return { name: "end", arg: false }
    case "endKey":
      return { name: "end", arg: true }
    case "pageUp":
      return { name: "page", arg: -0.8 }
    case "pageDown":
      return { name: "page", arg: 0.8 }
    // Delete opens the filter rather than removing a row; in filter mode the
    // field keeps deleting text itself.
    //
    // Backspace is the menu's way BACK rather than a filter key: with the
    // field inactive it walks the chain Escape walks (de-focus the filter,
    // collapse, pop, close), which is the conventional home binding and leaves
    // Delete to arm the filter. With the field active it is the field's, since
    // text under the caret is not a row. An open editor owns it as well: the
    // caret had the key first, and a key meant for a number being typed must
    // not become the menu closing around it, so it is swallowed rather than
    // routed - the same answer a letter the field refused gets.
    case "backspace":
      if (ctx.editor === true) return { name: "swallow", arg: null }
      if (list) return { name: "escape", arg: null }
      return unclaimed
    case "deleteKey":
      if (list) return { name: "filter", arg: null }
      return unclaimed
  }

  // Typing in list mode filters across every page of the bundle. "/" arms
  // the in-page quick-filter instead and is not itself part of the query.
  // No modifier may be held, or Ctrl+A and friends would be swallowed.
  //
  // An open editor is not a panel command, and this is where that has to be
  // said. The caret had the character first: a key only reaches the panel
  // after the focused field has already seen it and let it go, and a field
  // lets a character go for exactly one reason - it is not a character this
  // field takes. A number picker's validator refusing a letter IS the filter,
  // so the letter is finished with. Routing it into the query instead types
  // the character into a box the user never opened and pulls the filter
  // field's focus off the editor mid-edit, which is how a numeric row ends
  // up behaving like a text field that takes letters.
  if (ctx.editor === true) return { name: "swallow", arg: null }
  const text = SU.textOf(ctx.text)
  if (!ctrl && !meta && list && text.length === 1 && text.charCodeAt(0) >= 32)
    return { name: text === "/" ? "scoped" : "query", arg: text }

  return null
}

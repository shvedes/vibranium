// The declared bundle: the shape a row starts with, the page assembly around
// it, the parse, and the extension merge.
//
// WHY IT IS ITS OWN MODULE. Everything here reads bundle text or plain page
// objects and produces normalized ones: no QML property, no singleton, no
// store, and nothing from the search index or the keyboard model. MenuLib
// re-exports each entry point, so the panel and the pickers keep the single
// import they already use (and the suite keeps its one coverage ledger); the
// file boundary is for the reader who wants the vocabulary a bundle is written
// in without the index around it.
.pragma library

.import "../../common/text/StringUtils.js" as SU
.import "../../common/text/SearchLib.js" as SL
.import "../../common/collections/StoreGuards.js" as StoreGuards

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
  const raw = JSON.parse(SU.stripJsonc(text))
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
    ext = JSON.parse(SU.stripJsonc(extText))
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

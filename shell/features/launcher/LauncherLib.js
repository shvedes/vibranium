// Pure-JS engine for the App Launcher: the index/usage/plugin model and the
// parsing and argv behind the filesystem work, plus desktop-entry indexing,
// fuzzy search, keyword-array parsing and shell helpers. Everything here is a
// deterministic transform of values it is handed - a FileView read, a Process
// line, a settings section - so a defect is drivable without a running shell.
// Shared helpers are delegated to common/text/StringUtils.js - single source of
// truth.
//
// Deliberately NOT here: FileView, Process, Timer, plugin hosts and any QML
// singleton (Settings, DesktopEntries, Paths, Clipboard, AppLauncher). The
// controller owns those resources; this module owns what a verdict MEANS. The
// two seams are narrow and named: a `readMeta(dir)` callback for the plugin
// manifest, a `grantedFor(plugin)` callback for the capability posture, and
// argv builders whose result the controller hands to a Process.
// Everything here is deterministic and unit-drivable - no Qt imports.
.pragma library

.import "../../common/text/StringUtils.js" as SU
.import "../../common/text/SearchLib.js" as SL
// File-opener rows reuse the Clipboard component's extension -> icon
// mapping verbatim, so a pasted path shows the same glyph it would show
// as a clipboard entry.
.import "../clipboard/ClipboardLib.js" as CL

function stripJsonc(raw) { return SU.stripJsonc(raw) }
function shellQuote(s) { return SU.shellQuote(s) }
function styledMarkup(text) { return SU.styledMarkup(text) }

// --- desktop entry index ---

// Categories hidden from the launcher regardless of settings.
const BASE_EXCLUDED_CATEGORIES = ["Power"]

// Change-detector for an index build: the live entry count, the sort
// method, and the usage signal the caller holds. The controller skips a
// rebuild when the string is unchanged, which is the warm-summon fast
// path, so it has to be a total function of exactly those three and
// nothing else - an input it ignores would read as "unchanged" and freeze
// a stale order.
//
// The usage term is a REVISION, a counter the caller moves whenever the
// usage map moves, and not the map itself. Fingerprinting the map answers
// a question this gate does not ask: the gate asks whether the map
// CHANGED, and a content fingerprint reaches that verdict only by
// serialising every key and count - kilobytes on a real druncache, on a
// path that runs on the first summon and again after every usage bump. A
// counter is O(1) in the map's size, and two different maps cannot land
// on the same revision.
function indexFingerprint(entryCount, sortMethod, usageSignal) {
  return (entryCount || 0) + "|" + String(sortMethod ?? "") + "|" + JSON.stringify(usageSignal)
}

// Snapshot one DesktopEntry into a plain record. DesktopEntry objects are
// QML singletons - indexing reads every property once so per-keystroke
// search never touches QObject property lookups.
function appRecord(entry) {
  const cats = entry.categories ?? []
  for (let i = 0; i < cats.length; i++) {
    if (BASE_EXCLUDED_CATEGORIES.indexOf(cats[i]) >= 0) return null
  }
  const keywords = entry.keywords ?? []
  const hay = [
    entry.name,
    entry.genericName,
    entry.comment,
    entry.id,
    keywords.join(" "),
    cats.join(" ")
  ].join(" ").toLowerCase()
  // Launch handling: Terminal=true entries must open inside a terminal.
  // The launcher itself does not match windows or resolve focus - that is
  // vb-launch-*'s job (vb-launch-cmd handles focus-or-launch, and TUI/PWA
  // entries already carry their vb-launch-tui / vb-launch-webapp wrapper
  // in Exec). This flag routes terminal-bounded entries to vb-launch-tui.
  // Only launcher-owned desktop entries can be removed in-app.
  // Detection: PWA category or vb-launch-webapp / raw Chromium
  // --app=<url> / --app-id=<id> exec, TUI category or vb-launch-tui
  // exec. TUI wins over PWA: vb-launch-tui's own window-matching
  // --app-id=org.vb.term.float flag must never classify a TUI as a
  // webapp. `badge` drives the right-side webapp/tui indicator.
  const _exec = String(entry.execString ?? entry.exec ?? "")
  const _isTUI = _exec.indexOf("vb-launch-tui") >= 0
    || cats.indexOf("TUI") >= 0
  const _isPWA = !_isTUI && (_exec.indexOf("vb-launch-webapp") >= 0
    || _exec.indexOf("--app=") >= 0
    || _exec.indexOf("--app-id=") >= 0
    || cats.indexOf("PWA") >= 0)
  // isManagedEntry is the single source for removable; the split above is
  // the same test kept in named form because `badge` needs it.
  const _removable = isManagedEntry(entry, cats)
  // Launch handling keeps the original entry: the controller reads its
  // id/exec for activation and usage bumps, and the snapshot stays
  // identity-stable with the DesktopEntries list it came from.
  return {
    kind: "app",
    uid: "app:" + entry.id,
    app: entry,
    label: String(entry.name ?? ""),
    sub: "",
    desc: String(entry.comment ?? ""),
    genericName: String(entry.genericName ?? ""),
    icon: String(entry.icon ?? ""),
    id: String(entry.id ?? ""),
    runInTerminal: entry.runInTerminal === true,
    hay: hay,
    words: hay.split(" "),
    removable: _removable,
    managed: _removable,
    badge: _isPWA ? "webapp" : _isTUI ? "tui" : ""
  }
}

function isManagedEntry(entry, cats) {
  const exec = String(entry.execString ?? entry.exec ?? "")
  const tui = exec.indexOf("vb-launch-tui") >= 0
    || cats.indexOf("TUI") >= 0
  const pwa = !tui && (exec.indexOf("vb-launch-webapp") >= 0
    || exec.indexOf("--app=") >= 0
    || exec.indexOf("--app-id=") >= 0
    || cats.indexOf("PWA") >= 0)
  return tui || pwa
}

function buildAppIndex(entries, sortMethod, usageMap) {
  const out = []
  for (let i = 0; i < entries.length; i++) {
    const rec = appRecord(entries[i])
    if (rec && rec.label !== "") out.push(rec)
  }
  // Base order for the idle view (no query). Search results re-rank by
  // relevance on top of this; equal relevance falls back to this order
  // via the searchRecords tiebreak, so "Most used" also governs
  // filtering and not just the resting list.
  // - alphabetical: classic A→Z (default)
  // - frequency: most-used first (cached across sessions),
  //   tie → alphabetical. Only affects the
  //   blank view; filtered search is always by fuzzy relevance.
  if (sortMethod === "frequency" && usageMap && typeof usageMap === "object") {
    out.sort((a, b) => {
      // Snapshot id first: records are snapshotted into plain records, so the
      // rank must survive the live DesktopEntry going away. A live read faults
      // to "" on a destroyed handle, which zeroes the count and pins frequency
      // sort to alphabetical. Live is only the fallback for a record minted
      // without one.
      const aid = String(a.id ?? (a.app ? a.app.id ?? "" : ""))
      const bid = String(b.id ?? (b.app ? b.app.id ?? "" : ""))
      const ac = usageCountFor(usageMap, aid)
      const bc = usageCountFor(usageMap, bid)
      if (ac !== bc) return bc - ac
      const al = a.label.toLowerCase()
      const bl = b.label.toLowerCase()
      return al < bl ? -1 : al > bl ? 1 : 0
    })
  } else {
    out.sort((a, b) => {
      const al = a.label.toLowerCase()
      const bl = b.label.toLowerCase()
      return al < bl ? -1 : al > bl ? 1 : 0
    })
  }
  return out
}

// Numeric usage count for a desktop id in a druncache map. The map
// mixes shapes over time: plain numbers (current writer) and
// {count} objects (older rows). Anything else reads as unused.
function usageCountFor(usageMap, id) {
  if (!usageMap || typeof usageMap !== "object") return 0
  const u = usageMap[String(id ?? "")]
  if (u && typeof u.count === "number") return u.count
  if (typeof u === "number") return u
  return 0
}

// --- usage persistence ---
//
// druncache.json is the launcher's only file it writes. Four pure steps own
// its whole contract - read, write, bump, emptiness - and the controller owns
// the four FileViews they land in. The two readers deliberately answer
// differently on a file they cannot read, and that difference is load
// bearing: the map read keeps whatever it already had (a launch bumped a
// counter the stale file does not know about yet), while the emptiness read
// reports "no history" so the settings menu hides its row.

// Parse one druncache file into { map, hasHistory }. null means the text is
// blank or unparsable - the caller keeps its own state, which is not the
// same verdict as an empty object. hasHistory is "the file holds at least one
// key", so a cache that exists but is `{}` reads as no history.
function parseUsageText(text) {
  const txt = String(text ?? "")
  if (txt.trim() === "") return null
  let parsed
  try {
    parsed = JSON.parse(txt)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null
  return { map: parsed, hasHistory: Object.keys(parsed).length > 0 }
}

// The exact bytes druncache.json is written with. Indented and newline
// terminated because the file is a user's own state, readable and
// hand-editable, and an atomic write replaces it wholesale.
function serializeUsage(map) {
  return JSON.stringify(map, null, 2) + "\n"
}

// The next map after one launch of `id`. Both stored shapes bump, and a
// count that is not a number starts from zero. null for an empty id: there
// is no counter to write, and the caller must not report an increment that
// did not happen.
function bumpUsage(usageMap, id) {
  const key = String(id ?? "").trim()
  if (key === "") return null
  const next = Object.assign({}, usageMap)
  const cur = next[key]
  const curCount = cur && typeof cur.count === "number" ? cur.count : (typeof cur === "number" ? cur : 0)
  next[key] = curCount + 1
  return next
}

// The clear-history refusal: nothing to clear, so the write is refused
// instead of removing a file that is already gone and reporting success.
function usageHistoryEmpty(hasHistory, map) {
  if (hasHistory === true) return false
  return !map || typeof map !== "object" || Object.keys(map).length === 0
}

// --- plugin registry model ---
//
// A plugin is a directory: plugin.json (manifest) plus main.js. Everything
// below is the model half of discovery - what a directory MEANS - while the
// controller owns the directory scan, the manifest read and the host
// evaluation. `readMeta(dir)` is the one filesystem seam, and it is a
// callback so this stays a pure transform of the manifests it is handed.

const PLUGIN_TYPES = ["websearch", "binary", "engine"]

// The type vocabulary discovery admits, as a probe the node harness (which
// collects functions, not module consts) can still read.
function pluginTypes() { return PLUGIN_TYPES }

// One discovered plugin's config, or null when the manifest is not usable.
// A broken manifest skips its directory and can never take the launcher
// down, so every field it must carry is checked here rather than trusted at
// the call site. `direct` selects a row as an immediate action instead of
// arming the plugin as a prefix. Capabilities are the manifest's REQUEST: a
// root's grant table is authoritative and intersects this, it can never be
// widened by a manifest. `_impl`/`_host`/`_view`/`_denied`/`_implLoadTried`
// are filled in by the controller and never leave it. `_implLoadTried` is
// declared here beside the rest so "has this implementation been attempted
// yet" is a stated field of the record rather than one the controller
// invents on its first write, and so the two points that clear it are the
// two the record already has: a rescan mints fresh configs, and a disable
// empties the runtime.
function pluginConfigFromMeta(id, dir, meta, persisted) {
  if (meta === null || meta === undefined) return null
  // The keyword condition and the type vocabulary are two statements of one
  // rule - only an engine, a websearch or a binary plugin is admitted, and
  // only one of those three may be keywordless - and the second settles every
  // case the first names. Both are kept because the rejection is a contract,
  // not an implementation detail; a future edit that drops either one still
  // admits exactly the same manifests.
  //
  // "Keywordless" IS the silent-plugin rule rather than an exemption from it:
  // a keyword is the only way a mode can be entered (see pluginByPrefix), so
  // an empty one is what makes a plugin reachable solely by what it claims.
  if (typeof meta.name !== "string" || meta.name === ""
    || typeof meta.description !== "string" || meta.description === ""
    || typeof meta.keyword !== "string"
    || (meta.type !== "engine" && meta.type !== "websearch" && meta.type !== "binary" && meta.keyword === "")
    || PLUGIN_TYPES.indexOf(meta.type) < 0) {
    return null
  }
  const cfg = {
    id: id,
    name: meta.name,
    description: meta.description,
    keyword: meta.keyword,
    type: meta.type,
    direct: meta.direct === true,
    dir: dir,
    caps: meta.capabilities,
    // Persisted enablement wins over the default; absent means enabled.
    enabled: true,
    broken: false,
    _impl: null,
    _implLoadTried: false,
    _host: null,
    _view: null,
    _denied: []
  }
  for (let i = 0; i < persisted.length; i++) {
    if (persisted[i].id === id) {
      cfg.enabled = persisted[i].enabled !== false
      break
    }
  }
  return cfg
}

// The whole registry from a scan result: the directory NAME is the plugin
// id, and a duplicate id resolves in favor of the earlier root (the built-in
// root is scanned first, so a user folder named `calc` cannot shadow the
// shipped one). `readMeta(dir)` returns the parsed manifest or null, and its
// own I/O failure is a skip, not a throw - discovery must survive a
// directory it cannot read.
function buildPluginConfigs(dirs, persisted, readMeta) {
  const seen = Object.create(null)
  const list = []
  for (let i = 0; i < dirs.length; i++) {
    const dir = dirs[i]
    const id = dir.substring(dir.lastIndexOf("/") + 1)
    if (seen[id] !== undefined) continue
    seen[id] = true
    const cfg = pluginConfigFromMeta(id, dir, readMeta(dir), persisted)
    if (cfg === null) continue
    list.push(cfg)
  }
  return list
}

// The persisted plugin section reduced to the list this module needs: the
// entries that name an id, in file order. Settings is the controller's to
// read; what a section MEANS is here.
function persistedPluginList(section) {
  const list = section && Array.isArray(section.plugins) ? section.plugins : []
  return list.filter(p => p && typeof p.id === "string")
}

// What settings.json should hold after a toggle: the full merged configs, so
// the file documents itself, with entries for plugins this scan did not
// discover left exactly as they were.
function pluginConfigsForPersist(persisted, plugins) {
  const known = persisted.filter(p => {
    return plugins.findIndex(k => k.id === p.id) < 0
  })
  for (let i = 0; i < plugins.length; i++) {
    const p = plugins[i]
    known.push({
      id: p.id,
      name: p.name,
      description: p.description,
      keyword: p.keyword,
      type: p.type,
      enabled: p.enabled === true
    })
  }
  return known
}

// The persisted list with one entry's enablement replaced, in file order: an
// id the file already names keeps its slot and every other field it carries,
// an id it has never mentioned is appended so a discovery overlay picks it
// up. This is what a write against a registry that has not been discovered
// yet persists. Durable first is the point - the demand that raced the scan
// is transient and its tree can be torn down before the scan lands, so a
// request held only in that tree would go with it.
function persistedPluginWithState(persisted, id, enabled) {
  const key = String(id ?? "")
  if (key === "") return persisted
  const out = persisted.slice()
  for (let i = 0; i < out.length; i++) {
    if (out[i].id !== key) continue
    // Copied, not written through: Settings hands out the live object.
    out[i] = Object.assign({}, out[i], { enabled: enabled === true })
    return out
  }
  out.push({ id: key, enabled: enabled === true })
  return out
}

// Apply a hand edit to the live registry. The configs are mutated in place
// (the controller republishes the list to force its own bindings, because a
// per-config field write is invisible to change detection), and `changed`
// tells the caller whether anything moved at all - a settings engine bump
// arrives on every write to the file, not only on a real change.
function mergePersistedEnabled(plugins, persisted) {
  let changed = false
  for (let i = 0; i < plugins.length; i++) {
    const cfg = plugins[i]
    let next = true
    for (let j = 0; j < persisted.length; j++) {
      if (persisted[j].id === cfg.id) {
        next = persisted[j].enabled !== false
        break
      }
    }
    if (next !== cfg.enabled) {
      cfg.enabled = next
      changed = true
    }
  }
  return changed
}

// Prefixes a query may be dispatched on: enabled, not broken, and claiming
// one. No `_impl` here, and that is load-bearing rather than incidental:
// implementations are loaded when a claim reaches them, so a rule that
// required one would publish an empty prefix list on the first open and a
// mode could not be entered at all. The keyword and the type are what make
// a plugin reachable by a prefix, and both come from the manifest.
function enabledPrefixes(plugins) {
  const out = []
  for (let i = 0; i < plugins.length; i++) {
    const p = plugins[i]
    if (p.enabled && !p.broken && p.keyword !== "") out.push(p.keyword)
  }
  return out
}

// A live plugin by id, whatever its state: the mode owner, the settings
// writer and the enablement read all need to find a config that is disabled
// as much as one that is loaded.
function pluginById(plugins, id) {
  const key = String(id ?? "")
  if (key === "") return null
  for (let i = 0; i < plugins.length; i++) {
    if (plugins[i].id === key) return plugins[i]
  }
  return null
}

// A live plugin by the exact prefix a query starts with, which is also the
// set of prefixes a mode may be entered for.
function pluginByPrefix(plugins, prefix) {
  if (prefix === "") return null
  for (let i = 0; i < plugins.length; i++) {
    const p = plugins[i]
    if (p.enabled && !p.broken && p.keyword !== "" && p.keyword === prefix) return p
  }
  return null
}

// The first live plugin of a type, in discovery order.
function pluginByType(plugins, type) {
  for (let i = 0; i < plugins.length; i++) {
    const p = plugins[i]
    if (p.enabled && !p.broken && p.type === type) return p
  }
  return null
}

// The only shape that leaves this module for a view: id, keyword and type.
// A view may read the descriptor's keyword and may not reach the impl, the
// host or the policy view through it.
function pluginDescriptor(cfg) {
  if (!cfg || cfg.broken || cfg.enabled !== true) return null
  return { id: cfg.id, keyword: cfg.keyword, type: cfg.type }
}

// Whether a plugin is usable, from the registry: discovered, enabled, not
// broken. An id nothing knows reads off, which is what an undiscovered
// plugin directory is.
function pluginEnabledFlag(plugins, id) {
  const cfg = pluginById(plugins, id)
  return cfg !== null && cfg.enabled === true && cfg.broken !== true
}

// The public record set, in one place: everything a status read may show and
// nothing that is an engine object. `grantedFor(plugin)` is the capability
// read, injected because it is a live call into a policy view the module
// must not own; a plugin that was never granted answers an empty list.
function pluginSummary(plugins, grantedFor) {
  const out = []
  for (let i = 0; i < plugins.length; i++) {
    const p = plugins[i]
    out.push({
      id: p.id,
      name: p.name,
      description: p.description,
      keyword: p.keyword,
      type: p.type,
      enabled: p.enabled === true,
      broken: p.broken === true,
      granted: grantedFor(p),
      denied: p._denied ?? []
    })
  }
  return out
}

// The same registry as a plain { id: enabled } map - the shape the menu
// toggles read, and the same answer pluginEnabledFlag gives for every id it
// knows.
function pluginToggles(plugins) {
  const out = {}
  for (let i = 0; i < plugins.length; i++) {
    const id = plugins[i].id
    out[id] = pluginEnabledFlag(plugins, id)
  }
  return out
}

// Engine plugin priority: first enabled engine claiming the query wins.
// Registration order is discovery order; the builtin root scans before the
// user root and folder names sort calc < color < fx < time < unit on
// disk, so ship the priority explicitly rather than inferring it. Declared
// ahead of its readers because a module-scope const is not hoisted in a QML
// library: the engine reports a use before its declaration, and the order is
// the only thing that makes the list mean anything. The isEngineKind
// predicate below is what the counter and the panel read.
//
// color leads because a color query is the narrowest of the five: it must be
// spelled with a `#` or a css function name, so nothing else can be reading it
// as arithmetic, a quantity or a currency pair. fx comes next because a
// currency query is the next narrowest - it needs an amount AND a currency on
// the source side, and a currency behind a keyword on the other. The
// calculator takes any arithmetic - "100*2" is its - and the unit converter
// takes a bare "<value><unit>", so anything that reads as a currency pair
// reaches fx before either can claim it.
const ENGINE_ORDER = ["color", "fx", "time", "unit", "calc"]

// `itemsFor(plugin)` is the plugin's own items() call, injected so a throwing
// implementation can be caught by the controller rather than here.
//
// The claim is the plugin's WHOLE list, not its first row: an engine may
// answer with several rows of one kind (a bare "5 mb" is six conversions, a
// bare "100 usd" is six rates), and the card renders every row it gets. An
// engine that answers with one row still answers with one row here.
//
// There is no `loadFor` here, and the omission is deliberate: the engine set
// is loaded by the controller BEFORE this call, in one pre-pass over every
// `type === "engine"` config. That is a superset of what the loop below can
// reach (it only ever considers `p.type === "engine"`), so by the time the
// `_impl` guard runs, every candidate is either loaded or already `broken`,
// and the guard can never skip a plugin that could have answered.
//
// A `loadFor` on this loop would be the obvious way to express "ask, don't
// skip", and it would be wrong: the loop asks on EVERY query including a
// blank one, so it would load the whole engine set on an idle open - the
// exact cost this exists to remove. The pre-pass can decline to load for a
// blank query; a per-candidate hook cannot.
function firstEngineClaiming(plugins, query, itemsFor) {
  const order = ENGINE_ORDER
  for (let o = 0; o < order.length; o++) {
    for (let i = 0; i < plugins.length; i++) {
      const p = plugins[i]
      if (!p || p.id !== order[o] || p.type !== "engine") continue
      if (!p.enabled || p.broken || !p._impl) continue
      const rows = itemsFor(p)
      if (rows && rows.length > 0) return { plugin: p, rows: rows }
    }
  }
  return null
}

// Fallback-slot priority: the one synthetic row the launcher shows when
// nothing local claimed the query. An engine takes the whole list by claiming,
// but the fallback is a CHAIN rather than a single owner - the slot
// holds one answer and the types below are the order they get asked in, so a
// plugin that declines the query hands the slot to the next type instead of
// erasing it. `websearch` is last because it answers every non-blank query:
// anything above it that declines has changed the row, not removed it.
//
// The order is by TYPE, not by id, which is what lets a user plugin join the
// chain - an id-keyed order would be a closed list of folder names, and the
// engine path is id-keyed precisely because its six entries are semantic
// identities whose UX ranking cannot be inferred. Discovery order breaks
// ties within a type, so the first live plugin of a type is the one asked.
const FALLBACK_ORDER = ["binary", "websearch"]

// The order a FORCED query ("!name") is asked in, which is `binary` alone.
// The "!" is the user asserting that the query IS a program name, so the
// question it asks is "run this", never "search for it": a name nothing
// provides has to leave the slot empty rather than answer a web search the
// user did not ask for and cannot have meant. An unforced query gets the
// whole chain, because there the web search is the right answer to "I typed
// something and nothing here matches".
const FORCED_ORDER = ["binary"]

// The fallback orders, as probes the node harness (which collects functions,
// not module consts) can still read.
function fallbackOrder() { return FALLBACK_ORDER }

function forcedOrder() { return FORCED_ORDER }

// The first live plugin in `order` whose items() claims the query, with every
// row it answered - the slot renders the plugin's own list, so unlike the
// engine path the claim is not narrowed to its first row. `itemsFor` is the
// plugin's own items() call, injected for the same reason as above.
//
// `order` narrows WHICH types may fill the slot, and defaults to the whole
// chain. A non-array is no narrowing, the same reading intersect() gives a
// manifest's request; an array is taken as given, so an empty one means
// nothing can claim and the caller gets null.
//
// `loadFor` is the controller's on-demand load, asked on a candidate BEFORE
// the `_impl` guard: the guard alone would skip a deferred plugin, and the
// fallback row this chain exists to fill would then never appear. Optional,
// and a caller whose registry is already loaded passes nothing, which leaves
// the pre-existing skip untouched. The engine path reaches the same
// guarantee from OUTSIDE its loop instead (see firstEngineClaiming), because
// this chain is only entered for a query that has already fallen through to
// the fallback slot, while the engine loop is asked on every query.
function firstFallbackClaiming(plugins, query, itemsFor, order, loadFor) {
  const seq = Array.isArray(order) ? order : FALLBACK_ORDER
  for (let o = 0; o < seq.length; o++) {
    for (let i = 0; i < plugins.length; i++) {
      const p = plugins[i]
      if (!p || p.type !== seq[o]) continue
      if (!p.enabled || p.broken) continue
      if (typeof loadFor === "function" && !p._impl) loadFor(p)
      if (!p._impl) continue
      const rows = itemsFor(p)
      if (rows && rows.length > 0) return { plugin: p, rows: rows }
    }
  }
  return null
}

// Shared search plumbing, re-exported for the menu. The implementations
// live in SearchLib (single source); this alias is the path MenuLib calls
// them by. One `var`, not per-function wrappers: the launcher suite asserts
// every exported FUNCTION was called during its run, and a single object
// stays off that surface - while the menu suite's private re-evaluation of
// MenuLib (which re-supplies its import aliases by hand) already carries
// this LauncherLib alias and so resolves SearchLib underneath, where a new
// .import in MenuLib would dangle.
// -> Behavioural delegation, the same shape as the StringUtils re-exports
// -> at the top of this file.
var SearchPlumbing = SL

// Score ONE query token against a record's pre-split words. Word-level
// matching only: a token hits a word by exact equality, word-start
// prefix, or contained substring. The menu's cross-word letter-chain
// matcher is deliberately NOT used here - over thousands of desktop
// entries it fabricates matches ("calculator" -> "C"hromium + "a"...),
// and a launcher needs precision more than acronym cleverness.
//
// Earlier position ranks higher so header-ish words win ties.
function tokenScore(words, t) {
  for (let w = 0; w < words.length; w++) {
    const word = words[w]
    if (word === t) return 3000 - w
    if (word.startsWith(t)) return 2000 - w * 10
    const idx = word.indexOf(t)
    if (idx > 0) return 1000 - idx * 10
  }
  return -1
}

// Damerau optimal-string-alignment distance capped at two: 0 for identical
// strings, 1-2 for one or two substitutions, insertions, deletions or
// adjacent transpositions, and 3 for anything further. The cap is the
// contract - callers only ask "within budget" - and words are short, so the
// table answers it with no early-exit state to prove correct. A single
// rolling row cannot serve the transposition cell, which reads two rows
// back: that is why this keeps the whole table.
//
// One transposition counts as one, which is what separates this from a
// plain Levenshtein cap: "fireofx" is two substitutions apart and one swap,
// and a swap is the typo a fast typist actually makes.
function typoDistance(a, b) {
  const x = String(a ?? "")
  const y = String(b ?? "")
  if (x === y) return 0
  const la = x.length
  const lb = y.length
  if (Math.abs(la - lb) > 2) return 3
  const d = []
  for (let i = 0; i <= la; i++) {
    d.push([i])
    for (let j = 1; j <= lb; j++) d[i].push(0)
  }
  for (let j = 1; j <= lb; j++) d[0][j] = j
  for (let i = 1; i <= la; i++) {
    for (let j = 1; j <= lb; j++) {
      const cost = x.charCodeAt(i - 1) === y.charCodeAt(j - 1) ? 0 : 1
      let v = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
      if (i > 1 && j > 1 && x.charCodeAt(i - 1) === y.charCodeAt(j - 2)
        && x.charCodeAt(i - 2) === y.charCodeAt(j - 1)) {
        v = Math.min(v, d[i - 2][j - 2] + 1)
      }
      d[i][j] = v
    }
  }
  const dist = d[la][lb]
  return dist <= 2 ? dist : 3
}

// Edit budget for one token, by its length: short tokens stay strict.
// Two edits on a two- or three-letter token match a large share of every
// word that short ("zz" meets all 139 desktop entries), so tokens under
// five characters allow a single edit and longer ones two. Measured, not
// guessed: the flat cap rescues nothing extra on short tokens that the
// strict one misses for a reason.
function typoBudget(t) {
  return String(t ?? "").length < 5 ? 1 : 2
}

// One token's typo verdict against pre-split words: the best within-budget
// match, or -1. Exact, prefix and substring matches are NOT typo matches -
// tokenScore owns those - so this answers only what that scorer cannot.
// Scored in its own bands under every exact band (500s for one edit, 400s
// for two), with the same earlier-words-first tiebreak, so within the typo
// pass a name hit still outranks a comment hit and the bands can never
// outrank an exact hit they are never compared against.
//
// Single-character tokens never reach the typo pass: any letter is one edit
// away from any other, so a one-letter query would rescue nearly every word
// that short and turn an unknown filter into a wall of false hits sharing
// one band - the entries that then fight for a single slot.
function typoTokenScore(words, t) {
  const exact = tokenScore(words, t)
  if (exact >= 0) return exact
  if (String(t ?? "").length < 2) return -1
  const budget = typoBudget(t)
  let best = -1
  for (let w = 0; w < words.length; w++) {
    const word = words[w]
    if (Math.abs(word.length - t.length) > budget) continue
    const dist = typoDistance(t, word)
    if (dist < 1 || dist > budget) continue
    const s = (dist === 1 ? 500 : 400) - w
    if (s > best) best = s
  }
  return best
}

// Tokenized AND-search over a records array (app index or keyword list):
// every space-separated token must hit its own best word; totals decide
// ranking. Returns { rows, count }: `rows` is the scored-sorted top
// `cap` (the display cap), `count` the full hit total for the
// matched/total counter. The whole hit set is never copied per
// keystroke - `cap` bounds both work and allocation.
//
// `tiebreak` is an optional rec -> number used when two records score
// equally (higher wins). The launcher passes its druncache counts when
// the sort method is "frequency", so most-used wins ties in filtering
// just like in the idle view. Records still tied after that keep input
// order (source index), which keeps results deterministic even on
// engines without a stable sort.
//
// Incremental cache: sequential typing ("f" -> "fi" -> "fir"...) is the
// common case. When the new query is a string-prefix of the previous one
// on the SAME records instance, new hits are a subset of previous hits -
// scan only that subset (typically <10 items) instead of the full index.
// Invalidated on records identity change (re-index) or query shrink/diverge.
// -> Identity is length-aware via SearchLib.sameCacheIndex and the hit store
// -> is scan-order (see SearchLib.narrowsQuery): the canonical policy shared
// -> with the menu, so ties rank by pool order on every path.
var _searchCacheRecords = null
var _searchCacheLen = -1
var _searchCacheQ = ""
var _searchCacheHits = null
var _searchCacheSorted = null

function searchRecords(records, query, cap, tiebreak) {
  const q = SL.normalizeQuery(query)
  if (q === "") {
    _searchCacheRecords = records
    _searchCacheLen = Array.isArray(records) ? records.length : -1
    _searchCacheQ = ""
    _searchCacheHits = []
    _searchCacheSorted = []
    return { rows: [], count: 0 }
  }
  const sameRecords = SL.sameCacheIndex(_searchCacheRecords, _searchCacheLen, records)
  if (SL.identicalQuery(sameRecords, _searchCacheQ, q, _searchCacheSorted)) {
    return { rows: _searchCacheSorted.slice(0, cap), count: _searchCacheSorted.length }
  }
  const tokens = SL.splitTokens(q)
  let source = records
  // Scan the cached hits instead of the pool when the query grew as a string
  // prefix AND the pool is the same array instance those hits were scored
  // from: a longer query matches a subset of what a shorter one matched, so
  // the pool behind the new hits IS the previous query's hit list.
  //
  // Pool identity is the whole test. This cache is module-level and three
  // surfaces reach it - the launcher, the menu's filterCounter forwarder, the
  // power menu - so a hit list can belong to a pool other than the one in hand,
  // and one record the two pools share is no evidence about the rest of either:
  // a scan that reused it would filter this pool by matches found elsewhere.
  // Every caller holds its own array between keystrokes (an app index, an
  // action pool), so identity is exact and cheap; a caller that rebuilds its
  // pool per keystroke scans in full, the same answer at the full-pool price.
  // -> The length term and the scan-order store are SearchLib's canonical
  // -> policy (sameCacheIndex + narrowsQuery): the same array with a different
  // -> length is a different pool, and the subset is scanned in pool order.
  if (SL.narrowsQuery(sameRecords, _searchCacheQ, q, _searchCacheHits)) source = _searchCacheHits
  const scored = []
  for (let i = 0; i < source.length; i++) {
    const rec = source[i]
    let total = 0
    let ok = true
    for (let t = 0; t < tokens.length && ok; t++) {
      const s = tokenScore(rec.words, tokens[t])
      if (s < 0) ok = false
      else total += s
    }
    if (ok) scored.push({ rec: rec, score: total, idx: i })
  }
  // Cache the FULL hit set (pre-cap) for incremental filtering; callers
  // cap via slice, so we keep canonical hits untruncated for the next pass.
  // -> Two stores: scan-order for the subset scan, sorted for identical-query
  // -> cap slices. The scan-order copy is taken before the sort, the way the
  // -> menu keeps its hit set, so ties rank by pool order either way.
  const hits = new Array(scored.length)
  for (let i = 0; i < scored.length; i++) hits[i] = scored[i].rec
  const tb = typeof tiebreak === "function" ? tiebreak : null
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score
    if (tb) {
      const d = tb(b.rec) - tb(a.rec)
      if (d !== 0) return d
    }
    return a.idx - b.idx
  })
  const full = new Array(scored.length)
  for (let i = 0; i < scored.length; i++) full[i] = scored[i].rec
  _searchCacheRecords = records
  _searchCacheLen = records.length
  _searchCacheQ = q
  _searchCacheHits = hits
  _searchCacheSorted = full
  const n = Math.min(full.length, cap)
  const out = new Array(n)
  for (let i = 0; i < n; i++) out[i] = full[i]
  return { rows: out, count: full.length }
}

// Typo rescue over a records array: the AND-search shape of searchRecords
// with typoTokenScore in place of tokenScore, and deliberately WITHOUT the
// incremental cache. A longer query can newly match under tolerance (the
// subset the cache assumes fails), so a cached subset scan would silently
// drop rows - every call scans the pool. Called only when the exact search
// reports zero, so the full scan lands on dead-end keystrokes alone, and
// the counter reads the true hit total the same way.
function searchTypo(records, query, cap, tiebreak) {
  const q = SL.normalizeQuery(query)
  if (q === "" || !Array.isArray(records)) return { rows: [], count: 0 }
  const tokens = SL.splitTokens(q)
  const scored = []
  for (let i = 0; i < records.length; i++) {
    const rec = records[i]
    let total = 0
    let ok = true
    for (let t = 0; t < tokens.length && ok; t++) {
      const s = typoTokenScore(rec.words, tokens[t])
      if (s < 0) ok = false
      else total += s
    }
    if (ok) scored.push({ rec: rec, score: total, idx: i })
  }
  const tb = typeof tiebreak === "function" ? tiebreak : null
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score
    if (tb) {
      const d = tb(b.rec) - tb(a.rec)
      if (d !== 0) return d
    }
    return a.idx - b.idx
  })
  const full = new Array(scored.length)
  for (let i = 0; i < scored.length; i++) full[i] = scored[i].rec
  const n = Math.min(full.length, cap)
  const out = new Array(n)
  for (let i = 0; i < n; i++) out[i] = full[i]
  return { rows: out, count: full.length }
}

// Filter counter over a FULL pool so `matched` reflects the true hit
// count (never the display cap), `total` is the pool size, and `rows`
// are the top `cap` matches for rendering. Blank queries match the
// whole pool sliced to `cap`. The {total, matched, rows} shell lives in
// SearchLib; the scorer stays this library's own searchRecords - the menu
// side forwards here for the same reason, and through the same shell.
// The optional `tiebreak` (rec -> number, higher wins) breaks equal
// relevance scores.
function filterCounter(pool, query, cap, tiebreak) {
  return SL.filterCounter(pool, query, cap, searchRecords, tiebreak)
}

// Kinds rendered as a synthetic row by design (never a filterable pool).
// Single source for the counter gate, single-row patching and swap-fade
// regime checks across the service and the panel.
function isEngineKind(kind) {
  return ENGINE_ORDER.indexOf(String(kind ?? "")) >= 0
}

function isSynthKind(kind) {
  const k = String(kind ?? "")
  return k === "web" || isEngineKind(k)
}

// Whether EVERY row in a set is synthetic, which is what the counter gate
// reads. It has to be every row rather than the first one: an engine can
// answer with several rows of its own kind now, and "one synthetic row hides
// the counter" would otherwise start reporting "6/214 apps" over a list of six
// conversions. An empty set is not an all-synthetic set - a fruitless search
// still shows "0/214".
function allSynthKinds(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return false
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i]
    if (!r || !isSynthKind(r.kind)) return false
  }
  return true
}

// What the granted `cachedNet` operation hands a plugin: the fetched BODY, or
// one of the two answers that are not a body. The three are distinct and the
// difference is load-bearing, so this is one function rather than a `?? null`
// at the call site:
//
//   null   never asked, or a request is in flight
//   ""     the fetch settled and produced nothing usable
//   text   the body
//
// The controller stores a record ({ body, at }) so it can carry the TTL; this
// projects the body out of it. Handing the record over instead is the bug
// this function exists to make impossible: a plugin handed an object gets
// "[object Object]" out of String(), which parses as no rates, so the row
// reads "rate table unavailable" no matter how good the fetch was. And a
// missing entry must be null rather than "", because "" means SETTLED.
function netBody(record) {
  if (record === null || record === undefined) return null
  const body = record.body
  if (body === null || body === undefined) return ""
  return String(body)
}

// Row-identity (uid) contract. The panel keys delegates, the height
// table and the no-rebuild epoch gate on uid alone (see LauncherPanel
// installRows/keyedRows), so the SHAPE of a uid decides whether typing
// updates a row in place or recreates it:
//
// - Multi-row engines (fx, unit, color): uid names the READING
//   ("fx:<pair>", "unit:<target>", "color:<format>"), never the query.
//   A reading that survives the keystroke keeps its delegate; a new
//   reading set advances the epoch and prunes the rest.
// - Single-mirror engines (calc, time, web): ONE constant uid for
//   the engine's row ("calc", mirrorUid("time"),
//   controller-stamped "web:<id>:<i>); the query and its resolution
//   travel in the payload (label/sub/item) only. Minting the uid from
//   the resolution ("time:<tz>") makes every keystroke a new identity
//   while typing, so the entry repaints per press instead of mirroring
//   the query. The incomplete-hint state shares the mirror uid.
// - Plugin main.js sources run in an eval scope with no imports, so
//   engines spell the literal and this file is the contract's home;
//   mirrorUid below exists so controller-side stamping and future
//   engines share the one shape instead of re-deriving it.
// Rendered-content equality between two row records: every field the
// delegate paints. Identity-adjacent fields (uid, clip, plugin owner, item payload) are
// the caller's job - see rowsEqual. When ignoreSub is true the sub line
// is skipped (web rows echo the live query; the patch path owns those).
function rowContentEqual(a, b, ignoreSub) {
  if (!a || !b) return false
  if (String(a.label ?? "") !== String(b.label ?? "")) return false
  if (!ignoreSub && String(a.sub ?? "") !== String(b.sub ?? "")) return false
  if (String(a.desc ?? "") !== String(b.desc ?? "")) return false
  if (String(a.icon ?? "") !== String(b.icon ?? "")) return false
  if (String(a.badge ?? "") !== String(b.badge ?? "")) return false
  if (String(a.command ?? "") !== String(b.command ?? "")) return false
  // The fabricated dot of a color row. It is painted instead of an icon rather
  // than beside one, so a swatch that changed under an unchanged label would
  // repaint a row this comparison had called equal.
  if (String(a.swatch ?? "") !== String(b.swatch ?? "")) return false
  if (String(a.swatchEdge ?? "") !== String(b.swatchEdge ?? "")) return false
  return true
}

// Row-set equality for change-aware assignment: same length plus
// per-position identity (uid), flags (clip), owners (plugin by id, so
// rescans minting fresh cfg objects still compare) and payloads (item
// copy/data), with rendered content via rowContentEqual. ignoreWebSub
// reproduces the panel's web exemption (query echo churns per keypress
// while the uid stays put).
function rowsEqual(a, b, ignoreWebSub) {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    const x = a[i]
    const y = b[i]
    if (!x || !y) return false
    if ((x.uid ?? x.kind) !== (y.uid ?? y.kind)) return false
    if ((x.clip ?? false) !== (y.clip ?? false)) return false
    const xp = x.plugin
    const yp = y.plugin
    if ((xp ? 1 : 0) !== (yp ? 1 : 0)) return false
    if (xp && yp && String(xp.id ?? "") !== String(yp.id ?? "")) return false
    const xi = x.item
    const yi = y.item
    if ((xi ? 1 : 0) !== (yi ? 1 : 0)) return false
    if (xi && yi) {
      if (String(xi.copyValue ?? "") !== String(yi.copyValue ?? "")) return false
      const xd = xi.data
      const yd = yi.data
      if ((xd ? 1 : 0) !== (yd ? 1 : 0)) return false
      if (xd && yd) {
        if (String(xd.action ?? "") !== String(yd.action ?? "")) return false
        if (String(xd.exec ?? "") !== String(yd.exec ?? "")) return false
        if (String(xd.id ?? "") !== String(yd.id ?? "")) return false
      }
    }
    const webPair = ignoreWebSub && String(x.kind ?? "") === "web"
      && String(y.kind ?? "") === "web"
    if (!rowContentEqual(x, y, webPair)) return false
  }
  return true
}

// --- process adapters: argv and verdicts ---
//
// The three probes below are the launcher's whole filesystem surface: a
// plugin directory scan, a path's existence and a timezone's clock. Each is
// an argv builder plus a verdict parser here, and a Process plus a cache
// there. The line formats are the contract between the two halves, so they
// are stated once and parsed once.

// Plugin directory scan, one absolute directory per line. The `${d%/}` in the
// loop strips a trailing slash so a root written with one still yields the
// same ids a root written without it does.
function pluginScanArgv(builtinRoot, userRoot) {
  return ["/bin/bash", "-c",
    "for r in " + shellQuote(builtinRoot) + " " + shellQuote(userRoot) + "; do\n"
    + "  [[ -d \"$r\" ]] || continue\n"
    + "  for d in \"$r\"/*; do [[ -d \"$d\" ]] && echo \"${d%/}\"; done\n"
    + "done"]
}

// The PATH scan behind the binary-launch fallback: one executable basename per
// line, in PATH order, for every regular executable in every PATH directory.
// argv only; the Process, the TTL and the cache are the controller's.
//
// PATH order is the answer's order on purpose. A name that appears in two
// directories belongs to the first, which is what a shell and `command -v`
// resolve it to, so the verdict parser's first-wins dedup reproduces the
// resolution the launch will actually perform. The explicit `exit 0` is there
// because the last `[[ ]]` in the loop is what the shell would otherwise
// report as the exit status, and a directory with no executables in it would
// read as a failed probe.
function binariesArgv() {
  return ["/bin/bash", "-c",
    "IFS=: read -ra dirs <<< \"$PATH\"\n"
    + "for d in \"${dirs[@]}\"; do\n"
    + "  [[ -d \"$d\" ]] || continue\n"
    + "  for f in \"$d\"/*; do\n"
    + "    [[ -f \"$f\" && -x \"$f\" ]] || continue\n"
    + "    printf '%s\\n' \"${f##*/}\"\n"
    + "  done\n"
    + "done\n"
    + "exit 0"]
}

// The verdict a finished scan printed: the distinct basenames, or null when
// the run produced nothing usable. Null is the honest answer for an empty
// PATH and for a shell that could not read a directory, and it is kept
// distinct from an empty list so a caller can tell "no scan has landed" from
// "the scan found nothing". Duplicates collapse to their first spelling
// because the argv prints in PATH order (see binariesArgv), which is the
// resolution a launch would pick. The `at` stamp is the caller's: it owns the
// cache, exactly as it does for timeVerdict.
function binariesVerdict(out) {
  const text = String(out ?? "")
  if (text === "") return null
  const seen = Object.create(null)
  const names = []
  const lines = text.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const n = lines[i].trim()
    if (n === "" || seen[n] === true) continue
    seen[n] = true
    names.push(n)
  }
  if (names.length === 0) return null
  return { names: names }
}

// Whether two PATH scans hold the same names in the same order. The verdict
// cache is compared by CONTENT rather than by identity, because a rescan that
// found nothing new must not republish the row: the `at` stamp differs on
// every run by construction, so comparing records would always report a change
// and the fallback row would repaint every TTL. Order-sensitive on purpose -
// PATH order is deterministic, so two scans of the same PATH print the same
// sequence, and an index-wise comparison is the honest shape of that.
function sameNameSet(a, b) {
  const x = Array.isArray(a) ? a : []
  const y = Array.isArray(b) ? b : []
  if (x.length !== y.length) return false
  for (let i = 0; i < x.length; i++) {
    if (x[i] !== y[i]) return false
  }
  return true
}

// Existence probe for one path: prints "<seq> dir|file|missing". The
// generation number is echoed back with the verdict so a run the caller
// aborted cannot come back later and overwrite a verdict about a path it
// never probed. argv only; the Process and its cancellation are the
// controller's.
function statProbeArgv(path, seq) {
  const q = shellQuote(path)
  return ["/bin/bash", "-c",
    "if [ -d " + q + " ]; then k=dir"
    + "; elif [ -f " + q + " ]; then k=file"
    + "; else k=missing; fi; echo " + seq + " $k"]
}

// The verdict a finished probe printed, or null when the line is not this
// run's answer. The null is the aborted-run guard: a stale exit is dropped,
// not stored, because the cache is keyed by the path the newer run is
// probing and a late answer would describe a path nobody asked about. A line
// with no separator, or a generation that is not a number, is never current.
function statVerdict(out, seq) {
  const line = String(out ?? "")
  const sp = line.indexOf(" ")
  const seen = sp < 0 ? -1 : parseInt(line.substring(0, sp), 10)
  if (seen !== seq) return null
  const kind = line.substring(sp + 1)
  return { current: true, verdict: kind === "dir" ? "dir" : kind === "file" ? "file" : "missing" }
}

// Zones that read the clock on a 12-hour dial, as IANA names. An entry
// matches the zone itself and every zone under it, so "America/Argentina"
// also covers Buenos_Aires and "America/Indiana" all seven of its cities.
// Everything else reads 24-hour: the majority of tzdata, and the answer that
// stays correct for a zone a later tzdata release adds.//
// The convention is a country's, not a city's (CLDR's timeData), so a place
// that writes the time both ways keeps the majority form. That is why
// America/Santiago, the Brazilian zones and Danish Greenland are absent from
// an otherwise 12-hour neighbourhood, and why the Brazilian states and
// Chile's Magallanes region that kept a 12-hour dial are named on their own.
// `var` rather than `const` because a module-scope `const` is a lexical
// binding that never becomes a property of this library's namespace - so
// nothing outside this file, the launcher suite included, could read the table.
var H12_ZONES = [
  // Americas: North and Central America, the Caribbean, and the half of
  // South America that writes 12 hours.
  "America/Adak", "America/Anchorage", "America/Antigua", "America/Anguilla",
  "America/Argentina", "America/Aruba", "America/Asuncion", "America/Atikokan",
  "America/Barbados", "America/Belize", "America/Blanc-Sablon", "America/Boise",
  "America/Buenos_Aires", "America/Cambridge_Bay", "America/Cancun",
  "America/Caracas", "America/Catamarca", "America/Cayenne", "America/Cayman",
  "America/Chicago", "America/Chihuahua", "America/Ciudad_Juarez",
  "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica",
  "America/Creston", "America/Dawson", "America/Dawson_Creek", "America/Detroit",
  "America/Dominica", "America/Edmonton", "America/El_Salvador",
  "America/Ensenada", "America/Fort_Nelson", "America/Glace_Bay",
  "America/Goose_Bay", "America/Grand_Turk", "America/Grenada",
  "America/Guadeloupe", "America/Guatemala", "America/Guayaquil",
  "America/Guyana", "America/Halifax", "America/Havana", "America/Indiana",
  "America/Jamaica", "America/Jujuy", "America/Kentucky", "America/Knox_IN",
  "America/Kralendijk", "America/La_Paz", "America/Lima",
  "America/Los_Angeles", "America/Louisville", "America/Lower_Princes",
  "America/Managua", "America/Marigot", "America/Martinique",
  "America/Matamoros", "America/Mazatlan", "America/Mendoza",
  "America/Menominee", "America/Merida", "America/Mexico_City",
  "America/Miquelon", "America/Moncton", "America/Monterrey",
  "America/Montevideo", "America/Montreal", "America/Montserrat",
  "America/Nassau", "America/New_York", "America/Nipigon", "America/Nome",
  "America/North_Dakota", "America/Ojinaga", "America/Pangnirtung",
  "America/Panama", "America/Paramaribo", "America/Phoenix",
  "America/Port-au-Prince", "America/Port_of_Spain", "America/Puerto_Rico",
  "America/Punta_Arenas", "America/Rankin_Inlet", "America/Regina",
  "America/Resolute", "America/Rosario", "America/Santa_Isabel",
  "America/Santo_Domingo", "America/Shiprock", "America/Sitka",
  "America/St_Barthelemy", "America/St_Johns", "America/St_Kitts",
  "America/St_Lucia", "America/St_Thomas", "America/St_Vincent",
  "America/Swift_Current", "America/Tegucigalpa", "America/Thunder_Bay",
  "America/Tijuana", "America/Toronto", "America/Tortola", "America/Vancouver",
  "America/Virgin", "America/Whitehorse", "America/Winnipeg", "America/Yakutat",
  "America/Yellowknife",
  // Brazil, minus the states that moved to 24 hours (Acre, Para, Bahia, the
  // coast) and the Fernando de Noronha link.
  "America/Boa_Vista", "America/Campo_Grande", "America/Cuiaba",
  "America/Manaus", "America/Porto_Velho",
  // Africa: the western, eastern and central zones whose countries keep the
  // dial; the Maghreb, the Gulf states' neighbours and the Atlantic islands
  // read 24.
  "Africa/Accra", "Africa/Addis_Ababa", "Africa/Asmara", "Africa/Asmera",
  "Africa/Brazzaville", "Africa/Bujumbura", "Africa/Cairo",
  "Africa/Dar_es_Salaam", "Africa/Djibouti", "Africa/Douala",
  "Africa/Freetown", "Africa/Kampala", "Africa/Kigali", "Africa/Kinshasa",
  "Africa/Lagos", "Africa/Libreville", "Africa/Luanda", "Africa/Lubumbashi",
  "Africa/Mogadishu", "Africa/Monrovia", "Africa/Nairobi",
  // Asia: the Near East, the Indian subcontinent and the Pacific rim, plus
  // Mongolia and the two Chinese zones that keep a local dial. Russia,
  // Central Asia, the Caucasus, Turkey and Cyprus read 24.
  "Asia/Aden", "Asia/Amman", "Asia/Baghdad", "Asia/Bahrain", "Asia/Beirut",
  "Asia/Brunei", "Asia/Calcutta", "Asia/Choibalsan", "Asia/Chongqing",
  "Asia/Chungking", "Asia/Colombo", "Asia/Dacca", "Asia/Damascus",
  "Asia/Dhaka", "Asia/Dili", "Asia/Dubai", "Asia/Gaza", "Asia/Harbin",
  "Asia/Hebron", "Asia/Ho_Chi_Minh", "Asia/Hong_Kong", "Asia/Hovd",
  "Asia/Jakarta", "Asia/Jayapura", "Asia/Jerusalem", "Asia/Kabul",
  "Asia/Karachi", "Asia/Kashgar", "Asia/Kathmandu", "Asia/Katmandu",
  "Asia/Kolkata", "Asia/Kuala_Lumpur", "Asia/Kuching", "Asia/Kuwait",
  "Asia/Macao", "Asia/Macau", "Asia/Makassar", "Asia/Manila",
  "Asia/Muscat", "Asia/Phnom_Penh", "Asia/Pontianak", "Asia/Pyongyang",
  "Asia/Qatar", "Asia/Rangoon", "Asia/Riyadh", "Asia/Saigon", "Asia/Seoul",
  "Asia/Shanghai", "Asia/Singapore", "Asia/Taipei", "Asia/Tehran",
  "Asia/Tel_Aviv", "Asia/Thimbu", "Asia/Thimphu", "Asia/Tokyo",
  "Asia/Ujung_Pandang", "Asia/Ulaanbaatar", "Asia/Ulan_Bator", "Asia/Yangon",
  // Indian Ocean, the one zone that keeps a 12-hour dial.
  "Indian/Maldives",
  // Australia: one entry, because the country is uniform - every state,
  // territory and the offshore islands write 12 hours, and a later tzdata
  // release that adds another Australian zone should not have to come back
  // here to be right.
  "Australia",
  // Pacific: the oceanic states, Micronesia, French Polynesia, New Zealand
  // and the US territories. Hawaii is here, Chile's Easter Island is not.
  "Pacific/Apia", "Pacific/Auckland", "Pacific/Chatham", "Pacific/Chuuk",
  "Pacific/Efate", "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji",
  "Pacific/Funafuti", "Pacific/Gambier", "Pacific/Guam", "Pacific/Honolulu",
  "Pacific/Kanton", "Pacific/Kiritimati", "Pacific/Kosrae",
  "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas",
  "Pacific/Midway", "Pacific/Nauru", "Pacific/Niue", "Pacific/Pago_Pago",
  "Pacific/Palau", "Pacific/Ponape", "Pacific/Pohnpei",
  "Pacific/Port_Moresby", "Pacific/Rarotonga", "Pacific/Saipan",
  "Pacific/Tahiti", "Pacific/Tarawa", "Pacific/Tongatapu", "Pacific/Wake",
  "Pacific/Wallis", "Pacific/Yap"
]

// The `date` format for the time field of a zone's clock probe. A zone is
// read on its own dial, never on the OS's, so "time in Chicago" prints
// "01:00 PM" on a machine set to 24 hours and "time in Madrid" prints
// "13:00" on one set to 12. The dial is a pure function of the zone, so a
// reading in the cache is already on the right one and a format change never
// has to re-probe.
function timeProbeFormat(tz) {
  const z = String(tz ?? "")
  for (let i = 0; i < H12_ZONES.length; i++) {
    const r = H12_ZONES[i]
    if (z === r || (z.length > r.length && z.startsWith(r + "/"))) return "%I:%M %p"
  }
  return "%H:%M"
}

// The clock probe prints "HH:MM|CODE|OFFSET|DATE" (e.g.
// "14:32|CEST|+0200|Fri 11 Sep"), or the 12-hour "01:00 PM" in the zones that
// keep that dial (see timeProbeFormat); a DATE carrying a pipe keeps the tail
// intact. null when the line is too short to be an answer. `changed` is
// false for an identical verdict, which is what lets a minute-boundary
// probe that read the same time rest instead of repainting the row.
function timeVerdict(line, previous) {
  const parts = String(line ?? "").trim() === "" ? [] : String(line).trim().split("|")
  if (parts.length < 4) return null
  const reading = {
    time: parts[0],
    code: parts[1],
    offset: parts[2],
    date: parts.slice(3).join("|")
  }
  const cur = previous
  const changed = !cur || cur.time !== reading.time || cur.code !== reading.code
    || cur.offset !== reading.offset || cur.date !== reading.date
  return { changed: changed, reading: reading }
}

// --- Exec parsing and launch routing ---

// The app's Exec parsed into an argv array. Prefers DesktopEntries' parsed
// command array; otherwise whitespace-splits the raw Exec string. %-fields
// (e.g. %U, %f) are dropped because the launcher passes no URL/file
// selection, and a dropped field leaves a now-meaningless trailing separator
// (`--` / `--url`, e.g. `discord --url -- %u`) which is peeled so the shim
// never receives it. Parsing only: handing the result to a process is the
// controller's.
function execArgs(entry) {
  let parts = (entry && Array.isArray(entry.command)) ? entry.command : []
  if (parts.length === 0) {
    const raw = entry ? String(entry.execString ?? "").trim() : ""
    if (raw === "") return []
    parts = raw.split(/\s+/)
  }
  const args = []
  let droppedField = false
  for (let i = 0; i < parts.length; i++) {
    const t = String(parts[i] ?? "")
    if (t === "") continue
    if (t.charAt(0) === "%") {
      droppedField = true
      continue
    }
    args.push(t)
  }
  if (droppedField) {
    while (args.length > 0 && (args[args.length - 1] === "--" || args[args.length - 1] === "--url")) args.pop()
  }
  return args
}

// The bash vb-launch-* shims own focus-or-launch (they match an existing
// window and focus it, or start the app), so selecting an entry delegates to
// them rather than matching windows in JS:
//   - Terminal=true entries (yazi) open inside a terminal via
//     vb-launch-tui (Quickshell's DesktopEntry.execute() ignores
//     runInTerminal, which is why the launcher wraps them).
//   - Entries whose Exec already is a vb-launch-* wrapper (TUI / PWA
//     entries use vb-launch-tui / vb-launch-webapp) run as-is.
//   - Everything else goes through vb-launch-cmd -- <command>.
// argv only; the detached exec is the facade's, so a command outlives the
// launcher.
function launchArgv(args, runInTerminal) {
  if (runInTerminal) return ["vb-launch-tui", "--"].concat(args)
  const first = args.length > 0 ? String(args[0]) : ""
  if (first === "vb-launch-cmd" || first === "vb-launch-tui" || first === "vb-launch-webapp") {
    return args
  }
  return ["vb-launch-cmd", "--"].concat(args)
}

// --- local path detection (file-opener row) ---

// A query that is really a single local path: rooted at "/" or "~"
// (optionally tilde-expanded via `home`), one path segment chain only.
// Internal spaces are allowed - pasted paths regularly contain them -
// because a meaningful search query never starts with "/" or "~".
// Returns the expanded, trailing-slash-stripped path or "" when the
// input is not a path candidate. The caller decides existence via a
// filesystem probe; this stays pure so it is unit-drivable.
function localPathCandidate(text, home) {
  const t = String(text ?? "").trim()
  if (t === "" || t.length > 4096) return ""
  if (t.indexOf("\n") >= 0) return ""
  let p = t
  if (p === "~") {
    if (!home || home === "") return ""
    p = home
  } else if (p.indexOf("~/") === 0) {
    if (!home || home === "") return ""
    p = home + p.substring(1)
  }
  if (p.charAt(0) !== "/") return ""
  while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
  return p
}

// Last path segment for the "Open <basename>" row title. Trailing
// slashes are stripped here too so untrimmed input still reads right;
// the filesystem root names itself.
function pathBasename(path) {
  let p = String(path ?? "")
  while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
  if (p === "" || p === "/") return p
  return p.split("/").pop() || p
}

// Icon basename for the file-opener row, routed through ClipboardLib's
// exact extension mapping (image, archive, pdf, code, ...). Directories
// use the clipboard folder glyph; unknown extensions fall back to the
// generic file glyph - the same fallback ClipboardEntry applies.
function pathIconName(isDir, path) {
  if (isDir) return "file-folder"
  return CL.extIconName(path) || "file"
}

// --- URI handling (file-opener row) ---

const RE_FILE_URI = /^file:\/\//i
const RE_URI_TAIL = /^([a-z][a-z0-9+.-]*):\/\/([^\/?#]*)(\/[^?#]*)?/i

// %XX decoder for URI path segments; malformed sequences keep the raw
// text (decodeURIComponent throws on them).
function percentDecode(s) {
  const t = String(s ?? "")
  if (t.indexOf("%") < 0) return t
  try { return decodeURIComponent(t) } catch (e) { return t }
}

// file://host/path - only an empty or localhost authority maps to the
// local filesystem, anything else is not a local file. Returns the
// decoded, trailing-slash-stripped path or "".
function fileUriPath(text) {
  const t = String(text ?? "").trim()
  if (!RE_FILE_URI.test(t)) return ""
  let rest = t.substring(7)
  if (rest.indexOf("localhost") === 0) rest = rest.substring(9)
  let p = percentDecode(rest)
  if (p.charAt(0) !== "/") return ""
  while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
  return p
}

// Human-facing tail of a remote URI for the row title: the last path
// segment when one exists, else the host. Percent-decoded for display.
function uriBasename(u) {
  const m = String(u ?? "").match(RE_URI_TAIL)
  if (!m) return String(u ?? "")
  const host = m[2]
  const path = m[3] ? percentDecode(m[3]) : ""
  if (path !== "" && path !== "/") return pathBasename(path)
  return host
}

// Full opener-target resolution for a query. Returns null when the query
// is not openable, otherwise:
//   { kind: "local", path, basename } - probe the fs, then open
//   { kind: "uri",   uri,  basename } - open directly, nothing to probe
// file:// URIs unwrap into local paths and follow the local flow (so a
// dead file:// link falls back to web search); network schemes (ftp,
// sftp, smb, ssh, ...) and http(s) open as-is via xdg-open.
function openTarget(text, home) {
  const t = String(text ?? "").trim()
  if (t === "" || t.length > 4096) return null
  if (t.indexOf("\n") >= 0) return null
  const fp = fileUriPath(t)
  if (fp !== "") return { kind: "local", path: fp, basename: pathBasename(fp) }
  const head = t.match(RE_URI_TAIL)
  if (head) {
    const s = head[1].toLowerCase()
    if (s === "http" || s === "https" || CL.isNetworkUri(t))
      return { kind: "uri", uri: t, basename: uriBasename(t) }
  }
  const p = localPathCandidate(t, home)
  if (p === "") return null
  return { kind: "local", path: p, basename: pathBasename(p) }
}

// The openable target the newest clipboard entry names, or null.
// Any entry that names exactly one destination file participates -
// uri-list copies (file managers, screenshot tools) land here whatever
// their content type says (image, folder, archive, ...) - plus URL,
// network and path-shaped text entries. Secrets and raw binary
// payloads never suggest anything. Returns
// { kind: "url" | "uri" | "local", value, basename }.
function clipTargetFor(entry, home) {
  if (!entry) return null
  const secretType = String(entry.type ?? "")
  if (secretType === "secret" || secretType === "credential"
    || secretType === "credentials") return null
  const paths = entry.filePaths
  if (paths && paths.length === 1) {
    let p = String(paths[0]).trim()
    while (p.length > 1 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
    if (p.charAt(0) === "/")
      return { kind: "local", value: p, basename: pathBasename(p) }
  }
  const type = String(entry.type ?? "text")
  if (type === "url") {
    const u = String(entry.raw ?? "").trim()
    return u === "" ? null : { kind: "url", value: u }
  }
  if (type === "network") {
    const t = openTarget(String(entry.raw ?? ""), home)
    return t && t.kind === "uri"
      ? { kind: "uri", value: t.uri, basename: t.basename } : null
  }
  if (type === "text") {
    // Text that is really a path or protocol URI (terminal copies).
    const t = openTarget(String(entry.raw ?? ""), home)
    if (!t) return null
    return t.kind === "local"
      ? { kind: "local", value: t.path, basename: t.basename }
      : { kind: "uri", value: t.uri, basename: t.basename }
  }
  return null
}

// The folder/file verdict the entry settled for itself at capture time, or
// "" when it settled none. A uri-list copy names one real destination and
// the clipboard service resolves folder-vs-file for it with a find pass as
// the entry is built (ClipboardLib.projectFileInfo), so the launcher can
// render the suggestion in that shape on the first frame instead of holding
// the row back for a stat probe it does not need. The same check
// clipTargetFor makes - exactly one absolute path - gates it, so a hint can
// never exist for an entry that resolves to no local target at all.
// A path-shaped text entry was never probed, and answers "".
function clipEntryKind(entry) {
  if (!entry) return ""
  const secretType = String(entry.type ?? "")
  if (secretType === "secret" || secretType === "credential"
    || secretType === "credentials") return ""
  const paths = entry.filePaths
  if (!paths || paths.length !== 1) return ""
  if (String(paths[0]).trim().charAt(0) !== "/") return ""
  return String(entry.type ?? "") === "folder" ? "dir" : "file"
}

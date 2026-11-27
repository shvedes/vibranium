pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQml as Qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import "MenuLib.js" as MenuLib
import "MenuIndex.js" as MenuIndex
import "MenuState.js" as MenuState
import "../../common/math/Range.js" as Range
import "../../common/settings/SettingsLib.js" as SettingsLib
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/text/IpcCatalog.js" as Catalog
import "MenuIpc.js" as MenuIpc

// Menu service: owns loaded bundles, the page stack, search state and the
// per-item runtime store. Rendering lives in MenuView/MenuPanel; rows call
// back into here for navigation and command execution.
//
// IPC surface (vb-shell menu <function> / qs ipc call menu <function>):
//   openFile <path>   load a bundle file and show its entry page
//   open '<json>'     same, inline
//   close             dismiss instantly
//   status            JSON snapshot for scripting
//   dump              normalized structure with guard results applied
//   probe             live view introspection (row type, expansion, ...)
//
// SPLIT MAP (one owner each, no behavior change): Stack (page stack:
// staged-flow cursor, navigation, expansion slots), SearchIndex
// (external search index, scoped "/" quick-filter, item state),
// Guards (guard expressions, isChecked/handleToggle verdicts, actions,
// IPC surface).
Singleton {
  id: root

  readonly property string tag: "menu"

  // Global animation kill switch. Hyprland's Appearance -> Animations ->
  // Enabled owns this through the hypr.* store: only an explicit false
  // disables menu motion (opens/resizes/submenu slidefade, row
  // add/remove, toggles, buttons, progress fills). Reactive - the
  // accessor captures the store rev, so toggling the setting re-evaluates
  // this binding live. Select expansion is gated too, one level down, in
  // the shared DropdownSlot every surface unfolds through. Unknown (store
  // not ready) disables until known, so a cold-boot open never slides.

  // Loaded bundle: entry page id plus pages by id.
  property var bundle: null
  // Flat fuzzy-search index over every selectable item of the bundle,
  // followed by the external registrations below. Derived state: never
  // assign it directly, go through _rebuildSearchIndex(). Merge order is
  // the deprioritization - search() sorts on score alone with a stable sort,
  // so an equal-scoring tie resolves to the bundle half.
  property var searchIndex: []
  // Bundle-derived index on its own.
  property var _builtinIndex: []
  // ownerId -> index entries, for pages and sources outside the bundle
  // (injected picker pages enumerate the disk, so their rows are data the
  // bundle parser never sees). Replace-by-owner: one call replaces the
  // owner's whole set, which is what makes a re-composed page correct.
  property var _indexRegistrations: ({})
  // Navigation stack of frames {id, sel}; last frame is on screen.
  // Open/close is intentionally instant - no window animation.
  property var stack: []

  // Guard answers from the last batched evaluation: three maps
  // uid -> bool keyed "w" (when/visibility), "c" (checked), "d" (disabled).
  property var guardWhen: ({})
  property var guardChecked: ({})
  property var guardDisabled: ({})

  // uid -> true for submenu links whose target page currently has nothing
  // usable on it: a page that never arrived, or one whose selectable rows are
  // all blocked by a condition. The link keeps its slot and is muted by
  // isUnavailable; search stops offering it because isVisible answers false
  // (groupSearchResults filters through isVisible).
  property var _deadLinks: ({})

  // Current search query; non-empty flips panels into results mode.
  property string query: ""
  // Ranked window of `searchIndex x query`, republished on both of its
  // inputs. _applyQuery is the one writer; an index rebuild re-runs it so a
  // late external registration cannot leave the old window on screen.
  property var results: []
  property bool _applyingQuery: false
  readonly property bool searching: root.query !== ""

  // In-page "/" quick-filter. Unlike cross-page search it does not alter
  // the navigation frame; it simply filters the current page's rows.
  property bool scopedActive: false
  property string scopedQuery: ""
  // The panel derives its flat result rows from scopedQuery through
  // MenuLib.scopedResultRows; this counter is only the publish edge that
  // tells it to re-derive. Storing the rows here created a second copy.
  property int scopedProjectionRev: 0
  // The filter's tree scope: every uid kept at any depth, and the groups whose
  // child lists are narrowed to that set. Entry.groupChildren reads these so a
  // group under a filter shows only the branches that matched, at its own
  // register, with its own dropdown bar and background.
  property var scopedVisibleUids: ({})
  property var scopedTrimmedGroups: ({})
  readonly property bool scopedSearching: root.scopedActive && root.scopedQuery !== ""

  // Per-row state, keyed by normalized stable uid.
  property var _states: ({})
  property int rev: 0

  // --- public gateway bookkeeping -----------------------------------------
  // One open generation per successful replacement/open. Row refs are retired
  // on close; page ordinals retire when the object under a page id is replaced
  // so a recycled uid or a rebuilt page can never inherit old refs.
  property int openGeneration: 0
  property string ipcIncarnation: ""
  property var _refPages: ({})
  property int _pageOrdinalSeq: 0
  property int _rowOrdinalSeq: 0
  property var _refsByValue: ({})
  property var _landingIntent: null
  property bool _ipcRegistered: false
  property bool _ipcProviderPending: false

  // The current frame and page are derived from the navigation stack.
  readonly property var frame: root.stack.length ? root.stack[root.stack.length - 1] : null
  readonly property string pageId: root.frame ? root.frame.id : ""
  readonly property var page: root.pageById(root.pageId)
  readonly property bool open: root.stack.length > 0

  // Only the bundle's entry page opens. Search and stack operations are
  // kept on the singleton so either renderer can drive them identically.
  property var _dynamicPages: ({})
  property var _optionPages: ({})
  property var _dynamicApis: ({})
  property var _indexProviders: []
  // Path -> companion bundle for pickers whose search-only rows live in a
  // separate file. The marker is a `// lazy-search:` line in the primary
  // file, read during _buildFromFile; the companion is loaded on the first
  // query so a session that never searches never parses the large corpus.
  property var _lazySearchPaths: ({})
  property int _pendingQueryGen: 0
  property var _claimToken: null
  property bool _settingsFamily: false
  property var viewState: ({})
  property int pendingSel: -1
  property var _restorePending: ({})

  // These loaders are synchronous by design: file bundles are small local
  // config data and must be completely available before the menu opens.
  FileView {
    id: loader
    path: ""
    printErrors: false
  }
  FileView {
    id: extensionLoader
    path: ""
    printErrors: false
  }
  FileView {
    id: lazyLoader
    path: ""
    printErrors: false
  }
  FileView {
    path: ""
    printErrors: false
  }

  // One explicit closure per catalog row id. The map is declared inside the
  // registration so the manifest's static check sees exactly the same set the
  // router receives at runtime.
  Component.onCompleted: {
    root._ipcRegistered = IpcRouter.register("menu", root, {
      "menu.open.inline": function (a, ctx) {
        const text = ctx.tokens.JSON !== undefined ? String(ctx.tokens.JSON) : JSON.stringify(a.JSON)
        const hash = text.indexOf("#")
        const frag = hash < 0 ? "" : text.substring(hash + 1)
        return root.ipcOpen({ inline: true, text: hash < 0 ? text : text.substring(0, hash),
          frag: frag });
      },
      "menu.open.file": function (a) { return root.ipcOpen({ path: a.PATH }) },
      "menu.toggle.inline": function (a, ctx) {
        const text = ctx.tokens.JSON !== undefined ? String(ctx.tokens.JSON) : JSON.stringify(a.JSON)
        const hash = text.indexOf("#")
        const frag = hash < 0 ? "" : text.substring(hash + 1)
        return root.ipcToggle({ inline: true, text: hash < 0 ? text : text.substring(0, hash),
          frag: frag });
      },
      "menu.toggle.file": function (a) { return root.ipcToggle({ path: a.PATH }) },
      "menu.close": function () { return root.ipcClose() },
      "menu.pages": function () { return root.ipcPages() },
      "menu.go": function (a) { return root.ipcGo(a.PAGE) },
      "menu.back": function () { return root.ipcBack() },
      "menu.list": function (a) { return root.ipcList(a.PAGE) },
      "menu.current": function () { return root.ipcCurrent() },
      "menu.select": function (a) { return root.ipcSelect(a.ROW) },
      "menu.search.global": function (a) { return root.ipcSearch("global", a.QUERY) },
      "menu.search.scoped": function (a) { return root.ipcSearch("scoped", a.QUERY) },
      "menu.search.clear": function () { return root.ipcSearch("clear", "") },
      "menu.item.ROW.get": function (a) { return root.ipcItemGet(a.ROW) },
      "menu.item.ROW.activate": function (a) { return root.ipcItem(a.ROW, "activate", {}) },
      "menu.item.ROW.open": function (a) { return root.ipcItem(a.ROW, "open", {}) },
      "menu.item.ROW.close": function (a) { return root.ipcItem(a.ROW, "close", {}) },
      "menu.item.ROW.toggle": function (a) { return root.ipcItem(a.ROW, "toggle", {}) },
      "menu.item.ROW.set": function (a) { return root.ipcItem(a.ROW, "set", { value: a.JSON }) },
      "menu.item.ROW.step.up": function (a) { return root.ipcItem(a.ROW, "step", { direction: "up" }) },
      "menu.item.ROW.step.down": function (a) { return root.ipcItem(a.ROW, "step", { direction: "down" }) },
      "menu.item.ROW.options": function (a) { return root.ipcItem(a.ROW, "options", {}) },
      "menu.item.ROW.choose": function (a) { return root.ipcItem(a.ROW, "choose", { option: a.OPTION }) },
      "menu.item.ROW.info.open": function (a) { return root.ipcItem(a.ROW, "info", { mode: "open" }) },
      "menu.item.ROW.info.close": function (a) { return root.ipcItem(a.ROW, "info", { mode: "close" }) },
      "menu.item.ROW.confirm.status": function (a) { return root.ipcItem(a.ROW, "confirm", { verb: "status" }) },
      "menu.item.ROW.confirm.next": function (a) { return root.ipcItem(a.ROW, "confirm", { verb: "next" }) },
      "menu.item.ROW.confirm.cancel": function (a) { return root.ipcItem(a.ROW, "confirm", { verb: "cancel" }) },
      "menu.item.ROW.flow.status": function (a) { return root.ipcItem(a.ROW, "flow", { verb: "status" }) },
      "menu.item.ROW.flow.next": function (a) { return root.ipcItem(a.ROW, "flow", { verb: "next" }) },
      "menu.item.ROW.flow.back": function (a) { return root.ipcItem(a.ROW, "flow", { verb: "back" }) },
      "menu.item.ROW.flow.commit": function (a) { return root.ipcItem(a.ROW, "flow", { verb: "commit" }) },
      "menu.item.ROW.flow.cancel": function (a) { return root.ipcItem(a.ROW, "flow", { verb: "cancel" }) },
      "menu.item.ROW.flow.set": function (a) {
        return root.ipcItem(a.ROW, "flow", { verb: "set", step: a.STEP, value: a.JSON });
      },
      "menu.item.ROW.delete": function (a) { return root.ipcItem(a.ROW, "delete", {}) },
      "menu.status": function () { return root.ipcOwnerStatus() },
      "menu.ping": function () { return root.ipcPing() }
    })
    Registry.offer("menu", {
      title: "Menu",
      description: "Open and control menu bundles",
      verbNames: Catalog.topLevelVerbs("menu")
    })
    Registry.register("menu", root)
    // Page surface half of the PageHost contract: state owners publish
    // page descriptors (IdleDaemon's timer list) and this handler builds
    // and registers them, so neither side names the other. A first adopt
    // replays requests that arrived before any surface existed.
    PageHost.adopt(root._pageHostHandler)
    // Boot alongside the shell: build the two most-opened bundles and run
    // their guard batches in the background, so the first summon finds warm
    // containers AND warm verdicts instead of painting an unguarded frame
    // (Copy track flashing, Settings arriving late). Retried until the
    // settings stores are ready - the main bundle joins their pages, and a
    // prewarm without them would cache a settings-less container.
    Qt.callLater(root._maybePrewarm)
  }

  Component.onDestruction: {
    IpcRouter.unregister("menu", root)
    PageHost.release(root._pageHostHandler)
    Registry.unregister("menu")
  }

  // Stable handler reference for the adopt above: identity comparison is
  // what keeps a re-adopt idempotent, so this is one stored closure,
  // not a per-call one.
  property var _pageHostHandler: function(request) { return root._injectExternalPage(request) }

  function _injectExternalPage(request) {
    if (!request || typeof request.id !== "string" || request.id === "") return false
    // Settings-family pages (idle timers) never join a standalone picker
    // bundle: republished on every container reload, they would otherwise
    // land in single-purpose menus like themes and answer search there.
    if (!root.externalPagesAllowed()) return false
    try {
      const page = root.buildDynamicPage(request.id, request.title,
        request.width, request.items, request.opts)
      return root.injectPage(page, null)
    } catch (e) {
      return false
    }
  }

  // `path` may carry a #page fragment selecting the entry inside the
  // unified catalog (catalog.jsonc#utilities). Bare catalog path means
  // the settings index; menu keybinds pass #main / #utilities.
  function openFile(path) {
    // ONE surface serves every page, so the requested path decides what an
    // already-open menu does: the same path again is the keybind's toggle, a
    // different one replaces what is showing. Closing on any open menu made
    // #utilities then #main a close with nothing opening. The close runs
    // before the build so the runtime is unwound and the build's own `wasOpen`
    // snapshot is false.
    if (root.open) {
      const same = root._lastPath === path
      root.close()
      if (same) return true
    }
    if (!root._buildFromFile(path)) return false
    root._primeRuntime(root.bundle)
    const frag = root._entryFragment(path)
    if (frag !== "" && root.bundle && root.bundle.byId && root.bundle.byId[frag] !== undefined) {
      root.stack = [{ id: frag, sel: 0, y: 0 }]
    } else if (root._catalogFile(path) && root.bundle && root.bundle.byId
      && root.bundle.byId["settings"] !== undefined) {
      root.stack = [{ id: "settings", sel: 0, y: 0 }]
    }
    root._claimToken = SurfaceClaim.claim("menu", root.close, root)
    Qt.callLater(root.evaluateGuards)
    return true
  }

  function _entryFragment(path) {
    const i = String(path).indexOf("#")
    return i < 0 ? "" : String(path).substring(i + 1)
  }

  function _catalogFile(path) {
    const s = String(path)
    const h = s.indexOf("#")
    const file = h < 0 ? s : s.substring(0, h)
    return file === Paths.settingsBundlePath || file === Paths.settingsCatalogPath
  }

  function _canonicalSource(path) {
    const s = String(path ?? "")
    const h = s.indexOf("#")
    return h < 0 ? s : s.substring(0, h)
  }

  // The emoji picker asks whether its own bundle is already showing before it
  // closes anything. Fragments select an entry inside one source, so they are
  // deliberately ignored here; an inline bundle has no file source.
  function isBundleOpen(path) {
    if (!root.open || root._lastPath === undefined || root._lastPath === "") return false
    const want = root._canonicalSource(path)
    return want !== "" && root._canonicalSource(root._lastPath) === want
  }

  function toggleFile(path) {
    if (root.open && root._lastPath === path) {
      root.close()
      return true
    }
    root.close()
    return root.openFile(path)
  }

  function close() {
    if (!root.open) return
    root.stack = []
    root._retireRefs()
    root.resetSearch()
    root._states = ({})
    // Flow stages are session state: a wizard left half-filled must not stay
    // parked on its later stage when the same menu is summoned again.
    root._flow = ({})
    root._slotCloses = ({})
    root.rev++
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
    // A preload that found the menu open skipped itself; the close edge is
    // the next safe moment to build the companion without disturbing a fit.
    if (!root._lazyPreloaded && !root._lazyPreloadScheduled) {
      root._lazyPreloadScheduled = true
      Idle.run(root._preloadLazySearches)
    }
  }

  // Build (or reuse cached) containers for `path` WITHOUT touching any
  // runtime state - no stack, no window, no guards. Used by openFile and
  // by boot-time prewarm so the first real keybind press finds warm
  // containers instead of paying the QV4 parse.
  function _buildFromFile(path) {
    // A bundle build can run while the menu is showing a different bundle.
    // Snapshot the active containers and restore them on exit, so the
    // build never swaps the bundle out from under a live view.
    const wasOpen = root.open
    const prevBundle = root.bundle
    const prevSearch = root._builtinIndex
    const prevFamily = root._settingsFamily

    // Reassigning the same path is a no-op for FileView, which would make
    // a second open of one bundle skip loading entirely. A #page fragment
    // selects the entry only - the file read strips it, and the cache is
    // keyed by file so #main and #utilities share one built bundle.
    const hashAt = String(path).indexOf("#")
    const filePath = hashAt < 0 ? path : String(path).substring(0, hashAt)
    const frag = hashAt < 0 ? "" : String(path).substring(hashAt + 1)
    loader.path = ""
    loader.path = filePath
    if (!loader.waitForJob()) return false
    root._lastPath = path
    const text = loader.text()
    root._registerLazySearch(text, filePath)

    // Repeat-summon cache: parsing/normalizing a bundle costs enough to
    // justify reusing the three most recent built containers (the two boot
    // entries plus a lazily preloaded picker). Any change to
    // source file, extension, or settings-store generation rebuilds it.
    const extPath = Paths.configHome
    extensionLoader.path = extPath + "/vibranium/user-menu.jsonc"
    const extText = extensionLoader.waitForJob() ? extensionLoader.text() : ""
    // Keyed by the full path: each entry (#main, #utilities, bare) builds
    // its own entry-scoped search index below.
    const cached = root._bundleCache[path]
    const sval = Settings.values
    const hrev = HyprlandSettings.ready ? HyprlandSettings.rev : 0
    const mrev = MiscSettings.ready ? MiscSettings.rev : 0
    if (cached !== undefined && cached.text === text && cached.ext === extText
      && cached.sval === sval && cached.hrev === hrev && cached.mrev === mrev) {
      root.bundle = cached.bundle
      root._builtinIndex = cached.index
      root._settingsFamily = cached.settingsFamily === true
      root._rebuildSearchIndex()
      if (wasOpen) {
        root.bundle = prevBundle
        root._builtinIndex = prevSearch
        root._settingsFamily = prevFamily
        root._rebuildSearchIndex()
      }
      root._restoreExternalPages()
      return true
    }
    try {
      root._loadContainers(text, extText, frag)
      const keys = Object.keys(root._bundleCache)
      if (keys.length >= 3) delete root._bundleCache[keys[0]]
      root._bundleCache[path] = {
        text: text,
        ext: extText,
        sval: sval,
        hrev: hrev,
        mrev: mrev,
        bundle: root.bundle,
        index: root._builtinIndex,
        settingsFamily: root._settingsFamily
      }
    } catch (e) {
      return false
    }
    if (wasOpen) {
      root.bundle = prevBundle
      root._builtinIndex = prevSearch
      root._settingsFamily = prevFamily
      root._rebuildSearchIndex()
    }
    root._restoreExternalPages()
    return true
  }

  // A bundle can point at a companion file holding rows that only search
  // needs. The marker lives in the JSONC header, so the data owns the
  // contract and the generic menu needs no per-picker path.
  function _lazyCompanion(text, filePath) {
    const m = /^\/\/ lazy-search:[ \t]*(\S+)[ \t]*$/m.exec(String(text ?? ""))
    if (!m) return ""
    const name = m[1]
    const slash = String(filePath).lastIndexOf("/")
    return slash < 0 ? name : String(filePath).substring(0, slash + 1) + name
  }

  function _registerLazySearch(text, filePath) {
    const companion = root._lazyCompanion(text, filePath)
    const current = root._lazySearchPaths[filePath]
    if (companion === "") {
      if (current === undefined) return
      const cleared = Object.assign({}, root._lazySearchPaths)
      delete cleared[filePath]
      root._lazySearchPaths = cleared
      return
    }
    if (current !== undefined && current.companion === companion) return
    const next = Object.assign({}, root._lazySearchPaths)
    next[filePath] = { companion: companion }
    root._lazySearchPaths = next
  }

  // Read the companion of one cached bundle and fold its pages into that
  // container. Mutating the cached object (rather than installing a new one)
  // keeps the panel's onBundleChanged out of an active search: a wholesale
  // bundle swap there drops the seat the search exit needs to fade back in.
  function _mergeLazyCompanion(cached, companion) {
    if (!cached || !cached.bundle || cached.bundle.lazySearchLoaded === true) return false
    lazyLoader.path = ""
    lazyLoader.path = companion
    if (!lazyLoader.waitForJob()) return false
    let extra = null
    try {
      extra = MenuLib.parseBundle(lazyLoader.text())
    } catch (e) {
      return false
    }
    if (!extra || !Array.isArray(extra.pages) || extra.pages.length === 0) return false
    const bundle = cached.bundle
    bundle.pages = bundle.pages.concat(extra.pages)
    Object.assign(bundle.byId, extra.byId)
    bundle.lazySearchLoaded = true
    cached.index = MenuLib.buildIndex(bundle)
    return true
  }

  // Fold the companion's pages into the live bundle on the first query. The
  // entry's uids stay untouched: pages keep their own id prefix, so no
  // re-normalization (and no second pass over the face rows) is needed.
  function _ensureLazySearch(q) {
    if (String(q ?? "") === "") return false
    const entry = root._lazySearchPaths[root._lastPath]
    if (entry === undefined || entry.companion === "") return false
    const cached = root._bundleCache[root._lastPath]
    if (cached === undefined || !root.bundle || root.bundle !== cached.bundle) return false
    if (!root._mergeLazyCompanion(cached, entry.companion)) return false
    root._builtinIndex = cached.index
    root._rebuildSearchIndex()
    return true
  }

  // Late prewarm: units register their lazy bundle paths on the Registry at
  // boot; once the entrance is over and the loop is idle, build those bundles
  // into the cache and merge their companions. The first query then finds a
  // merged cached container and pays no parse at all.
  function _preloadLazySearches() {
    root._lazyPreloadScheduled = false
    // Building a bundle installs its containers even when the caller restores
    // them afterwards. Doing that under an open picker refits the card mid
    // summon - the cold-boot first-open flicker. Wait for a closed surface;
    // until then an ordinary first query loads the companion on demand.
    if (root.open) return
    const paths = Registry.get("lazySearchBundles", "paths")
    if (!Array.isArray(paths) || paths.length === 0) return
    const priorBundle = root.bundle
    const priorIndex = root._builtinIndex
    const priorFamily = root._settingsFamily
    for (let i = 0; i < paths.length; i++) {
      const path = paths[i]
      if (!root._buildFromFile(path)) continue
      const entry = root._lazySearchPaths[path]
      if (entry === undefined) continue
      root._mergeLazyCompanion(root._bundleCache[path], entry.companion)
    }
    root.bundle = priorBundle
    root._builtinIndex = priorIndex
    root._settingsFamily = priorFamily
    root._rebuildSearchIndex()
    root._lazyPreloaded = true
  }

  // The external pages - the idle timer list, the font rows - belong to the
  // settings family. The surface drops its page table on every container
  // reload and the owners republish after the drop, but a cached reload does
  // not reload the containers: the table then keeps whatever the last reload
  // left in it, and that reload may have been a bundle which does not take
  // these pages. Ask for them again, so the table matches the bundle that
  // is actually active.
  //
  // Index providers are asked on the same terms: their page composition is
  // what registers their search rows, so a reload that dropped the page took
  // the rows with it. Republishing here puts both back before the first
  // query, which the container drop alone never did.
  function _restoreExternalPages() {
    if (!root.externalPagesAllowed()) return
    PageHost.replayPages()
    for (const owner of root._indexProviders) {
      if (owner && typeof owner.republishIndex === "function") owner.republishIndex()
    }
  }

  property string _lastPath: ""
  property string _lastInline: ""
  property var _bundleCache: ({})
  property bool _prewarmed: false
  property bool _lazyPreloaded: false
  property bool _lazyPreloadScheduled: false

  // Icon raster prewarm, fed from the warm bundles in _maybePrewarm. The
  // panel's IconWarmer decodes each (glyph, tone) into Qt's shared pixmap
  // cache ahead of the first summon, so a menu delegate paints its icon in the
  // frame it is created instead of blanking for the async SVG decode. Only the
  // decoded raster is warmed here; the recolor string is Icons' own cache.
  //
  // The warm is deliberately idle and chunked. Queuing every glyph's async
  // decode in one turn puts ~180 jobs on Qt's image thread during boot and the
  // resulting contention can stretch a bar module's own state transition - a
  // glyph painted in the color of an intermediate state instead of the settled
  // one. The boot milestone already holds the warm off that window (the menu
  // cannot be summoned earlier), and the panel's adoption is the live signal
  // that the warmer exists - no delay timer and no turn budget.
  property var _iconWarmRequests: []
  property int _iconWarmIdx: 0
  readonly property int iconWarmBatch: 16
  readonly property bool _iconWarmReady: root._iconWarmRequests.length > 0
    && root._iconWarmIdx < root._iconWarmRequests.length
    && DesktopLayoutState.bootEntrancePlayed
    && !!root.probeSource
    && typeof root.probeSource.prewarmIcons === "function"

  function _collectIconRequests(bundles) {
    const out = []
    const seen = Object.create(null)
    const add = (name, accent) => {
      const n = String(name ?? "")
      if (n === "") return
      const a = String(accent ?? "")
      const key = n + "\u0000" + a
      if (seen[key] === true) return
      seen[key] = true
      out.push({ name: n, colorKey: "foreground_0", accentKey: a })
    }
    // Every shipped glyph at the ordinary row tone. Catalog pages, injected
    // pages and search hits all name a shipped asset, so this baseline covers
    // a cold first open regardless of which bundle won the prewarm race.
    const names = Object.keys(Icons._raw)
    for (let i = 0; i < names.length; i++) add(names[i], "")
    // Two-tone row glyphs the warm bundles actually accent (a bare name above
    // is not the URL such a row requests).
    for (let b = 0; b < bundles.length; b++) {
      const bundle = bundles[b]
      const pages = bundle && Array.isArray(bundle.pages) ? bundle.pages : []
      for (let p = 0; p < pages.length; p++) {
        const items = pages[p] && Array.isArray(pages[p].items) ? pages[p].items : []
        for (let i = 0; i < items.length; i++) {
          const itm = items[i]
          if (itm && itm.icon) add(itm.icon, root.iconAccentFor(itm))
        }
      }
    }
    return out
  }

  function _startIconPrewarm(bundles) {
    root._iconWarmRequests = root._collectIconRequests(bundles)
    root._iconWarmIdx = 0
    root._pumpIconPrewarm()
  }

  function _pumpIconPrewarm() {
    if (!root._iconWarmReady) return
    const panel = root.probeSource
    const end = Math.min(root._iconWarmIdx + root.iconWarmBatch, root._iconWarmRequests.length)
    if (end <= root._iconWarmIdx) return
    panel.prewarmIcons(root._iconWarmRequests.slice(root._iconWarmIdx, end))
    root._iconWarmIdx = end
    if (root._iconWarmIdx < root._iconWarmRequests.length) Qt.callLater(root._pumpIconPrewarm)
  }
  // Defer off the binding edge: the pump mutates requests/probe state that the
  // gate reads, so calling it inline re-enters evaluation as a binding loop.
  on_IconWarmReadyChanged: if (root._iconWarmReady) Qt.callLater(root._pumpIconPrewarm)

  // Boot-time prewarm for the two most-opened bundles (see onCompleted).
  // Builds each container into the repeat-summon cache and runs its guard
  // batch, so the first real keypress cache-hits a settings-complete bundle
  // and reads cached verdicts. The two builds share the single-flight guard
  // runner: the first batch runs for the first bundle, the second call parks
  // `_guardsPending` and re-runs for the second once the first lands - with
  // the merge below both verdict sets survive. Never disturbs a live menu:
  // the readiness gate below waits for the boot milestone, a closed menu and
  // ready settings, and re-fires on those live edges instead of polling.
  readonly property bool _prewarmCanRun: !root._prewarmed
    && DesktopLayoutState.bootEntrancePlayed
    && !root.open
    && Settings.ready === true && HyprlandSettings.ready === true
    && MiscSettings.ready === true
  // Defer off the binding edge: the build mutates store/menu state that the
  // gate reads, so running it inline re-enters evaluation as a binding loop.
  on_PrewarmCanRunChanged: if (root._prewarmCanRun) {
    Qt.callLater(root._maybePrewarm)
    // The lazy companion parse is deferred again to the next idle turn, so it
    // never lands in the same frame as the prewarm's guard batches.
    if (!root._lazyPreloaded && !root._lazyPreloadScheduled) {
      root._lazyPreloadScheduled = true
      Idle.run(root._preloadLazySearches)
    }
  }

  function _maybePrewarm() {
    if (root._prewarmed) return
    // The two bundle builds, their guard batches and the index rebuild are
    // tens of milliseconds on the GUI thread, and the boot entrance is drawing
    // through it - measured as a 100ms frame in the middle of the entrance
    // (see DesktopLayoutState.bootEntrancePlayed). The readiness gate re-fires
    // on the milestone; a summon before it builds the bundle it needs on its
    // own, so nothing waits on this prewarm.
    if (!DesktopLayoutState.bootEntrancePlayed) return
    if (root.open) return
    if (Settings.ready !== true || HyprlandSettings.ready !== true
      || MiscSettings.ready !== true) return
    // A build installs its containers as the active bundle, and the warm set
    // ends on the utilities entry - a menu page, not a settings page. The
    // menu is closed while this runs, so that container is not the surface in
    // hand: external pages (the font rows indexed at boot) are composed only
    // into a settings-family bundle, and the utilities entry refuses them
    // until the menu opens on something else. Restore the containers the warm
    // builds replaced - on a cold boot, no bundle at all - and let the first
    // open install the bundle it actually shows.
    const prevBundle = root.bundle
    const prevIndex = root._builtinIndex
    const prevFamily = root._settingsFamily
    let interrupted = false
    const warmBundles = []
    try {
      if (root._buildFromFile(Paths.settingsCatalogPath + "#main")) {
        warmBundles.push(root.bundle)
        root.evaluateGuards()
      }
      if (root.open) interrupted = true
      else if (root._buildFromFile(Paths.settingsCatalogPath + "#utilities")) {
        warmBundles.push(root.bundle)
        root.evaluateGuards()
      }
    } catch (e) {}
    // Read the accent variants while the warm containers are still installed.
    // The icon pump runs after they are restored and feeds the panel, which
    // persists from late boot and owns the warmer at the menu window's DPR.
    if (!interrupted) root._startIconPrewarm(warmBundles)
    root.bundle = prevBundle
    root._builtinIndex = prevIndex
    root._settingsFamily = prevFamily
    root._rebuildSearchIndex()
    // A summon mid-build leaves the work undone; the readiness gate re-fires
    // when the menu closes and the stores are still ready.
    if (interrupted) return
    root._prewarmed = true
  }

  function openJson(text) {
    if (root.open) {
      root.close()
      return true
    }
    try {
      root.loadText(text)
    } catch (e) {
      return false
    }
    return true
  }

  function loadText(text, extOverride) {
    root._lastPath = ""
    root._lastInline = String(text ?? "")
    root._loadContainers(text, extOverride)
    root._primeRuntime(root.bundle)
    root._claimToken = SurfaceClaim.claim("menu", root.close, root)
    Qt.callLater(root.evaluateGuards)
  }

  // Normalized pages for one store payload, cached by PAYLOAD IDENTITY: a
  // store hands back the same object until its generation changes, so an
  // unchanged store costs one strict comparison per container load instead of
  // a re-normalization of every row. Two entries and two stores - a store's
  // entry is replaced when its generation moves, never accumulated.
  property var _normCache: ({})
  function _mergeStorePages(base, key, payload) {
    if (payload === null || payload === undefined) return base
    let hit = root._normCache[key]
    if (hit === undefined || hit.src !== payload) {
      const list = Array.isArray(payload) ? payload : payload.pages
      let pages = MenuLib.normalizePages(list)
      // A store that owns the synthetic index hands its rows over separately:
      // the index is the FIRST page of the tree, in front of that store's own.
      if (!Array.isArray(payload) && payload.hasIndex === true) {
        pages = [MenuLib.normalizePage({
          id: "settings",
          title: payload.indexTitle,
          items: payload.index
        }, "settings")].concat(pages)
      }
      hit = { src: payload, pages: pages }
      const next = Object.assign({}, root._normCache)
      next[key] = hit
      root._normCache = next
    }
    return MenuLib.mergePages(base, hit.pages)
  }

  // Does any submenu row in `base` point at a page that store owns? The one
  // place the question is asked, for both stores.
  function _linksPage(base, store) {
    for (let p = 0; p < base.pages.length; p++) {
      const items = base.pages[p].items
      for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (!it || it.type !== "submenu") continue
        if (store === "hypr" ? HyprlandSettings.menuHasPage(it.page)
          : Settings.menuHasPage(it.page)) return true
      }
    }
    return false
  }

  // The internal entry used by the existing file/JSON open paths. It still
  // swaps the active view once, through the same install step the gateway
  // uses after it has prepared and validated a candidate.
  function _loadContainers(text, extOverride, entryFrag) {
    root._installContainers(root._assembleContainers(text, extOverride,
      root._lastPath, entryFrag))
  }

  // Pure assembly: read the bundle, merge the owned stores, apply the
  // extension and scope the search index, then RETURN the candidate. Nothing
  // here swaps the active view, retires dynamic pages or clears runtime
  // state, so a gateway can prepare and validate a replacement before it
  // closes the old bundle.
  function _assembleContainers(text, extText, path, entryFrag) {
    const t0 = Date.now()
    // The unified catalog carries menu `menus`: parseBundle reads those,
    // while a generated settings bundle carries `pages`. Either way the
    // dynamic settings/hypr leaves merge below when linked.
    // The unified catalog is already parsed for the settings stores
    // (SettingsCatalog memoizes one read + parse at boot), so the menu does not
    // parse the same ~5k lines again on every rebuild - it builds its
    // containers from the parsed `menus`. Every other bundle, and the catalog
    // before it has been read, still goes through the text path.
    let base = null
    if (root._catalogFile(path)) {
      const catalog = SettingsCatalog.load()
      if (catalog && Array.isArray(catalog.menus)) {
        try {
          base = MenuLib.bundleFromPages(catalog.menus)
        } catch (e) {
          base = null
        }
      }
    }
    if (base === null) base = MenuLib.parseBundle(text)
    let searchBase = base

    const bare = base.pages.length === 1 && base.pages[0].items.length === 0
    const linksSettings = root._catalogFile(path) || bare
      || root._linksPage(base, "settings")
    let settingsFamily = linksSettings

    // One tree, one merge. Each store hands over page descriptors for its own
    // half of the catalog (SettingsLib.buildPages) and _mergeStorePages
    // normalizes that store's pages ONCE per generation, appending them by
    // reference. Before this each half was stringified in its store, parsed
    // back here and re-normalized per merge - and the hypr half was merged
    // twice, once into the displayed bundle and once into the search bundle,
    // which is exactly why the two could not stay one object.
    if (linksSettings) {
      base = root._mergeStorePages(base, "settings", Settings.menuPages())
      if (HyprlandSettings.ready)
        base = root._mergeStorePages(base, "hypr", HyprlandSettings.menuPages())
      MenuLib.orderSettingsIndex(base)
    } else if (HyprlandSettings.ready && root._linksPage(base, "hypr")) {
      // A bundle with its own link to a compositor page still gets those
      // pages; it never gets the settings tree.
      base = root._mergeStorePages(base, "hypr", HyprlandSettings.menuPages())
    }
    searchBase = base

    if (base.byId[base.entry] !== undefined && base.byId[base.entry].items.length === 0) {
      const fb = base.byId["settings"] !== undefined ? "settings"
        : (base.pages.find(p => p.items.length > 0) || {}).id
      if (fb !== undefined && fb !== null && fb !== "") base.entry = fb
    }

    // No sibling registry: the unified catalog already carries every menu
    // page (`menus`), and the dynamic settings/hypr leaves merged above.
    // Unrelated picker bundles opened via openJson stay untouched.

    if (extText === undefined) {
      const extPath = Paths.configHome
      extensionLoader.path = extPath + "/vibranium/user-menu.jsonc"
      extText = extensionLoader.waitForJob() ? extensionLoader.text() : ""
    }
    if (extText !== undefined && extText !== null && extText.trim() !== "") {
      // base and searchBase are one object here (see the merge above), so the
      // extension is applied once instead of twice.
      try {
        base = MenuLib.applyExtension(base, extText)
      } catch (e) {
        Log.warn(root.tag, "user-menu.jsonc ignored: " + e)
      }
      searchBase = base
    }

    // Entry scope for the unified catalog: the file holds every menu, but
    // search and the external-half gate span only the opened entry's tree,
    // the way one-file-per-menu scoped both before. Other bundles keep
    // their file scope.
    const isCatalog = root._catalogFile(path)
    if (isCatalog) {
      let entry = base.entry
      if (typeof entryFrag === "string" && entryFrag !== ""
        && base.byId[entryFrag] !== undefined)
        entry = entryFrag
      else if (base.byId["settings"] !== undefined)
        entry = "settings"
      let extIds = []
      if (typeof extText === "string" && extText.trim() !== "") {
        try {
          const parsedExt = MenuLib.parseBundle(extText)
          for (let i = 0; i < parsedExt.pages.length; i++) extIds.push(parsedExt.pages[i].id)
        } catch (e) {}
      }
      searchBase = MenuLib.scopeBundle(base, entry, extIds)
      let fam = entry === "settings"
        || Settings.menuHasPage(entry) || HyprlandSettings.menuHasPage(entry)
      if (!fam) {
        const epg = base.byId[entry]
        if (epg !== undefined && epg !== null && Array.isArray(epg.items)) {
          for (let i = 0; i < epg.items.length && !fam; i++) {
            const it = epg.items[i]
            if (it && it.type === "submenu" && typeof it.page === "string" && it.page !== ""
              && (it.page === "settings"
                || Settings.menuHasPage(it.page) || HyprlandSettings.menuHasPage(it.page)))
              fam = true
          }
        }
      }
      settingsFamily = fam
    }

    root._markSensitive(base, text)
    return {
      bundle: base,
      index: MenuLib.buildIndex(searchBase),
      settingsFamily: settingsFamily === true,
      entry: base.entry,
      byId: base.byId
    }
  }

  // `sensitive` is an authoring flag on a bundle row. The normalized payload
  // deliberately keeps a fixed key set, so carry the flag across as a private
  // marker on the row the gateway can read without widening the public shape.
  function _markSensitive(base, text) {
    let raw
    try { raw = JSON.parse(MenuLib.stripJsonc(String(text ?? ""))) } catch (e) { return }
    if (!raw || !Array.isArray(raw.pages) || !base || !base.byId) return
    const mark = function (items, rawItems) {
      if (!Array.isArray(items) || !Array.isArray(rawItems)) return
      for (let i = 0; i < items.length && i < rawItems.length; i++) {
        const src = rawItems[i]
        if (src && src.sensitive === true) items[i]._sensitive = true
        if (src && Array.isArray(src.children))
          mark(items[i] && items[i].children, src.children)
      }
    }
    for (let p = 0; p < raw.pages.length; p++) {
      const src = raw.pages[p]
      if (!src || typeof src.id !== "string") continue
      const page = base.byId[src.id]
      if (page) mark(page.items, src.items)
    }
  }

  // The only writer of the active containers. Dropped external pages are
  // replayed by their owners afterwards; nothing here chooses a new entry
  // frame or claims a surface.
  function _installContainers(candidate) {
    // The scope is recorded from the assemble decision; it is not computed a
    // second way at install time.
    const linksSettings = candidate.settingsFamily === true
    root.bundle = candidate.bundle
    root._builtinIndex = candidate.index
    root._settingsFamily = linksSettings
    const droppedPages = Object.assign({}, root._dynamicPages, root._optionPages)
    root._dynamicPages = {}
    root._optionPages = {}
    root._dynamicApis = {}
    root._dropPageIndexRegistrations(droppedPages)
    root._rebuildSearchIndex()
    // Live owners republish their pages after a reload - but only into a
    // settings-family bundle. Replaying them into a standalone picker
    // bundle would re-inject foreign pages (and their index rows) into a
    // menu that must span only its own rows.
    if (root.externalPagesAllowed()) {
      for (const owner of root._indexProviders) {
        if (owner && typeof owner.republishIndex === "function") owner.republishIndex()
      }
    }
    PageHost.reportDropped()
  }

  function _retireRefs() {
    root._refPages = ({})
    root._refsByValue = ({})
    root._landingIntent = null
  }

  function _advanceOpenGeneration() {
    root.openGeneration++
    root._retireRefs()
  }

  function _primeRuntime(bundle) {
    root._advanceOpenGeneration()
    root.bundle = bundle
    root.resetSearch()
    root.pendingSel = -1
    root.viewState = {}
    root._optionPages = {}
    root._restorePending = {}
    root.beginRestore(bundle.entry)
    root._states = {}
    root.stack = [{ id: bundle.entry, sel: 0, y: 0 }]
    root._buildCondIndex()
    root.recomputeDeadLinks()
  }

  // Whether settings-family external pages (idle timers, font rows) may
  // join the current bundle. Standalone picker bundles opened via openJson
  // (themes, theme removal) are single-purpose: injected settings pages
  // would both render foreign rows and answer global search there. No
  // bundle yet (boot, menu never opened) allows, preserving first indexing.
  function externalPagesAllowed() {
    if (root.bundle === null || root.bundle === undefined) return true
    return root._settingsFamily === true
  }

  // The index a query scans: the bundle's own entries plus every live owner's,
  // with a republished page shadowing the bundle's copy of it. The merge is
  // MenuIndex.sectionRows' (shadowing, ordering and the empty cases).
  function _rebuildSearchIndex() {
    root.searchIndex = MenuIndex.sectionRows(root._builtinIndex,
      root._indexRegistrations, root._settingsFamily)
    // `results` is a derivation of the index and the query. Re-run the writer
    // on the index edge; _applyingQuery stops a scan that itself registers a
    // page from re-entering before it has finished.
    if (root.query !== "" && !root._applyingQuery) root._applyQuery(root.query)
  }

  // Global search publishes every keystroke.
  //
  // A keystroke is a whole pipeline: scan the index, rank the hits, reinstall
  // the panel's row projection (up to the 200-row cap), remeasure the card and
  // resize the window. That pipeline used to be paced behind a trailing
  // coalescing window (a Ui.fastMs timer) on a large index to keep the churn
  // down - but the window is longer than the gap between two typed keys, so
  // every key after the first of a burst sat unpublished for up to 120ms: the
  // bar echoed the text while the results trailed it. The scan is cheap: a
  // cold full scan of a 3,000-entry index measures 0.8-1.7 ms, and a key that
  // grows the query (the usual case between two keystrokes) narrows the
  // previous hit set at ~0.005 ms. The install is keyed and incremental, and a
  // stale row set is the thing the user actually sees - so the query is
  // applied on every keystroke instead.
  //
  // An empty query needs no special case here: _applyQuery publishes it and
  // drops the ranked window, which is what clearing the bar means.
  function setQuery(q) {
    root._landingIntent = null
    // Retire deferred index-provider callbacks from the previous query. A
    // scan completing against an erased query re-applies the old text,
    // re-enters search and drops the restored page's reveal claim, leaving
    // its expanded dropdown with no region or background.
    root._pendingQueryGen++
    root._retireSearchRefs()
    root._ipcProviderPending = false
    // A lazy merge rebuilds the index here; the new query is applied below,
    // so an intermediate re-scan of the outgoing query would only churn.
    root._applyingQuery = true
    root._ensureLazySearch(q)
    if (root.frame && root.hasDynamicPage(root.frame.id)) {
      const pg = root.pageById(root.frame.id)
      if (!pg || pg.searchGlobal !== true) {
        root._applyingQuery = false
        if (!root.scopedActive) root.beginScoped()
        root.setScopedQuery(q)
        return
      }
    }
    root._applyingQuery = false
    root._applyQuery(String(q ?? ""))
  }

  // Publish one query: the applied text, its ranked window, and any provider
  // that wants the scan deferred until its rows exist.
  function _applyQuery(q) {
    if (root._applyingQuery) return
    root._applyingQuery = true
    Menu.trace("menu.query", {
      q: q, gen: root._pendingQueryGen, frame: root.frame ? root.frame.id : ""
    })
    root.query = q
    root.results = q !== "" ? MenuLib.search(root.searchIndex, q) : []
    const provider = root._indexProviderFor(q)
    if (provider && typeof provider.ensureScanned === "function") {
      const took = provider.ensureScanned()
      if (took && typeof provider.whenScanned === "function") {
        const gen = ++root._pendingQueryGen
        const held = String(q || "")
        root._ipcProviderPending = true
        provider.whenScanned(() => {
          if (gen !== root._pendingQueryGen) return
          const live = String(root.query || "")
          if (live !== "" && live !== held) root.setQuery(live)
          else root.setQuery(held)
          root._ipcProviderPending = false
        })
      }
    }
    root._applyingQuery = false
  }

  function _indexProviderFor(q) {
    const needle = String(q || "").trim()
    if (needle === "") return null
    for (const owner of root._indexProviders) {
      if (!owner) continue
      if (owner.indexReady && owner.indexReady()) continue
      if (typeof owner.claimsQuery === "function" && owner.claimsQuery(needle)) return owner
    }
    return null
  }

  function clearQuery() {
    if (root.query === "") return
    root.resetSearch()
  }

  // Every store variable a row's `showIf` names, collected once. The walk is
  // MenuIndex.conditionVars' (deduplication and the absent-array cases).
  function _buildCondIndex() {
    root._condVars = MenuIndex.conditionVars(root.bundle)
  }

  // --- supplemental state ---
  // Alias the open flag under the name views bind to (MenuView.visible,
  // PanelFocus serviceVisible). Same value, stable name.
  readonly property bool visible: root.open

  // Unified right-hand value column for bar alignment (see MenuPanel).
  // When a page shows >=2 range/progress rows, all value boxes share this
  // width so little bars form a perfect column. 0 = per-item sizing.
  property int unifiedBarValueW: 0

  // Blow-by-blow latch for per-row slot closes, uid -> true. Armed at the
  // collapse choke point (setExpanded/setInfo with value !== true, where
  // no DropdownSlot is in scope) and cleared by the row itself when its
  // slot motion reaches zero (see MenuPanel's onSlotMotionMsChanged).
  // Reconciled against the model on every install (pruneSlotCloses), so a
  // latch never outlives its row.
  property var _slotCloses: ({})

  // True while any row's slot is still easing shut. Derived from the row
  // latches instead of a wall-clock guess: the verdict ends when the slot
  // itself reports still, so it cannot clear before a slow slot lands or
  // outlive a fast one that has already settled. A reopen drops its row's
  // latch at the same choke point, releasing the verdict in that turn.
  readonly property bool slotClosing: Object.values(_slotCloses).some(v => v)

  // Staged-flow cursor per row uid: {index, values}. Flow rows (an item
  // with a `flow` stage array, see MenuLib.isFlow) render one stage at a
  // time; the cursor and the accumulated stage values live here, outside
  // the bundle, so navigation never mutates page data.
  property var _flow: ({})

  // Bumped only when a store change may have flipped a showIf verdict; the
  // panel re-filters rows on this instead of every rev.
  property int condRev: 0
  property var _condVars: ({})

  // The active menu panel. Published by MenuView; production consumers use
  // this handle. `probeSource` stays as the debug/introspection alias.
  property var panel: null
  property var probeSource: null

  // Frame trace for live diagnosis, armed over IPC. Every call site is a
  // no-op until a verb turns this on, so a normal session emits nothing.
  property bool traceEnabled: false
  function trace(tag, fields) {
    if (!root.traceEnabled) return
    console.log("NTRACE " + tag + " " + JSON.stringify(fields))
  }

  // One store write, three stores. `deep` names the stores whose option can
  // gate a row's `requires:` expression, so only they re-resolve dead links;
  // the misc store's options are values without conditions behind them.
  function _optionsChanged(key, value, deep) {
    Menu.syncBound(key, value)
    Menu.refreshSectionCounts()
    if (deep === true) Menu.recomputeDeadLinks()
  }

  Connections {
    target: Settings
    function onOptionChanged(key, value) { Menu._optionsChanged(key, value, true) }
    function onReadyChanged() { Menu._maybePrewarm() }
  }
  Connections {
    target: HyprlandSettings
    function onOptionChanged(key, value) { Menu._optionsChanged(key, value, true) }
    function onReadyChanged() { Menu._maybePrewarm() }
  }
  Connections {
    target: MiscSettings
    function onOptionChanged(key, value) { Menu._optionsChanged(key, value, false) }
    function onReadyChanged() { Menu._maybePrewarm() }
  }

  // Re-derive the "N items" sub line of every counted section row on the
  // settings root. Counting runs over the BUILT page: every declared row is
  // listed, and gated rows stay on it while muted, so the number describes
  // the page's shape and does not move as conditions flip.
  // In-place mutation + rev bump: the mirror holds these same objects,
  // so patched strings reach delegates without any model rebuild.
  function refreshSectionCounts() {
    const rootPage = root.bundle ? root.bundle.byId.settings : null
    if (!rootPage || !root.bundle) return
    let changed = false
    for (let i = 0; i < rootPage.items.length; i++) {
      const it = rootPage.items[i]
      if (it.type !== "submenu" || !it.page || it.sub === undefined) continue
      const page = root.bundle.byId[it.page]
      if (!page) continue
      let n = 0
      let hasItems = false
      for (let j = 0; j < page.items.length; j++) {
        const cand = page.items[j]
        if (!cand || cand.type === "separator") continue
        if (!Menu.isListed(cand)) continue
        n++
        if (cand.var === undefined) hasItems = true
      }
      const noun = hasItems ? "item" : "option"
      const label = n === 1 ? "1 " + noun : n + " " + noun + "s"
      if (it.sub !== label) {
        it.sub = label
        changed = true
      }
    }
    if (changed) root.rev++
  }

  // --- icon resolution ---
  // Menu glyphs come from the shell's own assets/icons set exclusively,
  // recolored to the live palette (see common/theme/Icons). Unknown names
  // resolve to nothing - never the XDG theme, so a missing asset shows
  // as a gap instead of an unthemed icon. Desktop-entry/app icons use
  // resolveAppIcon, which keeps the platform lookup as fallback.

  function resolveAppIcon(name) {
    if (!name) return ""
    // The one place the two-step lookup lives (shipped asset, then the
    // platform theme, with path passthrough and memoization) - see
    // common/theme/AppIcons.
    const hit = AppIcons.url(name)
    if (hit !== "") return hit
    return String(Quickshell.iconPath(name))
  }

  // Search state resets together everywhere: navigation, close, reload.
  function resetSearch() {
    root._pendingQueryGen++
    root._retireSearchRefs()
    root.clearScoped()
    root.query = ""
    root.results = []
  }

  // --- provider surfaces ---
  // Providers overlay per-row semantics onto bundle-declared rows by id:
  // view (sub/display/checked), confirm flow, and actions. The row model
  // stays owned by the bundle; the provider owns the behavior. Surfaces
  // may register before the menu singleton exists, so late booters poll
  // briefly via Registry.get("menu", "registerProvider"). Units on the
  // new hub register through ProviderHost instead; _providerFor reads
  // both, local first.
  property var _providers: ({})

  function registerProvider(id, surface) {
    if (typeof id !== "string" || id === "" || !surface) return
    root._providers = Object.assign({}, root._providers, { [id]: surface })
  }

  function unregisterProvider(id) {
    if (root._providers[id] === undefined) return
    const next = Object.assign({}, root._providers)
    delete next[id]
    root._providers = next
  }

  function _providerFor(id) {
    if (id && root._providers[id]) return root._providers[id]
    if (typeof ProviderHost !== "undefined" && ProviderHost
      && typeof ProviderHost.providerFor === "function") {
      try {
        const p = ProviderHost.providerFor(id)
        if (p) return p
      } catch (e) {}
    }
    // One page-level resolver can serve hundreds of rows without claiming a
    // provider id for each one. ProviderHost copies its frozen table on every
    // claim, which made a store change cost seconds on the UI thread.
    const api = root.frame ? root._dynamicApis[root.frame.id] : null
    if (api && typeof api.provider === "function") {
      try {
        const p = api.provider(id)
        if (p) return p
      } catch (e) {}
    }
    return null
  }

  // Hook context handed to provider calls: lets a surface read menu state
  // (expanded confirm rows) and trigger conditional-reveal refreshes
  // without importing the menu framework.
  //
  // ONE object for the session. The context is stateless - it names the
  // singleton, never the row the hook was dispatched for - and the panel
  // resolves it per row on every install (projectRows asks subFor and
  // widestDisplayFor) plus once per visible delegate. Building a fresh object
  // with two closures per call was pure allocation churn on the search
  // keystroke path, where a projection is resolved again for every result.
  property var _hookCtxShared: ({
    isExpanded: (it) => root.isExpanded(it),
    bumpCondRev: () => root.bumpCondRev()
  })

  function _hookCtx(item) {
    return root._hookCtxShared
  }

  // --- generic item helpers (provider-backed, Entry/MenuPanel delegate
  // here). Keeps row view (Entry) free of service imports and id branches;
  // per-service knowledge lives in the owning provider. JSON may also
  // provide a `confirm` object directly; provider confirms take precedence.

  // A group child marked `type: "provider"` is a placeholder for a live row
  // set owned by a surface (the font list). Resolve its `fontRows` hook and
  // normalize the rows exactly like any other group children, so a font
  // installed mid-session appears in the dropdown without a menu reload.
  function providerFontRows(marker) {
    const p = root._providerFor(marker && marker.id)
    const rows = MenuLib.hookValue(p, "fontRows", marker, root._hookCtxShared, null)
    if (!Array.isArray(rows) || rows.length === 0) return []
    return MenuLib.normalizeChildren(rows, marker.id, marker.id + "#font")
  }

  function subFor(item) {
    if (!item) return ""
    // The value contract is MenuLib's (hookValue): a nullish or empty answer is
    // a decline and the bundle's own copy stands.
    const p = root._providerFor(item.id)
    const hooked = MenuLib.hookValue(p, "sub", item, root._hookCtx(item), "")
    if (hooked !== "") return String(hooked)
    // A search hit is a copy: the child it names can carry no sub of its own
    // while the live page row the hit points at does. Read the live copy here
    // rather than in the delegate alone - the model's height estimate and the
    // row's own text must ask one question, or the card is sized for one line
    // and the delegate draws two. The rev read re-evaluates on an in-place
    // count refresh without any model churn.
    root.rev
    const pg = typeof item.pageId === "string" && typeof item.row === "number"
      ? root.pageById(item.pageId) : null
    const live = pg && Array.isArray(pg.items) ? pg.items[item.row] : null
    if (live && live.sub !== undefined && live.sub !== null)
      return String(live.sub)
    return String(item.sub ?? "")
  }

  function displayFor(item) {
    if (!item) return null
    const p = root._providerFor(item.id)
    return MenuLib.hookValue(p, "display", item, root._hookCtx(item), null)
  }

  function widestDisplayFor(item) {
    if (!item) return null
    const p = root._providerFor(item.id)
    return MenuLib.hookValue(p, "widestDisplay", item, root._hookCtx(item), null)
  }

  // Both layout facts for one row in ONE provider resolution. The install
  // (MenuPanel.projectRows) asks for the sub line and the widest value of
  // every installed row, and resolving subFor/widestDisplayFor separately
  // looked the same provider up twice per row and crossed the QML boundary
  // twice. The value contracts are still MenuLib's (hookValue) - only the
  // lookup is shared, and a row with no provider pays one miss and no call.
  function rowFactsFor(item) {
    if (!item) return { sub: "", widest: "" }
    const p = root._providerFor(item.id)
    // The sub is the delegate's own resolution, not a second one: a search
    // hit whose visible sub comes from its live page row has the same second
    // line in the estimate as in the rendered delegate.
    const sub = root.subFor(item)
    const wide = MenuLib.hookValue(p, "widestDisplay", item, root._hookCtxShared, null)
    return {
      sub: sub,
      widest: wide === null || wide === undefined ? "" : String(wide)
    }
  }

  function isToggleOn(item) {
    if (!item || item.type !== "toggle") return false
    // Strict boolean is MenuLib's rule (hookBool): a truthy stand-in a surface
    // returned by mistake has not answered, so the bundle's own truth stands.
    const p = root._providerFor(item.id)
    const hooked = MenuLib.hookBool(p, "checked", item, root._hookCtx(item), null)
    if (hooked !== null) return hooked
    if (typeof item.checked === "string" && item.checked !== "") return root.isChecked(item)
    // Use stateOf so var-bound toggles initialise from Settings and track rev
    const s = root.stateOf(item)
    return s.checked === true
  }

  function isValueActive(item) {
    if (!item) return false
    const p = root._providerFor(item.id)
    const hooked = MenuLib.hookBool(p, "valueActive", item, root._hookCtx(item), null)
    return hooked !== null ? hooked : false
  }

  function isNumberActive(item) {
    if (!item) return false
    const p = root._providerFor(item.id)
    const hooked = MenuLib.hookBool(p, "numberActive", item, root._hookCtx(item), null)
    return hooked !== null ? hooked : false
  }

  // Palette key a provider wants its row glyph accented with (caffeine's
  // red slash while active). "" keeps the row monochrome.
  function iconAccentFor(item) {
    if (!item) return ""
    const p = root._providerFor(item.id)
    if (p && typeof p.iconAccent === "function") {
      const r = p.iconAccent(item, root._hookCtx(item))
      if (typeof r === "string" && r !== "") return r
    }
    return ""
  }

  function confirmFor(item) {
    if (!item) return null
    const p = root._providerFor(item.id)
    let provided = null
    if (p && typeof p.confirm === "function") provided = p.confirm(item, root._hookCtx(item))
    // A surface's descriptor wins, including a falsy one - that is how a
    // surface arms NOTHING for a row the bundle would otherwise arm. Only null
    // and undefined fall through, and the bundle side must be an object.
    return MenuLib.resolveConfirm(item, provided)
  }

  function handleConfirm(item) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.runConfirm === "function") {
      if (p.runConfirm(item, root._hookCtx(item)) === true) return true
    }
    if (item.confirm && typeof item.confirm === "object" && typeof item.confirm.command === "string" && item.confirm.command !== "") {
      root.runCommand(item.confirm.command, "")
      return true
    }
    return false
  }

  function handleNumberChange(item, value) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.runNumber === "function") {
      if (p.runNumber(item, value, root._hookCtx(item)) === true) return true
    }
    return false
  }

  function handleToggle(item, state) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.runToggle === "function") {
      if (p.runToggle(item, state, root._hookCtx(item)) === true) return true
    }
    return false
  }

  // A service-owned staged flow submits its accumulated stage values
  // through the owning provider (runFlow); providers without one decline
  // and the row falls back to its inline commit path.
  function handleFlow(item, vals) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.runFlow === "function") {
      if (p.runFlow(item, vals, root._hookCtx(item)) === true) return true
    }
    return false
  }

  // --- staged-flow cursor ---
  // One cursor per flow row uid: the stage index under render plus the
  // accumulated stage values keyed by stage index. Null/uidless rows read
  // the resting cursor and ignore writes. Every mutation bumps rev - flow
  // bindings key on it exactly like the state bindings do.

  function _flowState(item) {
    const uid = item ? item.uid : ""
    if (!uid) return MenuState.blankFlow()
    let st = root._flow[uid]
    if (st === undefined) {
      st = MenuState.blankFlow()
      root._flow[uid] = st
    }
    // Older records from a live shell replace only the missing fields; the
    // visited chain and the draft presence bit must exist for every flow.
    if (!Array.isArray(st.visited)) st.visited = [Number(st.index) || 0]
    if (!st.draft || typeof st.draft !== "object") st.draft = { set: false, value: null }
    if (st.ready === undefined) st.ready = false
    return st
  }

  function flowIndexOf(item) {
    const st = root._flowState(item)
    return Number(st.index) || 0
  }

  function flowValuesOf(item) {
    const st = root._flowState(item)
    return st.values || {}
  }

  function setFlowValue(item, index, value) {
    const uid = item ? item.uid : ""
    if (!uid) return
    const st = root._flowState(item)
    st.values[String(Number(index) || 0)] = value
    root.rev++
  }

  function setFlowIndex(item, index) {
    const uid = item ? item.uid : ""
    if (!uid) return
    root._flowState(item).index = Number(index) || 0
    root.rev++
  }

  function resetFlow(item) {
    const uid = item ? item.uid : ""
    if (!uid) return
    if (root._flow[uid] !== undefined) {
      delete root._flow[uid]
      root.rev++
    }
  }

  // Registry API entry for history-driven reveals: bumps the
  // conditional-reveal generation so MenuPanel animates the row
  // in/out without rebuilding the whole model.
  function bumpCondRev() {
    root.condRev++
    root.refreshSectionCounts()
  }

  // Collapse the clear-history confirmation if it is open. Used
  // when history becomes empty while the row is expanded - the hide
  // must be deferred until the dropdown finishes closing, otherwise
  // the card keeps the expanded height as empty space.
  function collapseClearHistory() {
    if (!root.bundle) return
    for (let p = 0; p < root.bundle.pages.length; p++) {
      const page = root.bundle.pages[p]
      for (let i = 0; i < page.items.length; i++) {
        const it = page.items[i]
        if (it && it.id === "clearUsageHistory" && root.isExpanded(it)) {
          root.setExpanded(it, false)
        }
      }
    }
  }

  // The store that owns a showIf key: hypr.* lives in HyprlandSettings,
  // misc.* in MiscSettings, everything else in Settings. A mixed list such as
  // the wallpaper transition (shell.wallpaper.enabled AND
  // hypr.animations.enabled) has legs in two stores, so routing the whole
  // list to one store would hide the row unconditionally - the foreign leg
  // never matches there.
  function _condStore(key) {
    const s = String(key || "")
    if (s.indexOf("hypr.") === 0) return HyprlandSettings
    if (s.indexOf("misc.") === 0) return MiscSettings
    return Settings
  }

  // Store-driven condition verdict over a showIf list, ANDed with transitive
  // hidden-dependency suppression. The rule itself is SettingsLib's: the menu
  // and the settings pages ask the same question, and a second copy here is a
  // copy that drifts. The two resolvers are what differ, so they are what this
  // passes - each key is routed to the store that owns it.
  function conditionsMet(showIf) {
    if (showIf === undefined || showIf === null) return true
    return SettingsLib.conditionsMet(
      (key) => root._condStore(key).byKey(String(key || "")),
      (key) => root._condStore(key).value(String(key || "")),
      showIf)
  }

  // Reverse sync: the store changed behind our back (IPC, another surface,
  // external edit picked up by the watcher). Re-materialize bound rows and
  // re-filter pages when the change touches a visibility condition.
  function syncBound(key, value) {
    if (!root.bundle) return
    let touched = false
    const pages = root.bundle.pages
    for (let p = 0; p < pages.length; p++) {
      const items = pages[p].items
      for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (it.var !== key) continue
        const st = root._states[it.uid]
        if (st === undefined) continue
        if (it.type === "toggle") st.checked = value === true
        else st.value = value
        touched = true
      }
    }
    if (touched) root.rev++
    // Re-filter only when the changed var participates in some condition.
    if (root._condVars[key]) root.condRev++
  }

  function isChecked(item) {
    if (!item) return false
    return root.guardChecked[item.uid] === true
  }

  // Guard verdicts are read for group children as well as page rows. Uid
  // walks have to reach them too, or a child verdict is parsed and then
  // dropped by the merge because no top-level row claims that uid.
  function _forEachRowUid(items, fn) {
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (!it || typeof it !== "object" || Array.isArray(it)) continue
      if (it.uid) fn(it.uid)
      if (Array.isArray(it.children)) root._forEachRowUid(it.children, fn)
    }
  }

  // Bash verdicts and store conditions are independent gates on the same
  // outcome: either one disables the row. The store leg resolves through
  // conditionsMet against the store that owns the key, so a setting flip
  // re-answers the binding without waiting for a guard batch.
  function isDisabled(item) {
    if (!item) return false
    if (root.guardDisabled[item.uid] === true) return true
    return item.disabledIf !== undefined && item.disabledIf !== null
      && !root.conditionsMet(item.disabledIf)
  }

  property var _guardProc: null
  property bool _guardsPending: false
  property string _guardCollected: ""

  function evaluateGuards() {
    // Single flight: Exec.shell process ignores a new command while the
    // previous one is still running, so a second call stands by and
    // reruns once the current batch lands. Same 400 ms debounce via
    // guardRefreshTimer and same single-flight semantics as before.
    if (root._guardProc && root._guardProc.running) {
      root._guardsPending = true
      return
    }
    root._guardsPending = false

    const script = root.bundle ? MenuLib.buildGuardScript(root.bundle.pages) : ""
    if (script === "") {
      // A guard-less bundle (theme pickers) carries no verdicts of its own,
      // so there is nothing to write - but also nothing to wipe. Clearing
      // the whole maps here dropped every other bundle's answers, and the
      // trip back (picker > Utilities) re-opened on pending verdicts.
      // Retire only this bundle's uids (unguarded rows read as visible);
      // foreign verdicts survive.
      if (root.bundle) {
        const keepWhen = Object.assign({}, root.guardWhen)
        const keepChecked = Object.assign({}, root.guardChecked)
        const keepDisabled = Object.assign({}, root.guardDisabled)
        for (let p = 0; p < root.bundle.pages.length; p++) {
          root._forEachRowUid(root.bundle.pages[p].items, function(uid) {
            if (keepWhen[uid] !== undefined) delete keepWhen[uid]
            if (keepChecked[uid] !== undefined) delete keepChecked[uid]
            if (keepDisabled[uid] !== undefined) delete keepDisabled[uid]
          })
        }
        root.guardWhen = keepWhen
        root.guardChecked = keepChecked
        root.guardDisabled = keepDisabled
      }
      root.rev++
      return
    }
    if (root._guardProc) {
      try { root._guardProc.destroy() } catch (e) {}
      root._guardProc = null
    }
    root._guardCollected = ""
    const proc = Exec.shell(script)
    if (!proc) {
      Log.warn(root.tag, "guard exec failed")
      return
    }
    root._guardProc = proc
    proc.exited.connect(function(exitCode, exitStatus) {
      let out = ""
      try {
        out = proc.stdout ? proc.stdout.text : ""
      } catch (e) {}
      if (out === "" && root._guardCollected !== "") out = root._guardCollected
      const ok = (exitCode === 0 && exitStatus === 0)
      const nextWhen = ({})
      const nextChecked = ({})
      const nextDisabled = ({})
      if (ok) {
        const lines = String(out).split("\n")
        for (let i = 0; i < lines.length; i++) {
          const line = String(lines[i]).trim()
          if (line === "") continue
          const valueAt = line.lastIndexOf(":")
          if (valueAt < 0) continue
          const tagAt = line.lastIndexOf(":", valueAt - 1)
          if (tagAt < 0) continue
          const uid = line.substring(0, tagAt)
          const tag = line.substring(tagAt + 1, valueAt)
          const value = line.substring(valueAt + 1) === "1"
          if (tag === "w") nextWhen[uid] = value
          else if (tag === "c") nextChecked[uid] = value
          else if (tag === "d") nextDisabled[uid] = value
        }
      }
      // Merge, don't replace: the batch only covers the CURRENT bundle, but
      // the verdict maps are global. Replacing dropped every other bundle's
      // answers, so a cross-page jump re-opened Utilities with
      // no verdict for "Copy current track", which then flashed. Uids in
      // this bundle are overwritten (or cleared when the row carries no
      // guard, which reads as visible); uids from other bundles are
      // preserved. A failed batch keeps the previous answers entirely -
      // the menu opens on those for exactly as long as the failure lasts.
      if (ok) {
        const mergedWhen = Object.assign({}, root.guardWhen)
        const mergedChecked = Object.assign({}, root.guardChecked)
        const mergedDisabled = Object.assign({}, root.guardDisabled)
        if (root.bundle) {
          for (let p = 0; p < root.bundle.pages.length; p++) {
            const items = root.bundle.pages[p].items
            root._forEachRowUid(items, function(uid) {
              if (nextWhen[uid] !== undefined) mergedWhen[uid] = nextWhen[uid]
              else delete mergedWhen[uid]
              if (nextChecked[uid] !== undefined) mergedChecked[uid] = nextChecked[uid]
              else delete mergedChecked[uid]
              if (nextDisabled[uid] !== undefined) mergedDisabled[uid] = nextDisabled[uid]
              else delete mergedDisabled[uid]
            })
          }
          // Dynamic/option pages share the maps but not the bundle walk above;
          // their verdicts arrive in the same batch and must land too.
          for (const uid in nextWhen) {
            if (mergedWhen[uid] === undefined) mergedWhen[uid] = nextWhen[uid]
          }
          for (const uid in nextChecked) {
            if (mergedChecked[uid] === undefined) mergedChecked[uid] = nextChecked[uid]
          }
          for (const uid in nextDisabled) {
            if (mergedDisabled[uid] === undefined) mergedDisabled[uid] = nextDisabled[uid]
          }
        } else {
          for (const uid in nextWhen) mergedWhen[uid] = nextWhen[uid]
          for (const uid in nextChecked) mergedChecked[uid] = nextChecked[uid]
          for (const uid in nextDisabled) mergedDisabled[uid] = nextDisabled[uid]
        }
        root.guardWhen = mergedWhen
        root.guardChecked = mergedChecked
        root.guardDisabled = mergedDisabled
      }
      root.rev++
      root.refreshSectionCounts()
      root.recomputeDeadLinks()
      if (root._guardsPending) Qt.callLater(root.evaluateGuards)
      root._guardCollected = ""
    })
  }

  // Re-run guard expressions after a guarded toggle's action fires. The
  // async command gets a short beat to take effect before the pill's
  // checked mirror re-reads reality - convention, not a guarantee (systemd
  // lazy-starts, so the very first flip can lag a beat or two).
  property Qml.Timer guardRefreshTimer: Qml.Timer {
    // Long enough for async actions (systemd lazy-start, hyprctl reload)
    // to land before the mirror re-reads reality. Reading-mode's file
    // write is synchronous, so the extra margin costs it nothing.
    interval: 400

    onTriggered: root.evaluateGuards()
  }

  // Trailing-edge debounce for scoped keystrokes on giant pages: recomputing
  // and reinstalling on every keystroke churns delegates and restarts row
  // fades faster than they complete, so fast typing reads as translucent
  // rows. Small scopes bypass it (see setScopedQuery) and stay instant.
  // The field still echoes instantly; only the model lags by one fast
  // beat. Enter flushes a pending query (see panel.activateCurrent) so
  // activation never reads a set the field has already left behind.
  readonly property int scopedDebounceMs: Ui.fastMs
  property string _scopedPending: ""
  property Qml.Timer scopedTimer: Qml.Timer {
    interval: root.scopedDebounceMs

    onTriggered: root._applyScopedQuery(root._scopedPending)
  }

  function refreshGuards() {
    if (root.bundle === null) return
    guardRefreshTimer.restart()
    root.recomputeDeadLinks()
  }

  function recomputeDeadLinks() {
    if (!root.bundle) return
    // A missing target while the settings stores are still landing is not a
    // dead link - it is a page that has not arrived. Marking it dead muted
    // the "Settings" entry on a cold-boot Main summon. Treat it as usable
    // until the stores are ready; the bundle rebuild on the next open
    // (cache keys on sval/hrev/mrev) supplies the real page.
    const storesReady = Settings.ready === true
      && HyprlandSettings.ready === true && MiscSettings.ready === true
    const dead = {}
    for (let p = 0; p < root.bundle.pages.length; p++) {
      const pg = root.bundle.pages[p]
      for (let i = 0; i < pg.items.length; i++) {
        const it = pg.items[i]
        if (!it || it.type !== "submenu") continue
        const tpg = typeof it.page === "string" && it.page !== ""
          ? root.bundle.byId[it.page] : null
        if (!tpg) {
          if (storesReady) dead[it.uid] = true
          continue
        }
        // A page whose every selectable row is blocked has nothing to offer
        // either, so its link mutes. The test is one level deep on purpose:
        // asking a nested submenu about its own target would recurse through
        // pages that can point back at each other.
        let usable = false
        for (let j = 0; j < tpg.items.length; j++) {
          const tIt = tpg.items[j]
          if (!tIt || !tIt.selectable) continue
          if (root._rowBlocked(tIt)) continue
          usable = true
          break
        }
        if (!usable) dead[it.uid] = true
      }
    }
    const prev = root._deadLinks
    const keys = Object.keys(dead)
    let same = Object.keys(prev).length === keys.length
    for (let k = 0; same && k < keys.length; k++) {
      if (prev[keys[k]] !== true) same = false
    }
    if (same) return
    root._deadLinks = dead
    // The mute is a row binding, so the dead set is an availability input.
    root.rev++
  }

  // Every row a page declares stays in its row set. A failing condition mutes
  // the row (see isUnavailable) instead of removing it, so browsing a menu
  // never changes its shape and the cursor's neighbors stay where they were.
  function isListed(item) {
    return item !== undefined && item !== null
  }

  // A row the user may act on right now. Search, the search index and every
  // path that offers a row to act on read this; the page view lists every row
  // and mutes whatever is unavailable.
  function isVisible(item) {
    return !!item && !root.isUnavailable(item)
  }

  // A listed row that cannot be used right now: a store-gated (showIf)
  // condition fails, a bash when/requires guard is false or still pending, a
  // provider vetoes it, or it opens a page with nothing usable on it. It
  // renders under a card-toned box that mutes it, the cursor steps over it,
  // and nothing activates it.
  function isUnavailable(item) {
    if (!item) return false
    if (root._rowBlocked(item)) return true
    return item.type === "submenu" && root._deadLinks[item.uid] === true
  }

  // Whether a row's own conditions block it, independent of the page a
  // submenu opens. Split out because the dead-link pass asks the same
  // question about a target page's rows without recursing into its submenus.
  function _rowBlocked(item) {
    if (!item) return false
    if (item.showIf !== undefined && item.showIf !== null
      && !root.conditionsMet(item.showIf)) return true
    // when/requires share one `w` verdict (MenuGuard). A gated row is muted
    // until that verdict arrives, so a guard batch can only turn it active -
    // it never paints an unproven row as usable.
    const gated = (typeof item.when === "string" && item.when.trim() !== "")
      || (item.requires !== undefined && item.requires !== null)
    if (gated && root.guardWhen[item.uid] !== true) return true
    // Provider visibility predicate: clearUsageHistory declares itself
    // unusable while history is empty (frequency sort's companion row).
    if (item.id) {
      const p = root._providerFor(item.id)
      if (p && typeof p.visible === "function"
        && p.visible(item, root._hookCtx(item)) === false) return true
    }
    return false
  }

  // EmojiPicker prewarm hook – delegates to the active panel when present.
  function warmPage(pageId, cols) {
    if (probeSource && typeof probeSource.warmPage === "function") {
      probeSource.warmPage(pageId, cols)
    } else {
      Log.debug(tag, "warmPage " + pageId + " (panel not ready)")
    }
  }

  // --- external search index ---
  // Pages the bundle parser never sees (picker pages enumerating the disk)
  // register their rows here under their dynamic page id, so global search
  // spans them. Replace-by-owner: one call replaces the owner's whole set.

  function provideIndexFor(owner) {
    if (!owner || typeof owner !== "object") return false
    const providers = root._indexProviders
    for (let i = 0; i < providers.length; i++) {
      if (providers[i] === owner) return true
    }
    root._indexProviders = providers.concat([owner])
    return true
  }

  // Index one injected page: entries are indistinguishable from bundle
  // rows to search() and jumpTo() (see MenuLib.buildPageIndex - injected
  // pages have no bundle parent and pass a bare [page.label] breadcrumb).
  function indexExternal(page) {
    if (!page || typeof page.id !== "string" || page.id === ""
      || !Array.isArray(page.items)) return false
    const entries = MenuLib.buildPageIndex(page, [page.label], [])
    const next = Object.assign({}, root._indexRegistrations)
    next[page.id] = entries
    root._indexRegistrations = next
    root._rebuildSearchIndex()
    return true
  }

  function unindexExternal(pageId) {
    if (typeof pageId !== "string" || pageId === "") return false
    if (root._indexRegistrations[pageId] === undefined) return false
    const next = Object.assign({}, root._indexRegistrations)
    delete next[pageId]
    root._indexRegistrations = next
    root._rebuildSearchIndex()
    return true
  }

  // Whether `pageId` currently answers a global query: a registration merged
  // into the live index. A registration alone is not enough - the index merges
  // them only while a settings-family bundle is active, so the same row set
  // reads as absent (and no query can reach it) under the utilities entry or a
  // standalone picker bundle.
  function hasExternalIndex(pageId) {
    if (typeof pageId !== "string" || pageId === "") return false
    if (root._settingsFamily !== true) return false
    return root._indexRegistrations[pageId] !== undefined
  }

  // A container reload drops every injected page (see _loadContainers), so
  // their index registrations go with them; owners republish live ones
  // right after through republishIndex().
  function _dropPageIndexRegistrations(dropped) {
    if (!dropped) return
    const ids = Object.keys(dropped)
    if (ids.length === 0) return
    const next = Object.assign({}, root._indexRegistrations)
    let changed = false
    for (let i = 0; i < ids.length; i++) {
      if (next[ids[i]] !== undefined) {
        delete next[ids[i]]
        changed = true
      }
    }
    if (changed) root._indexRegistrations = next
  }

  // --- navigation ---

  // Runtime pages generated on demand. Two tables, two lifecycles:
  // _optionPages (select option lists) reset on every prime; dynamic
  // service pages (emoji recents) survive summons in _dynamicPages so an
  // open never recomposes them - owners refresh on their own state
  // changes, and _loadContainers clears the table for new containers.
  // Kept out of bundle so dump/search never see them.

  // Hand a service-built page to the menu: normalized upstream through
  // MenuLib.buildPage (see buildDynamicPage), then registered here so
  // navigation, search-jump and rendering treat it like any other page.
  // `api` optionally carries owner callbacks keyed by capability (e.g.
  // insert/forget for pickers); the panel routes row actions declared on
  // items (delCommand etc) back to the owning page through it. Injecting
  // also indexes the page's rows for global search (see indexExternal),
  // unless `index` is false: picker rows reachable only from their own
  // surface (theme removal) never answer a query typed anywhere else. A
  // re-inject with the opt-out withdraws a stale registration, so old
  // rows cannot stay searchable behind the new page.
  function injectPage(page, api, index) {
    if (!page || typeof page.id !== "string" || page.id === "") return false
    const next = Object.assign({}, root._dynamicPages)
    next[page.id] = page
    root._dynamicPages = next
    const apis = Object.assign({}, root._dynamicApis)
    if (api) apis[page.id] = api
    else delete apis[page.id]
    root._dynamicApis = apis
    if (index === false) root.unindexExternal(page.id)
    else root.indexExternal(page)
    // rev refreshes bound rows; condRev makes the panel re-filter so a
    // page that swapped content under the same id re-renders (animated,
    // since this is a content delta rather than wholesale navigation).
    root.rev++
    root.condRev++
    return true
  }

  function hasDynamicPage(id) {
    return root._dynamicPages[id] !== undefined
  }

  function dynamicApi(id) {
    return root._dynamicApis[id] ?? null
  }

  // Normalize raw rows into a proper page object without touching menu
  // state. Exists so widgets can build pages through the same MenuLib
  // pipeline as bundles instead of importing the JS library across
  // module directories (cross-dir .pragma imports are fragile).
  function buildDynamicPage(id, title, width, rawItems, opts) {
    return MenuLib.buildPage(id, title, width, rawItems, opts)
  }

  function commitOption(item) {
    const parent = root.itemByUid(item ? item._parentUid : "")
    if (!item || !parent) return false
    if (item.enabled === false || root.isDisabled(item)) return false
    const isAction = parent.var === "" && (parent.onSelect !== "" || parent.onCall !== "")
    setValue(parent, item.value)
    if (isAction) {
      // Action-select (e.g. Recording): close the whole menu first so
      // capture UIs don't appear over the layer, then run.
      const val = item.value
      // Pop option page, then close menu
      pop()
      close()
      Qt.callLater(() => parent.onCall !== ""
        ? root.runCall(parent.onCall, val)
        : root.runCommand(parent.onSelect, val))
    } else {
      if (parent.onCall !== "") runCall(parent.onCall, item.value)
      else runCommand(parent.onSelect, item.value)
      pop()
    }
    return true
  }

  function optionIsChosen(item) {
    const parent = root.itemByUid(item ? item._parentUid : "")
    if (!parent) return false
    return String(stateOf(parent).value) === String(item.value)
  }

  // Reverse uid -> item lookup across all known pages. The trailing
  // component of a uid is an arbitrary sanitized key, not necessarily a
  // numeric index, so resolve by uid match rather than array indexing -
  // otherwise rows whose id is not a number (e.g. "idle-add") can never
  // be found and their flow/prompt state silently degrades to a
  // plain prompt.
  function itemByUid(uid) {
    if (!uid) return null
    const hash = uid.lastIndexOf("#")
    if (hash < 0) return null
    const pageId = uid.substring(0, hash)
    const page = (root._dynamicPages && root._dynamicPages[pageId])
      || (root._optionPages && root._optionPages[pageId])
      || (root.bundle && root.bundle.byId ? root.bundle.byId[pageId] : null)
      || null
    if (!page || !page.items) return null
    const items = page.items
    const key = uid.substring(hash + 1)
    const index = Number(key)
    if (Number.isInteger(index) && index >= 0 && index < items.length) {
      const direct = items[index]
      if (direct && direct.uid === uid) return direct
    }
    // A group nested in another group is a normalized row with a uid of its
    // own, but it is not in page.items. Walk the children too, or a nested
    // group cannot resolve its own source and unfolds to an empty slot.
    function findIn(list, depth) {
      for (let i = 0; i < list.length; i++) {
        const it = list[i]
        if (!it) continue
        if (it.uid === uid) return it
        if (depth > 0 && Array.isArray(it.children)) {
          const nested = findIn(it.children, depth - 1)
          if (nested) return nested
        }
      }
      return null
    }
    // A vault can nest far deeper than four groups. Resolve by uid through
    // the whole live tree so a deep row's provider, guard and landing waiter
    // can find it; the walk is bounded only to stop a malformed cycle.
    return findIn(items, 12)
  }

  function hasPage(id) {
    if (!root.bundle) return false
    if (root._dynamicPages[id] || root._optionPages[id] || root.bundle.byId[id])
      return true
    Log.warn(root.tag, "unknown page '" + id + "'")
    return false
  }

  function pageById(id) {
    if (!root.bundle) return null
    return root._dynamicPages[id] || root._optionPages[id]
      || root.bundle.byId[id] || null
  }

  function beginRestore(pageId) {
    const next = Object.assign({}, root._restorePending)
    next[pageId] = true
    root._restorePending = next
  }

  function endRestore(pageId) {
    if (root._restorePending[pageId] === undefined) return
    const next = Object.assign({}, root._restorePending)
    delete next[pageId]
    root._restorePending = next
  }

  // Remember the position of every page - the entry page included, so
  // coming back from a submenu re-seats the cursor on the link that was
  // entered. close() clears the whole map: memory is per open session.
  // The uid pins the seat to the row rather than the number (see
  // MenuPanel.applyFrameState): guard batches and reveals move rows, the
  // uid survives all of those.
  //
  function saveFrame(sel, y, uid) {
    if (!root.frame) return
    const next = Object.assign({}, root.viewState)
    const rec = { sel: sel, y: y }
    if (uid !== undefined) rec.uid = uid
    next[root.frame.id] = rec
    root.viewState = next
  }

  function savedFor(pageId) {
    return root.viewState[pageId] ?? null
  }

  function push(pageId) {
    root._landingIntent = null
    if (!root.hasPage(pageId)) return false
    const next = root.stack.slice()
    next.push({
      id: pageId,
      sel: 0,
      y: 0
    })
    root.resetSearch()
    // Fresh landings start at the top; revisited pages restore their
    // remembered cursor instead.
    root.pendingSel = root.viewState[pageId] !== undefined ? -1 : 0
    root.beginRestore(pageId)
    root.stack = next
    Log.debug(root.tag, "push " + pageId + " depth=" + next.length)
    return true
  }

  // Expansions and open descriptions never survive leaving a page -
  // returning later lands on a clean row.
  function collapseFrame(pageId) {
    const pg = root.pageById(pageId)
    if (!pg) return
    let changed = false
    for (let i = 0; i < pg.items.length; i++) {
      const st = root._states[pg.items[i].uid]
      if (st && (st.expanded || st.info)) {
        st.expanded = false
        st.info = false
        changed = true
      }
    }
    if (changed) root.rev++
  }

  function pop() {
    if (!root.open) return
    if (root.stack.length <= 1) {
      root.close()
      return
    }
    root._landingIntent = null
    root.collapseFrame(root.frame.id)
    root.resetSearch()
    // Leaf pages forget their cursor: only ancestors (parents) keep
    // remembered positions across navigation.
    const leaving = root.frame.id
    const vs = Object.assign({}, root.viewState)
    delete vs[leaving]
    root.viewState = vs
    if (root.stack.length > 1) root.beginRestore(root.stack[root.stack.length - 2].id)
    root.stack = root.stack.slice(0, -1)
    Log.debug(root.tag, "pop depth=" + root.stack.length)
  }

  // One step back without closing: the Back key and the `back` IPC verb.
  function back() {
    if (!root.open) return false
    root.pop()
    return true
  }

  // Jump anywhere in the bundle: fresh stack rooted at the target page
  // with the target row preselected, bypassing any remembered position.
  // Used by search activation. `row` indexes the RAW items array; every
  // declared row is listed, so the listed position counts the skipped chrome
  // only (isListed is still the one question the walk asks).
  function visibleIndexOf(page, rawRow) {
    let n = 0
    const items = page ? page.items : []
    for (let i = 0; i < rawRow && i < items.length; i++) {
      if (root.isListed(items[i])) n++
    }
    return n
  }

  // Where a uid sits in the LIVE page, counting listed rows only. -1
  // when the page is unknown or the row is not on it.
  function visibleIndexOfUid(pageId, uid) {
    if (uid === undefined || uid === null || uid === "") return -1
    const page = root.pageById(pageId)
    if (!page || !Array.isArray(page.items)) return -1
    let n = 0
    for (let i = 0; i < page.items.length; i++) {
      const it = page.items[i]
      if (!root.isListed(it)) continue
      if (it.uid === uid) return n
      n++
    }
    return -1
  }

  function jumpTo(pageId, row) {
    if (!root.hasPage(pageId)) return false
    // A jump to the page already on screen installs no new page, so the
    // panel's onCurrentPageIdChanged handler never runs to hand the seat
    // over. Note the case before the stack is replaced.
    const samePage = !!root.frame && root.frame.id === pageId
    root.collapseFrame(root.frame.id)
    const vs = Object.assign({}, root.viewState)
    delete vs[pageId]
    root.viewState = vs
    root.resetSearch()
    // The frame seats the LISTED position, not the raw page index: guard-
    // hidden rows never reach the list model, so a raw slot is a seat no row
    // owns (store-gated rows stay listed and keep their slot). The same number
    // drives the landing (pendingSel) and the fallback the frame keeps for a
    // revisit without remembered state.
    const at = visibleIndexOf(root.pageById(pageId), row)
    root.pendingSel = at
    root.beginRestore(pageId)
    root.stack = [{
        id: pageId,
        sel: at,
        y: 0
      }]
    // A page change consumes pendingSel in applyFrameState from its own
    // install. Clearing the search onto the SAME page leaves no such install,
    // so hand the seat over here instead - otherwise pendingSel stays armed
    // and every settled waiter (the group/select/search-result landings) is
    // blocked on its `pendingSel < 0` gate forever. Deferred so the search
    // teardown's same-turn row install has landed before the seat is applied.
    if (samePage && root.panel && typeof root.panel.applyFrameState === "function") {
      const panel = root.panel
      Qt.callLater(function() { panel.applyFrameState() })
    }
    return true
  }

  // --- scoped "/" quick-filter ---

  // Arm the in-page filter. Scope stays the CURRENT page until cleared;
  // with an empty query it shows the full visible page so the first
  // keystroke simply narrows it.
  function beginScoped() {
    // The projection first, the flag second. Arming re-projects the panel's
    // rows off `scopedQuery`; publishing the flag before the empty query has
    // published its visible set installs a projection of nothing and drops
    // the card to its empty state for a beat.
    root.setScopedQuery("")
    root.scopedActive = true
  }

  // Filter scope is the current menu - the page on screen and the groups
  // nested in it - trimmed in place, never flattened. A group that holds a
  // match stays where it is; only the branches under it that matched survive,
  // so opening it shows its children in their own dropdown, with that
  // dropdown's own bar and background. Flattening a deep hit to a top-level
  // row instead produced a naked option sitting between page rows: no
  // dropdown, no bar geometry, and a card sized for a row that was never a
  // page row.
  //
  // `visible` names every row kept at any depth. `trimmed` names the groups
  // whose children must be narrowed to that set - a group whose OWN label
  // matched keeps its whole subtree, because the user asked for that group
  // and everything under it is in scope.
  function _scopedTree(pg, text) {
    const state = {
      rows: [],
      visible: Object.create(null),
      trimmed: Object.create(null)
    }
    if (!pg || !Array.isArray(pg.items)) return state
    const q = String(text ?? "").toLowerCase().trim()
    const tokens = q === "" ? [] : q.split(/\s+/).filter(t => t !== "")
    const matches = (it) => {
      const hay = MenuLib.hayForFilter(it)
      for (let t = 0; t < tokens.length; t++)
        if (hay.indexOf(tokens[t]) < 0) return false
      return true
    }
    const walk = (list, depth) => {
      const rows = []
      for (let i = 0; i < list.length; i++) {
        const it = list[i]
        if (!root.isListed(it)) continue
        const kids = depth > 0 && Array.isArray(it.children) ? it.children : null
        const kidRows = kids ? walk(kids, depth - 1) : []
        const selfMatch = tokens.length === 0 || matches(it)
        if (selfMatch || kidRows.length > 0) {
          rows.push(it)
          if (it.uid !== undefined && it.uid !== null) state.visible[String(it.uid)] = true
          if (kids && !selfMatch && it.uid !== undefined && it.uid !== null)
            state.trimmed[String(it.uid)] = true
        }
      }
      return rows
    }
    state.rows = walk(pg.items, 6)
    return state
  }

  function setScopedQuery(q) {
    const text = String(q ?? "")
    const pg = root.pageById(root.frame ? root.frame.id : "")
    const tree = _scopedTree(pg, text)
    // Small scopes install instantly like before; only giant ones ride
    // the debounce (see scopedTimer). Empty queries always apply at once.
    if (text === "" || tree.rows.length <= Ui.listFullRows) {
      scopedTimer.stop()
      root._applyScopedQuery(text, tree)
      return
    }
    root._scopedPending = text
    scopedTimer.restart()
  }

  function _applyScopedQuery(q, pre) {
    root._scopedPending = ""
    root._retireSearchRefs()
    root.scopedQuery = q
    let tree = pre
    if (!tree || !Array.isArray(tree.rows)) {
      tree = _scopedTree(root.pageById(root.frame ? root.frame.id : ""), q)
    }
    root.scopedProjectionRev++
    root.scopedVisibleUids = tree.visible
    root.scopedTrimmedGroups = tree.trimmed
  }

  // Apply a debounced query now. True when one was pending, so callers
  // can re-drive what they came to do after the model catches up.
  function flushScoped() {
    if (!scopedTimer.running) return false
    scopedTimer.stop()
    root._applyScopedQuery(root._scopedPending)
    return true
  }

  function clearScoped() {
    scopedTimer.stop()
    root._scopedPending = ""
    if (!root.scopedActive && root.scopedQuery === ""
      && Object.keys(root.scopedTrimmedGroups).length === 0) return
    root.scopedActive = false
    root.scopedQuery = ""
    // Publish the restore edge for the panel as well: clearing the filter
    // re-projects the full page, and the seat hand-back rides that install.
    root.scopedProjectionRev++
    root.scopedVisibleUids = ({})
    root.scopedTrimmedGroups = ({})
  }

  // --- item state ---

  // Canonical mutable records keyed by uid.
  function _rawState(item) {
    let st = root._states[item.uid]
    if (st === undefined) {
      st = MenuState.initialState(item,
        (key) => root._condStore(key).value(String(key || "")))
      root._states[item.uid] = st
    }
    return st
  }

  // Returns a COPY. Bindings capture `rev` first so they re-run on every
  // mutation, and the fresh object guarantees dependents see a change - a
  // same-reference var result would silently notify nobody.
  function stateOf(item) {
    if (!item || !item.uid) return MenuState.blankState()
    root.rev
    return Object.assign({}, root._rawState(item))
  }

  // A row's stored value, read WITHOUT the defensive copy stateOf makes.
  //
  // stateOf hands out a fresh map because a caller may keep it and compare it,
  // and it captures rev so a BINDING that calls it re-evaluates when state
  // changes. This one is for the width pass, which is imperative: it walks a
  // page of rows on every navigation and every open and must not allocate a map
  // per row, and a dependency it never reads would only register a binding this
  // function is not written for. A caller inside a binding wants stateOf.
  function valueOf(item) {
    if (!item || !item.uid) return undefined
    return root._rawState(item).value
  }

  function setChecked(item, value) {
    if (!item || !item.uid) return false
    if (item.var !== "") {
      let ok = false
      const v = String(item.var)
      if (v.indexOf("hypr.") === 0) ok = HyprlandSettings.setOption(item.var, value === true)
      else if (v.indexOf("misc.") === 0) ok = MiscSettings.setOption(item.var, value === true)
      else ok = Settings.setOption(item.var, value === true)
      if (!ok) return false
    }
    root._rawState(item).checked = value === true
    root.rev++
    return true
  }

  // Optimistic write for literal/mirror toggles (checked is a system
  // expression): stamp the requested state so the pill flips instantly,
  // then the upcoming guard re-evaluation replaces it with whatever
  // reality actually reports. Assigns a fresh map so every reader (incl.
  // Entry.toggleOn via this fn's guardChecked access) sees the change.
  function setGuardChecked(item, value) {
    if (!item || !item.uid) return
    const next = Object.assign({}, root.guardChecked)
    next[item.uid] = value === true
    root.guardChecked = next
    root.rev++
  }

  function setValue(item, value) {
    if (!item || !item.uid) return false
    if (item.var !== "") {
      let ok = false
      const v = String(item.var)
      if (v.indexOf("hypr.") === 0) ok = HyprlandSettings.setOption(item.var, value)
      else if (v.indexOf("misc.") === 0) ok = MiscSettings.setOption(item.var, value)
      else ok = Settings.setOption(item.var, value)
      if (!ok) return false
    }
    root._rawState(item).value = value
    root.rev++
    return true
  }

  // --- expansion slots ---

  // The row's own close latch: `closing` sets it, clearing drops it. The map
  // is replaced, not mutated, so a binding re-evaluates on assignment.
  function _setSlotClose(uid, closing) {
    if (!uid) return
    root._slotCloses = MenuState.withSlotClose(root._slotCloses, uid, closing)
  }

  // Arm the close latch BEFORE the state write and its rev. The claim
  // handlers react to that rev and release the slot's growth claim; the
  // panel's region guard reads slotClosing to decide whether to hold the
  // card. Arming afterwards let the claim release with no close in flight,
  // clearing the region for one frame - the card dropped to its resting
  // height and was restored before the fold started. The latch is cleared
  // by slotCloseFinished when the slot actually reaches rest.
  function setExpanded(item, value) {
    if (value !== true && item && item.uid) root._setSlotClose(item.uid, true)
    root._rawState(item).expanded = value === true
    root.rev++
    if (value === true && item && item.uid && root._slotCloses[item.uid] !== undefined)
      root._setSlotClose(item.uid, false)
  }

  // Open a whole ancestor chain with one rev bump. A deep landing used to
  // write each group separately, and every write re-ran row projection and
  // width measurement over the whole vault on the UI thread.
  function setExpandedBatch(items, value) {
    const list = Array.isArray(items) ? items : []
    for (let i = 0; i < list.length; i++) {
      const it = list[i]
      if (!it || !it.uid) continue
      if (value !== true) root._setSlotClose(it.uid, true)
      root._rawState(it).expanded = value === true
      if (value === true && root._slotCloses[it.uid] !== undefined)
        root._setSlotClose(it.uid, false)
    }
    if (list.length > 0) root.rev++
  }

  function setInfo(item, value) {
    if (value !== true && item && item.uid) root._setSlotClose(item.uid, true)
    root._rawState(item).info = value === true
    root.rev++
    if (value === true && item && item.uid && root._slotCloses[item.uid] !== undefined)
      root._setSlotClose(item.uid, false)
  }

  // Folding a group folds every slot it contains, including descendants whose
  // delegates are not loaded at this instant. Their state lives on the model;
  // a grandchild left expanded would reappear under a collapsed chevron on the
  // next open. Loaded delegates are handled by Entry.collapse(); this reaches
  // the rest.
  function clearDescendantState(item) {
    if (!item || !Array.isArray(item.children)) return false
    let changed = false
    const walk = function(kids) {
      for (let i = 0; i < kids.length; i++) {
        const kid = kids[i]
        if (!kid || !kid.uid) continue
        const st = root._states[kid.uid]
        const modal = st && (st.expanded === true || st.info === true
          || st.promptOpen === true || st.confirmKind !== ""
          || (Number(st.confirmStage) || 0) !== 0)
        if (modal) {
          st.expanded = false
          st.info = false
          st.promptOpen = false
          st.confirmKind = ""
          st.confirmStage = 0
          root._setSlotClose(kid.uid, false)
          if (MenuLib.isFlow(kid)) delete root._flow[kid.uid]
          changed = true
          root.trace("menu.descClear", { id: String(kid.id ?? kid.uid) })
        }
        if (Array.isArray(kid.children)) walk(kid.children)
      }
    }
    walk(item.children)
    if (changed) root.rev++
    return changed
  }

  function infoOpen(item) {
    if (!item || !item.uid) return false
    const st = root._states[item.uid]
    return st ? st.info === true : false
  }

  // Non-copying read for panel-side scans (freeze bookkeeping); unlike
  // stateOf this allocates nothing.
  function isExpanded(item) {
    if (!item || !item.uid) return false
    const st = root._states[item.uid]
    return st ? st.expanded === true : false
  }

  // The row's own close latch: true while its slot is still easing shut.
  function isSlotClosing(item) {
    if (!item || !item.uid) return false
    return root._slotCloses[item.uid] === true
  }

  // The row reports its slot motion at rest: the close landed, drop the
  // latch. A reopen inside the grace window never goes still, so the
  // latch just re-arms instead.
  // The row reports its slot motion at rest: the close landed, drop the
  // latch. The delegate never touches the panel's list here.
  function slotCloseFinished(item) {
    if (!item || !item.uid) return
    const next = MenuState.withoutSlotClose(root._slotCloses, item.uid)
    if (next !== root._slotCloses) root._slotCloses = next
  }

  // A child's nested slot opens inside its parent's row: the panel owns the
  // list seat, so these verbs only forward. The delegate never touches List.
  function beginNestedReveal() {
    if (root.panel && root.panel.beginNestedReveal) root.panel.beginNestedReveal()
  }
  function beginNestedRestore(paceMs) {
    if (root.panel && root.panel.beginNestedRestore)
      root.panel.beginNestedRestore(paceMs)
  }
  function nestedSlotFinished(item) {
    slotCloseFinished(item)
    root.rev++
    if (root.panel && root.panel.nestedSlotFinished) root.panel.nestedSlotFinished()
  }

  // A close latch belongs to a row the model still lists. `candidate` is
  // the authoritative next model, so anything pruned here has no delegate
  // left to report its close.
  function pruneSlotCloses(candidate) {
    const next = MenuState.pruneSlotCloses(root._slotCloses, candidate)
    if (next !== root._slotCloses) root._slotCloses = next
  }

  // --- shared row actions ---------------------------------------------------
  // Every mutation a row can cause lives here. The UI delegates and the public
  // gateway both call these methods with the same normalized row and a context
  // naming the page, the view and the caller. The context may carry two
  // delegate-only callbacks (`collapse` and `focus`) for visual mechanics; a
  // gateway call supplies neither and never inspects `currentItem`.

  function rowCanOperate(item, ancestors) {
    if (!item) return false
    if (MenuIpc.layoutRow(item.type)) return false
    const chain = (ancestors || []).concat([item])
    for (let i = 0; i < chain.length; i++) {
      const row = chain[i]
      if (!row || row.enabled === false || root.isDisabled(row) || root.isUnavailable(row)) return false
    }
    return true
  }

  function rowState(item) { return root.stateOf(item) }

  function _actionWasFiltered() { return root.scopedActive }

  function _clearActionFilter(item) {
    if (!root.scopedActive) return
    if (item && item.scopedResult === true) return
    if (root.panel) root.panel._scopedClearByAction = true
    root.clearScoped()
  }

  function _collapseRow(item, ctx) {
    if (ctx && typeof ctx.collapse === "function") ctx.collapse()
    else {
      root.clearDescendantState(item)
      root.setExpanded(item, false)
      const st = root.stateOf(item)
      if (st.promptOpen || st.confirmKind !== "") root._setRowState(item, {
        promptOpen: false, confirmKind: "", confirmStage: 0
      })
      if (MenuLib.isFlow(item)) root.resetFlow(item)
    }
  }

  function _focusEditor(ctx) {
    if (ctx && typeof ctx.focus === "function") ctx.focus()
  }

  // Copy-on-write patch of a row's shared modal state.
  function _setRowState(item, patch) {
    if (!item || !item.uid) return
    const st = root._rawState(item)
    for (const key in patch) st[key] = patch[key]
    root.rev++
  }

  function setPromptOpen(item, value) {
    if (!item) return
    root._setRowState(item, { promptOpen: value === true })
  }

  function confirmKindOf(item) {
    const st = root.stateOf(item)
    return String(st.confirmKind || "")
  }

  function confirmStageOf(item) {
    return Number(root.stateOf(item).confirmStage) || 0
  }

  function rowSetExpanded(item, value, ctx) {
    if (!item) return false
    if (MenuLib.isFlow(item) && value === false) root.resetFlow(item)
    root.setExpanded(item, value === true)
    return true
  }

  // A toggle flips through the same precedence the delegate used: provider
  // first, then guarded mirror, then the owning settings store.
  function rowSetToggle(item, state, ctx) {
    if (!item || !root.rowCanOperate(item, ctx && ctx.ancestors)) return false
    const _wasFiltered = root._actionWasFiltered()
    try {
      if (root.handleToggle(item, state)) return true
      const guarded = typeof item.checked === "string" && item.checked !== ""
      if (guarded) {
        root.setGuardChecked(item, state)
        if (item.onToggle) root.runCommand(item.onToggle, state)
        root.refreshGuards()
      } else {
        if (item.var === "" && !item.onToggle) return false
        if (!root.setChecked(item, state)) return false
        if (item.onToggle) root.runCommand(item.onToggle, state)
      }
      return true
    } finally {
      if (_wasFiltered) root._clearActionFilter(item)
    }
  }

  // Grid and list action dispatch. The grid route keeps its existing order:
  // dynamic `insert` and the command first, then the close; a list route
  // closes before dispatch unless `keepOpen`.
  function rowRunAction(item, ctx) {
    if (!item || !root.rowCanOperate(item, ctx && ctx.ancestors)) return false
    if (item.id === "timer.stop") {
      root.handleConfirm({ id: "timer" })
      return true
    }
    const view = ctx && ctx.view === "grid" ? "grid" : "list"
    if (view === "grid") {
      const pageId = ctx && ctx.pageId ? ctx.pageId : root.pageId
      const api = root.dynamicApi(pageId)
      if (api && typeof api.insert === "function") api.insert(String(item.value ?? ""))
      let cmd = String(item.command ?? "")
      if (cmd === "") {
        const pg = root.pageById(pageId)
        if (pg && typeof pg.command === "string") cmd = pg.command
      }
      if (item.call !== "") root.runCall(item.call, item.value !== undefined ? item.value : "")
      else if (cmd !== "") root.runCommand(cmd, item.value !== undefined ? item.value : "")
      if (item.keepOpen !== true) root.close()
      return true
    }
    if (item.keepOpen !== true) root.close()
    if (item.call !== "") root.runCall(item.call, item.value !== undefined ? item.value : "")
    else root.runCommand(item.command, item.value !== undefined ? item.value : "")
    return true
  }

  function rowOpen(item, ctx) {
    if (!item) return false
    if (item.type === "submenu") {
      const panel = root.panel || root.probeSource
      if (panel && typeof panel.pushPage === "function") panel.pushPage(item.page)
      else root.push(item.page)
      return true
    }
    if (item.type === "select" || item.type === "group" || item.type === "expandable") {
      if (item.infoOnly && (item.type === "expandable")) return false
      root.setExpanded(item, true)
      return true
    }
    if (item.type === "number" || item.type === "range" || item.type === "text") {
      // Seeding the editor is not a persisted write: it makes the field show
      // the value the commit will use.
      if (!root.isExpanded(item)) {
        root.setValue(item, item.type === "text"
          ? String(root.valueOf(item) ?? "")
          : (ctx && ctx.numeric !== undefined ? Number(ctx.numeric) : root._numericFor(item)))
      }
      root.setExpanded(item, true)
      _focusEditor(ctx)
      return true
    }
    return false
  }

  function _numericFor(item) {
    if (!item) return 0
    const v = root.valueOf(item)
    const n = Number(v === undefined || v === null ? (item.value !== undefined ? item.value : item.min) : v)
    return isFinite(n) ? n : Number(item.min) || 0
  }

  function rowClose(item, ctx) {
    if (!item) return false
    root._collapseRow(item, ctx)
    return true
  }

  function rowSetInfo(item, value, ctx) {
    if (!item) return false
    root.setInfo(item, value === true)
    return true
  }

  function rowChoose(item, value, ctx) {
    if (!item) return false
    if (item.type === "option") {
      const parent = root.itemByUid(item._parentUid)
      if (parent && !root.rowCanOperate(parent, ctx && ctx.ancestors)) return false
      return root.commitOption(item)
    }
    if (!root.rowCanOperate(item, ctx && ctx.ancestors)) return false
    const _wasFiltered = root._actionWasFiltered()
    try {
      if (MenuLib.isFlow(item) && String(item.type) === "select") {
        if (root.rowFlowAdvance(value, ctx)) return true
        root.rowFlowCommit(ctx)
        return true
      }
      if (item.editValue !== undefined && String(value) === String(item.editValue)) {
        root.setPromptOpen(item, true)
        root.setExpanded(item, true)
        _focusEditor(ctx)
        return true
      }
      const isAction = item.var === "" && (item.onSelect !== "" || item.onCall !== "")
      root._collapseRow(item, ctx)
      const st = root.stateOf(item)
      if (!isAction && String(st.value) === String(value)) return true
      if (!root.setValue(item, value)) return false
      if (isAction) {
        if (item.keepOpen === true) {
          if (item.onCall !== "") root.runCall(item.onCall, value)
          else root.runCommand(item.onSelect, value)
        } else {
          root.close()
          Qt.callLater(() => item.onCall !== ""
            ? root.runCall(item.onCall, value)
            : root.runCommand(item.onSelect, value))
        }
      } else {
        if (item.onCall !== "") root.runCall(item.onCall, value)
        else root.runCommand(item.onSelect, value)
      }
      return true
    } finally {
      if (_wasFiltered) root._clearActionFilter(item)
    }
  }

  // Commit the value an editor holds. Text is trimmed, numbers are parsed as
  // a leading decimal then clamped and quantized, and the display-unit rule
  // is the same one Entry used for onChange.
  function rowCommitEdit(item, text, ctx) {
    if (!item) return false
    if (MenuLib.isFlow(item)) {
      if (root.rowFlowAdvance(text, ctx)) return true
      root.rowFlowCommit(ctx)
      return true
    }
    if (root.confirmKindOf(item) !== "") return false
    if (root.stateOf(item).promptOpen) {
      const typed = String(text).trim()
      root.setPromptOpen(item, false)
      root._collapseRow(item, ctx)
      if (typed !== "" && item.editCall !== undefined && item.editCall !== "")
        root.runCall(item.editCall, typed)
      return true
    }
    if (item.type === "text") {
      const t = String(text).trim()
      if (item.var !== undefined && item.var !== "") {
        if (!root.setValue(item, t)) return false
        if (t !== "" && item.onSubmit) root.runCommand(item.onSubmit, t)
        root._collapseRow(item, ctx)
        return true
      }
      if (item.allowEmpty !== true && t === "" && item.onSubmit) {
        root._collapseRow(item, ctx)
        return true
      }
      if (item.onSubmit) {
        // A caller-supplied shell template may only be interpolated with a
        // quoted, standalone %v token. The UI path keeps its configured
        // template unchanged and passes the text as the raw substitution
        // value, exactly as the editor always did. Validate before the write.
        const template = ctx && ctx.origin === "ui" ? item.onSubmit
          : MenuIpc.safeShellTemplate(item.onSubmit) ? item.onSubmit : null
        if (template === null) return false
        // The UI keeps its clear-then-run rule. A gateway write reports the
        // value it committed, so the typed text stays in the row's value slot.
        if (ctx && ctx.origin === "ui") root.setValue(item, "")
        else root.setValue(item, t)
        if (ctx && ctx.origin === "ui") root.runCommand(template, t)
        else root.runCommand(MenuIpc.quoteShellValue(template, t), "")
      } else root.setValue(item, t)
      root._collapseRow(item, ctx)
      return true
    }
    if (item.type === "number" || item.type === "range") {
      const raw = String(text).trim()
      if (raw === "") { root._collapseRow(item, ctx); return true }
      const typed = MenuLib.leadingNumber(raw)
      if (typed === null) return false
      const next = MenuLib.quantize(MenuLib.clamp(typed, Number(item.min) || 0, Number(item.max) || 0))
      if (!root.setValue(item, next)) return false
      if (!root.handleNumberChange(item, next) && item.onChange !== "")
        root.runCommand(item.onChange, Format.fixed(next, MenuLib.decimalsOf(Number(item.step) || 1))
          + MenuLib.unitSuffix(item.unit))
      root._collapseRow(item, ctx)
      if (item.close === true) root.close()
      return true
    }
    return false
  }

  function rowStep(item, direction, ctx) {
    if (!item || (item.type !== "number" && item.type !== "range")) return false
    if (!root.rowCanOperate(item, ctx && ctx.ancestors)) return false
    if (root.isNumberActive(item)) return false
    const ctx2 = ctx || {}
    const stepSize = ctx2.numeric !== undefined ? Number(ctx2.step !== undefined ? ctx2.step : item.step) : (Number(item.step) || 1)
    const lo = ctx2.minimum !== undefined ? Number(ctx2.minimum) : Number(item.min) || 0
    const hi = ctx2.maximum !== undefined ? Number(ctx2.maximum) : Number(item.max) || 0
    const current = ctx2.numeric !== undefined ? Number(ctx2.numeric) : Number(root._numericFor(item))
    let next = MenuLib.clamp(current + direction * (stepSize || 1), lo, hi)
    next = MenuLib.quantize(next)
    if (next === current) return true
    if (!root.setValue(item, next)) return false
    if (!root.handleNumberChange(item, next) && item.onChange !== "")
      root.runCommand(item.onChange, Format.fixed(next,
        ctx2.decimals !== undefined ? Number(ctx2.decimals) : MenuLib.decimalsOf(stepSize))
        + (ctx2.unit !== undefined ? String(ctx2.unit) : MenuLib.unitSuffix(item.unit)))
    return true
  }

  // --- staged flow (one cursor per flow uid) --------------------------------

  function _flowDraft(item, value, hasValue) {
    const uid = item ? item.uid : ""
    if (!uid) return false
    const st = root._flowState(item)
    st.draft = { set: hasValue === true, value: value }
    root.rev++
    return true
  }

  function rowFlowAdvance(value, ctx) {
    const item = ctx && ctx.item ? ctx.item : null
    const src = item && MenuLib.isFlow(item) ? item : null
    if (!src || !root.isExpanded(src)) return false
    const idx = root.flowIndexOf(src)
    const stage = MenuLib.flowStep(src, idx)
    if (!stage) return false
    if (stage.required && String(value === undefined || value === null ? "" : value).trim() === "") return false
    if (stage.kind === "select" || stage.kind === "number" || stage.kind === "range"
      || stage.kind === "text") {
      root._flowDraft(src, value, true)
    }
    const values = root.flowValuesOf(src)
    const next = MenuLib.nextFlowIndex(src, idx + 1, values)
    const st = root._flowState(src)
    if (next >= MenuLib.flowCount(src)) {
      // The last stage was answered: copy the draft into the committed map
      // and arm the one-shot commit. Another commit is then refused until the
      // flow is reopened.
      st.values[String(idx)] = value
      st.draft = { set: false, value: null }
      st.ready = true
      root.rev++
      return false
    }
    if (Array.isArray(st.visited) && st.visited.indexOf(next) < 0) st.visited.push(next)
    st.index = next
    st.draft = { set: false, value: null }
    root.rev++
    _focusEditor(ctx)
    return true
  }

  function rowFlowSet(step, value, ctx) {
    const item = ctx && ctx.item ? ctx.item : null
    const src = item && MenuLib.isFlow(item) ? item : null
    if (!src) return false
    const idx = Number(step) || 0
    if (idx !== root.flowIndexOf(src)) return false
    const stage = MenuLib.flowStep(src, idx)
    if (!stage) return false
    if (stage.sensitive === true) return false
    return root._flowDraft(src, value, true)
  }

  function rowFlowBack(ctx) {
    const item = ctx && ctx.item ? ctx.item : null
    const src = item && MenuLib.isFlow(item) ? item : null
    if (!src || root.flowIndexOf(src) <= 0) return false
    const st = root._flowState(src)
    const visited = Array.isArray(st.visited) ? st.visited : []
    let prev = visited.length > 1 ? visited[visited.length - 2] : root.flowIndexOf(src) - 1
    if (!Number.isInteger(prev) || prev < 0) prev = root.flowIndexOf(src) - 1
    // A revisited step clears everything after it.
    const keep = {}
    for (const k in st.values) if (Number(k) < prev) keep[k] = st.values[k]
    st.values = keep
    st.visited = visited.filter(i => i < prev).concat([prev])
    st.index = prev
    st.ready = false
    st.draft = { set: false, value: null }
    if (!root.isExpanded(src)) root.setExpanded(src, true)
    root.rev++
    _focusEditor(ctx)
    return true
  }

  function rowFlowCommit(ctx) {
    const item = ctx && ctx.item ? ctx.item : null
    const src = item && MenuLib.isFlow(item) ? item : null
    if (!src) return false
    const st = root._flowState(src)
    if (st.ready !== true) return false
    for (let i = 0; i < (st.visited || []).length; i++) {
      const step = MenuLib.flowStep(src, Number(st.visited[i]))
      if (step && step.required && String(st.values[String(st.visited[i])] ?? "").trim() === "")
        return false
    }
    const vals = Object.assign({}, st.values)
    const draft = st.draft
    if (draft && draft.set === true) vals[String(root.flowIndexOf(src))] = draft.value
    st.draft = { set: false, value: null }
    root.rev++
    const last = Array.isArray(st.visited) && st.visited.length > 0
      ? st.visited[st.visited.length - 1] : MenuLib.flowCount(src) - 1
    const text = vals[String(last)] !== undefined ? String(vals[String(last)]) : ""
    const handled = root.handleFlow(src, vals)
    root._collapseRow(src, ctx)
    if (handled) return true
    const shell = function (template) {
      if (ctx && ctx.origin === "ipc" && MenuIpc.safeShellTemplate(template))
        root.runCommand(MenuIpc.quoteShellValue(template, text), "")
      else root.runCommand(template, text)
    }
    if (item.onCall !== "") root.runCall(item.onCall, text)
    else if (item.onSelect !== "") shell(item.onSelect)
    else if (item.onChange !== "") shell(item.onChange)
    else if (item.editCall !== "") root.runCall(item.editCall, text)
    else if (item.onSubmit !== "") shell(item.onSubmit)
    if (item.close === true) root.close()
    return true
  }

  function rowFlowCancel(ctx) {
    const item = ctx && ctx.item ? ctx.item : null
    if (!item) return false
    root.resetFlow(item)
    root._collapseRow(item, ctx)
    return true
  }

  // --- shared confirmation and deletion ------------------------------------

  function rowConfirm(item, kind, ctx) {
    if (!item) return false
    const descriptor = kind === "delete"
      ? (root._deleteConfirmFor ? root._deleteConfirmFor(item) : null)
      : root.confirmFor(item)
    if (!descriptor) return false
    if (kind === "activate" && descriptor.action === "clearHistory"
      && Registry.get("appLauncher", "hasUsageHistory") === false) return false
    const st = root.stateOf(item)
    const activeKind = String(st.confirmKind || "")
    const stages = Number(descriptor.stages) || 1
    let stage = Number(st.confirmStage) || 0
    if (activeKind !== kind) { stage = 1; root._setRowState(item, { confirmKind: kind, confirmStage: 1 }) }
    else if (stage === 0) { stage = 1; root._setRowState(item, { confirmStage: 1 }) }
    else if (stage < stages) { stage++; root._setRowState(item, { confirmStage: stage }) }
    else {
      // Clear before dispatch so a re-entrant command cannot re-arm it.
      root._setRowState(item, { confirmKind: "", confirmStage: 0 })
      root._collapseRow(item, ctx)
      if (kind === "delete") root._runDelete(item)
      else if (!root.handleConfirm(item)) {
        if (item.confirm && typeof item.confirm.command === "string" && item.confirm.command !== "")
          root.runCommand(item.confirm.command, "")
      }
      if (item.close === true) root.close()
      return true
    }
    if (!root.isExpanded(item)) root.setExpanded(item, true)
    return true
  }

  function _runDelete(item) {
    const dc = String(item.delCommand ?? "")
    if (dc === "") return
    const value = item.value !== undefined ? String(item.value) : ""
    if (dc === "@forget") {
      const api = root.frame ? root.dynamicApi(root.frame.id) : null
      if (api && typeof api.forget === "function") api.forget(value)
    } else root.runCommand(dc, value)
  }

  function _deleteConfirmFor(item) {
    if (!item || typeof item.delCommand !== "string" || item.delCommand === "") return null
    return {
      stages: 2,
      hint: "Press Delete again to remove " + String(item.label ?? "this item"),
      armed: "<b><u>Press Delete again to confirm removal</u></b>",
      label: "Remove " + String(item.label ?? "item")
    }
  }

  // Grid deletion has no delegate: one direct forget, as before.
  function rowDelete(item, ctx) {
    if (!item || typeof item.delCommand !== "string" || item.delCommand === "") return false
    if (ctx && ctx.view === "grid") {
      root._runDelete(item)
      return true
    }
    return root.rowConfirm(item, "delete", ctx)
  }

  function rowConfirmStatus(item) {
    const st = root.stateOf(item)
    const kind = String(st.confirmKind || "")
    const descriptor = kind === "delete" ? root._deleteConfirmFor(item) : root.confirmFor(item)
    return MenuIpc.confirmStatus(kind, st.confirmStage, descriptor)
  }

  function rowConfirmCancel(item, ctx) {
    if (!item) return false
    root._setRowState(item, { confirmKind: "", confirmStage: 0 })
    root._collapseRow(item, ctx)
    return true
  }

  // --- one activation entry point ------------------------------------------

  function rowActivate(item, ctx) {
    if (!item || !root.rowCanOperate(item, ctx && ctx.ancestors)) return false
    const _wasFiltered = root._actionWasFiltered()
    const callCtx = ctx || {}
    try {
      if (MenuLib.isFlow(item)) {
        root.setExpanded(item, true)
        return true
      }
      const kind = root.confirmKindOf(item)
      if (kind !== "" || root.confirmFor(item)) {
        return root.rowConfirm(item, "activate", callCtx)
      }
      switch (item.type) {
      case "submenu":
        root.rowOpen(item, callCtx)
        return true
      case "toggle":
        root.rowSetToggle(item, !root.isToggleOn(item), callCtx)
        if (item.close === true) root.close()
        return true
      case "action":
        if (callCtx.view === "grid") root.rowRunAction(item, callCtx)
        else root.rowRunAction(item, callCtx)
        return true
      case "select":
        if (!root.rowCanOperate(item, (callCtx.ancestors || []))) return false
        root.rowSetExpanded(item, !root.isExpanded(item), callCtx)
        return true
      case "option":
        root.rowChoose(item, item.value, callCtx)
        return true
      case "number":
      case "range":
      case "text":
        root.rowOpen(item, callCtx)
        return true
      case "group":
      case "expandable":
        if (!item.infoOnly && callCtx.emptyBody !== true)
          root.rowSetExpanded(item, !root.isExpanded(item), callCtx)
        return true
      case "result":
        if (callCtx.consumeResult && typeof callCtx.consumeResult === "function") callCtx.consumeResult()
        else {
          const panel = root.panel || root.probeSource
          if (panel && typeof panel.consumePendingResult === "function") {
            panel.pendingResult = item
            Qt.callLater(panel.consumePendingResult)
          } else root.jumpTo(item.pageId, item.row)
        }
        return true
      }
      return false
    } finally {
      if (_wasFiltered) root._clearActionFilter(item)
    }
  }

  // Run a command template through bash; %v substitutes with `value`.
  function runCommand(template, value) {
    const cmd = MenuLib.substitute(template, value)
    if (cmd.trim() === "") return
    Log.trace("menu", root.tag, "select " + cmd)
    Log.info(root.tag, "exec: " + cmd)
    const proc = procComponent.createObject(root, {
      command: ["/bin/bash", "-c", cmd]
    })
    proc.exited.connect(proc.destroy)
    proc.running = true
  }

  // Run an internal API call spec: "<target> <method> [args...]" with %v
  // substitution in the args. Resolved through the Registry hub - no
  // shell spawn, no external `qs ipc call` round-trip.
  function runCall(spec, value) {
    const parts = String(spec ?? "").trim().split(/\s+/).filter(p => p !== "")
    if (parts.length < 2) return
    const args = []
    for (let i = 2; i < parts.length; i++)
      args.push(MenuLib.substitute(parts[i], value))
    Log.trace("menu", root.tag, "call " + parts[0] + "." + parts[1])
    Log.info(root.tag, "call: " + parts[0] + "." + parts[1])
    Registry.call(parts[0], parts[1], ...args)
  }

  // --- public model gateway ------------------------------------------------
  // MenuIpc is a pure projection/guard library; this owner supplies runtime
  // state, claims, page/provider data and the router frames. No command below
  // synthesises a key event, polls a delegate or evaluates caller-supplied
  // shell source.

  function _ok(data) { return data === undefined ? MenuIpc.silent() : MenuIpc.ok(data) }
  function _err(code, message) { return MenuIpc.fail(code, message === undefined ? code : message) }

  function _pendingQuery() {
    // A generation counter is not a pending flag: it grows with every guard
    // batch. Only a deferred provider, a debounced scoped projection or an
    // in-flight query can make a result view unreliable for a write.
    return root._ipcProviderPending === true
      || (root._scopedPending !== undefined && root._scopedPending !== "")
      || root._applyingQuery === true
  }

  function _scope() {
    return MenuIpc.scopeOf(root.query !== "", root.scopedActive && root.scopedQuery !== "")
  }

  function _closedFrame() {
    return MenuIpc.ok(MenuIpc.closedSnapshot(root.rev))
  }

  function _currentFrame(withBundle) {
    if (!root.open) return _closedFrame()
    const panel = root.panel || root.probeSource
    const data = {
      open: true,
      page: root.pageId,
      depth: root.stack.length,
      scope: root._scope(),
      revision: root.rev,
      row: null,
      pending: root._pendingQuery() || (panel && panel._settlePending === true) || false
    }
    if (withBundle) {
      data.bundleEntry = root.bundle && root.bundle.entry ? String(root.bundle.entry) : ""
      data.guardsPending = root._pendingQuery()
    }
    // A protected page is visible as a page frame but publishes no rows.
    const rows = MenuIpc.isProtectedPage(root.pageId) ? [] : root._currentRows()
    if (rows.length > 0) data.row = rows[0]
    return MenuIpc.ok(data)
  }

  function ipcStatus() { return _currentFrame(true) }
  function ipcCurrent() { return _currentFrame(false) }

  // --- page tree and references -------------------------------------------

  function _pageOrdinalFor(page) {
    if (!page || typeof page.id !== "string") return null
    const rec = root._refPages[page.id]
    if (rec && rec.page === page) return rec
    const next = {
      page: page,
      ordinal: ++root._pageOrdinalSeq,
      rows: Object.create(null)
    }
    const all = Object.assign({}, root._refPages)
    all[page.id] = next
    root._refPages = all
    return next
  }

  function _mintRowRef(item, page, ancestors, searchHit) {
    if (!item || !item.uid || !page) return null
    const rec = root._pageOrdinalFor(page)
    if (!rec) return null
    let row = rec.rows[item.uid]
    if (!row || row.item !== item || (searchHit === true && row.search !== true)) {
      row = { ordinal: ++root._rowOrdinalSeq, item: item, search: searchHit === true,
        ancestors: (ancestors || []).slice() }
      rec.rows[item.uid] = row
    }
    const ref = MenuIpc.ref(IpcRouter.incarnation, root.openGeneration,
      rec.ordinal, row.ordinal)
    if (ref) {
      root._refsByValue[ref] = {
        item: item, page: page, pageId: page.id, uid: item.uid,
        ancestors: row.ancestors.slice(), ref: ref, search: searchHit === true
      }
    }
    return ref
  }

  // A re-ranked result set is a new projection: refs minted from a previous
  // query never address a hit in the new one, even when the same uid returns.
  function _retireSearchRefs() {
    const pages = Object.assign({}, root._refPages)
    for (const id in pages) {
      const rows = pages[id].rows
      for (const uid in rows) if (rows[uid].search === true) delete rows[uid]
    }
    const refs = Object.assign({}, root._refsByValue)
    for (const ref in refs) if (refs[ref].search === true) delete root._refsByValue[ref]
  }

  function _resolveRef(ref) {
    if (typeof ref !== "string" || ref === "") return { error: "stale" }
    const parsed = MenuIpc.refMatches(ref, IpcRouter.incarnation, root.openGeneration)
    if (!parsed) return { error: "stale" }
    const entry = root._refsByValue[ref]
    if (!entry) return { error: "stale" }
    const page = root.pageById(entry.pageId)
    const item = entry.search === true ? entry.item : root.itemByUid(entry.uid)
    if (!page || page !== entry.page || !item || item !== entry.item)
      return { error: "stale" }
    if (entry.search !== true) for (let i = 0; i < entry.ancestors.length; i++) {
      const a = entry.ancestors[i]
      if (root.itemByUid(a.uid) !== a) return { error: "stale" }
    }
    // A protected row is still discoverable: reads redact it, writes refuse.
    return {
      item: item, page: page, pageId: entry.pageId,
      ancestors: entry.ancestors, ref: ref, entry: entry,
      protected: MenuIpc.isProtectedRow(item, page,
        MenuLib.isFlow(item) ? MenuLib.flowStep(item, root.flowIndexOf(item)) : null)
    }
  }

  function _walkPage(page, visit, ancestors, depth) {
    if (!page || !Array.isArray(page.items)) return
    const parent = ancestors || []
    for (let i = 0; i < page.items.length; i++) {
      const it = page.items[i]
      if (!it) continue
      visit(it, parent, depth || 0, page)
      if (Array.isArray(it.children) && it.children.length > 0)
        root._walkChildren(it.children, visit, parent.concat([it]), (depth || 0) + 1, page)
    }
  }

  function _walkChildren(list, visit, ancestors, depth, page) {
    for (let i = 0; i < list.length; i++) {
      const it = list[i]
      if (!it) continue
      visit(it, ancestors, depth, page)
      if (Array.isArray(it.children) && it.children.length > 0)
        root._walkChildren(it.children, visit, ancestors.concat([it]), depth + 1, page)
    }
  }

  function _locate(uid) {
    if (!uid) return null
    const pages = []
    if (root.bundle && root.bundle.pages) pages.push.apply(pages, root.bundle.pages)
    for (const id in root._dynamicPages) pages.push(root._dynamicPages[id])
    for (const id in root._optionPages) pages.push(root._optionPages[id])
    for (let i = 0; i < pages.length; i++) {
      let found = null
      root._walkPage(pages[i], function (it, ancestors, depth, page) {
        if (!found && it.uid === uid) found = { item: it, ancestors: ancestors.slice(), page: page, depth: depth }
      }, [], 0)
      if (found) return found
    }
    return null
  }

  function _rowActions(item) {
    const out = []
    const keys = ["activate", "open", "close", "toggle", "set", "step", "options",
      "choose", "info", "confirm", "flow", "delete"]
    for (let i = 0; i < keys.length; i++) {
      if (MenuIpc.supports(item.type, keys[i])) out.push(keys[i])
    }
    if (typeof item.delCommand === "string" && item.delCommand !== "" && out.indexOf("delete") < 0)
      out.push("delete")
    if (MenuLib.isFlow(item) && out.indexOf("flow") < 0) out.push("flow")
    return out
  }

  function _rowRecord(item, page, ancestors, depth, ref, searchProxy) {
    const state = root.stateOf(item)
    const parent = ancestors && ancestors.length > 0
      ? root._mintRowRef(ancestors[ancestors.length - 1], page, ancestors.slice(0, -1)) : null
    const protectedRow = MenuIpc.isProtectedRow(item, page)
    return MenuIpc.rowRecord({
      ref: ref, uid: item.uid, id: item.id, page: page ? page.id : root.pageId,
      parent: parent, depth: depth || 0, type: searchProxy ? "result" : item.type,
      label: item.label, available: root.rowCanOperate(item, ancestors),
      expanded: state.expanded === true, actions: protectedRow ? [] : root._rowActions(item),
      protected: protectedRow
    })
  }

  function _currentRows() {
    if (!root.open) return []
    const panel = root.panel || root.probeSource
    const out = []
    const seen = Object.create(null)
    const emit = function (item, page, ancestors, depth, proxy) {
      if (!item || !root.isListed(item)) return
      const ref = root._mintRowRef(item, page, ancestors, proxy === true)
      const rec = root._rowRecord(item, page, ancestors, depth, ref, proxy)
      out.push(rec)
      seen[item.uid] = true
      // Expanded children are appended in displayed order, using the same
      // group child filter Entry uses.
      if (!proxy && root.isExpanded(item) && Array.isArray(item.children)) {
        const kids = root._groupChildFilter ? root._groupChildFilter(item) : item.children
        for (let i = 0; i < kids.length; i++) {
          if (kids[i]) emit(kids[i], page, (ancestors || []).concat([item]), (depth || 0) + 1, false)
        }
      }
    }
    if (panel && Array.isArray(panel.rowsModel) && panel.rowsModel.length > 0) {
      for (let i = 0; i < panel.rowsModel.length; i++) {
        const row = panel.rowsModel[i]
        if (!row) continue
        if (row.scopedResult || row.searchResult || row.type === "result") {
          emit(row, root.pageById(root.pageId), [], 0, true)
          continue
        }
        const loc = root._locate(row.uid)
        if (!loc) continue
        emit(loc.item, loc.page, loc.ancestors, loc.depth, false)
      }
      return out
    }
    // Without a mounted panel the ranked window is the only rendered view;
    // project it as result proxies, the same rows a panel would install.
    if (root.query !== "" && Array.isArray(root.results) && root.results.length > 0) {
      for (let i = 0; i < root.results.length; i++) {
        const hit = root.results[i]
        if (MenuIpc.isProtectedPage(hit.pageId)) continue
        const pg = root.pageById(hit.pageId)
        const it = pg && Array.isArray(pg.items) ? pg.items[Number(hit.row)] : null
        if (it) emit(it, pg, [], 0, true)
      }
      return out
    }
    const page = root.pageById(root.pageId)
    if (!page) return out
    root._walkPage(page, function (it, ancestors, depth, pg) {
      emit(it, pg, ancestors, depth, false)
    }, [], 0)
    return out
  }

  function ipcList(pageId) {
    if (!root.open) {
      return MenuIpc.fail("unavailable", "menu is closed")
    }
    if (pageId !== undefined && pageId !== null && pageId !== "") {
      const page = root.pageById(String(pageId))
      if (!page) return MenuIpc.fail("not-found", "no such page")
      if (MenuIpc.isProtectedPage(String(pageId)))
        return MenuIpc.fail("unsupported", "protected page")
      const out = []
      root._walkPage(page, function (it, ancestors, depth, pg) {
        out.push(root._rowRecord(it, pg, ancestors, depth,
          root._mintRowRef(it, pg, ancestors), false))
      }, [], 0)
      return MenuIpc.ok(out)
    }
    if (MenuIpc.isProtectedPage(root.pageId)) return MenuIpc.ok([])
    return MenuIpc.ok(root._currentRows())
  }

  function ipcPages() {
    if (!root.open) return MenuIpc.ok([])
    const out = []
    const seen = Object.create(null)
    const add = function (id, reachable) {
      if (typeof id !== "string" || id === "" || seen[id] === true) return
      const page = root.pageById(id)
      if (!page) return
      if (MenuIpc.isProtectedPage(id)) { seen[id] = true; return }
      if (page.items === undefined && root._dynamicPages[id] === undefined) return
      seen[id] = true
      out.push({
        id: id, title: String(page.title ?? id),
        layout: root._gridPage(id) ? "grid" : "list",
        reachable: reachable === true
      })
      const items = Array.isArray(page.items) ? page.items : []
      for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (it && it.type === "submenu" && typeof it.page === "string") add(it.page, true)
      }
    }
    add(root.pageId, false)
    if (root.bundle) add(root.bundle.entry, false)
    for (let i = 0; i < root.stack.length; i++) add(root.stack[i].id, false)
    return MenuIpc.ok(out)
  }

  function _gridPage(id) {
    const page = root.pageById(id)
    return !!(page && (page.grid === true || page.layout === "grid"))
  }

  // Shortest allowed link path; a blocked link is never a path.
  function _linkPath(from, to) {
    if (!from || !to || from === to) return []
    const queue = [[from, []]]
    const seen = Object.create(null)
    seen[from] = true
    while (queue.length > 0) {
      const cur = queue.shift()
      const page = root.pageById(cur[0])
      if (!page) continue
      const items = Array.isArray(page.items) ? page.items : []
      for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (!it || it.type !== "submenu" || typeof it.page !== "string") continue
        const next = it.page
        if (seen[next] === true) continue
        if (!root.rowCanOperate(it, [])) continue
        seen[next] = true
        const path = cur[1].concat([next])
        if (next === to) return path
        queue.push([next, path])
      }
    }
    return null
  }

  function ipcGo(pageId) {
    if (!root.open) return MenuIpc.fail("unavailable", "menu is closed")
    const target = String(pageId ?? "")
    if (!root.pageById(target)) return MenuIpc.fail("not-found", "no such page")
    if (MenuIpc.isProtectedPage(target)) return MenuIpc.fail("unsupported", "protected page")
    if (target === root.pageId) return MenuIpc.ok({ page: root.pageId, depth: root.stack.length })
    // A frame on the real stack pops back without a new push/checkpoint.
    const at = root.stack.map(f => f.id).indexOf(target)
    if (at >= 0) {
      while (root.stack.length > at + 1) root.pop()
      return MenuIpc.ok({ page: root.pageId, depth: root.stack.length })
    }
    const fromCurrent = root._linkPath(root.pageId, target)
    const fromEntry = root.bundle ? root._linkPath(root.bundle.entry, target) : null
    let chain = fromCurrent
    if (!chain || (fromEntry && fromEntry.length < chain.length)) chain = fromEntry
    if (!chain || chain.length === 0) return MenuIpc.fail("refused", "no allowed link path")
    const panel = root.panel || root.probeSource
    if (panel && typeof panel.pushPage === "function") {
      for (let i = 0; i < chain.length; i++) panel.pushPage(chain[i])
    } else {
      for (let i = 0; i < chain.length; i++) root.push(chain[i])
    }
    return MenuIpc.ok({ page: root.pageId, depth: root.stack.length })
  }

  function ipcBack() {
    if (!root.open) return _ok({ open: false, page: null })
    root.back()
    return MenuIpc.ok({ open: root.open, page: root.pageId })
  }

  // --- selection and search ------------------------------------------------

  function ipcSelect(ref) {
    if (!root.open) return MenuIpc.fail("unavailable", "menu is closed")
    const found = root._resolveRef(ref)
    if (found.error) return MenuIpc.fail(found.error, "row reference")
    const panel = root.panel || root.probeSource
    if (!panel) return MenuIpc.fail("unavailable", "no visible panel")
    // Expand the verified ancestor chain, then seat by uid through the panel.
    root.setExpandedBatch(found.ancestors, true)
    if (typeof panel.applyModelSelection === "function") {
      const okSeat = panel.applyModelSelection(found.item, found.page, found.ancestors)
      if (okSeat === false) return MenuIpc.fail("unavailable", "row not in view")
    } else {
      const idx = panel.indexOfUid(found.item.uid)
      if (idx < 0 || !panel.focusIndex(idx)) return MenuIpc.fail("unavailable", "row not in view")
    }
    root._landingIntent = { ref: ref, uid: found.item.uid, rev: root.rev }
    return MenuIpc.silent()
  }

  function ipcSearch(kind, query) {
    if (!root.open) return MenuIpc.fail("unavailable", "menu is closed")
    if (kind === "clear") {
      if (root.scopedActive) root.clearScoped()
      if (root.query !== "") root.clearQuery()
      return MenuIpc.ok({ scope: "none", pending: root._pendingQuery() })
    }
    const text = String(query ?? "")
    const page = root.pageById(root.pageId)
    if (kind === "global") {
      if (root._dynamicPages[root.pageId] !== undefined && page && page.searchGlobal !== true)
        return MenuIpc.fail("unsupported", "page has no global search")
      root.setQuery(text)
      return MenuIpc.ok({ scope: "global", pending: root._pendingQuery() })
    }
    if (kind === "scoped") {
      if (!root.scopedActive) root.beginScoped()
      root.setScopedQuery(text)
      return MenuIpc.ok({ scope: "scoped", pending: root._pendingQuery() })
    }
    return MenuIpc.fail("unsupported", "unknown search mode")
  }

  // --- bundle open/toggle/close -------------------------------------------

  function _readSource(spec) {
    if (spec && typeof spec === "object" && spec.inline === true) {
      return { text: String(spec.text), path: "", frag: String(spec.frag || "") }
    }
    const raw = String(spec && spec.path ? spec.path : spec ?? "")
    const hash = raw.indexOf("#")
    const path = hash < 0 ? raw : raw.substring(0, hash)
    const frag = hash < 0 ? "" : raw.substring(hash + 1)
    if (path === "") return null
    loader.path = ""
    loader.path = path
    if (!loader.waitForJob()) return null
    root._registerLazySearch(loader.text(), path)
    return { text: loader.text(), path: path, frag: frag }
  }

  function _prepareOpen(spec) {
    if (!spec) return null
    const src = root._readSource(spec)
    if (!src) return null
    const frag = src.frag
    if (frag !== "" && !spec.inline) {
      // Validate the fragment against the parsed bundle before closing the
      // old one; an explicitly requested unknown entry is not a silent fall
      // back to the default page.
      const probe = MenuLib.parseBundle(src.text)
      if (!probe.byId || probe.byId[frag] === undefined) return null
    }
    extensionLoader.path = ""
    extensionLoader.path = Paths.configHome + "/vibranium/user-menu.jsonc"
    const extText = extensionLoader.waitForJob() ? extensionLoader.text() : ""
    let candidate
    try {
      candidate = root._assembleContainers(src.text, extText, src.path, frag)
    } catch (e) {
      return null
    }
    const entry = frag !== "" ? frag : candidate.bundle.entry
    if (!candidate.byId || candidate.byId[entry] === undefined) return null
    return {
      candidate: candidate,
      source: src,
      entry: entry,
      identity: src.path !== "" ? src.path + "#" + entry
        : "inline:" + src.text + (frag !== "" ? "#" + frag : "")
    }
  }

  function _installPrepared(prepared) {
    root._installContainers(prepared.candidate)
    root._lastPath = prepared.source.path + (prepared.source.frag !== ""
      ? "#" + prepared.source.frag : "")
    root._lastInline = prepared.source.path === "" ? prepared.source.text : ""
    root._primeRuntime(prepared.candidate.bundle)
    if (prepared.candidate.byId[prepared.entry] !== undefined)
      root.stack = [{ id: prepared.entry, sel: 0, y: 0 }]
    root._claimToken = SurfaceClaim.claim("menu", root.close, root)
    Qt.callLater(root.evaluateGuards)
    return MenuIpc.ok({ open: true, page: root.pageId })
  }

  function _currentIdentity() {
    if (!root.open) return ""
    if (root._lastInline !== "" && root._lastPath === "") return "inline:" + root._lastInline
    if (root._lastPath === undefined || root._lastPath === "") return ""
    const canonical = root._canonicalSource(root._lastPath)
    return canonical + "#" + root.pageId
  }

  function ipcOpen(spec) {
    const prepared = root._prepareOpen(spec)
    if (!prepared) return MenuIpc.fail("not-found", "bundle could not be prepared")
    if (root.open && root._currentIdentity() === prepared.identity)
      return MenuIpc.ok({ open: true, page: root.pageId })
    if (root.open) root.close()
    return root._installPrepared(prepared)
  }

  function ipcToggle(spec) {
    const prepared = root._prepareOpen(spec)
    if (!prepared) return MenuIpc.fail("not-found", "bundle could not be prepared")
    if (root.open && root._currentIdentity() === prepared.identity) {
      root.close()
      return MenuIpc.ok({ open: false, page: null })
    }
    if (root.open) root.close()
    return root._installPrepared(prepared)
  }

  function ipcClose() {
    root.close()
    return MenuIpc.ok({ open: false, page: null })
  }

  // --- item operations -----------------------------------------------------

  function _itemPayload(found) {
    const item = found.item
    const page = found.page
    const st = root.stateOf(item)
    const state = {
      value: root.rowCanOperate(item, found.ancestors) ? st.value : undefined,
      checked: st.checked, info: st.info,
      confirmStage: Number(st.confirmStage) || 0
    }
    const flowItem = MenuLib.isFlow(item) ? item : null
    let flow = null
    if (flowItem) {
      const fs = root._flowState(flowItem)
      flow = {
        active: root.isExpanded(item), index: Number(fs.index) || 0,
        visited: (fs.visited || []).slice(), ready: fs.ready === true,
        values: Object.assign({}, fs.values),
        kind: String((MenuLib.flowStep(flowItem, Number(fs.index) || 0) || {}).kind || "")
      }
    }
    const protectedRow = MenuIpc.isProtectedRow(item, page)
    return MenuIpc.itemDetail({
      ref: found.ref, uid: item.uid, id: item.id, page: page.id,
      parent: found.ancestors.length > 0 ? root._mintRowRef(
        found.ancestors[found.ancestors.length - 1], page, found.ancestors.slice(0, -1)) : null,
      depth: found.ancestors.length, type: item.type, label: item.label,
      available: root.rowCanOperate(item, found.ancestors),
      expanded: st.expanded === true,
      actions: root._rowActions(item),
      protected: protectedRow, item: item, state: state,
      selected: root.optionIsChosen(item),
      options: MenuIpc.optionsProjection(item.options || [], st.value, protectedRow),
      confirm: root.confirmFor(item),
      flow: flow,
      min: item.min, max: item.max, step: item.step
    })
  }

  function _itemContext(found, view) {
    return {
      pageId: found.pageId, view: view || "list", origin: "ipc",
      item: found.item, ancestors: found.ancestors,
      numeric: root._numericFor(found.item)
    }
  }

  function _writableItem(found, view) {
    if (!root.open) return MenuIpc.fail("unavailable", "menu is closed")
    if (found.error) return MenuIpc.fail(found.error, "row reference")
    if (root._pendingQuery()) return MenuIpc.fail("busy", "search pending")
    if (found.protected === true) return MenuIpc.fail("unsupported", "protected row")
    if (found.pageId !== root.pageId && view !== "result")
      return MenuIpc.fail("refused", "row is not on the active page")
    if (!root.rowCanOperate(found.item, found.ancestors))
      return MenuIpc.fail("refused", "row is blocked")
    return null
  }

  function ipcItemGet(ref) {
    const found = root._resolveRef(ref)
    if (found.error) return MenuIpc.fail(found.error, "row reference")
    return MenuIpc.ok(root._itemPayload(found))
  }

  function ipcItem(ref, op, opts) {
    const arg = opts && typeof opts === "object" && !Array.isArray(opts) ? opts.value : opts
    if (op === "get") return root.ipcItemGet(ref)
    let found = root._resolveRef(ref)
    let searchProxy = false
    if (found.error && root.query !== "") {
      // A current search result may only be activated, through the existing
      // pending-result landing path. Never mutate a search proxy.
      const panel = root.panel || root.probeSource
      const rows = panel && Array.isArray(panel.rowsModel) ? panel.rowsModel : []
      const hit = rows.find(r => r && r.ref === ref)
      if (hit && op === "activate") {
        found = { item: hit, page: root.pageById(hit.page), pageId: hit.page,
          ancestors: [], ref: ref }
        searchProxy = true
      }
    }
    const denied = root._writableItem(found, searchProxy ? "result" : "list")
    if (denied) return denied
    const item = found.item
    const ctx = root._itemContext(found)
    const protectedRow = MenuIpc.isProtectedRow(item, found.page)
    if (protectedRow && op !== "get")
      return MenuIpc.fail("unsupported", "protected row")
    const isFlowRow = MenuLib.isFlow(item)
    const kindError = MenuIpc.operationError(searchProxy ? "result" : item.type, op)
    if (kindError && !(op === "action" && item.type === "action")
      && !(op === "set" && isFlowRow)
      && !(isFlowRow && (op === "open" || op === "activate" || op === "close")))
      return MenuIpc.fail(kindError, "operation not allowed for row type")

    switch (op) {
    case "activate":
      if (searchProxy) {
        const panel = root.panel || root.probeSource
        if (!panel || typeof panel.consumePendingResult !== "function")
          return MenuIpc.fail("unavailable", "no result handoff")
        panel.pendingResult = item
        Qt.callLater(panel.consumePendingResult)
        return MenuIpc.silent()
      }
      root.rowActivate(item, ctx)
      return MenuIpc.silent()
    case "open":
      if (isFlowRow) {
        root.setExpanded(item, true)
        return MenuIpc.ok({ open: true, page: root.pageId })
      }
      if (item.type === "submenu") {
        const panel = root.panel || root.probeSource
        if (panel && typeof panel.pushPage === "function") panel.pushPage(item.page)
        else root.push(item.page)
        return MenuIpc.ok({ page: root.pageId })
      }
      root.rowOpen(item, ctx)
      return MenuIpc.ok({ open: root.isExpanded(item), page: root.pageId })
    case "close":
      root.rowClose(item, ctx)
      return MenuIpc.ok({ open: root.isExpanded(item), page: root.pageId })
    case "toggle":
      if (!root.rowSetToggle(item, !root.isToggleOn(item), ctx)) return MenuIpc.fail("refused", "toggle was not applied")
      return MenuIpc.ok({ value: root.isToggleOn(item) })
    case "set": {
      const value = arg
      if (MenuLib.isFlow(item)) {
        const step = Number(flowIndexOf(item)) || 0
        if (!root.rowFlowSet(step, value, ctx)) return MenuIpc.fail("refused", "flow step")
        return MenuIpc.silent()
      }
      if (item.type === "select") {
        if (root.stateOf(item).promptOpen !== true)
          return MenuIpc.fail("refused", "select is not in edit mode")
        if (typeof value !== "string") return MenuIpc.fail("invalid-argument", "edit prompt wants a string")
        if (!root.rowCommitEdit(item, value, ctx)) return MenuIpc.fail("refused", "edit was not applied")
        return MenuIpc.ok({ value: root.valueOf(item) })
      }
      const bad = MenuIpc.valueError(item, value)
      if (bad) return MenuIpc.fail(bad, "wrong value type")
      if (item.type === "toggle") {
        if (!root.rowSetToggle(item, value === true, ctx)) return MenuIpc.fail("refused", "toggle was not applied")
        return MenuIpc.ok({ value: root.isToggleOn(item) })
      }
      if (!root.rowCommitEdit(item, value, ctx)) return MenuIpc.fail("refused", "edit was not applied")
      return MenuIpc.ok({ value: root.valueOf(item) })
    }
    case "step": {
      const up = String(opts && opts.direction ? opts.direction : (arg || "up")).toLowerCase()
      if (up !== "up" && up !== "down") return MenuIpc.fail("invalid-argument", "step wants up or down")
      root.rowStep(item, up === "up" ? 1 : -1, ctx)
      return MenuIpc.ok({ value: root.valueOf(item) })
    }
    case "options":
      return MenuIpc.ok(MenuIpc.optionsProjection(item.options || [], root.stateOf(item).value,
        MenuIpc.isProtectedRow(item, found.page)))
    case "choose": {
      const idx = MenuIpc.optionIndex(String(opts && opts.option !== undefined ? opts.option : arg))
      const options = MenuIpc.optionsProjection(item.options || [], root.stateOf(item).value, false)
      if (idx < 0 || idx >= options.length) return MenuIpc.fail("not-found", "no such option")
      const opt = options[idx]
      if (!opt.enabled) return MenuIpc.fail("refused", "option is disabled")
      if (!root.rowChoose(item, root._rawOptions(item)[idx].value, ctx))
        return MenuIpc.fail("refused", "option was not applied")
      return MenuIpc.ok({ value: root.valueOf(item) })
    }
    case "info": {
      const value = String(opts && opts.mode !== undefined ? opts.mode : (arg || "")) === "open"
      const has = String(item.desc ?? "") !== "" || String(item.warning ?? "") !== ""
      if (value && !has && !root.isExpanded(item))
        return MenuIpc.fail("unsupported", "row has no description")
      root.rowSetInfo(item, value, ctx)
      return MenuIpc.ok({ open: root.infoOpen(item) })
    }
    case "confirm":
      return root.ipcItemConfirm(found,
        String(opts && opts.verb !== undefined ? opts.verb : (arg || "status")), ctx)
    case "flow":
      return root.ipcItemFlow(found,
        String(opts && opts.verb !== undefined ? opts.verb : (arg || "")), ctx, opts || {})
    case "delete":
      root.rowDelete(item, ctx)
      return MenuIpc.silent()
    case "action":
      root.rowRunAction(item, ctx)
      return MenuIpc.silent()
    }
    return MenuIpc.fail("unsupported", "unknown item operation")
  }

  function _rawOptions(item) {
    const stage = MenuLib.isFlow(item) ? MenuLib.flowStep(item, flowIndexOf(item)) : null
    const declared = stage && stage.options !== undefined ? stage.options : item.options
    if (Array.isArray(declared)) return declared
    return declared && declared.length !== undefined ? Array.prototype.slice.call(declared) : []
  }

  function ipcItemConfirm(found, verb, ctx) {
    const item = found.item
    if (verb === "status") return MenuIpc.ok(root.rowConfirmStatus(item))
    if (verb === "next") {
      const kind = root.confirmKindOf(item)
      if (kind === "") return MenuIpc.fail("refused", "no active confirmation")
      if (!root.rowConfirm(item, kind, ctx)) return MenuIpc.fail("refused", "no confirmation")
      return MenuIpc.ok(root.rowConfirmStatus(item))
    }
    if (verb === "cancel") {
      root.rowConfirmCancel(item, ctx)
      return MenuIpc.ok(root.rowConfirmStatus(item))
    }
    return MenuIpc.fail("unsupported", "unknown confirmation verb")
  }

  function ipcItemFlow(found, verb, ctx, opts) {
    const item = found.item
    if (!MenuLib.isFlow(item)) return MenuIpc.fail("unsupported", "row has no flow")
    const fs = root._flowState(item)
    const status = function () {
      return MenuIpc.ok(MenuIpc.flowStatus({
        active: root.isExpanded(item), index: Number(fs.index) || 0,
        values: fs.values, ready: fs.ready === true
      }, String((MenuLib.flowStep(item, Number(fs.index) || 0) || {}).kind || ""),
        MenuIpc.isProtectedRow(item, found.page)))
    }
    if (verb === "status") return status()
    if (verb === "set") {
      const step = Number(opts && opts.step !== undefined ? opts.step : 0) || 0
      if (step !== flowIndexOf(item)) return MenuIpc.fail("refused", "not the current step")
      const stage = MenuLib.flowStep(item, step)
      if (!stage) return MenuIpc.fail("not-found", "no such step")
      if (stage.sensitive === true) return MenuIpc.fail("unsupported", "protected step")
      const bad = MenuIpc.valueErrorForKind(String(stage.kind || ""), opts ? opts.value : undefined)
      if (bad) return MenuIpc.fail(bad, "wrong value type")
      const value = opts ? opts.value : undefined
      if (stage.kind === "number" || stage.kind === "range") {
        const n = Number(value)
        const tooLow = stage.min !== undefined && n < Number(stage.min)
        const tooHigh = stage.max !== undefined && n > Number(stage.max)
        if (!isFinite(n) || tooLow || tooHigh)
          return MenuIpc.fail("refused", "value outside step bounds")
      }
      if (stage.kind === "select") {
        const offered = Array.isArray(stage.options) ? stage.options : []
        if (!offered.some(o => o && String(o.value) === String(value)))
          return MenuIpc.fail("refused", "value is not an offered option")
      }
      if (!root.rowFlowSet(step, value, ctx))
        return MenuIpc.fail("refused", "draft not accepted")
      return MenuIpc.silent()
    }
    if (verb === "next") {
      const draft = fs.draft && fs.draft.set === true ? fs.draft.value : undefined
      const stage = MenuLib.flowStep(item, flowIndexOf(item))
      if (stage && stage.required && String(draft ?? "").trim() === "")
        return MenuIpc.fail("refused", "required step has no value")
      const before = flowIndexOf(item)
      root.rowFlowAdvance(draft, ctx)
      if (flowIndexOf(item) === before && fs.ready !== true)
        return MenuIpc.fail("refused", "flow did not advance")
      return status()
    }
    if (verb === "back") {
      if (!root.rowFlowBack(ctx)) return MenuIpc.fail("refused", "no earlier step")
      return status()
    }
    if (verb === "commit") {
      const shellKeys = ["onSelect", "onChange", "onSubmit"]
      for (let i = 0; i < shellKeys.length; i++) {
        const template = item[shellKeys[i]]
        if (typeof template === "string" && template.indexOf("%v") >= 0
          && !MenuIpc.safeShellTemplate(template))
          return MenuIpc.fail("unsupported", "flow shell template cannot take typed text")
      }
      if (!root.rowFlowCommit(ctx)) return MenuIpc.fail("refused", "flow is not ready")
      return MenuIpc.silent()
    }
    if (verb === "cancel") {
      root.rowFlowCancel(ctx)
      return MenuIpc.ok({ active: false, step: 0, kind: "", ready: false, values: {} })
    }
    return MenuIpc.fail("unsupported", "unknown flow verb")
  }

  // --- router status -------------------------------------------------------

  function ipcOwnerStatus() {
    return MenuIpc.ok({
      open: root.open, page: root.pageId, depth: root.stack.length,
      scope: root._scope(), revision: root.rev,
      bundleEntry: root.bundle && root.bundle.entry ? String(root.bundle.entry) : "",
      guardsPending: root._pendingQuery(),
      registered: root._ipcRegistered
    })
  }

  // Injected common rows use the router's text adapter, not the gateway
  // frame path: a gateway frame here would be stringified as [object Object].
  function ipcPing() { return "pong" }

  Component {
    id: procComponent

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  // Live list the debug verbs drive. listView is the panel's alias for
  // the list renderer; the grid twin answers the same cursor contract.
  function _debugList() {
    const panel = root.probeSource
    if (!panel) return null
    if (panel.listView) return panel.listView
    if (panel.list) return panel.list
    return null
  }

  IpcHandler {
    target: "menu"
    function help(command: string): string {
      return UnitIpc.help("menu", "Menu", "Open and control menu bundles", [
        { name: "back", help: "go back one page" },
        { name: "close", help: "close the menu" },
        { name: "debugActivate", help: "activate the current row" },
        { name: "debugBeginScoped", help: "arm the in-page \"/\" filter" },
        { name: "debugMove", help: "(dir) move the cursor" },
        { name: "debugMoveOption", help: "(dir) move the current row option" },
        { name: "debugRows", help: "current page rows as JSON" },
        { name: "debugSetCurrentIdx", help: "(idx) debug: set current index" },
        { name: "debugState", help: "debug snapshot" },
        { name: "dump", help: "loaded bundle as JSON" },
        { name: "dumpRows", help: "(pageId) resolved row model as JSON" },
        { name: "open", help: "(json) open with a bundle" },
        { name: "openFile", help: "(path) load a bundle file and show its entry page" },
        { name: "toggle", help: "(json) open/close" },
        { name: "toggleFile", help: "(path) toggle a bundle file" },
      ], command)
    }
    function ping(): string { return "pong" }

    function open(json: string): string {
      return root.openJson(json) ? "ok" : "error"
    }

    function openFile(path: string): string {
      return root.openFile(path) ? "ok" : "error"
    }

    function close(): string {
      root.close()
      return "ok"
    }

    function toggle(json: string): string {
      if (root.open) { root.close(); return "ok" }
      return root.openJson(json) ? "ok" : "error"
    }

    function toggleFile(path: string): string {
      // Delegated rather than re-implemented: the root's own toggle knows the
      // page it was opened with, so the same path closes and a different one
      // switches. A local `if (open) close` here turned every cross-page
      // keybind into a close.
      return root.toggleFile(path) ? "ok" : "error"
    }

    function back(): string {
      return root.back() ? "ok" : "error"
    }

    function debugResetFlow(): string {
      root._flow = ({})
      root.rev++
      return "reset"
    }

    function debugTrace(on: string): string {
      root.traceEnabled = on === "on" || on === "1" || on === "true"
      return root.traceEnabled ? "on" : "off"
    }

    // Force motion on or off independently of the system setting.
    function debugAnims(mode: string): string {
      const on = mode === "on" || mode === "1" || mode === "true"
      MotionPolicy.debugForceOn = on
      MotionPolicy.debugDisabled = !on
      return MotionPolicy.enabled ? "on" : "off"
    }

    function restoreAnims(): string {
      MotionPolicy.debugForceOn = false
      MotionPolicy.debugDisabled = false
      return MotionPolicy.enabled ? "system-on" : "system-off"
    }

    // Frame sampler for the live live trace suite. One verb arms, one marks the
    // phase a frame belongs to, one returns the recorded ring.
    function debugDeep(on: string): string {
      const panel = root.panel
      if (!panel) return "no panel"
      return (on === "on" || on === "1" || on === "true")
        ? panel.deepStart("") : panel.deepStop()
    }

    function deepPhase(name: string): string {
      const panel = root.panel
      if (!panel) return "no panel"
      return panel.deepMark(name)
    }

    // Chunked because one IPC reply cannot carry 600 full frame records.
    function probeDeep(from: int, count: int): string {
      const panel = root.probeSource || root.panel
      const at = Math.max(0, Number(from) || 0)
      const take = Math.max(1, Math.min(Number(count) || 20, 30))
      return panel ? panel.deepFramesJson(at, take) : "[]"
    }

    // Drive literal characters through the same key route a typist uses, so
    // an open editor receives them instead of the global search field.
    function debugText(text: string): string {
      const panel = root.panel
      if (!panel) return "no panel"
      const s = String(text ?? "")
      for (let i = 0; i < s.length; i++) {
        const ch = s[i]
        const code = ch === " " ? Qt.Key_Space
          : ch >= "0" && ch <= "9" ? Qt.Key_0 + (ch.charCodeAt(0) - 48)
          : Qt.Key_A + (ch.toLowerCase().charCodeAt(0) - 97)
        panel.handleKey({ key: code, modifiers: 0, text: ch, accepted: false })
      }
      return "text " + s.length
    }

    function debugAutoMove(dir: int): string {
      const panel = root.panel
      if (!panel || typeof panel.moveSelection !== "function") return "no panel"
      panel.moveSelection(dir, true)
      return "moved " + dir
    }

    function debugChildMove(dir: int): string {
      const panel = root.panel
      if (!panel || typeof panel.moveSelection !== "function") return "no panel"
      panel.moveSelection(dir)
      return "moved " + dir
    }

    function debugActivatePanel(): string {
      const panel = root.panel
      if (!panel || typeof panel.activateCurrent !== "function") return "no panel"
      panel.activateCurrent()
      return "ok"
    }

    function debugEscape(): string {
      const panel = root.panel
      if (!panel || typeof panel.escapeChain !== "function") return "no panel"
      panel.escapeChain()
      return "ok"
    }

    function debugType(text: string): string {
      const panel = root.panel
      if (!panel) return "no panel"
      // The field's own pipeline is the one writers use: it performs the
      // idempotent assignment and emits edited(), which reaches the panel's
      // deferred publish. Writing .text behind it left the field and the
      // applied query describing two different searches.
      panel.searchField.type(String(text ?? ""))
      return "typed " + JSON.stringify(text)
    }

    function debugBeginScoped(): string {
      root.beginScoped()
      const panel = root.panel
      if (panel) panel.searchField.text = ""
      return "scoped"
    }

    function debugSetQuery(q: string): string {
      const text = String(q ?? "")
      const panel = root.panel
      if (panel) panel.searchField.type(text)
      else root.setQuery(text)
      return "query=" + text
    }

    function debugInfo(): string {
      const panel = root.panel
      if (!panel || typeof panel.toggleInfoCurrent !== "function") return "no panel"
      panel.toggleInfoCurrent()
      return "ok"
    }

    function debugKey(name: string): string {
      const panel = root.panel
      if (!panel || !panel._keyCodes || panel._keyCodes[name] === undefined) return "no key"
      const event = { key: panel._keyCodes[name], modifiers: 0, text: "", accepted: false }
      panel.handleKey(event)
      return name + " -> " + (event.accepted ? "accepted" : "passed")
    }

    function debugSetCurrentIdx(idx: int): string {
      // Route the IPC verb through the panel's seat so a programmatic jump
      // gets lease preemption, a highlight sweep and a live follow like a
      // browsed step. The panel's debugSetCurrentIdx owns list.seat(idx,"step").
      const panel = root.panel || root.probeSource
      if (panel && typeof panel.debugSetCurrentIdx === "function") {
        const now = panel.debugSetCurrentIdx(idx)
        return "set to " + idx + " now " + now
      }
      // Headless probe callers without a panel still get a raw seat.
      if (root.probeSource && root.probeSource.list) {
        root.probeSource.list.currentIndex = idx
        return "set to " + idx + " now " + root.probeSource.list.currentIndex
      }
      return "no probeSource"
    }

    function debugMove(dir: int): string {
      const list = root._debugList()
      if (!list || list.count === undefined) return "no probeSource"
      const next = list.count > 0 ? Range.clamp(list.currentIndex + dir, 0, list.count - 1) : 0
      // The relative step keeps its clamp but seats through the panel so the
      // cursor glides with the same contract as debugSetCurrentIdx.
      const panel = root.panel || root.probeSource
      if (panel && typeof panel.debugSetCurrentIdx === "function") {
        panel.debugSetCurrentIdx(next)
        return "moved to " + next
      }
      list.currentIndex = next
      return "moved to " + next
    }

    function debugMoveOption(dir: int): string {
      const panel = root.panel
      if (!panel || typeof panel.currentRow !== "function") return "no option row"
      const row = panel.currentRow()
      if (!row || typeof row.moveOption !== "function") return "no option row"
      // Same route as the human side arrow: the row owns grid stride, an
      // open child dropdown and group children. A raw optionIndex write
      // could reach a state no key press produces.
      if (row.moveOption(dir * row.optionColumnStride)) return "option moved"
      panel.stepCurrent(dir)
      return "stepped"
    }

    function debugActivate(): string {
      const list = root._debugList()
      const row = list ? list.currentItem : null
      if (row && typeof row.activate === "function") {
        row.activate()
        return "ok"
      }
      return "error"
    }

    // Current page rows for headless inspection: (id, kind, label).
    function debugRows(): string {
      const pg = root.pageById(root.frame ? root.frame.id : "")
      if (!pg) return "[]"
      const rows = []
      for (let i = 0; i < pg.items.length; i++) {
        const it = pg.items[i]
        if (!root.isListed(it)) continue
        rows.push({
          id: it.id ?? "",
          kind: it.type ?? "",
          label: it.label ?? "",
          available: !root.isUnavailable(it)
        })
      }
      return JSON.stringify(rows)
    }

    // Full normalized structure for debugging merges and guards.
    function dump(): string {
      if (!root.bundle) return "{}"
      const pages = []
      for (let i = 0; i < root.bundle.pages.length; i++) {
        const p = root.bundle.pages[i]
        const items = []
        for (let j = 0; j < p.items.length; j++) {
          const it = p.items[j]
          items.push({
            uid: it.uid,
            id: it.id,
            type: it.type,
            label: it.label,
            visible: root.isVisible(it),
            listed: root.isListed(it),
            available: !root.isUnavailable(it),
            disabled: root.isDisabled(it),
            checked: root.isChecked(it)
          })
        }
        pages.push({
          id: p.id,
          title: p.label,
          layout: p.layout,
          items: items
        })
      }
      return JSON.stringify(pages)
    }

    // Resolved row model for one page: (id, kind, label, checked, hint).
    // Label rides along because most bundle rows have an empty id; without
    // it the phase G baseline cannot tell rows apart. Same
    // visibility/confirm resolution the panel renders with.
    function dumpRows(pageId: string): string {
      const pg = root.pageById(pageId)
      if (!pg) return "[]"
      const rows = []
      for (let i = 0; i < pg.items.length; i++) {
        const it = pg.items[i]
        if (!root.isListed(it)) continue
        const cf = root.confirmFor(it)
        rows.push({
          id: it.id ?? "",
          kind: it.type ?? "",
          label: it.label ?? "",
          checked: root.isToggleOn(it) || root.isChecked(it),
          available: !root.isUnavailable(it),
          hint: cf ? cf.hint : ""
        })
      }
      return JSON.stringify(rows)
    }

    function status(): string {
      return JSON.stringify({
        visible: root.visible,
        depth: root.stack.length,
        page: root.frame ? root.frame.id : "",
        query: root.query,
        guards: Object.keys(root.guardWhen).length + "/" + Object.keys(root.guardChecked).length + "/" + Object.keys(root.guardDisabled).length
      })
    }

    // Live view introspection: what the cursor row actually reports.
    function probe(): string {
      return root.probeSource ? root.probeSource.probeSnapshot() : "{}"
    }

    function debugState(): string {
      return JSON.stringify({
        viewState: root.viewState,
        pendingSel: root.pendingSel,
        stack: root.stack,
        bundleEntry: root.bundle ? root.bundle.entry : "",
        rev: root.rev
      })
    }
  }

  MenuView {}
}


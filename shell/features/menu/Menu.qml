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
import "../../common/text/UnitIpc.js" as UnitIpc

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
  readonly property bool animationsEnabled: MotionPolicy.enabled

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

  // uid -> true for submenu links whose target page currently renders
  // no visible rows. Bash `when` guards live in guardWhen (menu-side),
  // so the settings schema counter cannot see them - e.g. the Power
  // page on a machine without PPD keeps its link while the page itself
  // renders nothing. isVisible consults this map, hiding the link from
  // page rows AND search results (groupSearchResults filters through
  // isVisible). Recomputed to a fixpoint: a link is dead when its
  // target has no live row, where live excludes already-dead links -
  // transitive empties collapse in repeated passes.
  property var _deadLinks: ({})

  // Current search query; non-empty flips panels into results mode.
  property string query: ""
  property var results: []
  readonly property bool searching: root.query !== ""

  // In-page "/" quick-filter. Unlike cross-page search it does not alter
  // the navigation frame; it simply filters the current page's rows.
  property bool scopedActive: false
  property string scopedQuery: ""
  property var scopedRows: []
  readonly property bool scopedSearching: root.scopedActive && root.scopedQuery !== ""

  // Per-row state, keyed by normalized stable uid.
  property var _states: ({})
  property int rev: 0

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
    id: siblingLoader
    path: ""
    printErrors: false
  }

  Component.onCompleted: {
    Registry.offer("menu", {
      title: "Menu",
      description: "Menu service",
      verbNames: ["openFile", "open", "close", "toggleFile", "status", "dump", "probe",
        "back", "debugActivate", "debugMove", "debugMoveOption", "debugRows",
        "debugSetCurrentIdx", "debugState", "dumpRows", "help", "ping", "toggle"]
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
    if (root.open) {
      root.close()
      return true
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
    root.resetSearch()
    root._states = ({})
    root.rev++
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
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
    root._lastName = filePath.substring(filePath.lastIndexOf("/") + 1)
    const text = loader.text()

    // Repeat-summon cache: parsing/normalizing a bundle costs enough to
    // justify reusing the two most recent built containers. Any change to
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
      if (keys.length >= 2) delete root._bundleCache[keys[0]]
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

  // The external pages - the idle timer list - belong to the settings
  // family. The surface drops its page table on every container reload and
  // the owners republish after the drop, but a cached reload does not
  // reload the containers: the table then keeps whatever the last reload
  // left in it, and that reload may have been a bundle which does not take
  // these pages. Ask for them again, so the table matches the bundle that
  // is actually active.
  function _restoreExternalPages() {
    if (!root.externalPagesAllowed()) return
    PageHost.replayPages()
  }

  property string _lastPath: ""
  property string _lastName: ""
  property var _bundleCache: ({})
  property bool _prewarmed: false

  // Boot-time prewarm for the two most-opened bundles (see onCompleted).
  // Builds each container into the repeat-summon cache and runs its guard
  // batch, so the first real keypress cache-hits a settings-complete bundle
  // and reads cached verdicts. The two builds share the single-flight guard
  // runner: the first batch runs for the first bundle, the second call parks
  // `_guardsPending` and re-runs for the second once the first lands - with
  // the merge below both verdict sets survive. Never disturbs a live menu:
  // `_buildFromFile` restores the active containers when open, and the
  // prewarm simply retries later in that case.
  function _maybePrewarm() {
    if (root._prewarmed) return
    if (root.open) {
      prewarmRetry.restart()
      return
    }
    if (Settings.ready !== true || HyprlandSettings.ready !== true
      || MiscSettings.ready !== true) {
      prewarmRetry.restart()
      return
    }
    try {
      if (root._buildFromFile(Paths.settingsCatalogPath + "#main")) root.evaluateGuards()
      if (root.open) {
        prewarmRetry.restart()
        return
      }
      if (root._buildFromFile(Paths.settingsCatalogPath + "#utilities")) root.evaluateGuards()
    } catch (e) {}
    root._prewarmed = true
  }

  property Qml.Timer prewarmRetry: Qml.Timer {
    interval: 500
    repeat: false
    onTriggered: root._maybePrewarm()
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
    root._loadContainers(text, extOverride)
    root._primeRuntime(root.bundle)
    root._claimToken = SurfaceClaim.claim("menu", root.close, root)
    Qt.callLater(root.evaluateGuards)
  }

  function _loadContainers(text, extOverride, entryFrag) {
    const t0 = Date.now()
    // The unified catalog carries menu `menus`: parseBundle reads those,
    // while a generated settings bundle carries `pages`. Either way the
    // dynamic settings/hypr leaves merge below when linked.
    let base = MenuLib.parseBundle(text)
    let searchBase = base

    const bare = base.pages.length === 1 && base.pages[0].items.length === 0
    let linksSettings = root._catalogFile(root._lastPath) || bare
    for (let p = 0; p < base.pages.length && !linksSettings; p++) {
      const items = base.pages[p].items
      for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (it.type === "submenu" && Settings.menuHasPage(it.page)) {
          linksSettings = true
          break
        }
      }
    }
    root._settingsFamily = linksSettings
    if (linksSettings) {
      const dynamic = Settings.menuBundleText()
      if (dynamic !== "") {
        try {
          const joined = MenuLib.mergeSibling(base, dynamic)
          base = joined
          searchBase = joined
        } catch (e) {}
      }
      if (HyprlandSettings.ready) {
        const hdyn = HyprlandSettings.menuBundleText()
        if (hdyn !== "") {
          try {
            base = MenuLib.mergeSibling(base, hdyn)
            searchBase = MenuLib.mergeSibling(searchBase, hdyn)
          } catch (e) {}
        }
      }
      MenuLib.orderSettingsIndex(base)
      let linksMisc = false
      if (MiscSettings.ready) {
        for (let p = 0; p < base.pages.length && !linksMisc; p++) {
          const items = base.pages[p].items
          for (let i = 0; i < items.length; i++) {
            const it = items[i]
            if (it.type === "submenu" && MiscSettings.menuHasPage(it.page)) {
              linksMisc = true
              break
            }
          }
        }
        if (!linksMisc && base.byId["misc"] !== undefined) linksMisc = true
        if (linksMisc) {
          const mdyn = MiscSettings.menuBundleText()
          if (mdyn !== "") {
            try {
              base = MenuLib.mergeSibling(base, mdyn)
              searchBase = MenuLib.mergeSibling(searchBase, mdyn)
            } catch (e) {}
          }
        }
      }
    } else {
      if (HyprlandSettings.ready) {
        let linksHyprDirect = false
        for (let p = 0; p < base.pages.length && !linksHyprDirect; p++) {
          const items = base.pages[p].items
          for (let i = 0; i < items.length; i++) {
            const it = items[i]
            if (it.type === "submenu" && HyprlandSettings.menuHasPage(it.page)) {
              linksHyprDirect = true
              break
            }
          }
        }
        if (linksHyprDirect) {
          const hdyn = HyprlandSettings.menuBundleText()
          if (hdyn !== "") {
            try {
              base = MenuLib.mergeSibling(base, hdyn)
              searchBase = MenuLib.mergeSibling(searchBase, hdyn)
            } catch (e) {}
          }
        }
      }
      if (MiscSettings.ready) {
        let linksMiscDirect = false
        for (let p = 0; p < base.pages.length && !linksMiscDirect; p++) {
          const items = base.pages[p].items
          for (let i = 0; i < items.length; i++) {
            const it = items[i]
            if (it.type === "submenu" && MiscSettings.menuHasPage(it.page)) {
              linksMiscDirect = true
              break
            }
          }
        }
        if (linksMiscDirect || base.byId["misc"] !== undefined) {
          const mdyn = MiscSettings.menuBundleText()
          if (mdyn !== "") {
            try {
              base = MenuLib.mergeSibling(base, mdyn)
              searchBase = MenuLib.mergeSibling(searchBase, mdyn)
            } catch (e) {}
          }
        }
      }
    }

    if (base.byId[base.entry] !== undefined && base.byId[base.entry].items.length === 0) {
      const fb = base.byId["settings"] !== undefined ? "settings"
        : (base.pages.find(p => p.items.length > 0) || {}).id
      if (fb !== undefined && fb !== null && fb !== "") base.entry = fb
    }

    // No sibling registry: the unified catalog already carries every menu
    // page (`menus`), and the dynamic settings/hypr leaves merged above.
    // Unrelated picker bundles opened via openJson stay untouched.

    let extText = extOverride
    if (extText === undefined) {
      const extPath = Paths.configHome
      extensionLoader.path = extPath + "/vibranium/user-menu.jsonc"
      extText = extensionLoader.waitForJob() ? extensionLoader.text() : ""
    }
    if (extText !== undefined && extText !== null && extText.trim() !== "") {
      try {
        if (searchBase === base) {
          base = MenuLib.applyExtension(base, extText)
          searchBase = base
        } else {
          base = MenuLib.applyExtension(base, extText)
          searchBase = MenuLib.applyExtension(searchBase, extText)
        }
      } catch (e) {}
    }

    // Entry scope for the unified catalog: the file holds every menu, but
    // search and the external-half gate span only the opened entry's tree,
    // the way one-file-per-menu scoped both before. Other bundles keep
    // their file scope.
    const isCatalog = root._catalogFile(root._lastPath)
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
      root._settingsFamily = fam
    }

    root.bundle = base
    root._builtinIndex = MenuLib.buildIndex(searchBase)
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

  function _primeRuntime(bundle) {
    root.bundle = bundle
    root.resetSearch()
    root.pendingSel = -1
    root.viewState = {}
    root._optionPages = {}
    root._restorePending = {}
    root.beginRestore(bundle.entry)
    root._states = {}
    root._closingRows = {}
    root._closePending = 0
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

  function _rebuildSearchIndex() {
    const merged = root._builtinIndex.slice()
    if (root._settingsFamily) {
      for (const ownerId in root._indexRegistrations) {
        const entries = root._indexRegistrations[ownerId]
        if (Array.isArray(entries)) merged.push(...entries)
      }
    }
    root.searchIndex = merged
  }

  function setQuery(q) {
    if (root.frame && root.hasDynamicPage(root.frame.id)) {
      if (!root.scopedActive) root.beginScoped()
      root.setScopedQuery(q)
      return
    }
    root.query = q
    root.results = root.searching ? MenuLib.search(root.searchIndex, q) : []
    const provider = root._indexProviderFor(q)
    if (provider && typeof provider.ensureScanned === "function") {
      const took = provider.ensureScanned()
      if (took && typeof provider.whenScanned === "function") {
        const gen = ++root._pendingQueryGen
        const held = String(q || "")
        provider.whenScanned(() => {
          if (gen !== root._pendingQueryGen) return
          const live = String(root.query || "")
          if (live !== "" && live !== held) root.setQuery(live)
          else root.setQuery(held)
        })
      }
    }
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

  function _buildCondIndex() {
    const vars = {}
    const bound = {}
    if (!root.bundle) {
      root._condVars = vars
      root._boundVars = bound
      return
    }
    for (const page of root.bundle.pages) {
      for (const item of page.items) {
        if (item.var) bound[item.var] = true
        for (const cond of item.showIf || []) vars[cond.var] = true
      }
    }
    root._condVars = vars
    root._boundVars = bound
  }

  // --- supplemental state ---
  // Alias the open flag under the name views bind to (MenuView.visible,
  // PanelFocus serviceVisible). Same value, stable name.
  readonly property bool visible: root.open

  // Unified right-hand value column for bar alignment (see MenuPanel).
  // When a page shows >=2 range/progress rows, all value boxes share this
  // width so little bars form a perfect column. 0 = per-item sizing.
  property int unifiedBarValueW: 0

  // Slots the global close easing is still holding (see slotClosing).
  property var _closingRows: ({})
  property int _closePending: 0

  // Blow-by-blow latch for per-row slot closes, uid -> true. Armed at the
  // collapse choke point (setExpanded/setInfo with value !== true, where
  // no DropdownSlot is in scope) and cleared by the row itself when its
  // slot motion reaches zero (see MenuPanel's onSlotMotionMsChanged).
  // Reconciled against the model on every install (pruneSlotCloses), so a
  // latch never outlives its row.
  property var _slotCloses: ({})

  // True while a dropdown/expansion slot is still easing shut - the full
  // close animation plus its grace window (mirrors DropdownSlot.closing).
  property bool slotClosing: false

  property Qml.Timer slotCloseTimer: Qml.Timer {
    interval: Ui.normalMs + 40

    onTriggered: root.slotClosing = false
  }

  // Staged-flow cursor per row uid: {index, values}. Flow rows (an item
  // with a `flow` stage array, see MenuLib.isFlow) render one stage at a
  // time; the cursor and the accumulated stage values live here, outside
  // the bundle, so navigation never mutates page data.
  property var _flow: ({})

  // Bumped only when a store change may have flipped a showIf verdict; the
  // panel re-filters rows on this instead of every rev.
  property int condRev: 0
  property var _condVars: ({})
  property var _boundVars: ({})

  // Primary panel publishes itself here for `probe` and the debug verbs.
  property var probeSource: null

  Connections {
    target: Settings
    function onOptionChanged(key, value) {
      Menu.syncBound(key, value)
      Menu.refreshSectionCounts()
      Menu.recomputeDeadLinks()
    }
    function onReadyChanged() { Menu._maybePrewarm() }
  }
  Connections {
    target: HyprlandSettings
    function onOptionChanged(key, value) {
      Menu.syncBound(key, value)
      Menu.refreshSectionCounts()
      Menu.recomputeDeadLinks()
    }
    function onReadyChanged() { Menu._maybePrewarm() }
  }
  Connections {
    target: MiscSettings
    function onOptionChanged(key, value) {
      Menu.syncBound(key, value)
      Menu.refreshSectionCounts()
    }
    function onReadyChanged() { Menu._maybePrewarm() }
  }

  // Re-derive the "N items" sub line of every counted section row on the
  // settings root. Counting runs against the BUILT page with live
  // visibility - showIf conditions AND bash when-guards both resolve
  // here - so the number always matches what entering the section shows.
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
        if (!Menu.isVisible(cand)) continue
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
    return null
  }

  // Hook context handed to provider calls: lets a surface read menu state
  // (expanded confirm rows) and trigger conditional-reveal refreshes
  // without importing the menu framework.
  function _hookCtx(item) {
    return {
      isExpanded: (it) => root.isExpanded(it),
      bumpCondRev: () => root.bumpCondRev()
    }
  }

  // --- generic item helpers (provider-backed, Entry/MenuPanel delegate
  // here). Keeps row view (Entry) free of service imports and id branches;
  // per-service knowledge lives in the owning provider. JSON may also
  // provide a `confirm` object directly; provider confirms take precedence.

  function subFor(item) {
    if (!item) return ""
    const p = root._providerFor(item.id)
    if (p && typeof p.sub === "function") {
      const r = p.sub(item, root._hookCtx(item))
      if (r !== null && r !== undefined && r !== "") return String(r)
    }
    return String(item?.sub ?? "")
  }

  function displayFor(item) {
    if (!item) return null
    const p = root._providerFor(item.id)
    if (p && typeof p.display === "function") {
      const r = p.display(item, root._hookCtx(item))
      if (r !== null && r !== undefined && r !== "") return r
    }
    return null
  }

  function widestDisplayFor(item) {
    if (!item) return null
    const p = root._providerFor(item.id)
    if (p && typeof p.widestDisplay === "function") {
      const r = p.widestDisplay(item, root._hookCtx(item))
      if (r !== null && r !== undefined && r !== "") return r
    }
    return null
  }

  function isToggleOn(item) {
    if (!item || item.type !== "toggle") return false
    const p = root._providerFor(item.id)
    if (p && typeof p.checked === "function") {
      const r = p.checked(item, root._hookCtx(item))
      if (r === true || r === false) return r
    }
    if (typeof item.checked === "string" && item.checked !== "") return root.isChecked(item)
    // Use stateOf so var-bound toggles initialise from Settings and track rev
    const s = root.stateOf(item)
    return s.checked === true
  }

  function isValueActive(item) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.valueActive === "function") {
      const r = p.valueActive(item, root._hookCtx(item))
      if (r === true || r === false) return r
    }
    return false
  }

  function isNumberActive(item) {
    if (!item) return false
    const p = root._providerFor(item.id)
    if (p && typeof p.numberActive === "function") {
      const r = p.numberActive(item, root._hookCtx(item))
      if (r === true || r === false) return r
    }
    return false
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
    if (p && typeof p.confirm === "function") {
      const r = p.confirm(item, root._hookCtx(item))
      if (r !== null && r !== undefined) return r
    }
    if (item.confirm && typeof item.confirm === "object") return item.confirm
    return null
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
    if (!uid) return { index: 0, values: {} }
    let st = root._flow[uid]
    if (st === undefined) {
      st = { index: 0, values: {} }
      root._flow[uid] = st
    }
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

  // Store-driven condition verdict over a showIf list. Each condition reads
  // its owning store (hypr.* from HyprlandSettings, misc.* from
  // MiscSettings, everything else from Settings), ANDed with transitive
  // hidden-dependency suppression resolved against the same owner. A mixed
  // list such as the wallpaper transition (shell.wallpaper.enabled AND
  // hypr.animations.enabled) has legs in two stores, so routing the whole
  // list to one store hides the row unconditionally - the foreign leg never
  // matches there.
  function conditionsMet(showIf) {
    if (showIf === undefined || showIf === null) return true
    return root._condsMet(showIf, {})
  }

  function _condValue(v) {
    const s = String(v || "")
    if (s.indexOf("hypr.") === 0) return HyprlandSettings.value(s)
    if (s.indexOf("misc.") === 0) return MiscSettings.value(s)
    return Settings.value(s)
  }

  function _condByKey(v) {
    const s = String(v || "")
    if (s.indexOf("hypr.") === 0) return HyprlandSettings.byKey(s)
    if (s.indexOf("misc.") === 0) return MiscSettings.byKey(s)
    return Settings.byKey(s)
  }

  function _condsMet(showIf, seen) {
    for (let i = 0; i < showIf.length; i++) {
      const cond = showIf[i]
      const cur = root._condValue(cond.var)
      let ok
      if (cond.op === "in") ok = cond.arg.indexOf(cur) >= 0
      else if (cond.op === "neq") ok = cur !== cond.arg
      else ok = cur === cond.arg
      if (ok) {
        const dep = root._condByKey(cond.var)
        if (dep && dep.showIf && !seen[cond.var]) {
          seen[cond.var] = true
          ok = root._condsMet(dep.showIf, seen)
        }
      }
      if (!ok) return false
    }
    return true
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

  function isDisabled(item) {
    if (!item) return false
    return root.guardDisabled[item.uid] === true
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
          const items = root.bundle.pages[p].items
          for (let i = 0; i < items.length; i++) {
            const uid = items[i] ? items[i].uid : ""
            if (!uid) continue
            if (keepWhen[uid] !== undefined) delete keepWhen[uid]
            if (keepChecked[uid] !== undefined) delete keepChecked[uid]
            if (keepDisabled[uid] !== undefined) delete keepDisabled[uid]
          }
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
      // answers, so a ThemePicker > Utilities jump re-opened Utilities with
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
            for (let i = 0; i < items.length; i++) {
              const uid = items[i] ? items[i].uid : ""
              if (!uid) continue
              if (nextWhen[uid] !== undefined) mergedWhen[uid] = nextWhen[uid]
              else delete mergedWhen[uid]
              if (nextChecked[uid] !== undefined) mergedChecked[uid] = nextChecked[uid]
              else delete mergedChecked[uid]
              if (nextDisabled[uid] !== undefined) mergedDisabled[uid] = nextDisabled[uid]
              else delete mergedDisabled[uid]
            }
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
    // dead link - it is a page that has not arrived. Marking it dead hid the
    // "Settings" entry on a cold-boot Main summon; the install that put it
    // back then landed above the seat (Help clamped from the warm view),
    // which is the reported Help > Install > Settings walk. Treat it as
    // alive until the stores are ready; the bundle rebuild on the next open
    // (cache keys on sval/hrev/mrev) supplies the real page.
    const storesReady = Settings.ready === true
      && HyprlandSettings.ready === true && MiscSettings.ready === true
    const dead = {}
    let changed = true
    while (changed) {
      changed = false
      for (let p = 0; p < root.bundle.pages.length; p++) {
        const pg = root.bundle.pages[p]
        for (let i = 0; i < pg.items.length; i++) {
          const it = pg.items[i]
          if (!it || it.type !== "submenu" || dead[it.uid]) continue
          const tpg = typeof it.page === "string" && it.page !== ""
            ? root.bundle.byId[it.page] : null
          if (!tpg) {
            if (!storesReady) continue
            dead[it.uid] = true
            changed = true
            continue
          }
          let alive = false
          for (let j = 0; j < tpg.items.length; j++) {
            const tIt = tpg.items[j]
            if (!tIt || !tIt.selectable || dead[tIt.uid]) continue
            if (!root.isVisible(tIt)) continue
            alive = true
            break
          }
          if (!alive) {
            dead[it.uid] = true
            changed = true
          }
        }
      }
    }
    root._deadLinks = dead
  }

  function isVisible(item) {
    if (!item) return true
    const v = root.guardWhen[item.uid]
    if (v === false) return false
    // Fail-closed while a `when`/`requires` verdict is still pending: the
    // batch runs async after the summon, so fail-open painted the row for a
    // frame and then removed it (Utilities "Copy current track" appearing
    // with no icon, then vanishing, yanking focus). A pending guard hides;
    // a verdict of true shows. Boot-time prewarm (see _maybePrewarm) fills
    // the verdicts before the first summon, so the pending state is only
    // the cold-boot edge, not every open.
    if (v === undefined) {
      const w = item.when
      if (w !== undefined && w !== null && String(w).trim() !== "") return false
      const rq = item.requires
      if (rq !== undefined && rq !== null) return false
    }
    if (item.type === "submenu" && root._deadLinks[item.uid]) return false
    // Store-driven conditions (showIf), each leg against its owning store.
    if (item.showIf !== undefined && item.showIf !== null) {
      if (!root.conditionsMet(item.showIf)) return false
    }
    // Provider visibility predicate: clearUsageHistory hides when history
    // is empty (frequency sort's companion row). Providers may veto
    // visibility of any row they own; everything else stays visible.
    if (item && item.id) {
      const p = root._providerFor(item.id)
      if (p && typeof p.visible === "function") {
        if (p.visible(item, root._hookCtx(item)) === false) return false
      }
    }
    return true
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
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it && it.uid === uid) return it
    }
    return null
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
  // Used by search activation. `row` indexes the RAW items array; the
  // selection lands on the row's VISIBLE position since hidden rows
  // guards, showIf) never make it into the list model.
  function visibleIndexOf(page, rawRow) {
    let n = 0
    const items = page ? page.items : []
    for (let i = 0; i < rawRow && i < items.length; i++) {
      if (root.isVisible(items[i])) n++
    }
    return n
  }

  // Where a uid sits in the LIVE page, counting visible rows only. -1
  // when the page is unknown or the row is not on it.
  function visibleIndexOfUid(pageId, uid) {
    if (uid === undefined || uid === null || uid === "") return -1
    const page = root.pageById(pageId)
    if (!page || !Array.isArray(page.items)) return -1
    let n = 0
    for (let i = 0; i < page.items.length; i++) {
      const it = page.items[i]
      if (!root.isVisible(it)) continue
      if (it.uid === uid) return n
      n++
    }
    return -1
  }

  function jumpTo(pageId, row) {
    if (!root.hasPage(pageId)) return false
    root.collapseFrame(root.frame.id)
    const vs = Object.assign({}, root.viewState)
    delete vs[pageId]
    root.viewState = vs
    root.resetSearch()
    // The frame seats the VISIBLE position, not the raw page index: hidden
    // rows (guards, showIf) never reach the list model, so a raw slot is a
    // seat no row owns. The same number drives the landing (pendingSel) and
    // the fallback the frame keeps for a revisit without remembered state.
    const at = visibleIndexOf(root.pageById(pageId), row)
    root.pendingSel = at
    root.beginRestore(pageId)
    root.stack = [{
        id: pageId,
        sel: at,
        y: 0
      }]
    return true
  }

  // --- scoped "/" quick-filter ---

  // Arm the in-page filter. Scope stays the CURRENT page until cleared;
  // with an empty query it shows the full visible page so the first
  // keystroke simply narrows it.
  function beginScoped() {
    root.scopedActive = true
    root.setScopedQuery("")
  }

  function setScopedQuery(q) {
    const text = String(q ?? "")
    // Scope is what's actually on screen: the current page's VISIBLE
    // items, matched through the lib across label/sub/desc/options.
    const pg = root.pageById(root.frame ? root.frame.id : "")
    const visible = pg ? pg.items.filter(root.isVisible) : []
    // Small scopes install instantly like before; only giant ones ride
    // the debounce (see scopedTimer). Empty queries always apply at once.
    if (text === "" || visible.length <= Ui.listFullRows) {
      scopedTimer.stop()
      root._applyScopedQuery(text, visible)
      return
    }
    root._scopedPending = text
    scopedTimer.restart()
  }

  function _applyScopedQuery(q, pre) {
    root._scopedPending = ""
    root.scopedQuery = q
    let visible = pre
    if (!Array.isArray(visible)) {
      const pg = root.pageById(root.frame ? root.frame.id : "")
      visible = pg ? pg.items.filter(root.isVisible) : []
    }
    root.scopedRows = MenuLib.scopedFilter(visible, q)
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
    if (!root.scopedActive && root.scopedQuery === "" && root.scopedRows.length === 0) return
    root.scopedActive = false
    root.scopedQuery = ""
    root.scopedRows = []
  }

  // --- item state ---

  // Canonical mutable records keyed by uid.
  function _rawState(item) {
    let st = root._states[item.uid]
    if (st === undefined) {
      let checked = item.checked_ === true
      let value = item.value !== undefined ? item.value : ""
      if (item.var !== "") {
        let live
        const v = String(item.var)
        if (v.indexOf("hypr.") === 0) live = HyprlandSettings.value(item.var)
        else if (v.indexOf("misc.") === 0) live = MiscSettings.value(item.var)
        else live = Settings.value(item.var)
        if (item.type === "toggle") checked = live === true
        else if (live !== undefined) value = live
      }
      st = {
        checked: checked,
        value: value,
        expanded: false,
        info: false
      }
      root._states[item.uid] = st
    }
    return st
  }

  // Returns a COPY. Bindings capture `rev` first so they re-run on every
  // mutation, and the fresh object guarantees dependents see a change - a
  // same-reference var result would silently notify nobody.
  function stateOf(item) {
    if (!item || !item.uid) return {
      checked: false,
      value: "",
      expanded: false,
      info: false
    }
    root.rev
    return Object.assign({}, root._rawState(item))
  }

  function setChecked(item, value) {
    if (item.var !== "") {
      let ok = false
      const v = String(item.var)
      if (v.indexOf("hypr.") === 0) ok = HyprlandSettings.setOption(item.var, value === true)
      else if (v.indexOf("misc.") === 0) ok = MiscSettings.setOption(item.var, value === true)
      else ok = Settings.setOption(item.var, value === true)
      if (!ok) return
    }
    root._rawState(item).checked = value === true
    root.rev++
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
    if (item.var !== "") {
      let ok = false
      const v = String(item.var)
      if (v.indexOf("hypr.") === 0) ok = HyprlandSettings.setOption(item.var, value)
      else if (v.indexOf("misc.") === 0) ok = MiscSettings.setOption(item.var, value)
      else ok = Settings.setOption(item.var, value)
      if (!ok) return
    }
    root._rawState(item).value = value
    root.rev++
  }

  // --- expansion slots ---

  function setExpanded(item, value) {
    root._rawState(item).expanded = value === true
    root.rev++
    if (value !== true) {
      root.slotClosing = true
      root.slotCloseTimer.restart()
      // The row's own close latch: cleared when its slot motion reaches
      // zero (see slotCloseFinished), reconciled on every model install.
      if (item && item.uid) {
        const next = Object.assign({}, root._slotCloses)
        next[item.uid] = true
        root._slotCloses = next
      }
    } else if (item && item.uid && root._slotCloses[item.uid] !== undefined) {
      const next = Object.assign({}, root._slotCloses)
      delete next[item.uid]
      root._slotCloses = next
    }
  }

  function setInfo(item, value) {
    root._rawState(item).info = value === true
    root.rev++
    if (value !== true) {
      root.slotClosing = true
      root.slotCloseTimer.restart()
      if (item && item.uid) {
        const next = Object.assign({}, root._slotCloses)
        next[item.uid] = true
        root._slotCloses = next
      }
    } else if (item && item.uid && root._slotCloses[item.uid] !== undefined) {
      const next = Object.assign({}, root._slotCloses)
      delete next[item.uid]
      root._slotCloses = next
    }
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
  function slotCloseFinished(item) {
    if (!item || !item.uid) return
    if (root._slotCloses[item.uid] === undefined) return
    const next = Object.assign({}, root._slotCloses)
    delete next[item.uid]
    root._slotCloses = next
  }

  // A close latch belongs to a row the model still lists. `candidate` is
  // the authoritative next model, so anything pruned here has no delegate
  // left to report its close.
  function pruneSlotCloses(candidate) {
    const rows = Array.isArray(candidate) ? candidate : []
    const keep = {}
    for (let i = 0; i < rows.length; i++) {
      const uid = rows[i] ? rows[i].uid : ""
      if (uid) keep[uid] = true
    }
    const next = {}
    let changed = false
    for (const uid in root._slotCloses) {
      if (keep[uid]) next[uid] = true
      else changed = true
    }
    if (changed) root._slotCloses = next
  }

  // --- actions ---

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

  // --- ipc ---

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
      return UnitIpc.help("menu", "Menu", "settings + menu framework", [
        { name: "back", help: "go back one page" },
        { name: "close", help: "close the menu" },
        { name: "debugActivate", help: "activate the current row" },
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
      if (root.open) { root.close(); return "ok" }
      return root.openFile(path) ? "ok" : "error"
    }

    function back(): string {
      return root.back() ? "ok" : "error"
    }

    function debugSetCurrentIdx(idx: int): string {
      const list = root._debugList()
      if (list) {
        list.currentIndex = idx
        return "set to " + idx + " now " + list.currentIndex
      }
      if (root.probeSource && root.probeSource.list) {
        root.probeSource.list.currentIndex = idx
        return "set to " + idx + " now " + root.probeSource.list.currentIndex
      }
      return "no probeSource"
    }

    function debugMove(dir: int): string {
      const list = root._debugList()
      if (!list || list.count === undefined) return "no probeSource"
      const next = Math.max(0, Math.min(list.count - 1, list.currentIndex + dir))
      list.currentIndex = next
      return "moved to " + next
    }

    function debugMoveOption(dir: int): string {
      const list = root._debugList()
      const row = list ? list.currentItem : null
      if (!row || row.optionIndex === undefined) return "no option row"
      const opts = row.optionCount !== undefined ? row.optionCount : -1
      let next = row.optionIndex + dir
      if (opts >= 0) next = Math.max(0, Math.min(opts - 1, next))
      row.optionIndex = next
      return "option " + next
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
        if (!root.isVisible(it)) continue
        rows.push({ id: it.id ?? "", kind: it.type ?? "", label: it.label ?? "" })
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
        if (!root.isVisible(it)) continue
        const cf = root.confirmFor(it)
        rows.push({
          id: it.id ?? "",
          kind: it.type ?? "",
          label: it.label ?? "",
          checked: root.isToggleOn(it) || root.isChecked(it),
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


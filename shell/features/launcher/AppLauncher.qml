pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
// IpcHandler: the target and every verb stay in the resident file, so a
// controller can never become a second handler for the same target.
import Quickshell.Io
import qs.common
import qs.services as Core
import "LauncherLib.js" as LauncherLib
import "PluginPolicy.js" as PluginPolicy
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/collections/BoundedCache.js" as BoundedCache

// Native application launcher service: desktop-entry search and
// launching, action plugins, web-search plugins and per-plugin
// enable/disable settings, all behind the IPC target "appLauncher".
//
// ARCHITECTURE
//
// This file is the RESIDENT FACADE. It owns the IPC target and every verb,
// the surface claim, the panel's view/navigation state, the menu provider
// records, the plugin capability boundary and a read-only projection of the
// controller. It performs no desktop-entry index build, no plugin
// discovery, no usage-data read and constructs no window, panel or view:
// constructing this singleton costs a few property bindings, the provider
// claims and one settings-store lookup of the persisted plugin
// enablement - a map read, not a scan - and nothing else.
//
// AppLauncherController.qml is the eager controller. It arrives through
// a Loader shortly after boot (see _prewarm) and owns the usage-data load,
// the index build, the plugin scan and hosts, the models, the stat/clock/
// launch children and the whole panel tree. It then stays resident: the
// first summon must paint the app list on frame one, not an empty window
// while the index builds and the desktop-entry scan lands, and tearing the
// tree down after every close would replay that cold start on every open.
// UnitGate leases the unit on the facade's own owner string for the
// demand that builds it.
//
// Nothing here hands out the controller. The public read surface below is a
// small projection of it that the controller publishes as it works and this
// file keeps serving after the teardown, so a consumer can never hold a
// reference to the tree behind the facade, and a read is the same whether
// the panel happens to be up. Every verb answers: "ok", a payload, or
// loading / unavailable / error:<code> - and a group no controller has
// published yet answers "unavailable" rather than presenting the
// controller's absence as an empty history and an empty plugin list.
//
// PLUGINS
//
// A plugin is a directory holding plugin.json (manifest: name,
// description, keyword prefix, type) plus main.js assigning a
// VibraniumPlugin object (init/items/activate). Directories are scanned
// from $VIBRANIUM/shell/features/launcher/plugins first, then
// ~/.config/vibranium/shell/AppLauncher/plugins; the directory NAME is the
// plugin id and duplicates resolve in favor of the earlier root. Broken
// manifests, missing metadata and failing initialization skip the plugin
// with a warning - they can never take the launcher down.
//
// A plugin is TRUSTED CODE, not sandboxed code: main.js is evaluated by
// PluginInstance inside this shell's own engine, with the engine's whole
// authority, and PluginPolicy cannot confine that. What the policy bounds
// is the API the launcher publishes - see _grantsFor, _apiFor and
// PluginPolicy.js for the full statement. The boundary stays here, in the
// file the security contract pins, while the controller does the scanning
// and the evaluating.
//
// Enable/disable state lives in settings.json under
// shell.appLauncher.plugins as a sparse list of config objects
// ({id, name, description, keyword, type, enabled}); discovery merges the
// manifests with whatever is persisted there. Disabled plugins are never
// loaded, never register prefixes and never contribute rows.
Singleton {
  id: root

  readonly property string tag: "appLauncher"
  readonly property string unitId: "appLauncher"

  // --- visibility and query ---
  // Reload survival for visibility plus the search text
  // (memory-only, never disk): bindings read through persist,
  // imperative sets write back via the change handlers below. Primitives
  // only - no controller, no window and no Loader is ever stored here.
  PersistentProperties {
    id: persist
    reloadableId: "appLauncher-visible"
    property bool visible: false
    property string entry: ""
  }
  property bool visible: persist.visible
  // Query text after prefix stripping (the search field mirrors this).
  property string entry: persist.entry
  onEntryChanged: persist.entry = entry

  // --- mode state (view state, outlives a single open) ---
  // "normal" | plugin type of the active mode ("websearch")
  // - assigned by enterMode()/exitMode()/reset(); nothing else may
  // assign it. The owner is an id, not a config object: a controller
  // teardown and rebuild mints fresh plugin objects, and a mode that held
  // one would be filtering against a dead owner.
  property string mode: "normal"
  property string modePluginId: ""
  // The mode's plugin as the search field reads it: a plain descriptor
  // handed over by the controller, never a runtime object, and never a
  // handle a view could walk back into the plugin registry with. It is
  // written where the id is written, so the two cannot drift.
  property var modePlugin: null

  // Token for the exclusive-surface claim this open holds, released by
  // close() and by Component.onDestruction.
  property var _claimToken: null

  // Row activation debounce: key repeat or a second Enter landing before
  // the window tears down must not start an app twice - the launcher
  // closes on the first hit and swallows the rest. Input state, so it
  // survives a controller teardown and covers the rebuilt one too.
  property double lastActivateAt: 0

  // Staged delete row: panel input, not index state. Held here because the
  // panel writes it between the stage and the confirm, and both may land
  // on either side of a controller rebuild.
  property var pendingDelete: null

  // --- controller lifecycle ---
  // One owner string for every demand. UnitGate matches leases by owner,
  // so a constant owner means the second keypress finds the lease that
  // already exists instead of minting a parallel one, and it is neither
  // Boot's "boot", nor pass's "pass-facade", nor a bar module's
  // "bar:<id>", so a release here can never take down a lease someone else
  // is holding.
  readonly property string gateOwner: "appLauncher-facade"
  property var _lease: null
  property int _constructions: 0

  // unloaded | loading | ready | unavailable | failed. A verb that cannot
  // run answers from this instead of vanishing: the string a caller sees
  // is _unavailableVerb().
  property string controllerState: "unloaded"
  property string controllerError: ""
  readonly property bool controllerReady: root.controllerState === "ready"
  // The facade itself is ready the moment this singleton is constructed,
  // which is what the boot drain waits for: the drain's job is to make the
  // `appLauncher` IPC target exist, not to build a controller. Confusing the
  // two leaves the launcher with no registered target at all, so
  // the two are separate properties with separate meanings.
  readonly property bool facadeReady: root.tag !== ""
  // Controllers built since boot. 0 until the prewarm lands, then one:
  // the visible proof that a facade construction does no work and the
  // resident controller is built exactly once.
  readonly property int constructions: root._constructions

  // --- public read surface (published) ---
  readonly property var _controller: controllerLoader.item
  // Result rows consumed by the panel, plus the filter counter. The
  // controller publishes all three on every recompute that assigns (see
  // _publishRows), and this file keeps serving the last publication after
  // the teardown - the same provenance pattern usage and plugins already
  // use below. Without it a close would drop the row model to [] and destroy
  // every delegate with its decoded icons, so the next open rebuilt the wall
  // from scratch with a visible refill. Cached rows are plain records; a
  // mode switch or query always recomputes before a read that needs it, so
  // a stale publication never answers a live question.
  property var _lastResults: []
  property int _lastMatched: 0
  property int _lastTotal: 0
  readonly property var results: root._controller !== null ? root._controller.results : root._lastResults
  readonly property var enabledPrefixes: root._controller !== null ? root._controller.enabledPrefixes : []
  readonly property int matchedCount: root._controller !== null ? root._controller.matchedCount : root._lastMatched
  readonly property int totalCount: root._controller !== null ? root._controller.totalCount : root._lastTotal
  function _publishRows(rows, matched, total) {
    root._lastResults = rows
    root._lastMatched = matched
    root._lastTotal = total
  }
  // Clock verdicts for the "time in <city>" rows, read by a granted
  // plugin through the capability host below. A plugin only exists while
  // a controller does, so this cache is not published.
  readonly property var timeCache: root._controller !== null ? root._controller.timeCache : ({})
  // Response bodies for the "value <CUR> in <CUR>" rows, keyed by URL, read
  // by a granted plugin through the capability host below. Same reasoning as
  // timeCache: a plugin lives exactly as long as a controller, so this cache
  // is not published either.
  readonly property var netCache: root._controller !== null ? root._controller.netCache : ({})
  // The last PATH scan behind the binary-launch fallback: { names, at: ms },
  // read by a granted plugin through the capability host below. Same
  // reasoning as timeCache and netCache - a plugin lives exactly as long as a
  // controller, so this cache is not published either.
  readonly property var binariesCache: root._controller !== null ? root._controller.binCache : null
  // Filesystem verdicts for openable local targets: path -> "dir" | "file"
  // | "missing". Unlike the caches above this one outlives the controller by
  // design: the clipboard suggestion's row withholds or paints from it, and
  // a teardown that dropped it would make every open re-render a long-deleted
  // target from its copy-time hint before the fresh probe corrects it - the
  // show-then-hide flicker. Memory-only, never disk: a verdict is about the
  // live filesystem, and a reload re-probes rather than trusting it. Bounded
  // at 128 like the app-icon memo: a session probes one clipboard target
  // plus a handful of typed paths, so the steady state is all hits and a
  // typed-path walk cannot grow it without bound.
  readonly property int statCacheCap: 128
  property var statCache: BoundedCache.create(root.statCacheCap)

  // --- published reads ---
  //
  // The controller's answers to the questions a caller may ask with the
  // panel closed: the usage cache and its emptiness, the discovered plugin
  // records and the per-plugin enablement the settings menu paints. It
  // publishes them here as it works (see _publishUsage/_publishPlugins) and
  // this file keeps serving them after the teardown, so a read never flips
  // just because a close settled.
  //
  // Each group carries its own provenance. `usageKnown` and `pluginsKnown`
  // are false until a controller has published a real value, and a verb
  // reading an unpublished group answers "unavailable" - the documented
  // result for a missing heavy controller - instead of a fact the facade
  // never observed.
  property bool usageKnown: false
  // usage -> count (plain number), as last published.
  property var usageMap: ({})
  // The clear-history row's offer gate, not a verdict about the cache: it
  // stays true until a controller has published the real answer, so a
  // history this shell has not read yet is never hidden. The factual read
  // is hasHistory(), which answers "unavailable" while usageKnown is false.
  property bool hasUsageHistory: true
  property bool pluginsKnown: false
  // Plain plugin records, exactly what pluginSummary() produced.
  property var pluginRows: []
  // The published enablement map (plugin id -> bool), or null while no
  // controller has published one.
  property var _publishedToggles: null

  // The user's own plugin configuration, re-read whenever the settings
  // engine bumps. This is the toggle answer before any controller has run:
  // the menu follows what the user configured, not a controller's absence,
  // so a shell that has never opened the launcher paints the real state.
  // Absent means enabled, which is the default discovery applies too.
  readonly property var _persistedToggles: root._persistedPluginToggles()
  // What the settings menu paints, and one rule so the three sources cannot
  // drift: a plugin the configuration turned off reads off whatever the scan
  // says, otherwise a live scan says everything it knows, and with no live
  // scan at all the configuration's own default stands. A hand edit therefore
  // moves a toggle at once with the launcher closed, and a published map is
  // never stale against the file it came from.
  readonly property var pluginToggles: root._mergeToggles(root._liveToggles(), root._persistedToggles)

  // The published registry answers only while a controller holds it. A demand
  // that raced its own scan has published nothing, and a controller torn down
  // after a close leaves a map behind that nothing can refresh - either way
  // the published snapshot is not a live answer, and a state written through
  // settings meanwhile would be argued down by it.
  function _liveToggles() {
    const ctrl = root._controller
    if (ctrl === null || ctrl.pluginsResolved !== true) return null
    return root._publishedToggles
  }

  function _mergeToggles(published, persisted) {
    const out = {}
    const ids = root._pluginToggleIds()
    for (let i = 0; i < ids.length; i++) {
      const pid = String(ids[i]).replace(/^launcher-/, "")
      if (persisted[pid] === false) {
        out[pid] = false
        continue
      }
      if (published !== null && published[pid] !== undefined) {
        out[pid] = published[pid] === true
        continue
      }
      out[pid] = persisted[pid] !== false
    }
    return out
  }

  // The controller is the only writer of the two groups, and it writes
  // plain values: a map, a bool, a record list. Nothing published here can
  // be walked back into the tree behind the facade.
  function _publishUsage(hasHistory, map) {
    root.usageKnown = true
    root.hasUsageHistory = hasHistory === true
    root.usageMap = map
  }

  function _publishPlugins(rows, toggles) {
    root.pluginsKnown = true
    root.pluginRows = rows
    root._publishedToggles = toggles
  }

  // The seven rows the settings menu owns, read from the persisted plugin
  // section. Not a scan: the settings store is resident and the answer is a
  // seven-entry map.
  function _persistedPluginToggles() {
    const section = Settings.rawSection("appLauncher")
    const list = section && Array.isArray(section.plugins) ? section.plugins : []
    const out = {}
    const ids = root._pluginToggleIds()
    for (let i = 0; i < ids.length; i++) {
      const pid = String(ids[i]).replace(/^launcher-/, "")
      out[pid] = true
      for (let j = 0; j < list.length; j++) {
        if (list[j] && list[j].id === pid) {
          out[pid] = list[j].enabled !== false
          break
        }
      }
    }
    return out
  }

  // Per-group provenance for status(), so a consumer can tell an empty
  // answer from an answer nobody has collected yet.
  function _readStates() {
    const ready = "ready"
    const unknown = "unavailable"
    return {
      history: root.usageKnown ? ready : unknown,
      usage: root.usageKnown ? ready : unknown,
      plugins: root.pluginsKnown ? ready : unknown
    }
  }

  // Chip label inside the search field: empty in every mode (normal
  // shows nothing, web-search shows the bare glyph). Kept for chipText.
  readonly property string chipLabel: ""
  // Chip icon inside the search field: active engines and web-search
  // results replace the default search glyph with a mode-specific glyph.
  readonly property string chipIcon: {
    if (root.modePluginId === "unit") return "calculator"
    if (root.modePluginId === "fx") return "landmark"
    if (root.modePluginId === "color") return "pipette"
    if (root.mode === "websearch") return "webapp"
    const row = root.results.length > 0 ? root.results[0] : null
    if (row && row.kind === "unit") return "calculator"
    if (row && row.kind === "fx") return "landmark"
    if (row && row.kind === "color") return "pipette"
    if (row && row.kind === "web") return "webapp"
    if (row && row.kind === "time") return "clock"
    if (row && row.kind === "calc") return "radical"
    return ""
  }
  readonly property string chipColorKey: "foreground_1"
  // Pill chrome toggle: mode glyphs read as plain inline content - no
  // colon, no box. The default search glyph follows the same treatment.
  readonly property bool chipBoxed: false

  readonly property string placeholder: {
    if (root.mode === "websearch") {
      return "search query..."
    }
    return "Search apps..."
  }

  // Filter counter box. Covers every mode that renders a filterable list;
  // exclusive synthetic modes have nothing to filter and hide the box. The
  // test is EVERY row rather than the first, because an engine can answer
  // with a list of readings now - "6/214 apps" over six conversions would be
  // counting a pool the engine never searched. The synthetic web fallback row
  // never counts as a match either: "0/214 apps" is the honest reading of a
  // fruitless query.
  readonly property bool showCounter: root.mode === "normal"
    && !LauncherLib.allSynthKinds(root.results)

  // Focus truth: the visible panel reports its field's live keyboard
  // state; scanned on demand (status/probe), never stale.
  readonly property bool effectiveSearchFocused: {
    for (let i = 0; i < root._panels.length; i++) {
      const p = root._panels[i]
      if (p.primarySurface) return p.probeFocus().focused
    }
    return false
  }

  // Registered panel instances (one per screen); tests and status()
  // reach keyboard truth through here. Panels live and die with the
  // controller, so this list empties with it.
  property var _panels: []

  function _attachPanel(panel) {
    const next = root._panels.slice()
    next.push(panel)
    root._panels = next
  }

  function _detachPanel(panel) {
    root._panels = root._panels.filter(p => p !== panel)
  }

  // --- provider id ownership ---
  // ProviderHost hands a record to the host Menu once and refuses a
  // re-registration whose owner is a different object, so a record is only
  // ever replaceable by the object that owns it. Every id below is owned
  // for as long as this unit is alive and is released in its teardown; a
  // refused id would otherwise pin the surface to a dead closure and drop
  // the row's confirm stage.
  function _claimProviderId(id, surface, deferred) {
    if (ProviderHost.registerProvider(id, surface, root)) return true
    ProviderHost.unregisterProvider(id, root)
    if (ProviderHost.registerProvider(id, surface, root)) return true
    // A predecessor that has not finalized yet still holds the id and
    // frees it only from its own teardown, which is itself a deferred
    // step, so a recreated unit gets one late attempt past this turn. The
    // id is bounded and re-entrant: this path can only ever claim a free
    // id, so a late miss is reported and never blocks a live owner.
    if (deferred) {
      DeferredQueue.run(() => { root._claimProviderId(id, surface, false) }, 2, 0, root.tag + " provider retry")
      return false
    }
    return false
  }

  // Ids of the plugin toggle rows the launcher overlays. One source for
  // registration and teardown, so the two sets cannot drift apart.
  function _pluginToggleIds() {
    return ["launcher-calc", "launcher-unit", "launcher-fx", "launcher-time", "launcher-color", "launcher-binary", "launcher-websearch"]
  }

  function _releaseMenuProviders() {
    const ids = root._pluginToggleIds()
    ProviderHost.unregisterProvider("clearUsageHistory", root)
    for (let i = 0; i < ids.length; i++)
      ProviderHost.unregisterProvider(ids[i], root)
  }

  // Menu provider surface: overlays clearUsageHistory-row semantics onto
  // the bundle-declared row by id (two-step confirm, empty-history
  // visibility gate). ProviderHost holds the surfaces under this unit as
  // owner and replays them when Menu registers as its host, so drain order
  // does not gate the rows. The menu closes on clear by design
  // (LauncherEntry flow), so no reopen logic belongs in the provider.
  //
  // Claimed while this facade constructs, not after a discovery: these are
  // nine records the settings menu reads with the launcher closed, and a
  // claim that waited for a first use would take the plugin toggle rows and
  // the clear-history row out of the menu for the whole session. What they
  // read is the projection above, and what they write is a demand.
  function _registerMenuProvider() {
    root._claimProviderId("clearUsageHistory", {
      visible: () => root.hasUsageHistory !== false,
      sub: (item, ctx) => (ctx && ctx.isExpanded(item)) ? "Select to confirm clear" : null,
      confirm: () => ({
        stages: 2,
        hint: "Press <b>Enter</b> again to clear usage history",
        armed: "<b><u>Press again to confirm clear</u></b>",
        label: "Clear history",
        action: "clearHistory"
      }),
      runConfirm: (item, ctx) => {
        // The real verdict, not a literal: a refused demand (blocked unit,
        // failed construction) or a cache that was already empty must reach
        // the menu as a refusal, or the row reports an action that never
        // ran. The repaint still happens either way - a successful clear
        // moves hasUsageHistory and hides the row.
        const cleared = root.clearUsageHistory()
        if (ctx) ctx.bumpCondRev()
        return cleared === true
      }
    }, false)
    const ids = root._pluginToggleIds()
    for (let i = 0; i < ids.length; i++) {
      root._claimProviderId(ids[i], {
        checked: (item) => root._pluginToggleState(item.id),
        runToggle: (item, state) => root._pluginToggleCommit(item.id, state)
      }, false)
    }
  }

  // Menu provider read: plugin id ("launcher-calc") -> enabled flag.
  // The live registry while a controller is up, the published projection
  // after it, and the user's persisted configuration before any controller
  // has ever run - so the row follows the configuration instead of painting
  // off for the length of a session nobody summoned the launcher. An id no
  // source knows reads as false, which is what an undiscovered plugin dir
  // is; discovery repaints via rev.
  function _pluginToggleState(menuId) {
    const pid = String(menuId ?? "").replace(/^launcher-/, "")
    const ctrl = root._controller
    // An unresolved registry holds no config, so pluginEnabled answers off
    // for every id - which would paint the whole page off for as long as a
    // tree's scan is in flight. Read the configuration until it resolves.
    if (ctrl !== null && ctrl.pluginsResolved === true) return ctrl.pluginEnabled(pid)
    const toggles = root.pluginToggles
    return toggles[pid] === true
  }

  // Menu provider write: demand the controller, which owns the flip and
  // the settings flush. This is a demand that never opens the panel, so it
  // takes the transient path: the tree goes again after the idle grace
  // instead of staying resident with nothing on screen. A refused demand
  // reports false, so the menu keeps the row as it was instead of painting
  // a toggle that changed nothing.
  function _pluginToggleCommit(menuId, state) {
    const ctrl = root._demandTransient()
    if (ctrl === null) return false
    return ctrl.pluginToggleCommit(menuId, state === true)
  }

  // Registry API: clear the most-used cache. Called directly by the
  // settings menu's confirmation dropdown - no shell boilerplate, and with
  // the launcher closed: this is the one writer the menu reaches without an
  // open, so it demands the controller like every other writer and hands the
  // real verdict back. A refused demand returns false, which is what the
  // row's runConfirm reports instead of a success it did not perform.
  function clearUsageHistory() {
    const ctrl = root._demandTransient()
    if (ctrl === null) return false
    return ctrl.clearUsageHistory()
  }

  Component.onCompleted: {
    Registry.offer("appLauncher", {
      title: "App launcher",
      description: "application search + usage-ranked results + plugins",
      verbNames: [
        "clearHistory",
        "close",
        "hasHistory",
        "open",
        "plugins",
        "pluginSet",
        "reload",
        "toggle",
        "usage",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register("appLauncher", root)
    // The provider claims are the only work this construction does
    // synchronously: six records the menu reads. The controller - usage
    // read, index build, plugin scan, no window - follows on its own
    // prewarm below, so the first summon finds it already built.
    root._registerMenuProvider()
    Qt.callLater(root._prewarm)
    // A reload with the panel open lands here with visible already true
    // and no claim (a claim is memory-only), so the open is replayed
    // through open() after clearing the flag: the claim and the
    // controller come back exactly as they were before the reload.
    if (root.visible) {
      root._replaying = true
      root.open()
      root._replaying = false
    }
  }

  Component.onDestruction: {
    closeSettle.stop()
    // The controller goes before the lease does, so no gate observer ever
    // sees the unit released while its child is still alive.
    root.teardownController()
    // Teardown releases every provider id: the surfaces close over this
    // root, so a survivor would keep a dead confirm closure.
    root._releaseMenuProviders()
    SurfaceClaim.releaseOwner(root)
    Registry.unregister("appLauncher")
  }

  // --- open/close/toggle ---

  // True while an open is waiting for the clipboard suggestion's stat
  // verdict before its first paint (see open()). The window stays hidden
  // until the verdict lands or the timeout fires, so the suggestion is
  // ready before any UI is drawn and no row is added, dropped or resized
  // after the open.
  property bool _openWaiting: false

  function open() {
    if (root.visible) return true
    // A second summon while the first is still waiting on its stat probe
    // is the same open, not a second one: starting another probe would
    // abort the run the first is waiting for (seq guard) and hang both
    // on the timeout.
    if (root._openWaiting) return true
    // Demand first: without a controller there is no window to show, so
    // the claim must not be taken and `visible` must not be set.
    const ctrl = root._demand()
    if (ctrl === null) return false
    closeSettle.stop()
    // A local clipboard target whose verdict is not settled (no cache, or
    // a revalidate in flight) holds the open: flipping visible now would
    // paint the provisional row first and land the verdict a probe later
    // behind it - the window growing or shrinking to fit a suggestion that
    // was known before the summon. Non-local targets (url/uri), a null
    // target and a settled verdict answer synchronously with zero added
    // latency; only the unsettled local case waits, bounded by
    // openProbeTimeout below.
    if (ctrl.clipProbePending()) {
      root._openWaiting = true
      openProbeTimeout.restart()
      return true
    }
    // Compute before showing: the panel's open path installs panel.rows
    // synchronously on the visible flip, so the row model must already be
    // the open's (fresh usage, fresh clipboard target) before it flips.
    // Computing after the flip painted the stale set first and landed the
    // fresh one a turn later behind it - the window visibly growing to fit
    // a suggestion that was known before the summon.
    root._openCompute()
    root.visible = true
    // Claimed once the panel is up, not before: the stored closer is
    // close, which refuses to run while `visible` is false, so a claim
    // taken earlier would install a closer that provably does nothing and
    // leave a claim nobody can retire if the rest of the opening throws.
    root._claimToken = SurfaceClaim.claim("appLauncher", root.close, root)
    return true
  }
  // The waiting probe settled (or the timeout fired): compute with the
  // settled verdict and show. The finishing compute skips the force
  // revalidate - the verdict it reads just landed, so revalidating here
  // would start a second probe and replay the very post-open correction
  // the wait just avoided.
  function _finishOpen() {
    if (!root._openWaiting) return
    root._openWaiting = false
    openProbeTimeout.stop()
    if (root.visible) return
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.onOpenedSettled()
    root.visible = true
    root._claimToken = SurfaceClaim.claim("appLauncher", root.close, root)
  }
  function _openCompute() {
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.onOpened()
  }

  function close() {
    // A close inside the open wait retires the pending open before it ever
    // painted: no claim was taken and no window mapped, so there is nothing
    // to hide or release. The controller stays warm (usage, index and the
    // verdict the probe just landed all serve the next summon) - it is
    // resident, so there is no idle grace to arm.
    if (root._openWaiting) {
      root._openWaiting = false
      openProbeTimeout.stop()
      return
    }
    if (!root.visible) return
    // The tree stays attached while the window hides: panel items are
    // destroyed only with their Loader, never against a torn-down surface
    // (see the Loader note in AppLauncherView - unloading here races the
    // hide and segfaults in derefWindow after close). The card vanishes with the
    // press instead of fading with the scrim; that pop is the price of
    // never stranding a delegate on a dead window.
    root.visible = false
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
    // The window fades out over Ui.fastMs; the close settle outlasts the
    // fade by a beat and then recomputes the rows back to idle while still
    // hidden. The controller itself stays resident - a close never tears
    // the tree down, so the next summon repaints from a warm index.
    closeSettle.restart()
  }

  function toggle() {
    if (root._openWaiting) {
      root.close()
      return
    }
    root.visible ? root.close() : root.open()
  }

  // Reset to a fresh summon: normal mode, no query. View state only, so a
  // close can reset it with no controller at all. Deliberately no
  // recompute: this runs hidden (close path, reload verb), and rebuilding
  // the rows here would replay the open layout behind the close fade -
  // with a query typed, the card visibly jumps from the filtered list
  // back to the full one on every close. Freshness is covered where the
  // rows are actually read: open() recomputes via onOpened(), and the
  // reload verb recomputes via discoverPlugins().
  function reset() {
    root.mode = "normal"
    root.modePluginId = ""
    root.modePlugin = null
    root.entry = ""
  }

  onVisibleChanged: {
    persist.visible = visible
    if (root.visible) return
    // A reload replay drives the flag false and true again in one tick, and
    // that is not a close: skipping the reset is what keeps the query the
    // reload just restored on screen.
    if (root._replaying) return
    Qt.callLater(root.reset)
  }

  // Set only while the reload replay drives visible false and true again.
  property bool _replaying: false

  // --- input pipeline (single route from the search bar) ---

  function submit(text) {
    root.entry = text
    root._recompute()
  }

  // Switch into a plugin's mode. `payload` carries whatever the user had
  // typed when they hit the prefix (the search field hands its content
  // over) so a query survives the switch. Only enabled plugins own
  // prefixes; unknown or disabled prefixes are ignored silently.
  function enterMode(prefix, payload) {
    if (root.mode !== "normal") return
    const ctrl = root._controller
    if (ctrl === null) return
    const plugin = ctrl.pluginForPrefix(prefix)
    if (plugin === null) return
    root.mode = plugin.type
    root.modePluginId = plugin.id
    root.modePlugin = plugin
    root.entry = String(payload ?? "")
    root._recompute()
  }

  function exitMode() {
    if (root.mode === "normal") return
    root.mode = "normal"
    root.modePluginId = ""
    root.modePlugin = null
    root._recompute()
  }

  // Backspace on an empty field leaves the mode.
  function stepBack() {
    if (root.mode !== "normal") {
      root.exitMode()
      return
    }
  }

  // Row activation, debounced on the facade (see lastActivateAt) and
  // dispatched by the controller, which owns what every kind means.
  function activate(row) {
    if (!row || row.kind === "separator") return
    const now = Date.now()
    if (now - root.lastActivateAt < 300) return
    root.lastActivateAt = now
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.activate(row)
  }

  function requestDelete(row) {
    if (!row || row.kind !== "app" || row.removable !== true) {
      return
    }
    root.pendingDelete = row
  }

  function confirmDelete() {
    const row = root.pendingDelete
    if (!row || !row.app || !row.app.id) return
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.confirmDelete(row)
    root.pendingDelete = null
  }

  // --- recompute ---
  //
  // Every input event ends here. With no controller there is nothing to
  // recompute - the row projection is already empty - and the call is a
  // no-op rather than an error, so a reload that restores a query without
  // a controller cannot throw.

  function _recompute() {
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.recompute()
  }

  // --- plugin capability boundary ---
  //
  // The grant table, the policy view and the host operations behind it stay
  // in the resident file, because this is the boundary the security
  // contract pins: a plugin's authority is decided here and nowhere else.
  // The controller decides WHEN a plugin exists and evaluates its main.js;
  // everything a granted plugin can reach is spelled below.
  //
  // The host table only binds the names a grant actually names, so a denied
  // operation has nothing to call even if the policy were asked for it.
  // The read and the clock probes forward to the controller, so the facade
  // holds no FileView and no Process for a plugin's sake.

  function _pluginHostFor(cfg) {
    return {
      id: () => cfg.id,
      configDir: () => Paths.xdgConfigHome + "/vibranium",
      pluginDir: () => cfg.dir,
      setting: key => Settings.value(key),
      shellQuote: s => LauncherLib.shellQuote(String(s)),
      stripJsonc: raw => LauncherLib.stripJsonc(String(raw)),
      requestTime: tz => root._requestTime(tz),
      cachedTime: tz => root.timeCache[tz],
      // The PATH pair, the same two-step shape as the clock pair and the
      // fetch pair: ask the controller to scan, then read what it cached. A
      // plugin holding both learns what is runnable and nothing about where
      // it lives - no directory list, no path to any one of them. A plugin
      // holding only the read half answers from whatever scan already landed.
      requestBinaries: () => root._requestBinaries(),
      cachedBinaries: () => root.binariesCache,
      // The fetch pair is a two-step, exactly like the clock pair above:
      // ask the controller to fetch, then read what it cached. A plugin never
      // sees a socket, a response object or a callback - it asks for a URL
      // and reads a string, and the controller owns both the request and the
      // row recompute that publishes the answer. `network` stays UNBOUND on
      // purpose: a raw fetch would hand a plugin the whole response stream,
      // and nothing shipped needs one. This pair is the narrow shape.
      requestNet: (url, timeoutMs) => root._requestNet(url, timeoutMs),
      // LauncherLib.netBody, not the cache entry itself: what a plugin is
      // handed is a BODY STRING. Handing over the record instead reaches the
      // plugin as "[object Object]", which parses as no rates at all - so the
      // row would read "rate table unavailable" however good the fetch was.
      cachedNet: url => LauncherLib.netBody(root.netCache[String(url ?? "")]),
      // The watcher's verdict, read live: full internet until the first
      // poll proves otherwise, so a plugin asking before the watcher
      // lands gets the optimistic answer and never a startup flash.
      // In-process like the other cached reads, hence a default grant
      // beside cachedNet rather than a named one.
      cachedOnline: () => Core.Connectivity.online,
      // The cache pair, split on read versus write. Reading is an in-process
      // read of $VIBRANIUM_CACHE/shell.json, which this process already holds,
      // so it is a default grant beside cachedNet. Writing reaches the disk,
      // so it is named per plugin - and confined to the plugin's own namespace
      // by _cacheSectionFor below, because that file is shared with the audio
      // level and the update mirror and "audio" is not a plugin's to rewrite.
      cachedSection: name => {
        const s = _cacheSectionFor(cfg, name)
        return s === "" ? null : ShellCache.section(s)
      },
      setCacheSection: (name, obj) => {
        const s = _cacheSectionFor(cfg, name)
        return s === "" ? false : ShellCache.setSection(s, obj)
      },
      // Silent no-op: plugins keep the api.log contract, and the shell does
      // not emit custom logs.
      log: () => {},
      // Arbitrary file read: the launcher needs it to load the manifest and
      // the source, but a plugin only gets it when its root's grant names
      // it, and even then only as a whole-file text read.
      readFile: path => root._readFileText(path),
      // A granted plugin still hands over shell source, so this capability
      // is a source surface by construction and is named as one in
      // PluginPolicy.js - not a data-only one.
      execDetached: script => root.execDetached(["/bin/sh", "-c", script])
    }
  }

  // The one namespace rule the cache operations carry: a plugin reads and
  // writes sections that begin with its OWN id, and anything else is refused
  // rather than repaired into a nearby name. The id comes from the config the
  // host table was built for, so a plugin cannot reach a namespace that is not
  // its own by passing a different name.
  //
  // The returned name is a KEY in one JSON document, never a path: the shell
  // cache is a single file whatever the section is called, so a name with a
  // slash in it is an odd key rather than a traversal. That is why the check
  // is a prefix and not a filename rule.
  function _cacheSectionFor(cfg, name) {
    const raw = String(name === undefined || name === null ? "" : name)
    if (raw.indexOf(String(cfg.id) + "-") !== 0) return ""
    return raw
  }

  // Capability grants per discovery root, named here because the launcher
  // is what hands a plugin an API and therefore what owns the decision.
  // The built-in root holds plugins that ship with the shell: their
  // "copy the result" and "open this URL" rows are part of the launcher,
  // so the privilege they need is granted explicitly and visibly. The user
  // root starts with nothing outside PluginPolicy's default, in-process
  // set - a plugin dropped in ~/.config reaches no file, no process, no
  // socket, no clipboard and no secret unless this table names it. A
  // manifest may narrow what its root holds (see _grantsFor) and can never
  // widen it.
  readonly property var _builtinGrants: ["execDetached"]
  readonly property var _userGrants: []
  // Per-plugin additions for the shipped root, keyed by plugin id. The
  // currency engine needs to read a rate document, and the fetch pair is
  // how it does that (see _pluginHostFor). Naming the plugin here rather
  // than adding the request to _builtinGrants is the point: the table above is
  // what every shipped plugin holds, so widening it would hand a socket to
  // the calculator, the clock and the unit converter as well. A
  // shipped plugin is in this repository, so the entry is a reviewable list
  // of which rows may leave this process - not a blanket grant.
  // Each entry names only the REQUEST half of its pair. cachedNet and
  // cachedBinaries are already default grants, so naming either here would
  // claim a capability the posture grants anyway. What this map buys is the
  // socket and the scan.
  //
  // `setCacheSection` is the exception to that "request half only" rule, and
  // for a stated reason: it is not a read half at all, it is the write end of
  // a document the whole shell shares. Naming it here confines the ability to
  // write a cache section to the one shipped plugin with a reason to - fx,
  // whose bare-query list is ordered by what the user actually picks - and the
  // namespace rule above confines it to fx's own section.
  readonly property var _builtinGrantsByPlugin: {
    "fx": ["requestNet", "setCacheSection"],
    "binary": ["requestBinaries"]
  }

  // The grant set for one discovered plugin. This file owns both tables and
  // the root that picks between them; the policy applies them, so the
  // containment test that decides "shipped or user" lives where the JS suites
  // can drive it. A manifest that declares `capabilities` narrows whatever
  // the table held and can never widen it.
  function _grantsFor(cfg) {
    return PluginPolicy.grantsForRoot(root._builtinRoot, cfg.dir,
      root._builtinGrants, root._userGrants, cfg.caps,
      root._builtinGrantsByPlugin, cfg.id)
  }

  function _apiFor(cfg) {
    // The plugin's view is the policy instance, not a hand-written object:
    // it carries exactly the granted operations, a denied one is absent
    // rather than throwing, and anything a bound operation throws is
    // redacted by the policy before it reaches the plugin or a log.
    const view = PluginPolicy.createPolicy(root._grantsFor(cfg), root._pluginHostFor(cfg))
    cfg._view = view
    cfg._denied = view.deniedOperations()
    return view
  }

  // Only the built-in root has to be named here: a plugin's grant table is
  // chosen by which root its directory came from, and the user root is the
  // empty one. The scan itself, and the user root it scans, are the
  // controller's.
  readonly property string _builtinRoot: Paths.vibraniumHome
    + "/shell/features/launcher/plugins"

  // The granted file read, forwarded: the reader is the controller's, so a
  // plugin only reaches one FileView and the facade holds none.
  function _readFileText(path) {
    const ctrl = root._controller
    if (ctrl === null) return null
    return ctrl.readPluginFile(path)
  }

  // The granted PATH scan, forwarded for the same reason. The verdict cache
  // is projected above, so cachedBinaries() answers with no controller and
  // only the request half needs one.
  function _requestBinaries() {
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.requestBinaries()
  }

  // The granted clock probe, forwarded for the same reason. The verdict
  // cache is projected above, so cachedTime() answers with no controller.
  function _requestTime(tz) {
    const ctrl = root._controller
    if (ctrl === null) return
    ctrl.requestTime(tz)
  }

  // The granted fetch, forwarded for the same reason. The URL is validated
  // here rather than in the controller because this is the boundary the
  // security contract pins: only https may leave the process, and a plugin
  // that asks for anything else gets no request at all rather than a
  // rewritten one. The body cache is projected above, so cachedNet()
  // answers with no controller.
  // The path is cut at 32 characters before it reaches a line: a PLUGIN
  // supplies this url, and an API key pasted into a query string would
  // otherwise appear in full. The bound is applied here rather than in the
  // formatter because that is where the untrusted string enters the shell.
  readonly property int _netLogPathLimit: 32

  function _requestNet(url, timeoutMs) {
    const u = String(url ?? "")
    if (!/^https:\/\//i.test(u)) return
    const ctrl = root._controller
    if (ctrl === null) return
    // The scheme is named and the rest is cut, so a reader can tell WHICH
    // plugin endpoint was asked for without the line carrying a query string.
    const cut = u.length > root._netLogPathLimit
      ? u.slice(0, root._netLogPathLimit) + "…(" + u.length + ")"
      : u
    Log.info("plugin request " + cut)
    Log.debug("request " + cut + " (" + u.length + " chars, bounded to " + root._netLogPathLimit + ")")
    ctrl.requestNet(u, timeoutMs)
  }

  // --- detached execution ---
  //
  // One guarantee for every plugin action: the command survives launcher
  // shutdown. Quickshell.execDetached is Quickshell's native detached-exec
  // (equivalent to Process.startDetached) - it forks the command into its
  // own session and it is not killed when the shell quits or reloads. No
  // nesting layer of bash / setsid on our side: commands are passed as a
  // plain argv array, and only genuinely shell-y invocations (the wl-copy
  // pipe) go through a single `sh -c`.
  //
  // It lives here so a granted plugin and every launch path share one exit
  // point, and so the facade - not a controller that comes and goes - owns
  // the one call that must outlive the launcher.

  function execDetached(command) {
    try {
      Quickshell.execDetached(Array.isArray(command) ? command : [String(command)])
    } catch (e) {
    }
  }

  // --- demand / teardown ---
  // Demand the resident controller, building it if the prewarm has not
  // landed yet. Repeated callers - a held key, a second IPC verb, the
  // panel's own close - all land here, and every path out (refused
  // lease, failed construction, unload) drops the lease again, so a
  // refused or failed caller leaves the next one a clean unit.
  // The controller is built once, shortly after boot, and stays resident
  // after that: the usage read, the index build, the plugin scan and the
  // desktop-entry snapshot all land before the first summon, so the first
  // open paints the app list on frame one instead of an empty window that
  // fills in a moment later. A demand that arrives before the prewarm
  // finished still builds it inline; a failed build retries on the timer
  // below rather than failing the session's opens.
  property bool _prewarmed: false

  function _prewarm() {
    if (root._prewarmed) return
    const ctrl = root._demand()
    if (ctrl !== null) {
      root._prewarmed = true
      return
    }
    if (root.controllerState !== "failed") prewarmRetry.restart()
  }

  function _demand() {
    if (root.controllerState === "ready" && root._controller !== null) return root._controller
    const result = UnitGate.ensure(root.unitId, root.gateOwner)
    if (result === undefined || result === null || result.ok !== true) {
      // A blocked, failed or unregistered unit still hands back a lease
      // for two of those three; give it straight back so the record
      // cannot collect owners for a demand that never loaded.
      if (result !== undefined && result !== null && result.lease !== undefined && result.lease !== null)
        root._lease = result.lease
      root._dropLease()
      root._setState(result !== undefined && result !== null && result.state === "failed" ? "failed" : "unavailable",
        result !== undefined && result !== null && result.state === "failed" ? "unit" : "gate")
      return null
    }
    if (result.lease !== root._lease) {
      root._lease = result.lease
      // Retained, not merely held: a stray single release (a dropped
      // claim, a failed caller unwinding) must not be able to drop the
      // unit under a live panel.
      UnitGate.retain(result.lease)
    }
    root._setState("loading")
    controllerLoader.active = true
    if (root._controller === null) {
      root._unloadFor("unavailable", "load")
      return null
    }
    if (root._controller.startupError !== "") {
      // A Loader cannot raise a construction error to its caller, so the
      // controller reports it and the facade answers error:<code> and
      // unloads: the next caller starts from an unloaded unit.
      root._unloadFor("failed", root._controller.startupError)
      return null
    }
    root._constructions++
    root._setState("ready")
    return root._controller
  }

  // Drop the controller and the lease, then state the outcome. The flag is
  // what keeps the teardown the gate performs on the way out - it runs
  // teardownController() from inside the release - from restating
  // "unloaded" in the middle of a demand that is about to report why it
  // failed, so the state sequence a consumer sees is the facade's own.
  property bool _unwinding: false

  function _unloadFor(next, code) {
    root._unwinding = true
    root._unload()
    root._unwinding = false
    root._setState(next, code)
  }

  // A demand that does not open the panel reaches the same resident tree
  // the prewarm built - the usage read, the index, the plugin scan, the
  // models, the processes and the watcher. This is the one place that
  // policy lives: the settings menu's eight toggles, the Registry
  // clear-history writer and the pluginSet/reload/clearHistory verbs all
  // reach the controller through here and nothing else. Nothing here hands
  // the tree back: the controller stays resident once built.
  function _demandTransient() {
    return root._demand()
  }

  // Drop the controller and the lease without touching the reported state.
  // A caller that is about to answer unavailable or failed unwinds through
  // here, so the state it reports is the last one a consumer sees instead of
  // flapping through "unloaded" on the way there.
  function _unload() {
    closeSettle.stop()
    const held = root._lease !== null || controllerLoader.item !== null
    controllerLoader.active = false
    root._dropLease()
    return held
  }

  // Idempotent and callable with nothing loaded: Boot's unit teardown
  // hook and the close settle both land here, and the second call is a
  // no-op rather than a double release.
  function teardownController() {
    const held = root._unload()
    if (!root._unwinding) root._setState("unloaded")
    return held
  }

  // The gate's teardown hook drops this owner's whole lease set in one
  // call, so the ensure and the retain that came with it go together and
  // a lost release cannot leave the record counting an owner nobody holds.
  function _dropLease() {
    if (root._lease === null) return false
    root._lease = null
    return UnitGate.releaseOwner(root.gateOwner) > 0
  }

  function _setState(next, code) {
    const detail = code || ""
    if (root.controllerState === next && root.controllerError === detail) return
    root.controllerState = next
    root.controllerError = detail
    // The unit's own ready probe reads controllerReady, and nothing polls
    // an on-demand unit, so the record is settled here instead: the gate
    // must not sit in "starting" once the controller is up.
    if (next === "ready") UnitGate.refresh(root.unitId)
  }

  // Defined answer for every verb while the controller is not there, so
  // an IPC caller learns why instead of getting a silent no-op.
  function _unavailableVerb() {
    if (root.controllerState === "failed") return "error:" + (root.controllerError !== "" ? root.controllerError : "controller")
    if (root.controllerState === "loading") return "loading"
    return "unavailable"
  }

  // --- panel body: windows live here, not under the controller ---
  // The view is a facade child so its windows outlive every controller
  // unload (a unit teardown still unloads the controller, e.g. through
  // Boot's hook). Parked under the controller, each close destroyed
  // windows WITH their panel trees, and the deferred half of that
  // teardown landed in derefWindow on a dead surface (SIGSEGV after
  // close).
  // Every panel reads the facade for the state it draws; nothing below
  // names the controller, so the unload cascade only ever takes data.
  AppLauncherView {}

  // The controller, and nothing else: a Loader the prewarm activates
  // shortly after boot. Windows and panels live above, outside this
  // Loader, for the reason stated there.
  Loader {
    id: controllerLoader
    active: false
    sourceComponent: controllerComp
  }

  Component {
    id: controllerComp

    AppLauncherController {}
  }

  // Retries the boot prewarm until the gate lets the controller build:
  // a demand that lands while a dependency is still settling reports
  // unavailable, and the next tick tries again instead of leaving the
  // session's opens cold. Stops on the first success or a hard failure.
  Timer {
    id: prewarmRetry
    interval: 500
    repeat: false
    onTriggered: root._prewarm()
  }

  // The exit fade is Ui.fastMs long; the settle outlasts it by a frame
  // and a half plus one frame window, so the window is fully faded and
  // the UI settled before the rows go idle. Single one-shot: a two-phase
  // split would do nothing between its phases (phase one only
  // restarts phase two), and the panels staged around it stay
  // attached for the window's whole life (see the Loader note in
  // AppLauncherView). The controller stays resident - the settle only
  // recomputes. Bounded, and an open that arrives first stops it.
  Timer {
    id: closeSettle
    interval: Ui.fastMs + 200
    repeat: false
    onTriggered: {
      // Settle the row model back to idle while still hidden: close reset
      // the query without recomputing (recomputing there would replay the
      // open layout behind the close fade), so the live rows are still the
      // filtered set from before the close. Recomputing here - window gone,
      // nothing to jump - publishes idle to the facade, so the next open
      // starts from idle instead of rebuilding the wall from a filtered
      // set it immediately discards.
      const ctrl = root._controller
      if (ctrl !== null && !root.visible) ctrl.recompute()
    }
  }

  // Bounds the open wait above: a local stat probe normally lands in a few
  // milliseconds, and a hung probe must never pin the launcher shut. On
  // timeout the open completes with whatever verdict exists (provisional
  // row or withheld row) - the same paint the old code produced, minus
  // the indefinite hang.
  Timer {
    id: openProbeTimeout
    interval: 350
    repeat: false
    onTriggered: root._finishOpen()
  }

  // --- ipc ---
  //
  // Every client delegates here; `status` doubles as the unit's liveness
  // probe, so it must answer even before the first use and after a
  // teardown. Every verb answers a string: "ok", a JSON payload, or one of
  // loading / unavailable / error:<code> while the controller is gone.

  IpcHandler {
    target: "appLauncher"
    function help(command: string): string {
      return UnitIpc.help("appLauncher", "App launcher", "application search + usage-ranked results + plugins", [
        { name: "clearHistory", help: "clear usage history" },
        { name: "close", help: "hide the launcher" },
        { name: "hasHistory", help: "any recorded usage?" },
        { name: "open", help: "show the launcher" },
        { name: "plugins", help: "list launcher plugins" },
        { name: "pluginSet", help: "(id, json) update one plugin" },
        { name: "reload", help: "rescan applications + plugins" },
        { name: "toggle", help: "show/hide" },
        { name: "usage", help: "dump usage counts" },
      ], command)
    }
    function ping(): string { return "pong" }

    function toggle(): string { return root._toggleVerb() }

    function open(): string { return root._openVerb() }

    function close(): string {
      root.close()
      return "ok"
    }

    function status(): string {
      const summary = root._pluginSummary()
      const plugins = []
      for (let i = 0; i < summary.length; i++) {
        const p = summary[i]
        plugins.push({
          id: p.id,
          type: p.type,
          keyword: p.keyword,
          enabled: p.enabled,
          broken: p.broken,
          // The capability posture, so a status read can show what a
          // plugin may reach instead of leaving it implicit.
          granted: p.granted,
          denied: p.denied
        })
      }
      const unit = UnitGate.state(root.unitId)
      return JSON.stringify({
        visible: root.visible,
        mode: root.mode,
        query: root.entry,
        count: root.results.length,
        searchFocused: root.effectiveSearchFocused,
        controller: root.controllerState,
        controllerError: root.controllerError,
        constructions: root.constructions,
        owners: unit === null ? 0 : unit.ownerCount,
        // Per-group provenance, so an empty plugins list reads as "not
        // collected yet" instead of "this launcher has no plugins".
        reads: root._readStates(),
        plugins: plugins
      })
    }

    function plugins(): string {
      if (!root.pluginsKnown) return "unavailable"
      const summary = root._pluginSummary()
      const out = []
      for (let i = 0; i < summary.length; i++) {
        const p = summary[i]
        out.push({
          id: p.id,
          name: p.name,
          description: p.description,
          keyword: p.keyword,
          type: p.type,
          enabled: p.enabled
        })
      }
      return JSON.stringify(out)
    }

    // pluginSet "actions" true
    function pluginSet(id: string, json: string): string {
      let v
      try {
        v = JSON.parse(json)
      } catch (e) {
        return "error: invalid JSON value"
      }
      const ctrl = root._demandTransient()
      if (ctrl === null) return root._unavailableVerb()
      return ctrl.setPluginEnabled(id, v) ? "ok" : "error"
    }

    function reload(): string {
      const ctrl = root._demandTransient()
      if (ctrl === null) return root._unavailableVerb()
      root.reset()
      ctrl.discoverPlugins()
      return "ok"
    }

    function clearHistory(): string {
      const ctrl = root._demandTransient()
      if (ctrl === null) return root._unavailableVerb()
      return ctrl.clearUsageHistory() ? "ok" : "error: already empty"
    }

    // A read is a fact or the documented sentinel, never a default: before
    // any controller has published the cache, the answer is "unavailable"
    // and not "false", and afterwards it is the published one - which is
    // the same value with the panel up and 200ms after it closed.
    function hasHistory(): string {
      if (!root.usageKnown) return "unavailable"
      return root.hasUsageHistory ? "true" : "false"
    }

    function usage(): string {
      if (!root.usageKnown) return "unavailable"
      return JSON.stringify(root.usageMap)
    }
  }

  // --- plugin summary for the read-only verbs ---
  // Plain records from the controller while it is up, the published
  // projection after it. status() must answer an object either way, so an
  // uncollected list is [] with reads.plugins reporting it as such.
  function _pluginSummary() {
    const ctrl = root._controller
    if (ctrl === null) return root.pluginRows
    return ctrl.pluginSummary()
  }

  function _openVerb() {
    root.open()
    if (root.controllerState === "ready" && (root.visible || root._openWaiting)) return "ok"
    return root._unavailableVerb()
  }

  // open is the shell's toggle key, so both halves answer "ok"; the
  // opening half answers the controller's state instead when the panel
  // could not be built.
  function _toggleVerb() {
    const wasVisible = root.visible || root._openWaiting
    root.toggle()
    if (wasVisible) return "ok"
    return root.controllerState === "ready" && (root.visible || root._openWaiting) ? "ok" : root._unavailableVerb()
  }
}

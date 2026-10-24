pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.menu
import qs.features.clipboard
import "CalcLib.js" as CalcLib
import "LauncherLib.js" as LauncherLib
import "../../common/collections/BoundedCache.js" as BoundedCache

// Demand-loaded child of the AppLauncher facade: every piece of expensive
// launcher work lives here and nothing here survives a close. The usage-data
// load, the desktop-entry index build, the plugin directory scan, the plugin
// hosts, the models, the stat/clock/launch processes and the whole panel tree
// are constructed with this object and go with it, so a shell that never
// opens the launcher never pays for any of it - which is the whole point of
// the unit being first_use in Boot's catalog.
//
// The facade is the only writer of this object's lifetime: it arrives
// through a Loader, it leaves the same way. Nothing here reaches into the
// gate and no IPC handler is declared here, so no verb can construct a
// second controller and the target stays single; the public read surface
// lives on the facade as a projection of this one.
//
// The launcher's view state is NOT here: mode, the query and visibility are
// the facade's, so a reload or a close can reset them without a controller,
// and this object reads them (AppLauncher.mode / .entry / .visible) exactly
// the way PassController reads Pass.visible for its window.
//
// WHAT IS NOT HERE
//
// The index, usage and plugin MODEL, and the parsing and argv behind the
// filesystem work, live in LauncherLib.js: what a directory means, what a
// druncache byte means, what an Exec line means, and the line formats the
// three probes speak. What is here is the shell those values move through -
// the FileViews, the three Processes, the debounce timer, the plugin hosts,
// the row recomputation, the launch dispatch and the panel tree. A library
// that owned a FileView or a Process could not be unit-drivable, and a
// controller that re-derived the model would own the same rule twice.
Item {
  id: root

  // Set when construction itself could not finish, so the facade can answer
  // "error:<code>" instead of reporting a controller that is not there.
  // Every later demand re-reads it, so a failed first caller cannot leave a
  // half-built controller behind for the next one.
  property string startupError: ""

  // --- indexes ---

  // Desktop entries snapshotted into plain records (rebuilt when
  // applications change or category visibility flips).
  property var appIndex: []
  // Change-detector of the last index build: entry count + sort method +
  // usage revision. Rebuilds skip when it is unchanged (warm summon fast
  // path).
  property string _indexFp: ""
  // Monotonic revision of usageMap, moved by every write to it (see
  // _setUsageMap). The gate reads this rather than the map: fingerprinting
  // the map would serialise every key and count on the warm-summon path
  // and after every usage bump, to answer a question whose only outcome is
  // "did the map move". A counter is O(1) in the map's size, and two
  // different maps cannot land on the same revision.
  property int _usageRev: 0

  // Rebuild the desktop-entry index: DesktopEntries' live list is
  // snapshotted into plain records through LauncherLib.buildAppIndex
  // (exclusion filters, search haystacks, badges and base order live
  // there). Runs while this controller constructs, on applicationsChanged
  // and when the sort method flips; frequency mode ranks the idle view by
  // druncache. The skip-if-unchanged detector is the library's too - the
  // warm-summon fast path, and its inputs are named there so an input
  // it forgot could not read as "unchanged" and freeze a stale order. The
  // usage term is the revision, so every map this index is ranked against
  // reaches the gate as a distinct value.
  function _rebuildAppIndex() {
    const entries = DesktopEntries.applications ? DesktopEntries.applications.values : []
    const fp = LauncherLib.indexFingerprint(entries ? entries.length : 0, root.sortMethod, root._usageRev)
    if (fp === root._indexFp) return
    root._indexFp = fp
    root.appIndex = LauncherLib.buildAppIndex(entries, root.sortMethod, root.usageMap)
  }

  // --- publishing the reads the facade serves ---
  //
  // The facade keeps answering the usage cache, its emptiness, the plugin
  // records and the per-plugin enablement after this object is gone, so a
  // caller with the panel closed reads the same answer the panel read. Both
  // calls hand over plain values: a bool, a map and a record list, which is
  // the whole of the surface the facade projects.
  function _publish() {
    AppLauncher._publishUsage(root.hasUsageHistory, root.usageMap)
  }

  function _publishPlugins() {
    AppLauncher._publishPlugins(root.pluginSummary(), root.pluginToggles())
  }

  // Settings-driven behavior flags. Shell-only options (full-path keyed,
  // no bash env projection) - the launcher reads them straight from the
  // store.
  readonly property bool showDescriptions: Settings.value("shell.launcher.showDescriptions") === true
  readonly property bool showIcons: Settings.value("shell.launcher.showIcons") !== false
  readonly property bool showBadges: Settings.value("shell.launcher.showBadges") !== false
  readonly property bool showClipSuggestion: Settings.value("shell.launcher.showClipboardSuggestion") !== false
  readonly property string sortMethod: Settings.value("shell.launcher.sortMethod") === "frequency" ? "frequency" : "alphabetical"
  readonly property bool autoSelect: Settings.value("shell.launcher.autoSelect") === true
  // usage -> count (plain number)
  property var usageMap: ({})

  // What counts as a change to usageMap, in one place.
  //
  // _sameUsageMap is the test a druncache read applies: the same keys
  // holding the same values, order irrelevant, so a read that lands the
  // map this controller already holds is not a change to it. The first
  // open reads the cache twice (this controller's construction is its own
  // warm-up, and onOpened rereads), and a change recorded on the second
  // read would rebuild the whole index on every summon - the one work the
  // rebuild gate exists to skip.
  //
  // _setUsageMap is the writer every other change goes through, and moving
  // the revision with the map is what makes the gate exact: a write that
  // skipped it would leave the index ranked against a map the gate never
  // saw move, which is a stale order with no rebuild left to correct it.
  function _sameUsageMap(a, b) {
    if (a === b) return true
    if (!a || typeof a !== "object" || !b || typeof b !== "object") return false
    const keys = Object.keys(a)
    if (keys.length !== Object.keys(b).length) return false
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i]
      if (!Object.prototype.hasOwnProperty.call(b, k)) return false
      if (a[k] !== b[k]) return false
    }
    return true
  }

  function _setUsageMap(map) {
    root.usageMap = map
    root._usageRev++
  }

  // Whether druncache contains at least one entry. Kept live via a
  // file watcher so the settings menu can hide the "Clear usage
  // history" row when empty without shell boilerplate. Updated both
  // from in-memory mutations and from disk changes, and published to
  // the facade on every change (see _publish) so a caller with the
  // panel closed reads the same answer the watcher just settled on.
  property bool hasUsageHistory: false

  // Sub-line placeholder for apps without a description while inline
  // descriptions are enabled.
  readonly property string noDescriptionText: "This app does not have description"

  // Result rows consumed by the panel; rebuilt wholesale by recompute().
  property var results: []
  // Matched/total are both fed by LauncherLib.filterCounter() inside
  // recompute() - the full-pool hit count and the pool size. Never
  // derived from results, which are display-capped; an unfiltered pool
  // must read "3085/3085", not "100/3085".
  property int matchedCount: 0
  property int totalCount: 0

  // Results fingerprint: index/plugin revisions pinned at the
  // last assignment. A recompute that changes nothing reuses the live
  // array (no signal, no panel work) instead of rebuilding the world.
  // Bumped wherever row-building inputs are reminted.
  property string _resultsFp: ""
  property int _pluginsRev: 0

  // Row-set equality for change-aware assignment - single definition
  // lives in LauncherLib (shared with the panel's patch paths).
  function _rowsEqual(a, b) {
    return LauncherLib.rowsEqual(a, b, false)
  }

  // Openable target resolved from the newest clipboard entry:
  // { kind: "url" | "uri" | "local", value, basename, hint } or null. A local
  // target carries in `hint` the folder/file verdict the entry's own capture
  // settled ("dir" | "file"); the row still withholds until the stat probe
  // verifies it, so the hint never paints provisionally. The suggestion row
  // rides above the idle app list; refreshed on open and on clipboard writes
  // while visible.
  property var clipTarget: null

  // Filesystem verdicts live on the facade (AppLauncher.statCache), not here:
  // the controller comes and goes with every open, and a teardown that dropped
  // them would make the next open re-render a long-deleted target from its
  // copy-time hint before the fresh probe corrects it. All reads and writes
  // below go through AppLauncher.statCache so the verdicts survive the gap.

  // The executable names on PATH behind the binary-launch fallback row:
  // { names: [...], at: ms }, or null when no scan has landed yet. Fed by
  // requestBinaries() on demand; entries older than _binTtlMs rescan.
  // Replaces the record wholesale on every settle, which is what lets a
  // plugin rebuild its lookup by reference (see the binary plugin) instead of
  // re-folding a few thousand names on each keystroke.
  property var binCache: null
  // PATH moves when a package is installed or removed, so this is far longer
  // than the clock's TTL: a stale executable name costs one query that
  // offers nothing, and rescanning walks every directory on the user's PATH.
  readonly property int _binTtlMs: 300000

  // Live clock readings for "time in <city>" rows: timezone ->
  // { time: "14:32" or "01:00 PM", code: "CEST", offset: "+0200",
  // date: "Fri 11 Sep", at: ms }. Fed by one shared TZ=date probe (see
  // _requestTime); entries older than _timeTtlMs re-probe on demand and tick
  // while visible.
  property var timeCache: ({})
  // Zone waiting for the probe while another zone's run is in flight.
  // Serializes requests so an aborted run can never attribute its output
  // to the wrong timezone.
  property string _timePendingZone: ""
  readonly property int _timeTtlMs: 15000

  // Response bodies for the "value <CUR> in <CUR>" rows: URL ->
  // { body, at: ms }. Fed by requestNet() on demand; entries older than
  // _netTtlMs re-fetch. Mirrors the clock cache, and for the same reason: a
  // plugin's items() runs on every recompute, so the request has to be
  // TTL-guarded or a rate row would re-arm its own fetch forever.
  property var netCache: ({})
  // URLs with a request in flight, so a second items() for the same URL
  // joins the first rather than opening a second socket.
  property var _netPending: ({})
  // Live net handles, so teardown can retire them. A handle is a plain JS
  // object and is therefore NOT parented to this controller: nothing about
  // destroying the controller reaches it, so the retirement has to be
  // explicit in onDestruction. Pruned on every new request rather than on
  // settle, because _settleNet is reached by url and not by handle.
  property var _netLive: []
  // A GOOD body is worth keeping a long time: the provider republishes once a
  // day, so ten minutes sits far inside its own cadence and a row never goes
  // stale under the user.
  //
  // A FAILED body is worth nothing, and must not be latched. One TTL for both
  // meant a fetch that failed while offline kept answering "rate table
  // unavailable" for ten minutes after the network came back, with no way to
  // force a retry - the guard is on the cache ENTRY, not on its contents. So
  // the two ages get separate TTLs: short for a failure, so the next
  // keystroke after _netRetryMs re-asks, long for a real answer.
  readonly property int _netTtlMs: 600000
  readonly property int _netRetryMs: 15000
  // --- plugins ---
  // Merged configs in registration order; runtime fields (_impl, broken,
  // dir) are underscore-private and never leave this file.
  property var plugins: []
  // Enabled, successfully loaded plugin prefixes in registration order -
  // the search field's prefix watcher consumes these for mode switches.
  // A property the controller republishes, not a computed list: the configs
  // are mutated in place, so a binding that called into here would depend on
  // property reads it is not written to look at, and the facade's field
  // would keep a stale prefix set after a rescan or a toggle.
  property var enabledPrefixes: []
  // Whether a discovery scan has built the registry yet. An unresolved
  // registry is empty, and empty answers two questions wrongly: every
  // plugin reads as off, and no id exists to write. Discovery is a Process
  // and lands a round trip after construction, so every consumer of the
  // enablement state needs this to tell "off" from "not scanned yet".
  property bool pluginsResolved: false

  // Chip-free state: the search field's own bindings live on the facade.

  // --- construction ---

  Component.onCompleted: {
    // The three construction steps that cost something: a usage-data read,
    // an index build over the live desktop entries and a plugin directory
    // scan. A throw here would leave the facade holding a controller that
    // never worked, so it is reported instead of propagating - a Loader
    // cannot raise a construction error to its caller.
    try {
      root._syncHasHistory()
      // Seed the ranking before the first index build: this controller is
      // rebuilt on every open, but the facade keeps serving the last
      // published map across the teardown gap. Starting from it instead of
      // {} keeps a warm summon in most-used order on frame one; the disk
      // read then only rebuilds when the file actually moved.
      if (AppLauncher.usageKnown && AppLauncher.usageMap
        && typeof AppLauncher.usageMap === "object"
        && !root._sameUsageMap(root.usageMap, AppLauncher.usageMap)) {
        root._setUsageMap(AppLauncher.usageMap)
        root.hasUsageHistory = AppLauncher.hasUsageHistory === true
      }
      // Frequency data is on-demand - the controller's own construction is
      // the first open's warm-up. Don't keep druncache.json resident at
      // boot: a shell that never summons the launcher never reads it.
      if (!saveDebounce.running) root._loadUsage()
      // The async read above lands after the build below, which is the
      // alphabetical flash frequency mode opens with. A blocking read of
      // the same tiny file ahead of the build keeps a cold first open in
      // final order too; the async continuation still lands and skips its
      // rebuild when the map is unchanged.
      if (root.sortMethod === "frequency" && !saveDebounce.running) root._loadUsageSync()
      root._rebuildAppIndex()
      // Arm the clipboard target's stat probe before the panel paints: the
      // demand builds this controller ahead of visible, and a hinted target
      // renders from its copy-time hint on frame one while the probe
      // verifies it in the background.
      root._refreshClipTarget()
      root.discoverPlugins()
      // First compute ahead of visible: a demand builds this controller
      // before the facade sets visible, so the row model is already idle
      // when the panel's open seat reads it - no transient empty between
      // the cached publication and the live one. Blank queries need no
      // plugins (app rows plus the clipboard suggestion), so an
      // undiscovered registry costs nothing here; the scan recomputes when
      // it lands.
      root.recompute()
    } catch (error) {
      root.startupError = "startup"
    }
  }

  Component.onDestruction: {
    // A launch bumps the usage counter and closes the launcher in the same
    // tick, so this teardown lands INSIDE the debounce window. Flush the
    // pending write here or the increment dies with the timer that would
    // have persisted it.
    if (saveDebounce.running) {
      saveDebounce.stop()
      // Fire-and-forget on purpose: waitForJob pumps a nested event loop,
      // and pumping one inside a Loader unload cascade processes deferred
      // deletes mid-cascade (use-after-free -> segfault on close). setText
      // alone still lands: the shell process outlives this controller, so
      // the IO thread completes the write. Durability without the block.
      try { root._saveUsage(false) } catch (e) {}
    }
    // Retire every in-flight fetch for the same reason: an fx row has an
    // 8000ms budget and the close settle is ~200ms, so a request opened and
    // then abandoned is the normal case, not the exotic one. The dead flag is
    // what stops the reply; the abort is only so the socket is not left to
    // drain out its remaining budget, and it is guarded because aborting
    // mid-handshake is exactly the case that reads device-not-open.
    const live = root._netLive
    for (let i = 0; i < live.length; i++) {
      live[i].dead = true
      live[i].done = true
      try { if (live[i].xhr) live[i].xhr.abort() } catch (e) {}
    }
    root._netLive = []
  }

  // Everything the first open does on top of construction. The facade calls
  // this from its own open tick, so the panel's first paint sees a fresh
  // frequency read and a resolved clipboard suggestion.
  function onOpened() {
    if (!saveDebounce.running) {
      root._loadUsage()
    }
    root._rebuildAppIndex()
    root._refreshClipTarget()
    root.recompute()
  }

  // --- the facade's call surface ---
  //
  // Every entry point in this block is reached through a demand the facade
  // made first, so nothing here has to know whether it is loaded, and
  // every answer it produces is a plain value the facade can project.
  //
  // The plugin a prefix claims, as a plain record: a view may read its
  // keyword, and it may not reach the impl, the host or the policy view
  // through it. This is the only shape the facade stores.
  function pluginForPrefix(prefix) { return LauncherLib.pluginDescriptor(LauncherLib.pluginByPrefix(root.plugins, prefix)) }
  // The public plugin record set, in one place: everything a status
  // read may show, and nothing that is an engine object. The capability
  // posture is the one live read in the record, so the library takes it as
  // a callback and a plugin that was never granted answers an empty list.
  function pluginSummary() {
    return LauncherLib.pluginSummary(root.plugins, p => p._view ? p._view.grantedOperations() : [])
  }

  // The same registry as a plain { id: enabled } map, which is the shape the
  // facade's menu toggles read. Built here so the facade never walks a
  // config object, and so a published map is the same answer pluginEnabled
  // gives for every id it knows.
  function pluginToggles() {
    return LauncherLib.pluginToggles(root.plugins)
  }

  // --- provider reads for the facade's menu surfaces ---
  //
  // The provider records themselves are the facade's: they are what lets
  // the settings menu read the plugin toggles and the clear-history row
  // with the launcher closed. Only the reads below reach into this
  // controller, and an undiscovered id reads as off - the same answer a
  // plugin that was never scanned gives.
  function pluginEnabled(id) {
    return LauncherLib.pluginEnabledFlag(root.plugins, id)
  }

  Connections {
    target: DesktopEntries

    function onApplicationsChanged() {
      root._rebuildAppIndex()
      root.recompute()
    }
  }

  Connections {
    target: Settings

    function onOptionChanged(key, _) {
      if (key === "shell.launcher.showDescriptions"
        || key === "shell.launcher.sortMethod") {
        root._rebuildAppIndex()
        root.recompute()
        return
      }
      if (key === "shell.launcher.searchEngine"
        || key === "shell.launcher.showIcons"
        || key === "shell.launcher.showBadges"
        || key === "shell.launcher.showClipboardSuggestion") root.recompute()
    }

    // External edits to settings.json (hand edit, another surface) may
    // have flipped plugin enablement - re-merge cheaply.
    function onRevChanged() {
      root._mergePersisted()
    }
  }

  // Clipboard Connections: a fresh copy while the launcher is open
  // swaps the suggestion in place (the row renders on the idle view
  // only, so active searches are never interrupted).
  Connections {
    target: Clipboard

    function onHistoryChanged() {
      if (!AppLauncher.visible) return
      root._refreshClipTarget()
      root.recompute()
    }
  }

  // --- row recomputation ---
  //
  // Single place deciding what the list shows; the panel only renders.

  function recompute() {
    let next = []
    const mode = AppLauncher.mode
    const modeId = AppLauncher.modePluginId
    switch (mode) {
      case "websearch": {
        next = root._webRows(AppLauncher.entry, LauncherLib.pluginById(root.plugins, modeId))
        root.matchedCount = next.length
        break
      }
      default: {
        const eng = root._engineRows(AppLauncher.entry)
        if (eng.length > 0) {
          next = eng
          root.matchedCount = eng.length
        } else {
          next = root._appRows(AppLauncher.entry)
        }
        break
      }
    }
    // Change-aware assignment: identical row sets keep the live array,
    // so no resultsChanged fires and the panel does zero work. Order,
    // content and input revisions all participate; anything real still
    // assigns exactly as before.
    const fp = root._indexFp + "|" + root._pluginsRev
    if (fp === root._resultsFp && root._rowsEqual(root.results, next)) {
      return
    }
    root.results = next
    root._resultsFp = fp
    // Publish the light row model for the facade to serve across the
    // teardown gap (see AppLauncher._publishRows). Heavy state (usage,
    // plugins, processes) still goes with this controller; the rows, being
    // plain records, stay cheaply resident so the delegates - and their
    // decoded icons - survive the close.
    AppLauncher._publishRows(root.results, root.matchedCount, root.totalCount)
    if (root.autoSelect) Qt.callLater(root._maybeAutoSelect)
  }

  // Every row the first enabled, non-broken engine plugin answering the query
  // produced. Registration order is discovery order; the builtin root scans
  // before the user root and folder names sort calc < color < fx < time < unit on
  // disk, so the priority and the whole selection are the shared library's.
  // Only the plugin call is this file's work, and it is the wrapped one, so a
  // throwing implementation degrades its own plugin.
  //
  // The list is the engine's own, not its first row: a bare "5 mb" is one
  // engine answer in six readings, and narrowing it here would throw away the
  // rows the plugin already decided were worth showing. An engine that answers
  // with one row (calc, time, and every typed failure) still yields one.
  //
  // The engine set is loaded here rather than from inside the library's
  // loop, and the whole of the load-on-demand guarantee rests on that
  // placement. See _loadReachable: the pre-pass below covers every engine
  // the loop can ask, so the loop's `!p._impl` guard never has an unloaded
  // engine in front of it.
  function _engineRows(query) {
    root._loadReachable(query)
    const hit = LauncherLib.firstEngineClaiming(root.plugins, query, p => root._safeItems(p, query))
    if (hit === null) return []
    const rows = hit.rows
    for (let i = 0; i < rows.length; i++) rows[i].plugin = hit.plugin
    return rows
  }

  function _maybeAutoSelect() {
    if (!root.autoSelect || !AppLauncher.visible) return
    if (AppLauncher.entry.trim() === "") return
    if (root.results.length !== 1) return
    const r = root.results[0]
    if (!r) return
    // calc, fx, time, unit, color, web and file are single by design
    // (eager calc, live rate, time lookup, unit conversion, one
    // copy row per color format, explicit web, fallback web, verified path) -
    // none may auto-fire. fx is here because its row is often the only result
    // and auto-activating it would open a socket the moment a query narrowed
    // to one. An engine that answers with a LIST of readings (a bare amount, a
    // bare quantity, a color code) is already outside the guard above, which is
    // the other half of why nothing here fires on a keystroke.
    if (r.kind === "calc" || r.kind === "fx" || r.kind === "time" || r.kind === "unit" || r.kind === "color" || r.kind === "web" || r.kind === "file") return
    // A typo-rescued single is a guess, not a selection: firing it would
    // launch an app the user never named.
    if (r.typo === true) return
    // only auto-activate app rows
    if (r.kind !== "app") return
    // debounce already in activate(), but ensure single activation
    root.activate(r)
  }

  // One-shot clock probe: `date` under TZ=<zone> prints
  // "<time>|CODE|OFFSET|DATE" (e.g. "14:32|CEST|+0200|Fri 11 Sep", or
  // "01:00 PM|CDT|-0500|..." where the zone keeps a 12-hour dial). The dial
  // comes from the zone, not from the OS, so the row reads the way the place
  // reads however this machine is set up. The verdict lands in timeCache
  // keyed by zone; a run already in flight for the same zone is left alone, a
  // different zone waits its turn via _timePendingZone so outputs can never
  // swap zones.
  function requestTime(tz) {
    // Fresh cache answers without spawning: items() asks on every
    // recompute, so an unguarded probe re-arms itself forever
    // (probe -> verdict -> recompute -> probe) and the row repaints
    // continuously. TTL gates the cadence; the 10s timeTick drives it.
    const cached = root.timeCache[tz]
    if (cached && (Date.now() - (cached.at || 0)) < root._timeTtlMs) {
      return
    }
    if (timeProc.running) {
      if (timeProc.zone === tz) return
      root._timePendingZone = tz
      return
    }
    timeProc.zone = tz
    timeProc.out = ""
    timeProc.environment = ({ "TZ": tz })
    timeProc.command = ["date", "+" + LauncherLib.timeProbeFormat(tz) + "|%Z|%z|%a %-d %b"]
    timeProc.running = true
  }

  // On-demand PATH scan for a granted plugin (see requestBinaries in
  // AppLauncher.qml). One scan per TTL, and a request while a run is in
  // flight is dropped rather than queued - a plugin's items() runs on every
  // recompute, so an unguarded call would re-arm a directory walk on every
  // keystroke forever, exactly as the clock and fetch pairs do.
  function requestBinaries() {
    const cached = root.binCache
    if (cached !== null && (Date.now() - (cached.at || 0)) < root._binTtlMs) return
    if (binProc.running) return
    binProc.command = LauncherLib.binariesArgv()
    binProc.running = true
  }

  function _onBinariesScanned() {
    const v = LauncherLib.binariesVerdict(binOut.text)
    // An identical set changes nothing: skip the cache rewrite and the
    // recompute so a settled row rests instead of repainting every TTL. The
    // comparison is on the names, not on the record, because the `at` stamp
    // differs on every scan by construction.
    const current = root.binCache
    if (v === null) {
      // A scan that found nothing usable is stored as such rather than
      // dropped, so cachedBinaries() distinguishes "no scan has landed" from
      // "the scan landed empty" and the TTL applies to the failure too.
      if (current !== null) return
      root.binCache = { names: [], at: Date.now() }
      return
    }
    if (current !== null && LauncherLib.sameNameSet(current.names, v.names)) {
      root.binCache = Object.assign({}, current, { at: Date.now() })
      return
    }
    root.binCache = { names: v.names, at: Date.now() }
    if (AppLauncher.visible) root.recompute()
  }

  function _onTimeProbed() {
    const tz = timeProc.zone
    // Identical verdicts change nothing: skip the cache rewrite and the
    // recompute so the live row rests instead of repainting every probe.
    let changed = false
    if (tz !== "") {
      const v = LauncherLib.timeVerdict(timeProc.out, root.timeCache[tz])
      if (v !== null && v.changed) {
        const next = Object.assign({}, root.timeCache)
        v.reading.at = Date.now()
        next[tz] = v.reading
        root.timeCache = next
        changed = true
      }
    }
    const pending = root._timePendingZone
    root._timePendingZone = ""
    if (pending !== "" && pending !== tz) root.requestTime(pending)
    if (changed && AppLauncher.visible) root.recompute()
  }

  // On-demand fetch for a granted plugin (see requestNet in AppLauncher.qml).
  // One GET per URL per TTL, a second request while the first is in flight is
  // dropped rather than queued, and the verdict lands in netCache keyed by
  // URL. A failed or empty body is cached as an empty string rather than
  // omitted: cachedNet() then answers "" (settled, unusable) where it answers
  // null (never asked or in flight), which is the difference between a row
  // that says the rate is unavailable and one that waits forever.
  function requestNet(url, timeoutMs) {
    const u = String(url === undefined || url === null ? "" : url)
    if (u === "") return
    const cached = root.netCache[u]
    if (cached !== undefined) {
      // The TTL follows the CONTENT: an empty body is a failure and ages out
      // in seconds, a real document ages out in minutes. A single TTL over
      // both is what latched an offline failure for the full ten.
      const age = Date.now() - (cached.at || 0)
      const warm = age < (cached.body === "" ? root._netRetryMs : root._netTtlMs)
      // The parent of this DEBUG is the INFO in AppLauncher._requestNet: the
      // plugin asked, and that line is the whole record of the ask. From here
      // the two ways out are otherwise indistinguishable - a warm entry opens
      // no socket, settles nothing and writes no cache line, so the requests
      // that did no I/O at all are the ones nothing else mentions. The verdict
      // is taken once above and both this line and the guard read it, so the
      // two cannot disagree about the window.
      //
      // The url is cut with the entry point's own bound rather than summarised
      // here: the plugin chose it, and the pair has to print the same string in
      // both records or it will not read as a pair. The cut and the key count
      // are built inside the gate, which is why this one is gated.
      const d = Log.at()
      if (d.allows("debug")) {
        const limit = AppLauncher._netLogPathLimit
        const cut = u.length > limit ? u.slice(0, limit) + "…(" + u.length + ")" : u
        d.debug(cut + " cache age " + age + "ms of the "
          + (cached.body === "" ? root._netRetryMs : root._netTtlMs) + "ms window, "
          + (warm ? "warm, answered with no request sent" : "cold, fetch asked"))
      }
      if (warm) {
        // A warm TTL answers without a fetch: a plugin's items() runs on
        // every recompute, so this is asked many times per open panel.
        return
      }
    }
    if (root._netPending[u] === true) return
    const next = Object.assign({}, root._netPending)
    next[u] = true
    root._netPending = next
    const budget = parseInt(timeoutMs, 10) > 0 ? parseInt(timeoutMs, 10) : 0
    let xhr = null
    try { xhr = new XMLHttpRequest() } catch (e) { root._settleNet(u, ""); return }
    // Superseded handles never call back, the same dead-flag shape the
    // weather service uses: aborting a handshaking socket logs a
    // device-not-open read, so a stale reply dies by flag while its socket
    // drains on its own.
    //
    // The flag carries the teardown case too, which is the reason the handle
    // is registered rather than left as a local: a reply arriving after this
    // controller is destroyed would otherwise run _settleNet against a dead
    // root and write netCache on it. onDestruction marks every live handle
    // dead, so the callback cannot fire at all.
    const handle = { dead: false, done: false, xhr: xhr }
    const finish = body => {
      if (handle.done) return
      handle.done = true
      if (handle.dead) return
      root._settleNet(u, body)
    }
    root._netLive = root._netLive.filter(h => !h.done).concat([handle])
    xhr.onreadystatechange = () => {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 200) {
        finish(String(xhr.responseText || ""))
        return
      }
      finish("")
    }
    try { xhr.ontimeout = () => { finish("") } } catch (e) {}
    try {
      if (budget > 0) xhr.timeout = budget
      xhr.open("GET", u)
      xhr.send()
    } catch (e) { root._settleNet(u, "") }
  }

  function _settleNet(url, body) {
    const pending = Object.assign({}, root._netPending)
    delete pending[url]
    root._netPending = pending
    const text = String(body === undefined || body === null ? "" : body)
    const cached = root.netCache[url]
    // An identical body changes nothing: skip the cache rewrite and the
    // recompute so a settled row rests instead of repainting every TTL.
    if (cached !== undefined && cached.body === text) return
    const next = Object.assign({}, root.netCache)
    next[url] = { body: text, at: Date.now() }
    root.netCache = next
    if (AppLauncher.visible) root.recompute()
  }

  function _appRows(rawQuery) {
    // "!" is the binary plugin's one escape, and it is resolved here rather
    // than in the plugin: everything below - the app search, the counter, the
    // path probe, the fallback chain - reads the stripped `query`, and only
    // this gate reads `forced`. The plugin is handed the same stripped text
    // and never learns the prefix was typed, so a forced claim and a plain one
    // produce the identical row and differ only in whether the slot was
    // consulted at all.
    const forced = String(rawQuery ?? "").charAt(0) === "!"
    const query = forced ? String(rawQuery).substring(1).trim() : String(rawQuery ?? "")
    // Match over the WHOLE index; only the display is capped (100 rows for
    // large app sets, 40-50 for typical) so the counter can report the true
    // number of hits and holding TAB does not appear to loop after the
    // ~20 visible rows.
    const blank = query === ""
    // Frequency mode ranks by druncache in the idle view (see
    // buildAppIndex); the same counts break equal-relevance ties while
    // filtering, so a heavily used "Spotify" outranks a rarely used
    // "SpotiFLAC" on a tied query like "spo". Alphabetical mode passes
    // no tiebreak and keeps pure relevance order.
    // -> counts snapshotted once per recompute into a Map; the comparator
    // below reads the snapshot instead of calling usageCountFor per
    // comparison, which ran O(n log n) map lookups per sort. Same order.
    let tie = null
    if (root.sortMethod === "frequency") {
      const counts = new Map()
      const pool = root.appIndex
      for (let i = 0; i < pool.length; i++) {
        const rec = pool[i]
        const id = rec && rec.app ? String(rec.app.id ?? "") : ""
        if (!counts.has(id)) counts.set(id, LauncherLib.usageCountFor(root.usageMap, id))
      }
      tie = rec => counts.get(rec && rec.app ? String(rec.app.id ?? "") : "") ?? 0
    }
    // filterCounter matches over the WHOLE index and reports the true hit
    // count as `matched` (total = index size), display-capped at 100.
    const res = LauncherLib.filterCounter(root.appIndex, query, 100, tie)
    root.matchedCount = res.matched
    root.totalCount = res.total
    const shown = res.rows.length
    const rows = []
    // Clipboard suggestion rides above the idle app list; it re-appears
    // whenever the field empties and refreshes on new copies.
    if (blank) {
      const clip = root._clipRow()
      if (clip) {
        rows.push(clip)
        // Visual break between the clipboard suggestion and the real
        // desktop entries below - only when the suggestion shows.
        rows.push({ kind: "separator" })
      }
    }
    // One mapping for exact and rescued rows alike: a typo hit IS the
    // same desktop entry, so it renders, keys and activates identically -
    // only the `typo` flag tells how it was found.
    const toRow = rec => ({
      kind: "app",
      uid: rec.uid,
      label: rec.label,
      // Description ownership follows the settings option. Inline
      // (option on): the description IS the sub line - missing ones get
      // an explicit placeholder - and ctrl-i has nothing to open.
      // Option off: no subtitle at all, ctrl-i opens the description.
      sub: root.showDescriptions
        ? (rec.desc !== "" ? rec.desc : root.noDescriptionText)
        : "",
      desc: root.showDescriptions ? "" : rec.desc,
      icon: root.showIcons ? rec.icon : "",
      // PWA/TUI marker for the right-side badge; gated by the same
      // setting that fills it, so a disabled badge ships empty rows.
      badge: root.showBadges ? String(rec.badge ?? "") : "",
      app: rec.app,
      // Terminal=true entries (yazi) must open in a terminal; everything
      // else routes through vb-launch-cmd on selection.
      runInTerminal: rec.runInTerminal === true,
      removable: rec.removable === true
    })
    for (let i = 0; i < shown; i++) {
      rows.push(toRow(res.rows[i]))
    }
    // Typo rescue, between the exact pool and the fallback slot: the exact
    // bands found nothing at all, so up to a length-gated budget of Damerau
    // edits per token over the whole index. Same records and the same mapping above, ranked under
    // every exact hit by construction - this pass only runs when those
    // number zero, so no exact row can move for it. Unforced, non-blank,
    // non-math queries only: "!" asserts a program name for the binary
    // slot, and math input stays quiet for the calc path. Rescued rows
    // carry `typo`, which rowsEqual ignores (identity and content match)
    // and the auto-select below refuses: firing on a fuzzy single match
    // would launch an app the user never named.
    if (!forced && !blank && res.matched === 0 && !CalcLib.isPotentialCalc(query)) {
      const ty = LauncherLib.searchTypo(root.appIndex, query, 100, tie)
      if (ty.count > 0) {
        root.matchedCount = ty.count
        for (let i = 0; i < ty.rows.length; i++) {
          const rescued = toRow(ty.rows[i])
          rescued.typo = true
          rows.push(rescued)
        }
      }
    }
    // Fallback slot: nothing local matched, or a "!" forced it to run
    // anyway. The synthetic row never counts toward matchedCount.
    // Suppress it for math-like input: "2+" should not offer web search
    // while the user is mid-expression; it would compete with the calc path.
    if ((rows.length === 0 || forced) && query !== "" && !CalcLib.isPotentialCalc(query)) {
      // File opener: a path- or URI-looking query resolves to an open
      // target. An existing local file/folder - or any openable URI -
      // replaces the slot with a single "Open <basename>" entry; a
      // miss keeps the fallback. While a stat probe is in flight
      // the list stays empty - no fallback-row flash before the swap.
      const target = LauncherLib.openTarget(query, Paths.home)
      if (target) {
        if (target.kind !== "local") {
          rows.push(root._fileRow(target, false))
          return rows
        }
        const st = BoundedCache.get(AppLauncher.statCache, target.path)
        if (st === "dir" || st === "file") {
          rows.push(root._fileRow(target, st === "dir"))
          return rows
        }
        if (st === undefined) {
          root._statPath(target.path)
          return rows
        }
        // missing: falls through to the plugin chain below
      }
      // The slot is a chain, not one owner: the first live plugin in
      // LauncherLib's fallback order that claims the query fills it, and a
      // plugin that declines (the binary plugin on anything but an exact
      // program name) hands it to the next type rather than erasing it.
      //
      // A forced query gets the binary type alone. "!" is the user asserting
      // that the query IS a program name, so the only question it can be
      // asking is "run this" - a name nothing provides leaves the slot empty
      // rather than falling through to a web search that cannot be what was
      // meant. An unforced query keeps the whole chain, where the web search
      // IS the right answer to "nothing here matches".
      const hit = LauncherLib.firstFallbackClaiming(root.plugins, query,
        p => root._safeItems(p, query),
        forced ? LauncherLib.forcedOrder() : undefined,
        p => root._loadOne(p))
      if (hit !== null) {
        const slot = root._webRows(query, hit.plugin, hit.rows)
        if (forced) return slot.concat(rows)
        rows.push(...slot)
      }
    }
    return rows
  }

  // `preferred` pins the serving plugin (the mode's owner in explicit
  // web mode); the fallback path passes whatever the chain found. `given`
  // carries rows the chain already asked for, so a claiming plugin's items()
  // runs once per recompute rather than once per lookup.
  function _webRows(query, preferred, given) {
    const blank = String(query ?? "").trim() === ""
    // Blank query outside explicit websearch mode stays empty: the
    // normal-mode fallback must not invent rows. Explicit mode (the
    // mode owner asking for its own query) answers with the plugin hint
    // row, tagged non-activatable below so Enter is a no-op on it.
    const explicit = blank && preferred && !preferred.broken
      && AppLauncher.mode === "websearch" && AppLauncher.modePluginId === preferred.id
    if (blank && !explicit) return []
    const plugin = preferred && !preferred.broken
      ? preferred : LauncherLib.pluginByType(root.plugins, "websearch")
    if (!plugin || plugin.broken) return []
    if (blank && plugin !== preferred) return []
    // The mode owner asking for its own rows is the one claim that does not
    // go through a library chain, so nothing has loaded this plugin yet:
    // entering a websearch mode with an empty payload is a blank query that
    // DOES reach it, and its hint row comes from items(""). Loaded here,
    // directly ahead of the call, because there is no loop here to ask from.
    // Rows handed in by the fallback chain were built by a plugin that had
    // already loaded, so that path never reaches this.
    if (given === undefined || given === null) root._loadOne(plugin)
    const items = given !== undefined && given !== null ? given : root._safeItems(plugin, query)
    const rows = []
    for (let i = 0; i < items.length; i++) {
      rows.push({
        kind: "web",
        // The uid is keyed on the OWNING PLUGIN and the row's position, never
        // on its label. A websearch row labels itself "Search in Google" for
        // every query, so a label-derived uid was stable by accident; a
        // binary row labels itself "Launch <name>", and a uid built from that
        // would mint a new row on every keystroke - defeating the identity
        // check that lets the panel patch in place instead of rebuilding
        // every delegate. One slot, one row: the plugin id plus the index is
        // the whole identity, and the rendered text is content, not identity.
        uid: "web:" + String(plugin.id) + ":" + i,
        label: String(items[i].label ?? ""),
        sub: String(items[i].sub ?? ""),
        desc: String(items[i].desc ?? ""),
        icon: root.showIcons ? String(items[i].icon ?? "") : "",
        incomplete: blank || items[i].incomplete === true,
        item: items[i],
        plugin: plugin
      })
    }
    return rows
  }

  // --- launching ---

  // Launch an app row. Which shim takes the entry is the shared library's
  // (see launchArgv); what this file owns is the order the two side effects
  // happen in and the one detached exec, which the facade provides so the
  // command outlives the launcher:
  //   - Terminal=true entries (yazi) open inside a terminal via
  //     vb-launch-tui (Quickshell's DesktopEntry.execute() ignores
  //     runInTerminal, which is why the launcher wraps them).
  //   - Entries whose Exec already is a vb-launch-* wrapper (TUI / PWA
  //     entries use vb-launch-tui / vb-launch-webapp) run as-is.
  //   - Everything else goes through vb-launch-cmd -- <command>.
  function _launchApp(row) {
    // frequency sort: bump usage before closing so next open shows it on top
    if (row.app && row.app.id) root._incrementUsage(row.app.id)
    // Close first: the launcher must stop consuming keys before the app
    // surfaces, or a follow-up Enter re-fires on the same row.
    AppLauncher.close()
    AppLauncher.execDetached(LauncherLib.launchArgv(LauncherLib.execArgs(row.app), row.runInTerminal))
  }

  function _runWeb(row) {
    const ok = root._safeActivate(row.plugin, row.item, AppLauncher.entry)
    if (ok) AppLauncher.close()
  }

  // --- file opener (clipboard suggestion + path rows) ---

  // Async `[ -d / -f ]` stat probe for a local target. Cheap bash; the
  // verdict lands in statCache keyed by path. The generation number is
  // echoed back with the verdict so an aborted run's late exit can
  // never poison the cache; the argv and the line's meaning are the
  // library's, this file owns the Process and the cancellation.
  //
  // A cached verdict is trusted for the immediate render while a forced
  // re-probe revalidates it in the background: a file deleted since the
  // last probe still paints from the stale verdict for one round trip
  // and then drops, rather than staying visible for the rest of the
  // session, and an unchanged verdict changes no row so the recompute
  // is a no-op.
  function _statPath(path, force) {
    if (force !== true && BoundedCache.has(AppLauncher.statCache, path)) return
    if (pathStatProc.running && pathStatProc.path === path && !force) return
    if (pathStatProc.running) pathStatProc.running = false
    pathStatProc.seq++
    pathStatProc.path = path
    pathStatProc.out = ""
    pathStatProc.command = LauncherLib.statProbeArgv(path, pathStatProc.seq)
    pathStatProc.running = true
  }

  function _onStatProbed() {
    const v = LauncherLib.statVerdict(pathStatProc.out, pathStatProc.seq)
    if (v === null) return // aborted run's stale exit
    BoundedCache.put(AppLauncher.statCache, pathStatProc.path, v.verdict)
    // A dir/file verdict for the live suggestion inserts the withheld row;
    // a missing verdict leaves the withheld list unchanged, so neither
    // paints a flash. Stale exits (seq mismatch above) return before this.
    if (AppLauncher.visible && AppLauncher.entry.trim() === "") {
      const live = root.clipTarget ? root.clipTarget.value : ""
      if (pathStatProc.path === live) root.recompute()
    }
  }

  // --- clipboard suggestion ---

  function _refreshClipTarget() {
    const prev = root.clipTarget ? root.clipTarget.value : ""
    const hist = Clipboard.history
    const resolved = hist && hist.length > 0 ? root._resolveClipTarget(hist[0]) : null
    const cur = resolved ? resolved.value : ""
    if (cur !== prev && cur !== "") {
      // Drop the stale verdict for the new target so a cached missing
      // cannot hide a re-created file of the same name across copies.
      BoundedCache.remove(AppLauncher.statCache, cur)
    }
    // The target is published while its probe is still in flight; _clipRow
    // renders a hinted local path from the copy-time hint meanwhile, so the
    // suggestion rides with the open and the probe only corrects it.
    if (resolved && resolved.kind === "local" && !BoundedCache.has(AppLauncher.statCache, resolved.value)) {
      root._statPath(resolved.value)
    }
    if (resolved && resolved.kind === "local" && BoundedCache.has(AppLauncher.statCache, resolved.value)
      && AppLauncher.visible
      && !(pathStatProc.running && pathStatProc.path === resolved.value)) {
      // Same target as the last refresh still carries its old verdict,
      // which may predate a deletion or a re-creation while the panel was
      // down. Revalidate in the background without dropping the cached
      // render, so an unchanged verdict changes no row and a changed one
      // corrects in place instead of staying stale. Skipped while its own
      // probe is still running, so the construction arming above is never
      // aborted and restarted here.
      root._statPath(resolved.value, true)
    }
    root.clipTarget = resolved
  }

  // Map the newest clipboard entry onto an openable target, or null.
  // Which entries may name a destination is the library's rule; this file
  // owns only which entry is newest. A local target also carries the
  // folder/file hint the entry settled at copy time; _clipRow paints from
  // it while the stat probe verifies the path.
  function _resolveClipTarget(entry) {
    const t = LauncherLib.clipTargetFor(entry, Paths.home)
    if (t === null || t.kind !== "local") return t
    const hint = LauncherLib.clipEntryKind(entry)
    if (hint === "") return t
    return { kind: t.kind, value: t.value, basename: t.basename, hint: hint }
  }

  // The suggestion row for the idle view, or null while absent.
  // Web links open in the default browser; protocol URIs and existing
  // local paths open in their default system app.
  //
  // A local path with a verified dir/file verdict renders from that verdict.
  // A path the stat probe has not verified yet renders from the copy-time
  // hint when one exists, so the suggestion rides with the open instead of
  // arriving a probe late; the probe still runs in the background and a
  // missing verdict drops the row when it lands. A hint-less path is
  // withheld entirely, same as the typed-path fallback (see _appRows): no
  // provisional row before the swap.
  function _clipRow() {
    if (!root.showClipSuggestion) return null
    const t = root.clipTarget
    if (!t) return null
    if (t.kind === "url" || t.kind === "uri") {
      return {
        kind: "file",
        uid: "clip:" + t.value,
        path: t.value,
        label: "Open URL from the clipboard",
        // Subtext follows the descriptions option, like app rows -
        // option off shows the title only.
        sub: root.showDescriptions ? t.value : "",
        desc: "",
        icon: root.showIcons ? "clipboard" : "",
        clipUrl: true,
        clip: true
      }
    }
    const st = BoundedCache.get(AppLauncher.statCache, t.value)
    let kind = ""
    if (st === "dir" || st === "file") {
      kind = st
    } else if (st === undefined && (t.hint === "dir" || t.hint === "file")) {
      kind = t.hint
      if (!(pathStatProc.running && pathStatProc.path === t.value)) root._statPath(t.value)
    } else {
      // No verdict yet (or missing): withhold the row and arm the probe.
      // The verdict inserts the row when it lands; a hint-less path never
      // paints provisionally.
      if (st === undefined && !(pathStatProc.running && pathStatProc.path === t.value)) root._statPath(t.value)
      return null
    }
    return {
      kind: "file",
      uid: "clip:" + t.value,
      path: t.value,
      label: kind === "dir" ? "Open folder from the clipboard" : "Open file from the clipboard",
      sub: root.showDescriptions ? t.basename : "",
      desc: "",
      icon: root.showIcons ? LauncherLib.pathIconName(kind === "dir", t.value) : "",
      clip: true
    }
  }

  function _fileRow(target, isDir) {
    const isUri = target.kind === "uri"
    const open = isUri ? target.uri : target.path
    let iconName = ""
    if (root.showIcons) {
      iconName = isUri ? "network-storage" : LauncherLib.pathIconName(isDir, target.path)
    }
    return {
      kind: "file",
      uid: "file:" + open,
      path: open,
      label: "Open " + target.basename,
      sub: "Open in default system app",
      desc: "",
      icon: iconName
    }
  }

  // Open a verified filesystem path (or URI) in its default app. Same
  // launch discipline as the web-search plugin: xdg-open inside app2unit's
  // transient systemd scope so the process stays session-tracked;
  // execDetached guarantees survival past launcher shutdown.
  function _openPath(row) {
    AppLauncher.close()
    AppLauncher.execDetached(["app2unit", "-S", "both", "-s", "app-graphical.slice",
      "--", "xdg-open", row.path])
  }

  // Plugin calls wrapped so a throwing implementation degrades its own
  // plugin, never the launcher.
  //
  // The null-_impl return is a DEFERRED plugin, not a broken one, and the
  // distinction is the whole of load-on-demand: the implementations are read
  // when a claim reaches them, so a caller can arrive before the load has
  // happened. Reading `plugin._impl.items()` unguarded would throw a
  // TypeError into the catch below and latch `broken`, which is permanent -
  // so a plugin that had merely not loaded yet would be disabled for the
  // life of the controller and never retried. It answers nothing and leaves
  // the verdict alone; the load in front of the claim is what fills it in,
  // so a null here means a caller reached a plugin nothing asked for.
  function _safeItems(plugin, query) {
    if (plugin._impl === null) return []
    try {
      const out = plugin._impl.items(query)
      return Array.isArray(out) ? out : []
    } catch (e) {
      plugin.broken = true
      root._rebuildPrefixes()
      return []
    }
  }

  // A row is only ever built from a plugin's own items(), so its impl was
  // loaded when the row appeared. The null return covers the one way that
  // can stop being true - a settings revision disabling the plugin between
  // the row's build and the Enter - and says the same thing: nothing to
  // activate, and no verdict to record.
  function _safeActivate(plugin, item, query) {
    if (plugin._impl === null) return false
    try {
      plugin._impl.activate(item, query)
      return true
    } catch (e) {
      plugin.broken = true
      root._rebuildPrefixes()
      return false
    }
  }

  // --- plugin registry ---

  readonly property string _builtinRoot: Paths.vibraniumHome
    + "/shell/features/launcher/plugins"
  readonly property string _userRoot: Paths.launcherUserPluginsDir

  // The directory walk is the library's argv; this file owns the Process
  // that runs it and the one callback that turns its output into a
  // registry.
  function discoverPlugins() {
    root.pluginsResolved = false
    scanProc.command = LauncherLib.pluginScanArgv(root._builtinRoot, root._userRoot)
    scanProc.running = true
  }

  Process {
    id: scanProc

    stdout: SplitParser {
      onRead: data => {
        const line = data.trim()
        if (line !== "") scanProc.dirs.push(line)
      }
    }

    property var dirs: []

    onExited: {
      root._registerPlugins(scanProc.dirs)
      scanProc.dirs = []
    }
  }

  Component {
    id: pluginHostComp

    PluginInstance {}
  }

  function _registerPlugins(dirs) {
    // What a discovered directory MEANS is the library's - the id, the
    // manifest shape check, the duplicate rule and the persisted
    // enablement overlay. The one seam is the manifest read below, so the
    // scan, the FileView and the directory walk stay in this file.
    root.pluginsResolved = true
    root.plugins = LauncherLib.buildPluginConfigs(dirs, root._persistedPlugins(),
      dir => root._readJsonFile(dir + "/plugin.json"))
    root._pluginsRev++
    root._rebuildPrefixes()
    // Rescans mint brand-new cfg objects. The mode owner is a facade-held
    // id, so a rescan needs no re-pin: drop the mode only when the plugin
    // that owned it is gone, or the panel would filter against an empty
    // pool.
    if (AppLauncher.mode !== "normal" && AppLauncher.modePluginId !== "") {
      if (LauncherLib.pluginById(root.plugins, AppLauncher.modePluginId) === null) AppLauncher.exitMode()
    }
    // No load here. Registration is a manifest read; the implementations
    // are read by the claim that reaches them, so the recompute below is
    // what loads whatever this query can reach - and an open under a blank
    // query loads nothing.
    root._maybeEnterModeForEntry()
    root.recompute()
  }

  // Discovery landed under a static query (open race): normal mode
  // holding a leading enabled prefix never saw prefix detection (it
  // runs only on keystrokes). Route it now so a prefix typed pre-scan
  // still enters its mode instead of sticking as a no-match query.
  function _maybeEnterModeForEntry() {
    if (AppLauncher.mode !== "normal") return
    const t = String(AppLauncher.entry ?? "")
    if (t === "") return
    const prefs = LauncherLib.enabledPrefixes(root.plugins)
    for (let i = 0; i < prefs.length; i++) {
      if (prefs[i] !== "" && t.startsWith(prefs[i])) {
        AppLauncher.enterMode(prefs[i], t.substring(prefs[i].length))
        return
      }
    }
  }

  // Re-read persisted enablement (settings.json edited elsewhere) and
  // apply it to the live registry. The overlay rule is the library's; the
  // republish below is this file's, because a per-config field write is
  // invisible to change detection.
  function _mergePersisted() {
    if (root.plugins.length === 0) return
    if (!LauncherLib.mergePersistedEnabled(root.plugins, root._persistedPlugins())) return
    root._applyEnablement()
  }

  function _applyEnablement() {
    root._unloadDisabled()
    // Re-publish the registry so the facade's enabledPrefixes binding
    // re-runs - per-config mutations are invisible to change detection.
    root._rebuildPrefixes()
    // The recompute is also the load: a plugin that just came back is
    // enabled, unlatched and unloaded, so whichever claim this query reaches
    // loads it through _loadOne on the way past.
    root.recompute()
  }

  // Drop a disabled plugin's runtime: host object, impl, capability view,
  // records and prefixes go away immediately so disable reads as off
  // without a reload.
  //
  // Keyed on `enabled` alone, not on whether an implementation is loaded. A
  // plugin whose main.js failed to evaluate holds no impl either, so a guard
  // that also tested `|| !cfg._impl` would skip it and leave its latch and
  // its broken verdict standing - and re-enabling it could then never load
  // it again.
  // Clearing the latch here is what makes a re-enable a retry, which is the
  // one thing a user who fixed a plugin and toggled it expects.
  function _unloadDisabled() {
    for (let i = 0; i < root.plugins.length; i++) {
      const cfg = root.plugins[i]
      if (cfg.enabled) continue
      if (cfg._host) {
        try { cfg._host.destroy() } catch (e) {}
      }
      cfg._host = null
      cfg._impl = null
      cfg._view = null
      cfg._denied = []
      cfg.broken = false
      cfg._implLoadTried = false
    }
  }

  // --- implementation loading ---
  //
  // Registration never loads. A discovered plugin is a manifest, a
  // directory and an id, and everything that reads the registry - the prefix
  // list, the settings toggles, the status records, the mode owner - reads
  // those. So a first open that is only looked at costs no plugin
  // evaluation, and the implementations are read when a claim reaches one.
  //
  // A claim cannot be routed without asking: an engine decides from the
  // query itself, and the fallback chain is a chain of asks. So the load
  // sits in front of the ask, not in place of it. LauncherLib's two claim
  // loops both carry a `!p._impl` guard, and a guard is the one thing that
  // must never be allowed to decide - see _loadReachable for how the engine
  // path gets ahead of its guard, and firstFallbackClaiming's loadFor for
  // how the chain does.
  //
  // What is NOT deferred is the capability boundary: a plugin's view and
  // denial list are minted in _loadOne below, at the moment its
  // implementation appears, so a published record never describes a plugin
  // that was not running when it was published.

  // Load one plugin's implementation, if it is enabled, not yet loaded and
  // not already tried. Returns true when `cfg._impl` holds an implementation
  // afterwards, whether this call loaded it or an earlier one did.
  //
  // `_implLoadTried` is the latch, and it is separate from `broken` on
  // purpose. `broken` is the published verdict - the status record, the
  // prefix list and every claim guard read it, and it survives to tell the
  // user their plugin is not working. The latch is the per-attempt memory
  // that stops a plugin whose main.js will not evaluate from costing a file
  // read on every keystroke forever. A rescan mints fresh configs and so
  // fresh latches, which is what lets an edited plugin recover.
  function _loadOne(cfg) {
    if (!cfg || !cfg.enabled) return false
    if (cfg._impl !== null) return true
    if (cfg._implLoadTried === true) return false
    cfg._implLoadTried = true
    cfg.broken = false
    cfg._impl = root._loadImpl(cfg)
    if (cfg._impl === null) {
      cfg.broken = true
      root._rebuildPrefixes()
      return false
    }
    try {
      // The capability boundary itself (the grant table, the policy view
      // and the host operations behind it) is the facade's, so the
      // security contract that pins _apiFor/_pluginHostFor keeps one
      // address. Building the impl and running init() are this file's
      // work, and happen only here.
      if (typeof cfg._impl.init === "function") cfg._impl.init(AppLauncher._apiFor(cfg))
    } catch (e) {
      cfg.broken = true
      root._rebuildPrefixes()
      return false
    }
    return true
  }

  // Load the engines a query can reach, before the claim that would
  // otherwise skip them. This is the batch form of _loadOne, and the only
  // place that decides which plugins a query SHAPE can reach:
  //
  //   - a blank query reaches no engine. Every shipped engine answers []
  //     for "", and the claim has no way to prove one would not, so the
  //     whole set is loaded for any other query and none of it for this
  //     one. That is what makes an open the user only looks at free.
  //   - a non-blank query reaches all of them. firstEngineClaiming tries
  //     every id in ENGINE_ORDER and the first to answer wins, so which one
  //     claims is only knowable by having asked - the implementations
  //     decide, not the query's shape. There is no cheaper routing.
  //   - the fallback types are NOT loaded here. The chain is entered only
  //     when nothing local matched, so binary and websearch load on the
  //     query that reaches them, through the loadFor that
  //     firstFallbackClaiming takes.
  //
  // Why this pre-pass and not a per-candidate hook inside the library's loop
  // (the same shape the fallback path uses): the loop above asks on EVERY
  // query, so a hook there would load the whole engine set on a blank one
  // and give back the cost this exists to remove. The trade is that the
  // coverage argument lives here, so it is stated: the loop considers only
  // `p.type === "engine"`, and this walks every config with that type, so
  // the set this loads is a superset of the set the loop can ask. Every
  // candidate is therefore loaded or already marked broken by the time the
  // loop's `!p._impl` guard runs, and the guard can never be the reason an
  // engine stays silent. A plugin type the loop could reach but this walk
  // skipped would break that, which is why the filter is on the type the
  // loop filters on and not on a list of ids.
  function _loadReachable(query) {
    if (String(query ?? "").trim() === "") return
    // The list is captured rather than read through root.plugins each turn:
    // a failed load republishes the registry, and _rebuildPrefixes replaces
    // root.plugins with a fresh array. The configs in it are the same
    // objects in the same order, so walking the captured one visits exactly
    // the same set - but it does so by construction rather than by relying
    // on that staying true.
    const list = root.plugins
    for (let i = 0; i < list.length; i++) {
      const cfg = list[i]
      if (!cfg || cfg.type !== "engine") continue
      root._loadOne(cfg)
    }
  }

  // Evaluate a plugin's main.js in its own PluginInstance host and
  // shape-check the result. Returns the impl object or null (never
  // throws). The host object outlives the call in cfg._host so each
  // folder keeps its own engine state until unload destroys it - and
  // until this controller itself goes.
  function _loadImpl(cfg) {
    const source = root.readPluginFile(cfg.dir + "/main.js")
    if (source === null) {
      return null
    }
    const host = pluginHostComp.createObject(root)
    if (!host) {
      return null
    }
    let ok = false
    try {
      ok = host.evaluate(source)
    } catch (e) {
      ok = false
    }
    if (ok !== true) {
      try { host.destroy() } catch (e) {}
      return null
    }
    const impl = host.impl
    if (!impl || typeof impl.items !== "function" || typeof impl.activate !== "function") {
      try { host.destroy() } catch (e) {}
      return null
    }
    cfg._host = host
    return impl
  }

  // Republish both the registry and the prefix list. The slice is what
  // makes the facade's own binding re-run for the same in-place reason.
  // The publish is what outlives this object: a settings-menu toggle reads
  // the facade's projection after the panel closed, and gets the same
  // verdict the live registry gave.
  function _rebuildPrefixes() {
    root.plugins = root.plugins.slice()
    root.enabledPrefixes = LauncherLib.enabledPrefixes(root.plugins)
    root._publishPlugins()
  }

  // --- usage counters ---

  // On-demand reload of usage counts from disk. Called on each open()
  // unless a debounced write is still pending (in-memory increments must
  // not be clobbered by a stale disk read). The read is async
  // (loaded/loadFailed continue below): every exit publishes, so the
  // facade's answer is this controller's own verdict on the file and
  // never the previous one's - a missing or unparsable cache is a
  // published "no history" rather than a leftover. The open shows the
  // previous map until the disk read lands and republishes, the same
  // shape the history watcher below already uses.
  function _loadUsage() {
    root._readUsageMap()
  }

  // Blocking druncache read for construction only: the async _loadUsage
  // above lands a round trip after the first index build, so a build that
  // ranks against the pre-read map paints alphabetical first and most-used
  // when the read lands. The file is kilobytes and the parked reader
  // already blocks the same way (see readPluginFile), so one small block
  // ahead of the build keeps the first frame in final order. A file this
  // read cannot reach leaves the map as it was - the async continuation
  // still lands and reports its own verdict. Never used on the save path:
  // a debounced increment must not be clobbered by a stale disk read.
  function _loadUsageSync() {
    reader.path = ""
    reader.path = Paths.drunCacheFile
    let ok = false
    try { ok = reader.waitForJob() } catch (e) { ok = false }
    let parsed = null
    if (ok === true) {
      try { parsed = LauncherLib.parseUsageText(reader.text()) } catch (e) { parsed = null }
    }
    reader.path = ""
    if (parsed === null) return
    if (!root._sameUsageMap(root.usageMap, parsed.map)) root._setUsageMap(parsed.map)
    root.hasUsageHistory = parsed.hasHistory === true
    root._publish()
  }

  property bool _usageReadArmed: false
  function _readUsageMap() {
    if (root._usageReadArmed) return
    root._usageReadArmed = true
    // Direct assignment, never bounced through "": the bounce's intermediate
    // load fails async and its loadFailed continuation clears this latch
    // before the real read lands, so the real read is dropped and the map
    // never populates (frequency sort stays alphabetical). Same-path is the
    // only case that needs a kick, and that is what reload() is for.
    if (drunReader.path === Paths.drunCacheFile) drunReader.reload()
    else drunReader.path = Paths.drunCacheFile
  }

  // Continuation of the usage read. An unreadable or unparsable cache
  // leaves the map as it was: a launch bumped a counter the stale file
  // has not caught up with yet, and a stale read must not take that
  // increment back. A read that does replace the map is a change to it,
  // and moves the revision with it - then republishes the open. A write
  // armed while the read was in flight wins outright: the disk the read
  // saw predates the increment, so applying it would rewind the map.
  function _finishUsageRead(ok) {
    if (!root._usageReadArmed) return
    root._usageReadArmed = false
    if (ok === true && !saveDebounce.running) {
      const parsed = LauncherLib.parseUsageText(drunReader.text())
      if (parsed !== null && !root._sameUsageMap(root.usageMap, parsed.map)) {
        root._setUsageMap(parsed.map)
        // The read lands after the construction/open index build (async,
        // so the build ranked against the previous map): rebuild here or
        // frequency mode keeps the pre-read order. Alphabetical mode reads
        // no usage, so it skips the rebuild the gate would otherwise run.
        if (root.sortMethod === "frequency") {
          root._rebuildAppIndex()
          if (AppLauncher.visible) root.recompute()
        }
      }
    }
    root._publish()
  }

  // Best-effort barrier: a count must be on disk before the next launch
  // reads it back. `sync` waits for the write; the destruction flush
  // below passes false (see there). Guarded either way: a fault must
  // drop the write, not the shell.
  function _saveUsage(sync) {
    try {
      drunWriter.setText(LauncherLib.serializeUsage(root.usageMap))
      if (sync !== false) drunWriter.waitForJob()
    } catch (e) {}
  }

  function _incrementUsage(entryId) {
    // bumpUsage answers with the next MAP, so the map is what is assigned
    // and the revision moves with the assignment rather than out of the
    // library call: the map is written from three more places (the
    // druncache read, a history clear, the free-while-closed path), and a
    // revision that only one of them moved would be no revision at all.
    const next = LauncherLib.bumpUsage(root.usageMap, entryId)
    if (next === null) return
    root._setUsageMap(next)
    root.hasUsageHistory = true
    root._publish()
    saveDebounce.restart()
  }

  // Keep hasUsageHistory live from disk - standalone watcher that does
  // not interfere with the on-demand drunReader cache. The probe read is
  // async like the map read above; the registry side effects ride the
  // continuation, and _publish follows them as it did synchronously.
  function _syncHasHistory() {
    root._readHistoryState()
  }

  property bool _historyReadArmed: false
  function _readHistoryState() {
    if (root._historyReadArmed) return
    root._historyReadArmed = true
    // Direct assignment, same reason as _readUsageMap above: a "" bounce
    // drops the real read on its intermediate failure and hasUsageHistory
    // never updates.
    if (historyProbe.path === Paths.drunCacheFile) historyProbe.reload()
    else historyProbe.path = Paths.drunCacheFile
  }

  function _finishHistoryRead(ok) {
    if (!root._historyReadArmed) return
    root._historyReadArmed = false
    const prev = root.hasUsageHistory
    // A file this read cannot reach reports no history, unlike the map
    // read above which keeps what it had: the menu row must hide the
    // moment the file is gone, and the map may outlive its own file by a
    // debounce window.
    const parsed = ok === true ? LauncherLib.parseUsageText(historyProbe.text()) : null
    const has = parsed !== null && parsed.hasHistory
    if (root.hasUsageHistory !== has) root.hasUsageHistory = has
    if (prev === root.hasUsageHistory || !Registry.get("menu", "open")) {
      root._publish()
      return
    }
    if (!root.hasUsageHistory) Registry.call("menu", "collapseClearHistory")
    Registry.call("menu", "bumpCondRev")
    root._publish()
  }

  // Registry API: clear the most-used cache. Called directly by the
  // settings menu's confirmation dropdown - no shell boilerplate.
  // The menu row's collapse animation owns the timing; the caller
  // (Entry) bumps Menu.condRev after collapsing so the hide is
  // deferred until the dropdown finishes closing (see MenuPanel
  // scheduleCondReveal). The file watcher remains the source for
  // external deletions.
  function clearUsageHistory() {
    if (LauncherLib.usageHistoryEmpty(root.hasUsageHistory, root.usageMap)) {
      return false
    }
    // Read before the stop below, because the flag is gone after it: a queued
    // write that was still in flight is one of the two things this clear costs,
    // and it is the one that would otherwise have landed after the unlink.
    const writeInFlight = saveDebounce.running
    if (saveDebounce.running) saveDebounce.stop()
    const path = Paths.drunCacheFile
    // Best-effort remove; FileView watcher will confirm.
    AppLauncher.execDetached(["rm", "-f", "--", path])
    // How many rows went, and not what they were: a usage row names the app
    // the user opened and how often, which is a history of their day.
    Log.info("cleared usage history, was " + Object.keys(root.usageMap || {}).length)
    // The parent of this DEBUG is the INFO above, which is allowed to carry the
    // count and nothing else. What the count does not say is the rest of the
    // cost of the same event: a queued write was dropped rather than flushed,
    // and only the frequency sort pays for an index rebuild. A count and two
    // flags, and the key count is inside the gate because enumerating the map
    // is more than a concat. No name appears here either - a usage row is the
    // user's day, and a DEBUG band is still a log.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("cleared " + Object.keys(root.usageMap || {}).length + " rows, queued write dropped "
        + writeInFlight + ", frequency index "
        + (root.sortMethod === "frequency" ? "rebuilt" : "left in place"))
    }
    root._setUsageMap({})
    root.hasUsageHistory = false
    // Published before the answer, so a caller that reads the facade the
    // moment after this returns sees the cleared cache and not the one it
    // just emptied.
    root._publish()
    if (root.sortMethod === "frequency") {
      root._rebuildAppIndex()
      if (AppLauncher.visible) root.recompute()
    }
    return true
  }

  // --- settings persistence ---
  //
  // Plugin enable/disable lives in the raw settings section
  // shell.appLauncher.plugins. Written ONLY on explicit toggles - a
  // construction or a rescan never mutates the user file.

  function _persistedPlugins() {
    return LauncherLib.persistedPluginList(Settings.rawSection("appLauncher"))
  }

  function setPluginEnabled(id, enabled) {
    const cfg = LauncherLib.pluginById(root.plugins, id)
    if (cfg !== null) {
      cfg.enabled = enabled === true
      root._applyEnablement()
      root.persistPlugins()
      return true
    }
    // An unresolved registry holds no config for anything, so a miss here is
    // not a refusal. The requested state goes to settings instead, where the
    // persisted overlay in buildPluginConfigs applies it on the build that
    // follows - so the settings menu's first keystroke on a plugin toggle,
    // which is what demands this tree, is not swallowed by a scan that has
    // not landed yet.
    if (!root.pluginsResolved) {
      Settings.setRawSection("appLauncher", "plugins",
        LauncherLib.persistedPluginWithState(root._persistedPlugins(), id, enabled === true))
      return true
    }
    return false
  }

  // Menu provider write, called by the facade: route through
  // setPluginEnabled so enablement, prefix rebuild and settings.json flush
  // stay on one path, then bump the menu's own condition index so the row
  // repaints. Returns true exactly when the menu should stop (it handled
  // the flip).
  function pluginToggleCommit(menuId, state) {
    const pid = String(menuId ?? "").replace(/^launcher-/, "")
    const ok = root.setPluginEnabled(pid, state === true)
    if (ok && typeof Menu !== "undefined" && Menu._buildCondIndex) {
      Menu._buildCondIndex()
      Menu.rev++
    }
    return ok
  }

  // Write the full merged configs so the file documents itself; entries
  // for plugins that are currently undiscovered stay untouched.
  function persistPlugins() {
    Settings.setRawSection("appLauncher", "plugins",
      LauncherLib.pluginConfigsForPersist(root._persistedPlugins(), root.plugins))
  }

  // --- staged rows and activation ---

  function activate(row) {
    if (!row || row.kind === "separator") return
    switch (row.kind) {
      case "app":
        root._launchApp(row)
        break
      case "calc":
      case "fx":
      case "time":
      case "unit":
      case "color": {
        if (row.incomplete === true || row.timeInvalid === true) break
        const ok = root._safeActivate(row.plugin, row.item, AppLauncher.entry)
        if (ok) AppLauncher.close()
        break
      }
      case "web":
        // Hint rows (empty query, see _webRows) never launch: opening the
        // bare engine endpoint with no terms is never useful.
        if (row.incomplete === true) break
        root._runWeb(row)
        break
      case "file":
        root._openPath(row)
        break
    }
  }

  function confirmDelete(row) {
    if (!row || !row.app || !row.app.id) return
    let id = String(row.app.id)
    if (!id.endsWith(".desktop")) id += ".desktop"
    const path = Paths.home + "/.local/share/applications/" + id
    AppLauncher.execDetached(["rm", "-f", "--", path])
    root._rebuildAppIndex()
    root.recompute()
  }

  // --- child resources ---

  // Parked reader: safe against missing files (returns null), never ties
  // up the watched views other components rely on.
  FileView {
    id: reader

    printErrors: false
  }

  // druncache readers/writers (frequency sort). Reads are async
  // (loaded/loadFailed continue below); the write stays a sync barrier
  // so a count is on disk before the next launch reads it back.
  FileView {
    id: drunReader
    printErrors: false
    onLoaded: root._finishUsageRead(true)
    onLoadFailed: root._finishUsageRead(false)
  }
  FileView { id: drunWriter; path: Paths.drunCacheFile; atomicWrites: true; printErrors: false }

  // Watcher for hasUsageHistory - live without holding the cache resident.
  FileView {
    id: historyWatcher
    path: Paths.drunCacheFile
    watchChanges: true
    printErrors: false
    onFileChanged: root._syncHasHistory()
    onLoaded: root._syncHasHistory()
    onLoadFailed: root._syncHasHistory()
  }
  FileView {
    id: historyProbe
    printErrors: false
    onLoaded: root._finishHistoryRead(true)
    onLoadFailed: root._finishHistoryRead(false)
  }

  Timer {
    id: saveDebounce
    interval: 400
    onTriggered: {
      root._saveUsage()
      root._syncHasHistory()
      if (root.sortMethod === "frequency") {
        if (AppLauncher.visible) {
          root._rebuildAppIndex()
          root.recompute()
        } else {
          // Free frequency cache while closed - next open will reread
          root._setUsageMap({})
        }
      }
    }
  }

  // One-shot stat probe for the file-opener rows: prints "<seq> dir |
  // file | missing" for the quoted path. The verdict lands in statCache
  // keyed by path; aborted runs are ignored via the echoed generation.
  Process {
    id: pathStatProc

    property int seq: 0
    property string path: ""
    property string out: ""

    stdout: SplitParser {
      onRead: data => {
        pathStatProc.out = data.trim()
      }
    }

    onExited: root._onStatProbed()
  }

  // PATH scan for the binary-launch fallback row (see requestBinaries).
  // One executable basename per line in PATH order, thousands of them on a
  // real install, so the whole stdout is collected and parsed once at exit
  // rather than split per line; the verdict lands in binCache and recomputes
  // the list in place.
  Process {
    id: binProc

    stdout: StdioCollector { id: binOut }
    stderr: StdioCollector {}

    onExited: root._onBinariesScanned()
  }

  // Shared clock probe for the "time in <city>" rows (see requestTime).
  // Single line "<time>|CODE|OFFSET|DATE>"; the verdict lands in timeCache
  // keyed by zone and recomputes the list in place.
  Process {
    id: timeProc

    property string zone: ""
    property string out: ""

    stdout: SplitParser {
      onRead: data => {
        timeProc.out = data.trim()
      }
    }

    onExited: root._onTimeProbed()
  }

  // Keeps a visible clock row ticking: fresh cache (TTL 15s) answers the
  // 10s tick without spawning, so a minute flips at most ~15s late.
  // Runs only while a live (non-error) time row is on screen.
  Timer {
    id: timeTick

    interval: 10000
    repeat: true
    running: AppLauncher.visible && root.results.length === 1
      && root.results[0] && root.results[0].kind === "time"
      && root.results[0].timeInvalid !== true
    onTriggered: {
      if (AppLauncher.visible) root.recompute()
    }
  }

  // --- file helpers ---

  // The one whole-file text read in this file: the granted plugin read the
  // facade forwards, and the manifest/source read discovery needs. One
  // parked FileView serves both, and it is never given a path until a
  // caller that already passed the grant or the discovery gate asks.
  function readPluginFile(path) {
    reader.path = ""
    reader.path = path
    if (!reader.waitForJob()) return null
    return reader.text()
  }

  function _readJsonFile(path) {
    const text = root.readPluginFile(path)
    if (text === null) return null
    try {
      return JSON.parse(LauncherLib.stripJsonc(text))
    } catch (e) {
      return null
    }
  }

  // Panel body: see the ownership note on AppLauncherView in the
  // facade file - windows live there, outside this Loader, so this
  // unload cascade only ever takes data, never surfaces.
}

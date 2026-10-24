pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "SettingsLib.js" as SL
import "../log/LogSpec.js" as Spec
import "../text/UnitIpc.js" as UnitIpc

// Schema-driven settings store. Single source of truth for every managed
// option:
//
//   schema    $VIBRANIUM/default/vibranium/settings/ (a directory: one
//             file per page family, with _index.jsonc for the root chrome)
//   user      ~/.config/vibranium/settings.json          (sparse overrides)
//
//   File layout: EVERYTHING except "options" lives under the "shell"
//   namespace - shell.wallpaper.*, shell.lockscreen.*,
//   shell.statusbar.* - because those belong to the Quickshell shell.
//   "options" holds the VIBRANIUM_* env-projected overrides. The old
//   flat layout (top-level wallpaper/lockscreen/statusbar) folds into
//   shell.* on load and is rewritten in normalized shape on next flush.
//   bash env  $VIBRANIUM_RUNTIME/settings.env            (atomic swap,
//             single bash contract; a watcher re-renders it if the file
//             is deleted or tampered with while the shell runs)
//
// Validation happens here, once, on the write path. Bash scripts never
// validate - they source an already-valid env projection. The menu binds
// rows through var-keyed items and listens to optionChanged for reverse
// sync; IPC target "settings" exposes get/set/toggle/dump/reload, and
// status reports the fault state and the rejected-override count.
//
// Persistence is non-destructive: a rejected override runs the session on
// the schema default and never reaches the file, and a file the store
// cannot read (malformed, unreadable, unwritable) is left exactly as it is
// while the fault holds the write back.
//
// Ownership split: the pure algorithm of validation, schema indexing,
// composition and the raw-section shape lives in SettingsLib.js, and this
// file keeps every VALUE, every watcher, every signal and every write. The
// functions below that remain here are committing wrappers - they read this
// store's state, hand it to a pure helper and publish the result back into
// the same fields, so the lib is never a second copy of anything. Watchers,
// the rev counter and the invalidation path are deliberately untouched
// (spec 09's measurement of rev breadth is still open).
//
//   Extra sections of settings.json outside the schema (wallpaper)
//   stay file-native: preserved verbatim on every flush, mutated through
//   their typed setters below. A key under shell the schema does not manage
//   is carried the same way, as a foreign field, whoever once read it. The
//   statusbar subtree is schema-managed (enabled/position/showBorder/
//   showShadow/layout + module toggles).
Singleton {
  id: root

  // Eager-boot hook for shell.qml, matching the Menu/Wallpaper pattern.
  readonly property string tag: "settings"

  // Flips true once schema + user data landed; consumers gate first paint.
  property bool ready: false

  // Coarse "something changed" signal, bumped on every mutation. DEFERRED:
  // _commit schedules the bump instead of doing it inline, so for up to one
  // event-loop turn `rev` still names the PREVIOUS generation while `values`
  // already holds the new one. Consequences, both intentional:
  //
  //   - a reader that captures rev in a binding is simply re-evaluated a
  //     turn later. Every such reader also captures `values` (through
  //     value()), which IS replaced synchronously, so nothing settles late.
  //   - a reader that READS rev as a value and compares it against something
  //     recorded earlier (a cache signature, a "did it change" probe) can
  //     observe the gap and is wrong. Do not do that. Sign such a structure
  //     on `values`, whose replacement is synchronous in both writers
  //     (_commit, _publish). Menu._buildFromFile's bundle cache is the one
  //     such reader in the tree.
  //
  // The two signal mutations outside _commit (a source/write fault, a raw
  // section edit) bump rev synchronously: nothing defers them, so they are
  // not part of the gap this comment is about.
  property int rev: 0

  // Parsed schema: ordered category sections plus canonical key lookup.
  property var _schema: null
  readonly property var sections: root._schema ? root._schema.sections : []

  // Resolved values, sharded by key so a one-key write does not re-evaluate
  // every reader in the tree.
  //
  // A binding captures every property its expression reads. `value(key)` used
  // to read `values` and nothing else, so writing ONE key replaced the map
  // and re-evaluated all 64 value readers - measured at 30ms of synchronous
  // UI-thread stall before the menu even heard a toggle had happened. That is
  // O(readers) per write, the wrong shape for a keyed lookup.
  //
  // So the map is split eight ways and `value()` reads only the shard its key
  // hashes to: a write replaces one shard and re-evaluates roughly an eighth
  // of the readers. The shards must be eight SEPARATE properties - an indexed
  // read into one `var` array captures the whole array and every shard would
  // invalidate together, which is the thing being fixed.
  //
  // Hash collisions cost a little redundant work and can never miss an
  // update, which is the right way round for an invalidation scheme. The
  // eight-way split is arbitrary; it only divides ~64 readers into ~8 groups.
  property var _shard0: ({})

  property var _shard1: ({})

  property var _shard2: ({})

  property var _shard3: ({})

  property var _shard4: ({})

  property var _shard5: ({})

  property var _shard6: ({})

  property var _shard7: ({})

  // The whole map, for the few readers that iterate it. Derived from the
  // shards, so the shards stay the single source of truth and this cannot
  // drift from them. It notifies whenever any shard does, which is exactly
  // the old behaviour for whole-store readers.
  readonly property var values: {
    const m = {}
    for (const k in root._shard0) m[k] = root._shard0[k]
    for (const k in root._shard1) m[k] = root._shard1[k]
    for (const k in root._shard2) m[k] = root._shard2[k]
    for (const k in root._shard3) m[k] = root._shard3[k]
    for (const k in root._shard4) m[k] = root._shard4[k]
    for (const k in root._shard5) m[k] = root._shard5[k]
    for (const k in root._shard6) m[k] = root._shard6[k]
    for (const k in root._shard7) m[k] = root._shard7[k]
    return m
  }

  function _shardOf(key) {
    let h = 0
    const s = String(key)
    for (let i = 0; i < s.length; i++)
      h = (h * 31 + s.charCodeAt(i)) & 7
    return h
  }

  // The shard a key lives in. Reading it is what a caller's binding ends up
  // depending on - no separate touch is needed, because the read that
  // fetches the value is the dependency.
  function _shardOfMap(key) {
    const s = root._shardOf(key)
    if (s === 0) return root._shard0
    if (s === 1) return root._shard1
    if (s === 2) return root._shard2
    if (s === 3) return root._shard3
    if (s === 4) return root._shard4
    if (s === 5) return root._shard5
    if (s === 6) return root._shard6
    return root._shard7
  }

  function _putShard(key, v) {
    const s = root._shardOf(key)
    const m = Object.assign({}, root._shardOfMap(key))
    m[key] = v
    if (s === 0) root._shard0 = m
    else if (s === 1) root._shard1 = m
    else if (s === 2) root._shard2 = m
    else if (s === 3) root._shard3 = m
    else if (s === 4) root._shard4 = m
    else if (s === 5) root._shard5 = m
    else if (s === 6) root._shard6 = m
    else root._shard7 = m
  }

  function _replaceAllShards(map) {
    const s = [ {}, {}, {}, {}, {}, {}, {}, {} ]
    for (const k in map) s[root._shardOf(k)][k] = map[k]
    root._shard0 = s[0]
    root._shard1 = s[1]
    root._shard2 = s[2]
    root._shard3 = s[3]
    root._shard4 = s[4]
    root._shard5 = s[5]
    root._shard6 = s[6]
    root._shard7 = s[7]
  }

  // Sparse user overrides, keyed canonically. Only normalized,
  // schema-valid values live here: this map is the single input to
  // persistence, so an invalid raw override cannot reach the file.
  property var _overrides: ({})

  // Parsed source of the last resolve, kept verbatim for diagnostics.
  // Unlike _lastRaw it is never rewritten by a commit or a flush.
  property var _raw: ({})

  // One message per override the schema rejected on the last load.
  property var _issues: []

  // Fault state. "" is healthy. A source fault ("malformed" | "unreadable")
  // means the user file is not something this store may write over; a
  // write fault ("readonly") means the write itself failed. Either one
  // blocks the user-file write while the session keeps running on schema
  // defaults and a freshly rendered env projection.
  property string fault: ""
  property string writeFault: ""
  readonly property bool faulted: root.fault !== "" || root.writeFault !== ""

  // True while a failed load has not yet reported why. A missing and an
  // unreadable file fail the blocking load identically, so the write path
  // stays closed until the queued loadFailed code tells them apart.
  property bool _readPending: false

  // Keys committed since the last flush; survives external-edit re-apply.
  property var _dirty: ({})

  // Last parsed user file this store is still willing to persist from,
  // kept verbatim for foreign-section preservation.
  property var _lastRaw: {}

  signal optionChanged(string key, var value)
  signal optionError(string key, string message)

  readonly property bool wallpaperEnabled: root.value("shell.wallpaper.enabled") !== false
  // Monochrome emoji mosaic fallback for the wallpaper-off state; safe default is off so
  // existing installs keep the plain theme tint.
  readonly property bool wallpaperMosaic: root.value("shell.wallpaper.mosaic") === true
  // Mosaic density (filled grid cells). Malformed values fall back to medium.
  readonly property string wallpaperMosaicIntensity: {
        const v = root.value("shell.wallpaper.mosaicIntensity")
    return root.wallpaperMosaicIntensityLevels.indexOf(v) >= 0 ? v : "medium"
  }
  // Mosaic glyph size. Malformed values fall back to medium.
  readonly property string wallpaperMosaicSize: {
        const v = root.value("shell.wallpaper.mosaicSize")
    return root.wallpaperMosaicSizeLevels.indexOf(v) >= 0 ? v : "medium"
  }
  // The bar's master switch is a schema option (values.read, instant) that
  // flushes to the same shell.statusbar.enabled leaf; raw statusbar readers
  // that also name it stay in sync via the flush-echo. Guarded to true
  // before the schema catalog lands.
  readonly property bool statusbarEnabled: root.value("shell.statusbar.enabled") !== false
  readonly property bool statusbarShowBorder: root.value("shell.statusbar.showBorder") === true
  readonly property bool statusbarShowShadow: root.value("shell.statusbar.showShadow") === true
  readonly property bool statusbarBlurred: root.value("shell.statusbar.blurred") === true
  // ArchUpdates island heavy-backlog caution (red box + red total).
  // Default on; the island folds every consumer off the same flag.
  readonly property bool statusbarArchUpdatesHeavyWarning: root.value("shell.statusbar.archUpdatesHeavyWarning") !== false

  readonly property bool blurBackground: root.value("shell.lockscreen.blurBackground") !== false
  readonly property string lockscreenBlurPower: {
        const v = root.value("shell.lockscreen.blurPower")
    return root.blurPowerLevels.indexOf(v) >= 0 ? v : "medium"
  }
  // Backdrop source mode. Any malformed or missing value resolves to screen
  // so pre-existing configs keep the captured-screen backdrop unchanged.
  readonly property string lockscreenBackgroundMode: {
        const v = root.value("shell.lockscreen.backgroundMode")
    return v === "background" ? v : "screen"
  }
  // Backdrop vignette level. Unknown or missing values resolve to off so
  // pre-existing configs keep the unmodified backdrop.
  readonly property string lockscreenVignette: {
        const v = root.value("shell.lockscreen.vignette")
    return root.vignetteLevels.indexOf(v) >= 0 ? v : "off"
  }
  readonly property int lockscreenDim: {
        const v = root.value("shell.lockscreen.dim")
    return typeof v === "number" && v >= 0 && v <= 100 ? v : 50
  }
  readonly property int lockscreenDimBlurred: {
        const v = root.value("shell.lockscreen.dimBlurred")
    return typeof v === "number" && v >= 0 && v <= 100 ? v : 50
  }
  readonly property bool lockscreenNowPlaying: root.value("shell.lockscreen.nowPlaying") !== false
  readonly property bool lockscreenPauseMusic: root.value("shell.lockscreen.pauseMusic") !== false
  // The always-on copy of the capture dots for when the bar cannot be seen
  // (a fullscreen toplevel covers the bar's Bottom layer surface). Default
  // on: an indicator that vanishes under a fullscreen app is the case the
  // overlay exists for, and a capture is exactly what a user must not miss.
  readonly property bool privacyOverlay: root.value("shell.privacy.overlay") !== false

  // There is deliberately no log-level projection here. The log is configured
  // by `VIBRANIUM_SHELL_LOG` alone, so this store has no `shell.log` or
  // `shell.logScopes` key to project - and no reason to know the log layer
  // exists. A settings option the logger does not read is worse than none: it
  // looks like it works.
  // Corner the overlay dots sit in. A malformed persisted value resolves to
  // top-right so a file that predates the setting, or an edited one, keeps a
  // corner rather than collapsing the row off-screen.
  readonly property string privacyPosition: {
        const v = root.value("shell.privacy.position")
    return root.privacyPositions.indexOf(v) >= 0 ? v : "top-right"
  }

  // --- night light temperature (shell.statusbar.nightLightTemperature) ---
  // The temperature hyprsunset applies. The schema owns validation
  // (2000..20000 K inclusive, step 100); a malformed persisted value falls
  // back to the schema default here.
  readonly property int nightLightTemperature: {
        const v = root.value("shell.statusbar.nightLightTemperature")
    return typeof v === "number" && v >= 2000 && v <= 20000 ? Math.round(v) : 6000
  }

  readonly property string statusbarPosition: {
    root.rev
    const raw = root._lastRaw || {}
    const sb = raw.shell && typeof raw.shell === "object" ? raw.shell.statusbar : null
    const pos = sb && typeof sb === "object" ? sb.position : null
    return root.statusbarPositions.indexOf(pos) >= 0 ? pos : "top"
  }

  // Zone layout: single source of truth for the bar (shell.statusbar.layout,
  // default in settings.jsonc). Zones hold EVERY known slot in its last
  // dragged order - including disabled ones - while `disabled` is a dumb
  // on/off list of static module ids. Disabled ids keep their zone gaps,
  // so re-enabling restores order. Owned dynamic modules (caffeine, timer,
  // recording, readingMode, update) live in zones too but never enter
  // `disabled`: they cannot be disabled, only re-arranged, and control
  // their own visibility internally. The store holds a schema-valid
  // layout, so the single structural gate (SL.validateLayout) is all the
  // read path needs; a rejected value falls back to the schema default.
  readonly property var statusbarLayout: {
        const check = SL.validateLayout(root.value("shell.statusbar.layout"))
    if (!check.error) return check.value
    const opt = root.byKey("shell.statusbar.layout")
    return opt !== null ? opt.default : { left: [], center: [], right: [], disabled: [] }
  }

  readonly property var blurPowerLevels: ["low", "medium", "high"]
  readonly property var vignetteLevels: ["off", "small", "medium", "large", "gigantic"]
  readonly property var statusbarPositions: ["top", "bottom"]
  readonly property var privacyPositions: ["top-right", "top-left", "bottom-right", "bottom-left"]
  readonly property var wallpaperMosaicIntensityLevels: ["sparse", "medium", "dense"]
  readonly property var wallpaperMosaicSizeLevels: ["small", "medium", "large", "very_large"]

  // --- idle daemon settings (shell.idle) ---
  //
  // Persisted as one object under the idle namespace: an enabled flag
  // plus a strictly increasing timer list. SettingsLib owns the contract -
  // positive integer minutes, known actions, known declared class, strict
  // order - and a write path here rejects rather than committing a list
  // that breaks it. An empty list is legal in any state: a daemon with
  // nothing armed simply never fires.
  //
  // A row's declared class is what the daemon's inhibitor guard reads, so
  // the shipped rows declare theirs: a lock command guarded by the idle
  // blockers, a suspend command by the sleep blockers. Every timer is a
  // command - there is no lock or suspend action to pick - so the shipped
  // list is the project's own session verbs, the same two the catalog
  // ships.

  readonly property var _defaultIdleTimers: [
    { minutes: 10, action: "command", command: "vb-shell session lock", commandClass: "lock" },
    { minutes: 15, action: "command", command: "vb-shell session suspend", commandClass: "suspend" }
  ]

  readonly property bool idleEnabled: root.value("shell.idle.enabled") !== false

  // Validated timer list from the store. Structural validation lives in
  // SettingsLib (one validator, unit-tested); the fallback to the default
  // list is the feature policy: the daemon must always arm. A valid empty
  // list stays empty in any state - nothing armed, nothing fires. Rows
  // stored before the class field existed are reconciled on read against
  // the project's own session verbs, so a stored lock or suspend timer
  // reaches the inhibitor guard instead of running ungated.
  readonly property var idleTimers: {
        const list = root.value("shell.idle.timers")
    if (SL.validateIdleTimers(list) !== "") return root._defaultIdleTimers.slice()
    return SL.normalizeIdleTimers(list)
  }

  // Write-path validation used by Settings and the idle IPC surface.
  // Returns "" when `list` is a legal timer list, else an error string.
  // Pure logic lives in SettingsLib (unit-tested); this stays a thin
  // wrapper so the daemon and IPC keep calling Settings.
  function validateIdleTimers(list) {
    return SL.validateIdleTimers(list)
  }

  // Whether the read path declares this command on its own, which is what
  // stops a writer from "clearing" a declaration that comes straight back.
  function declaresOwnCommand(command) {
    return SL.declaresOwnCommand(command)
  }

  // Commit a validated timer list. Returns an error string when
  // rejected; on success the prior configuration is replaced atomically.
  function setIdleTimers(list) {
    const err = root.validateIdleTimers(list)
    if (err !== "") {
      return err
    }
    root._commit("shell.idle.timers", SL.buildIdleTimerRows(list), "")
    return ""
  }

  // Commit the enabled flag. Returns an error string when rejected. The
  // accepted spellings are SettingsLib's; the message names this key.
  function setIdleEnabled(v) {
    const check = SL.coerceBool(v)
    if (!check.ok) return "enabled must be true or false"
    root._commit("shell.idle.enabled", check.value, "")
    return ""
  }

  Component.onCompleted: {
    Registry.offer("settings", {
      title: "Settings",
      description: "settings engine store",
      verbNames: [
        "dump",
        "get",
        "reload",
        "set",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    // Watch governor for external edits (K2) - replaces FileView watchers
    root._settingsWatchUnsub = Watch.subscribe(Paths.settingsFile, (text) => {
      root._loadUser()
    })

    root._envWatchUnsub = Watch.subscribe(Paths.runtimeEnvFile, (text) => {
      root._restoreRuntimeEnv()
    })
    // Single deterministic boot chain: schema scan -> user load. Runtime
    // and state dirs exist by then - created at session startup.
    root._loadSchema()
  }
  Component.onDestruction: {
    if (root._settingsWatchUnsub) root._settingsWatchUnsub()
    if (root._envWatchUnsub) root._envWatchUnsub()
  }

  // --- generic store API ---

  // Non-copying read for hot bindings. A reader's binding captures
  // `values` through this property read, so replacing the map is what
  // re-evaluates it. It must NOT also capture `rev`: a commit replaces
  // `values` and bumps `rev`, and a reader bound to both would be
  // evaluated once per write, doubling the store's invalidation cost on
  // every toggle. Consumers that need the broader "something changed"
  // signal capture `rev` themselves and keep doing so.
  function value(key) {
    // Reads the key's shard, NOT `values`: that read is the dependency the
    // caller's binding takes, and it is narrow on purpose - see the note on
    // _shard0.
    return root._shardOfMap(key)[key]
  }

  function setOption(key, v, hook) {
    const opt = root.byKey(key)
    if (!opt) {
      root.optionError(key, "unknown option")
      return false
    }
    const check = SL.validateValue(opt, v)
    if (!check.ok) {
      root.optionError(key, check.error)
      return false
    }
    root._commit(key, check.value, hook || "")
    return true
  }

  function toggleOption(key, hook) {
    const cur = root.value(key)
    return root.setOption(key, !(cur === true), hook)
  }

  function byKey(key) {
    return root._schema && root._schema.byKey[key] !== undefined ? root._schema.byKey[key] : null
  }

  // Evaluate a normalized showIf list against current values. Transitive
  // + cycle-safe (see SettingsLib.conditionsMet).
  function conditionsMet(showIf) {
    if (!root._schema) return true
    root.rev
    return SL.conditionsMet(root._schema.byKey, root.values, showIf)
  }

  // Coalesced rev bump. A commit invalidates the whole dependent set
  // twice: once by replacing `values`, once by bumping `rev`. Both passes
  // are synchronous and each one is expensive, so doing them in the same
  // turn made every settings write a single stall of roughly the sum of
  // the two - and `optionChanged`, which is what a listener such as the
  // menu's conditional reveal waits on, could not be delivered until the
  // second pass had finished. Deferring the bump keeps both signals and
  // their meaning; it only moves one pass to the next turn, which halves
  // the worst-case stall and lets the commit be observed immediately.
  // Coalesced so a burst of commits in one tick costs one bump, not one
  // per commit.
  property bool _revPending: false

  function _bumpRev() {
    root.rev++
  }

  function _scheduleRevBump() {
    if (root._revPending) return
    root._revPending = true
    // The flag is cleared BEFORE the bump, so a commit raised from inside
    // the bump's own invalidation pass schedules a fresh bump instead of
    // being swallowed: no write can lose its bump.
    Qt.callLater(() => {
      root._revPending = false
      root._bumpRev()
    })
  }

  function _commit(key, v, hook) {
    // Read BEFORE the shard is replaced: the line reports a transition, so
    // both sides of it have to be real values rather than the new one twice.
    // The shard map is read directly rather than through `value()` so this
    // does not touch `rev` - a commit that registered a dependency on the
    // store's own invalidation would be a cycle. A `setOption` refused
    // upstream never reaches here, so this fires on a change, not an attempt.
    const before = root._shardOfMap(key)[key]

    // One key changes, so one shard is replaced. `values` is derived and
    // follows; nothing here rebuilds the whole map for the readers that
    // iterate it.
    root._putShard(key, v)

    // Every option change is one INFO line, under a CLAIMED `settings` scope
    // rather than the derived `settings.settings`: the file and the domain are
    // not the same name, and `at()` is what that is for.
    //
    // The values go through `summarize` and never through `stringify` - a bar
    // layout is a thirty-field object and an array is never joined, so neither
    // is printed whole.
    const line = Log.at("settings")
    if (key.indexOf(".") < 0) {
      // A key with NO dot is an `env.*` projection: bare names
      // (`RECORDING_FPS`), landing in `settings.json:options`, and the one
      // option family whose value a user can paste a token into. The name is a
      // fixed catalog enum and is safe; the value is not, so both sides are
      // hidden and what remains is the key alone.
      //
      // DEBUG, not INFO: a line carrying a key name and two `<hidden>`s answers
      // almost nothing at the level a reader is reading for "what did the shell
      // do", and these writes are the store maintaining a projection rather
      // than a person changing a setting. An earlier version of this comment
      // claimed the rendered env file is watched and re-imported as options,
      // making these lines an echo on every shell start. That was wrong -
      // `_restoreRuntimeEnv` only renders and then normalises, and no path
      // reads values back out of that file.
      line.debug(key + ": <hidden>, env projection")
    } else {
      line.info(key + ": " + Spec.summarize(before) + " > " + Spec.summarize(v))
      // Whether the new value deviates from the schema default is what decides
      // if it is written to the user file at all, so a setting that "did not
      // save" is almost always this rather than a failed write. The default is
      // read again here rather than reusing the `def` further down, which is
      // declared after this block and would be a reference before its
      // initialisation.
      line.debug(key + " " + (SL.valuesEqual(v, root.byKey(key).default)
        ? "matches the default, not written"
        : "deviant, written as an override"))
    }

    // Overlay rule: the user file holds deviants only. A value that
    // matches the schema default holds no override - setting an option
    // back to its default removes it from the file again. The comparison
    // itself is SettingsLib's, so the store and its test simulation run
    // one definition of "this value is a deviant".
    const def = root.byKey(key).default
    const ov = Object.assign({}, root._overrides)
    if (SL.valuesEqual(v, def)) delete ov[key]
    else ov[key] = v
    root._overrides = ov
    root._dirty[key] = true

    // The signal goes out while `rev` still names the previous generation -
    // by design, and the deferred bump is what keeps it that way: the signal
    // and the bump are one event-loop turn apart. A handler that
    // needs to know "the store moved" must read `values` (or the signal's
    // own payload), never `rev`; see the note on `rev`.
    root.optionChanged(key, v)
    root._scheduleRevBump()

    if (hook !== "") root._pendingHooks.push(hook)
    root._scheduleFlush()
  }

  // --- schema loading ---

  // Read a whole catalog file list concurrently, one parked FileView per file.
  // Shared with MiscSettings, so the read shape and the bail below cannot drift
  // between the two stores.
  //
  // Parked, not re-pointed, because overlap is the whole point: one view holds
  // one path, so re-pointing a single view can only ever have one read in
  // flight and the files serialise again - and re-pointing a view that has
  // already loaded additionally needs the `path = ""` reset, or waitForJob
  // answers false while text() hands back the previous body. A view per file
  // needs neither.
  //
  // The barrier is the whole design: preload defaults true, so setting a path
  // starts the read in the background, and every path is set before any
  // waitForJob. Pointing a view and waiting on it immediately starts and
  // finishes a read before the next path is set, which serialises exactly like
  // the reused view did while also paying for N object constructions.
  //
  // Returns the texts in file order, or null if any read did not report
  // success.
  //
  // What keeps the set all-or-nothing is that parseCatalogDir has no notion of
  // a file that is missing: it merges what it is handed into one option set,
  // so a set missing a file would yield a schema that looks complete and
  // silently drops every option the unread file declared. Two things keep that
  // from happening and both are load-bearing:
  //
  //   - null. Measured on this Quickshell: a path that does not exist, or one
  //     that cannot be read, still answers waitForJob() true and hands back
  //     the empty string, so this arm does not fire for a broken file and
  //     cannot be the only guard.
  //   - the empty string. parseCatalogDir throws on it (JSON.parse of the
  //     stripped text), the caller's try/catch drops the catalog, and the
  //     store is left with no options. That is the path a broken file
  //     actually takes, and it is why the failure is reported rather than
  //     swallowed: a store with no options is a settings page that says
  //     nothing, and the reason belongs in the log.
  //
  // Neither is added here: the second is the caller's, unchanged.
  function readCatalogTexts(parent, files) {
    const n = files.length
    const views = []
    for (let i = 0; i < n; i++) {
      const v = parkedReader.createObject(parent)
      if (!v) {
        for (let k = 0; k < views.length; k++) views[k].destroy()
        return null
      }
      views.push(v)
    }
    for (let i = 0; i < n; i++) views[i].path = files[i]
    const texts = []
    let ok = true
    for (let i = 0; i < n; i++) {
      if (!views[i].waitForJob()) {
        ok = false
        // Same reason as the index read: a file that is named but cannot be
        // read leaves the store with no options, so it is named.
        Log.error("settings: a catalog file could not be read: " + files[i])
      }
      texts.push(views[i].text())
      views[i].destroy()
    }
    return ok ? texts : null
  }

  function _loadSchema() {
    // The directory catalog: shell/ + env/ files share one parse so the
    // option set stays whole (env order follows file order). It is the only
    // catalog - there is no second copy to fall back to, so a catalog that
    // cannot be read leaves the store with no options and says why.
    schemaLoader.path = ""
    schemaLoader.path = Paths.settingsSchemaDir + "/_index.jsonc"
    if (!schemaLoader.waitForJob()) {
      Log.error("settings: the catalog index could not be read: "
        + Paths.settingsSchemaDir + "/_index.jsonc")
      root._schemaDone()
      return
    }
    let idx = null
    try {
      idx = JSON.parse(SL.stripJsonc(schemaLoader.text()))
    } catch (e) {
      Log.error("settings: the catalog index did not parse: "
        + (e && e.message ? e.message : String(e)))
      idx = null
    }
    if (!idx || typeof idx !== "object") {
      root._schemaDone()
      return
    }
    // misc/ files ride along so misc.* options resolve in this schema
    // too: Settings.menuBundleText projects MiscSettings' live
    // values/enums onto them for rendering, while MiscSettings stays
    // the single writer (flush/renderEnv skip opt.misc below).
    // Files already parsed above (e.g. shell/10-wallpaper.jsonc also
    // hosts the misc page) must not parse twice - the catalog treats
    // duplicate keys across files as a hard error.
    const miscFiles = Paths.miscCatalogFiles.filter(f =>
      Paths.shellCatalogFiles.indexOf(f) < 0 && Paths.envCatalogFiles.indexOf(f) < 0)
    const files = Paths.shellCatalogFiles.concat(Paths.envCatalogFiles, miscFiles)
    const namespaces = []
    for (let i = 0; i < files.length; i++) {
      namespaces.push(files[i].indexOf("/misc/") >= 0 ? "misc" : (files[i].indexOf("/env/") >= 0 ? "env" : "shell"))
    }
    const texts = root.readCatalogTexts(root, files)
    if (!texts) {
      root._schemaDone()
      return
    }
    let catalog = null
    try {
      catalog = SL.parseCatalogDir(texts, namespaces,
        (typeof idx.width === "number" && idx.width > 0) ? Math.round(idx.width) : 0,
        (typeof idx.title === "string" && idx.title.trim() !== "") ? idx.title.trim() : "")
    } catch (err) {
      // A duplicate key across two catalog files lands here.
      Log.error("settings: the directory catalog did not parse: "
        + (err && err.message ? err.message : String(err)))
    }
    if (!catalog) {
      root._schemaDone()
      return
    }
    root._collected = catalog.sections
    root._collectedRootWidth = catalog.rootWidth || 0
    root._collectedRootTitle = catalog.rootTitle || ""
    root._schemaDone()
  }

  property int _collectedRootWidth: 0
  property string _collectedRootTitle: ""

  function _schemaDone() {
    root._schema = SL.buildSchema(root._collected, root._collectedRootWidth, root._collectedRootTitle)
    root._collected = []
    root._loadUser()
  }

  property var _collected: []

  // --- user data ---

  // A missing file and an unreadable one fail the blocking load the same
  // way, so the verdict arrives out of band (see _onLoadFailed) and the
  // write path stays closed until it does.
  function _loadUser() {
    // The FIRST read is not a phase at all: Component.onCompleted subscribes
    // the file watcher before it starts the schema scan, and the subscription
    // delivers the current contents immediately, so this runs once with no
    // schema and _applyUserData drops the result on its `!root._schema` guard.
    //
    // Reads go through a parked loader: the watched settingsView may be in
    // a failed state (file not created yet) and must never be read from.
    userLoader.path = ""
    userLoader.path = Paths.settingsFile
    const ok = userLoader.waitForJob()
    root._readPending = !ok
    root._applyUserData(ok ? userLoader.text() : "")
  }

  // FileViewError: 2 is FileNotFound, every other code means the file is
  // there but cannot be read. The classification is SettingsLib's; an
  // unreadable file is the user's content nobody has read yet, so it is
  // reported and left alone.
  function _onLoadFailed(error) {
    root._readPending = false
    root._setFault(SL.loadFault(error))
  }

  // The one writer of `fault`, so a transition is one event and cannot be
  // missed by a reader watching the property. A clear is a transition like
  // any other: a session that reads unreadable and then parses again is worth
  // seeing on both ends, and `kind` is the whole claim - nothing about the
  // user's file travels with it.
  function _setFault(kind) {
    if (root.fault === kind) return
    root.fault = kind
    root.rev++
  }

  // The write half, kept apart because the two clear on different evidence: a
  // source fault outlives a reload until the file parses again, while a write
  // fault retires on the next save that lands.
  function _setWriteFault(kind) {
    if (root.writeFault === kind) return
    root.writeFault = kind
    root.rev++
  }

  function _applyUserData(rawText) {
    // Boot race: the user file can land before the schema scan finishes.
    // _loadUser() runs again after the schema is up, so just wait here.
    if (!root._schema) return

    // Own flushes re-trigger the watch and resolve to identical values,
    // so re-applying is a cheap no-op, not a loop: no key flips, no flush.

    const source = SL.parseUserSource(rawText)
    // A malformed file is never rewritten. The session falls back to the
    // schema defaults, persistence is blocked, and the fault clears only
    // when a later read parses again - a hand fix or an explicit
    // backed-up migration. The parsed source is dropped, so _lastRaw
    // keeps naming the last file this store is willing to write from.
    let parsed = source.fault === "" ? source.raw : {}

    if (source.fault === "") {
      root._lastRaw = parsed
    }

    const resolved = SL.resolve(root._schema, parsed)

    // Keys committed since the last flush exist only in memory - an
    // external edit must not evict them. Re-stamp the dirty set onto the
    // freshly resolved maps before publishing.
    const stamped = SL.reapplyPending(resolved.values, resolved.validOverrides,
      root._schema.byKey, root._dirty, root.values)
    resolved.values = stamped.values
    resolved.validOverrides = stamped.validOverrides
    root._publish(resolved)

    // A read that parsed outranks an earlier verdict: the file is a source
    // again, so an unreadable fault is over. A write fault is not - it
    // clears on the next successful save.
    root._setFault(source.fault)

    if (!root.ready) {
      root.ready = true
    // First pass also seeds the env projection so early scripts see real
    // values even if nothing was ever changed. One tick of delay gives a
    // failed load's reason time to land, so nothing is written on a guess.
      root._scheduleFlush()
    }
  }

  // An option value as a reader wants it: a scalar as itself, a structured
  // value by what it actually is.
  //
  // The part count is `Object.keys(v).length`, NOT `v.length`. A `layout`
  // value is `{left, center, right, disabled}` - four named parts and no
  // length - so reading `.length` off it yields `undefined` and the count
  // prints as "undefined-part", which is worse
  // than no line at all. Naming the parts is the useful half anyway: the
  // zones it holds are the thing a reader would ask.
  //
  // The parts read `left 3, center 2` and not `left=3 center=2` because the
  // sentence is already "{key} updated to {value}". An `=` inside the value
  // would be indistinguishable from the `key=value` form this deliberately
  // does not use, and the line would look like it was setting a second
  // option.

  function _publish(resolved) {
    const prev = root.values
    // A resolve can move any key, so every shard is replaced. This is the
    // rare bulk path (schema load, file reload).
    root._replaceAllShards(resolved.values)
    root._overrides = resolved.validOverrides
    root._raw = resolved.raw
    root._issues = resolved.issues

    // Emit one change per externally-flipped key so bound views resettle.
    // The key set is SettingsLib's; the signals stay here.
    const flipped = SL.changedKeys(prev, root.values)
    for (let i = 0; i < flipped.length; i++) {
      const key = flipped[i]
      const next = root.values[key]
      root.optionChanged(key, next)
    }
    root.rev++
  }

  // Split SettingsLib's "key: reason - using default" into its two halves.
  // The key is everything before the first ": ", so a reason carrying a
  // colon of its own stays whole inside the message, and the fixed
  // "using default" tail is policy the event name already carries.

  // --- raw (non-schema) section accessors ---

  // --- raw-section public surface ---
  //
  // For components owning a non-schema settings namespace under shell.*
  // (e.g. the AppLauncher's plugin registry). Read returns the LIVE
  // object - treat it as read-only; writes go through setRawSection so
  // rev bumps and the flush pipeline stay on one path.

  function rawSection(section) {
    root.rev
    return SL.rawSectionOf(root._lastRaw, section)
  }

  function setRawSection(section, key, value) {
    root._mutateRaw(section, key, value)
  }

  // Typed setters preserved for existing widget call sites.

  function toggleWallpaper() {
    root.toggleOption("shell.wallpaper.enabled")
  }

  function toggleMosaic() {
    root.toggleOption("shell.wallpaper.mosaic")
  }

  function toggleBlurBackground() {
    root.setOption("shell.lockscreen.blurBackground", !(root.blurBackground === true))
  }

  function toggleLockscreenNowPlaying() {
    root.setOption("shell.lockscreen.nowPlaying", !(root.lockscreenNowPlaying === true))
  }

  function toggleLockscreenPauseMusic() {
    root.setOption("shell.lockscreen.pauseMusic", !(root.lockscreenPauseMusic === true))
  }

  function cycleLockscreenBlurPower() {
    const next = root.blurPowerLevels[(root.blurPowerLevels.indexOf(root.lockscreenBlurPower) + 1) % root.blurPowerLevels.length]
    root.setOption("shell.lockscreen.blurPower", next)
  }

  // Mutate a raw section of the user file. Raw sections live under the
  // shell namespace, like everything except "options"; the shape of the
  // edit is SettingsLib's, the republish is this store's.
  //
  // This path emits no optionChanged, so `rev` and the republish are the only
  // reports a raw write makes.
  function _mutateRaw(section, key, v) {
    root._lastRaw = SL.writeRawSection(root._lastRaw, section, key, v)
    root.rev++
    root._scheduleFlush()
  }

  // --- flush pipeline (coalesced atomic writes + hooks) ---

  property var _pendingHooks: []

  // Coalesced flush: one event-loop tick batches rapid commits.
  property bool _flushPending: false

  function _scheduleFlush() {
    if (root._flushPending) return
    root._flushPending = true
    Qt.callLater(() => root._flushSoon())
  }

  function _flushSoon() {
    root._flushPending = false
    root.flush()
  }

  function flush() {
    if (!root._schema || !root.ready) return

    // The user file is rewritten only from a source this store has read
    // and only while no fault stands. The managed view is composed from
    // the last parsed source plus the valid override map: managed leaves
    // are written (or pruned when back at default) one by one, never by
    // deleting whole section objects, an invalid managed leaf keeps the
    // user's own value, and foreign fields pass through verbatim. Hypr and
    // misc keys are owned by their own stores.
    const out = root.faulted || root._readPending
      ? null
      : SL.composeManaged(root._schema, root._lastRaw, root._overrides)

    if (out !== null) {
      // Adopt the flushed shape as the live raw view BEFORE writing: raw
      // readers (wallpaperEnabled, statusbarPosition, rawSection) must see
      // schema commits immediately, not on the next external reload - the
      // write echo comes back through the watcher and resolves to the same
      // values, so this assignment is their only update path.
      root._lastRaw = out
      settingsView.setText(JSON.stringify(out, null, 2) + "\n")
      // Only a write that landed retires the dirty set: an accepted commit
      // the store could not persist stays memory-only and keeps surviving
      // external reloads, exactly like a commit from the last tick.
      root._dirty = {}
    }
    // The else branch is the one flush that writes nothing, and the only place
    // in the store where a commit is silently not persisted. It is correct - an
    // unreadable file must not be overwritten, and a read still in flight would
    // be written from stale raw - so the dirty set simply survives to the next
    // flush that lands.

    // Derived from the validated in-memory values, so the bash projection
    // stays correct even while the user file is held back.
    runtimeEnv.setText(SL.renderEnv(root._schema, root.values))

    if (root._pendingHooks.length > 0) {
      const hooks = root._pendingHooks.splice(0, root._pendingHooks.length)
      for (let h = 0; h < hooks.length; h++) root.runHook(hooks[h])
    }
  }

  function runHook(cmd) {
    const c = String(cmd).split("%v").join("")
    if (c.trim() === "") return
    const proc = hookComponent.createObject(root, {
      command: ["/bin/bash", "-c", c]
    })
    proc.exited.connect(proc.destroy)
    proc.running = true
  }

  // Self-heal for the bash projection. Any watcher event (deletion,
  // hand edit, our own write echo) re-renders from live values and
  // rewrites unless the file already holds exactly that content.
  // Deleted or failed reads never match, so removal always restores;
  // identical echo content short-circuits before any write.
  function _restoreRuntimeEnv() {
    if (!root._schema || !root.ready) return
    const expected = SL.renderEnv(root._schema, root.values)
    envReader.path = ""
    envReader.path = Paths.runtimeEnvFile
    if (envReader.waitForJob() && envReader.text() === expected) return
    runtimeEnv.setText(expected)
    runtimeEnv.waitForJob()
  }

  // Menu integration: raw bundle text for dynamic page injection.
  // Hypr pages are owned by HyprlandSettings - this bundle only carries
  // shell/env. HyprlandSettings merges its leaves as sibling pages so
  // Settings -> Hyprland navigation stays one tree.
  property string _bundleCache: ""
  property int _bundleRev: -1
  property int _bundleMiscRev: -1
  function menuBundleText() {
    if (!root._schema || !root.ready) return ""
    const miscRev = (typeof MiscSettings !== "undefined" && MiscSettings.ready) ? MiscSettings.rev : -1
    if (root._bundleCache !== "" && root._bundleRev === root.rev && root._bundleMiscRev === miscRev) return root._bundleCache
    // misc.* options are file-backed by MiscSettings (never persisted in
    // settings.json): project its live values AND option enums at build
    // time so dropdowns render truth. The old path (a one-way mirror
    // fired after async scans) lost every race where the scan landed
    // before this schema existed, pinning the dropdown to the catalog
    // default and its single placeholder entry forever.
    if (typeof MiscSettings !== "undefined" && MiscSettings.ready) {
      for (const mkey in MiscSettings._byKey) {
        const src = MiscSettings._byKey[mkey]
        const dst = root._schema.byKey[mkey]
        if (!dst) continue
        if (src.values) dst.values = src.values.slice()
        dst.valueLabels = src.valueLabels ? Object.assign({}, src.valueLabels) : null
        if (src.keywords) dst.keywords = src.keywords.slice()
      }
      const merged = Object.assign({}, root.values, MiscSettings.values)
      root._bundleCache = JSON.stringify(SL.buildBundle(root._schema, merged))
      root._bundleRev = root.rev
      root._bundleMiscRev = miscRev
      return root._bundleCache
    }
    root._bundleCache = JSON.stringify(SL.buildBundle(root._schema, root.values))
    root._bundleRev = root.rev
    root._bundleMiscRev = miscRev
    return root._bundleCache
  }

  // Cheap link-target probe for menu joins: names `pageId` either the
  // settings root or a generated category page? Reads the already-parsed
  // schema - no bundle build, no stringify.
  function menuHasPage(pageId) {
    if (!root._schema || !root.ready) return false
    if (pageId === "settings") return true
    const pages = root._schema.pages || root._schema.sections || []
    for (let i = 0; i < pages.length; i++) {
      if (pages[i].page === pageId) return true
    }
    return false
  }


  // --- processes / file views ---

  // Reads _index.jsonc, the root chrome of the directory catalog. The
  // catalog files themselves go through parkedReader.
  FileView {
    id: schemaLoader

    printErrors: false
  }

  // A reader with no path of its own. One per catalog file per read, created
  // and destroyed inside readCatalogTexts, so a load leaves no reader behind.
  // watchChanges is stated rather than inherited: the catalog is read once at
  // boot, and a watch on each of the parked views would be an inotify
  // registration with no subscriber. On this Quickshell the property already
  // defaults false and the count is the same either way, so this documents the
  // requirement rather than changing the number.
  Component {
    id: parkedReader

    FileView {
      printErrors: false
      watchChanges: false
    }
  }

  // Writer for the user file; watcher via Watch governor (K2)
  FileView {
    id: settingsView

    path: Paths.settingsFile
    atomicWrites: true
    printErrors: false
    // A failed write means the file is not writable: hold persistence
    // until a write lands again instead of failing silently on every
    // commit. The env projection keeps flowing either way.
    onSaved: root._setWriteFault("")
    onSaveFailed: root._setWriteFault("readonly")
  }
  property var _settingsWatchUnsub: null

  FileView {
    id: userLoader

    // No blockLoading: combined with a missing file it deadlocks
    // waitForJob. Without it a failed load simply returns false.
    printErrors: false
    onLoadFailed: (error) => root._onLoadFailed(error)
  }

  FileView {
    id: runtimeEnv

    path: Paths.runtimeEnvFile
    atomicWrites: true
    printErrors: false
  }

  // Paranoia net via Watch governor (K2)
  property var _envWatchUnsub: null

  // Parked reader for the restore check; same failed-state rules as
  // userLoader - the watched view itself is never read from.
  FileView {
    id: envReader

    printErrors: false
  }

  Component {
    id: hookComponent

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  // --- ipc ---

  IpcHandler {
    target: "settings"
    function help(command: string): string {
      return UnitIpc.help("settings", "Settings", "settings engine store", [
        { name: "dump", help: "all stored values" },
        { name: "get", help: "(key) read one value" },
        { name: "reload", help: "re-read the store" },
        { name: "set", help: "(key, value) write one value" },
        { name: "toggle", help: "flip a boolean key" },
      ], command)
    }
    function status(): string {
      return JSON.stringify({
        unit: "settings",
        healthy: !root.faulted,
        fault: root.fault,
        writeFault: root.writeFault,
        issues: root._issues.length
      })
    }
    function ping(): string { return "pong" }

    function get(key: string): string {
      if (root.byKey(key) === null) return JSON.stringify({
        error: "unknown option"
      })
      return JSON.stringify({
        key: key,
        value: root.value(key)
      })
    }

    function set(key: string, json: string): string {
      let v
      try {
        v = JSON.parse(json)
      } catch (e) {
        return "error: invalid JSON value"
      }
      return root.setOption(key, v) ? "ok" : "error"
    }

    function toggle(key: string): string {
      return root.toggleOption(key) ? "ok" : "error"
    }

    function dump(): string {
      return JSON.stringify(root.values)
    }

    // Re-reads the user file; a source that parses again clears the fault.
    function reload(): string {
      root._loadUser()
      return "ok"
    }
  }
}

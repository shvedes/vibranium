pragma Singleton

import QtQml
import Quickshell
import qs.common
import qs.features.lyrics
import "../BarLib.js" as BarLib
import "../BarIpc.js" as BarIpc
import "../../../common/text/IpcCatalog.js" as Catalog

// The resident half of the bar. It owns the persisted demand for the bar
// runtime, the layout/module data behind `bar` IPC and the menu providers, and
// holds a nullable reference to the accepted runtime. It imports no visual bar
// type, so the settings menu, `bar` IPC and the off-state CLI work on a shell
// that never loaded the status bar.
Singleton {
  id: root

  readonly property string tag: "bar"
  readonly property bool initialized: root._initialized
  property bool _initialized: false

  // The settings lease for the bar unit is acquired by Boot, not here. This is
  // the answer to "is the runtime currently mounted", which is what a live
  // operation needs before it can forward anything.
  property var runtime: null
  property var generation: 0

  readonly property bool enabled: Settings.statusbarEnabled
  property bool _hideToggle: false
  readonly property bool hideToggle: root._hideToggle
  readonly property bool effectiveEnabled: root.enabled && !root._hideToggle
  readonly property string position: Settings.statusbarPosition
  readonly property bool showBorder: Settings.statusbarShowBorder
  readonly property int height: 28

  readonly property var screens: Ui.validScreens

  // --- visual facade --------------------------------------------------------
  // The visual tree addresses the resident `Bar` facade. Every read resolves
  // through the accepted runtime, with inert defaults while none is mounted,
  // so a stale delegate can never reach a destroyed surface. No visual type
  // is imported here: these are plain values and calls on a captured owner.
  function _forward(name, args) {
    const rt = root.runtime
    if (!rt || typeof rt[name] !== "function") return undefined
    return rt[name].apply(rt, args)
  }

  readonly property real entranceSlide: root.runtime ? root.runtime.entranceSlide : 0
  readonly property real entranceWarmOpacity: root.runtime ? root.runtime.entranceWarmOpacity : 0
  readonly property bool entranceModulesReady: root.runtime ? root.runtime.entranceModulesReady : false
  readonly property bool entranceReady: root.runtime ? root.runtime.entranceReady : false
  readonly property real revealProgress: root.runtime ? root.runtime.revealProgress : 0
  readonly property real iconSlot: root.runtime ? root.runtime.iconSlot : 0
  readonly property real iconCanvas: root.runtime ? root.runtime.iconCanvas : 0
  readonly property real slotInset: root.runtime ? root.runtime.slotInset : 0
  readonly property real pillFontSize: root.runtime ? root.runtime.pillFontSize : 0
  readonly property real textScale: root.runtime ? root.runtime.textScale : 1
  readonly property bool moveActive: root.runtime ? root.runtime.moveActive : false
  readonly property bool movePressed: root.runtime ? root.runtime.movePressed : false
  readonly property var moveOwner: root.runtime ? root.runtime.moveOwner : null
  readonly property string moveCandidate: root.runtime ? root.runtime.moveCandidate : ""
  readonly property string moveScreenKey: root.runtime ? root.runtime.moveScreenKey : ""
  readonly property int moveViewsRevision: root.runtime ? root.runtime.moveViewsRevision : 0

  function _args() { return Array.prototype.slice.call(arguments) }
  function registerMoveView() { return root._forward("registerMoveView", root._args.apply(null, arguments)) }
  function unregisterMoveView() { return root._forward("unregisterMoveView", root._args.apply(null, arguments)) }
  function moveViewFor(screen) { return root.runtime ? root.runtime.moveViewFor(screen) : null }
  function cancelBarMove() { return root._forward("cancelBarMove", []) }
  function startBarMove() { return root._forward("startBarMove", root._args.apply(null, arguments)) }
  function updateBarMove() { return root._forward("updateBarMove", root._args.apply(null, arguments)) }
  function pressBar() { return root._forward("pressBar", root._args.apply(null, arguments)) }
  function releaseBar() { return root._forward("releaseBar", root._args.apply(null, arguments)) }
  function endBarMove() { return root._forward("endBarMove", root._args.apply(null, arguments)) }
  function moveSlot() { return root._forward("moveSlot", root._args.apply(null, arguments)) }
  function moveSlotAcross() { return root._forward("moveSlotAcross", root._args.apply(null, arguments)) }
  function componentFor(id) { return root.runtime ? root.runtime.componentFor(id) : null }
  function isGroup(id) { return root.runtime ? root.runtime.isGroup(id) : false }
  function isOwned(id) { return root._isOwned(id) }
  function groupMembers(id) { return root.runtime ? root.runtime.groupMembers(id) : [] }
  function markBuildStart() { return root._forward("markBuildStart", root._args.apply(null, arguments)) }
  function reportModuleReady() { return root._forward("reportModuleReady", root._args.apply(null, arguments)) }
  function _latchEntrance() { return root._forward("_latchEntrance", []) }
  function registerPicker() { return root._forward("registerPicker", root._args.apply(null, arguments)) }
  function unregisterPicker() { return root._forward("unregisterPicker", root._args.apply(null, arguments)) }
  function registerFallbackPicker() { return root._forward("registerFallbackPicker", root._args.apply(null, arguments)) }
  function unregisterFallbackPicker() { return root._forward("unregisterFallbackPicker", root._args.apply(null, arguments)) }
  function claimActivePicker() { return root._forward("claimActivePicker", root._args.apply(null, arguments)) }
  function clearActivePicker() { return root._forward("clearActivePicker", root._args.apply(null, arguments)) }

  function _ownerName() { return root.tag }

  // --- static slot table ----------------------------------------------------
  //
  // The single data table for slot ids, zones, default order and the always-on,
  // stale, fixed and migration rules. The visual runtime maps these ids to
  // components; everything that writes persisted layout data uses this table
  // through the same normalization path.
  readonly property var _zones: ({
    workspaces: "left", privacy: "right", clock: "center", weather: "right",
    keyboardLayout: "right", bluetooth: "right", battery: "right",
    network: "right", printers: "right", powerProfile: "right",
    systemUpdates: "right", colorPicker: "right", nightLight: "right",
    nowPlaying: "right", volume: "right", session: "right", tray: "right",
    downloader: "right"
  })
  readonly property var _placeBefore: ({
    tray: "keyboardLayout", privacy: "battery", weather: "session",
    keyboardLayout: "session", bluetooth: "network", battery: "network",
    network: "volume", printers: "session", downloader: "powerProfile",
    powerProfile: "session", systemUpdates: "session", colorPicker: "session",
    nightLight: "session", nowPlaying: "session", volume: "session"
  })
  readonly property var _permanent: ({})
  readonly property var _pinned: ({})
  readonly property var _alwaysOnIds: ["workspaces"]
  readonly property var _staleSlotIds: ["microphone"]
  readonly property var _renamedSlotIds: ({ videoDownloader: "downloader" })
  readonly property var _gatedIds: ["systemUpdates", "printers"]
  readonly property var _ownedIds: ["readingMode", "recording", "timer", "caffeine", "update"]

  function _isOwned(id) { return root._ownedIds.indexOf(id) >= 0 }
  function isFixedSlot(id) {
    return root._pinned[id] !== undefined || (root._isOwned(id) && id !== "readingMode"
      && id !== "recording" && id !== "timer" && id !== "caffeine" && id !== "update")
  }
  function isPinned(id) { return root._pinned[id] !== undefined }
  function _isStandaloneSlot(id) {
    if (typeof id !== "string" || id === "") return false
    return BarIpc.metadata[id] !== undefined || root._isOwned(id)
  }

  // --- settings projection --------------------------------------------------
  readonly property var storedLayout: BarLib.renameSlots(Settings.statusbarLayout, root._renamedSlotIds)

  readonly property var layout: BarLib.renderLayout(root.storedLayout, root.disabledModules,
    ["left", "center", "right"], root._pinned,
    id => root._isStandaloneSlot(id), id => root._isOwned(id))

  readonly property var positions: root.storedLayout
  readonly property var disabledModules: Array.isArray(root.storedLayout.disabled)
    ? root.storedLayout.disabled.slice() : []
  readonly property var enabledModules: {
    const out = []
    for (const zone of ["left", "center", "right"]) {
      const list = root.layout[zone] || []
      for (const id of list) if (out.indexOf(id) < 0) out.push(id)
    }
    return out
  }

  function _normalizeLayout(raw) {
    return BarLib.normalizeLayout(raw, ["left", "center", "right"],
      id => root._isStandaloneSlot(id), id => root._isOwned(id),
      root._permanent, root._alwaysOnIds, root._staleSlotIds, root._pinned)
  }

  function setOption(key, value) {
    switch (key) {
      case "enabled":
        return Settings.setOption("shell.statusbar.enabled", value === true)
      case "position":
        return Settings.setOption("shell.statusbar.position", value)
      case "showBorder":
        return Settings.setOption("shell.statusbar.showBorder", value === true)
      case "layout": {
        const norm = root._normalizeLayout(value)
        if (norm === null) return false
        return Settings.setOption("shell.statusbar.layout", norm)
      }
      case "hideToggle":
        root._hideToggle = value === true
        return true
    }
    return false
  }

  // The transient override survives a master switch cycle in the same shell
  // process. `bar show` while disabled clears it; a master enable never does.
  function setHidden(hidden) { root._hideToggle = hidden === true; return true }
  function toggleHidden() { root._hideToggle = !root._hideToggle; return true }
  function clearHidden() { root._hideToggle = false; return true }

  function isEnabled(id) {
    if (typeof id !== "string" || id === "") return false
    if (root._isOwned(id) || id === "workspaces" || root._permanent[id] !== undefined) return true
    return root.disabledModules.indexOf(id) < 0
  }
  function isModuleVisible(id) { return root.isEnabled(id) }

  // Data-only module enable/disable. The runtime re-checks its own registry
  // when it mounts; there is no construction side effect while off.
  function enableModule(id) {
    if (!root._isStandaloneSlot(id)) return false
    if (root.isEnabled(id)) return true
    const cur = root.storedLayout
    const zones = {
      left: (cur.left || []).slice(),
      center: (cur.center || []).slice(),
      right: (cur.right || []).slice()
    }
    const zone = root._zones[id]
    if (zone === undefined || !Array.isArray(zones[zone])) return false
    if (BarLib.slotPresent(zones, id) === null)
      BarLib.insertBeforeAnchor(zones[zone], root._placeBefore[id], id)
    const disabled = root.disabledModules.filter(x => x !== id)
    return root.setOption("layout", {
      left: zones.left, center: zones.center, right: zones.right, disabled: disabled
    })
  }

  function disableModule(id) {
    if (!root._isStandaloneSlot(id) || root._isOwned(id)) return false
    if (id === "workspaces" || root._permanent[id] !== undefined) return false
    if (!root.isEnabled(id)) return true
    const cur = root.storedLayout
    const disabled = root.disabledModules.slice()
    if (disabled.indexOf(id) < 0) disabled.push(id)
    return root.setOption("layout", {
      left: (cur.left || []).slice(), center: (cur.center || []).slice(),
      right: (cur.right || []).slice(), disabled: disabled
    })
  }

  // --- accepted runtime handoff ---------------------------------------------
  function attachRuntime(item, gen) {
    if (!item || root.runtime === item) return false
    root.runtime = item
    root.generation = gen
    return true
  }

  function detachRuntime(item, gen) {
    if (root.runtime !== item || root.generation !== gen) return false
    root.runtime = null
    return true
  }

  function _live(name, args) {
    const rt = root.runtime
    if (!rt || typeof rt[name] !== "function") return BarIpc.fail("unavailable", "bar is not mounted")
    return rt[name].apply(rt, args)
  }

  // --- off-state IPC --------------------------------------------------------
  function stateSnapshot(): var {
    const rt = root.runtime
    if (rt && typeof rt.stateSnapshot === "function") return rt.stateSnapshot()
    return {
      enabled: root.enabled,
      hidden: root.hideToggle,
      effectiveEnabled: false,
      position: root.position,
      showBorder: root.showBorder,
      height: root.height,
      layout: root.layout,
      storedLayout: root.storedLayout,
      disabled: root.disabledModules,
      positions: root.positions,
      enabledModules: root.enabledModules
    }
  }

  function ipcStatus() {
    const rt = root.runtime
    if (rt && typeof rt.ipcStatus === "function") return rt.ipcStatus()
    const snap = root.stateSnapshot()
    const outputs = []
    for (const s of root.screens) {
      const name = String(s.name || "")
      if (name !== "" && outputs.indexOf(name) < 0) outputs.push(name)
    }
    outputs.sort()
    const placed = (root.layout.left || []).concat(root.layout.center || [], root.layout.right || [])
    return Object.assign(snap, {
      outputs: outputs,
      placedModules: placed,
      modules: root._offlineModuleRecords(outputs)
    })
  }

  function _offlineModuleRecords(outputs) {
    const out = []
    const ids = Object.keys(BarIpc.metadata).sort()
    for (const id of ids) {
      const rec = BarIpc.listRecord(id, BarIpc.metadata[id], root.isEnabled(id), false)
      rec.screens = outputs.map(name => ({ name: name, loaded: false, visible: false, islandOpen: false }))
      out.push(rec)
    }
    return out
  }

  function ipcSetEnabled(desired) {
    const want = desired === true
    if (root.enabled !== want) root.setOption("enabled", want)
    return BarIpc.silent()
  }

  function ipcSetHidden(hidden) {
    root.setHidden(hidden === true)
    return BarIpc.silent()
  }

  function ipcShow() {
    if (!root.enabled) root.clearHidden()
    else root.setHidden(false)
    return BarIpc.silent()
  }

  function ipcHide() { return root.ipcSetHidden(true) }
  function ipcShowToggle() { return root.toggleHidden() }

  function _ipcPositionGet() { return BarIpc.ok(root.position) }
  function _ipcLayoutGet() { return BarIpc.ok(root.ipcLayout()) }

  function ipcSetPosition(value) {
    if (value === "toggle") value = root.position === "top" ? "bottom" : "top"
    if (value !== "top" && value !== "bottom")
      return BarIpc.fail("invalid-argument", "position must be top, bottom or toggle")
    if (root.position !== value) root.setOption("position", value)
    return BarIpc.silent()
  }

  function ipcLayout() {
    const s = root.storedLayout || {}
    const out = { left: [], center: [], right: [], disabled: [] }
    for (const zone of ["left", "center", "right"]) {
      for (const id of (s[zone] || []))
        out[zone].push((root.isEnabled(id) ? "- [*] " : "- [] ") + id)
    }
    for (const id of (s.disabled || [])) out.disabled.push("- [] " + id)
    return out
  }

  // Validate a caller's complete layout before handing it to the one write
  // path. Per-zone uniqueness and a separate `disabled` set are both valid:
  // a disabled slot still keeps its zone place.
  function ipcSetLayout(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
      return BarIpc.fail("invalid-argument", "layout must be an object")
    const zones = ["left", "center", "right"]
    const next = { left: [], center: [], right: [], disabled: [] }
    for (const zone of zones.concat(["disabled"])) {
      const list = raw[zone]
      if (!Array.isArray(list))
        return BarIpc.fail("invalid-argument", "layout needs four arrays")
      const seen = Object.create(null)
      for (const id of list) {
        if (typeof id !== "string" || id === "")
          return BarIpc.fail("invalid-argument", "layout ids must be strings")
        if (seen[id] === true)
          return BarIpc.fail("invalid-argument", "duplicate layout placement")
        seen[id] = true
        if (zone === "disabled") {
          if (root._isOwned(id) || id === "workspaces" || root._permanent[id] !== undefined
            || !root._isStandaloneSlot(id))
            return BarIpc.fail("invalid-argument", "slot cannot be disabled")
        } else if (!root._isStandaloneSlot(id)) {
          return BarIpc.fail("invalid-argument", "unknown layout slot")
        }
        next[zone].push(id)
      }
    }
    const cur = root.storedLayout || {}
    for (const zone of zones) {
      const live = Array.isArray(cur[zone]) ? cur[zone] : []
      for (let i = 0; i < live.length; i++) {
        if (!root.isFixedSlot(live[i])) continue
        if (next[zone].indexOf(live[i]) !== i)
          return BarIpc.fail("invalid-argument", "fixed slot cannot move")
      }
    }
    const norm = root._normalizeLayout(next)
    if (norm === null) return BarIpc.fail("invalid-argument", "layout rejected")
    if (!root.setOption("layout", norm)) return BarIpc.fail("refused", "layout write refused")
    return BarIpc.silent()
  }

  function _ipcKnown(id) {
    return typeof id === "string" && id !== "" && BarIpc.metadata[id] !== undefined
  }

  function ipcModuleList(filter) {
    const rt = root.runtime
    if (rt && typeof rt.ipcModuleList === "function") return rt.ipcModuleList(filter)
    const want = filter === undefined || filter === null || filter === "" ? "all" : String(filter)
    const out = []
    for (const id of Object.keys(BarIpc.metadata).sort()) {
      const enabled = root.isEnabled(id)
      if (want === "enabled" && !enabled) continue
      if (want === "disabled" && enabled) continue
      if (want === "hidden" && (!enabled || true)) continue
      if (want === "visible" && (!enabled || root.effectiveEnabled)) continue
      out.push(BarIpc.listRecord(id, BarIpc.metadata[id], enabled, false))
    }
    return BarIpc.ok(out)
  }

  function ipcOptionsFor(id) {
    const keys = BarIpc.optionKeys(id, null)
    const out = []
    for (const key of keys) {
      const full = BarIpc.settingKey(id, key)
      const meta = Settings.byKey(full)
      const value = Settings.value(full)
      out.push({
        key: key,
        type: meta ? meta.type : null,
        value: value === undefined ? null : value,
        default: meta && meta.default !== undefined ? meta.default : null,
        choices: meta && Array.isArray(meta.choices) ? meta.choices.slice() : null,
        limits: meta && (meta.min !== undefined || meta.max !== undefined)
          ? { min: meta.min === undefined ? null : meta.min,
              max: meta.max === undefined ? null : meta.max } : null
      })
    }
    return out
  }

  function ipcModuleStatus(id) {
    const rt = root.runtime
    if (rt && typeof rt.ipcModuleStatus === "function") return rt.ipcModuleStatus(id)
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    const meta = BarIpc.metadata[id]
    const rec = BarIpc.listRecord(id, meta, root.isEnabled(id), false)
    rec.kind = "slot"
    rec.toggleable = id !== "workspaces" && root._isStandaloneSlot(id)
    rec.movable = !root.isFixedSlot(id) && !root.isPinned(id)
    rec.hasIsland = meta.hasIsland === true
    rec.options = root.ipcOptionsFor(id)
    const outputs = root.screens.map(s => String(s.name || "")).filter(n => n !== "")
    rec.screens = outputs.map(name => ({ name: name, loaded: false, visible: false, islandOpen: false }))
    return BarIpc.ok(rec)
  }

  function ipcSetModule(id, desired) {
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    if (!root._isStandaloneSlot(id) || id === "workspaces" || root._isOwned(id))
      return BarIpc.fail("unsupported", "module has no enable switch")
    const want = desired === true
    if (root.isEnabled(id) === want) return BarIpc.silent()
    const done = want ? root.enableModule(id) : root.disableModule(id)
    if (!done) return BarIpc.fail("refused", "module write refused")
    return BarIpc.silent()
  }

  function ipcIsland(id, verb, output) {
    const rt = root.runtime
    if (rt && typeof rt.ipcIsland === "function") return rt.ipcIsland(id, verb, output)
    return BarIpc.fail("unavailable", "bar is not mounted")
  }

  function ipcOptList(id) {
    const rt = root.runtime
    if (rt && typeof rt.ipcOptList === "function") return rt.ipcOptList(id)
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    return BarIpc.ok(root.ipcOptionsFor(id))
  }

  function _ipcOptKey(id, key) {
    return root.ipcOptionsFor(id).some(o => o.key === key)
  }

  function ipcOptGet(id, key) {
    const rt = root.runtime
    if (rt && typeof rt.ipcOptGet === "function") return rt.ipcOptGet(id, key)
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    if (!root._ipcOptKey(id, key)) return BarIpc.fail("unsupported", "no such option")
    const v = Settings.value(BarIpc.settingKey(id, key))
    return BarIpc.ok({ key: key, value: v === undefined ? null : v })
  }

  function ipcOptSet(id, key, value) {
    const rt = root.runtime
    if (rt && typeof rt.ipcOptSet === "function") return rt.ipcOptSet(id, key, value)
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    if (!root._ipcOptKey(id, key)) return BarIpc.fail("unsupported", "no such option")
    const full = BarIpc.settingKey(id, key)
    if (JSON.stringify(Settings.value(full)) === JSON.stringify(value)) return BarIpc.silent()
    if (!Settings.setOption(full, value)) return BarIpc.fail("invalid-argument", "value refused")
    return BarIpc.silent()
  }

  function ipcTriggerModule(id, name, output) {
    const rt = root.runtime
    if (rt && typeof rt.ipcTriggerModule === "function") return rt.ipcTriggerModule(id, name, output)
    if (!root._ipcKnown(id)) return BarIpc.fail("not-found", "no such module")
    if (BarIpc.triggerNames(id).indexOf(name) < 0)
      return BarIpc.fail("unsupported", "no such trigger")
    return BarIpc.fail("unavailable", "module is not mounted")
  }

  // The picker/live operations forward to the accepted runtime when it exists
  // and report unavailable when it does not. The independent picker owner
  // takes over the colorPicker target once that feature is mounted.
  function ipcPickColor() { return root._live("ipcPickColor", arguments.length ? [].slice.call(arguments) : []) }
  function ipcCloseColorPick() { return root._live("ipcCloseColorPick", []) }
  function ipcColorStatus() {
    const rt = root.runtime
    if (rt && typeof rt.ipcColorStatus === "function") return rt.ipcColorStatus()
    return BarIpc.ok({ available: false, picking: false, screen: "" })
  }

  // Registry facade: resident identity, live operations delegated to the
  // accepted runtime. `lyrics` is owned by an independent feature.
  function showLyrics(player, screen) {
    const rt = root.runtime
    if (rt && typeof rt._closeIslandShowingPlayer === "function") {
      rt._closeIslandShowingPlayer(player)
    }
    return Lyrics.showLyrics(player, screen)
  }

  function _toggleIds() {
    return Object.keys(BarIpc.metadata).filter(id =>
      id !== "workspaces" && !root._isOwned(id) && root._isStandaloneSlot(id))
  }

  function _registerMenuProviders() {
    for (const id of root._toggleIds()) {
      const surface = {
        checked: () => root.isEnabled(id),
        runToggle: (item, state) => { root.ipcSetModule(id, state !== false) }
      }
      ProviderHost.claimProvider("bar-" + id, surface, root)
    }
  }

  function _releaseMenuProviders() {
    for (const id of root._toggleIds()) ProviderHost.unregisterProvider("bar-" + id, root)
  }

  function _publishLayout() {
    DesktopLayoutState.publishBarLayout(root, root.effectiveEnabled, root.position, root.height)
  }

  Component.onCompleted: {
    IpcRouter.register("bar", root, {
      "bar.enable": () => root.ipcSetEnabled(true),
      "bar.disable": () => root.ipcSetEnabled(false),
      "bar.toggle": () => root.ipcSetEnabled(!root.enabled),
      "bar.show": () => root.ipcShow(),
      "bar.hide": () => root.ipcHide(),
      "bar.showToggle": () => root.ipcShowToggle(),
      "bar.position.get": () => root._ipcPositionGet(),
      "bar.position.set": a => root.ipcSetPosition(a.POSITION),
      "bar.layout.get": () => root._ipcLayoutGet(),
      "bar.layout.set": a => root.ipcSetLayout(a.LAYOUT),
      "bar.module.list": a => root.ipcModuleList(a.FILTER),
      "bar.module.ID.status": a => root.ipcModuleStatus(a.MODULE),
      "bar.module.ID.enable": a => root.ipcSetModule(a.MODULE, true),
      "bar.module.ID.disable": a => root.ipcSetModule(a.MODULE, false),
      "bar.module.ID.toggle": a => root.ipcSetModule(a.MODULE, !root.isEnabled(a.MODULE)),
      "bar.module.ID.island.is-open": a => root.ipcIsland(a.MODULE, "is-open", a.OUTPUT),
      "bar.module.ID.island.open": a => root.ipcIsland(a.MODULE, "open", a.OUTPUT),
      "bar.module.ID.island.close": a => root.ipcIsland(a.MODULE, "close", a.OUTPUT),
      "bar.module.ID.island.toggle": a => root.ipcIsland(a.MODULE, "toggle", a.OUTPUT),
      "bar.module.ID.opt.list": a => root.ipcOptList(a.MODULE),
      "bar.module.ID.opt.KEY.get": a => root.ipcOptGet(a.MODULE, a.KEY),
      "bar.module.ID.opt.KEY.set": a => root.ipcOptSet(a.MODULE, a.KEY, a.JSON),
      "bar.module.ID.trigger": a => root.ipcTriggerModule(a.MODULE, a.NAME, a.OUTPUT),
      "bar.status": () => ({ v: 1, ok: true, data: root.ipcStatus(), format: { kind: "record" } }),
      "bar.ping": () => "pong"
    })
    Registry.offer("bar", {
      title: "Bar",
      description: "Inspect and control the status bar",
      verbNames: Catalog.topLevelVerbs("bar")
    })
    Registry.register(root.tag, root)
    // The Utilities menu row calls this target; it must exist with no bar.
    Registry.register("lyrics", root)
    root._registerMenuProviders()
    root._publishLayout()
    root._initialized = true
  }

  Component.onDestruction: {
    IpcRouter.unregister("bar", root)
    root._releaseMenuProviders()
    DesktopLayoutState.releaseBarLayout(root)
    Registry.unregister("lyrics", root)
    Registry.unregister(root.tag)
  }

  Connections {
    target: Settings
    function onStatusbarEnabledChanged() { root._publishLayout() }
    function onStatusbarPositionChanged() { root._publishLayout() }
    function onOptionChanged() { root._publishLayout() }
  }

  onHideToggleChanged: root._publishLayout()
}

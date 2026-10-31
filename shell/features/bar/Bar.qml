pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.bar
import qs.features.bar.modules.Clock
import qs.features.bar.modules.KeyboardLayout
import qs.features.bar.modules.Logout
import qs.features.bar.modules.Bluetooth
import qs.features.bar.modules.Battery
import qs.features.bar.modules.Network
import qs.features.bar.modules.PowerProfile
import qs.features.bar.modules.ArchUpdates
import qs.features.bar.modules.ColorPicker
import qs.features.bar.modules.NightLight
import qs.features.bar.modules.Privacy
import qs.features.bar.modules.ReadingMode
import qs.features.bar.modules.Recording
import qs.features.bar.modules.Timer as CoreTimer
import qs.features.bar.modules.Caffeine
import qs.features.bar.modules.Update
import qs.features.bar.modules.Volume
import qs.features.bar.modules.Weather
import qs.features.bar.modules.Tray
import qs.features.bar.modules.Printers
import qs.features.bar.modules.NowPlaying
import qs.features.bar.modules.Workspaces
import "BarLib.js" as BarLib
import "../../common/text/UnitIpc.js" as UnitIpc

// The bar. Owns the bar's shell-internal settings (the raw "statusbar"
// section under shell.* in settings.json: enabled, position, showBorder,
// showShadow, blurred and the zone layout) and exposes them to the per-monitor
// BarView windows plus the `qs ipc call bar ...` surface.
//
// Zones: three logical areas (left, center, right) hold EVERY known slot
// id in order - including disabled ones - plus a `disabled` array with
// the static ids that are off. A single option, shell.statusbar.layout,
// is the only source of truth:
//
//   { left: [...], center: [...], right: [...], disabled: [...] }
//
// Disabled ids keep their zone gaps, so re-enabling restores order.
// Owned dynamic modules (caffeine, timer, recording, readingMode, update)
// live in zones too but never enter `disabled`: they cannot be disabled,
// only re-arranged, and own their transient visibility internally
// (visible:false / width:0 stay in the order). Modules and groups register
// here with a Component and a default zone; enable/disable adds/removes
// the slot id from `disabled` (via IPC, drags, or the `bar-<id>` menu
// provider toggles - no per-module settings keys exist). Groups render
// their members together and are dragged, enabled and disabled as one unit.
//
// SPLIT MAP (one owner each, no behavior change): Layout (zone layout
// option, storedLayout/positions, normalize, commit, drag order),
// Scale (bar metrics: height, slot tokens, per-module construction
// records, metrics), Modules (registry, owned dynamics, readiness,
// enable/disable, menu providers, IPC bridge).
Singleton {
  id: root

  readonly property string tag: "bar"

  // Real screens for the per-monitor surfaces: one bar window and one move
  // gesture window per valid screen (placeholder screens that appear on
  // wakeup carry an empty name / 0 size and must be filtered out).
  readonly property var screens: Ui.validScreens
  // The per-monitor bar window, keyed by screen name: the MoveWindow needs
  // its zones' rects to keep its input region off the modules.
  property var _moveViews: ({})
  property int moveViewsRevision: 0

  // One bar window per real screen, registered so the MoveWindow proxy can
  // find the window whose zone rects it must keep out of its input region.
  // The registration is the only place the bar knows how many bar surfaces
  // exist, so it is where the count belongs: a reader who sees two bars on
  // three monitors needs the number of registered views to explain it, and
  // the number of screens to explain the two.
  function registerMoveView(view) {
    if (!view || !view.moveRegistrationKey) return
    const key = view.moveRegistrationKey
    const current = root._moveViews[key]
    if (current === view) return
    if (current && root.moveScreenKey === key) root.cancelBarMove()
    const next = Object.assign({}, root._moveViews)
    next[key] = view
    root._moveViews = next
    root.moveViewsRevision++
  }

  function unregisterMoveView(view) {
    if (!view || !view.moveRegistrationKey) return
    const key = view.moveRegistrationKey
    if (root._moveViews[key] !== view) return
    if (root.moveScreenKey === key) root.cancelBarMove()
    const next = Object.assign({}, root._moveViews)
    delete next[key]
    root._moveViews = next
    root.moveViewsRevision++
  }

  function moveViewFor(screen) {
    if (!screen || !screen.name) return null
    return root._moveViews[screen.name] || null
  }

  // --- settings (live view of the raw statusbar section) ---

  readonly property bool enabled: Settings.statusbarEnabled
  // Transient IPC-only hide: when true the bar unmaps and releases its
  // exclusive zone so tiled windows reclaim the space. Never persisted
  // (no Settings key, no schema entry, no menu row) and only reachable
  // through `qs ipc call bar` (`set hideToggle <bool>` or `hideToggle`
  // to flip). Resets to false on every shell start.
  property bool hideToggle: false
  // Effective visibility: the persistent master switch AND the transient
  // hide. Every surface (BarView, MoveWindow, BarShadow) and the published
  // desktop layout read this, so a hidden bar frees screen space exactly
  // like a disabled one without touching the persisted `enabled` value.
  readonly property bool effectiveEnabled: root.enabled && !root.hideToggle
  readonly property string position: Settings.statusbarPosition
  readonly property bool showBorder: Settings.statusbarShowBorder
  readonly property bool showShadow: Settings.statusbarShowShadow
  readonly property bool blurred: Settings.statusbarBlurred
  // Bar thickness is fixed: no user-facing height setting, no wheel resize.
  readonly property int height: 28
  function publishDesktopLayout() {
    DesktopLayoutState.publishBarLayout(root, root.effectiveEnabled, root.position, root.height)
  }
  // Single source of truth: shell.statusbar.layout
  // { left, center, right, disabled }. Zones hold every known slot;
  // `disabled` is the dumb on/off list for static slots.
  readonly property var storedLayout: Settings.statusbarLayout
  // Zones only (all modules, including disabled) - the drag order source.
  // Derived from storedLayout to keep moveSlot math unchanged.
  readonly property var positions: ({
    left: (storedLayout.left || []).slice(),
    center: (storedLayout.center || []).slice(),
    right: (storedLayout.right || []).slice()
  })
  // Dumb off list for static slots. Owned dynamic modules never enter here.
  readonly property var disabledModules: (storedLayout.disabled || []).slice()
  // Derived enabled list (static slots minus disabled, plus workspaces and
  // permanent slots, which are always on). Kept for IPC compat; isEnabled()
  // is the truth.
  readonly property var enabledModules: {
    const out = []
    for (const zone of root.zones) {
      const list = (root.positions[zone] || [])
      for (let i = 0; i < list.length; i++) {
        const id = list[i]
        if (!root._isStandaloneSlot(id) && !root.isOwned(id)) continue
        if (root.isOwned(id) || root.disabledModules.indexOf(id) < 0) {
          if (out.indexOf(id) < 0) out.push(id)
        }
      }
    }
    return out
  }

  // --- live module metrics (F4) ---
  // Bar thickness is a constant, so only the font contributes to the scale
  // (Ui.barScaleWithFont), keeping icons/text in token proportions.
  readonly property real _requestedScale: Math.max(0.5, Math.min(2.0,
    Ui.barScaleWithFont ? Ui.fontScale : 1))
  // Effective scale for icons, canvas AND module text together. Every module
  // grows by this one factor, so the Ui token proportions hold at any bar
  // height and preset; capping the icon scale and the text scale separately
  // is what lets the two drift apart across modules.
  readonly property real iconScale: root._requestedScale
  // The slot is the hit target: never smaller than 12, never taller than
  // the bar minus breathing room on both edges.
  readonly property int iconSlot: Math.max(12, Math.min(
    Math.round(Ui.barIconSlot * root.iconScale), height - 4))
  // The painted canvas sits inside the slot with >=3px inset per edge
  // (~0.54 of the fixed bar height at scale 1 - see the Ui token rule).
  readonly property int iconCanvas: Math.max(8, Math.min(
    Math.round(Ui.barIconCanvas * root.iconScale), root.iconSlot - 6))
  // Label text scale: the SAME scale as the icons, so text modules
  // (the keyboard layout code, the weather readout) grow proportionally
  // with them.
  readonly property real textScale: root.iconScale
  // The horizontal inset an icon-only module's glyph gets from the slot /
  // canvas geometry: Icon centers its canvas inside the slot, so painted
  // content sits (slot - canvas) / 2 away from each slot edge. The zone row
  // lays slots out with zero gap (Zone.xForSlot sums slot widths), so text-
  // bearing modules must box themselves in with this same inset - a label
  // sized to its painted width would otherwise ride flush against the next
  // module, breaking the inter-module spacing every icon-only module has.
  readonly property int slotInset: Math.max(0, Math.round(
    (root.iconSlot - root.iconCanvas) / 2))
  // Filtered layout for rendering: zones minus `disabled` (owned always
  // pass). Owned modules carry no settings toggle - the bar governs their
  // zone position, the module itself owns transient visibility
  // (visible:false / width:0 stay in the order). Stale ids that no
  // registry slot resolves never render.
  // Imperative, not a binding: a `var` binding that returns a fresh object
  // on every evaluation makes QML report "Binding loop detected for property
  // layout" when the store bumps the stored layout while `layout` is being
  // evaluated. The signature guard keeps unrelated Settings writes (e.g. the
  // NightLight global toggle) from churning the bar.
  //
  // The filter itself is BarLib.renderLayout; this owns the signature guard
  // and the registry lookups it is handed.
  property var layout: ({ left: [], center: [], right: [] })
  property string _layoutSig: ""

  function _layoutSignature(v) {
    // Stable signature for change detection: sorted JSON of the three
    // zones (order inside each zone matters, so not sorted per zone).
    try {
      return JSON.stringify(v)
    } catch (e) {
      return ""
    }
  }

  function updateLayout() {
    const out = BarLib.renderLayout(root.positions, root.disabledModules,
      root.zones, root._pinned, id => root.componentFor(id), id => root.isOwned(id))
    const sig = root._layoutSignature(out)
    if (sig === root._layoutSig) return
    root._layoutSig = sig
    root.layout = out
    // Readiness, on the layout side: updateLayout runs on every registry and
    // settings change and this is the only path in the bar that walks the
    // whole layout to settle the module records.
    root._settleReadies(out, Date.now())
  }
  readonly property var zones: ["left", "center", "right"]

  // One store write, one pass over the gate leases and one render.
  //
  // `positions` and `disabledModules` are derived from `storedLayout` and
  // `enabledModules` from those two, and each derived property notifies
  // separately - a handler on every one of them ran this block four times for
  // a single commit (five when `enabledModules` changed twice), which is four
  // full `renderLayout` + `JSON.stringify` passes and four trips through
  // `UnitGate.ensure`, each of which emits `unitChanged` + `statesChanged`
  // and answers with a whole-boot-report rebuild.
  //
  // The pass is deferred one turn so it runs once the store's notification
  // burst has unwound. QML does not evaluate the derived bindings before it
  // delivers this handler - `storedLayout` is notified while `positions` and
  // `disabledModules` still hold the previous write's values, so a
  // synchronous pass here would render the old layout and, with no second
  // handler left, never catch up. The flag coalesces a burst of writes into a
  // single pass, so the count is one per write even when a caller writes
  // twice in one turn.
  //
  // Nothing is lost by dropping the other three handlers: every one of them
  // can only fire because `storedLayout` fired, and in this whole tree no
  // other listener observes their signals (`positions`, `disabledModules` and
  // `enabledModules` are read imperatively, by `updateLayout`, `isEnabled`
  // and the two IPC dumps).
  onStoredLayoutChanged: root._scheduleLayoutSync()
  property bool _layoutSyncPending: false

  function _scheduleLayoutSync() {
    if (root._layoutSyncPending) return
    root._layoutSyncPending = true
    Qt.callLater(() => {
      root._layoutSyncPending = false
      root._syncGateLeases()
      root.updateLayout()
    })
  }

  onZonesChanged: root.updateLayout()
  // _components, _groups, _pinned and owned maps are var objects mutated
  // via assignment in Component.onCompleted / ownModule / releaseModule.
  // Their change signals are _componentsChanged etc. - the leading underscore
  // is part of the property name, so the handler is on_ComponentsChanged.
  on_ComponentsChanged: root.updateLayout()
  on_GroupsChanged: root.updateLayout()
  on_PinnedChanged: root.updateLayout()
  on_OwnedChanged: root.updateLayout()
  on_OwnedCompsChanged: root.updateLayout()

  // --- module registry ---
  // id -> Component, instantiated by BarView wherever the layout puts the id.

  property var _components: ({})
  property var _zones: ({})
  // Group key id -> ordered member module ids. A group occupies exactly one
  // layout slot (its key id) while rendering its members together; members
  // are never placed or enabled individually, which is what makes a group
  // a single, indivisible draggable unit (nothing to pull out from inside).
  property var _groups: ({})
  // Slot id -> anchor slot id it must precede when enabled (e.g. the
  // weather module always slots in directly before the session group).
  // General enablement ordering without per-module special cases.
  property var _placeBefore: ({})
  // Always-on slots: no settings toggle, kept in their zone at boot. Empty
  // today - a slot listed here is force-enabled even when the user's file
  // predates it, which is also what makes it undisableable.
  property var _permanent: ({})
  // Slot ids that carry no toggle but are not part of _permanent: they are
  // always enabled without being force-enabled at boot. Held as data so the
  // layout normalizer (a pure library) never names a module itself.
  readonly property var _alwaysOnIds: ["workspaces"]
  // Slot ids no registry entry serves. The "microphone" id is carried by
  // older default layouts but no registry slot serves it; it is dropped
  // on every write so an upgraded file heals instead of leaking a dead
  // entry. See _normalizeLayout for why an id is on this list.
  readonly property var _staleSlotIds: ["microphone"]
  // Pinned slots: map of slot id -> zone it is pinned to. Pinned slots are
  // non-rearrangeable (a drag never moves them) and always resolve to the
  // end of their pinned zone, so e.g. the session group stays parked on the
  // far right corner. They remain fully toggle-able like any other module.
  property var _pinned: ({})

  function isGroup(id) {
    return BarLib.isGroup(root._groups, id)
  }

  // True when a slot is pinned to a zone and must not be re-arranged.
  // Draggable slots exclude these, so a pinned group stays put.
  function isPinned(id) {
    return root._pinned !== null && root._pinned[id] !== undefined
  }

  function groupMembers(id) {
    return BarLib.groupMembers(root._groups, id)
  }

  // True when `id` is on: owned dynamic modules are always on (they
  // cannot be disabled, only re-arranged); static slots are on unless
  // listed in the layout `disabled` array (the single source of truth).
  function isEnabled(id) {
    if (root.isOwned(id)) return true
    return root.disabledModules.indexOf(id) < 0
  }

  // True when a module is on the bar: as its own slot, or inside an enabled
  // group. Resolves against the filtered layout (zones minus disabled).
  function isModuleVisible(id) {
    return BarLib.moduleVisible(root.layout, root._groups, id)
  }

  // --- owned (dynamic) modules ---
  // A service that knows its own state claims a slot and controls the
  // module itself; the bar hosts the placement (and the window contract)
  // without learning what the module is. `_owned` is a reactive list of
  // { id, zone }; `_ownedComps` maps id -> Component. Logic lives in
  // BarLib.js.
  property var _owned: []
  property var _ownedComps: ({})

  // Claim a slot. spec: { id, zone, component, draggable }. Registers the
  // component once (rejecting ids the static registry or another owner
  // already holds) and gives the id a persisted place in its zone when the
  // store is ready - deferred to the ready pass otherwise. Returns false
  // when the spec is unusable or the id is taken.
  function ownModule(spec): bool {
    if (!spec || typeof spec !== "object") return false
    if (typeof spec.component === "undefined") return false
    const id = String(spec.id || "")
    if (id === "" || root.isOwned(id)) return false
    if (root.componentFor(id) !== null) return false
    // Reassign fresh objects (not in-place mutation) so both _owned and
    // _ownedComps emit change signals the Zone bindings track - and
    // populate the component map first so a delegate that reads it on the
    // same tick sees the component, not an empty map.
    const comps = Object.assign({}, root._ownedComps, { [id]: spec.component })
    const zone = BarLib.normZone(String(spec.zone || "right"))
    const next = root._owned.concat([{
      id: id,
      zone: zone,
      draggable: spec.draggable === true
    }])
    root._ownedComps = comps
    root._owned = next
    root.markModuleFound(id)
    // The placement is attempted here and deferred to the ready pass when the
    // store has not landed: the ready pass gives a deferred id its gap.
    root._ensureOwnedPosition(id)
    return true
  }

  // Relinquish a slot (a reloading service cleans up its indicator). The
  // zone position is kept: re-registration finds its old gap and never
  // reorders neighbors. The bar governs position; the service only lends
  // the component.
  function releaseModule(id): bool {
    const next = BarLib.removeOwned(root._owned, id)
    if (next === null) return false
    root._owned = next
    const comps = Object.assign({}, root._ownedComps)
    delete comps[id]
    root._ownedComps = comps
    return true
  }

  // Give a registered owned id one persisted place, deterministically:
  // immediately before the first pinned slot in its zone, else appended.
  // Idempotent - no-ops when already placed or the store is not ready.
  // The bar governs position: owned modules live in the same layout zones
  // as static ones and are only re-arranged by drags, never disabled.
  function _ensureOwnedPosition(id) {
    if (!Settings.ready || !root.isOwned(id)) return false
    let zone = "right"
    const owned = root._owned
    for (let i = 0; i < owned.length; i++) if (owned[i].id === id) zone = owned[i].zone
    const cur = root.positions
    if (!cur || !Array.isArray(cur.left)) return false
    if ((cur[zone] || []).indexOf(id) >= 0) return true
    const next = { left: cur.left.slice(), center: cur.center.slice(), right: cur.right.slice() }
    BarLib.insertBeforePin(next[zone], root._pinned, id)
    return root._commitLayout(next)
  }

  // Resolve any layout slot id to its component: owned registrations win
  // over the static registry (id spaces are disjoint by contract), group
  // keys resolve to the group container, plain modules to themselves.
  function componentFor(id) {
    if (root._ownedComps[id] !== undefined) return root._ownedComps[id]
    if (root._groups && root._groups[id] !== undefined) return groupComp
    return root._components[id] || null
  }

  // A slot is owned when a service registered it (component map is the
  // source of truth; _owned carries placement metadata).
  function isOwned(id) {
    return root._ownedComps[id] !== undefined
  }

  // Whether an owned module's spec allowed dragging (fixed by default).
  function ownedDraggable(id) {
    const owned = root._owned
    for (let i = 0; i < owned.length; i++)
      if (owned[i].id === id) return owned[i].draggable === true
    return false
  }

  // A fixed obstacle: never part of a drag's movable sequence. Pinned slots
  // are re-pinned to their zone end by every write; non-draggable owned
  // modules keep their persisted place (a wall in the row). This is the
  // whole slot-level mobility rule: everything a drag may pick up is the
  // negation of this.
  function isFixedSlot(id) {
    return root.isPinned(id) || (root.isOwned(id) && !root.ownedDraggable(id))
  }

  // --- generic module on/off ("settings module") ---
  // Static slots toggle through the layout `disabled` array only - there
  // are no per-module Enabled keys. The bar-enabled settings page lists
  // one provider toggle per id below (see _toggleIds); the menu resolves
  // each row's pill and flip through the registered surfaces, so a flip
  // lands straight in `disabled` with no intermediate store key to drift.
  // Owned dynamic modules never enter `disabled`: the bar only governs
  // their position while the module owns its own visibility.

  // Ids with a menu toggle: every standalone slot except the always-on
  // ones (workspaces carries no toggle) and anything declared in
  // _permanent. Future static modules appear here automatically once
  // registered + placed.
  function _toggleIds() {
    const out = []
    for (const id of root._slotIds()) {
      if (!root._isStandaloneSlot(id) || root.isOwned(id)) continue
      if (root._permanent[id] !== undefined || id === "workspaces") continue
      out.push(id)
    }
    return out
  }

  // Menu provider surface for one toggle id. `checked` is read inside the
  // row's reactive binding, so the pill tracks the bar (and hand edits)
  // with no polling; `runToggle` returning true marks the flip handled.
  function _moduleSurface(id) {
    return {
      checked: () => root.isEnabled(id),
      runToggle: (item, state) => {
        return state ? root.enableModule(id) : root.disableModule(id)
      }
    }
  }

  // Provider id ownership: ProviderHost hands a record to the host Menu
  // once and refuses a re-registration whose owner is a different object,
  // so a record is only ever replaceable by the object that owns it. Every
  // `bar-<id>` record is owned for as long as this unit is alive and is
  // released in its teardown; a refused id would otherwise pin the surface
  // to a dead closure and drop the row's toggle behavior.
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

  function _releaseMenuProviders() {
    // Snapshot first: the loop must not walk a collection it rewrites.
    const ids = root._toggleIds()
    for (let i = 0; i < ids.length; i++)
      ProviderHost.unregisterProvider("bar-" + ids[i], root)
  }

  // Menu provider registration: overlays toggle semantics onto the
  // bundle-declared `bar-<id>` rows. ProviderHost keeps each surface under
  // this unit as owner and replays the whole set when Menu registers as its
  // host, so drain order does not gate the rows.
  function _registerMenuProviders() {
    for (const id of root._toggleIds())
      root._claimProviderId("bar-" + id, root._moduleSurface(id), false)
  }

  // Standalone slot ids in iteration order: plain modules plus group
  // keys. Group members render through their group and hold no slot.
  function _slotIds() {
    return Object.keys(root._components).concat(Object.keys(root._groups))
  }

  property var _gateLeases: ({})

  // Gate resolver for on-demand services. archUpdates and printers are gated
  // on their bar module (proposal 6.3): the service loads only when the module
  // is enabled. The drain skips them; the bar gate owner materializes them on
  // enable through UnitGate.
  //
  // A unit whose consumer is not a bar module does not belong on this list.
  // powerProfile is the case that proves it: the AC policy is a resident unit
  // that reads the daemon, so a gate the bar holds on the daemon's behalf would
  // leave the policy unbuilt on a shell with the slot switched off.
  function _gateOwner(id) {
    return "bar:" + id
  }

  function _gateResolve(id) {
    if (typeof id !== "string" || !root._isGated(id)) return false
    const result = UnitGate.ensure(id, root._gateOwner(id))
    if (!result || result.ok !== true) {
      if (result && result.lease) UnitGate.release(result.lease)
      return false
    }
    // The lease is only recorded when this id does not already hold it.
    // UnitGate.ensure finds the live lease for a (unit, owner) pair and
    // returns the SAME token every time (`_findLease` + the entry's own
    // `token`), and ensure never increments the count, so a repeat resolve
    // for a held id yields the identical token. Reassigning
    // `_gateLeases` there would allocate a fresh object and emit a change
    // signal for a map whose contents did not move; nothing in the tree
    // binds to `_gateLeases`, so the cost is pure churn on a path that runs
    // on every layout write. A released id is gone from the map and gets a
    // new token, so it takes the assignment.
    if (root._gateLeases[id] !== result.lease)
      root._gateLeases = Object.assign({}, root._gateLeases, { [id]: result.lease })
    return true
  }

  function _gateRelease(id) {
    const lease = root._gateLeases[id]
    if (lease === undefined) return false
    if (!UnitGate.release(lease)) return false
    const next = Object.assign({}, root._gateLeases)
    delete next[id]
    root._gateLeases = next
    return true
  }

  function _syncGateLeases() {
    for (let i = 0; i < root._gatedIds.length; i++) {
      const id = root._gatedIds[i]
      if (root.isEnabled(id)) root._gateResolve(id)
      else root._gateRelease(id)
    }
  }

  // --- module startup -> readiness ---
  //
  // The sync pass is the bar's second half of startup, and it runs on a gate
  // rather than on a clock: `Settings.ready` is the boundary between a catalog
  // that exists and a catalog that knows where its slots go. Asked before the
  // store lands it does nothing at all, because there is nothing to heal
  // against; the ready change handler runs it again once the schema is in.
  //
  // An owned module registered before the store has no persisted place yet, so
  // the pass places every owned id after the static heal: that loop is the
  // same one, and it runs on a path that already writes to the store.
  function syncAllModulesFromSettings() {
    if (!Settings.ready) return // wait out the schema load
    root.ensurePermanentSlots()
    root.ensureAllSlotsInLayout()
    for (let i = 0; i < root._owned.length; i++) {
      root._ensureOwnedPosition(root._owned[i].id)
    }
    // Gated units follow actual visibility: a module hidden via `disabled`
    // keeps its service unloaded; enabling one materializes it.
    root._syncGateLeases()
    root.updateLayout()
  }

  // --- the per-module construction record ---
  //
  // The module wrappers (Zone's slot loader, Group's member loader) open and
  // close the clock and report into the registry here, because this is the only
  // object that knows both halves of the picture: which Component a slot
  // resolved to, and how many real screens exist to build it on.
  //
  // "Loaded" means the Loader reached Ready. It deliberately does not mean the
  // module painted: `shell/README.md` records that
  // `QT_QPA_PLATFORM=offscreen` drives no render loop, so first-frame
  // presentation latency is not observable in this environment.
  //
  // One record per module KIND, not per instance. The bar is built per output,
  // so on three monitors every module is constructed three times. The first
  // instance to finish establishes the kind, and a later instance of the same
  // kind is stamped `rebuilt` rather than opening a second record.
  //
  // Neither map is read by a binding - they are a private scratch record
  // written once per construction - so they are mutated in place rather than
  // reassigned. Reassigning them per module would be a fresh object allocation
  // inside the layout path for no signal anyone listens to.
  //
  // In place is also what keeps the stamper loop-free. `markBuildStart` runs
  // inside the `sourceComponent` binding of the very Loader it stamps
  // (Zone.resolveSlot, Group's member delegate), and a QML property that one
  // evaluation reads and then writes is a binding loop: Qt reports it, aborts
  // the evaluation and drops the binding, so that Loader never resolves its
  // component again.
  //
  // The stamps are `var` and not `int` because Date.now() is ~1.79e12 and a QML
  // int is 32-bit, so a stamp held in one truncates negative.
  property var _buildOpen: ({})   // kind -> { comp, t0 } while a Loader holds it
  property var _buildDone: ({})   // kind -> true once the kind first reported
  property var _profile: ({})     // kind -> the lifecycle record below
  property var _profileSeen: ({}) // kind -> true, one `ready` stamp per kind

  // The lifecycle record for one module kind, with the stamp for each point
  // where the module's state actually changes:
  //
  //   found     the id entered the catalog: a static slot, a group key, or an
  //             owned registration. Nothing has been constructed.
  //   booting   a Loader was handed the Component; the clock opens. The same
  //             synchronous turn as the construction.
  //   booted    that Loader reached Ready, so the component exists.
  //   ready     the id ALSO reached the rendered layout, so the user sees it.
  //   rebuilt   a later instance of a kind the first one already established.
  //
  // `ready` is the one that carries what the others cannot: `booted` says a
  // Component was instantiated and `ready` says the user can see it, and the
  // gap between them is a module that built and then failed to appear - a hole
  // in the bar.
  //
  // 0 means the stamp has not happened, and it is not a legal value for one
  // that has: a module constructed in the same millisecond it was found is 0.
  function _profileRec(kind, bootAt) {
    let rec = root._profile[kind]
    if (rec === undefined) {
      rec = ({ bootAt: bootAt, found: 0, booting: 0, booted: 0, ready: 0, rebuilt: 0 })
      root._profile[kind] = rec
    }
    return rec
  }

  // `found` for every static slot and group key in the catalog. A group is
  // entered by its key alone: its members hold no slot of their own and
  // Group.qml reports each one as it constructs, so stamping them here too
  // would be the same module entered twice.
  function _markCatalogFound() {
    for (const id in root._components) root.markModuleFound(id)
    for (const id in root._groups) root.markModuleFound(id)
  }

  // `found`: the id is in the catalog and nothing has been built for it yet.
  function markModuleFound(kind) {
    const rec = root._profileRec(kind, 0)
    if (rec.found !== 0) return
    rec.found = Date.now()
  }

  // `ready`: booted AND present in the rendered layout. Both conditions, and
  // the point of the stamp is that they are separate - `booted` says a
  // Component was instantiated and `ready` says the user can see it, so a
  // module that reaches one and not the other has a hole in the bar.
  //
  // The two arrive in EITHER order and the stamp has to come from whichever is
  // second, which is why this walks the layout instead of sitting in one
  // handler. Both orders are real: the ready pass places every slot before the
  // first Loader has built anything (layout first, Loader completes it), and an
  // owned module registers after the layout has settled (Loader first, the
  // layout completes it). Both callers pass the instant they were called at, so
  // neither takes a second reading of the clock.
  //
  // The second pass is the other half of the same question: a kind that WAS
  // placed and no longer is. That is how a module is switched off or dragged
  // elsewhere. The record is deleted with it, so a module that comes back is a
  // new record with a fresh `found` - the same as it would be on a real
  // restart.
  function _settleReadies(layout, now) {
    for (const zone in layout) {
      const list = layout[zone]
      for (let i = 0; i < list.length; i++) {
        const slot = list[i]
        // The slot's own record, then its members'. A group occupies ONE
        // layout entry and renders several modules, so the members have to be
        // settled explicitly or every one of them sits unplaced while the user
        // is looking at them.
        const ids = [slot]
        const members = root._groups[slot]
        if (members !== undefined) {
          for (let m = 0; m < members.length; m++) ids.push(members[m])
        }
        for (let n = 0; n < ids.length; n++) {
          const kind = ids[n]
          if (root._profileSeen[kind] === true) continue
          const rec = root._profile[kind]
          if (rec === undefined || rec.booting === 0 || rec.booted === 0) continue
          root._profileSeen[kind] = true
          rec.ready = now
        }
      }
    }
    for (const kind in root._profileSeen) {
      if (root._profileSeen[kind] !== true) continue
      if (root._inLayout(layout, kind)) continue
      root._profileSeen[kind] = false
      delete root._profile[kind]
    }
    // Readiness, on the entrance side: every settle re-checks the boot gate,
    // so whichever arrival is second (layout or Loader) releases the reveal.
    root._updateEntrance()
  }

  // --- boot entrance gate ---
  //
  // Holds every slot hidden until all placed modules have built, then
  // releases them together into one slidefade (down from the top edge,
  // up from the bottom). One-shot: once latched it never closes again,
  // so toggles and drags keep their existing grow/enter motion.
  //
  // Expected ids are the rendered layout expanded through groups (a group
  // key renders its members, never itself). Each must have reached `ready`
  // (booted AND in layout) via _settleReadies. An empty layout never latches
  // here - the store is still landing - the fallback timer below is the backstop
  // that guarantees the bar cannot stay held forever (a Loader that errors
  // never reports, so without it one broken module would blank the bar).
  property bool entranceReady: false

  Timer {
    id: entranceFallback

    interval: 3000
    // Stops once the entrance latches early: without the binding the
    // one-shot still fires at 3s into a _latchEntrance() that returns
    // immediately - one wasted wakeup per boot.
    running: !root.entranceReady
    repeat: false
    onTriggered: root._latchEntrance()
  }

  function _entranceExpectedIds(layout) {
    return BarLib.entranceExpectedIds(layout, root._groups)
  }

  function _updateEntrance() {
    if (root.entranceReady) return
    if (!Settings.ready) return
    const layout = root.layout
    if (!layout) return
    const expected = root._entranceExpectedIds(layout)
    if (expected.length === 0) return
    for (let i = 0; i < expected.length; i++) {
      if (root._profileSeen[expected[i]] !== true) return
    }
    root._latchEntrance()
  }

  function _latchEntrance() {
    if (root.entranceReady) return
    root.entranceReady = true
  }

  // Is `kind` on the bar, either as a slot of its own or as a member of a
  // group that is? Both, and the second half is load-bearing: a group member
  // holds no slot, so `tray` and `logout` are reached through the `session`
  // key. Without that, every group member would sit unplaced forever.
  function _inLayout(layout, kind) {
    for (const zone in layout) {
      const list = layout[zone]
      if (list.indexOf(kind) >= 0) return true
      for (let i = 0; i < list.length; i++) {
        const members = root._groups[list[i]]
        if (members !== undefined && members.indexOf(kind) >= 0) return true
      }
    }
    return false
  }

  // Open the construction clock for a module kind. Called from the same
  // expression that hands the Component to a Loader, so the stamp lands in the
  // same synchronous turn as the construction itself.
  //
  // `Loader.status` cannot be the opener and this is measured, not assumed:
  // for a synchronous `sourceComponent` QQuickLoader assigns Loading straight
  // into its private state field and never emits `statusChanged` for it, so
  // the only transition a caller can observe is the jump to Ready (verified on
  // Quickshell 0.3.1). What the stamp therefore covers is everything from this
  // call to Loader.Ready - component resolution, the module's own construction
  // and every child it builds - and nothing else.
  //
  // Re-resolving the same Component for the same kind is a no-op: the Loader
  // keeps the item it already built, so a re-evaluated binding must not restart
  // the clock. A different Component means a real rebuild, and the clock
  // restarts with it.
  function markBuildStart(kind, comp) {
    if (kind === "" || comp === null || comp === undefined) return
    const open = root._buildOpen[kind]
    if (open !== undefined && open.comp === comp) return
    const now = Date.now()
    root._buildOpen[kind] = { comp: comp, t0: now }
    const rec = root._profileRec(kind, now)
    if (rec.booting !== 0) return
    rec.booting = now
  }

  // Close the clock: the Loader for `kind` reached Ready. The first instance of
  // a kind opens the record's `booted`; a later one stamps `rebuilt`.
  function reportModuleReady(kind) {
    const open = root._buildOpen[kind]
    delete root._buildOpen[kind]
    const now = Date.now()
    const rec = root._profileRec(kind, open !== undefined ? open.t0 : now)
    if (root._buildDone[kind] === undefined) {
      root._buildDone[kind] = true
      rec.booted = now
      // Readiness, on the Loader side: a slot already in the rendered layout is
      // on the bar the moment its Component exists, so this is the second of the
      // two conditions and the `ready` stamp comes from here. `now` is the
      // instant already taken - no second reading of the clock on a
      // construction path.
      root._settleReadies(root.layout, now)
    } else {
      // A later instance of a kind the first one already established: a detail
      // of the per-output build, not a second record.
      rec.rebuilt = now
    }
  }

  // Keep the always-on slots (workspaces, plus anything in the currently empty
  // _permanent map) in their zones and enabled; heals user files that predate
  // them. Idempotent - isEnabled short-circuits.
  //
  // Returns how many slots it had to force-enable, which is 0 on every boot
  // after the first and is the one figure that says whether a heal happened
  // or whether the user's file already agreed. A count and not a bool because
  // "did anything move" and "how much" are different questions and only the
  // second is interesting once the boolean is known to be false.
  function ensurePermanentSlots() {
    let n = 0
    for (const id in root._permanent) {
      if (root.isEnabled(id)) continue
      root.enableModule(id)
      n++
    }
    if (!root.isEnabled("workspaces")) {
      root.enableModule("workspaces")
      n++
    }
    return n
  }

  // Heal the zone order: every known static slot and every registered
  // owned id gets exactly one persisted place. Missing ids are inserted
  // at their default (_placeBefore / owned-zone) spot; present ids are
  // untouched, so user drags survive upgrades that add new modules.
  // Single commit at the end - no churn when nothing is missing.
  function ensureAllSlotsInLayout() {
    const cur = root.positions
    if (!cur || !Array.isArray(cur.left)) return false
    const next = { left: cur.left.slice(), center: cur.center.slice(), right: cur.right.slice() }
    let changed = false
    const place = id => {
      if (BarLib.slotPresent(next, id)) return
      const zone = root._zones[id]
      if (zone === undefined) return
      BarLib.insertBeforeAnchor(next[zone], root._placeBefore[id], id)
      changed = true
    }
    for (const id of root._slotIds()) {
      // Owned ids are placed by their own loop below, from the owned zone.
      if (root.isOwned(id)) continue
      // _isStandaloneSlot is both filters this loop needs: it rejects an id
      // no component resolves, and a group member, which renders through its
      // group's slot and holds none of its own.
      if (!root._isStandaloneSlot(id)) continue
      place(id)
    }
    for (let i = 0; i < root._owned.length; i++) {
      const oid = root._owned[i].id
      if (BarLib.slotPresent(next, oid)) continue
      BarLib.insertBeforePin(next[BarLib.normZone(root._owned[i].zone)], root._pinned, oid)
      changed = true
    }
    if (!changed) return true
    return root._commitLayout(next)
  }

  Component.onCompleted: {
    root.publishDesktopLayout()
    Registry.offer("bar", {
      title: "Bar",
      description: "top bar layout + modules",
      verbNames: [
        "disable",
        "dump",
        "dumpAll",
        "enable",
        "hideToggle",
        "set",
        "status",
        "toggle",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
    // Modules render group members through memberComponent; the layout only
    // ever holds standalone slots + group keys.
    root._components = { workspaces: workspacesComp, privacy: privacyComp, clock: clockComp, weather: weatherComp, keyboardLayout: keyboardLayoutComp, bluetooth: bluetoothComp, battery: batteryComp, network: networkComp, printers: printersComp, powerProfile: powerProfileComp, archUpdates: archUpdatesComp, colorPicker: colorPickerComp, nightLight: nightLightComp, nowPlaying: nowPlayingComp, volume: volumeComp, logout: logoutComp, tray: trayComp }
    // Session = tray + logout. Logout is the static anchor on the bar's far
    // corner; the tray sits directly to its left and slides out leftward off
    // it without ever moving logout.
    root._groups = { session: ["tray", "logout"] }
    root._zones = { workspaces: "left", privacy: "right", clock: "center", weather: "right", keyboardLayout: "right", bluetooth: "right", battery: "right", network: "right", printers: "right", powerProfile: "right", archUpdates: "right", colorPicker: "right", nightLight: "right", nowPlaying: "right", volume: "right", session: "right" }
    // Right-zone default order: the keyboard layout indicator, bluetooth,
    // battery and the network module join the zone ahead of the session
    // group, in toggle order - bluetooth and battery slot in directly before
    // the network module. Privacy is a right-zone launcher because the dots
    // live on the overlay, and anchors on `battery` to sit where the shipped
    // default layout puts it: after battery, clear of the pinned session
    // group on the far corner.
    root._placeBefore = { privacy: "battery", weather: "session", keyboardLayout: "session", bluetooth: "network", battery: "network", network: "volume", printers: "session", powerProfile: "session", archUpdates: "session", colorPicker: "session", nightLight: "session", nowPlaying: "session", volume: "session" }
    // Empty: every static slot is toggleable today. The map stays because
    // BarLib.normalizeLayout takes it as an input, and it is where a future
    // always-on slot (one the user may not switch off) is declared.
    root._permanent = ({})
    // The session group (tray + power) is pinned to the right edge: it
    // cannot be dragged elsewhere and always sits at the end of the right
    // zone, while remaining toggleable through its menu row.
    root._pinned = { session: "right" }
    // `found` for the static catalog. One call per slot rather than one per
    // Component, because a group is entered by its KEY and its members are
    // reported individually by Group.qml as they construct - a `found` for
    // `tray` here and another in Group would be the same module twice.
    //
    // The stamp is taken here, after the registry is populated and before
    // updateLayout, so `found` genuinely precedes every `booting`.
    root._markCatalogFound()
    // Reading mode is an owned dynamic module like caffeine/update: it
    // takes a right-zone slot only while its state file exists and stays
    // in the persisted layout while hidden.
    root.ownModule({ id: "readingMode", zone: "right", draggable: true, component: readingModeComp })
    // Recording indicator: same owned contract, hidden while idle.
    root.ownModule({ id: "recording", zone: "right", draggable: true, component: recordingComp })
    // Timer indicator: same owned contract, hidden while idle or stopped.
    // The module mirrors the timer bus topic itself; the slot stays
    // registered so the persisted position never churns.
    root.ownModule({ id: "timer", zone: "right", draggable: true, component: timerComp })
    // Caffeine + update indicators: same owned contract - the services publish
    // bus topics and these modules mirror them, so the services never import
    // the bar.
    root.ownModule({ id: "caffeine", zone: "right", draggable: true, component: caffeineComp })
    root.ownModule({ id: "update", zone: "right", draggable: true, component: updateComp })
    root.updateLayout()
    // Heal the zone order once settings land; menu toggle rows bind below.
    if (Settings.ready) root.syncAllModulesFromSettings()
    // One-shot stale-slot heal: runs here and on the settings-ready path
    // below, whichever sees the loaded layout first (idempotent).
    root._migrateStaleSlotsOnce()
    root._registerMenuProviders()
  }
  Component.onDestruction: {
    // Teardown releases every provider id: each surface closes over this
    // root, so a survivor would keep a dead toggle closure.
    root._releaseMenuProviders()
    for (const id of root._gatedIds) UnitGate.releaseOwner(root._gateOwner(id))
    DesktopLayoutState.releaseBarLayout(root)
    Registry.unregister(root.tag)
  }

  Connections {
    target: Settings

    // Kick the first heal the moment the schema + values load; the layout
    // starts at its file default and missing slots are placed without
    // touching `disabled`.
    function onReadyChanged() {
      if (Settings.ready) {
        root.syncAllModulesFromSettings()
        root._migrateStaleSlotsOnce()
      }
    }
  }

  Component {
    id: workspacesComp

    Workspaces {}
  }
  Component {
    id: privacyComp

    Privacy {}
  }
  Component {
    id: clockComp

    Clock {}
  }
  Component {
    id: keyboardLayoutComp

    KeyboardLayout {}
  }
  Component {
    id: weatherComp

    Weather {}
  }
  Component {
    id: bluetoothComp

    Bluetooth {}
  }
  Component {
    id: batteryComp

    Battery {}
  }
  Component {
    id: networkComp

    Network {}
  }

  Component {
    id: powerProfileComp

    PowerProfile {}
  }

  Component {
    id: archUpdatesComp

    ArchUpdates {}
  }

  Component {
    id: colorPickerComp

    ColorPicker {}
  }

  Component {
    id: nightLightComp

    NightLight {}
  }

  Component {
    id: nowPlayingComp

    NowPlaying {}
  }

  // Owned indicator: registered as a dynamic module (see onCompleted), so
  // it never enters the static _components map or the settings toggles.
  Component {
    id: readingModeComp

    ReadingMode {}
  }

  // Owned recording indicator: state comes from the Recording core
  // singleton; the slot persists in the layout while hidden.
  Component {
    id: recordingComp

    Recording {}
  }

  // Owned timer indicator: state comes from the timer bus topic; the slot
  // persists in the layout while hidden. Imported aliased (CoreTimer) - the
  // bare name collides with QtQml's Timer type.
  Component {
    id: timerComp

    CoreTimer.Timer {}
  }

  // Owned caffeine indicator: mirrors the inhibitor.bus topic published by
  // the Inhibitor service (caffeineEnabled comes in the payload, so the
  // module never imports Settings-backed services).
  Component {
    id: caffeineComp

    Caffeine {}
  }

  // Owned update indicator: mirrors the update.available bus topic
  // published by the Update service.
  Component {
    id: updateComp

    Update {}
  }

  Component {
    id: volumeComp

    Volume {}
  }

  Component {
    id: logoutComp
    Logout {}
  }
  Component {
    id: trayComp

    Tray {}
  }
  Component {
    id: printersComp

    Printers {}
  }
  // The group container; componentFor resolves a group key to this. The
  // slot wrapper tells it which group it is (groupKey) so it can render and
  // wire that group's members.
  Component {
    id: groupComp

    Group {}
  }

  // --- writes ---

  function setOption(key, value) {
    switch (key) {
      case "enabled":
        // The master switch lives in the schema store; it flushes to the
        // same shell.statusbar.enabled leaf the raw section used, keeping
        // the IPC write path and the Settings menu on one value.
        return Settings.setOption("shell.statusbar.enabled", value === true)
      case "position":
        // Schema-owned (the settings menu and the drag write the same leaf);
        // the store validates against top/bottom.
        return Settings.setOption("shell.statusbar.position", value)
      case "showBorder":
        return Settings.setOption("shell.statusbar.showBorder", value === true)
      case "showShadow":
        return Settings.setOption("shell.statusbar.showShadow", value === true)
      case "blurred":
        return Settings.setOption("shell.statusbar.blurred", value === true)
      case "layout": {
        const norm = root._normalizeLayout(value)
        if (norm === null) return false
        return Settings.setOption("shell.statusbar.layout", norm)
      }
      case "hideToggle":
        // Transient IPC-only hide: flips no persisted key, touches no file.
        // `value === true` hides (unmaps + releases the exclusive zone),
        // anything else shows again. Only reachable through IPC `set`.
        root.hideToggle = value === true
        return true
    }
    return false
  }

  // The one layout write. `next` is the { left, center, right } clone a
  // caller has already mutated in place (every layout mutation in this file
  // builds a fresh clone first, so the live `positions` arrays are never
  // touched), and the commit is the store's own answer.
  //
  // `disabled` defaults to the live off list. A caller that derives its own
  // off list hands it in: enable and disable both read `storedLayout`
  // directly and edit one id in it, so reusing `disabledModules` there would
  // throw away the very edit the write exists for. That array belongs to the
  // caller; this function never mutates it.
  function _commitLayout(next, disabled) {
    return root.setOption("layout", {
      left: next.left,
      center: next.center,
      right: next.right,
      disabled: disabled === undefined ? root.disabledModules.slice() : disabled
    })
  }

  // Toggle the bar itself (shell.statusbar.enabled). Returns the commit
  // result: true when the new value was accepted and flushed.
  function toggleBar(): bool {
    return Settings.toggleOption("shell.statusbar.enabled")
  }

  // Flip the transient IPC-only hide. Never persisted: only unmaps the
  // windows and releases the exclusive zone until flipped back or the
  // shell restarts. Always succeeds.
  function toggleHide(): bool {
    root.hideToggle = !root.hideToggle
    return true
  }

  // A standalone slot id is draggable and occupy-able in the layout: a
  // plain module or a group key, but never a group member (members render
  // only through their group and hold no slot of their own).
  //
  // Resolution is `componentFor`, so an OWNED id answers true here too: a
  // service-registered slot occupies the layout exactly like a static one.
  // Every consumer of this answer discriminates owned ids separately - each
  // one either filters `isOwned` out first, or pairs this with an `isOwned`
  // test in the same expression - so the owned ids this admits are the ones
  // the consumer wanted anyway.
  function _isStandaloneSlot(id) {
    if (!root.componentFor(id)) return false
    for (const gid in root._groups)
      if (root.groupMembers(gid).indexOf(id) >= 0) return false
    return true
  }

  // Single-option normalize: { left, center, right, disabled }. Zones hold
  // standalone slots plus registered owned module ids, one id in exactly
  // one zone, no duplicates. Group members never appear. `disabled` is a
  // dumb off list for static slots only: owned dynamic modules, permanent
  // slots and workspaces are stripped. Owned modules cannot be disabled at
  // all; workspaces and permanent slots are enabled by ensurePermanentSlots
  // at boot, so persisting them off would only be undone.
  //
  // The rules live in BarLib.normalizeLayout; what each id *is* stays here.
  // Two of the inputs are this bar's own registry facts and are passed in
  // rather than hardcoded in the library, so no common module learns a slot
  // id:
  //
  //   stale     - "microphone" is carried by older default layouts but
  //               no registry slot serves it; the stale id is dropped on
  //               every write so an upgraded file heals silently instead
  //               of leaking a dead entry.
  //   alwaysOn  - the workspaces slot carries no toggle upstream
  //               (ensurePermanentSlots), so it is never disableable.
  //   permanent - currently empty; a slot listed there would be both
  //               force-enabled at boot and un-disableable here.
  function _normalizeLayout(raw) {
    return BarLib.normalizeLayout(raw, root.zones,
      id => root._isStandaloneSlot(id), id => root.isOwned(id),
      root._permanent, root._alwaysOnIds, root._staleSlotIds, root._pinned)
  }

  // Heal for the superseded "microphone" slot id: an upgraded file is
  // rewritten once through the normal write path. Idempotent, so both
  // the boot path and the settings-ready path can call it whatever order
  // the stores land in. Bails while Settings is still landing, so a slow
  // file is never healed before it is even read.
  function _migrateStaleSlotsOnce() {
    if (!Settings.ready) return
    const cur = root.storedLayout || {}
    let found = false
    for (const zone of root.zones) {
      const list = cur[zone]
      if (Array.isArray(list) && list.indexOf("microphone") >= 0) { found = true; break }
    }
    if (found) {
      const healed = root._normalizeLayout(cur)
      if (healed !== null) root.setOption("layout", healed)
    }
  }

  // Enable: drop the id from `disabled`, ensuring it holds a zone place
  // (inserted at its default _placeBefore spot when missing). Zones are
  // otherwise untouched, so re-enabling restores the dragged order.
  // Owned dynamic modules are always on: enabling them is a no-op true.
  //
  // The commit result is what the caller acts on, so the function returns
  // the store's own answer rather than the fact that a call was made: an
  // IPC verb and a settings pill that report success on a rejected write
  // tell the user the bar moved when it did not. The function returns
  // without committing when an owned module is always on, a group member
  // has no slot of its own, or an unknown id is not a module.
  function enableModule(id) {
    if (typeof id !== "string" || id === "") return false
    if (root.isOwned(id)) return true
    if (!root._isStandaloneSlot(id)) return false
    if (root.isEnabled(id)) {
      // Still ensure a zone place for files that predate the slot.
      if (BarLib.slotPresent(root.positions, id)) {
        root._gateResolve(id)
        return true
      }
    }
    const zone = root._zones[id]
    if (zone === undefined) return false
    const cur = root.storedLayout
    const zones = {
      left: (cur.left || []).slice(),
      center: (cur.center || []).slice(),
      right: (cur.right || []).slice()
    }
    const found = BarLib.slotPresent(zones, id)
    if (!found) {
      const target = zones[zone]
      if (!target) return false
      BarLib.insertBeforeAnchor(target, root._placeBefore[id], id)
    }
    const disabled = (cur.disabled || []).slice()
    const di = disabled.indexOf(id)
    if (di >= 0) disabled.splice(di, 1)
    const ok = root._commitLayout(zones, disabled)
    if (ok) root._gateResolve(id)
    return ok
  }

  // Disable: append the id to `disabled`, leaving its zone gap in place.
  // Owned dynamic modules carry no toggle, and permanent slots and workspaces
  // are force-enabled at boot: all rejected so IPC callers get an error.
  //
  // `already-off` answers true and the rest answers the commit result, on the
  // same rule as enableModule: an id the user switched off is off whichever
  // way the caller counted it, and a store-rejected write must not read as a
  // pill that flipped.
  function disableModule(id) {
    if (typeof id !== "string" || id === "") return false
    if (root.isOwned(id)) return false
    if (root._permanent[id] !== undefined || id === "workspaces") return false
    if (!root._isStandaloneSlot(id)) return false
    if (!root.isEnabled(id)) return true
    const cur = root.storedLayout
    const disabled = (cur.disabled || []).slice()
    if (disabled.indexOf(id) < 0) disabled.push(id)
    const ok = root._commitLayout({
      left: (cur.left || []).slice(),
      center: (cur.center || []).slice(),
      right: (cur.right || []).slice()
    }, disabled)
    if (ok) root._gateRelease(id)
    return ok
  }

  // The units the bar materializes on demand rather than at boot. Held as data
  // rather than named in a branch so the gate list and the resolvers cannot
  // disagree: _gateResolve and _gateRelease both read it.
  //
  // Membership is a claim about the SERVICE, not about this module: an id here
  // is a service the boot drain skips and only this owner opens, so a service
  // with a consumer outside the bar has no business on the list. A slot that is
  // not gated still resolves normally - _gateResolve answers false and the
  // loader builds the module off _components either way.
  readonly property var _gatedIds: ["archUpdates", "printers"]

  function _isGated(id) {
    return root._gatedIds.indexOf(id) >= 0
  }

  // Apply a drag drop to the persisted zone layout. `ordered` is the zone's
  // reorderable (non-pinned) enabled slot ids in their final, user-chosen
  // order, as produced by the zone's live reorder. Zones (all modules)
  // are rebuilt from it: each reorderable slot is written in the new order
  // while disabled modules stay in the exact gaps they occupied, so their
  // places are preserved across subsequent re-enables. Pinned slots are
  // never part of `ordered` and are pinned back to the end of their zone,
  // so a drag can never displace them. The filtered layout is the drag's
  // index space, not the zones - mapping through ids (not indexes) keeps
  // the write correct when disabled slots are interleaved.
  function moveSlot(region, ordered) {
    const cur = root.positions
    if (!cur || !Array.isArray(cur[region])) return false
    if (!Array.isArray(ordered)) return false
    // The order rebuild is pure (BarLib) and unit-tested; this validates,
    // reads the live registry through the two predicates and commits.
    // Returns false when the drop resolved to the order already persisted,
    // and the commit result otherwise.
    const built = BarLib.rebuildZoneOrder(cur[region], ordered,
      root.layout[region] || [], id => root.isPinned(id), id => root.isFixedSlot(id))
    if (!built.changed) return false
    const next = { left: cur.left.slice(), center: cur.center.slice(), right: cur.right.slice() }
    next[region] = built.list
    return root._commitLayout(next)
  }

  // Commit a cross-zone drop: move `id` from `fromRegion` into `toRegion`
  // at movable position `toIndex` (index into the target's enabled,
  // non-fixed display order, as produced by the drop math over the
  // target's movable slots). Both zones are rewritten in a single commit
  // so the two membership animations (source collapses, target grows)
  // play together; disabled modules keep their gaps and pins re-pin on
  // the write. The position math itself is pure (BarLib) and unit-tested;
  // this only validates and commits. Returns false when rejected.
  function moveSlotAcross(id, fromRegion, toRegion, toIndex) {
    if (typeof id !== "string" || id === "") return false
    if (root.zones.indexOf(fromRegion) < 0 || root.zones.indexOf(toRegion) < 0) return false
    if (fromRegion === toRegion) return false
    const cur = root.positions
    if (!cur || !Array.isArray(cur[fromRegion]) || !Array.isArray(cur[toRegion])) return false
    if (cur[fromRegion].indexOf(id) < 0) return false
    if (!root._isStandaloneSlot(id) && !root.isOwned(id)) return false
    const next = BarLib.crossDropPositions(cur, root.layout[toRegion] || [],
      sid => root.isFixedSlot(sid), id, fromRegion, toRegion, toIndex)
    if (next === null) return false
    return root._commitLayout(next)
  }

  // --- bar position gesture ---
  // Dragging empty bar space previews a top/bottom target; shared, reactive
  // state the per-monitor MoveWindow renders and the gesture drives.
  property bool moveActive: false
  property string moveScreenKey: ""
  property real moveScreenHeight: 0
  property var moveOwner: null
  property string moveCandidate: ""
  property bool movePressed: false

  function pressBar(screen, owner) {
    if (!root.effectiveEnabled || !owner || !screen) return false
    if (!screen.name || screen.width <= 0 || screen.height <= 0) return false
    if (root.movePressed && root.moveOwner !== owner) root.cancelBarMove()
    root.clearBarMove()
    root.movePressed = true
    root.moveScreenKey = String(screen.name)
    root.moveScreenHeight = screen.height
    root.moveOwner = owner
    return true
  }

  function startBarMove(owner) {
    if (root.moveOwner !== owner || !root.movePressed) return false
    if (!root.moveScreenKey || root.moveScreenHeight <= 0 || root.moveActive) return false
    root.moveActive = true
    root.moveCandidate = Bar.position
    return true
  }

  function updateBarMove(owner, screenX, screenY) {
    if (root.moveOwner !== owner || !root.moveActive) return false
    if (root.moveScreenHeight <= 0) return false
    root.moveCandidate = BarLib.positionCandidateHeld(
      screenY, root.moveScreenHeight, root.moveCandidate)
    return true
  }

  function endBarMove(owner) {
    if (root.moveOwner !== owner) return false
    if (!root.moveActive) {
      root.clearBarMove()
      return false
    }
    const target = root.moveCandidate
    const was = Bar.position
    root.clearBarMove()
    // A gesture that ends on the edge the bar already occupies is a real
    // outcome - the user aimed at it, saw the preview and let go - and it
    // commits nothing because there is nowhere to move to.
    if (target && target !== was) root.setOption("position", target)
    return true
  }

  function cancelBarMove(owner) {
    if (owner !== undefined && root.moveOwner !== owner) return false
    root.clearBarMove()
    return true
  }

  function releaseBar(owner) {
    if (root.moveOwner !== owner || root.moveActive) return false
    root.clearBarMove()
    return true
  }

  function clearBarMove() {
    root.moveActive = false
    root.moveScreenKey = ""
    root.moveScreenHeight = 0
    root.moveOwner = null
    root.moveCandidate = ""
    root.movePressed = false
  }

  onEnabledChanged: {
    root.publishDesktopLayout()
    if (!root.effectiveEnabled) root.cancelBarMove()
  }
  onHideToggleChanged: {
    root.publishDesktopLayout()
    if (!root.effectiveEnabled) root.cancelBarMove()
  }
  onEffectiveEnabledChanged: root.publishDesktopLayout()
  onPositionChanged: root.publishDesktopLayout()

  // --- per-module IPC bridge: colorPicker ---
  // The ColorPicker module instantiates once per bar window (per monitor),
  // so it cannot host the IpcHandler itself: a target must be unique and
  // quickshell drops duplicate registrations with a warning. The singleton
  // owns the single handler; the first loaded module instance registers
  // here (registerPicker) and the verbs delegate to it. `pick` starts a
  // native pick on that instance's screen - the keybind surface is
  // `vb-shell colorPicker pick`.
  property Item _pickerOwner: null

  function registerPicker(m) {
    _pickerOwner = m
  }

  function unregisterPicker(m) {
    if (_pickerOwner === m) _pickerOwner = null
  }

  IpcHandler {
    target: "colorPicker"
    function help(command: string): string {
      return UnitIpc.help("colorPicker", "Color Picker", "screen color picker", [
        { name: "pick", help: "start a color pick (result copied to clipboard)" },
      ], command)
    }
    function ping(): string { return "pong" }
    function status(): string {
      return JSON.stringify({
        unit: "colorPicker",
        healthy: root._pickerOwner !== null
      })
    }
    function pick(): string {
      if (root._pickerOwner === null) return "error: no picker module loaded"
      return root._pickerOwner.beginPick() ? "ok" : "error: no screen to pick on"
    }
  }

  // One bar window per real screen, plus a full-screen overlay mirroring
  // the bar-position gesture on its own screen.
  Variants {
    model: root.screens
    delegate: BarShadow {
      required property ShellScreen modelData
      screen: modelData
    }
  }

  Variants {
    model: root.screens
    delegate: BarView {
      required property ShellScreen modelData
      screen: modelData
    }
  }

  Variants {
    model: root.screens
    delegate: MoveWindow {
      required property ShellScreen modelData
      winScreen: modelData
    }
  }

  // A per-screen privacy indicator that is NOT a bar surface: an Overlay
  // layer window that shows the capture dots whenever the bar's own copy
  // is not on screen. Its own visibility is gated on Settings.privacyOverlay
  // rather than on the bar module, so hiding the module does not silently
  // drop the indicator too; it keeps existing while the bar itself is off.
  Variants {
    model: root.screens
    delegate: PrivacyOverlay {
      required property ShellScreen modelData
      winScreen: modelData
    }
  }

  IpcHandler {
    target: "bar"
    function help(command: string): string {
      return UnitIpc.help("bar", "Bar", "top bar layout + modules", [
        { name: "disable", help: "(id) disable a bar module" },
        { name: "dump", help: "enabled module ids in display order" },
        { name: "dumpAll", help: "full bar state dump" },
        { name: "enable", help: "(id) enable a bar module" },
        { name: "hideToggle", help: "toggle the transient bar hide (frees screen space, not persisted)" },
        { name: "set", help: "(key, json) configure the bar (keys: enabled, position, showBorder, showShadow, blurred, layout, hideToggle)" },
        { name: "toggle", help: "toggle the bar itself (hide/show)" },
      ], command)
    }
    function ping(): string { return "pong" }

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        hideToggle: root.hideToggle,
        effectiveEnabled: root.effectiveEnabled,
        position: root.position,
        showBorder: root.showBorder,
        showShadow: root.showShadow,
        blurred: root.blurred,
        height: root.height,
        layout: root.layout,
        storedLayout: root.storedLayout,
        disabled: root.disabledModules,
        positions: root.positions,
        enabledModules: root.enabledModules
      })
    }

    function set(key: string, json: string): string {
      let v
      try {
        v = JSON.parse(json)
      } catch (e) {
        return "error"
      }
      return root.setOption(key, v) ? "ok" : "error"
    }

    function enable(id: string): string {
      return root.enableModule(id) ? "ok" : "error"
    }

    function toggle(): string {
      return root.toggleBar() ? "ok" : "error"
    }

    function hideToggle(): string {
      return root.toggleHide() ? "ok" : "error"
    }

    function disable(id: string): string {
      return root.disableModule(id) ? "ok" : "error"
    }

    function dumpAll(): string {
      return JSON.stringify({
        enabled: root.enabled,
        hideToggle: root.hideToggle,
        effectiveEnabled: root.effectiveEnabled,
        position: root.position,
        showBorder: root.showBorder,
        showShadow: root.showShadow,
        blurred: root.blurred,
        height: root.height,
        layout: root.layout,
        storedLayout: root.storedLayout,
        disabled: root.disabledModules,
        positions: root.positions,
        enabledModules: root.enabledModules,
        modules: Object.keys(root._components),
        owned: Object.keys(root._ownedComps)
      })
    }

    function dump(): string {
      // Enabled module ids in display order (zones left->right).
      return JSON.stringify(root.layout.left.concat(root.layout.center, root.layout.right))
    }
  }
}

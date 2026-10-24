pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type missing-property
import QtQuick
import qs.common
import qs.features.bar
import "BarLib.js" as BarLib
import "../../common/collections/ZoneGeometry.js" as ZoneGeometry

// One bar zone (left / center / right). Renders the zone's slots from a
// single ordered model - layout slots (plain modules and module groups)
// plus owned dynamic indicators - and self-anchors within the padding
// container BarView gives it.
//
// Order follows a simple rule: owned indicators hug the inside edge (away
// from the screen corners), so on the right zone they come before the
// layout slots and on the left/center after. Keeping both populations in
// one ordered model means the static anchor of a right-anchored group
// (e.g. logout) always lands at the corner.
//
// Drag reorder: grab and drag a module (or a whole group) - the gesture is
// a DragHandler, so a plain click still reaches the module while a move
// past a small threshold starts the drag. The drag is interactive: the
// grabbed module detaches at once and rides the cursor (tinted accent),
// and at home the other slots glide to their new positions on the fly as
// the pointer crosses them, running on virtual geometry so mid-glide
// positions never feed back into the target. Drops work across zones too:
// carried over a foreign zone the module keeps riding (its home gap stays
// open behind it); releasing there commits both zones at once, so the
// source collapses shut while the target grows open. Groups occupy
// exactly one slot (dragging one moves every member), and the arrangement
// is written to config once, on release - never during the drag. No drag
// hints are drawn at all: the accent-tinted grabbed module is the only
// indicator. Pinned slots (e.g. the session group) are excluded from
// dragging entirely.
//
// Delegates are membership-stable: the Repeater model is canonically ordered
// and cached, so a pure reorder - or any unrelated settings write - never
// recreates a module. Slots are positioned by x (no Row); module state
// (tray slide, clock roll, open islands) survives reorders and config
// commits untouched.
Item {
  id: root

  property string region: "left"
  // The per-monitor bar window, which wires each instantiated module.
  property var hostWindow: null

  // The zone's persisted slot order, mixed: static modules, groups and
  // owned dynamic modules interleaved exactly as the user left them.
  readonly property var zoneLayout: Bar.layout[root.region] || []

  // The zone's movable slot ids for a drag: every layout slot except fixed
  // obstacles. Pinned slots are a wall at the end of their zone;
  // non-draggable owned modules are walls in place. Neither ever enters
  // the working order, so nothing can be dropped onto or past them.
  function movableIds() {
    const out = []
    const zl = root.zoneLayout
    for (let i = 0; i < zl.length; i++)
      if (!Bar.isFixedSlot(zl[i])) out.push(zl[i])
    return out
  }

  // Which population a slot id belongs to: an owned dynamic module or a
  // layout slot. The mixed model publishes this per entry and the row keys
  // its rows by the pair, so a kind flip is a distinct row for the same id.
  function _kindOf(id) {
    return Bar.isOwned(id) ? "owned" : "static"
  }

  // Visual order. Resting: the persisted mixed layout as-is. Dragging: the
  // fixed obstacles keep their persisted places while the movable ids
  // stream from the live working order - the same interleave the commit
  // writes back, so nothing visually jumps on release. Retained departures
  // (`leaving`) splice back at their cached display index so the row
  // shrinks in place around them.
  readonly property var displayOrder: {
    const out = []
    const ordered = root.workList !== null
      ? root.workList : root.zoneLayout
    let wi = 0
    const zl = root.zoneLayout
    for (let i = 0; i < zl.length; i++) {
      const id = zl[i]
      let disp
      if (root.workList !== null && !Bar.isFixedSlot(id)) {
        disp = wi < ordered.length ? ordered[wi++] : id
      } else {
        disp = id
      }
      out.push({ kind: root._kindOf(disp), id: disp })
    }
    const spots = root._leavingSorted()
    for (let s = 0; s < spots.length; s++)
      out.splice(Math.min(spots[s].at, out.length), 0,
        { kind: spots[s].kind, id: spots[s].id })
    return out
  }

  // A drag is live on this window - own or sibling zone. Scanned, not
  // shared state: the commit still writes once on release, this only
  // lights the empty-zone hint below.
  readonly property bool anyDragActive: {
    if (root.dragActive) return true
    if (!root.parent) return false
    const kids = root.parent.children
    for (let i = 0; i < kids.length; i++) {
      const z = kids[i]
      if (z !== root && z.dragActive === true) return true
    }
    return false
  }
  // An effectively emptied zone is an invisible target (idle dynamic
  // modules occupy slots with zero width); while any drag is live it
  // shows where a drop lands. Pure visual - layout math reads
  // displayOrder only, so this never moves anything.
  readonly property bool showDropHint: root.contentWidth < 1 && root.anyDragActive
  // Repeater model: one entry per slot, canonically ordered (sorted static
  // ids + owned ids) and cached by signature. A pure reorder commit - or any
  // unrelated settings rev bump - hands the Repeater the exact same array,
  // so no delegate is ever recreated and module state survives untouched.
  // Delegates are positioned by displayOrder instead.
  property string _memberSig: ""
  property var memberModel: []

  // Rebuild memberModel only when the mixed membership signature changes;
  // the cached array instance is reused so Repeater delegates are
  // membership-stable (module state survives reorders). Imperative, not a
  // binding: a binding that wrote _memberSig while reading it back is a
  // binding loop, and Qt answers one by dropping the expression. The sorted
  // signature keeps a pure reorder from touching membership.
  //
  // Membership animation (Settings toggles) works mic-style, driven by the
  // toggled slot's own width: a membership change hands the Repeater a
  // different array, so a departing delegate is destroyed and recreated
  // and cannot glide from persisted state (an identical-content swap is a
  // no-op - 0 delegates created, 0 destroyed). Instead the entering slot
  // grows 0->full
  // in place (content pinned right, clipped: neighbors part around it
  // while the glyph holds still, exactly like the mic/power-profile
  // indicators) and the departing slot is retained shrinking full->0; the
  // zone width, slot x and center-anchor offset all track those live
  // widths frame by frame - no easing layer on top, so nothing drifts as
  // a block. The fade runs INSIDE the same window (creation-armed, never
  // membership-bound), so there is no gap-then-fade sequence. Drags and
  // continuous width changes (mic/tray) are untouched: drag keeps its own
  // workList-gated x glide, live widths track directly.
  //
  // Ids added by the last animated toggle (simultaneous fade + grow).
  property var enteringIds: []
  // Departing ids stay here (id -> {kind, at}) with a shrinking width
  // until the cleanup timer drops them, so removal slides shut instead
  // of popping.
  property var leaving: ({})
  // Cold-boot grace: the first Settings sync enables always-on slots
  // (workspaces) right after first paint - animating that churn
  // would slide every zone on every boot, so membership motion stays off
  // until the session settles.
  property bool bootSettled: false
  Timer {
    interval: 2000
    running: true
    repeat: false
    onTriggered: root.bootSettled = true
  }
  Timer {
    id: animTimer
    interval: Ui.slowMs + 120
    repeat: false
    onTriggered: root._dropLeaving()
  }
  // Forget finished departures (and stale entrances): recompute the model
  // from the live layout, which no longer contains them.
  function _dropLeaving() {
    root.leaving = {}
    root.enteringIds = []
    root.memberModel = root._modelFromIds(root.zoneLayout.slice().sort())
  }
  // The mixed model for an ordered id array: one { kind, id } entry per id.
  function _modelFromIds(ids) {
    const out = []
    for (let i = 0; i < ids.length; i++)
      out.push({ kind: root._kindOf(ids[i]), id: ids[i] })
    return out
  }
  function rebuildMemberModel() {
    const ids = root.zoneLayout.slice().sort()
    const sig = "m:" + ids.join(",")
    if (sig === root._memberSig) return
    const first = root._memberSig === ""
    root._memberSig = sig
    // Animated toggles only past boot grace, outside drags, with motion
    // on: otherwise (boot sync, drag commits, killswitch) the model swaps
    // silently. Added ids fade + grow; removed ids are retained shrinking
    // in `leaving` until animTimer drops them.
    const animate = !first && !root.dragActive && root.bootSettled
      && MotionPolicy.enabled
    const prev = {}
    for (let p = 0; p < root.memberModel.length; p++)
      prev[ZoneGeometry.slotKey(root.memberModel[p].kind, root.memberModel[p].id)] = true
    let added = []
    const kept = {}
    for (let a = 0; a < ids.length; a++) {
      const key = ZoneGeometry.slotKey(root._kindOf(ids[a]), ids[a])
      kept[key] = true
      if (animate && !prev[key]) added.push(ids[a])
    }
    if (animate) {
      // Retain departures with their display position: snapshot the live
      // display order BEFORE the swap (delegates still exist this tick).
      const disp = root.displayOrder
      const atOf = {}
      for (let d = 0; d < disp.length; d++)
        atOf[ZoneGeometry.slotKey(disp[d].kind, disp[d].id)] = d
      const next = {}
      for (let p = 0; p < root.memberModel.length; p++) {
        const e = root.memberModel[p]
        const key = ZoneGeometry.slotKey(e.kind, e.id)
        if (!kept[key] && atOf[key] !== undefined)
          next[e.id] = { kind: e.kind, at: atOf[key] }
      }
      root.leaving = next
      root.enteringIds = added
      if (added.length > 0 || Object.keys(next).length > 0) animTimer.restart()
    } else {
      root.leaving = {}
      root.enteringIds = []
    }
    root.memberModel = root._modelFromIds(ids).concat(root._leavingEntries())
  }

  // Retained departures as one array, ascending by the display index each
  // departure was cached with.
  function _leavingSorted() {
    const spots = []
    for (const id in root.leaving) {
      const l = root.leaving[id]
      if (l) spots.push({ kind: l.kind, id: id, at: l.at })
    }
    spots.sort((a, b) => a.at - b.at)
    return spots
  }
  // Model entries for retained departures, spliced back at their cached
  // display index so the row shrinks in place. The index is displayOrder's
  // concern, so only the pair reaches the model.
  function _leavingEntries() {
    return root._leavingSorted().map(e => ({ kind: e.kind, id: e.id }))
  }

  // Slot width-factor endpoints. Creation value: entering slots start
  // collapsed (grow animates them open); everything else starts full.
  // With motion off the answer is always full - no invisible dwell while
  // the cleanup timer runs out.
  function _initialGrow(id) {
    if (!MotionPolicy.enabled) return 1
    if (root.leaving[id] !== undefined) return 1
    return root.enteringIds.indexOf(id) >= 0 ? 0 : 1
  }
  // Settled value: departures collapse, everything else opens.
  function _targetGrow(id) {
    if (!MotionPolicy.enabled) return 1
    return root.leaving[id] !== undefined ? 0 : 1
  }

  // --- row geometry snapshot ---
  //
  // One copy of the row's numeric geometry per zone: the ordered ids and
  // kinds, the ordered widths, the prefix x positions and the id -> row
  // index. It exists so a layout read is an index into a copy instead of a
  // scan of the Repeater: contentWidth, pivotKey, pivotX and every
  // delegate's x resolve through one number each, where a scan of the
  // delegates per slot makes a single width change re-evaluate the row.
  //
  // The copy is rebuilt from the delegates at ONE extraction point
  // (refreshGeometry) and only when the invalidation signature actually
  // moves - ordered membership, a width, a grow factor or the drag
  // snapshot's revision. It is a copy, never a live view into the
  // Repeater, so a per-frame delegate width change reads it back
  // unchanged instead of re-entering the rebuild.
  property var geoSnapshot: null
  property string _geoSig: ""
  // The drag geometry's own revision: the frozen static widths are part of
  // the row, so recording or releasing them invalidates it.
  property int dragGeometryRevision: 0

  // Single extraction point: ONE linear pass over the delegates collects
  // their live widths and grow factors, keyed by row key, so a width
  // change is caught by the same pass that fills the copy. A static slot
  // mid-drag takes the frozen drag width instead, so a module animating
  // under the cursor cannot shift the working arrangement; owned
  // indicators have no frozen row and read their live width. A row whose
  // delegate is not instantiated reads 0, the answer an unresolved slot gives.
  // True when the copy changed.
  function refreshGeometry() {
    const order = root.displayOrder
    const n = order.length
    const ids = new Array(n)
    const kinds = new Array(n)
    const widths = {}
    const grows = {}
    for (let i = 0; i < n; i++) {
      const e = order[i]
      ids[i] = e.id
      kinds[i] = e.kind
      const k = ZoneGeometry.slotKey(e.kind, e.id)
      widths[k] = 0
      grows[k] = 1
    }
    const frozen = root.slotWidths
    const items = root._slotItems()
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      const k = ZoneGeometry.slotKey(it.modelData.kind, it.modelData.id)
      if (widths[k] === undefined) continue
      grows[k] = it.grow
      widths[k] = it.modelData.kind === "static" && frozen !== null
        && frozen[it.modelData.id] !== undefined
        ? frozen[it.modelData.id] : it.width
    }
    const rev = root.dragGeometryRevision
    const sig = ZoneGeometry.invalidationSig(ids, kinds, widths, grows, rev)
    if (sig === root._geoSig) return false
    root._geoSig = sig
    const row = ZoneGeometry.orderedWidths(ids, kinds, widths)
    root.geoSnapshot = {
      ids: ids,
      kinds: kinds,
      widths: row,
      prefix: ZoneGeometry.prefixX(row),
      rowOf: ZoneGeometry.rowIndexMap(ids),
      total: ZoneGeometry.totalWidth(row)
    }
    return true
  }

  // Every live delegate, in row order. A full scan, for the callers that
  // want all of them. Quickshell's Repeater carries itemAt(), a plain Qt
  // Repeater only objectAt(), so the accessor is picked per call.
  function _slotItems() {
    const out = []
    for (let i = 0; i < slotRep.count; i++) {
      const it = slotRep.itemAt ? slotRep.itemAt(i) : slotRep.objectAt(i)
      if (it) out.push(it)
    }
    return out
  }

  // A delegate's width is the one geometry input no binding can derive, so
  // every slot reports its own and the row copy is rebuilt from those
  // reports - synchronously, inside the width handler.
  //
  // Deferring that rebuild to the next event-loop turn coalesces several
  // slots reporting on the same frame into one O(n) extraction, and it is
  // still wrong: `Slot.width` is a live binding while `Slot.x` resolves
  // against this copy, so a deferred pass leaves every slot's width one
  // frame ahead of the x that places it for the whole animation and snaps
  // on the final pass. The centre zone's `anchors.horizontalCenterOffset`
  // reads the same copy through `pivotX`, so it trails identically. The
  // cost is one extraction per reporting slot per frame; the row is exact
  // within every frame instead.
  function _scheduleGeometryRefresh() {
    root.refreshGeometry()
  }

  // The row's identity changed (order, membership, a retained departure):
  // rebuild the copy the new row needs.
  onDisplayOrderChanged: root.refreshGeometry()
  // The frozen drag widths changed: a new revision, then a rebuild.
  onSlotWidthsChanged: {
    root.dragGeometryRevision++
    root.refreshGeometry()
  }

  // Width of a slot for layout math, read from the row snapshot. During a
  // drag the static widths come from the geometry snapshot
  // (recordStaticGeometry) so a module whose width animates mid-drag (the
  // tray sliding open, for instance) cannot shift the working arrangement
  // - only the dragged item's own, frozen width drives the layout. Owned
  // indicators have no frozen row and read their live captured width. A row
  // is identified by its id and the caller supplies the kind with the row,
  // so the two never diverge and one row index answers for both.
  function widthFor(kind, id) {
    if (kind === "static" && root.slotWidths !== null && root.slotWidths[id] !== undefined)
      return root.slotWidths[id]
    const snap = root.geoSnapshot
    if (snap === null) return 0
    const row = snap.rowOf[id]
    return row === undefined ? 0 : snap.widths[row]
  }

  // Resting x of a slot in the zone row: one prefix read over the row
  // snapshot, which is the cumulative width of everything displayed before
  // it (never their x, so the result is deterministic even while slots are
  // mid-glide). An id the row does not hold answers with the row's total,
  // the one x past the last row.
  function xForSlot(kind, id) {
    const snap = root.geoSnapshot
    if (snap === null) return 0
    const row = snap.rowOf[id]
    return snap.prefix[row === undefined ? snap.widths.length : row]
  }

  // The zone hugs its content and sits vertically centered on one horizontal
  // edge: left at the start, right at the end, center fixed on the middle
  // (fixed-center anchoring: the center row's own middle lands on screen
  // center no matter how wide the side zones grow; on a crowded bar the
  // zones may overlap, with the center row painting on top). Only one
  // horizontal anchor is ever set (assigned at runtime so the analyzer never
  // sees an illegal left+right+center combination).
  readonly property real contentWidth: root.geoSnapshot !== null
    ? root.geoSnapshot.total : 0
  width: root.contentWidth
  height: Bar.height
  // Dead-center pivot: the slot nearest the zone's own middle (ties
  // go left - strict `<` keeps the first). The offset below parks
  // this slot's center on screen center, so siblings spawning either
  // side grow outward without moving it. Order comes from zoneLayout
  // (frozen during drags, so the pivot cannot hop mid-gesture);
  // widths stay live (spawn/shrink glides track frame by frame).
  // ZoneGeometry.slotKey of the pivot, "" when the zone is empty.
  readonly property string pivotKey: {
    const ids = root.zoneLayout
    const snap = root.geoSnapshot
    let best = ""
    let bestDist = Infinity
    let bx = 0
    // Row measures come off the snapshot, not through widthFor: a binding
    // that calls back into the zone's own methods re-enters itself while
    // the membership notification that publishes the snapshot is still
    // running. An id the row does not hold measures 0.
    const total = snap !== null ? snap.total : 0
    for (let i = 0; i < ids.length; i++) {
      const row = snap !== null ? snap.rowOf[ids[i]] : undefined
      const w = row === undefined ? 0 : snap.widths[row]
      const c = Math.abs((bx + w / 2) - total / 2)
      if (c < bestDist) {
        bestDist = c
        best = ZoneGeometry.slotKey(root._kindOf(ids[i]), ids[i])
      }
      bx += w
    }
    return best
  }
  // Pivot center in zone coords; falls back to the zone middle when
  // the pivot delegate is not instantiated yet.
  readonly property real pivotX: {
    const order = root.displayOrder
    for (let i = 0; i < order.length; i++) {
      if (ZoneGeometry.slotKey(order[i].kind, order[i].id) !== root.pivotKey)
        continue
      return root.xForSlot(order[i].kind, order[i].id)
        + root.widthFor(order[i].kind, order[i].id) / 2
    }
    const snap = root.geoSnapshot
    return (snap !== null ? snap.total : 0) / 2
  }
  anchors.horizontalCenterOffset: root.region === "center"
    ? Math.round(root.contentWidth / 2 - root.pivotX) : 0
  anchors.verticalCenter: parent.verticalCenter
  // Paint order: the fixed-center row sits above the side zones so it
  // stays readable on a crowded bar; a zone with a live drag rises above
  // everything so the carried module never slides under any drop target.
  z: root.dragActive ? 2 : (root.region === "center" ? 1 : 0)

  function applyAnchoring() {
    root.anchors.left = undefined
    root.anchors.right = undefined
    root.anchors.horizontalCenter = undefined
    if (!root.parent) return
    if (root.region === "left") root.anchors.left = root.parent.left
    else if (root.region === "right") root.anchors.right = root.parent.right
    else root.anchors.horizontalCenter = root.parent.horizontalCenter
  }
  onRegionChanged: root.applyAnchoring()
  Component.onCompleted: {
    root.applyAnchoring()
    root.rebuildMemberModel()
    // Seed the row copy before the first polish: the layout bindings read
    // it, and each delegate's birth rebuilds it anyway.
    root.refreshGeometry()
  }

  // --- drag state (one drag at a time per zone) ---

  property bool dragActive: false
  // The dragged slot's position in the ORIGINAL static layout; the commit
  // maps it to its final position in workList.
  property int dragFrom: -1
  // Live visual order of the zone's static slot ids while a drag runs (and
  // through the commit handoff). Reorders move slots by x via displayOrder;
  // the order is written to config once, on release.
  property var workList: null
  // The dragged slot id and its current position in workList.
  property string dragId: ""
  property int dragPos: -1
  // Cross-zone carry: region under the pointer while carrying ("" over
  // empty bar space or back home). Any zone accepts the drop, with no
  // foreign-zone lockout.
  property string overZone: ""
  // The zone item under the pointer + the pointer's local x inside it,
  // for the cross-zone drop math on release.
  property Item overZoneItem: null
  property real overZoneX: 0
  // Pointer x in this zone's coordinates (refreshed by the drag poll) and
  // the grab offset the carried slot keeps while riding the cursor.
  property real carryX: 0
  property real carryGrabDX: -1
  // Static slot widths and the row x where the static block starts,
  // snapshotted at drag start: the drop math runs on this stable virtual
  // geometry, so mid-glide positions cannot feed back into the target.
  property var slotWidths: null
  property var activeDragHandler: null
  property Item activeSlotItem: null
  // The protected (pinned) slot currently under the drag cursor, or "".
  // Pinned slots can't be reordered, so hovering one mid-drag highlights
  // it (a red wrap) to make the "you can't drop here" boundary visible
  // right on the protected area itself.
  property string protectedHoverId: ""
  // The session group (and any pinned slot) is fully inert during a drag:
  // it is never part of the working order, so no module can be dropped onto
  // or past it, and it never reacts to the drag at all.

  // Reflect the zone's drag into the host window so modules sharing the bar
  // (e.g. the session group) can freeze their hover effects while a reorder
  // runs. Counted per window in case a drag ever spans zones.
  onDragActiveChanged: {
    if (!root.hostWindow) return
    if (root.dragActive) root.hostWindow.enterSlotDrag()
    else root.hostWindow.leaveSlotDrag()
  }

  // Snapshot the static slot widths and the static block's row origin, so
  // the drop math can run on stable virtual geometry while the real slots
  // are mid-glide.
  function recordStaticGeometry() {
    const widths = {}
    const items = root._slotItems()
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it.modelData.kind !== "static") continue
      widths[it.modelData.id] = it.width
    }
    root.slotWidths = widths
  }

  // The slot whose DragHandler is `handler`. A search, not the full scan
  // _slotItems makes: the walk stops on the match, so the cost is one
  // comparison per delegate up to the hit and nothing is collected.
  function _slotForDragSource(handler) {
    for (let i = 0; i < slotRep.count; i++) {
      const it = slotRep.itemAt ? slotRep.itemAt(i) : slotRep.objectAt(i)
      if (it && it.dragSource === handler) return it
    }
    return null
  }

  // Same-zone slots as [{ x, width, index }] in row coords, taken straight
  // from the row snapshot. Fixed obstacles (pinned / non-draggable owned)
  // advance the virtual row without offering a drop gap; movable ids are
  // candidates at their live workList index.
  function virtualSlotsInfo() {
    const snap = root.geoSnapshot
    if (snap === null) return []
    return ZoneGeometry.dropCandidates(snap.ids, snap.widths, snap.prefix,
      root.workList, id => Bar.isFixedSlot(id))
  }

  // Begin a drag from the slot that owns `handler`. `handler` is that slot's
  // DragHandler (already active, past its threshold).
  function startSlotDrag(handler) {
    if (root.dragActive || !handler || !handler.active) return
    // Match the handler to its slot in the repeater.
    const slotItem = root._slotForDragSource(handler)
    if (!slotItem) return
    // The original position of the dragged slot in the movable working
    // order, resolved by id (the delegate persists across reorders, so it
    // carries no index of its own). Fixed obstacles are excluded, so a
    // pinned or non-draggable id can never be a dragFrom.
    const from = root.movableIds().indexOf(slotItem.modelData.id)
    if (from < 0) return
    // A glide-home from a cancelled carry may still be pending: stop it so
    // it cannot release this drag's working order mid-gesture.
    homeTimer.stop()
    // Seed the carry target BEFORE flipping carried on (below): the x
    // binding must never evaluate with a stale carryX (initial 0 or a
    // leftover from an earlier gesture), or the module snaps to garbage and
    // the correcting poll locks the offset in. Press point in zone
    // coordinates, from the scene position, so the seed and every poll
    // resolve the pointer the same way - see refreshDrag on why the mapping
    // must not go through the slot.
    const seedScene = handler.centroid.scenePosition
    root.carryX = root.mapFromGlobal(seedScene.x, seedScene.y).x
    // Grab offset (slot-local press point) so the carried module stays
    // under the cursor from the very first poll instead of jumping. This one
    // IS slot-local on purpose: it is the offset within the module that was
    // grabbed, and carryX carries the same press point in zone coordinates.
    root.carryGrabDX = handler.centroid.position.x
    root.dragActive = true
    root.dragId = slotItem.modelData.id
    root.dragFrom = from
    root.dragPos = from
    root.workList = root.movableIds()
    root.recordStaticGeometry()
    root.activeDragHandler = handler
    root.activeSlotItem = slotItem
    // Force-ingest the press centroid; the Connections below takes over from
    // the first real movement.
    root._lastCX = -1
    root._lastCY = -1
    root.refreshDrag()
  }

  // Last ingested raw centroid, in SCENE coordinates. This is the motion
  // gate for the carry: a held-still pointer yields an unchanging scene
  // position, so the target freezes and the module settles where it was
  // left. It reads the scene position rather than the handler's slot-local
  // one precisely because a slot-local centroid keeps changing while the
  // slot eases, which is what made a still pointer look like motion - see
  // refreshDrag. The Connections below only fires on real movement, so this
  // is this belt-and-braces for that path and load-bearing for the direct
  // call startSlotDrag makes to ingest the press point.
  property real _lastCX: -1
  property real _lastCY: -1

  function refreshDrag() {
    if (!root.dragActive || !root.activeDragHandler || !root.activeSlotItem) return
    // The carry target is read in SCENE coordinates and mapped through the
    // zone, never through the slot. `centroid.position` is local to the
    // handler's parent - the carried slot - and that slot's x is being eased
    // by the `Behavior on x` below, so a slot-local read feeds the slot's own
    // animated position back into its target: the two drift apart, the
    // apparent pointer motion never stops, and a cursor held still outside the
    // bar walks the module off the screen at a steady rate. Scene position is
    // the pointer, so a still cursor is a frozen centroid here.
    const sp = root.activeDragHandler.centroid.scenePosition
    if (root._lastCX >= 0 && sp.x === root._lastCX && sp.y === root._lastCY) return
    root._lastCX = sp.x
    root._lastCY = sp.y
    const loc = root.mapFromGlobal(sp.x, sp.y)
    root.carryX = loc.x
    root.updateOverZone(loc)
    root.updateProtectedHover(loc.x)
    // The working order only tracks the pointer while it is home; carried
    // elsewhere the arrangement freezes and the drop math runs on release.
    if (root.overZone === root.region) root.updateDrag(loc.x)
  }

  // Track which protected (pinned) slot the drag pointer currently covers
  // (by x in zone coordinates), so the Slot can wrap that protected area in
  // a red box. Pinned slots sit at the end of the zone and never move, so
  // their live position is stable and x-containment is enough.
  function updateProtectedHover(locX) {
    let hovered = ""
    const order = root.displayOrder
    for (let i = 0; i < order.length; i++) {
      const e = order[i]
      if (e.kind !== "static" || !Bar.isPinned(e.id)) continue
      const px = root.xForSlot(e.kind, e.id)
      const pw = root.widthFor(e.kind, e.id)
      if (locX >= px && locX <= px + pw) {
        hovered = e.id
        break
      }
    }
    if (root.protectedHoverId !== hovered) root.protectedHoverId = hovered
  }

  // Hit-test the drag pointer against this zone and its siblings (all
  // zones share this zone's parent container, each exposing a `region`).
  // Records the zone, its item and the pointer's local x inside it: home
  // keeps the same-zone reorder running, a foreign zone arms the carry,
  // "" over empty bar space freezes everything until release. Home first
  // so a drag staying over its own area never flickers; center wins
  // sibling overlaps (fixed-center paints it on top).
  //
  // Narrow zones (down to fully empty ones, width 0) get a minimum hit
  // width around their middle - otherwise an emptied zone is a zero-width
  // target the pointer can never sit over and nothing can be dragged
  // back into it.
  readonly property real dropHitW: 48
  function hitContains(zone, px) {
    const hw = Math.max(zone.width, root.dropHitW) / 2
    const cx = zone.x + zone.width / 2
    return px >= cx - hw && px <= cx + hw
  }
  function updateOverZone(loc) {
    root.overZone = ""
    root.overZoneItem = null
    if (!root.dragActive || !root.activeSlotItem || !root.parent) return
    const p = root.mapToItem(root.parent, loc.x, loc.y)
    if (root.hitContains(root, p.x)) {
      root.overZone = root.region
      root.overZoneItem = root
      root.overZoneX = loc.x
      return
    }
    const kids = root.parent.children
    const order = ["center", "left", "right"]
    for (let o = 0; o < order.length; o++) {
      for (let i = 0; i < kids.length; i++) {
        const z = kids[i]
        if (z === root || z.region === undefined || z.region !== order[o]) continue
        if (root.hitContains(z, p.x)) {
          root.overZone = z.region
          root.overZoneItem = z
          const lp = z.mapFromItem(root.parent, p.x, p.y)
          root.overZoneX = lp.x
          return
        }
      }
    }
  }

  // Interactive reorder: the freed gap chases the pointer - every time the
  // pointer crosses a slot's midpoint the working order reorders and the
  // slots glide to their new positions. Runs on virtual geometry so
  // mid-glide positions cannot feed back into the target.
  function updateDrag(x) {
    if (!root.dragActive || root.workList === null) return
    const target = BarLib.dropTarget(root.virtualSlotsInfo(), root.dragPos, x)
    if (target.to !== root.dragPos) {
      const was = root.dragPos
      const next = BarLib.reorder(root.workList, root.dragPos, target.to)
      if (next !== root.workList) root.workList = next
      root.dragPos = target.to
    }
  }

  // Apply the live arrangement to the config - exactly one write on
  // release; the drag itself never touches it.
  function commitDrag() {
    if (!root.dragActive) return
    const dz = root.overZone
    // Released over a foreign zone: hand off to the cross-zone commit.
    if (dz !== "" && dz !== root.region) {
      root.commitCrossDrag(dz)
      return
    }
    // Home release (or over empty space): write when moved. Accepted
    // write: zoneLayout is already current (the commit propagates
    // synchronously through Settings.values -> Bar.layout), so there is
    // no flash-back window. Rejected write: falls back to the persisted
    // layout. Either way the working order's job is done once moveSlot
    // returns.
    if (dz !== "" && root.workList !== null && root.dragId !== ""
      && root.workList.indexOf(root.dragId) !== root.dragFrom) {
      Bar.moveSlot(root.region, root.workList)
    }
    // Drop the carry NOW so the module eases into its gap (or home) while
    // the working order is still live; the order itself releases once the
    // glide lands (identical values, so the release moves nothing).
    root.clearDrag(true)
    homeTimer.restart()
  }

  // Commit a cross-zone drop into `dz`: insert the carried id into the
  // target zone's movable order at the pointer, then write both zones in
  // one commit so the source collapses shut while the target grows open.
  // Drag state goes down BEFORE the write so the membership swap animates
  // (rebuilds skip motion mid-drag) and the carried delegate dies with the
  // swap instead of snapping home for a frame. Synchronous - no frame
  // paints between the state flips.
  function commitCrossDrag(dz) {
    const id = root.dragId
    const from = root.region
    const t = root.overZoneItem
    let idx = -1
    if (t && id !== "") {
      // Target movable slots (display order, fixed obstacles and
      // mid-collapse leavers excluded) with live geometry for the
      // gap-nearest-edge rule.
      const slots = []
      const order = t.displayOrder
      for (let i = 0; i < order.length; i++) {
        const e = order[i]
        if (Bar.isFixedSlot(e.id)) continue
        if (t.leaving && t.leaving[e.id] !== undefined) continue
        slots.push({ x: t.xForSlot(e.kind, e.id), width: t.widthFor(e.kind, e.id) })
      }
      idx = Math.max(0, Math.min(BarLib.dropTarget(slots, slots.length, root.overZoneX).to, slots.length))
    }
    root.releaseWorkList()
    root.clearDrag()
    // The target index is -1 when the pointer was not over a resolvable gap,
    // which is a rejected drop rather than a drop at position 0.
    if (idx >= 0) Bar.moveSlotAcross(id, from, dz, idx)
  }

  function clearDrag(keepOrder) {
    root.dragActive = false
    root.dragFrom = -1
    root.dragPos = -1
    root.dragId = ""
    root.overZone = ""
    root.overZoneItem = null
    root.carryGrabDX = -1
    root.protectedHoverId = ""
    root.activeDragHandler = null
    root.activeSlotItem = null
    // The working order (with its geometry snapshot) is released in
    // commitDrag right after moveSlot returns: the settings commit
    // propagates synchronously, so zoneLayout already matches workList and
    // there is no flash-back window for a deferred release to paper over.
    // onZoneLayoutChanged stays as a backstop in case a future settings
    // write path ever becomes async. See releaseWorkList().
    // Defense in depth: if workList is somehow still live and zoneLayout
    // already reflects it, drop it here rather than waiting on the signal -
    // unless the caller keeps it alive for a release glide (homeTimer).
    if (!keepOrder && root.workList !== null && root.zoneLayoutMatchesWorkList()) root.releaseWorkList()
  }

  // True when the persisted layout already reflects the live working order:
  // the movable sequence of zoneLayout (fixed obstacles skipped) equals
  // workList. Releasing in that state is a no-op visually, so clearDrag may
  // do it safely as defense in depth.
  function zoneLayoutMatchesWorkList() {
    if (!Array.isArray(root.workList)) return false
    let oi = 0
    const zl = root.zoneLayout
    for (let i = 0; i < zl.length; i++) {
      if (Bar.isFixedSlot(zl[i])) continue
      if (root.workList[oi] !== zl[i]) return false
      oi++
    }
    return oi === root.workList.length
  }

  // Drop the working order and its geometry snapshot, handing layout back
  // to zoneLayout. Called from commitDrag right after the write lands (or
  // a drag is cancelled) - the commit propagates synchronously, so
  // zoneLayout already matches and nothing visually changes - and as a
  // backstop from onZoneLayoutChanged / clearDrag.
  function releaseWorkList() {
    root.workList = null
    root.slotWidths = null
  }

  // Backstop only: commitDrag releases the working order right after the
  // write (the commit propagates synchronously through Settings.values ->
  // Bar.layout), so this normally never fires with workList live. Kept in
  // case a future settings write path ever becomes async - then it drops
  // the working order once zoneLayout catches up (identical arrangement,
  // so nothing visually changes - only the source of truth flips back).
  onZoneLayoutChanged: {
    root.rebuildMemberModel()
    // Backstop only: commitDrag releases the working order right after the
    // write (the commit propagates synchronously through Settings.values ->
    // Bar.layout), so this normally never fires with workList live. Kept in
    // case a future settings write path ever becomes async - then it drops
    // the working order once zoneLayout catches up.
    if (!root.dragActive && root.workList !== null) root.releaseWorkList()
  }

  // Keep the live reorder current as the pointer moves. DragHandler does
  // expose the centroid's change as a real signal - QQuickMultiPointHandler
  // declares `centroid` as NOTIFY centroidChanged, emitted per pointer event -
  // so this is event-driven rather than sampled: a polled centroid would wake
  // three zones on every output for the whole gesture to learn what a signal
  // says for free. Targeting root.activeDragHandler rather than a delegate's own
  // handler is what makes this safe: the zone outlives any one slot's
  // delegate, and the target re-resolves when the next drag starts.
  Connections {
    target: root.activeDragHandler
    enabled: root.dragActive && root.activeDragHandler !== null
    function onCentroidChanged() {
      root.refreshDrag()
    }
  }

  // Release tail for every home release: the carry already dropped (the
  // module eases into its gap on the still-live working order), this only
  // lets go of the order once the glide lands. Stopped by any fresh drag
  // start so it cannot release a new gesture's order.
  Timer {
    id: homeTimer

    interval: Ui.expandMs + 20
    repeat: false
    onTriggered: {
      root.releaseWorkList()
      root.clearDrag()
    }
  }

  // --- slots ---

  // Resolve a layout slot id to its Component and open its construction
  // clock. This is the expression the slot's Loader binds `sourceComponent`
  // to, so the stamp is taken in the same synchronous turn that hands the
  // Component over - the tightest opener a Loader offers. `Loader.status` is
  // not usable as one: for a synchronous source Qt writes Loading straight
  // into the Loader's private state and emits no signal for it, so the only
  // transition a caller can observe is the jump to Ready. Group keys resolve
  // to the group container and are not timed here; Group.qml times the
  // members instead. The construction records markBuildStart keeps are
  // mutated in place, never reassigned: a reassignment is a property write
  // from inside the binding this call runs under, and Qt answers that by
  // dropping the binding.
  function resolveSlot(id) {
    const comp = Bar.componentFor(id)
    if (!Bar.isGroup(id) && comp !== null && comp !== undefined) {
      Bar.markBuildStart(id, comp)
    }
    return comp
  }

  component Slot: Item {
    id: slot

    required property var modelData
    // Layout slots are draggable unless fixed: pinned slots (e.g. the
    // session group) and non-draggable owned modules stay put while
    // remaining fully toggleable upstream (static case).
    readonly property bool draggable: !Bar.isFixedSlot(slot.modelData.id)
    // The dragged slot is "lifted": it rides the cursor wearing the held
    // wrap below, and the freed gap is wherever its geometry isn't
    // currently covering.
    readonly property bool lifted: root.dragActive && slot.modelData.id === root.dragId
    // The drag cursor sits on this slot's protected area: a pinned slot is
    // never a drop target, so the slot's own box marks it off limits right
    // where the cursor is.
    readonly property bool offLimits: root.dragActive
      && root.protectedHoverId === slot.modelData.id
    // Exposes the child DragHandler so the zone can match a slot by handler.
    property alias dragSource: dragHandler

    // Resting position in the zone row: follows the live display order, so
    // a reorder moves the slot itself. The Behavior is scoped to the
    // working order: reorders glide while workList is set; once it is
    // released (commitDrag, right after the write - zoneLayout already
    // matches), position changes are instant and coincide with the
    // persisted order - the visual position never jumps. Membership
    // motion needs no x easing and no edge compensation: the toggled
    // slot's own width (grow below) is what parts its neighbors, and
    // every x binding tracks it live, mic-style. Slots always tile
    // exactly (each x sums the rounded widths before it), so a growing
    // module never overlaps - or slides under - its neighbors; clip
    // keeps the emerging content inside the slot while the glyph holds
    // still at its final spot.
    clip: true
    // Carry: from drag start the dragged slot detaches from the row and
    // rides the cursor (grab offset preserved), painting above everything;
    // at home its gap chases the pointer through the working order, away
    // its home gap stays open behind it. The workList-gated x easing stays
    // on, so it trails the pointer smoothly and glides into its gap (or
    // home) on release.
    readonly property bool carried: root.dragActive && slot.modelData.id === root.dragId
    z: slot.carried ? 50 : 0
    x: slot.carried ? root.carryX - (root.carryGrabDX >= 0 ? root.carryGrabDX : 0)
      : root.xForSlot(slot.modelData.kind, slot.modelData.id)
    width: Math.round(contentLoader.implicitWidth * slot.grow)
    height: Bar.height
    implicitHeight: Bar.height
    // Toggled-in modules fade in WHILE growing (same window as the width
    // slide, mic-style) - never after it. Creation-driven: the Repeater
    // rebuilds every delegate on a toggle, so a membership binding would
    // flip late (gap opens first, fade lands after). Only entering ids
    // start at 0 and arm to 1 on completion; everyone else rests at 1
    // with no animation (Behaviors skip initial values). Retained
    // departures stay fully visible while sliding shut.
    //
    // Boot entrance (intro below) multiplies this: during the boot hold
    // both are live (enter 1, intro 0 -> opacity 0), on release intro
    // carries the slidefade. Post-boot toggles ride enter alone.
    opacity: slot.enter * slot.intro
    // Boot slide: held above the bar (top) or below it (bottom) until
    // Bar releases the entrance, then glides home with the fade above.
    // Position-driven, so a top/bottom flip mid-hold re-aims the travel;
    // at rest (intro 1) this is 0 whatever the position is.
    y: (1 - slot.intro) * slot.introOffset
    readonly property real introOffset: Bar.position === "top" ? -Ui.s : Ui.s
    // Boot entrance hold: 0 until Bar.entranceReady AND this slot's own
    // Loader is Ready, then 1 together with every other held slot.
    // _bootHeld captures birth before the release - only those animate.
    // Post-boot births (toggles, owned arrivals) are born after the latch
    // and skip straight to 1 with the Behavior below gated off, keeping
    // their existing grow/enter motion untouched. The Loader.Ready term
    // keeps a slot whose async build lands after the global release (a
    // second screen a frame behind) sliding in instead of popping.
    property bool _bootHeld: true
    property real intro: slot._bootHeld
      ? ((Bar.entranceReady && contentLoader.status === Loader.Ready) ? 1 : 0) : 1
    Behavior on intro {
      enabled: slot._bootHeld && MotionPolicy.enabled
      NumberAnimation { duration: Ui.slowMs; easing.type: Easing.OutCubic }
    }
    property real enter: (root.enteringIds.indexOf(slot.modelData.id) >= 0 && MotionPolicy.enabled) ? 0 : 1
    // Width factor: entering slots grow 0->full, retained departures
    // shrink full->0, everything else rests at full. Alone this drives the
    // whole effect - zone width, neighbor x and the center pivot all read
    // live slot widths, so they track each frame with no easing on top.
    property real grow: root._initialGrow(slot.modelData.id)
    Component.onCompleted: {
      // Capture birth before/after the entrance release: boot slots (born
      // held) keep the intro tween armed, post-boot births disarm it (see
      // the Behavior above) and skip straight to visible.
      slot._bootHeld = !Bar.entranceReady
      slot.grow = root._targetGrow(slot.modelData.id)
      // Arm the simultaneous fade: breaks the binding (stays 1), so the
      // later enteringIds cleanup cannot replay a second, delayed fade.
      if (root.enteringIds.indexOf(slot.modelData.id) >= 0) slot.enter = 1
      // A birth is a membership change: publish this row's real width.
      root.refreshGeometry()
    }
    Behavior on enter {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
    }
    Behavior on grow {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.slowMs }
    }

    // A width change is the one geometry input a binding cannot derive
    // from itself, so it rebuilds the row copy the reads resolve against.
    // Synchronous, in the same turn: `Slot.width` is live and `Slot.x`
    // resolves against the copy, so any deferral leaves the two disagreeing
    // for a frame - see _scheduleGeometryRefresh.
    onWidthChanged: root._scheduleGeometryRefresh()

    Behavior on x {
      enabled: MotionPolicy.enabled && root.workList !== null
      NumberAnimation { duration: Ui.expandMs; easing.type: Easing.OutCubic }
    }

    Loader {
      id: contentLoader

      // Pinned to the slot's right edge: while the slot grows the content
      // holds the neighbor boundary and the clip above trims the travel,
      // so the glyph holds still at its final spot while the row parts
      // around it (mic-style). At rest (grow 1) this puts the content flush
      // with the slot's right edge, the position an unanchored loader
      // gives.
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      // Asynchronous so one heavy module cannot stall the row behind it:
      // during boot every slot is held at intro 0 while its Loader builds,
      // then Bar releases them together into one slidefade; post-boot the
      // enter/grow animation above covers the arrival. Geometry survives
      // the gap through the geoSnapshot copy (an uninstantiated delegate
      // reads 0 there), and the construction clock still brackets
      // resolveSlot -> onLoaded, only longer.
      asynchronous: true

      sourceComponent: root.resolveSlot(slot.modelData.id)

      onLoaded: {
        if (contentLoader.item && root.hostWindow)
          root.hostWindow.wireModule(contentLoader.item)
        // Modules learn their slot id for the settings-key namespace (click
        // commands resolve shell.statusbar.<id><action>).
        if (contentLoader.item && contentLoader.item.moduleId !== undefined)
          contentLoader.item.moduleId = slot.modelData.id
        // Groups pick up their members once the slot tells them who they are.
        if (contentLoader.item && contentLoader.item.groupKey !== undefined)
          contentLoader.item.groupKey = slot.modelData.id
        // Loader.Ready is the close of the construction clock opened in
        // resolveSlot. A group key is not reported here: it is a layout
        // convenience whose members are timed individually in Group.qml, and
        // a `session loaded in 40ms` line would name one module where the
        // user sees two on the bar.
        if (!Bar.isGroup(slot.modelData.id)) Bar.reportModuleReady(slot.modelData.id)
      }
    }

    // Drag feedback, one box for both cases: while dragged the slot wears its
    // own accent box (border over a translucent accent fill), and while the
    // drag cursor sits on this slot's protected area the same box turns
    // red, marking the pinned slot off limits exactly where the cursor is.
    // The module content itself is never recolored. The two conditions are
    // exclusive per slot - a dragged slot is movable, and only a pinned id
    // is ever marked - so one rectangle answers both, at the higher z of
    // the pair, which leaves paint order over the module content alone.
    Rectangle {
      visible: slot.lifted || slot.offLimits
      anchors.fill: parent
      radius: Math.min(RoundingPolicy.radius, parent.height / 2)
      color: slot.lifted ? Ui.tint("accent", 0.14) : Ui.tint("red", 0.18)
      border.color: slot.lifted ? Ui.solid("accent") : Ui.solid("red")
      border.width: 1
      z: 25
    }

    // The drag gesture itself. A plain click (no movement) stays a click and
    // reaches the module's own handler; moving past the threshold takes over
    // the pointer and starts the reorder. Enabled only for layout slots -
    // owned indicators are services and not user-reorderable.
    DragHandler {
      id: dragHandler

      enabled: slot.draggable && !Bar.movePressed

      target: null
      // Reordering is horizontal: track the x axis only, so a plain click
      // (no movement) stays a click for the module and a vertical drag does
      // not grab anything. The platform drag threshold sizes the gesture.
      xAxis.enabled: true
      yAxis.enabled: false

      onActiveChanged: {
        if (active) root.startSlotDrag(dragHandler)
        else if (root.dragActive) root.commitDrag()
      }
    }
  }

  // No Row positioner here: every slot is positioned purely by its `x`
  // binding (xForSlot), so reordering workList during a drag is what moves
  // the delegates. A Row would lay them out by width/model order instead
  // and defeat the live rearrange entirely.
  Repeater {
    id: slotRep

    model: root.memberModel
    // Slot declares its own `required property var modelData`; the Repeater
    // injects it, so no delegate-inline redeclaration (which would shadow
    // the component property) is needed.
    delegate: Slot {}
  }

  // Drop hint for emptied zones: parked like the zone itself (left edge,
  // center, right edge) so it always sits inside the bar while any drag
  // is live. Shows where a drop lands; layout math ignores it.
  Rectangle {
    visible: root.showDropHint
    x: root.region === "left" ? 0 : root.region === "right" ? -root.dropHitW : -root.dropHitW / 2
    y: 4
    width: root.dropHitW
    height: Bar.height - 8
    radius: RoundingPolicy.radius
    color: Ui.tint("accent", 0.10)
    border.color: Ui.solid("accent")
    border.width: 1
  }
}

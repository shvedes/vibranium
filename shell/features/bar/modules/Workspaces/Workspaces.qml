pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import qs.common
import qs.features.bar
import "Model.js" as Model

// Global workspaces module. Every bar shows all real workspaces (special
// scratchpad surfaces are skipped); the one active on this bar's monitor
// reads as current (accent), workspaces with windows read occupied (full
// foreground), empty ones read registered (50% transparent). Clicking a
// workspace activates it. While a keybind submap is active a little "[R]"
// superscript appears after the last index (resize is the only submap
// today).
//
// Three shapes selected by shell.statusbar.workspacesAppearance:
// plain (default), boxes or piles.
//
//   plain  each workspace is a number in an equal-width slot, with a small gap.
//   boxes  each workspace is a padded box; boxes touch and the current one is
//          filled with the accent.
//   piles  each workspace shows its number and icons for distinct apps.
//
// Number-only styles reserve the measured width of two digits in every slot,
// so labels and hit targets stay even across single- and double-digit ids.
// Piles own the app icons and size each slot to its contents.
//
// Every shape publishes one width from one expression - a fixed two-digit
// number slot or the pile icon arithmetic - and the strip sums those.
//
// Number shapes are static in their LAYOUT whatever the animation switches
// say: no tween in this module runs outside Piles (see animOn), so a
// workspace is added and removed outright. The urgent pulse is the one
// animation that runs in every shape, because it paints a color and moves no
// geometry (see pulseOn). A pile is the only reason this module reads a
// workspace's windows; each delegate resolves its own pile and publishes its
// measured width. The module sums those widths, while number-only styles use
// a fixed two-digit width.

BarModule {
  id: root

  readonly property var monitor: barScreen ? Hyprland.monitorFor(barScreen) : null

  // The workspace THIS bar's monitor is on, read separately from the
  // workspace list because the list is not what changes: Hyprland reports
  // leaving an empty workspace and arriving on the next one as a destroy and
  // a spawn, so a flick across the strip moves the list twice and the focus
  // once.
  //
  // Per monitor, not global: the bar is built per output and each monitor has
  // its own active workspace, so a switch on one screen moves that bar's
  // focus and the others stay put.
  readonly property var activeWorkspace: root.monitor ? root.monitor.activeWorkspace : null

  // Each slot owns its own hover and click surface (see the delegate's
  // MouseArea), so the base fill is off. The base fill is raised above module
  // content and is hover-enabled, so leaving it on would swallow every hover
  // event and the per-pile hover lift could never fire. Volume's per-icon
  // areas disable it for the same reason.
  //
  // An assignment, not a redeclaration: BarModule already owns the property.
  builtinFill: false

  // Live submap from the hyprland event socket; empty string = default.
  property string submap: ""
  readonly property bool submapActive: root.submap === "resize"

  // One value makes all three appearances independently selectable.
  readonly property string appearance: {
    const value = Settings.value("shell.statusbar.workspacesAppearance")
    return value === "boxes" || value === "piles" ? value : "plain"
  }
  readonly property bool piles: root.appearance === "piles"
  readonly property bool boxes: root.appearance === "boxes"
  readonly property int twoDigitWidth: Math.ceil(twoDigitMeasure.width)

  TextMetrics {
    id: twoDigitMeasure

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontS
    font.bold: true
    text: "88"
  }

  // Whether this module's motion runs at all. One answer to "should this
  // frame move anything?", folded from the three things that decide it, so no
  // tween below has to repeat the check. The urgent pulse does NOT read it:
  // it paints a color and moves no geometry, so it has its own gate below.
  //
  //   MotionPolicy.enabled   the compositor-wide switch, and the only
  //                          animation switch a user can actually reach:
  //                          it is the one the settings catalog declares.
  //                          The bar's own shell.statusbar.iconAnimations
  //                          is deliberately NOT a term here. Icon and Clock
  //                          read it, but it is declared by no settings page
  //                          and SettingsLib.resolve drops every key the
  //                          schema does not name, so it resolves to
  //                          undefined from the settings file as well as
  //                          from the menu - a term that could never be
  //                          false is not a gate.
  //   piles                  number-only styles are fixed-width; piles alone
  //                          change width with their window count.
  //   bootSettled            the cold-boot grace, below.
  readonly property bool animOn: root.piles && MotionPolicy.enabled && root.bootSettled

  // Whether the urgent pulse may run. This is NOT animOn.
  //
  // animOn is a LAYOUT gate: the `piles` term in it is there because a
  // number-only slot has a fixed width, so it has nothing that can tween. A
  // color swing moves no geometry, so the term does not apply to it, and
  // reading animOn here is what held an urgent slot at its red in every
  // shape but Piles - the one state signal the strip paints went static in
  // the default appearance on account of a width tween it was never part of.
  //
  // What it does read is the compositor-wide switch and the cold-boot grace,
  // so a shell with motion killed off holds its red instead of swinging it,
  // exactly as the layout tweens stop. bootSettled is in both gates because a
  // pulse that started mid-boot would begin its cycle inside the pass the
  // grace is hiding, rather than from the foreground its first phase names.
  readonly property bool pulseOn: MotionPolicy.enabled && root.bootSettled

  // Cold-boot settle gate, the same one Volume uses for its mic pill: a
  // delegate publishes its width on completion and again as the workspace
  // list fills in, so the first layout pass moves every slot. Animating that
  // would fan the strip open on every start. Zone takes the same 2s grace,
  // so the module and its row settle on the same tick.
  property bool bootSettled: false

  Timer {
    interval: 2000
    running: true
    repeat: false
    onTriggered: root.bootSettled = true
  }

  // Records the layout once the motion has finished. Long enough for the
  // widest tween the module can start (a slot glides in over Ui.fastMs) plus
  // margin, and restarted on every change, so it always lands on a final
  // layout rather than a frame mid-glide.
  Timer {
    id: settleTimer
    interval: Ui.fastMs * 3
    repeat: false
    // Replaced wholesale rather than mutated: a binding reads this, and an
    // in-place write on a plain object would notify nobody.
    onTriggered: {
      root.settledWidths = root.currentWidths()
      root.retireSettled()
    }
  }

  // Fixed slot width for number-only appearances, sized for two digits.
  // It is also the stand-in before a delegate has published its pile width.
  readonly property int buttonWidth: Model.numberBoxWidth(root.twoDigitWidth, root.numberPad)
  onButtonWidthChanged: root.scheduleSlotGeometry()

  // The air inside one number slot, each edge. Boxes pad like a pill; plain
  // numbers use less padding to keep the strip compact.
  readonly property int numberPad: root.boxes ? root.metrics.pad : root.metrics.numberPad

  // Space between two slots. Plain numbers use a 3px gap, boxes
  // touch edge-to-edge, and piles keep enough air to read as separate pills.
  readonly property int gap: root.piles
    ? Model.pileGap(Bar.iconScale)
    : Model.numberGap(root.boxes)

  // One token set for every shape, so the strip arithmetic has a single
  // source. Scaled by the bar's own icon scale like every other module's
  // metrics, so a font preset grows the piles with the rest of the bar.
  readonly property var metrics: Model.metrics(Bar.iconScale, root.gap)

  // The surface height: an inset pill for piles and matching short boxes for
  // the boxes shape, leaving air above and below the row.
  readonly property int pillHeight: Model.pillHeight(Bar.height, Bar.iconScale)

  // Corner radius of pile pills. The boxes shape is square-cornered.
  readonly property int pillRadius: Model.pillRadius(Bar.height, Bar.iconScale)

  // The workspace ids that exist right now, special surfaces skipped.
  readonly property var liveIds: {
    const out = []
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id >= 0) out.push(ws.id)
    return out
  }

  // The ids the strip RENDERS - which is deliberately NOT what exists.
  //
  // Hyprland does not report a focus change as a change of list. Leaving an
  // empty workspace DESTROYS it and arriving on the next one SPAWNS it, as
  // two separate events, and in between the compositor genuinely has one
  // fewer workspace. Bound to the model directly, the Repeater rebuilt twice
  // and the strip really did pass through the shorter state: the workspaces to
  // the right moved a whole slot's width left, then came back. That reads as a
  // fast flicker, and no easing hides it, because the intermediate state is
  // real rather than a rendering artefact.
  //
  // Reconciling into a list the module owns, once per burst, collapses the
  // pair into ONE rebuild, so the strip never passes through the short state
  // at all. Swapping between two empty neighbouring workspaces then changes
  // the strip by the difference between the two numbers - about a pixel - so
  // the slot reads as the same slot showing a different number, which is what
  // it actually is.
  //
  // What the module owns is `rendered` below.
  // Long enough to swallow a destroy and the spawn that replaces it, short
  // enough to be invisible on a genuine change.
  readonly property int reconcileMs: 60

  // Ids that have LEFT the list but still hold width, tweening to nothing.
  //
  // A delegate that does not exist cannot be animated, so a departing slot
  // needs one that outlives the list by exactly one tween. Because x is the
  // sum of the widths actually being drawn, the slots to its right then glide
  // left on their own and the seam stays exact. Animating x instead would put
  // a slot in motion independently of its neighbour, which is the arrangement
  // that overlaps them.
  property var leaving: []

  // The ids the strip draws, in order, INCLUDING any that are on their way
  // out. This is the single list the model and all the geometry read, which is
  // what keeps them from disagreeing mid-rebuild.
  property var rendered: []

  function renderedIds() {
    return root.rendered
  }

  // One reconcile. The live order wins, and any id still being drawn that is
  // absent from it is spliced back at the index it holds rather than appended.
  //
  // Keeping the leaver IN PLACE is the whole point. Its width is what the
  // slots after it are positioned by, so a leaver left in the middle carries
  // them left as it collapses. Appending it to the end - the obvious way to
  // keep the model simple - animates the collapse somewhere the eye is not,
  // and everything to its right still snaps, because nothing between them is
  // moving any more.
  function reconcile() {
    const next = root.liveIds
    const prev = root.rendered
    const out = next.slice()
    const gone = []
    for (let i = 0; i < prev.length; i++) {
      const id = prev[i]
      if (next.indexOf(id) >= 0) continue
      if (out.indexOf(id) >= 0) continue
      out.splice(Math.min(i, out.length), 0, id)
      gone.push(id)
    }
    root.leaving = gone
    root.rendered = out
  }

  // Called once the tweens have finished, so a leaver is dropped only after it
  // has actually reached zero. Retiring on the event that removed it instead
  // would cut the glide off at whatever width it had reached.
  function retireSettled() {
    if (root.leaving.length === 0) return
    const keep = []
    const stillRendered = []
    for (const id of root.rendered) {
      if (root.leaving.indexOf(id) < 0) { stillRendered.push(id); continue }
      if (root.renderedWidthOf(id) > 0.5) { keep.push(id); stillRendered.push(id) }
    }
    if (keep.length !== root.leaving.length) {
      root.leaving = keep
      root.rendered = stillRendered
    }
  }

  function renderedWidthOf(id) {
    const at = root.rendered.indexOf(id)
    return at < 0 ? 0 : root.liveWidthAt(at)
  }

  Timer {
    id: reconcileTimer
    interval: root.reconcileMs
    repeat: false
    onTriggered: root.reconcile()
  }

  // A signal handler, not a binding: restarting a timer here is a side effect,
  // not something a binding evaluation may depend on.
  onLiveIdsChanged: {
    // Nothing to coalesce before the strip holds anything. The first
    // population is not a burst - it is the strip filling in for the first
    // time - and making it wait out the hold left the bar drawing no
    // workspaces at all for the length of it, which also made every probe
    // reading taken in that window vacuous: zero widths trivially never
    // overlap. After that, every change is a burst worth collapsing.
    if (root.rendered.length === 0) root.reconcile()
    else reconcileTimer.restart()
  }

  // The live workspace object for an id, or null while the strip still shows
  // an id the compositor has already dropped. That is the point of the hold,
  // and why the delegate has to survive a null workspace.
  function workspaceFor(id) {
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id === id) return ws
    return null
  }

  function visibleCount() {
    return root.renderedIds().length
  }

  // The number a workspace shows. The delegate paints the same string, so
  // the measured run and the painted glyph can never be two labels.
  function labelFor(ws, id) {
    // A held slot has no workspace object yet still owes a number: its id is
    // what it showed a moment ago, and for a numeric workspace it IS the
    // name, so the swap reads as one number changing to another.
    if (ws === null || ws === undefined) return String(id)
    return String(ws.name ?? ws.id)
  }

  // The workspace id the strip RENDERS at `index`, or -1.
  function idAt(index) {
    const idx = root.renderedIds()
    return index < idx.length ? idx[index] : -1
  }

  // One slot's LIVE width - the animated value, not the target.
  //
  // Reading the delegate rather than a published number is what keeps the
  // strip correct while it moves. An x animated independently of the widths
  // lets a slot reach its new position while the one after it is still
  // sliding, so the two overlap; x and the widths cannot be animated
  // separately and still keep a slot's right edge against its neighbour's
  // left edge.
  //
  // Deriving every position from the widths actually being drawn makes
  // adjacency structural: a slot's x is the sum of the widths before it, so
  // two neighbouring slots cannot overlap at any point in the tween, because
  // each one's right edge IS the next one's left edge by construction. The
  // same argument covers implicitWidth, which sums the same values, so the
  // bar's own reflow runs in step with the strip instead of jumping ahead of
  // it. Under a shared interpolation the additive relation is exact.
  //
  // A width of 0 is a real value, not a missing one: a slot growing in from
  // nothing passes through it, and treating it as "not built yet" would swap
  // in the fixed box and make the strip jump sideways mid-glide.
  //
  // The delegate at `index`, or null when the Repeater is out of step with the
  // list. Its items only address the list correctly while its own count agrees
  // with the rendered list, so an item read across a rebuild window belongs to
  // a workspace that is no longer there. Comparing counts rather than reading
  // a property off the item also keeps this free of a dynamic member the
  // linter cannot resolve.
  function delegateAt(index) {
    return wsRepeater.count === root.visibleCount() ? wsRepeater.itemAt(index) : null
  }

  // WHEN THE SLOT CANNOT BE TRUSTED, the stand-in is the width THAT WORKSPACE
  // last had, not the fixed box. Hyprland reports a focus change as two
  // events - destroy the empty workspace you left, create the one you arrived
  // on - and between them the Repeater is out of step with the list. The fixed
  // box is the wrong value there: it differs from an empty pile's width by
  // several pixels, and every slot to the right moves by that difference.
  //
  // The stand-in is keyed by the workspace's ID rather than by position, so it
  // carries none of the assumptions that would hand one workspace another's
  // width.
  function liveWidthAt(index) {
    const item = root.delegateAt(index)
    if (item !== null && item !== undefined) return item.width
    const held = root.settledWidths[root.idAt(index)]
    return typeof held === "number" && held > 0 ? held : root.buttonWidth
  }

  // The gap a slot LEAVES behind it, which is not always the strip's gap.
  //
  // A leaver's own width reaching zero is not the end of its contribution: it
  // still owns the gap to its right, and that gap outlives the width unless it
  // is tweened too, so the collapse finishes and the remaining pixels vanish
  // when the slot is retired. Tweening the gap on the same duration as the
  // width means the pair reaches zero together and retirement is a no-op.
  function liveGapAt(index) {
    const item = root.delegateAt(index)
    return item !== null && item !== undefined ? item.gapAfter : root.gap
  }

  // The layout as of the last settled pass: workspace id -> width.
  //
  // This is what lets a workspace created IN THE MIDDLE of the list glide
  // rather than snap. The Repeater builds a fresh delegate for the new
  // position, and a fresh delegate has no previous width for a Behavior to
  // animate from - Qt skips the value an item is born with - so without a
  // seed it simply appeared at full size while everything after it jumped.
  //
  // KEYED BY WORKSPACE ID, not by position. An insert shifts every later slot
  // along by one, so a positional seed hands each surviving workspace the
  // width of whichever one occupies its index, and gives a genuinely new id a
  // seed of 0: a workspace that only moved collapses and grows back. Keyed by
  // identity, a workspace that merely moved keeps its OWN width and only an
  // unseen id starts from nothing.
  //
  // Recorded only once the tween has finished, so the value is always a
  // FINAL layout and never a frame from the middle of one.
  property var settledWidths: ({})

  function currentWidths() {
    const out = ({})
    const idx = root.renderedIds()
    for (let i = 0; i < idx.length; i++) out[idx[i]] = root.liveWidthAt(i)
    return out
  }

  // The width a newly created slot should start from: what THIS workspace
  // held when the layout last settled. An id the settled layout never saw is
  // genuinely new and starts from nothing, so a workspace appended to the
  // end grows into the strip while the rest hold still.
  // Takes the workspace ID, not the object: the model is ids now, and a slot
  // can be asked for its seed while it holds an id the compositor has already
  // dropped - there is no object to read an id off in that case.
  function seedWidth(wsId) {
    const w = root.settledWidths[wsId]
    return typeof w === "number" && w > 0 ? w : 0
  }

  function settleLater() {
    settleTimer.restart()
  }

  // --- the row's numeric geometry, as one snapshot per tick ---
  //
  // The prefix x of every slot, plus the per-slot widths and gaps it was
  // built from: `{ count, widths, gaps, prefix }`, where `prefix[k]` is the
  // sum of the live widths and gaps of the k slots before index k, and
  // `prefix[count]` is the whole row. Every position read is one index into
  // this copy.
  //
  // It exists because resolving a position by walking the delegates is
  // quadratic in the number of workspaces, per frame. `x` is bound on every
  // delegate and each one sums the widths of every slot before it, and each
  // of those widths is a `Repeater.itemAt` lookup of an ANIMATED property -
  // so one width tween over n slots costs n delegates times n lookups every
  // frame, and the `slotsWidth` and `implicitWidth` walks run on top of it.
  // That is the same shape `Zone.qml` removes with its own `geoSnapshot`, and
  // for the same reason: one linear extraction per tick, then a read per
  // slot.
  //
  // The values in the copy are the LIVE ones, re-read on every pass, so this
  // changes the cost and not the geometry: a slot's x is still the sum of the
  // widths actually being drawn, so a slot's right edge IS the next slot's
  // left edge at every point in a tween rather than only at rest, and the
  // additive relation is exact because both sides read one snapshot. It is a
  // copy rather than a live view, so a reader cannot re-enter the pass that
  // is filling it.
  property var slotGeometry: ({ count: 0, widths: [], gaps: [], prefix: [0] })

  // The single extraction point: one pass over the delegates collects the
  // live width and gap of each and the prefix x they imply. Called from a
  // handler or a deferred flush, never from a binding - the module's one
  // hard rule about writes.
  function refreshSlotGeometry() {
    const n = root.visibleCount()
    const widths = new Array(n)
    const gaps = new Array(n)
    for (let i = 0; i < n; i++) {
      widths[i] = root.liveWidthAt(i)
      gaps[i] = root.liveGapAt(i)
    }
    const prefix = new Array(n + 1)
    prefix[0] = 0
    // The parenthesisation is load-bearing, not decoration: it is the order
    // the running total accumulated in, so the prefix rounds identically at
    // every step. Associating the other way round (`prefix + width + gap`)
    // sums the same terms in a different order and lands a sub-pixel step
    // away on fractional widths, which is enough to move a seam that the
    // module's whole geometry rests on being exact.
    for (let i = 0; i < n; i++) prefix[i + 1] = prefix[i] + (widths[i] + gaps[i])
    root.slotGeometry = { count: n, widths: widths, gaps: gaps, prefix: prefix }
  }

  // Synchronous, in the handler's own turn.
  //
  // A width tween reports on every frame and every slot after the one that
  // moved reports in that same frame, so an un-coalesced extraction is one
  // pass per slot per frame. Deferring it to the next event-loop turn does
  // coalesce those into one pass - and it is still wrong. A delegate's
  // `width` is a live binding while `slotX` resolves against this snapshot,
  // so a deferred pass leaves every slot's width one frame ahead of the x
  // that places it for the whole tween, then snaps on the final pass. The
  // identity-change case below is the same hazard and is direct for the same
  // reason. The cost is one pass per reporting slot per frame; the strip is
  // exact within every frame instead.
  function scheduleSlotGeometry() {
    root.refreshSlotGeometry()
  }

  // The row's identity changed: a direct pass, because the x bindings of the
  // slots about to be built resolve against the copy in the same turn and a
  // deferral would leave the whole strip a tick on the previous row. The
  // Repeater may not have built its delegates yet when this runs, so each
  // delegate's own birth runs a direct pass too and the last one is complete.
  onRenderedChanged: root.refreshSlotGeometry()

  // The settled widths are the STAND-IN a pass reads for a slot the Repeater
  // has not built, so recording a new set can move the row even when no
  // delegate's own width moved - which is exactly what the settle timer does
  // during a reconcile. A scheduled pass, not a direct one: this fires from a
  // timer handler that is itself already outside every binding, and the slots
  // it corrects are mid-collapse, so a tick of latency costs nothing.
  onSettledWidthsChanged: root.scheduleSlotGeometry()

  // Offset of the slot at `at` from the left edge: one index read, which is
  // the sum of the live widths and gaps of the slots before it. Out of range
  // clamps to the row's ends, so an index the Repeater has not counted yet
  // lands on the left edge and one past the strip lands on its total.
  function slotX(at) {
    const snap = root.slotGeometry
    return snap.prefix[Math.max(0, Math.min(at, snap.count))]
  }

  // The strip's slot area, without the trailing submap badge. Kept apart
  // from visibleWidth so the badge can sit at its right edge without the
  // badge's own width feeding back into the number it is positioned against.
  readonly property int slotsWidth: {
    // The bare read keeps the dependency on the Repeater's own count, so a
    // delegate birth re-evaluates this even on a tick where the snapshot has
    // not been rebuilt yet.
    wsRepeater.count
    const snap = root.slotGeometry
    if (snap.count === 0) return 0
    // The last slot leaves no gap behind it, and for a leaver that gap is on
    // its way to zero anyway, so it has to come off the total by its own value
    // rather than by the strip's gap.
    return Math.max(0, snap.prefix[snap.count] - snap.gaps[snap.count - 1])
  }

  implicitWidth: root.visibleWidth()

  // The badge trails the last index; slotInset pads its right edge so it
  // keeps the conventional air before the next module (zero-gap row).
  function visibleWidth() {
    wsRepeater.count
    const extra = root.submapActive ? root.gap + submapText.implicitWidth + Bar.slotInset : 0
    return root.slotsWidth + extra
  }

  // Windows of one workspace as plain records, the shape Model.pileItems
  // takes. The app identity is the wayland appId, which is what an app
  // reports about itself and what is identical across all of its windows;
  // Hyprland's own class is the fallback for a window with no wayland
  // surface, reached through lastIpcObject because Quickshell's Hyprland
  // toplevel carries no class property of its own.
  //
  // The window TITLE is deliberately not projected. Nothing downstream reads
  // it: the pile draws an icon, a count badge and a "+N" chip, and the click
  // activates the workspace rather than the window. Reading it here would be
  // the one field in this record that changes on every keystroke in any
  // window on this workspace, so the whole projection - and with it
  // Model.pileItems' group, count and slice - would re-run, and the pile
  // would be a fresh object, on every character typed anywhere on the
  // workspace. `address` stays because pileItems needs it to key a window
  // that declares no appId, and `activated` because it picks the
  // representative.
  function windowRecords(ws) {
    // A held slot has no windows, which is the honest answer.
    if (ws === null || ws === undefined) return []
    const tops = ws.toplevels ? ws.toplevels.values : []
    const out = []
    for (const top of tops) {
      if (!top) continue
      out.push({
        appId: root.appIdFor(top),
        address: String(top.address ?? ""),
        activated: top.activated === true,
        urgent: top.urgent === true
      })
    }
    return out
  }

  function appIdFor(top) {
    const appId = String(top.wayland?.appId ?? "").trim()
    if (appId !== "") return appId
    return String(top.lastIpcObject?.["class"] ?? "").trim().toLowerCase()
  }

  // The empty pile, shared by every slot while piles are off.
  //
  // One frozen value rather than null: a QML binding evaluates whether or
  // not the item it feeds is visible, so a Text reading `pile.overflow` would
  // dereference null on every number-only slot even though the chip is
  // hidden. An empty pile is the honest answer anyway - a number-only slot
  // genuinely holds no apps - and it lets every consumer read `pile.x`
  // unguarded.
  readonly property var emptyPile: ({ items: [], overflow: 0 })

  // The pile for one workspace: its capped icon list and the hidden
  // remainder. Empty for a workspace with no windows, which is what leaves a
  // bare number there.
  function pileFor(ws) {
    return Model.pileItems(root.windowRecords(ws), Model.MAX_ICONS)
  }

  // Icon URL for one pile entry: the app's own id first, then its name. The
  // shared primitive is the one place this two-step lookup lives, so a
  // window icon and a menu entry resolve by the same rule.
  function iconSourceFor(item) {
    for (const candidate of Model.iconCandidates(item.appId)) {
      const hit = AppIcons.url(candidate)
      if (hit !== "") return hit
    }
    return ""
  }

  // The tint a pile shows before the hover lift is added: the current
  // workspace, an occupied one, or nothing at all for an empty one. Kept as
  // one function so hover can be expressed as an offset from it rather than a
  // fourth parallel branch of the same decision.
  function pillAlpha(wsBtn) {
    if (wsBtn.focused) return root.metrics.pillFillFocused
    if (wsBtn.occupied) return root.metrics.pillFill
    return 0
  }

  // Stand-in for an app the platform theme has no icon for.
  //
  // A constant rather than a per-slot lookup, so it is resolved once for the
  // module and shared by every slot: AppIcons memoizes anyway, and a binding
  // that named the icon inline would re-ask on every repaint. A question mark
  // is the freedesktop "unidentified" glyph, so it ships in every icon theme
  // - which is what makes it a safe floor rather than one more thing that can
  // come back empty.
  readonly property string unknownIconSource: AppIcons.url("gtk-dialog-question")

  Component.onCompleted: Hyprland.rawEvent.connect(root.onRawEvent)
  Component.onDestruction: Hyprland.rawEvent.disconnect(root.onRawEvent)

  function onRawEvent(event) {
    if (event.name !== "submap") return
    root.submap = event.data.trim()
  }

  Repeater {
    id: wsRepeater

    model: root.renderedIds()

    delegate: Rectangle {
      id: wsBtn

      required property int index
      required property int modelData

      // The id this slot stands for, and the live workspace behind it. The
      // two part company for the reconcile window, when the strip is still
      // showing an id the compositor has already dropped - that is the hold,
      // and the slot keeps painting its number throughout.
      readonly property int wsId: modelData
      readonly property var ws: root.workspaceFor(wsId)
      // On its way out: the compositor has dropped this workspace, but the
      // slot is still drawn so its width can tween to nothing. Without it the
      // delegate would be destroyed on the spot and every slot to the right
      // would snap rather than glide.
      readonly property bool onTheWayOut: root.leaving.indexOf(wsId) >= 0
      // The gap this slot leaves to its right. Same Glide as the width below,
      // deliberately: a leaver's width and its gap have to reach zero on the
      // same frame or the strip loses the difference in a step.
      property real gapAfter: wsBtn.onTheWayOut ? 0 : root.gap
      Behavior on gapAfter {
        enabled: root.animOn
        Glide { duration: Ui.fastMs }
      }
      // Every reading below tolerates a null ws: a QML binding dereferences
      // its item whether or not the item is visible, and this slot is visible
      // for the whole hold.
      readonly property bool focused: ws !== null && root.monitor !== null && root.monitor.activeWorkspace === ws
      readonly property bool occupied: ws !== null && !!ws.toplevels && !!ws.toplevels.values && ws.toplevels.values.length > 0
      readonly property bool urgent: ws !== null && ws.urgent === true
      readonly property real baseOpacity: focused ? 1 : occupied ? 1 : 0.5
      // Resolved once per delegate and read by the icon row and the overflow
      // chip, so a workspace is walked once per rebuild rather than once per
      // binding that wants a window. Bound to ws, so opening or closing any
      // window re-resolves it. Never null - see root.emptyPile.
      readonly property var pile: root.piles ? root.pileFor(ws) : root.emptyPile
      // The cursor is over this slot. Drives the pile's hover lift.
      property bool hovered: false
      // The measured width of this workspace's number, used to size piles.
      // Number-only styles share the fixed two-digit width above.
      property int labelWidth: 0

      // Published from a change handler rather than read by the module: a
      // binding that assigns a probe's text and then reads that probe is a
      // binding loop, which is the trap RowHeightProbe.qml documents. A
      // handler runs outside every binding, so writing here is safe, and the
      // module only ever READS published widths.
      function publishLabelWidth() {
        const w = Math.max(Math.round(wsLabel.implicitWidth), Math.round(boldLabel.implicitWidth))
        if (w !== wsBtn.labelWidth) wsBtn.labelWidth = w
      }
      // Piles fit the measured number and icons. Number-only styles use the
      // same fixed width for every workspace, so long labels stay hittable.
      //
      // A leaver's target is zero, which is what the tween runs down to. The
      // slot's CONTENT is clipped as it narrows, so the number is faded out
      // alongside rather than sliced through the middle of a glyph.
      readonly property int ownWidth: wsBtn.onTheWayOut
        ? 0
        : (root.piles
          ? Model.pileWidth(pile.items.length, pile.overflow, wsBtn.labelWidth, root.metrics)
          : root.buttonWidth)
      // Urgent flash colors: the label's color swings foreground -> red
      // and back, slowly. Opacity stays at full strength while urgent so
      // the swing reads on the text itself. A focused box resolves its label
      // against the solid accent surface.
      readonly property color fgColor: root.boxes && wsBtn.focused
        ? Ui.contrastOn(root.metrics.boxFocusedFill)
        : Ui.solid("foreground_0")
      readonly property color urgentColor: Ui.solid("red")
      readonly property int flashMs: 700
      property color flashColor: Ui.solid("foreground_0")
      // Whether the urgent pulse is running. It reads `pulseOn`, not
      // `animOn`: the swing repaints a color and moves no geometry, so none
      // of what the `piles` term in `animOn` stands for - a pile's width
      // moving with its window count - applies to it. Every shape swings;
      // with the compositor's motion switch off the label holds
      // `urgentColor` outright, so the slot reads urgent either way.
      readonly property bool flashing: wsBtn.urgent && root.pulseOn

      // x is NOT animated. It is the sum of the widths actually being drawn
      // (see slotX), so it is already smooth and, more importantly, already
      // correct: an animated x could slide one slot across a neighbour that
      // had not moved yet. Animating the WIDTH is enough - the position
      // follows from it.
      x: root.slotX(index)
      // A slot the Repeater has just created starts at the width THIS
      // workspace held last (see seedWidth) and glides to its own, which is
      // what makes a workspace created mid-list slide rather than snap. It
      // arms a turn later, and that reassignment is the tween's first move -
      // a Behavior cannot animate the value an item is born with.
      //
      // With motion off there is no seed and no arming: the slot is born at
      // its final width, so the cold-boot pass cannot flash a narrower strip
      // for a frame before settling.
      width: (!root.animOn || wsBtn._armed || !wsBtn.animatedWidth)
        ? wsBtn.ownWidth
        : root.seedWidth(wsBtn.wsId)
      // A pile that gains or loses an app grows or shrinks, and its
      // neighbours are carried along because their x is derived from it.
      //
      // The tween is gated on animOn ALONE, and not on animatedWidth as well.
      // animatedWidth decides the TARGET, in the binding above, so a slot whose
      // target does not move has nothing to animate and needs no second gate.
      // Gating on both also breaks the first window on a workspace:
      // animatedWidth flips and the target moves in the same tick, and QML
      // does not order those two bindings, so the width is applied while the
      // tween is still off and the pile snaps instead of pushing.
      Behavior on width {
        enabled: root.animOn
        Glide { duration: Ui.fastMs }
      }

      property bool _armed: false
      // Whether this slot's width is worth tweening - which is exactly when
      // its target is going to MOVE.
      //
      //   leaving: collapses to zero, and that collapse is the whole reason
      //     it still has a delegate.
      //   has icons: gains or loses rows as windows open and close.
      //   not yet armed: the slot was just created, so it is being handed the
      //     seed width in the binding above and needs the tween to travel
      //     from it. A workspace never seen before seeds from nothing, and an
      //     EMPTY one is the case that matters: with 7 leaving and 8
      //     arriving in the same reconcile, both animating is what makes them
      //     cancel. Born at full size instead, 8 and 7's collapse briefly
      //     stack, and everything to the right swings out and back.
      readonly property bool animatedWidth: root.piles
        ? (wsBtn.onTheWayOut || pile.items.length > 0 || !wsBtn._armed)
        : false
      onOwnWidthChanged: root.settleLater()
      // The width and the gap are the two inputs a binding cannot derive
      // from itself, so each reports the change that moves the rest of the
      // strip. The report is coalesced into one pass per tick, because an
      // animated width moves this slot AND every slot after it on the same
      // frame and the strip's positions are read from one copy.
      //
      // The gap reports for its own sake, not for symmetry: a leaver's width
      // and its gap tween to zero together, and the seam between two slots
      // is exact only while both are moving, so a pass driven by the width
      // alone would draw the collapse with the gap a frame stale.
      onWidthChanged: root.scheduleSlotGeometry()
      onGapAfterChanged: root.scheduleSlotGeometry()
      Component.onCompleted: {
        if (root.animOn) {
          // A turn, not immediately: arming in the same tick would make it a
          // no-op, since the tween needs two distinct values to run between.
          Qt.callLater(function () { wsBtn._armed = true })
        } else {
          wsBtn._armed = true
        }
        // The layout is about to change; record where it comes to rest.
        root.settleLater()
        // Direct, not scheduled: the other slots' x bindings resolve against
        // the copy in this same turn, and this is the pass that makes the row
        // complete - a new delegate is the last one the extraction has to see.
        root.refreshSlotGeometry()
      }
      // The slot spans the full bar height - it is the hit target and what
      // the zone lays out. Piles inset their pill and boxes inset vertically;
      // the child surface owns each shape's fill and height.
      height: Bar.height
      // A leaver narrows past the width of its own content, so the content
      // has to be clipped or the number hangs outside the slot. It is
      // transparent for a slot at rest, so this costs nothing normally.
      clip: true
      opacity: wsBtn.onTheWayOut ? 0 : 1
      Behavior on opacity {
        enabled: root.animOn
        Glide { duration: Ui.fastMs }
      }
      // The slot itself is never a surface. The child below owns any tint.
      color: "transparent"

      // The background surface: the pill for piles, the filled box for boxes,
      // and nothing for the plain strip. Surfaces are inset vertically so
      // they read as contained shapes rather than full-height bands.
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        // Piles: a pill with rounded corners; boxes: a sharp-edged box;
        // plain strip: zero height (invisible).
        height: root.piles ? root.pillHeight
                  : root.boxes ? root.pillHeight
                  : 0
        // Piles: rounded to read as a chip; boxes and plain strip: sharp.
        radius: root.piles ? root.pillRadius : RoundingPolicy.radius
        // The state tint, plus the hover lift on top of whichever is showing.
        //
        // Piles lift their faint tint on hover; boxes fill the focused slot
        // with accent and otherwise use a subtle tint; plain is transparent.
        color: root.piles
          ? (wsBtn.hovered
            ? Ui.tint("foreground_0", root.pillAlpha(wsBtn) + root.metrics.pillHover)
            : Ui.tint("foreground_0", root.pillAlpha(wsBtn)))
          : root.boxes
            ? (wsBtn.focused
              ? Ui.solid(root.metrics.boxFocusedFill)
              : Ui.tint("foreground_0", root.metrics.boxFill
                + (wsBtn.hovered ? root.metrics.pillHover : 0)))
            : "transparent"

        Behavior on color {
          enabled: root.animOn
          ColorAnimation { duration: Ui.fastMs }
        }
      }

      // The workspace number. Paints the same string the strip measured and
      // uses the same level-3 sizing in every shape.
      Title {
        id: wsLabel

        level: 3
        anchors.verticalCenter: wsBtn.verticalCenter
        x: root.piles ? root.metrics.pad : 0
        width: root.piles ? wsLabel.implicitWidth : wsBtn.width
        horizontalAlignment: root.piles ? Text.AlignLeft : Text.AlignHCenter
        text: root.labelFor(wsBtn.ws, wsBtn.wsId)
        color: wsBtn.urgent && !(root.boxes && wsBtn.focused)
          ? (wsBtn.flashing ? wsBtn.flashColor : wsBtn.urgentColor)
          : wsBtn.focused
            ? (root.piles
              ? Ui.solid("accent")
              : (root.boxes
                ? Ui.contrastOn(root.metrics.boxFocusedFill)
                : Ui.solid("accent")))
          : wsBtn.fgColor
        font.bold: wsBtn.focused
        opacity: wsBtn.urgent ? 1 : wsBtn.baseOpacity
        onImplicitWidthChanged: wsBtn.publishLabelWidth()
        Component.onCompleted: wsBtn.publishLabelWidth()
      }

      // The width the number is measured at: the BOLD run, always.
      // The painted label goes bold on the focused workspace, and bold is
      // about a pixel wider. Measuring the widest case keeps pile geometry
      // focus-independent, so focus changes only repaint the changed piles.
      //
      // The spare pixel on an unfocused pile is inner air; its icons follow
      // the painted run (wsLabel.width) exactly.
      Title {
        id: boldLabel

        level: 3
        visible: false
        width: 0
        // Piles position the probe after their inner padding, just like the
        // visible label. Number-only labels are centered in their fixed slot.
        x: root.piles ? root.metrics.pad : 0
        height: 0
        text: wsLabel.text
        font.bold: true
        onImplicitWidthChanged: wsBtn.publishLabelWidth()
        Component.onCompleted: wsBtn.publishLabelWidth()
      }

      // App icons: one per distinct app in the workspace, in the order the
      // apps first appear, and no more than Model.MAX_ICONS of them. Empty
      // for an unoccupied workspace, which is what leaves a bare number.
      //
      // A FIXED number of slots, not one per app. This is what makes an icon
      // slide out as smoothly as it slid in. With a Repeater over the app
      // list, an app leaving DESTROYS its delegate - there is nothing left to
      // animate - and this Qt build's positioner has no `remove` transition
      // to soften it (it exposes only populate/move/add), so the icon popped
      // out while its neighbours slid. Fixed slots are never destroyed, so a
      // departing app is just a slot whose width and opacity glide to zero.
      //
      // The slot count is the same MAX_ICONS the cap uses, so the geometry
      // below and Model.pileWidth agree on how many slots can ever be
      // occupied. Nothing here changes the app set: it only decides how the
      // same set is drawn.
      Row {
        id: pileIcons

        anchors.verticalCenter: parent.verticalCenter
        x: wsLabel.x + wsLabel.width + root.metrics.numGap
        // The gap is carried by each occupied slot rather than by the
        // positioner's spacing, because a spacing would also be inserted
        // around an EMPTY slot and leave a hole where an icon no longer
        // sits.
        // The last occupied slot carries no trailing gap, which is what makes
        // the row's width exactly the icon area Model.pileWidth budgeted.
        spacing: 0
        visible: root.piles && wsBtn.pile.items.length > 0

        Repeater {
          model: Model.MAX_ICONS

          delegate: Item {
            id: pileIcon

            required property int index

            // This slot's app, or null when fewer apps than slots are shown.
            // Bound to the pile, so an app opening or closing re-evaluates it.
            readonly property var item: root.piles && index < wsBtn.pile.items.length
              ? wsBtn.pile.items[index] : null
            readonly property bool last: index === wsBtn.pile.items.length - 1
            // Occupied: the icon plus the gap that follows it, except after
            // the last one. Empty: nothing at all, so the slot collapses out
            // of the run without leaving a gap behind.
            width: item !== null
              ? root.metrics.icon + (last ? 0 : root.metrics.iconGap)
              : 0
            height: root.metrics.icon
            opacity: item !== null ? 1 : 0
            // The slide. Width carries the layout, so the positioner re-lays
            // the run on every frame of the tween and the neighbours are
            // carried along with it; opacity keeps the departing icon
            // visible while it collapses. Both gated on the same switch as
            // the rest of the module's motion, so one setting governs it.
            Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }
            Behavior on opacity { enabled: root.animOn; Glide { duration: Ui.fastMs } }

            readonly property string source: item !== null ? root.iconSourceFor(item) : ""
            // The containing window's DPR (its own screen - bar windows can
            // move). Window.devicePixelRatio notifies on its own, so a bar
            // that moves to a screen with a different scale re-rasterizes.
            readonly property real _dpr: {
              const w = Window.window
              const dpr = w ? w.devicePixelRatio : 0
              return typeof dpr === "number" && isFinite(dpr) && dpr > 0 ? dpr : 1
            }

            // App icons are platform assets and must keep their own colors,
            // so these are plain Images and not the Icon primitive (which
            // recolors the shell's own glyphs to the palette). Image rather
            // than IconImage because only Image takes a sourceSize: Qt
            // rasterizes into sourceSize and maps that texture onto the item,
            // so without it the icon decodes once at 1x and every later
            // display-scale change stretches a stale raster. Rasterizing at
            // icon * DPR keeps it texel-crisp.
            Image {
              id: glyph

              x: 0
              width: root.metrics.icon
              height: root.metrics.icon
              visible: pileIcon.source !== ""
              source: pileIcon.source
              sourceSize: Qt.size(root.metrics.icon * pileIcon._dpr, root.metrics.icon * pileIcon._dpr)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
              asynchronous: true
              retainWhileLoading: true
            }

            // The app ships no icon the platform theme knows. Rather than
            // leave a hole in the run, the slot shows the standard
            // "unknown" glyph, so a workspace holding such an app still
            // reads as occupied and the app is visibly unidentified.
            //
            // Resolved through the same primitive as a real icon, so it goes
            // through Icons.url first and the platform theme second, and it
            // is memoized like any other lookup rather than re-resolved on
            // every repaint.
            Image {
              id: unknownGlyph

              x: 0
              width: root.metrics.icon
              height: root.metrics.icon
              visible: pileIcon.item !== null && pileIcon.source === ""
              source: root.unknownIconSource
              sourceSize: Qt.size(root.metrics.icon * pileIcon._dpr, root.metrics.icon * pileIcon._dpr)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
              asynchronous: true
              retainWhileLoading: true
              opacity: 0.6
            }

            // Count badge on an app with more than one window, so two
            // terminals read as one app with two windows rather than as a
            // single window. A background_0 ring keeps the digit legible
            // over an icon of any color.
            Rectangle {
              visible: pileIcon.item !== null && pileIcon.item.count > 1
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              width: Math.max(5, Math.round(root.metrics.icon * 0.42))
              height: width
              radius: width / 2
              color: Ui.solid("background_0")

              Text {
                anchors.centerIn: parent
                // `visible` on the badge does not protect this: a QML binding
                // evaluates whether or not the item it feeds is shown, and an
                // empty slot has no item at all. Same rule as root.emptyPile.
                //
                // Clamped at 9 because the badge is a fixed circle sized from
                // the icon, and two digits do not fit it. A tenth window is
                // rare enough that reading it as "9 or more" costs less than
                // a badge that overlaps its own glyph.
                text: pileIcon.item !== null
                  ? String(Math.min(9, pileIcon.item.count))
                  : ""
                color: Ui.solid("foreground_0")
                font.family: Ui.fontFamily
                font.pixelSize: Math.max(6, Math.round(root.metrics.icon * 0.34))
                font.bold: true
              }
            }
          }
        }
      }

      // The remainder chip: one narrow "+N" standing in for every icon past
      // the cap, so a workspace with a dozen windows still fits the strip.
      Text {
        id: overflowChip

        anchors.verticalCenter: parent.verticalCenter
        // No Behavior here: the row's width is the sum of the slots' ANIMATED
        // widths, so this binding already moves with them. A tween on top
        // would smooth an already-smooth value and lag behind the icons it
        // is supposed to be attached to.
        x: pileIcons.x + pileIcons.width + root.metrics.iconGap
        visible: root.piles && wsBtn.pile.overflow > 0
        text: "+" + wsBtn.pile.overflow
        color: Ui.tint("foreground_0", 0.5)
        font.family: Ui.fontFamily
        font.pixelSize: Math.max(7, Math.round(root.metrics.icon * 0.7))
        font.bold: true
        width: root.metrics.overflow
        horizontalAlignment: Text.AlignHCenter
      }

      // Urgent workspaces pulse their color slowly between the normal
      // foreground and red (fg -> red -> fg). The explicit `from` on the
      // first phase snaps the start color back to foreground even if the
      // cycle was interrupted mid-swing.
      //
      // `wsBtn.flashing` carries the gate, which is `root.pulseOn` - the
      // compositor-wide switch and the cold-boot grace, without the `piles`
      // term `animOn` exists for. A looping animation has no `Behavior` to
      // disable and `Animation` has no `enabled` member either, so `running`
      // is the only lever. With the gate shut the label paints `urgentColor`
      // outright (see wsLabel.color), so the slot still reads urgent and still
      // drives full-strength opacity below; it is simply held at the color
      // the pulse would reach rather than swung toward it.
      SequentialAnimation {
        id: urgentFlash

        running: wsBtn.flashing
        loops: Animation.Infinite

        ColorAnimation {
          target: wsBtn
          property: "flashColor"
          from: wsBtn.fgColor
          to: wsBtn.urgentColor
          duration: wsBtn.flashMs
          easing.type: Easing.InOutQuad
        }
        ColorAnimation {
          target: wsBtn
          property: "flashColor"
          to: wsBtn.fgColor
          duration: wsBtn.flashMs
          easing.type: Easing.InOutQuad
        }
      }

      // The slot's whole input surface: hover, and the two clicks.
      //
      // This is why the module sets builtinFill to false. The base fill is
      // raised above module content and is hover-enabled, so it would take
      // every hover event and this area would never see one - the hover lift
      // would be dead. Owning the surface per slot is the same arrangement
      // Volume uses for its per-icon areas.
      MouseArea {
        id: wsHover

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: wsBtn.hovered = true
        onExited: wsBtn.hovered = false
        onClicked: mouse => {
          // Left activates the workspace; right is the declarative click
          // command, exactly as the base fill routed it.
          //
          // The base fill is off (`builtinFill: false`) because it is raised
          // and hover-enabled, so leaving it on would swallow every hover and
          // the per-pile lift would be dead.
          if (mouse.button === Qt.RightButton) {
            root.clickCommand("rightClick")
            return
          }
          // A held slot may outlive its workspace during reconciliation.
          // Dispatch directly through Quickshell for an immediate compositor
          // request without spawning a hyprctl process.
          //
          // The request is Lua, not a dispatcher string: this compositor
          // evaluates a dispatch as a Lua chunk (`return hl.dispatch(<request>)`),
          // so a bare "workspace 3" fails to parse and the click does nothing.
          // Ids are positive here - special workspaces are filtered out of
          // liveIds - so the number interpolates as a Lua literal.
          if (wsBtn.ws !== null) Hyprland.dispatch("hl.dsp.focus({workspace = " + wsBtn.wsId + "})")
        }
      }
    }
  }

  // Superscript "[R]" trailing the indexes while a submap is active.
  Title {
    id: submapText

    level: 4
    x: root.slotsWidth + (root.submapActive ? root.gap : 0)
    y: 3
    visible: root.submapActive
    text: "[R]"
    color: Ui.solid("yellow")
    font.pixelSize: 8
    font.family: Ui.fontFamily
    font.bold: true
  }

  // Right-click stays declarative (shell.statusbar.workspacesRightClick via
  // BarModule.clickCommand), dispatched from each slot's own MouseArea rather
  // than from the base fill, because that fill has to be off for the per-slot
  // hover surface to receive any event at all. The command, its fallback and
  // its key are unchanged.
}

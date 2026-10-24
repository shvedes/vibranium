pragma ComponentBehavior: Bound

// The Graph tab: a canvas of the audio graph, the local qpwgraph.
//
// It is drawn from two sources and neither of them is this file's own memory.
// The NODES come from the controller's `graphNodes`, which is the whole
// audio node set under the same filter the row lists use - so a shell peak tap
// is not on this canvas either, and a tap here would create another tap. The
// LINKS come from the controller's `graphLinks`, which is read out of
// `AudioNodes.linkValues`, the graph's own link list. Nothing here invents a
// line: a link the daemon does not report is not drawn, which is what makes a
// refused or coalesced connect disappear on the next frame instead of lingering
// as fiction the user has to disprove.
//
// Four things the canvas does, in this order of authority:
//
//   PAN and ZOOM are this file's own state, applied to one `Item` rather than
//   through a Flickable. A Flickable inside the window's own body Flickable
//   would be two scroll owners over one viewport, and a nested drag is decided
//   by Qt rather than by this file.
//
//   CARD PLACES are this file's state too, keyed by node id and NOT persisted.
//   Nothing here is written to disk, so a mixer that is closed and reopened
//   lays the graph out again. Keying rather than indexing is what keeps a card
//   from jumping: the node set is republished whole whenever any node arrives or
//   leaves, so the delegate array is rebuilt on every arrival, and a card that
//   read its place by index would move every time one of its neighbours did.
//   A card that reads its place by key comes back to where it was.
//
//   The FIRST place a card is given comes from a LAYERED LAYOUT rather than a
//   grid: a layer per node is the length of the longest chain of links ending at
//   it, so a source is leftmost, the filters are in the middle, the devices are
//   rightmost, and every link runs left to right without a single per-kind case.
//   `Graph.layerPlan` is that rule, as a pure function of the node set and the
//   link groups, and it is recomputed on every rebuild - a card that ALREADY has
//   a place never reads the new plan, so an arrival cannot shift its neighbours.
//   Nodes with no links at all go to a column beside the band rather than into
//   it: the chain says nothing about them and a card sitting in the middle of a
//   chain reads as a stage of it.
//
//   CONNECTING is a gesture on the wire: a press on a card's port handle and a
//   release over another card. The pairing behind it is `Graph.pairPorts`, and
//   which ports match is never decided here.
//
//   Every drawn line meets a card ON one of its port marks rather than on the
//   card's dead middle, so the mark a line starts from and the mark a press can
//   grab are the same mark. Which one is `Graph.edgeSlots` answered into
//   `edgeAt`, and the curve and the grip on the curve's end read that one
//   answer rather than each placing an end of their own.
//
//   WRITES are the controller's, and every one of them is a gesture the user
//   ended deliberately on a named pair: a wire released over a card, a line's
//   own endpoint dragged onto a card, a right-click on a card edge's handles,
//   and the Disconnect chip with a line selected. Nothing is written on a hover,
//   on a pan, on a zoom, on a card move, on a layout pass or on the open, and a
//   wire released over nothing writes nothing at all - the rubber band is the
//   whole of the pending state and it is not the graph's to keep.
//
// The lines are `Shape` paths rather than a `Canvas`. A Canvas repaints on its
// own `onPaint`, which on a live graph means once per graph tick with the whole
// topology re-walked in JS; a Shape repaints when its path properties change
// and not otherwise, so a graph that has not moved costs nothing to draw.
//
// The viewport is BOUNDED, and that is a structural answer rather than a z-order
// one. Two nested boxes, both clipped: the tab itself, so nothing reaches the
// window's tab strip above it, and the `canvas` inside it, whose top edge IS the
// bottom of the chrome row. The chrome is a child of the tab and therefore
// inside the tab's own rectangle, so a tab-level clip cannot keep the canvas
// away from the hint line and the buttons - a card dragged up under them is
// still a card that clip lets through, and the user reads that as a card painted
// over them. Bounding the canvas to the region below the chrome is the only
// arrangement in which a card cannot reach the chrome at any zoom and any pan,
// because there is no pan that puts the chrome inside the canvas. Raising the
// chrome's z instead would only move the fight to the next surface.
//
// The canvas is NOT clipped to the world's own box. The world is `worldW` by
// `worldH`, which is a bound rather than a measurement - a card the user dragged
// past the last grid slot sits outside it - and at the smallest zoom the scaled
// world is smaller than the viewport in both axes, so a clip on the world would
// cut away parts of the canvas that are inside the viewport. The clip belongs on
// the viewport, and the viewport is the canvas.
//
// SPLIT MAP (one owner each, no behavior change): Canvas (viewport
// transform, card placement, grips/wires/lines, pan/zoom, the canvas +
// world) and Layout (card model, layered layout plan, chrome row, tab
// chrome). Lines are Shape paths, never Canvas repaints.

import QtQuick
import QtQuick.Shapes
import qs.common
import "MixerModel.js" as Model
import "GraphModel.js" as Graph

Item {
  id: tab

  // The outer bound: nothing this tab draws reaches the window's own tab strip
  // above it or the window edge beside it. See the note above.
  clip: true

  // A panel action: a label in a chip that is also a button.
  //
  // Hand-built rather than `Chip` for the reason the window's routing chip is
  // hand-built: `Chip` centres its label in the whole pill, and it has no way
  // to be red - which the Disconnect action has to be, because it is the one
  // control on this canvas that cuts a link the user may be listening through.
  component GraphTabAction: Rectangle {
    id: action

    property string text: ""
    // The destroying action. Red chrome, so Disconnect does not read as one more
    // label beside three neutral ones.
    property bool danger: false
    property bool hover: false
    property bool press: false

    signal triggered()

    implicitWidth: actionLabel.implicitWidth + 2 * Ui.s
    implicitHeight: Math.max(22, actionLabel.implicitHeight + Ui.s)
    radius: RoundingPolicy.radius
    color: !action.enabled ? Ui.tint("foreground_1", 0.03)
      : (action.press ? Ui.tint(action.danger ? "red" : "accent", 0.22)
        : (action.hover ? Ui.tint(action.danger ? "red" : "accent", 0.12)
          : Ui.tint("foreground_1", 0.05)))
    border.width: 1
    border.color: action.danger
      ? Ui.tint("red", 0.55)
      : Ui.tint("background_3", 0.8)

    Behavior on color { ColorAnim {} }
    Behavior on border.color { ColorAnim {} }

    Title {
      id: actionLabel

      anchors.centerIn: parent
      level: 5
      text: action.text
      elide: Text.ElideRight
      font.bold: action.danger
      color: !action.enabled ? Ui.tint("foreground_1", 0.4)
        : action.danger ? Ui.solid("red") : Ui.solid("foreground_1")
    }

    MouseArea {
      anchors.fill: parent
      enabled: action.enabled
      hoverEnabled: action.enabled
      cursorShape: action.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onPressed: action.press = true
      onReleased: action.press = false
      onExited: action.press = false
      onCanceled: action.press = false
      onClicked: action.triggered()
    }

    HoverHandler {
      onHoveredChanged: action.hover = hovered
    }

    Accessible.role: Accessible.Button
    Accessible.name: action.text
  }

  required property var controller
  // Whether this tab is the one on screen. The window empties the model as well
  // as collapsing this item, so an inactive canvas builds no card, takes no
  // peak hold and holds no selection.
  property bool active: false

  // --- the viewport transform ---
  //
  // One `Item` carries both: `scale` is the zoom about the canvas's own top
  // left, and `x`/`y` are the pan. Zooming about the pointer rather than about
  // the origin is one line of arithmetic (below) and it is the difference
  // between a canvas that follows the pointer and one that slides out from
  // under it.
  readonly property real minZoom: 0.35
  readonly property real maxZoom: 2.0
  // One notch multiplies the zoom by `exp(step)`, so the step is a log ratio and
  // not a percentage: a percentage would have to be recomputed against the
  // current scale to stay constant. At 0.1 a notch is about 10% and seven
  // notches reach a doubling, which is the wheel step every other zoomable
  // surface in a desktop shell uses and is slow enough to stop on.
  readonly property real zoomStep: 0.1
  // A quarter of the base step, for Control. A modifier rather than a smaller
  // base step: a base step small enough to want a modifier is a base step whose
  // unmodified wheel reads as no wheel at all, and the modifier is here to make
  // a coarse wheel land on a fine scale, not to rescue a fine one.
  readonly property real zoomStepFine: 0.025
  property real zoom: 1
  property real panX: 0
  property real panY: 0

  // The viewport, in the canvas's own units. Read off the canvas rather than
  // off the tab, because the canvas is the box the graph is allowed to paint
  // in and the pan clamp has to keep the world inside THAT box: a clamp against
  // the tab's height would let the world slide under the chrome, which is the
  // one place it must never be.
  readonly property int viewW: canvas.width
  readonly property int viewH: canvas.height

  // --- card placement ---
  //
  // The delegate array is `[{ key, node }]`, published so it can be a
  // Repeater's model, and kept stable by Graph.syncCards: when the graph
  // republishes the same node set behind fresh wrappers, syncCards hands back
  // the incumbent array and no delegate is rebuilt at all.
  property var _cards: []
  // node id -> `{ x, y }`, the places that outlive a rebuild. A separate map
  // rather than a field on the card entry, because the card entry is exactly
  // the thing that is thrown away and rebuilt.
  property var _positions: ({})

  // The card's own size, and the SPACING around it. Three numbers and a margin,
  // and the steps are derived from them rather than stated, because a card's
  // width and the gap beside it are one measurement of how much room the canvas
  // takes: an independent `colStep` goes stale against a resized card and the
  // gap silently closes.
  //
  // The gaps are generous because this is a canvas to be read at a glance and
  // dragged across, and because the handles sit ON the card edges - a cramped gap
  // puts the right-hand handle of one card and the left-hand handle of the next
  // within a few pixels of each other, which is two targets where the user aimed
  // at one.
  readonly property int cardW: 240
  readonly property int cardH: 104
  // The clear space between two cards' edges. The x gap is also the minimum
  // horizontal span between two linked cards' anchors, so it sets how much lead
  // a link's curve has to work with.
  readonly property int gapX: 148
  readonly property int gapY: 52
  // The world's own margin: the padding around the whole band, on every side.
  // This is the space between the outermost card and the edge the pan clamp stops
  // at, so it is a reachability number before it is a spacing one - a clamp whose
  // bound is inside the outermost card is a card the user cannot pan to at all.
  // It also matches the 80 the clamp stops short of on the viewport side, so the
  // two ends of the pan agree about how much of the edge to leave behind.
  readonly property int margin: 80
  readonly property int colStep: tab.cardW + tab.gapX
  readonly property int rowStep: tab.cardH + tab.gapY

  // The world's own extent, from the LAYOUT rather than from the card count.
  //
  // A card count says nothing about how many columns those cards ended up in -
  // eight cards laid out as a chain of four filter stages are four columns wide,
  // where a card-count bound would claim eight cards' worth of one column - and
  // the pan clamp is measured against this, so a world smaller than its own
  // contents is a canvas whose right-hand layers cannot be panned to.
  //
  // `Graph.layerExtent` rather than the arithmetic here: the same function the
  // slots came from, over the same plan, so the bound and the cards cannot be two
  // answers to one question. Recomputed on a layout pass, not per frame - it is a
  // property of the plan, not of the pointer.
  property var _extent: ({ w: 0, h: 0 })
  readonly property real worldW: Math.max(1, tab._extent.w)
  readonly property real worldH: Math.max(1, tab._extent.h)

  // --- the grips and the wire ---
  //
  // The drawn mark and its pick tolerance, in ONE space, with the mark the input
  // and the tolerance derived from it.
  //
  // Stated as two independent numbers they are two numbers free to disagree, and
  // the disagreement is what makes a press miss: a mark stated in WORLD units
  // grows with the zoom while a tolerance stated in SCREEN pixels does not, so
  // past 1x the target ends up smaller than the thing it is the target for. At 2x
  // with a 16-unit mark, a tolerance of eleven screen pixels is a 22-pixel target
  // around a 32-pixel ring, and the outer five pixels of every ring answer to
  // nothing - a press there reaches the background, and the background pans.
  //
  // So the mark is WORLD units - it is painted inside the world item and scales
  // with the canvas like everything else on a card - and the tolerance is the
  // mark's own radius plus a floor of SLOP screen pixels, so the hit region is
  // ALWAYS the mark plus that floor and cannot be smaller than what is drawn:
  //
  //   reach * zoom >= handleSize / 2 * zoom + slop
  //
  // which is an identity at every zoom by construction. Measured, radius in
  // screen pixels, at 1 / 0.35 / 2:
  //
  //   zoom   mark radius   tolerance (screen px)   contains the mark
  //   1.00        8             14                   yes, +6
  //   0.35        2.80           8.80                 yes, +6
  //   2.00       16             22                   yes, +6
  //
  // The floor is what keeps a three-pixel mark hittable at the smallest zoom, and
  // it is in SCREEN pixels because that is the one thing that must not shrink:
  // the canvas is scaled, the pointer is not.
  readonly property int handleSize: 16
  // The extra reach beyond the drawn mark, in screen pixels, at every zoom. Six
  // is about the width of a pointer's own imprecision at the extremes of the
  // zoom range, and it is deliberately not larger: the tolerance also decides
  // which edge a press near the middle of a card belongs to, and a tolerance
  // wider than the card's own half would make every press on a card a press on
  // one of its two edges.
  readonly property real handleSlop: 6
  readonly property real handleReach: tab.handleSize / 2 + tab.handleSlop / tab.zoom
  // The band the handles of one edge are spread over, and the largest gap
  // between two of them. A fan wider than the band would put a handle under the
  // card's own name and mute control, which are the two things above this band.
  // Published because the step below is derived from it.
  readonly property int handleSpan: 44
  readonly property int handleGapMax: 22

  // --- the lines ---
  //
  // The stroke weights, and the pick radius. The unselected weight is what makes
  // a link READ against a card's own surface at the default zoom: two world units
  // at a third of an alpha is a hairline that disappears into the card it arrives
  // at, which is the same thing as a graph that is not connected. The heavier
  // weight is the selected line and nothing else.
  //
  // The pick radius is SCREEN pixels converted through the zoom, because a
  // tolerance in world units would be 2.25 pixels at the smallest zoom and a line
  // that cannot be clicked at a zoom the user can reach to is not selectable.
  // That is the same reasoning as the handle tolerance, and the two numbers are
  // deliberately different: a line is a long thin target and a handle is a small
  // round one, so a line needs less slop than a handle does.
  readonly property real linkWeight: 2.5
  readonly property real linkWeightPicked: 3.5
  readonly property real curvePickReach: 8 / tab.zoom

  // An unpicked line's alpha, and why it is 0.7 rather than 0.5.
  //
  // The line carries a hue, so its alpha does not say only "not selected":
  // hue says which kind of card
  // the line LEAVES, and a hue at half an alpha is a hue pressed halfway toward
  // the ground it is drawn on - which costs the KINDS their separation by the
  // same factor, and separation is the whole reason the hue is there.
  //
  // Measured on this machine's palette, each hue composited over the canvas
  // ground and the distance between neighbouring composites taken in RGB:
  //
  //   alpha    green<->yellow    green<->blue    green dist from ground
  //   0.5          33.5             44.2               99.3
  //   0.7          47.8             60.2              139.6
  //
  // Every pair is further apart at 0.7 and every hue is further from the ground,
  // and 0.7 still reads as quieter than a card's own kind colour at 0.9 - the
  // line is connective tissue, the card is the subject.
  //
  // The picked line is untouched: accent, 0.9, and the heavier stroke. It has to
  // stay unmistakable, and it is the one line whose job is to be looked AT
  // rather than read.
  readonly property real linkAlpha: 0.7

  // The dash pattern of a line the mixer owns, in WORLD units: the painted on
  // length and the gap after it, before the zoom.
  //
  // World units rather than screen pixels, and the reason is the whole reason a
  // dashed line has to say anything: a dash pattern measured in pixels would
  // keep its screen size at every zoom and turn a zoomed-out line into a solid
  // smear, which is the exact opposite of what a dash is for. Stated in world
  // units it scales with the canvas like every other measurement here, so
  // zooming OUT sparsens the dash (fewer, proportionally larger marks on a
  // shorter line) and zooming in resolves it.
  //
  // The numbers are near `handleSize`: 16 units of dash against a 2.5-unit
  // stroke is a mark several stroke-widths long, so a dash reads as a dash at
  // 0.35x rather than dissolving into the stroke it is made of.
  //
  // The INK of a dash is longer than the dash, by one stroke width: the line
  // keeps the `RoundCap` every other line here has, and a round cap puts half a
  // stroke width past each end. Measured off the pixels at 1x and 2x, the ink
  // runs measure 18.7 world units and the gaps 7.4, against 16 and 10 asked for
  // - which is 16 + 2.5 and 10 - 2.5 to within the antialiasing. The pattern
  // itself is the two numbers above; the caps are the reason the drawn marks
  // are not exactly them.
  readonly property real linkDash: 16
  readonly property real linkGap: 10

  // Which line the pressed card is an end of, or "" for a fresh wire from a
  // port handle. Two gestures and one shape: a release either connects two
  // cards or moves a line that already exists, and this is what tells them
  // apart.
  property bool wiring: false
  // The side the wire left from, in the canvas's own spelling: 1 for the outputs
  // on the right edge, 0 for the inputs on the left. A wire taken from an input
  // is the same connect running the other way.
  property int wireFromSide: 0
  property string wireFromKey: ""
  property string wireLinkKey: ""
  // The grab point and the pointer, both in world units. Not the reason they are
  // world units rather than viewport units: the card that holds the grab reports
  // in its own frame, and this file is what knows the transform out of it.
  property real wireFromX: 0
  property real wireFromY: 0
  property real wireX: 0
  property real wireY: 0
  // The card under the pointer, or "" for none. Read from the release point as
  // well as from the last motion, so a wire released without ever moving lands
  // on the card it was pressed on rather than on nothing.
  property string wireDropKey: ""

  // The line selected by a click on the canvas, or "". The only selection there
  // is: nothing is armed any more, because a connect is a wire and a reroute is
  // that wire's own end.
  property string linkKey: ""
  // The refusal string of the last write the user asked for, or "". It is the
  // one thing on the canvas that outlives the gesture, because a write that
  // failed with nothing else to show reads as a canvas that ignored the drag.
  property string notice: ""

  readonly property var link: tab._linkGroup(tab.linkKey)
  // What letting go of the wire right now would write, or null for nothing.
  // One predicate for the whole drag: the rubber band's colour, the status line
  // and the release all have to agree about whether this drop writes anything.
  readonly property var wireTarget: tab._wireTarget()
  readonly property var status: tab._status()

  readonly property var curves: tab._buildCurves()

  // The viewport lines: the canvas's own status, kept apart from the window's
  // one status line, which reports the routing and card maps.
  readonly property string portNote: {
    const err = String(tab.controller === null ? "" : (tab.controller.portsError || ""))
    if (err !== "") return "port list unavailable"
    if (!tab.controller.portsReady) return "reading ports"
    return ""
  }

  // --- the card model ---
  //
  // One projection, run off a notification and not off a binding: the node set
  // arrives whole on every arrival and departure, and a binding over it would
  // rebuild the delegate array on every one of them. Coalesced behind the same
  // callLater-plus-timer pair the controller uses for the same reason.
  function _scheduleCards() {
    if (!tab.active) return
    Qt.callLater(() => cardTimer.restart())
  }

  function _rebuildCards() {
    const nodes = tab.controller === null ? [] : tab.controller.graphNodes
    const next = []
    for (let i = 0; i < nodes.length; i++) {
      // A node with no usable id is dropped rather than drawn with an empty
      // key. Such a card could never be found by a grip, would share a place
      // with every other such card, and would be a card nothing can be done
      // with. An unaddressable node is not one this canvas can act on.
      const key = Model.nodeKey(nodes[i])
      if (key === "") continue
      next.push({ key: key, node: nodes[i] })
    }
    const held = Graph.syncCards(tab._cards, next, Model.nodeKey)
    if (held === tab._cards) return
    tab._place(held)
    tab._cards = held
    tab._recomputeConnectable()
  }

  // node key -> whether this node can take part in a connect at all.
  //
  // "Unsupported" is decided by the PORT DATA and not by the kind: a node is
  // unsupported when no pair it could be an end of exists. That is three
  // conditions folded into one test, and each of them is one the user cannot
  // work out for themselves from a ring:
  //
  //   no ports at all            nothing to connect
  //   ports, no counterpart      `Graph.pairPorts` refuses every pairing of this
  //                              node's outputs against another node's inputs
  //                              AND every pairing the other way round, which
  //                              is what an output named `output_FROB` is: a
  //                              channel suffix no input on the graph shares
  //   ports and a counterpart    supported, even in ONE direction only: a sink
  //                              with no inputs is still worth connecting
  //                              something to
  //
  // An unsupported node is drawn dimmed with its port rings suppressed, so a
  // press on its edge never reaches the refusal it would otherwise get - there
  // is no affordance to press and so nothing to report. Genuine mid-gesture
  // refusals, a wire released over an incompatible card or a reroute onto a node
  // that will not take it, are still the controller's to make and to report.
  property var _connectable: ({})

  // One card's answer, and the one the delegate binds to.
  //
  // Absent means `true`: the map is empty while the ports have not been read,
  // and a card whose ports are not known is not a card to dim - it is a card
  // whose grips are not published yet, and `portsKnown` already says so on its
  // own line. Only an explicit `false`, which can only be written by the pass
  // below over a node it has actually tested, suppresses anything.
  function connectableOf(key) {
    return tab._connectable[key] !== false
  }

  // When the controller last finished reading ports, as this file's own copy.
  // Whether a card can be connected is a fact about the PORT ENUMERATION and
  // not about the node set, so a read that lands after the cards are placed is
  // what has to re-answer it. The controller's stamp is that signal: there is no
  // per-node port signal to subscribe to, because the port names are parsed out
  // of `pw-link` and nothing on the graph announces them.
  readonly property int portsAt: tab.controller === null
    ? 0 : Number(tab.controller.portsAt)

  onPortsAtChanged: tab._recomputeConnectable()

  function _recomputeConnectable() {
    if (tab.controller === null || tab.controller.portsReady !== true) {
      tab._connectable = ({})
      return
    }
    const cards = tab._cards
    const outs = []
    const ins = []
    const out = ({})
    for (let i = 0; i < cards.length; i++) {
      const name = Model.nodeName(cards[i].node)
      outs.push(Graph.recordsOf(tab.controller.outputPorts, name))
      ins.push(Graph.recordsOf(tab.controller.inputPorts, name))
      out[cards[i].key] = false
    }
    // Every ordered pair of distinct cards, once. A pairing is a fact about two
    // nodes, so one pass marks both ends: a card is connectable if some other
    // card's input can be paired with one of its outputs, or the other way
    // round. Quadratic in the card count, which is a handful here, and it runs
    // on a card arrival and on a port read rather than on a frame.
    for (let i = 0; i < cards.length; i++) {
      for (let j = 0; j < cards.length; j++) {
        if (i === j) continue
        if (out[cards[i].key] === true && out[cards[j].key] === true) continue
        if (outs[i].length > 0 && ins[j].length > 0
          && Graph.pairPorts(outs[i], ins[j]).pairs.length > 0) {
          out[cards[i].key] = true
          out[cards[j].key] = true
        }
      }
    }
    tab._connectable = out
  }

  // Every card's place.
  //
  // A card that is already placed keeps exactly where it was, and a card that is
  // new gets its slot from the LAYERED layout. That asymmetry is the whole of
  // "a card that stays must not move": the plan is recomputed on every rebuild,
  // because the topology it is derived from changes, but a card that already has
  // a place never reads the new plan again - so an arriving stream cannot shift
  // the filter beside it, and a new link cannot reflow the band under the user's
  // hands. Only `resetLayout` throws the map away and lays every card out again.
  //
  // This runs on an arrival as well as on a departure, so it is also where a node
  // that has LEFT stops being placed: a card nobody draws holding a place would
  // sit in the way of the next card to arrive, which is how a canvas slowly fills
  // with ghosts.
  function _place(cards) {
    const plan = Graph.layerPlan(tab._layoutNodes(cards), tab._graphGroups())
    const metrics = {
      cardW: tab.cardW,
      cardH: tab.cardH,
      gapX: tab.gapX,
      gapY: tab.gapY,
      margin: tab.margin
    }
    const slots = Graph.layerSlots(plan, metrics)
    const kept = ({})
    for (let i = 0; i < cards.length; i++) {
      const key = cards[i].key
      const at = tab._positions[key]
      if (at !== undefined && at !== null) {
        kept[key] = at
        continue
      }
      const slot = slots[key]
      kept[key] = slot === undefined || slot === null
        ? { x: tab.margin, y: tab.margin } : slot
    }
    tab._positions = kept
    tab._extent = Graph.layerExtent(plan, metrics)
  }

  // The layout's own inputs, in the plain shapes GraphModel.layerPlan takes: a
  // kind per node and nothing else, because the library holds no vocabulary of
  // its own and the canvas is what knows what a node is.
  //
  // `nodeKey` rather than `key`: a layout keyed by anything else is a layout over
  // a different identity, and the places map is keyed by the PipeWire id.
  function _layoutNodes(cards) {
    const entries = []
    for (let i = 0; i < cards.length; i++) {
      entries.push({ key: cards[i].key, kind: Model.classify(cards[i].node) })
    }
    return entries
  }

  // The link groups the layout is derived from: the same projection the curves
  // are built from, so the cards are laid out against the links that are DRAWN
  // and a card is never placed by a link the canvas is not showing.
  function _graphGroups() {
    if (tab.controller === null) return []
    const groups = tab.controller.graphLinks
    return Array.isArray(groups) ? groups : []
  }


  // A card with no place reads at the world's own margin rather than at the
  // origin, so a card that has not been laid out yet - which is a card the graph
  // published between two rebuilds - is drawn inside the world instead of on its
  // corner.
  function cardX(key) {
    const at = tab._positions[key]
    return at === undefined || at === null ? tab.margin : at.x
  }

  function cardY(key) {
    const at = tab._positions[key]
    return at === undefined || at === null ? tab.margin : at.y
  }

  function moveCard(key, dx, dy) {
    const at = tab._positions[key]
    if (at === undefined || at === null) return
    // The map is replaced rather than mutated in place: the delegates' x/y
    // bindings read it, and an in-place write would move the cards on screen
    // without re-running a single binding. One small map per pointer motion,
    // which is an interaction and not a frame callback.
    const next = ({})
    for (const k in tab._positions) next[k] = tab._positions[k]
    next[key] = { x: at.x + dx, y: at.y + dy }
    tab._positions = next
    tab._clampPan()
  }

  function nodeOf(key) {
    for (let i = 0; i < tab._cards.length; i++) {
      if (tab._cards[i].key === key) return tab._cards[i].node
    }
    return null
  }

  function labelOf(key) {
    return Model.label(tab.nodeOf(key))
  }

  // What the card at this key IS, or null for a key no card holds. The canvas's
  // own read of the same classification the card reads for its own stripe, and
  // it goes through the card's node rather than a map kept beside it, so a line
  // can never be coloured by a kind the card itself is not wearing.
  function kindOf(key) {
    return Model.classify(tab.nodeOf(key))
  }

  // --- pan and zoom ---
  //
  // The clamp keeps at least a corner of the canvas reachable: the bounds are
  // the viewport inset on one side and the world's own far edge on the other,
  // and a world smaller than the viewport is pinned at the origin rather than
  // being flung off it. A canvas the user can lose is a canvas that needs a
  // reset button to be usable, and the bound is cheaper than the button.
  //
  // The inset is the world's own margin rather than a literal, so the two ends of
  // the pan agree about how much edge to leave behind: the bound is stated once
  // and the world's own padding is built out of it.
  function _clampPan() {
    const edge = tab.margin
    const w = tab.worldW * tab.zoom
    const h = tab.worldH * tab.zoom
    const loX = Math.min(0, edge - w)
    const loY = Math.min(0, edge - h)
    const hiX = Math.max(0, Math.min(tab.viewW - edge, w - edge))
    const hiY = Math.max(0, Math.min(tab.viewH - edge, h - edge))
    tab.panX = Math.max(loX, Math.min(hiX, tab.panX))
    tab.panY = Math.max(loY, Math.min(hiY, tab.panY))
  }

  // Zoom about a point of the viewport. `k` is the ratio of the new scale to
  // the old, so the world point under the pointer is
  // `(at - pan) / zoom` before and `(at - pan') / zoom'` after; solving for
  // `pan'` is one multiplication and it is the whole of "the canvas follows
  // the pointer".
  //
  // Immediate, with no Behaviour on the zoom anywhere: an animated scale is a
  // canvas that keeps moving after the wheel has stopped, and a wheel is
  // already as immediate as the compositor allows.
  function zoomBy(notches, atX, atY, fine) {
    const step = fine === true ? tab.zoomStepFine : tab.zoomStep
    let next = tab.zoom * Math.exp(notches * step)
    if (next > tab.maxZoom) next = tab.maxZoom
    if (next < tab.minZoom) next = tab.minZoom
    if (next === tab.zoom) return
    const k = next / tab.zoom
    tab.panX = atX - (atX - tab.panX) * k
    tab.panY = atY - (atY - tab.panY) * k
    tab.zoom = next
    tab._clampPan()
  }

  // The cards' own extent in world units, or null when there are none. One walk
  // of the position map, which is what the view is fitted to and what the pan
  // clamp's own bound stands in for.
  function _contentBox() {
    let minX = Infinity
    let minY = Infinity
    let maxX = -Infinity
    let maxY = -Infinity
    for (const k in tab._positions) {
      const at = tab._positions[k]
      if (at === undefined || at === null) continue
      if (at.x < minX) minX = at.x
      if (at.y < minY) minY = at.y
      if (at.x + tab.cardW > maxX) maxX = at.x + tab.cardW
      if (at.y + tab.cardH > maxY) maxY = at.y + tab.cardH
    }
    if (!isFinite(minX) || !isFinite(minY)) return null
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
  }

  // The whole graph in the viewport, and never larger than 1:1.
  //
  // A view that resets to the origin is not "the whole graph" - on any graph
  // wider than the window it cuts the last column in half, and a cut card is a
  // card whose output handles are off the canvas, which is a card that cannot be
  // connected from where the user is looking. The fit never zooms IN past 1:1,
  // because a small graph blown up is not more readable than a small graph.
  function resetView() {
    const box = tab._contentBox()
    if (box === null) {
      tab.zoom = 1
      tab.panX = 0
      tab.panY = 0
      tab._clampPan()
      return
    }
    const pad = Ui.m
    const w = box.w + 2 * pad
    const h = box.h + 2 * pad
    let z = Math.min(tab.viewW / Math.max(1, w), tab.viewH / Math.max(1, h), 1)
    if (z < tab.minZoom) z = tab.minZoom
    if (z > tab.maxZoom) z = tab.maxZoom
    tab.zoom = z
    tab.panX = (tab.viewW - box.w * z) / 2 - box.x * z
    tab.panY = (tab.viewH - box.h * z) / 2 - box.y * z
    tab._clampPan()
  }

  // The layout, not the view: the cards go back on the layered layout and the
  // view goes back to the whole graph. The one thing on this canvas that throws
  // away something the user did on purpose, so it is a named action rather than
  // a side effect of anything else.
  //
  // It is also the only route by which an ALREADY-PLACED card re-reads the plan,
  // and that is the point of it: the plan is derived from the link topology, so
  // the chain a card was laid out against is the chain it is on now. Cards that
  // have not moved have kept their places all along.
  function resetLayout() {
    tab._positions = ({})
    tab._place(tab._cards)
    tab.resetView()
  }

  // --- the handles ---
  //
  // One card's port handles in one direction, as their y in that card's own
  // units. Computed here rather than in the card because the canvas draws the
  // far end of the line one of these handles starts and the card draws the
  // handle, and two copies of one layout rule is one rule that disagrees with
  // itself.
  //
  // Centred on the card's middle and stepped by the gap, so a card with one
  // port in a direction puts that mark where a line is anchored and a card with
  // several fans them either side of the same point. The gap shrinks as the
  // count grows rather than the band growing, so a node with many ports gets a
  // denser fan and never a handle above the name or below the port line.
  function portHandles(key, inputs) {
    if (tab.controller === null || tab.controller.portsReady !== true) return []
    const name = Model.nodeName(tab.nodeOf(key))
    if (name === "") return []
    const held = Graph.portsOf(
      inputs === true ? tab.controller.inputPorts : tab.controller.outputPorts, name)
    if (held.length === 0) return []
    const step = Math.min(tab.handleGapMax, tab.handleSpan / held.length)
    const out = []
    for (let i = 0; i < held.length; i++) {
      out.push(tab.cardH / 2 + (i - (held.length - 1) / 2) * step)
    }
    return out
  }

  // What one edge of one card carries, and it is the answer to THREE questions
  // that have to agree: where the drawn line meets the card, where a press takes
  // hold of that line's end to move it, and which mark is a port that already
  // has a line on it. Three readers of one answer is the point - a line and a
  // grip and a mark that each own a copy of "where does this edge's line start"
  // are three answers to one question, and they end up a mark apart.
  //
  //   marks  one entry per PORT on that edge, `{ y, linked }`: where the mark
  //          sits and whether a drawn line is standing on it.
  //   lines  one entry per drawn line on that edge, `{ y, key }`: where the
  //          line meets the card, and which line it is.
  //
  // A mark with no line keeps its place in `marks` and invents nothing: an
  // unused port is a port with nothing attached to it, and it is still the
  // target a new wire starts from. A line whose edge has no mark to land on
  // meets the card on the card's own middle instead: that is the honest answer
  // while the ports have not been read, because an edge nobody has read
  // cannot say where along it the line meets.
  //
  // The marks come from the INPUTS on side 0 and the OUTPUTS on side 1, which is
  // the one thing here spelled out rather than derived: the two edges are a
  // pair of sides and a pair of directions, and reading one for the other is an
  // edge that answers with the wrong fan. `side` is therefore a NUMBER, 0 or 1,
  // and the two tests below are strict: `true === 1` is false, so a boolean
  // here silently answers with the left edge's ports and the right edge's lines.
  function edgeAt(key, side) {
    const groups = tab._graphGroups()
    const slots = Graph.edgeSlots(groups)
    const ys = tab.portHandles(key, side !== 1)
    const lines = []
    for (let i = 0; i < groups.length; i++) {
      const group = groups[i]
      if (group === null || group === undefined) continue
      if ((side === 1 ? group.sourceKey : group.targetKey) !== key) continue
      lines.push({
        key: group.key,
        slot: side === 1 ? slots[i].from : slots[i].to
      })
    }
    for (let i = 0; i < lines.length; i++) {
      lines[i].y = tab._markY(ys, lines[i].slot, lines.length)
    }
    const marks = []
    for (let i = 0; i < ys.length; i++) {
      marks.push({ y: ys[i], linked: tab._lineOnMark(lines, ys[i]) })
    }
    return { marks: marks, lines: lines }
  }

  // Which mark line `slot` of `total` on that edge is drawn from:
  // `floor(slot * marks / total)`. One line per mark while the marks last, and
  // past that the lines spread back across the marks they have, so two lines on
  // an edge with fewer ports than lines land on different marks while marks
  // remain, and share one only when the edge has none left to give. The card's
  // own middle when the edge has no mark at all.
  function _markY(ys, slot, total) {
    if (ys.length === 0 || slot < 0 || total <= 0) return tab.cardH / 2
    return ys[Math.min(ys.length - 1, Math.floor(slot * ys.length / total))]
  }

  // Whether one of these lines meets the card exactly on this mark. Exact
  // equality rather than "near it", because both numbers are the same entry of
  // the same handle list: a mark a line stands on IS that line's mark, and a
  // mark near one is a mark nothing is attached to.
  function _lineOnMark(lines, y) {
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].y === y) return true
    }
    return false
  }

  // One edge's own entry for one line, or null. The route from a link group to
  // the two points its curve is drawn between: the curve's endpoint and the
  // grip that takes hold of that endpoint are one number read twice.
  function _lineOn(key, side, linkKey) {
    const list = tab.edgeAt(key, side).lines
    for (let i = 0; i < list.length; i++) {
      if (list[i].key === linkKey) return list[i]
    }
    return null
  }

  // --- the wire ---
  //
  // A press on a card's edge that took hold of something, and the wire leaves
  // from `localY` down that edge. `linkKey` is "" for a fresh wire from a port
  // mark and the line's own key for a grab of that line's endpoint, so the
  // release has one gesture and two commits. The y travels with the grab because
  // the two callers answer different edges: a mark's own place for a new wire,
  // and the drawn line's own end for a reroute, which is the point the user can
  // see.
  function beginWire(key, side, linkKey, localY) {
    const at = tab._edgePoint(key, side, localY)
    if (at === null) return
    tab.notice = ""
    tab.wiring = true
    tab.wireFromSide = side
    tab.wireFromKey = key
    tab.wireLinkKey = linkKey
    tab.wireFromX = at.x
    tab.wireFromY = at.y
    tab.wireX = at.x
    tab.wireY = at.y
    tab.wireDropKey = tab._cardAt(at.x, at.y)
  }

  // The pointer's travel, in the pressed card's own units and turned into world
  // units here: the card knows where it is and only this file knows the
  // transform. A drop target is recomputed per motion rather than watched for,
  // which is one walk of the delegate array and no subscription to maintain.
  function moveWire(key, localX, localY) {
    if (!tab.wiring) return
    tab.wireX = tab.cardX(key) + localX
    tab.wireY = tab.cardY(key) + localY
    tab.wireDropKey = tab._cardAt(tab.wireX, tab.wireY)
  }

  // The release, and the only place on this canvas that writes. Everything the
  // commit needs is read first and the wire is torn down before it is asked
  // for, so a refusal leaves no rubber band behind it and a second release
  // cannot repeat a write.
  function endWire(key, localX, localY) {
    if (!tab.wiring) return
    const fromKey = tab.wireFromKey
    const fromSide = tab.wireFromSide
    const linkKey = tab.wireLinkKey
    tab.moveWire(key, localX, localY)
    const dropKey = tab.wireDropKey
    tab._dropWire()
    tab.notice = ""
    // Released over nothing: the pointer was over no card at all, and there is
    // no pair the user named, so there is nothing to write.
    if (dropKey === "") return
    if (linkKey !== "") {
      tab._rerouteTo(linkKey, dropKey)
      return
    }
    tab._connectDrop(fromKey, fromSide, dropKey)
  }

  function _dropWire() {
    tab.wiring = false
    tab.wireFromKey = ""
    tab.wireLinkKey = ""
    tab.wireDropKey = ""
  }

  // The connect a released wire would make. A wire taken from an INPUT handle
  // runs the other way: the card under the pointer is the source and the card
  // the wire started on is the target, because the model is one line per
  // source -> target pair and the gesture that asks for one may run either way.
  function _connectDrop(fromKey, fromSide, dropKey) {
    if (tab.controller === null) return
    const sourceKey = fromSide === 1 ? fromKey : dropKey
    const targetKey = fromSide === 1 ? dropKey : fromKey
    // connectNodes composes the plan itself and returns the refusal string
    // instead of dispatching anything when the pair cannot be made, so the
    // refusal is reported here and there is no separate check to keep in step.
    const res = tab.controller.connectNodes(
      tab.nodeOf(sourceKey), tab.nodeOf(targetKey))
    if (res !== true) tab.notice = String(res)
  }

  function _rerouteTo(linkKey, dropKey) {
    if (tab.controller === null) return
    const group = tab._linkGroup(linkKey)
    if (group === null) return
    // A wire put back on the node it already goes to is not a reroute, and the
    // controller would compose it happily: a cut and a connect of the same
    // pair, which is a link removed and remade under somebody who is listening
    // to it because the pointer came home.
    if (group.targetKey === dropKey) return
    const res = tab.controller.rerouteLink(group, tab.nodeOf(dropKey))
    if (res !== true) tab.notice = String(res)
  }

  // Whether a connect between these two cards could write anything at all: both
  // nodes carry a port in the direction being connected, they are not the same
  // node, and the ports have been read. The pairing itself is NOT re-derived
  // here - which ports match is `pairPorts`' question and it answers it on the
  // release, where the answer costs nothing to be exact. This is the cheap
  // question a drag can ask on every pointer move without building a pair list,
  // so "there is nothing here to connect" is visible while the pointer is still
  // moving.
  function _canPair(sourceKey, targetKey) {
    if (tab.controller === null || tab.controller.portsReady !== true) return false
    if (sourceKey === "" || targetKey === "" || sourceKey === targetKey) return false
    const sourceName = Model.nodeName(tab.nodeOf(sourceKey))
    const targetName = Model.nodeName(tab.nodeOf(targetKey))
    if (sourceName === "" || targetName === "") return false
    return Graph.portsOf(tab.controller.outputPorts, sourceName).length > 0
      && Graph.portsOf(tab.controller.inputPorts, targetName).length > 0
  }

  // What letting go right now would write, or null. A pair the drag could make
  // and the line a reroute would move, both as the two node keys they are about,
  // which is also what the status line names and what the rubber band's colour
  // means.
  function _wireTarget() {
    if (!tab.wiring) return null
    if (tab.wireDropKey === "") return null
    if (tab.wireLinkKey !== "") {
      const group = tab._linkGroup(tab.wireLinkKey)
      // Neither of the two cards the line already joins is a destination for
      // it: one is where it already goes, and the other is where it already
      // comes from. Both refusals are the controller's to make and are reported
      // on the release; what is refused HERE is the promise, so a band over
      // either card is drawn as a band that writes nothing.
      if (group === null || group.targetKey === tab.wireDropKey
        || group.sourceKey === tab.wireDropKey) return null
      return {
        reroute: true,
        sourceKey: group.sourceKey,
        targetKey: tab.wireDropKey
      }
    }
    const sourceKey = tab.wireFromSide === 1 ? tab.wireFromKey : tab.wireDropKey
    const targetKey = tab.wireFromSide === 1 ? tab.wireDropKey : tab.wireFromKey
    if (tab._canPair(sourceKey, targetKey) === false) return null
    return { reroute: false, sourceKey: sourceKey, targetKey: targetKey }
  }

  // --- the lines ---
  //
  // One entry per link group, with the curve it is drawn along and the box that
  // curve is drawn in. A group whose two ends are not both on the canvas
  // contributes nothing: the alternative is a line to a card that is not there,
  // which is a line to nowhere.
  //
  // The box is the two anchors' own extent grown by the STROKE's half width,
  // which is all the stroke can reach past them. It is computed here rather than
  // sized from the world, so the stroke is always inside its own bounding
  // rectangle and never a world to the left of the world's origin: see the note
  // on the curve delegate.
  //
  // The padding is the stroke's own half width plus a unit of antialiasing, and
  // not a multiple of the span: the curve's control points sit inside the span
  // between the two anchors, so a span-relative pad would put every stroke's
  // box a card-width and a half wider than the line it holds, and a shape that
  // large costs a repaint of mostly empty space on a graph that repaints when
  // the topology moves.
  //
  // Rebuilt when a card moves and when the graph's links move, and NOT when the
  // zoom moves - the curve is in world units and the world is what is scaled,
  // so a zoom changes the viewport and not the geometry. It reads each end's
  // own line entry rather than a mark of its own choosing, so the curve, the
  // grip on its endpoint and the pick test are all the same two points: the
  // curve below is what `pickCurve` measures against, so a line whose ends
  // moved and whose pick geometry did not is a line that cannot be clicked.
  function _buildCurves() {
    const out = []
    if (tab.controller === null) return out
    const groups = tab.controller.graphLinks
    if (!Array.isArray(groups)) return out
    // The stroke's own half width at its heaviest, plus a unit of antialiasing.
    const pad = tab.linkWeight / 2 + 1
    for (let i = 0; i < groups.length; i++) {
      const group = groups[i]
      if (group === null || group === undefined) continue
      const leaving = tab._lineOn(group.sourceKey, 1, group.key)
      const arriving = tab._lineOn(group.targetKey, 0, group.key)
      if (leaving === null || arriving === null) continue
      const from = tab._edgePoint(group.sourceKey, 1, leaving.y)
      const to = tab._edgePoint(group.targetKey, 0, arriving.y)
      if (from === null || to === null) continue
      const curve = Graph.curveBetween(from.x, from.y, to.x, to.y)
      // The line wears the kind of the card it LEAVES, decided from the two ends'
      // own classifications rather than from anything the group carries: a group is
      // a pair of link ids and knows nothing about what either end is, so the hue
      // cannot come from here without being invented.
      const sourceKind = tab.kindOf(group.sourceKey)
      const targetKind = tab.kindOf(group.targetKey)
      // The one thing this canvas knows about a monitor leg is that it joins an
      // input device to an output device. See `Model.isMonitorLeg`.
      const monitor = Model.isMonitorLeg(sourceKind, targetKind)
      const sourceName = tab.labelOf(group.sourceKey)
      const targetName = tab.labelOf(group.targetKey)
      // The stroke's own half width at its heaviest, plus a unit of
      // antialiasing: the box is the curve's extent grown by exactly this, and
      // the path is written relative to it, so the stroke is inside its own
      // bounding rectangle whether it is solid or a dash. Both ends of the box
      // are known before the string is built, which is what lets the conversion
      // out of world units be the box's own corner - see `Graph.dashPath`.
      const box = {
        x: Math.min(from.x, to.x) - pad,
        y: Math.min(from.y, to.y) - pad,
        w: Math.abs(to.x - from.x) + 2 * pad,
        h: Math.abs(to.y - from.y) + 2 * pad
      }
      // A solid line is one run, so the delegate draws a dash and a plain line
      // through the same mechanism. See `Graph.dashRuns`.
      const runs = monitor
        ? Graph.dashRuns(curve, tab.linkDash, tab.linkGap)
        : Graph.dashRuns(curve, 0, 0)
      out.push({
        key: group.key,
        ids: group.ids,
        sourceKey: group.sourceKey,
        targetKey: group.targetKey,
        curve: curve,
        monitor: monitor,
        runs: runs,
        // Written against the box's own corner, exactly as the path element's
        // points were before this became a string: the curve stays in world
        // units in `curves` - which is what the pick radius and the anchors are
        // stated in - and only the painted copy is local.
        path: Graph.dashPath(runs, box.x, box.y),
        // Named rather than counted: the shape carries the pair's identity in
        // words, because a line's endpoints are the only thing about it a user
        // can be told.
        endpointText: sourceName + " to " + targetName,
        kindText: (sourceKind === null ? "node" : sourceKind) + " to "
          + (targetKind === null ? "node" : targetKind),
        colorKey: Model.kindColorKey(sourceKind),
        box: box
      })
    }
    return out
  }

  // A point on a card's edge in world units: the right edge for an output and
  // the left one for an input, because that is the direction audio flows and a
  // line that arrives from the right of its own target reads as flowing
  // backwards. `localY` is the offset down the card's own edge, and it is the
  // only thing that varies: the x is the edge itself for every caller, so a
  // line's endpoint and a port mark's press are both this at their own y.
  function _edgePoint(key, side, localY) {
    const at = tab._positions[key]
    if (at === undefined || at === null) return null
    return {
      x: at.x + (side === 1 ? tab.cardW : 0),
      y: at.y + localY
    }
  }

  // The card whose box holds this world point, or "". The first match in the
  // delegate order rather than the topmost, because two cards can be dragged on
  // top of each other and the delegate array is the only order this file has.
  function _cardAt(worldX, worldY) {
    for (let i = 0; i < tab._cards.length; i++) {
      const at = tab._positions[tab._cards[i].key]
      if (at === undefined || at === null) continue
      if (worldX < at.x || worldX > at.x + tab.cardW) continue
      if (worldY < at.y || worldY > at.y + tab.cardH) continue
      return tab._cards[i].key
    }
    return ""
  }

  // Whether a press on BARE canvas landed in a handle's band rather than on the
  // background, in world units.
  //
  // A handle is a mark centred ON the card's edge, so half of it is over the
  // plate and half over the canvas, and `handleReach` reaches further out still.
  // That leaves a band of empty canvas outside every card which is functionally
  // part of its edge - and this file's pan surface is the only thing under it,
  // because a card's own area is a rectangle and a point six pixels past its
  // right edge is not inside it. So a press that misses the ring by a hair
  // arrives here and pans the canvas, which is the opposite of what the press
  // was for.
  //
  // The surface asks this at press time rather than carrying an item for the
  // band, because the band is not a shape: it is a tolerance in world units
  // around an edge, it grows with the card and it moves with the card, and an item
  // sized to match it would be an item whose size is the tolerance and whose
  // position is a card edge - a second statement of both, free to disagree with
  // the card.
  //
  // So the pan surface refuses to start, and the press is deliberately then
  // dead: a press on the tolerance ring of a handle hit the mark's neighbourhood
  // and not the mark, and treating that as a click on the background (which
  // dismisses the selection) or as a pan are both worse than doing nothing.
  function _handleBandAt(worldX, worldY) {
    const reach = tab.handleReach
    for (let i = 0; i < tab._cards.length; i++) {
      const key = tab._cards[i].key
      const at = tab._positions[key]
      if (at === undefined || at === null) continue
      // The vertical extent is the card's own, not the band's: a press 40 world
      // units above a card's top corner is not near any of its handles, and
      // widening the vertical test that far would swallow the space above and
      // below every card.
      if (worldY < at.y || worldY > at.y + tab.cardH) continue
      const left = worldX < at.x + reach
      const right = worldX > at.x + tab.cardW - reach
      if (!left && !right) continue
      // A card with no handles on that side has no tolerance there: the band
      // belongs to the EDGE, and an edge with nothing on it is not a target.
      if (left && tab.portHandles(key, true).length === 0) continue
      if (right && tab.portHandles(key, false).length === 0) continue
      return true
    }
    return false
  }

  // The line under a click, or "". The click is in viewport units and the
  // curves are in world units, so the point is taken back through the
  // transform first, and the pick radius is scaled with it - a tolerance of a
  // fixed eight world units would be two and a quarter screen pixels at the
  // smallest zoom and unusable.
  function pickCurve(atX, atY) {
    const worldX = (atX - tab.panX) / tab.zoom
    const worldY = (atY - tab.panY) / tab.zoom
    const reach = tab.curvePickReach
    let best = ""
    let nearest = Infinity
    for (let i = 0; i < tab.curves.length; i++) {
      const d = Graph.curveDistance(worldX, worldY, tab.curves[i].curve)
      if (d > reach || d >= nearest) continue
      nearest = d
      best = tab.curves[i].key
    }
    return best
  }

  function _linkGroup(key) {
    if (key === "" || tab.controller === null) return null
    const groups = tab.controller.graphLinks
    if (!Array.isArray(groups)) return null
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].key === key) return groups[i]
    }
    return null
  }

  function clearPick() {
    tab.linkKey = ""
    tab.notice = ""
  }

  // The Disconnect chip's write, on the line a click named. The chip is standing
  // rather than armed: a click on a line is what names it, and the line it is
  // about is in the status line beside the button. A refusal is left in the
  // status line rather than thrown away, because it is the only thing that tells
  // the user their click did not reach the daemon.
  function commitDisconnect() {
    if (tab.controller === null) return
    const res = tab.controller.disconnectLink(tab.link)
    if (res === true) {
      tab.clearPick()
      return
    }
    tab.notice = String(res)
  }

  // Cut every link attached at one card edge, from a right-click on that edge's
  // handles. The fourth gesture on this canvas and the same write as the
  // Disconnect chip: `controller.disconnectLink`, on the same link group, through
  // the same one-child-per-link-id queue. There is no second route to a
  // `pw-link -d` and this is why - a right-click is a gesture on a card edge, and
  // the pairs it names are the pairs the endpoint-drag reroute would have
  // replaced, so it must remove exactly those and nothing else.
  //
  // Every group at that edge goes, not the first one: a stereo pair is ONE group
  // carrying two link ids and is one call, and a card edge with two groups on it
  // - two sources into one filter input - is two calls so a refusal on the first
  // stops the queue and leaves the second pair listening rather than half cut.
  // This is also why the groups are read in the graph's own order: that is the
  // order the panel prints them in.
  function cutEdge(key, side) {
    if (tab.controller === null) return
    const groups = tab._graphGroups()
    let held = null
    for (let i = 0; i < groups.length; i++) {
      const at = side === 1 ? groups[i].sourceKey === key : groups[i].targetKey === key
      if (!at) continue
      if (held === null) held = [groups[i]]
      else held.push(groups[i])
    }
    // The graph is the only thing that knows what is attached to an edge, and it
    // is what the canvas draws, so a link the graph has not reported cannot be
    // cut - which is why this reads the same list the curves are built from
    // rather than a cache of its own that could name a pair the canvas is not
    // drawing.
    //
    // Nothing here is a repair pass and nothing here retries: the write goes out
    // once per group and a refusal stops it, which is the same rule the
    // controller's queue already holds.
    // Nothing attached at that edge: there is no pair the user named, so there
    // is nothing to write and - unlike a genuine refusal - nothing to report.
    // The handle is still there and still pressable, because it is how the edge
    // is reached; a right-click on it is a press on nothing.
    if (held === null) return
    for (let i = 0; i < held.length; i++) {
      const res = tab.controller.disconnectLink(held[i])
      if (res !== true) {
        tab.notice = String(res)
        return
      }
    }
    // The cut went out and the graph will redraw; a selection naming one of these
    // lines must not survive it, because a Disconnect chip left enabled over a
    // line that is no longer there is a button that writes against nothing.
    tab.clearPick()
  }

  // The canvas's one line of status, and the priority order it is chosen in: a
  // gesture in hand, then the last refusal, then the port enumeration's own
  // state, then the selected line, then the vocabulary. A function rather than a
  // chain of nested bindings because the text and its colour have to agree about
  // which of those won, and two bindings reading the same order is two answers
  // to one question.
  function _status() {
    if (tab.wiring) {
      // Nothing under the pointer, nothing to say: the rubber band is already
      // the whole of the pending state.
      if (tab.wireDropKey === "") return { text: "", color: "" }
      if (tab.wireTarget === null) {
        return { text: "nothing to write here", color: Ui.tint("yellow", 0.9) }
      }
      return {
        text: (tab.wireTarget.reroute === true ? "move line: " : "link: ")
          + tab.labelOf(tab.wireTarget.sourceKey) + " -> "
          + tab.labelOf(tab.wireTarget.targetKey),
        color: Ui.tint("accent", 0.9)
      }
    }
    if (tab.notice !== "") return { text: tab.notice, color: Ui.tint("red", 0.9) }
    const err = tab.controller === null
      ? "" : String(tab.controller.graphError || "")
    if (err !== "") return { text: err, color: Ui.tint("red", 0.9) }
    if (tab.portNote !== "") {
      return { text: tab.portNote, color: Ui.tint("yellow", 0.9) }
    }
    if (tab.link !== null) {
      return {
        text: tab.labelOf(tab.link.sourceKey) + " -> " + tab.labelOf(tab.link.targetKey)
          + "   (link " + tab.link.ids.join(", ") + ")",
        color: Ui.solid("foreground_0")
      }
    }
    // The vocabulary, because the canvas's whole language is now a gesture and
    // a gesture cannot say what it is.
    return {
      text: "Drag from a port handle to another node to link them. "
        + "Drag a line's end to move it. Right-click a handle to unlink it.",
      color: Ui.tint("foreground_1", 0.6)
    }
  }

  Component.onCompleted: tab._scheduleCards()

  Connections {
    target: tab.controller
    function onGraphNodesChanged() { tab._scheduleCards() }
  }

  Timer {
    id: cardTimer

    interval: 75
    repeat: false
    onTriggered: tab._rebuildCards()
  }

  // Leaving the tab drops the selection and the wire in hand. A selection that
  // survived would be the first click of the next visit naming a line, and a
  // wire that survived would be a rubber band with no gesture attached to it:
  // the card holding the grab is destroyed with the model, so no release ever
  // arrives to end it.
  onActiveChanged: {
    if (tab.active) {
      tab._clampPan()
      tab._scheduleCards()
      return
    }
    cardTimer.stop()
    tab._dropWire()
    tab.clearPick()
  }

  // --- the canvas ---
  //
  // The box the graph is allowed to paint in, and the box every coordinate in
  // this file is stated in. Its top edge is the bottom of the chrome row, so the
  // hint line and the buttons are outside the canvas by construction rather than
  // by paint order, and `clip` makes that a scissor rather than a promise.
  //
  // Everything that speaks in viewport units lives in here - the pan surface,
  // the world and the dragged line - so `mouse.x`, the wheel's `event.x` and the
  // pan are all one frame with no conversion between them. The chrome is the one
  // thing outside, and that is the point.
  Item {
    id: canvas

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: chrome.bottom
    anchors.topMargin: Ui.s / 2
    anchors.bottom: parent.bottom
    clip: true

    // The pan surface and the line picker, in one area.
    //
    // Declared BEFORE the world, so the cards are above it: a later sibling is a
    // later hit target, and a pan surface on top would swallow every press on a
    // card and every drag of one. It paints nothing, so being underneath costs
    // no pixels.
    //
    // A middle-press that travels is a pan and nothing else; a left press
    // that does not is a pick, which is why the two share one MouseArea
    // rather than a Flickable and a delegate: there is no gesture here
    // that means both at once. A left press that travels is a dead
    // gesture - it pans nothing and, marked travelled, picks nothing.
    MouseArea {
      id: surface

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton

      // The press's own origin and the pan's base, captured once per gesture so
      // the motion handler is one subtraction rather than a subtraction from a
      // value it has to keep updating.
      property real px: 0
      property real py: 0
      property real baseX: 0
      property real baseY: 0
      property bool panned: false
      // Whether this press landed on a handle's tolerance band. Armed at press
      // and cleared on release, so the flag describes THIS gesture and never a
      // pointer merely passing over.
      property bool onHandle: false
      // Whether this press may pan: the middle button only, armed and
      // cleared with the gesture it belongs to.
      property bool midPress: false

      onPressed: function(mouse) {
        surface.px = mouse.x
        surface.py = mouse.y
        surface.baseX = tab.panX
        surface.baseY = tab.panY
        surface.panned = false
        surface.midPress = mouse.button === Qt.MiddleButton
        // Refuse the pan when the press was aimed at a handle and missed it, and
        // refuse the click too, for the reason on `_handleBandAt`. Computed from
        // the press's own point rather than from the last motion: a press and a
        // move are different moments and this is a question about the press.
        surface.onHandle = tab._handleBandAt(
          (mouse.x - tab.panX) / tab.zoom, (mouse.y - tab.panY) / tab.zoom)
      }
      onReleased: {
        surface.onHandle = false
        surface.midPress = false
      }
      onPositionChanged: function(mouse) {
        // A press that took hold of a handle's band is not a pan however far it
        // travels. The threshold is still measured so a press that DID travel is
        // marked as one, because the click below has to know the difference
        // between a pick and a drag on the same press.
        const dx = mouse.x - surface.px
        const dy = mouse.y - surface.py
        if (!surface.panned && Math.abs(dx) + Math.abs(dy) > 3) surface.panned = true
        if (!surface.panned || surface.onHandle || !surface.midPress) return
        tab.panX = surface.baseX + dx
        tab.panY = surface.baseY + dy
        tab._clampPan()
      }
      onClicked: function(mouse) {
        // Picks are a left-button gesture: a middle-click that travelled is
        // already refused as panned below, and one that did not must not
        // pick a line either.
        if (mouse.button !== Qt.LeftButton) return
        // A drag ends on a release too, and a release at the end of a pan is not
        // a pick: without this the canvas would pick whatever line the pointer
        // happened to be over at the far end of a pan.
        if (surface.panned) return
        // And a press that took hold of a handle's band is not a pick at all,
        // whether or not it travelled: see `_handleBandAt`.
        if (surface.onHandle) return
        const key = tab.pickCurve(mouse.x, mouse.y)
        // A click on nothing is the one dismissal this canvas has and it is the
        // one a click on the background is expected to be: it drops the selected
        // line and the last refusal. It does NOT cancel a wire - a wire is
        // ended by its own release, and a release that lands on the background is
        // over no card at all.
        if (key === "") {
          tab.clearPick()
          return
        }
        tab.notice = ""
        tab.linkKey = key
      }
    }

    // The world: the transform, and everything drawn in world units.
    //
    // The curves first and the cards second, so a card paints over the line that
    // arrives at it and the line never over the name the user is reading.
    Item {
      id: world

      x: tab.panX
      y: tab.panY
      scale: tab.zoom
      transformOrigin: Item.TopLeft
      width: tab.worldW
      height: tab.worldH

    Repeater {
      // Gated on `active` for the same reason the card Repeater is: an inactive
      // canvas builds no curve shapes either. The curve LIST underneath is still
      // kept current, because it is a cheap walk and it is what the canvas draws
      // the instant it becomes the tab on screen.
      model: tab.active ? tab.curves : []

      delegate: Shape {
        id: line

        required property var modelData

        // The shape's own box is this curve's own extent, and the path is
        // written relative to that box.
        //
        // A ShapePath is drawn in the SHAPE's own coordinates, so the shape's x
        // and y move the stroke with the box rather than only moving the box: a
        // shape parked at (-worldW, -worldH) to be large enough to avoid culling
        // draws a path whose world coordinates are 248 at x = 248 - worldW, which
        // is a whole world to the left of the world's origin and outside the
        // viewport at every pan and zoom that shows a card. The box is therefore
        // the curve's extent rather than the world's, and each point is spent one
        // subtraction against the box's own corner.
        //
        // An exact box also removes the culling a world-sized box is padded to
        // avoid: every point of the stroke is inside it by construction, and the
        // card it came from can be dragged anywhere without the stroke
        // following it out of its own bounding rectangle.
        x: line.modelData.box.x
        y: line.modelData.box.y
        width: line.modelData.box.w
        height: line.modelData.box.h

        // ONE ShapePath for the whole line, whatever its dash is. The stroke's colour
        // and weight live here and nowhere else, and the path is one string of
        // sub-cubics: a solid line is a string of one, so there is no second
        // place for a property to be set and no branch on which kind of line is
        // being drawn.
        ShapePath {
          // The hue is the kind of the card the line LEAVES, and the selection
          // state is over it: a line the user is holding is accent and wider
          // whatever feeds it, because "which one am I holding" has to beat
          // "what feeds this one" while the pointer is down on it.
          //
          // There is no dashed "pending" variant, because a connect that was
          // asked for and not yet granted is not a state this canvas is allowed
          // to draw. A dash is not that: it marks a link the mixer OWNS, which
          // is a fact about the graph rather than about a request.
          strokeColor: line.modelData.key === tab.linkKey
            ? Ui.tint("accent", 0.9) : Ui.tint(line.modelData.colorKey, tab.linkAlpha)
          strokeWidth: line.modelData.key === tab.linkKey
            ? tab.linkWeightPicked : tab.linkWeight
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap

          // The runs, as path commands: `M` to the start of each dash and a `C`
          // for the rest of it. Every command is a sub-cubic of the SAME curve
          // `curveDistance` measures, so the ink is on the line and the gaps are
          // on the line too - which is why a dashed line is still picked along
          // its whole length and not only on its dashes.
          PathSvg { path: line.modelData.path }
        }

        // A line is a graphic and not a control: clicking one SELECTS it through
        // the canvas surface beneath, not through this item, so there is no
        // action to announce here. What is worth announcing is the pair, because
        // a line otherwise carries no text at all - and its two endpoints are the
        // only description of it that is true at every zoom and every palette.
        //
        // The description names the two CLASSES as well as the two names, so the
        // information the hue carries visually is available without the hue.
        Accessible.role: Accessible.Graphic
        Accessible.name: line.modelData.endpointText
        Accessible.description: "link from " + line.modelData.kindText
          + (line.modelData.monitor ? ", dashed: the mixer's own monitor route" : "")
      }
    }

    Repeater {
      model: tab.active ? tab._cards : []

      delegate: GraphNode {
        required property var modelData

        x: tab.cardX(modelData.key)
        y: tab.cardY(modelData.key)
        width: tab.cardW
        height: tab.cardH
        node: modelData.node
        nodeKey: modelData.key
        portsKnown: tab.controller !== null && tab.controller.portsReady === true
        connectable: tab.connectableOf(modelData.key)
        // The whole edge answer, not just its marks: the card draws the marks
        // and presses the lines, and it is this file that knows where both are.
        // `0` and `1`, the sides as numbers: `true` is not `1` to a strict
        // comparison, so a boolean here answers with the other edge's fan.
        inEdge: tab.edgeAt(modelData.key, 0)
        outEdge: tab.edgeAt(modelData.key, 1)
        reach: tab.handleReach
        handleSize: tab.handleSize
        // One mark for a selected line's two ends and one for the card a wire
        // is over: both answer "what would this release or this click act on".
        linked: tab.link !== null && (modelData.key === tab.link.sourceKey
          || modelData.key === tab.link.targetKey)
        dropTarget: tab.wireTarget !== null
          && modelData.key === tab.wireTarget.targetKey
        onGrabbed: function(side, markY) {
          tab.beginWire(modelData.key, side, "", markY)
        }
        // The line this card names, and the point it meets the card at, so the
        // rubber band continues from the line's own end instead of from the
        // card's middle.
        onLineGrabbed: function(side, lineKey, anchorY) {
          tab.beginWire(modelData.key, side, lineKey, anchorY)
        }
        onCut: function(side) { tab.cutEdge(modelData.key, side) }
        onWireMoved: function(localX, localY) {
          tab.moveWire(modelData.key, localX, localY)
        }
        onWireEnded: function(localX, localY) {
          tab.endWire(modelData.key, localX, localY)
        }
        onDragged: function(dx, dy) { tab.moveCard(modelData.key, dx, dy) }
      }
    }
    }

    // The wire being dragged, over the world rather than inside it. Its ends are
    // in viewport units, so its stroke is a fixed number of pixels instead of one
    // that thins to nothing at the smallest zoom and fattens at the largest, and
    // the line stays visible where it crosses a card - which is where the pointer
    // is, and where the user is looking.
    Shape {
      id: wire

      anchors.fill: parent
      visible: tab.wiring

      // One shape and one path for the whole drag: a rubber band is a gesture, so
      // it costs a path whose four points move and nothing that has to be laid
      // out, walked or rebuilt. `Graph.curveBetween` is the same curve the drawn
      // links are made of, in viewport units rather than world ones, so the band
      // and a line it is pulling look like the same line. Its origin is the
      // canvas's, so it needs no offset of its own.
      readonly property var curve: Graph.curveBetween(
        tab.wireFromX * tab.zoom + tab.panX, tab.wireFromY * tab.zoom + tab.panY,
        tab.wireX * tab.zoom + tab.panX, tab.wireY * tab.zoom + tab.panY)

      ShapePath {
        // Accent only where letting go would write something. There is no dashed
        // "pending" variant: a connect that was asked for and not yet granted is
        // not a state this canvas is allowed to draw, and the band is not the
        // graph's to draw at all - it is the gesture's own mark and it is gone the
        // moment the gesture ends.
        strokeColor: tab.wireTarget === null
          ? Ui.tint("foreground_1", 0.55) : Ui.tint("accent", 0.9)
        // The band's own weight, in viewport units, and NOT `linkWeight`: that one is a
        // world-unit measurement for a stroke inside the scaled world, and this
        // shape is outside it. Two names for two spaces, because a band drawn at
        // a world-unit weight would thin to nothing at the smallest zoom - which
        // is the one zoom the user is dragging a wire at to fit the target on
        // screen.
        strokeWidth: 2.5
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        startX: wire.curve.x1
        startY: wire.curve.y1
        PathCubic {
          control1X: wire.curve.x2
          control1Y: wire.curve.y2
          control2X: wire.curve.x3
          control2Y: wire.curve.y3
          x: wire.curve.x4
          y: wire.curve.y4
        }
      }
    }

    // The wheel, taken here rather than by the window's body Flickable: that
    // Flickable is not the one on screen while this tab is up, and a canvas whose
    // zoom is a side effect of a scroll elsewhere is a canvas nobody can aim.
    //
    // A child of the canvas, so the wheel is taken over the canvas only. Over the
    // chrome the wheel belongs to whatever the chrome is under, and the position
    // it reports is in this item's units, which is the frame the pan is in.
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        const d = event.angleDelta.y
        if (d === 0) return
        // `x`/`y` and not `position`: QQuickWheelEvent publishes the pointer's
        // position under the two short names and has no `position` member, so
        // this is the wheel event's own coordinate pair rather than a
        // reconstructed one. `modifiers` is the same event's own modifier word,
        // which is what makes the fine step a modifier rather than a second
        // binding somewhere else.
        tab.zoomBy(d / 120, event.x, event.y,
          (event.modifiers & Qt.ControlModifier) === Qt.ControlModifier)
      }
    }
  }

  // --- the chrome ---
  //
  // A toolbar across the top of the viewport, not a panel across the foot of it,
  // and anchored to no armed operation because there is no armed operation: a
  // wire dragged from a port handle and released over a card IS the connect, and
  // a line's own end dragged onto a card IS the reroute. What is left to say is
  // the one line of status - what the gesture in hand would write, or the last
  // refusal - beside the standing actions that were never part of a gesture.
  //
  // A child of the tab and not of the canvas, so it does not pan and does not
  // scale: a refusal printed at 0.35 zoom is unreadable, and a button that moves
  // while the pointer is on it is a button that cannot be clicked. The canvas's
  // top edge is this row's bottom edge, so what the canvas may paint stops here
  // rather than merely being painted over.
  Row {
    id: chrome

    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Ui.m
    spacing: Ui.s

    GraphTabAction {
      text: "Rescan ports"
      onTriggered: tab.controller.refreshPorts()
    }

    GraphTabAction {
      text: "Reset layout"
      onTriggered: tab.resetLayout()
    }

    GraphTabAction {
      text: "Reset view"
      onTriggered: tab.resetView()
    }

    GraphTabAction {
      text: "Disconnect"
      danger: true
      enabled: tab.link !== null
      onTriggered: tab.commitDisconnect()
    }
  }

  Title {
    id: statusLine

    anchors.left: parent.left
    anchors.leftMargin: Ui.m
    anchors.right: chrome.left
    anchors.rightMargin: Ui.m
    anchors.verticalCenter: chrome.verticalCenter
    level: 5
    text: tab.status.text
    elide: Text.ElideRight
    // The status function's empty states carry no colour, and a Title with a
    // blank colour is a runtime error rather than an invisible one.
    color: tab.status.color !== "" ? tab.status.color : "transparent"
  }
}

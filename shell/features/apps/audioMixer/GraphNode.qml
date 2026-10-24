pragma ComponentBehavior: Bound

// One node on the graph canvas: an audio node's card.
//
// A card is a topology mark, not a mixer row. There is no fader here because
// every volume in this window already has one on the tab that owns the node,
// and a second fader per node on a canvas would be a second thing to drag and
// a second answer to "how loud is this". What the card carries is what the
// canvas itself needs - which kind of node it is, which client it belongs to,
// what it is playing, whether it is muted, that it is alive, whether it can be
// connected at all, and one handle per port to be connected with.
//
// The handles are the card's grip on the wire. The canvas owns the line being
// dragged and the pairing behind it, so this file draws a mark per port and
// reports which one a press took hold of. Their PLACES are handed in rather
// than computed here, because the canvas draws the far end of the line one of
// these handles starts and one layout rule has to serve both ends - two copies
// of it is one rule that disagrees with itself.
//
// A card whose ports cannot be paired with anything on the graph publishes no
// handles at all: it is drawn dimmed, it says so on its port line, and the press
// decision refuses its edges, so there is nothing to press and nothing to
// report. See `connectable` and `gripAt` below.
//
// The handles answer to three presses, and the three are separate flags on the
// card because they are separate outcomes: a LEFT press on one starts a wire, a
// right press on one cuts what is attached to that edge, and a press anywhere
// else moves the card. Only the first is reported as a grab, and the cut reports
// an edge rather than a grab, so a right-click cannot also leave a rubber band on
// screen. See `gripAt`, `cutAt` and the surface's `onPressed`.
//
// `LevelMeter` is this feature's pass-through into `qs.common`'s `LiveMeter`,
// which is what the bar's volume island and both mixer row types already draw.
// It is used here for the same reason they use it: one peak bar with one
// smoothing and one clip threshold, and the node peak scaled by the node's own
// volume in one place rather than in two.
//
// The peak hold is taken here and given back here, on the same terms as
// StreamRow's: only once the node's channel map is known, because Quickshell's
// monitor refuses a node whose channels are still Unknown, and the handle
// records the node it was taken on so a card handed a DIFFERENT node gives the
// old hold back before it takes a new one.
//
// Dragging is an interaction, not a binding: this file reports the pointer's
// travel and the canvas owns where cards live. Nothing here writes a position,
// and the only thing the graph hears from this file is the `cut` signal - which
// is a report of where the right-click landed, not a write, and the canvas
// decides what that means for the pairs already there.

import QtQuick
import qs.common
import qs.services as Core
import "MixerModel.js" as Model

Item {
  id: card

  required property var node
  // The PipeWire node id as a string, which is what the canvas keys positions,
  // selections and the link projection by. Spelled out rather than derived
  // here because the canvas is the thing that holds the map, and two keys for
  // one node is two things to disagree.
  required property string nodeKey
  // Whether the port enumeration has landed. It is a separate fact from the
  // edge answers, because "no ports" and "ports not read yet" are different
  // things to print and only one of them is about the node.
  property bool portsKnown: false
  // Whether this node can take part in a connect at all, as the canvas decided
  // it. See the definition in GraphTab next to `_recomputeConnectable`: a node is
  // unsupported when no pair it could be an end of exists, which is a fact about
  // the port data and not about the kind.
  //
  // An unsupported card is drawn dimmed and publishes no port marks, so there
  // is no grip on its edge to press and `gripAt` takes hold of nothing there.
  // That is the whole of the affordance: the user can see the card will not take
  // a wire before trying, and a press on its edge is a press that moves the card.
  property bool connectable: true
  // What this card's edges carry, one answer per edge and handed in whole:
  // `marks` is one entry per PORT on that edge (`{ y, linked }`) and `lines` is
  // one entry per DRAWN line standing on it (`{ y, key }`).
  //
  // The PLACES travel from the canvas rather than being computed here because
  // `PwNode` publishes no `ports` property in Quickshell 0.3.1 - the canvas
  // enumerates them with `pw-link` - and because the canvas draws the far end of
  // every line one of these marks starts. Three readers of one fact is the
  // point: a mark, a line's endpoint and the grip that takes hold of that
  // endpoint. Handing over the marks alone and letting this file place a line's
  // end on the card's middle is what put a drawn line's end eleven world units
  // from the mark the press answered to.
  property var inEdge: ({ marks: [], lines: [] })
  property var outEdge: ({ marks: [], lines: [] })
  // How far from a mark, and from a drawn line's own end, a press still counts
  // as landing ON it, in this card's own units. The canvas derives it
  // from the DRAWN MARK rather than stating it beside the mark: the tolerance is
  // the mark's radius plus a floor of screen pixels, so the hit region is always
  // the mark and a little more, and a mark that grows grows its target with it.
  // Stated apart, the two drift: a ring taken from 8 to 14 world units with an
  // 11-pixel tolerance still in place leaves the outer quarter of the ring
  // answering to nothing at 2x, and a press there falls through to the
  // background, which pans the canvas instead of taking hold of the node.
  //
  // Its value at the smallest zoom is large enough that two fanned marks are
  // closer together than the tolerance itself, which is why the press decision
  // below compares distances rather than trying candidates in an order.
  property real reach: 8
  // The drawn mark's own diameter, in this card's units. Published by the canvas
  // for the same reason it publishes `reach`: it derives the tolerance above from
  // this, and derives the gap between two marks from it as well, so all three
  // numbers are one measurement rather than three that can disagree.
  property int handleSize: 14
  // The two marks this card can carry, both answering the same question - what
  // the next click, or the next release, acts on - so they are the same
  // question and the same visual weight. `linked` is an end of the selected
  // line; `dropTarget` is the card a dragged line is over.
  property bool linked: false
  property bool dropTarget: false

  // A press that took hold of a port mark, reporting which edge it came from
  // and where that mark is. The canvas draws the wire from there, so the y is
  // the MARK's place and not the press's: a press four pixels off the mark has
  // to start the wire on the mark.
  signal grabbed(int side, real markY)
  // A press that took hold of a drawn line's end instead. It names WHICH line and
  // WHERE that line meets this card, because both are facts of the edge rather
  // than of the press: the canvas draws the rubber band from the same two
  // numbers the curve's end was drawn from, so a reroute takes hold at the end
  // the user can see rather than at the card's middle.
  signal lineGrabbed(int side, string linkKey, real anchorY)
  // A right-click that took hold of a mark's edge, naming the side. The canvas
  // owns what is attached there and owns the only route that removes it, so this
  // file reports the edge and not the links: the link list is not on this card,
  // and a card that asked the graph which pairs it is an end of would be a card
  // deciding which links exist.
  signal cut(int side)
  // The pointer's travel and the release, in this card's own unscaled units.
  // Reported in the card's frame because the card is what holds the grab, and
  // turned into world units by the canvas, which owns the transform.
  signal wireMoved(real localX, real localY)
  signal wireEnded(real localX, real localY)
  // The pointer's travel since the press, for a move of the card itself. The
  // canvas adds it to the card's stored place. Reported rather than applied
  // because the position belongs to the canvas, which is what survives a card
  // being rebuilt.
  signal dragged(real dx, real dy)

  // --- the node, read live ---
  //
  // Read off the node every frame the card paints rather than snapshotted, for
  // the reason DeviceRow and StreamRow read the same two properties live: the
  // graph changes them, and a cached level is a stale level. These are valid
  // reads because the controller holds the one node-set observation.
  readonly property var audio: card.node !== null && card.node !== undefined
    && card.node.audio !== undefined ? card.node.audio : null
  readonly property real volume: card.audio !== null ? Number(card.audio.volume) : 0
  readonly property bool muted: card.audio !== null ? card.audio.muted === true : false
  readonly property string kind: Model.classify(card.node)

  // The kind's own glyph, through the model's media-class map rather than a
  // second table here: `Audio/Sink` is a speaker and `Stream/Output/Audio` is a
  // music note wherever the shell decides that, and this file is not the place
  // that decision lives. A node whose class the map does not know gets the
  // link glyph, which is the honest answer for a node that exists to join two
  // others.
  readonly property string kindIcon:
    Model.iconForMediaClass(Model.propText(card.node, "media.class")) || "link"

  // The palette KEY this kind is drawn in, read from the library that owns the
  // pairing rather than written out here. The canvas's lines read the same
  // function for the same four kinds, so the two files cannot disagree about
  // what colour a playback stream is - and the reasoning behind the four hues
  // lives with `classify`, which is where the kinds themselves come from.
  //
  // A card wears it on the stripe and the glyph, because a card is identified
  // by more than its text: an application names its own capture streams after
  // its own SOURCES, so two cards can carry the same words and differ only in
  // what they are.
  readonly property string kindKey: Model.kindColorKey(card.kind)

  readonly property string kindColor:
    Ui.tint(card.kindKey, card.muted ? 0.35 : 0.9)

  // Two lines of name, and WHICH string goes on which of them is the whole of a
  // card's identity: the client first, what it is carrying second, and never the
  // same string twice.
  //
  // An application names its capture streams after its own SOURCES - OBS
  // publishes "Desktop Audio" for two of them and calls both that - so a card
  // that leads with `label()` prints "Desktop Audio" on two cards and says OBS on
  // neither. `appName` prefers `application.name` over `media.name`, so a stream
  // leads with the client behind it; a device leads with what the driver called
  // the hardware, which is the only name it has.
  readonly property string titleText: Model.isStreamKind(card.kind)
    ? Model.appName(card.node) : Model.label(card.node)

  // What it is carrying. Dropped rather than repeated when it IS the title: a
  // stream whose application label and media name are the same string ("Spotify")
  // would otherwise print it twice, and two lines that agree are one line with
  // extra space in it.
  readonly property string detailText: {
    const media = Model.mediaName(card.node)
    if (media === "" || media === card.titleText) return ""
    return media
  }

  // The port line, and the states it can be in. A node whose enumeration
  // has not landed says so, because "0 in / 0 out" beside a card the user is
  // trying to connect reads as a dead node rather than as a canvas that has
  // not read the graph yet. The counts are the handle lists' lengths, so the
  // line and the grips can never disagree about how many ports there are.
  //
  // A node that HAS ports and no counterpart anywhere says so instead of
  // printing them: the counts are then an invitation with nothing behind it, and
  // "not connectable" is the fact the canvas already drew the card's dimming
  // from.
  readonly property string portText: !card.portsKnown ? "ports not read"
    : (card.inEdge.marks.length + card.outEdge.marks.length === 0 ? "no ports"
      : (card.connectable
        ? card.inEdge.marks.length + " in / " + card.outEdge.marks.length + " out"
        : "not connectable"))

  // --- the grips ---
  //
  // The card is ONE MouseArea and the grips are a region of it, not extra hit
  // targets stacked on top of it. A separate item per mark would have to be
  // sized in world units to stay grabbable at the smallest zoom, and an item
  // over the card's edge is an item that ends up over the mute control. Inside
  // the card the tolerance is a distance test instead, which is the same
  // arithmetic the canvas runs to pick a line and costs nothing extra to keep
  // correct at any zoom.
  //
  // The marks hang half off the plate, so the hit rect reaches past them into
  // bare canvas by the same tolerance: negative margins bound to `reach`, not
  // a second measurement, so the ring and the test cannot disagree. A press
  // out there that takes no grip is released in onPressed, so the extension
  // never steals background gestures - it only stops the outer half of every
  // visible mark answering to nothing.
  //
  // `side` is the canvas's own spelling: 1 for the outputs on the right edge,
  // 0 for the inputs on the left. One convention covers the marks, the line's
  // two ends and the origin of the dragged line.
  //
  // The two edges are tested rather than one, because the tolerance can reach
  // further than the card is wide at the smallest zoom: a tolerance of 25 world
  // units on a card twice that wide still leaves the middle to itself, and this
  // is the test that says so. `cutAt` below reuses this and therefore lands on
  // the same edge a left press would.
  function _edgeSide(localX) {
    if (localX >= card.width - card.reach) return 1
    if (localX <= card.reach) return 0
    return -1
  }

  // One edge's marks, so the readers below spell the side once rather than three
  // times and a change to that spelling is a change in one line.
  function _marks(side) {
    return side === 1 ? card.outEdge.marks : card.inEdge.marks
  }

  // The mark nearest a press on one edge, or -1 when none is within reach.
  // Nearest rather than first, because at the smallest zoom the tolerance is
  // wider than the gap between two marks and only the distance can say which
  // one the pointer was nearer.
  function _nearestMark(side, localY) {
    const list = card._marks(side)
    let best = -1
    // From the tolerance, not from `_markDistance`: that one clamps at the
    // tolerance and returns it for a press that is already ON a mark, which
    // as a starting bound would exclude the mark it just found.
    let nearest = card.reach
    for (let i = 0; i < list.length; i++) {
      const d = Math.abs(Number(list[i].y) - localY)
      if (d >= nearest) continue
      nearest = d
      best = i
    }
    return best
  }

  // How far the press is from the nearest mark on this edge, or `reach` when
  // none is within it. Clamped at `reach` rather than at infinity so a press
  // that is nowhere near either candidate compares as "nothing is close" on
  // both sides and takes neither.
  function _markDistance(side, localY) {
    const list = card._marks(side)
    let nearest = card.reach
    for (let i = 0; i < list.length; i++) {
      const d = Math.abs(Number(list[i].y) - localY)
      if (d < nearest) nearest = d
    }
    return nearest
  }

  // The drawn line's own end nearest a press on this edge, or null. Null IS the
  // "no line is anchored here" answer, because the search is clamped at `reach`:
  // a press with nothing within the tolerance finds nothing rather than
  // reporting a line it cannot reach.
  //
  // The entry is returned whole rather than a distance, because a press that
  // takes hold of this line also has to say WHICH line it took hold of, and the
  // edge's own list is what names it. That is what keeps two lines on one edge
  // apart: each is grabbed at its own end, not at the first line this edge
  // happens to carry.
  function _nearestLine(side, localY) {
    // An unsupported card takes hold of nothing on its edges. Its edge lists are
    // still filled - the canvas draws this card's edges whatever this card can be
    // connected to - so the refusal is here, or the press would offer a grip on
    // an end that is not drawn.
    if (!card.connectable) return null
    const list = side === 1 ? card.outEdge.lines : card.inEdge.lines
    let best = null
    let nearest = card.reach
    for (let i = 0; i < list.length; i++) {
      const d = Math.abs(Number(list[i].y) - localY)
      if (d >= nearest) continue
      nearest = d
      best = list[i]
    }
    return best
  }

  // The drawn line's end this press would take hold of on that edge, or null:
  // the nearest one, and only while it is at least as near as the nearest mark.
  // `gripAt` below carries the whole of why a tie goes to the line, and `cutAt`
  // reuses this so a right-click lands on the candidate a left press would.
  function _lineUnder(side, localY) {
    const line = card._nearestLine(side, localY)
    if (line === null) return null
    if (Math.abs(Number(line.y) - localY) > card._markDistance(side, localY)) return null
    return line
  }

  // What a press at this point took hold of, and the whole of it: a grip on a
  // port mark, a grip on a drawn line's end on that edge, or nothing at all - in
  // which case the press is the card's own and moves it.
  //
  // A function of the coordinates rather than the body of a signal handler, so
  // the decision is one thing with one answer whether it came from a pointer or
  // from a drive of this card's own arithmetic.
  //
  // NEAREST of the two candidates, not the line first. The tolerance is a mark's
  // radius plus a screen-pixel floor, which at the smallest zoom is wider than
  // half a card's height - and two ports fanned around the middle put both of
  // them inside one tolerance of it. An order that tried the line first would
  // therefore take the line everywhere on a two-port card and leave no way to
  // start a wire from one.
  //
  // A TIE goes to the line, and a tie is now every mark a line stands on rather
  // than only a card with a single port in this direction: a line's end is drawn
  // ON a mark, so the two candidates are the same point and every comparison on
  // that mark is the comparison of a number with itself. The line therefore owns
  // its own end, which is what makes a reroute one gesture and what every node
  // editor does with a port that carries something.
  //
  // The cost is stated rather than hidden: on an edge whose every mark carries a
  // line there is no grip left on that edge, so a wire onto that card is started
  // from the SOURCE's free mark and dropped on the card, which is the same
  // gesture and the only pair of ports it can name. Measured on this machine:
  // `eq_input`'s two input ports carry three links each, so both its marks carry
  // a line and neither of them starts a wire.
  function gripAt(localX, localY) {
    // An unsupported card takes hold of nothing on its edges. The check is here
    // and not only in the drawing because the drawing is not the contract: this
    // is the one function every press on an edge goes through, so one line here
    // is what makes "no affordance to press" true rather than merely visible.
    if (!card.connectable) return false
    const side = card._edgeSide(localX)
    if (side < 0) return false
    const line = card._lineUnder(side, localY)
    if (line !== null) {
      card.wiring = true
      card.lineGrabbed(side, line.key, Number(line.y))
      return true
    }
    const index = card._nearestMark(side, localY)
    if (index < 0) return false
    card.wiring = true
    card.grabbed(side, Number(card._marks(side)[index].y))
    return true
  }

  // Which edge a RIGHT-CLICK landed on, or -1 for none: the same edge test and
  // the same two candidates as `gripAt`, reported and nothing else.
  //
  // A second function rather than an argument on `gripAt` because the two
  // presses must not share its side effects. A right-click that reached `gripAt`
  // would raise the wire flag and report a grab, and the press would be a wire in
  // hand as well as a cut - which is how a right-click ends up starting a band
  // and dragging the world around on its way to disconnecting something.
  //
  // The EDGE and not the line, because a cut here is what the canvas does with
  // the pairs at that edge: a stereo pair is one group and one call, and an edge
  // with two groups on it is two. Which of them the press landed on is not
  // asked, and cannot be: the cut is the edge.
  //
  // -1 means the press took hold of the CARD rather than of a mark. A card has
  // no click action of its own, so that is nothing happening, which is what a
  // right-click on a card's body already meant.
  function cutAt(localX, localY) {
    if (!card.connectable) return -1
    const side = card._edgeSide(localX)
    if (side < 0) return -1
    if (card._lineUnder(side, localY) !== null) return side
    return card._nearestMark(side, localY) >= 0 ? side : -1
  }

  // --- the peak hold ---
  //
  // `PipeWireState` owns one monitor per node and hands out refcounted holds,
  // so a meter per card is one monitor per node however many cards draw it.
  // A hold latched at construction would meter the node that left and refuse
  // the node that arrived, so the node it was taken on is recorded beside it.
  property var peak: null
  property var _peakNode: null

  Component.onCompleted: card._syncPeak()
  Component.onDestruction: card._releasePeak()
  onNodeChanged: card._syncPeak()

  Connections {
    target: card.audio
    function onChannelsChanged() { card._syncPeak() }
  }

  function _syncPeak() {
    if (card._peakNode !== card.node) card._releasePeak()
    if (card.peak !== null) return
    const node = card.node
    if (node === null || node === undefined || node.audio === null
      || node.audio === undefined) return
    if (!Model.channelsKnown(node.audio.channels)) return
    const handle = Core.PipeWireState.acquirePeaks("audioMixer/graph", node)
    if (handle === null) return
    card.peak = handle
    card._peakNode = node
  }

  function _releasePeak() {
    card._peakNode = null
    if (card.peak === null) return
    Core.PipeWireState.releasePeaks(card.peak)
    card.peak = null
  }

  function toggleMute() {
    if (card.audio === null) return
    card.audio.muted = !card.audio.muted
  }

  // --- the press, as a measurement ---
  //
  // The press point, whether the pointer has travelled far enough to count as a
  // drag, and whether this press took hold of a wire instead of the card. Three
  // fields rather than a threshold comparison against a stored x and y on every
  // motion, so the decision is made once per gesture and the motion handler
  // does one subtraction.
  property real pressX: 0
  property real pressY: 0
  property bool travel: false
  property bool wiring: false
  // Whether this press was a right-click that took hold of a handle. Its own flag
  // rather than `wiring`, because the two presses are opposites: `wiring` means
  // this card owns a line in flight and must not move, and `cutting` means this
  // card has already reported a cut and must not move either - but only one of
  // them may be set at a time, and one flag cannot say which.
  property bool cutting: false

  Rectangle {
    id: plate

    anchors.fill: parent
    radius: RoundingPolicy.radius
    // The card's own surface, not the window's: the canvas has no rows, so a
    // card that borrowed a row's background would read as a row that happened
    // to land on a canvas.
    //
    // An unsupported card's surface is faded rather than recoloured, because
    // colour is now carrying the kind: a dimmed surface and a dimmed name read as
    // "not usable" without taking the kind's colour away from the stripe.
    color: card.linked ? Ui.tint("accent", 0.09)
      : (card.connectable ? Ui.solid("background_2") : Ui.tint("background_2", 0.45))
    border.width: card.linked ? 2 : 1
    border.color: card.linked
      ? Ui.tint("accent", 0.7)
      : (card.connectable ? Ui.tint("background_3", 0.8) : Ui.tint("foreground_1", 0.14))

    Behavior on color { ColorAnim {} }
    Behavior on border.color { ColorAnim {} }
  }

  // The kind's stripe, across the card's top edge: three units of the kind's own
  // palette key, under the name row and clear of the port band. A card's identity
  // is its client first and its kind second, and the stripe is what tells two
  // cards apart when their text is the same string.
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 3
    color: card.kindColor
  }

  // The card a dragged line is over. A separate item from the plate so it can
  // carry no Behavior: the pointer crosses from one card to the next faster
  // than a colour animation can follow, and a highlight that lags the pointer
  // names the wrong card.
  Rectangle {
    anchors.fill: parent
    radius: RoundingPolicy.radius
    color: "transparent"
    border.width: 2
    border.color: Ui.tint("accent", 0.85)
    visible: card.dropTarget
  }

  // Declared before every control, so the controls take the press and this
  // area is only reached where there is no control: a card with a mute button
  // on it must not swallow the button's own click. A press on a grip is decided
  // here too, which is the one way this area can mean something other than
  // "this card".
  MouseArea {
    id: surface

    anchors.fill: parent
    anchors.leftMargin: -card.reach
    anchors.rightMargin: -card.reach
    // The right button is accepted so it can reach the grip decision below rather
    // than falling through this area to whatever is under it. Accepting it is
    // what stops a right-click from becoming a pan: a button this area does not
    // take is a button the pan surface behind the world does not see either,
    // and a right-click beside a handle is exactly the press that pans.
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // A CLICK on the card does nothing at all. A connect is a drag from a port
    // handle and a reroute is a drag from a line's end, so there is no click on
    // a card that means a specific pair - and a click that armed a destination
    // the user never chose is exactly the confirm-step syntax this replaced. The
    // card's own drag is a move, and it is the only thing a left press on it
    // does.
    //
    // A press near an edge reaches the grip decision in gripAt(); the
    // coordinates are the card's own, which is the frame the tolerance and the
    // handle list are both stated in.
    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        // A right-click is a cut and nothing else: `cutAt` reports which edge it
        // landed on without raising the wire flag, and the motion and release
        // handlers below both return on `card.cutting`, so the same press cannot
        // also move the card or leave a band on screen.
        const side = card.cutAt(mouse.x, mouse.y)
        if (side < 0) {
          // Outside the plate with no edge in reach this press is not the
          // card's: release it so it reaches whoever is under it.
          if (mouse.x < 0 || mouse.x > card.width || mouse.y < 0 || mouse.y > card.height)
            mouse.accepted = false
          return
        }
        card.cutting = true
        card.cut(side)
        return
      }
      card.pressX = mouse.x
      card.pressY = mouse.y
      card.travel = false
      card.wiring = false
      if (card.gripAt(mouse.x, mouse.y)) return
      // A press inside the plate that took no grip moves the card; outside
      // it the press belongs to whoever is under it (the pan surface), so
      // the extended hit rect above never steals background gestures.
      if (mouse.x < 0 || mouse.x > card.width || mouse.y < 0 || mouse.y > card.height)
        mouse.accepted = false
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      // A press that took hold of a wire reports travel and nothing else: a
      // card the user is pulling a line from must not also slide away from
      // that line.
      if (card.wiring) {
        card.wireMoved(mouse.x, mouse.y)
        return
      }
      // Nor does a right-click that took hold of a handle: it is a cut, and a
      // cut that also dragged the card two hundred units across the canvas would
      // be cutting a link the user can no longer see.
      if (card.cutting) return
      if (Math.abs(mouse.x - card.pressX) > 2 || Math.abs(mouse.y - card.pressY) > 2) {
        card.travel = true
      }
      card.dragged(mouse.x - card.pressX, mouse.y - card.pressY)
    }
    onReleased: function(mouse) {
      if (card.cutting) {
        card.cutting = false
        return
      }
      if (!card.wiring) return
      card.wiring = false
      card.wireEnded(mouse.x, mouse.y)
    }
    // A grab stolen by another item, a window losing the pointer, a teardown: the
    // release never arrives, so both flags are given back here or the next press
    // on this card inherits a gesture that is not its own.
    onCanceled: {
      card.cutting = false
      card.wiring = false
    }

    // A grouping rather than a button: a card is moved by a drag and connected
    // by a grip, and it has no click action of its own to announce. The mute
    // control inside it is the one button, and it says so.
    Accessible.role: Accessible.Grouping
    Accessible.name: card.titleText
    Accessible.description: card.kind + ", " + card.portText
  }

  Item {
    id: head

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Ui.s
    height: 16

    Icon {
      id: glyph

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      name: card.kindIcon
      // The kind's own key, so the glyph and the stripe above it cannot disagree
      // about what this card is. A muted card keeps its kind and loses its
      // weight, which the stripe's alpha already carries.
      colorKey: card.muted ? "foreground_1" : card.kindKey
      size: 15
    }

    Title {
      id: nameText

      anchors.left: glyph.right
      anchors.leftMargin: Ui.s
      anchors.right: mute.left
      anchors.rightMargin: Ui.s
      anchors.verticalCenter: parent.verticalCenter
      level: 3
      text: card.titleText
      elide: Text.ElideRight
      color: card.muted ? Ui.tint("foreground_1", 0.5)
        : (card.connectable ? Ui.solid("foreground_0") : Ui.tint("foreground_1", 0.6))
    }

    // The mute affordance, and the island's: the glyph carries the level, the
    // tiered paths carry its colour, and the click is the toggle. The same
    // control as the stream row's, because it is the same node property.
    Item {
      id: mute

      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: 16
      height: 16

      Icon {
        anchors.centerIn: parent
        name: card.audio === null ? "volume-off"
          : Core.Audio.volumeIconFor(card.volume, card.muted)
        colorKey: card.muted ? "red" : "foreground_1"
        accentKey: card.muted ? "red" : ""
        dimTiers: card.audio === null ? 0
          : Core.Audio.volumeDimTiersFor(card.volume, card.muted)
        size: 15
      }

      MouseArea {
        anchors.fill: parent
        enabled: card.audio !== null
        cursorShape: card.audio !== null ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: card.toggleMute()
      }

      Accessible.role: Accessible.CheckBox
      Accessible.name: "Mute " + card.titleText
      Accessible.checked: card.muted
    }
  }

  Title {
    id: detailText

    anchors.left: head.left
    anchors.right: head.right
    anchors.top: head.bottom
    // `implicitHeight` unconditionally, with `visible` doing the hiding. The
    // conditional form - `height: visible ? implicitHeight : 0` - is the same
    // thing written as a cycle: `height` feeds the implicit size the card
    // itself is sized from, and Qt reports "binding loop detected for property
    // height" on every card. An invisible item takes no space either way.
    height: implicitHeight
    level: 4
    text: card.detailText
    elide: Text.ElideRight
    visible: text !== ""
  }

  // The live bar, UNDER the names and at the card's own width, for the reason
  // every meter in this app is under its own control: a level that cannot be
  // lined up with the name above it is a decoration.
  LiveMeter {
    id: meter

    anchors.left: head.left
    anchors.right: head.right
    anchors.top: detailText.visible ? detailText.bottom : head.bottom
    anchors.topMargin: Ui.s / 2
    height: 4
    peakHandle: card.peak
    // Peak taps are pre-volume, so the bar is scaled by the node's own level:
    // a node at 20% must never paint full scale.
    gain: card.volume
    muted: card.muted
  }

  Title {
    id: portText

    anchors.left: head.left
    anchors.right: head.right
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Ui.s / 2
    level: 5
    text: card.portText
    elide: Text.ElideRight
    color: card.connectable || !card.portsKnown
      ? Ui.tint("foreground_1", 0.55) : Ui.tint("yellow", 0.8)
  }

  // --- the marks ---
  //
  // One mark per port, on the edge that port is on, centred on the edge so half
  // of each mark is over the plate and half is over the canvas: a line arrives
  // AT the edge, and a mark drawn inside the card would not be where the line's
  // end is.
  //
  // Shape carries the SIDE and colour says the same thing again. An input is a
  // ring and an output is a solid disc, because two identical dots give the user
  // nothing to aim at and nothing to tell them which way a wire runs, and the
  // difference has to survive the smallest zoom - so it is in the shape rather
  // than in a hue that four screen pixels would swallow. The ring keeps a hole
  // at every zoom because its thickness scales with the mark.
  //
  // The COLOURS, and the discipline they are chosen under:
  //
  //   input    purple    hollow ring
  //   output   orange    solid disc
  //
  // Four palette keys are already the four node KINDS and a card shows its own in
  // its stripe and its glyph - green a playback stream, red a capture stream,
  // blue an output device, yellow an input device - so a mark in any of those four
  // reads as "this is the kind of this card". `accent` is out for the reason the
  // kinds already state: it is the user's own choice and on more than one of the
  // 30 palettes shipped here it resolves to the same colour as `blue`. That
  // leaves `purple` and `orange`, and they are the best pair of what is left:
  // `orange` is the theme's `accent` in none of the 30, `purple` in four
  // (catppuccin), and over the same 30 palettes `purple` is never nearer than 45
  // RGB units to a kind colour while `orange` closes to 21 on catppuccin-macchiato
  // against yellow. A soft collision is not a collision: the mark is a mark on the
  // card's edge and the kind is a stripe along its top.
  //
  // LINKED is a third thing a mark says, and it is the one a user acts on: this
  // port already has a line on it, so a press here takes hold of that line rather
  // than starting a new one. It is drawn as a rim OUTSIDE the mark, so the mark's
  // own shape still says the side and the tab still reads with no colour at all.
  //
  // Painted last, so a mark is never half hidden by the name behind it, and
  // sized in this card's own units like everything else on the card. The card is
  // what shrinks when the canvas zooms out; what has to stay the same size on
  // screen is the TOLERANCE around it, which is `reach` and which the canvas
  // derives from `handleSize`.
  //
  // The marks are painted and never hit-tested. They are items with no input,
  // because the card's own area is what answers a press and it answers it with a
  // distance test against this card's whole tolerance - see `gripAt`. A mark that
  // took input would need a hit area sized in SCREEN pixels inside a card drawn in
  // world units, which is an item whose size has to be recomputed on every zoom of
  // a card whose own size does not change.
  component Handle: Item {
    id: grip

    required property int diameter
    // True for an input on the left edge, false for an output on the right.
    required property bool input
    // Whether a drawn line meets the card on this mark. From the canvas's edge
    // answer rather than from "this edge has a line", which would put a rim on
    // every mark of an edge when only one of them carries one.
    required property bool linked
    // The side's own palette key, from the mapping above. Two keys and not the
    // card's kind key: what this mark is FOR and what this card IS are two
    // different facts, and the kind has a colour of its own already.
    readonly property string sideKey: grip.input ? "purple" : "orange"
    // How far the rim sits off the mark, which is also the slack the grip keeps
    // on every side so the mark's CENTRE - what `portHandles` placed and what the
    // press tolerance is measured from - does not move when the rim appears.
    readonly property int rim: 2

    width: grip.diameter + 2 * grip.rim
    height: width

    // What this mark is, in words: which edge it is on and what a drag from it
    // does. It restates the shape and the rim rather than adding a third answer,
    // and it is the only place that can say what the mark DOES - a ring and a
    // disc describe the shape and nothing else.
    readonly property string side: grip.input
      ? "input port on the left edge; drag it onto another node to link that node into this one"
      : "output port on the right edge; drag it onto another node to link this node into that one"
    readonly property string stateText: grip.linked
      ? "A link is attached here, so a drag from this mark moves that link's end."
      : "Nothing is attached here yet."

    Rectangle {
      id: mark

      anchors.centerIn: parent
      width: grip.diameter
      height: width
      radius: width / 2
      color: grip.input ? "transparent" : Ui.solid(grip.sideKey)
      // A quarter of the mark, so the hole a ring leaves is a sixth of it and the
      // ring is still a ring rather than a dot with a lighter dot in it.
      border.width: grip.input ? Math.max(2, Math.round(width / 4)) : 0
      border.color: Ui.tint(grip.sideKey, 0.9)
    }

    // The rim, outside the mark and drawn only on a mark a line stands on. Its
    // own colour is the side's at a lower weight: the rim is a second fact about
    // the same mark, not a third hue.
    Rectangle {
      anchors.centerIn: parent
      width: parent.width
      height: width
      radius: width / 2
      color: "transparent"
      border.width: grip.rim
      border.color: Ui.tint(grip.sideKey, 0.6)
      visible: grip.linked
    }

    Accessible.role: Accessible.Graphic
    Accessible.name: grip.side
    Accessible.description: grip.stateText
  }

  Repeater {
    model: card.connectable ? card.outEdge.marks : []

    delegate: Handle {
      required property var modelData

      diameter: card.handleSize
      input: false
      linked: modelData.linked === true
      x: card.width - width / 2
      y: Number(modelData.y) - height / 2
    }
  }

  Repeater {
    model: card.connectable ? card.inEdge.marks : []

    delegate: Handle {
      required property var modelData

      diameter: card.handleSize
      input: true
      linked: modelData.linked === true
      x: 0
      y: Number(modelData.y) - height / 2
    }
  }
}

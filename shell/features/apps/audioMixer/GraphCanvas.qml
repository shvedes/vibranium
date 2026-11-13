pragma ComponentBehavior: Bound

// qmllint disable unqualified
// `host` is the tab, and it stays untyped: this component is part of the same
// module as GraphTab, so naming that type here does not resolve either (the
// members then read as unqualified exactly as they do now). The members are
// checked at runtime, and construction-test builds this type with its host.


// The graph canvas: the viewport, the world, the cards and the wire.
//
// This is the half of the tab that paints and hit-tests. Its state and its
// decisions stay on the tab (`host`): the pan and zoom values, the card places,
// the pairing rules, the wire's own state machine and every controller write.
// Nothing here decides anything - it reads `host`, renders it, and reports a
// pointer gesture back through the host's functions. The `host` hop is the
// contract, not a convenience: a canvas that owned a second copy of the pan, or
// of which card a point is over, would be a second answer to a question the tab
// has already answered.
//
// The one thing that is local is the canvas's own frame: `width`/`height` are
// the viewport the pan clamp is stated in (see `host.viewW`), and everything in
// here - the pan surface, the wheel's event coordinates, the rubber band - is
// in that frame with no conversion between them.
//
// Lines are Shape paths, never Canvas repaints: a Shape repaints when its path
// properties change, so a graph that has not moved costs nothing to draw.

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

import QtQuick
import QtQuick.Shapes
import qs.common
import "GraphModel.js" as Graph

Item {

  // The tab that owns the state this canvas renders.
  required property var host

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
        surface.baseX = host.panX
        surface.baseY = host.panY
        surface.panned = false
        surface.midPress = mouse.button === Qt.MiddleButton
        // Refuse the pan when the press was aimed at a handle and missed it, and
        // refuse the click too, for the reason on `_handleBandAt`. Computed from
        // the press's own point rather than from the last motion: a press and a
        // move are different moments and this is a question about the press.
        surface.onHandle = host._handleBandAt(
          (mouse.x - host.panX) / host.zoom, (mouse.y - host.panY) / host.zoom)
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
        host.panX = surface.baseX + dx
        host.panY = surface.baseY + dy
        host._clampPan()
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
        const key = host.pickCurve(mouse.x, mouse.y)
        // A click on nothing is the one dismissal this canvas has and it is the
        // one a click on the background is expected to be: it drops the selected
        // line and the last refusal. It does NOT cancel a wire - a wire is
        // ended by its own release, and a release that lands on the background is
        // over no card at all.
        if (key === "") {
          host.clearPick()
          return
        }
        host.notice = ""
        host.linkKey = key
      }
    }

    // The world: the transform, and everything drawn in world units.
    //
    // The curves first and the cards second, so a card paints over the line that
    // arrives at it and the line never over the name the user is reading.
    Item {
      id: world

      x: host.panX
      y: host.panY
      scale: host.zoom
      transformOrigin: Item.TopLeft
      width: host.worldW
      height: host.worldH

    Repeater {
      // Gated on `active` for the same reason the card Repeater is: an inactive
      // canvas builds no curve shapes either. The curve LIST underneath is still
      // kept current, because it is a cheap walk and it is what the canvas draws
      // the instant it becomes the tab on screen.
      model: host.active ? host.curves : []

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
          strokeColor: line.modelData.key === host.linkKey
            ? Ui.tint("accent", 0.9) : Ui.tint(line.modelData.colorKey, host.linkAlpha)
          strokeWidth: line.modelData.key === host.linkKey
            ? host.linkWeightPicked : host.linkWeight
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
      model: host.active ? host._cards : []

      delegate: GraphNode {
        required property var modelData

        x: host.cardX(modelData.key)
        y: host.cardY(modelData.key)
        width: host.cardW
        height: host.cardH
        node: modelData.node
        nodeKey: modelData.key
        portsKnown: host.controller !== null && host.controller.portsReady === true
        connectable: host.connectableOf(modelData.key)
        // The whole edge answer, not just its marks: the card draws the marks
        // and presses the lines, and it is this file that knows where both are.
        // `0` and `1`, the sides as numbers: `true` is not `1` to a strict
        // comparison, so a boolean here answers with the other edge's fan.
        inEdge: host.edgeAt(modelData.key, 0)
        outEdge: host.edgeAt(modelData.key, 1)
        reach: host.handleReach
        handleSize: host.handleSize
        // One over the zoom: this file paints the card in world units, and the
        // mark inside it has to hold one screen size. See `handleReach` above.
        markScale: 1 / host.zoom
        // One mark for a selected line's two ends and one for the card a wire
        // is over: both answer "what would this release or this click act on".
        linked: host.link !== null && (modelData.key === host.link.sourceKey
          || modelData.key === host.link.targetKey)
        dropTarget: host.wireTarget !== null
          && modelData.key === host.wireTarget.targetKey
        // The mark the wire would stand on, handed in as a place on the edge it
        // arrives at: the card's marks are its own list, and a place is what
        // both sides already speak.
        dropSide: host.wireSnap === null ? -1 : host.wireSnap.side
        dropY: host.wireSnap !== null && host.wireSnap.key === modelData.key
          ? host.wireSnap.localY : -1
        onGrabbed: function(side, markY) {
          host.beginWire(modelData.key, side, "", markY)
        }
        // The line this card names, and the point it meets the card at, so the
        // rubber band continues from the line's own end instead of from the
        // card's middle.
        onLineGrabbed: function(side, lineKey, anchorY) {
          host.beginWire(modelData.key, side, lineKey, anchorY)
        }
        onCut: function(side) { host.cutEdge(modelData.key, side) }
        onWireMoved: function(localX, localY) {
          host.moveWire(modelData.key, localX, localY)
        }
        onWireEnded: function(localX, localY) {
          host.endWire(modelData.key, localX, localY)
        }
        onDragged: function(dx, dy) { host.moveCard(modelData.key, dx, dy) }
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
      visible: host.wiring

      // The band's far end is the port the release would meet, when there is
      // one: see `wireSnap`. A band over nothing follows the pointer, because
      // there is no mark it is heading for.
      readonly property var tip: host.wireSnap

      // One shape and one path for the whole drag: a rubber band is a gesture, so
      // it costs a path whose four points move and nothing that has to be laid
      // out, walked or rebuilt. `Graph.curveBetween` is the same curve the drawn
      // links are made of, in viewport units rather than world ones, so the band
      // and a line it is pulling look like the same line. Its origin is the
      // canvas's, so it needs no offset of its own.
      readonly property var curve: Graph.curveBetween(
        host.wireFromX * host.zoom + host.panX, host.wireFromY * host.zoom + host.panY,
        (wire.tip === null ? host.wireX : wire.tip.x) * host.zoom + host.panX,
        (wire.tip === null ? host.wireY : wire.tip.y) * host.zoom + host.panY)

      ShapePath {
        // Accent only where letting go would write something. There is no dashed
        // "pending" variant: a connect that was asked for and not yet granted is
        // not a state this canvas is allowed to draw, and the band is not the
        // graph's to draw at all - it is the gesture's own mark and it is gone the
        // moment the gesture ends.
        strokeColor: host.wireTarget === null
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
        host.zoomBy(d / 120, event.x, event.y,
          (event.modifiers & Qt.ControlModifier) === Qt.ControlModifier)
      }
    }
}

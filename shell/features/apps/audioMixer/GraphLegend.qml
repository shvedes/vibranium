// The canvas's legend.
//
// The canvas's whole language is a mark and a gesture, and neither can say
// what it is: a hollow ring and a solid disc are the two ends of a wire and
// nothing in the picture says which is which, a hue names a kind only to
// someone who already knows the four, and "drag from here to there" is not
// written on a drag. So the tab says it, in the tab, and only while it is
// asked for: the panel lies over the canvas rather than beside it, because it
// is read once and the canvas is what the user came for.
//
// Every kind colour here is READ from `MixerModel.kindColorKey`, which is the
// one place that pairing is written down, so a legend that disagreed with the
// cards would have to be wrong twice. The two port keys are the same pair the
// card's own marks are drawn in (`GraphNode`'s `Handle`).
//
// It hangs off the button that opens it and stays closed until that click. Its
// right edge is the chrome row's right edge, which is the info button's - the
// button is the last thing in that row - because a bubble that does not point
// at its trigger is a panel that has to be hunted for. Anchoring to the ROW
// rather than to the button is an anchors rule, not a preference: this item is
// the row's sibling, and an anchor can only name a parent or a sibling.

import QtQuick
import QtQuick.Shapes
import qs.common
import "MixerModel.js" as Model

// Its ground is the shell's own tooltip ground (`IconButton`'s bubble), so it
// reads as the same kind of object as every other hint in the tree.
//
// It swallows its own presses. A press on a sentence must not pan the canvas
// under it, and the pan surface is the canvas's, not the tab's - so the panel
// has to take the press rather than passing it down.
Rectangle {
  id: root

  // Whether the tab's info button has the panel open.
  property bool open: false
  // The chrome row the panel hangs under, and whose right edge it shares. Null
  // leaves the panel unanchored, which is what a construction probe gets.
  property Item anchorItem: null

  // A port mark as the legend draws it: the same two shapes with the same two
  // palette keys as the cards' marks, at label size. A picture of the mark and
  // not the mark itself - the canvas's marks are sized against a press
  // tolerance and grow under the pointer, neither of which a legend row needs.
  //
  // Declared INSIDE the root: an inline component is a member of the object it
  // is declared in, and a `component` at the top level of a file is a syntax
  // error rather than a file-scoped type.
  component LegendPort: Shape {
    id: legendPort

    property bool input: true
    property bool linked: false

    readonly property int size: 14
    readonly property string sideKey: legendPort.input ? "purple" : "orange"
    readonly property real ringW: Math.max(1.5, legendPort.size / 4.5)
    readonly property real bodyR: legendPort.size / 2
    readonly property real ringR: legendPort.input
      ? legendPort.bodyR - legendPort.ringW / 2 : legendPort.bodyR
    readonly property real rimR: legendPort.bodyR + 1.5

    width: legendPort.size + 6
    height: width
    antialiasing: true

    ShapePath {
      fillColor: legendPort.input ? "transparent" : Ui.solid(legendPort.sideKey)
      strokeColor: legendPort.input ? Ui.tint(legendPort.sideKey, 0.9) : "transparent"
      strokeWidth: legendPort.input ? legendPort.ringW : 0

      PathAngleArc {
        centerX: legendPort.width / 2
        centerY: legendPort.height / 2
        radiusX: legendPort.ringR
        radiusY: legendPort.ringR
        sweepAngle: 180
      }

      PathAngleArc {
        centerX: legendPort.width / 2
        centerY: legendPort.height / 2
        radiusX: legendPort.ringR
        radiusY: legendPort.ringR
        startAngle: 180
        sweepAngle: 180
      }
    }

    ShapePath {
      fillColor: "transparent"
      strokeColor: legendPort.linked ? Ui.tint(legendPort.sideKey, 0.6) : "transparent"
      strokeWidth: 1.5

      PathAngleArc {
        centerX: legendPort.width / 2
        centerY: legendPort.height / 2
        radiusX: legendPort.rimR
        radiusY: legendPort.rimR
        sweepAngle: 180
      }

      PathAngleArc {
        centerX: legendPort.width / 2
        centerY: legendPort.height / 2
        radiusX: legendPort.rimR
        radiusY: legendPort.rimR
        startAngle: 180
        sweepAngle: 180
      }
    }
  }

  // A kind's colour as the card's own top stripe draws it: three units of the
  // kind's palette key, from the mixer's classifier rather than from a literal.
  component LegendChip: Rectangle {
    property string kind: ""

    width: 3
    height: 12
    radius: 1.5
    color: Ui.solid(Model.kindColorKey(kind))
  }

  // The dash a monitor leg is drawn with, at label size: three marks and the
  // gaps between them, which is the pattern and not a second description of it.
  component LegendDash: Row {
    spacing: 3
    height: 16

    Repeater {
      model: 3

      Rectangle {
        y: 7
        width: 6
        height: 2
        radius: 1
        color: Ui.tint("foreground_1", 0.6)
      }
    }
  }

  // One legend sentence: body text rather than a row's muted subtitle, because
  // it is read at rest and has to be legible without being the subject.
  component LegendText: Title {
    level: 5
    wrapMode: Text.WordWrap
    elide: Text.ElideNone
    color: Ui.tint("foreground_1", 0.8)
  }

  anchors.top: root.anchorItem ? root.anchorItem.bottom : undefined
  anchors.right: root.anchorItem ? root.anchorItem.right : undefined
  anchors.topMargin: 6
  width: Math.min(320, Math.max(0, (root.parent ? root.parent.width : 0) - 2 * Ui.m))
  height: helpBody.implicitHeight + 2 * Ui.m
  visible: root.open
  radius: RoundingPolicy.radius
  color: Ui.solid("background_0")
  border.width: 1
  border.color: Ui.solid("background_3")
  z: 1

  MouseArea { anchors.fill: parent }

  Column {
    id: helpBody

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Ui.m
    spacing: Ui.s

    Title {
      level: 2
      text: "PORTS"
    }

    Row {
      spacing: Ui.s

      LegendPort { input: true }
      LegendText { text: "input, drag to link" }
    }

    Row {
      spacing: Ui.s

      LegendPort { input: false }
      LegendText { text: "output, drag to link" }
    }

    Row {
      spacing: Ui.s

      LegendPort {
        input: true
        linked: true
      }
      LegendText { text: "a ring means a link is attached" }
    }

    Title {
      level: 2
      text: "COLORS"
    }

    Row {
      spacing: Ui.s

      LegendChip { kind: "playbackStream" }
      LegendText { text: "playback" }
      Item {
        width: Ui.s
        height: 1
      }
      LegendChip { kind: "captureStream" }
      LegendText { text: "capture" }
    }

    Row {
      spacing: Ui.s

      LegendChip { kind: "outputDevice" }
      LegendText { text: "output" }
      Item {
        width: Ui.s
        height: 1
      }
      LegendChip { kind: "inputDevice" }
      LegendText { text: "input" }
    }

    Row {
      spacing: Ui.s

      LegendDash {}
      LegendText { text: "monitor route" }
    }

    Title {
      level: 2
      text: "GESTURES"
    }

    LegendText {
      width: helpBody.width
      text: "Drag a line's end to reroute it."
    }

    LegendText {
      width: helpBody.width
      text: "Drag a card to move it."
    }

    LegendText {
      width: helpBody.width
      text: "Right-click a mark to disconnect it."
    }

    LegendText {
      width: helpBody.width
      text: "Wheel zooms, middle-drag pans."
    }
  }
}

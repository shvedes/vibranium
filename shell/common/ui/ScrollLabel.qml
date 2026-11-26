pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../motion/Marquee.js" as Marquee

// A one-line label that SCROLLS when it does not fit instead of losing its
// tail to an ellipsis: a pause so the head can be read, an eased leg to the
// far end, a pause there, and a leg back. One implementation for the mixer
// chips, the clipboard's path rows, the launcher sub lines and the bar's
// Now Playing / Downloader islands. The leg time comes from
// common/motion/Marquee.js rather than from a number written at a call site,
// so there is one opinion about how long a leg takes. A focus-gated caller can
// also hand its scroll back: closing its gate reverses from the offset the leg
// was interrupted on instead of placing the head in one frame.
//
// A wrapper rather than a Text, because the label inside has to be WIDER than
// the box that shows it: the caller anchors this item exactly as it anchored
// the Text it replaces (left/right or width, vertical centre), `clip` keeps
// the overflow from painting over neighbouring chrome, and the Title inside
// is free to travel. `text`, `level` and `color` are aliases onto that Title,
// so a call site reads as it did before - and one that sets no color keeps
// the level's own, because an unset alias does not override the binding
// underneath it.
//
// The knobs below (`font*`, `textFormat`, `idleElide`, the two pause lengths,
// `opticalCenter`) are pass-throughs for the sites that used to hand-roll the
// animation. Defaults are exactly the mixer chip's old look: level-driven
// Title typography, right elide at rest, a 1200ms head pause and the shared
// 400ms endpoint pause.
Item {
  id: root

  property alias text: label.text
  property alias level: label.level
  property alias color: label.color

  // Presentation pass-throughs. An unset alias leaves the Title's own
  // level-derived binding in place, so the mixer chips keep their type.
  property alias fontFamily: label.font.family
  property alias fontSize: label.font.pixelSize
  property alias fontBold: label.font.bold
  property alias fontUnderline: label.font.underline
  property alias fontStrikeout: label.font.strikeout
  property alias fontFeatures: label.font.features
  property alias textFormat: label.textFormat
  property alias horizontalAlignment: label.horizontalAlignment

  // Which elide a label uses when it is NOT travelling. Title's default is
  // ElideRight; a path row needs ElideLeft so the file name survives, and a
  // clipped hover-gated title needs ElideNone so it is cut rather than
  // ellipsised.
  property int idleElide: Text.ElideRight

  // Title nudges a vertically-centred label down by ~8% of its pixel size to
  // sit on cap height. That is right for a chip, but the rows that hand-rolled
  // this marquee centred their Text geometrically; they opt out here so their
  // paint position does not move by a pixel when they adopt this component.
  property bool opticalCenter: true

  // Timing. The head beat is a local reading pause; the end beat is the
  // shell-wide value. A row that starts moving immediately sets the first to
  // 0, and nothing has to reach into the animation to change it.
  property int startPauseMs: 1200
  property int endpointPauseMs: Marquee.endpointPauseMs()

  // The caller's own gate, on top of the shell's motion policy: a chip whose
  // row is closing, a list whose item is not current, or a title whose island
  // is shut stops here rather than animating under a label nobody is looking
  // at.
  //
  // NOT named `enabled`: that is Item's own, and shadowing it here would both
  // silence the item and lie about what the flag does - this one stops the
  // marquee, not the label.
  property bool scrolling: true

  // The text's own width, so a call site that sizes its slot from the label
  // (the chips do: preferred width is the label plus their chrome) still
  // measures the text and not the box.
  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight
  clip: true

  readonly property real overflow: Math.max(0, label.implicitWidth - root.width)
  readonly property bool scrollable: root.scrolling
    && Marquee.scrollable(overflow)
  readonly property int legMs: Marquee.legMs(overflow)

  // A row that gives its scroll up when focus leaves it opts in here. Closing
  // the gate then glides the label home from the offset the leg was cut on;
  // every other caller keeps the instant reset, since a chip that is closing
  // or an island that is shut has no audience for a return leg.
  property bool returnOnGateClose: false

  // The label keeps its full width and no elide until the handback lands, so
  // the text cannot reflow under the animation. The running flag is the single
  // source of that state; nothing else writes it.
  readonly property bool _returning: returnLeg.running
  readonly property bool travelling: root.scrollable || root._returning

  // Back to the start, and running or stopped. Every way the content can
  // change - a new width, a new string - comes through here, and so does a
  // gate opening on a label that is already home.
  function reset() {
    returnLeg.stop()
    label.x = 0
    // Read the raw inputs, not the `scrollable` binding: a gate handler can
    // run before that binding has re-evaluated, and a stale false would leave
    // the leg stopped with nobody left to start it.
    if (root.scrolling && Marquee.scrollable(label.implicitWidth - root.width)) leg.restart()
    else leg.stop()
  }

  // Gate closing on a row that was mid-leg: reverse from the live offset
  // instead of placing the head in one frame. The leg's onStopped parks x at
  // the head first, so the return leg carries the captured offset itself.
  // Its duration is scaled to that offset, not to the full overflow: a title
  // cut near the head parks almost at once, a far one still takes longer.
  function returnToHead() {
    const from = label.x
    if (!root.returnOnGateClose || from >= 0
        || !Marquee.scrollable(overflow)) {
      root.reset()
      return
    }
    leg.stop()
    returnLeg.from = from
    returnLeg.duration = Marquee.returnMs(-from)
    returnLeg.restart()
  }

  onWidthChanged: root.reset()
  onTextChanged: root.reset()
  onScrollingChanged: {
    if (root.scrolling) {
      if (root._returning) {
        // Focus came back before the handback landed: the outward leg has no
        // `from`, so it resumes from the current x rather than the head.
        returnLeg.stop()
        leg.restart()
      } else {
        root.reset()
      }
    } else {
      root.returnToHead()
    }
  }
  Component.onCompleted: root.reset()

  SequentialAnimation {
    id: leg

    // Driven only from the functions above. A `running: root.scrollable`
    // binding could stop the leg before the gate handler has read its offset,
    // turning the handback into the old one-frame snap.
    loops: Animation.Infinite
    PauseAnimation {
      duration: root.startPauseMs
    }
    NumberAnimation {
      target: label
      property: "x"
      // No `from`: a focus that returns mid-handback resumes from the live x.
      to: -root.overflow
      duration: root.legMs
      easing.type: Easing.InOutSine
    }
    PauseAnimation {
      duration: root.endpointPauseMs
    }
    NumberAnimation {
      target: label
      property: "x"
      from: -root.overflow
      to: 0
      duration: root.legMs
      easing.type: Easing.InOutSine
    }
    PauseAnimation {
      duration: root.endpointPauseMs
    }
    // A stopped marquee is a label at its beginning, not one parked at whatever
    // offset the animation was interrupted on.
    onStopped: label.x = 0
  }

  NumberAnimation {
    id: returnLeg
    target: label
    property: "x"
    to: 0
    easing.type: Easing.InOutSine
  }

  Title {
    id: label

    x: 0
    // Wider than the box only while it is allowed to travel, so a short label
    // stays one line inside its slot and a long one is never squeezed: the
    // elide below is what a label that cannot scroll falls back to.
    width: root.travelling ? implicitWidth : root.width
    anchors.verticalCenter: parent.verticalCenter
    // Matches Title's own optical-centring formula while `opticalCenter` is
    // on; 0 restores the plain geometric centring the hand-rolled sites had.
    anchors.verticalCenterOffset: root.opticalCenter
      ? Math.round(font.pixelSize * 0.08) : 0
    elide: root.travelling ? Text.ElideNone : root.idleElide
  }
}

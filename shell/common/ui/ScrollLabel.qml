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
// so there is one opinion about how long a leg takes.
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

  // Back to the start, and running or stopped. Every way the question can
  // change - a new width, a new string, the gate closing - comes through here,
  // so there is one place that decides whether the marquee is on.
  function reset() {
    label.x = 0
    if (root.scrollable) leg.restart()
    else leg.stop()
  }

  onWidthChanged: root.reset()
  onTextChanged: root.reset()
  onScrollingChanged: root.reset()
  Component.onCompleted: root.reset()

  SequentialAnimation {
    id: leg

    running: root.scrollable
    loops: Animation.Infinite
    PauseAnimation {
      duration: root.startPauseMs
    }
    NumberAnimation {
      target: label
      property: "x"
      from: 0
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

  Title {
    id: label

    x: 0
    // Wider than the box only while it is allowed to travel, so a short label
    // stays one line inside its slot and a long one is never squeezed: the
    // elide below is what a label that cannot scroll falls back to.
    width: root.scrollable ? implicitWidth : root.width
    anchors.verticalCenter: parent.verticalCenter
    // Matches Title's own optical-centring formula while `opticalCenter` is
    // on; 0 restores the plain geometric centring the hand-rolled sites had.
    anchors.verticalCenterOffset: root.opticalCenter
      ? Math.round(font.pixelSize * 0.08) : 0
    elide: root.scrollable ? Text.ElideNone : root.idleElide
  }
}

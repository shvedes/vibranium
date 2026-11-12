pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../../../common/motion/Marquee.js" as Marquee

// A one-line title that SCROLLS when it does not fit, instead of losing its
// tail to an ellipsis: the marquee the bar's Now Playing island and the
// clipboard's path rows already use - a pause so the head can be read, an
// eased leg to the far end, a pause there, and a leg back. The leg's duration
// comes from common/motion/Marquee.js rather than from a number written here,
// so this is the third caller that times the same way and not a third opinion
// about how long a leg takes.
//
// A wrapper rather than a Text, because the label inside has to be WIDER than
// the box that shows it: the caller anchors this item exactly as it anchored
// the Text it replaces (left, right, vertical centre), `clip` keeps the
// overflow from painting over the chip's caret, and the Title inside is free to
// travel. `text`, `level` and `color` are aliases onto that Title, so a call
// site reads as it did before - and one that sets no colour keeps the level's
// own, because an unset alias does not override the binding underneath it.
Item {
  id: root

  property alias text: label.text
  property alias level: label.level
  property alias color: label.color

  // The caller's own gate, on top of the shell's motion policy: a chip whose
  // row is closing, or whose list of candidates is empty, stops here rather
  // than animating under a label nobody is looking at.
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

  readonly property bool scrollable: root.scrolling && MotionPolicy.enabled
    && label.implicitWidth > root.width + 0.5
  readonly property real overflow: Math.max(0, label.implicitWidth - root.width)
  readonly property int legMs: Marquee.legMs(overflow)
  // A beat at each end: long enough to read the head of a name before it moves
  // and to read the tail before it returns, and the same two numbers the
  // clipboard row uses.
  readonly property int startPauseMs: 1200
  readonly property int endpointPauseMs: 400

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
    elide: root.scrollable ? Text.ElideNone : Text.ElideRight
  }
}

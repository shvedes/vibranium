pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Linear progress bar. Determinate mode fills toward `value` (0-100) with
// an eased glide so fast update streams read as one sweep; indeterminate
// mode slides a fixed-width block back and forth.
//
// The native control is not behind this one, and the measurement says
// why. QtQuick.Controls maps from/to/value onto a read-only `position` the
// same way `ratio` does here: against a 0..100 range the values 0, 50 and
// 150 read back 0, 0.5 and 1 with the value clamped, so the range
// arithmetic is not what this wrapper is for. `position` is read-only and
// does not move when `indeterminate` is set - under Basic, under the
// platform default and under Fusion alike - because the busy motion
// belongs to the style's own contentItem, which the track, the fill and the
// empty-dim tokens replace wholesale. The sweep that `visible` and
// `animationsEnabled` gate, the `glideMs` a sender-streamed bar retunes,
// and the left-anchored horizontal fill stay here, and the property names
// every consumer assigns stay the same.
Rectangle {
  id: root

  property real value: 0
  property bool indeterminate: false
  // Fill accent; defaults to theme accent.
  property color fillColor: Theme.color("accent")
  // Empty bars dim by default so a spawned 0% bar does not shout;
  // consumers rendering an always-visible track turn this off.
  property bool dimWhenEmpty: true
  // Determinate fill glide duration - sender-streamed bars tune this
  // down so repeated hints retarget quickly.
  property int glideMs: Ui.normalMs
  // Kill switch: disables the fill glide and the indeterminate sweep;
  // the fill still jumps to the target and the sweep halts. Defaults on
  // for standalone consumers off the menu.
  property bool animationsEnabled: true

  implicitWidth: 160
  height: 6
  clip: true
  color: Theme.color("background_2")
  radius: RoundingPolicy.radius
  opacity: root.indeterminate || !root.dimWhenEmpty || root.ratio > 0 ? 1 : 0.4

  readonly property real clamped: Math.min(100, Math.max(0, root.value))
  readonly property real ratio: root.clamped / 100

  Component.onCompleted: {
  }

  Component.onDestruction: {
  }

  // The reported value and the ratio it clamps to. Both travel together
  // because a sender streaming past 100 is the case where the two disagree,
  // and which of the two the fill followed is the question.

  Rectangle {
    id: fill

    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    visible: !root.indeterminate
    width: parent.width * root.ratio
    color: root.fillColor
    radius: RoundingPolicy.radius

    // Focus vibrancy (menu range/progress rows swap fillColor on
    // selection) fades instead of snapping while animations run.
    Behavior on color {
      enabled: root.animationsEnabled
      ColorAnimation { duration: Ui.fastMs }
    }

    Behavior on width {
      enabled: root.animationsEnabled
      Glide { duration: root.glideMs }
    }

    // The gliding fill, per frame. A sender-streamed bar retunes glideMs
    // while the fill is moving, and this is where the retune is visible.
  }

  Rectangle {
    id: block

    visible: root.indeterminate
    width: parent.width * 0.3
    height: parent.height
    color: root.fillColor
    radius: RoundingPolicy.radius

    SequentialAnimation on x {
      running: root.indeterminate && root.visible && root.animationsEnabled
      loops: Animation.Infinite

      NumberAnimation {
        from: 0
        to: block.parent.width - block.width
        duration: 900
        easing.type: Easing.InOutSine
      }
      NumberAnimation {
        from: block.parent.width - block.width
        to: 0
        duration: 900
        easing.type: Easing.InOutSine
      }
    }

    // The block sliding, per frame, for the same reason the fill's width is:
    // the frame loop is the only thing that produces the intermediate x.
  }
}

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

  // The fraction the fill is DRAWN at: the reported level, except while a
  // level change is gliding toward it.
  //
  // The glide lives on this number rather than on the fill's own width,
  // because that width is geometry as much as level. A bar handed a level in
  // the pass that builds its card - or one whose level arrives a turn later,
  // which is every notification delegate, since `modelData` and the entry's
  // snapshot land after the card completes - would otherwise sweep in from an
  // empty track: an animation of the bar APPEARING, not of the level moving.
  // Geometry now follows this fraction, so a bar that is laid out late, or a
  // card that is built before its snapshot, is already at its level the first
  // time it is drawn. A re-show at a new level is the host's call (OSD asks
  // for it with `fillSnap`).
  property real shownRatio: root.ratio

  // Whether the level's glide is armed.
  //
  // Once, after the bar's first placement, and deferred a turn - the same
  // shape and for the same reason as the pile's `place()` in
  // NotificationsView, with one turn's grace on top. The deferral is what
  // covers a delegate: `modelData` and the entry's level are handed to a card
  // AFTER its `Component.onCompleted`, in its creation turn, so arming at
  // construction would let that very first level glide in from empty. The
  // delay clears the creation turn, and everything after it - a streamed
  // volume, a download's progress - is a level CHANGE and glides.
  //
  // Gated on the bar's own width rather than on the level: a bar that appears
  // empty (a 0% download, an idle mixer channel) is placed all the same, and
  // its first move must glide like any other.
  property bool placed: false

  function _armPlaced(): void {
    root.placed = true
  }

  function _considerPlace(): void {
    if (root.placed || root.width <= 0) return
    Qt.callLater(root._armPlaced)
  }
  onWidthChanged: root._considerPlace()
  Component.onCompleted: root._considerPlace()

  Behavior on shownRatio {
    enabled: root.animationsEnabled && root.placed
    Glide { duration: root.glideMs }
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
    width: parent.width * root.shownRatio
    color: root.fillColor
    radius: RoundingPolicy.radius

    // Focus vibrancy (menu range/progress rows swap fillColor on
    // selection) fades instead of snapping while animations run.
    Behavior on color {
      enabled: root.animationsEnabled
      ColorAnimation { duration: Ui.fastMs }
    }

    // The gliding fill, per frame. The tween itself is on `shownRatio` (see
    // the root), which is what makes a level change animate while a
    // placement - or a late layout - does not.
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

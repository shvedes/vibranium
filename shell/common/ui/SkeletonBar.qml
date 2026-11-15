pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One placeholder block in a loading skeleton: the tint and corner recipe
// every island and panel had spelled out per site, with the shared pulse
// cadence opt-in.
//
//   SkeletonBar { width: 120 }
//   SkeletonBar { width: 120; pulse: root.loading; pulseIndex: row.index }
//
// Callers own the box (width, height, anchors, and any parent opacity); this
// primitive owns the colour, the corner and the pulse. A site that fades the
// block as a whole - the arch-updates handover - leaves `pulse` off and
// animates its wrapper, so the two never write one opacity.
Rectangle {
  id: bar

  // Runs the shared skeleton cadence on this block's opacity.
  property bool pulse: false
  // Row position in the placeholder block, which staggers the pulse.
  property int pulseIndex: 0
  // Extra offset inside the pulse cycle, for a variant that must not sit on
  // top of the row it follows.
  property int pulseOffset: 0
  // Tint strength of the block against foreground_1: the row's main line is
  // the default, a secondary line (or a glyph) passes its own.
  property real tint: 0.14
  // The block's opacity before and between pulses. Islands that sit the
  // placeholder under a dimmer surface pass their own rather than fading the
  // whole row.
  property real restingOpacity: 1

  implicitHeight: 8
  radius: RoundingPolicy.radius
  color: Ui.tint("foreground_1", bar.tint)
  opacity: bar.restingOpacity

  SequentialAnimation on opacity {
    loops: Animation.Infinite
    running: bar.pulse
    SkeletonPulse {
      index: bar.pulseIndex
      offset: bar.pulseOffset
    }
  }
}

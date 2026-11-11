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

  implicitHeight: 8
  radius: RoundingPolicy.radius
  color: Ui.tint("foreground_1", 0.14)

  SequentialAnimation on opacity {
    loops: Animation.Infinite
    running: bar.pulse
    SkeletonPulse {
      index: bar.pulseIndex
      offset: bar.pulseOffset
    }
  }
}

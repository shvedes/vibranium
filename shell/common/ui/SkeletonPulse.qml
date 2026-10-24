pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// The placeholder pulse an island runs while a section is loading: dim,
// up to full, dim again, forever, with the rows offset from each other so
// a list of placeholders travels instead of blinking as one block.
//
// Declared as `SequentialAnimation on opacity` inside the target, so the
// target owns the animation and the primitive only supplies the shape:
//
//   SequentialAnimation on opacity {
//     running: root.loading
//     SkeletonPulse { index: row.index }
//   }
//
// The cadence lives here because thirty call sites across three islands had
// each written it out, in two dialects: the bluetooth and network copies
// guarded the index through `Number(x) || 0` and floored the result, the
// arch-updates copy did neither, so an undefined index produced a NaN
// duration there. Both read as the same numbers because they were meant to
// be the same animation.
SequentialAnimation {
  id: root

  // Row position within the placeholder block. Drives the stagger; 0 for a
  // lone placeholder.
  property int index: 0
  // Extra offset inside the cycle, for a variant that must not sit on top
  // of the row it follows. Applied before the modulo, so an offset larger
  // than the cycle wraps rather than stalling.
  property int offset: 0

  // One cadence for every skeleton in the shell. A site tunes its place in
  // the block with `index`/`offset`, never with its own numbers.
  readonly property int stepMs: 90
  readonly property int cycleMs: 320
  readonly property int fadeMs: 750
  readonly property real lowOpacity: Ui.dimmedOpacity

  // A non-integer or absent index is a zero, not a NaN duration: this runs
  // on a Repeater delegate where `index` is the one thing that may not be
  // there yet.
  readonly property real _slot: Number(root.index) || 0
  readonly property int _delay: Math.max(0, (root._slot * root.stepMs + root.offset) % root.cycleMs)

  loops: Animation.Infinite

  PauseAnimation { duration: root._delay }
  NumberAnimation { to: 1.0; duration: root.fadeMs; easing.type: Easing.InOutQuad }
  NumberAnimation { to: root.lowOpacity; duration: root.fadeMs; easing.type: Easing.InOutQuad }
}

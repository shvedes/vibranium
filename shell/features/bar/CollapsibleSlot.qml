pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.bar

// Collapsible module slot: the one tray-convention collapse every dynamic
// bar module hand-rolled before this file existed.
//
// One axis: `slide` animates 0..1 on `collapseShown`, `implicitWidth` is
// the open width rounded to whole pixels every frame (fractional widths
// put neighbor slots at fractional x, which the renderer rounds
// inconsistently -> the shimmer that reads as a bounce), `clip` keeps the
// glyph inside the slot, and `fade` carries the glyph opacity so icons
// bind `opacity: <slot>.fade` instead of owning a second tween (same
// linear Ui.fastMs travel, driven once here rather than per icon).
//
// Per-site surface, the only lines a module keeps:
//   collapseShown  the visibility condition (was the slide binding)
//   collapseFull   the open width in px (was the Math.round argument)
//   collapseInOut  Tray only: InOutCubic instead of OutCubic at the same
//                  Ui.slowMs (a ~50px slide jerks on OutCubic's initial
//                  velocity and crawls sub-pixel in its tail; InOutCubic
//                  ramps from rest and settles gently - see Tray.qml)
//   collapseArmed  extra slide-Behavior gate (Volume's cold-boot settle:
//                  parked until the first layout pass, so creation never
//                  slides in)
//   collapseAnimated  motion gate; defaults to MotionPolicy.enabled, with
//                     Tray opting into its reveal while global motion is off
// Modules with a second axis (Caffeine's pill, NowPlaying's title) keep
// that axis local and read it inside collapseFull.
BarModule {
  id: root

  // The visibility condition; false parks the slot at zero width.
  property bool collapseShown: true
  // The open width in px; rounded per frame through the slide.
  property real collapseFull: Bar.iconSlot
  // Tray's easing variant; false is Glide's own OutCubic.
  property bool collapseInOut: false
  // Extra slide gate; true everywhere but Volume's cold-boot settle.
  property bool collapseArmed: true
  // Motion gate; Tray opts into its reveal while global motion is off.
  property bool collapseAnimated: MotionPolicy.enabled

  // Icons reveal progressively as the module widens.
  clip: true

  // Slide amount: 1 expanded, 0 collapsed. The slide itself is animated
  // (not the width) so implicitWidth - what the zone row measures -
  // tracks the animation frame by frame and the collapse never snaps.
  property real slide: root.collapseShown ? 1 : 0
  Behavior on slide {
    enabled: root.collapseArmed && root.collapseAnimated
    Glide { duration: Ui.slowMs; easing.type: root.collapseInOut ? Easing.InOutCubic : Easing.OutCubic }
  }

  // Glyph opacity: the same fast fade every icon ran on itself, driven
  // once here. Icons bind opacity to this and keep `visible: opacity > 0`.
  property real fade: root.collapseShown ? 1 : 0
  Behavior on fade {
    enabled: root.collapseAnimated
    NumberAnimation { duration: Ui.fastMs }
  }

  // Rounded to whole pixels every frame: the zone row lays out at this
  // width, and integer steps glide smoothly where fractional widths
  // shimmer.
  implicitWidth: Math.round(root.slide * root.collapseFull)
}

pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Disclosure affordance: two round-capped bars meeting at 45 degrees.
// Rotated Rectangles instead of a painted Canvas - vector AA renders the
// tip cleanly, with no pixel-grid snapping to fight.
//
// Extracted from two byte-identical inline `component Chevron` copies
// (menu Entry, the volume island), each of which had been ported from the
// previous one by hand. Geometry is fixed here so a retune lands on both
// at once.
Item {
  id: root

  // "right" | "left" | "up" | "down"
  property string direction: "right"
  property color color: Theme.color("foreground_1")
  // Stroke width in pixels.
  property real thickness: 1.5

  readonly property real halfH: root.height * 0.25
  readonly property real legL: root.halfH * Math.SQRT2

  readonly property real _spin: ({
    "right": 0,
    "down": 90,
    "left": 180,
    "up": 270
  })[root.direction] ?? 0

  rotation: root._spin
  width: 16
  height: 16

  Rectangle {
    width: root.legL
    height: root.thickness
    radius: root.thickness / 2
    antialiasing: true
    color: root.color
    rotation: 45
    x: root.width / 2 - root.legL / 2
    y: root.height / 2 - root.halfH / 2 - root.thickness / 2
  }

  Rectangle {
    width: root.legL
    height: root.thickness
    radius: root.thickness / 2
    antialiasing: true
    color: root.color
    rotation: -45
    x: root.width / 2 - root.legL / 2
    y: root.height / 2 + root.halfH / 2 - root.thickness / 2
  }
}

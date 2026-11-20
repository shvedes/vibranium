pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.common

// The shell's single soft elevation halo: a directionless shadow that copies
// its host's geometry. Used by the menu's nested cursor bars, inline notices,
// and the shell's tooltip bubbles so every hint reads at the same depth.
// Declare it before the host, as a sibling, so the halo paints behind the
// surface rather than over it.
RectangularShadow {
  id: root

  required property Item host

  visible: root.host.visible
  anchors.fill: root.host
  radius: RoundingPolicy.radius
  color: "#66000000"
  // Pixels, not a fraction, so the halo is the same size on every surface.
  blur: 12
  spread: 1
  offset: ({ x: 0, y: 0 })
}

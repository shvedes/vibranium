pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.common

// Elevation halo for the card-shaped MenuLib overlays: menu, launcher, power,
// clipboard and pass. The pickers fill their whole surface and have no card to
// lift. This is the menu's heavier profile; SoftShadow stays the shell's normal
// halo for nested bars. Declare it before the host so the halo paints behind.
RectangularShadow {
  id: root

  required property Item host

  visible: root.host.visible && Settings.value("shell.menu.dropShadow") === true
  anchors.fill: root.host
  radius: RoundingPolicy.radius
  // 0.8 alpha at 100%, 0.2 at the catalog's 25% floor: the halo never fades
  // out. Blur and spread stay at triple the shared halo's profile.
  color: Qt.rgba(0, 0, 0, 0.8 * Settings.menuShadowIntensity / 100)
  blur: 36
  spread: 3
  offset: ({ x: 0, y: 0 })
}

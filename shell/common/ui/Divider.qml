pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Horizontal hairline separator box. Consumers anchor left/right (or set
// width); a softer line overrides `color`, e.g.
// Ui.tint("background_3", 0.7).
//
// NOTE: do not route the default color through custom properties of this
// file - reading them from the color binding races property
// initialization and feeds QColor NaN alphas on the first pass.
Rectangle {
  implicitWidth: 200
  height: 1
  radius: RoundingPolicy.radius
  color: Ui.tint("background_3", 1)
}

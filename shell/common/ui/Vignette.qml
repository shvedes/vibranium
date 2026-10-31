pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

// Radial edge darkening over whatever is behind it, drawn as a fullscreen
// shape with a radial gradient: transparent through the middle, black at the
// corners.
//
// Two numbers drive it. `intensity` is how dark the edge gets - 0 draws
// nothing - and `progress` is how far the fade has run, so a caller can
// animate one while the other holds the chosen level. The shape shrinks
// slightly as the fade runs, which walks the dark edge inward instead of
// snapping it into place.
//
// The gradient is a smoothstep ramp and not the three stops it looks like it
// wants: a linear ramp has a slope discontinuity at its midpoint, and that
// kink is what reads as a visible ring around the middle of the screen.
Item {
  id: root

  // Darkness at the edge, 0..1.
  property real intensity: 0
  // How far the fade has run, 0..1.
  property real progress: 1

  opacity: root.intensity * root.progress
  visible: opacity > 0.01
  scale: 1.08 - 0.08 * root.progress
  transformOrigin: Item.Center

  // Cached diagonal radius: one evaluation per resize instead of per
  // gradient restyle. Half the diagonal is the radius, so every corner
  // darkens evenly.
  readonly property real diagR: Math.sqrt(width * width + height * height) / 2

  Shape {
    anchors.fill: parent

    ShapePath {
      startX: 0
      startY: 0

      PathLine {
        x: root.width
        y: 0
      }
      PathLine {
        x: root.width
        y: root.height
      }
      PathLine {
        x: 0
        y: root.height
      }
      PathLine {
        x: 0
        y: 0
      }

      strokeColor: "transparent"

      fillGradient: RadialGradient {
        centerX: root.width / 2
        centerY: root.height / 2
        centerRadius: root.diagR
        focalX: root.width / 2
        focalY: root.height / 2
        focalRadius: 0

        GradientStop {
          position: 0
          color: "#00000000"
        }
        GradientStop {
          position: 0.5
          color: "#00000000"
        }
        GradientStop {
          position: 0.55
          color: "#07000000"
        }
        GradientStop {
          position: 0.6
          color: "#1b000000"
        }
        GradientStop {
          position: 0.65
          color: "#37000000"
        }
        GradientStop {
          position: 0.7
          color: "#5a000000"
        }
        GradientStop {
          position: 0.75
          color: "#80000000"
        }
        GradientStop {
          position: 0.8
          color: "#a5000000"
        }
        GradientStop {
          position: 0.85
          color: "#c8000000"
        }
        GradientStop {
          position: 0.9
          color: "#e4000000"
        }
        GradientStop {
          position: 0.95
          color: "#f8000000"
        }
        GradientStop {
          position: 1
          color: "#ff000000"
        }
      }
    }
  }
}

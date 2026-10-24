pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.common

// Fabricated picture stand-in: a generic mountain + sun scene drawn
// from shapes inside a caller-sized stage. Static, island skeleton
// chrome - no shimmer, no ready-made icon. Shared by the two-pane
// image previews (clipboard media stage, wallpaper preview), which is
// why it lives in the library and not in either panel.
//
// True round clip through the house MultiEffect mask idiom: a plain
// Rectangle clip is rectangular and would keep the mountains' square
// corners over the rounded sky.
Item {
  id: root

  // Corner radius of the stage, follows RoundingPolicy.
  property real radius: RoundingPolicy.radius

  layer.enabled: true
  layer.smooth: true
  layer.effect: MultiEffect {
    maskEnabled: true
    maskSource: roundMask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }

  Rectangle {
    anchors.fill: parent
    color: Ui.tint("foreground_1", 0.14)

    // Sun disc, upper right. Painted before the slopes so a low sun
    // would sink behind them; tones step sky -> far -> near -> sun.
    Rectangle {
      x: parent.width * 0.62
      y: parent.height * 0.14
      width: parent.height * 0.26
      height: width
      radius: width / 2
      color: Ui.tint("foreground_1", 0.3)
    }

    Shape {
      anchors.fill: parent

      ShapePath {
        fillColor: Ui.tint("foreground_1", 0.2)
        strokeColor: "transparent"
        PathMove { x: 0; y: root.height }
        PathLine { x: root.width * 0.38; y: root.height * 0.3 }
        PathLine { x: root.width * 0.78; y: root.height }
        PathLine { x: 0; y: root.height }
      }
    }

    Shape {
      anchors.fill: parent

      ShapePath {
        fillColor: Ui.tint("foreground_1", 0.26)
        strokeColor: "transparent"
        PathMove { x: root.width * 0.4; y: root.height }
        PathLine { x: root.width * 0.74; y: root.height * 0.52 }
        PathLine { x: root.width; y: root.height }
        PathLine { x: root.width * 0.4; y: root.height }
      }
    }
  }

  Rectangle {
    id: roundMask

    anchors.fill: parent
    radius: root.radius
    color: "white"
    visible: false
    layer.enabled: true
    layer.smooth: true
    layer.samples: 4
  }
}

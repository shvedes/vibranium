pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.bar

PanelWindow {
  id: root

  // The extra height below (or above) the bar the gradient fades through. It
  // is the one number that differs from the bar window's height and the
  // reason the two are not the same surface.
  readonly property int extent: 8

  visible: Bar.enabled && !Bar.hideToggle && Bar.showShadow
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: Bar.position === "top"
  anchors.bottom: Bar.position === "bottom"
  implicitHeight: Bar.height + root.extent

  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.namespace: "vibranium:bar-shadow"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region { width: 0; height: 0 }

  Rectangle {
    x: 0
    y: Bar.position === "top" ? Bar.height : 0
    width: parent.width
    height: root.extent
    gradient: Gradient {
      orientation: Gradient.Vertical
      GradientStop {
        position: 0
        color: Bar.position === "top" ? Ui.alpha("#000000", 0.22) : "transparent"
      }
      GradientStop {
        position: Bar.position === "top" ? 0.15 : 0.85
        color: Ui.alpha("#000000", 0.4)
      }
      GradientStop {
        position: 1
        color: Bar.position === "top" ? "transparent" : Ui.alpha("#000000", 0.22)
      }
    }
  }
}

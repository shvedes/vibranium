pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "LayerSpec.js" as LayerSpec

// A layer-shell surface whose static contract comes from LayerSpec.js.
//
// The four anchors, the ignoring exclusion mode and the transparent color are
// the same six lines on every full-screen surface in this shell; the namespace,
// the layer and the keyboard policy are the parts that have to agree with the
// Hyprland rules. All of it lives here, and a declaration says one thing:
// `surface: "vibranium:osd"`.
//
// A consumer owns what is genuinely its own: `screen`, `visible`, `mask`, and a
// keyboard mode gated on its own open state. Overriding `anchors` or
// `exclusiveZone` is how the bar and the privacy dots opt out of the
// full-screen shape.
PanelWindow {
  id: root

  // The layer-shell namespace, and the registry key. Empty only on
  // ScrimWindow, the base the menu family inherits before it sets one.
  property string surface: ""

  readonly property var spec: LayerSpec.spec(root.surface)
  readonly property int layerNumber: root.spec === null
    ? LayerSpec.OVERLAY : root.spec.layer

  color: "transparent"
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1

  WlrLayershell.namespace: root.surface
  WlrLayershell.layer: root.layerNumber === LayerSpec.BACKGROUND ? WlrLayer.Background
    : root.layerNumber === LayerSpec.BOTTOM ? WlrLayer.Bottom
    : root.layerNumber === LayerSpec.TOP ? WlrLayer.Top
    : WlrLayer.Overlay
  // The registry says whether the surface may ever take keys. A surface that
  // does gates this on its own open state; leaving the ungated default in place
  // would hand the keyboard to a surface that has nothing to type into.
  WlrLayershell.keyboardFocus: root.spec !== null && root.spec.focus !== "none"
    ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
}

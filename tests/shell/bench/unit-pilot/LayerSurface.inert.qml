// Test-only stand-in for common/ui/LayerSurface.qml.
// The real type is a PanelWindow and cannot compile offscreen (no
// PanelWindow backend). Offscreen Ui.validScreens is empty, so no overlay is
// ever instanced; the stand-in only has to satisfy the type's compile-time
// surface so the REAL AppLauncher singleton and its REAL IpcRouter
// registration can be observed headlessly. Never copied into production.
pragma ComponentBehavior: Bound

import QtQuick
import "LayerSpec.js" as LayerSpec

Item {
  id: root

  property string surface: ""
  property color color: "transparent"
  property var screen: null
  property var mask: null
  property var exclusionMode: null
  property int exclusiveZone: -1
  property bool hasExclusiveFocus: false

  readonly property var spec: LayerSpec.spec(root.surface)
  readonly property int layerNumber: root.spec === null
    ? LayerSpec.OVERLAY : root.spec.layer
}

pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// The indicator layer of a two-tone Icon, compiled once per engine and
// shared by every icon instance through Loader.source instead of one
// inline Component per Icon. An uninstantiated inline Component is only a
// lightweight wrapper (the bytecode is shared), but with 120+ icons in the
// tree two of them per instance - indicator plus debug bounds - was the
// largest remaining per-instance weight in the icon path. A file URL in
// Loader.source stores a string and compiles on first activation, so a
// plain icon pays one Loader and nothing else.
//
// HOST CONTRACT: instantiated only by Icon.qml's indicatorLoader, whose
// custom properties below are plain bindings (no extra objects per icon).
// They are read through `parent` - the loaded item is parented to the
// Loader - once, into typed aliases on this root; nested children read
// the aliases, never `parent` (their parent is this root, not the Loader).
// Geometry is NOT forwarded: the Loader is already canvas-sized and
// centered, so this root fills it, and the DPR comes from the item's own
// window exactly like Icon.qml's.
Item {
  id: root

  anchors.fill: parent

  // In from the host Loader (see contract above).
  readonly property string iconName: parent.iconName
  readonly property string iconColorKey: parent.iconColorKey
  readonly property string iconAccentKey: parent.iconAccentKey
  readonly property int iconDimTiers: parent.iconDimTiers
  readonly property bool iconLayered: parent.iconLayered
  readonly property string iconAnim: parent.iconAnim
  readonly property bool iconAnimOn: parent.iconAnimOn

  // The containing window's DPR, same rule as Icon.qml: the item's own
  // window, falling back to 1 before it is in one.
  readonly property real _dpr: {
    const w = Window.window
    const dpr = w ? w.devicePixelRatio : 0
    return typeof dpr === "number" && isFinite(dpr) && dpr > 0 ? dpr : 1
  }

  // Ready when the indicator raster has decoded. Icon.qml reads this
  // through the Loader's item for its own `ready`.
  readonly property bool layerReady: indicator.status === Image.Ready

  Image {
    id: indicator

    visible: root.iconLayered
    anchors.fill: parent
    retainWhileLoading: true
    asynchronous: true
    source: root.iconLayered
      ? Icons.url(root.iconName, root.iconColorKey, root.iconAccentKey, "indicator", root.iconDimTiers)
      : ""
    sourceSize: Qt.size(root.width * root._dpr, root.height * root._dpr)
    onVisibleChanged: if (visible) opacity = 1
  }

  // Behavior animations drive the layer's opacity on the GPU. The
  // "blink" convention matches the Timer gauge (600ms halves,
  // InOutQuad) but with a 0.5 floor - the attention swap is solid ->
  // 50% transparent, not a hard blackout. "pulse" is the pending breathe.
  // Both stop when the layer disappears (running binds through visible),
  // and the snap-back resets mid-phase opacity so re-activation starts
  // from full. Cross-item target: the `on` property syntax only reaches
  // same-item properties, so the children carry target/property.
  SequentialAnimation {
    running: indicator.visible && root.iconAnimOn && root.iconAnim === "blink"
    loops: Animation.Infinite
    onRunningChanged: if (!running && indicator.visible) indicator.opacity = 1

    NumberAnimation { target: indicator; property: "opacity"; to: 0.5; duration: Ui.blinkMs; easing.type: Easing.InOutQuad }
    NumberAnimation { target: indicator; property: "opacity"; to: 1; duration: Ui.blinkMs; easing.type: Easing.InOutQuad }
  }

  SequentialAnimation {
    running: indicator.visible && root.iconAnimOn && root.iconAnim === "pulse"
    loops: Animation.Infinite
    onRunningChanged: if (!running && indicator.visible) indicator.opacity = 1

    NumberAnimation { target: indicator; property: "opacity"; to: 0.5; duration: Ui.pulseMs; easing.type: Easing.InOutSine }
    NumberAnimation { target: indicator; property: "opacity"; to: 1; duration: Ui.pulseMs; easing.type: Easing.InOutSine }
  }
}

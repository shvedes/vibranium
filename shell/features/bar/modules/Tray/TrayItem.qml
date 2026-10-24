pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.features.bar

// One status notifier icon. Left-click activates (or opens the menu for
// menu-only items), middle-click secondary-activates, right-click opens
// the item's DBusMenu, the wheel scrolls it. Hover drives the shared
// tooltip bubble owned by the host module.
MouseArea {
  id: root

  property var item: null
  property var barWindow: null

  // Live bar metrics - the same tokens the shared Icon primitive paints from,
  // read straight off Bar so a tray icon scales with bar height and preset
  // exactly like every normal module's does.
  readonly property int _slot: Bar.iconSlot
  readonly property int _canvas: Bar.iconCanvas
  readonly property real _dpr: Window.window ? Window.window.devicePixelRatio : 1

  signal menuRequested(var handle, var anchor)
  signal tooltipRequested(var anchor, string text)
  signal tooltipReleased(var anchor)

  implicitWidth: root._slot
  implicitHeight: root._slot
  hoverEnabled: true
  cursorShape: Qt.PointingHandCursor
  acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

  function tooltipText() {
    if (!root.item) return ""
    return root.item.tooltipTitle || root.item.title || root.item.id
  }

  onClicked: event => {
    if (event.button === Qt.LeftButton) {
      if (root.item && root.item.onlyMenu && root.item.hasMenu) {
        // A menu-only item takes the left click for its menu.
        root.menuRequested(root.item.menu, root)
      } else if (root.item) {
        // The item's own verb (usually raise its window).
        root.item.activate()
      }
    } else if (event.button === Qt.MiddleButton) {
      if (root.item) root.item.secondaryActivate()
    } else if (event.button === Qt.RightButton) {
      if (root.item && root.item.hasMenu) {
        root.menuRequested(root.item.menu, root)
      }
    }
    event.accepted = true
  }

  onWheel: event => {
    if (root.item && typeof root.item.scroll === "function")
      root.item.scroll(event.angleDelta.y > 0 ? 1 : -1, false)
    event.accepted = true
  }

  // Use Image (not IconImage) so sourceSize can be set for DPR-crisp
  // rasterization at the live canvas size, exactly like common/ui/Icon.qml
  // (canvas * DPR physical, canvas logical). IconImage has no sourceSize
  // and would stretch the raster.
  Image {
    anchors.centerIn: parent
    width: root._canvas
    height: root._canvas
    sourceSize: Qt.size(root._canvas * root._dpr, root._canvas * root._dpr)
    // Loaded synchronously: SNI icons are small local images/theme icons,
    // and an async load would pop each icon in a frame late as the tray's
    // clip reveals it during the slide - a visible hitch.
    mipmap: true
    fillMode: Image.PreserveAspectFit
    smooth: true
    asynchronous: false
    cache: true
    // The service's own icon, used as given: theme names arrive as
    // image://icon/..., pixmap data as image://qspixmap/..., and some
    // exporters send a plain file path. The guard covers the window
    // where a recycled delegate has no modelData yet.
    source: root.item ? root.item.icon || "" : ""
  }

  onHoveredChanged: {
    if (!root.barWindow) return
    if (root.containsMouse) root.tooltipRequested(root, root.tooltipText())
    else root.tooltipReleased(root)
  }

  // Destroyed while hovered (item removed): no leave fires, so release the
  // shared bubble directly - otherwise it outlives the icon (and the tray).
  Component.onDestruction: {
    try {
      if (root.containsMouse) {
        const host = root.barWindow ? root.barWindow.toolTipHost : null
        if (host) host.cancel(root)
      }
    } catch (e) {}
  }
}

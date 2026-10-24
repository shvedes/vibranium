pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.bar
import qs.services as Core

// Bar face of the privacy service (qs.services.privacy): a static right-zone
// launcher for the privacy island. The capture dots themselves are NOT drawn
// here - they live on the bar's own privacy overlay (PrivacyOverlay.qml), an
// Overlay-layer surface per screen, so they survive a fullscreen toplevel
// covering the bar. All state, the per-app ledger, the tooltip/island models
// and the link-cut toggles live in the service, so the overlay's dots and the
// lockscreen dots mirror the same state without duplicating any PipeWire code.
BarModule {
  id: root

  // Left click opens the info island; the fill still reports `hovered`
  // for the tooltip.
  fillButtons: Qt.LeftButton
  onClicked: mouse => root.openIsland()

  // Regular static module: one icon slot, no slide and no collapse, so the
  // slot holds its width whether or not a capture is running.
  readonly property real slotWidth: root.iconSlot
  implicitWidth: root.slotWidth

  Icon {
    anchors.centerIn: parent
    name: "incognito"
    colorKey: "foreground_0"
  }

  // Tooltip asks on every hover, not only while a capture runs: the
  // service projects the per-app table from the live ledger and returns
  // no rows with no client, so the idle half is a literal here.
  // A quiet privacy slot stays self-explaining instead of silent - the
  // literal reads as a plain sentence (the island already shows the same
  // words, with no prefix). Active rows render through the host's shared
  // lines path like every compact tooltip, so the bubble insets match.
  ToolTipBind {
    active: root.hovered && !root.barWindow.islandHost.isOpenFor(root)
    text: Core.Privacy.active ? "" : "No apps using your devices"
    lines: Core.Privacy.active ? Core.Privacy.tooltipRows : []
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    PrivacyIsland {
      rows: Core.Privacy.islandRows
      onInvokeRequested: (app, key) => {
        // DEBUG, and deliberately not INFO: the row's button asks the
        // privacy service to cut a link or put one back, and the service's
        // pipeline decides which and whether it landed - a cut can be
        // refused outright (nothing_to_restore), which the row shows and
        // nothing else records. So this is the request, who was asked and
        // for what, and the outcome line belongs to services/privacy where
        // the cut is actually run.
        return Core.Privacy._toggleTarget(app, key)
      }
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // The service owns `active`; mirror its change to close a stale island.
  Connections {
    target: Core.Privacy

    function onActiveChanged() {
      if (!Core.Privacy.active && root.barWindow.islandHost.isOpenFor(root))
        root.barWindow.islandHost.close()
    }
  }
}

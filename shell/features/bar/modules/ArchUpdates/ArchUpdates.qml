pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.services as Svc
import qs.features.bar
import qs.features.bar.modules.ArchUpdates
import "Model.js" as Model

// Arch updates indicator. Static right-zone module that visualises
// the ArchUpdates service (official Arch packages and AUR,
// fetched in parallel with timeouts). Left opens the searchable island
// with per-source update buttons, middle refreshes, right launches the
// official TUI updater. The tooltip counts by source - the total first,
// then the official and the AUR split, each under the glyph the island's
// table uses - and the full list stays in the island.
BarModule {
  id: root

  readonly property string displayState: Svc.ArchUpdates.state
  readonly property var displayPackages: Svc.ArchUpdates.packages
  readonly property string displayError: Svc.ArchUpdates.errorText
  readonly property bool displayUpdating: Svc.ArchUpdates.updating

  // Same threshold, same toggle as the island's warning box: the tooltip's
  // red total and the island's alarm are one condition.
  readonly property bool heavyQueue: Model.heavyQueue(root.displayPackages,
    Settings.statusbarArchUpdatesHeavyWarning)

  // Status text for the two states that carry no counts. A pending or
  // up-to-date list is a row set instead (tipLines below).
  readonly property string tooltipText: root.displayState === "loading"
    ? "Checking for updates..." : (root.displayState === "error" ? "Unable to check for updates" : "")

  // Tooltip rows ({icon, text}, the weather convention): the total first,
  // then the official and AUR split under the source glyphs the island's
  // table uses. A heavy backlog paints the total in the red the island's
  // subtitle uses. The total rides the module's own bar glyph, which is
  // what distinguishes it from the AUR row below it.
  readonly property var tipLines: {
    const st = root.displayState
    if (st !== "ready" && st !== "idle") return []
    const n = root.displayPackages.length
    if (n === 0) return [{ icon: "package", text: "System is up to date" }]
    const counts = Model.sourceCounts(root.displayPackages)
    return [
      {
        icon: root._iconName,
        text: n === 1 ? "1 update" : n + " updates",
        colorKey: root.heavyQueue ? "red" : "foreground_0"
      },
      { icon: "archlinux", text: counts.official + " official" },
      { icon: "package", text: counts.aur + " AUR" }
    ]
  }

  // Visual: single package-aur icon, no count badge. Always takes
  // the fixed slot, even when up to date.
  implicitWidth: Bar.iconSlot

  // Glyph per state: package-aur with a green "+" when updates are
  // available, package-error with a red xmark on failure, plain package
  // when up to date. The accent recolors only the tagged sub-shape; the
  // package body stays foreground.
  readonly property string _iconName: root.displayState === "error" ? "package-error"
    : (root.displayPackages.length > 0 ? "package-aur" : "package")
  readonly property string _iconAccent: root.displayState === "error" ? "red"
    : (root.displayPackages.length > 0 ? "green" : "")

  Icon {
    anchors.centerIn: parent
    name: root._iconName
    colorKey: "foreground_0"
    accentKey: root._iconAccent
  }

  // Click contract: left opens island, middle refreshes, right
  // launches the official updater for all official packages.
  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.LeftButton) {
      root.openIsland()
    } else if (mouse.button === Qt.MiddleButton) {
      Svc.ArchUpdates.refresh()
    } else if (mouse.button === Qt.RightButton) {
      Svc.ArchUpdates.triggerUpdate(false, [])
    }
  }

  ToolTipBind {
    active: root.hovered
    text: root.tooltipText
    lines: root.tipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    ArchUpdatesIsland {
      packages: root.displayPackages
      islandState: root.displayState
      errorText: root.displayError
      updating: root.displayUpdating
      onUpdateRequested: (aur, names) => {
        // The update runs in its own terminal (vb-launch-tui), so close the
        // island right away; the service refreshes when the updater exits
        // and the module repopulates from there.
        const host = root.barWindow.islandHost
        if (host.isOpenFor(root)) host.close()
        Svc.ArchUpdates.triggerUpdate(aur, names)
      }
      onUpdateSystemRequested: {
        const host = root.barWindow.islandHost
        if (host.isOpenFor(root)) host.close()
        Svc.ArchUpdates.triggerUpdateBoth([])
      }
      onRefreshRequested: Svc.ArchUpdates.refresh()
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}

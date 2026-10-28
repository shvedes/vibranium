pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell.Hyprland
import qs.common
import qs.features.bar

// Barebones workspaces: plain numbers, flashing red for urgents.
// No occupied/empty states, no opacity dimming, no submap badge, no
// timers - the strip syncs off compositor events instead.

BarModule {
  id: root

  readonly property var monitor: barScreen ? Hyprland.monitorFor(barScreen) : null
  readonly property int activeId: root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : -1

  // Live workspace ids, special scratchpad skipped.
  readonly property var ids: {
    const out = []
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id >= 0) out.push(ws.id)
    out.sort((a, b) => a - b)
    return out
  }

  function workspaceFor(id) {
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id === id) return ws
    return null
  }

  builtinFill: false
  implicitWidth: row.implicitWidth

  // The ids the strip renders, synced off compositor events rather than
  // a timer. A create, destroy or focus change schedules a sync, so a
  // new workspace never lags the switch and a dead one clears on the
  // destroy event instead of lingering as a ghost. The sync is deferred
  // past current event processing (callLater, not a wall-clock wait) so
  // the workspace model has applied the same event batch before it is
  // read; the join-guard keeps no-op syncs from rebuilding the strip.
  property var shown: []

  function syncIds() {
    if (root.shown.join(",") !== root.ids.join(",")) root.shown = root.ids
  }

  // Backstop for startup when the model fills in after us; steady-state
  // updates come from the socket events below.
  onIdsChanged: if (root.shown.length === 0) root.syncIds()

  Component.onCompleted: {
    root.syncIds()
    Hyprland.rawEvent.connect(root.onRawEvent)
  }
  Component.onDestruction: Hyprland.rawEvent.disconnect(root.onRawEvent)

  function onRawEvent(event) {
    if (event.name === "createworkspace" || event.name === "destroyworkspace" || event.name === "workspacev2" || event.name === "focusedmon") Qt.callLater(root.syncIds)
  }

  Row {
    id: row

    anchors.verticalCenter: parent.verticalCenter
    spacing: 12

    Repeater {
      model: root.shown

      delegate: Item {
        id: slot

        required property int modelData

        readonly property int wsId: modelData
        readonly property var ws: root.workspaceFor(wsId)
        readonly property bool focused: root.activeId === wsId
        readonly property bool urgent: slot.ws !== null && slot.ws.urgent === true

        width: label.implicitWidth + 4
        height: Bar.height
        onUrgentChanged: if (!slot.urgent) label.opacity = 1

        Title {
          id: label

          level: 3
          anchors.centerIn: parent
          text: String(slot.wsId)
          color: slot.urgent ? Ui.solid("red") : slot.focused ? Ui.solid("accent") : Ui.solid("foreground_0")

          // The only animation in this module: urgents flash.
          SequentialAnimation on opacity {
            running: slot.urgent
            loops: Animation.Infinite
            NumberAnimation {
              to: 0.35
              duration: 800
            }
            NumberAnimation {
              to: 1.0
              duration: 800
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton
          onClicked: if (slot.ws !== null) slot.ws.activate()
        }
      }
    }
  }
}

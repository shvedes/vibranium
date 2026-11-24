pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell.Hyprland
import qs.common
import qs.features.bar
import "Model.js" as WSM

// Barebones workspaces: plain numbers, flashing red for urgents.
// No occupied/empty states, no opacity dimming, no timers - the strip
// follows the live workspace model directly. While a keybind submap is active
// a little "[R]" superscript trails the last index (resize is the only
// submap today).

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
    + (root.submapActive ? WSM.numberGap() + submapText.implicitWidth + Bar.slotInset : 0)

  Component.onCompleted: Hyprland.rawEvent.connect(root.onRawEvent)
  Component.onDestruction: Hyprland.rawEvent.disconnect(root.onRawEvent)

  // Live submap from the hyprland event socket; empty string = default.
  property string submap: ""
  readonly property bool submapActive: root.submap === "resize"

  function onRawEvent(event) {
    if (event.name === "submap") root.submap = String(event.data ?? "").trim()
  }

  readonly property int cellPad: WSM.numberPad(root.textScale)
  readonly property int cellWidth: WSM.numberBoxWidth(measure.implicitWidth, root.cellPad)

  // Hidden two-digit ruler: every slot is sized for "00" plus padding,
  // so the active icon, single digits and double digits all share one
  // fixed cell and switching focus never resizes the strip.
  Text {
    id: measure
    visible: false
    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontS
    text: "00"
  }

  Row {
    id: row

    anchors.verticalCenter: parent.verticalCenter
    spacing: WSM.numberGap()

    Repeater {
      // One live derivation: ids already tracks Hyprland.workspaces.values,
      // so the strip follows every create/destroy/focus batch directly.
      model: root.ids

      delegate: Item {
        id: slot

        required property int modelData

        readonly property int wsId: modelData
        readonly property var ws: root.workspaceFor(wsId)
        readonly property bool focused: root.activeId === wsId
        readonly property bool urgent: slot.ws !== null && slot.ws.urgent === true

        // One driver for the glyph swap. Both layers derive their opacity
        // from it, so they cannot drift apart mid-fade. Glide carries the
        // shared motion policy and duration.
        property real focusK: slot.focused ? 1 : 0
        Behavior on focusK {
          Glide {}
        }

        width: root.cellWidth
        height: Bar.height

        // Number and focus glyph share one fixed cell and both read focusK.
        // Each layer owns its resting size, so a focus change only moves the
        // shared fade and cannot resize or shift the strip.
        Title {
          id: label

          level: 3
          anchors.centerIn: parent
          anchors.verticalCenterOffset: Math.round(Ui.fontS * 0.08)
          font.pixelSize: Ui.fontS
          text: String(slot.wsId)
          color: Ui.solid("foreground_0")
          opacity: 1 - slot.focusK
          visible: !slot.urgent
        }

        Title {
          id: focusIcon

          level: 3
          anchors.centerIn: parent
          // Title nudges text down for optical centring; keep the glyph at
          // zero offset so it sits where the single-layer swap placed it.
          anchors.verticalCenterOffset: 0
          font.pixelSize: Math.round(Ui.fontS / 1.2)
          text: "\uDB85\uDCFB"
          color: Ui.solid("foreground_0")
          opacity: slot.focusK
          visible: !slot.urgent
        }

        // Urgency flashes on its own layer so the animation owns this opacity,
        // not the glyph layers'. Ending urgency only hides the wash; no handler
        // has to correct a value the stopped animation left behind.
        Title {
          id: urgentWash

          level: 3
          anchors.centerIn: parent
          anchors.verticalCenterOffset: slot.focused ? 0 : Math.round(Ui.fontS * 0.08)
          font.pixelSize: slot.focused ? focusIcon.font.pixelSize : label.font.pixelSize
          text: slot.focused ? focusIcon.text : label.text
          color: Ui.solid("red")
          visible: slot.urgent
          opacity: 0

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
          // This module turns the shared fill off (builtinFill: false), so the
          // cell areas are the whole hover surface. A MouseArea without hover
          // takes no hover events, and cursorShape is only applied through
          // them - the hand cursor would then trail whatever module it came
          // from instead of following the cell under the pointer.
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: mouse => {
            // Right-click is the module's declarative hook
            // (shell.statusbar.workspacesRightClick). Unset, it does nothing -
            // the catalog offered the command before anything consumed it.
            if (mouse.button === Qt.RightButton) {
              root.clickCommand("rightClick")
              return
            }
            if (slot.ws !== null) slot.ws.activate()
          }
        }
      }
    }
  }

  // Superscript "[R]" trailing the indexes while a submap is active.
  Title {
    id: submapText

    level: 4
    x: row.width + (root.submapActive ? WSM.numberGap() : 0)
    y: 3
    visible: root.submapActive
    text: "[R]"
    color: Ui.solid("yellow")
    font.pixelSize: 8
    font.family: Ui.fontFamily
    font.bold: true
  }
}

pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.bar

// Night light indicator. shell.nightLight.enabled is the source of truth:
// vb-cmd-nightshift mirrors unit changes into the store after every
// toggle, and this module binds to the key - so the icon flips instantly
// on click, from the settings menu, or from any script that toggles
// through --set-active. Click toggles, wheel steps -i/-d; nothing else.
CollapsibleSlot {
  id: root

  readonly property bool vmUnavailable: Quickshell.env("CHASSIS_TYPE") === "vm"

  // Instant: a plain settings binding, no polling.
  readonly property bool active: Settings.value("shell.nightLight.enabled") === true

  // Hidden in a VM. User disable is handled one level up: a disabled id
  // never reaches the filtered layout, so this module is not instantiated
  // at all.
  readonly property bool shown: !root.vmUnavailable

  // Collapsible slot (see CollapsibleSlot.qml): zero width while hidden
  // so it leaves no gap.
  collapseShown: root.shown

  Icon {
    // Pinned to the trailing edge the box grows from (right-anchored zone):
    // the Icon item is slot-sized and paints its glyph centered inside, so
    // a flush-right anchor centers the glyph at rest and holds it
    // screen-fixed while the slot grows (left overflow is clipped).
    //
    // No opacity on the glyph: `active` is a boolean and the accent key
    // already carries it, so a fade would say the same state change twice.
    // Appearing is the slot's own slide.
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: "night-light"
    colorKey: "foreground_0"
    accentKey: root.active ? "yellow" : ""
  }

  fillButtons: Qt.LeftButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.RightButton) return
    root._toggle()
  }

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.active) return
      Exec.shell("vb-cmd-nightshift " + (event.angleDelta.y > 0 ? "-i" : "-d"))
    }
  }

  ToolTipBind {
    active: root.shown && root.hovered
    text: root.active ? "Night Light active" : "Night Light suspended"
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  function _toggle() {
    // Optimistic flip - the pill and icon move on frame one; the script
    // converges the unit to the same state (idempotent --set-active) and
    // mirrors the key back only if it drifted.
    const next = !root.active
    root._apply(next)
  }

  // Converge the unit to `on` and leave the key authoritative in the
  // store. Idempotent: safe to run repeatedly from any surface.
  function _apply(on) {
    Exec.shell("vb-cmd-nightshift --set-active " + (on ? "1" : "0"))
  }

  Connections {
    target: Settings

    function onOptionChanged(key, value) {
      if (key !== "shell.nightLight.enabled" || typeof value !== "boolean") return
      // Converge, never negate: the script re-writes the key only when
      // the stored value drifted from the unit, so this cannot loop.
      root._apply(value)
    }
  }
}

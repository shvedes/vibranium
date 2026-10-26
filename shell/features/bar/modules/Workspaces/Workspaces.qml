pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import qs.common
import qs.features.bar
import "Model.js" as Model

// Global workspaces module. Every bar shows all real workspaces (special
// scratchpad surfaces are skipped); the one active on this bar's monitor
// reads as current (accent), workspaces with windows read occupied (full
// foreground), empty ones read registered (50% transparent). Clicking a
// workspace activates it.
//
// The strip is number-only: one fixed-width slot per workspace, sized for two
// digits so single- and double-digit ids keep even labels and hit targets.
// Nothing here animates. A workspace appearing, disappearing or changing state
// is painted outright; the urgent state is the red colour itself rather than a
// pulse.
//
// While a keybind submap is active a little "[R]" superscript appears after
// the last index (resize is the only submap today).

BarModule {
  id: root

  readonly property var monitor: barScreen ? Hyprland.monitorFor(barScreen) : null

  // The workspace THIS bar's monitor is on, read separately from the
  // workspace list because the list is not what changes: Hyprland reports
  // leaving an empty workspace and arriving on the next one as a destroy and
  // a spawn, so a flick across the strip moves the list twice and the focus
  // once.
  //
  // Per monitor, not global: the bar is built per output and each monitor has
  // its own active workspace, so a switch on one screen moves that bar's
  // focus and the others stay put.
  readonly property var activeWorkspace: root.monitor ? root.monitor.activeWorkspace : null

  // Each slot owns its own click surface (see the delegate's MouseArea), so
  // the base fill is off.
  //
  // An assignment, not a redeclaration: BarModule already owns the property.
  builtinFill: false

  // Live submap from the hyprland event socket; empty string = default.
  property string submap: ""
  readonly property bool submapActive: root.submap === "resize"

  readonly property int twoDigitWidth: Math.ceil(twoDigitMeasure.width)
  readonly property int numberPad: Model.numberPad(Bar.iconScale)
  readonly property int buttonWidth: Model.numberBoxWidth(root.twoDigitWidth, root.numberPad)
  readonly property int gap: Model.numberGap()

  TextMetrics {
    id: twoDigitMeasure

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontS
    font.bold: true
    text: "88"
  }

  // The workspace ids that exist right now, special surfaces skipped.
  readonly property var liveIds: {
    const out = []
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id >= 0) out.push(ws.id)
    return out
  }

  // The ids the strip renders, which is deliberately not bound straight to
  // liveIds. Hyprland reports a focus change as two events - destroy the empty
  // workspace you left, create the one you arrived on - and in between the
  // compositor genuinely has one fewer workspace. Rendering that intermediate
  // state made the strip drop a slot and immediately rebuild it.
  //
  // Reconciling once per burst collapses the pair into one model update, so
  // the strip never passes through the short state. A genuine change still
  // lands within reconcileMs.
  readonly property int reconcileMs: 60
  property var rendered: []

  function reconcile() {
    root.rendered = root.liveIds
  }

  Timer {
    id: reconcileTimer
    interval: root.reconcileMs
    repeat: false
    onTriggered: root.reconcile()
  }

  // A signal handler, not a binding: restarting a timer here is a side effect,
  // not something a binding evaluation may depend on.
  onLiveIdsChanged: {
    // The first population is not a burst - it is the strip filling in for the
    // first time - so it lands without the hold.
    if (root.rendered.length === 0) root.reconcile()
    else reconcileTimer.restart()
  }

  // The live workspace object for an id, or null for an id the strip still
  // holds while the compositor has already dropped it.
  function workspaceFor(id) {
    const vals = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (const ws of vals) if (ws.id === id) return ws
    return null
  }

  function labelFor(ws, id) {
    if (ws === null || ws === undefined) return String(id)
    return String(ws.name ?? ws.id)
  }

  // The strip's slot area, without the trailing submap badge. Slots are evenly
  // spaced and the last one leaves no gap behind it.
  readonly property int slotsWidth: {
    // The bare read keeps the dependency on the Repeater's own count, so a
    // delegate birth re-evaluates this in the same turn.
    const count = wsRepeater.count
    return count === 0 ? 0 : count * root.buttonWidth + (count - 1) * root.gap
  }

  implicitWidth: root.slotsWidth
    + (root.submapActive ? root.gap + submapText.implicitWidth + Bar.slotInset : 0)

  Component.onCompleted: Hyprland.rawEvent.connect(root.onRawEvent)
  Component.onDestruction: Hyprland.rawEvent.disconnect(root.onRawEvent)

  function onRawEvent(event) {
    if (event.name !== "submap") return
    root.submap = event.data.trim()
  }

  Repeater {
    id: wsRepeater

    model: root.rendered

    delegate: Rectangle {
      id: wsBtn

      required property int index
      required property int modelData

      // The id this slot stands for, and the live workspace behind it. The two
      // part company for the reconcile window, when the strip still shows an
      // id the compositor has already dropped - the slot keeps painting its
      // number throughout.
      readonly property int wsId: modelData
      readonly property var ws: root.workspaceFor(wsId)
      // Every reading below tolerates a null ws: a QML binding dereferences
      // its item whether or not the item is visible.
      readonly property bool focused: ws !== null && root.monitor !== null && root.monitor.activeWorkspace === ws
      readonly property bool occupied: ws !== null && !!ws.toplevels && !!ws.toplevels.values && ws.toplevels.values.length > 0
      readonly property bool urgent: ws !== null && ws.urgent === true
      readonly property real baseOpacity: focused ? 1 : occupied ? 1 : 0.5

      x: index * (root.buttonWidth + root.gap)
      width: root.buttonWidth
      height: Bar.height
      clip: true
      color: "transparent"

      Title {
        id: wsLabel

        level: 3
        anchors.verticalCenter: parent.verticalCenter
        width: wsBtn.width
        horizontalAlignment: Text.AlignHCenter
        text: root.labelFor(wsBtn.ws, wsBtn.wsId)
        color: wsBtn.urgent
          ? Ui.solid("red")
          : wsBtn.focused
            ? Ui.solid("accent")
            : Ui.solid("foreground_0")
        font.bold: wsBtn.focused
        opacity: wsBtn.urgent ? 1 : wsBtn.baseOpacity
      }

      // The slot's whole input surface.
      //
      // This is why the module sets builtinFill to false. The base fill is
      // raised above module content and is hover-enabled, so it would take
      // every click and this area would never see one. Owning the surface per
      // slot is the same arrangement Volume uses for its per-icon areas.
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
          // Left activates the workspace; right is the declarative click
          // command, exactly as the base fill routed it.
          if (mouse.button === Qt.RightButton) {
            root.clickCommand("rightClick")
            return
          }
          // A held slot may outlive its workspace during reconciliation.
          // Dispatch directly through Quickshell for an immediate compositor
          // request without spawning a hyprctl process.
          //
          // The request is Lua, not a dispatcher string: this compositor
          // evaluates a dispatch as a Lua chunk (`return hl.dispatch(<request>)`),
          // so a bare "workspace 3" fails to parse and the click does nothing.
          // Ids are positive here - special workspaces are filtered out of
          // liveIds - so the number interpolates as a Lua literal.
          if (wsBtn.ws !== null) Hyprland.dispatch("hl.dsp.focus({workspace = " + wsBtn.wsId + "})")
        }
      }
    }
  }

  // Superscript "[R]" trailing the indexes while a submap is active.
  Title {
    id: submapText

    level: 4
    x: root.slotsWidth + (root.submapActive ? root.gap : 0)
    y: 3
    visible: root.submapActive
    text: "[R]"
    color: Ui.solid("yellow")
    font.pixelSize: 8
    font.family: Ui.fontFamily
    font.bold: true
  }

  // Right-click stays declarative (shell.statusbar.workspacesRightClick via
  // BarModule.clickCommand), dispatched from each slot's own MouseArea rather
  // than from the base fill, because that fill has to be off for the per-slot
  // surface to receive any event at all.
}

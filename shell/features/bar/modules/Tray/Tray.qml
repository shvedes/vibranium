pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.SystemTray
import qs.features.bar

// Tray module. Hosts the StatusNotifier items, collapsed to zero width.
// The logout icon is its expansion trigger: hovering it slides the tray
// out to the left - because this module is the last one in the right
// zone's right-anchored row, growing it pushes every module ahead of it
// left in the same motion. It stays expanded while the mouse sits on the
// logout icon, on the tray itself, or on one of the tray's menus.
//
// Each item: left-click activates, right-click opens its DBusMenu (see
// Quickshell.DBusMenu), the wheel scrolls it.
CollapsibleSlot {
  id: root

  // Tray icons read the bar's scaled slot/canvas themselves (see TrayItem), so
  // this row does not restate them: a token copied here is a value the icons
  // do not read, and they would follow the real one only by coincidence.
  // Spacing/padding are 0 like Zone/Group (slots abut with 0 gap, canvas
  // centering provides the visual padding).
  readonly property int sidePad: 0
  readonly property int spacing: 0

  // Open while the logout trigger (the shared per-window hover state),
  // this module itself, or one of this module's menus keeps it up.
  // `=== true` so a mid-reload undefined read (window being torn down)
  // coerces instead of warning. With the logout module disabled there is
  // no trigger - the tray then stays expanded at all times.
  function triggerActive() {
    // Reading properties on a module/window being torn down during reload
    // throws; treat that frame as not-triggered. Whole body in the try so
    // even the barWindow read on a half-destroyed root is covered.
    try {
      const w = root.barWindow
      if (!w) return false
      return w.trayTriggerHovered === true
    } catch (e) { return false }
  }
  // While a slot-reorder drag is live on this bar window the session group
  // stays fully static: hovering it must not even latch the tray, or it
  // would pop open the instant the drag ends (the drag suppressed the slide
  // but the hover machinery kept running and armed the latch). Gate the
  // hover reads themselves so nothing accumulates during a drag.
  // Inert while a slot-reorder drag runs AND for a short grace after it,
  // so a rearrange that leaves the cursor over the session doesn't slide
  // the tray open on release; a deliberate fresh hover reopens it.
  function windowFlag(name): bool {
    try {
      const w = root.barWindow
      if (!w) return false
      return w[name] === true
    } catch (e) { return false }
  }
  readonly property bool dragMode: root.windowFlag("recentDragActive")
  readonly property bool triggerHovered: !root.dragMode && root.triggerActive()
  // Whole-module hover is the fill AND any item: sibling MouseAreas do not
  // share hover (moving onto the top one exits the one below), so the fill
  // alone goes false over the icons while the icons themselves go true.
  // The row sits above the fill (z) so the items actually receive hover for
  // tooltips/clicks; OR-ing both keeps the tray open over gaps (fill) and
  // over icons (items). More icons means more icon area, which is why the
  // close got more likely with more items.
  property int _itemHoverCount: 0
  readonly property bool selfHovered: !root.dragMode && (root.hovered || root._itemHoverCount > 0)
  readonly property bool hasItems: SystemTray.items.values.length > 0
  // The expansion trigger (logout) is a group member alongside the tray,
  // so whenever this module is rendered the trigger is present too. Ask the
  // group (not the raw layout) so the tray stays robust to composition
  // changes.
  readonly property bool logoutPresent: Bar.isModuleVisible("logout")

  // Hover latch. Briefly holds `open` after the last hover loss so the
  // handoff between trigger -> fill -> item (and between adjacent items,
  // where the leave fires just before the next enter) never flickers the
  // slide. Hover here is seamless (the logout edge is static, fill covers
  // gaps and items cover icons via the OR in selfHovered), so the grace
  // only needs to bridge that ms-level handoff - 50ms closes fast once the
  // cursor truly leaves, instead of lingering open.
  property bool hoverLatch: false
  property int graceMs: 50

  Timer {
    id: graceTimer

    interval: root.graceMs
    onTriggered: root.hoverLatch = false
  }

  function refreshLatch() {
    if (root.triggerHovered || root.selfHovered) {
      graceTimer.stop()
      root.hoverLatch = true
    } else {
      graceTimer.restart()
    }
  }
  onTriggerHoveredChanged: root.refreshLatch()
  onSelfHoveredChanged: root.refreshLatch()

  // Dropping the latch the moment a drag engages guarantees the tray is
  // fully collapsed at drag end - it only reopens if the user deliberately
  // hovers it fresh afterwards, never because the drag swept over it.
  onDragModeChanged: if (root.dragMode) {
    graceTimer.stop()
    root.hoverLatch = false
    root._itemHoverCount = 0
  }

  readonly property bool open: !root.dragMode
    && (!root.logoutPresent || root.hoverLatch || trayMenu.open)

  // A collapsing tray must not leave its tooltip behind: the collapse can
  // run without a leave (anchor destroyed, or the clip swallows the exit),
  // and the host would otherwise keep serving a bubble for a tray that is
  // already shut. Targeted retire, so other modules' bubbles survive.
  onOpenChanged: {
    if (root.open) return
    try {
      const host = root.barWindow ? root.barWindow.toolTipHost : null
      if (host) host.cancelTray()
    } catch (e) {}
  }

  // Collapsible slot (see CollapsibleSlot.qml, collapseInOut for the
  // easing rationale): 1 expanded, 0 collapsed. Zero width with no items.
  collapseShown: root.open
  collapseFull: root.hasItems ? root.contentWidth : 0
  collapseInOut: true
  collapseAnimated: true

  readonly property real contentWidth: trayRow.implicitWidth + root.sidePad * 2

  Row {
    id: trayRow

    // Above the built-in fill (fill z=1) so the per-item MouseAreas receive
    // hover/clicks for tooltips and menus; the fill below still covers the
    // gaps. See selfHovered: fill XOR items would each go false alone.
    z: 2
    // Hug the right (logout) side so the tray 'expands from the left': a
    // leftward-growing tray pinned on its logout edge reveals the icon
    // nearest logout first and extends the rest to the left - the clip
    // shows the rightmost icons, then progressively more as it widens.
    anchors.right: parent.right
    anchors.rightMargin: root.sidePad
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.spacing

    Repeater {
      model: SystemTray.items

      delegate: TrayItem {
        required property var modelData

        item: modelData
        barWindow: root.barWindow
        // When a custom right-click command is set the fill below takes
        // Right (explicit opt-in) - withhold it here so the press falls
        // through to the fill instead of opening the item DBusMenu.
        acceptedButtons: root.clickSetting("rightClick") !== "" ? (Qt.LeftButton | Qt.MiddleButton) : (Qt.LeftButton | Qt.RightButton | Qt.MiddleButton)
        onContainsMouseChanged: {
          if (containsMouse) {
            root._itemHoverCount++
          } else {
            root._itemHoverCount = Math.max(0, root._itemHoverCount - 1)
          }
        }
        Component.onDestruction: {
          // A delegate destroyed while hovered (item removed) never emits
          // the leave - release its hold so the tray cannot latch open.
          if (containsMouse) root._itemHoverCount = Math.max(0, root._itemHoverCount - 1)
        }
        onMenuRequested: (handle, anchor) => {
          // The menu replaces the tooltip as this item's context.
          // Null-guarded: Zone/Group loaders are async so barWindow is null
          // at binding-eval time, same as every host: binding above.
          const host = root.barWindow ? root.barWindow.toolTipHost : null
          if (host) host.hide()
          trayMenu.openFor(handle, anchor)
        }
        onTooltipRequested: (anchor, text) => {
          const host = root.barWindow ? root.barWindow.toolTipHost : null
          if (host) host.show(anchor, text, root.barWindow)
        }
        onTooltipReleased: anchor => {
          const host = root.barWindow ? root.barWindow.toolTipHost : null
          if (host) host.cancel(anchor)
        }
      }
    }
  }

  // Whole-module hover keeps the tray expanded while crossing it. The row
  // sits above the built-in fill (z), so the per-item MouseAreas receive
  // hover/clicks first and the fill below still covers the gaps: accepting
  // Left/Right here would still swallow presses the items withheld (Right
  // with a custom command falls through to here), and tray menus could never
  // open. Only when a custom right-click command is configured does the fill
  // take right-clicks as the explicit opt-in and run it.
  //
  // That gate IS the tray's non-command fallback path, so the handler reads
  // the return instead of discarding it. The tray's own right-click behaviour
  // is the item's DBusMenu, and it is reached by the gate withholding the
  // button rather than from here: the items sit above the fill, so a press
  // they accept never reaches the fill below. Both halves read the same
  // setting, so the branch below is reached only when they disagree - the
  // setting cleared between the gate and the click - and the module has no
  // menu of its own to open for a press that took no item with it.
  fillButtons: root.clickSetting("rightClick") !== "" ? Qt.RightButton : Qt.NoButton
  onClicked: {
    if (root.clickCommand("rightClick")) return
  }

  // One shared tooltip bubble for every item (a layer surface per item
  // would be wasteful) - served by the BarView host.

  TrayMenu {
    id: trayMenu

    anchorWindow: root.barWindow
    barPosition: Bar.position
  }

  // A hidden bar must not leave its tray menus floating on screen.
  Connections {
    target: Bar

    function onEnabledChanged() {
      if (!Bar.enabled) trayMenu.close()
    }
  }
}








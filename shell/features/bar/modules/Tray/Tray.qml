pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.SystemTray
import qs.common
import qs.features.bar
import qs.features.bar.control

// Tray module. Hosts the StatusNotifier items in a collapsible slot with its
// own disclosure affordance: a left-pointing chevron pinned to the slot's
// right edge. Hovering the chevron slides the icons out to the left - the row
// is right-anchored inside the clipped slot, so the clip reveals the icons
// nearest the chevron first and extends the rest leftward. The chevron
// cross-fades to accent while the tray is open.
//
// The hover latch holds the tray open across the chevron -> item handoff and
// while one of its menus is up. Each item: left-click activates, right-click
// opens its DBusMenu, middle-click secondary-activates, wheel scrolls.
CollapsibleSlot {
  id: root

  // The disclosure affordance stays visible at every slide value, so a
  // collapsed tray is still a chevron-sized target the user can hover. Only
  // the icons beyond it are animated by the slide.
  readonly property int chevronSlot: Ui.chevronW
  readonly property int spacing: 0

  // The chevron is the trigger. It lives in this module, so the tray neither
  // borrows an adjacent module's hover nor asks the bar whether a group
  // partner is present. `=== true` keeps a torn-down frame quiet.
  function triggerActive() {
    try {
      return chevronArea.containsMouse === true
    } catch (e) { return false }
  }
  // A slot-reorder drag suppresses the slide entirely: reopening under a
  // moving cursor would shift the row the drag is measuring. The window's
  // grace flag keeps that true briefly after the drag, so a rearrange that
  // leaves the pointer on the chevron needs a fresh hover to expand it.
  function windowFlag(name): bool {
    try {
      const w = root.barWindow
      if (!w) return false
      return w[name] === true
    } catch (e) { return false }
  }
  readonly property bool dragMode: root.windowFlag("recentDragActive")
  // A drag invalidates a hover that was already on the chevron: the pointer
  // can stay parked there through the whole grace, and re-arming on the flag's
  // falling edge would pop the tray open with no fresh gesture. Only a new
  // chevron enter after the freeze lifts clears the invalidation.
  property bool hoverInvalidated: false
  readonly property bool triggerHovered: !root.dragMode
    && !root.hoverInvalidated && root.triggerActive()
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
  // An empty tray shrinks out of the row instead of snapping in one frame.
  // Width rides Ui.slowMs and the fade Ui.fastMs, the same pair the zone uses
  // when a module enters or leaves, so the neighbor slots glide with it.
  property real presence: root.hasItems ? 1 : 0
  Behavior on presence {
    enabled: MotionPolicy.enabled
    NumberAnimation { duration: Ui.slowMs; easing.type: Easing.OutCubic }
  }
  property real presenceFade: root.hasItems ? 1 : 0
  Behavior on presenceFade {
    enabled: MotionPolicy.enabled
    NumberAnimation { duration: Ui.fastMs }
  }
  // Hidden only once the shrink finishes, so the outgoing frames still paint.
  visible: root.presence > 0
  opacity: root.presenceFade

  // Hover latch. Briefly holds `open` after the last hover loss so the
  // handoff between chevron -> fill -> item (and between adjacent items,
  // where the leave fires just before the next enter) never flickers the
  // slide. The handoff is seamless - the chevron is static, the fill covers
  // gaps and items cover icons via the OR in selfHovered - so the grace only
  // needs to bridge that ms-level handoff: 50ms closes fast once the cursor
  // truly leaves, instead of lingering open.
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
    root.hoverInvalidated = true
  }

  readonly property bool open: !root.dragMode
    && (root.hoverLatch || trayMenu.open)

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

  // Collapsible slot (see CollapsibleSlot.qml, collapseInOut for the easing
  // rationale): 1 expanded, 0 collapsed. The chevron is outside the slide and
  // occupies chevronSlot while there are icons to reveal; with none, the whole
  // slot - chevron included - measures zero.
  collapseShown: root.open
  collapseFull: root.contentWidth
  collapseInOut: true
  collapseAnimated: true

  implicitWidth: Math.round(root.presence
    * (root.chevronSlot + Math.round(root.slide * root.collapseFull)))

  readonly property real contentWidth: trayRow.implicitWidth

  Row {
    id: trayRow

    // Above the built-in fill (fill z=1) so the per-item MouseAreas receive
    // hover/clicks for tooltips and menus; the fill below still covers the
    // gaps. See selfHovered: fill XOR items would each go false alone.
    z: 2
    // Hugging the chevron's left edge makes the slide reveal icons from the
    // right inward: the icon nearest the chevron appears first, and the rest
    // extend to the left as the clipped slot widens.
    anchors.right: parent.right
    anchors.rightMargin: root.chevronSlot
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

  // Disclosure affordance and trigger in one. The chevron points at the
  // icons the slide reveals, stays visible while collapsed, and cross-fades
  // to accent once the tray is open. It is raised above the icon row so its
  // hover is never stolen by an icon.
  MouseArea {
    id: chevronArea

    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.chevronSlot
    height: parent.height
    z: 3
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    // Right-click belongs to the item DBusMenus, or to the configured
    // command on the fill below; the chevron consumes hover and left-click.
    acceptedButtons: Qt.LeftButton
    // A hover arriving while the window is frozen is not a fresh gesture.
    // Wait for a rising edge after the freeze to clear the drag invalidation.
    onContainsMouseChanged: {
      if (containsMouse && !root.dragMode) root.hoverInvalidated = false
    }

    // A themed SVG from the shipped set, so the affordance carries the same
    // stroke, weight and DPR treatment as every other bar icon. Two stacked
    // full-strength copies cross-fade rather than swapping a recolor URL: the
    // move to accent is one continuous fade, gated by the shared motion
    // policy. The resting copy uses the same tone as the neighboring icons.
    Icon {
      anchors.centerIn: parent
      size: root.chevronSlot
      name: "chevron"
      // The shipped glyph points right; the tray opens leftward.
      rotation: 180
      colorKey: "foreground_0"
      opacity: root.open ? 0 : 1
      visible: opacity > 0

      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
    }

    Icon {
      anchors.centerIn: parent
      size: root.chevronSlot
      name: "chevron"
      rotation: 180
      colorKey: "accent"
      opacity: root.open ? 1 : 0
      visible: opacity > 0

      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
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
  // the return instead of discarding it. The tray's own right-click behavior
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
    barPosition: BarControl.position
  }

  // A hidden bar must not leave its tray menus floating on screen.
  Connections {
    target: BarControl

    function onEnabledChanged() {
      if (!BarControl.enabled) trayMenu.close()
    }
  }
}

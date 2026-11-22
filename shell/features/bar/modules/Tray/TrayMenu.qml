pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.common
import "../../../../common/math/Range.js" as Range

// DBusMenu popup for a tray item. A transparent full-screen overlay (same
// pattern as the island and tooltip) parks a card under the clicked item.
// Entries come from a QsMenuOpener fed the item's DBusMenuHandle; the
// Quickshell.DBusMenu machinery handles the remote protocol (AboutToShow,
// layout updates, click events). Submenu entries push onto a stack with a
// back row leading home - arbitrary depth, no nested popups.
//
// Dismissal mirrors the island: a focus grab routes input to the menu and
// its bar window, and a full-screen net catches any click outside the
// card; Escape pops submenus first, then closes.
LayerSurface {
  id: root

  property var menuHandle: null
  property Item anchorItem: null
  property var anchorWindow: null
  property string barPosition: "top"
  property int margin: Ui.s
  property int maxHeight: 480

  property bool open: false
  signal menuClosed()

  // See the header: one screen, one visit.
  property var _claimToken: null

  // Whether the card has been parked for the current open. The surface maps at
  // its placeholder size, so the open-time park has to run against the screen;
  // until it has, the card stays transparent rather than drawn at 0,0.
  property bool _parked: false

  // One deferred park per turn, retired on every logical menu change. The
  // epoch captured at scheduling keeps a pass queued for a closed or replaced
  // menu from parking the card with stale geometry (IslandHost coalescer).
  property int _parkEpoch: 0
  property bool _parkQueued: false

  // Submenu stack: each level is the DBusMenuItem whose children are
  // showing; empty means the root menu.
  property var stack: []
  readonly property var currentHandle: root.stack.length > 0 ? root.stack[root.stack.length - 1] : root.menuHandle
  readonly property var menuEntries: opener.children ? opener.children.values : []

  function anchorScreen(): var {
    try {
      const w = root.anchorWindow
      return w ? w.screen : null
    } catch (e) { return null }
  }
  function grabWindows(): var {
    try {
      const w = root.anchorWindow
      return w ? [root, w] : [root]
    } catch (e) { return [root] }
  }

  screen: root.anchorScreen()
  visible: root.open || card.opacity > 0
  surface: "vibranium:popup"
  // OnDemand while open so Escape can reach the key scope; released the
  // moment the logical close fires.
  WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

  // Outside-click dismissal: input is routed to the menu and its bar
  // window while open; clicking anywhere else clears the grab and closes.
  HyprlandFocusGrab {
    active: root.open
    windows: root.grabWindows()
    onCleared: root.close()
  }

  // Dismissal net: any click outside the card closes the menu.
  MouseArea {
    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    onPressed: root.close()
  }

  QsMenuOpener {
    id: opener

    menu: root.currentHandle
  }

  function refreshCurrent() {
    // Some applications don't push layout updates on their own; nudge the
    // remote menu to refresh before (re)showing a level.
    const h = root.currentHandle
    if (h && typeof h.updateLayout === "function") h.updateLayout()
  }

  function openFor(handle, anchor) {
    if (!handle) return
    root.menuHandle = handle
    root.anchorItem = anchor
    root.stack = []
    card.contentY = 0
    root.open = true
    // Park before the surface maps. Its first present is built from the card's
    // coordinates, and the deferred pass used to leave it at 0,0 for a frame.
    // The anchor's bar window and its screen are known while this surface is
    // still unmapped.
    root._bumpParkEpoch()
    root._parked = false
    root.positionCard()
    if (root._claimToken === null) {
      root._claimToken = SurfaceClaim.claim("trayMenu", root.close, root)
    }
    root.refreshCurrent()
  }

  function close() {
    if (!root.open) return
    root.open = false
    root._bumpParkEpoch()
    root._parked = false
    if (root._claimToken !== null) {
      SurfaceClaim.release(root._claimToken)
      root._claimToken = null
    }
    root.stack = []
    root.menuClosed()
  }

  function pushSubmenu(entry) {
    root.stack = root.stack.concat([entry])
    root._bumpParkEpoch()
    card.contentY = 0
    Qt.callLater(root.refreshCurrent)
    root.requestPark()
  }

  function popSubmenu() {
    if (root.stack.length === 0) return
    root.stack = root.stack.slice(0, -1)
    root._bumpParkEpoch()
    root.requestPark()
  }

  // The card's rows: the current level's DBusMenu entries, plus a leading Back
  // row while inside a submenu. Mapped into the shared menu's record shape
  // here, so the menu itself knows nothing about DBus. `payload` carries the
  // QsMenuEntry untouched - activation still forwards to the application
  // through the entry's own `triggered()`.
  readonly property var rows: {
    const out = []
    if (root.stack.length > 0) {
      // The shipped icon set has no left chevron, so the glyph stays in the
      // label rather than becoming an empty 16px icon slot.
      out.push({ label: "‹ Back", payload: { back: true } })
    }
    const entries = root.menuEntries
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i]
      if (!e) continue
      out.push({
        label: String(e.text ?? ""),
        iconSource: String(e.icon ?? ""),
        enabled: e.enabled !== false,
        separator: e.isSeparator === true,
        indicator: e.buttonType === QsMenuButtonType.CheckBox ? "check"
          : (e.buttonType === QsMenuButtonType.RadioButton ? "radio" : ""),
        checked: e.checkState === Qt.Checked,
        partial: e.checkState === Qt.PartiallyChecked,
        hasChildren: e.hasChildren === true,
        payload: { entry: e }
      })
    }
    return out
  }

  // The card, parked under the anchor item -> the shared menu primitive.
  ContextMenu {
    id: card

    entries: root.rows
    // A remote menu can be longer than the screen; the shared card scrolls
    // past `maxHeight`.
    maxHeight: root.maxHeight
    opacity: root.open && root._parked ? 1 : 0
    // A remote menu arrives asynchronously: the open-time park runs before the
    // entries exist, so the width they give the card re-parks it. Height has
    // its own handler below - a second one here is a duplicate handler and a
    // load-time error for the whole type.
    onWidthChanged: if (root.open) root.requestPark()

    // Menu content can land after open (DBus aboutToShow, late layout
    // updates): for a bottom bar the card must grow UP from its bottom edge
    // (pinned just above the bar) rather than extend downward off-screen,
    // so re-park whenever the card's own height changes.
    onHeightChanged: if (root.open) root.requestPark()

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs }
    }

    onActivated: entry => {
      const payload = entry.payload ?? ({})
      if (payload.back === true) {
        root.popSubmenu()
        return
      }
      const target = payload.entry
      if (!target) return
      if (target.hasChildren === true) {
        root.pushSubmenu(target)
        return
      }
      // Emitting the `triggered` signal is how a QsMenuEntry is activated;
      // for a DBusMenuItem the C++ side forwards it to the app as the
      // "clicked" event. Without this, selecting an entry only closed the
      // menu and did nothing.
      if (typeof target.triggered === "function") target.triggered()
      root.close()
    }
  }

  FocusScope {
    id: keyScope

    anchors.fill: parent
    focus: root.open

    Keys.onEscapePressed: event => {
      if (root.stack.length > 0) root.popSubmenu()
      else root.close()
      event.accepted = true
    }
  }

  // Every logical menu change starts a fresh park cycle: close(), openFor()
  // and both level changes retire the coalescer, so a stale callback cannot
  // clear the new cycle's latch.
  function _bumpParkEpoch() {
    root._parkEpoch++
    root._parkQueued = false
  }

  // Coalesce the geometry-triggered parks to one per event-loop turn and
  // close over the epoch. A pass queued for a replaced menu is inert; the
  // new level's own settle hooks schedule its park.
  function requestPark() {
    if (root._parkQueued) return
    root._parkQueued = true
    const epoch = root._parkEpoch
    Qt.callLater(() => {
      if (epoch !== root._parkEpoch) return
      root._parkQueued = false
      root.positionCard(epoch)
    })
  }

  // Park the card next to its anchor on every open and when the surface
  // maps/configures (the first pass runs pre-configure, so the same
  // settle hooks as the island re-run it at real coordinates).
  function positionCard(epoch) {
    if (epoch !== undefined && epoch !== root._parkEpoch) return
    if (!root.anchorItem || !root.anchorWindow) return
    const w = card.width
    const h = card.height
    if (!(w > 0) || !(h > 0)) return
    const barH = root.anchorWindow.height
    const anchorX = root.anchorItem.mapToItem(root.anchorWindow.contentItem, 0, 0).x
    let x = anchorX + root.anchorItem.width / 2 - w / 2
    // The settle is the SCREEN's, not this surface's. The popup is still at its
    // 100x100 placeholder when it opens, so clamping against root.width put the
    // card at the clamp's lower bound - the top-left corner. The bar window is
    // mapped and configured, and its screen is the one being placed on.
    // qmllint disable missing-property
    const screenW = root.anchorWindow.screen ? root.anchorWindow.screen.width : root.width
    const screenH = root.anchorWindow.screen ? root.anchorWindow.screen.height : root.height
    // qmllint enable missing-property
    let y = root.barPosition === "bottom" ? screenH - barH - h - root.margin : barH + root.margin
    x = Range.clamp(x, root.margin, screenW - w - root.margin)
    y = Range.clamp(y, root.margin, screenH - h - root.margin)
    card.x = Math.round(x)
    card.y = Math.round(y)
    root._parked = true
  }

  onOpenChanged: {
    if (root.open) {
      root.requestPark()
      Qt.callLater(() => keyScope.forceActiveFocus())
    }
  }
  onAnchorItemChanged: if (root.open) root.requestPark()
  onAnchorWindowChanged: if (root.open) root.requestPark()
  onBarPositionChanged: if (root.open) root.requestPark()
  onBackingWindowVisibleChanged: if (root.backingWindowVisible && root.open) root.requestPark()
  onWidthChanged: if (root.width > 100 && root.open) root.requestPark()
  onHeightChanged: if (root.height > 100 && root.open) root.requestPark()
}

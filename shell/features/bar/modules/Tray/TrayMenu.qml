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
PanelWindow {
  id: root

  property var menuHandle: null
  property Item anchorItem: null
  property var anchorWindow: null
  property string barPosition: "top"
  property int margin: Ui.s
  property int maxHeight: 480

  property bool open: false
  signal menuClosed()

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
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  WlrLayershell.namespace: "vibranium:tray"
  WlrLayershell.layer: WlrLayer.Overlay
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
    root.refreshCurrent()
  }

  function close() {
    if (!root.open) return
    root.open = false
    root.stack = []
    root.menuClosed()
  }

  function pushSubmenu(entry) {
    root.stack = root.stack.concat([entry])
    card.contentY = 0
    Qt.callLater(root.refreshCurrent)
    Qt.callLater(root.positionCard)
  }

  function popSubmenu() {
    if (root.stack.length === 0) return
    root.stack = root.stack.slice(0, -1)
    Qt.callLater(root.positionCard)
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
    opacity: root.open ? 1 : 0

    // Menu content can land after open (DBus aboutToShow, late layout
    // updates): for a bottom bar the card must grow UP from its bottom edge
    // (pinned just above the bar) rather than extend downward off-screen,
    // so re-park whenever the card's own height changes.
    onHeightChanged: if (root.open) Qt.callLater(root.positionCard)

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

  // Park the card next to its anchor on every open and when the surface
  // maps/configures (the first pass runs pre-configure, so the same
  // settle hooks as the island re-run it at real coordinates).
  function positionCard() {
    if (!root.anchorItem || !root.anchorWindow) return
    const w = card.width
    const h = card.height
    const barH = root.anchorWindow.height
    const anchorX = root.anchorItem.mapToItem(root.anchorWindow.contentItem, 0, 0).x
    let x = anchorX + root.anchorItem.width / 2 - w / 2
    let y = root.barPosition === "bottom" ? root.height - barH - h - root.margin : barH + root.margin
    x = Range.clamp(x, root.margin, root.width - w - root.margin)
    y = Range.clamp(y, root.margin, root.height - h - root.margin)
    card.x = Math.round(x)
    card.y = Math.round(y)
  }

  onOpenChanged: {
    if (root.open) {
      Qt.callLater(root.positionCard)
      Qt.callLater(() => keyScope.forceActiveFocus())
    }
  }
  onAnchorItemChanged: if (root.open) Qt.callLater(root.positionCard)
  onAnchorWindowChanged: if (root.open) Qt.callLater(root.positionCard)
  onBarPositionChanged: if (root.open) Qt.callLater(root.positionCard)
  onBackingWindowVisibleChanged: if (root.backingWindowVisible && root.open) Qt.callLater(root.positionCard)
  onWidthChanged: if (root.width > 100 && root.open) Qt.callLater(root.positionCard)
  onHeightChanged: if (root.height > 100 && root.open) Qt.callLater(root.positionCard)
}

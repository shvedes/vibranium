pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.common
import qs.features.bar

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
  property int rowHeight: Ui.trayRowH
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
    root.updateCardWidth()
    root.anchorItem = anchor
    root.stack = []
    list.contentY = 0
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
    list.contentY = 0
    root.updateCardWidth()
    Qt.callLater(root.refreshCurrent)
    Qt.callLater(root.positionCard)
  }

  function popSubmenu() {
    if (root.stack.length === 0) return
    root.stack = root.stack.slice(0, -1)
    root.updateCardWidth()
    Qt.callLater(root.positionCard)
  }

  // Content-fit width like the settings menus: longest visible label
  // plus the fixed chrome columns, clamped.
  TextMetrics {
    id: measure

    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
  }

  property int cardWidth: 180

  // Content-fit width: longest visible label plus the fixed chrome columns
  // (84 = margins + three chrome columns + spacings), clamped to 180..320.
  // Imperative because measuring mutates the shared TextMetrics; doing it
  // inside a binding that reads the metrics is a binding loop.
  function updateCardWidth() {
    let maxW = 0
    const entries = root.menuEntries
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i]
      if (!e || e.isSeparator === true) continue
      measure.text = String(e.text ?? "")
      if (measure.width > maxW) maxW = measure.width
    }
    root.cardWidth = Math.max(180, Math.min(Math.round(maxW) + 84, 320))
  }
  onMenuEntriesChanged: root.updateCardWidth()

  // The card, parked under the anchor item -> shared Card primitive.
  Card {
    id: card

    width: root.cardWidth
    height: Math.min(listCol.implicitHeight, root.maxHeight) + 2 * Ui.outerPad
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

    Flickable {
      id: list

      anchors.fill: card.contentArea
      contentWidth: width
      contentHeight: listCol.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      clip: true

      Column {
        id: listCol

        width: parent.width
        spacing: Ui.trayListSpacing

        // Back row while inside a submenu.
        Item {
          width: root.cardWidth - 2 * Ui.outerPad
          height: root.stack.length > 0 ? root.rowHeight : 0
          visible: root.stack.length > 0
          clip: true

          Rectangle {
            anchors.fill: parent
            color: Ui.tint("foreground_0", 0.07)
            opacity: backHover.containsMouse ? 1 : 0

            Behavior on opacity {
              enabled: MotionPolicy.enabled
              NumberAnimation { duration: Ui.fastMs }
            }
          }

          MouseArea {
            id: backHover

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.popSubmenu()
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Ui.m
            anchors.rightMargin: Ui.m
            spacing: 8

            Title {
              level: 3
              text: "‹"
              color: Ui.solid("foreground_0")
              verticalAlignment: Text.AlignVCenter
            }

            Title {
              level: 3
              text: "Back"
              color: Ui.solid("foreground_0")
              verticalAlignment: Text.AlignVCenter
            }
          }
        }

        Repeater {
          model: root.menuEntries

          delegate: TrayMenuRow {
            required property var modelData

            entry: modelData
            rowHeight: root.rowHeight
            rowWidth: root.cardWidth - 2 * Ui.outerPad
            onActivated: entry => {
              // Emitting the `triggered` signal is how a QsMenuEntry is
              // activated; for a DBusMenuItem the C++ side forwards it to
              // the app as the "clicked" event. Without this, selecting an
              // entry only closed the menu and did nothing.
              if (entry && typeof entry.triggered === "function") entry.triggered()
              root.close()
            }
            onSubmenuRequested: entry => root.pushSubmenu(entry)
          }
        }
      }
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
    x = Math.max(root.margin, Math.min(x, root.width - w - root.margin))
    y = Math.max(root.margin, Math.min(y, root.height - h - root.margin))
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
  onCardWidthChanged: if (root.open) Qt.callLater(root.positionCard)
  onBackingWindowVisibleChanged: if (root.backingWindowVisible && root.open) Qt.callLater(root.positionCard)
  onWidthChanged: if (root.width > 100 && root.open) Qt.callLater(root.positionCard)
  onHeightChanged: if (root.height > 100 && root.open) Qt.callLater(root.positionCard)
}

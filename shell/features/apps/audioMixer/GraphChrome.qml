pragma ComponentBehavior: Bound

// The graph tab's chrome: the toolbar, the status line and the legend.
//
// It is a separate component because it is the one part of the tab that must
// NOT pan or scale: a refusal printed at 0.35 zoom is unreadable, and a button
// that moves under the pointer is a button that cannot be clicked. The canvas
// starts at this component's bottom edge, so "outside the canvas" is a layout
// fact rather than a paint order.
//
// It talks to the tab through values and signals, not through the tab object:
// the chrome reads four things (whether a legend is open, whether a line is
// selected, and the status line's text and colour) and asks for five actions.
// That is the whole contract, and it is checked by the linter rather than only
// at runtime.

import QtQuick
import qs.common

Item {
  id: chromeRoot

  // In: the tab's state, as values.
  property bool legendOpen: false
  property bool canDisconnect: false
  property string statusText: ""
  property string statusColor: ""
  // Out: the tab's actions, as requests. The chrome never writes the tab.
  signal rescanRequested()
  signal layoutResetRequested()
  signal viewResetRequested()
  signal disconnectRequested()
  signal helpToggled()

  height: actionRow.height

  component GraphTabAction: Rectangle {
    id: action

    property string text: ""
    // The destroying action. Red chrome, so Disconnect does not read as one more
    // label beside three neutral ones.
    property bool danger: false
    property bool hover: false
    property bool press: false

    signal triggered()

    implicitWidth: actionLabel.implicitWidth + 2 * Ui.s
    implicitHeight: Math.max(22, actionLabel.implicitHeight + Ui.s)
    radius: RoundingPolicy.radius
    color: !action.enabled ? Ui.tint("foreground_1", 0.03)
      : (action.press ? Ui.tint(action.danger ? "red" : "accent", 0.22)
        : (action.hover ? Ui.tint(action.danger ? "red" : "accent", 0.12)
          : Ui.tint("foreground_1", 0.05)))
    border.width: 1
    border.color: action.danger
      ? Ui.tint("red", 0.55)
      : Ui.tint("background_3", 0.8)

    Behavior on color { ColorAnim {} }
    Behavior on border.color { ColorAnim {} }

    Title {
      id: actionLabel

      anchors.centerIn: parent
      level: 5
      text: action.text
      elide: Text.ElideRight
      font.bold: action.danger
      color: !action.enabled ? Ui.tint("foreground_1", 0.4)
        : action.danger ? Ui.solid("red") : Ui.solid("foreground_1")
    }

    MouseArea {
      anchors.fill: parent
      enabled: action.enabled
      hoverEnabled: action.enabled
      cursorShape: action.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onPressed: action.press = true
      onReleased: action.press = false
      onExited: action.press = false
      onCanceled: action.press = false
      onClicked: action.triggered()
    }

    HoverHandler {
      onHoveredChanged: action.hover = hovered
    }

    Accessible.role: Accessible.Button
    Accessible.name: action.text
  }

  Row {
    id: actionRow

    anchors.top: parent.top
    anchors.right: parent.right
    spacing: Ui.s

    GraphTabAction {
      text: "Rescan ports"
      onTriggered: chromeRoot.rescanRequested()
    }

    GraphTabAction {
      text: "Reset layout"
      onTriggered: chromeRoot.layoutResetRequested()
    }

    GraphTabAction {
      text: "Reset view"
      onTriggered: chromeRoot.viewResetRequested()
    }

    GraphTabAction {
      text: "Disconnect"
      danger: true
      enabled: chromeRoot.canDisconnect
      onTriggered: chromeRoot.disconnectRequested()
    }

    // The one control in this row that writes nothing: the shipped `info` mark,
    // wearing the shell's own icon button so it hovers and presses like every
    // other icon in the tree. Its hover tip names it; the click pins the legend
    // below it, which is a tooltip with more in it than a line of text.
    IconButton {
      id: helpButton

      name: "info"
      tipText: "How the graph works"
      slotSize: 24
      // Eighteen in a twenty-four slot rather than fifteen: the difference has
      // to be even for the glyph to land on a whole pixel, and the info mark
      // needs the room - at fifteen its dot merges into the stem and the glyph
      // reads as leaning off its own centre.
      iconSize: 18
      onClicked: chromeRoot.helpToggled()
    }
  }

  Title {
    id: statusLine

    anchors.left: parent.left
    anchors.right: actionRow.left
    anchors.rightMargin: Ui.m
    anchors.verticalCenter: actionRow.verticalCenter
    level: 5
    text: chromeRoot.statusText
    elide: Text.ElideRight
    // The status function's empty states carry no colour, and a Title with a
    // blank colour is a runtime error rather than an invisible one.
    color: chromeRoot.statusColor !== "" ? chromeRoot.statusColor : "transparent"
  }

  // The canvas's whole language is a mark and a gesture, and neither can say
  // what it is. The panel that says it is a component of its own: it is a
  // self-contained picture of the vocabulary, it shares nothing with the canvas
  // but the row it hangs under, and a second copy here would be two
  // descriptions of one legend, free to disagree about a colour or a gesture.
  GraphLegend {
    id: legend

    open: chromeRoot.legendOpen
    // The chrome row the bubble hangs under, and whose right edge it shares.
    anchorItem: actionRow
  }
}

pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One slot of a grid-layout page (page.layout === "grid", see MenuLib
// buildPage). Three shapes:
//   action cell  - glyph centered in a square hit target
//   submenu cell - category link, icon or label instead of a glyph
//   header/spacer- non-selectable chrome slots woven into the model by
//                  MenuPanel.composeGridRows (this GridView build has no
//                  native sections); headers span the card width.
// Selection paints instantly like list rows; hovering MOVES THE CURSOR
// instead of painting its own fill, so a parked pointer leaves no ghost
// tint behind keyboard navigation (same rule as Entry). Corners follow
// RoundingPolicy across the menu module.
Rectangle {
  id: cell

  // Model-injected identity; `itm` mirrors Entry's payload alias so
  // panel-side cursor checks stay shape-identical across both views. A
  // ScriptModel exposes exactly one role and it is the whole record, so
  // the record IS the cell row and `modelData` is what `itm` names - there
  // is no wrapper to unwrap and no `key` role to declare (it would have no
  // source, and a `required` property with no source is a hard "Cannot
  // create delegate").
  required property var modelData
  required property int index

  readonly property var itm: modelData
  readonly property bool isLink: !!modelData && modelData.type === "submenu"
  readonly property bool isHeader: !!modelData && modelData.type === "header"
  readonly property bool isSpacer: !!modelData && modelData.type === "spacer"

  readonly property var view: GridView.view

  property bool sel: false

  signal activated()

  // Glyph preference: the value slot carries the raw emoji (page-command
  // substitution source); the label's first code point is the fallback.
  readonly property string glyph: {
    const v = modelData ? String(modelData.value ?? "") : ""
    if (v !== "") return v
    const cps = Array.from(modelData ? String(modelData.label ?? "") : "")
    return cps.length > 0 ? cps[0] : ""
  }

  readonly property string linkIconName: modelData ? String(modelData.icon ?? "") : ""

  visible: !isSpacer
  color: sel && !isHeader ? Ui.tint("background_2", 1) : "transparent"
  // Cell corners follow RoundingPolicy (hypr.decoration.rounding).
  radius: RoundingPolicy.radius
  width: view ? (isHeader ? view.width : view.cellWidth) : 100
  height: view ? view.cellHeight : 46

  Text {
    anchors.fill: parent
    // Gated on the same terms as `visible` below: an invisible Text still
    // shapes for its implicit size, so a full label held here forces a
    // fontconfig fallback shaping the delegate never paints.
    text: (!cell.isHeader && !cell.isLink && !cell.isSpacer) ? cell.glyph : ""
    color: Ui.solid("foreground_0")
    font.pixelSize: Math.round(cell.height * 0.52)
    // Pinned to the color emoji font: the glyph is one emoji codepoint, so
    // a direct family hit avoids the fallback scan across every installed
    // font that shaping it under the UI font pays on first use.
    font.family: "Noto Color Emoji"
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    visible: !cell.isHeader && !cell.isLink && !cell.isSpacer
  }

  Text {
    anchors.fill: parent
    leftPadding: Ui.s
    rightPadding: Ui.s
    text: cell.isHeader ? String(cell.modelData ? cell.modelData.label ?? "" : "") : ""
    color: Ui.tint("foreground_1", 0.6)
    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
    font.bold: true
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignLeft
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    visible: cell.isHeader
  }

  Text {
    anchors.fill: parent
    leftPadding: 3
    rightPadding: 3
    text: (cell.isLink && cell.linkIconName === "") ? String(cell.modelData ? cell.modelData.label ?? "" : "") : ""
    color: Ui.tint("foreground_1", 0.75)
    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    visible: cell.isLink && cell.linkIconName === ""
  }

  Icon {
    anchors.centerIn: parent
    size: Math.round(cell.height * 0.42)
    name: cell.linkIconName
    colorKey: "foreground_0"
    visible: cell.isLink && cell.linkIconName !== ""
  }

  MouseArea {
    enabled: !cell.isHeader && !cell.isSpacer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: {
      const view = cell.view
      if (containsMouse && view && view.currentIndex !== cell.index) {
        if (view && typeof view.seat === "function") view.seat(cell.index, "click")
        else view.currentIndex = cell.index
      }
    }
    onClicked: cell.activated()
  }
}

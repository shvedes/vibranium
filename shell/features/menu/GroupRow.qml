pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib

// One child of a group row's inline dropdown. The row is Entry.qml itself:
// every view, state write and animation below is the page row's, drawn at the
// compact register. This wrapper only supplies the geometry the group needs
// to push the surrounding children around that row's nested slots.
Rectangle {
  id: child

  required property var modelData
  required property int index

  // Rows below a focused child slide down inside the clipped dropdown while
  // one of its slots is open. A transform, not y: the Column owns y. It reads
  // the bar's own frame, so it carries no second animation of its own.
  property real slideY: 0
  transform: Translate { y: child.slideY }

  readonly property string kind: child.modelData
    ? MenuLib.restKind(child.modelData, String(child.modelData.sub ?? "")) : ""
  readonly property real restH: RowGeometry.childRestH(child.kind)
  // The hosted row's slots are overlays: the selection bar grows to cover
  // them, and the group pushes the neighbours from the same numbers.
  readonly property var liveRow: rowLoader.item
  readonly property real barH: liveRow ? liveRow.nestedBarH : restH
  readonly property real settledBarH: liveRow ? liveRow.nestedSettledBarH : restH
  readonly property real settledExtra: Math.max(0, settledBarH - restH)

  // Seats the group cursor on this child. The hosted row owns the state write.
  signal picked()

  width: parent.width
  height: child.restH
  radius: RoundingPolicy.radius
  color: "transparent"

  // Loaded by URL, not by type name: Entry owns the group's child delegates,
  // so naming it here would close a compile-time cycle between the two files.
  Loader {
    id: rowLoader

    width: child.width
    Component.onCompleted: setSource(Qt.resolvedUrl("Entry.qml"), {
      modelData: child.modelData,
      index: child.index,
      itm: child.modelData,
      nested: true,
      width: child.width
    })
    Connections {
      target: rowLoader.item

      function onActivated() { child.picked() }
    }
  }
  Binding {
    target: rowLoader.item
    property: "width"
    value: child.width
    when: rowLoader.item !== null
  }
}

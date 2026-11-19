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
  property int nestedDepth: 0

  // Rows below a focused child slide down inside the clipped dropdown while
  // one of its slots is open. A transform, not y: the Column owns y. It reads
  // the bar's own frame, so it carries no second animation of its own.
  property real slideY: 0
  onSlideYChanged: if (Menu.traceEnabled) Menu.trace("child.slide", {
    id: String(child.modelData?.id ?? ""), index: child.index,
    y: Math.round(slideY * 10) / 10
  })
  transform: Translate { y: child.slideY }

  readonly property string kind: child.modelData
    ? MenuLib.restKind(child.modelData, String(child.modelData.sub ?? "")) : ""
  readonly property real restH: RowGeometry.childRestH(child.kind)
  // The hosted row's slots are overlays: the selection bar grows to cover
  // them, and the group pushes the neighbours from the same numbers.
  readonly property var liveRow: rowLoader.item
  readonly property real barH: liveRow ? liveRow.nestedBarH : restH
  readonly property real settledBarH: liveRow ? liveRow.nestedSettledBarH : restH

  // Seats the group cursor on this child. The hosted row owns the state write.
  signal picked()

  width: parent.width
  // A separator's own row is the bare hairline (or the labeled strip), far
  // shorter than a normal child. Sizing its wrapper at a normal row left the
  // line pinned to the wrapper's top with all the breathing below it.
  height: child.modelData && child.modelData.type === "separator"
    ? RowGeometry.childRestSeparator(String(child.modelData.label ?? "") !== "")
    : child.restH
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
      nestedDepth: child.nestedDepth + 1,
      width: child.width
    })
    Connections {
      target: rowLoader.item

      // Activation precedes the slot opening and the list's reveal seat, so
      // the panel reads the offset under the user's view.
      function onActivated() {
        Menu.trace("child.activate", { id: String(child.modelData?.id ?? "") })
        Menu.beginNestedReveal()
        child.picked()
      }
      function onExpandedChanged() {
        const row = child.liveRow
        if (!row) return
        Menu.trace("child.expanded", {
          id: String(child.modelData?.id ?? ""), open: row.expanded,
          ms: row.slotMotionMs,
          dH: Math.round(row.descSlotH * 10) / 10,
          eH: Math.round(row.expandSlotH * 10) / 10
        })
        if (row.expanded) {
          Menu.beginNestedReveal()
        } else {
          // The slot still publishes its close duration here: the panel rides
          // the seat back at that same pace.
          Menu.beginNestedRestore(row.slotMotionMs)
        }
      }
      // The panel wires this for page rows. A nested child needs the same
      // close latch released, or the panel keeps treating its collapsed slot
      // as mid-close and never returns the region it grew for it.
      function onSlotMotionEnded() {
        Menu.trace("child.slotEnd", {
          id: String(child.modelData?.id ?? ""), ms: child.liveRow ? child.liveRow.slotMotionMs : -1
        })
        Menu.nestedSlotFinished(child.modelData)
      }
    }
  }
  Binding {
    target: rowLoader.item
    property: "width"
    value: child.width
    when: rowLoader.item !== null
  }
}

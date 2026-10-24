pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.wallpaperPicker

// Wallpaper picker row - filename label with selection fill, plus the
// staged delete confirm slot (hint -> armed -> confirm) ported from
// ClipboardEntry. Delete state (open/stage) is owned by the panel;
// this is pure view.
Item {
  id: row

  // The record rides whole in the one role a ScriptModel exposes,
  // `modelData`: under it this IS the row record, not a context object
  // wrapping one.
  required property var modelData
  required property int index

  // Pending delete: row stays in the model until the rm lands but
  // must not react to clicks or activation.
  readonly property bool pending: row.modelData
    ? WallpaperPicker.optimistic.isPending(row.modelData.value) : false
  // Three-step delete confirm (hint -> armed -> confirm). Index +
  // stage are owned by the panel; this is pure view.
  property bool deleteOpen: false
  property int deleteStage: 0

  signal activated()
  signal deleteConfirm()

  // Slide-in used by the panel after a delete: rows below the removed
  // row start one row low and ease up into the vacated position. Runs
  // on a Translate so it never fights the ListView's own y layout.
  // Follows the global animation switch - off means rows land in place.
  transform: Translate { id: slideTf }
  function armSlide(offset) {
    if (!MotionPolicy.enabled) return
    slideTf.y = offset
    // Glide drops its target when the tween stops, and a target assigned over
    // a declared binding removes that binding, so the hand-back is what makes
    // this row's SECOND arm animate: a surviving row is armed once per delete
    // above it. Without it the tween runs against nothing and the row stays
    // parked at the offset.
    slideAnim.target = slideTf
    slideAnim.from = offset
    slideAnim.to = 0
    slideAnim.restart()
  }
  // The shared number tween, on the picker's own clock (Ui.normalMs) - a row
  // travelling the height of the confirm slot it is closing reads slower than
  // the highlight bar, which rides Ui.fastMs. The gate is the switch above:
  // off means no arm at all, so the duration needs no second check.
  Glide {
    id: slideAnim
    target: slideTf
    property: "y"
    duration: Ui.normalMs
  }

  width: ListView.view ? ListView.view.width : 320
  // The confirm slot grows the row in-flow; the height tracks the
  // slot's open/close animation 1:1 (same pattern as ClipboardEntry).
  readonly property real baseH: Math.max(Ui.rowMinH, 28)
  readonly property real deleteSlotH: deleteSlot ? deleteSlot.height : 0
  readonly property real slotMotionMs: deleteSlot && (deleteSlot.open || deleteSlot.closing)
    ? deleteSlot.slotMs : 0
  height: baseH + deleteSlotH

  Rectangle {
    anchors.fill: parent
    // Always transparent: the List sliding highlight bar paints the
    // selection behind the rows (see common/ui/List). Same as menu Entry.
    color: "transparent"
  }

  MouseArea {
    anchors.fill: parent
    enabled: !row.pending
    onClicked: {
      const v = row.ListView.view
      if (v && v.currentIndex !== row.index) v.seat(row.index, "click")
      row.activated()
    }
  }

  Item {
    id: mainLine

    // Inset like ClipboardEntry's mainLine: rowPadV above, content height
    // only. The confirm slot anchors to mainLine.bottom + Ui.m, so a
    // full-height mainLine would push the slot's built-in bottom gap past
    // the row edge and leave the Delete button flush with the row border.
    // With the inset, rowPadV + label height centers the label in baseH
    // while closed and leaves the slot's gap inside the row while open.
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: Ui.rowPadV
    height: label.height

    Text {
      id: label
      anchors.left: parent.left
      anchors.leftMargin: Ui.m
      anchors.right: parent.right
      anchors.rightMargin: Ui.m
      text: row.modelData ? String(row.modelData.label ?? "") : ""
      color: Ui.solid("foreground_0")
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
  }

  ConfirmSlot {
    id: deleteSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    topGap: Ui.m
    open: row.deleteOpen
    stage: row.deleteStage
    hintText: "Press Delete to remove this wallpaper"
    onConfirmed: row.deleteConfirm()
  }
}

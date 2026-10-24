pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.clipboard

// Clipboard row - mirrors LauncherEntry with descriptions enabled:
// icon 20px, title, subLeft - time, pin indicator. Looks like AppLauncher
// with sub-text or Settings sub line.
Item {
  id: row

  // The record rides whole in the one role a ScriptModel exposes,
  // `modelData`: under it this IS the row record, not a context object
  // wrapping one. There is no second role to unwrap.
  required property var modelData
  required property int index

  property bool pinned: modelData ? modelData.pinned === true : false
  // Pending delete: row stays in the model for the removal handoff but
  // must not react to clicks, activation, copy or pin.
  readonly property bool pending: modelData ? Clipboard.optimistic.isPending(modelData.id) : false
  // Three-step delete confirm (hint -> armed -> confirm), pinned rows
  // only. Index + stage are owned by the panel; this is pure view.
  property bool deleteOpen: false
  property int deleteStage: 0
  // The resting two-line height the panel sizes its window from. New
  // delegates report a zero content column until their text lays out, and a
  // floor of Ui.rowMinH would make a model swap under-report the list by one
  // text line per row - the transient the scroll hold then chases.
  property real restHeight: Ui.rowMinH
  // Missing-file flag: an open-on-Enter existence probe found the path
  // gone. The subtext carries the notice (see buildSubLeft) and paints
  // red while flagged.
  readonly property bool missing: modelData ? modelData.missing === true : false

  readonly property string titleText: modelData ? String(modelData.title || "") : ""
  readonly property bool pathLike: modelData ? modelData.pathLike === true : false
  readonly property string subLeftText: modelData ? String(modelData.subLeft || "") : ""
  readonly property string timeText: modelData ? String(modelData.timeStr || "") : ""
  readonly property string iconName: modelData ? String(modelData.icon || "text") : "text"

  signal activated()
  signal deleteConfirm()

  // Slide-in used by the panel after a delete: rows below the removed
  // row start one row low and ease up into the vacated position. Runs on
  // a Translate so it never fights the ListView's own y layout. Follows
  // the global animation switch - off means rows just land in place.
  // Shares the highlight clock (Ui.fastMs) so rows and bar move together.
  transform: Translate { id: slideTf }
  function armSlide(offset) {
    if (!MotionPolicy.enabled) return
    slideTf.y = offset
    slideAnim.from = offset
    slideAnim.to = 0
    slideAnim.restart()
  }
  NumberAnimation {
    id: slideAnim
    target: slideTf
    property: "y"
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
  }

  width: ListView.view ? ListView.view.width : 320
  // The confirm slot grows the row in-flow; the height tracks the slot's
  // open/close animation 1:1 (same pattern as LauncherEntry).
  readonly property real deleteSlotH: deleteSlot ? deleteSlot.height : 0
  readonly property real slotMotionMs: deleteSlot && (deleteSlot.open || deleteSlot.closing)
    ? deleteSlot.slotMs : 0
  height: Math.max(row.restHeight, mainCol.height + 2 * Ui.rowPadV) + deleteSlotH

  Rectangle {
    anchors.fill: parent
    // Always transparent: the List sliding highlight bar paints the
    // selection behind the rows (see common/ui/List). Same as menu Entry.
    color: "transparent"
  }

  // Pin indicator - small dot or lock for secret? Use accent
  Rectangle {
    visible: row.pinned
    anchors.left: parent.left
    anchors.leftMargin: 1
    anchors.verticalCenter: parent.verticalCenter
    width: 3
    height: 18
    radius: RoundingPolicy.radius
    color: Theme.color("accent")
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    enabled: !row.pending
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) {
        Clipboard.close()
        return
      }
      const v = row.ListView.view
      if (v && v.currentIndex !== row.index) v.seat(row.index, "click")
      row.activated()
    }
  }

  Item {
    id: mainLine

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: Ui.rowPadV
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    height: mainCol.height

    Icon {
      id: iconImg
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      size: 20
      name: row.iconName
      colorKey: "foreground_0"
      visible: true
    }

    Column {
      id: mainCol
      anchors.left: iconImg.visible ? iconImg.right : parent.left
      // -> 8 is Ui.s, so the icon/text gaps read tokens verbatim.
      anchors.leftMargin: iconImg.visible ? Ui.s : 0
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

      Text {
        width: parent.width
        text: row.titleText
        color: Ui.tint("foreground_0", 1)
        font.pixelSize: Ui.fontL
        font.family: Ui.fontFamily
        // Path rows elide from the left so the file name stays visible;
        // prose and titles elide on the right.
        elide: row.pathLike ? Text.ElideLeft : Text.ElideRight
        textFormat: Text.PlainText
        // Secret entries already generic, but ensure not selectable?
      }

      Item {
        width: parent.width
        height: Math.max(subLeft.height, timeText.height)

        Item {
          id: subLeft
          anchors.left: parent.left
          anchors.right: timeText.left
          // -> 8 is Ui.s, so the sub/time gap reads a token verbatim.
          anchors.rightMargin: Ui.s
          anchors.verticalCenter: parent.verticalCenter
          height: subSwap.implicitHeight
          clip: true

          // Subtext swap: the library SlideSwap, the same bottom-to-top
          // cross-slidefade the input ghost uses for placeholder flips
          // (which is what the normal/pinned switch rides). Every subtext
          // update - a landed file probe, a flagged-missing notice - rises
          // in instead of snapping. The host clips: the swap does not
          // elide, so an overlong string cuts at the box like the ghost.
          SlideSwap {
            id: subSwap
            anchors.fill: parent
            text: row.subLeftText
            // A flagged-missing row carries the notice in red like the
            // launcher's alert rows - the size/resolution metadata it
            // replaces is stale the moment the file is gone.
            color: row.missing ? Theme.color("red") : Ui.tint("foreground_1", 0.55)
            fontSize: Ui.fontXs
            fontFamily: Ui.fontFamily
          }
        }

        Text {
          id: timeText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row.timeText
          color: Ui.tint("foreground_1", 0.45)
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
          textFormat: Text.PlainText
        }
      }
    }
  }

  // Confirm dropdown under the row: hint text + Delete button. Stage 2
  // fills the button red; one more key/click confirms. Panel owns stage.
  // Pinned rows arm it via Delete, rows flagged missing via Enter - the
  // staging is the same either way, only the hint names the reason.
  ConfirmSlot {
    id: deleteSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    topGap: Ui.m
    open: row.deleteOpen && (row.pinned || row.missing)
    stage: row.deleteStage
    hintText: row.missing ? "Press Delete to remove this missing entry" : "Press Delete to remove this pinned entry"
    onConfirmed: row.deleteConfirm()
  }
}

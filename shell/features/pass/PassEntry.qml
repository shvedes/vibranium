pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.features.pass

// One password-manager row: folder, entry, action or shortcut. Same
// family look as LauncherEntry/ClipboardEntry - 20px icon, label plus
// dim sub line, transparent fill (the List highlight paints selection).
Item {
  id: row

  // The row record, whole. A ScriptModel exposes exactly one role and it is
  // this one, so every field below is read off the record itself - there is
  // no `key` role to declare (it has no source, and a `required` property
  // with no source is a hard "Cannot create delegate") and no wrapper to
  // unwrap. The panel's own identity for this row rides along as `uid` and
  // is only ever read for its LENGTH.
  required property var modelData
  required property int index
  readonly property string rowKey: row.modelData ? String(row.modelData.uid || "") : ""
  // A rebaked row supersedes whatever close it still owed: the new role
  // owns the slot from here, so the release a cancelled close was holding
  // goes with the rebake - the swap that installed these rows is the one
  // the panel owns, not a second one from the departed role.
  //
  // The model reports a payload change as dataChanged over the whole range on
  // every reassignment, so this fires for every live row on every install and
  // not only for the one that was rebaked. It costs nothing that it did not
  // already cost: rebuild() mints fresh row objects each pass, so every row's
  // payload reference is new on every install whatever the model reports.
  onModelDataChanged: {
    row.closingEdit = false
    row._closeDone = null
  }

  // Staged delete confirm (Delete action row only); panel owns the stage.
  property bool deleteOpen: false
  property int deleteStage: 0
  property bool deleteIsFolder: false
  // Triple-buffer middle frame (spec 49): the row survives commit
  // visibly but inert until the refresh removes it - clipboard parity.
  readonly property bool pending: modelData && (modelData.path || modelData.dirPath)
    ? Pass.optimistic.isPending(modelData.path || modelData.dirPath || "") : false

  opacity: row.pending ? 0.45 : 1

  readonly property string kind: modelData ? String(modelData.kind || "entry") : "entry"
  readonly property string label: modelData ? String(modelData.label || "") : ""
  readonly property string sub: modelData ? String(modelData.sub || "") : ""
  // Per-row icon tint; only the create rows set one (green file, yellow
  // folder) - everything else stays on the default foreground.
  readonly property string iconColor: (modelData && modelData.iconColor) ? String(modelData.iconColor) : "foreground_0"
  readonly property string iconName: {
    if (!modelData) return "text"
    if (modelData.icon !== undefined && String(modelData.icon) !== "") return String(modelData.icon)
    switch (row.kind) {
      case "dir": return "file-folder"
      case "up": return "arrow"
      case "back": return "arrow"
      default: return "lock"
    }
  }
  // Delimiter rows collapse to a slim centered hairline, launcher parity.
  readonly property bool isSep: row.kind === "delimiter"

  signal activated()
  signal deleteConfirm()

  // Inline name editor: DropdownSlot + InputField, the shared pattern
  // with no menu coupling. The panel bakes editor:true plus hints into
  // the row; focus and validation round-trip through the functions.
  property bool editorOpen: modelData ? modelData.editor === true : false
  property string editHint: modelData ? String(modelData.editHint || "") : ""
  property string editInitial: modelData ? String(modelData.editInitial || "") : ""
  signal editorAccepted(string text)
  signal editorCancelled()
  // Born-open delegates skip the open glide (the model swap
  // creates them with editorOpen already true): stay shut for
  // one frame so the shared 140ms Glide runs on every open.
  property bool _ready: false
    // One Component.onCompleted and only one: the second one is a QML
    // "Property value set multiple times" that takes the whole type - and
    // therefore every panel that instantiates it - out of construction.
    Component.onCompleted: {
      // A delegate with no payload is a row with nothing to draw, and it is
      // the one render failure visible from in here: every binding below
      // reads empty and the row is a blank strip in the list. It is left
      // to draw rather than refused, because an empty payload is not a
      // verdict - the construction harness supplies one on purpose.
      Qt.callLater(() => { if (row) row._ready = true })
    }
  function focusEditor() {
    const shell = editorLoader.item
    const f = shell ? shell.field : null
    if (!f) return
    f.text = row.editInitial
    f.grabFocus()
    f.input.selectAll()
  }
  function flashInvalid() {
    const shell = editorLoader.item
    const f = shell ? shell.field : null
    // A refused name is a normal outcome, so there is nothing to do
    // without an editor to flash.
    if (!f) return
    f.input.selectAll()
    f.grabFocus()
  }
  // Two-phase close entry (panel settleEditorClose): shut the live row so
  // the shared close Glide runs before the swap destroys it, and hold the
  // panel's release until the slot's close actually lands. The slot's own
  // terminal edge is the release point, so a close longer than any easing
  // length still keeps this row alive, and a reopen inside that window
  // cancels the release together with the close. The pending release rides
  // the row: a rebake (onModelDataChanged) or a destruction takes it down, so
  // a panel reference cannot outlive the delegate that owes it.
  property bool closingEdit: false
  property var _closeDone: null
  function beginClose(done) {
    row._closeDone = typeof done === "function" ? done : null
    // Nothing gliding: this slot never opened (the row is younger than its
    // first frame) or its close already landed, so the close is over and
    // the release is due at once.
    if (!editorSlot.open && !editorSlot.closing) {
      row._releaseClose()
      return
    }
    row.closingEdit = true
  }
  function _releaseClose() {
    const done = row._closeDone
    row._closeDone = null
    if (typeof done === "function") done()
  }

  width: ListView.view ? ListView.view.width : 320
  // Both slots grow the row in-flow; the height tracks the open one 1:1
  // (same pattern as LauncherEntry). Delete and editor never coincide.
  readonly property real deleteSlotH: deleteSlot ? deleteSlot.height : 0
  readonly property real editorSlotH: editorSlot ? editorSlot.height : 0
  readonly property real slotMotionMs: Math.max(
    deleteSlot && (deleteSlot.open || deleteSlot.closing) ? deleteSlot.slotMs : 0,
    editorSlot && (editorSlot.open || editorSlot.closing) ? editorSlot.slotMs : 0)
  height: row.isSep ? 12 : (Math.max(Ui.rowMinH, mainCol.height + 2 * Ui.rowPadV) + deleteSlotH + editorSlotH)

  Rectangle {
    anchors.fill: parent
    color: "transparent"
  }

  // Delimiter rows: centered hairline with the menu's side insets.
  Divider {
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Ui.m + 2
    anchors.rightMargin: Ui.m + 2
    visible: row.isSep
  }

  MouseArea {
    anchors.fill: parent
    enabled: !row.pending && !row.isSep
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) {
        Pass.close()
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
    visible: !row.isSep

    Icon {
      id: iconImg
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      size: 20
      name: row.iconName
      colorKey: row.iconColor
    }

    Column {
      id: mainCol
      anchors.left: iconImg.right
      anchors.leftMargin: 8
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1

      Text {
        width: parent.width
        text: row.label
        color: Ui.tint("foreground_0", 1)
        font.pixelSize: Ui.fontL
        font.family: Ui.fontFamily
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: row.sub !== ""
        text: row.sub
        color: Ui.tint("foreground_1", 0.55)
        font.pixelSize: Ui.fontXs
        font.family: Ui.fontFamily
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
    }
  }

  // Staged delete confirm under the Delete action row: hint -> armed ->
  // confirm with stages 2, same ConfirmSlot as clipboard pinned-delete.
  ConfirmSlot {
    id: deleteSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: mainLine.bottom
    topGap: Ui.m
    open: row.deleteOpen && !row.isSep
    stage: row.deleteStage
    confirmText: "Delete"
    hintText: row.deleteIsFolder ? "Press Delete to remove this folder" : "Press Delete to remove this entry"
    armedText: "<b><u>Press again to confirm</u></b>"
    onConfirmed: row.deleteConfirm()
  }

  DropdownSlot {
    id: editorSlot

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: deleteSlot.bottom
    // Stacked below the delete confirm: no top gap while it is live, full
    // padding when it is shut (the editor opens alone).
    topGap: (deleteSlot.open || deleteSlot.closing) ? 0 : Ui.m
    open: row.editorOpen && row._ready && !row.closingEdit && !row.isSep
    gap: Ui.m
    // The close reached its end: the release the panel's swap waits for.
    onCloseFinished: row._releaseClose()

    Loader {
      id: editorLoader

      active: (row.editorOpen && row._ready && !row.closingEdit) || editorSlot.closing
      width: parent.width
      // Continuous binding: adopt-once would freeze the height before
      // content finished laying out.
      height: item ? item.implicitHeight : 0
      sourceComponent: editorComp
      onLoaded: {
        // The ready gate means the panel's backup focus can land
        // before the item exists (it no-ops on the null guard):
        // claim focus on arrival too, deferred past creation like
        // the menu. Either order ends focused + selected.
        Qt.callLater(() => { if (row.editorOpen) row.focusEditor() })
      }
    }
  }

  Component {
    id: editorComp

    // Item shell with explicit implicitHeight like the menu's
    // confirm/body/option roots: the Loader reads item height off
    // this, the inset Column hangs one level down as proven.
    Item {
      property alias field: editorField

      width: parent.width
      implicitHeight: col.height

      Column {
        id: col

        x: Ui.m
        width: parent.width - 2 * Ui.m
        spacing: Ui.s

        InputField {
          id: editorField

          width: parent.width
          height: Ui.inputHeight
          placeholder: row.editHint
          clearable: false
          onAccepted: text => row.editorAccepted(text)
          onEscaped: row.editorCancelled()
        }
      }
    }
  }
}

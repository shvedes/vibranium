pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.wallpaper
import qs.features.wallpaperPicker

// Wallpaper picker card - two-pane layout: list left, preview right.
// Declarative via PanelCard + PanelFocus; fixed 6-row window.
PanelCard {
  id: panel

  maxHeight: 520
  hardMaxHeight: 800
  outerPad: Ui.outerPad
  filterH: Ui.filterH
  listTopGap: Ui.listTopGap
  emptyMinH: Ui.emptyMinH
  // The window's box, owned by the shared two-pane metrics: one height, one
  // width decision, and nothing in either reading the selection, the row count
  // or the entry type. See TwoPaneMetrics.
  TwoPaneMetrics { id: metrics }
  baseWidth: metrics.totalW + 2 * panel.outerPad
  count: list.count
  contentHeight: list.contentHeight
  rows: WallpaperPicker.filtered
  // The gap between rows is the LIST's, read rather than assumed: the card
  // sums the same gap the list places, so the region's bottom edge stays on
  // a row boundary whatever a surface decides to space its rows by.
  rowSpacing: list.spacing
  // No in-flow slots on this surface, so nothing ever asks the card to
  // grow: no slot is open, so the resting region stands and no override is
  // offered. (Forwarding the list's raw claim would be wrong here: this
  // surface never had one - see PanelCard.slotRegionH.)
  slotOpen: false
  slotRegionH: -1

  width: Math.min(metrics.totalW + 2 * panel.outerPad, parent ? parent.width - 64 : metrics.totalW)
  height: Math.min(panel.regionChromeH + metrics.contentH, panel.hardMaxHeight)

  readonly property bool searching: WallpaperPicker.query !== ""
  // Dead filter: no user wallpapers, no query to take.
  readonly property bool filterDead: WallpaperPicker._userFiles.length === 0

  // This panel's own row: a wallpaper entry is a single line with no sub, so
  // its height is the floor, and WallpaperEntry.baseH is the same expression.
  // A constant, not a measurement - a reading of whichever delegates happen to
  // be instantiated is a function of scroll position, slot state and model
  // churn.
  readonly property real rowH: Math.max(Ui.rowMinH, 28)

  // The window's box, owned by the shared two-pane metrics so this card and
  // the clipboard are the same size by construction rather than by two
  // matching sets of arithmetic. This panel's rows are one line shorter than
  // the window's budget, so more of them fit inside it: the window is the
  // budget, the row count is whatever fits.
  //
  // No rowLimit here. This panel never declared one, and PanelCard's cap feeds
  // the estimated region arithmetic, which a row carrying an open confirm slot
  // perturbs - a cap declared for a panel whose own height does not read it is
  // a second, stale answer to a question this card already answers.

  readonly property bool primarySurface: visible
  property bool _rowsPending: false

  Component.onCompleted: { WallpaperPicker._attachPanel(panel); panel.syncRows() }
  Component.onDestruction: WallpaperPicker._detachPanel(panel)
  TapHandler { onTapped: focusCtrl.grabFilter() }

  Connections {
    target: WallpaperPicker
    function onFilteredChanged() { panel.syncRows() }
    function onVisibleChanged() {
      if (!WallpaperPicker.visible) return
      panel.show()
      searchField.text = ""
      list.settle(0, true)
      focusCtrl.grabList()
    }
  }

  function syncRows() {
    if (panel._rowsPending) return
    panel._rowsPending = true
    Qt.callLater(() => {
      panel._rowsPending = false
      // Row identity shifts on any model change - an open confirm
      // dropdown must not survive it.
      panel.closeDelete()
      panel._swapGen++
      const g = panel._swapGen
      list.swapRun(g, v => v === panel._swapGen, () => {
        panel.installRows()
        list.settle(0, true)
      })
      Qt.callLater(focusCtrl.reassert)
    })
  }

  // The record array the model shows. installRows is its only writer, and the
  // ScriptModel below reads it through `values`, which is the model's only
  // write - one path, nothing behind it.
  property var _records: []
  // Wallpaper rows. The key is the file name, which is unique in a theme's
  // user set and stable across a filter, so every change (typing, a drop, a
  // theme re-apply) is a diff inside the model instead of a model-reference
  // swap, and the List keeps its measured-height table.
  ScriptModel {
    id: listModel
    values: panel._records
    // `value` is the file name: the same string the row set is deduplicated
    // on, the one this panel treats as a row's identity, and the field the
    // height table already keyed on. The records reach the delegate whole, as
    // modelData - there is no wrapper role to unwrap.
    objectProp: "value"
    // Payloads compare by identity, as they did under the keyed model: a
    // filter hands back fresh record objects for rows whose content did not
    // change, and the default (Structure) would read that as a payload edit
    // on every keystroke.
    comparisonMode: ObjectComparison.Identity
  }
  // Identity epoch for the height table. The ScriptModel reports neither a
  // revision nor a key-set flag, so the panel owns the counter: installRows
  // folds the key sequence into _lastSeq and every sequence that differs from
  // the last one advances the epoch. A counter and not the sequence itself,
  // because a sequence returns to an earlier value when rows are reordered
  // back and the epoch must never repeat one (see List.qml's fingerprint).
  // Advanced from the single write site rather than from a binding: a binding
  // that writes the value it reads is a loop.
  property int _epoch: 0
  property var _lastSeq: ""
  readonly property int identityRevision: panel._epoch
  // The key sequence the model showed before the current sync, kept for
  // the delete reflow alone: a ScriptModel reports no operations, so the rows
  // a removal pushed up are found by diffing the two sequences (see
  // armSlideFrom).
  property var _prevKeys: []
  property string _modelError: ""

  // The row set this panel's own guard accepts. A ScriptModel refuses nothing,
  // so the checks stay here rather than moving: two file names equal would
  // otherwise put two live rows on one identity, and all List can do with that
  // is refuse to measure either of them.
  function keyedRows() {
    const src = panel.rows
    if (!Array.isArray(src)) { panel._modelError = "not_array"; return null }
    const rows = new Array(src.length)
    const seen = Object.create(null)
    for (let i = 0; i < src.length; i++) {
      const rec = src[i]
      if (!rec || typeof rec.value !== "string") {
        panel._modelError = "invalid_row"
        return null
      }
      if (rec.value.trim() === "") {
        panel._modelError = "missing_key"
        return null
      }
      if (seen[rec.value] !== undefined) {
        panel._modelError = "duplicate_key"
        return null
      }
      seen[rec.value] = true
      rows[i] = rec
    }
    return rows
  }

  function installRows() {
    const rows = panel.keyedRows()
    // A refused set writes nothing at all: the previous rows stay on screen
    // until a set that passes arrives.
    if (rows === null) return
    panel._modelError = ""
    const prev = panel._prevKeys
    panel._records = rows
    const keys = rows.map(r => String(r.value))
    const seq = keys.join("\u0000")
    if (seq !== panel._lastSeq) {
      panel._lastSeq = seq
      panel._epoch++
    }
    panel._prevKeys = keys
    panel.armSlideFrom(prev, keys)
  }

  // The vault emptied under an open panel: drop a stale query when
  // one is pending and park the focus back in the list (see the
  // clipboard panel's reset).
  onFilterDeadChanged: {
    if (!panel.filterDead) return
    searchField.text = ""
    if (WallpaperPicker.query !== "") WallpaperPicker.clearQuery()
    focusCtrl.grabList()
  }

  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: WallpaperPicker.visible
  }
  readonly property alias input: searchField.input
  property alias mode: focusCtrl.mode
  function grabList() { focusCtrl.grabList() }
  function grabFilter() { focusCtrl.grabFilter() }
  function reassertFocus() { focusCtrl.reassert() }

  function currentFile() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) return ""
    return panel.rows[idx].value || ""
  }
  function activateCurrent() {
    // Open confirm takes precedence over activation, like the
    // clipboard. Only the armed row itself confirms; landing on
    // another row (click) just closes the dropdown.
    if (panel._deleteIndex >= 0) {
      if (list.currentIndex === panel._deleteIndex) { panel.acceptDelete(); return }
      panel.closeDelete()
    }
    const f = panel.currentFile()
    // Pending-delete rows stay visible but inert: no wallpaper switch.
    if (!f || WallpaperPicker.optimistic.isPending(f)) return
    WallpaperPicker.setWallpaper(f)
  }

  function moveSelection(dir) {
    if (!list.move(dir)) return
    // Leaving the armed row closes its confirm dropdown.
    if (panel._deleteIndex >= 0 && panel._deleteIndex !== list.currentIndex) panel.closeDelete()
  }

  // Deletion is buffered in the service; remember where the request
  // came from so selection can be repaired once the commit lands.
  property int pendingDeleteIndex: -1
  property int _swapGen: 0
  // Three-step confirm state: hint -> armed -> confirm.
  property int _deleteIndex: -1
  property int _deleteStage: 0
  function closeDelete() {
    _deleteIndex = -1
    _deleteStage = 0
    list.autoRevealIndex = -1
  }
  // Post-delete reflow: rows below the removed one slide up into the
  // vacated position. A keyed removal reuses every surviving delegate,
  // so no delegate is born to arm itself - the panel arms the shifted
  // rows itself from the rows that left (see armSlideFrom), and the
  // armed state must be ready before the commit lands.
  property real _slideOffset: 0
  property int _slideGen: -1
  function _armSlide(from) {
    // The row's height AS IT STANDS, and that is the whole reason this reads a
    // delegate instead of the constant: the caller arms the reflow BEFORE it
    // closes the confirm slot, so a live row is still carrying the expanded
    // height and the rows below have to move by that much or the space the
    // removed row leaves is never taken up. The resting row height is the
    // fallback for a row that is not instantiated, where there is no open
    // slot to account for either.
    const it = list.itemAtIndex(from)
    _slideOffset = (it ? it.height : panel.rowH) + list.spacing
    _slideGen = panel._swapGen + 1
  }
  // The affected set comes from the rows that left between the previous sync
  // and this one: the model's own operation report is gone, and the two key
  // sequences answer the same question. The lowest index the previous set
  // held and the new one does not is the first row the removal pushed up,
  // and every row from there to the end moved: the bound is min(from, n - 1).
  // That is the delegate-side rule (index >= from) collapsed into one
  // index, and each live row below it is armed exactly once. A set that only
  // reorders or grows drops nothing, so nothing is armed for it.
  function armSlideFrom(prevKeys, nextKeys) {
    if (panel.pendingDeleteIndex < 0) return
    if (panel._slideGen !== panel._swapGen) return
    const live = Object.create(null)
    for (let i = 0; i < nextKeys.length; i++) live[nextKeys[i]] = true
    let from = -1
    for (let i = 0; i < prevKeys.length; i++) {
      if (live[prevKeys[i]] !== true) { from = i; break }
    }
    if (from < 0) return
    const n = nextKeys.length
    for (let i = Math.min(from, n - 1); i < n; i++) {
      const it = list.itemAtIndex(i)
      if (it && typeof it.armSlide === "function") it.armSlide(panel._slideOffset)
    }
  }

  // Delete/Ctrl+D entry point: every row gets the staged confirm - a
  // wallpaper file removal is irreversible, unlike clipboard history.
  function toggleDeleteCurrent() {
    const idx = list.currentIndex
    if (idx < 0 || idx >= panel.rows.length) { panel.closeDelete(); return }
    const row = panel.rows[idx]
    if (!row) return
    if (panel._deleteIndex === idx) {
      if (panel._deleteStage >= 2) { panel.acceptDelete(); return }
      panel._deleteStage++
      list.autoRevealIndex = idx
      return
    }
    panel._deleteIndex = idx
    panel._deleteStage = 1
    list.autoRevealIndex = idx
  }
  function acceptDelete() {
    const idx = panel._deleteIndex
    const row = idx >= 0 && idx < panel.rows.length ? panel.rows[idx] : null
    if (row) panel._armSlide(idx)
    panel.closeDelete()
    if (!row || WallpaperPicker.optimistic.isPending(row.value)) return
    pendingDeleteIndex = idx
    WallpaperPicker.requestDelete(row.value)
  }
  // Runs after the service committed the removal. Queued repair also
  // wins over syncRows' reset-to-top queued for the same filtered
  // change.
  function onDeleteCommitted(fileName) {
    const from = panel.pendingDeleteIndex
    panel.pendingDeleteIndex = -1
    if (from < 0) return
    Qt.callLater(() => {
      const n = panel.rows.length
      list.seat(n === 0 ? -1 : Math.min(from, n - 1), "land")
    })
  }

  function escapeChain() {
    // The open confirm is modal: Escape cancels it before anything else.
    if (panel._deleteIndex >= 0) { panel.closeDelete(); return }
    if (WallpaperPicker.query !== "") {
      WallpaperPicker.clearQuery()
      searchField.text = ""
      return
    }
    if (focusCtrl.mode === "filter" || searchField.focused) {
      focusCtrl.grabList()
      return
    }
    WallpaperPicker.close()
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const meta = event.modifiers & Qt.MetaModifier
    if ((k === Qt.Key_D && ctrl) || k === Qt.Key_Delete) {
      panel.toggleDeleteCurrent()
      event.accepted = true
      return
    }
    if (k === Qt.Key_F && ctrl) { focusCtrl.grabFilter(); event.accepted = true; return }
    switch (k) {
      case Qt.Key_Down:
      case Qt.Key_Tab:
        panel.moveSelection(1); event.accepted = true; return
      case Qt.Key_Up:
      case Qt.Key_Backtab:
        panel.moveSelection(-1); event.accepted = true; return
      case Qt.Key_PageUp: panel.scrollBy(-0.8); event.accepted = true; return
      case Qt.Key_PageDown: panel.scrollBy(0.8); event.accepted = true; return
      case Qt.Key_Home: list.seat(0, "step"); event.accepted = true; return
      case Qt.Key_End: list.seat(panel.rows.length - 1, "step"); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter: panel.activateCurrent(); event.accepted = true; return
      case Qt.Key_Escape: panel.escapeChain(); event.accepted = true; return
      case Qt.Key_Backspace:
      case Qt.Key_Delete:
        if (focusCtrl.mode === "list") { focusCtrl.grabFilter(); event.accepted = true; return }
        break
      case Qt.Key_Space:
        if (focusCtrl.mode === "list" && !searchField.focused) { panel.activateCurrent(); event.accepted = true; return }
        break
    }
    if (!ctrl && !meta && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
      if (focusCtrl.mode === "list") {
        // A dead filter takes no query.
        if (panel.filterDead) { event.accepted = true; return }
        WallpaperPicker.submit(event.text)
        searchField.text = event.text
        focusCtrl.grabFilter()
        event.accepted = true
      }
    }
  }
  Keys.onPressed: event => panel.handleKey(event)
  function scrollBy(factor) { list.pageBy(factor) }

  // Skeleton row: a static mock of one resting wallpaper entry - a
  // single filename bar in the label's own line box (hidden probe,
  // RowHeightProbe pattern). Static, island chrome. Local: wallpaper
  // rows are single-line labels, a different shape from the
  // clipboard's two-line entries, so no shared component exists.
  component SkeletonFileRow: Item {
    id: fileSkel

    // Repeater-fed (see the clipboard filler): the bare `index` read
    // at the instantiation site resolves to nothing at runtime, so the
    // stagger reads the declared property instead.
    required property int index
    property real labelFrac: [0.7, 0.52, 0.61][index % 3]

    opacity: 0.55

    Text {
      id: labelProbe

      visible: false
      width: 1
      wrapMode: Text.NoWrap
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily
      text: "Mg"
      textFormat: Text.PlainText
    }

    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Ui.m
      anchors.rightMargin: Ui.m
      anchors.topMargin: Ui.rowPadV
      height: labelProbe.implicitHeight

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width * fileSkel.labelFrac
        height: 8
        radius: RoundingPolicy.radius
        color: Ui.tint("foreground_1", 0.14)
      }
    }
  }

  Item {
    id: filterBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    anchors.topMargin: panel.outerPad
    height: panel.filterH
    InputField {
      id: searchField
      anchors.fill: parent
      implicitHeight: panel.filterH
      basePadding: Ui.l
      focusColor: Ui.solid("accent")
       placeholder: "Filter wallpapers..."
       inputRole: "filter"
       filterIconAlways: true
      // Dead while the vault is empty: no query to take, no focus to hold.
      enabled: !panel.filterDead
      clearable: false
       counterVisible: true
      counterMatched: WallpaperPicker.filtered.length
      counterTotal: WallpaperPicker._userFiles.length
      onEdited: text => WallpaperPicker.submit(text)
      onAccepted: panel.activateCurrent()
      onEscaped: panel.escapeChain()
    }
  }

  Item {
    id: contentRow
    anchors.top: filterBar.bottom
    anchors.topMargin: panel.listTopGap
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.outerPad
    anchors.rightMargin: panel.outerPad
    anchors.bottom: parent.bottom
    anchors.bottomMargin: panel.outerPad
    height: metrics.contentH

    // Single vertical hairline between list and preview (Divider tone),
    // centered in the shared gap - same as the clipboard panel.
    Rectangle {
      width: 1
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      x: metrics.leftW + (metrics.gap - 1) / 2
      color: Ui.tint("background_3", 1)
    }

    Row {
      anchors.fill: parent
      spacing: metrics.gap
      Item {
        id: listBox
        width: metrics.leftW
        height: parent.height
        clip: true
        List {
          id: list
          anchors.fill: parent
          anchors.rightMargin: 16
          // Bound once: the display model is the single data path, so a
          // filtered sync diffs through its `values` instead of replacing the
          // model reference and clearing the whole measured-height table.
          model: listModel
          interactive: false
          // Cursor-row gate (menu parity): the bar glides for focus
          // moves, filtered or not, but snaps while the focused row
          // stages its confirm (tracks the slot 1:1); a slot left
          // behind must not freeze the bar mid-move.
          highlightMotion: MotionPolicy.enabled && panel._deleteIndex !== list.currentIndex
          // Never learn while a staged delete confirm is open (see
          // ClipboardPanel): the ConfirmSlot sits in-flow under the row,
          // so the inflated height would poison the table's average and
          // the fit and wrap seats would resolve against a height no row
          // carries again.
          measureGuard: idx => panel._deleteIndex < 0
          // Height table keyed by row identity: the file name, the same
          // string the model's objectProp names, so a table entry always
          // describes the row holding it. `?? index` keeps a row renderable
          // when the record carries no key at all.
          rowIdentity: index => String(listModel.values[index]?.value ?? index)
          // Identity epoch for the height table. The model reports nothing
          // per sync, so the panel's counter does: it advances only when the
          // key SEQUENCE changes, so a payload-only change keeps the
          // measured heights while a key-set change advances the epoch and
          // prunes the rows the new key set drops.
          identityRevision: panel.identityRevision
          trailSpace: 0
          clip: true
          autoRevealEnabled: true
           delegate: WallpaperEntry {
             deleteOpen: panel._deleteIndex === index
            deleteStage: panel._deleteIndex === index ? panel._deleteStage : 0
            onActivated: () => panel.activateCurrent()
            onDeleteConfirm: () => panel.toggleDeleteCurrent()
          }
        }
        ScrollBar {
          flickable: list
          anchors.top: parent.top
          anchors.topMargin: 4
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.bottom: parent.bottom
          anchors.bottomMargin: 4
          thickness: 4
          autoHide: false
        }
        // Filler skeleton rows under short lists: live rows stay live,
        // the rest of the viewport holds its footprint. The window is
        // counted in one-line rows (metrics.rows budgets two-line
        // ones), so a filter narrows the live set and the skeletons
        // take the rest. Same pattern as the clipboard filler.
        Column {
          anchors.left: parent.left
          anchors.right: parent.right
          // Mirrors the list's own gutter above, so filler rows start
          // on the same x as live ones.
          anchors.rightMargin: 16
          anchors.top: parent.top
          anchors.topMargin: Math.min(list.contentHeight + (list.count > 0 ? list.spacing : 0), parent.height)
          spacing: list.spacing
          opacity: 0.8
          visible: list.count < Math.floor((metrics.contentH + list.spacing) / (panel.rowH + list.spacing))
          clip: true

          Repeater {
            model: Math.max(0, Math.floor((metrics.contentH + list.spacing) / (panel.rowH + list.spacing)) - list.count)

            delegate: SkeletonFileRow {
              width: parent.width
              height: panel.rowH
            }
          }
        }
        // Fully empty: dim veil over the full-window skeletons, the
        // EmptyState icon + copy above it (clipboard parity).
        Rectangle {
          anchors.fill: parent
          visible: list.count === 0
          color: Ui.tint("background_0", 0.45)
        }
        // Empty list: image glyph with no accent over the copy
        // (library-wide EmptyState, same style as the menus). No
        // wallpapers at all keeps "No wallpapers"; a filter with no hits
        // keeps the menus' filter-x + "No matches" pair.
        EmptyState {
          anchors.centerIn: parent
          width: Math.max(0, parent.width - 32)
          visible: list.count === 0
          text: WallpaperPicker._userFiles.length === 0 ? "No wallpapers" : "No matches"
          iconName: WallpaperPicker._userFiles.length === 0 ? "image" : "filter-x"
          iconColorKey: "foreground_1"
          iconAccentKey: WallpaperPicker._userFiles.length === 0 ? "" : "red"
        }
      }
      Rectangle {
        id: previewBox
        width: metrics.previewW
        height: parent.height
        // Flat like the clipboard preview: no outline box, no brighter
        // fill - the image floats on the card background directly.
        color: "transparent"
        clip: true
        readonly property string curFile: {
          const idx = list.currentIndex
          if (idx < 0 || idx >= panel.rows.length) return ""
          return panel.rows[idx].value
        }
        readonly property bool isEmpty: curFile === ""
        readonly property string curPath: curFile !== "" ? WallpaperPicker.backgroundsDir + "/" + curFile : ""
        Image {
          id: previewImg
          anchors.fill: parent
          anchors.margins: 6
          source: previewBox.curPath !== "" ? Paths.toFileUrl(previewBox.curPath) : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          smooth: true
          opacity: status === Image.Ready ? 1 : 0

          Behavior on opacity {
            enabled: MotionPolicy.enabled
            NumberAnimation { duration: Ui.slowMs; easing.type: Easing.OutCubic }
          }
          // The card is an Item, not a window, so its window's own ratio comes
          // from the attached property, which resolves as soon as the card is
          // in the scene and is notifying. sourceSize is in DEVICE pixels, so
          // the box it paints into is measured in logical ones and multiplied.
          // Unbounded, this preview rasterizes the user's own 5K wallpaper at
          // full size - mip chain and all - to fill a box a few hundred
          // pixels across.
          readonly property real _dpr: Window.window
            ? Window.window.devicePixelRatio : 1
          sourceSize.width: previewBox.width > 0
            ? Math.round(previewBox.width * _dpr) : 0
          sourceSize.height: previewBox.height > 0
            ? Math.round(previewBox.height * _dpr) : 0
        }

        Text {
          anchors.centerIn: parent
          visible: previewImg.status === Image.Error && previewBox.curFile !== ""
          text: "No preview"
          color: Ui.tint("foreground_1", 0.5)
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
          textFormat: Text.PlainText
        }
        // Empty state mirrors ClipboardPreview's placeholder (icon + text,
        // no filled background): centered column, Ui.s spacing, 54px file
        // glyph at 0.35 opacity, fontM italic title at 0.6 tint.
        Column {
          anchors.centerIn: parent
          visible: previewBox.isEmpty
          spacing: Ui.s
          Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "file"
            colorKey: "foreground_1"
            size: 54
            opacity: 0.35
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 220
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "No preview"
            color: Ui.tint("foreground_1", 0.6)
            font.pixelSize: Ui.fontM
            font.family: Ui.fontFamily
            font.italic: true
            textFormat: Text.PlainText
          }
        }
        MouseArea {
          anchors.fill: parent
          onClicked: WallpaperPicker.openFolder()
          cursorShape: Qt.PointingHandCursor
        }
        DropArea {
          id: previewDrop
          anchors.fill: parent
          enabled: Wallpaper.enabled
          // True only while a payload that passed the hover filter is over
          // the area. DropArea.containsDrag is true for every hovering
          // drag whether or not onEntered accepted it, so the overlay must
          // bind to this verdict instead of containsDrag.
          property bool dragOk: false
          onEntered: drag => {
            if (!Wallpaper.enabled) return
            dragOk = Wallpaper._dropIsSupported(drag)
            // Hover-time filter: only payloads handleDroppedUri can turn
            // into a wallpaper accept the drag; anything else never
            // triggers the preview overlay.
            if (dragOk) drag.acceptProposedAction()
          }
          onExited: dragOk = false
          onDropped: drop => {
            dragOk = false
            if (!Wallpaper._dropIsSupported(drop)) return
            // The same reduction the hover filter used, so the drag that lit
            // this preview is the drag handled here.
            const uri = Wallpaper._droppedUri(drop)
            if (uri === "") return
            Wallpaper.handleDroppedUri(uri)
          }
        }
        Rectangle {
          anchors.fill: parent
          visible: previewDrop.dragOk
          color: Ui.tint("accent", 0.12)
          border.color: Ui.solid("accent")
          border.width: 2
        }
      }
    }
  }
}

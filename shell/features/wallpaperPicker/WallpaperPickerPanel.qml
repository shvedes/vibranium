pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Effects
import Quickshell
import qs.common
import qs.features.wallpaper
import qs.features.wallpaperPicker
import "../../common/text/StringUtils.js" as SU
import "../../common/ui/PanelKeys.js" as PanelKeys

// Wallpaper picker overlay: a horizontal cascade of wallpaper previews.
//
// WHY A CASCADE. A wallpaper is chosen by looking at it, so the picture is the
// interface. The deck holds the selected wallpaper as a full 16:9 card in the
// middle and its neighbours as narrow slices tucked under its edges, one step
// further out - the shape Omarchy's image selector uses for theme previews.
// Moving the selection glides the whole row: the outgoing card shrinks into a
// slice while the incoming one grows out of its slice, so the deck reads as one
// horizontal surface rather than a list that scrolls. A step off either end of
// the listing wraps to the other end, so the deck behaves as a ring of pictures
// even though the row it draws is a line.
//
// APPLYING IS PART OF SELECTING. Enter, Space or a click sets the wallpaper
// and ends the visit in the same act; the picker never defers the apply to the
// close, and there is no separate confirm step.
//
// ONE SURFACE, TWO VERBS. Delete / Ctrl+D removes the selected wallpaper from
// here as well, so the picker and the deleter are the same visit: the key arms
// the footer prompt, Enter confirms, Esc backs out. The removal itself stays
// with the service (bounded rm, optimistic row, list refresh).
//
// NO SEARCH. The deck is browsed, not queried: the overlay carries no text
// field and no query state, because the listing is a visual set and a typed
// filter over it was a second, unrelated way to move a cursor.
//
// The service owns the listing, the removal and the path gate; this file owns
// the deck's geometry, its window and its keys.
Item {
  id: panel

  // Ceilings from the view's ScreenCeiling. The deck is a share of the screen,
  // not of the window it lives in: the window is sized from this panel.
  property real maxHeight: 600
  property real hardMaxHeight: 1200

  readonly property var rows: WallpaperPicker.filtered

  // Selected row. The deck's whole geometry is a function of this index.
  property int selIndex: 0
  // How many rows on each side of the selection the deck instantiates. The
  // visible count follows the screen; the window is a little wider so a slide
  // that is still animating in from the edge has a tile to come from.
  readonly property int windowRadius: 6
  // Open fade. The content is one opacity fade - no per-element and no
  // per-tile entrance - and `_settled` keeps the deck's geometry tweens off
  // until the surface has taken the screen's size, so the first frame cannot
  // animate a cascade out of zero-sized cards.
  property bool _fade: false
  property bool _settled: false
  // The file the user is on across a row-set change (a filter keystroke, a
  // removal, a theme swap), so the deck does not jump to the top.
  property string _keepFile: ""
  // Delete confirm (one step, unlike the old three-stage slot: the overlay has
  // nowhere to expand a row, so the footer carries the decision).
  property bool _confirmOpen: false
  property string _confirmFile: ""
  // Selection repair after a removal, as the service's commit calls back.
  property int pendingDeleteIndex: -1
  // The file a removal just took out of the deck, and how far through its exit
  // it is. The tile is carried as a window row of its own for the length of the
  // tween (see _syncWindow), so the picture lifts and fades while the survivor
  // rolls into its slot instead of the slot being re-drawn in one frame.
  property string _leavingFile: ""
  property real _leaveProgress: 0

  Component.onCompleted: { WallpaperPicker._attachPanel(panel); panel.syncRows() }
  Component.onDestruction: WallpaperPicker._detachPanel(panel)

  // ---- deck geometry -------------------------------------------------------
  // One decision per axis. The big card is the deck's height, narrowed by the
  // screen when a wide wallpaper would not leave room for a neighbour; the
  // slices are fractions of it, and every outer tile travels exactly one slice
  // step, so consecutive tiles overlap by the same amount.
  readonly property real deckH: Math.round(Math.max(160, Math.min(panel.height * 0.56, panel.maxHeight)))
  readonly property real bigH: Math.round(Math.min(panel.deckH, panel.width * 0.60 * 9 / 16))
  readonly property real bigW: Math.round(panel.bigH * 16 / 9)
  readonly property real sliceW: Math.round(panel.bigW * 0.13)
  readonly property real sliceH: Math.round(panel.bigH * 0.82)
  readonly property real sliceOverlap: Math.round(panel.sliceW * 0.30)
  readonly property real sliceStep: panel.sliceW - panel.sliceOverlap
  readonly property real deckCenterX: Math.round(panel.width / 2)

  // Device-pixel decode box, shared by every tile: one size for the whole
  // visit, so moving the selection never re-decodes a picture that was
  // already loaded.
  readonly property real _dpr: Window.window ? Window.window.devicePixelRatio : 1
  readonly property int decodeW: Math.round(panel.bigW * panel._dpr * 0.6)
  readonly property int decodeH: Math.round(panel.bigH * panel._dpr * 0.6)

  function tileW(rel) {
    return rel === 0 ? panel.bigW : panel.sliceW
  }
  function tileH(rel) {
    return rel === 0 ? panel.bigH : panel.sliceH
  }
  function tileX(rel) {
    if (rel === 0) return panel.deckCenterX - panel.bigW / 2
    if (rel < 0) {
      return panel.deckCenterX - panel.bigW / 2 - panel.sliceW + panel.sliceOverlap
        + (rel + 1) * panel.sliceStep
    }
    return panel.deckCenterX + panel.bigW / 2 - panel.sliceOverlap + (rel - 1) * panel.sliceStep
  }
  // A gentle downward cascade outward, kept inside the slice's own inset so a
  // tile never leaves the deck's band.
  function tileY(rel) {
    if (rel === 0) return 0
    return Math.round((panel.bigH - panel.sliceH) / 2 + Math.min(Math.abs(rel), 8) * 3)
  }

  // A picture is decoded exactly while it has any part of the screen: the deck
  // is wider than the screen on a long listing, and the slices past the edge
  // are the only ones worth releasing. A slice that scrolls back in starts
  // loading again as it animates, rather than holding a decode for a picture
  // nobody can see.
  function tileVisible(rel) {
    const x = panel.tileX(rel)
    return x + panel.tileW(rel) > 0 && x < panel.width
  }

  // ---- row window ----------------------------------------------------------
  // Keyed by the FILE, not by its slot in the window: a selection step shifts
  // the window by one entry at each edge, and a removal shifts every row after
  // it, so a slot-keyed cell would take on its neighbour's picture - a decode
  // and a snap where the deck should have rolled. Keyed by file, every cell
  // that stayed keeps its picture, its decode and its glide.
  ListModel { id: deck }

  function _rowFile(abs) {
    const rows = panel.rows
    if (!rows || abs < 0 || abs >= rows.length) return ""
    const rec = rows[abs]
    return rec ? String(rec.value ?? "") : ""
  }

  // The directory a row's picture is read from: a user pick and a shipped
  // wallpaper are both rows, and only the row knows which tree it came from.
  function _rowDir(abs) {
    const rows = panel.rows
    if (!rows || abs < 0 || abs >= rows.length) return ""
    const rec = rows[abs]
    return rec ? String(rec.dir ?? "") : ""
  }

  // A revealed row the user disabled: it carries the Hidden badge and has no
  // file of its own left to remove.
  function _rowDisabled(abs) {
    const rows = panel.rows
    if (!rows || abs < 0 || abs >= rows.length) return false
    const rec = rows[abs]
    return rec ? rec.disabled === true : false
  }

  // The rows the deck instantiates: the window around the selection. It is
  // wider than the cascade shows, so a slide that is still animating in from the
  // edge has a tile to come from.
  function _windowAbss() {
    const n = panel.rows ? panel.rows.length : 0
    const out = []
    if (n === 0) return out
    const sel = Math.max(0, Math.min(panel.selIndex, n - 1))
    const start = Math.max(0, sel - panel.windowRadius)
    const end = Math.min(n - 1, sel + panel.windowRadius)
    for (let abs = start; abs <= end; abs++) out.push(abs)
    return out
  }

  // The window is diffed by FILE and not by slot. A removal shifts every row
  // after it down one index, so a slot-keyed patch hands each surviving cell
  // its neighbour's picture - a re-decode and a snap in place of the roll the
  // deck exists for. Keyed by file, every survivor keeps its own cell, its
  // decode and its glide, and the row that grows into the vacated slot is the
  // picture that was already beside it.
  //
  // The departing tile rides as a row of its own (abs -1) until its exit is
  // over: the row set has already dropped it by the time the commit lands, so
  // without a row here its cell would be destroyed in that same frame.
  //
  // Survivors keep their relative order through every change this deck takes,
  // so one ascending pass both patches and inserts without ever moving a row.
  function _syncWindow() {
    const want = []
    if (panel._leavingFile !== "") {
      // An empty dir lets the tile fall back to the user overlay: the
      // departing picture is already gone from the listing either way.
      want.push({ abs: -1, file: panel._leavingFile, rel: 0, dir: "", disabled: false, vanishing: false })
    }
    const abss = panel._windowAbss()
    for (let i = 0; i < abss.length; i++) {
      want.push({
        abs: abss[i],
        file: panel._rowFile(abss[i]),
        rel: abss[i] - panel.selIndex,
        dir: panel._rowDir(abss[i]),
        disabled: panel._rowDisabled(abss[i]),
        vanishing: false
      })
    }
    const wanted = Object.create(null)
    for (let i = 0; i < want.length; i++) wanted[want[i].file] = true

    // A row that leaves the window - the hidden set being hidden again, a theme
    // swap - fades out in place before it is dropped, so the deck reads as
    // pictures leaving rather than a snap to the next listing. `_settled` keeps
    // the open out of it: there the panel's own fade already covers the deck.
    const animate = panel._settled && MotionPolicy.enabled
    // A row that is wanted again before its fade finished turns around instead
    // of being released under the listing that just took it back.
    for (let i = 0; i < deck.count; i++) {
      const row = deck.get(i)
      if (row.vanishing === true && wanted[String(row.file)] === true) {
        deck.setProperty(i, "vanishing", false)
      }
    }
    for (let i = deck.count - 1; i >= 0; i--) {
      const row = deck.get(i)
      if (wanted[String(row.file)] === true || row.vanishing === true) continue
      if (animate) { deck.setProperty(i, "vanishing", true); continue }
      deck.remove(i)
    }
    // Departing rows are parked past the live window, so the ascending patch
    // below still lines up with `want`; each one releases itself when its fade
    // ends (see _dropVanished).
    let departing = 0
    for (let i = 0; i < deck.count; i++) {
      if (deck.get(i).vanishing === true) departing++
    }
    let at = 0
    while (departing > 0) {
      if (deck.get(at).vanishing === true) {
        deck.move(at, deck.count - 1)
        departing--
      } else {
        at++
      }
    }
    for (let i = 0; i < want.length; i++) {
      const row = deck.get(i)
      if (row && String(row.file) === want[i].file) {
        deck.setProperty(i, "abs", want[i].abs)
        deck.setProperty(i, "rel", want[i].rel)
        deck.setProperty(i, "dir", want[i].dir)
        deck.setProperty(i, "disabled", want[i].disabled)
      } else {
        deck.insert(i, want[i])
      }
    }
    // Only live rows are trimmed here: a departing one is released by its fade.
    while (deck.count > want.length && deck.get(deck.count - 1).vanishing !== true) {
      deck.remove(deck.count - 1)
    }
  }

  // A departing cell's fade is over: release its row. The wallpaper can come
  // back while the fade runs (a second toggle), in which case the row has
  // already been turned around and is left alone.
  function _dropVanished(file) {
    const name = String(file)
    if (panel._indexOf(name) >= 0) return
    for (let i = 0; i < deck.count; i++) {
      if (String(deck.get(i).file) === name) {
        deck.remove(i)
        return
      }
    }
  }

  function _currentFile() {
    const rows = panel.rows
    const i = panel.selIndex
    if (!rows || i < 0 || i >= rows.length) return ""
    const rec = rows[i]
    return rec ? String(rec.value ?? "") : ""
  }

  function _indexOf(file) {
    const rows = panel.rows
    if (!rows || file === "") return -1
    for (let i = 0; i < rows.length; i++) {
      const rec = rows[i]
      if (rec && String(rec.value ?? "") === file) return i
    }
    return -1
  }

  function syncRows() {
    const n = panel.rows ? panel.rows.length : 0
    const carried = panel._keepFile
    const keep = panel._indexOf(carried)
    // A committed removal arrives as a row set that no longer holds the file
    // the deck was on, while the panel still carries the request that took it
    // out. That is the one row-set change with a picture to animate away, so
    // the exit is armed here - before the window is diffed and the cell it
    // belongs to drops out of it.
    if (carried !== "" && keep < 0 && panel.pendingDeleteIndex >= 0) panel._leave(carried)
    const next = n === 0 ? 0 : (keep >= 0 ? keep : Math.min(panel.selIndex, n - 1))
    if (next !== panel.selIndex) panel.selIndex = next
    panel._keepFile = panel._currentFile()
    panel._syncWindow()
  }

  onRowsChanged: panel.syncRows()

  onSelIndexChanged: {
    panel._keepFile = panel._currentFile()
    panel._syncWindow()
  }

  // ---- selection / apply ---------------------------------------------------
  function select(index) {
    const n = panel.rows ? panel.rows.length : 0
    if (n === 0) return
    const next = Math.max(0, Math.min(index, n - 1))
    if (next !== panel.selIndex) panel.selIndex = next
  }

  function moveSelection(dir) {
    // Leaving the armed row gives back the confirm, like every other panel.
    if (panel._confirmOpen) panel.cancelDelete()
    const n = panel.rows ? panel.rows.length : 0
    if (n === 0) return
    // A step off either end of the listing lands on the other end, and that is
    // the whole of the wrap: the deck anchors on the selection, so the index is
    // the only thing that moves. Paging keeps its clamp instead.
    const next = dir === 1 || dir === -1
      ? (panel.selIndex + dir + n) % n
      : Math.max(0, Math.min(panel.selIndex + dir, n - 1))
    if (next !== panel.selIndex) panel.selIndex = next
  }

  function _isApplied(file) {
    if (file === "") return false
    const cur = SU.basename(String(Wallpaper.current))
    return cur !== "" && cur === file
  }

  // Accepting is apply-and-leave: the service sets the wallpaper and dismisses
  // the overlay (and the menu chain) in the same act, so the desktop is left
  // showing the picture that was just picked.
  function activateCurrent() {
    const file = panel._currentFile()
    if (file === "") return
    if (WallpaperPicker.optimistic.isPending(file)) return
    WallpaperPicker.setWallpaper(file)
  }
  function choose(file) {
    if (file === "") return
    if (WallpaperPicker.optimistic.isPending(file)) return
    WallpaperPicker.setWallpaper(file)
  }

  // 0 leaves the deck for the file chooser: a wallpaper that is not in this
  // theme's set is picked as a file by a separate surface and applied by the
  // script it opens. The deck leaves first so the chooser is not stacked over
  // a dimmed overlay.
  function pickFile() {
    WallpaperPicker.close()
    Exec.run([Paths.vibraniumHome + "/bin/vb-wallpaper-pick"])
  }

  // ---- delete --------------------------------------------------------------
  // Delete / Ctrl+D on the selected wallpaper: the footer asks, Enter removes,
  // Esc gives the deck back. A removal never changes what is on the desktop
  // unless the service says the removed file was the applied one.
  function toggleDelete() {
    const file = panel._currentFile()
    if (file === "") return
    // A revealed hidden wallpaper is already removed from the theme; Enter is
    // the key that restores it, so removal has nothing to arm here.
    if (WallpaperPicker.isDisabledRow(file)) return
    if (panel._confirmOpen && panel._confirmFile === file) {
      panel.acceptDelete()
      return
    }
    if (WallpaperPicker.optimistic.isPending(file)) return
    panel._confirmFile = file
    panel._confirmOpen = true
  }

  function cancelDelete() {
    panel._confirmOpen = false
    panel._confirmFile = ""
  }

  function acceptDelete() {
    const file = panel._confirmFile
    panel.cancelDelete()
    if (file === "") return
    if (WallpaperPicker.optimistic.isPending(file)) return
    panel.pendingDeleteIndex = panel.selIndex
    if (WallpaperPicker.requestDelete(file) !== true) panel.pendingDeleteIndex = -1
  }

  // The service's commit callbacks. The row set change itself arrives through
  // `rows`; these only repair the selection and drop the applied mark for a
  // file that no longer exists.
  function onDeleteCommitted(fileName) {
    panel.pendingDeleteIndex = -1
    Qt.callLater(() => panel.syncRows())
  }
  function onDeleteAborted() {
    panel.pendingDeleteIndex = -1
  }

  // The exit of the tile a removal took out of the deck. One progress value
  // drives it, so the lift and the fade cannot drift apart, and the deck's own
  // roll underneath is the other half of the same beat: the tile that was
  // beside the removed one is growing into its slot while this one lifts away.
  function _leave(file) {
    panel._leavingFile = ""
    panel._leaveProgress = 0
    panel._leavingFile = file
    // With motion off there is nothing to hold the row for: the deck lands in
    // place and the tile goes with the rows that are gone.
    if (!MotionPolicy.enabled) { panel._finishLeave(); return }
    leaveAnim.restart()
  }

  // The row is released only once the tween has run out, which is what turns
  // the exit into a fade instead of a hole. The diff runs again on release so
  // the deck does not keep a row for a file that is gone.
  function _finishLeave() {
    panel._leavingFile = ""
    panel._leaveProgress = 0
    panel._syncWindow()
  }

  NumberAnimation {
    id: leaveAnim
    target: panel
    property: "_leaveProgress"
    from: 0
    to: 1
    duration: Ui.slowMs
    easing.type: Easing.OutCubic
    onFinished: panel._finishLeave()
  }

  // ---- open / focus --------------------------------------------------------
  function _seatOnApplied() {
    // A visit starts from a settled deck, so an exit still running from the
    // last one is dropped rather than carried onto a new listing.
    leaveAnim.stop()
    panel._leavingFile = ""
    panel._leaveProgress = 0
    const applied = SU.basename(String(Wallpaper.current))
    const index = panel._indexOf(applied)
    panel._keepFile = index >= 0 ? applied : ""
    panel.selIndex = index >= 0 ? index : 0
    panel._syncWindow()
  }

  function reveal() {
    panel._fade = false
    panel._settled = false
    revealTimer.restart()
  }

  // One frame is what the surface needs to take its real size; the fade then
  // runs over content that is already laid out.
  Timer {
    id: revealTimer
    interval: 16
    onTriggered: {
      if (!WallpaperPicker.visible) return
      panel._settled = true
      panel._fade = true
    }
  }

  Connections {
    target: WallpaperPicker

    function onVisibleChanged() {
      if (!WallpaperPicker.visible) {
        panel._fade = false
        panel._settled = false
        revealTimer.stop()
        return
      }
      panel.cancelDelete()
      panel._seatOnApplied()
      panel.reveal()
      focusCtrl.grabList()
    }
  }

  // No field on this surface: the deck is the whole interface, so PanelFocus is
  // here for its window re-seat and its sink alone.
  PanelFocus {
    id: focusCtrl
    serviceVisible: WallpaperPicker.visible
  }
  property alias mode: focusCtrl.mode
  function grabList() { focusCtrl.grabList() }
  function reassertFocus() { focusCtrl.reassert() }

  function escapeChain() {
    if (panel._confirmOpen) { panel.cancelDelete(); return }
    WallpaperPicker.close()
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    // The confirm is modal: Enter or Space decides, Esc backs out, everything
    // else waits for one of those. Space confirms here because the deck has no
    // text entry, so the key has no other meaning on this surface.
    if (panel._confirmOpen) {
      // Delete (or Ctrl+D) again is the confirmation the pane advertises;
      // Enter and Space stay as equivalent keys for the same decision.
      if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space
          || k === Qt.Key_Delete || (k === Qt.Key_D && ctrl)) {
        panel.acceptDelete()
        event.accepted = true
        return
      }
      if (k === Qt.Key_Escape) { panel.cancelDelete(); event.accepted = true; return }
      return
    }
    if ((k === Qt.Key_D && ctrl) || k === Qt.Key_Delete) {
      panel.toggleDelete()
      event.accepted = true
      return
    }
    // The browse and file-chooser verbs are chords, not bare letters: a plain
    // keypress is left to whatever search trigger owns it.
    if (k === Qt.Key_H && ctrl) {
      WallpaperPicker.toggleHidden()
      event.accepted = true
      return
    }
    if (k === Qt.Key_O && ctrl) { panel.pickFile(); event.accepted = true; return }
    // The deck is horizontal, so both hands get a route: arrows, A/D from
    // WASD and J/K from vim all step the selection. Ctrl+D is claimed above as
    // the removal key, so D here is only the plain one.
    if (!ctrl) {
      if (k === Qt.Key_Right || k === Qt.Key_D || k === Qt.Key_K) {
        panel.moveSelection(1)
        event.accepted = true
        return
      }
      if (k === Qt.Key_Left || k === Qt.Key_A || k === Qt.Key_J) {
        panel.moveSelection(-1)
        event.accepted = true
        return
      }
    }
    switch (PanelKeys.route(k, Qt, true, false)) {
      case "next": panel.moveSelection(1); event.accepted = true; return
      case "prev": panel.moveSelection(-1); event.accepted = true; return
      case "pageUp": panel.moveSelection(-4); event.accepted = true; return
      case "pageDown": panel.moveSelection(4); event.accepted = true; return
      case "first": panel.select(0); event.accepted = true; return
      case "last": panel.select(panel.rows.length - 1); event.accepted = true; return
      case "activate": panel.activateCurrent(); event.accepted = true; return
      case "escape": panel.escapeChain(); event.accepted = true; return
    }
  }
  Keys.onPressed: event => panel.handleKey(event)

  // ---- surface -------------------------------------------------------------
  // Empty space closes the visit; the tiles and the footer sit above it.
  MouseArea {
    anchors.fill: parent
    onClicked: WallpaperPicker.close()
  }

  DropArea {
    id: drop

    anchors.fill: parent
    enabled: Wallpaper.enabled
    property bool dragOk: false
    onEntered: drag => {
      if (!Wallpaper.enabled) return
      drop.dragOk = Wallpaper._dropIsSupported(drag)
      if (drop.dragOk) drag.acceptProposedAction()
    }
    onExited: drop.dragOk = false
    onDropped: drag => {
      drop.dragOk = false
      if (!Wallpaper._dropIsSupported(drag)) return
      const uri = Wallpaper._droppedUri(drag)
      if (uri === "") return
      Wallpaper.handleDroppedUri(uri)
    }
  }

  Rectangle {
    anchors.fill: parent
    visible: drop.dragOk
    color: Ui.tint("accent", 0.10)
    border.color: Ui.solid("accent")
    border.width: 2
  }

  Item {
    id: stage

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: -28
    width: panel.width
    height: panel.bigH
    clip: true
    // A departing tile outlives the row set it came from: the last wallpaper a
    // theme held still has to fade out over an empty deck.
    // Departing rows outlive the listing they came from, so the deck stays up
    // while they fade out even when the last row has already left `rows`.
    visible: panel.rows.length > 0 || panel._leavingFile !== "" || deck.count > 0
    opacity: panel._fade ? 1 : 0

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }

    Repeater {
      model: deck

      // The cell owns the deck arithmetic and the motion; the tile owns the
      // picture. Required properties are the model's own roles, so the engine
      // initializes them per row and a window step updates these bindings in
      // place - the tile keeps its decoded image and glides to its new slot.
      delegate: Item {
        id: cell

        required property int rel
        required property string file
        required property string dir
        required property bool disabled
        // The row is leaving the window and is fading out before it is
        // released.
        required property bool vanishing

        // The tile a removal just took out of the listing. It keeps the slot it
        // was read in - the selection does not move on a removal - and leaves
        // from there, over the survivor that is growing into that slot.
        readonly property bool leaving: panel._leavingFile === cell.file
        // A tile on its way out is a picture of a file that no longer exists,
        // so it takes no clicks: the survivor underneath is the one a click
        // belongs to, and it is already the selection.
        enabled: !cell.leaving

        x: panel.tileX(cell.rel)
        y: panel.tileY(cell.rel)
        width: panel.tileW(cell.rel)
        height: panel.tileH(cell.rel)
        z: cell.leaving ? 200 : (cell.rel === 0 ? 100 : 50 - Math.min(Math.abs(cell.rel), 40))
        // A tile that arrives after the deck has settled - revealing the
        // disabled wallpapers - fades in over the deck's normal clock instead
        // of popping into its slot. Tiles placed during the open are already
        // covered by the panel's own fade, so they start at full opacity.
        property real appear: 1
        // The fade a departing row takes on its way out of the window.
        property real vanish: 1
        opacity: (cell.leaving ? 1 - panel._leaveProgress : 1) * cell.appear * cell.vanish
        onVanishingChanged: {
          vanishAnim.stop()
          vanishAnim.to = cell.vanishing ? 0 : 1
          vanishAnim.restart()
        }
        Component.onCompleted: {
          if (!panel._settled || !MotionPolicy.enabled) return
          cell.appear = 0
          appearAnim.start()
        }

        NumberAnimation {
          id: appearAnim

          target: cell
          property: "appear"
          to: 1
          duration: Ui.normalMs
          easing.type: Easing.OutCubic
        }

        NumberAnimation {
          id: vanishAnim

          target: cell
          property: "vanish"
          duration: Ui.normalMs
          easing.type: Easing.OutCubic
          onFinished: {
            const leaving = String(cell.file)
            if (cell.vanishing) Qt.callLater(() => panel._dropVanished(leaving))
          }
        }

        Behavior on x {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on y {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on width {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }
        Behavior on height {
          enabled: MotionPolicy.enabled && panel._settled
          Glide { duration: Ui.slowMs }
        }

        // The exit's lift rides a translate and not the y binding above: that
        // binding is re-aimed on every deck step and its glide would be
        // restarted on every frame of the fade.
        transform: Translate {
          y: cell.leaving ? -Math.round(panel.bigH * 0.10) * panel._leaveProgress : 0
        }

        // A drop shadow under every tile, so the cascade reads as a stack of
        // separate pictures rather than one band of colour.
        //
        // RectangularShadow and not a MultiEffect shadow: this one draws the
        // shadow ALONE. There is no source item painted along with it, which is
        // what turned an oversized or padded shadow effect into a solid black
        // frame around the picture, and it has a real spread in pixels where
        // MultiEffect has only a blur and a proportional scale - a scale that
        // grows the big card by tens of pixels and the narrow slices by two.
        //
        // It keeps the cell's paint order: declared first, so it sits under the
        // picture and under the frame's border.
        RectangularShadow {
          anchors.fill: parent
          radius: RoundingPolicy.radius
          color: "#66000000"
          // Pixels, not fractions, so every tile grows its halo by the same
          // amount instead of in proportion to its own size.
          blur: 12
          spread: 2
          offset: "0,2"
        }

        WallpaperEntry {
          anchors.fill: parent
          file: cell.file
          dir: cell.dir
          rel: cell.rel
          disabled: cell.disabled
          pending: WallpaperPicker.optimistic.isPending(cell.file)
          deleteArmed: panel._confirmOpen && panel._confirmFile === cell.file
          // The surface's own width is read here as well as inside the geometry:
          // a tile built before the deck has a size has to pick its picture up
          // when that size lands, and a direct read is what makes that re-run
          // certain rather than dependent on a read made inside a function.
          decode: panel.width > 0 && panel.tileVisible(cell.rel)
          decodeW: panel.decodeW
          decodeH: panel.decodeH
          onChosen: panel.choose(cell.file)
        }
      }
    }
  }

  Column {

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: stage.bottom
    anchors.topMargin: Ui.l
    width: Math.min(panel.bigW, Math.max(0, panel.width - 2 * Ui.outerPad))
    // No name to show until a listing offers one; an empty island would be a
    // lone pill under the deck.
    visible: stage.visible && panel._currentFile() !== ""
    opacity: panel._fade ? 1 : 0

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }

    // The selected file gets the footer's island: it sits over the same dimmed
    // backdrop, so a palette foreground on it is unreadable on a light theme.
    // White is the fallback text; the applied wallpaper still reads in accent.
    Rectangle {
      id: nameIsland

      x: Math.round((parent.width - width) / 2)
      implicitWidth: nameText.implicitWidth + Ui.l * 2
      implicitHeight: nameText.implicitHeight + Ui.s * 2
      width: Math.min(implicitWidth, parent.width)
      height: implicitHeight
      radius: Math.min(RoundingPolicy.radius, Math.round(height / 2))
      color: Qt.rgba(0, 0, 0, 0.62)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.18)

      Accessible.role: Accessible.StaticText
      Accessible.name: panel._currentFile()

      Text {
        id: nameText

        anchors.centerIn: parent
        width: Math.min(implicitWidth, nameIsland.width - Ui.l * 2)
        horizontalAlignment: Text.AlignHCenter
        text: panel._currentFile()
        color: panel._isApplied(panel._currentFile())
          ? Ui.solid("accent")
          : "#ffffff"
        font.pixelSize: Ui.fontCardTitle
        font.family: Ui.fontFamily
        font.bold: true
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
      }
    }
  }

  EmptyState {
    anchors.centerIn: parent
    width: Math.max(0, panel.width - 64)
    visible: panel.rows.length === 0 && deck.count === 0
    opacity: panel._fade ? 1 : 0
    text: "No wallpapers"
    iconName: "image"
    iconColorKey: "foreground_1"
  }

  // The footer legend: navigation and acceptance in the accent, the removal
  // key in the palette's red, and the file chooser in yellow - the one key
  // that leaves the theme's own set. Styled text because the keys are colored
  // per key rather than the whole line.
  function _key(name, color) {
    return "<font color=\"" + color + "\">" + name + "</font>"
  }
  function _escText(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
  function _legend() {
    const accent = Ui.solid("accent")
    if (panel._confirmOpen) {
      return "Remove " + panel._escText(panel._confirmFile) + "?  "
        + panel._key("Delete", Ui.solid("red")) + " again to remove · "
        + panel._key("Esc", accent) + " cancels"
    }
    // The reveal verb is only advertised while the theme has something to
    // reveal: a Ctrl+H that would do nothing is a dead key in the legend.
    const hidden = WallpaperPicker.hiddenCount > 0
      ? panel._key("Ctrl+H", Ui.solid("purple"))
        + (WallpaperPicker.showHidden ? " hide hidden · " : " show hidden · ")
      : ""
    return panel._key("←/→", accent) + " · " + panel._key("A/D", accent)
      + " · " + panel._key("J/K", accent) + " browse · "
      + panel._key("Enter", accent) + " / " + panel._key("Space", accent) + " apply · "
      + hidden
      + panel._key("Ctrl+O", Ui.solid("yellow")) + " open · "
      + panel._key("Delete", Ui.solid("red")) + " remove · Esc close"
  }
  // The legend without its per-key markup, for the island's accessible name:
  // a screen reader should read the keys, not the colour tags.
  function _legendPlain() {
    return panel._legend().replace(/<[^>]*>/g, "")
  }

  // The footer sits on its own dark island rather than straight on the backdrop.
  // The deck behind it is a dimmed desktop, and a palette foreground on that is
  // exactly the light-theme failure this avoids: on a light theme `foreground_1`
  // is a dark colour over an already dark backdrop, so the plain words vanished.
  // The island is theme-independent - a stronger scrim plus white text - which
  // is why the words are white instead of a palette leaf; the key hints keep
  // their palette colours, and the border and rounding make the island read as
  // a surface of its own rather than a floating line of text.
  Rectangle {
    id: footer

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Ui.outerPad * 2
    implicitWidth: footerText.implicitWidth + Ui.l * 2
    implicitHeight: footerText.implicitHeight + Ui.s * 2
    width: Math.min(implicitWidth, Math.max(0, panel.width - 2 * Ui.outerPad))
    height: implicitHeight
    radius: Math.min(RoundingPolicy.radius, Math.round(height / 2))
    color: Qt.rgba(0, 0, 0, 0.62)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.18)
    opacity: panel._fade ? 1 : 0

    Accessible.role: Accessible.StaticText
    Accessible.name: panel._legendPlain()

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      Glide { duration: Ui.fastMs }
    }

    Text {
      id: footerText

      anchors.centerIn: parent
      width: Math.min(implicitWidth, footer.width - Ui.l * 2)
      horizontalAlignment: Text.AlignHCenter
      text: panel._legend()
      color: "#ffffff"
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily
      elide: Text.ElideRight
      textFormat: Text.StyledText
    }
  }

}

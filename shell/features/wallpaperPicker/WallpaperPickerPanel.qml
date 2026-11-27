pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Effects
import Quickshell
import qs.common
import qs.features.wallpaper
import qs.features.wallpaperPicker
import "../../common/text/StringUtils.js" as SU
import "../../common/ui/KeyHint.js" as KeyHint
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
// APPLYING IS PART OF SELECTING. Enter or Space sets the wallpaper and ends
// the visit in the same act; the picker never defers the apply to the close,
// and there is no separate confirm step.
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

  // A wallpaper that is globally disabled still opens this picker, but it has
  // no list to browse: the deck is replaced by a single disabled-state mark.
  readonly property bool featureDisabled: !Wallpaper.enabled

  // Selected row. The deck's whole geometry is a function of this index.
  property int selIndex: 0
  // How many rows on each side of the selection the deck instantiates. The
  // visible count follows the screen; the window is a little wider so a slide
  // that is still animating in from the edge has a tile to come from.
  readonly property int windowRadius: 6
  // Open fade. The content is one opacity fade - no per-element and no
  // per-tile entrance - and `_settled` keeps the deck's geometry tweens off
  // until the surface has taken a real size, so the first frame cannot
  // animate a cascade out of zero-sized cards. That size is a live fact, not
  // a one-frame timer guess.
  property bool _fade: false
  property bool _settled: false
  readonly property bool _sized: width > 0 && height > 0
  // The whole deck rises into place as the layer opens, the way the theme
  // picker's stage glides up into its settled y. The stage reads this offset;
  // the deck's own geometry still has only its deckPos clock.
  property real stageSlideY: MotionPolicy.enabled ? Ui.m * 2 : 0
  // One fade for the WHOLE overlay, inherited by every child. Nothing inside
  // animates its own presence. Deck glides wait until that fade has landed so
  // the first painted frame is already at its final geometry.
  opacity: panel._fade ? 1 : 0
  Behavior on opacity {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.fastMs }
  }
  readonly property bool _deckLive: !MotionPolicy.enabled || opacity >= 0.99

  // One stage-sized rise per visit, from just below the resting position.
  // A dedicated tween keeps this layer motion off the deck's single clock.
  NumberAnimation {
    id: stageRise
    target: panel
    property: "stageSlideY"
    from: Ui.m * 2
    to: 0
    duration: Ui.slowMs
    easing.type: Easing.OutCubic
  }
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

  // The deck's one animated source. selIndex is the committed selection (what
  // Enter applies, what the footer names, what a delete repairs); deckPos is
  // where the cascade is actually looking. They agree at rest. A step off an
  // end keeps selIndex at the destination but walks deckPos across every
  // intervening entry, so the wrap is a journey through the list rather than
  // a one-frame re-dress of the window.
  property real deckPos: 0
  // Duration for the one Behavior below, armed BEFORE the deckPos write - the
  // same pre-arm List.qml uses for _sweepMs, because a tween launched on an
  // assignment ignores a duration changed afterwards. Long for a wrap,
  // Ui.slowMs for a step, 0 for the instant re-seat of a new row set.
  property int _deckTravelMs: 0
  property int _nextMoveMs: 0
  // The integer centre the current window was built for. The window only needs
  // re-diffing when this changes; tile geometry itself reads deckPos live.
  property int _windowCenter: 0

  // One clock for the whole deck. Tile x/y/width/height are pure functions of
  // deckPos below; no cell runs a second tween that could chase a re-aimed
  // window frame by frame. The fade gate keeps geometry off until the panel is
  // settled, as it did when the cells owned their own Behaviours.
  Behavior on deckPos {
    // A zero duration is the instant case: the tween lands in the tick it
    // starts, so an in-flight wrap replaced by a new row set cannot keep
    // driving deckPos towards a target from the old listing.
    enabled: MotionPolicy.enabled && panel._deckLive
    Glide { duration: panel._deckTravelMs }
  }

  // The single place deckPos is written. Callers arm the duration first, then
  // come through here, so the Behavior reads the right clock on the write.
  function _seatDeck(value, ms) {
    panel._deckTravelMs = ms
    panel.deckPos = value
  }

  // One place for every selection commit. The duration is parked on
  // _nextMoveMs and picked up by onSelIndexChanged, which is the only handler
  // that seats the deck for a selection change.
  function _commitSelection(next, ms) {
    panel._nextMoveMs = ms
    if (next === panel.selIndex) {
      // A row-set change can move the list under an unchanged index; the deck
      // still has to be re-seated, instantly, on the file that index now names.
      panel._seatDeck(next, 0)
      return
    }
    panel.selIndex = next
  }

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

  // Tile geometry is a pure function of a CONTINUOUS rel = abs - deckPos. At
  // rel 0 a tile is the big card; at |rel| >= 1 it is a slice. Between the two
  // the size and the x/y offsets interpolate, which is what makes a wrap leg
  // show the same moving picture on every frame instead of a tween restarted
  // on each integer step. There is deliberately no Behavior on these - the
  // deckPos clock above is the only motion.
  function tileW(rel) {
    const a = Math.abs(rel)
    return a >= 1 ? panel.sliceW
      : Math.round(panel.bigW + (panel.sliceW - panel.bigW) * a)
  }
  function tileH(rel) {
    const a = Math.abs(rel)
    return a >= 1 ? panel.sliceH
      : Math.round(panel.bigH + (panel.sliceH - panel.bigH) * a)
  }
  function tileX(rel) {
    const a = Math.abs(rel)
    const centreX = panel.deckCenterX - panel.bigW / 2
    if (a < 0.0001) return centreX
    if (rel < 0) return Math.round(centreX - a * panel.sliceStep)
    const sliceX = panel.deckCenterX + panel.bigW / 2 - panel.sliceOverlap
    if (a >= 1) return Math.round(sliceX + (a - 1) * panel.sliceStep)
    return Math.round(centreX + (sliceX - centreX) * a)
  }
  // A gentle downward cascade outward, kept inside the slice's own inset so a
  // slice never leaves the deck's band. The first unit of rel is the same
  // interpolation the card's size takes; past it the slice only steps down.
  function tileY(rel) {
    const a = Math.abs(rel)
    if (a < 0.0001) return 0
    const one = Math.round((panel.bigH - panel.sliceH) / 2 + 3)
    if (a < 1) return Math.round(one * a)
    return Math.round((panel.bigH - panel.sliceH) / 2 + Math.min(a, 8) * 3)
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

  // The rows the deck instantiates: the window around where the deck is
  // LOOKING, not around the committed index. During a wrap the two differ:
  // deckPos walks every entry between the ends, so the window follows it and
  // a tile to come from always exists on the side the motion is heading.
  function _windowAbss() {
    const n = panel.rows ? panel.rows.length : 0
    const out = []
    if (n === 0) return out
    const sel = Math.max(0, Math.min(Math.round(panel.deckPos), n - 1))
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
      want.push({ abs: -1, file: panel._leavingFile, dir: "", disabled: false })
    }
    const abss = panel._windowAbss()
    if (abss.length > 0) {
      panel._windowCenter = Math.round(panel.deckPos)
    }
    for (let i = 0; i < abss.length; i++) {
      want.push({
        abs: abss[i],
        file: panel._rowFile(abss[i]),
        dir: panel._rowDir(abss[i]),
        disabled: panel._rowDisabled(abss[i])
      })
    }
    const wanted = Object.create(null)
    for (let i = 0; i < want.length; i++) wanted[want[i].file] = true

    // A row that leaves the window is removed directly. A tile never animates
    // its own presence: the overlay's fade owns the open and close, and the
    // deck's geometry glides own selection changes. A per-tile fade here would
    // be a second clock on the same picture, and it made the selection border
    // flicker for the length of the glide.
    for (let i = deck.count - 1; i >= 0; i--) {
      const row = deck.get(i)
      if (wanted[String(row.file)] === true) continue
      deck.remove(i)
    }
    for (let i = 0; i < want.length; i++) {
      const row = deck.get(i)
      if (row && String(row.file) === want[i].file) {
        deck.setProperty(i, "abs", want[i].abs)
        deck.setProperty(i, "dir", want[i].dir)
        deck.setProperty(i, "disabled", want[i].disabled)
      } else {
        deck.insert(i, want[i])
      }
    }
    while (deck.count > want.length) {
      deck.remove(deck.count - 1)
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
    // A new row set is a new coordinate space: the deck re-seats instantly
    // rather than gliding across indices that no longer name the same files.
    panel._commitSelection(next, 0)
    panel._keepFile = panel._currentFile()
    panel._syncWindow()
  }

  onRowsChanged: panel.syncRows()

  onSelIndexChanged: {
    panel._keepFile = panel._currentFile()
    panel._seatDeck(panel.selIndex, panel._nextMoveMs)
  }

  // The window follows the live deck position, so a wrap leg creates the next
  // slice just before the moving card needs it and retires the old one as it
  // leaves. Only an integer centre crossing diffs the model; between crossings
  // the delegates derive their own rel from deckPos with no per-frame churn.
  onDeckPosChanged: {
    const n = panel.rows ? panel.rows.length : 0
    if (n === 0) return
    const centre = Math.max(0, Math.min(Math.round(panel.deckPos), n - 1))
    if (centre !== panel._windowCenter) panel._syncWindow()
  }

  // ---- selection / apply ---------------------------------------------------
  function select(index) {
    const n = panel.rows ? panel.rows.length : 0
    if (n === 0) return
    const next = Math.max(0, Math.min(index, n - 1))
    panel._commitSelection(next, Ui.slowMs)
  }

  function moveSelection(dir) {
    // Leaving the armed row gives back the confirm, like every other panel.
    if (panel._confirmOpen) panel.cancelDelete()
    const n = panel.rows ? panel.rows.length : 0
    if (n === 0) return
    const cur = panel.selIndex
    const next = dir === 1 || dir === -1
      ? (cur + dir + n) % n
      : Math.max(0, Math.min(cur + dir, n - 1))
    const wrapped = (dir === 1 && next < cur) || (dir === -1 && next > cur)
    let ms = Ui.slowMs
    if (wrapped) {
      // A lap crosses every entry between the ends. Keep the committed index
      // at the destination (Enter applies what the user asked for) but let the
      // one deck clock traverse the whole list, the way the old List picker's
      // wrap lap glided contentY across the rows instead of jumping to them.
      // The span, not a fixed delay, sets the length of the journey.
      ms = Math.min(1600, Ui.slowMs + Math.abs(cur - next) * 20)
    }
    panel._commitSelection(next, ms)
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
    // A new visit is a fresh seat, never a journey from the last visit's
    // position through a listing that may have changed while closed.
    panel._commitSelection(index >= 0 ? index : 0, 0)
    panel._syncWindow()
  }

  function _armStageRise() {
    if (!MotionPolicy.enabled) {
      panel.stageSlideY = 0
      return
    }
    // The size edge and the deferred settle can both land on the same open;
    // a second arm would pull the stage back down after it started rising.
    if (!stageRise.running) stageRise.restart()
  }

  function reveal() {
    panel._fade = false
    panel._settled = false
    // The panel can already be sized from a previous open, in which case no
    // size edge will fire: re-check the live fact on the next turn. A panel
    // that is still unsized is armed by on_SizedChanged when it lands.
    Qt.callLater(() => {
      if (!WallpaperPicker.visible || !panel._sized) return
      panel._settled = true
      panel._fade = true
      panel._armStageRise()
    })
  }

  on_SizedChanged: {
    if (!panel._sized || !WallpaperPicker.visible || panel._fade) return
    panel._settled = true
    panel._fade = true
    panel._armStageRise()
  }

  Connections {
    target: WallpaperPicker

    function onVisibleChanged() {
      if (!WallpaperPicker.visible) {
        panel._fade = false
        panel._settled = false
        // Re-arm the offset so the next open has a start point to glide from.
        stageRise.stop()
        panel.stageSlideY = MotionPolicy.enabled ? Ui.m * 2 : 0
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
    // With no list on screen, browsing and applying would pick a picture blind.
    // Only the close verb remains while the feature is disabled.
    if (panel.featureDisabled) {
      if (k === Qt.Key_Escape) { WallpaperPicker.close(); event.accepted = true }
      return
    }
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
    // PgUp/Start reach the right end of this horizontal deck and PgDn/End the
    // left one, the reverse of a vertical list. They take their own key
    // checks so Tab/Backtab keep the ordinary next/previous step.
    if (k === Qt.Key_PageUp) { panel.moveSelection(1); event.accepted = true; return }
    if (k === Qt.Key_PageDown) { panel.moveSelection(-1); event.accepted = true; return }
    if (k === Qt.Key_Home) { panel.select(panel.rows.length - 1); event.accepted = true; return }
    if (k === Qt.Key_End) { panel.select(0); event.accepted = true; return }
    switch (PanelKeys.route(k, Qt, true, false)) {
      case "next": panel.moveSelection(1); event.accepted = true; return
      case "prev": panel.moveSelection(-1); event.accepted = true; return
      case "activate": panel.activateCurrent(); event.accepted = true; return
      case "escape": panel.escapeChain(); event.accepted = true; return
    }
  }
  Keys.onPressed: event => panel.handleKey(event)

  // ---- surface -------------------------------------------------------------
  Item {
    id: stage

    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round((panel.height - panel.bigH) / 2 - 28 + panel.stageSlideY)
    width: panel.width
    height: panel.bigH
    clip: true
    // The footer is anchored to the stage, so it travels with the list.
    // A departing tile outlives the row set it came from: the last wallpaper a
    // theme held still has to fade out over an empty deck.
    // Departing rows outlive the listing they came from, so the deck stays up
    // while they fade out even when the last row has already left `rows`.
    visible: !panel.featureDisabled
      && (panel.rows.length > 0 || panel._leavingFile !== "" || deck.count > 0)

    Repeater {
      model: deck

      // The cell owns the deck arithmetic; the tile owns the picture. rel is
      // derived live from the one deckPos clock, not stored per frame, and the
      // geometry functions below are pure in it. No cell owns a tween, so a
      // wrap cannot leave one behind or start a second clock chasing another.
      delegate: Item {
        id: cell

        required property int abs
        required property string file
        required property string dir
        required property bool disabled

        // The departed tile is docked at the centre for its whole exit; the
        // rest are positioned by the live difference from the deck's position.
        readonly property real deckRel: cell.abs < 0 ? 0 : cell.abs - panel.deckPos

        // The tile a removal just took out of the listing. It keeps the slot it
        // was read in - the selection does not move on a removal - and leaves
        // from there, over the survivor that is growing into that slot.
        readonly property bool leaving: panel._leavingFile === cell.file
        x: panel.tileX(cell.deckRel)
        y: panel.tileY(cell.deckRel)
        width: panel.tileW(cell.deckRel)
        height: panel.tileH(cell.deckRel)
        z: cell.leaving ? 200
          : (Math.abs(cell.deckRel) < 0.5 ? 100 : 50 - Math.min(Math.floor(Math.abs(cell.deckRel)), 40))
        // A tile is still about its own presence: the overlay's fade owns the
        // open and close, and the only per-tile opacity here is the delete
        // exit, which the controller drives through _leaveProgress.
        opacity: cell.leaving ? 1 - panel._leaveProgress : 1

        // The exit's lift rides a translate rather than the y binding: y is
        // re-derived from deckPos on every frame and a second tween on it
        // would chase the one clock the deck already has.
        transform: Translate {
          y: cell.leaving ? -Math.round(panel.bigH * 0.10) * panel._leaveProgress : 0
        }

        // A drop shadow under every tile, so the cascade reads as a stack of
        // separate pictures rather than one band of color.
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
          // The veil is a state (selected or not), not a continuous value: let
          // it change once, at the midpoint, while the card itself moves.
          rel: Math.round(cell.deckRel)
          disabled: cell.disabled
          pending: WallpaperPicker.optimistic.isPending(cell.file)
          deleteArmed: panel._confirmOpen && panel._confirmFile === cell.file
          // The surface's own width is read here as well as inside the geometry:
          // a tile built before the deck has a size has to pick its picture up
          // when that size lands, and a direct read is what makes that re-run
          // certain rather than dependent on a read made inside a function.
          decode: panel.width > 0 && panel.tileVisible(cell.deckRel)
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
    visible: stage.visible && !panel.featureDisabled && panel._currentFile() !== ""

    // The selected file gets the footer's island: it sits over the same dimmed
    // backdrop, so a palette foreground on it is unreadable on a light theme.
    // White is the fallback text; the applied wallpaper still reads in accent.
    GlassPill {
      id: nameIsland

      x: Math.round((parent.width - width) / 2)
      maxWidth: parent.width
      text: panel._currentFile()
      textColor: panel._isApplied(panel._currentFile())
        ? Ui.solid("accent")
        : "#ffffff"
      accessibleName: panel._currentFile()
      fontPixelSize: Ui.fontCardTitle
      fontFamily: Ui.fontFamily
      bold: true
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
    }
  }

  EmptyState {
    anchors.centerIn: parent
    width: Math.max(0, panel.width - 64)
    visible: !panel.featureDisabled && panel.rows.length === 0 && deck.count === 0
    text: "No wallpapers"
    iconName: "image"
    iconColorKey: "foreground_1"
  }

  // Stand-in for the deck while the feature is off: a large glyph over copy
  // naming the disabled state. The picker stays openable so its close chain is
  // intact; no picture is offered and the list keys are inert.
  EmptyState {
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -20
    width: Math.max(0, panel.width - 64)
    visible: panel.featureDisabled
    text: "Wallpapers are disabled"
    iconName: "eye-closed"
    iconColorKey: "foreground_1"
    iconSize: 128
    textSize: 18
    maxTextWidth: 360
  }

  // The footer legend: navigation and acceptance in the accent, the removal
  // key in the palette's red, and the file chooser in yellow - the one key
  // that leaves the theme's own set. Styled text because the keys are colored
  // per key rather than the whole line; the markup and plain-text recipes
  // live in KeyHint.js, shared with the theme picker.
  function _legend() {
    const accent = Ui.solid("accent")
    if (panel._confirmOpen) {
      return "Remove " + KeyHint.escape(panel._confirmFile) + "?  "
        + KeyHint.key("Delete", Ui.solid("red")) + " again to remove · "
        + KeyHint.key("Esc", accent) + " cancels"
    }
    // The reveal verb is only advertised while the theme has something to
    // reveal: a Ctrl+H that would do nothing is a dead key in the legend.
    const hidden = WallpaperPicker.hiddenCount > 0
      ? KeyHint.key("Ctrl+H", Ui.solid("purple"))
        + (WallpaperPicker.showHidden ? " hide hidden · " : " show hidden · ")
      : ""
    return KeyHint.key("←/→", accent) + " · " + KeyHint.key("A/D", accent)
      + " · " + KeyHint.key("J/K", accent) + " browse · "
      + KeyHint.key("Enter", accent) + " / " + KeyHint.key("Space", accent) + " apply · "
      + hidden
      + KeyHint.key("Ctrl+O", Ui.solid("yellow")) + " open · "
      + KeyHint.key("Delete", Ui.solid("red")) + " remove · Esc close"
  }

  // The footer sits on its own dark island rather than straight on the backdrop.
  // The deck behind it is a dimmed desktop, and a palette foreground on that is
  // exactly the light-theme failure this avoids: on a light theme `foreground_1`
  // is a dark color over an already dark backdrop, so the plain words vanished.
  // The island is theme-independent - a stronger scrim plus white text - which
  // is why the words are white instead of a palette leaf; the key hints keep
  // their palette colors, and the border and rounding make the island read as
  // a surface of its own rather than a floating line of text.
  GlassPill {
    id: footer

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Ui.outerPad * 2
    maxWidth: Math.max(0, panel.width - 2 * Ui.outerPad)
    visible: !panel.featureDisabled
    accessibleName: KeyHint.plain(panel._legend())
    text: panel._legend()
    fontPixelSize: Ui.fontL
    fontFamily: Ui.fontFamily
    elide: Text.ElideRight
    textFormat: Text.StyledText
  }

  PointerGuard {}
}

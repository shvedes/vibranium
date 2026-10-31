pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import qs.features.pass
import "Model.js" as Model
import "../../common/ui/SlotGrowth.js" as SlotGrowth

// Password-manager card over the Pass service: root menu (Browse Vault
// + git), folder browser with leading create rows, per-entry actions and
// create flows. A filter bar spans every view (launcher geometry and
// keyboard model: list-first, typing feeds, "/" focuses, Esc peels).
// Names are edited inline (DropdownSlot + InputField under the row),
// secrets in a masked overlay; there are no Back rows anywhere.
//
// Delete/Ctrl-D stage the delete on the vault row under the cursor, from
// the list and from the focused filter alike - the field takes the two
// keys ahead of its own editing while such a row is under the cursor,
// launcher parity. A row found by searching is a vault row like any
// other, so it deletes the same way the browsed one does.
//
// SPLIT MAP (one owner each, no behavior change): the list shell stays
// here (filter bar, folder browser, rows, overlays) and Editor (inline
// editor plumbing: DropdownSlot + InputField under the row, masked
// secret overlay, create flows) owns its region below.
PanelCard {
  id: panel

  maxHeight: 600
  hardMaxHeight: 1200
  vPad: Ui.outerPad + 8
  hPad: Ui.outerPad
  baseWidth: 380
  rowIconW: 26
  rowBadgeW: 22
  _maxLabelW: 420
  // Package-missing state: the card keeps its normal shape - the dead
  // filter box stays visible, dimmed under the warning backdrop (the
  // island pattern: dead content dims, it does not vanish). The
  // empty-list floor grows so the warning column breathes below the
  // input instead of squeezing against it.
  emptyMinH: panel.noPassBinary ? 180 : Ui.emptyMinH

  count: list.count
  contentHeight: list.contentHeight
  rows: panel.rowData
  // The gap between rows is the LIST's, read rather than assumed: the card
  // sums the same gap the list places, so the region's bottom edge stays on
  // a row boundary whatever a surface decides to space its rows by.
  rowSpacing: list.spacing
  bottomReserve: panel.statusReserve
  exactListH: list.contentHeight > 0 ? list.fitHeight(panel.availListH) : -1
  // The list owns the growth claim (List.revealNeedH) and the rule that turns
  // it into a region lives once, in SlotGrowth.js, so this surface and the
  // menu cannot answer the same question two different ways. What the card
  // receives is the DECIDED region, and separately whether a slot is open at
  // all - a dropdown that fits in the resting region asks for no resize while
  // still making the content taller, and conflating the two latched an
  // inflated content height as the resting size.
  slotOpen: list.revealNeedH > 0
  slotRegionH: SlotGrowth.regionForSlot(
    list, panel.restingListH, panel.screenMaxListH, Ui.s)
  // A keystroke is a real resize, so the card glides to its fitted height
  // even inside the show gate - the launcher carve-out, same rule: without
  // this a filter typed before the appear animation finishes snaps.
  sizeMotionDuringGate: panel.filterText !== ""

  // Row payloads for the list; PanelCard reads them for width fitting.
  // Named rowData (not rows) - rows is PanelCard's own property.
  property var rowData: []
  property int baseCount: 0
  property string filterText: ""
  property bool scopedFiltering: false
  property int matchCount: 0
  // Inline-editor state: one open at a time, re-derived every rebuild
  // from mode + initial so refreshes and filters never orphan it.
  property int editorIndex: -1
  property string editorMode: "" // "" | create-name | mkdir | rename
  property string editorInitial: ""
  property bool editorPendingFocus: false
  // Same-tick reentry guard: the Enter that commits an editor also
  // bubbles to handleKey after closeEditor cleared `editing`, so the
  // trailing activateCurrent would re-run the row it just left.
  property bool _editorAcceptTick: false
  // Move picker + init key picker sub-states.
  property string sub: "" // "" | movepick | keys
  property string moveDir: ""
  property string pendingName: ""
  // One-shot follow selection for instant mkdir: the next syncRows
  // seats the cursor on the newborn folder, then clears the flag.
  property string pendingSelectDir: ""
  property string createMethod: ""
  property string secretHint: ""
  // Secret typed for a create that hit the overwrite guard: the overlay
  // hides while confirming, the value waits here (never rendered).
  property string pendingSecret: ""
  property int overwriteStage: 0
  property string deletePath: ""
  property int deleteStage: 0
  // True while the staged delete targets a folder (recursive rm).
  property bool deleteIsDir: false
  // The record array the view shows. `values` is the ScriptModel's only
  // write, so this array IS the model's whole data path and syncRows is its
  // only writer - which is also what keeps a rebaked row (bakeEditor
  // mutating `editor` in place) from reaching the view outside the swap
  // window the install runs in.
  property var _rows: []
  // Display model: a ScriptModel over `_rows`. Reassigning `values` diffs the
  // row set inside the model rather than resetting the view, so a rebuild
  // that keeps a row's identity reuses that row's delegate instead of
  // destroying and re-laying it out.
  ScriptModel {
    id: listModel
    values: panel._rows
    // The identity keyedRows() mints, lifted onto the row itself so the
    // record the delegate receives IS the row and the body reads
    // `modelData.<field>`. It is `uid` and not `key` because a GPG key row
    // already carries a `key` payload (the fingerprint) that
    // activateCurrent reads to initialise the store - stamping the identity
    // over it would destroy the only field that row has.
    objectProp: "uid"
    // Identity compares a payload by reference, which is what these rows are
    // built under: rebuild() mints fresh row objects every pass, so a
    // payload change is always a new reference. The default (Structure)
    // would compare by content instead.
    comparisonMode: ObjectComparison.Identity
  }
  // Identity epoch for the list's height table. A ScriptModel reports
  // neither a revision nor a key-set flag, so the panel owns the counter,
  // and it advances at the model's single write site (install) rather than
  // from a binding over the value it reads - that is a loop, and the engine
  // warns about it on every pass.
  //
  // It advances only when the key SEQUENCE changed, so a payload-only change
  // keeps the measured heights and a key-set change prunes the rows the new
  // key set no longer claims. A counter rather than the sequence itself
  // because List.qml:329 wants a revision that never repeats an earlier
  // value, and a page re-entered returns to the same sequence - which is
  // ordinary here, frames restore the same folder over and over. A keyed
  // model publishes `revision` on a key-set change and 0 on anything else, so
  // the value oscillates; this one
  // only rises, which is the property List.qml actually asks for.
  property int _epoch: 0
  property var _lastSeq: ""
  readonly property int identityRevision: panel._epoch
  property ListFrameState frames: ListFrameState { view: list }

  // Frame-key namespaces. viewKey() builds the keys and the cleanup
  // sites match on the prefixes, so both read one spelling: a
  // temporary namespace (the move picker) cannot be forgotten under a
  // prefix the builder never emits.
  readonly property string frameOwner: "pass"
  readonly property string browsePrefix: "browse:"
  readonly property string pickPrefix: "pick:"
  readonly property string actionPrefix: "action:"

  // A frame namespace the running transition has already outlived.
  // Removal is refused while a restore token is live, so the discard
  // waits for the commit that closes the window.
  property string _discardPrefix: ""

  // True while a name/secret field owns the keyboard: list shortcuts
  // stand down so typing never double-fires panel actions.
  readonly property bool editing: panel.editorMode !== "" || panel.secretOpen
  readonly property bool secretOpen: panel.createMethod === "enter" && panel.overwriteStage === 0
  readonly property bool primarySurface: visible
  readonly property bool vaultSearchable: Pass.initialized
    && (Pass.mode === "browse" || Pass.mode === "menu")
  readonly property bool filteringPage: panel.scopedFiltering || !panel.vaultSearchable
  // Footer reserve below the list so the transient status line never
  // overlaps rows; zero when hidden (reads implicitHeight only, so no
  // height loop like a direct binding would make).
  readonly property real statusReserve: statusLine.visible ? statusLine.implicitHeight + Ui.s : 0

  Component.onCompleted: panel.rebuild()
  // Disabled in the warning state so a tap on the card edges cannot
  // focus the dead filter (the overlay MouseArea already eats the
  // press, this closes the gesture-handler path on top).
  TapHandler { enabled: !panel.noPassBinary; onTapped: focusCtrl.grabFilter() }

  Connections {
    target: Pass
    function onEntriesChanged() {
      // Selected entry vanished (deleted or moved away) - drop to browse.
      if (Pass.mode === "action" && Pass.selectedPath !== "") {
        let found = false
        const es = Pass.entries
        for (let i = 0; i < es.length; i++) {
          if (es[i] && es[i].path === Pass.selectedPath) { found = true; break }
        }
        if (!found) {
          Pass.mode = "browse"
          panel.closeDelete()
          panel.closeEditor()
        }
      }
      if (Pass.mode === "create" && panel.createMethod !== "") {
        panel.createMethod = ""
        panel.pendingSecret = ""
        panel.pendingName = ""
        panel.overwriteStage = 0
        Pass.mode = "browse"
      }
      panel.rebuild()
    }
    function onAllDirsChanged() {
      panel.rebuild()
    }
    function onVisibleChanged() {
      if (!Pass.visible) {
        panel.resetPageTransition()
        panel._openSeat = false
        // A wholesale clear drops every frame and the window with it,
        // so no deferred discard survives into the next session.
        panel._discardPrefix = ""
        panel.frames.clear()
        return
      }
      panel.sub = ""
      panel.moveDir = ""
      panel.closeEditor()
      panel.pendingName = ""
      panel.pendingSelectDir = ""
      panel.createMethod = ""
      panel.secretHint = ""
      panel.pendingSecret = ""
      panel.overwriteStage = 0
      panel.closeDelete()
      panel.clearQuery()
      secretBox.clear()
      panel._openSeat = true
      panel.resetPageTransition()
      panel._discardPrefix = ""
      panel.frames.clear()
      list.settle(0, true)
      list.seatTo(0, false, "pass-open")
      panel.show()
      panel.rebuild()
      focusCtrl.grabList()
    }
    function onModeChanged() { panel.closeDelete(); panel.closeEditor(); panel.rebuild() }
    function onCurrentDirChanged() { panel.rebuild() }
    function onInitializedChanged() { panel.rebuild() }
    function onGitReadyChanged() { panel.rebuild() }
    function onKeysReady() { panel.rebuild() }
    // Probe landed mid-open (slow boot): swap to the empty/overlay state
    // without waiting for the next natural rebuild.
    function onPassBinaryChanged() { panel.rebuild() }
    function onDeleteCommitted(path) {
      const p = String(path || "")
      if (p !== "" && (Pass.currentDir === p || Pass.currentDir.indexOf(p + "/") === 0)) {
        let dir = Pass.currentDir
        while (dir !== "" && (dir === p || dir.indexOf(p + "/") === 0)) {
          const s = dir.lastIndexOf("/")
          dir = s === -1 ? "" : dir.substring(0, s)
        }
        Pass.browseTo(dir)
      }
      // The removed row's place hands over to the head landing: the
      // install below pins the bar before the write and glides it to
      // the head once motion re-arms, instead of snapping in one frame.
      panel._deleteGlide = true
      panel.rebuild()
    }
  }

  Connections {
    target: Pass.optimistic
    function onPendingChanged() { panel.rebuild() }
  }

  function viewKey() {
    if (panel.sub === "keys") return "keys"
    if (Pass.mode === "browse") return panel.browsePrefix + Pass.currentDir
    if (Pass.mode === "action")
      return panel.sub === "movepick" ? panel.pickPrefix + panel.moveDir : panel.actionPrefix + Pass.selectedPath
    if (Pass.mode === "create") return "create"
    return "menu"
  }

  function identityForRow(row) {
    if (!row) return ""
    const identity = row.path || row.dirPath
      || String(row.label || "") + "|" + String(row.sub || "")
    return String(row.kind || "") + "|" + identity
  }

  // The records the model shows: the panel's own row objects, each with its
  // identity stamped on as `uid`. A ScriptModel hands the delegate the whole
  // record, so the record has to BE the row rather than a wrapper beside it
  // - which also means the rows the view shows and the rows this panel
  // indexes are one array, not two that can disagree.
  //
  // This is also where the one refusal the keyed model's validate does not
  // make lives. A ScriptModel accepts a duplicate identity - four rows
  // in, four rows out, no error - and two live rows on one identity is the
  // failure List.qml cannot absorb: it refuses to measure either of them and
  // the height table degrades with nothing anywhere saying why. The panel
  // builds the rows, so the panel is where the check belongs, and returning
  // null (rather than a partial array) is what lets install() keep its
  // render-failed path for a page it cannot draw.
  function keyedRows() {
    const pool = panel.rowData
    const rows = new Array(pool.length)
    const seen = Object.create(null)
    for (let i = 0; i < pool.length; i++) {
      const row = pool[i]
      const uid = panel.identityForRow(row)
      if (uid === "" || seen[uid] !== undefined) return null
      seen[uid] = true
      row.uid = uid
      rows[i] = row
    }
    return rows
  }

  // Folder browser rows: create rows lead (green file, yellow folder -
  // the only tinted icons in the whole surface), then dirs, then files.
  // Move-pick shows a location note plus the full folder context so the
  // page never reads as a lone button.
  function vaultRows(dir, picking) {
    const r = []
    const ch = Model.childrenOf(Pass.entries, dir, Pass.allDirs)
    if (picking) {
      if (dir !== "")
        r.push({ kind: "up", label: "..", sub: "parent folder", icon: "arrow" })
      r.push({ kind: "move-here", label: "Move here", sub: dir === "" ? "/" : "/" + dir, icon: "check" })
      r.push({ kind: "delimiter" })
      for (let i = 0; i < ch.dirs.length; i++)
        r.push({ kind: "dir", label: ch.dirs[i], sub: panel.dirSub(panel.joinDir(dir, ch.dirs[i])), icon: "file-folder", name: ch.dirs[i], dirPath: panel.joinDir(dir, ch.dirs[i]) })
      for (let j = 0; j < ch.files.length; j++)
        r.push({ kind: "entry", label: ch.files[j].name, sub: ch.files[j].dir === "" ? "" : ch.files[j].path, icon: "lock", path: ch.files[j].path })
      return r.filter(row => String(row.kind || "") !== "dir" || !panel.isGone(row.dirPath || ""))
    }
    r.push({ kind: "create-password", label: "Create password", sub: "Create a new password here", icon: "file", iconColor: "green" })
    r.push({ kind: "create-folder", label: "Create folder", sub: "Create a new folder here", icon: "file-folder", iconColor: "yellow" })
    r.push({ kind: "delimiter" })
    for (let i = 0; i < ch.dirs.length; i++)
      r.push({ kind: "dir", label: ch.dirs[i], sub: panel.dirSub(panel.joinDir(dir, ch.dirs[i])), icon: "file-folder", name: ch.dirs[i], dirPath: panel.joinDir(dir, ch.dirs[i]) })
    for (let j = 0; j < ch.files.length; j++)
      r.push({ kind: "entry", label: ch.files[j].name, sub: ch.files[j].dir === "" ? "" : ch.files[j].path, icon: "lock", path: ch.files[j].path })
    if (ch.dirs.length === 0 && ch.files.length === 0)
      r.push({ kind: "note", label: "Empty folder", sub: "create something above", icon: "info" })
    return r.filter(row => String(row.kind || "") !== "dir" || !panel.isGone(row.dirPath || ""))
  }

  function matchRow(row) {
    const q = panel.filterText.toLowerCase()
    if (q === "") return true
    const hay = String(row.label || "") + " " + String(row.sub || "")
    return hay.toLowerCase().indexOf(q) !== -1
  }

  function clearQuery() {
    panel.filterText = ""
    searchField.text = ""
    panel.scopedFiltering = false
  }

  function beginPageFilter() {
    panel.scopedFiltering = true
    panel.filterText = ""
    searchField.text = ""
    panel.rebuild()
    focusCtrl.grabFilter()
  }

  function seedBrowseTarget(dir, path) {
    const target = String(path || "")
    if (target === "") return
    const key = panel.browsePrefix + String(dir || "")
    const rows = panel.vaultRows(String(dir || ""), false)
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]
      if (!row || String(row.path || row.dirPath || "") !== target) continue
      panel.frames.put(panel.frameOwner, key, {
        index: i,
        y: null,
        identity: panel.identityForRow(row)
      })
      return
    }
  }

  // True while the path is staged for deletion: dir rows hide at
  // once (no useful dimmed state), file rows keep the spec 49 dim.
  function isGone(path) {
    const p = String(path || "")
    return p !== "" && Pass.optimistic.isPending(p)
  }

  function rebuild() {
    const frameToken = panel.frames.begin(panel.frameOwner)
    // Package missing: no rows at all. The overlay owns the visual; an
    // empty model also makes every keyboard path (Enter, Delete, filter
    // activation) a no-op instead of reaching the pass-less machinery.
    if (panel.noPassBinary) {
      panel.baseCount = 0
      panel.rowData = []
      // The probe can land while the user is mid-typing in the filter:
      // pull focus back out so the dead box cannot keep the keyboard, and
      // drop the query so the field goes back to its placeholder. Without
      // this the box is dimmed but not dead: the text would keep the clear
      // button lit, which is a live control on a field nothing can type in.
      if (focusCtrl.mode === "filter" || searchField.focused) focusCtrl.grabList()
      if (panel.filterText !== "") panel.clearQuery()
      panel.syncRows(frameToken, true)
      return
    }
    let r = []
    if (!Pass.initialized) {
      if (panel.sub === "keys") {
        if (Pass.keyChoices.length === 0)
          r.push({ kind: "note", label: "No GPG keys found", sub: "create one with gpg --gen-key", icon: "warning" })
        for (let i = 0; i < Pass.keyChoices.length; i++)
          r.push({ kind: "key", label: Pass.keyChoices[i], sub: "use this key", icon: "key", key: Pass.keyChoices[i] })
      } else {
        r.push({ kind: "init", label: "Initialize a password store", sub: "pick a GPG key", icon: "key" })
      }
    } else if (panel.sub === "movepick") {
      r = panel.vaultRows(panel.moveDir, true)
    } else if (Pass.mode === "action") {
      const p = Pass.selectedPath
      r = [
        { kind: "action", action: "copy", label: "Copy", sub: p, icon: "copy" },
        { kind: "action", action: "edit", label: "Edit", sub: "open in terminal", icon: "tui" },
        { kind: "action", action: "move", label: "Move", sub: "pick a folder", icon: "arrow-corner" },
        { kind: "action", action: "rename", label: "Rename", sub: "same folder", icon: "pencil" },
      ]
    } else if (Pass.mode === "create") {
      r = [
        { kind: "method", method: "enter", label: "Enter password", sub: "type it once", icon: "key" },
        { kind: "method", method: "generate", label: "Generate password", sub: "random, copied at once", icon: "update" },
      ]
    } else if (Pass.mode === "browse" || Pass.mode === "menu") {
      if (Pass.mode === "browse") {
        r = panel.vaultRows(Pass.currentDir, false)
      } else {
        r.push({ kind: "vault", label: "Browse Vault", sub: Pass.entries.length + " entries", icon: "file-folders" })
        if (Pass.gitReady) {
          r.push({ kind: "push", label: "Push to remote", sub: "upload commits to origin", icon: "git" })
          r.push({ kind: "pull", label: "Pull from remote", sub: "fetch and rebase from origin", icon: "git" })
        }
      }
    }
    panel.baseCount = r.length
    if (panel.filterText === "") {
      panel.matchCount = r.length
      panel.rowData = r
    } else if (panel.filteringPage) {
      const hits = r.filter(row => row.kind !== "note" && row.kind !== "delimiter" && panel.matchRow(row))
      panel.matchCount = hits.length
      // No live note row on a miss: the empty model keeps keyboard paths
      // no-ops and the listBox EmptyState below paints the lock copy.
      panel.rowData = hits
    } else {
      const found = Model.searchVault(Pass.entries, Pass.allDirs, panel.filterText)
      const searched = []
      for (let i = 0; i < found.dirs.length; i++) {
        const dp = found.dirs[i]
        searched.push({ kind: "dir", label: dp.split("/").pop(), sub: dp, icon: "file-folder", name: dp.split("/").pop(), dirPath: dp })
      }
      for (let j = 0; j < found.entries.length; j++)
        searched.push({ kind: "entry", label: found.entries[j].name, sub: found.entries[j].path, icon: "lock", path: found.entries[j].path })
      const visible = searched.filter(row => String(row.kind || "") !== "dir" || !panel.isGone(row.dirPath || ""))
      panel.baseCount = Pass.entries.length + Pass.allDirs.length
      panel.matchCount = visible.length
      // Same: empty model, the overlay below owns the visual.
      panel.rowData = visible
    }
    panel.bakeEditor()
    panel.syncRows(frameToken, panel.filterText === "")
  }

  // Folds the open inline editor into the rebuilt rows by role, not by
  // stored index: refreshes and filters re-derive it, a view that no
  // longer holds the role drops it silently.
  function bakeEditor() {
    panel.editorIndex = -1
    if (panel.editorMode === "") return
    for (let i = 0; i < panel.rowData.length; i++) {
      const row = panel.rowData[i]
      if (!row) continue
      let hint = ""
      if (panel.editorMode === "create-name" && row.kind === "create-password") hint = "Password name"
      else if (panel.editorMode === "mkdir" && row.kind === "create-folder") hint = "Folder name"
      else if (panel.editorMode === "rename" && row.kind === "action" && row.action === "rename") hint = "New name"
      else continue
      panel.editorIndex = i
      row.editor = true
      row.editInitial = panel.editorInitial
      row.editHint = hint
      return
    }
    // Role gone (filtered out, view moved on) - drop the editor state.
    panel.closeEditor()
  }

  // A committed delete owns the next install's landing: the bar is
  // pinned on the removed row before the model write and glides to the
  // head once motion re-arms. Armed by onDeleteCommitted, spent by the
  // install below - never by navigation, which seats its own rows.
  property bool _deleteGlide: false
  // Release a delete-landing pin once the bar can travel: the stillness
  // lease (land seat) zeroes highlight motion, so releasing earlier
  // snaps instead of gliding. A wall-clock deadline, never a turn
  // budget - DeferredQueue turns drain several to a frame (menu parity).
  function _releaseDeletePinWhenLive() {
    const t0 = Date.now()
    const poll = () => {
      if (!Pass.visible) { list.unpinHighlight(); return }
      if (list.currentIndex !== 0 && list.currentIndex !== -1) { list.unpinHighlight(); return }
      if (Date.now() - t0 > 2000) { list.unpinHighlight(); return }
      if (list._inSwap || list._seatsInstant) {
        Idle.run(poll, 2)
        return
      }
      list.unpinHighlight()
    }
    Idle.run(poll, 2)
  }

  property bool _rowsPending: false
  property int _pendingFrameToken: -1
  property bool _pendingResumeTracking: false
  property bool _openSeat: false
  property int _swapGen: 0
  property int _pageTransitionGen: 0
  property string listError: ""

  function syncRows(frameToken, resumeTracking) {
    panel._pendingFrameToken = frameToken
    panel._pendingResumeTracking = resumeTracking === true
    if (panel._rowsPending) return
    panel._rowsPending = true
    Qt.callLater(() => {
      panel._rowsPending = false
      const frameToken = panel._pendingFrameToken
      const shouldResume = panel._pendingResumeTracking
      panel._pendingFrameToken = -1
      panel._pendingResumeTracking = false
      if (frameToken < 0) return

      panel._swapGen++
      const g = panel._swapGen
      const k = panel.viewKey()
      const openSeat = panel._openSeat === true
      // A seat change or a page turn. `values` is the only write a ScriptModel
      // has, so the swap window is the only thing this decides, and that half
      // is the load-bearing one: beginSwap() is what zeroes the highlight
      // duration,
      // stops the content tween and holds the selection bar's geometry
      // across the install, so a page turn plays as one page instead of as a
      // list re-sorting under its own slide.
      //
      // What a single write gives up: on a page turn
      // whose key set OVERLAPS the page it came from - browse -> move-pick
      // shares that folder's own dir and entry rows, and every page shares
      // the delimiter - a surviving delegate is reused rather than
      // destroyed and re-laid-out. Measured against the real List.qml the
      // reuse is invisible here: the only state PassEntry carries across an
      // install is _ready, closingEdit and _closeDone, and a reused row
      // already has _ready true while the rebake in onModelDataChanged
      // clears the other two. It is the reuse the in-page path has always
      // relied on. On a page turn with a DISJOINT key set the write is
      // indistinguishable from a full rebuild: measured, 5 delegates
      // destroyed and 4 born either way, through rowsRemoved/rowsInserted
      // and never a reset.
      const pageTurn = openSeat || panel.frames.activeKey !== k
      const editorFocus = panel.editorPendingFocus
        && panel.editorIndex >= 0 && panel.editorIndex < panel.rowData.length
      const useSwap = pageTurn || editorFocus
      if (openSeat) panel._openSeat = false

      const transitionGen = panel._pageTransitionGen

      const install = () => {
        const candidate = panel.keyedRows()
        if (candidate === null) {
          // The page transition is abandoned: a page that
          // could not install its rows has no slide to play, and leaving it
          // half-played would leave the list at x=48.
          panel.listError = "duplicate_identity"
          panel.resetPageTransition()
          return false
        }
        panel.listError = ""
        // A committed delete lands the head: freeze the bar on the row
        // being removed before the write. The pin hands over to the head
        // landing in land() below; anything off the head path goes live.
        // Skipped at the head: no travel, and nothing to freeze.
        const deleteGlide = panel._deleteGlide
        panel._deleteGlide = false
        if (deleteGlide && MotionPolicy.enabled && list.currentIndex > 0) list.pinHighlight()
        // The model's single write. `values` is the only write a ScriptModel
        // has and it refuses nothing, so there is no result to inspect and
        // no second verb to fall back from: the write lands, or the array
        // handed to it was not one - and keyedRows() above has already
        // answered the only question this panel's rows can get wrong.
        panel._rows = candidate
        // The identity epoch, advanced here and nowhere else: this is the
        // model's one write, so it is the only place a new key sequence can
        // appear. NUL separates the keys, and no row identity can hold one
        // (they are built from paths, fixed labels and a fixed vocabulary of
        // kinds), so the join cannot forge a boundary between two rows.
        const seq = candidate.map(r => r.uid).join("\u0000")
        if (seq !== panel._lastSeq) {
          panel._lastSeq = seq
          panel._epoch++
        }

        const saved = openSeat ? null : panel.frames.frameFor(panel.frameOwner, k)
        const hasFrame = saved !== null
        let idx = -1
        let restoreY
        if (hasFrame) {
          idx = saved.index
          if (typeof saved.y === "number") restoreY = saved.y
        } else if (Pass.mode === "browse" && panel.sub === "" && panel.filterText === "") {
          for (let i = 0; i < list.count; i++) {
            const row = panel.rowData[i]
            if (row && (row.kind === "dir" || row.kind === "entry") && panel.isSelectable(i)) {
              idx = i
              break
            }
          }
        }
        let seeded = hasFrame && saved.y === null
        if (panel.pendingSelectDir !== "") {
          const flag = panel.pendingSelectDir
          panel.pendingSelectDir = ""
          for (let i = 0; i < list.count; i++) {
            const row = panel.rowData[i]
            if (row && row.kind === "dir" && String(row.dirPath || "") === flag) {
              idx = i
              restoreY = undefined
              seeded = false
              break
            }
          }
        }

        const land = () => {
          if (idx < 0) {
            list.seat(-1, "land")
            if (list.count > 0) list.settle(0, true)
            if (openSeat) list.seatTo(0, false, "pass-open")
            return
          }
          list.seat(idx, "land")
          if (seeded) {
            list.reveal(idx, true)
          } else if (typeof restoreY === "number") {
            list.restoreAt(idx, restoreY)
          } else if (openSeat) {
            list.settle(0, true)
            list.seatTo(0, false, "pass-open")
          } else if (Pass.mode === "browse" && panel.sub === "" && panel.filterText === "") {
            if (idx > 0) {
              const d = list.itemAtIndex(idx)
              if (d && d.y < list.height) list.seatTo(0, false, "pass-landing")
              else list.reveal(idx, true)
            } else {
              list.settle(0, true)
            }
          } else {
            list.settle(0, true)
          }
          if (deleteGlide) {
            // The removed row is gone; its pinned place hands over to
            // the head landing once motion re-arms. Any other landing -
            // a restored seat, a reveal - goes live at once.
            if (list.currentIndex === 0) panel._releaseDeletePinWhenLive()
            else list.unpinHighlight()
          }
        }

        if (editorFocus) {
          panel.editorPendingFocus = false
          list.seat(panel.editorIndex, "land")
          list.autoRevealIndex = panel.editorIndex
          Qt.callLater(() => {
            if (g !== panel._swapGen) return
            const it = list.currentItem
            if (it && typeof it.focusEditor === "function") it.focusEditor()
          })
          if (deleteGlide) list.unpinHighlight()
          return true
        }

        land()
        return true
      }

      const queueCommit = () => {
        if (!shouldResume) return
        Idle.run(() => {
          if (g !== panel._swapGen) {
            if (panel._pageTransitionGen === transitionGen)
              panel.resetPageTransition()
            return
          }
          if (!panel.frames.commit(frameToken, k)) {
            if (panel._pageTransitionGen === transitionGen)
              panel.resetPageTransition()
          }
          // The commit is where the restore window closes, so this is
          // the first turn a namespace the transition outlived can go.
          panel.flushFrameDiscard()
        }, 2)
      }

      if (useSwap) {
        let installed = false
        list.swapRun(g, v => v === panel._swapGen, () => {
          installed = install()
        })
        if (installed) {
          queueCommit()
          if (!editorFocus && panel.editorMode === "" && !panel.secretOpen) focusCtrl.reassert()
        }
      } else if (install()) {
        queueCommit()
        if (panel.editorMode === "" && !panel.secretOpen) focusCtrl.reassert()
      }
    })
  }

  PanelFocus {
    id: focusCtrl
    searchField: searchField
    serviceVisible: Pass.visible
  }
  readonly property alias input: searchField.input
  function grabList() { focusCtrl.grabList() }
  function grabFilter() { focusCtrl.grabFilter() }
  function reassertFocus() { focusCtrl.reassert() }

  function currentRow() { return list.currentItem }

  function moveSelection(dir) {
    if (!list.move(dir)) return
    // Leaving the armed row closes its confirm dropdown.
    if (panel.deletePath !== "") {
      const cur = (list.currentIndex >= 0 && list.currentIndex < panel.rowData.length) ? panel.rowData[list.currentIndex] : null
      if (!cur || String(cur.path || cur.dirPath || "") !== panel.deletePath) panel.closeDelete()
    }
  }
  function scrollBy(factor) { list.pageBy(factor) }
  function jumpEnd(last) { list.jumpEnd(last) }

  function isSelectable(idx) {
    if (idx < 0 || idx >= panel.rowData.length) return false
    return panel.rowData[idx].kind !== "note" && panel.rowData[idx].kind !== "delimiter"
  }

  function activateAt(idx) {
    if (idx < 0 || idx >= panel.rowData.length) return
    if (!panel.isSelectable(idx)) return
    list.seat(idx, "click")
    panel.activateCurrent()
  }

  function joinDir(dir, name) {
    return dir === "" ? name : dir + "/" + name
  }

  // Folder size line for dir rows: recursive entry count, "empty"
  // for folders the entry scan cannot populate.
  function dirSub(dir) {
    const n = Model.countUnder(Pass.entries, dir)
    if (n <= 0) return "empty"
    return n === 1 ? "1 entry" : n + " entries"
  }

  function trimmed(text) {
    return String(text || "").replace(/^\s+/, "").replace(/\s+$/, "")
  }

  function targetExists(path) {
    const es = Pass.entries
    for (let i = 0; i < es.length; i++) {
      if (es[i] && es[i].path === path) return true
    }
    return false
  }

  function activateCurrent() {
    // An open editor swallows its own Enter; activating any row from
    // the list only cancels it, never double-fires.
    if (panel.editorMode !== "") { panel.cancelEditor(); return }
    // Trailing half of an editor commit (see _editorAcceptTick): the
    // row was already consumed, never re-run it in the same tick.
    if (panel._editorAcceptTick) return
    if (panel.deletePath !== "") {
      const cur = (list.currentIndex >= 0 && list.currentIndex < panel.rowData.length) ? panel.rowData[list.currentIndex] : null
      if (cur && String(cur.path || cur.dirPath || "") === panel.deletePath) { panel.acceptDelete(); return }
      panel.closeDelete()
    }
    let idx = list.currentIndex
    if (idx < 0 || idx >= panel.rowData.length) {
      if (panel.rowData.length === 0) return
      idx = -1
      for (let i = 0; i < panel.rowData.length; i++) {
        if (panel.isSelectable(i)) { idx = i; break }
      }
      if (idx === -1) return
      list.seat(idx, "click")
    }
    const r = panel.rowData[idx]
    if (!r || r.kind === "note") return
    const kind = String(r.kind)
    if (kind === "init") {
      panel.beginPageTransition(true, false)
      panel.sub = "keys"
      Pass.requestKeys()
      panel.rebuild()
      return
    }
    if (kind === "key") {
      Pass.initStore(String(r.key || ""))
      panel.sub = ""
      return
    }
    if (kind === "vault") {
      panel.beginPageTransition(true, false)
      panel.clearQuery()
      Pass.browseTo("")
      panel.rebuild()
      return
    }
    if (kind === "push") { Pass.push(); Pass.close(); return }
    if (kind === "pull") { Pass.pull(); Pass.close(); return }
    if (kind === "create-password") {
      panel.openEditor("create-name", "")
      return
    }
    if (kind === "create-folder") {
      panel.openEditor("mkdir", "")
      return
    }
    if (kind === "dir") {
      const next = String(r.dirPath || panel.joinDir(panel.sub === "movepick" ? panel.moveDir : Pass.currentDir, String(r.name || r.label)))
      panel.beginPageTransition(true, false)
      if (panel.sub !== "movepick" && panel.filterText !== "") {
        const parentSlash = next.lastIndexOf("/")
        const parentDir = parentSlash === -1 ? "" : next.substring(0, parentSlash)
        panel.seedBrowseTarget(parentDir, next)
      }
      panel.clearQuery()
      if (panel.sub === "movepick") panel.moveDir = next
      else Pass.browseTo(next)
      panel.rebuild()
      return
    }
    if (kind === "entry") {
      // In move-pick files are orientation context only.
      if (panel.sub === "movepick") return
      // Global hits land in context: seat the browser on the entry's
      // parent so Esc shows its folder, not the vault root.
      const full = String(r.path || "")
      const slash = full.lastIndexOf("/")
      const parentDir = slash === -1 ? "" : full.substring(0, slash)
      panel.beginPageTransition(true, false)
      if (panel.filterText !== "")
        panel.seedBrowseTarget(parentDir, full)
      panel.clearQuery()
      Pass.browseTo(parentDir)
      Pass.select(full)
      // The landing is a new view, not a filtered one: without this the
      // view-local filter below collapses the four actions to one Copy
      // row and a second Enter in the same tick copies (issue 66).
      panel.rebuild()
      return
    }
    if (kind === "up") { panel.moveUp(); return }
    if (kind === "move-here") {
      const base = Pass.selectedPath.split("/").pop()
      const destinationDir = panel.moveDir
      panel.beginPageTransition(false, true)
      const started = Pass.moveEntry(Pass.selectedPath, panel.joinDir(destinationDir, base))
      panel.discardFramePrefix(panel.pickPrefix)
      panel.clearQuery()
      panel.sub = ""
      if (started) Pass.browseTo(destinationDir)
      else Pass.mode = "browse"
      panel.rebuild()
      return
    }
    if (kind === "method") {
      panel.chooseMethod(String(r.method || ""))
      return
    }
    if (kind === "action") {
      panel.runAction(String(r.action || ""))
      return
    }
  }

  function runAction(action) {
    const p = Pass.selectedPath
    if (action === "copy") {
      Pass.copyEntry(p)
      Pass.close()
      return
    }
    if (action === "edit") {
      Pass.editEntry(p)
      Pass.close()
      return
    }
    if (action === "move") {
      panel.beginPageTransition(true, false)
      panel.clearQuery()
      panel.sub = "movepick"
      const slash = p.lastIndexOf("/")
      panel.moveDir = slash === -1 ? "" : p.substring(0, slash)
      panel.rebuild()
      return
    }
    if (action === "rename") {
      panel.openEditor("rename", p.split("/").pop())
      return
    }
  }

  function chooseMethod(method) {
    const target = panel.createTarget()
    if (target === "") return
    panel.clearQuery()
    if (method === "enter") {
      if (panel.pendingSecret !== "") {
        // Back on the armed overwrite: stage it like Delete, the next
        // activation past armed commits the stashed secret.
        if (panel.overwriteStage >= 2) {
          Pass.insertEntry(target, panel.pendingSecret, true)
          panel.resetCreate()
          Pass.close()
        } else {
          panel.overwriteStage++
        }
        return
      }
      panel.createMethod = "enter"
      panel.secretHint = "Secret for " + target
      secretBox.clear()
      panel.rebuild()
      Qt.callLater(() => secretBox.grabFocus())
      return
    }
    if (method === "generate") {
      if (panel.targetExists(target) && panel.overwriteStage < 2) {
        panel.createMethod = "generate"
        panel.overwriteStage++
        list.autoRevealIndex = list.currentIndex
        return
      }
      Pass.generateEntry(target, panel.targetExists(target))
      panel.resetCreate()
      Pass.close()
      return
    }
  }

  function createTarget() {
    if (panel.pendingName === "" || !Model.isValidName(panel.pendingName)) return ""
    return panel.joinDir(Pass.currentDir, panel.pendingName)
  }

  function resetCreate() {
    panel.createMethod = ""
    panel.secretHint = ""
    panel.pendingSecret = ""
    panel.pendingName = ""
    panel.overwriteStage = 0
    secretBox.clear()
  }

  function commitSecret(secret) {
    const s = String(secret || "")
    if (s === "") return
    const target = panel.createTarget()
    if (target === "") return
    if (panel.targetExists(target) && panel.overwriteStage < 2) {
      // Stash the secret and drop the overlay so the overwrite confirm
      // underneath is reachable; Esc still cancels all of it.
      panel.pendingSecret = s
      panel.overwriteStage++
      panel.rebuild()
      focusCtrl.grabList()
      return
    }
    Pass.insertEntry(target, s, panel.targetExists(target))
    panel.resetCreate()
    Pass.close()
  }

  // --- inline editor plumbing ---
  function openEditor(mode, initial) {
    panel.closeDelete()
    // A reopen inside a close window owns its own swap: the rebuild
    // rebakes the editor row, and the rebake drops the release the
    // cancelled close was holding (PassEntry onModelDataChanged).
    panel.editorMode = mode
    panel.editorInitial = String(initial || "")
    panel.editorPendingFocus = true
    panel.rebuild()
  }
  function closeEditor() {
    panel.editorIndex = -1
    panel.editorMode = ""
    panel.editorInitial = ""
    panel.editorPendingFocus = false
    // Pursuit never self-clears (ui/List): a stale index keeps
    // the 16ms timer running against later reveal()/settle().
    list.autoRevealIndex = -1
  }
  function cancelEditor() {
    panel.settleEditorClose()
    focusCtrl.grabList()
  }

  // The rebuild the close owes: the swap that drops the editor role from
  // the rows. It runs from the row's close-completion signal, so the row
  // stays alive through its close Glide and a close slower than any
  // easing length is never cut short.
  function commitEditorClose() {
    // The swap resets currentIndex to the top before the
    // correction lands (spec 67 mirror): hold highlight motion
    // across the swap window, restore right after.
    panel._swapGen++
    const g = panel._swapGen
    list.swapRun(g, v => v === panel._swapGen, () => {
      panel.rebuild()
    })
  }
  // Owns the closeEditor state clear: callers drop theirs.
  function settleEditorClose() {
    // The index dies with closeEditor: capture the live editor
    // row first. Null (scrolled out of cache) means nothing
    // visible to animate - swap at once instead.
    const idx = panel.editorIndex
    const it = idx >= 0 ? list.itemAtIndex(idx) : null
    panel.closeEditor()
    if (it && typeof it.beginClose === "function") {
      // The row runs its own close and calls back when the slot's
      // close has landed; a row with nothing to animate releases
      // inside beginClose.
      it.beginClose(panel.commitEditorClose)
    } else {
      // Same swap-tick freeze as commitEditorClose: instant
      // correction, no top-visit painted.
      panel.commitEditorClose()
    }
  }
  function flashEditor() {
    const it = list.currentItem
    if (it && typeof it.flashInvalid === "function") it.flashInvalid()
  }

  function editorAccepted(text) {
    const name = panel.trimmed(text)
    if (panel.editorMode === "create-name") {
      if (!Model.isValidName(text)) { panel.flashEditor(); return }
      panel.beginPageTransition(true, false)
      panel.pendingName = name
      panel._editorAcceptTick = true
      Qt.callLater(() => panel._editorAcceptTick = false)
      // The picker below never filters (see rebuild): arriving with a
      // stale query would only confuse the next browse landing.
      panel.clearQuery()
      Pass.mode = "create"
      panel.settleEditorClose()
      return
    }
    if (panel.editorMode === "mkdir") {
      if (!Model.isValidName(text)) { panel.flashEditor(); return }
      const dir = panel.joinDir(Pass.currentDir, name)
      panel._editorAcceptTick = true
      Qt.callLater(() => panel._editorAcceptTick = false)
      // Creation only, no teleport: the folder appears in place once
      // the dirs probe returns.
      Pass.createFolder(dir)
      panel.pendingSelectDir = dir
      panel.settleEditorClose()
      return
    }
    if (panel.editorMode === "rename") {
      if (!Model.isValidName(text)) { panel.flashEditor(); return }
      const p = Pass.selectedPath
      const slash = p.lastIndexOf("/")
      const dest = slash === -1 ? name : p.substring(0, slash) + "/" + name
      if (dest === p) { panel.cancelEditor(); return }
      if (panel.targetExists(dest)) { panel.flashEditor(); return }
      panel.beginPageTransition(false, true)
      panel._editorAcceptTick = true
      Qt.callLater(() => panel._editorAcceptTick = false)
      Pass.moveEntry(p, dest)
      panel.clearQuery()
      Pass.mode = "browse"
      panel.settleEditorClose()
    }
  }

  function editorCancelled() {
    panel.cancelEditor()
  }

  // Package guard: every flow in this panel funnels through the `pass`
  // binary, so a missing package makes the whole surface useless. Row
  // guards (dim rows, dead actions) would only move the problem around:
  // this overlay replaces the content entirely while it is up.
  readonly property bool noPassBinary: Pass.passBinary === "missing"

  function closeDelete() {
    panel.deletePath = ""
    panel.deleteStage = 0
    panel.deleteIsDir = false
    list.autoRevealIndex = -1
  }

  // The vault path the delete flow may act on: the row under the cursor
  // when that row is a vault folder or an entry, "" when there is nothing
  // removable under the cursor. One answer for the key arming and for the
  // flow itself, so the two cannot disagree about what Delete may do.
  //
  // The move picker is excluded: its rows are places, not things to
  // delete. Every other page's rows (actions, methods, menu entries) fail
  // the kind test on their own. A vault-wide search shows the same folder
  // and entry rows the browser does, so a row found by searching deletes
  // exactly like the one found by browsing to it.
  function deleteTarget() {
    if (panel.sub === "movepick") return ""
    const idx = list.currentIndex
    const r = idx >= 0 && idx < panel.rowData.length ? panel.rowData[idx] : null
    if (!r) return ""
    const kind = String(r.kind || "")
    if (kind !== "dir" && kind !== "entry") return ""
    return String(r.path || r.dirPath || "")
  }

  // Whether the destructive keys may act on the row under the cursor. The
  // filter field arms them from this, so with nothing removable under the
  // cursor Delete keeps editing the query instead of being swallowed -
  // launcher parity (LauncherPanel.deleteKeyAvailable).
  readonly property bool deleteKeyAvailable: panel.deleteTarget() !== ""

  function toggleDeleteCurrent() {
    const idx = list.currentIndex
    const p = panel.deleteTarget()
    if (p === "") { panel.closeDelete(); return }
    const r = panel.rowData[idx]
    const isDir = String(r.kind || "") === "dir"
    if (panel.deletePath === p) {
      if (panel.deleteStage >= 2) { panel.acceptDelete(); return }
      panel.deleteStage++
      list.autoRevealIndex = idx
      return
    }
    panel.deletePath = p
    panel.deleteIsDir = isDir
    panel.deleteStage = 1
    list.autoRevealIndex = idx
  }

  function acceptDelete() {
    const p = panel.deletePath
    panel.closeDelete()
    if (p === "") return
    // Buffered in the service (request -> commit -> settled); the row
    // stays until the commit lands.
    Pass.requestDelete(p)
    panel.rebuild()
  }

  function cancelMovePicker() {
    panel.beginPageTransition(false, false)
    panel.discardFramePrefix(panel.pickPrefix)
    panel.clearQuery()
    panel.sub = ""
    panel.moveDir = ""
    panel.rebuild()
  }

  function moveUp() {
    panel.beginPageTransition(false, true)
    panel.clearQuery()
    if (panel.moveDir !== "") {
      const s = panel.moveDir.lastIndexOf("/")
      panel.moveDir = s === -1 ? "" : panel.moveDir.substring(0, s)
    } else {
      panel.sub = ""
    }
    panel.rebuild()
  }

  // Esc peels exactly one layer; there are no Back rows anywhere.
  function escapeChain() {
    if (panel.editorMode !== "") { panel.cancelEditor(); return }
    if (panel.overwriteStage > 0) {
      panel.overwriteStage = 0
      panel.pendingSecret = ""
      panel.rebuild()
      return
    }
    if (panel.deletePath !== "") { panel.closeDelete(); return }
    if (panel.scopedFiltering) {
      if (focusCtrl.mode === "filter" && searchField.text !== "") {
        focusCtrl.grabList()
        return
      }
      panel.clearQuery()
      panel.rebuild()
      focusCtrl.grabList()
      return
    }
    if (panel.filterText !== "") {
      panel.clearQuery()
      panel.rebuild()
      focusCtrl.grabList()
      return
    }
    if (focusCtrl.mode === "filter") {
      focusCtrl.grabList()
      return
    }
    if (panel.sub === "movepick") {
      panel.cancelMovePicker()
      return
    }
    if (panel.sub === "keys") {
      panel.beginPageTransition(false, true)
      panel.sub = ""
      panel.rebuild()
      return
    }
    if (Pass.mode === "create") {
      panel.beginPageTransition(false, true)
      panel.resetCreate()
      Pass.back()
      panel.rebuild()
      return
    }
    if (Pass.mode === "action" || Pass.mode === "browse") {
      panel.beginPageTransition(false, true)
      Pass.back()
      panel.rebuild()
      return
    }
    Pass.close()
  }

  function handleKey(event) {
    const k = event.key
    const ctrl = event.modifiers & Qt.ControlModifier
    const meta = event.modifiers & Qt.MetaModifier

    if (k === Qt.Key_Escape) { panel.escapeChain(); event.accepted = true; return }
    // Package missing: the panel is display-only. Escape (above) still
    // closes it; every other key dies here so the typing-feeds-filter
    // block, Ctrl+F and Backspace can never focus the dead filter.
    if (panel.noPassBinary) { event.accepted = true; return }
    // While a field owns the keyboard the list shortcuts stand down. Tab
    // and Backtab still have to be swallowed on the way out: unaccepted they
    // are precisely the keys Qt's focus chain acts on, so Shift+Tab walked
    // out of an open "Create password" field and into the filter bar above
    // it, stranding a half-typed name in a box that commits nothing. Same
    // treatment the menu gives an open editor (MenuLib keyRoute -> swallow).
    // Every other key belongs to the field and is left to reach it.
    if (panel.editing) {
      if (k === Qt.Key_Tab || k === Qt.Key_Backtab) event.accepted = true
      return
    }

    // Delete/Ctrl-D stage the delete on the row under the cursor. The
    // filter field takes the same two keys ahead of its own editing while
    // such a row is under the cursor (see deleteKeys), so the key works
    // from the field as well as from the list - launcher parity.
    if ((k === Qt.Key_D && ctrl) || k === Qt.Key_Delete) {
      panel.toggleDeleteCurrent()
      event.accepted = true
      return
    }
    if (k === Qt.Key_F && ctrl) { panel.beginPageFilter(); event.accepted = true; return }
    // "/" focuses the filter like the other menus' prefix habit.
    if (k === Qt.Key_Slash && !ctrl && !meta) { panel.beginPageFilter(); event.accepted = true; return }

    switch (k) {
      case Qt.Key_Down:
      case Qt.Key_Tab:
        panel.moveSelection(1); event.accepted = true; return
      case Qt.Key_Up:
      case Qt.Key_Backtab:
        panel.moveSelection(-1); event.accepted = true; return
      case Qt.Key_PageUp: panel.scrollBy(-0.8); event.accepted = true; return
      case Qt.Key_PageDown: panel.scrollBy(0.8); event.accepted = true; return
      case Qt.Key_Home: panel.jumpEnd(false); event.accepted = true; return
      case Qt.Key_End: panel.jumpEnd(true); event.accepted = true; return
      case Qt.Key_Return:
      case Qt.Key_Enter:
        // `focused`, not `activeFocus`: InputField is a wrapper Rectangle and
        // the focus lives on the inner TextField it exposes as `focused`, so
        // `activeFocus` on the wrapper is permanently false and this guard
        // never stood down.
        if (searchField.focused) return
        panel.activateCurrent(); event.accepted = true; return
      case Qt.Key_Backspace:
        // The way back, not the filter trigger - matching MenuLib.keyRoute.
        // With the field active the caret has the key (and an empty field
        // escapes through onBackspaceEmpty, below); with it inactive this
        // walks the same chain Escape walks.
        if (searchField.focused) return
        panel.escapeChain(); event.accepted = true; return
      case Qt.Key_Space:
        if (searchField.focused) return
        panel.activateCurrent(); event.accepted = true; return
    }

    // List-first typing feeds the filter, launcher parity.
    if (!ctrl && !meta && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
      panel.scopedFiltering = !panel.vaultSearchable
      panel.filterText = event.text
      searchField.text = event.text
      focusCtrl.grabFilter()
      panel.rebuild()
      event.accepted = true
      return
    }
  }

  Keys.onPressed: event => panel.handleKey(event)

  // --- top filter bar spans full width, launcher geometry ---
  // In the warning state the input stays visible but dead: dimmed under
  // the overlay backdrop, clicks eaten by the overlay MouseArea.
  Item {
    id: filterBar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.hPad
    anchors.rightMargin: panel.hPad
    anchors.topMargin: panel.vPad
    height: panel.filterH

    InputField {
      id: searchField
      anchors.fill: parent
      implicitHeight: panel.filterH
      basePadding: Ui.l
      focusColor: Ui.solid("accent")
      placeholder: panel.filteringPage ? "Filter..." : "Search..."
      inputRole: panel.filteringPage ? "filter" : "search"
      filterIconAlways: panel.filteringPage
      clearable: false
      // No counter in the warning state: the rows it would count are gone,
      // so "0/0" is a number about a list that is not there, dimmed under
      // the overlay next to a package that is not installed.
      counterVisible: !panel.noPassBinary
      counterMatched: panel.matchCount
      counterTotal: panel.baseCount
      // The native text control consumes Delete/Ctrl-D before a Keys handler
      // can see them; the field takes them ahead of editing while a
      // removable row is under the cursor - launcher parity. With nothing
      // removable under the cursor Delete keeps editing the query.
      deleteKeys: panel.deleteKeyAvailable
      onEdited: text => {
        panel.filterText = text
        panel.rebuild()
      }
      onAccepted: text => panel.activateCurrent()
      onEscaped: panel.escapeChain()
      onBackspaceEmpty: panel.escapeChain()
      onDeleteRequested: panel.toggleDeleteCurrent()
    }
  }

  function resetPageTransition() {
    panel._pageTransitionGen++
    pageAnim.stop()
    pageShift.x = 0
    listBox.opacity = 1
  }

  function playPageTransition(forward) {
    panel._pageTransitionGen++
    pageAnim.stop()
    if (!Pass.visible || !MotionPolicy.enabled) {
      panel.resetPageTransition()
      return
    }
    pageShift.x = forward ? 48 : -48
    listBox.opacity = 0
    pageX.from = pageShift.x
    pageFade.from = 0
    pageAnim.restart()
  }

  function beginPageTransition(forward, forgetSource) {
    panel.frames.begin(panel.frameOwner, forgetSource === true)
    panel.playPageTransition(forward)
  }

  // Cleanup for a namespace the running transition has already left. A
  // live restore token pins the frame of the key the transition is still
  // anchored on, so the removal is retried from the commit that closes
  // the window; nothing reads a frame for a namespace the panel has left
  // (viewKey() has moved on), which is what makes the deferral invisible.
  function discardFramePrefix(prefix) {
    const p = String(prefix || "")
    if (p === "") return
    panel._discardPrefix = p
    panel.flushFrameDiscard()
  }

  function flushFrameDiscard() {
    const p = panel._discardPrefix
    if (p === "") return
    if (panel.frames.tokenLive) return
    panel._discardPrefix = ""
    panel.frames.forgetPrefix(panel.frameOwner, p)
  }

  Item {
    id: listBox
    anchors.top: filterBar.bottom
    anchors.topMargin: panel.listTopGap
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: panel.hPad
    anchors.rightMargin: panel.hPad
    // Explicit height like LauncherPanel (never stretched): the card
    // formula assumes exactly this stack, so top and bottom breathe
    // evenly. PanelCard accounts for the status reserve in its height.
    height: Math.max(0, panel.listRegionH)

    transform: Translate { id: pageShift; x: 0 }

    ParallelAnimation {
      id: pageAnim

      NumberAnimation {
        id: pageX
        target: pageShift
        property: "x"
        to: 0
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: pageFade
        target: listBox
        property: "opacity"
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    List {
      id: list
      anchors.fill: parent
      model: listModel
      // Center-lock scrolloff: keyboard steps keep the cursor riding
      // the viewport middle while scrolling is possible (menu parity).
      // Steps ease while animations run, jump while off.
      centerCursor: true
      smoothScroll: MotionPolicy.enabled
      // Cursor-row gate (menu parity): the bar snaps only while the
      // focused row stages delete/editor (tracks it 1:1); a staged row
      // left behind must not freeze the bar mid-move.
      highlightMotion: MotionPolicy.enabled && !cursorSlotOpen
      // True while the cursor row itself stages a delete confirm or an
      // inline editor (model-level reads, synchronous with the index).
      readonly property bool cursorSlotOpen: {
        const idx = list.currentIndex
        if (idx < 0) return false
        if (panel.editorMode !== "" && idx === panel.editorIndex) return true
        if (panel.deletePath === "") return false
        const row = idx >= 0 && idx < panel.rowData.length ? panel.rowData[idx] : null
        return row ? String(row.path || row.dirPath || "") === panel.deletePath : false
      }
      // The row's own identity, read off the record the model holds. The
      // `?? index` fallback is what keeps a row renderable and measurable
      // when the lookup comes back empty; measured, an out-of-range index
      // and a record with no uid both land there.
      rowIdentity: index => String(listModel.values[index]?.uid ?? index)
      // Identity epoch for the height table: advances only when a sync
      // changed the key sequence, so a payload-only change keeps the
      // measured heights and a key-set change prunes the rows the new
      // key set no longer claims. A ScriptModel has no key-set flag and no
      // revision, so panel.identityRevision is the counter - see its
      // declaration for why it is a counter and not the sequence.
      identityRevision: panel.identityRevision
      isSelectable: idx => panel.isSelectable(idx)
      // Never learn while a delete confirm or inline editor is open: the
      // open row is slot-inflated (phantom scroll on short views).
      measureGuard: idx => panel.deletePath === "" && panel.editorMode === ""
      autoRevealIndex: -1

      delegate: PassEntry {
        // The record is the row, so this reads the same two fields the row
        // always carried, off `modelData` rather than off a wrapper role.
        deleteOpen: panel.deletePath !== "" && modelData
          && (modelData.path || modelData.dirPath || "") === panel.deletePath
        deleteStage: panel.deleteStage
        deleteIsFolder: panel.deleteIsDir
        onActivated: () => panel.activateAt(index)
        onDeleteConfirm: () => panel.acceptDelete()
        onEditorAccepted: text => panel.editorAccepted(text)
        onEditorCancelled: () => panel.editorCancelled()
      }
    }

    // Filter/search with no hits: the mode glyph over the copy
    // (library-wide EmptyState, bar-island pattern): filtering ->
    // filter-x + "No matches", searching -> search-alert + "No results",
    // same pair as the menus. No live note row: an empty model keeps
    // keyboard paths no-ops.
    EmptyState {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - 32)
      visible: list.count === 0 && panel.filterText !== "" && !panel.noPassBinary && !panel.secretOpen
      text: panel.filteringPage ? "No matches" : "No results"
      iconName: panel.filteringPage ? "filter-x" : "search-alert"
      iconColorKey: "foreground_1"
      iconAccentKey: "red"
    }

    // Overwrite guard floats over the list bottom: hint -> armed ->
    // confirm with stages 2, same ConfirmSlot as delete.
    ConfirmSlot {
      id: overwriteSlot
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      open: panel.overwriteStage > 0
      stage: panel.overwriteStage
      confirmText: "Overwrite"
      hintText: "Entry exists - press to overwrite"
      armedText: "<b><u>Press again to confirm overwrite</u></b>"
      onConfirmed: {
        if (panel.overwriteStage >= 2) {
          if (panel.createMethod === "enter") {
            const target = panel.createTarget()
            if (target !== "" && panel.pendingSecret !== "") {
              Pass.insertEntry(target, panel.pendingSecret, true)
              panel.resetCreate()
              Pass.close()
            }
          } else if (panel.createMethod === "generate") {
            const target = panel.createTarget()
            if (target !== "") {
              Pass.generateEntry(target, true)
              panel.resetCreate()
              Pass.close()
            }
          }
        } else {
          panel.overwriteStage++
        }
      }
    }

    // Secret entry: masked InputField (the shared sensitive mode), the
    // only field on screen while it is up. Clicks land back on it so
    // typing can never leak into the filter behind the overlay.
    Rectangle {
      id: secretOverlay
      anchors.fill: parent
      visible: panel.secretOpen
      color: Ui.solid("background_0")
      opacity: 0.97

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: secretBox.grabFocus()
      }

      Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 340)
        spacing: Ui.m

        Text {
          width: parent.width
          text: panel.secretHint
          color: Ui.tint("foreground_1", 0.7)
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
          elide: Text.ElideRight
          horizontalAlignment: Text.AlignHCenter
        }

        InputField {
          id: secretBox
          width: parent.width
          sensitive: true
          placeholder: "SECRET"
          onAccepted: text => panel.commitSecret(text)
          onEscaped: panel.escapeChain()
        }

        Text {
          width: parent.width
          text: "Enter confirms - Esc cancels"
          color: Ui.tint("foreground_1", 0.45)
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // Package-missing warning: dim backdrop over the whole card, big
  // centered warning glyph with generic text under it (the
  // ArchUpdates/Printers island pattern, sized up for the menu card).
  // The glyph and text stay full-strength on top of the dim, like the
  // islands; the backdrop eats every click so the dead list underneath
  // never receives input.
  Item {
    id: noPassOverlay

    // Fills the whole card so the dim reaches the dead filter box too;
    // the warning column itself centers in the body region below the
    // input (see warnCol).
    anchors.fill: parent
    visible: panel.noPassBinary

    Rectangle {
      anchors.fill: parent
      color: Ui.tint("background_0", 0.62)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
    }

    Column {
      id: warnCol

      // Horizontal card center; vertically centered in the body region
      // (listBox, below the dimmed input), floored at the region top.
      // Explicit y binding - a Column cannot anchor to its uncle.
      anchors.horizontalCenter: parent.horizontalCenter
      y: listBox.y + Math.max(0, (listBox.height - warnCol.height) / 2)
      width: Math.min(parent.width - 32, 340)
      spacing: 10

      Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        name: "warning"
        colorKey: "red"
        size: 56
      }

      Title {
        level: 3
        width: parent.width
        text: "The pass package is not installed"
        color: Ui.tint("foreground_1", 0.6)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Title {
        level: 5
        width: parent.width
        // "pass" picks up the theme accent via StyledText markup; the
        // rest of the line stays at the level-5 muted tone.
        textFormat: Text.StyledText
        text: "Install <b><font color=\"" + Ui.solid("accent") + "\">pass</font></b> to manage your password store"
        color: Ui.tint("foreground_1", 0.45)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  Text {
    id: statusLine
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: panel.hPad
    anchors.rightMargin: panel.hPad
    anchors.bottomMargin: panel.vPad
    // Errors only: a busy line would have nothing to report - with a resident
    // controller the vault is warm in the first frame, so a busy line could
    // only ever report the background re-probe, which needs no announcement.
    visible: Pass.lastError !== ""
    // Collapsed by hand: a height binding off implicitHeight loops on
    // anchor layout, so visibility flips set the height imperatively.
    // Single-line elided text keeps one constant line height, so reading
    // implicitHeight here is always exact.
    height: 0
    onVisibleChanged: {
      statusLine.height = statusLine.visible ? statusLine.implicitHeight : 0
    }
    text: Pass.lastError
    color: Theme.color("red")
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    elide: Text.ElideRight
  }
}

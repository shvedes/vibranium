pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import "DownloadsLib.js" as DL
import "../../../../common/motion/Marquee.js" as Marquee
import "../../../../common/collections/TableSort.js" as TableSort

// Downloader island: preview, URL field and the format table. The table is
// the ArchUpdates package table with one change - single selection, so there
// is no checkbox and no select-all; the chosen row names the format the
// download will use.
//
// The table never changes height. Its model is at least `_rowWindow` rows
// long (live formats plus fillers) and a blank table stands those rows as
// skeleton bars which the real content dissolves into through
// `_skeletonMix`, so a fetch never recreates the delegates or swaps one
// picture for another in a single frame.
Item {
  id: root

  property int islandContentWidth: 380
  // Content-sized like the shipped islands: the card pads by Ui.outerPad on
  // every side, so the live body height plus two pads leaves a real gap
  // below the action row instead of clipping it against the card border.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  // IslandHost owns this card's one height clock: its Glide (OutCubic,
  // Ui.resizeMs) tweens card.height while sectionSwap snaps straight to its
  // destination, so all three block opacity crossfades ride a single resize
  // curve - the same arrangement as the other islands. Self-animating (the old
  // Stage 4 arrangement) disabled the host Glide and left only sectionSwap's
  // default-Linear NumberAnimation, which read as a linear grow and a shrink
  // that did not animate at all.
  property bool islandSelfAnimating: false
  property var islandHost: null
  readonly property bool blockedNavKeys: urlField.focused
  // Arrows and Enter walk the format table. The list answers moveBy() and
  // the host router gates them on `blockedNavKeys` while the URL field has
  // the keyboard.
  property var islandNavTarget: formatList

  property bool downloading: false
  // yt-dlp itself, as opposed to the wrapper around it. The module asks the
  // CLI; without the tool no fetch can run, so the body becomes the install
  // prompt instead of a table nothing can fill.
  property bool toolMissing: false
  property var probeTool: null
  // Playlist entries and which of them are ticked. A playlist is a queue of
  // videos, so the table lists the entries and the primary action downloads
  // the ticked ones in order.
  property var playlist: []
  // The playlist's own name: what the preview calls it and the folder the
  // batch downloads into. The entries are videos; the name is the collection.
  property string playlistTitle: ""
  property var plChecked: []
  // The batch's quality choice: a playlist has no format table, so the choice
  // is made once for the ticked entries (see DL.qualityOptions).
  property string plQuality: "best"
  // Audio batches embed the thumbnail by default; the checkbox under the
  // quality chips makes that an explicit choice instead of a silent extra.
  property bool plEmbedThumbnail: true
  property var loadPlaylist: null
  property var startPlaylist: null
  // Progress of the queue the module is walking, for the line above the table.
  property int queueDone: 0
  property int queueTotal: 0
  // The load the last finished download used, owned by the module so the answer
  // survives this island being closed.
  property string lastLoadUrl: ""
  // The file the last successful run wrote, from the module. A file-mode run
  // keeps a green completion box instead of dropping its only evidence on the
  // frame the progress line disappears.
  property string lastSavedPath: ""
  // The last link this island itself filled from the clipboard, so the same
  // clipboard does not refetch on every open.
  property string lastAutoUrl: ""
  // The link the clipboard is offering, if any. The empty pane's click is the
  // paste affordance, so the pane is only a live target while this names a
  // link: an empty clipboard must not read as a suggestion.
  readonly property string _clipboardUrl: DL.clipboardLink(
    String(Quickshell.clipboardText || ""))
  property var noteAutoLoaded: null
  // Set when a download starts from this island: the load it used is spent, so
  // it must not be remembered again (see persist()). A failure clears it, so a
  // retry still reopens with the link in place.
  property bool _loadSpent: false
  property string lastError: ""
  property var startDownload: null
  property var loadInfo: null
  property var loadPreview: null
  property var requestPreview: null
  property var releasePreview: null
  property var cancelDownload: null
  // The card's own mirror of the error line. A cancellation is not a state
  // worth keeping, so the notice keeps a copy and clears it after a fade once
  // the next action answers it.
  property string _noticeText: ""
  // The same slot carries an error, a cancellation and a finished file; the
  // tone is what tells them apart at a glance.
  property string _noticeTone: "danger"
  property bool _noticeFading: false
  readonly property bool _noticeIsCancel: root._noticeText === DL.cancelMessage()
  readonly property bool _noticeIsSuccess: root._noticeTone === "success"
  // The unknown-link warning is a suggestion to pick a chip, not a failure.
  // Keeping it as one string lets a chip answer it without guessing from the
  // last error text. The classifier's raw reason stays out of the copy.
  readonly property string _classifyWarning: "Could not tell what this link is."
    + " Choose Video or File."
  // What a running job took from the card: begin() empties the pick and the
  // ticks so no second job can be staged. A cancel hands them back, so the
  // table is ready to run again instead of sitting inert.
  property string _pendingFormat: ""
  property var _pendingTicks: []
  // The module's error slot is its own; the card asks it to clear a line
  // rather than writing a property it is bound to.
  property var clearError: null
  property var reloadHistory: null
  property var forgetHistory: null
  property var clearHistory: null

  property string format: ""
  property var formats: []
  // What the dispatcher decided about the link, and who was asked to fetch it.
  // `tool` is the user's choice: auto asks the classifier, while an explicit
  // value skips it and forces that engine. `fileMode` swaps the format table
  // for a direct-file card.
  property var classify: null
  property string kind: "unknown"
  property string engine: ""
  property string classifyReason: ""
  property string tool: "auto"
  property bool classifying: false
  // A manual Video fetch that yt-dlp refused as an unsupported link. The
  // warning names Auto/File instead of leaving an empty table as the answer.
  property bool mediaMismatch: false
  readonly property bool fileMode: root.kind === "file"
  readonly property string effectiveTool: root.tool !== "auto" ? root.tool
    : (root.engine !== "" ? root.engine : "auto")
  // Which column the table is ordered by, and which way. Best quality first is
  // what the table opens on; the headers cycle it (see TableSort).
  property string sortKey: "resolution"
  property string sortDir: "desc"
  property var history: []
  // Which recent entry a click staged in the URL field. A row is a pointer to
  // a video, not a request for its formats: the fetch belongs to the Fetch
  // button (see the action row), not to the click.
  property int _histPick: -1
  // The staged row still names what the field carries: typing over the field
  // drops the staging with it, so Refresh never acts on a stale pick.
  readonly property bool _histPicked: root._histPick >= 0
    && root._histPick < root.history.length && root.history[root._histPick]
    && DL.urlKey(root.history[root._histPick].url) === DL.urlKey(urlField.text)
  // Paths from `history` whose file the module found gone. The list still
  // loads that video by URL; the row says the file it names is not there.
  property var missingFiles: []
  property string previewTitle: ""
  // The pane under the pointer: a loaded preview wears a wash that says it
  // is one surface, the way the now-playing artwork does.
  property bool previewHover: false
  // What the overlay prints: a playlist says so, because the title alone
  // reads like a single video.
  readonly property string previewText: {
    // A playlist is named by itself, not by whichever entry a flat listing
    // happens to report first: a watch link carrying `list=` extracts one
    // video, so the preview's own title is the first video's title.
    if (root.playlist.length > 0 && root.playlistTitle !== "")
      return "[Playlist] " + root.playlistTitle
    if (root.previewTitle === "") return ""
    return (root.playlist.length > 0 ? "[Playlist] " : "") + root.previewTitle
  }
  property string previewUrl: ""
  property bool loadingInfo: false
  // A preview is still pending until its frame is painted: the title and the
  // listing land first, the thumbnail always last, so the card keeps the image
  // glyph and its breathe until the image itself is there.
  readonly property bool _previewFetching: root.loadingInfo
    || (root.previewUrl !== "" && previewImage.status !== Image.Ready
      && previewImage.status !== Image.Error)
  // Every fetch carries the epoch it started in: a Clear bumps it, so a reply
  // that was already in flight when the island was emptied lands nowhere.
  property int _fetchEpoch: 0

  // Every model write (history, formats, playlist, table sort) bumps this
  // epoch. A deferred cursor seat or scroll landing retires itself when it
  // wakes up in a newer epoch, so an older intent cannot unseat the row a
  // newer table just claimed (invariant 5).
  property int _seatEpoch: 0

  // The module owns the runtime art warmer because this island is torn down
  // on close. Demand the visible URL, release it on close: that is the whole
  // lifetime of the cached pixmap.
  property string _demandedPreview: ""
  function _syncPreviewDemand() {
    if (root._demandedPreview !== "" && root._demandedPreview !== root.previewUrl) {
      if (typeof root.releasePreview === "function")
        root.releasePreview(root._demandedPreview)
      root._demandedPreview = ""
    }
    if (root.previewUrl !== "" && root._demandedPreview !== root.previewUrl) {
      if (typeof root.requestPreview === "function"
        && root.requestPreview(root.previewUrl))
        root._demandedPreview = root.previewUrl
    }
  }
  onPreviewUrlChanged: root._syncPreviewDemand()

  // Whether a Clear would actually remove something: the field, a table, a
  // preview, an error. The island's first phase is none of those, and the
  // button greys out there rather than promising an action it cannot take.
  readonly property bool _dirty: urlField.text.trim() !== ""
    || root.formats.length > 0 || root.previewTitle !== ""
    || root._noticeText !== ""

  // The pole's stripe tile: one accent diagonal drawn as an inline SVG over
  // the track's brightened fill, so the motion is a sliding image and not a
  // shader. The tile width is the stripe period - wide bands, few of them -
  // and a slide of exactly one tile is a seamless loop.
  //
  // The stripes run past the tile's corners on purpose: a line whose ends sit
  // inside the box is capped there, and the caps read as lozenges cut off
  // midway instead of bands crossing the pole. With the ends outside, only the
  // box edges cut them, and the neighbouring tile continues each band.
  readonly property int _poleTile: 16
  readonly property string _poleSource: {
    const ink = String(Theme.color("accent") || "")
    if (ink === "") return ""
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 6">'
      + '<g stroke="' + ink + '" stroke-width="6">'
      + '<path d="M-10 12L26 -9.6"/><path d="M6 12L42 -9.6"/></g></svg>'
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg)
  }

  // What the last visit loaded. The island is transient - the module builds a
  // new one on every open - so the data is handed in on construction and
  // handed back after every change, and the module drops it once a download
  // actually happened.
  property string initialUrl: ""
  property var initialFormats: []
  // The playlist entries the last visit loaded, so a reopen is the same table
  // instead of another trip to the CLI.
  property var initialPlaylist: []
  property string initialPlaylistTitle: ""
  // The ticks that went with those entries: a narrowed selection is part of
  // the load, not a preference to recreate on the next open.
  property var initialPlChecked: []
  property var initialPreview: null
  property string initialFormat: ""
  property string initialTool: "auto"
  property string initialKind: "unknown"
  property string initialReason: ""
  property string initialEngine: ""
  property var remember: null
  // The table's ordering outlives the island like the loaded session does,
  // but it is a preference rather than part of the load.
  property string initialSortKey: ""
  property string initialSortDir: ""
  property var rememberSort: null

  // Formats of the URL in the field that are already on disk. The history
  // names one format id per download, matched through a key the CLI's
  // normalized spelling and what was typed both answer. Entries whose file is
  // gone are left out: they are a memory, not a copy on disk.
  readonly property var _doneIds: DL.downloadedFormats(root.history,
    urlField.text, root.missingFiles)

  // The playlist entries whose video is already on disk. The tick is the
  // queue's selection, so an entry we already hold is drawn ticked but is not
  // part of it: the row is a fact, not a pick. A deleted or moved copy is not
  // held, so that entry stays selectable for a fresh download.
  readonly property var _historyKeys: DL.downloadedKeys(root.history,
    root.missingFiles)

  function playlistHave(index) {
    const entry = root.playlist[index]
    if (!entry) return false
    const key = DL.urlKey(entry.url)
    return key !== "" && root._historyKeys.indexOf(key) >= 0
  }

  readonly property int plHaveCount: {
    let n = 0
    for (let i = 0; i < root.playlist.length; i++) {
      if (root.playlistHave(i)) n++
    }
    return n
  }

  // What the header tick and the batch button count: the entries still to be
  // fetched, already-held ones subtracted.
  readonly property int plTickable: root.playlist.length - root.plHaveCount
  readonly property bool _pickedDownloaded: root.format !== ""
    && root._doneIds.indexOf(String(root.format)) >= 0
  // The file that copy landed as. The green button opens it instead of
  // downloading the same capture twice; "" means there is nothing to open.
  readonly property string _openPath: DL.downloadedPath(root.history,
    urlField.text, root.format, root.missingFiles)

  // Ticked playlist entries. Recomputed whenever the ticks change, which is
  // what the button's count and its inert state read.
  readonly property int plCount: {
    let n = 0
    for (let i = 0; i < root.playlist.length; i++) {
      if (root.plChecked[i] === true) n++
    }
    return n
  }

  // --- format table -----------------------------------------------------
  //
  // Rows the table shows at once. The list's model is at least this long -
  // live formats plus fillers below - so the table keeps one footprint
  // whether it is loading, populated or idle.
  readonly property int _rowWindow: 7
  // Sorted, then padded. The ordering is a projection of the fetch, so a
  // header click re-orders what is already loaded instead of refetching.
  readonly property var _sorted: DL.sortFormats(root.formats, root.sortKey,
    root.sortDir)
  readonly property var _rows: DL.rowWindow(root._sorted, root._rowWindow)
  // Recent is a fixed seven-row window. The model itself stops at seven, so
  // entries past it create no delegates and cannot be reached by any gesture.
  readonly property var _historyRows: DL.rowWindow(
    root.history.slice(0, root._rowWindow), root._rowWindow)
  // Placeholder switch: there is nothing to show yet, so every row stands as
  // a skeleton bar. The handover from blank to live is a dissolve of
  // `_skeletonMix`, not a model swap.
  readonly property bool _blank: root.formats.length === 0
  // Idle, with nothing in the field: the general recent list. The same table
  // carries media and direct-file rows, and it stays for an empty history so
  // the idle card keeps one footprint instead of falling back to the format
  // skeleton. A failed fetch with a URL still shows the format table; the
  // error above explains that state.
  readonly property bool _historyEmpty: root.history.length === 0
  readonly property bool _showHistory: root._blank && !root.loadingInfo
    && root.playlist.length === 0 && !root.fileMode
    && (root.history.length > 0 || urlField.text.trim() === "")
  // The empty recent pane speaks for every engine: a video and a direct file
  // are the same kind of row here.
  readonly property string _historyEmptyIcon: "download-alt"
  readonly property string _historyEmptyText: "Downloads will appear here"
  property real _skeletonMix: root._blank ? 1 : 0
  Behavior on _skeletonMix {
    enabled: MotionPolicy.enabled
    Glide { duration: Ui.normalMs }
  }

  // Row geometry shared by the header and the delegates so the columns line
  // up: [inset] RESOLUTION | A/V | SIZE [scrollbar gutter]. The gutter is
  // reserved in the row chrome because the bar overlays the viewport edge,
  // so the SIZE column never runs underneath it.
  readonly property real _rowInset: Ui.s
  readonly property real _gap: 6
  readonly property real _vBarGutter: 6
  // Rows are plates, not a stack: an accent band flush against the row below
  // reads as one tall block, so neighbouring rows keep their distance.
  readonly property real _rowH: 20
  readonly property real _rowGap: 2
  readonly property real _rowChrome: 2 * root._rowInset + 2 * root._gap + root._vBarGutter
  readonly property real _tableW: root.islandContentWidth - 2 * Ui.outerPad
  // The table's own chrome: two insets, the scrollbar gutter and the FOUR
  // gaps between five columns. (`_rowChrome` counts two gaps because the
  // library's width arithmetic assumes the old three-column row; using it
  // here left the size column twenty-four pixels past the scrollbar gutter.)
  readonly property real _tableChrome: 2 * root._rowInset + root._vBarGutter
    + 4 * root._gap
  // The resolution column takes whatever the measured columns leave over; it
  // is the one column a person picks by.
  readonly property real resColW: Math.max(40,
    root._tableW - root._tableChrome - root.fpsColW - root.extColW
      - root.kindColW - root.sizeColW)
  // Exact content height of the padded window, gaps included, so the capped
  // viewport ends on a whole row instead of clipping one in half.
  readonly property real tableCapH: root._rowWindow * root._rowH
    + (root._rowWindow - 1) * root._rowGap
  // The remove rail beside the history list: one chip per row, on the card
  // ground instead of inside the row (or inside the scrolling list). A whole
  // row tall, so each chip lines up with the band it removes; a little wider
  // than that, which is the room the glyph gets without pulling the rows apart.
  readonly property real _deleteSlotW: 24
  // The playlist's length column: hours fit too ("1:12:04"), since entries
  // carry whatever yt-dlp reports.
  readonly property real plDurationW: 56
  readonly property real _histBandW: root._tableW - root._deleteSlotW - root._gap
  readonly property real histTitleW: Math.max(48,
    root._histBandW - (2 * root._rowInset + root._gap) - root.sizeColW)

  // Measured column widths, so a long size string never eats the primary
  // column. The measuring is imperative and stays here; the arithmetic that
  // turns the measurements into the two bounded widths is the library's.
  property real fpsColW: 20
  property real extColW: 32
  property real kindColW: 32
  property real sizeColW: 46
  readonly property real _sizeCap: 96
  TextMetrics {
    id: tm

    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    font.bold: false
  }

  function measureTable() {
    const rows = root.formats
    tm.font.bold = true
    tm.text = "FPS"
    let fw = tm.width
    tm.text = "FORMAT"
    let ew = tm.width
    tm.text = "A/V"
    let kw = tm.width
    tm.text = "SIZE"
    let sw = tm.width
    tm.font.bold = false
    for (let i = 0; i < rows.length; i++) {
      tm.text = DL.fpsLabel(rows[i])
      if (tm.width > fw) fw = tm.width
      tm.text = DL.extLabel(rows[i])
      if (tm.width > ew) ew = tm.width
      tm.text = DL.kindLabel(rows[i])
      if (tm.width > kw) kw = tm.width
      tm.text = DL.cellLabel(DL.sizeLabel(rows[i].size))
      if (tm.width > sw) sw = tm.width
    }
    // History rows share the size column, and their sizes are different
    // strings ("39.0 MiB" from raw bytes), so the visible window is measured
    // too. Rows outside it can never be shown, so they do not size a column.
    const hist = root.history.slice(0, root._rowWindow)
    for (let h = 0; h < hist.length; h++) {
      tm.text = DL.cellLabel(DL.sizeLabel(hist[h].size))
      if (tm.width > sw) sw = tm.width
    }
    root.fpsColW = Math.ceil(fw) + 2
    root.extColW = Math.min(64, Math.ceil(ew) + 2)
    const cols = DL.formatColumns(kw, sw, root._tableW, root._rowChrome,
      { minKind: 32, minSize: 46, sizeCap: root._sizeCap })
    root.kindColW = cols.kind
    root.sizeColW = cols.size
  }

  // A model that grows from empty makes the view seat row 0 on its own, so a
  // freshly loaded table paints a cursor band on the first format before
  // anyone picked one. Put the cursor where the pick is - on the picked row,
  // or nowhere when nothing is picked - once the view has adopted the rows.
  function settleCursor() {
    if (root.format !== "") {
      const rows = root._rows
      for (let i = 0; i < rows.length; i++) {
        if (!DL.isFiller(rows[i]) && String(rows[i].id || "") === root.format) {
          if (formatList.currentIndex !== i) formatList.seat(i, "land")
          return
        }
      }
    }
    if (formatList.currentIndex !== -1) formatList.seat(-1, "land")
  }

  // A re-order rewrites every row's position, so the cursor - an index into
  // the old order - is dropped, and the table is read from the top again.
  // seatTo is the list's only scroll writer: a direct contentY write would be
  // overwritten in the same turn by the offset the model swap preserves, and
  // the view would land back where it was scrolled to. The deferred repeat
  // catches the swap's own restore retries, and is retired by a newer model
  // write rather than scrolling a newer table to the top.
  function landTop() {
    formatList.seatTo(0, false, "sort")
  }

  // A header click on a new column starts ascending; on the sorted column it
  // flips. The order is a preference, so it is handed back to outlive the
  // island. The epoch is retired here (not in a list handler) because a sort
  // rewrites formatList's model without touching root.formats.
  function toggleSort(key) {
    root._seatEpoch++
    root.sortDir = TableSort.nextDirection(root.sortKey, root.sortDir, key)
    root.sortKey = key
    if (formatList.currentIndex !== -1) formatList.seat(-1, "land")
    root.landTop()
    const epoch = root._seatEpoch
    Qt.callLater(() => {
      if (epoch === root._seatEpoch) root.landTop()
    })
    if (typeof root.rememberSort === "function")
      root.rememberSort(root.sortKey, root.sortDir)
  }

  // The size column is shared with the history table, so a change there can
  // move it too. The view seats row 0 during the model assignment itself;
  // histList.onModelChanged parks it again in that same synchronous edge, so
  // no frame paints a band on a row nobody pointed at (Q14). The one guarded
  // deferral covers only the view's own placement retry after the swap; a
  // newer history write retires it before it can unseat anything.
  onHistoryChanged: {
    root._seatEpoch++
    root.measureTable()
    const epoch = root._seatEpoch
    Qt.callLater(() => {
      if (epoch === root._seatEpoch && histList.currentIndex !== -1)
        histList.seat(-1, "land")
    })
  }

  onLastErrorChanged: {
    if (root.lastError === "") {
      // The module cleared the line itself (a new run, a Clear): it goes at
      // once, unless the fade is already carrying it out.
      if (!root._noticeFading) root._noticeText = ""
      return
    }
    root._noticeFading = false
    root._noticeTone = "danger"
    noticeFade.stop()
    root._noticeText = root.lastError
  }

  // A finished or cancelled job rewrites the history, so the idle table and
  // the already-downloaded marks follow it without a reopen. A job that failed
  // or was cancelled leaves the load worth reopening; one that finished spent
  // it, and the module has already dropped the session.
  onDownloadingChanged: {
    if (root.downloading) return
    if (root.lastError !== "") root._loadSpent = false
    root.refresh()
    // A cancel hands back what the job took - after the re-read, so the
    // entries it already landed count as held and stay out of the ticks.
    if (root.lastError === DL.cancelMessage()) root.restorePending()
    else {
      root._pendingFormat = ""
      root._pendingTicks = []
      // A successful file run has no format table whose already-downloaded
      // state would say so. Keep the answer in the notice slot, green.
      if (root.fileMode && root._loadSpent && root.lastSavedPath !== "")
        root.showFileSaved(root.lastSavedPath)
    }
  }

  // The playlist list seats row 0 on its own when its model arrives, so a
  // freshly listed playlist would open with a focused band on the first entry.
  // Ticks are the selection here; plList.onModelChanged parks the cursor in
  // the model's own synchronous edge, and the guarded deferral covers the
  // view's later placement retry (retired by a newer playlist write).
  onPlaylistChanged: {
    root._seatEpoch++
    const epoch = root._seatEpoch
    Qt.callLater(() => {
      if (epoch === root._seatEpoch && plList.currentIndex !== -1)
        plList.seat(-1, "land")
    })
  }

  onFormatsChanged: {
    root._seatEpoch++
    root.measureTable()
    // The keyboard cursor is an index into the previous row set. A new set
    // makes index 0 name a different format, so unseat synchronously rather
    // than leave the cursor band on a row nobody pointed at; formatList's
    // onModelChanged repeats the unseat after the view's own index-0 seat.
    if (formatList.currentIndex !== -1) formatList.seat(-1, "land")
    // A fresh table is read from its first row. The remembered pick still
    // gets its cursor, but seating it must not drag the view down to it: a
    // reopened island shows the rows in the remembered order, from the top.
    // This single deferred landing is epoch-guarded: a newer fetch retires
    // it instead of letting a stale pick seat itself in the newer table.
    const epoch = root._seatEpoch
    Qt.callLater(() => {
      if (epoch !== root._seatEpoch) return
      root.settleCursor()
      root.landTop()
    })
  }

  function pickIndex(index) {
    root.dismissNotice()
    const row = root._rows[index]
    // A running job owns the selection: its rows are not picks until it ends.
    if (root.downloading || DL.isFiller(row)) return
    root.format = String(row.id || "")
    root.persist()
  }

  // The fetched row the picked id names. The download asks it what to fetch:
  // a video-only row needs its audio merged in (see DL.downloadSelector).
  function pickedRow() {
    const rows = root.formats
    for (let i = 0; i < rows.length; i++) {
      if (String(rows[i] && rows[i].id || "") === root.format) return rows[i]
    }
    return null
  }

  function persist() {
    if (typeof root.remember !== "function") return
    // A spent load is not a session. The module forgets it when the download
    // lands, and this gate is what keeps a pick, a late fetch reply or the
    // start itself from writing it back into the next open.
    if (root._loadSpent) return
    root.remember(urlField.text.trim(), root.formats,
      ({ title: root.previewTitle, thumbnail: root.previewUrl }), root.format,
      root.playlist, root.playlistTitle, root.plChecked, root.tool, root.kind,
      root.classifyReason, root.engine)
  }

  function refresh() {
    if (typeof root.reloadHistory !== "function") return
    // The history file is append-ordered, so the newest line is its last one.
    // The table reads newest first, which is what "recent" promises.
    root.history = root.reloadHistory().slice().reverse()
  }

  // A history row is a URL that worked once: clicking it stages that URL for
  // another load instead of asking for a paste. The fetch itself is one press
  // away - the Refresh button becomes Fetch while a row is staged - because
  // pointing at a row is not the same as asking to fetch it again.
  function selectHistory(index) {
    root.dismissNotice()
    root.mediaMismatch = false
    const row = root.history[index]
    if (root.downloading || !row || !row.url) return
    // A row remembers the engine that wrote it. A file row reopens in file
    // mode with that engine selected; a media row stays on Auto so the next
    // fetch re-classifies rather than trusting an old format id.
    if (DL.isFileHistory(row)) {
      root.tool = DL.historyEngine(row)
      root.kind = "file"
      root.engine = root.tool
      root.classifyReason = "history"
      root.formats = []
      root.previewTitle = DL.fileName(row.url)
      root.previewUrl = ""
    } else {
      root.tool = "auto"
      root.kind = "media"
      root.engine = "yt-dlp"
      root.classifyReason = "history"
    }
    root._histPick = index
    urlField.text = String(row.url)
    root.persist()
    urlField.forceActiveFocus()
  }

  // Clear in the Recent table wipes the history the CLI owns; the rows come
  // back from its re-read, so the table ends up saying what the file does.
  function wipeHistory() {
    root.dismissNotice()
    if (typeof root.clearHistory !== "function") return
    root.clearHistory(rows => {
      root.history = (rows || []).slice().reverse()
      root._histPick = -1
    })
  }

  // Removing an entry rewrites the history file in the CLI, which owns its
  // format. The rows come back from a re-read rather than being spliced here.
  function requestDelete(index) {
    root.dismissNotice()
    if (typeof root.forgetHistory !== "function") return
    // The rail's index is a display row; the CLI deletes by file line, and the
    // two run in opposite directions.
    const line = root.history.length - 1 - index
    root.forgetHistory(line, rows => { root.history = rows.slice().reverse() })
  }

  function restore() {
    if (root.initialUrl === "") return
    root.mediaMismatch = false
    urlField.text = root.initialUrl
    root.tool = root.initialTool || "auto"
    root.kind = root.initialKind || "unknown"
    root.engine = root.initialEngine || ""
    root.classifyReason = root.initialReason || ""
    if (root.tool === "wget" || root.tool === "aria2c") {
      root.kind = "file"
      root.engine = root.tool
    }
    if (root.kind === "file" && root.previewTitle === "")
      root.previewTitle = DL.fileName(root.initialUrl)
    root.formats = root.initialFormats || []
    root.playlist = root.initialPlaylist || []
    root.playlistTitle = root.initialPlaylistTitle || ""
    if (root.playlist.length > 0) {
      // The ticks are part of the load: a playlist somebody narrowed down is
      // still that selection on the next open, not the whole list again.
      const kept = root.initialPlChecked || []
      const ticks = []
      if (kept.length === root.playlist.length) {
        for (let i = 0; i < kept.length; i++) ticks.push(kept[i] === true)
      } else {
        for (let i = 0; i < root.playlist.length; i++) ticks.push(true)
      }
      // An entry already in the history is drawn ticked but never queued, so
      // the remembered selection cannot put it back in a batch.
      for (let i = 0; i < ticks.length; i++) {
        if (root.playlistHave(i)) ticks[i] = false
      }
      root.plChecked = ticks
    }
    if (root.initialPreview) {
      root.previewTitle = root.initialPreview.title || ""
      root.previewUrl = root.initialPreview.thumbnail || ""
    }
    // A remembered pick only stands while the format it named is still in the
    // list the CLI reports today.
    const rows = root.formats
    for (let i = 0; i < rows.length; i++) {
      if (String(rows[i].id || "") === root.initialFormat) {
        root.format = root.initialFormat
        break
      }
    }
  }

  function restoreSort() {
    if (root.initialSortKey !== "") root.sortKey = root.initialSortKey
    if (root.initialSortDir === "asc" || root.initialSortDir === "desc")
      root.sortDir = root.initialSortDir
  }

  // An error line is not a state the card should keep: the next thing the
  // person does answers a cancellation, so it leaves with a fade instead of
  // standing until a Clear. A failure keeps its line - it still explains
  // something nobody has dealt with yet.
  function dismissNotice() {
    // Picking a chip answers the unknown-link suggestion, so that warning goes
    // immediately rather than waiting for a fetch or a fade.
    if (root._noticeText === root._classifyWarning) {
      noticeFade.stop()
      root._noticeText = ""
      root._noticeFading = false
      return
    }
    if ((!root._noticeIsCancel && !root._noticeIsSuccess)
      || root._noticeText === "") return
    // The fade flag goes first: clearing the module's line makes the binding
    // arrive empty, and that edge must not drop the text before the fade.
    root._noticeFading = true
    if (typeof root.clearError === "function") root.clearError()
    if (!MotionPolicy.enabled) {
      root._noticeText = ""
      root._noticeFading = false
      return
    }
    noticeFade.restart()
  }

  // A cancel gives back what begin() took: the pick, or the ticks the batch
  // was about to run, so the card reads as ready for the same job again
  // instead of as an inert table. Entries the batch already landed are held,
  // so they stay out of the selection.
  // The completion box a file download leaves behind. It is deliberately the
  // same slot and shape as a cancellation, only green: the file's evidence
  // must survive a run short enough to miss the progress line.
  function showFileSaved(path) {
    const name = DL.savedName(path)
    root._noticeFading = false
    noticeFade.stop()
    root._noticeTone = "success"
    root._noticeText = name !== "" ? "Downloaded " + name : "File downloaded"
  }

  function restorePending() {
    if (root._pendingFormat !== "" && root.format === "") {
      const rows = root.formats
      for (let i = 0; i < rows.length; i++) {
        if (String(rows[i] && rows[i].id || "") === root._pendingFormat) {
          root.format = root._pendingFormat
          break
        }
      }
    }
    const kept = root._pendingTicks
    if (kept.length > 0 && kept.length === root.playlist.length) {
      const ticks = []
      for (let i = 0; i < root.playlist.length; i++) {
        ticks.push(root.playlistHave(i) ? false : kept[i] === true)
      }
      root.plChecked = ticks
    }
    root._pendingFormat = ""
    root._pendingTicks = []
  }

  // The preview names the link in the field, so its click is the browse
  // action: the page opens in the default browser, nothing downloads, and
  // the field keeps the link it already carries.
  function openPreviewLink() {
    const url = urlField.text.trim()
    if (url === "") return
    Exec.run(["xdg-open", url])
  }

  // Opening the island reads the clipboard: a link to a mainstream host is
  // filled in and fetched, anything else is left alone. A remembered load
  // outranks the clipboard, so this is only reached on a fresh island.
  //
  // This is the ONE paste path. The pane click, the open-time auto-load and
  // Ctrl+V all call it, so clipboardLink validation, the last-load / last-auto
  // dedupe, the _pasteTrying stand-down, the auto-load note and the fetch all
  // agree no matter which gesture asked (ISL-3).
  function pasteFromClipboard() {
    // Opening the card while a job runs is not a request to replace that job.
    if (root.downloading) return true
    const url = DL.clipboardLink(String(Quickshell.clipboardText || ""))
    if (url === "") return false
    // The link that was just downloaded is usually still what the clipboard
    // holds. Reopening after a download means the initial phase, not a refetch
    // of what is already on disk; answered as handled so the retry stands down.
    if (root.lastLoadUrl !== ""
      && DL.urlKey(url) === DL.urlKey(root.lastLoadUrl)) {
      root._pasteTrying = false
      return true
    }
    // Same rule for the link this island already auto-loaded: the clipboard
    // still holding it is not a new intent.
    if (root.lastAutoUrl !== ""
      && DL.urlKey(url) === DL.urlKey(root.lastAutoUrl)) {
      root._pasteTrying = false
      return true
    }
    urlField.text = url
    root._pasteTrying = false
    if (typeof root.noteAutoLoaded === "function") root.noteAutoLoaded(url)
    root.fetchAll()
    return true
  }

  // One-shot arm for the open-time clipboard race. `Quickshell.clipboardText`
  // is a real notifying property, so the retry is released by its signal, not
  // by a 160 ms wall-clock guess (Q15). The timer below is a bounded window
  // for that race and only DISARMS - it never performs a speculative read.
  property bool _pasteTrying: false

  Connections {
    target: Quickshell

    function onClipboardTextChanged() {
      if (!root._pasteTrying) return
      // A typed or pasted field is a newer intent than the clipboard race.
      if (urlField.text.trim() !== "") {
        root._pasteTrying = false
        return
      }
      // pasteFromClipboard() clears the arm on a handled link or a dedupe;
      // a non-link change leaves it armed for the next real clipboard edge.
      root.pasteFromClipboard()
    }
  }

  Timer {
    id: pasteWaitDeadline

    // The former pasteRetry budget (160 ms x 4), now a grace window for the
    // clipboard-owner race rather than a readiness poll: no callback reads
    // the clipboard, it only ends the wait when no signal ever arrived.
    interval: 640
    repeat: false
    running: root._pasteTrying
    onTriggered: root._pasteTrying = false
  }

  function fetchAll() {
    // A running job owns the card. Refresh/Enter must not clear the load or
    // start a second classifier underneath the download that is already busy.
    if (root.downloading) return
    root.dismissNotice()
    // The staging is spent the moment a fetch starts, whatever it returns.
    root._histPick = -1
    const url = urlField.text.trim()
    const epoch = ++root._fetchEpoch
    // A fetch is a fresh load, whatever the last download did.
    root._loadSpent = false
    root.formats = []
    root.format = ""
    root.playlist = []
    root.plChecked = []
    root.previewTitle = ""
    root.previewUrl = ""
    root.classifying = false
    root.mediaMismatch = false
    if (url === "") {
      root.loadingInfo = false
      return
    }

    const loadMedia = () => {
      root.loadingInfo = true
      if (DL.isPlaylistUrl(url)) {
        // A playlist is listed, not extracted: the flat listing names every
        // entry without touching the videos themselves.
        if (typeof root.loadPlaylist === "function") {
          root.loadPlaylist(url, (entries, title) => {
            if (epoch !== root._fetchEpoch) return
            root.playlist = entries
            root.playlistTitle = title || ""
            const ticks = []
            for (let i = 0; i < entries.length; i++)
              ticks.push(!root.playlistHave(i))
            root.plChecked = ticks
            root.loadingInfo = false
            if (entries.length === 0) {
              root._noticeTone = "danger"
              root._noticeText = "Could not read the playlist"
            }
            root.persist()
          })
        } else {
          root.loadingInfo = false
        }
      } else if (typeof root.loadInfo === "function") {
        root.loadInfo(url, (rows, error) => {
          if (epoch !== root._fetchEpoch) return
          root.formats = rows
          root.loadingInfo = false
          root.mediaMismatch = root.tool === "yt-dlp" && rows.length === 0
            && DL.videoUnsupported(error)
          root.persist()
        })
      } else {
        root.loadingInfo = false
      }
      if (typeof root.loadPreview === "function") {
        root.loadPreview(url, info => {
          if (epoch !== root._fetchEpoch) return
          root.previewTitle = info && info.title || ""
          root.previewUrl = info && info.thumbnail || ""
          root.persist()
        })
      }
    }

    // An explicit tool is the answer: no classifier, no Node process.
    if (root.tool !== "auto") {
      root.kind = root.tool === "yt-dlp" ? "media" : "file"
      root.engine = root.tool
      root.classifyReason = "chosen"
      if (root.kind === "file") {
        root.loadingInfo = false
        root.previewTitle = DL.fileName(url)
        root.persist()
        return
      }
      loadMedia()
      return
    }

    if (typeof root.classify !== "function") {
      root.loadingInfo = false
      root._noticeTone = "danger"
      root._noticeText = "Could not classify the link"
      return
    }
    root.classifying = true
    root.loadingInfo = true
    root.classify(url, info => {
      if (epoch !== root._fetchEpoch) return
      const verdict = info || {}
      root.classifying = false
      root.kind = String(verdict.kind || "unknown")
      root.engine = String(verdict.engine || "")
      root.classifyReason = String(verdict.reason || "")
      if (root.kind === "file") {
        // A file has no format table and no thumbnail: the filename is the
        // whole preview, and the download button is live without a pick.
        root.loadingInfo = false
        root.previewTitle = DL.fileName(url)
        root.previewUrl = ""
        root.persist()
        return
      }
      if (root.kind !== "media") {
        root.loadingInfo = false
        root._noticeTone = "danger"
        root._noticeText = root._classifyWarning
        root.persist()
        return
      }
      loadMedia()
    })
  }

  // A tool chip. Auto returns to classification; Video and File pin the
  // engine and refetch the field, so the table or the file card follows.
  function chooseTool(tool) {
    root.dismissNotice()
    if (root.downloading || root.classifying) return
    root.mediaMismatch = false
    root.tool = String(tool || "auto")
    if (root.tool === "auto") {
      root.kind = "unknown"
      root.engine = ""
      root.classifyReason = ""
    } else if (root.tool === "yt-dlp") {
      root.kind = "media"
      root.engine = "yt-dlp"
      root.classifyReason = "chosen"
    } else {
      root.kind = "file"
      root.engine = root.tool
      root.classifyReason = "chosen"
    }
    root.fetchAll()
  }

  // Clear: back to the island's first phase. The field empties, the table and
  // its pick go, the preview and any error go, and the session is forgotten so
  // a reopen starts here too instead of restoring what was just cleared.
  function clearAll() {
    root._fetchEpoch++
    root._loadSpent = false
    urlField.text = ""
    root.formats = []
    root.format = ""
    // A playlist is part of the loaded card too: clearing only the field and
    // the format table left its entries on screen, with no way to act on them.
    root.playlist = []
    root.playlistTitle = ""
    root.plChecked = []
    root._pendingFormat = ""
    root._pendingTicks = []
    root._histPick = -1
    root.previewTitle = ""
    root.previewUrl = ""
    root._noticeText = ""
    root._noticeTone = "danger"
    root._noticeFading = false
    if (typeof root.clearError === "function") root.clearError()
    root.loadingInfo = false
    root.mediaMismatch = false
    root.tool = "auto"
    root.kind = "unknown"
    root.engine = ""
    root.classifyReason = ""
    root.classifying = false
    root.persist()
    formatList.currentIndex = -1
    body.forceActiveFocus()
  }

  // Ticking an entry. The array is replaced rather than mutated so the rows
  // and the count re-read it.
  function togglePlaylist(index) {
    root.dismissNotice()
    if (root.downloading || index < 0 || index >= root.playlist.length) return
    // An entry already on disk is not a choice.
    if (root.playlistHave(index)) return
    const next = root.plChecked.slice()
    while (next.length < root.playlist.length) next.push(false)
    next[index] = next[index] !== true
    root.plChecked = next
  }

  // One ticked entry is a single video, whatever it came from: drop the batch
  // and load that URL the way the field would, so the format table - not the
  // batch cap - picks the capture.
  function loadSolo(url) {
    if (root.downloading) return
    root.playlist = []
    root.plChecked = []
    root.playlistTitle = ""
    urlField.text = String(url)
    root.fetchAll()
    urlField.forceActiveFocus()
  }

  // The header tick: all of the entries still to be fetched when any is off,
  // none when all are on. Entries already held stay out of the selection.
  function togglePlaylistAll() {
    root.dismissNotice()
    if (root.downloading || root.playlist.length === 0) return
    const tick = root.plCount < root.plTickable
    const next = []
    for (let i = 0; i < root.playlist.length; i++) {
      next.push(root.playlistHave(i) ? false : tick)
    }
    root.plChecked = next
  }

  function begin() {
    if (root.downloading) return
    root.dismissNotice()
    // A direct file has no pick: the fetch is one engine run with the
    // filename the dispatcher resolves.
    if (root.fileMode) {
      const fileUrl = urlField.text.trim()
      if (fileUrl === "" || typeof root.startDownload !== "function") return
      if (root.startDownload(fileUrl, "", root.effectiveTool) === false) return
      root._pendingFormat = ""
      root._pendingTicks = []
      root._loadSpent = true
      return
    }
    // A playlist is the queue: the ticked entries go in order, and the ticks
    // clear as it starts.
    if (root.playlist.length > 0) {
      const urls = []
      for (let i = 0; i < root.playlist.length; i++) {
        if (root.plChecked[i] === true) urls.push(String(root.playlist[i].url))
      }
      if (urls.length === 0) return
      // One video is not a batch: it opens in the island's regular mode with
      // its own format table, so the capture is the video's real one rather
      // than a batch cap.
      if (urls.length === 1) {
        root.loadSolo(urls[0])
        return
      }
      if (typeof root.startPlaylist !== "function") return
      const selector = DL.qualitySelector(root.plQuality)
      if (root.startPlaylist(urls, urlField.text.trim(), selector,
        root.playlistTitle, DL.qualityLabel(root.plQuality), "yt-dlp",
        root.plQuality === "audio" && root.plEmbedThumbnail) === false) return
      // What the batch took, so a cancel can hand it back.
      root._pendingTicks = root.plChecked.slice()
      root._pendingFormat = ""
      root._loadSpent = true
      root.plChecked = root.plChecked.map(() => false)
      return
    }
    const url = urlField.text.trim()
    if (url === "" || root.format === "") return
    // A format already on disk is not downloaded twice from here.
    if (root._pickedDownloaded) return
    if (typeof root.startDownload !== "function") return
    const selector = DL.downloadSelector(root.pickedRow()) || root.format
    if (root.startDownload(url, selector) === false) return
    // What the job took, so a cancel can hand it back.
    root._pendingFormat = root.format
    root._pendingTicks = []
    // The pick and the load are spent the moment the job owns them: the band
    // clears, and nothing this load's late replies say can put it back in the
    // session a reopen reads (see persist()).
    root._loadSpent = true
    root.format = ""
    formatList.currentIndex = -1
  }

  // The installer is a terminal program, so it takes the context and the
  // island closes behind it - the move the CUPS setup button makes.
  function installTool() {
    Exec.run(["vb-launch-terminal", "--app-id=org.vb.term.float",
      "--title=vb-pkg-install", "--", "vb-pkg-install", "--embedded",
      "--", "yt-dlp"])
    if (root.islandHost) root.islandHost.close()
  }

  Component.onCompleted: {
    // The bound error arrives with the component, so its change handler never
    // ran: the notice starts from the line the module already carries.
    root._noticeText = root.lastError
    root.restore()
    root.restoreSort()
    // A remembered playlist is a URL with no rows: its entries come from the
    // CLI, so a reopen asks for them again.
    if (root.initialUrl !== "" && DL.isPlaylistUrl(root.initialUrl)
      && root.playlist.length === 0) root.fetchAll()
    if (root.initialUrl === "") {
      // One initial read covers a clipboard already published. A miss arms
      // the one-shot waiter on clipboardTextChanged (Q15), not a poll.
      root._pasteTrying = !root.pasteFromClipboard()
    }
    root.measureTable()
    root.refresh()
    // The tool can be installed between opens, so every open asks again.
    if (typeof root.probeTool === "function") root.probeTool()
    root._syncPreviewDemand()
    Qt.callLater(() => body.forceActiveFocus())
  }
  onVisibleChanged: {
    if (root.visible) Qt.callLater(() => body.forceActiveFocus())
  }
  // Closing the island is not a reason to lose a loaded, unpicked table: the
  // last persist on the way out is what holds it for the next launch. The
  // runtime warmer is released in the same breath, since no surface is left
  // showing that thumbnail.
  Component.onDestruction: {
    if (root._demandedPreview !== "" && typeof root.releasePreview === "function")
      root.releasePreview(root._demandedPreview)
    root._demandedPreview = ""
    root.persist()
  }

  // The UI font resolves asynchronously at boot; a first measure in the
  // fallback font would freeze undersized columns.
  Connections {
    target: SystemFont

    function onFamilyChanged() { root.measureTable() }
  }

  Keys.onPressed: event => {
    if (event.key !== Qt.Key_V || !(event.modifiers & Qt.ControlModifier)
      || (event.modifiers & Qt.MetaModifier) || urlField.focused) return
    // Same function the pane click and the open-time auto-load call: no raw
    // clipboard write, no bypass of validation, dedupe or noteAutoLoaded.
    const handled = root.pasteFromClipboard()
    // Focus is a keyboard-only nicety, not part of paste semantics: keep the
    // key path's old "ready to edit" behaviour after a real fill.
    if (handled && urlField.text.trim() !== "") urlField.forceActiveFocus()
    event.accepted = true
  }

  Item {
    anchors.fill: parent

    Column {
      id: body
      width: parent.width
      spacing: Ui.s

      // Missing tool: the whole card is the reason plus the one action that
      // fixes it (the CUPS setup-block shape). Everything that needs yt-dlp
      // hides, so nothing promises a fetch that cannot run.
      Item {
        visible: root.toolMissing
        width: parent.width
        height: setupBlock.implicitHeight + Ui.xl

        Column {
          id: setupBlock

          // Own margin under the card's top pad, so the block reads as the
          // card's content rather than as one more row of a stack.
          anchors.top: parent.top
          anchors.topMargin: Ui.xl
          width: parent.width
          spacing: Ui.m

          EmptyState {
            width: parent.width
            iconName: "download-alt"
            text: "No download engine is installed"
          }

          Title {
            level: 5
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Video needs yt-dlp and files need wget. Install the media engine to fetch either kind."
            color: Ui.tint("foreground_1", 0.5)
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            variant: "outline"
            label: "Install yt-dlp"
            onClicked: root.installTool()
          }
        }
      }

      // Preview frame. The thumbnail stays dimmed under the title overlay;
      // the clipboard glyph is the idle placeholder and the image glyph the
      // one a fetch is filling in. The whole pane breathes while it loads and
      // lifts under the pointer, because the pane itself is the click target.
      Rectangle {
        id: previewFrame
        visible: !root.toolMissing
        width: parent.width
        height: 132
        color: Ui.solid("background_2")
        border.width: 1
        border.color: Ui.tint("foreground_1", 0.25)
        clip: true

        Image {
          id: previewImage
          anchors.fill: parent
          asynchronous: true
          cache: true
          retainWhileLoading: true
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: 320
          sourceSize.height: 180
          source: root.previewUrl
          opacity: status === Image.Ready ? 0.55 : 0
          // A loaded thumbnail settles in with a slight push, so the frame
          // reads as arriving rather than as a pop.
          scale: status === Image.Ready && root.previewUrl !== "" ? 1.06 : 1
          Behavior on scale {
            enabled: MotionPolicy.enabled
            NumberAnimation {
              duration: Ui.normalMs
              easing.type: Easing.OutCubic
            }
          }
        }

        Icon {
          anchors.centerIn: parent
          // The clipboard is the idle affordance; a fetched file wears its
          // own glyph, and an image stands in until the thumbnail is painted
          // (the name and listing always arrive first). The file glyph waits
          // for the fetch: an empty field is still an invitation to paste.
          name: root.fileMode && root.previewTitle !== "" ? "file"
            : root.loadingInfo || root.previewUrl !== "" || root.previewText !== ""
              ? "image" : "clipboard"
          colorKey: "foreground_1"
          size: 48
          opacity: 0.4
          visible: previewImage.status !== Image.Ready
        }

        // Title lives over the image, on a scrim that only appears once a
        // preview has actually loaded.
        Rectangle {
          id: previewTitleScrim

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 34
          visible: root.previewText !== ""
          color: Ui.tint("background_0", 0.75)
          // The title scrolls when it does not fit, the same marquee the
          // clipboard and now-playing islands use: a pause at each end and
          // one eased leg between them.
          Item {
            id: previewTitleMarquee

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 8
            height: previewTitleText.implicitHeight
            clip: true

            readonly property real overflow: Math.max(0,
              previewTitleText.implicitWidth - width)
            readonly property bool scrollable: Marquee.scrollable(overflow)
            readonly property int legMs: Marquee.legMs(overflow)
            readonly property int endpointPauseMs: Marquee.endpointPauseMs()

            function reset() {
              previewTitleText.x = 0
              if (previewTitleMarquee.scrollable && previewPaneInput.overTitle)
                previewTitleAnimation.restart()
              else previewTitleAnimation.stop()
            }

            onWidthChanged: previewTitleMarquee.reset()

            SequentialAnimation {
              id: previewTitleAnimation

              running: previewTitleMarquee.scrollable && previewPaneInput.overTitle
              loops: Animation.Infinite
              NumberAnimation {
                target: previewTitleText
                property: "x"
                from: 0
                to: -previewTitleMarquee.overflow
                duration: previewTitleMarquee.legMs
                easing.type: Easing.InOutSine
              }
              PauseAnimation { duration: previewTitleMarquee.endpointPauseMs }
              NumberAnimation {
                target: previewTitleText
                property: "x"
                from: -previewTitleMarquee.overflow
                to: 0
                duration: previewTitleMarquee.legMs
                easing.type: Easing.InOutSine
              }
              PauseAnimation { duration: previewTitleMarquee.endpointPauseMs }
              onStopped: previewTitleText.x = 0
            }

            Title {
              id: previewTitleText

              // The width never depends on `scrollable`: that pair of bindings
              // settles on the constrained width, which left the ellipsis on
              // the very title the marquee was scrolling. The text rides its
              // own width and the marquee's clip trims what is off-screen.
              width: implicitWidth
              anchors.verticalCenter: parent.verticalCenter
              level: 3
              text: root.previewText
              elide: Text.ElideNone
              onTextChanged: previewTitleMarquee.reset()
            }
          }
        }

        // Loading breathe: one slow wash over the whole pane, icon and title
        // included, so a fetch reads as pending rather than as an empty card.
        Rectangle {
          anchors.fill: parent
          color: Ui.tint("foreground_0", 0.05)
          visible: root._previewFetching
          opacity: 0

          SequentialAnimation on opacity {
            running: root._previewFetching && MotionPolicy.enabled
            loops: Animation.Infinite
            NumberAnimation {
              from: 0
              to: 1
              duration: 900
              easing.type: Easing.InOutSine
            }
            NumberAnimation {
              from: 1
              to: 0
              duration: 900
              easing.type: Easing.InOutSine
            }
          }
        }

        // Hover light: the now-playing artwork's own wash, over the title too,
        // so the pane reads as one surface instead of an image with a strip.
        Rectangle {
          anchors.fill: parent
          color: Ui.tint("foreground_0", 0.07)
          opacity: root.previewHover ? 1 : 0
          visible: opacity > 0.01

          Behavior on opacity {
            enabled: MotionPolicy.enabled
            NumberAnimation { duration: Ui.fastMs }
          }
        }

        // The pane is one target: a loaded preview opens its page in the
        // browser, and an empty one is the paste affordance - but only while
        // the clipboard actually names a link. An empty clipboard is not a
        // suggestion: the pane neither lifts under the pointer nor answers a
        // click, so it never promises a paste it cannot make.
        MouseArea {
          id: previewPaneInput

          anchors.fill: parent
          enabled: !root.toolMissing
            && (root.previewUrl !== "" || root._clipboardUrl !== "")
          hoverEnabled: true
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          acceptedButtons: Qt.LeftButton

          // The pane sits above the title strip, so the strip's own hover is
          // read from this one target rather than from a handler the pane
          // would cover. `overTitle` is the bottom scrim, not the whole image.
          property real _hoverY: -1
          readonly property bool overTitle: containsMouse
            && _hoverY >= previewTitleScrim.y

          onEntered: {
            root.previewHover = true
            _hoverY = mouse.y
          }
          onPositionChanged: _hoverY = mouse.y
          onExited: {
            root.previewHover = false
            _hoverY = -1
          }
          // A clipboard that empties under the pointer sends no exit event,
          // so the wash is dropped with the target itself.
          onEnabledChanged: if (!enabled) {
            root.previewHover = false
            _hoverY = -1
          }
          onClicked: {
            if (root.previewUrl !== "") root.openPreviewLink()
            else root.pasteFromClipboard()
          }
        }
      }

      // Engine choice: Auto trusts the classifier; Video and File skip it.
      // The Auto chip names the verdict it reached, so an ftps link reads
      // "Auto: aria2c" instead of changing engines without saying so.
      Row {
        id: engineRow

        visible: !root.toolMissing && urlField.text.trim() !== ""
        width: parent.width
        spacing: Ui.s

        Item {
          width: autoChip.implicitWidth
          height: autoChip.implicitHeight
          opacity: root.tool === "auto" ? 1 : 0.7

          Chip {
            id: autoChip

            text: root.tool === "auto" && root.engine !== ""
              ? "Auto: " + root.engine : "Auto"
            fontSize: Ui.fontXs
            selected: root.tool === "auto"
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.downloading && !root.classifying
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.chooseTool("auto")
          }
        }

        Item {
          width: videoChip.implicitWidth
          height: videoChip.implicitHeight
          opacity: root.tool === "yt-dlp" ? 1 : 0.7

          Chip {
            id: videoChip

            text: "Video"
            fontSize: Ui.fontXs
            selected: root.tool === "yt-dlp"
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.downloading && !root.classifying
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.chooseTool("yt-dlp")
          }
        }

        Item {
          width: fileChip.implicitWidth
          height: fileChip.implicitHeight
          opacity: root.tool === "wget" || root.tool === "aria2c" ? 1 : 0.7

          Chip {
            id: fileChip

            text: "File"
            fontSize: Ui.fontXs
            selected: root.tool === "wget" || root.tool === "aria2c"
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.downloading && !root.classifying
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.chooseTool("wget")
          }
        }
      }

      // A manual Video fetch can be refused by yt-dlp before any table
      // exists. Say what that means in human terms, right under the chips
      // that can fix it, instead of leaving a blank format card.
      Notice {
        width: parent.width
        tone: "warning"
        message: root.mediaMismatch && root.tool === "yt-dlp"
          ? "That link is not a video. Try Auto or File." : ""
      }

      InputField {
        id: urlField
        visible: !root.toolMissing
        width: parent.width
        placeholder: root.fileMode ? "Paste a direct file URL"
          : "Paste a video URL with Ctrl+V"
        clearable: true
        // The xmark is inset the same distance from the link and from the
        // box edge instead of sitting flush against the text.
        clearGap: 2 * Ui.s
        // A link that does not fit scrolls while the field is idle, the way
        // the preview title does; focusing it returns to the head of the URL.
        scrollWhenIdle: true
        // The xmark empties the field, so it may as well empty the card: the
        // table, the pick and the preview it left behind have nothing to say
        // about an empty field. Plain erasing (edited("")) keeps its meaning.
        onCleared: root.clearAll()
        onEdited: {
          root.mediaMismatch = false
          root.dismissNotice()
        }
        onAccepted: text => root.fetchAll()
        onEscaped: {
          if (root.islandHost) root.islandHost.close()
        }
      }

      // The error line sits in a slot of its own so a cancellation can leave
      // with a fade instead of vanishing on the frame the next action lands.
      Item {
        id: noticeSlot

        width: parent.width
        height: root._noticeText !== "" ? noticeBox.height : 0
        visible: !root.toolMissing && root._noticeText !== ""

        Notice {
          id: noticeBox

          width: parent.width
          tone: root._noticeTone
          message: root._noticeText
          opacity: root._noticeFading ? 0 : 1
        }

        SequentialAnimation {
          id: noticeFade

          NumberAnimation {
            target: noticeBox
            property: "opacity"
            to: 0
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
          ScriptAction {
            script: {
              root._noticeText = ""
              root._noticeFading = false
            }
          }
        }
      }

      // Download activity: the word plus a barber pole, so an ongoing download
      // is visibly ongoing rather than a line of static text. There is no byte
      // count to report yet - the CLI prints progress to a terminal only - so
      // accent bands slide along a brightened track instead of a percentage:
      // the striped pole that hangs outside a barbershop, in miniature.
      Row {
        width: parent.width
        spacing: Ui.s
        visible: root.downloading && !root.toolMissing

        // The update card's busy spinner, reused as-is: the reload glyph
        // turning once a second while the job runs. Like the bar sweep, this
        // is a busy indicator, so it ignores the global motion switch.
        Icon {
          id: downloadGlyph
          anchors.verticalCenter: parent.verticalCenter
          name: "update"
          colorKey: "accent"
          size: 12
          transformOrigin: Item.Center

          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 1000
            loops: Animation.Infinite
            running: root.downloading
            onRunningChanged: if (!running) downloadGlyph.rotation = 0
          }
        }

        Title {
          id: downloadingLabel
          anchors.verticalCenter: parent.verticalCenter
          level: 4
          text: root.queueTotal > 1
            ? "Downloading " + Math.min(root.queueDone + 1, root.queueTotal)
              + " of " + root.queueTotal + "..."
            : "Downloading..."
        }

        Rectangle {
          id: pole

          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - 12 - downloadingLabel.implicitWidth
            - 2 * parent.spacing)
          height: 6
          radius: RoundingPolicy.radius
          // Brightened ground under the accent bands, so the track reads as
          // the pole and not as another row of the table.
          color: Ui.solid("background_3")
          clip: true

          Image {
            id: poleBands

            width: pole.width + root._poleTile
            height: pole.height
            fillMode: Image.Tile
            source: root._poleSource
            sourceSize: Qt.size(root._poleTile, pole.height)

            NumberAnimation on x {
              // The bands travel with the download, left to right, even when
              // global animations are off: this is the progress indicator.
              from: -root._poleTile
              to: 0
              duration: 1200
              loops: Animation.Infinite
              running: root.downloading
            }
          }
        }
      }

      // The three tables share one slot: the one the current mode names fades
      // in as the others fade out, so a switch between RECENT, FORMATS and
      // PLAYLIST reads as a swap rather than a single-frame replacement.
      Item {
        id: sectionSwap

        width: parent.width
        visible: !root.toolMissing && !root.fileMode
        height: root.fileMode ? 0
          : root.playlist.length > 0 ? playlistBlock.height
            : root._showHistory ? historyBlock.height : tableBlock.height

        readonly property bool showPlaylist: root.playlist.length > 0
        readonly property bool showHistory: root._showHistory
          && root.playlist.length === 0
        readonly property bool showTable: !root._showHistory
          && root.playlist.length === 0

      // Format table: header row plus the capped list, both columns sized
      // from one set of measurements. The block's height is constant: the
      // list always holds the padded row window and the header never moves.
      Item {
        id: tableBlock

        width: parent.width
        opacity: sectionSwap.showTable ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          NumberAnimation { duration: Ui.fastMs }
        }
        height: headerRow.height + formatList.height

        Column {
          width: parent.width

          Item {
            id: headerRow

            width: parent.width
            height: 20

            Row {
              anchors.fill: parent
              anchors.leftMargin: root._rowInset
              anchors.rightMargin: root._rowInset + root._vBarGutter
              spacing: root._gap

              SortHeader {
                width: root.resColW
                anchors.verticalCenter: parent.verticalCenter
                text: "RESOLUTION"
                sortKey: "resolution"
                activeKey: root.sortKey
                onClicked: root.toggleSort("resolution")
              }

              SortHeader {
                width: root.fpsColW
                anchors.verticalCenter: parent.verticalCenter
                text: "FPS"
                alignRight: true
                sortKey: "fps"
                activeKey: root.sortKey
                onClicked: root.toggleSort("fps")
              }

              SortHeader {
                width: root.extColW
                anchors.verticalCenter: parent.verticalCenter
                text: "FORMAT"
                sortKey: "format"
                activeKey: root.sortKey
                onClicked: root.toggleSort("format")
              }

              SortHeader {
                width: root.kindColW
                anchors.verticalCenter: parent.verticalCenter
                text: "A/V"
                sortKey: "kind"
                activeKey: root.sortKey
                onClicked: root.toggleSort("kind")
              }

              SortHeader {
                width: root.sizeColW
                anchors.verticalCenter: parent.verticalCenter
                text: "SIZE"
                alignRight: true
                sortKey: "size"
                activeKey: root.sortKey
                onClicked: root.toggleSort("size")
              }
            }
          }

          Item {
            width: parent.width
            height: formatList.height

            List {
              id: formatList

              width: parent.width
              // Capped viewport: the table grows to its window and then
              // scrolls instead of pushing the action row off the card.
              height: Math.min(contentHeight, root.tableCapH)
              clip: true
              // One selection, no checkbox: the chosen row is the accent
              // band the delegate paints, and the built-in highlight stays
              // for the keyboard cursor so walking the table is visible
              // before Enter commits.
              stableModel: root._rows
              spacing: root._rowGap
              currentIndex: -1
              // Seating a row is a click, not a journey: the band snaps to the
              // pick instead of gliding across the table from the last one.
              highlightMotion: false
              // A row picked with the mouse keeps the place it has: the table
              // does not recentre its cursor the way a menu does.
              centerFollow: false
              interactive: contentHeight > height && !root._blank
              wheelSteps: false
              // A placeholder row is not a format: the cursor must not stop
              // on a filler it could never download.
              isSelectable: i => !root._blank && !DL.isFiller(root._rows[i])
              delegate: formatRow
              onActivated: index => root.pickIndex(index)
              // The view seats index 0 synchronously as part of the model
              // assignment, before this edge fires. Unseating here (rather
              // than a turn later) means the unpointed band never reaches a
              // frame - the same synchronous gate ArchUpdates uses.
              onModelChanged: {
                if (formatList.currentIndex !== -1) formatList.seat(-1, "land")
              }
            }

            // The placeholder rows stay perfectly still and one wash breathes
            // over them, the ArchUpdates pattern: per-bar pulses staggered on
            // their own read as random flicker rather than as loading.
            Item {
              anchors.fill: parent
              clip: true
              visible: opacity > 0.01
              opacity: root.loadingInfo ? 1 : 0

              Behavior on opacity {
                enabled: MotionPolicy.enabled
                Glide { duration: Ui.normalMs }
              }

              Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0.0; color: "transparent" }
                  GradientStop { position: 0.5; color: Ui.tint("foreground_1", 0.10) }
                  GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: 0.55

                SequentialAnimation on opacity {
                  loops: Animation.Infinite
                  running: root.loadingInfo && MotionPolicy.enabled
                  SkeletonPulse { index: 0 }
                }
              }
            }
          }
        }

        // Vertical scrollbar: fixed in the viewport, below the header, in
        // the gutter the rows already reserve. It rides the live rows, so it
        // fades in as they take the table over.
        Item {
          anchors.fill: parent
          opacity: 1 - root._skeletonMix
          visible: opacity > 0

          ScrollBar {
            flickable: formatList
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: headerRow.height
            anchors.bottom: parent.bottom
            anchors.rightMargin: 1
            thickness: 3
            radius: RoundingPolicy.radius
          }
        }

      }

      // Idle table: what was downloaded before, so an empty island still says
      // something useful. A row loads that video again; the trailing glyph
      // removes the entry from the history file.
      Item {
        id: historyBlock

        width: parent.width
        opacity: sectionSwap.showHistory ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          NumberAnimation { duration: Ui.fastMs }
        }
        height: histHeader.height + histList.height

        Column {
          width: parent.width

          Item {
            id: histHeader

            width: parent.width
            height: 20

            Row {
              anchors.fill: parent
              anchors.leftMargin: root._rowInset
              // Clears the remove rail: the buttons stand beside the history
              // list, so the header's value column ends where the list does.
              anchors.rightMargin: root._deleteSlotW + root._gap
                + root._rowInset
              spacing: root._gap

              // The mode names itself in the first column instead of in a cap
              // above the table (the formats table keeps RESOLUTION, which
              // already says what it is).
              Title {
                level: 5
                width: root.histTitleW
                anchors.verticalCenter: parent.verticalCenter
                text: "RECENT"
                elide: Text.ElideNone
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }

              Title {
                level: 5
                width: root.sizeColW
                anchors.verticalCenter: parent.verticalCenter
                text: "SIZE"
                elide: Text.ElideNone
                horizontalAlignment: Text.AlignRight
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }

            }
          }

          Item {
            width: parent.width
            height: histList.height

            List {
              id: histList
              // probe hook: historyList -> read by downloader-island.qml for
              // history geometry; inert in production
              objectName: "historyList"

              // The table stops at its band; the remove rail owns the width
              // past it, beside the list and outside its rows.
              width: root._histBandW
              // Only the rows that exist: history is short, and a table of
              // empty slots would be a taller island for nothing. The table
              // is a fixed window: entries past the seventh are not scrolled
              // to, removed, or otherwise acknowledged here.
              height: Math.min(contentHeight, root.tableCapH)
              clip: true
              contentY: 0
              // Padded to the window exactly like the format table, so the
              // rows the history does not fill stand as the same skeleton bars
              // (ArchUpdates' placeholder) and the table keeps one footprint.
              stableModel: root._historyRows
              spacing: root._rowGap
              currentIndex: -1
              interactive: false
              wheelSteps: false
              delegate: historyRow
              // An empty recent table is a dimmed footprint, not a live
              // format skeleton: the rows are padding for the idle note.
              opacity: root._historyEmpty ? 0.35 : 1
              Behavior on opacity {
                enabled: MotionPolicy.enabled
                NumberAnimation { duration: Ui.fastMs }
              }
              // Recent rows are picks, not a selection: the view's own
              // index-0 seat is undone in this synchronous model edge.
              onModelChanged: {
                if (histList.currentIndex !== -1) histList.seat(-1, "land")
              }
            }

            // The empty note is a child of this Item, not of the Column: an
            // anchor to histList is only a sibling anchor here, so the note
            // centers on the table box instead of parking under the header.
            EmptyState {
              // probe hook: historyEmpty -> read by downloader-island.qml for
              // empty-note centering; inert in production
              objectName: "historyEmpty"
              anchors.centerIn: histList
              width: histList.width
              iconName: root._historyEmptyIcon
              text: root._historyEmptyText
              visible: root._historyEmpty
            }

            // Remove rail: one button per entry, aligned to its row and
            // standing beside the list rather than inside it. Nothing here
            // widens a row or is clipped by the table.
            Item {
              id: deleteRail

              x: histList.width + root._gap
              width: root._deleteSlotW
              height: histList.height
              clip: true

              Repeater {
                model: root._historyRows

                delegate: IconButton {
                  required property var modelData
                  required property int index

                  y: index * (root._rowH + root._rowGap)
                    - histList.contentY
                  width: root._deleteSlotW
                  height: root._rowH
                  visible: !DL.isFiller(modelData)
                  // A chip, not a stray mark: row height, the shell's own
                  // corner radius and a hairline edge, so it reads as a
                  // control belonging to the band beside it. At rest it is
                  // the bare glyph; under the pointer the whole chip fills
                  // solid red and the glyph flips to the card ground, so the
                  // destructive action is the button itself. Nothing about it
                  // moves: no zoom, no lift, just the fill.
                  name: "remove"
                  iconSize: 14
                  flat: true
                  cornerRadius: RoundingPolicy.radius
                  // The border is red at rest and only deeper under the
                  // pointer; the fill is what arrives with the hover.
                  borderKey: "red"
                  colorKey: hovered ? "background_0" : "foreground_1"
                  iconOpacity: 1
                  color: hovered ? Ui.solid("red") : "transparent"
                  tipText: "Remove from history"
                  onClicked: root.requestDelete(index)
                }
              }
            }
          }
        }

      }

      // Playlist table: the entries a playlist link names, all ticked to begin
      // with. The header tick flips all of them; the primary action downloads
      // the ticked ones in order.
      Item {
        id: playlistBlock

        opacity: sectionSwap.showPlaylist ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
          enabled: MotionPolicy.enabled
          NumberAnimation { duration: Ui.fastMs }
        }
        width: parent.width
        height: plBody.implicitHeight

        Column {
          id: plBody

          width: parent.width

          // The batch's quality: a playlist cannot show per-entry formats, so
          // the choice is made once for everything ticked. The row is the
          // chips alone - the cap word said nothing the chips do not - and it
          // is a band of its own: the same air below it as the section spacing
          // above it, so the chips do not crowd the header that follows.
          Item {
            width: parent.width
            height: qualityColumn.implicitHeight + Ui.s

            Column {
              id: qualityColumn

              width: parent.width
              spacing: Ui.s

              Row {
                id: qualityRow

                width: parent.width
                spacing: Ui.s

                Repeater {
                  model: DL.qualityOptions()

                  delegate: Item {
                    required property var modelData

                    width: qualityChip.implicitWidth
                    height: qualityChip.implicitHeight
                    anchors.verticalCenter: parent.verticalCenter
                    // The unchosen captures step back: at full strength the
                    // four chips read as four equally current choices, and
                    // their fills mud together against the card.
                    // With fewer than two entries ticked there is no batch to
                    // cap: the chips grey out, and the one ticked video opens
                    // in the format table instead.
                    opacity: root.plCount < 2 ? 0.3
                      : (root.plQuality === String(modelData.key) ? 1 : 0.7)

                    Behavior on opacity {
                      enabled: MotionPolicy.enabled
                      NumberAnimation { duration: Ui.fastMs }
                    }

                    Chip {
                      id: qualityChip
                      text: String(modelData.label)
                      fontSize: Ui.fontXs
                      selected: root.plQuality === String(modelData.key)
                      // Each cap wears its own leaf of the palette, so the row
                      // reads as a ladder of tiers before any label is read.
                      colorKey: String(modelData.color || "")
                    }

                    MouseArea {
                      anchors.fill: parent
                      enabled: !root.downloading && root.plCount > 1
                      onClicked: root.plQuality = String(modelData.key)
                    }

                    // A disabled chip still receives hover here, which is
                    // what lets it show the disabled-button cursor.
                    HoverHandler {
                      cursorShape: !root.downloading && root.plCount > 1
                        ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                    }
                  }
                }
              }

              // The cover-art choice belongs to the audio capture, not to a
              // video cap: show it only while Audio is the selection and the
              // batch has at least two entries (a single entry uses the
              // format table instead).
              Item {
                id: audioMetaBlock

                visible: root.plQuality === "audio" && root.plCount > 1
                width: parent.width
                height: visible ? audioMetaRow.implicitHeight : 0

                // The checkbox column is the playlist table's own: same row
                // inset and gap, so the audio choice lines up with the ticks.
                Row {
                  id: audioMetaRow

                  anchors.left: parent.left
                  anchors.leftMargin: root._rowInset
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: root._gap

                  CheckBox {
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: !root.downloading
                    checked: root.plEmbedThumbnail
                  }

                  Title {
                    anchors.verticalCenter: parent.verticalCenter
                    level: 5
                    text: "Embed thumbnail"
                    color: Ui.tint("foreground_1", 0.75)
                    font.pixelSize: Ui.fontXs
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: !root.downloading
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.plEmbedThumbnail = !root.plEmbedThumbnail
                }
              }
            }
          }

          Item {
            id: plHeader

            width: parent.width
            height: 20

            Row {
              anchors.fill: parent
              anchors.leftMargin: root._rowInset
              anchors.rightMargin: root._rowInset + root._vBarGutter
              spacing: root._gap

              Item {
                width: 14
                height: 14
                anchors.verticalCenter: parent.verticalCenter

                CheckBox {
                  anchors.centerIn: parent
                  checked: root.plTickable > 0
                    && root.plCount === root.plTickable
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: !root.downloading
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.togglePlaylistAll()
                }
              }

              Title {
                width: 22
                anchors.verticalCenter: parent.verticalCenter
                level: 5
                text: "#"
                horizontalAlignment: Text.AlignRight
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }

              Title {
                width: parent.width - 14 - 22 - root.plDurationW
                  - 3 * root._gap
                anchors.verticalCenter: parent.verticalCenter
                level: 5
                text: "VIDEOS"
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }

              Title {
                width: root.plDurationW
                anchors.verticalCenter: parent.verticalCenter
                level: 5
                text: "TIME"
                horizontalAlignment: Text.AlignRight
                color: Ui.tint("foreground_1", 0.6)
                font.pixelSize: Ui.fontXs
                font.bold: true
              }
            }
          }

          Item {
            width: parent.width
            height: plList.height

            List {
              id: plList

              width: parent.width
              // The same capped viewport as the other tables: seven rows, then
              // the list scrolls instead of pushing the action row down.
              height: Math.min(contentHeight, root.tableCapH)
              clip: true
              stableModel: root.playlist
              spacing: root._rowGap
              // Ticks are the playlist's selection; the list itself has no
              // cursor, so nothing wears a focused-row band and no row is
              // seated when the entries arrive.
              currentIndex: -1
              selectionHighlight: false
              isSelectable: () => false
              interactive: contentHeight > height
              wheelSteps: false
              delegate: playlistRow
              // Ticks, not the list cursor, are the playlist's selection:
              // clear the view's synchronous index-0 seat in the same edge.
              onModelChanged: {
                if (plList.currentIndex !== -1) plList.seat(-1, "land")
              }
            }

            ScrollBar {
              flickable: plList
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.rightMargin: 1
              thickness: 3
              radius: RoundingPolicy.radius
            }
          }
        }
      }

      }

      Row {
        visible: !root.toolMissing
        width: parent.width
        spacing: Ui.s
        Button {
          id: actionButton

          width: (parent.width - Ui.s) / 2
          label: root.downloading ? "Cancel"
            : root.playlist.length > 0 ? "Download " + root.plCount
            : root.fileMode ? "Download"
            : root._pickedDownloaded ? "Open" : "Download"
          // Cancel is the one destructive press on the card, so it wears the
          // red fill; a copy already on disk wears the finished job's green and
          // opens it, so the green is an action rather than a dead state. Both
          // stay at full strength because their labels say what they are.
          variant: "primary"
          accentColor: root.downloading ? Ui.solid("red")
            : root._pickedDownloaded ? Ui.solid("green")
            : Ui.solid("accent")
          opacity: root.downloading || root._pickedDownloaded
            || root.plCount > 0 || (root.fileMode
              && urlField.text.trim() !== "")
            || actionButton.live ? 1 : 0.45
          actionable: root.downloading
            || (root.playlist.length > 0
              ? root.plCount > 0
              : root.fileMode ? urlField.text.trim() !== ""
                : root._pickedDownloaded ? root._openPath !== ""
                  : root.format !== "")
          onClicked: {
            if (root.downloading) {
              if (typeof root.cancelDownload === "function") root.cancelDownload()
            } else if (root._pickedDownloaded) {
              // The capture is on disk: the press opens it where it landed and
              // the card has nothing left to say, so it closes behind the
              // player the way the installer's launch does.
              if (root._openPath !== "") {
                Exec.run(["xdg-open", root._openPath])
                if (root.islandHost) root.islandHost.close()
              }
            } else {
              root.begin()
            }
          }
        }
        Button {
          width: (parent.width - 2 * parent.spacing) / 4
          // A staged recent entry turns the table's refresh into a fetch: the
          // field already carries the staged URL, so this is the same call,
          // with the button saying which job it is about to do.
          label: root._histPicked ? "Fetch" : "Refresh"
          variant: "outline"
          // Nothing in the field means nothing to fetch, and a running job
          // owns the card: an inert button must not answer a click.
          actionable: !root.downloading && urlField.text.trim() !== ""
          onClicked: root.fetchAll()
        }
        Button {
          width: (parent.width - 2 * parent.spacing) / 4
          label: "Clear"
          variant: "outline"
          // In recent mode the table itself is what Clear is for: an empty
          // field still has a whole list to wipe. Everywhere else it is inert
          // while the island is already empty.
          actionable: !root.downloading
            && (root.history.length > 0 || root._dirty)
          onClicked: {
            if (root._showHistory) {
              root.wipeHistory()
              return
            }
            root.clearAll()
          }
        }
      }
    }
  }

  // One row, two faces: the skeleton bar it is born as and the format it
  // carries. A filler row only ever has the bar - it is the empty space
  // under the last format. The switch lives inside the delegate because
  // `modelData` exists only here; a list-scope ternary would throw.
  Component {
    id: formatRow

    Item {
      id: rowCell

      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : root._tableW
      height: root._rowH

      readonly property bool filler: DL.isFiller(rowCell.modelData)
      readonly property string rowId: rowCell.filler ? "" : String(rowCell.modelData.id || "")
      readonly property string label: DL.formatLabel(rowCell.modelData)
      readonly property string fpsText: DL.fpsLabel(rowCell.modelData)
      readonly property string extText: DL.extLabel(rowCell.modelData)
      readonly property string extKey: rowCell.filler ? "foreground_1"
        : DL.filetypeKey(rowCell.modelData.ext)
      readonly property string kindText: DL.kindLabel(rowCell.modelData)
      readonly property string kindKey: rowCell.filler ? "foreground_1"
        : DL.kindKey(rowCell.modelData)
      readonly property string sizeText: rowCell.filler ? ""
        : DL.cellLabel(DL.sizeLabel(rowCell.modelData.size))
      readonly property bool chosen: !rowCell.filler && root.format === rowCell.rowId
      // Already on disk for this URL: the row is a fact, not a pick.
      readonly property bool done: rowCell.liveRow
        && root._doneIds.indexOf(rowCell.rowId) >= 0
      // A live row answers pointer and keyboard only once the real formats
      // own the table; behind the skeleton bars there is nothing to pick.
      readonly property bool liveRow: !rowCell.filler && !root._blank
      readonly property real barOpacity: rowCell.filler ? 1 : root._skeletonMix
      readonly property real contentOpacity: rowCell.filler ? 0 : 1 - root._skeletonMix

      // Zebra band plus the click surface. The selected row is the accent
      // band; there is no checkmark anywhere in the table.
      ZebraRow {
        anchors.fill: parent
        rowIndex: rowCell.index
        selected: rowCell.chosen
        // A running job owns the table: its rows are neither picks nor
        // navigable until it ends.
        interactive: rowCell.liveRow && !root.downloading
        hoverable: rowCell.liveRow && !root.downloading
        hoverCursor: rowCell.liveRow && !root.downloading
        onClicked: {
          formatList.seat(rowCell.index, "click")
          root.pickIndex(rowCell.index)
        }
      }

      // The pointer contract lives on the row it describes. A live pick
      // points; a placeholder or running job refuses. A table-wide overlay
      // could outlive the row state and leave the refusal cursor over rows
      // the user can still select.
      HoverHandler {
        cursorShape: rowCell.liveRow && !root.downloading
          ? Qt.PointingHandCursor : Qt.ForbiddenCursor
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root._rowInset
        anchors.rightMargin: root._rowInset + root._vBarGutter
        spacing: root._gap

        // Primary cell: the resolution a person picks by, bold foreground_0.
        Item {
          width: root.resColW
          height: parent.height

          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            SkeletonBar {
              // Staggered widths: a wall of identical bars reads as a block,
              // the three-phase pattern reads as unfinished rows.
              width: parent.width * (0.42 + (rowCell.index % 3) * 0.16)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Title {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            level: 5
            text: rowCell.label
            elide: Text.ElideRight
            // Accent marks a format this video was already taken in.
            color: rowCell.done ? Ui.solid("accent") : Ui.solid("foreground_0")
            font.pixelSize: Ui.fontXs
            font.bold: true
          }
        }

        // Frame-rate cell: a bare number, right-aligned like the size, and a
        // dash when the stream has no video to have a rate.
        Item {
          width: root.fpsColW
          height: parent.height

          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            SkeletonBar {
              width: parent.width * 0.6
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Title {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            level: 5
            text: rowCell.fpsText
            elide: Text.ElideNone
            horizontalAlignment: Text.AlignRight
            color: Ui.tint("foreground_1", 0.7)
            font.pixelSize: Ui.fontXs
          }
        }

        // Container cell: color-coded by type, so the two rows that share a
        // resolution read apart without having to be compared word by word.
        Item {
          width: root.extColW
          height: parent.height

          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            SkeletonBar {
              width: parent.width * 0.65
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Title {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            level: 5
            text: rowCell.extText
            elide: Text.ElideRight
            color: Ui.tint(rowCell.extKey, 1)
            font.pixelSize: Ui.fontXs
          }
        }

        // Kind cell: what the stream carries. A resolution alone cannot say
        // whether a row is silent, so it reads quiet beside it.
        Item {
          width: root.kindColW
          height: parent.height

          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            SkeletonBar {
              width: parent.width * 0.7
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Title {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            level: 5
            text: rowCell.kindText
            elide: Text.ElideRight
            color: Ui.tint(rowCell.kindKey, 1)
            font.pixelSize: Ui.fontXs
          }
        }

        // Value cell: the reported size, accent and right-aligned.
        Item {
          width: root.sizeColW
          height: parent.height

          Item {
            anchors.fill: parent
            opacity: rowCell.barOpacity
            visible: opacity > 0

            SkeletonBar {
              width: parent.width * 0.58
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Title {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            opacity: rowCell.contentOpacity
            visible: opacity > 0
            level: 5
            text: rowCell.sizeText
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignRight
            color: Ui.tint("accent", 1)
            font.pixelSize: Ui.fontXs
          }
        }
      }
    }
  }

  // One history entry: the title, the size it landed at, and a remove glyph
  // that appears on hover. Clicking the row loads that URL again.
  // One playlist entry: a tick, its position, its title and its length. The
  // whole row toggles - the shared CheckBox is visual only, by design.
  Component {
    id: playlistRow

    Item {
      id: plCell

      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : root._tableW
      height: root._rowH

      readonly property bool ticked: root.plChecked[plCell.index] === true
      // Already in the history: the tick stands as a fact (we have it), but
      // the row answers no pointer and is never queued again.
      readonly property bool have: root.playlistHave(plCell.index)
      // A running queue owns the table: no tick moves until it ends.
      readonly property bool liveRow: !root.downloading

      ZebraRow {
        anchors.fill: parent
        rowIndex: plCell.index
        interactive: plCell.liveRow && !plCell.have
        hoverable: plCell.liveRow && !plCell.have
        hoverCursor: plCell.liveRow && !plCell.have
        onClicked: root.togglePlaylist(plCell.index)
      }

      // A held entry and a running batch are both non-interactive rows; the
      // pointer reads the same refusal as a disabled button.
      HoverHandler {
        cursorShape: plCell.liveRow && !plCell.have
          ? Qt.PointingHandCursor : Qt.ForbiddenCursor
      }

      Row {
        anchors.fill: parent
        anchors.leftMargin: root._rowInset
        anchors.rightMargin: root._rowInset + root._vBarGutter
        spacing: root._gap

        Item {
          width: 14
          height: 14
          anchors.verticalCenter: parent.verticalCenter

          CheckBox {
            anchors.centerIn: parent
            checked: plCell.have || plCell.ticked
          }
        }

        Title {
          width: 22
          anchors.verticalCenter: parent.verticalCenter
          level: 5
          text: String(plCell.modelData.index || "")
          horizontalAlignment: Text.AlignRight
          color: plCell.have ? Ui.tint("foreground_1", 0.3)
            : Ui.tint("foreground_1", 0.6)
          font.pixelSize: Ui.fontXs
        }

        // A title longer than its column scrolls like the recent rows: a pause
        // at each end and one eased leg between them, but only while the
        // pointer is over the title.
          Item {
            id: plTitleBox

            width: parent.width - 14 - 22 - root.plDurationW - 3 * root._gap
            height: parent.height
            clip: true

            readonly property real overflow: Math.max(0,
              plTitleText.implicitWidth - width)
            readonly property bool scrollable: Marquee.scrollable(overflow)
            readonly property int legMs: Marquee.legMs(overflow)
            readonly property int endpointPauseMs: Marquee.endpointPauseMs()

            HoverHandler {
              id: plTitleHover
              cursorShape: plCell.liveRow && !plCell.have
                ? Qt.PointingHandCursor : Qt.ForbiddenCursor
            }

            function reset() {
              plTitleText.x = 0
              if (plTitleBox.scrollable && plTitleHover.hovered)
                plTitleAnimation.restart()
              else plTitleAnimation.stop()
            }

            onWidthChanged: plTitleBox.reset()
            onOverflowChanged: plTitleBox.reset()

            SequentialAnimation {
              id: plTitleAnimation

              running: plTitleBox.scrollable && plTitleHover.hovered
              loops: Animation.Infinite
            NumberAnimation {
              target: plTitleText
              property: "x"
              from: 0
              to: -plTitleBox.overflow
              duration: plTitleBox.legMs
              easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: plTitleBox.endpointPauseMs }
            NumberAnimation {
              target: plTitleText
              property: "x"
              from: -plTitleBox.overflow
              to: 0
              duration: plTitleBox.legMs
              easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: plTitleBox.endpointPauseMs }
            onStopped: plTitleText.x = 0
          }

          Title {
            id: plTitleText

            width: implicitWidth
            anchors.verticalCenter: parent.verticalCenter
            level: 5
            text: String(plCell.modelData.title || "-")
            elide: Text.ElideNone
            font.pixelSize: Ui.fontXs
            // A held entry keeps its name in the accent - it is a copy, not
            // an option - while the rest of its row steps back.
            color: plCell.have ? Ui.solid("accent")
              : plCell.ticked ? Ui.solid("foreground_0")
              : Ui.tint("foreground_1", 0.6)
            onTextChanged: plTitleBox.reset()
          }
        }

        Title {
          width: root.plDurationW
          anchors.verticalCenter: parent.verticalCenter
          level: 5
          text: DL.cellLabel(plCell.modelData.duration)
          horizontalAlignment: Text.AlignRight
          color: plCell.have ? Ui.tint("foreground_1", 0.3)
            : Ui.tint("foreground_1", 0.6)
          font.pixelSize: Ui.fontXs
        }
      }
    }
  }

  Component {
    id: historyRow

    Item {
      id: histCell

      required property var modelData
      required property int index
      width: ListView.view ? ListView.view.width : root._tableW
      height: root._rowH

      readonly property bool filler: DL.isFiller(histCell.modelData)
      readonly property bool liveRow: !histCell.filler
      readonly property string titleText: histCell.filler ? ""
        : (histCell.modelData && histCell.modelData.title
          ? String(histCell.modelData.title) : "-")
      readonly property string sizeText: histCell.filler ? ""
        : DL.cellLabel(DL.sizeLabel(histCell.modelData && histCell.modelData.size))
      // The entry remembers a file the downloader wrote; if that path is gone
      // (moved, renamed, deleted) the row says so instead of pretending it is
      // still there. It still loads the URL for another copy.
      readonly property bool gone: histCell.liveRow && histCell.modelData
        && histCell.modelData.path
        && root.missingFiles.indexOf(String(histCell.modelData.path)) >= 0

      ZebraRow {
        id: histBand

        width: parent.width
        height: parent.height
        rowIndex: histCell.index
        // The staged row wears the selected band until the fetch starts.
        selected: root._histPicked && root._histPick === histCell.index
        // Same rule as the format table: a download in flight owns the list.
        interactive: histCell.liveRow && !root.downloading
        hoverable: histCell.liveRow && !root.downloading
        hoverCursor: histCell.liveRow && !root.downloading
        onClicked: root.selectHistory(histCell.index)
      }

      // The rows past the last entry were never downloaded, so they say
      // nothing: title-width bar and a size bar in the slots they will fill.
      Item {
        anchors.fill: parent
        visible: histCell.filler

        SkeletonBar {
          x: root._rowInset
          width: root.histTitleW * (0.45 + (histCell.index % 3) * 0.15)
          anchors.verticalCenter: parent.verticalCenter
          restingOpacity: 0.7
        }

        SkeletonBar {
          width: root.sizeColW * 0.55
          anchors.right: parent.right
          anchors.rightMargin: root._rowInset
          anchors.verticalCenter: parent.verticalCenter
          restingOpacity: 0.7
        }
      }

      Row {
        anchors.left: parent.left
        anchors.right: histBand.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: root._rowInset
        // The band already stops in the gutter; the text keeps its own inset
        // from that edge so the SIZE column stays where the header puts it.
        anchors.rightMargin: root._rowInset
        spacing: root._gap
        visible: histCell.liveRow

        // A title longer than its column scrolls like the preview title: a
        // pause at each end and one eased leg between them, but only while the
        // pointer is over the title. Short titles are still and elide nothing.
        Item {
          id: histTitleBox

          width: root.histTitleW
          height: parent.height
          clip: true

          readonly property real overflow: Math.max(0,
            histTitleText.implicitWidth - width)
          readonly property bool scrollable: Marquee.scrollable(overflow)
          readonly property int legMs: Marquee.legMs(overflow)
          readonly property int endpointPauseMs: Marquee.endpointPauseMs()

          HoverHandler {
            id: histTitleHover
            cursorShape: histCell.liveRow && !root.downloading
              ? Qt.PointingHandCursor : Qt.ArrowCursor
          }

          function reset() {
            histTitleText.x = 0
            if (histTitleBox.scrollable && histTitleHover.hovered)
              histTitleAnimation.restart()
            else histTitleAnimation.stop()
          }

          onWidthChanged: histTitleBox.reset()
          onOverflowChanged: histTitleBox.reset()

          SequentialAnimation {
            id: histTitleAnimation

            running: histTitleBox.scrollable && histTitleHover.hovered
            loops: Animation.Infinite
            NumberAnimation {
              target: histTitleText
              property: "x"
              from: 0
              to: -histTitleBox.overflow
              duration: histTitleBox.legMs
              easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: histTitleBox.endpointPauseMs }
            NumberAnimation {
              target: histTitleText
              property: "x"
              from: -histTitleBox.overflow
              to: 0
              duration: histTitleBox.legMs
              easing.type: Easing.InOutSine
            }
            PauseAnimation { duration: histTitleBox.endpointPauseMs }
            onStopped: histTitleText.x = 0
          }

          Title {
            id: histTitleText

            width: implicitWidth
            anchors.verticalCenter: parent.verticalCenter
            level: 5
            text: histCell.titleText
            elide: Text.ElideNone
            color: histCell.gone ? Ui.tint("foreground_1", 0.55)
              : Ui.solid("foreground_0")
            font.pixelSize: Ui.fontXs
            font.strikeout: histCell.gone
            onTextChanged: histTitleBox.reset()
          }
        }

        Title {
          width: root.sizeColW
          anchors.verticalCenter: parent.verticalCenter
          level: 5
          text: histCell.sizeText
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignRight
          color: histCell.gone ? Ui.tint("accent", 0.45) : Ui.tint("accent", 1)
          font.pixelSize: Ui.fontXs
        }

      }
    }
  }
}

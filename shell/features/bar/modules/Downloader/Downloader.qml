pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Io
import qs.common
import qs.features.bar
import "DownloadsLib.js" as DL

// Statusbar entry for the downloader. The module owns the running job and the
// busy state so the island can be closed mid-download without cancelling
// anything; island content is transient and only forwards user intent.
//
// The CLI is the dispatcher: it routes media to yt-dlp and direct files to
// wget or aria2c. The module never decides an engine itself - the island says
// which one a link is, and passes it through.
BarModule {
  id: root

  implicitWidth: Bar.iconSlot
  fillButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
  barTipText: "Downloader"
  barTipActive: root.hovered && !root.islandOpen

  property bool downloading: false
  property string lastError: ""
  // The file the last successful run wrote. The island uses it for the green
  // completion box in file mode; clearing it at the start of every run keeps a
  // stale path from naming the wrong file.
  property string lastSavedPath: ""
  // Set by the user's own Cancel: the job then exits nonzero, and that is not
  // a failure to announce.
  property bool _cancelled: false
  // Every run owns a token. Cancel bumps it, and a late callback from the run
  // it killed is ignored instead of clearing the busy state of a newer job.
  property int _runSeq: 0
  // One middle-click read at a time: the primary owner is a one-shot child and
  // a second click while it runs would race its own answer.
  property bool _primaryBusy: false
  // The table's ordering is a view preference, so it outlives the island the
  // way the loaded session does without being part of it.
  property string sortKey: "resolution"
  property string sortDir: "desc"

  // Three red blinks for a download that failed while the island was closed:
  // the bar glyph is the only surface left to say so, and the cadence is the
  // connectivity glyph's own (Ui.blinkMs), counted rather than held.
  property int _blinkLeft: 0
  property bool _blinkOn: false
  // The blink snaps between two real colours, so each blink is one data URL
  // (Icons.url), not the ~30 a tween through intermediate hex colours would
  // decode; the retained raster covers the single decode per endpoint.
  property color glyphColor: root._blinkOn ? Ui.solid("red")
    : Ui.solid("foreground_0")

  function _flashFailure() {
    root._blinkLeft = 5
    root._blinkOn = true
    blinkTimer.restart()
  }

  Timer {
    id: blinkTimer

    interval: Ui.blinkMs
    repeat: true
    running: false
    onTriggered: {
      if (root._blinkLeft <= 0) {
        root._blinkOn = false
        blinkTimer.stop()
        return
      }
      root._blinkLeft--
      root._blinkOn = !root._blinkOn
    }
  }

  function rememberSort(key, dir) {
    root.sortKey = key || "resolution"
    root.sortDir = dir === "asc" ? "asc" : "desc"
  }
  readonly property string cli: Paths.vibraniumHome + "/bin/vb-util-download"
  readonly property string historyPath: Paths.vibraniumState + "/vb-util-yt-dlp.history"
  // The playlist history row is one folder row; this sidecar names the entry
  // files it contains so the held-entry ticks survive that grouping.
  readonly property string playlistEntriesPath:
    Paths.vibraniumState + "/vb-util-yt-dlp.entries"

  // The island is torn down when it closes, so the loaded URL, format table,
  // preview and pick live here until a download actually happens. Reopening
  // the island restores the last load instead of an empty table.
  property string sessionUrl: ""
  property var sessionFormats: []
  // A playlist's entries are part of the load: they come from the CLI, so a
  // remember without them would refetch on every open.
  property var sessionPlaylist: []
  // The playlist's own name: the folder the batch downloads into and what the
  // preview calls it. Not part of the entries - a title is not a video.
  property string sessionPlaylistTitle: ""
  // The ticks that went with those entries, so a narrowed batch reopens as it
  // was left.
  property var sessionPlChecked: []
  property var sessionPreview: ({ title: "", thumbnail: "" })
  property string sessionFormat: ""
  // The engine choice and the verdict that went with the load. Auto is the
  // default; an explicit tool is the user's override while the island is open.
  property string sessionTool: "auto"
  property string sessionKind: "unknown"
  property string sessionReason: ""
  property string sessionEngine: ""
  // History rows whose file is no longer on disk. The CLI answers the check:
  // the shell has no primitive that asks "does this path exist" without
  // reading the file, and reading a video to learn that is not an option.
  property var missingPaths: []
  // yt-dlp itself, as opposed to the wrapper: without it no fetch can run, so
  // the island swaps its body for the install prompt. The CLI answers the
  // check, since the shell has no PATH lookup of its own.
  property bool toolMissing: false
  // A playlist is a queue of single runs: each entry is one CLI call and one
  // file, while the batch writes a single folder history row. The queue lives
  // here because the island can close mid-way.
  property var queue: []
  property int queueTotal: 0
  property int queueDone: 0
  // The load the last finished download used. The island skips it when it reads
  // the clipboard on open: a link that was just downloaded is still very likely
  // what the clipboard holds, and reopening should not fetch it again.
  property string lastLoadUrl: ""
  // The last link the island filled from the clipboard by itself. Auto-paste
  // is a first-open convenience: doing it again on the next open with the
  // same clipboard is a loop, not a shortcut.
  property string lastAutoUrl: ""
  property string _queueLoadUrl: ""
  // The selector the batch was started with, applied to every entry.
  property string _queueFormat: ""
  // The folder the batch writes into, named after the playlist.
  property string _queueFolder: ""
  // The batch's quality label, so a second run of the same playlist at another
  // preset lands in its own folder instead of beside the first copy.
  property string _queueTag: ""
  // The engine the batch runs with. A playlist is media by definition.
  property string _queueTool: "yt-dlp"
  // Audio batches can carry cover art; the island asks for it explicitly.
  property bool _queueThumbnail: false

  function rememberSession(url, formats, preview, format, playlist,
    playlistTitle, checked, tool, kind, reason, engine) {
    if (!url || url === "") {
      root.forgetSession()
      return
    }
    root.sessionUrl = url
    root.sessionFormats = formats || []
    root.sessionPreview = preview || ({ title: "", thumbnail: "" })
    root.sessionFormat = format || ""
    root.sessionPlaylist = playlist || []
    root.sessionPlaylistTitle = String(playlistTitle || "")
    root.sessionPlChecked = checked || []
    root.sessionTool = String(tool || "auto")
    root.sessionKind = String(kind || "unknown")
    root.sessionReason = String(reason || "")
    root.sessionEngine = String(engine || "")
  }

  // Deleting an entry rewrites the history file, which the CLI owns. The rows
  // come back from a re-read rather than being spliced here, so what the table
  // shows is always what the file says.
  function deleteHistory(index, done) {
    const n = Number(index)
    const rows = () => done(root.reloadHistory())
    if (!isFinite(n) || n < 0) {
      rows()
      return
    }
    const job = Exec.runJob([root.cli, "--history-delete", String(n + 1)],
      "downloader", {
        timeoutMs: 15000,
        onFinished: rows,
        onFailed: rows
      })
    if (job === null) rows()
  }

  // Clear in the Recent table: the whole history goes, which is what the table
  // is. The rows come back from a re-read so the table says what the file does.
  function clearHistory(done) {
    const rows = () => done(root.reloadHistory())
    const job = Exec.runJob([root.cli, "--history-clear"], "downloader", {
      timeoutMs: 10000,
      onFinished: rows,
      onFailed: rows
    })
    if (job === null) rows()
  }

  function noteAutoLoaded(url) {
    root.lastAutoUrl = String(url || "")
  }

  function forgetSession() {
    root.sessionUrl = ""
    root.sessionFormats = []
    root.sessionPreview = ({ title: "", thumbnail: "" })
    root.sessionFormat = ""
    root.sessionPlaylist = []
    root.sessionPlaylistTitle = ""
    root.sessionPlChecked = []
    root.sessionTool = "auto"
    root.sessionKind = "unknown"
    root.sessionReason = ""
    root.sessionEngine = ""
  }

  FileView {
    id: historyProbe
    path: root.historyPath
    printErrors: false
  }

  FileView {
    id: playlistEntriesProbe
    path: root.playlistEntriesPath
    printErrors: false
  }

  function reloadPlaylistEntries() {
    playlistEntriesProbe.path = ""
    playlistEntriesProbe.path = root.playlistEntriesPath
    if (!playlistEntriesProbe.waitForJob()) return ""
    return playlistEntriesProbe.text()
  }

  function reloadHistory() {
    historyProbe.path = ""
    historyProbe.path = root.historyPath
    const rows = historyProbe.waitForJob()
      ? DL.attachPlaylistEntries(DL.parseHistory(historyProbe.text()),
        DL.parsePlaylistLedger(root.reloadPlaylistEntries()))
      : []
    root.probeMissing(rows)
    return rows
  }

  // One check for the whole history rather than one read per row: the paths
  // travel as arguments, so no shell quoting is involved and a path may hold
  // anything but a newline. The answer is the subset that is gone.
  function probeMissing(rows) {
    const paths = []
    const list = Array.isArray(rows) ? rows : []
    for (let i = 0; i < list.length; i++) {
      const row = list[i]
      const p = row && row.path ? String(row.path) : ""
      if (p !== "" && paths.indexOf(p) < 0) paths.push(p)
      if (!row || !DL.isPlaylistHistory(row)) continue
      const entries = Array.isArray(row.entries) ? row.entries : []
      for (let k = 0; k < entries.length; k++) {
        const ep = entries[k] && entries[k].path ? String(entries[k].path) : ""
        if (ep !== "" && paths.indexOf(ep) < 0) paths.push(ep)
      }
    }
    root.missingPaths = []
    if (paths.length === 0) return
    const job = Exec.runJob([root.cli, "--missing"].concat(paths),
      "downloader", {
        timeoutMs: 10000,
        onFinished: result => {
          const out = []
          const lines = String(result && result.stdout || "").split("\n")
          for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim()
            if (line !== "") out.push(line)
          }
          root.missingPaths = out
        },
        onFailed: () => { root.missingPaths = [] }
      })
    if (job === null) root.missingPaths = []
  }

  // Exit 0 is "the tool is there"; only the explicit 1 is "missing", so a
  // wrapper that could not run at all does not send the user to install a
  // package that would not fix it.
  function probeTool() {
    const job = Exec.runJob([root.cli, "--probe"], "downloader", {
      timeoutMs: 5000,
      onFinished: result => {
        const code = Number(result && (result.exitCode !== undefined
          ? result.exitCode : result.code))
        root.toolMissing = code === 1
      },
      onFailed: () => { root.toolMissing = false }
    })
    if (job === null) root.toolMissing = false
  }

  // The probe forks vb-util-download, so firing it from onCompleted contends
  // with the boot entrance the wallpaper fade, the bar slidefade and the
  // module flashes share. Hold it until that motion has finished drawing. The
  // island re-probes on every open, so a late answer costs no behavior.
  BootGate {
    until: "played"
    onFire: root.probeTool()
  }

  // What the dispatcher thinks the link is. The island shows the verdict and
  // uses it to decide whether a format table or a file card belongs on screen.
  function classify(url, done) {
    const empty = { kind: "unknown", engine: "", reason: "" }
    if (!url || url === "") {
      done(empty)
      return
    }
    const job = Exec.runJob([root.cli, "--classify", url], "downloader", {
      timeoutMs: 10000,
      onFinished: result => {
        const code = Number(result && (result.exitCode !== undefined
          ? result.exitCode : result.code))
        const line = String(result && result.stdout || "").trim()
        if (code !== 0 || line === "") {
          done(empty)
          return
        }
        const f = line.split("\t")
        done({ kind: f[0] || "unknown", engine: f[1] || "",
          reason: f[2] || "" })
      },
      onFailed: () => done(empty)
    })
    if (job === null) done(empty)
  }

  function loadInfo(url, done) {
    if (!url || url === "") {
      done([])
      return
    }
    const job = Exec.runJob([root.cli, "--info", url], "downloader", {
      timeoutMs: 30000,
      onFinished: result => {
        const code = Number(result && (result.exitCode !== undefined
          ? result.exitCode : result.code))
        const error = String(result && result.stderr || "").trim()
        done(code === 0 ? DL.pickableFormats(String(result.stdout || "")) : [],
          error)
      },
      onFailed: () => done([], "")
    })
    if (job === null) done([], "")
  }

  // A playlist's entries, from yt-dlp's flat listing: fast, and it names every
  // entry without extracting the videos themselves.
  function loadPlaylist(url, done) {
    if (!url || url === "") {
      done([], "")
      return
    }
    const job = Exec.runJob([root.cli, "--playlist-info", url],
      "downloader", {
        timeoutMs: 30000,
        onFinished: result => {
          const code = Number(result && (result.exitCode !== undefined
            ? result.exitCode : result.code))
          const text = String(result.stdout || "")
          done(code === 0 ? DL.playlistEntries(text) : [],
            code === 0 ? DL.playlistTitle(text) : "")
        },
        onFailed: () => done([], "")
      })
    if (job === null) done([], "")
  }

  // Runtime preview warmer, the MediaArt pattern: a hidden Image per URL
  // demanded by a visible surface. The island is transient, but this module is
  // not, so the decoded pixmap survives a close/reopen without a file cache.
  // A release drops the last demand, and no historical thumbnail outlives it.
  property var _previewDemands: ({})
  readonly property var previewWarmUrls: Object.keys(root._previewDemands)

  function requestPreview(url) {
    const want = String(url || "")
    if (want === "") return false
    const current = root._previewDemands[want]
    const next = Object.assign({}, root._previewDemands)
    next[want] = { url: want, refs: (current ? current.refs : 0) + 1 }
    root._previewDemands = next
    return true
  }

  function releasePreview(url) {
    const want = String(url || "")
    const current = root._previewDemands[want]
    if (!current) return false
    const next = Object.assign({}, root._previewDemands)
    if (current.refs <= 1) delete next[want]
    else next[want] = { url: want, refs: current.refs - 1 }
    root._previewDemands = next
    return true
  }

  function loadPreview(url, done) {
    if (!url || url === "") {
      done({ title: "", thumbnail: "" })
      return
    }
    const job = Exec.runJob([root.cli, "--preview", url], "downloader", {
      timeoutMs: 30000,
      onFinished: result => {
        const code = Number(result && (result.exitCode !== undefined
          ? result.exitCode : result.code))
        done(code === 0 ? DL.parsePreview(String(result.stdout || ""))
          : { title: "", thumbnail: "" })
      },
      onFailed: () => done({ title: "", thumbnail: "" })
    })
    if (job === null) done({ title: "", thumbnail: "" })
  }

  // The newest file the CLI wrote. The history is appended, so its last line is
  // the run that just finished.
  function latestSavedPath() {
    const rows = root.reloadHistory()
    for (let i = rows.length - 1; i >= 0; i--) {
      const path = rows[i] && rows[i].path ? String(rows[i].path) : ""
      if (path !== "") return path
    }
    return ""
  }

  // The completion card carries Open and Dismiss. Two actions are what make
  // the card draw buttons at all - the shell treats a lone action as the whole
  // card - and the sender blocks until the click, printing the chosen action
  // on stdout. The waiter is a plain Process rather than a registry job, the
  // same wiring the update-available card uses: the click channel is the
  // child's stdout, and nothing else here needs a job lifetime. The timeout is
  // generous because the card has to stay clickable, not just visible.
  //
  // force is the background path's answer to the island gate: a middle-click
  // download is announced even if the card was opened while it ran.
  function notifySaved(body, target, force) {
    if (root.islandOpen && force !== true) return
    // A missing target must be a plain notification. Testing `target === ""`
    // misses an omitted argument (`undefined`), which still produced two
    // buttons wired to the string "undefined" - actions that cannot work.
    const path = target === undefined || target === null ? "" : String(target)
    if (path === "") {
      Exec.notify("Downloader", body)
      return
    }
    if (openWaiter.running) return
    root._openTarget = path
    openWaiter.command = ["notify-send", "-a", "Vibranium", "-u", "normal",
      "-t", "30000", "-A", "open=Open", "-A", "dismiss=Dismiss",
      "Downloader", String(body)]
    openWaiter.running = true
  }

  // The bar's middle click is a background download from PRIMARY selection,
  // not the ordinary clipboard the island reads. That is a separate Wayland
  // selection, so it needs its own reader rather than Quickshell.clipboardText.
  function downloadFromPrimary() {
    if (root._primaryBusy) return
    if (root.downloading) {
      Exec.notify("Downloader", "A download is already running")
      return
    }
    root._primaryBusy = true
    const job = Exec.runJob(["wl-paste", "--primary", "--no-newline"],
      "downloader:primary", {
        timeoutMs: 3000,
        spawnWatchdogMs: 2000,
        onFinished: result => {
          root._primaryBusy = false
          if (!result || result.timedOut === true) {
            Exec.notify("Downloader", "Could not read the primary selection")
            return
          }
          const code = Number(result.exitCode !== undefined
            ? result.exitCode : result.code)
          if (code !== 0) {
            Exec.notify("Downloader", "Primary selection is not a link")
            return
          }
          root.downloadPrimaryLink(String(result.stdout || ""))
        },
        onFailed: () => {
          root._primaryBusy = false
          Exec.notify("Downloader", "Could not read the primary selection")
        }
      })
    if (job === null) {
      root._primaryBusy = false
      Exec.notify("Downloader", "Primary selection is not a link")
    }
  }

  function downloadPrimaryLink(text) {
    // Middle-click is not a paste: the whole selection has to be one link.
    // Scanning prose for the first URL would turn a sentence mentioning an
    // old link into a download nobody asked for.
    const url = DL.primaryLink(String(text || ""))
    if (url === "") {
      Exec.notify("Downloader", "Primary selection is not a link")
      return
    }
    if (root.downloading) {
      Exec.notify("Downloader", "A download is already running")
      return
    }
    // Any playlist link is a collection, including a watch link carrying
    // list= (the shape YouTube's share sheet produces). The queue path owns
    // it; a plain video keeps the ordinary single-run path below.
    if (DL.primaryRoute(url) === "playlist") {
      root.downloadPrimaryPlaylist(url)
      return
    }
    root.classify(url, verdict => {
      // Middle-click is the no-card shortcut. If auto cannot name a type, take
      // the File path instead of stopping on "unsure"; a link that classified
      // successfully still goes to its own engine. A playlist link is not
      // special here: the wrapper's default single-video run picks its video
      // at Best, so middle-click stays all-default.
      const tool = DL.primaryTool(verdict)
      if (root.downloading) {
        Exec.notify("Downloader", "A download is already running")
        return
      }
      const started = root.startDownload(url, "", tool, true)
      if (!started) {
        Exec.notify("Downloader", "Could not start the download")
        return
      }
      Exec.notify("Downloader", "Starting download: " + url)
    })
  }

  // Middle-clicking a playlist page has no card in which to tick entries, so
  // use the island's default: every listed entry, in order, at Best quality.
  // Each entry gets its own CLI run and file; the batch is one history row.
  function downloadPrimaryPlaylist(url) {
    if (root.downloading) {
      Exec.notify("Downloader", "A download is already running")
      return
    }
    if (typeof root.loadPlaylist !== "function") {
      Exec.notify("Downloader", "Could not read the playlist")
      return
    }
    if (root._primaryBusy) {
      Exec.notify("Downloader", "A download is already running")
      return
    }
    root._primaryBusy = true
    root.loadPlaylist(url, (entries, title) => {
      root._primaryBusy = false
      const list = Array.isArray(entries) ? entries : []
      const urls = []
      for (let i = 0; i < list.length; i++) {
        const entryUrl = String(list[i] && list[i].url || "").trim()
        if (entryUrl !== "") urls.push(entryUrl)
      }
      if (urls.length === 0) {
        Exec.notify("Downloader", "Could not read the playlist")
        return
      }
      if (root.downloading) {
        Exec.notify("Downloader", "A download is already running")
        return
      }
      const started = root.startPlaylist(urls, url, DL.qualitySelector("best"),
        String(title || ""), DL.qualityLabel("best"), "yt-dlp", false)
      if (!started) {
        Exec.notify("Downloader", "Could not start the download")
        return
      }
      Exec.notify("Downloader", "Starting playlist download: " + urls.length
        + (urls.length === 1 ? " video" : " videos"))
    })
  }

  // The path the card's Open action names. Kept beside the waiter so the
  // stdout handler does not have to close over the call that posted it.
  property string _openTarget: ""

  Process {
    id: openWaiter

    stdout: StdioCollector { id: openOut }
    onExited: {
      const choice = String(openOut.text || "").trim().toLowerCase()
      const target = root._openTarget
      root._openTarget = ""
      if (choice === "open" && target !== "") Exec.run(["xdg-open", target])
    }
  }

  // One CLI run. The queue repeats this, so the spawn, the cancel flag and the
  // failure text live here rather than in each caller.
  function runOne(url, format, done, folder, tag, tool, embedThumbnail,
    playlistUrl) {
    const token = ++root._runSeq
    root.downloading = true
    root._cancelled = false
    root.lastError = ""
    root.lastSavedPath = ""
    const argv = [root.cli]
    if (tool && tool !== "" && tool !== "auto") argv.push("--tool", tool)
    if (format && format !== "") argv.push("--format", format)
    if (folder && folder !== "") argv.push("--subdir", folder)
    if (tag && tag !== "") argv.push("--subdir-tag", tag)
    if (playlistUrl && playlistUrl !== "")
      argv.push("--playlist-history", playlistUrl)
    if (embedThumbnail === true) argv.push("--embed-thumbnail")
    argv.push(url)
    const job = Exec.runJob(argv, "downloader", {
      timeoutMs: 0,
      spawnWatchdogMs: 3000,
      onFinished: result => {
        if (token !== root._runSeq) return
        const cancelled = root._cancelled
        root._cancelled = false
        const code = Number(result && (result.exitCode !== undefined
          ? result.exitCode : result.code))
        // The error text lands before the busy flag drops: the island reads it
        // on that edge to tell a spent load from one worth reopening.
        if (code !== 0 && !cancelled) {
          root.lastError = String(result && result.stderr
            || "Download failed").trim()
        }
        // The island reads the saved path on the busy edge, so it has to land
        // before the flag drops - the same ordering the error text uses.
        if (code === 0 && !cancelled) root.lastSavedPath = root.latestSavedPath()
        root.downloading = false
        done(code === 0, cancelled)
      },
      onFailed: () => {
        if (token !== root._runSeq) return
        const cancelled = root._cancelled
        root._cancelled = false
        if (!cancelled) root.lastError = "Could not start the downloader"
        root.downloading = false
        done(false, cancelled)
      }
    })
    if (job === null) {
      root.downloading = false
      root.lastError = "Could not start the downloader"
      return false
    }
    return true
  }

  function failed() {
    Exec.notify("Downloader", "Download failed")
    // Nothing is on screen when the island is closed, so the bar says it
    // instead - the same way a link drop is announced.
    if (!root.islandOpen) root._flashFailure()
  }

  function startDownload(url, format, tool, background) {
    if (root.downloading || !url || url === "") return false
    root.queue = []
    root.queueTotal = 0
    root.queueDone = 0
    const started = root.runOne(url, format, (ok, cancelled) => {
      if (cancelled) return
      if (!ok) {
        root.failed()
        return
      }
      const path = root.lastSavedPath
      // The load is forgotten before the card is posted: nothing the notice or
      // the history probe does after this can leave the session behind. A
      // middle-click job belongs to the bar, not to a card that may be open on
      // another load, so it leaves that session alone.
      root.lastLoadUrl = url
      if (background !== true) root.forgetSession()
      const body = background === true && path !== ""
        ? "Downloaded " + DL.savedName(path) : "Download complete"
      root.notifySaved(body, path, background === true)
    }, "", "", tool)
    if (!started) root.lastError = root.lastError || "Could not start the downloader"
    return started
  }

  // A playlist is the same run repeated: each ticked entry is one CLI call, in
  // order, and every video lands on disk. The batch writes one folder history
  // row, so the queue passes its playlist URL to every run.
  function startPlaylist(urls, loadUrl, format, folder, tag, tool,
    embedThumbnail) {
    if (root.downloading) return false
    const list = []
    const src = Array.isArray(urls) ? urls : []
    for (let i = 0; i < src.length; i++) {
      const url = String(src[i] || "").trim()
      if (url !== "") list.push(url)
    }
    if (list.length === 0) return false
    root.queue = list
    root.queueTotal = list.length
    root.queueDone = 0
    root._queueLoadUrl = String(loadUrl || "")
    root._queueFormat = String(format || "")
    root._queueFolder = DL.folderName(folder)
    root._queueTag = String(tag || "")
    root._queueTool = String(tool || "yt-dlp")
    root._queueThumbnail = embedThumbnail === true
    return root.nextQueued()
  }

  function nextQueued() {
    if (root.queue.length === 0) {
      const total = root.queueTotal
      root.queueTotal = 0
      root.queueDone = 0
      root.downloading = false
      if (total > 0) {
        // A queue writes many files, but it has one folder. The completed card
        // opens that folder; the session goes first, for the same reason a
        // single download's does.
        root.lastLoadUrl = root._queueLoadUrl
        root.forgetSession()
        // The island is the surface when it is open: the queue line there
        // already says the batch finished, and a card would announce what the
        // user is looking at.
        if (!root.islandOpen) {
          root.notifySaved("Playlist downloaded - " + total
            + (total === 1 ? " video" : " videos"), root.lastSavedPath)
        }
      }
      return true
    }
    const url = String(root.queue[0])
    root.queue = root.queue.slice(1)
    const done = root.queueDone
    const started = root.runOne(url, root._queueFormat, (ok, cancelled) => {
      if (cancelled) {
        root.queue = []
        root.queueTotal = 0
        root.queueDone = 0
        return
      }
      root.queueDone = done + 1
      if (!ok) {
        root.queue = []
        root.queueTotal = 0
        root.queueDone = 0
        root.failed()
        return
      }
      root.nextQueued()
    }, root._queueFolder, root._queueTag, root._queueTool,
      root._queueThumbnail, root._queueLoadUrl)
    if (!started) {
      root.queue = []
      root.queueTotal = 0
      root.queueDone = 0
    }
    return started
  }

  // The error line is the module's, and the island is bound to it; the card
  // asks here for the one case it dismisses on its own (a cancellation the
  // next action answers) rather than writing a property it does not own.
  function clearError() {
    if (root.lastError !== "") root.lastError = ""
  }

  // The island's Cancel says so in place; a cancellation from the bar (right
  // click) has no island to say it in, but it is still not a failure, so no
  // notice is posted either way. A queue stops where it is.
  function cancelDownload() {
    if (!root.downloading) return
    // Invalidate the running callback before the process is killed: it may
    // still land after the next job has taken the busy flag.
    root._runSeq++
    root._cancelled = true
    root.queue = []
    root.queueTotal = 0
    root.queueDone = 0
    // Before the flag drops, so the island's edge handler reads the reason and
    // keeps the load reopenable.
    root.lastError = DL.cancelMessage()
    ProcessRegistry.cancelOwner("downloader")
    root.downloading = false
  }

  onClicked: mouse => {
    if (mouse.button === Qt.MiddleButton) {
      // Middle click is the no-card shortcut: read PRIMARY selection, classify
      // it, and start the same background job the island would.
      root.downloadFromPrimary()
      return
    }
    if (mouse.button === Qt.RightButton) {
      // Background cancel: the island can be closed mid-download, and the
      // bar is the only surface left to stop the job from.
      root.cancelDownload()
      return
    }
    root.openIsland()
  }

  // Hidden warmers share Qt's pixmap cache with the island's visible Image:
  // same URL and same 320x180 source size, so a reopen decodes nothing new.
  Repeater {
    model: root.previewWarmUrls

    Image {
      required property string modelData

      visible: false
      asynchronous: true
      cache: true
      sourceSize.width: 320
      sourceSize.height: 180
      source: modelData
    }
  }

  Icon {
    anchors.centerIn: parent
    name: "download-alt"
    colorKey: String(root.glyphColor)
  }

  // The bar carries the busy state only while the island is closed: with the
  // card open, its own progress line is where the job is reported, and a
  // second moving glyph behind it would be noise.
  IconSweep {
    anchors.centerIn: parent
    canvas: Bar.iconCanvas
    active: root.downloading && !root.islandOpen
  }

  Component {
    id: islandComp
    DownloaderIsland {
      downloading: root.downloading
      lastError: root.lastError
      clearError: root.clearError
      startDownload: root.startDownload
      classify: root.classify
      loadInfo: root.loadInfo
      loadPreview: root.loadPreview
      requestPreview: root.requestPreview
      releasePreview: root.releasePreview
      cancelDownload: root.cancelDownload
      reloadHistory: root.reloadHistory
      forgetHistory: root.deleteHistory
      initialUrl: root.sessionUrl
      initialFormats: root.sessionFormats
      initialPreview: root.sessionPreview
      initialFormat: root.sessionFormat
      initialTool: root.sessionTool
      initialKind: root.sessionKind
      initialReason: root.sessionReason
      initialEngine: root.sessionEngine
      initialSortKey: root.sortKey
      initialSortDir: root.sortDir
      missingFiles: root.missingPaths
      toolMissing: root.toolMissing
      probeTool: root.probeTool
      loadPlaylist: root.loadPlaylist
      startPlaylist: root.startPlaylist
      queueDone: root.queueDone
      queueTotal: root.queueTotal
      lastLoadUrl: root.lastLoadUrl
      lastAutoUrl: root.lastAutoUrl
      lastSavedPath: root.lastSavedPath
      noteAutoLoaded: root.noteAutoLoaded
      initialPlaylist: root.sessionPlaylist
      initialPlaylistTitle: root.sessionPlaylistTitle
      initialPlChecked: root.sessionPlChecked
      clearHistory: root.clearHistory
      remember: root.rememberSession
      rememberSort: root.rememberSort
    }
  }
  islandComponent: islandComp
}

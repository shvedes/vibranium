pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "ClipboardLib.js" as CL
import "../../common/text/UnitIpc.js" as UnitIpc

// Clipboard service in the shell's own process - no helper daemon. Fast
// in-memory history, image/credential/pinning/preview support; history
// persists as JSON under $VIBRANIUM_CACHE.
//
// Change detection is event-driven: one `wl-paste --watch` process fires
// only on real clipboard writes, and a slow reconciler covers the rare
// environments where events get lost. Zero idle process churn: no
// fixed-interval poller is kept alive.
//
// Every snapshot goes through _offer(), which keys content by hash. That
// single choke point gives: dedupe of identical copies, move-to-top on
// re-copy, and echo suppression for entries this shell itself put back
// on the clipboard while the mute window was open.
Singleton {
  id: root

  readonly property string tag: "clipboard"

  // SPLIT MAP (one owner each, no behavior change): History (newest-first
  // entries, persistence, factory, activate/pin/delete), ImageCache
  // (image pipeline, dimension probe, preview data), Search (mode +
  // search, change detection, filtering).
  // --- history ---
  // Newest first. Entry shape:
  // { id, ts, raw, mime, type, icon, title, subLeft, hay, words, pinned,
  //   preview, filePaths[], fileSize, totalSize, folderCount, foldersCount,
  //   allFolders, imageW, imageH, imageFile, imageDataFile,
  //   secretHandle, unavailable }
  // A secret entry holds no payload: raw is empty and the bytes live in
  // SecretStore under secretHandle. unavailable marks an imported cipher text
  // that no key could open, so the row stays visible but is not copyable.
  property var history: []
  property int nextId: 1
  // Short, curated ring - the manager is a hot-history scratchpad, not a
  // graveyard.
  property int maxHistory: 20

  // Snapshot + persistence live under $VIBRANIUM_CACHE so image previews
  // and the JSON history survive reboots together.
  property string cacheDir: ""
  readonly property string imgDir: root.cacheDir !== "" ? root.cacheDir + "/clipboard-img" : "/tmp/vibranium-clipboard-img"
  property int imgSeq: 0
  property string home: ""

  // --- mode / search ---
  // Reload survival for the view flags (memory-only, never disk):
  // bindings read through persist, imperative sets write back via
  // the change handlers below.
  PersistentProperties {
    id: persist
    reloadableId: "clipboard-visible"
    property bool visible: false
    property string query: ""
    property string mode: "normal"
  }
  property string query: persist.query
  property string mode: persist.mode // "normal" | "pinned" (@)
  readonly property bool showPinned: root.mode === "pinned"
  property var filtered: []
  property int matchedCount: 0

  // --- visibility / panels ---
  property bool visible: persist.visible
  readonly property bool open: root.visible
  property var _panels: []
  // Token for the exclusive-surface claim this open holds, released by
  // hidePanel() and by Component.onDestruction.
  property var _claimToken: null
  onVisibleChanged: persist.visible = visible
  onQueryChanged: persist.query = query
  onModeChanged: persist.mode = mode

  function _attachPanel(p) {
    const n = root._panels.slice()
    n.push(p)
    root._panels = n
  }
  function _detachPanel(p) {
    root._panels = root._panels.filter(x => x !== p)
  }

  readonly property int totalCount: root.history.length
  readonly property int pinnedCount: {
    let c = 0
    for (let i = 0; i < root.history.length; i++)
      if (root.history[i].pinned) c++
    return c
  }
  readonly property int normalCount: root.history.length - root.pinnedCount

  // Readiness, as one word with a meaning rather than a hopeful name.
  //
  // There is no `ready` flag in this file and there does not need to be one:
  // the singleton is constructed synchronously and `_load()` runs inside
  // Component.onCompleted, so by the time anything can read the panel the
  // history is already loaded. What is genuinely not settled at that moment
  // is the WATCHER: `watchBackoff` holds `watchProc` back 1500ms, and until
  // that child is up the only signal is the slow reconciler. A panel that
  // renders empty because nothing has been captured yet is indistinguishable
  // from one that renders empty because the watcher never started - so the
  // two facts are logged, once each, rather than carried in a boolean nobody
  // reads.
  //
  // `_loadDone` is the load verdict; `_watchStarted` the watcher verdict.
  property bool _loadDone: false
  property bool _watchStarted: false

  Component.onCompleted: {
    orphanReap.running = true
    Registry.offer("clipboard", {
      title: "Clipboard",
      description: "clipboard history manager",
      verbNames: [
        "clear",
        "close",
        "copy",
        "list",
        "open",
        "pin",
        "remove",
        "toggle",
        "view",
        "status",
        "help",
        "ping",
      ]
    })
    root.home = Quickshell.env("HOME")
    CL.setHome(root.home)
    // VIBRANIUM_CACHE is normally exported by the uwsm env file; a bare
    // session (or a misconfigured one) may leave it unset. Falling back to
    // /tmp put the history on tmpfs, which is wiped on every reboot and
    // silently dropped every pinned (and unpinned) entry with it. Resolve the
    // same persistent location the env file would have chosen instead.
    const _cacheHome = Quickshell.env("VIBRANIUM_CACHE")
      || ((Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/vibranium")
    root.cacheDir = _cacheHome + "/clipboard"
    bootInit.running = true
    root._load()
    // Directory and file mode are asserted before the first write, so the
    // history never exists at a wider mode even for the first payload.
    historyDirProc.command = CL.buildEnsurePrivateDirsCmd(root.cacheDir, root.imgDir)
    root._permStartedAt = Date.now()
    historyDirProc.running = true
    historyPermWatch.restart()
    // Adopt whatever is on the clipboard right now instead of waiting
    // for the first slow tick - a copy made during shell startup must
    // land without a five-second hole.
    root.queuePoll()
    watchBackoff.restart() // starts watchProc after a short settle
  }

  // Credential bytes, the in-flight copy child, and the store slots a history
  // row points at are all released here; the singleton dying takes its child
  // Process objects with it.
  Component.onDestruction: {
    copyTimeout.stop()
    if (copyProc.running) copyProc.running = false
    copyProc._sink = null
    root._suppressSecret = ""
    root._forgetAllSecrets()
    SurfaceClaim.releaseOwner(root)
  }

  // Snapshot dir is persistent (history is), so no wipe - just parent dirs.
  Process {
    id: bootInit
    command: CL.buildMkdirCmd(root.imgDir, root.cacheDir)
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: root._sweepOrphanSnapshots()
  }

  Process {
    id: orphanReap

    // One-shot: kill watchers orphaned by pre-fix generations (bare
    // kill/pkill leaves wl-paste reparented). Matches only our own
    // __vc__ protocol string, never a generic wl-paste.
    command: CL.buildOrphanReapCmd()
  }

  // --- persistence ---
  // History survives as JSON under $VIBRANIUM_CACHE: {version, entries:[...]}.
  // No credential payload and no cipher key is written: a key beside its own
  // ciphertext protects nothing, and a memory-only store cannot be persisted
  // honestly, so a captured secret lives for the session that captured it.
  // Native FileView keeps the JSON always in memory, no `cat` spawn.

  FileView {
    id: clipboardFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    }
  function _historyPath() { return root.cacheDir + "/clipboard.json" }
  function _load() {
    // Native read - no `cat` shell
    clipboardFile.path = ""
    clipboardFile.path = root._historyPath()
    let ok = clipboardFile.waitForJob()
    let jsonText = ok ? String(clipboardFile.text()) : ""
    // Whether the document was JSON at all is a question the library does not
    // answer, and the difference matters: parseHistoryDocument returns an empty
    // entry list both for a file that would not parse and for a file that held
    // no entries, and those are a first boot and a lost history respectively.
    // The parse is tried here - the library still decides the shape, and its
    // answer is what the shell runs on.
    const parsed = root._stateParses(jsonText)
    root._reconstruct(jsonText, ok && !parsed, jsonText.trim() !== "", ok)
  }
  // Would this state document parse as JSON? A pure predicate over a string,
  // which is what makes it testable without a live session and without a
  // filesystem - and it is deliberately NOT the library's `parseHistoryDocument`,
  // which answers the shape question and swallows this one.
  //
  // An empty document answers true. That is not a claim that "" is JSON: it is
  // the statement "there was nothing to misparse", which is the case where the
  // question does not arise and where the caller's `present` flag has already
  // said everything.
  function _stateParses(text) {
    const body = String(text === null || text === undefined ? "" : text).trim()
    if (body === "") return true
    try { JSON.parse(body); return true } catch (error) { return false }
  }

  function _reconstruct(text, unparsed, present, readOk) {
    const doc = CL.parseHistoryDocument(text)
    const arr = doc.entries
    const fileKey = doc.key
    // Corrupt-but-present must never persist: the empty parse above would
    // otherwise clobber the file with an empty document. Keep in-memory
    // history, report once, and leave the node alone.
    if (present && unparsed) {
      root._loadDone = true
      root._notify("Clipboard", "History file was corrupt - keeping current history")
      return
    }
    if (!arr || arr.length === 0) {
      root._loadDone = true
      // A failed read must never clobber the file with emptiness: persist
      // only what was actually observed, so a transient read failure keeps
      // its history instead of replacing it with an empty document.
      if (readOk) root._persist()
      return
    }
    const hist = []
    let stranded = 0
    for (let i = 0; i < arr.length; i++) {
      const o = arr[i]
      const isSecret = o.type === "secret"
      const id = o.id || root.nextId
      let raw = ""
      let secretHandle = ""
      let unavailable = false
      if (isSecret) {
        // Import read: decode once into the memory-only store, then let
        // the cipher text die with the next write. A row no key can open
        // keeps its metadata but no payload, and becomes copyable again only
        // if the credential is captured afresh.
        const held = o.raw
        const ciphered = held && typeof held === "object" && typeof held.ciphered === "string"
          ? held.ciphered : ""
        const clear = held === undefined || held === null || typeof held === "object"
          ? "" : String(held)
        const plain = ciphered !== ""
          ? (fileKey === "" ? "" : CL.decryptSecret(ciphered, fileKey))
          : clear
        if (plain !== "") {
          secretHandle = root._secretHandleFor(id)
          SecretStore.stash(secretHandle, plain)
        } else {
          unavailable = ciphered !== "" || clear !== ""
          if (unavailable) stranded++
        }
      } else {
        raw = String(o.raw == null ? "" : o.raw)
      }
      // For preview of secrets, never expose plain
      const previewVal = isSecret ? "" : String(o.preview == null ? raw : o.preview)
      const e = {
        id: id, ts: o.ts || Date.now(), raw: raw,
        mime: o.mime || "text/plain", type: o.type || "text",
        pinned: o.pinned === true, filePaths: o.filePaths || [],
        imageFile: o.imageFile || "", imageDataFile: o.imageDataFile || "",
        imageSha: o.imageSha || "", fileSize: o.fileSize, totalSize: o.totalSize, folderCount: o.folderCount,
        foldersCount: o.foldersCount || 0, allFolders: o.allFolders === true,
        imageW: o.imageW || 0, imageH: o.imageH || 0,
        folderItems: o.folderItems, pathLike: false,
        // Persisted folder payload, validated back to absent on anything
        // but a plain object - presence is the verdict, so shape is the
        // only thing left to check. A hand-edited document must never
        // paint rows from a misshapen value.
        git: (o.git && typeof o.git === "object" && !Array.isArray(o.git)) ? o.git : null,
        missing: o.missing === true,
        missingText: String(o.missingText == null ? "" : o.missingText),
        icon: "", title: "", subLeft: "", hay: "", words: [],
        preview: previewVal, secretHandle: secretHandle, unavailable: unavailable
      }
      CL.deriveEntry(e, TimeFormat.use12h)
      hist.push(e)
      if (e.id >= root.nextId) root.nextId = e.id + 1
    }
    // Pinned-first trim: pinned rows survive reload even past the cap, the
    // unpinned tail fills what is left.
    const _pinned = hist.filter(e => e.pinned === true)
    const _unpinned = hist.filter(e => e.pinned !== true)
    root.history = _pinned.concat(_unpinned.slice(0, Math.max(0, root.maxHistory - _pinned.length)))
    root._recompute()
    // Re-probe any images that lost dimensions (0) - e.g. after GIF height bug
    // - and revalidate persisted folder payloads in the background, so a new
    // session never presents yesterday's branch as today's fact. The cached
    // rows stay up until the fresh verdict lands.
    for (let i = 0; i < root.history.length; i++) {
      const en = root.history[i]
      if (en.type === "image" && (en.imageW === 0 || en.imageH === 0)) {
        Qt.callLater(() => root._probeDims(en.id))
      }
      if (en.type === "folder" && en.git) {
        Qt.callLater(() => root._prefetchGit(en.id))
      }
    }
    // The rewrite drops the beside-stored key and every cipher text it
    // opened, which is the point: the new file carries no key at all.
    root._persist()
    if (stranded > 0) {
      root._notify("Clipboard", stranded + " stored credential(s) had no usable key and were dropped")
    }
    root._loadDone = true
  }

  function _secretHandleFor(id) { return "clipboard:" + id }

  function _forgetEntrySecret(e) {
    if (e && e.secretHandle) SecretStore.drop(e.secretHandle)
  }
  function _forgetAllSecrets() {
    const h = root.history
    for (let i = 0; i < h.length; i++) SecretStore.drop(String(h[i].secretHandle || ""))
  }

  function _exportEntries() {
    return CL.exportEntries(root.history)
  }

  property bool _saveDirty: false
  property string _pendingPayload: ""
  property bool _saving: false
  // Released by historyPermProc; until then every write is held back so the
  // file is never created at a wider mode than 0600.
  property bool _historyPermReady: false
  // Latched when a mode bound expired without a confirmed mode, so the
  // degraded state is reported once rather than once per retry.
  property bool _historyPermDegraded: false
  // Start stamp for the mode-assertion chain. `double` because a 32-bit int
  // cannot hold `Date.now()`.
  property double _permStartedAt: 0

  // FileView writes through the process umask, so a file it creates is
  // world-readable until something narrows it - a window in which the whole
  // history is exposed. install(1) sets the mode on the node it creates, so
  // the file appears at 0600 and an existing wider file is narrowed before any
  // byte is written. install and chmod ship in the same coreutils package, so
  // this step cannot vanish the way a missing helper binary would.
  Process {
    id: historyDirProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      historyPermProc.command = ["install", "-m", "0600", "--", "/dev/null", root._historyPath()]
      root._permStartedAt = Date.now()
      historyPermProc.running = true
    }
  }
  Process {
    id: historyPermProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    // A zero exit is what asserts the mode. A failed run leaves the node at
    // its current mode, so a non-zero exit cannot open the gate either.
    onExited: (exitCode, exitStatus) => {
      if (exitCode !== 0) return
      historyPermWatch.stop()
      root._historyPermReady = true
      Qt.callLater(() => root._flushPersist())
    }
  }
  // Bounded retry: a helper that never reports an exit, or reports a failure,
  // leaves the mode unasserted, and a write through it would create the file at
  // the umask default. The payload is held instead of written, and the
  // assertion is re-driven so a transient failure is not permanent. An attempt
  // still in flight keeps running: a slow install gets the full interval again
  // rather than being killed and restarted, which would keep a slow helper from
  // ever reaching its own exit.
  // Permission-watch cadence, named: re-drives the mode assertion
  // every 5s until the history file's mode confirms.
  readonly property int historyPermWatchMs: 5000
  Timer {
    id: historyPermWatch
    interval: root.historyPermWatchMs
    repeat: true
    onTriggered: {
      if (root._historyPermReady) { historyPermWatch.stop(); return }
      if (!root._historyPermDegraded) {
        root._historyPermDegraded = true
        root._notify("Clipboard", "History file mode unconfirmed - saving is held until it is set")
      }
      // The retry re-stamps the chain, so the eventual exit reports the time of
      // THIS attempt and not the time of the first one twenty seconds ago.
      if (!historyDirProc.running && !historyPermProc.running) {
        root._permStartedAt = Date.now()
        historyDirProc.running = true
      }
      historyPermWatch.restart()
    }
  }
  function _flushPersist() {
    const payload = root._pendingPayload
    if (payload === "") return
    root._pendingPayload = ""
    root._writeHistory(payload)
  }
  function _persist() {
    if (root.cacheDir === "") return
    probePersistTimer.stop()
    root._pendingPayload = JSON.stringify({ version: 2, entries: _exportEntries() })
    // Held, not lost: the payload is parked in `_pendingPayload` and written
    // the moment `install` reports its exit.
    if (!root._historyPermReady) return
    root._flushPersist()
  }
  // Probe verdicts (dimensions, file sizes, git) re-derive on demand, so a
  // selection sweep parking them one by one must not sync-stringify and
  // sync-write the whole file per row. They park behind a trailing 2s
  // window instead; captures and deletes keep the immediate _persist above.
  // A crash inside the window only loses re-derivable verdicts, and hiding
  // the panel flushes whatever is still parked.
  Timer {
    id: probePersistTimer
    interval: 2000
    repeat: false
    onTriggered: root._persist()
  }
  function _persistSoon() {
    if (root.cacheDir === "") return
    probePersistTimer.restart()
  }
  function _writeHistory(payload) {
    if (_saving) { _saveDirty = true; root._pendingPayload = payload; return }
    _saving = true
    // Native FileView write - no `cat`/`printf` shell, always in memory.
    // atomicWrites replaces the node with the writer's own temp file, whose
    // mode this process does not control, so the mode is asserted again for
    // every replace rather than only for the create.
    clipboardFile.path = root._historyPath()
    clipboardFile.setText(payload)
    // The scheduling gate, not the verdict: it is true for a save that then
    // fails, so it says whether the chmod below was started and nothing more.
    const ok = clipboardFile.waitForJob()
    if (ok) {
      chmodProc.command = CL.buildHistoryModeCmd(root._historyPath())
      chmodProc.running = true
    }
    // The gate releases here, not on the chmod: without the reset only the
    // first save of the session ever reached disk and every later capture
    // parked in _pendingPayload forever - a restart then came back empty.
    _saving = false
    if (_saveDirty) {
      // The coalesced case: a write arrived while one was in flight, so the
      // payload in hand is already stale and is replaced immediately after.
      _saveDirty = false
      const p = root._pendingPayload
      root._pendingPayload = ""
      if (p !== "" && p !== payload) root._writeHistory(p)
    }
  }
  Process {
    id: chmodProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
  }

  // --- open / close ---
  // IPC verbs are named open/close/toggle, but a readonly bool property
  // `open` exists on this singleton too (view bindings read it), and the
  // property shadows same-name methods at call sites. Everything routes
  // through uniquely-named internals so no caller ever crosses that gap.
  function showPanel() {
    if (root.visible) return
    root.query = ""
    root.mode = "normal"
    root.visible = true
    // Claimed once the panel is up, not before: the stored closer is
    // hidePanel, which refuses to run while `visible` is false, so a claim
    // taken earlier would install a closer that provably does nothing and
    // leave a claim nobody can retire if _recompute throws.
    root._claimToken = SurfaceClaim.claim("clipboard", root.hidePanel, root)
    root._recompute()
    root.queuePoll() // catch writes missed while closed
  }
  function hidePanel() {
    if (!root.visible) return
    if (probePersistTimer.running) { probePersistTimer.stop(); root._persist() }
    root.visible = false
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
  }
  // One guard for every path that can empty the list: an open panel with
  // nothing left to show closes itself. Single deletes, clearAll (IPC and
  // UI alike) and any future drain funnel through here instead of each
  // repeating the check.
  function _hideIfEmpty() {
    if (root.visible && root.filtered.length === 0) root.hidePanel()
  }
  function open() { root.showPanel(); return true }
  function close() { root.hidePanel(); return true }
  function toggle() { root.visible ? root.hidePanel() : root.showPanel() }

  // --- search / mode ---
  function submit(text) {
    const t = String(text || "")
    if (t.length > 0 && t.charAt(0) === "@") {
      root.mode = "pinned"
      root.query = t.substring(1).trimStart()
    } else if (root.mode === "pinned") {
      root.query = t
    } else {
      root.mode = "normal"
      root.query = t
    }
    root._recompute()
  }
  function enterPinned(payload) {
    root.mode = "pinned"
    root.query = String(payload || "").trim()
    root._recompute()
  }
  function exitPinned() {
    root.mode = "normal"
    root.query = ""
    root._recompute()
  }
  // Returns true when the escape was consumed by a state rollback;
  // the panel closes only on false.
  function clearQuery() {
    if (root.query !== "") {
      root.query = ""
      root._recompute()
      return true
    }
    if (root.mode === "pinned") {
      root.exitPinned()
      return true
    }
    return false
  }
  function stepBack() {
    if (root.query !== "") {
      root.query = ""
      root._recompute()
      return
    }
    if (root.mode === "pinned") root.exitPinned()
  }

  function _recompute() {
    const list = CL.selectEntries(root.history, root.mode, root.query)
    root.filtered = list
    root.matchedCount = list.length
  }
  // React to the shell's 12/24-hour switch without a reboot: re-derive every
  // entry's timeStr so the displayed times follow the new format live.
  Connections {
    target: TimeFormat
    function onUse12hChanged() {
      const h = root.history.slice()
      for (let i = 0; i < h.length; i++) {
        if (h[i]) h[i] = CL.deriveEntry(h[i], TimeFormat.use12h)
      }
      root.history = h
      root._recompute()
    }
  }

  // --- pin / delete ---
  function togglePinAt(index) {
    const list = root.filtered
    if (index === null || index === undefined || index < 0 || index >= list.length) return false
    root.togglePin(list[index].id)
    return true
  }
  function togglePin(id) {
    let wasPinned = false
    let slot = -1
    const h = root.history.slice()
    for (let i = 0; i < h.length; i++) {
      if (h[i].id === id) {
        wasPinned = h[i].pinned === true
        slot = i
        h[i] = Object.assign({}, h[i], { pinned: !h[i].pinned })
        break
      }
    }
    // A miss persists nothing: the panel and the IPC verb can both name a
    // row another path removed first, and that must not rewrite the file.
    if (slot < 0) return
    root.history = h
    root._recompute()
    // Only a row that was actually found gets a line. An id no longer in
    // history still falls through this function, because the panel and the
    // IPC verb can both name a row another path removed first.
    //
    // The slot is the entry's POSITION, not its id: pinning flips a flag and
    // does not reorder, so the index the loop found is the one the line names.
    // An id would be the more stable handle and is not used, because the id is
    // derived from the payload and this feature's rule is that no log line
    // carries clipboard content - a digest of it is still a handle on it.
    if (slot >= 0) {
      if (wasPinned) {
        Log.info("unpinned entry " + slot + ", total pinned " + root.pinnedCount)
      } else {
        Log.info("pinned entry " + slot + " (" + String(h[slot].mime) + "), total pinned " + root.pinnedCount)
      }
      // The record behind the slot is the half neither pin line carries, and
      // the two lines are not symmetrical: the pin names the mime and the unpin
      // does not, so a row pinned and unpinned across a session correlates by
      // slot number alone. The mime is repeated here for exactly that reason
      // and bounded with `summarize`, because it is client data and this
      // feature's rule admits it only the way it admits an app name.
      //
      // `type` is the shell's own classification word, and it is one of the few
      // things a clipboard log line may carry: the shell's own classification
      // word, a size, a count, a slot number and a bounded client string, and
      // nothing derived from the payload. `type` describes a row without
      // describing what is in it, and it is the field that separates a folder
      // row from a file row advertising the same `text/uri-list`. The row count
      // rides along because `total pinned` counts keeps rather than rows, so
      // the cap is the only thing that says how much room the ring has left.
      const d = Log.at()
      if (d.allows("debug")) {
        d.debug("entry " + slot + ": type " + String(h[slot].type)
          + ", " + Log.summarize(String(h[slot].mime))
          + ", " + root.totalCount + " of " + root.maxHistory + " rows")
      }
    }
    // If we just unpinned the last pinned entry while in pinned mode, exit it
    if (wasPinned && root.pinnedCount === 0 && root.showPinned) {
      root.mode = "normal"
      root.query = ""
      root._recompute()
    }
    root._persist()
  }
  // Triple-buffered deletion via OptimisticSet (K3)
  property OptimisticSet optimistic: OptimisticSet {}
  function findById(id) {
    const h = root.history
    for (let i = 0; i < h.length; i++)
      if (h[i].id === id) return h[i]
    return null
  }
  function requestDelete(id) {
    if (root.optimistic.isPending(id)) return false
    const entry = root.findById(id)
    if (!entry) return false
    // Keep captured for stage 2 check - store in a separate map
    if (!root._captured) root._captured = ({})
    root._captured[id] = entry
    root.optimistic.mark(id)
    Idle.run(() => root.commitDelete(id), 2)
    return true
  }
  function commitDelete(id) {
    if (!root.optimistic.isPending(id)) return
    const captured = root._captured ? root._captured[id] : null
    if (!captured) { root.finishDelete(id); return }
    // Entry replaced or gone between stages - abort safely.
    if (root.findById(id) !== captured) { root.finishDelete(id); return }
    const h = root.history.slice()
    let idx = -1
    for (let i = 0; i < h.length; i++)
      if (h[i].id === id) { idx = i; break }
    if (idx < 0) { root.finishDelete(id); return }
    // Captured BEFORE the splice, because after it `h[idx]` is the row that moved
    // into that slot.
    const gone = h[idx]
    root._purgeEntries([gone])
    h.splice(idx, 1)
    root.history = h
    root._recompute()
    // A pinned row and an ordinary one are not the same deletion. Pinning is
    // a deliberate keep, so losing one is worth naming on its own terms, and
    // the pinned total is the number of deliberate keeps left. Neither line
    // carries content: the slot is a position and the totals are counts.
    if (gone.pinned === true) {
      Log.info("cleared pinned entry " + idx + ", total pinned " + root.pinnedCount)
    } else {
      Log.info("cleared entry " + idx + ", total " + root.totalCount)
    }
    // Both clear lines name a slot and one total; the record that left is what
    // neither can, and it is the half that matters once the row is gone.
    // `type` is the classification word, and it is one of the few things a
    // clipboard log line may carry: the shell's own classification word, a
    // size, a count, a slot number and a bounded client string, and nothing
    // derived from the payload. `type` describes a row and not what is in it,
    // and it is what says whether this
    // delete also released a session snapshot under the cache or a credential
    // store slot. `bytes` is the size that went, hidden for a credential
    // because even a length is a hint about its value: `_entryBytes` answers 0
    // for one, and "0" is a true statement about the stored row and a false one
    // about the bytes that were copied, so the distinction has to be made where
    // the line is built rather than inside the helper.
    //
    // The size on the left of the arrow is the array the splice ran against,
    // and `+ 1` is that row: `total` is read after the reassignment, so the
    // INFO above gives the after and nothing places it against the cap. The
    // gate wraps `_entryBytes` because a suppressed line must not ask.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("cleared entry " + idx + ": type " + String(gone.type)
        + ", bytes " + (gone.type === "secret" ? "hidden" : String(root._entryBytes(gone)))
        + ", " + (root.totalCount + 1) + " -> " + root.totalCount
        + " of " + root.maxHistory)
    }
    root._persist()
    // The panel closing itself here is a real transition: the last row went,
    // the panel went with it.
    root._hideIfEmpty()
    Qt.callLater(() => root.finishDelete(id))
  }
  property var _captured: ({})
  function finishDelete(id) {
    root.optimistic.confirm(id)
    if (root._captured) {
      const n = Object.assign({}, root._captured)
      delete n[id]
      root._captured = n
    }
    root._dropPreviewData([{ id: id }])
    // Pinned mode with nothing pinned left goes back to normal only
    // after the model commit, never during the click that started it.
    if (root.showPinned && root.pinnedCount === 0) {
      root.mode = "normal"
      root.query = ""
      root._recompute()
    }
    // Selection repair belongs to the owning panel, after commit.
    for (let i = 0; i < root._panels.length; i++) {
      const p = root._panels[i]
      if (p && typeof p.onDeleteCommitted === "function") p.onDeleteCommitted(id)
    }
  }
  // Lift an entry to the most-recent slot (used when it is re-copied).
  function _promote(id) {
    const h = root.history.slice()
    let idx = -1
    for (let i = 0; i < h.length; i++)
      if (h[i].id === id) { idx = i; break }
    if (idx < 0) return
    if (idx === 0) {
      // Still refresh timestamp so timeStr updates and persistence reorders.
      const e0 = Object.assign({}, h[0], { ts: Date.now() })
      h[0] = CL.deriveEntry(e0, TimeFormat.use12h)
      root.history = h
      root._recompute()
      root._persist()
      return
    }
    const e = Object.assign({}, h[idx], { ts: Date.now() })
    h.splice(idx, 1)
    h.unshift(CL.deriveEntry(e, TimeFormat.use12h))
    root.history = h
    root._recompute()
    root._persist()
  }
  // Pinned entries survive a clear - they are deliberate, not detritus.
  function clearAll() {
    const removed = []
    const kept = []
    for (let i = 0; i < root.history.length; i++) {
      if (root.history[i].pinned) kept.push(root.history[i])
      else removed.push(root.history[i])
    }
    root._purgeEntries(removed)
    root.history = kept
    root._recompute()
    // Deliberately bare. A clear is one act by the user whatever it removed,
    // and the two counts that would say more - how many rows went, how many
    // pinned rows survived - are already implied by `total` and `total pinned`
    // on the delete lines. A bulk line repeating them would be the same fact
    // twice in two vocabularies.
    Log.info("cleared clipboard")
    // A bulk clear fires no delete lines, so the counts that line above
    // deliberately leaves out are not implied here by anything - nothing else
    // prints when a row goes, and this is the only record of the event. What it
    // owes a reader is therefore the ledger of what the clear released rather
    // than the totals again: the type mix, because 23 text rows and 23 image
    // rows cost the same number of captures and a completely different number
    // of files under the cache; the snapshot bytes those files held; and how
    // many credential store slots were dropped, which is the one figure here a
    // length could never stand in for.
    //
    // One pass builds both tallies and a second sums the sizes, so the gate is
    // not decoration - a suppressed line must not walk `removed` at all.
    const d = Log.at()
    if (d.allows("debug")) {
      const mix = ({})
      let slots = 0
      for (let i = 0; i < removed.length; i++) {
        const e = removed[i]
        const t = String(e.type)
        mix[t] = mix[t] === undefined ? 1 : mix[t] + 1
        if (String(e.secretHandle || "") !== "") slots++
      }
      const kinds = Object.keys(mix).sort()
      let shape = ""
      for (let i = 0; i < kinds.length; i++)
        shape += (i > 0 ? ", " : "") + kinds[i] + " " + mix[kinds[i]]
      d.debug("cleared clipboard: " + removed.length + " of "
        + (removed.length + kept.length) + " rows dropped (" + shape + "), "
        + kept.length + " pinned kept, snapshot bytes "
        + root._snapshotBytes(removed) + ", credential slots dropped " + slots)
    }
    root._persist()
    root._hideIfEmpty()
  }

  // --- activate (put back on clipboard, or open files) ---
  // File-backed rows open in their default app instead of re-copying:
  // a copied file's whole point is the path, and re-copying it when the
  // user wanted to look at it is the extra step. Everything else keeps
  // the copy behaviour.
  function activateAt(index) {
    const list = root.filtered
    if (index < 0 || index >= list.length) return
    const entry = list[index]
    // Enter copies the selected content back (promoting it to the top) instead
    // of opening a file/folder in its default app.
    root.copyEntry(entry)
    root.hidePanel()
  }

  // Never carries a value: only counts and fixed phrases reach it.
  function _notify(summary, body) {
    Exec.run(["notify-send", "-r", "3", "-t", "3000", "-a", "Vibranium",
      summary, body])
  }

  property bool _muting: false
  // Echo-mute window after a self-copy: our own wl-copy write would
  // otherwise come back through the watcher as a new entry. Named so no
  // bare interval survives (see the interval-naming rule).
  readonly property int echoMuteMs: 1200
  Timer { id: muteTimer; interval: root.echoMuteMs; onTriggered: root._muting = false }

  // Re-copy executor. The argv carries flags and the mime type only; a
  // payload arrives on the child's write channel, so a credential is never a
  // command line and never inside a shell source string.
  //
  // Feed signal: onStarted feeds stdin at once. The started signal is the
  // authoritative feed, and a timed re-feed would only race the signal that
  // already won. The copy deadline below is the
  // one timer left - a child that never finishes reading is killed and
  // the slot released.
  Process {
    id: copyProc
    property var _sink: null
    property bool _fed: false
    stdinEnabled: false
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onStarted: root._feedCopyStdin()
    onExited: (exitCode, exitStatus) => {
      copyTimeout.stop()
      copyProc._sink = null
      pendingCopyTimer.restart()
    }
  }
  // Copy deadline: a child that never finished reading its stdin would
  // hold the credential in the store slot forever; kill it and release
  // the slot. Named, single-shot, the one timer on this path.
  readonly property int copyDeadlineMs: 5000
  Timer {
    id: copyTimeout
    interval: root.copyDeadlineMs
    repeat: false
    onTriggered: {
      if (copyProc.running) copyProc.running = false
      copyProc._sink = null
      pendingCopyTimer.restart()
      root._notify("Clipboard", "Copy timed out")
    }
  }

  // One write, one close. Process maps stdinEnabled=false onto
  // QProcess::closeWriteChannel(), and that EOF is mandatory rather than
  // cosmetic: wl-copy buffers stdin into a temp file and claims the
  // selection only after that read completes, so a pipe left open leaves the
  // clipboard unserved.
  function _feedCopyStdin() {
    if (copyProc._fed || !copyProc.running) return
    const sink = copyProc._sink
    if (typeof sink !== "function") return
    copyProc._fed = true
    try { sink() } catch (ignored) { }
    copyProc.stdinEnabled = false
  }

  // sink is a closure that writes straight into the child: a payload never
  // becomes a return value a caller could hold on to.
  function _startCopy(argv, sink) {
    if (copyProc.running) return false
    copyProc._sink = typeof sink === "function" ? sink : null
    copyProc._fed = false
    copyProc.stdinEnabled = copyProc._sink !== null
    copyProc.command = argv
    copyProc.running = true
    copyTimeout.restart()
    return true
  }

  // Pending-copy window: paths a copy is still serving stay queued this
  // long before the snapshot flush reaps them. Named, single-shot.
  readonly property int pendingCopyWindowMs: 5000
  Timer {
    id: pendingCopyTimer
    interval: root.pendingCopyWindowMs
    repeat: false
    onTriggered: {
      root._pendingCopyPaths = []
      root._flushPendingPurgePaths()
      root.queueFlush()
    }
  }

  function copyEntry(entry) {
    if (!entry) return
    // A credential is reached through its store handle and nothing else: the
    // value materialises inside the stdin write and the slot is gone by the
    // time this function returns, so no plan, argv, or DTO ever holds it.
    let secretHandle = ""
    if (entry.type === "secret") {
      secretHandle = String(entry.secretHandle || "")
      if (secretHandle === "" || !SecretStore.has(secretHandle)) {
        root._notify("Clipboard", "Credential unavailable - copy it again from its source")
        return
      }
    }
    // Validate before mutating: a copy already in flight rejects here, with
    // no promote and no mute window, so the rejected copy leaves history
    // exactly as it found it.
    if (copyProc.running) {
      root._notify("Clipboard", "Copy already in progress")
      return
    }
    // An image row with no file behind it has nothing to offer: reject
    // before the promote below moves it.
    if (entry.type === "image" && !entry.imageDataFile && !entry.imageFile) return
    let cmdArr = null
    let sink = null
    if (entry.type === "secret") {
      cmdArr = CL.buildCopySecretCmd()
      sink = () => SecretStore.feed(secretHandle, v => copyProc.write(v))
    } else if (entry.type === "network") {
      const rawNet = String(entry.raw || "")
      // Preserve uri-list for network storage (ftp/sftp/smb etc.)
      let uris = rawNet
      if (entry.filePaths && entry.filePaths.length > 0) {
        const nets = entry.filePaths.filter(p => CL.isNetworkUri(p))
        if (nets.length > 0) uris = nets.join("\n")
        else uris = entry.filePaths.join("\n")
      }
      // Use text/uri-list for network URIs, fall back to text/plain
      if (uris.indexOf("://") >= 0) {
        cmdArr = CL.buildCopyUriListCmd()
        sink = () => copyProc.write(uris)
      } else {
        cmdArr = CL.buildCopyTextCmd()
        sink = () => copyProc.write(uris)
      }
    } else if (entry.type === "text" || entry.type === "url") {
      cmdArr = CL.buildCopyTextCmd()
      sink = () => copyProc.write(String(entry.raw || ""))
    }
    else if (entry.type === "image" && entry.imageDataFile && !entry.imageFile) cmdArr = CL.buildCopyImageDataCmd(entry.mime, entry.imageDataFile)
    else if ((entry.type === "file" || entry.type === "folder"
        || entry.type === "archive" || entry.type === "files"
        || entry.type === "folders")) {
      const uris = (entry.filePaths || []).map(p => CL.toFileUri(p)).join("\n")
      cmdArr = CL.buildCopyUrisCmd(uris)
    } else if (entry.type === "image" && entry.imageFile) cmdArr = CL.buildCopyImageFileCmd(entry.imageFile)
    else return
    // Copying from the history is an implicit "use" - bring the row back
    // to the most-recent slot and persist, so it sits at the top on the
    // next launch even though our own echo suppression swallows the
    // clipboard event that would otherwise do it.
    root._promote(entry.id)
    // Text- and URI-family re-copies are hash-predictable: suppress our
    // own echo exactly. A credential keeps only its handle here and is
    // matched in place inside the store, so the copied bytes never become a
    // long-lived property.
    root._suppressHash = ""
    root._suppressSecret = ""
    if (entry.type === "image" && entry.imageDataFile && !entry.imageFile) {
      root._suppressHash = "uri:" + CL.toFileUri(entry.imageDataFile)
    } else if (entry.type === "image" && entry.imageFile) {
      root._suppressHash = "uri:" + CL.toFileUri(entry.imageFile)
    } else if (entry.filePaths && entry.filePaths.length > 0) {
      root._suppressHash = "uri:" + entry.filePaths.join("|")
    } else if (secretHandle !== "") {
      root._suppressSecret = secretHandle
    } else {
      root._suppressHash = "text:" + String(entry.raw || "")
    }
    root._muting = true
    muteTimer.restart()

    root._pendingCopyPaths = CL.entryPaths(entry)
    pendingCopyTimer.restart()
    if (!root._startCopy(cmdArr, sink)) {
      // Raced start: the early running check above passed but the child
      // started between the check and the start. The promote already ran,
      // so this only notifies.
      root._notify("Clipboard", "Copy already in progress")
      return
    }
  }

  // Re-serve a freshly captured row so this shell owns the system selection
  // from now on. Silent where copyEntry notifies: an external copy arriving
  // while another copy is in flight simply keeps its original owner rather
  // than popping a warning. Secrets are skipped - a credential source owns
  // its own lifetime and the shell must not prolong it.
  function _takeOwnership(id) {
    if (copyProc.running) return
    const entry = root.findById(id)
    if (!entry || entry.type === "secret" || entry.unavailable === true) return
    if (entry.type === "image" && !entry.imageDataFile && !entry.imageFile) return
    let cmdArr = null
    let sink = null
    if (entry.type === "network") {
      const rawNet = String(entry.raw || "")
      let uris = rawNet
      if (entry.filePaths && entry.filePaths.length > 0) {
        const nets = entry.filePaths.filter(p => CL.isNetworkUri(p))
        if (nets.length > 0) uris = nets.join("\n")
        else uris = entry.filePaths.join("\n")
      }
      if (uris.indexOf("://") >= 0) {
        cmdArr = CL.buildCopyUriListCmd()
        sink = () => copyProc.write(uris)
      } else {
        cmdArr = CL.buildCopyTextCmd()
        sink = () => copyProc.write(uris)
      }
    } else if (entry.type === "text" || entry.type === "url") {
      cmdArr = CL.buildCopyTextCmd()
      sink = () => copyProc.write(String(entry.raw || ""))
    } else if (entry.type === "image" && entry.imageDataFile && !entry.imageFile) {
      cmdArr = CL.buildCopyImageDataCmd(entry.mime, entry.imageDataFile)
    } else if ((entry.type === "file" || entry.type === "folder"
        || entry.type === "archive" || entry.type === "files"
        || entry.type === "folders")) {
      const uris = (entry.filePaths || []).map(p => CL.toFileUri(p)).join("\n")
      cmdArr = CL.buildCopyUrisCmd(uris)
    } else if (entry.type === "image" && entry.imageFile) {
      cmdArr = CL.buildCopyImageFileCmd(entry.imageFile)
    } else {
      return
    }
    // Hash-predictable echo suppression for the serve, same shape as a
    // manual re-copy, so the watcher's echo of our own serve is swallowed
    // instead of duplicating the row it just stored.
    root._suppressHash = ""
    if (entry.type === "image" && entry.imageDataFile && !entry.imageFile) {
      root._suppressHash = "uri:" + CL.toFileUri(entry.imageDataFile)
    } else if (entry.type === "image" && entry.imageFile) {
      root._suppressHash = "uri:" + CL.toFileUri(entry.imageFile)
    } else if (entry.filePaths && entry.filePaths.length > 0) {
      root._suppressHash = "uri:" + entry.filePaths.join("|")
    } else {
      root._suppressHash = "text:" + String(entry.raw || "")
    }
    root._muting = true
    muteTimer.restart()
    root._pendingCopyPaths = CL.entryPaths(entry)
    pendingCopyTimer.restart()
    root._startCopy(cmdArr, sink)
  }

  // --- clipboard change detection ---
  // Watch is the primary signal; the slow reconciler is a seatbelt.
  property string _lastHash: ""
  property string _suppressHash: ""
  // Echo arm for a credential copy: a store handle, never the bytes.
  property string _suppressSecret: ""
  property var _currentPaths: []
  property bool _currentPathsKnown: false
  property int _clipboardGeneration: 0
  property int _clearGeneration: -1
  property var _pendingSnapshotEntries: []
  property var _pendingCopyPaths: []
  // Slow safety net behind the watcher's event signal: parked while
  // the watcher is healthy (running:false), one poll per minute when it
  // is down. The signal does the work; the timer only catches a dead
  // watcher. Named, repeat, 60s backstop.
  readonly property int reconcileBackstopMs: 60000
  Timer {
    id: reconcileTimer
    interval: root.reconcileBackstopMs
    repeat: true
    // Fallback polls while the watcher is down; one-shot replay of a
    // raced poll otherwise. A healthy idle watcher parks the timer
    // instead of waking every 5 seconds for two false conditions.
    //
    // The park condition has to be a property this file declares. A condition
    // over two undeclared properties reads `undefined` for both, `!undefined`
    // is `true`, and the timer never parks: a `wl-paste --list-types` is
    // forked every five seconds for the life of the shell, forever, which is
    // the process churn this singleton exists to have removed. A comment
    // describing an intent the code does not implement is what makes such a
    // loop read as deliberate.
    //
    // `_watchStarted` is the real signal: set in `onStarted`, cleared in
    // `onExited`. The watcher being up is what parks the timer, and the
    // event-driven path is the one that carries the clipboard.
    running: !root._watchStarted
    onTriggered: root._poll()
  }

  Process {
    id: watchProc
    running: false
    command: CL.buildWatchCmd()
    stdout: SplitParser {
      onRead: data => {
        // One `__vc__` per clipboard write. A continuous line, so it goes
        // through trace with the message deferred: the signal fires on every
        // copy the user makes anywhere on the desktop, and building a string
        // for each one is the cost trace exists to avoid. What it says is the
        // transition - the write happened - and nothing about what was
        // written; the payload is read by a different child entirely.
        if (data.trim() === "__vc__") root.queuePoll()
      }
    }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      // The watcher is the only EVENT source this service has; the reconciler
      // below is the seatbelt.
      root._watchStarted = false
      watchBackoff.restart() // crash/no-display recovery, damped
    }
    onStarted: root._watchStarted = true
  }
  Timer {
    id: watchBackoff
    interval: 1500
    repeat: false
    onTriggered: watchProc.running = true
  }

  function _poll() {
    root._reapRead()
    if (listProc.running || root._readProc !== null || uriProc.running) return
    listProc.command = CL.buildListTypesCmd()
    listProc.running = true
  }

  // Coalesced defers: N triggers in one turn run one _poll / one flush.
  // The pending flags do the coalescing (a second request while one is
  // queued is free); Idle.run is only the turn boundary, so the storm of
  // per-event defers collapses into one ordered call each.
  property bool _pollQueued: false
  property bool _flushQueued: false
  function queuePoll() {
    if (root._pollQueued) return
    root._pollQueued = true
    Idle.run(() => { root._pollQueued = false; root._poll() }, 0, 0, "clipboard:poll")
  }
  function queueFlush() {
    if (root._flushQueued) return
    root._flushQueued = true
    Idle.run(() => { root._flushQueued = false; root._flushPendingSnapshots() }, 0, 0, "clipboard:flush")
  }

  Process {
    id: listProc
    running: false
    stdout: StdioCollector { id: listOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) root._onListTypes(String(listOut.text))
    }
  }

  function _onListTypes(text) {
    // Which of the three read routes a paste takes is the library's rule;
    // this file owns only which route runs the child.
    const offer = CL.parseTypeList(text)
    const types = offer.types
    uriProc._types = types
    if (offer.hasUri) {
      uriProc.command = CL.buildPasteUriListCmd()
      uriProc.running = true
      return
    }
    if (offer.hasImage) {
      root._setCurrentPaths([])
      root._pollImage(offer.imageType)
      return
    }
    root._startRead(types)
  }

  // A text read owns its process and its collector for exactly one read.
  // wl-paste hands a credential over in clear, and a collector left attached
  // to a long-lived process keeps those bytes for the rest of the session:
  // destroying the process destroys the collector with it, and the value moves
  // into SecretStore or dies with the read.
  property var _readProc: null
  Component {
    id: readProcComp
    Process {
      id: pasteProc
      property var types: []
      stdout: StdioCollector { id: pasteOut }
      stderr: StdioCollector {}
      onExited: (exitCode, exitStatus) => {
        const text = exitCode === 0 ? String(pasteOut.text) : ""
        root._readProc = null
        destroy()
        root._onReadText(text, pasteProc.types)
      }
    }
  }
  function _startRead(types) {
    if (root._readProc !== null) return false
    const proc = readProcComp.createObject(root, { types: types })
    if (proc === null) return false
    root._readProc = proc
    proc.command = CL.buildPasteTextCmd()
    proc.running = true
    return true
  }
  // A child that never started reports no exit at all, so a read handle that
  // owns no live process is released here instead of parking the poll loop.
  function _reapRead() {
    const proc = root._readProc
    if (proc === null) return
    try {
      if (proc.running === true) return
    } catch (ignored) {
    }
    root._readProc = null
    try { proc.destroy() } catch (ignored) { return }
  }

  function _offer(hash, buildFn) {
    if (hash === "") return
    if (hash === root._lastHash) {
      // Identical content again: a watcher event plus a reconciler tick both
      // see the same selection.
      return
    }
    if (root._suppressHash !== "" && hash === root._suppressHash) {
      // Our own re-copy echoed back. Swallow it once, then disarm so an
      // external copy of genuinely identical content still lands later.
      root._suppressHash = ""
      root._lastHash = hash
      return
    }
    if (root._suppressSecret !== "" && hash.indexOf("text:") === 0
      && SecretStore.matchesValue(root._suppressSecret, hash.substring(5))) {
      // The credential echo arrives as the same bytes we just wrote; the
      // comparison happens inside the store so they are never re-parked.
      root._suppressSecret = ""
      root._lastHash = hash
      return
    }
    root._lastHash = hash
    // The mute window: the copy this shell made is still settling, so
    // anything arriving now is presumed to be its echo.
    if (root._muting) return
    const entry = buildFn()
    if (!entry) return
    const live = root._addEntry(entry)
    // Take ownership of the fresh capture so the content stays pasteable
    // after the source app closes. Wayland drops the selection with its
    // owner; without this the shell only stored the bytes and the user had
    // to re-select the row manually to paste again.
    if (live) Qt.callLater(() => root._takeOwnership(live.id))
  }

  function _onReadText(text, types) {
    root._setCurrentPaths([])
    const seen = types || []
    // The same predicate detectType() uses, so a paste cannot be read as a
    // credential and then typed as anything else.
    const isSecret = CL.isCredentialMimeTypes(seen)
    const t = String(text || "")
    if (t === "") return
    const imgPath = isSecret ? "" : CL.textImagePath(t, root.home)
    if (imgPath !== "") {
      root._setCurrentPaths([imgPath])
      root._completePendingCopy([imgPath])
    }
    root._offer("text:" + t, () => {
      // A bare path to an image file pasted as text behaves like a real
      // image copy: full preview and image title semantics.
      if (imgPath !== "") {
        const e = root._buildEntry(t, CL.mimeForExt(imgPath), "image",
          [imgPath], "")
        e.imageFile = imgPath
        const eid = e.id
        Qt.callLater(() => {
          root._probeDims(eid)
          root._probeFileInfo(eid, [imgPath])
        })
        return e
      }
      const type = isSecret ? "secret" : CL.detectType(seen, t, [])
      // For network storage URIs, keep the URI in filePaths for consistent title/preview handling
      let fps = []
      let preview = isSecret ? "" : t
      if (type === "network") {
        const nets = CL.extractNetworkUris(t)
        if (nets.length > 0) fps = nets
        else fps = [t]
        preview = fps[0] || t
      }
      // A credential row is built empty and reaches SecretStore by handle:
      // raw stays "", so no projection, model, or export can carry the value.
      const e = root._buildEntry(isSecret ? "" : t, seen.length > 0 ? seen[0] : "text/plain",
        type, fps, preview)
      if (isSecret) {
        e.secretHandle = root._secretHandleFor(e.id)
        SecretStore.stash(e.secretHandle, t)
      }
      return e
    })
  }

  Process {
    id: uriProc
    property var _types: []
    running: false
    stdout: StdioCollector { id: uriOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) root._onReadUri(String(uriOut.text))
    }
  }

  function _onReadUri(text) {
    const paths = CL.parseUriList(text)
    root._setCurrentPaths(paths)
    root._completePendingCopy(paths)
    const netUris = CL.extractNetworkUris(text)
    if (netUris.length > 0 && paths.length === 0) {
      // Pure network storage URIs (ftp/sftp/smb/nfs etc.) - keep as network type
      root._offer("uri:" + netUris.join("|"), () => {
        const e = root._buildEntry(String(text).trim(), "text/uri-list", "network", netUris, netUris[0] || "")
        e.filePaths = netUris.slice()
        return e
      })
      return
    }
    if (paths.length === 0) {
      // uri-list held only remote links or nothing - fall through to text.
      // A second read route for one copy costs a whole extra wl-paste.
      root._startRead(uriProc._types || [])
      return
    }
    root._offer("uri:" + paths.join("|"), () => {
      let type
      if (paths.length === 1) {
        if (CL.isImageExt(paths[0])) type = "image"
        else if (CL.isArchive(paths[0])) type = "archive"
        else type = "file" // stat probe corrects folder-vs-file
      } else {
        type = "files"
      }
      const e = root._buildEntry(String(uriOut.text).trim(),
        "text/uri-list", type, paths,
        paths.length === 1 ? CL.homeTilde(paths[0]) : "")
      if (type === "image") e.imageFile = paths[0]
      // Deferred metadata: sizes/folder anatomy always; dimensions for
      // image files. IDs are stable so late patches land correctly.
      const eid = e.id
      Qt.callLater(() => {
        root._probeFileInfo(eid, paths)
        if (type === "image") root._probeDims(eid)
      })
      return e
    })
  }

  // --- entry factory ---
  // Single place where a JS payload becomes a fully derived row so every
  // creator shares identical field hygiene (and patch sites re-run it).
  function _buildEntry(raw, mime, type, filePaths, preview) {
    const e = CL.newEntry(root.nextId++, Date.now(), raw, mime, type, filePaths, preview)
    return CL.deriveEntry(e, TimeFormat.use12h)
  }

  // Copy-on-write history mutation helper. Reassigning the array property
  // fires exactly one change notification per probe completion.
  function _patch(id, mutate) {
    const prevLen = root.history.length
    // -> Capture pinning before mutation for the payload-only gate below.
    let oldPinned = null
    // -> Capture derived display text so a payload-only probe that changes
    // -> visible row text still recomputes below.
    let oldTitle = ""
    let oldSubLeft = ""
    let oldTimeStr = ""
    let oldIcon = ""
    let oldGit = ""
    for (let i = 0; i < root.history.length; i++) {
      if (root.history[i].id === id) {
        oldPinned = root.history[i].pinned === true
        oldTitle = String(root.history[i].title || "")
        oldSubLeft = String(root.history[i].subLeft || "")
        oldTimeStr = String(root.history[i].timeStr || "")
        oldIcon = String(root.history[i].icon || "")
        try { oldGit = JSON.stringify(root.history[i].git ?? null) } catch (e) { oldGit = "" }
        break
      }
    }
    const h = root.history.slice()
    let newPinned = oldPinned
    let newTitle = oldTitle
    let newSubLeft = oldSubLeft
    let newTimeStr = oldTimeStr
    let newIcon = oldIcon
    let newGit = oldGit
    for (let i = 0; i < h.length; i++) {
      if (h[i].id !== id) continue
      const e = Object.assign({}, h[i])
      mutate(e)
      h[i] = CL.deriveEntry(e, TimeFormat.use12h)
      newPinned = h[i].pinned === true
      newTitle = String(h[i].title || "")
      newSubLeft = String(h[i].subLeft || "")
      newTimeStr = String(h[i].timeStr || "")
      newIcon = String(h[i].icon || "")
      try { newGit = JSON.stringify(h[i].git ?? null) } catch (e) { newGit = "" }
      break
    }
    root.history = h
    // -> Gate: empty query plus unchanged row count/pinning/display text
    // -> means the payload-only probe moved no membership and changed no
    // -> visible text, so skip the full filter reinstall; counts and
    // -> visible rows stay exact. The git verdict feeds the preview card
    // -> (not the row text), so its change must reinstall too - otherwise
    // -> a revalidation that only adds e.g. the author email would leave
    // -> the preview bound to the stale entry object.
    if (String(root.query || "").trim() === ""
      && h.length === prevLen && newPinned === oldPinned
      && newTitle === oldTitle && newSubLeft === oldSubLeft
      && newTimeStr === oldTimeStr && newIcon === oldIcon
      && newGit === oldGit) return
    root._recompute()
  }

  // --- image pipeline ---
  // Snapshot -> (size+sha1 in one pass) -> offer(content-hash key).
  // Unique destination per copy means history previews never mutate under
  // existing entries; sha keys make repeated copies of identical bytes
  // dedupe instead of piling up.
  function _pollImage(mime) {
    // The snapshot is busy, so this image copy is not read at all and there is
    // no entry for it.
    if (imagePipeProc.running || dimProc.running) return
    root.imgSeq++
    root._pendingMime = mime
    root._pendingPath = CL.snapshotPath(root.imgDir, Date.now(), root.imgSeq, mime)
    imagePipeProc.command = CL.buildImageSnapshotCmd(mime, root._pendingPath)
    imagePipeProc.running = true
  }

  property string _pendingMime: ""
  property string _pendingPath: ""
  property var dimQueue: []

  // Every reason a snapshot does not become an entry funnels here, so the
  // one file a capture wrote is unlinked on all of them - a short read, an
  // unusable report, our own echo, and a duplicate of bytes already held.
  function _discardPendingSnapshot() {
    if (root._pendingPath === "") return
    root._enqueueRmPaths([root._pendingPath])
  }

  // One fused flight: write the snapshot, size it, hash it, and print
  // "<size> <sha>" (or EMPTY when wl-paste came up short). A single
  // process keeps ordering trivial and makes failures diagnosable - a
  // chained second Process never fired reliably here.
  Process {
    id: imagePipeProc
    running: false
    stdout: StdioCollector { id: pipeOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const out = String(pipeOut.text).trim()
      if (out === "EMPTY" || exitCode !== 0) {
        root._discardPendingSnapshot()
        return
      }
      // First line: size from stat, second line: "sha  path" from sha1sum
      const report = CL.parseSnapshotOutput(out)
      if (report === null) {
        root._discardPendingSnapshot()
        return
      }
      const sz = report.size
      const sha = report.sha
      const hash = "img:" + sha + ":" + sz
      // Echo suppression / muting / duplicate hash - just record and cleanup
      if (hash === root._lastHash) {
        root._discardPendingSnapshot()
        return
      }
      if (root._suppressHash !== "" && hash === root._suppressHash) {
        root._suppressHash = ""
        root._lastHash = hash
        root._discardPendingSnapshot()
        return
      }
      if (root._muting) {
        root._lastHash = hash
        root._discardPendingSnapshot()
        return
      }
      // History duplicate - same bytes already stored (opening clipboard re-snapshots same image)
      for (let i = 0; i < root.history.length; i++) {
        const h = root.history[i]
        if (h.type === "image" && h.imageSha === sha && h.fileSize === sz) {
          // Re-copying bytes already held: the row is lifted, not duplicated,
          // and the snapshot file this flight wrote is thrown away.
          root._lastHash = hash
          root._promote(h.id)
          root._discardPendingSnapshot()
          return
        }
      }
      root._offer(hash, () => {
        const e = root._buildEntry("image:" + root._pendingPath,
          root._pendingMime, "image", [], "")
        e.imageDataFile = root._pendingPath
        e.imageSha = sha
        e.fileSize = sz
        const eid = e.id
        Qt.callLater(() => root._probeDims(eid))
        return CL.deriveEntry(e, TimeFormat.use12h)
      })
    }
  }

  function _probeDims(id) {
    if (id < 0) return
    let p = ""
    const h = root.history
    for (let i = 0; i < h.length; i++)
      if (h[i].id === id) { p = h[i].imageDataFile || h[i].imageFile || ""; break }
    if (p === "") return
    if (dimProc.running) {
      // Queued, not dropped: the dimensions still land, one probe behind.
      if (root.dimQueue.indexOf(id) < 0) root.dimQueue = root.dimQueue.concat([id])
      return
    }
    dimProc._id = id
    dimProc.command = CL.buildDimCmd(p)
    dimProc.running = true
  }
  function _dequeueDim() {
    if (root.dimQueue.length === 0) return
    const next = root.dimQueue[0]
    root.dimQueue = root.dimQueue.slice(1)
    // Defer to avoid reentrancy with onExited
    Qt.callLater(() => root._probeDims(next))
  }

  // --- dimension probe (ImageMagick ships in vb-base.pkgs) ---
  // Header-only read: cheap even for giant screenshots.
  Process {
    id: dimProc
    property int _id: -1
    running: false
    stdout: StdioCollector { id: dimOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const dims = CL.parseDimOutput(dimOut.text)
      if (dims !== null) {
        root._patch(dimProc._id, e => {
          e.imageW = dims.w
          e.imageH = dims.h
        })
        // Probe patches park behind the persist window, so dimensions
        // survive a restart instead of re-probing every boot.
        root._persistSoon()
      }
      Qt.callLater(() => root._dequeueDim())
    }
  }

  // --- filesystem probe for URI entries ---
  // One bounded find pass per folder (timeout 10, -xdev, awk-summed to
  // "<count> <bytes>"); plain files stat. TOOBIG past 20000 files skips the
  // sum so a huge walk can never wedge the probe. The shell emits
  // DIR/FILE/MISSING chunks; the JS side aggregates sizes.
  function _probeFileInfo(id, paths) {
    if (!paths || paths.length === 0) return
    // A `find` pass per folder, and folders can be enormous - a home directory
    // copied as a URI is a multi-minute walk.
    fileInfoProc.command = CL.buildFileInfoCmd(paths)
    fileInfoProc._id = id
    fileInfoProc.running = true
  }

  Process {
    id: fileInfoProc
    property int _id: -1
    running: false
    stdout: StdioCollector { id: fileInfoOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      // The row keeps its pending shape when the report named nothing, which
      // renders as a file row with no size at all.
      root._onFileInfo(fileInfoProc._id, String(fileInfoOut.text).trim())
    }
  }

  function _onFileInfo(id, out) {
    // The DIR/FILE/MISSING chunks arrive here. The aggregation is the library's; the one piece
    // of controller state it needs is whether the row it would patch is
    // still in history, which decides the unlabelled single-path fallback.
    const report = CL.parseFileInfoReport(out, root.findById(id) !== null)
    if (report === null) return
    root._patch(id, e => { CL.projectFileInfo(e, report) })
    // Probe patches park behind the persist window, so a folder verdict
    // survives a restart instead of re-walking every boot.
    root._persistSoon()
    // A fresh folder verdict also arms the background git prefetch, so the
    // repo rows are already there on first open instead of arriving a probe
    // late. Best-effort: selection-time probing covers whatever it misses.
    root._prefetchGit(id)
  }

  // --- preview data hub ---
  // Lazy preview payloads keyed by entry id, computed when the panel
  // selects a row. Only one probe family remains (text-ish files, with a
  // wish id so a newer selection preempts the running one). GIF/kapot,
  // videos and folder listings were deemed not worth their probe cost.
  property var previewData: ({})   // id -> {kind, ..., done}

  function _pdPut(id, payload) {
    const pd = Object.assign({}, root.previewData)
    pd[id] = payload
    root.previewData = pd
  }

  function _pathForId(id) {
    const h = root.history
    for (let i = 0; i < h.length; i++) {
      if (h[i].id !== id) continue
      return h[i].filePaths && h[i].filePaths.length === 1 ? h[i].filePaths[0] : ""
    }
    return ""
  }

  function requestPreviewData(id, entry) {
    if (!entry || id === undefined || id < 0) return
    const have = root.previewData[id]
    // Already computed: fires on every selection change, and the panel re-asks
    // for a row it already has whenever the model swaps.
    if (have !== undefined && have.done) return
    const p = _pathForId(id)
    // Images/URLs/text preview from the entry alone; nothing to spawn.
    if (p === "" || (entry.type !== "file" && entry.type !== "folder")) {
      _pdPut(id, { kind: "inline", done: true })
      return
    }
    // A folder serves its persisted payload straight off the entry: no
    // probe, no previewData growth. Absent payload probes on demand (and
    // the boot revalidation covers the rest).
    if (entry.type === "folder") {
      if (p.charAt(0) !== "/") {
        _pdPut(id, { kind: "inline", done: true })
        return
      }
      // Payloads without the author-email field carry no `cemail` key:
      // treat them as absent so the selection reprobes instead of serving
      // the stale verdict forever.
      const gp = entry.git
      const missingEmail = gp !== undefined && gp !== null && typeof gp === "object" && !("cemail" in gp)
      if (!missingEmail && gp !== undefined && gp !== null) return
      _wishGit(id, p)
      return
    }
    // A file row is the only one that spawns anything else, and it is a
    // real child process per selection.
    _wishMedia(id, p)
  }

  // ---- text-ish files: libmagic binary sniff + capped head dump ----
  Process {
    id: textProc
    property int _id: -1
    running: false
    stdout: StdioCollector { id: textOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      // The head dump this child produces IS file content, so nothing here
      // prints it - not the bytes, not the sniffed mime, not the first line of
      // the dump. `superseded` says the answer arrived after the cursor had
      // already moved on, which is why nothing was stored.
      const mine = textProc._id === root._tWish
      if (mine) {
        const raw = String(textOut.text)
        const head = CL.parseTextProbeOutput(raw)
        const isText = head.mime !== "" && head.mime !== "binary" && CL.isTextMime(head.mime)
        root._pdPut(textProc._id,
          isText
            ? { kind: "textfile", content: head.body, done: true }
            : { kind: "binary", done: true })
      }
      if (root._tWish >= 0 && root._tWish !== textProc._id)
        root._launchTextFor(root._tWish)
    }
  }
  property int _tWish: -1

  function _wishText(id, p) {
    root._tWish = id
    if (!textProc.running) root._launchTextFor(id)
  }
  function _launchTextFor(id) {
    const p = root._pathForId(id)
    if (p === "") {
      root._pdPut(id, { kind: "inline", done: true })
      return
    }
    textProc._id = id
    textProc.command = CL.buildTextProbeCmd(p)
    textProc.running = true
  }

  // ---- media files: mediainfo card (mp3/flac/mp4/... ) ----
  Process {
    id: mediaProc
    property int _id: -1
    running: false
    stdout: StdioCollector { id: mediaOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (mediaProc._id === root._mWish) {
        const rc = mediaProc.exitCode
        // rc 1 is NOT a failure: mediainfo reports 1 for a format it cannot
        // describe, and the summary card is the designed answer.
        if (rc === 1) {
          // no mediainfo binary, or extension not media -> summary card
          const p = root._pathForId(mediaProc._id)
          root._pdPut(mediaProc._id, { kind: "mediainfo", mi: null, done: true, summary: CL.buildMediaSummary(p) })
        } else {
          const mi = CL.parseMediaInfo(String(mediaOut.text))
          // mediainfo ran but could not parse -> summary card too
          root._pdPut(mediaProc._id, mi !== null
            ? { kind: "mediainfo", mi: mi, done: true }
            : { kind: "mediainfo", mi: null, done: true, summary: CL.buildMediaSummary(root._pathForId(mediaProc._id)) })
        }
      }
      Qt.callLater(() => root._dequeueMedia())
    }
  }
  property int _mWish: -1
  property var _mediaQueue: []

  function _wishMedia(id, p) {
    if (!CL.isMediaPath(p)) {
      root._wishText(id, p)
      return
    }
    root._mWish = id
    if (!mediaProc.running) root._launchMediaFor(id)
  }
  function _launchMediaFor(id) {
    const p = root._pathForId(id)
    if (p === "") {
      root._pdPut(id, { kind: "inline", done: true })
      return
    }
    mediaProc._id = id
    mediaProc.command = CL.buildMediaInfoCmd(p)
    mediaProc.running = true
  }
  function _dequeueMedia() {
    if (mediaProc.running || root._mediaQueue.length === 0) return
    const id = root._mediaQueue.shift()
    if (id === root._mWish) root._launchMediaFor(id)
  }

  // ---- folders: git repo card (branch, status, commit) ----
  // Probed in the background at capture time (see _onFileInfo) so the rows
  // are already there on first open; a selection that arrives before the
  // prefetch lands (or for a row captured before this existed) falls back
  // to the same wish path. Single-flight with a FIFO behind it: the wish
  // always jumps the queue, prefetch results are stored either way, and a
  // non-repo stores an inline verdict so the row is never re-probed.
  Process {
    id: gitProc
    property int _id: -1
    running: false
    stdout: StdioCollector { id: gitOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const completed = gitProc._id
      // Positive verdicts land on the entry itself and persist with it, so
      // the rows are already there on first open - and after a restart. A
      // miss leaves a session memo instead: re-probing a non-repo on every
      // focus would be pure cost, while persisting the negative would hide
      // a repo created later. Either way an entry that left history
      // mid-probe stores nothing - its purge already dropped it.
      const e = completed >= 0 ? root.findById(completed) : null
      if (e !== null && e.type === "folder") {
        const g = CL.parseGitInfoOutput(String(gitOut.text))
        if (g !== null) {
          root._patch(completed, x => { x.git = g })
          root._persistSoon()
          if (completed === root._gWish) root._gWish = -1
        } else {
          root._pdPut(completed, { kind: "inline", done: true })
        }
      }
      root._pumpGit()
    }
  }
  property int _gWish: -1
  // Capture-time backlog behind the single flight. Bounded by folder
  // captures, which are rare next to selections; entries that left
  // history are skipped at drain time rather than at enqueue time.
  property var _gitPrefetchQueue: []

  // One arbiter for the single flight: a live selection wish first,
  // queued prefetches behind it. No-op while a probe runs or nothing
  // is owed.
  function _pumpGit() {
    if (gitProc.running) return
    const w = root._gWish
    if (w >= 0 && root.findById(w) !== null) {
      const whave = root.previewData[w]
      if (whave === undefined || !whave.done) { root._launchGitFor(w); root._gWish = -1; return }
    }
    root._drainGitPrefetch()
  }
  function _wishGit(id, p) {
    root._gWish = id
    root._pumpGit()
  }
  // Best-effort background prefetch for a freshly captured folder: skipped
  // when there is nothing to learn (payload already done) and queued behind
  // a running probe otherwise. Never preempts a selection wish.
  function _prefetchGit(id) {
    const e = root.findById(id)
    if (!e || e.type !== "folder") return
    const have = root.previewData[id]
    if (have !== undefined && have.done) return
    if (root._gitPrefetchQueue.indexOf(id) < 0)
      root._gitPrefetchQueue = root._gitPrefetchQueue.concat([id])
    root._pumpGit()
  }
  function _drainGitPrefetch() {
    while (root._gitPrefetchQueue.length > 0) {
      const id = root._gitPrefetchQueue[0]
      root._gitPrefetchQueue = root._gitPrefetchQueue.slice(1)
      const e = root.findById(id)
      if (!e || e.type !== "folder") continue
      const have = root.previewData[id]
      if (have !== undefined && have.done) continue
      const p = root._pathForId(id)
      if (p === "" || p.charAt(0) !== "/") {
        root._pdPut(id, { kind: "inline", done: true })
        continue
      }
      root._launchGitFor(id)
      return
    }
  }
  function _launchGitFor(id) {
    const p = root._pathForId(id)
    if (p === "" || p.charAt(0) !== "/") {
      root._pdPut(id, { kind: "inline", done: true })
      return
    }
    gitProc._id = id
    gitProc.command = CL.buildGitInfoCmd(p)
    gitProc.running = true
  }

  // --- snapshot GC ---
  // Only session snapshots (imageDataFile) are ever unlinked; user files
  // referenced by copied paths are never touched.
  //
  // A file currently served back out to the clipboard (pending-copy
  // window) is never unlinked mid-serve. A skipped file is not dropped
  // outright either - that would leak it permanently, because nothing ever
  // retries. It rides _pendingPurgePaths until the window lapses, and the
  // flush below reaps it.
  property var _pendingPurgePaths: []
  // Serial rm queue: rmProc is single-flight, so a second unlink requested
  // while one is running must wait instead of overwriting the in-flight
  // command (which silently dropped it and leaked the file forever).
  property var _rmQueue: []
  function _enqueueRmPaths(paths) {
    let queued = false
    for (let i = 0; i < (paths || []).length; i++) {
      const f = String(paths[i] == null ? "" : paths[i])
      if (f === "") continue
      root._rmQueue = root._rmQueue.concat([f])
      queued = true
    }
    if (queued) root._pumpRm()
  }
  function _pumpRm() {
    if (rmProc.running) return
    if (root._rmQueue.length === 0) return
    const batch = root._rmQueue
    root._rmQueue = []
    rmProc.command = CL.buildRmPathsCmd(batch)
    rmProc.running = true
  }
  function _purgeSnapshots(entries) {
    const paths = []
    for (let i = 0; i < entries.length; i++) {
      const f = entries[i].imageDataFile
      if (!f || f === "") continue
      if (root._pendingCopyPaths.indexOf(f) >= 0) {
        if (root._pendingPurgePaths.indexOf(f) < 0)
          root._pendingPurgePaths = root._pendingPurgePaths.concat([f])
        continue
      }
      paths.push(f)
    }
    if (paths.length === 0) return
    root._enqueueRmPaths(paths)
  }
  // Reap deferred snapshot files: anything the copy window protected at
  // purge time, minus files a live entry references again (paranoia -
  // snapshot files are unique per capture, so a reference means the row
  // survived and owns its own lifecycle) and minus files a new copy
  // window protects (re-parked for the next pass, never dropped).
  function _flushPendingPurgePaths() {
    if (root._pendingPurgePaths.length === 0) return
    const live = Object.create(null)
    for (let i = 0; i < root.history.length; i++) {
      const f = root.history[i].imageDataFile
      if (f && f !== "") live[f] = true
    }
    const parked = []
    const paths = []
    for (let i = 0; i < root._pendingPurgePaths.length; i++) {
      const f = root._pendingPurgePaths[i]
      if (live[f] === true) continue
      if (root._pendingCopyPaths.indexOf(f) >= 0) { parked.push(f); continue }
      paths.push(f)
    }
    root._pendingPurgePaths = parked
    if (paths.length === 0) return
    root._enqueueRmPaths(paths)
  }
  // Boot orphan sweep: snapshot files are unique per capture, so any file
  // under the snapshot dir that no history row references is a leftover -
  // a delete that predated the rm queue, a crash between capture and
  // persist, or a trimmed row from before. Without this the cache dir only
  // ever grows. Only session snapshots are ever unlinked; user files
  // referenced by copied paths live elsewhere and are never touched.
  function _sweepOrphanSnapshots() {
    if (root.imgDir === "" || sweepProc.running) return
    sweepProc.command = ["ls", "-1", "--", root.imgDir]
    sweepProc.running = true
  }
  // Bytes about to be released, summed from the entries' own recorded sizes.
  // A pure function of history, which is what makes it testable off a live
  // session.
  function _snapshotBytes(entries) {
    let n = 0
    for (let i = 0; i < entries.length; i++)
      if (typeof entries[i].fileSize === "number") n += entries[i].fileSize
    return n
  }

  // Preview-hub eviction: whenever entries leave history (delete, cap
  // trim), drop their cached preview payloads too. Without this the
  // id-keyed previewData map retained every probed text-file dump for
  // the shell's lifetime, keyed by ids that can never be selected
  // again.
  function _dropPreviewData(entries) {
    const ids = []
    for (let i = 0; i < entries.length; i++) ids.push(entries[i].id)
    if (ids.length === 0) return
    const pd = Object.assign({}, root.previewData)
    let dropped = 0
    for (let i = 0; i < ids.length; i++) {
      if (pd[ids[i]] !== undefined) { delete pd[ids[i]]; dropped++ }
    }
    if (dropped === 0) return
    root.previewData = pd
  }

  Process {
    id: rmProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: root._pumpRm()
  }
  Process {
    id: sweepProc
    running: false
    stdout: StdioCollector { id: sweepOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (exitCode !== 0) return
      const live = Object.create(null)
      for (let i = 0; i < root.history.length; i++) {
        const f = root.history[i].imageDataFile
        if (f && f !== "") live[f] = true
      }
      const orphans = []
      const names = String(sweepOut.text).split("\n")
      for (let i = 0; i < names.length; i++) {
        const n = names[i].trim()
        if (n === "") continue
        const full = root.imgDir + "/" + n
        if (live[full] !== true) orphans.push(full)
      }
      if (orphans.length > 0) root._enqueueRmPaths(orphans)
    }
  }

  Process {
    id: clearProc
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      // `wl-copy --clear` emptying the SYSTEM clipboard is how a deleted entry
      // stops being re-captured on the next boot.
      if (exitCode !== 0) return
      const pending = root._pendingSnapshotEntries
      if (pending.length === 0) {
        root._clearGeneration = -1
        return
      }
      // The generation guard is the interesting one: the user copied something
      // new between asking for the clear and getting it, so the snapshot files
      // are NOT unlinked - they belong to what is on the clipboard now. A
      // deleted image that is still selected survives by that guard.
      if (root._entriesMatchCurrent(pending)) return
      if (root._clearGeneration !== root._clipboardGeneration) {
        root.queueFlush()
        return
      }
      root._pendingSnapshotEntries = []
      root._clearGeneration = -1
      root._purgeSnapshots(pending)
    }
  }
  function _setCurrentPaths(paths) {
    const next = Array.isArray(paths) ? paths.slice() : []
    const old = root._currentPaths
    let changed = old.length !== next.length
    if (!changed) {
      for (let i = 0; i < old.length; i++) {
        if (old[i] !== next[i]) {
          changed = true
          break
        }
      }
    }
    root._currentPaths = next
    root._currentPathsKnown = true
    if (changed) root._clipboardGeneration++
    root.queueFlush()
  }

  function _completePendingCopy(paths) {
    if (root._pendingCopyPaths.length === 0) return
    for (let i = 0; i < root._pendingCopyPaths.length; i++) {
      if (paths.indexOf(root._pendingCopyPaths[i]) < 0) continue
      root._pendingCopyPaths = []
      pendingCopyTimer.stop()
      root.queueFlush()
      return
    }
  }

  function _entriesMatchCurrent(entries) {
    if (!root._currentPathsKnown) return true
    for (let i = 0; i < entries.length; i++) {
      const paths = CL.entryPaths(entries[i])
      for (let j = 0; j < paths.length; j++) {
        if (root._currentPaths.indexOf(paths[j]) >= 0) return true
      }
    }
    return false
  }

  function _flushPendingSnapshots() {
    root._flushPendingPurgePaths()
    if (!root._currentPathsKnown || clearProc.running
      || root._pendingSnapshotEntries.length === 0) return
    if (root._entriesMatchCurrent(root._pendingSnapshotEntries)) {
      root._clearGeneration = root._clipboardGeneration
      clearProc.command = CL.buildClearCmd()
      clearProc.running = true
      return
    }
    const pending = root._pendingSnapshotEntries
    root._pendingSnapshotEntries = []
    root._clearGeneration = -1
    root._purgeSnapshots(pending)
  }

  function _clearCurrentForEntries(entries) {
    // Parked: the system clipboard has not been read yet, or a clear is already
    // in flight. The row is already gone from history at this point, so this
    // queue is the only thing standing between "deleted" and "re-captured on
    // the next boot".
    if (!root._currentPathsKnown || clearProc.running) {
      root._pendingSnapshotEntries = root._pendingSnapshotEntries.concat(entries)
      return true
    }
    if (!root._entriesMatchCurrent(entries)) return false
    root._pendingSnapshotEntries = root._pendingSnapshotEntries.concat(entries)
    root._clearGeneration = root._clipboardGeneration
    clearProc.command = CL.buildClearCmd()
    clearProc.running = true
    return true
  }

  function _purgeEntries(entries) {
    if (!root._clearCurrentForEntries(entries)) root._purgeSnapshots(entries)
    root._dropPreviewData(entries)
    for (let i = 0; i < entries.length; i++) root._forgetEntrySecret(entries[i])
  }

  // --- history insertion ---

  // Returns the live row that now holds the capture (the pinned original on
  // a pinned re-copy, the promoted existing row on a duplicate, the fresh
  // row otherwise). The caller uses it to take clipboard ownership without
  // re-resolving the row.
  function _addEntry(entry) {
    const hist = root.history.slice()
    // Same content again? Bump it to the top instead of duplicating.
    let existingIdx = -1
    for (let i = 0; i < hist.length; i++) {
      if (hist[i].type !== entry.type) continue
      let same = false
      if (entry.type === "secret") {
        // Two credentials match only when both still hold a value, and the
        // comparison runs inside the store so neither side is copied out.
        // An unavailable row holds nothing and never matches.
        same = SecretStore.matchesValue(String(hist[i].secretHandle || ""),
          SecretStore.peek(String(entry.secretHandle || "")))
      } else {
        same = (hist[i].raw === entry.raw)
      }
      if (same) { existingIdx = i; break }
    }
    if (existingIdx >= 0) {
      const existing = hist[existingIdx]
      // The existing row is the one whose SecretStore slot is actually held,
      // so it is the row that survives and the fresh capture's slot is
      // released rather than shadowed. A pinned original additionally keeps
      // its position: a user who re-copies something pinned sees the row stay
      // put, which is correct.
      if (existing.secretHandle !== entry.secretHandle)
        root._forgetEntrySecret(entry)
      if (existing.pinned) return existing
      // Move the surviving row to the front rather than unshifting the fresh
      // one. Unshifting the fresh entry installed a row pointing at the slot
      // released two lines up, so that row could never be copied again
      // ("credential unavailable") for the rest of the session; and the bare
      // splice left the surviving old slot orphaned in the store, because
      // _forgetAllSecrets only walks root.history and so could never reach it.
      // Keeping the old object also keeps its id, which is what any lazily
      // computed preview payload is keyed by.
      hist.splice(existingIdx, 1)
      hist.unshift(existing)
    } else {
      hist.unshift(entry)
    }
    // Trim oldest unpinned rows beyond the cap; pinned are exempt.
    while (hist.length > root.maxHistory) {
      let dropped = false
      for (let i = hist.length - 1; i >= 0; i--) {          if (!hist[i].pinned) {
            root._purgeEntries([hist[i]])
            hist.splice(i, 1)
          dropped = true
          break
        }
      }
      if (!dropped) break // all pinned - keep them, cap be damned
    }
    root.history = hist
    root._recompute()
    // Every entry that reaches here arrived from outside: `_offer` has
    // already swallowed this shell's own copy through the hash, the secret and
    // the mute-window checks, so one user action produces exactly one line
    // here. The mimetype is what the OFFERING APPLICATION advertised, which is
    // client data and bounded like an app name; the payload that came with it
    // is never named, and a credential prints the mimetype its source
    // advertised like any other row.
    Log.info("captured data (" + String(entry.mime) + "), total", root.totalCount)
    // The INFO carries the mime the offering application advertised and the
    // size the capture left, and nothing else. `type` is the shell's own
    // classification word, and it is one of the few things a clipboard log
    // line may carry: the shell's own classification word, a size, a count, a
    // slot number and a bounded client string, and nothing derived from the
    // payload. `type` describes a row without describing what is in it, and it
    // is the only
    // field that separates a folder copy from an archive copy of one
    // `text/uri-list` payload. `bytes` is the other: a size says what a reader
    // needs about a capture and reveals none of it, and a credential reports
    // `hidden` rather than the `0` `_entryBytes` hands back for it.
    //
    // `existingIdx` is the verdict the INFO reads as an add. A re-copy of bytes
    // already held did not grow the store, it moved the row it found to the
    // front, and from the total alone the two are the same event. It is read
    // here rather than captured because the loop that set it is the only thing
    // that could have changed it; a pinned original is not this case at all,
    // since that path drops the capture and returns without reaching this line.
    //
    // The count against the cap is what says whether the next capture evicts.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("captured data (" + Log.summarize(String(entry.mime)) + "): type "
        + String(entry.type) + ", bytes "
        + (entry.type === "secret" ? "hidden" : String(root._entryBytes(entry)))
        + ", " + (existingIdx >= 0 ? "promoted from slot " + existingIdx : "new row")
        + ", " + root.totalCount + " of " + root.maxHistory)
    }
    root._persist()
    return hist[0]
  }
  // One entry's size in bytes, from whatever that entry happens to know about
  // itself: the recorded size for a file or an image, the stored string's
  // length otherwise. A pure function of the entry, which is what makes it
  // testable outside a live session. A credential is 0 here and the CALLER
  // prints `bytes=hidden` for it - the distinction has to be made where the
  // line is built, because "0" is a true statement about a secret's stored row
  // and a false statement about the bytes that were copied.
  function _entryBytes(entry) {
    if (entry.type === "secret") return 0
    if (typeof entry.fileSize === "number") return entry.fileSize
    if (typeof entry.totalSize === "number") return entry.totalSize
    return String(entry.raw == null ? "" : entry.raw).length
  }

  // --- IPC ---
  IpcHandler {
    target: "clipboard"
    function help(command: string): string {
      return UnitIpc.help("clipboard", "Clipboard", "clipboard history manager", [
        { name: "clear", help: "wipe history" },
        { name: "close", help: "hide the panel" },
        { name: "copy", help: "(index) re-copy an entry" },
        { name: "list", help: "history metadata as JSON" },
        { name: "open", help: "show the panel" },
        { name: "pin", help: "(index) pin an entry" },
        { name: "remove", help: "(index) drop an entry" },
        { name: "toggle", help: "show/hide" },
        { name: "view", help: "(index) preview an entry" },
      ], command)
    }
    function ping(): string { return "pong" }
    function open(): string { root.showPanel(); return "ok" }
    function close(): string { root.hidePanel(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function clear(): string { root.clearAll(); return "ok" }
    function status(): string {
      return JSON.stringify({
        visible: root.visible,
        total: root.history.length,
        pinned: root.pinnedCount,
        mode: root.mode,
        query: root.query,
        count: root.filtered.length
      })
    }
    function list(): string { return JSON.stringify(root._listProjection()) }

    function view(index: string): string {
      const e = root._filteredAt(root._ipcIndex(index))
      if (!e) return "null"
      return JSON.stringify(root._projectEntry(e))
    }
    function copy(index: string): string {
      const e = root._filteredAt(root._ipcIndex(index))
      if (!e) return "error:index"
      root.copyEntry(e)
      return "ok"
    }
    function remove(index: string): string {
      // Resolve the index to an id once, then go through the buffered
      // requestDelete so IPC and UI share one deletion path.
      const e = root._filteredAt(root._ipcIndex(index))
      if (!e) return "error:index"
      if (!root.requestDelete(e.id)) return "error:pending"
      return "ok"
    }
    function pin(index: string): string {
      const at = root._ipcIndex(index)
      const e = root._filteredAt(at)
      if (!e) return "error:index"
      root.togglePinAt(at)
      return "ok"
    }
  }

  // Strict IPC index: optional sign with digits only. parseInt accepts
  // trailing junk ("1abc" -> 1), so every index verb gates through here
  // first; anything else is a miss. Null means miss.
  function _ipcIndex(v) {
    const s = String(v === undefined || v === null ? "-1" : v)
    if (!/^-?\d+$/.test(s)) return null
    return parseInt(s, 10)
  }
  // Entry at the current filtered-list position (what the UI/CLI index).
  // A null index (strict gate miss) is always a miss.
  function _filteredAt(index) {
    if (index === null || index === undefined || index < 0 || index >= root.filtered.length) return null
    return root.filtered[index]
  }

  // --- read projection ---
  // One shape for both read verbs. Fields are metadata plus a bounded
  // preview; a raw payload is not among them, so nothing a credential row
  // holds can reach a caller even indirectly. The preview policy is explicit:
  // text-shaped content gets a truncated preview, everything else gets none,
  // and a credential row gets none at all.
  function _projectEntry(e) {
    const o = {
      id: e.id,
      type: e.type,
      title: e.title,
      subLeft: e.subLeft,
      timeStr: e.timeStr,
      pinned: e.pinned === true,
      mime: e.mime,
      filePaths: (e.filePaths || []).slice()
    }
    if (e.fileSize !== undefined) o.fileSize = e.fileSize
    if (e.type === "text" || e.type === "url" || e.type === "network")
      o.preview = CL.truncateText(String(e.preview || ""), 200)
    return o
  }
  // Credential rows are counted but not listed: the list verb returns
  // metadata only, so excluding them outright is what keeps a raw secret
  // entry out of ordinary list output. The list honors the same filtered
  // order the index verbs address, and each entry carries its filtered
  // index so a withheld credential never shifts a position silently.
  function _listProjection() {
    const entries = []
    let secrets = 0
    for (let i = 0; i < root.filtered.length; i++) {
      const e = root.filtered[i]
      if (e.type === "secret") { secrets++; continue }
      const o = root._projectEntry(e)
      o.index = i
      entries.push(o)
    }
    return {
      version: 2,
      total: root.history.length,
      count: entries.length,
      secrets: secrets,
      entries: entries
    }
  }

  ClipboardView {}
}

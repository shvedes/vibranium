pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQml
import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.common
import "Model.js" as Model

// Demand-loaded child of the Pass facade: every piece of store work lives
// here and nothing here survives a close. The binary probe, the store
// resolve, the .gpg-id read, the find scan, the git checks, every
// pass/gpg child and the panel tree itself are constructed with this
// object and go with it, so a shell that never opens the password manager
// never pays for any of it.
//
// The facade is the only writer of this object's lifetime: it arrives
// through a Loader, it leaves the same way. Nothing here reaches into the
// gate, so no verb can construct a second controller, and the public read
// surface stays on the facade - this file is addressed only by
// PassController, never by a panel or a registry consumer.
//
// Secrets never touch notifications, argv, or a QML property: a decrypted
// value lives in SecretStore under a handle and reaches wl-copy through the
// facade transport's stdin, so only the entry path is ever reported to the
// user. Every child process is direct argv - no bash -c anywhere.
// The single exception is `pass edit` itself, which needs a terminal for
// $EDITOR: it launches through vb-launch-tui exactly like any other TUI
// surface.
Item {
  id: root

  // Staged-delete marks are panel input, not store state: the map is
  // created once by the facade and handed in, so PassEntry's bindings
  // keep their target across a teardown. Required, not defaulted: a
  // controller built without the shared map would split the marks in
  // two, and the split would only show as rows stuck pending.
  required property OptimisticSet optimistic

  // Set when construction itself could not finish, so the facade can
  // answer "error:<code>" instead of reporting a controller that is not
  // there. Every later demand re-reads it, so a failed first caller
  // cannot leave a half-built controller behind for the next one.
  property string startupError: ""

  // --- store state ---
  property string storeDir: ""
  property bool initialized: false
  property var entries: []
  // All known folders, including empty ones the entry scan cannot see.
  property var allDirs: []
  property bool _refreshQueued: false
  property bool busy: false
  property string lastError: ""
  property bool gitReady: false

  property string passBinary: "unknown" // unknown | present | missing
  readonly property bool passInstalled: root.passBinary !== "missing"

  property var _unlockCb: null
  property string _gitNext: ""
  property bool _gitVerbose: false
  // Consecutive failed unlock attempts, reset by a success. gpg-agent backs
  // off after a few wrong master passwords, so the count is what says
  // "about to be locked out" rather than "wrong password".
  property int _unlockAttempts: 0
  property var _showProc: null
  // True while a read is in flight: `pass show` owns a live child and the
  // value it is about to hand over lives in this object's own store slot, so
  // a teardown that landed now would drop the copy the caller just asked
  // for. The facade reads it to keep its idle release off a decrypting
  // controller; nothing else has to know.
  readonly property bool copyPending: root._showProc !== null
  // Whether any child this object owns is still running, so the facade can
  // ask before it hands the controller back. Every flow that starts a child
  // also closes the panel - insert, generate, copy, push and pull all return
  // to the surface at once - and the child that has to report back lives
  // here, so a teardown on the close fade kills the process before its
  // onExited runs and the answer is lost with it. Process truth rather than
  // the busy flag, which only the write flows maintain and which no git
  // child ever sets. The dynamic `pass show` is the one child with no fixed
  // owner here, so it is read through copyPending instead.
  readonly property bool childBusy: findProc.running || mkdirProc.running
    || rmdirProc.running || gpgProc.running || termProc.running
    || headProc.running || writeProc.running || genProc.running
    || mvProc.running || rmProc.running || initProc.running
    || keysProc.running || gitRemoteProc.running || gitPushProc.running
    || gitPullProc.running || root.copyPending
  // Handles this flow opened and has not released yet. The list is what
  // destruction walks, so two overlapping flows (an insert still committing
  // while a copy is being prepared) each release exactly their own slot.
  property var _secretHandles: []
  // Paths this controller marked in the shared optimistic map and has not
  // settled. Destruction cancels the remainder, because a mark whose
  // commit never ran would otherwise outlive the controller and pin a row
  // as pending in the next session.
  property var _marked: []

  Component.onCompleted: {
    // The three construction steps that cost something: a PATH probe, a
    // store resolve and the first scan (one file read plus two children).
    // A throw here would leave the facade holding a controller that never
    // worked, so it is turned into startupError instead of propagating - a
    // Loader cannot raise a construction error to its caller.
    try {
      root.probeBinary()
      root._resolveStoreDir()
      root.refresh()
    } catch (ignored) {
      root.startupError = "startup"
      root.lastError = "store unavailable"
    }
  }

  Component.onDestruction: {
    // A store slot and an unsettled delete mark are the only things this
    // object can leave behind; the copy child belongs to the facade, which
    // outlives a panel, and goes down with the singleton.
    root._releaseSecrets()
    for (let i = 0; i < root._marked.length; i++) root.optimistic.cancel(root._marked[i])
    root._marked = []
  }

  // A SecretStore slot, namespaced by kind rather than by path alone. A read
  // and a write for the same entry are two different values with two
  // different owners: the read's slot is handed to the facade's wl-copy child
  // and dropped when that copy settles, the write's slot is the pending stdin
  // payload `pass insert` is about to read. Sharing one key let a copy landing
  // mid-insert overwrite the write's slot - the insert's _feedInsert then peeked
  // an empty slot, wrote nothing, and `pass insert --echo` blocked on stdin
  // with no timeout, so busy stuck true and every later writer was refused.
  function _secretHandleFor(p, kind) { return "pass:" + kind + ":" + p }

  function _stashSecret(handle, value) {
    if (!SecretStore.stash(handle, value)) return false
    root._secretHandles = root._secretHandles.concat([handle])
    return true
  }
  function _untrackSecret(handle) {
    if (handle === "") return
    root._secretHandles = root._secretHandles.filter(h => h !== handle)
  }
  // Drops the value and stops tracking it. A handle whose value already left
  // through the write channel is a no-op here, so every terminal path can
  // call it without knowing which one ran.
  function _forgetSecret(handle) {
    if (handle === "") return
    SecretStore.drop(handle)
    root._untrackSecret(handle)
  }
  function _releaseSecrets() {
    const owned = root._secretHandles
    root._secretHandles = []
    for (let i = 0; i < owned.length; i++) SecretStore.drop(owned[i])
  }

  // Every child this object starts goes through here, so no call site can set
  // a command without also starting it.
  function _start(proc) {
    proc.running = true
  }

  // Optimistic-mark bookkeeping: the mark and the settle both land on the
  // shared map, and the list is what destruction walks.
  function _markPending(path) {
    if (!root.optimistic.mark(path)) return false
    root._marked = root._marked.concat([path])
    return true
  }
  function _settlePending(path) {
    const keep = root._marked.filter(entry => entry !== path)
    if (keep.length !== root._marked.length) root._marked = keep
  }

  function _env() {
    return {
      PASSWORD_STORE_DIR: Quickshell.env("PASSWORD_STORE_DIR"),
      XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"),
      HOME: Quickshell.env("HOME")
    }
  }

  function _resolveStoreDir() {
    var d = Model.storeDir(root._env())
    if (d.length > 1 && d.charAt(d.length - 1) === "/")
      d = d.substring(0, d.length - 1)
    root.storeDir = d
  }

  // Every pass/git Process inherits this override so the resolved store
  // wins over whatever the daemon environment carried (imperative form
  // like AppLauncher's TZ probe).
  function _withStore(proc) {
    proc.environment = ({ "PASSWORD_STORE_DIR": root.storeDir })
  }

  function _notify(summary, body) {
    Exec.run(["notify-send", "-r", "3", "-t", "3000", "-a", "Vibranium",
      summary, body])
  }

  // Binary availability: the store (PASSWORD_STORE_DIR) can exist
  // without the `pass` package being installed, and every flow on
  // the panel runs through it. Checked synchronously via
  // StandardPaths - no process, so the verdict lands immediately and
  // the panel never flashes the warning on a slow boot.
  // The answer is a url, not a string: a hit reads as
  // "file:///usr/bin/pass" and a miss as an EMPTY url, which compares
  // false against "" under === no matter what it stringifies to, so a
  // missing binary probed as present. String() is what makes the miss
  // detectable - the same normalisation common/Paths.qml applies to
  // writableLocation. Only the verdict is kept; the path never leaves
  // this function.
  function probeBinary() {
    root.passBinary = String(StandardPaths.findExecutable("pass")) !== "" ? "present" : "missing"
  }

  // --- discovery ---
  // The .gpg-id read is async (loaded/loadFailed continue the refresh
  // below): a main-thread waitForJob here would stall the panel on
  // every refresh for a file the store may not even have. While the
  // check is in flight initialized stays false, which is the skeleton
  // the panel already renders for an unknown store.
  property bool _idWaitArmed: false
  FileView {
    id: gpgIdFile
    printErrors: false
    onLoaded: root._finishIdCheck(true)
    onLoadFailed: root._finishIdCheck(false)
  }

  // A successful mutation waiting to be reported, and nothing more.
  //
  // The count has to wait for the scan that follows the write: at the moment a
  // writer child exits, `entries` is still the pre-mutation list, so a line
  // emitted there would report a total that is one off in exactly the case a
  // reader cares about. `findProc` is where the scan lands, so that is where
  // the verb is spent. A mutation that FAILED sets nothing, so a refusal is
  // silent - the error is already on the panel and in `lastError`.
  //
  // `set` says which list the count belongs to: a folder line counts folders
  // and an entry line counts entries, and mixing them would make a total that
  // moves for the wrong reason.
  property var _pendingAction: null

  // Drop a verb that no scan will ever spend.
  //
  // The handoff is only sound while a scan is guaranteed to follow. If none
  // starts, the verb would still be parked when the NEXT refresh runs, and that
  // scan would report its own count under this mutation's name - a line that is
  // entirely true and entirely misleading. Losing the line is recoverable; a
  // line about the wrong event is not.
  function _abandonPending(reason: string): void {
    if (root._pendingAction === null) return
    const lost = root._pendingAction.verb
    root._pendingAction = null
    // The verb goes here because the INFO line this replaces never prints: a
    // dropped handoff would otherwise be a mutation that happened and produced
    // no trace of it at all.
    Log.warn("pass mutation not reported (" + lost + "), " + reason)
  }

  function refresh() {
    if (root.storeDir === "") root._resolveStoreDir()
    if (root.storeDir === "") { root._abandonPending("no store"); return }
    root._reapShow()
    // A check already in flight completes this refresh when it lands;
    // arming twice would interleave two continuations on one file.
    if (root._idWaitArmed) return
    root._idWaitArmed = true
    const idPath = root.storeDir + "/.gpg-id"
    // Reassigning the same path is a no-op for FileView, so a repeat
    // refresh reloads explicitly instead of arming a signal that never
    // fires and parking every later refresh behind it.
    if (gpgIdFile.path === idPath) gpgIdFile.reload()
    else {
      gpgIdFile.path = ""
      gpgIdFile.path = idPath
    }
  }

  // Continuation of refresh() once the .gpg-id read lands. Stale
  // signals (the "" clear, an older refresh) find the arm down and are
  // ignored; the armed job is the only one answered.
  function _finishIdCheck(hasId) {
    if (!root._idWaitArmed) return
    root._idWaitArmed = false
    root.initialized = hasId === true
    if (!root.initialized) {
      root._refreshQueued = false
      root.entries = []
      root.allDirs = []
      root.gitReady = false
      root._abandonPending("store has no .gpg-id")
      return
    }
    if (!findProc.running) {
      root._refreshQueued = false
      root.busy = true
      root._withStore(findProc)
      // One pass for both sets: "d <rel>" folders, "f <rel>" entries.
      // Direct argv, no shell - parens ride as plain arguments.
      findProc.command = ["find", root.storeDir, "-not", "-path", "*/.git/*",
        "(", "-type", "d", "-printf", "d %P\n", ")",
        "-o", "(", "-type", "f", "-name", "*.gpg", "-printf", "f %P\n", ")"]
      root._start(findProc)
    } else {
      // The running scan owns the one find slot, so a refresh that lands
      // while it runs cannot start a second one and the flag is the only way
      // to have it asked for at all. Named only when a verb is parked: that
      // is the case where the INFO line carrying that verb is printed by a
      // LATER scan, and the gap between the two otherwise reads as a
      // mutation that reported late for no reason.
      root._refreshQueued = true
      const parked = root._pendingAction
      if (parked !== null) Log.debug(parked.verb + ": refresh queued behind the running scan")
    }
    root._checkRemote("")
  }

  Process {
    id: findProc
    stdout: StdioCollector { id: findOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      root.busy = false
      if (root._refreshQueued) {
        root._refreshQueued = false
        // This early return is the other half of the queue above: a scan that
        // lands while a refresh is already pending does not spend the parked
        // verb, which is why a verb's total can end up describing more than
        // the one write that armed it. Without the line the mutation reads as
        // reported against a scan that finished before it was even started.
        const parked = root._pendingAction
        if (parked !== null) Log.debug(parked.verb + ": total deferred to the queued scan")
        Qt.callLater(() => root.refresh())
        return
      }
      if (exitCode !== 0) {
        root.lastError = "store scan failed"
        root.entries = []
        root.allDirs = []
        // A failed scan is a third way the verb can be stranded: it emptied the
        // model, so the count this mutation would have reported no longer
        // describes anything.
        root._abandonPending("store scan failed")
        return
      }
      const raw = String(findOut.text).split("\n")
      const parsed = Model.parseFindOutput(root.storeDir, raw)
      root.entries = Model.listEntries(root.storeDir, parsed.files)
      root.allDirs = parsed.dirs
      // The scan has landed, so the count is finally true. Verb and count
      // only: this component's contract is that a store, an entry and a folder
      // are all identifying, and a line here is not the place to relax that.
      const pending = root._pendingAction
      root._pendingAction = null
      if (pending !== null) {
        const total = pending.set === "dirs" ? root.allDirs.length : root.entries.length
        Log.info(pending.verb + ", total " + total)
        // The count the INFO line is reporting is the AFTER picture; the scan
        // shape behind it is what explains an unexpected total.
        Log.debug("scan: " + parsed.files.length + " files, " + parsed.dirs.length + " dirs")
      }
      // Every name the scan found is tokenised, so the token map holds the whole
      // vocabulary of this store rather than only the names something asked
      // about.
      root._mintNames(parsed.files, parsed.dirs)
    }
  }

  // Tokens for everything the scan saw. The names never leave this function:
  // they are read out of the scan result and handed straight to the token
  // helper, so the set of store names the session has in hand is exactly the
  // set of names it could still leak.
  function _mintNames(files, dirs) {
    const f = Array.isArray(files) ? files : []
    const d = Array.isArray(dirs) ? dirs : []
    for (let i = 0; i < f.length; i++) Pass.entryToken(Model.stripGpg(String(f[i])))
    for (let i = 0; i < d.length; i++) Pass.folderToken(String(d[i]))
  }

  // Real folder creation (pass folders only exist with content, but the
  // vault shows empty ones too now). One mkdir, direct argv - the only
  // sanctioned non-pass process besides the toast spawn.
  function createFolder(path) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      root.lastError = "no folder"
      return false
    }
    if (mkdirProc.running) {
      root.lastError = "busy"
      return false
    }
    root.busy = true
    mkdirProc._path = p
    mkdirProc.command = ["/bin/mkdir", "-p", root.storeDir + "/" + p]
    // Optimistic: the row appears instantly; the dirs probe
    // reconciles (a failed mkdir drops it on the fail refresh).
    const known = root.allDirs.slice()
    if (known.indexOf(p) === -1) {
      known.push(p)
      known.sort((a, b) => Model.versionCompare(a, b))
      root.allDirs = known
    }
    root._start(mkdirProc)
    return true
  }

  Process {
    id: mkdirProc
    property string _path: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const p = mkdirProc._path
      root.busy = false
      if (exitCode !== 0) {
        root.lastError = "folder failed: " + p
        root.refresh()
        return
      }
      root.lastError = ""
      // The verb is parked here rather than routed through `_afterMutation`,
      // which would also attempt a push. This path deliberately does not push:
      // an empty folder is not something git records, so a push would be
      // attempted for a change git cannot store. Same handoff, without the
      // side effect.
      root._pendingAction = { verb: "created folder", set: "dirs" }
      // What the sibling mutations do not say: no push was probed. An empty
      // folder is invisible to git, so the missing `git push` line that
      // follows every other verb here is the contract working rather than a
      // sync that quietly failed, and the total above is a folder count.
      Log.debug("created folder: armed for the scan, no push probed")
      root.refresh()
    }
  }

  Process {
    id: rmdirProc
    property string _path: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const p = rmdirProc._path
      root.busy = false
      if (exitCode !== 0) {
        root.lastError = "delete failed: " + p
        root._cancelPending(p)
        if (root._pendingDelete === p) root._pendingDelete = ""
        return
      }
      root.lastError = ""
      root.finishDelete(p)
      root._afterMutation({ verb: "deleted folder", set: "dirs" })
    }
  }

  // --- read (copy first line only) ---
  function copyEntry(path) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      root.lastError = "no entry"
      return false
    }
    // The transport is single-flight, so a second read is refused here
    // rather than queued behind a child the facade owns.
    if (root._showProc !== null || !Pass.copyIdle()) return false
    const proc = showProcComp.createObject(root, { path: p })
    if (proc === null) {
      root.lastError = "copy failed: " + p
      return false
    }
    root._showProc = proc
    proc.environment = ({ "PASSWORD_STORE_DIR": root.storeDir })
    proc.command = ["pass", "show", p]
    root._start(proc)
    return true
  }

  // A show owns its process and its collector for exactly one read. `pass
  // show` prints the credential in clear, and a collector left attached to a
  // long-lived process would hold those bytes for the rest of the session,
  // so the process is destroyed as soon as the value is in the store.
  Component {
    id: showProcComp
    Process {
      id: showProc
      property string path: ""
      stdout: StdioCollector { id: showOut }
      stderr: StdioCollector {}
      onExited: (exitCode, exitStatus) => {
        const p = showProc.path
        const value = exitCode === 0 ? Model.firstLine(String(showOut.text)) : ""
        root._showProc = null
        destroy()
        root._afterShow(p, value)
      }
    }
  }

  function _afterShow(p, value) {
    if (value === "") {
      root.lastError = "decrypt failed: " + p
      root._unlockAttempts++
      root._notify("Password Manager", "Failed to decrypt: " + p)
      return
    }
    root._unlockAttempts = 0
    const handle = root._secretHandleFor(p, "r")
    root._stashSecret(handle, value)
    // Only the entry path is ever notified; the value moves from the store
    // into the child's stdin and nowhere else.
    if (!root._handOff(handle)) {
      root._forgetSecret(handle)
      root.lastError = "copy failed: " + p
      root._notify("Password Manager", "Copy failed: " + p)
      return
    }
    root.lastError = ""
    root._notify("Password Manager", "Password copied to clipboard")
  }
  // A show child that never started reports no exit at all, so a read handle
  // that owns no live process is released here instead of blocking the panel.
  function _reapShow() {
    const proc = root._showProc
    if (proc === null) return
    try {
      if (proc.running === true) return
    } catch (ignored) {
    }
    root._showProc = null
    try { proc.destroy() } catch (ignored) { return }
    root.lastError = "read failed"
  }

  // The credential itself never comes back from a read: the clear value
  // goes straight into SecretStore under a handle and the facade's
  // transport is what moves it to the clipboard. The controller holds the
  // handle, not the bytes.
  function _handOff(handle) {
    if (!Pass.copySecret(handle)) return false
    // The transport owns the slot from here; a feed that never happens is
    // released by the transport, not by this object.
    root._untrackSecret(handle)
    return true
  }

  // --- pre-warm: decrypt to null before edit so pinentry lands first ---
  function ensureUnlocked(path, cb) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      if (typeof cb === "function") cb(false)
      return
    }
    if (gpgProc.running) {
      if (typeof cb === "function") cb(false)
      return
    }
    root._unlockAttempts++
    root._unlockCb = (typeof cb === "function") ? cb : null
    root._withStore(gpgProc)
    gpgProc.command = ["gpg", "-q", "--no-tty", "-d",
      root.storeDir + "/" + p + ".gpg"]
    root._start(gpgProc)
  }

  Process {
    id: gpgProc
    // stdout stays anonymous and unnamed on purpose: `gpg -d` prints the
    // decrypted entry in clear, and a collector with an id is a reference
    // somebody can read the value through. It is discarded here.
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const cb = root._unlockCb
      root._unlockCb = null
      if (exitCode === 0) root._unlockAttempts = 0
      if (typeof cb === "function") cb(exitCode === 0)
    }
  }

  // --- edit: pre-warm, then $EDITOR in a terminal, owned by pass itself ---
  // vb-launch-tui daemonizes (setsid) and exits at once, so the tracked
  // Process only proves the spawn - completion is detected by watching
  // HEAD: `pass edit` commits solely when the buffer was saved.
  property string _editBase: ""
  property int _editTicks: 0

  function editEntry(path) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      root.lastError = "no entry"
      return false
    }
    if (gpgProc.running || termProc.running) {
      root.lastError = "busy"
      return false
    }
    root.ensureUnlocked(p, ok => {
      if (!ok) {
        root.lastError = "unlock failed: " + p
        root._notify("Password Manager", "Failed to unlock keyring. Edit cancelled.")
        return
      }
      root._launchEditor(p)
    })
    return true
  }

  function _launchEditor(p) {
    root._withStore(termProc)
    termProc.command = ["vb-launch-tui", "--app-id=org.vb.term",
      "--title=pass", "--", "pass", "edit", p]
    root._start(termProc)
    root._notify("Password Manager", "Opened in editor: " + p)
    if (!root.gitReady) return
    root._editBase = ""
    root._editTicks = 0
    editWatch.stop()
    if (!headProc.running) {
      headProc._watch = true
      root._withStore(headProc)
      headProc.command = ["git", "-C", root.storeDir, "rev-parse", "HEAD"]
      root._start(headProc)
    } else {
      editWatch.restart()
    }
  }

  // Tracked only for the spawn: vb-launch-tui daemonizes and exits, the
  // terminal itself outlives this Process (see _launchEditor).
  Process {
    id: termProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
  }

  // A git object id is never published: a pass store's first commit hashes
  // the file NAMES of the store (the content is gpg ciphertext, the names
  // are not), so a sha is a digest over exactly the vocabulary this file
  // refuses to expose.
  Process {
    id: headProc
    property bool _watch: false
    stdout: StdioCollector { id: headOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (!headProc._watch) return
      const head = String(headOut.text).trim()
      if (root._editBase === "") {
        if (exitCode === 0 && head !== "") {
          root._editBase = head
          root._editTicks = 0
          editWatch.restart()
        }
        return
      }
      if (exitCode === 0 && head !== "" && head !== root._editBase) {
        root._editBase = ""
        editWatch.stop()
        root.push()
      }
    }
  }

  

  // Bounded HEAD poll after an edit launch (5s x 120 = 10min max): pushes
  // exactly when the edit committed, stays silent on view-only quits and
  // can never hang the panel - failures just age out. Named cadence.
  readonly property int editPollMs: 5000
  Timer {
    id: editWatch
    interval: root.editPollMs
    repeat: true
    running: false
    onTriggered: {
      root._editTicks++
      if (root._editTicks > 120) {
        root._editBase = ""
        editWatch.stop()
        return
      }
      if (headProc.running) return
      headProc._watch = true
      root._withStore(headProc)
      headProc.command = ["git", "-C", root.storeDir, "rev-parse", "HEAD"]
      root._start(headProc)
    }
  }

  // --- write paths: insert / generate / move / remove / init ---
  function insertEntry(path, secret, force) {
    const p = String(path || "")
    const s = String(secret === undefined || secret === null ? "" : secret)
    if (p === "" || s === "" || root.storeDir === "") {
      root.lastError = "empty entry"
      return false
    }
    if (writeProc.running) {
      root.lastError = "busy"
      return false
    }
    root.busy = true
    writeProc._path = p
    // The value goes to the store and the process keeps only the handle, so
    // the write channel can be fed without a QML property holding a secret.
    const handle = root._secretHandleFor(p, "w")
    if (!root._stashSecret(handle, s)) {
      root.busy = false
      root.lastError = "empty entry"
      return false
    }
    writeProc._handle = handle
    const cmd = ["pass", "insert", "--echo"]
    if (force === true) cmd.push("--force")
    cmd.push(p)
    root._withStore(writeProc)
    writeProc.command = cmd
    root._start(writeProc)
    return true
  }

  Process {
    id: writeProc
    stdinEnabled: true
    property string _path: ""
    property string _handle: ""
    property bool _wrote: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onStarted: root._feedInsert()
    onExited: (exitCode, exitStatus) => {
      const p = writeProc._path
      const handle = writeProc._handle
      writeProc._handle = ""
      root.busy = false
      if (exitCode !== 0) {
        // The value never reached the clipboard, so nothing is left to hold.
        root._forgetSecret(handle)
        root.lastError = "save failed: " + p
        root._notify("Password Manager", "Save failed: " + p)
        return
      }
      if (handle === "" || !root._handOff(handle)) {
        root._forgetSecret(handle)
        root.lastError = "copy failed: " + p
        root._notify("Password Manager", "Saved, but copy failed: " + p)
        root._afterMutation({ verb: "created entry", set: "entries" })
        return
      }
      root.lastError = ""
      root._notify("Password Manager", "Password saved and copied to clipboard")
      root._afterMutation({ verb: "created entry", set: "entries" })
    }
  }
  // `pass insert --echo` reads one line and does not wait for EOF, so the
  // channel stays open and the value is written exactly once.
  function _feedInsert() {
    if (writeProc._wrote || !writeProc.running) return
    writeProc._wrote = true
    const handle = writeProc._handle
    if (handle === "") return
    const value = SecretStore.peek(handle)
    if (value !== "") writeProc.write(value + "\n")
  }

  function generateEntry(path, force) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      root.lastError = "no entry"
      return false
    }
    if (genProc.running) {
      root.lastError = "busy"
      return false
    }
    root.busy = true
    const cmd = ["pass", "generate"]
    if (force === true) cmd.push("--force")
    cmd.push(p)
    genProc._path = p
    root._withStore(genProc)
    genProc.command = cmd
    root._start(genProc)
    return true
  }

  Process {
    id: genProc
    property string _path: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const p = genProc._path
      root.busy = false
      if (exitCode !== 0) {
        root.lastError = "generate failed: " + p
        root._notify("Password Manager", "Generate failed: " + p)
        return
      }
      root.lastError = ""
      if (!root.copyEntry(p)) {
        root.lastError = "copy failed: " + p
        root._notify("Password Manager", "Generated, but copy failed: " + p)
      }
      root._afterMutation({ verb: "generated entry", set: "entries" })
    }
  }

  function moveEntry(from, to) {
    const a = String(from || "")
    const b = String(to || "")
    if (a === "" || b === "" || root.storeDir === "") {
      root.lastError = "no entry"
      return false
    }
    if (a === b) {
      root.lastError = "same location"
      return false
    }
    if (mvProc.running) {
      root.lastError = "busy"
      return false
    }
    root.busy = true
    mvProc._from = a
    root._withStore(mvProc)
    mvProc.command = ["pass", "mv", a, b]
    root._start(mvProc)
    return true
  }

  Process {
    id: mvProc
    property string _from: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const from = mvProc._from
      root.busy = false
      if (exitCode !== 0) {
        root.lastError = "move failed: " + from
        return
      }
      root.lastError = ""
      root._notify("Password Manager", "Password moved")
      root._afterMutation({ verb: "moved entry", set: "entries" })
    }
  }

  // Triple-buffered deletion like Clipboard/AppLauncher: the staged UI
  // confirm arms, requestDelete buffers the intent as pending, and the
  // commit runs `pass rm` two frames later so rapid re-arms collapse.
  property string _pendingDelete: ""
  signal deleteCommitted(string path)

  function removeEntry(path) {
    return root.requestDelete(path)
  }

  function requestDelete(path) {
    const p = String(path || "")
    if (p === "" || root.storeDir === "") {
      root.lastError = "no entry"
      return false
    }
    if (!root._markPending(p)) return false
    root._pendingDelete = p
    Idle.run(() => root.commitDelete(p), 2)
    return true
  }

  function commitDelete(path) {
    const p = String(path || "")
    if (!root.optimistic.isPending(p)) return
    if (root._pendingDelete !== p) { root._cancelPending(p); return }
    if (rmProc.running) {
      // Single-flight like the other writers: re-queue instead of
      // dropping, the pending mark keeps it idempotent.
      Idle.run(() => root.commitDelete(p), 2)
      return
    }
    // Empty mkdir folders hold no pass-name, so `pass rm` refuses
    // them: remove the directory itself (mkdirProc precedent -
    // direct argv, never recursive).
    if (root.allDirs.indexOf(p) !== -1 && Model.countUnder(root.entries, p) === 0) {
      if (rmdirProc.running) {
        Idle.run(() => root.commitDelete(p), 2)
        return
      }
      root.busy = true
      rmdirProc._path = p
      rmdirProc.command = ["/bin/rmdir", root.storeDir + "/" + p]
      root._start(rmdirProc)
      return
    }
    root.busy = true
    rmProc._path = p
    root._withStore(rmProc)
    rmProc.command = ["pass", "rm", "--recursive", "--force", p]
    root._start(rmProc)
  }

  function _removeCachedPath(path) {
    const p = String(path || "")
    if (p === "") return
    const prefix = p + "/"
    const entries = root.entries.filter(entry => {
      const value = entry ? String(entry.path || "") : ""
      return value !== p && value.indexOf(prefix) !== 0
    })
    if (entries.length !== root.entries.length) root.entries = entries
    const dirs = root.allDirs.filter(dir => {
      const value = String(dir || "")
      return value !== p && value.indexOf(prefix) !== 0
    })
    if (dirs.length !== root.allDirs.length) root.allDirs = dirs
  }

  function finishDelete(path) {
    const p = String(path || "")
    root._removeCachedPath(p)
    root.optimistic.confirm(p)
    root._settlePending(p)
    if (root._pendingDelete === p) root._pendingDelete = ""
    root.deleteCommitted(p)
  }

  // Cancel a mark the controller still owns, and forget it: a cancelled
  // path is settled, so destruction must not try to cancel it again.
  function _cancelPending(path) {
    root.optimistic.cancel(path)
    root._settlePending(path)
  }

  Process {
    id: rmProc
    property string _path: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      const p = rmProc._path
      root.busy = false
      if (exitCode !== 0) {
        root.lastError = "delete failed: " + p
        root._cancelPending(p)
        if (root._pendingDelete === p) root._pendingDelete = ""
        return
      }
      root.lastError = ""
      root.finishDelete(p)
      root._afterMutation({ verb: "deleted entry", set: "entries" })
    }
  }

  function initStore(key) {
    const k = String(key || "")
    if (k === "" || root.storeDir === "") {
      root.lastError = "no key"
      return false
    }
    if (initProc.running) {
      root.lastError = "busy"
      return false
    }
    root.busy = true
    root._withStore(initProc)
    initProc.command = ["pass", "init", k]
    root._start(initProc)
    return true
  }

  Process {
    id: initProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      root.busy = false
      // The notification names the store and not the key: a gpg
      // fingerprint is how a key is found in a keyserver, so it identifies
      // a person as surely as an entry name identifies a bank.
      if (exitCode !== 0) {
        root.lastError = "init failed"
        root._notify("Password Manager", "Error initializing password store")
        return
      }
      root.lastError = ""
      root._notify("Password Manager", "Password store initialized successfully")
      // The one verb here that counts a store rather than an entry, because
      // that is what `pass init` makes: an empty store. The count is 0 by
      // definition, and saying so is the whole of the report.
      root._pendingAction = { verb: "initialised store", set: "entries" }
      root.refresh()
    }
  }

  // --- GPG key listing for the init picker ---
  property var keyChoices: []
  signal keysReady()

  function requestKeys() {
    if (keysProc.running) return false
    keysProc.command = ["gpg", "--list-secret-keys", "--with-colons"]
    root._start(keysProc)
    return true
  }

  Process {
    id: keysProc
    stdout: StdioCollector { id: keysOut }
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      if (exitCode !== 0) {
        root.keyChoices = []
        root.lastError = "gpg key list failed"
      } else {
        root.keyChoices = Model.parseKeyFingerprints(String(keysOut.text))
        if (root.keyChoices.length === 0) {
          root.lastError = "no gpg keys"
          root._notify("Password Manager", "No GPG keys found. Create one first with 'gpg --gen-key'")
        }
      }
      root.keysReady()
    }
  }

  // --- git: async push after mutation, explicit pull/push for the panel ---
  //
  // A pull and a push are the only two children here that leave the
  // machine. Nothing here ever reads the remote URL: `remote get-url origin`
  // hands back a handle somebody can legitimately paste a token into, in
  // either the git@host:user/repo.git or the https://token@host/... form, so
  // the store is identified by its own path and never by its remote.
  function _afterMutation(action) {
    // `action` is `{ verb, set }` and is the ONLY thing this reports about a
    // mutation. It carries no name because nothing here may: in a password
    // store the name IS the secret, so a name and a password are the same
    // class of thing and neither may reach a log at any level. A name that
    // has to appear is published as an opaque per-session token instead.
    root._pendingAction = action || null
    // The half of the handoff that is invisible at the other end. The INFO
    // line prints at the scan, a whole child later, and nothing in between
    // says which writer armed it, which of the two lists its total will be
    // read from, or that a push was probed. Both fields are call-site
    // literals, which is why nothing here is summarised: the one string this
    // feature may not print - bounded or not - is a name.
    if (root._pendingAction !== null)
      Log.debug(root._pendingAction.verb + ": armed for the scan, total will count "
        + root._pendingAction.set + ", push probed")
    root.refresh()
    root.tryPush()
  }

  function _checkRemote(next) {
    if (root.storeDir === "") return
    if (gitRemoteProc.running) return
    root._gitNext = next || ""
    root._withStore(gitRemoteProc)
    gitRemoteProc.command = ["git", "-C", root.storeDir, "remote", "get-url", "origin"]
    root._start(gitRemoteProc)
  }

  function tryPush() {
    root._gitVerbose = false
    root._checkRemote("push")
  }

  function push() {
    root._gitVerbose = true
    root._checkRemote("push")
  }

  function pull() {
    if (root.storeDir === "") return false
    if (gitPullProc.running) return false
    root._withStore(gitPullProc)
    gitPullProc.command = ["git", "-C", root.storeDir, "pull", "--rebase"]
    root._start(gitPullProc)
    return true
  }

  Process {
    id: gitRemoteProc
    // stdout is anonymous and stays that way. This child's stdout IS the
    // remote URL - the one string in the whole component that is allowed to
    // carry a credential - so it is given no id at all: a named collector is
    // a reference somebody could read it through. Nothing here reads it.
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: (exitCode, exitStatus) => {
      // This child reads .git/config and opens no socket: it decides
      // whether a push is worth attempting, and its URL is never read.
      root.gitReady = exitCode === 0
      const next = root._gitNext
      root._gitNext = ""
      if (exitCode !== 0 || next !== "push") return
      if (gitPushProc.running) return
      root._withStore(gitPushProc)
      gitPushProc.command = ["git", "-C", root.storeDir, "push", "-u", "origin", "HEAD"]
      root._start(gitPushProc)
    }
  }

  Process {
    id: gitPushProc
    stdout: StdioCollector { id: pushOut }
    stderr: StdioCollector { id: pushErr }
    onExited: (exitCode, exitStatus) => {
      const out = String(pushOut.text) + String(pushErr.text)
      // Same rule as the pull, and the reason it is worth saying twice: `out`
      // is read a line below for the toast and it names the branch and the
      // remote. It stays in the toast, which the user asked for, and never
      // reaches a log.
      Log.info("git push, code " + exitCode)
      // What the code alone cannot say: whether anybody was told, and why
      // nothing is recounted. A push is the one direction that cannot change
      // what is on this disk, so a scan would report a model the push cannot
      // have touched - and the toast a reader is asking about only happens
      // for a push the panel asked for, so the two codes are not
      // interchangeable to whoever reads them.
      Log.debug("git push, code " + exitCode + ", "
        + (root._gitVerbose ? "asked by the panel" : "after a mutation")
        + ", listing not rescanned")
      if (exitCode !== 0) {
        root.lastError = "git push failed"
        if (root._gitVerbose) root._notify("Password Manager", "Push failed")
      } else if (root._gitVerbose) {
        root._notify("Password Manager", out.indexOf("up to date") !== -1 || out.indexOf("up-to-date") !== -1
          ? "Already up to date" : "Pushed successfully")
      }
      root._gitVerbose = false
    }
  }

  Process {
    id: gitPullProc
    stdout: StdioCollector { id: pullOut }
    stderr: StdioCollector { id: pullErr }
    onExited: (exitCode, exitStatus) => {
      const out = String(pullOut.text) + String(pullErr.text)
      // The verb and the exit code, and nothing else. This child's output is
      // the one string in the component that can carry a branch, a host and a
      // remote name, and none of what these children print is published: in a
      // password store the name IS the secret, so a branch or a host that
      // identifies a store is a secret too. The exit code is the whole of what
      // is knowable here without publishing any of it.
      Log.info("git pull, code " + exitCode)
      if (exitCode !== 0) {
        // The success arm rescans and this one deliberately does not, and from
        // the INFO line alone there is nothing to tell the two apart. A
        // refused pull changed nothing on this disk, so the model a scan would
        // rebuild is already the right one; naming the absence is what keeps a
        // silent scan from reading as a count still in flight.
        Log.debug("git pull, code " + exitCode + ", refused: no scan follows")
        root.lastError = "git pull failed"
        root._notify("Password Manager", "Pull failed")
        return
      }
      root.lastError = ""
      root._notify("Password Manager", out.indexOf("Already up to date") !== -1
        ? "Already up to date" : "Pulled successfully")
      // The scan that follows is what tells a reader whether the pull
      // brought anything.
      root.refresh()
      // Started or queued is refresh()'s decision, not this child's, and it is
      // the only thing separating "the pull brought nothing" from "the pull's
      // scan has not landed yet" - the two are the same line in the log.
      Log.debug("git pull, code " + exitCode + ", scan "
        + (root._refreshQueued ? "queued behind a running one" : "started"))
    }
  }

  // --- panel body: the window exists only while this controller does ---
  // Opened and closed through the facade, because the surface claim and
  // the close settle live there; this object only renders.
  //
  // The card's share of each screen is asked of ScreenCeiling, which reads
  // the SCREEN and never this window: the window is sized from the card it
  // hosts, so its height resolves in stages, while a screen's height is a
  // settled number from the first frame.
  Variants {
    model: Ui.validScreens

    OverlayWindow {
      id: win

      required property ShellScreen modelData
      screen: modelData
      // The card's share of THIS screen, owned by the shared ceiling so
      // the reason lives in one place. See ScreenCeiling.
      ScreenCeiling {
        id: ceiling
        screen: win.modelData
        fraction: 0.72
        growthFraction: 0.92
      }

      visible: Pass.visible
      overlayOpen: Pass.visible
      primary: modelData === Ui.primaryScreen
      dim: 0.45

      wlrNamespace: "vibranium:pass"

      onCloseRequested: Pass.close()

      Loader {
        anchors.fill: parent
        active: win.primary
        sourceComponent: passPanelComp
      }

      Component {
        id: passPanelComp

        Item {
          PassPanel {
            visible: win.primary
            maxHeight: ceiling.maxHeight
            hardMaxHeight: ceiling.hardMaxHeight
          }
        }
      }
    }
  }
}

pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQml
import QtQuick
import Quickshell
// IpcHandler and the credential transport's Process; every store child and
// every file read now lives with the controller that drives it.
import Quickshell.Io
import qs.common
import "Model.js" as Model
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/security/SecretOwnership.js" as SecretOwnership

// Pass password-manager service in the shell's own process. A
// resident facade over a demand-loaded controller: the IPC target, the
// surface claim, the credential exit path and the panel's view state are
// here and live for the whole session, while every piece of store work
// (the binary probe, the store resolve, the .gpg-id read, the find scan,
// the git checks, the pass/gpg children and the panel tree) lives in
// PassController and is built on first use.
//
// The singleton cannot be unloaded, so the split is not "hide the
// singleton": UnitGate leases the unit, a Loader holds the controller,
// and the facade releases both after the close animation has played.
// A shell that never opens the password manager pays for none of the
// construction work - which is the whole point of the unit being
// first_use in Boot's catalog.
//
// Nothing here hands out the controller. The public read surface below
// is a projection of it (empty and unknown while it is gone), so a
// consumer can never hold a reference to the tree behind the facade.
Singleton {
  id: root

  readonly property string tag: "pass"
  readonly property string unitId: "pass"

  // --- panel view state ---
  // The panel's own navigation, kept here because it outlives a single
  // open and needs no store, no process and no controller to answer.
  property string mode: "menu" // menu | browse | action | create
  property string currentDir: ""
  property string selectedPath: ""

  // Reload survival for visibility (memory-only, never disk): the
  // binding reads through persist, imperative sets write back below.
  PersistentProperties {
    id: persist
    reloadableId: "pass-visible"
    property bool visible: false
  }
  property bool visible: persist.visible
  readonly property bool open: root.visible
  // Whether a panel has already been opened over a controller, which is
  // what separates the open that inherits the controller it was handed from
  // the opens that have to look at the store again.
  property bool _panelOpened: false
  onVisibleChanged: {
    persist.visible = visible
    // Either direction hands the controller's lifetime to the panel: an
    // open cancels a release the grace had pending, and a close is already
    // closeSettle's, so the idle timer has nothing left to decide.
    idleRelease.stop()
    if (!root.visible) return
    // The first open is answered by the construction it came with; every
    // later one re-probes, so a pass binary or a .gpg-id that appeared
    // while the panel was closed is still picked up.
    if (root._panelOpened) root._refreshOnOpen()
    root._panelOpened = true
  }

  // Staged-delete marks are panel input, not store state. The set is
  // created once and handed to every controller, so PassEntry's
  // Connections target and its pending bindings survive a teardown; a
  // mark whose controller died unsettled is cancelled by that
  // controller on the way out.
  property OptimisticSet optimistic: OptimisticSet {}
  signal keysReady()
  signal deleteCommitted(string path)

  // --- opaque store tokens ---
  //
  // The map lives here and nowhere else, and "here" is load-bearing: this is
  // the only object in the directory that outlives a panel close, so a token
  // minted for an entry is still that token after the controller is torn
  // down and rebuilt, and a new shell always starts again at #1. The map is
  // private, is never persisted, and is read by nothing but
  // the accessors below - so the whole anonymisation of this component is
  // this block plus the pure helpers in Model.js, and there is no second
  // path to it.
  //
  // A name is passed IN and the token comes out; no caller ever holds the
  // pairing.
  readonly property var _tokens: Model.newTokenMap()
  function entryToken(path) { return Model.token(root._tokens, "entry", path) }
  function folderToken(dir) { return Model.token(root._tokens, "folder", dir) }

  // --- credential transport ---
  // The one exit path for a decrypted value, and the only child the
  // resident facade holds. It stays here on purpose: it is the single
  // place a credential can leave the process, and it outlives a panel
  // close so an in-flight copy is never cut short. The wl-copy argv, the
  // SecretStore.feed() sink and the stdin channel are all spelled here,
  // and the suite case that would pin them
  // (tests/shell/suites/js/modules-wallpaper.test.mjs, the transport-sink
  // case) is recorded as an explicit skip: the case needs a PAM agent and
  // a wl-copy binary, and this environment has neither, so the transport
  // is unverified by the suite. It knows nothing about the store: whoever
  // decrypted a value hands over a handle, and the handle is all that
  // crosses.
  //
  // wl-copy takes flags and the mime type in argv and reads the bytes from
  // stdin, so the value is absent from /proc/<pid>/cmdline and from every
  // process listing. The write channel is closed right after the write
  // because the EOF is mandatory: wl-copy buffers stdin into a temp file and
  // claims the selection only once that read completes.
  property var _secretHandles: []
  // The transport's own status line entry, surfaced through the same
  // read-only projection the controller's errors use: the panel shows
  // whichever is live, the controller's first.
  property string _copyError: ""
  function copySecret(handle) {
    const key = String(handle || "")
    if (key === "" || copyProc.running) return false
    // A copy is a fact about the vault being used, and it is the only thing
    // here worth a line: the handle is a path (`pass:email/gmail`), which this
    // component's own contract calls identifying, and the value never leaves
    // the sink below. Logged on the hand-off rather than on the child's exit
    // because `wl-copy` outliving the shell is normal and the transport
    // succeeding is not this component's news.
    Log.info("copied entry")
    Log.debug("hand-off armed, transport " + (copyProc.running ? "starting" : "idle"))
    copyProc._handle = key
    // The sink is a closure that writes straight into the child, so the
    // value never becomes a return value any caller could hold on to.
    copyProc._sink = () => SecretStore.feed(key, v => copyProc.write(v))
    copyProc._fed = false
    copyProc.stdinEnabled = true
    copyProc.command = ["wl-copy", "--sensitive", "--type", "text/plain"]
    root._secretHandles = root._secretHandles.concat([key])
    root._copyError = ""
    copyProc.running = true
    copyFeed.restart()
    copyTimeout.restart()
    // A hand-off is the tail of a copy: the value is in the transport, which
    // is the facade's to finish, and the controller is only still needed for
    // a read that has not decrypted yet. The grace starts again from here,
    // so a slow pinentry cannot be cut short by the deadline the demand set.
    idleRelease.restart()
    // What the hand-off costs, which the line above does not say: the value
    // holds a SecretStore slot until the write deadline expires, and the
    // controller keeps its own grace rather than the one the demand armed.
    // A copy followed by no teardown is the shape of a stuck shell, and both
    // numbers are what tell it apart from a value still in flight.
    Log.debug("copied entry: store slot held to the " + copyTimeout.interval
      + "ms write deadline, controller grace re-armed")
    return true
  }
  function _untrackSecret(handle) {
    root._secretHandles = SecretOwnership.untrack(root._secretHandles, handle)
  }
  // Whether the transport would take a value right now. A caller reads this
  // to refuse a read it could not hand off, instead of starting one.
  function copyIdle() {
    return !copyProc.running
  }
  // A slot the child never took is released here instead of staying in the
  // store until the session ends.
  function _forgetSecret(handle) {
    root._secretHandles = SecretOwnership.forget(SecretStore, root._secretHandles, handle)
  }
  function _releaseSecrets() {
    root._secretHandles = SecretOwnership.releaseAll(SecretStore, root._secretHandles)
  }

  Process {
    id: copyProc
    property var _sink: null
    property string _handle: ""
    property bool _fed: false
    stdinEnabled: false
    running: false
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onStarted: root._feedCopyStdin()
    onExited: {
      copyFeed.stop()
      copyTimeout.stop()
      copyProc._sink = null
      // Covers the child that exited before the write went out: the value it
      // was going to receive is released here instead of staying in the store.
      root._forgetSecret(copyProc._handle)
      copyProc._handle = ""
    }
  }
  // Feed fallback for the case where no started signal arrives: the write
  // also goes out once the child owns a pid.
  Timer {
    id: copyFeed
    interval: 250
    repeat: false
    onTriggered: root._feedCopyStdin()
  }
  Timer {
    id: copyTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      // A child that never finished reading its stdin would hold the
      // credential in the store slot forever.
      if (copyProc.running) copyProc.running = false
      copyProc._sink = null
      root._forgetSecret(copyProc._handle)
      copyProc._handle = ""
      root._copyError = "copy timed out"
      root._notify("Password Manager", "Copy timed out")
    }
  }
  function _feedCopyStdin() {
    if (copyProc._fed || !copyProc.running) return
    const sink = copyProc._sink
    if (typeof sink !== "function") return
    copyProc._fed = true
    try { sink() } catch (ignored) { }
    // The slot is gone by now, whatever the sink did with the value.
    root._untrackSecret(copyProc._handle)
    // Process maps stdinEnabled=false onto QProcess::closeWriteChannel().
    copyProc.stdinEnabled = false
  }

  // Token for the exclusive-surface claim this open holds, released by
  // hidePanel() and by Component.onDestruction.
  property var _claimToken: null

  // --- controller lifecycle ---
  // The lease, the state and the Loader are the shared UnitLease; what each
  // facade keeps is when to give the controller back.
  readonly property string gateOwner: "pass-facade"

  UnitLease {
    id: lease
    unitId: root.unitId
    owner: root.gateOwner
    controllerComponent: controllerComp
  }

  readonly property alias controllerState: lease.phase
  readonly property alias controllerError: lease.error
  readonly property bool controllerReady: lease.phase === "ready"
  readonly property bool facadeReady: root.tag !== ""
  readonly property alias constructions: lease.constructions

  // --- public read surface (projected) ---
  readonly property string storeDir: lease.controller !== null ? lease.controller.storeDir : ""
  readonly property bool initialized: lease.controller !== null ? lease.controller.initialized : false
  readonly property var entries: lease.controller !== null ? lease.controller.entries : []
  readonly property var allDirs: lease.controller !== null ? lease.controller.allDirs : []
  readonly property bool busy: lease.controller !== null ? lease.controller.busy : false
  readonly property string lastError: Model.statusError(
    lease.controller === null ? "" : lease.controller.lastError, root._copyError)
  readonly property string passBinary: lease.controller !== null ? lease.controller.passBinary : "unknown"
  readonly property bool gitReady: lease.controller !== null ? lease.controller.gitReady : false
  readonly property var keyChoices: lease.controller !== null ? lease.controller.keyChoices : []

  Component.onCompleted: {
    Registry.offer("pass", {
      title: "Password manager",
      description: "native pass frontend",
      verbNames: [
        "open",
        "copy",
        "close",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register("pass", root)
    // Boot alongside the shell: build the controller (binary probe, store
    // resolve, find scan, git check) in the background so the first open
    // shows a warm vault in one frame instead of a cold "0 entries" +
    // "Working..." skeleton. The demand holds its lease; idleRelease skips
    // panel-opened controllers, so this survives until the session ends.
    // A shell without `pass` installed still pays one cheap probe - the
    // price of an instant first frame.
    Idle.run(() => {
      if (lease.controller !== null) return
      if (root.visible) return
      if (lease.demand() !== null) idleRelease.stop()
    }, 0, 0, "pass-prewarm")
    // A reload with the panel open lands here with visible already true
    // and no claim (a claim is memory-only), so the open is replayed
    // through showPanel() after clearing the flag: the claim and the
    // controller come back exactly as they were before the reload.
    if (root.visible) {
      root.visible = false
      root.showPanel()
    }
  }

  Component.onDestruction: {
    idleRelease.stop()
    // The controller goes before the lease does, so no gate observer ever
    // sees the unit released while its child is still alive.
    root.teardownController()
    // A store slot and an in-flight copy child are the only things that can
    // outlive a panel: release both, and the child goes with this singleton.
    root._releaseSecrets()
    if (copyProc.running) copyProc.running = false
    copyProc._sink = null
    copyProc._handle = ""
    SurfaceClaim.releaseOwner(root)
    Registry.unregister("pass")
  }

  // The transport needs it for its own timeout; every other message comes
  // from the controller, which owns the flow that failed.
  function _notify(summary, body) {
    Exec.notifyStatus(summary, body)
  }

  // --- open / close ---
  function showPanel() {
    if (root.visible) return true
    // Demand first: without a controller there is no window to show, so
    // the claim must not be taken and `visible` must not be set.
    if (lease.demand() === null) return false
    root.mode = "menu"
    root.currentDir = ""
    root.selectedPath = ""
    root.visible = true
    // Claimed once the panel is up, not before: the stored closer is
    // hidePanel, which refuses to run while `visible` is false, so a claim
    // taken earlier would install a closer that provably does nothing and
    // leave a claim nobody can retire if the rest of the opening throws.
    // The store is not probed here: the controller that just arrived has
    // already probed the binary and scanned the store, and refresh() blocks
    // on the .gpg-id read, so a second pair here made the first open pay for
    // two full scans. onVisibleChanged re-probes from the second open on.
    root._claimToken = SurfaceClaim.claim("pass", root.hidePanel, root)
    return true
  }
  function hidePanel() {
    if (!root.visible) return
    root.visible = false
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
    // The controller stays resident once a panel has been opened: tearing the
    // tree down on every close made every open pay for a binary probe, a
    // .gpg-id read, a find scan and a git remote check from an empty
    // projection ("Browse Vault (0 entries)", "Working...", no git rows) -
    // the reported staged boot. The window fade needs no teardown (the tree
    // is hidden, not destroyed); flows still report through the live
    // controller, and the next open inherits a warm scan and only re-probes
    // in the background (see onVisibleChanged). Copy-only demands without a
    // panel still release via idleRelease.
  }
  function open() { root.toggle(); return true }
  function close() { root.hidePanel(); return true }
  function toggle() { root.visible ? root.hidePanel() : root.showPanel() }

  // --- navigation (view state only, no controller required) ---
  function browseTo(dir) {
    root.currentDir = String(dir || "")
    root.mode = "browse"
  }
  function select(path) {
    root.selectedPath = String(path || "")
    root.mode = "action"
  }
  // One peel step; the panel's Esc chain drives it. The rule is the store
  // library's, this is the facade's own state it is applied to.
  function back() {
    const step = Model.navigationBack(root.mode, root.currentDir)
    if (step.mode !== undefined) root.mode = step.mode
    if (step.dir !== undefined) root.currentDir = step.dir
    if (step.close === true) root.hidePanel()
  }

  // --- demand / teardown ---
  // Build the controller on first use and keep exactly one. Repeated
  // callers - a held key, a second IPC verb, the panel's own close - all
  // land here, and every path out (refused lease, failed construction,
  // unload) drops the lease again, so a refused or failed caller leaves
  // the next one a clean unit.
  // Drop the controller and the lease, then state the outcome. The flag is
  // what keeps the teardown the gate performs on the way out - it runs
  // teardownController() from inside the release - from restating
  // "unloaded" in the middle of a demand that is about to report why it
  // failed, so the state sequence a consumer sees is the facade's own.
  // Drop the controller and the lease without touching the reported state.
  // A caller that is about to answer unavailable or failed unwinds through
  // here, so the state it reports is the last one a consumer sees instead of
  // flapping through "unloaded" on the way there.
  // Idempotent and callable with nothing loaded: Boot's unit teardown
  // hook and the close settle both land here, and the second call is a
  // no-op rather than a double release.

  // Boot's unit teardown hook calls this by name on every facade, so the
  // shared lease teardown is republished under the name the hook owns.
  function teardownController() {
    return lease.teardown()
  }

  // The gate's teardown hook drops this owner's whole lease set in one
  // call, so the ensure and the retain that came with it go together and
  // a lost release cannot leave the record counting an owner nobody holds.
  // --- idle release ---
  // The close settle only runs when a panel was opened, so the one demand
  // that opens nothing - the copy verb - had no way back to teardown: the
  // store probe, the find, git and gpg children, the model and the panel
  // tree all stayed resident with no claim, no window and visible false.
  // The release is armed where the controller is built and where a value
  // reaches the transport, so no demand site has to remember to give the
  // controller back, and it waits for a copy to land before it does.
  function _releaseIfIdle() {
    // Only a controller the facade accepted: a refused or failed demand
    // reports its own state to the next caller, and a timer landing on it
    // would restate that as "unloaded". A panel that is up owns its
    // controller outright - the close settle is the path that gives it
    // back, and a copy the panel itself asked for arms this timer too.
    if (root.controllerState !== "ready" || lease.controller === null) return false
    if (root.visible) return false
    // A panel that has ever been opened keeps its controller resident (see
    // hidePanel): the next open must show a warm vault in one frame, not a
    // cold skeleton. Only copy-only demands (no panel yet) release here.
    if (root._panelOpened) return false
    // A copy is in flight from here until the transport child is gone and
    // the controller has no read left to finish. Releasing now would drop a
    // value mid-decrypt, and the credential slot is released by the
    // controller's own teardown - once, whether it runs from here or from
    // the close settle.
    if (copyProc.running || root._secretHandles.length > 0
      || lease.controller.copyPending === true) {
      idleRelease.restart()
      return false
    }
    return root.teardownController()
  }

  // The open-time pair, from the second open on: what the first open
  // inherited from the controller it was handed is a store scan that just
  // ran, and repeating it there doubled the blocking .gpg-id read. What it
  // cannot inherit is the state of the world a moment later, so a binary
  // that got installed or a .gpg-id that appeared between two opens still
  // reaches the panel.
  function _refreshOnOpen() {
    const ctrl = lease.controller
    if (ctrl === null) return false
    ctrl.probeBinary()
    ctrl.refresh()
    return true
  }

  // Defined answer for every verb while the controller is not there, so
  // an IPC caller learns why instead of getting a silent no-op.
  function _unavailableVerb() {
    return Model.unavailableVerb(root.controllerState, root.controllerError)
  }

  // --- command verbs: one controller, a defined refusal when there is none ---
  function copyEntry(path) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.copyEntry(path) === true
  }
  function createFolder(path) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.createFolder(path) === true
  }
  function moveEntry(from, to) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.moveEntry(from, to) === true
  }
  function removeEntry(path) {
    return root.requestDelete(path)
  }
  function requestDelete(path) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.requestDelete(path) === true
  }
  function insertEntry(path, secret, force) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.insertEntry(path, secret, force) === true
  }
  function generateEntry(path, force) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.generateEntry(path, force) === true
  }
  function editEntry(path) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.editEntry(path) === true
  }
  function initStore(key) {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.initStore(key) === true
  }
  function requestKeys() {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.requestKeys() === true
  }
  function push() {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.push() === true
  }
  function pull() {
    const ctrl = lease.demand()
    return ctrl !== null && ctrl.pull() === true
  }

  // --- IPC ---
  IpcHandler {
    target: "pass"
    function help(command: string): string {
      return UnitIpc.help("pass", "Password manager", "native pass frontend", [
        { name: "open", help: "show/hide the panel" },
        { name: "copy", help: "(path) copy line 1" },
        { name: "close", help: "hide the panel" },
        { name: "toggle", help: "show/hide" },
      ], command)
    }
    function ping(): string { return "pong" }
    // open is the shell's toggle key, so both halves answer "ok"; the
    // opening half answers the controller's state instead when the panel
    // could not be built.
    function open(): string { return root._toggleVerb() }
    function close(): string { root.hidePanel(); return "ok" }
    function toggle(): string { return root._toggleVerb() }
    function status(): string {
      const unit = UnitGate.state(root.unitId)
      return JSON.stringify({
        storeDir: root.storeDir,
        initialized: root.initialized,
        count: root.entries.length,
        dirs: root.allDirs.length,
        busy: root.busy,
        lastError: root.lastError,
        visible: root.visible,
        mode: root.mode,
        git: root.gitReady,
        controller: root.controllerState,
        controllerError: root.controllerError,
        constructions: root.constructions,
        owners: unit === null ? 0 : unit.ownerCount
      })
    }
    function copy(path: string): string {
      const ctrl = lease.demand()
      if (ctrl === null) return root._unavailableVerb()
      return ctrl.copyEntry(path || "") ? "ok" : "error:copy"
    }
  }

  function _toggleVerb() {
    const wasVisible = root.visible
    root.toggle()
    return Model.toggleReply(wasVisible, root.controllerState, root.visible,
      root.controllerError)
  }

  // The controller, and nothing else: a Loader with no source until the
  // first demand, so a facade that is only an IPC target holds no store
  // child, no file read, no window and no panel tree. The two signals the
  // facade re-emits are wired here, at the only place the controller is
  // named.
  Component {
    id: controllerComp

    PassController {
      optimistic: root.optimistic
      onKeysReady: root.keysReady()
      onDeleteCommitted: (path) => root.deleteCommitted(path)
    }
  }

  // The grace a demand that opened no panel keeps its controller for. Long
  // enough that a copy followed by an open reuses the store scan the copy
  // already paid for, short enough that the residue of a copy nobody
  // followed up on is gone within a second. Bounded and one-shot: a later
  // demand re-arms it, the panel's own open or close stops it, and a copy
  // still in flight re-arms it rather than losing the value.
  Timer {
    id: idleRelease
    interval: 1200
    repeat: false
    onTriggered: root._releaseIfIdle()
  }
}

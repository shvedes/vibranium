pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters duplicated-name
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.menu
import "Model.js" as Model
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/security/SecretOwnership.js" as SecretOwnership

// Pass is an ordinary menu service. Its whole user-facing surface is two
// dynamic pages built from the controller's five store facts; it has no
// window, no row renderer, no key handling and no navigation state of its own.
// The menu owns the surface, the stack and the focus; this object owns the
// derivation, the providers keyed by row id, the verbs and the one credential
// exit path.
//
// "One state, many derivations": the controller writes entries, allDirs,
// gitReady, passBinary and initialized. Everything on screen is a function of
// those five values, recomputed on a single deferred publish edge. Publishing
// is the only writer of the page table, the provider table and the page API,
// and it re-supplies all three on every injection because a container load
// drops injected pages.
Singleton {
  id: root

  readonly property string tag: "pass"
  readonly property string unitId: "pass"
  readonly property string menuPage: "pass-menu"
  readonly property string vaultPage: "pass-vault"

  // --- controller lifecycle ------------------------------------------------
  // The resident facade leases a demand-loaded controller. A shell that never
  // summons Pass pays for no probe, no find scan and no store child.
  readonly property string gateOwner: "pass-facade"

  UnitLease {
    id: lease
    unitId: root.unitId
    owner: root.gateOwner
    controllerComponent: controllerComp
  }

  readonly property alias controllerState: lease.phase
  readonly property alias controllerError: lease.error
  readonly property alias constructions: lease.constructions
  readonly property bool facadeReady: root.tag !== ""

  // --- public read surface (projection, empty/unknown while controller gone)
  readonly property string storeDir: lease.controller !== null ? lease.controller.storeDir : ""
  readonly property bool initialized: lease.controller !== null ? lease.controller.initialized : false
  readonly property var entries: lease.controller !== null ? lease.controller.entries : []
  readonly property var allDirs: lease.controller !== null ? lease.controller.allDirs : []
  readonly property bool busy: lease.controller !== null ? lease.controller.busy : false
  readonly property string passBinary: lease.controller !== null ? lease.controller.passBinary : "unknown"
  readonly property bool gitReady: lease.controller !== null ? lease.controller.gitReady : false
  readonly property var keyChoices: lease.controller !== null ? lease.controller.keyChoices : []
  readonly property string lastError: Model.statusError(
    lease.controller === null ? "" : lease.controller.lastError, root._copyError)

  // The five facts are read together. A binding on this object re-evaluates
  // once for any of them, and its only consequence is arming one deferred
  // publish - never a second stored copy of the page.
  readonly property var pageFacts: ({
    entries: root.entries,
    allDirs: root.allDirs,
    gitReady: root.gitReady,
    passBinary: root.passBinary,
    initialized: root.initialized
  })

  property bool _publishArmed: false
  property bool _forcePublish: false
  property string _lastPublishSig: ""
  onPageFactsChanged: root._schedulePublish()

  // Republishing rebuilds every nested row and its search index. A fact
  // change that leaves the projection identical (a probe or a refresh with
  // no store change) must not pay that cost on the UI thread.
  function _publishSig() {
    const paths = root.entries.map(e => e && e.path ? e.path : "").join(",")
    return [root.passBinary, root.initialized, root.gitReady, paths,
      root.allDirs.join(",")].join("|")
  }

  // Staged-delete marks belong to the controller work, but the shared map is
  // created here so a row's pending binding survives a controller teardown.
  property OptimisticSet optimistic: OptimisticSet {}
  signal keysReady()
  signal deleteCommitted(string path)

  // Opaque log tokens are minted here, on the resident facade: a token has to
  // keep meaning the same entry across a controller rebuild. The controller
  // passes names in and gets a counter back; no caller holds the pairing.
  readonly property var _tokens: Model.newTokenMap()
  function entryToken(path) { return Model.token(root._tokens, "entry", path) }
  function folderToken(dir) { return Model.token(root._tokens, "folder", dir) }

  // --- credential transport ------------------------------------------------
  // The one exit path for a decrypted value, and the only Process the facade
  // holds. The controller never sees the wl-copy child and the child never
  // sees a plaintext QML property: the value moves from SecretStore straight
  // into its stdin. wl-copy takes flags in argv and reads bytes on stdin, so
  // the secret is absent from /proc/<pid>/cmdline, from history and from
  // every notification. The write channel closes on the feed edge because
  // wl-copy claims the selection only after stdin reaches EOF.
  property var _secretHandles: []
  property string _copyError: ""

  function copySecret(handle) {
    const key = String(handle || "")
    if (key === "" || copyProc.running) return false
    copyProc._handle = key
    copyProc._sink = () => SecretStore.feed(key, v => copyProc.write(v))
    copyProc._fed = false
    copyProc.stdinEnabled = true
    copyProc.command = ["wl-copy", "--sensitive", "--type", "text/plain"]
    root._secretHandles = root._secretHandles.concat([key])
    root._copyError = ""
    copyProc.running = true
    copyTimeout.restart()
    idleRelease.restart()
    return true
  }
  function copyIdle() { return !copyProc.running }
  function _untrackSecret(handle) {
    root._secretHandles = SecretOwnership.untrack(root._secretHandles, handle)
  }
  function _forgetSecret(handle) {
    root._secretHandles = SecretOwnership.forget(SecretStore, root._secretHandles, handle)
  }
  function _releaseSecrets() {
    root._secretHandles = SecretOwnership.releaseAll(SecretStore, root._secretHandles)
  }
  function _notify(summary, body) { Exec.notifyStatus(summary, body) }

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
      copyTimeout.stop()
      copyProc._sink = null
      root._forgetSecret(copyProc._handle)
      copyProc._handle = ""
    }
  }
  // onStarted is the only feed edge: Process publishes it for every child
  // that reaches exec, so there is no readiness guess here.
  Timer {
    id: copyTimeout
    interval: 5000
    repeat: false
    onTriggered: {
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
    root._untrackSecret(copyProc._handle)
    copyProc.stdinEnabled = false
  }

  // --- page publication ----------------------------------------------------
  // One deferred edge, armed by the fact binding, by a summon and by a
  // container drop. There is no "tries" counter and no readiness timer: a
  // later edge simply supplies the newest derivation again.
  function _schedulePublish() {
    if (root._publishArmed) return
    root._publishArmed = true
    Qt.callLater(root._publish)
  }

  property var _landing: null
  property bool _summonLanding: false

  // One resolver for every Pass row. The menu asks for a surface by row id;
  // no per-row ProviderHost claim is needed, so a store change no longer
  // copies the frozen provider table hundreds of times on the UI thread.
  function _surfaceForId(id) {
    const key = String(id || "")
    if (key.indexOf("pass:") !== 0) return null
    if (key.indexOf("pass:create-folder:") === 0
      || key.indexOf("pass:create-file:") === 0
      || key.indexOf("pass:rename:") === 0
      || key.indexOf("pass:move:") === 0) {
      return {
        runFlow: (it, vals) => root._runFlow(it, vals),
        forget: value => root._forgetPath(String(value || ""))
      }
    }
    if (key.indexOf("pass:delete:") === 0) {
      return {
        iconAccent: () => "red",
        runConfirm: it => root._deletePath(String(it.value || "")),
        forget: value => root._forgetPath(String(value || ""))
      }
    }
    if (key.indexOf("pass:dir:") === 0) {
      return { forget: value => root._forgetPath(String(value || "")) }
    }
    return null
  }

  function _publish() {
    if (!root._publishArmed) return
    root._publishArmed = false
    if (typeof Menu === "undefined" || !Menu || !Menu.injectPage) return
    const forced = root._forcePublish || root._summonLanding || root._landing !== null
    root._forcePublish = false
    const sig = root._publishSig()
    if (!forced && sig === root._lastPublishSig) return
    root._lastPublishSig = sig

    const menuItems = root._menuRows()
    const vaultItems = root._vaultRows()
    // The page API is re-supplied on every inject: a container reload drops
    // the dynamic API table along with the pages.
    const api = {
      forget: value => root._forgetPath(String(value || "")),
      provider: id => root._surfaceForId(id)
    }
    // The vault can hold far more rows than the panel's default ceiling; a
    // tall page ceiling keeps the last row visible instead of cropping it.
    const pageOpts = { maxHeight: 1100 }
    // Pass is a standalone menu that reuses the shared primitives. Its rows
    // stay out of the global index, so typing narrows this vault only.
    Menu.injectPage(Menu.buildDynamicPage(root.menuPage, "Password manager", 0, menuItems, pageOpts), api, false)
    Menu.injectPage(Menu.buildDynamicPage(root.vaultPage, "Vault", 0, vaultItems, pageOpts), api, false)

    if (root._summonLanding) {
      root._summonLanding = false
      Menu.jumpTo(root.menuPage, 0)
      return
    }
    if (root._landing !== null) {
      const landing = root._landing
      root._landing = null
      root._releaseFocusLanding(landing)
    }
  }

  // A landing is released on the page's real settled edge. The waiter's guard
  // reads the live page, so a slow rescan holds it instead of being guessed by
  // a timer, and a stale intent is retired by replacing _landing before it is
  // ever published.
  function _releaseFocusLanding(landing) {
    const panel = Menu.panel
    if (!panel || !panel.listView || !Array.isArray(landing.chain) || landing.chain.length === 0) return
    if (landing.closeGroup) {
      const group = Menu.itemByUid(landing.closeGroup)
      if (group) {
        Menu.setExpanded(group, false)
        // The same publish swaps this group's delegate, so its fold never
        // reports slotCloseFinished and Menu.slotClosing would stay armed
        // forever, holding every settled waiter (including this landing)
        // shut. Clear the latch on the next edge, after the fold has started.
        Qt.callLater(() => Menu.slotCloseFinished(group))
      }
    }
    if (landing.flowUid) {
      const flowUid = landing.flowUid
      const flowItem = Menu.itemByUid(flowUid)
      // Resetting a flow clears its stage cursor but not the row's expanded
      // state. Without this the wizard stays open and keeps the keyboard
      // while the landing tries to focus the newly created entry.
      if (flowItem && Menu.isExpanded(flowItem)) Menu.setExpanded(flowItem, false)
      // The committed flow row folds as its editor closes, but this same
      // publish replaces its delegate before that fold reports. Clear its
      // latch on the next edge so Menu.slotClosing cannot hold the landing
      // waiter shut forever.
      Qt.callLater(() => Menu.slotCloseFinished({ uid: flowUid }))
    }
    // Only a summon needs the root-frame teleport. A mutation landing is a
    // focus change on the page already showing; jumping here would discard the
    // pass-menu frame below and make Back close the whole menu.
    if (!Menu.frame || Menu.frame.id !== landing.page) Menu.jumpTo(landing.page, 0)
    const ready = () => Menu.frame && Menu.frame.id === landing.page
    const chain = landing.chain
    // A created entry is published only after its child exits and the find
    // scan lands; a deleted one is still on the page until that scan lands.
    // The guard reads the live page instead of spending the landing on the
    // first settled frame, so it releases on the real publish edge - no
    // timer, no retry budget, and no stale fallback.
    const gone = landing.waitGone || ""
    const present = () => ready() && (gone === "" || !Menu.itemByUid(gone))
      && !!Menu.itemByUid(chain[chain.length - 1])
    // The first settled edge opens the ancestors. A second one re-seats the
    // target: the publish's own model swap can echo its old index in between,
    // and taking the seat on that edge is the only way to keep it from winning.
    panel.whenSettled(() => {
      if (!ready()) return
      const idx = Menu.visibleIndexOfUid(landing.page, chain[0])
      if (idx < 0) return
      const list = panel.listView
      // landIndex takes the cursor without the generic center-follow that
      // snapped contentY across the list. The reveal engine scrolls smoothly.
      list.landIndex(idx)
      // One state write for the whole ancestor chain instead of one rev bump
      // per level; each bump re-projected and re-measured the entire vault.
      const ancestors = []
      for (let i = 0; i + 1 < chain.length; i++) {
        const it = Menu.itemByUid(chain[i])
        if (it) ancestors.push(it)
      }
      if (ancestors.length > 0) Menu.setExpandedBatch(ancestors, true)
      // A nested whenSettled waiter drains inside the same call and its child
      // seat is undone by the expansion's own cursor seed. One deferred turn
      // is an edge, not a retry budget: the expansion has landed by then.
      Qt.callLater(() => {
        if (!ready()) return
        const at = Menu.visibleIndexOfUid(landing.page, chain[0])
        if (at < 0) return
        const list2 = panel.listView
        let r = list2.itemAtIndex(at)
        for (let i = 0; i + 1 < chain.length && r; i++) {
          const kids = r.groupChildren || []
          let found = -1
          for (let j = 0; j < kids.length; j++) {
            if (kids[j] && kids[j].uid === chain[i + 1]) { found = j; break }
          }
          if (found < 0) break
          r.childIndex = found
          r = r._focusedChildRow ? r._focusedChildRow() : null
        }
        list2.landIndex(at)
        // The group's slot geometry settles a frame after the child seat;
        // re-seat once more on that edge so the highlight cannot span the
        // rows the expansion just moved.
        panel.whenSettled(() => {
          if (!ready()) return
          const at2 = Menu.visibleIndexOfUid(landing.page, chain[0])
          if (at2 < 0) return
          // "click" is the persistent seat cause: track() records it as user
          // motion, so a later model swap cannot restore the pre-create row.
          panel.listView.landIndex(at2)
          // Start the reveal only here, on the settled edge: an earlier
          // pursuit aims at a viewport that has not grown to its final
          // height and overshoots, then snaps back when the card settles.
          panel.listView.autoRevealIndex = at2
        }, ready)
      })
    }, present)
  }

  // The menu keys state by uid, not by the row id a provider is claimed with.
  // A uid is pageId + "#" + uidKey(id), and a nested child's key carries every
  // ancestor's key as a "/" prefix (MenuPage.normalizeChildren). Building the
  // landing chain here keeps that vocabulary in one place.
  function _uidFor(id) {
    const key = String(id || "").replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
    return root.vaultPage + "#" + key
  }
  // A "Create here" row lives inside its folder's dropdown, so its uid
  // carries every ancestor folder key as a "/" prefix (MenuPage normalizes
  // children that way). Closing it by a bare uid is a no-op and leaves the
  // group open after a create.
  function _createGroupUid(dir) {
    if (dir === "" || dir === "root") return root._uidFor(Model.rowId("create-group", "root"))
    const parts = String(dir).split("/").filter(p => p !== "")
    let prefix = ""
    for (let i = 0; i < parts.length; i++) {
      const key = String(Model.rowId("dir", parts.slice(0, i + 1).join("/")))
        .replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
      prefix = prefix ? prefix + "/" + key : key
    }
    const leaf = String(Model.rowId("create-group", dir))
      .replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
    return root.vaultPage + "#" + prefix + "/" + leaf
  }

  function _chainFor(path, isDir) {
    const parts = String(path || "").split("/").filter(p => p !== "")
    const chain = []
    let prefix = ""
    // For a file the last segment is the file itself, not a folder above it.
    const dirCount = isDir ? parts.length : Math.max(0, parts.length - 1)
    for (let i = 0; i < dirCount; i++) {
      const key = (prefix ? prefix + "/" : "")
        + String(Model.rowId("dir", parts.slice(0, i + 1).join("/")))
          .replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
      chain.push(root.vaultPage + "#" + key)
      prefix = key
    }
    // A folder target is its own last ancestor: appending it twice would make
    // the walker try to open the target inside itself and abandon the landing.
    if (!isDir) {
      const leaf = String(Model.rowId("file", String(path || "")))
        .replace(/[#:]/g, "-").replace(/[\x00-\x1f\x7f]/g, "-")
      chain.push(root.vaultPage + "#" + (prefix ? prefix + "/" : "") + leaf)
    }
    return chain
  }
  function _landOn(path, isDir, closeGroup, flowUid) {
    root._landing = {
      page: root.vaultPage,
      chain: root._chainFor(path, isDir),
      closeGroup: closeGroup || "",
      flowUid: flowUid || ""
    }
    root._schedulePublish()
  }

  // --- composition: pass-menu ----------------------------------------------
  function _warning(id, text) {
    return {
      type: "expandable", id: id, label: "Password manager unavailable",
      warning: text, desc: text, infoOnly: true, enabled: false
    }
  }

  function _menuRows() {
    if (root.passBinary !== "present")
      return [root._warning("pass:warning", "The pass package is not installed")]
    const rows = [{
      type: "submenu",
      id: "pass:browse",
      label: "Browse vault",
      sub: Model.countWord(root.entries.length, "entry", "entries"),
      icon: "file-folders",
      page: root.vaultPage
    }]
    if (root.gitReady) {
      rows.push({
        type: "group",
        id: "pass:git",
        label: "Git operations",
        sub: "origin configured",
        icon: "git",
        children: [
          { type: "action", id: "pass:push", label: "Push to remote", sub: "upload commits to origin", icon: "git", call: "pass push" },
          { type: "action", id: "pass:pull", label: "Pull from remote", sub: "fetch and rebase from origin", icon: "git", call: "pass pull" }
        ]
      })
    }
    return rows
  }

  // --- composition: pass-vault ---------------------------------------------
  function _createRows(dir) {
    const suffix = dir === "" ? "root" : dir
    return [{
      type: "group",
      id: Model.rowId("create-group", suffix),
      label: dir === "" ? "Create" : "Create here",
      sub: "in " + (dir === "" ? "vault root" : dir),
      icon: "file",
      children: [
        {
          type: "select", id: Model.rowId("create-folder", suffix),
          label: "Folder", sub: "new folder", icon: "file-folder",
          marker: false, hideValue: true, keepOpen: true,
          flow: [
            { kind: "text", placeholder: "Folder name or path", sub: "Create here", subAccent: "Folder name..." }
          ]
        },
        {
          type: "select", id: Model.rowId("create-file", suffix),
          label: "File", sub: "new password", icon: "file",
          marker: false, hideValue: true, keepOpen: true,
          flow: [
            { kind: "text", placeholder: "Entry name or path", sub: "Create here", subAccent: "Entry name..." },
            {
              kind: "select", sub: "Create here", subAccent: "Password source...",
              options: [
                { label: "Generate a password", value: "generate", icon: "update" },
                { label: "Enter a password", value: "enter", icon: "pencil" }
              ]
            },
            {
              kind: "text", placeholder: "Password", sub: "Create here",
              subAccent: "Type the secret...", sensitive: true,
              skipUnless: "enter"
            }
          ]
        }
      ]
    }]
  }

  function _fileRows(path) {
    return [
      { type: "text", id: Model.rowId("rename", path), value: path, label: "Rename", icon: "pencil", hideValue: true,
        placeholder: "New name or path", flow: [
          { kind: "text", placeholder: "New name or path" }
        ] },
      { type: "action", id: Model.rowId("copy", path), value: path, label: "Copy", icon: "copy",
        call: "pass copy %v", hideValue: true, keepOpen: true },
      { type: "select", id: Model.rowId("move", path), value: path, label: "Move", icon: "arrow-corner",
        marker: false, hideValue: true, keepOpen: true,
        flow: [
          { kind: "select", options: root._moveOptions() }
        ] },
      { type: "action", id: Model.rowId("edit", path), value: path, label: "Edit", icon: "tui",
        call: "pass edit %v", hideValue: true },
      { type: "action", id: Model.rowId("delete", path), value: path, label: "Delete", icon: "remove", iconColor: "red", hideValue: true,
        confirm: {
          stages: 2,
          hint: "Press <b>Enter</b> again to delete this password",
          armed: "<b><u>Press again to confirm delete</u></b>",
          label: "Delete"
        } }
    ]
  }

  function _moveOptions() {
    const opts = [{ label: "Vault root", value: "", icon: "file-folders" }]
    const dirs = root.allDirs
    for (let i = 0; i < dirs.length; i++)
      opts.push({ label: dirs[i], value: dirs[i], icon: "file-folder" })
    return opts
  }

  function _folderRow(dir) {
    const ch = Model.childrenOf(root.entries, dir, root.allDirs)
    // Create here is always the first child of a folder, with its own
    // separator directly beneath it, before the folder's contents. Its
    // scope is in the path-derived id, so the row carries no value copy.
    const children = [root._createRows(dir)[0], {
      type: "separator",
      id: Model.rowId("sep", dir),
      sepHeight: 22
    }]
    for (let i = 0; i < ch.dirs.length; i++) {
      const sub = dir === "" ? ch.dirs[i] : dir + "/" + ch.dirs[i]
      children.push(root._folderRow(sub))
    }
    for (let i = 0; i < ch.files.length; i++)
      children.push(root._fileGroupRow(ch.files[i]))
    return {
      type: "group",
      id: Model.rowId("dir", dir),
      label: dir.substring(dir.lastIndexOf("/") + 1),
      sub: Model.folderSubtitle(root.entries, root.allDirs, dir),
      icon: "file-folder",
      delCommand: "@forget",
      value: dir,
      children: children
    }
  }

  function _vaultRows() {
    if (root.passBinary !== "present")
      return [root._warning("pass:vault-warning", "The pass package is not installed")]
    const rows = root._createRows("")
    rows.push({ type: "separator", id: "pass:sep", sepHeight: 22 })
    const ch = Model.childrenOf(root.entries, "", root.allDirs)
    for (let i = 0; i < ch.dirs.length; i++) rows.push(root._folderRow(ch.dirs[i]))
    for (let i = 0; i < ch.files.length; i++)
      rows.push(root._fileGroupRow(ch.files[i]))
    return rows
  }

  // A file row takes Delete / Ctrl+D through the same key-only staged path as
  // a folder. `delCommand` arms the confirmation without changing Enter,
  // which must still open the row's action dropdown.
  function _fileGroupRow(file) {
    return {
      type: "group",
      id: Model.rowId("file", file.path),
      label: file.name,
      icon: "lock",
      value: file.path,
      hideValue: true,
      delCommand: "@forget",
      children: root._fileRows(file.path)
    }
  }

  // --- flow / confirm verbs ------------------------------------------------
  // A committed flow must reopen at its first stage. Entry.collapse() resets
  // the flow of the delegate it holds, but a publish can swap that delegate
  // before the reset lands, leaving the next summon on "generate"/"enter".
  // Clearing by the stable uid here keeps the wizard's cursor correct.
  function _finishFlow(item, ok) {
    if (ok && item && item.uid) Menu.resetFlow({ uid: item.uid })
    return ok
  }

  function _runFlow(item, values) {
    if (!item) return false
    const id = String(item.id || "")
    const v0 = String(values && values["0"] !== undefined ? values["0"] : "").trim()
    const v1 = String(values && values["1"] !== undefined ? values["1"] : "")
    const v2 = String(values && values["2"] !== undefined ? values["2"] : "")
    // A stage swap keeps the outgoing editor alive as a ghost for its fade.
    // When a create republishes the page, that ghost can re-fire accepted()
    // with a seeded text of "undefined" and commit a second, bogus flow.
    // Such a value is never a name the user typed: drop the late commit so
    // it cannot create a stray entry or overwrite the real focus landing.
    if (v0 === "undefined" || v0 === "null") return true
    // An empty name is a cancelled create: close the flow without a notice.
    if ((id.indexOf("pass:create-folder:") === 0
      || id.indexOf("pass:create-file:") === 0) && v0 === "") return true
    if (id.indexOf("pass:rename:") === 0) {
      if (!Model.validPath(v0)) {
        root._notify("Password Manager", "Invalid name")
        return true
      }
      const from = String(item.value || "")
      root._landOn(v0, false, "")
      return root._finishFlow(item, root.moveEntry(from, v0))
    }
    if (id.indexOf("pass:move:") === 0) {
      const from = String(item.value || "")
      const base = from.substring(from.lastIndexOf("/") + 1)
      // A single select stage stores its value at index 0; the destination
      // is that folder plus the file's basename.
      const to = v0 === "" ? base : v0 + "/" + base
      root._landOn(to, false, "")
      return root._finishFlow(item, root.moveEntry(from, to))
    }
    if (id.indexOf("pass:create-folder:") === 0) {
      // The scope is encoded in the path-derived id, never in the row's
      // value slot: a flow stage writes its text there while it is open,
      // and that must not be mistaken for the destination folder.
      const rawDir = id.substring("pass:create-folder:".length)
      const dir = rawDir === "root" ? "" : rawDir
      const full = dir === "" ? v0 : dir + "/" + v0
      if (!Model.validPath(full)) {
        root._notify("Password Manager", "Invalid folder name")
        return true
      }
      const group = root._createGroupUid(dir)
      root._landOn(full, true, group, item.uid)
      return root._finishFlow(item, root.createFolder(full))
    }
    if (id.indexOf("pass:create-file:") === 0) {
      const rawDir = id.substring("pass:create-file:".length)
      const dir = rawDir === "root" ? "" : rawDir
      const full = dir === "" ? v0 : dir + "/" + v0
      if (!Model.validPath(full)) {
        root._notify("Password Manager", "Invalid entry name")
        return true
      }
      const group = root._createGroupUid(dir)
      root._landOn(full, false, group, item.uid)
      const ok = v1 === "enter"
        ? root.insertEntry(full, v2, true)
        : root.generateEntry(full, true)
      return root._finishFlow(item, ok)
    }
    return false
  }

  function _deletePath(path) {
    const p = String(path || "")
    if (p === "") return false
    const focus = Model.neighbourAfter(root.entries, root.allDirs, p)
    if (!root.requestDelete(p)) return false
    const isDir = root.allDirs.indexOf(p) !== -1
    const waitGone = root._uidFor(Model.rowId(isDir ? "dir" : "file", p))
    if (focus === "") {
      root._landing = {
        page: root.vaultPage,
        chain: [root._uidFor(Model.rowId("create-group", "root"))],
        closeGroup: "",
        waitGone: waitGone
      }
    } else {
      const neighbourIsDir = focus.indexOf("pass:dir:") === 0
      const path = focus.replace(/^pass:(dir|file):/, "")
      root._landing = {
        page: root.vaultPage,
        chain: root._chainFor(path, neighbourIsDir),
        // A neighbour folder may still carry an open Create here from an
        // earlier create; close it so one Esc appears to close that folder.
        closeGroup: neighbourIsDir ? root._createGroupUid(path) : "",
        waitGone: waitGone
      }
    }
    root._schedulePublish()
    return true
  }
  function _forgetPath(path) { return root._deletePath(path) }

  // --- command verbs: one controller, defined refusal when there is none ---
  function _unavailableVerb() { return Model.unavailableVerb(root.controllerState, root.controllerError) }
  function _ctrl() { return lease.demand() }

  function copyEntry(path) {
    const c = root._ctrl()
    return c !== null && c.copyEntry(path) === true
  }
  // Registry verbs named by the menu's declarative `call` specs. They are the
  // same functions the IPC handler uses, so a row and `qs ipc call` cannot
  // disagree about what a copy or an edit does.
  function copy(path) { return root.copyEntry(path) }
  function edit(path) { return root.editEntry(path) }
  function createFolder(path) {
    const c = root._ctrl()
    return c !== null && c.createFolder(path) === true
  }
  function moveEntry(from, to) {
    const c = root._ctrl()
    return c !== null && c.moveEntry(from, to) === true
  }
  function requestDelete(path) {
    const c = root._ctrl()
    return c !== null && c.requestDelete(path) === true
  }
  function removeEntry(path) { return root.requestDelete(path) }
  function insertEntry(path, secret, force) {
    const c = root._ctrl()
    return c !== null && c.insertEntry(path, secret, force) === true
  }
  function generateEntry(path, force) {
    const c = root._ctrl()
    return c !== null && c.generateEntry(path, force) === true
  }
  function editEntry(path) {
    const c = root._ctrl()
    return c !== null && c.editEntry(path) === true
  }
  function initStore(key) {
    const c = root._ctrl()
    return c !== null && c.initStore(key) === true
  }
  function requestKeys() {
    const c = root._ctrl()
    return c !== null && c.requestKeys() === true
  }
  function push() {
    const c = root._ctrl()
    return c !== null && c.push() === true
  }
  function pull() {
    const c = root._ctrl()
    return c !== null && c.pull() === true
  }
  function teardownController() { return lease.teardown() }

  // --- summon / dismiss ----------------------------------------------------
  // The menu is the surface. Summoning arms the root-frame landing, re-probes
  // the binary (a package installed while Pass was closed must be picked up)
  // and refreshes the facts; the deferred publish then lands pass-menu.
  function open() {
    // The CTRL-ALT-P keybind calls `pass open`. On the Pass page that is a
    // toggle: a second press must dismiss the same surface, not re-summon it.
    // A menu showing some other page is still a summon, not a close.
    if (root.ownsFrame()) return root.close()
    const c = lease.demand()
    if (c === null) return root._unavailableVerb()
    root._summoned = true
    c.probeBinary()
    c.refresh()
    root._summonLanding = true
    root._schedulePublish()
    if (typeof Menu !== "undefined" && Menu && !Menu.open)
      Menu.openFile(Paths.settingsCatalogPath + "#main")
    // A summon starts in list mode with the row cursor live. The field is a
    // search entry point, not the initial focus: the first printable key goes
    // through the panel's type-to-search route into the global query.
    Qt.callLater(() => {
      if (Menu.panel && typeof Menu.panel.focusFilter === "function")
        Menu.panel.focusFilter("list")
    })
    return "ok"
  }
  function ownsFrame() {
    return typeof Menu !== "undefined" && Menu && Menu.open && Menu.frame
      && (Menu.frame.id === root.menuPage || Menu.frame.id === root.vaultPage)
  }
  function close() {
    if (root.ownsFrame()) {
      if (Menu.panel && typeof Menu.panel.focusFilter === "function")
        Menu.panel.focusFilter("list")
      Menu.close()
    }
    return "ok"
  }
  function toggle() { return root.ownsFrame() ? root.close() : root.open() }

  // Only a copy-only demand (no summon yet) gives its controller back after
  // the grace: a summoned controller stays warm for the next open.
  property bool _summoned: false
  function _releaseIfIdle() {
    if (root.controllerState !== "ready" || lease.controller === null) return false
    if (root._summoned) return false
    if (copyProc.running || root._secretHandles.length > 0 || lease.controller.copyPending === true) {
      idleRelease.restart()
      return false
    }
    return root.teardownController()
  }
  Timer {
    id: idleRelease
    interval: 1200
    repeat: false
    onTriggered: root._releaseIfIdle()
  }

  // --- boot / registry / ipc -----------------------------------------------
  Component.onCompleted: {
    Registry.offer("pass", {
      title: "Password manager",
      description: "native pass frontend",
      verbNames: ["open", "copy", "close", "toggle", "status", "help", "ping"]
    })
    Registry.register("pass", root)
    // A cheap warm probe at boot: the first summon then shows a warm vault.
    Idle.run(() => {
      if (lease.controller !== null) return
      if (root._summoned) return
      if (lease.demand() !== null) idleRelease.stop()
    }, 0, 0, "pass-prewarm")
  }

  // A container load drops every injected page and its API. Republishing is
  // the same derivation as a fact change - no retry loop, no fresh state.
  Connections {
    target: PageHost
    function onPagesDropped() {
      root._forcePublish = true
      root._schedulePublish()
    }
  }

  Component.onDestruction: {
    idleRelease.stop()
    root.teardownController()
    root._releaseSecrets()
    if (copyProc.running) copyProc.running = false
    copyProc._sink = null
    copyProc._handle = ""
    Registry.unregister("pass")
  }

  IpcHandler {
    target: "pass"
    function help(command: string): string {
      return UnitIpc.help("pass", "Password manager", "native pass frontend", [
        { name: "open", help: "toggle the Password manager menu page" },
        { name: "copy", help: "(path) copy line 1 to the clipboard" },
        { name: "close", help: "close the Pass page" },
        { name: "toggle", help: "open/close the Pass page" }
      ], command)
    }
    function ping(): string { return "pong" }
    function open(): string { return root.open() }
    function close(): string { return root.close() }
    function toggle(): string { return root.toggle() }
    function status(): string {
      const unit = UnitGate.state(root.unitId)
      return JSON.stringify({
        storeDir: root.storeDir,
        initialized: root.initialized,
        count: root.entries.length,
        dirs: root.allDirs.length,
        busy: root.busy,
        lastError: root.lastError,
        page: root.ownsFrame() ? Menu.frame.id : "",
        git: root.gitReady,
        pass: root.passBinary,
        controller: root.controllerState,
        controllerError: root.controllerError,
        constructions: root.constructions,
        owners: unit === null ? 0 : unit.ownerCount
      })
    }
    function copy(path: string): string {
      const c = lease.demand()
      if (c === null) return root._unavailableVerb()
      return c.copyEntry(path || "") ? "ok" : "error:copy"
    }
  }

  Component {
    id: controllerComp

    PassController {
      optimistic: root.optimistic
      onKeysReady: root.keysReady()
      onDeleteCommitted: path => {
        // A committed delete always republishes, even when the cached fact
        // signature happens to look unchanged. No deleted row survives a
        // commit on a stale page.
        root._forcePublish = true
        root._schedulePublish()
        root.deleteCommitted(path)
      }
    }
  }
}

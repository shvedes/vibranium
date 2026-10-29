pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.common
import qs.features.menu
import "../../../common/text/UnitIpc.js" as UnitIpc
import "./ThemeScan.js" as ThemeScan

// Theme remover service. Same looks as the main theme picker (ThemePicker):
// a Menu page whose rows carry a `palette` array (hex swatches) rendered as
// little filled dots under the label in Entry.qml - but listing only
// community themes (user dirs with no official counterpart, the set
// vb-theme-remove takes) and running the removal backend per row.
//
// Discovery mirrors vb-theme-set but entirely in the shell: enumerates
// $VIBRANIUM/themes (exclusion names only) and $XDG_CONFIG_HOME/vibranium/
// themes, reads colors.list via FileView. No bash middleman: MenuLib does
// the bundle, Entry does the visuals, and the deletion is an argv
// invocation of vb-theme-remove <folder>.
//
// The folder is a directory name on the user's own disk, so it is data and
// nothing guarantees a tidy spelling. It is passed as one argv element
// (no quoting step can split or drop it) and PathPolicy holds it to a
// single segment below the user themes root, so it cannot name a path
// outside it; the check is lexical and reports containment as unverified.
// The staged confirmation runs through a Menu provider rather than a
// `confirm.command` template, because that field is bash source by
// definition and would put the folder back into source text.
//
// Performance: same shape as ThemePicker (async FolderListModels, sync
// FileView reads only for community themes, session cache). Both listings
// are armed at the first real need, so a session that never removes a
// theme scans no directory. Removal rows carry no active marker: they
// offer no state.
Singleton {
  id: root

  readonly property string tag: "themeRemover"
  readonly property string pageId: "themeRemove"

  property var _cached: null
  property bool _pendingShow: false

  // --- directory listings (pure QML, no bash) ---
  // FolderListModel auto-updates count when the directory changes - use
  // onCountChanged to invalidate cache live.
  //
  // The folder is left unset and assigned by _armFolders() at the first real
  // need: a bound folder opens the directory at construction, so a boot that
  // never opens this picker would pay for two listings of the theme roots
  // and then read colors.list for every row in them.
  //
  // An unset folder is not an empty folder. FolderListModel resolves it to
  // the process working directory and reports status Ready with that
  // directory's subdirectories in count, so the model's own status cannot
  // tell "not listed yet" from "listed and empty". _listed is the
  // discriminator, and it matters more here than in the picker: a scan that
  // ran against an unarmed listing would build uninstall rows out of the
  // working directory, and an empty row set is what raises the "no
  // community themes" notice. No row can ever be built that way.
  property bool _foldersArmed: false
  property bool _listed: false

  FolderListModel {
    id: officialModel
    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
    onStatusChanged: root._onListingReady()
  }

  FolderListModel {
    id: userModel
    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
    onStatusChanged: root._onListingReady()
  }

  // Inotify fallback for added/removed theme dirs. A FileView pointed at a
  // directory emits fileChanged when entries come and go, and one pointed
  // at a missing path emits it when that path is created, so every
  // add/remove/created-root funnels into the same debounced rescan even
  // when the models' own count signals miss it (a model aimed at a missing
  // root settles to Null and never emits again on its own).
  FileView {
    id: officialDirWatch
    path: Paths.vibraniumHome + "/themes"
    watchChanges: true
    printErrors: false
    onFileChanged: root._onDirChanged()
  }
  FileView {
    id: userDirWatch
    path: Paths.themesUserRoot
    watchChanges: true
    printErrors: false
    onFileChanged: root._onDirChanged()
  }

  // Assigning the folder is the only thing that starts a directory scan, so
  // this is the one place it happens. Both are assigned together because
  // every scan needs both listings Ready; arming one alone would scan a
  // directory whose pair can never complete.
  function _armFolders() {
    if (root._foldersArmed) return
    root._foldersArmed = true
    officialModel.folder = "file://" + Paths.vibraniumHome + "/themes"
    userModel.folder = "file://" + Paths.themesUserRoot
  }

  Timer {
    id: dirDebounce
    interval: 250
    repeat: false
    onTriggered: root._onDirCountChangedDebounced()
  }

  function _onDirCountChanged() {
    // A count that lands while the listing is still being armed is the
    // first population, not a directory change: the scan it would schedule
    // is the one the first real need already asked for. Letting it through
    // would rescan and recompose the page 250ms after the reader opened it.
    // Count events only ever come from a live model, so unlike the dir
    // watchers below this never re-arms: re-aiming here would chase the
    // working-directory flash a resolving model reports before settling.
    if (!root._listed) return
    dirDebounce.restart()
  }

  // The FileView dir watchers land here. External changes are the one
  // thing that can leave a model behind (a root created after the arming
  // sits at Null, dead to further model events), so the models are
  // re-aimed first and the listing-ready handler picks up the settle.
  function _onDirChanged() {
    if (!root._foldersArmed) return
    root._reaimUnready()
    root._onListingReady()
    if (!root._listed) return
    dirDebounce.restart()
  }

  // Whether a listing model freshly lists its root: Ready with rows under
  // it, or Ready and empty. Anything else - still loading, settled to Null
  // on a missing root, or Ready with the working directory's rows (the
  // flash a missing root reports before settling to Null) - needs a
  // re-aim before it can be scanned.
  function _modelFresh(m, rootPath) {
    if (m.status !== FolderListModel.Ready) return false
    if (m.count === 0) return true
    const p = String(m.get(0, "filePath"))
    return p.lastIndexOf(rootPath + "/", 0) === 0
  }

  function _modelsFresh() {
    return root._modelFresh(officialModel, Paths.vibraniumHome + "/themes")
      && root._modelFresh(userModel, Paths.themesUserRoot)
  }

  // Whether the pair can be scanned: fresh, or settled to Null on a
  // missing root, which reads as empty (a missing dir contributes no
  // rows). The flash above never passes: it is Ready with foreign rows.
  function _modelsUsable() {
    const ou = officialModel.status === FolderListModel.Null || root._modelFresh(officialModel, Paths.vibraniumHome + "/themes")
    const uu = userModel.status === FolderListModel.Null || root._modelFresh(userModel, Paths.themesUserRoot)
    return ou && uu
  }

  // A themes root that does not exist yet (a fresh install whose user
  // declined the additional themes, so ~/.config/vibranium/themes was
  // never created) settles its model to Null. Null is terminal - the model
  // will not recover on its own - so it counts as settled and reads as
  // empty (count 0) while the official names still filter. Only Loading is
  // still in flight.
  function _isSettled(m) {
    return m.status !== FolderListModel.Loading
  }

  // Re-aim every model that does not freshly list its root: still loading,
  // settled to Null on a directory that did not exist when it was armed
  // (a themes root created later - the first community theme install
  // creates the user dir - is picked up), or Ready with foreign rows (the
  // working-directory flash a missing root reports before settling).
  // Reassigning the same URL is a no-op, so the folder is blanked first on
  // a later turn. _listed drops while the re-aim is in flight, so the
  // transient listing the blank folder resolves to is never scanned as
  // themes. Only ever called from open() and the dir-watcher handler,
  // never from the listing-ready handler and never from a count event, so
  // a flash can never retrigger its own re-aim in a loop.
  function _reaimUnready() {
    if (!root._foldersArmed) return false
    let rearmed = false
    const jobs = [
      [officialModel, "file://" + Paths.vibraniumHome + "/themes", Paths.vibraniumHome + "/themes"],
      [userModel, "file://" + Paths.themesUserRoot, Paths.themesUserRoot]
    ]
    for (let i = 0; i < jobs.length; i++) {
      const m = jobs[i][0]
      if (root._modelFresh(m, jobs[i][2])) continue
      m.folder = ""
      const url = jobs[i][1]
      Qt.callLater(() => { m.folder = url })
      rearmed = true
    }
    if (rearmed) root._listed = false
    return rearmed
  }

  // One listing landing is the only event that can finish a pending show or
  // refresh a live cache, so both status handlers route here. Both listings
  // are required: a half-armed pair is not a listing, and the scan waits for
  // the second one.
  function _onListingReady() {
    if (!root._foldersArmed) return
    if (!root._isSettled(officialModel) || !root._isSettled(userModel)) return
    // Never latch or scan the working-directory flash: a model aimed at a
    // missing root reports Ready with foreign rows before settling to Null.
    // Dropping _listed keeps the debounced scan and the pending show gated
    // until the settle that follows re-invokes this handler.
    if (!root._modelsUsable()) {
      root._listed = false
      return
    }
    root._listed = true
    if (root._pendingShow) {
      root._doScan(true)
      return
    }
    // Background refresh recomposes live when the remover is the top frame,
    // so a change that lands while it is open never leaves a stale page up.
    if (root._cached !== null) root._doScan(Menu.open && Menu.frame && Menu.frame.id === root.pageId)
  }

  function _onDirCountChangedDebounced() {
    root._cached = null
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
      if (root._listed) {
        root._doScan(true)
      } else {
        root._pendingShow = true
      }
    } else {
      if (root._listed) {
        Qt.callLater(() => root._doScan(false))
      }
    }
  }

  Component.onCompleted: {
    Registry.offer("themeRemover", {
      title: "Theme remover",
      description: "community theme uninstall",
      verbNames: [
        "close",
        "open",
        "refresh",
        "summon",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    // Registry.call routes the menu row's runCall spec ("themeRemover
    // summon %v") here; offer() alone only feeds the IPC manifest.
    Registry.register("themeRemover", root)
  }

  Component.onDestruction: {
    // Teardown releases the whole per-row provider set: the surfaces close
    // over this root, so a survivor would keep a dead confirm closure on a
    // row that can no longer be uninstalled.
    root._releaseProviders()
    Registry.unregister("themeRemover")
  }

  // --- helpers: keep them tiny and allocation-light ---
  FileView {
    id: reader
    printErrors: false
  }

  function _readFile(path) {
    reader.path = ""
    reader.path = path
    if (!reader.waitForJob()) return ""
    return reader.text()
  }

  // Main scan: user dirs minus official counterparts (exact dir match, the
  // same rule the removal backend applies: overrides stay, they shadow stock
  // instead of adding).
  // Synchronous FileView reads, but only for community themes.
  function _doScan(show) {
    root._pendingShow = show
    // The single choke point every scan path passes through. A listing that
    // is not armed is not an empty user themes root, so it produces no
    // uninstall rows and no "no community themes" notice.
    if (!root._listed) return
    // The latch above verified the rows, but the flash can land between the
    // latch and a scan. Never scan it: re-arm and hold the pending show
    // for the settle that follows.
    if (!root._modelsUsable()) {
      root._reaimUnready()
      root._pendingShow = show
      return
    }
    const t0 = Date.now()
    const official = {}
    for (let i = 0; i < officialModel.count; i++) {
      const name = officialModel.get(i, "fileName")
      if (name) official[String(name)] = true
    }
    const userRoot = Paths.themesUserRoot
    const out = []
    for (let i = 0; i < userModel.count; i++) {
      const name = userModel.get(i, "fileName")
      if (!name) continue
      const folder = String(name)
      if (official[folder]) continue
      const label = ThemeScan.displayName(folder)
      const palette = ThemeScan.extractPalette(root._readFile(userRoot + "/" + folder + "/colors.list"))
      out.push({ folder: folder, label: label === "" ? folder : label, palette: palette })
    }

    out.sort((a, b) => a.label.localeCompare(b.label))

    root._cached = out

    if (root._pendingShow) {
      root._pendingShow = false
      root._show(out)
    }
  }

  function _buildItems(data) {
    const items = []
    const ids = []
    for (let i = 0; i < data.length; i++) {
      const e = data[i]
      items.push({
        type: "action",
        id: e.folder,
        label: e.label,
        sub: "",
        icon: "theme",
        palette: e.palette,
        // The folder is the row payload: hideValue keeps it out of the
        // readout, and the confirm stage reads it back from the row.
        value: e.folder,
        hideValue: true,
        // Staged uninstall confirmation, same three-way flow as the
        // launcher's app deletion and the clipboard's pinned removal:
        // hint -> armed -> confirm. The confirm stage reaches _remove()
        // through the row's Menu provider (see _registerProviders) and
        // recomposes the list; the menu stays up.
        confirm: {
          stages: 2,
          hint: "Press <b>Enter</b> or <b>Delete</b> again to uninstall this theme",
          armed: "<b><u>Press again to confirm uninstall</u></b>",
          label: "Uninstall"
        }
      })
      ids.push(e.folder)
    }
    // Composing the page is the only moment the id set is exact, so this
    // is the sole registration trigger: every _show path runs
    // _buildItems, and each compose replaces the full set.
    root._registerProviders(ids)
    return items
  }

  // One confirm provider per listed row, keyed by the row id, so the
  // staged confirmation lands on the argv path instead of the bash
  // `confirm.command` template. Providers for rows the rescan dropped are
  // released here, so the menu's provider map tracks the page and nothing
  // else. ProviderHost holds the set under this unit as owner and replays
  // it when Menu registers as its host, so a row composed before the menu
  // singleton exists still reaches it.
  property var _providerIds: []

  // Provider id ownership: ProviderHost hands a record to the host Menu
  // once and refuses a re-registration whose owner is a different object,
  // so a record is only ever replaceable by the object that owns it. Every
  // id in `_providerIds` is owned for as long as this unit is alive and the
  // whole set is released on destruction; a refused id would otherwise pin
  // the surface to a dead closure and leave the row without its confirm.
  function _claimProviderId(id, surface, deferred) {
    if (ProviderHost.registerProvider(id, surface, root)) return true
    ProviderHost.unregisterProvider(id, root)
    if (ProviderHost.registerProvider(id, surface, root)) return true
    // A predecessor that has not finalized yet still holds the id and
    // frees it only from its own teardown, which is itself a deferred
    // step, so a recreated unit gets one late attempt past this turn. The
    // id is bounded and re-entrant: this path can only ever claim a free
    // id, so a late miss is reported and never blocks a live owner.
    if (deferred) {
      DeferredQueue.run(() => { root._claimProviderId(id, surface, false) }, 2, 0, root.tag + " provider retry")
      return false
    }
    return false
  }

  function _releaseProviders() {
    // Snapshot first: the loop must not walk a collection it rewrites.
    const ids = root._providerIds
    root._providerIds = []
    for (let i = 0; i < ids.length; i++)
      ProviderHost.unregisterProvider(ids[i], root)
  }

  function _registerProviders(ids) {
    root._releaseProviders()
    const fresh = []
    for (let i = 0; i < ids.length; i++) {
      root._claimProviderId(ids[i], {
        runConfirm: (item, ctx) => {
          root._remove(item.value)
          return true
        }
      }, false)
      fresh.push(ids[i])
    }
    root._providerIds = fresh
  }

  // The theme name is accepted only as a single path segment below the
  // user themes root. leafRelative drops anything carrying a separator or
  // a `..`, so a row value can neither walk up nor name an absolute path.
  function _contained(folder) {
    return PathPolicy.check(Paths.themesUserRoot, folder, {
      operation: "theme_dir",
      mode: "write",
      leafRelative: true,
      relative: true
    }).ok === true
  }

  // One argv element, no shell: a folder name holding a space, an
  // apostrophe, a semicolon, a dollar or a backtick reaches
  // vb-theme-remove whole and unexpanded.
  function _remove(folder) {
    const name = String(folder ?? "")
    if (name === "" || !root._contained(name)) return
    Exec.run([Paths.vibraniumHome + "/bin/vb-theme-remove", name])
  }

  function _notifyEmpty() {
    Exec.run(["notify-send", "-r", "3", "-t", "2000", "Vibranium", "No community themes installed"])
    // Last row went away while the page was on top (confirm-stage
    // removal): pushed summon pops back to the chain below; a standalone
    // summon (single frame) closes outright, which is the `vb-shell menu
    // close` behaviour. Guarded on the page being the current frame, so a
    // deferred scan landing under some other page never pops its frame.
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
      if (Menu.stack.length > 1) Menu.pop()
      else Menu.close()
    }
  }

  function _show(data) {
    if (!data || data.length === 0) {
      root._notifyEmpty()
      return
    }
    const page = {
      id: root.pageId,
      title: "Uninstall theme",
      width: 360,
      items: root._buildItems(data)
    }
    const bundleText = JSON.stringify(page)
    try {
      // Both injects opt out of the global index: uninstall rows are meant to
      // be reachable from the theme picker's own menu, where the scoped
      // filter trims them, and not as answers to a search in every other
      // menu. The page still registers, so navigation and the push/peel
      // below are the same either way.
      if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
        // Live update the already-open picker: re-inject the page so the
        // rev/condRev bump re-renders its rows in place. loadText here
        // (a fresh single-frame stack) would drop the chain below and
        // reset the scroll. (The cache is already current - _doScan and
        // the open() cache path both set it before calling _show.)
        // The trailing false is the search opt-out: a theme is reachable
        // from this picker and nowhere else, so its rows must not answer a
        // query typed in Settings or any other menu.
        Menu.injectPage(Menu.buildDynamicPage(root.pageId, page.title,
          page.width, page.items), null, false)
      } else if (Menu.open) {
        // Summoned from inside another menu (Remove -> Theme): seat the
        // page as a dynamic page and PUSH it onto the live stack, so the
        // chain below survives and Esc pops back to it. Same opt-out as
        // above.
        Menu.injectPage(Menu.buildDynamicPage(root.pageId, page.title,
          page.width, page.items), null, false)
        if (Menu.stack.some(f => f && f.id === root.pageId)) {
          // Already sitting somewhere on this stack (summon -> Esc ->
          // summon): peel back to the existing frame instead of stacking
          // a twin the user would have to Esc through twice.
          while (Menu.open && Menu.frame && Menu.frame.id !== root.pageId) Menu.pop()
        } else {
          Menu.push(root.pageId)
        }
      } else {
        Menu.openJson(bundleText)
      }
    } catch (e) {
    }
  }

  // --- public API ---

  function open() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return "ok"
    // The user shelf is external state: a folder added/removed while the
    // remover was closed leaves any served cache stale. The community set
    // is small and the scan is synchronous, so every open re-arms (picks
    // up a root created since) and rescans instead of serving the cache.
    // Refresh explicitly via `refresh` after editing theme files in place.
    root._armFolders()
    root._reaimUnready()
    if (!root._listed) {
      root._pendingShow = true
      return "ok"
    }
    root._doScan(true)
    return "ok"
  }

  // Manual rescan for in-place theme file edits (the dir watcher only
  // fires on added/removed themes). Recomposes live when open,
  // otherwise just refreshes the cache. A listing that was never armed
  // holds no rows to rescan and answers error, the same answer the
  // not-Ready gate gives while a scan is still in flight.
  function refresh() {
    if (!root._listed) return "error"
    root._cached = null
    root._doScan(Menu.open && Menu.frame && Menu.frame.id === root.pageId)
    return "ok"
  }

  // Registry method behind the Remove -> Theme menu row (call spec
  // "themeRemover summon"): refresh the cache silently and open the
  // picker without touching the menu chain below - the push path in
  // _show() lands the page on top of the stack so Esc walks back.
  function summon() {
    root._cached = null
    return root.open()
  }

  function close() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
      Menu.close()
    }
    return "ok"
  }

  function toggle() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
      Menu.close()
      return "ok"
    }
    if (Menu.open) Menu.close()
    return root.open()
  }

  function status() {
    return JSON.stringify({
      cached: root._cached ? root._cached.length : 0,
      pending: root._pendingShow,
      open: Menu.open && Menu.frame ? Menu.frame.id : ""
    })
  }

  IpcHandler {
    target: "themeRemover"
    function help(command: string): string {
      return UnitIpc.help("themeRemover", "Theme remover", "community theme uninstall", [
        { name: "close", help: "hide the remover" },
        { name: "open", help: "show the remover" },
        { name: "refresh", help: "rescan themes (in-place file edits)" },
        { name: "toggle", help: "show/hide" },
      ], command)
    }
    function ping(): string { return "pong" }
    function open(): string { return root.open() }
    function close(): string { return root.close() }
    function refresh(): string { return root.refresh() }
    function toggle(): string { return root.toggle() }
    function status(): string { return root.status() }
  }
}

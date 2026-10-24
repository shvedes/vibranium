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

// Theme picker service. Mirrors vb-theme-set discovery but entirely in
// quickshell: enumerates $VIBRANIUM/themes and $XDG_CONFIG_HOME/vibranium/themes,
// reads theme.info / colors.list via FileView, builds a Menu page whose
// rows carry a `palette` array (hex swatches) rendered as little filled
// dots under the label in Entry.qml. No bash middleman: MenuLib does the
// bundle, Entry does the visuals.
//
// Data, never source: a row's active state is a JS comparison against the
// stored theme name (the `active` flag, which Entry paints), and applying
// a row is a Registry call into apply() below. The folder reaches
// vb-theme-set as one argv element, so a theme directory name may hold a
// space, an apostrophe, a semicolon, a dollar or a backtick without any of
// it being read as source text. PathPolicy holds the name to a single
// segment below a themes root, so a row value can never name a path
// outside them; the check is lexical, so it reports containment as
// unverified and a symlink inside a themes root stays out of its reach.
//
// Performance: one FolderListModel per source (already async), ~90
// synchronous FileView reads (theme.info + colors.list per theme) on the
// first scan. The two listings are armed at the first real need, so a
// session that never opens this picker scans no directory and reads no
// theme file. Results are cached for the session; an open that finds the
// cache serves it, and the directory watcher keeps it current after that.
// The active row follows the stored theme name without rescanning after a
// theme switch.
Singleton {
  id: root

  readonly property string tag: "themePicker"
  readonly property string pageId: "themes"

  property var _cached: null
  property bool _pendingShow: false
  property string _activeTheme: ""

  // --- active theme tracking via Watch governor (trio) ---
  property var _watchUnsub: null

  // The theme.name read is async (loaded/loadFailed continue below):
  // Watch callbacks must never block the loop on a file read.
  property bool _activeArmed: false
  FileView {
    id: activeReader
    printErrors: false
    onLoaded: root._finishActive(true)
    onLoadFailed: root._finishActive(false)
  }

  FileView {
    id: reader
    printErrors: false
    onLoaded: root._scanLanded(true)
    onLoadFailed: root._scanLanded(false)
  }

  function _updateActive() {
    if (root._activeArmed) return
    root._activeArmed = true
    // Direct assignment, never bounced through "": the bounce's intermediate
    // load fails async and its continuation clears this latch before the real
    // read lands, so the real read is dropped and the active marker never sets.
    if (activeReader.path === Paths.themeNameFile) activeReader.reload()
    else activeReader.path = Paths.themeNameFile
  }

  // Continuation of the theme.name read. A miss clears the marker and
  // re-stamps; anything else moves it only on change.
  function _finishActive(ok) {
    if (!root._activeArmed) return
    root._activeArmed = false
    if (ok !== true) {
      root._activeTheme = ""
      root._stampActive()
      return
    }
    const next = activeReader.text().trim().toLowerCase()
    if (next === root._activeTheme && root._activeTheme !== "") return
    root._activeTheme = next
    // The page is composed with the marker already stamped, so a switch
    // that happens while the picker is on screen only has to move the
    // flag: a rebuild here would drop the menu chain and the scroll.
    root._stampActive()
  }

  // The row that names the stored theme is the active one. The folder is
  // the row's own data, so the comparison needs no guard expression and no
  // shell. Case is folded because the stored name is read lowercased.
  function _isActiveFolder(folder) {
    const v = String(folder ?? "").toLowerCase()
    return v !== "" && v === root._activeTheme
  }

  // A family select carries the variant that was current when the page was
  // composed in its value, so a switch made from another surface moves the
  // marker through the option set instead. Both shapes answer with the
  // same rule: does this row name the stored theme?
  function _rowActive(it) {
    if (root._isActiveFolder(it.value)) return true
    const opts = Array.isArray(it.options) ? it.options : []
    for (let i = 0; i < opts.length; i++) {
      if (root._isActiveFolder(opts[i].value)) return true
    }
    return false
  }

  // Re-stamp the active flag on the built page in place. The panel mirrors
  // these very objects, so a rev bump repaints the moved marker without
  // touching the model, the delegates or the stack.
  function _stampActive() {
    const page = Menu.pageById(root.pageId)
    if (!page || !Array.isArray(page.items)) return
    let changed = false
    for (let i = 0; i < page.items.length; i++) {
      const it = page.items[i]
      const next = root._rowActive(it)
      if (it.active === next) continue
      it.active = next
      changed = true
    }
    if (changed) Menu.rev++
  }

  // The theme name is accepted only as a single path segment below one of
  // the two themes roots. leafRelative drops anything carrying a separator
  // or a `..`, so a row value can neither walk up nor name an absolute
  // path; the two roots are the only places a name may live.
  readonly property var _themeRoots: [
    Paths.vibraniumHome + "/themes",
    Paths.themesUserRoot
  ]

  function _contained(folder) {
    const options = {
      operation: "theme_dir",
      mode: "write",
      leafRelative: true,
      relative: true
    }
    for (let i = 0; i < root._themeRoots.length; i++) {
      if (PathPolicy.check(root._themeRoots[i], folder, options).ok === true) return true
    }
    return false
  }

  // Registry method behind a row's `call` spec ("themePicker apply %v").
  // The value is the folder and nothing else: MenuLib substitutes it into
  // the spec as one argument, and it is handed to vb-theme-set as one argv
  // element, so no quoting step can drop or split it.
  function apply(folder) {
    const name = String(folder ?? "")
    if (name === "" || !root._contained(name)) return "error: not a theme name"
    Exec.run([Paths.vibraniumHome + "/bin/vb-theme-set", name])
    // The state file is written by the backend, so the marker follows its
    // watcher rather than an optimistic stamp here.
    return "ok"
  }

  // --- directory listings (pure QML, no bash) ---
  // FolderListModel auto-updates count when the directory changes -
  // use onCountChanged to invalidate cache live.
  //
  // The folder is left unset and assigned by _armFolders() at the first real
  // need: a bound folder opens the directory at construction, so a boot that
  // never summons this picker would pay for two listings of the theme roots
  // and then read theme.info and colors.list for every row in them.
  //
  // An unset folder is not an empty folder. FolderListModel resolves it to
  // the process working directory and reports status Ready with that
  // directory's subdirectories in count, so the model's own status cannot
  // tell "not listed yet" from "listed and empty". _listed is the
  // discriminator, and every scan and every model read below sits behind it:
  // no row can ever be built from the working directory.
  property bool _foldersArmed: false
  property bool _listed: false

  FolderListModel {
    id: officialModel
    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
  }

  FolderListModel {
    id: userModel
    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
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

  // Directory-count debounce, named: one re-scan per burst of
  // add/remove events.
  readonly property int dirDebounceMs: 250
  Timer {
    id: dirDebounce
    interval: root.dirDebounceMs
    repeat: false
    onTriggered: root._onDirCountChangedDebounced()
  }

  function _onDirCountChanged() {
    // A count that lands while the listing is still being armed is the
    // first population, not a directory change: the scan it would schedule
    // is the one the first real need already asked for. Letting it through
    // would rescan and recompose the page 250ms after the reader opened it.
    if (!root._listed) return
    dirDebounce.restart()
  }

  // A themes root that does not exist yet (a fresh install whose user
  // declined the additional themes, so ~/.config/vibranium/themes was
  // never created) never reaches Ready. Requiring Ready on both models
  // stalls the picker forever with _pendingShow set and no page. A model
  // that has settled into any terminal state counts: a missing dir reads
  // as empty (count 0) and the official themes still list.
  function _isSettled(m) {
    return m.status !== FolderListModel.Loading && m.status !== FolderListModel.Null
  }

  // A settled-but-not-Ready model names a directory that did not exist
  // when it was armed. Re-aim it so a themes root created later (the
  // first community theme install creates the user dir) is picked up;
  // reassigning the same URL is a no-op, so the folder is blanked first
  // on a later turn. _listed drops while the re-aim is in flight, so the
  // transient working-directory listing the blank folder resolves to is
  // never scanned as themes.
  function _reaimUnready() {
    if (!root._foldersArmed) return false
    let rearmed = false
    if (root._isSettled(officialModel) && officialModel.status !== FolderListModel.Ready) {
      const url = "file://" + Paths.vibraniumHome + "/themes"
      officialModel.folder = ""
      Qt.callLater(() => { officialModel.folder = url })
      rearmed = true
    }
    if (root._isSettled(userModel) && userModel.status !== FolderListModel.Ready) {
      const url = "file://" + Paths.themesUserRoot
      userModel.folder = ""
      Qt.callLater(() => { userModel.folder = url })
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
    root._listed = true
    if (root._pendingShow) {
      root._doScan(true)
      return
    }
    if (root._cached !== null) root._doScan(false)
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
    Registry.offer("themePicker", {
      title: "Theme picker",
      description: "theme selection",
      verbNames: [
        "close",
        "open",
        "refresh",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    // Registry.call routes each row's runCall spec ("themePicker apply %v")
    // here; offer() alone only feeds the IPC manifest.
    Registry.register("themePicker", root)
    root._updateActive()
    root._watchUnsub = Watch.subscribe(Paths.themeNameFile, (text) => {
      root._updateActive()
    })
  }
  Component.onDestruction: {
    Registry.unregister("themePicker")
    if (root._watchUnsub) root._watchUnsub()
  }

  Connections {
    target: officialModel
    function onStatusChanged() { root._onListingReady() }
  }

  Connections {
    target: userModel
    function onStatusChanged() { root._onListingReady() }
  }

  // --- helpers: keep them tiny and allocation-light ---
  function _cap(s) {
    if (!s) return ""
    return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase()
  }

  // Main scan: FolderListModel -> theme.info -> colors.list -> palette.
  // Async file reads (two per theme, advanced by the reader's signals);
  // ~2*themes files land across turns with the previous cache up instead of
  // blocking ~80ms on warm cache. Runs when the first real
  // need arms the listings, again when the directory count changes
  // (theme added/removed) and on manual refresh - an open that finds
  // the cache serves it and never rescans.
  function _doScan(show) {
    root._pendingShow = show
    // The single choke point every scan path passes through. A listing that
    // is not armed is not an empty themes root, so it produces no rows and
    // no page.
    if (!root._listed) return
    const seen = {}
    const bases = []

    for (let i = 0; i < officialModel.count; i++) {
      const name = officialModel.get(i, "fileName")
      if (!name) continue
      const folder = String(name)
      seen[folder.toLowerCase()] = true
      bases.push({
        folder: folder,
        base: Paths.vibraniumHome + "/themes/" + folder,
        isUser: false
      })
    }
    const userRoot = Paths.themesUserRoot
    for (let i = 0; i < userModel.count; i++) {
      const name = userModel.get(i, "fileName")
      if (!name) continue
      const folder = String(name)
      if (seen[folder.toLowerCase()]) continue // user override of official -> skip
      bases.push({
        folder: folder,
        base: userRoot + "/" + folder,
        isUser: true
      })
    }

    // Async scan: one theme per two file reads (theme.info, then
    // colors.list), advanced by the reader's loaded/loadFailed signals.
    // A scan requested while one is in flight queues behind it (latest
    // wins): the shared reader answers one arming at a time, so two
    // live jobs would advance each other's cursors. While a scan is in
    // flight the previous cache stays up (the pending-show state below
    // is the skeleton a summon waits on).
    if (root._scanJob !== null) {
      root._scanQueued = { show: show }
      return
    }
    root._scanGen++
    root._scanJob = { gen: root._scanGen, bases: bases, i: 0, out: [], show: show, phase: "info", infoText: "" }
    root._scanReadInfo()
  }

  // Scan generation: a refresh or count change that lands mid-scan
  // queues behind it (see _doScan) instead of interleaving on the
  // shared reader.
  property int _scanGen: 0
  property var _scanJob: null
  property var _scanQueued: null

  // Arm the theme.info read for the cursor theme, or finish when done.
  // Direct assignment, never bounced through "": the bounce fires an extra
  // loadFailed per file and each spurious continuation advances this machine
  // a step, so info/colors pairs misalign and themes drop. Same-path is the
  // only case that needs reload().
  //
  // Deferred a tick past the caller: re-pointing this view from inside its
  // own loaded/loadFailed handler drops the next load (measured: the second
  // signal never arrives and the scan stalls on theme zero), so every
  // mid-scan arm goes through _armReader. The generation echo drops a stale
  // arm when a newer scan started in between.
  function _armReader(path) {
    const gen = root._scanGen
    Qt.callLater(() => {
      if (root._scanJob === null || gen !== root._scanGen) return
      if (reader.path === path) reader.reload()
      else reader.path = path
    })
  }

  function _scanReadInfo() {
    const st = root._scanJob
    if (st === null) return
    if (st.i >= st.bases.length) {
      root._finishScan(st)
      return
    }
    st.phase = "info"
    root._armReader(st.bases[st.i].base + "/theme.info")
  }

  // One landed read advances the machine: info stashes its text and arms
  // the colors read; colors parses the row and advances the cursor. A
  // miss reads as "", the same answer a synchronous read gives, so a missing
  // file yields the folder-heuristic row rather than dropping the theme.
  function _scanLanded(ok) {
    const st = root._scanJob
    if (st === null || st.gen !== root._scanGen) return
    if (st.phase === "info") {
      st.infoText = ok === true ? reader.text() : ""
      st.phase = "colors"
      root._armReader(st.bases[st.i].base + "/colors.list")
      return
    }
    const ctext = ok === true ? reader.text() : ""
    st.out.push(root._parseThemeRow(st.bases[st.i], st.infoText, ctext))
    st.i++
    root._scanReadInfo()
  }

  // One theme's row from its folder entry plus the two file texts. Pure:
  // the same parse the sync loop ran, callable without a live scan.
  function _parseThemeRow(entry, infoText, ctext) {
    const folder = entry.folder
    const base = entry.base
    // .uninstalled check via FileView is unreliable (empty marker vs missing
    // both give text len 0). Skip the check for now; archived wallpapers
    // are rare and showing them is harmless. If needed, use Process test -f.

    let family = ""
    let variant = ""
    let lightVal = ""
    if (String(infoText).trim() !== "") {
      const lines = String(infoText).split("\n")
      for (let l = 0; l < lines.length; l++) {
        const line = lines[l]
        const eq = line.indexOf("=")
        if (eq < 0) continue
        const k = line.substring(0, eq).trim()
        const v = line.substring(eq + 1).trim()
        if (k === "FAMILY") family = v
        else if (k === "VARIANT") variant = v
        else if (k === "LIGHT") lightVal = v
      }
    } else {
      if (entry.isUser) {
        family = ""
        variant = ThemeScan.capWords(folder)
      } else if (folder.indexOf("-") < 0) {
        family = ""
        variant = root._cap(folder)
      } else {
        const dash = folder.indexOf("-")
        const prefix = folder.substring(0, dash)
        const suffix = folder.substring(dash + 1)
        family = root._cap(prefix)
        variant = root._cap(suffix.replace(/-/g, " "))
      }
    }

    let label = ""
    if (family) label = family + " " + variant.replace(/-/g, " ")
    else label = variant.replace(/-/g, " ")
    if (label.trim() === "") label = folder

    const palette = ThemeScan.extractPalette(String(ctext))

    // Light/Dark from theme.info or folder heuristic
    let isLight = false
    if (lightVal !== "") isLight = lightVal === "true"
    else if (/(light|latte|dawn)$/i.test(folder)) isLight = true
    const light = isLight ? "Light" : "Dark"

    return { folder: folder, label: label, palette: palette, light: light, family: family, variant: variant }
  }

  // Close out a finished scan: sort, cache, and show when asked. Only
  // the current generation advances here; a queued scan starts next.
  function _finishScan(st) {
    if (st.gen !== root._scanGen) return
    root._scanJob = null
    const out = st.out
    out.sort((a, b) => a.label.localeCompare(b.label))

    root._cached = out

    if (root._pendingShow) {
      root._pendingShow = false
      root._show(out)
    }
    if (root._scanQueued !== null) {
      const q = root._scanQueued
      root._scanQueued = null
      root._doScan(q.show)
    }
  }

  // A single theme is one glyph that says which mode it is, so the row's
  // left slot carries the sun or the moon instead of the palette mark the
  // whole page repeats. A family is a set of both, so it keeps the palette.
  // The name is the shipped asset's own (Icons scans assets/icons by file
  // name), so a missing glyph renders as no icon rather than a broken one.
  function _iconFor(light) {
    return light === "Light" ? "brightness" : "moon"
  }

  function _buildItems(data) {
    // Group by family, promote singles to standalone.
    const families = {}
    const standalone = []
    for (let i = 0; i < data.length; i++) {
      const e = data[i]
      if (e.family && e.family !== "") {
        if (!families[e.family]) families[e.family] = []
        families[e.family].push(e)
      } else {
        standalone.push(e)
      }
    }
    // Promote single-variant families
    for (const fam in families) {
      if (families[fam].length === 1) {
        standalone.push(families[fam][0])
        delete families[fam]
      }
    }

    const items = []

    // Standalone actions
    standalone.sort((a, b) => a.label.localeCompare(b.label))
    for (let i = 0; i < standalone.length; i++) {
      const e = standalone[i]
      items.push({
        type: "action",
        id: e.folder,
        label: e.label,
        sub: "",
        icon: root._iconFor(e.light),
        palette: e.palette,
        light: e.light,
        // The folder travels as the row's value and reaches vb-theme-set
        // through the Registry call, so it is never concatenated into
        // command text. hideValue keeps the payload out of the readout.
        value: e.folder,
        hideValue: true,
        call: "themePicker apply %v",
        active: root._isActiveFolder(e.folder),
        close: true
      })
    }

    // Family selects (collapsed)
    const fams = Object.keys(families).sort()
    for (let f = 0; f < fams.length; f++) {
      const fam = fams[f]
      const variants = families[fam].slice().sort((a, b) => a.variant.localeCompare(b.variant))
      // Active variant in this family, if any
      let activeEntry = null
      for (let v = 0; v < variants.length; v++) {
        if (variants[v].folder.toLowerCase() === root._activeTheme) {
          activeEntry = variants[v]
          break
        }
      }
      const curVal = activeEntry ? activeEntry.folder : ""
      const curPalette = activeEntry ? activeEntry.palette : variants[0].palette
      const opts = variants.map(v => ({
        label: v.variant,
        value: v.folder,
        palette: v.palette,
        light: v.light
      }))
      items.push({
        type: "select",
        id: "family-" + fam,
        label: fam,
        sub: "",
        icon: "theme",
        palette: curPalette,
        light: variants.length + " variants",
        value: curVal,
        marker: true,
        options: opts,
        // Action-select: the picked option is the folder, handed over as
        // one Registry argument. The row closes before the call runs, so
        // the menu needs no separate close command in the spec.
        onCall: "themePicker apply %v",
        active: root._isActiveFolder(curVal),
        close: false
      })
    }

    items.sort((a, b) => a.label.localeCompare(b.label))

    return items
  }

  function _show(data) {
    if (!data || data.length === 0) {
      return
    }
    const items = root._buildItems(data)
    const page = {
      id: root.pageId,
      title: "Themes",
      width: 360,
      items: items
    }
    const bundleText = JSON.stringify(page)
    try {
      if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
        // Live update the already-open picker
        Menu.loadText(bundleText)
      } else {
        Menu.openJson(bundleText)
      }
    } catch (e) {
    }
  }

  // --- public API ---

  function open() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return "ok"
    if (Menu.open) Menu.close()
    if (root._cached !== null) {
      const cached = root._cached.slice()
      cached.sort((a, b) => a.label.localeCompare(b.label))
      cached.sort((a, b) => {
        const aActive = a.folder.toLowerCase() === root._activeTheme
        const bActive = b.folder.toLowerCase() === root._activeTheme
        if (aActive !== bActive) return aActive ? -1 : 1
        return 0
      })
      root._show(cached)
      // No background rescan: the directory watcher keeps the cache fresh
      // (see _doScan). Refresh explicitly via `refresh` after editing
      // theme.info/colors.list in place.
      return "ok"
    }
    // First real need: arming the listings is what starts the scan, and it
    // runs from the status handler once both have landed. A settled-but-
    // not-Ready model is re-aimed first, so a themes root created after
    // the arming still resolves instead of pinning the open behind it.
    root._armFolders()
    root._reaimUnready()
    if (!root._listed) {
      root._pendingShow = true
      return "ok"
    }
    root._doScan(true)
    return "ok"
  }

  // Manual rescan for in-place theme.info/colors.list edits (the dir
  // watcher only fires on added/removed themes). Recomposes live when
  // open, otherwise just refreshes the cache. A listing that was never
  // armed holds no rows to rescan and answers error, the same answer the
  // not-Ready gate gives while a scan is still in flight.
  function refresh() {
    if (!root._listed) return "error"
    root._cached = null
    root._doScan(Menu.open && Menu.frame && Menu.frame.id === root.pageId)
    return "ok"
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
      active: root._activeTheme,
      pending: root._pendingShow,
      open: Menu.open && Menu.frame ? Menu.frame.id : ""
    })
  }

  IpcHandler {
    target: "themePicker"
    function help(command: string): string {
      return UnitIpc.help("themePicker", "Theme picker", "theme selection", [
        { name: "close", help: "hide the picker" },
        { name: "open", help: "show the picker" },
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

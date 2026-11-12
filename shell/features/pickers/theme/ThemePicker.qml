pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "./ThemeScan.js" as ThemeScan
import "../../../common/text/UnitIpc.js" as UnitIpc
import "../../../common/text/StringUtils.js" as SU

// Theme picker service: the cascade overlay's data source.
//
// Discovery mirrors vb-theme-set but lives entirely in quickshell: it
// enumerates $VIBRANIUM/themes and $XDG_CONFIG_HOME/vibranium/themes, reads
// theme.info / colors.list via FileView, and publishes one row per
// standalone theme or family. Each row carries its full colors.list map,
// because the overlay's skeletons are painted in the theme's own palette
// rather than the live shell palette. ThemeScan owns the parse; this file
// owns the listing, the cache, and the apply gate.
//
// Data, never source: applying a row is a Registry call into apply() below,
// and the folder reaches vb-theme-set as one argv element, so a theme
// directory name may hold a space, an apostrophe, a semicolon, a dollar or
// a backtick without any of it being read as source text. PathPolicy holds
// the name to a single segment below a themes root, so a row value can never
// name a path outside them; the check is lexical, so it reports containment
// as unverified and a symlink inside a themes root stays out of its reach.
//
// Performance: one FolderListModel per source (already async) and two file
// reads per theme. The singleton warms the listing and colors cache when it
// is constructed at boot, so the first summon already has rows and the panel
// has built its previews instead of showing an empty deck while the scan
// runs. Results stay cached for the session, the directory watcher keeps them
// current, and the active marker follows the stored theme name without
// rescanning after a theme switch.
Singleton {
  id: root

  readonly property string tag: "themePicker"

  property var _cached: null
  // The overlay's rows: one record per standalone theme or family. A family
  // record carries `variants`, each with its own folder/light/colors.
  property var rows: []
  property bool visible: false
  readonly property bool isOpen: root.visible

  property string _activeTheme: ""
  readonly property string activeFolder: root._activeTheme

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

  // Continuation of the theme.name read. A miss clears the marker;
  // anything else moves it only on change. The rows themselves do not need
  // restamping: the panel compares against activeFolder, so a theme switch
  // repaints the marker in place without touching the model or the deck.
  function _finishActive(ok) {
    if (!root._activeArmed) return
    root._activeArmed = false
    if (ok !== true) {
      root._activeTheme = ""
      return
    }
    root._activeTheme = activeReader.text().trim().toLowerCase()
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

  // Registry method behind the overlay's apply. The value is the folder and
  // nothing else, and it is handed to vb-theme-set as one argv element, so
  // no quoting step can drop or split it.
  function apply(folder) {
    const name = String(folder ?? "")
    if (name === "" || !root._contained(name)) return "error: not a theme name"
    // Selecting the theme that is already applied is a no-op. The backend has
    // its own guard, but making the decision here means the picker never
    // launches it for a same-theme click - no wallpaper refresh, hook or
    // notification can ride along with an action that has nothing to do.
    if (name.toLowerCase() === root.activeFolder) {
      root.close()
      return "ok"
    }
    Exec.run([Paths.vibraniumHome + "/bin/vb-theme-set", name])
    // The state file is written by the backend, so the marker follows its
    // watcher rather than an optimistic stamp here.
    root.close()
    return "ok"
  }

  // --- directory listings (pure QML, no bash) ---
  // The two theme roots, armed at the first real need: the shared component
  // owns the listing pair, the watchers and the settle/re-arm policy.
  ThemeRoots {
    id: roots

    onReady: {
      // Arming the pair is itself the first real need, so a settled pair
      // always has a listing to serve: the open that armed it, or a cache that
      // wants a background refresh.
      if (roots.listed) root._doScan()
    }
    onChanged: {
      root._cached = null
      if (roots.listed) Qt.callLater(() => root._doScan())
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
    // Registry.call routes the overlay's apply here; offer() alone only
    // feeds the IPC manifest.
    Registry.register("themePicker", root)
    root._updateActive()
    root._watchUnsub = Watch.subscribe(Paths.themeNameFile, (text) => {
      root._updateActive()
    })
    // The theme picker is a deferred resident, so this runs after the boot
    // entrance, not on its frames. Warming here means the first open serves a
    // filled cache and an already-built preview deck.
    root.warm()
  }
  Component.onDestruction: {
    Registry.unregister("themePicker")
    if (root._watchUnsub) root._watchUnsub()
  }

  // --- helpers: keep them tiny and allocation-light ---
  function _cap(s) {
    if (!s) return ""
    return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase()
  }

  // Natural alphanumeric order for labels. localeCompare alone leaves "Theme
  // 10" ahead of "Theme 2" (and its result depends on the host locale); a
  // zero-padded numeric key makes digit runs compare by value, independent of
  // the environment.
  function _alphaKey(value) {
    return String(value ?? "").toLowerCase().replace(/(\d+)/g, digits => ("000000000000" + digits).slice(-12))
  }
  function _compareAlpha(a, b) {
    const ka = root._alphaKey(a)
    const kb = root._alphaKey(b)
    if (ka < kb) return -1
    if (ka > kb) return 1
    return 0
  }

  // Main scan: FolderListModel -> theme.info -> colors.list -> row.
  // Async file reads (two per theme, advanced by the reader's signals);
  // ~2*themes files land across turns with the previous cache up instead of
  // blocking ~80ms on warm cache.
  function _doScan() {
    // The single choke point every scan path passes through. A listing that
    // is not armed is not an empty themes root, so it produces no rows.
    if (!roots.beginScan()) return
    const seen = {}
    const bases = []

    for (let i = 0; i < roots.officialModel.count; i++) {
      const name = roots.officialModel.get(i, "fileName")
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
    for (let i = 0; i < roots.userModel.count; i++) {
      const name = roots.userModel.get(i, "fileName")
      if (!name) continue
      const folder = String(name)
      if (seen[folder.toLowerCase()]) continue // user override of official -> skip
      bases.push({
        folder: folder,
        base: SU.joinPath(userRoot, folder),
        isUser: true
      })
    }

    // Async scan: one theme per two file reads (theme.info, then
    // colors.list), advanced by the reader's loaded/loadFailed signals.
    // A scan requested while one is in flight queues behind it (latest
    // wins): the shared reader answers one arming at a time, so two
    // live jobs would advance each other's cursors. While a scan is in
    // flight the previous cache stays up.
    if (root._scanJob !== null) {
      root._scanQueued = true
      return
    }
    root._scanGen++
    root._scanJob = { gen: root._scanGen, bases: bases, i: 0, out: [], phase: "info", infoText: "" }
    root._scanReadInfo()
  }

  // Scan generation: a refresh or count change that lands mid-scan
  // queues behind it (see _doScan) instead of interleaving on the
  // shared reader.
  property int _scanGen: 0
  property var _scanJob: null
  property bool _scanQueued: false

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

  // One theme's row from its folder entry plus the two file texts. Pure over
  // both texts, so it can be exercised without a live scan.
  function _parseThemeRow(entry, infoText, ctext) {
    const folder = entry.folder
    // .uninstalled check via FileView is unreliable (empty marker vs missing
    // both give text len 0). Skip the check for now; archived wallpapers
    // are rare and showing them is harmless.

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

    const colors = ThemeScan.extractColors(String(ctext))

    // Light/Dark from theme.info or folder heuristic
    let isLight = false
    if (lightVal !== "") isLight = lightVal === "true"
    else if (/(light|latte|dawn)$/i.test(folder)) isLight = true

    return {
      folder: folder,
      label: label,
      colors: colors,
      light: isLight,
      family: family,
      variant: variant
    }
  }

  // Group the scanned themes into the deck's rows: one standalone card per
  // theme without a family, one parent card per family with its variants
  // kept behind it. A family of one is promoted to a standalone theme, so a
  // card never expands into a single child that repeats it.
  function _buildRows(data) {
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
    for (const fam in families) {
      if (families[fam].length === 1) {
        standalone.push(families[fam][0])
        delete families[fam]
      }
    }

    const out = []
    standalone.sort((a, b) => root._compareAlpha(a.label, b.label))
    for (let i = 0; i < standalone.length; i++) {
      const e = standalone[i]
      out.push({
        family: "",
        label: e.label,
        folder: e.folder,
        light: e.light,
        colors: e.colors,
        variants: []
      })
    }

    const fams = Object.keys(families).sort((a, b) => root._compareAlpha(a, b))
    for (let f = 0; f < fams.length; f++) {
      const fam = fams[f]
      const variants = families[fam].slice().sort((a, b) => root._compareAlpha(a.variant, b.variant))
      const children = []
      for (let v = 0; v < variants.length; v++) {
        const e = variants[v]
        children.push({
          family: fam,
          label: e.variant,
          folder: e.folder,
          light: e.light,
          colors: e.colors
        })
      }
      out.push({
        family: fam,
        label: fam,
        folder: "",
        light: variants[0].light,
        colors: variants[0].colors,
        variants: children
      })
    }

    out.sort((a, b) => root._compareAlpha(a.label, b.label))
    return out
  }

  // Close out a finished scan: sort, cache, and publish. Only the current
  // generation advances here; a queued scan starts next.
  function _finishScan(st) {
    if (st.gen !== root._scanGen) return
    root._scanJob = null
    const out = st.out
    out.sort((a, b) => root._compareAlpha(a.label, b.label))

    root._cached = out
    root.rows = root._buildRows(out)

    if (root._scanQueued) {
      root._scanQueued = false
      root._doScan()
    }
  }

  // --- public API ---

  // Arm and run the first scan without opening the overlay. The singleton
  // calls this once at boot; an open that beats the scan to the cache joins
  // the same job instead of starting a second one.
  function warm() {
    if (root._cached !== null || root._scanJob !== null) return "ok"
    roots.arm()
    roots.rearmUnready()
    if (roots.listed) root._doScan()
    return "ok"
  }

  function open() {
    if (root.visible) return "ok"
    // The overlay is a visit of its own; a menu that summoned it goes away
    // rather than sitting dimmed behind the deck.
    Registry.call("menu", "close")
    root.visible = true
    if (root._cached !== null) {
      root.rows = root._buildRows(root._cached)
      // The themes roots are external state: a folder added/removed while
      // the picker was closed leaves this cache stale. Re-aim (picks up a
      // root created since the arming) and refresh in the background; the
      // finished scan updates the open deck live. Refresh explicitly
      // via `refresh` after editing theme.info/colors.list in place.
      roots.rearmUnready()
      if (roots.listed) root._doScan()
      else roots.arm()
      return "ok"
    }
    // No cache yet: warm owns the first arm. If boot prewarming is already
    // in flight this joins that job rather than starting a second scan.
    root.warm()
    return "ok"
  }

  // Manual rescan for in-place theme.info/colors.list edits (the dir
  // watcher only fires on added/removed themes). A listing that was never
  // armed holds no rows to rescan and answers error, the same answer the
  // not-Ready gate gives while a scan is still in flight.
  function refresh() {
    if (!roots.listed) return "error"
    root._cached = null
    root._doScan()
    return "ok"
  }

  function close() {
    if (root.visible) root.visible = false
    Registry.call("menu", "close")
    return "ok"
  }
  function toggle() {
    return root.visible ? root.close() : root.open()
  }

  function status() {
    return JSON.stringify({
      cached: root._cached ? root._cached.length : 0,
      rows: root.rows ? root.rows.length : 0,
      active: root._activeTheme,
      visible: root.visible
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

  ThemePickerView {}
}

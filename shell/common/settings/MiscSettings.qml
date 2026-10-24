pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "SettingsLib.js" as SL
import "GtkSettings.js" as GtkSettings
import "../text/UnitIpc.js" as UnitIpc

// Cursor theme and cursor size - the two options the settings schema
// declares under the General page, in shell/10-wallpaper.jsonc.
//
// Not persisted in settings.json; the values live in cursor-theme.json,
// written by vb-cursor-set. Settings projects this singleton's live values
// onto those two keys, which is the whole of what this unit is for: the
// schema entry is the shape, this is the current value.
//
// The `misc.` key prefix and the unit id name a Misc settings page that
// this tree does not have - `menuHasPage` below returns false for
// everything. The `miscPage` local in
// _loadFallback is not that page: it is a holder for the two option records
// this unit registers. The ids are kept because they are the join key for
// the schema, the IPC target and the log scope, and renaming them is a
// change to three other files rather than a rename.
Singleton {
    id: root
    readonly property string tag: "miscSettings"
    property bool ready: false
    property int rev: 0
    property var values: ({})
    property var _byKey: ({})

    signal optionChanged(string key, var value)

    Component.onCompleted: {
      Registry.offer("miscSettings", {
        title: "Misc settings",
        description: "misc user preferences",
        verbNames: [
          "dump",
          "get",
          "set",
          "status",
          "help",
          "ping",
        ]
      })
        Registry.register("miscSettings", root)
        root._load()
    }
    Component.onDestruction: Registry.unregister("miscSettings")

    function value(key) {
        root.rev
        return root.values[key]
    }
    function byKey(key) { return root._byKey[key] !== undefined ? root._byKey[key] : null }
    function conditionsMet(showIf) {
        if (!root._byKey) return true
        root.rev
        return SL.conditionsMet(root._byKey, root.values, showIf)
    }
    // This unit publishes no page of its own. The two cursor options are
    // declared by the schema under General, and Settings projects their live
    // values from here; the menu is never handed a bundle by this singleton.
    function menuBundleText() { return "" }
    function menuHasPage(pageId) { return false }

    FileView { id: schemaLoader; printErrors: false }
    property var _schema: null
    readonly property var pages: root._schema ? root._schema.pages : []

    // This store is the smallest of the three and the only one whose external
    // sources are enumerated rather than merged, so `ready` here means "the
    // schema is usable" and deliberately does NOT wait for the cursor scans -
    // the scans fill an enum, not an option value, and blocking first paint on
    // a `vb-cursor-list` subprocess would make a missing script a slow shell
    // instead of an Adwaita-only picker.
    function _load() {
        // The directory catalog: the misc/ files are already namespaced. It
        // is the only catalog - there is no second copy to fall back to, so
        // a catalog that cannot be read leaves the store with no options
        // and says why.
        schemaLoader.path = ""
        schemaLoader.path = Paths.settingsSchemaDir + "/_index.jsonc"
        if (!schemaLoader.waitForJob()) {
            Log.error("miscSettings: the catalog index could not be read: "
                + Paths.settingsSchemaDir + "/_index.jsonc")
            root._loadFallback()
            return
        }
        let idx = null
        try {
            idx = JSON.parse(SL.stripJsonc(schemaLoader.text()))
        } catch (e) {
            Log.error("miscSettings: the catalog index did not parse: "
                + (e && e.message ? e.message : String(e)))
            idx = null
        }
        if (!idx || typeof idx !== "object") {
            root._loadFallback()
            return
        }
        const files = Paths.miscCatalogFiles
        // General lives under shell/: derive namespace per file
        // like Settings does, so shell rows pass natively and the 3
        // misc riders pass via SHELL_CROSS_OK.
        const namespaces = []
        for (let i = 0; i < files.length; i++) {
            namespaces.push(files[i].indexOf("/misc/") >= 0 ? "misc" : (files[i].indexOf("/env/") >= 0 ? "env" : "shell"))
        }
        // The read, and the all-or-nothing bail that goes with it, is
        // Settings': one code path for both stores, so the two cannot
        // drift on the part that decides whether a partial set reaches
        // the parser. miscCatalogFiles names one file today, so there is
        // nothing here to overlap - the point is that the shape is the
        // same one, not that this store gets faster.
        const texts = Settings.readCatalogTexts(root, files)
        if (!texts) {
            root._loadFallback()
            return
        }
        let catalog = null
        try {
            catalog = SL.parseCatalogDir(texts, namespaces, 0, "")
        } catch (e) {
            Log.error("miscSettings: the directory catalog did not parse: "
                + (e && e.message ? e.message : String(e)))
        }
        if (!catalog) {
            root._loadFallback()
            return
        }
        if (!root._adoptCatalog(catalog.pages || [])) return
    }
    // Collect every misc.* option across the scanned pages into one
    // synthetic page (no misc.* option rides a page of its own). Returns
    // false when nothing was found (caller falls back).
    function _adoptCatalog(all) {
        const miscOpts = []
        const seenMisc = {}
        for (let i = 0; i < all.length; i++) {
            const pg = all[i]
            for (let j = 0; j < pg.options.length; j++) {
                const o = pg.options[j]
                if (o.misc && !seenMisc[o.key]) {
                    seenMisc[o.key] = true
                    miscOpts.push(o)
                }
            }
        }
        if (miscOpts.length === 0) {
            root._loadFallback()
            return false
        }
        const miscPage = { page: "misc", label: "Misc", options: miscOpts, items: [], errors: [] }
        // Register options from catalog
        for (let i = 0; i < miscPage.options.length; i++) {
            const o = miscPage.options[i]
            root._byKey[o.key] = o
        }
        // Seed values from defaults then system state
        for (let k in root._byKey) root.values[k] = root._byKey[k].default
        root._schema = { sections: [miscPage], pages: [miscPage], byKey: root._byKey, rootWidth: 0, rootTitle: "" }
        root._readCurrentState()
        // The cursor enum behind these values is filled by a subprocess that
        // has not been spawned yet, which is why `ready` fires before
        // _scanCursorOptions.
        root.ready = true
        root.rev++
        root._scanCursorOptions()
        // Trigger initial scans for dynamic values
        Qt.callLater(() => {
            // CursorPicker populates values when it scans
            // If they already scanned, they will update via update*Options
        })
        return true
    }
    function _loadFallback() {
        // Fallback hard-coded (should not happen)
        const opts = []
        opts.push({ key: "misc.cursorTheme", type: "string", default: "Adwaita", label: "Cursor theme", values: ["Adwaita"], valueLabels: null, hypr: null, misc: true, id: "misc.cursorTheme", env: false, hidden: false, showIf: null, when: "", disabled: "", hook: "", min: undefined, max: undefined, step: 1, unit: "" })
        opts.push({ key: "misc.cursorSize", type: "int", default: 24, label: "Cursor size", values: [24, 32], valueLabels: null, hypr: null, misc: true, id: "misc.cursorSize", env: false, hidden: false, showIf: null, when: "", disabled: "", hook: "", min: undefined, max: undefined, step: 1, unit: " px" })
        for (let i = 0; i < opts.length; i++) {
            const o = opts[i]
            const check = SL.validateValue(o, o.default)
            if (!check.ok) continue
            o.default = check.value
            o.misc = true
            root._byKey[o.key] = o
            root.values[o.key] = o.default
        }
        root._schema = { sections: [{ page: "misc", label: "Misc", options: opts, items: [], errors: [] }], pages: [{ page: "misc", label: "Misc", options: opts, items: [], errors: [] }], byKey: root._byKey, rootWidth: 0, rootTitle: "" }
        root._readCurrentState()
        // The fallback is two hard-coded options and is unreachable on a
        // checkout that has a catalog.
        root.ready = true
        root.rev++
        root._scanCursorOptions()
    }

    function _readCurrentState() {
        // Read cursor theme/size from state file and gtk
        stateReader.path = ""
        stateReader.path = Paths.vibraniumState + "/cursor-theme.json"
        let theme = "Adwaita", size = 24
        if (stateReader.waitForJob()) {
            let o = null
            try { o = JSON.parse(stateReader.text()) } catch (e) { o = null }
            if (o && typeof o === "object") {
                if (typeof o.theme === "string" && o.theme !== "") theme = o.theme
                const n = parseInt(o.size, 10)
                if (!isNaN(n)) size = n
            }
        } else {
            // Fallback to gtk, parsed through the shared GtkSettings
            // reader so every settings.ini fallback resolves identically.
            gtkReader.path = ""
            gtkReader.path = Paths.configHome + "/gtk-3.0/settings.ini"
            if (gtkReader.waitForJob()) {
                const txt = gtkReader.text()
                const t = GtkSettings.cursorThemeOf(txt, "")
                if (t !== "") theme = t
                const n = GtkSettings.cursorSizeOf(txt, -1)
                if (n >= 0) size = n
            }
        }
        const next = Object.assign({}, root.values)
        const themeChanged = next["misc.cursorTheme"] !== theme
        const sizeChanged = next["misc.cursorSize"] !== size
        next["misc.cursorTheme"] = theme
        next["misc.cursorSize"] = size
        if (themeChanged || sizeChanged) {
            root.values = next
            root.rev++
            if (themeChanged) root.optionChanged("misc.cursorTheme", theme)
            if (sizeChanged) root.optionChanged("misc.cursorSize", size)
        }
    }

    function setOption(key, v) {
        const opt = root.byKey(key)
        if (!opt) return false
        const check = SL.validateValue(opt, v)
        if (!check.ok) {
            return false
        }
        const next = Object.assign({}, root.values)
        next[key] = check.value
        root.values = next
        root.rev++
        root.optionChanged(key, check.value)
        // Trigger actual system change via pickers. Absolute script paths -
        // the shell service runs without $VIBRANIUM/bin on PATH.
        if (key === "misc.cursorTheme") {
            const proc = themeProc.createObject(root, { command: [Paths.vibraniumHome + "/bin/vb-cursor-set", check.value] })
            proc.exited.connect((code, status) => {
                if (code === 0) root._readCurrentState()
                proc.destroy()
            })
            proc.running = true
            root._scanCursorSizes(check.value)
        } else if (key === "misc.cursorSize") {
            const curTheme = root.values["misc.cursorTheme"] || "Adwaita"
            const proc = sizeProc.createObject(root, { command: [Paths.vibraniumHome + "/bin/vb-cursor-set", "--size", String(check.value), curTheme] })
            // vb-cursor-set expects theme as positional arg, size via --size
            // Actually vb-cursor-set [THEME] --size SIZE, so we need to handle correctly
            // For size change, keep current theme
            proc.exited.connect((code, status) => {
                if (code === 0) root._readCurrentState()
                proc.destroy()
            })
            proc.running = true
        }
        return true
    }

    function _replaceBoundOptions(key) {
        const opt = root._byKey[key]
        if (!opt || !Array.isArray(opt.values)) return false
        const labels = opt.valueLabels && typeof opt.valueLabels === "object"
            ? opt.valueLabels : {}
        const choices = []
        for (let i = 0; i < opt.values.length; i++) {
            const value = opt.values[i]
            const valueKey = String(value)
            choices.push({
                value: value,
                label: labels[valueKey] !== undefined ? String(labels[valueKey]) : valueKey
            })
        }
        return OptionHost.replaceBoundOptions(key, choices)
    }

    function updateThemeOptions(themes) {
        const opt = root._byKey["misc.cursorTheme"]
        if (!opt) return
        const values = themes.map(t => t.folder)
        const labels = {}
        for (let t of themes) labels[t.folder] = t.pretty
        opt.values = values
        opt.valueLabels = labels
        const cur = root.values["misc.cursorTheme"]
        if (values.indexOf(cur) < 0) {
            opt.values = [cur].concat(values)
            if (!opt.valueLabels[cur]) opt.valueLabels[cur] = cur
        }
        root.rev++
        root._replaceBoundOptions("misc.cursorTheme")
    }

    function updateSizeOptions(sizes, theme) {
        if (theme !== undefined && String(theme) !== String(root.values["misc.cursorTheme"])) return false
        if (!Array.isArray(sizes) || sizes.length === 0) return false
        const opt = root._byKey["misc.cursorSize"]
        if (!opt) return false
        opt.values = sizes.slice()
        opt.min = Math.min.apply(null, sizes)
        opt.max = Math.max.apply(null, sizes)
        const labels = {}
        for (let s of sizes) labels[String(s)] = String(s) + " px"
        opt.valueLabels = labels
        root.rev++
        root._replaceBoundOptions("misc.cursorSize")
        return true
    }

    // --- installed cursor theme/size scan ---
    // MiscSettings owns its option enums: CursorPicker may be idle, and the
    // shell service runs without $VIBRANIUM/bin on PATH, so the scan goes
    // through absolute script paths right after the catalog loads.

    Process {
        id: themeScan

        stdout: StdioCollector { id: themeScanOut }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (code !== 0) {
                // A non-zero exit here is the whole failure mode this scan has,
                // and it is silent by design: the option keeps the schema's
                // single-value enum until the next scan succeeds.
                return
            }
            // vb-cursor-list --pairs prints one "folder<TAB>display" row
            // per theme in a single process (sorted): stable pairing,
            // unlike the old paste-of-two-runs which could misalign when
            // the two processes iterated in different orders.
            const themes = []
            const lines = themeScanOut.text.split("\n")
            for (let i = 0; i < lines.length; i++) {
                const line = lines[i]
                if (line.trim() === "") continue
                const tab = line.indexOf("\t")
                const folder = tab >= 0 ? line.substring(0, tab).trim() : line.trim()
                const pretty = tab >= 0 ? line.substring(tab + 1).trim() : folder
                if (folder === "") continue
                themes.push({ folder: folder, pretty: pretty !== "" ? pretty : folder })
            }
            // Empty is a successful run that found nothing, and it is NOT the
            // same as a failure: it leaves the schema enum alone rather than
            // pinning it, so the next scan (open or state change) recovers.
            if (themes.length === 0) return
            root.updateThemeOptions(themes)
            root._scanCursorSizes(root.values["misc.cursorTheme"])
        }
    }
    Process {
        id: sizeScan

        property string _theme: ""
        property bool _replacePending: false
        stdout: StdioCollector { id: sizeScanOut }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (sizeScan._replacePending) {
                sizeScan._replacePending = false
                // The superseded run's exit. Its result is for a theme the
                // newer run already covers, so it is dropped.
                return
            }
            const theme = sizeScan._theme
            if (theme === "" || String(theme) !== String(root.values["misc.cursorTheme"])) {
                // The user switched theme while the scan ran. The result is
                // correct for a theme that is no longer selected, and dropping
                // it is the right behaviour: applying it would repin the enum
                // to the newly chosen theme's scan, which is the one after it.
                return
            }
            if (code !== 0) return
            // vb-cursor-list --size THEME prints "THEME s1 s2 ...".
            const parts = sizeScanOut.text.trim().split(/\s+/)
            if (parts[0] !== theme) {
                // The script echoed a different theme than it was asked for.
                // That is a bug in the script or a stale symlink target, and it
                // is the one case where a wrong size would land silently.
                return
            }
            const sizes = []
            for (let i = 1; i < parts.length; i++) {
                const n = parseInt(parts[i], 10)
                if (!isNaN(n) && sizes.indexOf(n) < 0) sizes.push(n)
            }
            if (sizes.length === 0) return
            root.updateSizeOptions(sizes, theme)
        }
    }

    function _scanCursorOptions() {
        // Guard the Boot-order race: MiscSettings resolves before Paths in
        // the SYNC floor, so vibraniumHome may still be empty on the very
        // first load. No retry timer: the Connections below re-runs the
        // scan once the home path lands, so an empty home waits instead
        // of polling.
        if (!Paths.vibraniumHome) {
            return
        }
        const bin = Paths.vibraniumHome + "/bin/vb-cursor-list"
        // Single-process --pairs run: one "folder<TAB>pretty" row per
        // theme, sorted. No paste-of-two-runs (fragile pairing) and no
        // PATH dependency (the script sources its lib via its own dir).
        themeScan.command = [bin, "--pairs"]
        themeScan.running = true
    }

    // Boot-order race, same rule as _scanCursorOptions: the pending
    // theme replays through the Connections below once the home path
    // lands, instead of a timer loop.
    property string _pendingSizeTheme: ""
    Connections {
        target: Paths
        function onVibraniumHomeChanged() {
            if (!Paths.vibraniumHome) return
            root._scanCursorOptions()
            if (root._pendingSizeTheme !== "") {
                const theme = root._pendingSizeTheme
                root._pendingSizeTheme = ""
                root._scanCursorSizes(theme)
            }
        }
    }

    function _scanCursorSizes(theme) {
        if (theme === undefined || theme === null || String(theme) === "") return
        if (!Paths.vibraniumHome) {
            root._pendingSizeTheme = String(theme)
            return
        }
        root._pendingSizeTheme = ""
        const scanTheme = String(theme)
        const wasRunning = sizeScan.running
        sizeScan._theme = scanTheme
        sizeScan._replacePending = wasRunning
        if (wasRunning) sizeScan.running = false
        sizeScan.command = [Paths.vibraniumHome + "/bin/vb-cursor-list", "--size", scanTheme]
        sizeScan.running = true
    }

    FileView { id: stateReader; printErrors: false }
    FileView { id: gtkReader; printErrors: false }

    // Live value sync: cursor-theme.json is written by vb-cursor-set, which
    // any picker path (and a hand edit) can trigger. Watching it here keeps
    // the projected misc.* values - and the menu rows bound to them - on
    // the file without a restart. Our own setOption writes echo back
    // through the same path, but _readCurrentState only bumps rev on real
    // change, so the echo is a no-op rather than a loop. The theme-list
    // rescan alongside covers a theme installed mid-session.
    FileView {
        path: Paths.vibraniumState + "/cursor-theme.json"
        watchChanges: true
        printErrors: false
        onFileChanged: { root._readCurrentState(); root._scanCursorOptions() }
        onLoaded: root._readCurrentState()
    }

    Component {
        id: themeProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
    Component {
        id: sizeProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }

    IpcHandler {
        target: "miscSettings"
        function help(command: string): string {
          return UnitIpc.help("miscSettings", "Misc settings", "misc user preferences", [
            { name: "dump", help: "all misc values" },
            { name: "get", help: "(key) read one value" },
            { name: "set", help: "(key, value) write one value" },
          ], command)
        }
        function status(): string {
          return JSON.stringify({ unit: "miscSettings", healthy: true })
        }
        function ping(): string { return "pong" }
        function get(key: string): string {
            const v = root.value(key)
            return v !== undefined ? JSON.stringify({key: key, value: v}) : JSON.stringify({error: "unknown"})
        }
        function set(key: string, json: string): string {
            let v; try { v = JSON.parse(json) } catch(e) { return "error" }
            return root.setOption(key, v) ? "ok" : "error"
        }
        function dump(): string { return JSON.stringify(root.values) }
    }
}

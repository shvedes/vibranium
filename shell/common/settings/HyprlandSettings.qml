pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Qt.labs.folderlistmodel
import qs.common
import "SettingsLib.js" as SL
import "HyprlandEditor.js" as HE
import "../text/UnitIpc.js" as UnitIpc

// Native Hyprland settings store - file-backed + live hyprctl.
//
// Mirrors Settings.qml but for hyprland lua configs. Values live in hypr
// files (look-and-feel.lua, input.lua, advanced.lua, smart-gaps.lua,
// animations.lua) and are optionally shadowed by live hyprctl state.
// The schema is the hypr subset of catalog.jsonc (keys hypr.* with
// `hypr` binding). HyprlandSettings owns its pages, Settings owns shell/env.
// Menu merges both bundles so navigation sees one tree: Settings -> Hyprland.
//
// Storage:
//   hypr.* options  ->  hypr lua files via HyprlandEditor.js
//   smartGaps       ->  file existence smart-gaps.lua
//   animPreset      ->  symlink animations.lua
//
// Live fetch:
//   hyprctl -j --batch "getoption ctl;..." -> populates values, fallbacks to
//   file content when hyprctl unavailable or returns nan/empty.
//
// No bash helpers, no lua interpreter - pure JS + FileView + Process.
Singleton {
    id: root
    readonly property string tag: "hyprlandSettings"
    property bool ready: false
    property int rev: 0

    property var values: ({})
    property var _schema: null
    readonly property var pages: root._schema ? root._schema.pages : []
    readonly property var sections: root.pages
    property var _byKey: ({})

    signal optionChanged(string key, var value)
    signal optionError(string key, string message)

    Component.onCompleted: {
      Registry.offer("hyprlandSettings", {
        title: "Hyprland settings",
        description: "Hyprland config editor",
        verbNames: [
          "dump",
          "get",
          "reload",
          "set",
          "toggle",
          "status",
          "help",
          "ping",
        ]
      })
        root._loadSchema()
        Hyprland.rawEvent.connect(root.onRawEvent)
    }
    Component.onDestruction: {
        Hyprland.rawEvent.disconnect(root.onRawEvent)
    }

    // Live config changes (including our own writes echoing back) invalidate
    // through the same fetch path the file watches drive.
    function onRawEvent(event) {
        if (!event || event.name !== "configreloaded") return
        root._fetchLive()
    }

    // --- generic store API ---

    function value(key) {
        root.rev
        return root.values[key]
    }

    function byKey(key) {
        return root._byKey[key] !== undefined ? root._byKey[key] : null
    }

    function conditionsMet(showIf) {
        if (!root._schema) return true
        root.rev
        return SL.conditionsMet(root._byKey, root.values, showIf)
    }

    function setOption(key, v, hook) {
        const opt = root.byKey(key)
        if (!opt) {
            root.optionError(key, "unknown option")
            return false
        }
        const check = SL.validateValue(opt, v)
        if (!check.ok) {
            root.optionError(key, check.error)
            return false
        }
        const ok = root._commitHypr(key, check.value)
        if (!ok) return false
        if (hook !== undefined && String(hook).trim() !== "") root.runHook(String(hook))
        return true
    }

    function toggleOption(key, hook) {
        const cur = root.value(key)
        return root.setOption(key, !(cur === true), hook)
    }

    function _commitHypr(key, v) {
        const opt = root.byKey(key)
        if (!opt || !opt.hypr) return false
        // Read before the writers run: a rejected write returns below with
        // the store untouched, so the value here is the one the file holds.
        const meta = opt.hypr
        let ok = false
        if (meta.kind === "smartGaps") {
            ok = root._writeSmartGaps(v === true)
        } else if (meta.kind === "animPreset") {
            ok = root._writeAnimPreset(String(v))
        } else {
            ok = root._writeHyprOption(meta, v)
        }
        if (!ok) {
            root.optionError(key, "write failed")
            return false
        }
        const next = Object.assign({}, root.values)
        next[key] = v
        root.values = next
        root.rev++
        root.optionChanged(key, v)
        // anim preset or any hypr change triggers reload already; smart gaps also reloads
        return true
    }

    // --- settings load phases ---
    //
    // `ready` has FOUR writers in this store and they are four different
    // arrivals, not four copies of one: an empty catalog, no option with a
    // hyprctl handle, a hyprctl failure, and a hyprctl success. Routing them
    // through one function is what keeps the four distinguishable, and
    // `source` is the fact that distinguishes them.
    function _markReady() {
        root.ready = true
    }

    // --- schema loading ---

    function _loadSchema() {
        // The unified catalog: this store keeps the hypr.* options and
        // drops everything else. It is the only catalog - there is no
        // second copy to fall back to, so a catalog that cannot be read
        // leaves the store with no options and says why.
        schemaLoader.path = ""
        schemaLoader.path = Paths.settingsCatalogPath
        if (!schemaLoader.waitForJob()) {
            Log.error("hyprlandSettings: the catalog could not be read: "
                + Paths.settingsCatalogPath)
            root._schemaDoneEmpty()
            return
        }
        let catalog = null
        try {
            catalog = SL.parseUnifiedCatalog(schemaLoader.text())
        } catch (err) {
            Log.error("hyprlandSettings: the catalog did not parse: "
                + (err && err.message ? err.message : String(err)))
        }
        if (!catalog) {
            root._schemaDoneEmpty()
            return
        }
        const hyprPages = []
        const hyprByKey = {}
        for (let i = 0; i < catalog.sections.length; i++) {
            const pg = catalog.sections[i]
            // The group is the ownership - including the items-only nav
            // pages (hyprland, hyprland-edit, hyprland-appearance), which
            // carry no option to infer it from.
            if (pg.group !== "hypr") continue
            hyprPages.push(pg)
            for (let o = 0; o < pg.options.length; o++) hyprByKey[pg.options[o].key] = pg.options[o]
        }
        root._hyprCollected = hyprPages
        root._hyprByKey = hyprByKey
        root._collectedRootWidth = catalog.rootWidth
        root._collectedRootTitle = catalog.rootTitle
        root._schemaDone()
    }

    function _schemaDoneEmpty() {
        root._schema = { sections: [], pages: [], byKey: {}, rootWidth: 0, rootTitle: "" }
        root._byKey = {}
        // The catalog indexed to nothing. Not a failure - a hypr/ directory that
        // does not exist is a normal checkout - but it means the page has no
        // options at all, which looks identical to a parse bug from the outside
        // and should not.
        root._markReady()
    }

    function _schemaDone() {
        const secs = root._hyprCollected || []
        const byKey = root._hyprByKey || {}
        root._schema = { sections: secs, pages: secs, byKey: byKey, rootWidth: root._collectedRootWidth, rootTitle: root._collectedRootTitle }
        root._byKey = byKey
        root._hyprCollected = []
        root._hyprByKey = {}

        // Seed values from defaults
        const init = {}
        for (const k in byKey) init[k] = byKey[k].default
        root.values = init
        root.rev++

        // Three external sources, probed where each is opened rather than where
        // it lands: the two file probes resolve synchronously and would
        // otherwise be indistinguishable from the schema build, and the batch
        // fetch is the only one that can fail and be retried from disk.
        // Determine initial smartGaps & animPreset synchronously via file probe, then live fetch.
        // The preset refresh merges the on-disk shelves into the option
        // first, so a symlinked custom preset validates on boot, and ends
        // with its own probe.
        root._probeSmartGaps()
        root._refreshAnimPresetValues()
        root._fetchLive()
    }

    property var _hyprCollected: []
    property var _hyprByKey: ({})
    property int _collectedRootWidth: 0
    property string _collectedRootTitle: ""

    // --- path expansion ---
    // Hypr JSON uses "$XDG_CONFIG_HOME/..." - expand via Paths, not only
    // HE.expand_path (which relies on Quickshell.env and may be empty before
    // session env is ready). This avoids creating a literal "$XDG_CONFIG_HOME"
    // directory in $HOME.
    function _expandFile(p) {
        let s = String(p)
        if (s.startsWith("$XDG_CONFIG_HOME/")) return Paths.configHome + s.slice("$XDG_CONFIG_HOME".length)
        if (s.startsWith("${XDG_CONFIG_HOME}/")) return Paths.configHome + s.slice("${XDG_CONFIG_HOME}".length)
        if (s === "$XDG_CONFIG_HOME") return Paths.configHome
        if (s === "${XDG_CONFIG_HOME}") return Paths.configHome
        if (s.startsWith("$HOME/")) return Paths.home + s.slice("$HOME".length)
        if (s.startsWith("${HOME}/")) return Paths.home + s.slice("${HOME}".length)
        if (s === "~") return Paths.home
        if (s.startsWith("~/")) return Paths.home + s.slice(1)
        return HE.expand_path(s)
    }

    // --- file helpers ---

    function _readFileContent(expandedPath) {
        reader.path = ""
        reader.path = expandedPath
        if (!reader.waitForJob()) return ""
        return reader.text()
    }

    function _writeFileContent(expandedPath, content) {
        writer.path = expandedPath
        writer.setText(content)
        return writer.waitForJob()
    }

    function _writeHyprOption(meta, value) {
        const file = root._expandFile(meta.file)
        const content = root._readFileContent(file)
        const res = HE.hyprEditContent(content, meta.path, value, { occurrence: 1 })
        if (!res.ok) {
            return false
        }
        const ok = root._writeFileContent(file, res.content)
        if (!ok) {
            return false
        }
        root._reloadHyprland()
        return true
    }

    function _probeSmartGaps() {
        const p = root._expandFile("$XDG_CONFIG_HOME/hypr/hyprland.conf.d/smart-gaps.lua")
        probeSmart.path = ""
        probeSmart.path = p
        const exists = probeSmart.waitForJob() && probeSmart.text().trim() !== ""
        // Also check file existence via probe success - waitForJob false means missing
        const enabled = exists
        // smartGaps key is hypr.general.smart_gaps if present
        const key = "hypr.general.smart_gaps"
        if (root._byKey[key] !== undefined) {
            const next = Object.assign({}, root.values)
            next[key] = enabled
            root.values = next
        }
    }

    function _probeAnimPreset() {
        const key = "hypr.animations.preset"
        if (root._byKey[key] === undefined) return
        if (readlinkProc.running) {
            root._probeQueued = true
            return
        }
        const target = root._expandFile("$XDG_CONFIG_HOME/hypr/hyprland.conf.d/animations.lua")
        readlinkProc.command = ["readlink", "-f", target]
        readlinkProc.running = true
    }
    property bool _probeQueued: false

    // Live preset inventory: the catalog ships the 7 bundled names, but
    // ~/.config/hypr/animations/*.lua is the user's own preset shelf and
    // must appear in the option without a restart. Both folders are listed
    // with FolderListModel (async, self-updating on directory change), so
    // a new file lands in the dropdown and re-probes on its own.
    property var _animCustomNames: []
    function _animDirUrl(dir) {
        if (dir === undefined || dir === null || String(dir) === "") return ""
        return "file://" + String(dir)
    }
    function _animBareNames(model) {
        const out = []
        if (!model || model.status !== FolderListModel.Ready) return out
        for (let i = 0; i < model.count; i++) {
            let f = ""
            try { f = String(model.get(i, "fileName")) } catch (e) { f = "" }
            if (f === "" || !f.endsWith(".lua")) continue
            const base = f.slice(0, -4)
            if (base !== "" && out.indexOf(base) < 0) out.push(base)
        }
        return out
    }
    function _refreshAnimPresetValues() {
        const key = "hypr.animations.preset"
        const opt = root._byKey[key]
        if (!opt) return
        const bundled = Array.isArray(opt.values) ? opt.values.slice() : []
        const customs = root._animBareNames(animCustomModel)
        root._animCustomNames = customs.slice()
        const defaults = root._animBareNames(animDefaultModel)
        const names = bundled.slice()
        const extra = []
        const seen = {}
        for (let i = 0; i < names.length; i++) seen[names[i]] = true
        const shelves = [defaults, customs]
        for (let s = 0; s < shelves.length; s++) {
            const list = shelves[s]
            for (let i = 0; i < list.length; i++) {
                if (!seen[list[i]]) { seen[list[i]] = true; extra.push(list[i]) }
            }
        }
        extra.sort()
        const labels = Object.assign({}, opt.valueLabels || {})
        for (let i = 0; i < extra.length; i++) {
            if (labels[extra[i]] === undefined)
                labels[extra[i]] = extra[i].charAt(0).toUpperCase() + extra[i].slice(1)
        }
        opt.values = names.concat(extra)
        opt.valueLabels = labels
        root.rev++
        root._probeAnimPreset()
    }

    function _writeSmartGaps(enabled) {
        const file = root._expandFile("$XDG_CONFIG_HOME/hypr/hyprland.conf.d/smart-gaps.lua")
        if (enabled) {
            const content = "hl.workspace_rule({\n  workspace = \"w[tv1] w[g0] s[false]\",\n  gaps_out = 0,\n  gaps_in = 0,\n})\n\nhl.window_rule({\n  match = {\n    float = false,\n    workspace = \"w[tv1] w[g0] s[false]\",\n  },\n  decorate = false\n})\n"
            const ok = root._writeFileContent(file, content)
            if (!ok) return false
        } else {
            // Race-free disable: write single space synchronously. Probe
            // treats whitespace-only (or missing) as disabled, and FileView
            // ignores empty-string writes (see test), so a space is the
            // minimal whitespace that actually truncates the file.
            const ok = root._writeFileContent(file, " ")
            if (!ok) return false
        }
        root._reloadHyprland()
        return true
    }

    // Backup check for anim preset - pure QML, no bash
    FileView { id: animProbe; printErrors: false }
    Process {
        id: animTestLProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (code === 0) {
                lnProc.command = ["ln", "-sf", root._animPendingSrc, root._animPendingTarget]
                lnProc.running = true
                root._reloadHyprland()
            } else {
                animProbe.path = ""
                animProbe.path = root._animPendingTarget + ".bak"
                const bakExists = animProbe.waitForJob()
                let bakPath = root._animPendingTarget + ".bak"
                if (bakExists) bakPath = root._animPendingTarget + ".bak." + Math.floor(Date.now()/1000)
                animMvProc.command = ["mv", root._animPendingTarget, bakPath]
                animMvProc.running = true
            }
        }
    }
    Process {
        id: animMvProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            lnProc.command = ["ln", "-sf", root._animPendingSrc, root._animPendingTarget]
            lnProc.running = true
            root._reloadHyprland()
        }
    }
    property string _animPendingSrc: ""
    property string _animPendingTarget: ""

    function _writeAnimPreset(preset) {
        const vibraniumHome = Paths.vibraniumHome !== "" ? Paths.vibraniumHome : root._expandFile("$VIBRANIUM")
        const configHome = Paths.configHome
        const targetFile = root._expandFile("$XDG_CONFIG_HOME/hypr/hyprland.conf.d/animations.lua")
        const defaultFolder = vibraniumHome + "/default/hypr/animations"
        const customFolder = configHome + "/hypr/animations"
        // A preset present on the user's shelf wins over the bundled copy;
        // everything else resolves to the bundled file.
        const sourceFolder = root._animCustomNames.indexOf(preset) >= 0 ? customFolder : defaultFolder
        const src = sourceFolder + "/" + preset + ".lua"
        // Pure check: does target exist and is not a symlink?
        animProbe.path = ""
        animProbe.path = targetFile
        const exists = animProbe.waitForJob()
        if (exists) {
            // Check if it's a symlink via test -L
            root._animPendingSrc = src
            root._animPendingTarget = targetFile
            animTestLProc.command = ["test", "-L", targetFile]
            animTestLProc.running = true
            // Next steps handled in animTestLProc.onExited
            return true
        }
        // No existing file - just symlink directly (no backup needed)
        lnProc.command = ["ln", "-sf", src, targetFile]
        lnProc.running = true
        root._reloadHyprland()
        return true
    }

    function _reloadHyprland() {
        const proc = reloadComponent.createObject(root, { command: ["hyprctl", "-q", "reload", "config-only"] })
        proc.exited.connect(proc.destroy)
        proc.running = true
    }

    // --- live fetch via hyprctl ---

    function _fetchLive() {
        if (!root._byKey) return
        const keys = []
        const ctls = []
        const typeByCtl = {}
        for (const k in root._byKey) {
            const opt = root._byKey[k]
            if (!opt.hypr) continue
            const m = opt.hypr
            if (m.kind !== "option") continue
            if (!m.ctl || m.ctl === "") continue
            // gaps_in/out fallback to file, skip hyprctl or keep but fallback
            // still fetch but will fallback to file if needed
            keys.push(k)
            ctls.push(m.ctl)
            typeByCtl[m.ctl] = opt.type
        }
        if (ctls.length === 0) {
            // Indexed fine, but nothing in the catalog names a compositor
            // option, so there is no external source to wait for. The schema
            // defaults are already the answer and the file probes are done.
            root._markReady()
            root.rev++
            return
        }
        // Build batch query: semicolon separated getoption
        let query = ""
        for (let i = 0; i < ctls.length; i++) query += (query ? ";" : "") + "getoption " + ctls[i]
        root._fetchKeys = keys
        root._fetchCtls = ctls
        root._fetchTypeByCtl = typeByCtl
        root._fetchBuf = ""
        fetchProc.command = ["hyprctl", "-j", "--batch", query]
        fetchProc.running = true
    }

    property var _fetchKeys: []
    property var _fetchCtls: []
    property var _fetchTypeByCtl: ({})
    property string _fetchBuf: ""

    // --- bundling for menu ---

    function menuBundleText() {
        if (!root._schema || !root.ready) return ""
        const b = SL.buildBundle(root._schema, root.values)
        // Hypr leaves merge as siblings into the main Settings tree - drop
        // the synthetic \"settings\" index that buildBundle prepends when no
        // explicit page with id \"settings\" exists. Settings already owns it.
        const pages = b.pages.filter(p => p.id !== "settings")
        return JSON.stringify({ pages: pages })
    }

    function menuHasPage(pageId) {
        if (!root._schema || !root.ready) return false
        if (root._schema.pages) {
            for (let i = 0; i < root._schema.pages.length; i++) if (root._schema.pages[i].page === pageId) return true
        }
        return false
    }

    function flush() {
        // Hypr writes are immediate per option; no debounce needed
    }

    function runHook(cmd) {
        const c = String(cmd).split("%v").join("")
        if (c.trim() === "") return
        const proc = hookComponent.createObject(root, { command: ["/bin/bash", "-c", c] })
        proc.exited.connect(proc.destroy)
        proc.running = true
    }

    // --- processes / file views ---

    FileView {
        id: schemaLoader
        printErrors: false
    }
    FileView {
        id: reader
        printErrors: false
    }
    FileView {
        id: writer
        atomicWrites: true
        printErrors: false
    }
    FileView {
        id: probeSmart
        printErrors: false
    }

    Process {
        id: fetchProc
        stdout: StdioCollector { id: fetchOut }
        stderr: StdioCollector { id: fetchErr }
        onExited: function(code, status) {
            let raw = ""
            try { raw = fetchOut.text } catch(e) {}
            // A batch that asked for nothing is not a merge - it is an exit
            // belonging to a run that a later `_fetchLive` already superseded,
            // because `_fetchKeys` is instance state cleared by whichever run
            // finished first. Reporting it as a merge would be a true-looking
            // answer about nothing, and it would also let the fallback path
            // below run a second time and rewrite values from disk over a live
            // result. `_fetchLive` never spawns the process with an empty key
            // list (that case returns before the spawn), so empty here can only
            // mean superseded.
            if (root._fetchKeys.length === 0) {
                return
            }
            if (code !== 0 || status !== 0 || String(raw).trim() === "") {
                // hyprctl is the LIVE source, so its absence is not an error to
                // hide: the values below come off disk and are correct until the
                // compositor says otherwise.
                root._fallbackToFiles()
                root._markReady()
                root.rev++
                return
            }
            raw = String(raw)
            // Patch nan
            raw = raw.replace(/nan/g, "0")
            let arr = null
            try {
                const trimmed = raw.trim()
                if (trimmed.startsWith("[")) {
                    arr = JSON.parse(trimmed)
                } else {
                    // Concatenated objects: "}{" -> "},{"
                    const wrapped = "[" + trimmed.replace(/\}\s*\{/g, "},{") + "]"
                    arr = JSON.parse(wrapped)
                }
            } catch(e) {
                // Exit 0 with output that is not the array we asked for: a
                // hyprctl version change and a truncated pipe both look like a
                // working command until you look, so fall back to disk.
                root._fallbackToFiles()
                root._markReady()
                root.rev++
                return
            }
            if (!Array.isArray(arr)) arr = [arr]
            const next = Object.assign({}, root.values)
            const keys = root._fetchKeys
            const ctls = root._fetchCtls
            const typeMap = root._fetchTypeByCtl
            for (let i = 0; i < keys.length && i < arr.length; i++) {
                const key = keys[i]
                const ctl = ctls[i]
                const opt = root._byKey[key]
                const obj = arr[i]
                if (!obj || typeof obj !== "object") continue
                let v = undefined
                const t = typeMap[ctl]
                if (t === "bool") v = obj.bool
                else if (t === "int") {
                    // gaps_in/out have css string not int - fallback to file
                    if (obj.int !== undefined && typeof obj.int === "number") v = obj.int
                    else if (typeof obj.css === "string") {
                        const first = obj.css.split(" ")[0]
                        const n = Number(first)
                        if (!isNaN(n)) v = Math.round(n)
                    }
                } else if (t === "float") {
                    if (obj.float !== undefined && typeof obj.float === "number") v = obj.float
                    else if (typeof obj.css === "string") {
                        const first = obj.css.split(" ")[0]
                        const n = Number(first)
                        if (!isNaN(n)) v = n
                    }
                } else if (t === "string") {
                    if (obj.str !== undefined) v = obj.str
                }
                if (v === undefined) {
                    // fallback to file - use Paths-aware expansion to avoid literal $XDG_... folder
                    const meta = opt.hypr
                    const file = root._expandFile(meta.file)
                    const content = root._readFileContent(file)
                    const res = HE.hyprGetContent(content, meta.path, { occurrence: 1 })
                    if (res.ok) v = res.value
                }
                if (v !== undefined) {
                    const check = SL.validateValue(opt, v)
                    if (check.ok) next[key] = check.value
                }
            }
            // Re-probe special kinds (smartGaps already, anim preset via earlier process)
            // smartGaps value from file probe already in next; keep
            // For anim preset, if process already set, keep; else default remains
            root.values = next
            root._fetchKeys = []
            root._fetchCtls = []
            // A key that fell back to disk is a compositor option hyprctl did not
            // answer - usually `gaps_in`, which hyprctl reports as a CSS string
            // - and it stays correct until something moves.
            root._markReady()
            root.rev++
        }
    }

    function _fallbackToFiles() {
        const next = Object.assign({}, root.values)
        for (const k in root._byKey) {
            const opt = root._byKey[k]
            if (!opt.hypr || opt.hypr.kind !== "option") continue
            const meta = opt.hypr
            const file = root._expandFile(meta.file)
            const content = root._readFileContent(file)
            const res = HE.hyprGetContent(content, meta.path, { occurrence: 1 })
            if (res.ok) {
                const check = SL.validateValue(opt, res.value)
                if (check.ok) next[k] = check.value
            }
        }
        root.values = next
    }

    Process {
        id: readlinkProc
        stdout: StdioCollector { id: readlinkOut }
        stderr: StdioCollector {}
        onExited: function(code, status) {
            let out = ""
            try { out = readlinkOut.text.trim() } catch(e) {}
            let preset = "default"
            if (out !== "") {
                const base = out.split("/").pop()
                preset = base.replace(/\.lua$/, "")
            }
            const key = "hypr.animations.preset"
            if (root._byKey[key]) {
                const check = SL.validateValue(root._byKey[key], preset)
                if (check.ok) {
                    const next = Object.assign({}, root.values)
                    next[key] = check.value
                    root.values = next
                    root.rev++
                    root.optionChanged(key, check.value)
                }
            }
            if (root._probeQueued) {
                root._probeQueued = false
                root._probeAnimPreset()
            }
        }
    }

    // Preset shelves: bundled + user. FolderListModel watches each directory
    // and fires on change, so a preset added mid-session joins the option
    // without a restart. The refresh also re-probes the symlink, so the
    // value tracks whatever the shelf now resolves to.
    FolderListModel {
        id: animDefaultModel
        folder: root._animDirUrl(Paths.vibraniumHome !== "" ? Paths.vibraniumHome + "/default/hypr/animations" : "")
        nameFilters: ["*.lua"]
        showDirs: false
        sortField: FolderListModel.Name
        onCountChanged: root._refreshAnimPresetValues()
        onStatusChanged: { if (status === FolderListModel.Ready) root._refreshAnimPresetValues() }
    }
    FolderListModel {
        id: animCustomModel
        folder: root._animDirUrl(Paths.configHome + "/hypr/animations")
        nameFilters: ["*.lua"]
        showDirs: false
        sortField: FolderListModel.Name
        onCountChanged: root._refreshAnimPresetValues()
        onStatusChanged: { if (status === FolderListModel.Ready) root._refreshAnimPresetValues() }
    }

    Process {
        id: lnProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }

    // Watch hypr lua files directly (was Watch governor): external edits
    // re-fetch live state, probes re-read their file. Own writes echo
    // back through the same path the governor delivered.
    FileView {
        path: Paths.hyprInputFile
        watchChanges: true
        printErrors: false
        onFileChanged: root._fetchLive()
        onLoaded: root._fetchLive()
    }
    FileView {
        path: Paths.hyprAppearanceFile
        watchChanges: true
        printErrors: false
        onFileChanged: root._fetchLive()
        onLoaded: root._fetchLive()
    }
    FileView {
        path: Paths.hyprAdvancedFile
        watchChanges: true
        printErrors: false
        onFileChanged: root._fetchLive()
        onLoaded: root._fetchLive()
    }
    FileView {
        path: Paths.hyprSmartGapsFile
        watchChanges: true
        printErrors: false
        onFileChanged: { root._probeSmartGaps(); root.rev++ }
        onLoaded: { root._probeSmartGaps(); root.rev++ }
    }
    FileView {
        path: Paths.hyprAnimationsFile
        watchChanges: true
        printErrors: false
        onFileChanged: root._probeAnimPreset()
        onLoaded: root._probeAnimPreset()
    }

    Component {
        id: reloadComponent
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
    Component {
        id: hookComponent
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }

    // ipc
    IpcHandler {
        target: "hyprlandSettings"
        function help(command: string): string {
          return UnitIpc.help("hyprlandSettings", "Hyprland settings", "Hyprland config editor", [
            { name: "dump", help: "edited config values" },
            { name: "get", help: "(key) read one value" },
            { name: "reload", help: "re-read the config" },
            { name: "set", help: "(key, value) write one value" },
            { name: "toggle", help: "flip a boolean key" },
          ], command)
        }
        function status(): string {
          return JSON.stringify({ unit: "hyprlandSettings", healthy: true })
        }
        function ping(): string { return "pong" }
        function get(key: string): string {
            if (root.byKey(key) === null) return JSON.stringify({error:"unknown option"})
            return JSON.stringify({key:key, value: root.value(key)})
        }
        function set(key: string, json: string): string {
            let v; try { v = JSON.parse(json) } catch(e) { return "error: invalid JSON" }
            return root.setOption(key, v) ? "ok" : "error"
        }
        function toggle(key: string): string { return root.toggleOption(key) ? "ok" : "error" }
        function dump(): string { return JSON.stringify(root.values) }
        function reload(): string { root._fetchLive(); return "ok" }
    }
}

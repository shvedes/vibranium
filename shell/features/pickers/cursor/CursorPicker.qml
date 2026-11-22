pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.menu
import "../../../common/text/UnitIpc.js" as UnitIpc
import "../../../common/settings/GtkSettings.js" as GtkSettings

// Efficient cursor theme/size picker – native, cached, no bash loop.
//
// State persistence: $VIBRANIUM_STATE/cursor-theme.json
// ({"theme": "...", "size": 24}) is owned by vb-cursor-set, the
// only writer; this picker reads it via FileView with watchChanges
// and applies changes through vb-cursor-set.
Singleton {
    id: root
    readonly property string tag: "cursorPicker"
    readonly property string pageId: "cursor-picker"

    // Cached theme list: [{folder, pretty}]
    property var _themes: null
    property var _sizeCache: ({})
    property string _currentTheme: "Adwaita"
    property int _currentSize: 24
    property bool _loading: false
    // Monotone size-scan generation: each _ensureSizes start claims a new
    // one, so an answer from a superseded run is retired even when the theme
    // name came back around (A -> B -> A).
    property int _scanGen: 0

    Component.onCompleted: {
      Registry.offer("cursorPicker", {
        title: "Cursor picker",
        description: "cursor theme selection",
        verbNames: [
          "close",
          "open",
          "setSize",
          "setTheme",
          "toggle",
          "status",
          "help",
          "ping",
        ]
      })
        Registry.register("cursorPicker", root)
        root._readStateFile()
    }
    Component.onDestruction: Registry.unregister("cursorPicker")

    // --- state via cursor-theme.json (read-only; vb-cursor-set writes) ---

    function _readStateFile() {
        if (!stateFile.waitForJob()) {
            root._readGtkFallback()
            return
        }
        const m = _parseStateJson(stateFile.text())
        if (m) {
            root.applyCurrent(m.theme, m.size)
            return
        }
        root._readGtkFallback()
    }

    // One writer of the visible theme/size. The state file (or its GTK
    // fallback when the file is absent) is the source; set verbs delegate to
    // vb-cursor-set and wait for this publish, so gesture, search and IPC
    // take the same route. A new theme needs its sizes cached or scanned.
    function applyCurrent(theme, size) {
        const t = theme === null ? root._currentTheme : theme
        const s = size === null ? root._currentSize : size
        const themeChanged = t !== root._currentTheme
        if (themeChanged) root._currentTheme = t
        if (s !== root._currentSize) root._currentSize = s
        if (themeChanged) root._ensureSizes(root._currentTheme)
    }

    function _parseStateJson(txt) {
        let o = null
        try { o = JSON.parse(txt) } catch (e) { return null }
        if (!o || typeof o !== "object") return null
        const theme = typeof o.theme === "string" && o.theme !== "" ? o.theme : null
        const n = parseInt(o.size, 10)
        const size = isNaN(n) ? null : n
        if (!theme && size === null) return null
        return { theme: theme || root._currentTheme, size: size === null ? root._currentSize : size }
    }



    function _readGtkFallback() {
        const gtkReader = gtkFallbackReader
        gtkReader.path = ""
        gtkReader.path = Paths.configHome + "/gtk-3.0/settings.ini"
        if (!gtkReader.waitForJob()) return
        // Shared GtkSettings reader: one INI contract for every fallback.
        const txt = gtkReader.text()
        const t = GtkSettings.cursorThemeOf(txt, "")
        const n = GtkSettings.cursorSizeOf(txt, -1)
        root.applyCurrent(t !== "" ? t : null, n >= 0 ? n : null)
    }

    FileView {
        id: gtkFallbackReader
        printErrors: false
    }

    FileView {
        id: stateFile
        path: Paths.vibraniumState + "/cursor-theme.json"
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: root._readStateFile()
    }

    // --- efficient theme scanning: one vb-cursor-list --pairs, cached ---
    Process {
        id: themeScanProc
        stdout: StdioCollector { id: themeScanOut }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            root._loading = false
            if (code !== 0) {
                return
            }
            const txt = themeScanOut.text
            const lines = txt.split("\n")
            const out = []
            for (let i = 0; i < lines.length; i++) {
                let line = lines[i]
                if (!line || line.trim() === "") continue
                const tab = line.indexOf("\t")
                if (tab >= 0) {
                    const folder = line.substring(0, tab).trim()
                    const pretty = line.substring(tab + 1).trim()
                    if (folder === "") continue
                    out.push({ folder: folder, pretty: pretty !== "" ? pretty : folder })
                } else {
                    line = line.trim()
                    if (!line) continue
                    out.push({ folder: line, pretty: line })
                }
            }
            if (out.length === 0) return
            root._themes = out
            if (typeof MiscSettings !== "undefined" && MiscSettings.updateThemeOptions) {
                MiscSettings.updateThemeOptions(out)
            }
        }
    }

    // The theme shelf is external state: a theme installed mid-session
    // joins only through a fresh scan, so opening the picker always
    // rescans while background pushes reuse the cache.
    function _ensureThemes(force) {
        if (root._themes !== null && force !== true) {
            if (typeof MiscSettings !== "undefined" && MiscSettings.updateThemeOptions) {
                MiscSettings.updateThemeOptions(root._themes)
            }
            return
        }
        if (root._loading) return
        root._loading = true
        themeScanProc.command = [Paths.vibraniumHome + "/bin/vb-cursor-list", "--pairs"]
        themeScanProc.running = true
    }

    Process {
        id: sizeScanProc
        stdout: StdioCollector { id: sizeOut }
        stderr: StdioCollector {}
        property string _theme: ""
        // Process-restart race: _ensureSizes stops this shared Process to
        // retarget --size. The killed run still emits onExited; this flag
        // consumes that one answer so it cannot publish the new run's sizes.
        property bool _replacePending: false
        property int _scanGen: -1
        onExited: (code, status) => {
            if (sizeScanProc._replacePending) {
                sizeScanProc._replacePending = false
                return
            }
            if (sizeScanProc._scanGen !== root._scanGen) return
            const theme = sizeScanProc._theme
            if (theme === "" || String(theme) !== String(root._currentTheme)) return
            if (code !== 0) {
                root._sizeCache[theme] = [24]
                root._updateSizeOptions(theme, [24])
                return
            }
            const txt = sizeOut.text.trim()
            const parts = txt.split(/\s+/)
            if (parts[0] !== theme) return
            const sizes = []
            for (let i = 1; i < parts.length; i++) {
                const n = parseInt(parts[i], 10)
                if (!isNaN(n)) sizes.push(n)
            }
            if (sizes.length === 0) sizes.push(24)
            root._sizeCache[theme] = sizes
            root._updateSizeOptions(theme, sizes)
        }
    }
    function _ensureSizes(theme) {
        const scanTheme = String(theme)
        if (root._sizeCache[scanTheme] !== undefined) {
            root._updateSizeOptions(scanTheme, root._sizeCache[scanTheme])
            return
        }
        const wasRunning = sizeScanProc.running
        root._scanGen++
        sizeScanProc._scanGen = root._scanGen
        sizeScanProc._theme = scanTheme
        sizeScanProc._replacePending = wasRunning
        if (wasRunning) sizeScanProc.running = false
        sizeScanProc.command = [Paths.vibraniumHome + "/bin/vb-cursor-list", "--size", scanTheme]
        sizeScanProc.running = true
    }
    function _updateSizeOptions(theme, sizes) {
        if (String(theme) !== String(root._currentTheme)) return
        if (typeof MiscSettings !== "undefined" && MiscSettings.updateSizeOptions) {
            MiscSettings.updateSizeOptions(sizes, theme)
        }
        if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) {
        }
    }
    Timer {
        interval: 1200
        running: true
        repeat: false
        onTriggered: {
            root._ensureThemes()
            root._ensureSizes(root._currentTheme)
        }
    }

    function _pushToMisc() {
        if (root._themes && typeof MiscSettings !== "undefined" && MiscSettings.updateThemeOptions) {
            MiscSettings.updateThemeOptions(root._themes)
        }
        const theme = root._currentTheme
        const curSizes = root._sizeCache[theme]
        if (curSizes && typeof MiscSettings !== "undefined" && MiscSettings.updateSizeOptions) {
            MiscSettings.updateSizeOptions(curSizes, theme)
        }
    }

    function open() {
        root._ensureThemes(true)
        root._ensureSizes(root._currentTheme)
        if (typeof MiscSettings !== "undefined") root._pushToMisc()
        if (Menu.open) {
            if (Menu.frame && Menu.frame.id === "general") return "ok"
            Menu.push("general")
        } else {
            Menu.openFile(Paths.settingsBundlePath)
            Qt.callLater(() => Menu.push("general"))
        }
        return "ok"
    }
    function close() { return "ok" }
    function toggle() { return root.open() }

    function setTheme(theme) {
        if (typeof MiscSettings !== "undefined" && MiscSettings.setOption) {
            return MiscSettings.setOption("misc.cursorTheme", theme) ? "ok" : "error"
        }
        const proc = setProc.createObject(root, { command: ["vb-cursor-set", theme] })
        proc.exited.connect(() => { root._readStateFile(); proc.destroy() })
        proc.running = true
        return "ok"
    }
    function setSize(size) {
        const n = parseInt(size, 10)
        if (isNaN(n)) return "error"
        if (typeof MiscSettings !== "undefined" && MiscSettings.setOption) {
            return MiscSettings.setOption("misc.cursorSize", n) ? "ok" : "error"
        }
        const proc = setProc.createObject(root, { command: ["vb-cursor-set", "--size", String(n)] })
        proc.exited.connect(() => { root._readStateFile(); proc.destroy() })
        proc.running = true
        return "ok"
    }

    // One process template for both one-shot setters: each createObject is
    // its own Process, and only its exit notification matters.
    Component {
        id: setProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }

    IpcHandler {
        target: "cursorPicker"
        function help(command: string): string {
          return UnitIpc.help("cursorPicker", "Cursor picker", "cursor theme selection", [
            { name: "close", help: "hide the picker" },
            { name: "open", help: "show the picker" },
            { name: "setSize", help: "(value) set cursor size" },
            { name: "setTheme", help: "(value) set cursor theme" },
            { name: "toggle", help: "show/hide" },
          ], command)
        }
        function ping(): string { return "pong" }
        function open(): string { return root.open() }
        function close(): string { return root.close() }
        function toggle(): string { return root.toggle() }
        function setTheme(theme: string): string { return root.setTheme(theme) }
        function setSize(size: string): string { return root.setSize(size) }
        function status(): string { return JSON.stringify({ theme: root._currentTheme, size: root._currentSize, themes: root._themes ? root._themes.length : 0 }) }
    }
}

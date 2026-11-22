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
import "../text/StringUtils.js" as SU

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

    // Resolved values, sharded by key so a one-key write does not re-evaluate
    // every reader of the store.
    //
    // A binding captures every property its expression reads. A value(key)
    // that reads only `values` replaces the whole map on a one-key write and
    // re-evaluates all ~64 value readers - measured at 30ms of synchronous
    // UI-thread stall before the menu hears the toggle. That is O(readers) per
    // write, the wrong shape for a keyed lookup.
    //
    // The map is split eight ways and value() reads only the shard its key
    // hashes to: a write replaces one shard and re-evaluates roughly an eighth
    // of the readers. The shards must be eight SEPARATE properties - an indexed
    // read into one `var` array captures the whole array and every shard would
    // invalidate together, which is the cost this split removes.
    //
    // Hash collisions cost a little redundant work and can never miss an
    // update, which is the right way round for an invalidation scheme.
    property var _shard0: ({})

    property var _shard1: ({})

    property var _shard2: ({})

    property var _shard3: ({})

    property var _shard4: ({})

    property var _shard5: ({})

    property var _shard6: ({})

    property var _shard7: ({})

    // The whole map, for the few readers that iterate it (dump, conditionsMet,
    // menuPages). Derived from the shards, so the shards stay the single source
    // of truth and this cannot drift from them. It notifies whenever any shard
    // does, which is what whole-store readers need.
    readonly property var values: {
      const m = {}
      for (const k in root._shard0) m[k] = root._shard0[k]
      for (const k in root._shard1) m[k] = root._shard1[k]
      for (const k in root._shard2) m[k] = root._shard2[k]
      for (const k in root._shard3) m[k] = root._shard3[k]
      for (const k in root._shard4) m[k] = root._shard4[k]
      for (const k in root._shard5) m[k] = root._shard5[k]
      for (const k in root._shard6) m[k] = root._shard6[k]
      for (const k in root._shard7) m[k] = root._shard7[k]
      return m
    }

    // key -> shard index. The hash walks every character of the key and the
    // keys are catalog literals, so the mapping is a pure function of a string
    // that never changes; computing it again on every binding re-evaluation
    // would be wasted work. Mutated in place, not published: this is a lookup
    // table, not state a binding observes.
    property var _shardMemo: Object.create(null)

    function _shardOf(key) {
      const s = String(key)
      const hit = root._shardMemo[s]
      if (hit !== undefined) return hit
      let h = 0
      for (let i = 0; i < s.length; i++)
        h = (h * 31 + s.charCodeAt(i)) & 7
      root._shardMemo[s] = h
      return h
    }

    // Reading the shard a key lives in is what a caller's binding ends up
    // depending on - no separate touch is needed, because the read that
    // fetches the value is the dependency.
    function _shardOfMap(key) {
      const s = root._shardOf(key)
      if (s === 0) return root._shard0
      if (s === 1) return root._shard1
      if (s === 2) return root._shard2
      if (s === 3) return root._shard3
      if (s === 4) return root._shard4
      if (s === 5) return root._shard5
      if (s === 6) return root._shard6
      return root._shard7
    }

    function _putShard(key, v) {
      const s = root._shardOf(key)
      const m = Object.assign({}, root._shardOfMap(key))
      m[key] = v
      if (s === 0) root._shard0 = m
      else if (s === 1) root._shard1 = m
      else if (s === 2) root._shard2 = m
      else if (s === 3) root._shard3 = m
      else if (s === 4) root._shard4 = m
      else if (s === 5) root._shard5 = m
      else if (s === 6) root._shard6 = m
      else root._shard7 = m
    }

    function _replaceAllShards(map) {
      const s = [ {}, {}, {}, {}, {}, {}, {}, {} ]
      for (const k in map) s[root._shardOf(k)][k] = map[k]
      root._shard0 = s[0]
      root._shard1 = s[1]
      root._shard2 = s[2]
      root._shard3 = s[3]
      root._shard4 = s[4]
      root._shard5 = s[5]
      root._shard6 = s[6]
      root._shard7 = s[7]
    }

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
        // Reads the key's shard, NOT `values`: that read is the dependency the
        // caller's binding takes, and it is narrow on purpose - see the note on
        // _shard0. Reading `rev` here would re-evaluate every value reader on
        // every write and undo the split.
        return root._shardOfMap(key)[key]
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
        // One key changes, so one shard is replaced. The derived `values`
        // follows; nothing here rebuilds the whole map for the readers that
        // iterate it.
        root._putShard(key, v)
        root.rev++
        const written = Object.assign({}, root._writtenKeys)
        written[key] = true
        root._writtenKeys = written
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
        // Shared read + parse with Settings and MiscSettings (see
        // SettingsCatalog): this store only keeps the hypr.* pages, so a
        // second pass over the same ~5k lines bought nothing.
        const catalog = SettingsCatalog.load()
        if (!catalog) {
            Log.error("hyprlandSettings: " + SettingsCatalog.error)
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

        // Seed values from defaults. A schema load moves every key, so this is
        // the rare path that replaces all eight shards.
        const init = {}
        for (const k in byKey) init[k] = byKey[k].default
        root._replaceAllShards(init)
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

    // `cache` is an optional per-pass map: the live fetch falls back to disk
    // per option, and every option in one file would otherwise re-read that
    // whole file through a blocking read of its own.
    function _readFileContent(expandedPath, cache) {
        if (cache !== undefined && cache[expandedPath] !== undefined) return cache[expandedPath]
        reader.path = ""
        reader.path = expandedPath
        const text = reader.waitForJob() ? reader.text() : ""
        if (cache !== undefined) cache[expandedPath] = text
        return text
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
        // smartGaps key is hypr.general.smart_gaps if present. This probe is
        // the one write path for the key: it writes a shard and emits the rev
        // and change signals itself, so the file view does not bump rev beside
        // it. A watch echo of an unchanged file is a no-op rather than a
        // spurious invalidation.
        const key = "hypr.general.smart_gaps"
        if (root._byKey[key] !== undefined && root._shardOfMap(key)[key] !== enabled) {
            root._putShard(key, enabled)
            root.rev++
            root.optionChanged(key, enabled)
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
    // One catalog parse feeds Settings and the menu builder. A dynamic enum
    // must publish a fresh record through this store's index and schema;
    // editing the shared catalog object would change every reader of it.
    function _republishOption(key, old, next) {
        const byKey = Object.assign({}, root._byKey)
        byKey[key] = next
        root._byKey = byKey
        const schema = root._schema
        if (!schema) return
        const schemaByKey = Object.assign({}, schema.byKey || {})
        schemaByKey[key] = next
        const secs = schema.sections || []
        const sections = []
        for (let i = 0; i < secs.length; i++) {
            const sec = secs[i]
            if (Array.isArray(sec.options) && sec.options.indexOf(old) >= 0) {
                const options = sec.options.slice()
                options[options.indexOf(old)] = next
                sections.push(Object.assign({}, sec, { options: options }))
            } else sections.push(sec)
        }
        root._schema = Object.assign({}, schema, {
            sections: sections, pages: sections, byKey: schemaByKey,
        })
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
        root._republishOption(key, opt, Object.assign({}, opt, {
            values: names.concat(extra),
            valueLabels: labels,
        }))
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

    // The symlink write is a three-leg chain (test -L -> mv -> ln). Its paths
    // belong to the pick that started the chain, not to a later pick: two
    // global pending slots would let the older chain back up the newer target
    // or point the newer source at it. One chain runs at a time and a newer
    // pick collapses into a single follow-up started when the chain finishes.
    property int _presetGen: 0
    property var _presetQueued: null

    function _drainPresetQueue() {
        if (root._presetQueued === null) return
        const next = root._presetQueued
        root._presetQueued = null
        root._writeAnimPreset(next)
    }

    // Backup check for anim preset - pure QML, no bash
    FileView { id: animProbe; printErrors: false }
    Process {
        id: animTestLProc
        property int presetGen: 0
        property string presetSrc: ""
        property string presetTarget: ""
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (animTestLProc.presetGen !== root._presetGen) return
            const src = animTestLProc.presetSrc
            const target = animTestLProc.presetTarget
            if (code === 0) {
                lnProc.presetGen = animTestLProc.presetGen
                lnProc.presetSrc = src
                lnProc.presetTarget = target
                lnProc.command = ["ln", "-sf", src, target]
                lnProc.running = true
                root._reloadHyprland()
            } else {
                animProbe.path = ""
                animProbe.path = target + ".bak"
                const bakExists = animProbe.waitForJob()
                let bakPath = target + ".bak"
                if (bakExists) bakPath = target + ".bak." + Math.floor(Date.now()/1000)
                animMvProc.presetGen = animTestLProc.presetGen
                animMvProc.presetSrc = src
                animMvProc.presetTarget = target
                animMvProc.command = ["mv", target, bakPath]
                animMvProc.running = true
            }
        }
    }
    Process {
        id: animMvProc
        property int presetGen: 0
        property string presetSrc: ""
        property string presetTarget: ""
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (animMvProc.presetGen !== root._presetGen) return
            const src = animMvProc.presetSrc
            const target = animMvProc.presetTarget
            lnProc.presetGen = animMvProc.presetGen
            lnProc.presetSrc = src
            lnProc.presetTarget = target
            lnProc.command = ["ln", "-sf", src, target]
            lnProc.running = true
            root._reloadHyprland()
        }
    }

    function _writeAnimPreset(preset) {
        if (animTestLProc.running || animMvProc.running || lnProc.running) {
            root._presetQueued = String(preset)
            return true
        }
        const gen = ++root._presetGen
        const vibraniumHome = Paths.vibraniumHome !== "" ? Paths.vibraniumHome : root._expandFile("$VIBRANIUM")
        const configHome = Paths.configHome
        const targetFile = root._expandFile("$XDG_CONFIG_HOME/hypr/hyprland.conf.d/animations.lua")
        const defaultFolder = vibraniumHome + "/default/hypr/animations"
        const customFolder = configHome + "/hypr/animations"
        // A preset present on the user's shelf wins over the bundled copy;
        // everything else resolves to the bundled file.
        const sourceFolder = root._animCustomNames.indexOf(preset) >= 0 ? customFolder : defaultFolder
        const src = SU.joinPath(sourceFolder, preset + ".lua")
        // Pure check: does target exist and is not a symlink?
        animProbe.path = ""
        animProbe.path = targetFile
        const exists = animProbe.waitForJob()
        if (exists) {
            // Check if it's a symlink via test -L. The paths travel with the
            // process so the exit handlers cannot borrow a newer pick's.
            animTestLProc.presetGen = gen
            animTestLProc.presetSrc = src
            animTestLProc.presetTarget = targetFile
            animTestLProc.command = ["test", "-L", targetFile]
            animTestLProc.running = true
            // Next steps handled in animTestLProc.onExited
            return true
        }
        // No existing file - just symlink directly (no backup needed)
        lnProc.presetGen = gen
        lnProc.presetSrc = src
        lnProc.presetTarget = targetFile
        lnProc.command = ["ln", "-sf", src, targetFile]
        lnProc.running = true
        root._reloadHyprland()
        return true
    }

    // One reload per interval, not one per write.
    //
    // A range row commits on every pointer move (Entry.seek -> Menu.setValue ->
    // setOption -> _commitHypr) and a held +/- key commits on every key repeat
    // (Entry.stepBy), so a commit must not spawn `hyprctl reload config-only`
    // immediately: measured at 8.6ms of process per call here, plus a full
    // compositor config reload. The file writes stay immediate - one read plus
    // one atomic write, 0.02ms - and only the reload coalesces.
    //
    // It coalesces as a leading-edge throttle with a trailing flush: the first
    // change of a burst reloads at once, changes inside the interval collapse
    // into the next tick, and the last value always lands. A pure trailing
    // debounce restarted on every write, which is exactly what a held key
    // produces, so nothing reached the compositor until the key came up and the
    // gaps only moved after the press ended.
    property bool _reloadDirty: false

    function _reloadHyprland() {
        root._reloadDirty = true
        if (!reloadTimer.running) root._flushReloads()
    }

    // The reload owed since the last tick, plus the interval that rate-limits
    // the next one.
    function _flushReloads() {
        if (!root._reloadDirty) return
        root._reloadDirty = false
        root._reloadNow()
        reloadTimer.restart()
    }

    function _reloadNow() {
        if (reloadProc.running) {
            root._reloadPending = true
            return
        }
        root._reloadPending = false
        reloadProc.command = ["hyprctl", "-q", "reload", "config-only"]
        reloadProc.running = true
    }

    property bool _reloadPending: false

    // Keys this store has written whose own reload has not landed yet. Until
    // it does, the compositor still answers with the value the write
    // replaced, and a fetch in that window republishes it: the row flips back
    // for a turn, and every row gated on that key re-answers from a value the
    // user has already replaced. On the page that owns the motion switch that
    // reversal is also the one that reads the old policy, so a fade runs with
    // animations just switched off. The write owns these keys until the
    // reload carrying it finishes.
    property var _writtenKeys: ({})

    Timer {
        id: reloadTimer
        interval: 80
        repeat: false
        onTriggered: root._flushReloads()
    }

    Process {
        id: reloadProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: {
            // The reload carrying the pending writes has landed, so the
            // compositor is the truth for those keys again - and the last
            // fetch answered before it, so ask again rather than only opening
            // the gate.
            if (Object.keys(root._writtenKeys).length > 0) {
                root._writtenKeys = ({})
                root._fetchLive()
            }
            if (root._reloadPending) root._reloadNow()
        }
    }

    // --- live fetch via hyprctl ---
    //
    // Config reloads, file watches, reload completion and IPC can all ask for
    // a fetch at once. One process runs at a time: a request that arrives
    // while it is in flight arms a single follow-up, started on exit from the
    // then-current catalog. The batch fields travel with the process, so an
    // exit merges under the keys and ctls it was launched with.
    property int _fetchGen: 0
    property bool _fetchQueued: false

    function _drainFetchQueue() {
        if (!root._fetchQueued) return
        root._fetchQueued = false
        root._fetchLive()
    }

    function _fetchLive() {
        if (!root._byKey) return
        if (fetchProc.running) {
            root._fetchQueued = true
            return
        }
        const gen = ++root._fetchGen
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
        fetchProc.batchGen = gen
        fetchProc.batchKeys = keys
        fetchProc.batchCtls = ctls
        fetchProc.batchTypeByCtl = typeByCtl
        fetchProc.command = ["hyprctl", "-j", "--batch", query]
        fetchProc.running = true
    }

    // --- pages for the menu tree ---

    // This store's half of the one menu tree: page descriptors from the same
    // builder Settings uses, cached per generation. No stringify here, no
    // synthetic index page (Settings owns that) and no second normalization
    // on the menu's side - see SL.buildPages and MenuLib.mergePages.
    function menuPages() {
        if (!root._schema || !root.ready) return null
        // One build per store generation: the menu asks on every container
        // load, and this half is the larger part of the catalog.
        if (root._pageCache !== null && root._pageRev === root.rev) return root._pageCache
        root._pageCache = SL.buildPages(root._schema, root.values).pages
        root._pageRev = root.rev
        return root._pageCache
    }

    property var _pageCache: null
    property int _pageRev: -1

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

    // Merge one batch's answer. The keys, ctls and type map are the ones
    // captured when this process was launched, so a later request cannot
    // change the meaning of an answer already in flight.
    function _mergeFetch(code, status, raw) {
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
        const keys = fetchProc.batchKeys
        const ctls = fetchProc.batchCtls
        const typeMap = fetchProc.batchTypeByCtl
        const fileCache = {}
        for (let i = 0; i < keys.length && i < arr.length; i++) {
            const key = keys[i]
            // Still owed its reload: this answer describes the config the
            // write replaced, not the one it wrote.
            if (root._writtenKeys[key] === true) continue
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
                const content = root._readFileContent(file, fileCache)
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
        // One answer may move any key, so all eight shards are replaced.
        root._replaceAllShards(next)
        // A key that fell back to disk is a compositor option hyprctl did not
        // answer - usually `gaps_in`, which hyprctl reports as a CSS string
        // - and it stays correct until something moves.
        root._markReady()
        root.rev++
    }

    Process {
        id: fetchProc
        property int batchGen: 0
        property var batchKeys: []
        property var batchCtls: []
        property var batchTypeByCtl: ({})
        stdout: StdioCollector { id: fetchOut }
        stderr: StdioCollector { id: fetchErr }
        onExited: function(code, status) {
            let raw = ""
            try { raw = fetchOut.text } catch(e) {}
            // An exit from a retired batch is a true-looking answer about a
            // request nobody is waiting for. Refuse it, then start the newest
            // queued batch from a clean set of fields.
            if (fetchProc.batchGen === root._fetchGen)
                root._mergeFetch(code, status, raw)
            root._drainFetchQueue()
        }
    }

    function _fallbackToFiles() {
        const next = Object.assign({}, root.values)
        // One read per file, not one per option: the catalog's options cluster
        // into four lua files, and this path is the hyprctl-less boot.
        const fileCache = {}
        for (const k in root._byKey) {
            const opt = root._byKey[k]
            if (!opt.hypr || opt.hypr.kind !== "option") continue
            const meta = opt.hypr
            const file = root._expandFile(meta.file)
            const content = root._readFileContent(file, fileCache)
            const res = HE.hyprGetContent(content, meta.path, { occurrence: 1 })
            if (res.ok) {
                const check = SL.validateValue(opt, res.value)
                if (check.ok) next[k] = check.value
            }
        }
        root._replaceAllShards(next)
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
                const base = SU.basename(out)
                preset = base.replace(/\.lua$/, "")
            }
            const key = "hypr.animations.preset"
            if (root._byKey[key]) {
                const check = SL.validateValue(root._byKey[key], preset)
                if (check.ok) {
                    root._putShard(key, check.value)
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
        property int presetGen: 0
        property string presetSrc: ""
        property string presetTarget: ""
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (lnProc.presetGen !== root._presetGen) return
            root._drainPresetQueue()
        }
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
        onFileChanged: root._probeSmartGaps()
        onLoaded: root._probeSmartGaps()
    }
    FileView {
        path: Paths.hyprAnimationsFile
        watchChanges: true
        printErrors: false
        onFileChanged: root._probeAnimPreset()
        onLoaded: root._probeAnimPreset()
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

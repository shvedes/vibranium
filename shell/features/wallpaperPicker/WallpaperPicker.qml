pragma Singleton
pragma ComponentBehavior: Bound

// The listing and the removal are registry jobs rather than a raw Process,
// which leaves qmllint unable to infer what a
// Component.createObject call produces; Process.exited and the
// FolderListModel status enum stay valid at runtime, and the same diagnostic
// already stands in the baseline for other createObject sites.
// qmllint disable missing-property
import QtQml
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.common
import qs.features.wallpaper
import "../../common/process/CommandSpec.js" as CommandSpec
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/text/ImageExts.js" as ImageExts

// Efficient user wallpaper picker – clipboard-like two-pane window.
//
// Data source: $XDG_CONFIG_HOME/vibranium/themes/$current_theme/backgrounds
// For community themes (theme dir has .git), only git-untracked files in
// backgrounds/ are user wallpapers (shipped ones are tracked). For
// official themes (no .git), every file is user-provided. The listing is
// fully native, cached, and async.
//
// Efficiency tricks:
// - One FolderListModel per backgrounds dir (Qt's async, watches for changes)
// - Git ls-files as a bounded registry job, only for .git themes, re-run
//   whenever the backgrounds dir changes so drops show up live
// - Filtered list derived via JS, not rescanning FS on every keystroke
// - Preview Image is asynchronous + cached, only current selection loads
// - Delete via one bounded rm job, list mutated in-place, no full rescan
Singleton {
    id: root
    readonly property string tag: "wallpaperPicker"

    property bool visible: false
    readonly property bool isOpen: root.visible

    property string query: ""
    property string currentTheme: ""
    property string backgroundsDir: ""
    property string themeDir: ""

    // Where the listing models' `folder` is spelled, derived from the
    // directories rather than stored, so neither can disagree with the
    // directory it names. Both spell the URL unencoded, which is the form
    // that round-trips through this property: `folder` is a QUrl, and
    // Quickshell hands it to JS via QUrl::toString(), whose default is
    // PrettyDecoded. TolerantMode parsing accepts a literal space and literal
    // non-ASCII in the path, and PrettyDecoded writes both back unescaped, so
    // `String(model.folder)` equals what was written. Measured on this build
    // (Qt 6.11.2, Quickshell 0.3.1) against a directory name holding a space
    // and two non-ASCII bytes, and against the percent-encoded spelling of
    // that same path: the unencoded form reads back byte-for-byte, the encoded
    // form reads back decoded and so would never equal what was written.
    // Percent-encoding belongs on the consumers of the URL, not on a property
    // read back for comparison - see Paths.toFileUrl, used by
    // WallpaperPickerPanel and WallpaperView for exactly that.
    //
    // Two characters in a directory name still break the equality, both
    // because PrettyDecoded re-encodes them: a literal `%` reads back as
    // `%25`, and `"` as `%22`. A `#` or `?` is worse than a mismatch - the
    // parser takes the rest of the name as fragment or query, so the model
    // resolves a directory that does not exist and settles at Null. None of
    // these survive any spelling, since the read-back is QUrl's own
    // formatting of whatever it parsed, so a themes dir carrying one of them
    // lists empty rather than mislisting.
    readonly property string _bgUrl: root.backgroundsDir === ""
      ? "" : "file://" + root.backgroundsDir
    readonly property string _themeUrl: root.themeDir === ""
      ? "" : "file://" + root.themeDir

    // Raw file names (basenames) from FS, before git filtering
    property var _rawFiles: []
    // User wallpapers after git filter (basenames)
    property var _userFiles: []
    // Filtered by query
    property var filtered: []
    property int matchedCount: 0

    // Cache for git untracked set
    property var _gitUntracked: null
    property bool _gitRunning: false
    // Whether the theme dir carries .git (re-derived on every _updateDirs)
    property bool _hasGit: false
    // Whether the cached untracked set is current for this _updateDirs pass;
    // when the folder keeps changing while a git run is in flight this
    // flips back and another run is scheduled.
    property bool _gitFresh: false
    // A git that never answers - absent, wedged, or failing - would otherwise
    // leave the rerun timer arming itself on every directory change and hold
    // the listing slot forever. Attempts are counted per directory and each
    // retry waits longer than the last; the last attempt settles into the
    // degraded state instead of asking again.
    property int _gitAttempts: 0
    property bool _gitDegraded: false
    // A listing answers in milliseconds, so this only bounds a wedged child.
    // The spawn window is what catches an absent git, which reports no exit
    // at all, and the debounce ceiling caps the backoff the retries use.
    readonly property int _gitTimeoutMs: 10000
    readonly property int _gitSpawnMs: 2000
    readonly property int _gitAttemptLimit: 3
    readonly property int _gitRerunMs: 300
    readonly property int _gitRerunMaxMs: 5000

    // --- request identity ---
    // Every asynchronous step here settles after the theme it was issued
    // for can be gone: the .git probe, the listing, the debounced refresh,
    // and each deletion. A RequestGate generation is the identity of that
    // work. Scope is drawn per instance and keys are per operation, so a
    // second picker and a second file never retire each other's requests.
    readonly property string _gateScope: "wallpaperPicker:" + Date.now().toString(36)
      + "-" + Math.floor(Math.random() * 1679616).toString(36)
    readonly property string _probeKey: "gitProbe"
    readonly property string _listKey: "gitList"
    readonly property string _refreshKey: "gitRefresh"
    // Immutable record of the running listing: the handle it must answer to
    // plus the theme and directory its command was built from. The job's
    // callback carries this record, so a reused slot or a replacement run can
    // never report against whatever the picker currently holds.
    property var _gitRun: null
    // Immutable record of the child the reused probe Process is running right
    // now, same shape. The record is bound to that child and is never replaced
    // while a child is in flight, so the exit it reports can only ever answer
    // the command that child carries. Null while the slot is free.
    property var _gitProbe: null
    // A probe issued while a child held the slot, or null. The reused Process
    // runs one child at a time, so this waits for the exit that frees the slot
    // rather than losing its start to a busy slot, which would never run.
    property var _gitProbeQueued: null
    // Queued debounced refresh, or null.
    property var _gitRerun: null
    // Stable code of the last refused path operation, or "".
    property string _refusal: ""
    // Set by the teardown handler, so a job cancelled there - cancelling
    // reports its terminal transition synchronously - cannot write to a
    // singleton that is already going away.
    property bool _closing: false

    // --- owned children ---
    // A removal answers in milliseconds, so its window only bounds a wedged
    // child or an absent rm. Either way the deletion settles as a failure
    // instead of leaving its optimistic row pending forever.
    readonly property int _deleteTimeoutMs: 10000
    readonly property int _deleteSpawnMs: 2000
    // One bounded owner label for every child this module starts, which is
    // what lets teardown stop all of them. A per-file label would not fit the
    // registry's label limit beside the per-instance gate scope.
    readonly property string _jobOwner: "wallpaperPicker"

    // --- path policy ---
    // A theme name and a wallpaper name both become path segments, and a
    // theme name also becomes a git -C argument and an rm target. Names are
    // data: spaces, quotes, and non-ASCII letters are ordinary theme names.
    // A name that could add a segment, climb out of its root, or terminate
    // the string is refused before a path is built from it. The bound is
    // also what keeps a per-file gate key inside RequestGate's label limit.
    readonly property int _nameLimit: 96

    function _nameError(name): string {
        const n = name === undefined || name === null ? "" : String(name)
        if (n === "") return "empty_name"
        if (n.length > root._nameLimit) return "name_too_long"
        if (n.indexOf("\0") >= 0) return "name_nul"
        // Traversal is named before the separator: a name that both
        // escapes and adds segments is reported as the escape it is.
        if (n === "." || n.indexOf("..") >= 0) return "name_traversal"
        if (n.indexOf("/") >= 0) return "name_separator"
        return ""
    }

    // The single path gate: the name must be safe, then the candidate must
    // sit below its root under PathPolicy's lexical check. The verdict is
    // lexical only and never asserts containment - a success carries
    // containment "unverified", because no canonical root exists without
    // the trusted filesystem helper. A caller that needs that guarantee is
    // answered with containment_unavailable and must not act on the path.
    function _checkedPath(name, base, relative, options): var {
        const nameError = root._nameError(name)
        if (nameError !== "") return { ok: false, code: nameError, path: "" }
        const verdict = PathPolicy.check(base, relative, options)
        if (verdict.ok !== true) return { ok: false, code: verdict.code, path: "" }
        return { ok: true, code: verdict.code, path: verdict.path, containment: verdict.containment }
    }

    // The themes root is the capability a theme name is judged against, so
    // every path derived from the active theme resolves through this check.
    function _themePath(theme, relative, options): var {
        return root._checkedPath(theme, Paths.themesUserRoot, relative, options)
    }

    // A refused operation is reported rather than silently skipped: the code
    // names what the policy could not establish.
    function _refuse(code) {
        root._refusal = String(code)
    }

    // The handle current() and invalidate() compare: the generation plus the
    // pair that owns it. A refused generation is reported, never treated as
    // live work.
    function _beginWork(key): var {
        const scope = root._gateScope
        const generation = RequestGate.begin(scope, key)
        if (generation === 0) root._refuse("gate_refused")
        return { id: generation, scope: scope, key: key }
    }

    // Every child this module starts is a registry-owned job. A bare Process
    // that names an executable the system does not have reports no exit at
    // all, so an unbounded child would leave whatever asked it waiting
    // forever; a job owns a spawn watchdog and a deadline, settles through
    // one terminal transition, and carries the exit code and the output with
    // it. A command the spec refuses, or one the registry cannot build, never
    // spawns and reports through the same callback as a failed run, so every
    // caller sees one outcome shape: a result object, or null.
    function _spawn(spec, options, onDone) {
        if (spec === null || spec === undefined || spec.ok !== true) {
            onDone(null)
            return null
        }
        const settings = Object.assign({}, options)
        settings.onFinished = onDone
        settings.onFailed = () => onDone(null)
        let job = null
        try {
            job = ProcessRegistry.start(spec, root._jobOwner, settings)
        } catch (ignored) {
            job = null
        }
        if (job === null) onDone(null)
        return job
    }

    // Success is the whole terminal verdict, not just a zero: a timed out,
    // cancelled or destroyed child never counts as having done its work.
    function _succeeded(result) {
        if (result === null || result === undefined) return false
        return String(result.code) === "ok" && Number(result.exitCode) === 0
          && result.timedOut !== true && result.cancelled !== true
          && result.destroyed !== true
    }

    // The stable refusal code for a child that did not report success. It is
    // derived from the job's own terminal code, so a new terminal state
    // becomes a new code instead of collapsing into a success.
    function _jobCode(result) {
        if (result === null || result === undefined) return "unavailable"
        const code = String(result.code)
        return code === "ok" ? "" : code
    }

    // Image-only gate: backgrounds/ may hold stray non-images (helper
    // scripts like a.sh, READMEs). Only these extensions ever become
    // rows, so the preview Image never tries to open a script.
    // Shared table (ImageExts); compared lowercased so
    // PHOTO.JPG counts (FolderListModel globs would miss that case).
    function _imgOk(name) {
        return ImageExts.ok(name)
    }

    Component.onCompleted: {
      Registry.offer("wallpaperPicker", {
        title: "Wallpaper picker",
        description: "per-theme wallpaper picker",
        verbNames: [
          "close",
          "open",
          "toggle",
          "status",
          "help",
          "ping",
        ]
      })
        Registry.register("wallpaperPicker", root)
        root._readTheme()
        root._watchUnsub = Watch.subscribe(Paths.themeNameFile, (text) => {
          root._readTheme()
        })
    }
    Component.onDestruction: {
        if (root._watchUnsub) root._watchUnsub()
        Registry.unregister("wallpaperPicker")
        // The closing flag comes first: cancelling a child reports its
        // terminal transition synchronously, and that callback must find a
        // stale module rather than a live one being taken apart.
        root._closing = true
        ProcessRegistry.cancelOwner(root._jobOwner)
    }

    // For panel attachment (mirrors Clipboard pattern, efficient)
    property var _panels: []
    function _attachPanel(p) {
        const n = root._panels.slice()
        n.push(p)
        root._panels = n
    }
    function _detachPanel(p) {
        root._panels = root._panels.filter(x => x !== p)
    }

    // --- theme via Watch governor (trio) ---
    property var _watchUnsub: null
    FileView {
        id: themeReader
        printErrors: false
    }
    function _readTheme() {
        themeReader.path = ""
        themeReader.path = Paths.themeNameFile
        if (!themeReader.waitForJob()) return
        const t = themeReader.text().trim()
        if (t === "" || t === root.currentTheme) {
            if (t !== "" && t !== root.currentTheme) {
                root.currentTheme = t
                root._updateDirs()
            } else if (t === "") {
                // Fallback to first run
                root.currentTheme = ""
                root._updateDirs()
            }
            return
        }
        root.currentTheme = t
        root._updateDirs()
    }
    function _updateDirs() {
        // A theme swap retires the previous directory's work: its probe,
        // its listing, and a queued refresh all belong to a path that is
        // being replaced.
        root._retireGit()
        const theme = String(root.currentTheme)
        // No theme named yet: there is no directory to list, and an absent
        // name is not a refusal.
        if (theme === "") {
            root._clearListing()
            return
        }
        // One segment under the themes root, and nothing else.
        const dir = root._themePath(theme, theme, {
            mode: "read", operation: "theme_dir", leafRelative: true
        })
        if (!dir.ok) {
            root._refuse(dir.code)
            root._clearListing()
            return
        }
        root._refusal = ""
        root.themeDir = dir.path
        root.backgroundsDir = dir.path + "/backgrounds"
        // Invalidate the git snapshot up front: until the fresh one lands,
        // rows render unfiltered instead of against the previous theme's set.
        root._gitUntracked = null
        root._hasGit = false
        root._gitFresh = false
        // A pass over a new directory starts with a full attempt budget: what
        // the replaced directory exhausted says nothing about this one.
        root._gitAttempts = 0
        root._gitDegraded = false
        // FolderListModel will auto-update when path changes
        bgModel.folder = root._bgUrl
        // A new directory is a new listing; the previous one's re-aim budget
        // says nothing about whether this one needs re-aiming.
        root._bgReaims = 0
        // Check for .git. The probe is issued under its own generation, so
        // the answer describes the directory it named.
        root._probeGit(theme, dir.path)
    }

    function _clearListing() {
        root.backgroundsDir = ""
        root.themeDir = ""
        root._rawFiles = []
        root._userFiles = []
        root._recomputeFiltered()
    }

    // One probe against one theme directory. The reused Process runs a single
    // child at a time, so a probe issued while a child is in flight is held as
    // the queued one and starts when that child reports: assigning the command
    // and setting running again while a child is alive starts nothing at all,
    // and the answer would then be the retired child's.
    function _probeGit(theme, dir) {
        const probe = root._beginWork(root._probeKey)
        if (probe.id === 0) return
        const record = Object.freeze({ handle: probe, theme: theme, dir: dir })
        if (root._gitProbe !== null) {
            root._gitProbeQueued = record
            return
        }
        root._startProbe(record)
    }

    // Binds the record to the child this start creates. The command is only
    // assigned with the slot free, so the child and the record it answers
    // cannot drift apart between the assignment and the exit.
    function _startProbe(record) {
        root._gitProbe = record
        gitCheckProc.command = ["test", "-d", record.dir + "/.git"]
        gitCheckProc.running = true
    }

    // The retired child has reported, so the slot is free and a probe that
    // waited for it runs on a later turn: a start issued from inside the exit
    // handler can be a no-op while the child it reports has not yet cleared the
    // slot. The queue holds one record, so a burst of theme swaps still runs
    // one child, and a record retired in the meantime is dropped rather than
    // run.
    function _startQueuedProbe() {
        if (root._closing) return
        const queued = root._gitProbeQueued
        root._gitProbeQueued = null
        if (queued === null) return
        if (root._gitProbe !== null) return
        if (!RequestGate.current(queued.handle)) return
        root._startProbe(queued)
    }

    // Retires the probe, the listing, and any queued refresh. A callback
    // that settles afterwards is a no-op instead of a stale contribution, and
    // the retired probe's child is stopped here at its own ownership site,
    // because the gate holds no resource. The stop is asynchronous, so the
    // child still reports an exit - the generation it answers is the retired
    // one, which is what keeps that exit from answering for the directory that
    // replaced it.
    function _retireGit() {
        RequestGate.invalidateScope(root._gateScope, root._probeKey)
        RequestGate.invalidateScope(root._gateScope, root._listKey)
        if (root._gitProbeQueued !== null) {
            RequestGate.invalidate(root._gitProbeQueued.handle)
            root._gitProbeQueued = null
        }
        if (root._gitRerun !== null) {
            RequestGate.invalidate(root._gitRerun.handle)
            root._gitRerun = null
        }
        if (gitCheckProc.running === true) gitCheckProc.running = false
        gitRerun.stop()
    }

    Process {
        id: gitCheckProc
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        // The record is read before the slot is cleared, so the exit answers
        // the child that produced it and not a probe issued since.
        onExited: (code, status) => {
            const probe = root._gitProbe
            root._gitProbe = null
            if (probe !== null) root._settleProbe(probe, code)
            if (root._gitProbeQueued !== null) Qt.callLater(root._startQueuedProbe)
        }
    }

    // One probe's answer, read from the record its own child carries. A probe
    // of a replaced theme directory says nothing about the current one; its
    // replacement carries its own generation.
    function _settleProbe(probe, code) {
        if (!RequestGate.current(probe.handle)) return
        if (probe.theme !== root.currentTheme || probe.dir !== root.themeDir) return
        const hasGit = code === 0
        root._hasGit = hasGit
        if (hasGit) {
            root._gitUntracked = null
            root._runGitLs()
        } else {
            // No git - every file is user file
            root._gitUntracked = null
            root._gitFresh = true
            root._applyGitFilter()
        }
    }

    // Git themes only: refresh the untracked set. A drop landing mid-run
    // queues another (debounced) instead of trusting the pending - already
    // stale - snapshot.
    function _runGitLs() {
        if (!root._hasGit || root.backgroundsDir === "") return
        // A pass that spent its attempts is not asked again by a directory
        // change: re-arming it is an explicit act - a theme swap or a fresh
        // open - not a side effect of a file landing.
        if (root._gitDegraded) return
        const theme = String(root.currentTheme)
        // The directory handed to git is the one the theme name authorizes,
        // and it is recorded with the generation so a run answers only the
        // listing it was started for.
        const dir = root._themePath(theme, theme, {
            mode: "read", operation: "git_list", leafRelative: true
        })
        if (!dir.ok) {
            root._refuse(dir.code)
            return
        }
        root._refusal = ""
        if (root._gitRunning) {
            root._queueGitRefresh(dir.path, root._gitAttempts + 1)
            return
        }
        const handle = root._beginWork(root._listKey)
        if (handle.id === 0) return
        const run = Object.freeze({ handle: handle, theme: theme, dir: dir.path })
        root._gitRun = run
        root._gitRunning = true
        // The theme name reaches git as a -C argument and the pathspec follows
        // `--`, so it stays data: the policy above named the only directory
        // this command may read.
        root._spawn(
            CommandSpec.argv(["git", "-C", run.dir, "ls-files", "--others", "--exclude-standard", "-z", "--", "backgrounds"]),
            { timeoutMs: root._gitTimeoutMs, spawnWatchdogMs: root._gitSpawnMs },
            (result) => root._onGitLsDone(run, result)
        )
    }

    // A dir change during a run becomes one debounced refresh for the
    // directory it was observed in. The queued record carries its own
    // generation, so a burst of drops collapses into the last one and a
    // refresh queued for a replaced directory is retired with it. The wait
    // doubles once per attempt that already failed, capped, so a retry of an
    // unanswered listing backs off instead of polling at a fixed rate.
    function _queueGitRefresh(dir, attempt) {
        const handle = root._beginWork(root._refreshKey)
        if (handle.id === 0) return
        root._gitRerun = { handle: handle, dir: dir }
        gitRerun.interval = root._gitDelay(attempt)
        gitRerun.restart()
    }
    function _gitDelay(attempt) {
        const rounds = attempt > 1 ? attempt - 1 : 0
        return Math.min(root._gitRerunMaxMs, root._gitRerunMs * Math.pow(2, rounds))
    }

    // A queued refresh for the directory the next run covers is retired:
    // that run already answers it, and leaving the timer armed would list
    // the same directory twice.
    function _absorbGitRefresh(dir) {
        const queued = root._gitRerun
        if (queued === null || queued.dir !== dir) return
        root._gitRerun = null
        RequestGate.invalidate(queued.handle)
        gitRerun.stop()
    }

    Timer {
        id: gitRerun
        interval: 300
        onTriggered: {
            const queued = root._gitRerun
            root._gitRerun = null
            if (queued === null) return
            if (!RequestGate.current(queued.handle)) return
            if (queued.dir !== root.themeDir) return
            root._runGitLs()
        }
    }

    // Terminal verdict of one listing. A retired run must not filter the
    // directory that replaced it, and a run whose generation is gone must not
    // answer for a command it was not started with. Either way the freed slot
    // is filled by the listing for the current theme, which absorbs a queued
    // refresh for the same directory. Teardown retires the children with the
    // closing flag already set, because cancelling one reports here
    // synchronously.
    function _onGitLsDone(run, result) {
        if (root._closing) return
        root._gitRunning = false
        root._gitRun = null
        if (run === null) return
        if (!RequestGate.current(run.handle) || run.theme !== root.currentTheme || run.dir !== root.themeDir) {
            root._absorbGitRefresh(run.dir)
            root._runGitLs()
            return
        }
        if (!root._succeeded(result)) {
            root._failGitList()
            return
        }
        const raw = String(result.stdout === undefined ? "" : result.stdout)
        // -z splits on \0
        const parts = raw.split("\0")
        const set = {}
        for (let i = 0; i < parts.length; i++) {
            let p = parts[i].trim()
            if (p === "") continue
            // git returns "backgrounds/foo.jpg" – strip prefix
            if (p.startsWith("backgrounds/")) p = p.slice("backgrounds/".length)
            set[p] = true
        }
        root._gitUntracked = set
        root._gitFresh = true
        root._gitAttempts = 0
        root._applyGitFilter()
    }

    // A listing that did not produce a set spends one attempt. While budget
    // remains it is retried through the same debounce timer a directory change
    // uses, so an absent or failing git cannot arm a timer on its own. The
    // last attempt settles into the degraded state instead: no file is offered
    // as a user wallpaper while the untracked set is unknown, and the snapshot
    // is marked fresh so the empty list reads as the answer it is rather than
    // as a listing that has not landed. A fresh open or a theme swap clears
    // the state and the listing runs again.
    function _failGitList() {
        root._gitAttempts = root._gitAttempts + 1
        if (root._gitAttempts < root._gitAttemptLimit) {
            root._queueGitRefresh(root.themeDir, root._gitAttempts)
            return
        }
        root._gitDegraded = true
        if (root._gitRerun !== null) {
            RequestGate.invalidate(root._gitRerun.handle)
            root._gitRerun = null
        }
        gitRerun.stop()
        root._gitUntracked = {}
        root._gitFresh = true
        root._applyGitFilter()
    }

    // Recovery for a pass that exhausted its attempts: the picker re-arms it
    // when it is opened, so a git that was missing or failing at load time
    // gets another bounded budget without a theme swap. Only an open does
    // this, which is what keeps the re-arm out of the directory-change path.
    function _rearmGitList() {
        if (!root._hasGit || root._gitDegraded === false) return
        root._gitDegraded = false
        root._gitAttempts = 0
        root._runGitLs()
    }

    function _applyGitFilter() {
        // _rawFiles contains basenames from FolderListModel
        let out = []
        if (root._gitUntracked === null) {
            // No git – all raw files are user files
            out = root._rawFiles.slice()
        } else {
            // Only untracked are user files
            for (let i = 0; i < root._rawFiles.length; i++) {
                const f = root._rawFiles[i]
                if (root._gitUntracked[f]) out.push(f)
            }
        }
        out.sort()
        root._userFiles = out
        root._recomputeFiltered()
    }

    // --- FolderListModel for backgrounds ---
    FolderListModel {
        id: bgModel
        showDirs: false
        showDotAndDotDot: false
        showFiles: true
        sortField: FolderListModel.Name
        onCountChanged: root._onBgCountChanged()
        onStatusChanged: {
            if (status === FolderListModel.Ready) root._onBgCountChanged()
        }
    }
    function _onBgCountChanged() {
        // Nothing to list until a theme names a directory.
        if (root._bgUrl === "") return
        // A model still aimed elsewhere has not answered for this theme yet.
        if (String(bgModel.folder) !== root._bgUrl) {
            root._reaimBgModel(true)
            return
        }
        if (bgModel.status !== FolderListModel.Ready) return
        const arr = []
        for (let i = 0; i < bgModel.count; i++) {
            const name = bgModel.get(i, "fileName")
            // Image-only: stray non-images (a.sh, READMEs) never become rows.
            if (!name || !root._imgOk(String(name))) continue
            // Every row names the directory it was read from, and that is the
            // only identity a scan carries. A row from anywhere else is a
            // scan that is no longer ours - the model's default listing of the
            // process's working directory, or the theme that was replaced -
            // and `folder` alone cannot tell those apart, because a scan
            // already under way when the folder was re-aimed still publishes
            // under the new URL and reports itself Ready. Adopting such a scan
            // paints wallpapers this theme does not have, and holds them
            // against the next Ready.
            const row = String(bgModel.get(i, "filePath"))
            if (row.lastIndexOf(root.backgroundsDir + "/", 0) !== 0) {
                root._reaimBgModel(true)
                return
            }
            arr.push(String(name))
        }
        root._rawFiles = arr
        // A dir change invalidates the git snapshot (drops land here while
        // the shell is up). Render immediately - against the current set,
        // unfiltered when none exists yet - then refresh the set; its exit
        // re-applies the filter with the fresh result.
        root._runGitLs()
        root._applyGitFilter()
    }

    // How many times one directory assignment may react to a scan that
    // described some other directory. A re-aim forces a fresh scan, and a
    // model that keeps answering with a directory this theme does not name
    // must not be able to spin forever. The budget is per assignment, not per
    // session, so a theme swap starts over rather than inheriting a spent one.
    readonly property int _bgReaimLimit: 3
    property int _bgReaims: 0

    // Point the model at this theme's backgrounds and start a scan that
    // belongs to it. Blanking the folder first is what makes the assignment
    // take effect at all: re-aiming at a URL the model already holds is a
    // no-op, and the scan that produced the foreign rows would survive it.
    //
    // Whatever the model was showing is dropped on the way, because a re-aim
    // is a statement that the previous answer described a different
    // directory.
    //
    // `capped` is true only for the automatic reaction to a bad scan, which
    // can arrive on its own and is therefore bounded. When a bounded re-aim
    // finds the budget spent the listing simply stays empty: an empty answer
    // claims no wallpaper the theme does not have, which is the only claim
    // this module is willing to make while the scan is untrustworthy. A
    // summon passes false and is never capped, because the directory it is
    // waiting for is created by the very action the user is about to take -
    // spending the budget there would leave the picker deaf to the first
    // wallpaper set after a few previews.
    function _reaimBgModel(capped) {
        root._rawFiles = []
        root._applyGitFilter()
        if (capped === true) {
            if (root._bgReaims >= root._bgReaimLimit) return
            root._bgReaims = root._bgReaims + 1
        }
        bgModel.folder = ""
        bgModel.folder = root._bgUrl
    }

    // --- filtering ---
    function submit(text) {
        root.query = String(text || "").trim()
        root._recomputeFiltered()
    }
    function clearQuery() {
        if (root.query !== "") {
            root.query = ""
            root._recomputeFiltered()
            return true
        }
        return false
    }
    function _recomputeFiltered() {
        const q = root.query.toLowerCase().trim()
        if (q === "") {
            root.filtered = root._userFiles.map(f => ({ label: f, value: f }))
            root.matchedCount = root.filtered.length
            return
        }
        const out = []
        for (let i = 0; i < root._userFiles.length; i++) {
            const f = root._userFiles[i]
            if (f.toLowerCase().indexOf(q) >= 0) out.push({ label: f, value: f })
        }
        root.filtered = out
        root.matchedCount = out.length
        // Per keystroke, like the vault search, so DEBUG and gated: the
        // query and the match count are the pair that explains a filter
        // that looks like it missed something.
    }

    // --- IPC / visibility ---
    function open() {
        if (root.visible) return "ok"
        // Re-read the dir before showing so freshly dropped images are
        // listed on the first summon instead of one theme re-apply later.
        //
        // A Null model is the one that never self-heals, and it is the state
        // `Wallpaper.set` leaves behind: setting a wallpaper into a theme
        // whose backgrounds/ did not exist yet creates that directory and the
        // file together, but a model already pointed at the missing path
        // holds no watcher for it, so the arrival is never noticed. A
        // re-aim is the only way back, and a summon is the right moment for
        // it. The condition is Null rather than "not Ready" because Loading
        // is a scan in flight that resolves on its own, and re-aiming a live
        // scan on every summon is how a user holding the menu key down keeps
        // a directory from ever finishing its listing.
        if (root._bgUrl !== "" && bgModel.status === FolderListModel.Null) {
            root._reaimBgModel(false)
        }
        // A listing that spent its attempt budget is re-armed here, before the
        // scan below, so a summon is the one place a degraded git gets
        // another bounded budget.
        root._rearmGitList()
        root._onBgCountChanged()
        // The empty notification is only trusted once the data is known
        // current: FolderListModel may still be loading, and on git themes
        // the untracked set may still be in flight - both would wrongly
        // report "no wallpapers" for a list about to fill. A live listing
        // counts as in flight here too, because a degraded set is re-armed
        // directly above. An outstanding probe counts as in flight as well,
        // including one queued behind a retiring child, which is not running
        // yet. Git results re-filter async, so the panel updates in place when
        // they land.
        const known = bgModel.status === FolderListModel.Ready
          && !gitCheckProc.running
          && root._gitProbe === null
          && root._gitProbeQueued === null
          && !root._gitRunning
          && (!root._hasGit || root._gitFresh)
        if (known && root._userFiles.length === 0 && root.backgroundsDir !== "") {
            // No wallpapers – notify
            const proc = notifyProc.createObject(root, { command: ["notify-send", "-r", "1", "Vibranium", "No user wallpapers found for current theme"] })
            proc.exited.connect(proc.destroy)
            proc.running = true
            return "ok"
        }
        root.query = ""
        root._recomputeFiltered()
        root.visible = true
        return "ok"
    }
    function close() {
        if (!root.visible) return "ok"
        root.visible = false
        return "ok"
    }
    function toggle() {
        return root.visible ? root.close() : root.open()
    }

    // --- actions ---
    // A selection is the end of the visit: the picker dismisses itself and the
    // menu chain that summoned it goes with it, so the desktop is left showing
    // the wallpaper that was just chosen. Menu.close() unwinds the whole stack
    // rather than one level, which is what "close the chain" means here - the
    // picker is usually summoned from a submenu, and popping a single level
    // would leave the menu sitting on the page it was opened from.
    //
    // A refused path sets nothing, so it dismisses nothing: the picker stays up
    // with its selection and its filter intact, which is the only state the
    // next attempt can be made from. The refusal itself is already recorded
    // where the panel's status verb reads it.
    function setWallpaper(fileName) {
        const name = String(fileName)
        // The wallpaper path is built from the theme name, so the same
        // policy decides it as the deletion path: a name the themes root
        // does not contain never reaches Wallpaper.set.
        const src = root._checkedPath(name, Paths.themesUserRoot, String(root.currentTheme) + "/backgrounds/" + name, {
            mode: "read", operation: "wallpaper_source", allowLeaf: true, allowExisting: true
        })
        if (!src.ok) {
            root._refuse(src.code)
            return
        }
        root._refusal = ""
        Wallpaper.set(src.path)
        root.dismiss()
    }

    // The picker and the menu chain are separate overlays with separate
    // lifetimes, so each is asked directly. The menu is a guest here rather
    // than a dependency: a target nothing registered answers null, and the
    // picker still closes.
    function dismiss() {
        root.close()
        Registry.call("menu", "close")
    }
    // Triple-buffered deletion via OptimisticSet (K3)
    property OptimisticSet optimistic: OptimisticSet {}

    function requestDelete(fileName) {
        if (!fileName) return false
        if (root.optimistic.isPending(fileName)) return false
        if (root._userFiles.indexOf(fileName) < 0) return false
        root.optimistic.mark(fileName)
        Idle.run(() => root.commitDelete(fileName), 2)
        return true
    }

    function commitDelete(fileName) {
        if (!root.optimistic.isPending(fileName)) return
        // File vanished between stages - abort safely.
        if (root._userFiles.indexOf(fileName) < 0) { root.finishDelete(fileName); return }
        root.deleteFile(fileName)
    }

    function finishDelete(fileName) {
        root.optimistic.confirm(fileName)
        // Selection repair belongs to the owning panel, after commit.
        for (let i = 0; i < root._panels.length; i++) {
            const p = root._panels[i]
            if (p && typeof p.onDeleteCommitted === "function") p.onDeleteCommitted(fileName)
        }
    }

    // A removal that did not happen leaves the row exactly where it is, so
    // the optimistic entry is cancelled instead of confirmed and the code is
    // reported. Nothing else settles a row whose child never reported, which
    // is what would leave it hidden from the list while still on disk.
    // Every route out of a removal that failed lands here - the two
    // unauthorized mirrors, the refused gate, the failed rm, and the empty
    // theme prune - so one refusal covers a wallpaper the picker promised to
    // remove and did not.
    function _abortDelete(fileName, code) {
        root.optimistic.cancel(fileName)
        root._refuse(code)
    }

    function deleteFile(fileName) {
        if (!fileName) return
        const theme = String(root.currentTheme)
        const name = String(fileName)
        // Both mirrors are authorized before either is removed: the themed
        // copy under the themes root, and the generated copy under the
        // theme state dir. A refused path removes nothing.
        const themed = root._checkedPath(name, Paths.themesUserRoot, theme + "/backgrounds/" + name, {
            mode: "write", operation: "leaf_delete", allowLeaf: true, allowExisting: true
        })
        const mirror = root._checkedPath(name, Paths.themeBackgroundsDir, name, {
            mode: "write", operation: "leaf_delete", leafRelative: true, allowExisting: true
        })
        if (!themed.ok || !mirror.ok) {
            root._abortDelete(name, themed.ok ? mirror.code : themed.code)
            return
        }
        root._refusal = ""
        // One generation per file, so two deletions in flight never retire
        // each other, and the theme it belongs to, so a swap cannot make an
        // old removal edit the new theme's list.
        const handle = root._beginWork("delete:" + name)
        if (handle.id === 0) {
            root._abortDelete(name, "gate_refused")
            return
        }
        const record = Object.freeze({ handle: handle, theme: theme, file: name })
        // Step 1: rm both mirrors. Leaf removal only - no recursive flag, no
        // shell, and both authorized paths travel as arguments after `--`. The
        // job bounds the child, so an absent rm settles as a failure instead
        // of holding the optimistic row pending.
        root._spawn(
            CommandSpec.argv(["rm", "-f", "--", themed.path, mirror.path]),
            { timeoutMs: root._deleteTimeoutMs, spawnWatchdogMs: root._deleteSpawnMs },
            (result) => root._onDeleteDone(record, result)
        )
    }

    // Terminal verdict of one removal. Only a child that reported success
    // takes the row out of the list and announces the commit: a failed, timed
    // out or unanswered rm puts the row back and says why. The marker settles
    // in both cases, including when the theme was swapped underneath the
    // removal, because a marker left set suppresses deleting a same-named file
    // in the theme that replaced it. The theme test still decides whether the
    // list, the announcement, and the prune are touched.
    function _onDeleteDone(record, result) {
        if (root._closing) return
        if (!RequestGate.current(record.handle)) return
        if (!root._succeeded(result)) {
            root._abortDelete(record.file, "delete_" + root._jobCode(result))
            return
        }
        root.optimistic.confirm(record.file)
        if (record.theme !== root.currentTheme) return
        // Update local list without full rescan
        root._rawFiles = root._rawFiles.filter(f => f !== record.file)
        root._applyGitFilter()
        root.finishDelete(record.file)
        // The count, not the basename. This is the "User wallpapers" row in
        // Settings > General, and the file it removed is a picture the user
        // put there; what a reader wants from the line is that one is gone.
        Log.info("deleted user wallpaper, total " + root._userFiles.length)
        // Step 2: check if deleted file was the current wallpaper
        const cur = Wallpaper.current
        const base = cur.split("/").pop()
        if (base === record.file) {
            // The basename comparison is the whole test - `Wallpaper.current`
            // is a path and `record.file` is not, so the strip above is what
            // makes them comparable - and the decision it drives is invisible:
            // the desktop changing under the user because they removed the
            // picture they were looking at is the most surprising thing this
            // file does, and nothing else here says it happened. No
            // summariser on the filename, either: this component never names
            // a wallpaper, and the count above is the whole of what it says.
            Log.debug("deleted user wallpaper: was the applied one, advancing to the next")
            Wallpaper.next()
        }
        // Step 3: check if backgroundsDir empty via bgModel
        Qt.callLater(() => {
            if (!RequestGate.current(record.handle)) return
            if (bgModel.count === 0) {
                themeDirModel.folder = root._themeUrl
                Qt.callLater(() => {
                    if (!RequestGate.current(record.handle)) return
                    if (record.theme !== root.currentTheme) return
                    root._pruneEmptyTheme(record)
                })
            }
        })
    }

    // Removing the emptied theme directory with its last wallpaper needs a
    // recursive removal, and a recursive removal requires a verified
    // canonical root. No helper in the shell provides one, so the policy
    // refuses it with containment_unavailable and the empty theme
    // directory is left in place rather than claimed to be safe. The
    // backgrounds directory itself is one empty directory, so an authorized
    // rmdir still removes it.
    function _pruneEmptyTheme(record) {
        if (themeDirModel.count === 1 && themeDirModel.status === FolderListModel.Ready) {
            root._refuse(root._themePath(record.theme, record.theme, {
                mode: "write", operation: "recursive_delete", leafRelative: true, allowExisting: true
            }).code)
        }
        const empty = root._themePath(record.theme, record.theme + "/backgrounds", {
            mode: "write", operation: "leaf_delete", allowLeaf: true, allowExisting: true
        })
        if (!empty.ok) {
            root._refuse(empty.code)
            return
        }
        const rmdirProc = delProc.createObject(root, { command: ["rmdir", empty.path] })
        rmdirProc.exited.connect(rmdirProc.destroy)
        rmdirProc.running = true
    }
    FolderListModel {
        id: themeDirModel
        showDirs: true
        showDotAndDotDot: false
        showFiles: true
        sortField: FolderListModel.Name
    }
    function openFolder() {
        const dir = root.backgroundsDir
        const proc = folderProc.createObject(root, { command: ["xdg-open", dir] })
        proc.exited.connect(proc.destroy)
        proc.running = true
        root.close()
    }

    Component {
        id: notifyProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
    Component {
        id: delProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
    Component {
        id: folderProc
        Process {
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }

    IpcHandler {
        target: "wallpaperPicker"
        function help(command: string): string {
          return UnitIpc.help("wallpaperPicker", "Wallpaper picker", "per-theme wallpaper picker", [
            { name: "close", help: "hide the picker" },
            { name: "open", help: "show the picker" },
            { name: "toggle", help: "show/hide" },
          ], command)
        }
        function ping(): string { return "pong" }
        function open(): string { return root.open() }
        function close(): string { return root.close() }
        function toggle(): string { return root.toggle() }
        function status(): string { return JSON.stringify({ visible: root.visible, count: root._userFiles.length, filtered: root.filtered.length, theme: root.currentTheme, refused: root._refusal }) }
    }

    WallpaperPickerView {}
}

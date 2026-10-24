pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/process/CommandSpec.js" as CommandSpec
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/text/ImageExts.js" as ImageExts
import "../../common/text/DropPayload.js" as DropPayload

// Pure-wallpaper renderer. The shell owns the *entire* decision stack: the
// cycle, per-theme memory and current pointer live in a native JSON cache
// ($VIBRANIUM_STATE/wallpaper.json), with no external daemon in the
// decision path and no background symlink.
//
// External work is a RequestGate generation plus registry-owned ProcessJobs.
// Each logical operation (set and its copy chain, the cycle listing, a drop
// chain, the realpath probe of a relative argument) is one immutable record
// carrying the generation, the theme, the basename, the source and the argv
// of every step it will run. A callback captures that record and asks
// RequestGate.current() before touching state, so a result that outlives its
// operation is a no-op instead of a race; an operation that is replaced, a
// theme that changes, or teardown retires the generation *before* the child
// is stopped, because cancelling a child reports its terminal transition
// synchronously.
//
// Every command travels as direct argv (CommandSpec.argv), so a path, a
// basename or a URL is data and never source: there is no `bash -c` here.
// PathPolicy decides the two things a lexical pass can prove - a recorded
// pointer stays below $VIBRANIUM_STATE, and a copy or download destination
// stays one inert segment below its directory - and reports the rest
// (symlink escape, TOCTOU, atomic creation) as unverified instead of
// claiming containment it cannot prove.
Singleton {
  id: root

  // Toggled by double-clicking the wallpaper; persisted in settings.json.
  // Gated on Settings.ready so a cold start shows the theme fill first.
  readonly property bool enabled: Settings.ready && Settings.wallpaperEnabled
  // Resolved absolute path of the active wallpaper ("" => plain tint). Bound
  // by views, so updates crossfade automatically via onSourceUrlChanged.
  property string current: ""
  readonly property int fadeMs: MotionPolicy.enabled ? 200 : 0

  readonly property string tag: "wallpaper"

  Connections {
    target: DesktopActions

    // The bar forwards the single uri DropPayload resolved, as one string. An
    // array payload from an older bar is still accepted, so a mixed-version
    // pair degrades to the same handling instead of an invalid payload toast.
    function onWallpaperDrop(uri, screen, error) {
      if (error !== undefined && error !== null && String(error) !== "") {
        root._notify(String(error), true)
        return
      }
      let single = uri
      if (Array.isArray(single)) single = single.length === 1 ? single[0] : ""
      if (typeof single !== "string" || single.trim() === "") {
        root._notify("Drop failed: invalid drop payload", true)
        return
      }
      root.handleDroppedUri(String(single))
    }
  }

  // Bumped to re-roll the mosaic. Every wallpaper event (next, set,
  // theme swap) rerolls so each change yields a fresh pattern; views bind
  // their seed to this plus their own per-screen local randomness.
  property int mosaicRev: 0
  function rerollMosaic() {
    root.mosaicRev += 1
  }

  // ---- wallpaper.json (replaces wallpaper.state + the background symlink) ----
  //   { "<theme>": "<path: relative-to-state or absolute>" }
  // Relative resolves under $VIBRANIUM_STATE; absolute is used verbatim.
  // Persisted WRAPPED as {"data": ...}; flat pre-wrapper files migrate
  // wholesale on load. The adapter suppresses our own write echo: a
  // reload carrying identical content leaves `data` untouched.
  property var _state: ({})
  property string activeTheme: ""
  // Static extensions Qt decodes natively on this install - shared table
  // (ImageExts), same set the picker gates on.
  readonly property var _imageExts: ImageExts.EXTS

  // ---- request identity ----
  // One key per kind of work, not per child: a set and its whole copy chain
  // share the set key, a drop and its whole stat/mkdir/curl/mime chain share
  // the drop key. Identity is therefore the operation, and two operations on
  // different keys never retire each other.
  readonly property string _gateScope: "wallpaper"
  readonly property string _setKey: "set"
  readonly property string _cycleKey: "cycle"
  readonly property string _dropKey: "drop"
  readonly property string _resolveKey: "resolve"

  // Live run per key, holding the mutable bookkeeping only: the child the key
  // currently owns (the chains are strictly sequential, so one reference is
  // the whole list) and the download scratch file the operation still has to
  // remove. The record callbacks capture is frozen and never appears here.
  property var _runs: ({})

  // Cycle requests that arrived while a listing was running. Queued
  // explicitly instead of collapsed into one slot, so N next presses advance
  // N images; bounded so a cycle that never reports cannot grow the list.
  property var _cyclePending: []
  readonly property int _cyclePendingLimit: 8

  // In-flight swap count, reported by the per-screen views (decode plus
  // transition). Rapid next/prev IPC (key spam) is refused while any screen
  // is still switching instead of queueing behind the animation and
  // interrupting it mid-flight. Internal callers (the picker's
  // delete-advance) bypass the gate: that call is correctness, not spam.
  property int _swapActive: 0
  readonly property bool switching: root._swapActive > 0
  function _swapBegin() {
    root._swapActive += 1
  }
  function _swapEnd() {
    if (root._swapActive > 0) root._swapActive -= 1
  }

  // A local filesystem primitive answers in milliseconds, so a window this
  // wide only bounds a wedged mount. The copy window covers a large image on
  // a slow disk, and the download window stays above curl's own
  // connect-timeout + max-time so curl's message wins over the deadline.
  readonly property int _probeTimeoutMs: 5000
  readonly property int _copyTimeoutMs: 60000
  readonly property int _curlTimeoutMs: 45000

  // The handle current()/invalidate() compare: the captured generation
  // together with the pair that owns it.
  function _handle(generation, key) {
    return { id: generation, scope: root._gateScope, key: key }
  }

  // Opens the operation of one key. The previous generation of that key dies
  // with its child and scratch file first, so a callback racing the
  // replacement already sees a stale handle. A refused generation is not a
  // live request, so the caller is refused too instead of running ungated.
  function _open(key, fields) {
    const carried = fields === undefined ? {} : fields
    root._retire(key, "superseded")
    const generation = RequestGate.begin(root._gateScope, key)
    if (generation === 0) return null
    const runs = Object.assign({}, root._runs)
    runs[key] = {
      job: null,
      temp: typeof carried.temp === "string" ? carried.temp : "",
      // The device and inode the filesystem reports for the source and for
      // each destination, and the copy chain planned from them. Both live on
      // the run rather than on the record: the identities are the
      // filesystem's answer and the argv is built from them, so neither is
      // known while the record is opened.
      ids: [],
      steps: null
    }
    root._runs = runs
    return Object.freeze(Object.assign({
      handle: Object.freeze(root._handle(generation, key)),
      key: key
    }, carried))
  }

  // Terminal path of an operation, whatever ended it: the generation dies
  // first, then the child the key still owns is terminated, then the run
  // leaves the table and a download scratch file is removed. The handle has
  // to be gone before the child is stopped, because cancelling a child
  // reports its terminal transition synchronously.
  //
  // Every retirement names its reason, because "the request finished" and
  // "the request was replaced" are the same silence from outside and only
  // one of them is a user action that went nowhere. The reason is handed to
  // the child's cancel, so a retired chain reports which of the two ended it.
  function _retire(key, reason) {
    RequestGate.invalidateScope(root._gateScope, key)
    const run = root._runs[key]
    if (run === undefined) return false
    const job = run.job
    const temp = run.temp
    const next = Object.assign({}, root._runs)
    delete next[key]
    root._runs = next
    root._stopJob(job, reason)
    if (temp !== "") root._cleanupPath(temp)
    return true
  }

  function _live(record) {
    return record !== null && record !== undefined && RequestGate.current(record.handle)
  }

  // Every child is a registry-owned job: exactly one terminal transition, the
  // output in the result, and a deadline that terminates the child instead of
  // leaving it parented. A command the contract refuses, or one the registry
  // cannot build, never spawns and reports through the same callback as a
  // nonzero exit, so a refusal is a failure rather than a silent no-op.
  function _spawn(record, spec, timeoutMs, onResult) {
    if (spec === null || spec === undefined || spec.ok !== true) {
      onResult(null)
      return false
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._gateScope + ":" + record.key, {
        timeoutMs: timeoutMs,
        onFinished: onResult,
        onFailed: () => onResult(null)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      onResult(null)
      return false
    }
    // The refusal callback above can settle the operation synchronously, so
    // currency is re-read before the job is recorded as owned.
    if (!root._live(record)) {
      root._stopJob(job, "stale")
      return false
    }
    const run = root._runs[record.key]
    if (run === undefined) {
      root._stopJob(job, "stale")
      return false
    }
    run.job = job
    return true
  }

  // One child of a chain: the previous child is released first, so a key owns
  // at most one live process and _retire has exactly one thing to terminate.
  function _runChild(record, spec, timeoutMs, onResult) {
    if (!root._live(record)) return
    const run = root._runs[record.key]
    if (run === undefined) return
    run.job = null
    root._spawn(record, spec, timeoutMs, onResult)
  }

  // A settled job owns nothing: the registry released its child and destroys
  // the job itself, so only a live one is cancelled here.
  function _stopJob(job, reason) {
    if (job === null || job === undefined) return
    try {
      if (String(job.state) === "settled") return
    } catch (ignored) {
      return
    }
    try {
      job.cancel(reason)
    } catch (ignored) {
      return
    }
  }

  // Success is the full terminal verdict, not just a zero: a timed out,
  // cancelled or destroyed child never counts as having done its work.
  function _succeeded(result) {
    if (result === null || result === undefined) return false
    return String(result.code) === "ok" && Number(result.exitCode) === 0
      && result.timedOut !== true && result.cancelled !== true
      && result.destroyed !== true
  }

  function basename(p) {
    return p ? p.split("/").pop() : ""
  }

  // A recorded pointer is either state-relative or absolute. Only the
  // relative form is a path this shell can judge: it must resolve below
  // $VIBRANIUM_STATE with no parent escape. An absolute pointer is used
  // verbatim by the file format, and no lexical pass can prove containment
  // for it or for a symlink inside the state tree, so the check covers
  // exactly the case it can prove and reports the rest as unverified.
  function resolvePath(p) {
    if (!p) return ""
    if (p.length && p[0] === "/") return p
    const verdict = PathPolicy.check(Paths.vibraniumState, p, { allowLeaf: true, mode: "read" })
    return verdict.ok === true ? String(verdict.path) : ""
  }

  // Destination leaf of a copy or a download. The candidate is one segment,
  // so the policy can prove that it stays a plain name below its directory
  // and cannot climb out with `..`; "." and ".." are refused outright. The
  // resolved path is returned instead of a joined string so a caller can
  // compare it with what it intended. Containment across a symlinked
  // directory, and the race between the check and the open, stay unverified:
  // QML has no no-follow filesystem primitive and the trusted path helper is
  // not part of the shell module.
  function _destOf(dir, leaf) {
    const verdict = PathPolicy.check(dir, leaf, {
      leafRelative: true,
      allowExisting: true,
      mode: "create"
    })
    return verdict.ok === true ? String(verdict.path) : ""
  }

  // Re-read $VIBRANIUM_STATE/theme.name; on change re-resolve the current.
  // Watch governor delivers the file text (or null if absent).
  function _onThemeNameChanged(text) {
    const t = (text !== undefined && text !== null ? String(text).trim() : "")
    // Fallback to direct read if Watch didn't provide text (e.g., initial call)
    let cur = t
    if (cur === "" && text === undefined) {
      // No text provided - try to read via Watch's last value or skip
      return
    }
    if (cur !== root.activeTheme) {
      root.activeTheme = cur
      // A listing of the previous theme's images is stale the moment the
      // theme changes, and the queued cycles behind it ask for the same
      // decision, so both go: the generation dies first, then the find
      // child, and the fresh reconcile issues a new cycle.
      root._retire(root._cycleKey, "theme_changed")
      root._cyclePending = []
      root._reconcile()
    }
  }

  // Parse wallpaper.json; adopt flat pre-wrapper files wholesale and
  // rewrite wrapped. Runs on every load; adapter echo needs no guard.
  //
  // The state file is the one thing on disk this component watches, and it is
  // NOT the image: a wallpaper edited or replaced in place is invisible here.
  // A text that does not parse is not adopted at all - the adapter's own value
  // stands, so an unparseable pointer memory leaves the surface on whatever
  // the last good load resolved rather than blanking it.
  function _loadJson() {
    let text = ""
    try { text = wallpaperView.text() } catch (e) { text = "" }
    if (text.trim() !== "") {
      let parsed = null
      try { parsed = JSON.parse(text) } catch (e) { parsed = null }
      // The flat pre-wrapper layout, adopted wholesale and written back
      // wrapped. A one-time rewrite of the user's state file.
      if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
        && parsed.data === undefined && Object.keys(parsed).length > 0) {
        stateAdapter.data = parsed
        wallpaperView.writeAdapter()
        return
      }
    }
    root._state = stateAdapter.data
    root._reconcile()
  }

  function saveJson() {
    stateAdapter.data = root._state
    wallpaperView.writeAdapter()
  }

  // Resolve Wallpaper.current for the active theme. Always via an async
  // `find` listing (auto-pick): a recorded pointer is lexical only, so a
  // deleted/renamed file still resolves and would publish a dangling path.
  // The view keeps the previous frame on a load error, which reads as
  // silently keeping the previous theme's wallpaper. The listing proves
  // presence and _onCycleDone falls back to the theme's very first image
  // (files[0]) when the recorded basename is gone.
  function _reconcile() {
    if (root.activeTheme === "") {
      root._publish("", "", "")
      return
    }
    root._startCycle("auto", 0)
  }

  // A cycle request that arrives while a listing runs is queued, never
  // merged into the live record: the two records would then disagree about
  // the mode and the theme they were asked for.
  function _startCycle(mode, offset) {
    if (root._runs[root._cycleKey] !== undefined) {
      if (root._cyclePending.length < root._cyclePendingLimit) {
        root._cyclePending = root._cyclePending.concat([{ mode: mode, offset: offset }])
      }
      return false
    }
    const record = root._open(root._cycleKey, {
      mode: mode,
      offset: offset,
      theme: root.activeTheme
    })
    if (record === null) return false
    root._runChild(record, CommandSpec.argv([
      "find", Paths.themeBackgroundsDir, "-maxdepth", "1", "-xtype", "f"
    ]), root._probeTimeoutMs, (result) => root._onCycleDone(record, result))
    return true
  }

  // Terminal path of one listing. Image-only: backgrounds/ may hold stray
  // non-images (a.sh sorts first alphabetically and would win every
  // auto-pick), so the listing is filtered before choosing. Mirrors the set
  // and drop paths, which already gate on ext.
  //
  // This is the answer to "does it index a directory": it lists one, and it
  // keeps nothing. Every cycle request re-runs `find` and the result is
  // thrown away after one name is chosen from it, so there is no index, no
  // thumbnail cache and no listing cache.
  function _onCycleDone(record, result) {
    if (!root._live(record)) return
    // A failed, timed out or refused listing has no output to choose from,
    // which is the same as an empty directory.
    const raw = root._succeeded(result) ? String(result.stdout || "") : ""
    // The operation is retired before anything visible moves, so a commit
    // cannot be raced by a request that supersedes this one mid-callback.
    root._retire(record.key, "cycle_done")
    const names = raw.split("\n").filter(l => l).map(l => l.split("/").pop())
    const files = names.filter(f => root._extOk(f)).sort()
    // The theme a listing was issued for has to still be the active one;
    // _onThemeNameChanged retires the cycle outright, and this is the cheap
    // invariant that keeps a commit from ever naming another theme.
    if (files.length === 0 || record.theme === "" || record.theme !== root.activeTheme) {
      // A theme with no usable image in its backgrounds directory cannot pick
      // one, and the fallback is a blank tint that looks deliberate. Every
      // other way of producing no output lands here too - an unreadable
      // directory, a `find` that is not there, a wedge the probe timeout
      // caught. This is a fault, not a state: the wallpaper is on and shows
      // nothing.
      root._drainCycle()
      return
    }
    if (record.mode === "auto") {
      const saved = root._state[record.theme]
      const recorded = saved ? root.basename(saved) : ""
      if (recorded !== "" && files.indexOf(recorded) >= 0) {
        // Recorded pointer verified present by the listing: publish it
        // without rewriting state. A write here would echo back through
        // stateAdapter.onDataChanged -> _reconcile -> another auto listing
        // -> another write, forever; the cycle key would never go idle and
        // next/prev requests would starve behind the autos (ctrl+alt+w
        // dead). _publish is idempotent, so re-verifying costs no write.
        const resolved = root.resolvePath(saved)
        if (resolved !== "") root._publish(resolved, recorded)
        else root._commit(record.theme, files[0])
      } else {
        // No recording, or the recording names a file this theme no longer
        // lists (deleted, renamed, or never an image - the listing has just
        // proved it, which the lexical resolvePath could not). Fall back to
        // the theme's very first image. This is the only auto path that
        // writes state.
        root._commit(record.theme, files[0])
      }
    } else {
      // The position this listing holds the outgoing wallpaper at, kept
      // across the fallback below so the discarded fact is reportable rather
      // than lost with the assignment.
      const found = files.indexOf(root.basename(root.current))
      let idx = found
      if (idx < 0) idx = 0
      if (record.mode === "next") idx = (idx + 1) % files.length
      else idx = (idx - 1 + files.length) % files.length
      root._commit(record.theme, files[idx])
      root.rerollMosaic()
      // The direction, where it landed, and the size of the set - and not the
      // file. A wallpaper basename is a user's own file, and this component
      // already treats a theme name as user data reaching a path.
      //
      // The index is here rather than one line down because "which one is it
      // now" is the question a person actually asks after pressing next, and an
      // index answers it without naming the thing it points at. It is also the
      // only way to see a wrap: `0 of 24` after `23 of 24` is the whole report
      // that the arithmetic came back round.
      Log.info("switched wallpaper (" + record.mode + "), "
        + idx + " of " + files.length)
      // How much of the listing the image filter refused. The count the line
      // above reports is what survived it, and one stray non-image in a
      // backgrounds directory is the whole reason a set is smaller than what
      // `find` printed - a difference the count cannot express. Counts, never
      // a name: a candidate the filter rejected is still a wallpaper, and this
      // directory has never named one.
      Log.debug("switched wallpaper (" + record.mode + "): " + files.length
        + " of " + names.length + " listed are images")
      // Whether the wallpaper that was on screen is one this listing knows at
      // all. It is what made the arithmetic start at the edge, and it is what
      // makes next and prev land somewhere the user did not predict after they
      // replaced an image by hand: nothing watches the image, so `current`
      // keeps naming a file the listing no longer holds.
      //
      // `found` and not `idx`. The landing position is the INFO line's job now;
      // this is where the arithmetic STARTED, and the two differ exactly when
      // the outgoing wallpaper was not in the listing - which is the case worth
      // a diagnostic and not the case worth a line every cycle. The verdict and
      // the position, never the basename the comparison was made on.
      Log.debug("switched wallpaper (" + record.mode + "): current "
        + (found < 0 ? "not among them" : "indexed at " + found))
    }
    root._drainCycle()
  }

  function _drainCycle() {
    if (root._cyclePending.length === 0) return
    const next = root._cyclePending[0]
    root._cyclePending = root._cyclePending.slice(1)
    root._startCycle(next.mode, next.offset)
  }

  // Record a background by basename and show it. Fresh object so the
  // adapter change fires; the mirror plus reconcile land through it.
  // Skips the state write when the value already stands: rewriting an
  // identical pointer would echo back through stateAdapter.onDataChanged
  // into another reconcile, and an auto verify would then re-list forever.
  function _commit(theme, base) {
    const rel = "theme/backgrounds/" + base
    if (root._state[theme] !== rel) {
      const next = Object.assign({}, root._state)
      next[theme] = rel
      root._state = next
      root.saveJson()
    }
    // A pointer the policy refuses is still recorded (the file stays the
    // source of truth for every other reader), it just does not publish a
    // current image here: blanking a working wallpaper would be worse.
    root._publish(root.resolvePath(rel), base)
  }

  // The one place `current` is assigned. Two callers reach it that do not go
  // through _commit: a theme swap and a boot both land on the recorded
  // pointer directly, because the pointer is already correct and _commit's
  // job is to write one, not to re-publish it.
  //
  // `label` is the basename, not the path it was reached by.
  //
  // An empty `label` is a cleared wallpaper rather than an unresolvable one,
  // and the two pull opposite ways: nothing to publish leaves `current` alone,
  // while an active theme with no wallpaper takes it away. Only the second is
  // an event, and it is guarded on there being something to clear.
  function _publish(resolved, label) {
    if (label === "") {
      if (root.current === "") return
      root.current = ""
      return
    }
    // Recorded but not applied. The surface keeps whatever it had, so from
    // outside this is indistinguishable from the request never arriving -
    // and the two are the difference between "this theme names no wallpaper"
    // and "this theme names one the policy will not load".
    if (resolved === "") return
    // The request arrived, it resolved to the file already on screen, and
    // nothing moved. That is also the answer to "I replaced the image on
    // disk and the wallpaper did not change": nothing watches the image, so
    // `current` does not move. The refresh verb over IPC is the documented
    // way out, and it reaches exactly here.
    if (resolved === root.current) return
    root.current = resolved
  }

  function next() { root._startCycle("next", 0) }
  function prev() { root._startCycle("prev", 0) }

  // Set an arbitrary image (Thunar / vb-shell / picker). External images are
  // copied into the user-themes dir and the state dir; files already living
  // there are recorded in place (no self-copies).
  function set(path) {
    const raw = (path || "").trim()
    if (!raw) return "error: no path"
    if (!raw.startsWith("/")) return root._resolveArg(raw)
    return root._setAbs(raw)
  }

  // A relative argument is resolved by one realpath child and fed back
  // through the absolute path. The probe records the argument it was issued
  // for, so its output can only ever be applied to that argument, and a
  // replaced probe contributes nothing at all.
  function _resolveArg(raw) {
    const record = root._open(root._resolveKey, { src: raw })
    if (record === null) return "error: busy"
    root._runChild(record, CommandSpec.argv(["realpath", "--", raw]),
      root._probeTimeoutMs, (result) => root._onResolveDone(record, result))
    return "ok"
  }

  function _onResolveDone(record, result) {
    if (!root._live(record)) return
    const abs = root._succeeded(result) ? String(result.stdout || "").trim() : ""
    root._retire(record.key, "resolved")
    // A relative argument that will not resolve: a path that is not there,
    // or one the shell may not read. Nothing is published and the caller
    // is told nothing, so the refusal is silent by design.
    if (abs === "" || abs[0] !== "/") return
    root._setAbs(abs)
  }

  function _setAbs(src, temp, origin, destBase) {
    // A remote download names its destination deterministically (see
    // _handleHttpUrl): the scratch file carries a timestamped leaf, but the
    // recorded basename is the stable one, so dropping one URL twice
    // overwrites one file instead of cluttering backgrounds/ with copies.
    const base = (typeof destBase === "string" && destBase !== "") ? destBase : root.basename(src)
    const ext = base.slice(base.lastIndexOf(".") + 1).toLowerCase()
    if (!root._imageExts[ext]) return "error: unsupported format: ." + ext
    const theme = root.activeTheme
    if (theme === "") return "error: no active theme"
    return root._beginSet(theme, base, src,
      temp === undefined ? "" : temp, origin === undefined ? "set" : origin)
  }

  // One set operation: an immutable record of the theme, the basename it will
  // record, the source it copies from, the scratch file it owns, and the
  // destination the policy authorized for each of the two directories. A
  // second set retires this one instead of overwriting a shared slot, so a
  // running chain can never commit another image's arguments, and neither can
  // publish a pointer for a source it never copied. Which destinations are
  // still owed a copy is deliberately not in the record: that is a question
  // about the files, and only the filesystem can answer it (_runIdentity).
  function _beginSet(theme, base, src, temp, origin) {
    // The theme name is user data reaching a path, so the directory it
    // selects is resolved through the policy too and the resolved form is
    // what mkdir and the copy both use.
    const userDir = root._destOf(Paths.userThemesDir(theme), "backgrounds")
    const stateDest = root._destOf(Paths.themeBackgroundsDir, base)
    const userDest = userDir === "" ? "" : root._destOf(userDir, base)
    if (userDir === "" || stateDest === "" || userDest === "") {
      return "error: unsafe destination"
    }
    // A destination named by the source's own path is already settled: the
    // string test is exact there, and a path never has to be probed against
    // itself. `mkdir` is the directory the destination needs created, empty
    // where none does.
    const copy = []
    if (src !== stateDest) copy.push(Object.freeze({ dest: stateDest, mkdir: "" }))
    if (src !== userDest) copy.push(Object.freeze({ dest: userDest, mkdir: userDir }))
    const record = root._open(root._setKey, {
      theme: theme,
      base: base,
      src: src,
      temp: temp,
      origin: origin,
      userDir: userDir,
      copy: Object.freeze(copy)
    })
    if (record === null) return "error: busy"
    // Both destinations are the source's own path, so there is nothing left to
    // ask the filesystem and the commit can run straight away.
    if (copy.length === 0) { root._planCopy(record); return "ok" }
    root._runIdentity(record, 0)
    return "ok"
  }

  // Whether a destination still owes a copy is not a question about its name.
  // The theme installer hard-links every wallpaper into the state tree (see
  // bin/vb-theme-set), so the source and the state copy are one inode under two
  // paths: the names differ, the file does not, and cp refuses that pair
  // outright. The filesystem alone can say which case this is, so each path is
  // stat-ed for its device and inode and the plan compares those.
  //
  // One path per child, and the format names nothing: a file whose name holds a
  // newline cannot split the answer across lines, and a path that is not there
  // reports no identity instead of shifting the ones after it. Index 0 is the
  // source; the rest are the destinations in plan order, so the chain ends one
  // past the last of them. A local filesystem answers in milliseconds - the
  // shared probe window only bounds a wedged mount.
  function _runIdentity(record, index) {
    if (!root._live(record)) return
    const run = root._runs[record.key]
    if (run === undefined) return
    if (index > record.copy.length) { root._planCopy(record); return }
    const path = index === 0 ? record.src : record.copy[index - 1].dest
    // The name reaches stat as an argument after `--`, never as source, and a
    // spec the contract refuses never spawns and reports as a failed run.
    root._runChild(record, CommandSpec.argv(["stat", "-c", "%d:%i", "--", path]),
      root._probeTimeoutMs, (result) => root._onIdentity(record, index, result))
  }

  // Only a child that reported an identity records one. A path that does not
  // exist, a refused spec, and an unanswered child all leave the slot empty,
  // which is what keeps the copy owed - the plan this operation ran before the
  // probe existed. Verdicts are recorded by index rather than by removing a
  // destination, so a probe that settles late cannot shift the ones still to be
  // asked about.
  function _onIdentity(record, index, result) {
    if (!root._live(record)) return
    const run = root._runs[record.key]
    if (run === undefined) return
    if (root._succeeded(result)) run.ids[index] = String(result.stdout || "").trim()
    root._runIdentity(record, index + 1)
  }

  // The copy chain, now that the identities are known. Binary copy stays on
  // cp/mkdir children: FileView writes text and would corrupt images, and no
  // QML dir primitive exists. A destination already holding the source's own
  // file is recorded in place instead of copied onto itself, so a picker
  // selection on a hard-linked wallpaper copies nothing at all and still
  // commits.
  //
  // An unreadable or absent source leaves index 0 empty, the plan still owes
  // a copy, and the failure arrives a moment later as a bare `cp` exit naming
  // a step rather than a file.
  function _planCopy(record) {
    if (!root._live(record)) return
    const run = root._runs[record.key]
    if (run === undefined) return
    const srcId = run.ids[0]
    const commands = []
    for (let i = 0; i < record.copy.length; i++) {
      // An unknown identity is never equal to the source's, so a failed probe
      // costs a copy rather than a commit over a stale file.
      if (srcId !== "" && run.ids[i + 1] === srcId) continue
      const target = record.copy[i]
      // Only the user themes directory is created here; the state one arrives
      // with the theme that owns it.
      if (target.mkdir !== "") commands.push(["mkdir", "-p", target.mkdir])
      commands.push(["cp", "--", record.src, target.dest])
    }
    const steps = []
    for (let i = 0; i < commands.length; i++) {
      const spec = CommandSpec.argv(commands[i])
      if (spec.ok !== true) {
        root._retire(record.key, "unusable_command")
        root._notify(record.origin === "drop" ? "Drop failed: unusable copy command" : "Wallpaper set failed: unusable copy command", true)
        return
      }
      steps.push(Object.freeze(spec))
    }
    run.steps = Object.freeze(steps)
    root._runCopy(record, 0)
  }

  // One step of the copy chain. Every step's exit code decides: a failed
  // mkdir or cp retires the operation instead of advancing, so a half-copied
  // image can never reach the commit and never publishes a pointer. An empty
  // step list is a source that already lives in both destinations.
  function _runCopy(record, index) {
    if (!root._live(record)) return
    const run = root._runs[record.key]
    if (run === undefined) return
    if (index >= run.steps.length) {
      root._commitSet(record)
      return
    }
    const spec = run.steps[index]
    // The tool name is a literal of the captured argv, not a path.
    const label = String(spec.argv[0])
    root._runChild(record, spec, root._copyTimeoutMs,
      (result) => root._onCopyChild(record, index, label, result))
  }

  function _onCopyChild(record, index, label, result) {
    if (!root._live(record)) return
    if (!root._succeeded(result)) {
      root._failSet(record, label)
      return
    }
    root._runCopy(record, index + 1)
  }

  // The set landed.
  function _commitSet(record) {
    if (!root._live(record)) return
    // Retire first: the generation dies, the chain is empty and the scratch
    // file is gone, all before the pointer is published.
    root._retire(record.key, "committed")
    root._commit(record.theme, record.base)
    root.rerollMosaic()
  }

  // A copy that did not finish leaves no pointer behind, and the scratch file
  // goes with it. The message keeps the drop vocabulary when the source was a
  // download, so both paths read the same to the user. Nothing was applied and
  // no pointer was written, so this is the one set failure the user has to act
  // on. The step is a literal of the captured argv, not a path.
  function _failSet(record, step) {
    if (!root._live(record)) return
    root._retire(record.key, "copy_failed")
    root._notify(record.origin === "drop" ? "Drop failed: " + String(step) + " failed" : "Wallpaper set failed: " + String(step) + " failed", true)
  }

  // ---- drag-and-drop handling ----
  // Hover acceptance is pre-filtered by _dropIsSupported (shared by
  // both DropAreas); the checks below stay authoritative at drop time.
  readonly property int maxDropBytes: 52428800

  // A drop owns a scratch file, a download, a mime probe and a copy, so a
  // second one is refused explicitly instead of racing the first. The busy
  // test reads the live operations themselves, which cannot disagree with
  // the operations the way a separate "in progress" flag can.
  function _busy() {
    return root._runs[root._dropKey] !== undefined || root._runs[root._setKey] !== undefined
  }

  function _notify(msg, isError) {
    const args = isError ? ["notify-send", "-u", "critical", "-r", "1", "-a", "Vibranium", "Desktop Background", msg] : ["notify-send", "-r", "1", "-a", "Vibranium", "Desktop Background", msg]
    // A stateless one-shot: Exec owns the child and destroys it on exit, and
    // no callback reads state back, so there is nothing here to gate.
    Exec.run(args)
  }

  // One toast per refused or failed drop, from one call site. `message` is the
  // wording the user reads and is passed through verbatim.
  //
  // A drop that was refused and a drop that was accepted and then failed read
  // the same to the user: both did nothing. The toast is transient, so it may
  // name more of the dropped input than anything that persists.
  function _dropFail(message) {
    root._notify("Drop failed: " + message, true)
  }

  function _decodeFileUri(uri) {
    let p = uri
    if (p.startsWith("file://")) {
      p = p.substring(7)
      if (p.startsWith("localhost")) {
        const slash = p.indexOf("/")
        if (slash >= 0) p = p.substring(slash)
        else p = ""
      }
      if (p !== "" && p[0] !== "/") p = "/" + p
    }
    try {
      p = decodeURIComponent(p)
    } catch (e) {
    }
    return p
  }

  // Remote input is https only. Plain http is refused rather than upgraded:
  // the scheme is the transport decision, and silently switching it would put
  // a wallpaper on both destinations that the remote end never authenticated.
  function _isHttpsUrl(s) {
    return s.startsWith("https://")
  }

  // Credentials embedded in the authority (`user:password@host`) would be sent
  // to the remote end and would sit in this process's argv, so an authority
  // carrying a userinfo separator is refused before anything is fetched. The
  // authority runs from the scheme to the first path, query, or fragment
  // delimiter; a percent-encoded `@` is data in a host and stays accepted.
  function _urlHasCredentials(s) {
    const rest = s.slice("https://".length)
    const stop = rest.search(/[\/?#]/)
    const authority = stop < 0 ? rest : rest.slice(0, stop)
    return authority.indexOf("@") >= 0
  }

  function _extOk(path) {
    return ImageExts.ok(path)
  }

  // Hover-time acceptance test shared by every drop target (the two
  // DropAreas here, the picker's preview, and both halves of the bar).
  // The rule is "exactly one image", not "exactly one entry", and it lives
  // in DropPayload so all five surfaces agree: a payload the hover accepts
  // is a payload handleDroppedUri can act on, so a drag never lights up and
  // is then refused as a multi-file drag. A browser drag of an image inside a
  // link offers the image and the page holding it, and that is one image.
  function _dropIsSupported(drag) {
    return DropPayload.supported(drag)
  }

  // The single uri a payload carries, or "" when it does not resolve. The
  // drop targets read this instead of parsing the payload themselves, which
  // is what let the bar and the desktop drift apart.
  function _droppedUri(drop) {
    const verdict = DropPayload.resolve(drop)
    return verdict.ok === true ? String(verdict.uri) : ""
  }

  function _sanitizeBase(name) {
    return name.replace(/[^A-Za-z0-9._-]/g, "_")
  }

  // Short deterministic hash of a remote URL, so a repeated drop of one URL
  // lands on one destination file instead of a timestamped new one. FNV-1a
  // over the URL string, 8 hex digits: enough to keep two hosts serving one
  // basename apart while the same URL always hashes the same.
  function _hash8(s) {
    let h = 0x811c9dc5
    const t = String(s || "")
    for (let i = 0; i < t.length; i++) {
      h ^= t.charCodeAt(i)
      h = (h * 0x01000193) >>> 0
    }
    return ("0000000" + h.toString(16)).slice(-8)
  }

  // The one entry point for a drag, whatever delivered it: the desktop's own
  // DropArea, the bar's forward through DesktopActions, and the `drop` IPC
  // verb. Every refusal below is a toast, because a refused drag leaves
  // nothing behind - no pointer, no file, no state change - and a toast that
  // has already faded is the only record the user had of it.
  function handleDroppedUri(rawUri) {
    // A drop that arrives while the wallpaper is off is a no-op and stays one:
    // the desktop's DropArea is gated on the same flag, so this is reachable
    // only over IPC or from the bar, and a toast here would be a new
    // user-visible behaviour for something that did nothing.
    if (!root.enabled) return
    if (root._busy()) {
      root._dropFail("another drop in progress")
      return
    }
    const uri = String(rawUri || "").trim()
    if (uri === "") {
      root._dropFail("empty uri")
      return
    }
    if (uri.indexOf("\n") >= 0 || uri.indexOf("\r") >= 0) {
      const parts = uri.split(/[\r\n]+/).filter(function(l) { return l.trim() !== "" && l.trim()[0] !== "#" })
      if (parts.length !== 1) {
        root._dropFail("drop only one image at a time")
        return
      }
      root.handleDroppedUri(parts[0])
      return
    }
    if (uri.startsWith("file://") || uri.startsWith("/")) {
      let path = uri
      if (uri.startsWith("file://")) path = root._decodeFileUri(uri)
      if (!path.startsWith("/")) {
        root._dropFail("only absolute paths supported")
        return
      }
      if (!root._extOk(path)) {
        root._dropFail("unsupported format")
        return
      }
      if (root.activeTheme === "") {
        root._dropFail("no active theme")
        return
      }
      root._beginLocalDrop(path)
      return
    }
    if (uri.startsWith("http://")) {
      root._dropFail("https:// URLs only")
      return
    }
    if (root._isHttpsUrl(uri)) {
      root._handleHttpUrl(uri)
      return
    }
    // The toast keeps the fragment the user dropped, because it is the only
    // thing that tells them which drag was wrong. A URI is unbounded user
    // input and can hold a signed token, so it is truncated here and not
    // carried anywhere else.
    root._dropFail("unsupported uri: " + uri.slice(0, 80))
  }

  // A local payload is stat-ed before anything is copied: a directory, a
  // dangling symlink, an oversized file and an empty file are all refused
  // before a child writes to either destination.
  function _beginLocalDrop(path) {
    const record = root._open(root._dropKey, { origin: "local", src: path, temp: "" })
    if (record === null) return
    root._runStat(record, path)
  }

  function _runStat(record, path) {
    root._runChild(record, CommandSpec.argv(["stat", "-c", "%F:%s", "--", path]),
      root._probeTimeoutMs, (result) => root._onDropStat(record, result))
  }

  function _onDropStat(record, result) {
    if (!root._live(record)) return
    const isTemp = record.temp !== ""
    if (!root._succeeded(result)) {
      // The dropped file is not there, or could not be read.
      root._retire(record.key, "stat_failed")
      root._dropFail("file not found")
      return
    }
    const raw = String(result.stdout || "").trim()
    const sep = raw.lastIndexOf(":")
    const kind = sep >= 0 ? raw.slice(0, sep) : ""
    const sizeStr = sep >= 0 ? raw.slice(sep + 1) : "0"
    const size = parseInt(sizeStr, 10)
    // Every refusal below retires first, so the scratch file of a download is
    // removed here instead of at the next unrelated drop.
    if (kind.indexOf("regular") !== 0) {
      root._retire(record.key, "not_regular")
      root._dropFail("not a regular file")
      return
    }
    if (isNaN(size) || size > root.maxDropBytes) {
      root._retire(record.key, "too_large")
      root._dropFail("file too large (" + sizeStr + " bytes)")
      return
    }
    if (size === 0) {
      root._retire(record.key, "empty")
      root._dropFail("empty file")
      return
    }
    if (!isTemp) {
      root._retire(record.key, "local_accepted")
      // The kind of the drop and nothing about the path. A dropped local path
      // is the user's own filesystem, and the URL arm below is stricter still.
      Log.info("dropped wallpaper (file)")
      // The size the stat answered with, and the one measurement this arm took.
      // The three refusals above print it in a toast and nothing here kept it,
      // so a wallpaper that decodes oddly or shows as a flat colour - usually
      // a few kilobytes - has no other record of how big the file was. The
      // parsed number rather than the stat line, which is the child's own
      // formatting and would want summarising to stay bounded.
      Log.debug("dropped wallpaper (file): " + size + " bytes")
      // The origin is forwarded so a local drop is distinguishable from a
      // picker pick. Nothing else reads it on this path: the copy-failure
      // notify tests for "drop" specifically, and "local" is not it, so their
      // wording is unchanged.
      const res = root._setAbs(record.src, "", record.origin)
      if (typeof res === "string" && res.startsWith("error:")) {
        // The adoption the line above announced was refused a moment later,
        // and the reason reached a toast and nowhere else. Without this the
        // pair reads as a wallpaper that changed and did not, which is the
        // one way this file can overstate what it did. The verdict prefix is
        // dropped because `refused as` already says it, and because leaving a
        // level word inside the text of a record is the one thing that reads
        // as a level word; the test above it is what makes the cut exact.
        // Bounded because what is left carries the dropped file's extension.
        const d = Log.at()
        if (d.allows("debug")) {
          d.debug("dropped wallpaper (file): refused as "
            + Log.summarize(res.slice("error: ".length)))
        }
        root._notify("Drop failed: " + res, true)
      }
      return
    }
    root._runMime(record, record.temp)
  }

  function _runMime(record, path) {
    root._runChild(record, CommandSpec.argv(["file", "--mime-type", "-b", "--", path]),
      root._probeTimeoutMs, (result) => root._onDropMime(record, result))
  }

  // A remote payload is downloaded into the cache dir, never in place: the
  // scratch file is a destination built from remote data, so its leaf has to
  // be one inert segment under that directory before curl is told to write
  // it, and the resolved path has to be exactly the one intended. The scheme
  // and the authority are settled before any of that: the destination is
  // lexical only, and containment across a symlinked cache directory and the
  // race between the check and the write stay unverified.
  function _handleHttpUrl(url) {
    if (url.length > 2048 || url.indexOf(" ") >= 0) {
      root._dropFail("invalid URL")
      return
    }
    if (root._urlHasCredentials(url)) {
      // The userinfo separator is the whole reason; the authority itself is
      // not named, because a host is the only part of it that would help
      // and the credentials are the part that must not be shown.
      root._dropFail("URL carries credentials")
      return
    }
    if (root.activeTheme === "") {
      root._dropFail("no active theme")
      return
    }
    let base = url.split("?")[0].split("#")[0].split("/").pop() || ""
    try { base = decodeURIComponent(base) } catch (e) {}
    if (base !== "") base = root._sanitizeBase(base)
    let ext = ""
    const dot = base.lastIndexOf(".")
    if (dot >= 0) ext = base.slice(dot + 1).toLowerCase()
    const named = root._imageExts[ext] === true
    // The recorded basename is stable per URL: the same drop twice lands on
    // the same file and overwrites it instead of minting a new timestamped
    // copy on every drop. The hash keeps two different URLs sharing one
    // basename apart.
    let finalBase = ""
    if (!named) {
      ext = "jpg"
      finalBase = "dropped-" + root._hash8(url) + "." + ext
      base = "dropped-" + Date.now() + "." + ext
    } else {
      if (base.length > 120) base = base.slice(0, 120)
      const cut = base.lastIndexOf(".")
      const stem = cut >= 0 ? base.slice(0, cut) : base
      const stemCut = stem.length > 80 ? stem.slice(0, 80) : stem
      finalBase = stemCut + "-" + root._hash8(url) + "." + ext
      if (finalBase.length > 120) finalBase = finalBase.slice(0, 120)
    }
    const tmpDir = Paths.vibraniumCache !== "" ? Paths.vibraniumCache : "/tmp"
    const tmp = tmpDir + "/wallpaper-drop-" + Date.now() + "-" + Math.floor(Math.random() * 10000) + "-" + base
    if (root._destOf(tmpDir, tmp.slice(tmpDir.length + 1)) !== tmp) {
      root._dropFail("unsafe cache path")
      return
    }
    const record = root._open(root._dropKey, { origin: "http", src: tmp, url: url, temp: tmp, finalBase: finalBase })
    if (record === null) return
    root._runChild(record, CommandSpec.argv(["mkdir", "-p", tmpDir]), root._probeTimeoutMs,
      (result) => root._onDropMkdir(record, result))
  }

  function _onDropMkdir(record, result) {
    if (!root._live(record)) return
    if (!root._succeeded(result)) {
      root._retire(record.key, "mkdir_failed")
      root._dropFail("cannot create cache dir")
      return
    }
    // Redirects are capped, the response size is capped, and --fail turns an
    // HTTP error into a nonzero exit so an error page is never mistaken for
    // an image. The URL travels as an argument after `--`, never as source.
    //
    // A dropped URL is the one input here that can carry a secret - a signed
    // link is a bearer token - and it is refused when it carries userinfo
    // precisely because it can.
    root._runChild(record, CommandSpec.argv(["curl", "--location", "--max-redirs", "3",
      "--connect-timeout", "10", "--max-time", "30", "--max-filesize", String(root.maxDropBytes),
      "--fail", "--silent", "--show-error", "--output", record.temp, "--", record.url]),
      root._curlTimeoutMs, (result) => root._onDropCurl(record, result))
  }

  function _onDropCurl(record, result) {
    if (!root._live(record)) return
    if (!root._succeeded(result)) {
      const err = result === null ? "download failed"
        : (String(result.stderr || "").trim() || "download failed")
      root._retire(record.key, "download_failed")
      // The toast carries curl's own words, truncated, because that is the only
      // copy of them the user gets: a 404, a refused TLS handshake and a
      // truncated response are three different faults and curl names each of
      // them.
      root._notify("Drop failed: " + err.slice(0, 120), true)
      return
    }
    root._runStat(record, record.temp)
  }

  // The extension is the only gate a download has left, so the content type
  // decides: a page of HTML named .png is refused before it is copied into
  // either background directory.
  function _onDropMime(record, result) {
    if (!root._live(record)) return
    const mime = root._succeeded(result) ? String(result.stdout || "").trim() : ""
    if (mime === "") {
      root._retire(record.key, "mime_unknown")
      root._dropFail("cannot detect file type")
      return
    }
    if (!mime.startsWith("image/")) {
      root._retire(record.key, "not_an_image")
      // The content type is named in the toast because it is the whole
      // answer: `text/html` named `.png` is the case this branch exists for.
      root._dropFail("not an image (" + mime + ")")
      return
    }
    // A dropped URL is a bearer token the moment it is signed, so neither the
    // URL nor the host is named here - only that a URL became the wallpaper.
    Log.info("dropped wallpaper (url)")
    // The content type that cleared the last gate a download has. It is the
    // whole answer to "why did that link become the wallpaper" - the toast
    // above names every rejected content type and nothing named the accepted
    // one - and it is stdout from a child, so it is bounded rather than
    // printed at whatever length the file chose to answer with.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("dropped wallpaper (url): accepted as " + Log.summarize(mime))
    }
    // The download becomes the source of a set operation, so ownership of
    // the scratch file moves with it: a failed copy removes it, a commit
    // keeps it until the copy is done. The drop itself is closed first, so
    // the two generations never overlap on the same work. The recorded
    // basename is the stable per-URL one, not the timestamped scratch leaf,
    // so a repeated drop overwrites its own file.
    const temp = record.temp
    const run = root._runs[record.key]
    if (run !== undefined) run.temp = ""
    root._retire(record.key, "drop_accepted")
    const res = root._setAbs(record.src, temp, "drop",
      typeof record.finalBase === "string" ? record.finalBase : "")
    if (typeof res === "string" && res.startsWith("error:")) {
      // The same refusal the local arm reports, and the same two reasons to
      // report it: the set is the last gate before the copy, so an adoption
      // the line above announced can still end with the wallpaper unchanged
      // and a scratch file removed, and the verdict prefix is dropped because
      // `refused as` already says it.
      const refused = Log.at()
      if (refused.allows("debug")) {
        refused.debug("dropped wallpaper (url): refused as "
          + Log.summarize(res.slice("error: ".length)))
      }
      root._notify("Drop failed: " + res, true)
      // No set operation took the file, so nothing else will remove it.
      root._cleanupPath(temp)
    } else {
      root._notify("Wallpaper set from download", false)
    }
  }

  function _cleanupPath(p) {
    if (!p) return
    // Only ever a scratch file this module built under the cache dir, and the
    // name reached rm as an argument, never as shell source. A teardown
    // callback can reach this after the singletons that own children start
    // going away, so nothing is spawned then: the file is in a disposable
    // cache dir and a later drop reuses a fresh name anyway.
    if (root._closing) return
    Exec.run(["rm", "-f", "--", p])
  }

  // Re-read palette and re-resolve the current pointer (on boot & IPC poke).
  function refreshBackground() {
    Theme.reloadPalette()
    root._reconcile()
  }

  function refresh() {
    root.rerollMosaic()
    root.refreshBackground()
  }

  // Watch governor for themeNameFile (trio)
  property var _themeWatchUnsub: null

  // Set by the destruction handler, so a late callback cannot create a child
  // under a singleton that is already being torn down.
  property bool _closing: false

  // Teardown: every live operation loses its generation and every child it
  // still owns is terminated and its job object destroyed, so a callback
  // arriving during engine teardown finds a stale handle and returns instead
  // of writing to a half torn down service. A job is destroyed here rather
  // than left to the registry's deferred dispose, which may never run while
  // the engine takes the tree down.
  function _shutdown() {
    root._closing = true
    const keys = Object.keys(root._runs)
    for (let i = 0; i < keys.length; i++) {
      RequestGate.invalidateScope(root._gateScope, keys[i])
      const run = root._runs[keys[i]]
      if (run === undefined || run.job === null || run.job === undefined) continue
      const job = run.job
      root._stopJob(job, "destroyed")
      try {
        job.destroy()
      } catch (ignored) {
        continue
      }
    }
    root._runs = ({})
    root._cyclePending = []
  }

  Component.onCompleted: {
    Registry.offer("wallpaper", {
      title: "Wallpaper",
      description: "wallpaper service",
      verbNames: [
        "drop",
        "get",
        "isEnabled",
        "next",
        "prev",
        "refresh",
        "set",
        "status",
        "help",
        "ping",
      ]
    })
    // The singleton's own start, before the first reconcile: the reconcile
    // that follows reads the theme pointer, and until the settings land
    // `enabled` is false by construction.
    root.refreshBackground()
    root._themeWatchUnsub = Watch.subscribe(Paths.themeNameFile, (text) => {
      root._onThemeNameChanged(text)
    })
  }
  Component.onDestruction: {
    if (root._themeWatchUnsub) root._themeWatchUnsub()
    Registry.unregister("wallpaper")
    root._shutdown()
  }

  Variants {
    model: Ui.validScreens
    delegate: WallpaperView {
      required property ShellScreen modelData
      screen: modelData
    }
  }

  FileView {
    id: wallpaperView
    path: Paths.wallpaperStateJson
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root._loadJson()
    onLoadFailed: root._loadJson()
    onFileChanged: wallpaperView.reload()
    JsonAdapter {
      id: stateAdapter
      property var data: ({})
      onDataChanged: {
        root._state = stateAdapter.data
        root._reconcile()
      }
    }
  }

  IpcHandler {
    target: "wallpaper"
    function help(command: string): string {
      return UnitIpc.help("wallpaper", "Wallpaper", "wallpaper service", [
        { name: "drop", help: "(uri) set wallpaper from a drag URI" },
        { name: "get", help: "current wallpaper path" },
        { name: "isEnabled", help: "wallpaper engine on?" },
        { name: "next", help: "next wallpaper" },
        { name: "prev", help: "previous wallpaper" },
        { name: "refresh", help: "re-scan" },
        { name: "set", help: "(path) set the wallpaper" },
      ], command)
    }
    function status(): string {
      return JSON.stringify({ unit: "wallpaper", healthy: true })
    }
    function ping(): string { return "pong" }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function next(): string {
      if (root.switching) return "error: switching"
      root.next()
      return "ok"
    }
    function prev(): string {
      if (root.switching) return "error: switching"
      root.prev()
      return "ok"
    }
    function set(path: string): string { return root.set(path) }
    function get(): string { return root.current }
    function drop(uri: string): string { root.handleDroppedUri(uri); return "ok" }

    function isEnabled(): string {
      return Settings.wallpaperEnabled ? "true" : "false"
    }
  }
}

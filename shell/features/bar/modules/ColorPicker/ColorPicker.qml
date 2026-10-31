pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.bar
import "ColorMath.js" as ColorMath
import "../../../../common/capture/ShotLib.js" as ShotLib

// Color picker module. Left click starts a native pick: a full-screen
// overlay on this module's screen shows the captured frame through
// ScreencopyView (the same backend the lockscreen uses) and the clicked
// pixel is read back entirely in-process - grabToImage of the view,
// cropped into a 1x1 Canvas, decoded with getImageData. No helper
// scripts, no screenshots, no temp files. Right click opens the history
// island; middle click clears the history. A picked color is copied in
// the format selected in the island (captured when the pick started).
// The bar icon is the droplet glyph; when
// shell.colorPicker.showLastColor is on and the history is not
// empty it is recolored with the newest record's color.
//
// History: $VIBRANIUM_CACHE/colorpicker.json is one shared document
// holding records { color, alpha, timestamp, formats?, fmt? }, owned by
// the state singleton as a cache slot. The module renders once per output
// while the history is global, so every instance reads and writes that one
// slot: a pick on one monitor is the whole history, and a write on one
// output cannot drop what another output already stored. Records are
// addable, deletable and deduped by color+alpha+format, capped at
// shell.colorPicker.historySize; the island shows a five-row viewport
// regardless of the cap.
//
BarModule {
  id: root

  // --- global history store ---
  // The store file is a cache slot of the state singleton, so the history
  // has exactly one authority no matter how many outputs the bar renders:
  // the singleton owns the single FileView (atomic write, watch, reload)
  // and the single live record array. The module loads once per output,
  // and each of those instances mirrors that payload here - it never holds
  // a copy of its own, which is what makes a write from one output
  // computed against what every other output already sees.
  //
  // The one thing the module still reads from the file itself is the
  // cold-start adoption below, and that read is shared through the neutral
  // DocumentAdoption tracker rather than opened per output.
  readonly property string _storeKey: "colorpicker"

  // Cache slots live at <key>.json inside the cache dir, so this is the
  // file the adoption reader below reads. The reader itself is shared, not
  // per output - see _adopt().
  readonly property string _storePath: Paths.vibraniumCache + "/" + root._storeKey + ".json"

  // Persisted cap (schema option shell.colorPicker.historySize, 1..50).
  // The UI always shows ten rows regardless; the file itself holds at
  // most this many records.
  readonly property int historySize: {
    const v = Settings.value("shell.colorPicker.historySize")
    return typeof v === "number" && v >= 1 && v <= 50 ? Math.round(v) : 10
  }

  // Notify after every completed pick (shell.colorPicker.notifyOnPick,
  // default on).
  readonly property bool notifyOnPick: Settings.value("shell.colorPicker.notifyOnPick") !== false

  // Icon tint (shell.colorPicker.showLastColor, default on): when on
  // and the history holds at least one record, the small droplet inside
  // the droplet glyph is filled with the newest record's opaque color
  // (the outline keeps the theme foreground). Settings.value() captures
  // rev, so a settings toggle re-renders live; records is reassigned
  // wholesale on every store change, so picks, island copies and
  // deletes re-tint in the same frame.
  readonly property bool _tintEnabled: Settings.value("shell.colorPicker.showLastColor") !== false

  // Newest record's "#rrggbb" (ColorMath normalizes every stored
  // color to lowercase #rrggbb); "" when the history is empty. Record
  // alpha is ignored on purpose: a translucent icon would read as
  // broken theming against the bar background.
  readonly property string _lastColor: root.records.length > 0 && root.records[0]
    ? String(root.records[0].color || "") : ""

  // Format a screen pick is copied and stored in. Not a schema option:
  // it follows the island's active format chip, which persists the
  // choice itself; captured in beginPick() so mid-pick chip changes
  // cannot alter the outcome.
  property string pickFmt: "hex"

  // Live parsed history for this output, newest first:
  // [{ color, alpha, timestamp }]. Reassigned wholesale whenever the shared
  // payload changes, and the array is the store's own array rather than a
  // copy of it.
  property var records: []

  // --- the picker's working state ---
  //
  // The preview colour and the hue, as the user last left them - which is
  // not the history. A colour dialled into the sv field and abandoned was
  // never committed, so it is in no record; and a pick is opaque unless the
  // alpha slider says otherwise, so the history's top entry carries no
  // transparency to restore. Both live in the shell cache under one
  // section, so the picker opens where the last session stopped.
  //
  // The module owns the section for the same reason it owns the history
  // store: the island never writes a document itself. It is the bar's
  // per-output module, so three monitors keep one section and the last
  // picker the user touched wins - which is the one they will see next.
  function workingState() {
    const sec = ShellCache.section("colorPicker")
    if (sec === null || typeof sec !== "object") return null
    const c = sec.picked
    if (c === null || typeof c !== "object" || Array.isArray(c)) return null
    const rgb = ["r", "g", "b"]
    for (let i = 0; i < rgb.length; i++) {
      const n = Number(c[rgb[i]])
      if (!isFinite(n) || n < 0 || n > 1) return null
    }
    const a = Number(c.a)
    if (!isFinite(a)) return null
    const hue = Number(sec.hue)
    return {
      picked: {
        r: Number(c.r), g: Number(c.g), b: Number(c.b),
        a: ColorMath.clampAlpha(a)
      },
      // Clamped to the same 0..360 the slider uses rather than wrapped to it.
      // Both ends are pure red, so a wrapped value and a clamped one paint
      // identically - but a stored 360 restored as 0 would park the thumb at
      // the wrong end of the bar, which is the teleport the clamp prevents.
      hue: isFinite(hue) ? Math.min(360, Math.max(0, hue)) : 0
    }
  }

  // Absorb the island's live preview. Held rather than written on every
  // report: the alpha slider reports on every pointer move, and AppState
  // flushes on the next event-loop turn, so an unwritten report is an
  // atomic file write per frame of a drag.
  property var _pendingWorking: null
  Timer {
    id: workingFlush
    interval: 400
    onTriggered: {
      const p = root._pendingWorking
      if (p === null) return
      root._pendingWorking = null
      ShellCache.updateSection("colorPicker", {
        picked: p.picked, hue: p.hue
      })
    }
  }

  function reportWorking(picked, hue) {
    // A screen pick owns the preview while it runs; whatever the island
    // reports meanwhile is not a colour the user chose on the picker.
    if (root.picking === true) return
    const rgb = ["r", "g", "b"]
    const out = {}
    for (let i = 0; i < rgb.length; i++) {
      const n = Number(picked[rgb[i]])
      if (!isFinite(n)) return
      out[rgb[i]] = Math.min(1, Math.max(0, n))
    }
    const a = Number(picked.a)
    if (!isFinite(a)) return
    out.a = ColorMath.clampAlpha(a)
    const h = Number(hue)
    root._pendingWorking = {
      picked: out,
      hue: isFinite(h) ? Math.min(360, Math.max(0, h)) : 0
    }
    workingFlush.restart()
  }

  // Identity of the shared payload behind `records`. The state singleton
  // bumps one global revision for every slot write, so this identity is
  // what separates "this history changed" from "some other slot in the
  // shell changed": only the former rebuilds the array.
  property var _storeSeen: null

  // Dedupe identity of a record; dedupe, promotion and deletion use
  // it. Delegates to ColorMath so the store and the history list can
  // never disagree on the key shape.
  function _recKey(rec): string {
    return ColorMath.recordKey(rec)
  }

  // One store record in canonical form: normalized "#rrggbb", clamped
  // alpha, a numeric timestamp, plus the optional formats map and display
  // fmt. null for a malformed entry, so a hand-edited document can never
  // paint a broken row. The single definition both the read and the write
  // path go through.
  function _canonical(rec): var {
    if (rec === null || typeof rec !== "object" || Array.isArray(rec)) return null
    const c = ColorMath.parse(rec.color)
    if (c === null) return null
    const out = {
      color: ColorMath.hex6(c),
      alpha: typeof rec.alpha === "number" ? ColorMath.clampAlpha(rec.alpha) : 1,
      timestamp: typeof rec.timestamp === "number" && isFinite(rec.timestamp) ? rec.timestamp : 0
    }
    if (rec.formats && typeof rec.formats === "object") {
      const fmts = ColorMath.sanitizeFormats(rec.formats)
      if (Object.keys(fmts).length > 0) out.formats = fmts
    }
    if (typeof rec.fmt === "string" && ColorMath.FORMATS.indexOf(rec.fmt) >= 0) {
      out.fmt = rec.fmt
    }
    return out
  }

  // Normalise a store payload: canonicalise every record, drop malformed
  // ones, dedupe by color+alpha+format (first occurrence wins and moves to
  // the front) and cap at historySize. Returns a fresh array, never
  // mutates in place.
  function _normalize(raw): var {
    const list = Array.isArray(raw) ? raw : []
    const out = []
    const seen = {}
    for (let i = 0; i < list.length; i++) {
      const rec = root._canonical(list[i])
      if (rec === null) continue
      const key = root._recKey(rec)
      if (seen[key]) continue
      seen[key] = true
      out.push(rec)
    }
    return out.slice(0, root.historySize)
  }

  // The shared payload as a record array. Every mutation reads the store
  // through here, so there is no second array an output could fall behind
  // on and no local copy a lost update could be serialised from.
  //
  // A payload this process wrote is a plain JS object; one the singleton
  // read back from the file is the adapter's object tree, whose record
  // list is array-like without being a JS array (Array.isArray() is false
  // and join() does not work on it). The boundary converts that once, so
  // everything downstream sees a plain array.
  function _sharedRecords(): var {
    const payload = AppState.value(root._storeKey)
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return []
    const list = payload.records
    if (list === undefined || list === null) return []
    return Array.isArray(list) ? list : Array.prototype.slice.call(list)
  }

  // The one reconciliation point for this output: adopt the shared payload
  // unless `records` already mirrors it. Picks, island copies, deletes,
  // clears, the adoption below and a write to the store from outside the
  // shell all land here, so the island and the icon tint always read the
  // array the store holds.
  function _reconcileStore() {
    const payload = AppState.value(root._storeKey)
    if (payload === root._storeSeen) return
    root._storeSeen = payload
    root.records = root._normalize(root._sharedRecords())
  }

  // --- persistence ---
  // One document, one writer: the state singleton's coalesced atomic write.
  // `next` is the whole record array and callers build it from
  // _sharedRecords(), which is what makes a write from any output a
  // read-modify-write against the current shared history. Returns whether
  // the store took it.
  function _persist(next): bool {
    const records = root._normalize(next)
    if (!AppState.set(root._storeKey, { records: records })) {
      // The store refused the document, so the caller's change is lost with it
      // and every caller here returns this verdict upward.
      return false
    }
    // The singleton copies the payload wrapper, not the record array, so
    // this output can hold the store's own array; the identity above then
    // makes the reconcile recognise this write and leave it alone.
    root._storeSeen = AppState.value(root._storeKey)
    root.records = records
    return true
  }

  // A cache slot's payload is an object, so a store document holding a bare
  // record array cannot be deserialized into it. The state store wraps such a
  // document under its own `data` key rather than letting the adapter refuse
  // it forever, so there are two shapes this has to adopt: no slot at all,
  // and a slot holding the store's `{data: [...]}` wrapper. The second
  // is the one an upgrade from the pre-slot bare-array file hits - and a
  // payload that is present but has no `records` key means the history is
  // unreadable, not that there is none.
  //
  // The reader that supplies the text is the shared one, so this runs for
  // whichever output is around when it answers; every other output reaches
  // the same text through the same signal and finds the slot already
  // created.
  function _adoptStore(text) {
    if (root._storeReader !== null) {
      DocumentAdoption.release(root._storeReader)
      root._storeReader = null
    }
    const payload = AppState.value(root._storeKey)
    const wrappedBareArray = payload !== null && typeof payload === "object"
      && !Array.isArray(payload) && payload.records === undefined
      && payload.data !== undefined
    if (payload === null || wrappedBareArray) {
      const source = String(text === undefined || text === null ? "" : text)
      const parsed = root._normalize(ColorMath.parseHistory(source))
      // A document that does not parse exactly as an empty file does yields []
      // for both, and the slot below writes [] over the user's file either way,
      // so nothing here distinguishes an unreadable history from a first run.
      AppState.slot(root._storeKey, { records: parsed }, "cache")
    }
    root._reconcileStore()
  }

  // The shared adoption observation this output holds, or null when there is
  // none. One held across an output's life is what a teardown has to drop;
  // see the destruction handler below.
  property var _storeReader: null

  // Bring the shared store up. The slot exists: every output - including one
  // created after another was destroyed - only mirrors it. The slot is
  // absent: join the ONE read of this document, and the first answer creates
  // the slot for everyone.
  function _ensureStore() {
    // Adoption is needed when the slot is absent AND when it is present but
    // holds the state store's `{data: [...]}` wrapper, which is what an
    // upgrade from the pre-slot bare-array file looks like. A present slot
    // with no `records` key is unreadable history, not an empty history, so
    // treating it as "nothing to do" would silently drop every colour the
    // user picked.
    const payload = AppState.value(root._storeKey)
    const wrappedBareArray = payload !== null && typeof payload === "object"
      && !Array.isArray(payload) && payload.records === undefined
      && payload.data !== undefined
    if (payload === null || wrappedBareArray) root._adopt()
    root._reconcileStore()
  }

  // Join the shared adoption read, or stay on the one already in flight.
  // The document is read by ONE reader for the whole shell, because a cold
  // start has every output reach this at once and N readers on one file
  // would all race to publish the same history. The first observer opens
  // the read and the rest join it, so the document is read once whichever
  // output got there first, and an output created while that read is still
  // pending joins it rather than opening a second.
  function _adopt() {
    if (root._storeReader === null) {
      root._storeReader = DocumentAdoption.observe("bar/colorPicker", root._storePath)
    }
  }

  // The shared read's answer, to every output in the shell. Each instance
  // adopts for itself: the first one creates the slot, the rest find it and
  // only mirror it.
  Connections {
    target: DocumentAdoption

    function onAdopted(path, text) {
      if (path === root._storePath) root._adoptStore(text)
    }
  }

  // The singleton owns the store's file view, so its revision is the
  // signal every output reconciles on - a write from anywhere, a write to
  // the document from outside the shell, or the adoption above. The
  // identity check inside rebuilds the array only when the payload object
  // itself changed, so a write to another slot the shell keeps does not
  // churn the history.
  Connections {
    target: AppState

    function onRevChanged() {
      root._reconcileStore()
    }
  }

  // Last copied color code shown in the bar flash (plain foreground text,
  // never tinted with the color itself). Set at the moment the record
  // lands in history; the reveal window below times how long it stays up.
  property string flashText: ""
  function _recordDisplay(rec): string {
    if (!rec || typeof rec !== "object") return ""
    const f = rec.formats && typeof rec.formats === "object" ? rec.formats : null
    const fmt = typeof rec.fmt === "string" ? rec.fmt : "hex"
    if (f !== null && typeof f[fmt] === "string" && f[fmt] !== "") return String(f[fmt])
    const c = ColorMath.parse(String(rec.color || ""))
    if (c === null) return String(rec.color || "")
    const a = typeof rec.alpha === "number" ? ColorMath.clampAlpha(rec.alpha) : 1
    return ColorMath.hex8(c, a)
  }
  function _fireCopyFlash(text) {
    const s = String(text === undefined || text === null ? "" : text)
    if (s === "") return
    root.flashText = s
    if (root._fsActive) {
      root._flashPending = true
      return
    }
    codeFlash.pulse()
  }
  // Add a color (normalized "#rrggbb" from the island or a pick) with
  // alpha. `meta` optionally carries `formats`: a map of every supported
  // serialization of the entry at add time, stored on the record so each
  // history entry keeps all its forms including transparency. Dedupe by
  // color+alpha+format and move the repeat to the front, starting from the
  // shared history so an add never drops what another output just stored.
  function addRecord(colorHex, alpha, meta) {
    const c = ColorMath.parse(String(colorHex === undefined ? "" : colorHex))
    if (c === null) {
      // A caller handed the store something ColorMath cannot read. The
      // island's own commit points guard this first, so reaching it means a
      // caller changed.
      return false
    }
    const a = ColorMath.clampAlpha(alpha)
    let formats = null
    if (meta && typeof meta === "object" && meta.formats && typeof meta.formats === "object") {
      formats = ColorMath.sanitizeFormats(meta.formats)
    }
    const rec = {
      color: ColorMath.hex6(c),
      alpha: a,
      timestamp: Date.now()
    }
    if (formats !== null) rec.formats = formats
    if (meta && typeof meta.fmt === "string" && ColorMath.FORMATS.indexOf(meta.fmt) >= 0)
      rec.fmt = meta.fmt
    const key = root._recKey(rec)
    const base = root._sharedRecords()
    const next = [rec]
    for (let i = 0; i < base.length; i++) {
      if (root._recKey(base[i]) === key) continue
      next.push(base[i])
    }
    const ok = root._persist(next)
    if (ok === true) root._fireCopyFlash(root._recordDisplay(root.records.length > 0 ? root.records[0] : rec))
    return ok
  }

  // Move an existing entry to the front without re-adding it - the
  // history-row copy path. Takes the record reference and keys it here,
  // so island and module can never disagree on key format. Returns true
  // when a row moved.
  function promoteRecord(rec) {
    if (!rec || typeof rec !== "object") return false
    const key = root._recKey(rec)
    let moved = null
    const rest = []
    const base = root._sharedRecords()
    for (let i = 0; i < base.length; i++) {
      const r = base[i]
      if (moved === null && root._recKey(r) === key) {
        moved = r
        continue
      }
      rest.push(r)
    }
    // The key was computed from a record the island is still holding, so a miss
    // here is a delete/re-add race rather than a user error.
    if (moved === null) return false
    const ok = root._persist([moved].concat(rest))
    if (ok === true) root._fireCopyFlash(root._recordDisplay(root.records.length > 0 ? root.records[0] : moved))
    return ok
  }

  // Delete by normalized key (history rows route through the island by
  // record reference; the key form keeps idempotence for free).
  function removeRecordById(key) {
    const base = root._sharedRecords()
    const next = base.filter(rec => root._recKey(rec) !== key)
    // Nothing matched, so nothing was removed and nothing was written.
    // Reached when a second delete lands on an already-deleted row.
    if (next.length === base.length) return false
    // The slot and the size, not the colour. The colour itself is user content
    // in the same way a clipboard entry is, and the record that was dropped is
    // gone by the time this prints anyway.
    const removed = base.length - next.length
    const ok = root._persist(next)
    if (ok !== false) Log.info("cleared entry " + base.length + ", total " + next.length)
    // The INFO reports a size before and a size after, which is what a delete
    // should report: the colour is user content in the same way a clipboard
    // entry is, and the record is gone by the time the line prints.
    //
    // What two numbers cannot give back is the shape of what was dropped, and
    // the shape is the only part of a colour that is not the colour. This
    // function takes a dedupe key rather than a record, and `recordKey` builds
    // that key as `<color>|<alpha>|<fmt>`, so splitting it at the separators
    // yields the record's transparency and the serialization it was stored
    // under while the first segment - the colour - is never touched. Summarize
    // is deliberately not applied to the whole key: a bounded `#rrggbb` is
    // still the colour, and bounding it would look like permission to print it.
    //
    // The cap rides along because `total` says how many records the document
    // holds and nothing says how many it may hold, so a store at its cap is one
    // pick from evicting and a store below it is not.
    const d = Log.at()
    if (d.allows("debug")) {
      const parts = String(key).split("|")
      d.debug("cleared entry " + base.length + ": dropped " + removed + " of "
        + base.length + ", store " + next.length + " of " + root.historySize
        + ", alpha " + (parts.length > 1 ? parts[1] : "1")
        + ", stored as " + Log.summarize(parts.length > 2 ? parts[2] : ""))
    }
    return ok
  }

  function removeRecord(rec) {
    if (!rec || typeof rec !== "object") return false
    return root.removeRecordById(root._recKey(rec))
  }

  // Middle click: clear the store through the module's own writer. The
  // island's Clear history button routes here too, and the empty guard is
  // what keeps a click on an already empty history a no-op.
  function clearHistory() {
    if (root.records.length === 0) return
    const removed = root.records.length
    // `_persist` replaces `records` with the empty normalized array, so the
    // mirror the count was taken from is held here for the tally below; the
    // store discards it on every write and nothing can read it afterwards.
    const dropped = root.records
    root._persist([])
    // The count that went, then the count that is left - one clear can empty a
    // long history, and "total 0" alone does not say how much was there.
    Log.info("cleared history, total 0 (was " + removed + ")")
    // Both numbers are on the line above, so what is missing is not the size
    // but the shape of what the size was. A record keeps every supported
    // serialization of itself under `formats`, so clearing 23 records drops 23
    // strings or 161, and at INFO those are one line with one number.
    //
    // The cap comes along because "was 23" only means "the whole document"
    // once the reader knows the document holds at most `historySize` - and this
    // mirror is already normalized to that cap, so a clear can never report a
    // number above it.
    //
    // The tally is built rather than read because no stored field counts the
    // optional `formats` maps, and the walk sits inside the gate so a
    // suppressed line costs a comparison rather than a pass over the mirror.
    const d = Log.at()
    if (d.allows("debug")) {
      let rich = 0
      for (let i = 0; i < dropped.length; i++) {
        const fmts = dropped[i].formats
        if (fmts && typeof fmts === "object" && Object.keys(fmts).length > 0) rich++
      }
      d.debug("cleared history, total 0: " + removed + " of " + root.historySize
        + " records dropped, " + rich + " carrying a formats map")
    }
  }

  // --- copy pipeline ---
  // Copies run through wl-copy (argument array, no shell source) as jobs
  // ProcessRegistry owns: exactly one terminal transition per copy, behind
  // a spawn watchdog and a deadline, so a child that reports no exit still
  // settles. The island closes only after the copy command completed.
  //
  // This component's ONE external process. The island's `copied` and the pick's
  // own `picked` say what colour went where; the child agrees or does not.

  property var _pendingCopies: ({})
  property int _copySeq: 0
  readonly property string _copyScope: "bar.colorPicker:copy:" + Date.now().toString(36)
    + "-" + Math.floor(Math.random() * 1679616).toString(36)
  readonly property int _copySpawnWindowMs: 1500
  readonly property int _copySpawnPollMs: 25
  readonly property int _copyDeadlineMs: 5000

  

  // Copy `text` and report the outcome through cb(ok) when given. Island
  // copies pass the onCopyDone bridge; the pick path passes null.
  function _copyText(text, cb) {
    const s = String(text === undefined || text === null ? "" : text)
    if (s === "") {
      if (typeof cb === "function") cb(false)
      return false
    }
    const id = ++root._copySeq
    root._pendingCopies[id] = {
      job: null,
      cb: typeof cb === "function" ? cb : null,
      startedAt: Date.now()
    }
    let job = null
    try {
      job = ProcessRegistry.start(["wl-copy", "-n", s], root._copyScope, {
        maxAttempts: 1,
        timeoutMs: root._copyDeadlineMs,
        spawnWatchdogMs: root._copySpawnWindowMs,
        spawnPollMs: root._copySpawnPollMs,
        onFinished: (result) => root._copyFinished(id, root._copySettled(result), result),
        onFailed: reason => root._copyFinished(id, false,
          { code: "start_refused", detail: String(reason === undefined ? "" : reason) })
      })
    } catch (ignored) {
      job = null
    }
    if (root._pendingCopies[id] === undefined) {
      root._cancelCopy(job, "settled")
      return false
    }
    if (job === null) {
      // The registry refused or threw: no child ever ran, so the colour
      // never reached the clipboard.
      root._copyFinished(id, false)
      return false
    }
    root._pendingCopies[id].job = job
    return true
  }

  // Island-facing copy: one serialized string, result reported back to
  // the live island content (which lands the record and closes itself
  // on success). The content only exists while the host shows it; a
  // copy that settles after close has nowhere to land and runs bare.
  function copyColor(text) {
    const host = root.barWindow ? root.barWindow.islandHost : null
    const c = host ? host.content : null
    if (c && typeof c.onCopyDone === "function")
      return root._copyText(text, ok => c.onCopyDone(ok))
    // Nothing to land the result on: the island is already gone. The copy
    // still runs - the user asked for the clipboard, not for the island.
    return root._copyText(text, null)
  }

  // Every copy in this component - the screen pick, the island's Copy button
  // and its history rows - settles here exactly once, which is what makes this
  // the one place that can say whether the colour reached the clipboard. Not
  // _copyText: there the child has only been asked to run, so the request is
  // accepted there, not copied.
  function _copyFinished(id, ok, result) {
    const entry = root._pendingCopies[id]
    if (entry === undefined) return
    delete root._pendingCopies[id]
    if (typeof entry.cb === "function") entry.cb(ok === true)
  }

  function _copySettled(result) {
    if (result === null || result === undefined) return false
    if (result.cancelled === true || result.destroyed === true) return false
    if (result.timedOut === true) return false
    return String(result.code) === "ok" && Number(result.exitCode) === 0
  }

  // A copy still in flight when the module goes away (a bar reload, the shell
  // shutting down) never reaches its own settle, because the callback that
  // would deliver the verdict is gone with this object. The child is cancelled
  // so it cannot outlive the module holding its pipe.
  function _releaseCopies() {
    const ids = Object.keys(root._pendingCopies)
    if (ids.length === 0) return
    for (let i = 0; i < ids.length; i++) {
      const entry = root._pendingCopies[ids[i]]
      delete root._pendingCopies[ids[i]]
      root._cancelCopy(entry === undefined ? null : entry.job, "destroyed")
    }
  }

  function _cancelCopy(job, reason) {
    if (job === null || job === undefined) return false
    try {
      if (String(job.state) === "settled") return false
    } catch (ignored) {
      return false
    }
    try {
      job.cancel(String(reason))
      return true
    } catch (ignored) {
      return false
    }
  }

  // --- native picking ---
  // Overlay on this module's screen: a still ScreencopyView frame under
  // a full-fill click surface. The click point maps into the grabbed
  // frame and the pixel is read back in-process through the 1x1 Canvas
  // below - no processes, no screenshots, no temp files.
  //
  // The pick claims the screen while it runs, so an open menu is put away
  // before the frame is taken: the frame is the screen the user aims at,
  // and a menu over it would be both the thing being photographed and the
  // surface holding the pointer away from the lens.

  property bool picking: false
  property var pickScreen: null
  // Keeps the grab result alive until the Canvas finished sampling.
  property var _grabResult: null
  // The screen claim this pick holds, or null while no pick runs. The claim
  // is what makes the pick the owner of the screen: SurfaceClaim fires the
  // closer of whichever surface holds it, so a pick opened over a menu puts
  // the menu away instead of running underneath it.
  property var _pickClaim: null

  // A disconnected ShellScreen is dangling and does not reconnect, so a
  // captured screen object cannot be held for the life of a pick. The
  // pick's screen is re-resolved against the CURRENT set whenever that set
  // changes, in the order the screenshot surfaces use: object identity,
  // then serial, then name plus size (ShotLib.matchScreen). A wrapper
  // rebuild for a still-connected output rebinds; no match at all means
  // the output is gone, and a pick cannot finish on it - cancelPick
  // retires the generation, so the grab, decode and paint that could still
  // commit all go with the screen.
  function _reconcilePickScreen() {
    if (!root.picking) return
    const current = ShotLib.matchScreen(root.pickScreen, Ui.validScreens)
    if (current === null) {
      // The output the overlay is on is gone, so the pick cannot finish on it.
      root.cancelPick()
      return
    }
    if (current !== root.pickScreen) root.pickScreen = current
  }

  // Pick identity is a RequestGate generation rather than the flag pair:
  // the grab callback, the frame decode and the sampler paint all settle
  // asynchronously, so each carries the generation it was issued under and
  // drops out once that generation is no longer live. Scope and key stay
  // per instance even though the history is shared: a pick runs on THIS
  // instance's overlay, probe and canvas, so two pickers on different
  // monitors must never retire each other's pick.
  readonly property string _pickScope: "bar.colorPicker:" + Date.now().toString(36)
    + "-" + Math.floor(Math.random() * 1679616).toString(36)
  readonly property string _pickKey: "pixel"
  // Live generation of this instance's pick; 0 while no pick runs.
  property int _pickGen: 0

  // The handle current()/invalidate() compare: the captured generation
  // plus the pair that owns it.
  function _pickHandle(gen): var {
    return { id: gen, scope: root._pickScope, key: root._pickKey }
  }

  // Retire the live generation before any state moves, so a grab, decode
  // or paint issued under it can no longer commit.
  function _retirePick() {
    if (root._pickGen === 0) return
    RequestGate.invalidate(root._pickHandle(root._pickGen))
    root._pickGen = 0
  }

  // Returns whether the pick was armed (a screen was available and the
  // gate issued a generation); the click path ignores it, the IPC verb
  // reports it.
  //
  // Called from the module's own click and from the bar's `colorPicker pick`
  // verb, which serves both the CLI and the keybind.
  function beginPick(): bool {
    root._retirePick()
    let s = ShotLib.matchScreen(root.barScreen, Ui.validScreens)
    if (s === null) s = ShotLib.matchScreen(Ui.primaryScreen, Ui.validScreens)
    // No screen at all: the pick never opens, so there is no overlay to
    // cancel later.
    if (s === null) return false
    const host = root.barWindow ? root.barWindow.islandHost : null
    if (host && host.isOpenFor(root)) host.close()
    // The pick copies and stores in the island's active format; capture
    // it now, before the overlay hides the island. Read off the live
    // content when shown, else fall back to the persisted preference
    // (the same section restoreFmt() reads).
    const c = host ? host.content : null
    if (c && typeof c.fmt === "string" && ColorMath.FORMATS.indexOf(c.fmt) >= 0) {
      root.pickFmt = c.fmt
    } else {
      const sec = Settings.rawSection("colorPicker")
      const v = sec && typeof sec.fmt === "string" ? sec.fmt : ""
      if (ColorMath.FORMATS.indexOf(v) >= 0) root.pickFmt = v
    }
    const gen = RequestGate.begin(root._pickScope, root._pickKey)
    // A refused generation means no overlay.
    if (gen === 0) return false
    root._pickGen = gen
    root.pickScreen = s
    // The pick takes the screen before it opens. The claim fires the closer
    // of whichever surface holds the screen now, so an open menu is put away
    // rather than left under the pick: a menu keeps the pointer and the
    // keyboard, so a pick under one never sees the cursor, and the frame it
    // photographs would be the menu rather than the desktop the user aimed
    // at. The island is closed above for the same reason.
    root._pickClaim = SurfaceClaim.claim("colorPicker", root.cancelPick, root)
    root.picking = true
    return true
  }

  // Abandon the live pick. A pick that COMMITS does not come through here -
  // finishPick tears down through _teardownPick() instead.
  function cancelPick() {
    root._teardownPick()
  }

  // The state teardown every close shares.
  function _teardownPick() {
    root._retirePick()
    root.picking = false
    root.pickScreen = null
    root._grabResult = null
    // The screen goes back to whoever holds it now. A claim displaced while
    // the pick ran has already been dropped by the registry, so the release
    // finds nothing and the token is simply cleared.
    if (root._pickClaim !== null) {
      SurfaceClaim.release(root._pickClaim)
      root._pickClaim = null
    }
    // The decode inputs go with the generation: a frame still decoding or
    // a sample still pending would otherwise paint into a later pick.
    pixelSampler.pending = null
    frameProbe.source = ""
  }

  // Window-logical click point -> frame pixel -> history + clipboard.
  // grabToImage's callback result exposes url (string) and image() (a
  // method, not a property): frame dimensions come from the hidden Image
  // probe below once it decodes the url. The grab runs under the
  // generation live at click time, so a grab that outlives its pick
  // contributes nothing.
  function sampleAt(x, y) {
    const gen = root._pickGen
    if (gen === 0 || !root.picking) return
    // A click with no frame yet. The pick stays open (the frame may
    // still be coming), so this is not a close.
    if (!overlayPick.frameReady) return
    const item = overlayPick.captureItem
    item.grabToImage(result => {
      if (!RequestGate.current(root._pickHandle(gen))) return
      const url = result && result.url !== undefined ? String(result.url) : ""
      if (url === "") {
        root.cancelPick()
        return
      }
      root._grabResult = result
      // The overlay's own ratio, not one derived here: the lens the user
      // aimed with magnifies by that one, and a click mapped through a
      // second ratio reads a real colour from the wrong pixel.
      pixelSampler.sample(url, x, y, overlayPick.frameRatio, gen)
    })
  }

  // The pixel read did not produce a colour. Unlike an empty grab this keeps
  // the pick OPEN - the overlay is still up and the user can click again.
  function _sampleFailed() {
    root._grabResult = null
  }

  function finishPick(r, g, b, a, gen) {
    if (!RequestGate.current(root._pickHandle(gen))) return
    root._grabResult = null
    // Teardown, not cancelPick: this pick is committing.
    root._teardownPick()
    const rec = {
      r: ColorMath.clamp01(r / 255),
      g: ColorMath.clamp01(g / 255),
      b: ColorMath.clamp01(b / 255),
      // The screen is opaque; frame alphas a hair under 255 are
      // compositing quantization, not user-visible transparency. Snap
      // them so near-identical picks do not fork into separate entries.
      a: a === undefined ? 1 : (a >= 254 ? 1 : ColorMath.clamp01(a / 255))
    }
    const hex = ColorMath.hex6(rec)
    if (hex === "") return
    // The pick's single commit point: the click's grab, the frame decode
    // and the pixel read all settle into `hex` here, and a pick cannot
    // re-enter because the sampler clears its pending sample before it
    // calls.
    //
    // Copy + store in the captured format (root.pickFmt); the record
    // keeps a full serialization snapshot so every format stays
    // available for later copies.
    const fmt = root.pickFmt
    const alpha = rec.a
    root.addRecord(hex, alpha, { fmt: fmt, formats: ColorMath.allFormats(rec, alpha) })
    const copyText = copyTextFor(rec, fmt)
    root._copyText(copyText, null)
    if (root.notifyOnPick) {
      Exec.run(["notify-send", "-r", "3", "-t", "1500", "-a", "Vibranium",
        "Color Picker", "Color copied to clipboard: " + copyText])
    }
  }

  // The clipboard string a pick in `fmt` carries.
  function copyTextFor(rec, fmt) {
    const out = ColorMath.format(rec, fmt, rec.a)
    return out !== null ? out : ColorMath.hex6(rec)
  }

  ColorPickerOverlay {
    id: overlayPick

    visible: root.picking
    screen: root.picking ? root.pickScreen : null
    onPickedAt: (x, y) => root.sampleAt(x, y)
    // The overlay names the gesture that abandoned the pick (escape,
    // right-click); the module's own cancels below pass their own reasons.
    onCancelled: root.cancelPick()
  }

  // Pixel readout: the hidden Image probe decodes the grabbed frame and
  // reports its true pixel size, then the 1x1 Canvas crops the one
  // clicked pixel with drawImage + getImageData. The grab result stays
  // referenced (root._grabResult) until sampling ends, keeping its URL
  // valid across the async decode.
  //
  // The Canvas needs a second copy of the frame and loads it itself:
  // drawImage on an Image argument does not use the item's texture, and the
  // load is asynchronous and independent of frameProbe's status. A paint
  // that runs before it lands reads zeros, and a pick that commits zeros is
  // black - a real answer to a click that never touched black. So the sample
  // waits for both copies.
  Image {
    id: frameProbe

    visible: false
    cache: false
    source: ""

    onStatusChanged: {
      if (status !== Image.Ready || pixelSampler.pending === null) return
      // A decode of a retired frame still reports Ready; only the pick
      // that asked for it may sample it.
      if (!RequestGate.current(root._pickHandle(pixelSampler.pending.gen))) return
      pixelSampler.requestPaint()
    }
  }

  Canvas {
    id: pixelSampler

    width: 1
    height: 1
    visible: false
    contextType: "2d"

    // The sample still owed by the live pick: its coordinates plus the
    // generation that issued it, null when nothing is owed.
    property var pending: null

    function sample(url, x, y, ratio, gen) {
      pixelSampler.pending = {
        gen: gen,
        url: url,
        x: x,
        y: y,
        ratio: ratio
      }
      frameProbe.source = url
      pixelSampler.loadImage(url)
    }

    // imageLoaded() carries no argument and fires only for a load that was
    // still in flight, so it is a retry, never the gate: the paint below asks
    // isImageLoaded() instead.
    onImageLoaded: pixelSampler.requestPaint()

    onPaint: {
      if (pixelSampler.pending === null || frameProbe.status !== Image.Ready) return
      const p = pixelSampler.pending
      // Both copies in hand: the Image's decode reports the frame's size, the
      // Canvas's own copy supplies the pixels. Drawing before that copy lands
      // reads the bare backing - zeros - and a pick that commits zeros is
      // black, a real answer to a click that never touched black.
      if (!pixelSampler.isImageLoaded(p.url)) {
        if (pixelSampler.isImageError(p.url)) {
          pixelSampler.pending = null
          frameProbe.source = ""
          root._sampleFailed()
        }
        return
      }
      if (!RequestGate.current(root._pickHandle(p.gen))) return
      const ctx = pixelSampler.getContext("2d")
      if (ctx === null) {
        root._sampleFailed()
        return
      }
      const fw = frameProbe.implicitWidth
      const fh = frameProbe.implicitHeight
      if (fw <= 0 || fh <= 0 || !(p.ratio > 0)) {
        root._sampleFailed()
        return
      }
      // The one conversion in the component that can change the ANSWER
      // rather than only the position: a window-logical click point is mapped
      // onto physical frame pixels here, and a wrong ratio or a wrong
      // rounding returns a real colour from the wrong place. The rounding is
      // floor, not round, and must stay floor: the magnified block the cross
      // covers is the one containing the pointer, which is floor of the
      // click's frame coordinate. Rounding to the nearest pixel centre reads
      // the neighbour on half of all clicks.
      const gx = Math.max(0, Math.min(fw - 1, Math.floor(p.x * p.ratio)))
      const gy = Math.max(0, Math.min(fh - 1, Math.floor(p.y * p.ratio)))
      ctx.clearRect(0, 0, 1, 1)
      ctx.drawImage(frameProbe, gx, gy, 1, 1, 0, 0, 1, 1)
      const px = ctx.getImageData(0, 0, 1, 1)
      pixelSampler.pending = null
      frameProbe.source = ""
      root._grabResult = null
      if (!px || !px.data || px.data.length < 3) {
        root._sampleFailed()
        return
      }
      const d = px.data
      root.finishPick(d[0], d[1], d[2], d[3], p.gen)
    }
  }

  // --- island ---

  Component {
    id: islandComp

    ColorPickerIsland {
      records: root.records
      addRecord: root.addRecord
      removeRecord: root.removeRecord
      clearAll: root.clearHistory
      promoteRecord: root.promoteRecord
      copyColor: root.copyColor
      // The picker's working state, read once on open and reported on
      // every preview change. See workingState() for why this is not
      // the history's top record.
      workingState: root.workingState
      reportWorking: root.reportWorking
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  Connections {
    target: Bar

    function onEnabledChanged() {
      // The bar going away takes the module with it, so a live pick dies
      // here rather than at teardown.
      if (!Bar.enabled) root.cancelPick()
    }
  }

  // Dock, undock, wakeup: one re-resolution of the live pick's screen.
  Connections {
    target: Ui

    function onValidScreensChanged() {
      root._reconcilePickScreen()
    }
  }

  // --- copy flash ---
  // Builtin, with no setting behind it: the window is the shared one
  // (common/ui/FlashReveal.qml) and the reveal is the same shape the
  // Now Playing track name uses - a real animated 0..1 gating a label
  // inside the pill. Unlike the network/bt flashes the code stays in
  // the plain foreground tone: the color itself is the announcement,
  // so no green blink and no tint of the text with the picked color.
  FlashReveal {
    id: codeFlash
    durationMs: 1500
  }
  // Fullscreen defer: a pick that lands while a fullscreen window owns
  // this screen must not flash under it - the pill would expand over the
  // fullscreen content. The event is parked in _flashPending and replayed
  // when the fullscreen ends, so the announcement lands when the bar is
  // visible again. An in-flight flash cut off by entering fullscreen is
  // parked the same way. The reveal itself never reads fullscreen: while
  // fullscreen is up nothing pulses and nothing shows.
  readonly property bool _fsActive: root.barScreen ? FullscreenProbe.screenActive(root.barScreen.name) : FullscreenProbe.anyActive
  property bool _flashPending: false
  on_FsActiveChanged: {
    if (root._fsActive) {
      // Entering fullscreen with a flash up: park it and take it off
      // screen instead of letting it run under the fullscreen window.
      if (codeFlash.active) {
        if (root.flashText !== "") root._flashPending = true
        codeFlash.clear()
      }
      return
    }
    if (root._flashPending) {
      root._flashPending = false
      if (root.flashText !== "") codeFlash.pulse()
    }
  }
  // Whether the reveal is up. Read by the slide rather than each reading
  // the window on its own: one event - the reveal timer's expiry - flips
  // the collapse, so the pill's collapse and the label's hide stay together.
  readonly property bool revealed: codeFlash.active && root.flashText !== ""
  property real codeSlide: root.revealed ? 1 : 0
  Behavior on codeSlide {
    Glide { duration: Ui.slowMs }
  }

  // --- module surface ---

  // Dynamic pill (the NowPlaying convention): a `codeSlide` real animates
  // 0..1 and the width rounds to whole pixels every frame, so neighbours
  // never sit at a fractional x while the pill grows. `clip` keeps the
  // collapsing label inside the module.
  clip: true
  implicitWidth: Math.round(root.codeSlide > 0 ? pill.width : Bar.iconSlot)

  Item {
    id: pill

    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Bar.iconSlot + root.codeSlide * (Math.min(labelText.implicitWidth, 240) + 4 + Bar.slotInset)
    height: root.height

    Item {
      id: glyph

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Bar.iconSlot
      height: parent.height

      Icon {
        // Centered in the slot when the code is hidden; docked left ahead of
        // the label otherwise (assigned at runtime so the analyzer never sees
        // an illegal left+horizontalCenter combination).
        anchors.left: root.codeSlide > 0 ? parent.left : undefined
        anchors.horizontalCenter: root.codeSlide > 0 ? undefined : parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        name: "droplet"
        colorKey: "foreground_0"
        accentKey: root._tintEnabled && root._lastColor !== "" ? root._lastColor : ""
      }
    }

    Title {
      id: labelText

      anchors.left: glyph.right
      anchors.leftMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      visible: root.codeSlide > 0
      level: 3
      width: Math.min(implicitWidth, 240)
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      text: root.flashText
      elide: Text.ElideRight
    }
  }

  // Strict routing: left picks, middle clears, right opens the island.
  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.LeftButton) {
      root.beginPick("island")
    } else if (mouse.button === Qt.MiddleButton) {
      root.clearHistory()
    } else if (mouse.button === Qt.RightButton) {
      root.openIsland()
    }
  }

  ToolTipBind {
    active: root.hovered
    text: "Click to pick a color"
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  // --- IPC bridge registration ---
  // The module instantiates once per bar window (per monitor), but an
  // IpcHandler target must be unique. The Bar singleton hosts the single
  // `colorPicker` handler; one registered instance owns the verb (the pick
  // runs on that instance's screen). vb-shell colorPicker pick is the
  // keybind surface.
  //
  // Bar.registerPicker is last-writer-wins, so exactly one instance may
  // call it, and the claim is keyed on the primary screen
  // (Ui.validScreens[0]): unique per session, so the owner no longer
  // depends on which instance happened to complete first, and a second
  // instance never registers and so can neither clobber the owner nor
  // clear its registration when it goes away. A primary-screen change
  // hands the claim over - the outgoing owner unregisters, the incoming
  // one registers - and the bar's own Variants load the primary screen's
  // module first, so the claim resolves to the same instance it did with
  // load-order registration.
  readonly property bool _ipcOwner: root.barScreen !== null
    && root.barScreen === Ui.primaryScreen
  on_IpcOwnerChanged: {
    // Exactly one instance owns the verb, and which one moves with the
    // primary screen.
    if (root._ipcOwner) Bar.registerPicker(root)
    else Bar.unregisterPicker(root)
  }

  Component.onCompleted: root._ensureStore()
  Component.onDestruction: {
    // The pick's generation first, like the QR overlay's teardown: a grab,
    // decode or paint issued under it must find the handle already retired
    // when the copies below cancel. A pick interrupted by the module going
    // away would otherwise leave the gate's entry live.
    root._retirePick()
    root._releaseCopies()
    // The screen claim goes with the module: a claim whose owner is being
    // destroyed is dropped rather than fired, so nothing runs against a
    // module that is already gone.
    SurfaceClaim.releaseOwner(root)
    // Drop this output's adoption observation. An output removed while its
    // read is still pending leaves the read to the outputs that are left;
    // if none are, the shared read goes with the last of them and the
    // output created after that reads the document again rather than
    // inheriting an answer nobody saw.
    if (root._storeReader !== null) {
      DocumentAdoption.release(root._storeReader)
      root._storeReader = null
    }
    Bar.unregisterPicker(root)
  }
}

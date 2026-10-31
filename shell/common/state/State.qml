pragma Singleton
pragma ComponentBehavior: Bound
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../text/UnitIpc.js" as UnitIpc

// State - multi-file JSON persistence with coalesced atomic writes and
// watch-driven external change notification. Each slot is a JSON file at
// $VIBRANIUM_STATE/<key>.json (scope "state", default) or
// $VIBRANIUM_CACHE/<key>.json (scope "cache"); a slot may name an
// explicit `file` instead (e.g. the shared "shell" slot lives in
// shell.jsonc). One FileView plus one JsonAdapter per slot: the view owns
// atomic write plus watch plus reload, the adapter owns parse plus
// stringify plus echo suppression. Writes coalesce to one event-loop tick
// via Qt.callLater. Fresh-object reassignment per 8.5 ensures bindings
// re-evaluate on every mutation.
Singleton {
  id: root

  readonly property string tag: "state"

  // Global rev bumped on any slot mutation; slot readers capture it for
  // reactive bindings (mirrors Settings.rev).
  property int rev: 0

  Component.onCompleted: {
    Registry.offer("state", {
      title: "State",
      description: "persisted JSON slots",
      verbNames: ["get", "set", "dump", "status", "help", "ping"]
    })
    // K1: ensure core slots exist at boot even if their consumers are
    // gated/deferred. The shared "shell" slot (shell.jsonc) carries the
    // cursor/weather/update sections; per-file cursor-theme.json is
    // superseded (one-shot import + removal by CursorPicker).
    root.slot("shell", {}, "state", "shell.jsonc")
  }

  Component.onDestruction: Registry.unregister("state")

  IpcHandler {
    target: "state"
    function help(command: string): string {
      return UnitIpc.help("state", "State", "persisted JSON slots", [
        { name: "get", help: "(key) read slot as JSON" },
        { name: "set", help: "(key, json) write slot" },
        { name: "dump", help: "all slots as JSON" },
        { name: "status", help: "health" },
      ], command)
    }
    function status(): string { return JSON.stringify({ unit: "state", healthy: true, slots: Object.keys(root._slots) }) }
    function ping(): string { return "pong" }
    function get(key: string): string {
      const v = root.value(key)
      return v !== null ? JSON.stringify(v) : "null"
    }
    function set(key: string, json: string): string {
      let v
      try { v = JSON.parse(json) } catch (e) { return "error: invalid JSON" }
      return root.set(key, v) ? "ok" : "error"
    }
    function dump(): string {
      const out = {}
      for (const k in root._slots) out[k] = root._slots[k].data
      return JSON.stringify(out)
    }
  }

  // key -> { path, data, defaultValue, view, flushPending }
  // data mirrors the slot adapter payload; view is the single FileView
  // owning atomic writes, watch and reload for that path.
  property var _slots: ({})

  // --- public API ---

  // Ensure slot exists and return its current data. Creates the slot on
  // first call, loads from disk (or default), and watches the file.
  // `file` optionally overrides the "<key>.json" file name.
  function slot(key, defaultValue, scope, file) {
    if (typeof key !== "string" || key === "") {
      return null
    }
    const def = defaultValue !== undefined && defaultValue !== null && typeof defaultValue === "object" && !Array.isArray(defaultValue)
      ? Object.assign({}, defaultValue) : (defaultValue !== undefined ? defaultValue : {})
    if (root._slots[key] !== undefined) {
      return root._slots[key].data
    }
    root._ensureSlot(key, def, scope, file)
    return root._slots[key].data
  }

  // Reactive read: captures rev so bindings re-evaluate when any slot mutates.
  function value(key) {
    root.rev
    const s = root._slots[key]
    return s ? s.data : null
  }

  // Replace slot data wholesale (fresh object); the adapter write follows
  // on the next event-loop tick. Mirror plus rev land synchronously
  // through the adapter payload handler.
  //
  // The written data is never published. A slot holds whatever its consumer
  // wrote, notification bodies and clipboard entries included, so the line
  // claims only that a value arrived and a slot moved.
  function set(key, data) {
    const slot = root._slots[key]
    if (!slot) {
      return false
    }
    const clean = data !== undefined && data !== null && typeof data === "object" && !Array.isArray(data)
      ? Object.assign({}, data) : data
    if (slot.view) {
      slot.view.slotData = clean
    } else {
      const next = Object.assign({}, slot, { data: clean })
      const nextSlots = Object.assign({}, root._slots)
      nextSlots[key] = next
      root._slots = nextSlots
      root.rev++
      root._scheduleFlush(key)
    }
    // "staged", not "saved", and DEBUG rather than INFO. The old line here
    // said "saved the {key} document" and was wrong twice over. Writes are
    // coalesced - set() arms a flush and Qt.callLater writes once - so two
    // deletes in a row printed "saved the shell document" twice while the
    // file was written once. The line claimed a save per staged value, which
    // is the same class of defect as a line that prints for the sake of
    // printing: it reports an event that had not happened yet.
    //
    // The write itself is traced where it happens, in _flush below. What
    // this site is for is the caller having put a value into the store, and
    // the caller already says what it did - "cleared the record of job 23".
    // What was lost was the name of the file, so that is what a reader
    // actually gets: the slot, and where the value now lives.
    //
    // The parent of this DEBUG is the caller's own line - the feature that put
    // the value in the store already said what it did, so the one fact it
    // cannot know is which slot took it. Both halves are bounded because `set`
    // is reachable from the IPC verb of the same name, and a key that arrived
    // over IPC is an argument rather than this tree's own vocabulary.
    Log.debug("staged a value into slot " + Log.summarize(key) + " at "
      + Log.summarize(slot.path))
    return true
  }

  // --- internals ---

  function _ensureSlot(key, defaultValue, scope, file) {
    const dir = scope === "cache" ? Paths.vibraniumCache : Paths.vibraniumState
    const stem = typeof file === "string" && file !== "" ? file : key + ".json"
    const path = dir + "/" + stem

    // Single view per slot: atomic writes, watch, reload. The JsonAdapter
    // child owns JSON parse plus stringify plus echo suppression.
    const view = slotComp.createObject(root, { slotKey: key })
    const def = defaultValue !== undefined ? defaultValue : {}
    const defClone = def !== null && typeof def === "object" && !Array.isArray(def)
      ? Object.assign({}, def) : def
    view.slotData = defClone
    view.path = path

    const nextSlots = Object.assign({}, root._slots)
    nextSlots[key] = {
      path: path,
      data: defClone,
      defaultValue: def,
      view: view,
      flushPending: false
    }
    root._slots = nextSlots

    // Initial load (file may not exist yet); the adapter keeps defaults
    // when the read misses. A missing file never deadlocks: without
    // blockLoading a failed load simply returns false.
    view.waitForJob()
    root._migrateFlat(key)
    root._syncMirror(key)
  }

  // Adopt flat files. A slot document is a JSON object, because that is
  // all JsonAdapter can represent; a file that wraps the payload under
  // "data" is the current shape, and a flat object is adopted
  // wholesale and rewritten wrapped.
  //
  // A document that is not an object at all - a bare array - falls straight
  // through to the adapter, which then refuses it on every single load: the
  // warning repeats forever, the slot stays at the adapter's empty default,
  // and a consumer checking "does this slot have a value" sees a
  // present-but-empty slot and never runs its own adoption. Wrapping it here
  // is shape-agnostic - the store does not know or care what the payload
  // means - and it hands the consumer something it can recognise and migrate.
  function _migrateFlat(key) {
    const slot = root._slots[key]
    if (!slot || !slot.view) return
    let text = ""
    try { text = slot.view.text() } catch (e) { return }
    if (text.trim() === "") return
    let parsed = null
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (parsed === undefined) return
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      // Not an object, so the adapter cannot hold it. Wrap it under the
      // slot's own wrapper key and rewrite the file in the current shape.
      if (parsed === null) return
      slot.view.slotData = { data: parsed }
      root._scheduleFlush(key)
      return
    }
    if (parsed.data !== undefined) return
    if (Object.keys(parsed).length === 0) return
    slot.view.slotData = parsed
    root._scheduleFlush(key)
  }

  // Mirror the adapter payload into the slot entry after the synchronous
  // ensure load; later mutations mirror through _onSlotDataChanged.
  function _syncMirror(key) {
    const slot = root._slots[key]
    if (!slot || !slot.view) return
    const nextSlots = Object.assign({}, root._slots)
    nextSlots[key] = Object.assign({}, slot, { data: slot.view.slotData })
    root._slots = nextSlots
  }

  // Adapter payload changed (local set or external reload): mirror it
  // for the sync readers and bump rev so bindings re-fire.
  function _onSlotDataChanged(key) {
    const slot = root._slots[key]
    if (!slot || !slot.view) return
    const nextSlots = Object.assign({}, root._slots)
    nextSlots[key] = Object.assign({}, slot, { data: slot.view.slotData })
    root._slots = nextSlots
    root.rev++
  }

  // One coalesced write per event-loop tick; rapid sets batch without
  // a debounce Timer.
  //
  // Why not PersistentProperties: one file per property cannot serve
  // slotted multi-file state (shell.jsonc sections, per-scope files),
  // atomic rewrites, the flat-document adoption above, echo suppression
  // or the watch/reload half below. The coalescing here is the whole of
  // what a persistor would add; the rest is what it cannot do.
  function _scheduleFlush(key) {
    const slot = root._slots[key]
    if (!slot || slot.flushPending) return
    const nextSlots = Object.assign({}, root._slots)
    nextSlots[key] = Object.assign({}, slot, { flushPending: true })
    root._slots = nextSlots
    Qt.callLater(() => root._flush(key))
  }

  function _flush(key) {
    const slot = root._slots[key]
    if (!slot) return
    const nextSlots = Object.assign({}, root._slots)
    nextSlots[key] = Object.assign({}, slot, { flushPending: false })
    root._slots = nextSlots
    // Ensure watcher is armed for next external change; FileView with
    // watchChanges fires onFileChanged when the file appears.
    if (slot.view) slot.view.writeAdapter()
    // The write that just landed, and how many slots the store is holding:
    // the count, never a document. Gated because a flush is per coalesced
    // tick and a chatty consumer drives ticks, so the field object is the
    // cost the gate has to remove - and `Object.keys` is that cost exactly,
    // which is why the count is read inside the gate and the list is not
    // printed at all.
    //
    // The parent of this DEBUG is the staged-value line in `set` above, which
    // is itself the tail of the caller's own line: this is the far end of one
    // chain, and it is the only place that can say the coalesced write landed
    // at all - `set` deliberately cannot.
    const d = Log.at()
    if (d.allows("debug")) {
      d.debug("flushed " + Log.summarize(slot.path) + ", "
        + Object.keys(root._slots).length + " slots")
    }
  }

  // Single component for slot views: one FileView plus one JsonAdapter.
  // slotData aliases the adapter payload so handlers stay on the view
  // object that also carries slotKey.
  Component {
    id: slotComp
    FileView {
      property string slotKey: ""
      property alias slotData: slotAdapter.data
      atomicWrites: true
      watchChanges: true
      printErrors: false
      onFileChanged: reload()
      onAdapterUpdated: root._scheduleFlush(slotKey)
      onLoadFailed: root._scheduleFlush(slotKey)
      onSlotDataChanged: root._onSlotDataChanged(slotKey)
      JsonAdapter {
        id: slotAdapter
        property var data: ({})
      }
    }
  }
}

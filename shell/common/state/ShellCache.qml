pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import qs.common

// ShellCache - one general JSON cache file owned by the whole shell:
// $VIBRANIUM_CACHE/shell.json, namespaced by section
// ({"audio": {"boostedVolume": 1.5}, ...}).
//
// Thin synchronous facade over AppState's "cache"-scoped slot, which
// owns the debounced atomic writes, echo suppression and watching -
// consumers here never touch files or spawn processes. Sections are
// plain objects created on first write; unknown sections read as null.
Singleton {
  id: root

  readonly property string tag: "shellCache"

  // AppState slot backing this cache. Distinct from ShellState's
  // "shell" slot: State keys slots by bare key, so a shared key makes
  // the second ensure a no-op and cache writes land in shell.jsonc.
  // The key therefore names the store, not the file, and the file name
  // below is the one that reaches the disk.
  readonly property string slotKey: "shell-cache"

  // File this cache lives in. Same name as ShellState's document in a
  // different scope: state is durable, a cache is not, so the two must
  // not share a path. Naming it explicitly keeps the two facades
  // independent of each other's slot key.
  readonly property string fileName: "shell.json"

  // One-shot migration flag for pre-split shell.jsonc contents.
  property bool _migrated: false

  // Ensure the backing slot exists (idempotent - first call creates
  // and loads it, later calls are a map hit).
  function _ensure() {
    AppState.slot(root.slotKey, {}, "cache", root.fileName)
    root._migrateFromState()
  }

  // Adopt cache sections stranded in shell.jsonc by the pre-split
  // shared slot key. Runs once; fills only absent sections so a live
  // cache file always wins over the stale state copy. Source sections
  // are removed only after the cache write is accepted.
  function _migrateFromState() {
    if (root._migrated) return
    root._migrated = true
    AppState.slot("shell", {}, "state", "shell.jsonc")
    const stateData = AppState.value("shell")
    if (stateData === null || typeof stateData !== "object" || Array.isArray(stateData)) return
    const hasAudio = stateData.audio !== undefined
    const hasArch = stateData.archUpdates !== undefined
    if (!hasAudio && !hasArch) return
    const cur = AppState.value(root.slotKey)
    const base = cur !== null && typeof cur === "object" && !Array.isArray(cur) ? cur : {}
    const next = Object.assign({}, base)
    if (hasAudio && next.audio === undefined) next.audio = stateData.audio
    if (hasArch && next.archUpdates === undefined) next.archUpdates = stateData.archUpdates
    if (!AppState.set(root.slotKey, next)) return
    const sCur = AppState.value("shell")
    const sBase = sCur !== null && typeof sCur === "object" && !Array.isArray(sCur) ? sCur : {}
    const sNext = Object.assign({}, sBase)
    delete sNext.audio
    delete sNext.archUpdates
    AppState.set("shell", sNext)
  }

  // Reactive section read: captures AppState.rev so bindings follow
  // writes. Returns the section object, or null when absent.
  function section(name) {
    root._ensure()
    const s = AppState.value(root.slotKey)
    const v = s ? s[String(name)] : undefined
    return v !== undefined ? v : null
  }

  // Replace a section wholesale and schedule a debounced flush.
  // Returns false when the name is unusable.
  function setSection(name, obj) {
    if (typeof name !== "string" || name === "") {
      return false
    }
    root._ensure()
    const cur = AppState.value(root.slotKey)
    const base = cur !== null && typeof cur === "object" && !Array.isArray(cur) ? cur : {}
    const next = Object.assign({}, base)
    next[name] = obj !== undefined && obj !== null && typeof obj === "object" && !Array.isArray(obj)
      ? Object.assign({}, obj) : obj
    return AppState.set(root.slotKey, next)
  }

  // Shallow-merge `patch` into a section (created when absent).
  function updateSection(name, patch) {
    if (typeof name !== "string" || name === "") {
      return false
    }
    if (!patch || typeof patch !== "object" || Array.isArray(patch)) {
      return false
    }
    root._ensure()
    const cur = root.section(name)
    const base = cur !== null && typeof cur === "object" && !Array.isArray(cur) ? cur : {}
    return root.setSection(name, Object.assign({}, base, patch))
  }

  // Numeric field read with fallback: validated finite number or
  // `fallback` otherwise. Audio's restore level reads through here.
  function number(sectionName, field, fallback) {
    const s = root.section(sectionName)
    const v = s ? Number(s[String(field)]) : NaN
    const fb = typeof fallback === "number" && isFinite(fallback) ? fallback : 0
    return isFinite(v) ? v : fb
  }
}

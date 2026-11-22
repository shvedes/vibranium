pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common

// Disabled builtin wallpapers.
//
// A shipped theme's images live in the read-only install tree, so removing
// one is a record rather than a file deletion. This store keeps one
// "<theme>/<basename>" key per disabled image in
// $VIBRANIUM_STATE/hidden-wallpapers.json, and every wallpaper surface treats
// a listed key as absent. The file is the user's to edit: restoring a
// wallpaper means deleting its key, which the watcher below picks up live.
//
// Document shape (one object, because JsonAdapter holds objects):
//   { "hidden": ["<theme>/<basename>", ...] }
Singleton {
  id: root

  readonly property string tag: "hiddenWallpapers"

  // Sorted, unique keys. The file is canonical: hide()/show() write it and
  // _adopt() is the only publisher of this mirror. A listing built from it
  // recomputes on the replacement, which happens only on a real key change.
  property var _hidden: []

  // Bumped once by _adopt() when the normalized keys really change.
  property int rev: 0

  Component.onCompleted: {
    // The first listing must not race the read: with no keys loaded yet every
    // builtin looks enabled.
    storeView.waitForJob()
    root._adopt()
  }

  FileView {
    id: storeView

    path: Paths.hiddenWallpapersJson
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root._adopt()
    onLoadFailed: root._adopt()
    onFileChanged: storeView.reload()

    JsonAdapter {
      id: storeAdapter

      property var hidden: []
    }
  }

  function key(theme, file): string {
    const t = String(theme ?? "").trim()
    const f = String(file ?? "").trim()
    // A key is exactly two segments: the theme, then one basename. A file
    // that could add a segment is not a wallpaper this store can describe.
    if (t === "" || f === "" || t.indexOf("/") >= 0 || f.indexOf("/") >= 0) return ""
    return t + "/" + f
  }

  function isHidden(theme, file): bool {
    const k = root.key(theme, file)
    return k !== "" && root._hidden.indexOf(k) >= 0
  }

  // Records one disabled wallpaper. False means the key was already there or
  // could not be built, so a caller never announces a change that did not
  // happen. The file is the source: the watch publishes the mirror through
  // _adopt() when the write lands.
  function hide(theme, file): bool {
    const k = root.key(theme, file)
    if (k === "" || root._hidden.indexOf(k) >= 0) return false
    const next = root._hidden.concat([k]).sort()
    storeAdapter.hidden = next
    storeView.writeAdapter()
    return true
  }

  // Removes one key, restoring a disabled shipped wallpaper. False means it
  // was not disabled or the key could not be built, so a caller never
  // announces a restore that did not happen.
  function show(theme, file): bool {
    const k = root.key(theme, file)
    if (k === "") return false
    const at = root._hidden.indexOf(k)
    if (at < 0) return false
    const next = root._hidden.slice()
    next.splice(at, 1)
    storeAdapter.hidden = next
    storeView.writeAdapter()
    return true
  }

  // One publisher for the mirror. A watch echo carries the same keys that are
  // already published (and a hand edit of unrelated fields does the same), so
  // publishing on every load would bump rev without a change behind it.
  function _adopt() {
    const next = root._normalize(storeAdapter.hidden)
    const cur = root._hidden
    let same = next.length === cur.length
    if (same) {
      for (let i = 0; i < next.length; i++) {
        if (next[i] !== cur[i]) { same = false; break }
      }
    }
    if (same) return
    root._hidden = next
    root.rev++
  }

  // A JSON array read back through JsonAdapter is a C++ sequence, not a JS
  // array: `Array.isArray` is false for exactly the value this store loads from
  // disk, so treating only real arrays as lists emptied the set on every shell
  // start. Length and indexing accept both shapes.
  function _asList(raw): var {
    if (raw === null || raw === undefined) return []
    if (Array.isArray(raw)) return raw
    if (typeof raw !== "object") return []
    const n = raw.length
    if (typeof n !== "number" || n < 0) return []
    const out = []
    for (let i = 0; i < n; i++) out.push(raw[i])
    return out
  }

  // Only strings that already name a theme and a basename survive: the file is
  // user-editable, and a malformed entry must not act as a prefix that hides
  // something else.
  function _normalize(raw): var {
    const out = []
    const seen = Object.create(null)
    const list = root._asList(raw)
    for (let i = 0; i < list.length; i++) {
      const k = String(list[i] ?? "").trim()
      if (k === "") continue
      const slash = k.indexOf("/")
      if (slash <= 0 || slash === k.length - 1) continue
      if (k.indexOf("/", slash + 1) >= 0) continue
      if (seen[k] === true) continue
      seen[k] = true
      out.push(k)
    }
    return out.sort()
  }
}

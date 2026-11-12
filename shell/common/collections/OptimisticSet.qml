import QtQml
import "EntryMap.js" as EntryMap

// OptimisticSet - pendingDeletes pattern for Clipboard + WallpaperPicker.
// Instances per consumer: Clipboard.optimistic and WallpaperPicker.optimistic
// mark(key): key joins pending, isPending bindings update
// confirm(key): drop + signal settled
// cancel(key): drop
// property var pending: fresh-object map per mutation (8.5 discipline)
QtObject {
  id: root

  property var pending: ({})

  function isPending(key) {
    return root.pending[key] !== undefined
  }

  function mark(key) {
    if (!key || root.pending[key] !== undefined) return false
    root.pending = EntryMap.withEntry(root.pending, key, true)
    return true
  }

  function confirm(key) {
    if (!key || root.pending[key] === undefined) return false
    root.pending = EntryMap.withoutEntry(root.pending, key)
    root.settled(key)
    return true
  }

  function cancel(key) {
    if (!key || root.pending[key] === undefined) return false
    root.pending = EntryMap.withoutEntry(root.pending, key)
    return true
  }

  signal settled(string key)
}

import QtQml
import "EntryMap.js" as EntryMap

// OptimisticSet - pendingDeletes pattern for Clipboard + WallpaperPicker.
// Instances per consumer: Clipboard.optimistic and WallpaperPicker.optimistic
// mark(key): key joins pending, isPending bindings update
// confirm(key): drop + signal settled
// cancel(key): drop
// property var pending: null-prototype map, replaced on every mutation
// Membership is an own-property test: Object.prototype names such as
// "constructor" or "__proto__" must never read as pending.
QtObject {
  id: root

  property var pending: Object.create(null)

  function isPending(key) {
    return Object.prototype.hasOwnProperty.call(root.pending, key)
  }

  function mark(key) {
    if (!key || Object.prototype.hasOwnProperty.call(root.pending, key)) return false
    root.pending = EntryMap.withEntry(root.pending, key, true)
    return true
  }

  function confirm(key) {
    if (!key || !Object.prototype.hasOwnProperty.call(root.pending, key)) return false
    root.pending = EntryMap.withoutEntry(root.pending, key)
    root.settled(key)
    return true
  }

  function cancel(key) {
    if (!key || !Object.prototype.hasOwnProperty.call(root.pending, key)) return false
    root.pending = EntryMap.withoutEntry(root.pending, key)
    return true
  }

  signal settled(string key)
}

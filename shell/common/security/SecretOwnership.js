.pragma library

.import "../collections/StoreGuards.js" as StoreGuards

// Secret handle ownership: the tracking list an owner keeps beside
// SecretStore.
//
// A facade or controller that stashes credential values remembers the handles
// it owns so it can release them on destruction, on a failed transport, or when
// a child exits before the value went out. That list is a QML `property var`,
// so it can only change by reassignment; these helpers return new arrays and
// never mutate the one handed in.
//
// The store is a parameter rather than an import so the ownership rules stay
// pure and node-testable - the QML singleton that owns the slots is not. The
// guards are unified here: null and undefined mean the empty handle, an empty
// handle is a no-op that returns a copy of the list, and a real handle is
// compared in string form because the list only holds the strings stash()
// accepted.

function _key(handle) {
  return handle === undefined || handle === null ? "" : String(handle)
}

function _copy(handles) {
  return StoreGuards.copyList(handles)
}

// Remove `handle` from the tracking list without touching the store. This is
// the "the value already left through feed()" path.
function untrack(handles, handle) {
  const key = _key(handle)
  const owned = _copy(handles)
  if (key === "") return owned
  return owned.filter(function (entry) { return entry !== key })
}

// Drop the value and stop tracking the handle. A handle whose value already
// left through the write channel is a no-op in the store, so every terminal
// path can call this without knowing which one ran.
function forget(store, handles, handle) {
  const key = _key(handle)
  if (key === "") return _copy(handles)
  if (store && typeof store.drop === "function") store.drop(key)
  return untrack(handles, key)
}

// Release every tracked value, returning the emptied list to assign back.
function releaseAll(store, handles) {
  const owned = _copy(handles)
  if (store && typeof store.drop === "function") {
    for (let i = 0; i < owned.length; i++) store.drop(_key(owned[i]))
  }
  return []
}

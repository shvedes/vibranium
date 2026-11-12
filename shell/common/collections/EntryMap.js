.pragma library

// Copy-on-write mutation for maps held in a QML `property var`.
//
// A QML property notifies only when the property itself is assigned, so a
// store that wants an observing binding to re-read must replace its map rather
// than write into it. Both state singletons that keep a per-path record apply
// the same rule; this is the one spelling of that copy.
//
// A missing or non-object map reads as empty, so a first write after a reset
// does not throw into a change handler.
function withEntry(entries, key, entry) {
  const base = entries !== null && typeof entries === "object" ? entries : {}
  const next = Object.assign({}, base)
  next[key] = entry
  return next
}

// The same rule for a removal. A map that does not hold the key answers a
// copy of itself, so a caller can assign the result unconditionally and a
// binding still sees a new value.
function withoutEntry(entries, key) {
  const base = entries !== null && typeof entries === "object" ? entries : {}
  const next = Object.assign({}, base)
  delete next[key]
  return next
}

// Handle-list arithmetic for a refcounted entry store.
//
// A store's `handles` array IS its reference count: one element per
// observation, appended when a consumer takes the entry and dropped when it
// lets go. Five singletons keep that count - file presence, document
// adoption, the audio node holds, the battery alert and the peak monitors -
// and the part that has to agree between them is the release: it answers
// whether an observation was actually dropped, and a handle the entry never
// held must not read as a drop.
//
// `attachHandle` answers a NEW array, because the entry is published and a
// reader that captured the old one must not see it change underneath.
// `detachHandle` answers the new array, or null when the handle was not
// there - so a miss allocates nothing, which the filter spelling it replaces
// did on every call.
function attachHandle(handles, handle) {
  const base = Array.isArray(handles) ? handles : []
  return base.concat([handle])
}

function detachHandle(handles, handle) {
  if (!Array.isArray(handles)) return null
  const at = handles.indexOf(handle)
  if (at < 0) return null
  const next = handles.slice()
  next.splice(at, 1)
  return next
}

function hasHandle(handles, handle) {
  return Array.isArray(handles) && handles.indexOf(handle) >= 0
}

// The observation count of an entry, with a missing list reading as none.
function handleCount(handles) {
  return Array.isArray(handles) ? handles.length : 0
}

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

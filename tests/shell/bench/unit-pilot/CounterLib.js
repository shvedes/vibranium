.pragma library

// Shared per-engine completion counter for the inertness probe. A .pragma
// library instance is shared by every importer, so the probe can read a count
// without touching (and thereby constructing) either singleton under test.
var counts = Object.create(null)

function bump(id) {
  counts[id] = (counts[id] || 0) + 1
}

function get(id) {
  return counts[id] || 0
}

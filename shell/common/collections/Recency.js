.pragma library

// Keys ordered by a recency stamp, least recent first.
//
// Both collection stores keep a per-entry clock - BoundedCache's `stamp` on
// a write or read, FrozenFootprint's `touch` on a save - and both expose
// their live keys in that order. The comparator is the same rule in both
// places, including the tiebreak: equal stamps order by key so the listing
// is stable instead of depending on object insertion order.
//
// `entries` is the store's own null-prototype map; `field` names its clock.
// A missing entry reads as stamp 0, so a malformed store still sorts rather
// than turning every comparison into NaN.
function keysBy(entries, field) {
  if (entries === null || entries === undefined) return []
  return Object.keys(entries).sort(function (a, b) {
    const ea = entries[a] || {}
    const eb = entries[b] || {}
    const delta = (ea[field] || 0) - (eb[field] || 0)
    if (delta !== 0) return delta
    return a < b ? -1 : 1
  })
}

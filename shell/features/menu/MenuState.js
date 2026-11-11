.pragma library

// Per-item runtime state, as pure functions over plain objects.
//
// The menu singleton owns the store, the revision counter and the slot-close
// timers. What it does not own is the shape of an item's first record or the
// copy-on-write rule the close latch follows - those are pure, and they live
// here so they can be driven without a shell.

// The state an unseated or unknown row reads as. A fresh object every call:
// stateOf hands out a copy so dependents always see a change.
function blankState() {
  return { checked: false, value: "", expanded: false, info: false }
}

// The record an item starts with. `live(varName)` answers the store value for
// a bound row; a toggle takes it as `checked`, every other type as `value`.
// The lookup stays a parameter because the three stores behind it - settings,
// hypr, misc - are the caller's business, not this module's.
function initialState(item, live) {
  let checked = item.checked_ === true
  let value = item.value !== undefined ? item.value : ""
  if (item.var !== "") {
    const seen = live(String(item.var))
    if (item.type === "toggle") checked = seen === true
    else if (seen !== undefined) value = seen
  }
  return { checked: checked, value: value, expanded: false, info: false }
}

// Copy-on-write close latch. The map is replaced, not mutated, so a binding
// that reads it re-evaluates on assignment.
function withSlotClose(map, uid, closing) {
  const next = Object.assign({}, map)
  if (closing) next[uid] = true
  else delete next[uid]
  return next
}

// Drop one row's latch. Returns the same map when there was nothing to drop,
// so a no-op close does not churn every reader.
function withoutSlotClose(map, uid) {
  if (map[uid] === undefined) return map
  const next = Object.assign({}, map)
  delete next[uid]
  return next
}

// A close latch belongs to a row the model still lists. `candidate` is the
// authoritative next model, so anything pruned here has no delegate left to
// report its close.
// Returns the same map when nothing was pruned, so the caller can skip the
// assignment (and the re-evaluation it would cause) on the common install.
function pruneSlotCloses(map, candidate) {
  const rows = Array.isArray(candidate) ? candidate : []
  const keep = {}
  for (let i = 0; i < rows.length; i++) {
    const uid = rows[i] ? rows[i].uid : ""
    if (uid) keep[uid] = true
  }
  const next = {}
  let changed = false
  for (const uid in map) {
    if (keep[uid]) next[uid] = true
    else changed = true
  }
  return changed ? next : map
}

// Frozen island card footprints: the last live content size per opener
// slot id, bounded and evicted least recently used.
//
// IslandHost is a PanelWindow, so qmltestrunner cannot load it and the map
// could not be unit-driven from there. The map lives here instead: pure JS,
// .pragma library, no Qt imports, numbers only. No QML Item is read,
// returned or retained, so the store survives in a plain .js test harness
// (tests/shell/suites/js/collections.test.mjs) exactly as it does in
// Quickshell's engine.
//
// Copy on write: every accepted save returns a NEW store with a fresh
// entries object, so a QML property binding on the store observes the
// swap. An in-place write would leave a Slot.x-style dependent reading
// the map it already read. The previous store is never mutated.
//
// Capacity: entries are per opener slot id, and the bar exposes fewer
// module slots than the bound, so eviction only starts once a layout
// churn has retired more ids than the bar has slots.

.pragma library

// Internal alongside the public surface: .pragma library exposes every
// top-level function to importers, not just the documented one.
function _capacityOf(value) {
  if (typeof value !== "number" || !isFinite(value))
    return 1
  const n = Math.floor(value)
  return n >= 1 ? n : 1
}

function _store(value) {
  return value !== null && typeof value === "object" ? value : null
}

function _entries(value) {
  const s = _store(value)
  return s && s.entries && typeof s.entries === "object" ? s.entries : null
}

function _key(value) {
  return typeof value === "string" && value.length > 0
}

function _dimension(value) {
  // typeof NaN is "number" and isFinite coerces, so both are checked
  // against a numeric typeof first.
  return typeof value === "number" && isFinite(value) && value > 0
}

function _entry(value, key) {
  const entries = _entries(value)
  if (entries === null || !_key(key))
    return null
  if (!Object.prototype.hasOwnProperty.call(entries, key))
    return null
  return entries[key]
}

// Least recently used eviction, with the key just saved exempt: the
// entry an open island is reading is never the victim of its own save.
// Runs on every accepted save, so a key loop cannot grow the store past
// the bound.
function _trim(store, keep) {
  const ids = Object.keys(store.entries)
  const drop = ids.length - store.capacity
  if (drop <= 0)
    return { store: store, evicted: [] }
  const ordered = ids.slice().sort((a, b) => {
    const delta = store.entries[a].touch - store.entries[b].touch
    if (delta !== 0)
      return delta
    return a < b ? -1 : 1
  })
  const entries = Object.assign(Object.create(null), store.entries)
  const evicted = []
  for (let i = 0; i < ordered.length && evicted.length < drop; i++) {
    if (ordered[i] === keep)
      continue
    delete entries[ordered[i]]
    evicted.push(ordered[i])
  }
  return {
    store: { capacity: store.capacity, entries: entries, touch: store.touch },
    evicted: evicted
  }
}

function _rejected(store, code) {
  return { ok: false, code: code, store: store, dimensionsChanged: false, evicted: [] }
}

// An empty store with a normalized bound. A capacity that is not a usable
// positive integer falls back to 1: a store with no bound at all is the
// unbounded map this library exists to remove.
function create(capacity) {
  return { capacity: _capacityOf(capacity), entries: Object.create(null), touch: 0 }
}

function capacity(store) {
  const s = _store(store)
  return s !== null && typeof s.capacity === "number" ? s.capacity : 0
}

function count(store) {
  const entries = _entries(store)
  return entries === null ? 0 : Object.keys(entries).length
}

function validKey(key) {
  return _key(key)
}

// A footprint dimension must be a finite positive number. Zero, negative
// and non-finite sizes are refused by save() so a collapsed measurement
// can never be frozen into the map.
function validDimension(value) {
  return _dimension(value)
}

function has(store, key) {
  return _entry(store, key) !== null
}

function w(store, key) {
  const e = _entry(store, key)
  return e === null ? 0 : e.w
}

function h(store, key) {
  const e = _entry(store, key)
  return e === null ? 0 : e.h
}

// The most recently saved key, "" on an empty store.
function activeKey(store) {
  const entries = _entries(store)
  if (entries === null)
    return ""
  const ids = Object.keys(entries)
  let best = ""
  let bestTouch = -1
  for (let i = 0; i < ids.length; i++) {
    const touch = entries[ids[i]].touch
    if (touch > bestTouch || (touch === bestTouch && ids[i] < best)) {
      best = ids[i]
      bestTouch = touch
    }
  }
  return best
}

// Live keys, least recently saved first.
function keys(store) {
  const entries = _entries(store)
  if (entries === null)
    return []
  return Object.keys(entries).sort((a, b) => {
    const delta = entries[a].touch - entries[b].touch
    if (delta !== 0)
      return delta
    return a < b ? -1 : 1
  })
}

// Record the live size of one opener slot. Every accepted save refreshes
// that key's recency, so an unchanged size still returns a new store: a
// slot that is reopened often stays recent enough not to be evicted, and
// the swap only makes a binding re-read the same numbers.
//
// The store argument must be a create() product (or one it returned) -
// that is a shared-call contract, not an access boundary, because a
// .pragma library exposes every top-level function to importers.
function save(store, key, width, height) {
  const base = _store(store) !== null ? store : create(1)
  if (!_key(key))
    return _rejected(base, "invalid_key")
  if (!_dimension(width))
    return _rejected(base, "invalid_width")
  if (!_dimension(height))
    return _rejected(base, "invalid_height")

  const previous = _entry(base, key)
  const touch = (base.touch || 0) + 1
  const entries = Object.assign(Object.create(null), base.entries)
  entries[key] = { w: width, h: height, touch: touch }
  const trimmed = _trim({ capacity: base.capacity, entries: entries, touch: touch }, key)
  return {
    ok: true,
    code: "",
    store: trimmed.store,
    dimensionsChanged: previous === null || previous.w !== width || previous.h !== height,
    evicted: trimmed.evicted
  }
}

// Drop every entry, keeping the bound.
function clear(store) {
  return create(_store(store) !== null ? store.capacity : 1)
}

function diagnostics(store) {
  return {
    count: count(store),
    capacity: capacity(store),
    active: activeKey(store),
    keys: keys(store)
  }
}

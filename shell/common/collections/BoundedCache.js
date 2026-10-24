// Bounded least-recently-used value map, mutated in place.
//
// The bound is the mechanism this library exists to provide. An unbounded
// memo of a resolved resource grows for the life of the process - one
// entry per combination of the inputs that produced it - so a session
// that walks through themes, palettes and caller-supplied variants pays
// for every combination it ever passed through and releases none of
// them. Here an entry is dropped oldest-use-first once the capacity is
// exceeded, and the capacity is a field a caller reads rather than
// believes.
//
// Mutation is in place, deliberately, and that is the one place this
// differs from FrozenFootprint's copy-on-write store. The usual owner is
// a QML `property var` that caller bindings read while they evaluate -
// Icons.url() writes into this map from inside a binding - so replacing
// the map object would notify the very bindings that are mid-evaluation
// and loop. A QML property emits only when the property itself is
// assigned, so structural writes here notify nobody. The cost is that
// nothing bound to the map can observe a change to it: size and
// diagnostics are functions for that reason, not properties.
//
// Recency is a per-entry stamp from a monotonic clock, refreshed by every
// read and every write, so the working set of a caller that re-reads what
// it uses stays resident and a caller that moves on loses its entries
// first. The entry just written is exempt from its own eviction: capacity
// one is a working cache of the current key, not a cache that discards
// every write.
//
// Values and keys are opaque to the map: it never inspects, copies or
// mutates what it stores. Keys must be non-empty strings and values must
// not be undefined, so a miss and a stored value are distinguishable
// without a sentinel - a caller can use the result of a read directly.
//
// .pragma library with no imports, so the capacity, the recency order and
// the diagnostics stay unit-drivable from a plain .js harness as well as
// from Quickshell's engine.

.pragma library

// Internal alongside the public surface: .pragma library exposes every
// top-level function to importers, not just the documented ones.
function _capacityOf(value) {
  if (typeof value !== "number" || !isFinite(value))
    return 1
  const n = Math.floor(value)
  return n >= 1 ? n : 1
}

function _isCache(value) {
  return value !== null && typeof value === "object" && _entries(value) !== null
}

function _entries(value) {
  if (value === null || typeof value !== "object")
    return null
  const entries = value.entries
  return entries !== null && typeof entries === "object" ? entries : null
}

function _count(value) {
  return typeof value === "number" ? value : 0
}

function _key(value) {
  return typeof value === "string" && value.length > 0
}

function _slot(cache, key) {
  const entries = _entries(cache)
  if (entries === null || !_key(key))
    return null
  if (!Object.prototype.hasOwnProperty.call(entries, key))
    return null
  return entries[key]
}

// Drop the least recently used entries until the map is back within its
// capacity, never the entry just written. Enough victims always exist:
// one key beyond the capacity leaves at least one candidate that is not
// the exempt key, because the capacity is at least one.
function _evict(cache, keep) {
  const over = _count(cache.size) - _count(cache.capacity)
  if (over <= 0)
    return
  const entries = _entries(cache)
  const ordered = Object.keys(entries).sort((a, b) => {
    const delta = entries[a].stamp - entries[b].stamp
    if (delta !== 0)
      return delta
    return a < b ? -1 : 1
  })
  let dropped = 0
  for (let i = 0; i < ordered.length && dropped < over; i++) {
    if (ordered[i] === keep)
      continue
    delete entries[ordered[i]]
    dropped += 1
  }
  cache.size = _count(cache.size) - dropped
  cache.evictions = _count(cache.evictions) + dropped
}

// An empty map with a normalized capacity. A capacity that is not a
// usable positive integer falls back to one: a map with no bound at all
// is the unbounded memo this library exists to remove.
function create(capacity) {
  return {
    capacity: _capacityOf(capacity),
    size: 0,
    clock: 0,
    hits: 0,
    misses: 0,
    stores: 0,
    evictions: 0,
    entries: Object.create(null)
  }
}

function capacity(cache) {
  return _isCache(cache) ? _count(cache.capacity) : 0
}

function size(cache) {
  return _isCache(cache) ? _count(cache.size) : 0
}

// Store one value, refreshing that key's recency, and drop the least
// recently used entries if the write took the map past its capacity.
// Returns whether the value was stored: a key that is not a non-empty
// string is refused and leaves the map exactly as it was.
function put(cache, key, value) {
  if (!_isCache(cache) || !_key(key) || value === undefined)
    return false
  const known = _slot(cache, key) !== null
  cache.entries[key] = { value: value, stamp: ++cache.clock }
  if (!known) {
    cache.size = _count(cache.size) + 1
    cache.stores = _count(cache.stores) + 1
    _evict(cache, key)
  }
  return true
}

// Read one value and mark it most recently used, or undefined when the
// key is absent or unusable. The recency write is the only mutation a
// read performs, and it is in place, so a caller may read on a hot path
// without notifying a binding.
function get(cache, key) {
  if (!_isCache(cache))
    return undefined
  const slot = _slot(cache, key)
  if (slot === null) {
    cache.misses = _count(cache.misses) + 1
    return undefined
  }
  slot.stamp = ++cache.clock
  cache.hits = _count(cache.hits) + 1
  return slot.value
}

// Membership without recency and without the read counters, for a caller
// that asks whether an entry exists rather than reading it.
function has(cache, key) {
  return _slot(cache, key) !== null
}

// Drop one entry, keeping the capacity, the clock and the counters. Answers
// whether an entry was actually dropped, so a caller can tell "removed" from
// "was not there": an unknown key, a non-key and a non-cache all answer
// false. The recency clock is left alone - removal is not a use - and the
// cumulative stores/hits/misses are history, not contents, so they stand.
function remove(cache, key) {
  if (!_isCache(cache) || !_key(key))
    return false
  const entries = _entries(cache)
  if (!Object.prototype.hasOwnProperty.call(entries, key))
    return false
  delete entries[key]
  cache.size = _count(cache.size) - 1
  return true
}

// Drop every entry, keeping the capacity, the clock and the counters. The
// map object itself is kept so an owner holding a reference does not have
// to re-bind anything.
function clear(cache) {
  if (!_isCache(cache))
    return cache
  cache.size = 0
  cache.entries = Object.create(null)
  return cache
}

// Live keys, least recently used first.
function keys(cache) {
  const entries = _entries(cache)
  if (entries === null)
    return []
  return Object.keys(entries).sort((a, b) => {
    const delta = entries[a].stamp - entries[b].stamp
    if (delta !== 0)
      return delta
    return a < b ? -1 : 1
  })
}

// What the map holds right now, so a caller can read the bound instead of
// trusting that one exists. The counts are cumulative for the life of the
// map; `size` and `keys` describe the current contents.
function diagnostics(cache) {
  if (!_isCache(cache))
    return { size: 0, capacity: 0, hits: 0, misses: 0, stores: 0, evictions: 0, keys: [] }
  return {
    size: _count(cache.size),
    capacity: _count(cache.capacity),
    hits: _count(cache.hits),
    misses: _count(cache.misses),
    stores: _count(cache.stores),
    evictions: _count(cache.evictions),
    keys: keys(cache)
  }
}

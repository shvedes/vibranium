.pragma library

// Guards shared by the bounded stores.
//
// BoundedCache and FrozenFootprint both normalize a capacity to a positive
// integer and both accept only a non-empty string as a key. A store with no
// usable bound is the unbounded map these libraries exist to remove, so the
// fallback is one rather than zero.

function capacityOf(value) {
  if (typeof value !== "number" || !isFinite(value)) return 1
  const n = Math.floor(value)
  return n >= 1 ? n : 1
}

function isKey(value) {
  return typeof value === "string" && value.length > 0
}

// A value that can be treated as a record: a non-null object that is not an
// array. The settings sections, the cached payloads and the bus replies all
// ask this before copying or reading a field, and stating it once keeps
// "null", "array" and "undefined" from being three different answers.
function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}


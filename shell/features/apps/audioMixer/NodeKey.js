.pragma library

// The join key between a PipeWire node and everything keyed by it.
//
// A node id arrives as a number from the C++ object and as text from the
// `pw-link`/`pactl` parsers, and both forms name the same node. The graph tab
// and the mixer both key their lookups by the decimal string, so the
// normalization lives here rather than in two functions that must agree for
// the two views to point at the same stream.
//
// "" for a node without a usable id: an unkeyable node cannot be looked up,
// and a guessed key would move the wrong stream.
function of(node) {
  if (node === null || node === undefined) return ""
  let id = null
  try {
    id = node.id
  } catch (ignored) {
    return ""
  }
  if (typeof id === "string") {
    return /^\d+$/.test(id.trim()) ? id.trim() : ""
  }
  if (typeof id !== "number" || !isFinite(id) || id < 0) return ""
  return String(Math.round(id))
}

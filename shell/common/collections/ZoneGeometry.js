// Pure row geometry for a bar zone.
//
// Consumes stable slot ids, a kind per id, numeric widths, grow factors
// and caller-injected predicates; returns only numbers, indices and
// candidate arrays. A row is identified by its slot id, so the same
// lookup serves every consumer, and a width is a plain number the caller
// captured - this module never reads, returns or retains a QML Item, and
// knows nothing about bars, modules, settings or screens. The id ->
// delegate association, the drag working list and every placement
// predicate stay in the caller, exactly as BarLib's drop policy stays in
// BarLib.
//
// .pragma library with no imports, so it is unit-drivable under any JS
// host and the row math is testable without a scene.

.pragma library

// Row key: kind and id together, so a kind flip is a distinct row even
// for the same id.
function slotKey(kind, id) {
  return kind + ":" + id
}

// Ordered slot widths for an ordered id array: one width per id, in the
// supplied order, 0 where the caller's map has no width for that row.
function orderedWidths(ids, kinds, widths) {
  const out = new Array(ids.length)
  for (let i = 0; i < ids.length; i++) {
    const w = widths[slotKey(kinds[i], ids[i])]
    out[i] = w === undefined ? 0 : w
  }
  return out
}

// Prefix x positions for an ordered width array: entry i is the row x of
// slot i and the last entry is the row total, so a slot's x is one index
// read with no accumulation and no second pass.
function prefixX(widths) {
  const out = new Array(widths.length + 1)
  out[0] = 0
  for (let i = 0; i < widths.length; i++)
    out[i + 1] = out[i] + widths[i]
  return out
}

// Total width of an ordered width array.
function totalWidth(widths) {
  let total = 0
  for (let i = 0; i < widths.length; i++) total += widths[i]
  return total
}

// Row index of every id in an ordered id array, as a null-prototype table
// for a caller that resolves a row on every layout read instead of once per
// rebuild. A duplicate id keeps its last index, because the loop overwrites
// each key as it goes.
function rowIndexMap(ids) {
  const out = Object.create(null)
  for (let i = 0; i < ids.length; i++) out[ids[i]] = i
  return out
}

// Drop candidates in row coordinates: one { x, width, index } per movable
// row, in row order, where x is the row's left edge, width its extent and
// index its position in the caller's drag working list (-1 when the id is
// absent from it). A row the injected isFixed predicate rejects advances
// the row x without offering a gap, so a pin wall stays off limits while
// still occupying its space. The shape is what a drop-target chooser
// consumes unchanged.
function dropCandidates(ids, widths, prefix, workIds, isFixed) {
  const out = []
  for (let i = 0; i < ids.length; i++) {
    if (isFixed(ids[i]) === true) continue
    out.push({
      x: prefix[i],
      width: widths[i],
      index: workIds ? workIds.indexOf(ids[i]) : -1
    })
  }
  return out
}

// Invalidation signature over everything the row geometry depends on: the
// ordered membership, the per-slot widths, the grow factors and the drag
// snapshot's revision. A geometry revision may key on nothing else, so an
// unrelated settings write leaves the signature identical and the caller
// keeps its cached row. Widths and grows are keyed by slotKey, like
// orderedWidths' input.
function invalidationSig(ids, kinds, widths, grows, dragRev) {
  let sig = ""
  for (let i = 0; i < ids.length; i++) {
    const k = slotKey(kinds[i], ids[i])
    sig += k + "=" + widths[k] + "@" + grows[k] + ";"
  }
  return sig + "#" + dragRev
}

// Shared device-list projections (qs.common.collections).
//
// Single source for the seven Model.js device-row vocabularies: sort,
// section, equality, display key and viewport height. The comparators stay
// with the caller (bluetooth sorts by name, wifi by signal), this file
// owns the shape: connected first, then known, then the caller order;
// sections as carried-forward labels; shallow field equality over
// snapshot rows. Pure JS, pragma library, no Qt imports.
.pragma library

.import "StoreGuards.js" as StoreGuards

// Connected first, then known/remembered, then the caller's tiebreak.
// rankOf/knownOf/labelOf read one row; tiebreak(a, b) orders within a
// tier (localeCompare on a label, signal strength, ...). The input is
// never mutated; a sorted copy is returned.
function sortRows(rows, rankOf, knownOf, tiebreak) {
  let list = StoreGuards.copyList(rows)
  list.sort(function(a, b) {
    let ra = rankOf ? !!rankOf(a) : false
    let rb = rankOf ? !!rankOf(b) : false
    if (ra !== rb) return ra ? -1 : 1
    let ka = knownOf ? !!knownOf(a) : false
    let kb = knownOf ? !!knownOf(b) : false
    if (ka !== kb) return ka ? -1 : 1
    if (typeof tiebreak === "function") return tiebreak(a, b)
    return 0
  })
  return list
}

// Shallow equality over snapshot rows via one key string per row. The
// poll rebuilds a fresh array every tick; assigning it unconditionally
// resets the ListView model and recreates every delegate, so callers
// skip the assignment when the keys agree.
function rowsEqual(a, b, keyOf) {
  let x = StoreGuards.asList(a)
  let y = StoreGuards.asList(b)
  if (x.length !== y.length) return false
  for (let i = 0; i < x.length; i++) {
    let kx = keyOf ? keyOf(x[i], i) : ""
    let ky = keyOf ? keyOf(y[i], i) : ""
    if (String(kx) !== String(ky)) return false
  }
  return true
}

// Section title for a sorted row at index: titleOf(row, prevRow, index)
// answers the header that OPENS here or "" on continuations. Carrying
// the label forward (instead of letting ListView paint a blank header
// for "") stays with the caller - see Network deriveWifiState.
function sectionTitleFor(index, rows, titleOf) {
  let list = StoreGuards.asList(rows)
  if (index < 0 || index >= list.length) return ""
  if (typeof titleOf !== "function") return ""
  let prev = index > 0 ? list[index - 1] : null
  return titleOf(list[index], prev, index)
}

// Flat ListView entries for sorted rows: an inline
// { type: "header", title } entry at every section start, then
// { type: "item", row } entries. entryOf(row) shapes the item entry;
// when trailingTitle is set a closing header is always appended even
// when its section has no rows, so a scan control stays reachable.
function sectionedEntries(sorted, titleOf, entryOf, trailingTitle) {
  let list = StoreGuards.asList(sorted)
  let entries = []
  let cur = ""
  for (let i = 0; i < list.length; i++) {
    let t = sectionTitleFor(i, list, titleOf)
    if (t !== "") {
      cur = t
      entries.push({ type: "header", title: t })
    }
    entries.push(typeof entryOf === "function" ? entryOf(list[i], i) : { type: "item", row: list[i] })
  }
  if (trailingTitle && cur !== trailingTitle) {
    entries.push({ type: "header", title: trailingTitle })
  }
  return entries
}

// Stable display key for a row: namespace + label, never empty.
function displayKey(row, namespace, label) {
  return String(namespace || "row") + ":" + String(label === undefined || label === null ? "" : label)
}

// Viewport cap for an island list: the content height, at most one page
// of rows. Single source for the wifi-list 250px cap idiom.
function viewportH(contentHeight, maxH) {
  let content = Number(contentHeight)
  if (!isFinite(content) || content <= 0) return 0
  let cap = Number(maxH)
  if (!isFinite(cap) || cap <= 0) cap = 250
  return Math.min(content, cap)
}

if (typeof module !== "undefined") {
  module.exports = {
    sortRows: sortRows,
    rowsEqual: rowsEqual,
    sectionTitleFor: sectionTitleFor,
    sectionedEntries: sectionedEntries,
    displayKey: displayKey,
    viewportH: viewportH
  }
}

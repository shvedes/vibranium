.pragma library

// Shared table-sort arithmetic: what a header click means, and the natural
// text order the text columns use.
//
// Feature modules own their comparators - a format row sorts by pixels, a
// package by name or version - because only they know what a row is. The
// direction convention and the text order live here so every sortable header
// behaves the same way and `SortHeader`'s arrow never lies.

// A click on a new column starts ascending; a click on the sorted column flips
// it. An empty `activeKey` means nothing is sorted yet, so the first click on
// any column is ascending.
function nextDirection(activeKey, direction, key) {
  if (String(activeKey || "") !== String(key || "")) return "asc"
  return String(direction || "") === "asc" ? "desc" : "asc"
}

// Text order with numbers read as numbers: "9.2" sorts under "10.1", which is
// the only way a version column is ever useful. Non-numeric runs compare as
// text, so "1.2p1" still lands next to "1.2".
function naturalCompare(a, b) {
  const x = String(a === undefined || a === null ? "" : a)
  const y = String(b === undefined || b === null ? "" : b)
  if (x === y) return 0
  const ax = x.match(/\d+|\D+/g) || []
  const by = y.match(/\d+|\D+/g) || []
  const n = Math.max(ax.length, by.length)
  for (let i = 0; i < n; i++) {
    const p = ax[i] === undefined ? "" : ax[i]
    const q = by[i] === undefined ? "" : by[i]
    if (p === q) continue
    const pn = /^\d+$/.test(p)
    const qn = /^\d+$/.test(q)
    // A number before a word at the same position: "2" then "beta".
    if (pn !== qn) return pn ? -1 : 1
    if (pn) {
      const d = Number(p) - Number(q)
      if (d !== 0) return d < 0 ? -1 : 1
      continue
    }
    return p < q ? -1 : 1
  }
  return 0
}

// Flip a comparator result for a descending sort. Callers compare only the
// VALUE - an equal pair is left to a stable tiebreak, so equal rows keep the
// order they arrived in whichever way the column is sorted.
function applyDirection(result, direction) {
  if (result === 0) return 0
  return String(direction || "") === "desc" ? -result : result
}

if (typeof module !== "undefined") {
  module.exports = {
    nextDirection: nextDirection,
    naturalCompare: naturalCompare,
    applyDirection: applyDirection
  }
}

.pragma library

// Whole-row list height arithmetic: the sum of a row set, and the largest
// whole prefix of one that fits a given space.
//
// WHY IT EXISTS. Two cards asked "how tall is this list" and each wrote the
// loop itself - PanelCard for the row-limited cards, MenuPanel beside it
// for the settings menu. They are the same loop, and being the same loop
// is the problem: a rule answered twice is a rule that drifts, and the
// drift is invisible until a list renders cut through a row. Everything
// either card does NOT agree on stays in the card.
//
// WHAT IS SHARED AND WHAT IS NOT. The ARITHMETIC is the shared rule: walk
// the rows, add the gap between them, stop at the boundary rather than
// past it. The VOCABULARY of a row is not, and deliberately so - a helper
// that hardcodes one spelling of a row's title line answers a different
// question for every other consumer, which is how a row set whose title
// field is not `label` came to be measured as an empty one. So `rowH` is
// the caller's own height function and this module never learns what a row
// looks like. A caller with a bespoke row shape (per-row fonts, theme
// swatches, markup sub lines) keeps its estimator and shares the sum; a
// caller with a uniform row passes a constant.
//
// EVERY ANSWER IS A WHOLE-ROW SUM. That is the whole point of stopping at
// the boundary instead of clamping to the space available: a region whose
// bottom edge is the bottom edge of a row shows a row whole, and one that
// is not shows it cut. Callers that need a screen number clamp this
// result; they must not feed one back in as an answer.

// Callers ask for "every row" or "the first n" and never for zero rows:
// a limit of 0 or less means no cap, which is the ordinary case for a
// card with no row limit of its own.
// The fallback row height: the learned average when there is one, else the
// live content's average, else the tree's floor. A list that has not measured
// anything yet still answers a usable row.
function fallbackRowH(avgH, count, contentHeight, rowMinH) {
  if (avgH > 0) return avgH
  const n = Number(count)
  const h = Number(contentHeight)
  if (n > 0 && h > 0) return Math.max(Number(rowMinH) || 0, h / n)
  return Number(rowMinH) || 0
}

// A measured height for one identity, or the caller's fallback when the table
// has no usable entry for it.
function heightAt(knownH, key, fallback) {
  const h = knownH[key]
  return typeof h === "number" && isFinite(h) && h > 0 ? h : fallback
}

// Which row owns each identity: the first index that claims a key, and -1 for
// a key two live rows share. A contested key has no single height to learn.
// One walk of the row set, in the row set's own order.
function identityOwners(count, rowKey) {
  const owner = Object.create(null)
  let contested = false
  for (let i = 0; i < count; i++) {
    const key = rowKey(i)
    if (owner[key] === undefined) owner[key] = i
    else {
      owner[key] = -1
      contested = true
    }
  }
  return { owner: owner, contested: contested }
}

// The least-recently-touched entries a height table must drop to stay under
// its cap, and the sum of their heights. Keys sort by touch stamp, then by
// name so an eviction order is deterministic when stamps tie.
function trimPlan(knownH, touchH, max) {
  const keys = Object.keys(knownH)
  const bound = Number(max)
  if (!isFinite(bound) || bound < 0 || keys.length <= bound) return { keys: [], sum: 0 }
  const excess = keys.length - bound
  keys.sort((a, b) => {
    const delta = (touchH[a] || 0) - (touchH[b] || 0)
    if (delta !== 0) return delta
    return a < b ? -1 : 1
  })
  const drop = keys.slice(0, excess)
  let sum = 0
  for (let i = 0; i < drop.length; i++) sum += knownH[drop[i]]
  return { keys: drop, sum: sum }
}

function limitOf(count, cap) {
  return cap > 0 ? Math.min(count, Math.floor(cap)) : count
}

// The height of a row set: whole rows plus the list's own inter-row gap.
// `cap` of 0 or less is every row, which is what a caller needs when it
// weighs a capped region against the whole model.
function contentH(rows, cap, rowH, spacing) {
  const n = rows === null || rows === undefined ? 0 : limitOf(rows.length, cap)
  let total = 0
  for (let i = 0; i < n; i++) {
    total += rowH(rows[i])
    if (i > 0) total += spacing
  }
  return total
}

// The largest whole prefix of the row set that fits `avail`: a region whose
// bottom edge is a row boundary, never a fraction of one. `ceiling` is the
// screen limit a caller clamps against, not a substitute answer - a cap
// taller than the space is answered with the largest whole prefix that
// fits.
//
// Zero rows is zero height. A card with nothing to show is sized by its
// own empty-state floor, and answering `avail` here would hand a window-
// filling region to a list that has no rows in it.
function snappedH(rows, cap, avail, ceiling, rowH, spacing) {
  if (rows === null || rows === undefined) return 0
  const n = limitOf(rows.length, cap)
  if (n === 0) return 0
  // A first row taller than the space is not shrunk and no second row is
  // considered: the answer is that row, clipped to the ceiling. Dropping
  // it would answer 0 for a list whose only row is simply too tall.
  const first = rowH(rows[0])
  if (first > avail) return Math.min(first, ceiling)
  let total = 0
  let best = 0
  for (let i = 0; i < n; i++) {
    total += rowH(rows[i])
    if (i > 0) total += spacing
    if (total > avail) break
    best = total
  }
  // Unreachable while a height function returns a positive number, which
  // every one of them does: a first row that fits was already taken as
  // `best`. Kept so a degenerate estimator degrades to the space rather
  // than to nothing.
  return best > 0 ? best : Math.min(avail, ceiling)
}

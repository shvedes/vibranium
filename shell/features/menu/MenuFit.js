.pragma library

// The fit-retry budgets, as a pure policy.
//
// A card whose rows are moving cannot be measured yet, so the panel re-posts
// its fit on a frame timer. The retry has to be BOUNDED: a condition that
// never clears (a swap that keeps reporting children, a slot whose close grace
// outlives its tween) would otherwise re-scan every live delegate once per
// frame forever and compete with the transitions it is waiting for. The two
// budgets differ on purpose - eight frames for a delegate that has not been
// created yet, twenty-four for a settle that includes a slot's close grace -
// and `retry` is the one place either number is applied.
//
// Kept out of the panel so the boundary is askable without a live menu: the
// interesting failure is an off-by-one that lets attempt N+1 through, or a
// counter that never reaches its budget, and both are visible here.

// Frames a not-yet-measurable fit may wait for delegates to appear.
var FIT_RETRY_BUDGET = 8
// Frames a fit may wait for a swap or a slot's close grace to settle.
var SETTLE_RETRY_BUDGET = 24

// The attempt count after one more retry, or -1 when the budget is spent.
// A missing, negative or non-finite count is read as "no attempts yet", so a
// reset that failed to happen cannot make the retry loop unbounded; a missing
// or non-positive budget is spent, because an unbounded wait is the bug this
// exists to prevent.
function retry(attempts, budget) {
  const used = Number(attempts)
  const max = Number(budget)
  const n = isFinite(used) && used > 0 ? Math.floor(used) : 0
  if (!isFinite(max) || max <= 0) return -1
  if (n >= Math.floor(max)) return -1
  return n + 1
}

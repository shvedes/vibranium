// Shared numeric range helpers (qs.common.math).
//
// The shell clamps ratios in a dozen places - colour channels, scrub
// positions, calendar day fractions, meter levels. Stating the two
// operations once keeps the inclusive bounds and the NaN behaviour (it
// propagates, because every caller has already validated its input) from
// drifting between copies. Pure JS, pragma library, no Qt imports.
.pragma library

// The hi side is the outer bound, so inverted bounds answer hi rather than
// lo - the contract the menu's option stepping was written against.
function clamp(value, lo, hi) {
  return Math.min(hi, Math.max(lo, value))
}

function clamp01(value) {
  return clamp(value, 0, 1)
}

// A clamp with a fallback for non-numeric input. `fallback` is returned only
// when Number(value) is NaN; infinities still clamp to the outer bound, which
// is what a caller that hands over a computed position expects.
function clampOr(value, lo, hi, fallback) {
  const n = Number(value)
  if (isNaN(n)) return fallback
  return clamp(n, lo, hi)
}

// A clamp that also rejects infinite input. `fallback` answers both NaN and
// +-Infinity, which is the contract colour channels use: a channel is a finite
// number or it is the default, never an unbounded one.
function clampFinite(value, lo, hi, fallback) {
  const n = Number(value)
  if (!isFinite(n)) return fallback
  return clamp(n, lo, hi)
}

// Round to `decimals` places. The decimal count is floored and clamped at
// zero, so a caller cannot ask for a fractional or negative digit count.
function round(value, decimals) {
  const places = Math.max(0, Math.floor(Number(decimals) || 0))
  const factor = Math.pow(10, places)
  return Math.round(Number(value) * factor) / factor
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    clamp01: clamp01,
    clampOr: clampOr,
    clampFinite: clampFinite,
    round: round
  }
}

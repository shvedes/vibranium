// Shared numeric range helpers (qs.common.math).
//
// The shell clamps ratios in a dozen places - colour channels, scrub
// positions, calendar day fractions, meter levels. Stating the two
// operations once keeps the inclusive bounds and the NaN behaviour (it
// propagates, because every caller has already validated its input) from
// drifting between copies. Pure JS, pragma library, no Qt imports.
.pragma library

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

function clamp01(value) {
  return clamp(value, 0, 1)
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    clamp01: clamp01
  }
}

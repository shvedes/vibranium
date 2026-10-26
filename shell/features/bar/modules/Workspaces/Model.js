.pragma library

// Pure number-strip algebra for the bar workspaces module. The strip renders
// one fixed-width number slot per workspace: the measured width of two digits
// plus equal padding on each edge. Everything here is arithmetic over that one
// shape; no Qt, Quickshell or protocol objects are involved.

// Space between two number slots.
function numberGap() {
  return 3
}

// Horizontal air inside one number slot, each edge. Scaled by the bar's own
// icon scale so the strip grows with the font preset.
function numberPad(scale) {
  const s = typeof scale === "number" && isFinite(scale) && scale > 0 ? scale : 1
  return Math.max(1, Math.round(2 * s))
}

// Width of one slot: the caller's measured label plus the padding on both
// edges. A box narrower than its own padding pair is impossible, and a zero or
// negative measurement must not produce a negative width, so both are floored.
function numberBoxWidth(numberWidth, pad) {
  const p = Math.max(0, pad | 0)
  return p * 2 + Math.max(0, numberWidth | 0)
}

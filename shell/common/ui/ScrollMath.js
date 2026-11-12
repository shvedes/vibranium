// Shared wheel-scroll arithmetic (qs.common.ui).
//
// The mixer popup and the clipboard preview both translate a wheel delta in
// rows into a clamped content offset. The rule is the same in both: a
// wheel-up is a contentY decrease, the offset never leaves [0, content
// height - viewport height], and a list that fits clamps to zero.
//
// Pure JS, pragma library, no Qt imports.
.pragma library

.import "../math/Range.js" as Range

// The content offset after `notches` rows of wheel travel. `rowH` is the
// height one notch moves; a fractional notch (trackpad) moves the same
// fraction of the row.
function wheelOffset(contentY, contentHeight, viewHeight, notches, rowH) {
  let maxY = Math.max(0, Number(contentHeight) - Number(viewHeight))
  let next = Number(contentY) - Number(notches) * Number(rowH)
  return Range.clamp(next, 0, maxY)
}

if (typeof module !== "undefined") {
  module.exports = {
    wheelOffset: wheelOffset
  }
}

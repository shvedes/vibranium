// Shared marquee timing (qs.common.motion).
//
// A text row that scrolls measured its leg duration from the overflow in
// three places: the now-playing title/artist/album lines and the clipboard
// title. One leg is the time the text takes to travel its overflow at a
// fixed reading pace, bounded so a short overflow does not crawl and a long
// one does not race. A row handing its scroll back on a focus change keeps
// that curve but covers the distance left at a fraction of the reading pace,
// so an interrupted title parks promptly instead of replaying a full leg.
//
// Pure JS, no Qt imports: the arithmetic is unit-drivable.
.pragma library

.import "../math/Range.js" as Range

var BASE_MS = 1800
var PER_PIXEL_MS = 24
var MIN_MS = 1800
var MAX_MS = 9000
var ENDPOINT_PAUSE_MS = 400
var RETURN_FACTOR = 0.08

// Whether a clipped label has anything to reveal. Scrolling is an
// accessibility behavior, not decoration: the animation setting governs how
// the shell moves, not whether a title that does not fit can ever be read.
// Callers still apply their own "is this row visible" gate; this only answers
// the overflow question.
function scrollable(overflow) {
  const n = Number(overflow)
  return isFinite(n) && n > 0.5
}

// Milliseconds for one leg over `overflow` pixels, or the floor when the
// overflow is not a finite number. The clamp keeps the same 1800..9000
// window every caller already used.
function legMs(overflow) {
  let n = Number(overflow)
  if (!isFinite(n)) n = 0
  let travel = BASE_MS + Math.max(0, n) * PER_PIXEL_MS
  return Range.clamp(Math.round(travel), MIN_MS, MAX_MS)
}

// Milliseconds for a handed-back label to cover `distance` pixels. Same
// bounded arithmetic as a leg, at a fraction of the reading pace: the return
// is still longer for a further-off title, but it parks in a few hundred ms.
function returnMs(distance) {
  let n = Number(distance)
  if (!isFinite(n)) n = 0
  return Math.round(legMs(n) * RETURN_FACTOR)
}

// Milliseconds a row dwells at each end of its travel before reversing. One
// published value: every marquee keeps the same beat without copying a literal.
function endpointPauseMs() {
  return ENDPOINT_PAUSE_MS
}

if (typeof module !== "undefined") {
  module.exports = {
    BASE_MS: BASE_MS,
    PER_PIXEL_MS: PER_PIXEL_MS,
    MIN_MS: MIN_MS,
    MAX_MS: MAX_MS,
    ENDPOINT_PAUSE_MS: ENDPOINT_PAUSE_MS,
    RETURN_FACTOR: RETURN_FACTOR,
    scrollable: scrollable,
    legMs: legMs,
    returnMs: returnMs,
    endpointPauseMs: endpointPauseMs
  }
}

// Shared marquee timing (qs.common.motion).
//
// A text row that scrolls measured its leg duration from the overflow in
// three places: the now-playing title/artist/album lines and the clipboard
// title. One leg is the time the text takes to travel its overflow at a
// fixed reading pace, bounded so a short overflow does not crawl and a long
// one does not race.
//
// Pure JS, no Qt imports: the arithmetic is unit-drivable.
.pragma library

var BASE_MS = 1800
var PER_PIXEL_MS = 24
var MIN_MS = 1800
var MAX_MS = 9000

// Milliseconds for one leg over `overflow` pixels, or the floor when the
// overflow is not a finite number. The clamp keeps the same 1800..9000
// window every caller already used.
function legMs(overflow) {
  var n = Number(overflow)
  if (!isFinite(n)) n = 0
  var travel = BASE_MS + Math.max(0, n) * PER_PIXEL_MS
  return Math.max(MIN_MS, Math.min(MAX_MS, Math.round(travel)))
}

if (typeof module !== "undefined") {
  module.exports = {
    BASE_MS: BASE_MS,
    PER_PIXEL_MS: PER_PIXEL_MS,
    MIN_MS: MIN_MS,
    MAX_MS: MAX_MS,
    legMs: legMs
  }
}

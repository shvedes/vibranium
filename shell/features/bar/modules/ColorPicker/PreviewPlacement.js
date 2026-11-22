// Placement for the color picker's floating code readout.
//
// The readout sits beside the magnifier box, which flattens against a screen
// edge as the aim approaches it. Every aim change re-runs this, so the choice
// has to be pure and cheap: no Qt imports, no allocation at all. Two scalar
// calls return one number each, x and y; side() is the shared decision,
// spelled as 0=top, 1=bottom, 2=right, 3=left. Top, bottom, right and left are
// tried in that order; a side is only taken with room for the whole card plus
// the gap, and the last resort is the side with the most room, clamped into
// the screen.
.pragma library

// Pick the side as a small integer so callers need no string or object to
// read the decision. Ties keep the order above: the first side with enough
// room wins, and in the fallback the earlier side wins an equal-room tie.
function side(bx, by, bw, bh, cw, ch, sw, sh, gap) {
  const g = Number(gap) > 0 ? Number(gap) : 0
  const cwid = Math.max(0, Number(cw) || 0)
  const chei = Math.max(0, Number(ch) || 0)
  const scrW = Math.max(1, Number(sw) || 1)
  const scrH = Math.max(1, Number(sh) || 1)
  const x = Number(bx) || 0
  const y = Number(by) || 0
  const bwid = Math.max(0, Number(bw) || 0)
  const bhei = Math.max(0, Number(bh) || 0)

  const top = y - g
  const bottom = scrH - y - bhei - g
  const right = scrW - x - bwid - g
  const left = x - g
  if (top >= chei) return 0
  if (bottom >= chei) return 1
  if (right >= cwid) return 2
  if (left >= cwid) return 3
  let best = top
  let chosen = 0
  if (bottom > best) { best = bottom; chosen = 1 }
  if (right > best) { best = right; chosen = 2 }
  if (left > best) chosen = 3
  return chosen
}

// Horizontal answer for the side side() would choose. Both halves call
// side() on the same scalars so the two numbers always name one choice;
// only the extent they centre and clamp differs.
function placeX(bx, by, bw, bh, cw, ch, sw, sh, gap) {
  const g = Number(gap) > 0 ? Number(gap) : 0
  const cwid = Math.max(0, Number(cw) || 0)
  const scrW = Math.max(1, Number(sw) || 1)
  const x = Number(bx) || 0
  const bwid = Math.max(0, Number(bw) || 0)
  const chosen = side(bx, by, bw, bh, cw, ch, sw, sh, gap)
  const raw = chosen === 0 || chosen === 1
    ? x + bwid / 2 - cwid / 2
    : (chosen === 3 ? x - g - cwid : x + bwid + g)
  return Math.min(Math.max(raw, 0), Math.max(0, scrW - cwid))
}

// Vertical half of the same answer.
function placeY(bx, by, bw, bh, cw, ch, sw, sh, gap) {
  const g = Number(gap) > 0 ? Number(gap) : 0
  const chei = Math.max(0, Number(ch) || 0)
  const scrH = Math.max(1, Number(sh) || 1)
  const y = Number(by) || 0
  const bhei = Math.max(0, Number(bh) || 0)
  const chosen = side(bx, by, bw, bh, cw, ch, sw, sh, gap)
  const raw = chosen === 0 || chosen === 1
    ? (chosen === 0 ? y - g - chei : y + bhei + g)
    : y + bhei / 2 - chei / 2
  return Math.min(Math.max(raw, 0), Math.max(0, scrH - chei))
}

if (typeof module !== "undefined") {
  module.exports = { side: side, placeX: placeX, placeY: placeY }
}

// Placement for the color picker's floating code readout.
//
// The readout sits beside the magnifier box, which flattens against a screen
// edge as the aim approaches it. Every aim change re-runs this, so the choice
// has to be pure and cheap: no Qt imports, no allocation beyond the answer.
// Top, bottom, right and left are tried in that order; a side is only taken
// with room for the whole card plus the gap, and the last resort is the side
// with the most room, clamped into the screen.
.pragma library

function place(box, card, screen, gap) {
  const g = Number(gap) > 0 ? Number(gap) : 0
  const cw = Math.max(0, Number(card && card.width) || 0)
  const ch = Math.max(0, Number(card && card.height) || 0)
  const sw = Math.max(1, Number(screen && screen.width) || 1)
  const sh = Math.max(1, Number(screen && screen.height) || 1)
  const bx = Number(box && box.x) || 0
  const by = Number(box && box.y) || 0
  const bw = Math.max(0, Number(box && box.width) || 0)
  const bh = Math.max(0, Number(box && box.height) || 0)

  const room = {
    top: by - g,
    bottom: sh - by - bh - g,
    right: sw - bx - bw - g,
    left: bx - g
  }
  const order = ["top", "bottom", "right", "left"]
  let side = ""
  for (let i = 0; i < order.length; i++) {
    const s = order[i]
    const need = s === "top" || s === "bottom" ? ch : cw
    if (room[s] >= need) {
      side = s
      break
    }
  }
  if (side === "") {
    let best = -Infinity
    for (let i = 0; i < order.length; i++) {
      const s = order[i]
      if (room[s] > best) {
        best = room[s]
        side = s
      }
    }
  }

  let x, y
  if (side === "top" || side === "bottom") {
    x = bx + bw / 2 - cw / 2
    y = side === "top" ? by - g - ch : by + bh + g
  } else {
    x = side === "left" ? bx - g - cw : bx + bw + g
    y = by + bh / 2 - ch / 2
  }
  return {
    side: side,
    x: Math.min(Math.max(x, 0), Math.max(0, sw - cw)),
    y: Math.min(Math.max(y, 0), Math.max(0, sh - ch))
  }
}

if (typeof module !== "undefined") {
  module.exports = { place: place }
}

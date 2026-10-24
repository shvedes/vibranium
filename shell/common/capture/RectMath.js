// Pure rect geometry shared by the capture service and the annotation
// views: the finite-number guard, the corner-pair normalize and the frame
// clamp. The capture pipeline needs the clamp to map a logical selection
// onto frame pixels, and the annotation views need the same normalize to
// turn a drag into a rect, so both resolve it here instead of keeping a
// second copy. No imports - nothing here touches the shell.
//
// scaleRect, clampPoint, clampRectInBox and placeBox are the rest of
// that vocabulary: the one scale a logical selection takes before it is
// clamped onto frame pixels, the two clamps the selection rects use, and
// the placement a magnifier takes around a live rect.
// The scale factor is applied unguarded because both call sites have
// already floored it, and a field that is a numeric string has to keep
// scaling the way "40" * 1.25 does.
//
// There is deliberately no intersectRect here. Returning an overlap as a
// rect and reading its right edge back as x + w is not the same number
// (x + (right - x) != right in binary floating point), and the crop and
// mosaic paths both step through a computed right edge often enough for
// that to matter.
.pragma library

function finite(value) {
  return typeof value === "number" && Number.isFinite(value)
}

function zeroRect() {
  return { x: 0, y: 0, w: 0, h: 0 }
}

// Corner pair -> non-negative rect.
function normRect(x1, y1, x2, y2) {
  if (!finite(x1) || !finite(y1) || !finite(x2) || !finite(y2)) return zeroRect()
  return {
    x: Math.min(x1, x2),
    y: Math.min(y1, y2),
    w: Math.abs(x2 - x1),
    h: Math.abs(y2 - y1)
  }
}

// Intersect with the frame; floors w/h at 1 so a drag past an edge never
// produces negative sizes downstream. Every field is rounded, not just
// w/h: x/y arrive scaled by a DPR ratio, and a fractional x with rounded
// extents can push x+w one pixel past the frame edge - which the canvas
// drawImage rejects as an index-size error instead of drawing.
function clampRect(rect, fw, fh) {
  const frameW = Math.max(1, Math.round(finite(fw) ? fw : 1))
  const frameH = Math.max(1, Math.round(finite(fh) ? fh : 1))
  const rawX = rect !== null && rect !== undefined && finite(rect.x) ? rect.x : 0
  const rawY = rect !== null && rect !== undefined && finite(rect.y) ? rect.y : 0
  const rawW = rect !== null && rect !== undefined && finite(rect.w) ? rect.w : 0
  const rawH = rect !== null && rect !== undefined && finite(rect.h) ? rect.h : 0
  const rawRight = finite(rawX + rawW) ? rawX + rawW : rawX
  const rawBottom = finite(rawY + rawH) ? rawY + rawH : rawY
  let x = Math.round(Math.max(0, Math.min(frameW, rawX)))
  let y = Math.round(Math.max(0, Math.min(frameH, rawY)))
  let w = Math.round(Math.max(1, Math.min(frameW, rawRight) - x))
  let h = Math.round(Math.max(1, Math.min(frameH, rawBottom) - y))
  if (x + w > frameW) {
    x = frameW - 1
    w = 1
  }
  if (y + h > frameH) {
    y = frameH - 1
    h = 1
  }
  return { x: x, y: y, w: w, h: h }
}

// Corner-origin scale: a logical selection or a window-logical crop
// before clampRect maps it onto frame pixels. Every field goes through the
// plain multiplication it replaces, coercion included - a numeric string
// field has to keep scaling the way "40" * 1.25 does - and the factor is
// not validated either, because both call sites have already floored it.
// A null rect throws here as the inline expression did; both callers
// guard it.
function scaleRect(rect, k) {
  return { x: rect.x * k, y: rect.y * k, w: rect.w * k, h: rect.h * k }
}

// Point into a rect. No finite guard on purpose: every caller maps a
// point that displayToDoc already made finite, and substituting 0 for a
// NaN would silently place a point at the frame origin instead of letting
// the caller see that the mapping broke.
function clampPoint(p, box) {
  return {
    x: Math.max(box.x, Math.min(box.x + box.w, p.x)),
    y: Math.max(box.y, Math.min(box.y + box.h, p.y))
  }
}

// A whole rect kept inside a box of the given size, anchored at the
// origin. Order matters and is the order below: x is placed against the
// old w, then w against the new x, so a rect wider than the box still
// ends up inside it.
function clampRectInBox(rect, boxW, boxH) {
  const maxX = Math.max(0, boxW)
  const maxY = Math.max(0, boxH)
  const x = Math.max(0, Math.min(maxX - Math.min(rect.w, maxX), rect.x))
  const y = Math.max(0, Math.min(maxY - Math.min(rect.h, maxY), rect.y))
  const w = Math.max(0, Math.min(rect.w, maxX - x))
  const h = Math.max(0, Math.min(rect.h, maxY - y))
  return { x: x, y: y, w: w, h: h }
}

// Origin of a size x size box that follows a point but keeps clear of a
// rect, inside a boxW x boxH area. A magnifier centered on the pointer
// covers the pixels the pointer is aiming at and, while a selection is
// being dragged, hides the very edge that is being extended.
//
// Without a rect - or with a zero-area one, which a fresh drag still is -
// the box is centered on the point and clamped, as a magnifier has no
// obstacle to dodge. Otherwise the centered placement is measured first
// and an unblocked box is returned unchanged; only an overlapping one
// pays for an escape. Each escape is a box flush with one of the rect's
// sides, grown by gap, and aligned with the point on the perpendicular
// axis, so the box ends up beside the rect rather than at a screen corner.
// The escape that moves the box least wins, and a tie keeps the earlier
// candidate so an equal-cost pair cannot swap sides frame to frame. A rect
// covering the whole area leaves no escape, and the centered placement
// stands - the area cannot be honored, so the pointer keeps the box.
function placeBox(px, py, size, rect, boxW, boxH, gap) {
  const s = Math.max(1, finite(size) ? size : 1)
  const maxX = Math.max(0, boxW - s)
  const maxY = Math.max(0, boxH - s)
  const cx = finite(px) ? px : 0
  const cy = finite(py) ? py : 0
  const home = {
    x: Math.max(0, Math.min(maxX, cx - s / 2)),
    y: Math.max(0, Math.min(maxY, cy - s / 2))
  }
  if (rect === null || rect === undefined) return home
  if (!(rect.w > 0) && !(rect.h > 0)) return home
  const pad = finite(gap) && gap > 0 ? gap : 0
  const left = rect.x - pad
  const top = rect.y - pad
  const right = rect.x + rect.w + pad
  const bottom = rect.y + rect.h + pad
  // Separating-axis test against the grown rect. Touching counts as clear,
  // so with no gap the box may sit flush against the edge.
  const clear = p => p.x >= right || p.x + s <= left
    || p.y >= bottom || p.y + s <= top
  if (clear(home)) return home
  const escapes = [
    { x: right, y: home.y },
    { x: left - s, y: home.y },
    { x: home.x, y: bottom },
    { x: home.x, y: top - s }
  ]
  let best = null
  let bestCost = Infinity
  for (let i = 0; i < escapes.length; i++) {
    const p = {
      x: Math.max(0, Math.min(maxX, escapes[i].x)),
      y: Math.max(0, Math.min(maxY, escapes[i].y))
    }
    if (!clear(p)) continue
    const cost = Math.abs(p.x - home.x) + Math.abs(p.y - home.y)
    if (cost >= bestCost) continue
    bestCost = cost
    best = p
  }
  return best !== null ? best : home
}

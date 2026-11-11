// Pure annotation math: eraser hit tests, arrow geometry, crop
// translation, view/document mapping. The only import is the neutral rect
// primitive, so the capture service and these views share one normalize and
// one clamp instead of each keeping a copy.
//
// The document/view half of the same vocabulary lives here too, because
// the editor, the region overlay and the region capture path all resolve
// it from this one home: the document-rect clamp and the export frame, the
// point clamps, the selection bounds and their eight handles, and the paint
// transform into backing pixels.
// Every function here takes the document state as arguments; nothing
// reads editor properties, so the library stays unit-drivable.
.pragma library
.import "../../common/capture/RectMath.js" as RectMath
.import "../../common/math/Range.js" as Range

function _finite(value) {
  return RectMath.finite(value)
}

function _point(value) {
  return value !== null && value !== undefined
    && _finite(value.x) && _finite(value.y)
}

function _zeroRect() {
  return RectMath.zeroRect()
}

// Corner pair -> non-negative rect.
function normRect(x1, y1, x2, y2) {
  return RectMath.normRect(x1, y1, x2, y2)
}

// Corner pair -> aspect-locked rect (w/h == ratio), dominant axis wins, the
// quadrant around the anchor preserved. A ratio that is not a positive finite
// number disables the lock and falls back to normRect.
function lockRect(x1, y1, x2, y2, ratio) {
  const base = normRect(x1, y1, x2, y2)
  if (!_finite(ratio) || ratio <= 0) return base
  if (base.w === 0 && base.h === 0) return base
  if (base.w / base.h >= ratio) {
    base.h = base.w / ratio
    base.y = y2 >= y1 ? y1 : y1 - base.h
  } else {
    base.w = base.h * ratio
    base.x = x2 >= x1 ? x1 : x1 - base.w
  }
  return base
}

function mapRectToFrame(rect, frameW, frameH, viewW, viewH) {
  if (rect === null || rect === undefined) return _zeroRect()
  const x = _finite(rect.x) ? rect.x : 0
  const y = _finite(rect.y) ? rect.y : 0
  const w = _finite(rect.w) ? rect.w : 0
  const h = _finite(rect.h) ? rect.h : 0
  const fw = _finite(frameW) && frameW > 0 ? frameW : 0
  const fh = _finite(frameH) && frameH > 0 ? frameH : 0
  const vw = _finite(viewW) && viewW > 0 ? viewW : 0
  const vh = _finite(viewH) && viewH > 0 ? viewH : 0
  const rawSx = fw > 0 && vw > 0 ? fw / vw : 1
  const rawSy = fh > 0 && vh > 0 ? fh / vh : 1
  const sx = _finite(rawSx) ? rawSx : 1
  const sy = _finite(rawSy) ? rawSy : 1
  const rx = x * sx
  const ry = y * sy
  const rw = w * sx
  const rh = h * sy
  return {
    x: _finite(rx) ? rx : 0,
    y: _finite(ry) ? ry : 0,
    w: _finite(rw) ? rw : 0,
    h: _finite(rh) ? rh : 0
  }
}

// Intersect with the frame; see RectMath.clampRect.
function clampRect(rect, fw, fh) {
  return RectMath.clampRect(rect, fw, fh)
}

// Overlay point -> backing pixels for the export transform: scale the
// view-relative point, rotate it about the view centre, and re-centre it on
// the rotated surface.
function docToBacking(p, vr, k, rot, dw, dh) {
  const vx = vr.x
  const vy = vr.y
  const cx = vr.w / 2
  const cy = vr.h / 2
  const a = (_finite(rot) ? rot : 0) * Math.PI / 180
  const ca = Math.cos(a)
  const sa = Math.sin(a)
  const px = k * (p.x - vx) - cx
  const py = k * (p.y - vy) - cy
  return {
    x: px * ca - py * sa + cx,
    y: px * sa + py * ca + dh / 2
  }
}

// The rounded bounding box of a rect's four corners through docToBacking, so
// getImageData can be handed an integer rect covering the rotated shape.
function rotBox(rect, vr, k, rot, dw, dh) {
  const cs = [
    { x: rect.x, y: rect.y },
    { x: rect.x + rect.w, y: rect.y },
    { x: rect.x + rect.w, y: rect.y + rect.h },
    { x: rect.x, y: rect.y + rect.h }
  ]
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (let i = 0; i < cs.length; i++) {
    const q = docToBacking(cs[i], vr, 1, rot, dw, dh)
    minX = Math.min(minX, q.x)
    minY = Math.min(minY, q.y)
    maxX = Math.max(maxX, q.x)
    maxY = Math.max(maxY, q.y)
  }
  return {
    x: Math.round(minX * k),
    y: Math.round(minY * k),
    w: Math.max(1, Math.round((maxX - minX) * k)),
    h: Math.max(1, Math.round((maxY - minY) * k))
  }
}

// The mosaic cell grid for a rect. The grid is anchored to the view origin,
// so a re-drawn rect mosaics into the same cells, and the step grows with the
// rect so a full-screen mosaic stays bounded (127 cells on the long axis at
// most, never finer than 3px).
function pixelateGrid(rect, vr) {
  if (rect === null || rect === undefined) return []
  const x = rect.x, y = rect.y, w = rect.w, h = rect.h
  if (!_finite(x) || !_finite(y) || !_finite(w) || !_finite(h) || w <= 0 || h <= 0) return []
  const vx = vr.x, vy = vr.y, vw = vr.w, vh = vr.h
  if (!_finite(vx) || !_finite(vy) || !_finite(vw) || !_finite(vh)) return []
  const minX = Math.max(x, vx)
  const minY = Math.max(y, vy)
  const maxX = Math.min(x + w, vx + vw)
  const maxY = Math.min(y + h, vy + vh)
  if (minX >= maxX || minY >= maxY) return []
  const step = Math.max(3, Math.ceil(Math.max(w, h) / 127))
  const firstX = Math.floor((minX - vx) / step)
  const lastX = Math.ceil((maxX - vx) / step)
  const firstY = Math.floor((minY - vy) / step)
  const lastY = Math.ceil((maxY - vy) / step)
  const cells = []
  for (let j = firstY; j < lastY; j++) {
    const cy0 = Math.max(minY, vy + j * step)
    const cy1 = Math.min(maxY, vy + (j + 1) * step)
    if (cy1 <= cy0) continue
    for (let i = firstX; i < lastX; i++) {
      const cx0 = Math.max(minX, vx + i * step)
      const cx1 = Math.min(maxX, vx + (i + 1) * step)
      if (cx1 <= cx0) continue
      cells.push({
        rect: { x: cx0, y: cy0, w: cx1 - cx0, h: cy1 - cy0 },
        center: {
          x: Range.clamp(vx + i * step + step / 2, cx0, cx1),
          y: Range.clamp(vy + j * step + step / 2, cy0, cy1)
        }
      })
    }
  }
  return cells
}

// Map a point through the export rotation into the rotated surface's
// coordinates. The surface itself is the destination frame: a quarter turn
// swaps its axes, so the mapping mirrors against the surface edge.
function _rotPoint(x, y, rot, sw, sh) {
  const r = ((Number(rot) || 0) % 360 + 360) % 360
  if (r === 90) return { x: sw - y, y: x }
  if (r === 180) return { x: sw - x, y: sh - y }
  if (r === 270) return { x: y, y: sh - x }
  return { x: x, y: y }
}

// A view rect -> the pixel box it occupies on the export surface, clipped to
// the surface. Null when the mapped box lands entirely off the export; a
// zero-size or NaN surface keeps the NaN box the caller can detect.
function pixelateBox(rect, vr, surface, rot) {
  if (!_finite(surface.w) || !_finite(surface.h)) {
    return { x: NaN, y: NaN, w: NaN, h: NaN }
  }
  const x0 = rect.x - vr.x
  const y0 = rect.y - vr.y
  const a = _rotPoint(x0, y0, rot, surface.w, surface.h)
  const b = _rotPoint(x0 + rect.w, y0 + rect.h, rot, surface.w, surface.h)
  const bx = Math.max(0, Math.floor(Math.min(a.x, b.x)))
  const by = Math.max(0, Math.floor(Math.min(a.y, b.y)))
  const ex = Math.min(surface.w, Math.ceil(Math.max(a.x, b.x)))
  const ey = Math.min(surface.h, Math.ceil(Math.max(a.y, b.y)))
  const bw = ex - bx
  const bh = ey - by
  if (bw < 1 || bh < 1) return null
  return { x: bx, y: by, w: bw, h: bh }
}

// One sample per grid cell: the cell's rect and the span it covers in the
// target box, or null when the cell does not overlap it. spanOf(cell) answers
// the unclipped {x0, y0, x1, y1} in box coordinates.
function _gridSamples(grid, box, spanOf) {
  if (!Array.isArray(grid) || grid.length === 0) return []
  if (box === null || box === undefined) return []
  const out = []
  for (let i = 0; i < grid.length; i++) {
    const cell = grid[i]
    const s = spanOf(cell)
    out.push({
      rect: cell.rect,
      box: s.x1 > s.x0 && s.y1 > s.y0 ? { x: s.x0, y: s.y0, w: s.x1 - s.x0, h: s.y1 - s.y0 } : null
    })
  }
  return out
}

// One clamped source span per mosaic cell: the span is the cell, not a point
// in it, so a thin feature inside a cell still contributes to its average.
// Cells that do not overlap the mapped box carry a null span.
function pixelateSamples(grid, vr, surface, rot, box) {
  return _gridSamples(grid, box, function(cell) {
    const a = _rotPoint(cell.rect.x - vr.x, cell.rect.y - vr.y, rot, surface.w, surface.h)
    const b = _rotPoint(cell.rect.x + cell.rect.w - vr.x,
      cell.rect.y + cell.rect.h - vr.y, rot, surface.w, surface.h)
    return {
      x0: Math.max(0, Math.floor(Math.min(a.x, b.x) - box.x)),
      y0: Math.max(0, Math.floor(Math.min(a.y, b.y) - box.y)),
      x1: Math.min(box.w, Math.ceil(Math.max(a.x, b.x) - box.x)),
      y1: Math.min(box.h, Math.ceil(Math.max(a.y, b.y) - box.y))
    }
  })
}

// The grid's extent in unrotated, view-relative image pixels, clipped to the
// baked backing. Unrotated because that is the image the blur bakes from.
function blurSampleBox(grid, vr, imgW, imgH) {
  if (!Array.isArray(grid) || grid.length === 0) return null
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (let i = 0; i < grid.length; i++) {
    const r = grid[i].rect
    minX = Math.min(minX, r.x - vr.x)
    minY = Math.min(minY, r.y - vr.y)
    maxX = Math.max(maxX, r.x + r.w - vr.x)
    maxY = Math.max(maxY, r.y + r.h - vr.y)
  }
  const x = Math.max(0, Math.floor(minX))
  const y = Math.max(0, Math.floor(minY))
  const w = Math.min(imgW, Math.ceil(maxX)) - x
  const h = Math.min(imgH, Math.ceil(maxY)) - y
  if (!(w >= 1) || !(h >= 1)) return null
  return { x: x, y: y, w: w, h: h }
}

// The same spans as pixelateSamples, read through the unrotated image
// mapping: one span per cell, clipped to the baked backing box.
function blurSamples(grid, vr, box) {
  return _gridSamples(grid, box, function(cell) {
    const r = cell.rect
    return {
      x0: Math.max(box.x, Math.floor(r.x - vr.x)),
      y0: Math.max(box.y, Math.floor(r.y - vr.y)),
      x1: Math.min(box.x + box.w, Math.ceil(r.x + r.w - vr.x)),
      y1: Math.min(box.y + box.h, Math.ceil(r.y + r.h - vr.y))
    }
  })
}

// The average colour a cell covers: every pixel in the span, not one texel in
// it. Returns [r, g, b] or null when the span has no pixels in the block.
function cellMean(px, box, span) {
  if (px === null || px === undefined || !px.data) return null
  if (box === null || box === undefined || span === null || span === undefined) return null
  const W = px.width, H = px.height
  if (!_finite(W) || !_finite(H) || W <= 0 || H <= 0) return null
  if (px.data.length < W * H * 4) return null
  const x0 = Math.max(0, Math.floor(Math.max(span.x, box.x)))
  const y0 = Math.max(0, Math.floor(Math.max(span.y, box.y)))
  const x1 = Math.min(W, Math.ceil(Math.min(span.x + span.w, box.x + box.w)))
  const y1 = Math.min(H, Math.ceil(Math.min(span.y + span.h, box.y + box.h)))
  if (x1 <= x0 || y1 <= y0) return null
  let r = 0, g = 0, b = 0, n = 0
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const o = (y * W + x) * 4
      r += px.data[o]
      g += px.data[o + 1]
      b += px.data[o + 2]
      n++
    }
  }
  return [Math.round(r / n), Math.round(g / n), Math.round(b / n)]
}

// Shared fit policy for display geometry and input mapping.
// Blur plate geometry. The plate is the document downscaled so its long side
// fits `maxSide`; a document already inside the bound keeps scale 1. A
// missing or non-positive extent reads as 1, the same "no downscale" answer
// the editor needs before the image has loaded.
function blurPlateScale(imgW, imgH, maxSide) {
  const w = Number(imgW)
  const h = Number(imgH)
  const m = Number(maxSide)
  if (!(w > 0) || !(h > 0) || !(m > 0)) return 1
  return Range.clamp01(m / Math.max(w, h))
}

// One plate side at scale k. At least one pixel: a zero-sized texture is not
// a blur plate, and Qt would decode nothing into it.
function blurPlateSide(size, k) {
  return Math.max(1, Math.round(Number(size) * Number(k)))
}

// Blur radius in document pixels: ~96 at plate scale, scaled up for large
// shots and capped. Measured on a text page: 96 and up left nothing legible,
// 60 left the words readable.
function blurRadius(k) {
  return Range.clamp(Math.round(96 / Number(k)), 96, 240)
}

function fitScale(stageW, stageH, docW, docH, minShortAxis) {
  const sw = _finite(stageW) ? stageW : 0
  const sh = _finite(stageH) ? stageH : 0
  const dw = _finite(docW) ? docW : 0
  const dh = _finite(docH) ? docH : 0
  if (!(dw > 0) || !(dh > 0)) return 1
  const fit = Math.min(sw / dw, sh / dh)
  const floor = _finite(minShortAxis) && minShortAxis > 0
    ? minShortAxis / Math.min(dw, dh) : 0
  const result = Math.max(fit, floor)
  return _finite(result) ? result : 1
}

function boardGeom(stageW, stageH, docW, docH, fit, zoom, pan) {
  const sw = _finite(stageW) ? stageW : 0
  const sh = _finite(stageH) ? stageH : 0
  const dw = _finite(docW) && docW > 0 ? docW : 1
  const dh = _finite(docH) && docH > 0 ? docH : 1
  const k = _finite(fit) && fit > 0 ? fit : 1
  const z = _finite(zoom) ? zoom : 1
  const px = pan !== null && pan !== undefined && _finite(pan.x) ? pan.x : 0
  const py = pan !== null && pan !== undefined && _finite(pan.y) ? pan.y : 0
  const w = Math.max(1, dw * k * z)
  const h = Math.max(1, dh * k * z)
  if (!_finite(w) || !_finite(h)) return { x: 0, y: 0, w: 1, h: 1, fit: k }
  const x = (sw - w) / 2 + px
  const y = (sh - h) / 2 + py
  return {
    x: _finite(x) ? x : 0,
    y: _finite(y) ? y : 0,
    w: w, h: h, fit: k
  }
}

// The frame both mappings share: the board origin, the view rect with its
// one-pixel floor, the rotation's cos/sin and the cover scale the board
// applies to the rotated document.
function _frame(geom, vr, rot) {
  const gx = geom !== null && geom !== undefined && _finite(geom.x) ? geom.x : 0
  const gy = geom !== null && geom !== undefined && _finite(geom.y) ? geom.y : 0
  const vx = vr !== null && vr !== undefined && _finite(vr.x) ? vr.x : 0
  const vy = vr !== null && vr !== undefined && _finite(vr.y) ? vr.y : 0
  const vw = vr !== null && vr !== undefined && _finite(vr.w) && vr.w > 0 ? vr.w : 1
  const vh = vr !== null && vr !== undefined && _finite(vr.h) && vr.h > 0 ? vr.h : 1
  const r = _finite(rot) ? rot : 0
  const a = r * Math.PI / 180
  const ca = Math.cos(a)
  const sa = Math.sin(a)
  const dw = Math.abs(vw * ca) + Math.abs(vh * sa)
  const dh = Math.abs(vw * sa) + Math.abs(vh * ca)
  let k = geom !== null && geom !== undefined && _finite(geom.w) && _finite(geom.h)
    && dw > 0 && dh > 0 ? Math.min(geom.w / dw, geom.h / dh)
    : geom !== null && geom !== undefined && _finite(geom.fit) && geom.fit > 0
      ? geom.fit : 1
  if (!(k > 0) || !_finite(k)) k = 1
  return { gx: gx, gy: gy, vx: vx, vy: vy, vw: vw, vh: vh,
    ca: ca, sa: sa, dw: dw, dh: dh, k: k }
}

// Overlay point -> document pixels. geom comes from boardGeom,
// vr is the view rect {x,y,w,h}, rot is 0/90/180/270.
function displayToDoc(mx, my, geom, vr, rot) {
  const x = _finite(mx) ? mx : 0
  const y = _finite(my) ? my : 0
  const f = _frame(geom, vr, rot)
  const bx = (x - f.gx) / f.k - f.dw / 2
  const by = (y - f.gy) / f.k - f.dh / 2
  const lx = bx * f.ca + by * f.sa + f.vw / 2
  const ly = -bx * f.sa + by * f.ca + f.vh / 2
  return {
    x: Range.clamp(lx + f.vx, f.vx, f.vx + f.vw),
    y: Range.clamp(ly + f.vy, f.vy, f.vy + f.vh)
  }
}

// Inverse of displayToDoc, same arguments.
function docToDisplay(p, geom, vr, rot) {
  if (!_point(p)) return { x: 0, y: 0 }
  const f = _frame(geom, vr, rot)
  const cx = p.x - f.vx - f.vw / 2
  const cy = p.y - f.vy - f.vh / 2
  const bx = cx * f.ca - cy * f.sa + f.dw / 2
  const by = cx * f.sa + cy * f.ca + f.dh / 2
  return { x: f.gx + bx * f.k, y: f.gy + by * f.k }
}

function _segDist2(px, py, ax, ay, bx, by) {
  if (!_finite(px) || !_finite(py) || !_finite(ax) || !_finite(ay)
    || !_finite(bx) || !_finite(by)) return Infinity
  const dx = bx - ax
  const dy = by - ay
  const len2 = dx * dx + dy * dy
  let t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
  t = Range.clamp01(t)
  const cx = ax + t * dx - px
  const cy = ay + t * dy - py
  return cx * cx + cy * cy
}

function pointToSegmentDist(px, py, ax, ay, bx, by) {
  return Math.sqrt(_segDist2(px, py, ax, ay, bx, by))
}

function _corners(stroke) {
  const p = stroke !== null && stroke !== undefined ? stroke.points : null
  if (!Array.isArray(p) || p.length < 2 || !_point(p[0]) || !_point(p[p.length - 1])) return _zeroRect()
  return normRect(p[0].x, p[0].y, p[p.length - 1].x, p[p.length - 1].y)
}

// Eraser hit test in image pixels. Brush/line/arrow test every segment,
// rect/ellipse test outline proximity, text tests its line box.
function hitStroke(stroke, px, py, tolerance) {
  if (stroke === null || stroke === undefined || !_finite(px) || !_finite(py)) return false
  const tolBase = _finite(tolerance) && tolerance > 0 ? tolerance : 0
  const pts = Array.isArray(stroke.points) ? stroke.points : []
  if (pts.length === 0) return false
  for (let i = 0; i < pts.length; i++) {
    if (!_point(pts[i])) return false
  }
  const tool = stroke.tool
  if (tool === "text") {
    const lines = String(stroke.text || "").split("\n")
    const fs = _finite(stroke.fontSize) && stroke.fontSize > 0 ? stroke.fontSize : 24
    const widest = lines.reduce((m, l) => Math.max(m, l.length), 0)
    const bx = pts[0].x - tolBase
    const by = pts[0].y - tolBase
    return px >= bx && px <= bx + widest * fs * 0.6 + tolBase * 2
      && py >= by && py <= by + lines.length * fs * 1.2 + tolBase * 2
  }
  if (tool === "rect" || tool === "ellipse") {
    if (pts.length < 2) return false
    const r = _corners(stroke)
    if (tool === "rect") {
      const d = Math.min(
        pointToSegmentDist(px, py, r.x, r.y, r.x + r.w, r.y),
        pointToSegmentDist(px, py, r.x, r.y + r.h, r.x + r.w, r.y + r.h),
        pointToSegmentDist(px, py, r.x, r.y, r.x, r.y + r.h),
        pointToSegmentDist(px, py, r.x + r.w, r.y, r.x + r.w, r.y + r.h))
      return d <= tolBase
    }
    const rx = Math.max(1, r.w / 2)
    const ry = Math.max(1, r.h / 2)
    const nx = (px - (r.x + rx)) / rx
    const ny = (py - (r.y + ry)) / ry
    const radial = Math.abs(1 - Math.sqrt(nx * nx + ny * ny)) * Math.min(rx, ry)
    return radial <= tolBase
  }
  if (tool === "blur" || tool === "pixelate") {
    // A blur or pixelate region is a filled area, not an outline: clicking
    // anywhere in it erases it, which is the only thing the eraser could mean
    // here.
    if (pts.length < 2) return false
    const r = _corners(stroke)
    return px >= r.x - tolBase && px <= r.x + r.w + tolBase
      && py >= r.y - tolBase && py <= r.y + r.h + tolBase
  }
  const width = _finite(stroke.width) && stroke.width > 0 ? stroke.width : 3
  const tol = width / 2 + tolBase
  if (tool === "arrowCorner" && pts.length >= 2) {
    const a = pts[0]
    const b = pts[pts.length - 1]
    const m = elbowMid(a, b)
    const r2 = Math.min(
      _segDist2(px, py, a.x, a.y, m.x, m.y),
      _segDist2(px, py, m.x, m.y, b.x, b.y))
    return r2 <= tol * tol
  }
  for (let i = 0; i + 1 < pts.length; i++) {
    if (_segDist2(px, py, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y) <= tol * tol) return true
  }
  return pts.length === 1 && _segDist2(px, py, pts[0].x, pts[0].y, pts[0].x, pts[0].y) <= tol * tol
}

// Two head-line endpoints for an arrow shaft (x1,y1 -> x2,y2). Head
// length scales with the stroke width, lines splay at +/- 25 degrees.
// Elbow midpoint for the corner arrow: the turn follows the dominant
// drag axis, so the shape reacts to drag direction instead of always
// bending the same way.
function elbowMid(a, b) {
  if (!_point(a) || !_point(b)) return { x: 0, y: 0 }
  return Math.abs(b.x - a.x) >= Math.abs(b.y - a.y)
    ? { x: b.x, y: a.y }
    : { x: a.x, y: b.y }
}

function arrowHead(x1, y1, x2, y2, headLen) {
  if (!_finite(x1) || !_finite(y1) || !_finite(x2) || !_finite(y2)) {
    return [{ x: 0, y: 0 }, { x: 0, y: 0 }]
  }
  const len = _finite(headLen) ? headLen : 0
  const ang = Math.atan2(y2 - y1, x2 - x1)
  const spread = 25 * Math.PI / 180
  return [
    { x: x2 - len * Math.cos(ang - spread), y: y2 - len * Math.sin(ang - spread) },
    { x: x2 - len * Math.cos(ang + spread), y: y2 - len * Math.sin(ang + spread) }
  ]
}

function _orient(a, b, c) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

function _onSegment(a, b, p) {
  return Math.min(a.x, b.x) <= p.x && p.x <= Math.max(a.x, b.x)
    && Math.min(a.y, b.y) <= p.y && p.y <= Math.max(a.y, b.y)
}

function _segmentsIntersect(a, b, c, d) {
  const o1 = _orient(a, b, c)
  const o2 = _orient(a, b, d)
  const o3 = _orient(c, d, a)
  const o4 = _orient(c, d, b)
  if (((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0))
    && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0))) return true
  if (o1 === 0 && _onSegment(a, b, c)) return true
  if (o2 === 0 && _onSegment(a, b, d)) return true
  if (o3 === 0 && _onSegment(c, d, a)) return true
  if (o4 === 0 && _onSegment(c, d, b)) return true
  return false
}

function _pointInRect(p, rect) {
  return _point(p) && p.x >= rect.x && p.x <= rect.x + rect.w
    && p.y >= rect.y && p.y <= rect.y + rect.h
}

function _segmentIntersectsRect(a, b, rect) {
  const x0 = rect.x
  const y0 = rect.y
  const x1 = rect.x + rect.w
  const y1 = rect.y + rect.h
  return _segmentsIntersect(a, b, { x: x0, y: y0 }, { x: x1, y: y0 })
    || _segmentsIntersect(a, b, { x: x1, y: y0 }, { x: x1, y: y1 })
    || _segmentsIntersect(a, b, { x: x1, y: y1 }, { x: x0, y: y1 })
    || _segmentsIntersect(a, b, { x: x0, y: y1 }, { x: x0, y: y0 })
}

// Crop filter for crop-commit: keeps every stroke that touches the rect -
// any point inside it, or a segment crossing it - and drops the rest. The
// survivors stay VERBATIM in absolute document coordinates. Coordinates are
// never translated (the view rect owns the origin); translating here as well
// would double-shift every stroke. Partially-outside strokes stay whole -
// the canvas backing clips them for free.
function cropDocument(strokes, rect) {
  if (!Array.isArray(strokes)) return []
  if (rect === null || rect === undefined) return []
  if (!_finite(rect.x) || !_finite(rect.y) || !_finite(rect.w) || !_finite(rect.h)) return []
  const out = []
  for (let i = 0; i < strokes.length; i++) {
    const stroke = strokes[i]
    if (stroke === null || stroke === undefined || !Array.isArray(stroke.points)) continue
    let kept = false
    let prev = null
    for (let j = 0; j < stroke.points.length; j++) {
      const p = stroke.points[j]
      if (!_point(p)) continue
      if (_pointInRect(p, rect) || (prev !== null && _segmentIntersectsRect(prev, p, rect))) {
        kept = true
        break
      }
      prev = p
    }
    if (kept) out.push(stroke)
  }
  return out
}
// --- document view geometry ---
// A document rect inside the document view rect, in absolute document
// pixels. The subtraction is unguarded on purpose: a non-finite field is
// already 0 to clampRect's own guard, so the two agree.
// The crop overlay's dim area: the live crop while it has area, otherwise
// the last applied frame. A one-pixel drag is not a selection yet, so it does
// not replace the committed frame.
function cropDimRect(cropRect, cropFrame) {
  return cropRect !== null && cropRect.w > 1 && cropRect.h > 1 ? cropRect : cropFrame
}

function clampDocumentRect(r, vr) {
  if (r === null || r === undefined) return null
  const c = clampRect({ x: r.x - vr.x, y: r.y - vr.y, w: r.w, h: r.h }, vr.w, vr.h)
  return { x: vr.x + c.x, y: vr.y + c.y, w: c.w, h: c.h }
}

// The frame one export reads: the whole view, or the applied crop frame
// narrowed back into it. The view rect itself is returned unchanged when
// no frame is applied.
function exportViewRect(vr, cropFrame) {
  if (cropFrame === null || cropFrame === undefined) return vr
  return clampDocumentRect(cropFrame, vr)
}

// On-screen size of the picture itself, before rotation: the view rect times
// the fit and zoom the display box is built with. The box is that rect
// ROTATED, so laying the picture out against the box would resample its
// pixels to the swapped aspect and then spin the distortion - a quarter turn
// squeezed a 16:9 shot towards 9:16 on an unchanged wide footprint. At this
// size the rotation alone produces the box's footprint, because the box is
// exactly the rotated bounding box of this rect.
function pictureSize(vr, fit, zoom) {
  if (vr === null || vr === undefined) return { w: 1, h: 1 }
  const vw = _finite(vr.w) && vr.w > 0 ? vr.w : 0
  const vh = _finite(vr.h) && vr.h > 0 ? vr.h : 0
  const kFit = _finite(fit) && fit > 0 ? fit : 1
  const kZoom = _finite(zoom) && zoom > 0 ? zoom : 1
  const w = vw * kFit * kZoom
  const h = vh * kFit * kZoom
  return { w: _finite(w) && w > 0 ? w : 1, h: _finite(h) && h > 0 ? h : 1 }
}

// Exported pixel size. A quarter turn swaps the axes; the angle is
// reduced modulo 180 first so -90, 90 and 270 all swap exactly once, and
// an animated in-between angle does not, because the export never runs
// mid-animation.
function exportSize(vr, docRot) {
  const quarterTurn = ((Number(docRot) % 180) + 180) % 180 === 90
  return { w: quarterTurn ? vr.h : vr.w, h: quarterTurn ? vr.w : vr.h }
}

// A document point into the drawable area: the view rect, or its
// intersection with the applied frame. The bounds are folded in place
// rather than through an intersection rect, because rebuilding x from a
// width loses bits - x + (right - x) is not always right.
function clampDocPoint(p, vr, cropFrame) {
  let x0 = vr.x
  let y0 = vr.y
  let x1 = vr.x + vr.w
  let y1 = vr.y + vr.h
  if (cropFrame !== null && cropFrame !== undefined) {
    x0 = Math.max(x0, cropFrame.x)
    y0 = Math.max(y0, cropFrame.y)
    x1 = Math.min(x1, cropFrame.x + cropFrame.w)
    y1 = Math.min(y1, cropFrame.y + cropFrame.h)
  }
  // An inverted interval (a frame that misses the view) leaves the point
  // alone rather than snapping it to an unrelated edge.
  return { x: Math.max(x0, Math.min(x1, p.x)), y: Math.max(y0, Math.min(y1, p.y)) }
}

// The view rect alone, ignoring the frame: staging or resizing a crop
// has to reach the image edges and grow past the current frame, or
// re-cropping a bigger area would be impossible.
function clampViewPoint(p, vr) {
  return RectMath.clampPoint(p, vr)
}

// A document point inside the applied frame, or anywhere when no frame
// is applied - the default "everything is fair game" state.
function insideFrame(p, frame) {
  if (frame === null || frame === undefined) return true
  return p.x >= frame.x && p.x <= frame.x + frame.w
    && p.y >= frame.y && p.y <= frame.y + frame.h
}

// Eraser tolerance in document pixels: a constant on-screen size, so it
// narrows as the document is zoomed in. The scale is compared, not
// validated: a non-numeric value still coerces, and a non-finite one
// collapses to a zero tolerance rather than the default, which is what
// the paint scale has always done here.
function hitTolerance(k) {
  return k > 0 ? 6 / k : 6
}

// Loose document-pixel bounds of a stroke for the selection outline, in
// the order the region overlay's handleSpots uses. The text extent is the
// same estimate hitStroke tests against, but the two do not read a font
// size identically: this one takes a non-positive value literally, so a
// stroke that claims a negative font size gets a negative-height box here
// while its hit test keeps the default. No UI path builds one.
function strokeBounds(s) {
  const pts = s.points || []
  if (pts.length === 0) return null
  let x0 = pts[0].x
  let y0 = pts[0].y
  let x1 = pts[0].x
  let y1 = pts[0].y
  for (let i = 1; i < pts.length; i++) {
    x0 = Math.min(x0, pts[i].x)
    y0 = Math.min(y0, pts[i].y)
    x1 = Math.max(x1, pts[i].x)
    y1 = Math.max(y1, pts[i].y)
  }
  if (s.tool === "text") {
    const fs = s.fontSize || 24
    const lines = String(s.text || "").split("\n")
    const widest = lines.reduce((m, l) => Math.max(m, l.length), 0)
    x1 = Math.max(x1, x0 + widest * fs * 0.6)
    y1 = Math.max(y1, y0 + lines.length * fs * 1.2)
  }
  const pad = Math.max(4, (s.width || 3) / 2 + 4)
  return { x: x0 - pad, y: y0 - pad, w: x1 - x0 + pad * 2, h: y1 - y0 + pad * 2 }
}

// Whole-box hit test for the Select tool: an object is grabbable anywhere
// inside the bounds its outline draws, not only on the ink it painted, so a
// circle is selected from its middle and a rect from its fill. The eraser keeps
// the geometric hit test - erasing a ring from its hole would be wrong.
function hitStrokeBox(stroke, px, py) {
  if (stroke === null || stroke === undefined) return false
  if (!_finite(px) || !_finite(py)) return false
  const b = strokeBounds(stroke)
  if (b === null) return false
  return px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h
}

// The eight resize spots of a selection box - corners and edge midpoints -
// as fractions of the box with the cursor each one advertises. One table,
// because the editor's select frame, its crop frame and the region
// overlay's handles all index the same eight in the same order, and each
// had spelled the table out for itself: a row inserted in one copy
// silently shifted the cursor on two of the three surfaces.
//
// Corners sit on even indexes, edge midpoints on odd ones, and
// selectHandles below is indexed by the same order.
function resizeSpots() {
  return [
    { fx: 0, fy: 0, cur: Qt.SizeFDiagCursor },
    { fx: 0.5, fy: 0, cur: Qt.SizeVerCursor },
    { fx: 1, fy: 0, cur: Qt.SizeBDiagCursor },
    { fx: 1, fy: 0.5, cur: Qt.SizeHorCursor },
    { fx: 1, fy: 1, cur: Qt.SizeFDiagCursor },
    { fx: 0.5, fy: 1, cur: Qt.SizeVerCursor },
    { fx: 0, fy: 1, cur: Qt.SizeBDiagCursor },
    { fx: 0, fy: 0.5, cur: Qt.SizeHorCursor }
  ]
}

// The eight document-space resize handles of a selection box, in
// resizeSpots order: corners on even indexes, edge midpoints on odd ones.
function selectHandles(b) {
  if (b === null || b === undefined) return null
  return [
    { x: b.x, y: b.y },
    { x: b.x + b.w / 2, y: b.y },
    { x: b.x + b.w, y: b.y },
    { x: b.x + b.w, y: b.y + b.h / 2 },
    { x: b.x + b.w, y: b.y + b.h },
    { x: b.x + b.w / 2, y: b.y + b.h },
    { x: b.x, y: b.y + b.h },
    { x: b.x, y: b.y + b.h / 2 }
  ]
}

// --- text metrics ---
// Display-px inset for the staged text box, so the caret and the glyphs
// sit inside it with real margins. Proportional with guards: calm on a
// giant box, never eats a small one whole.
// The palette's spoken names, for the one place a tool label names a colour.
// Anything outside the palette is echoed verbatim, which is what keeps a
// caller's custom ink readable instead of blank.
var COLOR_NAMES = {
  "#ffffff": "white", "#000000": "black", "#ff5555": "red",
  "#50fa7b": "green", "#8be9fd": "cyan", "#f1fa8c": "yellow",
  "#bd93f9": "purple", "#ffb86c": "orange"
}

function colorName(value) {
  return COLOR_NAMES[value] || value
}

// Whether an exported path may be removed after the offer: a clipboard-owned
// output is kept, and anything the editor produced itself - a runtime output,
// or a target that did not exist before this export - belongs to the editor.
function shouldRemoveOutput(clipboardOwned, runtimeOutput, saveTargetExisted) {
  if (clipboardOwned === true) return false
  return runtimeOutput === true || saveTargetExisted !== true
}

// Which file type a save dialog's selected name filter asks for, falling back
// to the editor's own type. The filter is a human-facing label, so both the
// format word and the extension are read.
function saveDialogType(filter, fallback) {
  const f = String(filter ?? "").toLowerCase()
  if (f.indexOf("jpeg") >= 0 || f.indexOf(".jpg") >= 0) return "jpeg"
  if (f.indexOf("png") >= 0) return "png"
  return fallback === "jpeg" ? "jpeg" : "png"
}

// Whether an exported file may be removed after it is offered. A copy may
// remove a file it produced, but never the source itself unless that source is
// a one-shot runtime output; a save keeps the target only when the user asked
// for it on disk.
function exportDeleteAfter(kind, output, shotPath, oneShot, saveToDisk) {
  return kind === "copy"
    ? (output !== shotPath || oneShot === true)
    : saveToDisk !== true
}

function textPad(dispH) {
  return Range.clamp(Math.round(dispH * 0.15), 2, 12)
}

// Font size to commit, from the on-screen text size and the scale it was
// measured at. The scale is floored rather than rejected so a collapsed
// stage commits a minimum-size stroke instead of dividing by zero.
function commitFontSize(textPx, k) {
  const d = Math.max(0.001, k)
  return Math.max(1, Math.round(textPx / d))
}

// --- selection resize ---
// A finished rect resized by dragging one handle: the dragged side
// follows the pointer, the opposite side stays fixed, and dragging past
// it flips the rect through min/max. spot is a handleSpots entry, so fx
// and fy are 0, 0.5 or 1.
function resizeFromHandle(orig, spot, mx, my) {
  const fx0 = orig.x
  const fy0 = orig.y
  const fx1 = orig.x + orig.w
  const fy1 = orig.y + orig.h
  let rx0 = fx0
  let rx1 = fx1
  let ry0 = fy0
  let ry1 = fy1
  if (spot.fx === 0) {
    if (mx <= fx1) {
      rx0 = mx
      rx1 = fx1
    } else {
      rx0 = fx1
      rx1 = mx
    }
  } else if (spot.fx === 1) {
    if (mx >= fx0) {
      rx0 = fx0
      rx1 = mx
    } else {
      rx0 = mx
      rx1 = fx0
    }
  }
  if (spot.fy === 0) {
    if (my <= fy1) {
      ry0 = my
      ry1 = fy1
    } else {
      ry0 = fy1
      ry1 = my
    }
  } else if (spot.fy === 1) {
    if (my >= fy0) {
      ry0 = fy0
      ry1 = my
    } else {
      ry0 = my
      ry1 = fy0
    }
  }
  return { x: rx0, y: ry0, w: Math.max(0, rx1 - rx0), h: Math.max(0, ry1 - ry0) }
}

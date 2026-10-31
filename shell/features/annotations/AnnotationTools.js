// Pure annotation math: eraser hit tests, arrow geometry, crop
// translation, view/document mapping. The only import is the neutral rect
// primitive, so the capture service and these views share one normalize and
// one clamp instead of each keeping a copy.
//
// The document/view half of the same vocabulary lives here too, because
// the editor, the region overlay and the region capture path all resolve
// it from this one home: the document-rect clamp and the export frame, the
// point clamps, the selection bounds and their eight handles, the paint
// transform into backing pixels, and the mosaic grid with the sample
// offsets its two sources (the baked image and the live board) read from.
// Every function here takes the document state as arguments; nothing
// reads editor properties, so the library stays unit-drivable.
.pragma library
.import "../../common/capture/RectMath.js" as RectMath

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

// Corner pair -> aspect-locked rect (w/h == ratio), dominant axis
// wins, quadrant around the anchor preserved. Ratio <= 0 disables
// the lock (plain normRect).
function lockRect(x1, y1, x2, y2, ratio) {
  if (!_finite(x1) || !_finite(y1) || !_finite(x2) || !_finite(y2)) return _zeroRect()
  if (!_finite(ratio) || !(ratio > 0)) return normRect(x1, y1, x2, y2)
  const dx = x2 - x1
  const dy = y2 - y1
  let w = Math.abs(dx)
  let h = Math.abs(dy)
  if (w / ratio >= h) h = w / ratio
  else w = h * ratio
  return {
    x: dx >= 0 ? x1 : x1 - w,
    y: dy >= 0 ? y1 : y1 - h,
    w: w,
    h: h
  }
}

// Intersect with the frame; see RectMath.clampRect.
function clampRect(rect, fw, fh) {
  return RectMath.clampRect(rect, fw, fh)
}

// Shared fit policy for display geometry and input mapping.
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

// Overlay point -> document pixels. geom comes from boardGeom,
// vr is the view rect {x,y,w,h}, rot is 0/90/180/270.
function displayToDoc(mx, my, geom, vr, rot) {
  const x = _finite(mx) ? mx : 0
  const y = _finite(my) ? my : 0
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
  const bx = (x - gx) / k - dw / 2
  const by = (y - gy) / k - dh / 2
  const lx = bx * ca + by * sa + vw / 2
  const ly = -bx * sa + by * ca + vh / 2
  return {
    x: Math.max(vx, Math.min(vx + vw, lx + vx)),
    y: Math.max(vy, Math.min(vy + vh, ly + vy))
  }
}

// Inverse of displayToDoc, same arguments.
function docToDisplay(p, geom, vr, rot) {
  if (!_point(p)) return { x: 0, y: 0 }
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
  const cx = p.x - vx - vw / 2
  const cy = p.y - vy - vh / 2
  const bx = cx * ca - cy * sa + dw / 2
  const by = cx * sa + cy * ca + dh / 2
  return { x: gx + bx * k, y: gy + by * k }
}

function _segDist2(px, py, ax, ay, bx, by) {
  if (!_finite(px) || !_finite(py) || !_finite(ax) || !_finite(ay)
    || !_finite(bx) || !_finite(by)) return Infinity
  const dx = bx - ax
  const dy = by - ay
  const len2 = dx * dx + dy * dy
  let t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
  t = Math.max(0, Math.min(1, t))
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
// rect/ellipse test outline proximity, text tests its line box, blur
// tests the whole rect (easier to tap away than an outline).
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
  if (tool === "rect" || tool === "ellipse" || tool === "pixelate") {
    if (pts.length < 2) return false
    const r = _corners(stroke)
    if (tool === "pixelate") {
      return px >= r.x - tolBase && px <= r.x + r.w + tolBase
        && py >= r.y - tolBase && py <= r.y + r.h + tolBase
    }
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

// Crop filter for crop-commit: drops fully-outside strokes, keeps the
// rest VERBATIM in absolute document coordinates. Coordinates are never
// translated (the view rect owns the origin); translating here as well
// would double-shift every stroke. Partially-outside strokes stay whole -
// the canvas backing clips them for free.
// --- document view geometry ---
// A document rect inside the document view rect, in absolute document
// pixels. The subtraction is unguarded on purpose: a non-finite field is
// already 0 to clampRect's own guard, so the two agree.
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

// Document point -> canvas backing pixels under the paint transform: K
// scale, then rotation about the view rect center, into the rotated
// document size. getImageData addresses the backing directly, so this is
// the only doc-to-pixel map the mosaic and live-blur sampling use.
function docToBacking(p, vr, k, rotDeg, docW, docH) {
  const a = rotDeg * Math.PI / 180
  const ca = Math.cos(a)
  const sa = Math.sin(a)
  const dx = p.x - (vr.x + vr.w / 2)
  const dy = p.y - (vr.y + vr.h / 2)
  return {
    x: (dx * ca - dy * sa + docW / 2) * k,
    y: (dx * sa + dy * ca + docH / 2) * k
  }
}

// Bounding box of a document rect in backing pixels, for a getImageData
// call. Rounded per field rather than as a box: a rounded x with a
// separately rounded width can reach one pixel past the backing edge, and
// the caller drops the effect rather than read out of bounds.
// Mosaic cell grid over a document rect, clipped to the view rect. The
// grid is anchored to the view origin, not to the rect, so the same rect
// always mosaics into the same cells no matter how it was dragged out.
// The step grows with the rect so a full-screen mosaic stays bounded:
// 127 cells on the long axis at most, and never finer than 3px.
function pixelateGrid(r, vr) {
  if (r === null || r === undefined) return []
  const x0 = Math.max(vr.x, r.x)
  const y0 = Math.max(vr.y, r.y)
  const x1 = Math.min(vr.x + vr.w, r.x + r.w)
  const y1 = Math.min(vr.y + vr.h, r.y + r.h)
  if (!(x1 > x0) || !(y1 > y0)) return []
  const step = Math.max(3, Math.ceil(Math.max(x1 - x0, y1 - y0) / 127))
  const firstX = Math.floor((x0 - vr.x) / step)
  const lastX = Math.ceil((x1 - vr.x) / step)
  const firstY = Math.floor((y0 - vr.y) / step)
  const lastY = Math.ceil((y1 - vr.y) / step)
  const cells = []
  for (let gy = firstY; gy < lastY; gy++) {
    const cellY = vr.y + gy * step
    const drawY = Math.max(y0, cellY)
    const drawY1 = Math.min(y1, cellY + step)
    if (!(drawY1 > drawY)) continue
    for (let gx = firstX; gx < lastX; gx++) {
      const cellX = vr.x + gx * step
      const drawX = Math.max(x0, cellX)
      const drawX1 = Math.min(x1, cellX + step)
      if (!(drawX1 > drawX)) continue
      cells.push({
        rect: { x: drawX, y: drawY, w: drawX1 - drawX, h: drawY1 - drawY },
        center: {
          x: Math.max(drawX, Math.min(drawX1, cellX + step / 2)),
          y: Math.max(drawY, Math.min(drawY1, cellY + step / 2))
        }
      })
    }
  }
  return cells
}

// Where the export reads a mosaic's samples from: the mosaic rect's
// corners mapped through the export transform (unrotated view-relative
// coordinates, rotation, export size), floored into the surface and
// clamped to it. Null when the mapped box lands entirely off the export.
function pixelateBox(r, vr, size, rotDeg) {
  const a = rotDeg * Math.PI / 180
  const ca = Math.cos(a)
  const sa = Math.sin(a)
  const corners = [
    [r.x - vr.x, r.y - vr.y],
    [r.x + r.w - vr.x, r.y - vr.y],
    [r.x - vr.x, r.y + r.h - vr.y],
    [r.x + r.w - vr.x, r.y + r.h - vr.y]
  ]
  let x0 = Infinity
  let y0 = Infinity
  let x1 = -Infinity
  let y1 = -Infinity
  for (let i = 0; i < corners.length; i++) {
    const cx = corners[i][0] - vr.w / 2
    const cy = corners[i][1] - vr.h / 2
    const ox = cx * ca - cy * sa + size.w / 2
    const oy = cx * sa + cy * ca + size.h / 2
    x0 = Math.min(x0, ox)
    y0 = Math.min(y0, oy)
    x1 = Math.max(x1, ox)
    y1 = Math.max(y1, oy)
  }
  const bx = Math.max(0, Math.floor(x0))
  const by = Math.max(0, Math.floor(y0))
  const bw = Math.min(size.w, Math.ceil(x1)) - bx
  const bh = Math.min(size.h, Math.ceil(y1)) - by
  if (bw < 1 || bh < 1) return null
  return { x: bx, y: by, w: bw, h: bh }
}

// A surface mapper: document coordinates in, that surface's own pixels
// out. The same map has to place the sample box, place a cell, and place
// what a cell is drawn as, or a cell ends up read from one place and
// drawn to another. Unrotated surfaces - the baked image and the board -
// map through the view origin alone.
function surfaceMap(vr, size, rotDeg) {
  const a = rotDeg * Math.PI / 180
  const ca = Math.cos(a)
  const sa = Math.sin(a)
  return (x, y) => {
    const dx = x - vr.x - vr.w / 2
    const dy = y - vr.y - vr.h / 2
    return {
      x: dx * ca - dy * sa + size.w / 2,
      y: dx * sa + dy * ca + size.h / 2
    }
  }
}

// Pixel bounds of a document-space rect inside an already-fetched block,
// through a surface map. All four corners are mapped and their extent
// taken, so a rotated cell is covered by the box that contains it rather
// than by its centre alone. Clamped into the block, so a cell that only
// partly overlaps still reads the part that is there.
function cellBounds(x0, y0, x1, y1, map, box) {
  const cx = [x0, x1, x0, x1]
  const cy = [y0, y0, y1, y1]
  let ax = Infinity
  let ay = Infinity
  let bx = -Infinity
  let by = -Infinity
  for (let i = 0; i < 4; i++) {
    const p = map(cx[i], cy[i])
    ax = Math.min(ax, p.x)
    ay = Math.min(ay, p.y)
    bx = Math.max(bx, p.x)
    by = Math.max(by, p.y)
  }
  const rx = Math.max(0, Math.floor(ax) - box.x)
  const ry = Math.max(0, Math.floor(ay) - box.y)
  // Both edges move into the block, not just the near one: subtracting
  // box.x from one side alone makes a cell whose block does not start at
  // the surface origin read a span as wide as the cell plus that offset,
  // so every cell would average in its neighbour's pixels.
  const rw = Math.min(box.w, Math.ceil(bx) - box.x) - rx
  const rh = Math.min(box.h, Math.ceil(by) - box.y) - ry
  if (rw < 1 || rh < 1) return null
  return { x: rx, y: ry, w: rw, h: rh }
}

// Mean colour of a block of pixels, which is what a mosaic cell is: the
// average of everything it covers, not one texel. A single sample is not
// a sample of the cell - at the step pixelateGrid picks for a large
// region, any feature thinner than a cell misses the centre, the cell
// comes back the background colour, and the whole region collapses into a
// flat slab with the picture only showing round its edges. Returns null
// for an empty or out-of-block span, so a cell that fell off the surface
// is skipped rather than filled with garbage.
function cellMean(px, box, b) {
  if (!px || !px.data || px.data.length < 4 || b === null || b === undefined) return null
  const x0 = Math.max(0, b.x)
  const y0 = Math.max(0, b.y)
  const x1 = Math.min(box.w, b.x + b.w)
  const y1 = Math.min(box.h, b.y + b.h)
  if (x1 <= x0 || y1 <= y0) return null
  let r = 0
  let g = 0
  let bl = 0
  let n = 0
  for (let y = y0; y < y1; y++) {
    let o = (y * box.w + x0) * 4
    for (let x = x0; x < x1; x++) {
      r += px.data[o]
      g += px.data[o + 1]
      bl += px.data[o + 2]
      n++
      o += 4
    }
  }
  if (n === 0) return null
  return [Math.round(r / n), Math.round(g / n), Math.round(bl / n)]
}

// One source span per grid cell for that box: the cell rect to draw, and
// the block pixels to read its colour from. The cell's own corners are
// mapped, not its centre, so the span covers the cell.
function pixelateSamples(grid, vr, size, rotDeg, box) {
  if (!Array.isArray(grid) || box === null || box === undefined) return []
  const map = surfaceMap(vr, size, rotDeg)
  const out = []
  for (let i = 0; i < grid.length; i++) {
    const rect = grid[i].rect
    out.push({
      rect: rect,
      box: cellBounds(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, map, box)
    })
  }
  return out
}

// Where the live blur reads its samples from the baked image: the grid
// in view-relative image pixels, clamped to the image. Unrotated, because
// the baked backing is the unrotated image.
function blurSampleBox(grid, vr, imgW, imgH) {
  if (!Array.isArray(grid) || grid.length === 0) return null
  let x0 = Infinity
  let y0 = Infinity
  let x1 = -Infinity
  let y1 = -Infinity
  for (let i = 0; i < grid.length; i++) {
    const rect = grid[i].rect
    x0 = Math.min(x0, rect.x - vr.x)
    y0 = Math.min(y0, rect.y - vr.y)
    x1 = Math.max(x1, rect.x - vr.x + rect.w)
    y1 = Math.max(y1, rect.y - vr.y + rect.h)
  }
  const bx = Math.max(0, Math.floor(x0))
  const by = Math.max(0, Math.floor(y0))
  const bw = Math.min(imgW, Math.ceil(x1)) - bx
  const bh = Math.min(imgH, Math.ceil(y1)) - by
  if (bw < 1 || bh < 1) return null
  return { x: bx, y: by, w: bw, h: bh }
}

function blurSamples(grid, vr, box) {
  if (!Array.isArray(grid) || box === null || box === undefined) return []
  const map = surfaceMap(vr, { w: vr.w, h: vr.h }, 0)
  const out = []
  for (let i = 0; i < grid.length; i++) {
    const rect = grid[i].rect
    out.push({
      rect: rect,
      box: cellBounds(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, map, box)
    })
  }
  return out
}

// --- text metrics ---
// Display-px inset for the staged text box, so the caret and the glyphs
// sit inside it with real margins. Proportional with guards: calm on a
// giant box, never eats a small one whole.
function textPad(dispH) {
  return Math.max(2, Math.min(12, Math.round(dispH * 0.15)))
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

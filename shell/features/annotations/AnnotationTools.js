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
  if (tool === "blur") {
    // A blur region is a filled area, not an outline: clicking anywhere in it
    // erases it, which is the only thing the eraser could mean here.
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

// Transition model for the wallpaper view: kinds, speed presets and the
// per-frame geometry behind each effect. The catalog is none/fade/slide/
// swipe/circle plus `random`; the mask reveals (slanted swipe, growing
// circle, shrinking hole) all ride the same single progress value, which
// the view also drives the crossfade and the slide offsets from. Curves
// are deliberately NOT configurable - each kind owns a hardcoded easing
// in the view; speeds only scale duration.
//
// Pure logic, no Qt/QML imports, so this stays testable from node like
// the bar modules' Model.js files. The view binds thin wrappers around
// these helpers; nothing here touches items or animations.

function transitions() {
  return ["none", "fade", "slide", "swipe", "circle", "random"]
}

// Kinds the random pool may yield. `none` (a confusing no-op win) and
// `random` itself are excluded.
function randomPool() {
  return ["fade", "slide", "swipe", "circle"]
}

function speeds() {
  return { slow: 1200, def: 600, fast: 250 }
}

// Directions and modes retired into their randomized parents: the four
// slide keys, grow/outer and all wipe keys. Unknown/hand-edited values
// fall back to the plain crossfade.
function normalizeKind(raw) {
  var k = String(raw || "").trim().toLowerCase()
  if (k === "wipe" || k === "wipe-horizontal" || k === "wipe-vertical") return "swipe"
  if (k === "slide-left" || k === "slide-right" || k === "slide-top" || k === "slide-bottom") return "slide"
  if (k === "grow" || k === "outer") return "circle"
  return transitions().indexOf(k) >= 0 ? k : "fade"
}

// Slide directions, rolled per swap for the single "slide" kind.
function slideDirections() {
  return ["left", "right", "top", "bottom"]
}

function normalizeDirection(raw) {
  var d = String(raw || "").trim().toLowerCase()
  return slideDirections().indexOf(d) >= 0 ? d : "left"
}

// Resolve one swap's kind. `rand01` is injectable so tests stay
// deterministic (the view passes Math.random()).
function resolveKind(raw, rand01) {
  var k = normalizeKind(raw)
  if (k !== "random") return k
  var pool = randomPool()
  var r = Number(rand01)
  if (isNaN(r) || r < 0) r = 0
  if (r >= 1) r = 0.999999
  return pool[Math.floor(r * pool.length)]
}

function normalizeSpeed(raw) {
  var s = String(raw || "").trim().toLowerCase()
  if (s === "slow" || s === "fast") return s
  return "default"
}

// Every kind follows the selected speed preset; curves stay hardcoded
// per kind in the view.
function durationFor(speed) {
  var table = speeds()
  if (speed === "slow") return table.slow
  if (speed === "fast") return table.fast
  return table.def
}

// Kinds rendered through the mask layer (swipe band / circles). Slides
// translate the layer and fades crossfade it - neither needs a mask.
function isMaskKind(kind) {
  return isSwipeKind(kind) || kind === "circle"
}

function isSwipeKind(kind) {
  return String(kind || "") === "swipe"
}

// Slide offset in px for progress 0..1: the new frame travels from a
// full screen off the named edge to rest. `from` is rolled per swap;
// w/h are the surface size.
function slideOffset(from, progress, w, h) {
  var p = clamp01(progress)
  var rest = 1 - p
  var d = normalizeDirection(from)
  // + 0 normalizes -0 (rest = 0) to 0 for strict consumers.
  if (d === "left") return { x: -rest * w + 0, y: 0 }
  if (d === "right") return { x: rest * w + 0, y: 0 }
  if (d === "top") return { x: 0, y: -rest * h + 0 }
  return { x: 0, y: rest * h + 0 }
}

// Scalar axis helpers for the per-tick slide bindings: one call per axis,
// zero object allocs. Object form above stays for tests and compat.
function slideX(from, progress, w) {
  var p = clamp01(progress)
  var rest = 1 - p
  var d = normalizeDirection(from)
  if (d === "left") return -rest * w + 0
  if (d === "right") return rest * w + 0
  return 0
}

function slideY(from, progress, h) {
  var p = clamp01(progress)
  var rest = 1 - p
  var d = normalizeDirection(from)
  if (d === "top") return -rest * h + 0
  if (d === "bottom") return rest * h + 0
  return 0
}

// Slanted reveal band as a plain rotated rectangle. progress 0..1
// grows the band width 0 -> full coverage around (centerFracX,
// centerFracY); angleDeg orients the band's long axis in QML clockwise
// degrees (0 sweeps horizontally, 90 vertically, anything between
// diagonally) and is rolled fresh per swap. Extents are exact maxima
// over the frame corners, so p = 1 provably covers the frame from any
// origin at any angle; the +4 margin scales with progress so p = 0
// stays exactly shut. Returns frame-space center, full size and the
// echoed angle for a centered rectangle.
function swipeBandRect(progress, w, h, centerFracX, centerFracY, angleDeg) {
  var p = clamp01(progress)
  var cx = w * fracOr(centerFracX, 0.5)
  var cy = h * fracOr(centerFracY, 0.5)
  var a = Number(angleDeg) * Math.PI / 180
  if (isNaN(a)) a = 0
  // Long-axis unit of a tall rect rotated by a (QML convention), plus
  // its perpendicular.
  var ux = -Math.sin(a)
  var uy = Math.cos(a)
  var vx = Math.cos(a)
  var vy = Math.sin(a)
  var needA = 0
  var needP = 0
  var corners = [[0 - cx, 0 - cy], [w - cx, 0 - cy], [0 - cx, h - cy], [w - cx, h - cy]]
  for (var i = 0; i < corners.length; i++) {
    var ta = Math.abs(corners[i][0] * ux + corners[i][1] * uy)
    var tp = Math.abs(corners[i][0] * vx + corners[i][1] * vy)
    if (ta > needA) needA = ta
    if (tp > needP) needP = tp
  }
  var degrees = Number(angleDeg)
  if (isNaN(degrees)) degrees = 0
  return {
    cx: cx,
    cy: cy,
    fullW: 2 * (needP + 4) * p,
    fullH: 2 * (needA + 4),
    angleDeg: degrees
  }
}

// Diameter of the reveal disc (grow) or the concealing disc (outer,
// rendered through the effect's inverted mask) for progress 0..1.
// The disc is centered on (centerFracX, centerFracY) and sized to cover
// the farthest corner from there, so p = 1 (grow) always fills the
// frame from any origin. invert flips the sweep for the shrink variant.
function discDiameter(progress, w, h, centerFracX, centerFracY, invert) {
  var p = clamp01(progress)
  var cx = w * fracOr(centerFracX, 0.5)
  var cy = h * fracOr(centerFracY, 0.5)
  var dx = Math.max(cx, w - cx)
  var dy = Math.max(cy, h - cy)
  var diameter = 2 * Math.sqrt(dx * dx + dy * dy) * 1.04
  return invert ? diameter * (1 - p) : diameter * p
}

function fracOr(v, fallback) {
  var n = Number(v)
  if (isNaN(n)) return fallback
  if (n < 0) return 0
  if (n > 1) return 1
  return n
}

function clamp01(v) {
  var n = Number(v)
  if (isNaN(n)) return 0
  if (n < 0) return 0
  if (n > 1) return 1
  return n
}

if (typeof module !== "undefined") {
  module.exports = {
    transitions: transitions,
    randomPool: randomPool,
    speeds: speeds,
    normalizeKind: normalizeKind,
    resolveKind: resolveKind,
    normalizeSpeed: normalizeSpeed,
    durationFor: durationFor,
    isMaskKind: isMaskKind,
    isSwipeKind: isSwipeKind,
    slideDirections: slideDirections,
    normalizeDirection: normalizeDirection,
    slideOffset: slideOffset,
    slideX: slideX,
    slideY: slideY,
    swipeBandRect: swipeBandRect,
    discDiameter: discDiameter,
    clamp01: clamp01
  }
}

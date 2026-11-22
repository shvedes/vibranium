.pragma library

// Reference field: PasswordBox's 320x44 box with 24px echo glyphs. Every pose
// and cadence is derived from those dimensions, so a field that matches the
// reference feels identical and a roomier or tighter one scales with it.
const REF_HEIGHT = 44
const REF_FONT = 24

// A field's share of the reference motion: the smaller of its type ratio and
// its box ratio. Type sets how far a glyph can travel before the jump reads as
// a shake; the box sets how much room there is around it. A field at the
// reference dimensions lands on exactly 1.
function poseScale(fontSize, height) {
  if (!(fontSize > 0) || !(height > 0)) return 1
  const byType = fontSize / REF_FONT
  const byBox = height / REF_HEIGHT
  return Math.max(0.35, Math.min(1.8, Math.min(byType, byBox)))
}

// Per-glyph jump poses for the caps-lock echo. A tick is a new pose; glyph i's
// pose is derived from the tick and its index, so a tick moves every glyph
// without touching the model that holds them.
//
// Deterministic: the sine scramble is the whole state, so any glyph's pose can
// be recomputed from (i, tick) alone. scale is the caller's share of the
// reference pose, so a small field keeps the same scramble at a lower
// amplitude without a second set of constants.

function offsetX(i, tick, scale) {
  const k = scale === undefined ? 1 : scale
  const v = Math.sin((i + 1) * 12.9898 + tick * 78.233) * 43758.5453
  return (v - Math.floor(v) - 0.5) * 6 * k
}

function offsetY(i, tick, scale) {
  const k = scale === undefined ? 1 : scale
  const v = Math.sin((i + 1) * 39.3465 + tick * 11.135) * 24634.6345
  return (v - Math.floor(v) - 0.5) * 10 * k
}

// Irregular cadence, denser as the pose grows: a roomier field changes its
// rhythm more often, a tighter one holds each pose longer. The cadence follows
// the square root of the pose rather than its inverse, so a small field slows
// gently instead of stretching every pose to two or three times the base. A
// steady metronome reads as a wobble, so the base range itself is random.
function nextInterval(scale) {
  const s = scale > 0 ? Math.sqrt(scale) : 1
  return Math.max(35, Math.round((70 + Math.random() * 90) / s))
}

// The one smoothing leg between two poses. It deliberately outlives a tick:
// the next pose arrives before the current tween has finished, so consecutive
// poses blend into each other. That blend is the look, not a bug - a leg
// shorter than the cadence reads as a jump instead. The value lives here so
// both fields agree on it instead of each carrying a copy.
function poseMs() {
  return 220
}

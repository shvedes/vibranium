.pragma library

// Per-glyph jump poses for the caps-lock echo. A tick is a new pose; glyph i's
// pose is derived from the tick and its index, so a tick moves every glyph
// without touching the model that holds them.
//
// Deterministic: the sine scramble is the whole state, so any glyph's pose can
// be recomputed from (i, tick) alone.

function offsetX(i, tick) {
  const v = Math.sin((i + 1) * 12.9898 + tick * 78.233) * 43758.5453
  return (v - Math.floor(v) - 0.5) * 6
}

function offsetY(i, tick) {
  const v = Math.sin((i + 1) * 39.3465 + tick * 11.135) * 24634.6345
  return (v - Math.floor(v) - 0.5) * 10
}

// Irregular cadence: a steady metronome reads as a wobble, while the point is
// a scramble that changes its own rhythm.
function nextInterval() {
  return 70 + Math.floor(Math.random() * 90)
}

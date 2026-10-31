.pragma library

// Keyboard-navigation arithmetic shared by the island key router
// (IslandNav.qml) and the two list primitives (List.qml, GridList.qml).
//
// WHY IT EXISTS. Two consumers answer "which target does this key mean,
// and where does the cursor land". Each of them is a key handler in a
// different window (a card, a list), and a rule answered twice is a rule
// that drifts: one of them wraps at the end, one clamps, and the island
// and the list disagree about what Left does on the last row. The
// arithmetic is the shared rule; what a row IS is not, and stays with the
// consumer - exactly the split RowMetrics.js makes between the sum and the
// per-row height.
//
// NO Qt IN HERE. A `.pragma library` that imported QtQml could not be loaded
// by the unit suite that covers this file, so the key codes arrive as DATA:
// the caller passes the four `Qt.Key_*` values it wants (keyCodes in
// IslandNav) and this module only compares. The cost is one object per call
// site; the gain is that every answer below is drivable headlessly.
//
// THE TWO ANSWERS. `axis` is the row axis: what a bar strip is (one line of
// modules) and what a list is. `cell` is the same question in two dimensions,
// for a grid whose last row is short. Both answer -1 for "there is no such
// target", which is the caller's signal to leave the cursor where it is -
// distinct from answering the current index, which would read as a move.

// The direction a key names, as a unit step. Null for a key that is not a
// direction, so a caller can tell "not a direction" from "the first one".
//
// `codes` is { left, right, up, down } of Qt.Key_* values, supplied by the
// caller: this module never names a Qt enum.
function direction(key, codes) {
  if (!codes) return null
  if (key === codes.left) return { dx: -1, dy: 0 }
  if (key === codes.right) return { dx: 1, dy: 0 }
  if (key === codes.up) return { dx: 0, dy: -1 }
  if (key === codes.down) return { dx: 0, dy: 1 }
  return null
}

// The direction a vim-cluster key names. Lowercase only, because an uppercase
// letter arrives as a shifted key and a shifted key is a modifier gesture: the
// media island's Shift+Right is "seek forward", and answering it as "next
// column" would make one physical gesture mean two things depending on which
// island is open. The caller passes `event.text`, so the keys are already
// characters here and this library still touches no Qt enum.
//
// Null for a character that is not in the cluster. Note what is NOT here: no
// `x` (delete) and no letters for shortcuts. Those are single-shot actions,
// not directions, and folding them into a direction table is how a panel ends
// up navigating when it meant to delete.
function vim(text) {
  if (typeof text !== 'string') return null
  switch (text) {
    case 'h': return { dx: -1, dy: 0 }
    case 'l': return { dx: 1, dy: 0 }
    case 'k': return { dx: 0, dy: -1 }
    case 'j': return { dx: 0, dy: 1 }
  }
  return null
}

// One row step. `delta` is -1 or +1 (0 is answered with -1: there is no
// keyboard gesture that stands still, and a caller that passes it has a
// direction table bug rather than a cursor position).
//
// An index below 0 means the consumer has no cursor yet: the first step lands
// on the edge the direction points at, so a freshly opened surface starts
// where the eye is already looking (top for Down, bottom for Up) instead of
// in the middle.
//
// wrap cycles (0 -> count - 1) and clamps with -1 at the edge, so the two
// policies cannot be confused for one another: a wrapped list answers a real
// index, a clamped one says there is nowhere to go.
function axis(index, count, delta, wrap) {
  if (!(count > 0)) return -1
  if (delta === 0) return -1
  let i = index
  if (i < 0) return delta > 0 ? 0 : count - 1
  if (wrap === true) return (((i + delta) % count) + count) % count
  const next = i + delta
  return next < 0 || next >= count ? -1 : next
}

// One cell step on a `cols`-wide grid. The row axis is the same policy as
// `axis`; the column axis is scoped to the current row, because a
// Left/Right that jumped to the next row would turn a two-column grid into a
// single strip and make Up/Down redundant.
//
// The short last row is the whole reason this is not `index + delta * cols`:
// a 5-cell grid with 3 columns has cells 3 and 4 on a row of two, so Right on
// cell 2 has nowhere to go and Down from cell 4 lands on cell 3 rather than
// off the end.
function cell(index, count, cols, dx, dy, wrap) {
  if (!(count > 0)) return -1
  if (dx === 0 && dy === 0) return -1
  const c = cols > 0 ? cols : 1
  const rows = Math.ceil(count / c)
  // How many cells row `row` actually has. Every full row has c of them and
  // only the last can be short, and this is the one line a naive
  // `index + dx * c` / `index + dy * cols` gets wrong: it treats the last row
  // as full, so a horizontal step walks off the end of the set and a vertical
  // one lands on a cell that was never there.
  const rowLen = (row) => Math.min(c, count - row * c)
  if (index < 0) return dx < 0 || dy < 0 ? count - 1 : 0
  const row = Math.floor(index / c)
  const col = index % c
  if (dx === 0) {
    // Vertical: keep the column, clamp or cycle the row. A column the target
    // row does not have folds to that row's last cell, so Down from the last
    // column of a full row is the last cell below rather than an error.
    let next = row + dy
    if (next < 0 || next >= rows) {
      if (wrap !== true) return -1
      next = ((next % rows) + rows) % rows
    }
    return next * c + Math.min(col, rowLen(next) - 1)
  }
  // Horizontal: scoped to the row, which may be the short one.
  const inRow = rowLen(row)
  let nextCol = col + dx
  if (nextCol < 0 || nextCol >= inRow) {
    if (wrap !== true) return -1
    nextCol = ((nextCol % inRow) + inRow) % inRow
  }
  return row * c + nextCol
}

// The direction a named axis step projects onto the row axis, for a
// consumer that is one-dimensional and receives a two-dimensional key. A
// vertical step wins when both are set, because a diagonal is not a key a
// user can press; horizontal is what Left/Right mean on a list.
function project(dx, dy) {
  // `!== 0` is not the guard it looks like: undefined !== 0 is true, so a
  // caller that forwarded a missing argument would get a confident 1. Being
  // a number is the guard, and it is also the only way a caller can be sure a
  // non-numeric value is refused rather than routed.
  if (typeof dy === 'number' && dy !== 0) return dy < 0 ? -1 : 1
  if (typeof dx === 'number' && dx !== 0) return dx < 0 ? -1 : 1
  return 0
}
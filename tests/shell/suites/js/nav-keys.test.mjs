#!/usr/bin/env node
// Suite: shell/common/ui/NavKeys.js - the keyboard-navigation arithmetic the
// island router and the two list primitives share.
//
// ## Why this file is tested at all
//
// The island key router (IslandNav.qml) and the two list primitives answer
// "which target does this key mean, and where does the cursor land".
// None of them is reachable by a test
// otherwise - the router sits inside a PanelWindow that qmltestrunner cannot
// load, and the two list types need a real view with delegates and a model -
// so a rule answered twice would be free to drift, and the drift shows
// up as "Left does something different in this island".
//
// The arithmetic is also where the sharp edge lives: a grid whose last row is
// short. `index + delta * cols` is right for every full row and wrong at the
// end of the set, which is exactly the case that only appears once a grid has
// more cells than its column count divides, and it is the case a construction
// probe and an eyeball pass both miss.
//
// This file is pure (`.pragma library`, no Qt import), so it is drivable
// here rather than only through the UI that uses it.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, deepEqual, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const FILE = path.join(SHELL_DIR, 'common/ui/NavKeys.js')
const NK = loadLib(FILE)

// Stand-in Qt key codes. The library never names a Qt enum by design - the
// caller hands the table in - so these are arbitrary distinct integers and a
// test that passes them proves the indirection works.
const K = { left: 0x01000012, right: 0x01000014, up: 0x01000013, down: 0x01000015 }
const OTHER = 0x41 // 'A'

suite('nav-keys', 'one direction table and one step rule, shared by every keyboard surface')

section('direction - the key -> unit step table')

group('each key names its own axis', () => {
  deepEqual('left is -1 on x and nothing on y', NK.direction(K.left, K), { dx: -1, dy: 0 })
  deepEqual('right is +1 on x', NK.direction(K.right, K), { dx: 1, dy: 0 })
  deepEqual('up is -1 on y', NK.direction(K.up, K), { dx: 0, dy: -1 })
  deepEqual('down is +1 on y', NK.direction(K.down, K), { dx: 0, dy: 1 })
})

group('a key that is not a direction is null, not a zero step', () => {
  eq('an unrelated key', NK.direction(OTHER, K), null)
  eq('Enter is not a direction', NK.direction(0x01000004, K), null)
  // The distinction matters: the router accepts an arrow only on a real step,
  // and "not a direction" and "a direction of zero" would both read as
  // no-op while meaning different things to a caller that reuses the table.
  ne('null is not the zero step', NK.direction(OTHER, K), { dx: 0, dy: 0 })
})

group('a missing or partial table answers null rather than throwing', () => {
  eq('no table at all', NK.direction(K.left, null), null)
  eq('an empty table', NK.direction(K.left, {}), null)
  // A table that names only some of the four still works for the ones it
  // names, and declines the rest: a surface with a bespoke direction key can
  // pass its own table without having to name the other three.
  eq('a one-key table answers that key', NK.direction(K.up, { up: K.up }), { dx: 0, dy: -1 })
  eq('and declines the ones it omits', NK.direction(K.down, { up: K.up }), null)
})

section('axis - one row step')

group('an ordinary step inside the set', () => {
  eq('down from the top', NK.axis(0, 5, 1, true), 1)
  eq('up from the middle', NK.axis(2, 5, -1, true), 1)
  eq('down from the last-but-one', NK.axis(3, 5, 1, true), 4)
})

group('wrap cycles and clamp refuses, and the two are distinguishable', () => {
  eq('down past the end wraps to the top', NK.axis(4, 5, 1, true), 0)
  eq('up past the top wraps to the end', NK.axis(0, 5, -1, true), 4)
  // -1 is the caller's "there is nowhere to go", and it is deliberately not
  // the index it refused: a clamped list that answered 4 for a step off the
  // end would silently jump to the far side.
  eq('down past the end clamps', NK.axis(4, 5, 1, false), -1)
  eq('up past the top clamps', NK.axis(0, 5, -1, false), -1)
  eq('a clamped step in the middle still moves', NK.axis(2, 5, -1, false), 1)
})

group('an empty set has no target', () => {
  eq('zero rows', NK.axis(0, 0, 1, true), -1)
  eq('a negative count is not a set', NK.axis(0, -3, 1, true), -1)
  eq('undefined', NK.axis(0, undefined, 1, true), -1)
})

group('a zero step is refused rather than treated as "stay put"', () => {
  // A caller passing 0 has a direction-table bug, and answering the current
  // index would hide it: the router would consume a key that moved nothing.
  eq('zero from a seated cursor', NK.axis(2, 5, 0, true), -1)
  eq('zero from an unseated cursor', NK.axis(-1, 5, 0, true), -1)
})

group('an unseated cursor lands where the direction points', () => {
  // The first step onto a surface that has no cursor yet starts where the eye
  // is already looking, rather than in the middle of the set.
  eq('down lands on the first row', NK.axis(-1, 5, 1, true), 0)
  eq('up lands on the last row', NK.axis(-1, 5, -1, true), 4)
  // And the landing respects the policy, so a clamped surface still lands
  // inside itself rather than refusing the very first step.
  eq('clamped down still lands on the first', NK.axis(-1, 5, 1, false), 0)
  eq('clamped up still lands on the last', NK.axis(-1, 5, -1, false), 4)
  eq('one row, down', NK.axis(-1, 1, 1, true), 0)
  eq('one row, up', NK.axis(-1, 1, -1, true), 0)
})

group('a negative index deeper than -1 is the same unseated state', () => {
  eq('down', NK.axis(-7, 4, 1, true), 0)
  eq('up', NK.axis(-7, 4, -1, true), 3)
})

section('cell - one step on a grid')

group('a full grid steps by its own shape', () => {
  eq('right within a row', NK.cell(0, 6, 3, 1, 0, false), 1)
  eq('left within a row', NK.cell(2, 6, 3, -1, 0, false), 1)
  eq('down a row keeps the column', NK.cell(1, 6, 3, 0, 1, false), 4)
  eq('up a row keeps the column', NK.cell(4, 6, 3, 0, -1, false), 1)
})

group('a row edge is where a horizontal step stops, not the next row', () => {
  // This is the reason cell() exists rather than arithmetic in the caller: a
  // flat step off the right edge of one row lands on the first cell of the
  // next, a whole row from where the key said, and it makes Up/Down
  // redundant on a grid.
  eq('right off the end of a row', NK.cell(2, 6, 3, 1, 0, false), -1)
  eq('left off the front of a row', NK.cell(3, 6, 3, -1, 0, false), -1)
  eq('and wrapping stays inside the row', NK.cell(2, 6, 3, 1, 0, true), 0)
  eq('wrapping the other way', NK.cell(3, 6, 3, -1, 0, true), 5)
})

group('the short last row is handled, which is the whole point', () => {
  // 5 cells in 3 columns: row 0 is 0..2, row 1 is 3..4 and has no third
  // cell. Every answer below is the case `index + delta * cols` gets wrong.
  eq('the last row is short', NK.cell(4, 5, 3, 1, 0, false), -1)
  eq('left from the short row works', NK.cell(4, 5, 3, -1, 0, false), 3)
  // Down from the last full column has no cell below it, so the answer is
  // the last cell that exists in that row.
  eq('down from the column the short row lacks', NK.cell(2, 5, 3, 0, 1, false), 4)
  eq('down past the final row is refused', NK.cell(4, 5, 3, 0, 1, false), -1)
  eq('up off the top row is refused', NK.cell(1, 5, 3, 0, -1, false), -1)
})

group('a one-column grid is the row case', () => {
  eq('right is refused', NK.cell(0, 4, 1, 1, 0, false), -1)
  eq('down', NK.cell(0, 4, 1, 0, 1, false), 1)
  eq('a zero column count degenerates to one', NK.cell(0, 4, 0, 0, 1, false), 1)
})

group('a degenerate set and a degenerate step', () => {
  eq('no cells', NK.cell(0, 0, 3, 1, 0, true), -1)
  eq('a negative cell count', NK.cell(0, -2, 3, 1, 0, true), -1)
  eq('no direction at all', NK.cell(0, 5, 3, 0, 0, true), -1)
})

group('an unseated cursor lands where the direction points', () => {
  eq('down lands on the first cell', NK.cell(-1, 5, 3, 0, 1, true), 0)
  eq('right lands on the first cell', NK.cell(-1, 5, 3, 1, 0, true), 0)
  eq('up lands on the last cell', NK.cell(-1, 5, 3, 0, -1, true), 4)
  eq('left lands on the last cell', NK.cell(-1, 5, 3, -1, 0, true), 4)
})

group('a single-cell grid answers itself rather than refusing', () => {
  // Every step on a one-cell grid is a step onto itself. Answering that cell
  // rather than -1 is what lets the caller distinguish "nowhere else to go"
  // (a real edge) from "this is all there is".
  eq('down', NK.cell(0, 1, 3, 0, 1, true), 0)
  eq('right', NK.cell(0, 1, 3, 1, 0, true), 0)
})

section('project - a 2-D direction onto a row axis')

group('a vertical step wins, because a diagonal is not a key', () => {
  eq('down', NK.project(0, 1), 1)
  eq('up', NK.project(0, -1), -1)
  // Both axes set cannot come from direction(), but a caller composing two
  // answers can produce it, and the vertical half is the defined answer.
  eq('a diagonal takes the vertical half', NK.project(1, 1), 1)
  eq('and in the other quadrant too', NK.project(-1, -1), -1)
})

group('a horizontal-only direction reads as previous / next', () => {
  eq('right', NK.project(1, 0), 1)
  eq('left', NK.project(-1, 0), -1)
})

group('no direction projects to no step', () => {
  eq('the origin', NK.project(0, 0), 0)
  eq('missing arguments', NK.project(undefined, undefined), 0)
})

finish()
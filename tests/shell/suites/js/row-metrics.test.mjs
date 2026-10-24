#!/usr/bin/env node
// Suite: shell/common/ui/RowMetrics.js - the whole-row height arithmetic both
// cards share.
//
// ## Why this file is tested at all
//
// The rule was written TWICE - once in PanelCard, once in MenuPanel, plus a
// third time inside MenuPanel's ten-row cap - and being written three times
// is what let it drift. The surfaces answer the same question, "how tall is
// this list", and the answer has one property that matters above all: the
// result is a WHOLE-ROW sum, so a region built from it ends on the bottom
// edge of a row rather than part-way through one. A row rendered half
// visible is the symptom, and it only appears for a list whose rows cross
// the available space, so it is exactly the case a construction probe
// misses.
//
// None of the three copies was reachable by a test. All three lived in
// panels, and a panel needs a window backend to instantiate - the
// construction suite classifies every one of them as "needs-environment" for
// exactly that reason. This file is pure, so it is not reachable that way.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const FILE = path.join(SHELL_DIR, 'common/ui/RowMetrics.js')
const RM = loadLib(FILE)

// A list's own gap on this tree (List.spacing, 2). Every expectation is
// written as a sum of explicit row heights plus this, so a change to the
// tree's spacing does not silently move an answer.
const SP = 2

// Rows of one shape: the common case, and the one where "probe the first row
// and multiply" happens to be right.
const uniform = (n, height) => Array.from({ length: n }, () => height)

// Rows of mixed shape. The reason a whole-row sum is not a count times a
// height: 10, 20, 30, 20, 10 is 90 plus four gaps, and 5 x 18 would land in
// the same neighbourhood - so a list that mixes a short row and a tall one
// is exactly where an averaged estimate cuts a row.
const mixed = [10, 20, 30, 20, 10]
const identity = (row) => row

suite('row-metrics', 'how tall is this list is one rule, and its answer is a whole-row sum')

section('limitOf')

group('a cap of zero or less means every row', () => {
  eq('no cap on a long list', RM.limitOf(5, 0), 5)
  eq('a negative cap is still no cap', RM.limitOf(5, -3), 5)
})

group('a positive cap bounds it', () => {
  eq('under the cap', RM.limitOf(5, 3), 3)
  eq('at the cap', RM.limitOf(5, 5), 5)
  eq('a cap past the end takes every row', RM.limitOf(2, 5), 2)
  // A fractional cap cannot address a row boundary, so it floors rather
  // than summing a slice of a row.
  eq('a fractional cap floors', RM.limitOf(5, 2.9), 2)
})

section('contentH - the height of a row set')

group('whole rows plus the gap between them', () => {
  eq('one row has no gap', RM.contentH([30], 0, identity, SP), 30)
  eq('two rows', RM.contentH([30, 30], 0, identity, SP), 30 + 30 + SP)
  eq('three uniform rows', RM.contentH(uniform(3, 30), 0, identity, SP), 3 * 30 + 2 * SP)
  eq('empty is zero', RM.contentH([], 0, identity, SP), 0)
})

group('a mixed row set is the sum of its rows, not a count times one of them', () => {
  eq('mixed', RM.contentH(mixed, 0, identity, SP), 10 + 20 + 30 + 20 + 10 + 4 * SP)
  // The averaged answer, recorded because it is the one that was wrong once.
  eq('and not the first row multiplied out',
    RM.contentH(uniform(5, 30), 0, identity, SP), 5 * 30 + 4 * SP)
})

group('a cap weighs only the capped rows', () => {
  eq('capped to two', RM.contentH(uniform(5, 30), 2, identity, SP), 30 + 30 + SP)
  eq('capped to one', RM.contentH(uniform(5, 30), 1, identity, SP), 30)
  eq('capped past the end', RM.contentH(uniform(5, 30), 9, identity, SP), 5 * 30 + 4 * SP)
})

group('a caller that measures a constant row answers with it', () => {
  eq('uniform through a constant',
    RM.contentH(uniform(4, 0), 0, () => 40, SP), 4 * 40 + 3 * SP)
})

group('no rows is no height, never the space available', () => {
  eq('null', RM.contentH(null, 0, identity, SP), 0)
  eq('undefined', RM.contentH(undefined, 0, identity, SP), 0)
})

section('snappedH - the largest WHOLE prefix that fits')

group('a list that fits is its own height', () => {
  eq('three of 30 fit in 200',
    RM.snappedH(uniform(3, 30), 0, 200, 1000, identity, SP), 3 * 30 + 2 * SP)
})

group('a list that does not fit loses whole rows, never half of one', () => {
  // Five rows of 30 plus four gaps is 158. Their running bottoms are 30, 62,
  // 94, 126, 158, so in 100 the fourth row crosses and exactly three rows
  // answer. A clamp to the space would answer 100 and leave the fourth row
  // cut through the middle.
  eq('three of five fit in 100', RM.snappedH(uniform(5, 30), 0, 100, 1000, identity, SP), 94)
  eq('and that answer is below the space it was given',
    RM.snappedH(uniform(5, 30), 0, 100, 1000, identity, SP) < 100, true)
  // The boundary is exact: one pixel short of the third row's bottom still
  // admits only two rows.
  eq('at 93 it is still two rows', RM.snappedH(uniform(5, 30), 0, 93, 1000, identity, SP), 62)
  eq('at 94 the third row fits', RM.snappedH(uniform(5, 30), 0, 94, 1000, identity, SP), 94)
})

group('the answer is never mid-row', () => {
  // The property the whole module exists for, checked by exhausting every
  // size of space rather than by asserting a few convenient numbers: a
  // legal answer is some whole prefix's height, and nothing else.
  const legal = (got, rowCount, rowH) => {
    for (let n = 0; n <= rowCount; n++) {
      if (got === n * rowH + Math.max(0, n - 1) * SP) return true
    }
    return false
  }
  const ROWS = 6
  const ROW_H = 30
  let midRow = 0
  for (let avail = 0; avail <= 200; avail++) {
    const got = RM.snappedH(uniform(ROWS, ROW_H), 0, avail, 1000, identity, SP)
    // Past the point where the whole list fits, the ceiling takes over; a
    // ceiling-clamped answer is the caller's screen limit, not a mid-row cut.
    if (got > 6 * ROW_H + 5 * SP) continue
    if (!legal(got, ROWS, ROW_H)) midRow++
  }
  eq('over 201 sizes of space, no answer lands mid-row', midRow, 0)
})

group('a first row taller than the space is that row, clipped to the ceiling', () => {
  eq('one 200-tall row in 100', RM.snappedH([200], 0, 100, 1000, identity, SP), 200)
  eq('and the ceiling still bounds it', RM.snappedH([200], 0, 100, 150, identity, SP), 150)
  // Dropping the row instead would answer 0 for a list whose only row is
  // simply too tall, which reads as a collapsed card.
  eq('and it is never dropped to nothing',
    RM.snappedH([200], 0, 100, 1000, identity, SP) > 0, true)
})

group('the cap bounds what is offered', () => {
  eq('capped to two of five, space for all five',
    RM.snappedH(uniform(5, 30), 2, 200, 1000, identity, SP), 62)
})

group('no rows is no height', () => {
  eq('empty', RM.snappedH([], 0, 500, 1000, identity, SP), 0)
  eq('null', RM.snappedH(null, 0, 500, 1000, identity, SP), 0)
  // A clamp would hand a window-filling region to a list with nothing in it.
  eq('and never the space it was offered',
    RM.snappedH([], 0, 500, 1000, identity, SP) < 500, true)
})

group('a mixed row set drops the whole row that does not fit', () => {
  // 10 + 2 + 20 + 2 + 30 = 64 for the first three rows.
  eq('three of the mixed five fit in 64', RM.snappedH(mixed, 0, 64, 1000, identity, SP), 64)
  eq('all five fit in the full height', RM.snappedH(mixed, 0, 1000, 1000, identity, SP),
    10 + 20 + 30 + 20 + 10 + 4 * SP)
})

group('the gap is the caller\'s, not the library\'s', () => {
  eq('a zero gap packs the rows', RM.snappedH(uniform(3, 30), 0, 1000, 1000, identity, 0), 3 * 30)
  eq('and a wide gap is honoured', RM.snappedH(uniform(3, 30), 0, 1000, 1000, identity, 10), 3 * 30 + 2 * 10)
  eq('a zero gap still answers whole rows', RM.snappedH(uniform(5, 30), 0, 100, 1000, identity, 0), 3 * 30)
})

finish()

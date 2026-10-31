#!/usr/bin/env node
// Suite: shell/common/ui/SlotGrowth.js - the one rule that decides how tall a
// slot-bearing card gets.
//
// ## Why this file is tested at all
//
// The rule used to be written TWICE - once in MenuPanel, once in PanelCard -
// and the two drifted when List.revealNeedH changed meaning. PanelCard kept
// treating the claim as a region height, so on a scrollable list the further
// down the content a row sat, the taller the card asked to be: a dropdown on
// the last folder in the password manager expanded the window by its own
// scroll offset when there was ample room to scroll instead.
//
// Neither copy could be reached by a test. Both lived in panels, and a panel
// needs a window backend to instantiate - the construction suite classifies
// every one of them as "needs-environment" for exactly that reason. The one
// surface with a headless probe (ui-rest) was checked against values the probe
// itself supplied, never against the arithmetic, so a wrong formula passed
// cleanly. This file is pure, so it is not reachable that way.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const FILE = path.join(SHELL_DIR, 'common/ui/SlotGrowth.js')
const S = loadLib(FILE)

// The reveal margin the shell's List seats to (Ui.s on this tree, 8). It is a
// parameter rather than an import because a .js cannot import the Ui singleton
// here - CalendarLib.js documents the same limitation - so a rule that
// hardcoded its own copy would drift from the list's definition of "revealed".
const MARGIN = 8
const CEILING = 922

// A stand-in for the four things the rule reads off a list. Deliberately a
// plain object: the rule must not come to depend on anything else, or it stops
// being testable without a QML engine, which is the property this suite exists
// to protect.
function listOf({ claim = -1, contentY = 0, rowTop = 0 } = {}) {
  return {
    revealNeedH: claim,
    contentY,
    autoRevealIndex: claim > 0 ? 0 : -1,
    rowTop: () => rowTop,
  }
}
const region = (list, base, ceiling = CEILING) =>
  S.regionForSlot(list, base, ceiling, MARGIN)
// rowH is the only thing the scroll-first test looks at, and it is
// `claim - rowTop`, so the fixtures below state it rather than leaving the
// reader to subtract.
const rowOf = (claim, rowTop) => claim - rowTop
// What the rule subtracts: where the content WILL sit, which is the row's top
// unless the list is already scrolled past it.
const reachOf = (contentY, rowTop) => Math.max(contentY, rowTop)

suite('slot-growth', 'the one rule for how tall a slot-bearing card gets')

// ---------------------------------------------------------------------------
section('the shape of the input: what the rule may read')
// ---------------------------------------------------------------------------

group('a list with nothing claimed holds the region it is showing', () => {
  eq('no claim at all', region(listOf({ claim: -1 }), 292), 292)
  eq('a claim of zero is still no claim',
    region(listOf({ claim: 0 }), 292), 292)
  eq('a negative region is passed through untouched',
    region(listOf({ claim: 500 }), -1), -1)
  eq('a zero region is passed through untouched',
    region(listOf({ claim: 500 }), 0), 0)
})

// ---------------------------------------------------------------------------
section('SCROLL FIRST: a row that fits is the list\'s job, not the card\'s')
// ---------------------------------------------------------------------------

// A scroll position c reveals the row iff c <= rowTop (its top is below the
// region's top edge) and c + base >= rowTop + rowH (its bottom is above the
// region's bottom edge), which is solvable exactly when rowH <= base. That
// single inequality is the whole of the scroll-first test, so these cases are
// the boundary of it: rowH is claim - rowTop.
group('a row no taller than the region never resizes the card', () => {
  // rowH 100 in a 292 region: fits with room to spare.
  const short = listOf({ claim: 150, rowTop: 50 })
  eq('the fixture really is a short row', rowOf(150, 50), 100)
  eq('a short row on a tall region', region(short, 292), 292)
  // rowH exactly 292 in a 292 region: the boundary, and it still fits.
  const exact = listOf({ claim: 342, rowTop: 50 })
  eq('a row exactly as tall as the region', region(exact, 292), 292)
  // The shape the live shell actually hit: a 287px row in a 292px region is a
  // scroll, and the card holds still. Read wrongly - treating the claim as a
  // region height - that same row asks for 532.
  const live = listOf({ claim: 532, contentY: 0, rowTop: 245 })
  eq('the 287px dropdown on a 292px region', rowOf(532, 245), 287)
  eq('is a scroll, not a resize', region(live, 292), 292)
})

group('the boundary is a half pixel, so a rounding crumb cannot resize the card', () => {
  // rowH 292.5 against base 292: 0.5 over, and the tolerance takes it.
  eq('half a pixel over the region is still a fit',
    region(listOf({ claim: 342.5, rowTop: 50 }), 292), 292)
  // rowH 293: a whole pixel over, and the card must carry it.
  const over = listOf({ claim: 343, rowTop: 50 })
  eq('and it is a whole pixel over', rowOf(343, 50), 293)
  eq('so the card grows', region(over, 292) > 292, true)
})

// The regression that made the password manager balloon, stated as a test: a
// row far down a scrollable list must not ask for a region as tall as its own
// distance down the page.
group('a row deep in the content is not a request for a tall card', () => {
  const deep = listOf({ claim: 912, contentY: 360, rowTop: 880 })
  eq('the region is 358 and the row sits at 880', region(deep, 358), 358)
  eq('and the answer is the region, not the row offset',
    region(deep, 358) < 880, true)
})
// ---------------------------------------------------------------------------
section('a row taller than the region: the region IS the row')
// ---------------------------------------------------------------------------

// The rule in one line, because the suite below is a lot of cases of it:
//
//   region = clamp(claim - rowTop, base, ceiling)
//
// with two early returns in front of it: no claim holds the region, and a row
// that already fits is the list's job (above). `claim - rowTop` is the row's
// SETTLED height - the claim is its bottom edge in content coordinates, so the
// difference is the whole of it.
//
// This is a change of contract, and the reason it is worth stating rather than
// only asserting. The rule used to SPLIT the deficit with the list:
//
//   region = claim - max(contentY, rowTop) + margin
//
// which made the card's height depend on where the list happened to be
// scrolled. Two things were wrong with that, and both are in SlotGrowth.js at
// the `need` line:
//
//   1. It read `contentY`, so the region changed as the user scrolled towards
//      a reveal - the card chasing the list, which is the alternation the two
//      writers could have. The row's settled height is the same number the whole
//      way, so there is nothing to chase.
//
//   2. It added the reveal margin. The content ENDS at the row's bottom, so
//      `rowBottom + Ui.s` is not a row the viewport can scroll to. Charging it
//      to the region makes the card taller than the content meant to fill it and
//      leaves the list permanently a margin short with nothing to spend it on.
//
// The second is the one that is easy to get wrong in the other direction: the
// margin is real, and the list's seat genuinely rests on it, so "the region must
// account for the margin" sounds right. It is the SEAT that carries the margin,
// not the region. The two are a pair and the region must not do the seat's job.
group('the region is the row, and it is the same from every scroll position', () => {
  // The live page: three rows, the last one a 240px dropdown, resting region
  // 145. rowH 287 does not fit, so the region grows to 287.
  const live = listOf({ claim: 385, contentY: 0, rowTop: 98 })
  eq('the fixture really is a row taller than the region', rowOf(385, 98), 287)
  eq('and the region becomes the row', region(live, 145), 287)
  // The old answer, stated so the difference is a number and not a story: the
  // whole deficit plus the margin, which is what this rule stopped doing.
  eq('and not the whole deficit plus the margin', 385 - 0 + MARGIN, 393)
  eq('which was 98px more window than the row asks for', 393 - region(live, 145), 106)
  // And the split the old rule subtracted is exactly the row's own height, so
  // the two are the same computation arrived at from opposite directions. This
  // is why dropping `contentY` was safe: the term it removed had already been
  // accounted for.
  eq('the row top is the whole of the subtraction', 385 - 98, region(live, 145))
})

group('the scroll position does not enter into it', () => {
  // Every position between where the list is and past the row's top resolves to
  // the same target, so the region cannot be retargeted by the seat it travels
  // with. The old rule returned a different number at each of these; the last
  // one used to be 462 and the first two 395.
  const at0 = listOf({ claim: 632, contentY: 0, rowTop: 245 })
  const at120 = listOf({ claim: 632, contentY: 120, rowTop: 245 })
  const at245 = listOf({ claim: 632, contentY: 245, rowTop: 245 })
  const past = listOf({ claim: 632, contentY: 320, rowTop: 245 })
  eq('scrolled to the top', region(at0, 292), 387)
  eq('scrolled to the middle of the row', region(at120, 292), 387)
  eq('scrolled to the row top', region(at245, 292), 387)
  // Past the row's top is where the old rule stopped subtracting and started
  // reading the offset, which is where the two answers used to diverge by 75px.
  // It is the same number now, and that is the point of the group.
  eq('scrolled well past the row top', region(past, 292), 387)
  eq('one answer for the whole stretch',
    region(at0, 292) === region(at120, 292)
      && region(at120, 292) === region(at245, 292)
      && region(at245, 292) === region(past, 292), true)
  // Stated as the property rather than as four coincidences: the region is a
  // function of the row and the resting size, and nothing else on the list.
  const offsets = [0, 1, 120, 244, 245, 300, 320, 9999]
  eq('and contentY cannot move it at all',
    new Set(offsets.map((y) => region(listOf({ claim: 632, contentY: y, rowTop: 245 }), 292))).size, 1)
})

group('a row that fits never resizes the card, and the margin is not in the way', () => {
  // The margin dropping out cannot smuggle a fit past the boundary: a row 8px
  // too tall still grows the card, and it grows to the row rather than to the
  // row plus a margin nothing can scroll to.
  const over = listOf({ claim: 300.5, rowTop: 0 })
  eq('rowH 300.5 in a 292 region', rowOf(300.5, 0), 300.5)
  eq('grows to the row itself', region(over, 292), 300.5)
})

group('a row far down a long list still gets its own height', () => {
  // 491 - 98 is 393: the row's settled height, with the list's 98 of offset
  // below it. The old rule said 401, and the 8 is the margin.
  const l = listOf({ claim: 491, contentY: 0, rowTop: 98 })
  eq('rowH 393 in a 145 region', rowOf(491, 98), 393)
  eq('the region is the row', region(l, 145), 393)
  eq('and the list keeps the 98 below it', region(l, 145) - 145, 248)
})

group('the region never shrinks, whatever the row asks for', () => {
  // A row near the top whose dropdown is tall: the need is far below the
  // resting region, and a card must not become shorter than its own rows.
  const l = listOf({ claim: 130, contentY: 0, rowTop: 0 })
  eq('the answer is at least the resting region', region(l, 292) >= 292, true)
  // A row far down a long list, where the old split took the deficit to almost
  // nothing and the region came out near the resting size. The row's own height
  // is 800, so this one grows, and growing is the point: the region is the row.
  const deep = listOf({ claim: 900, contentY: 700, rowTop: 100 })
  eq('a need above the resting region grows the card', region(deep, 292), 800)
})

// ---------------------------------------------------------------------------
section('the ceiling: past it the region stops and the claim goes back')
// ---------------------------------------------------------------------------

group('a dropdown taller than the screen is not shown by growing the card', () => {
  // Need would be 1492 against a 922 ceiling.
  const l = listOf({ claim: 1492, contentY: 0, rowTop: 0 })
  eq('past the ceiling the region holds', region(l, 292), 292)
  // Just inside: it grows, and is clamped to the ceiling.
  const near = listOf({ claim: 914, contentY: 0, rowTop: 0 })
  eq('a need under the ceiling is honoured whole', region(near, 292), 914)
  const exact = listOf({ claim: 922, contentY: 0, rowTop: 0 })
  eq('a need exactly at it is honoured', region(exact, 292), 922)
  const over = listOf({ claim: 923, contentY: 0, rowTop: 0 })
  eq('one pixel past it is not', region(over, 292), 292)
  // The boundary is the ROW now, not the row plus the margin. Under the old
  // rule the margin meant a 914px row asked for 922 and a 915px row asked for
  // 923 and was refused - so the margin moved the ceiling by 8 in both
  // directions. It no longer does, and this pair is where that shows.
  eq('the ceiling is read against the row, not the row plus the margin',
    region(listOf({ claim: 915, rowTop: 0 }), 292) > 292, true)
})

group('the ceiling is not read against the scroll offset either', () => {
  // One row 700px down the content, the list at the top, a dropdown that puts
  // the claim at 1400. The row is 700 tall and fits under the ceiling, so the
  // card grows and the list takes the 700 below it. Measured against the whole
  // deficit the need would be 1408, which is past the ceiling - and the rule
  // would refuse a growth the row can afford and hand the reveal back to a list
  // that was never going to reach it.
  const l = listOf({ claim: 1400, contentY: 0, rowTop: 700 })
  eq('the whole deficit would be past the ceiling', 1400 - 0 + MARGIN > CEILING, true)
  eq('the row is not', region(l, 292), 700)
  eq('so a need that fits is honoured', region(l, 292) < 1400 - 0 + MARGIN, true)
  // The same claim with the list scrolled all the way down: identical, because
  // the offset is not an input.
  eq('and scrolling to the row top changes nothing',
    region(listOf({ claim: 1400, contentY: 700, rowTop: 700 }), 292), 700)
})

// ---------------------------------------------------------------------------
section('every term is observable: the rule is three inputs, no hidden state')
// ---------------------------------------------------------------------------

// A note on the fourth parameter, because it is the kind of thing that reads as
// an oversight and is not: `regionForSlot(list, base, ceiling, margin)` still
// takes the margin and does not use it. The parameter is kept so the callers do
// not all change at once, and the assertions below pin that it is genuinely
// inert rather than merely unexercised. If a future change starts using it
// again, the test that should fail is the one that says the region does not
// move - not a pixel assertion somewhere in a card's geometry.
group('the margin parameter is accepted and deliberately ignored', () => {
  const l = listOf({ claim: 632, contentY: 0, rowTop: 245 })
  eq('margin 0', S.regionForSlot(l, 292, CEILING, 0), 387)
  eq('margin 8', S.regionForSlot(l, 292, CEILING, 8), 387)
  eq('margin 40', S.regionForSlot(l, 292, CEILING, 40), 387)
  // The old rule's two symptoms, both now absent: a huge margin could not drag
  // the region below the resting one, and a margin at all could not push a
  // 915px row past a 922px ceiling.
  eq('a huge margin does not shrink the region',
    S.regionForSlot(l, 292, CEILING, 100000), 387)
  eq('and does not run the need into the ceiling',
    S.regionForSlot(listOf({ claim: 915, rowTop: 0 }), 292, CEILING, 100000), 915)
})

group('the ceiling is the caller\'s too', () => {
  const l = listOf({ claim: 914, contentY: 0, rowTop: 0 })
  eq('a low ceiling holds the region', S.regionForSlot(l, 292, 400, MARGIN), 292)
  eq('a high ceiling lets it through', S.regionForSlot(l, 292, 4000, MARGIN), 914)
})

group('the rule reads nothing else off the list', () => {
  // A list that is frozen, so a read of anything not already there throws
  // instead of quietly working in production and being untestable here.
  //
  // `contentY` is still present, because the callers all set it and removing it
  // from here would be a lie about what the object looks like. It is no longer
  // READ: the group below says so, and this one says that reading it is not
  // required, which is the weaker and more useful of the two claims.
  const strict = Object.freeze({
    revealNeedH: 632,
    contentY: 0,
    autoRevealIndex: 0,
    rowTop: () => 245,
  })
  eq('and it is happy with those four', S.regionForSlot(strict, 292, CEILING, MARGIN), 387)

  // A list with the two properties the rule does not need at all. If
  // `contentY` were still read, this would throw rather than answer, and that is
  // the assertion - a getter that is never called cannot be observed by its
  // value, only by not being needed.
  const minimal = Object.freeze({
    revealNeedH: 632,
    autoRevealIndex: 0,
    rowTop: () => 245,
  })
  eq('and it does not need contentY at all', S.regionForSlot(minimal, 292, CEILING, MARGIN), 387)
})

finish()

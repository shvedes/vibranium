#!/usr/bin/env node
// Suite: shell/features/apps/audioMixer/GraphModel.js - the graph canvas's
// view geometry.
//
// The pan clamp, the pointer-anchored zoom, the content bounds and the
// fit-the-whole-graph reset all lived in GraphTab.qml, a 2100-line QML
// surface that needs a live PipeWire graph to construct. They are pure
// arithmetic over a viewport, a world and a position map, so they moved into
// the graph library and are driven here directly.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, approx, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const GM = loadLib(path.join(SHELL_DIR, 'features/apps/audioMixer/GraphModel.js'))

suite('graph-model', 'GraphModel view geometry: clamp, zoom, bounds, fit')

section('clampPan - a corner of the world stays reachable')

group('a world larger than the viewport pans between its edges', () => {
  const p = GM.clampPan(100, 100, 500, 400, 1000, 800, 1, 10)
  eq('a position inside the bound is kept', p, { x: 100, y: 100 })
  const high = GM.clampPan(9999, 9999, 500, 400, 1000, 800, 1, 10)
  eq('the far x edge is the world less the viewport', high.x, 490)
  eq('the far y edge is the world less the viewport', high.y, 390)
})

group('a world smaller than the viewport stays where it is put', () => {
  eq('a small world keeps its pan', GM.clampPan(50, 50, 500, 400, 100, 80, 1, 10), { x: 50, y: 50 })
  eq('the origin is reachable', GM.clampPan(0, 0, 500, 400, 100, 80, 1, 10), { x: 0, y: 0 })
  eq('a negative pan is kept while the world still covers it', GM.clampPan(-50, -50, 500, 400, 1000, 800, 1, 10), { x: -50, y: -50 })
})

group('the margin is the reachable edge', () => {
  const p = GM.clampPan(-9999, -9999, 500, 400, 1000, 800, 1, 25)
  eq('the near edge keeps one margin of world visible', p.x, 25 - 1000)
  eq('and the other axis', p.y, 25 - 800)
})

group('zoom scales the world before the clamp', () => {
  const p = GM.clampPan(0, 0, 500, 400, 1000, 800, 0.5, 10)
  eq('a world that now fits is pinned at the origin', p, { x: 0, y: 0 })
  const high = GM.clampPan(9999, 9999, 500, 400, 1000, 800, 2, 10)
  eq('the far x edge is still the viewport bound', high.x, 490)
  eq('and the far y edge', high.y, 390)
})

section('zoomPan - the point under the pointer stays under it')

group('the unzoomed center is a fixed point at scale 1', () => {
  const z = GM.zoomPan(0, 0, 1, 0, 0.1, 0.2, 3, 100, 100)
  eq('no wheel means no change', z, { zoom: 1, panX: 0, panY: 0 })
})

group('zooming in moves the world out from under the pointer', () => {
  const z = GM.zoomPan(0, 0, 1, 1, Math.log(2), 0.5, 4, 100, 50)
  approx('the zoom doubles', z.zoom, 2, 1e-9)
  // at (100,50): pan' = at - (at - pan) * k = 100 - 100*2 = -100.
  approx('the anchor x follows', z.panX, -100, 1e-9)
  approx('the anchor y follows', z.panY, -50, 1e-9)
  // The world point under the pointer is unchanged: (at - pan) / zoom.
  approx('the point under the pointer is invariant',
    (100 - z.panX) / z.zoom, 100, 1e-9)
})

group('the two zoom bounds are honoured', () => {
  eq('above the maximum', GM.zoomPan(0, 0, 2, 100, 1, 0.5, 3, 0, 0).zoom, 3)
  eq('below the minimum', GM.zoomPan(0, 0, 1, -100, 1, 0.5, 4, 0, 0).zoom, 0.5)
  eq('a clamp to the current scale is a no-op',
    GM.zoomPan(7, 8, 3, 1, 1, 0.5, 3, 0, 0), { zoom: 3, panX: 7, panY: 8 })
})

section('contentBox - the cards own extent')

group('the box is the union of every placed card', () => {
  const box = GM.contentBox({ a: { x: 10, y: 20 }, b: { x: 200, y: 50 } }, 100, 40)
  eq('the origin is the top-left card', { x: box.x, y: box.y }, { x: 10, y: 20 })
  eq('the width spans to the far card edge', box.w, 290)
  eq('the height spans to the tallest bottom', box.h, 70)
})

group('an empty or absent position map has no box', () => {
  eq('no cards', GM.contentBox({}, 100, 40), null)
  eq('a null position', GM.contentBox({ a: null }, 100, 40), null)
  eq('a nullish map', GM.contentBox(null, 100, 40), null)
})

section('fitView - the whole graph, never magnified')

group('a graph larger than the viewport is scaled down around its centre', () => {
  const fit = GM.fitView({ x: 0, y: 0, w: 1000, h: 500 }, 500, 400, 0, 0.2, 4)
  approx('half scale fits the width', fit.zoom, 0.5, 1e-9)
  approx('and is centred horizontally', fit.panX, 0, 1e-9)
  approx('and vertically', fit.panY, (400 - 500 * 0.5) / 2, 1e-9)
})

group('a graph smaller than the viewport is centred at 1:1', () => {
  const fit = GM.fitView({ x: 10, y: 20, w: 100, h: 80 }, 500, 400, 0, 0.2, 4)
  eq('never magnified', fit.zoom, 1)
  eq('centred x', fit.panX, (500 - 100) / 2 - 10)
  eq('centred y', fit.panY, (400 - 80) / 2 - 20)
})

group('the fit is bounded by the zoom limits', () => {
  eq('a tiny graph is not zoomed out below the minimum',
    GM.fitView({ x: 0, y: 0, w: 100000, h: 100000 }, 500, 400, 0, 0.5, 4).zoom, 0.5)
  eq('the 1:1 ceiling always applies, even with a higher maximum',
    GM.fitView({ x: 0, y: 0, w: 1, h: 1 }, 500, 400, 0, 0.2, 4).zoom, 1)
})

group('an empty graph resets to the identity view', () => {
  eq('a null box', GM.fitView(null, 500, 400, 10, 0.2, 4), { zoom: 1, panX: 0, panY: 0 })
  eq('an undefined box', GM.fitView(undefined, 500, 400, 10, 0.2, 4), { zoom: 1, panX: 0, panY: 0 })
})

group('the padding is part of the fitted extent', () => {
  const withPad = GM.fitView({ x: 0, y: 0, w: 400, h: 400 }, 500, 500, 50, 0.1, 4)
  const without = GM.fitView({ x: 0, y: 0, w: 400, h: 400 }, 500, 500, 0, 0.1, 4)
  eq('padding only ever shrinks the fit', withPad.zoom <= without.zoom, true)
})

section('handleYs / markY / lineOnMark - the port fan and its lines')

group('the fan is centred on the card and shrinks with the count', () => {
  eq('no ports, no marks', GM.handleYs(0, 104, 44, 22), [])
  eq('one port lands on the middle', GM.handleYs(1, 104, 44, 22), [52])
  eq('two ports are one gap either side', GM.handleYs(2, 104, 44, 22), [41, 63])
  const four = GM.handleYs(4, 104, 44, 22)
  approx('the band stays centred', (four[0] + four[3]) / 2, 52)
  approx('the gap caps at gapMax', four[1] - four[0], 11)
  const dense = GM.handleYs(44, 104, 44, 22)
  approx('a dense fan steps by span over count', dense[1] - dense[0], 1)
  eq('and stays inside the band', dense[43] - dense[0] < 44, true)
})

group('markY spreads the lines back across the marks', () => {
  eq('an edge with no mark answers the card middle', GM.markY([], 0, 3, 104), 52)
  eq('the slot owns its mark while marks last', GM.markY([10, 20, 30], 1, 3, 104), 20)
  eq('past the last mark the lines share it', GM.markY([10, 20], 5, 6, 104), 20)
  eq('a negative slot', GM.markY([10, 20], -1, 2, 104), 52)
  eq('no lines', GM.markY([10, 20], 0, 0, 104), 52)
  eq('a non-array mark list', GM.markY(null, 0, 1, 104), 52)
})

group('lineOnMark is exact identity', () => {
  eq('a line exactly on the mark', GM.lineOnMark([{ y: 10 }, { y: 20 }], 20), true)
  eq('a mark nothing is on', GM.lineOnMark([{ y: 10 }], 10.0001), false)
  eq('no lines', GM.lineOnMark([], 10), false)
  eq('a null line is skipped', GM.lineOnMark([null, { y: 10 }], 10), true)
  eq('a non-array list', GM.lineOnMark(null, 10), false)
})

section('pairPossible - the pairing rule as a predicate')

group('it agrees with pairPorts on every shape of the rule', () => {
  const cases = [
    [['node:output_FL'], ['node:playback_FL']],
    [['node:output_FL'], ['node:playback_FR']],
    [['node:output_FL', 'node:output_FR'], ['node:playback_FR', 'node:playback_FL']],
    [['node:output_FL'], ['node:playback_FL', 'node:playback_FR']],
    [['node:Port-0'], ['node:Port-0']],
    [['node:Port-0'], ['node:playback_FL']],
    [['node:output_FROB'], ['node:playback_FL']],
    [['node:playback_FL'], ['node:output_FL']],
    [[], ['node:playback_FL']],
    [['node:output_FL'], []]
  ]
  for (const [outs, ins] of cases) {
    eq('a pair exists exactly when pairPorts builds one: '
      + outs.join(',') + ' / ' + ins.join(','),
      GM.pairPossible(outs, ins), GM.pairPorts(outs, ins).pairs.length > 0)
  }
})

group('it refuses what cannot be paired', () => {
  eq('absent lists', GM.pairPossible(null, null), false)
  eq('undefined lists', GM.pairPossible(undefined, undefined), false)
  eq('only outputs', GM.pairPossible(['node:output_FL'], []), false)
  eq('two unnumbered ports on each side are not a channel match',
    GM.pairPossible(['node:Port-0', 'node:Port-1'], ['node:Port-0', 'node:Port-1']), false)
  eq('a suffix on one side alone is not a match',
    GM.pairPossible(['node:output_FL'], ['node:Port-0']), false)
})

group('it accepts the mono single-port case and the shared channel case', () => {
  eq('one unnamed port either side', GM.pairPossible(['node:Port-0'], ['node:Port-0']), true)
  eq('a shared channel suffix', GM.pairPossible(['node:output_FL'], ['node:playback_FL']), true)
  eq('one matching channel among several',
    GM.pairPossible(['node:output_FL'], ['node:playback_FR', 'node:playback_FL']), true)
})

finish()

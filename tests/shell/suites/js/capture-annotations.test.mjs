#!/usr/bin/env node
// Suite: the capture geometry and the annotation math.
//
// Three pure libraries, one theme: every coordinate that reaches the frame
// pixels is derived rather than stored, so the interesting behaviour is not
// the happy path but the degenerate one. A drag that collapses to zero, a
// selection that starts off-screen, a DPR ratio the compositor has not
// reported yet, a font size a stroke claims is negative. Each library states
// its own contract in its header, and several of those contracts are
// deliberately surprising - a name-only screen key, an outline-only ellipse
// hit test, a grid anchored to the view rather than to the rect - so the
// surprising parts are pinned here with the reason they exist.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, deepEqual, show, finish,
} from '../../lib/assert.mjs'

// Resolved from this file's location rather than from SHELL_DIR in
// assert.mjs: that export walks one level too far up and lands outside the
// repo, so it does not name the shell tree.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const RM = loadLib(path.join(SHELL, 'common/capture/RectMath.js'))
const SL = loadLib(path.join(SHELL, 'common/capture/ShotLib.js'))
const AT = loadLib(path.join(SHELL, 'features/annotations/AnnotationTools.js'))

suite('capture + annotations', 'RectMath, ShotLib, AnnotationTools')

// ---------------------------------------------------------------------------
section('RectMath.finite / zeroRect - the two primitives everything guards on')

group('finite accepts a real number and nothing else', () => {
  // The guard is `typeof value === "number" && Number.isFinite(value)`, so a
  // numeric string is NOT a coordinate. The clamps built on it fold such a
  // field to 0 rather than coercing it, which is the opposite of scaleRect
  // further down and is the reason the two disagree. The two clamps that
  // reach Math.min/Math.max directly (clampRectInBox) do coerce, which is
  // pinned where they are tested.
  eq('an integer', RM.finite(1), true)
  eq('zero', RM.finite(0), true)
  eq('a negative number', RM.finite(-1), true)
  eq('a float', RM.finite(1.5), true)
  eq('NaN', RM.finite(NaN), false)
  eq('Infinity', RM.finite(Infinity), false)
  eq('-Infinity', RM.finite(-Infinity), false)
  eq('a numeric string', RM.finite('1'), false)
  eq('an empty string', RM.finite(''), false)
  eq('null', RM.finite(null), false)
  eq('undefined', RM.finite(undefined), false)
  eq('a boolean', RM.finite(true), false)
  eq('a boxed Number', RM.finite(new Number(1)), false)
  eq('a BigInt', RM.finite(1n), false)
  noThrow('no input shape throws', () => RM.finite(Symbol.iterator))
})

group('zeroRect is the canonical degenerate rect, freshly allocated', () => {
  eq('shape', RM.zeroRect(), { x: 0, y: 0, w: 0, h: 0 })
  // A fresh object per call matters: the degenerate rect is handed straight
  // back to a caller that stores it, so two results must never alias.
  const held = RM.zeroRect()
  held.x = 99
  eq('a fresh object each call', RM.zeroRect().x, 0)
  is('the key order is stable for diffing', Object.keys(RM.zeroRect()),
    (v) => v.join(',') === 'x,y,w,h', 'x,y,w,h')
})

// ---------------------------------------------------------------------------
section('RectMath.normRect - corner pair to non-negative rect')

group('orders the corners so a drag in any direction yields the same rect', () => {
  eq('down-right', RM.normRect(10, 20, 30, 50), { x: 10, y: 20, w: 20, h: 30 })
  eq('up-left', RM.normRect(30, 50, 10, 20), { x: 10, y: 20, w: 20, h: 30 })
  eq('down-left', RM.normRect(30, 20, 10, 50), { x: 10, y: 20, w: 20, h: 30 })
  eq('up-right', RM.normRect(10, 50, 30, 20), { x: 10, y: 20, w: 20, h: 30 })
  eq('x descending only', RM.normRect(10, 0, 0, 5), { x: 0, y: 0, w: 10, h: 5 })
  eq('y descending only', RM.normRect(0, 5, 5, 0), { x: 0, y: 0, w: 5, h: 5 })
})

group('a zero-length drag is a zero-size rect, not a missing one', () => {
  eq('same point', RM.normRect(5, 5, 5, 5), { x: 5, y: 5, w: 0, h: 0 })
  eq('w and h are never negative', RM.normRect(0, 0, 0, 0), { x: 0, y: 0, w: 0, h: 0 })
  // Negative coordinates are ordinary document pixels: a pan can put the
  // origin above and to the left of the view.
  eq('negative corners', RM.normRect(-10, -20, -5, -10), { x: -10, y: -20, w: 5, h: 10 })
  eq('straddling the origin', RM.normRect(-5, -5, 5, 5), { x: -5, y: -5, w: 10, h: 10 })
})

group('any non-finite corner collapses the whole rect to the origin', () => {
  eq('NaN x1', RM.normRect(NaN, 0, 10, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('NaN y1', RM.normRect(0, NaN, 10, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('NaN x2', RM.normRect(0, 0, NaN, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('NaN y2', RM.normRect(0, 0, 10, NaN), { x: 0, y: 0, w: 0, h: 0 })
  eq('Infinity', RM.normRect(Infinity, 0, 10, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('-Infinity', RM.normRect(0, 0, -Infinity, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('undefined', RM.normRect(undefined, 0, 10, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('null', RM.normRect(null, 0, 10, 10), { x: 0, y: 0, w: 0, h: 0 })
  // A numeric string fails the finite guard, so a text field that hands a
  // string to a drag collapses to the origin rather than to a parse.
  eq('a numeric string corner', RM.normRect('10', 0, 30, 10), { x: 0, y: 0, w: 0, h: 0 })
  eq('no arguments at all', RM.normRect(), { x: 0, y: 0, w: 0, h: 0 })
  noThrow('all four nullish', () => RM.normRect(null, null, null, null))
  noThrow('a Symbol corner', () => RM.normRect(Symbol(), 0, 1, 1))
})

// ---------------------------------------------------------------------------
section('RectMath.clampRect - intersect a selection with the frame')

group('a rect inside the frame is returned unchanged', () => {
  eq('origin corner', RM.clampRect({ x: 0, y: 0, w: 10, h: 10 }, 100, 100), { x: 0, y: 0, w: 10, h: 10 })
  eq('interior', RM.clampRect({ x: 10, y: 20, w: 30, h: 40 }, 100, 100), { x: 10, y: 20, w: 30, h: 40 })
  eq('touching the right edge exactly', RM.clampRect({ x: 90, y: 0, w: 10, h: 10 }, 100, 100), { x: 90, y: 0, w: 10, h: 10 })
  eq('touching the bottom edge exactly', RM.clampRect({ x: 0, y: 90, w: 10, h: 10 }, 100, 100), { x: 0, y: 90, w: 10, h: 10 })
  eq('exactly the frame', RM.clampRect({ x: 0, y: 0, w: 100, h: 100 }, 100, 100), { x: 0, y: 0, w: 100, h: 100 })
})

group('a rect that overhangs is trimmed on the overflowing side only', () => {
  eq('overhang right', RM.clampRect({ x: 80, y: 0, w: 40, h: 10 }, 100, 100), { x: 80, y: 0, w: 20, h: 10 })
  eq('overhang bottom', RM.clampRect({ x: 0, y: 80, w: 10, h: 40 }, 100, 100), { x: 0, y: 80, w: 10, h: 20 })
  eq('overhang on both axes', RM.clampRect({ x: 80, y: 70, w: 40, h: 40 }, 100, 100), { x: 80, y: 70, w: 20, h: 30 })
  // A selection dragged off the top-left keeps the size it had on the far
  // side: the right/bottom edge is what gets clamped, never the extent.
  eq('origin overhang keeps the far edge', RM.clampRect({ x: -20, y: -5, w: 30, h: 20 }, 100, 100), { x: 0, y: 0, w: 10, h: 15 })
  eq('wholly past the far edge becomes the last pixel', RM.clampRect({ x: 200, y: 200, w: 10, h: 10 }, 100, 100), { x: 99, y: 99, w: 1, h: 1 })
  eq('wholly before the origin becomes the first pixel', RM.clampRect({ x: -500, y: -500, w: 10, h: 10 }, 100, 100), { x: 0, y: 0, w: 1, h: 1 })
  eq('straddling the whole frame', RM.clampRect({ x: -20, y: -20, w: 200, h: 200 }, 100, 100), { x: 0, y: 0, w: 100, h: 100 })
})

group('w/h floor at 1, which is what stops a negative size downstream', () => {
  eq('zero size inside the frame', RM.clampRect({ x: 10, y: 10, w: 0, h: 0 }, 100, 100), { x: 10, y: 10, w: 1, h: 1 })
  eq('zero size at the origin', RM.clampRect({ x: 0, y: 0, w: 0, h: 0 }, 100, 100), { x: 0, y: 0, w: 1, h: 1 })
  // A negative extent is a caller bug, but it must not produce w < 0, which
  // drawImage would reject as an index-size error rather than draw.
  eq('negative extent', RM.clampRect({ x: 10, y: 10, w: -5, h: -5 }, 100, 100), { x: 10, y: 10, w: 1, h: 1 })
  eq('negative width only', RM.clampRect({ x: 10, y: 10, w: -5, h: 20 }, 100, 100), { x: 10, y: 10, w: 1, h: 20 })
  eq('a 1x1 frame', RM.clampRect({ x: 5, y: 5, w: 10, h: 10 }, 1, 1), { x: 0, y: 0, w: 1, h: 1 })
  eq('a frame that rounds down to 0', RM.clampRect({ x: 0, y: 0, w: 5, h: 5 }, 0.4, 0.4), { x: 0, y: 0, w: 1, h: 1 })
  eq('a negative frame', RM.clampRect({ x: 0, y: 0, w: 5, h: 5 }, -3, -3), { x: 0, y: 0, w: 1, h: 1 })
  eq('a zero frame', RM.clampRect({ x: 0, y: 0, w: 5, h: 5 }, 0, 0), { x: 0, y: 0, w: 1, h: 1 })
})

group('every field is rounded, which is the documented fix for the canvas', () => {
  // The header's reason for rounding x/y as well as w/h: x arrives scaled
  // by a DPR ratio, and a fractional x with a rounded extent can push x+w
  // one pixel past the frame edge, which drawImage rejects.
  eq('fractional x rounds up', RM.clampRect({ x: 10.6, y: 10.4, w: 10.5, h: 10.5 }, 100, 100), { x: 11, y: 10, w: 10, h: 11 })
  eq('fractional frame rounds too', RM.clampRect({ x: 1.4, y: 1.6, w: 3.3, h: 3.3 }, 100.4, 100.6), { x: 1, y: 2, w: 4, h: 3 })
  is('all four fields are integers', Object.values(RM.clampRect({ x: 0.4, y: 0.6, w: 99.5, h: 99.5 }, 100, 100)),
    (v) => v.every(Number.isInteger), 'every field an integer')
  // The rescue branch: rounding x up to the frame width with a 1px extent
  // would leave x + w > frameW, so the rect is pulled back to the last pixel.
  eq('rounding past the edge is rescued', RM.clampRect({ x: 99.7, y: 0, w: 0.2, h: 5 }, 100, 100), { x: 99, y: 0, w: 1, h: 5 })
  eq('the rescue is symmetric on y', RM.clampRect({ x: 0, y: 99.7, w: 5, h: 0.2 }, 100, 100), { x: 0, y: 99, w: 5, h: 1 })
  eq('a rect starting exactly at the frame edge', RM.clampRect({ x: 100, y: 0, w: 5, h: 5 }, 100, 100), { x: 99, y: 0, w: 1, h: 5 })
  eq('rounding x up eats the extent', RM.clampRect({ x: 0.6, y: 0, w: 99.9, h: 5 }, 100, 100), { x: 1, y: 0, w: 99, h: 5 })
  eq('rounding x down keeps it', RM.clampRect({ x: 0.4, y: 0, w: 99.9, h: 5 }, 100, 100), { x: 0, y: 0, w: 100, h: 5 })
})

group('a missing or non-finite field reads as 0 rather than NaN', () => {
  eq('null rect', RM.clampRect(null, 100, 100), { x: 0, y: 0, w: 1, h: 1 })
  eq('undefined rect', RM.clampRect(undefined, 100, 100), { x: 0, y: 0, w: 1, h: 1 })
  eq('a number is not a rect', RM.clampRect(0, 100, 100), { x: 0, y: 0, w: 1, h: 1 })
  eq('a partial rect', RM.clampRect({ x: 5 }, 100, 100), { x: 5, y: 0, w: 1, h: 1 })
  eq('NaN x', RM.clampRect({ x: NaN, y: 5, w: 10, h: 10 }, 100, 100), { x: 0, y: 5, w: 10, h: 10 })
  eq('NaN w', RM.clampRect({ x: 5, y: 5, w: NaN, h: 10 }, 100, 100), { x: 5, y: 5, w: 1, h: 10 })
  eq('Infinity x folds to 0', RM.clampRect({ x: Infinity, y: 5, w: 10, h: 10 }, 100, 100), { x: 0, y: 5, w: 10, h: 10 })
  eq('-Infinity x folds to 0', RM.clampRect({ x: -Infinity, y: 5, w: 10, h: 10 }, 100, 100), { x: 0, y: 5, w: 10, h: 10 })
  // An Infinity extent would make x + w non-finite; the raw right edge then
  // falls back to x itself, so the rect is one pixel wide rather than NaN.
  eq('Infinity w does not poison the extent', RM.clampRect({ x: 5, y: 5, w: Infinity, h: 10 }, 100, 100), { x: 5, y: 5, w: 1, h: 10 })
  eq('Infinity h does not poison the extent', RM.clampRect({ x: 5, y: 5, w: 10, h: Infinity }, 100, 100), { x: 5, y: 5, w: 10, h: 1 })
  eq('a numeric string field is not a coordinate', RM.clampRect({ x: '10', y: 0, w: '5', h: 5 }, 100, 100), { x: 0, y: 0, w: 1, h: 5 })
  eq('a non-finite frame', RM.clampRect({ x: 0, y: 0, w: 5, h: 5 }, NaN, NaN), { x: 0, y: 0, w: 1, h: 1 })
  eq('an omitted frame', RM.clampRect({ x: 0, y: 0, w: 5, h: 5 }), { x: 0, y: 0, w: 1, h: 1 })
})

group('the result always fits the frame, whatever it was handed', () => {
  const cases = [
    [{ x: 0, y: 0, w: 10, h: 10 }, 100, 50],
    [{ x: 95, y: 45, w: 50, h: 50 }, 100, 50],
    [{ x: -30, y: -30, w: 60, h: 60 }, 100, 50],
    [{ x: 0.5, y: 0.5, w: 99.9, h: 49.9 }, 100, 50],
    [{ x: 100, y: 50, w: 10, h: 10 }, 100, 50],
    [{ x: 1e6, y: 1e6, w: 1, h: 1 }, 100, 50],
  ]
  for (const [r, fw, fh] of cases) {
    const c = RM.clampRect(r, fw, fh)
    is(`x+w <= ${fw} and y+h <= ${fh} for ${show(r)}`,
      c, (v) => v.x >= 0 && v.y >= 0 && v.w >= 1 && v.h >= 1 && v.x + v.w <= fw && v.y + v.h <= fh,
      'inside the frame with w,h >= 1')
  }
  eq('the result key set is exactly x,y,w,h', Object.keys(RM.clampRect({ x: 1, y: 1, w: 1, h: 1 }, 10, 10)), ['x', 'y', 'w', 'h'])
  // A Quickshell rect is a live object with getters, so a plain field read
  // is the whole contract; a getter that yields a number is clamped like a
  // plain number.
  const live = { get x() { return 5 }, get y() { return 5 }, get width() { return 5 }, get height() { return 5 } }
  eq('a getter-backed rect reads the w,h fields', RM.clampRect(live, 10, 10), { x: 5, y: 5, w: 1, h: 1 })
  throws('a getter that throws propagates - it is the caller error it looks like', () => {
    const bad = { get x() { throw new Error('boom') } }
    return RM.clampRect(bad, 10, 10)
  }, /boom/)
})

// ---------------------------------------------------------------------------
section('RectMath.scaleRect - the one unguarded scale in the file')

group('multiplies every field, coercion included', () => {
  // The header is explicit: the factor is not validated and the fields are
  // not guarded, because a field that is a numeric string has to keep
  // scaling the way "40" * 1.25 does. This is the deliberate opposite of
  // clampRect, which folds a string field to 0.
  eq('a plain scale', RM.scaleRect({ x: 1, y: 2, w: 3, h: 4 }, 1.25), { x: 1.25, y: 2.5, w: 3.75, h: 5 })
  eq('a numeric string field coerces', RM.scaleRect({ x: '40', y: 0, w: '10', h: 0 }, 1.5), { x: 60, y: 0, w: 15, h: 0 })
  eq('a factor of 0 zeroes it', RM.scaleRect({ x: 1, y: 2, w: 3, h: 4 }, 0), { x: 0, y: 0, w: 0, h: 0 })
  eq('a negative factor flips the sign', RM.scaleRect({ x: 1, y: 2, w: 3, h: 4 }, -1.5), { x: -1.5, y: -3, w: -4.5, h: -6 })
  eq('a negative rect stays negative', RM.scaleRect({ x: -10, y: -10, w: 20, h: 20 }, 2), { x: -20, y: -20, w: 40, h: 40 })
  approx('a fractional factor is not rounded', RM.scaleRect({ x: 0, y: 0, w: 10, h: 10 }, 1.25).w, 12.5, 1e-12)
})

group('an unusable factor produces NaN rather than a guard', () => {
  is('NaN factor', RM.scaleRect({ x: 1, y: 1, w: 1, h: 1 }, NaN), (v) => Object.values(v).every(Number.isNaN), 'all fields NaN')
  is('Infinity factor', RM.scaleRect({ x: 1, y: 1, w: 1, h: 1 }, Infinity), (v) => v.x === Infinity, 'x is Infinity')
  is('a string factor that is not a number', RM.scaleRect({ x: 1, y: 1, w: 1, h: 1 }, 'wide'), (v) => Number.isNaN(v.x), 'x is NaN')
  is('an undefined factor', RM.scaleRect({ x: 1, y: 1, w: 1, h: 1 }), (v) => Number.isNaN(v.x), 'x is NaN')
  // Documented: "A null rect throws here as the inline expression did; both
  // callers guard it." The throw is the contract, not an accident.
  throws('a null rect throws', () => RM.scaleRect(null, 2), /reading 'x'/)
  throws('an undefined rect throws', () => RM.scaleRect(undefined, 2))
  eq('a rect of all zeroes survives a NaN factor as NaN, not a throw',
    RM.scaleRect({ x: 0, y: 0, w: 0, h: 0 }, NaN), { x: NaN, y: NaN, w: NaN, h: NaN })
})

// ---------------------------------------------------------------------------
section('RectMath.clampPoint - into a box, with no finite guard on purpose')

group('clamps to the box on both axes', () => {
  eq('inside', RM.clampPoint({ x: 5, y: 5 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 5, y: 5 })
  eq('past the far corner', RM.clampPoint({ x: 50, y: 50 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 10, y: 10 })
  eq('before the origin', RM.clampPoint({ x: -5, y: -5 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 0, y: 0 })
  eq('exactly the far corner is not clamped', RM.clampPoint({ x: 10, y: 10 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 10, y: 10 })
  eq('exactly the origin is not clamped', RM.clampPoint({ x: 0, y: 0 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 0, y: 0 })
  // A box whose origin is negative (a panned view) clamps into that box, so
  // the result is negative too.
  eq('a negative-origin box', RM.clampPoint({ x: 0, y: 0 }, { x: -10, y: -10, w: 5, h: 5 }), { x: -5, y: -5 })
  eq('a negative-origin box, far corner', RM.clampPoint({ x: 99, y: 99 }, { x: -10, y: -10, w: 5, h: 5 }), { x: -5, y: -5 })
  eq('a zero-size box', RM.clampPoint({ x: 5, y: 5 }, { x: 0, y: 0, w: 0, h: 0 }), { x: 0, y: 0 })
  // A negative-size box has its far edge *before* its origin, so the clamp
  // collapses to the origin rather than reaching past it.
  eq('a negative-size box collapses to its origin', RM.clampPoint({ x: 5, y: 5 }, { x: 0, y: 0, w: -10, h: -10 }), { x: 0, y: 0 })
  eq('and so does a point before it', RM.clampPoint({ x: -5, y: -5 }, { x: 0, y: 0, w: -10, h: -10 }), { x: 0, y: 0 })
  eq('string fields coerce here', RM.clampPoint({ x: 5, y: 5 }, { x: '0', y: '0', w: '10', h: '10' }), { x: 5, y: 5 })
})

group('a NaN coordinate propagates so the caller can see the mapping broke', () => {
  // Documented: "No finite guard on purpose ... substituting 0 for a NaN
  // would silently place a point at the frame origin instead of letting the
  // caller see that the mapping broke."
  is('NaN x', RM.clampPoint({ x: NaN, y: 1 }, { x: 0, y: 0, w: 10, h: 10 }),
    (v) => Number.isNaN(v.x) && v.y === 1, 'x is NaN, y still clamped')
  is('NaN y', RM.clampPoint({ x: 1, y: NaN }, { x: 0, y: 0, w: 10, h: 10 }),
    (v) => Number.isNaN(v.y) && v.x === 1, 'y is NaN, x still clamped')
  is('a NaN box origin', RM.clampPoint({ x: 1, y: 1 }, { x: NaN, y: 0, w: 10, h: 10 }),
    (v) => Number.isNaN(v.x), 'x is NaN')
  is('Infinity x clamps to the far edge', RM.clampPoint({ x: Infinity, y: 1 }, { x: 0, y: 0, w: 10, h: 10 }),
    (v) => v.x === 10, 'x is 10')
  is('-Infinity x clamps to the origin', RM.clampPoint({ x: -Infinity, y: 1 }, { x: 0, y: 0, w: 10, h: 10 }),
    (v) => v.x === 0, 'x is 0')
  throws('a null point throws', () => RM.clampPoint(null, { x: 0, y: 0, w: 1, h: 1 }), /reading 'x'/)
  eq('the return shape is x,y only', Object.keys(RM.clampPoint({ x: 1, y: 1 }, { x: 0, y: 0, w: 1, h: 1 })), ['x', 'y'])
})

// ---------------------------------------------------------------------------
section('RectMath.clampRectInBox - a whole rect kept inside a box')

group('the placement order is what keeps an oversized rect inside', () => {
  // Documented: "x is placed against the old w, then w against the new x,
  // so a rect wider than the box still ends up inside it."
  eq('fits', RM.clampRectInBox({ x: 0, y: 0, w: 10, h: 10 }, 100, 100), { x: 0, y: 0, w: 10, h: 10 })
  eq('interior', RM.clampRectInBox({ x: 40, y: 40, w: 10, h: 10 }, 100, 100), { x: 40, y: 40, w: 10, h: 10 })
  eq('pushed off the far edge', RM.clampRectInBox({ x: 95, y: 95, w: 10, h: 10 }, 100, 100), { x: 90, y: 90, w: 10, h: 10 })
  eq('pushed off the origin', RM.clampRectInBox({ x: -20, y: -20, w: 10, h: 10 }, 100, 100), { x: 0, y: 0, w: 10, h: 10 })
  eq('wider than the box', RM.clampRectInBox({ x: 0, y: 0, w: 200, h: 10 }, 100, 100), { x: 0, y: 0, w: 100, h: 10 })
  eq('taller than the box', RM.clampRectInBox({ x: 0, y: 0, w: 10, h: 200 }, 100, 100), { x: 0, y: 0, w: 10, h: 100 })
  eq('both axes oversized', RM.clampRectInBox({ x: 50, y: 50, w: 200, h: 200 }, 100, 100), { x: 0, y: 0, w: 100, h: 100 })
  eq('exactly the box', RM.clampRectInBox({ x: 0, y: 0, w: 100, h: 100 }, 100, 100), { x: 0, y: 0, w: 100, h: 100 })
  eq('origin exactly on the far edge', RM.clampRectInBox({ x: 100, y: 0, w: 10, h: 10 }, 100, 100), { x: 90, y: 0, w: 10, h: 10 })
})

group('a zero-size box admits nothing but never goes negative', () => {
  eq('zero box', RM.clampRectInBox({ x: 5, y: 5, w: 10, h: 10 }, 0, 0), { x: 0, y: 0, w: 0, h: 0 })
  eq('negative box', RM.clampRectInBox({ x: 5, y: 5, w: 10, h: 10 }, -10, -10), { x: 0, y: 0, w: 0, h: 0 })
  eq('a zero-size rect keeps its position', RM.clampRectInBox({ x: 5, y: 5, w: 0, h: 0 }, 100, 100), { x: 5, y: 5, w: 0, h: 0 })
  eq('a zero-size rect is pushed off the edge', RM.clampRectInBox({ x: 100, y: 100, w: 0, h: 0 }, 100, 100), { x: 100, y: 100, w: 0, h: 0 })
  eq('a negative-size rect is floored at 0', RM.clampRectInBox({ x: 10, y: 10, w: -5, h: -5 }, 100, 100), { x: 10, y: 10, w: 0, h: 0 })
})

group('no finite guard here, so strings coerce and NaN spreads', () => {
  // The counterpart to clampRect: this clamp reaches Math.min/Math.max
  // directly, so a numeric string field coerces the way it always has and a
  // non-finite field is not repaired.
  eq('a numeric string field coerces', RM.clampRectInBox({ x: '5', y: 0, w: '10', h: 10 }, 100, 100), { x: 5, y: 0, w: 10, h: 10 })
  eq('a numeric string box coerces', RM.clampRectInBox({ x: 5, y: 5, w: 10, h: 10 }, '100', '100'), { x: 5, y: 5, w: 10, h: 10 })
  is('NaN fields spread to every output field',
    RM.clampRectInBox({ x: NaN, y: NaN, w: NaN, h: NaN }, 100, 100),
    (v) => Object.values(v).every(Number.isNaN), 'all fields NaN')
  eq('a fractional box is used as-is', RM.clampRectInBox({ x: 10.5, y: 10.5, w: 1, h: 1 }, 10.5, 10.5), { x: 9.5, y: 9.5, w: 1, h: 1 })
  eq('the return shape is x,y,w,h', Object.keys(RM.clampRectInBox({ x: 0, y: 0, w: 1, h: 1 }, 2, 2)), ['x', 'y', 'w', 'h'])
  for (const [r, bw, bh] of [
    [{ x: 0, y: 0, w: 10, h: 10 }, 100, 100],
    [{ x: 95, y: 95, w: 10, h: 10 }, 100, 100],
    [{ x: 0, y: 0, w: 200, h: 200 }, 100, 100],
    [{ x: -5, y: -5, w: 10, h: 10 }, 0, 0],
  ]) {
    const c = RM.clampRectInBox(r, bw, bh)
    is(`x+w <= ${bw} for ${show(r)} in ${bw}x${bh}`, c,
      (v) => v.x >= 0 && v.y >= 0 && v.w >= 0 && v.h >= 0 && v.x + v.w <= bw && v.y + v.h <= bh,
      'inside the box')
  }
  // A null rect is not guarded here either, the same way scaleRect's is not:
  // the guard list in this file is a finite() check, not a shape check.
  throws('a null rect throws', () => RM.clampRectInBox(null, 10, 10), /reading 'w'/)
  throws('an undefined rect throws', () => RM.clampRectInBox(undefined, 10, 10))
})

// ---------------------------------------------------------------------------
section('RectMath.placeBox - a magnifier that steps around the rect it magnifies')

const ARENA = 1000
const BOX = 120
const GAP = 4

// The rect the box is grown by before the collision test, and the test
// itself: a box is clear when it is wholly left of, right of, above or
// below that rect, and touching counts as clear. This is the same
// separating-axis form placeBox applies internally, written out so the
// invariant is asserted against the return value rather than against the
// implementation that produced it.
const clearOf = (p, r) => p.x >= r.x + r.w + GAP || p.x + BOX <= r.x - GAP
  || p.y >= r.y + r.h + GAP || p.y + BOX <= r.y - GAP

group('with nothing to dodge, the box is centered on the point', () => {
  eq('a null rect', RM.placeBox(500, 500, BOX, null, ARENA, ARENA, GAP), { x: 440, y: 440 })
  eq('an undefined rect', RM.placeBox(500, 500, BOX, undefined, ARENA, ARENA, GAP), { x: 440, y: 440 })
  // A fresh drag is a zero-area rect at the cursor: there is no interior to
  // cover, so the lens stays on the pointer and does not jump on mouse-down.
  eq('a zero-area rect', RM.placeBox(500, 500, BOX, { x: 500, y: 500, w: 0, h: 0 }, ARENA, ARENA, GAP), { x: 440, y: 440 })
  // A rect that is zero on ONE axis is a strip, not nothing: a horizontal
  // drag is a full-width line the lens must not lie along, and it dodges.
  eq('a zero-width strip still dodges', RM.placeBox(500, 500, BOX, { x: 500, y: 500, w: 0, h: 40 }, ARENA, ARENA, GAP), { x: 504, y: 440 })
  // Near an edge the centered box clamps flush against it, so the sampled
  // pixel leaves the exact center of the lens - the pre-existing behavior
  // this function has to keep.
  eq('a point at the top-left corner', RM.placeBox(0, 0, BOX, null, ARENA, ARENA, GAP), { x: 0, y: 0 })
  eq('a point at the bottom-right corner', RM.placeBox(ARENA, ARENA, BOX, null, ARENA, ARENA, GAP), { x: 880, y: 880 })
  // A rect the centered box already misses is left alone: dodging is not
  // free, and a lens that already has a clear view stays on the pointer.
  eq('a rect the centered box misses', RM.placeBox(800, 100, BOX, { x: 10, y: 400, w: 100, h: 100 }, ARENA, ARENA, GAP), { x: 740, y: 40 })
  // A negative point is a pointer that has not been placed yet, not an
  // error: it clamps to the origin instead of producing a negative origin.
  eq('a negative point clamps', RM.placeBox(-50, -50, BOX, null, ARENA, ARENA, GAP), { x: 0, y: 0 })
})

group('an overlapping box escapes through the cheapest side', () => {
  // The cursor is the far corner of each rect, as it is mid-drag, so each
  // escape lands flush with the side the cursor is nearest.
  eq('down-right drag, escape right', RM.placeBox(700, 700, BOX, { x: 500, y: 500, w: 200, h: 200 }, ARENA, ARENA, GAP), { x: 704, y: 640 })
  eq('down-left drag, escape left', RM.placeBox(300, 700, BOX, { x: 300, y: 500, w: 200, h: 200 }, ARENA, ARENA, GAP), { x: 176, y: 640 })
  eq('up-right drag, escape right', RM.placeBox(700, 300, BOX, { x: 500, y: 300, w: 200, h: 200 }, ARENA, ARENA, GAP), { x: 704, y: 240 })
  eq('up-left drag, escape left', RM.placeBox(300, 300, BOX, { x: 300, y: 300, w: 200, h: 200 }, ARENA, ARENA, GAP), { x: 176, y: 240 })
  // A pointer inside the rect - a move drag - escapes over the nearest edge.
  // Left of the rect there is no room, so the escape is vertical, and a
  // pointer centered in it ties above against below: the earlier candidate
  // wins, which is what keeps the box from swapping sides frame to frame.
  eq('a pointer centered in the left third escapes below', RM.placeBox(150, 500, BOX, { x: 100, y: 400, w: 600, h: 200 }, ARENA, ARENA, GAP), { x: 90, y: 604 })
  eq('a pointer in the right third escapes right', RM.placeBox(650, 500, BOX, { x: 100, y: 400, w: 600, h: 200 }, ARENA, ARENA, GAP), { x: 704, y: 440 })
  eq('a pointer above the middle escapes above', RM.placeBox(150, 450, BOX, { x: 100, y: 400, w: 600, h: 200 }, ARENA, ARENA, GAP), { x: 90, y: 276 })
  // A zero-height rect is a horizontal drag: the only escapes are vertical
  // unless one of the ends has room, and the near end is the cheaper.
  eq('a horizontal strip escapes left', RM.placeBox(500, 500, BOX, { x: 500, y: 500, w: 400, h: 0 }, ARENA, ARENA, GAP), { x: 376, y: 440 })
  // A rect in the corner leaves the opposite corner as the only escape.
  eq('a corner rect', RM.placeBox(50, 50, BOX, { x: 0, y: 0, w: 200, h: 200 }, ARENA, ARENA, GAP), { x: 204, y: 0 })
})

group('the escape is a fixed offset, not a chase', () => {
  // The lens is a viewport, not a crop: a growing drag must not walk the
  // box across the screen. A constant offset from the cursor across a whole
  // growth sweep is what makes the lens feel attached to the pointer.
  for (const [label, grow] of [
    ['down-right', (i) => [500 + i * 10, 500 + i * 10]],
    ['down-left', (i) => [500 - i * 10, 500 + i * 10]],
    ['up-right', (i) => [500 + i * 10, 500 - i * 10]],
    ['up-left', (i) => [500 - i * 10, 500 - i * 10]],
  ]) {
    const offsets = new Set()
    for (let i = 1; i <= 20; i++) {
      const [cx, cy] = grow(i)
      const r = { x: Math.min(500, cx), y: Math.min(500, cy), w: Math.abs(cx - 500), h: Math.abs(cy - 500) }
      const p = RM.placeBox(cx, cy, BOX, r, ARENA, ARENA, GAP)
      is(`${label} step ${i} stays clear`, p, (v) => clearOf(v, r), 'clear of the rect')
      offsets.add(`${p.x + BOX / 2 - cx},${p.y + BOX / 2 - cy}`)
    }
    eq(`${label} holds one offset for the whole sweep`, offsets.size, 1)
  }
})

group('the box never leaves the area and never covers the rect', () => {
  // A clear position is one the grid below can find, independent of how
  // placeBox picks it. Asserting against the grid rather than against the
  // four flush candidates keeps this from re-implementing the function it
  // is checking: if any clear origin exists in the area, the returned one
  // has to be clear, and a rect that leaves no clear origin at all - one
  // covering the area - is the documented fallback rather than a miss.
  const clearOriginExists = (r) => {
    for (let x = 0; x + BOX <= ARENA; x += 8) {
      for (let y = 0; y + BOX <= ARENA; y += 8) {
        if (clearOf({ x, y }, r)) return true
      }
    }
    return false
  }
  let inside = 0
  let dodged = 0
  let missed = []
  for (let x = 0; x <= ARENA; x += 53) {
    for (let y = 0; y <= ARENA; y += 59) {
      for (const r of [
        { x, y, w: 0, h: 0 },
        { x, y, w: 300, h: 200 },
        { x: x - 200, y: y - 150, w: 400, h: 300 },
        { x: 0, y: 0, w: ARENA, h: ARENA },
        { x: x - 400, y, w: 800, h: 0 },
      ]) {
        const p = RM.placeBox(x, y, BOX, r, ARENA, ARENA, GAP)
        if (p.x < 0 || p.y < 0 || p.x + BOX > ARENA || p.y + BOX > ARENA) {
          missed.push(`origin ${show(p)} left the area for ${show(r)}`)
          continue
        }
        inside++
        if (clearOf(p, r)) dodged++
        // A rect with no extent on either axis is the pointer's own point,
        // not an obstacle: the contract is that the box does not dodge it.
        else if (r.w !== 0 || r.h !== 0) {
          if (clearOriginExists(r)) missed.push(`origin ${show(p)} covers ${show(r)}`)
        }
      }
    }
  }
  is('the sweep is not empty', inside, (v) => v > 0, 'a nonzero sample')
  eq('every box is inside the area and clear of the rect where it can be', missed, [])
  is('a real share of the sweep needed an escape', dodged, (v) => v > 100, 'dodged more than 100 times')
})

group('the degenerate inputs stay usable', () => {
  // A box larger than the area has nowhere to go, so it pins to the origin
  // rather than reporting a negative origin.
  eq('a box wider than the area', RM.placeBox(50, 50, BOX, { x: 0, y: 0, w: 200, h: 200 }, 80, 80, GAP), { x: 0, y: 0 })
  eq('a zero area', RM.placeBox(50, 50, BOX, null, 0, 0, GAP), { x: 0, y: 0 })
  // Unlike clampRectInBox above, the point and the size are guarded: both
  // arrive from a QML binding, and a NaN there would poison the origin for
  // every frame after it.
  eq('a NaN point falls back to the origin', RM.placeBox(NaN, NaN, BOX, null, ARENA, ARENA, GAP), { x: 0, y: 0 })
  eq('an undefined point falls back to the origin', RM.placeBox(undefined, undefined, BOX, null, ARENA, ARENA, GAP), { x: 0, y: 0 })
  eq('a numeric string point is not a coordinate', RM.placeBox('500', '500', BOX, null, ARENA, ARENA, GAP), { x: 0, y: 0 })
  // An unusable size floors to 1px, so the origin is the point itself
  // rather than a NaN that would blank the lens for the rest of the drag.
  eq('a zero size still yields a point', RM.placeBox(100, 100, 0, null, ARENA, ARENA, GAP), { x: 99.5, y: 99.5 })
  eq('a NaN size still yields a point', RM.placeBox(100, 100, NaN, null, ARENA, ARENA, GAP), { x: 99.5, y: 99.5 })
  eq('a negative size still yields a point', RM.placeBox(100, 100, -50, null, ARENA, ARENA, GAP), { x: 99.5, y: 99.5 })
  // A negative gap is a missing gap, and a missing gap means the box may sit
  // flush against the rect edge.
  eq('a negative gap is no gap', RM.placeBox(700, 700, BOX, { x: 500, y: 500, w: 200, h: 200 }, ARENA, ARENA, -5), { x: 700, y: 640 })
  // A fresh object per call: the origin is stored by a QML binding, so two
  // results must never alias.
  noThrow('two results do not alias', () => {
    const a = RM.placeBox(500, 500, BOX, null, ARENA, ARENA, GAP)
    const b = RM.placeBox(500, 500, BOX, null, ARENA, ARENA, GAP)
    if (a === b) throw new Error('the same object came back twice')
  })
  eq('the return shape is x,y', Object.keys(RM.placeBox(500, 500, BOX, null, ARENA, ARENA, GAP)), ['x', 'y'])
})

// ---------------------------------------------------------------------------
section('ShotLib - device pixel ratio chain')

group('qtDpr floors anything unusable at 1', () => {
  eq('a real ratio', SL.qtDpr(2), 2)
  eq('a fractional ratio', SL.qtDpr(1.5), 1.5)
  eq('a ratio below 1 is legal', SL.qtDpr(0.5), 0.5)
  eq('a numeric string coerces', SL.qtDpr('1.5'), 1.5)
  eq('0 is unusable', SL.qtDpr(0), 1)
  eq('a negative ratio is unusable', SL.qtDpr(-1), 1)
  eq('NaN is unusable', SL.qtDpr(NaN), 1)
  eq('Infinity is unusable', SL.qtDpr(Infinity), 1)
  eq('undefined is unusable', SL.qtDpr(undefined), 1)
  eq('null coerces to 0, so 1', SL.qtDpr(null), 1)
  eq('an empty string coerces to 0, so 1', SL.qtDpr(''), 1)
  eq('a non-numeric string', SL.qtDpr('wide'), 1)
  eq('no argument', SL.qtDpr(), 1)
  noThrow('an object', () => SL.qtDpr({}))
  noThrow('an array', () => SL.qtDpr([2]))
  noThrow('a boolean', () => SL.qtDpr(true))
})

group('compositorScale lets the compositor win even at 1', () => {
  // Documented: "The compositor wins whenever it reports one, including 1 -
  // a monitor at integer scale 1 on a HiDPI Qt session still has a
  // logical-to-physical ratio of 2, and the frame a screencopy reports is
  // the compositor's."
  eq('a real scale wins', SL.compositorScale(2, 1), 2)
  eq('scale 1 still wins over a Qt ratio of 2', SL.compositorScale(1, 2), 1)
  eq('a fractional compositor scale', SL.compositorScale(1.25, 2), 1.25)
  eq('a numeric string scale coerces', SL.compositorScale('1.25', 2), 1.25)
  eq('0 falls through to Qt', SL.compositorScale(0, 2), 2)
  eq('a negative scale falls through to Qt', SL.compositorScale(-1, 2), 2)
  eq('undefined falls through to Qt', SL.compositorScale(undefined, 2), 2)
  eq('null falls through to Qt', SL.compositorScale(null, 2), 2)
  eq('NaN falls through to Qt', SL.compositorScale(NaN, 2), 2)
  eq('both unusable gives 1', SL.compositorScale(NaN, NaN), 1)
  eq('both nullish gives 1', SL.compositorScale(null, null), 1)
  // The fallback is qtDpr, so it inherits the floor rather than returning
  // the raw Qt value.
  eq('an unusable Qt ratio is floored on the way through', SL.compositorScale(null, 0), 1)
  eq('a Qt ratio of 0 through the fallback', SL.compositorScale(0, 0), 1)
  eq('no arguments at all', SL.compositorScale(), 1)
  noThrow('an object scale', () => SL.compositorScale({}, 2))
  noThrow('an array ratio', () => SL.compositorScale(1, [2]))
})

// ---------------------------------------------------------------------------
section('ShotLib - the grab size chain')

group('grabSourceSize prefers a landed frame and computes one otherwise', () => {
  eq('no frame yet, so it computes', SL.grabSourceSize(100, 50, 1.5, 0, 0), { width: 150, height: 75 })
  eq('a width only', SL.grabSourceSize(100, 50, 1.5, 300, 0), { width: 300, height: 75 })
  eq('a height only', SL.grabSourceSize(100, 50, 1.5, 0, 200), { width: 150, height: 200 })
  eq('both reported', SL.grabSourceSize(100, 50, 1.5, 300, 200), { width: 300, height: 200 })
  eq('a negative reported size is not a frame', SL.grabSourceSize(100, 50, 1, -10, -10), { width: 100, height: 50 })
  eq('rounds half up', SL.grabSourceSize(101, 1, 1.5, 0, 0), { width: 152, height: 2 })
  // Deliberately not floored at 1: this is "what the frame should be", and
  // a 0x0 here is what tells the caller no frame has landed yet.
  eq('nothing configured at all is 0x0', SL.grabSourceSize(0, 0, 0, 0, 0), { width: 0, height: 0 })
  eq('a collapsed view with no frame', SL.grabSourceSize(0, 0, 2, 0, 0), { width: 0, height: 0 })
})

group('grabItemSize is the expected size, floored at 1 so it never matches 0x0', () => {
  eq('a normal window', SL.grabItemSize(100, 50, 1.5), { width: 150, height: 75 })
  eq('a collapsed window', SL.grabItemSize(0, 0, 0), { width: 1, height: 1 })
  eq('a sub-pixel window', SL.grabItemSize(0.5, 0.5, 1), { width: 1, height: 1 })
  eq('a window smaller than the dpr', SL.grabItemSize(1, 1, 0.5), { width: 1, height: 1 })
  eq('rounds half up', SL.grabItemSize(101, 1, 1), { width: 101, height: 1 })
  eq('a 0x0 view at 1.5 still floors at 1', SL.grabItemSize(0, 0, 1.5), { width: 1, height: 1 })
  eq('the floor is the documented reason the two differ',
    [SL.grabSourceSize(0, 0, 1, 0, 0), SL.grabItemSize(0, 0, 1)],
    [{ width: 0, height: 0 }, { width: 1, height: 1 }])
  eq('a fractional size rounds', SL.grabItemSize(10, 10, 1.25), { width: 13, height: 13 })
})

group('sourceSizeMatches allows one pixel of slack on both axes', () => {
  eq('exact', SL.sourceSizeMatches(100, 100, 100, 100, 1), true)
  eq('one pixel narrow', SL.sourceSizeMatches(100, 100, 99, 100, 1), true)
  eq('one pixel wide', SL.sourceSizeMatches(100, 100, 101, 100, 1), true)
  eq('one pixel short', SL.sourceSizeMatches(100, 100, 100, 99, 1), true)
  eq('one pixel tall', SL.sourceSizeMatches(100, 100, 100, 101, 1), true)
  eq('diagonally one off', SL.sourceSizeMatches(100, 100, 101, 99, 1), true)
  eq('two pixels is a scaled-down grab', SL.sourceSizeMatches(100, 100, 102, 100, 1), false)
  eq('two pixels on the other axis too', SL.sourceSizeMatches(100, 100, 100, 102, 1), false)
  eq('the tolerance has to cover both axes', SL.sourceSizeMatches(100, 100, 102, 98, 1), false)
  eq('a 0 tolerance still admits one pixel', SL.sourceSizeMatches(100, 100, 101, 100, 0), true)
  eq('a negative tolerance is replaced by 1', SL.sourceSizeMatches(100, 100, 101, 100, -5), true)
  eq('a negative tolerance still rejects two', SL.sourceSizeMatches(100, 100, 102, 100, -5), false)
  eq('an omitted tolerance defaults to 1', SL.sourceSizeMatches(100, 100, 101, 100), true)
  eq('a numeric string tolerance coerces', SL.sourceSizeMatches(100, 100, 102, 100, '2'), true)
  eq('a NaN tolerance is replaced by 1', SL.sourceSizeMatches(100, 100, 102, 100, NaN), false)
  eq('a fractional tolerance compares against the fraction', SL.sourceSizeMatches(100, 100, 101.5, 100, 1), false)
  eq('a NaN expected size never matches', SL.sourceSizeMatches(NaN, 100, 100, 100, 1), false)
  eq('a NaN actual never matches', SL.sourceSizeMatches(100, 100, NaN, 100, 1), false)
  eq('an Infinity tolerance accepts anything finite', SL.sourceSizeMatches(100, 100, 1e6, 1, Infinity), true)
  eq('a 0x0 source against a 1x1 expectation matches', SL.sourceSizeMatches(1, 1, 0, 0, 1), true)
})

group('grabTargetSize divides the frame back down to the item', () => {
  eq('a 1:1 dpr', SL.grabTargetSize(300, 150, 1), { width: 300, height: 150 })
  eq('a 2:1 dpr', SL.grabTargetSize(300, 150, 2), { width: 150, height: 75 })
  eq('a 1.5 dpr is exact here', SL.grabTargetSize(300, 150, 1.5), { width: 200, height: 100 })
  // ceil, not round: the target must not be smaller than the source it has
  // to hold, or the last row of the frame is dropped.
  eq('ceil keeps an odd source whole', SL.grabTargetSize(301, 151, 1), { width: 301, height: 151 })
  eq('ceil rounds up a remainder', SL.grabTargetSize(5, 5, 2), { width: 3, height: 3 })
  eq('an exact division does not round up', SL.grabTargetSize(4, 4, 2), { width: 2, height: 2 })
  eq('a target of 0 is floored to 1', SL.grabTargetSize(2, 2, 2), { width: 1, height: 1 })
  eq('a 1px source at dpr 2', SL.grabTargetSize(1, 1, 2), { width: 1, height: 1 })
  eq('a 0 source', SL.grabTargetSize(0, 0, 1), { width: 1, height: 1 })
  eq('a negative source', SL.grabTargetSize(-5, -5, 1), { width: 1, height: 1 })
  eq('a NaN source', SL.grabTargetSize(NaN, NaN, 1), { width: 1, height: 1 })
  eq('a numeric string source coerces', SL.grabTargetSize('300', 150, 1), { width: 300, height: 150 })
  eq('a 0 dpr is floored to 1, so no division', SL.grabTargetSize(300, 150, 0), { width: 300, height: 150 })
  eq('a sub-pixel source rounds before it divides', SL.grabTargetSize(0.5, 0.5, 0.5), { width: 2, height: 2 })
  eq('a fractional source rounds first', SL.grabTargetSize(1.4, 1.6, 1), { width: 1, height: 2 })
  eq('no arguments', SL.grabTargetSize(), { width: 1, height: 1 })
  noThrow('an object source', () => SL.grabTargetSize({}, {}))
  noThrow('an array dpr', () => SL.grabTargetSize(10, 10, [2]))
})

group('grabResultSize is the target scaled back up by the window dpr', () => {
  // The round trip is the contract: target * dpr is the file on disk, and
  // that file is the grid a selection is mapped onto and clamped into.
  eq('a 1:1 dpr is the identity', SL.grabResultSize(300, 150, 1), { width: 300, height: 150 })
  eq('a 2:1 dpr doubles it', SL.grabResultSize(150, 75, 2), { width: 300, height: 150 })
  eq('a 1.2 dpr, the surface ratio of a 1600x900 window on a 1920x1080 frame',
    SL.grabResultSize(1600, 900, 1.2), { width: 1920, height: 1080 })
  eq('a fractional dpr rounds', SL.grabResultSize(10, 10, 1.25), { width: 13, height: 13 })
  eq('rounds half up', SL.grabResultSize(5, 5, 1.5), { width: 8, height: 8 })
  eq('a 0 dpr is floored to 1, so the target stands', SL.grabResultSize(300, 150, 0),
    { width: 300, height: 150 })
  eq('a negative dpr is floored to 1 too', SL.grabResultSize(300, 150, -2),
    { width: 300, height: 150 })
  eq('a NaN dpr is floored to 1', SL.grabResultSize(300, 150, NaN), { width: 300, height: 150 })
  eq('a 0 target is floored to 1', SL.grabResultSize(0, 0, 2), { width: 1, height: 1 })
  eq('a negative target is floored to 1', SL.grabResultSize(-5, -5, 2), { width: 1, height: 1 })
  eq('a NaN target is floored to 1', SL.grabResultSize(NaN, NaN, 2), { width: 1, height: 1 })
  eq('a numeric string target coerces', SL.grabResultSize('300', 150, 2), { width: 600, height: 300 })
  eq('a sub-pixel target rounds', SL.grabResultSize(0.5, 0.5, 2), { width: 1, height: 1 })
  eq('no arguments', SL.grabResultSize(), { width: 1, height: 1 })
  noThrow('an object target', () => SL.grabResultSize({}, {}))
  noThrow('an array dpr', () => SL.grabResultSize(10, 10, [2]))
  // The bug this exists for: the target was published as the frame, so a
  // selection was mapped and clamped onto a grid 1/dpr of the file it is
  // cut from - anchored top-left, short of the region the pointer drew.
  eq('the target is never the frame when the dpr is not 1',
    SL.grabResultSize(1600, 900, 1.2).width !== 1600, true)
})

// ---------------------------------------------------------------------------
section('ShotLib - output identity across a hotplug')

group('screenKey prefers the serial pair, and orders it candidate-first', () => {
  eq('both sides report a serial', SL.screenKey({ serialNumber: 'A1', name: 'DP-1' }, { serialNumber: 'B2', name: 'DP-2' }), 'serial:A1|B2')
  // The order is fixed, not symmetric, so a key can be produced from either
  // side of a pair and still come out the same string.
  eq('the pair is not sorted', SL.screenKey({ serialNumber: 'B', name: 'x' }, { serialNumber: 'A', name: 'y' }), 'serial:B|A')
  eq('the connector name is not in the serial key', SL.screenKey({ serialNumber: 'A1', name: 'DP-1' }, { serialNumber: 'A1', name: 'DP-2' }), 'serial:A1|A1')
  eq('a numeric serial stringifies', SL.screenKey({ serialNumber: 5 }, { serialNumber: 6 }), 'serial:5|6')
  // `?? ""` is a nullish fold, so 0 survives as the serial "0" while an
  // empty string counts as no serial at all.
  eq('serial 0 is a serial', SL.screenKey({ serialNumber: 0, name: 'n' }, { serialNumber: 'A' }), 'serial:0|A')
  eq('an empty serial is not', SL.screenKey({ serialNumber: '', name: 'n' }, { serialNumber: 'A' }), 'name:n')
  eq('a missing serial is not', SL.screenKey({ name: 'n' }, { serialNumber: 'A' }), 'name:n')
})

group('one serial on one side only falls back to the connector name', () => {
  // Documented: "one screen's serial alone would be a key the other side
  // cannot produce and a hotplug mid-capture would resolve to a stale
  // object", so the key pairs both names instead of one name and one serial.
  eq('the candidate has no serial', SL.screenKey({ name: 'DP-1' }, { serialNumber: 'B2', name: 'DP-2' }), 'name:DP-1')
  eq('the other side has no serial', SL.screenKey({ serialNumber: 'A1', name: 'DP-1' }, { name: 'DP-2' }), 'name:DP-1')
  eq('neither side has one', SL.screenKey({ name: 'DP-1' }, { name: 'DP-2' }), 'name:DP-1')
  eq('an unnamed screen with no serial is the unusable key', SL.screenKey({ name: '' }, {}), 'name:')
  eq('an unnamed screen with a serial still falls back', SL.screenKey({ serialNumber: 'A' }, { name: '' }), 'name:')
  eq('a missing name', SL.screenKey({}, {}), 'name:')
})

group('matchScreen resolves identity first, then key plus mode size', () => {
  const a = { name: 'DP-1', serialNumber: 'S1', width: 1920, height: 1080 }
  const b = { name: 'DP-2', serialNumber: 'S2', width: 1280, height: 720 }
  eq('the same object resolves to itself', SL.matchScreen(a, [b, a]) === a, true)
  eq('a reconfigured screen resolves to the live object',
    SL.matchScreen({ name: 'DP-1', serialNumber: 'S1', width: 1920, height: 1080 }, [a]) === a, true)
  // Identity is checked first, so a stale candidate that is still in the
  // list wins over a key match against another entry.
  eq('identity beats a key match', SL.matchScreen(b, [a, b]) === b, true)
  // The mode size is part of the match: a resolution change reads as a
  // different screen rather than the old one.
  eq('a width change is a different screen', SL.matchScreen({ name: 'DP-1', serialNumber: 'S1', width: 1280, height: 1080 }, [a]), null)
  eq('a height change is a different screen', SL.matchScreen({ name: 'DP-1', serialNumber: 'S1', width: 1920, height: 720 }, [a]), null)
  eq('a serial change is a different screen', SL.matchScreen({ name: 'DP-1', serialNumber: 'S9', width: 1920, height: 1080 }, [a]), null)
  eq('a connector rename with the serial kept matches', SL.matchScreen({ name: 'DP-3', serialNumber: 'S1', width: 1920, height: 1080 }, [a]) === a, true)
  // Documented: "a screen the compositor has not described yet falls back to
  // the connector name" - a candidate with no serial matches by name.
  eq('a candidate with no serial matches by name',
    SL.matchScreen({ name: 'DP-1', width: 1920, height: 1080 }, [a]) === a, true)
  eq('an unnamed candidate matches nothing', SL.matchScreen({ name: '', width: 1920, height: 1080 }, [a]), null)
  eq('an empty list', SL.matchScreen(a, []), null)
  eq('a non-array list', SL.matchScreen(a, null), null)
  eq('a null candidate', SL.matchScreen(null, [a]), null)
  eq('an undefined candidate', SL.matchScreen(undefined, [a]), null)
  eq('no arguments at all', SL.matchScreen(), null)
  noThrow('an empty object candidate', () => SL.matchScreen({}, []))
  // A hole in the screen list is a caller error, not something the contract
  // covers: screenKey dereferences both arguments.
  throws('a null entry in the list throws', () => SL.matchScreen(a, [null, a]), /reading 'serialNumber'/)
})

group('pickFocusedScreen is a pure walk of the list', () => {
  const a = { name: 'DP-1', serialNumber: 'S1' }
  const b = { name: 'DP-2', serialNumber: 'S2' }
  const byName = (s) => ({ id: s.name })
  eq('the second screen', SL.pickFocusedScreen([a, b], byName, 'DP-2') === b, true)
  eq('the first screen', SL.pickFocusedScreen([a, b], byName, 'DP-1') === a, true)
  eq('an unknown id', SL.pickFocusedScreen([a, b], byName, 'DP-9'), null)
  eq('an empty list', SL.pickFocusedScreen([], byName, 'DP-1'), null)
  eq('a null id is never the focused one', SL.pickFocusedScreen([a], byName, null), null)
  eq('an undefined id is never the focused one', SL.pickFocusedScreen([a], byName, undefined), null)
  // Identity comparison, not equality: the id is whatever the caller's
  // resolver produced, and a 0 or false monitor id is a real one.
  eq('a 0 id matches', SL.pickFocusedScreen([a, b], (s) => ({ id: s.name === 'DP-1' ? 0 : 1 }), 0) === a, true)
  eq('a false id matches', SL.pickFocusedScreen([a], () => ({ id: false }), false) === a, true)
  eq('a screen the resolver cannot map is skipped', SL.pickFocusedScreen([a], () => null, 'DP-1'), null)
  eq('a monitor with no id field is skipped', SL.pickFocusedScreen([a], () => ({}), 'DP-1'), null)
  eq('a non-array list', SL.pickFocusedScreen(null, byName, 'DP-1'), null)
  eq('a non-function resolver', SL.pickFocusedScreen([a], null, 'DP-1'), null)
  eq('a string resolver', SL.pickFocusedScreen([a], 'byName', 'DP-1'), null)
  eq('no arguments at all', SL.pickFocusedScreen(), null)
  // The resolver is called unguarded, so a resolver that throws is the
  // caller's own error rather than a "no focused screen" answer.
  throws('a throwing resolver propagates', () => SL.pickFocusedScreen([a], () => { throw new Error('resolver') }, 'DP-1'), /resolver/)
})

// ---------------------------------------------------------------------------
section('ShotLib - flow sequencing guards')

group('flowLive requires a positive id equal to the live flow', () => {
  eq('live', SL.flowLive(1, 1), true)
  eq('a superseded flow', SL.flowLive(2, 1), false)
  eq('an unreleased flow of 0', SL.flowLive(0, 0), false)
  eq('a negative id is never live', SL.flowLive(-1, -1), false)
  eq('a numeric string id', SL.flowLive('1', 1), true)
  eq('a numeric string flow', SL.flowLive(1, '1'), true)
  eq('both numeric strings', SL.flowLive('2', 2), true)
  eq('NaN', SL.flowLive(NaN, NaN), false)
  eq('null', SL.flowLive(null, null), false)
  eq('undefined', SL.flowLive(undefined, undefined), false)
  eq('a live id against no flow', SL.flowLive(1, undefined), false)
  eq('no flow against a live id', SL.flowLive(undefined, 1), false)
  eq('no arguments at all', SL.flowLive(), false)
  eq('Infinity is not live', SL.flowLive(Infinity, Infinity), false)
  eq('a fractional id matches a fractional flow', SL.flowLive(1.5, 1.5), true)
  eq('a fractional id does not match a rounded flow', SL.flowLive(1.5, 1.5 + Number.EPSILON), false)
})

group('jobLive requires both ids, so a replaced job cannot answer', () => {
  eq('both live', SL.jobLive(1, 1, 1, 1), true)
  eq('a newer job replaced it', SL.jobLive(2, 1, 1, 1), false)
  eq('a newer flow replaced it', SL.jobLive(1, 1, 2, 1), false)
  eq('both replaced', SL.jobLive(2, 1, 3, 1), false)
  eq('a job id of 0 is never live', SL.jobLive(0, 0, 1, 1), false)
  eq('a flow id of 0 is never live', SL.jobLive(1, 1, 0, 0), false)
  eq('negative ids are never live', SL.jobLive(-1, -1, -1, -1), false)
  eq('numeric strings coerce', SL.jobLive('1', '1', '1', '1'), true)
  eq('a numeric string against a number', SL.jobLive('1', 1, 1, 1), true)
  eq('NaN', SL.jobLive(NaN, NaN, NaN, NaN), false)
  eq('null', SL.jobLive(null, null, null, null), false)
  eq('undefined', SL.jobLive(undefined, undefined, undefined, undefined), false)
  eq('a missing job id', SL.jobLive(undefined, 1, 1, 1), false)
  eq('a missing flow id', SL.jobLive(1, 1, undefined, 1), false)
  eq('a non-numeric job id', SL.jobLive('job-1', 'job-1', 1, 1), false)
  eq('no arguments at all', SL.jobLive(), false)
})

group('requestLive drops a released id, which resolves to 0', () => {
  eq('held', SL.requestLive(3, 3), true)
  eq('released to 0', SL.requestLive(0, 0), false)
  eq('released to 0 against a live id', SL.requestLive(0, 3), false)
  eq('a replaced request', SL.requestLive(4, 3), false)
  eq('a numeric string', SL.requestLive(3, '3'), true)
  eq('NaN', SL.requestLive(NaN, NaN), false)
  eq('null', SL.requestLive(null, null), false)
  eq('a live request against no current', SL.requestLive(3, undefined), false)
  eq('negative', SL.requestLive(-3, -3), false)
  eq('no arguments at all', SL.requestLive(), false)
})

group('liveRegionIdentity holds a grab job against the request it belongs to', () => {
  const live = { jobId: 1, flowId: 1 }
  eq('matching', SL.liveRegionIdentity(live, { jobId: 1 }, 1), true)
  eq('a different job', SL.liveRegionIdentity(live, { jobId: 2 }, 1), false)
  eq('a different flow', SL.liveRegionIdentity({ jobId: 1, flowId: 2 }, { jobId: 1 }, 1), false)
  eq('no live region', SL.liveRegionIdentity(null, { jobId: 1 }, 1), false)
  eq('an undefined live region', SL.liveRegionIdentity(undefined, { jobId: 1 }, 1), false)
  eq('no request', SL.liveRegionIdentity(live, null, 1), false)
  eq('an undefined request', SL.liveRegionIdentity(live, undefined, 1), false)
  eq('a job id of 0 is not live', SL.liveRegionIdentity({ jobId: 0, flowId: 1 }, { jobId: 0 }, 1), false)
  eq('a missing job id', SL.liveRegionIdentity({ flowId: 1 }, { jobId: 1 }, 1), false)
  eq('a request with no job id', SL.liveRegionIdentity(live, {}, 1), false)
  eq('numeric strings coerce', SL.liveRegionIdentity({ jobId: '1', flowId: '1' }, { jobId: '1' }, '1'), true)
  eq('a non-numeric job id', SL.liveRegionIdentity({ jobId: 'job-1', flowId: 1 }, { jobId: 'job-1' }, 1), false)
  eq('an unreleased flow', SL.liveRegionIdentity(live, { jobId: 1 }, undefined), false)
  eq('a NaN flow on both sides', SL.liveRegionIdentity({ jobId: 1, flowId: NaN }, { jobId: 1 }, NaN), false)
  eq('an empty object as a live region', SL.liveRegionIdentity({}, { jobId: 1 }, 1), false)
  eq('no arguments at all', SL.liveRegionIdentity(), false)
})

group('seedRegionIdentity additionally matches the seed by identity and url', () => {
  const seed = { jobId: 1, flowId: 1, url: 'file:///tmp/a.png' }
  const req = { jobId: 1, url: 'file:///tmp/a.png' }
  eq('matching', SL.seedRegionIdentity(seed, seed, req, 1), true)
  eq('a different url', SL.seedRegionIdentity(seed, seed, { jobId: 1, url: 'file:///tmp/b.png' }, 1), false)
  // Identity, not equality: an answer for a seed the service already
  // discarded must not validate against its replacement.
  eq('an equal but different seed object', SL.seedRegionIdentity(seed, { ...seed }, req, 1), false)
  eq('the current seed was cleared', SL.seedRegionIdentity(seed, null, req, 1), false)
  eq('the current seed is undefined', SL.seedRegionIdentity(seed, undefined, req, 1), false)
  eq('no seed at all', SL.seedRegionIdentity(null, null, req, 1), false)
  eq('no request', SL.seedRegionIdentity(seed, seed, null, 1), false)
  eq('a different flow', SL.seedRegionIdentity(seed, seed, req, 2), false)
  eq('a job id of 0 is not live', SL.seedRegionIdentity({ jobId: 0, flowId: 1, url: 'x' }, { jobId: 0, flowId: 1, url: 'x' }, { jobId: 0 }, 1), false)
  eq('a missing job id', SL.seedRegionIdentity({ flowId: 1, url: 'x' }, { flowId: 1, url: 'x' }, { jobId: 1 }, 1), false)
  eq('a missing seed url', SL.seedRegionIdentity({ jobId: 1, flowId: 1 }, { jobId: 1, flowId: 1 }, { jobId: 1 }, 1), false)
  eq('a request with no url', SL.seedRegionIdentity(seed, seed, { jobId: 1 }, 1), false)
  // The url is compared as a string, so a numeric one still matches - but a
  // number is not a stringified number here, because the seed side is
  // String()d and the request side is not folded the same way.
  eq('a numeric seed url against a string request url', SL.seedRegionIdentity({ jobId: 1, flowId: 1, url: 7 }, { jobId: 1, flowId: 1, url: 7 }, { jobId: 1, url: '7' }, 1), false)
  eq('a string seed url against a string request url', SL.seedRegionIdentity(seed, seed, { jobId: 1, url: 'file:///tmp/a.png' }, 1), true)
  eq('no arguments at all', SL.seedRegionIdentity(), false)
})

// ---------------------------------------------------------------------------
section('ShotLib - naming, suffixes and mimes')

group('timestamp is manual Date math in the bash tool shape', () => {
  // Never toLocaleString: the name has to sort identically in every locale.
  match('the documented shape', SL.timestamp(), /^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/)
  match('the year matches the clock', SL.timestamp(), new RegExp(`^${new Date().getFullYear()}-`))
  eq('two-digit padding', SL._pad(5), '05')
  eq('two digits stay two digits', SL._pad(15), '15')
  eq('a single digit is padded to two', SL._pad(0), '00')
  eq('three digits are not truncated', SL._pad(100), '100')
  match('fileStem is the timestamp behind a prefix', SL.fileStem(), /^screenshot-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/)
  contains('fileStem carries the same timestamp', SL.fileStem(), SL.timestamp().slice(0, 4))
  notMatch('no locale punctuation leaks in', SL.timestamp(), /[,\s]|AM|PM/)
})

group('the suffix is the one Canvas.save checks, and it is jpg not jpeg', () => {
  eq('jpeg', SL.suffixFor('jpeg'), 'jpg')
  eq('png', SL.suffixFor('png'), 'png')
  eq('anything else is png', SL.suffixFor('webp'), 'png')
  eq('an undefined type is png', SL.suffixFor(undefined), 'png')
  eq('null is png', SL.suffixFor(null), 'png')
  // The type string is compared exactly, so a settings value that arrived
  // capitalised silently captures a PNG.
  eq('JPEG is not jpeg', SL.suffixFor('JPEG'), 'png')
  eq('an empty type', SL.suffixFor(''), 'png')
  eq('no arguments at all', SL.suffixFor(), 'png')
  eq('mimeFor jpeg', SL.mimeFor('jpeg'), 'image/jpeg')
  eq('mimeFor anything else', SL.mimeFor('webp'), 'image/png')
  eq('mimeFor null', SL.mimeFor(null), 'image/png')
  // The two tables have to agree, or a saved .jpg would be announced as PNG.
  for (const type of ['jpeg', 'png', 'webp', 'JPEG', '', null, undefined]) {
    is(`suffixFor(${show(type)}) and mimeFor(${show(type)}) agree on one format`,
      [SL.suffixFor(type), SL.mimeFor(type)],
      (v) => (v[0] === 'jpg') === (v[1] === 'image/jpeg'), 'jpg <=> image/jpeg')
  }
})

group('ensureImageSuffix appends only when the suffix is not already an image', () => {
  eq('png kept', SL.ensureImageSuffix('/tmp/a.png'), '/tmp/a.png')
  eq('jpg kept', SL.ensureImageSuffix('/tmp/a.jpg'), '/tmp/a.jpg')
  eq('jpeg kept', SL.ensureImageSuffix('/tmp/a.jpeg'), '/tmp/a.jpeg')
  eq('webp kept', SL.ensureImageSuffix('/tmp/a.webp'), '/tmp/a.webp')
  eq('bmp kept', SL.ensureImageSuffix('/tmp/a.bmp'), '/tmp/a.bmp')
  eq('tif kept', SL.ensureImageSuffix('/tmp/a.tif'), '/tmp/a.tif')
  eq('tiff kept', SL.ensureImageSuffix('/tmp/a.tiff'), '/tmp/a.tiff')
  eq('the match is case-insensitive', SL.ensureImageSuffix('/tmp/a.PNG'), '/tmp/a.PNG')
  eq('a dot is added for a bare name', SL.ensureImageSuffix('/tmp/a', 'jpeg'), '/tmp/a.jpg')
  eq('png is the fallback suffix', SL.ensureImageSuffix('/tmp/a', 'png'), '/tmp/a.png')
  eq('an unknown preferred type is still png', SL.ensureImageSuffix('/tmp/a', 'zzz'), '/tmp/a.png')
  // A file that exists but is not an image gets a suffix appended, so the
  // canvas encoder picks a format rather than reading the bytes.
  eq('a gif is not an image suffix here', SL.ensureImageSuffix('/tmp/a.gif'), '/tmp/a.gif.png')
  eq('a text file', SL.ensureImageSuffix('/tmp/a.txt', 'jpeg'), '/tmp/a.txt.jpg')
  eq('an empty path gets a bare suffix', SL.ensureImageSuffix('', 'jpeg'), '.jpg')
  eq('a null path', SL.ensureImageSuffix(null, 'png'), '.png')
  eq('an omitted preferred type', SL.ensureImageSuffix('/tmp/a'), '/tmp/a.png')
  eq('a trailing dot is not an image suffix', SL.ensureImageSuffix('/tmp/a.'), '/tmp/a..png')
  eq('a URI keeps its extension', SL.ensureImageSuffix(SL.fileUri('/tmp/a b.png'), 'jpeg'), 'file:///tmp/a%20b.png')
  eq('no arguments at all', SL.ensureImageSuffix(), '.png')
})

group('mimeForPath reads the extension, case-insensitively, png by default', () => {
  const cases = [
    ['/tmp/a.jpg', 'image/jpeg'],
    ['/tmp/a.JPG', 'image/jpeg'],
    ['/tmp/a.jpeg', 'image/jpeg'],
    ['/tmp/a.JPEG', 'image/jpeg'],
    ['a.webp', 'image/webp'],
    ['a.bmp', 'image/bmp'],
    ['a.tif', 'image/tiff'],
    ['a.tiff', 'image/tiff'],
    ['a.TIFF', 'image/tiff'],
    ['a.svg', 'image/svg+xml'],
    ['a.png', 'image/png'],
    ['a.PNG', 'image/png'],
  ]
  for (const [p, m] of cases) {
    eq(`mimeForPath(${p})`, SL.mimeForPath(p), m)
  }
  eq('no extension', SL.mimeForPath('a'), 'image/png')
  eq('a dot mid-name is not an extension', SL.mimeForPath('a.jpg.txt'), 'image/png')
  eq('a trailing dot', SL.mimeForPath('a.'), 'image/png')
  eq('an empty string', SL.mimeForPath(''), 'image/png')
  eq('null', SL.mimeForPath(null), 'image/png')
  eq('undefined', SL.mimeForPath(undefined), 'image/png')
  eq('no arguments at all', SL.mimeForPath(), 'image/png')
  // A path carrying a percent-encoded extension is not decoded first, so it
  // does not match either.
  eq('an encoded extension', SL.mimeForPath('/tmp/a%2Ejpg'), 'image/png')
  noThrow('an object', () => SL.mimeForPath({}))
  noThrow('an array', () => SL.mimeForPath(['a.jpg']))
  noThrow('a number', () => SL.mimeForPath(7))
})

group('pathFromFileUrl decodes without treating reserved characters as separators', () => {
  eq('an absolute path', SL.pathFromFileUrl('file:///tmp/a.png'), '/tmp/a.png')
  eq('a localhost authority is dropped', SL.pathFromFileUrl('file://localhost/tmp/a.png'), '/tmp/a.png')
  eq('a percent-encoded space', SL.pathFromFileUrl('file:///tmp/a%20b.png'), '/tmp/a b.png')
  eq('a percent-encoded hash', SL.pathFromFileUrl('file:///tmp/a%23b.png'), '/tmp/a#b.png')
  eq('a plus is a literal plus, not a space', SL.pathFromFileUrl('file:///tmp/a+b.png'), '/tmp/a+b.png')
  // A bare authority is kept as the first path segment, which is what
  // "without treating reserved characters as path separators" buys: a UNC
  // host is not silently promoted to a directory.
  eq('a host authority is not dropped', SL.pathFromFileUrl('file://host/tmp/a.png'), 'host/tmp/a.png')
  eq('a query string is not stripped', SL.pathFromFileUrl('file:///tmp/a.png?x=1'), '/tmp/a.png?x=1')
  eq('the root', SL.pathFromFileUrl('file:///'), '/')
  eq('a malformed escape sequence yields nothing', SL.pathFromFileUrl('file:///tmp/100%.png'), '')
  eq('a lone percent', SL.pathFromFileUrl('file:///100%'), '')
  eq('not a file url', SL.pathFromFileUrl('/tmp/a.png'), '')
  eq('an https url', SL.pathFromFileUrl('https://x/a.png'), '')
  eq('a bare scheme', SL.pathFromFileUrl('file://'), '')
  eq('a relative url', SL.pathFromFileUrl('a.png'), '')
  eq('an empty string', SL.pathFromFileUrl(''), '')
  eq('null', SL.pathFromFileUrl(null), '')
  eq('undefined', SL.pathFromFileUrl(undefined), '')
  eq('no arguments at all', SL.pathFromFileUrl(), '')
  noThrow('a number', () => SL.pathFromFileUrl(7))
  // A decoded result is a usable path: it round-trips through fileUri.
  const decoded = SL.pathFromFileUrl('file:///tmp/a%20b.png')
  eq('the decoded path round-trips through fileUri', SL.fileUri(decoded), 'file:///tmp/a%20b.png')
  contains('a percent escape is decoded, not kept', SL.pathFromFileUrl('file:///tmp/%2Fetc'), '/etc')
})

// ---------------------------------------------------------------------------
section('ShotLib - clipboard and notification copy')

group('sq delegates to StringUtils.shellQuote', () => {
  eq('a plain word', SL.sq('abc'), "'abc'")
  eq('a word with a space', SL.sq('a b'), "'a b'")
  eq('an empty string', SL.sq(''), "''")
  eq('an embedded quote is escaped', SL.sq("it's"), "'it'\\''s'")
  // shellQuote stringifies its argument, so a nullish path becomes the shell
  // word 'undefined' rather than an empty one. The only caller passes
  // fileUri(), which is always a string, so this is a pinned sharp edge
  // rather than a live path.
  eq('no argument stringifies undefined', SL.sq(), "'undefined'")
  eq('null stringifies null', SL.sq(null), "'null'")
  eq('0 stringifies 0', SL.sq(0), "'0'")
})

group('fileUri percent-encodes each segment and keeps one scheme', () => {
  eq('an absolute path', SL.fileUri('/tmp/a.png'), 'file:///tmp/a.png')
  eq('a path with a space', SL.fileUri('/tmp/a b.png'), 'file:///tmp/a%20b.png')
  eq('a path with a quote is not shell-special to the URI', SL.fileUri("/tmp/it's.png"), "file:///tmp/it's.png")
  eq('a path with a percent sign', SL.fileUri('/tmp/100%.png'), 'file:///tmp/100%25.png')
  eq('a path with a hash', SL.fileUri('/tmp/a#b.png'), 'file:///tmp/a%23b.png')
  eq('a path with a newline', SL.fileUri('/tmp/a\nb.png'), 'file:///tmp/a%0Ab.png')
  eq('a relative path gets the root', SL.fileUri('a/b.png'), 'file:///a/b.png')
  eq('a single segment', SL.fileUri('a.png'), 'file:///a.png')
  eq('repeated separators collapse', SL.fileUri('//tmp//a.png'), 'file:///tmp/a.png')
  eq('a trailing separator is dropped', SL.fileUri('/tmp/'), 'file:///tmp')
  eq('the root', SL.fileUri('/'), 'file:///')
  eq('an empty path still names a root', SL.fileUri(''), 'file:///')
  eq('null', SL.fileUri(null), 'file:///')
  // An existing URI is passed through untouched rather than double-encoded.
  eq('an existing uri is not re-encoded', SL.fileUri('file:///tmp/a.png'), 'file:///tmp/a.png')
  eq('an existing uri with a space is left alone', SL.fileUri('file:///tmp/a%20b.png'), 'file:///tmp/a%20b.png')
  for (const p of ['/tmp/a.png', '/tmp/a b.png', "/tmp/it's.png", 'relative/x.png', '/a#b/c%d.png']) {
    is(`fileUri(${p}) has exactly one scheme separator`, SL.fileUri(p),
      (v) => v.startsWith('file://') && !v.slice(7).includes('://'), 'one file:// prefix')
  }
  is('the encoded form decodes back to the path', SL.fileUri('/tmp/a b.png'),
    (v) => decodeURIComponent(v.slice('file://'.length)) === '/tmp/a b.png', 'decodes to the input')
})

group('copyImageCmd is a URI-list offer through a forking wl-copy', () => {
  eq('a plain path', SL.copyImageCmd('/tmp/a.png'), ['sh', '-c', "printf '%s\\n' 'file:///tmp/a.png' | wl-copy --type text/uri-list"])
  eq('a path with a space is quoted', SL.copyImageCmd('/tmp/a b.png')[2], "printf '%s\\n' 'file:///tmp/a%20b.png' | wl-copy --type text/uri-list")
  eq('a quote in the path is escaped for the shell', SL.copyImageCmd("/tmp/it's.png")[2], "printf '%s\\n' 'file:///tmp/it'\\''s.png' | wl-copy --type text/uri-list")
  eq('exactly three argv entries', SL.copyImageCmd('/tmp/a.png').length, 3)
  eq('it runs through sh -c', SL.copyImageCmd('/tmp/a.png').slice(0, 2), ['sh', '-c'])
  contains('the URI type is named', SL.copyImageCmd('/tmp/a.png')[2], '--type text/uri-list')
  contains('printf is used so no trailing newline is lost', SL.copyImageCmd('/tmp/a.png')[2], "printf '%s\\n'")
  // The URI encoder is what neutralises the shell metacharacters: a path
  // segment keeps only the unreserved set, so the quoting is belt and braces
  // rather than the only defence.
  const nasty = SL.copyImageCmd("/tmp/a'b\"c;d`e$f.png")[2]
  contains("a quote in the path is URI-encoded, then shell-quoted", nasty, "'file:///tmp/a'\\''b%22c%3Bd%60e%24f.png'")
  notContains('no raw semicolon reaches the shell', nasty, ';')
  notContains('no raw backtick reaches the shell', nasty, '`')
  notContains('no raw dollar reaches the shell', nasty, '$')
  eq('exactly one pipe separates the stages', nasty.split('|').length - 1, 1)
  eq('an empty path still yields a command', SL.copyImageCmd('').length, 3)
  eq('a null path still yields a command', SL.copyImageCmd(null).length, 3)
})

group('notifyBody produces the two published label strings', () => {
  // The header calls this the bash tool's notify() case list. That bash list
  // is no longer in the tree, so the strings are pinned here as the shell's
  // own contract rather than as a cross-file equality.
  eq('a saved region', SL.notifyBody('region', true), 'Selected region saved to disk')
  eq('an unsaved region', SL.notifyBody('region', false), 'Selected region captured')
  eq('a saved screen', SL.notifyBody('screen', true), 'Active screen saved to disk')
  eq('an unsaved screen', SL.notifyBody('screen', false), 'Active screen captured')
  // Only "region" has its own label; every other mode is the screen one,
  // because the capture tool only offers those two.
  eq('an unknown mode falls back to the screen label', SL.notifyBody('window', true), 'Active screen saved to disk')
  eq('an undefined mode', SL.notifyBody(undefined, true), 'Active screen saved to disk')
  eq('an empty mode', SL.notifyBody('', true), 'Active screen saved to disk')
  // A truthy `saved` is a truthy `saved`, so the settings field drives it
  // directly rather than being compared to true.
  eq('1 saves', SL.notifyBody('region', 1), 'Selected region saved to disk')
  eq('0 captures', SL.notifyBody('region', 0), 'Selected region captured')
  eq('an empty string captures', SL.notifyBody('region', ''), 'Selected region captured')
  eq('an omitted saved flag captures', SL.notifyBody('region'), 'Selected region captured')
  eq('no arguments at all', SL.notifyBody(), 'Active screen captured')
  for (const mode of ['region', 'screen', 'window', '']) {
    for (const saved of [true, false]) {
      is(`notifyBody(${show(mode)}, ${saved}) is one of the two exact strings`,
        SL.notifyBody(mode, saved),
        (v) => v === 'Selected region saved to disk' || v === 'Selected region captured'
          || v === 'Active screen saved to disk' || v === 'Active screen captured',
        'a published label string')
    }
  }
})

// ---------------------------------------------------------------------------
section('AnnotationTools - the shared rect primitives it re-exports')

group('normRect and clampRect are the RectMath functions, not copies', () => {
  eq('normRect', AT.normRect(10, 20, 4, 6), { x: 4, y: 6, w: 6, h: 14 })
  eq('normRect collapses a NaN corner', AT.normRect(NaN, 0, 1, 1), { x: 0, y: 0, w: 0, h: 0 })
  eq('clampRect', AT.clampRect({ x: -20, y: -5, w: 30, h: 20 }, 100, 100), { x: 0, y: 0, w: 10, h: 15 })
  eq('clampViewPoint is the point clamp', AT.clampViewPoint({ x: 50, y: 5 }, { x: 0, y: 0, w: 10, h: 10 }), { x: 10, y: 5 })
  eq('_finite is the RectMath guard', [AT._finite(1), AT._finite('1')], [true, false])
  eq('_zeroRect is the RectMath degenerate rect', AT._zeroRect(), { x: 0, y: 0, w: 0, h: 0 })
  eq('_point needs both coordinates finite', [AT._point({ x: 0, y: 0 }), AT._point({ x: 0 }), AT._point(null), AT._point({ x: '1', y: 0 })], [true, false, false, false])
})

group('mapRectToFrame scales each axis by its own frame/view ratio', () => {
  eq('1:1', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 100, 100, 100, 100), { x: 10, y: 20, w: 30, h: 40 })
  eq('2x on both axes', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 200, 200, 100, 100), { x: 20, y: 40, w: 60, h: 80 })
  eq('a non-uniform ratio keeps the axes independent', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 200, 100, 100, 100), { x: 20, y: 20, w: 60, h: 40 })
  approx('a fractional ratio is not rounded', AT.mapRectToFrame({ x: 0, y: 0, w: 10, h: 10 }, 125, 125, 100, 100).w, 12.5, 1e-12)
  eq('negative coordinates are carried through', AT.mapRectToFrame({ x: -10, y: -10, w: 5, h: 5 }, 100, 100, 100, 100), { x: -10, y: -10, w: 5, h: 5 })
})

group('mapRectToFrame treats a zero ratio as 1 rather than dividing by zero', () => {
  // A frame that has not been sized yet and a view that has not been laid
  // out both read as a 1:1 map, so the first frame after a resize does not
  // throw the selection to the origin.
  eq('a zero-size view', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 200, 200, 0, 0), { x: 10, y: 20, w: 30, h: 40 })
  eq('a zero-size frame', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 0, 0, 100, 100), { x: 10, y: 20, w: 30, h: 40 })
  eq('a negative frame size', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, -100, -100, 100, 100), { x: 10, y: 20, w: 30, h: 40 })
  eq('a NaN view size', AT.mapRectToFrame({ x: 10, y: 20, w: 30, h: 40 }, 200, 200, NaN, NaN), { x: 10, y: 20, w: 30, h: 40 })
  eq('a null rect', AT.mapRectToFrame(null, 100, 100, 100, 100), { x: 0, y: 0, w: 0, h: 0 })
  eq('an undefined rect', AT.mapRectToFrame(undefined, 100, 100, 100, 100), { x: 0, y: 0, w: 0, h: 0 })
  eq('a NaN field folds to 0', AT.mapRectToFrame({ x: NaN, y: 2, w: 3, h: NaN }, 100, 100, 100, 100), { x: 0, y: 2, w: 3, h: 0 })
  eq('no arguments at all', AT.mapRectToFrame(), { x: 0, y: 0, w: 0, h: 0 })
  // A ratio that overflows to Infinity is repaired per field rather than
  // poisoning the whole rect with Infinity.
  eq('an overflowing ratio', AT.mapRectToFrame({ x: 1e308, y: 0, w: 0, h: 0 }, 1e308, 1e308, 1, 1), { x: 0, y: 0, w: 0, h: 0 })
  is('every field is finite for an overflowing ratio', AT.mapRectToFrame({ x: 1e308, y: 1e308, w: 1e308, h: 1e308 }, 1e308, 1e308, 1, 1),
    (v) => Object.values(v).every(Number.isFinite), 'all fields finite')
  eq('a fractional field survives the scale', AT.mapRectToFrame({ x: 0.5, y: 0.5, w: 0.5, h: 0.5 }, 1, 1, 2, 2), { x: 0.25, y: 0.25, w: 0.25, h: 0.25 })
})

// ---------------------------------------------------------------------------
section('AnnotationTools.lockRect - the aspect-locked drag')

group('the dominant axis wins and the anchor quadrant is preserved', () => {
  // Documented: "Corner pair -> aspect-locked rect (w/h == ratio), dominant
  // axis wins, quadrant around the anchor preserved."
  eq('x-dominant grows the height', AT.lockRect(0, 0, 100, 30, 1), { x: 0, y: 0, w: 100, h: 100 })
  eq('y-dominant grows the width', AT.lockRect(0, 0, 10, 100, 1), { x: 0, y: 0, w: 100, h: 100 })
  eq('a 2:1 lock, x-dominant', AT.lockRect(0, 0, 100, 10, 2), { x: 0, y: 0, w: 100, h: 50 })
  // The grown side extends past the pointer, so the rect covers the whole
  // drag rather than stopping at it.
  eq('a 2:1 lock, y-dominant, grows past the pointer', AT.lockRect(0, 0, 10, 100, 2), { x: 0, y: 0, w: 200, h: 100 })
  eq('a 0.5:1 lock, x-dominant', AT.lockRect(0, 0, 100, 1, 0.5), { x: 0, y: 0, w: 100, h: 200 })
  approx('a 16:9 lock', AT.lockRect(0, 0, 160, 90, 16 / 9).h, 90, 1e-9)
  eq('an exact tie is x-dominant', AT.lockRect(0, 0, 10, 10, 1), { x: 0, y: 0, w: 10, h: 10 })
  eq('up-right from the anchor', AT.lockRect(0, 0, 100, 30, 1), { x: 0, y: 0, w: 100, h: 100 })
  eq('up-left from the anchor', AT.lockRect(100, 30, 0, 0, 1), { x: 0, y: -70, w: 100, h: 100 })
  eq('down-right from a top-left anchor', AT.lockRect(0, 0, 30, 100, 1), { x: 0, y: 0, w: 100, h: 100 })
  // The anchor is the first point and never moves; the grown axis extends
  // back from it, so an up-left drag keeps the anchor at the far corner.
  eq('up-left from a bottom-right anchor', AT.lockRect(100, 100, 20, 80, 1), { x: 20, y: 20, w: 80, h: 80 })
  eq('a negative-quadrant anchor keeps its side', AT.lockRect(-100, 0, -90, 5, 1), { x: -100, y: 0, w: 10, h: 10 })
})

group('a non-positive ratio disables the lock and falls back to normRect', () => {
  eq('ratio 0', AT.lockRect(10, 20, 4, 6, 0), { x: 4, y: 6, w: 6, h: 14 })
  eq('a negative ratio', AT.lockRect(10, 20, 4, 6, -1), { x: 4, y: 6, w: 6, h: 14 })
  eq('an undefined ratio', AT.lockRect(10, 20, 4, 6, undefined), { x: 4, y: 6, w: 6, h: 14 })
  eq('a NaN ratio', AT.lockRect(10, 20, 4, 6, NaN), { x: 4, y: 6, w: 6, h: 14 })
  // The guard is _finite(ratio) && ratio > 0, not ratio > 0 alone, so an
  // Infinity ratio is "no ratio" rather than an infinitely locked one.
  eq('an Infinity ratio is no ratio', AT.lockRect(0, 0, 10, 10, Infinity), AT.normRect(0, 0, 10, 10))
  eq('a numeric string ratio is not a ratio', AT.lockRect(10, 20, 4, 6, '2'), { x: 4, y: 6, w: 6, h: 14 })
  eq('no ratio at all', AT.lockRect(10, 20, 4, 6), { x: 4, y: 6, w: 6, h: 14 })
  eq('the disabled lock is exactly normRect', AT.lockRect(0, 0, 100, 30, 0), AT.normRect(0, 0, 100, 30))
})

group('a non-finite corner collapses to the origin, as normRect does', () => {
  eq('NaN x1', AT.lockRect(NaN, 0, 10, 10, 1), { x: 0, y: 0, w: 0, h: 0 })
  eq('NaN y2', AT.lockRect(0, 0, 10, NaN, 1), { x: 0, y: 0, w: 0, h: 0 })
  eq('undefined', AT.lockRect(undefined, undefined, 1, 1, 1), { x: 0, y: 0, w: 0, h: 0 })
  eq('a null corner', AT.lockRect(null, 0, 1, 1, 1), { x: 0, y: 0, w: 0, h: 0 })
  eq('a zero-length drag with the lock on', AT.lockRect(5, 5, 5, 5, 1), { x: 5, y: 5, w: 0, h: 0 })
  eq('a zero-length drag with the lock off', AT.lockRect(5, 5, 5, 5, 0), { x: 5, y: 5, w: 0, h: 0 })
  noThrow('all four nullish', () => AT.lockRect(null, null, null, null, 1))
  for (const [x1, y1, x2, y2, r] of [[0, 0, 100, 30, 1], [0, 0, 10, 100, 2], [100, 30, 0, 0, 1], [-50, 20, -10, 40, 0.5]]) {
    const v = AT.lockRect(x1, y1, x2, y2, r)
    is(`w/h == ${r} and w >= 0 for ${show([x1, y1, x2, y2, r])}`, v,
      (o) => o.w >= 0 && o.h >= 0 && Math.abs(o.w / o.h - r) < 1e-9, 'aspect ratio held')
  }
})

// ---------------------------------------------------------------------------
section('AnnotationTools.fitScale / boardGeom - the shared fit policy')

group('fitScale contains the document in the stage', () => {
  eq('wide document, wide stage', AT.fitScale(400, 400, 100, 100, 0), 4)
  eq('the tighter axis decides', AT.fitScale(200, 100, 400, 200, 0), 0.5)
  eq('portrait', AT.fitScale(200, 400, 100, 200, 0), 2)
  eq('an exact fit', AT.fitScale(200, 100, 400, 200, 0), 0.5)
  eq('a fractional stage', AT.fitScale(1000, 1000, 300, 300, 0), 10 / 3)
})

group('the short-axis floor overflows the stage rather than shrinking further', () => {
  // Documented in the caller: below this the short axis of an
  // extreme-aspect capture is too thin to click or draw on.
  eq('the floor wins over a smaller fit', AT.fitScale(200, 100, 1000, 1000, 200), 0.2)
  eq('the fit wins when it is larger', AT.fitScale(200, 100, 100, 100, 5), 1)
  eq('a 0 floor is no floor', AT.fitScale(200, 100, 1000, 1000, 0), 0.1)
  eq('a negative floor is no floor', AT.fitScale(200, 100, 1000, 1000, -10), 0.1)
  eq('a NaN floor is no floor', AT.fitScale(200, 100, 1000, 1000, NaN), 0.1)
  eq('an undefined floor is no floor', AT.fitScale(200, 100, 1000, 1000, undefined), 0.1)
  // The floor is expressed over the *short* axis, so a tall document is
  // protected by its height rather than its width.
  eq('the floor uses the short axis', AT.fitScale(100, 200, 1000, 100, 50), 0.5)
  eq('the same floor on a wide document', AT.fitScale(100, 200, 1000, 100, 50), 0.5)
  eq('a floor over the short axis of a portrait document', AT.fitScale(100, 200, 100, 1000, 50), 0.5)
})

group('a stage that is not laid out yet yields 0, not 1', () => {
  // fitScale has no stage floor: 0 is a real answer and boardGeom is the
  // place that turns a non-positive fit back into 1.
  eq('a zero stage', AT.fitScale(0, 0, 100, 100, 0), 0)
  eq('a negative stage', AT.fitScale(-100, 100, 100, 100, 0), 0)
  eq('a non-finite stage', AT.fitScale(NaN, NaN, 100, 100, 0), 0)
  // String stages are not coordinates, so they read as 0 - unlike scaleRect.
  eq('a numeric string stage', AT.fitScale('200', '100', 400, 200, 0), 0)
  eq('a document with no width is a no-op scale', AT.fitScale(200, 100, 0, 200, 0), 1)
  eq('a document with no height is a no-op scale', AT.fitScale(200, 100, 400, 0, 0), 1)
  eq('a zero document is a no-op scale', AT.fitScale(200, 100, 0, 0, 0), 1)
  eq('a negative document is a no-op scale', AT.fitScale(200, 100, -10, 200, 0), 1)
  eq('a NaN document is a no-op scale', AT.fitScale(200, 100, NaN, 200, 0), 1)
  eq('no arguments at all', AT.fitScale(), 1)
  eq('the result is never NaN for any shape', AT.fitScale(NaN, NaN, NaN, NaN, NaN), 1)
  noThrow('an object stage', () => AT.fitScale({}, {}, 100, 100, 0))
  for (const [sw, sh, dw, dh, m] of [
    [200, 100, 400, 200, 0], [0, 0, 100, 100, 0], [200, 100, 1000, 1000, 200],
    [100, 200, 1000, 100, 50], [NaN, 100, 100, 100, 0],
  ]) {
    is(`finite for stage ${sw}x${sh} doc ${dw}x${dh} floor ${m}`, AT.fitScale(sw, sh, dw, dh, m),
      (v) => Number.isFinite(v) && v >= 0, 'finite and non-negative')
  }
})

group('boardGeom centres the fitted board in the stage and applies the pan', () => {
  // {x: (stageW - w)/2 + panX, y: (stageH - h)/2 + panY, w, h, fit}
  eq('centred', AT.boardGeom(400, 200, 100, 50, 0.5, 1, { x: 0, y: 0 }), { x: 175, y: 87.5, w: 50, h: 25, fit: 0.5 })
  eq('a zoom of 2 doubles the board', AT.boardGeom(400, 200, 100, 50, 0.5, 2, { x: 0, y: 0 }), { x: 150, y: 75, w: 100, h: 50, fit: 0.5 })
  eq('a pan offsets the origin', AT.boardGeom(400, 200, 100, 50, 0.5, 1, { x: 10, y: -5 }), { x: 185, y: 82.5, w: 50, h: 25, fit: 0.5 })
  eq('no pan object', AT.boardGeom(400, 200, 100, 50, 0.5, 1, null), { x: 175, y: 87.5, w: 50, h: 25, fit: 0.5 })
  eq('an undefined pan', AT.boardGeom(400, 200, 100, 50, 0.5, 1, undefined), { x: 175, y: 87.5, w: 50, h: 25, fit: 0.5 })
  eq('a partial pan folds the bad axis to 0', AT.boardGeom(400, 200, 100, 50, 0.5, 1, { x: NaN, y: 3 }), { x: 175, y: 90.5, w: 50, h: 25, fit: 0.5 })
  eq('the fit is echoed back for the mapping fallbacks', AT.boardGeom(400, 200, 100, 50, 0.25, 1, null).fit, 0.25)
  for (const [sw, sh, dw, dh, k, z] of [[400, 200, 100, 50, 0.5, 1], [400, 200, 100, 50, 0.5, 3], [100, 100, 640, 480, 0.1, 1]]) {
    const g = AT.boardGeom(sw, sh, dw, dh, k, z, null)
    approx(`x is centred for ${sw}x${sh} doc ${dw}x${dh} k ${k} z ${z}`, g.x, (sw - g.w) / 2, 1e-9)
    approx(`y is centred for ${sw}x${sh} doc ${dw}x${dh} k ${k} z ${z}`, g.y, (sh - g.h) / 2, 1e-9)
  }
})

group('boardGeom floors the board at 1px and the fit at 1', () => {
  eq('a zero document is a 1x1 board', AT.boardGeom(400, 200, 0, 0, 0.5, 1, null), { x: 199.5, y: 99.5, w: 1, h: 1, fit: 0.5 })
  eq('a zoom of 0 is a 1x1 board', AT.boardGeom(400, 200, 100, 50, 0.5, 0, null), { x: 199.5, y: 99.5, w: 1, h: 1, fit: 0.5 })
  eq('a fit of 0 becomes 1', AT.boardGeom(400, 200, 100, 50, 0, 1, null), { x: 150, y: 75, w: 100, h: 50, fit: 1 })
  eq('a negative fit becomes 1', AT.boardGeom(400, 200, 100, 50, -2, 1, null).fit, 1)
  eq('a NaN fit becomes 1', AT.boardGeom(400, 200, 100, 50, NaN, 1, null).fit, 1)
  eq('an undefined fit becomes 1', AT.boardGeom(400, 200, 100, 50, undefined, 1, null).fit, 1)
  eq('a NaN zoom becomes 1', AT.boardGeom(400, 200, 100, 50, 0.5, NaN, null), { x: 175, y: 87.5, w: 50, h: 25, fit: 0.5 })
  eq('a zero document width is a 1px-wide board', AT.boardGeom(400, 200, NaN, 50, 0.5, 1, null), { x: 199.5, y: 87.5, w: 1, h: 25, fit: 0.5 })
  eq('a zero document height is a 1px-tall board', AT.boardGeom(400, 200, 100, 0, 0.5, 1, null), { x: 175, y: 99.5, w: 50, h: 1, fit: 0.5 })
  eq('a stage that is not laid out gives a negative origin', AT.boardGeom(NaN, 200, 100, 50, 0.5, 1, null), { x: -25, y: 87.5, w: 50, h: 25, fit: 0.5 })
  // An overflowing board would put the whole mapping into Infinity, so the
  // 1x1 fallback is returned instead.
  eq('an overflowing board', AT.boardGeom(400, 200, 1e308, 1e308, 1e308, 1e308, null), { x: 0, y: 0, w: 1, h: 1, fit: 1e308 })
  // A collapsed stage centres a 1x1 board on a 0x0 stage, which is a negative
  // half-extent: the board origin is the first pixel the item would draw.
  eq('no arguments at all', AT.boardGeom(), { x: -0.5, y: -0.5, w: 1, h: 1, fit: 1 })
  for (const args of [[400, 200, 100, 50, 0.5, 1], [0, 0, 0, 0, 0, 0], [NaN, NaN, 1e308, 1e308, Infinity, Infinity]]) {
    const g = AT.boardGeom(...args, null)
    is(`finite for ${show(args)}`, g, (v) => Object.values(v).every(Number.isFinite) && v.w >= 1 && v.h >= 1, 'finite, w/h >= 1')
  }
  eq('the return shape carries fit', Object.keys(AT.boardGeom(10, 10, 10, 10, 1, 1, null)), ['x', 'y', 'w', 'h', 'fit'])
})

// ---------------------------------------------------------------------------
section('AnnotationTools.displayToDoc / docToDisplay - the point mapping pair')

group('displayToDoc inverts the board placement into document pixels', () => {
  const geom = { x: 0, y: 0, w: 100, h: 100, fit: 1 }
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('the centre maps to the centre', AT.displayToDoc(50, 50, geom, vr, 0), { x: 50, y: 50 })
  eq('the origin maps to the origin', AT.displayToDoc(0, 0, geom, vr, 0), { x: 0, y: 0 })
  eq('a pan in geom moves the mapping', AT.displayToDoc(10, 10, { x: 5, y: 5, w: 100, h: 100, fit: 1 }, vr, 0), { x: 5, y: 5 })
  // k comes from geom.w/dw, not from geom.fit, when the geom has a size.
  eq('k is taken from the board size', AT.displayToDoc(100, 50, { x: 0, y: 0, w: 100, h: 50, fit: 1 }, { x: 0, y: 0, w: 50, h: 25 }, 0), { x: 50, y: 25 })
  eq('a zero-size view falls back to 1x1 at the origin', AT.displayToDoc(50, 50, geom, { x: 0, y: 0, w: 0, h: 0 }, 0), { x: 0.5, y: 0.5 })
  eq('a null view', AT.displayToDoc(50, 50, geom, null, 0), { x: 0.5, y: 0.5 })
  eq('a null geom is a zero-offset 1x1 board', AT.displayToDoc(50, 50, null, vr, 0), { x: 50, y: 50 })
})

group('displayToDoc clamps into the view rect, and the bound is inclusive', () => {
  const geom = { x: 0, y: 0, w: 100, h: 100, fit: 1 }
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('far outside', AT.displayToDoc(-50, 500, geom, vr, 0), { x: 0, y: 100 })
  eq('the far corner is reachable', AT.displayToDoc(100, 100, geom, vr, 0), { x: 100, y: 100 })
  eq('a negative geom offset clamps into the view', AT.displayToDoc(-100, -100, { x: -50, y: -50, w: 100, h: 100, fit: 1 }, vr, 0), { x: 0, y: 0 })
  // A non-finite pointer reads as 0 rather than NaN, so a stray event cannot
  // poison the stroke that follows it.
  eq('a NaN pointer coordinate reads as 0', AT.displayToDoc(NaN, NaN, geom, vr, 0), { x: 0, y: 0 })
  // An infinite coordinate is not finite either, so it takes the same fold
  // rather than reaching the far edge of the view.
  eq('an infinite pointer also reads as 0', AT.displayToDoc(Infinity, -Infinity, geom, vr, 0), { x: 0, y: 0 })
  eq('a non-finite rotation reads as 0', AT.displayToDoc(50, 50, geom, vr, NaN), { x: 50, y: 50 })
  eq('an undefined rotation reads as 0', AT.displayToDoc(50, 50, geom, vr, undefined), { x: 50, y: 50 })
  eq('the view origin shifts the clamped bounds', AT.displayToDoc(-100, -100, geom, { x: 50, y: 50, w: 10, h: 10 }, 0), { x: 50, y: 50 })
  for (const [mx, my] of [[-1e9, -1e9], [1e9, 1e9], [0, 0], [50, 50], [100, 100], [37, 61]]) {
    const d = AT.displayToDoc(mx, my, geom, vr, 0)
    is(`inside the view for (${mx}, ${my})`, d, (v) => v.x >= 0 && v.x <= 100 && v.y >= 0 && v.y <= 100, 'within the view rect')
  }
  noThrow('no geometry at all', () => AT.displayToDoc(0, 0, null, null, null))
  noThrow('a string pointer', () => AT.displayToDoc('5', '5', geom, vr, 0))
})

group('a quarter turn rotates the mapping inside the board', () => {
  // The view rect is the unrotated image and the geom box is its ROTATED
  // bounding box - the editor sizes the board from the same rotating-rect
  // formula, so at 90 degrees a 50x100 image is displayed in a 100x50 board
  // and the display point lives in that 100x50 space. The display corners
  // then land on image corners.
  const img = { x: 0, y: 0, w: 50, h: 100 }
  const bbox = { x: 0, y: 0, w: 100, h: 50, fit: 1 }
  const land = { x: 0, y: 0, w: 100, h: 50, fit: 1 }
  eq('0 degrees, top-left', AT.displayToDoc(0, 0, land, { x: 0, y: 0, w: 100, h: 50 }, 0), { x: 0, y: 0 })
  eq('0 degrees, bottom-right', AT.displayToDoc(100, 50, land, { x: 0, y: 0, w: 100, h: 50 }, 0), { x: 100, y: 50 })
  eq('180 degrees mirrors both axes', AT.displayToDoc(0, 0, land, { x: 0, y: 0, w: 100, h: 50 }, 180), { x: 100, y: 50 })
  eq('180 degrees, the other corner', AT.displayToDoc(100, 50, land, { x: 0, y: 0, w: 100, h: 50 }, 180), { x: 0, y: 0 })
  eq('90 degrees, the display top-left is the image bottom-left', AT.displayToDoc(0, 0, bbox, img, 90), { x: 0, y: 100 })
  eq('90 degrees, the display top-right is the image top-left', AT.displayToDoc(100, 0, bbox, img, 90), { x: 0, y: 0 })
  eq('90 degrees, the display bottom-left is the image bottom-right', AT.displayToDoc(0, 50, bbox, img, 90), { x: 50, y: 100 })
  eq('90 degrees, the display bottom-right is the image top-right', AT.displayToDoc(100, 50, bbox, img, 90), { x: 50, y: 0 })
  eq('270 degrees, the display top-left is the image top-right', AT.displayToDoc(0, 0, bbox, img, 270), { x: 50, y: 0 })
  eq('270 degrees, the display bottom-left is the image top-left', AT.displayToDoc(0, 50, bbox, img, 270), { x: 0, y: 0 })
  eq('270 degrees, the display bottom-right is the image bottom-left', AT.displayToDoc(100, 50, bbox, img, 270), { x: 0, y: 100 })
  approx('90 degrees, a point on the display right edge', AT.displayToDoc(100, 25, bbox, img, 90).x, 25, 1e-9)
  approx('90 degrees, a point on the display right edge, y', AT.displayToDoc(100, 25, bbox, img, 90).y, 0, 1e-9)
  approx('270 degrees, a point below the display', AT.displayToDoc(10, 70, bbox, img, 270).x, 0, 1e-9)
  approx('270 degrees, a point below the display, y', AT.displayToDoc(10, 70, bbox, img, 270).y, 10, 1e-9)
  // The centre of the board is the one point every rotation agrees on, and
  // it lands on the centre of the image.
  for (const [rot, vr, geom, cx, cy] of [
    [0, { x: 0, y: 0, w: 100, h: 50 }, land, 50, 25],
    [180, { x: 0, y: 0, w: 100, h: 50 }, land, 50, 25],
    [90, img, bbox, 25, 50],
    [270, img, bbox, 25, 50],
  ]) {
    const c = AT.displayToDoc(geom.w / 2, geom.h / 2, geom, vr, rot)
    approx(`the centre maps to the image centre at ${rot} degrees`, c.x, cx, 1e-9)
    approx(`the centre maps to the image centre at ${rot} degrees, y`, c.y, cy, 1e-9)
  }
  // An in-between angle is a real rotation, so the display's corners no
  // longer land on image corners.
  const sq = { x: 0, y: 0, w: 100, h: 100, fit: 1 }
  const v45 = { x: 0, y: 0, w: 100, h: 100 }
  approx('45 degrees moves the display top-right to the image top edge', AT.displayToDoc(100, 0, sq, v45, 45).x, 50, 1e-9)
  approx('45 degrees, y', AT.displayToDoc(100, 0, sq, v45, 45).y, 0, 1e-9)
  approx('45 degrees maps the display bottom-left to the image bottom edge', AT.displayToDoc(0, 100, sq, v45, 45).y, 100, 1e-9)
  eq('45 degrees still maps the centre to the centre', AT.displayToDoc(50, 50, sq, v45, 45), { x: 50, y: 50 })
})

group('docToDisplay is the inverse and does not clamp', () => {
  const geom = { x: 0, y: 0, w: 100, h: 100, fit: 1 }
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('the centre', AT.docToDisplay({ x: 50, y: 50 }, geom, vr, 0), { x: 50, y: 50 })
  eq('the top-left corner', AT.docToDisplay({ x: 0, y: 0 }, geom, vr, 0), { x: 0, y: 0 })
  eq('the bottom-right corner', AT.docToDisplay({ x: 100, y: 100 }, geom, vr, 0), { x: 100, y: 100 })
  // Clamping is the caller of displayToDoc's job on the way in; the inverse
  // has to be able to draw a handle outside the view.
  eq('a point outside the view is not clamped', AT.docToDisplay({ x: 500, y: -20 }, geom, vr, 0), { x: 500, y: -20 })
  eq('a rotated point', AT.docToDisplay({ x: 100, y: 50 }, geom, { x: 0, y: 0, w: 200, h: 100 }, 90).x, 25.000000000000004)
  approx('a rotated point, y', AT.docToDisplay({ x: 100, y: 50 }, geom, { x: 0, y: 0, w: 200, h: 100 }, 90).y, 50, 1e-9)
  eq('a null point reads as the origin', AT.docToDisplay(null, geom, vr, 0), { x: 0, y: 0 })
  eq('an undefined point', AT.docToDisplay(undefined, geom, vr, 0), { x: 0, y: 0 })
  eq('a partial point is not a point', AT.docToDisplay({ x: 1 }, geom, vr, 0), { x: 0, y: 0 })
  eq('a NaN point', AT.docToDisplay({ x: NaN, y: 0 }, geom, vr, 0), { x: 0, y: 0 })
  eq('no arguments at all', AT.docToDisplay(), { x: 0, y: 0 })
})

group('the two are inverses of each other at every quarter turn', () => {
  // The invariant the overlay depends on: an image point reached through
  // displayToDoc comes back to the same display pixel. The geom box has to
  // be the rotated bounding box, otherwise the board is letterboxed inside
  // its own rotated footprint and the round trip has nothing to be an
  // identity on.
  const land = { x: 0, y: 0, w: 100, h: 50, fit: 1 }
  const img = { x: 0, y: 0, w: 50, h: 100 }
  const bbox = { x: 0, y: 0, w: 100, h: 50, fit: 1 }
  for (const [rot, vr, geom, pts] of [
    [0, { x: 0, y: 0, w: 100, h: 50 }, land, [[0, 0], [50, 25], [100, 50], [37, 45]]],
    [180, { x: 0, y: 0, w: 100, h: 50 }, land, [[0, 0], [50, 25], [100, 50], [37, 45]]],
    [90, img, bbox, [[0, 0], [50, 25], [100, 50], [10, 40]]],
    [270, img, bbox, [[0, 0], [50, 25], [100, 50], [10, 40]]],
  ]) {
    for (const [mx, my] of pts) {
      const d = AT.displayToDoc(mx, my, geom, vr, rot)
      const back = AT.docToDisplay(d, geom, vr, rot)
      approx(`rot ${rot}: (${mx}, ${my}) comes back`, back.x, mx, 1e-9)
      approx(`rot ${rot}: (${mx}, ${my}) comes back, y`, back.y, my, 1e-9)
    }
  }
  const sq = { x: 0, y: 0, w: 100, h: 100, fit: 1 }
  const vsq = { x: 0, y: 0, w: 100, h: 100 }
  for (const [x, y] of [[0, 0], [25, 75], [50, 50], [100, 100]]) {
    const s = AT.docToDisplay({ x, y }, sq, vsq, 0)
    const back = AT.displayToDoc(s.x, s.y, sq, vsq, 0)
    approx(`(${x}, ${y}) survives a display->doc->display round trip`, back.x, x, 1e-9)
    approx(`(${x}, ${y}) survives the round trip, y`, back.y, y, 1e-9)
  }
  // displayToDoc is the clamping half of the pair, so a pointer outside the
  // image does not come back: it is pinned to the image's far edge first.
  const clamped = AT.displayToDoc(1e6, -1e6, sq, vsq, 0)
  is('a far-outside pointer clamps rather than round-trips', clamped, (v) => v.x === 100 && v.y === 0, 'x=100 y=0')
  eq('and the clamped point maps back to the image corner', AT.docToDisplay(clamped, sq, vsq, 0), { x: 100, y: 0 })
  // A letterboxed board is the case where the two diverge: the image corner
  // is off the board, so the mapping clamps into the image and the round trip
  // cannot hold. Pinned because it is the shape a panned board makes.
  const box = { x: 10, y: 20, w: 200, h: 100, fit: 2 }
  const small = { x: 0, y: 0, w: 100, h: 50 }
  eq('an off-board image corner clamps to the image origin', AT.displayToDoc(0, 0, box, small, 0), { x: 0, y: 0 })
  eq('and does not round-trip', AT.docToDisplay({ x: 0, y: 0 }, box, small, 0), { x: 10, y: 20 })
})

// ---------------------------------------------------------------------------
section('AnnotationTools - segment distance and hit geometry')

group('pointToSegmentDist is the clamped projection distance', () => {
  eq('on the segment', AT.pointToSegmentDist(5, 0, 0, 0, 10, 0), 0)
  eq('perpendicular off a horizontal segment', AT.pointToSegmentDist(5, 5, 0, 0, 10, 0), 5)
  eq('past the far end clamps to the endpoint', AT.pointToSegmentDist(20, 0, 0, 0, 10, 0), 10)
  eq('before the near end clamps to the endpoint', AT.pointToSegmentDist(-5, 0, 0, 0, 10, 0), 5)
  eq('a vertical segment', AT.pointToSegmentDist(0, 5, 0, 0, 0, 10), 0)
  eq('on a diagonal', AT.pointToSegmentDist(5, 5, 0, 0, 10, 10), 0)
  approx('off a diagonal', AT.pointToSegmentDist(5, 0, 0, 0, 10, 10), Math.sqrt(12.5), 1e-12)
  // A degenerate segment has no direction, so the distance is the point
  // distance - which is what makes a single-point brush hittable.
  eq('a degenerate segment', AT.pointToSegmentDist(5, 0, 0, 0, 0, 0), 5)
  eq('on a degenerate segment', AT.pointToSegmentDist(0, 0, 0, 0, 0, 0), 0)
  eq('_segDist2 is the squared form', AT._segDist2(5, 5, 0, 0, 10, 0), 25)
  eq('_segDist2 of zero', AT._segDist2(5, 0, 0, 0, 10, 0), 0)
})

group('a non-finite coordinate makes the distance unusable, not zero', () => {
  eq('a NaN point', AT._segDist2(NaN, 0, 0, 0, 10, 0), Infinity)
  eq('a NaN endpoint', AT._segDist2(5, 0, 0, 0, NaN, 0), Infinity)
  eq('an Infinity coordinate', AT._segDist2(Infinity, 0, 0, 0, 10, 0), Infinity)
  eq('the sqrt of that is still Infinity', AT.pointToSegmentDist(NaN, 0, 0, 0, 10, 0), Infinity)
  eq('so nothing within a tolerance matches it', AT.pointToSegmentDist(NaN, 0, 0, 0, 10, 0) <= 1e9, false)
  noThrow('a string coordinate', () => AT.pointToSegmentDist('1', 0, 0, 0, 10, 0))
  noThrow('no arguments at all', () => AT.pointToSegmentDist())
})

group('elbowMid turns at the dominant drag axis', () => {
  eq('x-dominant: the corner sits under the end point', AT.elbowMid({ x: 0, y: 0 }, { x: 100, y: 20 }), { x: 100, y: 0 })
  eq('y-dominant: the corner sits beside the start point', AT.elbowMid({ x: 0, y: 0 }, { x: 20, y: 100 }), { x: 0, y: 100 })
  // The tie goes to the x branch, so an exactly 45 degree drag bends
  // horizontally and the shape never depends on rounding.
  eq('an exact tie is x-dominant', AT.elbowMid({ x: 0, y: 0 }, { x: 10, y: 10 }), { x: 10, y: 0 })
  eq('an exact tie with negative deltas', AT.elbowMid({ x: 0, y: 0 }, { x: -10, y: -10 }), { x: -10, y: 0 })
  eq('a backwards x-dominant drag', AT.elbowMid({ x: 100, y: 0 }, { x: 0, y: 20 }), { x: 0, y: 0 })
  eq('a backwards y-dominant drag', AT.elbowMid({ x: 0, y: 100 }, { x: 20, y: 0 }), { x: 0, y: 0 })
  eq('the same point is its own elbow', AT.elbowMid({ x: 5, y: 5 }, { x: 5, y: 5 }), { x: 5, y: 5 })
  eq('a null endpoint', AT.elbowMid(null, { x: 1, y: 1 }), { x: 0, y: 0 })
  eq('a partial endpoint is not a point', AT.elbowMid({ x: 1 }, { x: 1, y: 1 }), { x: 0, y: 0 })
  eq('both null', AT.elbowMid(null, null), { x: 0, y: 0 })
  eq('a NaN coordinate is not a point', AT.elbowMid({ x: NaN, y: 0 }, { x: 1, y: 1 }), { x: 0, y: 0 })
  eq('no arguments at all', AT.elbowMid(), { x: 0, y: 0 })
  noThrow('a string coordinate', () => AT.elbowMid({ x: '1', y: 0 }, { x: 1, y: 1 }))
})

group('arrowHead splays two lines at 25 degrees from the shaft', () => {
  const head = AT.arrowHead(0, 0, 100, 0, 10)
  eq('two endpoints', head.length, 2)
  // The angle is measured from the shaft, so both lines sit 10 * cos(25)
  // behind the tip and 10 * sin(25) to either side.
  approx('x is the tip minus the projection', head[0].x, 100 - 10 * Math.cos(25 * Math.PI / 180), 1e-9)
  approx('the first line splays up', head[0].y, 10 * Math.sin(25 * Math.PI / 180), 1e-9)
  approx('the second line splays down', head[1].y, -10 * Math.sin(25 * Math.PI / 180), 1e-9)
  approx('both lines share the x', head[1].x, head[0].x, 1e-12)
  eq('the spread is symmetric', head[0].y, -head[1].y)
  const down = AT.arrowHead(0, 0, 0, 100, 10)
  approx('a downward arrow splays left', down[0].x, -10 * Math.sin(25 * Math.PI / 180), 1e-9)
  approx('a downward arrow points back up the shaft', down[0].y, 100 - 10 * Math.cos(25 * Math.PI / 180), 1e-9)
  // A zero head length collapses the head onto the tip. The editor derives
  // headLen as max(14 * scale, width * 5), so this is the degenerate-input
  // answer rather than a live path - pinned so the fallback is visible.
  eq('a head length of 0 sits on the tip', AT.arrowHead(0, 0, 100, 0, 0), [{ x: 100, y: 0 }, { x: 100, y: 0 }])
  eq('an undefined head length sits on the tip', AT.arrowHead(0, 0, 100, 0, undefined), [{ x: 100, y: 0 }, { x: 100, y: 0 }])
  eq('a NaN head length sits on the tip', AT.arrowHead(0, 0, 100, 0, NaN), [{ x: 100, y: 0 }, { x: 100, y: 0 }])
  eq('a non-finite coordinate gives two origins', AT.arrowHead(NaN, 0, 100, 0, 10), [{ x: 0, y: 0 }, { x: 0, y: 0 }])
  eq('a non-finite end gives two origins', AT.arrowHead(0, 0, Infinity, 0, 10), [{ x: 0, y: 0 }, { x: 0, y: 0 }])
  // A zero-length shaft has no direction, and atan2(0, 0) is 0, so the head
  // still splays around the +x axis. Pinned because a zero-length arrow is
  // what a click without a drag produces.
  approx('a zero-length shaft points along +x', AT.arrowHead(5, 5, 5, 5, 10)[0].x, 5 - 10 * Math.cos(25 * Math.PI / 180), 1e-9)
  eq('and both lines are still distinct', AT.arrowHead(5, 5, 5, 5, 10)[0].y, 10 * Math.sin(25 * Math.PI / 180) + 5)
  eq('no arguments at all', AT.arrowHead(), [{ x: 0, y: 0 }, { x: 0, y: 0 }])
  is('every head point is finite for a real shaft', AT.arrowHead(0, 0, 100, 40, 12),
    (v) => v.every((p) => Number.isFinite(p.x) && Number.isFinite(p.y)), 'finite points')
})

// ---------------------------------------------------------------------------
section('AnnotationTools.hitStroke - the eraser hit test')

group('a brush hit test covers the stroke plus half its width', () => {
  const line = { tool: 'brush', width: 4, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }
  eq('on the line', AT.hitStroke(line, 5, 0, 0), true)
  eq('inside the half-width', AT.hitStroke(line, 5, 1.9, 0), true)
  eq('exactly the half-width', AT.hitStroke(line, 5, 2, 0), true)
  eq('just outside the half-width', AT.hitStroke(line, 5, 2.1, 0), false)
  eq('a tolerance widens it', AT.hitStroke(line, 5, 5, 3), true)
  eq('a tolerance that is still too small', AT.hitStroke(line, 5, 5.1, 3), false)
  // An absent or non-positive width reads as the 3px default, so a stroke
  // saved before widths existed is still erasable.
  eq('the default width is 3', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 1.4, 0), true)
  eq('just outside the default width', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 1.6, 0), false)
  eq('a zero width is the default', AT.hitStroke({ tool: 'brush', width: 0, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 1.4, 0), true)
  eq('a negative width is the default', AT.hitStroke({ tool: 'brush', width: -4, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 1.4, 0), true)
  eq('a NaN width is the default', AT.hitStroke({ tool: 'brush', width: NaN, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 1.4, 0), true)
})

group('every segment of a polyline is tested', () => {
  const poly = { tool: 'brush', width: 2, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }] }
  eq('the first segment', AT.hitStroke(poly, 5, 0, 0), true)
  eq('the corner', AT.hitStroke(poly, 10, 0, 0), true)
  eq('the second segment', AT.hitStroke(poly, 10, 5, 0), true)
  eq('inside the corner, away from both', AT.hitStroke(poly, 7, 3, 0), false)
  eq('a three-point V', AT.hitStroke({ tool: 'arrow', width: 2, points: [{ x: 0, y: 0 }, { x: 50, y: 50 }, { x: 100, y: 0 }] }, 50, 50, 0), true)
  eq('an unknown tool falls through to the polyline test', AT.hitStroke({ tool: 'mystery', points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 0, 0), true)
  eq('no tool at all', AT.hitStroke({ points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }, 5, 0, 0), true)
})

group('a one-point stroke is a dot, and it uses the same half-width', () => {
  eq('on the dot', AT.hitStroke({ tool: 'brush', points: [{ x: 5, y: 5 }] }, 5, 5, 0), true)
  eq('inside the default half-width', AT.hitStroke({ tool: 'brush', points: [{ x: 5, y: 5 }] }, 5, 6, 0), true)
  eq('just outside the default half-width', AT.hitStroke({ tool: 'brush', points: [{ x: 5, y: 5 }] }, 5, 7, 0), false)
  eq('inside a width-4 half-width', AT.hitStroke({ tool: 'brush', width: 4, points: [{ x: 5, y: 5 }] }, 5, 6.9, 0), true)
  eq('just outside a width-4 half-width', AT.hitStroke({ tool: 'brush', width: 4, points: [{ x: 5, y: 5 }] }, 5, 7.1, 0), false)
})

group('a rect hit test is outline proximity, not containment', () => {
  // Documented: "rect/ellipse test outline proximity". The interior of a
  // box is deliberately not a hit, so a filled-looking rect is erased by its
  // edge like every other stroke.
  const rect = { tool: 'rect', points: [{ x: 10, y: 10 }, { x: 30, y: 40 }] }
  eq('on the top edge', AT.hitStroke(rect, 20, 10, 0), true)
  eq('on the bottom edge', AT.hitStroke(rect, 20, 40, 0), true)
  eq('on the left edge', AT.hitStroke(rect, 10, 25, 0), true)
  eq('on the right edge', AT.hitStroke(rect, 30, 25, 0), true)
  eq('exactly the top-left corner', AT.hitStroke(rect, 10, 10, 0), true)
  eq('exactly the bottom-right corner', AT.hitStroke(rect, 30, 40, 0), true)
  eq('the interior is not a hit', AT.hitStroke(rect, 20, 20, 0), false)
  eq('the interior is not a hit even with a tolerance', AT.hitStroke(rect, 20, 20, 5), false)
  eq('a tolerance reaches off the edge', AT.hitStroke(rect, 20, 12, 2), true)
  eq('just past the tolerance', AT.hitStroke(rect, 20, 12.1, 2), false)
  eq('a corner distance counts for the tolerance', AT.hitStroke(rect, 9, 10, 1), true)
  eq('just past the corner tolerance', AT.hitStroke(rect, 8.9, 10, 1), false)
  eq('the corner order does not matter', AT.hitStroke({ tool: 'rect', points: [{ x: 30, y: 40 }, { x: 10, y: 10 }] }, 20, 10, 0), true)
  // A rect needs two corners: one point is a dot, not a box.
  eq('one point is not a rect', AT.hitStroke({ tool: 'rect', points: [{ x: 10, y: 10 }] }, 10, 10, 0), false)
  // A zero-size rect degenerates to a point, which is still hittable.
  eq('a zero-size rect is hittable at its corner', AT.hitStroke({ tool: 'rect', points: [{ x: 10, y: 10 }, { x: 10, y: 10 }] }, 10, 10, 0), true)
  eq('a zero-size rect is not hittable beside it', AT.hitStroke({ tool: 'rect', points: [{ x: 10, y: 10 }, { x: 10, y: 10 }] }, 10, 11, 0), false)
})

group('an ellipse hit test is proximity to the curve, not containment', () => {
  const ell = { tool: 'ellipse', points: [{ x: 0, y: 0 }, { x: 100, y: 50 }] }
  eq('the top of the curve', AT.hitStroke(ell, 50, 0, 0), true)
  eq('the left of the curve', AT.hitStroke(ell, 0, 25, 0), true)
  eq('the right of the curve', AT.hitStroke(ell, 100, 25, 0), true)
  eq('the bottom of the curve', AT.hitStroke(ell, 50, 50, 0), true)
  // The bounding-box corner is outside the curve, so it is not a hit.
  eq('the bounding-box corner is not a hit', AT.hitStroke(ell, 0, 0, 0), false)
  eq('the centre is not a hit', AT.hitStroke(ell, 50, 25, 0), false)
  eq('just inside the top is not a hit', AT.hitStroke(ell, 50, 1, 0), false)
  eq('further inside is not a hit', AT.hitStroke(ell, 50, 2, 0), false)
  eq('a tolerance reaches inside', AT.hitStroke(ell, 50, 1.2, 2), true)
  eq('a tolerance that is still too small', AT.hitStroke(ell, 50, 2.5, 2), false)
  eq('a larger tolerance reaches further in', AT.hitStroke(ell, 50, 3, 4), true)
  eq('and stops again', AT.hitStroke(ell, 50, 4, 4), false)
  eq('a generous tolerance reaches it', AT.hitStroke(ell, 50, 5, 6), true)
  eq('the point order does not matter', AT.hitStroke({ tool: 'ellipse', points: [{ x: 100, y: 50 }, { x: 0, y: 0 }] }, 50, 0, 0), true)
  // The radius measure is scaled by the short semi-axis, so it approximates
  // rather than computes a true distance; a point on the curve at 45
  // degrees is still a hit, which is the invariant that matters.
  const c = Math.SQRT1_2
  eq('on the curve at 45 degrees', AT.hitStroke(ell, 50 + 50 * c, 25 + 25 * c, 0), true)
  eq('a tolerance around it', AT.hitStroke(ell, 50 + 50 * c, 25 + 25 * c, 1), true)
  // A zero-size ellipse still has a 1px radius from the max(1, ..) guard, so
  // it is hittable within about 0.41px of its point.
  const dot = { tool: 'ellipse', points: [{ x: 0, y: 0 }, { x: 0, y: 0 }] }
  eq('a zero-size ellipse is not hittable with no tolerance', AT.hitStroke(dot, 0, 0, 0), false)
  eq('a zero-size ellipse is hittable with a 0.5px tolerance', AT.hitStroke(dot, 0, 0, 0.5), true)
  eq('but not with 0.3px', AT.hitStroke(dot, 0, 0, 0.3), false)
  eq('and the guard radius applies on the x axis too', AT.hitStroke(dot, 0.5, 0, 0.5), true)
  eq('a zero-size ellipse off its point', AT.hitStroke(dot, 0, 3, 0), false)
  eq('an ellipse needs two corners', AT.hitStroke({ tool: 'ellipse', points: [{ x: 10, y: 10 }] }, 10, 10, 0), false)
})

group('a pixelate hit test is the whole rect, so it is easier to tap away', () => {
  const px = { tool: 'pixelate', points: [{ x: 10, y: 10 }, { x: 30, y: 40 }] }
  eq('the centre', AT.hitStroke(px, 20, 20, 0), true)
  eq('a corner', AT.hitStroke(px, 10, 10, 0), true)
  eq('the far corner', AT.hitStroke(px, 30, 40, 0), true)
  eq('the interior near an edge', AT.hitStroke(px, 20, 39, 0), true)
  eq('outside with no tolerance', AT.hitStroke(px, 32, 20, 0), false)
  eq('outside with a tolerance', AT.hitStroke(px, 20, 42, 2), true)
  eq('just past the tolerance', AT.hitStroke(px, 20, 42.1, 2), false)
  eq('a single point is not a mosaic', AT.hitStroke({ tool: 'pixelate', points: [{ x: 10, y: 10 }] }, 10, 10, 0), false)
})

group('a text hit test is its estimated line box', () => {
  // The box is widest-line * fontSize * 0.6 by lines * fontSize * 1.2,
  // grown by the tolerance on the near sides and by twice it on the far
  // ones.
  const txt = { tool: 'text', text: 'ab', fontSize: 10, points: [{ x: 100, y: 100 }] }
  eq('inside', AT.hitStroke(txt, 105, 105, 0), true)
  eq('the anchor itself', AT.hitStroke(txt, 100, 100, 0), true)
  eq('the far edge with no tolerance', AT.hitStroke(txt, 112, 100, 0), true)
  eq('just past the far edge', AT.hitStroke(txt, 112.1, 100, 0), false)
  eq('the near edge with a tolerance', AT.hitStroke(txt, 98, 100, 2), true)
  eq('just before the near edge', AT.hitStroke(txt, 97.9, 100, 2), false)
  eq('the far edge with a tolerance', AT.hitStroke(txt, 114, 100, 2), true)
  eq('just past the far edge with a tolerance', AT.hitStroke(txt, 114.1, 100, 2), false)
  eq('the bottom edge with a tolerance', AT.hitStroke(txt, 100, 114, 2), true)
  eq('just past the bottom edge with a tolerance', AT.hitStroke(txt, 100, 114.1, 2), false)
  eq('the widest line decides the width', AT.hitStroke({ tool: 'text', text: 'a\nbbb', fontSize: 10, points: [{ x: 0, y: 0 }] }, 17.9, 0, 0), true)
  eq('and the narrowest line does not', AT.hitStroke({ tool: 'text', text: 'a\nbbb', fontSize: 10, points: [{ x: 0, y: 0 }] }, 18.1, 0, 0), false)
  eq('the line count decides the height', AT.hitStroke({ tool: 'text', text: 'a\nbb', fontSize: 10, points: [{ x: 0, y: 0 }] }, 0, 23, 0), true)
  eq('and one more line does not', AT.hitStroke({ tool: 'text', text: 'a\nbb', fontSize: 10, points: [{ x: 0, y: 0 }] }, 0, 25, 0), false)
  eq('an absent font size reads as 24', AT.hitStroke({ tool: 'text', text: 'a', points: [{ x: 0, y: 0 }] }, 14, 28, 0), true)
  eq('and not one pixel more', AT.hitStroke({ tool: 'text', text: 'a', points: [{ x: 0, y: 0 }] }, 14, 29, 0), false)
  // An empty text is still a box: the caret has to be erasable.
  eq('an empty text is a one-line box', AT.hitStroke({ tool: 'text', text: '', fontSize: 10, points: [{ x: 0, y: 0 }] }, 0, 0, 0), true)
  eq('and it ends where a one-line box ends', AT.hitStroke({ tool: 'text', text: '', fontSize: 10, points: [{ x: 0, y: 0 }] }, 0, 12, 0), true)
  eq('a missing text field is the same as empty', AT.hitStroke({ tool: 'text', fontSize: 10, points: [{ x: 0, y: 0 }] }, 0, 0, 0), true)
  // Documented divergence: hitStroke guards the font size, so a negative one
  // reads as the 24px default rather than collapsing the box.
  eq('a negative font size uses the 24px default', AT.hitStroke({ tool: 'text', text: 'abc', fontSize: -10, points: [{ x: 0, y: 0 }] }, 0, 0, 0), true)
  eq('and the default box is 28.8px tall', AT.hitStroke({ tool: 'text', text: 'abc', fontSize: -10, points: [{ x: 0, y: 0 }] }, 0, 28.7, 0), true)
  eq('but not 29', AT.hitStroke({ tool: 'text', text: 'abc', fontSize: -10, points: [{ x: 0, y: 0 }] }, 0, 29, 0), false)
  eq('only the first point is the anchor', AT.hitStroke({ tool: 'text', text: 'a', fontSize: 10, points: [{ x: 0, y: 0 }, { x: 500, y: 500 }] }, 0, 0, 0), true)
  eq('a second point does not extend the box', AT.hitStroke({ tool: 'text', text: 'a', fontSize: 10, points: [{ x: 0, y: 0 }, { x: 500, y: 500 }] }, 500, 500, 0), false)
})

group('a corner arrow tests the two elbow segments between the endpoints', () => {
  const corner = { tool: 'arrowCorner', width: 2, points: [{ x: 0, y: 0 }, { x: 100, y: 20 }] }
  eq('the first segment', AT.hitStroke(corner, 50, 0, 0), true)
  eq('the elbow itself', AT.hitStroke(corner, 100, 0, 0), true)
  eq('the second segment', AT.hitStroke(corner, 100, 10, 0), true)
  eq('the end point', AT.hitStroke(corner, 100, 20, 0), true)
  eq('inside the elbow, away from both legs', AT.hitStroke(corner, 50, 20, 0), false)
  eq('inside the elbow with a tolerance', AT.hitStroke(corner, 50, 0.9, 0), true)
  eq('still inside the elbow with a bigger one', AT.hitStroke(corner, 50, 1.1, 0), false)
  // Only the first and last points matter, so a recorded mid-point cannot
  // change what the eraser matches.
  const poly = { tool: 'arrowCorner', width: 2, points: [{ x: 0, y: 0 }, { x: 50, y: 50 }, { x: 100, y: 0 }] }
  eq('the start point', AT.hitStroke(poly, 0, 0, 0), true)
  eq('the end point', AT.hitStroke(poly, 100, 0, 0), true)
  eq('the elbow of the endpoints', AT.hitStroke(poly, 100, 50, 0), false)
  eq('the recorded mid point is ignored', AT.hitStroke(poly, 50, 50, 0), false)
  eq('a one-point corner arrow is a dot', AT.hitStroke({ tool: 'arrowCorner', points: [{ x: 5, y: 5 }] }, 5, 5, 0), true)
  eq('inside the default half-width', AT.hitStroke({ tool: 'arrowCorner', points: [{ x: 5, y: 5 }] }, 5, 6.4, 0), true)
  eq('just outside it', AT.hitStroke({ tool: 'arrowCorner', points: [{ x: 5, y: 5 }] }, 5, 6.6, 0), false)
  eq('with a width of 4', AT.hitStroke({ tool: 'arrowCorner', width: 4, points: [{ x: 5, y: 5 }] }, 5, 6.9, 0), true)
  eq('and just outside that', AT.hitStroke({ tool: 'arrowCorner', width: 4, points: [{ x: 5, y: 5 }] }, 5, 7.1, 0), false)
})

group('a corrupt stroke is never partially erasable', () => {
  // Every point is validated before any segment is tested, so a stroke with
  // one bad point cannot have half of it removed.
  const line = { tool: 'brush', width: 4, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }
  eq('a NaN point in the middle', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: NaN, y: 0 }, { x: 5, y: 0 }] }, 0, 0, 0), false)
  eq('a NaN last point', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 1, y: NaN }] }, 0, 0, 0), false)
  eq('a null point', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, null] }, 0, 0, 0), false)
  eq('a point missing its y', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 1 }] }, 0, 0, 0), false)
  eq('a string point', AT.hitStroke({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: '5', y: 0 }] }, 0, 0, 0), false)
  eq('an empty point list', AT.hitStroke({ tool: 'brush', points: [] }, 0, 0, 0), false)
  eq('no points key at all', AT.hitStroke({ tool: 'brush' }, 0, 0, 0), false)
  eq('points that are not an array', AT.hitStroke({ tool: 'brush', points: 'x' }, 0, 0, 0), false)
  eq('a null stroke', AT.hitStroke(null, 0, 0, 0), false)
  eq('an undefined stroke', AT.hitStroke(undefined, 0, 0, 0), false)
  eq('no arguments at all', AT.hitStroke(), false)
})

group('a non-finite pointer or tolerance is inert, and the call never throws', () => {
  const line = { tool: 'brush', width: 4, points: [{ x: 0, y: 0 }, { x: 10, y: 0 }] }
  eq('a NaN pointer x', AT.hitStroke(line, NaN, 0, 0), false)
  eq('a NaN pointer y', AT.hitStroke(line, 0, NaN, 0), false)
  eq('an Infinity pointer clamps out of reach', AT.hitStroke(line, Infinity, 0, 0), false)
  // A non-positive or non-finite tolerance reads as 0 rather than as the
  // caller's default, so a missing zoom scale narrows the eraser instead of
  // widening it.
  eq('a negative tolerance', AT.hitStroke(line, 5, 0, -3), true)
  eq('a NaN tolerance', AT.hitStroke(line, 5, 0, NaN), true)
  eq('a zero tolerance', AT.hitStroke(line, 5, 0, 0), true)
  eq('a string tolerance does not widen', AT.hitStroke(line, 5, 3, '9'), false)
  // The per-keystroke purity contract: a throw here is a UI defect.
  for (const s of [null, undefined, {}, { tool: 'brush' }, line, { tool: 'rect', points: [{ x: 0, y: 0 }] },
    { tool: 'text', points: [{ x: 0, y: 0 }] }, { tool: 'ellipse', points: [{ x: 0, y: 0 }, { x: 0, y: 0 }] }]) {
    noThrow(`no throw for ${show(s)}`, () => AT.hitStroke(s, 0, 0, 0))
    noThrow(`no throw for ${show(s)} at NaN`, () => AT.hitStroke(s, NaN, NaN, NaN))
    noThrow(`no throw for ${show(s)} with no pointer`, () => AT.hitStroke(s))
  }
  is('the return value is always a boolean', [AT.hitStroke(line, 5, 0, 0), AT.hitStroke(line, 5, 9, 0), AT.hitStroke(null, 0, 0, 0)],
    (v) => v.every((x) => typeof x === 'boolean'), 'boolean results')
})

// ---------------------------------------------------------------------------
section('AnnotationTools.cropDocument - the crop-commit filter')

group('a stroke is kept when any of its points is inside the rect', () => {
  const R = { x: 50, y: 50, w: 50, h: 50 }
  const at = (p) => ({ tool: 'brush', points: p })
  eq('inside', AT.cropDocument([at([{ x: 60, y: 60 }])], R).length, 1)
  eq('on the near edge', AT.cropDocument([at([{ x: 50, y: 50 }])], R).length, 1)
  eq('on the far edge', AT.cropDocument([at([{ x: 100, y: 100 }])], R).length, 1)
  eq('outside', AT.cropDocument([at([{ x: 10, y: 10 }])], R).length, 0)
  // The bounds are inclusive, so a stroke that only touches the frame is
  // still exported rather than silently dropped.
  eq('a zero-size rect keeps the point on it', AT.cropDocument([at([{ x: 5, y: 5 }])], { x: 5, y: 5, w: 0, h: 0 }).length, 1)
  eq('a negative-origin rect is a real rect', AT.cropDocument([at([{ x: -5, y: -5 }])], { x: -10, y: -10, w: 20, h: 20 }).length, 1)
  eq('a point past a negative rect', AT.cropDocument([at([{ x: 60, y: 60 }])], { x: -10, y: -10, w: 20, h: 20 }).length, 0)
  eq('the first point decides when the rest are outside', AT.cropDocument([at([{ x: 60, y: 60 }, { x: 900, y: 900 }])], R).length, 1)
  eq('a later point inside keeps it', AT.cropDocument([at([{ x: 900, y: 900 }, { x: 60, y: 60 }])], R).length, 1)
})

group('a stroke that only crosses the rect is kept whole', () => {
  const R = { x: 50, y: 50, w: 50, h: 50 }
  const at = (p) => ({ tool: 'brush', points: p })
  eq('a segment straight through', AT.cropDocument([at([{ x: 0, y: 60 }, { x: 200, y: 60 }])], R).length, 1)
  eq('every point outside but a segment crossing', AT.cropDocument([at([{ x: 0, y: 60 }, { x: 10, y: 60 }, { x: 200, y: 60 }])], R).length, 1)
  eq('a diagonal through the corner', AT.cropDocument([at([{ x: 0, y: 0 }, { x: 200, y: 200 }])], R).length, 1)
  // The bounds are inclusive, so a segment that only grazes the frame is
  // still kept: one pixel lower and it is dropped.
  eq('a segment grazing the near edge', AT.cropDocument([at([{ x: 0, y: 50 }, { x: 200, y: 50 }])], R).length, 1)
  eq('one pixel below it', AT.cropDocument([at([{ x: 0, y: 50 }, { x: 200, y: 50 }])], { x: 50, y: 51, w: 50, h: 50 }).length, 0)
  eq('a stroke entirely on the far side', AT.cropDocument([at([{ x: 200, y: 200 }, { x: 300, y: 300 }])], R).length, 0)
})

group('kept strokes are the same objects, in absolute document coordinates', () => {
  // Documented: "keeps the rest VERBATIM in absolute document coordinates.
  // Coordinates are never translated (the view rect owns the origin);
  // translating here as well would double-shift every stroke."
  const R = { x: 50, y: 50, w: 50, h: 50 }
  const stroke = { tool: 'brush', width: 4, points: [{ x: 60, y: 60 }] }
  const out = AT.cropDocument([stroke], R)
  eq('the object is not copied', out[0] === stroke, true)
  eq('the point is not translated', out[0].points, [{ x: 60, y: 60 }])
  eq('the whole stroke is kept, fields included', out[0], { tool: 'brush', width: 4, points: [{ x: 60, y: 60 }] })
  const text = { tool: 'text', text: 'hi', fontSize: 12, points: [{ x: 60, y: 60 }] }
  eq('a text stroke keeps its metrics', AT.cropDocument([text], R)[0], text)
  const order = [stroke, { tool: 'brush', points: [{ x: 70, y: 70 }] }, { tool: 'brush', points: [{ x: 1, y: 1 }] }]
  eq('the surviving order is the input order', AT.cropDocument(order, R).length, 2)
  eq('and the survivors are the first two', AT.cropDocument(order, R), [order[0], order[1]])
})

group('unusable input drops everything rather than throwing', () => {
  const R = { x: 50, y: 50, w: 50, h: 50 }
  const at = (p) => ({ tool: 'brush', points: p })
  eq('a non-array stroke list', AT.cropDocument(null, R), [])
  eq('a string stroke list', AT.cropDocument('x', R), [])
  eq('an object stroke list', AT.cropDocument({}, R), [])
  eq('a null rect', AT.cropDocument([at([{ x: 60, y: 60 }])], null), [])
  eq('an undefined rect', AT.cropDocument([at([{ x: 60, y: 60 }])], undefined), [])
  eq('a rect missing w', AT.cropDocument([at([{ x: 60, y: 60 }])], { x: 0, y: 0, w: 10 }), [])
  eq('a rect with a NaN field', AT.cropDocument([at([{ x: 60, y: 60 }])], { x: 0, y: 0, w: NaN, h: 10 }), [])
  eq('a rect with a string field', AT.cropDocument([at([{ x: 60, y: 60 }])], { x: 0, y: 0, w: '10', h: 10 }), [])
  eq('no arguments at all', AT.cropDocument(), [])
  eq('an empty stroke list', AT.cropDocument([], R), [])
  eq('null entries in the list', AT.cropDocument([null, undefined], R), [])
  eq('a stroke with no points array', AT.cropDocument([{ tool: 'brush' }], R), [])
  eq('a stroke with empty points', AT.cropDocument([{ tool: 'brush', points: [] }], R), [])
  eq('a stroke whose points are not an array', AT.cropDocument([{ tool: 'brush', points: 'x' }], R), [])
  eq('a stroke whose only point is corrupt', AT.cropDocument([at([{ x: NaN, y: 0 }])], R), [])
  eq('a corrupt point after a good one still keeps it', AT.cropDocument([at([{ x: 60, y: 60 }, { x: NaN, y: 0 }])], R).length, 1)
  // The per-keystroke purity contract: a throw here loses the crop.
  for (const [strokes, rect] of [
    [null, R], [[], R], [[{}], R], [null, null], [at([{ x: 1, y: 1 }]), { x: 0, y: 0, w: 1, h: 1 }],
    [[null, { tool: 'x', points: [null, { x: NaN, y: NaN }] }], R],
  ]) {
    noThrow(`no throw for ${show(strokes)} in ${show(rect)}`, () => AT.cropDocument(strokes, rect))
  }
  is('the result is always an array', [AT.cropDocument(null, R), AT.cropDocument([], R), AT.cropDocument([{}], R)],
    (v) => v.every(Array.isArray), 'arrays')
})

// ---------------------------------------------------------------------------
section('AnnotationTools - the document/view frame vocabulary')

group('clampDocumentRect subtracts the view origin and puts it back', () => {
  const vr = { x: 50, y: 50, w: 100, h: 100 }
  eq('inside the view', AT.clampDocumentRect({ x: 60, y: 60, w: 20, h: 20 }, vr), { x: 60, y: 60, w: 20, h: 20 })
  eq('at the view origin', AT.clampDocumentRect({ x: 50, y: 50, w: 10, h: 10 }, vr), { x: 50, y: 50, w: 10, h: 10 })
  eq('exactly the view', AT.clampDocumentRect({ x: 50, y: 50, w: 100, h: 100 }, vr), { x: 50, y: 50, w: 100, h: 100 })
  eq('overhanging the far edge', AT.clampDocumentRect({ x: 90, y: 90, w: 50, h: 50 }, vr), { x: 90, y: 90, w: 50, h: 50 })
  eq('before the view origin', AT.clampDocumentRect({ x: 0, y: 0, w: 10, h: 10 }, vr), { x: 50, y: 50, w: 1, h: 1 })
  // The clamp happens in view-relative space, so a rect past the far edge
  // comes back at the view origin plus the view's own last pixel.
  eq('entirely after the view', AT.clampDocumentRect({ x: 500, y: 500, w: 10, h: 10 }, vr), { x: 149, y: 149, w: 1, h: 1 })
  eq('a null rect', AT.clampDocumentRect(null, vr), null)
  // Documented: "The subtraction is unguarded on purpose: a non-finite field
  // is already 0 to clampRect's own guard, so the two agree." The frame does
  // not shift, because a bad field folds to 0 before it is added back.
  eq('a NaN field folds to 0 without moving the frame', AT.clampDocumentRect({ x: NaN, y: 0, w: 5, h: 5 }, { x: 0, y: 0, w: 100, h: 100 }), { x: 0, y: 0, w: 5, h: 5 })
  eq('a non-finite frame origin is not guarded', AT.clampDocumentRect({ x: 5, y: 5, w: 5, h: 5 }, { x: 0, y: 0 }), { x: 0, y: 0, w: 1, h: 1 })
  eq('a zero-size frame', AT.clampDocumentRect({ x: 50, y: 50, w: 10, h: 10 }, { x: 0, y: 0, w: 0, h: 0 }), { x: 0, y: 0, w: 1, h: 1 })
  eq('a negative frame origin', AT.clampDocumentRect({ x: -40, y: -40, w: 10, h: 10 }, { x: -50, y: -50, w: 100, h: 100 }), { x: -40, y: -40, w: 10, h: 10 })
  // The subtraction runs before clampRect's finite guard, so a numeric
  // string has already become a number by then - the one place in this file
  // where a string field is accepted.
  eq('a numeric string field is coerced by the subtraction', AT.clampDocumentRect({ x: '10', y: 10, w: 5, h: 5 }, { x: 0, y: 0, w: 100, h: 100 }), { x: 10, y: 10, w: 5, h: 5 })
  eq('a non-numeric string field is still not a coordinate', AT.clampDocumentRect({ x: 'a', y: 10, w: 5, h: 5 }, { x: 0, y: 0, w: 100, h: 100 }), { x: 0, y: 10, w: 5, h: 5 })
  for (const r of [{ x: 0, y: 0, w: 10, h: 10 }, { x: 90, y: 90, w: 50, h: 50 }, { x: 500, y: 500, w: 10, h: 10 }, { x: 30.6, y: 30.4, w: 5, h: 5 }]) {
    const c = AT.clampDocumentRect(r, { x: 0, y: 0, w: 100, h: 100 })
    is(`inside the view for ${show(r)}`, c, (v) => v.x >= 0 && v.y >= 0 && v.w >= 1 && v.h >= 1 && v.x + v.w <= 100 && v.y + v.h <= 100, 'inside the view rect')
  }
  eq('no arguments at all', AT.clampDocumentRect(), null)
  // The view rect is a required argument: its origin is read unguarded.
  throws('a null view rect throws', () => AT.clampDocumentRect({ x: 1, y: 1, w: 1, h: 1 }, null), /reading 'x'/)
})

group('exportViewRect is the view alone until a frame is applied', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('no frame returns the view', AT.exportViewRect(vr, null), vr)
  eq('the view object itself is returned', AT.exportViewRect(vr, null) === vr, true)
  eq('an undefined frame returns the view', AT.exportViewRect(vr, undefined), vr)
  eq('a frame inside the view', AT.exportViewRect(vr, { x: 10, y: 20, w: 30, h: 40 }), { x: 10, y: 20, w: 30, h: 40 })
  eq('a frame overhanging is narrowed', AT.exportViewRect(vr, { x: 90, y: 90, w: 50, h: 50 }), { x: 90, y: 90, w: 10, h: 10 })
  // A frame the view does not contain clamps to the view's far corner: the
  // export still has to be a real rect rather than an empty one.
  eq('a frame entirely after the view', AT.exportViewRect(vr, { x: 200, y: 200, w: 10, h: 10 }), { x: 99, y: 99, w: 1, h: 1 })
  eq('a frame entirely before the view', AT.exportViewRect(vr, { x: -500, y: -500, w: 10, h: 10 }), { x: 0, y: 0, w: 1, h: 1 })
  eq('a zero-size frame', AT.exportViewRect(vr, { x: 50, y: 50, w: 0, h: 0 }), { x: 50, y: 50, w: 1, h: 1 })
  eq('a negative-size frame', AT.exportViewRect(vr, { x: 50, y: 50, w: -10, h: -10 }), { x: 50, y: 50, w: 1, h: 1 })
  eq('a view that already has a negative origin', AT.exportViewRect({ x: -50, y: -50, w: 100, h: 100 }, { x: -40, y: -40, w: 10, h: 10 }), { x: -40, y: -40, w: 10, h: 10 })
  eq('no arguments at all', AT.exportViewRect(), undefined)
  throws('a null view with a frame throws', () => AT.exportViewRect(null, { x: 0, y: 0, w: 1, h: 1 }), /reading 'x'/)
})

group('exportSize swaps the axes for a quarter turn and only that', () => {
  // Documented: "the angle is reduced modulo 180 first so -90, 90 and 270
  // all swap exactly once, and an animated in-between angle does not,
  // because the export never runs mid-animation."
  const vr = { x: 0, y: 0, w: 100, h: 50 }
  eq('0', AT.exportSize(vr, 0), { w: 100, h: 50 })
  eq('90 swaps', AT.exportSize(vr, 90), { w: 50, h: 100 })
  eq('-90 swaps', AT.exportSize(vr, -90), { w: 50, h: 100 })
  eq('270 swaps', AT.exportSize(vr, 270), { w: 50, h: 100 })
  eq('-270 swaps', AT.exportSize(vr, -270), { w: 50, h: 100 })
  eq('450 is a quarter turn after reduction', AT.exportSize(vr, 450), { w: 50, h: 100 })
  eq('180 does not', AT.exportSize(vr, 180), { w: 100, h: 50 })
  eq('-180 does not', AT.exportSize(vr, -180), { w: 100, h: 50 })
  eq('360 does not', AT.exportSize(vr, 360), { w: 100, h: 50 })
  eq('an in-between angle does not', AT.exportSize(vr, 45), { w: 100, h: 50 })
  eq('a mid-animation angle does not', AT.exportSize(vr, 89), { w: 100, h: 50 })
  eq('NaN does not', AT.exportSize(vr, NaN), { w: 100, h: 50 })
  eq('undefined does not', AT.exportSize(vr, undefined), { w: 100, h: 50 })
  eq('null does not', AT.exportSize(vr, null), { w: 100, h: 50 })
  eq('a numeric string does', AT.exportSize(vr, '90'), { w: 50, h: 100 })
  eq('a numeric string of 0 does not', AT.exportSize(vr, '0'), { w: 100, h: 50 })
  eq('a square view swaps to itself', AT.exportSize({ x: 0, y: 0, w: 100, h: 100 }, 90), { w: 100, h: 100 })
  eq('a zero-size view', AT.exportSize({ x: 0, y: 0, w: 0, h: 0 }, 90), { w: 0, h: 0 })
  throws('no arguments at all throws - the view rect is required', () => AT.exportSize(), /reading 'w'/)
  is('the return shape is w,h only', AT.exportSize(vr, 0), (v) => Object.keys(v).join(',') === 'w,h', 'w,h')
})

group('clampDocPoint folds the frame into the bounds in place', () => {
  // Documented: "The bounds are folded in place rather than through an
  // intersection rect, because rebuilding x from a width loses bits."
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('no frame, inside', AT.clampDocPoint({ x: 5, y: 5 }, vr, null), { x: 5, y: 5 })
  eq('no frame, outside', AT.clampDocPoint({ x: 500, y: -5 }, vr, null), { x: 100, y: 0 })
  eq('the view corner is reachable', AT.clampDocPoint({ x: 0, y: 0 }, vr, null), { x: 0, y: 0 })
  eq('a frame narrows the bounds', AT.clampDocPoint({ x: 500, y: 5 }, vr, { x: 10, y: 10, w: 20, h: 20 }), { x: 30, y: 10 })
  eq('a frame clamps the near side too', AT.clampDocPoint({ x: -50, y: 5 }, vr, { x: 10, y: 10, w: 20, h: 20 }), { x: 10, y: 10 })
  eq('exactly on the frame far edge', AT.clampDocPoint({ x: 30, y: 30 }, vr, { x: 10, y: 10, w: 20, h: 20 }), { x: 30, y: 30 })
  eq('a frame larger than the view does not widen it', AT.clampDocPoint({ x: 500, y: 5 }, vr, { x: -50, y: -50, w: 500, h: 500 }), { x: 100, y: 5 })
  // A frame that does not overlap the view makes the interval inverted, and
  // an inverted interval returns the point unchanged rather than snapping it
  // to an unrelated edge.
  eq('a frame that misses the view leaves the point alone', AT.clampDocPoint({ x: 500, y: 500 }, vr, { x: 500, y: 500, w: 10, h: 10 }), { x: 500, y: 500 })
  eq('a zero-size frame', AT.clampDocPoint({ x: 50, y: 50 }, vr, { x: 50, y: 50, w: 0, h: 0 }), { x: 50, y: 50 })
  eq('an undefined frame behaves as no frame', AT.clampDocPoint({ x: 500, y: 5 }, vr, undefined), { x: 100, y: 5 })
  eq('a view with a negative origin', AT.clampDocPoint({ x: -500, y: 5 }, { x: -100, y: -100, w: 10, h: 10 }, null), { x: -100, y: -90 })
  eq('a point inside a negative-origin view', AT.clampDocPoint({ x: -95, y: -95 }, { x: -100, y: -100, w: 10, h: 10 }, null), { x: -95, y: -95 })
  eq('a NaN point keeps its NaN', Number.isNaN(AT.clampDocPoint({ x: NaN, y: 0 }, vr, null).x), true)
  throws('no arguments at all throws - both rects are required', () => AT.clampDocPoint(), /reading 'x'/)
  noThrow('a null frame', () => AT.clampDocPoint({ x: 1, y: 1 }, vr, null))
})

group('insideFrame is the no-frame-everything-is-fair default', () => {
  const F = { x: 0, y: 0, w: 10, h: 10 }
  eq('no frame', AT.insideFrame({ x: 500, y: 500 }, null), true)
  eq('an undefined frame', AT.insideFrame({ x: 0, y: 0 }, undefined), true)
  eq('inside', AT.insideFrame({ x: 5, y: 5 }, F), true)
  eq('on the far corner', AT.insideFrame({ x: 10, y: 10 }, F), true)
  eq('one pixel past', AT.insideFrame({ x: 11, y: 10 }, F), false)
  eq('above', AT.insideFrame({ x: 5, y: -1 }, F), false)
  eq('left', AT.insideFrame({ x: -1, y: 5 }, F), false)
  eq('a zero-size frame admits only its point', AT.insideFrame({ x: 0, y: 0 }, { x: 0, y: 0, w: 0, h: 0 }), true)
  eq('and nothing else', AT.insideFrame({ x: 1, y: 0 }, { x: 0, y: 0, w: 0, h: 0 }), false)
  // A negative extent puts the far edge before the origin, so the inclusive
  // test admits nothing at all - a degenerate frame blocks every point.
  eq('a negative-size frame admits nothing', AT.insideFrame({ x: 0, y: 0 }, { x: 0, y: 0, w: -5, h: -5 }), false)
  eq('not even its own origin', AT.insideFrame({ x: -5, y: -5 }, { x: 0, y: 0, w: -5, h: -5 }), false)
  eq('no arguments at all', AT.insideFrame(), true)
  noThrow('a null frame', () => AT.insideFrame({ x: 1, y: 1 }, null))
  for (const [p, f] of [[{ x: 5, y: 5 }, F], [{ x: 0, y: 0 }, F], [{ x: 10, y: 10 }, F], [{ x: 10.1, y: 5 }, F]]) {
    is(`inside for ${show(p)} with ${show(f)}`, AT.insideFrame(p, f),
      (v) => v === (p.x >= f.x && p.x <= f.x + f.w && p.y >= f.y && p.y <= f.y + f.h), 'matches the inclusive test')
  }
})

group('hitTolerance is a constant on-screen size, so it narrows as you zoom in', () => {
  eq('1:1', SL.qtDpr(1) && AT.hitTolerance(1), 6)
  eq('2x zoom halves it', AT.hitTolerance(2), 3)
  eq('0.5x zoom doubles it', AT.hitTolerance(0.5), 12)
  // Documented: "The scale is compared, not validated: a non-numeric value
  // still coerces, and a non-finite one collapses to a zero tolerance
  // rather than the default."
  eq('a scale of 0 falls back to 6', AT.hitTolerance(0), 6)
  eq('a negative scale falls back to 6', AT.hitTolerance(-1), 6)
  eq('a NaN scale falls back to 6', AT.hitTolerance(NaN), 6)
  eq('an undefined scale falls back to 6', AT.hitTolerance(undefined), 6)
  eq('a null scale falls back to 6', AT.hitTolerance(null), 6)
  eq('a non-numeric string falls back to 6', AT.hitTolerance('a'), 6)
  eq('a numeric string still coerces', AT.hitTolerance('2'), 3)
  eq('an Infinity scale collapses to 0', AT.hitTolerance(Infinity), 0)
  eq('an empty string falls back to 6', AT.hitTolerance(''), 6)
  eq('no arguments at all', AT.hitTolerance(), 6)
  approx('a 1.25 scale', AT.hitTolerance(1.25), 4.8, 1e-12)
  approx('a fractional scale', AT.hitTolerance(0.3), 20, 1e-12)
  is('the tolerance is non-negative and finite for any sane scale', [AT.hitTolerance(0.5), AT.hitTolerance(1), AT.hitTolerance(4), AT.hitTolerance(0.01)],
    (v) => v.every((x) => Number.isFinite(x) && x >= 0), 'finite and non-negative')
  // The eraser must keep working at a scale where a pixel of tolerance is a
  // large fraction of a document pixel.
  is('a large zoom still gives a usable tolerance', AT.hitTolerance(64), (v) => v > 0 && v < 1, 'between 0 and 1')
  noThrow('an object scale', () => AT.hitTolerance({}))
  noThrow('an array scale', () => AT.hitTolerance([2]))
})

// ---------------------------------------------------------------------------
section('AnnotationTools.strokeBounds / selectHandles - the selection outline')

group('strokeBounds pads by half the width plus 4, with a floor of 4', () => {
  eq('a diagonal stroke', AT.strokeBounds({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 10, y: 20 }] }), { x: -5.5, y: -5.5, w: 21, h: 31 })
  eq('a single point', AT.strokeBounds({ tool: 'brush', points: [{ x: 5, y: 5 }] }), { x: -0.5, y: -0.5, w: 11, h: 11 })
  // pad = max(4, width / 2 + 4): below a 0 width the floor takes over.
  eq('a width of 2 pads by 5', AT.strokeBounds({ tool: 'brush', width: 2, points: [{ x: 0, y: 0 }, { x: 10, y: 20 }] }), { x: -5, y: -5, w: 20, h: 30 })
  eq('a width of 10 pads by 9', AT.strokeBounds({ tool: 'brush', width: 10, points: [{ x: 0, y: 0 }, { x: 10, y: 20 }] }), { x: -9, y: -9, w: 28, h: 38 })
  eq('an absent width reads as 3', AT.strokeBounds({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 10, y: 20 }] }).x, -5.5)
  // A zero width is a falsy fold here, unlike hitStroke's `> 0` guard; both
  // land on 3, so the two agree by different routes.
  eq('a zero width reads as 3 here too', AT.strokeBounds({ tool: 'brush', width: 0, points: [{ x: 0, y: 0 }] }).x, -5.5)
  eq('the floor of 4 applies at width 0', AT.strokeBounds({ tool: 'brush', width: 0, points: [{ x: 0, y: 0 }] }).w, 11)
  eq('negative coordinates are carried through', AT.strokeBounds({ tool: 'brush', points: [{ x: -10, y: -10 }, { x: 0, y: 0 }] }), { x: -15.5, y: -15.5, w: 21, h: 21 })
  eq('the extent is over every point, not just the ends',
    AT.strokeBounds({ tool: 'brush', points: [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 50, y: 100 }] }), { x: -5.5, y: -5.5, w: 111, h: 111 })
  eq('an empty point list has no bounds', AT.strokeBounds({ tool: 'brush', points: [] }), null)
  eq('no points key at all', AT.strokeBounds({ tool: 'brush' }), null)
  // A stroke object is a required argument: its points are read unguarded.
  throws('no arguments at all throws', () => AT.strokeBounds(), /reading 'points'/)
  throws('a null stroke throws', () => AT.strokeBounds(null), /reading 'points'/)
  // A one-point stroke still gets a real box, so a dot is selectable.
  is('a one-point box is a real rect', AT.strokeBounds({ tool: 'brush', points: [{ x: 0, y: 0 }] }),
    (v) => v.w > 0 && v.h > 0, 'positive size')
  for (const pts of [[{ x: 0, y: 0 }, { x: 10, y: 20 }], [{ x: -30, y: 5 }], [{ x: 3, y: 3 }, { x: 3, y: 3 }]]) {
    is(`positive size for ${show(pts)}`, AT.strokeBounds({ tool: 'brush', points: pts }),
      (v) => v.w >= 0 && v.h >= 0 && Number.isFinite(v.x), 'finite, non-negative size')
  }
})

group('the text extent grows the box but never shrinks it', () => {
  eq('a 20px font over 5 characters', AT.strokeBounds({ tool: 'text', text: 'hello', fontSize: 20, points: [{ x: 0, y: 0 }] }), { x: -5.5, y: -5.5, w: 71, h: 35 })
  eq('two lines are taller', AT.strokeBounds({ tool: 'text', text: 'a\nbb', fontSize: 10, points: [{ x: 0, y: 0 }] }), { x: -5.5, y: -5.5, w: 23, h: 35 })
  eq('an empty text is one line tall', AT.strokeBounds({ tool: 'text', text: '', fontSize: 10, points: [{ x: 0, y: 0 }] }), { x: -5.5, y: -5.5, w: 11, h: 23 })
  eq('a missing text is one line tall', AT.strokeBounds({ tool: 'text', fontSize: 10, points: [{ x: 0, y: 0 }] }).h, 23)
  // An absent font size is a falsy fold (`s.fontSize || 24`), so the box is
  // the 24px estimate plus the padding.
  eq('an absent font size reads as 24', AT.strokeBounds({ tool: 'text', text: 'x', points: [{ x: 0, y: 0 }] }).h, 39.8)
  eq('and the width follows the same estimate', AT.strokeBounds({ tool: 'text', text: 'x', points: [{ x: 0, y: 0 }] }).w, 25.4)
  // The point extent wins when it is larger, so a second point is honoured.
  eq('a second point is not ignored', AT.strokeBounds({ tool: 'text', text: 'x', fontSize: 10, points: [{ x: 100, y: 100 }, { x: 0, y: 0 }] }).w, 111)
  // Documented divergence: this function takes a negative font size
  // literally, so the estimate contributes nothing and the box collapses to
  // the anchor - while hitStroke's guard would have used the 24px default.
  eq('a negative font size contributes no extent',
    AT.strokeBounds({ tool: 'text', text: 'abc', fontSize: -10, points: [{ x: 10, y: 10 }] }), { x: 4.5, y: 4.5, w: 11, h: 11 })
  eq('and that box is far shorter than the hit test box',
    AT.strokeBounds({ tool: 'text', text: 'abc', fontSize: -10, points: [{ x: 10, y: 10 }] }).h < 28.8, true)
  // A zero font size is the other side of the same `||` fold: it reads as
  // 24 here too, so only a *negative* size takes the literal path.
  approx('a zero font size reads as 24', AT.strokeBounds({ tool: 'text', text: 'abc', fontSize: 0, points: [{ x: 10, y: 10 }] }).h, 39.8, 1e-9)
  approx('a zero font size widths as 24 too', AT.strokeBounds({ tool: 'text', text: 'abc', fontSize: 0, points: [{ x: 10, y: 10 }] }).w, 3 * 24 * 0.6 + 11, 1e-9)
  approx('a 24px one-character line is 14.4px wide', AT.strokeBounds({ tool: 'text', text: 'x', fontSize: 24, points: [{ x: 0, y: 0 }] }).w, 1 * 24 * 0.6 + 11, 1e-12)
  approx('a 24px single line is 28.8px tall', AT.strokeBounds({ tool: 'text', text: 'x', fontSize: 24, points: [{ x: 0, y: 0 }] }).h, 1 * 24 * 1.2 + 11, 1e-12)
})

group('selectHandles is the eight-spot order the region overlay shares', () => {
  // Documented: "corners on even indexes, edge midpoints on odd ones".
  eq('the published order', AT.selectHandles({ x: 0, y: 0, w: 100, h: 50 }), [
    { x: 0, y: 0 }, { x: 50, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 25 },
    { x: 100, y: 50 }, { x: 50, y: 50 }, { x: 0, y: 50 }, { x: 0, y: 25 },
  ])
  eq('eight spots', AT.selectHandles({ x: 0, y: 0, w: 1, h: 1 }).length, 8)
  eq('an odd width still halves exactly', AT.selectHandles({ x: 0, y: 0, w: 101, h: 51 })[1], { x: 50.5, y: 0 })
  eq('a zero-size box puts every spot on one point',
    AT.selectHandles({ x: 5, y: 5, w: 0, h: 0 }).every((p) => p.x === 5 && p.y === 5), true)
  eq('a negative box places the spots by its far edge', AT.selectHandles({ x: -10, y: -10, w: 20, h: 20 })[0], { x: -10, y: -10 })
  eq('a null box', AT.selectHandles(null), null)
  eq('an undefined box', AT.selectHandles(undefined), null)
  eq('no arguments at all', AT.selectHandles(), null)
  for (const b of [{ x: 0, y: 0, w: 100, h: 50 }, { x: -20, y: 7, w: 33, h: 91 }, { x: 5, y: 5, w: 0, h: 0 }]) {
    const h = AT.selectHandles(b)
    is(`corners on the box corners for ${show(b)}`, h.filter((_, i) => i % 2 === 0).map((p) => `${p.x},${p.y}`).sort(),
      (v) => v.includes(`${b.x},${b.y}`) && v.includes(`${b.x + b.w},${b.y}`), 'top-left and top-right present')
    is(`every spot is inside the box for ${show(b)}`, h,
      (v) => v.every((p) => p.x >= b.x - 1e-9 && p.x <= b.x + b.w + 1e-9 && p.y >= b.y - 1e-9 && p.y <= b.y + b.h + 1e-9),
      'inside the box')
  }
  noThrow('a box with missing fields', () => AT.selectHandles({}))
})

// ---------------------------------------------------------------------------
section('AnnotationTools.docToBacking / rotBox - the paint transform')

group('docToBacking scales, rotates about the view centre and re-centres', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('the view centre', AT.docToBacking({ x: 50, y: 50 }, vr, 1, 0, 100, 100), { x: 50, y: 50 })
  eq('the top-left corner', AT.docToBacking({ x: 0, y: 0 }, vr, 1, 0, 100, 100), { x: 0, y: 0 })
  eq('a scale of 2', AT.docToBacking({ x: 50, y: 50 }, vr, 2, 0, 100, 100), { x: 100, y: 100 })
  eq('a 180 degree turn', AT.docToBacking({ x: 0, y: 0 }, vr, 1, 180, 100, 100), { x: 100, y: 100 })
  // At 90 degrees the document size is the swapped one, so the point that
  // was at the right edge lands at the top of the rotated surface.
  eq('a quarter turn', AT.docToBacking({ x: 100, y: 50 }, vr, 1, 90, 100, 50), { x: 50, y: 75 })
  // The other quarter turn maps the mirror-image document point to the same
  // backing pixel, which is the invariant the mosaic sampling depends on.
  approx('the opposite quarter turn agrees on x', AT.docToBacking({ x: 0, y: 50 }, vr, 1, 270, 100, 50).x, 50, 1e-9)
  eq('the opposite quarter turn, y', AT.docToBacking({ x: 0, y: 50 }, vr, 1, 270, 100, 50).y, 75)
  eq('a view with a non-zero origin', AT.docToBacking({ x: 60, y: 60 }, { x: 50, y: 50, w: 20, h: 20 }, 1, 0, 20, 20), { x: 10, y: 10 })
  // The per-frame path must not clamp: a sample outside the backing is
  // dropped by the caller, not moved here.
  eq('an outside point is not clamped', AT.docToBacking({ x: -50, y: 200 }, vr, 1, 0, 100, 100), { x: -50, y: 200 })
  eq('a scale of 0 collapses to the document centre', AT.docToBacking({ x: 50, y: 50 }, vr, 0, 0, 100, 100), { x: 0, y: 0 })
  is('a NaN scale spreads', AT.docToBacking({ x: 50, y: 50 }, vr, NaN, 0, 100, 100),
    (v) => Number.isNaN(v.x) && Number.isNaN(v.y), 'NaN coordinates')
  is('a 45 degree turn is a real rotation', AT.docToBacking({ x: 50, y: 0 }, vr, 1, 45, 100, 100),
    (v) => Math.abs(v.x - 85.3553390593274) < 1e-9 && Math.abs(v.y - 14.6446609406726) < 1e-9,
    'the top edge midpoint swings out to the right')
  throws('a null point throws', () => AT.docToBacking(null, vr, 1, 0, 100, 100), /reading 'x'/)
  throws('a null view throws', () => AT.docToBacking({ x: 1, y: 1 }, null, 1, 0, 100, 100), /reading 'x'/)
})

group('rotBox is the rounded bounding box of the four mapped corners', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('identity', AT.rotBox({ x: 0, y: 0, w: 10, h: 20 }, vr, 1, 0, 100, 100), { x: 0, y: 0, w: 10, h: 20 })
  eq('a scale of 2', AT.rotBox({ x: 0, y: 0, w: 10, h: 20 }, vr, 2, 0, 100, 100), { x: 0, y: 0, w: 20, h: 40 })
  eq('an offset rect', AT.rotBox({ x: 10, y: 10, w: 10, h: 10 }, vr, 1, 0, 100, 100), { x: 10, y: 10, w: 10, h: 10 })
  eq('a 180 degree turn keeps the size at the mirrored origin', AT.rotBox({ x: 0, y: 0, w: 10, h: 10 }, vr, 1, 180, 100, 100), { x: 90, y: 90, w: 10, h: 10 })
  // A quarter turn swaps the box's own axes; the origin is not clamped, so
  // the caller can see that the box left the backing.
  eq('a quarter turn swaps w and h', [AT.rotBox({ x: 0, y: 0, w: 20, h: 10 }, vr, 1, 90, 100, 50).w, AT.rotBox({ x: 0, y: 0, w: 20, h: 10 }, vr, 1, 90, 100, 50).h], [10, 20])
  eq('and the origin may be negative', AT.rotBox({ x: 0, y: 0, w: 20, h: 10 }, vr, 1, 90, 100, 50), { x: 90, y: -25, w: 10, h: 20 })
  eq('a half scale at 90 degrees', AT.rotBox({ x: 0, y: 0, w: 20, h: 10 }, vr, 0.5, 90, 100, 50), { x: 45, y: -12, w: 5, h: 10 })
  eq('a zero-size rect is floored at 1x1 for getImageData', AT.rotBox({ x: 10, y: 10, w: 0, h: 0 }, vr, 1, 0, 100, 100), { x: 10, y: 10, w: 1, h: 1 })
  eq('a fractional rect rounds per field', AT.rotBox({ x: 0.4, y: 0.4, w: 10.2, h: 10.2 }, vr, 1, 0, 100, 100), { x: 0, y: 0, w: 10, h: 10 })
  eq('a negative rect keeps its negative origin', AT.rotBox({ x: -10, y: -10, w: 20, h: 20 }, vr, 1, 0, 100, 100), { x: -10, y: -10, w: 20, h: 20 })
  eq('a rect outside the view is not clamped', AT.rotBox({ x: 500, y: 500, w: 10, h: 10 }, vr, 1, 0, 100, 100), { x: 500, y: 500, w: 10, h: 10 })
  eq('a 1x1 box round-trips its own origin', AT.rotBox({ x: 7, y: 7, w: 1, h: 1 }, vr, 1, 0, 100, 100), { x: 7, y: 7, w: 1, h: 1 })
  for (const [r, k, rot, dw, dh] of [
    [{ x: 0, y: 0, w: 10, h: 20 }, 1, 0, 100, 100],
    [{ x: 10, y: 10, w: 30, h: 30 }, 0.5, 90, 100, 100],
    [{ x: 0, y: 0, w: 20, h: 10 }, 2, 270, 100, 50],
    [{ x: -5, y: -5, w: 0, h: 0 }, 1, 0, 100, 100],
  ]) {
    is(`w,h >= 1 for ${show([r, k, rot])}`, AT.rotBox(r, vr, k, rot, dw, dh),
      (v) => v.w >= 1 && v.h >= 1 && Number.isInteger(v.x) && Number.isInteger(v.y), 'integer, w/h >= 1')
  }
  eq('the return shape is x,y,w,h', Object.keys(AT.rotBox({ x: 1, y: 1, w: 1, h: 1 }, vr, 1, 0, 10, 10)), ['x', 'y', 'w', 'h'])
  // The rect is a required argument: its four corners are read unguarded.
  throws('a null rect throws', () => AT.rotBox(null, vr, 1, 0, 100, 100), /reading 'x'/)
  noThrow('a missing field reads as NaN and rounds to NaN', () => AT.rotBox({ x: 1 }, vr, 1, 0, 100, 100))
})

// ---------------------------------------------------------------------------
section('AnnotationTools.pixelateGrid - the mosaic cell grid')

group('the grid is anchored to the view origin, not to the rect', () => {
  // Documented: "The grid is anchored to the view origin, not to the rect,
  // so the same rect always mosaics into the same cells no matter how it
  // was dragged out." A cell boundary is always vr + n * step, which is what
  // makes a re-crop stable.
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  const a = AT.pixelateGrid({ x: 1, y: 1, w: 7, h: 7 }, vr)
  const b = AT.pixelateGrid({ x: 2, y: 2, w: 7, h: 7 }, vr)
  eq('dragging the rect changes the clipped edge cells only', [a.length, b.length], [9, 9])
  eq('the interior cell boundaries are identical', [a[1].rect.x, a[2].rect.x], [b[1].rect.x, b[2].rect.x])
  eq('the first cell starts where the rect does', [a[0].rect.x, b[0].rect.x], [1, 2])
  eq('the interior cell centres are identical', [a[1].center.x, a[2].center.x], [b[1].center.x, b[2].center.x])
  eq('a cell boundary is a multiple of the step from the view origin',
    [a[1].rect.x, a[2].rect.x, a[4].rect.x], [3, 6, 3])
  eq('a view with a non-zero origin shifts every cell', AT.pixelateGrid({ x: 50, y: 50, w: 9, h: 9 }, { x: 50, y: 50, w: 100, h: 100 })[0].rect,
    { x: 50, y: 50, w: 3, h: 3 })
})

group('the step is 3 at minimum and 127 cells at maximum', () => {
  // Documented: "The step grows with the rect so a full-screen mosaic stays
  // bounded: 127 cells on the long axis at most, and never finer than 3px."
  eq('a 2x2 rect is one 3px cell', AT.pixelateGrid({ x: 0, y: 0, w: 2, h: 2 }, { x: 0, y: 0, w: 100, h: 100 }).length, 1)
  eq('a 10x10 rect is 4x4 cells', AT.pixelateGrid({ x: 0, y: 0, w: 10, h: 10 }, { x: 0, y: 0, w: 100, h: 100 }).length, 16)
  eq('a 9x9 rect is 3x3 cells', AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, { x: 0, y: 0, w: 100, h: 100 }).length, 9)
  eq('a 100x100 rect is 34x34 cells', AT.pixelateGrid({ x: 0, y: 0, w: 100, h: 100 }, { x: 0, y: 0, w: 100, h: 100 }).length, 1156)
  eq('a 10000px mosaic is 127 cells on the long axis',
    AT.pixelateGrid({ x: 0, y: 0, w: 10000, h: 10 }, { x: 0, y: 0, w: 10000, h: 10000 }).length, 127)
  eq('a 10x10000 mosaic is 127 the other way',
    AT.pixelateGrid({ x: 0, y: 0, w: 10, h: 10000 }, { x: 0, y: 0, w: 10000, h: 10000 }).length, 127)
  // The step comes from the long axis, so a 1000x10 mosaic gets 125 columns
  // of 8px - and still 2 rows, because lastX/lastY are ceil()ed rather than
  // floor()ed so a partial edge cell is drawn.
  eq('a 1000x10 mosaic is 125 columns of 2 rows', AT.pixelateGrid({ x: 0, y: 0, w: 1000, h: 10 }, { x: 0, y: 0, w: 1000, h: 1000 }).length, 250)
  eq('never finer than 3px', AT.pixelateGrid({ x: 0, y: 0, w: 3, h: 3 }, { x: 0, y: 0, w: 100, h: 100 }).length, 1)
})

group('cells are clipped to the rect, and edge cells are truncated', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  const off = AT.pixelateGrid({ x: 5, y: 5, w: 4, h: 4 }, vr)
  eq('a rect that starts mid-cell', off[0].rect, { x: 5, y: 5, w: 1, h: 1 })
  eq('and the rest are whole cells', off[1].rect, { x: 6, y: 5, w: 3, h: 1 })
  eq('a centre is clamped into its drawn cell, not the full one', off[0].center, { x: 5, y: 5 })
  const neg = AT.pixelateGrid({ x: -5, y: -5, w: 10, h: 10 }, vr)
  eq('a rect that starts before the view is clipped to the view', neg[0].rect, { x: 0, y: 0, w: 3, h: 3 })
  eq('and its last cell is truncated at the rect', neg[1].rect, { x: 3, y: 0, w: 2, h: 3 })
  const part = AT.pixelateGrid({ x: 95, y: 0, w: 10, h: 4 }, vr)
  eq('a rect overhanging the right edge is clipped', part[2].rect, { x: 99, y: 0, w: 1, h: 3 })
  eq('every cell stays inside the view', part.every((c) => c.rect.x >= 0 && c.rect.x + c.rect.w <= 100), true)
  eq('a cell centre stays inside its own drawn rect',
    AT.pixelateGrid({ x: 1, y: 1, w: 8, h: 8 }, vr).every((c) => c.center.x >= c.rect.x && c.center.x <= c.rect.x + c.rect.w), true)
  eq('a 9x9 rect is tiled exactly', AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, vr).reduce((a, c) => a + c.rect.w * c.rect.h, 0), 81)
  eq('an unaligned 7x7 rect is tiled exactly too', AT.pixelateGrid({ x: 1, y: 1, w: 7, h: 7 }, vr).reduce((a, c) => a + c.rect.w * c.rect.h, 0), 49)
  eq('every cell has a positive size', AT.pixelateGrid({ x: 1, y: 1, w: 8, h: 8 }, vr).every((c) => c.rect.w > 0 && c.rect.h > 0), true)
})

group('an empty or outside rect produces no cells at all', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  eq('a null rect', AT.pixelateGrid(null, vr), [])
  eq('an undefined rect', AT.pixelateGrid(undefined, vr), [])
  eq('no arguments at all', AT.pixelateGrid(), [])
  eq('a zero-size rect', AT.pixelateGrid({ x: 5, y: 5, w: 0, h: 0 }, vr), [])
  eq('a negative-size rect', AT.pixelateGrid({ x: 5, y: 5, w: -5, h: -5 }, vr), [])
  eq('a rect entirely after the view', AT.pixelateGrid({ x: 200, y: 200, w: 10, h: 10 }, vr), [])
  eq('a rect entirely before the view', AT.pixelateGrid({ x: -500, y: -500, w: 10, h: 10 }, vr), [])
  // A rect that only touches the far edge has no area in the view.
  eq('a rect touching the right edge exactly', AT.pixelateGrid({ x: 100, y: 0, w: 10, h: 4 }, vr), [])
  eq('a rect touching the bottom edge exactly', AT.pixelateGrid({ x: 0, y: 100, w: 4, h: 10 }, vr), [])
  eq('a rect outside a shifted view', AT.pixelateGrid({ x: 0, y: 0, w: 10, h: 10 }, { x: 50, y: 50, w: 100, h: 100 }), [])
  eq('a rect inside a shifted view', AT.pixelateGrid({ x: 50, y: 50, w: 10, h: 10 }, { x: 50, y: 50, w: 100, h: 100 }).length, 16)
  eq('a NaN rect field', AT.pixelateGrid({ x: NaN, y: 0, w: 10, h: 10 }, vr), [])
  throws('a null view throws - the view rect is required', () => AT.pixelateGrid({ x: 0, y: 0, w: 1, h: 1 }, null), /reading 'x'/)
  is('the result is always an array', [AT.pixelateGrid(null, vr), AT.pixelateGrid({ x: 0, y: 0, w: 1, h: 1 }, vr)],
    (v) => v.every(Array.isArray), 'arrays')
  is('every cell has a rect and a centre', AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, vr),
    (v) => v.every((c) => deepEqual(Object.keys(c).sort(), ['center', 'rect'])), 'rect and center keys')
})

// ---------------------------------------------------------------------------
section('AnnotationTools - the mosaic and blur sample offsets')

group('pixelateBox maps the rect corners through the export transform', () => {
  const vr = { x: 0, y: 0, w: 100, h: 50 }
  eq('unrotated, at the origin', AT.pixelateBox({ x: 0, y: 0, w: 10, h: 20 }, vr, { w: 100, h: 50 }, 0), { x: 0, y: 0, w: 10, h: 20 })
  eq('unrotated, in the middle', AT.pixelateBox({ x: 40, y: 20, w: 20, h: 20 }, vr, { w: 100, h: 50 }, 0), { x: 40, y: 20, w: 20, h: 20 })
  // The box is clipped to the export surface, so a rect that runs off the
  // bottom of a 50px view reads the surface edge rather than overshooting.
  eq('a rect clipped by the surface', AT.pixelateBox({ x: 40, y: 40, w: 20, h: 20 }, vr, { w: 100, h: 50 }, 0), { x: 40, y: 40, w: 20, h: 10 })
  // A quarter turn maps through the swapped export size, so the box moves to
  // the mirrored half of the surface.
  eq('a quarter turn', AT.pixelateBox({ x: 0, y: 0, w: 20, h: 10 }, vr, { w: 50, h: 100 }, 90), { x: 40, y: 0, w: 10, h: 20 })
  eq('a quarter turn in the middle', AT.pixelateBox({ x: 30, y: 10, w: 20, h: 10 }, vr, { w: 50, h: 100 }, 90), { x: 30, y: 30, w: 10, h: 20 })
  eq('a three-quarter turn', AT.pixelateBox({ x: 0, y: 0, w: 20, h: 10 }, vr, { w: 50, h: 100 }, 270), { x: 0, y: 80, w: 11, h: 20 })
  eq('a half turn', AT.pixelateBox({ x: 0, y: 0, w: 20, h: 10 }, vr, { w: 100, h: 50 }, 180), { x: 80, y: 39, w: 20, h: 11 })
  eq('the whole surface', AT.pixelateBox({ x: 0, y: 0, w: 100, h: 50 }, vr, { w: 100, h: 50 }, 0), { x: 0, y: 0, w: 100, h: 50 })
  eq('a rotated whole surface', AT.pixelateBox({ x: 0, y: 0, w: 100, h: 50 }, vr, { w: 100, h: 50 }, 180), { x: 0, y: 0, w: 100, h: 50 })
  eq('a rect larger than the surface is clipped to it', AT.pixelateBox({ x: 0, y: 0, w: 101, h: 51 }, vr, { w: 100, h: 50 }, 0), { x: 0, y: 0, w: 100, h: 50 })
  eq('the near edge is not floored below 0', AT.pixelateBox({ x: -10, y: 0, w: 20, h: 10 }, vr, { w: 100, h: 50 }, 0), { x: 0, y: 0, w: 10, h: 10 })
  eq('the far edge is not beyond the surface', AT.pixelateBox({ x: 95, y: 0, w: 20, h: 10 }, vr, { w: 100, h: 50 }, 0), { x: 95, y: 0, w: 5, h: 10 })
  eq('a fractional rect is floored and ceiled', AT.pixelateBox({ x: 0.4, y: 0.4, w: 10.2, h: 10.2 }, vr, { w: 100, h: 50 }, 0), { x: 0, y: 0, w: 11, h: 11 })
  eq('a view with a non-zero origin maps to the surface origin', AT.pixelateBox({ x: 50, y: 50, w: 10, h: 10 }, { x: 50, y: 50, w: 100, h: 100 }, { w: 100, h: 100 }, 0), { x: 0, y: 0, w: 10, h: 10 })
})

group('a mapped box that lands off the export is null', () => {
  // Documented: "Null when the mapped box lands entirely off the export."
  const vr = { x: 0, y: 0, w: 100, h: 50 }
  eq('entirely after the surface', AT.pixelateBox({ x: 500, y: 500, w: 10, h: 10 }, vr, { w: 100, h: 50 }, 0), null)
  eq('entirely before it', AT.pixelateBox({ x: -500, y: -500, w: 10, h: 10 }, vr, { w: 100, h: 50 }, 0), null)
  eq('a zero-size rect has no area to sample', AT.pixelateBox({ x: 0, y: 0, w: 0, h: 0 }, vr, { w: 100, h: 50 }, 0), null)
  eq('a rect that only overlaps one pixel', AT.pixelateBox({ x: 100, y: 50, w: 10, h: 10 }, vr, { w: 100, h: 50 }, 0), null)
  eq('a zero-size surface', AT.pixelateBox({ x: 0, y: 0, w: 10, h: 10 }, vr, { w: 0, h: 0 }, 0), null)
  eq('a negative surface', AT.pixelateBox({ x: 0, y: 0, w: 10, h: 10 }, vr, { w: -10, h: -10 }, 0), null)
  // A non-finite surface is not something the export can produce; the `bw <
  // 1` guard is a comparison, which NaN passes, so the NaN box is returned
  // rather than the null the "entirely off" contract promises. Pinned
  // because a NaN surface would otherwise be indistinguishable from a real
  // box at the call site.
  is('a NaN surface is not caught by the off-surface guard',
    AT.pixelateBox({ x: 0, y: 0, w: 10, h: 10 }, vr, { w: NaN, h: NaN }, 0),
    (v) => Object.values(v).every(Number.isNaN), 'an all-NaN box')
  throws('a null rect throws on its fields', () => AT.pixelateBox(null, vr, { w: 1, h: 1 }, 0), /reading 'x'/)
  noThrow('an undefined rotation', () => AT.pixelateBox({ x: 0, y: 0, w: 1, h: 1 }, vr, { w: 10, h: 10 }, undefined))
  for (const [r, rot] of [
    [{ x: 0, y: 0, w: 10, h: 10 }, 0], [{ x: 40, y: 20, w: 30, h: 20 }, 0],
    [{ x: 0, y: 0, w: 20, h: 10 }, 90], [{ x: 0, y: 0, w: 20, h: 10 }, 180],
  ]) {
    const b = AT.pixelateBox(r, vr, rot === 90 ? { w: 50, h: 100 } : { w: 100, h: 50 }, rot)
    is(`inside the surface for ${show(r)} at ${rot}`, b === null ? 'off' : b,
      (v) => v === 'off' || (v.x >= 0 && v.y >= 0 && v.w >= 1 && v.h >= 1 && v.x + v.w <= 100 && v.y + v.h <= 50),
      'inside the export surface')
  }
})

group('pixelateSamples gives one clamped source span per cell', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  const grid = AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, vr)
  const box = AT.pixelateBox({ x: 0, y: 0, w: 9, h: 9 }, vr, { w: 100, h: 100 }, 0)
  const s = AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, 0, box)
  eq('one sample per cell', s.length, grid.length)
  eq('the cell rect travels with the sample', s[0].rect, { x: 0, y: 0, w: 3, h: 3 })
  // The span is the cell, not a point in it. A single texel per cell is
  // not a sample of the cell: at the step pixelateGrid picks for a large
  // region, anything thinner than a cell misses the centre and the region
  // collapses to a flat slab of the background colour.
  eq('the first cell spans its own rect', s[0].box, { x: 0, y: 0, w: 3, h: 3 })
  eq('the spans are view-relative', s[1].box, { x: 3, y: 0, w: 3, h: 3 })
  eq('every span is inside the box', s.every((v) => v.box.x >= 0 && v.box.x + v.box.w <= box.w && v.box.y >= 0 && v.box.y + v.box.h <= box.h), true)
  // The invariant that makes it a mosaic: every sampled pixel belongs to
  // exactly one cell. Overlapping spans average a neighbour's pixels into
  // a cell, and gaps leave a cell reading part of its neighbour.
  eq('the spans tile the box exactly once', s.reduce((a, v) => a + v.box.w * v.box.h, 0), box.w * box.h)
  // A 1x1 block holds one pixel, so exactly one cell has a span and every
  // other cell has none: a cell that does not overlap the block is not
  // clamped into it, it is skipped, and a null span is what says so.
  const one = AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, 0, { x: 0, y: 0, w: 1, h: 1 })
  eq('a 1x1 block gives one span to one cell', one.filter((v) => v.box !== null).length, 1)
  eq('that span is the single pixel', one.find((v) => v.box !== null).box, { x: 0, y: 0, w: 1, h: 1 })
  eq('the cells off the block have no span', one.every((v) => v.box === null || (v.box.w === 1 && v.box.h === 1)), true)
  eq('a non-array grid', AT.pixelateSamples(null, vr, { w: 1, h: 1 }, 0, box), [])
  eq('an empty grid', AT.pixelateSamples([], vr, { w: 1, h: 1 }, 0, box), [])
  eq('a null box', AT.pixelateSamples(grid, vr, { w: 1, h: 1 }, 0, null), [])
  eq('an undefined box', AT.pixelateSamples(grid, vr, { w: 1, h: 1 }, 0, undefined), [])
  eq('no arguments at all', AT.pixelateSamples(), [])
  // A grid built by pixelateGrid always carries a rect on every cell, and
  // the span is built from that rect alone - a cell with only a centre no
  // longer has anything to read.
  throws('a cell with no rect throws', () => AT.pixelateSamples([{ center: { x: 0, y: 0 } }], vr, { w: 10, h: 10 }, 0, box), /reading 'x'/)
  eq('a string rotation still maps', AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, '0', box), s)
  for (const rot of [0, 90, 180, 270]) {
    const b = AT.pixelateBox({ x: 0, y: 0, w: 9, h: 9 }, vr, { w: 100, h: 100 }, rot)
    is(`every span is inside the box at ${rot}`, AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, rot, b),
      (v) => v.every((o) => o.box.x >= 0 && o.box.x + o.box.w <= b.w && o.box.y >= 0 && o.box.y + o.box.h <= b.h), 'clamped into the box')
  }
  // A rotated cell is covered by the box that contains it, so a quarter
  // turn keeps every cell 3x3 rather than collapsing it to a column. The
  // box has to be the rotated one: read against the unrotated box every
  // cell falls outside it and gets no span at all.
  const turned = AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, 90,
    AT.pixelateBox({ x: 0, y: 0, w: 9, h: 9 }, vr, { w: 100, h: 100 }, 90))
  eq('a quarter turn gives every cell a span', turned.filter((v) => v.box === null).length, 0)
  eq('a quarter turn keeps the cell size', turned.every((v) => v.box.w === 3 && v.box.h === 3), true)
})

group('blurSampleBox reads the grid in unrotated view-relative image pixels', () => {
  // Documented: "Unrotated, because the baked backing is the unrotated
  // image." This is the other source's box, so it is a different transform.
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  const grid = AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, vr)
  eq('the grid extent', AT.blurSampleBox(grid, vr, 100, 100), { x: 0, y: 0, w: 9, h: 9 })
  eq('a shifted view keeps the image coordinates at 0', AT.blurSampleBox(AT.pixelateGrid({ x: 50, y: 50, w: 9, h: 9 }, { x: 50, y: 50, w: 100, h: 100 }), { x: 50, y: 50, w: 100, h: 100 }, 100, 100), { x: 0, y: 0, w: 9, h: 9 })
  eq('an image smaller than the grid clips the box', AT.blurSampleBox(grid, vr, 4, 4), { x: 0, y: 0, w: 4, h: 4 })
  eq('a 1px image still gives a 1px box', AT.blurSampleBox(grid, vr, 1, 1), { x: 0, y: 0, w: 1, h: 1 })
  eq('an empty grid', AT.blurSampleBox([], vr, 100, 100), null)
  eq('a non-array grid', AT.blurSampleBox(null, vr, 100, 100), null)
  eq('no arguments at all', AT.blurSampleBox(), null)
  eq('a grid with one cell', AT.blurSampleBox([{ rect: { x: 10, y: 10, w: 4, h: 4 } }], vr, 100, 100), { x: 10, y: 10, w: 4, h: 4 })
  // Both the view rect and every cell rect are read unguarded: a grid built
  // by pixelateGrid always carries both.
  throws('a null view throws', () => AT.blurSampleBox(grid, null, 100, 100), /reading 'x'/)
  throws('a cell with no rect throws', () => AT.blurSampleBox([{ center: { x: 0, y: 0 } }], vr, 100, 100), /reading 'x'/)
  is('the box is always inside the image', [
    AT.blurSampleBox(grid, vr, 100, 100),
    AT.blurSampleBox(grid, vr, 4, 4),
    AT.blurSampleBox(AT.pixelateGrid({ x: -5, y: -5, w: 20, h: 20 }, vr), vr, 100, 100),
  ], (v) => v.every((b) => b.x >= 0 && b.y >= 0 && b.w >= 1 && b.h >= 1 && b.x + b.w <= 100 && b.y + b.h <= 100), 'inside the image')
})

group('blurSamples and pixelateSamples agree on an unrotated export', () => {
  const vr = { x: 0, y: 0, w: 100, h: 100 }
  const grid = AT.pixelateGrid({ x: 0, y: 0, w: 9, h: 9 }, vr)
  const box = AT.blurSampleBox(grid, vr, 100, 100)
  const bs = AT.blurSamples(grid, vr, box)
  eq('one sample per cell', bs.length, grid.length)
  eq('the first cell spans its own rect', bs[0].box, { x: 0, y: 0, w: 3, h: 3 })
  // The two sources share the grid and, unrotated at 1:1, the same mapping -
  // which is exactly why the box has to be the one belonging to each source.
  eq('they are identical for an unrotated view-relative mapping',
    bs, AT.pixelateSamples(grid, vr, { w: 100, h: 100 }, 0, AT.pixelateBox({ x: 0, y: 0, w: 9, h: 9 }, vr, { w: 100, h: 100 }, 0)))
  eq('every span is inside the box', bs.every((v) => v.box.x >= 0 && v.box.x + v.box.w <= box.w && v.box.y >= 0 && v.box.y + v.box.h <= box.h), true)
  eq('the spans tile the box exactly once', bs.reduce((a, v) => a + v.box.w * v.box.h, 0), box.w * box.h)
  eq('a null box', AT.blurSamples(grid, vr, null), [])
  eq('an undefined box', AT.blurSamples(grid, vr, undefined), [])
  eq('a non-array grid', AT.blurSamples(null, vr, box), [])
  eq('an empty grid', AT.blurSamples([], vr, box), [])
  eq('no arguments at all', AT.blurSamples(), [])
  eq('a 1x1 block gives one span to one cell', AT.blurSamples(grid, vr, { x: 0, y: 0, w: 1, h: 1 }).filter((v) => v.box !== null).length, 1)
  throws('a cell with no rect throws', () => AT.blurSamples([{ center: { x: 0, y: 0 } }], vr, box), /reading 'x'/)
  is('a sample has exactly rect and box', bs[0], (v) => deepEqual(Object.keys(v).sort(), ['box', 'rect']), 'rect, box only')
  // A block that does not start at the surface origin must not widen a
  // cell: both edges move into the block, or a cell would average in the
  // pixels of the offset between them. Built so the block really is
  // offset - a grid at image 50 inside a 100px surface, not a grid that
  // merely sits away from the view origin.
  const vrAt = { x: 50, y: 50, w: 100, h: 100 }
  const offGrid = AT.pixelateGrid({ x: 100, y: 100, w: 9, h: 9 }, vrAt)
  const offBox = AT.blurSampleBox(offGrid, vrAt, 100, 100)
  eq('the offset block', offBox, { x: 50, y: 50, w: 9, h: 9 })
  const shifted = AT.blurSamples(offGrid, vrAt, offBox)
  eq('an offset block gives every cell a span', shifted.filter((v) => v.box === null).length, 0)
  eq('an offset block keeps the cell size', shifted.every((v) => v.box.w === v.rect.w && v.box.h === v.rect.h), true)
  eq('an offset block still tiles once', shifted.reduce((a, v) => a + v.box.w * v.box.h, 0), offBox.w * offBox.h)
})

group('cellMean averages the pixels a cell covers', () => {
  // The average of the cell, not one texel in it: a cell whose centre
  // happens to land between two features would otherwise report the
  // background for a cell that is mostly neither feature.
  const box = { x: 0, y: 0, w: 8, h: 4 }
  const px = { data: new Uint8ClampedArray(8 * 4 * 4), width: 8, height: 4 }
  for (let y = 0; y < 4; y++) {
    for (let x = 0; x < 8; x++) {
      const o = (y * 8 + x) * 4
      px.data[o] = x < 4 ? 200 : 0
      px.data[o + 1] = 0
      px.data[o + 2] = x < 4 ? 0 : 200
      px.data[o + 3] = 255
    }
  }
  eq('a uniform cell is that colour', AT.cellMean(px, box, { x: 0, y: 0, w: 4, h: 4 }), [200, 0, 0])
  eq('a uniform cell on the other half', AT.cellMean(px, box, { x: 4, y: 0, w: 4, h: 4 }), [0, 0, 200])
  eq('a cell straddling both is their average', AT.cellMean(px, box, { x: 2, y: 0, w: 4, h: 4 }), [100, 0, 100])
  eq('one pixel is its own mean', AT.cellMean(px, box, { x: 0, y: 0, w: 1, h: 1 }), [200, 0, 0])
  eq('a span past the block clamps into it', AT.cellMean(px, box, { x: 6, y: 2, w: 40, h: 40 }), [0, 0, 200])
  eq('a span entirely off the block', AT.cellMean(px, box, { x: 40, y: 40, w: 4, h: 4 }), null)
  eq('a zero-width span', AT.cellMean(px, box, { x: 2, y: 0, w: 0, h: 4 }), null)
  eq('a null span', AT.cellMean(px, box, null), null)
  eq('an undefined span', AT.cellMean(px, box, undefined), null)
  eq('no pixels at all', AT.cellMean(px, box), null)
  eq('a null pixel block', AT.cellMean(null, box, { x: 0, y: 0, w: 2, h: 2 }), null)
  eq('a pixel block with no data', AT.cellMean({ width: 8, height: 4 }, box, { x: 0, y: 0, w: 2, h: 2 }), null)
  eq('a pixel block with truncated data', AT.cellMean({ data: new Uint8ClampedArray(3) }, box, { x: 0, y: 0, w: 2, h: 2 }), null)
  // A single texel is the bug this replaced: a 1px feature at the left edge
  // of a 3x3 cell is three ninths of it, and a centre-only sample would
  // have reported plain black for a cell that is a third bright.
  const thin = { data: new Uint8ClampedArray(3 * 3 * 4), width: 3, height: 3 }
  for (let y = 0; y < 3; y++) {
    const o = (y * 3) * 4
    thin.data[o] = 255
    thin.data[o + 3] = 255
  }
  eq('a thin feature inside a cell is found', AT.cellMean(thin, { x: 0, y: 0, w: 3, h: 3 }, { x: 0, y: 0, w: 3, h: 3 }), [85, 0, 0])
})


// ---------------------------------------------------------------------------
section('AnnotationTools - text metrics and selection resize')

group('textPad is a proportional inset with a 2..12 clamp', () => {
  eq('a collapsed box', AT.textPad(0), 2)
  eq('a tiny box', AT.textPad(5), 2)
  eq('just under the floor crossover', AT.textPad(13.3), 2)
  eq('a normal box', AT.textPad(26), 4)
  eq('a giant box', AT.textPad(100), 12)
  eq('a negative height is the floor', AT.textPad(-50), 2)
  eq('a fractional height rounds first', AT.textPad(26.4), 4)
  eq('a height just above the cap stays under it', AT.textPad(1000), 12)
  is('never below the floor', [0, 1, 5, 13, 20, 50, 100, 1000].map(AT.textPad), (v) => v.every((p) => p >= 2), '>= 2')
  is('never above the cap', [0, 1, 5, 13, 20, 50, 100, 1000].map(AT.textPad), (v) => v.every((p) => p <= 12), '<= 12')
  // There is no finite guard here, unlike most of the file: a non-finite
  // height propagates instead of collapsing to the floor.
  is('a NaN height propagates rather than flooring', AT.textPad(NaN), (v) => Number.isNaN(v), 'NaN')
  eq('an undefined height propagates too', Number.isNaN(AT.textPad(undefined)), true)
  approx('a fractional height is rounded', AT.textPad(27.4), 4, 1e-12)
  approx('a 40px box is 15% of 40', AT.textPad(40), 6, 1e-12)
  noThrow('a string height', () => AT.textPad('20'))
  noThrow('a null height', () => AT.textPad(null))
})

group('commitFontSize inverts the on-screen size through the scale', () => {
  eq('1:1', AT.commitFontSize(24, 1), 24)
  eq('2x zoom commits half', AT.commitFontSize(24, 2), 12)
  eq('0.5x zoom commits double', AT.commitFontSize(1, 0.5), 2)
  // The caller passes textPx = fontSize * scale, so committing that pair
  // must give the original font size back.
  for (const fs of [8, 12, 24, 48]) {
    for (const k of [0.1, 0.5, 1, 1.25, 2, 4]) {
      eq(`fontSize ${fs} at scale ${k} round-trips`, AT.commitFontSize(fs * k, k), fs)
    }
  }
  // Documented: "The scale is floored rather than rejected so a collapsed
  // stage commits a minimum-size stroke instead of dividing by zero." A
  // collapsed stage makes textPx 0 too, so the pair below is the real one.
  eq('a collapsed stage commits the minimum', AT.commitFontSize(0, 0), 1)
  eq('the floor at 0.001 is what avoids the division', AT.commitFontSize(1, 0), 1000)
  eq('a negative scale is floored the same way', AT.commitFontSize(1, -2), 1000)
  eq('a fractional result rounds', AT.commitFontSize(5, 0.3), 17)
  // A 0 or negative on-screen size is floored to 1 rather than committed as 0.
  eq('a 0px text commits 1', AT.commitFontSize(0, 1), 1)
  eq('a negative text commits 1', AT.commitFontSize(-10, 1), 1)
  eq('a NaN scale propagates rather than flooring', Number.isNaN(AT.commitFontSize(24, NaN)), true)
  eq('an undefined scale propagates', Number.isNaN(AT.commitFontSize(24, undefined)), true)
  eq('a NaN size propagates', Number.isNaN(AT.commitFontSize(NaN, 1)), true)
  eq('no arguments at all propagates too', Number.isNaN(AT.commitFontSize()), true)
  noThrow('a string scale', () => AT.commitFontSize(24, '2'))
  noThrow('a string size', () => AT.commitFontSize('24', 2))
  is('the result is always a positive integer', [AT.commitFontSize(24, 1), AT.commitFontSize(0, 0), AT.commitFontSize(-5, 1), AT.commitFontSize(1, 0)],
    (v) => v.every((x) => Number.isInteger(x) && x >= 1), 'integer >= 1')
})

group('resizeFromHandle moves the dragged side and flips past the fixed one', () => {
  const O = { x: 0, y: 0, w: 100, h: 50 }
  // spot is a handleSpots entry, so fx and fy are 0, 0.5 or 1.
  eq('the top-left corner', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, 20, 10), { x: 20, y: 10, w: 80, h: 40 })
  eq('the top-right corner', AT.resizeFromHandle(O, { fx: 1, fy: 0 }, 80, 10), { x: 0, y: 10, w: 80, h: 40 })
  eq('the bottom-right corner', AT.resizeFromHandle(O, { fx: 1, fy: 1 }, 80, 40), { x: 0, y: 0, w: 80, h: 40 })
  eq('the bottom-left corner', AT.resizeFromHandle(O, { fx: 0, fy: 1 }, 20, 40), { x: 20, y: 0, w: 80, h: 40 })
  eq('the top edge midpoint moves y only', AT.resizeFromHandle(O, { fx: 0.5, fy: 0 }, 50, 10), { x: 0, y: 10, w: 100, h: 40 })
  eq('the right edge midpoint moves x only', AT.resizeFromHandle(O, { fx: 1, fy: 0.5 }, 80, 25), { x: 0, y: 0, w: 80, h: 50 })
  eq('the bottom edge midpoint', AT.resizeFromHandle(O, { fx: 0.5, fy: 1 }, 50, 40), { x: 0, y: 0, w: 100, h: 40 })
  eq('the left edge midpoint', AT.resizeFromHandle(O, { fx: 0, fy: 0.5 }, 20, 25), { x: 20, y: 0, w: 80, h: 50 })
  eq('the centre handle moves nothing', AT.resizeFromHandle(O, { fx: 0.5, fy: 0.5 }, 500, 500), O)
  eq('a spot with no fx moves nothing', AT.resizeFromHandle(O, {}, 5, 5), O)
  eq('an fx that is not a handle fraction moves nothing', AT.resizeFromHandle(O, { fx: 0.25, fy: 0.25 }, 5, 5), O)
  eq('an x-only handle ignores my', AT.resizeFromHandle(O, { fx: 0, fy: 0.5 }, 5, 500), { x: 5, y: 0, w: 95, h: 50 })
  eq('a y-only handle ignores mx', AT.resizeFromHandle(O, { fx: 0.5, fy: 0 }, 500, 5), { x: 0, y: 5, w: 100, h: 45 })
})

group('dragging past the fixed side flips the rect through min/max', () => {
  const O = { x: 0, y: 0, w: 100, h: 50 }
  // Documented: "dragging past it flips the rect through min/max", so the
  // box grows the other way rather than inverting.
  eq('past the left edge', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, -20, 10), { x: -20, y: 10, w: 120, h: 40 })
  eq('past the right edge', AT.resizeFromHandle(O, { fx: 1, fy: 0 }, 130, 10), { x: 0, y: 10, w: 130, h: 40 })
  eq('past the top edge', AT.resizeFromHandle(O, { fx: 0.5, fy: 0 }, 50, -20), { x: 0, y: -20, w: 100, h: 70 })
  eq('past the bottom edge', AT.resizeFromHandle(O, { fx: 0.5, fy: 1 }, 50, 80), { x: 0, y: 0, w: 100, h: 80 })
  eq('past both edges', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, -30, -30), { x: -30, y: -30, w: 130, h: 80 })
  // Exactly onto the fixed side collapses the axis to zero rather than
  // inverting it, so the caller gets a degenerate rect it can discard.
  eq('onto the opposite corner', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, 100, 50), { x: 100, y: 50, w: 0, h: 0 })
  eq('onto the fixed x only', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, 100, 0), { x: 100, y: 0, w: 0, h: 50 })
  eq('dragging back to the original corner is a no-op', AT.resizeFromHandle(O, { fx: 0, fy: 0 }, 0, 0), O)
  eq('a zero-size original grows from its point', AT.resizeFromHandle({ x: 5, y: 5, w: 0, h: 0 }, { fx: 1, fy: 1 }, 10, 10), { x: 5, y: 5, w: 5, h: 5 })
  eq('a zero-size original dragged back collapses', AT.resizeFromHandle({ x: 5, y: 5, w: 0, h: 0 }, { fx: 0, fy: 0 }, 5, 5), { x: 5, y: 5, w: 0, h: 0 })
  eq('a negative original', AT.resizeFromHandle({ x: -10, y: -10, w: 20, h: 20 }, { fx: 0, fy: 0 }, -20, -20), { x: -20, y: -20, w: 30, h: 30 })
  throws('no arguments at all throws - the original rect is required', () => AT.resizeFromHandle(), /reading 'x'/)
  for (const [o, spot, mx, my] of [
    [O, { fx: 0, fy: 0 }, 20, 10], [O, { fx: 1, fy: 1 }, -50, -50], [O, { fx: 0, fy: 0 }, 100, 50],
    [{ x: -10, y: -10, w: 20, h: 20 }, { fx: 0.5, fy: 1 }, 0, -30],
  ]) {
    const r = AT.resizeFromHandle(o, spot, mx, my)
    is(`w,h >= 0 for ${show(spot)} at (${mx}, ${my})`, r, (v) => v.w >= 0 && v.h >= 0 && Number.isFinite(v.x), 'non-negative size')
  }
  // The original rect and the handle spot are both required arguments; a
  // missing spot moves nothing rather than throwing, but a null one does.
  throws('a null original throws', () => AT.resizeFromHandle(null, { fx: 0, fy: 0 }, 0, 0), /reading 'x'/)
  throws('a null spot throws', () => AT.resizeFromHandle(O, null, 0, 0), /reading 'fx'/)
  noThrow('an empty spot moves nothing', () => AT.resizeFromHandle(O, {}, 0, 0))
  noThrow('a NaN pointer', () => AT.resizeFromHandle(O, { fx: 0, fy: 0 }, NaN, NaN))
  eq('the return shape is x,y,w,h', Object.keys(AT.resizeFromHandle(O, { fx: 0, fy: 0 }, 5, 5)), ['x', 'y', 'w', 'h'])
})

finish()
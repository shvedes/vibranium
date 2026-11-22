#!/usr/bin/env node
// Suite: ColorPicker capture grace, scalar readout placement and one preview
// report (WAL-5, WAL-6, WAL-13).
//
//   shell/features/bar/modules/ColorPicker/ColorPickerOverlay.qml
//   shell/features/bar/modules/ColorPicker/PreviewPlacement.js
//   shell/features/bar/modules/ColorPicker/ColorPickerIsland.qml
//
// All three findings ride compositor edges or the pointer path, neither of
// which exists in this node-only harness. The mechanism is pinned in source
// and the placement arithmetic on its pure scalar API; the frame the
// compositor actually maps and the drag that actually reports need a live
// shell. No live claim is made here.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, skip, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const CP = path.join(SHELL_DIR, 'features', 'bar', 'modules', 'ColorPicker')
const OVERLAY = fs.readFileSync(path.join(CP, 'ColorPickerOverlay.qml'), 'utf8')
const PLACEMENT = fs.readFileSync(path.join(CP, 'PreviewPlacement.js'), 'utf8')
const ISLAND = fs.readFileSync(path.join(CP, 'ColorPickerIsland.qml'), 'utf8')

const PP = loadLib(path.join(CP, 'PreviewPlacement.js'))

// Boolean assertions keep a failed source check to one line: a dump of a
// 900-line QML file on every failure hides which guard actually broke.
const has = (label, haystack, needle) => eq(label, haystack.includes(needle), true)
const absent = (label, haystack, needle) => eq(label, haystack.includes(needle), false)
const reHas = (label, haystack, re) => eq(label, re.test(haystack), true)
const reAbsent = (label, haystack, re) => eq(label, re.test(haystack), false)

// Lift a function body by brace matching so nested blocks survive. The
// shipped file is the only source of truth; nothing is copied in here.
function liftFunction(src, name) {
  const at = src.indexOf(`function ${name}(`)
  if (at < 0) return ''
  const brace = src.indexOf('{', at)
  if (brace < 0) return ''
  let depth = 0
  for (let j = brace; j < src.length; j++) {
    if (src[j] === '{') depth++
    if (src[j] === '}') {
      depth--
      if (depth === 0) return src.slice(brace + 1, j)
    }
  }
  return ''
}

function count(haystack, needle) {
  return haystack.split(needle).length - 1
}

const REPORT_BODY = liftFunction(ISLAND, '_reportPreview')
const SET_HUE_BODY = liftFunction(ISLAND, 'setHue')
const APPLY_CODE_BODY = liftFunction(ISLAND, '_applyCode')

suite('color-picker', 'WAL-5 capture grace, WAL-6 scalar placement, WAL-13 one report')

// ======================================================================
section('WAL-5 - one compositor grace, then the stop edge')
group('the retry ladder is gone', () => {
  absent('no attempt property on the view', OVERLAY, 'property int attempts')
  absent('no attempt reads', OVERLAY, 'view.attempts')
  reAbsent('no eight-attempt budget', OVERLAY, /attempts\s*>=\s*8/)
  reAbsent('no second interval in the trigger', OVERLAY, /capTimer\.interval\s*=\s*250/)
  reAbsent('no repeating timer', OVERLAY, /repeat:\s*true/)
})
group('the grace is one shot and the stop edge owns the retries', () => {
  has('capTimer is single-shot', OVERLAY, 'repeat: false')
  has('map arms the grace', OVERLAY, 'capTimer.restart()')
  has('close disarms it', OVERLAY, 'capTimer.stop()')
  has('the trigger captures once', OVERLAY, 'view.captureFrame()')
  has('the stop edge re-requests', OVERLAY,
    'if (overlay.visible && !view.hasContent) view.captureFrame()')
  has('the grace reason is documented', OVERLAY, 'no recording context')
})

// ======================================================================
section('WAL-6 - scalar placement with no per-sample objects')
group('the pure API is scalars in, scalars out', () => {
  eq('placeX is exported', typeof PP.placeX, 'function')
  eq('placeY is exported', typeof PP.placeY, 'function')
  eq('side selection is exported', typeof PP.side, 'function')
  reAbsent('the old object API is gone', PLACEMENT, /function place\(/)
  reAbsent('no room object', PLACEMENT, /\bconst room\s*=/)
  reAbsent('no order array', PLACEMENT, /\bconst order\s*=/)
  reAbsent('no returned object', PLACEMENT, /return\s*\{/)
})
group('the QML binds two scalar calls, no scratch object', () => {
  absent('no spot property', OVERLAY, 'property var spot')
  has('x binds placeX', OVERLAY, 'PreviewPlacement.placeX(')
  has('y binds placeY', OVERLAY, 'PreviewPlacement.placeY(')
  reAbsent('no box literal at the call site', OVERLAY, /PreviewPlacement\.place\(\s*\{/)
})
group('the scalar answers match the old geometry', () => {
  const x = PP.placeX(700, 400, 150, 150, 140, 26, 1600, 900, 10)
  const y = PP.placeY(700, 400, 150, 150, 140, 26, 1600, 900, 10)
  eq('top placement x', x, 705)
  eq('top placement y', y, 364)
  eq('bottom placement y', PP.placeY(700, 0, 150, 75, 140, 26, 1600, 900, 10), 85)
  eq('left placement x', PP.placeX(1450, 0, 150, 150, 140, 26, 1600, 180, 10), 1300)
  eq('clamped x', PP.placeX(0, 200, 20, 150, 300, 26, 1600, 900, 10), 0)
})

// ======================================================================
section('WAL-13 - one report from one setter pipeline')
group('there is a single report call site', () => {
  eq('one _reportPreview call', count(ISLAND, 'root._reportPreview()'), 1)
  reAbsent('no hue-change report', ISLAND, /onHueChanged[^\n]*_reportPreview/)
  absent('no hue change handler at all', ISLAND, 'onHueChanged')
  has('the one call rides picked', ISLAND,
    'onPickedChanged: {\n    root._reportPreview()')
})
group('the report reads the live pair and keeps both states', () => {
  reHas('the report body is present', REPORT_BODY, /reportWorking/)
  has('reports live picked', REPORT_BODY, 'root.picked')
  has('reports live hue', REPORT_BODY, 'root.hue')
  has('hue is still its own state', ISLAND, 'property real hue: 0')
  has('restore still applies both', ISLAND, 'root.hue = w.hue')
})
group('hue is written before picked wherever both move', () => {
  for (const [name, body] of [['setHue', SET_HUE_BODY], ['_applyCode', APPLY_CODE_BODY]]) {
    const h = body.indexOf('root.hue =')
    const p = body.indexOf('root.picked =')
    eq(`${name} writes hue first`, h >= 0 && p > h, true)
  }
})

skip('a real layer-surface map and a real pointer drag',
  'needs a compositor and a screencopy backend; source + pure arithmetic pin the mechanism')

finish()

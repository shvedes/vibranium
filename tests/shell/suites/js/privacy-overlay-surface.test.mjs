#!/usr/bin/env node
// Suite: the privacy dot surface never resizes on a dot animation frame.
//
//   shell/features/bar/PrivacyOverlay.qml    the layer surface and its dot row
//
// A LayerSurface cannot be constructed under QT_QPA_PLATFORM=offscreen, so
// this suite reads the shipped QML and evaluates the surface expressions with
// a small model. It pins the mechanism that made concurrent bar animations
// stutter: the dots' slot widths animate, so a surface sized from the live
// cluster wrote a new width to the compositor on every frame of every reveal,
// reconfiguring the layer surface and stalling the GUI thread.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const SRC = fs.readFileSync(
  path.join(SHELL_DIR, 'features', 'privacy', 'PrivacyOverlay.qml'), 'utf8')

// The surface-level assignments carry two spaces of indent; the Dot slots
// and the content wrapper carry four. Take the first match of each.
const surfaceWidth = (SRC.match(/^  width:\s*(.+)$/m) || [])[1] || ''
const surfaceHeight = (SRC.match(/^  height:\s*(.+)$/m) || [])[1] || ''
const contentX = (SRC.match(/^    x:\s*(.+)$/m) || [])[1] || ''
const dotWidth = (SRC.match(/^    width:\s*(.+)$/m) || [])[1] || ''
const dotBehavior = (SRC.match(/    Behavior on width\s*\{([^}]*)\}/m) || [])[1] || ''

const evalExpr = (expr, root, Ui) =>
  new Function('root', 'Ui', `return (${expr})`)(root, Ui)

suite('bar/privacy-overlay-surface', 'the capture dots animate inside a fixed surface')

section('the surface size is constant, the dots animate inside it')

group('the compositor geometry does not follow the animated cluster', () => {
  notMatch('surface width ignores the live cluster', surfaceWidth, /\bclusterW\b/)
  notMatch('surface height ignores the live cluster', surfaceHeight, /\bclusterH\b/)
  contains('width is the whole dot set at maximum', surfaceWidth, 'dotCount * (root.dotSize + root.dotGap)')
  contains('height is one dot plus insets', surfaceHeight, 'root.dotSize + 2 * Ui.s')
  match('the dot count is declared', SRC, /readonly property int dotCount: 3/)
  contains('the content docks to the anchored corner', contentX, 'root.width - root.clusterW - Ui.s')
  notMatch('the content no longer assumes a left-edge surface', contentX, /^Ui\.s$/)
  contains('the dot slot still animates its width', dotBehavior, 'NumberAnimation')
  contains('the dot width still drives the reveal', dotWidth, 'dot.on ?')
})

group('the surface size never changes as dots light up', () => {
  const Ui = { s: 8 }
  const root = { dotCount: 3, dotSize: 6, dotGap: 5, clusterW: 0, clusterH: 6, width: 49 }
  const expectedW = 3 * (6 + 5) + 2 * 8
  eq('the surface is sized for all three dots', evalExpr(surfaceWidth, root, Ui), expectedW)
  eq('the surface height is one dot', evalExpr(surfaceHeight, root, Ui), 6 + 16)

  for (const clusterW of [0, 11, 22, 33]) {
    root.clusterW = clusterW
    eq(`width holds at clusterW=${clusterW}`, evalExpr(surfaceWidth, root, Ui), expectedW)
  }
  eq('a left-edge surface keeps the plain inset', evalExpr(contentX, { ...root, dotOnLeftEdge: true }, Ui), 8)
  eq('a right-edge surface docks the cluster to the corner',
    evalExpr(contentX, { ...root, dotOnLeftEdge: false }, Ui), 49 - 33 - 8)
})

finish()

#!/usr/bin/env node
// Suite: animated geometry must not drive compositor or animation state.
//
//   shell/features/notifications/NotificationsView.qml   input mask box
//   shell/common/ui/IslandHost.qml                       notification clearance
//   shell/features/annotations/AnnotationEditor.qml      crop veil canvas
//   shell/common/LyricsPane.qml                          deferred cue follow
//
// These QML surfaces cannot be constructed under QT_QPA_PLATFORM=offscreen, so
// the suite reads the shipped sources and pins the mechanism of each fix: a
// tween's per-frame value never reaches a layer-surface property, a shared
// state publish, a full canvas repaint, or an animation restart.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const read = (...parts) => fs.readFileSync(path.join(SHELL_DIR, ...parts), 'utf8')
const NOTIFS = read('features', 'notifications', 'NotificationsView.qml')
const ISLAND = read('common', 'ui', 'IslandHost.qml')
const EDITOR = read('features', 'annotations', 'AnnotationEditor.qml')
const LYRICS = read('common', 'LyricsPane.qml')

const mask = (NOTIFS.match(/  mask: Region \{([\s\S]*?)\n  \}/) || [])[1] || ''
const publish = (ISLAND.match(/DesktopLayoutState\.publishIsland\(islandName, root\.open,[^\n]+/) || [])[0] || ''
const veil = (EDITOR.match(/    Canvas \{\n      id: veilCanvas([\s\S]*?)\n    \}/) || [])[1] || ''
const boardPaint = (EDITOR.match(/    Canvas \{\n      id: board([\s\S]*?)\n    \}/) || [])[1] || ''
const centre = (LYRICS.match(/  function _centre\(index\) \{([\s\S]*?)\n  \}/) || [])[1] || ''

suite('shell/per-frame-sync', 'animated geometry stays off frame-critical state')

section('the four fixes')

group('the notification mask uses the settled box height', () => {
  contains('the mask is explicit scalars, not the animating Item', NOTIFS, 'mask: Region {')
  notMatch('the mask no longer tracks the pile Item', NOTIFS, /mask: Region \{ item: pile \}/)
  contains('height is the settled target', mask, 'Notifications.pileHeight()')
  contains('bottom y is dock minus the settled height', mask, 'win.height - win.bottomInset - Notifications.pileHeight()')
  notMatch('the mask does not read the animated pile.height', mask, /pile\.height/)
})

group('the island publishes the settled footprint', () => {
  contains('the publish uses the settled top edge', publish, 'clearY')
  notMatch('the publish no longer uses the live tween height', publish, /parkH/)
  match('clearY is derived from the destination height', ISLAND, /clearY = Range\.clamp\([\s\S]*?barH - h - root\.margin/)
  contains('the live card still parks from its own height', ISLAND, 'cardItem.height > 0')
})

group('the crop veil paints on its own canvas', () => {
  match('a veil canvas exists', EDITOR, /Canvas \{\s*\n\s*id: veilCanvas/)
  contains('the veil is cheap fillRects', veil, 'ctx.fillRect(')
  contains('the veil still uses the document transform', veil, 'editor._boardPaintK')
  contains('the veil clears before bailing at zero opacity', veil, 'ctx.clearRect(')
  contains('the opacity change repaints only the veil', EDITOR, 'onCropDimOpacityChanged: veilCanvas.requestPaint()')
  notMatch('the ink canvas no longer fills the dim veil', boardPaint, /editor\._cropDimRect !== null/)
})

group('the lyrics follow is coalesced and re-aims', () => {
  match('a pending flag guards the follow', LYRICS, /property bool _followPending: false/)
  match('the handler queues instead of posting each time', LYRICS, /onHeightChanged: root\._queueFollow\(\)/)
  eq('every follow post goes through the queue', (LYRICS.match(/Qt\.callLater\(root\._follow\)/g) || []).length, 0)
  contains('the pending flag is cleared on the queued turn', LYRICS, 'root._followPending = false')
  contains('a running scroll is re-aimed, not restarted', centre, 'if (scrollTo.running)')
  notMatch('the glide branch no longer stops before re-aiming', centre, /const row = view\.itemAtIndex\(index\)\n\s*scrollTo\.stop\(\)/)
})

finish()

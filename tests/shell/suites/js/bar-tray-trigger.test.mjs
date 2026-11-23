#!/usr/bin/env node
// Suite: the tray's own chevron trigger and its drag freeze (BAR-4).
//
//   shell/features/bar/modules/Tray/Tray.qml   the trigger, latch and affordance
//   shell/features/bar/BarView.qml             the per-window drag grace
//   shell/features/bar/modules/Session/Session.qml  the independent power button
//   shell/features/bar/Bar.qml                 standalone slots, no pin
//   shell/common/settings/catalog.jsonc        default order and toggles
//
// Limitation: BarView is a LayerSurface and Quickshell.screens is empty under
// QT_QPA_PLATFORM=offscreen, so no window can be constructed headlessly and no
// synthesized MouseArea hover is available. This suite reads the real QML,
// lifts the trigger expression out of it, and drives it over a hover/drag
// timeline. Compositor delivery of the hover and the slide animation stay
// source-level only.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const TRAY = path.join(SHELL, 'features', 'bar', 'modules', 'Tray', 'Tray.qml')
const BARVIEW = path.join(SHELL, 'features', 'bar', 'BarView.qml')
const SESSION = path.join(SHELL, 'features', 'bar', 'modules', 'Session', 'Session.qml')
const BAR = path.join(SHELL, 'features', 'bar', 'Bar.qml')
const CATALOG = path.join(SHELL, 'common', 'settings', 'catalog.jsonc')

const tray = fs.readFileSync(TRAY, 'utf8')
const barView = fs.readFileSync(BARVIEW, 'utf8')
const session = fs.readFileSync(SESSION, 'utf8')
const bar = fs.readFileSync(BAR, 'utf8')
const catalog = fs.readFileSync(CATALOG, 'utf8')

// The trigger is one expression in Tray.qml so it can be lifted verbatim.
const TRIGGER_BODY_RE = /function triggerActive\(\)\s*\{([\s\S]*?)\n  \}/
const TRIGGER_RE = /return\s+(chevronArea\.containsMouse\s*===\s*true)/
const triggerBody = (tray.match(TRIGGER_BODY_RE) || [])[1] || ''
const trigger = (triggerBody.match(TRIGGER_RE) || [])[1] || ''

const DRAG_RE = /readonly\s+property\s+bool\s+dragMode:\s*root\.windowFlag\("recentDragActive"\)/
const TRIGGER_HOVERED_RE = /readonly\s+property\s+bool\s+triggerHovered:\s*!root\.dragMode\s*&&\s*!root\.hoverInvalidated\s*&&\s*root\.triggerActive\(\)/
const INVALIDATE_RE = /root\.hoverInvalidated\s*=\s*true/
const CLEAR_INVALIDATION_RE = /if \(containsMouse && !root\.dragMode\)\s*root\.hoverInvalidated\s*=\s*false/
const OPEN_RE = /readonly\s+property\s+bool\s+open:\s*!root\.dragMode\s*&&\s*\(root\.hoverLatch\s*\|\|\s*trayMenu\.open\)/
const LATCH_DROP_RE = /onDragModeChanged:\s*if \(root\.dragMode\)\s*\{([\s\S]*?)\n  \}/
const latchDrop = (tray.match(LATCH_DROP_RE) || [])[1] || ''

// One turn of the derivation: the chevron publishes hover, the drag flag
// wins, and the latch either holds (hover/menu) or runs out over one grace
// step. `open` is then derived from the latch and the menu, never stored.
const fresh = () => ({
  chevronHovered: false,
  recentDragActive: false,
  menuOpen: false,
  wasHovered: false,
  wasDragging: false,
  triggerActive: false,
  dragMode: false,
  triggerHovered: false,
  hoverInvalidated: false,
  hoverLatch: false,
  grace: 0,
  open: false,
})

function step(s) {
  s.dragMode = s.recentDragActive === true
  if (s.dragMode && !s.wasDragging) {
    s.hoverInvalidated = true
    s.hoverLatch = false
  }
  if (s.chevronHovered && !s.wasHovered && !s.dragMode)
    s.hoverInvalidated = false
  s.wasHovered = s.chevronHovered
  s.wasDragging = s.dragMode

  s.triggerActive = s.chevronHovered === true
  s.triggerHovered = !s.dragMode && !s.hoverInvalidated && s.triggerActive
  if (s.triggerHovered) {
    s.hoverLatch = true
    s.grace = 0
  } else if (s.hoverLatch && ++s.grace >= 2) {
    s.hoverLatch = false
  }
  s.open = !s.dragMode && (s.hoverLatch || s.menuOpen)
  return s
}

suite('bar/tray-trigger', 'BAR-4: the tray owns its chevron trigger and drag freeze')

section('the trigger lives in the tray')
group('the chevron, not an adjacent module, publishes the hover', () => {
  match('triggerActive reads the chevron MouseArea', triggerBody, TRIGGER_RE)
  eq('the lifted expression reads chevron hover', trigger, 'chevronArea.containsMouse === true')
  notMatch('no cross-module hover flag remains in the tray', tray, /logoutHovered|trayTriggerHovered/)
  notMatch('the tray no longer asks the bar about a group partner', tray, /isModuleVisible/)
  notMatch('the session module publishes no hover source', session, /\bhovered\b|\.logoutHovered/)
  notMatch('BarView declares no hover trigger', barView, /logoutHovered|trayTriggerHovered/)
})
group('the drag freeze still gates the trigger', () => {
  match('dragMode reads the window grace flag', tray, DRAG_RE)
  match('triggerHovered is gated by dragMode and the invalidation', tray, TRIGGER_HOVERED_RE)
  match('open is derived from the latch or menu, gated by dragMode', tray, OPEN_RE)
  contains('the latch is dropped when a drag engages', latchDrop, 'root.hoverLatch = false')
  match('a drag invalidates the hover already on the chevron', latchDrop, INVALIDATE_RE)
  match('only a fresh hover after the freeze clears it', tray, CLEAR_INVALIDATION_RE)
  contains('the window still publishes the grace flag', barView, 'recentDragActive')
  contains('the window grace timer stays', barView, 'dragGraceTimer')
})
group('the chevron affordance is part of the slot', () => {
  match('the slot width is scaled by an animated presence', tray,
    /implicitWidth:\s*Math\.round\(root\.presence\s*\*/)
  contains('the module paints until the shrink finishes', tray, 'visible: root.presence > 0')
  match('presence drives width at the zone grow duration', tray,
    /Behavior on presence\s*\{\s*enabled:\s*MotionPolicy\.enabled\s*NumberAnimation\s*\{\s*duration:\s*Ui\.slowMs/)
  match('presence drives the fade at the zone enter duration', tray,
    /Behavior on presenceFade\s*\{\s*enabled:\s*MotionPolicy\.enabled\s*NumberAnimation\s*\{\s*duration:\s*Ui\.fastMs/)
  contains('the icon row leaves room for the chevron', tray,
    'anchors.rightMargin: root.chevronSlot')
  contains('the chevron is a themed SVG glyph', tray, 'name: "chevron"')
  contains('the glyph is turned to point left', tray, 'rotation: 180')
  contains('the idle glyph uses the same tone as other bar icons', tray, 'colorKey: "foreground_0"')
  match('the idle glyph fades out as the accent fades in', tray,
    /opacity:\s*root\.open\s*\?\s*0\s*:\s*1/)
  contains('the accent copy uses the accent palette key', tray, 'colorKey: "accent"')
  match('the accent copy fades in with the open state', tray,
    /opacity:\s*root\.open\s*\?\s*1\s*:\s*0/)
  match('the fade runs on the shared motion gate', tray,
    /Behavior on opacity\s*\{\s*enabled:\s*MotionPolicy\.enabled/)
})
group('both modules are standalone and movable', () => {
  contains('no groups are registered', bar, 'root._groups = ({})')
  contains('no slots are pinned', bar, 'root._pinned = ({})')
  contains('the tray is a standalone slot', bar, 'tray: trayComp')
  contains('the session is a standalone slot', bar, 'session: sessionComp')
  contains('both sit in the right zone', bar, 'session: "right", tray: "right"')
  const rightIds = (((catalog.match(/"right"\s*:\s*\[([\s\S]*?)\]/) || [])[1] || '')
    .match(/"[^"]+"/g) || []).map(s => s.slice(1, -1))
  eq('the tray leads the default right zone', rightIds[0], 'tray')
  notMatch('the tray is not parked at the session corner', rightIds.slice(-2).join(','), /tray/)
  contains('the tray has its own toggle', catalog, '"id": "bar-tray"')
  notMatch('the combined toggle label is gone', catalog, /Power & Tray/)
})

section('the lifted derivation over a hover/drag timeline')
group('chevron hover opens and leaving closes', () => {
  const s = fresh()
  s.chevronHovered = true
  step(s)
  eq('hovering the chevron opens the tray', s.open, true)

  s.chevronHovered = false
  step(s)
  eq('the latch bridges the leave', s.open, true)
  step(s)
  eq('the grace expiry closes it', s.open, false)
})
group('a drag freezes the tray and cannot re-arm it under a parked cursor', () => {
  const s = fresh()
  s.chevronHovered = true
  step(s)
  eq('a hover at rest opens it', s.open, true)

  s.recentDragActive = true
  step(s)
  eq('drag start collapses it', s.open, false)
  eq('the latch is gone', s.hoverLatch, false)

  step(s)
  eq('the grace keeps it shut while the cursor stays put', s.open, false)

  s.recentDragActive = false
  step(s)
  eq('the parked hover stays invalidated', s.hoverInvalidated, true)
  eq('grace expiry alone does not reopen it', s.open, false)

  s.chevronHovered = false
  step(s)
  s.chevronHovered = true
  step(s)
  eq('a fresh hover after the freeze opens it', s.open, true)
})
group('a drag sweeping over the chevron cannot latch it', () => {
  const s = fresh()
  s.recentDragActive = true
  s.chevronHovered = true
  step(s)
  eq('the trigger is suppressed during the drag', s.triggerHovered, false)
  eq('nothing is latched', s.hoverLatch, false)

  s.chevronHovered = false
  s.recentDragActive = false
  step(s)
  eq('the swept hover does not survive the freeze', s.open, false)
})
group('an open menu holds the tray open without hover', () => {
  const s = fresh()
  s.menuOpen = true
  step(s)
  eq('the menu alone opens it', s.open, true)

  s.recentDragActive = true
  step(s)
  eq('a drag still collapses it', s.open, false)

  s.recentDragActive = false
  step(s)
  eq('the menu reopens it once the freeze lifts', s.open, true)
})

finish()

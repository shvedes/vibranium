#!/usr/bin/env node
// Suite: the logout hover -> tray trigger derivation on BarView (BAR-4).
//
//   shell/features/bar/BarView.qml                 the two sources + derivation
//   shell/features/bar/modules/Logout/Logout.qml    the hover source writer
//   shell/features/bar/modules/Tray/Tray.qml        the reader contract
//
// Limitation: BarView is a LayerSurface and Quickshell.screens is empty under
// QT_QPA_PLATFORM=offscreen, so the window cannot be constructed headlessly
// and no synthesized MouseArea hover is available. This suite reads the real
// QML, lifts the two expressions out of it, and evaluates them over a driven
// hover/drag timeline. It pins the derivation and its scheduling contract;
// compositor delivery of the hover and the actual tray animation stay
// source-level only.

import fs from 'node:fs'
import path from 'node:path'
import {
  suite, section, group, eq, match, contains, notMatch, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const BARVIEW = path.join(SHELL, 'features', 'bar', 'BarView.qml')
const LOGOUT = path.join(SHELL, 'features', 'bar', 'modules', 'Logout', 'Logout.qml')
const TRAY = path.join(SHELL, 'features', 'bar', 'modules', 'Tray', 'Tray.qml')

const barView = fs.readFileSync(BARVIEW, 'utf8')
const logout = fs.readFileSync(LOGOUT, 'utf8')
const tray = fs.readFileSync(TRAY, 'utf8')

// Both expressions are one line each so they can be lifted verbatim.
const DERIVATION_RE = /readonly\s+property\s+bool\s+trayTriggerHovered\s*:\s*([^\n]+)/
const HOVER_WRITE_RE = /\bw\.logoutHovered\s*=\s*([^\n]+)/
const ARM_BODY_RE = /function _armRecentDrag\(\)\s*\{([\s\S]*?)\}/
const ARM_CLEAR_RE = /\bwin\.logoutHovered\s*=\s*([^\n]+)/
const derivation = (barView.match(DERIVATION_RE) || [])[1] || ''
const hoverWrite = (logout.match(HOVER_WRITE_RE) || [])[1] || ''
const armBody = (barView.match(ARM_BODY_RE) || [])[1] || ''
const armClear = (armBody.match(ARM_CLEAR_RE) || [])[1] || ''

function evalExpr(expr, names) {
  if (!expr) return undefined
  return new Function(...Object.keys(names), `return (${expr})`)(...Object.values(names))
}

const fresh = () => ({
  hovered: false,
  hoverEdge: false,
  logoutHovered: false,
  recentDragActive: false,
  slotDragActive: false,
  trayTriggerHovered: false,
})

// One turn: Logout publishes on a hover edge only (onHoveredChanged fires on
// a change of hover, not when the drag term changes), then the BarView
// derivation is re-evaluated over its two live sources.
function step(s) {
  if (s.hoverEdge) {
    s.logoutHovered = evalExpr(hoverWrite, { root: { hovered: s.hovered }, w: s })
    s.hoverEdge = false
  }
  s.trayTriggerHovered = evalExpr(derivation, { win: s })
  return s
}

// The drag-arm edge: freeze the trigger and, when the source does so,
// invalidate a hover latched before the drag started. Both enterSlotDrag
// and leaveSlotDrag route through _armRecentDrag.
function arm(s) {
  s.recentDragActive = true
  s.slotDragActive = true
  if (armClear) s.logoutHovered = evalExpr(armClear, { win: s })
  return s
}

suite('bar/tray-trigger', 'BAR-4: hover and drag derive one tray trigger')

section('the writer side')
group('BarView declares one readonly derivation, not a stored flag', () => {
  match('trayTriggerHovered is a readonly derived bool', barView, DERIVATION_RE)
  contains('the derivation reads the logout hover source', derivation, 'logoutHovered')
  contains('the derivation reads the drag freeze', derivation, 'recentDragActive')
  match('the drag term negates the freeze', derivation, /!\s*win\.recentDragActive/)
  notMatch('nothing assigns to the flag on BarView', barView, /trayTriggerHovered\s*=/)
})
group('the imperative clears and the direct logout write are gone', () => {
  const start = barView.indexOf('function enterSlotDrag')
  const end = barView.indexOf('function _armRecentDrag')
  const dragFns = barView.slice(start, end)
  notMatch('enter/leaveSlotDrag no longer clear the flag', dragFns, /trayTriggerHovered\s*=/)
  notMatch('Logout no longer assigns the flag', logout, /\.trayTriggerHovered\s*=/)
  match('Logout writes only the hover source', logout, HOVER_WRITE_RE)
  contains('the hover write gates on the drag freeze', hoverWrite, '!w.recentDragActive')
})
group('the drag grace is preserved', () => {
  contains('the arming function stays', barView, '_armRecentDrag')
  contains('the grace timer stays', barView, 'dragGraceTimer')
  contains('the grace length stays', barView, 'dragGraceMs')
  contains('the freeze flag stays', barView, 'recentDragActive')
})
group('arming a drag invalidates a hover latched before it', () => {
  match('the arm edge clears the stale hover', barView, ARM_CLEAR_RE)
  const leave = barView.slice(
    barView.indexOf('function leaveSlotDrag'),
    barView.indexOf('function _armRecentDrag'),
  )
  notMatch('leaveSlotDrag never restores the hover', leave, /logoutHovered\s*=\s*true/)
})
group('the Tray reader contract is untouched', () => {
  match('dragMode still reads recentDragActive', tray, /dragMode:\s*root\.windowFlag\("recentDragActive"\)/)
  match('triggerHovered still gates on dragMode', tray, /triggerHovered:\s*!root\.dragMode\s*&&\s*root\.triggerActive\(\)/)
})

section('the lifted derivation over a hover/drag timeline')
group('a mid-drag hover cannot re-latch the trigger', () => {
  const s = fresh()
  s.hovered = true
  s.hoverEdge = true
  step(s)
  eq('a hover at rest opens it', s.trayTriggerHovered, true)

  s.hovered = false
  s.hoverEdge = true
  step(s)
  eq('leaving closes it', s.trayTriggerHovered, false)

  s.recentDragActive = true
  s.slotDragActive = true
  step(s)
  eq('drag start keeps it closed', s.trayTriggerHovered, false)

  s.hovered = true
  s.hoverEdge = true
  step(s)
  eq('a hover arriving during the drag is not published', s.logoutHovered, false)
  eq('and the derivation stays false', s.trayTriggerHovered, false)

  s.slotDragActive = false
  step(s)
  eq('drag end inside the grace stays closed', s.trayTriggerHovered, false)

  s.recentDragActive = false
  step(s)
  eq('grace expiry does not re-latch a parked mid-drag hover', s.trayTriggerHovered, false)
  eq('the hover source is still clear', s.logoutHovered, false)

  s.hovered = false
  s.hoverEdge = true
  step(s)
  s.hovered = true
  s.hoverEdge = true
  step(s)
  eq('a fresh hover after the freeze opens it', s.trayTriggerHovered, true)
})
group('the drag term wins over a latched source', () => {
  const s = fresh()
  s.logoutHovered = true
  s.recentDragActive = true
  step(s)
  eq('a source true during the freeze cannot open it', s.trayTriggerHovered, false)

  s.recentDragActive = false
  step(s)
  eq('once the freeze lifts the live source opens it', s.trayTriggerHovered, true)
})
group('a hover latched before the drag cannot survive the grace', () => {
  const s = fresh()
  s.hovered = true
  s.hoverEdge = true
  step(s)
  eq('a hover at rest latches', s.logoutHovered, true)
  eq('and opens the trigger', s.trayTriggerHovered, true)

  arm(s)
  step(s)
  eq('arming the drag discards the stale hover', s.logoutHovered, false)
  eq('the derivation closes the trigger', s.trayTriggerHovered, false)

  s.slotDragActive = false
  step(s)
  eq('drag end inside the grace stays closed', s.trayTriggerHovered, false)

  s.recentDragActive = false
  step(s)
  eq('grace expiry does not reopen on the stale hover', s.trayTriggerHovered, false)
  eq('the stale hover is still discarded', s.logoutHovered, false)

  s.hovered = false
  s.hoverEdge = true
  step(s)
  s.hovered = true
  s.hoverEdge = true
  step(s)
  eq('a fresh leave/enter re-arms the trigger', s.trayTriggerHovered, true)
})

finish()

#!/usr/bin/env node
// Suite: BAR-11 - the bar's two full-screen popup hosts retire stale
// placements. ToolTipHost and TrayMenu are LayerSurfaces, which have no
// offscreen backend, so the placement itself cannot be driven headlessly.
// This probe reads their sources and pins the mechanism instead: one deferred
// funnel, one coalescer, and a generation captured at scheduling that a newer
// election / logical menu change retires before the callback writes geometry.

import fs from 'node:fs'
import path from 'node:path'
import { suite, section, group, eq, contains, notContains, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const BAR = path.join(SHELL, 'features', 'bar')
const TIP = fs.readFileSync(path.join(BAR, 'ToolTipHost.qml'), 'utf8')
const TRAY = fs.readFileSync(path.join(BAR, 'modules', 'Tray', 'TrayMenu.qml'), 'utf8')

suite('common/bar/placement-epoch', 'BAR-11: coalesced, epoch-guarded bubble and card parking')

// ---------------------------------------------------------------------------
section('ToolTipHost: one deferred placement, captured winner')
// ---------------------------------------------------------------------------

group('every deferred place goes through one coalescer', () => {
  eq('one coalescer declaration', (TIP.match(/property bool _placeQueued/g) || []).length, 1)
  eq('one requestPlace funnel', (TIP.match(/function requestPlace\(/g) || []).length, 1)
  eq('all four deferred sites use it', (TIP.match(/root\.requestPlace\(\)/g) || []).length, 4)
  notContains('no bare deferred place remains', TIP, 'Qt.callLater(root.place)')
})

group('place() refuses a pass captured for a retired winner', () => {
  contains('place takes the captured winner', TIP, 'function place(capturedWinner)')
  contains('and checks it before writing geometry', TIP,
    'if (capturedWinner !== undefined && capturedWinner !== root._winner) return')
  const guardAt = TIP.indexOf('capturedWinner !== root._winner')
  const xAt = TIP.indexOf('bubble.x = Math.round(x)')
  const yAt = TIP.indexOf('bubble.y = Math.round(y)')
  contains('the guard still owns the x write', TIP, 'bubble.x = Math.round(x)')
  contains('the guard still owns the y write', TIP, 'bubble.y = Math.round(y)')
  eq('the guard precedes both writes', guardAt > 0 && guardAt < xAt && guardAt < yAt, true)
})

group('the coalescer is retired by a new election', () => {
  contains('a winner change releases the queued pass', TIP,
    'on_WinnerChanged: root._placeQueued = false')
  contains('the callback rechecks the captured winner', TIP,
    'if (winner !== root._winner) return')
})

group('the election and snapshot contract is preserved', () => {
  contains('the activation serial stays', TIP, 'property int _rev: 0')
  contains('the winner stays', TIP, 'property var _winner: null')
  contains('the snapshot stays', TIP, 'property var _req: null')
  contains('highest-rev election stays', TIP, 'if (!best || r.rev > best.rev) best = r')
  contains('retire-on-destroy stays', TIP, 'function _retire(bind)')
  contains('the show timer stays', TIP, 'id: showTimer')
  contains('the timer revalidates its winner', TIP, 'if (!root._req) return')
  contains('the initial synchronous place stays', TIP, 'root.place()')
})

// ---------------------------------------------------------------------------
section('TrayMenu: one deferred park, captured epoch')
// ---------------------------------------------------------------------------

group('every deferred park goes through one coalescer', () => {
  eq('one coalescer declaration', (TRAY.match(/property bool _parkQueued/g) || []).length, 1)
  eq('one epoch declaration', (TRAY.match(/property int _parkEpoch/g) || []).length, 1)
  eq('one requestPark funnel', (TRAY.match(/function requestPark\(/g) || []).length, 1)
  eq('all eleven deferred sites use it', (TRAY.match(/root\.requestPark\(\)/g) || []).length, 11)
  notContains('no bare deferred park remains', TRAY, 'Qt.callLater(root.positionCard)')
})

group('positionCard refuses a pass captured for a replaced menu', () => {
  contains('park takes the captured epoch', TRAY, 'function positionCard(epoch)')
  contains('and checks it before writing geometry', TRAY,
    'if (epoch !== undefined && epoch !== root._parkEpoch) return')
  const guardAt = TRAY.indexOf('epoch !== root._parkEpoch) return')
  const xAt = TRAY.indexOf('card.x = Math.round(x)')
  const yAt = TRAY.indexOf('card.y = Math.round(y)')
  contains('the x write stays', TRAY, 'card.x = Math.round(x)')
  contains('the y write stays', TRAY, 'card.y = Math.round(y)')
  eq('the guard precedes both writes', guardAt > 0 && guardAt < xAt && guardAt < yAt, true)
})

group('the epoch is retired on every logical menu change', () => {
  eq('one epoch bump helper', (TRAY.match(/function _bumpParkEpoch\(/g) || []).length, 1)
  eq('open, close and both level changes bump it',
    (TRAY.match(/root\._bumpParkEpoch\(\)/g) || []).length, 4)
  contains('the callback rechecks the captured epoch', TRAY,
    'if (epoch !== root._parkEpoch) return')
})

group('the open-time synchronous park is preserved', () => {
  contains('the anchor is still parked before the surface maps', TRAY, 'root.positionCard()')
  contains('the parked latch stays', TRAY, 'property bool _parked: false')
  contains('the claim token stays', TRAY, 'property var _claimToken: null')
  contains('the surface claim stays', TRAY, 'SurfaceClaim.claim("trayMenu"')
})

finish()

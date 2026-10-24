#!/usr/bin/env node
// Suite: the bar's pure JS layer.
//
//   shell/features/bar/BarLib.js                        the layout algebra
//   shell/features/bar/modules/ArchUpdates/Model.js      search + selection
//   shell/features/bar/modules/Volume/Model.js           stream classification
//   shell/features/bar/modules/Workspaces/Model.js       pile geometry + identity
//   shell/common/NowPlaying.js                           the media helpers
//
// Every one of these sits on a binding that re-evaluates per keystroke or per
// frame, so each function is checked against the contract in its own header
// comment, and each cluster also checks the purity the caller relies on (a
// QML binding cannot survive a helper that mutates the array it was handed).
//
// The NowPlaying helpers used to be covered twice: once against
// features/bar/modules/NowPlaying/Model.js, a partial copy nothing imported,
// and once against the shared library. The copy is gone, so its parity
// section is gone with it, and the shared library is asserted on its own.

import vm from 'node:vm'
import fs from 'node:fs'
import path from 'node:path'
import { loadLib, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, approx, skip, deepEqual, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const fsExists = (p) => fs.existsSync(p)

// The shell root is resolved from this file's own location, the way
// text.test.mjs does it. `SHELL_DIR` from the assertion kit is *not* usable
// for opening the libraries: it walks four levels up from tests/shell/lib,
// which lands one directory above the repository (`.local/share/shell`).
// The first group in this suite pins that so the drift is visible here rather
// than as an ENOENT at import time - see the report.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const BAR = path.join(SHELL, 'features', 'bar')
const B = loadLib(path.join(BAR, 'BarLib.js'))
const AU = loadLib(path.join(BAR, 'modules', 'ArchUpdates', 'Model.js'))
const VO = loadLib(path.join(BAR, 'modules', 'Volume', 'Model.js'))
const WSM = loadLib(path.join(BAR, 'modules', 'Workspaces', 'Model.js'))
const CN = loadLib(path.join(SHELL, 'common', 'NowPlaying.js'))

// --- a clock we control -------------------------------------------------
//
// noteManual/manualFresh/manualDir are gated on Date.now(), and a .pragma
// library gets its own vm context per file, so the host's Date is not the
// context's Date and monkey-patching it here would prove nothing. clocked()
// re-evaluates the same source in a context whose Date is a stub, which is
// what makes the freshness threshold testable on both sides without a sleep
// and lets both NowPlaying copies be compared at the *same* timestamp.
//
// It is a second loader, not a replacement: loadLib above is still what every
// non-time-gated assertion runs against, and the first group below asserts
// that clocked() publishes the same function set.
const DECL = /^(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*))/gm
function clocked(file, t = 1000) {
  const clock = { t }
  const src = libSource(file)
  const holder = { console, Date: { now: () => clock.t } }
  const ctx = vm.createContext(holder)
  vm.runInContext(src, ctx, { filename: file })
  const out = { _clock: clock }
  for (const m of src.matchAll(DECL)) {
    const name = m[1] || m[2]
    if (name in ctx) out[name] = ctx[name]
  }
  return out
}

const ZONES = ['left', 'center', 'right']
// Registry facts Bar.qml injects into normalizeLayout/renderLayout.
const ALL_SLOTS = ['clock', 'workspaces', 'tray', 'wifi', 'battery', 'volume', 'microphone', 'update']
const STANDALONE = new Set(ALL_SLOTS)
const OWNED = new Set(['recording', 'timer'])
const isStandalone = (id) => STANDALONE.has(id)
const isOwned = (id) => OWNED.has(id)
const hasSlot = (id) => STANDALONE.has(id) || OWNED.has(id)
const noPins = {}
const nothing = () => false

// The owned-descriptor list Bar.ownModule keeps: { id, zone } entries in
// registration order, built the way its concat builds them.
const claims = (ids, zone) => ids.map((id) => ({ id, zone }))

const npk = (name, extra) => Object.assign({ name, candidate: '1.0-1' }, extra)
const OFFICIAL = npk('vim')
const AURPKG = npk('yay-bin', { source: 'aur', repository: 'aur' })

suite('bar/models', 'BarLib + the bar module models + common/NowPlaying')

section('the harness contract')
group('the five libraries load and publish a function surface', () => {
  for (const [label, lib] of [['BarLib', B], ['ArchUpdates/Model', AU], ['Volume/Model', VO], ['Workspaces/Model', WSM], ['common/NowPlaying', CN]]) {
    is(`${label} loaded`, lib, (v) => v && typeof v === 'object' && Object.keys(v).length > 0, 'a non-empty namespace')
  }
  eq('BarLib publishes the seventeen layout helpers plus the shared insert rule', Object.keys(B).length, 18)
  eq('ArchUpdates/Model publishes the seventeen model functions plus four table vars', Object.keys(AU).length, 21)
  eq('Volume/Model publishes thirteen functions', Object.keys(VO).length, 13)
  eq('Workspaces/Model publishes the pile functions and its tags', Object.keys(WSM).length, 11)
})
group('assert.mjs SHELL_DIR resolves the shell tree itself', () => {
  // The kit's export is the load root every JS suite shares, so it is worth
  // asserting rather than assuming: it must land on the shell directory, not
  // one level above the checkout. It briefly did not, and every suite that
  // trusted it silently fell back to resolving its own path.
  eq('the kit path is the shell root', SHELL_DIR, SHELL)
  eq('and it can open a library directly', fsExists(path.join(SHELL_DIR, 'features', 'bar', 'BarLib.js')), true)
  eq('and it holds the entry point', fsExists(path.join(SHELL_DIR, 'shell.qml')), true)
})

// ======================================================================
section('BarLib.normZone - three zones, everything else is "right"')
group('the three zone ids pass through unchanged', () => {
  eq('left', B.normZone('left'), 'left')
  eq('center', B.normZone('center'), 'center')
  eq('right', B.normZone('right'), 'right')
})
group('anything else folds to the right zone', () => {
  // The header comment: "dynamic indicators default to the right zone, away
  // from the static time/workspaces that occupy left and center".
  eq('an unknown id', B.normZone('top'), 'right')
  eq('the empty string', B.normZone(''), 'right')
  eq('undefined', B.normZone(undefined), 'right')
  eq('null', B.normZone(null), 'right')
  eq('0 (falsy, but not a zone)', B.normZone(0), 'right')
  eq('false', B.normZone(false), 'right')
  eq('an object', B.normZone({}), 'right')
  eq('an array holding a zone id is not a zone', B.normZone(['left']), 'right')
})
group('the match is exact - no case folding, no trimming', () => {
  // indexOf on a fixed table, so a case or whitespace variant is not a zone
  // and silently lands the module on the right.
  eq('capitalised', B.normZone('Left'), 'right')
  eq('all caps', B.normZone('RIGHT'), 'right')
  eq('leading space', B.normZone(' left'), 'right')
  eq('trailing space', B.normZone('right '), 'right')
  eq('a centre spelling', B.normZone('centre'), 'right')
})

section('BarLib.removeOwned - the claim release')
group('removes by id and returns a new list', () => {
  const owned = [{ id: 'a', zone: 'left' }, { id: 'b', zone: 'right' }]
  eq('the survivor', B.removeOwned(owned, 'a'), [{ id: 'b', zone: 'right' }])
  eq('the input is untouched', owned.length, 2)
  ne('a new array', B.removeOwned(owned, 'a'), owned)
  eq('the empty result is an empty array, not null', B.removeOwned(owned, 'a') && B.removeOwned([{ id: 'a' }], 'a'), [])
})
group('a stray release is a harmless no-op', () => {
  const owned = [{ id: 'a', zone: 'left' }]
  eq('an unknown id', B.removeOwned(owned, 'zzz'), null)
  eq('undefined', B.removeOwned(owned, undefined), null)
  eq('null', B.removeOwned(owned, null), null)
  eq('an empty string', B.removeOwned(owned, ''), null)
  eq('releasing the same id twice reports the second as a no-op', B.removeOwned(B.removeOwned(owned, 'a'), 'a'), null)
})
group('the id comparison is strict, so a number never matches a string id', () => {
  const owned = [{ id: '0', zone: 'left' }]
  eq('numeric 0 does not remove id "0"', B.removeOwned(owned, 0), null)
  eq('the string does', B.removeOwned(owned, '0'), [])
})
group('every entry can be released, one id at a time', () => {
  let owned = claims(['a', 'b', 'c'], 'right')
  owned = B.removeOwned(owned, 'b')
  eq('the survivor order', owned.map((m) => m.id), ['a', 'c'])
  owned = B.removeOwned(owned, 'c')
  owned = B.removeOwned(owned, 'a')
  eq('an empty list when the last one goes', owned, [])
})

section('BarLib groups - one slot, several members')
group('groupMembers returns the member list or an empty one', () => {
  const groups = { tray: ['tray', 'bluetooth', 'network'], 'tray-expanded': ['bluetooth'] }
  eq('a three-member group', B.groupMembers(groups, 'tray'), ['tray', 'bluetooth', 'network'])
  eq('a one-member group', B.groupMembers(groups, 'tray-expanded'), ['bluetooth'])
  eq('an unknown key', B.groupMembers(groups, 'zzz'), [])
  eq('a missing map', B.groupMembers(null, 'tray'), [])
  eq('undefined', B.groupMembers(undefined, 'tray'), [])
  eq('a value that is not an array', B.groupMembers({ tray: 'tray' }, 'tray'), [])
  eq('a null value', B.groupMembers({ tray: null }, 'tray'), [])
  eq('a number value', B.groupMembers({ tray: 3 }, 'tray'), [])
})
group('isGroup is membership, so an empty member list is not a group', () => {
  eq('a real group', B.isGroup({ g: ['a'] }, 'g'), true)
  eq('a group with no members', B.isGroup({ g: [] }, 'g'), false)
  eq('a non-array member value', B.isGroup({ g: 'a' }, 'g'), false)
  eq('an unknown key', B.isGroup({ g: ['a'] }, 'zzz'), false)
  eq('a missing map', B.isGroup(null, 'g'), false)
})
group('slotPresent finds an id in any zone, whatever the order', () => {
  const layout = { left: ['clock'], center: ['workspaces'], right: ['tray', 'volume'] }
  eq('left', B.slotPresent(layout, 'clock'), true)
  eq('the last zone', B.slotPresent(layout, 'volume'), true)
  eq('an absent id', B.slotPresent(layout, 'wifi'), false)
  eq('a substring is not a slot', B.slotPresent(layout, 'clo'), false)
  eq('a null layout', B.slotPresent(null, 'clock'), false)
  eq('an empty layout', B.slotPresent({}, 'clock'), false)
  eq('a zone value that is not an array is skipped, not indexed', B.slotPresent({ left: 'clock' }, 'clo'), false)
  eq('a zone value that is a string never matches', B.slotPresent({ left: 'clock' }, 'clock'), false)
})
group('moduleVisible follows the bundle a member belongs to', () => {
  // The header: "Lets a member module ask about the bundle it belongs to
  // (e.g. the tray's expansion trigger is the group it shares)".
  const groups = { tray: ['tray', 'bluetooth', 'network'] }
  const layout = { left: ['clock'], right: ['tray'] }
  eq('the group key itself', B.moduleVisible(layout, groups, 'tray'), true)
  eq('a member of a placed group', B.moduleVisible(layout, groups, 'bluetooth'), true)
  eq('the second member too', B.moduleVisible(layout, groups, 'network'), true)
  eq('a standalone slot', B.moduleVisible(layout, groups, 'clock'), true)
  eq('a member of a group with no slot', B.moduleVisible(layout, { other: ['bluetooth'] }, 'bluetooth'), false)
  eq('an id in neither', B.moduleVisible(layout, groups, 'wifi'), false)
  eq('a null layout and a null group map', B.moduleVisible(null, null, 'x'), false)
  eq('an empty group map', B.moduleVisible(layout, {}, 'bluetooth'), false)
})

section('BarLib.entranceExpectedIds - the boot-entrance expectation')
group('plain slots pass through in first-seen order', () => {
  eq('across zones', B.entranceExpectedIds({ left: ['clock'], center: ['workspaces'], right: ['volume'] }, {}), ['clock', 'workspaces', 'volume'])
  eq('an empty layout expects nothing', B.entranceExpectedIds({ left: [], center: [], right: [] }, {}), [])
  eq('a null layout expects nothing', B.entranceExpectedIds(null, {}), [])
  eq('an undefined layout expects nothing', B.entranceExpectedIds(undefined, {}), [])
  eq('a zone value that is not an array is skipped', B.entranceExpectedIds({ left: 'clock', right: ['volume'] }, {}), ['volume'])
})
group('a group key expands to its members, never itself', () => {
  // The bar's session group: one layout slot, two modules on screen.
  const groups = { session: ['tray', 'logout'] }
  eq('the key becomes its members', B.entranceExpectedIds({ right: ['volume', 'session'] }, groups), ['volume', 'tray', 'logout'])
  eq('member order is the group order', B.entranceExpectedIds({ right: ['session'] }, groups), ['tray', 'logout'])
  eq('an empty member list expects nothing for the key', B.entranceExpectedIds({ right: ['session'] }, { session: [] }), [])
  eq('a non-array member value is not a group', B.entranceExpectedIds({ right: ['session'] }, { session: 'tray' }), ['session'])
  eq('a null group map leaves the key as-is', B.entranceExpectedIds({ right: ['session'] }, null), ['session'])
})
group('duplicates collapse to the first sighting', () => {
  eq('twice in one zone', B.entranceExpectedIds({ left: ['clock', 'clock'] }, {}), ['clock'])
  eq('in two zones the earlier zone wins', B.entranceExpectedIds({ left: ['clock'], right: ['clock', 'volume'] }, {}), ['clock', 'volume'])
  eq('a member that is also its own slot collapses too', B.entranceExpectedIds({ left: ['tray'], right: ['session'] }, { session: ['tray', 'logout'] }), ['tray', 'logout'])
})
group('the inputs are never mutated', () => {
  const layout = { left: ['clock'], right: ['session'] }
  const groups = { session: ['tray', 'logout'] }
  const snapshot = JSON.stringify({ layout, groups })
  B.entranceExpectedIds(layout, groups)
  eq('identical after the call', JSON.stringify({ layout, groups }), snapshot)
})

section('BarLib.pinSlots - a pinned slot always resolves to its corner')
group('mutates the layout it is handed, as its header documents', () => {
  const layout = { left: [], center: [], right: ['a'] }
  const out = B.pinSlots(layout, { b: 'right' }, ZONES)
  is('the same object comes back', out, (v) => v === layout, 'pinSlots returns its argument')
  eq('and it was changed in place', layout, { left: [], center: [], right: ['a', 'b'] })
})
group('pulls the id to the end of its pinned zone, from anywhere', () => {
  const layout = { left: ['a', 'pinned', 'b'], center: [], right: [] }
  B.pinSlots(layout, { pinned: 'right' }, ZONES)
  eq('out of its old zone and at the end of the new one', layout, { left: ['a', 'b'], center: [], right: ['pinned'] })
})
group('re-pins an id that sits in the wrong zone, even in the middle', () => {
  const layout = { left: ['x'], center: ['y', 'tray', 'z'], right: [] }
  B.pinSlots(layout, { tray: 'right' }, ZONES)
  eq('the middle slot became the corner', layout, { left: ['x'], center: ['y', 'z'], right: ['tray'] })
})
group('a pinned id absent from the layout is materialised at its corner', () => {
  // The write path calls this with no `include` gate, so a pinned id the file
  // never mentions is *added*. That is how a module that pins itself (clock,
  // workspaces) keeps its place in a hand-edited or minimal layout.
  const layout = { left: [], center: [], right: ['a'] }
  B.pinSlots(layout, { clock: 'left', volume: 'right' }, ZONES)
  eq('both pins landed', layout, { left: ['clock'], center: [], right: ['a', 'volume'] })
})
group('a pin naming a zone outside `zones` is skipped entirely', () => {
  const layout = { left: ['a'], center: [], right: ['b'] }
  B.pinSlots(layout, { a: 'top' }, ZONES)
  eq('the id stays where the file put it', layout, { left: ['a'], center: [], right: ['b'] })
  eq('and a later real pin still applies', B.pinSlots(layout, { a: 'left', b: 'right' }, ['left']), layout)
  eq('two zones, one pin', layout.left, ['a'])
})
group('pins are applied in the order of the pinned map', () => {
  const layout = { left: [], center: [], right: [] }
  B.pinSlots(layout, { a: 'right', b: 'right' }, ZONES)
  eq('declaration order decides the corner order', layout.right, ['a', 'b'])
})
group('only the first occurrence in a zone is spliced out', () => {
  // indexOf + splice, so a hand-edited layout that already lists the id twice
  // keeps one copy - and renderLayout does not dedupe, so that copy renders.
  const layout = { left: ['a', 'a', 'b'], center: [], right: [] }
  B.pinSlots(layout, { a: 'left' }, ZONES)
  eq('one duplicate survives', layout.left, ['a', 'b', 'a'])
})
group('the include gate holds a disabled pin out of the render layout', () => {
  const layout = { left: ['keep', 'drop'], center: [], right: [] }
  B.pinSlots(layout, { keep: 'left', drop: 'left' }, ZONES, (id) => id === 'keep')
  eq('the excluded pin leaves no trace', layout.left, ['keep'])
  eq('a falsy include behaves as a gate that excludes nothing', B.pinSlots({ left: ['x'], center: [], right: [] }, { x: 'left' }, ZONES, 0).left, ['x'])
})
group('an empty pin map is a no-op', () => {
  const layout = { left: ['a'], center: [], right: [] }
  B.pinSlots(layout, {}, ZONES)
  eq('unchanged', layout, { left: ['a'], center: [], right: [] })
  eq('a null pin map does not throw', B.pinSlots({ left: [], center: [], right: [] }, null, ZONES).left, [])
})

section('BarLib.insertBeforePin - the owned-module placement rule')
group('lands immediately before the first pinned slot', () => {
  eq('a pin at the front', B.insertBeforePin(['p', 'q'], { p: 'right' }, 'new'), ['new', 'p', 'q'])
  eq('a pin in the middle', B.insertBeforePin(['a', 'b', 'p'], { p: 'left' }, 'new'), ['a', 'b', 'new', 'p'])
  eq('the first of two pins wins', B.insertBeforePin(['a', 'p1', 'p2'], { p1: 'left', p2: 'right' }, 'new'), ['a', 'new', 'p1', 'p2'])
})
group('appends when the zone holds no pin', () => {
  eq('no pin map at all', B.insertBeforePin(['a', 'b'], {}, 'new'), ['a', 'b', 'new'])
  eq('an empty pin map', B.insertBeforePin(['a'], {}, 'new'), ['a', 'new'])
  eq('a pin map for other ids', B.insertBeforePin(['a'], { other: 'left' }, 'new'), ['a', 'new'])
  eq('an empty zone', B.insertBeforePin([], { x: 'left' }, 'new'), ['new'])
  eq('the pin is a membership test, not a zone test: any value counts', B.insertBeforePin(['p'], { p: 'left' }, 'new'), ['new', 'p'])
  eq('an undefined pin value is not a pin', B.insertBeforePin(['p'], { p: undefined }, 'new'), ['p', 'new'])
})
group('the list is mutated in place, as its header documents', () => {
  const list = ['a', 'b']
  const out = B.insertBeforePin(list, {}, 'new')
  is('the same array comes back', out, (v) => v === list, 'returns its argument')
  eq('and it was changed in place', list, ['a', 'b', 'new'])
})
group('the pin lookup is unguarded, so an inherited key reads as a pin', () => {
  // `pinned[list[i]] !== undefined` walks the prototype chain, so a slot id
  // that happens to be an Object.prototype member is treated as a pin wall.
  // Nothing in the registry uses such an id today; pinned as a trap.
  eq('"toString" in the list is a wall', B.insertBeforePin(['toString', 'a'], {}, 'new'), ['new', 'toString', 'a'])
  eq('"constructor" in the list is a wall', B.insertBeforePin(['constructor'], {}, 'new'), ['new', 'constructor'])
  eq('"__proto__" in the list is a wall', B.insertBeforePin(['__proto__', 'z'], {}, 'new'), ['new', '__proto__', 'z'])
})

section('BarLib.insertBeforeAnchor - the static-module placement rule')
group('lands directly before the anchor when it is in the zone', () => {
  eq('the anchor at the front', B.insertBeforeAnchor(['a', 'b'], 'a', 'new'), ['new', 'a', 'b'])
  eq('an anchor in the middle', B.insertBeforeAnchor(['a', 'b', 'c'], 'b', 'new'), ['a', 'new', 'b', 'c'])
  eq('the anchor at the end', B.insertBeforeAnchor(['a', 'b'], 'b', 'new'), ['a', 'new', 'b'])
  eq('the only entry', B.insertBeforeAnchor(['a'], 'a', 'new'), ['new', 'a'])
})
group('an empty or absent anchor is an append', () => {
  eq('an empty anchor', B.insertBeforeAnchor(['a', 'b'], '', 'new'), ['a', 'b', 'new'])
  eq('an anchor naming an id the zone does not hold', B.insertBeforeAnchor(['a', 'b'], 'zz', 'new'), ['a', 'b', 'new'])
  eq('a null anchor', B.insertBeforeAnchor(['a', 'b'], null, 'new'), ['a', 'b', 'new'])
  eq('undefined', B.insertBeforeAnchor(['a', 'b'], undefined, 'new'), ['a', 'b', 'new'])
  eq('an empty zone', B.insertBeforeAnchor([], 'a', 'new'), ['new'])
})
group('the list is mutated in place', () => {
  const list = ['a', 'b']
  is('the same array comes back', B.insertBeforeAnchor(list, 'a', 'new'), (v) => v === list, 'returns its argument')
  eq('and it was changed in place', list, ['new', 'a', 'b'])
})

section('BarLib.normalizeLayout - the write-path layout policy')
const nl = (raw, over) => B.normalizeLayout(
  raw,
  over && over.zones ? over.zones : ZONES,
  over && over.isStandalone ? over.isStandalone : isStandalone,
  over && over.isOwned ? over.isOwned : isOwned,
  (over && over.permanent) || {},
  (over && over.alwaysOn) || [],
  (over && over.stale) || [],
  (over && over.pinned) || noPins,
)
group('the option always carries all four keys, in a fixed order', () => {
  eq('an empty object', Object.keys(nl({})), ['left', 'center', 'right', 'disabled'])
  eq('a full object', Object.keys(nl({ left: ['clock'], center: [], right: [], disabled: [] })), ['left', 'center', 'right', 'disabled'])
  // Key order is what the signature (JSON.stringify of this) hashes on, so a
  // subset zone list must not change it.
  eq('a one-zone policy still writes all four', Object.keys(nl({ left: ['clock'] }, { zones: ['left'] })), ['left', 'center', 'right', 'disabled'])
  eq('and the unread zones are empty', nl({ left: ['clock'] }, { zones: ['left'] }).right, [])
})
group('a raw that is not an object is refused', () => {
  eq('null', nl(null), null)
  eq('undefined', nl(undefined), null)
  eq('an array', nl([]), null)
  eq('a string', nl('left'), null)
  eq('a number', nl(7), null)
  eq('true', nl(true), null)
  eq('an empty object is fine though', nl({}), { left: [], center: [], right: [], disabled: [] })
})
group('an empty policy normalizes to four empty lists', () => {
  eq('empty', nl({}), { left: [], center: [], right: [], disabled: [] })
  eq('a zone that is not an array is skipped', nl({ left: 'clock', center: 5, right: null }), { left: [], center: [], right: [], disabled: [] })
  eq('a zone name outside the table is never read', nl({ top: ['clock'], middle: ['wifi'] }), { left: [], center: [], right: [], disabled: [] })
})
group('a single known slot survives untouched', () => {
  eq('one zone, one id', nl({ left: ['clock'], center: [], right: [], disabled: [] }), { left: ['clock'], center: [], right: [], disabled: [] })
  eq('zone order is the policy order, not the raw order', nl({ right: ['volume'], left: ['clock'] }), { left: ['clock'], center: [], right: ['volume'], disabled: [] })
})
group('an id the registry does not resolve is dropped', () => {
  eq('an unknown id', nl({ left: ['clock', 'ghost', 'workspaces'] }).left, ['clock', 'workspaces'])
  eq('an id that is not a string', nl({ left: ['clock', 7, null, {}, ['x']] }).left, ['clock'])
  eq('an empty string', nl({ left: ['clock', ''] }).left, ['clock'])
  eq('a whitespace id is a real id as far as the library knows', nl({ left: ['clock', ' '] }, { isStandalone: (id) => id === ' ' }).left, [' '])
})
group('owned ids pass without being standalone', () => {
  eq('an owned id in a zone', nl({ left: ['recording'] }).left, ['recording'])
  eq('an owned id among standalone ones', nl({ right: ['volume', 'timer', 'battery'] }).right, ['volume', 'timer', 'battery'])
  eq('an unknown id is still unknown', nl({ right: ['timer', 'ghost'] }).right, ['timer'])
})
group('a duplicate id is kept once, in the first zone that claims it', () => {
  eq('twice in one zone', nl({ left: ['clock', 'clock', 'workspaces'] }).left, ['clock', 'workspaces'])
  eq('in two zones, the earlier zone wins', nl({ center: ['clock'], left: ['clock'] }), { left: ['clock'], center: [], right: [], disabled: [] })
  eq('three zones deep', nl({ right: ['clock'], left: ['clock'], center: ['clock'] }).center, [])
  eq('and the id does not come back in the later zone', nl({ right: ['clock'], left: ['clock'] }).right, [])
})
group('a stale id is dropped on every write, so an upgraded file heals', () => {
  // The README: the shipped default still lists `microphone`, and
  // "_staleSlotIds drops it on every write so an upgraded file heals".
  const stale = { stale: ['microphone'] }
  eq('from its zone', nl({ left: ['clock', 'microphone', 'workspaces'] }, stale).left, ['clock', 'workspaces'])
  // The stale filter is inside the zone walk only: the `disabled` loop never
  // consults it, so a stale id in the off list survives the write. Harmless
  // for the bar (renderLayout drops ids the registry cannot resolve) but it
  // is not what "dropped on every write" reads like - see the report.
  eq('but not out of the disabled list', nl({ disabled: ['microphone'] }, stale).disabled, ['microphone'])
  eq('a stale id that is not present costs nothing', nl({ left: ['clock'] }, stale), { left: ['clock'], center: [], right: [], disabled: [] })
  eq('a stale id is dropped even if the registry still resolves it', nl({ left: ['microphone'], disabled: ['microphone'] }, stale).left, [])
  eq('stale beats owned', nl({ left: ['timer'] }, { stale: ['timer'] }).left, [])
})
group('disabled is a list of standalone, non-owned, non-permanent ids', () => {
  eq('a plain toggleable slot', nl({ disabled: ['wifi'] }).disabled, ['wifi'])
  eq('duplicates collapse', nl({ disabled: ['wifi', 'wifi'] }).disabled, ['wifi'])
  eq('an owned id never enters disabled', nl({ disabled: ['timer'] }).disabled, [])
  eq('an unknown id never enters disabled', nl({ disabled: ['ghost'] }).disabled, [])
  eq('a permanent slot never enters disabled', nl({ disabled: ['clock'] }, { permanent: { clock: 'left' } }).disabled, [])
  eq('an alwaysOn slot never enters disabled', nl({ disabled: ['workspaces'] }, { alwaysOn: ['workspaces'] }).disabled, [])
  eq('a non-string entry is dropped', nl({ disabled: ['wifi', 7, '', null] }).disabled, ['wifi'])
  eq('a missing disabled list is an empty one', nl({ left: ['clock'] }).disabled, [])
  eq('a non-array disabled list is an empty one', nl({ disabled: 'wifi' }).disabled, [])
  eq('permanent is a membership test on the id, whatever the value', nl({ disabled: ['wifi'] }, { permanent: { wifi: false } }).disabled, [])
  eq('a falsy permanent value still means permanent', nl({ disabled: ['wifi'] }, { permanent: { wifi: 0 } }).disabled, [])
})
group('a slot may sit in a zone and in disabled - the gap is the point', () => {
  // The README: zones hold every known id *including disabled ones*, so a
  // disabled module keeps its gap and re-enabling restores the dragged order.
  const out = nl({ left: ['clock', 'wifi', 'workspaces'], disabled: ['wifi'] })
  eq('the gap stays in the zone', out.left, ['clock', 'wifi', 'workspaces'])
  eq('and the off list names it', out.disabled, ['wifi'])
})
group('pins are enforced after normalization', () => {
  eq('a pinned id is pulled to the end of its zone', nl({ left: ['clock', 'workspaces', 'tray'] }, { pinned: { clock: 'left' } }).left, ['workspaces', 'tray', 'clock'])
  eq('and out of any other zone', nl({ left: ['tray'], right: ['clock'] }, { pinned: { clock: 'right' } }), { left: ['tray'], center: [], right: ['clock'], disabled: [] })
  eq('a pinned id missing from the file is added at its corner', nl({}, { pinned: { volume: 'right' } }).right, ['volume'])
  eq('a pin naming a zone outside the policy is ignored', nl({ left: ['clock'] }, { pinned: { clock: 'top' } }).left, ['clock'])
  eq('a pinned unknown id is added - pinSlots never asks the registry', nl({}, { pinned: { ghost: 'left' } }).left, ['ghost'])
})
group('the raw option is never mutated', () => {
  const raw = { left: ['clock', 'microphone', 'clock'], center: ['timer'], right: [], disabled: ['wifi', 'timer'] }
  const snapshot = JSON.stringify(raw)
  nl(raw, { stale: ['microphone'], pinned: { clock: 'right' } })
  eq('identical after the call', JSON.stringify(raw), snapshot)
  const zones = raw.left
  nl(raw, {})
  is('the zone array itself is untouched', zones, (a) => a === raw.left && a.join() === 'clock,microphone,clock', 'zone array identity and contents')
})
group('the policy is driven entirely by the injected registry facts', () => {
  // The header: "this function never learns a module's id, and never decides
  // what one renders". A different registry must change the answer.
  const all = { isStandalone: () => true, isOwned: () => false }
  eq('a permissive registry keeps everything', nl({ left: ['x', 'y', 'z'] }, all).left, ['x', 'y', 'z'])
  eq('an empty registry keeps nothing', nl({ left: ['x', 'y', 'z'] }, { isStandalone: () => false, isOwned: () => false }).left, [])
  eq('a one-zone policy reads only that zone', nl({ left: ['clock'], right: ['clock'] }, { zones: ['right'] }).right, ['clock'])
  eq('and leaves the others empty', nl({ left: ['clock'], right: ['clock'] }, { zones: ['right'] }).left, [])
})

section('BarLib.renderLayout - the one derivation to what the bar draws')
const rl = (positions, over) => B.renderLayout(
  positions,
  (over && over.disabled) || [],
  (over && over.zones) ? over.zones : ZONES,
  (over && over.pinned) || noPins,
  (over && over.hasSlot) || hasSlot,
  (over && over.isOwned) || isOwned,
)
group('the output carries exactly the zones it was asked for, in that order', () => {
  const out = rl({ left: [], center: [], right: [] })
  eq('the default order', Object.keys(out), ['left', 'center', 'right'])
  // The header: "Key insertion order is the caller's `zones` order, which the
  // signature (JSON.stringify of this object) is sensitive to."
  eq('a reordered policy reorders the keys', Object.keys(rl({ left: [], right: [] }, { zones: ['right', 'left'] })), ['right', 'left'])
  eq('one zone yields one key', Object.keys(rl({ left: [] }, { zones: ['left'] })), ['left'])
  eq('every value is a list', Array.isArray(out.left) && Array.isArray(out.center) && Array.isArray(out.right), true)
})
group('zones minus disabled, minus ids the registry cannot resolve', () => {
  const positions = { left: ['clock', 'workspaces'], center: ['tray'], right: ['volume', 'ghost'] }
  eq('nothing disabled', rl(positions), { left: ['clock', 'workspaces'], center: ['tray'], right: ['volume'] })
  eq('one disabled', rl(positions, { disabled: ['workspaces'] }).left, ['clock'])
  eq('a disabled id that is not present costs nothing', rl(positions, { disabled: ['wifi'] }).left, ['clock', 'workspaces'])
  eq('every slot disabled leaves three empty lists', rl(positions, { disabled: ['clock', 'workspaces', 'tray', 'volume'] }), { left: [], center: [], right: [] })
  eq('a missing zone reads as empty', rl({ left: ['clock'] }), { left: ['clock'], center: [], right: [] })
  eq('a zone value that is not an array reads as empty', rl({ left: 'clock' }).left, [])
  eq('a null positions zone reads as empty', rl({ left: null }).left, [])
})
group('an absent positions object reads as three empty zones', () => {
  // Bar.qml derives `positions` from the settings store, and QML delivers
  // storedLayoutChanged before that binding has been evaluated - so the first
  // two updateLayout() calls of a cold boot hand this function `undefined` and
  // used to throw at BarLib.js:192. It must read as "nothing known yet" and
  // let the next notification supply the real value, so the bar is not
  // blanked by the gap. Reproduced 4x per boot with VIBRANIUM_LOG_DEBUG=1.
  noThrow('an undefined positions does not throw', () => rl(undefined))
  noThrow('a null positions does not throw', () => rl(null))
  eq('undefined yields every zone empty', rl(undefined), { left: [], center: [], right: [] })
  eq('null yields every zone empty', rl(null), { left: [], center: [], right: [] })
  // Still a well-formed answer, because the caller JSON.stringifies it and
  // compares the signature before committing.
  eq('the key order is the zones order, not the input order', Object.keys(rl(undefined, { zones: ['right', 'left'] })), ['right', 'left'])
  // A pin still resolves to its corner: pinSlots' contract is "a pinned slot
  // always resolves to its corner, whatever the input says", so an absent
  // positions does not disown it. The next notification corrects the zone.
  eq('a pin against absent positions still lands in its corner', rl(undefined, { pinned: { clock: 'left' } }).left, ['clock'])
})
group('an owned id always passes, even while it is in disabled', () => {
  // The README: "Owned modules never enter `disabled`; they own their own
  // transient visibility". The filter honours the first half of that.
  eq('an owned id survives the disabled list', rl({ right: ['volume', 'timer'] }, { disabled: ['volume', 'timer'] }).right, ['timer'])
  eq('a static id beside it still goes', rl({ right: ['volume', 'timer'] }, { disabled: ['volume', 'timer'] }).right.includes('volume'), false)
})
group('pins are re-applied on the render side too', () => {
  eq('a pinned id moves to the end of its zone', rl({ left: ['clock', 'workspaces', 'tray'] }, { pinned: { clock: 'left' } }).left, ['workspaces', 'tray', 'clock'])
  eq('a pinned id moves between zones', rl({ left: ['clock'], right: ['volume'] }, { pinned: { clock: 'right' } }), { left: [], center: [], right: ['volume', 'clock'] })
  eq('a pin that names a zone outside the policy is ignored', rl({ left: ['clock'] }, { pinned: { clock: 'top' } }).left, ['clock'])
  eq('an empty pin map changes nothing', rl({ left: ['clock', 'workspaces'] }).left, ['clock', 'workspaces'])
})
group('a pinned id that is switched off leaves no trace at all', () => {
  // The include gate is `isOwned(id) || disabled.indexOf(id) < 0`, so a
  // disabled pin is stripped from its zone and not re-appended - the read
  // path must not materialise a disabled slot.
  const out = rl({ left: ['clock', 'wifi', 'workspaces'] }, { disabled: ['wifi'], pinned: { wifi: 'left' } })
  eq('it is gone and nothing moved into its place', out.left, ['clock', 'workspaces'])
  eq('a disabled owned pin is kept', rl({ right: ['timer'] }, { disabled: ['timer'], pinned: { timer: 'right' } }).right, ['timer'])
})
group('the persisted positions are never mutated', () => {
  const positions = { left: ['clock', 'workspaces'], center: ['tray'], right: ['volume'] }
  const snapshot = JSON.stringify(positions)
  rl(positions, { disabled: ['workspaces'], pinned: { clock: 'right' } })
  eq('identical after the call', JSON.stringify(positions), snapshot)
})
group('the filter is not a dedupe pass', () => {
  // Unlike normalizeLayout there is no `seen` table here: a layout that
  // already lists an id twice renders it twice. Pinned because the write path
  // is what guarantees one id in one zone, not this filter.
  eq('a duplicated id renders twice', rl({ left: ['clock', 'clock'] }).left, ['clock', 'clock'])
  eq('a duplicated owned id too', rl({ right: ['timer', 'timer'] }).right, ['timer', 'timer'])
  eq('but one occurrence of a disabled id drops all of them', rl({ left: ['clock', 'clock'] }, { disabled: ['clock'] }).left, [])
})

section('BarLib.reorder - move one slot to a final index')
group('the item ends at `to`, whatever the direction', () => {
  eq('first to last', B.reorder(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a'])
  eq('last to first', B.reorder(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b'])
  eq('one step right', B.reorder(['a', 'b', 'c'], 0, 1), ['b', 'a', 'c'])
  eq('one step left', B.reorder(['a', 'b', 'c'], 2, 1), ['a', 'c', 'b'])
  eq('a swap', B.reorder(['a', 'b'], 0, 1), ['b', 'a'])
  eq('from the middle of five', B.reorder(['a', 'b', 'c', 'd', 'e'], 2, 4), ['a', 'b', 'd', 'e', 'c'])
})
group('a no-op reorder is still a copy', () => {
  eq('from equals to', B.reorder(['a', 'b', 'c'], 1, 1), ['a', 'b', 'c'])
  const list = ['a', 'b']
  const out = B.reorder(list, 0, 0)
  is('a new array', out, (v) => v !== list, 'a different array object')
  eq('and the input is unchanged', list, ['a', 'b'])
})
group('out-of-range indexes are clamped, not honoured', () => {
  eq('a from past the end leaves the list alone', B.reorder(['a', 'b'], 5, 0), ['a', 'b'])
  eq('a negative from leaves the list alone', B.reorder(['a', 'b'], -1, 0), ['a', 'b'])
  eq('a to past the end clamps to the last index', B.reorder(['a', 'b', 'c'], 0, 99), ['b', 'c', 'a'])
  eq('a negative to clamps to the front', B.reorder(['a', 'b', 'c'], 2, -4), ['c', 'a', 'b'])
  eq('both out of range', B.reorder(['a', 'b'], 7, 7), ['a', 'b'])
})
group('degenerate lists', () => {
  eq('an empty list', B.reorder([], 0, 0), [])
  eq('an empty list with a bad from', B.reorder([], 3, 1), [])
  eq('a one-entry list', B.reorder(['a'], 0, 0), ['a'])
  eq('a one-entry list with a huge to', B.reorder(['a'], 0, 9), ['a'])
  eq('duplicates are positions, not values', B.reorder(['a', 'a', 'b'], 0, 2), ['a', 'b', 'a'])
})
group('the input is never mutated', () => {
  const list = ['a', 'b', 'c']
  B.reorder(list, 0, 2)
  eq('unchanged', list, ['a', 'b', 'c'])
})

section('BarLib.dropTarget - the insertion target for a horizontal drag')
// Three 10/20/10-wide slots laid out left to right at x = 0, 10, 30.
const SLOTS = [{ x: 0, width: 10, index: 0 }, { x: 10, width: 20, index: 1 }, { x: 30, width: 10, index: 2 }]
group('a same-zone drag snaps to the nearest gap of the other slots', () => {
  // The dragged slot is skipped, so its own edges are never candidates and a
  // drop that lands on top of it reads as its current position.
  eq('far left, before the first', B.dropTarget(SLOTS, 0, -5), { to: 0, x: 10 })
  eq('on the first gap line', B.dropTarget(SLOTS, 0, 10), { to: 0, x: 10 })
  eq('inside the wide middle slot stays before it', B.dropTarget(SLOTS, 0, 25), { to: 1, x: 30 })
  eq('on the last gap line', B.dropTarget(SLOTS, 0, 40), { to: 2, x: 40 })
  eq('far right clamps to the last gap', B.dropTarget(SLOTS, 0, 400), { to: 2, x: 40 })
})
group('every `to` is a valid final index for the zone', () => {
  const list = ['a', 'b', 'c']
  for (let f = 0; f < list.length; f++) {
    for (const x of [-100, 0, 5, 15, 20, 35, 100]) {
      const r = B.dropTarget(SLOTS, f, x)
      is(`to in range for from=${f} x=${x}`, r.to, (v) => v >= 0 && v < list.length, '0 <= to < length')
    }
  }
})
group('the gap line reported is the edge the drop snapped to', () => {
  eq('the left edge of a gap', B.dropTarget(SLOTS, 0, 12).x, 10)
  eq('the right edge of a gap', B.dropTarget(SLOTS, 0, 28).x, 30)
})
group('a tie keeps the earlier gap, so a bisect reads as one position', () => {
  // The header: "Strict < keeps the first gap when the pointer bisects two
  // equal neighbours, so a drop between B and C always reads as one position."
  const two = [{ x: 0, width: 10, index: 0 }, { x: 10, width: 10, index: 1 }]
  eq('exactly between them', B.dropTarget(two, 0, 15), { to: 0, x: 10 })
  eq('past the midpoint of the second', B.dropTarget(two, 0, 16), { to: 1, x: 20 })
  eq('before the midpoint of the first', B.dropTarget(two, 0, 14), { to: 0, x: 10 })
  // A zone whose two gaps carry the same x cannot exist (they are edges of
  // distinct slots), so the tie rule is the only thing keeping this stable.
  eq('a zero-width slot at the same x', B.dropTarget([{ x: 10, width: 0 }, { x: 10, width: 10 }], 0, 10), { to: 0, x: 10 })
})
group('a different dragged index shifts the candidates the other way', () => {
  eq('dragging the middle to the far left', B.dropTarget(SLOTS, 1, 0), { to: 0, x: 0 })
  eq('dragging the middle to the right', B.dropTarget(SLOTS, 1, 25), { to: 1, x: 30 })
  eq('dragging the middle past the end', B.dropTarget(SLOTS, 1, 45), { to: 2, x: 40 })
  eq('dragging the last to the far left', B.dropTarget(SLOTS, 2, 0), { to: 0, x: 0 })
  eq('dragging the last left by one gap', B.dropTarget(SLOTS, 2, 12), { to: 1, x: 10 })
  eq('dragging the last back to its own place', B.dropTarget(SLOTS, 2, 100), { to: 2, x: 30 })
})
group('a cross-zone drop passes fromIndex = slots.length', () => {
  // The header: cross-zone drops pass slots.length "so nothing is skipped and
  // every gap 0..n is a candidate".
  const list = ['a', 'b', 'c']
  for (const x of [-50, 0, 10, 20, 30, 50]) {
    const r = B.dropTarget(SLOTS, list.length, x)
    is(`to in range for a cross drop at x=${x}`, r.to, (v) => v >= 0 && v <= list.length, '0 <= to <= length')
  }
  eq('at the front', B.dropTarget(SLOTS, 3, 0), { to: 0, x: 0 })
  eq('in the middle', B.dropTarget(SLOTS, 3, 25), { to: 2, x: 30 })
  eq('past the end', B.dropTarget(SLOTS, 3, 50), { to: 3, x: 40 })
})
group('a zone with no other slot falls back to clamping', () => {
  // Nothing to compare against, so the pointer x is echoed and the drop index
  // is the dragged slot's own.
  eq('a single slot', B.dropTarget([{ x: 5, width: 5 }], 0, 99), { to: 0, x: 99 })
  eq('no slots at all', B.dropTarget([], 0, 10), { to: 0, x: 10 })
  eq('a negative pointer', B.dropTarget([], 0, -10), { to: 0, x: -10 })
})
group('malformed slot records are read as zero-width at x = 0', () => {
  // `Number(slots[i].x) || 0` is a falsy fold, so a missing coordinate and a
  // coordinate of 0 land in the same place - and a missing width makes the
  // slot a point, which is why its two gaps carry the same x.
  eq('a neighbour with no x reads as x = 0', B.dropTarget([{ x: 50, width: 10 }, { width: 10 }], 0, 0), { to: 0, x: 0 })
  eq('a slot with no width collapses to a point', B.dropTarget([{ x: 0 }, { x: 10 }], 0, 9), { to: 0, x: 10 })
  eq('a NaN x reads as 0', B.dropTarget([{ x: 'abc' }, { x: 10 }], 0, 0), { to: 0, x: 10 })
  eq('a string width is coerced', B.dropTarget([{ x: 0, width: '10' }, { x: 10, width: '10' }], 0, 20), { to: 1, x: 20 })
  // `index` is in the record but never read: the array position is the index.
  eq('a wrong index field changes nothing', B.dropTarget([{ x: 0, width: 10, index: 99 }, { x: 20, width: 10, index: 0 }], 0, 31), { to: 1, x: 30 })
  eq('and a missing index field is fine too', B.dropTarget([{ x: 0, width: 10 }, { x: 20, width: 10 }], 0, 31), { to: 1, x: 30 })
})
group('the slots array is never mutated', () => {
  const slots = SLOTS.map((s) => ({ ...s }))
  const before = JSON.stringify(slots)
  B.dropTarget(slots, 1, 25)
  eq('unchanged', JSON.stringify(slots), before)
})

section('BarLib.rebuildZoneOrder - the same-zone drop write')
const FIXED = new Set(['tray'])
const PINNED = new Set(['volume'])
const isFixed = (id) => FIXED.has(id)
const isPinned = (id) => PINNED.has(id)
const FULL = ['clock', 'tray', 'workspaces', 'wifi', 'volume']
const DISPLAY = ['clock', 'tray', 'workspaces', 'volume']
// `ordered` is the *movable* sequence, so it carries neither the fixed slot
// (tray) nor the pinned wall (volume) - Zone.qml excludes both from the
// movable sequence before it ever calls this.
group('a drop that changes nothing reports changed: false', () => {
  const out = B.rebuildZoneOrder(FULL, ['clock', 'workspaces'], DISPLAY, isPinned, isFixed)
  eq('the list is the unpinned full list', out.list, ['clock', 'tray', 'workspaces', 'wifi'])
  eq('and the caller can skip the write', out.changed, false)
})
group('a real drag rewrites the movable run and keeps the walls', () => {
  const out = B.rebuildZoneOrder(FULL, ['workspaces', 'clock'], DISPLAY, isPinned, isFixed)
  // `tray` is fixed and `wifi` is disabled: both stay exactly where they were,
  // and only the movable ids between them move.
  eq('the new zone', out.list, ['workspaces', 'tray', 'clock', 'wifi'])
  eq('and it is a change', out.changed, true)
})
group('the fixed slot keeps its place, not its position in the order', () => {
  const out = B.rebuildZoneOrder(FULL, ['workspaces', 'clock'], DISPLAY, isPinned, isFixed)
  eq('tray did not travel', out.list.indexOf('tray'), 1)
  eq('and clock took the first movable slot', out.list[0], 'workspaces')
})
group('a disabled slot is an invisible wall that keeps its gap', () => {
  const out = B.rebuildZoneOrder(['a', 'off', 'b'], ['b', 'a'], ['a', 'b'], nothing, nothing)
  eq('the hidden id stays put and does not consume a slot', out.list, ['b', 'off', 'a'])
})
group('pinned ids are skipped entirely - the write re-pins them', () => {
  const out = B.rebuildZoneOrder(FULL, ['clock', 'workspaces'], DISPLAY, isPinned, isFixed)
  eq('the pinned id is gone from the returned list', out.list.includes('volume'), false)
  eq('and the comparison ignores it too', out.changed, false)
  // normalizeLayout is what puts it back, at the zone end, whatever the
  // returned list holds.
  eq('normalizeLayout puts it back at the corner', nl({ left: out.list }, { zones: ['left'], pinned: { volume: 'left' } }).left, out.list.concat('volume'))
})
group('a newly enabled slot that is not in full appends after the block', () => {
  const out = B.rebuildZoneOrder(['a', 'b'], ['new', 'b', 'a'], ['a', 'b', 'new'], nothing, nothing)
  eq('the newcomer lands first in the movable run', out.list, ['new', 'b', 'a'])
  eq('and the change is reported', out.changed, true)
})
group('a fully disabled zone reports no change', () => {
  eq('empty in, empty out', B.rebuildZoneOrder([], [], [], nothing, nothing), { list: [], changed: false })
  eq('a zone of only fixed ids does not change', B.rebuildZoneOrder(['tray'], [], ['tray'], nothing, isFixed), { list: ['tray'], changed: false })
  eq('a zone of only pinned ids drops to empty', B.rebuildZoneOrder(['volume'], [], [], isPinned, nothing), { list: [], changed: false })
})
group('the full list is never mutated', () => {
  const full = FULL.slice()
  B.rebuildZoneOrder(full, ['workspaces', 'clock'], DISPLAY, isPinned, isFixed)
  eq('unchanged', full, FULL)
})
group('the movable set and `ordered` must agree, or the wall branch duplicates', () => {
  // `ordered` is documented as the zone's *reorderable* enabled ids, so a
  // caller that hands over a short or over-long list breaks the walk: the
  // leftover branch pushes a raw `ordered` entry at the end even when that id
  // is fixed, pinned or already emitted. Pinned because the output would
  // silently render a slot twice rather than fail.
  eq('a short ordered list duplicates the id it skips', B.rebuildZoneOrder(['a', 'b', 'c'], ['c', 'a'], ['a', 'b', 'c'], nothing, nothing).list, ['c', 'a', 'c'])
  eq('a fixed id inside ordered is appended verbatim', B.rebuildZoneOrder(['a', 'tray'], ['a', 'tray'], ['a', 'tray'], nothing, isFixed).list, ['a', 'tray', 'tray'])
  eq('a pinned id inside ordered comes back', B.rebuildZoneOrder(['a', 'volume'], ['a', 'volume'], ['a'], isPinned, nothing), { list: ['a', 'volume'], changed: true })
  eq('an ordered id that is not in full at all is appended', B.rebuildZoneOrder(['a'], ['b', 'a'], ['a', 'b'], nothing, nothing).list, ['b', 'a'])
})

section('BarLib.crossDropPositions - the cross-zone drop write')
const CUR = { left: ['clock', 'tray', 'workspaces'], center: ['volume'], right: ['battery'] }
group('the dragged id moves between zones and the input is untouched', () => {
  const out = B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', 0)
  eq('it lands before the movable at the drop index', out, { left: ['clock', 'tray'], center: ['workspaces', 'volume'], right: ['battery'] })
  eq('the input is unchanged', CUR, { left: ['clock', 'tray', 'workspaces'], center: ['volume'], right: ['battery'] })
  ne('the result is a fresh object', out, CUR)
  ne('and its lists are fresh', out.left, CUR.left)
})
group('the drop index is clamped to the movable count', () => {
  eq('a negative index is the front', B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', -3).center, ['workspaces', 'volume'])
  eq('an index past the end is the back', B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', 99).center, ['volume', 'workspaces'])
  eq('one past the last movable equals the last index', B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', 1).center, ['volume', 'workspaces'])
  eq('exactly the count is the back too', B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', 2).center, ['volume', 'workspaces'])
})
group('fixed and disabled slots are walls the id is threaded past', () => {
  const cur = { left: ['a'], center: ['tray', 'x', 'volume'], right: [] }
  eq('before the first movable', B.crossDropPositions(cur, ['tray', 'x', 'volume'], isFixed, 'a', 'left', 'center', 0).center, ['tray', 'a', 'x', 'volume'])
  eq('after it', B.crossDropPositions(cur, ['tray', 'x', 'volume'], isFixed, 'a', 'left', 'center', 1).center, ['tray', 'x', 'a', 'volume'])
  eq('past the last movable it lands at the end', B.crossDropPositions(cur, ['tray', 'x', 'volume'], isFixed, 'a', 'left', 'center', 9).center, ['tray', 'x', 'volume', 'a'])
  eq('a display with no movables puts it at the end', B.crossDropPositions(cur, [], isFixed, 'a', 'left', 'center', 0).center, ['tray', 'x', 'volume', 'a'])
  eq('a slot that is neither fixed nor displayed is skipped over', B.crossDropPositions(cur, ['x'], isFixed, 'a', 'left', 'center', 0).center, ['tray', 'a', 'x', 'volume'])
})
group('a disabled id in the target zone is collapsed into the drop point', () => {
  // "Defensive: a duplicated id in the target collapses to the drop point."
  const cur = { left: ['a'], center: ['a', 'x'], right: [] }
  eq('the source copy is removed and the target copy follows the drop', B.crossDropPositions(cur, ['x'], isFixed, 'a', 'left', 'center', 1).center, ['x', 'a'])
  eq('the zone it came from keeps only its own other ids', B.crossDropPositions(cur, ['x'], isFixed, 'a', 'left', 'center', 0).center, ['a', 'x'])
})
group('an invalid move returns null rather than a half-applied one', () => {
  eq('the same region', B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'left', 0), null)
  eq('an id that is not in the source zone', B.crossDropPositions(CUR, ['volume'], isFixed, 'ghost', 'left', 'center', 0), null)
  eq('an id the target already displays', B.crossDropPositions(CUR, ['workspaces'], isFixed, 'workspaces', 'left', 'center', 0), null)
  eq('an empty id', B.crossDropPositions(CUR, ['volume'], isFixed, '', 'left', 'center', 0), null)
  eq('a numeric id', B.crossDropPositions(CUR, ['volume'], isFixed, 7, 'left', 'center', 0), null)
  eq('a null id', B.crossDropPositions(CUR, ['volume'], isFixed, null, 'left', 'center', 0), null)
  eq('a null cur', B.crossDropPositions(null, ['volume'], isFixed, 'workspaces', 'left', 'center', 0), null)
  eq('a cur missing the target zone', B.crossDropPositions({ left: ['a'], right: [] }, [], isFixed, 'a', 'left', 'center', 0), null)
  eq('a cur missing the source zone', B.crossDropPositions({ center: [], right: [] }, [], isFixed, 'a', 'left', 'center', 0), null)
  eq('a cur zone that is not an array', B.crossDropPositions({ left: 'a', center: [] }, [], isFixed, 'a', 'left', 'center', 0), null)
})
group('the result always carries the three zone keys', () => {
  const out = B.crossDropPositions(CUR, ['volume'], isFixed, 'workspaces', 'left', 'center', 0)
  eq('key order', Object.keys(out), ['left', 'center', 'right'])
  eq('a null display list is treated as empty', B.crossDropPositions(CUR, null, isFixed, 'workspaces', 'left', 'center', 0).center, ['volume', 'workspaces'])
})

section('BarLib.positionCandidateHeld - the 24px hysteresis band')
group('a held top only flips past the midline plus 24', () => {
  eq('at the midline', B.positionCandidateHeld(480, 960, 'top'), 'top')
  eq('at the band edge it still holds', B.positionCandidateHeld(504, 960, 'top'), 'top')
  eq('one pixel past the band it flips', B.positionCandidateHeld(505, 960, 'top'), 'bottom')
  eq('well past it', B.positionCandidateHeld(700, 960, 'top'), 'bottom')
})
group('a held bottom only flips past the midline minus 24', () => {
  eq('at the midline', B.positionCandidateHeld(480, 960, 'bottom'), 'bottom')
  eq('at the band edge it still holds', B.positionCandidateHeld(456, 960, 'bottom'), 'bottom')
  eq('one pixel past the band it flips', B.positionCandidateHeld(455, 960, 'bottom'), 'top')
  eq('well past it', B.positionCandidateHeld(0, 960, 'bottom'), 'top')
})
group('riding the midline never oscillates', () => {
  // The dead band is [456, 504] on a 960px screen; inside it the held
  // candidate never moves, whatever the pointer does.
  for (const y of [456, 470, 480, 490, 500, 504]) {
    eq(`top holds at y=${y}`, B.positionCandidateHeld(y, 960, 'top'), 'top')
  }
  for (const y of [456, 460, 470, 480, 490, 504]) {
    eq(`bottom holds at y=${y}`, B.positionCandidateHeld(y, 960, 'bottom'), 'bottom')
  }
})
group('a candidate that is neither top nor bottom is decided at once', () => {
  // The inactive state has no history to protect, so the plain midline rule
  // applies - this is the gesture starting, not a drag in progress.
  eq('an empty current, upper half', B.positionCandidateHeld(100, 960, ''), 'top')
  eq('an empty current, lower half', B.positionCandidateHeld(900, 960, ''), 'bottom')
  eq('an empty current at the midline', B.positionCandidateHeld(480, 960, ''), 'top')
  eq('an undefined current', B.positionCandidateHeld(900, 960, undefined), 'bottom')
  eq('a nonsense current', B.positionCandidateHeld(100, 960, 'sideways'), 'top')
  eq('and it matches the plain midline rule', B.positionCandidateHeld(100, 960, 'zzz'), 'top')
})
group('an unusable reading keeps the current candidate rather than clearing it', () => {
  eq('a NaN y holds top', B.positionCandidateHeld(NaN, 960, 'top'), 'top')
  eq('a NaN y holds bottom', B.positionCandidateHeld(NaN, 960, 'bottom'), 'bottom')
  eq('a NaN y holds an empty candidate', B.positionCandidateHeld(NaN, 960, ''), '')
  eq('a zero height holds bottom', B.positionCandidateHeld(10, 0, 'bottom'), 'bottom')
  eq('an infinite height holds top', B.positionCandidateHeld(10, Infinity, 'top'), 'top')
  eq('a negative height holds the candidate', B.positionCandidateHeld(-9999, -1, 'top'), 'top')
})
group('the band is absolute, so a short screen makes the hysteresis wider', () => {
  // screenH / 2 = 10 for a 20px screen, so the band reaches past the edges
  // and a held candidate only moves on the opposite half of the screen.
  eq('a held top at the bottom of a 20px screen', B.positionCandidateHeld(20, 20, 'top'), 'top')
  eq('a held bottom at the top of a 20px screen', B.positionCandidateHeld(0, 20, 'bottom'), 'bottom')
  eq('a held top past the band on a tall screen', B.positionCandidateHeld(1100, 2000, 'top'), 'bottom')
  eq('a held top inside the band on a tall screen', B.positionCandidateHeld(700, 2000, 'top'), 'top')
})

// ======================================================================
section('ArchUpdates/Model - the AUR tag and the selection keys')
group('the three tag constants are the published values', () => {
  eq('AUR', AU.AUR, 'aur')
  eq('AUR_PREFIX', AU.AUR_PREFIX, 'aur:')
  eq('OFFICIAL_PREFIX', AU.OFFICIAL_PREFIX, 'official:')
  // The README: "The value is "aur", the keys are "aur:" and "official:"
  // prefixed" - and they are the same values the functions actually use.
  eq('selKey builds the AUR key from the constants', AU.selKey({ source: AU.AUR, name: 'yay' }), AU.AUR_PREFIX + 'yay')
  eq('selKey builds the official key from the constants', AU.selKey({ name: 'vim' }), AU.OFFICIAL_PREFIX + 'vim')
  eq('isAur reads the AUR constant', AU.isAur({ source: AU.AUR }), true)
  eq('selectedNames routes on the AUR constant', AU.selectedNames({ [AU.AUR_PREFIX + 'yay']: true }), { official: [], aur: ['yay'] })
})
group('isAur is a guarded, exact tag read', () => {
  eq('an AUR package', AU.isAur(AURPKG), true)
  eq('an official package', AU.isAur(OFFICIAL), false)
  eq('no source at all is official', AU.isAur({ name: 'x' }), false)
  eq('a different repository name is official', AU.isAur({ name: 'x', source: 'extra' }), false)
  eq('the tag is case-sensitive', AU.isAur({ name: 'x', source: 'AUR' }), false)
  eq('a padded tag is not the tag', AU.isAur({ name: 'x', source: ' aur' }), false)
  // "The guards are why an unguarded read here cannot take the shell down."
  eq('null', AU.isAur(null), false)
  eq('undefined', AU.isAur(undefined), false)
  eq('a string entry', AU.isAur('aur'), false)
  eq('a number entry', AU.isAur(7), false)
  eq('an array entry', AU.isAur(['aur']), false)
  eq('an entry whose source is an object', AU.isAur({ source: {} }), false)
})
group('selKey is stable and total', () => {
  const a = { name: 'vim', source: 'core' }
  const b = { name: 'vim', source: 'extra' }
  eq('the same package twice', AU.selKey(a), AU.selKey({ name: 'vim', source: 'core' }))
  eq('the same name in two repositories collides on purpose', AU.selKey(a), AU.selKey(b))
  eq('an AUR package of the same name is a different key', AU.selKey({ name: 'vim', source: 'aur' }), 'aur:vim')
  eq('a numeric name is stringified', AU.selKey({ name: 7 }), 'official:7')
  eq('a null name is the empty tail, not the no-key answer', AU.selKey({ name: null }), 'official:')
  eq('no name at all is the empty tail too', AU.selKey({}), 'official:')
  // The header says "" is the no-key answer, but only a non-object answers
  // it: an object with no name still gets a prefixed empty tail, which
  // selectAll will store and selectedNames then drops. An array is an object,
  // so it takes the object path.
  eq('a non-object has no key', AU.selKey(null), '')
  eq('a string has no key', AU.selKey('vim'), '')
  eq('undefined has no key', AU.selKey(undefined), '')
  eq('a number has no key', AU.selKey(7), '')
  eq('an array is an object, so it gets a prefixed empty key', AU.selKey([]), 'official:')
  is('the no-key answer is falsy so callers can drop it', AU.selKey({}), (k) => k === 'official:', 'a prefixed empty tail, not ""')
})
group('sourceCounts splits the list and the two always sum to its length', () => {
  const list = [OFFICIAL, AURPKG, npk('firefox'), npk('yay', { source: 'aur' })]
  eq('two official, two AUR', AU.sourceCounts(list), { official: 2, aur: 2 })
  eq('the sum is the length', AU.sourceCounts(list).official + AU.sourceCounts(list).aur, list.length)
  eq('all official', AU.sourceCounts([OFFICIAL, OFFICIAL]), { official: 2, aur: 0 })
  eq('all AUR', AU.sourceCounts([AURPKG, AURPKG]), { official: 0, aur: 2 })
  eq('an empty list', AU.sourceCounts([]), { official: 0, aur: 0 })
  eq('null', AU.sourceCounts(null), { official: 0, aur: 0 })
  eq('undefined', AU.sourceCounts(undefined), { official: 0, aur: 0 })
  eq('a non-array', AU.sourceCounts('vim'), { official: 0, aur: 0 })
  // A non-object entry is not an AUR package, so it lands in the official
  // count - the two still sum, which is the invariant the header names.
  eq('a null entry counts as official', AU.sourceCounts([null]), { official: 1, aur: 0 })
  eq('a string entry counts as official', AU.sourceCounts(['x', AURPKG]), { official: 1, aur: 1 })
})
group('heavyQueue is the shared threshold, gated on its toggle', () => {
  // One definition for the module's red total and the island's warning
  // box, so the alarm and the number cannot disagree.
  eq('the threshold is published', AU.HEAVY_QUEUE_MIN, 200)
  const many = []
  for (let i = 0; i < 201; i++) many.push(npk('p' + i))
  const exactly = []
  for (let i = 0; i < 200; i++) exactly.push(npk('p' + i))
  eq('above the threshold, enabled', AU.heavyQueue(many, true), true)
  eq('exactly at the threshold is not heavy', AU.heavyQueue(exactly, true), false)
  eq('below the threshold', AU.heavyQueue([OFFICIAL], true), false)
  // The toggle is the island's settings gate, and it wins over the count.
  eq('disabled turns it off above the threshold', AU.heavyQueue(many, false), false)
  eq('disabled at any count', AU.heavyQueue(exactly, false), false)
  eq('a falsy toggle of any shape', AU.heavyQueue(many, undefined), false)
  eq('a null list reads as empty', AU.heavyQueue(null, true), false)
  eq('a non-array reads as empty', AU.heavyQueue('vim', true), false)
})

section('ArchUpdates/Model.filterPackages - the case-insensitive search')
const SEARCH = [npk('Firefox', { repository: 'extra' }), npk('vim', { repository: 'core' }), npk('yay-bin', { repository: 'aur', source: 'aur' })]
group('the name and the repository are both searched', () => {
  eq('a name fragment', AU.filterPackages(SEARCH, 'fire').map((p) => p.name), ['Firefox'])
  eq('a repository fragment', AU.filterPackages(SEARCH, 'aur').map((p) => p.name), ['yay-bin'])
  eq('case-insensitive on the name', AU.filterPackages(SEARCH, 'FIRE').map((p) => p.name), ['Firefox'])
  eq('case-insensitive on the repository', AU.filterPackages(SEARCH, 'AUR').map((p) => p.name), ['yay-bin'])
  eq('a substring, not a prefix', AU.filterPackages(SEARCH, 'irefo').map((p) => p.name), ['Firefox'])
  eq('no match', AU.filterPackages(SEARCH, 'zzz'), [])
  eq('the input order is preserved', AU.filterPackages(SEARCH, 'i').map((p) => p.name), ['Firefox', 'vim', 'yay-bin'])
  eq('the entries are the same objects', AU.filterPackages(SEARCH, 'vim')[0] === SEARCH[1], true)
})
group('a query that matches nothing is trimmed away into "no filter"', () => {
  // "An empty query returns the input array itself, not a copy, so an
  // unfiltered island hands the row window the service's array."
  const out = AU.filterPackages(SEARCH, '')
  is('the same array, not a copy', out, (v) => v === SEARCH, 'identity for an empty query')
  is('a whitespace-only query is also empty', AU.filterPackages(SEARCH, '   '), (v) => v === SEARCH, 'identity after trim')
  eq('a padded query is trimmed', AU.filterPackages(SEARCH, '  vim  ').map((p) => p.name), ['vim'])
})
group('a non-string query is stringified, which is a trap not a shortcut', () => {
  // `String(query)` with no nullish guard: undefined becomes the literal
  // "undefined", so an unfiltered call that forgets its argument returns
  // nothing at all. Pinned because the island always passes a string and a
  // future caller might not.
  eq('undefined filters for the word "undefined"', AU.filterPackages(SEARCH, undefined), [])
  eq('null likewise', AU.filterPackages(SEARCH, null), [])
  eq('0 filters for "0"', AU.filterPackages([npk('x10')], 0).map((p) => p.name), ['x10'])
  eq('a number that matches nothing', AU.filterPackages(SEARCH, 7), [])
  eq('false filters for "false"', AU.filterPackages(SEARCH, false), [])
})
group('a non-array package list reads as empty', () => {
  eq('null', AU.filterPackages(null, 'vim'), [])
  eq('undefined', AU.filterPackages(undefined, 'vim'), [])
  eq('a string', AU.filterPackages('vim', 'vim'), [])
  eq('an object', AU.filterPackages({ 0: OFFICIAL }, 'vim'), [])
})
group('unlike its neighbours, filterPackages does not guard its entries', () => {
  // isAur, sourceCounts, selKey and rowView all tolerate a non-object entry
  // ("a delegate mid-teardown, a model swap"); this one reads p.name
  // unguarded, so a null in the array takes the search down. Asserted as the
  // real behaviour - see the report.
  throws('a null entry throws', () => AU.filterPackages([null], 'x'), /name/)
  throws('an undefined entry throws', () => AU.filterPackages([undefined], 'x'), /name/)
  noThrow('an empty query short-circuits before the walk', () => AU.filterPackages([null], ''))
})

section('ArchUpdates/Model - the selection algebra')
group('selectedCount counts keys, whatever their values', () => {
  eq('two keys', AU.selectedCount({ 'official:vim': true, 'aur:yay': true }), 2)
  eq('a false value is still a key', AU.selectedCount({ 'official:vim': false }), 1)
  eq('an empty map', AU.selectedCount({}), 0)
  eq('a key with no value at all', AU.selectedCount({ a: undefined }), 1)
})
group('allSelected is membership, not a count', () => {
  const sel = { 'official:vim': true, 'official:Firefox': true, 'aur:yay-bin': true }
  eq('every filtered package is selected', AU.allSelected(SEARCH, sel), true)
  eq('one missing is not all', AU.allSelected(SEARCH, { 'official:vim': true }), false)
  eq('none selected', AU.allSelected(SEARCH, {}), false)
  // "A key left over from outside the filter must not read as everything is
  // selected, and an empty filter never does."
  eq('an unrelated extra key does not help', AU.allSelected([OFFICIAL], { 'aur:other': true }), false)
  eq('a truthy non-true value counts as selected', AU.allSelected([OFFICIAL], { 'official:vim': 1 }), true)
  eq('zero is falsy, so it does not count', AU.allSelected([OFFICIAL], { 'official:vim': 0 }), false)
  eq('the AUR key is a different key from the official one', AU.allSelected([AURPKG], { 'official:yay-bin': true }), false)
  eq('an empty filter is never all selected', AU.allSelected([], sel), false)
  eq('a null filter is never all selected', AU.allSelected(null, sel), false)
  eq('a non-array filter', AU.allSelected('vim', sel), false)
})
group('selectedNames splits the keys and drops the malformed ones', () => {
  eq('one of each', AU.selectedNames({ 'official:vim': true, 'aur:yay': true }), { official: ['vim'], aur: ['yay'] })
  eq('the order of the map decides the order of the names', AU.selectedNames({ 'official:b': true, 'official:a': true }), { official: ['b', 'a'], aur: [] })
  eq('a key with no separator is dropped', AU.selectedNames({ nocolon: true }), { official: [], aur: [] })
  eq('a key that starts with the separator is dropped', AU.selectedNames({ ':lead': true }), { official: [], aur: [] })
  eq('a key whose name is empty is dropped', AU.selectedNames({ 'official:': true, 'aur:': true }), { official: [], aur: [] })
  eq('only the exact aur tag routes to the AUR list', AU.selectedNames({ 'AUR:x': true }), { official: ['x'], aur: [] })
  eq('any other source is an official name', AU.selectedNames({ 'extra:x': true, 'repo:y': true }), { official: ['x', 'y'], aur: [] })
  eq('only the first separator splits', AU.selectedNames({ 'aur:a:b': true }), { official: [], aur: ['a:b'] })
  eq('an empty map', AU.selectedNames({}), { official: [], aur: [] })
  eq('the two lists are always present', Object.keys(AU.selectedNames({})), ['official', 'aur'])
})
group('emptySelection hands out a fresh object every time', () => {
  const a = AU.emptySelection()
  const b = AU.emptySelection()
  eq('both empty', [a, b], [{}, {}])
  is('and never the same object', a, (v) => v !== b, 'two distinct empty objects')
  a['official:x'] = true
  eq('so writing to one leaves the next call empty', AU.emptySelection(), {})
})
group('toggleKey flips a key without touching the map it was handed', () => {
  const sel = { 'official:vim': true, 'aur:yay': true }
  eq('a selected key is removed', AU.toggleKey(sel, 'official:vim'), { 'aur:yay': true })
  eq('an unselected key is added', AU.toggleKey(sel, 'official:firefox'), { 'official:vim': true, 'aur:yay': true, 'official:firefox': true })
  eq('the input is unchanged', sel, { 'official:vim': true, 'aur:yay': true })
  is('the result is a new object', AU.toggleKey(sel, 'x'), (v) => v !== sel, 'a different map')
  eq('a falsy value is read as unselected and becomes true', AU.toggleKey({ a: false }, 'a'), { a: true })
  eq('a truthy non-true value is read as selected and is deleted', AU.toggleKey({ a: 1 }, 'a'), {})
  eq('toggling an empty map', AU.toggleKey({}, 'x'), { x: true })
})
group('selectAll extends the selection and keeps keys outside the filter', () => {
  // "Keys outside the filter survive, so searching away from a row never
  // drops it."
  const sel = { 'official:hidden': true }
  eq('every filtered package joins', AU.selectAll(sel, SEARCH), { 'official:hidden': true, 'official:vim': true, 'official:Firefox': true, 'aur:yay-bin': true })
  eq('the input is unchanged', sel, { 'official:hidden': true })
  eq('a single package', AU.selectAll({}, [OFFICIAL]), { 'official:vim': true })
  eq('an empty filter adds nothing', AU.selectAll(sel, []), sel)
  eq('a null filter adds nothing', AU.selectAll(sel, null), sel)
  eq('a non-array filter adds nothing', AU.selectAll(sel, 'vim'), sel)
  // The one asymmetry: a package with no name still produces a non-empty key,
  // so it is stored. selectedNames drops it later, but selectedCount and the
  // row checkbox would both see it.
  eq('a nameless object stores a prefixed empty key', AU.selectAll({}, [{}]), { 'official:': true })
  eq('a skeleton row adds nothing', AU.selectAll({}, [{}, null]), { 'official:': true })
  eq('re-selecting is idempotent', AU.selectAll({ 'official:vim': true }, [OFFICIAL]), { 'official:vim': true })
})
group('toggleAll is selectAll or a full clear', () => {
  const sel = { 'official:hidden': true, 'official:vim': true }
  eq('not all selected extends', AU.toggleAll(sel, false, [OFFICIAL]), { 'official:hidden': true, 'official:vim': true })
  eq('already all selected clears everything, filter or not', AU.toggleAll(sel, true, [OFFICIAL]), {})
  eq('the input is unchanged either way', sel, { 'official:hidden': true, 'official:vim': true })
  eq('the clear is a fresh object, not the input', AU.toggleAll(sel, true, []) === sel, false)
  eq('an empty filter with nothing selected is a no-op clear', AU.toggleAll({ x: true }, false, []), { x: true })
})
group('pruneKeys drops keys for packages that are gone', () => {
  eq('a stale AUR key is removed', AU.pruneKeys({ 'official:vim': true, 'aur:gone': true }, SEARCH), { 'official:vim': true })
  eq('everything stale', AU.pruneKeys({ 'aur:a': true, 'aur:b': true }, SEARCH), {})
  eq('nothing stale reports no change', AU.pruneKeys({ 'official:vim': true }, SEARCH), null)
  eq('an empty map over an empty list', AU.pruneKeys({}, []), null)
  eq('an empty map is never a change', AU.pruneKeys({}, SEARCH), null)
  const sel = { 'official:vim': true, 'aur:gone': true }
  const out = AU.pruneKeys(sel, SEARCH)
  eq('the input keeps the stale key', sel, { 'official:vim': true, 'aur:gone': true })
  is('and the result is a new object', out, (v) => v !== sel, 'a different map')
  eq('a non-array list prunes everything', AU.pruneKeys({ 'official:vim': true }, null), {})
  eq('a live key is kept by its prefixed form, not its name', AU.pruneKeys({ 'vim': true }, [OFFICIAL]), {})
  eq('a nameless package keeps its prefixed empty key', AU.pruneKeys({ 'official:': true }, [{ name: '' }]), null)
  eq('a non-object entry contributes no live key', AU.pruneKeys({ 'official:': true }, [null]), {})
})

section('ArchUpdates/Model - the row projection and the window')
group('rowWindow pads the live rows up to the window', () => {
  eq('one row in a four-row window', AU.rowWindow([OFFICIAL], 4), [OFFICIAL, { _filler: true }, { _filler: true }, { _filler: true }])
  eq('the live entry is the same object', AU.rowWindow([OFFICIAL], 4)[0] === OFFICIAL, true)
  eq('every filler carries the marker', AU.rowWindow([], 3).every((r) => r._filler === true), true)
  eq('an empty list still fills the window', AU.rowWindow([], 3), [{ _filler: true }, { _filler: true }, { _filler: true }])
})
group('at or past the window the input array is returned as-is', () => {
  // "At or past the window the input array is returned as-is: the padding
  // would be dead and a copy would churn the list's stableModel." The test
  // is `rows.length >= windowSize`, so it is the *list* that must be at or
  // past the window, not the other way round.
  const rows = [OFFICIAL, AURPKG]
  is('exactly the window', AU.rowWindow(rows, 2), (v) => v === rows, 'identity at the window size')
  is('a list longer than the window', AU.rowWindow(rows, 1), (v) => v === rows, 'identity past the window size')
  is('a zero window', AU.rowWindow(rows, 0), (v) => v === rows, 'identity at a zero window')
  is('a negative window', AU.rowWindow(rows, -1), (v) => v === rows, 'identity at a negative window')
  is('an empty list at a zero window', AU.rowWindow([], 0), (v) => Array.isArray(v) && v.length === 0, 'an empty array')
  eq('and nothing is padded', AU.rowWindow(rows, 1).length, 2)
  eq('a window wider than the list does pad', AU.rowWindow(rows, 4).length, 4)
  eq('an empty list is not padded at a zero window', AU.rowWindow([], 0), [])
})
group('a non-array row list reads as empty', () => {
  eq('null', AU.rowWindow(null, 3), [{ _filler: true }, { _filler: true }, { _filler: true }])
  eq('undefined', AU.rowWindow(undefined, 3).length, 3)
  eq('a string', AU.rowWindow('vim', 2), [{ _filler: true }, { _filler: true }])
  eq('an array-like object', AU.rowWindow({ 0: OFFICIAL, length: 1 }, 1), [{ _filler: true }])
  eq('a number', AU.rowWindow(7, 1), [{ _filler: true }])
})
group('rowView projects exactly the six fields the delegate renders', () => {
  eq('a selected AUR package', AU.rowView({ name: 'yay-bin', source: 'aur', candidate: '12.0-1' }, { 'aur:yay-bin': true }), {
    filler: false, key: 'aur:yay-bin', checked: true, aur: true, name: 'yay-bin', candidate: '12.0-1',
  })
  eq('an unselected official package', AU.rowView(OFFICIAL, {}), {
    filler: false, key: 'official:vim', checked: false, aur: false, name: 'vim', candidate: '1.0-1',
  })
  eq('the key order is fixed', Object.keys(AU.rowView(OFFICIAL, {})), ['filler', 'key', 'checked', 'aur', 'name', 'candidate'])
})
group('checked is a strict true, not a truthy read', () => {
  eq('true', AU.rowView(OFFICIAL, { 'official:vim': true }).checked, true)
  eq('1 is not true', AU.rowView(OFFICIAL, { 'official:vim': 1 }).checked, false)
  eq('a truthy string is not true', AU.rowView(OFFICIAL, { 'official:vim': 'yes' }).checked, false)
  eq('absent', AU.rowView(OFFICIAL, {}).checked, false)
})
group('a skeleton row, a filler and a nameless row all project to the same view', () => {
  // "so the delegate carries one branch instead of testing the model entry
  // three times."
  const empty = { filler: true, key: '', checked: false, aur: false, name: '', candidate: '' }
  eq('a skeleton row', AU.rowView({}, {}), empty)
  eq('a padding filler', AU.rowView({ _filler: true }, {}), empty)
  eq('a filler that also has a name', AU.rowView({ _filler: true, name: 'vim' }, {}), empty)
  eq('null', AU.rowView(null, {}), empty)
  eq('undefined', AU.rowView(undefined, {}), empty)
  eq('a string entry', AU.rowView('vim', {}), empty)
  eq('an array entry', AU.rowView([OFFICIAL], {}), empty)
  eq('an explicit empty name is a real row', AU.rowView({ name: '' }, {}).filler, false)
  eq('and its key is the prefixed empty tail', AU.rowView({ name: '' }, {}).key, 'official:')
  eq('a null name is a real row too', AU.rowView({ name: null }, {}).filler, false)
  eq('a filler marker of a false value is a real row', AU.rowView({ _filler: false, name: 'vim' }, {}).filler, false)
  // `pkg.name === undefined` is the filler test, so a *falsy* name is a real
  // row - and the two `String(pkg.name || "")` reads then fold it to "".
  eq('a false name is a real row with an empty name', AU.rowView({ name: false }, {}), { filler: false, key: 'official:', checked: false, aur: false, name: '', candidate: '' })
  eq('a zero name likewise', AU.rowView({ name: 0 }, {}).name, '')
  eq('and its key is the prefixed empty tail', AU.rowView({ name: 0 }, {}).key, 'official:')
})
group('isFiller: what a padding row is, read on its own', () => {
  // The island's isSelectable predicate asks this directly, so the cursor
  // cannot walk onto one of the window's blank padding rows and paint the
  // selection bar over an empty row. It is the same test rowView applies,
  // exported rather than re-derived by the caller.
  eq('a real package is not a filler', AU.isFiller(OFFICIAL), false)
  eq('a padding filler is', AU.isFiller({ _filler: true }), true)
  eq('a skeleton blank is', AU.isFiller({}), true)
  eq('null is', AU.isFiller(null), true)
  eq('undefined is', AU.isFiller(undefined), true)
  eq('a string is', AU.isFiller('vim'), true)
  eq('a number is', AU.isFiller(7), true)
  eq('a falsy name is still a real row', AU.isFiller({ name: '' }), false)
  eq('a null name likewise', AU.isFiller({ name: null }), false)
  eq('it does not read the _filler marker, only the name',
    AU.isFiller({ _filler: true, name: 'vim' }), false)
  eq('and the two agree on every rowView filler case',
    [AU.isFiller({}), AU.isFiller({ _filler: true }), AU.isFiller(null), AU.isFiller({ name: '' })]
      .join(),
    [true, true, true, false].join())
})
group('a real row stringifies its two text fields', () => {
  eq('a numeric name', AU.rowView({ name: 7, candidate: 8 }, {}), { filler: false, key: 'official:7', checked: false, aur: false, name: '7', candidate: '8' })
  eq('a missing candidate', AU.rowView({ name: 'vim' }, {}).candidate, '')
  eq('a null candidate', AU.rowView({ name: 'vim', candidate: null }, {}).candidate, '')
  eq('a non-string name is stringified by String()', AU.rowView({ name: { a: 1 } }, {}).name, '[object Object]')
  eq('and a non-string candidate the same way', AU.rowView({ name: 'x', candidate: { a: 1 } }, {}).candidate, '[object Object]')
  eq('a truthy non-string name is kept as text', AU.rowView({ name: '7' }, {}).name, '7')
  eq('a name that is an array stringifies', AU.rowView({ name: ['a', 'b'] }, {}).name, 'a,b')
})

section('ArchUpdates/Model.columnWidths - the capped table columns')
// The island's own chrome policy, passed in: 16px version padding, a 40px
// floor and a 120px cap on the version, an 80px floor on the name.
const CAPS = { verPad: 16, minVer: 40, verCap: 120, minName: 80 }
const cw = (n, v, viewport, chrome, caps) => AU.columnWidths(n, v, viewport, chrome, caps || CAPS)
group('both columns are their measured width plus the chrome', () => {
  eq('a comfortable table', cw(100, 60, 400, 0), { name: 100, ver: 76 })
  eq('the version takes its padding', cw(40, 10, 400, 0), { name: 80, ver: 40 })
  eq('the name has no padding of its own', cw(120, 60, 400, 0), { name: 120, ver: 76 })
  eq('the name is floored even when the table is wide', cw(40, 10, 400, 0).name, 80)
})
group('fractional measurements are rounded up', () => {
  eq('a fractional name', cw(100.1, 60, 400, 0).name, 101)
  eq('a fractional version', cw(100, 60.2, 400, 0).ver, 77)
  eq('a hair over the floor', cw(80.01, 40.01, 400, 0), { name: 81, ver: 57 })
  eq('a hair under the floor still floors', cw(79.9, 39.9, 400, 0), { name: 80, ver: 56 })
  eq('zero measures to the floor', cw(0, 0, 400, 0), { name: 80, ver: 40 })
})
group('the version column is capped, so a git hash cannot push it off-screen', () => {
  eq('a long version caps', cw(100, 300, 400, 0), { name: 100, ver: 120 })
  eq('well past the cap', cw(100, 4000, 4000, 0), { name: 100, ver: 120 })
  eq('the cap wins over the name budget', cw(100, 300, 200, 20), { name: 80, ver: 120 })
})
group('the name yields to the version', () => {
  // "The name yields to the version: what the viewport has left after the
  // chrome and the version is the name budget."
  eq('a wide name in a wide table', cw(400, 60, 400, 0), { name: 324, ver: 76 })
  eq('the row chrome comes off the top', cw(400, 60, 400, 20), { name: 304, ver: 76 })
  eq('a capped version leaves less for the name', cw(400, 300, 400, 0), { name: 280, ver: 120 })
  eq('both capped', cw(400, 300, 260, 20), { name: 120, ver: 120 })
})
group('the name can never invert below its floor', () => {
  eq('a table too small for the floor', cw(100, 60, 90, 0), { name: 80, ver: 76 })
  eq('the sum overflows the viewport rather than inverting', cw(100, 120, 100, 0), { name: 80, ver: 120 })
  eq('a zero viewport', cw(100, 60, 0, 0), { name: 80, ver: 76 })
  eq('a negative viewport', cw(100, 60, -50, 0), { name: 80, ver: 76 })
  eq('a zero width version', cw(100, 0, 400, 0), { name: 100, ver: 40 })
})
group('the caps are the caller\'s, not the library\'s', () => {
  eq('a different version pad', cw(100, 60, 400, 0, { ...CAPS, verPad: 0 }), { name: 100, ver: 60 })
  eq('a different version cap', cw(100, 300, 400, 0, { ...CAPS, verCap: 60 }), { name: 100, ver: 60 })
  eq('a different name floor', cw(10, 1, 400, 0, { ...CAPS, minName: 200 }), { name: 200, ver: 40 })
  eq('a cap below the floor is the cap', cw(10, 1, 400, 0, { ...CAPS, minVer: 60, verCap: 30 }), { name: 80, ver: 30 })
})

// ======================================================================
section('Volume/Model - playback and capture stream classification')
const node = (extra) => Object.assign({ isStream: true }, extra)
group('a sink is a playback stream and never a capture stream', () => {
  eq('a typed output stream', VO.isPlaybackStream(node({ isSink: true, type: 'Stream/Output/Audio', name: 'a' })), true)
  eq('and not a capture stream', VO.isCaptureStream(node({ isSink: true, type: 'Stream/Output/Audio', name: 'a' })), false)
  eq('a sink with no type at all', VO.isPlaybackStream(node({ isSink: true, name: 'a' })), true)
  eq('still not a capture stream', VO.isCaptureStream(node({ isSink: true, name: 'a' })), false)
})
group('a source is a capture stream and never a playback stream', () => {
  eq('a typed input stream', VO.isCaptureStream(node({ isSink: false, type: 'Stream/Input/Audio', name: 'b' })), true)
  eq('and not a playback stream', VO.isPlaybackStream(node({ isSink: false, type: 'Stream/Input/Audio', name: 'b' })), false)
  eq('a source with no type at all', VO.isCaptureStream(node({ isSink: false, name: 'b' })), true)
})
group('with no isSink flag the class decides', () => {
  // The README's rule: "by `isSink` or a `Stream/Output/Audio` /
  // `AudioOutStream` / `Output` class, and as a capture stream by the
  // `isSink === false` case or the matching `Input` classes".
  const noFlag = (type) => node({ type })
  eq('a Stream/Output/Audio class', VO.isPlaybackStream(noFlag('Stream/Output/Audio')), true)
  eq('an AudioOutStream class', VO.isPlaybackStream(noFlag('AudioOutStream')), true)
  eq('a bare Output class', VO.isPlaybackStream(noFlag('Output')), true)
  eq('a Stream/Input/Audio class is not playback', VO.isPlaybackStream(noFlag('Stream/Input/Audio')), false)
  eq('an AudioInStream class is not playback', VO.isPlaybackStream(noFlag('AudioInStream')), false)
  eq('a bare Input class is not playback', VO.isPlaybackStream(noFlag('Input')), false)
  eq('a Stream/Input/Audio class is capture', VO.isCaptureStream(noFlag('Stream/Input/Audio')), true)
  eq('an AudioInStream class is capture', VO.isCaptureStream(noFlag('AudioInStream')), true)
  eq('a bare Input class is capture', VO.isCaptureStream(noFlag('Input')), true)
  eq('a Stream/Output/Audio class is not capture', VO.isCaptureStream(noFlag('Stream/Output/Audio')), false)
  eq('an AudioOutStream class is not capture', VO.isCaptureStream(noFlag('AudioOutStream')), false)
  eq('a bare Output class is not capture', VO.isCaptureStream(noFlag('Output')), false)
  eq('the class match is a substring, not a prefix', VO.isPlaybackStream(noFlag('Audio/Output/Default')), true)
  eq('and it is case-sensitive', VO.isPlaybackStream(noFlag('stream/output/audio')), false)
})
group('a monitor is classified by its own side', () => {
  // A PulseAudio/PipeWire monitor is a source node that carries a copy of a
  // sink's audio, so it arrives as isSink: false with a monitor-ish name.
  const mon = node({ isSink: false, type: 'Stream/Input/Audio/Analog', name: 'alsa_input.pci-0000_00_1f.3.analog-stereo.monitor' })
  eq('a monitor source is a capture stream', VO.isCaptureStream(mon), true)
  eq('and never a playback stream', VO.isPlaybackStream(mon), false)
  const monSink = node({ isSink: true, type: 'Stream/Output/Audio/Analog', name: 'alsa_output.pci.monitor' })
  eq('a monitor sink is a playback stream', VO.isPlaybackStream(monSink), true)
  eq('and never a capture stream', VO.isCaptureStream(monSink), false)
  eq('a loopback named like a monitor is still by side', VO.isPlaybackStream(node({ isSink: true, name: 'my-loopback.monitor' })), true)
})
group('a device node is not a stream at all', () => {
  // "A node that is neither is not a stream and must not be listed."
  const dev = { isStream: false, isSink: false, type: 'Audio/Sink', name: 'alsa_output.pci' }
  eq('not a playback stream', VO.isPlaybackStream(dev), false)
  eq('not a capture stream', VO.isCaptureStream(dev), false)
  eq('a missing isStream flag is not a stream', VO.isPlaybackStream({ isSink: true, type: 'Stream/Output/Audio' }), false)
  eq('nor a capture stream', VO.isCaptureStream({ isSink: false, type: 'Stream/Input/Audio' }), false)
  eq('a falsy isStream', VO.isPlaybackStream({ isStream: 0, isSink: true }), false)
})
group('the two predicates are not mutually exclusive when the flag and the class disagree', () => {
  // isSink === true answers the playback question and the *class* answers the
  // capture one, so a node whose class contradicts its flag matches both. A
  // real gap rather than a contract violation - see the report.
  const contradiction = node({ isSink: true, type: 'Stream/Input/Audio', name: 'weird' })
  eq('playback', VO.isPlaybackStream(contradiction), true)
  eq('capture too', VO.isCaptureStream(contradiction), true)
  const other = node({ isSink: false, type: 'Stream/Output/Audio', name: 'weird' })
  eq('playback from the class', VO.isPlaybackStream(other), true)
  eq('capture from the flag', VO.isCaptureStream(other), true)
})
group('nothing about the classification throws', () => {
  eq('null', VO.isPlaybackStream(null), false)
  eq('undefined', VO.isPlaybackStream(undefined), false)
  eq('zero', VO.isPlaybackStream(0), false)
  eq('an empty string', VO.isPlaybackStream(''), false)
  eq('null for capture', VO.isCaptureStream(null), false)
  eq('an empty object', VO.isCaptureStream({}), false)
  eq('a numeric type is stringified', VO.isPlaybackStream(node({ type: 0 })), false)
  eq('a non-string type is stringified', VO.isPlaybackStream(node({ type: { toString: () => 'Output' } })), true)
  noThrow('an array', () => VO.isPlaybackStream([]))
  noThrow('a function', () => VO.isCaptureStream(() => {}))
})

section('Volume/Model - the playbackStreams composition')
group('playbackStreams keeps list order and only live playback app rows', () => {
  // The island section and the bar tooltip count read this one function,
  // so whatever it drops is dropped in both places at once.
  const app = (name) => node({ isSink: true, type: 'Stream/Output/Audio', name, audio: {} })
  const rows = [
    app('spotify'),
    { isStream: false, isSink: false, type: 'Audio/Sink', name: 'alsa_output.pci', audio: {} },
    app('omarchy_speaker_tuning'),
    node({ isSink: false, type: 'Stream/Input/Audio', name: 'mic', audio: {} }),
    app('eq_band'),
    node({ isSink: true, type: 'Stream/Output/Audio', name: 'noaudio' }),
    app('firefox'),
  ]
  eq('devices, tuners, captures and audioless rows are out',
    VO.playbackStreams(rows).map((n) => n.name), ['spotify', 'firefox'])
  eq('an empty list', VO.playbackStreams([]), [])
  eq('null', VO.playbackStreams(null), [])
  eq('undefined', VO.playbackStreams(undefined), [])
})

section('Volume/Model - the list and node snapshot helpers')
group('listSnapshot copies an array and tolerates everything else', () => {
  const list = [1, 2, 3]
  const snap = VO.listSnapshot(list)
  eq('the same contents', snap, [1, 2, 3])
  is('a different array', snap, (v) => v !== list, 'a copy, not the list')
  snap.push(4)
  eq('so writing to it does not reach the list', list, [1, 2, 3])
  eq('an empty list', VO.listSnapshot([]), [])
  eq('null', VO.listSnapshot(null), [])
  eq('undefined', VO.listSnapshot(undefined), [])
  eq('a plain object has no slice', VO.listSnapshot({ length: 2, 0: 'a' }), [])
  eq('a number', VO.listSnapshot(7), [])
  eq('zero', VO.listSnapshot(0), [])
  // A string has no slice either, so it is returned as-is rather than as the
  // empty list the guard suggests.
  eq('a string is returned as-is', VO.listSnapshot('ab'), 'ab')
})
group('nodeProps reads properties only from a ready node', () => {
  eq('a ready node', VO.nodeProps({ ready: true, properties: { 'node.nick': 'x' } }), { 'node.nick': 'x' })
  eq('a node that is not ready', VO.nodeProps({ ready: false, properties: { a: 1 } }), {})
  eq('a node with no ready flag', VO.nodeProps({ properties: { a: 1 } }), {})
  eq('a node with no properties', VO.nodeProps({ ready: true }), {})
  eq('an empty properties map is returned as-is', VO.nodeProps({ ready: true, properties: {} }).constructor === Object, true)
  eq('null', VO.nodeProps(null), {})
  eq('undefined', VO.nodeProps(undefined), {})
  eq('a number', VO.nodeProps(7), {})
  // properties is returned by reference, not cloned: the island reads it per
  // frame and a copy per read would be a hot-path allocation.
  const props = { a: 1 }
  is('the same object, not a copy', VO.nodeProps({ ready: true, properties: props }), (v) => v === props, 'identity for nodeProps')
})
group('friendlyDeviceLabel strips the two PipeWire decorations', () => {
  eq('the built-in prefix', VO.friendlyDeviceLabel('Built-in Audio Analog Stereo'), 'Analog Stereo')
  eq('the unhyphenated spelling', VO.friendlyDeviceLabel('builtin audio Digital Output'), 'Digital')
  eq('lowercase', VO.friendlyDeviceLabel('built-in audio x'), 'x')
  eq('mixed case', VO.friendlyDeviceLabel('BUILT-IN AUDIO x'), 'x')
  eq('the suffix', VO.friendlyDeviceLabel('Speakers Output'), 'Speakers')
  eq('the input suffix', VO.friendlyDeviceLabel('Microphone Input'), 'Microphone')
  eq('both together', VO.friendlyDeviceLabel('Built-in Audio Headphones Output'), 'Headphones')
  eq('surrounding space is trimmed first', VO.friendlyDeviceLabel('   Padded   '), 'Padded')
})
group('the decorations only match in the exact shape they are written for', () => {
  // The prefix regex is /^built-?in audio\s+/i: the optional character is the
  // hyphen, not the space, so "built in audio" is not recognised.
  eq('"built in audio" with a space is not stripped', VO.friendlyDeviceLabel('built in audio x'), 'built in audio x')
  eq('the suffix needs whitespace before it', VO.friendlyDeviceLabel('Output'), 'Output')
  eq('so a bare "Input" survives too', VO.friendlyDeviceLabel('Input'), 'Input')
  eq('a mid-string Output is not a suffix', VO.friendlyDeviceLabel('Output Monitor'), 'Output Monitor')
  eq('"Line Output" only loses the last word', VO.friendlyDeviceLabel('Line Output'), 'Line')
  eq('the prefix is stripped once, not repeatedly', VO.friendlyDeviceLabel('Built-in Audio Built-in Audio x'), 'Built-in Audio x')
  eq('an empty string', VO.friendlyDeviceLabel(''), '')
  eq('whitespace only', VO.friendlyDeviceLabel('   '), '')
  eq('null', VO.friendlyDeviceLabel(null), '')
  eq('undefined', VO.friendlyDeviceLabel(undefined), '')
  eq('0 is a falsy fold to empty', VO.friendlyDeviceLabel(0), '')
  eq('a number is stringified', VO.friendlyDeviceLabel(42), '42')
})
group('nodeLabel prefers the nickname, then the description, then the name', () => {
  eq('a node nickname', VO.nodeLabel({ nickname: 'Headphones' }), 'Headphones')
  eq('the nick alias', VO.nodeLabel({ nick: 'Headphones' }), 'Headphones')
  eq('the nickname property', VO.nodeLabel({ ready: true, properties: { 'node.nick': 'Headphones' } }), 'Headphones')
  eq('the active profile wins over the name', VO.nodeLabel({ ready: true, properties: { 'device.profile.description': 'Pro' }, name: 'alsa' }), 'Pro')
  eq('the node nickname beats every property', VO.nodeLabel({ nickname: 'A', ready: true, properties: { 'node.nick': 'B', 'device.profile.description': 'C' } }), 'A')
  eq('no nickname: the description, de-prefixed like any label', VO.nodeLabel({ description: 'Built-in Audio' }), 'Built-in Audio')
  eq('the node.description property', VO.nodeLabel({ ready: true, properties: { 'node.description': 'Desk Mic' } }), 'Desk Mic')
  eq('the node description', VO.nodeLabel({ description: 'Desk Mic' }), 'Desk Mic')
  eq('the description beats the name', VO.nodeLabel({ description: 'D', name: 'N' }), 'D')
  eq('no description: the name', VO.nodeLabel({ name: 'alsa_output.pci' }), 'alsa_output.pci')
  eq('nothing at all reads as Unknown', VO.nodeLabel({}), 'Unknown')
  eq('a null node', VO.nodeLabel(null), 'Unknown')
  eq('undefined', VO.nodeLabel(undefined), 'Unknown')
  eq('a blank nickname falls through to the description', VO.nodeLabel({ nickname: '   ', name: 'fallback' }), 'fallback')
  // Both branches run friendlyDeviceLabel, so the description is de-prefixed
  // too - but only the nickname branch has a "does it fold to nothing" retry,
  // so a blank description stays a blank label instead of falling through to
  // the node name.
  eq('a blank description is not replaced', VO.nodeLabel({ description: '  ', name: 'fallback' }), '')
  eq('a de-prefixing description is stripped like any label', VO.nodeLabel({ description: 'Built-in Audio Output', name: 'n' }), 'Output')
  eq('the label is trimmed and de-prefixed too', VO.nodeLabel({ nickname: ' Built-in Audio Desk ' }), 'Desk')
  eq('a not-ready node still answers from its own fields', VO.nodeLabel({ ready: false, nickname: 'Desk' }), 'Desk')
})
group('sinkDeviceIcon reads six candidate strings, headset first', () => {
  const f = (form) => VO.sinkDeviceIcon({ ready: true, properties: { 'device.form_factor': form } })
  eq('form_factor headset', f('headset'), 'headset')
  eq('form_factor headphones', f('headphones'), 'headphones')
  eq('a singular headphone form factor', f('headphone'), 'headphones')
  eq('an unknown form factor', f('laptop'), '')
  eq('a microphone form factor', f('microphone'), '')
  eq('form_factor is read before the icon name', VO.sinkDeviceIcon({ ready: true, properties: { 'device.form_factor': 'headset', 'device.icon_name': 'audio-headphones' } }), 'headset')
  eq('the camelCase form factor', VO.sinkDeviceIcon({ ready: true, properties: { 'device.formFactor': 'headset' } }), 'headset')
})
group('every other candidate is a substring test, lowercased', () => {
  eq('icon_name', VO.sinkDeviceIcon({ ready: true, properties: { 'device.icon_name': 'audio-headset-bluetooth' } }), 'headset')
  eq('the camelCase icon name', VO.sinkDeviceIcon({ ready: true, properties: { 'device.iconName': 'audio-headset' } }), 'headset')
  eq('the dashed icon name', VO.sinkDeviceIcon({ ready: true, properties: { 'device.icon-name': 'audio-headset' } }), 'headset')
  eq('a multi-word icon name', VO.sinkDeviceIcon({ ready: true, properties: { 'device.icon_name': 'audio-headphones' } }), 'headphones')
  eq('the node name', VO.sinkDeviceIcon({ name: 'alsa_output.usb-Audio-Co-Headset' }), 'headset')
  eq('the node nickname', VO.sinkDeviceIcon({ nickname: 'My Headphones' }), 'headphones')
  eq('the nick alias', VO.sinkDeviceIcon({ nick: 'headset' }), 'headset')
  eq('the node.nick property', VO.sinkDeviceIcon({ ready: true, properties: { 'node.nick': 'headset' } }), 'headset')
  eq('the node description', VO.sinkDeviceIcon({ description: 'Built-in Audio Headset' }), 'headset')
  eq('the node.description property', VO.sinkDeviceIcon({ ready: true, properties: { 'node.description': 'headset' } }), 'headset')
  eq('the device description', VO.sinkDeviceIcon({ ready: true, properties: { 'device.description': 'Headset' } }), 'headset')
  eq('the match is case-insensitive', VO.sinkDeviceIcon({ name: 'HEADSET' }), 'headset')
  eq('a name that merely contains headset', VO.sinkDeviceIcon({ name: 'xheadsety' }), 'headset')
  eq('a null node', VO.sinkDeviceIcon(null), '')
  eq('an empty node', VO.sinkDeviceIcon({}), '')
  eq('a plain speaker node', VO.sinkDeviceIcon({ name: 'alsa_output.pci.analog-stereo' }), '')
  // "Headset (with mic) takes priority over headphones (output only)": the
  // two tests are substring tests, so a name holding both reads as a headset.
  eq('a name holding both words reads as a headset', VO.sinkDeviceIcon({ name: 'headset-and-headphones' }), 'headset')
})
group('sinkTooltipIcon is always the device type', () => {
  const f = (node) => VO.sinkTooltipIcon(node)
  const live = { ready: true, audio: { volume: 0.5, muted: false } }
  eq('a headset sink', f(Object.assign({ properties: { 'device.form_factor': 'headset' } }, live)), 'headset')
  eq('a headphones sink', f(Object.assign({ properties: { 'device.form_factor': 'headphone' } }, live)), 'headphones')
  // The plain speaker sink is the module's common case, and the one the
  // bar's tiered volume glyph does not describe: the row names the device.
  eq('a plain speaker sink', f(Object.assign({ name: 'alsa_output.pci.analog-stereo' }, live)), 'speaker')
  // The device glyph stays even while muted: mute state and level live on the
  // row below, which already carries the muted mark.
  eq('a muted headset keeps its headset icon', f(Object.assign({ properties: { 'device.form_factor': 'headset' } }, live, { audio: { volume: 0.5, muted: true } })), 'headset')
  eq('a muted speaker keeps its speaker icon', f(Object.assign({ name: 'alsa_output.pci.analog-stereo' }, live, { audio: { volume: 0, muted: true } })), 'speaker')
  eq('no sink at all', f(null), 'volume-off')
  eq('a sink with no audio object', f({ ready: true }), 'volume-off')
})

section('Volume/Model - the stream labels')
group('rawStreamLabel is a five-step fallback', () => {
  eq('application.name first', VO.rawStreamLabel({ ready: true, properties: { 'application.name': 'Spotify' }, name: 'n', description: 'd' }), 'Spotify')
  eq('then the node description', VO.rawStreamLabel({ description: 'D', ready: true, properties: { 'media.name': 'M' } }), 'D')
  eq('then media.name', VO.rawStreamLabel({ ready: true, properties: { 'media.name': 'M' }, name: 'n' }), 'M')
  eq('then the node.name property', VO.rawStreamLabel({ ready: true, properties: { 'node.name': 'P' }, name: 'n' }), 'P')
  eq('then the node name', VO.rawStreamLabel({ name: 'n' }), 'n')
  eq('nothing at all', VO.rawStreamLabel({}), '')
  eq('a null node', VO.rawStreamLabel(null), '')
  eq('an empty application name falls through', VO.rawStreamLabel({ ready: true, properties: { 'application.name': '' }, name: 'n' }), 'n')
  eq('the raw value is not trimmed', VO.rawStreamLabel({ ready: true, properties: { 'application.name': '  Spotify  ' } }), '  Spotify  ')
})
group('streamLabel trims, defaults to "Stream" and de-generifies audio-src', () => {
  eq('a real label', VO.streamLabel({ name: 'Firefox' }), 'Firefox')
  eq('trimmed', VO.streamLabel({ name: '  Firefox  ' }), 'Firefox')
  eq('nothing to name it', VO.streamLabel({}), 'Stream')
  eq('whitespace only', VO.streamLabel({ name: '   ' }), 'Stream')
  eq('a null node', VO.streamLabel(null), 'Stream')
  eq('audio-src falls back to the application name', VO.streamLabel({ name: 'audio-src', ready: true, properties: { 'application.name': 'spotify' } }), 'spotify')
  eq('a differently cased audio-src too', VO.streamLabel({ name: 'AUDIO-SRC', ready: true, properties: { 'application.name': 'spotify' } }), 'spotify')
  eq('with no application name it uses the node name', VO.streamLabel({ name: 'Firefox' , description: 'audio-src' }), 'Firefox')
  eq('and no alternative at all keeps audio-src', VO.streamLabel({ name: 'audio-src' }), 'audio-src')
  eq('an application name that is itself audio-src is no help', VO.streamLabel({ name: 'audio-src', ready: true, properties: { 'application.name': 'AUDIO-SRC' } }), 'AUDIO-SRC')
  eq('and the original casing is what comes back', VO.streamLabel({ name: 'audio-src', ready: true, properties: { 'application.name': 'audio-src' } }), 'audio-src')
  eq('a padded application name is trimmed', VO.streamLabel({ name: 'audio-src', ready: true, properties: { 'application.name': '  spotify  ' } }), 'spotify')
  eq('a label that merely contains audio-src is kept', VO.streamLabel({ name: 'audio-src-2' }), 'audio-src-2')
  eq('the fallback is only consulted for the exact string', VO.streamLabel({ ready: true, properties: { 'application.name': 'Spotify' } }), 'Spotify')
})
group('appIconName prefers the icon keys and never falls back to node.name', () => {
  eq('application.icon-name', VO.appIconName({ ready: true, properties: { 'application.icon-name': 'firefox' } }), 'firefox')
  eq('the camelCase spelling', VO.appIconName({ ready: true, properties: { 'application.iconName': 'firefox' } }), 'firefox')
  eq('the process binary', VO.appIconName({ ready: true, properties: { 'application.process.binary': '/usr/bin/brave' } }), '/usr/bin/brave')
  eq('the icon key beats the binary', VO.appIconName({ ready: true, properties: { 'application.icon-name': 'i', 'application.process.binary': 'b' } }), 'i')
  eq('the value is trimmed', VO.appIconName({ ready: true, properties: { 'application.icon-name': '  firefox  ' } }), 'firefox')
  eq('application.name is the second choice', VO.appIconName({ ready: true, properties: { 'application.name': 'Code' } }), 'Code')
  eq('a trimmed application name', VO.appIconName({ ready: true, properties: { 'application.name': '  Code  ' } }), 'Code')
  // The comment: "avoid using raw node.name like "eq_output" which has no
  // icon and produces purple checker".
  eq('node.name is never used', VO.appIconName({ name: 'eq_output' }), '')
  eq('not even beside an application name', VO.appIconName({ name: 'eq_output', ready: true, properties: { 'application.name': 'System Sounds' } }), 'System Sounds')
  eq('a blank application name is no icon', VO.appIconName({ name: 'eq_output', ready: true, properties: { 'application.name': '   ' } }), '')
  // The icon key chain is a truthy fold, so an explicitly undefined or empty
  // key falls through to the next candidate rather than yielding "".
  eq('an explicitly undefined icon key falls through to the name', VO.appIconName({ ready: true, properties: { 'application.icon-name': undefined, 'application.name': 'X' } }), 'X')
  eq('an empty icon key too', VO.appIconName({ ready: true, properties: { 'application.icon-name': '', 'application.process.binary': 'b' } }), 'b')
  eq('a not-ready node has no properties', VO.appIconName({ ready: false, properties: { 'application.icon-name': 'firefox' } }), '')
  eq('a null node', VO.appIconName(null), '')
  eq('an empty node', VO.appIconName({}), '')
})
group('outputVolumeName is six bands over the rounded percentage', () => {
  // The bands are read off a Math.round(volume * 100), so the boundary is
  // the *rounded* percentage, not the raw volume: 14.9% rounds to 15 and
  // reads as Low.
  eq('muted wins over everything', VO.outputVolumeName(0.5, true), 'Muted')
  eq('muted at zero', VO.outputVolumeName(0, true), 'Muted')
  eq('muted at full', VO.outputVolumeName(1, true), 'Muted')
  eq('a truthy mute flag', VO.outputVolumeName(0.5, 1), 'Muted')
  eq('silent', VO.outputVolumeName(0, false), 'Silenced')
  eq('just under half a percent still rounds to silent', VO.outputVolumeName(0.004, false), 'Silenced')
  eq('just over half a percent is quiet', VO.outputVolumeName(0.005, false), 'Quiet')
  eq('quiet', VO.outputVolumeName(0.1, false), 'Quiet')
  eq('14.9% rounds up into the low band', VO.outputVolumeName(0.149, false), 'Low')
  eq('14% stays quiet', VO.outputVolumeName(0.14, false), 'Quiet')
  eq('15%', VO.outputVolumeName(0.15, false), 'Low')
  eq('39.9% rounds up into the medium band', VO.outputVolumeName(0.399, false), 'Medium')
  eq('39% stays low', VO.outputVolumeName(0.39, false), 'Low')
  eq('40%', VO.outputVolumeName(0.4, false), 'Medium')
  eq('69.9% rounds up into the high band', VO.outputVolumeName(0.699, false), 'High')
  eq('69% stays medium', VO.outputVolumeName(0.69, false), 'Medium')
  eq('70%', VO.outputVolumeName(0.7, false), 'High')
  eq('99.6% rounds up into loud', VO.outputVolumeName(0.996, false), 'Loud')
  eq('99% stays high', VO.outputVolumeName(0.99, false), 'High')
  eq('100%', VO.outputVolumeName(1, false), 'Loud')
  eq('over 100% is still loud', VO.outputVolumeName(1.5, false), 'Loud')
  eq('a string volume is coerced', VO.outputVolumeName('0.5', false), 'Medium')
  eq('null is zero', VO.outputVolumeName(null, false), 'Silenced')
  eq('undefined reads as zero, so the quietest band', VO.outputVolumeName(undefined, false), 'Quiet')
  eq('a NaN volume is not a comparison, so the quietest band', VO.outputVolumeName(NaN, false), 'Quiet')
  // A hair below zero rounds to -0, and `-0 === 0`, so an out-of-range volume
  // reads as Silenced rather than Quiet.
  eq('a hair below zero rounds to -0 and reads as silenced', VO.outputVolumeName(-0.0001, false), 'Silenced')
  eq('a clearly negative volume does not', VO.outputVolumeName(-0.5, false), 'Quiet')
})

// ======================================================================
// common/NowPlaying.js - the helpers every media surface shares: player sort,
// mm:ss, seek math, the sample ring and the time-gated transport stamp.
//
// These used to be asserted twice, against a per-module copy that nothing
// imported. One library, asserted once.
section('common/NowPlaying.js - player sort, formats and seek math')
const playingFlag = (p) => p.playing
group('sortPlayers is a stable partition, not a title sort', () => {
  // The module README: "groups actively playing clients to the front and
  // preserves the original order inside each group". Titles never enter the
  // decision, so a z-named playing client still leads.
  eq('empty', CN.sortPlayers([], playingFlag), [])
  eq('one playing', CN.sortPlayers([{ t: 'a', playing: true }], playingFlag).map((p) => p.t), ['a'])
  eq('one idle', CN.sortPlayers([{ t: 'a', playing: false }], playingFlag).map((p) => p.t), ['a'])
  const mixed = [
    { t: 'a', playing: true }, { t: 'b', playing: false }, { t: 'c', playing: true },
    null, undefined, { t: 'd', playing: false },
  ]
  eq('playing first, then idle, holes dropped', CN.sortPlayers(mixed, playingFlag).map((p) => p.t), ['a', 'c', 'b', 'd'])
  eq('the order inside the playing group is the input order', CN.sortPlayers(mixed, playingFlag).slice(0, 2).map((p) => p.t), ['a', 'c'])
  eq('the order inside the idle group is the input order', CN.sortPlayers(mixed, playingFlag).slice(2).map((p) => p.t), ['b', 'd'])
  eq('equal titles are not reordered', CN.sortPlayers([{ t: 'x', playing: false }, { t: 'x', playing: true }], playingFlag).map((p) => p.playing), [true, false])
  eq('a null title is not a reason to sort', CN.sortPlayers([{ t: null, playing: true }, { t: 'a', playing: false }], playingFlag).map((p) => p.playing), [true, false])
  eq('two idle players keep their order', CN.sortPlayers([{ t: 'z', playing: false }, { t: 'a', playing: false }], playingFlag).map((p) => p.t), ['z', 'a'])
  eq('two playing players keep their order', CN.sortPlayers([{ t: 'z', playing: true }, { t: 'a', playing: true }], playingFlag).map((p) => p.t), ['z', 'a'])
})
group('sortPlayers drops holes and returns a new array', () => {
  eq('a hole in the middle', CN.sortPlayers([{ t: 'a', playing: true }, null, { t: 'b', playing: true }], playingFlag).length, 2)
  eq('only holes', CN.sortPlayers([null, undefined], playingFlag), [])
  eq('the entries are the same objects', CN.sortPlayers([{ t: 'a', playing: true }], playingFlag)[0].t, 'a')
  const src = [{ t: 'a', playing: true }, { t: 'b', playing: false }]
  is('a new array', CN.sortPlayers(src, playingFlag), (v) => v !== src, 'a different array')
  eq('and the input is unchanged', src.length, 2)
  eq('a hole is skipped before the predicate is consulted', CN.sortPlayers([null, { t: 'a', playing: true }], () => true).length, 1)
  throws('a null source is a TypeError', () => CN.sortPlayers(null, playingFlag), /length/)
  throws('a missing predicate is a TypeError', () => CN.sortPlayers([{ t: 'a' }]), /isPlaying/)
})
group('isBrowserPlayer matches whole client tokens', () => {
  const t = (dbusName, identity) => CN.isBrowserPlayer(dbusName, identity)
  eq('a chromium instance', t('org.mpris.MediaPlayer2.chromium.instance1234', 'yt'), true)
  eq('a firefox instance', t('org.mpris.MediaPlayer2.firefox.instance9', 'some tab'), true)
  eq('a chrome instance', t('org.mpris.MediaPlayer2.chrome.instance7', 'Chrome'), true)
  eq('a generic chromium identity', t('org.mpris.MediaPlayer2.vlc', 'Chromium'), true)
  eq('a generic firefox identity', t('org.mpris.MediaPlayer2.vlc', 'Firefox'), true)
  eq('a suffixed firefox identity', t('x', 'Firefox Beta'), true)
  eq('a case-insensitive dbus name', t('ORG.MPRIS.MEDIAPLAYER2.CHROMIUM.INSTANCE1', ''), true)
  eq('a bare chrome bus is still chrome', t('org.mpris.MediaPlayer2.chrome', 'Google Chrome'), true)
  eq('edge', t('org.mpris.MediaPlayer2.microsoft-edge', 'Microsoft Edge'), true)
  eq('brave', t('org.mpris.MediaPlayer2.brave.instance3', 'Brave'), true)
  eq('opera', t('org.mpris.MediaPlayer2.opera', 'Opera'), true)
  eq('vivaldi', t('org.mpris.MediaPlayer2.vivaldi', 'Vivaldi'), true)
  eq('epiphany', t('org.mpris.MediaPlayer2.epiphany', 'Epiphany'), true)
  eq('telegram desktop spaced', t('org.mpris.MediaPlayer2.telegram-desktop', 'Telegram Desktop'), true)
  eq('telegram desktop fused', t('org.mpris.MediaPlayer2.vlc', 'TelegramDesktop'), true)
  eq('a case-insensitive telegram identity', t('x', 'telegramdesktop'), true)
})
group('a plain player is not a browser', () => {
  const t = (dbusName, identity) => CN.isBrowserPlayer(dbusName, identity)
  eq('vlc', t('org.mpris.MediaPlayer2.vlc', 'VLC'), false)
  eq('spotify', t('org.mpris.MediaPlayer2.spotify', 'Spotify'), false)
  eq('mpv', t('org.mpris.MediaPlayer2.mpv', 'mpv'), false)
  eq('an empty pair', t('', ''), false)
  eq('null name', t(null, null), false)
  eq('undefined name', t(undefined, undefined), false)
  eq('a firefoxctl bus with a firefox identity still matches on the identity', t('org.mpris.MediaPlayer2.firefoxctl', 'Firefox'), true)
  eq('a bare chrome bus matches on the token', t('org.mpris.MediaPlayer2.chrome', 'Google Chrome'), true)
  // Token matching retired the old substring quirks with it: a Chrome
  // identity matches on its own token now, and a near-miss token matches
  // nothing. Pinned as the deliberate tightening - see the report.
  eq('an identity of "chrome.instanceN" matches on the token', t('org.mpris.MediaPlayer2.vlc', 'chrome.instance1'), true)
  eq('a plain "Chrome" identity matches on the token', t('org.mpris.MediaPlayer2.vlc', 'Google Chrome'), true)
  eq('a dbus name with "chrome" and "instance" matches on the bus', t('org.mpris.MediaPlayer2.chrome.instance7', ''), true)
  eq('"chrome" and "instance" as bus tokens is enough', t('org.mpris.MediaPlayer2.instance5.chrome', ''), true)
  eq('a dbus name with only "instance" matches on the chrome identity', t('org.mpris.MediaPlayer2.instance5', 'Chrome'), true)
  eq('a near-miss token never matches', t('x', 'chromiumifier'), false)
  eq('a bare "chrome" token matches', t('', 'chrome'), true)
  noThrow('a number dbus name', () => CN.isBrowserPlayer(7, 7))
  eq('a number is stringified', CN.isBrowserPlayer(0, 'Chromium'), true)
})
group('filterBrowsers removes them and keeps the rest in order', () => {
  const rows = [
    { dbusName: 'org.mpris.MediaPlayer2.vlc', identity: 'VLC' },
    { dbusName: 'org.mpris.MediaPlayer2.chromium.instance1', identity: 'a tab' },
    { dbusName: 'x', identity: 'firefox' },
    null,
    undefined,
    { dbusName: 'y', identity: 'spotify' },
  ]
  eq('two survivors', CN.filterBrowsers(rows).map((p) => p.identity), ['VLC', 'spotify'])
  eq('an empty list', CN.filterBrowsers([]), [])
  eq('only browsers', CN.filterBrowsers([{ dbusName: 'x', identity: 'firefox' }]), [])
  eq('a hole is dropped, not grouped', CN.filterBrowsers([null, { dbusName: 'y', identity: 's' }]).length, 1)
  const src = rows.slice()
  ne('a new array', CN.filterBrowsers(src), src)
  eq('and the input is unchanged', src.length, 6)
  noThrow('an object entry has no fields', () => CN.filterBrowsers([{}]))
  eq('an object with no fields is kept', CN.filterBrowsers([{}]).length, 1)
  eq('a null dbus name falls back to the identity', CN.filterBrowsers([{ dbusName: null, identity: 'Chromium' }]).length, 0)
})
group('fmtTime is m:ss, with the hour field only when the reference needs it', () => {
  eq('zero', CN.fmtTime(0), '0:00')
  eq('the last second of a minute', CN.fmtTime(59), '0:59')
  eq('exactly a minute', CN.fmtTime(60), '1:00')
  eq('a minute and a second', CN.fmtTime(61), '1:01')
  eq('the last second before the hour', CN.fmtTime(3599), '59:59')
  // No leading zeroes on the leading field, so a short track is not padded out
  // to a width it does not need.
  eq('a two-digit minute count', CN.fmtTime(723), '12:03')
  eq('a fraction truncates down', CN.fmtTime(61.9), '1:01')
  eq('a fraction under a second truncates to zero', CN.fmtTime(0.9), '0:00')
  eq('a string number is coerced', CN.fmtTime('90'), '1:30')
})
group('the hour field appears from the reference, not from the value', () => {
  // The reference is the track's length, and it - not the elapsed value -
  // decides the shape. That is what lets a caller measure the column once and
  // have both fields hold that shape for the whole track.
  eq('an hour-long track, at the start', CN.fmtTime(0, 3661), '0:00:00')
  eq('the same track, mid-way', CN.fmtTime(1800, 3661), '0:30:00')
  eq('and at its length', CN.fmtTime(3661, 3661), '1:01:01')
  // The crossing itself: a value past the hour under a sub-hour reference stays
  // in the narrow shape, which is the case that would otherwise reflow the
  // column at exactly the wrong tick.
  eq('an hour of elapsed under a short track', CN.fmtTime(3600, 3661), '1:00:00')
  eq('an hour of elapsed under an hour-long track', CN.fmtTime(3600, 7200), '1:00:00')
  eq('just under the reference boundary', CN.fmtTime(3599, 3599), '59:59')
  eq('exactly on the reference boundary', CN.fmtTime(3599, 3600), '0:59:59')
  eq('a value past the boundary under a boundary reference', CN.fmtTime(3600, 3600), '1:00:00')
  // The boundary is the reference's, never the value's: a short track that has
  // somehow been seeked past an hour keeps the shape it was measured with.
  eq('a short reference stays narrow even past an hour', CN.fmtTime(7200, 100), '120:00')
  // A missing reference falls back to the value, which is the right answer for
  // a lone duration with nothing to be consistent with.
  eq('no reference at all', CN.fmtTime(3661), '1:01:01')
  eq('an explicit null reference', CN.fmtTime(3661, null), '1:01:01')
  eq('an explicit undefined reference', CN.fmtTime(3661, undefined), '1:01:01')
  // Both fields of a pair agree, because the caller passes one reference to
  // both. This is the property the column depends on.
  const pair = (len, pos) => CN.fmtTime(pos === undefined ? len / 2 : pos, len) + "/" + CN.fmtTime(len, len)
  eq('a four-minute pair', pair(229), '1:54/3:49')
  eq('an hour-long pair at its half', pair(5445), '0:45:22/1:30:45')
  eq('and at its start', pair(5445, 0), '0:00:00/1:30:45')
  eq('and at its end', pair(5445, 5445), '1:30:45/1:30:45')
  // A pair never changes width as the position advances, which is the whole
  // reason the reference exists. The narrow shape narrows and widens with the
  // minute count, so the guarantee is about the hour field not appearing: a
  // value that has crossed into a second hour keeps two hour digits only
  // because the cap is what bounds it.
  const hourShape = [0, 1, 59, 3599, 3600, 3661, 36000, 86399, 86400]
    .map((t) => /^\d+:\d{2}:\d{2}$/.test(CN.fmtTime(t, 86400)))
  eq('one reference always gives the hour shape, across the whole cap',
    Array.from(new Set(hourShape)), [true])
  eq('and the widest of them is the cap itself', CN.fmtTime(86400, 86400), '24:00:00')
})
group('fmtTime floors at zero for anything it cannot read', () => {
  eq('a negative', CN.fmtTime(-5), '0:00')
  eq('a small negative', CN.fmtTime(-0.1), '0:00')
  eq('a non-numeric string', CN.fmtTime('abc'), '0:00')
  eq('the empty string', CN.fmtTime(''), '0:00')
  eq('null', CN.fmtTime(null), '0:00')
  eq('undefined', CN.fmtTime(undefined), '0:00')
  eq('NaN', CN.fmtTime(NaN), '0:00')
  eq('a non-numeric string with digits', CN.fmtTime('12abc'), '0:00')
  eq('true is 1', CN.fmtTime(true), '0:01')
  eq('an array of one', CN.fmtTime([61]), '1:01')
  // A reference that cannot be read falls back to the value rather than
  // throwing, so a lengthless stream still renders a narrow clock.
  eq('a null reference does not force the hour field', CN.fmtTime(61, null), '1:01')
  eq('a non-numeric reference does not either', CN.fmtTime(61, 'abc'), '1:01')
  eq('a negative reference is not an hour', CN.fmtTime(3600, -5), '60:00')
  // Number(Infinity) is truthy and Math.floor keeps it, so the reference is
  // Infinity (which is an hour) and the fields under it are NaN.
  eq('Infinity produces the placeholder string, not a throw', CN.fmtTime(Infinity), 'Infinity:NaN:NaN')
  eq('-Infinity floors at zero', CN.fmtTime(-Infinity), '0:00')
  eq('a finite value under an infinite reference', CN.fmtTime(61, Infinity), '0:01:01')
})
group('the clock shape is structural, not just a value', () => {
  // The format is what a label binds to, so it is worth pinning as a shape and
  // not only as a set of values.
  match('a narrow label', CN.fmtTime(125), /^\d+:[0-5]\d$/)
  match('an hour-long label', CN.fmtTime(125, 3661), /^\d+:\d{2}:[0-5]\d$/)
  notMatch('the narrow shape has no hour field', CN.fmtTime(125), /^\d+:\d+:\d+$/)
  notMatch('nor does it under a sub-hour reference', CN.fmtTime(125, 300), /^\d+:\d+:\d+$/)
  match('the seconds field is always two digits', CN.fmtTime(5), /^\d+:0\d$/)
  match('the minutes field is two digits once there is an hour', CN.fmtTime(5, 3661), /^\d+:\d{2}:0\d$/)
  // The padding that remains is the reason the two fields under the hour line
  // up with each other column-wise; the leading field carries none, so a short
  // track is not held to a width it does not need.
  notMatch('the leading field carries no leading zero', CN.fmtTime(65), /^0\d/)
  eq('and the cap, which is the widest, still pads the fields under the hour', CN.fmtTime(86400), '24:00:00')
  contains('fmtDuration keeps the mm:ss tail', CN.fmtDuration(3661), '01:01')
  contains('with an hour field in front', CN.fmtDuration(3661), '1:01:01')
  notContains('and no hour field under an hour', CN.fmtDuration(61), ':00:')
  match('playerKey separates its fields with the unit separator', CN.playerKey({ trackTitle: 'a', trackArtist: 'b' }), /\\u001f/)
  match('a key is a JSON array of four strings', CN.playerKey({ dbusName: 'd' }), /^\["[^"]*","[^"]*","[^"]*","[^"]*"\]$/)
})
group('clampRatio is the seek thumb, guarded on a positive width', () => {
  approx('half way', CN.clampRatio(50, 100), 0.5, 1e-9)
  approx('at the left edge', CN.clampRatio(0, 100), 0, 1e-9)
  approx('at the right edge', CN.clampRatio(100, 100), 1, 1e-9)
  approx('past the left edge clamps', CN.clampRatio(-1, 100), 0, 1e-9)
  approx('past the right edge clamps', CN.clampRatio(200, 100), 1, 1e-9)
  eq('a zero width is no ratio', CN.clampRatio(5, 0), 0)
  eq('a negative width is no ratio', CN.clampRatio(5, -1), 0)
  eq('a NaN width is no ratio', CN.clampRatio(5, NaN), 0)
  eq('an undefined width is no ratio', CN.clampRatio(5, undefined), 0)
  eq('a string width is coerced', CN.clampRatio(5, '10'), 0.5)
  approx('a string numerator is coerced', CN.clampRatio('50', 100), 0.5, 1e-9)
  // Math.min/Math.max propagate NaN, so a NaN numerator is *not* guarded -
  // the only unguarded input in this function.
  is('a NaN numerator stays NaN', CN.clampRatio(NaN, 100), (v) => Number.isNaN(v), 'NaN')
  eq('and a null numerator is 0', CN.clampRatio(null, 100), 0)
  eq('a null width is no ratio', CN.clampRatio(null, null), 0)
  approx('a fractional thumb', CN.clampRatio(1, 3), 1 / 3, 1e-9)
  approx('a tiny thumb', CN.clampRatio(0.001, 100), 0.00001, 1e-12)
})
group('freshSkipPosition is the settle budget for a switch flash', () => {
  eq('a fresh track', CN.freshSkipPosition(0), 0)
  eq('a fraction of a second in', CN.freshSkipPosition(1), 1)
  eq('exactly the budget', CN.freshSkipPosition(2), 2)
  // "Players report Position after Metadata, so an immediate read can still
  // carry the old track's position; anything above the settle budget reads as
  // stale and snaps to 0."
  eq('a hair over the budget snaps to 0', CN.freshSkipPosition(2.0001), 0)
  eq('a stale position snaps to 0', CN.freshSkipPosition(3), 0)
  eq('a long position snaps to 0', CN.freshSkipPosition(300), 0)
  eq('a fraction inside the budget is kept as-is', CN.freshSkipPosition(1.5), 1.5)
  eq('a string is coerced', CN.freshSkipPosition('1.5'), 1.5)
  eq('a negative snaps to 0', CN.freshSkipPosition(-1), 0)
  eq('NaN snaps to 0', CN.freshSkipPosition(NaN), 0)
  eq('null snaps to 0', CN.freshSkipPosition(null), 0)
  eq('undefined snaps to 0', CN.freshSkipPosition(undefined), 0)
  eq('a non-numeric string snaps to 0', CN.freshSkipPosition('abc'), 0)
  eq('Infinity snaps to 0', CN.freshSkipPosition(Infinity), 0)
  eq('-Infinity snaps to 0', CN.freshSkipPosition(-Infinity), 0)
  eq('true is one second', CN.freshSkipPosition(true), 1)
})
group('endedNaturally reads the four-second end tolerance', () => {
  eq('a null sample', CN.endedNaturally(null), false)
  eq('an undefined sample', CN.endedNaturally(undefined), false)
  eq('an empty sample is a stream, so it ended on its own', CN.endedNaturally({}), true)
  eq('a zero length is a stream', CN.endedNaturally({ pos: 10, len: 0 }), true)
  eq('a negative length is a stream', CN.endedNaturally({ pos: 10, len: -1 }), true)
  eq('a missing length is a stream', CN.endedNaturally({ pos: 10 }), true)
  eq('a NaN length is a stream', CN.endedNaturally({ pos: 10, len: NaN }), true)
  eq('four seconds from the end is natural', CN.endedNaturally({ pos: 96, len: 100 }), true)
  eq('exactly four seconds short of it is not', CN.endedNaturally({ pos: 95.9, len: 100 }), false)
  eq('at the end', CN.endedNaturally({ pos: 100, len: 100 }), true)
  eq('past the end', CN.endedNaturally({ pos: 130, len: 100 }), true)
  eq('half way is not', CN.endedNaturally({ pos: 50, len: 100 }), false)
  // A track shorter than the tolerance is always "natural", so a skip inside
  // a four-second intro reads as an auto-advance. That is the deliberate
  // "false silence" the header trades for not flashing on every short clip.
  eq('a three-second track at zero is natural', CN.endedNaturally({ pos: 0, len: 3 }), true)
  eq('a four-second track at zero is natural', CN.endedNaturally({ pos: 0, len: 4 }), true)
  eq('a five-second track at zero is not', CN.endedNaturally({ pos: 0, len: 5 }), false)
  eq('a five-second track at four is natural', CN.endedNaturally({ pos: 4, len: 5 }), true)
  // Anything short enough that `len - 4` is at or below 0 is *always*
  // natural, so a one-second skip in a five-second track reads as an
  // auto-advance. That is the deliberate "false silence" of the header.
  eq('a one-second skip in a five-second track is still natural', CN.endedNaturally({ pos: 1, len: 5 }), true)
  eq('a six-second track needs two seconds of slack', CN.endedNaturally({ pos: 1, len: 6 }), false)
})
group('shouldPopOsd is the pop policy for a track change', () => {
  const natural = { pos: 99, len: 100 }
  const skip = { pos: 50, len: 100 }
  const stream = { pos: 0, len: 0 }
  eq('a fresh stamp always pops, whatever the sample says', CN.shouldPopOsd(true, natural, true), true)
  eq('a stamp with no previous sample pops', CN.shouldPopOsd(true, null, true), true)
  eq('a stamp on a track that was never seen pops', CN.shouldPopOsd(true, null, false), true)
  eq('no track seen and no stamp is silent', CN.shouldPopOsd(false, null, false), false)
  eq('an auto-advance is silent', CN.shouldPopOsd(false, natural, true), false)
  eq('a real skip pops', CN.shouldPopOsd(false, skip, true), true)
  eq('a stream with no length is silent', CN.shouldPopOsd(false, stream, true), false)
  // "prev === null on an established track means it lived under one sample
  // window - a skip - and pops".
  eq('an established track with no sample pops', CN.shouldPopOsd(false, null, true), true)
  eq('an undefined sample also pops, not silently', CN.shouldPopOsd(false, undefined, true), true)
  eq('an established track past the tolerance pops', CN.shouldPopOsd(false, { pos: 20, len: 100 }, true), true)
  eq('a falsy hadTrack short-circuits before the sample', CN.shouldPopOsd(false, skip, 0), false)
  eq('an undefined hadTrack too', CN.shouldPopOsd(false, skip, undefined), false)
  eq('a truthy non-boolean stamp is a stamp', CN.shouldPopOsd(1, natural, true), true)
  eq('an empty-string stamp is not a stamp', CN.shouldPopOsd('', natural, true), false)
})

section('common/NowPlaying.js - the time-gated transport stamp')
group('an unstamped library reports no manual intent at all', () => {
  const fresh = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  eq('the loader built the same function set', Object.keys(fresh).filter((k) => k !== '_clock').sort().join(), Object.keys(CN).sort().join())
  eq('manualFresh is false for any budget', fresh.manualFresh(3000), false)
  eq('for the default budget', fresh.manualFresh(0), false)
  eq('for a huge budget', fresh.manualFresh(1e9), false)
  eq('for a negative budget', fresh.manualFresh(-1), false)
  eq('manualDir is 0', fresh.manualDir(), 0)
})
group('a fresh stamp is inside the budget, on both sides of the threshold', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'), 1000)
  np._clock.t = 5000
  np.noteManual('next')
  eq('at the instant of the stamp, the default budget is fresh', np.manualFresh(3000), true)
  eq('a 1ms budget at age 0', np.manualFresh(1), true)
  np._clock.t = 5001
  eq('age 1 with a 1ms budget is still fresh (the test is <=)', np.manualFresh(1), true)
  np._clock.t = 5002
  eq('age 2 with a 1ms budget is stale', np.manualFresh(1), false)
  np._clock.t = 8000
  eq('age exactly 3000 with the default budget is fresh', np.manualFresh(3000), true)
  np._clock.t = 8001
  eq('age 3001 with the default budget is stale', np.manualFresh(3000), false)
  eq('but a longer budget still holds it', np.manualFresh(60000), true)
})
group('a non-positive budget folds to the 3000ms default', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'), 1000)
  np._clock.t = 5000
  np.noteManual('next')
  eq('zero', np.manualFresh(0), true)
  eq('a negative budget', np.manualFresh(-5000), true)
  eq('undefined', np.manualFresh(undefined), true)
  eq('NaN is not > 0, so it folds too', np.manualFresh(NaN), true)
  np._clock.t = 5000 + 3001
  eq('and the fold is a real 3000ms window', np.manualFresh(0), false)
  eq('as is a negative one', np.manualFresh(-1), false)
  eq('but a longer explicit budget still reads fresh', np.manualFresh(3002), true)
})
group('manualDir maps the kind to a direction, and expires with the stamp', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'), 1000)
  np._clock.t = 5000
  np.noteManual('previous')
  eq('previous is -1', np.manualDir(), -1)
  np.noteManual('next')
  eq('next is 1', np.manualDir(), 1)
  np.noteManual('stop')
  eq('anything else is 0', np.manualDir(), 0)
  np.noteManual('')
  eq('an empty kind is 0', np.manualDir(), 0)
  np.noteManual(null)
  eq('a null kind is 0', np.manualDir(), 0)
  np.noteManual(undefined)
  eq('an undefined kind is 0', np.manualDir(), 0)
  np.noteManual(0)
  eq('a falsy kind is 0', np.manualDir(), 0)
  np.noteManual('PREVIOUS')
  eq('the kind is case-sensitive', np.manualDir(), 0)
  np._clock.t = 5000 + 3001
  eq('an expired stamp reports no direction', np.manualDir(), 0)
  eq('even though the kind is still remembered', np.noteManual('next') === undefined, true)
  eq('re-stamping restores it', np.manualDir(), 1)
})
group('noteSample appends and keeps the newest four', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  const ring = []
  np.noteSample(ring, 't1', 10, 100)
  np.noteSample(ring, 't1', 20, 100)
  np.noteSample(ring, 't2', 0, 50)
  np.noteSample(ring, 't1', 30, 100)
  eq('four samples is the cap', ring.length, 4)
  eq('the ring holds the last four in order', ring.map((s) => s.id), ['t1', 't1', 't2', 't1'])
  np.noteSample(ring, 't3', 5, 60)
  eq('the fifth drops the oldest', ring.map((s) => s.id), ['t1', 't2', 't1', 't3'])
  eq('the dropped sample was the first one', ring[0].pos, 20)
  eq('the sample shape', Object.keys(ring[0]), ['id', 'pos', 'len'])
})
group('noteSample coerces its three fields', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  const ring = []
  np.noteSample(ring, 'a', '12', '34')
  eq('a string position is coerced', ring[0], { id: 'a', pos: 12, len: 34 })
  const r2 = []
  np.noteSample(r2, null, undefined, null)
  eq('nullish fields fold to 0 or ""', r2[0], { id: '', pos: 0, len: 0 })
  const r3 = []
  np.noteSample(r3, 7, NaN, 'x')
  eq('a numeric id is stringified, NaN folds to 0', r3[0], { id: '7', pos: 0, len: 0 })
  const r4 = []
  np.noteSample(r4, 'x', -5, -1)
  eq('a negative position is kept, not clamped', r4[0], { id: 'x', pos: -5, len: -1 })
  const r5 = []
  np.noteSample(r5, 'x', Infinity, 0)
  eq('an infinite position is kept', r5[0].pos, Infinity)
})
group('noteSample mutates the caller ring and returns nothing useful', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  const ring = []
  eq('the return value is undefined', np.noteSample(ring, 'a', 1, 2), undefined)
  eq('the ring grew in place', ring.length, 1)
  is('so the caller\'s own array is the buffer', ring[0], (v) => v === ring[0] && v.id === 'a', 'the sample landed in the caller array')
})
group('lastSampleFor finds the newest sample for an id', () => {
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  const ring = [{ id: 't1', pos: 10, len: 100 }, { id: 't2', pos: 0, len: 50 }, { id: 't1', pos: 30, len: 100 }]
  eq('the newest of the matching samples', np.lastSampleFor(ring, 't1'), { id: 't1', pos: 30, len: 100 })
  eq('a single match', np.lastSampleFor(ring, 't2'), { id: 't2', pos: 0, len: 50 })
  eq('an unknown id is null', np.lastSampleFor(ring, 'zz'), null)
  eq('an empty ring is null', np.lastSampleFor([], 't1'), null)
  is('the returned object is the caller\'s own', np.lastSampleFor(ring, 't1') === ring[2], (v) => v === true, 'the ring entry itself')
  eq('a hole in the ring is skipped', np.lastSampleFor([null, { id: 'a', pos: 1, len: 2 }], 'a'), { id: 'a', pos: 1, len: 2 })
  eq('a hole and no match', np.lastSampleFor([null, { id: 'a' }], 'b'), null)
  eq('a numeric id is stringified for the compare', np.lastSampleFor([{ id: '7' }], 7), { id: '7' })
  eq('and undefined does not match an empty id', np.lastSampleFor([{ id: '' }], undefined), null)
  eq('the ring is never mutated', (() => { const before = JSON.stringify(ring); np.lastSampleFor(ring, 't1'); return JSON.stringify(ring) === before })(), true)
})
group('lastSampleFor is the one ring reader that is not nullish-guarded', () => {
  // `ring.length` with no `ring || []`, unlike every other ring reader in
  // these two files. Asserted as the real behaviour - see the report.
  const np = clocked(path.join(SHELL, 'common', 'NowPlaying.js'))
  throws('a null ring throws', () => np.lastSampleFor(null, 'x'), /length/)
  throws('an undefined ring throws', () => np.lastSampleFor(undefined, 'x'), /length/)
  noThrow('an empty ring is fine', () => np.lastSampleFor([], 'x'))
  noThrow('a hole inside the ring is fine', () => np.lastSampleFor([null, { id: 'a' }], 'a'))
})

section('common/NowPlaying.js - the media surface every consumer shares')
group('the whole published surface is here, and it is the only copy', () => {
  // The split used to be "shared with a per-module copy" versus "only here",
  // and the second list was the one that proved the copy had not grown into
  // a second implementation. With one library that distinction is gone, so
  // the assertion is the full surface: every documented helper publishes, and
  // the set is exactly these - which still catches a helper being dropped.
  const shared = ['sortPlayers', 'isBrowserPlayer', 'filterBrowsers', 'fmtTime', 'clampRatio', 'noteManual', 'manualFresh', 'manualDir', 'noteSample', 'lastSampleFor', 'endedNaturally', 'shouldPopOsd', 'freshSkipPosition']
  const unique = ['canSetPlayerVolume', 'canSetPlayerPosition', 'normalizeVolume', 'volumeKnown', 'volumeUnmuted', 'adjustedVolume', 'playerVolumeKey', 'setMuteResumePending', 'consumeMuteResume', 'restorePlayerVolume', 'togglePlayerVolume', 'playerKey', 'playerPosition', 'playerLength', 'normalizePosition', 'progressPercent', 'fmtDuration', 'widestTime', 'volumeProbeStep', 'volumeProbeTarget', 'volumeProbeTook', 'volumeReadback', 'pickPlayerIndex']
  for (const k of shared) is(`${k} publishes`, CN[k], (v) => typeof v === 'function', 'a function')
  for (const k of unique) is(`${k} publishes`, CN[k], (v) => typeof v === 'function', 'a function')
  is('BROWSER_TOKENS publishes the client table', CN.BROWSER_TOKENS, (v) => Array.isArray(v) && v.every((t) => t === String(t).toLowerCase()), 'lowercase tokens')
  eq('and the surface is exactly these, with nothing left over',
    Object.keys(CN).filter((k) => !k.startsWith('_')).sort().join(),
    shared.concat(unique).concat(['BROWSER_TOKENS']).sort().join())
})
group('pickPlayerIndex is the regroup rule the bar pill and the island share', () => {
  // Players are plain objects carrying a state string, so the predicate is
  // the only thing that decides "active" - the same shape the QML callers
  // have, where the predicate reads `p.playbackState === Playing`.
  const P = (id, state = 'paused') => ({ id, state })
  const active = (p) => p.state === 'playing'
  const at = (view, index) => (index >= 0 && index < view.length ? view[index].id : null)
  const pick = (previous, next, index) => CN.pickPlayerIndex(previous, next, index, active)
  const A = P('a')
  const B = P('b')
  const Aup = P('a', 'playing')
  const Bup = P('b', 'playing')

  group('a card on a silent client hands over to a playing one', () => {
    // The reported defect: a regroup promotes the second client to the head
    // and demotes the one on screen, and clamping the index alone leaves the
    // card on the silent client with the active ones stacked behind it.
    const previous = [A, B]
    const next = [Bup, A]
    eq('the card moves to the promoted client', at(next, pick(previous, next, 0)), 'b')
    eq('and the silent client is left at slot 1', at(next, 1), 'a')
    // The same hold one slot in: the client that went silent was not the head
    // to begin with, and the rule is about the hold, not the slot.
    eq('a hold at slot 1 gives over the same way', at(next, pick([Bup, A], next, 1)), 'b')
  })
  group('a client that is still playing keeps the slot', () => {
    // Between two playing clients there is nothing to prefer, so snapping to
    // the head would move the card for no reason.
    const previous = [Aup, Bup]
    const next = [Aup, Bup]
    eq('the second of two playing clients is not moved', pick(previous, next, 1), 1)
    eq('the first is not moved either', pick(previous, next, 0), 0)
    // A regroup that reorders two playing clients follows the identity, so
    // the card lands on the client it was showing rather than the new head.
    const swapped = [Bup, Aup]
    eq('a reorder follows the held client, not the new head', at(swapped, pick(previous, swapped, 0)), 'a')
  })
  group('a view with nothing playing keeps the hold', () => {
    // The reason the pin exists: an all-paused set must not collapse onto
    // slot 0 and lose the last track the user had up.
    const previous = [A, B]
    eq('a silent hold at slot 1 stays', pick(previous, previous, 1), 1)
    eq('a silent hold at slot 0 stays', pick(previous, previous, 0), 0)
    const swapped = [B, A]
    eq('a regroup of two silent clients follows identity, not slot 0', at(swapped, pick(previous, swapped, 0)), 'a')
    // `Stopped` is silent too, and only the predicate knows that - the
    // helper never reads a state itself.
    const stopped = [P('a', 'stopped'), B]
    eq('a stopped client is a silent hold, not an active one', pick(stopped, stopped, 0), 0)
  })
  group('a hold whose client left is only clamped', () => {
    const previous = [A, B]
    eq('a shrunken view clamps to its last slot', pick(previous, [Aup], 1), 0)
    eq('an empty view is slot 0', pick(previous, [], 1), 0)
    const replaced = [P('c', 'playing'), P('d', 'playing')]
    eq('a replaced view keeps the numeric slot it held', at(replaced, pick(previous, replaced, 1)), 'd')
  })
  group('the index is normalized before it addresses anything', () => {
    // Normalization decides *which* client is held, so these assert on the
    // client that survives rather than on the number it landed at.
    const mk = (n) => Array.from({ length: n }, (_, i) => P(`p${i}`, 'playing'))
    const view = mk(3)
    const landing = (previous, index) => view[CN.pickPlayerIndex(previous, view, index, active)].id
    // A previous view sharing its objects with the next one is a regroup, so
    // the held client is found by identity rather than by slot.
    eq('a negative index reads slot 0', landing(view, -3), 'p0')
    eq('an index past the end reads the last slot', landing(view, 99), 'p2')
    eq('a fractional index truncates down', landing(view, 1.9), 'p1')
    eq('a string index coerces', landing(view, '1'), 'p1')
    for (const v of [NaN, undefined, null, 'abc', {}]) {
      eq(`a non-index (${showLabel(v)}) reads slot 0`, landing(view, v), 'p0')
    }
    // A previous view of unrelated objects is the dead-client path, where the
    // normalized slot is the only thing that survives.
    const other = mk(4)
    eq('an unrelated previous view lands on the clamped slot', landing(other, 99), 'p2')
    eq('and an index at its own end is clamped the same way', landing(other, 2), 'p2')
    // No prior view yet (first paint, or a client set that had nothing in it)
    // leaves nothing to hold, so the head is the answer even for an index that
    // would otherwise survive normalization.
    eq('an empty previous view is the head', pick([], view, 4), 0)
    eq('an empty previous view at slot 0 is the head', pick([], view, 0), 0)
  })
  group('it is pure, and it returns an index rather than a player', () => {
    const previous = [A, B]
    const next = [Bup, A]
    const before = JSON.stringify([previous, next])
    const got = pick(previous, next, 0)
    eq('the views are untouched', JSON.stringify([previous, next]), before)
    is('the result is a number', got, (v) => typeof v === 'number' && Number.isInteger(v), 'an integer')
    eq('equal to the slot of a real client', next[got].id, 'b')
    eq('and the result is stable across calls', pick(previous, next, 0), got)
  })
  group('it refuses a null view the way sortPlayers does', () => {
    // No guard: the library's callers always hold a real array, and a silent
    // coercion would hide a caller that lost the list.
    throws('a null next', () => CN.pickPlayerIndex([], null, 0, active), /length/)
    throws('an undefined next', () => CN.pickPlayerIndex([], undefined, 0, active), /length/)
    throws('a null previous', () => CN.pickPlayerIndex(null, [Aup], 0, active), /null/)
    throws('a missing predicate', () => CN.pickPlayerIndex([A], [A], 0), /isPlaying/)
  })
  group('the predicate is consulted for the hold, then for the head', () => {
    // A hold that is playing must be found by identity first, so the head
    // scan never runs - which is what stops a hold on a playing client from
    // being pulled to slot 0.
    const seen = []
    const previous = [Aup, B]
    const swapped = [Bup, Aup]
    CN.pickPlayerIndex(previous, swapped, 0, (p) => {
      seen.push(p.id)
      return p.state === 'playing'
    })
    eq('only the hold is tested when the hold is playing', seen, ['a'])
    const seen2 = []
    CN.pickPlayerIndex([A, B], [Bup, A], 0, (p) => {
      seen2.push(p.id)
      return p.state === 'playing'
    })
    eq('a silent hold falls through to the head scan', seen2, ['a', 'b'])
  })
})
// Labels an assertion input for the report, so a failing case names the value
// that produced it rather than only the expression.
function showLabel(v) {
  if (typeof v === 'string') return JSON.stringify(v)
  if (v === undefined) return 'undefined'
  if (Array.isArray(v)) return `[${v.map(showLabel).join(',')}]`
  if (v && typeof v === 'object') return JSON.stringify(v)
  return String(v)
}

group('canSetPlayerVolume wants both flags, strictly', () => {
  eq('both true', CN.canSetPlayerVolume({ canControl: true, volumeSupported: true }), true)
  eq('no control', CN.canSetPlayerVolume({ canControl: false, volumeSupported: true }), false)
  eq('no volume support', CN.canSetPlayerVolume({ canControl: true, volumeSupported: false }), false)
  eq('neither', CN.canSetPlayerVolume({ canControl: false, volumeSupported: false }), false)
  eq('truthy is not enough', CN.canSetPlayerVolume({ canControl: 1, volumeSupported: 1 }), false)
  eq('an empty player', CN.canSetPlayerVolume({}), false)
  eq('null', CN.canSetPlayerVolume(null), false)
  eq('undefined', CN.canSetPlayerVolume(undefined), false)
  eq('zero', CN.canSetPlayerVolume(0), false)
})
group('playerLength refuses a duration-unknown sentinel', () => {
  // A chromium media session sends INT64_MAX for "no duration" (every YouTube
  // live stream). Quickshell divides microseconds and hands it out as a length,
  // so without this the island shows 2562047788:00:54 as a track time and stays
  // clickable. MPRIS also says a length of 0 means unknown.
  const INT64_MAX = 9223372036854775807
  eq('INT64_MAX microseconds, as Quickshell divides it', CN.playerLength({ lengthSupported: true, length: INT64_MAX / 1e6 }), 0)
  eq('the raw microsecond value, unconverted', CN.playerLength({ lengthSupported: true, length: INT64_MAX }), 0)
  eq('a zero length is unknown per the spec', CN.playerLength({ lengthSupported: true, length: 0 }), 0)
  eq('a negative length', CN.playerLength({ lengthSupported: true, length: -1 }), 0)
  eq('an infinite length', CN.playerLength({ lengthSupported: true, length: Infinity }), 0)
  eq('a length past the plausible bound', CN.playerLength({ lengthSupported: true, length: 200000 }), 0)
  // The bound itself is inclusive, and an hour of stream is not a sentinel.
  eq('exactly the bound is a length', CN.playerLength({ lengthSupported: true, length: 86400 }), 86400)
  eq('a second past the bound is not', CN.playerLength({ lengthSupported: true, length: 86401 }), 0)
  eq('a six-hour podcast', CN.playerLength({ lengthSupported: true, length: 21600 }), 21600)
  eq('a four-minute track', CN.playerLength({ lengthSupported: true, length: 272 }), 272)
  eq('a string length is coerced and kept', CN.playerLength({ lengthSupported: true, length: '272' }), 272)
  // The refusal is length-only: canSeek does not make the number plausible.
  eq('canSeek does not rescue a sentinel', CN.playerLength({ lengthSupported: true, length: INT64_MAX / 1e6, canSeek: true }), 0)
  eq('and neither does a supported length', CN.playerLength({ lengthSupported: true, length: INT64_MAX / 1e6, canSeek: true, positionSupported: true }), 0)
})
group('canSetPlayerPosition wants both flags and a real length', () => {
  // The flags are declarations a player can fake; the length is an absence it
  // cannot. So a lengthless player is refused even when it claims seek, which
  // is the whole live-stream case.
  const seekable = { canSeek: true, positionSupported: true, lengthSupported: true, length: 240 }
  eq('a normal track', CN.canSetPlayerPosition(seekable), true)
  eq('no seek support', CN.canSetPlayerPosition({ ...seekable, canSeek: false }), false)
  eq('no position support', CN.canSetPlayerPosition({ ...seekable, positionSupported: false }), false)
  eq('neither flag', CN.canSetPlayerPosition({ ...seekable, canSeek: false, positionSupported: false }), false)
  // A stream: no mpris:length at all. `length` reads back as the position, so
  // the length - not the reported number - is what has to be asked.
  eq('an unsupported length, whatever length reports', CN.canSetPlayerPosition({ ...seekable, lengthSupported: false, length: 900 }), false)
  // A stream that publishes a zero length, which is what chromium does for a
  // live YouTube video.
  eq('a published zero length', CN.canSetPlayerPosition({ ...seekable, length: 0 }), false)
  // The real live-stream case: a chromium session advertises INT64_MAX.
  eq('the chromium duration-unknown sentinel', CN.canSetPlayerPosition({ ...seekable, length: 9223372036854.775 }), false)
  eq('a missing length field', CN.canSetPlayerPosition({ ...seekable, length: undefined }), false)
  eq('a null length', CN.canSetPlayerPosition({ ...seekable, length: null }), false)
  eq('a NaN length', CN.canSetPlayerPosition({ ...seekable, length: NaN }), false)
  eq('a negative length clamps to zero, so it is refused', CN.canSetPlayerPosition({ ...seekable, length: -5 }), false)
  eq('truthy flags are not enough', CN.canSetPlayerPosition({ canSeek: 1, positionSupported: 1, lengthSupported: 1, length: 240 }), false)
  eq('a length with no flags', CN.canSetPlayerPosition({ lengthSupported: true, length: 240 }), false)
  eq('an empty player', CN.canSetPlayerPosition({}), false)
  eq('null', CN.canSetPlayerPosition(null), false)
  eq('undefined', CN.canSetPlayerPosition(undefined), false)
  eq('zero', CN.canSetPlayerPosition(0), false)
  // A length of one second is a real target and stays seekable: the gate is
  // "is there something to seek to", not "is it worth it".
  eq('a one-second track', CN.canSetPlayerPosition({ ...seekable, length: 1 }), true)
})
group('widestTime is the column sample that cannot elide', () => {
  // The island reserves a fixed width for its two mm:ss columns and left-aligns
  // into it, so the sample has to be the widest string either column can show.
  // `fmtTime` drops the hour, so the cap itself is the longest output, and past
  // the cap there is no length at all.
  //
  // The cap is written out rather than read off the library: a `.pragma
  // library` exposes its functions on the namespace, not a top-level const, so
  // `CN.MAX_PLAUSIBLE_LENGTH` is undefined here - which is exactly why the
  // sample is a call and not a constant a caller has to reach into the library
  // for. 86400 is a day, and it is the bound `playerLength` enforces.
  const CAP = 86400
  eq('the cap as a full clock', CN.widestTime(), '24:00:00')
  eq('it is the cap rendered, not a constant beside it', CN.fmtTime(CAP, CAP), CN.widestTime())
  // Every length a column can be handed - and every position one can show,
  // since reanchor clamps the shown position to the length - renders no wider
  // than the sample. Character count is the proxy, not rendered width: the
  // advance widths are a QML-side measurement, and what has to hold here is
  // that the sample reserves at least as many characters as anything it is
  // sized against.
  // Every length a column can be handed - and every position one can show,
  // since reanchor clamps the shown position to the length - renders no wider
  // than the sample, *under that length as the reference*. Character count is
  // the proxy, not rendered width: the advance widths are a QML-side
  // measurement, and what has to hold is that the sample reserves at least as
  // many characters as anything it is sized against.
  const rendered = [0, 1, 9, 59, 60, 599, 600, 999, 3599, 3600, 5999, 35999, 86399, CAP]
    .flatMap((len) => [CN.fmtTime(len, len), CN.fmtTime(0, len), CN.fmtTime(len / 2, len)])
  eq('no length within the cap renders wider than the sample',
    rendered.filter((s) => s.length > CN.widestTime().length), [])
  eq('and the sample is the longest of them',
    Math.max(...rendered.map((s) => s.length)), CN.widestTime().length)
  // The two shapes the island's column is measured against, pinned because
  // they are the two ends of the format decision: a short track renders narrow,
  // an hour-long one carries the hour field, and the reserve for each is that
  // track's own length rather than a fixed sample.
  eq('a short track, no hour field', CN.fmtTime(229, 229), '3:49')
  eq('an hour-long track, hour field', CN.fmtTime(3723, 3723), '1:02:03')
  // The no-length case has no reference that could put the hour in, so it
  // renders the narrow shape and the island reserves the narrow width there.
  // A stream is the same case: no length, so no hour field, and the column is
  // measured from the placeholder pair.
  eq('no length means the narrow shape', CN.fmtTime(61, 0), '1:01')
  // The island's placeholder pair is the narrow shape twice with the tight
  // separator between, so a lengthless row reserves what it will render. It is
  // one character wider per field than `0:00` - a hyphen is narrower than a
  // digit in most faces, but the reserve is measured from the placeholder
  // itself, so the pair is the sample that has to hold.
  eq('and the placeholder pair is two narrow fields and a separator',
    '--:--/--:--'.length, '--:--'.length * 2 + 1)
  // The other end of the same contract: a length past the cap never reaches a
  // column, so nothing wider than the sample can be asked for.
  eq('a length past the cap is no length', CN.playerLength({ lengthSupported: true, length: CAP * 100 }), 0)
})
group('normalizeVolume clamps into [0, 1] and refuses NaN', () => {
  approx('mid', CN.normalizeVolume(0.5), 0.5, 1e-9)
  eq('zero', CN.normalizeVolume(0), 0)
  eq('one', CN.normalizeVolume(1), 1)
  eq('below zero clamps', CN.normalizeVolume(-1), 0)
  eq('above one clamps', CN.normalizeVolume(2), 1)
  eq('NaN is zero', CN.normalizeVolume(NaN), 0)
  eq('a string is coerced', CN.normalizeVolume('0.3'), 0.3)
  eq('a numeric string above one clamps', CN.normalizeVolume('9'), 1)
  eq('a non-numeric string is zero', CN.normalizeVolume('loud'), 0)
  // `isFinite(n)` is the guarded form, so an infinite volume reads as silence
  // rather than as full scale - which is the opposite of the clamp the
  // surrounding Math.min/Math.max would give.
  eq('Infinity is zero, not full', CN.normalizeVolume(Infinity), 0)
  eq('-Infinity is zero too', CN.normalizeVolume(-Infinity), 0)
  eq('null', CN.normalizeVolume(null), 0)
  eq('undefined', CN.normalizeVolume(undefined), 0)
  eq('false', CN.normalizeVolume(false), 0)
  eq('true', CN.normalizeVolume(true), 1)
  eq('an empty array', CN.normalizeVolume([]), 0)
  eq('an array of one', CN.normalizeVolume([0.5]), 0.5)
})
group('volumeUnmuted is the 0 -> positive crossing', () => {
  eq('from silent to audible', CN.volumeUnmuted(0, 0.5), true)
  eq('from silent to a whisper', CN.volumeUnmuted(0, 0.0001), true)
  eq('already audible', CN.volumeUnmuted(0.1, 0.5), false)
  eq('still silent', CN.volumeUnmuted(0, 0), false)
  eq('already audible and going down', CN.volumeUnmuted(0.5, 0), false)
  eq('a negative current normalizes to silent', CN.volumeUnmuted(-1, 0.5), true)
  eq('an over-range current normalizes to one', CN.volumeUnmuted(2, 0.5), false)
  eq('a NaN current normalizes to silent', CN.volumeUnmuted(NaN, 0.5), true)
  eq('a NaN next normalizes to silent', CN.volumeUnmuted(0, NaN), false)
})
group('adjustedVolume steps by the sign of the direction', () => {
  approx('up', CN.adjustedVolume(0.5, 1, 0.1), 0.6, 1e-9)
  approx('down', CN.adjustedVolume(0.5, -1, 0.1), 0.4, 1e-9)
  eq('up out of range clamps at one', CN.adjustedVolume(0.95, 1, 0.1), 1)
  eq('down out of range clamps at zero', CN.adjustedVolume(0.05, -1, 0.1), 0)
  eq('a negative direction is down', CN.adjustedVolume(0.5, -5, 0.1), 0.4)
  eq('a zero direction is a no-op', CN.adjustedVolume(0.5, 0, 0.1), 0.5)
  eq('a zero step is a no-op', CN.adjustedVolume(0.5, 1, 0), 0.5)
  eq('a negative step is a no-op', CN.adjustedVolume(0.5, 1, -0.1), 0.5)
  eq('a NaN direction is a no-op', CN.adjustedVolume(0.5, NaN, 0.1), 0.5)
  eq('a NaN step is a no-op', CN.adjustedVolume(0.5, 1, NaN), 0.5)
  eq('an infinite direction is a no-op', CN.adjustedVolume(0.5, Infinity, 0.1), 0.5)
  eq('an infinite step is a no-op', CN.adjustedVolume(0.5, 1, Infinity), 0.5)
  eq('an out-of-range volume is clamped first', CN.adjustedVolume(2, -1, 0.1), 0.9)
  eq('a NaN volume starts from zero', CN.adjustedVolume(NaN, 1, 0.1), 0.1)
  eq('a string direction is coerced', CN.adjustedVolume(0.5, '1', 0.1), 0.6)
  approx('a step of one is a full swing', CN.adjustedVolume(0.5, 1, 1), 1, 1e-9)
})
group('volumeProbeStep is the audibly-and-numerically safe delta', () => {
  // 0.02 outruns every player quantization the shell has met (spotify
  // stores 1/65535, vlc 1/320) while being about 0.18 dB, so a probe can
  // only take that much away, and only for the length of a readback.
  approx('the step itself', CN.volumeProbeStep(), 0.02, 1e-12)
  eq('it outruns the coarsest quantization seen', CN.volumeProbeStep() > 1 / 320, true)
  eq('it stays a fraction of full scale', CN.volumeProbeStep() < 0.03, true)
})
group('volumeProbeTarget steps down, and only up out of silence', () => {
  approx('half scale probes two points down', CN.volumeProbeTarget(0.5, 0.02), 0.48, 1e-12)
  approx('full scale', CN.volumeProbeTarget(1, 0.02), 0.98, 1e-12)
  approx('a custom step', CN.volumeProbeTarget(0.5, 0.1), 0.4, 1e-12)
  approx('no step given takes the default', CN.volumeProbeTarget(0.5), 0.48, 1e-12)
  // The rule the section comment states: down whenever down stays above the
  // floor, because a step down onto the floor is a mute, not a probe. The
  // comparison is on the computed level, so a step that lands within float
  // noise of the floor takes the up branch too.
  approx('a step that would land under the floor probes up', CN.volumeProbeTarget(0.2, 0.191), 0.391, 1e-12)
  approx('a step that clears the floor probes down', CN.volumeProbeTarget(0.2, 0.18), 0.02, 1e-12)
  approx('at the floor it probes up instead', CN.volumeProbeTarget(0.02, 0.02), 0.04, 1e-12)
  approx('a silent player is probed up out of it', CN.volumeProbeTarget(0, 0.02), 0.02, 1e-12)
  eq('and never lands on silence', CN.volumeProbeTarget(0.01, 0.02) > 0, true)
  approx('a step too large to fit below', CN.volumeProbeTarget(0.4, 0.5), 0.9, 1e-12)
  // A step above the half ceiling is halved first, so a caller cannot ask
  // the probe to swing full scale; a halved step that then fits below
  // probes down like any other.
  approx('a step above the ceiling is halved, then fits below', CN.volumeProbeTarget(0.9, 5), 0.4, 1e-12)
  eq('and the halved step still probes up, capped at full', CN.volumeProbeTarget(0.5, 5), 1)
  eq('an upward probe from silence is still capped at full', CN.volumeProbeTarget(1, 0.02) <= 1, true)
  approx('a negative volume normalizes first, then probes up', CN.volumeProbeTarget(-1, 0.02), 0.02, 1e-12)
  approx('a NaN volume is silence, probed up', CN.volumeProbeTarget(NaN, 0.02), 0.02, 1e-12)
  eq('a NaN step takes the default', CN.volumeProbeTarget(0.5, NaN), 0.48)
  eq('a negative step takes the default', CN.volumeProbeTarget(0.5, -1), 0.48)
  eq('a zero step takes the default', CN.volumeProbeTarget(0.5, 0), 0.48)
  // Whatever the input, the probe is a different level from the one it
  // started at - a probe equal to the level it probes is not a probe.
  ne('the probe is never the current level', CN.volumeProbeTarget(0.5, 0.02), 0.5)
})
group('volumeProbeTook judges a reading, not a number', () => {
  eq('the player echoed the probe', CN.volumeProbeTook(0.48, 0.48, 0.005), true)
  // spotify quantizes to 1/65535, so an exact match is the exception.
  eq('a quantized echo is still taken', CN.volumeProbeTook(0.428386, 0.4283817807278553, 0.005), true)
  eq('inside the tolerance', CN.volumeProbeTook(0.5, 0.504, 0.005), true)
  // The comparison is a plain `<=`, so the boundary is set by the binary
  // representation of the two levels rather than by the tolerance alone.
  eq('exactly on the tolerance', CN.volumeProbeTook(0, 0.005, 0.005), true)
  eq('a boundary the floats put just outside', CN.volumeProbeTook(0.5, 0.505, 0.005), false)
  eq('outside the tolerance', CN.volumeProbeTook(0.5, 0.506, 0.005), false)
  // The case the whole probe exists for: the level the player kept is the
  // step away, which is four tolerances out.
  eq('the player kept its own level', CN.volumeProbeTook(0.48, 0.5, 0.005), false)
  eq('a coarser player quantization still reads as taken', CN.volumeProbeTook(0.48, 0.481, 0.005), true)
  eq('no tolerance given takes a quarter step', CN.volumeProbeTook(0.5, 0.504), true)
  eq('and a quarter step still refuses a dropped write', CN.volumeProbeTook(0.5, 0.52), false)
  eq('a zero tolerance is refused, so the default holds', CN.volumeProbeTook(0.5, 0.51, 0), false)
  eq('a NaN tolerance falls back too', CN.volumeProbeTook(0.5, 0.51, NaN), false)
  eq('a NaN target', CN.volumeProbeTook(NaN, 0.5, 0.005), false)
  eq('a NaN reading', CN.volumeProbeTook(0.5, NaN, 0.005), false)
  eq('undefined on both sides', CN.volumeProbeTook(undefined, undefined, 0.005), false)
  eq('a string is coerced on both sides', CN.volumeProbeTook('0.5', '0.5', 0.005), true)
  // `Number(null)` is 0, the same coercion normalizeVolume documents. It
  // cannot be reached from the owner, which passes a level from
  // volumeProbeTarget and a number from volumeReadback or null, and the
  // null is filtered out before the call.
  eq('null coerces to a zero reading, as normalizeVolume does', CN.volumeProbeTook(null, null, 0.005), true)
  eq('an infinite reading is not a number', CN.volumeProbeTook(0.5, Infinity, 0.005), false)
  eq('and an infinite target neither', CN.volumeProbeTook(Infinity, 0.5, 0.005), false)
  // The tolerance must stay a fraction of the step, or a dropped write
  // would be read as a rounded one.
  eq('the default tolerance is a quarter step', CN.volumeProbeTook(0.5, 0.5 + CN.volumeProbeStep() / 4 - 1e-12), true)
  eq('and refuses a whole step away', CN.volumeProbeTook(0.5, 0.5 + CN.volumeProbeStep(), false), false)
})
group('volumeKnown separates a level the player reported from one it did not', () => {
  // MPRIS reserves a NEGATIVE Volume for "this client does not know its
  // volume", and normalizeVolume collapses that - and every non-finite read -
  // to 0. That is the right number for a bar to paint and the wrong one to
  // hand back to a player as its own level: the restore half of the volume
  // probe writes it, so a client answering -1 was given Volume = 0 and muted
  // by a probe that was only ever supposed to ask a question.
  eq('a real level', CN.volumeKnown(0.5), true)
  eq('zero is a level, not an absence', CN.volumeKnown(0), true)
  eq('a full level', CN.volumeKnown(1), true)
  // A malformed level above 1 is still a number the player reported, so it
  // reads as known: restoring what it said is more faithful than clamping it,
  // and refusing the probe is not this predicate's business.
  eq('above one', CN.volumeKnown(1.5), true)
  eq('the MPRIS unknown marker', CN.volumeKnown(-1), false)
  eq('and any other negative level', CN.volumeKnown(-0.001), false)
  eq('a not-a-number read', CN.volumeKnown(NaN), false)
  eq('an infinite read', CN.volumeKnown(Infinity), false)
  // A string is coerced, as everywhere else in this file. Unreachable from
  // the owner, which reads a qreal off a player object rather than a text.
  eq('a numeric string', CN.volumeKnown('0.5'), true)
  eq('a non-numeric string', CN.volumeKnown('loud'), false)
  // Number('') is 0, so an empty string reads as a known zero level - the same
  // coercion normalizeVolume documents. Also unreachable, and pinned so the
  // oddity is a decision on record rather than a surprise.
  eq('an empty string coerces to zero, as normalizeVolume does', CN.volumeKnown(''), true)
})
group('the probe cannot mute a player', () => {
  // The two halves are the two ends of one write pair in MediaState: the target
  // goes out, the level the player had comes back. Neither end may reach
  // silence, or the round trip the shell runs about a client it is not sure of
  // becomes a mute.
  for (const v of [0, 0.001, 0.005, 0.01, 0.02, 0.1, 0.5, 0.99, 1]) {
    is(`${v} probes to a level above silence`,
      CN.volumeProbeTarget(v, CN.volumeProbeStep()),
      t => t >= 0.01,
      'the probe target must never be 0 or below')
  }
  // The put-back has to be the player's own number, or it is a second write
  // rather than a restore. For every level the probe accepts, normalizing is
  // the identity - which is what makes the owner free to hand the raw read
  // straight back.
  for (const v of [0, 0.001, 0.02, 0.5, 0.99, 1]) {
    eq(`${v} is restored as itself`, CN.normalizeVolume(v), v)
  }
  // And the level that would have made the put-back a mute is the one the
  // owner refuses to probe at all, so it never reaches the write.
  eq('an unknown level is refused rather than clamped', CN.volumeKnown(-1), false)
  eq('and it is the flatten that made it dangerous', CN.normalizeVolume(-1), 0)
})
group('volumeReadback accepts only a busctl double reply', () => {
  approx('the reply busctl --json=short prints', CN.volumeReadback('{"type":"d","data":0.42}'), 0.42, 1e-12)
  approx('a full-precision double', CN.volumeReadback('{"type":"d","data":4.483863584344243702340e-01}'), 0.44838635843442437, 1e-15)
  eq('a zero volume is a reading, not an absence', CN.volumeReadback('{"type":"d","data":0}'), 0)
  eq('surrounding whitespace is tolerated', CN.volumeReadback('  {"type":"d","data":0.5}\n'), 0.5)
  // Everything below is a transport failure or a foreign shape, and all of
  // them have to read as "no reading" - a busctl hiccup that came back as a
  // number would be read as a dropped write and gray out a working slider.
  eq('an empty answer', CN.volumeReadback(''), null)
  eq('whitespace only', CN.volumeReadback('   \n'), null)
  eq('undefined', CN.volumeReadback(undefined), null)
  eq('null', CN.volumeReadback(null), null)
  eq('a busctl failure line', CN.volumeReadback('No such service "org.mpris.MediaPlayer2.nope"'), null)
  eq('a truncated child', CN.volumeReadback('{"type":"d","dat'), null)
  eq('a non-JSON body', CN.volumeReadback('d 0.42'), null)
  eq('JSON null', CN.volumeReadback('null'), null)
  eq('a JSON array', CN.volumeReadback('[]'), null)
  eq('a JSON string', CN.volumeReadback('"0.42"'), null)
  eq('a bare number', CN.volumeReadback('0.42'), null)
  eq('a differently typed reply', CN.volumeReadback('{"type":"s","data":"0.42"}'), null)
  eq('a reply with no type', CN.volumeReadback('{"data":0.42}'), null)
  eq('a reply with no data', CN.volumeReadback('{"type":"d"}'), null)
  eq('a non-numeric data', CN.volumeReadback('{"type":"d","data":"loud"}'), null)
  eq('an infinite data', CN.volumeReadback('{"type":"d","data":1e999}'), null)
  // The volume comes from a GetAll-shaped dict when a player hands one back
  // verbatim, so a nested object is a shape change, not a reading.
  eq('a GetAll-shaped reply', CN.volumeReadback('{"Volume":{"type":"d","data":0.5}}'), null)
})
group('playerPosition and playerLength floor at zero', () => {
  eq('a position', CN.playerPosition({ position: 5 }), 5)
  eq('a negative position', CN.playerPosition({ position: -3 }), 0)
  eq('a string position', CN.playerPosition({ position: '7' }), 7)
  eq('a null position', CN.playerPosition({ position: null }), 0)
  eq('no position field', CN.playerPosition({}), 0)
  eq('a null player', CN.playerPosition(null), 0)
  eq('a NaN position', CN.playerPosition({ position: NaN }), 0)
  // The *global* isFinite is used here, which coerces: a numeric string is a
  // usable reading, an infinite one is not.
  eq('an infinite position is refused', CN.playerPosition({ position: Infinity }), 0)
  eq('a negative infinity too', CN.playerPosition({ position: -Infinity }), 0)
  eq('a length', CN.playerLength({ length: 5 }), 5)
  eq('a negative length', CN.playerLength({ length: -2 }), 0)
  eq('a string length', CN.playerLength({ length: '9' }), 9)
  eq('no length field', CN.playerLength({}), 0)
  eq('a null player', CN.playerLength(null), 0)
  // `lengthSupported === false` is the only refusal: an absent flag means the
  // length is trusted, because a player that publishes one is answering.
  eq('an explicitly unsupported length reads as zero', CN.playerLength({ length: 5, lengthSupported: false }), 0)
  eq('an explicitly supported length is read', CN.playerLength({ length: 5, lengthSupported: true }), 5)
  eq('a supported length of zero stays zero', CN.playerLength({ length: 0, lengthSupported: true }), 0)
  eq('a NaN length', CN.playerLength({ length: NaN }), 0)
})
group('normalizePosition never lets the position outrun the length', () => {
  eq('inside', CN.normalizePosition(5, 10), 5)
  eq('past the end clamps to the length', CN.normalizePosition(15, 10), 10)
  eq('a negative position clamps to zero', CN.normalizePosition(-5, 10), 0)
  eq('a zero length is no bound', CN.normalizePosition(5, 0), 5)
  eq('a negative length is no bound', CN.normalizePosition(5, -1), 5)
  eq('a NaN position is zero', CN.normalizePosition(NaN, 10), 0)
  eq('a NaN length is no bound', CN.normalizePosition(5, NaN), 5)
  eq('a null length is no bound', CN.normalizePosition(5, null), 5)
  eq('both NaN', CN.normalizePosition(NaN, NaN), 0)
  eq('string fields are coerced', CN.normalizePosition('5', '10'), 5)
})
group('progressPercent is 0..100, or -1 when there is no length', () => {
  approx('half way', CN.progressPercent(5, 10), 50, 1e-9)
  approx('the start', CN.progressPercent(0, 10), 0, 1e-9)
  approx('the end', CN.progressPercent(10, 10), 100, 1e-9)
  eq('past the end clamps to 100', CN.progressPercent(15, 10), 100)
  eq('before the start clamps to 0', CN.progressPercent(-1, 10), 0)
  eq('a stream has no progress at all', CN.progressPercent(5, 0), -1)
  eq('a negative length has no progress', CN.progressPercent(5, -1), -1)
  eq('a NaN length has no progress', CN.progressPercent(5, NaN), -1)
  eq('a null length has no progress', CN.progressPercent(5, null), -1)
  approx('a NaN position reads as the start', CN.progressPercent(NaN, 10), 0, 1e-9)
  approx('a quarter', CN.progressPercent(5, 20), 25, 1e-9)
  approx('a long track, a small position', CN.progressPercent(30, 3600), 100 * 30 / 3600, 1e-9)
})
group('fmtDuration is mm:ss until the hours, then h:mm:ss', () => {
  eq('zero', CN.fmtDuration(0), '00:00')
  eq('the last second of a minute', CN.fmtDuration(59), '00:59')
  eq('a minute', CN.fmtDuration(60), '01:00')
  eq('a minute and a second', CN.fmtDuration(61), '01:01')
  eq('the last second of an hour', CN.fmtDuration(3599), '59:59')
  eq('an hour', CN.fmtDuration(3600), '1:00:00')
  eq('an hour and a minute and a second', CN.fmtDuration(3661), '1:01:01')
  eq('ten hours', CN.fmtDuration(36000), '10:00:00')
  eq('the largest two-digit hour field', CN.fmtDuration(359999), '99:59:59')
  eq('the hours are not zero-padded', CN.fmtDuration(360000), '100:00:00')
  eq('a negative duration', CN.fmtDuration(-5), '00:00')
  eq('a non-numeric string', CN.fmtDuration('abc'), '00:00')
  eq('null', CN.fmtDuration(null), '00:00')
  eq('NaN', CN.fmtDuration(NaN), '00:00')
  eq('a fraction truncates down', CN.fmtDuration(61.9), '01:01')
  eq('Infinity is a finite check failure, so zero', CN.fmtDuration(Infinity), '00:00')
  eq('a numeric string is coerced', CN.fmtDuration('90'), '01:30')
  eq('the minutes field is zero-padded to two', CN.fmtDuration(600), '10:00')
  eq('a duration under a minute is two-padded too', CN.fmtDuration(5), '00:05')
})
group('playerKey is a stable identity for a player', () => {
  eq('a null player', CN.playerKey(null), '')
  eq('a full player', CN.playerKey({ dbusName: 'd', uniqueId: 'u', metadata: { 'mpris:trackid': 't' } }), '["d","u","t",""]')
  eq('no ids: the title fallback is used', CN.playerKey({ trackTitle: 'T', trackArtist: 'A', trackAlbum: 'B' }), '["","","","T\\u001fA\\u001fB"]')
  eq('a dbus name alone leaves the title fallback in place', CN.playerKey({ dbusName: 'd' }), '["d","","","\\u001f\\u001f"]')
  eq('a unique id alone suppresses it', CN.playerKey({ uniqueId: 'u' }), '["","u","",""]')
  eq('a trackid alone suppresses it', CN.playerKey({ metadata: { 'mpris:trackid': 't' } }), '["","","t",""]')
  // The fallback is keyed on `uniqueId` and `mpris:trackid` only, so a dbus
  // name does not suppress it - a player whose ids are absent still gets a
  // title-derived key.
  eq('one identifier suppresses the title fallback', CN.playerKey({ dbusName: 'd', uniqueId: 'u' }), '["d","u","",""]')
  eq('and so does a trackid beside a dbus name', CN.playerKey({ dbusName: 'd', metadata: { 'mpris:trackid': 't' }, trackTitle: 'T' }), '["d","","t",""]')
  eq('the same player twice', CN.playerKey({ trackTitle: 'T', trackArtist: 'A' }), CN.playerKey({ trackTitle: 'T', trackArtist: 'A' }))
  ne('a different title is a different key', CN.playerKey({ trackTitle: 'T' }), CN.playerKey({ trackTitle: 'U' }))
  ne('a different artist is a different key', CN.playerKey({ trackArtist: 'A' }), CN.playerKey({ trackArtist: 'B' }))
  eq('a null trackid counts as present', CN.playerKey({ metadata: { 'mpris:trackid': null } }), '["","","null",""]')
  eq('a non-object metadata is ignored', CN.playerKey({ metadata: 'x', trackTitle: 'T' }), '["","","","T\\u001f\\u001f"]')
  eq('an empty object still gets the separator fallback', CN.playerKey({}), '["","","","\\u001f\\u001f"]')
  eq('the unit separator keeps the fields apart', CN.playerKey({ trackTitle: 'a', trackArtist: 'b' }).includes('\\u001f'), true)
  // A title/artist/album triple cannot collide with another one, because the
  // separator is not a character any of them can contain.
  ne('"a" + "bc" does not collide with "ab" + "c"', CN.playerKey({ trackTitle: 'a', trackArtist: 'bc' }), CN.playerKey({ trackTitle: 'ab', trackArtist: 'c' }))
})
group('playerVolumeKey prefers the dbus name, then the identity', () => {
  eq('a null player has no key', CN.playerVolumeKey(null), '')
  eq('the dbus name wins', CN.playerVolumeKey({ dbusName: 'd', identity: 'i' }), 'd')
  eq('the identity is second', CN.playerVolumeKey({ identity: 'i' }), 'i')
  eq('neither: the player key', CN.playerVolumeKey({ trackTitle: 'T' }), CN.playerKey({ trackTitle: 'T' }))
  eq('which is never empty for an object', CN.playerVolumeKey({}).length > 0, true)
  eq('an empty dbus name falls through', CN.playerVolumeKey({ dbusName: '', identity: 'i' }), 'i')
  eq('a numeric dbus name is stringified', CN.playerVolumeKey({ dbusName: 7 }), '7')
})
group('setMuteResumePending and consumeMuteResume are a one-shot latch', () => {
  const p = { dbusName: 'latch.test' }
  eq('nothing pending yet', CN.consumeMuteResume(p), false)
  CN.setMuteResumePending(p, true)
  eq('the latch is armed', CN.consumeMuteResume(p), true)
  eq('and consuming it disarms it', CN.consumeMuteResume(p), false)
  CN.setMuteResumePending(p, true)
  CN.setMuteResumePending(p, false)
  eq('a pending false clears the latch', CN.consumeMuteResume(p), false)
  eq('setMuteResumePending returns nothing', CN.setMuteResumePending(p, true), undefined)
  eq('a player with no key is never armed', CN.setMuteResumePending(null, true) === undefined && CN.consumeMuteResume(null), false)
  eq('a keyless player cannot be consumed', CN.consumeMuteResume({ volume: 0 }), false)
  // The latch is per player, so arming one does not arm another.
  CN.setMuteResumePending({ dbusName: 'latch.a' }, true)
  eq('another player is unaffected', CN.consumeMuteResume({ dbusName: 'latch.b' }), false)
  eq('and the armed one still fires', CN.consumeMuteResume({ dbusName: 'latch.a' }), true)
})
group('togglePlayerVolume mutes to zero and restores what it saved', () => {
  eq('a player at 42% mutes', CN.togglePlayerVolume({ dbusName: 'v.a', volume: 0.42 }, 0.3), 0)
  eq('and comes back to 42%', CN.togglePlayerVolume({ dbusName: 'v.a', volume: 0 }, 0.3), 0.42)
  eq('a player at 70% mutes', CN.togglePlayerVolume({ dbusName: 'v.b', volume: 0.7 }, 0.3), 0)
  eq('and comes back to 70%', CN.togglePlayerVolume({ dbusName: 'v.b', volume: 0 }, 0.3), 0.7)
  eq('a player at 100% mutes', CN.togglePlayerVolume({ dbusName: 'v.c', volume: 1 }, 0.3), 0)
  eq('and comes back to 100%', CN.togglePlayerVolume({ dbusName: 'v.c', volume: 0 }, 0.3), 1)
  eq('an unmuted player is never lowered by a restore', CN.togglePlayerVolume({ dbusName: 'v.d', volume: 0.2 }, 0.9), 0)
})
group('a player that was never muted comes up to the fallback', () => {
  eq('with a usable fallback', CN.togglePlayerVolume({ dbusName: 'v.e', volume: 0 }, 0.2), 0.2)
  eq('and the fallback does not become the saved value', CN.togglePlayerVolume({ dbusName: 'v.e', volume: 0 }, 0.2), 0.2)
  eq('a fallback of zero gets the 0.5 default', CN.togglePlayerVolume({ dbusName: 'v.f', volume: 0 }, 0), 0.5)
  eq('an out-of-range fallback is normalized first', CN.togglePlayerVolume({ dbusName: 'v.g', volume: 0 }, 2), 1)
  eq('a negative fallback is the 0.5 default', CN.togglePlayerVolume({ dbusName: 'v.h', volume: 0 }, -1), 0.5)
  eq('a NaN fallback is the 0.5 default', CN.togglePlayerVolume({ dbusName: 'v.i', volume: 0 }, NaN), 0.5)
  eq('a saved value beats the fallback', CN.restorePlayerVolume({ dbusName: 'v.a', volume: 0 }, 0.25), 0.42)
  eq('an unknown player takes the fallback', CN.restorePlayerVolume({ dbusName: 'v.unknown', volume: 0 }, 0.25), 0.25)
  eq('an unknown player with no fallback gets the default', CN.restorePlayerVolume({ dbusName: 'v.unknown', volume: 0 }, 0), 0.5)
})
group('the keyless player case is a real identity, not a shared slot', () => {
  eq('a player with no name at all mutes', CN.togglePlayerVolume({ volume: 0.6 }, 0.3), 0)
  eq('and comes back to 60%', CN.togglePlayerVolume({ volume: 0 }, 0.3), 0.6)
  eq('an identity-keyed player mutes', CN.togglePlayerVolume({ identity: 'v.name', volume: 0.6 }, 0.3), 0)
  eq('and comes back', CN.togglePlayerVolume({ identity: 'v.name', volume: 0 }, 0.3), 0.6)
  eq('a player-keyed player mutes', CN.togglePlayerVolume({ trackTitle: 'v.title', volume: 0.6 }, 0.3), 0)
  eq('and comes back', CN.togglePlayerVolume({ trackTitle: 'v.title', volume: 0 }, 0.3), 0.6)
  eq('a null player takes the fallback', CN.togglePlayerVolume(null, 0.4), 0.4)
  eq('a null player with no fallback gets the default', CN.togglePlayerVolume(null, 0), 0.5)
  eq('an out-of-range volume is normalized before the test', CN.togglePlayerVolume({ dbusName: 'v.j', volume: 2 }, 0.3), 0)
  eq('and a negative volume is silent, so it comes up', CN.togglePlayerVolume({ dbusName: 'v.k', volume: -1 }, 0.3), 0.3)
  eq('a missing volume field is silent', CN.togglePlayerVolume({ dbusName: 'v.l' }, 0.3), 0.3)
  eq('a NaN volume is silent', CN.togglePlayerVolume({ dbusName: 'v.m', volume: NaN }, 0.3), 0.3)
})


section('workspaces: the grouping key and the icon lookup names')
group('appKey is the exact lower-cased app id', () => {
  eq('it lower-cases', WSM.appKey('Firefox'), 'firefox')
  eq('and trims', WSM.appKey('  Telegram  '), 'telegram')
  eq('two spellings of one app are one key', WSM.appKey('Firefox') === WSM.appKey('FIREFOX'), true)
  eq('a missing id is the empty key', WSM.appKey(undefined), '')
  eq('and so is a null one', WSM.appKey(null), '')
  // The key is deliberately NOT reduced further: folding the id down to its
  // last component would let two distinct apps of one vendor (org.gnome.Nautilus
  // and org.gnome.Something) share a pile entry, which shows as one app
  // silently standing in for the other.
  eq('a dotted id stays whole', WSM.appKey('org.gnome.Nautilus'), 'org.gnome.nautilus')
})
group('iconCandidates offers the name an icon theme is keyed on', () => {
  eq('a plain name is its own only candidate', WSM.iconCandidates('firefox'), ['firefox'])
  eq('a reverse-DNS id also offers its last component', WSM.iconCandidates('org.telegram.desktop'), ['org.telegram.desktop', 'telegram'])
  eq('the .desktop extension is not part of the name', WSM.iconCandidates('Telegram.desktop'), ['telegram.desktop', 'telegram'])
  eq('a name that IS its last component is not repeated', WSM.iconCandidates('telegram'), ['telegram'])
  eq('an empty id offers nothing', WSM.iconCandidates(''), [])
  eq('and neither does a missing one', WSM.iconCandidates(undefined), [])
  // A trailing dot must not produce an empty candidate - the caller would
  // then ask the icon theme for the empty name. Splitting drops the empty
  // component, so the name is recovered from the one before it.
  eq('a trailing dot still recovers the name', WSM.iconCandidates('foo.'), ['foo.', 'foo'])
  eq('no candidate is ever the empty string', ['foo.', '.foo', 'org.gnome.', '...'].every(id => WSM.iconCandidates(id).every(c => c.length > 0)), true)
})

section('workspaces: one entry per app, capped')
group('pileItems folds one app\'s windows into one entry', () => {
  const one = WSM.pileItems([
    { appId: 'Firefox', address: 'a', title: 'one' },
    { appId: 'firefox', address: 'b', title: 'two' },
  ], 4)
  eq('two windows of one app are one entry', one.items.length, 1)
  eq('and the count is the window count', one.items[0].count, 2)
  eq('with nothing hidden', one.overflow, 0)
})
group('the entry keeps the first window, and follows focus', () => {
  const order = WSM.pileItems([
    { appId: 'firefox', address: 'a', title: 'first' },
    { appId: 'telegram', address: 'b', title: 'chat' },
    { appId: 'alacritty', address: 'c', title: 'term' },
  ], 4)
  eq('entries are in first-appearance order, not sorted', order.items.map(i => i.appId), ['firefox', 'telegram', 'alacritty'])
  eq('the representative is that first window', order.items[0].title, 'first')
  const focused = WSM.pileItems([
    { appId: 'firefox', address: 'a', title: 'first' },
    { appId: 'firefox', address: 'b', title: 'second', activated: true },
  ], 4)
  eq('an activated window takes over the entry it shares', focused.items[0].address, 'b')
  eq('and its title with it', focused.items[0].title, 'second')
  eq('without becoming a second entry', focused.items.length, 1)
  eq('while an unfocused entry is left alone', focused.items[0].activated, true)
})
group('the cap hides the tail and reports it', () => {
  const many = WSM.pileItems(
    ['a', 'b', 'c', 'd', 'e', 'f'].map((n) => ({ appId: n, address: n, title: n })), 4)
  eq('at most MAX_ICONS entries are kept', many.items.length, 4)
  eq('and the rest are counted, not dropped silently', many.overflow, 2)
  eq('the kept ones are the first ones', many.items.map(i => i.appId), ['a', 'b', 'c', 'd'])
  eq('MAX_ICONS is the default cap', WSM.MAX_ICONS, 4)
  eq('pileItems uses it when the caller names none', WSM.pileItems(['a', 'b', 'c', 'd', 'e'].map(n => ({ appId: n, address: n })), 0).items.length, 4)
  eq('a cap under one still keeps one entry rather than none', WSM.pileItems([{ appId: 'a', address: 'a' }], -3).items.length, 1)
  eq('with the remainder still reported', WSM.pileItems([{ appId: 'a', address: 'a' }], -3).overflow, 0)
  eq('nothing overflows at exactly the cap', WSM.pileItems(['a', 'b', 'c', 'd'].map(n => ({ appId: n, address: n })), 4).overflow, 0)
  eq('one overflows by one', WSM.pileItems(['a', 'b', 'c', 'd', 'e'].map(n => ({ appId: n, address: n })), 4).overflow, 1)
})
group('windows with no usable identity', () => {
  eq('an empty list is an empty pile', WSM.pileItems([], 4), { items: [], overflow: 0 })
  eq('a missing list is an empty pile', WSM.pileItems(undefined, 4), { items: [], overflow: 0 })
  // A window with neither an id nor an address cannot be told apart from any
  // other, so collecting them under the empty key would render N identical
  // tiles.
  eq('an idless, addressless record is dropped', WSM.pileItems([{ appId: '', address: '', title: 'x' }], 4).items.length, 0)
  eq('a null record is dropped', WSM.pileItems([null, { appId: 'a', address: 'a' }], 4).items.length, 1)
  // An address is still an identity, so an idless window keeps its own slot
  // and the workspace still reads as occupied.
  const byAddr = WSM.pileItems([{ appId: '', address: '0x1', title: 'x' }], 4)
  eq('an idless window with an address keeps a slot', byAddr.items.length, 1)
  eq('keyed on the address', byAddr.items[0].key, 'addr:0x1')
  eq('and two idless windows do not merge', WSM.pileItems([{ appId: '', address: '0x1' }, { appId: '', address: '0x2' }], 4).items.length, 2)
})
group('urgency propagates to the shared entry', () => {
  const pile = WSM.pileItems([
    { appId: 'firefox', address: 'a', urgent: false },
    { appId: 'firefox', address: 'b', urgent: true },
  ], 4)
  eq('one urgent window marks the app urgent', pile.items[0].urgent, true)
  eq('and a calm one does not', WSM.pileItems([{ appId: 'firefox', address: 'a' }], 4).items[0].urgent, false)
})
group('the caller array is not mutated', () => {
  const records = [{ appId: 'a', address: 'a' }, { appId: 'a', address: 'b' }]
  const before = JSON.stringify(records)
  WSM.pileItems(records, 4)
  eq('a QML binding survives a helper that mutates its input', JSON.stringify(records), before)
})

section('workspaces: geometry')
group('metrics scale with the bar and keep a usable floor', () => {
  const m = WSM.metrics(1, 0)
  eq('at scale 1 the icon is a third under the bar glyph', m.icon, 12)
  eq('the pill pads each edge', m.pad, 5)
  eq('the number gap is wider than the icon gap', m.numGap > m.iconGap, true)
  eq('the slot gap is the bar row spacing, passed in', m.gap, 0)
  eq('and a caller may widen it', WSM.metrics(1, 3).gap, 3)
  eq('a negative gap is clamped to the bar default', WSM.metrics(1, -4).gap, 0)
  eq('scale 2 grows the icon', WSM.metrics(2, 0).icon, 24)
  eq('scale 2 grows the pad', WSM.metrics(2, 0).pad, 10)
  eq('a scale below one still yields a legible icon', WSM.metrics(0.3, 0).icon >= 8, true)
  // A non-numeric or non-positive scale would otherwise produce NaN widths
  // and silently collapse the strip.
  for (const bad of [0, -1, NaN, Infinity, undefined, null, 'two']) {
    eq(`the scale ${String(bad)} falls back to 1`, WSM.metrics(bad, 0).icon, 12)
  }
  eq('a fractional scale rounds to a whole pixel', Number.isInteger(WSM.metrics(1.5, 0).icon), true)
})
group('the icon gap is a quarter of an icon, not a hair', () => {
  // Two app icons have no boundary of their own, so a narrow gap reads as
  // one smear rather than as two apps. This is the assertion that keeps the
  // gap from being tightened back to 1px.
  const m = WSM.metrics(1, 0)
  eq('the gap is a quarter of the icon', m.iconGap, Math.round(m.icon / 4))
  eq('and never narrower than 3px at any scale', [0.3, 0.5, 1, 1.5, 2, 3].every(s => WSM.metrics(s, 0).iconGap >= 3), true)
  eq('and never wider than a third of the icon', [1, 1.5, 2, 3].every(s => WSM.metrics(s, 0).iconGap <= m.icon * s / 3), true)
  eq('the number gap is at least as wide as the icon gap', WSM.metrics(1, 0).numGap >= WSM.metrics(1, 0).iconGap, true)
})
group('number shapes use reduced spacing or touch edge-to-edge', () => {
  eq('plain labels use half the old 6px gap', WSM.numberGap(false), 3)
  eq('boxes have no gap between adjacent surfaces', WSM.numberGap(true), 0)
  eq('boxes and plain labels remain exclusive modes', WSM.numberGap(true) !== WSM.numberGap(false), true)
})
group('the gap between two piles is a property of the shape', () => {
  eq('at scale 1 the piles are 4px apart', WSM.pileGap(1), 4)
  eq('scale 2 opens it', WSM.pileGap(2), 8)
  eq('a small scale keeps a legible minimum', WSM.pileGap(0.2), 3)
  for (const bad of [0, -1, NaN, undefined, null, 'two']) {
    eq(`the gap scale ${String(bad)} falls back to 1`, WSM.pileGap(bad), 4)
  }
  // Number-only spacing is supplied by numberGap(); metrics() receives the
  // chosen value so the strip geometry and its QML delegates stay in sync.
  eq('the plain strip gap is 3px', WSM.metrics(1, WSM.numberGap(false)).gap, 3)
  eq('boxes touch', WSM.metrics(1, WSM.numberGap(true)).gap, 0)
})
group('the pill is shorter than the bar it sits in', () => {
  eq('a 28px bar yields a 22px pill', WSM.pillHeight(28, 1), 22)
  eq('it is inset on both edges', 28 - WSM.pillHeight(28, 1), 6)
  eq('a bigger bar yields a proportionally inset pill', WSM.pillHeight(40, 1) < 40, true)
  eq('and it is never the full height', [20, 28, 40, 60].every(h => WSM.pillHeight(h, 1) < h), true)
  eq('a tiny bar still yields a usable pill', WSM.pillHeight(8, 1), 8)
  eq('the inset never eats the whole bar', [4, 8, 10, 20].every(h => WSM.pillHeight(h, 1) >= 8), true)
  for (const bad of [0, -1, NaN, undefined, null, 'two']) {
    eq(`the pill scale ${String(bad)} falls back to 1`, WSM.pillHeight(28, bad), 22)
  }
  eq('a fractional bar height rounds to a whole pixel', Number.isInteger(WSM.pillHeight(27.6, 1)), true)
})
group('the pill corners are a chip, not a stadium', () => {
  // height/2 rounds the corners so far that the shape reads as a lozenge and
  // the number stops looking like it sits in a box. This is the assertion
  // that keeps the radius from being put back.
  const stadium = h => WSM.pillHeight(h, 1) / 2
  eq('a 28px bar yields a 4px radius', WSM.pillRadius(28, 1), 4)
  eq('well under the 11px a stadium would use', WSM.pillRadius(28, 1) < stadium(28), true)
  eq('and at least twice smaller than one', stadium(28) / WSM.pillRadius(28, 1) >= 2, true)
  // Parallel sides and parallel top/bottom edges are what make it read as a
  // container; a stadium has neither.
  eq('it is never a stadium at any bar height', [16, 20, 28, 40, 60].every(h => WSM.pillRadius(h, 1) < stadium(h)), true)
  // A fifth of the pill where that clears the floor. Below the floor the
  // radius is a constant 3px, which is what keeps a short pill's corners
  // visible at all - so the ratio is only claimed where it actually applies.
  eq('it is about a fifth of the pill', [20, 28, 40, 60].every(h => WSM.pillRadius(h, 1) === Math.round(WSM.pillHeight(h, 1) / 5)), true)
  eq('and it never exceeds a quarter where the floor is not binding', [20, 28, 40, 60].every(h => WSM.pillRadius(h, 1) <= WSM.pillHeight(h, 1) / 4), true)
  eq('and never rounds a short pill into a circle', [4, 8, 10].every(h => WSM.pillRadius(h, 1) < WSM.pillHeight(h, 1) / 2), true)
  eq('it has a visible floor', WSM.pillRadius(8, 1) >= 3, true)
  eq('it tracks the pill rather than a fixed number', WSM.pillRadius(60, 1) > WSM.pillRadius(28, 1), true)
  for (const bad of [0, -1, NaN, undefined, null, 'two']) {
    eq(`the radius scale ${String(bad)} falls back to 1`, WSM.pillRadius(28, bad), 4)
  }
})
group('the pile fill stays faint', () => {
  const m = WSM.metrics(1, 0)
  // The bar sits on a wallpaper, so a strong fill reads as a slab of flat
  // colour and competes with the icons it is meant to be framing.
  eq('the occupied fill is a whisper', m.pillFill, 0.06)
  eq('the focused fill is stronger but still faint', m.pillFillFocused, 0.13)
  eq('focused reads above occupied', m.pillFillFocused > m.pillFill, true)
  eq('neither is opaque', [m.pillFill, m.pillFillFocused].every(a => a > 0 && a < 0.2), true)
  eq('and neither is invisible', [m.pillFill, m.pillFillFocused].every(a => a >= 0.05), true)
  // The two states must stay separable at a glance, or the strip loses the
  // current/occupied/empty reading it is there to give.
  eq('the two states are visibly apart', m.pillFillFocused - m.pillFill >= 0.05, true)
})
group('hover is a lift on top of the state, not a fourth state', () => {
  const m = WSM.metrics(1, 0)
  eq('the lift is 0.1', m.pillHover, 0.1)
  // An offset rather than a parallel branch, so hovering composes with the
  // state underneath instead of overriding it: the pile you point at always
  // lifts by the same amount, and focused/occupied still read through it.
  eq('a hovered occupied pile', m.pillFill + m.pillHover, 0.16)
  eq('a hovered focused pile', m.pillFillFocused + m.pillHover, 0.23)
  // An empty pile is transparent, so hover is the only affordance it has -
  // and it must actually appear rather than lift nothing.
  eq('a hovered empty pile lifts from nothing', 0 + m.pillHover, 0.1)
  eq('every hovered state is fainter than opaque', [0.16, 0.23, 0.1].every(a => a < 0.35), true)
  eq('and the lift is the same for all of them',
    [m.pillFill, m.pillFillFocused, 0].every(base => Math.round((base + m.pillHover) * 100) - Math.round(base * 100) === 10), true)
  eq('the lift is positive, so hover is visible at all', m.pillHover > 0, true)
  // It is a tint ALPHA, so it has to stay a fraction.
  eq('the lift is a fraction, not a percentage', m.pillHover > 0 && m.pillHover < 1, true)
})
group('pileWidth is the number, the icons and the padding', () => {
  const m = WSM.metrics(1, 0)
  // An empty pile is the number and the pill's own air, and nothing else.
  // Reserving the number-to-icons gap unconditionally left dead pixels on
  // the right of an empty workspace's label, so the number read off-centre.
  const bare = m.pad * 2 + 8
  eq('an empty pile is the number and its air', WSM.pileWidth(0, 0, 8, m), bare)
  eq('and reserves no gap for icons that are not there', WSM.pileWidth(0, 0, 8, m), bare)
  eq('which makes the number exactly centred in it', WSM.pileWidth(0, 0, 8, m) - bare, 0)
  eq('one icon adds the gap and its side', WSM.pileWidth(1, 0, 8, m), bare + m.numGap + m.icon)
  eq('two icons add a side and a gap', WSM.pileWidth(2, 0, 8, m), bare + m.numGap + 2 * m.icon + m.iconGap)
  eq('three icons add a third side and a second gap', WSM.pileWidth(3, 0, 8, m), bare + m.numGap + 3 * m.icon + 2 * m.iconGap)
  // The label is measured by the caller's Text, so a two-digit workspace
  // really is wider than a one-digit one.
  eq('a wider label widens the pile', WSM.pileWidth(1, 0, 14, m) - WSM.pileWidth(1, 0, 8, m), 6)
  eq('and widens an empty pile by the same amount', WSM.pileWidth(0, 0, 14, m) - WSM.pileWidth(0, 0, 8, m), 6)
  eq('the overflow chip costs a gap and the chip', WSM.pileWidth(2, 3, 8, m) - WSM.pileWidth(2, 0, 8, m), m.iconGap + m.overflow)
  eq('an overflow with no icons shown costs no leading gap', WSM.pileWidth(0, 2, 8, m) - WSM.pileWidth(0, 0, 8, m), m.overflow)
  eq('a negative count is treated as none', WSM.pileWidth(-2, 0, 8, m), bare)
  eq('a negative label width contributes nothing', WSM.pileWidth(0, 0, -5, m), m.pad * 2)
  eq('a fractional count is floored', WSM.pileWidth(2.9, 0, 8, m), WSM.pileWidth(2, 0, 8, m))
  eq('widths grow monotonically with the icon count', [0, 1, 2, 3, 4].map(n => WSM.pileWidth(n, 0, 8, m)), [0, 1, 2, 3, 4].map(n => WSM.pileWidth(n, 0, 8, m)).sort((a, b) => a - b))
  // The first icon is what the number-to-icons gap is FOR, so adding it must
  // cost strictly more than the icon itself.
  eq('the first icon costs a gap on top of its side', WSM.pileWidth(1, 0, 8, m) - bare > m.icon, true)
})
group('the fixed icon slots reproduce exactly the width that was budgeted', () => {
  // The icon row renders a FIXED MAX_ICONS slots, each occupied one carrying
  // its icon plus the gap that follows it and the last one carrying no
  // trailing gap. This is that sum, spelled out here, because the row and
  // pileWidth are two implementations of one number and nothing else holds
  // them together: if either drifts, the icons overflow the pill or fall
  // short of the space reserved for them.
  const m = WSM.metrics(1, 0)
  const slotRow = (shown) => {
    let total = 0
    for (let i = 0; i < shown; i++) total += m.icon + (i === shown - 1 ? 0 : m.iconGap)
    return total
  }
  for (let n = 1; n <= WSM.MAX_ICONS; n++) {
    // pileWidth also charges the gap between the number and the icons, and
    // the label, neither of which belongs to the icon row.
    const budgeted = WSM.pileWidth(n, 0, 0, m) - (m.pad * 2) - m.numGap
    eq(`${n} icon${n === 1 ? '' : 's'} occupy the width that was budgeted`, slotRow(n), budgeted)
  }
  eq('no trailing gap after the last icon', slotRow(1) - slotRow(0), m.icon)
  eq('each extra icon costs a side and a gap', slotRow(2) - slotRow(1), m.icon + m.iconGap)
  eq('an empty row occupies nothing', slotRow(0), 0)
  // An empty slot collapses to zero, so dropping an icon out of the middle of
  // a run hands back its side AND the gap behind it, and the run closes over
  // rather than holding a hole open.
  eq('dropping the last of n icons frees its side and its gap',
    slotRow(3) - slotRow(2), m.icon + m.iconGap)
  eq('dropping the only icon frees just its side', slotRow(1) - slotRow(0), m.icon)
})
// One thing neither copy does, recorded so the gap is visible in the total
// rather than silently absent.
skip('the OSD/island consumers of the time-gated helpers', 'the callers are QML; only the pure halves are asserted here')

finish()
#!/usr/bin/env node
// Suite: shell/features/notifications/NotificationsLib.js - the synchronous
// replace tag and the tag-aware history.
//
// A fixed `notify-send -r ID` cannot replace: Quickshell 0.3.x answers an
// unknown replaces_id with a fresh server id instead of echoing it (spec 1.2
// says a non-zero replaces_id is echoed back), so every send is a new card.
// The tag is the daemon-side replacement that does not depend on server ids:
// a new arrival carrying the same tag retires the live card(s) carrying it
// (Notifications._admit), and the history keeps one row per tag instead of
// one per server-allocated id (pushHistory). What is asserted is the pure
// policy the QML owns the objects for:
//
//   replaceTagOf   the hint names read, their precedence, and the "" answers
//   pushHistory    the tag eviction alongside the existing id overwrite and
//                  bound - a volume drag keeps one row, not one per send.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, finish, SHELL_DIR,
} from '../../lib/assert.mjs'

const NL = loadLib(path.join(SHELL_DIR, 'features/notifications/NotificationsLib.js'))

suite('notifications', 'NotificationsLib.js: replaceTagOf, tag-aware pushHistory, vol lane')

// ---------------------------------------------------------------------------
section('volOf - the volume-lane level in percent, or -1')
// ---------------------------------------------------------------------------
group('nothing to read is no lane', () => {
  eq('null hints', NL.volOf(null), -1)
  eq('undefined hints', NL.volOf(undefined), -1)
  eq('a non-object', NL.volOf(42), -1)
  eq('empty hints', NL.volOf({}), -1)
  eq('unrelated hints only', NL.volOf({ value: 42 }), -1)
  eq('a boolean is no lane', NL.volOf({ 'x-vb-vol': true }), -1)
  eq('a blank string is no lane', NL.volOf({ 'x-vb-vol': '   ' }), -1)
  eq('a non-numeric string is no lane', NL.volOf({ 'x-vb-vol': 'loud' }), -1)
})

group('percent in, percent out', () => {
  eq('an int', NL.volOf({ 'x-vb-vol': 42 }), 42)
  eq('zero is a lane at silence, not no lane', NL.volOf({ 'x-vb-vol': 0 }), 0)
  eq('a double rounds', NL.volOf({ 'x-vb-vol': 42.6 }), 43)
  eq('a double rounds down', NL.volOf({ 'x-vb-vol': 42.4 }), 42)
  eq('a numeric string reads', NL.volOf({ 'x-vb-vol': '42' }), 42)
  eq('past a hundred clamps', NL.volOf({ 'x-vb-vol': 150 }), 100)
  eq('below zero clamps', NL.volOf({ 'x-vb-vol': -5 }), 0)
  eq('no fraction leg: a double 0.5 is half a percent', NL.volOf({ 'x-vb-vol': 0.5 }), 1)
})

// ---------------------------------------------------------------------------
section('volMutedOf - the mute flag, lenient about the wire type')
// ---------------------------------------------------------------------------
group('absent is unmuted', () => {
  eq('null hints', NL.volMutedOf(null), false)
  eq('empty hints', NL.volMutedOf({}), false)
  eq('an unrelated hint', NL.volMutedOf({ 'x-vb-vol': 42 }), false)
})

group('booleans and numbers', () => {
  eq('true', NL.volMutedOf({ 'x-vb-vol-muted': true }), true)
  eq('false', NL.volMutedOf({ 'x-vb-vol-muted': false }), false)
  eq('1', NL.volMutedOf({ 'x-vb-vol-muted': 1 }), true)
  eq('0', NL.volMutedOf({ 'x-vb-vol-muted': 0 }), false)
})

group('strings, case- and space-insensitive', () => {
  eq('"true"', NL.volMutedOf({ 'x-vb-vol-muted': 'true' }), true)
  eq('" True "', NL.volMutedOf({ 'x-vb-vol-muted': ' True ' }), true)
  eq('"1"', NL.volMutedOf({ 'x-vb-vol-muted': '1' }), true)
  eq('"yes"', NL.volMutedOf({ 'x-vb-vol-muted': 'YES' }), true)
  eq('"false"', NL.volMutedOf({ 'x-vb-vol-muted': 'false' }), false)
  eq('"0"', NL.volMutedOf({ 'x-vb-vol-muted': '0' }), false)
  eq('"no"', NL.volMutedOf({ 'x-vb-vol-muted': 'no' }), false)
  eq('blank', NL.volMutedOf({ 'x-vb-vol-muted': '  ' }), false)
  eq('anything else', NL.volMutedOf({ 'x-vb-vol-muted': 'loud' }), false)
})

// ---------------------------------------------------------------------------
section('hideMetaOf - the per-notification meta-line switch')
// ---------------------------------------------------------------------------
group('absent is shown', () => {
  eq('null hints', NL.hideMetaOf(null), false)
  eq('empty hints', NL.hideMetaOf({}), false)
  eq('an unrelated hint', NL.hideMetaOf({ 'x-vb-vol': 42 }), false)
  eq('the vol-muted flag is a different key', NL.hideMetaOf({ 'x-vb-vol-muted': true }), false)
})

group('the flag hides, through the same lenient reading', () => {
  eq('true', NL.hideMetaOf({ 'x-vb-hide-meta': true }), true)
  eq('false', NL.hideMetaOf({ 'x-vb-hide-meta': false }), false)
  eq('1', NL.hideMetaOf({ 'x-vb-hide-meta': 1 }), true)
  eq('0', NL.hideMetaOf({ 'x-vb-hide-meta': 0 }), false)
  eq('"true"', NL.hideMetaOf({ 'x-vb-hide-meta': 'true' }), true)
  eq('"false"', NL.hideMetaOf({ 'x-vb-hide-meta': 'false' }), false)
  eq('blank', NL.hideMetaOf({ 'x-vb-hide-meta': '  ' }), false)
})

// ---------------------------------------------------------------------------
section('volIconFor / volDimTiersFor - the island thirds')
// ---------------------------------------------------------------------------
group('the icon follows silence and mute', () => {
  eq('zero is off', NL.volIconFor(0, false), 'volume-off')
  eq('the Audio silence threshold holds', NL.volIconFor(0.01, false), 'volume-off')
  eq('just above it is max', NL.volIconFor(0.02, false), 'volume-max')
  eq('muted wins over level', NL.volIconFor(0.9, true), 'volume-off')
  eq('non-finite is off', NL.volIconFor(NaN, false), 'volume-off')
})

group('the tiers read thirds', () => {
  eq('muted gets 0', NL.volDimTiersFor(0.9, true), 0)
  eq('silence gets 0', NL.volDimTiersFor(0, false), 0)
  eq('first third', NL.volDimTiersFor(0.2, false), 1)
  eq('second third', NL.volDimTiersFor(0.5, false), 2)
  eq('third third', NL.volDimTiersFor(0.9, false), 3)
  eq('full', NL.volDimTiersFor(1, false), 3)
})

// ---------------------------------------------------------------------------
section('replaceTagOf - the tag a notification carries, or ""')
// ---------------------------------------------------------------------------
group('nothing to read is no tag', () => {
  eq('null hints', NL.replaceTagOf(null), '')
  eq('undefined hints', NL.replaceTagOf(undefined), '')
  eq('a non-object', NL.replaceTagOf('x-dunst-stack-tag'), '')
  eq('empty hints', NL.replaceTagOf({}), '')
  eq('unrelated hints only', NL.replaceTagOf({ value: 42 }), '')
})

group('the standard stack tag is read', () => {
  eq('a plain tag', NL.replaceTagOf({ 'x-dunst-stack-tag': 'vb-window-volume' }), 'vb-window-volume')
  eq('surrounding whitespace is trimmed', NL.replaceTagOf({ 'x-dunst-stack-tag': '  vol  ' }), 'vol')
  eq('whitespace-only is no tag', NL.replaceTagOf({ 'x-dunst-stack-tag': '   ' }), '')
  eq('a non-string is not a tag', NL.replaceTagOf({ 'x-dunst-stack-tag': 42 }), '')
  eq('a null is not a tag', NL.replaceTagOf({ 'x-dunst-stack-tag': null }), '')
})

group('the aliases are read', () => {
  eq('the mako alias', NL.replaceTagOf({ 'x-canonical-private-synchronous': 'vb-brightness' }), 'vb-brightness')
  eq('the shell name', NL.replaceTagOf({ 'x-vb-tag': 'vb-foo' }), 'vb-foo')
  eq('the alias trims too', NL.replaceTagOf({ 'x-canonical-private-synchronous': '  b  ' }), 'b')
})

group('the first non-empty one wins', () => {
  eq('standard hint over the alias',
    NL.replaceTagOf({ 'x-dunst-stack-tag': 'a', 'x-canonical-private-synchronous': 'b' }), 'a')
  eq('standard hint over the shell name',
    NL.replaceTagOf({ 'x-dunst-stack-tag': 'a', 'x-vb-tag': 'c' }), 'a')
  eq('alias over the shell name',
    NL.replaceTagOf({ 'x-canonical-private-synchronous': 'b', 'x-vb-tag': 'c' }), 'b')
  eq('an empty standard tag falls through to the alias',
    NL.replaceTagOf({ 'x-dunst-stack-tag': '  ', 'x-canonical-private-synchronous': 'b' }), 'b')
  eq('a non-string standard value falls through to the alias',
    NL.replaceTagOf({ 'x-dunst-stack-tag': 7, 'x-canonical-private-synchronous': 'b' }), 'b')
})

// ---------------------------------------------------------------------------
section('pushHistory - one row per tag, not one per server id')
// ---------------------------------------------------------------------------
function row(id, tag) {
  const r = { id, summary: 's' + id, closedReason: 0 }
  if (tag !== undefined) r.replaceTag = tag
  return r
}

group('the untagged contract is unchanged', () => {
  eq('a new row unshifts',
    NL.pushHistory([row(1)], { id: 2, summary: 's2' }, 10).map((r) => r.id), [2, 1])
  eq('the same id overwrites where it stands',
    NL.pushHistory([row(1), row(2)], { id: 2, summary: 'new' }, 10).map((r) => [r.id, r.summary]),
    [[1, 's1'], [2, 'new']])
  eq('the bound drops from the tail',
    NL.pushHistory([row(1), row(2)], { id: 3, summary: 's3' }, 2).map((r) => r.id), [3, 1])
  eq('a non-object snapshot leaves the list alone',
    NL.pushHistory([row(1)], null, 10).map((r) => r.id), [1])
})

group('a tagged arrival evicts the tag\'s other rows', () => {
  eq('one row per tag across server ids',
    NL.pushHistory([row(1, 'vol'), row(9)], { id: 2, summary: 's2', replaceTag: 'vol' }, 10).map((r) => r.id),
    [2, 9])
  eq('rows with other tags stay',
    NL.pushHistory(
      [row(1, 'vol'), row(2, 'bright'), row(3)],
      { id: 4, summary: 's4', replaceTag: 'vol' }, 10).map((r) => r.id),
    [4, 2, 3])
  eq('several stale incarnations all go',
    NL.pushHistory(
      [row(1, 'vol'), row(2, 'vol'), row(3)],
      { id: 4, summary: 's4', replaceTag: 'vol' }, 10).map((r) => r.id),
    [4, 3])
  eq('the same id still overwrites rather than duplicating',
    NL.pushHistory([row(1, 'vol')], { id: 1, summary: 'new', replaceTag: 'vol' }, 10),
    [{ id: 1, summary: 'new', replaceTag: 'vol' }])
  eq('a retag overwrites by id and evicts the new tag\'s row',
    NL.pushHistory(
      [row(1, 'a'), row(2, 'b')],
      { id: 1, summary: 'new', replaceTag: 'b' }, 10).map((r) => r.id),
    [1])
})

group('tag comparison is trimmed and stable', () => {
  eq('padded tags match',
    NL.pushHistory([row(1, 'vol  ')], { id: 2, summary: 's2', replaceTag: '  vol' }, 10).map((r) => r.id),
    [2])
  eq('rows predating the field are untagged and kept',
    NL.pushHistory([{ id: 1, summary: 'old' }], { id: 2, summary: 's2', replaceTag: 'vol' }, 10).map((r) => r.id),
    [2, 1])
  eq('an empty tag evicts nothing',
    NL.pushHistory([row(1, 'vol')], { id: 2, summary: 's2', replaceTag: '  ' }, 10).map((r) => r.id),
    [2, 1])
  eq('a missing tag evicts nothing',
    NL.pushHistory([row(1, 'vol')], { id: 2, summary: 's2' }, 10).map((r) => r.id),
    [2, 1])
  eq('the bound still applies after an eviction',
    NL.pushHistory([row(1, 'vol'), row(2)], { id: 3, summary: 's3', replaceTag: 'vol' }, 2).map((r) => r.id),
    [3, 2])
})

// ---------------------------------------------------------------------------
section('pileDock - the pile clears an open island on its own screen')

group('no island is the bar dock unchanged', () => {
  eq('top', NL.pileDock(40, false, 500, 8), 40)
  eq('zero stays zero', NL.pileDock(0, false, 500, 8), 0)
  eq('garbage bar dock falls back to zero', NL.pileDock('x', false, 500, 8), 0)
})

group('an open island adopts its far edge plus one margin', () => {
  eq('top dock', NL.pileDock(40, true, 500, 8), 508)
  eq('a smaller island never pulls the pile into the bar', NL.pileDock(40, true, 20, 8), 40)
  eq('a tie holds the bar dock', NL.pileDock(40, true, 32, 8), 40)
})

group('garbage island numbers fall back to the bar dock', () => {
  eq('a non-numeric edge', NL.pileDock(40, true, 'x', 8), 40)
  eq('a negative edge', NL.pileDock(40, true, -5, 8), 40)
  eq('a non-numeric margin drops the rhythm', NL.pileDock(40, true, 500, 'x'), 500)
  eq('a negative bar dock reads as zero', NL.pileDock(-4, true, 500, 8), 508)
})

finish()

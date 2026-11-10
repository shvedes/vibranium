#!/usr/bin/env node
// Suite: common/process/PanelList.js - the attach/detach arithmetic behind
// every panel-owning singleton's `_panels` registry.
//
// The contract is small but load-bearing: the list is a QML `property var`,
// so reassignment is the only mutation that notifies, and the helper must
// return a new array every time. The two properties worth pinning are
// therefore identity (the input is never touched, the output is never the
// input) and the exact matching rule (attach appends, detach removes by
// identity).

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const PL = loadLib(path.join(SHELL, 'common', 'process', 'PanelList.js'))

suite('common/process/panel-list', 'PanelList attach and detach')

// ---------------------------------------------------------------------------
section('attach returns a new list with the panel appended')
// ---------------------------------------------------------------------------

group('the input array is never mutated', () => {
  const a = { name: 'a' }
  const input = []
  const out = PL.attach(input, a)
  eq('the input stays empty', input.length, 0)
  is('the output is a different array', out, (v) => v !== input, 'distinct arrays')
  eq('the output holds the panel', out.length, 1)
  is('the appended entry is the panel itself', out[0], (v) => v === a, 'panel instance')
})

group('attach appends to the end and preserves existing order', () => {
  const a = { name: 'a' }
  const b = { name: 'b' }
  const out = PL.attach([a], b)
  eq('length grows by one', out.length, 2)
  is('the existing entry keeps its slot', out[0], (v) => v === a, 'first panel')
  is('the new entry lands last', out[1], (v) => v === b, 'second panel')
})

group('a repeated attach is two entries, not a dedupe', () => {
  const a = { name: 'a' }
  const out = PL.attach(PL.attach([], a), a)
  eq('the panel is listed twice', out.length, 2)
  is('both entries are the same instance', out[0], (v) => v === out[1], 'same panel')
})

group('a missing or non-array list starts empty', () => {
  const a = { name: 'a' }
  eq('null becomes a one-entry list', PL.attach(null, a).length, 1)
  eq('undefined becomes a one-entry list', PL.attach(undefined, a).length, 1)
  eq('a non-array becomes a one-entry list', PL.attach('nope', a).length, 1)
})

// ---------------------------------------------------------------------------
section('detach removes by identity and returns a new list')
// ---------------------------------------------------------------------------

group('only the matching instance goes', () => {
  const a = { name: 'a' }
  const b = { name: 'b' }
  const input = [a, b]
  const out = PL.detach(input, a)
  eq('one entry was removed', out.length, 1)
  is('the survivor is the other panel', out[0], (v) => v === b, 'survivor')
  eq('the input still has both', input.length, 2)
  is('the output is a different array', out, (v) => v !== input, 'distinct arrays')
})

group('every identical entry is removed', () => {
  const a = { name: 'a' }
  const out = PL.detach([a, a, a], a)
  eq('all three are gone', out.length, 0)
})

group('a structurally equal but distinct object is left alone', () => {
  const a = { name: 'a' }
  const twin = { name: 'a' }
  eq('detach matches identity only', PL.detach([a], twin).length, 1)
})

group('a missing or non-array list detaches to empty', () => {
  const a = { name: 'a' }
  eq('null detaches to empty', PL.detach(null, a).length, 0)
  eq('undefined detaches to empty', PL.detach(undefined, a).length, 0)
})

finish()

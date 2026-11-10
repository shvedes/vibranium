#!/usr/bin/env node
// Suite: common/security/SecretOwnership.js - the tracking-list arithmetic
// shared by the pass facade and its controller.
//
// The store is injected, so these are ordinary string/array rules: the list
// is reassigned rather than mutated, an empty handle is a no-op, and every
// drop is named in string form because that is what the tracking list holds.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const SO = loadLib(path.join(SHELL, 'common', 'security', 'SecretOwnership.js'))

// A store stub that records every drop, in order.
function fakeStore() {
  const dropped = []
  return {
    dropped,
    drop(handle) {
      dropped.push(String(handle))
      return true
    },
  }
}

suite('common/security/secret-ownership', 'SecretOwnership untrack/forget/releaseAll')

// ---------------------------------------------------------------------------
section('untrack removes a handle without touching the store')
// ---------------------------------------------------------------------------

group('the list is replaced, not mutated', () => {
  const input = ['pass:read:a', 'pass:write:a']
  const out = SO.untrack(input, 'pass:read:a')
  eq('one entry goes', out.length, 1)
  eq('the survivor is the other handle', out[0], 'pass:write:a')
  eq('the input keeps both', input.length, 2)
  is('the output is a different array', out, (v) => v !== input, 'distinct arrays')
})

group('an empty handle returns an unchanged copy', () => {
  const input = ['a']
  eq('the list is unchanged', SO.untrack(input, '').length, 1)
  eq('null is the empty handle', SO.untrack(input, null).length, 1)
  eq('undefined is the empty handle', SO.untrack(input, undefined).length, 1)
  is('and it is still a copy', SO.untrack(input, ''), (v) => v !== input, 'distinct arrays')
})

group('a handle is compared in string form', () => {
  eq('a numeric handle matches its string entry', SO.untrack(['5', '6'], 5).length, 1)
})

group('a missing list reads as empty', () => {
  eq('null becomes empty', SO.untrack(null, 'a').length, 0)
  eq('undefined becomes empty', SO.untrack(undefined, 'a').length, 0)
})

// ---------------------------------------------------------------------------
section('forget drops the value and stops tracking the handle')
// ---------------------------------------------------------------------------

group('the matching value is dropped and removed', () => {
  const store = fakeStore()
  const input = ['pass:read:a', 'pass:read:b']
  const out = SO.forget(store, input, 'pass:read:a')
  eq('the store saw one drop', store.dropped.length, 1)
  eq('for the named handle', store.dropped[0], 'pass:read:a')
  eq('the list lost one entry', out.length, 1)
  eq('the other handle stays', out[0], 'pass:read:b')
  eq('the input is untouched', input.length, 2)
})

group('an empty handle drops nothing', () => {
  const store = fakeStore()
  eq('the store is not called', SO.forget(store, ['a'], '').length, 1)
  eq('and null is the empty handle', SO.forget(store, ['a'], null).length, 1)
  eq('no drops happened', store.dropped.length, 0)
})

group('a non-string handle is dropped and untracked as its string', () => {
  const store = fakeStore()
  const out = SO.forget(store, ['5'], 5)
  eq('the store saw the string form', store.dropped[0], '5')
  eq('and the list entry went with it', out.length, 0)
})

// ---------------------------------------------------------------------------
section('releaseAll drops every tracked value and empties the list')
// ---------------------------------------------------------------------------

group('each handle is dropped once, in list order', () => {
  const store = fakeStore()
  const input = ['pass:read:a', 'pass:write:a', 'pass:read:b']
  const out = SO.releaseAll(store, input)
  eq('three drops', store.dropped.length, 3)
  eq('the first handle', store.dropped[0], 'pass:read:a')
  eq('the second handle', store.dropped[1], 'pass:write:a')
  eq('the third handle', store.dropped[2], 'pass:read:b')
  eq('the list comes back empty', out.length, 0)
  eq('the input still holds every handle', input.length, 3)
})

group('an empty or missing list drops nothing', () => {
  const store = fakeStore()
  eq('empty releases to empty', SO.releaseAll(store, []).length, 0)
  eq('null releases to empty', SO.releaseAll(store, null).length, 0)
  eq('no drops happened', store.dropped.length, 0)
})

finish()

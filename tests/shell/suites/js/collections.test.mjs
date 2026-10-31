#!/usr/bin/env node
// Suite: common/collections/ - the two bounded stores and the pure row
// geometry.
//
// Three files with no Qt imports, so a plain node harness can drive all of
// them. Every one of them is small and every one of them has a documented
// contract that is easy to get subtly wrong:
//
//   BoundedCache    in place, capacity floor 1, recency refreshed by reads
//   FrozenFootprint copy on write, refuses a collapsed measurement
//   ZoneGeometry    pure numbers, a row identified by (kind, id)
//
// The two bounded stores are the interesting pair: they are both LRU maps
// with the same capacity floor and the same exempt-written-key rule, and they
// mutate differently *on purpose* (README "Two bounded stores, two different
// write disciplines"). Both disciplines are pinned here, because the only way
// to tell them apart later is that one of them stopped being one.
//
// FrozenFootprint.js is the odd one out: it carries no `.pragma library`
// line, which the directory README already records as known drift. The last
// section pins that absence, so adding the pragma cannot happen silently.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains,
  throws, noThrow, approx, skip, deepEqual, show, finish,
} from '../../lib/assert.mjs'

// The shell root is resolved from this file's location, as text.test.mjs
// does. assert.mjs exports SHELL_DIR, but it climbs four levels from
// tests/shell/lib and so lands beside the repo rather than in it; a suite that
// used it would not find the libraries at all.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')

const SRC = (name) => path.join(SHELL, 'common/collections', name)
const BC = loadLib(SRC('BoundedCache.js'))
const FF = loadLib(SRC('FrozenFootprint.js'))
const ZG = loadLib(SRC('ZoneGeometry.js'))

suite('common/collections', 'BoundedCache, FrozenFootprint, ZoneGeometry')

// ---------------------------------------------------------------------------
section('BoundedCache.create - the capacity is the contract')
// ---------------------------------------------------------------------------
group('create normalizes a usable capacity', () => {
  eq('an exact integer is kept', BC.capacity(BC.create(7)), 7)
  eq('one', BC.capacity(BC.create(1)), 1)
  // Math.floor, so a fractional capacity truncates rather than rounding up
  // and immediately evicting a write the caller believed fitted.
  eq('a float truncates down', BC.capacity(BC.create(3.7)), 3)
  eq('a float just under an integer', BC.capacity(BC.create(2.999)), 2)
  eq('a very large capacity is not clamped', BC.capacity(BC.create(1e9)), 1e9)
})
group('a capacity that is not a usable positive integer falls back to 1', () => {
  // "A map with no bound at all is the unbounded memo this library exists to
  // remove" (header). So there is no way to ask for an unbounded map: every
  // unusable capacity becomes the smallest bound there is.
  eq('zero', BC.capacity(BC.create(0)), 1)
  eq('negative', BC.capacity(BC.create(-5)), 1)
  eq('a small negative fraction floors to -1', BC.capacity(BC.create(-0.5)), 1)
  eq('NaN', BC.capacity(BC.create(NaN)), 1)
  eq('Infinity', BC.capacity(BC.create(Infinity)), 1)
  eq('-Infinity', BC.capacity(BC.create(-Infinity)), 1)
  eq('undefined', BC.capacity(BC.create(undefined)), 1)
  eq('null', BC.capacity(BC.create(null)), 1)
  eq('a numeric string is not a number', BC.capacity(BC.create('5')), 1)
  eq('true', BC.capacity(BC.create(true)), 1)
  eq('an object', BC.capacity(BC.create({})), 1)
})
group('a fresh map starts empty and counted at zero', () => {
  const c = BC.create(4)
  eq('size', BC.size(c), 0)
  eq('keys', BC.keys(c), [])
  eq('diagnostics', BC.diagnostics(c), {
    size: 0, capacity: 4, hits: 0, misses: 0, stores: 0, evictions: 0, keys: [],
  })
  // The entries object is created with a null prototype so a key named
  // "__proto__" or "toString" is an ordinary own property of it rather than a
  // write into the prototype chain.
  is('entries has a null prototype', c.entries, (e) => Object.getPrototypeOf(e) === null, 'null prototype')
})

// ---------------------------------------------------------------------------
section('BoundedCache.put - what is accepted and what is refused')
// ---------------------------------------------------------------------------
group('an accepted write returns true and is visible immediately', () => {
  const c = BC.create(2)
  eq('first write', BC.put(c, 'a', 1), true)
  eq('second write', BC.put(c, 'b', 2), true)
  eq('size', BC.size(c), 2)
  eq('keys, oldest use first', BC.keys(c), ['a', 'b'])
  eq('read back', BC.get(c, 'a'), 1)
  // The read above is itself a recency refresh, so a is no longer the least
  // recently used key. keys() reporting the live order rather than the
  // insertion order is how a caller can see that refresh happened.
  eq('the read rotated the LRU order', BC.keys(c), ['b', 'a'])
  eq('stores counted', BC.diagnostics(c).stores, 2)
  // "Values and keys are opaque to the map: it never inspects, copies or
  // mutates what it stores."
  const v = { deep: { n: 1 } }
  BC.put(c, 'o', v)
  is('the value is held by reference', BC.get(c, 'o'), (got) => got === v, 'same object')
})
group('the key must be a non-empty string', () => {
  const c = BC.create(2)
  eq('empty string', BC.put(c, '', 1), false)
  eq('number', BC.put(c, 7, 1), false)
  eq('null', BC.put(c, null, 1), false)
  eq('undefined', BC.put(c, undefined, 1), false)
  eq('object', BC.put(c, {}, 1), false)
  eq('an array', BC.put(c, ['a'], 1), false)
  eq('a whitespace key is a real key', BC.put(c, ' ', 1), true)
  eq('none of the refusals stored anything', BC.size(c), 1)
  eq('and only the whitespace key is present', BC.keys(c), [' '])
})
group('undefined is the one refused value, so a miss stays distinguishable', () => {
  // Header: "Keys must be non-empty strings and values must not be
  // undefined, so a miss and a stored value are distinguishable without a
  // sentinel - a caller can use the result of a read directly."
  const c = BC.create(2)
  eq('undefined value refused', BC.put(c, 'k', undefined), false)
  eq('null accepted', BC.put(c, 'k', null), true)
  eq('read of a stored null', BC.get(c, 'k'), null)
  is('which is not undefined, so it reads as a hit', BC.has(c, 'k'), (v) => v === true, 'true')
  eq('0 accepted', BC.put(c, 'z', 0), true)
  eq('false accepted', BC.put(c, 'y', false), true)
  eq('an empty string accepted', BC.put(c, 'x', ''), true)
  eq('three stored values in a capacity-2 map', BC.size(c), 2)
  eq('the refused key never existed', BC.has(c, 'k'), false)
})
group('re-putting an existing key refreshes recency and does not store again', () => {
  const c = BC.create(3)
  BC.put(c, 'a', 1)
  eq('overwrite accepted', BC.put(c, 'a', 2), true)
  eq('size unchanged', BC.size(c), 1)
  eq('stores counted once', BC.diagnostics(c).stores, 1)
  eq('the newest value wins', BC.get(c, 'a'), 2)
  eq('a second overwrite', BC.put(c, 'a', 3), true)
  eq('still one entry', BC.size(c), 1)
  eq('still one store', BC.diagnostics(c).stores, 1)
  // A refused write must not touch the entry either.
  eq('a refused overwrite', BC.put(c, 'a', undefined), false)
  eq('the previous value survives', BC.get(c, 'a'), 3)
})
group('the map is mutated in place, never replaced', () => {
  // Header: "A QML property emits only when the property itself is assigned,
  // so structural writes here notify nobody." An identity-stable map object is
  // the whole reason this library exists instead of a frozen one.
  const c = BC.create(2)
  const same = c
  BC.put(c, 'a', 1)
  BC.get(c, 'a')
  BC.put(c, 'b', 2)
  BC.has(c, 'a')
  BC.clear(c)
  is('the object a caller holds is the object that was written to', c, (v) => v === same, 'same reference')
  is('clear returns the same object too', BC.clear(c), (v) => v === c, 'same reference')
})

// ---------------------------------------------------------------------------
section('BoundedCache eviction - which key dies first')
// ---------------------------------------------------------------------------
group('capacity one is a working cache of the current key, not a black hole', () => {
  // Header: "The entry just written is exempt from its own eviction: capacity
  // one is a working cache of the current key, not a cache that discards every
  // write." Every write is accepted and every write is readable afterwards.
  const c = BC.create(1)
  eq('first write', BC.put(c, 'a', 'A'), true)
  eq('readable', BC.get(c, 'a'), 'A')
  eq('second write', BC.put(c, 'b', 'B'), true)
  eq('the new key is readable', BC.get(c, 'b'), 'B')
  eq('the old key is gone', BC.has(c, 'a'), false)
  eq('size stays at the bound', BC.size(c), 1)
  eq('one eviction was counted', BC.diagnostics(c).evictions, 1)
})
group('capacity N evicts least recently used, oldest use first', () => {
  const c = BC.create(3)
  for (const k of ['k0', 'k1', 'k2']) BC.put(c, k, k)
  eq('full but not over', BC.keys(c), ['k0', 'k1', 'k2'])
  BC.put(c, 'k3', 'k3')
  eq('the oldest key dies', BC.keys(c), ['k1', 'k2', 'k3'])
  BC.put(c, 'k4', 'k4')
  eq('and the next oldest follows it', BC.keys(c), ['k2', 'k3', 'k4'])
  eq('k0 and k1 are both gone', [BC.has(c, 'k0'), BC.has(c, 'k1')], [false, false])
  eq('size never exceeded the bound', BC.size(c), 3)
  eq('two evictions counted', BC.diagnostics(c).evictions, 2)
  eq('five stores counted', BC.diagnostics(c).stores, 5)
})
group('a read is a recency refresh, so a re-read working set survives', () => {
  // Header: "Recency is a per-entry stamp from a monotonic clock, refreshed by
  // every read and every write, so the working set of a caller that re-reads
  // what it uses stays resident."
  const c = BC.create(2)
  BC.put(c, 'a', 1)
  BC.put(c, 'b', 2)
  eq('a is the least recently used to begin with', BC.keys(c), ['a', 'b'])
  eq('reading a', BC.get(c, 'a'), 1)
  eq('a is now the most recently used', BC.keys(c), ['b', 'a'])
  BC.put(c, 'c', 3)
  eq('so b is the victim, not a', BC.keys(c), ['a', 'c'])
  eq('a survived', BC.get(c, 'a'), 1)
  // A working set kept hot by reads keeps its entries against a stream of
  // unrelated writes; only the untouched one is lost.
  for (let i = 0; i < 5; i++) { BC.get(c, 'a'); BC.get(c, 'c') }
  BC.put(c, 'd', 4)
  eq('a and c are still both resident', BC.keys(c), ['c', 'a', 'd'].filter((k) => BC.has(c, k)).sort((x, y) => BC.keys(c).indexOf(x) - BC.keys(c).indexOf(y)))
})
group('a re-put is also a recency refresh, so it protects the key', () => {
  const c = BC.create(2)
  BC.put(c, 'a', 1)
  BC.put(c, 'b', 2)
  BC.put(c, 'a', 11)
  eq('the rewritten key moved to the front of the LRU order', BC.keys(c), ['b', 'a'])
  BC.put(c, 'c', 3)
  eq('the key that had not been touched is the victim', BC.keys(c), ['a', 'c'])
  eq('the protected key kept the new value', BC.get(c, 'a'), 11)
})
group('the eviction counter is cumulative for the life of the map', () => {
  const c = BC.create(1)
  eq('no evictions yet', BC.diagnostics(c).evictions, 0)
  BC.put(c, 'a', 1)
  eq('still none', BC.diagnostics(c).evictions, 0)
  BC.put(c, 'b', 2)
  eq('one', BC.diagnostics(c).evictions, 1)
  BC.put(c, 'c', 3)
  BC.put(c, 'd', 4)
  eq('three', BC.diagnostics(c).evictions, 3)
  BC.put(c, 'd', 40)
  eq('an overwrite evicts nothing', BC.diagnostics(c).evictions, 3)
  eq('and the counter tracks the bound, not the writes', BC.size(c), 1)
})

// ---------------------------------------------------------------------------
section('BoundedCache.get and has')
// ---------------------------------------------------------------------------
group('get on a miss counts a miss and returns undefined', () => {
  const c = BC.create(2)
  eq('the read', BC.get(c, 'nope'), undefined)
  eq('misses counted', BC.diagnostics(c).misses, 1)
  eq('hits not counted', BC.diagnostics(c).hits, 0)
  eq('a second miss', BC.get(c, 'nope'), undefined)
  eq('misses counted twice', BC.diagnostics(c).misses, 2)
  eq('a miss creates nothing', BC.size(c), 0)
  eq('keys stay empty', BC.keys(c), [])
})
group('get on a hit counts a hit and is the only mutation a read performs', () => {
  const c = BC.create(2)
  BC.put(c, 'a', 'v')
  const before = BC.diagnostics(c)
  eq('the read', BC.get(c, 'a'), 'v')
  const after = BC.diagnostics(c)
  eq('hits counted', after.hits - before.hits, 1)
  eq('misses untouched', after.misses, before.misses)
  eq('stores untouched', after.stores, before.stores)
  eq('evictions untouched', after.evictions, before.evictions)
  eq('size untouched', after.size, before.size)
})
group('has answers membership without recency and without the counters', () => {
  // Header: "Membership without recency and without the read counters, for a
  // caller that asks whether an entry exists rather than reading it."
  const c = BC.create(2)
  eq('absent', BC.has(c, 'x'), false)
  eq('a miss is not counted by has', BC.diagnostics(c).misses, 0)
  BC.put(c, 'a', 1)
  BC.put(c, 'b', 2)
  eq('present', BC.has(c, 'a'), true)
  eq('has creates nothing', BC.size(c), 2)
  eq('has counts no hit', BC.diagnostics(c).hits, 0)
  eq('has does not refresh recency', BC.keys(c), ['a', 'b'])
  BC.put(c, 'c', 3)
  eq('so a looked-at but unread entry is the first victim', BC.keys(c), ['b', 'c'])
})

// ---------------------------------------------------------------------------
section('BoundedCache.keys, clear and diagnostics')
// ---------------------------------------------------------------------------
group('keys() is live keys, least recently used first', () => {
  const c = BC.create(4)
  eq('empty', BC.keys(c), [])
  BC.put(c, 'm', 1)
  BC.put(c, 'z', 2)
  BC.put(c, 'a', 3)
  eq('insertion order, not alphabetical', BC.keys(c), ['m', 'z', 'a'])
  BC.get(c, 'm')
  eq('a read rotates the order', BC.keys(c), ['z', 'a', 'm'])
  const k = BC.keys(c)
  k.push('junk')
  eq('the returned array is a copy', BC.keys(c), ['z', 'a', 'm'])
  is('and pushing to it cannot add a key', c, (v) => BC.has(v, 'junk') === false, 'no junk key')
})
group('clear keeps the capacity, the clock and the counters', () => {
  // Header: "The map object itself is kept so an owner holding a reference
  // does not have to re-bind anything."
  const c = BC.create(2)
  BC.put(c, 'a', 1)
  BC.get(c, 'zz')
  BC.put(c, 'b', 2)
  BC.put(c, 'c', 3)
  is('clear returns the same object', BC.clear(c), (v) => v === c, 'same reference')
  eq('size reset', BC.size(c), 0)
  eq('keys empty', BC.keys(c), [])
  eq('capacity kept', BC.capacity(c), 2)
  eq('counters kept', BC.diagnostics(c), {
    size: 0, capacity: 2, hits: 0, misses: 1, stores: 3, evictions: 1, keys: [],
  })
  eq('the map is usable again', BC.put(c, 'd', 4), true)
  eq('and the bound still applies', BC.keys(c), ['d'])
  BC.put(c, 'e', 5)
  eq('two writes fit the capacity of 2', BC.keys(c), ['d', 'e'])
  BC.put(c, 'f', 6)
  eq('a third evicts the oldest of the cleared map', BC.keys(c), ['e', 'f'])
  eq('and counts it against the lifetime total', BC.diagnostics(c).evictions, 2)
})
group('remove() drops one entry and answers whether it did', () => {
  const c = BC.create(4)
  BC.put(c, 'a', 1)
  BC.put(c, 'b', 2)
  eq('present', BC.remove(c, 'a'), true)
  eq('gone', BC.has(c, 'a'), false)
  eq('size follows', BC.size(c), 1)
  eq('the other entry is untouched', BC.get(c, 'b'), 2)
  eq('a second remove is a miss', BC.remove(c, 'a'), false)
  eq('an empty key is refused', BC.remove(c, ''), false)
  eq('removal is not a use: the survivor keeps its recency', BC.keys(c), ['b'])
  BC.put(c, 'c', 3)
  BC.put(c, 'd', 4)
  BC.put(c, 'e', 5)
  eq('four writes fit the capacity of 4', BC.keys(c), ['b', 'c', 'd', 'e'])
  BC.put(c, 'f', 6)
  eq('a fifth evicts the oldest survivor', BC.keys(c), ['c', 'd', 'e', 'f'])
  eq('removing the newest compacts without disturbing order', BC.remove(c, 'f'), true)
  eq('order of the rest is kept', BC.keys(c), ['c', 'd', 'e'])
})
group('diagnostics() reports the bound, the counters and the live keys', () => {
  const c = BC.create(2)
  BC.put(c, 'a', 1)
  BC.get(c, 'a')
  BC.get(c, 'miss')
  BC.put(c, 'b', 2)
  BC.put(c, 'c', 3)
  eq('the full shape', BC.diagnostics(c), {
    size: 2, capacity: 2, hits: 1, misses: 1, stores: 3, evictions: 1, keys: ['b', 'c'],
  })
  // "size and keys describe the current contents", the rest is cumulative.
  is('the reported keys agree with keys()', BC.diagnostics(c), (d) => deepEqual(d.keys, BC.keys(c)), 'same order')
  const d = BC.diagnostics(c)
  d.keys.push('junk')
  is('and the reported keys are a copy', BC.diagnostics(c), (x) => !x.keys.includes('junk'), 'no junk')
})
group('a key that collides with an Object.prototype name is an ordinary key', () => {
  const c = BC.create(4)
  eq('__proto__', BC.put(c, '__proto__', 1), true)
  eq('toString', BC.put(c, 'toString', 2), true)
  eq('hasOwnProperty', BC.put(c, 'hasOwnProperty', 3), true)
  eq('constructor', BC.put(c, 'constructor', 4), true)
  eq('four entries', BC.size(c), 4)
  eq('a prototype name is not inherited away', BC.has(c, 'constructor'), true)
  eq('and a name that was never stored is still absent', BC.has(c, 'valueOf'), false)
  eq('__proto__ reads back as its stored value', BC.get(c, '__proto__'), 1)
  is('the entries prototype is still null', c.entries, (e) => Object.getPrototypeOf(e) === null, 'null prototype')
})

// ---------------------------------------------------------------------------
section('BoundedCache against arguments that are not caches')
// ---------------------------------------------------------------------------
group('every entry point refuses a non-cache and reads back as empty', () => {
  // A caller that lost its reference, or a QML property that has not been
  // assigned yet, hands in undefined. The library is on the per-keystroke
  // path, so none of this may throw.
  const notCaches = [['null', null], ['undefined', undefined], ['a number', 42], ['a string', 'x'], ['an array', []], ['a bare object', {}], ['an object with entries: null', { entries: null }]]
  for (const [label, bad] of notCaches) {
    noThrow(`capacity on ${label}`, () => BC.capacity(bad))
    eq(`capacity on ${label} is 0`, BC.capacity(bad), 0)
    eq(`size on ${label} is 0`, BC.size(bad), 0)
    eq(`keys on ${label} is empty`, BC.keys(bad), [])
    eq(`put on ${label} is refused`, BC.put(bad, 'k', 1), false)
    eq(`get on ${label} is undefined`, BC.get(bad, 'k'), undefined)
    eq(`has on ${label} is false`, BC.has(bad, 'k'), false)
    eq(`remove on ${label} is false`, BC.remove(bad, 'k'), false)
    eq(`diagnostics on ${label} is zeroed`, BC.diagnostics(bad), {
      size: 0, capacity: 0, hits: 0, misses: 0, stores: 0, evictions: 0, keys: [],
    })
  }
})
group('a get on a non-cache is not counted as a miss', () => {
  // The miss counter lives on the cache, so a caller that reads through an
  // unassigned property cannot inflate the diagnostics of a real map.
  noThrow('get on undefined', () => BC.get(undefined, 'k'))
  noThrow('get on a bare object', () => BC.get({}, 'k'))
  eq('and nothing to show for it', BC.diagnostics(undefined).misses, 0)
})
group('clear on a non-cache hands the argument straight back', () => {
  eq('null', BC.clear(null), null)
  eq('undefined', BC.clear(undefined), undefined)
  eq('a number', BC.clear(42), 42)
  eq('a bare object is not touched either', BC.clear({}), {})
  is('and the bare object gained no entries', BC.clear({}), (v) => !('entries' in v), 'no entries added')
})

// ---------------------------------------------------------------------------
section('FrozenFootprint - the bound and the two predicates')
// ---------------------------------------------------------------------------
group('create normalizes the capacity exactly as BoundedCache does', () => {
  eq('an exact integer', FF.capacity(FF.create(7)), 7)
  eq('a float truncates', FF.capacity(FF.create(3.7)), 3)
  eq('zero falls back to 1', FF.capacity(FF.create(0)), 1)
  eq('negative falls back to 1', FF.capacity(FF.create(-5)), 1)
  eq('NaN falls back to 1', FF.capacity(FF.create(NaN)), 1)
  eq('Infinity falls back to 1', FF.capacity(FF.create(Infinity)), 1)
  eq('undefined falls back to 1', FF.capacity(FF.create(undefined)), 1)
  eq('a string falls back to 1', FF.capacity(FF.create('5')), 1)
  // There is no way to express capacity zero: a store always holds at least
  // the entry it was just handed.
  is('no input yields a capacity below 1', [0, -1, 0.5, NaN, 'x', null, undefined], (vs) => vs.every((v) => FF.capacity(FF.create(v)) >= 1), 'capacity >= 1')
})
group('a fresh store is empty and every read of it says so', () => {
  const s = FF.create(3)
  eq('count', FF.count(s), 0)
  eq('keys', FF.keys(s), [])
  // Header: "The most recently saved key, "" on an empty store."
  eq('activeKey', FF.activeKey(s), '')
  eq('has', FF.has(s, 'x'), false)
  eq('w', FF.w(s, 'x'), 0)
  eq('h', FF.h(s, 'x'), 0)
  eq('diagnostics', FF.diagnostics(s), { count: 0, capacity: 3, active: '', keys: [] })
  is('entries has a null prototype', s.entries, (e) => Object.getPrototypeOf(e) === null, 'null prototype')
})
group('validKey takes any non-empty string, verbatim', () => {
  eq('a word', FF.validKey('slot-3'), true)
  eq('whitespace is a legal key', FF.validKey(' '), true)
  eq('a padded key is legal', FF.validKey(' a '), true)
  eq('the empty string is not', FF.validKey(''), false)
  eq('a number', FF.validKey(3), false)
  eq('null', FF.validKey(null), false)
  eq('undefined', FF.validKey(undefined), false)
  eq('an object', FF.validKey({}), false)
  eq('an array', FF.validKey([]), false)
  eq('a boolean', FF.validKey(true), false)
})
group('validDimension takes a finite positive number', () => {
  // Header: "A footprint dimension must be a finite positive number. Zero,
  // negative and non-finite sizes are refused by save() so a collapsed
  // measurement can never be frozen into the map."
  eq('one', FF.validDimension(1), true)
  eq('a fraction', FF.validDimension(0.5), true)
  eq('a large value', FF.validDimension(1e9), true)
  eq('zero', FF.validDimension(0), false)
  eq('negative zero', FF.validDimension(-0), false)
  eq('negative', FF.validDimension(-1), false)
  eq('NaN', FF.validDimension(NaN), false)
  eq('Infinity', FF.validDimension(Infinity), false)
  eq('-Infinity', FF.validDimension(-Infinity), false)
  eq('a numeric string is not a number', FF.validDimension('5'), false)
  eq('null', FF.validDimension(null), false)
  eq('undefined', FF.validDimension(undefined), false)
  eq('a boolean', FF.validDimension(true), false)
  eq('an array', FF.validDimension([]), false)
  eq('an object', FF.validDimension({}), false)
})

// ---------------------------------------------------------------------------
section('FrozenFootprint.save - copy on write and the refusal codes')
// ---------------------------------------------------------------------------
group('an accepted save returns a new store, even for an unchanged size', () => {
  // Header: "Copy on write: every accepted save returns a NEW store with a
  // fresh entries object, so a QML property binding on the store observes the
  // swap. The previous store is never mutated."
  const s0 = FF.create(3)
  const r1 = FF.save(s0, 'a', 10, 20)
  eq('the result shape', Object.keys(r1).sort(), ['code', 'dimensionsChanged', 'evicted', 'ok', 'store'].sort())
  eq('ok', r1.ok, true)
  eq('an accepted code is the empty string', r1.code, '')
  eq('nothing evicted below the bound', r1.evicted, [])
  is('the store is a new object', r1.store, (v) => v !== s0, 'not the input store')
  eq('the previous store is still empty', FF.count(s0), 0)
  const r2 = FF.save(r1.store, 'a', 10, 20)
  // README: "It reports dimensionsChanged separately from changed: an
  // unchanged size still returns a new store, which is how a frequently
  // reopened slot stays recent enough not to be evicted."
  is('an unchanged size still returns a new store', r2.store, (v) => v !== r1.store, 'not the input store')
  eq('and reports no size change', r2.dimensionsChanged, false)
  eq('the entry is still there', FF.w(r2.store, 'a'), 10)
  eq('with the same height', FF.h(r2.store, 'a'), 20)
})
group('dimensionsChanged separates a size change from a recency refresh', () => {
  let s = FF.create(3)
  s = FF.save(s, 'a', 10, 20).store
  eq('the same size twice is not a change', FF.save(s, 'a', 10, 20).dimensionsChanged, false)
  eq('a new width is a change', FF.save(s, 'a', 11, 20).dimensionsChanged, true)
  eq('a new height is a change', FF.save(s, 'a', 10, 21).dimensionsChanged, true)
  eq('a key that is not held yet is always a change', FF.save(s, 'b', 10, 20).dimensionsChanged, true)
  // The comparison is ===, so it is on the exact number, not on what the two
  // numbers print as.
  const f = FF.save(FF.create(3), 'f', 0.1 + 0.2, 1).store
  eq('a bit-equal float is not a change', FF.save(f, 'f', 0.30000000000000004, 1).dimensionsChanged, false)
  eq('the decimal that prints the same is a change', FF.save(f, 'f', 0.3, 1).dimensionsChanged, true)
  eq('and the same width with a new height is a change', FF.save(f, 'f', 0.1 + 0.2, 2).dimensionsChanged, true)
})
group('a refused save names the offending dimension and leaves the store alone', () => {
  const s = FF.create(2)
  const cases = [
    ['the empty key', ['', 1, 1], 'invalid_key'],
    ['a null key', [null, 1, 1], 'invalid_key'],
    ['a numeric key', [5, 1, 1], 'invalid_key'],
    ['a zero width', ['a', 0, 1], 'invalid_width'],
    ['a negative width', ['a', -1, 1], 'invalid_width'],
    ['a NaN width', ['a', NaN, 1], 'invalid_width'],
    ['an infinite width', ['a', Infinity, 1], 'invalid_width'],
    ['a string width', ['a', '10', 1], 'invalid_width'],
    ['a null width', ['a', null, 1], 'invalid_width'],
    ['a zero height', ['a', 1, 0], 'invalid_height'],
    ['a negative height', ['a', 1, -3], 'invalid_height'],
    ['a NaN height', ['a', 1, NaN], 'invalid_height'],
    ['an infinite height', ['a', 1, Infinity], 'invalid_height'],
    ['an undefined height', ['a', 1, undefined], 'invalid_height'],
  ]
  for (const [label, args, code] of cases) {
    const r = FF.save(s, ...args)
    eq(`${label} is refused with ${code}`, r.code, code)
    eq(`${label} reports ok false`, r.ok, false)
    eq(`${label} reports no dimension change`, r.dimensionsChanged, false)
    eq(`${label} evicted nothing`, r.evicted, [])
    is(`${label} hands back the store it was given`, r.store, (v) => v === s, 'the input store')
  }
  eq('and the store is untouched by every refusal', FF.diagnostics(s), { count: 0, capacity: 2, active: '', keys: [] })
})
group('the refusal order is key, then width, then height', () => {
  // A row that is wrong in three ways is reported for the first fault in the
  // check order, so the code a caller sees is stable rather than whichever
  // branch the interpreter reached first.
  const s = FF.create(2)
  eq('key before width', FF.save(s, '', 0, 0).code, 'invalid_key')
  eq('key before height', FF.save(s, null, 1, 0).code, 'invalid_key')
  eq('width before height', FF.save(s, 'a', 0, 0).code, 'invalid_width')
  eq('a good width with a bad height names the height', FF.save(s, 'a', 1, -1).code, 'invalid_height')
})
group('save is copy on write: the previous store is never mutated', () => {
  const s0 = FF.create(2)
  const s1 = FF.save(s0, 'a', 1, 1).store
  const s2 = FF.save(s1, 'b', 2, 2).store
  const s3 = FF.save(s2, 'c', 3, 3).store
  eq('the first store is still empty', FF.count(s0), 0)
  eq('the first store has no a', FF.has(s0, 'a'), false)
  eq('the second store holds only a', FF.keys(s1), ['a'])
  eq('the second store has no b', FF.has(s1, 'b'), false)
  eq('the second store still has a at its saved size', [FF.w(s1, 'a'), FF.h(s1, 'a')], [1, 1])
  eq('the third store holds a and b', FF.keys(s2), ['a', 'b'])
  // Capacity 2, so the third save evicts a from the *new* store only: s2 still
  // holds a and b, and a dependent holding s2 keeps seeing both.
  eq('the newest store is the bounded one', FF.keys(s3), ['b', 'c'])
  eq('and s2 was not trimmed to match it', FF.keys(s2), ['a', 'b'])
  eq('a wider bound keeps every save', (() => {
    let t = FF.create(3)
    t = FF.save(t, 'a', 1, 1).store
    t = FF.save(t, 'b', 2, 2).store
    return FF.keys(FF.save(t, 'c', 3, 3).store)
  })(), ['a', 'b', 'c'])
  // A dependent that captured s1 still reads s1's numbers after s2 and s3.
  eq('a captured store keeps its own active key', FF.activeKey(s1), 'a')
  eq('and its own touch clock', s1.touch, 1)
  eq('each save advances the touch clock', [s2.touch, s3.touch], [2, 3])
})

// ---------------------------------------------------------------------------
section('FrozenFootprint eviction - the ring')
// ---------------------------------------------------------------------------
group('the oldest saved entry dies first, and the newest always survives', () => {
  let s = FF.create(1)
  const r1 = FF.save(s, 'a', 1, 1)
  s = r1.store
  eq('capacity one holds the entry just saved', FF.count(s), 1)
  eq('and it is readable', [FF.w(s, 'a'), FF.h(s, 'a')], [1, 1])
  const r2 = FF.save(s, 'b', 2, 2)
  s = r2.store
  eq('the new save is accepted', r2.ok, true)
  eq('the previous key is reported as evicted', r2.evicted, ['a'])
  eq('the previous key is gone', FF.has(s, 'a'), false)
  eq('its width reads as 0', FF.w(s, 'a'), 0)
  eq('the new key is live', [FF.w(s, 'b'), FF.h(s, 'b')], [2, 2])
  eq('the bound holds', FF.count(s), 1)
  eq('activeKey is the key just saved', FF.activeKey(s), 'b')
})
group('a ring of N keeps the newest N and drops the oldest as it wraps', () => {
  let s = FF.create(3)
  const seen = []
  for (const k of ['a', 'b', 'c', 'd', 'e', 'f']) {
    const r = FF.save(s, k, 1, 1)
    s = r.store
    seen.push({ written: k, evicted: r.evicted, keys: FF.keys(s) })
  }
  eq('the first three writes do not evict', seen.slice(0, 3).map((x) => x.evicted), [[], [], []])
  eq('the fourth write evicts the first', seen[3].evicted, ['a'])
  eq('the fifth evicts the second', seen[4].evicted, ['b'])
  eq('the sixth evicts the third', seen[5].evicted, ['c'])
  eq('the ring holds the newest three', FF.keys(s), ['d', 'e', 'f'])
  eq('oldest first in the key order', FF.keys(s), ['d', 'e', 'f'])
  eq('newest first in activeKey', FF.activeKey(s), 'f')
  eq('count is exactly the bound', FF.count(s), 3)
})
group('count never exceeds the capacity, however long the key loop', () => {
  // Header: "Runs on every accepted save, so a key loop cannot grow the store
  // past the bound." Exercised over far more keys than the bound.
  for (const cap of [1, 2, 5, 17]) {
    let s = FF.create(cap)
    let peak = 0
    for (let i = 0; i < 200; i++) {
      s = FF.save(s, `slot-${i}`, i + 1, i + 2).store
      peak = Math.max(peak, FF.count(s))
    }
    eq(`capacity ${cap} peaks at its bound`, peak, cap)
    eq(`capacity ${cap} settles at its bound`, FF.count(s), cap)
    eq(`capacity ${cap} is reported correctly`, FF.capacity(s), cap)
  }
})
group('a re-save is a recency refresh, so a frequently reopened slot survives', () => {
  // Header: "Every accepted save refreshes that key's recency, so an
  // unchanged size still returns a new store: a slot that is reopened often
  // stays recent enough not to be evicted."
  let s = FF.create(2)
  s = FF.save(s, 'a', 10, 10).store
  s = FF.save(s, 'b', 20, 20).store
  eq('a is the oldest save', FF.keys(s), ['a', 'b'])
  s = FF.save(s, 'a', 10, 10).store
  eq('re-saving a moved it behind b', FF.keys(s), ['b', 'a'])
  eq('and reported no dimension change', FF.save(s, 'a', 10, 10).dimensionsChanged, false)
  const r = FF.save(s, 'c', 30, 30)
  eq('so b is the victim, not the refreshed a', r.evicted, ['b'])
  eq('the refreshed slot survived', FF.has(r.store, 'a'), true)
  eq('at its original size', FF.w(r.store, 'a'), 10)
})
group('the entry just saved is exempt from its own eviction', () => {
  // Header: "Least recently used eviction, with the key just saved exempt: the
  // entry an open island is reading is never the victim of its own save."
  let s = FF.create(1)
  for (const k of ['a', 'b', 'c']) {
    const r = FF.save(s, k, 1, 1)
    eq(`saving ${k} over capacity ${1} evicts something else`, r.evicted, k === 'a' ? [] : [k === 'b' ? 'a' : 'b'])
    s = r.store
    is(`the store after saving ${k} holds that key`, s, (v) => FF.has(v, k), 'saved key resident')
    eq(`and only that key`, FF.count(s), 1)
  }
})
group('clear keeps the bound and starts a new touch clock', () => {
  let s = FF.create(3)
  s = FF.save(s, 'a', 1, 1).store
  const cleared = FF.clear(s)
  is('a new store, not the one passed in', cleared, (v) => v !== s, 'new object')
  eq('empty', FF.count(cleared), 0)
  eq('with no active key', FF.activeKey(cleared), '')
  eq('and the same bound', FF.capacity(cleared), 3)
  eq('the touch clock is back to zero', cleared.touch, 0)
  eq('and the store is usable', FF.save(cleared, 'z', 1, 1).ok, true)
  eq('a non-store is cleared into a capacity-one store', FF.capacity(FF.clear(null)), 1)
  eq('a bare object has no capacity to keep', FF.capacity(FF.clear({})), 1)
})

// ---------------------------------------------------------------------------
section('FrozenFootprint reads and diagnostics')
// ---------------------------------------------------------------------------
group('keys() is live keys, least recently saved first', () => {
  let s = FF.create(4)
  eq('an empty store has no keys', FF.keys(s), [])
  s = FF.save(s, 'z', 1, 1).store
  s = FF.save(s, 'm', 1, 1).store
  s = FF.save(s, 'a', 1, 1).store
  eq('save order, not alphabetical', FF.keys(s), ['z', 'm', 'a'])
  s = FF.save(s, 'z', 1, 1).store
  eq('re-saving z moved it to the back', FF.keys(s), ['m', 'a', 'z'])
  const k = FF.keys(s)
  k.push('junk')
  is('the returned array is a copy', s, (v) => !FF.has(v, 'junk'), 'no junk key')
})
group('activeKey is the most recently saved key, "" on an empty store', () => {
  let s = FF.create(3)
  eq('before any write', FF.activeKey(s), '')
  s = FF.save(s, 'a', 1, 1).store
  eq('after one write', FF.activeKey(s), 'a')
  s = FF.save(s, 'b', 1, 1).store
  eq('after a second write', FF.activeKey(s), 'b')
  // A re-save is the most recent save, so it takes the active slot back.
  s = FF.save(s, 'a', 1, 1).store
  eq('a re-save takes the active slot', FF.activeKey(s), 'a')
  s = FF.save(s, 'c', 1, 1).store
  eq('a third write takes it back', FF.activeKey(s), 'c')
  // The active key is inside the store and inside the bound.
  is('the active key is one of the live keys', s, (v) => FF.keys(v).includes(FF.activeKey(v)), 'live key')
})
group('w and h answer 0 for a key the store does not hold', () => {
  const s = FF.save(FF.create(2), 'a', 3, 4).store
  eq('a live width', FF.w(s, 'a'), 3)
  eq('a live height', FF.h(s, 'a'), 4)
  eq('an absent width', FF.w(s, 'zz'), 0)
  eq('an absent height', FF.h(s, 'zz'), 0)
  eq('an empty key reads as absent', FF.w(s, ''), 0)
  eq('a null key reads as absent', FF.h(s, null), 0)
  eq('a numeric key reads as absent', FF.w(s, 5), 0)
  eq('a float width is kept exactly', FF.w(FF.save(FF.create(1), 'f', 1.5, 2.5).store, 'f'), 1.5)
  // save() refuses a non-positive dimension, so a stored width can never be 0
  // and a 0 read is unambiguously "not held" for a caller.
  eq('a stored width is never 0', FF.save(s, 'z', 0, 1).code, 'invalid_width')
  eq('and a 0 width means absent', [FF.w(FF.save(s, 'z', 0, 1).store, 'z'), FF.has(s, 'z')], [0, false])
})
group('diagnostics() reports count, capacity, active and keys', () => {
  let s = FF.create(2)
  s = FF.save(s, 'a', 1, 1).store
  s = FF.save(s, 'b', 2, 2).store
  s = FF.save(s, 'c', 3, 3).store
  eq('after a wrap', FF.diagnostics(s), { count: 2, capacity: 2, active: 'c', keys: ['b', 'c'] })
  is('the reported keys agree with keys()', FF.diagnostics(s), (d) => deepEqual(d.keys, FF.keys(s)), 'same order')
  eq('the reported count agrees with count()', FF.diagnostics(s).count, FF.count(s))
  eq('the reported capacity agrees with capacity()', FF.diagnostics(s).capacity, FF.capacity(s))
  eq('the reported active agrees with activeKey()', FF.diagnostics(s).active, FF.activeKey(s))
})
group('a non-store argument reads as an empty store', () => {
  const notStores = [['null', null], ['undefined', undefined], ['a number', 42], ['a string', 'x'], ['an array', []], ['a bare object', {}], ['an object with no entries', { capacity: 2 }]]
  for (const [label, bad] of notStores) {
    noThrow(`count on ${label}`, () => FF.count(bad))
    eq(`count on ${label} is 0`, FF.count(bad), 0)
    eq(`keys on ${label} is empty`, FF.keys(bad), [])
    eq(`activeKey on ${label} is ""`, FF.activeKey(bad), '')
    eq(`w on ${label} is 0`, FF.w(bad, 'x'), 0)
    eq(`h on ${label} is 0`, FF.h(bad, 'x'), 0)
    eq(`has on ${label} is false`, FF.has(bad, 'x'), false)
  }
  eq('a non-store reports capacity 0', FF.capacity(null), 0)
  eq('diagnostics on null', FF.diagnostics(null), { count: 0, capacity: 0, active: '', keys: [] })
})
group('save onto a non-object store starts a fresh capacity-one store', () => {
  // "The store argument must be a create() product (or one it returned)"
  // (header). A caller that violates it gets a working single-slot store
  // rather than a throw on the layout path.
  const r = FF.save(null, 'a', 1, 1)
  eq('the save is accepted', r.ok, true)
  eq('and the result is a usable store', FF.diagnostics(r.store), { count: 1, capacity: 1, active: 'a', keys: ['a'] })
  const bad = FF.save(42, '', 1, 1)
  eq('a refused save on a non-store reports the key fault', bad.code, 'invalid_key')
  eq('and still hands back a usable store', FF.capacity(bad.store), 1)
})

// ---------------------------------------------------------------------------
section('The two bounded stores, side by side')
// ---------------------------------------------------------------------------
// README, "Two bounded stores, two different write disciplines": both files
// are bounded LRU maps with the same capacity floor and the same
// exempt-the-just-written-key rule, and they mutate differently on purpose.
// The shared half is asserted against both, so the pair cannot drift apart,
// and the differing half is asserted separately, because the only way to tell
// them apart later is that one of them stopped being one.
group('both normalize the capacity the same way', () => {
  for (const asked of [0, 1, 5, 8.9, -3, NaN, Infinity, undefined, '4', null]) {
    const b = BC.capacity(BC.create(asked))
    const f = FF.capacity(FF.create(asked))
    eq(`BoundedCache and FrozenFootprint agree on ${show(asked)}`, b, f)
  }
  eq('an exact integer is kept by both', [BC.capacity(BC.create(5)), FF.capacity(FF.create(5))], [5, 5])
  eq('a float truncates in both', [BC.capacity(BC.create(8.9)), FF.capacity(FF.create(8.9))], [8, 8])
  eq('the floor is 1 in both', [BC.capacity(BC.create(0)), FF.capacity(FF.create(0))], [1, 1])
  eq('and 1 for an unbounded request in both', [BC.capacity(BC.create(Infinity)), FF.capacity(FF.create(Infinity))], [1, 1])
  is('no input yields a capacity below 1 in either', [0, -1, 0.5, NaN, 'x', null, undefined], (vs) => vs.every((v) => BC.capacity(BC.create(v)) >= 1 && FF.capacity(FF.create(v)) >= 1), 'capacity >= 1 in both')
})
group('both evict the least recently used and exempt the entry just written', () => {
  // BoundedCache, capacity 2: a, b, then a read of a, then c evicts b.
  const bc = BC.create(2)
  BC.put(bc, 'a', 1)
  BC.put(bc, 'b', 2)
  BC.get(bc, 'a')
  BC.put(bc, 'c', 3)
  eq('BoundedCache drops the entry that was not touched', BC.keys(bc), ['a', 'c'])
  // FrozenFootprint, capacity 2: the same sequence, with a re-save as the
  // recency refresh.
  let ff = FF.create(2)
  ff = FF.save(ff, 'a', 1, 1).store
  ff = FF.save(ff, 'b', 2, 2).store
  ff = FF.save(ff, 'a', 1, 1).store
  const r = FF.save(ff, 'c', 3, 3)
  eq('FrozenFootprint drops the same entry', FF.keys(r.store), ['a', 'c'])
  eq('and names it as evicted', r.evicted, ['b'])
  // Capacity one: the newest write is the only resident entry in both.
  const one = BC.create(1)
  BC.put(one, 'a', 1)
  BC.put(one, 'b', 2)
  eq('BoundedCache at capacity 1 holds the newest write', BC.keys(one), ['b'])
  let fone = FF.create(1)
  fone = FF.save(fone, 'a', 1, 1).store
  eq('FrozenFootprint at capacity 1 holds the newest write', FF.keys(FF.save(fone, 'b', 2, 2).store), ['b'])
})
group('neither grows past its bound, however long the key loop', () => {
  for (const cap of [1, 2, 4]) {
    const bc = BC.create(cap)
    for (let i = 0; i < 50; i++) BC.put(bc, `k${i}`, i)
    eq(`BoundedCache at capacity ${cap} peaks at the bound`, BC.size(bc), cap)
    eq(`BoundedCache at capacity ${cap} keeps the newest ${cap}`, BC.keys(bc), Array.from({ length: cap }, (_, i) => `k${50 - cap + i}`))
    let ff = FF.create(cap)
    let peak = 0
    for (let i = 0; i < 50; i++) { ff = FF.save(ff, `k${i}`, i + 1, i + 1).store; peak = Math.max(peak, FF.count(ff)) }
    eq(`FrozenFootprint at capacity ${cap} peaks at the bound`, peak, cap)
    eq(`FrozenFootprint at capacity ${cap} keeps the newest ${cap}`, FF.keys(ff), Array.from({ length: cap }, (_, i) => `k${50 - cap + i}`))
  }
})
group('one mutates in place and the other hands back a new store', () => {
  // This is the one difference, and it exists because of what the owner is: a
  // QML property var that a binding reads (BoundedCache) versus one a
  // dependent holds (FrozenFootprint).
  const bc = BC.create(2)
  BC.put(bc, 'a', 1)
  const bcRef = bc
  BC.get(bc, 'a')
  BC.put(bc, 'b', 2)
  BC.clear(bc)
  is('BoundedCache never replaces the map object', bc, (v) => v === bcRef, 'same object')
  let ff = FF.create(2)
  const ffRef = ff
  ff = FF.save(ff, 'a', 1, 1).store
  ne('FrozenFootprint replaces the store on every accepted save', ff, ffRef)
  is('and the previous store is still readable', ffRef, (v) => FF.count(v) === 0 && !FF.has(v, 'a'), 'the empty store it was')
  // The consequence both pay for: neither offers a `count`/`size` a QML
  // binding could read as a property, so both are functions.
  is('BoundedCache reaches its size through a function', bc, (v) => typeof BC.size(v) === 'number' && typeof BC.size === 'function', 'size() is a function')
  is('FrozenFootprint derives its count from the entries', ff, (v) => typeof v.count === 'undefined' && typeof FF.count === 'function', 'no count field, count() is a function')
})
group('a miss reads as an empty answer in both, and neither throws', () => {
  const bc = BC.create(1)
  BC.put(bc, 'a', 1)
  const ff = FF.save(FF.create(1), 'a', 1, 1).store
  eq('BoundedCache reads a miss as undefined', BC.get(bc, 'nope'), undefined)
  eq('BoundedCache answers membership as false', BC.has(bc, 'nope'), false)
  eq('FrozenFootprint reads a miss width as 0', FF.w(ff, 'nope'), 0)
  eq('FrozenFootprint answers membership as false', FF.has(ff, 'nope'), false)
  noThrow('a refused write into BoundedCache', () => BC.put(bc, 'nope', undefined))
  noThrow('a refused write into FrozenFootprint', () => FF.save(ff, 'nope', 0, 0))
  // A refused write leaves the bound alone in both.
  eq('BoundedCache still holds only a', BC.keys(bc), ['a'])
  eq('FrozenFootprint still holds only a', FF.keys(ff), ['a'])
})

// ---------------------------------------------------------------------------
section('ZoneGeometry.slotKey and orderedWidths')
// ---------------------------------------------------------------------------
group('slotKey is kind and id joined by a colon', () => {
  eq('a static slot', ZG.slotKey('static', 'workspaces'), 'static:workspaces')
  eq('an owned indicator', ZG.slotKey('owned', 'tray'), 'owned:tray')
  eq('it is deterministic', ZG.slotKey('static', 'a'), ZG.slotKey('static', 'a'))
  // Header: "Row key: kind and id together, so a kind flip is a distinct row
  // even for the same id."
  ne('a kind flip is a different key', ZG.slotKey('static', 'a'), ZG.slotKey('owned', 'a'))
  eq('an empty id is still a key', ZG.slotKey('static', ''), 'static:')
  eq('an empty kind is still a key', ZG.slotKey('', 'a'), ':a')
  // The join is a bare colon, so a pair is only unambiguous while the kind
  // cannot itself contain a colon. Zone.qml builds kinds from a closed set
  // ("static" / "owned"), so the first segment is always the kind.
  eq('an id containing a colon is kept whole', ZG.slotKey('static', 'a:b'), 'static:a:b')
  eq('and the separator makes the join ambiguous for a colon in the kind', ZG.slotKey('a:b', 'c'), ZG.slotKey('a', 'b:c'))
  is('a real kind set is unambiguous', ['static', 'owned'], (kinds) => kinds.every((k) => !k.includes(':')), 'no colon in a kind')
})
group('orderedWidths reads one width per id, in the supplied order', () => {
  const ids = ['a', 'b', 'c']
  const kinds = ['static', 'owned', 'static']
  const widths = { 'static:a': 10, 'owned:b': 20 }
  eq('a hit, a hit and a miss', ZG.orderedWidths(ids, kinds, widths), [10, 20, 0])
  eq('the order is the id order, not the map order', ZG.orderedWidths(['c', 'b', 'a'], ['static', 'owned', 'static'], widths), [0, 20, 10])
  eq('a kind flip reads its own width', ZG.orderedWidths(['a'], ['owned'], { 'static:a': 10, 'owned:a': 99 }), [99])
  eq('an empty row', ZG.orderedWidths([], [], {}), [])
  eq('one row', ZG.orderedWidths(['a'], ['static'], { 'static:a': 42 }), [42])
  eq('a float width is passed through', ZG.orderedWidths(['a'], ['s'], { 's:a': 1.5 }), [1.5])
  eq('a negative width is passed through', ZG.orderedWidths(['a'], ['s'], { 's:a': -5 }), [-5])
  // Only `undefined` is folded to 0, so a caller that stored null or a string
  // gets it back rather than a silent zero.
  eq('null passes through', ZG.orderedWidths(['a'], ['s'], { 's:a': null }), [null])
  eq('a string passes through', ZG.orderedWidths(['a'], ['s'], { 's:a': '40' }), ['40'])
  eq('an explicit undefined folds to 0', ZG.orderedWidths(['a'], ['s'], { 's:a': undefined }), [0])
})
group('a missing width reads as 0, indistinguishable from a zero width', () => {
  // Header: "0 where the caller's map has no width for that row" - a row
  // whose delegate is not instantiated reads as an unresolved slot, and
  // Zone.qml relies on that by pre-seeding widths[k] = 0 for every member.
  eq('a missing entry', ZG.orderedWidths(['a'], ['s'], {}), [0])
  eq('a present zero', ZG.orderedWidths(['a'], ['s'], { 's:a': 0 }), [0])
  eq('the two are the same array', ZG.orderedWidths(['a'], ['s'], {}), ZG.orderedWidths(['a'], ['s'], { 's:a': 0 }))
  // A width under the wrong kind is a miss, not a cross-kind read.
  eq('the wrong kind is a miss', ZG.orderedWidths(['a'], ['owned'], { 'static:a': 10 }), [0])
})

// ---------------------------------------------------------------------------
section('ZoneGeometry.prefixX and totalWidth')
// ---------------------------------------------------------------------------
group('prefixX is one longer than the row and ends at the total', () => {
  // Header: "entry i is the row x of slot i and the last entry is the row
  // total, so a slot's x is one index read with no accumulation and no second
  // pass."
  eq('an empty row', ZG.prefixX([]), [0])
  eq('one slot', ZG.prefixX([10]), [0, 10])
  eq('three slots', ZG.prefixX([10, 20, 30]), [0, 10, 30, 60])
  eq('four slots', ZG.prefixX([1, 2, 3, 4]).length, 5)
  eq('the first entry is always the origin', ZG.prefixX([7, 7, 7])[0], 0)
  eq('the last entry is the total', ZG.prefixX([10, 20, 30])[3], 60)
  eq('all-zero widths', ZG.prefixX([0, 0]), [0, 0, 0])
  is('an input array is not mutated', (() => { const w = [1, 2]; ZG.prefixX(w); return w })(), (w) => deepEqual(w, [1, 2]), 'unchanged')
})
group('the accumulation is monotonic for a non-negative row', () => {
  for (const widths of [[1], [1, 1], [5, 5, 5, 5, 5, 5, 5, 5], [0, 10, 0, 10], [3, 3, 3]]) {
    const prefix = ZG.prefixX(widths)
    is(`monotonic for ${show(widths)}`, prefix, (p) => p.every((x, i) => i === 0 || x >= p[i - 1]), 'non-decreasing')
  }
  eq('a negative width breaks monotonicity, as a plain sum would', ZG.prefixX([10, -4]), [0, 10, 6])
  is('a NaN width poisons everything after it', ZG.prefixX([NaN, 1]), (p) => p.length === 3 && p[0] === 0 && Number.isNaN(p[1]) && Number.isNaN(p[2]), 'NaN from the first bad entry on')
})
group('totalWidth is the sum, and agrees with the last prefix entry', () => {
  eq('an empty row', ZG.totalWidth([]), 0)
  eq('one slot', ZG.totalWidth([10]), 10)
  eq('three slots', ZG.totalWidth([10, 20, 30]), 60)
  eq('all-zero widths', ZG.totalWidth([0, 0, 0]), 0)
  // Both accumulate left to right over the same array, so the two agree
  // exactly, floats included.
  approx('a float sum', ZG.totalWidth([0.1, 0.2]), 0.3, 1e-9)
  is('the last prefix entry is the total', [0.1, 0.2, 0.3], (ws) => ZG.prefixX(ws)[ws.length] === ZG.totalWidth(ws), 'exactly equal')
  approx('a float prefix total', ZG.prefixX([0.1, 0.2])[2], 0.3, 1e-9)
  is('a NaN width poisons the total too', ZG.totalWidth([1, NaN]), (t) => Number.isNaN(t), 'NaN')
  eq('a negative width subtracts', ZG.totalWidth([10, -4]), 6)
})

// ---------------------------------------------------------------------------
section('ZoneGeometry.rowIndexMap')
// ---------------------------------------------------------------------------
group('rowIndexMap is a null-prototype table of row indices', () => {
  const m = ZG.rowIndexMap(['a', 'b', 'c'])
  is('a null-prototype object', m, (v) => Object.getPrototypeOf(v) === null, 'null prototype')
  eq('built as a plain object it has the same entries', { ...m }, { a: 0, b: 1, c: 2 })
  eq('first row', m.a, 0)
  eq('last row', m.c, 2)
  eq('an absent id is undefined, not -1', m.z, undefined)
  eq('and reports absent-ness through `in`', 'z' in m, false)
  eq('an empty row', ZG.rowIndexMap([]), {})
  eq('a prototype name is an ordinary key', ZG.rowIndexMap(['toString']).toString, 0)
  eq('so a name that was never inserted is absent', ZG.rowIndexMap(['a']).valueOf, undefined)
})
group('a duplicate id keeps its last index in the map', () => {
  // The loop overwrites each key as it goes, so the last occurrence wins.
  // Stable slot ids are unique by construction; pinning the direction keeps a
  // duplicate from reading as a first-wins lookup.
  eq('the last occurrence wins', { ...ZG.rowIndexMap(['a', 'b', 'a']) }, { a: 2, b: 1 })
})

// ---------------------------------------------------------------------------
section('ZoneGeometry.dropCandidates')
// ---------------------------------------------------------------------------
group('one candidate per movable row, in row order', () => {
  const ids = ['a', 'b', 'c']
  const widths = [100, 50, 60]
  const prefix = ZG.prefixX(widths)
  eq('the whole row', ZG.dropCandidates(ids, widths, prefix, ['a', 'b', 'c'], () => false), [
    { x: 0, width: 100, index: 0 },
    { x: 100, width: 50, index: 1 },
    { x: 150, width: 60, index: 2 },
  ])
  eq('one candidate per row', ZG.dropCandidates(ids, widths, prefix, ['a', 'b', 'c'], () => false).length, 3)
  eq('the keys are exactly x, width and index', Object.keys(ZG.dropCandidates(ids, widths, prefix, ['a'], () => false)[0]), ['x', 'width', 'index'])
  eq('an empty row', ZG.dropCandidates([], [], [0], ['a'], () => false), [])
  eq('float geometry is passed through', ZG.dropCandidates(['a', 'b'], [10.5, 20.25], ZG.prefixX([10.5, 20.25]), ['a', 'b'], () => false), [
    { x: 0, width: 10.5, index: 0 },
    { x: 10.5, width: 20.25, index: 1 },
  ])
  // The x of row i is prefixX(widths)[i], so it is the accumulated sum of the
  // rows before it - not the row's own offset within the candidate list.
  const floats = ZG.dropCandidates(['a', 'b', 'c'], [0.1, 0.2, 0.3], ZG.prefixX([0.1, 0.2, 0.3]), ['a', 'b', 'c'], () => false)
  approx('the first row starts at the origin', floats[0].x, 0, 1e-9)
  approx('the second row starts after the first', floats[1].x, 0.1, 1e-9)
  approx('the third row starts after the first two', floats[2].x, 0.3, 1e-9)
  is('and the x values are the prefix entries', floats.map((c) => c.x), (xs) => deepEqual(xs, ZG.prefixX([0.1, 0.2, 0.3]).slice(0, 3)), 'the first three prefix entries')
})
group('a fixed row advances the x without offering a gap', () => {
  // Header: "A row the injected isFixed predicate rejects advances the row x
  // without offering a gap, so a pin wall stays off limits while still
  // occupying its space."
  const ids = ['pin', 'a', 'b']
  const widths = [100, 50, 60]
  const prefix = ZG.prefixX(widths)
  const pinned = ZG.dropCandidates(ids, widths, prefix, ['a', 'b'], (id) => id === 'pin')
  eq('the fixed row is not a candidate', pinned.length, 2)
  eq('and no gap is offered in its place', pinned[0], { x: 100, width: 50, index: 0 })
  eq('the next row keeps its own x', pinned[1], { x: 150, width: 60, index: 1 })
  eq('the fixed row occupies its 100px regardless', prefix[1] - prefix[0], 100)
  eq('and the candidate after it is placed past that space', pinned[0].x, 100)
  eq('every row fixed means no candidates at all', ZG.dropCandidates(ids, widths, prefix, ['a', 'b'], () => true), [])
  // A row is skipped by id, not by position in the work list: a row absent
  // from the work list and not fixed is still offered, with index -1.
  eq('a fixed row absent from the work list is still skipped', ZG.dropCandidates(ids, widths, prefix, ['a'], (id) => id === 'b').map((c) => c.index), [-1, 0])
  eq('and a movable row absent from the work list is offered at -1', ZG.dropCandidates(ids, widths, prefix, ['a'], () => false)[0], { x: 0, width: 100, index: -1 })
})
group('index is the position in the drag working list, -1 when absent', () => {
  const ids = ['a', 'b', 'c']
  const widths = [10, 10, 10]
  const prefix = ZG.prefixX(widths)
  eq('in work list order', ZG.dropCandidates(ids, widths, prefix, ['c', 'b', 'a'], () => false).map((c) => c.index), [2, 1, 0])
  eq('a partially filled list', ZG.dropCandidates(ids, widths, prefix, ['b'], () => false).map((c) => c.index), [-1, 0, -1])
  eq('an empty work list is all -1', ZG.dropCandidates(ids, widths, prefix, [], () => false).map((c) => c.index), [-1, -1, -1])
  eq('no work list at all is all -1', ZG.dropCandidates(ids, widths, prefix, undefined, () => false).map((c) => c.index), [-1, -1, -1])
  eq('the index is the row id matched, not the row position', ZG.dropCandidates(['b', 'a'], [10, 10], ZG.prefixX([10, 10]), ['a', 'b'], () => false).map((c) => c.index), [1, 0])
})
group('only a literal true from isFixed removes a row', () => {
  // `isFixed(ids[i]) === true`, so a predicate written as a truthy expression
  // pins nothing. Pinned because Zone.qml injects Bar.isFixedSlot, and a
  // silent truthy result there would let a drag target a pinned wall.
  const ids = ['a', 'b']
  const widths = [10, 10]
  const prefix = ZG.prefixX(widths)
  eq('true removes', ZG.dropCandidates(ids, widths, prefix, [], () => true).length, 0)
  eq('false removes nothing', ZG.dropCandidates(ids, widths, prefix, [], () => false).length, 2)
  eq('1 is not true', ZG.dropCandidates(ids, widths, prefix, [], () => 1).length, 2)
  eq('a truthy string is not true', ZG.dropCandidates(ids, widths, prefix, [], () => 'yes').length, 2)
  eq('undefined is not true', ZG.dropCandidates(ids, widths, prefix, [], () => undefined).length, 2)
  eq('null is not true', ZG.dropCandidates(ids, widths, prefix, [], () => null).length, 2)
})
group('the predicate receives the row id, and the inputs are not touched', () => {
  const ids = ['a', 'b', 'c']
  const widths = [10, 20, 30]
  const prefix = ZG.prefixX(widths)
  const workIds = ['b', 'a']
  const seen = []
  ZG.dropCandidates(ids, widths, prefix, workIds, (id) => { seen.push(id); return false })
  eq('called once per row, in row order', seen, ids)
  eq('the id array is unchanged', ids, ['a', 'b', 'c'])
  eq('the width array is unchanged', widths, [10, 20, 30])
  eq('the work list is unchanged', workIds, ['b', 'a'])
  // A missing predicate is a caller error, not a silent "nothing is fixed".
  throws('dropCandidates without a predicate', () => ZG.dropCandidates(ids, widths, prefix, workIds), /isFixed/)
})

// ---------------------------------------------------------------------------
section('ZoneGeometry.invalidationSig')
// ---------------------------------------------------------------------------
group('the signature covers membership, widths, grows and the drag revision', () => {
  const ids = ['a', 'b']
  const kinds = ['static', 'owned']
  const widths = { 'static:a': 10, 'owned:b': 20 }
  const grows = { 'static:a': 1, 'owned:b': 2 }
  eq('the shape', ZG.invalidationSig(ids, kinds, widths, grows, 7), 'static:a=10@1;owned:b=20@2;#7')
  eq('it is deterministic', ZG.invalidationSig(ids, kinds, widths, grows, 7), ZG.invalidationSig(ids, kinds, widths, grows, 7))
  eq('a new drag revision changes it', ZG.invalidationSig(ids, kinds, widths, grows, 8), 'static:a=10@1;owned:b=20@2;#8')
  eq('a changed width changes it', ZG.invalidationSig(ids, kinds, { 'static:a': 11, 'owned:b': 20 }, grows, 7), 'static:a=11@1;owned:b=20@2;#7')
  eq('a changed grow changes it', ZG.invalidationSig(ids, kinds, widths, { 'static:a': 1, 'owned:b': 3 }, 7), 'static:a=10@1;owned:b=20@3;#7')
  eq('a reorder changes it', ZG.invalidationSig(['b', 'a'], ['owned', 'static'], widths, grows, 7), 'owned:b=20@2;static:a=10@1;#7')
  eq('a dropped member changes it', ZG.invalidationSig(['a'], ['static'], widths, grows, 7), 'static:a=10@1;#7')
  eq('a kind flip on the same id changes it', ZG.invalidationSig(['a'], ['owned'], widths, grows, 7), 'owned:a=undefined@undefined;#7')
  eq('a fractional width is stringified as written', ZG.invalidationSig(['a'], ['s'], { 's:a': 1.5 }, { 's:a': 1 }, 0), 's:a=1.5@1;#0')
})
group('it covers nothing else, so an unrelated write leaves it identical', () => {
  // Header: "A geometry revision may key on nothing else, so an unrelated
  // settings write leaves the signature identical and the caller keeps its
  // cached row."
  const ids = ['a']
  const kinds = ['static']
  const widths = { 'static:a': 10 }
  const grows = { 'static:a': 1 }
  eq('extra entries in the width map are ignored', ZG.invalidationSig(ids, kinds, { 'static:a': 10, 'static:other': 99 }, grows, 0), ZG.invalidationSig(ids, kinds, widths, grows, 0))
  eq('extra entries in the grow map are ignored', ZG.invalidationSig(ids, kinds, widths, { 'static:a': 1, 'static:other': 9 }, 0), ZG.invalidationSig(ids, kinds, widths, grows, 0))
  eq('a dropped member changes it', ZG.invalidationSig(['a', 'b'], ['static', 'static'], widths, grows, 0), 'static:a=10@1;static:b=undefined@undefined;#0')
  eq('the result is a plain string', typeof ZG.invalidationSig(ids, kinds, widths, grows, 0), 'string')
  // Two ids whose strings concatenate the same way still separate, because
  // every element ends with its own ';'.
  is('adjacent members cannot run together', [
    ZG.invalidationSig(['a', 'b'], ['s', 's'], { 's:a': 1, 's:b': 2 }, { 's:a': 1, 's:b': 2 }, 0),
    ZG.invalidationSig(['a;b'], ['s'], { 's:a;b': 1 }, { 's:a;b': 1 }, 0),
  ], (sigs) => sigs[0] !== sigs[1], 'distinct')
})
group('a row whose width or grow is not in the map is still tracked', () => {
  // A missing entry stringifies as "undefined" rather than being skipped, so
  // a row that gains a width later produces a different signature and the
  // caller rebuilds. That is the whole reason a width may be absent at all.
  eq('both missing', ZG.invalidationSig(['z'], ['static'], {}, {}, 0), 'static:z=undefined@undefined;#0')
  eq('a missing width is not a zero width', ZG.invalidationSig(['a'], ['s'], {}, { 's:a': 1 }, 0), 's:a=undefined@1;#0')
  eq('a present zero is a different signature', ZG.invalidationSig(['a'], ['s'], { 's:a': 0 }, { 's:a': 1 }, 0), 's:a=0@1;#0')
  eq('a width that appears later changes the signature', ZG.invalidationSig(['a'], ['s'], {}, { 's:a': 1 }, 0) === ZG.invalidationSig(['a'], ['s'], { 's:a': 10 }, { 's:a': 1 }, 0), false)
})
group('the empty row and a missing drag revision are still distinct strings', () => {
  eq('an empty row', ZG.invalidationSig([], [], {}, {}, 3), '#3')
  eq('an undefined drag revision', ZG.invalidationSig([], [], {}, {}, undefined), '#undefined')
  eq('a null drag revision', ZG.invalidationSig([], [], {}, {}, null), '#null')
  eq('revision 0 is not the empty string', ZG.invalidationSig([], [], {}, {}, 0), '#0')
  ne('so 0 and undefined are different', ZG.invalidationSig([], [], {}, {}, 0), ZG.invalidationSig([], [], {}, {}, undefined))
  eq('a null id entry is read as the string "null"', ZG.invalidationSig([null], ['s'], {}, {}, 0), 's:null=undefined@undefined;#0')
})
group('the geometry functions require the caller\'s real arrays and maps', () => {
  // ZoneGeometry is the one library here that guards nothing: the header
  // describes what the caller supplies, and Zone.qml always supplies real
  // arrays and objects. Pinned so "why does this throw" has an answer in the
  // suite rather than only in review.
  throws('invalidationSig with a null width map', () => ZG.invalidationSig(['a'], ['s'], null, {}, 0), /'s:a'/)
  throws('invalidationSig with a null grow map', () => ZG.invalidationSig(['a'], ['s'], {}, null, 0), /'s:a'/)
  throws('invalidationSig with a null kind array', () => ZG.invalidationSig(['a'], null, {}, {}, 0), /'0'/)
  throws('orderedWidths with a null width map', () => ZG.orderedWidths(['a'], ['s'], null), /'s:a'/)
  throws('prefixX with a null array', () => ZG.prefixX(null), /length/)
  throws('totalWidth with a null array', () => ZG.totalWidth(null), /length/)
  throws('rowIndexMap with a null id array', () => ZG.rowIndexMap(null), /length/)
  // A missing isFixed is the same class of caller error, already pinned in the
  // dropCandidates group above.
  noThrow('an empty row through every function', () => {
    ZG.invalidationSig([], [], {}, {}, 0)
    ZG.orderedWidths([], [], {})
    ZG.prefixX([])
    ZG.totalWidth([])
    ZG.rowIndexMap([])
    ZG.dropCandidates([], [], [0], [], () => false)
  })
})

// ---------------------------------------------------------------------------
section('Documented drift in this directory')
// ---------------------------------------------------------------------------
group('FrozenFootprint.js carries a .pragma library line', () => {
  // README, "Known drift": the file's own header and IslandHost.qml's import
  // comment both describe it as a `.pragma library`, and there is no such
  // line in it. Nothing fails today - IslandHost.qml imports it as a plain
  // script and the node harness strips the pragma whether or not it is there
  // - but a `.pragma library` exposes every top-level function to importers
  // while a plain script is evaluated as a component, so the "_capacityOf /
  // _trim are internal alongside the public surface" comments are only true
  // once the pragma is added.
  //
  // Pinned as the *absence*, so adding the pragma - the direction the README
  // calls safe - fails here and has to be a deliberate change rather than a
  // silent one.
  const frozen = fs.readFileSync(SRC('FrozenFootprint.js'), 'utf8')
  match('FrozenFootprint.js has no .pragma library', frozen, /^[ \t]*\.pragma[ \t]+library/m)
  contains('its header still calls itself pure JS with no Qt imports', frozen, 'no Qt imports')
  contains('its header still names the .js test harness', frozen, 'tests/shell/suites/js/collections.test.mjs')
  for (const [label, name] of [['BoundedCache.js', 'BoundedCache.js'], ['ZoneGeometry.js', 'ZoneGeometry.js']]) {
    match(`${label} does carry a .pragma library`, fs.readFileSync(SRC(name), 'utf8'), /^[ \t]*\.pragma[ \t]+library/m)
  }
})
group('behaviour that needs a QML engine, not a node harness', () => {
  // Recorded rather than asserted, so the coverage gap is visible in the
  // total instead of being implied by silence.
  skip('BoundedCache in-place writes do not re-enter a QML binding', 'needs a QML engine: the reason the map mutates in place is that Icons.url() writes into it from inside a binding')
  skip('FrozenFootprint store swaps are observed by a dependent holding a property var', 'needs a QML engine: the reason every save returns a new store is that a Slot.x-style dependent must re-read it')
  skip('ZoneGeometry output drives a real row layout', 'needs a scene: the drop-candidate x values are consumed by a drop-target chooser in Zone.qml')
})

finish()
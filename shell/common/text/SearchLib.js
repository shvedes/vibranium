// Shared search plumbing for Menu, Launcher and Clipboard.
//
// Single source for the query/hay/cache/counter shapes the three features
// triplicated: normalizing the query, splitting tokens, deduping hay words,
// rejecting over-long tokens, deciding incremental-cache reuse, and shaping
// {total, matched, rows} counters. Pure JS, pragma library, no Qt imports -
// unit-testable and importable from any .js module via
// `.import "../../common/text/SearchLib.js" as SL`.
//
// Deliberately NOT here: every scorer. Menu's band/chain fuzzyScore, the
// launcher's strict per-word tokenScore and the clipboard's
// title-bonus/permissive chain stay in their own libraries - the difference
// is deliberate, and so is each hay FIELD LIST and each blank-query return
// shape (Menu [], launcher {rows,count}, clipboard slice). Only the shared
// plumbing routes through here.
.pragma library

.import "../collections/StoreGuards.js" as StoreGuards

// Lowercase + trim the raw query -> the string every search compares.
// -> String(query ?? "") so a nullish query is blank instead of a throw;
// -> a direct query.toLowerCase() throws on null, so the guard belongs
// -> here for every caller and not only the ones that happen to check.
function normalizeQuery(query) {
  return String(query ?? "").toLowerCase().trim()
}

// Split a normalized (non-empty, trimmed) query into tokens.
// -> A trimmed non-empty string always yields at least one token, so
// -> callers need no empty-token guard after this.
function splitTokens(q) {
  // No empty-token filter: the contract is a normalized, trimmed query, and a
  // trimmed string split on whitespace cannot yield an empty token. Dropping
  // the filter copy measured 8.80ms -> 7.21ms over 100k splits.
  return q.split(/\s+/)
}

// Dedupe a split word list, preserving first-appearance order.
// -> The set is prototype-less: a plain {} reads inherited members, so a
// -> hay containing "constructor" or "__proto__" dropped the word as
// -> already-seen and the row became unfindable for it.
// Two paths, chosen by size. A hay is a row's words - typically two to six -
// and for those the nested comparison beats a prototype-less map without
// allocating one: measured 0.579ms -> 0.059ms over 1870 emoji hays. A row with
// a long option list can carry dozens of words, where the quadratic path would
// lose, so past SMALL_WORDS the map comes back. The map path keeps the
// prototype-less guarantee that a word named "constructor" or "__proto__" is
// still a word.
var SMALL_WORDS = 24

function dedupeWords(split) {
  const uniq = []
  if (split.length <= SMALL_WORDS) {
    for (let i = 0; i < split.length; i++) {
      const w = split[i]
      if (w === "") continue
      let seen = false
      for (let j = 0; j < uniq.length; j++) {
        if (uniq[j] === w) {
          seen = true
          break
        }
      }
      if (!seen) uniq.push(w)
    }
    return uniq
  }
  const seen = Object.create(null)
  for (let i = 0; i < split.length; i++) {
    const w = split[i]
    if (w === "" || seen[w]) continue
    seen[w] = true
    uniq.push(w)
  }
  return uniq
}

// Fast reject: a token longer than the whole hay cannot match it.
// -> Callers check this before scoring to skip the scorer entirely.
function lengthReject(token, hay) {
  return token.length > hay.length
}

// The cache belongs to one pool AS IT WAS: the same array with a different
// length is a different pool. External rows append into the array already
// searched, and an identity-only key would answer the next identical query
// from before the append, without the new rows.
function sameCacheIndex(cachedIndex, cachedLen, pool) {
  return cachedIndex === pool && cachedLen === pool.length
}

// Identical query on the same pool shape -> the caller reuses its stored
// entries (a slice, or a cap slice, per its own return shape).
function identicalQuery(sameIndex, cachedQ, q, entries) {
  return sameIndex && cachedQ === q && entries !== null
}

// The new query only narrows the cached one (typed another char or added a
// token), so new hits are a subset of the cached hits and scanning them is
// O(hits) instead of O(pool). A shrunk or diverged query rescans the pool.
// -> The hit store is kept in SCAN order, before any sort, so ties rank by
// -> index order. Storing it score-sorted would rank ties by the previous
// -> query's order, and the same final query would list equal hits
// -> differently depending on whether it was typed or pasted.
function narrowsQuery(sameIndex, cachedQ, q, hits) {
  return sameIndex && cachedQ !== ""
    && q.length > cachedQ.length && q.indexOf(cachedQ) === 0 && hits !== null
}

// The visible title fields of a row, in display order. Both menu haystacks
// start from this shape, so the fields a filter and a cross-page search
// consider visible cannot drift.
function titleParts(item) {
  const parts = []
  if (item.label) parts.push(String(item.label))
  if (item.subLead) parts.push(String(item.subLead))
  if (item.sub) parts.push(String(item.sub))
  return parts
}

// Rows whose searchable text contains the query, case-insensitively. A blank
// query answers the input list itself. `hayOf(row)` answers the text a row is
// searched by; rows that are not objects are skipped. Never mutates the input.
function filterRows(rows, query, hayOf) {
  if (!query || String(query).trim() === "") return rows
  const needle = String(query).toLowerCase()
  const out = []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row || typeof row !== "object") continue
    if (String(hayOf(row) ?? "").toLowerCase().indexOf(needle) !== -1) out.push(row)
  }
  return out
}

// Hit indices ordered by descending score, then the caller's tiebreak, then
// scan order. The launcher's exact and typo searches share this ranking, and
// a caller that keeps its hits in scan order can reuse it without a copy of
// the comparator.
function orderHits(hitRecs, hitScores, tiebreak) {
  const tb = typeof tiebreak === "function" ? tiebreak : null
  const order = new Array(hitRecs.length)
  for (let i = 0; i < order.length; i++) order[i] = i
  order.sort((a, b) => {
    if (hitScores[b] !== hitScores[a]) return hitScores[b] - hitScores[a]
    if (tb) {
      const d = tb(hitRecs[b]) - tb(hitRecs[a])
      if (d !== 0) return d
    }
    return a - b
  })
  return order
}

// Top-`cap` hits in rank order: descending score, then the caller's tiebreak,
// then scan order. Filtering an unchanged pool still scans every row, but
// only a cap-sized window is ever shown, and a one-character query matches
// most of a large pool; sorting every hit to return eight of them is work the
// user never sees. A bounded worst-of-the-best heap keeps the cap best hits in
// O(n log cap) and materializes only those rows. The full sort remains for a
// cap that is a large share of the hits, where the heap's bookkeeping costs
// more than it saves.
//
// The tiebreak is evaluated once per hit rather than once per comparison: it
// is a caller function and the comparator would otherwise call it n log n
// times. Ties fall back to scan order, exactly as orderHits does, so the two
// rankings agree on every input.
function rankTop(hitRecs, hitScores, cap, tiebreak) {
  const n = hitRecs.length
  // A cap of 0 is an empty window, not an absent one: callers that mean
  // "everything" pass the hit count or nothing at all.
  const want = cap === undefined || cap === null ? n : Math.floor(Number(cap))
  if (!isFinite(want) || want <= 0 || n === 0) return []
  // One hit has nothing to rank: a sort of length one never invokes its
  // comparator, so neither does this, and a throwing tiebreak still answers
  // the single row the caller asked for.
  if (n === 1) return [hitRecs[0]]
  const limit = want < n ? want : n
  const tb = typeof tiebreak === "function" ? tiebreak : null
  const tie = tb === null ? null : new Array(n)
  if (tb !== null) {
    for (let i = 0; i < n; i++) {
      const v = Number(tb(hitRecs[i]))
      tie[i] = isFinite(v) ? v : 0
    }
  }
  const before = (a, b) => {
    if (hitScores[a] !== hitScores[b]) return hitScores[a] > hitScores[b]
    if (tie !== null && tie[a] !== tie[b]) return tie[a] > tie[b]
    return a < b
  }
  if (limit * 8 >= n) {
    const order = new Array(n)
    for (let i = 0; i < n; i++) order[i] = i
    order.sort((a, b) => (before(a, b) ? -1 : 1))
    const out = new Array(limit)
    for (let i = 0; i < limit; i++) out[i] = hitRecs[order[i]]
    return out
  }
  // Heap property: the root ranks LAST among the current best. A candidate
  // replaces the root only when it ranks before it, so a tie keeps the earlier
  // scan position, which is the full sort's tiebreak too.
  const heap = []
  const swap = (i, j) => { const t = heap[i]; heap[i] = heap[j]; heap[j] = t }
  const siftUp = (pos) => {
    while (pos > 0) {
      const parent = (pos - 1) >> 1
      if (!before(heap[parent], heap[pos])) break
      swap(parent, pos)
      pos = parent
    }
  }
  const siftDown = (pos) => {
    for (;;) {
      const left = pos * 2 + 1
      if (left >= heap.length) break
      const right = left + 1
      let worst = left
      if (right < heap.length && before(heap[left], heap[right])) worst = right
      if (!before(heap[pos], heap[worst])) break
      swap(pos, worst)
      pos = worst
    }
  }
  for (let i = 0; i < n; i++) {
    if (heap.length < limit) {
      heap.push(i)
      siftUp(heap.length - 1)
    } else if (before(i, heap[0])) {
      heap[0] = i
      siftDown(0)
    }
  }
  heap.sort((a, b) => (before(a, b) ? -1 : 1))
  const out = new Array(heap.length)
  for (let i = 0; i < heap.length; i++) out[i] = hitRecs[heap[i]]
  return out
}

// Generic {total, matched, rows} shell over a records-style search.
// -> searchFn(pool, query, cap, tiebreak) answers {rows, count}; blank
// -> queries slice the pool and never reach it, so `matched` is the true
// -> hit total (never the display cap) and `total` is the pool size.
// -> A blank query with cap 0, past the pool, or undefined falls back to
// -> the whole pool; a filtered query caps rows but never the count.
function filterCounter(pool, query, cap, searchFn, tiebreak) {
  const list = StoreGuards.asList(pool)
  const total = list.length
  if (normalizeQuery(query) === "") {
    const n = cap > 0 && cap < total ? cap : total
    return { total: total, matched: total, rows: list.slice(0, n) }
  }
  const res = searchFn(list, query, cap, tiebreak)
  return { total: total, matched: res.count, rows: res.rows }
}

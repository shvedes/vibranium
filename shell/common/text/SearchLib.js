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
//
// `tiebreakFirst` swaps those two keys: the tiebreak leads and the score
// only separates rows that tie on it. The launcher asks for that in
// frequency mode, where "most used" is the user's chosen order and relevance
// is the fallback among equally-used apps. Without it the score always wins,
// which is the default every other caller wants.
function orderHits(hitRecs, hitScores, tiebreak, tiebreakFirst) {
  const tb = typeof tiebreak === "function" ? tiebreak : null
  const tbFirst = tb !== null && tiebreakFirst === true
  const order = new Array(hitRecs.length)
  for (let i = 0; i < order.length; i++) order[i] = i
  order.sort((a, b) => {
    if (tbFirst) {
      const d = tb(hitRecs[b]) - tb(hitRecs[a])
      if (d !== 0) return d
    }
    if (hitScores[b] !== hitScores[a]) return hitScores[b] - hitScores[a]
    if (tb && !tbFirst) {
      const d = tb(hitRecs[b]) - tb(hitRecs[a])
      if (d !== 0) return d
    }
    return a - b
  })
  return order
}

// Generic {total, matched, rows} shell over a records-style search.
// -> searchFn(pool, query, cap, tiebreak, tiebreakFirst) answers
// -> {rows, count}; blank queries slice the pool and never reach it, so
// -> `matched` is the true hit total (never the display cap) and `total` is
// -> the pool size. A blank query with cap 0, past the pool, or undefined
// -> falls back to the whole pool; a filtered query caps rows but never the
// -> count.
function filterCounter(pool, query, cap, searchFn, tiebreak, tiebreakFirst) {
  const list = StoreGuards.asList(pool)
  const total = list.length
  if (normalizeQuery(query) === "") {
    const n = cap > 0 && cap < total ? cap : total
    // An uncapped blank query answers the pool itself: every caller opens on
    // this path (an empty search box), and the slice copied a whole result
    // pool per open to hand back the same entries. A capped one still slices.
    return { total: total, matched: total, rows: n === total ? list : list.slice(0, n) }
  }
  const res = searchFn(list, query, cap, tiebreak, tiebreakFirst)
  return { total: total, matched: res.count, rows: res.rows }
}

// --- strict records matcher ---
//
// The tokenized AND-search over records whose hay is a pre-split `words`
// array: the launcher's app index, the menu's page lists, the power menu.
//
// It lives here rather than in LauncherLib because the menu needs THIS
// matcher and nothing else from that library - and LauncherLib imports
// ClipboardLib for its file-icon mapping, so the menu's load graph used to
// carry both whole libraries (~3.7k lines) to reach one scoring loop. A
// matcher is search plumbing, which is what this file is for; the launcher
// keeps a named delegate so its own callers and suite do not move.

// Score ONE query token against a record's pre-split words. Word-level
// matching only: a token hits a word by exact equality, word-start prefix,
// or contained substring. The menu's cross-word letter-chain matcher is
// deliberately NOT used here - over thousands of desktop entries it
// fabricates matches ("calculator" -> "C"hromium + "a"...), and a launcher
// needs precision more than acronym cleverness.
//
// Earlier position ranks higher so header-ish words win ties.
function tokenScore(words, t) {
  for (let w = 0; w < words.length; w++) {
    const word = words[w]
    if (word === t) return 3000 - w
    // One scan, not two. `startsWith` and the contained-substring test both
      // searched the word, and for the common case - a word the token is not
      // in - the prefix probe found out in three characters and the substring
      // scan still walked the whole word. indexOf answers both questions: 0 is
      // the prefix band, >0 the contained band.
    const idx = word.indexOf(t)
    if (idx === 0) return 2000 - w * 10
    if (idx > 0) return 1000 - idx * 10
  }
  return -1
}

// Incremental cache: sequential typing ("f" -> "fi" -> "fir"...) is the
// common case. When the new query is a string-prefix of the previous one on
// the SAME records instance, new hits are a subset of previous hits - scan
// only that subset (typically <10 items) instead of the full index.
// Invalidated on records identity change (re-index) or query shrink/diverge.
//
// One cache, because there is one matcher: the launcher and the menu both
// reach it through this module, and pool identity + length is the whole
// validity test (see sameCacheIndex), so a hit list from one pool can never
// be scanned for another.
var _searchCacheRecords = null
var _searchCacheLen = -1
var _searchCacheQ = ""
var _searchCacheHits = null
var _searchCacheSorted = null
var _searchCacheTbFirst = false

// Tokenized AND-search over a records array (app index or keyword list):
// every space-separated token must hit its own best word; totals decide
// ranking. Returns { rows, count }: `rows` is the scored-sorted top
// `cap` (the display cap), `count` the full hit total for the
// matched/total counter. The whole hit set is never copied per
// keystroke - `cap` bounds both work and allocation.
//
// `tiebreak` is an optional rec -> number key (higher wins). The launcher
// passes its druncache counts when the sort method is "frequency", so
// filtering follows the idle view's order. With `tiebreakFirst` that key is
// the primary order and the score breaks ties; without it the score leads
// and the tiebreak only separates equal scores. Records still tied after
// both keep input order (source index), which keeps results deterministic
// even on engines without a stable sort.
function searchRecords(records, query, cap, tiebreak, tiebreakFirst) {
  const q = normalizeQuery(query)
  const tbFirst = tiebreakFirst === true
  if (q === "") {
    _searchCacheRecords = records
    _searchCacheLen = Array.isArray(records) ? records.length : -1
    _searchCacheQ = ""
    _searchCacheHits = []
    _searchCacheSorted = []
    _searchCacheTbFirst = tbFirst
    return { rows: [], count: 0 }
  }
  // The ranking mode is part of the cache key: the same pool and query under
  // a different primary key is a different answer, not a cache hit.
  const sameRecords = sameCacheIndex(_searchCacheRecords, _searchCacheLen, records)
    && _searchCacheTbFirst === tbFirst
  if (identicalQuery(sameRecords, _searchCacheQ, q, _searchCacheSorted)) {
    return { rows: _searchCacheSorted.slice(0, cap), count: _searchCacheSorted.length }
  }
  const tokens = splitTokens(q)
  let source = records
  // Scan the cached hits instead of the pool when the query grew as a string
  // prefix AND the pool is the same array instance those hits were scored
  // from: a longer query matches a subset of what a shorter one matched, so
  // the pool behind the new hits IS the previous query's hit list.
  //
  // Pool identity is the whole test. This cache is module-level and three
  // surfaces reach it - the launcher, the menu's filterCounter forwarder, the
  // power menu - so a hit list can belong to a pool other than the one in hand,
  // and one record the two pools share is no evidence about the rest of either:
  // a scan that reused it would filter this pool by matches found elsewhere.
  // Every caller holds its own array between keystrokes (an app index, an
  // action pool), so identity is exact and cheap; a caller that rebuilds its
  // pool per keystroke scans in full, the same answer at the full-pool price.
  if (narrowsQuery(sameRecords, _searchCacheQ, q, _searchCacheHits)) source = _searchCacheHits
  // Parallel arrays: one {rec, score, idx} per hit was thousands of objects
  // per keypress on a one-letter query. The scan position is the push index.
  const hitRecs = []
  const hitScores = []
  for (let i = 0; i < source.length; i++) {
    const rec = source[i]
    let total = 0
    let ok = true
    for (let t = 0; t < tokens.length && ok; t++) {
      const s = tokenScore(rec.words, tokens[t])
      if (s < 0) ok = false
      else total += s
    }
    if (ok) {
      hitRecs.push(rec)
      hitScores.push(total)
    }
  }
  // Cache the FULL hit set (pre-cap) for incremental filtering; callers
  // cap via slice, so we keep canonical hits untruncated for the next pass.
  // -> Two stores: scan-order for the subset scan, sorted for identical-query
  // -> cap slices. The scan-order copy is taken before the sort, the way the
  // -> menu keeps its hit set, so ties rank by pool order either way.
  const hits = hitRecs
  const order = orderHits(hitRecs, hitScores, tiebreak, tbFirst)
  const full = new Array(order.length)
  for (let i = 0; i < order.length; i++) full[i] = hitRecs[order[i]]
  _searchCacheRecords = records
  _searchCacheLen = records.length
  _searchCacheQ = q
  _searchCacheHits = hits
  _searchCacheSorted = full
  _searchCacheTbFirst = tbFirst
  const n = Math.min(full.length, cap)
  const out = new Array(n)
  for (let i = 0; i < n; i++) out[i] = full[i]
  return { rows: out, count: full.length }
}

// The counter over that matcher: the shape every caller wants without
// passing the scorer by hand.
function filterRecords(pool, query, cap, tiebreak, tiebreakFirst) {
  return filterCounter(pool, query, cap, searchRecords, tiebreak, tiebreakFirst)
}

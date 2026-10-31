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
  return q.split(/\s+/).filter(t => t !== "")
}

// Dedupe a split word list, preserving first-appearance order.
// -> The set is prototype-less: a plain {} reads inherited members, so a
// -> hay containing "constructor" or "__proto__" dropped the word as
// -> already-seen and the row became unfindable for it.
function dedupeWords(split) {
  const seen = Object.create(null)
  const uniq = []
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

// Generic {total, matched, rows} shell over a records-style search.
// -> searchFn(pool, query, cap, tiebreak) answers {rows, count}; blank
// -> queries slice the pool and never reach it, so `matched` is the true
// -> hit total (never the display cap) and `total` is the pool size.
// -> A blank query with cap 0, past the pool, or undefined falls back to
// -> the whole pool; a filtered query caps rows but never the count.
function filterCounter(pool, query, cap, searchFn, tiebreak) {
  const list = Array.isArray(pool) ? pool : []
  const total = list.length
  if (normalizeQuery(query) === "") {
    const n = cap > 0 && cap < total ? cap : total
    return { total: total, matched: total, rows: list.slice(0, n) }
  }
  const res = searchFn(list, query, cap, tiebreak)
  return { total: total, matched: res.count, rows: res.rows }
}

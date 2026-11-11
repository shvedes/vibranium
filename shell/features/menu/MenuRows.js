.pragma library

// Row-set identity, as pure functions over plain arrays.
//
// The panel owns the cursor and the rule for which row may hold it, so both
// arrive as parameters; nothing here reads a QML property or a singleton. The
// three questions are the ones the card asks around a model write: is this the
// very same row set, does the row under the cursor survive into the next one,
// and where should the cursor land when the row count changed.

// True when `next` holds the very same row objects, in order, as `current`.
// Same uids alone are not enough to skip: a container rebuild mints fresh
// objects (payloads refreshed), and only the model write hands those to the
// delegates. Same references mean there is literally nothing to publish - and
// reassigning the array anyway resets the native view, whose cursor adjustment
// paints one wrong frame with the highlight gliding there and back.
function sameRecords(current, next) {
  if (!Array.isArray(current) || !Array.isArray(next)
    || current.length !== next.length) return false
  for (let i = 0; i < current.length; i++) {
    if (current[i] !== next[i]) return false
  }
  return true
}

// The uid sequence a row set is identified by. NUL is the separator because
// uidKey strips every control character out of an item id and a page id, so a
// row uid cannot hold one and the join cannot forge a boundary between rows.
// The panel memoizes this on the array identity; the fold itself is pure.
function keySeq(rows) {
  const pool = Array.isArray(rows) ? rows : []
  const keys = new Array(pool.length)
  for (let i = 0; i < pool.length; i++) {
    const item = pool[i]
    keys[i] = String(item && item.uid !== undefined && item.uid !== null
      ? item.uid : "")
  }
  return keys.join("\u0000")
}

// The row set a keyed model may install, or the refusal code that says why it
// may not. Four rows in and four rows out is not an install a height table can
// absorb when two of them share one identity: List refuses to measure either,
// prunes both and raises identityError, so a duplicate has to be refused at
// this boundary rather than handed on. The codes are the keyed-model validate
// vocabulary; `rows` is a fresh array holding the caller's own row objects,
// which is what makes the install observable.
function setGuard(candidate) {
  if (!Array.isArray(candidate)) return { rows: null, error: "not_array" }
  const rows = new Array(candidate.length)
  const seen = Object.create(null)
  for (let i = 0; i < candidate.length; i++) {
    const item = candidate[i]
    if (!item || item.uid === undefined || item.uid === null)
      return { rows: null, error: "invalid_row" }
    const key = String(item.uid)
    if (key.trim() === "") return { rows: null, error: "missing_key" }
    if (seen[key] !== undefined) return { rows: null, error: "duplicate_key" }
    seen[key] = true
    rows[i] = item
  }
  return { rows: rows, error: "" }
}

// Where the cursor belongs in `next`, given where it was in `current`.
//
// The row is named by its uid in the payload, never by asking the view: the
// view still holds the row set being replaced, so an identity lookup through
// it answers with the row that inherited the old index - in a menu, a
// separator. When that row is gone (a Delete on the row under the cursor) the
// answer is the nearest row that can hold a cursor: forward from the old
// index, else backward, so the cursor never parks on a separator or on the Add
// row. `isSelectable(index)` answers for `next`, which is the set landing.
// -1 means there is no row to put it on.
function cursorIndexAfter(current, fromIndex, next, isSelectable) {
  if (!Array.isArray(next) || next.length === 0) return -1
  if (fromIndex >= 0 && Array.isArray(current)) {
    const was = current[fromIndex]
    const uid = was ? was.uid : null
    if (uid !== null && uid !== undefined) {
      for (let i = 0; i < next.length; i++) {
        if (next[i].uid === uid) return i
      }
    }
  }
  const from = Math.min(Math.max(fromIndex, 0), next.length - 1)
  for (let i = from; i < next.length; i++) {
    if (isSelectable(i)) return i
  }
  for (let i = from - 1; i >= 0; i--) {
    if (isSelectable(i)) return i
  }
  return -1
}

// Whether the row under the cursor (index `at` in `current`) is still in
// `next`. Looked up by uid in the payload, never in the view: the view has not
// adopted the new set yet, so a lookup there answers with whatever row
// inherited the index.
function cursorSurvives(current, at, next) {
  if (at < 0 || !Array.isArray(current)) return false
  const was = current[at]
  const uid = was ? was.uid : null
  if (uid === null || uid === undefined) return false
  const rows = Array.isArray(next) ? next : []
  for (let i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].uid === uid) return true
  }
  return false
}

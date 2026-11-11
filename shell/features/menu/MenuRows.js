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

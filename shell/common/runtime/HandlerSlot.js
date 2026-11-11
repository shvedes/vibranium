// The claim rules for a single-handler slot.
//
// Several action surfaces hold one caller at a time in a QML `property var`:
// the capture actions, the session actions and the page host. The property
// itself must be assigned by the QML owner so bindings observe the swap, but
// the two rules around the assignment are the same everywhere - a claimant is
// a function, and a slot already held by a different claimant refuses the new
// one instead of silently replacing it. State them once.
//
// Pure JS, pragma library, no Qt imports.
.pragma library

// Whether `handler` may take a slot currently holding `current`. An empty slot
// accepts any function; a slot held by the same function accepts it again,
// which is what a view re-adopting on reload does.
function canAdopt(current, handler) {
  if (typeof handler !== "function") return false
  return current === null || current === undefined || current === handler
}

// Whether `handler` is the one that may give the slot back. A different
// claimant, an empty slot and a non-function all answer false, so a stale view
// cannot clear a live one.
function canRelease(current, handler) {
  return current === handler
}

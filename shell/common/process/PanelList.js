.pragma library

.import "../collections/StoreGuards.js" as StoreGuards

// The panel registry every panel-owning singleton keeps: a list of live panel
// instances that the singleton walks when it has news for them (selection
// repair after a delete, keyboard focus truth, delete confirmations).
//
// The list is stored as a QML `property var`, so it can only be mutated by
// reassignment - a plain push would not notify bindings. Both functions
// therefore return a NEW array and leave their input untouched, which is also
// what makes them safe to unit-test without an engine.
//
// The rules are the ones the four copies already applied: attach appends
// (two attachments of the same panel are two entries, because the caller's
// lifecycle decides when it detaches), detach removes every entry identical to
// the one given. A missing or non-array list is treated as empty rather than
// throwing into a Component.onDestruction handler.

// Append `panel` to `list` and return a new array.
function attach(list, panel) {
  var next = StoreGuards.copyList(list)
  next.push(panel)
  return next
}

// Remove every entry identical to `panel` from `list` and return the rest.
function detach(list, panel) {
  if (!Array.isArray(list)) return []
  return list.filter(function (entry) { return entry !== panel })
}

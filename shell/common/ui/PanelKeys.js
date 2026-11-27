.pragma library

// The key -> route table the four list panels share: launcher, clipboard,
// pass and wallpaper picker.
//
// WHY IT EXISTS. Each panel's key handler carried its own switch over the same
// keys, and they had already drifted - the wallpaper picker listed Delete in a
// branch that could never run, because the delete key was handled above it.
// The mapping is the part that must not drift: Down, Tab and PageDown are all
// "next row", Up, Backtab and PageUp are all "previous row", Home/End are the
// ends, Return/Enter activate, Backspace is "back". What a route DOES stays
// with the panel, because that is panel state rather than key meaning: the
// launcher guards a staged delete, the pass panel stands down while a field
// owns the keyboard.
//
// NO Qt IN HERE, for the reason NavKeys.js gives: a `.pragma library` cannot
// import Qt, so the caller hands the `Qt` object in and this file only reads
// the twelve members it names. That keeps every answer below drivable from the
// suite while leaving one key table for every panel.
//
// The empty string means "not a panel route", which is what lets a caller tell
// a foreign key (a letter, a shortcut) from a route that does nothing.
// A row's in-flow slots are DropdownSlots with the same `open`/`closing`
// contract on every surface. This is the one place that turns them plus a
// panel's confirmation flag into the "a dropdown owns the keys" verdict.
function dropdownOpen(confirmOpen, row) {
  if (confirmOpen === true) return true
  if (!row) return false
  const live = (s) => !!s && (s.open === true || s.closing === true)
  return live(row.descSlot) || live(row.deleteSlot) || live(row.expandSlot)
}

function isNavigation(name) {
  return name === "next" || name === "prev" || name === "first" || name === "last"
}

// One rule for every list panel: while a dropdown is open, navigation keys
// belong to the dropdown, not to the list underneath it. A selection dropdown
// is the exception - its arrows move the option cursor, so the row handles
// those keys before asking for a route. Anything else (a confirmation, an
// input field, a number picker, a description) must swallow them; otherwise
// Tab walks focus out of a dialog that is still on screen.
function gateNavigation(name, openDropdown, selectionDropdown) {
  return openDropdown === true && selectionDropdown !== true
    && isNavigation(name) ? "swallow" : name
}

function route(key, qt, listMode, fieldFocused, openDropdown, selectionDropdown) {
  if (!qt) return ""
  if (openDropdown === true && selectionDropdown !== true && key !== undefined
    && (key === qt.Key_Left || key === qt.Key_Right)) return "swallow"
  let r = ""
  if (key === qt.Key_Down || key === qt.Key_Tab || key === qt.Key_PageDown) r = "next"
  else if (key === qt.Key_Up || key === qt.Key_Backtab || key === qt.Key_PageUp) r = "prev"
  else if (key === qt.Key_Home) r = "first"
  else if (key === qt.Key_End) r = "last"
  else if (key === qt.Key_Return || key === qt.Key_Enter) r = "activate"
  else if (key === qt.Key_Escape) r = "escape"
  else if (key === qt.Key_Backspace) r = "back"
  // Space is a space in a query and "activate" on a list row, so the caller's
  // focus state decides which. A field that owns the keyboard gets the key
  // back unclaimed rather than having it swallowed as a route.
  else if (key === qt.Key_Space && listMode && !fieldFocused) r = "activate"
  return gateNavigation(r, openDropdown, selectionDropdown)
}

// Ctrl-V from a row whose field has no caret: the native paste never sees the
// key, so the panel has to land it through the field's own pipeline. This is
// only the key answer - "paste" - because the guard differs per surface (an
// open menu editor swallows it, the launcher and clipboard want list focus,
// the clipboard also wants a live filter and an unfocused field). The action
// and event.accepted stay in the panel that owns them.
//
// Meta is explicitly excluded: on those layouts Ctrl+Meta+V is a system
// shortcut, not a query paste. The qt table is handed in, as above, so this
// stays drivable from plain values with no Qt import.
function pasteRoute(key, modifiers, qt) {
  if (!qt) return ""
  if (key !== qt.Key_V) return ""
  if ((modifiers & qt.ControlModifier) === 0) return ""
  if ((modifiers & qt.MetaModifier) !== 0) return ""
  return "paste"
}

// The "one printable character starts the query" test, shared by every panel
// that spends its letters on the filter. It is deliberately only about the
// key: no Ctrl, no Meta, exactly one character whose code is at or above
// space. Field focus, alt-state, a dead filter or a reserved prefix are panel
// state, so those guards stay at the call site rather than leaking in here.
function printable(text, modifiers, qt) {
  if (!qt) return false
  if ((modifiers & qt.ControlModifier) !== 0) return false
  if ((modifiers & qt.MetaModifier) !== 0) return false
  return typeof text === "string" && text.length === 1 && text.charCodeAt(0) >= 32
}

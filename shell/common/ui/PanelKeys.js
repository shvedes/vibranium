.pragma library

// The key -> route table the four list panels share: launcher, clipboard,
// pass and wallpaper picker.
//
// WHY IT EXISTS. Each panel's key handler carried its own switch over the same
// keys, and they had already drifted - the wallpaper picker listed Delete in a
// branch that could never run, because the delete key was handled above it.
// The mapping is the part that must not drift: Down and Tab are both "next
// row", PageUp/PageDown page, Home/End are the ends, Return/Enter activate,
// Backspace is "back". What a route DOES stays with the panel, because that is
// panel state rather than key meaning: the launcher guards a staged delete,
// the pass panel stands down while a field owns the keyboard.
//
// NO Qt IN HERE, for the reason NavKeys.js gives: a `.pragma library` cannot
// import Qt, so the caller hands the `Qt` object in and this file only reads
// the twelve members it names. That keeps every answer below drivable from the
// suite while leaving one key table for every panel.
//
// The empty string means "not a panel route", which is what lets a caller tell
// a foreign key (a letter, a shortcut) from a route that does nothing.
function route(key, qt, listMode, fieldFocused) {
  if (!qt) return ""
  if (key === qt.Key_Down || key === qt.Key_Tab) return "next"
  if (key === qt.Key_Up || key === qt.Key_Backtab) return "prev"
  if (key === qt.Key_PageUp) return "pageUp"
  if (key === qt.Key_PageDown) return "pageDown"
  if (key === qt.Key_Home) return "first"
  if (key === qt.Key_End) return "last"
  if (key === qt.Key_Return || key === qt.Key_Enter) return "activate"
  if (key === qt.Key_Escape) return "escape"
  if (key === qt.Key_Backspace) return "back"
  // Space is a space in a query and "activate" on a list row, so the caller's
  // focus state decides which. A field that owns the keyboard gets the key
  // back unclaimed rather than having it swallowed as a route.
  if (key === qt.Key_Space) return listMode && !fieldFocused ? "activate" : ""
  return ""
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

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

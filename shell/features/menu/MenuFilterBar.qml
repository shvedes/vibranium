import QtQuick
import qs.common

// The menu's filter header: the one field the card's SearchScope drives.
//
// Extracted from MenuPanel so the field's input contract - the chip that
// stays put while the "/" quick-filter is armed, the role and ghost hint that
// flip together, and the focus/escape/backspace routes - lives beside the
// component it configures rather than in the middle of the card's sizing
// machinery. The panel keeps ownership of what those routes do; this only
// publishes them, and exposes the field itself for text, focus and word
// editing, so SearchScope's call sites are unchanged.
Item {
  id: root

  // The field itself. The panel reads and writes its text, checks and grabs
  // its focus, and drives the word-editing helpers through this alias.
  property alias field: barInput

  // True while the "/" scoped filter is armed. The chip must stay put in
  // that mode, focused or not: the default (false) hid it on the first Esc
  // and glided the query left, which read as a flash. The ghost hint moves
  // with it so "Search" never implies the global cross-page search.
  property bool scoped: false

  signal edited(string text)
  signal accepted(string text)
  signal escaped()
  signal backspaceEmpty()
  // Not `focusChanged`: Item already carries that as the notify signal of its
  // own `focus` property, and redeclaring it is an invalid override the engine
  // ignores, which would leave the panel's handler bound to a signal the field
  // never raises.
  signal fieldFocusChanged()

  InputField {
    id: barInput

    anchors.fill: parent
    inputRole: root.scoped ? "filter" : "search"
    filterIconAlways: true
    clearable: false
    placeholder: root.scoped ? "Filter..." : "Search..."
    onEdited: text => root.edited(text)
    onAccepted: text => root.accepted(text)
    onEscaped: root.escaped()
    onBackspaceEmpty: root.backspaceEmpty()
    onFocusedChanged: root.fieldFocusChanged()
  }
}

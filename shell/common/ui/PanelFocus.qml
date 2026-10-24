pragma ComponentBehavior: Bound
// qmllint disable missing-property
// qmllint disable unqualified
import QtQuick
import QtQuick.Window

// Focus glue lives in the lib: one place for mode + keySink +
// grabList/grabFilter/reassertFocus. Panels compose it declaratively:
//
//   PanelFocus {
//     id: focus
//     searchField: searchField
//     serviceVisible: AppLauncher.visible
//   }
//   Keys.onPressed: event => panel.handleKey(event)
//   InputField { id: searchField; onFocusedChanged: Qt.callLater(focus.reassert) }
//
// Shared filter-bar contract: every overlay filter bar is InputField
// plus panel handleKey plus PanelFocus plus probeFocus (focused, text,
// mode). Panels keep their own handleKey routing; focus ownership and
// list/filter mode live here.
//
Item {
  id: root

  property string mode: "list"
  // Which mode a summon seats this surface in. "list" is the menu model: the
  // sink holds the focus and the first printable key feeds the field.
  // "filter" is the search-first model: the field holds the focus, so the
  // caret is live before the first key. A standing intent and not a one-shot
  // seat: an open runs before its surface holds keyboard focus, so the
  // request it makes is not one it can read back - reassert() completes this
  // once the grant lands.
  property string openMode: "list"
  property Item searchField: null
  property bool serviceVisible: false

  readonly property alias keySink: sink

  function grabList() {
    root.mode = "list"
    sink.forceActiveFocus()
  }

  // The mode is declared only once the field reports focus. forceActiveFocus
  // against a window the compositor has not given keyboard focus to records the
  // request without making the item the active focus item, so a mode declared
  // first outlives a focus that never arrived - and a filter mode with an
  // unfocused field is a dead keyboard: the field consumes nothing, and every
  // printable-character route requires list mode, so the keys go nowhere.
  // Declaring it late costs one keystroke of type-to-search instead.
  function grabFilter() {
    if (!root.searchField) return
    // A disabled field is a dead filter (empty source): never attempt
    // the grab - the forceActiveFocus inside can dislodge the focus
    // the surface holds, leaving the panel deaf to keys.
    if (root.searchField.enabled === false) return
    root.searchField.grabFocus()
    if (!root.searchField.focused) return
    root.mode = "filter"
    if (root.searchField.input) root.searchField.input.cursorPosition = root.searchField.input.text.length
  }

  function reassert() {
    if (!root.serviceVisible) return
    const sf = root.searchField
    const focused = sf ? sf.focused : false
    if (focused || root.mode === "filter") {
      root.mode = "filter"
      if (sf && !sf.focused) sf.grabFocus()
      return
    }
    // The search-first seat. The field is the only item that can hold this
    // surface's seat, so seating the sink here instead would take the focus
    // item the grant's own re-seat (see reseat) owes the field, and the
    // field would never get it: the re-seat is owed only while nothing holds
    // focus, and the sink would now hold it. A request made before the grant
    // records nothing, so this leaves the mode declared late (see
    // grabFilter) and runs again when the grant lands.
    if (root.openMode === "filter" && sf !== null) {
      root.grabFilter()
      return
    }
    if (!sink.activeFocus) sink.forceActiveFocus()
  }

  // Shared filter probe: headless and test callers read focus plus
  // query through one entry point instead of pasting the one-liner.
  function probe() {
    const sf = root.searchField
    return {
      focused: sf ? sf.focused : false,
      text: sf ? sf.text : "",
      mode: root.mode
    }
  }

  Item { id: sink }

  // Whether nothing in the surface currently holds focus. This primitive owns
  // two focus items - the search field and the sink - and every other one in a
  // panel surface belongs to the consumer: the field inside a dropdown slot,
  // the inline name editor, the secret box. The window reports those exactly
  // like it reports the panel's own, so every automatic focus request below is
  // conditioned on there being nothing to displace.
  //
  // The window's content item counts as unowned, and it is the case that
  // matters: a window hands it active focus at creation as a placeholder, and
  // key events delivered to it bubble to its parents rather than down to the
  // panel, so a surface sitting on it has no focus item at all as far as the
  // panel is concerned. That is the "left holding none" state below, and
  // reading it as owned would leave it unrepaired.
  //
  // A focus item that does not hold focus counts as unowned too. The pointer
  // itself is not the signal: a window keeps naming the last focus item after
  // the item lets go rather than reporting none, so "the panel lost focus" is
  // a live pointer to something that is not holding focus - never a null one.
  function unowned() {
    const w = root.Window.window
    if (w === null) return true
    const it = w.activeFocusItem
    if (it === null || it === w.contentItem) return true
    return it.activeFocus !== true
  }

  // The window re-seat. The window is the only party that can take keyboard
  // focus away without asking: an overlay's layer surface is created and
  // mapped when it opens, and the compositor's keyboard grant lands a round
  // trip later, with the surface inactive in between. A focus request made
  // during that window does not survive it, and a panel whose only focus
  // assert ran at open is left holding none - a Keys handler on the panel
  // root sees only events bubbling up from a focused descendant, so a panel
  // with no focus item receives no keys at all.
  //
  // Owed only while the surface holds nothing. Re-seating on every focus
  // change instead is a focus war rather than a heal: the turn an editor
  // takes focus the window announces a new focus item, the re-seat hands it
  // straight back, and the editor is left unfocused with the panel fighting
  // its own consumer.
  //
  // Deferred one turn: the surface becomes active before its item tree has
  // settled, and reassert reads the field and the sink.
  function reseat() {
    const w = root.Window.window
    if (!w || !w.active) return
    if (!root.unowned()) return
    Qt.callLater(root.reassert)
  }

  Connections {
    target: root.Window.window
    ignoreUnknownSignals: true

    function onActiveChanged() { root.reseat() }
    function onActiveFocusItemChanged() { root.reseat() }
  }

  // Auto-watch searchField focus when it becomes available. A field that
  // lost focus is healed, and a field that lost it to something else in the
  // surface is not: re-grabbing it is how a keystroke meant for a number
  // picker ends up in the query instead. The consumer owns the editors, so
  // the consumer re-asserts them (MenuPanel.reassertFocus, the row's
  // editorOpen).
  Connections {
    target: root.searchField
    ignoreUnknownSignals: true
    function onFocusedChanged() {
      if (root.unowned()) Qt.callLater(root.reassert)
    }
  }
}

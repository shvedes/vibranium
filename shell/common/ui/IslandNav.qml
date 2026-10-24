pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "NavKeys.js" as NavKeys

// IslandNav: the key surface of one island surface.
//
// It is an ANCESTOR of the content, and that is the whole design. A key event
// is delivered to the item holding active focus and bubbles up its parent
// chain, so only an ancestor sees both halves of an island's keyboard: the
// keys a focused child did not consume (an island whose content root grabs
// focus for its own shortcuts) and the keys nothing in the content claims.
// A sibling sink sees one half and never the other, which is why this is a
// wrapper and not a focus item parked next to the card.
//
// The escape ladder falls out of that order rather than out of a stack: a
// focused child (an input field wiping, a nested slot closing) is below the
// content root, and both are below this, so the innermost handler runs first
// and only an unclaimed Escape reaches escapePressed. An island that needs a
// rung of its own puts a Keys handler on its content root.
//
// Arrows and Enter go to `target`, which is duck-typed: moveBy(dx, dy) for
// the four directions and activate() for Enter, each probed before it is
// called. Both are optional, so a surface with rows and no primary action
// still navigates, one with an action and no rows still activates, and
// anything that implements neither leaves the keys alone. `List` and
// `GridList` implement both, which is the whole wiring an island does: point
// `target` at one of them.
//
// A modified arrow is NOT routed. Shift/Ctrl/Alt/Super plus an arrow is a
// different gesture that belongs to whatever is focused (the media island
// seeks on Shift and skips tracks on Ctrl), so the router declines and the
// event keeps travelling. Enter and Escape are unconditional: neither is a
// modifier gesture anywhere in this tree.
Item {
  id: root

  // Whether the surface is live. Closed, the item holds no focus and consumes
  // nothing; the window itself is unmapped or fading at the same moment.
  property bool active: true

  // When true, EVERY key is forwarded to descendants untouched and no signal
  // fires. This is the suspension hatch for an inline editor: an island whose
  // search field or password box holds the keyboard sets `blocked`, and the
  // arrows type into the field instead of walking the island's cursor.
  //
  // It exists because `Keys.BeforeItem` below deliberately outranks the
  // focused child, and that is only safe with an explicit way to stand down.
  // A focus check is NOT that hatch: the child holding focus is precisely the
  // case the priority override breaks.
  //
  // An island states its own version of this as `blockedNavKeys` and the
  // surface copies it into `contentBlocked`; see `suspended`.
  property bool blocked: false

  // The surface's copy of the loaded content's `blockedNavKeys`. OR-ed with
  // `blocked` rather than replacing it, so a surface that has its own reason
  // to stand down (a modal slot open, a confirm in flight) and the content's
  // reason (a focused text field) do not have to know about each other.
  readonly property bool suspended: root.blocked || root.contentBlocked

  // Set by the surface from the loaded content's `blockedNavKeys`, read
  // through a probed function rather than a binding: `cardLoader.item` is
  // typed QtObject, and a binding reading a property the content may not
  // declare can fail to evaluate - which Qt answers by dropping the binding,
  // silently, leaving an island whose keys are never suppressed.
  property bool contentBlocked: false

  // The keyboard target, resolved by the surface that owns this router from
  // the loaded content (IslandHost reads the content's `islandNavTarget`).
  // Null is the normal answer for an island with nothing to navigate.
  property var target: null

  // The four direction keys this router answers, as data so NavKeys.js can
  // stay Qt-free. Overridable so a surface with its own direction keys can
  // say so without editing the router.
  readonly property var keyCodes: ({
    left: Qt.Key_Left,
    right: Qt.Key_Right,
    up: Qt.Key_Up,
    down: Qt.Key_Down
  })

  readonly property bool navigable: root.target !== null
    && typeof root.target.moveBy === "function"
  readonly property bool activatable: root.target !== null
    && typeof root.target.activate === "function"

  // Semantic signals, not behaviour: what closing means (unmapping a window,
  // leaving a mode, switching to the next island) belongs to whoever mounted
  // the router. This split is what lets the key map stay in one place while
  // ten islands keep their own state machines.
  signal escapePressed()
  signal deleteRequested()
  signal textKey(string text)

  // The item the host hands active focus to once the surface is mapped. The
  // router holds no sink of its own for this: it is the router itself, so a
  // focus grant lands on the item whose Keys handler is the one that matters.
  readonly property alias focusSink: root

  // Owns active focus while the surface is live, which is what makes the
  // unclaimed keys arrive here at all. A content child that wants the keys (a
  // content root calling forceActiveFocus) is declared later, so it wins
  // deliberately rather than by accident.
  focus: root.active

  // BeforeItem, and this is the second load-bearing choice in this file.
  // The default priority lets the focused item's own handler see a key first,
  // which hands every arrow to whatever inner Flickable/ListView/TextField
  // happens to hold focus and leaves the island's cursor unmoved. BeforeItem
  // runs the island's key map first, and `blocked` is the way back down.
  Keys.priority: Keys.BeforeItem

  Keys.onPressed: event => {
    if (!root.active || root.suspended) return

    if (event.key === Qt.Key_Escape) {
      root.escapePressed()
      event.accepted = true
      return
    }

    // Tab is NOT handled, and that is deliberate. It stays unaccepted so it falls
    // through to Qt's own focus traversal, which is what a Tab key means
    // everywhere else on this desktop - and it is worth being explicit about
    // why, because intercepting Tab to hop to the NEXT BAR ISLAND is a
    // different feature wearing Tab's clothes. Inside one
    // island, Tab moving focus between the island's own focusable elements is
    // the conventional reading, and hijacking it to leave the island silently
    // makes an island's own controls unreachable by keyboard.

    // Arrows, plus the IJKL/HJKL cluster. A modified arrow is NOT routed -
    // Shift/Ctrl/Alt/Super plus an arrow is a different gesture that belongs
    // to whatever is focused (the media island seeks on Shift and skips
    // tracks on Ctrl), so the router declines and the event keeps travelling.
    // Enter and Escape are unconditional: neither is a modifier gesture
    // anywhere in this tree.
    const dir = NavKeys.direction(event.key, root.keyCodes)
    if (dir !== null) {
      if (event.modifiers
        & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
        return
      }
      if (root.navigable && root.target.moveBy(dir.dx, dir.dy)) event.accepted = true
      return
    }
    const vim = NavKeys.vim(event.text)
    if (vim !== null) {
      if (root.navigable && root.target.moveBy(vim.dx, vim.dy)) event.accepted = true
      return
    }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
      || event.key === Qt.Key_Space) {
      if (!root.activatable) return
      root.target.activate()
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Delete) {
      root.deleteRequested()
      event.accepted = true
      return
    }

    // A one-shot letter shortcut. Deliberately NOT consumed: the island
    // decides whether the letter means something, and a letter it does not
    // know must still reach whatever else wants it.
    if (event.text && event.text.length === 1) root.textKey(event.text)
  }

  // Focus ownership when the surface is mapped late. An overlay's layer
  // surface is created and mapped when it opens and the compositor's keyboard
  // grant lands a round trip later, so a focus request made during that
  // window does not survive it - the same re-seat PanelFocus performs for
  // the panels, and it is borrowed rather than rewritten here. Every
  // automatic re-assert inside it is gated on nothing in the surface holding
  // focus, so it repairs an unowned surface and never takes the keys back
  // from an editor that has them.
  PanelFocus {
    id: focus

    serviceVisible: root.active
  }

  // The window re-seat is NOT re-declared here. PanelFocus already connects
  // to its own window and calls reseat() on both `active` and
  // `activeFocusItemChanged`, which is the whole of what a second Connections
  // block on Window.window would do - and a worse version of it, because that
  // attached property is documented to support Item-derived targets only, so
  // using it bare warns at runtime. One place owns the focus glue; a panel
  // composes it rather than copying it.
}
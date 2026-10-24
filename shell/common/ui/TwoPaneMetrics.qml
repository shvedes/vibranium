pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Two-pane card metrics: a fixed list budget on the left, a preview pane on
// the right that is exactly as wide as the card is tall in the pane's aspect.
//
// WHY IT EXISTS. The clipboard window and the wallpaper picker are the same
// shape - a scrolling list beside a preview, both wanting a window that does
// not move - and each grew its own copy of the arithmetic. That is how they
// came to differ: one was six two-line rows tall, the other six one-line rows,
// and a third version of the width rule appeared and was wrong. A card's
// WIDTH and HEIGHT are one decision, so they live here once and both panels
// read them, which is what makes the two windows the same size rather than
// coincidentally similar.
//
// BOTH AXES ARE CONSTANT, and neither reads the selection, the row count or
// the entry type. A window that resizes as you arrow through entries moves the
// pane out from under the thing being read: a text entry and a screenshot are
// two things in ONE window. The preview pane is sized ONCE, at 16:9 against
// the card's own height, so a 16:9 image fills it edge to edge and any other
// aspect letterboxes inside a box that was already the right size. Deriving
// the width from the height is the same number twice and only invites the two
// to disagree.
//
// The height is set by the TALLEST row shape these cards carry - a title plus
// a second line - rather than by each panel's own row. That is the whole
// reason the two cards match, and it is why a panel whose rows are shorter
// shows more of them instead of a shorter window: the window is the budget,
// the row count is whatever fits inside it.
//
// An Item, like RowHeightProbe beside it, because the row height is measured
// with real Texts and an object with no default property cannot host them. It
// draws nothing: the probe's own Texts are invisible and read through
// implicitHeight.
Item {
  id: root

  // The left column. A wall of text wants a little more than a wall of
  // filenames, and one value for both is what keeps the cards identical.
  readonly property int leftW: 380
  readonly property int gap: 12

  // The window's row budget, in the tallest row shape a card here can render.
  readonly property int rows: 6

  // The preview pane's aspect. 16:9 is what a screenshot is, and the pane is
  // sized to it rather than the image resized to the pane.
  readonly property real aspect: 16 / 9

  // The inter-row gap. Taken from the list's own spacing by the caller; this
  // is only the cold-start value before a list exists to ask.
  property real spacing: 2

  // One two-line row, measured from the fonts and cached by the probe. This
  // is the term that sets the window, and it is deliberately NOT the
  // consuming panel's row height: a card one line tall and a card two lines
  // tall are the same window.
  //
  // Floored, and knowingly: the probe answers -1 until it has laid out the
  // constant string below, which is a placeholder for one turn and not an
  // unmeasurable row. The floor is the shape's own minimum, and the cache
  // drop at the bottom of this file re-measures it for real.
  readonly property real rowH: Math.max(Ui.rowMinH, rowProbe.measure("Mg", "00:00"))

  RowHeightProbe { id: rowProbe }

  // The card's height: whole rows and the gaps between them, so the bottom
  // edge is the bottom of a row rather than a fraction of one.
  readonly property real contentH: root.rows * root.rowH
    + Math.max(0, root.rows - 1) * root.spacing

  // The preview pane, and with it the card's width.
  readonly property int previewW: Math.round(root.contentH * root.aspect)
  readonly property int totalW: root.leftW + root.previewW + root.gap

  // The fonts land late, and a probe that measured before they did keeps its
  // first answer for the session. Dropping the cache once the component is up
  // is the documented way to ask for a settled number, and the window is
  // sized from this one.
  Component.onCompleted: Qt.callLater(() => rowProbe.clear())
}

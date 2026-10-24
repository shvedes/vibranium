.pragma library

// How tall a slot-bearing region's card should be, for ONE list, given one
// resting region. This is the whole decision, and it lives here because one
// rule has to be written once: two copies drift the moment the claim changes
// meaning. The drift is not hypothetical: a panel that compares the claim
// against the region as though the claim were a region height asks for a
// taller card the further down the content a row sits, so a dropdown on the
// last folder in the password manager grows the window by its own scroll
// offset.
//
// ## Why it is not in the library proper
//
// The decision needs a height, and the height belongs to whoever is showing
// it. Putting it inside List.qml - which owns `revealNeedH` - means reading
// `contentY` and `height` from inside a binding that feeds that same height,
// and Qt answers that by dropping the value and reporting a binding loop. A
// binding loop is not a one-off: the live shell logged 70,000 of them. So the
// LIST publishes the claim and the CONSUMER applies it, which is the split
// this file sits on top of.
//
// ## Why a .js and not QML
//
// It is a pure function of four numbers and the list's public claim, so it can
// be exercised without a window, a panel or a Quickshell. A copy of the rule
// living in a panel could only ever be tested by driving a live shell over
// IPC, and the one surface with a test probe was checked against values the
// test itself supplied, never against the arithmetic. `slot-growth.test.mjs`
// asserts the arithmetic directly.
//
// The reveal margin is a PARAMETER, not an import. A .js cannot import the Ui
// singleton in this tree (CalendarLib.js documents the same limitation and
// duplicates the constant instead), and a rule that silently hardcoded its
// own copy of the spacing would drift from the list's definition of
// "revealed" - which is precisely the disagreement that made the card and
// the list fight over one dropdown.

// The region a card should show while a slot is open on `list`.
//
//   list     the List, for its claim, scroll offset and row geometry
//   base     the resting region the card is already showing
//   ceiling  the tallest region a card may be on this screen
//   margin   the list's reveal margin (Ui.s), passed rather than imported
//
// Returns `base` unchanged in every case where the list can do the work
// itself, so the caller's only job afterwards is to publish the result to
// `list.growthH` - see the note on that property.
function regionForSlot(list, base, ceiling, margin) {
  if (!(base > 0)) return base
  const claim = list.revealNeedH
  if (!(claim > 0)) return base

  // The row's SETTLED height, slots included. The claim is its bottom edge in
  // content coordinates, so the difference is the whole of it.
  const rowTop = list.rowTop(list.autoRevealIndex)
  const rowH = claim - rowTop

  // SCROLL FIRST, and this is the test for it. A scroll position c reveals the
  // row iff c <= rowTop (its top is below the region's top edge) and
  // c + base >= rowTop + rowH (its bottom is above the region's bottom
  // edge), which is solvable exactly when rowH <= base. So when the row fits
  // in the region the card is already showing, the list can always find that
  // position and the card must not move: resizing the window for something a
  // scroll reveals is the wrong answer.
  //
  // The region therefore grows only when the row does not fit - the dropdown
  // is taller than the card, and no scroll position shows all of it. That is
  // the "expand on demand" case, and it is the only one.
  if (rowH <= base + 0.5) return base

  // The region is the ROW's own settled height, and it does not read
  // `contentY`.
  //
  // Subtracting the live scroll offset asked the card to become as tall as
  // the row's distance down the page, so the card grew to swallow the scroll
  // instead of the list taking it. Measured on the Media Controls page with
  // the OSD rows off: a 385px claim in a 145px region produced a 393px
  // card, `contentY` stayed at 0, and the entries above the opened row never
  // moved - the window grew downward from its bottom border and nothing was
  // pushed up.
  //
  // Sizing the region to the row leaves the row too tall to fit in it, which
  // is the one condition under which the list seats a reveal, and the seat
  // is what carries the entries above to the top of the viewport. The two
  // halves are a pair and neither works alone: this rule without the list's
  // seat grows the window and pushes nothing, and the seat without this rule
  // lands 17px short of the row's top. The handoff is monotonic and closes
  // once - with `height == rowH` the list's outstanding amount reduces to
  // `rowTop - contentY`, positive until the seat puts the row's top at the
  // region's top, and zero there.
  //
  // The margin is deliberately not added. The content ENDS at the row's
  // bottom, so `rowBottom + Ui.s` is not a content row the viewport can
  // scroll to; charging it to the region makes the card taller than the
  // content meant to fill it, and the list is left permanently a margin
  // short with nothing to spend it on.
  const need = rowH

  // Past the ceiling the region stops: a card taller than the display is not a
  // card. The claim is then handed back to the list, which scrolls the rest.
  if (need > ceiling) return base

  return Math.min(Math.max(base, need), ceiling)
}

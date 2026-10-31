pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// ScreenCeiling - how much of the SCREEN a window's card may take.
//
// WHY IT EXISTS. A ceiling derived from the window the card lives in is the
// shape this file exists to replace:
//
//   maxHeight: win.height > 0 ? Math.round(win.height * 0.6) : 600
//
// and the window is sized FROM that card, so the number resolves in stages.
// win.height reads 0 before the first polish, so a hardcoded placeholder
// stands in for that frame, and the real value arrives a frame or two later -
// a different number from the placeholder, which is the only part that
// matters. The card is built to fit the placeholder's row count, the ceiling
// then grows under it, one more row fits where a row has just been cut, and
// the row that appears is a visible pop on every summon. Five features each
// carry the same two lines, which is why the same defect has to be found
// five times.
//
// A screen is the same number from the first frame and never changes, so the
// ceiling is read from it and the placeholder goes away with the loop.
//
// The fraction is per surface and not a constant of this file: a card with a
// preview pane beside it wants more of the screen than a single column does,
// and a power menu wants less than either. What belongs here is the rule, the
// screen lookup and the no-screen case - not the taste.
QtObject {
  id: root

  // The screen the card is on. The view knows this and nothing below it does,
  // which is why the ceiling is expressed here and not inside PanelCard: a
  // card knows the height it was handed, and a panel handed a height derived
  // from the window it is inside is back where this started.
  property ShellScreen screen: null

  // The share of the screen the card may take at rest, and the larger share
  // the growth path may reach. A slot that opens, or a page taller than the
  // resting cap, grows up to the second number and no further.
  property real fraction: 0.6
  property real growthFraction: 0.85

  readonly property int screenH: root.screen ? Math.round(root.screen.height) : 0
  readonly property int maxHeight: Math.round(root.screenH * root.fraction)
  readonly property int hardMaxHeight: Math.round(root.screenH * root.growthFraction)
}

// The menu row's resting geometry, as pure arithmetic over its tokens.
//
// WHY THE ARITHMETIC IS HERE AND THE METRICS ARE NOT. A rest height is
//
//   max(rowMinH, titleLine + (second line ? 1 + its line : 0) + 2 * rowPadV)
//
// where every line is ceil(FontMetrics.height) for its font. The FontMetrics
// belong to QML - RowGeometry builds them from the theme and pins the tokens -
// and the arithmetic belongs to nobody in particular, which is exactly why it
// lives here: the same rule can then be asked at ANY token set, including the
// scaled ones a larger font produces, without a shell running. The singleton
// supplies the tokens; this file is the rule.
//
// A `.pragma library` namespace IS its top-level declarations, so every name
// below is part of the module's surface. Nothing here reads Ui, Menu or an
// item: a caller hands over the token set.
.pragma library

// The row's own constants. They are not theme tokens (a theme does not choose
// them), and both the singleton and a test read them from here so the swatch
// strip, the separator's breathing and the bare hairline are spelled once.
var SWATCH_H = 8
var SEP_PAD_V = 3
var BARE_SEP_H = 10

// The stacked height of a row's text column, before the row's padding.
// `kind` is one of the three shapes a row takes at rest ("line", "sub",
// "theme"), and nothing about it names a string.
//
// A theme row's second line is the swatch strip, not a sub line: the strip is
// the dot's own size and the 1px above it is the label Column's spacing.
function colH(kind, g) {
  if (kind === "theme") return g.labelLineH + 1 + g.swatchH
  if (kind === "sub") return g.labelLineH + 1 + g.subLineH
  return g.labelLineH
}

// The row's rest height: its column plus the row's vertical padding, floored
// at the shared minimum row. THE rule - Entry's delegate height and
// MenuPanel's model-side estimate both ask it, so the card's bottom edge lands
// on a row boundary instead of a few pixels into a row.
//
// The floor is why the padding is inside the max rather than added to it: a
// one-line row at a small font is SHORTER than the minimum row, and a rule that
// seated it at the floor and then added padding would be two rules wearing one
// name.
function restH(kind, g) {
  return Math.max(g.rowMinH, colH(kind, g) + 2 * g.rowPadV)
}

// A group separator's rest height: a breadcrumb in the sub-line register, or
// nothing at all. Both halves read the same answer, so a labeled section header
// is one number on the card and on the delegate that draws it.
function restSeparator(hasLabel, g) {
  return hasLabel ? g.subLineH + 2 * g.sepPadV : g.bareSepH
}

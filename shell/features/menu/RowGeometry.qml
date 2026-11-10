pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "RowRule.js" as RowRule

// The menu row's token set: the theme's two line registers and the numbers the
// rest-height rule is asked with. The RULE is RowRule.js; this file supplies
// what the theme and the font say and hands every caller the same answers.
//
// WHY IT IS A SINGLETON. The rule is a constant of the theme and the font, not
// of a row or a card. It used to be an Item that MenuPanel owned one of and
// every delegate instantiated another of - two FontMetrics per live row, each
// answering the same two numbers for the same two fonts. Nothing here is
// per-instance, and a module singleton is the one copy that Qt will make.
//
// WHY THE LINE IS PINNED. A laid-out line box is not one number per font -
// measured on this host it spans 17..19px for a title line across sixteen
// strings, and 13..25px for a sub line - so a card sized from the MODEL and a
// delegate sized from its own laid-out Text could only agree by shaping the
// same string twice, which is what the per-string height cache existed for.
// With the line pinned to ceil(FontMetrics.height) on both sides, a rest height
// follows from the row's KIND alone and neither side has to know what the other
// shaped. MEASURED, NOT ASSERTED: `tests/shell/suites/qml/menu-row-height-test.sh`
// measures the pin against the engine's own line boxes at four font scales,
// fallback faces included.
QtObject {
  id: root

  // The two line registers a row draws at rest: its title (fontL) and its sub
  // line - or a separator's breadcrumb - (fontXs).
  //
  // The pin is ONE number per register, but the engine draws a script with
  // its fallback face, whose line box can be taller than the primary face's.
  // Measuring the primary metrics alone under-pins every row that renders a
  // fallback script (an Arabic title clipped its own line), so the token is
  // the tallest line the fallback chain produces for a sample per script.
  readonly property real labelLineH: Math.ceil(Math.max(root.labelMetrics.height, root.labelFallbackMetrics.height))
  readonly property real subLineH: Math.ceil(Math.max(root.subMetrics.height, root.subFallbackMetrics.height))

  // The row constants, read from the rule so the strip, the breathing and the
  // hairline are spelled once.
  readonly property int swatchH: RowRule.SWATCH_H
  readonly property int sepPadV: RowRule.SEP_PAD_V
  readonly property int bareSepH: RowRule.BARE_SEP_H

  // Everything the rule needs, in one object. A theme or font change moves a
  // token and every reader re-asks; nobody has to be told which function
  // depends on what.
  readonly property var tokens: ({
    labelLineH: root.labelLineH,
    subLineH: root.subLineH,
    swatchH: root.swatchH,
    sepPadV: root.sepPadV,
    bareSepH: root.bareSepH,
    rowMinH: Ui.rowMinH,
    rowPadV: Ui.rowPadV
  })

  // The metrics are PROPERTIES, not bare children: QtObject has no default
  // property, so a child object has to be assigned to a declared one. (As a
  // child it is a construction error, and every delegate that reads this
  // singleton then fails to build.)
  readonly property FontMetrics labelMetrics: FontMetrics {
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
  }

  readonly property FontMetrics subMetrics: FontMetrics {
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
  }

  // Fallback shaping samples: the scripts the menu corpus actually contains.
  // TextMetrics shapes the string, so the height it reports is the one the
  // fallback face would lay out, not the primary face's.
  readonly property TextMetrics labelFallbackMetrics: TextMetrics {
    font.pixelSize: Ui.fontL
    font.family: Ui.fontFamily
    text: "مرحبا हिन्दी 日本語"
  }

  readonly property TextMetrics subFallbackMetrics: TextMetrics {
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    text: "مرحبا हिन्दी 日本語"
  }

  function colH(kind) {
    return RowRule.colH(kind, root.tokens)
  }

  function restH(kind) {
    return RowRule.restH(kind, root.tokens)
  }

  function restSeparator(hasLabel) {
    return RowRule.restSeparator(hasLabel, root.tokens)
  }
}

pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Per-string row-height measurement, on the basis every row delegate already
// uses: a real Text's implicitHeight, the integral line box for THAT string.
//
// WHY NOT A TextMetrics PROBE. A probe answers the height of the string it was
// given, so one fixed probe string is not the row's label - and the two
// quantities are not even the same shape. TextMetrics.height is the glyph
// bounding box; Text.implicitHeight is the laid-out line box, which is
// fractional until the delegate's own ceil(FontMetrics.height) floor rounds
// it. Measured on the launcher's two-line row:
//
//   real Text        18 + 1 + 14  = 33  -> row 47
//   "Mg" TextMetrics 17.141 + 1 + 13.188 = 31.328 -> estimate 45.328
//
// 1.672px a row, so a twelve-row cap loses 18px and its last entry renders
// cut through the middle. The gap is the accumulated fractional slack, and it
// is scale-dependent in exactly the way the report describes: at an integer
// scale factor the metric is already integral, ceil is a no-op, and the probe
// agrees; at a fractional one it falls short by up to a pixel per line, so
// the cut shows at some scaling levels and not at others.
//
// String-dependent by construction as well - MenuPanel's own comment records
// that "App launcher" renders a pixel taller than "Mg" - so no single probe
// string stands in for a set of them. Hence per string, and hence a cache:
// re-measuring every row from inside a height binding is a layout storm.
//
// CACHING SAFETY. A height binding calls measure() directly (PanelCard's
// region math does), so a miss must not invalidate the binding that asked.
// All mutable state therefore lives in ONE plain-object property and is
// mutated by member write only: a counter property would fire on every
// insertion and Qt would drop the binding's value mid-pass. The two probe
// Texts are written on a miss too, which re-invalidates once and settles on
// the next pass - the same tradeoff MenuPanel's probe makes, and the reason
// the cache is checked first.
//
// PlainText sub lines: a markup-bearing sub belongs to MenuPanel's own probe,
// which shapes with StyledText on purpose.
Item {
  id: root

  // Bound, and small: a panel measures the rows it renders plus whatever the
  // width pass touches, which is tens of strings. The cap is a backstop
  // against a consumer that hands every row of a long list to a model-math
  // call, not a working limit.
  property int maxEntries: 512
  // font.family is assigned per measurement the way MenuPanel's probe family
  // is, so a consumer that renders per-row fonts measures on the row's own.
  property string probeFamily: Ui.fontFamily

  // clock, cache and touch in one bag. Member writes only - see above.
  property var _state: ({
    clock: 0,
    cache: Object.create(null),
    touch: Object.create(null)
  })

  // The delegate's own line metric, per font size. LauncherEntry floors each
  // line on ceil(FontMetrics.height), so the probe must read the same metric
  // to land on the real height at fractional scale - a Text's implicitHeight
  // is the fractional line box that value floors, and keeping it (even ceiled)
  // left a sub-pixel gap that still cost a fit retry.
  FontMetrics {
    id: labelFontMetrics
    font.pixelSize: Ui.fontL
    font.family: root.probeFamily
  }
  FontMetrics {
    id: subFontMetrics
    font.pixelSize: Ui.fontXs
    font.family: root.probeFamily
  }

  // A probe Text that has not been laid out reports a zero line box, and
  // reading one is not a measurement - it is a placeholder. Both probes take
  // an explicit width and NoWrap so their line box is the text's own and never
  // a function of a width the parent has not resolved: a wrapping text at an
  // unresolved width is zero lines tall, and 0 is exactly the value that
  // poisoned the first draft of this cache.
  Text {
    id: labelProbe
    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.pixelSize: Ui.fontL
    font.family: root.probeFamily
    textFormat: Text.PlainText
  }

  Text {
    id: subProbe
    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.pixelSize: Ui.fontXs
    font.family: root.probeFamily
    textFormat: Text.PlainText
  }

  // Resting height of one row: the label column's line boxes plus the row's
  // vertical padding, floored at Ui.rowMinH - the same arithmetic the row
  // delegates spell in their own height bindings.
  //
  // A negative answer means "not measurable", and it is the only way this
  // function says so. The floor belongs to the caller: `rowRestHeight` in
  // PanelCard takes `h > 0 ? h : Ui.rowMinH`, because a negative height inside
  // a row sum would shrink every row after it, and the two-pane surfaces take
  // `Math.max(Ui.rowMinH, ...)`. A floor returned from here instead would be
  // indistinguishable from a real one-line row, which is what made a two-line
  // row measure as an empty one: a plausible number rather than a visible
  // failure.
  function measure(label, sub) {
    const lab = label === undefined || label === null ? "" : String(label)
    const sb = sub === undefined || sub === null ? "" : String(sub)
    if (lab === "" && sb === "") return -1
    const state = root._state
    const key = lab + "" + sb
    const hit = state.cache[key]
    if (hit !== undefined) {
      state.touch[key] = ++state.clock
      return hit
    }
    // Assign first, then ask whether a line box came back. A Text whose layout
    // has not run reports a zero height for whatever it holds, and reading
    // that is reading a placeholder - so the negative answer is returned
    // WITHOUT being remembered. The entry is keyed by string, so one cached placeholder
    // would pin the wrong height for the rest of the session; the caller's
    // next pass measures for real. The test has to follow the assignment:
    // checking the probe before it holds the text asks a question no probe
    // can ever answer, and every string would take the early return forever.
    // Match the delegate's own floor: LauncherEntry spells its resting line
    // height as ceil(FontMetrics.height) per line, and a Text's implicitHeight
    // is the fractional line box that value floors. Measuring the same metric
    // the delegate uses removes the last fractional-scale slack, so the model
    // latch lands on the real height on the first pass.
    let colH = lab === "" ? 0 : Math.ceil(labelFontMetrics.height)
    if (colH <= 0) return -1
    if (sb !== "") {
      const sh = Math.ceil(subFontMetrics.height)
      if (sh <= 0) return -1
      colH += 1 + sh
    }
    const h = Math.max(Ui.rowMinH, colH + 2 * Ui.rowPadV)
    state.cache[key] = h
    state.touch[key] = ++state.clock
    root._evict()
    return h
  }

  // Least recently read first, so a row whose height is asked for every frame
  // is the last to lose its entry. Costs an estimate for the evicted string
  // and re-learns on its next measurement.
  function _evict() {
    const state = root._state
    const keys = Object.keys(state.cache)
    if (keys.length <= root.maxEntries) return
    keys.sort((a, b) => (state.touch[a] || 0) - (state.touch[b] || 0))
    const excess = keys.length - root.maxEntries
    for (let i = 0; i < excess; i++) {
      delete state.cache[keys[i]]
      delete state.touch[keys[i]]
    }
  }

  // A cache entry is only valid for the font it was measured with, so the
  // family changing drops the lot. Self-healing rather than caller-driven: a
  // font swap would otherwise leave every entry stale for the session, and
  // every panel would have to remember to say so.
  onProbeFamilyChanged: root.clear()

  // The fonts land late - the same label measures differently on the first
  // turns than later - so a caller that cares about a settled number drops
  // the cache once the fonts are in. Without it the stale entries outlive the
  // change that invalidated them.
  function clear() {
    const state = root._state
    state.cache = Object.create(null)
    state.touch = Object.create(null)
  }
}

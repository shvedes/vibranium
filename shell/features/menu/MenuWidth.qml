pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.menu
import "MenuLib.js" as MenuLib

// The menu card's WIDTH: how wide a page of rows has to be.
//
// WHY IT IS ITS OWN FILE. The card is content-sized - exactly as wide as its
// widest row - and that one answer needs seven shaping probes, three
// dictionaries bounded by a shared budget, a dropdown that widens the card past
// its resting measure, and two singleton connections that drop the lot when the
// font or the palette changes. That is a rule, not a corner of a card: it is
// read by the card's own width binding, by the dropdown open/close handlers and
// by the row-set install, and none of those need to know how a text is shaped.
// It lived in the middle of a 4.8k-line panel beside the fit trajectory, the
// keyboard routing and the persistence, which is exactly the kind of file where
// a rule stops being readable as a rule.
//
// WHAT IT MEASURES, AND WHAT IT DELIBERATELY DOES NOT. The pass measures the
// page's own rows and never consults the viewport. The card is content-sized,
// so the window is sized to the card, and a viewport read here reports whatever
// width the previous contentW produced - on a cold summon the cardMinW floor,
// which is a plausible few hundred pixels rather than an obviously unresolved
// zero. Measured against that, a "stop once a row is already wider than the
// screen" exit fires on row 0 and answers with that one row's width instead of
// the page's widest. The viewport clamp belongs in the width binding: a content
// width that reads the viewport is circular, because the window cannot be sized
// until contentW is written and contentW cannot be written correctly until the
// window is sized.
//
// HEIGHT IS NOT THIS COMPONENT'S. A row's rest height is RowGeometry's rule and
// depends on the row's KIND alone, so none of the shaping here is visible to a
// height binding - which is why the caches below are read only from this file's
// imperative pass and a cache miss can move a probe's font family without
// invalidating anything that is evaluating.
Item {
  id: root

  // The card this engine sizes. The row set, the search mode, the grid mode,
  // the card's live width and the settle hook are all read through it, so this
  // component keeps no copy of the panel's state.
  property var host: null

  // The card's resting width: what the rows measure with every dropdown shut.
  // 0 means "not measured yet", and the width binding answers that with the
  // card's floor - a cold frame, not a claim about the content.
  property real contentW: 0

  // Closed-row width: what recalcWidth measured with every dropdown shut. The
  // card rests here; an open select dropdown widens past it through
  // applyDropdownWidth and falls back to it on close.
  property real _closedContentW: 0

  // Unified value-column width for perfect bar alignment: when a page shows two
  // or more little bars, every value box shares one width so the bars form one
  // column. Updated in recalcWidth.
  //
  // This is the PRODUCER of the shared column; MenuLib.valueSlotW is the
  // consumer rule Entry applies, and the two are not a pair of halves to be
  // merged: the pass measures the widest value on the page with the shared
  // probe, then mirrors the number into Menu.unifiedBarValueW so the delegates
  // can read one number instead of each re-deriving it.
  property int unifiedValueW: 0

  // Value probe. TextMetrics, because that is what Entry's own value slots
  // shape with (valueMetrics/selectMetrics/pctMetrics), so a trail reserved
  // here is the trail the slot renders. The LABEL probes below are Text for the
  // same reason: that is what a label renders with.
  TextMetrics {
    id: measureValue

    font.pixelSize: Ui.fontS
    font.family: Ui.fontFamily
  }

  // Prototype matching Entry's sub line exactly (see Entry subMain): it renders
  // StyledText, whose line box runs ~2px taller than the PlainText metrics. The
  // whole-row width needs the real number.
  Text {
    id: measureSubStyled

    visible: false
    text: "Mg"
    font.pixelSize: Ui.fontXs
    font.family: root._rowProbeFamily
    textFormat: Text.StyledText
  }

  // The group separator's own label: a Text, because a separator renders one
  // (Entry sepText) and the width has to be the width of what is drawn.
  Text {
    id: measureSepLabel

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: root._rowProbeFamily
    font.bold: true
    textFormat: Text.PlainText
  }

  // Imperative per-text probes for the width pass. Widths are still per string
  // and per family - a text's advance is its glyphs - and one shaping still
  // serves the label, the sub line and the separator.
  //
  // They are Text items rather than TextMetrics on purpose. The two do not
  // agree: for the same string, family and size, TextMetrics.width is a couple
  // of pixels off Text.implicitWidth in either direction ("Deep Forest" 84 vs
  // 85.8, "Grape Soda" 79 vs 78). A reservation shaped with TextMetrics is
  // therefore a reservation for a string nobody draws, and with no floor under
  // it the card came up short by exactly that.
  // Never read from bindings - the pass owns their text.
  Text {
    id: measureRowLabel

    visible: false
    font.pixelSize: Ui.fontL
    font.family: root._rowProbeFamily
    textFormat: Text.PlainText
  }
  Text {
    id: measureRowSub

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: root._rowProbeFamily
    textFormat: Text.StyledText
  }

  // Dropdown option probes. OptionRow paints its label at Ui.fontM under the
  // system family - never the value slot's fontS the trail is reserved with and
  // never the themed row family - so the width pass shapes options here instead
  // of reusing either of those probes.
  Text {
    id: measureOptLabel

    visible: false
    font.pixelSize: Ui.fontM
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
  }
  Text {
    id: measureOptLight

    visible: false
    font.pixelSize: Ui.fontXs
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
  }

  // Family the row probes shape with. Assigning font.family on a probe writes
  // the font GROUP, and Qt counts a group write from inside a binding
  // evaluation as a loop on that binding whether or not the binding reads
  // anything of the probe. The probes take the family from this plain property
  // instead, and the family still lands on the probe before its measure runs.
  // Only this imperative pass sets it.
  property string _rowProbeFamily: Ui.fontFamily

  // The width cache: ONE bounded map of shaped strings, keyed by the string and
  // the family and register it was shaped in.
  //
  // It used to be three dictionaries (label, sub, option) sharing a budget, and
  // the budget's overflow THREW ALL THREE AWAY at once - so the one key that
  // went over the line cost the whole page a re-shaping pass, mid-open. A Map
  // iterates in insertion order, which is exactly what a least-recently-used
  // eviction needs: a hit is re-inserted at the young end, and an insert past
  // the cap drops the oldest single entry and nothing else.
  //
  // The cap is per-entry accounting: one giant page files ~1870 labels, so 4096
  // holds a page's labels, subs and dropdown options with room to spare and
  // still bounds a session that walks every bundle.
  property var _shapes: new Map()
  readonly property int _metricCap: 4096

  // One shaping, cached. `produce` runs only on a miss and owns whatever probe
  // state it needs. The Map is never reassigned - only mutated - so no binding
  // can depend on it, and the pass is imperative in the first place.
  function _shape(key, produce) {
    const hit = root._shapes.get(key)
    if (hit !== undefined) {
      root._shapes.delete(key)
      root._shapes.set(key, hit)
      return hit
    }
    const value = produce()
    root._shapes.set(key, value)
    if (root._shapes.size > root._metricCap) {
      const oldest = root._shapes.keys().next()
      if (oldest.done !== true) root._shapes.delete(oldest.value)
    }
    return value
  }

  // Width measurements are only valid for the font and the palette they were
  // shaped under, and only describe the rows of one bundle generation. Both a
  // bundle swap and a theme swap drop the maps; a font change arrives with the
  // theme swap, since a theme carries the font choice. Drop the metrics and
  // re-shape the model under whatever they are about to become: a change to
  // either invalidates every measurement, and the pass does not run again until
  // the next row install - which for an open card is the next navigation, or
  // never.
  function reshapeMetrics() {
    root.clearShapeCache()
    root.recalcWidth()
  }

  // Drop the shapes. Only imperative call sites call this: nothing fills the
  // map from inside a binding, so clearing here cannot land in the middle of a
  // binding's own evaluation.
  function clearShapeCache() {
    root._shapes.clear()
  }

  Connections {
    target: Theme

    function onColorsChanged() { root.reshapeMetrics() }
  }

  // The system font lands asynchronously (a gsettings/ini probe behind
  // SystemFont.family) and every shaping here is done under it. A card measured
  // against the fallback family would keep that width once the real one
  // arrived - a few pixels short of every row - and nothing else re-runs the
  // pass until the next navigation.
  Connections {
    target: SystemFont

    function onFamilyChanged() { root.reshapeMetrics() }
  }

  function _widestStepperWidth(items) {
    let maxW = 0
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it.type !== "range" && it.type !== "number") continue
      // The same string the row's own slot shapes (see valueProbeText), so the
      // shared column is never narrower than a value it has to hold.
      measureValue.text = root.valueProbeText(it)
      maxW = Math.max(maxW, measureValue.width)
    }
    if (maxW > 0) maxW = Math.min(maxW + 6, 140)
    return maxW
  }

  // Trailing width a row reserves. This is the SAME rule the row renders
  // (Entry's trail cluster), read from the same tokens and the same shared slot
  // formula, because the card has to be as wide as the row is and the row is
  // drawn before any card has measured anything. The widgets are Ui.toggleW /
  // Ui.chevronW / Ui.optMarkW - the very properties Entry binds them to - and
  // the value columns go through MenuLib.valueSlotW with the pads and caps
  // Entry passes it. A reservation that came up short has nowhere to hide:
  // there is no floor under it, so the label elides.
  //
  // The one deliberate excess is a select's widest option rather than its
  // current one (Entry renders the current label): a value that grows when the
  // user picks a longer option must not re-cut the card under the row that
  // holds it.
  function trailWidthFor(itm) {
    switch (itm.type) {
      case "toggle":
        return Ui.toggleW
      case "submenu":
        return Ui.chevronW
      case "expandable":
        // The chevron only rides a row that has something to unfold.
        return (itm.desc !== undefined && itm.desc !== null && String(itm.desc) !== "")
          || (itm.body !== undefined && itm.body !== null && String(itm.body) !== "")
          ? Ui.chevronW : 0
      case "option":
        return Ui.optMarkW
      case "progress": {
        if (root.unifiedValueW > 0) return Ui.barW + Ui.barGap + root.unifiedValueW
        measureValue.text = "100 %"
        return Ui.barW + Ui.barGap + MenuLib.valueSlotW(0, measureValue.width, 4, 80)
      }
      case "number": {
        if (root.unifiedValueW > 0) return root.unifiedValueW
        measureValue.text = root.valueProbeText(itm)
        return MenuLib.valueSlotW(0, measureValue.width, 6, 140)
      }
      case "range": {
        if (root.unifiedValueW > 0) return Ui.barW + Ui.barGap + root.unifiedValueW
        measureValue.text = root.valueProbeText(itm)
        return Ui.barW + Ui.barGap + MenuLib.valueSlotW(0, measureValue.width, 6, 140)
      }
      case "select": {
        if (itm.var === "" && itm.onSelect !== "" && itm.onSelect !== undefined) return 0
        // Reserve for the widest option so the card never elides the value.
        let maxW = 0
        for (const o of (itm.options ?? [])) {
          measureValue.text = o.label
          maxW = Math.max(maxW, measureValue.width)
        }
        if (maxW === 0) {
          const cur = Menu.valueOf(itm)
          let label = ""
          for (const o of (itm.options ?? [])) if (o.value === cur) { label = o.label; break }
          measureValue.text = label !== "" ? label : "value"
          maxW = measureValue.width
        }
        return MenuLib.valueSlotW(0, maxW, 0, 220)
      }
      case "text": {
        // Placeholder is what an empty row shows; the stored value is what a
        // filled one shows, and it is free-form (a path, a query). Both, under
        // the cap Entry applies to the slot itself.
        const v = String(itm.placeholder ?? "")
        measureValue.text = v !== "" ? v : "value"
        const phW = measureValue.width
        const cur = Menu.valueOf(itm)
        const curS = String(cur ?? "")
        if (curS !== "") {
          measureValue.text = curS
          return MenuLib.valueSlotW(0, Math.max(phW, measureValue.width), 0, 180)
        }
        return MenuLib.valueSlotW(0, phW, 0, 180)
      }
      default:
        return 0
    }
  }

  // Card-coordinate width a select's inline dropdown needs so none of its
  // entries elides. The closed row only reserves the widest option through the
  // capped value slot (fontS, 220 cap), while OptionRow paints every entry
  // full-width at fontM: a long option fits the slot's reservation on the row
  // and still clips inside its own expansion. Shaped at OptionRow's own size,
  // through the same grid and inner margins the expansion renders (optsGrid
  // inset, option side margins, the gap kept from an optional light note).
  // Two-column dropdowns (>6 options) hold half a row per cell, so the grid
  // needs twice the widest entry plus the column gap. Input kinds need nothing:
  // their editors live in the value slot the trail already reserves.
  function _dropdownNeedW(itm) {
    const opts = itm.options ?? []
    let maxOpt = 0
    let maxLight = 0
    for (let k = 0; k < opts.length; k++) {
      const o = opts[k] ?? {}
      const label = o.label ?? String(o.value ?? "")
      const light = String(o.light ?? "")
      const shaped = root._shape("opt\u0001" + label + "\u0001" + light, () => {
        measureOptLabel.text = label
        let lw = 0
        if (light !== "") {
          measureOptLight.text = light
          lw = measureOptLight.implicitWidth
        }
        return { o: measureOptLabel.implicitWidth, l: lw }
      })
      if (shaped.o > maxOpt) maxOpt = shaped.o
      if (shaped.l > maxLight) maxLight = shaped.l
    }
    if (opts.length === 0) return 0
    // Card coordinates: rowChromeW carries the card padding, the row side
    // margins and the label spacing; the remainder is the dropdown's own chrome
    // (grid inset, option side margins, light gap) plus the text.
    if (MenuLib.optionColumnCount(opts.length) > 1)
      return root.rowChromeW() + 5 * Ui.m - Ui.s + 16 + 2 * (maxOpt + maxLight)
    return root.rowChromeW() + 2 * Ui.m - Ui.s + 8 + maxOpt + maxLight
  }

  // The width the CURRENT page declares for itself, or 0 when it declares
  // none. Read from the page record rather than cached on the card: a page's
  // own number travels with the page, and a card that remembered the previous
  // page's figure would open the next one at the wrong size.
  function declaredPageWidth() {
    // The page comes from the INSTALL, not from the navigation singleton:
    // Menu.page is a binding over pageId and still names the page being LEFT
    // inside a change handler, so asking it here sized the page being entered to
    // the one being left - back out of the idle timer list (which declares 340)
    // landed the settings page at 340 instead of its own measure. The host's
    // installedPage is written once per install, with the row set this pass is
    // measuring. The singleton is only the fallback before the first install,
    // which is the one case where there is no row set to belong to.
    const host = root.host
    const pg = host && host.installedPage ? host.installedPage
      : (typeof Menu === "undefined" ? null : Menu.page)
    if (!pg) return 0
    const w = Number(pg.width)
    return isFinite(w) && w > 0 ? w : 0
  }

  // Width the open select dropdown needs right now, or 0 when no select
  // dropdown is open. Closed rows keep the capped value-slot reservation, so
  // the card rests at the closed measure and only grows for the expansion that
  // is actually on screen - then falls back on close.
  function _openSelectNeedW() {
    // Fast path: the tracked open-slot row, exact while one row is open.
    const at = root.host._trackedOpenIdx()
    if (at >= 0) {
      const one = root.host.rowsModel[at]
      if (one && one.type === "select" && Menu.isExpanded(one)
          && Array.isArray(one.options) && one.options.length > 0)
        return root._dropdownNeedW(one)
    }
    // Otherwise (untracked, or an info row sitting beside an open dropdown)
    // take the widest open select on the page.
    let best = 0
    for (let i = 0; i < root.host.rowsModel.length; i++) {
      const it = root.host.rowsModel[i]
      if (!it || it.type !== "select" || !Menu.isExpanded(it)) continue
      if (!Array.isArray(it.options) || it.options.length === 0) continue
      const need = root._dropdownNeedW(it)
      if (need > best) best = need
    }
    return best
  }

  // Grow the card for the open dropdown, shrink it back on close. The width
  // binding clamps to the viewport and onWidthChanged arms the settle reveal,
  // so the entries unveil with the growth instead of starting a beat elided -
  // the same treatment a wider page gets.
  function applyDropdownWidth() {
    root.contentW = Math.max(root._closedContentW, root._openSelectNeedW())
  }

  // What Entry's valueMetrics shapes for a numeric row: the widest reading the
  // row can show, or its own numeric fallback when it has none. The provider's
  // display override wins over the row's own, because that is what the slot
  // renders.
  function valueProbeText(itm) {
    // The provider's widest display was resolved at install (MenuPanel's
    // rowFacts), so the width pass reads a projection rather than dispatching a
    // hook per row, per pass.
    const widest = root.host ? root.host.rowFacts(itm).widest : ""
    if (widest !== "") return widest
    return MenuLib.widestValueString(itm) || "888.88"
  }

  // What a row costs before any of its own content: the card's padding on both
  // sides, the row's side margins inside it, and the one spacing unit the label
  // column keeps clear of the trail cluster. Entry's own anchors (mainLine's
  // Ui.m margins, listBox's outerPad, labelCol's rightMargin) are the same
  // three numbers; the card adds them up per row and the row applies them one
  // by one, which is why they live in one function.
  function rowChromeW() {
    return Ui.outerPad * 2 + Ui.m * 2 + Ui.s
  }

  // The shaped font family of one row: a theme row draws its name in the font
  // it previews, which is routinely wider than the system one, and the cache is
  // keyed by family AND string for that reason.
  function rowFontFamily(itm) {
    const family = itm && typeof itm.previewFontFamily === "string" ? itm.previewFontFamily : ""
    return family !== "" ? family : Ui.fontFamily
  }

  // Key for the shaping caches. It names a string AND a family because a width
  // depends on both; a height depends on neither (RowGeometry), so this is the
  // only map keyed by a row string.
  function shapeKey(text, family) {
    return String(family) + "\u0001" + String(text)
  }

  // A page may declare its own width (settings sections, manifests, injected
  // pickers), and that number is the card's starting measure. The rows are
  // still measured: a declared figure that could not hold the page's longest
  // row would clip it, and a card is never narrower than its content. Declared
  // first, measurement only widens - which is the difference between honouring
  // a page's own number and ignoring it, as this pass used to.
  //
  // The width Behavior (see the card) smooths navigation between pages whose
  // content measures differently.
  //
  // Imperative, never a binding: measuring mutates the probes, so a declarative
  // contentW would depend on what it writes - an instant binding loop.
  function recalcWidth() {
    if (!root.host) return
    if (root.host.gridMode) {
      // A grid page has no row text to shape, and its columns are derived FROM
      // this width, so there is nothing to measure: the module default is the
      // grid's own size. Written on every grid pass so a grid summon never
      // inherits the list width of the page before it.
      root._closedContentW = Ui.defWidth
      root.contentW = Ui.defWidth
      return
    }
    const items = root.host.rowsModel
    // The page's own width, or 0 when it names none.
    const declared = root.declaredPageWidth()
    // Compute unified value-column width first so all little bars share one
    // column.
    const hasMultipleBars = items.filter(it => it && (it.type === "range" || it.type === "progress")).length >= 2
    if (hasMultipleBars) {
      root.unifiedValueW = root._widestStepperWidth(items)
      // Publish to the Menu singleton so delegates (Entry) can read it without
      // needing a direct panel reference (delegates are in a separate file).
      if (typeof Menu !== "undefined" && Menu.unifiedBarValueW !== undefined)
        Menu.unifiedBarValueW = root.unifiedValueW
    } else {
      root.unifiedValueW = 0
      if (typeof Menu !== "undefined" && Menu.unifiedBarValueW !== undefined)
        Menu.unifiedBarValueW = 0
    }
    // A giant page installs its head window only (see recomputeRows), so the
    // pass shapes at most that many rows, and every string it sees is a
    // dictionary hit the second time.
    const headN = Math.min(items.length, Ui.listFullRows)
    // SYNCHRONOUS: the card paints on the turn this runs in, and a contentW
    // that arrives a turn after that turn is a resize the user watches the
    // window do.
    //
    // The probes do not need the deferral. A Text answers implicitWidth from its
    // own content on the turn its text is assigned - a probe read cold, before
    // any layout pass, returns the same number as one read a turn later
    // ("grinning face with smiling eyes..." 476px both ways, and every other
    // string identical). What makes a cold read look unreliable is the
    // empty-page shape a deferral also produces: contentW stays 0, and 0 is
    // indistinguishable from "no rows".
    let maxRow = 0
    for (let i = 0; i < headN; i++) {
      const it = items[i]
      if (!it || !it.label) continue
      // Row chrome and icon column, both the row's own numbers (rowChromeW,
      // Ui.rowIconW). The column is reserved for an icon NAME or a glyph (the
      // emoji picker's rows), whichever Entry paints there - reserving only the
      // name left a glyph row 28px narrower than it renders, and the label
      // clipped against its own preview.
      let w = root.rowChromeW()
      if (it.icon || (it.glyph !== undefined && it.glyph !== null
        && String(it.glyph) !== "")) w += Ui.rowIconW + Ui.s
      let labelW = 0
      {
        // Shaped in the row's OWN font (rowFontFamily). Search results take
        // this path too. A per-character estimate would keep a keystroke off
        // the shaping path, and it costs correctness twice over: it guesses 7px
        // per character against a 13px font, so a result whose glyphs run wide
        // comes up short, and the 360 cap it shares with the measured branch
        // elides the longest names outright (the emoji picker: a 536px row in a
        // 420px card). Shaping a result row is a dictionary hit once the string
        // has been seen, and a miss is one Text assignment.
        const family = root.rowFontFamily(it)
        labelW = root._shape(root.shapeKey(it.label, family), () => {
          root._rowProbeFamily = family
          measureRowLabel.text = it.label
          return measureRowLabel.implicitWidth
        })
        // Sub line: lead + muted copy + trailing accent. The card must fit the
        // widest of label/sub, otherwise the subtext elides. Use the displayed
        // sub (provider override wins) so the measure matches what Entry
        // actually paints.
        // The displayed sub line was resolved at install (rowFacts), so the
        // pass shapes a string it was handed instead of asking a provider from
        // inside a measurement.
        const dispSub = root.host.rowFacts(it).sub
        const subKey = family + "\u0001" + String(it.subLead || "") + "\u0001"
          + dispSub + "\u0001" + String(it.subAccent || "")
        const subW = root._shape(subKey, () => {
          let sw = 0
          root._rowProbeFamily = family
          if (it.subLead) {
            measureRowSub.text = it.subLead
            sw += measureRowSub.implicitWidth + 4
          }
          if (dispSub !== "") {
            measureSubStyled.text = MenuLib.styledMarkup(dispSub)
            sw += measureSubStyled.implicitWidth
          }
          if (it.subAccent) {
            measureRowSub.text = it.subAccent
            sw += (sw > 0 ? 4 : 0) + measureRowSub.implicitWidth
          }
          return sw
        })
        if (subW > labelW) labelW = subW
      }
      w += labelW
      // Every search result is a link forward, so the card reserves the chevron
      // on results whatever the row's own type is (Entry reads `searchResult`,
      // not the type, to decide).
      if (root.host.searching) w += Ui.chevronW
      w += root.trailWidthFor(it)
      if (w > maxRow) maxRow = w
    }
    // Group separators / search breadcrumbs may be the widest line.
    if (!root.host.searching) {
      for (let i = 0; i < headN; i++) {
        const it = items[i]
        if (!it || it.type !== "separator") continue
        const lbl = String(it.label || "")
        if (lbl === "") continue
        root._rowProbeFamily = root.rowFontFamily(it)
        measureSepLabel.text = lbl
        const sw = measureSepLabel.implicitWidth + root.rowChromeW()
        if (sw > maxRow) maxRow = sw
      }
    }
    // The rows are installed and laid out at the card's CURRENT width before
    // this write lands, so a page whose content measures wider opens with its
    // longest copy already clipped. Arm the settle flag HERE, at the decision,
    // rather than on the first width change a turn later: the rows then reveal
    // with the growth instead of starting a beat elided.
    if (Math.abs(maxRow - root.host.width) > 0.5) root.host._armWidthSettle()
    root._closedContentW = Math.max(declared, maxRow)
    root.applyDropdownWidth()
  }
}

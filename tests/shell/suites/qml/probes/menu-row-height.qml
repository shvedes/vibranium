// Probe: is a menu row's resting height a function of its KIND, at every scale?
//
// The menu sizes its card from the model, before a single delegate exists, and
// the delegate lays the same row out for real. Those two halves agree because
// the line box is PINNED to a token (`ceil(FontMetrics.height)`) rather than
// measured per string. Two pairs exist - the primary face's and a taller
// fallback pair - and a row selects one from the script its copy draws.
//
// This probe answers the two questions that decides, with numbers:
//
//   1. Every row of every shipped bundle classifies into one kind, and the two
//      projections the menu uses - the panel's (a provider override resolved
//      at install) and the delegate's (the copy it renders) - agree on every
//      one of them.
//   2. At 1.0, 1.25, 1.5 and 2.0 font scales, the pin never gives a string more
//      than a pixel of real line less than the engine lays out, for the title,
//      the StyledText sub line and the bold separator breadcrumb; the pinned
//      line is ONE number per register; and the rest heights the shipped
//      arithmetic produces are the token arithmetic.
//
// Why a scale axis: the rule is `ceil(metrics)`, and a rule that only holds at
// the size it was written at is a constant, not a rule. A larger UI font is the
// case where a per-string measurement and a pinned token disagree most.
//
// Why the settings catalog: it is the largest bundle the shell ships, so the
// row corpus is real copy - settings labels, long sub lines, counts, theme
// names - rather than a fixture that happens to be easy.
//
// The arithmetic is asked through `features/menu/RowRule.js`, the file the
// singleton itself calls. `RowGeometry` cannot be read here: it is a singleton
// of `qs.features.menu`, and merely importing that module instantiates `Menu`,
// which needs a PanelWindow backend this probe does not have.
//
// The fixture assigns text and reads implicitHeight on the same turn, the way
// RowHeightProbe does: a probe that reads before its layout has run measures a
// placeholder, which is why the whole measurement happens on a timer.

import QtQuick
import Quickshell.Io
import qs.common
import "features/menu/MenuLib.js" as MenuLib
import "features/menu/RowRule.js" as RowRule

Item {
  id: root
  width: 800
  height: 600

  // The four scales. A font size change is the axis on which "one number per
  // font" can quietly stop being one number.
  readonly property var scales: [1.0, 1.25, 1.5, 2.0]
  // Distinct bundle strings measured at each scale, on top of the fixture.
  readonly property int sampleCap: 64

  // Strings that break a single-probe estimate: ascender/descender extremes, no
  // descenders at all, wide glyphs, a CJK face, a colour emoji face, combining
  // marks, and the two the source names ("App launcher" renders a pixel taller
  // than "Mg").
  readonly property var fixture: [
    "Mg",
    "App launcher",
    "Deep Forest",
    "Grape Soda",
    "Settings > General > Displays",
    "iiiiiii",
    "WWWW",
    "yqp gj",
    "cafe\u0301",
    "\u00c5\u00c4\u00d6",
    "12:45",
    "\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8",
    "\u0645\u0631\u062d\u0628\u0627",
    "\u0939\u093f\u0928\u094d\u0926\u0940",
    "\ud83c\udfa8 Emoji",
    "\ud83e\udde5\ud83d\udc68\u200d\ud83d\udc69\u200d\ud83d\udc67"
  ]

  property int threw: 0
  property int phase: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      root.threw++
      kv(key + ".threw", e && e.message ? e.message : e)
    }
  }

  // The probe sits in the config mirror root, so the shell tree is beside it.
  // `Qt.resolvedUrl(".")` has no trailing slash, and a path joined without one
  // is a file that does not exist - the reason this is spelled out.
  readonly property string cfgDir: {
    const base = Qt.resolvedUrl(".").toString().replace("file://", "")
    return base.charAt(base.length - 1) === "/" ? base : base + "/"
  }

  // The catalog's bytes are latched when the file loads, not read at audit
  // time: a FileView read before its load returns the empty string, and an
  // empty corpus would silently turn every row assertion below into a zero.
  property string catalogText: ""

  FileView {
    id: catalog

    path: root.cfgDir + "common/settings/catalog.jsonc"
    printErrors: false
    onLoaded: root.catalogText = catalog.text()
  }

  // Independent metrics: "the token is ceil(FontMetrics.height)" is checked
  // rather than re-asserted from the token itself.
  FontMetrics {
    id: mLabel
  }

  FontMetrics {
    id: mSub
  }

  // The fallback samples the shipped token measures, shaped the same way.
  TextMetrics {
    id: tmLabel
    font.family: Ui.fontFamily
    text: "\u0645\u0631\u062d\u0628\u0627 \u0939\u093f\u0928\u094d\u0926\u0940 \u65e5\u672c\u8a9e"
  }

  TextMetrics {
    id: tmSub
    font.family: Ui.fontFamily
    text: "\u0645\u0631\u062d\u0628\u0627 \u0939\u093f\u0928\u094d\u0926\u0940 \u65e5\u672c\u8a9e"
  }

  // Natural line boxes - what the engine lays out for a string.
  Text {
    id: natLabel

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
  }

  // Entry's muted copy is StyledText, which runs taller than PlainText on some
  // faces: the sub register is measured the way it renders.
  Text {
    id: natSub

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    textFormat: Text.StyledText
  }

  // A separator's breadcrumb is fontXs BOLD: the register whose line box the
  // pin has to cover without a bold metric of its own.
  Text {
    id: natSep

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    font.bold: true
    textFormat: Text.PlainText
  }

  // The same Texts under the pin.
  // The pin is ASSIGNED imperatively, never bound: a binding to a property this
  // probe writes in the same turn is evaluated a turn later, so the first
  // measurement would read the default line height of 0.
  Text {
    id: pinLabel

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    textFormat: Text.PlainText
    lineHeightMode: Text.FixedHeight
  }

  Text {
    id: pinSub

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    textFormat: Text.StyledText
    lineHeightMode: Text.FixedHeight
  }

  Text {
    id: pinSep

    visible: false
    width: 1
    wrapMode: Text.NoWrap
    font.family: Ui.fontFamily
    font.bold: true
    textFormat: Text.PlainText
    lineHeightMode: Text.FixedHeight
  }

  // The corpus: every row the shell's own catalog declares. The unified catalog
  // carries both the menu bundles (`menus`) and the settings pages (`pages`),
  // and the settings pages are the larger half - so both are normalized into
  // rows here rather than taking whichever one parseBundle picks.
  function collectRows() {
    const rows = []
    const text = root.catalogText
    if (!text || text === "") return rows
    let raw = null
    try {
      raw = JSON.parse(MenuLib.stripJsonc(text))
    } catch (e) {
      return rows
    }
    const pages = (raw && Array.isArray(raw.menus) ? raw.menus : [])
      .concat(raw && Array.isArray(raw.pages) ? raw.pages : [])
    for (let p = 0; p < pages.length; p++) {
      let page = null
      try {
        page = MenuLib.normalizePage(pages[p], "corpus" + p)
      } catch (e) {
        continue
      }
      for (let i = 0; i < page.items.length; i++) rows.push(page.items[i])
    }
    return rows
  }

  // One scale: pins, then measures every string natural and pinned, then asks
  // the shipped arithmetic for the rest heights.
  function auditScale(idx, sample) {
    const scale = root.scales[idx]
    const pre = "s." + idx + "."
    const labelPx = Math.max(1, Math.round(Ui.fontL * scale))
    const subPx = Math.max(1, Math.round(Ui.fontXs * scale))
    mLabel.font.pixelSize = labelPx
    mSub.font.pixelSize = subPx
    tmLabel.font.pixelSize = labelPx
    tmSub.font.pixelSize = subPx
    const primaryLabelLineH = Math.ceil(mLabel.height)
    const primarySubLineH = Math.ceil(mSub.height)
    const labelLineH = Math.ceil(Math.max(mLabel.height, tmLabel.height))
    const subLineH = Math.ceil(Math.max(mSub.height, tmSub.height))
    const common = {
      swatchH: RowRule.SWATCH_H,
      sepPadV: RowRule.SEP_PAD_V,
      bareSepH: RowRule.BARE_SEP_H,
      rowMinH: Math.max(1, Math.round(Ui.rowMinH * scale)),
      rowPadV: Math.max(0, Math.round(Ui.rowPadV * scale)),
      scale: scale
    }
    const gPrimary = Object.assign({ labelLineH: primaryLabelLineH,
      subLineH: primarySubLineH }, common)
    const g = Object.assign({ labelLineH: labelLineH, subLineH: subLineH }, common)
    kv(pre + "scale", scale)
    kv(pre + "labelPx", labelPx)
    kv(pre + "subPx", subPx)
    kv(pre + "labelLineH", labelLineH)
    kv(pre + "subLineH", subLineH)
    kv(pre + "primaryLabelLineH", primaryLabelLineH)
    kv(pre + "primarySubLineH", primarySubLineH)
    kv(pre + "rowMinH", g.rowMinH)
    kv(pre + "rowPadV", g.rowPadV)
    // The rule itself, asked the way the singleton asks it. The fallback pair
    // is the tall script token; the primary pair is what a Latin-only row
    // selects, and it is what keeps an ordinary row from taking the page's
    // tallest line.
    kv(pre + "restLine", RowRule.restH("line", g))
    kv(pre + "restSub", RowRule.restH("sub", g))
    kv(pre + "restTheme", RowRule.restH("theme", g))
    kv(pre + "restSep", RowRule.restSeparator(true, g))
    kv(pre + "restSepBare", RowRule.restSeparator(false, g))
    kv(pre + "colLine", RowRule.colH("line", g))
    kv(pre + "primaryRestLine", RowRule.restH("line", gPrimary))
    kv(pre + "primaryRestSub", RowRule.restH("sub", gPrimary))
    kv(pre + "primaryRestTheme", RowRule.restH("theme", gPrimary))
    kv(pre + "primaryRestSep", RowRule.restSeparator(true, gPrimary))
    kv(pre + "expectLine", Math.max(g.rowMinH, g.labelLineH + 2 * g.rowPadV))
    kv(pre + "expectSub", Math.max(g.rowMinH,
      g.labelLineH + 1 + g.subLineH + 2 * g.rowPadV))
    kv(pre + "expectTheme", Math.max(g.rowMinH,
      g.labelLineH + 1 + g.swatchH + 2 * g.rowPadV))
    kv(pre + "expectSep", g.subLineH + 2 * g.sepPadV)
    kv(pre + "expectPrimaryLine", Math.max(gPrimary.rowMinH,
      gPrimary.labelLineH + 2 * gPrimary.rowPadV))
    kv(pre + "expectPrimarySub", Math.max(gPrimary.rowMinH,
      gPrimary.labelLineH + 1 + gPrimary.subLineH + 2 * gPrimary.rowPadV))

    natLabel.font.pixelSize = labelPx
    natSub.font.pixelSize = subPx
    natSep.font.pixelSize = subPx
    pinLabel.font.pixelSize = labelPx
    pinSub.font.pixelSize = subPx
    pinSep.font.pixelSize = subPx
    // Assigned, not bound - see the declaration.
    pinLabel.lineHeight = labelLineH
    pinSub.lineHeight = subLineH
    pinSep.lineHeight = subLineH

    let shortLabel = 0
    let shortLabelText = ""
    let shortSub = 0
    let shortSubText = ""
    let shortSep = 0
    let measured = 0
    let pinMin = 1e9
    let pinMax = -1
    let pinSubMin = 1e9
    let pinSubMax = -1
    const natDistinct = {}
    for (let i = 0; i < sample.length; i++) {
      const text = sample[i]
      natLabel.text = text
      natSub.text = text
      natSep.text = text
      const nLabel = natLabel.implicitHeight
      const nSub = natSub.implicitHeight
      const nSep = natSep.implicitHeight
      pinLabel.text = text
      pinSub.text = text
      pinSep.text = text
      const pLabel = pinLabel.implicitHeight
      const pSub = pinSub.implicitHeight
      const pSep = pinSep.implicitHeight
      // A zero line box is a not-yet-laid-out probe, not a measurement.
      if (nLabel <= 0 || nSub <= 0 || pLabel <= 0 || pSub <= 0) continue
      measured++
      natDistinct[String(nLabel)] = true
      if (pLabel < pinMin) pinMin = pLabel
      if (pLabel > pinMax) pinMax = pLabel
      if (pSub < pinSubMin) pinSubMin = pSub
      if (pSub > pinSubMax) pinSubMax = pSub
      // Both failure directions are kept apart. A SHORTFALL means the pin
      // gives a string less line than the engine lays out - the one that can
      // clip a fallback face. A SURPLUS only reserves room a string does not
      // use.
      if (nLabel - pLabel > shortLabel) {
        shortLabel = nLabel - pLabel
        shortLabelText = text
      }
      if (nSub - pSub > shortSub) {
        shortSub = nSub - pSub
        shortSubText = text
      }
      if (nSep - pSep > shortSep) shortSep = nSep - pSep
    }
    if (measured === 0) {
      kv(pre + "measured", 0)
      return
    }
    kv(pre + "measured", measured)
    kv(pre + "natDistinct", Object.keys(natDistinct).length)
    kv(pre + "pinMin", pinMin)
    kv(pre + "pinMax", pinMax)
    kv(pre + "pinSubMin", pinSubMin)
    kv(pre + "pinSubMax", pinSubMax)
    kv(pre + "shortLabel", shortLabel)
    kv(pre + "shortLabelText", shortLabelText)
    kv(pre + "shortSub", shortSub)
    kv(pre + "shortSubText", shortSubText)
    kv(pre + "shortSep", shortSep)
  }

  function report() {
    kv("font.family", Ui.fontFamily)
    kv("ui.fontL", Ui.fontL)
    kv("ui.fontXs", Ui.fontXs)
    kv("scales", root.scales.length)
    kv("catalog.loaded", root.catalogText !== "" ? 1 : 0)
    kv("catalog.bytes", root.catalogText.length)
    const rows = root.collectRows()
    kv("rows.total", rows.length)

    // --- every row of the shipped bundle --------------------------------
    const counts = { line: 0, sub: 0, theme: 0 }
    const mismatch = []
    let unknown = 0
    const seen = {}
    const strings = []
    for (let i = 0; i < rows.length; i++) {
      const it = rows[i]
      if (!it) continue
      // The two projections the menu uses, each with the sub line it has: the
      // panel resolves a provider override (none registers in this probe), the
      // delegate renders the copy it draws.
      const panelKind = MenuLib.restKind(it, "")
      const delegateKind = MenuLib.restKind(it, String(it.sub ?? ""))
      if (panelKind !== delegateKind) mismatch.push(String(it.uid))
      if (counts[panelKind] === undefined) unknown++
      else counts[panelKind]++
      const copy = [it.label, it.sub, it.subLead, it.subAccent]
      for (let k = 0; k < copy.length; k++) {
        const v = copy[k]
        if (typeof v !== "string" || v === "") continue
        if (seen[v] === true) continue
        seen[v] = true
        strings.push(v)
      }
    }
    kv("rows.mismatch", mismatch.length)
    kv("rows.mismatch.first", mismatch.length > 0 ? mismatch[0] : "")
    kv("rows.unknown", unknown)
    kv("rows.line", counts.line)
    kv("rows.sub", counts.sub)
    kv("rows.theme", counts.theme)
    kv("rows.strings", strings.length)

    const sample = root.fixture.slice()
    for (let i = 0; i < strings.length && sample.length < root.fixture.length + root.sampleCap; i++) {
      if (root.fixture.indexOf(strings[i]) >= 0) continue
      sample.push(strings[i])
    }
    kv("sample.strings", sample.length)
    kv("sample.cap", root.fixture.length + root.sampleCap)

    // Script classification: which rows may reach a fallback face. A row that
    // does not must not pay the fallback line's height.
    kv("script.latin", RowRule.needsFallbackLine("App launcher") ? 1 : 0)
    kv("script.mgcjk", RowRule.needsFallbackLine("Mg \u65e5\u672c\u8a9e") ? 1 : 0)
    kv("script.arabic", RowRule.needsFallbackLine("\u0645\u0631\u062d\u0628\u0627") ? 1 : 0)
    kv("script.hindi", RowRule.needsFallbackLine("\u0939\u093f\u0928\u094d\u0926\u0940") ? 1 : 0)
    kv("script.emoji", RowRule.needsFallbackLine("\ud83c\udfa8 Emoji") ? 1 : 0)
    kv("script.accents", RowRule.needsFallbackLine("caf\u00e9 \u00c5\u00c4\u00d6") ? 1 : 0)

    for (let s = 0; s < root.scales.length; s++) root.auditScale(s, sample)
  }

  Timer {
    interval: 400
    running: root.phase === 0
    repeat: false
    onTriggered: {
      root.phase = 1
      root.safe("report", root.report)
      kv("threw", root.threw)
      kv("done", 1)
      console.log("##DONE##")
      root.phase = 9
    }
  }
}

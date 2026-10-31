pragma Singleton

import QtQml
import Quickshell
import qs.common
import "../math/Color.js" as Color

// Shared design tokens for ui primitives: spacing, text sizes, control
// heights and standard animation timings. Components bind through here so
// a tweak propagates without touching every consumer.
Singleton {
  id: root

  // Real screens. Placeholder screens that appear on wakeup carry an empty
  // name / 0 size and must be filtered out of every per-screen surface;
  // `validScreens` is the live Quickshell.screens view (it notifies on its
  // own, no caching beyond the property), `primaryScreen` the first valid
  // one. Every view binds the screen set through here rather than
  // re-filtering Quickshell.screens by hand.
  readonly property var validScreens: Quickshell.screens.filter(s => String(s.name ?? "") !== "" && s.width > 0)
  readonly property var primaryScreen: root.validScreens[0] ?? null
  // Screen set changes (dock/undock, wakeup): one event line so a look
  // at the journal shows which outputs the shell lays out on.

  // Spacing scale.
  readonly property int s: 8
  readonly property int m: 12
  readonly property int l: 16
  readonly property int xl: 20

  // Text scale. Dense list UIs live between fontXs and fontL.
  readonly property int fontXs: 10
  readonly property int fontS: 11
  readonly property int fontM: 12
  readonly property int fontL: 13
  // Card title (bold headline).
  readonly property int fontCardTitle: 14

  // System GTK font family, provided by SystemFont singleton.
  readonly property string fontFamily: SystemFont.family

  // Masked password echo, shared by every secret prompt (PasswordBox's
  // per-glyph display for lockscreen/polkit, InputField's native Password
  // mode for the wifi passphrase). One token so the echo reads the same
  // everywhere and changes in exactly one place.
  readonly property string passwordEcho: "*"

  // Bar icon tokens (Omarchy-style barScaleWithFont/iconSlot/iconCanvas):
  // every bar icon lives in a fixed outer slot and paints in a smaller
  // optical canvas, so all icons carry uniform visual weight and there is
  // one place to change sizing. The slot is the hit/click target - constant
  // across glyphs; the canvas is the area the glyph actually paints in.
  // When barScaleWithFont is on, both multiply by fontScale so the whole
  // bar grows coherently with the font. fontScale defaults to 1 (Vibranium
  // has no user font-size scaling yet); it is the single hook Icon.qml and
  // IconButton.qml read, so bumping it regrows slot + canvas together.
  // Sizing rule: the canvas paints at ~0.54 of the reference bar height
  // (14px on the 26px reference bar) - large enough to read at a glance,
  // small enough to leave breathing room top and bottom. The slot stays
  // larger (27) so hit targets and inter-module rhythm never shrink with
  // the glyph: to resize icons, retune the canvas against that ratio,
  // never the bar height.
  readonly property real barIconSlot: 27
  readonly property real barIconCanvas: 14
  readonly property bool barScaleWithFont: true
  readonly property real fontScale: 1

  // Control heights.
  readonly property int buttonHeight: 28
  readonly property int inputHeight: 32
  readonly property int expandMs: 140

  // Tray DBusMenu rows are pointer-only compact rows, denser than buttons
  // and menu rows alike. One token feeds the row height in TrayMenuRow and
  // the default in TrayMenu (plus its back row), so the compact rhythm
  // cannot drift between the two.
  readonly property int trayRowH: 24
  readonly property int trayListSpacing: 1

  // Row / chrome metrics (merged from MenuUi for single-token source).
  readonly property int rowMinH: 34
  readonly property int rowPadV: 7
  readonly property int barW: 54
  readonly property int barH: 6
  readonly property int barGap: 8
  readonly property int filterH: rowMinH
  // Width of the widgets a row carries on its right, and of the icon it
  // carries on its left. These are read by the WIDGET (Entry's toggle
  // pill, chevrons and option mark; the row's Icon) and by the card that
  // reserves the space for them from the model, before a single row
  // exists. Two numbers for one box is how a reservation and the row it
  // was made for drift apart and the card ends up a few pixels short of
  // the row it is sizing.
  readonly property int toggleW: 32
  readonly property int chevronW: 16
  readonly property int optMarkW: 14
  readonly property int rowIconW: 20
  readonly property int outerPad: 14
  readonly property int listTopGap: 10
  readonly property int emptyMinH: 140
  readonly property int resizeMs: 160
  readonly property int defWidth: 420
  // Card width floor. A content-sized card stops being a card somewhere
  // below this: the filter field and a row's own chrome lose the room that
  // makes them read as one surface, and a page whose rows are all short
  // (an entry page of six submenus) opens as a strip. Small enough that a
  // page sized by its rows never reaches it - it exists for the pages that
  // would otherwise open narrower than that strip.
  readonly property int cardMinW: 250
  readonly property int cardBorder: 2

  // List instantiation policy (see common/ui/List): lists with fewer
  // rows than this instantiate every delegate, so layout is exact and
  // wrap seats never traverse estimates (estimate resolution ratchets
  // originY once per lap - the growing top gap). Covers every small
  // panel (launcher ~54, clipboard ~20, pass ~50) with headroom; 4-digit
  // walls stay estimated. A cost cap in rows, the unit cost scales with.
  readonly property int listFullRows: 150
  // Buffer that always covers a small list whole: picked far above any
  // sub-150-row content (~7500px) so every delegate instantiates from
  // the first frames, no convergence through estimate updates.
  readonly property int listFullBuffer: 100000

  // Durations shared by press/expansion feedback.
  readonly property int fastMs: 120
  // Dropdown unfold velocity (see common/ui/DropdownSlot): slots open at
  // constant speed instead of constant time, so a 60px description snaps
  // in at the fastMs floor while a 400px option wall takes the slowMs
  // cap. Same OutCubic language as every other tween; the List content
  // tween already works this way (scrollVpx), slots just never got one.
  readonly property int slotVpx: 1000
  readonly property int normalMs: 180
  readonly property int slowMs: 260

  // Indicator-layer animation periods (Icons/Icon indicator framework).
  // Blink is a hard attention flash, pulse is a slow pending breathe.
  readonly property int blinkMs: 600
  readonly property int pulseMs: 1400

  // Visual helpers.
  readonly property real dimWhenEmpty: 0.4
  readonly property real disabledOpacity: 0.45
  readonly property real dimmedOpacity: 0.55

  // Palette color softened by alpha. Resolves to transparent while the
  // palette has not landed yet, so early binding passes never feed
  // Qt.alpha a void (setAlphaF nan spam); the binding re-runs on reload.
  function tint(key, a) {
    const c = Theme.color(key)
    return c === undefined ? "transparent" : Qt.alpha(c, a)
  }

  // Solid palette lookup with transparent fallback for boot frames.
  function solid(key) {
    const c = Theme.color(key)
    return c === undefined ? "transparent" : c
  }

  // The palette color that is `t` of the way from one leaf to another.
  //
  // A tint of the shell's own background by the shell's own red is a palette
  // decision, so it is made out of the palette rather than out of a color
  // chosen here: the blend follows the theme. `t` is the share of the SECOND
  // leaf - 0 is the first leaf, 1 is the second - and the result is opaque,
  // because the leaves are.
  //
  // A blend that cannot be made (a leaf that is not a color) leaves the first
  // leaf alone rather than inventing a third one.
  function mix(keyA, keyB, t) {
    const mixed = Color.mix(Theme.color(keyA), Theme.color(keyB), t)
    return mixed === "" ? root.solid(keyA) : mixed
  }

  // Alpha helper that guards void inputs (e.g. Theme.color before palette lands).
  function alpha(c, a) {
    if (c === undefined || c === "" || c === null) return "transparent"
    return Qt.alpha(c, a)
  }

  // WCAG relative luminance of a palette leaf, or null when the value is not a
  // hex color. The leaves arrive as strings off the JsonAdapter, so this parses
  // rather than reading a QColor, and it ignores alpha - which is what makes a
  // SOLID fill the only legal argument: luminance over a translucent color is
  // the luminance of whatever is behind it, which is the wallpaper.
  function luminance(c) {
    let hex = String(c === undefined || c === null ? "" : c).trim()
    if (hex.charAt(0) !== "#") return null
    hex = hex.slice(1)
    if (hex.length === 3) {
      hex = hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1) + hex.charAt(2) + hex.charAt(2)
    }
    if (!/^[0-9a-fA-F]{6}$/.test(hex)) return null
    const channel = v => {
      const n = parseInt(v, 16) / 255
      return n <= 0.03928 ? n / 12.92 : Math.pow((n + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(hex.slice(0, 2))
      + 0.7152 * channel(hex.slice(2, 4))
      + 0.0722 * channel(hex.slice(4, 6))
  }

  // The palette color that READS on top of `key`'s own solid fill.
  //
  // A filled surface inverts the relationship between a label and its
  // background, and an accent is free to land on either side of that line
  // between themes - so the answer is measured per palette rather than
  // assumed. Both candidates are the palette's own near-black and near-white,
  // which keeps this a palette decision instead of an invented color.
  //
  // The two contrast ratios are compared against each other rather than
  // against a brightness threshold: both candidates move with the theme, so a
  // threshold tuned for one palette misreads the next.
  function contrastOn(key) {
    const fill = root.luminance(Theme.color(key))
    const onFill = root.luminance(Theme.color("background_0"))
    const againstFill = root.luminance(Theme.color("foreground_0"))
    // Nothing measured: the foreground is the safe answer on an unknown fill,
    // and the real palette lands within milliseconds and rebinds.
    if (fill === null || onFill === null || againstFill === null) return root.solid("foreground_0")
    const ratio = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
    return root.solid(ratio(fill, onFill) >= ratio(fill, againstFill) ? "background_0" : "foreground_0")
  }

  // Card geometry helpers re-exported for declarative panels (no JS import needed).
  function chromeHeight(outerPad, filterH, listTopGap) {
    if (listTopGap === undefined) listTopGap = root.listTopGap
    if (filterH === undefined) filterH = root.filterH
    if (outerPad === undefined) outerPad = root.outerPad
    return 2 * outerPad + filterH + listTopGap
  }

  function availHeight(maxHeight, chromeH) {
    const v = maxHeight - chromeH
    return v > 0 ? v : 0
  }

  function cardHeight(chromeH, contentH, hardMax) {
    const v = chromeH + contentH
    return v < hardMax ? v : hardMax
  }
}

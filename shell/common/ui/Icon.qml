pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import qs.common
import "../theme/DeviceIcons.js" as DeviceIcons

// A themed icon from the shipped SVG set, always rendered at a fixed
// optical canvas inside a fixed slot so every bar icon carries uniform
// visual weight and the hit/click target stays constant across glyphs.
// The slot is the outer square (the module's implicit size); the canvas is
// the square the glyph actually paints in, centered inside it. All geometry
// comes from the bar tokens (Ui.barIconSlot / Ui.barIconCanvas), so there
// is one place to resize the whole bar.
//
// Device-pixel-ratio rasterization: the served SVG carries a large
// width/height stamp (Icons.rasterSide), so the data: URL itself decodes
// full-size and every display size only ever downscales from it - Qt
// ignores Image.sourceSize for data: URL loads on this build (measured,
// see Icons._rasterSize), so sourceSize cannot steer the decode here.
// sourceSize is still set to canvas * devicePixelRatio: it is the
// documented raster contract the suite pins (canvas times DPR, exactly),
// and it steers the decode on any source or build where the stamp does
// not. The ratio is read from the item's OWN window (bar windows can move
// screens), so a DPR change re-evaluates the binding instead of relying
// on a primary screen.
Item {
  id: root

  // Icon name in the shipped set (shell/assets/icons).
  property string name: ""
  // Fallback name chain (XDG icon-theme spellings) for toolbar glyphs:
  // the first candidate that resolves wins, "". Empty (default) keeps
  // the single `name` path above. The contract is AppIcons' own: the
  // AppIcons.url loop, memoised per (name, fallback) by
  // AppIcons itself, so no second cache lives here. A chain that
  // resolves to nothing draws nothing.
  property list<string> names: []
  // The first candidate that resolves, "" when none does (or when the
  // chain is empty and the single-name path applies).
  readonly property string namesResolved: {
    for (let i = 0; i < root.names.length; i++) {
      const hit = AppIcons.url(root.names[i], "")
      if (hit !== "") return hit
    }
    return ""
  }
  readonly property bool _useNames: root.names.length > 0
  // Palette key to recolor the SVG with (Icons.url, default foreground_0).
  property string colorKey: "foreground_0"
  // Optional second palette key for two-tone assets: colors elements
  // tagged class="indicator" with this key while the rest of the glyph
  // keeps colorKey. Empty (default) recolors the whole icon in one tone.
  // Accepts a literal #rrggbb, like colorKey.
  property string accentKey: ""
  // When true (and accentKey set and the asset carries indicator
  // elements), the indicators render on their own layer so they can
  // animate by GPU opacity without touching the base glyph. When false
  // the icon renders one static URL. The layer stays loaded once it has
  // engaged, and is hidden while the icon is not layered.
  property bool indicatorActive: false
  // Behavior override: "blink" (hard attention flash) or "pulse" (slow
  // pending breathe). Empty uses the asset's declared default class
  // (blink wins if an asset declares both). Ignored while
  // indicatorActive is false.
  property string indicatorAnim: ""
  // Tiered glyphs (volume/wifi strength): how many leading wave/arc
  // groups stay in full body tone. 0 (default) paints the whole glyph;
  // N keeps tiers 1..N solid and dims the rest to a ghost gray (see
  // assets/icons/README.md, "tier classes"). Forwarded to both layer
  // sources so a tiered glyph stays correct even if it ever combines
  // with an animated indicator.
  property int dimTiers: 0
  // Layout override: when > 0 this instance is exempt from the bar slot /
  // canvas tokens (islands and menus keep bespoke sizes) and renders at
  // exactly this logical size, still DPR-corrected. 0 means "use the tokens".
  property real size: 0

  // Shared token defaults, scaled by the common font token.
  readonly property real _defaultScale: Ui.barScaleWithFont ? Ui.fontScale : 1
  readonly property real defaultSlotSize: Math.max(12, Math.min(
    Math.round(Ui.barIconSlot * root._defaultScale), 24))
  readonly property real defaultCanvasSize: Math.max(8, Math.min(
    Math.round(Ui.barIconCanvas * root._defaultScale), root.defaultSlotSize - 6))
  property real slotSize: root.defaultSlotSize
  property real canvasSize: root.defaultCanvasSize

  // size override collapses the slot and canvas onto one bespoke value.
  readonly property real _slot: root.size > 0 ? root.size : root.slotSize
  readonly property real _canvas: root.size > 0 ? root.size : root.canvasSize

  // The containing window's DPR (its own screen - bar windows can move).
  // The QtQuick `Window` attached property resolves only once the item is
  // inside a window; until then the binding reads 1 and re-evaluates as
  // soon as the window is assigned. Window.devicePixelRatio emits a change
  // notify on its own, so moving to a screen with a different scale factor
  // re-rasterizes the SVG at the new resolution automatically.
  readonly property real _dpr: {
    const w = Window.window
    const dpr = w ? w.devicePixelRatio : 0
    return typeof dpr === "number" && isFinite(dpr) && dpr > 0 ? dpr : 1
  }

  // The asset's declared feature flags (indicator present, behaviors).
  // Empty name or an unscanned asset resolves to no features.
  readonly property var _feat: root.name !== ""
    ? (Icons._features[root.name] ?? null) : null

  // Layer mode engages only when everything is present: accent, active
  // flag, and an asset that actually has indicator elements.
  readonly property bool _layered: root.accentKey !== ""
    && root.indicatorActive && root._feat !== null && root._feat.indicator

  // Behavior resolution: explicit override wins, else the asset default
  // (blink before pulse if both declared), else pulse.
  readonly property string _anim: {
    if (!root._layered) return ""
    if (root.indicatorAnim === "blink" || root.indicatorAnim === "pulse")
      return root.indicatorAnim
    if (root._feat.blink) return "blink"
    if (root._feat.pulse) return "pulse"
    return "pulse"
  }

  // Reduced-motion gate for the indicator flash. While off, the layer renders
  // static at full opacity - the indicator keeps its accent color but never
  // flashes. This is the global switch, not a bar-local key: an undeclared
  // settings key resolves to undefined (SettingsLib drops keys the schema does
  // not name), and `undefined !== false` is always true, so a gate written that
  // way can never close.
  readonly property bool _animOn: MotionPolicy.enabled

  // Layer readiness, read off the loaded layer item: null while the layer
  // has never engaged (plain icons never load it), false while its raster
  // decodes. No reset handler is needed - an unloaded layer reads false
  // through the null guard.
  readonly property bool _layerReady: indicatorLoader.item !== null
    && indicatorLoader.item.layerReady === true
  readonly property bool ready: icon.status === Image.Ready && (!root._layered || root._layerReady)

  // The slot is the fixed outer target. Consumers size their pill (and the
  // module's hit area) from this so width never varies with the glyph.
  // Explicit geometry mirrors the implicit one so anchor-only parents
  // (island placeholders, hero rows) lay out the paint box itself rather
  // than a zero-size item whose glyph overflows it.
  implicitWidth: root._slot
  implicitHeight: root._slot
  width: root._slot
  height: root._slot

  Image {
    id: icon

    anchors.centerIn: parent
    // Keep the last-good raster painted while a new URL decodes: without
    // this every first appearance of an (icon, size, color) triple blanks
    // the slot for a frame (volume tiers, weather conditions, theme
    // swaps). Proven by offscreen probe on this Qt build: with retain,
    // the old glyph stays painted through Loading; without, the slot
    // clears to background. Stated explicitly rather than relying on the
    // data-URL async behavior: every other icon surface in the tree sets
    // it by hand.
    asynchronous: true
    retainWhileLoading: true
    // Layered mode: the base image carries only the glyph (indicators
    // forced transparent), so the indicator layer can animate above it.
    // A names chain bypasses the recolor pipeline (platform glyphs paint
    // as shipped) and takes the resolved URL.
    source: root._useNames ? root.namesResolved
      : root._layered
      ? Icons.url(root.name, root.colorKey, root.accentKey, "base", root.dimTiers)
      : Icons.url(root.name, root.colorKey, root.accentKey, "", root.dimTiers)
    // Target raster size (canvas logical * DPR). For the stamped data:
    // URLs this documents the contract rather than steering the decode
    // (see the header note); the item still paints at canvas logical px.
    sourceSize: Qt.size(root._canvas * root._dpr, root._canvas * root._dpr)
    width: root._canvas
    height: root._canvas
  }

  // Indicator layer: loads only when layered mode is first engaged and stays
  // retained afterward. Same geometry as the base image so the two rasters
  // reassemble the normal render exactly.

  // Construction audit: the base image is always instantiated (every icon
  // paints it), so the only conditional surface is the indicator layer,
  // and it loads through a Loader whose active term keeps it resident once
  // engaged. The Loader names a file URL, not an inline Component: an
  // inline Component would instantiate one wrapper object per Icon (120+
  // in the tree) for a layer only two-tone icons ever engage, while the
  // URL stores a string and compiles the shared layer file once per
  // engine on first use. The layer's inputs ride on custom Loader
  // properties below (plain bindings, no extra objects); the layer file
  // documents the contract it reads through `parent`.
  Loader {
    id: indicatorLoader

    anchors.centerIn: parent
    width: root._canvas
    height: root._canvas
    asynchronous: false
    active: root._layered || indicatorLoader.status === Loader.Ready
    source: Qt.resolvedUrl("IconIndicatorLayer.qml")

    // Forwarded into the layer (see IconIndicatorLayer.qml).
    property string iconName: root.name
    property string iconColorKey: root.colorKey
    property string iconAccentKey: root.accentKey
    property int iconDimTiers: root.dimTiers
    property bool iconLayered: root._layered
    property string iconAnim: root._anim
    property bool iconAnimOn: root._animOn
  }

  // Volume-tier helper: tiered level glyph for a 0..1 fraction, resolved
  // through the shared common/theme/DeviceIcons.js table so Icon
  // instances never hand-roll the volume thirds.
  function volumeTierIcon(volume, muted) {
    return DeviceIcons.volumeIconFor(volume, muted)
  }

  // --- debug bounds: VIBRANIUM_DEBUG_BAR_ICONS=1 ---
  // Red = outer slot (hit target), blue = optical canvas (painted content;
  // the glyph paints at exactly the canvas, so its bounds are the blue box).
  readonly property bool _debug: Quickshell.env("VIBRANIUM_DEBUG_BAR_ICONS") === "1"

  // File-sourced like the indicator layer: the env gate is read once and
  // is false in production, so an inline Component here would be a second
  // dead wrapper per icon. The Loader below is the whole production cost.
  Loader {
    active: root._debug
    anchors.fill: parent
    source: Qt.resolvedUrl("IconDebugBounds.qml")

    property real canvas: root._canvas
  }
}

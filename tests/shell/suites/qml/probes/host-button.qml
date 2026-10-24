// Probe: IslandHost and IconButton, headless, against a real event loop.
//
// IslandHost is a PanelWindow, and QT_QPA_PLATFORM=offscreen has no
// PanelWindow backend, so `IslandHost {}` cannot be constructed at all:
//
//   @common/ui/IslandHost.qml[67:1]: No PanelWindow backend loaded.
//
// What is worth testing in it is not window code: the open state machine, the
// frozen footprint cache, the key derivation, the diagnostics shape and
// positionCard's arithmetic are all plain QML on the component's own root. So
// the probe reads the real IslandHost.qml, rewrites only the window-only
// surface, and evaluates the result. Every function, the Card, the Loader and
// the Connections are the file's own bytes.
//
// Dropped, and unreachable rather than untested:
//   * the root type PanelWindow -> Item: the type does not resolve offscreen
//   * screen, color, exclusionMode, exclusiveZone, the four anchored edges and
//     WlrLayershell.*: Window-only properties, not assignable on an Item
//   * onBackingWindowVisibleChanged: a PanelWindow signal
//   * the HyprlandFocusGrab block: it dispatches a real focus grab through the
//     compositor whenever root.open is true, which a test must never do
// `visible` is KEPT - it is a real Item property here, and the same
// `root.open || card.opacity > 0` expression is what gates the real window.
//
// The rewrite reports the lines it removed and the functions that survived, and
// the driver asserts both, so a source change it no longer understands fails
// the suite instead of quietly testing something else.
//
// IconButton is an Item, so it is driven directly, with no rewrite.
//
// The pump is what makes this a test and not a snapshot: the theme palette and
// the icon scan land after boot, the open and close fades run for ~120ms, and
// the card's height tween is only observable while it is in flight. Each phase
// reports and the next runs on a later event-loop turn.

import QtQuick
import Quickshell
import qs.common

ShellRoot {
  id: root

  property int phase: 0

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function list(v) {
    return v.join(",")
  }

  function live(item) {
    return item ? "live" : "null"
  }

  // open and isOpenFor must never disagree about the served anchor, so the
  // pair is read together at every state the pump visits.
  function agree(h, key, anchor) {
    kv("ih.agree." + key, h.open === h.isOpenFor(anchor))
  }

  // alphaOf reads the alpha channel back out of a #AARRGGBB colour, so "the
  // tint applied the alpha" is an assertion and not an assumption.
  function alphaOf(c) {
    const s = String(c)
    if (!/^#[0-9a-fA-F]{8}$/.test(s)) return "not-argb:" + s
    return parseInt(s.slice(1, 3), 16) / 255
  }

  // ---- IconButton: real instances, no rewrite -------------------------

  IconButton { id: bPlain }
  IconButton { id: bIcon; name: "volume-max" }
  IconButton { id: bGlyph; glyph: "*"; slotSize: 20 }
  IconButton { id: bForce; forceHover: true; name: "wifi-3" }
  IconButton { id: bForceOff; forceHover: true; enabled: false; name: "wifi-3" }
  IconButton { id: bBright; bright: true; name: "volume-max" }
  IconButton { id: bFaint; faint: true }
  IconButton { id: bFlatBright; flat: true; bright: true; cornerRadius: 6; name: "volume-max" }
  IconButton { id: bFlat; flat: true; cornerRadius: 6; name: "wifi-3"; dimTiers: 2 }
  IconButton { id: bRounded; cornerRadius: 9 }
  IconButton { id: bSlot; slotSize: 40; iconSize: 18; name: "volume-max" }
  IconButton { id: bTween }
  IconButton { id: bTip; tipText: "hello" }
  IconButton { id: bTier0; name: "volume-max" }
  IconButton { id: bTier1; name: "volume-max"; dimTiers: 1 }
  // The soft gate: enabled, so the subtree stays in the hit-test chain and a
  // cursor can still reach the user, but not actionable, so the button
  // reports itself inert.
  IconButton { id: bInert; actionable: false; forceHover: true; name: "volume-max" }
  // Both gates at once, which must read the same as the hard lock.
  IconButton { id: bInertOff; actionable: false; enabled: false; forceHover: true; name: "volume-max" }
  IconButton { id: bClickInert; actionable: false }

  // innerButton reaches the native Ctl.Button the wrapper drives. `children` is
  // the only handle on it - the id is private to the component - and it is what
  // lets the suite read pressed, hovered, activeFocus and the background
  // rectangle the shell's own chrome lives in.
  function innerButton(b) {
    const kids = b.children
    for (let i = 0; i < kids.length; i++) {
      if (kids[i] && kids[i].contentItem !== undefined) return kids[i]
    }
    return null
  }

  function iconOf(b) {
    return root.innerButton(b).contentItem.children[0]
  }

  function glyphOf(b) {
    return root.innerButton(b).contentItem.children[1]
  }

  // The pressed state cannot be reached: AbstractButton.pressed is read-only
  // and is set by the platform's press handling, so with no compositor and no
  // window there is no API to move it. clicked() is therefore driven by
  // emitting the native signal the wrapper re-emits (onClicked:
  // root.clicked()), which covers the wrapper's wiring and a handler's
  // arity, not the platform's press-to-click mapping.
  property int clickCount: 0
  // The inert button's own counter: it has to be a separate tally, because
  // "did not fire" is only visible against a count that was already moving.
  property int inertClickCount: 0

  function reportIconButtonDefaults() {
    const nb = root.innerButton(bPlain)
    kv("ib.defaults.name", JSON.stringify(bPlain.name))
    kv("ib.defaults.colorKey", bPlain.colorKey)
    kv("ib.defaults.accentKey", JSON.stringify(bPlain.accentKey))
    kv("ib.defaults.glyph", JSON.stringify(bPlain.glyph))
    kv("ib.defaults.dimTiers", bPlain.dimTiers)
    kv("ib.defaults.bright", bPlain.bright)
    kv("ib.defaults.faint", bPlain.faint)
    kv("ib.defaults.flat", bPlain.flat)
    kv("ib.defaults.iconSize", bPlain.iconSize)
    kv("ib.defaults.slotSize", bPlain.slotSize)
    kv("ib.defaults.cornerRadius", bPlain.cornerRadius)
    kv("ib.defaults.radius", bPlain.radius)
    kv("ib.defaults.iconOpacity", bPlain.iconOpacity)
    kv("ib.defaults.animationsEnabled", bPlain.animationsEnabled)
    kv("ib.defaults.enabled", bPlain.enabled)
    kv("ib.defaults.opacity", bPlain.opacity)
    kv("ib.defaults.scale", bPlain.scale)
    kv("ib.defaults.tipText", JSON.stringify(bPlain.tipText))
    kv("ib.defaults.tipShown", bPlain._tipShown)
    kv("ib.defaults.forceHover", bPlain.forceHover)
    kv("ib.defaults.iconMode", bPlain.iconMode)
    kv("ib.defaults.targetSize", bPlain.targetSize)
    kv("ib.defaults.width", bPlain.width)
    kv("ib.defaults.height", bPlain.height)
    kv("ib.defaults.pressed", bPlain.pressed)
    kv("ib.defaults.hovered", bPlain.hovered)
    kv("ib.defaults.focused", bPlain._focused)
    kv("ib.defaults.color", String(bPlain.color))
    kv("ib.defaults.restAlpha", root.alphaOf(bPlain.color))
    kv("ib.defaults.restIsTransparent", String(bPlain.color) === "#00000000")
    kv("ib.defaults.bgColor", String(nb.background.color))
    kv("ib.defaults.bgIsGround", String(nb.background.color) === String(bPlain.color))
    kv("ib.defaults.bgRadius", nb.background.radius)
    kv("ib.defaults.bgBorderWidth", nb.background.border.width)
    kv("ib.defaults.bgBorderColor", String(nb.background.border.color))
    kv("ib.defaults.restBorder", String(nb.background.border.color) === String(Ui.tint("foreground_1", 0.4)))
    kv("ib.defaults.nativePressed", nb.pressed)
    kv("ib.defaults.nativeHovered", nb.hovered)
    kv("ib.defaults.nativeActiveFocus", nb.activeFocus)
    kv("ib.defaults.nativeFocusOnTab", nb.activeFocusOnTab)
    kv("ib.defaults.nativeFocusPolicy", nb.focusPolicy)
    kv("ib.defaults.contentItemChildren", nb.contentItem.children.length)
  }

  function reportIconButtonModes() {
    // iconMode picks between the SVG and the glyph and keys off `name` alone -
    // `glyph` is never consulted.
    kv("ib.mode.empty", bPlain.iconMode)
    kv("ib.mode.named", bIcon.iconMode)
    kv("ib.mode.glyph", bGlyph.iconMode)
    kv("ib.glyph.text.visible", root.glyphOf(bGlyph).visible)
    kv("ib.glyph.icon.visible", root.iconOf(bGlyph).visible)
    kv("ib.named.text.visible", root.glyphOf(bIcon).visible)
    kv("ib.named.icon.visible", root.iconOf(bIcon).visible)
    // The bar slot is derived from the tokens and clamped to [12, 24], so a bar
    // that grows with the font grows the slot with it.
    const slot = Math.max(12, Math.min(Math.round(Ui.barIconSlot * (Ui.barScaleWithFont ? Ui.fontScale : 1)), 24))
    kv("ib.mode.tokenSlot", root.iconOf(bIcon).defaultSlotSize)
    kv("ib.mode.tokenFormula", slot)
    kv("ib.mode.tokenMatches", root.iconOf(bIcon).defaultSlotSize === slot)
    kv("ib.mode.tokenCanvas", root.iconOf(bIcon).canvasSize)
    kv("ib.mode.canvasFormula", Math.max(8, Math.min(Math.round(Ui.barIconCanvas * (Ui.barScaleWithFont ? Ui.fontScale : 1)), root.iconOf(bIcon).defaultSlotSize - 6)))
    kv("ib.mode.canvasMatches", root.iconOf(bIcon).canvasSize === Math.max(8, Math.min(Math.round(Ui.barIconCanvas * (Ui.barScaleWithFont ? Ui.fontScale : 1)), root.iconOf(bIcon).defaultSlotSize - 6)))
    // Glyph mode keeps the legacy fixed 16px micro-button.
    kv("ib.mode.glyphTarget", bPlain.targetSize)
    kv("ib.mode.iconTarget", bIcon.targetSize)
    kv("ib.mode.slotOverridesGlyph", bGlyph.targetSize)
    kv("ib.mode.slotOverrides", bSlot.targetSize)
    kv("ib.mode.slotWins", bSlot.targetSize === bSlot.slotSize)
    kv("ib.mode.slotZeroLoses", bSlot.slotSize > 0 && bIcon.slotSize === 0)
    // iconSize paints inside the slot and never resizes it.
    kv("ib.mode.iconSizeForwards", root.iconOf(bSlot).size)
    kv("ib.mode.iconSizeKeepsSlot", bSlot.width)
    kv("ib.mode.iconSizeZeroUsesTokens", root.iconOf(bIcon).size)
    kv("ib.mode.iconNameForwards", root.iconOf(bIcon).name)
    kv("ib.mode.colorKeyForwards", root.iconOf(bIcon).colorKey)
    kv("ib.mode.dimTiersForwards", root.iconOf(bFlat).dimTiers)
  }

  function reportIconButtonInteraction() {
    const nb = root.innerButton(bPlain)
    // forceHover is the only cursor substitute there is: it paints the hovered
    // look without a pointer and must not pop the tip bubble.
    kv("ib.hover.force", bForce.hovered)
    kv("ib.hover.force.nativeStaysFalse", root.innerButton(bForce).hovered)
    kv("ib.hover.force.tipStaysHidden", bForce._tipShown)
    // The enabled gate: a disabled button must not report itself hovered or
    // pressed even with forceHover set, or a disabled island pad would paint
    // the armed look.
    kv("ib.hover.disabledHovered", bForceOff.hovered)
    kv("ib.hover.disabledPressed", bForceOff.pressed)
    kv("ib.hover.disabledEnabled", bForceOff.enabled)
    kv("ib.hover.disabledOpacity", bForceOff.opacity)
    kv("ib.hover.disabledNativeEnabled", root.innerButton(bForceOff).enabled)
    kv("ib.hover.restingHovered", bPlain.hovered)
    kv("ib.hover.restingPressed", bPlain.pressed)
    kv("ib.hover.focused", bPlain._focused)
    // The soft gate. `actionable: false` must behave like the hard lock for
    // every state the button reports, while the two gates stay distinct: the
    // native control is still enabled, because that is what keeps a cursor
    // reaching the user, and the shell's own dim is not applied, because the
    // consumer dims the control around it.
    kv("ib.hover.inertLive", bInert.live)
    kv("ib.hover.inertEnabled", bInert.enabled)
    kv("ib.hover.inertNativeEnabled", root.innerButton(bInert).enabled)
    kv("ib.hover.inertHovered", bInert.hovered)
    kv("ib.hover.inertPressed", bInert.pressed)
    kv("ib.hover.inertOpacity", bInert.opacity)
    kv("ib.hover.inertGround", String(bInert.color))
    kv("ib.hover.bothLive", bInertOff.live)
    kv("ib.hover.bothHovered", bInertOff.hovered)
    kv("ib.hover.bothDimmed", bInertOff.opacity)
    kv("ib.hover.plainIsLive", bPlain.live)
    // color is a three-step ladder, and each rung is checkable through the
    // alpha channel rather than a pinned theme value.
    kv("ib.color.rest", String(bPlain.color))
    kv("ib.color.restAlpha", root.alphaOf(bPlain.color))
    kv("ib.color.hover", String(bForce.color))
    kv("ib.color.hoverAlpha", root.alphaOf(bForce.color))
    kv("ib.color.hoverTarget", String(Ui.tint("foreground_1", 0.12)))
    kv("ib.color.hoverMatches", String(bForce.color) === String(Ui.tint("foreground_1", 0.12)))
    kv("ib.color.faint", String(bFaint.color))
    kv("ib.color.faintAlpha", root.alphaOf(bFaint.color))
    kv("ib.color.faintTarget", String(Ui.tint("foreground_1", 0.07)))
    kv("ib.color.faintMatches", String(bFaint.color) === String(Ui.tint("foreground_1", 0.07)))
    kv("ib.color.bright", String(bBright.color))
    kv("ib.color.brightAlpha", root.alphaOf(bBright.color))
    kv("ib.color.brightTarget", String(Ui.tint("accent", 0.15)))
    kv("ib.color.brightMatches", String(bBright.color) === String(Ui.tint("accent", 0.15)))
    kv("ib.color.brightDiffersFromRest", String(bBright.color) !== String(bPlain.color))
    kv("ib.color.brightDiffersFromHover", String(bBright.color) !== String(bForce.color))
    kv("ib.color.brightDiffersFromFaint", String(bBright.color) !== String(bFaint.color))
    // flat takes the border away and nothing else: the radius is untouched.
    kv("ib.flat.borderWidth", root.innerButton(bFlat).background.border.width)
    kv("ib.flat.borderWidthOff", root.innerButton(bRounded).background.border.width)
    kv("ib.flat.radius", root.innerButton(bFlat).background.radius)
    kv("ib.flat.radiusOff", root.innerButton(bRounded).background.radius)
    kv("ib.flat.color", String(bFlat.color))
    kv("ib.flat.restColor", String(bRounded.color))
    // A flat button with no focus has no border at all, so the accent can only
    // show in the fill - which is what the comment promises.
    kv("ib.flat.borderTransparent", String(root.innerButton(bFlatBright).background.border.color))
    kv("ib.flat.borderWidthBright", root.innerButton(bFlatBright).background.border.width)
    kv("ib.flat.brightFill", String(bFlatBright.color))
    // What the component's own binding asks the palette for, computed here
    // rather than pinned in the driver. IconButton.qml:72-74 resolves its
    // colours through Ui.tint(key, alpha), so the contract under test is the
    // KEY and the ALPHA - not whichever theme happens to be loaded. A literal
    // pin would fail on every palette change, which is noise rather than
    // signal.
    kv("expect.accent15", String(Ui.tint("accent", 0.15)))
    kv("expect.fg012", String(Ui.tint("foreground_1", 0.12)))
    kv("expect.fg007", String(Ui.tint("foreground_1", 0.07)))
    kv("expect.fg04", String(Ui.tint("foreground_1", 0.4)))
    kv("expect.fg07", String(Ui.tint("foreground_1", 0.7)))
    kv("expect.accentBorder", String(Ui.tint("accent", 0.45)))
    kv("expect.transparent", "transparent")
    kv("ib.flat.brightBorder", String(root.innerButton(bBright).background.border.color))
    kv("ib.flat.brightBorderIsAccent", String(root.innerButton(bBright).background.border.color) === String(Theme.color("accent")))
    // radius is an alias of cornerRadius, on the wrapper and on the chrome.
    kv("ib.radius.tracks", bRounded.radius)
    kv("ib.radius.tracksChrome", root.innerButton(bRounded).background.radius)
    bRounded.cornerRadius = 3
    kv("ib.radius.afterChange", bRounded.radius)
    kv("ib.radius.afterChangeChrome", root.innerButton(bRounded).background.radius)
    bRounded.cornerRadius = 9
    // clicked(): the native signal the wrapper re-emits.
    kv("ib.click.count", root.clickCount)
    nb.clicked()
    kv("ib.click.afterOne", root.clickCount)
    nb.clicked()
    kv("ib.click.afterTwo", root.clickCount)
    bPlain.clicked()
    kv("ib.click.afterOwnSignal", root.clickCount)
    // The soft gate is what makes an inert button inert, so a native click on
    // one must not reach the wrapper's signal. Only the native path is
    // checked: `clicked` is a plain signal and emitting it directly is a QML
    // fact, not the platform's press mapping - which is the same reason the
    // count above is driven through innerButton().
    const inertNb = root.innerButton(bClickInert)
    inertNb.clicked()
    kv("ib.click.inertNative", root.inertClickCount)
    // No composable hover for the tip: btn.hovered has no way to become true
    // here, so the bubble must stay hidden.
    kv("ib.tip.tipText", bTip.tipText)
    kv("ib.tip.shown", bTip._tipShown)
    kv("ib.tip.nativeHovered", root.innerButton(bTip).hovered)
  }

  function reportTiers() {
    kv("ic.ready", Icons.ready)
    kv("ic.indexed", Icons.indexedCount)
    kv("ic.ghostTone", root.ghostTone())
    // volume-max carries tier-1..3, wifi-3 tier-1..4.
    for (const d of [0, 1, 2, 3, 4, 9, -1]) {
      kv("ic.vol.tier" + d, root.dimmedTiers(Icons.url("volume-max", "foreground_0", "", "", d)))
    }
    for (const d of [0, 1, 2, 4]) {
      kv("ic.wifi.tier" + d, root.dimmedTiers(Icons.url("wifi-3", "foreground_0", "", "", d)))
    }
    // The forwarded end: two buttons on one asset, one tiered and one not, must
    // hand their Images different artwork for the same name and palette. The
    // Image stores `source` as a QUrl, whose string form re-encodes
    // differently from the URL Icons.url returns, so the comparison is on the
    // decoded SVG - which is the thing that differs.
    const srcOf = b => root.decodeSvg(root.iconOf(b).children[0].source)
    kv("ic.forward.zero", srcOf(bTier0) === root.decodeSvg(Icons.url("volume-max", "foreground_0", "", "", 0)))
    kv("ic.forward.one", srcOf(bTier1) === root.decodeSvg(Icons.url("volume-max", "foreground_0", "", "", 1)))
    kv("ic.forward.differs", srcOf(bTier0) !== srcOf(bTier1))
    kv("ic.forward.flatTwo", srcOf(bFlat) === root.decodeSvg(Icons.url("wifi-3", "foreground_0", "", "", 2)))
    kv("ic.forward.sameTierSameArt", srcOf(bTier0) === srcOf(bTier0))
  }

  // ---- dimTiers: the rule lives in Icons.recolor, IconButton forwards it --

  function ghostTone() {
    // Mirrors Icons._mixHex: a 50/50 mix of the body tone toward the bar
    // background, recomputed here so the assertion does not read the helper it
    // is checking.
    const a = parseInt(String(Theme.color("foreground_0")).substring(1), 16)
    const b = parseInt(String(Theme.color("background_0")).substring(1), 16)
    const ch = (sa, sb, shift) => Math.round((((sa >> shift) & 255) + ((sb >> shift) & 255)) / 2)
    const n = (ch(a, b, 16) << 16) | (ch(a, b, 8) << 8) | ch(a, b, 0)
    return "#" + n.toString(16).padStart(6, "0")
  }

  function decodeSvg(url) {
    return decodeURIComponent(String(url).replace("data:image/svg+xml;utf8,", ""))
  }

  // dimmedTiers lists the tier groups of one asset that came out in the ghost
  // tone, so "dimTiers 1 dims tiers 2 and 3" is a measurement of the recolored
  // SVG rather than a reading of the source.
  function dimmedTiers(url) {
    const ghost = root.ghostTone()
    const els = decodeSvg(url).match(/<[a-zA-Z][^>]*>/g) || []
    const out = []
    for (let i = 0; i < els.length; i++) {
      const tier = els[i].match(/class="[^"]*\btier-(\d+)\b/)
      if (tier === null) continue
      if (els[i].indexOf(ghost) >= 0) out.push(tier[1])
    }
    return out.join(",")
  }

  // ---- IslandHost stand-ins: the bar window and the anchors ------------

  // A bar module is an Item carrying moduleId (set by Group/Zone) and barWindow
  // (set by BarView.wireModule). positionCard maps the anchor through
  // barWindow.contentItem and reads barWindow.height, so the stand-in has to be
  // a real Item (mapToItem needs a real item chain) wrapped in an object that
  // answers the window-shaped reads. Quickshell.screens[0] is the single
  // virtual screen offscreen provides.
  Item {
    id: barContent
    width: 800
    height: 40
    QtObject {
      id: barWin
      property var screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
      property Item contentItem: barContent
      property int height: 40
    }
  }

  Item {
    id: anchorVolume
    property string moduleId: "volume"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 100
    y: 5
  }

  Item {
    id: anchorWifi
    property string moduleId: "wifi"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 400
    y: 5
  }

  // Same slot id as anchorVolume, different object, far enough right that the
  // card has to be clamped away from the screen edge.
  Item {
    id: anchorVolumeTwin
    property string moduleId: "volume"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 700
    y: 5
  }

  // An anchor before Group/Zone has wired it: no moduleId, no barWindow.
  Item {
    id: anchorBare
    width: 30
    height: 30
    x: 10
    y: 5
  }

  // Two more slots, for the shared-Component case: neither host has ever
  // frozen them, so a missing entry is unambiguous.
  Item {
    id: anchorShared
    property string moduleId: "shared"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 200
    y: 5
  }
  Item {
    id: anchorSharedTwin
    property string moduleId: "shared-twin"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 260
    y: 5
  }

  // A slot the main host never serves, for the self-animating content.
  Item {
    id: anchorSelf
    property string moduleId: "self"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 320
    y: 5
  }

  // A slot only the second host ever serves, to show two footprint stores do
  // not see each other.
  Item {
    id: anchorSecond
    property string moduleId: "second-only"
    property var barWindow: barWin
    width: 30
    height: 30
    x: 500
    y: 5
  }

  // Forty distinct slots, for the eviction bound. Built at runtime rather than
  // from a Repeater: under this Quickshell a Repeater reports count 5 with an
  // empty children list and itemAt() returning null, so a delegate-based
  // source of anchors would silently hand the probe nulls.
  property var floodAnchors: []

  function buildFloodAnchors() {
    for (let i = 0; i < 40; i++) {
      const a = Qt.createQmlObject("import QtQuick\nItem {\n"
        + "  property string moduleId: \"slot-" + i + "\"\n"
        + "  property var barWindow: root.barWinRef\n"
        + "  width: 20\n  height: 20\n}\n", root, "flood_anchor_" + i + ".qml")
      root.floodAnchors.push(a)
    }
  }

  function floodAnchor(i) {
    return root.floodAnchors[i]
  }

  readonly property var barWinRef: barWin
  readonly property bool motionEnabled: MotionPolicy.enabled

  Component {
    id: compWide
    Item {
      property int islandContentWidth: 300
      property int islandContentHeight: 140
    }
  }

  Component {
    id: compTall
    Item {
      property int islandContentWidth: 220
      property int islandContentHeight: 90
    }
  }

  // Content that declares itself self-animating opts out of the card's height
  // tween, so its own animation is the only easing.
  Component {
    id: compSelf
    Item {
      property int islandContentWidth: 260
      property int islandContentHeight: 70
      property bool islandSelfAnimating: true
    }
  }

  // ---- the headless IslandHost -----------------------------------------

  property string hostSource: ""
  property int hostSourceStatus: 0
  property int dropCount: 0
  property int grabLines: 0
  property string droppedLines: ""
  property string keptFunctions: ""
  property string hostText: ""
  property var hosts: []
  property int opacityLandedAt: 0
  property int heightLandedAt: 0
  property bool sawMidFade: false
  property var h1: null
  property var h2: null
  property var h3: null
  property var h4: null
  property var cardXBeforeNull: -1
  property int h1CountBeforeSecond: -1

  function readSource() {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", "common/ui/IslandHost.qml", false)
    xhr.send()
    root.hostSourceStatus = xhr.status
    root.hostSource = xhr.responseText || ""
  }

  // headless() performs the rewrite and records what it removed, so the driver
  // can hold the rewrite to the file it is rewriting.
  function headless() {
    const lines = root.hostSource.split("\n")
    const kept = []
    const dropped = []
    let grab = 0
    let inGrab = false
    let inVisibilityHandler = false
    let depth = 0
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i]
      if (/^PanelWindow \{$/.test(l)) {
        kept.push("Item {")
        continue
      }
      if (/^  HyprlandFocusGrab \{$/.test(l)) {
        inGrab = true
        depth = 1
        grab = 1
        continue
      }
      if (inGrab) {
        depth += (l.match(/\{/g) || []).length
        depth -= (l.match(/\}/g) || []).length
        if (depth <= 0) inGrab = false
        grab++
        continue
      }
      if (/^  onBackingWindowVisibleChanged: \{$/.test(l)) {
        inVisibilityHandler = true
        depth = 1
        dropped.push(l.trim())
        continue
      }
      if (inVisibilityHandler) {
        depth += (l.match(/\{/g) || []).length
        depth -= (l.match(/\}/g) || []).length
        dropped.push(l.trim())
        if (depth <= 0) inVisibilityHandler = false
        continue
      }
      if (/^  (screen|color|exclusionMode|exclusiveZone):/.test(l)
        || /^  anchors\.(top|bottom|left|right):/.test(l)
        || /^  WlrLayershell\./.test(l)) {
        dropped.push(l.trim())
        continue
      }
      kept.push(l)
    }
    const text = kept.join("\n")
      // The one import that has to move: the rewritten file is evaluated from
      // the config root, not from common/ui.
      .replace('import "../collections/FrozenFootprint.js" as FP',
        'import "common/collections/FrozenFootprint.js" as FP')
   
    const fns = []
    const re = /^[ \t]*function ([A-Za-z_][A-Za-z0-9_]*)/gm
    let m = re.exec(text)
    while (m !== null) {
      fns.push(m[1])
      m = re.exec(text)
    }
    return {
      text: text,
      dropped: dropped.sort(),
      dropCount: dropped.length,
      grabLines: grab,
      functions: fns.sort()
    }
  }

  function makeHost(name) {
    const h = Qt.createQmlObject(root.hostText, root, "headless_island_host_" + name + ".qml")
    h.width = 800
    h.height = 800
    root.hosts.push(h)
    return h
  }

  function reportRewrite() {
    kv("hl.sourceStatus", root.hostSourceStatus)
    kv("hl.sourceLen", root.hostSource.length)
    kv("hl.sourceIsPanelWindow", /^PanelWindow \{/m.test(root.hostSource))
    kv("hl.rootTypeIsItem", /^Item \{/m.test(root.hostText))
    kv("hl.droppedCount", root.dropCount)
    kv("hl.droppedLines", root.droppedLines)
    kv("hl.grabLines", root.grabLines)
    kv("hl.functions", root.keptFunctions)
    kv("hl.keepsLoader", root.hostText.indexOf("id: cardLoader") >= 0)
    kv("hl.keepsCard", root.hostText.indexOf('objectName: "islandCard"') >= 0)
    kv("hl.keepsSaveCall", root.hostText.indexOf("FP.save(root._footprint, root._key, w, h)") >= 0)
    kv("hl.keepsCapacityBind", root.hostText.indexOf("FP.create(root.frozenCapacity)") >= 0)
    kv("hl.keepsVisible", root.hostText.indexOf("visible: root.open || card.opacity > 0") >= 0)
    kv("hl.keepsPositionCard", root.hostText.indexOf("function positionCard()") >= 0)
    kv("hl.keepsKeyFor", root.hostText.indexOf("function _keyFor(anchor)") >= 0)
    kv("hl.dropsGrab", !/^  HyprlandFocusGrab \{/m.test(root.hostText))
    kv("hl.dropsLayershell", root.hostText.indexOf("WlrLayershell") < 0)
  }

  // ---- the pump ---------------------------------------------------------
  Timer {
    id: pump
    interval: 12
    repeat: true
    running: true
    onTriggered: {
      root.phase++
      root.step(root.phase)
    }
  }

  // One function per phase, each on its own event-loop turn. The schedule is
  // paced by the real durations rather than by guesswork: the card's opacity
  // tween is Ui.fastMs (120ms, about eight turns here), the Glide on its
  // height runs longer than that, and the icon's ColorAnim is still climbing
  // long after both - so every landing read sits clear of its tween.
  function step(n) {
    root.trackTweens(n)
    if (n === 1) onFirst()
    else if (n === 2) onSecond()
    else if (n === 3) onThird()
    else if (n >= 4 && n <= 10) onFade(n)
    else if (n === 11) onSettled()
    else if (n === 12) onSettledStable()
    else if (n >= 13 && n <= 17) onResizeMid(n)
    else if (n === 18) onResizeLanded()
    else if (n === 19) onPosition()
    else if (n === 20) onMargin()
    else if (n === 21) onMarginRead()
    else if (n === 22) onBottom()
    else if (n === 23) onBottomRead()
    else if (n === 24) onClampRead()
    else if (n >= 25 && n <= 34) onClosingSettle(n)
    else if (n === 35) onClosed()
    else if (n === 36) onToggleOpen()
    else if (n === 37) onToggleShut()
    else if (n === 38) onToggleOther()
    else if (n === 39) onNullComponent()
    else if (n === 40) onNullAnchor()
    else if (n === 41) onNullAnchorClosed()
    else if (n >= 42 && n <= 50) onClosingSettle(n)
    else if (n === 51) onKeyDerivation()
    else if (n === 52) onRejectedSize()
    else if (n === 53) onRejectedSizeRead()
    else if (n === 54) onRejectedSizeNegative()
    else if (n === 55) onSharedComponent()
    else if (n === 56) onSharedComponentClose()
    else if (n >= 57 && n <= 65) onClosingSettle(n)
    else if (n === 66) onSharedClosed()
    else if (n === 67) onSecondHost()
    else if (n >= 68 && n <= 76) onClosingSettle(n)
    else if (n === 77) onSecondHostRead()
    else if (n === 78) onFloodStart()
    else if (n >= 79 && n <= 118) onFloodTurn(n - 79)
    else if (n === 119) onFloodResult()
    else if (n === 120) onFinish()
  }

  // The turn each of the card's two opening tweens lands on. The finding this
  // suite records is a relationship between them - the height tween outlives
  // the opacity tween - and a relationship is what a turn index measures
  // without depending on how fast this host's event loop turns.
  function trackTweens(n) {
    if (!root.h1 || !root.h1.card) return
    if (root.opacityLandedAt === 0 && root.h1.card.opacity === 1) root.opacityLandedAt = n
    if (root.heightLandedAt === 0 && root.h1.card.height === 140) root.heightLandedAt = n
  }

  // The fade, sampled turn by turn. The evidence that the grow is a tween and
  // not a slow measurement is the no-motion control on the same turn: the same
  // component, the same content, animationsEnabled false, and it is already at
  // its final size and full opacity.
  function onFade(n) {
    const h = root.h1
    if (h.card.opacity < 1 && h.card.height < 140) root.sawMidFade = true
    kv("ih.fade.t" + n + ".content", root.live(h.content))
    kv("ih.fade.t" + n + ".opacity", h.card.opacity)
    kv("ih.fade.t" + n + ".opacityStrict", h.card.opacity > 0 && h.card.opacity < 1)
    kv("ih.fade.t" + n + ".height", h.card.height)
    kv("ih.fade.t" + n + ".heightStrict", h.card.height > 0 && h.card.height < 140)
    kv("ih.fade.t" + n + ".noMotionHeight", root.h3.card.height)
    kv("ih.fade.t" + n + ".selfHeight", root.h2.card.height)
    // The self-animating content declares 70, so "mid-glide" is a range, not a
    // value: the sampled height depends on the turn spacing, which is the
    // host's, not the component's.
    kv("ih.fade.t" + n + ".selfStrict", root.h2.card.height > 0 && root.h2.card.height < 70)
    if (n === 4) {
      // The icon hover tween starts here and is sampled on the next turns.
      kv("ib.tween.start", String(root.innerButton(bTween).background.color))
      kv("ib.tween.target", String(Ui.tint("foreground_1", 0.12)))
      kv("ib.tween.targetAlpha", root.alphaOf(Ui.tint("foreground_1", 0.12)))
      kv("ib.tween.motion", MotionPolicy.enabled)
      bTween.forceHover = true
      kv("ib.tween.ground", String(bTween.color))
      kv("ib.tween.hovered", bTween.hovered)
    } else if (n <= 7) {
      const bg = String(root.innerButton(bTween).background.color)
      kv("ib.tween.mid" + n, bg)
      kv("ib.tween.mid" + n + "Alpha", root.alphaOf(bg))
      kv("ib.tween.ground" + n, String(bTween.color))
    }
  }

  // ---- phases ------------------------------------------------------------

  Component.onCompleted: {
    kv("probe.error", "none")
    try {
      bPlain.clicked.connect(function () { root.clickCount++ })
      bClickInert.clicked.connect(function () { root.inertClickCount++ })
      root.readSource()
      const info = root.headless()
      root.hostText = info.text
      root.dropCount = info.dropCount
      root.droppedLines = root.list(info.dropped)
      root.grabLines = info.grabLines
      root.keptFunctions = root.list(info.functions)
      root.reportRewrite()
      root.h1 = root.makeHost("main")
      root.h2 = root.makeHost("second")
      root.h3 = root.makeHost("nomotion")
      root.h4 = root.makeHost("flood")
      // The no-motion control: the same component, the same content, the same
      // first open, with every tween switched off.
      root.h3.animationsEnabled = false
      root.buildFloodAnchors()
      kv("hl.floodAnchors", root.floodAnchors.length)
      kv("hl.floodKey0", root.floodAnchors.length > 0 ? root.floodAnchors[0].moduleId : "none")
      kv("hl.floodKey39", root.floodAnchors.length > 39 ? root.floodAnchors[39].moduleId : "none")
      kv("hl.floodDistinct", (function () {
        const seen = {}
        for (let i = 0; i < root.floodAnchors.length; i++) seen[root.floodAnchors[i].moduleId] = true
        return Object.keys(seen).length
      })())
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    root.reportIconButtonDefaults()
    root.reportIconButtonModes()
  }

  function onFirst() {
    const h = root.h1
    try {
      kv("ih.built", h !== null)
      kv("ih.capacity", h.frozenCapacity)
      kv("ih.open.initial", h.open)
      kv("ih.isOpenFor.initial", h.isOpenFor(anchorVolume))
      kv("ih.barPosition.default", h.barPosition)
      kv("ih.margin.default", h.margin)
      kv("ih.tokenS", Ui.s)
      kv("ih.anchorItem.default", root.live(h.anchorItem))
      kv("ih.contentComponent.default", root.live(h.contentComponent))
      kv("ih.content.default", root.live(h.content))
      kv("ih.key.default", h._key)
      kv("ih.animationsEnabled.default", h.animationsEnabled)
      kv("ih.motionEnabled", root.motionEnabled)
      kv("ih.diag.keys", Object.keys(h.diagnostics()).sort().join(","))
      const d = h.diagnostics()
      kv("ih.diag.count", d.count)
      kv("ih.diag.capacity", d.capacity)
      kv("ih.diag.key", d.key)
      kv("ih.diag.contentLive", d.contentLive)
      kv("ih.diag.active", String(d.active))
      kv("ih.diag.keysList", d.keys.join(","))
      kv("ih.diag.cardWidth", d.cardWidth)
      kv("ih.diag.cardHeight", d.cardHeight)
      // The key is the opener's slot id, with "default" as the fallback.
      kv("ih.key.volume", h._keyFor(anchorVolume))
      kv("ih.key.wifi", h._keyFor(anchorWifi))
      kv("ih.key.twin", h._keyFor(anchorVolumeTwin))
      kv("ih.key.bare", h._keyFor(anchorBare))
      kv("ih.key.null", h._keyFor(null))
      kv("ih.key.distinct", h._keyFor(anchorVolume) !== h._keyFor(anchorWifi))
      kv("ih.key.stable", h._keyFor(anchorVolume) === h._keyFor(anchorVolume))
      kv("ih.key.twinsCollide", h._keyFor(anchorVolume) === h._keyFor(anchorVolumeTwin))
      kv("ih.key.foreignItem", h._keyFor(barContent))
      // An unseen key has no footprint at all.
      kv("ih.frozen.unseenW", h._frozenW("volume"))
      kv("ih.frozen.unseenH", h._frozenH("volume"))
      kv("ih.frozen.unseenDefaultW", h._frozenW("default"))
      // Screen anchoring: a wired anchor resolves the bar window's screen, an
      // unwired one resolves to null and neither throws.
      kv("ih.screen.count", Quickshell.screens.length)
      kv("ih.screen.name", JSON.stringify(Quickshell.screens[0] ? Quickshell.screens[0].name : null))
      kv("ih.screen.width", Quickshell.screens[0] ? Quickshell.screens[0].width : -1)
      kv("ih.screen.height", Quickshell.screens[0] ? Quickshell.screens[0].height : -1)
      kv("ih.screen.bareIsNull", h.anchorScreen() === null)
      kv("ih.screen.grabBare", h.grabWindows().length)
      h.show(anchorVolume, compWide)
      root.h3.show(anchorWifi, compWide)
      kv("ih.screen.wired", h.anchorScreen() === Quickshell.screens[0])
      kv("ih.screen.wiredTruthy", h.anchorScreen() !== null)
      kv("ih.screen.grabWired", h.grabWindows().length)
      root.agree(h, "afterShow", anchorVolume)
    } catch (e) {
      kv("probe.error", "phase1: " + (e && e.message ? e.message : e))
    }
  }

  function onSecond() {
    const h = root.h1
    try {
      // One turn after show: the state machine has already moved, the Loader
      // has incubated, and the card's width - which has no Behavior - is
      // already final while its height is still climbing.
      kv("ih.show.open", h.open)
      kv("ih.show.key", h._key)
      kv("ih.show.anchor", h.anchorItem === anchorVolume)
      kv("ih.show.comp", h.contentComponent === compWide)
      kv("ih.show.content", root.live(h.content))
      kv("ih.show.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.show.isOpenForWifi", h.isOpenFor(anchorWifi))
      kv("ih.show.isOpenForTwin", h.isOpenFor(anchorVolumeTwin))
      kv("ih.show.isOpenForBare", h.isOpenFor(anchorBare))
      kv("ih.show.isOpenForNull", h.isOpenFor(null))
      kv("ih.show.cardWidth", h.card.width)
      kv("ih.show.cardHeightInFlight", h.card.height > 0 && h.card.height < 140)
    } catch (e) {
      kv("probe.error", "phase2: " + (e && e.message ? e.message : e))
    }
  }

  function onThird() {
    const h = root.h1
    try {
      // Two turns in, the content is live and the card is growing. The
      // Behavior on height is documented to make the very first size evaluation
      // a snap so the window maps at its final size (IslandHost.qml:256-266);
      // it is not one. h3 is the same first open with animationsEnabled false
      // and h2 is one whose content declares itself self-animating, which the
      // same gate is meant to exempt. All three are read on the same turn.
      kv("ih.fade.content", root.live(h.content))
      kv("ih.fade.noMotion.opacity", root.h3.card.opacity)
      kv("ih.fade.noMotion.height", root.h3.card.height)
      kv("ih.fade.noMotion.snapped", root.h3.card.height === 140 && root.h3.card.opacity === 1)
      kv("ih.fade.noMotion.content", root.live(root.h3.content))
      root.h2.show(anchorSelf, compSelf)
      kv("ih.fade.selfOpen", root.h2.open)
      kv("ih.fade.selfKey", root.h2._key)
    } catch (e) {
      kv("probe.error", "phase3: " + (e && e.message ? e.message : e))
    }
  }

  function onSettled() {
    const h = root.h1
    try {
      kv("ih.settled.opacity", h.card.opacity)
      kv("ih.settled.height", h.card.height)
      kv("ih.settled.width", h.card.width)
      kv("ih.settled.liveWidth", h.content ? h.content.islandContentWidth : -1)
      kv("ih.settled.liveHeight", h.content ? h.content.islandContentHeight : -1)
      kv("ih.settled.frozenW", h._frozenW("volume"))
      kv("ih.settled.frozenH", h._frozenH("volume"))
      kv("ih.settled.count", h.diagnostics().count)
      kv("ih.settled.contentLive", h.diagnostics().contentLive)
      kv("ih.settled.diag", JSON.stringify(h.diagnostics()))
      kv("ih.fade.sawMidFade", root.sawMidFade)
      kv("ih.fade.opacityLandedAt", root.opacityLandedAt)
      kv("ih.fade.heightLandedAt", root.heightLandedAt)
      root.agree(h, "settled", anchorVolume)
    } catch (e) {
      kv("probe.error", "phase11: " + (e && e.message ? e.message : e))
    }
  }

  function onSettledStable() {
    const h = root.h1
    try {
      kv("ih.settled.stable", h.card.height)
      kv("ih.settled.opacityStable", h.card.opacity)
      // A resize while the island is fully open is the grow the tween is for,
      // and the gate is satisfied here: opacity is 1 and the host is open.
      h.content.islandContentHeight = 400
      kv("ih.resize.requested", h.content.islandContentHeight)
    } catch (e) {
      kv("probe.error", "phase12: " + (e && e.message ? e.message : e))
    }
  }

  function onResizeMid(n) {
    const h = root.h1
    try {
      kv("ih.resize.t" + n + ".height", h.card.height)
      kv("ih.resize.t" + n + ".strict", h.card.height > 140 && h.card.height < 400)
      // The footprint is written from the live measurement the moment the
      // content resizes, not when the tween lands.
      kv("ih.resize.t" + n + ".frozen", h._frozenH("volume"))
      kv("ih.resize.t" + n + ".widthUnchanged", h.card.width)
    } catch (e) {
      kv("probe.error", "phase13-17: " + (e && e.message ? e.message : e))
    }
  }

  function onResizeLanded() {
    const h = root.h1
    try {
      kv("ih.resize.landed", h.card.height)
      kv("ih.resize.landedFrozen", h._frozenH("volume"))
      kv("ih.resize.landedFrozenW", h._frozenW("volume"))
      kv("ih.resize.landedOpacity", h.card.opacity)
    } catch (e) {
      kv("probe.error", "phase18: " + (e && e.message ? e.message : e))
    }
  }

  function onPosition() {
    const h = root.h1
    try {
      // positionCard parks the card under the module: for a top bar y is the
      // bar height plus the margin, x is the anchor's centre less half the
      // card, and both are clamped away from the screen edges by that margin.
      kv("ih.pos.cardX", h.card.x)
      kv("ih.pos.cardY", h.card.y)
      kv("ih.pos.width", h.card.width)
      kv("ih.pos.height", h.card.height)
      kv("ih.pos.barHeight", barWin.height)
      kv("ih.pos.expectedX", Math.max(Ui.s, Math.min(100 + 15 - 300 / 2, 800 - 300 - Ui.s)))
      kv("ih.pos.expectedY", Math.max(Ui.s, Math.min(40 + Ui.s, 800 - 400 - Ui.s)))
      root.reportTiers()
      root.reportIconButtonInteraction()
    } catch (e) {
      kv("probe.error", "phase19: " + (e && e.message ? e.message : e))
    }
  }

  function onMargin() {
    const h = root.h1
    try {
      // The margin is the only spacing term positionCard reads, and it is a
      // public property, so a runtime change is the interesting case. The
      // component re-parks on open, anchor and barPosition changes but has no
      // onMarginChanged, so this one does not move the card by itself.
      h.margin = 20
      kv("ih.margin.changed", h.margin)
    } catch (e) {
      kv("probe.error", "phase20: " + (e && e.message ? e.message : e))
    }
  }

  function onMarginRead() {
    const h = root.h1
    try {
      kv("ih.margin.cardY", h.card.y)
      kv("ih.margin.cardX", h.card.x)
      // The Glide from the resize above is asymptotic, so the card only reaches
      // its declared size well after the tween's nominal duration.
      kv("ih.resize.settled", h.card.height)
      // A barPosition change does re-park, and then the new margin is what the
      // park reads - so the margin is a real term in the derived offset.
      h.barPosition = "bottom"
      kv("ih.margin.positionFlip", h.barPosition)
    } catch (e) {
      kv("probe.error", "phase21: " + (e && e.message ? e.message : e))
    }
  }

  function onBottom() {
    const h = root.h1
    try {
      kv("ih.bottom.cardY", h.card.y)
      kv("ih.bottom.cardX", h.card.x)
      kv("ih.bottom.expectedY", Math.max(20, Math.min(800 - 40 - 400 - 20, 800 - 400 - 20)))
      kv("ih.bottom.expectedYMargin8", Math.max(8, Math.min(800 - 40 - 400 - 8, 800 - 400 - 8)))
      h.margin = Ui.s
      kv("ih.bottom.marginRestored", h.margin)
    } catch (e) {
      kv("probe.error", "phase22: " + (e && e.message ? e.message : e))
    }
  }

  function onBottomRead() {
    const h = root.h1
    try {
      // The card keeps the offset the previous park produced, which is the
      // other half of the missing margin handler.
      kv("ih.bottom.yAfterMarginRestore", h.card.y)
      kv("ih.resize.settledExact", h.card.height === 400)
      kv("ih.resize.settledValue", h.card.height)
      h.barPosition = "top"
      kv("ih.restore.position", h.barPosition)
      // A module near the right edge pushes the card off it, so the margin is
      // also the clamp.
      h.show(anchorVolumeTwin, compWide)
      kv("ih.clamp.anchor", h.anchorItem === anchorVolumeTwin)
    } catch (e) {
      kv("probe.error", "phase23: " + (e && e.message ? e.message : e))
    }
  }

  function onClampRead() {
    const h = root.h1
    try {
      kv("ih.clamp.cardX", h.card.x)
      kv("ih.clamp.cardY", h.card.y)
      kv("ih.clamp.expectedX", Math.max(Ui.s, Math.min(700 + 15 - 300 / 2, 800 - 300 - Ui.s)))
      kv("ih.clamp.isOpenForTwin", h.isOpenFor(anchorVolumeTwin))
      kv("ih.clamp.isOpenForVolume", h.isOpenFor(anchorVolume))
      h.close()
      kv("ih.close.open", h.open)
      kv("ih.close.isOpenForTwin", h.isOpenFor(anchorVolumeTwin))
      kv("ih.close.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.close.key", h._key)
      // The content outlives the close on purpose: the Loader stays active
      // through the fade so items do not vanish mid-animation.
      kv("ih.close.contentStillLive", root.live(h.content))
      kv("ih.close.compKept", h.contentComponent === compWide)
      kv("ih.close.cardHeight", h.card.height)
      root.agree(h, "afterClose", anchorVolumeTwin)
    } catch (e) {
      kv("probe.error", "phase24: " + (e && e.message ? e.message : e))
    }
  }

  function onClosingSettle(n) {
    const h = root.h1
    kv("ih.settle.t" + n + ".content", root.live(h.content))
    kv("ih.settle.t" + n + ".opacity", h.card.opacity)
    kv("ih.settle.t" + n + ".opacityStrict", h.card.opacity > 0 && h.card.opacity < 1)
    kv("ih.settle.t" + n + ".cardWidth", h.card.width)
    kv("ih.settle.t" + n + ".cardHeight", h.card.height)
    if (n === 34) {
      // The icon hover tween, long settled: the ground is the target and the
      // chrome has caught up with it.
      kv("ib.tween.landed", String(root.innerButton(bTween).background.color))
      kv("ib.tween.landedAlpha", root.alphaOf(root.innerButton(bTween).background.color))
      kv("ib.tween.landedIsTarget", String(root.innerButton(bTween).background.color) === String(Ui.tint("foreground_1", 0.12)))
      kv("ib.tween.groundLanded", String(bTween.color))
      // Releasing forceHover puts the ground back, so the tween is a change
      // and not a one-way paint.
      bForce.forceHover = false
      kv("ib.tween.releasedHovered", bForce.hovered)
      kv("ib.tween.releasedColor", String(bForce.color))
    }
  }

  function onClosed() {
    const h = root.h1
    try {
      kv("ih.closed.opacity", h.card.opacity)
      kv("ih.closed.content", root.live(h.content))
      kv("ih.closed.compStillSet", h.contentComponent === compWide)
      // The headline footprint contract: a closed host keeps the size its
      // content had, read from the frozen store rather than from a live item.
      kv("ih.closed.frozenW", h._frozenW("volume"))
      kv("ih.closed.frozenH", h._frozenH("volume"))
      kv("ih.closed.cardWidth", h.card.width)
      kv("ih.closed.cardHeight", h.card.height)
      kv("ih.closed.count", h.diagnostics().count)
      kv("ih.closed.contentLive", h.diagnostics().contentLive)
      kv("ih.closed.diagKey", h.diagnostics().key)
      kv("ih.closed.diagCardW", h.diagnostics().cardWidth)
      kv("ih.closed.diagCardH", h.diagnostics().cardHeight)
      kv("ih.closed.otherKeyW", h._frozenW("wifi"))
      kv("ih.closed.otherKeyH", h._frozenH("wifi"))
    } catch (e) {
      kv("probe.error", "phase35: " + (e && e.message ? e.message : e))
    }
  }

  function onToggleOpen() {
    const h = root.h1
    try {
      kv("ih.toggle.closedBefore", h.open)
      h.toggle(anchorWifi, compTall)
      kv("ih.toggle.opened", h.open)
      kv("ih.toggle.isOpenForWifi", h.isOpenFor(anchorWifi))
      kv("ih.toggle.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.toggle.key", h._key)
      root.agree(h, "afterToggleOpen", anchorWifi)
    } catch (e) {
      kv("probe.error", "phase36: " + (e && e.message ? e.message : e))
    }
  }

  function onToggleShut() {
    const h = root.h1
    try {
      kv("ih.toggle.openBefore", h.open)
      h.toggle(anchorWifi, compTall)
      kv("ih.toggle.shut", h.open)
      kv("ih.toggle.shutIsOpenFor", h.isOpenFor(anchorWifi))
      // A toggle for a different anchor on an open host switches rather than
      // closes: only one island is ever open, so the second press is a show.
      h.show(anchorWifi, compTall)
      kv("ih.toggle.switch.open", h.open)
      kv("ih.toggle.switch.isOpenForWifi", h.isOpenFor(anchorWifi))
      h.toggle(anchorVolume, compWide)
      kv("ih.toggle.switch.key", h._key)
      kv("ih.toggle.switch2.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.toggle.switch2.isOpenForWifi", h.isOpenFor(anchorWifi))
      h.close()
    } catch (e) {
      kv("probe.error", "phase37: " + (e && e.message ? e.message : e))
    }
  }

  function onToggleOther() {
    const h = root.h1
    try {
      kv("ih.toggle2.closed", h.open)
      kv("ih.toggle2.frozenWifiW", h._frozenW("wifi"))
      kv("ih.toggle2.frozenWifiH", h._frozenH("wifi"))
      kv("ih.toggle2.frozenVolumeW", h._frozenW("volume"))
      kv("ih.toggle2.frozenVolumeH", h._frozenH("volume"))
    } catch (e) {
      kv("probe.error", "phase38: " + (e && e.message ? e.message : e))
    }
  }

  function onNullComponent() {
    const h = root.h1
    try {
      root.cardXBeforeNull = h.card.x
      // A null component is what a module passes when it has nothing to show.
      // It must not throw, and it must not leave the previous content loaded.
      h.show(anchorVolume, null)
      kv("ih.nullComp.noThrow", true)
      kv("ih.nullComp.open", h.open)
      kv("ih.nullComp.content", root.live(h.content))
      kv("ih.nullComp.comp", root.live(h.contentComponent))
      kv("ih.nullComp.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.nullComp.key", h._key)
      // With no content live the card sizes from the frozen store, which is the
      // whole point of freezing it.
      kv("ih.nullComp.cardWidth", h.card.width)
      kv("ih.nullComp.cardHeight", h.card.height)
      kv("ih.nullComp.frozenW", h._frozenW("volume"))
      kv("ih.nullComp.frozenH", h._frozenH("volume"))
      root.agree(h, "afterNullComp", anchorVolume)
    } catch (e) {
      kv("probe.error", "phase39: " + (e && e.message ? e.message : e))
    }
  }

  function onNullAnchor() {
    const h = root.h1
    try {
      // A null anchor is a show() before the module wiring lands. The key falls
      // back to "default" and the screen resolves to null, but the state
      // machine must still work and positionCard must stay a no-op.
      h.show(null, compTall)
      kv("ih.nullAnchor.noThrow", true)
      kv("ih.nullAnchor.open", h.open)
      kv("ih.nullAnchor.key", h._key)
      kv("ih.nullAnchor.isOpenForNull", h.isOpenFor(null))
      kv("ih.nullAnchor.isOpenForVolume", h.isOpenFor(anchorVolume))
      kv("ih.nullAnchor.screen", h.anchorScreen() === null)
      kv("ih.nullAnchor.grab", h.grabWindows().length)
      kv("ih.nullAnchor.anchor", root.live(h.anchorItem))
      kv("ih.nullAnchor.content", root.live(h.content))
      kv("ih.nullAnchor.cardXUnchanged", h.card.x === root.cardXBeforeNull)
      kv("ih.nullAnchor.cardX", h.card.x)
      root.agree(h, "afterNullAnchor", null)
    } catch (e) {
      kv("probe.error", "phase40: " + (e && e.message ? e.message : e))
    }
  }

  function onNullAnchorClosed() {
    const h = root.h1
    try {
      kv("ih.nullAnchor.count", h.diagnostics().count)
      kv("ih.nullAnchor.defaultW", h._frozenW("default"))
      kv("ih.nullAnchor.defaultH", h._frozenH("default"))
      kv("ih.nullAnchor.volumeW", h._frozenW("volume"))
      kv("ih.nullAnchor.volumeH", h._frozenH("volume"))
      kv("ih.nullAnchor.wifiW", h._frozenW("wifi"))
      kv("ih.nullAnchor.wifiH", h._frozenH("wifi"))
      kv("ih.nullAnchor.active", String(h.diagnostics().active))
      h.close()
    } catch (e) {
      kv("probe.error", "phase41: " + (e && e.message ? e.message : e))
    }
  }

  function onKeyDerivation() {
    const h = root.h1
    try {
      kv("ih.derive.distinct", h._keyFor(anchorVolume) !== h._keyFor(anchorWifi))
      kv("ih.derive.twinCollapses", h._keyFor(anchorVolume) === h._keyFor(anchorVolumeTwin))
      kv("ih.derive.bareIsDefault", h._keyFor(anchorBare) === "default")
      kv("ih.derive.nullIsDefault", h._keyFor(null) === "default")
      let seen = {}
      for (let i = 0; i < 40; i++) seen[h._keyFor(root.floodAnchor(i))] = true
      kv("ih.derive.fortyDistinctKeys", Object.keys(seen).length)
    } catch (e) {
      kv("probe.error", "phase51: " + (e && e.message ? e.message : e))
    }
  }

  function onRejectedSize() {
    const h = root.h1
    try {
      // A collapsed measurement must be refused rather than frozen: a zero
      // width would collapse every later open of that slot.
      h.show(anchorVolume, compWide)
      kv("ih.reject.open", h.open)
      kv("ih.reject.content", root.live(h.content))
      kv("ih.reject.beforeW", h._frozenW("volume"))
      kv("ih.reject.beforeH", h._frozenH("volume"))
      h.content.islandContentWidth = 0
      kv("ih.reject.zeroWidthSet", h.content.islandContentWidth)
      kv("ih.reject.liveWidth", h.card.width)
    } catch (e) {
      kv("probe.error", "phase52: " + (e && e.message ? e.message : e))
    }
  }

  function onRejectedSizeRead() {
    const h = root.h1
    try {
      kv("ih.reject.frozenWAfterZero", h._frozenW("volume"))
      kv("ih.reject.frozenHAfterZero", h._frozenH("volume"))
      kv("ih.reject.countAfterZero", h.diagnostics().count)
      // Same for a negative height: typeof -5 is "number" and isFinite(-5), so
      // only the positivity check can catch it.
      h.content.islandContentWidth = 300
      h.content.islandContentHeight = -5
      kv("ih.reject.negativeSet", h.content.islandContentHeight)
    } catch (e) {
      kv("probe.error", "phase53: " + (e && e.message ? e.message : e))
    }
  }

  function onRejectedSizeNegative() {
    const h = root.h1
    try {
      kv("ih.reject.frozenHAfterNegative", h._frozenH("volume"))
      kv("ih.reject.frozenWAfterNegative", h._frozenW("volume"))
      h.content.islandContentHeight = 140
      kv("ih.reject.restored", h.content.islandContentHeight)
    } catch (e) {
      kv("probe.error", "phase54: " + (e && e.message ? e.message : e))
    }
  }

  function onSharedComponent() {
    const h = root.h1
    try {
      // Two slots served by ONE component: the Loader keeps the live item, so
      // the content object never changes and only _key moves.
      h.show(anchorShared, compTall)
      kv("ih.shared.openShared", h.open)
      kv("ih.shared.isOpenForShared", h.isOpenFor(anchorShared))
      kv("ih.shared.keyShared", h._key)
      h.show(anchorSharedTwin, compTall)
      kv("ih.shared.keyTwin", h._key)
      kv("ih.shared.isOpenForTwin", h.isOpenFor(anchorSharedTwin))
      kv("ih.shared.isOpenForSharedAfter", h.isOpenFor(anchorShared))
      kv("ih.shared.content", root.live(h.content))
    } catch (e) {
      kv("probe.error", "phase55: " + (e && e.message ? e.message : e))
    }
  }

  function onSharedComponentClose() {
    const h = root.h1
    try {
      // The live card tracks the content, so while it is open it looks right...
      kv("ih.shared.cardWidth", h.card.width)
      kv("ih.shared.cardHeight", h.card.height)
      // ...but the twin's slot was never frozen, because _saveFrozen only runs
      // on a content change or a content size change and neither happened.
      kv("ih.shared.frozenSharedW", h._frozenW("shared"))
      kv("ih.shared.frozenTwinW", h._frozenW("shared-twin"))
      kv("ih.shared.count", h.diagnostics().count)
      h.close()
    } catch (e) {
      kv("probe.error", "phase56: " + (e && e.message ? e.message : e))
    }
  }

  function onSharedClosed() {
    const h = root.h1
    try {
      // With the content gone, the twin's card has nothing to size from.
      kv("ih.shared.closedTwinW", h.card.width)
      kv("ih.shared.closedTwinH", h.card.height)
      kv("ih.shared.closedSharedW", h._frozenW("shared"))
      kv("ih.shared.closedContent", root.live(h.content))
      kv("ih.shared.closedKey", h._key)
      kv("ih.shared.closedCount", h.diagnostics().count)
    } catch (e) {
      kv("probe.error", "phase66: " + (e && e.message ? e.message : e))
    }
  }

  function onSecondHost() {
    const h1 = root.h1
    const h2 = root.h2
    try {
      // Two hosts, one probe: opening one must not move the other, and their
      // footprint stores are separate objects.
      kv("ih.inst.h1Open", h1.open)
      kv("ih.inst.h2Open", h2.open)
      kv("ih.inst.h1Key", h1._key)
      kv("ih.inst.h2Key", h2._key)
      kv("ih.inst.separateStores", h1._footprint !== h2._footprint)
      kv("ih.inst.h1CountBefore", h1.diagnostics().count)
      kv("ih.inst.h2CountBefore", h2.diagnostics().count)
      root.h1CountBeforeSecond = h1.diagnostics().count
      h2.show(anchorSecond, compWide)
      kv("ih.inst.h2Opened", h2.open)
      kv("ih.inst.h1OpenAfter", h1.open)
    } catch (e) {
      kv("probe.error", "phase67: " + (e && e.message ? e.message : e))
    }
  }

  function onSecondHostRead() {
    const h1 = root.h1
    const h2 = root.h2
    try {
      kv("ih.inst.h1CountAfter", h1.diagnostics().count)
      kv("ih.inst.h1CountUnchanged", h1.diagnostics().count === root.h1CountBeforeSecond)
      kv("ih.inst.h2CountAfter", h2.diagnostics().count)
      kv("ih.inst.h2KeyAfter", h2._key)
      // A slot only the second host has served: present there, absent here.
      kv("ih.inst.h2FrozenSecondOnly", h2._frozenW("second-only"))
      kv("ih.inst.h1FrozenSecondOnly", h1._frozenW("second-only"))
      kv("ih.inst.h2FrozenSelf", h2._frozenW("self"))
      kv("ih.inst.h1FrozenSelf", h1._frozenW("self"))
      kv("ih.inst.h1Content", root.live(h1.content))
      kv("ih.inst.h2Content", root.live(h2.content))
      kv("ih.inst.h1IsOpenForShared", h1.isOpenFor(anchorShared))
      kv("ih.inst.h2IsOpenForSecond", h2.isOpenFor(anchorSecond))
      h2.close()
      root.h3.close()
      kv("ih.inst.h3Closed", !root.h3.open)
    } catch (e) {
      kv("probe.error", "phase77: " + (e && e.message ? e.message : e))
    }
  }

  function onFloodStart() {
    const f = root.h4
    try {
      kv("ih.flood.capacity", f.frozenCapacity)
      kv("ih.flood.diagKeys", Object.keys(f.diagnostics()).sort().join(","))
      kv("ih.flood.startCount", f.diagnostics().count)
      kv("ih.flood.startKey", f._key)
      kv("ih.flood.open", f.open)
    } catch (e) {
      kv("probe.error", "phase78: " + (e && e.message ? e.message : e))
    }
  }

  // One anchor per event-loop turn. The Loader only recreates the content when
  // the component actually changes, so alternating two components is what makes
  // each show() write a new footprint under its own key.
  function onFloodTurn(i) {
    const f = root.h4
    try {
      f.show(root.floodAnchor(i), i % 2 === 0 ? compWide : compTall)
      if (i === 30 || i === 31 || i === 32 || i === 33) {
        const d = f.diagnostics()
        kv("ih.flood.countAfter" + i, d.count)
        kv("ih.flood.boundAfter" + i, d.count <= d.capacity)
        kv("ih.flood.oldestAfter" + i, d.keys.length > 0 ? d.keys[0] : "")
        kv("ih.flood.newestAfter" + i, d.keys.length > 0 ? d.keys[d.keys.length - 1] : "")
        kv("ih.flood.newestWAfter" + i, f._frozenW("slot-" + i))
      }
    } catch (e) {
      kv("probe.error", "flood" + i + ": " + (e && e.message ? e.message : e))
    }
  }

  function onFloodResult() {
    const f = root.h4
    try {
      const d = f.diagnostics()
      kv("ih.flood.finalCount", d.count)
      kv("ih.flood.finalCapacity", d.capacity)
      kv("ih.flood.finalWithinBound", d.count <= d.capacity)
      kv("ih.flood.finalAtBound", d.count === f.frozenCapacity)
      kv("ih.flood.finalKeysCount", d.keys.length)
      kv("ih.flood.finalActive", d.active)
      kv("ih.flood.newestRetained", d.keys.length > 0 ? d.keys[d.keys.length - 1] : "")
      kv("ih.flood.oldestRetained", d.keys.length > 0 ? d.keys[0] : "")
      kv("ih.flood.newestW", f._frozenW("slot-39"))
      kv("ih.flood.newestH", f._frozenH("slot-39"))
      kv("ih.flood.oldestRetainedW", f._frozenW("slot-8"))
      kv("ih.flood.firstEvictedW", f._frozenW("slot-0"))
      kv("ih.flood.lastEvictedW", f._frozenW("slot-7"))
      kv("ih.flood.keptSlot8W", f._frozenW("slot-8"))
      kv("ih.flood.finalDiagKeys", Object.keys(f.diagnostics()).sort().join(","))
      f.close()
    } catch (e) {
      kv("probe.error", "phase119: " + (e && e.message ? e.message : e))
    }
  }

  function onFinish() {
    try {
      kv("probe.phases", root.phase)
      kv("ic.readyFinal", Icons.ready)
      kv("ic.indexedFinal", Icons.indexedCount)
      kv("ic.cacheSize", Icons.cacheSize())
    } catch (e) {
      kv("probe.error", "finish: " + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }
}

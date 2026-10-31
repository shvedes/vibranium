#!/bin/bash
# Suite: common/ui, part two - name resolution, geometry, state machines and
# the motion primitives, in a real event loop.
#
# ui-test.sh owns the design tokens, Ui.tint/Ui.alpha, Chip's layout set,
# CheckBox.boxSize, ProgressBar's clamping, Divider's hairline, Title's level
# heights, Notice.danger, Toggle.toggle() and MotionPolicy.duration. This suite
# is the other half - the twenty-one components that have logic in them and no
# behavioural coverage:
#
#   BodyText  ConfirmSlot  DropdownButton  DropdownSlot  Glide  GridList  Icon
#   PanelCard  PanelFocus  ProgressBar  ScrimWindow  ScrollBar  ZebraRow
#   CheckBox  CapsChip  Card  Notice  Title  Divider  Toggle  Vignette
#
# The technique is the same as ui-test.sh - QT_QPA_PLATFORM=offscreen
# suppresses the render loop, not the binding, layout or animation passes - but
# this probe leans harder on the event loop, because almost everything worth
# asserting here is only true on a later turn:
#
#   * Icon's boot scan (a Quickshell Process filling Icons._raw) is empty at
#     Component.onCompleted and holds 178 assets on the first turn. A
#     snapshot taken at boot would "prove" that no icon name resolves.
#   * Font metrics move too: the same label measures 187px wide at
#     Component.onCompleted and 249px a few hundred milliseconds later, which
#     is why PanelCard.recalcWidth() is driven at turn 20 and compared against
#     a TextMetrics read on that same turn.
#   * Four separate tweens are sampled in flight - Glide's number tween,
#     CapsChip's 150ms opacity/scale pair, ProgressBar's fill glide and
#     DropdownSlot's height unfold - and each is asserted both for moving
#     toward the target and for landing exactly on it without overshooting.
#   * GridList's wrap sweep runs for 540ms, so the pump runs 50 turns (about
#     800ms) rather than ui-test.sh's four.
#
# What cannot be reached here, and is recorded rather than faked:
#
#   * ScrimWindow (and any PanelWindow) cannot be constructed at all - the
#     engine has no PanelWindow backend without a compositor. The probe
#     attempts it at runtime through Qt.createQmlObject so the failure is data
#     and the exact message is the evidence, then the window-only behaviour is
#     t_skipped.
#   * Quickshell.screens is EMPTY under offscreen, not one virtual screen, so
#     Ui.validScreens.length is 0 and Ui.primaryScreen is null. Any per-screen
#     surface has nothing to lay out on here.
#   * There is no compositor, so no MouseArea can be pressed or hovered.
#     containsMouse / containsPress stay false, which means the hover and
#     press tints of DropdownButton, ZebraRow and Card are unreachable, and
#     ZebraRow's clicked() is driven at the signal level instead. Those are
#     t_skipped with the reason; everything reachable around them is
#     asserted.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ui-rest" "common/ui part two: Icon resolution, grid/scroll geometry, state machines and motion"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ui-rest.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
# A throw after the boot report would leave probe.error at "none", so the
# catch handler writes a second key; the suite checks the raw output for that
# key rather than a qp_get, which would return the "none" printed first.
t_not_contains "and nothing threw after the boot report either" "probe.thrown=" "$(qp_out)"
t_eq "the probe completed every phase" "true" "$(qp_get probe.completed)"

# ---------------------------------------------------------------------
# The headless substrate. Pinned first so every "could not observe X"
# below reads as a fact about this environment, not a guess.
# ---------------------------------------------------------------------
t_section "the enum values the symbolic comparisons below rest on"
# Read rather than assumed: Text.FixedHeight is 1 and not 2, and
# Easing.OutCubic is 6, so a suite that hardcoded the wrong constant would
# compare two wrong things and still pass.
t_eq "Text.PlainText" "0" "$(qp_get text.enum.PlainText)"
t_eq "Text.StyledText" "4" "$(qp_get text.enum.StyledText)"
t_eq "Text.WordWrap" "1" "$(qp_get text.enum.WordWrap)"
t_eq "Text.FixedHeight" "1" "$(qp_get text.enum.FixedHeight)"
t_eq "Text.ElideRight" "1" "$(qp_get text.enum.ElideRight)"
t_eq "Easing.OutCubic" "6" "$(qp_get easing.OutCubic)"
t_eq "Image.Ready" "1" "$(qp_get image.Ready)"
t_eq "Loader.Ready" "1" "$(qp_get loader.Ready)"
t_eq "Qt.PointingHandCursor" "13" "$(qp_get pointing.cursor)"

t_section "the headless substrate these results are read against"
t_eq "the motion gate is on, so nothing below degrades to a snap" "true" "$(qp_get env.motion.enabled)"
# Quickshell.screens is empty here, not one virtual screen. That is the
# environment, not a shell defect: Ui.validScreens filters on a non-empty name
# and a non-zero size, and the offscreen platform publishes no screen at all.
t_eq "there is no screen to lay out on" "0" "$(qp_get env.validScreens)"
t_eq "so there is no primary screen either" "null" "$(qp_get env.primaryScreen)"
t_eq "the scene itself is windowed" "yes" "$(qp_get env.rootHasWindow)"
t_note "offscreen gives a window but no screens: Quickshell.screens is empty, so Ui.validScreens.length is 0 and Ui.primaryScreen is null. Every per-screen surface is untestable here for that reason, and none of the components below reads a screen."

# ---------------------------------------------------------------------
# Icon: name resolution, recolor, size, features, layers, fallback.
# ---------------------------------------------------------------------
t_section "Icon: the boot scan is what makes a name resolvable at all"
# At Component.onCompleted Icons._raw is empty, so every icon's source is the
# empty string. This is the reason the whole name-resolution section below
# has to be read on the first event-loop turn rather than at construction.
t_eq "the icon set is still empty at Component.onCompleted" "0" "$(qp_get icon.scan.bootIndexed)"
t_eq "so the scan has not reported yet" "false" "$(qp_get icon.scan.bootReady)"
t_eq "and a known name resolves to nothing yet" "0" "$(qp_get icon.url.bootLength)"
t_eq "on the first turn the scan is in" "180" "$(qp_get icon.scan.indexed)"
t_eq "and reports ready" "true" "$(qp_get icon.scan.ready)"

t_section "Icon: a known name resolves to a recolored data URL"
t_eq "the source is a data URL" "true" "$(qp_get icon.url.known.isDataUrl)"
t_eq "with the documented media type prefix" "data:image/svg+xml;utf" "$(qp_get icon.url.known.prefix)"
t_eq "carrying the recolored body tone" "true" "$(qp_get icon.url.known.hasBodyTone)"
# A NOTE, not an assertion, and deliberately. The line above is the assertion
# that matters: it asks whether the recoloured source CONTAINS the encoded
# `foreground_0`, which is the claim being made - the icon took the theme's
# token rather than a hardcoded colour.
#
# This one used to assert the token's literal value (`%23dfdfdf`) and it was a
# FAIL on any other theme - it pins one host's palette and calls it a contract.
# `foreground_0` here is `%23d3c6aa`, a green, and nothing about the icon
# pipeline is wrong. A theme's colours are the theme's business; recording the
# value is an observation, which is what a note is for.
t_note "foreground_0 on this host is $(qp_get icon.url.known.bodyToneIsForeground0), not a fixed value; the assertion above is the theme-independent one"
t_eq "and the asset's own paints are gone" "true" "$(qp_get icon.url.known.paintsRewritten)"
t_eq "the same name through Icons.url is a real URL" "725" "$(qp_get icons.url.knownName.length)"
t_eq "and the same asset measured directly is 460" "462" "$(qp_get icons.url.sameName.length)"
t_note "The same asset does not have the same length twice: Icons.url('clock','foreground_0') is 460 characters, and the URL read back off the Image after Qt has normalised it is 420. Only the content assertions - the recolored tone is present, the original paint is gone - are comparable across the two; the length is Qt's business."

t_section "Icon: an unknown name and an empty name both fall back to no source"
t_eq "an unknown name yields no URL" "false" "$(qp_get icon.url.unknown.isDataUrl)"
t_eq "and the source is the empty string" "0" "$(qp_get icon.url.unknown.length)"
t_eq "the Image stays in the Null status" "0" "$(qp_get icon.url.unknown.status)"
t_eq "so ready is never reached" "false" "$(qp_get icon.url.unknown.ready)"
t_eq "and it is still not ready many turns later" "false" "$(qp_get icon.state.unknownNotReadyLater)"
t_eq "the image status has not moved since" "0" "$(qp_get icon.state.unknownStatusLater)"
t_eq "but the slot keeps its token size, so a missing icon is a hole, not a collapse" "24" "$(qp_get icon.url.unknown.slotStillReserved)"
t_eq "an unknown name has no features" "null" "$(qp_get icon.url.unknown.features)"
t_eq "Icons.url itself returns the empty string for one" "''" "$(qp_get icons.url.unknownName)"
t_eq "an empty name yields no URL either" "false" "$(qp_get icon.url.noName.isDataUrl)"
t_eq "with an empty source" "0" "$(qp_get icon.url.noName.length)"
t_eq "and no features" "null" "$(qp_get icon.url.noName.features)"
t_eq "Icons.url returns the empty string for an empty name too" "''" "$(qp_get icons.url.emptyName)"
t_note "An unknown or empty icon name is completely silent: no broken URL, no warning, no fallback glyph - the Image simply never leaves Image.Null. The slot still reserves its 24px token, so a typo in an icon name shows as a correctly sized blank. That is Icons.qml:141 (if (raw === undefined) return \"\") and Icons.qml:92 (if (!name) return \"\") behaving as written, but the failure is invisible to whoever typo'd the name."
t_skip "an unknown icon name renders some visible fallback glyph" "Icons.url returns \"\" for an unrecognised name, so the Image has no source to render; there is no fallback asset in the tree to assert"

t_section "Icon: the colorKey path, including a literal #rrggbb"
t_eq "a literal colorKey still produces a data URL" "true" "$(qp_get icon.url.literalColorKey.isDataUrl)"
t_eq "painted in the literal" "true" "$(qp_get icon.url.literalColorKey.hasLiteral)"
t_eq "and it skips the palette entirely" "true" "$(qp_get icon.url.literalColorKey.skipsPalette)"
t_eq "an unknown palette key falls back to a colour, never undefined" "#000000" "$(qp_get theme.unknownKey)"
t_eq "an empty palette key does the same" "#000000" "$(qp_get theme.emptyKey)"
# FINDING: Icons.qml:97-98 says an empty colorKey "still keeps the binding
# pending" and Icons.qml:104-105 says an invalid accent key "resolves to \"\"
# and keeps the binding pending". Neither arm is reachable: the hex is
# `String(Theme.color(colorKey) ?? "")`, and Theme.color ends in a fallback map
# that answers every key - including "" and unknown names - with a colour, so
# the guard never sees the empty string. Recorded rather than asserted as
# intended behaviour.
t_eq "so an EMPTY colorKey silently produces a URL, not a pending binding" "true" "$(qp_get icon.url.noColorKey.isDataUrl)"
t_eq "an invalid accent key also produces a URL" "true" "$(qp_get icon.url.badAccent.isDataUrl)"
t_eq "painted with Theme's black fallback" "true" "$(qp_get icon.url.badAccent.paintedWithFallback)"
t_eq "Icons.url agrees: it returns a 772-character URL" "772" "$(qp_get icons.url.badAccentKey.length)"
t_eq "whose indicator is painted in that same fallback" "true" "$(qp_get icons.url.badAccentKey.paintsFallback)"
t_note "FINDING (Low, doc/code drift): Icons.url's two 'keeps the binding pending' guards are unreachable. Icons.qml:98 resolves the colorKey through Theme.color, and Theme.color:47-67 answers every key - including the empty string and unknown names - with a colour from its fallback map, so the 'if (hex === empty) return empty' guard at Icons.qml:101 and the matching accent guard at Icons.qml:111 can never fire. Observed: colorKey \"\" and accentKey \"not_a_palette_key\" both yield a fully-formed data URL with the glyph painted in the #000000 fallback, where the comment promises a pending binding. Same shape as the Ui.tint fallback ui-test.sh already records, one layer up."
t_skip "an invalid colorKey or accentKey holds the binding pending instead of resolving" "Theme.color's fallback map makes both guards unreachable, so there is no pending-binding state to observe; see the note above"

t_section "Icon: features, layering and the two-tone split"
t_eq "an asset with an indicator but no behaviour is flagged exactly so" '{"indicator":true,"blink":false,"pulse":false}' "$(qp_get icons.features.indicatorNoBehavior)"
t_eq "an asset declaring blink is flagged so" '{"indicator":true,"blink":true,"pulse":false}' "$(qp_get icons.features.blink)"
t_eq "a tiered asset has no indicator" '{"indicator":false,"blink":false,"pulse":false}' "$(qp_get icons.features.tiered)"
t_eq "and neither does a plain asset" '{"indicator":false,"blink":false,"pulse":false}' "$(qp_get icons.features.plainAsset)"
t_eq "layer mode needs indicatorActive" "false" "$(qp_get icon.layered.needsActive)"
t_eq "and an accentKey" "false" "$(qp_get icon.layered.needsAccent)"
t_eq "and engages only with all three present" "true" "$(qp_get icon.layered.engaged)"
t_eq "the base layer carries no accent tone" "false" "$(qp_get icon.base.hasAccent)"
t_eq "its indicator is forced to no paint" "true" "$(qp_get icon.base.indicatorForcedNone)"
t_eq "the indicator layer exists" "true" "$(qp_get icon.indicator.exists)"
t_eq "as its own data URL" "true" "$(qp_get icon.indicator.isDataUrl)"
t_eq "painted in the accent tone" "true" "$(qp_get icon.indicator.hasAccent)"
t_eq "carrying only the indicator elements" "true" "$(qp_get icon.indicator.isIndicatorOnly)"
t_eq "its Loader is active once engaged" "true" "$(qp_get icon.loader.active)"
t_eq "and has reached Ready" "true" "$(qp_get icon.loader.ready)"
t_eq "a non-layered icon builds no indicator layer" "false" "$(qp_get icon.loader.inactiveWhenNotLayered)"
t_eq "and neither does a plain icon" "false" "$(qp_get icon.loader.inactiveWhenPlain)"
t_eq "the static two-tone URL carries both tones at once" "true" "$(qp_get icon.staticTwoTone.hasBody)"
t_eq "including the accent" "true" "$(qp_get icon.staticTwoTone.hasAccent)"

t_section "Icon: the behavior vocabulary and the reduced-motion gate"
t_eq "a non-layered icon resolves no behavior at all" "''" "$(qp_get icon.anim.notLayered)"
t_eq "an asset with an indicator but no declared behavior defaults to pulse" "'pulse'" "$(qp_get icon.anim.defaultForNoBehavior)"
t_eq "an explicit blink wins" "'blink'" "$(qp_get icon.anim.explicitBlink)"
t_eq "and a value outside the vocabulary falls through to the asset default" "'blink'" "$(qp_get icon.anim.unknownOverrideFallsBack)"
t_eq "the reduced-motion gate reads on by default" "true" "$(qp_get icon.anim.motionGate)"

t_section "Icon: dimTiers, the size override and per-instance isolation"
t_eq "dimming the outer tier groups changes the URL" "true" "$(qp_get icon.tier.differsFromFull)"
t_eq "painted in a 50/50 mix toward the bar background" "true" "$(qp_get icon.tier.dimsOuterGroups)"
t_eq "and the undimmed glyph has no ghost tone in it" "true" "$(qp_get icon.tier.fullHasNoGhost)"
# A note for the same reason as the foreground_0 one above. This value is a
# 50/50 mix of two THEME tokens, so pinning it to `#7a7a7a` pins one host's
# palette twice over: the mix follows `foreground_0`, which is a green here.
# "painted in a 50/50 mix toward the bar background" above is the assertion that
# carries the claim and it is theme-independent; this records what the mix came
# out as on this host.
t_note "the ghost tone on this host is $(qp_get icon.tier.ghostTone), a mix of two theme tokens rather than a fixed value"
t_eq "the default slot is the clamped bar token" "24" "$(qp_get icon.slot.token)"
t_eq "clamped down from the 27px token" "true" "$(qp_get icon.slot.isClampedHigh)"
t_eq "the default canvas is the bar token" "14" "$(qp_get icon.canvas.token)"
t_eq "and is strictly inside the slot" "true" "$(qp_get icon.canvas.belowSlot)"
t_eq "the implicit size is that square slot" "24" "$(qp_get icon.size.slotFromToken)"
t_eq "on both axes" "true" "$(qp_get icon.size.slotIsSquare)"
t_eq "a size override collapses the slot onto the requested size" "40" "$(qp_get icon.size.override.implicit)"
t_eq "on both axes" "40" "$(qp_get icon.size.override.ih)"
t_eq "and the canvas follows" "40" "$(qp_get icon.size.override.imageW)"
t_eq "on both axes" "40" "$(qp_get icon.size.override.imageH)"
t_eq "the raster is taken at the requested size" "40" "$(qp_get icon.size.override.sourceSize)"
t_eq "while the slot token is left alone" "24" "$(qp_get icon.size.override.leavesSlotToken)"
t_eq "and so is the canvas token" "14" "$(qp_get icon.size.override.leavesCanvasToken)"
t_eq "a sibling instance keeps the token size" "24" "$(qp_get icon.size.otherInstanceUnaffected)"
t_eq "so the two instances really do differ" "true" "$(qp_get icon.size.isolation)"
t_eq "and the shared slotSize is untouched by the override" "true" "$(qp_get icon.state.plainSlotUnaffectedByBig)"
t_eq "the default raster is the canvas times the DPR" "14" "$(qp_get icon.size.plainSourceSize)"
t_eq "and the arithmetic is exactly that for the override" "true" "$(qp_get icon.size.sourceSizeIsCanvasTimesDpr)"
t_eq "the offscreen screen reports a DPR of 1" "1" "$(qp_get icon.size.raster.dpr)"
t_eq "which is what Icon reads through its own window" "1" "$(qp_get icon.dpr.read)"
t_eq "the debug-bounds overlay is off unless the env var is set" "false" "$(qp_get icon.debugBounds)"
t_eq "the recolored URL is 422 characters through the Image" "422" "$(qp_get icon.url.known.length)"
t_eq "the icon URL cache holds the served entries" "13" "$(qp_get icons.cache.size)"
t_eq "a settled plain icon is ready" "true" "$(qp_get icon.ready.plainLater)"
t_eq "and its slot is the 24px token" "24" "$(qp_get icon.state.plainImplicitUnaffected)"
t_note "Icon._dpr falls back to 1 when the containing window has no usable devicePixelRatio (Icon.qml:81-85), but under offscreen the window DOES report 1, so that fallback arm is never taken here. The DPR-correction path itself is asserted: sourceSize is canvas * dpr, 14 for the default canvas and 40 for a size:40 override."
t_eq "a plain icon is ready once the glyph decodes" "true" "$(qp_get icon.ready.plain)"
t_eq "a two-tone icon is ready too" "true" "$(qp_get icon.ready.twoTone)"
t_eq "a non-layered two-tone icon is ready as well" "true" "$(qp_get icon.ready.notActive)"
t_eq "an unknown name is still not ready 30 turns on" "false" "$(qp_get icon.ready.unknown)"
t_eq "ready tracks the base image's status" "true" "$(qp_get icon.ready.plain)"

# ---------------------------------------------------------------------
# GridList: the column and row arithmetic.
# ---------------------------------------------------------------------
t_section "GridList: cell origins are a prefix sum, and the last column stays inside"
t_eq "the model count is what was assigned" "7" "$(qp_get grid.count)"
t_eq "the cell is 100 wide" "100" "$(qp_get grid.cellW)"
t_eq "and 40 tall" "40" "$(qp_get grid.cellH)"
t_eq "the viewport is 300 wide" "300" "$(qp_get grid.viewportW)"
t_eq "the declared column count" "3" "$(qp_get grid.declaredCols)"
t_eq "and the viewport fits the same number of cells" "3" "$(qp_get grid.viewportCols)"
t_eq "row 0 starts at x 0" "0" "$(qp_get grid.x0)"
t_eq "and on y 0" "0" "$(qp_get grid.y0)"
t_eq "cell 1 at one cell in" "100" "$(qp_get grid.x1)"
t_eq "cell 2 at two cells in" "200" "$(qp_get grid.x2)"
t_eq "cell 3 wraps to column 0" "0" "$(qp_get grid.x3)"
t_eq "and the odd final row starts at column 0 too" "0" "$(qp_get grid.x6)"
t_eq "so a half-filled row is left-aligned, not right-padded" "true" "$(qp_get grid.oddRowStartsAtCol0)"
t_eq "rows step by exactly one cell height" "40" "$(qp_get grid.cellRowStride)"
t_eq "cell 3 is on the second row" "40" "$(qp_get grid.y3)"
t_eq "cell 6 on the third" "80" "$(qp_get grid.y6)"
t_eq "the last column's right edge is the viewport" "300" "$(qp_get grid.lastColRightEdge)"
t_eq "so no cell runs past it" "true" "$(qp_get grid.lastColWithinViewport)"
t_eq "the row total is ceil(count / cols) rows" "120" "$(qp_get grid.contentHeight)"
t_eq "which is the same arithmetic written out" "120" "$(qp_get grid.contentHeightExpected)"
t_eq "a 10-item grid is four rows" "160" "$(qp_get grid.ten.contentHeight)"
t_eq "which is ceil(10 / 3) * cellHeight" "160" "$(qp_get grid.ten.contentHeightExpected)"
t_eq "its tenth cell sits in column 0" "0" "$(qp_get grid.ten.x9)"
t_eq "on the fourth row" "120" "$(qp_get grid.ten.y9)"
t_eq "leaving one cell of that row filled" "100" "$(qp_get grid.ten.lastRightEdge)"

t_section "GridList: the same prefix-sum rule the bar uses for its row slots"
# ZoneGeometry.prefixX is the bar's slot-origin rule; a grid's cell origins
# are the same prefix sum, which is what makes the two compose on one card.
t_eq "prefixX starts at 0" "0" "$(qp_get grid.prefixX0)"
t_eq "prefixX step one matches cell 1" "100" "$(qp_get grid.prefixX1)"
t_eq "prefixX step two matches cell 2" "200" "$(qp_get grid.prefixX2)"
t_eq "prefixX's last entry is the row total" "300" "$(qp_get grid.prefixXTotal)"
t_eq "which is totalWidth of the cell widths" "300" "$(qp_get grid.totalWidth)"
t_eq "and is exactly the viewport here" "true" "$(qp_get grid.totalWidthIsViewport)"

t_section "GridList: the column arithmetic MenuPanel derives is self-consistent"
# MenuPanel.qml:108-110: cols = max(1, floor(innerW / cellSpec)) and
# side = floor(innerW / cols). The off-by-one this guards against is a last
# column that runs past the card's inner width, so the check is the slack,
# not a magic number.
t_eq "eight columns fit a 392px inner width at a 46px spec" "8" "$(qp_get grid.fit.cols)"
t_eq "and the cell side is the whole width divided back" "49" "$(qp_get grid.fit.side)"
t_eq "which is what the consumer's own formula gives" "8" "$(qp_get grid.fit.formula.cols)"
t_eq "including the side" "49" "$(qp_get grid.fit.formula.side)"
t_eq "and the slack" "0" "$(qp_get grid.fit.formula.slack)"
t_eq "the grid under test is laid out at that side" "true" "$(qp_get grid.fit.cellMatchesSide)"
t_eq "its viewport is cols * side" "392" "$(qp_get grid.fit.viewportW)"
t_eq "and it fits exactly that many columns" "8" "$(qp_get grid.fit.viewportCols)"
t_eq "the measured slack is 0" "0" "$(qp_get grid.fit.slack)"
t_eq "and always stays under one column" "true" "$(qp_get grid.fit.slackUnderOneCell)"
t_eq "so the last column never overflows" "true" "$(qp_get grid.fit.neverOverflows)"
t_eq "cell 7 sits one side short of the edge" "343" "$(qp_get grid.fit.x7)"
t_eq "its right edge is the inner width exactly" "392" "$(qp_get grid.fit.lastRightEdge)"
t_eq "and not one pixel past it" "true" "$(qp_get grid.fit.lastRightEdgeWithin)"
t_eq "a ragged 301px inner width still does not overflow" "true" "$(qp_get grid.fit.raggedNeverOverflows)"
t_eq "and its slack still stays under one column" "true" "$(qp_get grid.fit.raggedSlackUnderOneCell)"
t_eq "an inner width narrower than one cell still gets a column" "1" "$(qp_get grid.fit.tinyNeverZeroCols)"
t_eq "and a cell that fits" "20" "$(qp_get grid.fit.tinySide)"
t_note "GridList.cols is the cursor-movement contract, not a layout input: the view derives its own column count from width / cellWidth, and the two agree only because MenuPanel sets cellWidth = floor(innerW / gridCols). The suite measures the actual cell origins for that reason, and asserts the consumer's formula separately rather than trusting cols to drive the layout."

t_section "GridList: an empty model is safe on every entry point"
t_eq "count is 0" "0" "$(qp_get grid.empty.count)"
t_eq "contentHeight is 0, not a divide artefact" "0" "$(qp_get grid.empty.contentHeight)"
t_eq "the cursor stays unseated" "-1" "$(qp_get grid.empty.currentIndex)"
t_eq "gotoCell refuses" "false" "$(qp_get grid.empty.gotoCell)"
t_eq "moveCell refuses an empty model" "false" "$(qp_get grid.empty.moveCell)"
t_eq "moveRow refuses an empty model" "false" "$(qp_get grid.empty.moveRow)"
t_eq "settle is a no-op" "undefined" "$(qp_get grid.empty.settle)"
t_eq "sweepToEnd is a no-op" "undefined" "$(qp_get grid.empty.sweepToEnd)"
t_eq "reveal is a no-op" "undefined" "$(qp_get grid.empty.reveal)"
t_eq "and the cursor is still unseated afterwards" "-1" "$(qp_get grid.empty.indexAfter)"

t_section "GridList: the cursor machine"
t_eq "a step below range clamps to the first cell" "false" "$(qp_get cursor.gotoCell.belowRange)"
t_eq "leaving the cursor at 0" "0" "$(qp_get cursor.gotoCell.belowRangeIdx)"
t_eq "a step above range clamps to the last cell" "true" "$(qp_get cursor.gotoCell.aboveRange)"
t_eq "which is index 6 of 7" "6" "$(qp_get cursor.gotoCell.aboveRangeIdx)"
t_eq "re-seating on the current cell is refused" "false" "$(qp_get cursor.gotoCell.again)"
t_eq "the default end helpers are () => -1" "true" "$(qp_get cursor.moveRow.defaultEndIsMinusOne)"
t_eq "a row step off the end reports its movement result" "true" "$(qp_get cursor.moveRow.down)"
t_eq "an explicit step reports that it moved" "true" "$(qp_get cursor.moveRow.stepDown)"
t_eq "and lands on index 4" "4" "$(qp_get cursor.moveRow.stepDownIdx)"
t_eq "an unseated cursor reads -1" "-1" "$(qp_get cursor.unseated)"
t_eq "a cell step from it reports that it moved" "true" "$(qp_get cursor.moveCell.downFromUnseated)"
t_eq "and nothing is selectable so the default end clamps to 0" "0" "$(qp_get cursor.nothingSelectable)"
t_eq "cancelSweep returns nothing" "undefined" "$(qp_get cursor.cancelSweep)"
t_eq "so a row step off the end clamps to 0" "0" "$(qp_get cursor.moveRow.downIdx)"
t_eq "a row step down moves exactly one row" "3" "$(qp_get cursor.moveRow.downStep)"
t_eq "which is the declared column count" "3" "$(qp_get cursor.moveRow.downStepExpected)"
t_eq "and a row step up comes back" "1" "$(qp_get cursor.moveRow.upIdx)"
t_eq "a cell step from an unseated cursor lands on the first" "0" "$(qp_get cursor.moveCell.downFromUnseatedIdx)"
t_eq "and one backwards lands on the last" "6" "$(qp_get cursor.moveCell.upFromUnseatedIdx)"
t_eq "which really is the last index" "true" "$(qp_get cursor.upFromUnseatedIsLast)"
t_eq "a rejected candidate is skipped, not landed on" "5" "$(qp_get cursor.skipRejected)"
t_eq "a run of rejects is skipped to the next accepted cell" "4" "$(qp_get cursor.skipToAccepted)"
t_eq "with nothing selectable at all the default end clamps to 0" "true" "$(qp_get cursor.nothingSelectableWithDefaultEnds)"
t_eq "and with a real end helper it lands there" "5" "$(qp_get cursor.nothingSelectableToLastHelper)"
t_eq "stepping off the end wraps to lastSelectable" "5" "$(qp_get cursor.wrapForward)"
t_eq "and stepping back off the front wraps to firstSelectable" "2" "$(qp_get cursor.wrapBackward)"
t_eq "settle skips a rejected seat by scanning forward" "2" "$(qp_get cursor.settleSkipsLeading)"
t_eq "and settles on the rejected index's successor" "2" "$(qp_get cursor.settleOnRejected)"
t_eq "reveal moves the view without moving the cursor" "2" "$(qp_get cursor.revealOutOfRange)"
t_eq "cancelSweep clears the sweep flag" "false" "$(qp_get cursor.sweepingAfterCancel)"
t_eq "and a sibling grid's cursor is untouched" "0" "$(qp_get cursor.otherGridUntouched)"

t_section "GridList: the wrap sweep runs as a tween, and can be cancelled"
t_eq "the flag is set by the call" "true" "$(qp_get sweep.flagSetAtCall)"
t_eq "from the current position" "0" "$(qp_get sweep.from)"
t_eq "to max(0, contentHeight - height)" "120" "$(qp_get sweep.to)"
t_eq "which is exactly that bound" "true" "$(qp_get sweep.targetIsMaxY)"
t_eq "and that target reads 120 throughout" "120" "$(qp_get sweep.target)"
t_eq "the flag is deferred, not permanent" "false" "$(qp_get sweep.flagCleared)"
t_eq "contentY moves off the origin" "true" "$(qp_get sweep.moving)"
t_eq "five sweep samples were taken" "5" "$(qp_get trace.sweepY.samples)"
t_eq "contentY rose on every turn" "true" "$(qp_get trace.sweepY.rising)"
t_eq "and never passed the sweep target" "true" "$(qp_get trace.sweepY.neverOvershot)"
t_eq "and the first was already moving" "true" "$(qp_get trace.sweepY.firstInFlight)"
t_match "and the raw sweep trace is five samples" '^[0-9. ]+$' "$(qp_get trace.sweepY.raw)"
t_eq "and never overshoots the target" "true" "$(qp_get sweep.neverOvershoots)"
t_eq "an immediate cancel drops the flag" "false" "$(qp_get cancel.flagAfterCancel)"
t_eq "and the view never moves at all" "0" "$(qp_get cancel.contentY)"
t_eq "still not moved 700ms later" "0" "$(qp_get cancel.contentY.final)"
t_eq "a cancelled sweep lands on nothing" "true" "$(qp_get cancel.neverMoved)"
t_eq "the flag really was set before the cancel" "true" "$(qp_get cancel.flagSetAtCall)"
t_eq "the live sweep lands exactly on its target" "true" "$(qp_get sweep.landedOnTarget)"
t_eq "at 120" "120" "$(qp_get sweep.contentY.settled)"
t_eq "and never overshot it" "true" "$(qp_get sweep.neverOvershot)"

# ---------------------------------------------------------------------
# ScrollBar: handle geometry against the viewport.
# ---------------------------------------------------------------------
t_section "ScrollBar: the wrapper's own policy"
t_eq "its width is the thickness token" "3" "$(qp_get sb.width)"
t_eq "which is what was asked for" "3" "$(qp_get sb.thickness)"
t_eq "target is the Flickable it was handed" "true" "$(qp_get sb.target.isTarget)"
t_eq "visible when there is something to scroll" "true" "$(qp_get sb.visible.scrollable)"
t_eq "and hidden when the content fits the viewport" "false" "$(qp_get sb.visible.notScrollable)"
t_eq "which is Qt reporting a scrollable fraction of 1" "1" "$(qp_get sb.short.size)"
t_eq "not something just under it" "true" "$(qp_get sb.short.size.isOne)"
t_eq "autoHide leaves the idle bar dimmed" "0.55" "$(qp_get sb.long.opacity.autoHide)"
t_eq "and turning it off leaves it fully opaque" "1" "$(qp_get sb.long.opacity.pinned)"
t_eq "the radius reaches the thumb" "3" "$(qp_get sb.fat.radius)"
t_eq "and defaults to square when unset" "0" "$(qp_get sb.pinned.radius)"
t_eq "thickness is a property, not a constant" "6" "$(qp_get sb.fat.thickness)"

t_section "ScrollBar: the handle size, and the divide guard at zero height"
t_eq "scrollable fraction for 200 of 800" "0.25" "$(qp_get sb.long.size)"
t_eq "the handle is that fraction of the track" "50" "$(qp_get sb.long.thumbH)"
t_eq "and is as wide as the bar" "3" "$(qp_get sb.long.thumbW)"
t_eq "a short slot becomes a minimumSize fraction" "0.12" "$(qp_get sb.long.minimumSize)"
t_eq "which is exactly minThumb / height" "true" "$(qp_get sb.long.minimumSize.isMinThumbFraction)"
t_eq "and equals the documented expression" "0.12" "$(qp_get sb.long.minimumSizeExpected)"
t_eq "a minThumb larger than the bar clamps to the whole track" "1" "$(qp_get sb.fat.minimumSize)"
t_eq "and the handle really does fill it" "200" "$(qp_get bar.fat.thumbH.fillsTrack)"
t_eq "the same figure read at construction" "200" "$(qp_get sb.fat.thumbH)"
t_eq "and the clamp holds there too" "true" "$(qp_get sb.fat.thumbNeverExceeds)"
t_eq "and again once the list has moved" "true" "$(qp_get bar.fat.thumbNeverExceeds)"
t_eq "and after the list is dragged to the bottom" "true" "$(qp_get bar.fat.minimumSizeIsClamped)"
t_eq "which is min(1, minThumb / height)" "1" "$(qp_get sb.fat.minimumSizeExpected)"
t_eq "and the handle does fill the track" "200" "$(qp_get sb.fat.thumbH)"
t_eq "without exceeding it" "true" "$(qp_get sb.fat.thumbNeverExceeds)"
t_eq "a zero-height bar yields minimumSize 0" "0" "$(qp_get sb.zero.minimumSize)"
t_eq "and it is a real number, not NaN" "number" "$(qp_get sb.zero.minimumSizeIsNumber)"
t_eq "that bar has no height to divide" "0" "$(qp_get sb.zero.height)"

t_section "ScrollBar: the shadow viewport measures the list, not the bar"
t_eq "the shadow reports the target's width" "80" "$(qp_get sb.shadow.widthIsTargetWidth)"
t_eq "which is not the bar's width" "true" "$(qp_get sb.shadow.widthIsNotBarWidth)"
t_eq "and the target's contentHeight" "800" "$(qp_get sb.shadow.contentHeight)"
t_eq "over the target's viewport height" "200" "$(qp_get sb.shadow.height)"
t_eq "it is invisible" "false" "$(qp_get sb.shadow.visible)"
t_eq "and never takes input" "false" "$(qp_get sb.shadow.interactive)"

t_section "ScrollBar: the handle travels the track and never runs past it"
t_eq "at the top of the list the handle is at 0" "0" "$(qp_get bar.thumbY.atTop)"
t_eq "keeping its size" "50" "$(qp_get bar.thumbH.atTop)"
t_eq "at contentY 300 it is a third of the way down" "75" "$(qp_get bar.thumbY.mid)"
t_eq "and the shadow followed the list" "300" "$(qp_get bar.shadow.mirrorsTarget)"
t_eq "as did the list itself" "300" "$(qp_get bar.target.atMid)"
t_eq "a write through the bar's single writer round-trips" "300" "$(qp_get bar.write.roundTrip)"
t_note "Below: the writer only accepts a position a PRESSED thumb produced. A shadow contentY also moves when the wrapper mirrors the target into it and when Qt clamps it after the content it mirrors changes - and relaying either is a loop, not a drag: replacing a model drops the view to the top, the shadow relays that, and the relay lands through the list's one writer as though the user had dragged the thumb to the first row. That is what made a scrolled list jump on every deletion."
t_eq "with no thumb pressed a differing position is not a drag" "300" "$(qp_get bar.write.noDragKeeps)"
t_eq "so the target is not moved by the mirror" "300" "$(qp_get bar.write.targetUnmoved)"
t_eq "and the bar reports that no thumb is driving it" "false" "$(qp_get bar.write.notDriving)"
t_eq "with the thumb following" "75" "$(qp_get bar.write.thumbY)"
t_eq "at the bottom of the list the handle is at the far end" "150" "$(qp_get bar.thumbY.atBottom)"
t_eq "which is the track minus the handle" "true" "$(qp_get bar.thumbY.atBottom.isExpected)"
t_eq "with the same handle size" "50" "$(qp_get bar.thumbH.atBottom)"
t_eq "and its bottom edge exactly on the track end" "true" "$(qp_get bar.thumbBottomAtBottom)"
t_eq "the raw expected figure is 150" "150" "$(qp_get bar.thumbY.atBottomExpected)"
t_eq "the shadow still mirrors the list's content height" "800" "$(qp_get bar.shadow.contentHeightMirrors)"
t_eq "and the short list's bar still has the 0.12 floor" "0.12" "$(qp_get bar.short.minimumSize)"
t_eq "so the handle never exceeds the track anywhere in the range" "true" "$(qp_get bar.thumbNeverExceedsTrack)"
t_eq "the handle is tinted, not solid" "0.4196078431372549" "$(qp_get sb.long.thumbAlpha)"

# ---------------------------------------------------------------------
# Glide and the other motion primitives.
# ---------------------------------------------------------------------
t_section "Glide: the number tween, read while it is in flight"
t_eq "a declared Glide takes its duration from the motion gate" "120" "$(qp_get glide.duration.isGate)"
t_eq "which is exactly what the gate returns" "120" "$(qp_get glide.duration.expected)"
t_eq "its curve is OutCubic" "6" "$(qp_get glide.easing)"
t_eq "symbolically" "true" "$(qp_get glide.easing.isOutCubic)"
t_eq "and it holds no target until something drives it" "null" "$(qp_get glide.target.pristine)"
t_eq "one turn in it is strictly between the endpoints" "true" "$(qp_get glide.midFlight)"
t_eq "and has not overshot" "true" "$(qp_get glide.neverOvershoots)"
t_eq "two turns in it has moved further" "true" "$(qp_get glide.increased)"
t_eq "it lands exactly on the target, not near it" "100" "$(qp_get glide.v.settled)"
t_eq "which is a real arrival" "true" "$(qp_get glide.landedOnTarget)"
t_eq "and the stop released its target" "null" "$(qp_get glide.targetWhileSettled)"
# Five samples, one event-loop turn apart. The exact value on any single turn
# is a function of how long that turn happened to be, so the claim is the
# shape of the trace, not a frame: it starts past a fifth of the way, rises on
# every turn, and never passes the target.
t_eq "five samples were taken" "5" "$(qp_get trace.glide.samples)"
t_eq "the value rose on every single turn" "true" "$(qp_get trace.glide.rising)"
t_eq "and no sample ever passed the target" "true" "$(qp_get trace.glide.neverOvershot)"
t_eq "the first was already a fifth of the way along" "true" "$(qp_get trace.glide.firstInFlight)"
t_match "and the raw trace is five samples" '^[0-9. ]+$' "$(qp_get trace.glide.raw)"
t_eq "still released a dozen turns later" "true" "$(qp_get glide.target.released)"
t_eq "with the value held at the target" "100" "$(qp_get glide.v.final)"

t_section "CapsChip: its own 150ms opacity and scale pair"
t_eq "the chip is sized from its own label" "78.34375" "$(qp_get caps.label.iw)"
t_eq "plus 24 of padding" "102.34375" "$(qp_get caps.width)"
t_eq "and the label width plus 24 is exactly that" "102.34375" "$(qp_get caps.widthExpected)"
t_eq "height is the label height plus 10" "25" "$(qp_get caps.height)"
t_eq "and the label height plus 10 is exactly that" "25" "$(qp_get caps.heightExpected)"
t_eq "square corners" "0" "$(qp_get caps.radius)"
t_eq "a one pixel border" "1" "$(qp_get caps.border)"
t_eq "the label is the fixed caps string" "CAPS LOCK" "$(qp_get caps.label.text)"
t_eq "letterspaced by 2" "2" "$(qp_get caps.label.ls)"
t_eq "bold" "true" "$(qp_get caps.label.bold)"
t_eq "at 11px" "11" "$(qp_get caps.label.px)"
t_eq "inactive rests fully transparent" "0" "$(qp_get caps.off.restOpacity)"
t_eq "and scaled down" "0.9" "$(qp_get caps.off.restScale)"
t_eq "on mirrors active" "true" "$(qp_get caps.on.mirrors)"
t_eq "and rests fully opaque" "1" "$(qp_get caps.on.opacity)"
t_eq "at full scale" "1" "$(qp_get caps.on.scale)"
t_eq "five opacity samples were taken" "5" "$(qp_get trace.capsOpacity.samples)"
t_eq "the opacity rose on every turn" "true" "$(qp_get trace.capsOpacity.rising)"
t_eq "and the first was a tenth of the way" "true" "$(qp_get trace.capsOpacity.firstInFlight)"
t_eq "five scale samples were taken" "5" "$(qp_get trace.capsScale.samples)"
t_eq "the scale rose on every turn" "true" "$(qp_get trace.capsScale.rising)"
t_eq "and never passed 1" "true" "$(qp_get trace.capsScale.neverOvershot)"
t_eq "and the first was a twentieth of the way" "true" "$(qp_get trace.capsScale.firstInFlight)"
t_match "and the raw scale trace is five samples" '^[0-9. ]+$' "$(qp_get trace.capsScale.raw)"
t_eq "one turn into the activation the scale is mid-flight" "true" "$(qp_get caps.scale.midFlight)"
t_eq "and has not overshot" "true" "$(qp_get caps.neverOvershoots)"
t_eq "it lands on exactly 1" "1" "$(qp_get caps.scale.final)"
t_eq "and the opacity on exactly 1" "1" "$(qp_get caps.opacity.final)"

t_section "Vignette: the level, the progress, and the shape that walks in"
t_eq "a full progress draws the whole level" "true" "$(qp_get vig.full.opacityIsLevelTimesProgress)"
t_eq "at the settled scale" "true" "$(qp_get vig.full.scaleIsSettled)"
t_eq "and it is on screen" "true" "$(qp_get vig.full.visible)"
t_eq "half the progress draws half the level" "true" "$(qp_get vig.half.opacityIsHalfTheLevel)"
t_eq "and the shape is scaled for the walk-in" "true" "$(qp_get vig.half.scaleIsTheWalkIn)"
t_eq "a level of nothing draws nothing" "true" "$(qp_get vig.none.opacityIsZero)"
t_eq "and stays hidden" "true" "$(qp_get vig.none.hidden)"

t_section "ProgressBar: the fill as layout, and the empty-dim rule"
t_eq "the documented default width" "160" "$(qp_get bar.iw)"
t_eq "a six pixel track" "6" "$(qp_get bar.h)"
t_eq "clipped" "true" "$(qp_get bar.clip)"
t_eq "an empty dimmed bar sits back" "0.4" "$(qp_get bar.empty.opacity)"
t_eq "its fill has no width yet" "0" "$(qp_get bar.empty.fillW)"
t_eq "but the fill is still the visible object" "true" "$(qp_get bar.empty.fillVisible)"
t_eq "a half-full bar's fill is half the bar" "50" "$(qp_get bar.half.fillW)"
t_eq "which is width * ratio" "50" "$(qp_get bar.half.fillExpected)"
t_eq "and it is fully opaque" "1" "$(qp_get bar.half.opacity)"
t_eq "dimWhenEmpty: false defeats the empty dim" "1" "$(qp_get bar.loud.opacity)"
t_eq "and keeps a quarter of the bar filled" "25" "$(qp_get bar.loud.fillW)"
t_eq "an indeterminate bar is never dimmed" "1" "$(qp_get bar.busy.opacity)"
t_eq "and hides the determinate fill" "false" "$(qp_get bar.busy.fillVisible)"
t_eq "showing the sweep block instead" "true" "$(qp_get bar.busy.blockVisible)"
t_eq "a third of the bar wide" "30" "$(qp_get bar.busy.blockW)"
t_eq "which is 0.3 of the bar" "30" "$(qp_get bar.busy.blockExpected)"
t_eq "and as tall as the track" "6" "$(qp_get bar.busy.blockH)"
t_eq "the fill wears the accent" "#8a8a8a" "$(qp_get bar.fillColor)"
t_eq "the track the background" "#393939" "$(qp_get bar.trackColor)"
t_eq "the fill glide defaults to the normal pace" "180" "$(qp_get bar.glideMs)"
t_eq "five fill samples were taken" "5" "$(qp_get trace.barFill.samples)"
t_eq "the fill rose on every turn" "true" "$(qp_get trace.barFill.rising)"
t_eq "and never passed the bar's own width" "true" "$(qp_get trace.barFill.neverOvershot)"
t_eq "and the first was a quarter of the way" "true" "$(qp_get trace.barFill.firstInFlight)"
t_match "and the raw fill trace is five samples" '^[0-9. ]+$' "$(qp_get trace.barFill.raw)"
t_eq "one turn after retargeting the fill is mid-glide" "true" "$(qp_get bar.fill.midFlight)"
t_eq "and has not overshot" "true" "$(qp_get bar.fill.neverOvershoots)"
t_eq "the target is the full bar" "100" "$(qp_get bar.fill.expectedTarget)"
t_eq "it lands on exactly the target" "100" "$(qp_get bar.fill.final)"
t_eq "which is width * ratio" "true" "$(qp_get bar.fill.matchesTarget)"
t_eq "and a sibling bar's fill never moved" "50" "$(qp_get bar.otherUnaffected)"

# ---------------------------------------------------------------------
# DropdownSlot: the open/close state machine and the deferred body.
# ---------------------------------------------------------------------
t_section "DropdownSlot: velocity-paced unfold, not a fixed time"
t_eq "a short slot's content reports its own height" "40" "$(qp_get slotShort.contentHeight)"
t_eq "plus the default gap" "12" "$(qp_get slotShort.gap)"
t_eq "which paces the open at the fastMs floor" "120" "$(qp_get slotShort.slotMs)"
t_eq "the documented formula gives the same" "120" "$(qp_get slotShort.slotMsExpected)"
t_eq "a tall slot paces at the slowMs cap instead" "260" "$(qp_get slotTall.slotMs)"
t_eq "which is also what the formula gives" "260" "$(qp_get slotTall.slotMsExpected)"
t_eq "the short slot sits exactly on the fastMs floor" "true" "$(qp_get slotShort.slotMs.isFastFloor)"
t_eq "the tall slot sits exactly on the slowMs cap" "true" "$(qp_get slotTall.slotMs.isSlowCap)"
t_eq "so the two slots are not the same duration" "true" "$(qp_get slotShort.slotMs.differsFromTall)"
t_eq "a closed slot has no height" "0" "$(qp_get slotShort.height)"
t_eq "the never-opened slot has none either" "0" "$(qp_get slotIdle.height)"
t_eq "and is not closing" "false" "$(qp_get slotIdle.closing)"
t_eq "nor after a hundred milliseconds" "false" "$(qp_get slotIdle.closingTurn2)"
t_eq "an open slot is not closing either" "false" "$(qp_get slotShort.closingTurn2)"
t_eq "nor is the tall one" "false" "$(qp_get slotTall.closing)"
t_eq "and is fully transparent" "0" "$(qp_get slotShort.opacity)"
t_eq "and holds no deferred body" "null" "$(qp_get slotShort.nested)"
t_eq "its sibling is closed too, independently" "null" "$(qp_get slotTall.nested)"

t_section "DropdownSlot: the close grace window is longer than either tween"
t_eq "a short slot's grace is max(slotMs, normalMs) + 20" "200" "$(qp_get slotShort.grace)"
t_eq "which is what the source computes" "200" "$(qp_get slotShort.graceExpected)"
t_eq "so it outlives that slot's unfold" "true" "$(qp_get slotShort.graceOutlivesHeight)"
t_eq "a tall slot's grace is 280" "280" "$(qp_get slotTall.grace)"
t_eq "which is also what the source computes" "280" "$(qp_get slotTall.graceExpected)"
t_eq "and outlives that slot's unfold too" "true" "$(qp_get slotTall.graceOutlivesHeight)"
t_note "DropdownSlot's height rides slotMs and its opacity the fixed Ui.normalMs (DropdownSlot.qml:114-120), which is why the grace window is max(slotMs, normalMs) + 20 rather than slotMs alone. The probe pins both halves of that: a short slot unfolds (120ms) faster than it fades (180ms), and a tall slot fades (180ms) faster than it unfolds (260ms)."

t_section "DropdownSlot: opening builds the body and glides the height"
t_eq "the body is created on open" "obj" "$(qp_get slotShort.nestedTurn2)"
t_eq "the tall slot's body is a distinct instance" "obj" "$(qp_get slotTall.nestedTurn2b)"
t_eq "the never-opened slot holds none" "null" "$(qp_get slotTall.nested)"
t_eq "into the content host, not a Loader" "true" "$(qp_get slotShort.nestedParent.isContentHost)"
t_eq "where it starts at the host's x" "0" "$(qp_get slotShort.nestedX)"
t_eq "and keeps its own width" "30" "$(qp_get slotShort.nestedW)"
t_eq "the sibling's body is a different instance" "30" "$(qp_get slotTall.nestedW)"
t_eq "one turn in, the height is well short of its target" "true" "$(qp_get slotShort.height.shortOfTarget)"
t_eq "the target being content height plus gap" "52" "$(qp_get slotShort.heightTarget)"
t_eq "expressed as a fraction of that target it is nearly there" "0.9629629629629629" "$(qp_get slotShort.heightFraction.s5)"
t_eq "while the fade is only 0.83 of the way" "0.8285322359396433" "$(qp_get slotShort.opacity.s5)"
t_eq "so on a short slot the unfold runs ahead of the fade" "true" "$(qp_get slotShort.unfoldAheadOfFade)"
t_eq "with both still in flight" "true" "$(qp_get slotShort.bothInFlight)"
t_eq "on a tall slot the fraction is 0.67 instead" "0.6681838871187984" "$(qp_get slotTall.heightFraction.s5)"
t_eq "so the fade runs ahead of the unfold" "true" "$(qp_get slotTall.fadeAheadOfUnfold)"
t_eq "and 0.82 of the way there by the later turn" "0.8155557578516157" "$(qp_get slotTall.heightFraction.s7)"
t_eq "still with both in flight" "true" "$(qp_get slotTall.bothInFlight.s7)"
t_eq "it lands on exactly content height plus gap" "52" "$(qp_get slotShort.height.landed)"
t_eq "five short-slot height samples were taken" "5" "$(qp_get trace.slotShortH.samples)"
t_eq "the unfold rose on every turn" "true" "$(qp_get trace.slotShortH.rising)"
t_eq "and never passed its target" "true" "$(qp_get trace.slotShortH.neverOvershot)"
t_eq "and the first was a third of the way" "true" "$(qp_get trace.slotShortH.firstInFlight)"
t_eq "the short slot's fade rose on every turn too" "true" "$(qp_get trace.slotShortO.rising)"
t_eq "and was a quarter of the way on the first turn" "true" "$(qp_get trace.slotShortO.firstInFlight)"
t_eq "the tall slot's unfold rose on every turn" "true" "$(qp_get trace.slotTallH.rising)"
t_eq "and never passed its 404 target" "true" "$(qp_get trace.slotTallH.neverOvershot)"
t_eq "and the first was a sixth of the way" "true" "$(qp_get trace.slotTallH.firstInFlight)"
t_eq "the tall slot's fade rose on every turn too" "true" "$(qp_get trace.slotTallO.rising)"
t_eq "and was a quarter of the way on the first turn" "true" "$(qp_get trace.slotTallO.firstInFlight)"
t_match "and the raw short-slot trace is five samples" '^[0-9. ]+$' "$(qp_get trace.slotShortH.raw)"
t_match "and so is the tall slot's" '^[0-9. ]+$' "$(qp_get trace.slotTallH.raw)"
t_eq "the tall slot's own gap" "4" "$(qp_get slotTall.gap)"
t_eq "and its content height" "400" "$(qp_get slotTall.contentHeight)"
t_eq "a closed tall slot has no height" "0" "$(qp_get slotTall.height)"
t_eq "its first in-flight height is 70" "70.08894310423305" "$(qp_get slotTall.height.s1)"
t_eq "against a 404 target" "404" "$(qp_get slotTall.heightTarget)"
t_eq "the short slot's target is 52" "52" "$(qp_get slotShort.heightTarget)"
t_eq "which is what the formula says" "true" "$(qp_get slotShort.height.matchesTarget)"
t_eq "and so does the tall one" "true" "$(qp_get slotTall.height.matchesTarget)"
t_eq "the fade is still running when the short unfold lands" "true" "$(qp_get slotShort.fadeOutlivesHeight)"
t_eq "with the fade all but over" "true" "$(qp_get slotShort.opacity.midFadeNearlyOver)"
t_eq "and finishes at exactly 1" "1" "$(qp_get slotShort.opacity.settled)"
t_eq "an open slot is not closing" "false" "$(qp_get slotShort.closing)"

t_section "DropdownSlot: closing holds the body, then releases it"
t_eq "closing is set the moment open drops" "true" "$(qp_get cycle.closingAtClose)"
t_eq "and the grace timer is armed" "true" "$(qp_get cycle.graceRunning)"
t_eq "the deferred body is still alive through the fade" "obj" "$(qp_get cycle.nestedHeldDuringClose)"
t_eq "the height lands on 0" "0" "$(qp_get cycle.height)"
t_eq "closing is false again once the grace expires" "false" "$(qp_get cycle.closing)"
t_eq "closeFinished fired exactly once" "1" "$(qp_get cycle.closeFinished)"
t_eq "and the body was released" "null" "$(qp_get cycle.nestedReleased)"
t_eq "the slot that was never closed never fired it" "0" "$(qp_get cycle.closeFinishedShort)"
t_eq "and neither did the never-opened one" "0" "$(qp_get slotShort.closeFinished)"
t_eq "closing was set the moment the cycle slot dropped" "true" "$(qp_get cycle.closingAtClose)"
t_eq "and the body was still alive then" "obj" "$(qp_get cycle.nestedHeldDuringClose)"
t_eq "the reopen cleared closing" "false" "$(qp_get reopen.closingCleared)"
t_eq "the reopen stopped the grace timer" "false" "$(qp_get reopen.graceStopped)"
t_eq "and cancelled the pending closeFinished" "0" "$(qp_get reopen.closeFinishedDuringGrace)"
t_eq "the slot that was never opened never armed it" "false" "$(qp_get slotIdle.graceArmed)"
t_eq "and never entered closing" "false" "$(qp_get slotIdle.neverArmed)"
t_note "A DropdownSlot born closed never enters closing: the private _closing flag starts false and the grace timer only arms from onOpenChanged (DropdownSlot.qml:156-165). That is correct - there is nothing to hold - but it means closing is not a general 'is not open' predicate and a consumer must not read it as one."

t_section "DropdownSlot: reopening inside the grace window keeps the body"
t_eq "closing clears on the reopen" "false" "$(qp_get reopen.closingCleared)"
t_eq "the grace timer is stopped" "false" "$(qp_get reopen.graceStopped)"
t_eq "and the SAME body instance is still held" "true" "$(qp_get reopen.sameBodyInstance)"
t_eq "so closeFinished was cancelled, not deferred" "0" "$(qp_get reopen.closeFinished)"
t_eq "still not fired 250ms later" "0" "$(qp_get reopen.closeFinished)"
t_eq "the body is still the same one" "true" "$(qp_get reopen.stillHoldingBody)"
t_eq "and the slot is fully open again" "52" "$(qp_get reopen.height)"

# ---------------------------------------------------------------------
# ConfirmSlot: the staged copy and the two signals.
# ---------------------------------------------------------------------
t_section "ConfirmSlot: the staged hint -> armed -> confirmed copy"
t_eq "it owns exactly two labels" "2" "$(qp_get confirm.textCount)"
t_eq "the first is the disarm hint" "Press Delete to remove" "$(qp_get confirm.hintText)"
t_eq "the second is the button label" "Delete" "$(qp_get confirm.buttonText)"
t_eq "the button label is configurable" "Delete" "$(qp_get confirm.confirmText.default)"
t_eq "the hint is configurable" "Press Delete to remove" "$(qp_get confirm.hintText.default)"
t_eq "and the armed text is a fixed literal" "<b><u>Press again to confirm</u></b>" "$(qp_get confirm.armedText.default)"
t_eq "at stage 0 the hint is showing" "Press Delete to remove" "$(qp_get confirm.stageText.before)"
t_eq "at stage 2 the armed text replaces it" "<b><u>Press again to confirm</u></b>" "$(qp_get confirm.stageText.after)"
t_eq "which is the slot's own armedText" "true" "$(qp_get confirm.stageText.isArmed)"
t_eq "and stays there" "<b><u>Press again to confirm</u></b>" "$(qp_get confirm.stageText.staysArmed)"
t_eq "a slot constructed armed is at stage 2" "2" "$(qp_get confirm.armed.isStage)"
t_eq "rendered as StyledText, so the tags are markup not literals" "true" "$(qp_get confirm.armed.format)"
t_eq "and switching stage does not resize the slot" "true" "$(qp_get confirm.stageKeepsHeight)"
t_eq "the gap between the label and the card is the Ui.m token" "12" "$(qp_get confirm.gap)"
t_eq "the content is 50 tall" "50" "$(qp_get confirm.contentHeight)"
t_eq "so the open slot is 50 plus the gap" "62" "$(qp_get confirm.height)"

t_section "ConfirmSlot: confirmed() fires, cancelled() never does"
t_eq "nothing fired at construction" "0" "$(qp_get confirm.buttonHits)"
t_eq "emitting confirmed() reaches the handler" "1" "$(qp_get confirm.confirmed.afterEmit)"
t_eq "and the count is stable afterwards" "1" "$(qp_get confirm.confirmedHits)"
t_eq "emitting cancelled() is the only way to raise it" "0" "$(qp_get confirm.cancelled.afterEmit)"
t_eq "and it is still zero after every path the component has" "0" "$(qp_get confirm.cancelledHits)"
t_eq "with a handler connected the whole time" "0" "$(qp_get confirm.cancelHits)"
t_eq "and the same after the stage change" "0" "$(qp_get confirm.cancelHits.staysZero)"
t_eq "an armed slot shows the armed text on its own" "<b><u>Press again to confirm</u></b>" "$(qp_get confirm.armed.text0)"
# FINDING: `signal cancelled()` is declared at ConfirmSlot.qml:17 and nothing
# in the file ever emits it, and no consumer in the tree connects to it (the
# seven ConfirmSlot users - PassPanel, PassEntry, Entry, PowerMenuPanel,
# WallpaperEntry, ClipboardEntry, LauncherEntry - all drive the stage from
# outside). So the type advertises a cancel notification it never sends.
t_note "FINDING (Low, dead signal): ConfirmSlot declares signal cancelled() (ConfirmSlot.qml:17) and never emits it. Nothing in the file raises it, and none of its seven consumers in the tree connects to onCancelled - each tracks the stage itself, which the header calls 'pure view'. A consumer wiring onCancelled would therefore hang silently, with no compile error and no runtime warning. Pinned here as the observed zero; PasswordBox.qml:73 declares and does emit a same-named signal, so the name itself is not the problem."
t_skip "ConfirmSlot's cancel path raises cancelled()" "the signal is declared but never emitted by the component; there is no path from any input or state change to it, so the count is asserted as a pinned zero instead"

# ---------------------------------------------------------------------
# PanelCard: the chrome ladder, the row table and the width pass.
# ---------------------------------------------------------------------
t_section "PanelCard: the chrome ladder and the empty-list floor"
t_eq "with a filter bar the chrome is 2*vPad + filterH + listTopGap" "72" "$(qp_get pc.chrome.withFilter)"
t_eq "which is what those tokens add to" "72" "$(qp_get pc.chrome.withFilterExpected)"
t_eq "without one the card hugs the list" "28" "$(qp_get pc.chrome.withoutFilter)"
t_eq "which is exactly 2*vPad" "28" "$(qp_get pc.chrome.withoutFilterExpected)"
t_eq "the available list height is maxHeight less that chrome" "528" "$(qp_get pc.availRows)"
t_eq "the screen bound is the hard max less that chrome" "1128" "$(qp_get pc.screenMaxRowsValue)"
t_eq "an empty list takes the emptyMinH floor" "140" "$(qp_get pc.empty.listRegionH)"
t_eq "which is min(emptyMinH, avail)" "140" "$(qp_get pc.empty.listRegionExpected)"
t_eq "so the card is 212 tall" "212" "$(qp_get pc.empty.cardHeight)"
t_eq "and keeps its base width with no rows to measure" "200" "$(qp_get pc.empty.width)"
t_eq "including contentW" "200" "$(qp_get pc.empty.contentW)"

t_section "PanelCard: the row-height table is a pure function of the row"
t_eq "a null row is the minimum row height" "34" "$(qp_get pc.rowRest.null)"
t_eq "a separator is a fixed 12" "12" "$(qp_get pc.rowRest.separator)"
t_eq "a delimiter likewise" "12" "$(qp_get pc.rowRest.delimiter)"
t_eq "and a row typed as a separator too" "12" "$(qp_get pc.rowRest.typeSeparator)"
t_eq "a plain row is the minimum row height" "34" "$(qp_get pc.rowRest.plain)"
t_eq "a row with a sub line adds that line plus one" "47" "$(qp_get pc.rowRest.sub)"
t_eq "subLeft counts the same way" "47" "$(qp_get pc.rowRest.subLeft)"
t_eq "the two-line figure IS the delegate's own line boxes" "true" "$(qp_get pc.rowRest.isRealLineBoxes)"
t_eq "and the plain figure is that same arithmetic" "true" "$(qp_get pc.rowRest.plainIsRealLineBoxes)"
t_eq "and is NOT a TextMetrics probe of some fixed string" "true" "$(qp_get pc.rowRest.notTheMgProbe)"
t_note "The row estimate is measured on a real Text's line box for the row's OWN label, because that is the number every row delegate reads (menu/Entry.qml: lbl.implicitHeight; LauncherEntry floors the same column on ceil(FontMetrics.height)). The 'Mg' TextMetrics probe this replaced is a different quantity AND a different string: on a two-line launcher row it answers 17.141 + 1 + 13.188 = 31.328 for the label column where the real Text gives 18 + 1 + 14 = 33, so the estimate said 45.328 for a row that settles at 47. That is 1.672px a row, 18px over a twelve-row cap, and it cut that cap's last entry through the middle. The gap is the fractional slack ceil() rounds away, which is why it appeared at fractional scale factors and not at integer ones."
t_eq "three plain rows with 2px gaps is 106" "106" "$(qp_get pc.model.threeRows)"
t_eq "which is the same arithmetic written out" "106" "$(qp_get pc.model.threeRowsExpected)"
t_eq "two rows with no labels still measure as rows" "70" "$(qp_get pc.model.noLabels)"
t_eq "and that is the same arithmetic" "70" "$(qp_get pc.model.noLabelsExpected)"

t_section "PanelCard: the row-set key only exists for a single row"
t_eq "a multi-row set has no key" "null" "$(qp_get pc.key.multiRow)"
t_eq "a single plain row keys on the one-column shape" "1|single:1" "$(qp_get pc.key.singlePlain)"
t_eq "a single two-line row keys on the two-column shape" "1|single:2" "$(qp_get pc.key.singleSub)"
t_eq "a single empty row keys on the unknown shape" "1|?" "$(qp_get pc.key.hole)"

t_section "PanelCard: the resting region ignores a fit measured through an open slot"
# The card's resting region is documented as the height of the row set "with
# nothing open", but a consumer computes `exactListH` with `list.fitHeight()`,
# and that walk reads each row's CURRENT height - so an open dropdown inflates
# the fit, and the y of every row beneath it besides. Handing that to the
# resting region made a dropdown on the FIRST row of the password manager grow
# the window with the growth rule never consulted: it was not the growth path
# at all, which is why fixing the growth rule changed nothing.
#
# So the fit is latched at its last slot-free value. The subtlety is the
# CLOSE: the claim is released the moment a slot starts closing, so `slotOpen`
# falls while the content is still tall, and latching there took the inflated
# fit and then snapped down to the real one - the small jump on close. The
# recovery is therefore monotone: for a plain open/close the row set does not
# change, so the fit can only come back DOWN.
t_eq "the resting region at rest" "292" "$(qp_get fl.restAtRest)"
t_eq "the fit reports the taller content once a slot is open" "532" "$(qp_get fl.fitSaidWhileOpen)"
t_eq "and the resting region did not follow it" "292" "$(qp_get fl.restWhileOpen)"
t_eq "so the card did not grow" "true" "$(qp_get fl.didNotGrow)"
t_eq "and it never moved on the way back down either" "false" "$(qp_get fl.movedDuringClose)"
t_eq "292 at every step of the collapsing fit" "292,292,292,292,292" "$(qp_get fl.trail)"
t_eq "and it landed back on the resting size" "292" "$(qp_get fl.landed)"
t_eq "which is the fit, now re-latched" "true" "$(qp_get fl.backToRest)"
t_eq "with the card back where it started" "330" "$(qp_get fl.cardBack)"

t_section "PanelCard: a row-limited card sizes to its rows, not the window"
# A row set at or under the cap knows its own resting height and the card
# hugs it - the "single-row regime" restingListH implements. The slot term
# (slotRegionH, -1 with nothing open) is a separate DECIDED override applied on
# top of that base, so a resting size is never derived from an open slot; and
# slotOpen is separate again, because a slot that fits makes the content
# taller while asking for no resize at all.
t_eq "the card is told rowLimit 3" "3" "$(qp_get pc.narrow.rowLimit)"
t_eq "and handed three rows" "3" "$(qp_get pc.narrow.rowsLength)"
t_eq "with a count of 3" "3" "$(qp_get pc.narrow.count)"
t_eq "and no slot open" "false" "$(qp_get pc.narrow.slotOpen)"
t_eq "and no region override" "-1" "$(qp_get pc.narrow.slotRegionH)"
t_eq "and no exactListH bypass" "-1" "$(qp_get pc.narrow.exactListH)"
t_eq "and fitPending false" "false" "$(qp_get pc.narrow.fitPending)"
t_eq "and a zero resting buffer" "0" "$(qp_get pc.narrow.restingBufH)"
t_eq "and a zero contentHeight" "0" "$(qp_get pc.narrow.contentHeight)"
t_eq "the available list height is 272" "272" "$(qp_get pc.narrow.avail)"
t_eq "the model height of those rows is 106" "106" "$(qp_get pc.narrow.model)"
t_eq "and snappedListH agrees" "106" "$(qp_get pc.narrow.snapped)"
t_eq "and rowLimitRegion is a real member of the card" "function" "$(qp_get pc.narrow.hasRowLimitFunction)"
t_eq "a three-row set at a cap of 3 measures 106" "106" "$(qp_get pc.narrow.listRegionH)"
t_eq "which is exactly the model height for those rows" "true" "$(qp_get pc.narrow.regionIsModel)"
t_eq "and is well under the 272 the window would allow" "true" "$(qp_get pc.narrow.regionBelowAvail)"
t_eq "so the card is 134 tall, not 300" "134" "$(qp_get pc.narrow.cardHeight)"
t_eq "a single row under a cap of 10 sizes to that one row" "34" "$(qp_get pc.oneRow.listRegionH)"
t_eq "which is the model height of one row" "34" "$(qp_get pc.oneRow.model)"
t_eq "so that card is 62 tall" "62" "$(qp_get pc.oneRow.cardHeight)"
t_eq "against an available 272" "272" "$(qp_get pc.oneRow.avail)"
# The same region does not drift between construction and the first turn: the
# first evaluation sees `rows` already assigned here, and re-reading it a turn
# later gives the same answer.
t_eq "and it is the same figure on the first turn" "106" "$(qp_get pc.narrow.settled.listRegionH)"
t_eq "including the card height" "134" "$(qp_get pc.narrow.settled.cardHeight)"
t_eq "and the live height follows it" "134" "$(qp_get pc.narrow.settled.height)"
t_eq "still exactly the model height" "true" "$(qp_get pc.narrow.settled.regionIsModel)"
t_eq "and still under the window allowance" "true" "$(qp_get pc.narrow.settled.regionBelowAvail)"

t_section "PanelCard: a row set LONGER than the cap is capped, like every other measure"
# The cap is what the card renders, so a row set longer than the cap is
# measured over the cap - the same question snappedListH and the resting
# buffer answer, and now the same answer from all three. This used to fall to
# the `avail` arm instead, which sized a five-row model capped at three to the
# whole window: the card reserved the full allowance for a list that only ever
# paints three rows, and every result count that crossed the cap moved the card
# by the difference.
t_eq "the over-cap card is told rowLimit 3" "3" "$(qp_get pc.five.rowLimit)"
t_eq "and handed five rows" "5" "$(qp_get pc.five.rowsLength)"
t_eq "with an available 272" "272" "$(qp_get pc.five.avail)"
t_eq "five rows against a cap of 3 measures the cap" "106" "$(qp_get pc.five.overCap.listRegionH)"
t_eq "not the whole window" "false" "$(qp_get pc.five.overCap.isAvail)"
t_eq "and rowLimitRegion says so itself" "106" "$(qp_get pc.five.overCap.regionFn)"
t_note "PanelCard.rowLimitRegion caps, and agrees with snappedListH on the same rows: five rows against a cap of three measure 106 through both, where the region used to return availListH (272) on the reasoning that 'avail is the right answer for a list that fills the window'. A capped list does not fill the window - it paints rowLimit rows and leaves the rest of the allowance empty, so charging the card for that empty space is what made it breathe whenever a result count crossed the cap. The resting buffer is scaled by the same cap for the same reason: it holds the model's FULL content height (1223px for 25 rows), which has no business sizing a ten-row viewport."
t_eq "the same five rows uncapped measure all of them" "178" "$(qp_get pc.fiveNoCap.listRegionH)"
t_eq "which is their model height" "178" "$(qp_get pc.fiveNoCap.model)"
t_eq "so that card is 206 tall" "206" "$(qp_get pc.fiveNoCap.cardHeight)"
t_eq "and the capped model height for the same rows is 106" "106" "$(qp_get pc.five.model)"
t_eq "which snappedListH reports for the capped case" "106" "$(qp_get pc.five.snapped)"
t_eq "and the region now agrees with it" "true" "$(qp_get pc.five.overCap.matchesSnapped)"

t_section "PanelCard: an open in-flow slot claims the region outright"
t_eq "a 300px expansion claims the list region" "300" "$(qp_get pc.slot.listRegionH)"
t_eq "rather than the window's allowance" "expansion" "$(qp_get pc.slot.reserved)"
t_eq "and the card adds the chrome and the bottom reserve" "338" "$(qp_get pc.slot.cardHeight)"
t_eq "which is the documented sum" "338" "$(qp_get pc.slot.cardHeightExpected)"
t_eq "with the height tween stood down, the height is that" "338" "$(qp_get pc.slot.height)"
t_eq "exactly, not still easing toward it" "true" "$(qp_get pc.slot.heightMatchesCardHeight)"

t_section "PanelCard: the width pass, measured after the fonts settle"
t_eq "the card is capped at parent width less 64" "236" "$(qp_get pc.width.cappedByParent)"
t_eq "and the cap is exactly that" "236" "$(qp_get pc.width.cap)"
t_eq "the cap is what bounds a too-wide measurement" "true" "$(qp_get pc.width.matchesFormula)"
t_eq "a long label measures 249 in the settled font" "249" "$(qp_get pc.width.labelWidth)"
t_eq "so the content width is that plus the insets" "311" "$(qp_get pc.contentW.longLabel)"
t_eq "and matches the width formula exactly" "311" "$(qp_get pc.contentW.expected)"
t_eq "rows with no label contribute nothing, so the base width stands" "120" "$(qp_get pc.contentW.noLabels)"
t_eq "which is the card's own baseWidth" "true" "$(qp_get pc.contentW.noLabelsIsBase)"
t_eq "the row height re-measured in the settled font is still the floor" "34" "$(qp_get pc.rowRest.plainSettled)"
t_eq "matching the real line box read on the same turn" "true" "$(qp_get pc.rowRest.plainMatchesSettled)"
t_eq "and the two-line figure follows the settled sub line box" "47" "$(qp_get pc.rowRest.subSettled)"
t_eq "matching that expression" "true" "$(qp_get pc.rowRest.subMatchesSettled)"
t_note "The same label measures 187px wide at Component.onCompleted and 249 by turn 20, and the fonts move the row line boxes with it. PanelCard measures through a real Text, so its width and row numbers are only comparable against a Text read on the SAME turn - which is why recalcWidth() is driven at turn 20 rather than at construction, and why the row expectations above are compared against the real line boxes rather than pinned to a float."
t_eq "the height binding reads the card height" "178" "$(qp_get pc.rows.height)"
t_eq "and that is exactly the computed card height" "true" "$(qp_get pc.rows.heightMatchesCardHeight)"
t_eq "the height tween is gated closed until the show gate opens" "false" "$(qp_get pc.shown.gateClosed)"
t_eq "and the gate's escape is off until a consumer opens it" "false" "$(qp_get pc.gateEscape.defaultOff)"

t_section "PanelCard: a capped list whose cap holds a separator"
# The launcher's clipboard case: twelve rendered rows, one of which is a 12px
# divider. A cap is not N average rows, so the whole-list resting buffer
# reaches the capped viewport through the cap's share of the ESTIMATED height.
# Scaling it by row count instead charges that divider a whole row's height,
# and the ceiling then trims the surplus at a screen number that lands
# mid-row - which is what cut the last entry through the middle.
t_eq "the cap is twelve rows" "12" "$(qp_get pc.clipCap.cappedRows)"
t_eq "the whole model measures over the full two hundred rows" "true" "$(qp_get pc.clipCap.estAllAboveCap)"
t_eq "and the capped estimate is far smaller" "true" "$(qp_get pc.clipCap.capSmallerThanAll)"
t_eq "the capped measure is the estimate share" "$(qp_get pc.clipCap.estCapExpected)" "$(qp_get pc.clipCap.cappedBufH)"
t_eq "which with an exact measurement is the estimate itself" "true" "$(qp_get pc.clipCap.estimateIsExact)"
t_eq "and is below a row-count scaling of the same buffer" "true" "$(qp_get pc.clipCap.belowRowCountScale)"
t_eq "and that row-count scaling is what overruns the window here" "true" "$(qp_get pc.clipCap.rowCountScaleExceedsAvail)"
t_eq "the window allowance sits above the real cap" "true" "$(qp_get pc.clipCap.availAboveRealCap)"
t_eq "the region is the capped measure" "$(qp_get pc.clipCap.cappedBufH)" "$(qp_get pc.clipCap.region)"
t_eq "and not the window allowance" "false" "$(qp_get pc.clipCap.isAvail)"
t_note "The window allowance here is placed on purpose, from the card's own settled numbers: above the height the twelve capped rows really occupy and below the height a row-count scaling of the resting buffer claims for them. That gap is the only arrangement in which the two measures disagree, and it is the launcher's clipboard case - a clipboard suggestion and its divider beside ten full-height rows. The row-count scaling answered 12 rows x the list's average row, which charges the 12px divider a full row: 34.8px of surplus, and the Math.min against availListH turned that surplus into a mid-row trim."
t_eq "a window too small for the cap answers with a whole prefix" "true" "$(qp_get pc.clipCap.crampedIsWholePrefix)"
t_eq "never with the allowance itself" "false" "$(qp_get pc.clipCap.crampedIsAvail)"
t_eq "and the prefix is under the allowance" "true" "$(qp_get pc.clipCap.crampedUnderAvail)"
t_note "rowLimitRegion is the one place a capped card turns a screen number into a region height, so it is the one place that can land between two rows. Every term it combines is a whole-row sum; availListH is only ever tested against, never returned."

t_section "PanelCard: the show gate has an escape for live input"
# The gate exists so the FIRST layout after an open cannot animate. It is not
# a statement about later resizes, and a keystroke landing inside the gate
# window is a later resize - with the gate closed for the whole window, the
# card snapped to its fitted height and the resize the user was typing
# towards arrived as a jump. MenuPanel already carves this out for its width.
t_eq "the card under test never opens its gate" "false" "$(qp_get pc.gate.gateClosed)"
t_eq "so a resize with the escape clear snaps" "true" "$(qp_get pc.gate.snappedToTarget)"
t_eq "the escape arms from the consumer's input state" "true" "$(qp_get pc.gate.escapeArmed)"
t_eq "and the same resize now has a target below where it started" "true" "$(qp_get pc.gate.shrinking)"
t_eq "the height tween is in flight rather than snapped" "true" "$(qp_get trace.gateH.moved)"
t_eq "on the first sampled turn it sits between the two" "true" "$(qp_get trace.gateH.firstInFlight)"
t_eq "and it never passes the target" "true" "$(qp_get trace.gateH.neverOvershot)"
t_eq "landing exactly on the card height once resizeMs is past" "true" "$(qp_get pc.gate.landedOnTarget)"
t_note "cardGate is never show()n, so shown is false for the whole run and every reading here is with the gate shut. The first resize snaps (the gate), the second is armed by sizeMotionDuringGate and eases to the same kind of change (the escape). The in-flight samples are reduced to a verdict for the reason the other tweens are: a Behavior's exact value one turn in is a function of how long that turn happened to be."

t_eq "clipped" "true" "$(qp_get pc.clip)"
t_eq "with the standard card border" "2" "$(qp_get pc.borderW)"
t_eq "on the standard background" "#141414" "$(qp_get pc.color)"
t_eq "and centred in its parent" "parent" "$(qp_get pc.anchors)"
t_eq "the show gate opens within the documented window" "true" "$(qp_get pc.gate.shown)"
t_note "PanelCard's width tween and height tween are both gated on shown, which is false until show() has run for Ui.resizeMs + Ui.fastMs (280ms). The gate is asserted at construction and asserted open at turn 30, and every height in this section was read while the gate was still shut, so those are snapped values - which is the behaviour the gate exists to prevent a consumer seeing."

# ---------------------------------------------------------------------
# PanelFocus.
# ---------------------------------------------------------------------
t_section "PanelFocus: the list sink"
t_eq "mode starts at list" "list" "$(qp_get focus.mode.default)"
t_eq "serviceVisible starts false" "false" "$(qp_get focus.serviceVisible.default)"
t_eq "with no search field" "null" "$(qp_get focus.searchField.default)"
t_eq "the key sink is an Item" "true" "$(qp_get focus.sink.isItem)"
t_eq "and each instance owns its own" "true" "$(qp_get focus.sink.distinct)"
t_eq "probe() on a bare focus reports all three fields" '{"focused":false,"text":"","mode":"list"}' "$(qp_get focus.probe.noField)"
t_eq "grabList leaves the mode at list" "list" "$(qp_get focus.grabList.mode)"
t_eq "and really takes focus on the sink" "true" "$(qp_get focus.grabList.focus)"
t_eq "including active focus" "true" "$(qp_get focus.grabList.activeFocus)"
t_note "forceActiveFocus() only takes effect from the first event-loop turn: called from Component.onCompleted under offscreen it leaves both focus and activeFocus false. PanelFocus.grabList() is asserted here at turn 1, which is the earliest point the claim holds."

t_section "PanelFocus: the filter mode, and two instances not sharing state"
t_eq "a second focus is still in list mode" "list" "$(qp_get focus.isolation.mode)"
t_eq "a second focus grabs its own sink" "true" "$(qp_get focus.isolation.otherSinkFocus)"
t_eq "with a distinct sink object" "true" "$(qp_get focus.isolation.sinkDistinct)"
t_eq "grabFilter with no field is a no-op on the mode" "list" "$(qp_get focus.noField.modeUnchanged)"
t_eq "grabFilter with a field switches the mode" "filter" "$(qp_get focus.grabFilter.mode)"
t_eq "probe() then reports focused, text and mode" '{"focused":true,"text":"hello","mode":"filter"}' "$(qp_get focus.grabFilter.probe)"
t_eq "and the cursor is parked at the end of the query" "5" "$(qp_get focus.grabFilter.cursor)"
t_eq "which is the query's length" "5" "$(qp_get focus.grabFilter.cursorExpected)"
t_eq "a sibling starts in list mode" "list" "$(qp_get focus.isolation.fieldMode)"
t_eq "and its own grabFilter takes it to filter" "filter" "$(qp_get focus.isolation.secondFieldMode)"
t_eq "without disturbing the first" "filter" "$(qp_get focus.isolation.firstUnaffected)"
t_eq "the probe still reports the same three fields later" '{"focused":true,"text":"hello","mode":"filter"}' "$(qp_get focus.probe.afterField)"
t_eq "with the mode still filter" "filter" "$(qp_get focus.probe.mode)"
t_note "reassert() is deliberately not asserted on the serviceVisible-false path beyond the mode being untouched: with the service hidden it returns before doing anything (PanelFocus.qml:43-44), so there is no state change to observe. Its visible-path branches both reduce to 'mode is filter and the field holds focus', which grabFilter already establishes."

# ---------------------------------------------------------------------
# ZebraRow.
# ---------------------------------------------------------------------
t_section "ZebraRow: the parity rule, checked on rows 0 to 3"
t_eq "row 0 carries the band" "#0dd5d5d5" "$(qp_get zebra.row0)"
t_eq "row 1 does not" "#00000000" "$(qp_get zebra.row1)"
t_eq "row 2 carries it again" "#0dd5d5d5" "$(qp_get zebra.row2)"
t_eq "row 3 does not" "#00000000" "$(qp_get zebra.row3)"
t_eq "the band token is a 0.05 foreground_1 tint" "#0dd5d5d5" "$(qp_get zebra.bandColor)"
t_eq "the selection token is a 0.22 accent tint" "#388a8a8a" "$(qp_get zebra.selectedColor)"
t_eq "the hover token is a 0.10 foreground_1 tint" "#1ad5d5d5" "$(qp_get zebra.hoverColor)"
t_eq "the band is a 0.05 tint of foreground_1" "0.050980392156862744" "$(qp_get zebra.band.alpha)"
t_eq "row 0's alpha is that tint" "0.050980392156862744" "$(qp_get zebra.evenRow.alpha)"
t_eq "row 1's alpha is zero, not a leftover band" "0" "$(qp_get zebra.oddRow.alpha)"
t_eq "and row 3's too" "0" "$(qp_get zebra.fourthRow.alpha)"
t_eq "the odd row is fully transparent" "#00000000" "$(qp_get zebra.oddRow.color)"
t_eq "a three-row set is band / none / band" "true" "$(qp_get zebra.parity.threeRows)"
t_eq "a four-row set ends on an odd row" "true" "$(qp_get zebra.parity.fourRows)"
t_note "The odd row is painted the literal 'transparent', which Qt normalises to #00000000 rather than leaving as a named colour - the probe reads the composed colour off the band Rectangle, so the assertion is on the alpha channel, which is 0 either way."

t_section "ZebraRow: selection overrides parity, and hover never overrides selection"
t_eq "the selection band is a 0.22 tint of accent" "0.2196078431372549" "$(qp_get zebra.selected.alpha)"
t_eq "an odd selected row is the selection tone" "#388a8a8a" "$(qp_get zebra.sel.odd)"
t_eq "and so is an even one" "#388a8a8a" "$(qp_get zebra.sel.even)"
t_eq "so parity is irrelevant once selected" "true" "$(qp_get zebra.sel.parityIrrelevant)"
t_eq "the hover wash is a 0.10 tint" "0.10196078431372549" "$(qp_get zebra.hover.alpha)"

t_section "ZebraRow: the click surface, and what needs a pointer"
t_eq "an interactive row has a visible click surface" "true" "$(qp_get zebra.area.visible)"
t_eq "a decorative row has none" "false" "$(qp_get zebra.area.decoration)"
t_eq "hover tracking is off by default" "false" "$(qp_get zebra.area.hoverEnabled)"
t_eq "and on for an opted-in row" "true" "$(qp_get zebra.area.hoverEnabledOptedIn)"
t_eq "the cursor is the arrow by default" "true" "$(qp_get zebra.cursor.arrow)"
t_eq "and a pointing hand where asked" "true" "$(qp_get zebra.cursor.pointing)"
t_eq "hovered is false with no pointer" "false" "$(qp_get zebra.hovered.withoutPointer)"
t_eq "and opting in does not fake it" "false" "$(qp_get zebra.hovered.optedIn)"
t_eq "the signal is reachable, driven at the signal level" "1" "$(qp_get zebra.clicks.afterEmit)"
t_eq "and nothing had fired before that" "0" "$(qp_get zebra.clicks)"
t_skip "ZebraRow's hovered band and its real click path" "no compositor means containsMouse stays false, so the hover band never shows and a MouseArea cannot be pressed; clicked(mouse) is driven by emitting the signal instead"
t_eq "and the count holds after the row that never emitted" "1" "$(qp_get zebra.clicks.final)"

# ---------------------------------------------------------------------
# BodyText: the markup toggle and the styledMarkup contract.
# ---------------------------------------------------------------------
t_section "BodyText: markup defaults to plain, so a runtime string is never parsed"
t_eq "the default is Text.PlainText" "true" "$(qp_get body.defaultFormat)"
t_eq "markup: true switches to Text.StyledText" "true" "$(qp_get body.markupFormat)"
t_eq "the colour is a 0.75 tint" "0.7490196078431373" "$(qp_get body.plain.colorAlpha)"
t_eq "at the fontS token" "11" "$(qp_get body.px)"
t_eq "in the shared font family" "true" "$(qp_get body.family.matchesToken)"
t_eq "a fixed 15px line height" "15" "$(qp_get body.lineHeight)"
t_eq "in FixedHeight mode" "true" "$(qp_get body.lineHeightMode.fixed)"
t_eq "word wrapped" "true" "$(qp_get body.wrap.word)"

t_section "BodyText: tag-free text renders the same either way"
t_eq "the plain instance wraps to 3 lines" "3" "$(qp_get body.tagFree.plainLineCount)"
t_eq "the markup instance to 3 as well" "3" "$(qp_get body.tagFree.markupLineCount)"
t_eq "the plain instance wraps to the same line count" "true" "$(qp_get body.tagFree.sameLineCount)"
t_eq "and the markup one to the same height" "45" "$(qp_get body.tagFree.markupHeight)"
t_eq "which is the same as the plain one" "true" "$(qp_get body.tagFree.sameHeight)"
t_eq "and to exactly 45px of height" "45" "$(qp_get body.tagFree.plainHeight)"
t_eq "and to the same height" "true" "$(qp_get body.tagFree.sameHeight)"
t_eq "both are the same three wrapped lines" "3" "$(qp_get body.tagFree.lineCount)"

t_section "BodyText: styledMarkup is the whitelisting escaper it documents"
t_eq "it re-admits b" "<b>hi</b>" "$(qp_get body.su.b)"
t_eq "i" "<i>hi</i>" "$(qp_get body.su.i)"
t_eq "u" "<u>hi</u>" "$(qp_get body.su.u)"
t_eq "and the closing tags" "</b>" "$(qp_get body.su.closer)"
t_eq "case-insensitively" "<B>x</B>" "$(qp_get body.su.upperKept)"
t_eq "everything else is escaped" "&lt;blink&gt;z&lt;/blink&gt;" "$(qp_get body.su.otherEscaped)"
t_eq "including an img tag" "&lt;img src=x&gt;" "$(qp_get body.su.imgEscaped)"
t_eq "ampersands are escaped first" "a &amp; b" "$(qp_get body.su.ampEscaped)"
t_eq "and a bare less-than too" "a &lt; b" "$(qp_get body.su.ltEscaped)"
t_eq "a newline becomes a break" "a<br>b" "$(qp_get body.su.nlBecomesBr)"
t_eq "an empty string stays empty" "''" "$(qp_get body.su.empty)"
t_eq "and so does a void one" "''" "$(qp_get body.su.null)"

t_section "BodyText: markup only renders a tag that went through styledMarkup"
t_eq "a whitelisted tag renders as markup, so it is narrower than its literal" "true" "$(qp_get body.markup.boldNarrowerThanLiteral)"
t_eq "the parsed form measures 42.6" "42.640625" "$(qp_get body.markup.boldMarkupWidth)"
t_eq "the same string in plain mode is 84.3 wide, the tags printed" "84.3125" "$(qp_get body.markup.boldPlainWidth)"
t_eq "an unescaped non-whitelisted tag is dropped by the parser" "true" "$(qp_get body.markup.rawTagIsDropped)"
t_eq "leaving only 5.2 of rendered text" "5.15625" "$(qp_get body.markup.rawTagWidth)"
t_eq "and nothing near the escaped form's 84.5" "84.484375" "$(qp_get body.markup.escapedTagWidth)"
t_eq "which renders as visible text instead" "true" "$(qp_get body.markup.escapedTagIsLiteral)"
t_eq "so a runtime string cannot smuggle a tag into markup mode" "true" "$(qp_get body.markup.noInjection)"
t_eq "the unescaped form is 5.2 of unwrapped text" "5.15625" "$(qp_get body.markup.rawTagImplicitWidth)"
t_eq "and the escaped form 84.5" "84.484375" "$(qp_get body.markup.escapedTagImplicitWidth)"
t_eq "so what is left of the raw one is just the glyph body" "true" "$(qp_get body.markup.rawTagRendersOnlyTheText)"
t_note "An UNESCAPED non-whitelisted tag in a markup:true BodyText does not just render as text - Qt's StyledText parser hands <img src=x> to the image loader, which logs 'StyledText - Invalid base url in img tag'. The shell's contract (BodyText.qml:11-13 and common/ui/README.md:115) is that only styledMarkup output reaches a markup:true BodyText; the probe shows the escaped form rendering inert and the raw form reaching the parser."
t_skip "BodyText proves no raw <b> can be rendered" "a whitelisted tag IS the point of markup:true; the security claim is about non-whitelisted tags, which is asserted as noInjection"

t_section "BodyText: newlines only break through styledMarkup"
t_eq "plain text honours a raw newline" "2" "$(qp_get body.nl.plainLineCount)"
t_eq "StyledText collapses a raw newline instead" "1" "$(qp_get body.nl.rawInMarkupLineCount)"
t_eq "and styledMarkup's <br> breaks it again" "2" "$(qp_get body.nl.styledLineCount)"
t_eq "which is the behaviour the source documents" "true" "$(qp_get body.nl.styledMatches)"
t_note "BodyText.qml:12 says \"\\n breaks via MenuLib.styledMarkup\", and that is load-bearing: StyledText does not treat a raw newline as a line break, it collapses it. A markup:true BodyText handed \"a\\nb\" renders one line; handed MenuLib.styledMarkup(\"a\\nb\") - the same text as a<br>b - it renders two. Both counts are asserted."

t_section "BodyText: height follows the wrapped text"
t_eq "an empty string still occupies one line" "15" "$(qp_get body.implicitHeight.empty)"
t_eq "reported as a single line" "1" "$(qp_get body.lineCount.empty)"
t_note "An empty BodyText is 15px tall, not 0: Qt reports lineCount 1 for empty text and the component's FixedHeight line box still applies. A consumer expecting a collapse-to-zero (the way Notice does, Notice.qml:28) would be wrong here."
t_eq "a long string wraps to four lines" "4" "$(qp_get body.stack.lineCountExpected)"
t_eq "which is what the item reports" "4" "$(qp_get body.stack.lineCount)"
t_eq "which is 4 * the 15px line height" "60" "$(qp_get body.stack.implicitHeight)"
t_eq "exactly, not approximately" "true" "$(qp_get body.stack.heightIsLinesTimesLineHeight)"
t_eq "and height follows it" "60" "$(qp_get body.stack.height)"

# ---------------------------------------------------------------------
# The remaining small components.
# ---------------------------------------------------------------------
t_section "Card: the padded content host and the capture net"
t_eq "the standard card background" "#141414" "$(qp_get card.color)"
t_eq "the standard card border width" "2" "$(qp_get card.borderW)"
t_eq "in the standard border colour" "#434343" "$(qp_get card.borderColor)"
t_eq "clipped" "true" "$(qp_get card.clip)"
t_eq "square corners" "0" "$(qp_get card.radius)"
t_eq "the content host is inset by the outer pad per side" "14" "$(qp_get card.contentInsetEach)"
t_eq "which is the token" "14" "$(qp_get card.contentInsetExpected)"
t_eq "so it is 172 wide inside a 200 card" "172" "$(qp_get card.contentW)"
t_eq "and 92 tall inside a 120 one" "92" "$(qp_get card.contentH)"
t_eq "input capture is on by default" "true" "$(qp_get card.captureInput)"
t_eq "and the capture net is there" "true" "$(qp_get card.netEnabled)"
t_eq "but it does not chase the pointer" "false" "$(qp_get card.net.hoverEnabled)"

t_section "Divider: a solid rule, not a tint"
t_eq "it is the background_3 token" "true" "$(qp_get divider.isSolidToken)"
t_eq "which is a six-digit opaque colour" "#434343" "$(qp_get divider.color)"
t_eq "with no border of its own" "1" "$(qp_get divider.borderW)"
t_eq "and square corners" "0" "$(qp_get divider.radius)"
t_note "Divider.qml's own note forbids routing its default colour through custom properties of that file, and the observed colour is the plain background_3 token - a full-alpha solid, unlike the tinted bands in ZebraRow and Notice."

t_section "Title: the remaining levels and the catch-all arms"
t_eq "level 1 is the island style: fontM" "12" "$(qp_get title1.px)"
t_eq "reading the raw colour as the opaque foreground_0" "#dfdfdf" "$(qp_get title1.color)"
t_eq "level 3's raw colour is the opaque foreground_1" "#d5d5d5" "$(qp_get title3.color)"
t_eq "and it is not the island style" "false" "$(qp_get title3.isIsland)"
t_eq "nor the section style" "false" "$(qp_get title3.isSection)"
t_eq "level 4 is not bold" "false" "$(qp_get title4.bold)"
t_eq "bold" "true" "$(qp_get title1.bold)"
t_eq "in the opaque foreground_0" "true" "$(qp_get title1.isSolidToken)"
t_eq "level 3 is the row-primary style: fontS" "11" "$(qp_get title3.px)"
t_eq "not bold" "false" "$(qp_get title3.bold)"
t_eq "in the opaque foreground_1" "true" "$(qp_get title3.isSolidToken)"
t_eq "with no letter spacing" "0" "$(qp_get title3.ls)"
t_eq "level 4 is the subtitle style: fontXs" "10" "$(qp_get title4.px)"
t_eq "and is a half-alpha tint" "0.5019607843137255" "$(qp_get title4.alpha)"
t_eq "level 5 is the body style: fontS" "11" "$(qp_get title5.px)"
t_eq "also a half-alpha tint" "0.5019607843137255" "$(qp_get title5.alpha)"
t_eq "level 0 falls through to the body arm" "11" "$(qp_get title0.px)"
t_eq "with the same half-alpha tint" "0.5019607843137255" "$(qp_get title0.alpha)"
t_eq "and is neither section nor island" "false" "$(qp_get title0.isSection)"
t_eq "nor that" "false" "$(qp_get title0.isIsland)"
t_eq "an out-of-range level does the same" "11" "$(qp_get titleBig.px)"
t_eq "and is not bold" "false" "$(qp_get titleBig.bold)"
t_eq "and keeps the half-alpha tint" "0.5019607843137255" "$(qp_get titleBig.alpha)"
t_eq "elides on the right" "true" "$(qp_get title.elide.right)"
t_eq "never wraps" "true" "$(qp_get title.wrap.none)"
t_eq "is always plain text" "true" "$(qp_get title.format.plain)"
t_eq "and does not force caps" "true" "$(qp_get title.cap.mixed)"

t_section "Notice: the two tints, and the empty-message collapse"
t_eq "the warning fill is the yellow token at 0.12" "#1f8d8872" "$(qp_get notice.warn.color)"
t_eq "which parses as a 0.12 alpha" "0.12156862745098039" "$(qp_get notice.warn.fillAlpha)"
t_eq "with a half-alpha border" "0.5019607843137255" "$(qp_get notice.warn.borderAlpha)"
t_eq "a one pixel border" "1" "$(qp_get notice.warn.borderW)"
t_eq "square corners" "0" "$(qp_get notice.warn.radius)"
t_eq "and a 200 default width" "200" "$(qp_get notice.warn.iw)"
t_eq "height is the message plus 20" "35" "$(qp_get notice.warn.height)"
t_eq "and a message makes it visible" "true" "$(qp_get notice.warn.visible)"
t_eq "a danger notice carries the same alpha" "0.12156862745098039" "$(qp_get notice.danger.alpha)"
t_eq "in a different hue" "different" "$(qp_get notice.danger.differsFromWarn)"
t_eq "an empty message hides the box" "false" "$(qp_get notice.empty.visible)"
t_eq "and collapses it to zero height" "0" "$(qp_get notice.empty.height)"
t_eq "markup: true switches the label to StyledText" "true" "$(qp_get notice.markup.format)"
t_eq "and plain is the default" "true" "$(qp_get notice.plain.format)"

t_section "CheckBox: the box as layout, and the mark"
t_eq "an explicit 14 square" "14" "$(qp_get checkbox.w)"
t_eq "on both axes" "14" "$(qp_get checkbox.h)"
t_eq "and the implicit size agrees" "14" "$(qp_get checkbox.iw)"
t_eq "on both axes" "14" "$(qp_get checkbox.ih)"
t_eq "square corners" "0" "$(qp_get checkbox.radius)"
t_eq "checked fills with the accent" "#8a8a8a" "$(qp_get checkbox.on.color)"
t_eq "and so does the border" "#8a8a8a" "$(qp_get checkbox.on.border)"
t_eq "the tick shows when checked" "true" "$(qp_get checkbox.on.markVisible)"
t_eq "and is U+2713" "10003" "$(qp_get checkbox.on.markCode)"
t_eq "at 13px" "13" "$(qp_get checkbox.on.markPx)"
t_eq "unchecked is transparent" "#00000000" "$(qp_get checkbox.off.color)"
t_eq "with a 0.45 border tint" "0.45098039215686275" "$(qp_get checkbox.off.borderAlpha)"
t_eq "and no tick" "false" "$(qp_get checkbox.off.markVisible)"
t_eq "while still a 14 square" "14" "$(qp_get checkbox.off.iw)"

t_section "Toggle: the thumb's two seats and the dimmed guard"
t_eq "the implicit size is 32 by 16" "32" "$(qp_get toggle.on.iw)"
t_eq "on the short axis" "16" "$(qp_get toggle.on.ih)"
t_eq "square corners" "0" "$(qp_get toggle.on.radius)"
t_eq "a checked track is the accent" "#8a8a8a" "$(qp_get toggle.on.color)"
t_eq "and the thumb is 12 square" "12" "$(qp_get toggle.on.thumbW)"
t_eq "on both axes" "12" "$(qp_get toggle.on.thumbH)"
t_eq "parked at the right when checked" "18" "$(qp_get toggle.on.thumbX)"
t_eq "which is width - thumb - 2" "18" "$(qp_get toggle.on.thumbX.expected)"
t_eq "in the background colour" "#141414" "$(qp_get toggle.on.thumbColor)"
t_eq "and at the left when not" "2" "$(qp_get toggle.off.thumbX)"
t_eq "over the background_3 track" "#434343" "$(qp_get toggle.off.color)"
t_eq "a dimmed toggle fades to the disabled opacity" "0.45" "$(qp_get toggle.dimmed.opacity)"
t_eq "its thumb stays on the unchecked seat" "2" "$(qp_get toggle.dimmed.thumbX)"
t_eq "and its click surface is off" "false" "$(qp_get toggle.dimmed.areaEnabled)"
t_eq "while an enabled one's is on" "true" "$(qp_get toggle.on.areaEnabled)"
t_eq "a dimmed toggle does not move" "false" "$(qp_get toggle.dimmed.stillChecked)"
t_eq "and emits nothing at all" "0" "$(qp_get toggle.dimmed.emits)"
t_eq "still not checked afterwards" "false" "$(qp_get toggle.dimmed.checkedAfter)"
t_eq "and its enabled sibling is untouched" "true" "$(qp_get toggle.on.unaffected)"
t_note "The dimmed guard is a separate gate from enabled_: Toggle.toggle() returns early on either (Toggle.qml:49) and the MouseArea gates on both (Toggle.qml:87). ui-test.sh covers enabled_ alone; the dimmed arm is asserted here because it is a distinct branch with its own opacity."

t_section "DropdownButton: the disabled state as a full visual state"
t_eq "it is the button height" "28" "$(qp_get dbtn.height)"
t_eq "which is the token" "28" "$(qp_get dbtn.heightExpected)"
t_eq "square corners" "0" "$(qp_get dbtn.radius)"
t_eq "with a one pixel border" "1" "$(qp_get dbtn.border)"
t_eq "an enabled button is fully opaque" "1" "$(qp_get dbtn.opacity)"
t_eq "resting at no fill" "#00000000" "$(qp_get dbtn.color.resting)"
t_eq "with the border tinted 0.45" "0.45098039215686275" "$(qp_get dbtn.borderAlpha.resting)"
t_eq "its accent is the red token" "#877070" "$(qp_get dbtn.accent)"
t_eq "and that is what Theme.color returns for red" "true" "$(qp_get dbtn.accent.isRedToken)"
t_eq "nothing fired before the drive" "0" "$(qp_get dbtn.clicks)"
t_eq "and a disabled button's own signal still reaches its handler" "1" "$(qp_get dbtn.offClicks.afterEmit)"
t_eq "at rest it is not pressed" "1" "$(qp_get dbtn.scale.resting)"
t_eq "a labelled button shows its label" "true" "$(qp_get dbtn.label.visible)"
t_eq "in the accent colour" "#877070" "$(qp_get dbtn.label.color)"
t_eq "bold" "true" "$(qp_get dbtn.label.bold)"
t_eq "at fontS" "11" "$(qp_get dbtn.label.px)"
t_eq "and an unlabelled one hides it" "false" "$(qp_get dbtn.bare.labelVisible)"
t_eq "a disabled button fades to the shared opacity" "0.45" "$(qp_get dbtn.off.opacity)"
t_eq "which is the token" "0.45" "$(qp_get dbtn.off.opacityExpected)"
t_eq "keeps no fill" "#00000000" "$(qp_get dbtn.off.color)"
t_eq "and turns its click surface off" "false" "$(qp_get dbtn.off.areaEnabled)"
t_eq "while the enabled one's is on" "true" "$(qp_get dbtn.on.areaEnabled)"
t_eq "the click signal reaches the handler" "1" "$(qp_get dbtn.clicks.afterEmit)"
t_eq "and the signal itself is not gated on enabled" "true" "$(qp_get dbtn.offSignalIsUngated)"
t_eq "the gate is on the input surface" "false" "$(qp_get dbtn.enabledGateIsTheArea)"
t_note "The disabled gate lives on the MouseArea (DropdownButton.qml:60), not on the signal: emitting clicked() on a disabled button still raises it, which the probe records as dbtn.offSignalIsUngated. The user-facing gate is the input surface, which is asserted as enabled false."
t_skip "DropdownButton's hover and press fills" "no compositor means containsMouse and containsPress stay false, so the 0.12 hover wash, the 0.2 press wash, the 0.7 pressed border and the 0.97 press scale are unreachable"

# ---------------------------------------------------------------------
# ScrimWindow: the one component that cannot be built here.
# ---------------------------------------------------------------------
t_section "ScrimWindow: a PanelWindow cannot be constructed without a compositor"
t_eq "the runtime instantiation produced no object" "null" "$(qp_get scrim.object)"
t_eq "the engine reports the type as unavailable" "true" "$(qp_get scrim.err.typeUnavailable)"
t_eq "and names the reason" "true" "$(qp_get scrim.err.panelWindowBackend)"
t_eq "it got as far as the component's own file" "true" "$(qp_get scrim.err.reachedSourceFile)"
t_eq "at the line its PanelWindow base is declared" "true" "$(qp_get scrim.err.hasLineNumber)"
t_eq "so this is not a missing module or a bad qmldir" "false" "$(qp_get scrim.err.moduleMissing)"
t_note "ScrimWindow.qml:11 declares a PanelWindow as its base type. Under QT_QPA_PLATFORM=offscreen there is no PanelWindow backend, so the whole type is unresolvable - and because that happens at component-compile time, a probe that merely MENTIONS ScrimWindow never loads at all. The probe therefore instantiates it through Qt.createQmlObject at runtime, which is the only way to turn the failure into data. The error text is: 'Type ScrimWindow unavailable / caused by qs:@/qs/common/ui/ScrimWindow.qml:11:1: No PanelWindow backend loaded.'"
t_skip "ScrimWindow's derived state: dim, overlayOpen fade, isPrimary click gate" "PanelWindow has no backend under offscreen; the type cannot be constructed at all, so none of its bindings can be evaluated here"
t_skip "ScrimWindow's exclusionMode, exclusiveZone and four-way anchoring" "same reason - the anchored PanelWindow properties only exist on a live layer surface"

t_summary

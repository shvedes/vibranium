#!/bin/bash
# Suite: menu-row-height - a menu row's resting height is a function of its
# KIND, and that holds at every font scale.
#
# The menu sizes its card from the model, before a delegate exists, and the
# delegate lays the same row out for real. Those two answers used to be a
# measurement of the row's own strings - hidden probe Texts, cached per label
# and per sub line - so they agreed only while both shaped the same text.
#
# The rule is `features/menu/RowRule.js`: pinned line boxes
# (`ceil(FontMetrics.height)`) turn a rest height into arithmetic over a token
# set, and `RowGeometry` is the singleton that supplies the tokens - the
# compact primary pair and the taller fallback pair, selected per row by the
# script its copy draws. This suite is both halves of the claim:
#
#   * MEASURED, in the real engine, over every row of the shipped settings
#     catalog plus a fallback-face fixture, at 1.0, 1.25, 1.5 and 2.0: the pin
#     never gives a string more than a pixel of real line less than the engine
#     lays out, the pinned line is ONE number per register, and the rest heights
#     the shipped arithmetic produces are the token arithmetic.
#   * CLASSIFIED, over every row of that bundle: each row lands in exactly one
#     kind, and the two projections the menu uses (the panel's install-time
#     projection, the delegate's rendered copy) agree on every one of them.
#
# Why the assertions are not vacuous:
#
#   * the pin must be ONE number per register and equal ceil(FontMetrics
#     .height). The failure mode is a missing lineHeightMode, which silently
#     leaves the natural line box in place and returns plausible numbers per
#     string.
#   * a one-line row must land ON the Ui.rowMinH floor while a two-line row is
#     genuinely taller than it - a rule that floored everything would satisfy
#     the first and fail the second.
#   * natural line boxes must NOT be one number across the same strings. That is
#     the control: it is why the per-string cache existed, and it is why
#     deleting it needed a pin rather than an argument.
#   * the scale axis must be a real axis: the pin at 2.0 has to be taller than
#     at 1.0, or "holds at four scales" would be one scale asserted four times.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "menu-row-height" "a row's resting height is a function of its kind, at every font scale"

require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/menu-row-height.qml" 60; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "0" "$(qp_get threw)"
t_eq "and ran to its sentinel" "1" "$(qp_get done)"

# ---------------------------------------------------------------------
t_section "every row of the shipped bundle classifies into one kind"

t_eq "the settings catalog was read" "1" "$(qp_get catalog.loaded)"
t_true "and its bytes arrived" test "$(qp_get catalog.bytes)" -gt 1000
t_true "and a row corpus worth classifying" test "$(qp_get rows.total)" -gt 100
# The classification is closed: anything else is a kind the card has no height
# for, which would silently fall through to a one-line row.
t_eq "no row lands outside the three kinds" "0" "$(qp_get rows.unknown)"
# The panel resolves a provider override at install and the delegate renders
# the copy it draws. Same rule, two projections, one answer per row - this is
# the assertion that the two halves cannot classify a row differently.
t_eq "the panel's projection and the delegate's agree on every row" \
  "0" "$(qp_get rows.mismatch)"
t_true "and a two-line row" test "$(qp_get rows.sub)" -gt 0
t_true "and a one-line row" test "$(qp_get rows.line)" -gt 0
# Theme rows are not in the catalog: the picker builds that page at runtime, so
# the theme kind is pinned by the unit suite's classification instead.
t_note "kind coverage here: $(qp_get rows.line) one-line, $(qp_get rows.sub) two-line, $(qp_get rows.theme) theme rows. A theme page is built at runtime by the theme picker and is not part of the shipped catalog."
t_true "the fixture and the bundle's own copy both get measured" \
  test "$(qp_get sample.strings)" -gt 16

# ---------------------------------------------------------------------
t_section "one pinned line per register, at four font scales"

t_eq "the probe measured four scales" "4" "$(qp_get scales)"
t_true "the axis is real: a 2.0 pin is taller than a 1.0 pin" \
  test "$(qp_get s.3.labelLineH)" -gt "$(qp_get s.0.labelLineH)"

for i in 0 1 2 3; do
  p="s.$i."
  t_eq "scale $i: every title line is ONE height" \
    "$(qp_get "${p}pinMin")" "$(qp_get "${p}pinMax")"
  t_eq "and it is the shipped title token" \
    "$(qp_get "${p}labelLineH")" "$(qp_get "${p}pinMin")"
  t_eq "scale $i: every sub line is ONE height" \
    "$(qp_get "${p}pinSubMin")" "$(qp_get "${p}pinSubMax")"
  t_eq "and it is the shipped sub token" \
    "$(qp_get "${p}subLineH")" "$(qp_get "${p}pinSubMin")"
done

# ---------------------------------------------------------------------
t_section "a row takes the register its own script needs"

# The token is selected per row from a script test, not measured per string.
# A Latin-only row must stay on the primary face: if one Arabic title pushed
# every row onto the fallback token, the page would be uniformly tall again.
t_eq "a Latin-only label stays on the primary face" "0" "$(qp_get script.latin)"
t_eq "accented Latin stays on it too" "0" "$(qp_get script.accents)"
t_eq "a CJK label reaches a fallback face" "1" "$(qp_get script.mgcjk)"
t_eq "Arabic reaches one" "1" "$(qp_get script.arabic)"
t_eq "Devanagari reaches one" "1" "$(qp_get script.hindi)"
t_eq "emoji reach one" "1" "$(qp_get script.emoji)"

for i in 0 1 2 3; do
  p="s.$i."
  t_true "scale $i: the primary title line is no taller than the fallback token" \
    test "$(qp_get "${p}primaryLabelLineH")" -le "$(qp_get "${p}labelLineH")"
  t_true "scale $i: nor the primary sub line" \
    test "$(qp_get "${p}primarySubLineH")" -le "$(qp_get "${p}subLineH")"
  t_eq "scale $i: a Latin-only one-line row is the primary line arithmetic" \
    "$(qp_get "${p}expectPrimaryLine")" "$(qp_get "${p}primaryRestLine")"
  t_eq "scale $i: a Latin-only two-line row is the primary line arithmetic" \
    "$(qp_get "${p}expectPrimarySub")" "$(qp_get "${p}primaryRestSub")"
done

# The control: without the pin the same strings take several heights. Only
# asserted at 1.0 - it is a property of faces, not of scale.
t_true "natural title line boxes are string-dependent on this host" \
  test "$(qp_get s.0.natDistinct)" -ge 2

# ---------------------------------------------------------------------
t_section "the pin covers every string at every scale"

for i in 0 1 2 3; do
  p="s.$i."
  # The bound is the SHORTFALL the pin may leave, and it is not one pixel at
  # every size. The only string that falls short is a CJK face, whose line box
  # is taller than the UI font's metrics: 1px at 13px, 2px at 1.25, 3px at 2.0 -
  # the fallback face's line box scales with the size it is set at, so a bound
  # written in pixels has to scale too. A bound that did not would either fail
  # the axis it was written for or hide a real clip at 1.0.
  # The bound is the SHORTFALL the pin may leave, and it is not one pixel at
  # every size. The only string that falls short is a CJK face, whose line box
  # is taller than the UI font's metrics: 1px at 13px, 2px at 1.25, 3px at 1.5
  # and 3px at 2.0 - the fallback face's line box scales with the size it is set
  # at, so a bound written in one pixel would fail the axis it was written for.
  # Measured, the excess is at most ~2px per 13px of font; the bound is its
  # doubling, which is loose enough to be a property and tight enough to catch a
  # pin that stopped scaling at all.
  t_true "scale $i: the title pin stays within the fallback face's scaling excess" \
    awk -v s="$(qp_get "${p}shortLabel")" -v f="$(qp_get "${p}scale")" 'BEGIN { exit !(s <= int(2 * f + 0.999)) }'
  t_true "scale $i: nor the sub pin, against the StyledText line the copy renders with" \
    awk -v s="$(qp_get "${p}shortSub")" -v f="$(qp_get "${p}scale")" 'BEGIN { exit !(s <= int(2 * f + 0.999)) }'
  t_true "scale $i: nor the separator pin against a bold breadcrumb" \
    awk -v s="$(qp_get "${p}shortSep")" -v f="$(qp_get "${p}scale")" 'BEGIN { exit !(s <= int(2 * f + 0.999)) }'
  t_note "scale $i: largest shortfalls $(qp_get "${p}shortLabel")px title ($(qp_get "${p}shortLabelText")), $(qp_get "${p}shortSub")px sub ($(qp_get "${p}shortSubText")), $(qp_get "${p}shortSep")px separator"
done
# At the shipped size the pin is within a pixel, which is the bound the row's
# own Text clips by today.
t_true "at 1.0 the pin is within one pixel of the engine's line" \
  awk -v s="$(qp_get s.0.shortLabel)" 'BEGIN { exit !(s <= 1) }'

# ---------------------------------------------------------------------
t_section "so a rest height follows from the rule, at every scale"

for i in 0 1 2 3; do
  p="s.$i."
  t_eq "scale $i: a one-line row is the title line plus padding, floored" \
    "$(qp_get "${p}expectLine")" "$(qp_get "${p}restLine")"
  t_eq "scale $i: a two-line row adds the sub line and the gap above it" \
    "$(qp_get "${p}expectSub")" "$(qp_get "${p}restSub")"
  t_eq "scale $i: a theme row adds the swatch strip and the gap above it" \
    "$(qp_get "${p}expectTheme")" "$(qp_get "${p}restTheme")"
  t_eq "scale $i: a labeled separator is its breadcrumb plus breathing" \
    "$(qp_get "${p}expectSep")" "$(qp_get "${p}restSep")"
  t_true "scale $i: a two-line row is taller than a one-line row" \
    test "$(qp_get "${p}restSub")" -gt "$(qp_get "${p}restLine")"
done

# The floor is load-bearing in one direction and must not swallow the other.
# WHICH SIDE BINDS IS THE FONT'S ANSWER, NOT THE RULE'S: the floor wins only
# while the title line fits under it, and a host whose fallback face lays a
# title out taller than Ui.rowMinH legitimately gets a taller one-line row (the
# rule is max(rowMinH, line), asserted above at every scale). So pin the floor
# where it binds and the non-undercut where the line has outgrown it.
if test "$(qp_get s.0.expectLine)" -le "$(qp_get s.0.rowMinH)"; then
  t_eq "a one-line row at the shipped scale lands on the Ui.rowMinH floor" \
    "$(qp_get s.0.rowMinH)" "$(qp_get s.0.restLine)"
else
  t_true "a one-line row at the shipped scale clears the Ui.rowMinH floor" \
    test "$(qp_get s.0.restLine)" -ge "$(qp_get s.0.rowMinH)"
  t_note "a $(qp_get s.0.labelLineH)px title line outgrows the $(qp_get s.0.rowMinH)px floor on this host, so the line sets a one-line row and the floor only guards the shorter rows"
fi
t_eq "a bare separator is the hairline, not a row" "$(qp_get s.0.rowMinH)" \
  "$(awk -v v="$(qp_get s.0.restSepBare)" -v f="$(qp_get s.0.rowMinH)" 'BEGIN { print (v < f) ? f : v }')"

# ---------------------------------------------------------------------
t_section "one rule, in one file, called by both halves"

MENU_DIR="$SHELL_DIR/features/menu"
GEO_SRC="$(<"$MENU_DIR/RowGeometry.qml")"
RULE_SRC="$(<"$MENU_DIR/RowRule.js")"
ENTRY_SRC="$(<"$MENU_DIR/Entry.qml")"
MENU_SRC="$(<"$MENU_DIR/MenuPanel.qml")"
MENU_LIB_SRC="$(<"$MENU_DIR/MenuLib.js")"
PANEL_WIDTH_SRC="$(<"$MENU_DIR/MenuWidth.qml")"

t_contains "the arithmetic turns a kind into a column height" "function colH(kind, g)" "$RULE_SRC"
t_contains "and a kind into a rest height" "function restH(kind, g)" "$RULE_SRC"
t_contains "and answers the separator on its own" "function restSeparator(hasLabel, g)" "$RULE_SRC"
t_contains "the singleton supplies the tokens and asks the rule" "RowRule.restH(kind, root.tokens)" "$GEO_SRC"
t_contains "its line tokens are the font metrics, ceiled over the fallback chain" \
  "Math.ceil(Math.max(root.labelMetrics.height, root.labelFallbackMetrics.height))" "$GEO_SRC"
t_contains "and it is a module singleton, one instance per process" \
  "singleton RowGeometry 1.0 RowGeometry.qml" "$(<"$MENU_DIR/qmldir")"

t_contains "the delegate takes its rest height from the singleton, per row" \
  "RowGeometry.restHFor(row.restKind, row.labelLineH, row.subLineH)" "$ENTRY_SRC"
t_contains "and its text column from the same rule" \
  "RowGeometry.colHFor(row.restKind, row.labelLineH, row.subLineH)" "$ENTRY_SRC"
t_contains "and its separator from the same rule" \
  "RowGeometry.restSeparatorFor(row.sepLabel !== \"\", row.subLineH)" "$ENTRY_SRC"
t_contains "the panel's model-side estimate reads the projected height" \
  "panel.rowFacts(itm).restH" "$MENU_SRC"
t_contains "which the same rule projected at install" \
  "RowGeometry.restHFor(kind, labelH, subH)" "$MENU_SRC"
t_contains "and the same separator answer" \
  "RowGeometry.restSeparatorFor(lbl !== \"\", lineH)" "$MENU_SRC"

# A row's line tokens are selected from its OWN copy: a Latin-only row rests
# on the primary face, and only a row that reaches a fallback face takes the
# taller token. Without this the tallest script on the page sizes every row.
t_contains "the rule classifies a string by the script it draws" \
  "function needsFallbackLine(text)" "$RULE_SRC"
t_contains "and the singleton selects the register per row" \
  "function labelHFor(text)" "$GEO_SRC"
t_contains "the delegate asks for its own label register" \
  "RowGeometry.labelHFor(row.displayLabel)" "$ENTRY_SRC"
t_contains "and its own sub register" \
  "RowGeometry.subHFor(RowGeometry.subSampleFor(itm, row.subText))" "$ENTRY_SRC"
t_contains "the panel projects the same two registers" \
  "RowGeometry.labelHFor(String(it.label" "$MENU_SRC"
t_contains "a chrome row (the inline editor) rests on the primary register" \
  "RowGeometry.primaryRestH(\"line\")" "$(<"$MENU_DIR/InlineEditor.qml")"

# One instance means nobody instantiates one. An Item here would be a second
# pair of FontMetrics per delegate, which is what the singleton removed.
t_not_contains "the delegate instantiates no geometry item" "RowGeometry {" "$ENTRY_SRC"
t_not_contains "nor does the panel" "RowGeometry {" "$MENU_SRC"

# The kind is decided in ONE place. Four files may name it: the module that
# owns the rule (MenuRow.js), the MenuLib facade that publishes it, and the two
# readers. A fifth would be a copy that drifts; a second definition would be a
# rule that can disagree with itself.
t_eq "the row kind is decided in exactly one module file" "1" \
  "$(grep -l "function restKind" "$MENU_DIR"/*.js | grep -v 'MenuLib.js' | wc -l | tr -d ' ')"
t_contains "and MenuLib publishes it as a one-line delegate" \
  "function restKind(item, providerSub) { return Row.restKind(item, providerSub) }" "$MENU_LIB_SRC"
t_eq "and the facade plus the two readers name it in four files" "4" \
  "$(grep -rl "restKind" "$MENU_DIR" --include='*.js' --include='*.qml' | wc -l | tr -d ' ')"
t_contains "the delegate classifies from the copy it renders" \
  "MenuLib.restKind(itm, row.subText)" "$ENTRY_SRC"
t_contains "and the panel from the projection it installed" \
  "const kind = MenuLib.restKind(it, f.sub)" "$MENU_SRC"

# ---------------------------------------------------------------------
t_section "and the per-string height machinery is gone"

REST_FN="$(awk '/^  function rowRestHeight\(itm\) \{/{f=1} f{print} f&&/^  \}$/{exit}' <<<"$MENU_SRC")"
t_not_empty "the estimate is still there to inspect" "$REST_FN"
t_not_contains "the model-side estimate reads no measured line box" \
  "implicitHeight" "$REST_FN"
t_not_contains "and asks no provider behind a binding" "Menu.subFor" "$REST_FN"

t_not_contains "no per-label height map survives" "_labelHCache" "$MENU_SRC"
t_not_contains "no per-sub height map survives" "_subHCache" "$MENU_SRC"
t_not_contains "no height warm pass survives" "cacheRowHeights" "$MENU_SRC"
t_not_contains "no binding-side cache fill survives" "_metricFillMissed" "$MENU_SRC"
t_not_contains "no warm stamp survives" "_warmedHeightsFor" "$MENU_SRC"
t_not_contains "and no copy of the row's sub vocabulary survives for heights" \
  "restSubText" "$MENU_SRC"

# The width pass shapes strings - a text's advance is its glyphs, per family -
# but its provider answers arrive with the installed row set, not from inside a
# measurement, and its cache is one bounded map instead of three dictionaries
# that were dropped wholesale on overflow.
t_not_contains "no provider sub call survives in the width pass" \
  "Menu.subFor" "$PANEL_WIDTH_SRC"
t_not_contains "no provider display call survives in the width pass" \
  "Menu.widestDisplayFor" "$PANEL_WIDTH_SRC"
t_not_contains "and no copying state read survives either" \
  "Menu.stateOf" "$PANEL_WIDTH_SRC"
t_contains "the width cache is one map" "property var _shapes: new Map()" "$PANEL_WIDTH_SRC"
t_contains "evicted one entry at a time" "root._shapes.delete(oldest.value)" "$PANEL_WIDTH_SRC"

t_note "the width pass still shapes strings and is bounded by _metricCap; no height reads it, and the panel's estimate is RowRule arithmetic on the row's kind"

t_summary

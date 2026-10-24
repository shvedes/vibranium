#!/bin/bash
# Suite: row-metrics - "how tall is this list" is answered once.
#
# Two cards asked the same question and each wrote the loop itself:
# PanelCard (features/clipboard, launcher, pass, powerMenu, wallpaperPicker)
# and MenuPanel (features/menu), which deliberately stays a plain Rectangle
# because of its grid mode, its ten-row resting cap and its per-row fonts.
# The delta is real and stays local. The ARITHMETIC was not different: the
# same walk, the same inter-row gap, the same stop at the row boundary.
#
# Three properties make this worth pinning rather than leaving to review.
#
# 1. A rule answered twice is a rule that drifts, and the drift is invisible
#    until a list renders with its last row cut through the middle. The
#    whole point of the stop-at-the-boundary is that a region's bottom edge
#    is the bottom edge of a ROW; a region built from a different sum lands
#    mid-row and the row renders cut.
#
# 2. The arithmetic is shared, the row VOCABULARY is not. A helper that
#    hardcodes one spelling of a row's title line answers a different
#    question for every other consumer: the clipboard's rows carry `title`
#    and `subLeft`, not `label`/`sub`, and the shared estimator read them as
#    an EMPTY row - Ui.rowMinH, 34px, against a real 47. A plausible wrong
#    number, in a shared helper, with nothing in the log, is the expensive
#    shape of this bug and not the duplicated loop. So the primitive takes
#    the caller's height function and never learns what a row looks like.
#
# 3. The probe must be able to say "I could not measure that". It used to
#    answer the row floor instead, which is a real row height and therefore
#    indistinguishable from a measurement - that is what let the empty-row
#    answer travel. A negative answer is the only honest one, and the
#    consumers that measure a CONSTANT string floor it themselves, knowing
#    they are flooring a not-yet-laid-out probe and not an unmeasurable row.
#
# This is a SOURCE suite because no feature panel can be constructed
# headlessly (no PanelWindow backend under QT_QPA_PLATFORM=offscreen, so all
# of them are classified needs-environment) and every number here only
# misbehaves across a font change or a row-shape change, neither of which a
# construction probe can reach.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "row-metrics" "how tall is this list is one rule, and a row the vocabulary cannot read is not measured as empty"

ROOT="$SHELL_DIR/common/ui"
METRICS="$ROOT/RowMetrics.js"
PANELCARD="$ROOT/PanelCard.qml"
PROBE="$ROOT/RowHeightProbe.qml"
# t_contains takes a haystack STRING, so every assertion below is handed
# file contents rather than a path. $(<f) is the project's own idiom.
METRICS_SRC="$(<"$METRICS")"
PANELCARD_SRC="$(<"$PANELCARD")"
PROBE_SRC="$(<"$PROBE")"

t_section "the shared primitive exists and owns the arithmetic"

t_file "the row-metrics library is in common/ui" "$METRICS"
t_contains "it is a pure QML library" ".pragma library" "$METRICS_SRC"
t_contains "it sums a whole row set" "function contentH" "$METRICS_SRC"
t_contains "it stops at the row boundary" "function snappedH" "$METRICS_SRC"
# The reason the gap is a parameter and not a literal. Two callers summing
# the same gap from two literals is how one of them stops being the list's
# gap without anything saying so.
t_contains "the inter-row gap is the caller's" "rowH, spacing" "$METRICS_SRC"
t_contains "and the ceiling is the caller's screen limit" "ceiling" "$METRICS_SRC"
# The knowledge that must not be stranded: why a boundary and not the space.
t_contains "and it says why a boundary and not a clamp" "cut" "$METRICS_SRC"

t_section "both callers route through it, and neither keeps a copy of the loop"

# The PanelCard side.
t_contains "PanelCard imports the shared arithmetic" "RowMetrics.js\" as RowMetrics" "$PANELCARD_SRC"
t_contains "PanelCard snaps through it" "RowMetrics.snappedH(root.rows" "$PANELCARD_SRC"
t_contains "PanelCard sums through it" "RowMetrics.contentH(root.rows" "$PANELCARD_SRC"
# A surviving hand-written sum would make the extraction a copy rather than
# a move, and the two copies would drift exactly as before.
t_not_contains "PanelCard keeps no hand-written row sum" "total += rowRestHeight" "$PANELCARD_SRC"

# The MenuPanel side. Pinned by name so the menu cannot quietly drop back to
# its own copy without this going red.
MENU="$SHELL_DIR/features/menu/MenuPanel.qml"
MENU_SRC="$(<"$MENU")"
t_contains "MenuPanel imports the same arithmetic" "RowMetrics.js\" as RowMetrics" "$MENU_SRC"
# The row set is a PARAMETER here, not the literal `panel.rowsModel`. It was
# widened to that shape when the exit needed a region for rows that are not
# installed yet (MenuPanel._modelListHFor), which is the same extraction with
# one more caller rather than a second rule: the whole point of the module is
# that a question about "how tall is this row set" is asked once, and a caller
# holding two different row sets must not be holding two different sums either.
# The `rows` form is therefore the sharper pin - it fails on a caller that
# quietly went back to spelling the loop, which the literal form would too but
# would also fail on the widening this suite should not have to care about.
t_contains "MenuPanel snaps through it" "RowMetrics.snappedH(rows" "$MENU_SRC"
t_contains "MenuPanel sums through it" "RowMetrics.contentH(rows" "$MENU_SRC"
t_contains "and the installed-model caller still names the model" "RowMetrics.contentH(panel.rowsModel" "$MENU_SRC"
t_not_contains "MenuPanel keeps no hand-written row sum" "total += panel.rowRestHeight" "$MENU_SRC"
# The grid is the reason MenuPanel stays bespoke, so the local branch has to
# survive the extraction - an assertion that the delta is still local.
t_contains "and the grid branch stays its own" "panel.gridSide" "$MENU_SRC"
t_contains "which is why the menu is still not a PanelCard" "stays a plain Rectangle instead of PanelCard" "$MENU_SRC"

t_section "the inter-row gap is the list's, not a literal in either caller"

t_contains "PanelCard reads it rather than assuming it" "property real rowSpacing" "$PANELCARD_SRC"
# The literal is the whole defect: correct while every list spaces at 2,
# wrong the moment one does not, with nothing at the call site to say so.
t_not_contains "and PanelCard holds no spacing literal" "total += 2" "$PANELCARD_SRC"
t_not_contains "MenuPanel holds no spacing literal" "total += 2" "$MENU_SRC"

# Every surface that binds rows to a card also binds the gap, so the sum and
# the list cannot disagree. Pinned as a list so a new card cannot arrive
# without it.
CARDS=(
  "clipboard/ClipboardPanel"
  "launcher/LauncherPanel"
  "pass/PassPanel"
  "powerMenu/PowerMenuPanel"
  "wallpaperPicker/WallpaperPickerPanel"
)
BOUND=0
for c in "${CARDS[@]}"; do
  f="$SHELL_DIR/features/$c.qml"
  src="$(<"$f")"
  t_contains "$(basename "$c") reads the list's spacing" "rowSpacing: list.spacing" "$src"
  BOUND=$((BOUND + 1))
done
t_eq "and the scan cannot shrink: five cards are pinned" "5" "$BOUND"
t_contains "and the menu reads its own" "readonly property real rowSpacing: list.spacing" "$MENU_SRC"

t_section "a row the vocabulary cannot read is not measured as empty"

# The probe's only way of saying "no measurement" is a negative answer.
t_contains "the probe reports an unmeasurable row as negative" "return -1" "$PROBE_SRC"
# The three floors are what made the empty-row answer travel. If one comes
# back, the trap is back.
t_not_contains "and never answers a row floor instead" "return Ui.rowMinH" "$PROBE_SRC"

# The escape hatch, and the reason it is a function rather than a field on
# the row record: a field would have to be computed into the model, and a
# model carrying pixel heights is re-derived every time the fonts land.
t_contains "a card takes a consumer's own height function" "property var rowHeightFn" "$PANELCARD_SRC"
t_contains "and consults it before the vocabulary" "if (typeof root.rowHeightFn === \"function\") return root.rowHeightFn(itm)" "$PANELCARD_SRC"

# The consumer that made this necessary. Its rows carry `title`/`subLeft`,
# so the shared estimator read them as empty rows - and a static-size window
# is by design there, so nothing about the card's height was ever going to
# reveal it.
CLIP="$SHELL_DIR/features/clipboard/ClipboardPanel.qml"
CLIP_SRC="$(<"$CLIP")"
t_contains "the clipboard states its own row height" "rowHeightFn: (row) => panel.rowH" "$CLIP_SRC"

# A consumer that measures a CONSTANT string still has to floor the
# negative, and knowingly: that is a not-yet-laid-out probe, which heals,
# rather than a row nobody can measure, which does not.
t_contains "the two-pane metrics floors its own placeholder" "Math.max(Ui.rowMinH, rowProbe.measure" "$(<"$ROOT/TwoPaneMetrics.qml")"
# The clipboard may hold that floor itself or read it from the two-pane
# metrics. Its window box is sized by those metrics, and the row it declares
# through rowHeightFn is the same row shape that budget is built from, so a
# second probe of the same two strings was a second answer to a question the
# window was already answering - and two text-layout caches to keep in step.
# The contract is the floor, not the spelling: a clipboard that hands a
# negative probe answer onward, or measures without one, fails here.
t_eq "and the clipboard's row height is floored, by its own probe or the shared one" "1" \
  "$(grep -cE 'readonly property real rowH: (Math\.max\(Ui\.rowMinH, rowProbe\.measure|metrics\.rowH)' <<<"$CLIP_SRC")"

t_note "the arithmetic is shared and the row vocabulary is not: PanelCard's estimator reads label/sub, the clipboard's rows carry title/subLeft, and a shared helper that hardcodes one spelling measures the other as an empty row - 34px against a real 47, silently"
t_note "the inter-row gap is the LIST's spacing on every surface, so a region built from the sum still lands on a row boundary if a surface ever spaces its rows differently"
t_summary

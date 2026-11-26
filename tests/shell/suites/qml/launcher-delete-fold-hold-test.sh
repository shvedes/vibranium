#!/bin/bash
# Suite: launcher-delete-fold-hold - a confirm folds before its row is swapped.
#
# Clearing a launcher filter with the delete confirmation open replaces the
# one-row result set with the full app list. A ListView model swap rebuilds the
# delegate, so a slot still folding is born closed and disappears in one frame.
# LauncherPanel holds the outgoing rows for the slot's own fold duration and
# publishes the new set on the release edge.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "launcher-delete-fold-hold" "a confirmation folds before the row set swaps"

SHELL_DIR="${SHELL_DIR:-$VIBRANIUM_DIR/shell}"
PANEL_SRC="$SHELL_DIR/features/launcher/LauncherPanel.qml"

t_section "the panel holds the row set for the fold"

PANEL_SOURCE="$(<"$PANEL_SRC")"

t_contains "rows are held while a slot folds" \
  'rows: panel._foldHeldRows !== null ? panel._foldHeldRows : AppLauncher.results' "$PANEL_SOURCE"
t_contains "the close runs before the install is scheduled" \
  'const foldMs = panel.closeDelete() || panel._foldingSlotMs()' "$PANEL_SOURCE"
t_contains "the hold uses the slot's own duration" \
  'foldRowsTimer.interval = foldMs' "$PANEL_SOURCE"
t_contains "the release publishes the fresh rows" \
  'panel.syncRows()' "$PANEL_SOURCE"
t_contains "a folding slot is discovered on the live delegates" \
  '!(d instanceof LauncherEntry)' "$PANEL_SOURCE"
t_contains "closing a confirmation returns its fold duration" \
  'const foldMs = row ? row.slotMotionMs : 0' "$PANEL_SOURCE"

t_section "frame-level: the held fold survives the swap window"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/launcher-delete-fold-hold.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
qp_assert "an immediate swap loses the fold in one frame" swap.snapped true
qp_assert "the held slot folds through intermediate frames" hold.folded true
qp_assert "it never regrows after landing" hold.neverRegrew true
qp_assert "the new row is born with no slot" hold.newRowClosed true
t_note "immediate swap: $(qp_get trace.noHold)"
t_note "held fold: $(qp_get trace.held)"

t_summary

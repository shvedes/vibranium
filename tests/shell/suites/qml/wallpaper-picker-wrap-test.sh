#!/bin/bash
# Suite: wallpaper-picker-wrap - next/prev at the ends travel through the list.
#
# WAL-WRAP. A step off either end of the wallpaper deck must be a visible
# journey across the intervening entries, not a one-frame switch. The panel
# cannot be built headlessly (LayerSurface), so the QML probe checks the real
# source handed in through the environment and drives a turn-based model of the
# deck position, sampling consecutive turns across the wrap.
# The model's verdicts are derived from the source facts, so a source that
# drifts back to an integer selIndex jump turns the frame half red too.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "wallpaper-picker-wrap" "wrap is a journey, not a one-frame switch"

require_qs

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-wrap.XXXXXX")"
cleanup() {
  qp_teardown
  [[ -n ${WORK:-} && -d $WORK ]] && rm -rf "$WORK"
}
trap cleanup EXIT

PANEL_SRC="$(cat "$SHELL_DIR/features/wallpaperPicker/WallpaperPickerPanel.qml")"
export PANEL_SRC

# The probe reads WALLPAPER_PICKER_PANEL_SRC; keep one name for both sides.
export WALLPAPER_PICKER_PANEL_SRC="$PANEL_SRC"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/wallpaper-picker-wrap.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
else
  t_ok "the probe reached ##DONE##"
fi

t_section "source gate"

qp_assert "one real deckPos owns tile geometry" gate.deckPos true
qp_assert "no cell geometry clock chasing deckPos" gate.oneClock true
qp_assert "no per-frame model diff" gate.noPerFrameDiff true
qp_assert "wrap arms a length-derived journey" gate.wrapJourney true
qp_assert "the file-keyed window diff is intact" gate.fileKeyed true
qp_assert "the fade, size gate and leave latches are intact" gate.invariants true

t_section "wrap frames"

# The old integer jump is the control: it must look like a one-frame switch.
t_eq "the legacy model is a one-frame switch" "true" "$(qp_get frame.legacyOneFrame)"

if [[ $(qp_get frame.distinctCenters) -ge 8 ]]; then
  t_ok "the window passes through intermediate entries"
else
  t_no "the window passes through intermediate entries" \
    "only $(qp_get frame.distinctCenters) distinct window centres were sampled"
fi

if awk -v v="$(qp_get frame.maxRelStep)" 'BEGIN { exit !(v < 2.0) }'; then
  t_ok "no tile rel jumps a frame"
else
  t_no "no tile rel jumps a frame" "largest per-frame rel step was $(qp_get frame.maxRelStep)"
fi

t_eq "no frame switches last directly to first" "false" "$(qp_get frame.oneFrameSwitch)"
if [[ $(qp_get frame.backwardSteps) -ge 5 ]]; then
  t_ok "the deck travels through the list"
else
  t_no "the deck travels through the list" \
    "only $(qp_get frame.backwardSteps) backward steps were sampled"
fi
t_eq "the wrap lands on the committed first entry" "true" "$(qp_get frame.landsAtFirst)"
t_eq "no per-cell geometry Behaviours remain" "0" "$(qp_get frame.cellGeomBehaviours)"

t_summary

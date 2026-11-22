#!/bin/bash
# Suite: picker-sized-fade - no deck animation before the panel has a size,
# and one inherited fade for the whole theme picker overlay.
#
# WAL-1/WAL-2. The panel cannot be built under offscreen (its LayerSurface has
# no PanelWindow backend), so the QML probe checks the real source handed in
# through the environment and drives a turn-based model of the reveal gate.
# The model's verdicts are derived from the source facts, so a source that
# drifts back to an unconditional reveal timer turns the frame half red too.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "picker-sized-fade" "live size gate, one root fade"

require_qs

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vb-shell-picker-fade.XXXXXX")"
cleanup() {
  qp_teardown
  [[ -n ${WORK:-} && -d $WORK ]] && rm -rf "$WORK"
}
trap cleanup EXIT

THEME_PANEL_SRC="$(cat "$SHELL_DIR/features/pickers/theme/ThemePickerPanel.qml")"
export THEME_PANEL_SRC

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/picker-sized-fade.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
else
  t_ok "the probe reached ##DONE##"
fi

t_section "source gate"

t_eq "the live size gate is present and the timer is gone" "true" "$(qp_get gate.live)"
t_eq "one root opacity with one Glide, no per-child fade" "true" "$(qp_get gate.oneRootFade)"
t_eq "geometry Behaviours stay gated on _settled" "true" "$(qp_get gate.geometryGateKept)"
t_eq "the contentBottom geometry chain is unchanged" "true" "$(qp_get gate.contentChainKept)"

t_section "entrance frames"

t_eq "_settled never leads an unsized panel" "false" "$(qp_get frame.settledWhileUnsized)"
t_eq "no card Behaviour runs before the panel is sized" "0" "$(qp_get frame.animBeforeSized)"
t_eq "the fade never starts before the size edge" "false" "$(qp_get frame.fadeBeforeSized)"
t_eq "every child inherits the one root opacity" "true" "$(qp_get frame.childrenInherit)"

t_summary

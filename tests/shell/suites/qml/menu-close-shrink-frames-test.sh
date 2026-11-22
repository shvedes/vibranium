#!/bin/bash
# Suite: menu-close-shrink-frames - a dropdown close glides, not snaps.
#
# Closing a dropdown releases its growth claim in the turn the fold starts,
# while the row is still tall. The card and the viewport read one height, so
# that height must be carried from the grown region down to rest over the
# release animation. Sampling the end state cannot see a one-frame drop: the
# probe evaluates MenuPanel's real _followSlotRow and samples the card height
# on consecutive turns.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "menu-close-shrink-frames" "a dropdown close carries the shrink in frames"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/menu-close-shrink-frames.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
t_eq "the real release branch was extracted" "true" "$(qp_get source.followFound)"

t_section "the close carries the shrink over intermediate frames"

qp_assert "the card shrank in more than one frame" frame.intermediate true
qp_assert "the card still landed at the resting height" frame.landed true
t_note "close height trace: $(qp_get trace.h)"

t_summary

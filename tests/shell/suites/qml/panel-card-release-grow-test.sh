#!/bin/bash
# Suite: panel-card-release-grow - a slot release with a moving base glides.
#
# Clearing a launcher filter with the delete confirmation open releases the
# slot claim in the same turn the row set changes. The resting region the slot
# releases into is then larger than the one it grew against, so the release
# latch must carry the height the card is showing UP to the new base instead
# of letting the height write land in one frame.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "panel-card-release-grow" "a slot release into a larger row set glides"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/panel-card-release-grow.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
t_eq "the card started at the one-row fit" "true" "$(qp_get source.grounded)"
t_eq "the delete claim grew the region" "true" "$(qp_get source.grew)"
t_eq "the clear moved the resting base up" "true" "$(qp_get source.newResting)"
t_eq "and the card has a taller destination" "true" "$(qp_get source.targetAboveStart)"

t_section "the release carries the growth over intermediate frames"

qp_assert "the first frame is already in flight" frame.firstMoved true
qp_assert "the card glided through intermediate heights" frame.intermediate true
qp_assert "it never passed the target" frame.neverOvershot true
qp_assert "and it landed on the card height" frame.landed true
t_note "release height trace: $(qp_get trace.h)"

t_summary

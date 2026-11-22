#!/bin/bash
# Suite: gridlist-seat - the single seat funnel and the wrap sweep's edge
# release in common/ui/GridList.qml, sampled over consecutive event-loop turns.
#
# GridList is the grid twin of List: it seats cells with positionViewAtIndex
# and runs one wrap sweep. A wrap used to arm a deferred Idle.run rewind that
# wrote the captured sweepY0 back two turns later. A page step that landed
# between the gesture and that rewind was undone one frame after it landed -
# a wrong frame followed by a glide from a stale origin. The fix routes every
# seat through one funnel and releases the sweep on the seat's contentY edge,
# starting from the view's live offset instead of a captured one.
#
# End-state assertions cannot see that: the step survives either way. The
# probe samples every contentY frame after the step and asserts no frame falls
# back to the stale origin, and that each programmatic verb takes exactly one
# seat - the same funnel a keyboard step takes.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "gridlist-seat" "common/ui/GridList.qml: one seat funnel, no stale rewind"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/gridlist-seat.qml" 25; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing during construction" "none" "$(qp_get probe.error)"
t_eq "no observation in the whole run threw" "0" "$(qp_get probe.threw)"
t_eq "the probe completed every phase" "true" "$(qp_get probe.completed)"

t_section "every seat goes through one funnel, like a keyboard step"

# The funnel is the change: it is absent on the unfixed tree.
qp_assert "GridList owns a seatTo funnel" g.hasSeatTo true
qp_assert "its write counter starts at zero" g.writesStart 0

# A keyboard step is the reference path; every verb must take the same one.
for pair in "key:keyboard" "page:pageBy" "settle:settle" "reveal:reveal" "jump:jumpEnd"; do
  name="${pair%%:*}"
  label="${pair##*:}"
  qp_assert "a $label step takes exactly one seat, like every other" "path.$name" 1
done

t_section "no frame undoes a page step taken after a wrap gesture"

qp_assert "the wrap armed its sweep" wrap.sweeping true
t_note "The sweep's target and the step land on the same value, so once the sweep starts from the live offset the view has nowhere to travel; on the old tree the deferred rewind still pulls it back to the captured origin."
qp_assert "the armed target is the scroll bound" wrap.to "$(qp_get g.maxY)"
qp_assert "the step landed on the target" wrap.afterStep "$(qp_get wrap.to)"

qp_assert "the wrap release took the same funnel" wrap.releaseSeat 1
qp_assert "no sampled frame falls back to the stale origin" wrap.backwards 0
qp_assert "the sweep released its armed state" wrap.sweepingAfter false
t_ne "at least one frame was sampled after the step" "" "$(qp_get wrap.trace)"

t_section "a plain wrap still glides end to end"

qp_assert "the plain wrap armed its sweep" plain.sweeping true
qp_assert "its target is the scroll bound" plain.to "$(qp_get g.maxY)"
t_note "On the fixed tree the sweep starts from the live contentY on the seat's edge and eases toward the target over consecutive frames. It is not removed."
qp_assert "the sweep released after the plain wrap" plain.sweepingAfter false

t_summary

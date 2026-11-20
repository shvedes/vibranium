#!/bin/bash
# Suite: dropdown-land - a landed DropdownSlot keeps following its content.
#
# land() snaps the slot to its destination with the Behavior disabled, which
# is how a region-growing reveal avoids animating the same height twice. The
# landing goes through Binding objects so the declarative height and opacity
# stay live: content that collapses later must shrink the slot with it, with
# no empty plate left under the shorter view.
#
# The landing credential is an epoch: a land() deferred through callLater may
# only write its hold if that epoch is still current and the hold still live.
# A land() followed by a release() before the deferred turn must leave the
# released slot unheld, so it cannot be frozen on a stale target.
#
# The probe also closes a separate, never-landed slot. Its deferred body must
# stay alive through the fold and be gone on closeFinished. The slot keeps a
# short grace timer for that edge: the release has to land after the list's
# height-zero reconcile, which is not observable here as a live value.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "dropdown-land" "a landed slot still tracks its content height"

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/dropdown-land.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
else
  t_ok "the probe reached ##DONE##"
fi

t_eq "the probe ran without throwing" "none" "$(qp_get probe.error)"
t_eq "the probe completed every phase" "true" "$(qp_get slot.completed)"

t_section "the landing snaps and keeps its binding"

before="$(qp_get slot.before)"
after="$(qp_get slot.after)"
shrunk="$(qp_get slot.shrunk)"

t_eq "landing snaps to the destination" "$before" "$after"
t_eq "the slot reports itself held" "true" "$(qp_get slot.held)"
t_ne "shrinking the body shrinks the slot" "$after" "$shrunk"

t_section "a stale land cannot freeze a released slot"

qp_assert "a stale deferred write leaves no landed hold" \
  "slot.staleLandedHold" "false"
qp_assert "a stale deferred write leaves the slot unheld" \
  "slot.staleHeld" "false"
qp_assert "a fresh land after release still applies" \
  "slot.relandHold" "true"
qp_assert "a fresh land re-arms the hold" \
  "slot.relandHeld" "true"

t_section "no deferred content outlives the fold"

qp_assert "the close reached its terminal edge" \
  "slot.foldCloseFired" "true"
qp_assert "the body lived through the fold" \
  "slot.bodyDuringFold" "true"
qp_assert "the body was released at the terminal edge" \
  "slot.noBodyAtFinish" "true"
qp_assert "no body remains after the fold" \
  "slot.bodyAfterFold" "false"
qp_assert "closing is clear after the fold" \
  "slot.closingAfterFold" "false"

t_summary

#!/bin/bash
# Suite: dropdown-land - a landed DropdownSlot keeps following its content.
#
# land() snaps the slot to its destination with the Behaviour disabled, which
# is how a region-growing reveal avoids animating the same height twice. The
# landing goes through Binding objects so the declarative height and opacity
# stay live: content that collapses later must shrink the slot with it, with
# no empty plate left under the shorter view.
#
# The probe lands a real slot, shrinks its body and reads the height back. A
# frozen height would keep the tall value and fail the shrink assertion.

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

t_summary

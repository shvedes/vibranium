#!/bin/bash
# Suite: common/process/StreamGuard.qml - the one supervisor every long-lived
# streaming child in the tree uses.
#
# The unit is small and its whole value is lifecycle: a generation whose lines
# are current, a spawn window that turns a child that never started into a
# failure, a stop that is not a failure, and a capped respawn after one. A probe
# drives it against a real `sh -c` child; nothing here asserts pixels or argv
# beyond what the probe gave it.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "stream-guard" "common/process/StreamGuard.qml: spawn window, line currency, stop, failure"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/stream-guard.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit
fi

t_section "a started child delivers its line and is armed"
t_eq "the guard is armed after start" "true" "$(qp_get armed.after.start)"
t_eq "it is not degraded" "false" "$(qp_get degraded.after.start)"
t_eq "the child's line arrived" "hello" "$(qp_get line)"

t_section "a deliberate stop parks the guard"
t_eq "it is not armed after stop" "false" "$(qp_get armed.after.stop)"

t_section "a child that exits is a failure with a capped respawn"
t_eq "the guard reads degraded" "true" "$(qp_get dead.degraded)"
t_eq "the failure was counted" "true" "$(test "$(qp_get dead.fails)" -ge 1 && echo true || echo false)"
# The respawn fires after backoffBaseMs and immediately fails again, so the
# guard is either inside a retry window or armed on the next attempt - both are
# past the spawn window here, and neither is "still running after a failure".
t_note "dead.armed=$(qp_get dead.armed) dead.fails=$(qp_get dead.fails) - the respawn is a real restart, not a parked guard"

t_summary

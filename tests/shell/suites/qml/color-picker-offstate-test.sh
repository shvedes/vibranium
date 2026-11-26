#!/bin/bash
# Suite: colorPicker IPC and its one active seat live outside the bar runtime.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "color-picker-offstate" "Standalone picker gateway works with no bar runtime"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/color-picker-offstate.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_eq "the controller exists" "object" "$(qp_get controller.exists)"
t_eq "no active seat" "true" "$(qp_get seat.empty)"
t_eq "no module owner" "true" "$(qp_get owner.none)"
t_eq "no bar fallback" "true" "$(qp_get fallback.none)"
t_eq "pick starts a standalone session" "ok" "$(qp_get pick.accepted)"
t_eq "close is idempotent" "ok" "$(qp_get close.ok)"
t_eq "status works" "ok" "$(qp_get status.code)"
t_eq "status reports idle" "true" "$(qp_get status.picking)"
t_eq "ping works" "pong" "$(qp_get ping)"

t_summary

#!/bin/bash
# Suite: common/BootGate - the shared boot-milestone gate. Built before a
# milestone it fires once on the transition; built after it, once on the next
# turn. `ready` follows only the named milestone so an early demand can park.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-gate" "BootGate: one fire per path, and a single-milestone ready flag"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-gate.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get gate.error)"
t_eq "a gate built early is not ready" "false" "$(qp_get gate.earlyBefore)"
t_eq "the transition fires the early gate once" "1" "$(qp_get gate.earlyFires)"
t_eq "another milestone's gate is not ready early" "false" "$(qp_get gate.settledBefore)"
t_eq "that gate turns ready on its own milestone" "true" "$(qp_get gate.settledAfter)"
t_eq "a late gate is ready on construction" "true" "$(qp_get gate.lateReadyOnCreate)"
t_eq "the already-passed path fires the late gate once" "1" "$(qp_get gate.lateFires)"

t_summary

#!/bin/bash
# Suite: the top-level colorPicker alias reaches the same owner closures as
# `bar colorPicker`, and is discoverable without duplicating the deep rows.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "ipc-color-alias" "one picker seat, two spellings, no index duplication"
require_qs
require_tools grep

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/ipc-color-alias.qml" 30; then
  t_no "the probe reached ##DONE##" "probe did not finish. $(qp_out)"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
  t_summary
  exit $?
fi
t_ok "the probe ran without throwing"

t_section "both targets registered"
t_eq "the alias target registered" "true" "$(qp_get register.alias)"

t_section "one closure behind both spellings"
t_eq "alias pick is silent" 'null' "$(qp_get alias.pick)"
t_eq "alias close is silent" 'null' "$(qp_get alias.close)"
t_eq "alias status is the owner projection" '{"available":true,"picking":false,"screen":"HDMI-A-1"}' \
  "$(qp_get alias.status)"
t_eq "pick was called once" "1" "$(qp_get calls.pick)"
t_eq "close was called once" "1" "$(qp_get calls.close)"
t_eq "status is only on the alias" "1" "$(qp_get calls.status)"

t_section "discovery stays flat"
t_eq "help shows pick and close" '["pick","close"]' "$(qp_get help.commands)"
t_eq "the target root prints no examples" "0" "$(qp_get help.examples)"
t_eq "the alias is in the index" "true" "$(qp_get index.target)"
t_eq "the index shows only the two verbs" '["pick","close"]' "$(qp_get index.literals)"
t_eq "the bar deep rows are gone" "true" "$(qp_get bar.deepGone)"
t_eq "the bar keeps no picker branch" "true" "$(qp_get bar.branchGone)"
t_eq "the result row is gone" "true" "$(qp_get result.gone)"

t_eq "the alias target unregisters" "true" "$(qp_get unregister.alias)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

t_summary

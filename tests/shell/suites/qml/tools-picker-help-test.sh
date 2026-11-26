#!/bin/bash
# Suite: the standalone picker's leaf page documents its options without notes.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "tools-picker-help" "the pick leaf documents its options without notes"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/tools-picker-help.qml" 30; then
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

t_eq "the help page is a success" "true" "$(qp_get help.ok)"
t_eq "the pick leaf has no notes" "[]" "$(qp_get help.notes)"
t_eq "the usage keeps the literal option" \
  "vb-shell tools picker pick [silent] [logical]" "$(qp_get help.usage)"
t_eq "silent and logical are documented" \
  '[{"name":"silent","summary":"Hide the live dimensions beside the cursor"},{"name":"logical","summary":"Return desktop coordinates in logical pixels"}]' \
  "$(qp_get help.options)"

t_summary

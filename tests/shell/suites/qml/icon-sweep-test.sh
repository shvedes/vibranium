#!/bin/bash
# Suite: Downloader/IconSweep - the bar icon's accent wave and parked idle
# state. The wave is forced regardless of the global motion setting, because
# it is the bar's only busy indicator.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "icon-sweep" "IconSweep: forced downward phase travel and idle parking"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/icon-sweep.qml" 40; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_eq "the canvas is the bar glyph canvas" "16" "$(qp_get sweep.canvas)"
t_eq "the band is a fraction of the canvas" "4.8" "$(qp_get sweep.band)"
t_true "the cadence is two to three frames per second" awk \
  -v ms="$(qp_get sweep.frameMs)" 'BEGIN { exit !(ms >= 300 && ms <= 400) }'
t_eq "the inactive sweep hides itself" "false" "$(qp_get sweep.visibleInactive)"
t_eq "the stopped phase parks at the top" "0" "$(qp_get sweep.parkedDelta)"

t_eq "the sweep ignores the global motion switch" "true" "$(qp_get sweep.motion)"
t_true "the phase travels downward while active" awk \
  -v a="$(qp_get sweep.first)" -v b="$(qp_get sweep.second)" \
  'BEGIN { exit !(b > a) }'

t_summary

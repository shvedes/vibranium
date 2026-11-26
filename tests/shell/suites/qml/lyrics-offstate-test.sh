#!/bin/bash
# Suite: the lyrics target is owned by a resident feature, not the bar runtime.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "lyrics-offstate" "Lyrics owner exists with no bar runtime attached"

require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/lyrics-offstate.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_eq "the probe ran without throwing" "" "$(qp_get probe.error)"
t_eq "the lyrics feature exists" "object" "$(qp_get lyrics.exists)"
t_eq "the control exposes showLyrics" "function" "$(qp_get control.hasShowLyrics)"
t_eq "no overlay is constructed while idle" "true" "$(qp_get lyrics.noOverlay)"
t_eq "close is idempotent while idle" "true" "$(qp_get lyrics.closeIdempotent)"
t_eq "no runtime is attached" "true" "$(qp_get control.noRuntime)"

t_summary

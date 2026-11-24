#!/bin/bash
# Suite: launcher-dot-phase - one clock, one derived dot stage, frame samples.
#
# LauncherEntry cannot be constructed offscreen (the menu import reaches a
# PanelWindow), so the QML probe reads the real file and evaluates its own dot
# bindings and timer in a headless slice. The frame sequence is read from the
# tick change, not from an end-state snapshot: a copied stage or a second
# writer would drift and fail here.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "launcher-dot-phase" "derived loading dots in LauncherEntry"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/launcher-dot-phase.qml" 20; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the QML source was read" "source.read" "true"
qp_assert "the dot bindings and timer were found" "source.bindingsFound" "true"

t_section "one clock, one writer, derived presentation"
qp_assert "only the timer writes the tick" "source.oneWriter" "true"
qp_assert "no stop-time reset writer" "source.noStopReset" "true"
qp_assert "the stage derives from the tick" "source.derived" "true"
qp_assert "subText holds no copied dot literal" "source.noCopiedStage" "true"
qp_assert "the cadence is 250ms" "source.interval250" "true"
qp_assert "the clock runs off the loading edge" "source.runningEdge" "true"

t_section "consecutive frames"
qp_assert "the first paint shows one dot" "runtime.initial" "Fetching inflation data."
qp_assert "the first tick shows two" "runtime.tick1" "Fetching inflation data.."
qp_assert "the second tick shows three" "runtime.tick2" "Fetching inflation data..."
qp_assert "the cycle returns to one" "runtime.tick3" "Fetching inflation data."
qp_assert "all four tick stages arrive in order" "runtime.samples" \
  "Fetching inflation data..|Fetching inflation data...|Fetching inflation data.|Fetching inflation data.."
qp_assert "a settled row carries no dots" "runtime.offline" "Fetching inflation data"

t_summary

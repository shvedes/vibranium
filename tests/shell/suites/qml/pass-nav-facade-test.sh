#!/bin/bash
# Suite: pass-nav-facade - LNC-7 single navigation writer (single-writer + equivalence).
#
# PassPanel cannot be constructed offscreen, so the probe reads the real Pass
# and PassPanel sources and evaluates the facade verbs it extracts from them
# with stubbed cross-component names. It asserts that mode, currentDir and
# selectedPath are written only in navigate(), that the panel never writes them
# directly, and that a panel gesture cleanup and the equivalent Esc verb publish
# one identical state trace.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "pass-nav-facade" "single navigation writer and gesture/verb equivalence"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/pass-nav-facade.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "both sources were read" "slice.sourcesRead" "true"
qp_assert "the facade functions were found" "slice.facadeFnsFound" "true"

t_section "LNC-7: one writer, no panel writes"
qp_assert "only navigate writes the navigation fields" "facade.singleWriter" "true"
qp_assert "every facade verb funnels through navigate" "facade.verbsFunnel" "true"
qp_assert "the panel never assigns mode/currentDir/selectedPath" "facade.noPanelWrites" "true"
qp_assert "the panel reaches the facade for its transitions" "facade.panelUsesNavigate" "true"

t_section "existing verbs keep their state effects"
qp_assert "browseTo sets dir and mode only" "verb.browseState" "browse|mail/gmail|"
qp_assert "select sets path and mode only" "verb.selectState" "action|mail/gmail|mail/gmail/acc"

t_section "gesture and verb publish the same navigation frames"
qp_assert "back ends in browse from action" "equivalence.verbEnd" "browse|mail/gmail|mail/gmail/acc"
qp_assert "panel cleanup ends in browse from action" "equivalence.gestureEnd" "browse|mail/gmail|mail/gmail/acc"
qp_assert "the verb trace is the single mode write" "equivalence.verbTrace" '["browse|mail/gmail|mail/gmail/acc"]'
qp_assert "the gesture trace equals the verb trace" "equivalence.gestureTrace" '["browse|mail/gmail|mail/gmail/acc"]'
qp_assert "both paths are frame-for-frame equal" "equivalence.traceEqual" "true"

t_summary

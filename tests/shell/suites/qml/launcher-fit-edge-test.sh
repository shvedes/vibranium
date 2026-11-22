#!/bin/bash
# Suite: launcher-fit-edge - LNC-1 fit measurement rides real settled edges.
#
# LauncherPanel cannot be constructed offscreen (PanelCard needs a LayerSurface
# and a screen), so the QML probe reads the real file and evaluates its own fit
# functions with stubbed list / panel / fallback. The four wait conditions are
# driven frame by frame: a settle wait must not exhaust a fit retry's budget,
# and every wait is released by the named live edge, not by a 16 ms poll.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "launcher-fit-edge" "fit measurement on settled edges, not a poll"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/launcher-fit-edge.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the QML source was read" "source.read" "true"
qp_assert "every fit function was found" "source.allFound" "true"

t_section "LNC-1: structure - one waiter, one derivation, one fallback"
qp_assert "no 16 ms fit poll timer" "source.noRetryTimer" "true"
qp_assert "no shared attempt counter" "source.noSharedCounter" "true"
qp_assert "no two retry ladders" "source.noRetryLadder" "true"
qp_assert "waiter list and whenFit shape" "source.waitersShape" "true"
qp_assert "single derivation drained on its change" "source.derivation" "true"
qp_assert "derivation covers swap, count, polish and slot motion" "source.fourEdges" "true"
qp_assert "one install-and-polish callLater" "source.oneCallLater" "true"
qp_assert "one labelled bounded fallback" "source.oneFallback" "true"
qp_assert "fallback names its missing edge" "source.fallbackLabelled" "true"

t_section "preserved contracts"
qp_assert "slotRegionH / slotOpen L3 geometry unchanged" "source.geometryPreserved" "true"
qp_assert "rowsPending and identity epochs unchanged" "source.epochsPreserved" "true"
qp_assert "settled resting-buffer relatch kept" "source.restBufferKept" "true"

t_section "arm and swap-close edge"
qp_assert "one waiter armed" "arm.waiters" "1"
qp_assert "fit pending" "arm.pending" "true"
qp_assert "model height latched in the same turn" "arm.modelNow" "110"
qp_assert "exactly one deferred drain" "arm.oneCallLater" "1"
qp_assert "fallback armed once" "arm.fallbackArmed" "1"
qp_assert "swap wait keeps the waiter" "swap.waited" "1"
qp_assert "swap wait does not latch a fit" "swap.notLatched" "110"
qp_assert "swap close makes the derivation live" "swap.readyLive" "true"
qp_assert "swap close latches the measured fit" "swap.latched" "120"
qp_assert "fit clears pending" "swap.pendingCleared" "false"
qp_assert "fit drains the waiter" "swap.waitersDrained" "0"
qp_assert "settled resting-buffer relatch ran once" "swap.restRelatch" "1"

t_section "the two budgets can no longer share a counter"
qp_assert "long settle + fit wait keeps model height" "budget.stillModelHeight" "110"
qp_assert "content-polish edge latches fit, not -1" "budget.fitAfterPolish" "120"

t_section "slot motion-finished edge"
qp_assert "moving slot waits" "slot.waitWhileMoving" "110"
qp_assert "motion-finished edge latches fit" "slot.fitAfterMotion" "120"

t_section "resting slot and count edge"
qp_assert "resting open slot gives up" "resting.gaveUp" "-1"
qp_assert "give-up clears pending" "resting.pendingCleared" "false"
qp_assert "count mismatch waits" "count.waited" "110"
qp_assert "count edge latches fit" "count.latched" "120"

t_summary

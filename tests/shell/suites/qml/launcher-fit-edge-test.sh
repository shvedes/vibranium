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

t_section "LNC-4: one labelled, generation-guarded snap writer"
qp_assert "snap functions found in source" "snap.source.found" "true"
qp_assert "sizeSnap has one writer" "snap.source.singleWriter" "true"
qp_assert "writer checks the arm generation" "snap.source.guarded" "true"
qp_assert "fade path never writes sizeSnap" "snap.source.fadeNeverWrites" "true"
qp_assert "close arms with a fresh generation" "snap.source.closeArms" "true"
qp_assert "gate releases on the armed generation" "snap.source.gateReleases" "true"
qp_assert "visible input releases on the armed generation" "snap.source.inputReleases" "true"

t_section "LNC-4: close -> hidden sync -> reopen first sizing snaps"
qp_assert "first open has no snap" "snap.afterFirstOpen" "false"
qp_assert "gate release keeps snap off" "snap.afterGate" "false"
qp_assert "typing glides" "snap.afterTyping" "false"
qp_assert "close arms the snap" "snap.closeArmed" "true"
qp_assert "close labels the arm" "snap.closeReason" "close-arm"
qp_assert "hidden query keeps the arm" "snap.hiddenInputKeepsArm" "true"
qp_assert "hidden sync ran the fade path" "snap.fadeCallsWhileHidden" "1"
qp_assert "hidden sync does not disarm" "snap.survivesHiddenSync" "true"
qp_assert "arm label survives hidden sync" "snap.reasonSurvives" "close-arm"
qp_assert "stale-generation release is ignored" "snap.staleReleaseIgnored" "true"
qp_assert "first sizing after reopen snaps" "snap.beforeReopenGate" "true"
qp_assert "reopen gate releases the snap" "snap.afterReopenGate" "false"
qp_assert "release labels the reason" "snap.releaseReason" "shown"

t_section "LNC-5: open seat retires the deferred sync"
qp_assert "generation is bumped in syncRowsNow" "swap.source.genInSyncNow" "true"
qp_assert "deferred sync captures and checks its generation" "swap.source.capturedGen" "true"
qp_assert "deferred install was pending" "swap.pendingArmed" "true"
qp_assert "open seat bumped the generation" "swap.genBumped" "true"
qp_assert "open seat installed once" "swap.installsAfterSeat" "1"
qp_assert "stale deferred install retired" "swap.staleRetired" "true"

t_section "LNC-11: cursor decisions read the live model"
qp_assert "cursor readers were found in source" "cursor.source.found" "true"
qp_assert "currentRecord derives from the live model" "cursor.source.live" "true"
qp_assert "no cursor reader indexes panel.rows" "cursor.source.noProducer" "true"
qp_assert "first-normal and selectable read the live view" "cursor.source.seatLive" "true"
qp_assert "the seat index is taken after installRows" "cursor.source.seatAfterInstall" "true"
qp_assert "first normal names the live set" "cursor.first" "1"
qp_assert "selectable walks the live set" "cursor.selectable" "false,true"
qp_assert "current row names the live record" "cursor.record" "app:live"
qp_assert "delete key reads the live record" "cursor.deleteLive" "true"
qp_assert "info names the live record" "cursor.info" "1"
qp_assert "activation names the live record" "cursor.activated" "app:live"

t_summary

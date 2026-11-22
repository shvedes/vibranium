#!/bin/bash
# Suite: launcher-reactive-guards - LNC-6/8/9/10 teardown and demand tokens.
#
# AppLauncher and its controller cannot be constructed offscreen, so the QML
# probe reads both real files and evaluates their functions in headless slices.
# The scan slice drives an overlapping rescan frame by frame: old dirs must not
# ride a late exit into the registry. The prewarm slice drives a refused demand
# past its retry cap. The replay slice checks that an open-on-reload re-takes
# the claim, and the guard slice checks that a deferred callback cannot touch
# a torn-down controller.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "launcher-reactive-guards" "generation, cap, claim and teardown guards"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/launcher-reactive-guards.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the probe ran the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "both QML sources were read" "source.read" "true"
qp_assert "every function and handler was found" "source.allFound" "true"

t_section "LNC-6: plugin discovery generation and cleared collectors"
qp_assert "scanSeq is declared and captured at demand" "scan.source.seq" "true"
qp_assert "dirs are cleared when a scan starts" "scan.source.clearAtStart" "true"
qp_assert "a stale exit is checked against the seq" "scan.source.staleExit" "true"
qp_assert "a stale exit requeues a fresh scan" "scan.source.requeued" "true"
qp_assert "one scan registers its own dirs" "scan.single.registered" "a,b"
qp_assert "one scan clears its collector" "scan.single.cleared" "true"
qp_assert "an overlapping rescan publishes only fresh dirs" "scan.overlap.registered" "c"
qp_assert "no registration carries the superseded dirs" "scan.overlap.log" "c"
qp_assert "the stale exit did not register" "scan.overlap.calls" "1"

t_section "LNC-8: edge-driven prewarm and one capped retry"
qp_assert "retry count has an explicit cap" "prewarm.source.capped" "true"
qp_assert "boot gate does not arm the retry timer" "prewarm.source.noGateTimer" "true"
qp_assert "success stops the retry timer" "prewarm.source.stopOnSuccess" "true"
qp_assert "the boot edge cancels the retry" "prewarm.source.edgeCancels" "true"
qp_assert "a short gate marks the prewarm pending" "prewarm.gate.pending" "true"
qp_assert "a short gate does not start a timer" "prewarm.gate.starts" "0"
qp_assert "a refusal arms one retry" "prewarm.refuse.starts" "1"
qp_assert "the retry is counted" "prewarm.refuse.count" "1"
qp_assert "a second refusal does not extend the budget" "prewarm.capped.starts" "1"
qp_assert "a later success prewarms" "prewarm.success.prewarmed" "true"
qp_assert "success stops the timer" "prewarm.success.stops" "true"

t_section "LNC-9: reload replay re-takes the surface claim"
qp_assert "replay clears visible before open" "replay.source.forcesFalse" "true"
qp_assert "replay runs under the _replaying flag" "replay.source.underFlag" "true"
qp_assert "the visible guard is preserved" "replay.source.guardKept" "true"
qp_assert "open saw a hidden panel" "replay.visibleAtOpen" "false"
qp_assert "replay called open through to the claim" "replay.claimCalls" "1"
qp_assert "the claim token is non-null after replay" "replay.tokenNonnull" "true"

t_section "LNC-10: deferred callbacks carry an alive guard"
qp_assert "one life holder exists" "later.source.holder" "true"
qp_assert "teardown flips the guard" "later.source.flip" "true"
qp_assert "the wrapper checks the captured guard" "later.source.wrapper" "true"
qp_assert "no raw auto-select deferral remains" "later.source.noRawAuto" "true"
qp_assert "no raw try-exec deferral remains" "later.source.noRawTryExec" "true"
qp_assert "a callback after teardown is a no-op" "later.afterTeardown" "0"

t_summary

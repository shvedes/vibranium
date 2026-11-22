#!/bin/bash
# Suite: pass-pin-tokens - LNC-2 delete pin and LNC-3 deferred sync tokens.
#
# PassPanel cannot be constructed offscreen, so the probe reads the real file
# and evaluates its own syncRows / release bodies with stubbed list, frame
# store, Pass service and deferred queue. The two overlapping intents are
# driven frame by frame: an older pin release must not unpin a newer motion,
# and an older sync must not reset a page slide opened by a newer intent.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "pass-pin-tokens" "delete pin generations and deferred sync tokens"
require_qs
trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/pass-pin-tokens.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

t_section "the slice is the real source"
qp_assert "the probe ran without throwing" "probe.error" ""
qp_assert "the QML source was read" "slice.sourceStatus" "true"
qp_assert "syncRows was found" "slice.syncFound" "true"
qp_assert "the pin release was found" "slice.releaseFound" "true"

t_section "LNC-3: a deferred sync owns its own token and key"
qp_assert "no shared pending token slots" "slice.noSharedSlots" "true"
qp_assert "token, resume, gen, key and page gen are captured" "slice.capturesLocals" "true"
qp_assert "the flush epoch still retires older closures" "slice.flushEpochRetained" "true"
qp_assert "no reset from a stale token during a live slide" "sync.resetsDuringLiveSlide" "0"
qp_assert "no token committed with another intent's key" "sync.mismatchedCommits" "0"
qp_assert "the transition's own sync closes the window" "sync.windowClosed" "true"
qp_assert "the committed key is the transition's view" "sync.finalKey" "pageC"

t_section "LNC-2: the pin release is generation-scoped and edge-driven"
qp_assert "no wall-clock poll in the release" "pin.noClockPoll" "true"
qp_assert "the release rides list motion and instant edges" "pin.edgeHandlers" "true"
qp_assert "the first release waits for a live edge" "pin.beforeNewDelete" "0"
qp_assert "no unpin mid-new-motion" "pin.midNewMotion" "0"
qp_assert "no unpin before the list publishes its edge" "pin.duringNewMotion" "0"
qp_assert "the live edge releases the new pin exactly once" "pin.afterEdge" "1"

t_summary

#!/bin/bash
# Suite: Phase 2 AsyncLoader request matrix - the real qs.boot.AsyncLoader
# driven offscreen with an injectable component factory.
#
# The probe (suites/qml/probes/boot-loader.qml) builds one QtObject loader per
# scenario, so no Boot/window is needed. It prints one serialized public-signal
# list per scenario; this suite compares each list, in full and in order, with
# the fixture of the same name under fixtures/boot-loader/. Counts alone cannot
# catch a lost adoption, a duplicate adopted edge, a reordered reentrant
# request or a cancelled callback that leaked a public failure.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-loader" "AsyncLoader request matrix, exact callback order, ids and cancellation"
require_qs
require_tools grep sed wc

FIXTURES="$TESTS_SHELL_DIR/fixtures/boot-loader"

# qp_setup assigns _QP_CFG inside a substitution, so callers must seed the
# mirror through its echoed path. The one real small QML URL is written there,
# next to the copied probe, and never into the shell tree.
_QP_CFG="$(qp_setup)"
trap qp_teardown EXIT
cat >"$_QP_CFG/BootLoaderSmallTarget.qml" <<'QML'
pragma ComponentBehavior: Bound
import QtQml

QtObject {
  property var boot: null
  readonly property string tag: "small-target"
}
QML

t_section "the probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-loader.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi
t_eq "every scenario was exercised" "true" "$(qp_get probe.complete)"

# The whole ordered signal list per scenario, never a count.
t_section "recorded signal lists equal their serialized fixtures"
for pair in \
  syncReady:sync-ready \
  syncErrorRepeat:sync-error-repeat \
  deferredReady:deferred-ready \
  deferredReadyRepeat:deferred-ready-repeat \
  deferredErrorRepeat:deferred-error-repeat \
  createObjectNullRepeat:create-object-null-repeat \
  adoptionSuppresses:adoption-suppresses \
  teardownDuringLoad:teardown-during-load \
  reentrantAdopted:reentrant-adopted \
  reentrantFailed:reentrant-failed \
  inertObserver:inert-observer \
  realUrl:real-url
do
  key="${pair%%:*}"
  fixture="${pair##*:}"
  t_eq "$key: the signal list equals $fixture.json" \
    "$(cat "$FIXTURES/$fixture.json")" "$(qp_get "$key.signals")"
done

t_section "asynchronous component creation and owner wiring"
t_eq "every injected load asked for an asynchronous component" "true" \
  "$(qp_get syncReady.async)"
t_eq "the factory received the source URL, not an inline component" \
  '["BootServices.qml"]' "$(qp_get syncReady.factoryUrls)"
t_eq "createObject received the loader owner and the boot property" \
  '[{"owner":true,"boot":true}]' "$(qp_get adoptionSuppresses.createCalls)"

t_section "synchronous Ready and the adoption guard"
t_eq "a synchronous Ready settles adopted" "adopted" "$(qp_get syncReady.state)"
t_eq "a synchronous Ready emits exactly one adopted edge" "1" \
  "$(qp_get syncReady.signals | grep -o '"op":"adopted"' | wc -l)"
t_eq "an adopted loader keeps its generation" "1" "$(qp_get syncReady.generation)"
t_eq "no attempt is allocated after adoption" "1" \
  "$(qp_get adoptionSuppresses.observer | grep -o '"op":"attemptOpen"' | wc -l)"
t_eq "the instance is never replaced by a later request" "true" \
  "$(qp_get adoptionSuppresses.instanceStable)"
t_eq "an inert observer leaves no observer calls" "[]" "$(qp_get inertObserver.observer)"

t_section "terminal failure is a report, not a permanent refusal"
t_eq "a synchronous load error settles the loader as failed" "failed" \
  "$(qp_get syncErrorRepeat.stateAfterFailure)"
t_eq "a deferred load error settles the loader as failed" "failed" \
  "$(qp_get deferredErrorRepeat.stateAfterFailure)"
t_eq "a null createObject settles the loader as failed" "failed" \
  "$(qp_get createObjectNullRepeat.stateAfterFailure)"
t_eq "each repeated attempt gets a fresh, distinct id" '[1,2]' \
  "$(qp_get syncErrorRepeat.ids)"
t_eq "the deferred repeat also gets distinct ids" '[1,2]' \
  "$(qp_get deferredErrorRepeat.ids)"
t_eq "the null-adoption repeat gets distinct ids" '[1,2]' \
  "$(qp_get createObjectNullRepeat.ids)"
t_eq "two deferred Ready attempts adopt once each, with distinct ids" '[1,2]' \
  "$(qp_get deferredReadyRepeat.ids)"
t_eq "and both loaders end adopted" "adopted|adopted" \
  "$(qp_get deferredReadyRepeat.stateA)|$(qp_get deferredReadyRepeat.stateB)"
t_eq "the fault-free path still allocates ids without an observer" '[1,2]' \
  "$(qp_get inertObserver.ids)"

t_section "deferred status hookup detaches the exact named handler once"
for pair in deferredReady:1 deferredErrorRepeat:2 teardownDuringLoad:1; do
  key="${pair%%:*}"
  expected="${pair##*:}"
  t_eq "$key: one statusChanged connection per deferred attempt" "$expected" \
    "$(qp_get "$key.connects")"
  t_eq "$key: one statusChanged disconnection per deferred attempt" "$expected" \
    "$(qp_get "$key.disconnects")"
  t_eq "$key: no disconnect of a handler that was never connected" "0" \
    "$(qp_get "$key.badDisconnects")"
  t_eq "$key: no handler remains attached" "0" "$(qp_get "$key.handlerCount")"
done
t_eq "a synchronous Ready never connects a status handler" "0" \
  "$(qp_get syncReady.connects)"

t_section "teardown is cancellation, never a public failure"
t_eq "teardown returns the loader to idle" "idle" \
  "$(qp_get teardownDuringLoad.stateAfterTeardown)"
t_eq "the observer sees a teardown outcome for the active attempt" \
  '[{"op":"attemptOpen","id":1},{"op":"attemptClose","id":1,"outcome":"teardown"},{"op":"attemptOpen","id":2}]' \
  "$(qp_get teardownDuringLoad.observer)"
t_eq "the stale callback publishes no failed signal" "0" \
  "$(qp_get teardownDuringLoad.signals | grep -o '"op":"failed"' | wc -l)"
t_eq "teardown and the fresh load each retire a generation" "3" \
  "$(qp_get teardownDuringLoad.generation)"
t_eq "a fresh request after teardown adopts with a new id" '[2]' \
  "$(qp_get teardownDuringLoad.ids)"

t_section "reentrant requests"
t_eq "a request from adopted is refused, with no second attempt" "1" \
  "$(qp_get reentrantAdopted.observer | grep -o '"op":"attemptOpen"' | wc -l)"
t_eq "the loader stays adopted after the reentrant request" "adopted" \
  "$(qp_get reentrantAdopted.state)"
t_eq "a request from failed is accepted with a new attempt id" '[1,2]' \
  "$(qp_get reentrantFailed.ids)"
t_eq "the reentrant attempt adopts" "adopted" "$(qp_get reentrantFailed.state)"

t_section "the one real small QML URL"
t_eq "the real URL adopted a small QtObject" "adopted" "$(qp_get realUrl.state)"
t_eq "it carries a positive attempt id" "true" \
  "$([[ $(qp_get realUrl.id) -gt 0 ]] && echo true || echo false)"
t_eq "it is the injected owner's boot property" "true" "$(qp_get realUrl.owner)"
t_eq "the real component hookup used Component.Asynchronous" "true" \
  "$(qp_get realUrl.async)"

t_summary

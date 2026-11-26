#!/bin/bash
# Suite: BootPump FIFO - the real qs.boot.BootPump driven offscreen with an
# injected clock and a recording observer.
#
# The probe (suites/qml/probes/boot-pump.qml) builds a QtObject pump directly,
# so no full Boot/window is needed. It prints one serialized event list per
# scenario; this suite compares each list, in full and in order, with the
# fixture of the same name under fixtures/boot-pump/. Counts alone cannot
# catch a lost rearm or a reordered continuation.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-pump" "literal FIFO, per-entry tokens, fault-contained observer, coordinator shutdown"
require_qs
require_tools grep sed

FIXTURES="$TESTS_SHELL_DIR/fixtures/boot-pump"
trap qp_teardown EXIT

t_section "the pump probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-pump.qml" 30; then
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
t_eq "the timer is a 16 ms one-shot" '{"interval":16,"repeat":false}' "$(qp_get pump.timer)"

t_section "recorded event lists equal their serialized fixtures"
# key:fixture pairs; every comparison is the whole ordered event list.
for pair in \
  normal:normal \
  throwNoEnqueue:throw-no-enqueue \
  throwSelf:throw-self-enqueue \
  duplicate:duplicate \
  alreadyArmed:already-armed \
  reentrant:reentrant \
  overlap:overlap \
  fakeClock:clock \
  shutdown:shutdown \
  observerDispatch:observer-dispatch \
  observerOpen:observer-open \
  observerDuplicate:observer-duplicate \
  inert:inert
do
  key="${pair%%:*}"
  fixture="${pair##*:}"
  t_eq "$key: the event list equals $fixture.json" \
    "$(cat "$FIXTURES/$fixture.json")" "$(qp_get "$key.events")"
done

t_section "acceptance and callback order"
t_eq "both entries in the normal chain are accepted" "true|true" \
  "$(qp_get normal.enqueueA)|$(qp_get normal.enqueueB)"
t_eq "the throwing entry is accepted" "true" "$(qp_get throwNoEnqueue.enqueue)"
t_eq "the self-enqueueing throwing entry is accepted" "true" "$(qp_get throwSelf.enqueue)"
t_eq "the first duplicate case is accepted" "true" "$(qp_get duplicate.first)"
t_eq "the duplicate enqueue is rejected" "false" "$(qp_get duplicate.second)"
t_eq "normal callbacks stay in arrival order" '["A","B"]' "$(qp_get normal.callbacks)"
t_eq "early/deferred/replay overlap keeps continuation order" \
  '["early1","early2","deferred","replay"]' "$(qp_get overlap.callbacks)"

t_section "throwing callbacks"
# The fixtures pin the closeWork outcome, no pump rearm and exception text;
# these keys restate the control-flow consequences for a reader.
t_eq "a throwing callback with no self-enqueue leaves no pending work" \
  '{"op":"turn","result":"boom-no-enqueue","pending":0,"timer":false}' \
  "$(qp_get throwNoEnqueue.events | grep -o '{"op":"turn"[^}]*}')"
t_eq "a throwing callback that self-enqueued leaves the new entry pending" \
  '{"op":"turn","result":"boom-self","pending":1,"timer":false}' \
  "$(qp_get throwSelf.events | grep -o '{"op":"turn"[^}]*}' | head -1)"
t_eq "shutdown clears the pending entries" "0" "$(qp_get shutdown.pending)"
t_eq "shutdown stops the timer" "false" "$(qp_get shutdown.timer)"
t_eq "shutdown does not run a callback" "[]" "$(qp_get shutdown.callbacks)"

t_section "fault-contained observer and inert observer"
t_eq "two dispatch faults produce exactly two noteFailure calls" "2" \
  "$(qp_get observerDispatch.noteFailures)"
t_eq "a failed openWork produces exactly one noteFailure call" "1" \
  "$(qp_get observerOpen.noteFailures)"
t_eq "two enqueue faults produce exactly two noteFailure calls" "2" \
  "$(qp_get observerDuplicate.noteFailures)"
t_eq "an inert observer makes zero observer calls" "[]" \
  "$(qp_get inert.observerCalls)"
t_eq "an inert observer reports zero failures" "0" "$(qp_get inert.noteFailures)"
t_eq "traced and inert observers produce the same callback order" \
  "$(qp_get normal.callbacks)" "$(qp_get inert.callbacks)"

t_summary

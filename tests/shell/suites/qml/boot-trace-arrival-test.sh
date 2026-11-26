#!/bin/bash
# Suite: boot-trace arrivals - both join orders, deferred handoff vs skip,
# watchdog deadline with a stalled GUI turn, and the earlier-seal race.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-trace-arrival" "the recorder in a QML engine, driven by the copied fixtures"
require_qs
require_tools grep sed

export BT_JOIN_FEATURES="$(cat "$TESTS_SHELL_DIR/fixtures/boot-trace/join-features-first.json")"
export BT_JOIN_PLAYED="$(cat "$TESTS_SHELL_DIR/fixtures/boot-trace/join-played-first.json")"
export BT_SEAL="$(cat "$TESTS_SHELL_DIR/fixtures/boot-trace/successful-seal.json")"
trap qp_teardown EXIT

t_section "the arrival probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-trace-arrival.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi

t_section "both arrival orders"
t_eq "features-first join is complete" "complete" "$(qp_get features.chain)"
t_eq "features-first selects the played predecessor" "endpoint.entrancePlayed" "$(qp_get features.predecessor)"
t_eq "features-first retains the other branch" "provider.result" "$(qp_get features.parallel)"
t_eq "features-first records the drain endpoint" "126" "$(qp_get features.endpoint)"
t_eq "played-first join is complete" "complete" "$(qp_get played.chain)"
t_eq "played-first selects the provider predecessor" "provider.result" "$(qp_get played.predecessor)"
t_eq "played-first retains the other branch" "endpoint.entrancePlayed" "$(qp_get played.parallel)"
t_eq "played-first records the drain endpoint" "126" "$(qp_get played.endpoint)"

t_section "deferred terminal paths"
t_eq "a skipped deferred source is terminal" "skipped" "$(qp_get deferred.skipTerminal)"
t_eq "a handed-off deferred source is admitted" "admissionComplete" "$(qp_get deferred.handoffTerminal)"
t_eq "the skip path still seals normally" "true" "$(qp_get deferred.skipSealed)"
t_eq "the handoff path still seals normally" "true" "$(qp_get deferred.handoffSealed)"

t_section "watchdog deadline and stalled turn"
t_eq "the GUI thread was actually occupied" "true" "$(qp_get stall.occupiedMs)"
t_eq "no fire at deadline-1 after the stall" "false" "$(qp_get stall.noEarlyFire)"
t_eq "a stalled turn cannot change the unsealed report" "true" "$(qp_get stall.reportUnchanged)"
t_eq "the watchdog fires at the deadline" "true" "$(qp_get watchdog.atDeadline)"
t_eq "the watchdog seal is recorded" "true" "$(qp_get watchdog.sealed)"

t_section "earlier seal wins"
t_eq "the earlier seal reason survives" "aborted" "$(qp_get race.sealReason)"
t_eq "watchdogFired after a seal returns false" "false" "$(qp_get race.watchdogAfterSeal)"
t_eq "a sealed report is unchanged by the race" "true" "$(qp_get race.reportFrozen)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

# A stalled GUI turn in a headless engine proves only the recorder's clock
# discipline. The real Boot watchdog is a QML Timer; pin that it can only seal.
WATCHDOG_BODY="$(sed -n '/id: traceWatchdog/,/^  }/p' "$SHELL_DIR/boot/Boot.qml")"
t_section "the probe matches the production watchdog"
t_contains "the timer checks the recorder's seal state" 'boot.trace.snapshot().sealed' "$WATCHDOG_BODY"
t_contains "the timer calls watchdogFired" 'boot.trace.watchdogFired(boot.nowMs())' "$WATCHDOG_BODY"
t_not_contains "the timer writes no log line" 'Log.' "$WATCHDOG_BODY"
t_skip "real stalled-turn delivery through Boot's QML Timer" \
  "UNVERIFIED: Boot cannot be built offscreen; the recorder's deadline discipline is exercised in-engine and the Timer body is pinned statically"

t_summary

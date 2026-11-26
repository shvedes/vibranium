#!/bin/bash
# Suite: boot-trace registration paths - failed gateway registration is an
# observation only; a catalog failure is a separate aborted seal; the watchdog
# keeps its own deadline and a sealed report stays frozen.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-trace-registration" "gateway failure is observation-only; catalog failure aborts"
require_qs
require_tools grep sed

trap qp_teardown EXIT

t_section "the registration probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-trace-registration.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi

t_section "a failed gateway registration is not a seal"
t_eq "the real router refuses an unknown row" "false" "$(qp_get router.failedRegister)"
t_true "the gateway observation was recorded" test "$(qp_get gateway.eventId)" -gt 0
t_eq "the gateway observation is in the causal index" "true" "$(qp_get gateway.inChain)"
t_eq "capture is not sealed" "false" "$(qp_get gateway.sealed)"
t_eq "there is no fake aborted reason" "null" "$(qp_get gateway.sealReason)"
t_eq "integrity stays valid" "true" "$(qp_get gateway.integrity)"
t_eq "no violation was written" "0" "$(qp_get gateway.violations)"
t_eq "a snapshot is still available" "2" "$(qp_get gateway.snapshotAvailable)"
t_true "the snapshot advances with the clock" test "$(qp_get gateway.observedThroughMs)" -gt 0
t_eq "later work is still captured" "true" "$(qp_get gateway.captureContinues)"

t_section "the watchdog and the seal boundary"
t_eq "no early fire at deadline-1" "false" "$(qp_get gateway.watchdogEarly)"
t_eq "the watchdog fires at the deadline" "true" "$(qp_get gateway.watchdogAtDeadline)"
t_eq "the watchdog seals capture" "true" "$(qp_get gateway.watchdogSealed)"
t_eq "a sealed report is frozen across a clock advance" "true" "$(qp_get gateway.sealedReportFrozen)"

t_section "catalog failure is a separate observation"
t_eq "the catalog failure seals" "true" "$(qp_get catalog.sealed)"
t_eq "the catalog failure uses aborted" "aborted" "$(qp_get catalog.reason)"
t_eq "the gateway failure did not abort" "true" "$(qp_get catalog.distinctFromGateway)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

# --- pin the probe's model to the real source -------------------------------
t_section "the probe matches the production path"
NOTE_BODY="$(sed -n '/function _noteGatewayRegistration/,/^  }/p' "$SHELL_DIR/boot/Boot.qml")"
t_contains "the gateway note emits an observation" 'boot.trace.emit("gateway.registered"' "$NOTE_BODY"
t_not_contains "the gateway note never seals" '_sealTrace' "$NOTE_BODY"
t_not_contains "the gateway note never logs" 'Log.' "$NOTE_BODY"
CATALOG_BODY="$(sed -n '/if (!catalogOk)/,/^    }/p' "$SHELL_DIR/boot/Boot.qml")"
t_contains "the catalog failure aborts" '_sealTrace("aborted")' "$CATALOG_BODY"
WATCHDOG_BODY="$(sed -n '/id: traceWatchdog/,/^  }/p' "$SHELL_DIR/boot/Boot.qml")"
t_contains "the watchdog calls the recorder" 'boot.trace.watchdogFired(boot.nowMs())' "$WATCHDOG_BODY"
t_not_contains "the watchdog writes no log line" 'Log.' "$WATCHDOG_BODY"
t_skip "a real gateway registration failure in a constructed Boot" \
  "UNVERIFIED: Boot cannot be built offscreen (LayerSurface/PanelWindow); the real router refusal and the real recorder path are exercised separately"

t_summary

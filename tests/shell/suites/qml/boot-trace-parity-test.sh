#!/bin/bash
# Suite: boot-trace parity - traced and inert walks of the same boot turns.
# A headless engine can establish logical choreography parity only; it proves
# nothing about paint, frame timing, wallpaper fades or what a user sees.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "boot-trace-parity" "same provider, milestone, timer, queue and IPC order with and without capture"
require_qs
require_tools grep sed

export BT_SEAL="$(cat "$TESTS_SHELL_DIR/fixtures/boot-trace/successful-seal.json")"
trap qp_teardown EXIT

t_section "the parity probe"
if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/boot-trace-parity.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi
if qp_probe_ran "probe.error"; then
  t_no "the probe ran without throwing" "$(qp_get probe.error)"
else
  t_ok "the probe ran without throwing"
fi

t_section "traced and inert choreography agree"
t_eq "the whole step sequence agrees" "true" "$(qp_get parity.steps)"
t_eq "provider turns agree" "true" "$(qp_get parity.provider)"
t_eq "bar and wallpaper milestones agree" "true" "$(qp_get parity.milestone)"
t_eq "queue and terminal dispositions agree" "true" "$(qp_get parity.queue)"
t_eq "IPC order agrees" "true" "$(qp_get parity.ipc)"
t_eq "timer arming agrees" "true" "$(qp_get parity.timer)"
t_eq "fallback selection agrees" "true" "$(qp_get parity.fallback)"
t_eq "neither path adds a diagnostic log line" "true" "$(qp_get parity.logLines)"

t_section "the shared choreography is the boot contract"
t_contains "services are demanded" "provider.request:provider:services" "$(qp_get steps.provider)"
t_contains "the services result is adopted" "provider.result:provider:services:adopted" "$(qp_get steps.provider)"
t_contains "features are absent by bar" "queue.skip:provider:features" "$(qp_get steps.queue)"
t_contains "bar reports absence" "queue.skip:surface:bar" "$(qp_get steps.queue)"
t_contains "the settle milestone is recorded" "milestone:settled" "$(qp_get steps.milestone)"
t_contains "bar reports played" "milestone:played:bar" "$(qp_get steps.milestone)"
t_contains "wallpaper reports played" "milestone:played:wallpaper" "$(qp_get steps.milestone)"
t_eq "the fallback is selected once" "drain:fallback" "$(qp_get steps.fallback)"
t_eq "IPC registers shell before boot" "ipc:shell.register|ipc:boot.register" "$(qp_get steps.ipc)"
t_eq "the watchdog is armed once" "timer:watchdog.arm" "$(qp_get steps.timer)"

t_section "the traced report is consistent with that choreography"
t_eq "the traced walk seals normally" "true" "$(qp_get traced.sealed)"
t_eq "all three endpoints are present" "3" "$(qp_get traced.endpoints)"
t_eq "integrity stays valid" "true" "$(qp_get traced.integrity)"
t_eq "all seven sources are terminal" "7" "$(qp_get traced.ledgerTerminal)"
t_eq "every observation was printed" "true" "$(qp_get probe.complete)"

# Static boundary: the wrappers that observe milestones must not log or latch.
LAYOUT_MILESTONES="$(sed -n '/function noteBootEntranceSettled/,/function noteBootEntrancePlayed/p' "$SHELL_DIR/common/state/DesktopLayoutState.qml")"
t_section "observer purity in the real wrappers"
t_not_contains "the settle wrapper writes no log line" 'Log.' "$LAYOUT_MILESTONES"
t_contains "the settle wrapper allocates before latching" \
  'root.milestoneObserver._observeMilestone' "$LAYOUT_MILESTONES"
t_skip "visual parity of the boot entrance" \
  "not observable in a headless engine - no surface paints, so no claim about fades or frames"
t_skip "real provider/timer/queue/IPC order under a constructed Boot" \
  "UNVERIFIED: Boot cannot be built offscreen; order is compared on the shared turn model with real recorder calls in one walk"

t_summary
